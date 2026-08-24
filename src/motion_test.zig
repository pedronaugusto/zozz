//! Behavioural tests for root motion: pulling it out of a clip offline with
//! `MotionExtractor`, and combining per-clip deltas at runtime with
//! `MotionBlendingJob`.
//!
//! The extraction contract has two sides and a test that checks one without
//! the other proves nothing: the motion track must carry the movement the
//! root actually had, AND the animation left behind must no longer contain
//! it. A extractor that copied the root track and changed nothing else would
//! pass the first half; one that zeroed the root would pass the second.

const std = @import("std");
const zozz = @import("zozz.zig");

const duration: f32 = 2.0;

fn translated(x: f32, y: f32, z: f32) zozz.Transform {
    var t = zozz.transform_identity;
    t.translation = .{ x, y, z };
    return t;
}

fn expectVec3(expected: [3]f32, actual: [3]f32, tolerance: f32) !void {
    for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, tolerance);
}

/// root -> child. The root's REST translation is (1, 0, 0), which only the
/// `.skeleton` reference below is measured against; the other two references
/// must ignore it.
fn buildSkeleton() !zozz.Skeleton {
    const raw = try zozz.RawSkeleton.init();
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", translated(1, 0, 0));
    _ = try raw.addJoint(root, "child", translated(0, 1, 0));
    return raw.build();
}

const key_times = [_]f32{ 0, duration / 2, duration };

/// The root walks from (5, 3, 0) to (9, 3, 6): 4 units along X, 6 along Z,
/// and a CONSTANT 3 on Y. Y is the control — the settings below never ask for
/// it, so it must survive in the animation untouched.
fn rootTranslationAt(time: f32) [3]f32 {
    const alpha = time / duration;
    return .{ 5 + 4 * alpha, 3, 6 * alpha };
}

fn buildWalk() !zozz.RawAnimation {
    const raw = try zozz.RawAnimation.init(2, duration, "walk");
    errdefer raw.deinit();
    for (key_times) |time| {
        try raw.pushTranslation(0, time, rootTranslationAt(time));
        try raw.pushRotation(0, time, .{ 0, 0, 0, 1 });
        try raw.pushScale(0, time, .{ 1, 1, 1 });
        try raw.pushTranslation(1, time, .{ 0, 1, 0 });
        try raw.pushRotation(1, time, .{ 0, 0, 0, 1 });
        try raw.pushScale(1, time, .{ 1, 1, 1 });
    }
    return raw;
}

/// Position settings that take X and Z but not Y, measured from `reference`.
fn positionSettings(reference: zozz.MotionReference, bake: bool) zozz.MotionSettings {
    return .{ .x = true, .y = false, .z = true, .reference = reference, .bake = bake };
}

/// Rotation settings that take nothing: the mask zeroes every decomposed
/// component, so the extracted rotation is the identity at every key and
/// baking it back is a no-op. Isolates the translation half.
const no_rotation: zozz.MotionSettings = .{
    .x = false,
    .y = false,
    .z = false,
    .reference = .absolute,
    .bake = true,
};

test "extracting root motion yields the root's translation, and the clip no longer has it" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skel = try buildSkeleton();
    defer skel.deinit();
    const input = try buildWalk();
    defer input.deinit();

    const extractor = try zozz.MotionExtractor.init();
    defer extractor.deinit();
    try extractor.setRootJoint(0);
    try std.testing.expectEqual(@as(u32, 0), extractor.rootJoint());
    try extractor.setPositionSettings(positionSettings(.absolute, true));
    try extractor.setRotationSettings(no_rotation);

    const motion_position = try zozz.RawFloat3Track.init();
    defer motion_position.deinit();
    const motion_rotation = try zozz.RawQuaternionTrack.init();
    defer motion_rotation.deinit();
    const output = try zozz.RawAnimation.init(2, duration, null);
    defer output.deinit();

    try extractor.run(input, skel, motion_position, motion_rotation, output);

    // One motion key per input translation key. The motion track is indexed
    // by RATIO, not seconds — a clip's key at t seconds becomes a track key
    // at t/duration, and a host sampling the two together has to convert.
    try std.testing.expectEqual(@as(u32, key_times.len), motion_position.numKeyframes());

    const position_track = try motion_position.build();
    defer position_track.deinit();

    // The motion IS the root's X and Z, unshifted (reference = absolute).
    for (key_times) |time| {
        const ratio = time / duration;
        const original = rootTranslationAt(time);
        try expectVec3(
            .{ original[0], 0, original[2] },
            try position_track.sample(ratio),
            1e-4,
        );
    }

    // ...and the animation left behind has none of it. X and Z are flat at
    // whatever the reference was (0 here); Y, which was never asked for, is
    // untouched at 3.
    for (key_times) |time| {
        const residual = try output.sampleTrack(0, time);
        try expectVec3(.{ 0, 3, 0 }, residual.translation, 1e-4);
    }

    // The non-root joint is not touched at all — extraction is a property of
    // one track, not of the clip.
    for (key_times) |time| {
        const child = try output.sampleTrack(1, time);
        try expectVec3(.{ 0, 1, 0 }, child.translation, 1e-5);
    }
    try std.testing.expectApproxEqAbs(duration, output.duration(), 1e-6);
    try std.testing.expectEqual(@as(u32, 2), output.numTracks());
}

test "the residual clip and the extracted motion recompose the original" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skel = try buildSkeleton();
    defer skel.deinit();
    const input = try buildWalk();
    defer input.deinit();

    const extractor = try zozz.MotionExtractor.init();
    defer extractor.deinit();
    // `.skeleton` this time, so the reference is a non-zero offset and a
    // recomposition that quietly dropped it would show.
    try extractor.setPositionSettings(positionSettings(.skeleton, true));
    try extractor.setRotationSettings(no_rotation);

    const motion_position = try zozz.RawFloat3Track.init();
    defer motion_position.deinit();
    const motion_rotation = try zozz.RawQuaternionTrack.init();
    defer motion_rotation.deinit();
    const output = try zozz.RawAnimation.init(2, duration, null);
    defer output.deinit();
    try extractor.run(input, skel, motion_position, motion_rotation, output);

    const position_track = try motion_position.build();
    defer position_track.deinit();

    // This is the whole reason the bake exists: a runtime that samples the
    // stripped clip and adds back the motion track has to land on the clip it
    // started with. Checked between the keys as well as on them, since both
    // sides interpolate linearly and a scaling mistake would only show off a
    // key.
    for (0..21) |i| {
        const time = duration * @as(f32, @floatFromInt(i)) / 20.0;
        const residual = try output.sampleTrack(0, time);
        const motion = try position_track.sample(time / duration);

        var recomposed: [3]f32 = undefined;
        for (&recomposed, residual.translation, motion) |*sum, r, m| sum.* = r + m;
        try expectVec3(rootTranslationAt(time), recomposed, 1e-3);
    }
}

test "the reference setting decides what the extracted motion is measured from" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    const skel = try buildSkeleton();
    defer skel.deinit();
    const input = try buildWalk();
    defer input.deinit();

    const extractor = try zozz.MotionExtractor.init();
    defer extractor.deinit();
    try extractor.setRotationSettings(no_rotation);

    // The clip starts at x = 5; the skeleton's rest root sits at x = 1. Each
    // reference subtracts something different, and the value at ratio 0 is
    // where they separate:
    //
    //   absolute  -> 5, the raw component
    //   skeleton  -> 4, measured from the rest pose
    //   animation -> 0, measured from the clip's own first frame
    //
    // A host that picks the wrong one gets a character that teleports by the
    // difference on the first frame of the clip.
    const cases = [_]struct { reference: zozz.MotionReference, at_zero: f32 }{
        .{ .reference = .absolute, .at_zero = 5 },
        .{ .reference = .skeleton, .at_zero = 4 },
        .{ .reference = .animation, .at_zero = 0 },
    };

    for (cases) |case| {
        try extractor.setPositionSettings(positionSettings(case.reference, true));
        const read_back = try extractor.positionSettings();
        try std.testing.expectEqual(case.reference, read_back.reference);
        try std.testing.expect(read_back.x and !read_back.y and read_back.z);

        const motion_position = try zozz.RawFloat3Track.init();
        defer motion_position.deinit();
        const motion_rotation = try zozz.RawQuaternionTrack.init();
        defer motion_rotation.deinit();
        const output = try zozz.RawAnimation.init(2, duration, null);
        defer output.deinit();
        try extractor.run(input, skel, motion_position, motion_rotation, output);

        const track = try motion_position.build();
        defer track.deinit();

        try expectVec3(.{ case.at_zero, 0, 0 }, try track.sample(0), 1e-4);
        // Whatever the reference, the DISTANCE travelled is the same: the
        // reference shifts the origin of the motion track, it does not
        // rescale it.
        try expectVec3(.{ case.at_zero + 4, 0, 6 }, try track.sample(1), 1e-4);
    }
}

test "blending root-motion deltas preserves distance travelled, and never scale" {
    const gpa = std.testing.allocator;
    try zozz.setAllocator(gpa);
    defer zozz.resetAllocator();

    var out: zozz.Transform = undefined;

    // No layers is the identity — a host with every clip weighted off gets a
    // character that stands still, not one that jumps to the origin with a
    // zero scale.
    try (zozz.MotionBlendingJob{ .layers = &[_]zozz.BlendLayer{}, .out = &out }).run();
    try expectVec3(.{ 0, 0, 0 }, out.translation, 1e-6);
    try expectVec3(.{ 1, 1, 1 }, out.scale, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out.rotation[3], 1e-6);

    // A single layer reproduces its delta exactly, at ANY positive weight:
    // the weights are normalized, so a lone layer at 0.1 is not a tenth of a
    // step. Scale is discarded either way — the job outputs identity scale
    // unconditionally, so a delta carrying one loses it.
    const single: zozz.Transform = .{
        .translation = .{ 3, 0, 4 }, // length 5.
        .rotation = .{ 0, 0, 0, 1 },
        .scale = .{ 7, 7, 7 },
    };
    for ([_]f32{ 0.1, 1.0, 25.0 }) |weight| {
        try (zozz.MotionBlendingJob{ .layers = &[_]zozz.BlendLayer{
            .{ .weight = weight, .delta = &single },
        }, .out = &out }).run();
        try expectVec3(.{ 3, 0, 4 }, out.translation, 1e-4);
        try expectVec3(.{ 1, 1, 1 }, out.scale, 1e-6);
    }

    // Two equal-length steps in perpendicular directions, blended half and
    // half. The direction splits the difference — but the LENGTH is the
    // weighted average of the two lengths (1), not the length of the averaged
    // vector (0.707). That separation is the reason this job exists rather
    // than a plain lerp: a character blending between two run cycles keeps
    // its stride length instead of shrinking it mid-turn.
    const east: zozz.Transform = .{
        .translation = .{ 1, 0, 0 },
        .rotation = .{ 0, 0, 0, 1 },
        .scale = .{ 1, 1, 1 },
    };
    const north: zozz.Transform = .{
        .translation = .{ 0, 0, 1 },
        .rotation = .{ 0, 0, 0, 1 },
        .scale = .{ 1, 1, 1 },
    };
    try (zozz.MotionBlendingJob{ .layers = &[_]zozz.BlendLayer{
        .{ .weight = 0.5, .delta = &east },
        .{ .weight = 0.5, .delta = &north },
    }, .out = &out }).run();
    const half_root_two = @sqrt(2.0) / 2.0;
    try expectVec3(.{ half_root_two, 0, half_root_two }, out.translation, 1e-4);
    const length = @sqrt(
        out.translation[0] * out.translation[0] +
            out.translation[2] * out.translation[2],
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1), length, 1e-4);

    // Weights are relative, not absolute: scaling every weight by the same
    // factor changes nothing.
    var scaled_weights: zozz.Transform = undefined;
    try (zozz.MotionBlendingJob{ .layers = &[_]zozz.BlendLayer{
        .{ .weight = 5, .delta = &east },
        .{ .weight = 5, .delta = &north },
    }, .out = &scaled_weights }).run();
    try expectVec3(out.translation, scaled_weights.translation, 1e-5);

    // A layer at weight 0 (or below) drops out entirely rather than dragging
    // the result toward its delta.
    try (zozz.MotionBlendingJob{ .layers = &[_]zozz.BlendLayer{
        .{ .weight = 1, .delta = &east },
        .{ .weight = 0, .delta = &north },
        .{ .weight = -3, .delta = &north },
    }, .out = &out }).run();
    try expectVec3(.{ 1, 0, 0 }, out.translation, 1e-5);

    // A NaN weight is refused rather than poisoning the whole blend: ozz's
    // own "negative counts as zero" clamp never catches it, because NaN is
    // neither <= 0 nor > 0.
    try std.testing.expectError(zozz.Error.InvalidArgument, (zozz.MotionBlendingJob{
        .layers = &[_]zozz.BlendLayer{.{ .weight = std.math.nan(f32), .delta = &east }},
        .out = &out,
    }).run());
}
