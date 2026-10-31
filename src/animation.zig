//! A compressed animation clip.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");

/// How a time outside a clip's [0, duration] maps onto it. `ratioAt` takes
/// one; there is no default, because a clip carries no loop flag.
pub const TimeMode = enum {
    /// Time before the start holds the first pose, past the end the last.
    clamp,
    /// Time wraps, so the clip repeats forever in both directions.
    loop,
};

pub const Animation = struct {
    handle: ?*c.Animation,

    pub fn initFromFile(path: [*:0]const u8, failure: *err.Failure) err.Error!Animation {
        var handle: *c.Animation = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .animation_load_file, c.zozzAnimationLoadFile(path, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// The bytes are read during the call only and need not outlive it.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!Animation {
        const image = bytes.readForParse();
        var handle: *c.Animation = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .animation_load_memory, c.zozzAnimationLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Animation) void {
        if (self.handle) |handle| c.zozzAnimationDestroy(handle);
        self.handle = null;
    }

    /// Clip length in seconds. Always greater than zero for a loaded clip.
    pub fn duration(self: Animation) f32 {
        return c.zozzAnimationDuration(err.live(self.handle));
    }

    /// Number of animated joints, which may be fewer than the skeleton's.
    pub fn numTracks(self: Animation) u32 {
        return err.reported(u32, c.zozzAnimationNumTracks(err.live(self.handle)));
    }

    /// Borrowed clip name; empty when the clip is unnamed.
    pub fn name(self: Animation) [:0]const u8 {
        return std.mem.span(c.zozzAnimationName(err.live(self.handle)));
    }

    /// Converts a time in seconds to the unit ratio sampling expects. `mode`
    /// is not optional: ozz stores no loop flag on an Animation, so the
    /// caller states it here rather than in a `@mod` at each call site.
    pub fn ratioAt(self: Animation, seconds: f32, mode: TimeMode) f32 {
        const total = self.duration();
        if (!(total > 0) or !std.math.isFinite(seconds)) return 0;
        const raw = seconds / total;
        return switch (mode) {
            .clamp => std.math.clamp(raw, 0, 1),
            // @mod takes the divisor's sign, so -0.25 maps to 0.75 and time
            // before the clip's start plays its tail rather than its head.
            .loop => @mod(raw, 1.0),
        };
    }

    /// Number of SoA blocks matching `numTracks`: `(numTracks + 3) / 4`.
    pub fn numSoaTracks(self: Animation) u32 {
        return err.reported(u32, c.zozzAnimationNumSoaTracks(err.live(self.handle)));
    }

    /// Estimated size of the clip's compressed keyframe data, in bytes.
    pub fn size(self: Animation) usize {
        return c.zozzAnimationSize(err.live(self.handle));
    }

    /// Number of distinct time points shared across the clip's keyframes.
    pub fn numTimepoints(self: Animation) u32 {
        return err.reported(u32, c.zozzAnimationNumTimepoints(err.live(self.handle)));
    }

    /// Writes the clip's time points, in seconds and ascending order. `out`
    /// must hold at least `numTimepoints` entries.
    pub fn timepoints(self: Animation, out: []f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .animation_timepoints, c.zozzAnimationTimepoints(err.live(self.handle), out.ptr, out.len));
    }

    /// One of the three compressed keyframe streams a clip carries.
    pub const Channel = c.KeyframeChannel;

    /// Element counts of one channel's control streams, for sizing the buffers
    /// the four readers below fill.
    pub const KeyframesCtrl = c.KeyframesCtrl;

    pub fn keyframesCtrl(self: Animation, channel: Channel, failure: *err.Failure) err.Error!KeyframesCtrl {
        var out: KeyframesCtrl = undefined;
        try err.check(failure, .animation_keyframes_ctrl, c.zozzAnimationKeyframesCtrl(err.live(self.handle), channel, &out));
        return out;
    }

    /// Indices into the clip's time points. One or two bytes per keyframe,
    /// whichever the time-point count needs; ozz decides that per clip.
    pub fn keyframeRatios(self: Animation, channel: Channel, out: []u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .animation_keyframe_ratios, c.zozzAnimationKeyframeRatios(err.live(self.handle), channel, out.ptr, out.len));
    }

    pub fn keyframePreviouses(self: Animation, channel: Channel, out: []u16, failure: *err.Failure) err.Error!void {
        try err.check(failure, .animation_keyframe_previouses, c.zozzAnimationKeyframePreviouses(err.live(self.handle), channel, out.ptr, out.len));
    }

    /// Group-varint encoded; decode with the same scheme ozz's own reader uses.
    pub fn keyframeIframeEntries(self: Animation, channel: Channel, out: []u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .animation_keyframe_iframe_entries, c.zozzAnimationKeyframeIframeEntries(err.live(self.handle), channel, out.ptr, out.len));
    }

    pub fn keyframeIframeDesc(self: Animation, channel: Channel, out: []u32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .animation_keyframe_iframe_desc, c.zozzAnimationKeyframeIframeDesc(err.live(self.handle), channel, out.ptr, out.len));
    }
};
