//! Each binding against the same ozz work written in C++ (bench/baseline.cpp),
//! measured through shakedown in ReleaseFast, so the Zig layer's cost is a
//! number. Timings are evidence, never a correctness gate; `--smoke` runs each
//! row once. The skeleton and clip are generated through zozz's own offline
//! builders and serialised once, untimed, so no asset is shipped.
const std = @import("std");
const shakedown = @import("shakedown");
const zozz = @import("zozz");
const baseline = @import("baseline");
const provenance = @import("preflight_bench_options");

/// The skeleton: a root, a spine topped by a neck and head, two arms that end
/// in `finger_count` fingers each, and two legs, every part a chain.
const spine_joints = 4;
const neck_joints = 2;
const arm_joints = 4;
const finger_count = 5;
const finger_joints = 3;
const leg_joints = 4;
/// The clip: every joint keyed `keys_per_second` times a second for
/// `clip_seconds`, each swinging about one axis `swings` times while the root
/// walks forward.
const clip_seconds = 4;
const keys_per_second = 30;
const swings = 2;
/// The sample rows play the clip forward at this rate, start to end.
const frame_count = clip_seconds * 60;
/// The blend: three layers, each the clip sampled at its own ratio.
const layer_ratios = [_]f32{ 0.1, 0.4, 0.7 };
const layer_weights = [_]f32{ 0.5, 0.3, 0.2 };
/// The skinned mesh: a square grid of vertices, positions and normals, each
/// vertex weighted by `influences` joints.
const mesh_side = 64;
const vertex_count = mesh_side * mesh_side;
const influences = 4;
const influence_weights = [influences - 1]f32{ 0.55, 0.25, 0.15 };
/// The two-bone solves reach for a square grid of targets around the left
/// wrist, some within the arm's reach and some past it.
const target_side = 4;
/// The left arm's upper arm, forearm and hand: the solved chain.
const chain_names = [_][:0]const u8{ "arm_l_1", "arm_l_2", "arm_l_3" };

const Failed = error{Failed};

/// The load rows' state. They run while no other ozz block is alive:
/// `setAllocator` is refused while a block of another allocator is live.
const Loads = struct {
    gpa: std.mem.Allocator,
    skeleton: []const u8,
    animation: []const u8,

    fn skeletonZig(l: *Loads, n: u64) Failed!void {
        var failure: zozz.Failure = .{};
        var joints: u64 = 0;
        for (0..n) |_| {
            var skeleton = zozz.Skeleton.initFromMemory(.init(l.skeleton), &failure) catch return error.Failed;
            joints += skeleton.numJoints();
            skeleton.deinit();
        }
        std.mem.doNotOptimizeAway(joints);
    }

    fn skeletonC(l: *Loads, n: u64) Failed!void {
        if (baseline.zozz_baseline_load_skeleton(l.skeleton.ptr, l.skeleton.len, n) == std.math.maxInt(u64)) return error.Failed;
    }

    fn animationZig(l: *Loads, n: u64) Failed!void {
        var failure: zozz.Failure = .{};
        var tracks: u64 = 0;
        for (0..n) |_| {
            var animation = zozz.Animation.initFromMemory(.init(l.animation), &failure) catch return error.Failed;
            tracks += animation.numTracks();
            animation.deinit();
        }
        std.mem.doNotOptimizeAway(tracks);
    }

    fn animationC(l: *Loads, n: u64) Failed!void {
        if (baseline.zozz_baseline_load_animation(l.animation.ptr, l.animation.len, n) == std.math.maxInt(u64)) return error.Failed;
    }

    fn installAllocator(l: *Loads) Failed!void {
        var failure: zozz.Failure = .{};
        zozz.setAllocator(l.gpa, &failure) catch return error.Failed;
    }

    fn removeAllocator(_: *Loads) Failed!void {
        var failure: zozz.Failure = .{};
        zozz.resetAllocator(&failure) catch return error.Failed;
    }
};

/// The frame rows' state: one skeleton and clip on each side, and the buffers
/// both sides read. Every input is built once, untimed; each row writes only
/// its own output.
const Frames = struct {
    skeleton: zozz.Skeleton,
    animation: zozz.Animation,
    sampling: zozz.SamplingContext,
    world: *anyopaque,
    ratios: []const f32,
    /// What the sample rows write.
    sampled: []zozz.SoaTransform,
    /// The clip at the first layer's ratio, and its model-space matrices.
    locals: []const zozz.SoaTransform,
    models: []zozz.Mat4,
    layers: []const zozz.BlendingLayer,
    poses: []const [*]const zozz.SoaTransform,
    rest: []const zozz.SoaTransform,
    blended: []zozz.SoaTransform,
    /// The skinning matrices, the mesh, and what skinning writes.
    palette: []const zozz.Mat4,
    mesh: Mesh,
    chain: [3]*const zozz.Mat4,
    targets: []const zozz.ik.Vec4,

    fn sampleZig(f: *Frames, n: u64) Failed!void {
        var failure: zozz.Failure = .{};
        var sum: f32 = 0;
        for (0..n) |i| {
            const job: zozz.SamplingJob = .{ .animation = f.animation, .context = f.sampling, .ratio = f.ratios[i % f.ratios.len], .out = f.sampled };
            job.run(&failure) catch return error.Failed;
            sum += f.sampled[0].translation.x[0];
        }
        std.mem.doNotOptimizeAway(sum);
    }

    fn sampleC(f: *Frames, n: u64) Failed!void {
        var sum: f32 = 0;
        if (!baseline.zozz_baseline_sample(f.world, f.ratios.ptr, f.ratios.len, f.sampled.ptr, f.sampled.len, n, &sum)) return error.Failed;
        std.mem.doNotOptimizeAway(sum);
    }

    fn localToModelZig(f: *Frames, n: u64) Failed!void {
        var failure: zozz.Failure = .{};
        const job: zozz.LocalToModelJob = .{ .skeleton = f.skeleton, .locals = f.locals, .out = f.models };
        var sum: f32 = 0;
        for (0..n) |_| {
            job.run(&failure) catch return error.Failed;
            sum += f.models[f.models.len - 1].m[12];
        }
        std.mem.doNotOptimizeAway(sum);
    }

    fn localToModelC(f: *Frames, n: u64) Failed!void {
        var sum: f32 = 0;
        if (!baseline.zozz_baseline_local_to_model(f.world, f.locals.ptr, f.locals.len, f.models.ptr, n, &sum)) return error.Failed;
        std.mem.doNotOptimizeAway(sum);
    }

    fn blendZig(f: *Frames, n: u64) Failed!void {
        var failure: zozz.Failure = .{};
        const job: zozz.BlendingJob = .{ .layers = f.layers, .rest_pose = f.rest, .out = f.blended };
        var sum: f32 = 0;
        for (0..n) |_| {
            job.run(&failure) catch return error.Failed;
            sum += f.blended[0].rotation.w[0];
        }
        std.mem.doNotOptimizeAway(sum);
    }

    fn blendC(f: *Frames, n: u64) Failed!void {
        var sum: f32 = 0;
        if (!baseline.zozz_baseline_blend(f.poses.ptr, &layer_weights, f.poses.len, f.rest.ptr, f.blended.ptr, f.blended.len, n, &sum)) return error.Failed;
        std.mem.doNotOptimizeAway(sum);
    }

    fn skinZig(f: *Frames, n: u64) Failed!void {
        var failure: zozz.Failure = .{};
        const stride = 3 * @sizeOf(f32);
        const job: zozz.skinning.Job = .{
            .vertex_count = vertex_count,
            .influences_count = influences,
            .joint_matrices = f.palette,
            .joint_indices = f.mesh.indices,
            .joint_indices_stride = influences * @sizeOf(u16),
            .joint_weights = f.mesh.weights,
            .joint_weights_stride = (influences - 1) * @sizeOf(f32),
            .in_positions = .{ .data = f.mesh.positions, .stride = stride },
            .in_normals = .{ .data = f.mesh.normals, .stride = stride },
            .out_positions = .{ .data = f.mesh.out_positions, .stride = stride },
            .out_normals = .{ .data = f.mesh.out_normals, .stride = stride },
        };
        var sum: f32 = 0;
        for (0..n) |_| {
            job.run(&failure) catch return error.Failed;
            sum += f.mesh.out_positions[0];
        }
        std.mem.doNotOptimizeAway(sum);
    }

    fn skinC(f: *Frames, n: u64) Failed!void {
        const m = &f.mesh;
        var sum: f32 = 0;
        if (!baseline.zozz_baseline_skin(f.palette.ptr, f.palette.len, m.indices.ptr, m.weights.ptr, m.positions.ptr, m.normals.ptr, m.out_positions.ptr, m.out_normals.ptr, vertex_count, influences, n, &sum)) return error.Failed;
        std.mem.doNotOptimizeAway(sum);
    }

    fn twoBoneZig(f: *Frames, n: u64) Failed!void {
        var failure: zozz.Failure = .{};
        var sum: f32 = 0;
        for (0..n) |i| {
            const job: zozz.ik.TwoBoneJob = .{ .target = f.targets[i % f.targets.len], .start_joint = f.chain[0], .mid_joint = f.chain[1], .end_joint = f.chain[2] };
            const solved = job.run(&failure) catch return error.Failed;
            sum += solved.start_joint_correction[0] + @as(f32, @floatFromInt(@intFromBool(solved.reached)));
        }
        std.mem.doNotOptimizeAway(sum);
    }

    fn twoBoneC(f: *Frames, n: u64) Failed!void {
        var sum: f32 = 0;
        if (!baseline.zozz_baseline_two_bone(f.chain[0], f.chain[1], f.chain[2], f.targets.ptr, f.targets.len, n, &sum)) return error.Failed;
        std.mem.doNotOptimizeAway(sum);
    }
};

/// The skinned mesh's buffers, three floats a vertex for positions and
/// normals, in and out.
const Mesh = struct {
    indices: []u16,
    weights: []f32,
    positions: []f32,
    normals: []f32,
    out_positions: []f32,
    out_normals: []f32,

    /// A flat grid facing +z, every vertex weighted by joints spread over the
    /// whole skeleton.
    fn init(a: std.mem.Allocator, joints: u32) !Mesh {
        const mesh: Mesh = .{
            .indices = try a.alloc(u16, vertex_count * influences),
            .weights = try a.alloc(f32, vertex_count * (influences - 1)),
            .positions = try a.alloc(f32, vertex_count * 3),
            .normals = try a.alloc(f32, vertex_count * 3),
            .out_positions = try a.alloc(f32, vertex_count * 3),
            .out_normals = try a.alloc(f32, vertex_count * 3),
        };
        for (0..vertex_count) |v| {
            for (0..influences) |k| mesh.indices[v * influences + k] = @intCast((v * 7 + k * 13) % joints);
            @memcpy(mesh.weights[v * (influences - 1) ..][0 .. influences - 1], &influence_weights);
            const x: f32 = @floatFromInt(v % mesh_side);
            const y: f32 = @floatFromInt(v / mesh_side);
            @memcpy(mesh.positions[v * 3 ..][0..3], &[3]f32{ x * 0.01 - 0.32, y * 0.027, 0.05 });
            @memcpy(mesh.normals[v * 3 ..][0..3], &[3]f32{ 0, 0, 1 });
        }
        return mesh;
    }
};

/// A growable in-memory sink an `OArchive` writes to.
const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn opened(_: ?*anyopaque) callconv(.c) c_int {
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const sink: *Sink = @ptrCast(@alignCast(user orelse return 0));
        const from: [*]const u8 = @ptrCast(data orelse return 0);
        sink.bytes.appendSlice(sink.gpa, from[0..size]) catch return 0;
        return size;
    }

    fn stream(sink: *Sink) zozz.Stream {
        return .{ .opened = &opened, .write = &write, .read = null, .seek = null, .tell = null, .user = sink };
    }
};

/// The archive images both sides load, owned by the caller.
const Images = struct { skeleton: []u8, animation: []u8 };

fn at(translation: [3]f32) zozz.Transform {
    var rest = zozz.transform_identity;
    rest.translation = translation;
    return rest;
}

/// Appends `count` joints named `prefix_0` onwards under `parent`, the first
/// at `first` from it and each next at `step`; the last joint's index.
fn chain(raw: zozz.RawSkeleton, parent: u32, prefix: []const u8, count: u32, first: [3]f32, step: [3]f32, failure: *zozz.Failure) !u32 {
    var name: [32]u8 = undefined;
    var joint = parent;
    for (0..count) |i| {
        const label = try std.mem.printSentinel(&name, "{s}_{d}", .{ prefix, i }, 0);
        joint = try raw.addJoint(joint, label, at(if (i == 0) first else step), failure);
    }
    return joint;
}

/// The skeleton and clip, built and serialised. Every ozz object made here is
/// destroyed before it returns, so the load rows start with none alive.
fn author(gpa: std.mem.Allocator, failure: *zozz.Failure) !Images {
    var raw = try zozz.RawSkeleton.init(failure);
    defer raw.deinit();
    const root = try raw.addJoint(null, "root", at(.{ 0, 1, 0 }), failure);
    const chest = try chain(raw, root, "spine", spine_joints, .{ 0, 0.12, 0 }, .{ 0, 0.12, 0 }, failure);
    _ = try chain(raw, chest, "neck", neck_joints, .{ 0, 0.1, 0 }, .{ 0, 0.1, 0 }, failure);
    for ([_]f32{ 1, -1 }, [_][]const u8{ "l", "r" }) |side, label| {
        var prefix: [32]u8 = undefined;
        const hand = try chain(raw, chest, try std.fmt.bufPrint(&prefix, "arm_{s}", .{label}), arm_joints, .{ side * 0.1, 0, 0 }, .{ side * 0.27, 0, 0 }, failure);
        for (0..finger_count) |finger| {
            const spread: f32 = @floatFromInt(finger);
            _ = try chain(raw, hand, try std.fmt.bufPrint(&prefix, "finger_{s}_{d}", .{ label, finger }), finger_joints, .{ side * 0.08, 0, (spread - 2) * 0.02 }, .{ side * 0.03, 0, 0 }, failure);
        }
        _ = try chain(raw, root, try std.fmt.bufPrint(&prefix, "leg_{s}", .{label}), leg_joints, .{ side * 0.1, -0.05, 0 }, .{ 0, -0.22, 0 }, failure);
    }
    var skeleton = try raw.build(failure);
    defer skeleton.deinit();

    // Track i drives the built skeleton's joint i, so its rest translation is
    // the skeleton's, read back in that order.
    const joints = skeleton.numJoints();
    const rest = try gpa.alloc(zozz.Transform, joints);
    defer gpa.free(rest);
    try skeleton.restPose(rest, failure);
    var clip = try zozz.RawAnimation.init(joints, clip_seconds, "walk", failure);
    defer clip.deinit();
    for (rest, 0..) |joint, track_index| {
        const track: u32 = @intCast(track_index);
        try clip.pushScale(track, 0, .{ 1, 1, 1 }, failure);
        if (track != 0) try clip.pushTranslation(track, 0, joint.translation, failure);
        const phase: f32 = @as(f32, @floatFromInt(track)) * 0.7;
        for (0..clip_seconds * keys_per_second + 1) |key| {
            const time = @as(f32, @floatFromInt(key)) / keys_per_second;
            if (track == 0) try clip.pushTranslation(track, time, .{ 0, 1 + 0.03 * @sin(time * 6), time * 1.2 }, failure);
            const half = 0.2 * @sin(std.math.tau * swings * time / clip_seconds + phase);
            var rotation: [4]f32 = .{ 0, 0, 0, @cos(half) };
            rotation[track % 3] = @sin(half);
            try clip.pushRotation(track, time, rotation, failure);
        }
    }
    var animation = try clip.build(0, failure); // no iframes: AnimationBuilder's default
    defer animation.deinit();

    const skeleton_image = try serialise(gpa, skeleton, failure);
    errdefer gpa.free(skeleton_image);
    return .{ .skeleton = skeleton_image, .animation = try serialise(gpa, animation, failure) };
}

/// One object's archive image, owned by the caller.
fn serialise(gpa: std.mem.Allocator, object: anytype, failure: *zozz.Failure) ![]u8 {
    var sink: Sink = .{ .gpa = gpa };
    errdefer sink.bytes.deinit(gpa);
    const bridge = sink.stream();
    {
        var archive = try zozz.OArchive.init(&bridge, zozz.nativeEndianness(), failure);
        defer archive.deinit();
        switch (@TypeOf(object)) {
            zozz.Skeleton => try archive.saveSkeleton(object, failure),
            zozz.Animation => try archive.saveAnimation(object, failure),
            else => @compileError("serialise takes a skeleton or an animation"),
        }
    }
    return sink.bytes.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    var failure: zozz.Failure = .{};
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try shakedown.bench.Options.fromArguments(args[1..]);
    const metadata: shakedown.bench.Metadata = .{ .commit = provenance.commit };
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    const images = try author(gpa, &failure);
    defer gpa.free(images.skeleton);
    defer gpa.free(images.animation);

    var loads: Loads = .{ .gpa = gpa, .skeleton = images.skeleton, .animation = images.animation };
    const LoadRow = shakedown.bench.Row(Loads, Failed);
    const through_gpa: LoadRow.Fixture = .{ .lifetime = .row, .setup = Loads.installAllocator, .teardown = Loads.removeAllocator };
    const load_rows = [_]LoadRow{
        .{ .name = "load_skeleton_zig", .unit = "skeleton", .run = Loads.skeletonZig },
        .{ .name = "load_skeleton_zig_allocator", .unit = "skeleton", .run = Loads.skeletonZig, .fixture = through_gpa },
        .{ .name = "load_skeleton_c", .unit = "skeleton", .run = Loads.skeletonC },
        .{ .name = "load_animation_zig", .unit = "clip", .run = Loads.animationZig },
        .{ .name = "load_animation_zig_allocator", .unit = "clip", .run = Loads.animationZig, .fixture = through_gpa },
        .{ .name = "load_animation_c", .unit = "clip", .run = Loads.animationC },
    };
    try shakedown.bench.run(Failed, gpa, init.io, &stdout.interface, &loads, &load_rows, metadata, options);

    var skeleton = try zozz.Skeleton.initFromMemory(.init(images.skeleton), &failure);
    defer skeleton.deinit();
    var animation = try zozz.Animation.initFromMemory(.init(images.animation), &failure);
    defer animation.deinit();
    var sampling = try zozz.SamplingContext.initForSkeleton(skeleton, &failure);
    defer sampling.deinit();
    const world = baseline.zozz_baseline_open(images.skeleton.ptr, images.skeleton.len, images.animation.ptr, images.animation.len) orelse return error.BaselineOpen;
    defer baseline.zozz_baseline_close(world);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const joints = skeleton.numJoints();
    const blocks = try zozz.soaBlocks(joints, &failure);

    const ratios = try a.alloc(f32, frame_count);
    for (ratios, 0..) |*ratio, i| ratio.* = @as(f32, @floatFromInt(i)) / frame_count;
    const sampled = try a.alloc(zozz.SoaTransform, blocks);
    try skeleton.restPoseSoa(sampled, &failure);
    const rest = try a.alloc(zozz.SoaTransform, blocks);
    try skeleton.restPoseSoa(rest, &failure);
    const blended = try a.alloc(zozz.SoaTransform, blocks);
    var layers: [layer_ratios.len]zozz.BlendingLayer = undefined;
    var poses: [layer_ratios.len][*]const zozz.SoaTransform = undefined;
    for (layer_ratios, layer_weights, &layers, &poses) |ratio, weight, *layer, *pose| {
        const out = try a.alloc(zozz.SoaTransform, blocks);
        try (zozz.SamplingJob{ .animation = animation, .context = sampling, .ratio = ratio, .out = out }).run(&failure);
        layer.* = zozz.blending.layer(weight, out);
        pose.* = out.ptr;
    }
    const locals = poses[0][0..blocks];
    const models = try a.alloc(zozz.Mat4, joints);
    try (zozz.LocalToModelJob{ .skeleton = skeleton, .locals = locals, .out = models }).run(&failure);
    const palette = try a.dupe(zozz.Mat4, models);

    var links: [chain_names.len]*const zozz.Mat4 = undefined;
    for (chain_names, &links) |name, *link| link.* = &palette[zozz.findJoint(skeleton, name) orelse return error.NoArm];
    const wrist = links[2].m[12..15].*;
    const targets = try a.alloc(zozz.ik.Vec4, target_side * target_side);
    for (targets, 0..) |*target, i| {
        const u: f32 = @floatFromInt(i % target_side);
        const v: f32 = @floatFromInt(i / target_side);
        target.* = .{ wrist[0] + (u - 1.5) * 0.25, wrist[1] + (v - 1.5) * 0.25, wrist[2] + 0.15, 0 };
    }

    var frames: Frames = .{
        .skeleton = skeleton,
        .animation = animation,
        .sampling = sampling,
        .world = world,
        .ratios = ratios,
        .sampled = sampled,
        .locals = locals,
        .models = models,
        .layers = &layers,
        .poses = &poses,
        .rest = rest,
        .blended = blended,
        .palette = palette,
        .mesh = try Mesh.init(a, joints),
        .chain = links,
        .targets = targets,
    };
    const FrameRow = shakedown.bench.Row(Frames, Failed);
    const frame_rows = [_]FrameRow{
        .{ .name = "sample_zig", .unit = "sample", .initial = 10, .run = Frames.sampleZig },
        .{ .name = "sample_c", .unit = "sample", .initial = 10, .run = Frames.sampleC },
        .{ .name = "local_to_model_zig", .unit = "pose", .initial = 10, .run = Frames.localToModelZig },
        .{ .name = "local_to_model_c", .unit = "pose", .initial = 10, .run = Frames.localToModelC },
        .{ .name = "blend_zig", .unit = "blend", .initial = 10, .run = Frames.blendZig },
        .{ .name = "blend_c", .unit = "blend", .initial = 10, .run = Frames.blendC },
        .{ .name = "skin_zig", .unit = "mesh", .run = Frames.skinZig },
        .{ .name = "skin_c", .unit = "mesh", .run = Frames.skinC },
        .{ .name = "two_bone_ik_zig", .unit = "solve", .initial = 100, .run = Frames.twoBoneZig },
        .{ .name = "two_bone_ik_c", .unit = "solve", .initial = 100, .run = Frames.twoBoneC },
    };
    try shakedown.bench.run(Failed, gpa, init.io, &stdout.interface, &frames, &frame_rows, metadata, options);
    try stdout.interface.flush();
}
