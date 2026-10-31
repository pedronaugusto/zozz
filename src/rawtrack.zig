//! Raw tracks: the authoring side of ozz's five user-channel track value types
//! (float, float2, float3, float4, quaternion), plus building them into runtime
//! tracks and optimizing them.
//!
//! A track animates a single variable that is not a joint transform — a blend
//! weight, a light intensity, a custom float4 — over a track-local `[0, 1]`
//! ratio rather than a duration in seconds. Each type below repeats the same
//! shape: push keyframes, then either `build` (compress into a runtime track)
//! or `optimize` (key-frame reduction into another raw track).
//!
//! `build` produces the same sampleable runtime track types `track.zig` defines
//! — `FloatTrack`, `Float2Track`, `Float3Track`, `Float4Track` and
//! `QuaternionTrack` are re-exported here, not redefined, so offline-built
//! tracks work directly with `track.zig`'s `initFromFile`-style API.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const file = @import("file.zig");
const track = @import("track.zig");

pub const Interpolation = c.TrackInterpolation;

/// One authored keyframe, as ozz stores it: an interpolation mode, a
/// track-local ratio and the value at it. Re-exported from `c.zig` rather
/// than redefined — a second definition is a second layout to keep in step
/// with the header.
pub const FloatKeyframe = c.RawFloatKeyframe;
pub const Float2Keyframe = c.RawFloat2Keyframe;
pub const Float3Keyframe = c.RawFloat3Keyframe;
pub const Float4Keyframe = c.RawFloat4Keyframe;
pub const QuaternionKeyframe = c.RawQuaternionKeyframe;

//=============================================================================
// FloatTrack
//=============================================================================

pub const FloatTrack = track.FloatTrack;

pub const RawFloatTrack = struct {
    handle: ?*c.RawFloatTrack,

    pub fn init(failure: *err.Failure) err.Error!RawFloatTrack {
        var handle: *c.RawFloatTrack = undefined;
        try err.check(failure, .raw_float_track_create, c.zozzRawFloatTrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloatTrack) void {
        if (self.handle) |handle| c.zozzRawFloatTrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloatTrack) u32 {
        return err.reported(u32, c.zozzRawFloatTrackNumKeyframes(err.live(self.handle)));
    }

    /// Appends one keyframe. `ratio` must be finite and within `[0, 1]`;
    /// keys must be pushed in non-decreasing ratio order (violations surface
    /// at `build`/`optimize` as `error.InvalidData`).
    pub fn pushKeyframe(self: RawFloatTrack, interpolation: Interpolation, ratio: f32, value: f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float_track_push_keyframe, c.zozzRawFloatTrackPushKeyframe(err.live(self.handle), interpolation, ratio, value));
    }

    /// Validates and builds a runtime track. The raw track is not consumed.
    pub fn build(self: RawFloatTrack, failure: *err.Failure) err.Error!FloatTrack {
        var handle: *c.FloatTrack = undefined;
        try err.check(failure, .float_track_build, c.zozzFloatTrackBuild(err.live(self.handle), &handle));
        return .{ .handle = handle };
    }

    /// Key-frame reduction within `tolerance`. `output` must be distinct from
    /// `self`; its previous contents are discarded even on failure.
    pub fn optimize(self: RawFloatTrack, tolerance: f32, output: RawFloatTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float_track_optimize, c.zozzRawFloatTrackOptimize(err.live(self.handle), tolerance, err.live(output.handle)));
    }

    /// Loads a raw track from a `.ozz` archive written by
    /// `archive.saveRawFloatTrackToFile` or `OArchive.saveRawFloatTrack` —
    /// the cook-stage cache the runtime `FloatTrack` is built from. The file
    /// is read as `Skeleton.initFromFile` reads it.
    pub fn initFromFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, limit: file.Limit, failure: *err.Failure) err.Error!RawFloatTrack {
        const image = try file.readImage(gpa, io, dir, sub_path, limit, .raw_float_track_load_file, failure);
        defer gpa.free(image);
        return initFromMemory(.init(image), failure);
    }

    /// The same, from a memory image. The bytes are read during the call
    /// only and need not outlive it.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!RawFloatTrack {
        const image = bytes.readForParse();
        var handle: *c.RawFloatTrack = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_float_track_load_memory, c.zozzRawFloatTrackLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// ozz's `RawTrack::Validate()`: keyframe ratios strictly ascending and
    /// all within `[0, 1]`. The same answer `build` and `optimize` report as
    /// `error.InvalidData`, available before either.
    pub fn validate(self: RawFloatTrack) bool {
        return c.zozzRawFloatTrackValidate(err.live(self.handle));
    }

    /// Borrowed track name, `""` when unnamed. `build` copies it into the
    /// runtime track, which is what makes it worth setting. Valid until the
    /// track is destroyed or renamed.
    pub fn name(self: RawFloatTrack) [:0]const u8 {
        return std.mem.span(c.zozzRawFloatTrackName(err.live(self.handle)).?);
    }

    /// Renames the track; `new_name` may be null, which clears it to `""`.
    /// The string is copied.
    pub fn setName(self: RawFloatTrack, new_name: ?[*:0]const u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float_track_set_name, c.zozzRawFloatTrackSetName(err.live(self.handle), new_name));
    }

    /// Copies every keyframe into `out` and returns the prefix that was
    /// written. `out` must hold at least `numKeyframes`, else
    /// `error.BufferTooSmall` and nothing is written. Caller-owned memory:
    /// this never allocates.
    pub fn keyframes(self: RawFloatTrack, out: []FloatKeyframe, failure: *err.Failure) err.Error![]FloatKeyframe {
        const count = self.numKeyframes();
        try err.check(failure, .raw_float_track_keyframes, c.zozzRawFloatTrackKeyframes(err.live(self.handle), out.ptr, out.len));
        return out[0..count];
    }

    /// Drops every keyframe, keeping the name. Editing a track means
    /// clearing it and pushing its replacement keys; ozz has no key removal
    /// by index either.
    pub fn clear(self: RawFloatTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float_track_clear, c.zozzRawFloatTrackClear(err.live(self.handle)));
    }
};

//=============================================================================
// Float2Track
//=============================================================================

pub const Float2Track = track.Float2Track;

pub const RawFloat2Track = struct {
    handle: ?*c.RawFloat2Track,

    pub fn init(failure: *err.Failure) err.Error!RawFloat2Track {
        var handle: *c.RawFloat2Track = undefined;
        try err.check(failure, .raw_float2_track_create, c.zozzRawFloat2TrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloat2Track) void {
        if (self.handle) |handle| c.zozzRawFloat2TrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloat2Track) u32 {
        return err.reported(u32, c.zozzRawFloat2TrackNumKeyframes(err.live(self.handle)));
    }

    pub fn pushKeyframe(self: RawFloat2Track, interpolation: Interpolation, ratio: f32, value: [2]f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float2_track_push_keyframe, c.zozzRawFloat2TrackPushKeyframe(err.live(self.handle), interpolation, ratio, &value));
    }

    pub fn build(self: RawFloat2Track, failure: *err.Failure) err.Error!Float2Track {
        var handle: *c.Float2Track = undefined;
        try err.check(failure, .float2_track_build, c.zozzFloat2TrackBuild(err.live(self.handle), &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawFloat2Track, tolerance: f32, output: RawFloat2Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float2_track_optimize, c.zozzRawFloat2TrackOptimize(err.live(self.handle), tolerance, err.live(output.handle)));
    }

    /// See `RawFloatTrack.initFromFile`.
    pub fn initFromFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, limit: file.Limit, failure: *err.Failure) err.Error!RawFloat2Track {
        const image = try file.readImage(gpa, io, dir, sub_path, limit, .raw_float2_track_load_file, failure);
        defer gpa.free(image);
        return initFromMemory(.init(image), failure);
    }

    /// See `RawFloatTrack.initFromMemory`.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!RawFloat2Track {
        const image = bytes.readForParse();
        var handle: *c.RawFloat2Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_float2_track_load_memory, c.zozzRawFloat2TrackLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// See `RawFloatTrack.validate`.
    pub fn validate(self: RawFloat2Track) bool {
        return c.zozzRawFloat2TrackValidate(err.live(self.handle));
    }

    /// See `RawFloatTrack.name`.
    pub fn name(self: RawFloat2Track) [:0]const u8 {
        return std.mem.span(c.zozzRawFloat2TrackName(err.live(self.handle)).?);
    }

    /// See `RawFloatTrack.setName`.
    pub fn setName(self: RawFloat2Track, new_name: ?[*:0]const u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float2_track_set_name, c.zozzRawFloat2TrackSetName(err.live(self.handle), new_name));
    }

    /// See `RawFloatTrack.keyframes`.
    pub fn keyframes(self: RawFloat2Track, out: []Float2Keyframe, failure: *err.Failure) err.Error![]Float2Keyframe {
        const count = self.numKeyframes();
        try err.check(failure, .raw_float2_track_keyframes, c.zozzRawFloat2TrackKeyframes(err.live(self.handle), out.ptr, out.len));
        return out[0..count];
    }

    /// See `RawFloatTrack.clear`.
    pub fn clear(self: RawFloat2Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float2_track_clear, c.zozzRawFloat2TrackClear(err.live(self.handle)));
    }
};

//=============================================================================
// Float3Track
//=============================================================================

pub const Float3Track = track.Float3Track;

pub const RawFloat3Track = struct {
    handle: ?*c.RawFloat3Track,

    pub fn init(failure: *err.Failure) err.Error!RawFloat3Track {
        var handle: *c.RawFloat3Track = undefined;
        try err.check(failure, .raw_float3_track_create, c.zozzRawFloat3TrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloat3Track) void {
        if (self.handle) |handle| c.zozzRawFloat3TrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloat3Track) u32 {
        return err.reported(u32, c.zozzRawFloat3TrackNumKeyframes(err.live(self.handle)));
    }

    pub fn pushKeyframe(self: RawFloat3Track, interpolation: Interpolation, ratio: f32, value: [3]f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float3_track_push_keyframe, c.zozzRawFloat3TrackPushKeyframe(err.live(self.handle), interpolation, ratio, &value));
    }

    pub fn build(self: RawFloat3Track, failure: *err.Failure) err.Error!Float3Track {
        var handle: *c.Float3Track = undefined;
        try err.check(failure, .float3_track_build, c.zozzFloat3TrackBuild(err.live(self.handle), &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawFloat3Track, tolerance: f32, output: RawFloat3Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float3_track_optimize, c.zozzRawFloat3TrackOptimize(err.live(self.handle), tolerance, err.live(output.handle)));
    }

    /// See `RawFloatTrack.initFromFile`.
    pub fn initFromFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, limit: file.Limit, failure: *err.Failure) err.Error!RawFloat3Track {
        const image = try file.readImage(gpa, io, dir, sub_path, limit, .raw_float3_track_load_file, failure);
        defer gpa.free(image);
        return initFromMemory(.init(image), failure);
    }

    /// See `RawFloatTrack.initFromMemory`.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!RawFloat3Track {
        const image = bytes.readForParse();
        var handle: *c.RawFloat3Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_float3_track_load_memory, c.zozzRawFloat3TrackLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// See `RawFloatTrack.validate`.
    pub fn validate(self: RawFloat3Track) bool {
        return c.zozzRawFloat3TrackValidate(err.live(self.handle));
    }

    /// See `RawFloatTrack.name`.
    pub fn name(self: RawFloat3Track) [:0]const u8 {
        return std.mem.span(c.zozzRawFloat3TrackName(err.live(self.handle)).?);
    }

    /// See `RawFloatTrack.setName`.
    pub fn setName(self: RawFloat3Track, new_name: ?[*:0]const u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float3_track_set_name, c.zozzRawFloat3TrackSetName(err.live(self.handle), new_name));
    }

    /// See `RawFloatTrack.keyframes`.
    pub fn keyframes(self: RawFloat3Track, out: []Float3Keyframe, failure: *err.Failure) err.Error![]Float3Keyframe {
        const count = self.numKeyframes();
        try err.check(failure, .raw_float3_track_keyframes, c.zozzRawFloat3TrackKeyframes(err.live(self.handle), out.ptr, out.len));
        return out[0..count];
    }

    /// See `RawFloatTrack.clear`.
    pub fn clear(self: RawFloat3Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float3_track_clear, c.zozzRawFloat3TrackClear(err.live(self.handle)));
    }
};

//=============================================================================
// Float4Track
//=============================================================================

pub const Float4Track = track.Float4Track;

pub const RawFloat4Track = struct {
    handle: ?*c.RawFloat4Track,

    pub fn init(failure: *err.Failure) err.Error!RawFloat4Track {
        var handle: *c.RawFloat4Track = undefined;
        try err.check(failure, .raw_float4_track_create, c.zozzRawFloat4TrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloat4Track) void {
        if (self.handle) |handle| c.zozzRawFloat4TrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloat4Track) u32 {
        return err.reported(u32, c.zozzRawFloat4TrackNumKeyframes(err.live(self.handle)));
    }

    pub fn pushKeyframe(self: RawFloat4Track, interpolation: Interpolation, ratio: f32, value: [4]f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float4_track_push_keyframe, c.zozzRawFloat4TrackPushKeyframe(err.live(self.handle), interpolation, ratio, &value));
    }

    pub fn build(self: RawFloat4Track, failure: *err.Failure) err.Error!Float4Track {
        var handle: *c.Float4Track = undefined;
        try err.check(failure, .float4_track_build, c.zozzFloat4TrackBuild(err.live(self.handle), &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawFloat4Track, tolerance: f32, output: RawFloat4Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float4_track_optimize, c.zozzRawFloat4TrackOptimize(err.live(self.handle), tolerance, err.live(output.handle)));
    }

    /// See `RawFloatTrack.initFromFile`.
    pub fn initFromFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, limit: file.Limit, failure: *err.Failure) err.Error!RawFloat4Track {
        const image = try file.readImage(gpa, io, dir, sub_path, limit, .raw_float4_track_load_file, failure);
        defer gpa.free(image);
        return initFromMemory(.init(image), failure);
    }

    /// See `RawFloatTrack.initFromMemory`.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!RawFloat4Track {
        const image = bytes.readForParse();
        var handle: *c.RawFloat4Track = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_float4_track_load_memory, c.zozzRawFloat4TrackLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// See `RawFloatTrack.validate`.
    pub fn validate(self: RawFloat4Track) bool {
        return c.zozzRawFloat4TrackValidate(err.live(self.handle));
    }

    /// See `RawFloatTrack.name`.
    pub fn name(self: RawFloat4Track) [:0]const u8 {
        return std.mem.span(c.zozzRawFloat4TrackName(err.live(self.handle)).?);
    }

    /// See `RawFloatTrack.setName`.
    pub fn setName(self: RawFloat4Track, new_name: ?[*:0]const u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float4_track_set_name, c.zozzRawFloat4TrackSetName(err.live(self.handle), new_name));
    }

    /// See `RawFloatTrack.keyframes`.
    pub fn keyframes(self: RawFloat4Track, out: []Float4Keyframe, failure: *err.Failure) err.Error![]Float4Keyframe {
        const count = self.numKeyframes();
        try err.check(failure, .raw_float4_track_keyframes, c.zozzRawFloat4TrackKeyframes(err.live(self.handle), out.ptr, out.len));
        return out[0..count];
    }

    /// See `RawFloatTrack.clear`.
    pub fn clear(self: RawFloat4Track, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_float4_track_clear, c.zozzRawFloat4TrackClear(err.live(self.handle)));
    }
};

//=============================================================================
// QuaternionTrack
//=============================================================================

pub const QuaternionTrack = track.QuaternionTrack;

pub const RawQuaternionTrack = struct {
    handle: ?*c.RawQuaternionTrack,

    pub fn init(failure: *err.Failure) err.Error!RawQuaternionTrack {
        var handle: *c.RawQuaternionTrack = undefined;
        try err.check(failure, .raw_quaternion_track_create, c.zozzRawQuaternionTrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawQuaternionTrack) void {
        if (self.handle) |handle| c.zozzRawQuaternionTrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawQuaternionTrack) u32 {
        return err.reported(u32, c.zozzRawQuaternionTrackNumKeyframes(err.live(self.handle)));
    }

    /// `value` is a quaternion in (x, y, z, w) order — w LAST.
    pub fn pushKeyframe(self: RawQuaternionTrack, interpolation: Interpolation, ratio: f32, value: [4]f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_quaternion_track_push_keyframe, c.zozzRawQuaternionTrackPushKeyframe(err.live(self.handle), interpolation, ratio, &value));
    }

    pub fn build(self: RawQuaternionTrack, failure: *err.Failure) err.Error!QuaternionTrack {
        var handle: *c.QuaternionTrack = undefined;
        try err.check(failure, .quaternion_track_build, c.zozzQuaternionTrackBuild(err.live(self.handle), &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawQuaternionTrack, tolerance: f32, output: RawQuaternionTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_quaternion_track_optimize, c.zozzRawQuaternionTrackOptimize(err.live(self.handle), tolerance, err.live(output.handle)));
    }

    /// See `RawFloatTrack.initFromFile`.
    pub fn initFromFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, limit: file.Limit, failure: *err.Failure) err.Error!RawQuaternionTrack {
        const image = try file.readImage(gpa, io, dir, sub_path, limit, .raw_quaternion_track_load_file, failure);
        defer gpa.free(image);
        return initFromMemory(.init(image), failure);
    }

    /// See `RawFloatTrack.initFromMemory`.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!RawQuaternionTrack {
        const image = bytes.readForParse();
        var handle: *c.RawQuaternionTrack = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_quaternion_track_load_memory, c.zozzRawQuaternionTrackLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// See `RawFloatTrack.validate`.
    pub fn validate(self: RawQuaternionTrack) bool {
        return c.zozzRawQuaternionTrackValidate(err.live(self.handle));
    }

    /// See `RawFloatTrack.name`.
    pub fn name(self: RawQuaternionTrack) [:0]const u8 {
        return std.mem.span(c.zozzRawQuaternionTrackName(err.live(self.handle)).?);
    }

    /// See `RawFloatTrack.setName`.
    pub fn setName(self: RawQuaternionTrack, new_name: ?[*:0]const u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_quaternion_track_set_name, c.zozzRawQuaternionTrackSetName(err.live(self.handle), new_name));
    }

    /// See `RawFloatTrack.keyframes`.
    pub fn keyframes(self: RawQuaternionTrack, out: []QuaternionKeyframe, failure: *err.Failure) err.Error![]QuaternionKeyframe {
        const count = self.numKeyframes();
        try err.check(failure, .raw_quaternion_track_keyframes, c.zozzRawQuaternionTrackKeyframes(err.live(self.handle), out.ptr, out.len));
        return out[0..count];
    }

    /// See `RawFloatTrack.clear`.
    pub fn clear(self: RawQuaternionTrack, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_quaternion_track_clear, c.zozzRawQuaternionTrackClear(err.live(self.handle)));
    }
};
