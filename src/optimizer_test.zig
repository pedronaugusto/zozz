//! Behavioural tests for the offline animation processing in optimizer.zig:
//! key-frame reduction, fixed-rate sample timing, and the additive builder.
//!
//! The optimizer tests all have the same two halves, and both halves matter:
//! the output must have FEWER keys, and it must still reproduce the input
//! within the tolerance that was asked for. Either one alone is passable by a
//! broken optimizer — the first by one that throws the animation away, the
//! second by one that changes nothing.

const std = @import("std");
const zozz = @import("zozz.zig");

fn translated(x: f32, y: f32, z: f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation = .{ x, y, z };
    return t;
}

/// root -> child, both at identity rest scale so the optimizer's translation
/// error metric is 1:1 with world units (it multiplies by the accumulated
/// parent scale, which is 1 here). That is what lets the tolerance below be
/// compared against a plain distance.
fn buildSkeleton() !zozz.Skeleton {
    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", zozz.transform_identity);
    _ = try raw.addJoint(root, "child", translated(0, 1, 0));
    return raw.build();
}

const duration: f32 = 1.0;
const dense_keys = 61;
const amplitude: f32 = 0.5;

fn curveAt(time: f32) f32 {
    return amplitude * @sin(2.0 * std.math.pi * time);
}

/// A clip whose root traces a smooth curve, densely sampled: 61 keys where a
/// dozen would do. Track 1 is deliberately near-static and keyed only at the
/// ends, so the key-time union below counts the root's keys and nothing else.
fn buildDenseAnimation() !zozz.RawAnimation {
    const raw = try zozz.RawAnimation.init(2, duration, "dense");
    errdefer raw.deinit();

    for (0..dense_keys) |i| {
        const time = duration * @as(f32, @floatFromInt(i)) / (dense_keys - 1);
        try raw.pushTranslation(0, time, .{ 0, curveAt(time), 0 });
    }
    for ([_]f32{ 0, duration }) |time| {
        try raw.pushRotation(0, time, .{ 0, 0, 0, 1 });
        try raw.pushScale(0, time, .{ 1, 1, 1 });
        try raw.pushTranslation(1, time, .{ 0, 1, 0 });
        try raw.pushRotation(1, time, .{ 0, 0, 0, 1 });
        try raw.pushScale(1, time, .{ 1, 1, 1 });
    }
    return raw;
}

/// Number of distinct key times across the whole clip. Track 1's two keys sit
/// at 0 and `duration`, which the root always keeps, so this is exactly the
/// root's translation key count.
fn countKeyTimes(raw: zozz.RawAnimation, gpa: std.mem.Allocator) !usize {
    const times = try raw.extractTimePoints(gpa);
    defer gpa.free(times);
    return times.len;
}

test "optimising drops redundant keys while staying inside the tolerance asked for" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skel = try buildSkeleton();
    defer skel.deinit();
    const input = try buildDenseAnimation();
    defer input.deinit();
    try std.testing.expectEqual(@as(usize, dense_keys), try countKeyTimes(input, gpa));

    const tolerance: f32 = 1e-2;
    const optimizer = try zozz.AnimationOptimizer.init();
    defer optimizer.deinit();
    try optimizer.setSetting(.{ .tolerance = tolerance, .distance = 1e-1 });

    // The setting must be the one that gets used, not a default that was
    // silently kept.
    const read_back = try optimizer.getSetting();
    try std.testing.expectApproxEqAbs(tolerance, read_back.tolerance, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 1e-1), read_back.distance, 1e-9);

    const output = try zozz.RawAnimation.init(2, duration, null);
    defer output.deinit();
    try optimizer.run(input, skel, output);

    // Half one: fewer keys. The curve is smooth enough that most of 61 keys
    // are recoverable by interpolation, so this is a real reduction rather
    // than a key or two shaved off the ends.
    const kept = try countKeyTimes(output, gpa);
    try std.testing.expect(kept < dense_keys);
    try std.testing.expect(kept < dense_keys / 2);

    // Half two: the decimated clip must still reproduce the original
    // everywhere, not merely at the keys that survived. Both clips are
    // piecewise-linear over a subset of the same key times, so a fine sweep
    // sees the worst case. The bound is the tolerance itself: ozz's decimation
    // is Douglas-Peucker over the original keys, and the root's model-space
    // transform IS its local one, so the tolerance is a plain distance here.
    const sweep = 500;
    var worst: f32 = 0;
    for (0..sweep + 1) |i| {
        const time = duration * @as(f32, @floatFromInt(i)) / sweep;
        const before = try input.sampleTrack(0, time);
        const after = try output.sampleTrack(0, time);
        var squared: f32 = 0;
        for (before.translation, after.translation) |a, b| squared += (a - b) * (a - b);
        worst = @max(worst, @sqrt(squared));
    }
    try std.testing.expect(worst <= tolerance);

    // ...and it did move: a decimation that flattened the curve to nothing
    // would sit at `amplitude` of error, not under the tolerance, but say so
    // anyway so the sweep cannot pass against an empty clip.
    try std.testing.expect(@abs(curveAt(0.25) - amplitude) < 1e-5);
    const at_peak = try output.sampleTrack(0, 0.25);
    try std.testing.expectApproxEqAbs(amplitude, at_peak.translation[1], tolerance);

    // The clip's shape is otherwise preserved: same duration, same track
    // count, and the untouched joint keeps its keys.
    try std.testing.expectApproxEqAbs(duration, output.duration(), 1e-6);
    try std.testing.expectEqual(@as(u32, 2), output.numTracks());
    const child = try output.sampleTrack(1, 0.5);
    try expectTranslation(.{ 0, 1, 0 }, child, 1e-6);
}

fn expectVec3(expected: [3]f32, actual: [3]f32, tolerance: f32) !void {
    for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, tolerance);
}

fn expectTranslation(expected: [3]f32, actual: zozz.Transform, tolerance: f32) !void {
    try expectVec3(expected, actual.translation, tolerance);
}

fn optimizedKeyCount(
    gpa: std.mem.Allocator,
    skel: zozz.Skeleton,
    input: zozz.RawAnimation,
    optimizer: zozz.AnimationOptimizer,
) !usize {
    const output = try zozz.RawAnimation.init(2, duration, null);
    defer output.deinit();
    try optimizer.run(input, skel, output);
    return countKeyTimes(output, gpa);
}

test "tolerance drives how much is dropped, and a child's override tightens its parents" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skel = try buildSkeleton();
    defer skel.deinit();
    const input = try buildDenseAnimation();
    defer input.deinit();

    const optimizer = try zozz.AnimationOptimizer.init();
    defer optimizer.deinit();

    try optimizer.setSetting(.{ .tolerance = 1e-3, .distance = 1e-1 });
    const tight = try optimizedKeyCount(gpa, skel, input, optimizer);

    try optimizer.setSetting(.{ .tolerance = 1e-1, .distance = 1e-1 });
    const loose = try optimizedKeyCount(gpa, skel, input, optimizer);

    // A looser error budget buys a smaller clip. An optimizer that ignored
    // the setting entirely would report the same number twice.
    try std.testing.expect(loose < tight);
    try std.testing.expect(tight < dense_keys);

    // The tolerance a joint is decimated with is the MINIMUM over its whole
    // subtree, not its own. So overriding the CHILD to something strict
    // tightens the root as well, even though the root's own setting has not
    // changed. A consumer tuning the fingers of a hand and finding the spine
    // grew keys is seeing this, and it is the opposite of what per-joint
    // overrides look like they do.
    try optimizer.setJointOverride(1, .{ .tolerance = 1e-4, .distance = 1e-1 });
    const child_tightened = try optimizedKeyCount(gpa, skel, input, optimizer);
    try std.testing.expect(child_tightened > loose);

    // Clearing it puts the global setting back in charge.
    try optimizer.clearJointOverride(1);
    try std.testing.expectEqual(loose, try optimizedKeyCount(gpa, skel, input, optimizer));
}

test "fixed-rate sample times are evenly spaced and the last never runs past the duration" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    {
        // A whole number of periods: 2.5s at 24Hz is 60 intervals, so 61 keys.
        const timing = try zozz.FixedRateSamplingTime.init(2.5, 24);
        defer timing.deinit();
        try std.testing.expectEqual(@as(usize, 61), timing.numKeys());
        try std.testing.expectApproxEqAbs(@as(f32, 0), try timing.at(0), 1e-6);
        for (0..timing.numKeys()) |key| {
            const time = try timing.at(key);
            try std.testing.expectApproxEqAbs(
                @as(f32, @floatFromInt(key)) / 24.0,
                time,
                1e-4,
            );
            // The property a cooker depends on: no sample time is ever past
            // the clip's end, whatever the accumulated float error would have
            // done. 60 * (1/24) overshoots 2.5 in binary floating point.
            try std.testing.expect(time <= 2.5);
        }
        try std.testing.expectApproxEqAbs(@as(f32, 2.5), try timing.at(60), 1e-6);
        try std.testing.expectError(zozz.Error.InvalidArgument, timing.at(61));
    }

    {
        // A ragged rate: 1s at 2.5Hz gives keys at 0, 0.4, 0.8, and then the
        // clamp lands the last one on 1.0 — a SHORTER final step than the
        // period. A consumer assuming a uniform delta between consecutive
        // sample times is wrong here, and this is where it shows.
        const timing = try zozz.FixedRateSamplingTime.init(1.0, 2.5);
        defer timing.deinit();
        try std.testing.expectEqual(@as(usize, 4), timing.numKeys());
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), try timing.at(0), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0.4), try timing.at(1), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0.8), try timing.at(2), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), try timing.at(3), 1e-6);
    }

    try std.testing.expectError(zozz.Error.InvalidArgument, zozz.FixedRateSamplingTime.init(1.0, 0));
    try std.testing.expectError(
        zozz.Error.InvalidArgument,
        zozz.FixedRateSamplingTime.init(std.math.nan(f32), 30),
    );
}

test "model-space sampling accounts for a parent joint's motion, not just the joint's own keys" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skel = try buildSkeleton(); // root -> child, child at rest (0, 1, 0)
    defer skel.deinit();

    const raw = try zozz.RawAnimation.init(2, duration, "model-space");
    defer raw.deinit();
    // Root translates 0 -> (4, 0, 0). The child track is left completely
    // empty — no key on any channel — so none of the motion below comes
    // from the child's own local keys.
    try raw.pushTranslation(0, 0.0, .{ 0, 0, 0 });
    try raw.pushTranslation(0, duration, .{ 4, 0, 0 });
    try raw.pushRotation(0, 0.0, .{ 0, 0, 0, 1 });
    try raw.pushScale(0, 0.0, .{ 1, 1, 1 });

    const samples = try raw.sampleTrackModelSpace(skel, 1, gpa);
    defer gpa.free(samples);

    // The only keyframe times anywhere in the joint's ancestry are the
    // root's two translation keys — the empty child track contributes none
    // of its own — so the union is exactly {0, duration}.
    try std.testing.expectEqual(@as(usize, 2), samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[0].time, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, duration), samples[1].time, 1e-6);

    // The child never moves in ITS OWN local space; every bit of motion in
    // its MODEL-space matrix (m[12..15) is the translation column) is the
    // root's, carried down through the hierarchy.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[0].transform.m[12], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[0].transform.m[13], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[0].transform.m[14], 1e-4);

    try std.testing.expectApproxEqAbs(@as(f32, 4.0), samples[1].transform.m[12], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[1].transform.m[13], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[1].transform.m[14], 1e-4);

    // An out-of-range joint and a skeleton/track-count mismatch are refused,
    // not silently sampled against garbage.
    try std.testing.expectError(
        zozz.Error.InvalidArgument,
        raw.sampleTrackModelSpace(skel, 2, gpa),
    );
    const mismatched = try zozz.RawAnimation.init(1, duration, null);
    defer mismatched.deinit();
    try std.testing.expectError(
        zozz.Error.SkeletonMismatch,
        mismatched.sampleTrackModelSpace(skel, 0, gpa),
    );
}

test "the additive builder turns a clip into deltas from its own first frame" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    // One track, starting well away from the origin and away from identity,
    // so "delta" and "absolute" cannot be confused for one another.
    const quarter_turn: [4]f32 = .{ 0, @sin(std.math.pi / 4.0), 0, @cos(std.math.pi / 4.0) };
    const input = try zozz.RawAnimation.init(1, duration, "absolute");
    defer input.deinit();
    try input.pushTranslation(0, 0, .{ 7, 3, -2 });
    try input.pushTranslation(0, duration, .{ 11, 3, -2 });
    try input.pushRotation(0, 0, .{ 0, 0, 0, 1 });
    try input.pushRotation(0, duration, quarter_turn);
    try input.pushScale(0, 0, .{ 2, 2, 2 });
    try input.pushScale(0, duration, .{ 4, 2, 2 });

    const output = try zozz.RawAnimation.init(1, duration, null);
    defer output.deinit();
    try zozz.AdditiveAnimationBuilder.run(input, output);

    // The first frame of a delta clip is the identity by construction — an
    // additive layer built from this clip and applied at t=0 must change
    // nothing about the pose it is layered onto.
    const first = try output.sampleTrack(0, 0);
    try expectTranslation(.{ 0, 0, 0 }, first, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), first.rotation[3], 1e-5);
    for (first.scale) |s| try std.testing.expectApproxEqAbs(@as(f32, 1), s, 1e-5);

    // The last frame is the difference from the first: translation subtracts,
    // rotation composes with the reference's conjugate, and scale DIVIDES.
    // The scale one is the trap — a consumer expecting a subtraction there
    // gets (2, 0, 0) instead of (2, 1, 1).
    const last = try output.sampleTrack(0, duration);
    try expectTranslation(.{ 4, 0, 0 }, last, 1e-5);
    try expectVec3(.{ 2, 1, 1 }, last.scale, 1e-5);
    var dot: f32 = 0;
    for (last.rotation, quarter_turn) |a, b| dot += a * b;
    try std.testing.expect(@abs(dot) > 0.999);

    // With an explicit reference pose the deltas are measured from it
    // instead, so a clip authored around one bind pose can be retargeted to
    // another without re-authoring: reference == the clip's LAST frame makes
    // the last frame the identity and the first frame the inverse delta.
    const from_last = try zozz.RawAnimation.init(1, duration, null);
    defer from_last.deinit();
    try zozz.AdditiveAnimationBuilder.runWithReference(input, &[_]zozz.Transform{.{
        .translation = .{ 11, 3, -2 },
        .rotation = quarter_turn,
        .scale = .{ 4, 2, 2 },
    }}, from_last);

    const referenced_last = try from_last.sampleTrack(0, duration);
    try expectTranslation(.{ 0, 0, 0 }, referenced_last, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), referenced_last.rotation[3], 1e-5);
    const referenced_first = try from_last.sampleTrack(0, 0);
    try expectTranslation(.{ -4, 0, 0 }, referenced_first, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), referenced_first.scale[0], 1e-5);

    // A reference pose shorter than the clip's track count is refused rather
    // than read past its end.
    try std.testing.expectError(
        zozz.Error.InvalidData,
        zozz.AdditiveAnimationBuilder.runWithReference(input, &[_]zozz.Transform{}, from_last),
    );
}

test "the compressed control streams size and read back for every channel" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const raw = try buildDenseAnimation();
    defer raw.deinit();
    const animation = try raw.build();
    defer animation.deinit();

    for ([_]zozz.Animation.Channel{ .translation, .rotation, .scale }) |channel| {
        const ctrl = try animation.keyframesCtrl(channel);
        try std.testing.expect(ctrl.num_ratio_bytes > 0);
        try std.testing.expect(ctrl.num_previouses > 0);
        try std.testing.expect(ctrl.iframe_interval >= 0);

        const ratios = try gpa.alloc(u8, ctrl.num_ratio_bytes);
        defer gpa.free(ratios);
        try animation.keyframeRatios(channel, ratios);

        const previouses = try gpa.alloc(u16, ctrl.num_previouses);
        defer gpa.free(previouses);
        try animation.keyframePreviouses(channel, previouses);

        const entries = try gpa.alloc(u8, ctrl.num_iframe_entry_bytes);
        defer gpa.free(entries);
        try animation.keyframeIframeEntries(channel, entries);

        const desc = try gpa.alloc(u32, ctrl.num_iframe_desc);
        defer gpa.free(desc);
        try animation.keyframeIframeDesc(channel, desc);

        // Ratios index the clip's time points, so none may run past them.
        const timepoint_count = animation.numTimepoints();
        if (timepoint_count <= 256) {
            for (ratios) |r| try std.testing.expect(r < timepoint_count);
        }

        // Two uint32 per iframe, and every offset lands inside the entries.
        try std.testing.expectEqual(@as(usize, 0), ctrl.num_iframe_desc % 2);
        var i: usize = 0;
        while (i < desc.len) : (i += 2) {
            try std.testing.expect(desc[i] <= entries.len);
        }
    }

    // A channel value the host made up is rejected, not read out of bounds.
    try std.testing.expectError(
        error.InvalidArgument,
        animation.keyframesCtrl(@enumFromInt(99)),
    );

    // A buffer that is too small is refused rather than overrun.
    const ctrl = try animation.keyframesCtrl(.translation);
    var tiny: [1]u8 = undefined;
    if (ctrl.num_ratio_bytes > 1) {
        try std.testing.expectError(
            error.BufferTooSmall,
            animation.keyframeRatios(.translation, &tiny),
        );
    }
}
