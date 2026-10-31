//! The coverage gate: every public ozz name in the areas this ABI claims has a
//! verdict in `ci/coverage/unbound_*.txt`, and every verdict is checkable.
//! INTERNAL is recomputed and refused unless upstream proves it; GAP fails.
//!
//!   (no mode)          the gate             --list   the gate, and the gaps
//!   --names            AREA<TAB>NAME for every name no entry point spells out
//!   --areas            the claimed areas, NAME[:DEPTH]
//!   --classify         NAME<TAB>INTERNAL<TAB>evidence, the provable verdicts
//!   --open             the unbound names --classify cannot justify
//!   --summary [AREA]   bound and public names per area, and AREA's unbound ones
//!
//! Run from the repository root. Every order is byte order and every directory
//! is read in byte order, so the output is the same on every host.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

/// The vendored ozz headers.
const ozz = "libs/ozz/include/ozz";
/// The vendored ozz sources, which build.zig's source list is read against.
const ozz_src = "libs/ozz/src";
/// The record: AREA<TAB>NAME<TAB>VERDICT<TAB>EVIDENCE, one file per area group.
const record_dir = "ci/coverage";
/// C entry points no Zig wrapper calls, each with its reason.
const exceptions_path = "ci/coverage/zig_surface_exceptions.txt";
/// The largest file read.
const max_file_bytes = 1 << 22;
/// The deepest a directory walk descends below its root.
const max_depth = 32;
/// How many unbound names `--summary AREA` lists per area.
const max_listed = 60;

/// Every directory ozz has, as `NAME:DEPTH` where the walk stops at DEPTH
/// because the subdirectories are areas of their own. A directory under
/// libs/ozz/include/ozz this list does not claim fails the gate: it is a
/// place a capability can hide where nothing here would look.
const area_specs = [_][]const u8{
    ".:1",        "base:1",           "base/containers", "base/encode",       "base/io",
    "base/maths", "base/memory",      "animation:1",     "animation/runtime", "animation/offline",
    "geometry:1", "geometry/runtime", "options",
};

/// Every verdict a line of the record can carry.
const verdicts = [_][]const u8{ "BOUND", "EXTENSION", "LANGUAGE", "ZIG", "INTERNAL", "GAP" };

/// The Zig facilities LANGUAGE evidence may name, matched as prefixes, so the
/// verdict cannot become a home for anything inconvenient.
const facilities = [_][]const u8{
    "@Vector",       "@shuffle",    "@reduce",         "@splat",            "@select",  "@bitCast",
    "@ptrCast",      "@floatCast",  "@intCast",        "@as",               "@clz",     "@ctz",
    "@popCount",     "@min",        "@max",            "@abs",              "@sqrt",    "@mulAdd",
    "@byteSwap",     "@atomicRmw",  "@prefetch",       "std.math",          "std.mem",  "std.sort",
    "std.ArrayList", "std.HashMap", "std.AutoHashMap", "std.PriorityQueue", "std.hash", "std.Thread",
    "std.heap",      "std.fmt",     "std.ascii",
};

/// Words that read like a call but declare nothing.
const method_keywords = [_][]const u8{
    "if",     "for", "while", "switch", "return", "sizeof", "alignof", "static_assert",
    "assert", "do",  "else",  "catch",  "new",    "delete", "defined",
};

/// The same words for upstream's internal markers, matched as prefixes as
/// the awk this program replaced matched them: `format_value` reads as `for`
/// and is never marked. No verdict depends on it today.
const marker_keywords = [_][]const u8{
    "if",            "for", "while", "switch", "return", "sizeof", "alignof",
    "static_assert", "do",  "else",  "catch",  "new",    "delete", "defined",
    "operator",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buffer);
    var stderr = Io.File.stderr().writer(io, &err_buffer);
    var r: Report = .{ .out = &stdout.interface, .err = &stderr.interface };
    const code = try run(.{ .io = io, .dir = Io.Dir.cwd(), .a = a }, &r, args);
    try stdout.interface.flush();
    try stderr.interface.flush();
    return code;
}

/// Runs the mode `args` names and returns the exit code.
fn run(t: Tree, r: *Report, args: []const [:0]const u8) !u8 {
    const mode: []const u8 = if (args.len > 1) args[1] else "";
    if (eql(mode, "") or eql(mode, "--list")) return gate(t, r, eql(mode, "--list"));
    if (eql(mode, "--areas")) {
        for (area_specs) |spec| try r.out.print("{s}\n", .{spec});
        return 0;
    }
    if (eql(mode, "--summary")) {
        try summary(t, r.out, if (args.len > 2) args[2] else null);
        return 0;
    }
    if (eql(mode, "--names")) {
        for ((try coverage(t)).areas) |area| {
            for (area.unbound) |name| try r.out.print("{s}\t{s}\n", .{ area.label, name });
        }
        return 0;
    }
    if (eql(mode, "--classify") or eql(mode, "--open")) {
        const open = eql(mode, "--open");
        for (try classify(t, try unboundNames(t.a, try coverage(t)))) |c| {
            if (c.evidence) |e| {
                if (!open) try r.out.print("{s}\tINTERNAL\t{s}\n", .{ c.name, e });
            } else if (open) try r.out.print("{s}\n", .{c.name});
        }
        return 0;
    }
    try r.err.print("unknown mode {s}; the modes are listed at the top of ci/coverage.zig\n", .{mode});
    return 2;
}

/// Where findings and the summary go, and how many checks failed.
const Report = struct {
    out: *Io.Writer,
    err: *Io.Writer,
    fails: usize = 0,

    /// Prints one failed check's headline.
    fn fail(r: *Report, comptime format: []const u8, args: anytype) !void {
        try r.err.print(format ++ "\n", args);
        r.fails += 1;
    }

    /// Prints `lines`, each indented by two spaces.
    fn listed(r: *Report, lines: []const []const u8) !void {
        for (lines) |line| try r.err.print("  {s}\n", .{line});
    }
};

/// One entry of a directory walk.
const Entry = struct { path: []const u8, kind: Io.File.Kind };

/// The repository the gate reads, rooted at `dir`.
const Tree = struct {
    io: Io,
    dir: Io.Dir,
    a: Allocator,

    /// A file's contents, or null when there is no such file.
    fn read(t: Tree, path: []const u8) !?[]const u8 {
        return aegis.own.readFile(t.io, t.dir, path, t.a, .fromRaw(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound, error.IsDir => null,
            else => |e| e,
        };
    }

    /// What `path` is, or null when there is nothing there.
    fn kind(t: Tree, path: []const u8) !?Io.File.Kind {
        const stat = t.dir.statFile(t.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => |e| return e,
        };
        return stat.kind;
    }

    /// The entries of directory `path`, names only, in byte order; empty when
    /// there is no directory.
    fn entries(t: Tree, path: []const u8) ![]const Entry {
        var dir = t.dir.openDir(t.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return &.{},
            else => |e| return e,
        };
        defer dir.close(t.io);
        var out: std.ArrayList(Entry) = .empty;
        var it = dir.iterate();
        while (try it.next(t.io)) |entry| try out.append(t.a, .{ .path = try t.a.dupe(u8, entry.name), .kind = entry.kind });
        mem.sort(Entry, out.items, {}, lessEntry);
        return out.items;
    }

    /// Every entry below `root`, at most `depth` levels down, in the order
    /// `find` lists them from a file system that reads back in byte order.
    fn walk(t: Tree, root: []const u8, depth: usize) ![]const Entry {
        var out: std.ArrayList(Entry) = .empty;
        try t.walkInto(&out, root, @min(depth, max_depth));
        return out.items;
    }

    fn walkInto(t: Tree, out: *std.ArrayList(Entry), path: []const u8, depth: usize) !void {
        if (depth == 0) return;
        for (try t.entries(path)) |e| {
            const full = try t.a.print("{s}/{s}", .{ path, e.path });
            try out.append(t.a, .{ .path = full, .kind = e.kind });
            if (e.kind == .directory) try t.walkInto(out, full, depth - 1);
        }
    }

    /// The files `ffi/*.h`-style globbing names, read, with their paths.
    fn files(t: Tree, path: []const u8, prefix: []const u8, suffix: []const u8) ![]const Named {
        var out: std.ArrayList(Named) = .empty;
        for (try t.entries(path)) |e| {
            if (e.kind != .file or e.path[0] == '.') continue;
            if (!mem.startsWith(u8, e.path, prefix) or !mem.endsWith(u8, e.path, suffix)) continue;
            const full = try t.a.print("{s}/{s}", .{ path, e.path });
            try out.append(t.a, .{ .name = full, .ref = (try t.read(full)) orelse continue });
        }
        return out.items;
    }
};

fn lessEntry(_: void, x: Entry, y: Entry) bool {
    return mem.lessThan(u8, x.path, y.path);
}

/// Two strings carried together: a name and what it refers to.
const Named = struct { name: []const u8, ref: []const u8 };

//===========================================================================
// The harvest: every public name ozz declares in one area, as a work list.
//
// Methods, free functions, and operators qualified by the exposed type they
// act on (Float4x4::operator*). An indented operator is a member and takes its
// class; one at column zero takes its first parameter's type, which ozz may
// wrap onto the next line. State carries across one area's headers as it did
// when one awk process read them all. The public data members of a class or
// struct outside `namespace internal` are names too, read by AccessScanner
// one header at a time: the parameters a caller sets on a builder or a job.
//===========================================================================

/// Reads public names out of one area's headers.
const MethodScanner = struct {
    a: Allocator,
    /// The ozz types a caller can obtain, which decide the operators reported.
    exposed: *const std.StringHashMap(void),
    names: std.ArrayList([]const u8) = .empty,
    public: bool = true,
    cls: []const u8 = "",
    in_comment: bool = false,
    /// A free operator whose first parameter is on the next line.
    pending_sym: []const u8 = "",

    fn file(s: *MethodScanner, text: []const u8) !void {
        s.public = true;
        s.cls = "";
        var lines: Lines = .init(text);
        while (lines.next()) |raw| try s.line(raw);
    }

    /// One physical line; a `class` and `struct` both open public scope.
    fn line(s: *MethodScanner, raw: []const u8) !void {
        if (mem.startsWith(u8, trimStart(raw), "#")) return;
        if (accessLabel(raw)) |public| {
            s.public = public;
            return;
        }
        if (keywordThenSpace(trimStart(raw), &.{ "class", "struct" })) {
            s.public = true;
            if (className(raw)) |name| s.cls = name;
        }
        if (!s.public) return;
        const code = (try stripBlockComments(s.a, raw, &s.in_comment)) orelse return;
        if (mem.find(u8, code, "OZZ_ASSERT") != null or mem.startsWith(u8, trimStart(code), "//")) return;
        if (s.pending_sym.len > 0) {
            const ty = firstParamType(code);
            const sym = s.pending_sym;
            s.pending_sym = "";
            if (ty.len > 0 and s.exposed.contains(ty)) try s.names.append(s.a, try s.a.print("{s}::{s}", .{ ty, sym }));
        }
        if (operatorAhead(code)) return s.operator(code);
        const id = identParen(code) orelse return;
        if (id.start > 0 and mem.findScalar(u8, ".>:", code[id.start - 1]) != null) return;
        const name = code[id.start..id.end];
        if (eql(name, s.cls) or name[0] == '_' or name[name.len - 1] == '_') return;
        if (oneOf(name, "", &method_keywords) or startsWithAny(name, &.{ "operator", "OZZ_" })) return;
        if (macroCase(name) or name.len < 3) return;
        try s.names.append(s.a, name);
    }

    /// An operator, qualified by the type it acts on when a caller can
    /// obtain that type. Assignment is value semantics for a type the ABI
    /// hands out by pointer only, so there is nothing to deliver.
    fn operator(s: *MethodScanner, code: []const u8) !void {
        const op = operatorCall(code) orelse return;
        const sym = trimEnd(code[op.start..op.paren]);
        if (eql(sym, "operator=")) return;
        var ty = s.cls;
        if (!isSpace(code[0])) {
            ty = firstParamType(code[op.paren + 1 ..]);
            if (ty.len == 0) {
                s.pending_sym = sym;
                return;
            }
        }
        if (ty.len == 0 or !s.exposed.contains(ty)) return;
        try s.names.append(s.a, try s.a.print("{s}::{s}", .{ ty, sym }));
    }
};

/// `private:`/`protected:` (false) or `public:` (true) opening a line.
fn accessLabel(raw: []const u8) ?bool {
    const l = trimStart(raw);
    if (mem.startsWith(u8, l, "private:") or mem.startsWith(u8, l, "protected:")) return false;
    if (mem.startsWith(u8, l, "public:")) return true;
    return null;
}

/// Whether `l` opens with one of `keywords` and a whitespace character.
fn keywordThenSpace(l: []const u8, keywords: []const []const u8) bool {
    for (keywords) |k| {
        if (mem.startsWith(u8, l, k) and l.len > k.len and isSpace(l[k.len])) return true;
    }
    return false;
}

/// The class a `class`/`struct` line names: the last identifier of the
/// leftmost `(class|struct) IDENT [IDENT]`, so an export macro between the
/// keyword and the name is passed over.
fn className(s: []const u8) ?[]const u8 {
    for (0..s.len) |i| {
        const kw: usize = if (mem.startsWith(u8, s[i..], "class")) 5 else if (mem.startsWith(u8, s[i..], "struct")) 6 else continue;
        const j = skipSpace(s, i + kw);
        if (j == i + kw or j >= s.len or !isIdentStart(s[j])) continue;
        const end = wordEnd(s, j);
        const k = skipSpace(s, end);
        if (k > end and k < s.len and isIdentStart(s[k])) return s[k..wordEnd(s, k)];
        return s[j..end];
    }
    return null;
}

/// Whether `operator` is followed by a character no identifier or space is.
fn operatorAhead(s: []const u8) bool {
    var from: usize = 0;
    while (mem.findPos(u8, s, from, "operator")) |i| {
        from = i + 1;
        if (i + 8 < s.len and !isWord(s[i + 8]) and s[i + 8] != ' ') return true;
    }
    return false;
}

/// Where an operator declaration starts and where its parameter list opens.
const OperatorCall = struct { start: usize, paren: usize };

/// The leftmost `operator()`, `operator[]` or `operator<symbols>` followed by
/// optional whitespace and `(`.
fn operatorCall(s: []const u8) ?OperatorCall {
    var from: usize = 0;
    while (mem.findPos(u8, s, from, "operator")) |i| {
        from = i + 1;
        const j = i + 8;
        var k = j;
        if (mem.startsWith(u8, s[j..], "()") or mem.startsWith(u8, s[j..], "[]")) {
            k = j + 2;
        } else {
            while (k < s.len and operatorChar(s[k])) k += 1;
            if (k == j) continue;
        }
        const p = skipSpace(s, k);
        if (p < s.len and s[p] == '(') return .{ .start = i, .paren = p };
    }
    return null;
}

fn operatorChar(c: u8) bool {
    return !isWord(c) and c != ' ' and c != '(' and c != ')' and c != '[';
}

/// The type a parameter list opens with, unqualified, with no `const`, no
/// namespace and no leading underscore; empty when it opens with none.
fn firstParamType(rest: []const u8) []const u8 {
    var r = trimStart(rest);
    for ([_][]const u8{ "const", "volatile" }) |q| {
        if (keywordThenSpace(r, &.{q})) {
            r = trimStart(r[q.len..]);
            break;
        }
    }
    if (r.len == 0 or !isIdentStart(r[0])) return "";
    var end: usize = 0;
    while (end < r.len and (isWord(r[end]) or r[end] == ':')) end += 1;
    var ty = r[0..end];
    if (mem.findLast(u8, ty, "::")) |p| ty = ty[p + 2 ..];
    if (ty.len > 0 and ty[0] == '_') ty = ty[1..];
    return ty;
}

/// An identifier's span.
const Span = struct { start: usize, end: usize };

/// The leftmost identifier followed by optional whitespace and `(`.
fn identParen(s: []const u8) ?Span {
    var i: usize = 0;
    while (i < s.len) {
        if (!isIdentStart(s[i])) {
            i += 1;
            continue;
        }
        const end = wordEnd(s, i);
        const p = skipSpace(s, end);
        if (p < s.len and s[p] == '(') return .{ .start = i, .end = end };
        i = end;
    }
    return null;
}

/// A name that is all capitals, digits and underscores: a macro.
fn macroCase(name: []const u8) bool {
    for (name) |c| {
        if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

//===========================================================================
// Matching. Both names split into words at camelCase boundaries and at
// underscores; an upstream name is bound when its words are an ordered
// subsequence of some entry point's words. Whole words, not substrings: `Tan`
// must not match zozzIArchiveTestAnimation. A deliberate rename reads as
// unbound, and the record answers for it.
//===========================================================================

/// A name's words, lowercased, split as awk's `split(s, w, / +/)` splits:
/// an underscore at either end leaves an empty word there.
fn splitWords(a: Allocator, m: []const u8) ![]const []const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (m, 0..) |c, i| {
        if (c == '_') {
            try s.append(a, ' ');
            continue;
        }
        if (std.ascii.isUpper(c) and i > 0 and (std.ascii.isLower(m[i - 1]) or std.ascii.isDigit(m[i - 1]))) try s.append(a, ' ');
        try s.append(a, std.ascii.toLower(c));
    }
    var words: std.ArrayList([]const u8) = .empty;
    if (s.items.len == 0) return words.items;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.items.len) {
        if (s.items[i] != ' ') {
            i += 1;
            continue;
        }
        try words.append(a, s.items[start..i]);
        while (i < s.items.len and s.items[i] == ' ') i += 1;
        start = i;
    }
    try words.append(a, s.items[start..]);
    return words.items;
}

/// Two words compared as awk compares split() fields: as numbers when both
/// look like one (`0000` equals `0`), as strings otherwise.
fn sameWord(x: []const u8, y: []const u8) bool {
    if (numeric(x) and numeric(y)) {
        const fx = std.fmt.parseFloat(f64, x) catch return eql(x, y);
        const fy = std.fmt.parseFloat(f64, y) catch return eql(x, y);
        return fx == fy;
    }
    return eql(x, y);
}

/// Digits, optionally followed by `e` and digits: the numeric forms a
/// lowercased identifier word can take.
fn numeric(w: []const u8) bool {
    const e = mem.findScalar(u8, w, 'e') orelse w.len;
    if (e == 0 or !allDigits(w[0..e])) return false;
    return e == w.len or (e + 1 < w.len and allDigits(w[e + 1 ..]));
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Whether `words` appear, in order, among some bound name's words.
fn spelledOut(words: []const []const u8, bound: []const []const []const u8) bool {
    for (bound) |b| {
        var k: usize = 0;
        for (b) |w| {
            if (k == words.len) break;
            if (sameWord(w, words[k])) k += 1;
        }
        if (k == words.len) return true;
    }
    return false;
}

/// The names of `names` no bound name spells out, in the order given.
fn unmatched(a: Allocator, names: []const []const u8, bound: []const []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        if (!spelledOut(try splitWords(a, name), bound)) try out.append(a, name);
    }
    return out.items;
}

//===========================================================================
// What ffi/*.h declares.
//===========================================================================

/// Every `zozz...` identifier directly followed by `(`: the entry points.
fn entryPoints(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var from: usize = 0;
    while (mem.findPos(u8, text, from, "zozz")) |at| {
        const end = wordEnd(text, at);
        if (end < text.len and text[end] == '(') {
            try out.append(a, text[at..end]);
            from = end + 1;
        } else from = at + 1;
    }
    return out.items;
}

/// Every identifier opening `zozz`, `Zozz` or `ZOZZ_` at a word boundary,
/// except a lowercase token carrying an underscore: a header's file name.
fn zozzSymbols(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var p: usize = 0;
    while (p < text.len) {
        if ((p == 0 or !isWord(text[p - 1])) and zozzPrefix(text[p..])) {
            const end = wordEnd(text, p);
            if (!fileToken(text[p..end])) try out.append(a, text[p..end]);
            p = end;
        } else p += 1;
    }
    return out.items;
}

fn zozzPrefix(s: []const u8) bool {
    return startsWithAny(s, &.{ "zozz", "Zozz", "ZOZZ_" });
}

/// `zozz`, lowercase letters or digits, then `_`: `zozz_animation`.
fn fileToken(t: []const u8) bool {
    if (!mem.startsWith(u8, t, "zozz")) return false;
    for (t[4..]) |c| {
        if (c == '_') return true;
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return false;
    }
    return false;
}

/// Every `zozz...` run, wherever it starts: what a Zig source mentions.
fn zozzMentions(a: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var from: usize = 0;
    while (mem.findPos(u8, text, from, "zozz")) |at| {
        from = wordEnd(text, at);
        try out.append(a, text[at..from]);
    }
}

/// The ozz types this package hands a caller: `Zozz<T>` in ffi/*.h, and every
/// capitalised `pub const` src/math.zig opens a line with.
fn exposedTypes(t: Tree, ffi: []const Named) !std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(t.a);
    for (ffi) |h| {
        var from: usize = 0;
        while (mem.findPos(u8, h.ref, from, "Zozz")) |at| {
            const end = wordEnd(h.ref, at);
            if (end == at + 4) {
                from = at + 1;
                continue;
            }
            try set.put(h.ref[at + 4 .. end], {});
            from = end;
        }
    }
    var lines: Lines = .init((try t.read("src/math.zig")) orelse "");
    while (lines.next()) |l| {
        if (!mem.startsWith(u8, l, "pub const ") or l.len <= 10 or !std.ascii.isUpper(l[10])) continue;
        try set.put(l[10..wordEnd(l, 10)], {});
    }
    return set;
}

//===========================================================================
// Coverage: each area's public names and the ones no entry point spells out.
//===========================================================================

/// One area that declares any public name.
const AreaResult = struct { label: []const u8, public: []const []const u8, unbound: []const []const u8 };
const Coverage = struct { areas: []const AreaResult, bound: []const []const u8 };

/// An area spec's directory under ozz/ and how deep its walk goes.
fn areaDir(a: Allocator, spec: []const u8) !struct { name: []const u8, dir: []const u8, depth: usize } {
    const name = cut(spec, ':');
    const depth = if (name.len < spec.len) try std.fmt.parseInt(usize, spec[name.len + 1 ..], 10) else max_depth;
    const dir = if (eql(name, ".")) ozz else try a.print("{s}/{s}", .{ ozz, name });
    return .{ .name = name, .dir = dir, .depth = depth };
}

/// Every area's public names, matched against every entry point. gtest_*.h
/// are ozz's own test helpers, never part of the library.
fn coverage(t: Tree) !Coverage {
    const ffi = try t.files("ffi", "", ".h");
    var entries: std.ArrayList([]const u8) = .empty;
    for (ffi) |h| try entries.appendSlice(t.a, try entryPoints(t.a, h.ref));
    const bound = unique(entries.items);
    var bound_words: std.ArrayList([]const []const u8) = .empty;
    for (bound) |b| try bound_words.append(t.a, try splitWords(t.a, b));
    const exposed = try exposedTypes(t, ffi);
    var areas: std.ArrayList(AreaResult) = .empty;
    for (area_specs) |spec| {
        const area = try areaDir(t.a, spec);
        if ((try t.kind(area.dir)) != .directory) continue;
        var scanner: MethodScanner = .{ .a = t.a, .exposed = &exposed };
        for (try t.walk(area.dir, area.depth)) |e| {
            if (e.kind == .directory or !mem.endsWith(u8, e.path, ".h")) continue;
            if (mem.startsWith(u8, basename(e.path), "gtest_")) continue;
            const text = (try t.read(e.path)) orelse continue;
            try scanner.file(text);
            var members: AccessScanner = .{ .a = t.a };
            try members.file(text);
            try scanner.names.appendSlice(t.a, members.members.items);
        }
        const public = unique(scanner.names.items);
        if (public.len == 0) continue;
        try areas.append(t.a, .{
            .label = if (eql(area.name, ".")) "ozz (root headers)" else area.name,
            .public = public,
            .unbound = try unmatched(t.a, public, bound_words.items),
        });
    }
    return .{ .areas = areas.items, .bound = bound };
}

/// AREA<TAB>NAME for every unbound name, in byte order.
fn unboundPairs(a: Allocator, cov: Coverage) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (cov.areas) |area| {
        for (area.unbound) |n| try out.append(a, try a.print("{s}\t{s}", .{ area.label, n }));
    }
    return unique(out.items);
}

/// Every unbound name, whatever its area, in byte order.
fn unboundNames(a: Allocator, cov: Coverage) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (cov.areas) |area| try out.appendSlice(a, area.unbound);
    return unique(out.items);
}

//===========================================================================
// Classification. An exclusion is legitimate only when upstream marks the
// name internal, when it has no public declaration, when every declaration
// sits under an `internal/` directory, or when the only headers declaring it
// are backed by sources build.zig does not compile. Everything else is a
// binding, a Zig facility or a gap. No judgement enters here.
//===========================================================================

/// Whether each declaration of a name sits in public scope. Every enclosing
/// scope has to be public; the access specifier is scoped to its class.
const AccessScanner = struct {
    a: Allocator,
    out: std.ArrayList(Named) = .empty,
    depth: isize = 0,
    /// Each open class scope: the depth its body opened at, and its access.
    scopes: std.ArrayList(struct { depth: isize, public: bool }) = .empty,
    in_comment: bool = false,
    /// The previous line continues a preprocessor directive, which declares
    /// no member: a macro body is not a class body.
    macro: bool = false,
    pending: bool = false,
    /// A class header seen whose `{` has not; it ends with its header.
    pendopen: bool = false,
    /// The data members declared in public scope outside `namespace
    /// internal`: what a caller sets on a builder, a job or a raw struct.
    members: std.ArrayList([]const u8) = .empty,
    /// The depth outside an open `namespace internal`.
    internal: ?isize = null,
    /// A class-body statement read so far, which may span lines.
    stmt: std.ArrayList(u8) = .empty,

    fn file(s: *AccessScanner, text: []const u8) !void {
        s.depth = 0;
        s.scopes.clearRetainingCapacity();
        s.in_comment = false;
        s.macro = false;
        s.pending = false;
        s.pendopen = false;
        s.internal = null;
        s.stmt.clearRetainingCapacity();
        var lines: Lines = .init(text);
        while (lines.next()) |raw| try s.line(raw);
    }

    /// Adds one line to the class-body statement it starts or continues.
    /// Back at the body's depth, a statement ending in `;` is read for data
    /// members and one ending in `}` (a method's body) is dropped; a class
    /// opening or closing drops it too. `in_body`: the line began there.
    fn statement(s: *AccessScanner, code: []const u8, public: bool, in_body: bool, reshaped: bool) !void {
        const n = s.scopes.items.len;
        if (n == 0 or s.pendopen or reshaped or !(in_body or s.stmt.items.len > 0)) return s.stmt.clearRetainingCapacity();
        try s.stmt.print(s.a, "{s} ", .{code});
        if (s.scopes.items[n - 1].depth != s.depth) return;
        const t = trimEnd(s.stmt.items);
        if (mem.endsWith(u8, t, ";")) {
            for (try memberNames(s.a, try s.a.dupe(u8, t))) |name| {
                try s.out.append(s.a, .{ .name = name, .ref = if (public) "public" else "nonpublic" });
                if (public and s.internal == null and harvestable(name)) try s.members.append(s.a, name);
            }
        } else if (!mem.endsWith(u8, t, "}")) return;
        s.stmt.clearRetainingCapacity();
    }

    fn line(s: *AccessScanner, raw: []const u8) !void {
        const continued = s.macro;
        s.macro = (continued or mem.startsWith(u8, trimStart(raw), "#")) and mem.endsWith(u8, trimEnd(raw), "\\");
        const code = cutText((try stripBlockComments(s.a, raw, &s.in_comment)) orelse return, "//");
        if (mem.startsWith(u8, trimStart(code), "#")) return;
        if (s.internal == null and internalNamespace(code)) s.internal = s.depth;
        const scopes_before = s.scopes.items.len;
        const in_body = scopes_before > 0 and s.scopes.items[scopes_before - 1].depth == s.depth;
        const header = afterTemplateParameters(code);
        if (keywordAt(header, &.{ "class", "struct", "union" }, true) and !mem.endsWith(u8, trimEnd(header), ";")) {
            s.pending = keywordAt(header, &.{ "struct", "union" }, false);
            s.pendopen = true;
        }
        if (accessLabel(code)) |public| {
            if (s.scopes.items.len > 0) s.scopes.items[s.scopes.items.len - 1].public = public;
            s.stmt.clearRetainingCapacity();
            return;
        }
        for (0..mem.countScalar(u8, code, '{')) |_| {
            s.depth += 1;
            if (s.pendopen) try s.scopes.append(s.a, .{ .depth = s.depth, .public = s.pending });
            s.pendopen = false;
        }
        for (0..mem.countScalar(u8, code, '}')) |_| {
            const n = s.scopes.items.len;
            if (n > 0 and s.scopes.items[n - 1].depth == s.depth) _ = s.scopes.pop();
            s.depth -= 1;
        }
        if (s.internal) |d| if (s.depth <= d) {
            s.internal = null;
        };
        const public = for (s.scopes.items) |sc| {
            if (!sc.public) break false;
        } else true;
        if (!continued) try s.statement(code, public, in_body, s.scopes.items.len != scopes_before);
        if (noFields(code)) return;
        const id = identParen(code) orelse return;
        if (id.start > 0 and mem.findScalar(u8, ".>:", code[id.start - 1]) != null) return;
        try s.out.append(s.a, .{ .name = code[id.start..id.end], .ref = if (public) "public" else "nonpublic" });
    }
};

/// Words that open a class-body line declaring no member a caller sets: a
/// `static` member in ozz is a constant.
const nonmember_keywords = [_][]const u8{
    "typedef", "using", "friend", "enum", "static", "template", "return", "class", "struct", "union", "namespace",
};

/// The names a class-body line declares as data members: a declaration
/// ending in `;` with no parameter list before its initializer (calls after
/// it are fine), each declarator's last identifier before its initializer,
/// array bound or bit width. Empty for anything else.
fn memberNames(a: Allocator, code: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const l = trimEnd(trimStart(code));
    if (!mem.endsWith(u8, l, ";") or mem.countScalar(u8, l, '(') != mem.countScalar(u8, l, ')')) return out.items;
    if (mem.findAny(u8, l[0 .. mem.findAny(u8, l, "={") orelse l.len], "()") != null) return out.items;
    if (keywordThenSpace(l, &nonmember_keywords) or !isIdentStart(l[0]) or operatorAhead(l)) return out.items;
    const body = l[0 .. l.len - 1];
    var nest: usize = 0;
    var start: usize = 0;
    for (0..body.len + 1) |i| {
        const c: u8 = if (i == body.len) ',' else body[i];
        switch (c) {
            '<', '{', '[', '(' => nest += 1,
            '>', '}', ']', ')' => nest -|= 1,
            ',' => if (nest == 0) {
                if (declaratorName(body[start..i], start == 0)) |name| try out.append(a, name);
                start = i + 1;
            },
            else => {},
        }
    }
    return out.items;
}

/// The identifier a declarator names, before its initializer, array bound
/// or bit width; the first declarator of a line also needs a type before it.
fn declaratorName(d: []const u8, typed: bool) ?[]const u8 {
    var end = d.len;
    for (d, 0..) |c, i| {
        const scope = c == ':' and ((i + 1 < d.len and d[i + 1] == ':') or (i > 0 and d[i - 1] == ':'));
        if (c == '=' or c == '{' or c == '[' or (c == ':' and !scope)) {
            end = i;
            break;
        }
    }
    const t = trimEnd(d[0..end]);
    var i = t.len;
    while (i > 0 and isWord(t[i - 1])) i -= 1;
    if (i == t.len or !isIdentStart(t[i])) return null;
    if (typed and trimEnd(t[0..i]).len == 0) return null;
    return t[i..];
}

/// Whether a data member's name passes a method's filters but the length
/// one: `IKAimJob::up` and `LocalToModelJob::to` are knobs a caller sets.
fn harvestable(name: []const u8) bool {
    if (name[0] == '_' or name[name.len - 1] == '_') return false;
    return !oneOf(name, "", &method_keywords) and !macroCase(name);
}

/// `l` past a leading `template <...>`, whose `class` and `typename` name
/// parameters rather than open a class; empty when the list runs on.
fn afterTemplateParameters(l: []const u8) []const u8 {
    const t = trimStart(l);
    if (!mem.startsWith(u8, t, "template")) return l;
    var i = skipSpace(t, "template".len);
    if (i >= t.len or t[i] != '<') return l;
    var depth: usize = 0;
    while (i < t.len) : (i += 1) switch (t[i]) {
        '<' => depth += 1,
        '>' => {
            depth -= 1;
            if (depth == 0) return t[i + 1 ..];
        },
        else => {},
    };
    return "";
}

/// Whether one of `keywords` stands at a word boundary in `l`, followed by
/// whitespace and, with `named`, by an identifier.
fn keywordAt(l: []const u8, keywords: []const []const u8, named: bool) bool {
    for (0..l.len) |i| {
        if (i > 0 and isWord(l[i - 1])) continue;
        for (keywords) |k| {
            if (!mem.startsWith(u8, l[i..], k)) continue;
            const j = skipSpace(l, i + k.len);
            if (j == i + k.len) continue;
            if (!named or (j < l.len and isIdentStart(l[j]))) return true;
        }
    }
    return false;
}

/// Names upstream marks internal: anything inside `namespace internal`, a
/// declaration under a `// Internal ...` comment, and a declaration whose
/// type names something in `internal::`. Each with the marker's FILE:LINE.
const InternalScanner = struct {
    a: Allocator,
    /// NAME<TAB>FILE:LINE<TAB>namespace|decl|type.
    out: std.ArrayList([]const u8) = .empty,

    fn file(s: *InternalScanner, path: []const u8, text: []const u8) !void {
        var depth: isize = 0;
        var nsdepth: ?isize = null;
        var nsmark: []const u8 = "";
        var pendmark: ?[]const u8 = null;
        var in_comment = false;
        var lines: Lines = .init(text);
        while (lines.next()) |raw| {
            if (internalNamespace(raw)) {
                if (nsdepth == null) {
                    nsdepth = depth;
                    nsmark = try s.a.print("{s}:{d}", .{ path, lines.number });
                }
                depth += 1;
                continue;
            }
            if (internalComment(raw)) {
                pendmark = try s.a.print("{s}:{d}", .{ path, lines.number });
                continue;
            }
            if (mem.startsWith(u8, trimStart(raw), "//")) continue;
            const code = cutText((try stripBlockComments(s.a, raw, &in_comment)) orelse continue, "//");
            depth += @as(isize, @intCast(mem.countScalar(u8, code, '{'))) - @as(isize, @intCast(mem.countScalar(u8, code, '}'))); // safe: a line read under max_file_bytes holds far fewer braces than isize can count
            if (nsdepth) |d| if (depth <= d) {
                nsdepth = null;
            };
            if (noFields(code)) continue;
            const id = identParen(code) orelse continue;
            const pre_call = id.start > 0 and mem.findScalar(u8, ".>:", code[id.start - 1]) != null;
            const name = code[id.start..id.end];
            const mark = pendmark;
            pendmark = null;
            if (pre_call or startsWithAny(name, &marker_keywords)) continue;
            const found = if (nsdepth != null)
                try s.a.print("{s}\t{s}\tnamespace", .{ name, nsmark })
            else if (mem.find(u8, code, "internal::") != null)
                try s.a.print("{s}\t{s}:{d}\ttype", .{ name, path, lines.number })
            else if (mark) |m|
                try s.a.print("{s}\t{s}\tdecl", .{ name, m })
            else
                continue;
            try s.out.append(s.a, found);
        }
    }
};

/// `namespace internal {` opening a line.
fn internalNamespace(raw: []const u8) bool {
    const l = trimStart(raw);
    if (!keywordThenSpace(l, &.{"namespace"})) return false;
    const r = trimStart(l[9..]);
    if (!mem.startsWith(u8, r, "internal")) return false;
    return mem.startsWith(u8, trimStart(r[8..]), "{");
}

/// A `// Internal ...` comment line.
fn internalComment(raw: []const u8) bool {
    const l = trimStart(raw);
    if (!mem.startsWith(u8, l, "//")) return false;
    return keywordThenSpace(trimStart(l[2..]), &.{"Internal"});
}

/// One unbound name and, when it is provable, its INTERNAL evidence.
const Classified = struct { name: []const u8, evidence: ?[]const u8 };

/// The verdict for every name of `names` that can be computed.
fn classify(t: Tree, names: []const []const u8) ![]const Classified {
    const headers = try ozzHeaders(t);
    var marked: std.StringHashMap([]const u8) = .init(t.a);
    var internal: InternalScanner = .{ .a = t.a };
    for (headers) |h| try internal.file(h.name, h.ref);
    for (unique(internal.out.items)) |l| {
        const name = field(l, 0);
        if (!marked.contains(name)) try marked.put(name, try t.a.print("upstream {s} ({s})", .{ field(l, 1), field(l, 2) }));
    }
    var public: std.StringHashMap(void) = .init(t.a);
    var batch: AccessScanner = .{ .a = t.a };
    for (headers) |h| try batch.file(h.ref);
    for (batch.out.items) |d| {
        if (eql(d.ref, "public")) try public.put(d.name, {});
    }
    const decls = try declarations(t, headers);
    const unreachable_by = try unreachableNames(t, headers, decls);
    const internal_dir = try internalDirNames(t.a, decls);
    var out: std.ArrayList(Classified) = .empty;
    for (names) |n| {
        const evidence: ?[]const u8 = if (marked.get(n)) |e|
            e
        else if (!public.contains(n))
            "no public declaration"
        else if (internal_dir.get(n)) |d|
            try t.a.print("declared only under {s}, an internal directory", .{d})
        else if (unreachable_by.get(n)) |u|
            try t.a.print("declared only by {s}, which this build does not compile", .{u})
        else
            null;
        try out.append(t.a, .{ .name = n, .evidence = evidence });
    }
    return out.items;
}

/// Every header under libs/ozz/include/ozz, read, in walk order.
fn ozzHeaders(t: Tree) ![]const Named {
    var out: std.ArrayList(Named) = .empty;
    for (try t.walk(ozz, max_depth)) |e| {
        if (e.kind == .directory or !mem.endsWith(u8, e.path, ".h")) continue;
        try out.append(t.a, .{ .name = e.path, .ref = (try t.read(e.path)) orelse continue });
    }
    return out.items;
}

/// NAME<TAB>HEADER for every declaration, public or not, each header read on
/// its own, in byte order.
fn declarations(t: Tree, headers: []const Named) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (headers) |h| {
        var s: AccessScanner = .{ .a = t.a };
        try s.file(h.ref);
        for (s.out.items) |d| try out.append(t.a, try t.a.print("{s}\t{s}", .{ d.name, h.name }));
    }
    return unique(out.items);
}

/// The names whose every declaration sits in a header this build cannot
/// reach, each with the first such header's reason.
fn unreachableNames(t: Tree, headers: []const Named, decls: []const []const u8) !std.StringHashMap([]const u8) {
    const compiled = try compiledSources(t);
    var reasons: std.StringHashMap([]const u8) = .init(t.a);
    for (headers) |h| {
        if (try uncompiledReason(t, h.name, &compiled)) |why| try reasons.put(h.name, why);
    }
    var reachable: std.StringHashMap(void) = .init(t.a);
    var first: std.StringHashMap([]const u8) = .init(t.a);
    for (decls) |d| {
        const name = field(d, 0);
        if (reasons.get(field(d, 1))) |why| {
            if (!first.contains(name)) try first.put(name, why);
        } else try reachable.put(name, {});
    }
    var out: std.StringHashMap([]const u8) = .init(t.a);
    var it = first.iterator();
    while (it.next()) |e| {
        if (!reachable.contains(e.key_ptr.*)) try out.put(e.key_ptr.*, e.value_ptr.*);
    }
    return out;
}

/// Why a header is unreachable: its own .cc is not compiled, no source
/// directory was vendored for it, or its directory has sources and none of
/// them are compiled. Null when it is reachable.
fn uncompiledReason(t: Tree, header: []const u8, compiled: *const std.StringHashMap(void)) !?[]const u8 {
    const rel = header[ozz.len + 1 ..];
    const rel_dir = if (mem.findScalarLast(u8, rel, '/')) |p| rel[0..p] else ".";
    const dir = try t.a.print("{s}/{s}", .{ ozz_src, rel_dir });
    const cc = try t.a.print("{s}/{s}.cc", .{ ozz_src, rel[0 .. rel.len - 2] });
    if ((try t.kind(cc)) == .file and !compiled.contains(cc)) return cc;
    if ((try t.kind(dir)) != .directory) return try t.a.print("no source directory vendored for {s}", .{rel_dir});
    var sources: usize = 0;
    for (try t.entries(dir)) |e| {
        if (!mem.endsWith(u8, e.path, ".cc")) continue;
        sources += 1;
        if (compiled.contains(try t.a.print("{s}/{s}", .{ dir, e.path }))) return null;
    }
    if (sources > 0) return try t.a.print("nothing in {s}", .{dir});
    return null;
}

/// Every `"libs/ozz/src/....cc"` build.zig spells out, unquoted.
fn compiledSources(t: Tree) !std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(t.a);
    const text = (try t.read("build.zig")) orelse "";
    for (try quotedSources(t.a, text)) |s| try set.put(s, {});
    return set;
}

fn quotedSources(a: Allocator, text: []const u8) ![]const []const u8 {
    const prefix = "\"" ++ ozz_src ++ "/";
    var out: std.ArrayList([]const u8) = .empty;
    var from: usize = 0;
    while (mem.findPos(u8, text, from, prefix)) |q| {
        from = q + 1;
        const k = q + prefix.len;
        var e = k;
        while (e < text.len and (isWord(text[e]) or text[e] == '/' or text[e] == '.')) e += 1;
        if (e >= text.len or text[e] != '"' or e < k + 4 or !mem.endsWith(u8, text[k..e], ".cc")) continue;
        try out.append(a, text[q + 1 .. e]);
        from = e + 1;
    }
    return out.items;
}

/// The names declared only under a path component named `internal`, ozz's
/// own spelling of the same thing its `namespace internal` says; each with
/// the last such header in byte order.
fn internalDirNames(a: Allocator, decls: []const []const u8) !std.StringHashMap([]const u8) {
    var elsewhere: std.StringHashMap(void) = .init(a);
    var under: std.StringHashMap([]const u8) = .init(a);
    for (decls) |d| {
        if (mem.find(u8, field(d, 1), "/internal/") == null) {
            try elsewhere.put(field(d, 0), {});
        } else try under.put(field(d, 0), field(d, 1));
    }
    var out: std.StringHashMap([]const u8) = .init(a);
    var it = under.iterator();
    while (it.next()) |e| {
        if (!elsewhere.contains(e.key_ptr.*)) try out.put(e.key_ptr.*, e.value_ptr.*);
    }
    return out;
}

//===========================================================================
// The gate.
//===========================================================================

/// One line of the record.
const Row = struct { area: []const u8, name: []const u8, verdict: []const u8, evidence: []const u8 };

/// Runs every check, prints the summary, and returns the exit code.
fn gate(t: Tree, r: *Report, list: bool) !u8 {
    const ffi = try t.files("ffi", "", ".h");
    var cx: Context = .{ .syms = .init(t.a), .sym_list = &.{}, .provable = .init(t.a) };
    var sym_list: std.ArrayList([]const u8) = .empty;
    for (ffi) |h| try sym_list.appendSlice(t.a, try zozzSymbols(t.a, h.ref));
    cx.sym_list = unique(sym_list.items);
    for (cx.sym_list) |s| try cx.syms.put(s, {});
    const cov = try coverage(t);
    for (try classify(t, try unboundNames(t.a, cov))) |c| {
        if (c.evidence) |e| try cx.provable.put(c.name, e);
    }
    try checkClaimed(t, r);
    const rows = try readRecord(t, r);
    try checkComplete(t.a, r, try unboundPairs(t.a, cov), rows);
    var problems: std.ArrayList([]const u8) = .empty;
    var refs: std.ArrayList(Named) = .empty;
    try checkEvidence(t.a, cx, rows, &problems, &refs);
    if (problems.items.len > 0) {
        for (problems.items) |p| try r.err.print("{s}\n", .{p});
        try r.fail("{d} unusable piece(s) of evidence", .{problems.items.len});
    }
    try checkZig(t, r, refs.items);
    try checkSurface(t, r, cov.bound);
    try summarize(t.a, r, rows, list, cov);
    if (r.fails > 0) {
        try r.err.print("\nFAIL  {d} problem(s)\n", .{r.fails});
        return 1;
    }
    try r.out.writeAll("\nOK  every public name in the claimed areas is accounted for\n");
    return 0;
}

/// A directory under libs/ozz/include/ozz no area claims fails, so a
/// re-vendor that adds one fails until the list catches up. A spec with no
/// depth limit claims its subdirectories too.
fn checkClaimed(t: Tree, r: *Report) !void {
    var dirs: std.ArrayList([]const u8) = .empty;
    for (try t.walk(ozz, max_depth)) |e| {
        if (e.kind == .directory) try dirs.append(t.a, e.path[ozz.len + 1 ..]);
    }
    var unclaimed: std.ArrayList([]const u8) = .empty;
    for (unique(dirs.items)) |d| {
        if (!claimed(d)) try unclaimed.append(t.a, d);
    }
    if (unclaimed.items.len == 0) return;
    try r.listed(unclaimed.items);
    try r.fail("{d} ozz directory(ies) missing from ci/coverage.zig", .{unclaimed.items.len});
}

fn claimed(d: []const u8) bool {
    for (area_specs) |spec| {
        const name = cut(spec, ':');
        if (eql(name, ".")) continue;
        if (eql(d, name)) return true;
        if (name.len == spec.len and mem.startsWith(u8, d, name) and d.len > name.len and d[name.len] == '/') return true;
    }
    return false;
}

/// The record's rows, every malformed line reported.
fn readRecord(t: Tree, r: *Report) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var shape: std.ArrayList([]const u8) = .empty;
    for (try t.files(record_dir, "unbound_", ".txt")) |file| {
        var lines: Lines = .init(file.ref);
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (try shapeProblem(t.a, file.name, lines.number, line)) |p| {
                try shape.append(t.a, p);
            } else try rows.append(t.a, .{ .area = field(line, 0), .name = field(line, 1), .verdict = field(line, 2), .evidence = field(line, 3) });
        }
    }
    if (shape.items.len > 0) {
        for (shape.items) |p| try r.err.print("{s}\n", .{p});
        try r.fail("{d} malformed line(s)", .{shape.items.len});
    }
    return rows.items;
}

/// What is wrong with one line of the record, or null. Evidence length is
/// counted in characters, as awk counts it.
fn shapeProblem(a: Allocator, file: []const u8, at: usize, line: []const u8) !?[]const u8 {
    if (mem.countScalar(u8, line, '\t') != 3) return try a.print("{s}:{d}: not four tab-separated fields", .{ file, at });
    const verdict = field(line, 2);
    if (!oneOf(verdict, "", &verdicts)) return try a.print("{s}:{d}: unknown verdict {s}", .{ file, at, verdict });
    if (!eql(verdict, "GAP") and characters(field(line, 3)) < 8) return try a.print("{s}:{d}: {s} has no evidence", .{ file, at, field(line, 1) });
    return null;
}

/// No name without a verdict, and no verdict for a name an entry point now
/// spells out.
fn checkComplete(a: Allocator, r: *Report, names: []const []const u8, rows: []const Row) !void {
    var pairs: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try pairs.append(a, try a.print("{s}\t{s}", .{ row.area, row.name }));
    const classified = unique(pairs.items);
    const missing = try without(a, names, classified);
    if (missing.len > 0) {
        try r.listed(missing);
        try r.fail("{d} area/name pair(s) with no verdict", .{missing.len});
    }
    const stale = try without(a, classified, names);
    if (stale.len > 0) {
        try r.listed(stale);
        try r.fail("{d} stale line(s) — an entry point now spells these out; delete them", .{stale.len});
    }
}

/// What evidence is checked against.
const Context = struct {
    /// Every zozz/Zozz/ZOZZ_ identifier ffi/*.h declares or mentions.
    syms: std.StringHashMap(void),
    sym_list: []const []const u8,
    /// The INTERNAL evidence classification computes, by name.
    provable: std.StringHashMap([]const u8),
};

/// Each verdict's evidence held to its rule; ZIG references are collected for
/// `checkZig` as NAME and REF.
fn checkEvidence(a: Allocator, cx: Context, rows: []const Row, problems: *std.ArrayList([]const u8), refs: *std.ArrayList(Named)) !void {
    for (rows) |row| {
        const v = row.verdict;
        if (eql(v, "BOUND") or eql(v, "EXTENSION")) {
            try boundEvidence(a, cx, row, problems);
        } else if (eql(v, "LANGUAGE")) {
            try languageEvidence(a, row, problems);
        } else if (eql(v, "ZIG")) {
            try zigEvidence(a, row, problems, refs);
        } else if (eql(v, "INTERNAL")) {
            if (cx.provable.get(row.name)) |e| {
                if (!eql(e, row.evidence)) try problems.append(a, try a.print("  {s}: INTERNAL evidence does not match what ci/coverage.zig --classify computes", .{row.name}));
            } else try problems.append(a, try a.print("  {s}: INTERNAL, but ci/coverage.zig --classify cannot justify it", .{row.name}));
        }
    }
}

/// BOUND and EXTENSION name zozz symbols ffi/*.h declares; `zozzFoo*` asks
/// only that some symbol starts with zozzFoo.
fn boundEvidence(a: Allocator, cx: Context, row: Row, problems: *std.ArrayList([]const u8)) !void {
    const e = row.evidence;
    var named: usize = 0;
    var p: usize = 0;
    while (p < e.len) {
        if (!zozzPrefix(e[p..])) {
            p += 1;
            continue;
        }
        const end = wordEnd(e, p);
        const tok = e[p..end];
        p = end;
        if (fileToken(tok)) continue;
        named += 1;
        if (p < e.len and e[p] == '*') {
            p += 1;
            if (!startsAny(cx.sym_list, tok)) try problems.append(a, try a.print("  {s}: nothing in ffi/*.h starts with {s}", .{ row.name, tok }));
            continue;
        }
        if (!cx.syms.contains(tok)) try problems.append(a, try a.print("  {s}: {s} is not in ffi/*.h", .{ row.name, tok }));
    }
    if (named == 0) try problems.append(a, try a.print("  {s}: {s} names no zozz symbol", .{ row.name, row.verdict }));
}

fn startsAny(items: []const []const u8, prefix: []const u8) bool {
    for (items) |i| {
        if (mem.startsWith(u8, i, prefix)) return true;
    }
    return false;
}

/// LANGUAGE names a Zig facility from a closed list; every @builtin or std.
/// token it uses has to be on that list.
fn languageEvidence(a: Allocator, row: Row, problems: *std.ArrayList([]const u8)) !void {
    const e = row.evidence;
    var hit = false;
    var p: usize = 0;
    while (p < e.len) {
        const end = facilityEnd(e, p) orelse {
            p += 1;
            continue;
        };
        const tok = e[p..end];
        p = end;
        if (startsWithAny(tok, &facilities)) {
            hit = true;
        } else try problems.append(a, try a.print("  {s}: {s} is not a facility this file recognises", .{ row.name, tok }));
    }
    if (!hit and mem.find(u8, e, "Zig slices") == null and mem.find(u8, e, "defer") == null) {
        try problems.append(a, try a.print("  {s}: LANGUAGE names no facility", .{row.name}));
    }
}

/// The end of an `@builtin` or `std.path` token starting at `p`.
fn facilityEnd(e: []const u8, p: usize) ?usize {
    var end = p;
    if (e[p] == '@') {
        end = p + 1;
        while (end < e.len and std.ascii.isAlphabetic(e[end])) end += 1;
        return if (end > p + 1) end else null;
    }
    if (!mem.startsWith(u8, e[p..], "std.")) return null;
    end = p + 4;
    while (end < e.len and (std.ascii.isAlphabetic(e[end]) or e[end] == '.')) end += 1;
    return if (end > p + 4) end else null;
}

/// ZIG names one or more declarations in src/, as src/FILE.zig:decl or
/// src/FILE.zig:container.decl; one per overload of an upstream name.
fn zigEvidence(a: Allocator, row: Row, problems: *std.ArrayList([]const u8), refs: *std.ArrayList(Named)) !void {
    var malformed = false;
    var named: usize = 0;
    var it = mem.tokenizeAny(u8, row.evidence, " \t");
    while (it.next()) |ref| {
        if (!zigRefShape(ref)) {
            try problems.append(a, try a.print("  {s}: {s} is not src/FILE.zig:decl or src/FILE.zig:container.decl", .{ row.name, ref }));
            malformed = true;
            continue;
        }
        named += 1;
        try refs.append(a, .{ .name = row.name, .ref = ref });
    }
    if (named == 0 and !malformed) try problems.append(a, try a.print("  {s}: ZIG names no declaration", .{row.name}));
}

/// `src/FILE.zig:decl` or `src/FILE.zig:container.decl`, where decl may be
/// spelled `@"name"`.
fn zigRefShape(ref: []const u8) bool {
    if (!mem.startsWith(u8, ref, "src/")) return false;
    const end = wordEnd(ref, 4);
    if (end == 4 or !mem.startsWith(u8, ref[end..], ".zig:")) return false;
    const decl = ref[end + 5 ..];
    if (declShape(decl)) return true;
    const dot = mem.findScalar(u8, decl, '.') orelse return false;
    return isIdent(decl[0..dot]) and declShape(decl[dot + 1 ..]);
}

fn declShape(d: []const u8) bool {
    if (isIdent(d)) return true;
    return d.len > 3 and mem.startsWith(u8, d, "@\"") and d[d.len - 1] == '"' and isIdent(d[2 .. d.len - 1]);
}

fn isIdent(s: []const u8) bool {
    return s.len > 0 and isIdentStart(s[0]) and wordEnd(s, 0) == s.len;
}

/// Every ZIG reference resolves: the file exists and declares the decl, and
/// `container.decl` finds it inside that container, which is what tells
/// `quaternion.mul` from `mat4.mul`.
fn checkZig(t: Tree, r: *Report, refs: []const Named) !void {
    var missing: usize = 0;
    for (refs) |ref| {
        const file = cut(ref.ref, ':');
        const decl = ref.ref[file.len + 1 ..];
        const text = (if ((try t.kind(file)) == .file) try t.read(file) else null) orelse {
            try r.err.print("  {s}: {s} does not exist\n", .{ ref.name, file });
            missing += 1;
            continue;
        };
        if (mem.findScalar(u8, decl, '.')) |dot| {
            if (containerDeclares(text, decl[0..dot], decl[dot + 1 ..])) continue;
            try r.err.print("  {s}: {s} declares no {s} inside {s}\n", .{ ref.name, file, decl[dot + 1 ..], decl[0..dot] });
        } else {
            if (zigDeclares(text, decl)) continue;
            try r.err.print("  {s}: {s} declares no {s}\n", .{ ref.name, file, decl });
        }
        missing += 1;
    }
    if (missing > 0) try r.fail("{d} ZIG line(s) pointing at nothing", .{missing});
}

/// `pub fn decl(` anywhere, or a line opening `pub fn|const|inline fn decl`
/// at a word boundary.
fn zigDeclares(text: []const u8, decl: []const u8) bool {
    var lines: Lines = .init(text);
    while (lines.next()) |l| {
        if (mem.find(u8, l, "pub fn ") != null and containsCall(l, decl)) return true;
        const rest = pubDeclRest(trimStart(l)) orelse continue;
        if (!mem.startsWith(u8, rest, decl)) continue;
        const k = decl.len;
        const before = isWord(decl[decl.len - 1]);
        const after = k < rest.len and isWord(rest[k]);
        if (before != after) return true;
    }
    return false;
}

/// Whether `l` holds `pub fn decl(`.
fn containsCall(l: []const u8, decl: []const u8) bool {
    var from: usize = 0;
    while (mem.findPos(u8, l, from, "pub fn ")) |at| {
        from = at + 1;
        const rest = l[at + 7 ..];
        if (mem.startsWith(u8, rest, decl) and rest.len > decl.len and rest[decl.len] == '(') return true;
    }
    return false;
}

/// What follows `pub fn `, `pub const ` or `pub inline fn ` opening `l`.
fn pubDeclRest(l: []const u8) ?[]const u8 {
    for ([_][]const u8{ "pub fn ", "pub const ", "pub inline fn " }) |p| {
        if (mem.startsWith(u8, l, p)) return l[p.len..];
    }
    return null;
}

/// Whether a member `m` is declared, indented, between a line opening
/// `pub const c = struct {` and the next line opening `};`.
fn containerDeclares(text: []const u8, c: []const u8, m: []const u8) bool {
    var inside = false;
    var lines: Lines = .init(text);
    while (lines.next()) |l| {
        if (mem.startsWith(u8, l, "pub const ") and mem.startsWith(u8, l[10..], c) and mem.startsWith(u8, l[10 + c.len ..], " = struct {")) {
            inside = true;
            continue;
        }
        if (inside and mem.startsWith(u8, l, "};")) inside = false;
        if (!inside or l.len == 0 or !isSpace(l[0])) continue;
        const rest = pubDeclRest(trimStart(l)) orelse continue;
        if (!mem.startsWith(u8, rest, m)) continue;
        const after = rest[m.len..];
        if (mem.startsWith(u8, after, "(") or mem.startsWith(u8, after, ":") or mem.startsWith(u8, after, " =")) return true;
    }
    return false;
}

/// The Zig surface. An entry point declared in C and never wrapped is
/// unreachable for a Zig host. src/c/ and c.zig are the extern layer; tests
/// and sweeps do not count as use.
fn checkSurface(t: Tree, r: *Report, entry_points: []const []const u8) !void {
    var calls: std.ArrayList([]const u8) = .empty;
    for (try t.walk("src", max_depth)) |e| {
        if (e.kind == .directory or !wrapperSource(e.path)) continue;
        try zozzMentions(t.a, (try t.read(e.path)) orelse continue, &calls);
    }
    var called: std.StringHashMap(void) = .init(t.a);
    for (calls.items) |c| try called.put(c, {});
    const excused = try exceptions(t, r);
    var unwrapped: std.ArrayList([]const u8) = .empty;
    for (entry_points) |e| {
        if (!called.contains(e)) try unwrapped.append(t.a, e);
    }
    const stranded = try without(t.a, unwrapped.items, excused);
    if (stranded.len > 0) {
        try r.listed(stranded);
        try r.fail("{d} entry point(s) with no Zig caller", .{stranded.len});
    }
    const excess = try without(t.a, excused, unwrapped.items);
    if (excess.len > 0) {
        try r.listed(excess);
        try r.fail("{d} excused entry point(s) that Zig does call, or that no longer exist", .{excess.len});
    }
}

/// A Zig source under src/ outside the extern layer, the tests and sweeps.
fn wrapperSource(path: []const u8) bool {
    const name = basename(path);
    if (!mem.endsWith(u8, name, ".zig") or mem.startsWith(u8, path, "src/c/")) return false;
    if (eql(name, "c.zig") or mem.endsWith(u8, name, "_test.zig")) return false;
    return mem.find(u8, name[0 .. name.len - 4], "_sweep") == null;
}

/// The names the exceptions file excuses, in byte order, each line
/// NAME<TAB>reason; malformed lines are reported.
fn exceptions(t: Tree, r: *Report) ![]const []const u8 {
    const text = (try t.read(exceptions_path)) orelse "";
    var names: std.ArrayList([]const u8) = .empty;
    var malformed: usize = 0;
    var lines: Lines = .init(text);
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (mem.countScalar(u8, line, '\t') != 1) {
            try r.err.print("  {s}: not NAME<TAB>reason\n", .{field(line, 0)});
            malformed += 1;
        } else if (characters(field(line, 1)) < 10) {
            try r.err.print("  {s}: no reason given\n", .{field(line, 0)});
            malformed += 1;
        } else try names.append(t.a, field(line, 0));
    }
    if (malformed > 0) try r.fail("{d} malformed exception line(s)", .{malformed});
    return unique(names.items);
}

/// The open gaps when asked, then the counts, then a failure per gap.
fn summarize(a: Allocator, r: *Report, rows: []const Row, list: bool, cov: Coverage) !void {
    var open: std.ArrayList(Row) = .empty;
    var counts: [verdicts.len]usize = @splat(0);
    for (rows) |row| {
        for (verdicts, 0..) |v, i| {
            if (eql(row.verdict, v)) counts[i] += 1;
        }
        if (eql(row.verdict, "GAP")) try open.append(a, row);
    }
    if (list and open.items.len > 0) {
        try r.out.writeAll("gaps\n");
        try columns(a, r.err, open.items);
        try r.out.writeAll("\n");
    }
    var bound: usize = 0;
    var public: usize = 0;
    for (cov.areas) |area| {
        public += area.public.len;
        bound += area.public.len - area.unbound.len;
    }
    try r.out.writeAll("zozz coverage\n");
    try r.out.print("  {s:<30} {d:>5}\n", .{ "entry points exported", cov.bound.len });
    try r.out.print("  {s:<30} {d:>5}\n", .{ "public ozz names, claimed areas", public });
    try r.out.print("  {s:<30} {d:>5}  spelled out by an entry point\n", .{ "  matched", bound });
    for ([_][]const u8{ "bound", "extension", "gap", "internal", "language", "zig" }) |lower| {
        for (verdicts, 0..) |v, i| {
            if (counts[i] > 0 and std.ascii.eqlIgnoreCase(v, lower)) try r.out.print("    {s:<28} {d:>5}\n", .{ lower, counts[i] });
        }
    }
    if (open.items.len > 0) try r.fail("{d} gap(s) — run with --list to see them", .{open.items.len});
}

/// AREA and NAME of each row in byte order, the first column padded to its
/// widest entry and two spaces, as `column -t` lays them out.
fn columns(a: Allocator, w: *Io.Writer, rows: []const Row) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var width: usize = 0;
    for (rows) |row| {
        try lines.append(a, try a.print("{s}\t{s}", .{ row.area, row.name }));
        width = @max(width, characters(row.area));
    }
    sortBytes(lines.items);
    for (lines.items) |l| {
        const area = field(l, 0);
        try w.writeAll(area);
        try w.splatByteAll(' ', width - characters(area) + 2);
        try w.print("{s}\n", .{field(l, 1)});
    }
}

/// Bound and public names per area; with `pattern`, the unbound names of
/// every area whose label holds it, ignoring case.
fn summary(t: Tree, out: *Io.Writer, pattern: ?[]const u8) !void {
    const cov = try coverage(t);
    try out.writeAll("zozz coverage of ozz  (by name; a work list, not a score)\n\n");
    try out.print("  {s:<34} {s:>8} {s:>8} {s:>6}\n", .{ "area", "bound", "public", "cover" });
    var total_b: usize = 0;
    var total_p: usize = 0;
    for (cov.areas) |area| {
        const p = area.public.len;
        const u = area.unbound.len;
        const b = p - u;
        try out.print("  {s:<34} {d:>8} {d:>8} {d:>5}%\n", .{ area.label, b, p, b * 100 / p });
        if (pattern) |pat| if (pat.len > 0 and std.ascii.findIgnoreCase(area.label, pat) != null) {
            for (area.unbound[0..@min(max_listed, u)]) |n| try out.print("      {s}\n", .{n});
            if (u > max_listed) try out.print("      ... {d} more\n", .{u - max_listed});
        };
        total_b += b;
        total_p += p;
    }
    const pct = if (total_p == 0) 0 else total_b * 100 / total_p;
    try out.print("\n  {s:<34} {d:>8} {d:>8} {d:>5}%\n", .{ "TOTAL", total_b, total_p, pct });
    try out.print("\n  entry points exported: {d}\n", .{cov.bound.len});
    try out.writeAll("  name matching is naive; ci/coverage.zig says what each unbound name really is\n");
    try out.writeAll("  pass --summary AREA to list what is unbound there\n");
}

//===========================================================================
// Text.
//===========================================================================

/// The lines of a text as awk reads them: split on newline, with no empty
/// line after a final newline.
const Lines = struct {
    rest: ?[]const u8,
    number: usize = 0,

    fn init(text: []const u8) Lines {
        return .{ .rest = if (text.len == 0) null else text };
    }

    fn next(l: *Lines) ?[]const u8 {
        const rest = l.rest orelse return null;
        l.number += 1;
        const at = mem.findScalar(u8, rest, '\n') orelse {
            l.rest = null;
            return rest;
        };
        l.rest = if (at + 1 == rest.len) null else rest[at + 1 ..];
        return rest[0..at];
    }
};

/// `raw` without its `/* */` spans, carrying an unterminated one to the next
/// line through `in_comment`; null for a line wholly inside one.
fn stripBlockComments(a: Allocator, raw: []const u8, in_comment: *bool) !?[]const u8 {
    var l = raw;
    if (in_comment.*) {
        const end = mem.find(u8, l, "*/") orelse return null;
        l = l[end + 2 ..];
        in_comment.* = false;
    }
    while (mem.find(u8, l, "/*")) |open| {
        const close = mem.find(u8, l[open + 2 ..], "*/") orelse {
            in_comment.* = true;
            return l[0..open];
        };
        l = try mem.concat(a, u8, &.{ l[0..open], l[open + 2 + close + 2 ..] });
    }
    return l;
}

/// Whether awk splits `l` into no fields: nothing but spaces, tabs and
/// newlines.
fn noFields(l: []const u8) bool {
    for (l) |c| {
        if (c != ' ' and c != '\t' and c != '\n') return false;
    }
    return true;
}

/// How many characters awk's `length` counts in UTF-8 text.
fn characters(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

fn basename(path: []const u8) []const u8 {
    return if (mem.findScalarLast(u8, path, '/')) |p| path[p + 1 ..] else path;
}

fn eql(x: []const u8, y: []const u8) bool {
    return mem.eql(u8, x, y);
}

/// Whether `s` is `prefix` followed by exactly one of `rest`.
fn oneOf(s: []const u8, prefix: []const u8, rest: []const []const u8) bool {
    if (!mem.startsWith(u8, s, prefix)) return false;
    for (rest) |r| {
        if (eql(s[prefix.len..], r)) return true;
    }
    return false;
}

fn startsWithAny(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (mem.startsWith(u8, s, p)) return true;
    }
    return false;
}

/// Field `n` of a tab-separated line; empty past the last.
fn field(line: []const u8, n: usize) []const u8 {
    var fields = mem.splitScalar(u8, line, '\t');
    for (0..n) |_| _ = fields.next() orelse return "";
    return fields.next() orelse "";
}

/// `s` up to the first `c`.
fn cut(s: []const u8, c: u8) []const u8 {
    return s[0 .. mem.findScalar(u8, s, c) orelse s.len];
}

/// `s` up to the first `needle`.
fn cutText(s: []const u8, needle: []const u8) []const u8 {
    return s[0 .. mem.find(u8, s, needle) orelse s.len];
}

/// The end of the run of word characters starting at `from`.
fn wordEnd(s: []const u8, from: usize) usize {
    var j = from;
    while (j < s.len and isWord(s[j])) j += 1;
    return j;
}

/// The first non-whitespace position at or after `from`.
fn skipSpace(s: []const u8, from: usize) usize {
    var j = from;
    while (j < s.len and isSpace(s[j])) j += 1;
    return j;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isSpace(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

fn trimStart(s: []const u8) []const u8 {
    return mem.trimStart(u8, s, &std.ascii.whitespace);
}

fn trimEnd(s: []const u8) []const u8 {
    return mem.trimEnd(u8, s, &std.ascii.whitespace);
}

fn sortBytes(items: [][]const u8) void {
    mem.sort([]const u8, items, {}, lessBytes);
}

fn lessBytes(_: void, x: []const u8, y: []const u8) bool {
    return mem.lessThan(u8, x, y);
}

/// `items` sorted, without repeats.
fn unique(items: [][]const u8) [][]const u8 {
    sortBytes(items);
    var n: usize = 0;
    for (items) |item| {
        if (n > 0 and eql(items[n - 1], item)) continue;
        items[n] = item;
        n += 1;
    }
    return items[0..n];
}

/// The lines of `xs` that `ys` does not hold, in the order of `xs`.
fn without(a: Allocator, xs: []const []const u8, ys: []const []const u8) ![]const []const u8 {
    var set: std.StringHashMap(void) = .init(a);
    for (ys) |y| try set.put(y, {});
    var out: std.ArrayList([]const u8) = .empty;
    for (xs) |x| {
        if (!set.contains(x)) try out.append(a, x);
    }
    return out.items;
}

//===========================================================================
// Tests.
//===========================================================================

const testing = std.testing;

/// The names one area's scanner reads from `texts`, one per line.
fn harvested(a: Allocator, exposed_names: []const []const u8, texts: []const []const u8) ![]const u8 {
    var exposed: std.StringHashMap(void) = .init(a);
    for (exposed_names) |e| try exposed.put(e, {});
    var s: MethodScanner = .{ .a = a, .exposed = &exposed };
    for (texts) |text| try s.file(text);
    var out: std.ArrayList(u8) = .empty;
    for (unique(s.names.items)) |n| try out.print(a, "{s}\n", .{n});
    return out.items;
}

/// `items` joined with commas.
fn joined(a: Allocator, items: []const []const u8) ![]const u8 {
    return mem.join(a, ",", items);
}

/// A report whose two streams are kept in memory.
const Captured = struct {
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,

    fn init(a: Allocator) Captured {
        return .{ .out = .init(a), .err = .init(a) };
    }

    fn report(c: *Captured) Report {
        return .{ .out = &c.out.writer, .err = &c.err.writer };
    }
};

/// Writes `files`, each a path and its contents, under `dir`.
fn plant(dir: Io.Dir, files: []const [2][]const u8) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |parent| try dir.createDirPath(testing.io, parent);
        try dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
    }
}

test "methods, free functions and operators on exposed types are names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\Float4x4::operator*
        \\Float4x4::operator+
        \\Float4x4::operator/
        \\Length
        \\Run
        \\
    , try harvested(arena.allocator(), &.{"Float4x4"}, &.{
        \\namespace ozz {
        \\struct Float4x4 {
        \\  Float4x4 operator*(const Float4x4& _b) const;
        \\  Float4x4& operator=(const Float4x4& _b);
        \\  void Run() const;
        \\  if (x) return;
        \\};
        \\OZZ_INLINE Float4x4 operator+(const Float4x4& _a,
        \\                              const Float4x4& _b);
        \\inline Float4x4
        \\operator-(
        \\    const Other& _a);
        \\inline Float4x4 operator/(
        \\    // the divisor
        \\    const math::Float4x4& _a);
        \\/* Prose(here) */ float Length(int x);
        \\#define MACRO(x) x
        \\  OZZ_ASSERT(Check(x));
        \\int ab(int);
        \\int _hidden(int);
        \\int MAKE_IT(int);
        \\obj.Called(1);
        \\}
    }));
}

test "a private section lasts until the next class or public label" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Visible\nnum_joints\n", try harvested(arena.allocator(), &.{}, &.{
        \\class OZZ_BASE_DLL Skeleton {
        \\ public:
        \\  int num_joints() const;
        \\ private:
        \\  void Hidden();
        \\};
        \\void AfterClass();
        \\struct Next {
        \\  void Visible();
        \\  /* Prose(here)
        \\     Spans(lines) */
        \\  Next();
        \\};
    }));
}

/// AREA: NAMES for each area `coverage` harvests from a tree of `files`.
fn treeNames(a: Allocator, files: []const [2][]const u8) ![]const u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try plant(tmp.dir, files);
    var out: std.ArrayList(u8) = .empty;
    for ((try coverage(.{ .io = testing.io, .dir = tmp.dir, .a = a })).areas) |area| {
        try out.print(a, "{s}: {s}\n", .{ area.label, try joined(a, area.public) });
    }
    return out.items;
}

test "a struct's public data members are names, its private ones are not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("base: Inline,Run,Validate,input,num_soa,settings,shown,skeleton,target,to,transform,x,y,z\n", try treeNames(arena.allocator(), &.{.{
        ozz ++ "/base/job.h",
        \\namespace ozz {
        \\struct Job {
        \\  bool Run() const;
        \\  bool operator==(const Job& _other) const;
        \\  math::SimdFloat4 target = math::simd_float4::zero();
        \\  const Skeleton* skeleton;
        \\  span<const math::SoaTransform> input;
        \\  int num_soa = 0;
        \\  int to = Skeleton::kMaxJoints;
        \\  math::Transform transform{};
        \\  typedef ozz::vector<int> Children;
        \\  static const int kMaxJoints = 1024;
        \\  enum { kOne = 1 };
        \\#define OZZ_MEMBER(_t) \
        \\  _t in_macro;
        \\  struct Settings {
        \\    bool x, y, z;  // Extract X, Y, Z components.
        \\  };
        \\  Settings settings = {true,
        \\                       false,  // Y
        \\                       true};
        \\  bool Validate(const Skeleton& _a,
        \\                const Skeleton& _b) const;
        \\  void Inline() {
        \\    float local = 0.f;
        \\  }
        \\ private:
        \\  float hidden;
        \\};
        \\class Store {
        \\  float secret;
        \\ public:
        \\  float shown;
        \\};
        \\namespace internal {
        \\struct Raw {
        \\  float keyframes;
        \\};
        \\}
        \\float global_value;
        \\}
    }}));
}

test "a builder's parameter is a name: AnimationBuilder::iframe_interval" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("animation/offline: iframe_interval\n", try treeNames(arena.allocator(), &.{.{
        ozz ++ "/animation/offline/animation_builder.h",
        \\namespace ozz {
        \\namespace animation {
        \\namespace offline {
        \\struct RawAnimation;
        \\class OZZ_ANIMOFFLINE_DLL AnimationBuilder {
        \\ public:
        \\  // Creates an Animation based on _raw_animation and *this builder parameters.
        \\  unique_ptr<Animation> operator()(const RawAnimation& _raw_animation) const;
        \\
        \\  // the interval between iframes, with a guaranteed one at the end of the
        \\  // animation (even if interval is smaller than animation duration).
        \\  float iframe_interval = 0.f;
        \\};
        \\}  // namespace offline
        \\}  // namespace animation
        \\}  // namespace ozz
    }}));
}

test "names match an entry point's words as whole words, in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("zozz,iarchive,test,animation", try joined(a, try splitWords(a, "zozzIArchiveTestAnimation")));
    try testing.expectEqualStrings("length2,sqr", try joined(a, try splitWords(a, "Length2Sqr")));
    try testing.expectEqualStrings(",x,y,", try joined(a, try splitWords(a, "_x__y_")));
    var bound: std.ArrayList([]const []const u8) = .empty;
    for ([_][]const u8{ "zozzIArchiveTestAnimation", "zozzSampleAnimationRun", "zozzMask_0" }) |b| try bound.append(a, try splitWords(a, b));
    const names = [_][]const u8{ "Tan", "SampleAnimation", "AnimationSample", "Run", "mask_0000", "mask_000f" };
    try testing.expectEqualStrings("Tan,AnimationSample,mask_000f", try joined(a, try unmatched(a, &names, bound.items)));
}

/// What an access scanner reads from `texts`, as NAME VISIBILITY lines; with
/// `batch`, one scanner reads them all, as one awk process did.
fn accessed(a: Allocator, texts: []const []const u8, batch: bool) ![]const u8 {
    var s: AccessScanner = .{ .a = a };
    var out: std.ArrayList(u8) = .empty;
    for (texts) |text| {
        if (!batch) s = .{ .a = a };
        s.out.clearRetainingCapacity();
        try s.file(text);
        for (s.out.items) |d| try out.print(a, "{s} {s}\n", .{ d.name, d.ref });
    }
    return out.items;
}

test "a declaration is public only when every enclosing scope is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\Pub public
        \\InnerPub public
        \\Priv nonpublic
        \\NestedPub nonpublic
        \\Free public
        \\
    , try accessed(arena.allocator(), &.{
        \\namespace ozz {
        \\class Foo {
        \\ public:
        \\  void Pub();
        \\  struct Inner {
        \\    void InnerPub();
        \\  };
        \\ private:
        \\  void Priv();
        \\  struct Nested {
        \\    void NestedPub();
        \\  };
        \\};
        \\void Free();  // Commented(out);
        \\}
    }, false));
}

test "nothing one header leaves open carries into the next of a batch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const texts = [_][]const u8{ "class Fwd\n", "namespace ozz {\nvoid Free();\n}\n" };
    try testing.expectEqualStrings("Free public\n", try accessed(arena.allocator(), &texts, true));
    try testing.expectEqualStrings("Free public\n", try accessed(arena.allocator(), &texts, false));
}

test "a template's parameter list opens no class" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\allocate public
        \\Get public
        \\Hidden nonpublic
        \\
    , try accessed(arena.allocator(), &.{
        \\namespace ozz {
        \\template <typename T, class U> T* allocate(U n) {
        \\  return nullptr;
        \\}
        \\template <class T>
        \\struct Box {
        \\  T Get();
        \\ private:
        \\  T Hidden();
        \\};
        \\}
    }, false));
}

test "upstream's internal markers: a namespace, a comment and a type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: InternalScanner = .{ .a = arena.allocator() };
    try s.file("h.h",
        \\namespace ozz {
        \\namespace internal {
        \\void Hidden();
        \\}
        \\// Internal helper.
        \\void Marked();
        \\void Plain();
        \\Foo<internal::Bar> Typed();
        \\// Internal use.
        \\int format_value();
        \\void Unmarked();
        \\}
    );
    try testing.expectEqualStrings("Hidden\th.h:2\tnamespace,Marked\th.h:5\tdecl,Typed\th.h:8\ttype", try joined(arena.allocator(), s.out.items));
}

test "build.zig's quoted ozz sources are the compiled ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "\"libs/ozz/src/a/b.cc\", \"libs/ozz/src/x.h\", \"libs/ozz/src/.cc\" \"libs/ozz/src/c d.cc\"\"libs/ozz/src/e.cc\"";
    try testing.expectEqualStrings("libs/ozz/src/a/b.cc,libs/ozz/src/e.cc", try joined(arena.allocator(), try quotedSources(arena.allocator(), text)));
}

test "ffi symbols, entry points and the zozz runs a Zig source mentions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "ZOZZ_API int zozzFoo(void); // zozz_core.h xzozzBar ZozzType ZOZZ zozzBar (y) xzozzBaz(";
    try testing.expectEqualStrings("ZOZZ_API,zozzFoo,ZozzType,zozzBar", try joined(a, try zozzSymbols(a, text)));
    try testing.expectEqualStrings("zozzFoo,zozzBaz", try joined(a, try entryPoints(a, text)));
    var mentions: std.ArrayList([]const u8) = .empty;
    try zozzMentions(a, "c.zozzA(); xzozzzozzB", &mentions);
    try testing.expectEqualStrings("zozzA,zozzzozzB", try joined(a, mentions.items));
}

test "each verdict's evidence is held to its own rule" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cx: Context = .{ .syms = .init(a), .sym_list = &.{ "ZozzType", "zozzA", "zozzAB" }, .provable = .init(a) };
    for (cx.sym_list) |s| try cx.syms.put(s, {});
    try cx.provable.put("Prov", "upstream x (decl)");
    const rows = [_]Row{
        .{ .area = "x", .name = "B1", .verdict = "BOUND", .evidence = "zozzA and ZozzType" },
        .{ .area = "x", .name = "B2", .verdict = "BOUND", .evidence = "zozzMissing zozz_core zozzA*" },
        .{ .area = "x", .name = "B3", .verdict = "BOUND", .evidence = "zozzQ* only" },
        .{ .area = "x", .name = "E1", .verdict = "EXTENSION", .evidence = "no symbol at all" },
        .{ .area = "x", .name = "L1", .verdict = "LANGUAGE", .evidence = "std.mem.Allocator" },
        .{ .area = "x", .name = "L2", .verdict = "LANGUAGE", .evidence = "@foo and std.io.Writer" },
        .{ .area = "x", .name = "L3", .verdict = "LANGUAGE", .evidence = "Zig slices and nothing" },
        .{ .area = "x", .name = "Z1", .verdict = "ZIG", .evidence = "src/math.zig:aCos  src/math.zig:mat4.mul" },
        .{ .area = "x", .name = "Z2", .verdict = "ZIG", .evidence = "math.zig:aCos" },
        .{ .area = "x", .name = "Z3", .verdict = "ZIG", .evidence = " \t " },
        .{ .area = "x", .name = "Prov", .verdict = "INTERNAL", .evidence = "upstream x (decl)" },
        .{ .area = "y", .name = "Prov", .verdict = "INTERNAL", .evidence = "upstream y (decl)" },
        .{ .area = "x", .name = "Nope", .verdict = "INTERNAL", .evidence = "no public declaration" },
        .{ .area = "x", .name = "G", .verdict = "GAP", .evidence = "" },
    };
    var problems: std.ArrayList([]const u8) = .empty;
    var refs: std.ArrayList(Named) = .empty;
    try checkEvidence(a, cx, &rows, &problems, &refs);
    try testing.expectEqualStrings(
        \\  B2: zozzMissing is not in ffi/*.h
        \\  B3: nothing in ffi/*.h starts with zozzQ
        \\  E1: EXTENSION names no zozz symbol
        \\  L2: @foo is not a facility this file recognises
        \\  L2: std.io.Writer is not a facility this file recognises
        \\  L2: LANGUAGE names no facility
        \\  Z2: math.zig:aCos is not src/FILE.zig:decl or src/FILE.zig:container.decl
        \\  Z3: ZIG names no declaration
        \\  Prov: INTERNAL evidence does not match what ci/coverage.zig --classify computes
        \\  Nope: INTERNAL, but ci/coverage.zig --classify cannot justify it
    , try mem.join(a, "\n", problems.items));
    try testing.expectEqual(@as(usize, 2), refs.items.len);
    try testing.expectEqualStrings("src/math.zig:mat4.mul", refs.items[1].ref);
}

test "a ZIG reference names a declaration, inside its container when it says one" {
    const text =
        \\pub fn aCos(x: f32) f32 {
        \\pub const mat4 = struct {
        \\    pub fn mul(a: Mat4) Mat4 {
        \\    pub const identity: Mat4 = .{};
        \\};
        \\pub const quaternion = struct {
        \\    pub inline fn conj(q: Quat) Quat {
        \\};
        \\pub const Mat4 = @Vector(16, f32);
        \\    pub const @"align" = 4;
        \\fn hiddenFn() void {}
    ;
    try testing.expect(zigDeclares(text, "aCos"));
    try testing.expect(zigDeclares(text, "Mat4"));
    try testing.expect(zigDeclares(text, "mul"));
    try testing.expect(!zigDeclares(text, "aCo"));
    try testing.expect(!zigDeclares(text, "hiddenFn"));
    try testing.expect(!zigDeclares(text, "@\"align\""));
    try testing.expect(containerDeclares(text, "mat4", "mul"));
    try testing.expect(containerDeclares(text, "mat4", "identity"));
    try testing.expect(containerDeclares(text, "quaternion", "conj"));
    try testing.expect(!containerDeclares(text, "quaternion", "mul"));
    try testing.expect(!containerDeclares(text, "mat4", "conj"));
    for ([_][]const u8{ "src/math.zig:aCos", "src/math.zig:mat4.mul", "src/math.zig:@\"align\"", "src/math.zig:mat4.@\"align\"" }) |ok| {
        try testing.expect(zigRefShape(ok));
    }
    for ([_][]const u8{ "src/sub/x.zig:a", "src/math.zig:a.b.c", "src/.zig:a", "src/math.zig:9a", "src/math.zig:" }) |bad| {
        try testing.expect(!zigRefShape(bad));
    }
}

test "an ozz directory no area claims fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try plant(tmp.dir, &.{
        .{ ozz ++ "/base/maths/internal/x.h", "" },
        .{ ozz ++ "/animation/offline/fbx/y.h", "" },
        .{ ozz ++ "/animation/nested/w.h", "" },
        .{ ozz ++ "/base/extra/z.h", "" },
    });
    var c: Captured = .init(a);
    var r = c.report();
    try checkClaimed(.{ .io = testing.io, .dir = tmp.dir, .a = a }, &r);
    try testing.expectEqualStrings("  animation/nested\n  base/extra\n2 ozz directory(ies) missing from ci/coverage.zig\n", c.err.written());
}

test "a malformed line of the record is refused and every pair needs one verdict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try plant(tmp.dir, &.{
        .{ record_dir ++ "/unbound_a.txt", "# a comment\n\nbase\tAlign\tLANGUAGE\tstd.mem.alignForward\nbase\tTwo\tBOUND\nbase\tBad\tMAYBE\tsomething long\n" ++
            "base\tShort\tZIG\tsrc/\nbase\tOpen\tGAP\t\nbase\tDash\tBOUND\t\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\n" },
        .{ record_dir ++ "/other.txt", "not\tthe\trecord\n" },
    });
    var c: Captured = .init(a);
    var r = c.report();
    const rows = try readRecord(.{ .io = testing.io, .dir = tmp.dir, .a = a }, &r);
    try checkComplete(a, &r, &.{ "base\tAlign", "base\tMissing" }, rows);
    try testing.expectEqualStrings(
        \\ci/coverage/unbound_a.txt:4: not four tab-separated fields
        \\ci/coverage/unbound_a.txt:5: unknown verdict MAYBE
        \\ci/coverage/unbound_a.txt:6: Short has no evidence
        \\ci/coverage/unbound_a.txt:8: Dash has no evidence
        \\4 malformed line(s)
        \\
    ++ "  base\tMissing\n1 area/name pair(s) with no verdict\n" ++
        "  base\tOpen\n1 stale line(s) — an entry point now spells these out; delete them\n", c.err.written());
}

test "an entry point no Zig source calls is stranded, unless excused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try plant(tmp.dir, &.{
        .{ "src/a.zig", "c.zozzA();\n" },
        .{ "src/c.zig", "pub extern fn zozzB() void;\n" },
        .{ "src/c/x.zig", "zozzB" },
        .{ "src/a_test.zig", "c.zozzB();\n" },
        .{ "src/b_sweep2.zig", "zozzB" },
        .{ "src/sub/d.zig", "zozzC" },
        .{ exceptions_path, "# header\nzozzA\tcalled after all, so not excusable\nzozzQ\tshort\nzozzD\tthe reason is long enough\nbad line\n" },
    });
    var c: Captured = .init(a);
    var r = c.report();
    try checkSurface(.{ .io = testing.io, .dir = tmp.dir, .a = a }, &r, &.{ "zozzA", "zozzB", "zozzC", "zozzD" });
    try testing.expectEqualStrings(
        \\  zozzQ: no reason given
        \\  bad line: not NAME<TAB>reason
        \\2 malformed exception line(s)
        \\  zozzB
        \\1 entry point(s) with no Zig caller
        \\  zozzA
        \\1 excused entry point(s) that Zig does call, or that no longer exist
        \\
    , c.err.written());
}

test "an exclusion is computed from upstream's markers, access and the build" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try plant(tmp.dir, &.{
        .{ "build.zig", "    \"libs/ozz/src/a/one.cc\",\n" },
        .{ ozz ++ "/a/one.h", "void Reach();\nvoid Both();\n// Internal x\nvoid Marked();\n" },
        .{ ozz_src ++ "/a/one.cc", "" },
        .{ ozz ++ "/a/two.h", "void Cold();\nvoid Both();\n" },
        .{ ozz_src ++ "/a/two.cc", "" },
        .{ ozz ++ "/a/seven.h", "void Open();\n" },
        .{ ozz ++ "/b/three.h", "void Far();\n" },
        .{ ozz ++ "/c/internal/four.h", "void Deep();\n" },
        .{ ozz_src ++ "/c/internal/keep", "" },
        .{ ozz ++ "/d/five.h", "class Five {\n  void Priv();\n};\n" },
        .{ ozz ++ "/e/six.h", "void Nothing();\n" },
        .{ ozz_src ++ "/e/other.cc", "" },
    });
    const names = [_][]const u8{ "Both", "Cold", "Deep", "Far", "Marked", "Nothing", "Open", "Priv", "Reach" };
    var out: std.ArrayList(u8) = .empty;
    for (try classify(.{ .io = testing.io, .dir = tmp.dir, .a = a }, &names)) |c| try out.print(a, "{s} | {s}\n", .{ c.name, c.evidence orelse "OPEN" });
    try testing.expectEqualStrings(
        \\Both | OPEN
        \\Cold | declared only by libs/ozz/src/a/two.cc, which this build does not compile
        \\Deep | declared only under libs/ozz/include/ozz/c/internal/four.h, an internal directory
        \\Far | declared only by no source directory vendored for b, which this build does not compile
        \\Marked | upstream libs/ozz/include/ozz/a/one.h:3 (decl)
        \\Nothing | declared only by nothing in libs/ozz/src/e, which this build does not compile
        \\Open | OPEN
        \\Priv | no public declaration
        \\Reach | OPEN
        \\
    , out.items);
}

test "the gate on a whole tree: a gap is listed, counted and fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try plant(tmp.dir, &.{
        .{ "ffi/zozz.h", "ZOZZ_API void zozzSkeletonRun(void);\n" },
        .{ "src/x.zig", "pub fn run() void {\n    c.zozzSkeletonRun();\n}\n" },
        .{ "src/math.zig", "" },
        .{ "build.zig", "" },
        .{ ozz ++ "/base/a.h", "void Run();\nvoid Spare();\n" },
        .{ record_dir ++ "/unbound_base.txt", "base\tSpare\tGAP\t\n" },
        .{ exceptions_path, "" },
    });
    var c: Captured = .init(a);
    var r = c.report();
    try testing.expectEqual(@as(u8, 1), try run(.{ .io = testing.io, .dir = tmp.dir, .a = a }, &r, &.{ "coverage", "--list" }));
    try testing.expectEqualStrings(
        \\gaps
        \\
        \\zozz coverage
        \\  entry points exported              1
        \\  public ozz names, claimed areas     2
        \\    matched                          1  spelled out by an entry point
        \\    gap                              1
        \\
    , c.out.written());
    try testing.expectEqualStrings("base  Spare\n1 gap(s) — run with --list to see them\n\nFAIL  1 problem(s)\n", c.err.written());
}

test "a line wholly inside a block comment is not read at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in_comment = false;
    try testing.expectEqualStrings("a  b ", (try stripBlockComments(a, "a /* x */ b /* open", &in_comment)).?);
    try testing.expect(in_comment);
    try testing.expectEqual(@as(?[]const u8, null), try stripBlockComments(a, "still inside", &in_comment));
    try testing.expectEqualStrings(" c", (try stripBlockComments(a, "end */ c", &in_comment)).?);
    try testing.expect(!in_comment);
    var lines: Lines = .init("one\ntwo\n");
    try testing.expectEqualStrings("one", lines.next().?);
    try testing.expectEqualStrings("two", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}
