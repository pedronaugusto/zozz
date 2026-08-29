//! A compressed animation clip.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");

pub const Animation = struct {
    handle: *c.Animation,

    pub fn initFromFile(path: [*:0]const u8) err.Error!Animation {
        var handle: *c.Animation = undefined;
        try err.check(c.zozzAnimationLoadFile(path, &handle));
        return .{ .handle = handle };
    }

    /// The bytes are read during the call only and need not outlive it.
    pub fn initFromMemory(bytes: []const u8) err.Error!Animation {
        var handle: *c.Animation = undefined;
        try err.check(c.zozzAnimationLoadMemory(bytes.ptr, bytes.len, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: Animation) void {
        c.zozzAnimationDestroy(self.handle);
    }

    /// Clip length in seconds. Always greater than zero for a loaded clip.
    pub fn duration(self: Animation) f32 {
        return c.zozzAnimationDuration(self.handle);
    }

    /// Number of animated joints, which may be fewer than the skeleton's.
    pub fn numTracks(self: Animation) u32 {
        return @intCast(c.zozzAnimationNumTracks(self.handle));
    }

    /// Borrowed clip name; empty when the clip is unnamed.
    pub fn name(self: Animation) [:0]const u8 {
        return std.mem.span(c.zozzAnimationName(self.handle));
    }

    /// Converts a time in seconds to the unit ratio sampling expects.
    /// Values outside the clip are clamped, matching ozz.
    pub fn ratioAt(self: Animation, seconds: f32) f32 {
        const total = self.duration();
        if (!(total > 0)) return 0;
        return std.math.clamp(seconds / total, 0, 1);
    }

    /// Number of SoA blocks matching `numTracks`: `(numTracks + 3) / 4`.
    pub fn numSoaTracks(self: Animation) u32 {
        return @intCast(c.zozzAnimationNumSoaTracks(self.handle));
    }

    /// Estimated size of the clip's compressed keyframe data, in bytes.
    pub fn size(self: Animation) usize {
        return c.zozzAnimationSize(self.handle);
    }

    /// Number of distinct time points shared across the clip's keyframes.
    pub fn numTimepoints(self: Animation) u32 {
        return @intCast(c.zozzAnimationNumTimepoints(self.handle));
    }

    /// Writes the clip's time points, in seconds and ascending order. `out`
    /// must hold at least `numTimepoints` entries.
    pub fn timepoints(self: Animation, out: []f32) err.Error!void {
        try err.check(c.zozzAnimationTimepoints(self.handle, out.ptr, out.len));
    }

    /// One of the three compressed keyframe streams a clip carries.
    pub const Channel = c.KeyframeChannel;

    /// Element counts of one channel's control streams, for sizing the buffers
    /// the four readers below fill.
    pub const KeyframesCtrl = c.KeyframesCtrl;

    pub fn keyframesCtrl(self: Animation, channel: Channel) err.Error!KeyframesCtrl {
        var out: KeyframesCtrl = undefined;
        try err.check(c.zozzAnimationKeyframesCtrl(self.handle, channel, &out));
        return out;
    }

    /// Indices into the clip's time points. One or two bytes per keyframe,
    /// whichever the time-point count needs; ozz decides that per clip.
    pub fn keyframeRatios(self: Animation, channel: Channel, out: []u8) err.Error!void {
        try err.check(c.zozzAnimationKeyframeRatios(self.handle, channel, out.ptr, out.len));
    }

    pub fn keyframePreviouses(self: Animation, channel: Channel, out: []u16) err.Error!void {
        try err.check(c.zozzAnimationKeyframePreviouses(self.handle, channel, out.ptr, out.len));
    }

    /// Group-varint encoded; decode with the same scheme ozz's own reader uses.
    pub fn keyframeIframeEntries(self: Animation, channel: Channel, out: []u8) err.Error!void {
        try err.check(c.zozzAnimationKeyframeIframeEntries(self.handle, channel, out.ptr, out.len));
    }

    pub fn keyframeIframeDesc(self: Animation, channel: Channel, out: []u32) err.Error!void {
        try err.check(c.zozzAnimationKeyframeIframeDesc(self.handle, channel, out.ptr, out.len));
    }
};
