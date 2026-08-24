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
    defer zozz.resetAllocator();

    const raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.0, 0.0);
    try raw.pushKeyframe(.linear, 0.5, 10.0);
    try raw.pushKeyframe(.linear, 1.0, 0.0);

    const track = try buildTrack(raw);
    defer track.deinit();

    // Exact keyframes.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try track.sample(0.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), try track.sample(0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try track.sample(1.0), 1e-4);

    // Halfway between two keyframes lands halfway between their values.
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), try track.sample(0.25), 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), try track.sample(0.75), 1e-2);
}

test "the triggering iterator yields the edges of a step function, in order" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    // A square wave: 0, 1, 0, 1 held over each quarter, step interpolation
    // so the transition sits exactly at each keyframe's ratio.
    const raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    try raw.pushKeyframe(.step, 0.0, 0.0);
    try raw.pushKeyframe(.step, 0.25, 1.0);
    try raw.pushKeyframe(.step, 0.5, 0.0);
    try raw.pushKeyframe(.step, 0.75, 1.0);

    const track = try buildTrack(raw);
    defer track.deinit();

    const triggering = try zozz.TrackTriggering.init(track, 0.0, 1.0, 0.5);
    defer triggering.deinit();

    var edges: [8]zozz.TrackEdge = undefined;
    var count: usize = 0;
    while (triggering.valid()) {
        edges[count] = try triggering.get();
        count += 1;
        try triggering.next();
    }

    // Four edges, and the first one is at ratio 0 — which is the part worth
    // pinning. A track is CYCLIC: the value at ratio 1 wraps to the value at
    // ratio 0. This wave ends high and starts low, so the seam is a falling
    // edge, and it lands at the START of the range rather than the end.
    //
    // A host driving a footstep off a looping clip gets that trigger on every
    // lap, at the moment the clip restarts. Counting the keyframes suggests
    // three edges; there are four, and the extra one fires first.
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
    defer zozz.resetAllocator();

    const raw = try zozz.RawFloatTrack.init();
    defer raw.deinit();
    // 11 co-linear points on a ramp from 0 to 10: every interior point is
    // exactly reproducible by interpolating its neighbours, so an optimizer
    // that actually looks at the data should discard nearly all of them.
    for (0..11) |i| {
        const ratio: f32 = @as(f32, @floatFromInt(i)) / 10.0;
        try raw.pushKeyframe(.linear, ratio, ratio * 10.0);
    }
    try std.testing.expectEqual(@as(u32, 11), raw.numKeyframes());

    const optimized = try zozz.RawFloatTrack.init();
    defer optimized.deinit();
    try raw.optimize(1e-3, optimized);

    try std.testing.expect(optimized.numKeyframes() < raw.numKeyframes());

    const original_track = try buildTrack(raw);
    defer original_track.deinit();
    const optimized_track = try buildTrack(optimized);
    defer optimized_track.deinit();

    var ratio: f32 = 0.0;
    while (ratio <= 1.0) : (ratio += 0.1) {
        const a = try original_track.sample(ratio);
        const b = try optimized_track.sample(ratio);
        try std.testing.expectApproxEqAbs(a, b, 1e-2);
    }
}
