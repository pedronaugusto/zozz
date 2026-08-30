//! Behavioural tests for OzzImporter: a small hand-authored .gltf fixture
//! (tests/data/two_joint.gltf — a two-joint skeleton, root -> child, with a
//! two-keyframe LINEAR rotation on the child) exercises the concrete glTF
//! backend, and a host-implemented ImporterInterface exercises the other
//! direction, independent of -Dgltf.

const std = @import("std");
const zozz = @import("zozz.zig");

const fixture_path = "tests/data/two_joint.gltf";

//=============================================================================
// A host-implementable importer, reused by the tests below that need
// -Doptions but not -Dgltf: builds the same two-joint skeleton the fixture
// file describes, entirely through the public zozz.c raw-skeleton/animation
// API a real host would use.
//=============================================================================

fn hostLoad(user: ?*anyopaque, filename: [*:0]const u8) callconv(.c) c_int {
    _ = user;
    _ = filename;
    return 1;
}

fn hostImportSkeleton(user: ?*anyopaque, types: zozz.ImportNodeType, out: *zozz.c.RawSkeleton) callconv(.c) c_int {
    _ = user;
    _ = types;
    var root_index: i32 = undefined;
    if (zozz.c.zozzRawSkeletonAddJoint(out, -1, "root", &zozz.transform_identity, &root_index) != .ok) {
        return 0;
    }
    var child_index: i32 = undefined;
    if (zozz.c.zozzRawSkeletonAddJoint(out, root_index, "child", &zozz.transform_identity, &child_index) != .ok) {
        return 0;
    }
    return 1;
}

fn hostImportAnimation(
    user: ?*anyopaque,
    animation_name: [*:0]const u8,
    skeleton: ?*const zozz.c.Skeleton,
    sampling_rate: f32,
    out: **zozz.c.RawAnimation,
) callconv(.c) c_int {
    _ = user;
    _ = animation_name;
    _ = sampling_rate;
    const num_tracks = zozz.c.zozzSkeletonNumJoints(skeleton);
    var handle: *zozz.c.RawAnimation = undefined;
    if (zozz.c.zozzRawAnimationCreate(num_tracks, 1.0, "host", &handle) != .ok) return 0;
    out.* = handle;
    return 1;
}

fn hostInterface() zozz.ImporterInterface {
    var interface = std.mem.zeroes(zozz.ImporterInterface);
    interface.load = &hostLoad;
    interface.import_skeleton = &hostImportSkeleton;
    interface.import_animation = &hostImportAnimation;
    return interface;
}

//=============================================================================
// The concrete glTF backend (-Dgltf)
//=============================================================================

test "gltf: import a skeleton and an animation from a fixture file" {
    if (!zozz.options.gltf) return error.SkipZigTest;

    var importer = try zozz.Importer.initFromGltf(fixture_path);
    defer importer.deinit();

    const all_types = zozz.ImportNodeType{
        .skeleton = true,
        .marker = true,
        .camera = true,
        .geometry = true,
        .light = true,
        .null = true,
        .any = true,
    };
    var raw_skel = try importer.importSkeleton(all_types);
    defer raw_skel.deinit();

    // Joint names and parent indices: root -> child, depth-first.
    try std.testing.expectEqual(@as(u32, 2), raw_skel.numJoints());
    try std.testing.expectEqualStrings("root", raw_skel.jointName(0).?);
    try std.testing.expectEqualStrings("child", raw_skel.jointName(1).?);
    try std.testing.expectEqual(@as(?u32, null), raw_skel.jointParent(0));
    try std.testing.expectEqual(@as(?u32, 0), raw_skel.jointParent(1));

    var skel = try raw_skel.build();
    defer skel.deinit();

    var animation_count: usize = 0;
    var found_clip = false;
    const Context = struct { count: *usize, found: *bool };
    var context = Context{ .count = &animation_count, .found = &found_clip };
    try importer.iterateAnimationNames(&context, struct {
        fn visit(ctx: *Context, name: [:0]const u8) void {
            ctx.count.* += 1;
            if (std.mem.eql(u8, name, "clip")) ctx.found.* = true;
        }
    }.visit);
    try std.testing.expectEqual(@as(usize, 1), animation_count);
    try std.testing.expect(found_clip);

    var raw_anim = try importer.importAnimation("clip", skel, 0.0);
    defer raw_anim.deinit();
    try std.testing.expectEqual(@as(u32, 2), raw_anim.numTracks());
    try std.testing.expectEqual(@as(f32, 1.0), raw_anim.duration());

    // Track 1 (child) carries the two authored rotation keyframes. LINEAR
    // interpolation copies gltf keyframes to ozz ones exactly
    // (gltf2ozz.cc's SampleLinearChannel), so sampling exactly at each
    // keyframe's own time reads back the authored value.
    const first = try raw_anim.sampleTrack(1, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.rotation[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.rotation[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.rotation[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), first.rotation[3], 1e-5);

    const last = try raw_anim.sampleTrack(1, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), last.rotation[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), last.rotation[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710678), last.rotation[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710678), last.rotation[3], 1e-4);
}

test "gltf: unsupported without -Dgltf" {
    if (zozz.options.gltf) return error.SkipZigTest;
    try std.testing.expectError(zozz.Error.Unsupported, zozz.Importer.initFromGltf(fixture_path));
}

//=============================================================================
// The host-implementable interface — independent of -Dgltf, needs -Doptions.
//=============================================================================

test "gltf: a host-supplied importer round-trips a two-joint skeleton" {
    if (!zozz.options.options) return error.SkipZigTest;

    var interface = hostInterface();
    var importer = try zozz.Importer.init(&interface);
    defer importer.deinit();
    try importer.load("ignored-by-the-host");

    var raw_skel = try importer.importSkeleton(std.mem.zeroes(zozz.ImportNodeType));
    defer raw_skel.deinit();

    try std.testing.expectEqual(@as(u32, 2), raw_skel.numJoints());
    try std.testing.expectEqualStrings("root", raw_skel.jointName(0).?);
    try std.testing.expectEqualStrings("child", raw_skel.jointName(1).?);
    try std.testing.expectEqual(@as(?u32, null), raw_skel.jointParent(0));
    try std.testing.expectEqual(@as(?u32, 0), raw_skel.jointParent(1));

    // Round-trips through a built runtime skeleton and back into an
    // animation import too, exercising the whole host path end to end.
    var skel = try raw_skel.build();
    defer skel.deinit();
    var raw_anim = try importer.importAnimation("clip", skel, 0.0);
    defer raw_anim.deinit();
    try std.testing.expectEqual(@as(u32, 2), raw_anim.numTracks());
}

test "gltf: a required host callback missing is rejected at Importer.init" {
    if (!zozz.options.options) return error.SkipZigTest;
    var interface = std.mem.zeroes(zozz.ImporterInterface);
    try std.testing.expectError(zozz.Error.InvalidArgument, zozz.Importer.init(&interface));
}

test "gltf: the host-implementable interface is unsupported without -Doptions" {
    if (zozz.options.options) return error.SkipZigTest;
    var interface = std.mem.zeroes(zozz.ImporterInterface);
    try std.testing.expectError(zozz.Error.Unsupported, zozz.Importer.init(&interface));
}

//=============================================================================
// The CLI driver (OzzImporter::operator()) is not bound: its dependency
// chain needs jsoncpp, which UPSTREAM.md records as deliberately excluded
// from the vendored tree. Pinned here so a future change that vendors
// jsoncpp and wires the driver up for real has to touch this test.
//=============================================================================

test "gltf: the CLI driver is always unsupported (jsoncpp is not vendored)" {
    const argv = [_][*:0]const u8{"prog"};

    if (zozz.options.gltf) {
        var importer = try zozz.Importer.initFromGltf(fixture_path);
        defer importer.deinit();
        try std.testing.expectError(zozz.Error.Unsupported, importer.run(&argv));
        return;
    }
    if (zozz.options.options) {
        var interface = hostInterface();
        var importer = try zozz.Importer.init(&interface);
        defer importer.deinit();
        try std.testing.expectError(zozz.Error.Unsupported, importer.run(&argv));
        return;
    }
    return error.SkipZigTest;
}
