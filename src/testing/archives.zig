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

/// A skeleton whose name block is `names` and whose parents are `parents`,
/// one joint per parent, at rest at the identity: the counts honest, the
/// content as given.
pub fn skeletonWith(a: std.mem.Allocator, names: []const u8, parents: []const i16) !Writer {
    var w: Writer = try .init(a, "ozz-skeleton", 2);
    try w.int(i32, @intCast(parents.len));
    try w.int(i32, @intCast(names.len));
    try w.bytes.appendSlice(a, names);
    for (parents) |parent| try w.int(i16, parent);
    // Per four joints: SoA translation, rotation (x, y, z, w) and scale.
    for (0..(parents.len + 3) / 4) |_| {
        try w.zeros(3 * 16 + 3 * 16);
        for (0..4 + 3 * 4) |_| try w.int(f32, 1);
    }
    return w;
}

/// A float track keyed at `ratios`, valued 1, 2, 3..., linear and unnamed.
pub fn floatTrack(a: std.mem.Allocator, ratios: []const f32) !Writer {
    var w: Writer = try .init(a, "ozz-float_track", 1);
    try w.int(u32, @intCast(ratios.len));
    try w.int(i32, 0);
    for (ratios) |ratio| try w.int(f32, ratio);
    for (0..ratios.len) |i| try w.int(f32, @floatFromInt(i + 1));
    try w.zeros((ratios.len + 7) / 8);
    return w;
}

/// Where each field of an animation archive lies, as `Animation::Save`
/// writes version 7: the header counts, the name, the timepoints, then per
/// channel its ratios, previouses, iframe entries, iframe descriptors,
/// interval and keys.
pub const AnimationLayout = struct {
    num_tracks: usize,
    timepoints: Field,
    channels: [3]Channel,

    pub const Field = struct { at: usize, count: usize };
    pub const Channel = struct {
        /// The u32 in the header counting this channel's iframe descriptors.
        desc_count_at: usize,
        ratios: Field,
        ratio_size: usize,
        previouses: Field,
        entries: Field,
        desc: Field,
        interval_at: usize,
    };

    pub fn parse(bytes: []const u8) !AnimationLayout {
        const header = 1 + "ozz-animation".len + 1 + 4;
        const counts_at = header + 8;
        var at = counts_at + 11 * 4 + readU32(bytes, counts_at);
        const timepoints: Field = .{ .at = at, .count = readU32(bytes, counts_at + 4) };
        at += timepoints.count * 4;
        const ratio_size: usize = if (timepoints.count <= std.math.maxInt(u8)) 1 else 2;
        var channels: [3]Channel = undefined;
        for (&channels, 0..) |*channel, i| {
            const keys = readU32(bytes, counts_at + 4 * (2 + i));
            channel.desc_count_at = counts_at + 4 * (6 + 2 * i);
            channel.ratio_size = ratio_size;
            channel.ratios = .{ .at = at, .count = keys };
            at += keys * ratio_size;
            channel.previouses = .{ .at = at, .count = keys };
            at += keys * 2;
            channel.entries = .{ .at = at, .count = readU32(bytes, counts_at + 4 * (5 + 2 * i)) };
            at += channel.entries.count;
            channel.desc = .{ .at = at, .count = readU32(bytes, counts_at + 4 * (6 + 2 * i)) };
            at += channel.desc.count * 4;
            channel.interval_at = at;
            at += 4;
            // Float3Key and QuaternionKey are three u16 each.
            at += keys * 6;
        }
        if (at != bytes.len) return error.NotAnAnimationArchive;
        return .{ .num_tracks = readU32(bytes, header + 4), .timepoints = timepoints, .channels = channels };
    }
};

/// `bytes` with `remove` bytes at `at` replaced by `insert`, owned by `a`.
pub fn splice(a: std.mem.Allocator, bytes: []const u8, at: usize, remove: usize, insert: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ bytes[0..at], insert, bytes[at + remove ..] });
}

/// The u32 at `at`, in this platform's order, as `Writer` writes it.
pub fn readU32(bytes: []const u8, at: usize) usize {
    return std.mem.readInt(u32, bytes[at..][0..4], std.lang.Endian.native);
}
