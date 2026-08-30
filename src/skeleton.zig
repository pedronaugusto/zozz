//! Joint hierarchy and rest pose.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");

/// The parent index a root joint reports. Re-exported from `c.zig`, where
/// the literal lives so that `abi_check.zig` compares it against the
/// header's `ZOZZ_NO_PARENT` — a second literal here would be a second
/// thing to get wrong.
pub const no_parent = c.no_parent;

/// ozz's own `Skeleton::kMaxJoints`: the largest joint count a skeleton may
/// have, and the value `LocalToModelJob.to` takes to mean "the last joint".
/// Re-exported from `c.zig` for the same reason as `no_parent`.
pub const max_joints = c.max_joints;

pub const Skeleton = struct {
    handle: *c.Skeleton,

    /// Loads a skeleton from a `.ozz` file on disk.
    ///
    /// `path` is passed straight to the C runtime's `fopen`, so it must be a
    /// native path in the platform's encoding.
    pub fn initFromFile(path: [*:0]const u8) err.Error!Skeleton {
        var handle: *c.Skeleton = undefined;
        try err.check(c.zozzSkeletonLoadFile(path, &handle));
        return .{ .handle = handle };
    }

    /// Loads a skeleton from a memory image of a `.ozz` file. The bytes are
    /// read during the call only and need not outlive it.
    pub fn initFromMemory(bytes: []const u8) err.Error!Skeleton {
        var handle: *c.Skeleton = undefined;
        try err.check(c.zozzSkeletonLoadMemory(bytes.ptr, bytes.len, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: Skeleton) void {
        c.zozzSkeletonDestroy(self.handle);
    }

    pub fn numJoints(self: Skeleton) u32 {
        return @intCast(c.zozzSkeletonNumJoints(self.handle));
    }

    /// Number of SoA blocks the skeleton occupies: `(numJoints + 3) / 4`.
    pub fn numSoaJoints(self: Skeleton) u32 {
        return @intCast(c.zozzSkeletonNumSoaJoints(self.handle));
    }

    /// Borrowed joint name, or null when `joint` is out of range. Valid only
    /// while the skeleton is alive.
    pub fn jointName(self: Skeleton, joint: u32) ?[:0]const u8 {
        const name = c.zozzSkeletonJointName(self.handle, @intCast(joint)) orelse return null;
        return std.mem.span(name);
    }

    /// Parent joint index, or `no_parent` for a root. Out-of-range indices
    /// also report `no_parent`; check `numJoints` when the difference matters.
    pub fn jointParent(self: Skeleton, joint: u32) i16 {
        return c.zozzSkeletonJointParent(self.handle, @intCast(joint));
    }

    /// Writes the rest pose as local transforms. `out` must hold at least
    /// `numJoints` entries.
    pub fn restPose(self: Skeleton, out: []math.Transform) err.Error!void {
        try err.check(c.zozzSkeletonRestPose(self.handle, out.ptr, out.len));
    }

    /// Copies ozz's own `joint_rest_poses` into `out`, no transpose. Seed a
    /// pose with this before sampling a clip that drives only some of the
    /// skeleton's joints: the ones the clip misses keep the rest pose.
    /// `out` must hold at least `numSoaJoints` blocks.
    pub fn restPoseSoa(self: Skeleton, out: []math.SoaTransform) err.Error!void {
        try err.check(c.zozzSkeletonRestPoseSoa(self.handle, out.ptr, out.len));
    }
};
