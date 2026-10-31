//! Hand-made `.ozz` archives, each the smallest input that reaches one of
//! the defects libs/patches closes: built byte by byte here so a regression
//! reproduces without the fuzzer, and so each says in code which field is
//! wrong. The layout is ozz's: an endianness byte, the type's tag with its
//! NUL, a u32 version, then the fields Save writes, native byte order.
const std = @import("std");

/// An archive under construction.
pub const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator, tag: []const u8, version: u32) !Writer {
        var w: Writer = .{ .a = a };
        try w.int(u8, switch (std.lang.Endian.native) {
            .big => 0,
            .little => 1,
        });
        try w.bytes.appendSlice(a, tag);
        try w.int(u8, 0);
        try w.int(u32, version);
        return w;
    }

    pub fn int(w: *Writer, comptime T: type, value: T) !void {
        try w.bytes.appendSlice(w.a, std.mem.asBytes(&value));
    }

    pub fn zeros(w: *Writer, n: usize) !void {
        try w.bytes.appendNTimes(w.a, 0, n);
    }

    pub fn deinit(w: *Writer) void {
        w.bytes.deinit(w.a);
    }
};

/// A skeleton of `joints` joints whose name block claims `chars` bytes, the
/// rest of it honest: one-byte names, root parents, zero rest poses.
pub fn skeleton(a: std.mem.Allocator, joints: i32, chars: i32) !Writer {
    var w: Writer = try .init(a, "ozz-skeleton", 2);
    try w.int(i32, joints);
    try w.int(i32, chars);
    const n: usize = @intCast(@max(joints, 0));
    for (0..n) |_| try w.int(u8, 0);
    for (0..n) |_| try w.int(i16, -1);
    try w.zeros((n + 3) / 4 * 160);
    return w;
}

/// An animation of one track up to its counts, given in Save's order: name,
/// timepoints, translations, rotations, scales, then each channel's iframe
/// entries and descriptors. Nothing follows them.
pub fn animationHeader(a: std.mem.Allocator, counts: [11]u32) !Writer {
    var w: Writer = try .init(a, "ozz-animation", 7);
    try w.int(f32, 1);
    try w.int(u32, 1);
    for (counts) |count| try w.int(u32, count);
    return w;
}

/// A float track claiming `keys` keys and a name of `name_len` characters;
/// nothing follows.
pub fn floatTrackHeader(a: std.mem.Allocator, keys: u32, name_len: i32) !Writer {
    var w: Writer = try .init(a, "ozz-float_track", 1);
    try w.int(u32, keys);
    try w.int(i32, name_len);
    return w;
}

/// A raw skeleton nested `depth` joints deep, one child each: an empty name,
/// a transform of zeros and a one-element children vector, closed by a joint
/// with none. A vector of more than none is followed by its element version.
pub fn rawSkeletonChain(a: std.mem.Allocator, depth: usize) !Writer {
    var w: Writer = try .init(a, "ozz-raw_skeleton", 1);
    try w.int(u32, 1);
    try w.int(u32, 1);
    for (0..depth) |i| {
        try w.int(u32, 0);
        try w.zeros(40);
        try w.int(u32, if (i + 1 == depth) 0 else 1);
        if (i + 1 != depth) try w.int(u32, 1);
    }
    return w;
}

/// Each place a raw archive sizes a vector or a string from a count, as an
/// archive that reaches it with `count` there and nothing after: the input
/// that would drive the resize, were the count not checked first.
pub const RawSize = enum {
    skeleton_roots,
    skeleton_name,
    skeleton_children,
    animation_tracks,
    animation_translations,
    animation_rotations,
    animation_scales,
    animation_name,
    track_keyframes,
    track_name,

    /// What the check refusing it is named.
    pub fn what(size: RawSize) []const u8 {
        return switch (size) {
            .skeleton_name, .animation_name, .track_name => "string.size",
            else => "vector.size",
        };
    }

    /// The archive; a track's tag is `track_tag`.
    pub fn archive(size: RawSize, a: std.mem.Allocator, track_tag: []const u8, count: u32) !Writer {
        switch (size) {
            .skeleton_roots, .skeleton_name, .skeleton_children => {
                var w: Writer = try .init(a, "ozz-raw_skeleton", 1);
                if (size == .skeleton_roots) {
                    try w.int(u32, count);
                    return w;
                }
                try w.int(u32, 1);
                try w.int(u32, 1);
                if (size == .skeleton_name) {
                    try w.int(u32, count);
                    return w;
                }
                try w.int(u32, 0);
                try w.zeros(40);
                try w.int(u32, count);
                return w;
            },
            .animation_tracks, .animation_translations, .animation_rotations, .animation_scales, .animation_name => {
                var w: Writer = try .init(a, "ozz-raw_animation", 3);
                try w.int(f32, 1);
                if (size == .animation_tracks) {
                    try w.int(u32, count);
                    return w;
                }
                if (size == .animation_name) {
                    try w.int(u32, 0);
                    try w.int(u32, count);
                    return w;
                }
                try w.int(u32, 1);
                try w.int(u32, 1);
                const channels: usize = switch (size) {
                    .animation_translations => 0,
                    .animation_rotations => 1,
                    else => 2,
                };
                for (0..channels) |_| try w.int(u32, 0);
                try w.int(u32, count);
                return w;
            },
            .track_keyframes, .track_name => {
                var w: Writer = try .init(a, track_tag, 1);
                if (size == .track_name) try w.int(u32, 0);
                try w.int(u32, count);
                return w;
            },
        }
    }
};
