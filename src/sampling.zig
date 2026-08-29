//! Sampling a clip into a pose, and flattening a pose to model space.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const Animation = @import("animation.zig").Animation;
const Skeleton = @import("skeleton.zig").Skeleton;
const SoaPose = @import("pose.zig").SoaPose;

/// Per-instance scratch that lets forward playback reuse the keyframes it
/// decompressed last frame.
///
/// One context belongs to one playing clip instance. Sharing a context between
/// two clips sampled in the same frame is not an error, but it invalidates the
/// cache on every switch and gives up the optimisation entirely.
pub const SamplingContext = struct {
    handle: *c.SamplingContext,

    /// Sizes the context for clips of at most `max_tracks` tracks. Size it
    /// from the skeleton, not one clip, if the context will be reused.
    pub fn init(max_tracks: u32) err.Error!SamplingContext {
        var handle: *c.SamplingContext = undefined;
        try err.check(c.zozzSamplingContextCreate(@intCast(max_tracks), &handle));
        return .{ .handle = handle };
    }

    pub fn initForSkeleton(skeleton: Skeleton) err.Error!SamplingContext {
        return init(skeleton.numJoints());
    }

    pub fn deinit(self: SamplingContext) void {
        c.zozzSamplingContextDestroy(self.handle);
    }

    /// Resizes the context in place for clips of at most `max_tracks`
    /// tracks, discarding whatever allocation it already held — the effect
    /// of `deinit` + `init` without giving up the handle, for reusing one
    /// context across differently-sized skeletons instead of destroying and
    /// recreating it each time. Also invalidates the context, exactly like
    /// `invalidate`.
    pub fn resize(self: SamplingContext, max_tracks: u32) err.Error!void {
        try err.check(c.zozzSamplingContextResize(self.handle, @intCast(max_tracks)));
    }

    pub fn maxTracks(self: SamplingContext) u32 {
        return @intCast(c.zozzSamplingContextMaxTracks(self.handle));
    }

    /// Drops the cached keyframe state.
    ///
    /// Required when a context may be reused with a different animation that
    /// could have been allocated at a recycled address: ozz detects a clip
    /// change by pointer identity, so a new clip at an old address would
    /// otherwise reuse stale cursors.
    pub fn invalidate(self: SamplingContext) void {
        c.zozzSamplingContextInvalidate(self.handle);
    }
};

/// Mirrors `ozz::animation::SamplingJob`. Samples `animation` at `ratio` in
/// the unit interval, writing local-space transforms into `out`. Values
/// outside [0, 1] are clamped by ozz; NaN is rejected. Joints past the clip's
/// track count are left untouched — seed `out` with the rest pose first when
/// the clip is partial.
pub const SamplingJob = struct {
    animation: Animation,
    context: SamplingContext,
    ratio: f32,
    out: SoaPose,

    /// Runs the sampling job.
    pub fn run(self: SamplingJob) err.Error!void {
        try err.check(c.zozzSample(self.animation.handle, self.context.handle, self.ratio, self.out.handle));
    }
};

/// Mirrors `ozz::animation::LocalToModelJob`: walks the joint hierarchy,
/// turning local-space transforms into model-space matrices. `root`
/// pre-multiplies the whole hierarchy; pass null for identity. `out` must
/// hold at least the skeleton's joint count and, being 16-byte-aligned
/// matrices, must itself start on a 16-byte boundary. `from`/`to`/
/// `from_excluded` narrow the walk to one chain (default: whole hierarchy).
pub const LocalToModelJob = struct {
    skeleton: Skeleton,
    locals: SoaPose,
    root: ?*const math.Mat4,
    out: []math.Mat4,

    /// First joint to update, or `null` for the root. `out` must still cover
    /// every joint either way: ancestors outside the range are read to place
    /// the ones inside it.
    from: ?u32 = null,
    /// Last joint to update, inclusive, or `null` for the last joint.
    to: ?u32 = null,
    /// Leave `from` itself untouched and start at its children. It must
    /// already hold a valid model-space matrix in `out`, since its children
    /// are expressed relative to it — this is the combination that finishes a
    /// chain whose first joint the correction already moved.
    from_excluded: bool = false,

    /// Runs the local-to-model job.
    pub fn run(self: LocalToModelJob) err.Error!void {
        // The unrestricted walk keeps its own entry point rather than passing
        // sentinels to the range one: it is the common case, it is what a C
        // caller reaches for, and routing both through one of them would mean
        // only one of the two was ever exercised.
        if (self.from == null and self.to == null and !self.from_excluded) {
            return err.check(c.zozzLocalToModel(
                self.skeleton.handle,
                self.locals.handle,
                self.root,
                self.out.ptr,
                self.out.len,
            ));
        }
        try err.check(c.zozzLocalToModelRange(
            self.skeleton.handle,
            self.locals.handle,
            self.root,
            if (self.from) |f| @intCast(f) else c.no_parent,
            if (self.to) |t| @intCast(t) else std.math.maxInt(c_int),
            @intFromBool(self.from_excluded),
            self.out.ptr,
            self.out.len,
        ));
    }
};
