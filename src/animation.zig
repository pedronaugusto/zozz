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
};
