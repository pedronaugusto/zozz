//! The archive: persisting a skeleton, an animation or a track to a stream a
//! host controls, or straight to a file, and reading them back the same way.

const std = @import("std");
const aegis = @import("aegis");
const c = @import("c.zig");
const err = @import("error.zig");
const Skeleton = @import("skeleton.zig").Skeleton;
const Animation = @import("animation.zig").Animation;
const track_mod = @import("track.zig");
const offline_mod = @import("offline.zig");
const rawtrack_mod = @import("rawtrack.zig");
const RawSkeleton = offline_mod.RawSkeleton;
const RawAnimation = offline_mod.RawAnimation;
const RawFloatTrack = rawtrack_mod.RawFloatTrack;
const RawFloat2Track = rawtrack_mod.RawFloat2Track;
const RawFloat3Track = rawtrack_mod.RawFloat3Track;
const RawFloat4Track = rawtrack_mod.RawFloat4Track;
const RawQuaternionTrack = rawtrack_mod.RawQuaternionTrack;
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

/// The stream an `IArchive` reads: its bytes are a peer's, and leave this
/// type only at the call that hands them to the archive's checked reader.
pub const InputStream = aegis.input.Untrusted(*const Stream);

/// Passed to a `Stream.seek` callback. Mirrors `c.SeekOrigin`.
pub const SeekOrigin = c.SeekOrigin;

/// The byte order an `OArchive` writes in. Mirrors `c.Endianness`.
pub const Endianness = c.Endianness;

/// The `Endianness` matching this build's own target — what reproduces
/// `OArchive`'s old, unconditional native-endian behaviour. zozz has no C
/// entry point to ask a platform its own native order (see zozz_archive.h);
/// a Zig host already has one, in the compiler's own target information.
pub fn nativeEndianness() Endianness {
    return switch (std.lang.Endian.native) {
        .big => .big,
        .little => .little,
    };
}

/// An archive bound to one `Stream`, open for writing.
///
/// Every archive is scoped to one logical file: `init`, save everything that
/// belongs together, `deinit`.
pub const OArchive = struct {
    handle: ?*c.OArchive,

    pub fn init(stream: *const Stream, endianness: Endianness, failure: *err.Failure) err.Error!OArchive {
        var handle: *c.OArchive = undefined;
        try err.check(failure, .o_archive_create, c.zozzOArchiveCreate(stream, endianness, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *OArchive) void {
        if (self.handle) |handle| c.zozzOArchiveDestroy(handle);
        self.handle = null;
    }

    /// Writes `data` untyped and unswapped, for framing custom data around
    /// the tagged objects below.
    pub fn saveBinary(self: OArchive, data: []const u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_binary, c.zozzOArchiveSaveBinary(err.live(self.handle), data.ptr, data.len));
    }

    pub fn saveInt32(self: OArchive, value: i32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_int32, c.zozzOArchiveSaveInt32(err.live(self.handle), value));
    }

    pub fn saveFloat(self: OArchive, value: f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_float, c.zozzOArchiveSaveFloat(err.live(self.handle), value));
    }

    pub fn saveSkeleton(self: OArchive, skeleton: Skeleton, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_skeleton, c.zozzOArchiveSaveSkeleton(err.live(self.handle), err.live(skeleton.handle)));
    }

    pub fn saveAnimation(self: OArchive, animation: Animation, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_animation, c.zozzOArchiveSaveAnimation(err.live(self.handle), err.live(animation.handle)));
    }

    /// Writes a tagged, versioned runtime track — the same archive shape
    /// `FloatTrack.initFromFile` / `.initFromMemory` read back. One method
    /// per track value type, so a track built with `RawFloatTrack.build`
    /// (and its Float2/3/4 and Quaternion siblings) has a way to leave the
    /// process it was built in.
    pub fn saveFloatTrack(self: OArchive, track: FloatTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_float_track, c.zozzOArchiveSaveFloatTrack(err.live(self.handle), err.live(track.handle)));
    }

    pub fn saveFloat2Track(self: OArchive, track: Float2Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_float2_track, c.zozzOArchiveSaveFloat2Track(err.live(self.handle), err.live(track.handle)));
    }

    pub fn saveFloat3Track(self: OArchive, track: Float3Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_float3_track, c.zozzOArchiveSaveFloat3Track(err.live(self.handle), err.live(track.handle)));
    }

    pub fn saveFloat4Track(self: OArchive, track: Float4Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_float4_track, c.zozzOArchiveSaveFloat4Track(err.live(self.handle), err.live(track.handle)));
    }

    pub fn saveQuaternionTrack(self: OArchive, track: QuaternionTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_quaternion_track, c.zozzOArchiveSaveQuaternionTrack(err.live(self.handle), err.live(track.handle)));
    }

    /// Writes a tagged, versioned OFFLINE object — the authoring side, so a
    /// cook stage's output can be cached and handed to the next stage rather
    /// than only built. One method per raw type, matching the load side.
    ///
    /// An EMPTY raw skeleton has no tree to write and is refused with
    /// `error.InvalidData`, the same answer `RawSkeleton.build` gives it.
    pub fn saveRawSkeleton(self: OArchive, raw: RawSkeleton, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_raw_skeleton, c.zozzOArchiveSaveRawSkeleton(err.live(self.handle), err.live(raw.handle)));
    }

    pub fn saveRawAnimation(self: OArchive, raw: RawAnimation, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_raw_animation, c.zozzOArchiveSaveRawAnimation(err.live(self.handle), err.live(raw.handle)));
    }

    pub fn saveRawFloatTrack(self: OArchive, raw: RawFloatTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_raw_float_track, c.zozzOArchiveSaveRawFloatTrack(err.live(self.handle), err.live(raw.handle)));
    }

    pub fn saveRawFloat2Track(self: OArchive, raw: RawFloat2Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_raw_float2_track, c.zozzOArchiveSaveRawFloat2Track(err.live(self.handle), err.live(raw.handle)));
    }

    pub fn saveRawFloat3Track(self: OArchive, raw: RawFloat3Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_raw_float3_track, c.zozzOArchiveSaveRawFloat3Track(err.live(self.handle), err.live(raw.handle)));
    }

    pub fn saveRawFloat4Track(self: OArchive, raw: RawFloat4Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_raw_float4_track, c.zozzOArchiveSaveRawFloat4Track(err.live(self.handle), err.live(raw.handle)));
    }

    pub fn saveRawQuaternionTrack(self: OArchive, raw: RawQuaternionTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .o_archive_save_raw_quaternion_track, c.zozzOArchiveSaveRawQuaternionTrack(err.live(self.handle), err.live(raw.handle)));
    }
};

/// An archive bound to one `Stream`, open for reading — the read twin of
/// `OArchive`.
///
/// Every archive is scoped to one logical file, read back in the order it
/// was written: `init`, load everything that belongs together, `deinit`.
pub const IArchive = struct {
    handle: ?*c.IArchive,

    pub fn init(stream: InputStream, failure: *err.Failure) err.Error!IArchive {
        var handle: *c.IArchive = undefined;
        try err.check(failure, .i_archive_create, c.zozzIArchiveCreate(stream.readForParse(), &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *IArchive) void {
        if (self.handle) |handle| c.zozzIArchiveDestroy(handle);
        self.handle = null;
    }

    /// True when the stream was written in the opposite byte order from this
    /// platform's. Loads swap transparently; this matters only for raw bytes
    /// read back through `loadBinary`.
    pub fn endianSwap(self: IArchive) bool {
        return c.zozzIArchiveEndianSwap(err.live(self.handle));
    }

    /// Reads `data.len` untyped bytes into `data`, unswapped — the read twin
    /// of `OArchive.saveBinary`.
    pub fn loadBinary(self: IArchive, data: []u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .i_archive_load_binary, c.zozzIArchiveLoadBinary(err.live(self.handle), data.ptr, data.len));
    }

    pub fn loadInt32(self: IArchive, failure: *err.Failure) err.Error!i32 {
        var value: i32 = undefined;
        try err.check(failure, .i_archive_load_int32, c.zozzIArchiveLoadInt32(err.live(self.handle), &value));
        return value;
    }

    pub fn loadFloat(self: IArchive, failure: *err.Failure) err.Error!f32 {
        var value: f32 = undefined;
        try err.check(failure, .i_archive_load_float, c.zozzIArchiveLoadFloat(err.live(self.handle), &value));
        return value;
    }

    pub fn loadSkeleton(self: IArchive, failure: *err.Failure) err.Error!Skeleton {
        var handle: *c.Skeleton = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_skeleton, c.zozzIArchiveLoadSkeleton(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadAnimation(self: IArchive, failure: *err.Failure) err.Error!Animation {
        var handle: *c.Animation = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_animation, c.zozzIArchiveLoadAnimation(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// Reads a tagged, versioned runtime track — the read twin of
    /// `OArchive.saveFloatTrack`. One method per track value type, matching
    /// the save side.
    pub fn loadFloatTrack(self: IArchive, failure: *err.Failure) err.Error!FloatTrack {
        var handle: *c.FloatTrack = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_float_track, c.zozzIArchiveLoadFloatTrack(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadFloat2Track(self: IArchive, failure: *err.Failure) err.Error!Float2Track {
        var handle: *c.Float2Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_float2_track, c.zozzIArchiveLoadFloat2Track(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadFloat3Track(self: IArchive, failure: *err.Failure) err.Error!Float3Track {
        var handle: *c.Float3Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_float3_track, c.zozzIArchiveLoadFloat3Track(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadFloat4Track(self: IArchive, failure: *err.Failure) err.Error!Float4Track {
        var handle: *c.Float4Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_float4_track, c.zozzIArchiveLoadFloat4Track(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadQuaternionTrack(self: IArchive, failure: *err.Failure) err.Error!QuaternionTrack {
        var handle: *c.QuaternionTrack = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_quaternion_track, c.zozzIArchiveLoadQuaternionTrack(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// True if the next object in the archive is a skeleton. Leaves the read
    /// position untouched either way, so a false result is free to try a
    /// different `testX`, and a true result is free to `loadSkeleton` right
    /// after.
    pub fn testSkeleton(self: IArchive) bool {
        return c.zozzIArchiveTestSkeleton(err.live(self.handle));
    }

    pub fn testAnimation(self: IArchive) bool {
        return c.zozzIArchiveTestAnimation(err.live(self.handle));
    }

    pub fn testFloatTrack(self: IArchive) bool {
        return c.zozzIArchiveTestFloatTrack(err.live(self.handle));
    }

    pub fn testFloat2Track(self: IArchive) bool {
        return c.zozzIArchiveTestFloat2Track(err.live(self.handle));
    }

    pub fn testFloat3Track(self: IArchive) bool {
        return c.zozzIArchiveTestFloat3Track(err.live(self.handle));
    }

    pub fn testFloat4Track(self: IArchive) bool {
        return c.zozzIArchiveTestFloat4Track(err.live(self.handle));
    }

    pub fn testQuaternionTrack(self: IArchive) bool {
        return c.zozzIArchiveTestQuaternionTrack(err.live(self.handle));
    }

    /// Reads a tagged, versioned OFFLINE object — the read twin of
    /// `OArchive.saveRawSkeleton` and its siblings.
    ///
    /// A raw skeleton comes back with DEPTH-FIRST joint indices, not the
    /// order it was authored in — the same reindexing `RawSkeleton.build`
    /// performs. Data that would fail its own `validate` still loads.
    pub fn loadRawSkeleton(self: IArchive, failure: *err.Failure) err.Error!RawSkeleton {
        var handle: *c.RawSkeleton = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_raw_skeleton, c.zozzIArchiveLoadRawSkeleton(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadRawAnimation(self: IArchive, failure: *err.Failure) err.Error!RawAnimation {
        var handle: *c.RawAnimation = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_raw_animation, c.zozzIArchiveLoadRawAnimation(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadRawFloatTrack(self: IArchive, failure: *err.Failure) err.Error!RawFloatTrack {
        var handle: *c.RawFloatTrack = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_raw_float_track, c.zozzIArchiveLoadRawFloatTrack(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadRawFloat2Track(self: IArchive, failure: *err.Failure) err.Error!RawFloat2Track {
        var handle: *c.RawFloat2Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_raw_float2_track, c.zozzIArchiveLoadRawFloat2Track(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadRawFloat3Track(self: IArchive, failure: *err.Failure) err.Error!RawFloat3Track {
        var handle: *c.RawFloat3Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_raw_float3_track, c.zozzIArchiveLoadRawFloat3Track(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadRawFloat4Track(self: IArchive, failure: *err.Failure) err.Error!RawFloat4Track {
        var handle: *c.RawFloat4Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_raw_float4_track, c.zozzIArchiveLoadRawFloat4Track(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn loadRawQuaternionTrack(self: IArchive, failure: *err.Failure) err.Error!RawQuaternionTrack {
        var handle: *c.RawQuaternionTrack = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .i_archive_load_raw_quaternion_track, c.zozzIArchiveLoadRawQuaternionTrack(err.live(self.handle), &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// True if the next object is a raw skeleton. Leaves the read position
    /// untouched either way, like every other `testX`.
    pub fn testRawSkeleton(self: IArchive) bool {
        return c.zozzIArchiveTestRawSkeleton(err.live(self.handle));
    }

    pub fn testRawAnimation(self: IArchive) bool {
        return c.zozzIArchiveTestRawAnimation(err.live(self.handle));
    }

    pub fn testRawFloatTrack(self: IArchive) bool {
        return c.zozzIArchiveTestRawFloatTrack(err.live(self.handle));
    }

    pub fn testRawFloat2Track(self: IArchive) bool {
        return c.zozzIArchiveTestRawFloat2Track(err.live(self.handle));
    }

    pub fn testRawFloat3Track(self: IArchive) bool {
        return c.zozzIArchiveTestRawFloat3Track(err.live(self.handle));
    }

    pub fn testRawFloat4Track(self: IArchive) bool {
        return c.zozzIArchiveTestRawFloat4Track(err.live(self.handle));
    }

    pub fn testRawQuaternionTrack(self: IArchive) bool {
        return c.zozzIArchiveTestRawQuaternionTrack(err.live(self.handle));
    }
};

/// Writes `skeleton` alone to `sub_path` in `dir`, as `saveToFile` writes.
pub fn saveSkeletonToFile(skeleton: Skeleton, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(Skeleton, OArchive.saveSkeleton, skeleton, io, dir, sub_path, .skeleton_save_file, failure);
}

/// Writes `animation` alone to `sub_path` in `dir`, as `saveToFile` writes.
pub fn saveAnimationToFile(animation: Animation, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(Animation, OArchive.saveAnimation, animation, io, dir, sub_path, .animation_save_file, failure);
}

/// Writes `track` alone to `sub_path` in `dir`, as `saveToFile` writes.
/// One function per track value type, matching `saveSkeletonToFile` /
/// `saveAnimationToFile`.
pub fn saveFloatTrackToFile(track: FloatTrack, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(FloatTrack, OArchive.saveFloatTrack, track, io, dir, sub_path, .float_track_save_file, failure);
}

pub fn saveFloat2TrackToFile(track: Float2Track, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(Float2Track, OArchive.saveFloat2Track, track, io, dir, sub_path, .float2_track_save_file, failure);
}

pub fn saveFloat3TrackToFile(track: Float3Track, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(Float3Track, OArchive.saveFloat3Track, track, io, dir, sub_path, .float3_track_save_file, failure);
}

pub fn saveFloat4TrackToFile(track: Float4Track, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(Float4Track, OArchive.saveFloat4Track, track, io, dir, sub_path, .float4_track_save_file, failure);
}

pub fn saveQuaternionTrackToFile(track: QuaternionTrack, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(QuaternionTrack, OArchive.saveQuaternionTrack, track, io, dir, sub_path, .quaternion_track_save_file, failure);
}

/// Writes `raw` alone to `sub_path` in `dir`, as `saveToFile` writes —
/// the offline twin of `saveSkeletonToFile` and the functions above it, and
/// what a cook stage uses to hand its output to the next one. The read side is
/// `RawSkeleton.initFromFile` and its equivalents, which own the file's
/// lifetime the same way the runtime loaders do.
pub fn saveRawSkeletonToFile(raw: RawSkeleton, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(RawSkeleton, OArchive.saveRawSkeleton, raw, io, dir, sub_path, .raw_skeleton_save_file, failure);
}

pub fn saveRawAnimationToFile(raw: RawAnimation, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(RawAnimation, OArchive.saveRawAnimation, raw, io, dir, sub_path, .raw_animation_save_file, failure);
}

pub fn saveRawFloatTrackToFile(raw: RawFloatTrack, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(RawFloatTrack, OArchive.saveRawFloatTrack, raw, io, dir, sub_path, .raw_float_track_save_file, failure);
}

pub fn saveRawFloat2TrackToFile(raw: RawFloat2Track, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(RawFloat2Track, OArchive.saveRawFloat2Track, raw, io, dir, sub_path, .raw_float2_track_save_file, failure);
}

pub fn saveRawFloat3TrackToFile(raw: RawFloat3Track, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(RawFloat3Track, OArchive.saveRawFloat3Track, raw, io, dir, sub_path, .raw_float3_track_save_file, failure);
}

pub fn saveRawFloat4TrackToFile(raw: RawFloat4Track, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(RawFloat4Track, OArchive.saveRawFloat4Track, raw, io, dir, sub_path, .raw_float4_track_save_file, failure);
}

pub fn saveRawQuaternionTrackToFile(raw: RawQuaternionTrack, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, failure: *err.Failure) err.Error!void {
    return saveToFile(RawQuaternionTrack, OArchive.saveRawQuaternionTrack, raw, io, dir, sub_path, .raw_quaternion_track_save_file, failure);
}

/// Writes `object` alone, by `saveTo`, to `sub_path` in `dir` through
/// `io`, in this target's byte order: written beside its destination and
/// renamed over it once synced, so a refused save leaves the file old, or
/// new and whole. The file's own failures name `call`; `saveTo`'s name
/// its archive call; a write the file system refuses is `ReadFailed`, the
/// error the C `io` result maps to. No C stdio sits under the Zig API.
fn saveToFile(
    comptime T: type,
    comptime saveTo: fn (OArchive, T, *err.Failure) err.Error!void,
    object: T,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    call: err.Call,
    failure: *err.Failure,
) err.Error!void {
    var atomic = dir.createFileAtomic(io, sub_path, .{ .replace = true }) catch |e| return switch (e) {
        error.FileNotFound => err.refuse(failure, call, err.Error.FileNotFound),
        else => err.refuse(failure, call, err.Error.ReadFailed),
    };
    // Deletes the file beside the destination unless `replace` renamed it.
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var sink: FileSink = .{ .file = atomic.file.writer(io, &buffer) };
    const stream = sink.stream();
    var out = try OArchive.init(&stream, nativeEndianness(), failure);
    defer out.deinit();
    try saveTo(out, object, failure);
    sink.file.interface.flush() catch return err.refuse(failure, call, err.Error.ReadFailed);
    atomic.file.sync(io) catch return err.refuse(failure, call, err.Error.ReadFailed);
    atomic.replace(io) catch return err.refuse(failure, call, err.Error.ReadFailed);
}

/// A `Stream` that writes into a `std.Io` file writer; a short write is
/// the archive's IO refusal.
const FileSink = struct {
    file: std.Io.File.Writer,

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const sink: *FileSink = @ptrCast(@alignCast(user orelse return 0)); // aegis: no-danger: user is the sink this file handed the archive stream, which hands it back unchanged
        if (size == 0) return 0;
        const bytes: [*]const u8 = @ptrCast(data orelse return 0); // aegis: no-danger: the archive writes size bytes of its own buffer, read here only up to size
        sink.file.interface.writeAll(bytes[0..size]) catch return 0;
        return size;
    }

    fn stream(sink: *FileSink) Stream {
        return .{ .opened = &opened, .write = &write, .read = null, .seek = null, .tell = null, .user = sink };
    }
};
