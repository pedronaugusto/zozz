//! Refuses a multi-digit number written by hand in a top-level `*.md`
//! document. A count that belongs to the tree belongs in a generated block,
//! which the docs check rebuilds; anything else stated outside one must be in
//! `allowed` with the reason it cannot go stale. Numbers in a generated
//! block, a fenced or inline code span, a link target or an identifier
//! (x86_64, 0.17.0, a date, a CI run id) are citations, not claims. An
//! allowance no document uses fails too: it describes a sentence that is no
//! longer there. Run from the repository root.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

const Allowance = struct { number: []const u8, reason: []const u8 };

/// The numbers a document may state by hand, each with why it is not a
/// measurement of this tree. Adding one is a deliberate argument; the table
/// is empty, and that is the intended state.
const allowed = [_]Allowance{};

/// The largest document read.
const max_file_bytes = 1 << 22;
/// The most top-level documents read.
const max_documents = 256;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = Io.Dir.cwd();
    var findings: std.ArrayList(u8) = .empty;
    var used: [allowed.len]bool = @splat(false);
    for (try documents(a, io, cwd)) |name| {
        const text = try aegis.own.readFile(io, cwd, name, a, .fromRaw(max_file_bytes));
        try check(a, name, text, &allowed, &used, &findings);
    }
    try unused(a, &allowed, &used, &findings);
    if (findings.items.len == 0) return 0;
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(findings.items);
    try stderr.interface.flush();
    return 1;
}

/// The `*.md` files at the root, in byte order.
fn documents(a: std.mem.Allocator, io: Io, cwd: Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var root = try cwd.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (names.items.len == max_documents) return error.TooManyDocuments;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Appends a finding for every hand-written number of `text`, marking in
/// `used` the allowances of `table` it uses.
fn check(a: std.mem.Allocator, name: []const u8, text: []const u8, table: []const Allowance, used: []bool, findings: *std.ArrayList(u8)) !void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        try findings.print(a, "{s}: not UTF-8\n", .{name});
        return;
    }
    var prose = try universalNewlines(a, text);
    prose = try stripGenerated(a, prose);
    prose = try strip(a, prose, "```", "```", true);
    prose = try strip(a, prose, "`", "`", false);
    prose = try strip(a, prose, "](", ")", true);
    var lines: Lines = .{ .text = prose };
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        var from: usize = 0;
        while (nextNumber(line, from)) |found| {
            from = found.end;
            const token = line[found.start..found.end];
            if (allowance(table, token)) |index| {
                used[index] = true;
                continue;
            }
            try findings.print(a, "{s}:{d}: the number {s} is written by hand; generate it, or allow it in ci/numbers.zig with why it cannot go stale\n", .{ name, number, token });
        }
    }
}

/// Appends a finding for every allowance of `table` no document used, in
/// byte order of the number.
fn unused(a: std.mem.Allocator, table: []const Allowance, used: []const bool, findings: *std.ArrayList(u8)) !void {
    var numbers: std.ArrayList([]const u8) = .empty;
    for (table, used) |entry, was| if (!was) try numbers.append(a, entry.number);
    std.mem.sort([]const u8, numbers.items, {}, lessThan);
    for (numbers.items) |number| try findings.print(a, "ci/numbers.zig: {s} is allowed but no document states it\n", .{number});
}

fn allowance(table: []const Allowance, token: []const u8) ?usize {
    for (table, 0..) |entry, index| if (std.mem.eql(u8, entry.number, token)) return index;
    return null;
}

/// `text` with every `\r\n` and lone `\r` turned into `\n`, as a document
/// read in text mode is.
fn universalNewlines(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, text, '\r') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    for (text, 0..) |byte, index| {
        if (byte != '\r') try out.append(a, byte) else if (index + 1 == text.len or text[index + 1] != '\n') try out.append(a, '\n');
    }
    return out.items;
}

const begin_marker = "<!-- BEGIN GENERATED ";
const end_marker = "<!-- END GENERATED -->";

/// `text` with every generated block blanked to its newlines. An opening
/// marker counts only as `<!-- BEGIN GENERATED <command> -->` ending its line,
/// the command holding no `>`; a malformed one stays prose.
fn stripGenerated(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    var search: usize = 0;
    while (std.mem.findPos(u8, text, search, begin_marker)) |start| {
        search = start + 1;
        const command = start + begin_marker.len;
        const close = std.mem.findScalarPos(u8, text, command, '>') orelse break;
        const formed = close >= command + 4 and std.mem.eql(u8, text[close - 3 .. close], " --") and
            close + 1 < text.len and text[close + 1] == '\n';
        if (!formed) continue;
        const end = std.mem.findPos(u8, text, close + 2, end_marker) orelse break;
        try out.appendSlice(a, text[at..start]);
        for (text[start .. end + end_marker.len]) |byte| if (byte == '\n') try out.append(a, '\n');
        at = end + end_marker.len;
        search = at;
    }
    try out.appendSlice(a, text[at..]);
    return out.items;
}

/// `text` with every region from `open` to the next `close` removed, keeping
/// the region's newlines so line numbers stay true. A region that would cross
/// a line ends nowhere unless `multiline`, and is left as it is.
fn strip(a: std.mem.Allocator, text: []const u8, open: []const u8, close: []const u8, multiline: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (std.mem.findPos(u8, text, at, open)) |start| {
        const end = std.mem.findPos(u8, text, start + open.len, close) orelse break;
        if (!multiline and std.mem.findScalar(u8, text[start..end], '\n') != null) {
            try out.appendSlice(a, text[at .. start + 1]);
            at = start + 1;
            continue;
        }
        try out.appendSlice(a, text[at..start]);
        for (text[start .. end + close.len]) |byte| if (byte == '\n') try out.append(a, '\n');
        at = end + close.len;
    }
    try out.appendSlice(a, text[at..]);
    return out.items;
}

/// The lines of a text, split where a text-mode reader splits them: at `\n`,
/// `\x0b`, `\x0c`, `\x1c`..`\x1e`, U+0085, U+2028 and U+2029.
const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn next(lines: *Lines) ?[]const u8 {
        const text = lines.text;
        if (lines.at >= text.len) return null;
        const start = lines.at;
        var index = start;
        while (index < text.len) : (index += 1) {
            const width = separator(text[index..]);
            if (width == 0) continue;
            lines.at = index + width;
            return text[start..index];
        }
        lines.at = text.len;
        return text[start..];
    }

    /// The length of the line separator `rest` starts with, or 0.
    fn separator(rest: []const u8) usize {
        switch (rest[0]) {
            '\n', 0x0b, 0x0c, 0x1c, 0x1d, 0x1e => return 1,
            else => {},
        }
        if (std.mem.startsWith(u8, rest, "\u{85}")) return 2;
        if (std.mem.startsWith(u8, rest, "\u{2028}") or std.mem.startsWith(u8, rest, "\u{2029}")) return 3;
        return 0;
    }
};

const Span = struct { start: usize, end: usize };

/// The next number of `line` at or after `from`: two or more characters of
/// digits, spaces and commas that start and end on a digit, standing apart
/// from identifiers, paths and versions.
fn nextNumber(line: []const u8, from: usize) ?Span {
    var start = from;
    while (start < line.len) {
        if (!std.ascii.isDigit(line[start]) or (start > 0 and joined(line[start - 1]))) {
            start += 1;
            continue;
        }
        var end = start;
        while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == ' ' or line[end] == ',')) end += 1;
        var last = end;
        while (last > start + 1) : (last -= 1) {
            if (std.ascii.isDigit(line[last - 1]) and (last == line.len or !joined(line[last]))) return .{ .start = start, .end = last };
        }
        start = end;
    }
    return null;
}

/// Whether a character beside a number makes it part of a longer token.
fn joined(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-' or byte == '/';
}

/// The findings `check` and `unused` give for `text` against `table`.
fn findingsOf(a: std.mem.Allocator, text: []const u8, table: []const Allowance) ![]const u8 {
    var findings: std.ArrayList(u8) = .empty;
    const used = try a.alloc(bool, table.len);
    @memset(used, false);
    try check(a, "f.md", text, table, used, &findings);
    try unused(a, table, used, &findings);
    return findings.items;
}

fn expectFindings(text: []const u8, table: []const Allowance, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(want, try findingsOf(arena.allocator(), text, table));
}

inline fn byHand(comptime line: []const u8, comptime number: []const u8) []const u8 {
    return "f.md:" ++ line ++ ": the number " ++ number ++ " is written by hand; generate it, or allow it in ci/numbers.zig with why it cannot go stale\n";
}

test "a number apart from an identifier is found, one inside one is not" {
    try std.testing.expectEqual(Span{ .start = 4, .end = 6 }, nextNumber("has 12 corners", 0).?);
    try std.testing.expect(nextNumber("x86_64 and 0.17.0 and v2 and a-12 and 12/3", 0) == null);
    try std.testing.expect(nextNumber("one 7 digit", 0) == null);
    try std.testing.expectEqual(Span{ .start = 0, .end = 5 }, nextNumber("1,024 bytes", 0).?);
    try std.testing.expectEqual(Span{ .start = 0, .end = 2 }, nextNumber("12 3a", 0).?);
    try std.testing.expectEqual(Span{ .start = 0, .end = 2 }, nextNumber("12, 3a", 0).?);
    try std.testing.expect(nextNumber("5 12a", 0) == null);
}

test "generated blocks, code and link targets are not prose" {
    const text = "<!-- BEGIN GENERATED x -->\n| 40 |\n<!-- END GENERATED -->\n```\n41\n```\n`42` [a](b/\n43)\nthen 44\n";
    try expectFindings(text, &.{}, byHand("9", "44"));
}

test "a malformed generated marker is prose" {
    try expectFindings("<!-- BEGIN GENERATED x --> 12\n<!-- END GENERATED -->\n", &.{}, byHand("1", "12"));
    try expectFindings("<!-- BEGIN GENERATED -->\n12\n<!-- END GENERATED -->\n", &.{}, byHand("2", "12"));
    try expectFindings("<!-- BEGIN GENERATED x -->\n12\n", &.{}, byHand("2", "12"));
}

test "an inline code span does not cross a line" {
    try expectFindings("a `b\n12 c` d\n", &.{}, byHand("2", "12"));
}

test "lines are counted as a text-mode reader counts them" {
    try expectFindings("a\r\nb\rc\x0cd\u{2028}e 12\n", &.{}, byHand("5", "12"));
}

test "an allowance is used by its number and an unused one fails" {
    const table = [_]Allowance{
        .{ .number = "64", .reason = "unused" },
        .{ .number = "12", .reason = "used" },
        .{ .number = "128", .reason = "unused" },
    };
    try expectFindings("has 12 and 13\n", &table, byHand("1", "13") ++
        "ci/numbers.zig: 128 is allowed but no document states it\n" ++
        "ci/numbers.zig: 64 is allowed but no document states it\n");
}

test "a document that is not UTF-8 is refused" {
    try expectFindings("a \xff b\n", &.{}, "f.md: not UTF-8\n");
}

test "every allowance is a distinct number with a reason" {
    for (allowed, 0..) |entry, index| {
        try std.testing.expect(entry.reason.len >= 20);
        try std.testing.expect(nextNumber(entry.number, 0) != null);
        for (allowed[0..index]) |earlier| try std.testing.expect(!std.mem.eql(u8, earlier.number, entry.number));
    }
}
