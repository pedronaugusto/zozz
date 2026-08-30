//! Runs the thread-safety claim `ffi/zozz_core.h` makes, rather than asserting
//! it in prose.
//!
//! The claim is that distinct handles may be used concurrently as long as the
//! installed allocator is thread-safe, because every entry point that
//! allocates reaches the one process-wide seam. A sentence cannot fail; this
//! can. Each worker owns its own sampling context, its own poses and its own
//! model matrices, allocates and frees handles of its own while it runs, and
//! shares only the skeleton and the animation, which are immutable once built.
//!
//! A DebugAllocator backs the seam because it is thread-safe by default and
//! accounts for every block: a race that corrupts its free list, a double
//! free, or a leak all fail here, and `deinit` reports the leak explicitly.

const std = @import("std");
const zozz = @import("zozz.zig");

const joint_count = 8;
const soa_blocks = (joint_count + 3) / 4;
const worker_count = 4;
const iterations = 200;
/// Kept to one unit: the clip is compressed on the way through ozz's key
/// encoding, and a tolerance has to sit above that error rather than below
/// it. One unit is where the rest of this suite reads sampled translations.
const travel = 1.0;

/// An eight-joint chain and a clip that slides its root along x, both immutable
/// once built and shared by every worker.
const Fixture = struct {
    skeleton: zozz.Skeleton,
    animation: zozz.Animation,

    fn init() !Fixture {
        const raw_skeleton = try zozz.RawSkeleton.init();
        defer raw_skeleton.deinit();
        var parent: ?u32 = null;
        var names: [joint_count][3:0]u8 = undefined;
        for (0..joint_count) |i| {
            names[i] = .{ 'j', '0' + @as(u8, @intCast(i)), 0 };
            var local = zozz.transform_identity;
            local.translation = .{ if (i == 0) 0 else 1, 0, 0 };
            parent = try raw_skeleton.addJoint(parent, &names[i], local);
        }
        const skeleton = try raw_skeleton.build();
        errdefer skeleton.deinit();

        const raw_animation = try zozz.RawAnimation.init(joint_count, 1.0, "concurrent");
        defer raw_animation.deinit();
        try raw_animation.pushTranslation(0, 0.0, .{ 0, 0, 0 });
        try raw_animation.pushTranslation(0, 1.0, .{ travel, 0, 0 });
        const animation = try raw_animation.build();

        return .{ .skeleton = skeleton, .animation = animation };
    }

    fn deinit(self: Fixture) void {
        self.animation.deinit();
        self.skeleton.deinit();
    }
};

/// Everything one worker touches, all of it its own.
const Worker = struct {
    sampled: [soa_blocks]zozz.SoaTransform = undefined,
    blended: [soa_blocks]zozz.SoaTransform = undefined,
    rest: [soa_blocks]zozz.SoaTransform = undefined,
    models: [joint_count]zozz.Mat4 = undefined,
};

/// One worker's whole frame: create a context, sample, blend, flatten, destroy.
/// Creating and destroying inside the loop is deliberate -- it is the seam, not
/// the jobs, that this test is aimed at.
fn work(fixture: *const Fixture, first_error: *std.atomic.Value(u16)) void {
    var worker: Worker = .{};
    for (0..iterations) |i| {
        const ratio = @as(f32, @floatFromInt(i)) / @as(f32, iterations);
        frame(fixture, &worker, ratio) catch |e| {
            // The first error wins, and it is kept as an error rather than a
            // count: "four workers failed" says nothing about why.
            _ = first_error.cmpxchgStrong(0, @intFromError(e), .monotonic, .monotonic);
            return;
        };
    }
}

fn frame(fixture: *const Fixture, worker: *Worker, ratio: f32) !void {
    try fixture.skeleton.restPoseSoa(&worker.rest);
    const context = try zozz.SamplingContext.init(joint_count);
    defer context.deinit();

    const sampling = zozz.SamplingJob{
        .animation = fixture.animation,
        .context = context,
        .ratio = ratio,
        .out = &worker.sampled,
    };
    try sampling.run();

    const layers = [_]zozz.blending.Layer{zozz.blending.layer(1.0, &worker.sampled)};
    const blending = zozz.blending.BlendingJob{
        .layers = &layers,
        .rest_pose = &worker.rest,
        .out = &worker.blended,
    };
    try blending.run();

    const flatten = zozz.LocalToModelJob{
        .skeleton = fixture.skeleton,
        .locals = &worker.blended,
        .out = &worker.models,
    };
    try flatten.run();

    // The root slides from 0 to `travel` over the clip, so a torn or
    // half-written result is visible rather than merely suspected.
    if (!std.math.approxEqAbs(f32, worker.models[0].m[12], ratio * travel, 1e-3)) {
        return error.TestUnexpectedResult;
    }
}

test "distinct handles are usable from several threads at once" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    try zozz.resetAllocator();
    try zozz.setAllocator(debug_allocator.allocator());

    const fixture = try Fixture.init();
    var first_error: std.atomic.Value(u16) = .init(0);

    var threads: [worker_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, work, .{ &fixture, &first_error });
    }
    for (threads) |thread| thread.join();

    fixture.deinit();
    try zozz.resetAllocator();

    const code = first_error.load(.monotonic);
    if (code != 0) {
        const e: anyerror = @errorFromInt(code);
        std.debug.print("worker failed: {s}\n", .{@errorName(e)});
        return e;
    }
    try std.testing.expectEqual(@as(usize, 0), zozz.allocatorLiveBlocks());
    try std.testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}
