//! ZOZZ_ALIGN16 is applied to a struct DEFINITION, never to a member. A
//! member-aligned type reads back as align 8 through Zig's translate-c on
//! every non-MSVC target, because translate-c ignores `#pragma pack(pop)` and
//! mingw's corecrt.h leaves a pack(8) open; src/abi_test.zig then fails on a
//! difference no object file has (ffi/zozz_core.h's alignment banner). The
//! ABI check catches it only on the targets that run it and only for a type
//! src/c.zig mirrors; this catches it everywhere.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// The largest source file read.
const max_file_bytes = 1 << 20;
const macro = "ZOZZ_ALIGN16";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var findings: std.ArrayList(u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, "ffi", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".h") and !std.mem.endsWith(u8, entry.name, ".cpp")) continue;
        const name = try a.print("ffi/{s}", .{entry.name});
        try check(a, name, try aegis.own.readFile(io, dir, entry.name, a, .fromRaw(max_file_bytes)), &findings);
    }
    if (findings.items.len == 0) return 0;
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(findings.items);
    try stderr.interface.writeAll(macro ++ " must follow `struct`, not precede a member\n");
    try stderr.interface.flush();
    return 1;
}

/// Appends `name:line: text` to `findings` for every line of `text` that
/// spells the macro outside a comment, its own definition and a
/// `struct ZOZZ_ALIGN16` head.
fn check(a: std.mem.Allocator, name: []const u8, text: []const u8, findings: *std.ArrayList(u8)) !void {
    var number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (misplaced(line)) try findings.print(a, "{s}:{d}: {s}\n", .{ name, number, line });
    }
}

/// Whether `line` applies the macro anywhere but to a struct definition.
fn misplaced(line: []const u8) bool {
    const body = std.mem.trimStart(u8, line, " \t");
    for ([_][]const u8{ "//", "*", "/*" }) |comment| {
        if (std.mem.startsWith(u8, body, comment)) return false;
    }
    if (std.mem.find(u8, line, macro) == null) return false;
    if (std.mem.startsWith(u8, body, "#")) {
        const directive = std.mem.trimStart(u8, body[1..], " \t");
        if (std.mem.startsWith(u8, directive, "define") and definesMacro(directive["define".len..])) return false;
    }
    var from: usize = 0;
    while (std.mem.findPos(u8, line, from, "struct")) |at| : (from = at + 1) {
        const rest = line[at + "struct".len ..];
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        if (trimmed.len < rest.len and std.mem.startsWith(u8, trimmed, macro)) return false;
    }
    return true;
}

/// Whether what follows `#define` names the macro.
fn definesMacro(rest: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    return trimmed.len < rest.len and std.mem.startsWith(u8, trimmed, macro);
}

test "the macro on a struct head, in a comment or in its definition is not a finding" {
    try std.testing.expect(!misplaced("typedef struct ZOZZ_ALIGN16 ZozzFloat4x4 {"));
    try std.testing.expect(!misplaced("// ZOZZ_ALIGN16 float m[16];"));
    try std.testing.expect(!misplaced(" * ZOZZ_ALIGN16 on a member"));
    try std.testing.expect(!misplaced("#  define ZOZZ_ALIGN16 __attribute__((aligned(16)))"));
    try std.testing.expect(!misplaced("float m[16];"));
}

test "the macro on a member is a finding" {
    try std.testing.expect(misplaced("  ZOZZ_ALIGN16 float m[16];"));
    try std.testing.expect(misplaced("  float m[16] ZOZZ_ALIGN16;"));
    try std.testing.expect(misplaced("#ifdef ZOZZ_ALIGN16"));
}
