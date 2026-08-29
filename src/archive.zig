//! The archive: persisting a skeleton, an animation or a track to a stream a
//! host controls, or straight to a file, and reading them back the same way.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const Skeleton = @import("skeleton.zig").Skeleton;
const Animation = @import("animation.zig").Animation;
const track_mod = @import("track.zig");
const FloatTrack = track_mod.FloatTrack;
const Float2Track = track_mod.Float2Track;
const Float3Track = track_mod.Float3Track;
const Float4Track = track_mod.Float4Track;
const QuaternionTrack = track_mod.QuaternionTrack;

/// A host-provided stand-in for ozz::io::Stream — the same role a Zig
/// allocator plays for `c.Allocator` in `memory.zig`. Reused verbatim rather
/// than wrapped, the way `math.Transform` reuses `c.Transform`: a Zig-side
/// implementation fills this struct directly, leaving whichever callbacks
/// its direction does not need `null`.
pub const Stream = c.Stream;

/// Passed to a `Stream.seek` callback. Mirrors `c.SeekOrigin`.
pub const SeekOrigin = c.SeekOrigin;

/// The byte order an `OArchive` writes in. Mirrors `c.Endianness`.
pub const Endianness = c.Endianness;

/// The `Endianness` matching this build's own target — what reproduces
/// `OArchive`'s old, unconditional native-endian behaviour. zozz has no C
/// entry point to ask a platform its own native order (see zozz_archive.h);
/// a Zig host already has one, in the compiler's own target information.
pub fn nativeEndianness() Endianness {
    return switch (std.builtin.Endian.native) {
        .big => .big,
        .little => .little,
    };
}

/// An archive bound to one `Stream`, open for writing.
///
/// Every archive is scoped to one logical file: `init`, save everything that
/// belongs together, `deinit`.
pub const OArchive = struct {
    handle: *c.OArchive,

    pub fn init(stream: *const Stream, endianness: Endianness) err.Error!OArchive {
        var handle: *c.OArchive = undefined;
        try err.check(c.zozzOArchiveCreate(stream, endianness, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: OArchive) void {
        c.zozzOArchiveDestroy(self.handle);
    }

    /// Writes `data` untyped and unswapped, for framing custom data around
    /// the tagged objects below.
    pub fn saveBinary(self: OArchive, data: []const u8) err.Error!void {
        try err.check(c.zozzOArchiveSaveBinary(self.handle, data.ptr, data.len));
    }

    pub fn saveInt32(self: OArchive, value: i32) err.Error!void {
        try err.check(c.zozzOArchiveSaveInt32(self.handle, value));
    }

    pub fn saveFloat(self: OArchive, value: f32) err.Error!void {
        try err.check(c.zozzOArchiveSaveFloat(self.handle, value));
    }

    pub fn saveSkeleton(self: OArchive, skeleton: Skeleton) err.Error!void {
        try err.check(c.zozzOArchiveSaveSkeleton(self.handle, skeleton.handle));
    }

    pub fn saveAnimation(self: OArchive, animation: Animation) err.Error!void {
        try err.check(c.zozzOArchiveSaveAnimation(self.handle, animation.handle));
    }

    /// Writes a tagged, versioned runtime track — the same archive shape
    /// `FloatTrack.initFromFile` / `.initFromMemory` read back. One method
    /// per track value type, so a track built with `RawFloatTrack.build`
    /// (and its Float2/3/4 and Quaternion siblings) has a way to leave the
    /// process it was built in.
    pub fn saveFloatTrack(self: OArchive, track: FloatTrack) err.Error!void {
        try err.check(c.zozzOArchiveSaveFloatTrack(self.handle, track.handle));
    }

    pub fn saveFloat2Track(self: OArchive, track: Float2Track) err.Error!void {
        try err.check(c.zozzOArchiveSaveFloat2Track(self.handle, track.handle));
    }

    pub fn saveFloat3Track(self: OArchive, track: Float3Track) err.Error!void {
        try err.check(c.zozzOArchiveSaveFloat3Track(self.handle, track.handle));
    }

    pub fn saveFloat4Track(self: OArchive, track: Float4Track) err.Error!void {
        try err.check(c.zozzOArchiveSaveFloat4Track(self.handle, track.handle));
    }

    pub fn saveQuaternionTrack(self: OArchive, track: QuaternionTrack) err.Error!void {
        try err.check(c.zozzOArchiveSaveQuaternionTrack(self.handle, track.handle));
    }
};

/// An archive bound to one `Stream`, open for reading — the read twin of
/// `OArchive`.
///
/// Every archive is scoped to one logical file, read back in the order it
/// was written: `init`, load everything that belongs together, `deinit`.
pub const IArchive = struct {
    handle: *c.IArchive,

    pub fn init(stream: *const Stream) err.Error!IArchive {
        var handle: *c.IArchive = undefined;
        try err.check(c.zozzIArchiveCreate(stream, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: IArchive) void {
        c.zozzIArchiveDestroy(self.handle);
    }

    /// True when the stream was written in the opposite byte order from this
    /// platform's. Loads swap transparently; this matters only for raw bytes
    /// read back through `loadBinary`.
    pub fn endianSwap(self: IArchive) bool {
        return c.zozzIArchiveEndianSwap(self.handle);
    }

    /// Reads `data.len` untyped bytes into `data`, unswapped — the read twin
    /// of `OArchive.saveBinary`.
    pub fn loadBinary(self: IArchive, data: []u8) err.Error!void {
        try err.check(c.zozzIArchiveLoadBinary(self.handle, data.ptr, data.len));
    }

    pub fn loadInt32(self: IArchive) err.Error!i32 {
        var value: i32 = undefined;
        try err.check(c.zozzIArchiveLoadInt32(self.handle, &value));
        return value;
    }

    pub fn loadFloat(self: IArchive) err.Error!f32 {
        var value: f32 = undefined;
        try err.check(c.zozzIArchiveLoadFloat(self.handle, &value));
        return value;
    }

    pub fn loadSkeleton(self: IArchive) err.Error!Skeleton {
        var handle: *c.Skeleton = undefined;
        try err.check(c.zozzIArchiveLoadSkeleton(self.handle, &handle));
        return .{ .handle = handle };
    }

    pub fn loadAnimation(self: IArchive) err.Error!Animation {
        var handle: *c.Animation = undefined;
        try err.check(c.zozzIArchiveLoadAnimation(self.handle, &handle));
        return .{ .handle = handle };
    }

    /// Reads a tagged, versioned runtime track — the read twin of
    /// `OArchive.saveFloatTrack`. One method per track value type, matching
    /// the save side.
    pub fn loadFloatTrack(self: IArchive) err.Error!FloatTrack {
        var handle: *c.FloatTrack = undefined;
        try err.check(c.zozzIArchiveLoadFloatTrack(self.handle, &handle));
        return .{ .handle = handle };
    }

    pub fn loadFloat2Track(self: IArchive) err.Error!Float2Track {
        var handle: *c.Float2Track = undefined;
        try err.check(c.zozzIArchiveLoadFloat2Track(self.handle, &handle));
        return .{ .handle = handle };
    }

    pub fn loadFloat3Track(self: IArchive) err.Error!Float3Track {
        var handle: *c.Float3Track = undefined;
        try err.check(c.zozzIArchiveLoadFloat3Track(self.handle, &handle));
        return .{ .handle = handle };
    }

    pub fn loadFloat4Track(self: IArchive) err.Error!Float4Track {
        var handle: *c.Float4Track = undefined;
        try err.check(c.zozzIArchiveLoadFloat4Track(self.handle, &handle));
        return .{ .handle = handle };
    }

    pub fn loadQuaternionTrack(self: IArchive) err.Error!QuaternionTrack {
        var handle: *c.QuaternionTrack = undefined;
        try err.check(c.zozzIArchiveLoadQuaternionTrack(self.handle, &handle));
        return .{ .handle = handle };
    }

    /// True if the next object in the archive is a skeleton. Leaves the read
    /// position untouched either way, so a false result is free to try a
    /// different `testX`, and a true result is free to `loadSkeleton` right
    /// after.
    pub fn testSkeleton(self: IArchive) bool {
        return c.zozzIArchiveTestSkeleton(self.handle);
    }

    pub fn testAnimation(self: IArchive) bool {
        return c.zozzIArchiveTestAnimation(self.handle);
    }

    pub fn testFloatTrack(self: IArchive) bool {
        return c.zozzIArchiveTestFloatTrack(self.handle);
    }

    pub fn testFloat2Track(self: IArchive) bool {
        return c.zozzIArchiveTestFloat2Track(self.handle);
    }

    pub fn testFloat3Track(self: IArchive) bool {
        return c.zozzIArchiveTestFloat3Track(self.handle);
    }

    pub fn testFloat4Track(self: IArchive) bool {
        return c.zozzIArchiveTestFloat4Track(self.handle);
    }

    pub fn testQuaternionTrack(self: IArchive) bool {
        return c.zozzIArchiveTestQuaternionTrack(self.handle);
    }
};

/// Writes `skeleton` alone to a new file at `path`.
pub fn saveSkeletonToFile(skeleton: Skeleton, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzSkeletonSaveFile(skeleton.handle, path));
}

/// Writes `animation` alone to a new file at `path`.
pub fn saveAnimationToFile(animation: Animation, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzAnimationSaveFile(animation.handle, path));
}

/// Writes `track` alone to a new file at `path`. One function per track
/// value type, matching `saveSkeletonToFile` / `saveAnimationToFile`.
pub fn saveFloatTrackToFile(track: FloatTrack, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzFloatTrackSaveFile(track.handle, path));
}

pub fn saveFloat2TrackToFile(track: Float2Track, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzFloat2TrackSaveFile(track.handle, path));
}

pub fn saveFloat3TrackToFile(track: Float3Track, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzFloat3TrackSaveFile(track.handle, path));
}

pub fn saveFloat4TrackToFile(track: Float4Track, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzFloat4TrackSaveFile(track.handle, path));
}

pub fn saveQuaternionTrackToFile(track: QuaternionTrack, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzQuaternionTrackSaveFile(track.handle, path));
}
