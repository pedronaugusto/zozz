//! Offline builders: author a skeleton or an animation at runtime, ozz's
//! offline pipeline (`RawSkeleton` -> `SkeletonBuilder`, `RawAnimation` ->
//! `AnimationBuilder`) behind the package's usual handle rules. Building yields
//! the same runtime `Skeleton` / `Animation` the loaders produce, so everything
//! downstream (sampling, local-to-model) is shared.
//!
//! Joint order: built skeletons store joints DEPTH-FIRST. Add joints
//! depth-first and built indices equal insertion indices; otherwise map through
//! `Skeleton.jointName`. Animation tracks pair with BUILT joint indices by
//! convention — the raw animation never sees a skeleton. Empty tracks bake
//! IDENTITY, never the skeleton's rest pose, which the builder never sees; a
//! consumer needing "unanimated = rest pose" must author rest-pose keys itself.
//! Pinned by test below.

const std = @import("std");
const aegis = @import("aegis");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");
const skeleton_mod = @import("skeleton.zig");
const animation_mod = @import("animation.zig");

/// A skeleton under construction: a flat list of (parent, name, rest) joints.
pub const RawSkeleton = struct {
    handle: ?*c.RawSkeleton,

    pub fn init(failure: *err.Failure) err.Error!RawSkeleton {
        var handle: *c.RawSkeleton = undefined;
        try err.check(failure, .raw_skeleton_create, c.zozzRawSkeletonCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawSkeleton) void {
        if (self.handle) |handle| c.zozzRawSkeletonDestroy(handle);
        self.handle = null;
    }

    /// Appends a joint and returns its insertion index. `parent` is null for
    /// a root, else the insertion index of an already-added joint. `name`
    /// is borrowed for the duration of the call only.
    pub fn addJoint(
        self: RawSkeleton,
        parent: ?u32,
        name: [*:0]const u8,
        rest: math.Transform,
        failure: *err.Failure,
    ) err.Error!u32 {
        var index: i32 = undefined;
        const parent_c: i32 = if (parent) |p| try err.narrow(failure, .raw_skeleton_add_joint, i32, p) else -1;
        try err.check(failure, .raw_skeleton_add_joint, c.zozzRawSkeletonAddJoint(err.live(self.handle), parent_c, name, &rest, &index));
        return err.reported(u32, index);
    }

    pub fn numJoints(self: RawSkeleton) u32 {
        return err.reported(u32, c.zozzRawSkeletonNumJoints(err.live(self.handle)));
    }

    /// Borrowed name of the joint at insertion index `joint` — the index
    /// `addJoint` returned, not a position in the depth-first tree `build`
    /// produces. Null if `joint` is out of range. Valid only while `self` is
    /// alive.
    pub fn jointName(self: RawSkeleton, joint: u32) ?[:0]const u8 {
        const index = aegis.int.narrow(i32, joint) orelse return null;
        const name = c.zozzRawSkeletonJointName(err.live(self.handle), index) orelse return null;
        return std.mem.span(name);
    }

    /// Parent's insertion index, or null for a root. Out-of-range indices
    /// also report null; check `numJoints` when the difference matters.
    pub fn jointParent(self: RawSkeleton, joint: u32) ?u32 {
        const index = aegis.int.narrow(i32, joint) orelse return null;
        const parent = c.zozzRawSkeletonJointParent(err.live(self.handle), index);
        return if (parent < 0) null else err.reported(u32, parent);
    }

    /// The local-space rest transform authored for the joint at insertion
    /// index `joint` — exactly what was last passed to `addJoint` for it.
    pub fn jointRest(self: RawSkeleton, joint: u32, failure: *err.Failure) err.Error!math.Transform {
        var out: math.Transform = undefined;
        const joint_index = try err.narrow(failure, .raw_skeleton_joint_rest, i32, joint);
        try err.check(failure, .raw_skeleton_joint_rest, c.zozzRawSkeletonJointRest(err.live(self.handle), joint_index, &out));
        return out;
    }

    /// Breadth-first traversal of the authored hierarchy, addressed by
    /// insertion index, not the built index `build` assigns. `context` must be
    /// a pointer, handed back to `visit` unchanged; `visit` must be infallible
    /// -- nothing may unwind across this boundary. With multiple roots, or
    /// subtrees of different depths, this is NOT one global level order: a
    /// grandchild of the first root can visit before a child of the second.
    pub fn iterateJointsBreadthFirst(
        self: RawSkeleton,
        context: anytype,
        comptime visit: fn (@TypeOf(context), joint: u32, parent: ?u32) void,
        failure: *err.Failure,
    ) err.Error!void {
        const Context = @TypeOf(context);
        comptime if (@typeInfo(Context) != .pointer) {
            @compileError("iterateJointsBreadthFirst: context must be a pointer");
        };

        const Trampoline = struct {
            fn call(joint: c_int, parent: c_int, user: ?*anyopaque) callconv(.c) void {
                const ctx: Context = @ptrCast(@alignCast(user.?)); // aegis: no-danger: user is the caller's context, which this function handed the C side and it hands back unchanged
                const parent_joint: ?u32 = if (parent < 0) null else err.reported(u32, parent);
                visit(ctx, err.reported(u32, joint), parent_joint);
            }
        };
        try err.check(failure, .raw_skeleton_iterate_joints_breadth_first, c.zozzRawSkeletonIterateJointsBreadthFirst(
            err.live(self.handle),
            &Trampoline.call,
            @ptrCast(context), // aegis: no-danger: the caller's context as the C side's opaque user pointer, read back only by the trampoline
        ));
    }

    /// Loads a raw skeleton from a `.ozz` archive written by
    /// `archive.saveRawSkeletonToFile` or `OArchive.saveRawSkeleton`.
    ///
    /// Joints come back in DEPTH-FIRST order, not the order they were
    /// authored in — the same reindexing `build` performs. Names, parents
    /// and rest transforms all survive. Pinned by test.
    pub fn initFromFile(path: [*:0]const u8, failure: *err.Failure) err.Error!RawSkeleton {
        var handle: *c.RawSkeleton = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_skeleton_load_file, c.zozzRawSkeletonLoadFile(path, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// The same, from a memory image. The bytes are read during the call only
    /// and need not outlive it.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!RawSkeleton {
        const image = bytes.readForParse();
        var handle: *c.RawSkeleton = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_skeleton_load_memory, c.zozzRawSkeletonLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// ozz's `RawSkeleton::Validate()`: the joint count is within
    /// `max_joints`. `addJoint` already refuses the joint that would exceed
    /// it, so a skeleton authored through this API always validates — one
    /// filled by an importer or read back from an archive did not go through
    /// that door.
    pub fn validate(self: RawSkeleton) bool {
        return c.zozzRawSkeletonValidate(err.live(self.handle));
    }

    /// Validates and builds a runtime skeleton. The raw skeleton is not
    /// consumed; it may be built again or extended further.
    pub fn build(self: RawSkeleton, failure: *err.Failure) err.Error!skeleton_mod.Skeleton {
        var handle: *c.Skeleton = undefined;
        try err.check(failure, .skeleton_build, c.zozzSkeletonBuild(err.live(self.handle), &handle));
        return .{ .handle = handle };
    }
};

/// An animation under construction: per-track keyed T/R/S channels.
pub const RawAnimation = struct {
    handle: ?*c.RawAnimation,

    /// `num_tracks` is fixed for the clip's lifetime; `duration_seconds` is
    /// finite and positive. `clip_name` may be null for an unnamed clip, and
    /// is read back by `name` below; a parameter of that name would shadow
    /// the accessor.
    pub fn init(num_tracks: u32, duration_seconds: f32, clip_name: ?[*:0]const u8, failure: *err.Failure) err.Error!RawAnimation {
        var handle: *c.RawAnimation = undefined;
        const tracks = try err.narrow(failure, .raw_animation_create, c_int, num_tracks);
        try err.check(failure, .raw_animation_create, c.zozzRawAnimationCreate(tracks, duration_seconds, clip_name, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *RawAnimation) void {
        if (self.handle) |handle| c.zozzRawAnimationDestroy(handle);
        self.handle = null;
    }

    pub fn numTracks(self: RawAnimation) u32 {
        return err.reported(u32, c.zozzRawAnimationNumTracks(err.live(self.handle)));
    }

    pub fn duration(self: RawAnimation) f32 {
        return c.zozzRawAnimationDuration(err.live(self.handle));
    }

    /// Appends one translation key. `time` must lie within `[0, duration]`;
    /// keys must arrive in non-decreasing time order per channel (violations
    /// surface at `build` as `error.InvalidData`).
    pub fn pushTranslation(self: RawAnimation, track: u32, time: f32, value: [3]f32, failure: *err.Failure) err.Error!void {
        const track_index = try err.narrow(failure, .raw_animation_push_translation, c_int, track);
        try err.check(failure, .raw_animation_push_translation, c.zozzRawAnimationPushTranslation(err.live(self.handle), track_index, time, &value));
    }

    /// Appends one rotation key: a quaternion in (x, y, z, w) order — w LAST.
    pub fn pushRotation(self: RawAnimation, track: u32, time: f32, value: [4]f32, failure: *err.Failure) err.Error!void {
        const track_index = try err.narrow(failure, .raw_animation_push_rotation, c_int, track);
        try err.check(failure, .raw_animation_push_rotation, c.zozzRawAnimationPushRotation(err.live(self.handle), track_index, time, &value));
    }

    /// Appends one scale key.
    pub fn pushScale(self: RawAnimation, track: u32, time: f32, value: [3]f32, failure: *err.Failure) err.Error!void {
        const track_index = try err.narrow(failure, .raw_animation_push_scale, c_int, track);
        try err.check(failure, .raw_animation_push_scale, c.zozzRawAnimationPushScale(err.live(self.handle), track_index, time, &value));
    }

    /// Loads a raw animation from a `.ozz` archive written by
    /// `archive.saveRawAnimationToFile` or `OArchive.saveRawAnimation`.
    pub fn initFromFile(path: [*:0]const u8, failure: *err.Failure) err.Error!RawAnimation {
        var handle: *c.RawAnimation = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_animation_load_file, c.zozzRawAnimationLoadFile(path, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// The same, from a memory image. The bytes are read during the call only
    /// and need not outlive it.
    pub fn initFromMemory(bytes: err.Bytes, failure: *err.Failure) err.Error!RawAnimation {
        const image = bytes.readForParse();
        var handle: *c.RawAnimation = undefined;
        var refusal: c.Refusal = .{};
        try err.checkLoad(failure, .raw_animation_load_memory, c.zozzRawAnimationLoadMemory(image.ptr, image.len, &handle, &refusal), refusal);
        return .{ .handle = handle };
    }

    /// ozz's `RawAnimation::Validate()`: duration positive, key times within
    /// `[0, duration]` and strictly ascending per channel. The same answer
    /// `build` reports as `error.InvalidData`, available before the build.
    pub fn validate(self: RawAnimation) bool {
        return c.zozzRawAnimationValidate(err.live(self.handle));
    }

    /// ozz's `RawAnimation::size()`: the authored data's footprint in bytes.
    /// The OFFLINE size — `Animation.size` is the built clip's.
    pub fn size(self: RawAnimation) usize {
        return c.zozzRawAnimationSize(err.live(self.handle));
    }

    /// Borrowed clip name, `""` when unnamed. Valid until the clip is
    /// destroyed or renamed.
    pub fn name(self: RawAnimation) [:0]const u8 {
        return std.mem.span(c.zozzRawAnimationName(err.live(self.handle)).?);
    }

    /// Renames the clip; `new_name` may be null, which clears it to `""`. The
    /// string is copied.
    pub fn setName(self: RawAnimation, new_name: ?[*:0]const u8, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_animation_set_name, c.zozzRawAnimationSetName(err.live(self.handle), new_name));
    }

    /// Retimes the clip. Shortening it does NOT move or drop the keys past
    /// the new end — ozz keeps duration as a plain field and so does this;
    /// they are left out of range, which `validate` reports and `build`
    /// refuses. Clear the channel and push retimed keys to do it properly.
    pub fn setDuration(self: RawAnimation, seconds: f32, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_animation_set_duration, c.zozzRawAnimationSetDuration(err.live(self.handle), seconds));
    }

    /// Number of keys on `track`'s translation channel; 0 for a track index
    /// this clip does not have.
    pub fn numTranslations(self: RawAnimation, track: u32) u32 {
        const index = aegis.int.narrow(c_int, track) orelse return 0;
        return err.reported(u32, c.zozzRawAnimationNumTranslations(err.live(self.handle), index));
    }

    pub fn numRotations(self: RawAnimation, track: u32) u32 {
        const index = aegis.int.narrow(c_int, track) orelse return 0;
        return err.reported(u32, c.zozzRawAnimationNumRotations(err.live(self.handle), index));
    }

    pub fn numScales(self: RawAnimation, track: u32) u32 {
        const index = aegis.int.narrow(c_int, track) orelse return 0;
        return err.reported(u32, c.zozzRawAnimationNumScales(err.live(self.handle), index));
    }

    /// Copies `track`'s translation keys into `out` and returns the prefix
    /// that was written. `out` must hold at least `numTranslations`, else
    /// `error.BufferTooSmall` and nothing is written. Caller-owned memory:
    /// this never allocates, so a cook loop can read every track through one
    /// buffer it sized once.
    pub fn translations(
        self: RawAnimation,
        track: u32,
        out: []TranslationKey,
        failure: *err.Failure,
    ) err.Error![]TranslationKey {
        const count = self.numTranslations(track);
        const track_index = try err.narrow(failure, .raw_animation_translations, c_int, track);
        try err.check(failure, .raw_animation_translations, c.zozzRawAnimationTranslations(err.live(self.handle), track_index, out.ptr, out.len));
        return out[0..count];
    }

    /// See `translations`. Rotations are (x, y, z, w) — w last.
    pub fn rotations(
        self: RawAnimation,
        track: u32,
        out: []RotationKey,
        failure: *err.Failure,
    ) err.Error![]RotationKey {
        const count = self.numRotations(track);
        const track_index = try err.narrow(failure, .raw_animation_rotations, c_int, track);
        try err.check(failure, .raw_animation_rotations, c.zozzRawAnimationRotations(err.live(self.handle), track_index, out.ptr, out.len));
        return out[0..count];
    }

    /// See `translations`.
    pub fn scales(self: RawAnimation, track: u32, out: []ScaleKey, failure: *err.Failure) err.Error![]ScaleKey {
        const count = self.numScales(track);
        const track_index = try err.narrow(failure, .raw_animation_scales, c_int, track);
        try err.check(failure, .raw_animation_scales, c.zozzRawAnimationScales(err.live(self.handle), track_index, out.ptr, out.len));
        return out[0..count];
    }

    /// Drops every key on `track`'s translation channel, leaving the other
    /// two alone. The track itself stays — a clip's track count is fixed at
    /// creation, and an empty channel bakes an identity key at `build`.
    pub fn clearTranslations(self: RawAnimation, track: u32, failure: *err.Failure) err.Error!void {
        const track_index = try err.narrow(failure, .raw_animation_clear_translations, c_int, track);
        try err.check(failure, .raw_animation_clear_translations, c.zozzRawAnimationClearTranslations(err.live(self.handle), track_index));
    }

    pub fn clearRotations(self: RawAnimation, track: u32, failure: *err.Failure) err.Error!void {
        const track_index = try err.narrow(failure, .raw_animation_clear_rotations, c_int, track);
        try err.check(failure, .raw_animation_clear_rotations, c.zozzRawAnimationClearRotations(err.live(self.handle), track_index));
    }

    pub fn clearScales(self: RawAnimation, track: u32, failure: *err.Failure) err.Error!void {
        const track_index = try err.narrow(failure, .raw_animation_clear_scales, c_int, track);
        try err.check(failure, .raw_animation_clear_scales, c.zozzRawAnimationClearScales(err.live(self.handle), track_index));
    }

    /// All three channels of `track` at once.
    pub fn clearTrack(self: RawAnimation, track: u32, failure: *err.Failure) err.Error!void {
        const track_index = try err.narrow(failure, .raw_animation_clear_track, c_int, track);
        try err.check(failure, .raw_animation_clear_track, c.zozzRawAnimationClearTrack(err.live(self.handle), track_index));
    }

    /// Validates and builds a compressed runtime animation. The raw animation
    /// is not consumed.
    pub fn build(self: RawAnimation, failure: *err.Failure) err.Error!animation_mod.Animation {
        var handle: *c.Animation = undefined;
        try err.check(failure, .animation_build, c.zozzAnimationBuild(err.live(self.handle), &handle));
        return .{ .handle = handle };
    }

    /// Samples one track at `time` (seconds; clamped to the track's own
    /// first/last key outside its range). For offline use only (preview,
    /// re-timing, cooking) — use `zozz.SamplingJob` against a built
    /// `Animation` at runtime.
    pub fn sampleTrack(self: RawAnimation, track: u32, time: f32, failure: *err.Failure) err.Error!math.Transform {
        var out: math.Transform = undefined;
        const track_index = try err.narrow(failure, .raw_animation_sample_track, i32, track);
        try err.check(failure, .raw_animation_sample_track, c.zozzRawAnimationSampleTrack(err.live(self.handle), track_index, time, &out));
        return out;
    }

    /// Samples every track at `time`. `out` must hold at least `numTracks`
    /// entries; slots past the track count are filled with the identity
    /// transform.
    pub fn sample(self: RawAnimation, time: f32, out: []math.Transform, failure: *err.Failure) err.Error!void {
        try err.check(failure, .raw_animation_sample, c.zozzRawAnimationSample(err.live(self.handle), time, out.ptr, out.len));
    }

    /// The sorted, de-duplicated union of every keyframe time across all
    /// tracks, allocated with `allocator`. Caller frees the result.
    pub fn extractTimePoints(self: RawAnimation, allocator: std.mem.Allocator, failure: *err.Failure) err.Error![]f32 {
        var count: usize = undefined;
        try err.check(failure, .raw_animation_extract_time_points, c.zozzRawAnimationExtractTimePoints(err.live(self.handle), null, 0, &count));

        const out = allocator.alloc(f32, count) catch return err.refuse(failure, .raw_animation_extract_time_points, err.Error.OutOfMemory);
        errdefer allocator.free(out);
        try err.check(failure, .raw_animation_extract_time_points, c.zozzRawAnimationExtractTimePoints(err.live(self.handle), out.ptr, out.len, &count));
        return out;
    }

    /// Samples `joint` in MODEL space, at every keyframe on it or an ancestor.
    /// For offline use only (preview, re-timing, cooking) — `zozz.SamplingJob`
    /// plus `zozz.LocalToModelJob` are the runtime path over a built
    /// `Animation` and `Skeleton`. `skeleton` must have as many joints as
    /// `self` has tracks, else `error.SkeletonMismatch`; `joint` must be one
    /// of them. Allocated with `allocator`; caller frees the result.
    pub fn sampleTrackModelSpace(
        self: RawAnimation,
        skeleton: skeleton_mod.Skeleton,
        joint: u32,
        allocator: std.mem.Allocator,
        failure: *err.Failure,
    ) err.Error![]ModelSpaceSample {
        const joint_index = try err.narrow(failure, .raw_animation_sample_track_model_space, i32, joint);
        var count: usize = undefined;
        try err.check(failure, .raw_animation_sample_track_model_space, c.zozzRawAnimationSampleTrackModelSpace(
            err.live(self.handle),
            err.live(skeleton.handle),
            joint_index,
            null,
            0,
            &count,
        ));

        const out = allocator.alloc(ModelSpaceSample, count) catch return err.refuse(failure, .raw_animation_sample_track_model_space, err.Error.OutOfMemory);
        errdefer allocator.free(out);
        try err.check(failure, .raw_animation_sample_track_model_space, c.zozzRawAnimationSampleTrackModelSpace(
            err.live(self.handle),
            err.live(skeleton.handle),
            joint_index,
            out.ptr,
            out.len,
            &count,
        ));
        return out;
    }
};

/// One authored key of a raw animation channel, as ozz stores it: a time in
/// the clip's own seconds and the value at it. Re-exported from `c.zig`
/// rather than redefined, the way `math.Transform` is — a second definition
/// is a second layout to keep in step with the header.
pub const TranslationKey = c.RawTranslationKey;
pub const RotationKey = c.RawRotationKey;
pub const ScaleKey = c.RawScaleKey;

/// One keyframe of `RawAnimation.sampleTrackModelSpace`: `time` in the
/// animation's own seconds, `transform` the sampled joint's model-space
/// matrix at that time.
pub const ModelSpaceSample = c.ModelSpaceSample;

//=============================================================================
// Tests
//=============================================================================

const pose_mod = @import("pose.zig");
const sampling_mod = @import("sampling.zig");

fn restAt(translation: [3]f32) math.Transform {
    var t = math.transform_identity;
    t.translation = translation;
    return t;
}

test "builder: a depth-first insertion round-trips names, parents and rest pose" {
    var failure: err.Failure = .{};
    var raw = try RawSkeleton.init(&failure);
    defer raw.deinit();

    // root -> spine -> {arm_l, arm_r}, inserted depth-first.
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }), &failure);
    const spine = try raw.addJoint(root, "spine", restAt(.{ 0, 1, 0 }), &failure);
    _ = try raw.addJoint(spine, "arm_l", restAt(.{ -0.5, 0.5, 0 }), &failure);
    _ = try raw.addJoint(spine, "arm_r", restAt(.{ 0.5, 0.5, 0 }), &failure);
    try std.testing.expectEqual(@as(u32, 4), raw.numJoints());

    var built = try raw.build(&failure);
    defer built.deinit();

    try std.testing.expectEqual(@as(u32, 4), built.numJoints());
    try std.testing.expectEqualStrings("root", built.jointName(0).?);
    try std.testing.expectEqualStrings("spine", built.jointName(1).?);
    try std.testing.expectEqualStrings("arm_l", built.jointName(2).?);
    try std.testing.expectEqualStrings("arm_r", built.jointName(3).?);
    try std.testing.expectEqual(skeleton_mod.no_parent, built.jointParent(0));
    try std.testing.expectEqual(@as(i16, 0), built.jointParent(1));
    try std.testing.expectEqual(@as(i16, 1), built.jointParent(2));
    try std.testing.expectEqual(@as(i16, 1), built.jointParent(3));

    var rest: [4]math.Transform = undefined;
    try built.restPose(&rest, &failure);
    try std.testing.expectEqual(@as(f32, 1), rest[1].translation[1]);
    try std.testing.expectEqual(@as(f32, -0.5), rest[2].translation[0]);
}

test "builder: a non-depth-first insertion is reindexed depth-first" {
    var failure: err.Failure = .{};
    var raw = try RawSkeleton.init(&failure);
    defer raw.deinit();

    // Insertion order: root, a, b, c(child of a). Depth-first order walks a's
    // subtree before b, so c overtakes b in the built skeleton.
    const root = try raw.addJoint(null, "root", math.transform_identity, &failure);
    const a = try raw.addJoint(root, "a", math.transform_identity, &failure);
    _ = try raw.addJoint(root, "b", math.transform_identity, &failure);
    _ = try raw.addJoint(a, "c", math.transform_identity, &failure);

    var built = try raw.build(&failure);
    defer built.deinit();

    try std.testing.expectEqualStrings("root", built.jointName(0).?);
    try std.testing.expectEqualStrings("a", built.jointName(1).?);
    try std.testing.expectEqualStrings("c", built.jointName(2).?);
    try std.testing.expectEqualStrings("b", built.jointName(3).?);
}

test "raw skeleton read-back is addressed by insertion index, not the built order" {
    var failure: err.Failure = .{};
    var raw = try RawSkeleton.init(&failure);
    defer raw.deinit();

    // Same non-depth-first insertion as the test above: root, a, b,
    // c(child of a). That test pins that the BUILT skeleton reindexes to
    // root, a, c, b; the raw skeleton's own read-back must not follow suit —
    // it stays addressed by insertion index no matter what building later
    // does to the numbering.
    const root = try raw.addJoint(null, "root", restAt(.{ 0, 0, 0 }), &failure);
    const a = try raw.addJoint(root, "a", restAt(.{ 1, 0, 0 }), &failure);
    const b = try raw.addJoint(root, "b", restAt(.{ 2, 0, 0 }), &failure);
    const child = try raw.addJoint(a, "c", restAt(.{ 3, 0, 0 }), &failure);

    try std.testing.expectEqual(@as(u32, 4), raw.numJoints());

    try std.testing.expectEqualStrings("root", raw.jointName(root).?);
    try std.testing.expectEqualStrings("a", raw.jointName(a).?);
    try std.testing.expectEqualStrings("b", raw.jointName(b).?);
    try std.testing.expectEqualStrings("c", raw.jointName(child).?);

    try std.testing.expectEqual(@as(?u32, null), raw.jointParent(root));
    try std.testing.expectEqual(@as(?u32, root), raw.jointParent(a));
    try std.testing.expectEqual(@as(?u32, root), raw.jointParent(b));
    try std.testing.expectEqual(@as(?u32, a), raw.jointParent(child));

    try std.testing.expectEqual(@as(f32, 2), (try raw.jointRest(b, &failure)).translation[0]);
    try std.testing.expectEqual(@as(f32, 3), (try raw.jointRest(child, &failure)).translation[0]);

    // Out of range is a clean null/error, not a crash.
    try std.testing.expectEqual(@as(?[:0]const u8, null), raw.jointName(99));
    try std.testing.expectEqual(@as(?u32, null), raw.jointParent(99));
    try std.testing.expectError(error.InvalidArgument, raw.jointRest(99, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_skeleton_joint_rest, .result = .invalid_argument }}, failure.frames());
}

test "raw skeleton breadth-first traversal is per-subtree, not a single global level order" {
    var failure: err.Failure = .{};
    var raw = try RawSkeleton.init(&failure);
    defer raw.deinit();

    // Two roots, asymmetric depth: root_a -> a1 -> a1a is two levels deep;
    // root_b -> b1 is one. A true global level order would visit b1 (depth 1)
    // before a1a (depth 2); ozz's own IterateJointsBF does not — it finishes
    // root_a's whole subtree before starting root_b's, so a1a visits first.
    const root_a = try raw.addJoint(null, "root_a", math.transform_identity, &failure);
    const a1 = try raw.addJoint(root_a, "a1", math.transform_identity, &failure);
    const a1a = try raw.addJoint(a1, "a1a", math.transform_identity, &failure);
    const root_b = try raw.addJoint(null, "root_b", math.transform_identity, &failure);
    const b1 = try raw.addJoint(root_b, "b1", math.transform_identity, &failure);

    const Visit = struct { joint: u32, parent: ?u32 };
    const Context = struct {
        visits: [5]Visit = undefined,
        count: usize = 0,
    };
    var ctx = Context{};

    try raw.iterateJointsBreadthFirst(&ctx, struct {
        fn visit(context: *Context, joint: u32, parent: ?u32) void {
            context.visits[context.count] = .{ .joint = joint, .parent = parent };
            context.count += 1;
        }
    }.visit, &failure);

    const expected = [_]Visit{
        .{ .joint = root_a, .parent = null },
        .{ .joint = root_b, .parent = null },
        .{ .joint = a1, .parent = root_a },
        .{ .joint = a1a, .parent = a1 },
        .{ .joint = b1, .parent = root_b },
    };
    try std.testing.expectEqual(expected.len, ctx.count);
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp.joint, ctx.visits[i].joint);
        try std.testing.expectEqual(exp.parent, ctx.visits[i].parent);
    }
}

test "builder: a built animation samples what was authored" {
    var failure: err.Failure = .{};
    var raw_skel = try RawSkeleton.init(&failure);
    defer raw_skel.deinit();
    const root = try raw_skel.addJoint(null, "root", math.transform_identity, &failure);
    _ = try raw_skel.addJoint(root, "child", restAt(.{ 0, 1, 0 }), &failure);
    var skel = try raw_skel.build(&failure);
    defer skel.deinit();

    var raw_anim = try RawAnimation.init(2, 2.0, "authored", &failure);
    defer raw_anim.deinit();
    // Root translates 0 -> (4, 0, 0) linearly; both tracks fully keyed.
    for (0..2) |track| {
        const x: f32 = if (track == 0) 4 else 0;
        try raw_anim.pushTranslation(@intCast(track), 0.0, .{ 0, 0, 0 }, &failure);
        try raw_anim.pushTranslation(@intCast(track), 2.0, .{ x, 0, 0 }, &failure);
        try raw_anim.pushRotation(@intCast(track), 0.0, .{ 0, 0, 0, 1 }, &failure);
        try raw_anim.pushScale(@intCast(track), 0.0, .{ 1, 1, 1 }, &failure);
    }
    var clip = try raw_anim.build(&failure);
    defer clip.deinit();
    try std.testing.expectEqual(@as(f32, 2.0), clip.duration());
    try std.testing.expectEqual(@as(u32, 2), clip.numTracks());

    // Two joints fit in one SoA block, on the stack.
    var pose: [1]math.SoaTransform = undefined;
    var context = try sampling_mod.SamplingContext.initForSkeleton(skel, &failure);
    defer context.deinit();

    // Tolerance is the builder's compression, not sampling noise: ozz stores
    // keys with quantized timepoints and half-float components (measured here:
    // the midpoint sample of a 0 -> 4 lerp lands at 1.9995117).
    var locals: [2]math.Transform = undefined;
    try (sampling_mod.SamplingJob{ .animation = clip, .context = context, .ratio = 0.5, .out = &pose }).run(&failure);
    try pose_mod.toLocalTransforms(&pose, &locals, &failure);
    try std.testing.expectApproxEqAbs(@as(f32, 2), locals[0].translation[0], 1e-2);

    try (sampling_mod.SamplingJob{ .animation = clip, .context = context, .ratio = 1.0, .out = &pose }).run(&failure);
    try pose_mod.toLocalTransforms(&pose, &locals, &failure);
    try std.testing.expectApproxEqAbs(@as(f32, 4), locals[0].translation[0], 1e-2);
}

test "builder: an empty track bakes identity, not the rest pose" {
    var failure: err.Failure = .{};
    // The contract this test pins is load-bearing for consumers whose rule is
    // "unanimated joints hold the rest pose": ozz's AnimationBuilder writes
    // identity keys for a track with no keys (animation_builder.cc, CopyRaw),
    // and it cannot do otherwise — a RawAnimation never sees a skeleton.
    var raw_skel = try RawSkeleton.init(&failure);
    defer raw_skel.deinit();
    const root = try raw_skel.addJoint(null, "root", math.transform_identity, &failure);
    _ = try raw_skel.addJoint(root, "still", restAt(.{ 5, 5, 5 }), &failure);
    var skel = try raw_skel.build(&failure);
    defer skel.deinit();

    var raw_anim = try RawAnimation.init(2, 1.0, null, &failure);
    defer raw_anim.deinit();
    try raw_anim.pushTranslation(0, 0.0, .{ 1, 0, 0 }, &failure);
    // Track 1: no keys at all.
    var clip = try raw_anim.build(&failure);
    defer clip.deinit();

    var pose: [1]math.SoaTransform = undefined;
    var context = try sampling_mod.SamplingContext.initForSkeleton(skel, &failure);
    defer context.deinit();

    // Seed the pose with the rest pose, then sample: the empty track has
    // baked keys, so sampling OVERWRITES the seeded rest pose with identity.
    try skel.restPoseSoa(&pose, &failure);
    try (sampling_mod.SamplingJob{ .animation = clip, .context = context, .ratio = 0.0, .out = &pose }).run(&failure);
    var locals: [2]math.Transform = undefined;
    try pose_mod.toLocalTransforms(&pose, &locals, &failure);
    try std.testing.expectEqual(@as(f32, 0), locals[1].translation[0]);
    try std.testing.expectEqual(@as(f32, 0), locals[1].translation[1]);
}

test "builder: validation failures are errors, not asserts" {
    var failure: err.Failure = .{};
    var raw_skel = try RawSkeleton.init(&failure);
    defer raw_skel.deinit();

    // Parent index that does not exist yet.
    try std.testing.expectError(
        error.InvalidArgument,
        raw_skel.addJoint(7, "orphan", math.transform_identity, &failure),
    );
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_skeleton_add_joint, .result = .invalid_argument }}, failure.frames());
    failure.reset();
    // An empty skeleton cannot build.
    try std.testing.expectError(error.InvalidData, raw_skel.build(&failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .skeleton_build, .result = .invalid_data }}, failure.frames());
    failure.reset();

    // Animation-side argument shapes.
    try std.testing.expectError(error.InvalidArgument, RawAnimation.init(0, 1.0, null, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_create, .result = .invalid_argument }}, failure.frames());
    failure.reset();
    try std.testing.expectError(error.InvalidArgument, RawAnimation.init(1, 0.0, null, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_create, .result = .invalid_argument }}, failure.frames());
    failure.reset();
    try std.testing.expectError(error.InvalidArgument, RawAnimation.init(1, std.math.nan(f32), null, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_create, .result = .invalid_argument }}, failure.frames());
    failure.reset();

    var raw_anim = try RawAnimation.init(1, 1.0, null, &failure);
    defer raw_anim.deinit();
    // Out-of-range track, out-of-range time, non-finite value.
    try std.testing.expectError(error.InvalidArgument, raw_anim.pushTranslation(1, 0.0, .{ 0, 0, 0 }, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_push_translation, .result = .invalid_argument }}, failure.frames());
    failure.reset();
    try std.testing.expectError(error.InvalidArgument, raw_anim.pushTranslation(0, 2.0, .{ 0, 0, 0 }, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_push_translation, .result = .invalid_argument }}, failure.frames());
    failure.reset();
    try std.testing.expectError(
        error.InvalidArgument,
        raw_anim.pushTranslation(0, 0.0, .{ std.math.inf(f32), 0, 0 }, &failure),
    );
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_push_translation, .result = .invalid_argument }}, failure.frames());
    failure.reset();

    // Keys out of order pass the push (per-call checks cannot see order
    // without forbidding legitimate equal-time replaces) and fail at build.
    try raw_anim.pushTranslation(0, 0.75, .{ 0, 0, 0 }, &failure);
    try raw_anim.pushTranslation(0, 0.25, .{ 1, 0, 0 }, &failure);
    try std.testing.expectError(error.InvalidData, raw_anim.build(&failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .animation_build, .result = .invalid_data }}, failure.frames());
}

test "raw animation: keys read back exactly as authored" {
    var failure: err.Failure = .{};
    var raw = try RawAnimation.init(2, 4.0, "walk", &failure);
    defer raw.deinit();

    try raw.pushTranslation(0, 0.0, .{ 1, 2, 3 }, &failure);
    try raw.pushTranslation(0, 2.5, .{ 4, 5, 6 }, &failure);
    try raw.pushRotation(0, 1.0, .{ 0, 0.7071068, 0, 0.7071068 }, &failure);
    try raw.pushScale(1, 3.0, .{ 2, 2, 2 }, &failure);

    try std.testing.expectEqual(@as(u32, 2), raw.numTranslations(0));
    try std.testing.expectEqual(@as(u32, 1), raw.numRotations(0));
    try std.testing.expectEqual(@as(u32, 0), raw.numScales(0));
    try std.testing.expectEqual(@as(u32, 0), raw.numTranslations(1));
    try std.testing.expectEqual(@as(u32, 1), raw.numScales(1));

    // The read-back is EXACT: nothing here is compressed, quantized or
    // interpolated on the way out — that only happens at build.
    var translations: [4]TranslationKey = undefined;
    const t = try raw.translations(0, &translations, &failure);
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expectEqual(@as(f32, 0.0), t[0].time);
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, t[0].value);
    try std.testing.expectEqual(@as(f32, 2.5), t[1].time);
    try std.testing.expectEqual([3]f32{ 4, 5, 6 }, t[1].value);

    var rotations: [4]RotationKey = undefined;
    const r = try raw.rotations(0, &rotations, &failure);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(@as(f32, 1.0), r[0].time);
    // (x, y, z, w) — w last, as everywhere in this package.
    try std.testing.expectEqual(@as(f32, 0.7071068), r[0].value[1]);
    try std.testing.expectEqual(@as(f32, 0.7071068), r[0].value[3]);

    var scales: [4]ScaleKey = undefined;
    const sc = try raw.scales(1, &scales, &failure);
    try std.testing.expectEqual(@as(usize, 1), sc.len);
    try std.testing.expectEqual([3]f32{ 2, 2, 2 }, sc[0].value);

    // A track with no keys on that channel writes nothing and returns empty.
    try std.testing.expectEqual(@as(usize, 0), (try raw.scales(0, &scales, &failure)).len);
}

test "raw animation: a buffer too small writes nothing, and a bad track is an error" {
    var failure: err.Failure = .{};
    var raw = try RawAnimation.init(1, 1.0, null, &failure);
    defer raw.deinit();
    try raw.pushTranslation(0, 0.0, .{ 1, 1, 1 }, &failure);
    try raw.pushTranslation(0, 1.0, .{ 2, 2, 2 }, &failure);

    var one: [1]TranslationKey = .{.{ .time = -1, .value = .{ 9, 9, 9 } }};
    try std.testing.expectError(error.BufferTooSmall, raw.translations(0, &one, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_translations, .result = .buffer_too_small }}, failure.frames());
    failure.reset();
    // Untouched: a short buffer is refused before anything is written, so a
    // caller that ignores the error cannot mistake a partial fill for a read.
    try std.testing.expectEqual(@as(f32, -1), one[0].time);

    var four: [4]TranslationKey = undefined;
    try std.testing.expectError(error.InvalidArgument, raw.translations(7, &four, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_translations, .result = .invalid_argument }}, failure.frames());
    failure.reset();
    try std.testing.expectEqual(@as(u32, 0), raw.numTranslations(7));
    try std.testing.expectError(error.InvalidArgument, raw.clearTranslations(7, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_clear_translations, .result = .invalid_argument }}, failure.frames());
}

test "raw animation: clearing one channel leaves the other two alone" {
    var failure: err.Failure = .{};
    var raw = try RawAnimation.init(1, 1.0, null, &failure);
    defer raw.deinit();
    try raw.pushTranslation(0, 0.0, .{ 1, 0, 0 }, &failure);
    try raw.pushRotation(0, 0.0, .{ 0, 0, 0, 1 }, &failure);
    try raw.pushScale(0, 0.0, .{ 1, 1, 1 }, &failure);

    try raw.clearRotations(0, &failure);
    try std.testing.expectEqual(@as(u32, 1), raw.numTranslations(0));
    try std.testing.expectEqual(@as(u32, 0), raw.numRotations(0));
    try std.testing.expectEqual(@as(u32, 1), raw.numScales(0));

    try raw.clearTrack(0, &failure);
    try std.testing.expectEqual(@as(u32, 0), raw.numTranslations(0));
    try std.testing.expectEqual(@as(u32, 0), raw.numScales(0));
    // The TRACK survives a clear — only its keys go. A clip's track count is
    // fixed at creation, so this still builds, with identity keys baked in.
    try std.testing.expectEqual(@as(u32, 1), raw.numTracks());
    var clip = try raw.build(&failure);
    defer clip.deinit();
    try std.testing.expectEqual(@as(u32, 1), clip.numTracks());
}

test "raw animation: rewriting a channel is clear-then-push" {
    var failure: err.Failure = .{};
    var raw = try RawAnimation.init(1, 2.0, null, &failure);
    defer raw.deinit();
    try raw.pushTranslation(0, 0.0, .{ 0, 0, 0 }, &failure);
    try raw.pushTranslation(0, 1.0, .{ 1, 0, 0 }, &failure);

    // Halve the sample rate: read what is there, clear, push the survivors.
    var keys: [8]TranslationKey = undefined;
    const authored = try raw.translations(0, &keys, &failure);
    try std.testing.expectEqual(@as(usize, 2), authored.len);
    try raw.clearTranslations(0, &failure);
    try raw.pushTranslation(0, authored[1].time, authored[1].value, &failure);

    const rewritten = try raw.translations(0, &keys, &failure);
    try std.testing.expectEqual(@as(usize, 1), rewritten.len);
    try std.testing.expectEqual(@as(f32, 1.0), rewritten[0].time);
    try std.testing.expect(raw.validate());
}

test "raw animation: validate, size, name and retiming" {
    var failure: err.Failure = .{};
    var raw = try RawAnimation.init(2, 1.0, "clip", &failure);
    defer raw.deinit();

    try std.testing.expectEqualStrings("clip", raw.name());
    try std.testing.expect(raw.validate());
    // ozz's own accounting, so the only claim made here is that it grows with
    // the data rather than that it equals any particular number.
    const empty_size = raw.size();
    try raw.pushTranslation(0, 0.0, .{ 0, 0, 0 }, &failure);
    try raw.pushTranslation(0, 1.0, .{ 1, 0, 0 }, &failure);
    try std.testing.expect(raw.size() > empty_size);

    try raw.setName("renamed", &failure);
    try std.testing.expectEqualStrings("renamed", raw.name());
    try raw.setName(null, &failure);
    try std.testing.expectEqualStrings("", raw.name());

    // Keys out of ascending order fail validate before build refuses them.
    try raw.pushTranslation(0, 0.5, .{ 2, 0, 0 }, &failure);
    try std.testing.expect(!raw.validate());
    try std.testing.expectError(error.InvalidData, raw.build(&failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .animation_build, .result = .invalid_data }}, failure.frames());
    failure.reset();

    // Retiming does not move keys: shortening leaves the last one past the
    // end, which is exactly what validate is for.
    var fresh = try RawAnimation.init(1, 2.0, null, &failure);
    defer fresh.deinit();
    try fresh.pushTranslation(0, 1.5, .{ 0, 0, 0 }, &failure);
    try std.testing.expect(fresh.validate());
    try fresh.setDuration(1.0, &failure);
    try std.testing.expectEqual(@as(f32, 1.0), fresh.duration());
    try std.testing.expect(!fresh.validate());
    try fresh.setDuration(2.0, &failure);
    try std.testing.expect(fresh.validate());

    try std.testing.expectError(error.InvalidArgument, fresh.setDuration(0, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_set_duration, .result = .invalid_argument }}, failure.frames());
    failure.reset();
    try std.testing.expectError(error.InvalidArgument, fresh.setDuration(std.math.nan(f32), &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .raw_animation_set_duration, .result = .invalid_argument }}, failure.frames());
}

test "raw skeleton: validate holds for anything this API can author" {
    var failure: err.Failure = .{};
    var raw = try RawSkeleton.init(&failure);
    defer raw.deinit();
    // Empty is valid to ozz -- RawSkeleton::Validate is a joint-count bound
    // and nothing else -- even though build refuses it for having no roots.
    try std.testing.expect(raw.validate());
    try std.testing.expectError(error.InvalidData, raw.build(&failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .skeleton_build, .result = .invalid_data }}, failure.frames());
    failure.reset();

    _ = try raw.addJoint(null, "root", math.transform_identity, &failure);
    try std.testing.expect(raw.validate());
}

test "a track, joint or parent index the C boundary cannot carry is refused, not narrowed" {
    var failure: err.Failure = .{};
    try std.testing.expectError(error.InvalidArgument, RawAnimation.init(1 << 31, 1.0, null, &failure));
    var raw_anim = try RawAnimation.init(1, 1.0, null, &failure);
    defer raw_anim.deinit();
    try std.testing.expectError(error.InvalidArgument, raw_anim.pushTranslation(1 << 31, 0.0, .{ 0, 0, 0 }, &failure));
    var raw_skel = try RawSkeleton.init(&failure);
    defer raw_skel.deinit();
    try std.testing.expectError(error.InvalidArgument, raw_skel.addJoint(1 << 31, "orphan", math.transform_identity, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{
        .{ .call = .raw_animation_create, .result = .invalid_argument },
        .{ .call = .raw_animation_push_translation, .result = .invalid_argument },
        .{ .call = .raw_skeleton_add_joint, .result = .invalid_argument },
    }, failure.frames());
    // The getters answer what they document for an index out of range.
    try std.testing.expectEqual(@as(u32, 0), raw_anim.numTranslations(1 << 31));
    try std.testing.expectEqual(@as(?[:0]const u8, null), raw_skel.jointName(1 << 31));
}
