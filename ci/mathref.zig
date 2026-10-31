//! Every public function of src/math.zig either faces the compiled ozz in
//! src/mathref_test.zig, or has a verdict in ci/mathref/undifferentiated.txt
//! with the reason it cannot. src/math.zig is a hand port; its other tests
//! compare it with itself, which cannot see a transcription wrong the same
//! way twice. It counts DECLARATIONS (`pub fn`, as container.name or name),
//! not behaviour, and reads the differential test lexically through the
//! container aliases at its top, so a name in a comment counts. A `pub const`
//! value is not a function and is not counted. Fails on a function with no
//! verdict, a verdict for a tested function, a verdict naming no function,
//! and a malformed verdict line. `--list` prints the untested functions and
//! their reasons first. Run from the repository root.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

const math_path = "src/math.zig";
const reference_path = "src/mathref_test.zig";
const verdict_path = "ci/mathref/undifferentiated.txt";
/// The largest file read.
const max_file_bytes = 1 << 22;
/// The shortest reason a verdict may give, in characters.
const min_reason = 20;

const Names = []const []const u8;
const Sources = struct { math: []const u8, reference: []const u8, verdicts: []const u8 };
/// What a run prints: `problems` on stderr, then `summary` on stdout, then
/// the outcome line, and whether it failed.
const Report = struct { problems: std.ArrayList(u8) = .empty, summary: std.ArrayList(u8) = .empty, fails: usize = 0 };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(a);
    const list = args.len > 1 and std.mem.eql(u8, args[1], "--list");
    const sources: Sources = .{
        .math = try aegis.own.readFile(io, cwd, math_path, a, .fromRaw(max_file_bytes)),
        .reference = try aegis.own.readFile(io, cwd, reference_path, a, .fromRaw(max_file_bytes)),
        .verdicts = try aegis.own.readFile(io, cwd, verdict_path, a, .fromRaw(max_file_bytes)),
    };
    const report = try run(a, sources, list);
    var err_buffer: [4096]u8 = undefined;
    var out_buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &err_buffer);
    var stdout = Io.File.stdout().writer(io, &out_buffer);
    try stderr.interface.writeAll(report.problems.items);
    try stderr.interface.flush();
    try stdout.interface.writeAll(report.summary.items);
    if (report.fails == 0) {
        try stdout.interface.writeAll("\nOK  every public maths function is tested against ozz or explained\n");
        try stdout.interface.flush();
        return 0;
    }
    try stdout.interface.flush();
    try stderr.interface.print("\nFAIL  {d} problem(s)\n", .{report.fails});
    try stderr.interface.flush();
    return 1;
}

/// Compares what src/math.zig declares with what the differential test
/// reaches and what the verdicts explain.
fn run(a: std.mem.Allocator, sources: Sources, list: bool) !Report {
    var r: Report = .{};
    const declared = try declarations(a, sources.math);
    const reached = try reachedNames(a, sources.reference);
    const covered = try common(a, declared, reached);
    const uncovered = try minus(a, declared, reached);
    const listed = try verdicts(a, sources.verdicts, &r);
    try group(a, &r, try minus(a, uncovered, listed), "function(s) neither differentially tested nor explained");
    try group(a, &r, try common(a, covered, listed), "stale line(s) \u{2014} these ARE tested now; delete them");
    try group(a, &r, try minus(a, listed, declared), "line(s) naming no public function in " ++ math_path);
    const out = &r.summary;
    if (list and uncovered.len != 0) {
        try out.appendSlice(a, "not differentially tested\n");
        for (uncovered) |name| {
            try out.appendSlice(a, "  ");
            try padded(a, out, name, 28);
            try out.print(a, " {s}\n", .{try reasonOf(a, sources.verdicts, name)});
        }
        try out.appendSlice(a, "\n");
    }
    try out.appendSlice(a, "zozz differential maths coverage\n");
    try row(a, out, "public functions in " ++ math_path, declared.len, "");
    try row(a, out, "  covered", covered.len, "faced against compiled ozz");
    try row(a, out, "  explained", uncovered.len, "with a reason on record");
    return r;
}

/// Reports `names`, one per line, and one failure counting them.
fn group(a: std.mem.Allocator, r: *Report, names: Names, what: []const u8) !void {
    if (names.len == 0) return;
    for (names) |name| try r.problems.print(a, "  {s}\n", .{name});
    try r.problems.print(a, "{d} {s}\n", .{ names.len, what });
    r.fails += 1;
}

fn row(a: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, count: usize, note: []const u8) !void {
    try out.appendSlice(a, "  ");
    try padded(a, out, label, 34);
    try out.print(a, " {d:>5}", .{count});
    if (note.len != 0) try out.print(a, "  {s}", .{note});
    try out.append(a, '\n');
}

/// Appends `text` and spaces up to `width` bytes.
fn padded(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    try out.appendSlice(a, text);
    if (text.len < width) try out.appendNTimes(a, ' ', width - text.len);
}

/// Every `pub fn` and `pub inline fn` of `source`: `name` at column 0, and
/// `container.name` indented inside a column-0 `pub const container = struct {`
/// up to the next column-0 `};`. Sorted and unique.
fn declarations(a: std.mem.Allocator, source: []const u8) !Names {
    var names: std.ArrayList([]const u8) = .empty;
    var container: []const u8 = "";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (structName(line)) |name| {
            container = name;
            continue;
        }
        if (std.mem.startsWith(u8, line, "};")) container = "";
        if (container.len != 0 and line.len != 0 and (line[0] == ' ' or line[0] == '\t')) {
            if (functionName(std.mem.trimStart(u8, line, " \t"))) |name| {
                try names.append(a, try unquote(a, try a.print("{s}.{s}", .{ container, name })));
                continue;
            }
        }
        if (functionName(line)) |name| try names.append(a, try unquote(a, name));
    }
    return sortUnique(names.items);
}

/// The name of `pub const name = struct {` at the start of `line`.
fn structName(line: []const u8) ?[]const u8 {
    const prefix = "pub const ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const end = identifierEnd(line, prefix.len);
    if (end == prefix.len or !std.mem.startsWith(u8, line[end..], " = struct {")) return null;
    return line[prefix.len..end];
}

/// What follows `pub fn ` or `pub inline fn ` at the start of `line`, up to
/// the first `(` or `:`.
fn functionName(line: []const u8) ?[]const u8 {
    const rest = for ([_][]const u8{ "pub fn ", "pub inline fn " }) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) break line[prefix.len..];
    } else return null;
    return rest[0 .. std.mem.findAny(u8, rest, "(:") orelse rest.len];
}

/// `text` without its `@"` and `"`.
fn unquote(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '"') continue;
        if (text[index] == '@' and index + 1 < text.len and text[index + 1] == '"') {
            index += 1;
            continue;
        }
        try out.append(a, text[index]);
    }
    return out.items;
}

/// Every math.zig name `source` spells: `alias.member` for each
/// `const alias = math.container;` line, `math.container.member`, and
/// `adapt(math.name)`. Sorted and unique.
fn reachedNames(a: std.mem.Allocator, source: []const u8) !Names {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const alias = aliasOf(line) orelse continue;
        try scanAlias(a, source, alias.name, alias.container, &names);
    }
    var at: usize = 0;
    while (std.mem.findPos(u8, source, at, "math.")) |start| {
        at = start + 1;
        const run_end = lowerEnd(source, start + "math.".len);
        if (run_end == start + "math.".len or run_end == source.len or source[run_end] != '.') continue;
        const m = member(source, run_end + 1) orelse continue;
        try names.append(a, try a.print("{s}.{s}", .{ source[start + "math.".len .. run_end], m.name }));
        at = m.end;
    }
    at = 0;
    const adapt = "adapt(math.";
    while (std.mem.findPos(u8, source, at, adapt)) |start| {
        at = start + 1;
        const end = identifierEnd(source, start + adapt.len);
        if (end == start + adapt.len or end == source.len or source[end] != ')') continue;
        try names.append(a, source[start + adapt.len .. end]);
        at = end + 1;
    }
    return sortUnique(names.items);
}

const Alias = struct { name: []const u8, container: []const u8 };

/// The alias a whole `line` of the form `const alias = math.container;`
/// declares, both of `[a-z0-9_]`. A line with no alias name is not Zig.
fn aliasOf(line: []const u8) ?Alias {
    const prefix = "const ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const name_end = lowerEnd(line, prefix.len);
    const middle = " = math.";
    if (name_end == prefix.len or !std.mem.startsWith(u8, line[name_end..], middle)) return null;
    const start = name_end + middle.len;
    const end = lowerEnd(line, start);
    if (end + 1 != line.len or line[end] != ';') return null;
    return .{ .name = line[prefix.len..name_end], .container = line[start..end] };
}

/// Appends `container.member` for every `alias.member` of `source` that
/// starts a word.
fn scanAlias(a: std.mem.Allocator, source: []const u8, alias: []const u8, container: []const u8, names: *std.ArrayList([]const u8)) !void {
    var at: usize = 0;
    while (std.mem.findPos(u8, source, at, alias)) |start| {
        at = start + 1;
        if (start > 0 and word(source[start - 1])) continue;
        const dot = start + alias.len;
        if (dot == source.len or source[dot] != '.') continue;
        const m = member(source, dot + 1) orelse continue;
        try names.append(a, try a.print("{s}.{s}", .{ container, m.name }));
        at = m.end;
    }
}

/// An identifier or `@"identifier"` at `start`: its name and where it ends.
fn member(source: []const u8, start: usize) ?struct { name: []const u8, end: usize } {
    if (std.mem.startsWith(u8, source[start..], "@\"")) {
        const end = identifierEnd(source, start + 2);
        if (end == start + 2 or end == source.len or source[end] != '"') return null;
        return .{ .name = source[start + 2 .. end], .end = end + 1 };
    }
    const end = identifierEnd(source, start);
    if (end == start) return null;
    return .{ .name = source[start..end], .end = end };
}

/// The end of the `[A-Za-z_][A-Za-z0-9_]*` at `start`, or `start`.
fn identifierEnd(text: []const u8, start: usize) usize {
    if (start >= text.len or !(std.ascii.isAlphabetic(text[start]) or text[start] == '_')) return start;
    var end = start + 1;
    while (end < text.len and word(text[end])) end += 1;
    return end;
}

/// The end of the `[a-z0-9_]*` at `start`.
fn lowerEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and (std.ascii.isLower(text[end]) or std.ascii.isDigit(text[end]) or text[end] == '_')) end += 1;
    return end;
}

fn word(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// The names the verdicts explain: `NAME<TAB>REASON` lines, `#` lines and
/// empty lines skipped. A malformed line is reported and explains nothing;
/// one failure counts them. Sorted and unique.
fn verdicts(a: std.mem.Allocator, text: []const u8, r: *Report) !Names {
    var names: std.ArrayList([]const u8) = .empty;
    var malformed: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const tab = std.mem.findScalar(u8, line, '\t');
        if (tab == null or std.mem.findScalarPos(u8, line, tab.? + 1, '\t') != null) {
            try r.problems.print(a, "  {s}: not NAME<TAB>reason\n", .{line});
            malformed += 1;
        } else if (characters(line[tab.? + 1 ..]) < min_reason) {
            try r.problems.print(a, "  {s}: no reason given\n", .{line[0..tab.?]});
            malformed += 1;
        } else try names.append(a, line[0..tab.?]);
    }
    if (malformed != 0) {
        try r.problems.print(a, "{d} malformed line(s) in " ++ verdict_path ++ "\n", .{malformed});
        r.fails += 1;
    }
    return sortUnique(names.items);
}

/// The length of `text` in characters, or in bytes when it is not UTF-8.
fn characters(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// The reasons of every verdict line whose name is `name`, one per line.
fn reasonOf(a: std.mem.Allocator, text: []const u8, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        if (!std.mem.eql(u8, fields.first(), name)) continue;
        try out.appendSlice(a, fields.next() orelse "");
        try out.append(a, '\n');
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// `names` in byte order with repeats removed, in place.
fn sortUnique(names: [][]const u8) Names {
    std.mem.sort([]const u8, names, {}, lessThan);
    var kept: usize = 0;
    for (names) |name| {
        if (kept != 0 and std.mem.eql(u8, names[kept - 1], name)) continue;
        names[kept] = name;
        kept += 1;
    }
    return names[0..kept];
}

/// The names of sorted `left` that sorted `right` also holds.
fn common(a: std.mem.Allocator, left: Names, right: Names) !Names {
    return merge(a, left, right, true);
}

/// The names of sorted `left` that sorted `right` does not hold.
fn minus(a: std.mem.Allocator, left: Names, right: Names) !Names {
    return merge(a, left, right, false);
}

fn merge(a: std.mem.Allocator, left: Names, right: Names, keep_shared: bool) !Names {
    var out: std.ArrayList([]const u8) = .empty;
    var j: usize = 0;
    for (left) |name| {
        while (j < right.len and std.mem.lessThan(u8, right[j], name)) j += 1;
        const shared = j < right.len and std.mem.eql(u8, right[j], name);
        if (shared == keep_shared) try out.append(a, name);
    }
    return out.items;
}

/// Spaces, sliced to a width in the expected reports.
const blank = "                                        ";

fn expectNames(want: []const []const u8, have: Names) !void {
    try std.testing.expectEqual(want.len, have.len);
    for (want, have) |w, h| try std.testing.expectEqualStrings(w, h);
}

test "declarations: containers, inline, quoted names, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\pub const vec = struct {
        \\    pub fn add(a: f32) f32 {}
        \\    pub inline fn @"and"(a: f32) f32 {}
        \\    fn hidden() void {}
        \\    pub const one = 1;
        \\};
        \\pub fn Rect(comptime T: type) type {
        \\    return struct {
        \\        pub fn width(r: @This()) T {}
        \\    };
        \\}
        \\pub const Packed = extern struct {
        \\    pub fn field() void {}
        \\};
        \\pub fn top() void {}
        \\pub noinline fn skipped() void {}
        \\pub fn top() void {}
    ;
    try expectNames(&.{ "Rect", "top", "vec.add", "vec.and" }, try declarations(arena.allocator(), source));
}

test "reached: aliases on a word start, math paths and adapted functions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\const sf = math.simd_float4;
        \\const q = math.quaternion; // not an alias: the line goes on
        \\x(sf.mAdd, sf.@"and", xsf.missed, a.sf.dotted, q.missed);
        \\y(math.mat4.mul, math.Box.missed, math.mat4.@"or", adapt(math.lerp), adapt(math.box.no));
        \\sf.@"open
    ;
    try expectNames(&.{ "box.no", "lerp", "mat4.mul", "mat4.or", "simd_float4.and", "simd_float4.dotted", "simd_float4.mAdd" }, try reachedNames(arena.allocator(), source));
}

test "a gap, a stale verdict, a phantom and malformed lines each fail once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sources: Sources = .{
        .math = "pub fn tested() void {}\npub fn untested() void {}\npub fn explained() void {}\n",
        .reference = "_ = adapt(math.tested);\n",
        .verdicts = "# comment\n\nexplained\ta reason that is long enough\ntested\talso a long enough reason here\n" ++
            "gone\tthis function was deleted long ago\nshort\ttoo short\nno tab here\n",
    };
    const r = try run(arena.allocator(), sources, false);
    try std.testing.expectEqualStrings(
        "  short: no reason given\n  no tab here: not NAME<TAB>reason\n2 malformed line(s) in ci/mathref/undifferentiated.txt\n" ++
            "  untested\n1 function(s) neither differentially tested nor explained\n" ++
            "  tested\n1 stale line(s) \u{2014} these ARE tested now; delete them\n" ++
            "  gone\n1 line(s) naming no public function in src/math.zig\n",
        r.problems.items,
    );
    try std.testing.expectEqual(4, r.fails);
    try std.testing.expectEqualStrings("zozz differential maths coverage\n" ++
        "  public functions in src/math.zig" ++ blank[0..7] ++ "3\n" ++
        "    covered" ++ blank[0..30] ++ "1  faced against compiled ozz\n" ++
        "    explained" ++ blank[0..28] ++ "2  with a reason on record\n", r.summary.items);
}

test "--list prints each untested function with its reason" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sources: Sources = .{
        .math = "pub fn b() void {}\npub fn a() void {}\n",
        .reference = "",
        .verdicts = "a\tthe first reason, long enough\nb\tthe second reason, long enough\n",
    };
    const r = try run(arena.allocator(), sources, true);
    try std.testing.expectEqual(0, r.fails);
    try std.testing.expect(std.mem.startsWith(u8, r.summary.items, "not differentially tested\n" ++
        "  a" ++ blank[0..28] ++ "the first reason, long enough\n" ++
        "  b" ++ blank[0..28] ++ "the second reason, long enough\n\nzozz"));
}
