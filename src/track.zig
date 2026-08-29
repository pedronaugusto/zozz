//! Runtime keyframe tracks — user-authored curves (float, vector, or
//! quaternion) sampled independently of the skeletal animation pipeline, plus
//! edge triggering over a float track.
//!
//! A track has no duration: it is sampled by ratio, the same [0, 1] unit
//! interval a `SamplingContext` uses, with 0 the start of the track and 1 the
//! end.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");

pub const FloatTrack = struct {
    handle: *c.FloatTrack,

    /// Loads a track from a `.ozz` file on disk.
    pub fn initFromFile(path: [*:0]const u8) err.Error!FloatTrack {
        var handle: *c.FloatTrack = undefined;
        try err.check(c.zozzFloatTrackLoadFile(path, &handle));
        return .{ .handle = handle };
    }

    /// Loads a track from a memory image of a `.ozz` file. The bytes are read
    /// during the call only and need not outlive it.
    pub fn initFromMemory(bytes: []const u8) err.Error!FloatTrack {
        var handle: *c.FloatTrack = undefined;
        try err.check(c.zozzFloatTrackLoadMemory(bytes.ptr, bytes.len, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: FloatTrack) void {
        c.zozzFloatTrackDestroy(self.handle);
    }

    /// Borrowed track name; "" if unnamed. Valid only while the track is
    /// alive.
    pub fn name(self: FloatTrack) [:0]const u8 {
        return std.mem.span(c.zozzFloatTrackName(self.handle));
    }

    /// Samples the track at `ratio` (out-of-range values are clamped by ozz).
    /// An empty track samples as 0.
    pub fn sample(self: FloatTrack, ratio: f32) err.Error!f32 {
        var out: f32 = undefined;
        try err.check(c.zozzFloatTrackSample(self.handle, ratio, &out));
        return out;
    }

    /// Number of authored keyframes.
    pub fn numKeyframes(self: FloatTrack) u32 {
        return @intCast(c.zozzFloatTrackNumKeyframes(self.handle));
    }

    /// Each keyframe's ratio, ascending. Allocated with `allocator`; caller
    /// frees the result.
    pub fn ratios(self: FloatTrack, allocator: std.mem.Allocator) err.Error![]f32 {
        const out = allocator.alloc(f32, self.numKeyframes()) catch return err.Error.OutOfMemory;
        errdefer allocator.free(out);
        try err.check(c.zozzFloatTrackRatios(self.handle, out.ptr, out.len));
        return out;
    }

    /// Each keyframe's authored value, index-aligned with `ratios` —
    /// `out[i]` is the value AT keyframe i, not an interpolated sample.
    /// Allocated with `allocator`; caller frees the result.
    pub fn values(self: FloatTrack, allocator: std.mem.Allocator) err.Error![]f32 {
        const out = allocator.alloc(f32, self.numKeyframes()) catch return err.Error.OutOfMemory;
        errdefer allocator.free(out);
        try err.check(c.zozzFloatTrackValues(self.handle, out.ptr, out.len));
        return out;
    }

    /// Each keyframe's interpolation mode, index-aligned with `ratios`.
    /// Allocated with `allocator`; caller frees the result.
    pub fn steps(self: FloatTrack, allocator: std.mem.Allocator) err.Error![]c.TrackInterpolation {
        const out = allocator.alloc(c.TrackInterpolation, self.numKeyframes()) catch return err.Error.OutOfMemory;
        errdefer allocator.free(out);
        try err.check(c.zozzFloatTrackSteps(self.handle, out.ptr, out.len));
        return out;
    }
};

/// The C entry points for one vector track value type, gathered so the four
/// same-shaped tracks (`Float2Track`, `Float3Track`, `Float4Track`,
/// `QuaternionTrack`) can share one implementation instead of duplicating it
/// four times by hand.
fn VectorOps(comptime Handle: type, comptime n: usize) type {
    return struct {
        loadFile: fn ([*:0]const u8, **Handle) callconv(.c) c.Result,
        loadMemory: fn ([*]const u8, usize, **Handle) callconv(.c) c.Result,
        destroy: fn (?*Handle) callconv(.c) void,
        name: fn (?*const Handle) callconv(.c) [*:0]const u8,
        sample: fn (*const Handle, f32, *[n]f32) callconv(.c) c.Result,
        numKeyframes: fn (?*const Handle) callconv(.c) c_int,
        ratios: fn (?*const Handle, [*]f32, usize) callconv(.c) c.Result,
        values: fn (?*const Handle, [*][n]f32, usize) callconv(.c) c.Result,
        steps: fn (?*const Handle, [*]c.TrackInterpolation, usize) callconv(.c) c.Result,
    };
}

fn VectorTrack(comptime Handle: type, comptime n: usize, comptime ops: VectorOps(Handle, n)) type {
    return struct {
        handle: *Handle,

        const Self = @This();

        /// Loads a track from a `.ozz` file on disk.
        pub fn initFromFile(path: [*:0]const u8) err.Error!Self {
            var handle: *Handle = undefined;
            try err.check(ops.loadFile(path, &handle));
            return .{ .handle = handle };
        }

        /// Loads a track from a memory image of a `.ozz` file. The bytes are
        /// read during the call only and need not outlive it.
        pub fn initFromMemory(bytes: []const u8) err.Error!Self {
            var handle: *Handle = undefined;
            try err.check(ops.loadMemory(bytes.ptr, bytes.len, &handle));
            return .{ .handle = handle };
        }

        pub fn deinit(self: Self) void {
            ops.destroy(self.handle);
        }

        /// Borrowed track name; "" if unnamed. Valid only while the track is
        /// alive.
        pub fn name(self: Self) [:0]const u8 {
            return std.mem.span(ops.name(self.handle));
        }

        /// Samples the track at `ratio` (out-of-range values are clamped by
        /// ozz). An empty track samples as the value type's identity (zero
        /// for a vector, the identity quaternion for `QuaternionTrack`).
        pub fn sample(self: Self, ratio: f32) err.Error![n]f32 {
            var out: [n]f32 = undefined;
            try err.check(ops.sample(self.handle, ratio, &out));
            return out;
        }

        /// Number of authored keyframes.
        pub fn numKeyframes(self: Self) u32 {
            return @intCast(ops.numKeyframes(self.handle));
        }

        /// Each keyframe's ratio, ascending. Allocated with `allocator`;
        /// caller frees the result.
        pub fn ratios(self: Self, allocator: std.mem.Allocator) err.Error![]f32 {
            const out = allocator.alloc(f32, self.numKeyframes()) catch return err.Error.OutOfMemory;
            errdefer allocator.free(out);
            try err.check(ops.ratios(self.handle, out.ptr, out.len));
            return out;
        }

        /// Each keyframe's authored value, index-aligned with `ratios` —
        /// `out[i]` is the value AT keyframe i, not an interpolated sample.
        /// Allocated with `allocator`; caller frees the result.
        pub fn values(self: Self, allocator: std.mem.Allocator) err.Error![][n]f32 {
            const out = allocator.alloc([n]f32, self.numKeyframes()) catch return err.Error.OutOfMemory;
            errdefer allocator.free(out);
            try err.check(ops.values(self.handle, out.ptr, out.len));
            return out;
        }

        /// Each keyframe's interpolation mode, index-aligned with `ratios`.
        /// Allocated with `allocator`; caller frees the result.
        pub fn steps(self: Self, allocator: std.mem.Allocator) err.Error![]c.TrackInterpolation {
            const out = allocator.alloc(c.TrackInterpolation, self.numKeyframes()) catch return err.Error.OutOfMemory;
            errdefer allocator.free(out);
            try err.check(ops.steps(self.handle, out.ptr, out.len));
            return out;
        }
    };
}

pub const Float2Track = VectorTrack(c.Float2Track, 2, .{
    .loadFile = c.zozzFloat2TrackLoadFile,
    .loadMemory = c.zozzFloat2TrackLoadMemory,
    .destroy = c.zozzFloat2TrackDestroy,
    .name = c.zozzFloat2TrackName,
    .sample = c.zozzFloat2TrackSample,
    .numKeyframes = c.zozzFloat2TrackNumKeyframes,
    .ratios = c.zozzFloat2TrackRatios,
    .values = c.zozzFloat2TrackValues,
    .steps = c.zozzFloat2TrackSteps,
});

pub const Float3Track = VectorTrack(c.Float3Track, 3, .{
    .loadFile = c.zozzFloat3TrackLoadFile,
    .loadMemory = c.zozzFloat3TrackLoadMemory,
    .destroy = c.zozzFloat3TrackDestroy,
    .name = c.zozzFloat3TrackName,
    .sample = c.zozzFloat3TrackSample,
    .numKeyframes = c.zozzFloat3TrackNumKeyframes,
    .ratios = c.zozzFloat3TrackRatios,
    .values = c.zozzFloat3TrackValues,
    .steps = c.zozzFloat3TrackSteps,
});

pub const Float4Track = VectorTrack(c.Float4Track, 4, .{
    .loadFile = c.zozzFloat4TrackLoadFile,
    .loadMemory = c.zozzFloat4TrackLoadMemory,
    .destroy = c.zozzFloat4TrackDestroy,
    .name = c.zozzFloat4TrackName,
    .sample = c.zozzFloat4TrackSample,
    .numKeyframes = c.zozzFloat4TrackNumKeyframes,
    .ratios = c.zozzFloat4TrackRatios,
    .values = c.zozzFloat4TrackValues,
    .steps = c.zozzFloat4TrackSteps,
});

/// A quaternion track. `sample` and `values` return (x, y, z, w) — w LAST,
/// matching `Transform.rotation` and every other quaternion in this package.
pub const QuaternionTrack = VectorTrack(c.QuaternionTrack, 4, .{
    .loadFile = c.zozzQuaternionTrackLoadFile,
    .loadMemory = c.zozzQuaternionTrackLoadMemory,
    .destroy = c.zozzQuaternionTrackDestroy,
    .name = c.zozzQuaternionTrackName,
    .sample = c.zozzQuaternionTrackSample,
    .numKeyframes = c.zozzQuaternionTrackNumKeyframes,
    .ratios = c.zozzQuaternionTrackRatios,
    .values = c.zozzQuaternionTrackValues,
    .steps = c.zozzQuaternionTrackSteps,
});

//=============================================================================
// Edge triggering
//=============================================================================

/// One detected threshold crossing, as reported by `TrackTriggering`.
pub const TrackEdge = struct {
    /// Ratio at which the track value crossed the threshold.
    ratio: f32,
    /// True for a rising edge (value became greater than the threshold),
    /// false for a falling edge (value became less than or equal to it).
    rising: bool,
};

/// A live edge-triggering session over a `FloatTrack`: detects where the
/// track's value crosses a threshold across a ratio range.
///
/// Borrows the track passed to `init` — the track must outlive this iterator,
/// including every call to `next`.
pub const TrackTriggering = struct {
    handle: *c.TrackTriggeringIterator,

    /// Runs edge-triggering over the ratio range [from, to] of `track`,
    /// detecting crossings of `threshold`. `from`, `to` and `threshold` may be
    /// any finite values, in any order: a `to` before `from` scans backward,
    /// and a range wider than 1 loops over the track more than once. The
    /// returned iterator is already positioned at the first edge, or past the
    /// end if `from == to` or no edge exists — check `valid` before `get`.
    pub fn init(track: FloatTrack, from: f32, to: f32, threshold: f32) err.Error!TrackTriggering {
        var handle: *c.TrackTriggeringIterator = undefined;
        try err.check(c.zozzFloatTrackTriggeringJobRun(track.handle, from, to, threshold, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: TrackTriggering) void {
        c.zozzTrackTriggeringIteratorDestroy(self.handle);
    }

    /// True if the iterator refers to a real edge (safe to pass to `get`);
    /// false once the sequence is exhausted.
    pub fn valid(self: TrackTriggering) bool {
        return c.zozzTrackTriggeringIteratorValid(self.handle);
    }

    /// Advances to the next edge. Returns `Error.InvalidArgument`, without
    /// advancing, if the iterator is already past the end.
    pub fn next(self: TrackTriggering) err.Error!void {
        try err.check(c.zozzTrackTriggeringIteratorNext(self.handle));
    }

    /// Reads the edge the iterator currently refers to. Returns
    /// `Error.InvalidArgument` if the iterator is past the end.
    pub fn get(self: TrackTriggering) err.Error!TrackEdge {
        var edge: c.TrackEdge = undefined;
        try err.check(c.zozzTrackTriggeringIteratorGet(self.handle, &edge));
        return .{ .ratio = edge.ratio, .rising = edge.rising };
    }
};
