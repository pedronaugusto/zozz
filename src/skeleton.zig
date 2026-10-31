//! Joint hierarchy and rest pose.

const std = @import("std");
const aegis = @import("aegis");
const c = @import("c.zig");
const err = @import("error.zig");
const file = @import("file.zig");
const math = @import("math.zig");

/// The parent index a root joint reports. Re-exported from `c.zig`, where
/// the literal lives so that `abi_test.zig` compares it against the
/// header's `ZOZZ_NO_PARENT` — a second literal here would be a second
/// thing to get wrong.
pub const no_parent = c.no_parent;

/// ozz's own `Skeleton::kMaxJoints`: the largest joint count a skeleton may
/// have, and the value `LocalToModelJob.to` takes to mean "the last joint".
/// Re-exported from `c.zig` for the same reason as `no_parent`.
pub const max_joints = c.max_joints;

pub const Skeleton = struct {
    handle: ?*c.Skeleton,

    /// Loads a skeleton from a `.ozz` file: the file at `sub_path` in `dir`,
    /// read whole through `io`, at most `limit` bytes, and parsed as
    /// `initFromMemory` parses. `file.readImage` names its refusals.
    pub fn initFromFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, limit: file.Limit, failure: *err.Failure) err.Error!Skeleton {
        const image = try file.readImage(gpa, io, dir, sub_path, limit, .skeleton_load_file, failure);
        defer gpa.free(image);
        return initFromMemory(.init(image), failure);
    }

    /// Loads a skeleton from a memory image of a `.ozz` file. The bytes are
    /// read during the call only and need not outlive it.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!Skeleton {
        const image = bytes.readForParse();
        var handle: *c.Skeleton = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .skeleton_load_memory, c.zozzSkeletonLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Skeleton) void {
        if (self.handle) |handle| c.zozzSkeletonDestroy(handle);
        self.handle = null;
    }

    pub fn numJoints(self: Skeleton) u32 {
        return err.reported(u32, c.zozzSkeletonNumJoints(err.live(self.handle)));
    }

    /// Number of SoA blocks the skeleton occupies: `(numJoints + 3) / 4`.
    pub fn numSoaJoints(self: Skeleton) u32 {
        return err.reported(u32, c.zozzSkeletonNumSoaJoints(err.live(self.handle)));
    }

    /// Borrowed joint name, or null when `joint` is out of range. Valid only
    /// while the skeleton is alive.
    pub fn jointName(self: Skeleton, joint: u32) ?[:0]const u8 {
        const index = aegis.int.narrow(c_int, joint) orelse return null;
        const name = c.zozzSkeletonJointName(err.live(self.handle), index) orelse return null;
        return std.mem.span(name);
    }

    /// Parent joint index, or `no_parent` for a root. Out-of-range indices
    /// also report `no_parent`; check `numJoints` when the difference matters.
    pub fn jointParent(self: Skeleton, joint: u32) i16 {
        const index = aegis.int.narrow(c_int, joint) orelse return no_parent;
        return c.zozzSkeletonJointParent(err.live(self.handle), index);
    }

    /// ozz's own parent array, in depth-first order, borrowed: no copy and
    /// no allocation, valid while the skeleton is alive. One crossing for the
    /// whole hierarchy, where `jointParent` costs one per joint. Empty for a
    /// skeleton with no joints.
    pub fn jointParents(self: Skeleton) []const i16 {
        var count: usize = 0;
        const ptr = c.zozzSkeletonJointParents(err.live(self.handle), &count) orelse
            return &.{};
        return ptr[0..count];
    }

    /// ozz's own name array, borrowed on the same terms. Each entry is a
    /// NUL-terminated name owned by the skeleton; `std.mem.span` turns one
    /// into a slice when a slice is what the caller wants.
    pub fn jointNames(self: Skeleton) []const [*:0]const u8 {
        var count: usize = 0;
        const ptr = c.zozzSkeletonJointNames(err.live(self.handle), &count) orelse
            return &.{};
        return ptr[0..count];
    }

    /// ozz's own rest pose, SoA and untransposed, borrowed on the same terms.
    /// The slice is `numSoaJoints` blocks long. `restPoseSoa` below is the
    /// copying twin, for a caller that means to WRITE the pose it seeds.
    pub fn jointRestPoses(self: Skeleton) []const math.SoaTransform {
        var count: usize = 0;
        const ptr = c.zozzSkeletonJointRestPoses(err.live(self.handle), &count) orelse
            return &.{};
        return ptr[0..count];
    }

    /// Writes the rest pose as local transforms. `out` must hold at least
    /// `numJoints` entries.
    pub fn restPose(self: Skeleton, out: []math.Transform, failure: *err.Failure) err.Error!void {
        try err.check(failure, .skeleton_rest_pose, c.zozzSkeletonRestPose(err.live(self.handle), out.ptr, out.len));
    }

    /// Copies ozz's own `joint_rest_poses` into `out`, no transpose. Seed a
    /// pose with this before sampling a clip that drives only some of the
    /// skeleton's joints: the ones the clip misses keep the rest pose.
    /// `out` must hold at least `numSoaJoints` blocks.
    pub fn restPoseSoa(self: Skeleton, out: []math.SoaTransform, failure: *err.Failure) err.Error!void {
        try err.check(failure, .skeleton_rest_pose_soa, c.zozzSkeletonRestPoseSoa(err.live(self.handle), out.ptr, out.len));
    }
};
