//! Files through `std.Io`: every single fault at every step of a file load
//! and a file save, each `std.Io` call failed, cut short or canceled once and
//! each allocation refused once. Every run loads or saves whole, or is refused
//! with an error of zozz's set and a frame naming the call, and frees
//! everything it allocated. And every loader and saver of the Zig API reads
//! and writes through the `Io` it is given, not through C stdio, and every
//! loader refuses a file over the limit it is given.

const std = @import("std");
const shakedown = @import("shakedown");
const zozz = @import("../zozz.zig");
const quiet = @import("quiet.zig");

extern fn zozzFixtureSkeleton(out_data: *?*anyopaque, out_size: *usize) zozz.c.Result;
extern fn zozzFixtureAnimation(out_data: *?*anyopaque, out_size: *usize) zozz.c.Result;
extern fn zozzFixtureFree(data: ?*anyopaque) void;

/// The fixture skeleton's joint count (tests/fixture.cpp).
const fixture_joints = 4;

/// The fixture skeleton as a `.ozz` image, from `gpa`.
fn fixtureSkeleton(gpa: std.mem.Allocator) ![]u8 {
    return fixture(gpa, &zozzFixtureSkeleton);
}

/// A fixture's `.ozz` image, from `gpa`.
fn fixture(gpa: std.mem.Allocator, make: *const fn (*?*anyopaque, *usize) callconv(.c) zozz.c.Result) ![]u8 {
    var data: ?*anyopaque = null;
    var size: usize = 0;
    if (make(&data, &size) != .ok) return error.FixtureFailed;
    defer zozzFixtureFree(data);
    const bytes: [*]const u8 = @ptrCast(data orelse return error.FixtureFailed);
    return gpa.dupe(u8, bytes[0..size]);
}

fn isZozzError(e: anyerror) bool {
    inline for (@typeInfo(zozz.Error).error_set.error_names.?) |name|
        if (e == @field(anyerror, name)) return true;
    return false;
}

/// One load of the fixture skeleton from its file, for `everyFault`. ozz's
/// own blocks come from the faulted allocator too. Every remap is refused,
/// so each run takes the same steps: whether `std.testing.allocator` shrinks
/// a block in place depends on what the process allocated before.
const Load = struct {
    dir: std.Io.Dir,
    counting: shakedown.alloc.Counting = undefined,
    no_resize: shakedown.alloc.NoResize = undefined,
    gpa: std.mem.Allocator = undefined,
    failure: zozz.Failure = .{},
    log: quiet.SilentLog = undefined,

    pub fn setUp(load: *Load, fio: *shakedown.FaultIo) !void {
        load.counting = .init(std.testing.allocator);
        load.no_resize = .init(load.counting.allocator());
        load.gpa = try fio.allocator(load.no_resize.allocator());
        load.failure = .{};
        try zozz.setAllocator(load.gpa, &load.failure);
        // A faulted read leaves ozz bytes it refuses: the frame says so.
        load.log = .begin();
    }

    pub fn run(load: *Load, io: std.Io) !void {
        var skeleton = try zozz.Skeleton.initFromFile(load.gpa, io, load.dir, "skeleton.ozz", .fromRaw(1 << 20), &load.failure);
        defer skeleton.deinit();
        if (skeleton.numJoints() != fixture_joints) return error.Misread;
    }

    pub fn check(load: *Load, io: std.Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = io;
        load.log.end();
        if (result) |_| {} else |e| {
            if (injected == null) return e;
            if (!isZozzError(e)) return e;
            if (load.failure.frames().len == 0) return error.Unframed;
        }
        var failure: zozz.Failure = .{};
        zozz.resetAllocator(&failure) catch return error.Leaked;
        if (load.counting.live_bytes != 0) return error.Leaked;
    }

    pub fn tearDown(load: *Load) void {
        _ = load;
    }
};

/// One save of the fixture skeleton over an older `skeleton.ozz`, for
/// `everyFault`.
const Save = struct {
    dir: std.Io.Dir,
    skeleton: zozz.Skeleton,
    expected: []const u8,
    failure: zozz.Failure = .{},

    const old = "the destination as it was";

    pub fn setUp(s: *Save, fio: *shakedown.FaultIo) !void {
        _ = fio;
        s.failure = .{};
        try s.dir.writeFile(std.testing.io, .{ .sub_path = "skeleton.ozz", .data = old });
    }

    pub fn run(s: *Save, io: std.Io) !void {
        try zozz.saveSkeletonToFile(s.skeleton, io, s.dir, "skeleton.ozz", &s.failure);
    }

    pub fn check(s: *Save, io: std.Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = io;
        var buffer: [1 << 12]u8 = undefined;
        const written = try s.dir.readFile(std.testing.io, "skeleton.ozz", &buffer);
        if (result) |_| {
            if (!std.mem.eql(u8, written, s.expected)) return error.Miswritten;
        } else |e| {
            if (injected == null) return e;
            if (!isZozzError(e)) return e;
            if (s.failure.frames().len == 0) return error.Unframed;
            // The old file, or the new one whole when the rename was done
            // and then reported as failed.
            if (!std.mem.eql(u8, written, old) and !std.mem.eql(u8, written, s.expected)) return error.Torn;
        }
        var it = s.dir.iterate();
        while (try it.next(std.testing.io)) |entry|
            if (!std.mem.eql(u8, entry.name, "skeleton.ozz")) return error.LeftBehind;
    }

    pub fn tearDown(s: *Save) void {
        _ = s;
    }
};

fn sweep(subject: anytype) !shakedown.EveryFaultReport {
    var diagnostics: shakedown.EveryFaultReport = .{};
    defer diagnostics.deinit();
    return shakedown.everyFault(std.testing.allocator, std.testing.io, subject, .{ .diagnostics = &diagnostics }) catch |e| {
        if (diagnostics.failure) |f| std.log.err("{t} with {any} injected; the run:\n{s}", .{ f.err, f.injected, f.trace });
        return e;
    };
}

test "loading a skeleton from its file survives every single fault, and frees everything" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image = try fixtureSkeleton(gpa);
    defer gpa.free(image);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skeleton.ozz", .data = image });

    var load: Load = .{ .dir = tmp.dir };
    const report = try sweep(&load);
    // Opened, sized, read and closed, the image's block and ozz's: several
    // steps, and more than one fault at most of them.
    try std.testing.expect(report.steps >= 6);
    try std.testing.expect(report.runs > report.steps);
}

test "saving a skeleton to its file survives every single fault: refused with a frame, the destination old or whole, nothing left behind" {
    const gpa = std.testing.allocator;
    var failure: zozz.Failure = .{};
    const image = try fixtureSkeleton(gpa);
    defer gpa.free(image);
    var skeleton = try zozz.Skeleton.initFromMemory(.init(image), &failure);
    defer skeleton.deinit();
    // The bytes a save writes are what the archive holds: the fixture's own.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var save: Save = .{ .dir = tmp.dir, .skeleton = skeleton, .expected = image };
    const report = try sweep(&save);
    // The create, writes, sync, close and rename.
    try std.testing.expect(report.steps >= 5);
}

/// Every loader and saver of the Zig API, by its object type: the loaders'
/// type, their file call, the saver and its file call.
const kinds = .{
    .{ zozz.Skeleton, .skeleton_load_file, zozz.saveSkeletonToFile, .skeleton_save_file },
    .{ zozz.Animation, .animation_load_file, zozz.saveAnimationToFile, .animation_save_file },
    .{ zozz.FloatTrack, .float_track_load_file, zozz.saveFloatTrackToFile, .float_track_save_file },
    .{ zozz.Float2Track, .float2_track_load_file, zozz.saveFloat2TrackToFile, .float2_track_save_file },
    .{ zozz.Float3Track, .float3_track_load_file, zozz.saveFloat3TrackToFile, .float3_track_save_file },
    .{ zozz.Float4Track, .float4_track_load_file, zozz.saveFloat4TrackToFile, .float4_track_save_file },
    .{ zozz.QuaternionTrack, .quaternion_track_load_file, zozz.saveQuaternionTrackToFile, .quaternion_track_save_file },
    .{ zozz.RawSkeleton, .raw_skeleton_load_file, zozz.saveRawSkeletonToFile, .raw_skeleton_save_file },
    .{ zozz.RawAnimation, .raw_animation_load_file, zozz.saveRawAnimationToFile, .raw_animation_save_file },
    .{ zozz.RawFloatTrack, .raw_float_track_load_file, zozz.saveRawFloatTrackToFile, .raw_float_track_save_file },
    .{ zozz.RawFloat2Track, .raw_float2_track_load_file, zozz.saveRawFloat2TrackToFile, .raw_float2_track_save_file },
    .{ zozz.RawFloat3Track, .raw_float3_track_load_file, zozz.saveRawFloat3TrackToFile, .raw_float3_track_save_file },
    .{ zozz.RawFloat4Track, .raw_float4_track_load_file, zozz.saveRawFloat4TrackToFile, .raw_float4_track_save_file },
    .{ zozz.RawQuaternionTrack, .raw_quaternion_track_load_file, zozz.saveRawQuaternionTrackToFile, .raw_quaternion_track_save_file },
};

test "every loader of the Zig API opens its file through the Io it is given" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "object.ozz", .data = "an image no open reaches" });
    inline for (kinds) |kind| {
        const plan = [_]shakedown.FaultIo.IoPlan.Entry{
            .{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 1 } }, .fault = .{ .fail = error.AccessDenied } },
        };
        const fio = try shakedown.FaultIo.init(gpa, std.testing.io, .{ .plan = &plan });
        defer fio.deinit();
        var failure: zozz.Failure = .{};
        try std.testing.expectError(zozz.Error.ReadFailed, kind[0].initFromFile(gpa, fio.io(), tmp.dir, "object.ozz", .fromRaw(1 << 20), &failure));
        try std.testing.expectEqual(@as(usize, 1), fio.fired().len);
        try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = kind[1], .result = .io }}, failure.frames());
    }
}

test "every loader of the Zig API refuses a file over its limit before ozz parses a byte" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image = "seventeen bytes!!";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "object.ozz", .data = image });
    inline for (kinds) |kind| {
        var failure: zozz.Failure = .{};
        try std.testing.expectError(zozz.Error.BadFormat, kind[0].initFromFile(gpa, std.testing.io, tmp.dir, "object.ozz", .fromRaw(image.len - 1), &failure));
        // One frame, the file call's: ozz was never handed the bytes.
        try std.testing.expectEqual(@as(usize, 1), failure.frames().len);
        const frame = failure.frames()[0];
        try std.testing.expectEqual(kind[1], frame.call);
        try std.testing.expectEqual(zozz.c.Result.bad_format, frame.result);
        try std.testing.expectEqualStrings("File.length", frame.refusal.named().?);
        try std.testing.expectEqual(@as(u64, image.len), frame.refusal.value);
        try std.testing.expectEqual(@as(u64, image.len - 1), frame.refusal.limit);
    }
}

/// The C ABI's file save of `object` writes the bytes the Zig API's save
/// writes, and its file load reads those back. Both are found by the name of
/// `object`'s C handle type, as every entry point of a type is spelled.
fn expectCSaveMatches(tmp: std.testing.TmpDir, object: anytype) !void {
    const T = @TypeOf(object);
    const Handle = @typeInfo(@typeInfo(@FieldType(T, "handle")).optional.child).pointer.child;
    const full = @typeName(Handle);
    const name = comptime full[(std.mem.findScalarLast(u8, full, '.') orelse 0) + 1 ..];
    var failure: zozz.Failure = .{};
    try @field(zozz, "save" ++ name ++ "ToFile")(object, std.testing.io, tmp.dir, "zig.ozz", &failure);
    // Relative to the test's working directory, as `tmpDir` makes it.
    var buffer: [64]u8 = undefined;
    const c_path = try std.mem.printSentinel(&buffer, ".zig-cache/tmp/{s}/c.ozz", .{tmp.sub_path}, 0);
    try std.testing.expectEqual(zozz.c.Result.ok, @field(zozz.c, "zozz" ++ name ++ "SaveFile")(object.handle.?, c_path));

    var zig_bytes: [1 << 16]u8 = undefined;
    var c_bytes: [1 << 16]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try tmp.dir.readFile(std.testing.io, "zig.ozz", &zig_bytes), try tmp.dir.readFile(std.testing.io, "c.ozz", &c_bytes));

    const zig_path = try std.mem.printSentinel(&buffer, ".zig-cache/tmp/{s}/zig.ozz", .{tmp.sub_path}, 0);
    var handle: *Handle = undefined;
    var refusal: zozz.c.Refusal = .{};
    try std.testing.expectEqual(zozz.c.Result.ok, @field(zozz.c, "zozz" ++ name ++ "LoadFile")(zig_path, &handle, &refusal));
    var loaded: T = .{ .handle = handle };
    loaded.deinit();
}

test "every C ABI file save writes what the Zig API's writes, and its file load reads it back" {
    const gpa = std.testing.allocator;
    var failure: zozz.Failure = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const skeleton_image = try fixtureSkeleton(gpa);
    defer gpa.free(skeleton_image);
    var skeleton = try zozz.Skeleton.initFromMemory(.init(skeleton_image), &failure);
    defer skeleton.deinit();
    try expectCSaveMatches(tmp, skeleton);

    const clip_image = try fixture(gpa, &zozzFixtureAnimation);
    defer gpa.free(clip_image);
    var clip = try zozz.Animation.initFromMemory(.init(clip_image), &failure);
    defer clip.deinit();
    try expectCSaveMatches(tmp, clip);

    var raw_skeleton = try zozz.RawSkeleton.init(&failure);
    defer raw_skeleton.deinit();
    _ = try raw_skeleton.addJoint(null, "root", zozz.transform_identity, &failure);
    try expectCSaveMatches(tmp, raw_skeleton);

    var raw_clip = try zozz.RawAnimation.init(1, 1.0, null, &failure);
    defer raw_clip.deinit();
    try raw_clip.pushTranslation(0, 0.5, .{ 1, 2, 3 }, &failure);
    try expectCSaveMatches(tmp, raw_clip);

    try expectTrackSavesMatch(tmp, zozz.RawFloatTrack, @as(f32, 0.5));
    try expectTrackSavesMatch(tmp, zozz.RawFloat2Track, [2]f32{ 0.5, 1 });
    try expectTrackSavesMatch(tmp, zozz.RawFloat3Track, [3]f32{ 0.5, 1, 2 });
    try expectTrackSavesMatch(tmp, zozz.RawFloat4Track, [4]f32{ 0.5, 1, 2, 3 });
    try expectTrackSavesMatch(tmp, zozz.RawQuaternionTrack, [4]f32{ 0, 0, 0, 1 });
}

/// `expectCSaveMatches` for a raw track of type `Raw` keyed with `value`,
/// and for the track it builds.
fn expectTrackSavesMatch(tmp: std.testing.TmpDir, comptime Raw: type, value: anytype) !void {
    var failure: zozz.Failure = .{};
    var raw = try Raw.init(&failure);
    defer raw.deinit();
    try raw.pushKeyframe(.linear, 0.5, value, &failure);
    try expectCSaveMatches(tmp, raw);
    var built = try raw.build(&failure);
    defer built.deinit();
    try expectCSaveMatches(tmp, built);
}

test "every saver of the Zig API creates its file through the Io it is given" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    inline for (kinds) |kind| {
        const plan = [_]shakedown.FaultIo.IoPlan.Entry{
            .{ .at = .{ .nth = .{ .call = .dirCreateFileAtomic, .n = 1 } }, .fault = .{ .fail = error.AccessDenied } },
        };
        const fio = try shakedown.FaultIo.init(gpa, std.testing.io, .{ .plan = &plan });
        defer fio.deinit();
        var failure: zozz.Failure = .{};
        // The create is refused before the object is read: a handle of
        // none reaches no archive call.
        const none: kind[0] = .{ .handle = null };
        try std.testing.expectError(zozz.Error.ReadFailed, kind[2](none, fio.io(), tmp.dir, "object.ozz", &failure));
        try std.testing.expectEqual(@as(usize, 1), fio.fired().len);
        try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = kind[3], .result = .io }}, failure.frames());
        var it = tmp.dir.iterate();
        try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(std.testing.io));
    }
}
