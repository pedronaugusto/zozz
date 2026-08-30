//! Behavioural tests for runtime float tracks, edge-triggering, and the raw
//! track key-frame optimizer.

const std = @import("std");
const zozz = @import("zozz.zig");

/// `RawFloatTrack.build()` returns rawtrack.zig's own minimal `FloatTrack`
/// (handle + deinit only) rather than track.zig's — see zozz.zig's comment
/// on the two. Both wrap the same `*c.FloatTrack`, so re-wrapping the handle
/// here is enough to get `sample`.
fn buildTrack(raw: zozz.RawFloatTrack) !zozz.FloatTrack {
    const built = try raw.build();
    return .{ .handle = built.handle };
}

test "a float track returns keyframe values exactly and interpolates between them" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, 0.0);
    try raw.pushKeyframe(.linear, 0.5, 10.0);
    try raw.pushKeyframe(.linear, 1.0, 0.0);

    var track = try buildTrack(raw);
    defer track.deinit();

    // Exact keyframes.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try track.sample(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), try track.sample(0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try track.sample(1.0), 1e-4);

    // Halfway between two keyframes lands halfway between their values.
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), try track.sample(0.25), 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), try track.sample(0.75), 1e-2);
}

test "a float track's keyframe read-back matches what was authored, across a bitset byte boundary" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    // 12 keys — more than the 8 in one byte of the packed steps bitset
    // (Track::steps(), one bit per key) — alternating step/linear, so an
    // off-by-one at the byte boundary (i/8 or i%8) shows up at index 8+, not by
    // silently passing with fewer keys. front()/back() sit exactly at ratio 0
    // and 1, so the builder patches nothing in: the built track holds exactly
    // these 12 keys, in order.
    var raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    const count = 12;
    for (0..count) |i| {
        const ratio: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
        const value: f32 = @floatFromInt(i);
        const interpolation: zozz.TrackInterpolation = if (i % 2 == 0) .step else .linear;
        try raw.pushKeyframe(interpolation, ratio, value);
    }

    var track = try buildTrack(raw);
    defer track.deinit();

    try std.testing.expectEqual(@as(u32, count), track.numKeyframes());

    const ratios = try track.ratios(gpa);
    defer gpa.free(ratios);
    const values = try track.values(gpa);
    defer gpa.free(values);
    const steps = try track.steps(gpa);
    defer gpa.free(steps);

    try std.testing.expectEqual(@as(usize, count), ratios.len);
    try std.testing.expectEqual(@as(usize, count), values.len);
    try std.testing.expectEqual(@as(usize, count), steps.len);

    for (0..count) |i| {
        const expected_ratio: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1));
        try std.testing.expectApproxEqAbs(expected_ratio, ratios[i], 1e-6);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), values[i]);
        const expected: zozz.TrackInterpolation = if (i % 2 == 0) .step else .linear;
        try std.testing.expectEqual(expected, steps[i]);
    }
}

test "a float3 track's keyframe read-back matches what was authored" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawFloat3Track.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, .{ 1, 2, 3 });
    try raw.pushKeyframe(.step, 0.5, .{ -1, -2, -3 });
    try raw.pushKeyframe(.linear, 1.0, .{ 0, 0, 0 });

    var track = try raw.build();
    defer track.deinit();

    try std.testing.expectEqual(@as(u32, 3), track.numKeyframes());

    const ratios = try track.ratios(gpa);
    defer gpa.free(ratios);
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.5, 1.0 }, ratios);

    const values = try track.values(gpa);
    defer gpa.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, values[0]);
    try std.testing.expectEqual([3]f32{ -1, -2, -3 }, values[1]);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, values[2]);

    const steps = try track.steps(gpa);
    defer gpa.free(steps);
    try std.testing.expectEqualSlices(
        zozz.TrackInterpolation,
        &.{ .linear, .step, .linear },
        steps,
    );
}

test "a quaternion track's keyframe read-back preserves x, y, z, w order" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    // A 90-degree turn about Z: identity, then (0, 0, sin45, cos45) — w LAST,
    // matching every other quaternion in this package.
    const half_turn: f32 = std.math.sqrt2 / 2.0;
    var raw = try zozz.RawQuaternionTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, .{ 0, 0, 0, 1 });
    try raw.pushKeyframe(.linear, 1.0, .{ 0, 0, half_turn, half_turn });

    var track = try raw.build();
    defer track.deinit();

    const values = try track.values(gpa);
    defer gpa.free(values);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, values[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), values[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), values[1][1], 1e-6);
    try std.testing.expectApproxEqAbs(half_turn, values[1][2], 1e-6);
    try std.testing.expectApproxEqAbs(half_turn, values[1][3], 1e-6);
}

test "the triggering iterator yields the edges of a step function, in order" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    // A square wave: 0, 1, 0, 1 held over each quarter, step interpolation
    // so the transition sits exactly at each keyframe's ratio.
    var raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.step, 0.0, 0.0);
    try raw.pushKeyframe(.step, 0.25, 1.0);
    try raw.pushKeyframe(.step, 0.5, 0.0);
    try raw.pushKeyframe(.step, 0.75, 1.0);

    var track = try buildTrack(raw);
    defer track.deinit();

    var triggering = try zozz.TrackTriggering.init(track, 0.0, 1.0, 0.5);
    defer triggering.deinit();

    var edges: [8]zozz.TrackEdge = undefined;
    var count: usize = 0;
    while (triggering.valid()) {
        edges[count] = try triggering.get();
        count += 1;
        try triggering.next();
    }

    // Four edges, and the first is at ratio 0: a track is CYCLIC, so the value
    // at ratio 1 wraps to ratio 0. This wave ends high and starts low, so the
    // seam is a falling edge landing at the START of the range, not the end. A
    // host driving a footstep off a looping clip gets that trigger every lap,
    // at the restart: counting keyframes suggests three edges, but the extra
    // one fires first.
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), edges[0].ratio, 1e-3);
    try std.testing.expect(!edges[0].rising);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), edges[1].ratio, 1e-3);
    try std.testing.expect(edges[1].rising);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), edges[2].ratio, 1e-3);
    try std.testing.expect(!edges[2].rising);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), edges[3].ratio, 1e-3);
    try std.testing.expect(edges[3].rising);
}

test "the track optimizer reduces keyframe count within tolerance of the original" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator() catch unreachable;

    var raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    // 11 co-linear points on a ramp from 0 to 10: every interior point is
    // exactly reproducible by interpolating its neighbours, so an optimizer
    // that actually looks at the data should discard nearly all of them.
    for (0..11) |i| {
        const ratio: f32 = @as(f32, @floatFromInt(i)) / 10.0;
        try raw.pushKeyframe(.linear, ratio, ratio * 10.0);
    }
    try std.testing.expectEqual(@as(u32, 11), raw.numKeyframes());

    var optimized = try zozz.RawFloatTrack.init();
    defer optimized.deinit();
    try raw.optimize(1e-3, optimized);

    try std.testing.expect(optimized.numKeyframes() < raw.numKeyframes());

    var original_track = try buildTrack(raw);
    defer original_track.deinit();
    var optimized_track = try buildTrack(optimized);
    defer optimized_track.deinit();

    var ratio: f32 = 0.0;
    while (ratio <= 1.0) : (ratio += 0.1) {
        const a = try original_track.sample(ratio);
        const b = try optimized_track.sample(ratio);
        try std.testing.expectApproxEqAbs(a, b, 1e-2);
    }
}

test "a raw track reads back what was authored, and validates ratio order" {
    var raw = try zozz.RawFloat3Track.init();
    defer raw.deinit();

    try std.testing.expectEqualStrings("", raw.name());
    try raw.setName("wind");
    try raw.pushKeyframe(.step, 0.0, .{ 1, 0, 0 });
    try raw.pushKeyframe(.linear, 0.5, .{ 0, 1, 0 });

    var keys: [4]zozz.Float3Keyframe = undefined;
    const back = try raw.keyframes(&keys);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(zozz.TrackInterpolation.step, back[0].interpolation);
    try std.testing.expectEqual(@as(f32, 0.0), back[0].ratio);
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, back[0].value);
    try std.testing.expectEqual(zozz.TrackInterpolation.linear, back[1].interpolation);
    try std.testing.expectEqual(@as(f32, 0.5), back[1].ratio);
    try std.testing.expectEqual([3]f32{ 0, 1, 0 }, back[1].value);

    // A short buffer is refused before anything is written.
    var one: [1]zozz.Float3Keyframe = .{.{ .interpolation = .step, .ratio = -1, .value = .{ 9, 9, 9 } }};
    try std.testing.expectError(error.BufferTooSmall, raw.keyframes(&one));
    try std.testing.expectEqual(@as(f32, -1), one[0].ratio);

    // ozz's RawTrack::Validate wants strictly ascending ratios; the push
    // entry point cannot see order, so this is where it surfaces — before
    // build, which reports the same thing as error.InvalidData.
    try std.testing.expect(raw.validate());
    try raw.pushKeyframe(.linear, 0.25, .{ 0, 0, 1 });
    try std.testing.expect(!raw.validate());
    try std.testing.expectError(error.InvalidData, raw.build());

    // Clearing keeps the name and lets the track be rewritten.
    try raw.clear();
    try std.testing.expectEqual(@as(u32, 0), raw.numKeyframes());
    try std.testing.expectEqualStrings("wind", raw.name());
    try raw.pushKeyframe(.linear, 0.0, .{ 2, 2, 2 });
    try std.testing.expect(raw.validate());
    var built = try raw.build();
    defer built.deinit();
    try std.testing.expectEqualStrings("wind", built.name());
}
