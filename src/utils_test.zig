//! Behavioural tests for the skeleton/animation utilities: leaf detection,
//! depth-first traversal in both directions, name lookup, and the rest-pose
//! accessors.
//!
//! Every assertion cross-checks a utility against something the caller could
//! have computed itself from `Skeleton`'s own accessors — `jointParent`,
//! `jointName`, `restPose`. That is the point: these functions exist to save
//! a consumer that work, so the test they have to pass is agreeing with it.
//!
//! Fixtures are built in code with `RawSkeleton`, as in `ik_test.zig`.

const std = @import("std");
const zozz = @import("zozz.zig");

fn translated(x: f32, y: f32, z: f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation = .{ x, y, z };
    return t;
}

/// A deliberately awkward hierarchy: two roots, branches at two different
/// depths, and leaves that are NOT the last joint. Built depth-first, so
/// insertion indices equal built indices (see offline.zig): a-b-c, a-b-d, a-g,
/// e-f.
fn buildSkeleton() !zozz.Skeleton {
    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();

    const a = try raw.addJoint(null, "a", translated(1, 0, 0));
    const b = try raw.addJoint(a, "b", translated(0, 2, 0));
    _ = try raw.addJoint(b, "c", translated(0, 0, 3));
    _ = try raw.addJoint(b, "d", translated(0, 0, -3));
    _ = try raw.addJoint(a, "g", translated(-1, 0, 0));
    const e = try raw.addJoint(null, "e", translated(10, 0, 0));
    _ = try raw.addJoint(e, "f", translated(0, 5, 0));

    return raw.build();
}

const joint_count = 7;

test "jointIsLeaf agrees with the parent array on every joint" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skel = try buildSkeleton();
    defer skel.deinit();
    try std.testing.expectEqual(@as(u32, joint_count), skel.numJoints());

    // Recompute leaf-ness the long way: a joint is a leaf iff no other joint
    // names it as its parent. This is what a consumer would write, and it
    // makes no assumption about ordering — so it also checks that the
    // "next joint's parent" shortcut ozz uses is actually equivalent.
    for (0..joint_count) |i| {
        const joint: u32 = @intCast(i);
        var has_child = false;
        for (0..joint_count) |j| {
            if (skel.jointParent(@intCast(j)) == @as(i16, @intCast(joint))) has_child = true;
        }
        try std.testing.expectEqual(!has_child, try zozz.jointIsLeaf(skel, joint));
    }

    // And the specific facts, spelled out, so a change that broke both the
    // utility and the cross-check above would still be caught: c, d and g
    // are leaves, and c is a leaf that is NOT the last joint — the case the
    // "is it the last one?" half of the implementation exists for.
    try std.testing.expect(!try zozz.jointIsLeaf(skel, 0)); // a
    try std.testing.expect(!try zozz.jointIsLeaf(skel, 1)); // b
    try std.testing.expect(try zozz.jointIsLeaf(skel, 2)); // c
    try std.testing.expect(try zozz.jointIsLeaf(skel, 3)); // d
    try std.testing.expect(try zozz.jointIsLeaf(skel, 4)); // g
    try std.testing.expect(!try zozz.jointIsLeaf(skel, 5)); // e
    try std.testing.expect(try zozz.jointIsLeaf(skel, 6)); // f
}

const Visits = struct {
    order: [joint_count]u32 = undefined,
    parents: [joint_count]i32 = undefined,
    count: usize = 0,

    fn record(self: *Visits, joint: u32, parent: i32) void {
        if (self.count >= joint_count) return; // Overrun is asserted below.
        self.order[self.count] = joint;
        self.parents[self.count] = parent;
        self.count += 1;
    }

    /// Position of `joint` in the visit order, or null if never visited.
    fn positionOf(self: Visits, joint: u32) ?usize {
        for (self.order[0..self.count], 0..) |visited, i| {
            if (visited == joint) return i;
        }
        return null;
    }
};

test "the depth-first traversal visits every joint once, parents before children" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skel = try buildSkeleton();
    defer skel.deinit();

    var forward: Visits = .{};
    try zozz.iterateJointsDepthFirst(skel, zozz.no_parent, &forward, Visits.record);

    // Every joint, exactly once. `positionOf` returning non-null for all of
    // them plus a total count of exactly numJoints leaves no room for a
    // duplicate or an omission.
    try std.testing.expectEqual(@as(usize, joint_count), forward.count);
    for (0..joint_count) |i| {
        try std.testing.expect(forward.positionOf(@intCast(i)) != null);
    }

    for (0..forward.count) |step| {
        const joint = forward.order[step];

        // The parent handed to the callback is the skeleton's own parent.
        try std.testing.expectEqual(
            @as(i32, skel.jointParent(joint)),
            forward.parents[step],
        );

        // A parent is always visited before its children. This is what makes
        // the traversal usable for accumulating a transform down a chain: at
        // the moment a joint is visited, its parent's result already exists.
        const parent = skel.jointParent(joint);
        if (parent == zozz.no_parent) continue;
        const parent_step = forward.positionOf(@intCast(parent)).?;
        try std.testing.expect(parent_step < step);
    }

    // The reverse traversal is the same set, with the guarantee inverted:
    // every joint before its parent, so a consumer accumulating UP a chain
    // (bounding volumes, IK setup) can rely on children being done first.
    var reverse: Visits = .{};
    try zozz.iterateJointsDepthFirstReverse(skel, &reverse, Visits.record);

    try std.testing.expectEqual(@as(usize, joint_count), reverse.count);
    for (0..reverse.count) |step| {
        const joint = reverse.order[step];
        try std.testing.expectEqual(
            @as(i32, skel.jointParent(joint)),
            reverse.parents[step],
        );
        const parent = skel.jointParent(joint);
        if (parent == zozz.no_parent) continue;
        try std.testing.expect(reverse.positionOf(@intCast(parent)).? > step);
    }
}

test "findJoint round-trips against jointName, and misses are null" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skel = try buildSkeleton();
    defer skel.deinit();

    for (0..joint_count) |i| {
        const joint: u32 = @intCast(i);
        const name = skel.jointName(joint).?;
        try std.testing.expectEqual(joint, zozz.findJoint(skel, name).?);
    }

    // A name nothing carries, and the documented case sensitivity — a host
    // that lowercases its joint names before looking them up gets null, not
    // a near match.
    try std.testing.expect(zozz.findJoint(skel, "not_a_joint") == null);
    try std.testing.expect(zozz.findJoint(skel, "A") == null);
    try std.testing.expect(zozz.findJoint(skel, "") == null);
}

test "the rest-pose accessors agree with each other, locally and in model space" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    const skel = try buildSkeleton();
    defer skel.deinit();

    // Single-joint local rest == the same joint's slot in the whole-skeleton
    // rest pose. The single-joint form exists to avoid materialising the
    // array; it must not answer differently for doing so.
    var rest: [joint_count]zozz.Transform = undefined;
    try skel.restPose(&rest);
    for (0..joint_count) |i| {
        const one = try zozz.jointRestPoseLocal(skel, @intCast(i));
        for (rest[i].translation, one.translation) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-6);
        }
        for (rest[i].rotation, one.rotation) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-6);
        }
        for (rest[i].scale, one.scale) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 1e-6);
        }
    }

    // Model space accumulates down the hierarchy. Every rest rotation here is
    // identity and every scale is one, so the model-space translation of a
    // joint is exactly the sum of its own and its ancestors' translations —
    // which makes the expected answer checkable by hand.
    var models: [joint_count]zozz.Mat4 align(16) = undefined;
    try zozz.restPoseModelSpace(skel, &models);

    for (0..joint_count) |i| {
        var expected: [3]f32 = .{ 0, 0, 0 };
        var walk: i32 = @intCast(i);
        while (walk != zozz.no_parent) {
            const t = rest[@intCast(walk)].translation;
            for (&expected, t) |*sum, v| sum.* += v;
            walk = skel.jointParent(@intCast(walk));
        }
        const m = models[i].m;
        try std.testing.expectApproxEqAbs(expected[0], m[12], 1e-5);
        try std.testing.expectApproxEqAbs(expected[1], m[13], 1e-5);
        try std.testing.expectApproxEqAbs(expected[2], m[14], 1e-5);
    }

    // Spot-check one by hand so the loop above cannot pass by computing the
    // same wrong thing twice: c sits at a + b + c = (1, 2, 3).
    try std.testing.expectEqual(@as(u32, 2), zozz.findJoint(skel, "c").?);
    try std.testing.expectApproxEqAbs(@as(f32, 1), models[2].m[12], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), models[2].m[13], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), models[2].m[14], 1e-5);
}
