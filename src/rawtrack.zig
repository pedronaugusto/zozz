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

const c = @import("c.zig");
const err = @import("error.zig");
const track = @import("track.zig");

pub const Interpolation = c.TrackInterpolation;

//=============================================================================
// FloatTrack
//=============================================================================

pub const FloatTrack = track.FloatTrack;

pub const RawFloatTrack = struct {
    handle: ?*c.RawFloatTrack,

    pub fn init() err.Error!RawFloatTrack {
        var handle: *c.RawFloatTrack = undefined;
        try err.check(c.zozzRawFloatTrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloatTrack) void {
        if (self.handle) |handle| c.zozzRawFloatTrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloatTrack) u32 {
        return @intCast(c.zozzRawFloatTrackNumKeyframes(self.handle.?));
    }

    /// Appends one keyframe. `ratio` must be finite and within `[0, 1]`;
    /// keys must be pushed in non-decreasing ratio order (violations surface
    /// at `build`/`optimize` as `error.InvalidData`).
    pub fn pushKeyframe(self: RawFloatTrack, interpolation: Interpolation, ratio: f32, value: f32) err.Error!void {
        try err.check(c.zozzRawFloatTrackPushKeyframe(self.handle.?, interpolation, ratio, value));
    }

    /// Validates and builds a runtime track. The raw track is not consumed.
    pub fn build(self: RawFloatTrack) err.Error!FloatTrack {
        var handle: *c.FloatTrack = undefined;
        try err.check(c.zozzFloatTrackBuild(self.handle.?, &handle));
        return .{ .handle = handle };
    }

    /// Key-frame reduction within `tolerance`. `output` must be distinct from
    /// `self`; its previous contents are discarded even on failure.
    pub fn optimize(self: RawFloatTrack, tolerance: f32, output: RawFloatTrack) err.Error!void {
        try err.check(c.zozzRawFloatTrackOptimize(self.handle.?, tolerance, output.handle.?));
    }
};

//=============================================================================
// Float2Track
//=============================================================================

pub const Float2Track = track.Float2Track;

pub const RawFloat2Track = struct {
    handle: ?*c.RawFloat2Track,

    pub fn init() err.Error!RawFloat2Track {
        var handle: *c.RawFloat2Track = undefined;
        try err.check(c.zozzRawFloat2TrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloat2Track) void {
        if (self.handle) |handle| c.zozzRawFloat2TrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloat2Track) u32 {
        return @intCast(c.zozzRawFloat2TrackNumKeyframes(self.handle.?));
    }

    pub fn pushKeyframe(self: RawFloat2Track, interpolation: Interpolation, ratio: f32, value: [2]f32) err.Error!void {
        try err.check(c.zozzRawFloat2TrackPushKeyframe(self.handle.?, interpolation, ratio, &value));
    }

    pub fn build(self: RawFloat2Track) err.Error!Float2Track {
        var handle: *c.Float2Track = undefined;
        try err.check(c.zozzFloat2TrackBuild(self.handle.?, &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawFloat2Track, tolerance: f32, output: RawFloat2Track) err.Error!void {
        try err.check(c.zozzRawFloat2TrackOptimize(self.handle.?, tolerance, output.handle.?));
    }
};

//=============================================================================
// Float3Track
//=============================================================================

pub const Float3Track = track.Float3Track;

pub const RawFloat3Track = struct {
    handle: ?*c.RawFloat3Track,

    pub fn init() err.Error!RawFloat3Track {
        var handle: *c.RawFloat3Track = undefined;
        try err.check(c.zozzRawFloat3TrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloat3Track) void {
        if (self.handle) |handle| c.zozzRawFloat3TrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloat3Track) u32 {
        return @intCast(c.zozzRawFloat3TrackNumKeyframes(self.handle.?));
    }

    pub fn pushKeyframe(self: RawFloat3Track, interpolation: Interpolation, ratio: f32, value: [3]f32) err.Error!void {
        try err.check(c.zozzRawFloat3TrackPushKeyframe(self.handle.?, interpolation, ratio, &value));
    }

    pub fn build(self: RawFloat3Track) err.Error!Float3Track {
        var handle: *c.Float3Track = undefined;
        try err.check(c.zozzFloat3TrackBuild(self.handle.?, &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawFloat3Track, tolerance: f32, output: RawFloat3Track) err.Error!void {
        try err.check(c.zozzRawFloat3TrackOptimize(self.handle.?, tolerance, output.handle.?));
    }
};

//=============================================================================
// Float4Track
//=============================================================================

pub const Float4Track = track.Float4Track;

pub const RawFloat4Track = struct {
    handle: ?*c.RawFloat4Track,

    pub fn init() err.Error!RawFloat4Track {
        var handle: *c.RawFloat4Track = undefined;
        try err.check(c.zozzRawFloat4TrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawFloat4Track) void {
        if (self.handle) |handle| c.zozzRawFloat4TrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawFloat4Track) u32 {
        return @intCast(c.zozzRawFloat4TrackNumKeyframes(self.handle.?));
    }

    pub fn pushKeyframe(self: RawFloat4Track, interpolation: Interpolation, ratio: f32, value: [4]f32) err.Error!void {
        try err.check(c.zozzRawFloat4TrackPushKeyframe(self.handle.?, interpolation, ratio, &value));
    }

    pub fn build(self: RawFloat4Track) err.Error!Float4Track {
        var handle: *c.Float4Track = undefined;
        try err.check(c.zozzFloat4TrackBuild(self.handle.?, &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawFloat4Track, tolerance: f32, output: RawFloat4Track) err.Error!void {
        try err.check(c.zozzRawFloat4TrackOptimize(self.handle.?, tolerance, output.handle.?));
    }
};

//=============================================================================
// QuaternionTrack
//=============================================================================

pub const QuaternionTrack = track.QuaternionTrack;

pub const RawQuaternionTrack = struct {
    handle: ?*c.RawQuaternionTrack,

    pub fn init() err.Error!RawQuaternionTrack {
        var handle: *c.RawQuaternionTrack = undefined;
        try err.check(c.zozzRawQuaternionTrackCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawQuaternionTrack) void {
        if (self.handle) |handle| c.zozzRawQuaternionTrackDestroy(handle);
        self.handle = null;
    }

    pub fn numKeyframes(self: RawQuaternionTrack) u32 {
        return @intCast(c.zozzRawQuaternionTrackNumKeyframes(self.handle.?));
    }

    /// `value` is a quaternion in (x, y, z, w) order — w LAST.
    pub fn pushKeyframe(self: RawQuaternionTrack, interpolation: Interpolation, ratio: f32, value: [4]f32) err.Error!void {
        try err.check(c.zozzRawQuaternionTrackPushKeyframe(self.handle.?, interpolation, ratio, &value));
    }

    pub fn build(self: RawQuaternionTrack) err.Error!QuaternionTrack {
        var handle: *c.QuaternionTrack = undefined;
        try err.check(c.zozzQuaternionTrackBuild(self.handle.?, &handle));
        return .{ .handle = handle };
    }

    pub fn optimize(self: RawQuaternionTrack, tolerance: f32, output: RawQuaternionTrack) err.Error!void {
        try err.check(c.zozzRawQuaternionTrackOptimize(self.handle.?, tolerance, output.handle.?));
    }
};
