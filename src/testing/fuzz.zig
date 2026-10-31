//! Properties over every parser of a host's bytes: each loader of an `.ozz`
//! archive, from memory, from a file and through a host's stream, and the
//! group-varint decoders. A case is a seed mutated, or bytes of its own, in a block that
//! ends at an inaccessible page, so a read past the bytes faults where it
//! happens. ozz's own blocks come from the same quarantine. What loads runs
//! the jobs a host runs on it; what is refused names the call that refused
//! it. Under the fuzzer the same properties are its targets.

const std = @import("std");
const shakedown = @import("shakedown");
const zozz = @import("../zozz.zig");
const quiet = @import("quiet.zig");

extern fn zozzFixtureSkeleton(out_data: *?*anyopaque, out_size: *usize) zozz.c.Result;
extern fn zozzFixtureAnimation(out_data: *?*anyopaque, out_size: *usize) zozz.c.Result;
extern fn zozzFixtureFree(data: ?*anyopaque) void;

const Allocator = std.mem.Allocator;

/// What a property draws from: the seeds of its kind, and the quarantine
/// every block of the case comes from.
const Context = struct {
    seeds: []const []const u8,
    guarded: Allocator,
    /// Where a loader's case is written to be loaded from a file.
    file: ?CaseFile = null,

    /// The directory the Zig API loads the case from, as `case_file`, and
    /// the same file's path for the C ABI's file loaders.
    const CaseFile = struct { dir: std.Io.Dir, path: [:0]const u8 };

    /// The case's bytes, ending at a guard page. Free with `guarded`.
    fn input(ctx: *const Context, case: *shakedown.Case) ![]u8 {
        var longest: usize = 0;
        for (ctx.seeds) |seed| longest = @max(longest, seed.len);
        // A mutation adds at most eight bytes to a seed.
        const drawn = shakedown.gen.mutated(case.source, try case.gpa.alloc(u8, longest + 8), ctx.seeds);
        return ctx.guarded.dupe(u8, drawn);
    }
};

/// One test's quarantine, which zozz and its properties both allocate from,
/// the scratch directory each case is written to for a file load, and ozz's
/// log silenced.
/// Begun in place: the allocator zozz holds points into it.
const Guarded = struct {
    quarantine: shakedown.alloc.Quarantine,
    log: quiet.SilentLog,
    files: std.testing.TmpDir,
    path_buffer: [64]u8,
    path: [:0]const u8,

    fn begin(g: *Guarded) !void {
        g.quarantine = .init(.{ .guard = .after });
        errdefer g.quarantine.deinit();
        g.files = std.testing.tmpDir(.{});
        errdefer g.files.cleanup();
        // Relative to the test's working directory, as `tmpDir` makes it.
        g.path = try std.mem.printSentinel(&g.path_buffer, ".zig-cache/tmp/{s}/" ++ case_file, .{g.files.sub_path}, 0);
        var failure: zozz.Failure = .{};
        try zozz.setAllocator(g.quarantine.allocator(), &failure);
        // Most cases are refused: each refusal is asserted by its frame.
        g.log = .begin();
    }

    fn end(g: *Guarded) void {
        g.log.end();
        var failure: zozz.Failure = .{};
        zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});
        g.files.cleanup();
        g.quarantine.deinit();
    }

    fn over(g: *Guarded, seeds: []const []const u8) Context {
        return .{
            .seeds = seeds,
            .guarded = g.quarantine.allocator(),
            .file = .{ .dir = g.files.dir, .path = g.path },
        };
    }
};

/// The name a loader's case is written under in `Context.file`.
const case_file = "case.ozz";

const loader_cases: shakedown.CheckOptions = .{ .cases = 512 };

/// A refused call must say which call refused: a refusal with no frame is
/// a silent one.
fn expectNamed(failure: *zozz.Failure) !void {
    if (failure.frames().len == 0) return error.RefusedWithoutAFrame;
}

/// A host's stream over bytes it holds, read once from the start.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn read(user: ?*anyopaque, buffer: ?*anyopaque, size: usize) callconv(.c) usize {
        const self: *Reader = @ptrCast(@alignCast(user orelse return 0));
        const out: [*]u8 = @ptrCast(buffer orelse return 0);
        const n = @min(self.bytes.len - self.at, size);
        @memcpy(out[0..n], self.bytes[self.at..][0..n]);
        self.at += n;
        return n;
    }

    fn seek(user: ?*anyopaque, offset: c_int, origin: zozz.SeekOrigin) callconv(.c) c_int {
        const self: *Reader = @ptrCast(@alignCast(user orelse return -1));
        const base: i64 = switch (origin) {
            .current => @intCast(self.at),
            .end => @intCast(self.bytes.len),
            .set => 0,
        };
        const target = base + offset;
        if (target < 0 or target > @as(i64, @intCast(self.bytes.len))) return -1;
        self.at = @intCast(target);
        return 0;
    }

    fn tell(user: ?*anyopaque) callconv(.c) c_int {
        const self: *Reader = @ptrCast(@alignCast(user orelse return -1));
        return @intCast(self.at);
    }

    fn stream(self: *Reader) zozz.Stream {
        return .{ .opened = &opened, .write = null, .read = &read, .seek = &seek, .tell = &tell, .user = self };
    }
};

/// A host's sink the seeds are saved into.
const Writer = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn opened(user: ?*anyopaque) callconv(.c) c_int {
        _ = user;
        return 1;
    }

    fn write(user: ?*anyopaque, data: ?*const anyopaque, size: usize) callconv(.c) usize {
        const self: *Writer = @ptrCast(@alignCast(user orelse return 0));
        const bytes: [*]const u8 = @ptrCast(data orelse return 0);
        self.list.appendSlice(self.gpa, bytes[0..size]) catch return 0;
        return size;
    }

    fn stream(self: *Writer) zozz.Stream {
        return .{ .opened = &opened, .write = &write, .read = null, .seek = null, .tell = null, .user = self };
    }
};

/// One loader's property: the bytes loaded from memory, from a file through
/// the Zig API and through the C ABI's file loader, and through a host's
/// stream by `load`, each object handed to `run`, which drives what a host
/// drives on it and frees it.
fn Loads(comptime T: type, comptime load: fn (zozz.IArchive, *zozz.Failure) zozz.Error!T, comptime run: fn (T, Allocator) anyerror!void) type {
    return struct {
        fn property(ctx: *const Context, case: *shakedown.Case) !void {
            const bytes = try ctx.input(case);
            defer ctx.guarded.free(bytes);
            var failure: zozz.Failure = .{};
            if (T.initFromMemory(.init(bytes), &failure)) |object| {
                try run(object, ctx.guarded);
            } else |_| try expectNamed(&failure);

            const file = ctx.file.?;
            try file.dir.writeFile(std.testing.io, .{ .sub_path = case_file, .data = bytes });
            failure = .{};
            if (T.initFromFile(ctx.guarded, std.testing.io, file.dir, case_file, .fromRaw(1 << 20), &failure)) |object| {
                try run(object, ctx.guarded);
            } else |_| try expectNamed(&failure);

            // A C host's file load, through `ozz::io::File`.
            const Handle = @typeInfo(@typeInfo(@FieldType(T, "handle")).optional.child).pointer.child;
            const handle_name = @typeName(Handle);
            const loadFile = @field(zozz.c, "zozz" ++ handle_name[(std.mem.findScalarLast(u8, handle_name, '.') orelse 0) + 1 ..] ++ "LoadFile");
            var handle: *Handle = undefined;
            var refusal: zozz.c.Refusal = .{};
            const result = loadFile(file.path, &handle, &refusal);
            if (result == .ok) {
                try run(.{ .handle = handle }, ctx.guarded);
            } else if (refusal.what != null and result != .bad_format and result != .io) return error.RecordBesideOtherResult;

            var reader: Reader = .{ .bytes = bytes };
            const host = reader.stream();
            failure = .{};
            var archive = zozz.IArchive.init(.init(&host), &failure) catch return expectNamed(&failure);
            defer archive.deinit();
            if (load(archive, &failure)) |object| {
                try run(object, ctx.guarded);
            } else |_| try expectNamed(&failure);
        }
    };
}

/// Places every joint in model space.
fn placeJoints(loaded: zozz.Skeleton, a: Allocator) !void {
    var skeleton = loaded;
    defer skeleton.deinit();
    var failure: zozz.Failure = .{};
    const locals = try a.alloc(zozz.SoaTransform, skeleton.numSoaJoints());
    defer a.free(locals);
    const out = try a.alloc(zozz.Mat4, skeleton.numJoints());
    defer a.free(out);
    try skeleton.restPoseSoa(locals, &failure);
    try (zozz.LocalToModelJob{ .skeleton = skeleton, .locals = locals, .out = out }).run(&failure);
}

/// Samples forward, back, and far enough each way to seek an iframe.
fn sampleClip(loaded: zozz.Animation, a: Allocator) !void {
    var animation = loaded;
    defer animation.deinit();
    var failure: zozz.Failure = .{};
    var context = try zozz.SamplingContext.init(animation.numTracks(), &failure);
    defer context.deinit();
    const pose = try a.alloc(zozz.SoaTransform, animation.numSoaTracks());
    defer a.free(pose);
    for ([_]f32{ 0.0, 0.95, 0.1, 0.3, 1.0, 0.6 }) |ratio| {
        try (zozz.SamplingJob{ .animation = animation, .context = context, .ratio = ratio, .out = pose }).run(&failure);
    }
}

/// Samples, and walks the edges of a range that loops over the track.
fn triggerTrack(loaded: zozz.FloatTrack, a: Allocator) !void {
    _ = a;
    var track = loaded;
    defer track.deinit();
    var failure: zozz.Failure = .{};
    for ([_]f32{ 0.0, 0.25, 0.6, 1.0 }) |ratio| _ = try track.sample(ratio, &failure);
    var edges: zozz.TrackTriggering = undefined;
    try edges.run(track, -1, 2, 0.5, &failure);
    while (edges.valid()) : (try edges.next(&failure)) _ = try edges.get(&failure);
}

fn sampleTrack(comptime T: type) fn (T, Allocator) anyerror!void {
    return struct {
        fn run(loaded: T, a: Allocator) !void {
            _ = a;
            var track = loaded;
            defer track.deinit();
            var failure: zozz.Failure = .{};
            for ([_]f32{ 0.0, 0.25, 0.6, 1.0 }) |ratio| _ = try track.sample(ratio, &failure);
        }
    }.run;
}

/// A raw object is the builder's input: what it builds runs as a loaded one
/// does, and what it refuses names the call.
fn builds(comptime Raw: type, comptime run: anytype) fn (Raw, Allocator) anyerror!void {
    return struct {
        fn go(loaded: Raw, a: Allocator) !void {
            var raw = loaded;
            defer raw.deinit();
            var failure: zozz.Failure = .{};
            const built = if (Raw == zozz.RawAnimation) raw.build(0.5, &failure) else raw.build(&failure);
            if (built) |object| try run(object, a) else |_| try expectNamed(&failure);
        }
    }.go;
}

const Seeds = struct {
    gpa: Allocator,
    skeletons: [2][]u8,
    animations: [3][]u8,
    float_tracks: [2][]u8,
    float2_tracks: [2][]u8,
    float3_tracks: [2][]u8,
    float4_tracks: [2][]u8,
    quaternion_tracks: [2][]u8,

    /// Each kind saved as ozz saves it, runtime and raw: the fixture's
    /// skeleton and animation, an animation with iframes, and a track of
    /// each value type with a step key among linear ones.
    fn init(gpa: Allocator) !Seeds {
        var failure: zozz.Failure = .{};
        try zozz.setAllocator(gpa, &failure);
        defer zozz.resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});
        var seeds: Seeds = undefined;
        seeds.gpa = gpa;

        seeds.skeletons[0] = try fixture(gpa, zozzFixtureSkeleton);
        var raw_skeleton = try zozz.RawSkeleton.init(&failure);
        defer raw_skeleton.deinit();
        const rest = zozz.transform_identity;
        const root = try raw_skeleton.addJoint(null, "root", rest, &failure);
        const spine = try raw_skeleton.addJoint(root, "spine", rest, &failure);
        _ = try raw_skeleton.addJoint(spine, "head", rest, &failure);
        _ = try raw_skeleton.addJoint(root, "leg", rest, &failure);
        seeds.skeletons[1] = try saved(gpa, "saveRawSkeleton", raw_skeleton);

        seeds.animations[0] = try fixture(gpa, zozzFixtureAnimation);
        var raw_animation = try zozz.RawAnimation.init(2, 4.0, "clip", &failure);
        defer raw_animation.deinit();
        for (0..17) |k| {
            const time = @as(f32, @floatFromInt(k)) / 4.0;
            const value: f32 = @floatFromInt(k % 5);
            for (0..2) |track| try raw_animation.pushTranslation(@intCast(track), time, .{ value, 0, 0 }, &failure);
        }
        var clip = try raw_animation.build(0.5, &failure);
        defer clip.deinit();
        seeds.animations[1] = try saved(gpa, "saveAnimation", clip);
        seeds.animations[2] = try saved(gpa, "saveRawAnimation", raw_animation);

        seeds.float_tracks = try trackSeeds(gpa, zozz.RawFloatTrack, f32, "saveFloatTrack", "saveRawFloatTrack");
        seeds.float2_tracks = try trackSeeds(gpa, zozz.RawFloat2Track, [2]f32, "saveFloat2Track", "saveRawFloat2Track");
        seeds.float3_tracks = try trackSeeds(gpa, zozz.RawFloat3Track, [3]f32, "saveFloat3Track", "saveRawFloat3Track");
        seeds.float4_tracks = try trackSeeds(gpa, zozz.RawFloat4Track, [4]f32, "saveFloat4Track", "saveRawFloat4Track");
        seeds.quaternion_tracks = try trackSeeds(gpa, zozz.RawQuaternionTrack, [4]f32, "saveQuaternionTrack", "saveRawQuaternionTrack");
        return seeds;
    }

    fn deinit(seeds: *Seeds) void {
        const all = [_][]const []u8{ &seeds.skeletons, &seeds.animations, &seeds.float_tracks, &seeds.float2_tracks, &seeds.float3_tracks, &seeds.float4_tracks, &seeds.quaternion_tracks };
        for (all) |kind| for (kind) |seed| seeds.gpa.free(seed);
    }

    fn fixture(gpa: Allocator, make: *const fn (*?*anyopaque, *usize) callconv(.c) zozz.c.Result) ![]u8 {
        var data: ?*anyopaque = null;
        var size: usize = 0;
        if (make(&data, &size) != .ok) return error.FixtureFailed;
        defer zozzFixtureFree(data);
        const bytes: [*]const u8 = @ptrCast(data orelse return error.FixtureFailed);
        return gpa.dupe(u8, bytes[0..size]);
    }

    fn saved(gpa: Allocator, comptime save: []const u8, object: anytype) ![]u8 {
        var failure: zozz.Failure = .{};
        var sink: Writer = .{ .gpa = gpa };
        errdefer sink.list.deinit(gpa);
        const host = sink.stream();
        var archive = try zozz.OArchive.init(&host, zozz.nativeEndianness(), &failure);
        defer archive.deinit();
        try @field(zozz.OArchive, save)(archive, object, &failure);
        return sink.list.toOwnedSlice(gpa);
    }

    /// The track built, then raw: keys at 0, .3 (a step), .5, .7 and 1.
    fn trackSeeds(gpa: Allocator, comptime Raw: type, comptime Value: type, comptime save: []const u8, comptime save_raw: []const u8) ![2][]u8 {
        var failure: zozz.Failure = .{};
        var raw = try Raw.init(&failure);
        defer raw.deinit();
        const keys = [_]struct { zozz.TrackInterpolation, f32 }{ .{ .linear, 0 }, .{ .step, 0.3 }, .{ .linear, 0.5 }, .{ .linear, 0.7 }, .{ .linear, 1 } };
        for (keys, 0..) |key, i| {
            const value: Value = if (Value == f32) @floatFromInt(i) else if (Raw == zozz.RawQuaternionTrack) .{ 0, 0, 0, 1 } else @splat(@floatFromInt(i));
            try raw.pushKeyframe(key[0], key[1], value, &failure);
        }
        var built = try raw.build(&failure);
        defer built.deinit();
        const runtime = try saved(gpa, save, built);
        errdefer gpa.free(runtime);
        return .{ runtime, try saved(gpa, save_raw, raw) };
    }
};

test "any bytes as a skeleton archive, runtime or raw" {
    var seeds: Seeds = try .init(std.testing.allocator);
    defer seeds.deinit();
    var guarded: Guarded = undefined;
    try guarded.begin();
    defer guarded.end();
    const ctx = guarded.over(&seeds.skeletons);
    try shakedown.check(std.testing.allocator, &ctx, Loads(zozz.Skeleton, zozz.IArchive.loadSkeleton, placeJoints).property, loader_cases);
    try shakedown.check(std.testing.allocator, &ctx, Loads(zozz.RawSkeleton, zozz.IArchive.loadRawSkeleton, builds(zozz.RawSkeleton, placeJoints)).property, loader_cases);
}

test "any bytes as an animation archive, runtime or raw" {
    var seeds: Seeds = try .init(std.testing.allocator);
    defer seeds.deinit();
    var guarded: Guarded = undefined;
    try guarded.begin();
    defer guarded.end();
    const ctx = guarded.over(&seeds.animations);
    try shakedown.check(std.testing.allocator, &ctx, Loads(zozz.Animation, zozz.IArchive.loadAnimation, sampleClip).property, loader_cases);
    try shakedown.check(std.testing.allocator, &ctx, Loads(zozz.RawAnimation, zozz.IArchive.loadRawAnimation, builds(zozz.RawAnimation, sampleClip)).property, loader_cases);
}

test "any bytes as a track archive of each value type, runtime or raw" {
    var seeds: Seeds = try .init(std.testing.allocator);
    defer seeds.deinit();
    var guarded: Guarded = undefined;
    try guarded.begin();
    defer guarded.end();
    const floats = guarded.over(&seeds.float_tracks);
    try shakedown.check(std.testing.allocator, &floats, Loads(zozz.FloatTrack, zozz.IArchive.loadFloatTrack, triggerTrack).property, loader_cases);
    try shakedown.check(std.testing.allocator, &floats, Loads(zozz.RawFloatTrack, zozz.IArchive.loadRawFloatTrack, builds(zozz.RawFloatTrack, triggerTrack)).property, loader_cases);
    inline for (.{
        .{ zozz.Float2Track, zozz.IArchive.loadFloat2Track, zozz.RawFloat2Track, zozz.IArchive.loadRawFloat2Track, &seeds.float2_tracks },
        .{ zozz.Float3Track, zozz.IArchive.loadFloat3Track, zozz.RawFloat3Track, zozz.IArchive.loadRawFloat3Track, &seeds.float3_tracks },
        .{ zozz.Float4Track, zozz.IArchive.loadFloat4Track, zozz.RawFloat4Track, zozz.IArchive.loadRawFloat4Track, &seeds.float4_tracks },
        .{ zozz.QuaternionTrack, zozz.IArchive.loadQuaternionTrack, zozz.RawQuaternionTrack, zozz.IArchive.loadRawQuaternionTrack, &seeds.quaternion_tracks },
    }) |kind| {
        const ctx = guarded.over(kind[4]);
        try shakedown.check(std.testing.allocator, &ctx, Loads(kind[0], kind[1], sampleTrack(kind[0])).property, loader_cases);
        try shakedown.check(std.testing.allocator, &ctx, Loads(kind[2], kind[3], builds(kind[2], sampleTrack(kind[0]))).property, loader_cases);
    }
}

/// What a decode consumed is within the bytes, and the values it gave
/// encode and decode back to themselves.
fn decodesWithin(ctx: *const Context, case: *shakedown.Case) !void {
    const bytes = try ctx.input(case);
    defer ctx.guarded.free(bytes);
    var failure: zozz.Failure = .{};
    var group: [4]u32 = undefined;
    if (zozz.encode.decodeGV4(.init(bytes), &group, &failure)) |consumed| {
        if (consumed > bytes.len) return error.ConsumedPastTheBytes;
        var again: [17]u8 = undefined;
        const used = try zozz.encode.encodeGV4(group, &again, &failure);
        var back: [4]u32 = undefined;
        _ = try zozz.encode.decodeGV4(.init(again[0..used]), &back, &failure);
        try std.testing.expectEqual(group, back);
    } else |_| try expectNamed(&failure);

    const values = try ctx.guarded.alloc(u32, shakedown.gen.intRange(case.source, usize, 0, 4) * 4);
    defer ctx.guarded.free(values);
    failure = .{};
    if (zozz.encode.decodeGV4Stream(.init(bytes), values, &failure)) |consumed| {
        if (consumed > bytes.len) return error.ConsumedPastTheBytes;
        const again = try ctx.guarded.alloc(u8, try zozz.encode.computeGV4WorstBufferSize(values.len, &failure));
        defer ctx.guarded.free(again);
        const used = try zozz.encode.encodeGV4Stream(values, again, &failure);
        const back = try ctx.guarded.alloc(u32, values.len);
        defer ctx.guarded.free(back);
        _ = try zozz.encode.decodeGV4Stream(.init(again[0..used]), back, &failure);
        try std.testing.expectEqualSlices(u32, values, back);
    } else |_| try expectNamed(&failure);
}

test "any bytes as group varints, one group or a stream" {
    // Seeds as the encoder writes them: a group of one-byte values, one
    // of every width, and a stream of three groups.
    var failure: zozz.Failure = .{};
    var narrow: [17]u8 = undefined;
    var wide: [17]u8 = undefined;
    var stream: [51]u8 = undefined;
    const values = [_]u32{ 1, 2, 3, 4, 1, 300, 70000, 1 << 24, 0, 0, 1 << 31, 5 };
    const seeds = [_][]const u8{
        narrow[0..try zozz.encode.encodeGV4(values[0..4].*, &narrow, &failure)],
        wide[0..try zozz.encode.encodeGV4(values[4..8].*, &wide, &failure)],
        stream[0..try zozz.encode.encodeGV4Stream(&values, &stream, &failure)],
    };
    var quarantine: shakedown.alloc.Quarantine = .init(.{ .guard = .after });
    defer quarantine.deinit();
    const ctx: Context = .{ .seeds = &seeds, .guarded = quarantine.allocator() };
    try shakedown.check(std.testing.allocator, &ctx, decodesWithin, .{ .cases = 2048 });
}
