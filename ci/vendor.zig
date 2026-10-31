//! Proves libs/ozz is ozz-animation at the pinned commit with the patches in
//! libs/patches applied, and nothing else: every taken path holds the same
//! files, each file is upstream's bytes with exactly the hunks the patches
//! give it, in order, nothing else sits beside them, and the vendor record
//! names the commit build.zig.zon pins. A patch that no longer applies where
//! its hunk says is a finding. Upstream is fetched by the manifest's URL and
//! hash, so a moved tag cannot stand in for the commit.
//!
//! zozz-vendor VENDORED UPSTREAM PATCHES MANIFEST RECORD
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// What was taken from upstream: directories whole, files as they are.
const taken = [_][]const u8{ "include", "src", "LICENSE.md", "AUTHORS.md", "CHANGES.md" };
/// Names upstream has inside the taken directories and the vendored copy
/// drops, files or whole directories: its CMake build, which build.zig
/// supersedes, and the FBX importer, which needs an SDK no one can vendor.
const excluded = [_][]const u8{ "CMakeLists.txt", "fbx" };
/// The patches libs/ozz carries over upstream, in the order they apply. Each
/// names the files it changes in its own `+++ b/libs/ozz/...` lines.
const patches = [_][]const u8{
    "ozz-archive-counts.patch",
};
/// Where a patch's file paths start.
const patch_root = "libs/ozz/";
/// The largest file compared.
const max_file_bytes = 1 << 22;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6) return error.Usage;
    const cwd = Io.Dir.cwd();
    var vendored = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer vendored.close(io);
    var upstream = try cwd.openDir(io, args[2], .{ .iterate = true });
    defer upstream.close(io);
    var patch_dir = try cwd.openDir(io, args[3], .{ .iterate = true });
    defer patch_dir.close(io);
    var findings: std.ArrayList(u8) = .empty;
    const sections = try readPatches(a, io, patch_dir, &findings);
    try compareTop(a, io, vendored, upstream, sections, &findings);
    const manifest = try aegis.own.readFile(io, cwd, args[4], a, .fromRaw(1 << 20));
    const record = try aegis.own.readFile(io, cwd, args[5], a, .fromRaw(1 << 20));
    try checkRecord(a, manifest, record, &findings);
    if (findings.items.len == 0) return 0;
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.print("libs/ozz is not upstream with exactly its patches:\n{s}", .{findings.items});
    try stderr.interface.flush();
    return 1;
}

/// One file's part of one patch: the file under libs/ozz, and the text
/// `apply` takes, from its `---` line to the next file's.
const Section = struct { patch: []const u8, file: []const u8, diff: []const u8 };

/// Every listed patch, split by file, in order; refuses a patch file that is
/// not listed, or a listed one that is missing.
fn readPatches(a: std.mem.Allocator, io: Io, dir: Io.Dir, findings: *std.ArrayList(u8)) ![]const Section {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!contains(&patches, entry.name)) try findings.print(a, "  libs/patches/{s}: not listed in ci/vendor.zig\n", .{entry.name});
    }
    var out: std.ArrayList(Section) = .empty;
    for (patches) |name| {
        const text = aegis.own.readFile(io, dir, name, a, .fromRaw(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                try findings.print(a, "  libs/patches/{s}: listed but missing\n", .{name});
                continue;
            },
            else => |e| return e,
        };
        const found = try split(a, name, text);
        if (found.len == 0) try findings.print(a, "  libs/patches/{s}: changes no file under {s}\n", .{ name, patch_root });
        try out.appendSlice(a, found);
    }
    return out.items;
}

/// `text`'s per-file sections. A section starts at a `--- ` line followed by
/// a `+++ b/libs/ozz/` line and runs to the next section or `diff ` line.
fn split(a: std.mem.Allocator, patch: []const u8, text: []const u8) ![]const Section {
    const Start = struct { at: usize, file: []const u8 };
    var starts: std.ArrayList(Start) = .empty;
    var ends: std.ArrayList(usize) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = std.mem.findScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..end];
        const next = @min(end + 1, text.len);
        if (std.mem.startsWith(u8, line, "diff ")) try ends.append(a, pos);
        if (std.mem.startsWith(u8, line, "--- ") and std.mem.startsWith(u8, text[next..], "+++ b/" ++ patch_root)) {
            try ends.append(a, pos);
            const plus_end = std.mem.findScalarPos(u8, text, next, '\n') orelse text.len;
            try starts.append(a, .{ .at = pos, .file = text[next + "+++ b/".len + patch_root.len .. plus_end] });
        }
        pos = next;
    }
    var out: std.ArrayList(Section) = .empty;
    for (starts.items) |s| {
        var stop = text.len;
        for (ends.items) |e| {
            if (e > s.at and e < stop) stop = e;
        }
        try out.append(a, .{ .patch = patch, .file = s.file, .diff = text[s.at..stop] });
    }
    return out.items;
}

/// Compares each taken path, and refuses a vendored entry that is not one.
fn compareTop(a: std.mem.Allocator, io: Io, vendored: Io.Dir, upstream: Io.Dir, sections: []const Section, findings: *std.ArrayList(u8)) !void {
    var it = vendored.iterate();
    while (try it.next(io)) |entry| {
        if (!contains(&taken, entry.name)) try findings.print(a, "  {s}: not taken from upstream\n", .{entry.name});
    }
    for (taken) |name| {
        const kind = (upstream.statFile(io, name, .{}) catch {
            try findings.print(a, "  {s}: upstream has no such path\n", .{name});
            continue;
        }).kind;
        if (kind == .directory) try compareTrees(a, io, vendored, upstream, name, sections, findings) else try compareFiles(a, io, vendored, upstream, name, sections, findings);
    }
    for (sections) |s| {
        if (!underTaken(s.file)) try findings.print(a, "  libs/patches/{s}: changes {s}, which is not taken from upstream\n", .{ s.patch, s.file });
    }
}

/// Compares two trees under `path`, both directions, by file.
fn compareTrees(a: std.mem.Allocator, io: Io, vendored: Io.Dir, upstream: Io.Dir, path: []const u8, sections: []const Section, findings: *std.ArrayList(u8)) !void {
    const ours = try listFiles(a, io, vendored, path);
    const theirs = try listFiles(a, io, upstream, path);
    for (theirs) |name| {
        if (!contains(ours, name)) try findings.print(a, "  {s}: missing from the vendored copy\n", .{name});
    }
    for (ours) |name| {
        if (!contains(theirs, name)) try findings.print(a, "  {s}: added to the vendored copy\n", .{name}) else try compareFiles(a, io, vendored, upstream, name, sections, findings);
    }
}

/// Every file under `path`, minus the excluded names, as paths with `/`.
fn listFiles(a: std.mem.Allocator, io: Io, root: Io.Dir, path: []const u8) ![]const []const u8 {
    var dir = root.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or excludedPath(entry.path)) continue;
        const relative = try a.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, relative, '\\', '/');
        try names.append(a, try a.print("{s}/{s}", .{ path, relative }));
    }
    return names.items;
}

/// Compares one file's bytes with upstream's, its patches applied in order.
fn compareFiles(a: std.mem.Allocator, io: Io, vendored: Io.Dir, upstream: Io.Dir, name: []const u8, sections: []const Section, findings: *std.ArrayList(u8)) !void {
    const ours = aegis.own.readFile(io, vendored, name, a, .fromRaw(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return findings.print(a, "  {s}: missing from the vendored copy\n", .{name}),
        else => |e| return e,
    };
    var expected: []const u8 = try aegis.own.readFile(io, upstream, name, a, .fromRaw(max_file_bytes));
    var patched = false;
    for (sections) |s| {
        if (!std.mem.eql(u8, s.file, name)) continue;
        patched = true;
        expected = apply(a, expected, s.diff) catch |err| switch (err) {
            error.PatchMismatch, error.MalformedPatch => return findings.print(a, "  libs/patches/{s}: does not apply to upstream {s} ({t})\n", .{ s.patch, name, err }),
            else => |e| return e,
        };
    }
    if (std.mem.eql(u8, ours, expected)) return;
    if (patched) {
        try findings.print(a, "  {s}: differs from upstream with its patches applied\n", .{name});
    } else {
        try findings.print(a, "  {s}: differs from upstream\n", .{name});
    }
}

pub const ApplyError = error{ PatchMismatch, MalformedPatch } || std.mem.Allocator.Error;

/// `original` with the unified diff `patch` applied: the text before its
/// `+++` line is the patch's description, and every context and removed
/// line must match `original` where its hunk says it stands.
pub fn apply(gpa: std.mem.Allocator, original: []const u8, patch: []const u8) ApplyError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = original;
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ")) break;
    } else return error.MalformedPatch;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "@@ -")) {
            const digits = line["@@ -".len..];
            const end = std.mem.findAny(u8, digits, ", ") orelse return error.MalformedPatch;
            const start = std.fmt.parseInt(usize, digits[0..end], 10) catch return error.MalformedPatch;
            if (start < line_number) return error.MalformedPatch;
            while (line_number < start) : (line_number += 1) {
                try out.appendSlice(gpa, takeLine(&rest) orelse return error.PatchMismatch);
                try out.append(gpa, '\n');
            }
            continue;
        }
        switch (line[0]) {
            ' ', '-' => {
                const was = takeLine(&rest) orelse return error.PatchMismatch;
                if (!std.mem.eql(u8, was, line[1..])) return error.PatchMismatch;
                line_number += 1;
                if (line[0] == ' ') {
                    try out.appendSlice(gpa, was);
                    try out.append(gpa, '\n');
                }
            },
            '+' => {
                try out.appendSlice(gpa, line[1..]);
                try out.append(gpa, '\n');
            },
            '\\' => {},
            else => return error.MalformedPatch,
        }
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn takeLine(rest: *[]const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    const end = std.mem.findScalar(u8, rest.*, '\n') orelse rest.len;
    const line = rest.*[0..end];
    rest.* = rest.*[@min(end + 1, rest.len)..];
    return line;
}

/// Requires the record to name the commit the manifest pins upstream at,
/// and every patch libs/ozz carries, so none is applied unrecorded.
fn checkRecord(a: std.mem.Allocator, manifest: []const u8, record: []const u8, findings: *std.ArrayList(u8)) !void {
    for (patches) |name| {
        if (std.mem.find(u8, record, name) == null) try findings.print(a, "  the vendor record does not name libs/patches/{s}\n", .{name});
    }
    const commit = pinnedCommit(manifest) orelse return findings.print(a, "  build.zig.zon pins ozz-animation at no commit\n", .{});
    if (std.mem.find(u8, record, commit) == null) try findings.print(a, "  the vendor record does not name the pinned commit {s}\n", .{commit});
}

/// Whether a path lies under one of the taken paths.
fn underTaken(path: []const u8) bool {
    for (taken) |t| {
        if (std.mem.eql(u8, path, t)) return true;
        if (std.mem.startsWith(u8, path, t) and path.len > t.len and path[t.len] == '/') return true;
    }
    return false;
}

/// Whether any component of a walked path is an excluded name.
fn excludedPath(path: []const u8) bool {
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (contains(&excluded, component)) return true;
    }
    return false;
}

/// The commit after `#` in the ozz-animation pin's URL.
fn pinnedCommit(manifest: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, manifest, ".ozz = .{") orelse return null;
    const url = std.mem.findPos(u8, manifest, at, "github.com/guillaumeblanc/ozz-animation") orelse return null;
    const hash = std.mem.findScalarPos(u8, manifest, url, '#') orelse return null;
    const end = std.mem.findScalarPos(u8, manifest, hash, '"') orelse return null;
    return manifest[hash + 1 .. end];
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |candidate| if (std.mem.eql(u8, candidate, item)) return true;
    return false;
}

test "the pinned commit is read from the manifest's URL" {
    const manifest =
        \\        .ozz = .{
        \\            .url = "git+https://github.com/guillaumeblanc/ozz-animation?ref=0.17.0#744eb9d9",
    ;
    try std.testing.expectEqualStrings("744eb9d9", pinnedCommit(manifest).?);
    try std.testing.expect(pinnedCommit(".other = .{}") == null);
}

test "a path under an excluded directory is excluded, a lookalike is not" {
    try std.testing.expect(excludedPath("animation/offline/fbx/fbx.cc"));
    try std.testing.expect(excludedPath("base\\CMakeLists.txt"));
    try std.testing.expect(!excludedPath("animation/offline/fbx2ozz.h"));
}

test apply {
    const gpa = std.testing.allocator;
    const original = "one\ntwo\nthree\nfour\n";
    const patch = "why\n--- a/f\n+++ b/f\n@@ -2,2 +2,2 @@\n two\n-three\n+3\n";
    const patched = try apply(gpa, original, patch);
    defer gpa.free(patched);
    try std.testing.expectEqualStrings("one\ntwo\n3\nfour\n", patched);
    // A removed or context line that is not where the hunk says is refused,
    // so a patch cannot quietly apply to the wrong text.
    try std.testing.expectError(error.PatchMismatch, apply(gpa, original, "--- a/f\n+++ b/f\n@@ -2,1 +2,1 @@\n-four\n+4\n"));
    try std.testing.expectError(error.PatchMismatch, apply(gpa, original, "--- a/f\n+++ b/f\n@@ -9,1 +9,1 @@\n-x\n+y\n"));
    try std.testing.expectError(error.MalformedPatch, apply(gpa, original, "no header\n"));
}

test "a patch splits into one section per file under libs/ozz" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\Why the patch exists.
        \\
        \\diff --git a/libs/ozz/src/x.cc b/libs/ozz/src/x.cc
        \\index 1..2 100644
        \\--- a/libs/ozz/src/x.cc
        \\+++ b/libs/ozz/src/x.cc
        \\@@ -1,1 +1,1 @@
        \\-a
        \\+b
        \\diff --git a/libs/ozz/include/y.h b/libs/ozz/include/y.h
        \\--- a/libs/ozz/include/y.h
        \\+++ b/libs/ozz/include/y.h
        \\@@ -2,1 +2,1 @@
        \\-c
        \\+d
        \\
    ;
    const sections = try split(arena.allocator(), "p.patch", text);
    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("src/x.cc", sections[0].file);
    try std.testing.expectEqualStrings("--- a/libs/ozz/src/x.cc\n+++ b/libs/ozz/src/x.cc\n@@ -1,1 +1,1 @@\n-a\n+b\n", sections[0].diff);
    try std.testing.expectEqualStrings("include/y.h", sections[1].file);
    try std.testing.expectEqualStrings("1\nd\n", try apply(arena.allocator(), "1\nc\n", sections[1].diff));
}

test "only a path under a taken one is patchable" {
    try std.testing.expect(underTaken("src/animation/runtime/skeleton.cc"));
    try std.testing.expect(underTaken("LICENSE.md"));
    try std.testing.expect(!underTaken("srcs/x.cc"));
    try std.testing.expect(!underTaken("CMakeLists.txt"));
}
