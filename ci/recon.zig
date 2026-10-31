//! What a binder needs to know about an ozz class, on one screen
//! (`zig build recon -- <Class or header path>`). The facts that decide
//! whether a binding is correct are not in the signatures: an `assert` in a
//! method body, a getter that returns a default instead of failing, a
//! private member, an enum that cannot be mirrored. This prints those lines
//! from the header and its `.cc`, each with its line number, so the reading
//! is a page instead of a file. A lead generator, not an oracle: it cannot
//! find a precondition nobody wrote down. Run from the repository root.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

const ozz = "libs/ozz";
const include = ozz ++ "/include/ozz";
/// The largest file read.
const max_file_bytes = 1 << 22;
/// Lines shown per section before the rest is summarised.
const shown_asserts = 40;
const shown_defaults = 15;
const shown_private = 20;
const shown_enums = 15;
const shown_methods = 60;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    if (args.len != 2) {
        try out.writeAll("usage: zig build recon -- <Class | path to an ozz header>\n");
        try out.flush();
        return 2;
    }
    const cwd = Io.Dir.cwd();
    const located = try locate(a, io, cwd, args[1]) orelse {
        try out.print("no header in {s} defines `{s}`; try a path, or check the spelling\n", .{ include, args[1] });
        try out.flush();
        return 1;
    };
    const header = try aegis.own.readFile(io, cwd, located.header, a, .fromRaw(max_file_bytes));
    // ozz keeps implementations under src/, not beside the header, as .cc.
    const source_path = try sourceOf(a, located.header);
    const source: ?[]const u8 = aegis.own.readFile(io, cwd, source_path, a, .fromRaw(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };

    try out.print("{s}  {s}\n", .{ located.name, located.header });
    if (source != null) try out.print("          {s}\n", .{source_path});

    // Each line here changes how the binding is written.
    try section(out, "Kind");
    const declaration = findDeclaration(header, located.name);
    if (declaration) |line| try out.print("  {d}:{s}\n", .{ line.number, line.text }) else try out.writeAll("  (declaration not found)\n");
    if (hasPureVirtual(header)) try out.writeAll("  ABSTRACT — has pure virtuals; it cannot be constructed directly.\n");

    // An assert is a precondition the signature does not state, and a binding
    // that forwards a call without checking it turns a caller mistake into a
    // process abort, or into undefined behaviour once NDEBUG removes it.
    try section(out, "Preconditions (assert) — a caller can trip these");
    var asserts: Shown = .{ .limit = shown_asserts };
    try asserts.scan(out, located.header, header, isAssert);
    if (source) |text| try asserts.scan(out, source_path, text, isAssert);
    try asserts.finish(out);

    // A getter that returns a default when it cannot answer looks like
    // success at the C boundary; the binding forwards it and says so.
    try section(out, "Silent defaults — a failure path that looks like success");
    var defaults: Shown = .{ .limit = shown_defaults };
    if (source) |text| try defaults.scan(out, source_path, text, isSilentDefault);
    try defaults.scan(out, located.header, header, isSilentDefault);
    try defaults.finish(out);

    // zozz does not pass -fno-access-control, so a private member is a wall
    // and the binding has to find the public way in.
    try section(out, "Private / protected — no -fno-access-control here");
    var private: Shown = .{ .limit = shown_private };
    try private.scanAccess(out, located.header, header, .hidden);
    try private.finish(out);

    // zozz mirrors these, and its ABI check refuses a negative enumerator: C
    // leaves an enum's underlying type to the implementation. See BINDING.md.
    try section(out, "Enums to mirror");
    var enums: Shown = .{ .limit = shown_enums };
    try enums.scan(out, located.header, header, isEnum);
    try enums.finish(out);
    var negatives: Shown = .{ .limit = std.math.maxInt(usize), .quiet = true };
    try negatives.scan(out, located.header, header, isNegativeValue);
    if (enums.seen != 0 and negatives.seen != 0) {
        try out.writeAll("  NEGATIVE VALUE PRESENT — if it is an enumerator, it cannot be\n    mirrored as a C enum. Use a fixed-width constant instead.\n");
        negatives.quiet = false;
        negatives.seen = 0;
        try negatives.scan(out, located.header, header, isNegativeValue);
    }

    try section(out, "Public methods");
    var methods: Shown = .{ .limit = shown_methods, .plain = true };
    try methods.scanAccess(out, located.header, header, .public);
    try methods.finish(out);

    try out.writeAll("\nthen read the header. This narrows the reading; it does not replace it.\n");
    try out.flush();
    return 0;
}

const Located = struct { header: []const u8, name: []const u8 };

/// The header `argument` names: a path under libs/ozz or from the root, a
/// header named after the class, or the header that defines the class.
fn locate(a: std.mem.Allocator, io: Io, root: Io.Dir, argument: []const u8) !?Located {
    for ([_][]const u8{ try a.print("{s}/{s}", .{ ozz, argument }), argument }) |path| {
        if (std.mem.endsWith(u8, path, ".h") and exists(io, root, path)) return .{ .header = path, .name = std.Io.Dir.path.stem(path) };
    }
    var dir = try root.openDir(io, include, .{ .iterate = true });
    defer dir.close(io);
    var named: ?[]const u8 = null;
    var defining: ?[]const u8 = null;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".h")) continue;
        const path = try a.print("{s}/{s}", .{ include, entry.path });
        std.mem.replaceScalar(u8, path, '\\', '/');
        if (named == null and std.mem.eql(u8, std.Io.Dir.path.stem(entry.basename), argument)) named = path;
        if (defining == null and findDeclaration(try aegis.own.readFile(io, dir, entry.path, a, .fromRaw(max_file_bytes)), argument) != null) defining = path;
    }
    // A file named after the class first; otherwise the class has to be
    // DEFINED there, never only forward-declared.
    const header = named orelse defining orelse return null;
    return .{ .header = header, .name = argument };
}

fn exists(io: Io, root: Io.Dir, path: []const u8) bool {
    _ = root.statFile(io, path, .{}) catch return false;
    return true;
}

/// libs/ozz/include/ozz/x/y.h → libs/ozz/src/x/y.cc.
fn sourceOf(a: std.mem.Allocator, header: []const u8) ![]const u8 {
    const marker = "/include/ozz/";
    const at = std.mem.find(u8, header, marker) orelse return a.dupe(u8, header);
    const stem = header[at + marker.len .. header.len - ".h".len];
    return a.print("{s}/src/{s}.cc", .{ header[0..at], stem });
}

const Line = struct { number: usize, text: []const u8 };

/// The line that defines `class Name` or `struct Name` (an `OZZ_*` export
/// macro allowed between), not one that forward-declares it: a line ending
/// in `;` is a promise that the definition is elsewhere.
fn findDeclaration(text: []const u8, name: []const u8) ?Line {
    var number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (defines(line, name)) return .{ .number = number, .text = line };
    }
    return null;
}

fn defines(line: []const u8, name: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const keyword = words.next() orelse return false;
    if (!std.mem.eql(u8, keyword, "class") and !std.mem.eql(u8, keyword, "struct")) return false;
    var word = words.next() orelse return false;
    if (std.mem.startsWith(u8, word, "OZZ_")) word = words.next() orelse return false;
    if (!std.mem.startsWith(u8, word, name)) return false;
    if (word.len > name.len and isWordChar(word[name.len])) return false;
    return std.mem.findScalar(u8, line, ';') == null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// A pure virtual is `virtual ... = 0;`. A bare `= 0;` is also every default
/// member initialiser, which would call a concrete settings struct abstract.
fn hasPureVirtual(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.find(u8, line, "virtual") orelse continue;
        const rest = line[at..];
        const semicolon = std.mem.findScalar(u8, rest, ';') orelse continue;
        const before = std.mem.trimEnd(u8, rest[0..semicolon], " \t");
        if (!std.mem.endsWith(u8, before, "0")) continue;
        const equals = std.mem.trimEnd(u8, before[0 .. before.len - 1], " \t");
        if (std.mem.endsWith(u8, equals, "=")) return true;
    }
    return false;
}

fn isAssert(line: []const u8) bool {
    return std.mem.find(u8, line, "assert") != null and std.mem.find(u8, line, "assert(false") == null;
}

fn isSilentDefault(line: []const u8) bool {
    const at = std.mem.find(u8, line, "return") orelse return false;
    const rest = line[at + "return".len ..];
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return false;
    for ([_][]const u8{ "sDefault", "sZero", "sIdentity", "Default()", "sInvalid" }) |marker| {
        if (std.mem.find(u8, rest, marker) != null) return true;
    }
    return false;
}

fn isEnum(line: []const u8) bool {
    const body = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, body, "enum class")) return false;
    const rest = std.mem.trimStart(u8, body["enum class".len..], " \t");
    return rest.len < body.len - "enum class".len and rest.len != 0 and std.ascii.isAlphabetic(rest[0]);
}

fn isNegativeValue(line: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, line, from, '=')) |at| : (from = at + 1) {
        const rest = std.mem.trimStart(u8, line[at + 1 ..], " \t");
        if (rest.len >= 2 and rest[0] == '-' and std.ascii.isDigit(rest[1])) return true;
    }
    return false;
}

const Access = enum { public, hidden };

/// Lines printed under one heading, up to a limit, with a count of the rest.
const Shown = struct {
    limit: usize,
    seen: usize = 0,
    /// Counts without printing.
    quiet: bool = false,
    /// Prints the line trimmed, without its file and number.
    plain: bool = false,

    fn scan(self: *Shown, out: *Io.Writer, path: []const u8, text: []const u8, keep: *const fn ([]const u8) bool) !void {
        var number: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (keep(line)) try self.show(out, path, number, line);
        }
    }

    /// The declarations under `public:`, or under `private:` and
    /// `protected:`, of every class in the header.
    fn scanAccess(self: *Shown, out: *Io.Writer, path: []const u8, text: []const u8, wanted: Access) !void {
        var access: ?Access = null;
        var number: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const body = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, body, "private:") or std.mem.startsWith(u8, body, "protected:")) {
                access = .hidden;
                if (wanted == .hidden) try self.show(out, "", number, line);
                continue;
            }
            if (std.mem.startsWith(u8, body, "public:")) {
                access = .public;
                continue;
            }
            // A class, nested ones included, opens private and a struct
            // public, until a label says otherwise.
            if (opens(body)) |kind| {
                access = kind;
                continue;
            }
            if (access != wanted) continue;
            if (wanted == .public) {
                if (isAssert(line) or std.mem.startsWith(u8, body, "//") or std.mem.startsWith(u8, body, "*")) continue;
                if (std.mem.findScalar(u8, line, '(') != null and std.mem.findAny(u8, line, ";{") != null) try self.show(out, path, number, body);
            } else if (std.mem.findAny(u8, line, "(;") != null and std.mem.findAny(u8, line, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_") != null) {
                try self.show(out, "", number, line);
            }
        }
    }

    fn show(self: *Shown, out: *Io.Writer, path: []const u8, number: usize, line: []const u8) !void {
        self.seen += 1;
        if (self.quiet or self.seen > self.limit) return;
        if (self.plain) return out.print("  {s}\n", .{line});
        // Lines of the header alone carry no path.
        if (path.len == 0) return out.print("  {d}:{s}\n", .{ number, line });
        try out.print("  {s}:{d}:{s}\n", .{ path, number, line });
    }

    fn finish(self: Shown, out: *Io.Writer) !void {
        if (self.seen == 0) return out.writeAll("  (none)\n");
        if (self.seen > self.limit) try out.print("  ... {d} more, not shown\n", .{self.seen - self.limit});
    }
};

/// The access a definition opens with: `class` private, `struct` public. A
/// forward declaration, ending in `;`, opens nothing.
fn opens(body: []const u8) ?Access {
    if (std.mem.findScalar(u8, body, ';') != null) return null;
    if (std.mem.startsWith(u8, body, "class ")) return .hidden;
    if (std.mem.startsWith(u8, body, "struct ")) return .public;
    return null;
}

fn section(out: *Io.Writer, title: []const u8) !void {
    try out.print("\n{s}\n", .{title});
}

test "a class is found where it is defined, not where it is forward-declared" {
    const text = "class Skeleton;\nnamespace ozz {\nclass OZZ_ANIMATION_DLL Skeleton {\n public:\n};\n";
    try std.testing.expectEqual(@as(usize, 3), findDeclaration(text, "Skeleton").?.number);
    try std.testing.expect(findDeclaration("struct SkeletonPose {\n", "Skeleton") == null);
    try std.testing.expect(findDeclaration("class Skeleton;\n", "Skeleton") == null);
}

test "a pure virtual is abstract, a default initialiser is not" {
    try std.testing.expect(hasPureVirtual("  virtual bool Run() const = 0;\n"));
    try std.testing.expect(!hasPureVirtual("  int count = 0;\n  virtual ~Job();\n"));
}

test "the source of a header is its .cc under src/" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("libs/ozz/src/animation/runtime/skeleton.cc", try sourceOf(arena.allocator(), "libs/ozz/include/ozz/animation/runtime/skeleton.h"));
}

test "the line classifiers" {
    try std.testing.expect(isAssert("  assert(count > 0);"));
    try std.testing.expect(!isAssert("  assert(false && \"unreachable\");"));
    try std.testing.expect(isSilentDefault("  return Float4x4::identity(); // sIdentity"));
    try std.testing.expect(!isSilentDefault("  // returns sDefault"));
    try std.testing.expect(isEnum("  enum class Mode : int {"));
    try std.testing.expect(!isEnum("  enum Mode {"));
    try std.testing.expect(isNegativeValue("  kNone = -1,"));
    try std.testing.expect(!isNegativeValue("  a = b - 1;"));
}

test "public methods are read under public:, and a struct opens public" {
    var buffer: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var shown: Shown = .{ .limit = 10, .plain = true };
    try shown.scanAccess(&out, "x.h", "class A {\n  void Opening();\n public:\n  bool Run() const;\n private:\n  void Hidden();\n public:\n  int size() const { return 0; }\n};\nstruct Job {\n  bool Validate() const;\n};\n", .public);
    try std.testing.expectEqualStrings("  bool Run() const;\n  int size() const { return 0; }\n  bool Validate() const;\n", out.buffered());
}
