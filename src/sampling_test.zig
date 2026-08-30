//! Behavioural tests for the sampling pipeline's two jobs, and above all for
//! `LocalToModelJob`'s joint range.
//!
//! The range is the part of ozz's job that fails QUIETLY when it is driven
//! wrong: an empty walk writes nothing and reports success. Every test here
//! plants a recognisable value in the destination first, so "did not write"
//! is a visible outcome rather than an indistinguishable one.

const std = @import("std");
const zozz = @import("zozz.zig");

/// Marks every matrix so an unwritten one is recognisable. No local-to-model
/// result can hold it: ozz always writes a bottom row of (0, 0, 0, 1).
const poison: zozz.Mat4 = .{ .m = .{-1.0} ** 16 };

fn translated(x: f32, y: f32, z: f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation = .{ x, y, z };
    return t;
}

fn wasWritten(m: zozz.Mat4) bool {
    return !std.mem.eql(u8, std.mem.asBytes(&m), std.mem.asBytes(&poison));
}

fn translationX(m: zozz.Mat4) f32 {
    return m.m[12];
}

/// A four-joint chain, each joint one unit further along x than its parent, so
/// joint i's model-space translation is exactly i.
const Chain = struct {
    skeleton: zozz.Skeleton,
    /// Four joints fit in one SoA block, so the pose lives in the fixture.
    pose: [1]zozz.SoaTransform,

    fn init() !Chain {
        const raw = try zozz.RawSkeleton.init();
        defer raw.deinit();
        var parent: ?u32 = null;
        for ([_][*:0]const u8{ "j0", "j1", "j2", "j3" }, 0..) |name, i| {
            const offset: f32 = if (i == 0) 0 else 1;
            parent = try raw.addJoint(parent, name, translated(offset, 0, 0));
        }
        const skeleton = try raw.build();
        errdefer skeleton.deinit();
        var pose: [1]zozz.SoaTransform = undefined;
        try skeleton.restPoseSoa(&pose);
        return .{ .skeleton = skeleton, .pose = pose };
    }

    fn deinit(self: Chain) void {
        self.skeleton.deinit();
    }
};

test "the default range walks the whole hierarchy" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator() catch unreachable;

    const chain = try Chain.init();
    defer chain.deinit();

    var models: [4]zozz.Mat4 = .{poison} ** 4;
    try (zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .out = &models,
    }).run();

    for (models, 0..) |m, i| {
        try std.testing.expect(wasWritten(m));
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(i)), translationX(m), 1e-6);
    }
}

test "a from with a defaulted to still updates through the last joint" {
    // The regression this file exists for. A defaulted `to` was translated
    // to maxInt(c_int), and ozz's `Min(to + 1, n)` overflowed to INT_MIN --
    // the walk ended before it began, wrote NOT ONE matrix, and returned
    // success. This is the documented path for re-running only the chain an
    // IK correction touched.
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator() catch unreachable;

    const chain = try Chain.init();
    defer chain.deinit();

    // Joints 0 and 1 are ancestors of the range and must already be valid:
    // joint 2 is placed relative to joint 1's model matrix.
    var models: [4]zozz.Mat4 = .{poison} ** 4;
    try (zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .out = &models,
    }).run();

    models[2] = poison;
    models[3] = poison;
    try (zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .from = 2,
        .out = &models,
    }).run();

    try std.testing.expect(wasWritten(models[2]));
    try std.testing.expect(wasWritten(models[3]));
    try std.testing.expectApproxEqAbs(@as(f32, 2), translationX(models[2]), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3), translationX(models[3]), 1e-6);
}

test "to ends the walk, leaving later joints untouched" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator() catch unreachable;

    const chain = try Chain.init();
    defer chain.deinit();

    var models: [4]zozz.Mat4 = .{poison} ** 4;
    try (zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .to = 1,
        .out = &models,
    }).run();

    try std.testing.expect(wasWritten(models[0]));
    try std.testing.expect(wasWritten(models[1]));
    try std.testing.expect(!wasWritten(models[2]));
    try std.testing.expect(!wasWritten(models[3]));
}

test "from_excluded keeps from's matrix and updates its children" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator() catch unreachable;

    const chain = try Chain.init();
    defer chain.deinit();

    var models: [4]zozz.Mat4 = .{poison} ** 4;
    try (zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .out = &models,
    }).run();

    // Move joint 1 in MODEL space only -- exactly what an IK correction does
    // before the rest of the chain is re-flattened beneath it.
    models[1].m[12] = 10;
    models[2] = poison;
    models[3] = poison;

    try (zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .from = 1,
        .from_excluded = true,
        .out = &models,
    }).run();

    try std.testing.expectApproxEqAbs(@as(f32, 10), translationX(models[1]), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 11), translationX(models[2]), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 12), translationX(models[3]), 1e-6);
}

test "an out-of-range from or to is refused rather than writing nothing" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator() catch unreachable;

    const chain = try Chain.init();
    defer chain.deinit();

    var models: [4]zozz.Mat4 = .{poison} ** 4;
    const base = zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .out = &models,
    };

    const Case = struct { from: i32, to: i32 };
    for ([_]Case{
        .{ .from = 4, .to = zozz.max_joints }, // from == numJoints
        .{ .from = -2, .to = zozz.max_joints }, // below no_parent
        .{ .from = zozz.no_parent, .to = -1 }, // to below zero
        .{ .from = zozz.no_parent, .to = zozz.max_joints + 1 },
        .{ .from = zozz.no_parent, .to = std.math.maxInt(i32) }, // the old sentinel
        .{ .from = 2, .to = 1 }, // to below a real from
    }) |case| {
        var job = base;
        job.from = case.from;
        job.to = case.to;
        try std.testing.expectError(zozz.Error.InvalidArgument, job.run());
    }

    // Nothing was written by any of them.
    for (models) |m| try std.testing.expect(!wasWritten(m));
}

test "a destination smaller than the skeleton is refused whatever the range" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator() catch unreachable;

    const chain = try Chain.init();
    defer chain.deinit();

    // Ancestors outside the range are still READ from `out`, so a short buffer
    // is invalid even when the range itself would fit in it.
    var models: [2]zozz.Mat4 = .{poison} ** 2;
    try std.testing.expectError(zozz.Error.BufferTooSmall, (zozz.LocalToModelJob{
        .skeleton = chain.skeleton,
        .locals = &chain.pose,
        .from = 0,
        .to = 1,
        .out = &models,
    }).run());
}

test "max_joints is ozz's own ceiling, and a pose cannot exceed it" {
    try zozz.setAllocator(std.testing.allocator);
    defer zozz.resetAllocator() catch unreachable;

    try std.testing.expectEqual(@as(i32, 1024), zozz.max_joints);
    try std.testing.expectError(
        zozz.Error.InvalidArgument,
        zozz.soaBlocks(@as(u32, @intCast(zozz.max_joints)) + 1),
    );
    try std.testing.expectEqual(@as(usize, 256), try zozz.soaBlocks(@intCast(zozz.max_joints)));
}
