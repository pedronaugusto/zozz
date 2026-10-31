//! Behavioural tests for ozz's command-line option parser (-Doptions).

const std = @import("std");
const zozz = @import("zozz.zig");

//=============================================================================
// Silencing ozz's Parser
//
// It writes error/help/version text straight to stdout, and Zig's test runner
// treats stdout as a framed IPC channel to `zig build test`: unframed bytes
// there desync the protocol and hang the runner rather than failing cleanly.
// Every call below that can reach one of those writes is wrapped, so the C++
// still runs for real without corrupting that channel.
//
// The redirect is CRT-level because that is the layer ozz writes through.
// Windows' CRT spells the same four calls with a leading underscore and names
// the null device NUL; `std.c` declares only the POSIX spellings, and on
// Windows its `open` does not compile at all.
//=============================================================================

const crt = if (@import("builtin").target.os.tag == .windows) struct {
    const null_device = "NUL";
    extern "c" fn _open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn _close(fd: c_int) c_int;
    extern "c" fn _dup(fd: c_int) c_int;
    extern "c" fn _dup2(from: c_int, to: c_int) c_int;
    const open = _open;
    const close = _close;
    const dup = _dup;
    const dup2 = _dup2;
} else struct {
    const null_device = "/dev/null";
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn dup(fd: c_int) c_int;
    extern "c" fn dup2(from: c_int, to: c_int) c_int;
};

/// O_WRONLY, which is 1 in both the POSIX and the Windows CRT headers.
const write_only: c_int = 1;

/// Descriptor 1, the CRT's stdout on every platform zozz builds for.
const stdout_fd: c_int = 1;

fn silencingStdout(comptime Result: type, comptime func: anytype, args: anytype) Result {
    const devnull = crt.open(crt.null_device, write_only);
    if (devnull < 0) return @call(.auto, func, args);
    defer _ = crt.close(devnull);

    const saved = crt.dup(stdout_fd);
    if (saved < 0) return @call(.auto, func, args);
    defer _ = crt.close(saved);

    _ = crt.dup2(devnull, stdout_fd);
    defer _ = crt.dup2(saved, stdout_fd);

    return @call(.auto, func, args);
}

/// A handle made while ozz is silenced, as any call or thread can make one.
fn openWhileSilenced() c_int {
    return crt.open(crt.null_device, write_only);
}

test "the runner's protocol survives a handle made while ozz is silenced" {
    // Known red on Windows, preflight-complete 92438516: preflight 0.18.5
    // leaves the CRT's fd 1 on the runner's protocol pipe, so the redirect
    // closes it, this handle takes its place and the runner's next result
    // write fails. The re-pin to a preflight that fixes it drops this skip.
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const handle = silencingStdout(c_int, openWhileSilenced, .{});
    if (handle >= 0) _ = crt.close(handle);
}

test "options: register int/float/bool/string, parse a command line, read values" {
    var failure: zozz.Failure = .{};
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init(&failure);
    defer parser.deinit();

    var int_opt = try zozz.IntOption.init("count", "an int option", 1, false, &failure);
    defer int_opt.deinit();
    var float_opt = try zozz.FloatOption.init("scale", "a float option", 1.0, false, &failure);
    defer float_opt.deinit();
    var bool_opt = try zozz.BoolOption.init("verbose", "a bool option", false, false, &failure);
    defer bool_opt.deinit();
    var string_opt = try zozz.StringOption.init("name", "a string option", "default", true, &failure);
    defer string_opt.deinit();

    try parser.register(int_opt, &failure);
    try parser.register(float_opt, &failure);
    try parser.register(bool_opt, &failure);
    try parser.register(string_opt, &failure);

    // 32-slot capacity minus the two built-ins (--help, --version).
    try std.testing.expectEqual(@as(u32, 30), parser.maxOptions());

    // Well-formed and fully satisfied: Parse() never touches stdout here, so
    // this one call needs no silencing.
    const argv = [_][*:0]const u8{ "prog", "--count=42", "--scale=2.5", "--verbose", "--name=hello" };
    const result = try parser.parseCommandLine(&argv, "1.0", "a test usage string", &failure);
    try std.testing.expectEqual(zozz.OptionsParseResult.success, result);

    try std.testing.expectEqual(@as(i32, 42), try int_opt.value(&failure));
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), try float_opt.value(&failure), 1e-6);
    try std.testing.expect(try bool_opt.value(&failure));
    try std.testing.expectEqualStrings("hello", try string_opt.value(&failure));

    try std.testing.expect(int_opt.statisfied());
    try std.testing.expect(!int_opt.required());
    try std.testing.expect(string_opt.required());
    try std.testing.expect(string_opt.statisfied());
    try std.testing.expectEqualStrings("count", int_opt.name());
    try std.testing.expectEqualStrings("an int option", int_opt.help());
    try std.testing.expectEqualStrings("prog", parser.executableName());
    try std.testing.expectEqualStrings("a test usage string", parser.usage());

    try int_opt.restoreDefault(&failure);
    try std.testing.expectEqual(@as(i32, 1), try int_opt.value(&failure));

    try parser.unregister(int_opt, &failure);
    try parser.unregister(float_opt, &failure);
    try parser.unregister(bool_opt, &failure);
    try parser.unregister(string_opt, &failure);
}

test "options: an unknown argument fails the parse" {
    var failure: zozz.Failure = .{};
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init(&failure);
    defer parser.deinit();

    const argv = [_][*:0]const u8{ "prog", "--this-option-does-not-exist" };
    const result = try silencingStdout(
        zozz.Error!zozz.OptionsParseResult,
        zozz.OptionsParser.parseCommandLine,
        .{ parser, &argv, @as(?[*:0]const u8, "1.0"), @as(?[*:0]const u8, "usage"), &failure },
    );
    try std.testing.expectEqual(zozz.OptionsParseResult.exit_failure, result);
}

test "options: a missing required option fails the parse" {
    var failure: zozz.Failure = .{};
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init(&failure);
    defer parser.deinit();
    var required = try zozz.StringOption.init("mandatory", null, "", true, &failure);
    defer required.deinit();
    try parser.register(required, &failure);

    const argv = [_][*:0]const u8{"prog"};
    const result = try silencingStdout(
        zozz.Error!zozz.OptionsParseResult,
        zozz.OptionsParser.parseCommandLine,
        .{ parser, &argv, @as(?[*:0]const u8, null), @as(?[*:0]const u8, null), &failure },
    );
    try std.testing.expectEqual(zozz.OptionsParseResult.exit_failure, result);
    try std.testing.expect(!required.statisfied());

    try parser.unregister(required, &failure);
}

test "options: --help returns the help result rather than crashing" {
    var failure: zozz.Failure = .{};
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init(&failure);
    defer parser.deinit();

    const argv = [_][*:0]const u8{ "prog", "--help" };
    const result = try silencingStdout(
        zozz.Error!zozz.OptionsParseResult,
        zozz.OptionsParser.parseCommandLine,
        .{ parser, &argv, @as(?[*:0]const u8, "1.0"), @as(?[*:0]const u8, "usage"), &failure },
    );
    try std.testing.expectEqual(zozz.OptionsParseResult.exit_success, result);

    // The direct call writes the same screen to stdout on demand.
    try silencingStdout(zozz.Error!void, zozz.OptionsParser.help, .{ parser, &failure });
}

test "options: register/unregister failures are errors, not crashes" {
    var failure: zozz.Failure = .{};
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init(&failure);
    defer parser.deinit();
    var opt = try zozz.BoolOption.init("flag", null, false, false, &failure);
    defer opt.deinit();

    // Not registered anywhere yet.
    try std.testing.expectError(zozz.Error.InvalidArgument, parser.unregister(opt, &failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .options_parser_unregister, .result = .invalid_argument }}, failure.frames());
    failure.reset();

    try parser.register(opt, &failure);
    // Duplicate name.
    var dup = try zozz.BoolOption.init("flag", null, true, false, &failure);
    defer dup.deinit();
    try std.testing.expectError(zozz.Error.InvalidArgument, parser.register(dup, &failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .options_parser_register, .result = .invalid_argument }}, failure.frames());
    failure.reset();

    try parser.unregister(opt, &failure);
}

test "options: every entry point is unsupported without -Doptions" {
    var failure: zozz.Failure = .{};
    if (zozz.options.options) return error.SkipZigTest;

    try std.testing.expectError(zozz.Error.Unsupported, zozz.OptionsParser.init(&failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .options_parser_create, .result = .unsupported }}, failure.frames());
    failure.reset();
    try std.testing.expectError(zozz.Error.Unsupported, zozz.IntOption.init("x", null, 0, false, &failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .int_option_create, .result = .unsupported }}, failure.frames());
    failure.reset();
    try std.testing.expectError(zozz.Error.Unsupported, zozz.FloatOption.init("x", null, 0, false, &failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .float_option_create, .result = .unsupported }}, failure.frames());
    failure.reset();
    try std.testing.expectError(zozz.Error.Unsupported, zozz.BoolOption.init("x", null, false, false, &failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .bool_option_create, .result = .unsupported }}, failure.frames());
    failure.reset();
    try std.testing.expectError(zozz.Error.Unsupported, zozz.StringOption.init("x", null, null, false, &failure));
    try std.testing.expectEqualSlices(zozz.Frame, &.{.{ .call = .string_option_create, .result = .unsupported }}, failure.frames());
}
