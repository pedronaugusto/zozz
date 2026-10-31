//! Refuses comment blocks that have stopped being reference documentation:
//! a block longer than its cap, or a comment line in the narrative register.
//! Length per block, not density: a header where every declaration carries
//! two crisp lines is correct at any percentage. The cap never justifies
//! dropping a fact; units, ownership, lifetime, nullability, error conditions
//! and ordering come first. Only the package's own sources: the vendored tree
//! is upstream's to comment.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// Comment lines directly above one declaration.
const max_decl = 6;
/// The block at the top of a file, or one headed by a `//===` banner, which
/// heads a whole section and holds the conventions covering everything below.
const max_header = 14;
/// Any block of a public C header (`zozz.h` and the headers it includes): it is
/// the contract a C caller reads, with no Zig doc beside it.
const max_contract = 16;
/// The largest source file read.
const max_file_bytes = 1 << 20;

/// The directories checked, each read one level deep, and the suffixes.
const directories = [_][]const u8{ "ffi", "src" };
const suffixes = [_][]const u8{ ".h", ".cpp", ".zig" };

/// Phrases that read as a person talking, not as documentation. Matched
/// case-insensitively, on word boundaries.
const narrative = [_][]const u8{
    "we",               "our",            "us",           "note that",        "worth stating", "worth noting",
    "worth saying",     "used to be",     "they used to", "it used to",       "the reason is", "the reason it",
    "which is why",     "that is why",    "turns out",    "in practice this", "do not be",     "you might think",
    "you might expect", "it is tempting",
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var findings: std.ArrayList(u8) = .empty;
    const cwd = Io.Dir.cwd();
    const public = try publicHeaders(a, try aegis.own.readFile(io, cwd, "ffi/zozz.h", a, .fromRaw(max_file_bytes)));
    for (directories) |path| {
        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !checked(entry.name)) continue;
            const name = try a.print("{s}/{s}", .{ path, entry.name });
            const contract = std.mem.eql(u8, path, "ffi") and contains(public, entry.name);
            try check(a, name, try aegis.own.readFile(io, dir, entry.name, a, .fromRaw(max_file_bytes)), contract, &findings);
        }
    }
    if (findings.items.len == 0) return 0;
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(findings.items);
    try stderr.interface.print("comment blocks are capped at {d} lines above a declaration, {d} at a file's top or under a //=== banner " ++
        "and {d} in a public C header, and stay out of the narrative register\n", .{ max_decl, max_header, max_contract });
    try stderr.interface.flush();
    return 1;
}

/// Whether a file of this name is one of the package's own sources.
fn checked(name: []const u8) bool {
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }
    return false;
}

/// Appends a line to `findings` for every over-long block and narrative line
/// of `text`. The first block of a file takes the header cap when it starts
/// on one of the first three lines; every block of a public C header, when
/// `contract`, takes the contract cap.
fn check(a: std.mem.Allocator, name: []const u8, text: []const u8, contract: bool, findings: *std.ArrayList(u8)) !void {
    var run: usize = 0;
    var start: usize = 0;
    var banner = false;
    var first = true;
    var number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "//")) {
            if (run == 0) {
                start = number;
                banner = false;
            }
            if (std.mem.startsWith(u8, raw, "//===")) banner = true;
            run += 1;
            if (narrativePhrase(line)) |phrase| try findings.print(a, "{s}:{d}: narrative register (\"{s}\")\n", .{ name, number, phrase });
            continue;
        }
        if (run > 0) {
            const cap: usize = if (contract) max_contract else if ((first and start <= 3) or banner) max_header else max_decl;
            if (run > cap) try findings.print(a, "{s}:{d}: {d} comment lines in one block (max {d})\n", .{ name, start, run, cap });
            first = false;
            run = 0;
        }
    }
    if (run > max_decl) try findings.print(a, "{s}:{d}: {d} trailing comment lines\n", .{ name, start, run });
}

/// `zozz.h` and the `zozz_*.h` headers it includes, by file name.
fn publicHeaders(a: std.mem.Allocator, umbrella: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(a, "zozz.h");
    var lines = std.mem.splitScalar(u8, umbrella, '\n');
    while (lines.next()) |line| {
        const key = "#include \"zozz_";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const end = std.mem.findScalarPos(u8, line, key.len, '"') orelse continue;
        try names.append(a, line["#include \"".len..end]);
    }
    return names.items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |candidate| if (std.mem.eql(u8, candidate, item)) return true;
    return false;
}

/// The first narrative phrase in a comment line, or null. A word character
/// is a letter, a digit or an underscore, so `_we` holds no `we`.
fn narrativePhrase(line: []const u8) ?[]const u8 {
    for (narrative) |phrase| {
        var from: usize = 0;
        while (std.ascii.findIgnoreCasePos(line, from, phrase)) |at| : (from = at + 1) {
            const before = at == 0 or !wordChar(line[at - 1]);
            const end = at + phrase.len;
            const after = end == line.len or !wordChar(line[end]);
            if (before and after) return phrase;
        }
    }
    return null;
}

fn wordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `lead` declarations, `banner`, `count` lines of `prefix`, then a
/// declaration.
fn block(comptime lead: usize, comptime banner: []const u8, comptime prefix: []const u8, comptime count: usize) []const u8 {
    comptime var text: []const u8 = "";
    inline for (0..lead) |_| text = text ++ "const y = 0;\n";
    text = text ++ banner;
    inline for (0..count) |_| text = text ++ prefix ++ " line\n";
    return comptime text ++ "const x = 1;\n";
}

test "a block above a declaration takes the declaration cap" {
    const a = std.testing.allocator;
    var findings: std.ArrayList(u8) = .empty;
    defer findings.deinit(a);
    try check(a, "f.zig", comptime block(3, "", "///", max_decl), false, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
    try check(a, "f.zig", comptime block(3, "", "//", max_decl + 1), false, &findings);
    try std.testing.expectEqualStrings("f.zig:4: 7 comment lines in one block (max 6)\n", findings.items);
}

test "a file's opening block and a banner take the header cap" {
    const a = std.testing.allocator;
    var findings: std.ArrayList(u8) = .empty;
    defer findings.deinit(a);
    try check(a, "f.zig", comptime block(0, "", "//!", max_header), false, &findings);
    try check(a, "f.zig", comptime block(3, "//===\n", "//", max_header - 1), false, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
    try check(a, "f.zig", comptime block(0, "", "//!", max_header + 1), false, &findings);
    try std.testing.expectEqualStrings("f.zig:1: 15 comment lines in one block (max 14)\n", findings.items);
}

test "every block of a public C header takes the contract cap" {
    const a = std.testing.allocator;
    var findings: std.ArrayList(u8) = .empty;
    defer findings.deinit(a);
    try check(a, "zozz.h", comptime block(3, "", "//", max_contract), true, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
    try check(a, "zozz.h", comptime block(3, "", "//", max_contract + 1), true, &findings);
    try std.testing.expectEqualStrings("zozz.h:4: 17 comment lines in one block (max 16)\n", findings.items);
}

test "the public headers are the umbrella and what it includes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const names = try publicHeaders(arena.allocator(), "#include <stdint.h>\n#include \"zozz_core.h\"\n// #include \"zozz_x.h\"\n");
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("zozz_core.h", names[1]);
}

test "only the first block of a file takes the header cap" {
    const a = std.testing.allocator;
    var findings: std.ArrayList(u8) = .empty;
    defer findings.deinit(a);
    try check(a, "f.zig", "//! one\n" ++ comptime block(1, "", "//", max_decl + 1), false, &findings);
    try std.testing.expectEqualStrings("f.zig:3: 7 comment lines in one block (max 6)\n", findings.items);
}

test "the narrative register is matched on word boundaries" {
    try std.testing.expectEqualStrings("we", narrativePhrase("// so We call it").?);
    try std.testing.expect(narrativePhrase("// weights and ours are fine") == null);
    try std.testing.expect(narrativePhrase("// the_we field") == null);
    try std.testing.expectEqualStrings("us", narrativePhrase("// it tells us").?);
    try std.testing.expectEqualStrings("which is why", narrativePhrase("/// Which is why it fails").?);
}
