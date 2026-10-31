//! Skeleton and animation utilities beyond the core accessors: single-joint
//! rest pose, hierarchy traversal, name lookup, and per-track key counts.
//!
//! Free functions rather than methods, mirroring ozz's own skeleton_utils.h
//! and animation_utils.h: standalone functions over `Skeleton` and
//! `Animation`, not members of either.

const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const Skeleton = @import("skeleton.zig").Skeleton;
const Animation = @import("animation.zig").Animation;

/// Local-space rest transform of a single joint, without reading the rest of
/// the skeleton.
pub fn jointRestPoseLocal(skeleton: Skeleton, joint: u32, failure: *err.Failure) err.Error!math.Transform {
    var out: math.Transform = undefined;
    const joint_index = try err.narrow(failure, .skeleton_joint_rest_pose_local, c_int, joint);
    try err.check(failure, .skeleton_joint_rest_pose_local, c.zozzSkeletonJointRestPoseLocal(skeleton.handle, joint_index, &out));
    return out;
}

/// Rest pose in model space, computed by walking the joint hierarchy once.
/// `out` must hold at least `skeleton.numJoints()` entries and, being an
/// array of 16-byte-aligned matrices, must itself start on a 16-byte
/// boundary.
pub fn restPoseModelSpace(skeleton: Skeleton, out: []math.Mat4, failure: *err.Failure) err.Error!void {
    try err.check(failure, .skeleton_rest_pose_model_space, c.zozzSkeletonRestPoseModelSpace(skeleton.handle, out.ptr, out.len));
}

/// True if `joint` has no children: it is the last joint, or the next
/// joint's parent is not `joint`.
pub fn jointIsLeaf(skeleton: Skeleton, joint: u32, failure: *err.Failure) err.Error!bool {
    var out: bool = undefined;
    const joint_index = try err.narrow(failure, .skeleton_joint_is_leaf, c_int, joint);
    try err.check(failure, .skeleton_joint_is_leaf, c.zozzSkeletonJointIsLeaf(skeleton.handle, joint_index, &out));
    return out;
}

/// Finds a joint by exact, case-sensitive name. Null if no joint matches.
pub fn findJoint(skeleton: Skeleton, name: [:0]const u8) ?u32 {
    const joint = c.zozzSkeletonFindJoint(skeleton.handle, name);
    return if (joint < 0) null else err.reported(u32, joint);
}

/// Depth-first traversal starting at `from` (`no_parent`, from `skeleton.zig`,
/// traverses the whole hierarchy, including every root when the skeleton has
/// more than one). `context` must be a pointer; it is handed back to `visit`
/// unchanged. The callback is infallible, matching ozz's own functor
/// contract: nothing that could unwind or need re-raising crosses the C
/// boundary.
pub fn iterateJointsDepthFirst(
    skeleton: Skeleton,
    from: i32,
    context: anytype,
    comptime visit: fn (@TypeOf(context), joint: u32, parent: i32) void,
    failure: *err.Failure,
) err.Error!void {
    const Context = @TypeOf(context);
    comptime if (@typeInfo(Context) != .pointer) {
        @compileError("iterateJointsDepthFirst: context must be a pointer");
    };

    const Trampoline = struct {
        fn call(joint: c_int, parent: c_int, user: ?*anyopaque) callconv(.c) void {
            const ctx: Context = @ptrCast(@alignCast(user.?)); // aegis: no-danger: user is the caller's context, which this function handed the C side and it hands back unchanged
            visit(ctx, err.reported(u32, joint), parent);
        }
    };
    try err.check(failure, .skeleton_iterate_joints_depth_first, c.zozzSkeletonIterateJointsDepthFirst(
        skeleton.handle,
        from,
        &Trampoline.call,
        @ptrCast(context), // aegis: no-danger: the caller's context as the C side's opaque user pointer, read back only by the trampoline
    ));
}

/// Depth-first traversal of the whole hierarchy in reverse: every joint
/// before its parent, leaves before roots. See `iterateJointsDepthFirst` for
/// the `context`/`visit` contract.
pub fn iterateJointsDepthFirstReverse(
    skeleton: Skeleton,
    context: anytype,
    comptime visit: fn (@TypeOf(context), joint: u32, parent: i32) void,
    failure: *err.Failure,
) err.Error!void {
    const Context = @TypeOf(context);
    comptime if (@typeInfo(Context) != .pointer) {
        @compileError("iterateJointsDepthFirstReverse: context must be a pointer");
    };

    const Trampoline = struct {
        fn call(joint: c_int, parent: c_int, user: ?*anyopaque) callconv(.c) void {
            const ctx: Context = @ptrCast(@alignCast(user.?)); // aegis: no-danger: user is the caller's context, which this function handed the C side and it hands back unchanged
            visit(ctx, err.reported(u32, joint), parent);
        }
    };
    try err.check(failure, .skeleton_iterate_joints_depth_first_reverse, c.zozzSkeletonIterateJointsDepthFirstReverse(
        skeleton.handle,
        &Trampoline.call,
        @ptrCast(context), // aegis: no-danger: the caller's context as the C side's opaque user pointer, read back only by the trampoline
    ));
}

/// Selects one track for the `countXKeys` functions below, or every track
/// together when `null`.
pub const TrackSelector = ?u32;

/// `track` as the C boundary takes it, -1 for every track; a track it
/// cannot carry is refused as `call`.
fn trackArg(track: TrackSelector, call: err.Call, failure: *err.Failure) err.Error!c_int {
    return if (track) |t| err.narrow(failure, call, c_int, t) else -1;
}

/// Counts translation keyframes. `track` selects one track, or every track
/// together when `null`.
pub fn countTranslationKeys(animation: Animation, track: TrackSelector, failure: *err.Failure) err.Error!u32 {
    const selected = try trackArg(track, .animation_count_translation_keys, failure);
    var out: c_int = undefined;
    try err.check(failure, .animation_count_translation_keys, c.zozzAnimationCountTranslationKeys(animation.handle, selected, &out));
    return err.reported(u32, out);
}

/// Counts rotation keyframes. See `countTranslationKeys`.
pub fn countRotationKeys(animation: Animation, track: TrackSelector, failure: *err.Failure) err.Error!u32 {
    const selected = try trackArg(track, .animation_count_rotation_keys, failure);
    var out: c_int = undefined;
    try err.check(failure, .animation_count_rotation_keys, c.zozzAnimationCountRotationKeys(animation.handle, selected, &out));
    return err.reported(u32, out);
}

/// Counts scale keyframes. See `countTranslationKeys`.
pub fn countScaleKeys(animation: Animation, track: TrackSelector, failure: *err.Failure) err.Error!u32 {
    const selected = try trackArg(track, .animation_count_scale_keys, failure);
    var out: c_int = undefined;
    try err.check(failure, .animation_count_scale_keys, c.zozzAnimationCountScaleKeys(animation.handle, selected, &out));
    return err.reported(u32, out);
}
