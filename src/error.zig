//! Translation between the C result enum and a Zig error set, the frame each
//! refusal leaves on the caller's `Failure`, and the contracts the wrappers
//! hold the boundary to: a live handle, a count the boundary reports, and the
//! bytes a loader parses.

const std = @import("std");
const aegis = @import("aegis");
const c = @import("c.zig");

pub const Error = error{
    /// The path could not be opened for reading.
    FileNotFound,
    /// The stream ended early or could not be read.
    ReadFailed,
    /// The archive did not identify itself as the expected ozz object type.
    BadFormat,
    /// The installed allocator returned null.
    OutOfMemory,
    /// A null handle, a count or index the C boundary cannot carry, a NaN,
    /// or a misaligned buffer.
    InvalidArgument,
    /// An ozz job rejected its own parameters.
    JobInvalid,
    /// The destination buffer was smaller than the required joint count.
    BufferTooSmall,
    /// Skeleton and pose (or animation) describe different joint counts.
    SkeletonMismatch,
    /// Authored offline data failed ozz validation: a raw skeleton over the
    /// depth limit, or raw animation keys out of order.
    InvalidData,
    /// The entry point exists but its build option is off: the library was
    /// compiled without the code it needs.
    Unsupported,
    /// A different allocator was offered while blocks the one in use — a
    /// host's, or ozz's own — are still live. Destroy what is outstanding
    /// first.
    AllocatorInUse,
};

/// The call a refusal names: the C entry point that returned it, or the one
/// the binding refused to make because an argument could not reach it, in
/// snake case without the `zozz` prefix (`zozzSamplingContextCreate` is
/// `sampling_context_create`). `soa_blocks` returns a count, not a result:
/// its zero is the refusal.
pub const Call = enum {
    additive_animation_builder_run,
    additive_animation_builder_run_with_reference,
    animation_build,
    animation_count_rotation_keys,
    animation_count_scale_keys,
    animation_count_translation_keys,
    animation_keyframe_iframe_desc,
    animation_keyframe_iframe_entries,
    animation_keyframe_previouses,
    animation_keyframe_ratios,
    animation_keyframes_ctrl,
    animation_load_file,
    animation_load_memory,
    animation_optimizer_clear_joint_override,
    animation_optimizer_create,
    animation_optimizer_get_setting,
    animation_optimizer_run,
    animation_optimizer_set_joint_override,
    animation_optimizer_set_setting,
    animation_save_file,
    animation_timepoints,
    blending_run,
    bool_option_create,
    bool_option_default,
    bool_option_value,
    compute_gv4_worst_buffer_size,
    decode_gv4,
    decode_gv4_stream,
    encode_gv4,
    encode_gv4_stream,
    fixed_rate_sampling_time_at,
    fixed_rate_sampling_time_create,
    float2_track_build,
    float2_track_load_file,
    float2_track_load_memory,
    float2_track_sample,
    float2_track_save_file,
    float3_track_build,
    float3_track_load_file,
    float3_track_load_memory,
    float3_track_sample,
    float3_track_save_file,
    float4_track_build,
    float4_track_load_file,
    float4_track_load_memory,
    float4_track_sample,
    float4_track_save_file,
    float_option_create,
    float_option_default,
    float_option_value,
    float_track_build,
    float_track_load_file,
    float_track_load_memory,
    float_track_sample,
    float_track_save_file,
    float_track_triggering_job_run,
    get_allocator,
    gltf_importer_create,
    i_archive_create,
    i_archive_load_animation,
    i_archive_load_binary,
    i_archive_load_float,
    i_archive_load_float2_track,
    i_archive_load_float3_track,
    i_archive_load_float4_track,
    i_archive_load_float_track,
    i_archive_load_int32,
    i_archive_load_quaternion_track,
    i_archive_load_raw_animation,
    i_archive_load_raw_float2_track,
    i_archive_load_raw_float3_track,
    i_archive_load_raw_float4_track,
    i_archive_load_raw_float_track,
    i_archive_load_raw_quaternion_track,
    i_archive_load_raw_skeleton,
    i_archive_load_skeleton,
    ik_aim_job_run,
    ik_two_bone_job_run,
    importer_create,
    importer_import_animation,
    importer_import_float2_track,
    importer_import_float3_track,
    importer_import_float4_track,
    importer_import_float_track,
    importer_import_skeleton,
    importer_iterate_animation_names,
    importer_iterate_node_properties,
    importer_load,
    importer_run,
    int_option_create,
    int_option_default,
    int_option_value,
    local_to_model,
    motion_blend,
    motion_extractor_create,
    motion_extractor_get_position_settings,
    motion_extractor_get_rotation_settings,
    motion_extractor_run,
    motion_extractor_set_position_settings,
    motion_extractor_set_root_joint,
    motion_extractor_set_rotation_settings,
    o_archive_create,
    o_archive_save_animation,
    o_archive_save_binary,
    o_archive_save_float,
    o_archive_save_float2_track,
    o_archive_save_float3_track,
    o_archive_save_float4_track,
    o_archive_save_float_track,
    o_archive_save_int32,
    o_archive_save_quaternion_track,
    o_archive_save_raw_animation,
    o_archive_save_raw_float2_track,
    o_archive_save_raw_float3_track,
    o_archive_save_raw_float4_track,
    o_archive_save_raw_float_track,
    o_archive_save_raw_quaternion_track,
    o_archive_save_raw_skeleton,
    o_archive_save_skeleton,
    option_restore_default,
    options_parser_create,
    options_parser_help,
    options_parser_parse_command_line,
    options_parser_register,
    options_parser_set_usage,
    options_parser_set_version,
    options_parser_unregister,
    quaternion_track_build,
    quaternion_track_load_file,
    quaternion_track_load_memory,
    quaternion_track_sample,
    quaternion_track_save_file,
    raw_animation_clear_rotations,
    raw_animation_clear_scales,
    raw_animation_clear_track,
    raw_animation_clear_translations,
    raw_animation_create,
    raw_animation_extract_time_points,
    raw_animation_load_file,
    raw_animation_load_memory,
    raw_animation_push_rotation,
    raw_animation_push_scale,
    raw_animation_push_translation,
    raw_animation_rotations,
    raw_animation_sample,
    raw_animation_sample_track,
    raw_animation_sample_track_model_space,
    raw_animation_save_file,
    raw_animation_scales,
    raw_animation_set_duration,
    raw_animation_set_name,
    raw_animation_translations,
    raw_float2_track_clear,
    raw_float2_track_create,
    raw_float2_track_keyframes,
    raw_float2_track_load_file,
    raw_float2_track_load_memory,
    raw_float2_track_optimize,
    raw_float2_track_push_keyframe,
    raw_float2_track_save_file,
    raw_float2_track_set_name,
    raw_float3_track_clear,
    raw_float3_track_create,
    raw_float3_track_keyframes,
    raw_float3_track_load_file,
    raw_float3_track_load_memory,
    raw_float3_track_optimize,
    raw_float3_track_push_keyframe,
    raw_float3_track_save_file,
    raw_float3_track_set_name,
    raw_float4_track_clear,
    raw_float4_track_create,
    raw_float4_track_keyframes,
    raw_float4_track_load_file,
    raw_float4_track_load_memory,
    raw_float4_track_optimize,
    raw_float4_track_push_keyframe,
    raw_float4_track_save_file,
    raw_float4_track_set_name,
    raw_float_track_clear,
    raw_float_track_create,
    raw_float_track_keyframes,
    raw_float_track_load_file,
    raw_float_track_load_memory,
    raw_float_track_optimize,
    raw_float_track_push_keyframe,
    raw_float_track_save_file,
    raw_float_track_set_name,
    raw_quaternion_track_clear,
    raw_quaternion_track_create,
    raw_quaternion_track_keyframes,
    raw_quaternion_track_load_file,
    raw_quaternion_track_load_memory,
    raw_quaternion_track_optimize,
    raw_quaternion_track_push_keyframe,
    raw_quaternion_track_save_file,
    raw_quaternion_track_set_name,
    raw_skeleton_add_joint,
    raw_skeleton_create,
    raw_skeleton_iterate_joints_breadth_first,
    raw_skeleton_joint_rest,
    raw_skeleton_load_file,
    raw_skeleton_load_memory,
    raw_skeleton_save_file,
    sample,
    sampling_context_create,
    sampling_context_resize,
    set_allocator,
    set_log_level,
    skeleton_build,
    skeleton_iterate_joints_depth_first,
    skeleton_iterate_joints_depth_first_reverse,
    skeleton_joint_is_leaf,
    skeleton_joint_rest_pose_local,
    skeleton_load_file,
    skeleton_load_memory,
    skeleton_rest_pose,
    skeleton_rest_pose_model_space,
    skeleton_rest_pose_soa,
    skeleton_save_file,
    skinning_job_run,
    soa_blocks,
    soa_pose_apply_local_corrections,
    soa_pose_from_local_transforms,
    soa_pose_set_identity,
    soa_pose_to_local_transforms,
    soa_weights_pack,
    string_option_create,
    string_option_default,
    string_option_value,
    track_interpolations,
    track_triggering_iterator_get,
    track_triggering_iterator_next,
};

/// One refusal: the call, and the result it returned or was refused with.
pub const Frame = struct {
    pub const aegis_public_frame = true;
    call: Call,
    result: c.Result,
};

/// What refused, oldest first. Every call that can fail takes one and pushes
/// one frame where it refuses; a call that only passes a refusal on pushes
/// nothing. Four are kept, and a fifth sets `truncated`.
pub const Failure = aegis.err.Context(Frame, 4);

/// Bytes a loader parses: an `.ozz` archive's image, or a group-varint
/// stream. They leave this type only at the call that hands them to the
/// boundary's checked reader.
pub const Bytes = aegis.input.Untrusted([]const u8);

/// Turns a C result into a Zig error, or void on success, leaving no frame:
/// for a call whose refusal `aegis.assert.never` rules out.
///
/// The switch is exhaustive over `c.Result` with no `else` branch: adding a
/// result to the C enum without handling it here is a compile error, which is
/// the property `AbiLayout.result_count` also checks at runtime.
pub fn map(result: c.Result) Error!void {
    return switch (result) {
        .ok => {},
        .file_not_found => Error.FileNotFound,
        .io => Error.ReadFailed,
        .bad_format => Error.BadFormat,
        .out_of_memory => Error.OutOfMemory,
        .invalid_argument => Error.InvalidArgument,
        .job_invalid => Error.JobInvalid,
        .buffer_too_small => Error.BufferTooSmall,
        .skeleton_mismatch => Error.SkeletonMismatch,
        .invalid_data => Error.InvalidData,
        .unsupported => Error.Unsupported,
        .allocator_in_use => Error.AllocatorInUse,
    };
}

/// The result an error stands for, `map` read backwards.
pub fn resultOf(e: Error) c.Result {
    return switch (e) {
        Error.FileNotFound => .file_not_found,
        Error.ReadFailed => .io,
        Error.BadFormat => .bad_format,
        Error.OutOfMemory => .out_of_memory,
        Error.InvalidArgument => .invalid_argument,
        Error.JobInvalid => .job_invalid,
        Error.BufferTooSmall => .buffer_too_small,
        Error.SkeletonMismatch => .skeleton_mismatch,
        Error.InvalidData => .invalid_data,
        Error.Unsupported => .unsupported,
        Error.AllocatorInUse => .allocator_in_use,
    };
}

/// Nothing on success; otherwise a frame on `failure` naming `call` and
/// `result`, and the error `result` maps to.
pub fn check(failure: *Failure, call: Call, result: c.Result) Error!void {
    map(result) catch |e| {
        failure.push(.{ .call = call, .result = result });
        return e;
    };
}

/// A refusal the binding makes before C is called: a frame on `failure`
/// naming `call` and the result `e` stands for, and `e`.
pub fn refuse(failure: *Failure, call: Call, e: Error) Error {
    failure.push(.{ .call = call, .result = resultOf(e) });
    return e;
}

/// `value` as `T` for the C boundary, or a refusal naming `call` when it
/// does not fit: a count or index the caller chose, which the boundary's
/// narrower parameter cannot carry.
pub fn narrow(failure: *Failure, call: Call, comptime T: type, value: anytype) Error!T {
    return aegis.int.narrow(T, value) orelse refuse(failure, call, Error.InvalidArgument);
}

/// `value`, a count, length or index the boundary reported, as `T`. The
/// boundary reports none below zero and none past what it holds, so one
/// that does not fit is a broken boundary rather than input to refuse, and
/// it stops in every build.
pub fn reported(comptime T: type, value: anytype) T {
    return aegis.int.narrow(T, value) orelse aegis.assert.never("zozz: the C boundary reported a count its type cannot hold");
}

/// The pointer a handle wrapper holds, which `deinit` nulls. A wrapper used
/// after its `deinit` stops in every build rather than handing ozz a freed
/// pointer.
pub inline fn live(handle: anytype) @typeInfo(@TypeOf(handle)).optional.child {
    return handle orelse aegis.assert.never("zozz: a handle was used after its deinit");
}

/// Borrowed, static description of a result, for logging.
pub fn name(result: c.Result) [:0]const u8 {
    return std.mem.span(c.zozzResultName(result));
}

test "ok is the only result that is not an error, and all of them are named" {
    try map(.ok);
    inline for (@typeInfo(c.Result).@"enum".field_values) |value| {
        const result: c.Result = @fromBackingInt(@intCast(value));
        try std.testing.expect(name(result).len > 0);
        if (result == .ok) continue;
        if (map(result)) |_| return error.ResultMappedToSuccess else |e| try std.testing.expectEqual(result, resultOf(e));
    }
}

test "a refusal pushes one frame naming its call and result, and success pushes none" {
    var failure: Failure = .{};
    try check(&failure, .sample, .ok);
    try std.testing.expectEqual(0, failure.frames().len);
    try std.testing.expectError(Error.JobInvalid, check(&failure, .sample, .job_invalid));
    try std.testing.expectError(Error.InvalidArgument, narrow(&failure, .sampling_context_create, c_int, @as(u32, 1 << 31)));
    try std.testing.expectEqual(@as(c_int, 7), try narrow(&failure, .sampling_context_create, c_int, @as(u32, 7)));
    try std.testing.expectEqualSlices(Frame, &.{
        .{ .call = .sample, .result = .job_invalid },
        .{ .call = .sampling_context_create, .result = .invalid_argument },
    }, failure.frames());
}

test "a fifth frame sets truncated and keeps the first four" {
    var failure: Failure = .{};
    for (0..5) |_| try std.testing.expectEqual(Error.JobInvalid, refuse(&failure, .blending_run, Error.JobInvalid));
    try std.testing.expectEqual(4, failure.frames().len);
    try std.testing.expect(failure.truncated);
}

/// `zozzSamplingContextCreate` -> `sampling_context_create`, as `Call`
/// spells it.
fn callName(c_name: []const u8, buf: []u8) []const u8 {
    const s = c_name["zozz".len..];
    var len: usize = 0;
    for (s, 0..) |ch, i| {
        const prev = if (i == 0) 0 else s[i - 1];
        const next = if (i + 1 < s.len) s[i + 1] else 0;
        const boundary = i != 0 and
            ((std.ascii.isLower(prev) and std.ascii.isUpper(ch)) or
                (std.ascii.isDigit(prev) and std.ascii.isUpper(ch) and std.ascii.isLower(next)) or
                (std.ascii.isUpper(prev) and std.ascii.isUpper(ch) and std.ascii.isLower(next)));
        if (boundary) {
            buf[len] = '_';
            len += 1;
        }
        buf[len] = std.ascii.toLower(ch);
        len += 1;
    }
    return buf[0..len];
}

test "call names are the entry points' names in snake case" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("sampling_context_create", callName("zozzSamplingContextCreate", &buf));
    try std.testing.expectEqualStrings("float2_track_sample", callName("zozzFloat2TrackSample", &buf));
    try std.testing.expectEqualStrings("decode_gv4_stream", callName("zozzDecodeGV4Stream", &buf));
    try std.testing.expectEqualStrings("ik_two_bone_run", callName("zozzIKTwoBoneRun", &buf));
}

/// Every module that refuses, read as it is compiled.
const sources = [_][]const u8{
    @embedFile("animation.zig"), @embedFile("archive.zig"),  @embedFile("blending.zig"),
    @embedFile("encode.zig"),    @embedFile("ik.zig"),       @embedFile("importer.zig"),
    @embedFile("memory.zig"),    @embedFile("motion.zig"),   @embedFile("offline.zig"),
    @embedFile("optimizer.zig"), @embedFile("options.zig"),  @embedFile("pose.zig"),
    @embedFile("rawtrack.zig"),  @embedFile("sampling.zig"), @embedFile("skeleton.zig"),
    @embedFile("skinning.zig"),  @embedFile("track.zig"),    @embedFile("utils.zig"),
    @embedFile("zozz.zig"),
};

test "every frame a checked C call pushes names that call" {
    // `err.check(failure, .x, c.zozzY(` must name `.x` as `zozzY` spells it,
    // so a frame can never name a call other than the one that refused. The
    // compiler proves both exist.
    var checked: usize = 0;
    for (sources) |source| {
        var rest: []const u8 = source;
        const marker = "err.check(failure, .";
        while (std.mem.find(u8, rest, marker)) |at| {
            rest = rest[at + marker.len ..];
            const end = std.mem.findScalar(u8, rest, ',') orelse return error.TestUnexpectedResult;
            const named = rest[0..end];
            const after = std.mem.trimStart(u8, rest[end + 1 ..], " \n");
            if (!std.mem.startsWith(u8, after, "c.zozz")) continue;
            const paren = std.mem.findScalar(u8, after, '(') orelse return error.TestUnexpectedResult;
            var buf: [128]u8 = undefined;
            try std.testing.expectEqualStrings(callName(after["c.".len..paren], &buf), named);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 200);
}

test "no module refuses without a frame" {
    // A refusal is made by `check`, `refuse` or `narrow`, which push the
    // frame. One of this set's errors returned any other way would reach the
    // caller with nothing on its `Failure`; and `map`, which pushes none, is
    // only for a result `aegis.assert.never` rules out.
    inline for (@typeInfo(Error).error_set.error_names.?) |error_name| {
        inline for (.{ "return ", "catch ", "orelse " }) |verb| {
            inline for (.{ "error.", "Error.", "err.Error." }) |spelling| {
                for (sources) |source| {
                    try std.testing.expect(std.mem.find(u8, source, verb ++ spelling ++ error_name) == null);
                }
            }
        }
    }
    for (sources) |source| {
        // Whether the innermost declaration above is a test block: a module
        // never makes a `Failure` of its own, whose frames no caller would see.
        var in_test = false;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const code = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, code, "test \"")) in_test = true;
            if (std.mem.startsWith(u8, code, "fn ") or std.mem.startsWith(u8, code, "pub fn ")) in_test = false;
            if (std.mem.find(u8, line, "err.map(") != null or std.mem.find(u8, line, "error_mod.map(") != null) {
                try std.testing.expect(std.mem.find(u8, line, "catch aegis.assert.never(") != null);
            }
            if (std.mem.find(u8, line, "err.Failure = .{}") != null) try std.testing.expect(in_test);
        }
    }
}

test "a generic wrapper's call prefix names the entry points it is given" {
    // track.zig's vector tracks name their frames `ops.call ++ "_sample"` and
    // so on, which the scan above cannot read: every `c.zozz` entry point an
    // instantiation hands over must spell its name from that prefix.
    var checked: usize = 0;
    for (sources) |source| {
        var rest: []const u8 = source;
        const marker = ".call = \"";
        while (std.mem.find(u8, rest, marker)) |at| {
            rest = rest[at + marker.len ..];
            const prefix = rest[0 .. std.mem.findScalar(u8, rest, '"') orelse return error.TestUnexpectedResult];
            const body = rest[0 .. std.mem.find(u8, rest, "})") orelse return error.TestUnexpectedResult];
            var entries = body;
            while (std.mem.find(u8, entries, "= c.zozz")) |entry| {
                entries = entries[entry + "= c.".len ..];
                const end = std.mem.findScalar(u8, entries, ',') orelse return error.TestUnexpectedResult;
                var buf: [128]u8 = undefined;
                const named = callName(entries[0..end], &buf);
                try std.testing.expect(std.mem.startsWith(u8, named, prefix) and named[prefix.len] == '_');
                checked += 1;
            }
        }
    }
    try std.testing.expect(checked > 0);
}
