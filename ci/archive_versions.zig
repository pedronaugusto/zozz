//! Prints UPSTREAM.md's archive-version table: the version of every
//! serialisable ozz type, read out of the vendored headers. ozz versions its
//! archives per type and refuses a version it does not know, so these
//! numbers decide which `.ozz` files this package loads. A re-vendor can
//! change any of them, so the table is generated. Only an
//! `OZZ_IO_TYPE_VERSION(version, type)` at column 0 of a `*.h` under
//! libs/ozz/include counts: archive_traits.h documents the macro with an
//! example use, and a documented example is not a serialisable type. Rows
//! are in byte order, so no host's collation can reorder the table. Run
//! from the repository root.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

const include_path = "libs/ozz/include";
/// The prefix a row's header path is shown without.
const shown_from = include_path ++ "/ozz/";
const macro = "OZZ_IO_TYPE_VERSION(";
/// The largest header read.
const max_file_bytes = 1 << 22;
/// The most entries walked under libs/ozz/include.
const max_entries = 1 << 14;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Io.Dir.cwd().openDir(io, include_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var rows: std.ArrayList([]const u8) = .empty;
    var entries: usize = 0;
    while (try walker.next(io)) |entry| {
        entries += 1;
        if (entries > max_entries) return error.TooManyEntries;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".h")) continue;
        const path = try a.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const text = try aegis.own.readFile(io, entry.dir, entry.basename, a, .fromRaw(max_file_bytes));
        try collect(a, try a.print(include_path ++ "/{s}", .{path}), text, &rows);
    }
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    try stdout.interface.writeAll(try table(a, rows.items));
    try stdout.interface.flush();
    return 0;
}

/// The table: its header, then `rows` in byte order.
fn table(a: std.mem.Allocator, rows: [][]const u8) ![]const u8 {
    std.mem.sort([]const u8, rows, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "| Type | Archive version | Declared in |\n|---|---:|---|\n");
    for (rows) |row| try out.appendSlice(a, row);
    return out.items;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Appends a row for every declaration of the header at `path`, whose bytes
/// are `text`.
fn collect(a: std.mem.Allocator, path: []const u8, text: []const u8, rows: *std.ArrayList([]const u8)) !void {
    const shown = if (std.mem.startsWith(u8, path, shown_from)) path[shown_from.len..] else path;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const found = declaration(line) orelse continue;
        // A type holding a tab ends at it, as a tab-separated field does.
        const name = found.name[0 .. std.mem.findScalar(u8, found.name, '\t') orelse found.name.len];
        try rows.append(a, try a.print("| `{s}` | {s} | `{s}` |\n", .{ name, found.version, shown }));
    }
}

const Declaration = struct { version: []const u8, name: []const u8 };

/// The version and type of an `OZZ_IO_TYPE_VERSION(<digits>, <type>)` that
/// starts `line`, the type running to the first `)`.
fn declaration(line: []const u8) ?Declaration {
    if (!std.mem.startsWith(u8, line, macro)) return null;
    var end = macro.len;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == macro.len or !std.mem.startsWith(u8, line[end..], ", ")) return null;
    const start = end + 2;
    const close = std.mem.findScalarPos(u8, line, start, ')') orelse return null;
    if (close == start) return null;
    return .{ .version = line[macro.len..end], .name = line[start..close] };
}

test "a declaration at column 0 is read, an example or variant is not" {
    try std.testing.expectEqualDeep(Declaration{ .version = "7", .name = "animation::Animation" }, declaration("OZZ_IO_TYPE_VERSION(7, animation::Animation)").?);
    try std.testing.expectEqualDeep(Declaration{ .version = "12", .name = "a::B<c" }, declaration("OZZ_IO_TYPE_VERSION(12, a::B<c)>)").?);
    try std.testing.expect(declaration("// Syntax is: OZZ_IO_TYPE_VERSION(46, Foo).") == null);
    try std.testing.expect(declaration(" OZZ_IO_TYPE_VERSION(1, Foo)") == null);
    try std.testing.expect(declaration("OZZ_IO_TYPE_VERSION_T1(1, typename T, Foo<T>)") == null);
    try std.testing.expect(declaration("OZZ_IO_TYPE_VERSION(_version, _type)") == null);
    try std.testing.expect(declaration("OZZ_IO_TYPE_VERSION(1,Foo)") == null);
    try std.testing.expect(declaration("OZZ_IO_TYPE_VERSION(1, )") == null);
    try std.testing.expect(declaration("OZZ_IO_TYPE_VERSION(1, Foo") == null);
}

test "rows show the path under ozz/ and sort in byte order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList([]const u8) = .empty;
    try collect(a, "libs/ozz/include/other.h", "x\nOZZ_IO_TYPE_VERSION(3, animation::offline::RawAnimation)\n", &rows);
    try collect(a, "libs/ozz/include/ozz/animation/runtime/track.h", "OZZ_IO_TYPE_VERSION(1, animation::QuaternionTrack)\r\n", &rows);
    try std.testing.expectEqualStrings("| Type | Archive version | Declared in |\n|---|---:|---|\n" ++
        "| `animation::QuaternionTrack` | 1 | `animation/runtime/track.h` |\n" ++
        "| `animation::offline::RawAnimation` | 3 | `libs/ozz/include/other.h` |\n", try table(a, rows.items));
}
