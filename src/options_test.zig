//! Behavioural tests for ozz's command-line option parser (-Doptions).

const std = @import("std");
const zozz = @import("zozz.zig");

/// ozz's Parser writes error/help/version text straight to stdout (see
/// zozz_options.h's module comment) — every path through Parse() that does
/// not cleanly succeed, and every direct Help() call, reaches it. Zig's own
/// test runner ALSO uses stdout (fd 1) as its framed IPC channel back to
/// `zig build test`; unframed text arriving there desyncs that protocol and
/// hangs the runner instead of failing loudly. Every call below that can
/// reach one of those writes is routed through this redirect first, so the
/// C++ behaviour is still exercised for real without corrupting the channel
/// this process is itself being driven through.
fn silencingStdout(comptime Result: type, comptime func: anytype, args: anytype) Result {
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
    if (devnull < 0) return @call(.auto, func, args);
    defer _ = std.c.close(devnull);

    const stdout_fd = std.posix.STDOUT_FILENO;
    const saved = std.c.dup(stdout_fd);
    if (saved < 0) return @call(.auto, func, args);
    defer _ = std.c.close(saved);

    _ = std.c.dup2(devnull, stdout_fd);
    defer _ = std.c.dup2(saved, stdout_fd);

    return @call(.auto, func, args);
}

test "options: register int/float/bool/string, parse a command line, read values" {
    if (!zozz.options.options) return error.SkipZigTest;

    const parser = try zozz.OptionsParser.init();
    defer parser.deinit();

    const int_opt = try zozz.IntOption.init("count", "an int option", 1, false);
    defer int_opt.deinit();
    const float_opt = try zozz.FloatOption.init("scale", "a float option", 1.0, false);
    defer float_opt.deinit();
    const bool_opt = try zozz.BoolOption.init("verbose", "a bool option", false, false);
    defer bool_opt.deinit();
    const string_opt = try zozz.StringOption.init("name", "a string option", "default", true);
    defer string_opt.deinit();

    try parser.register(int_opt.handle);
    try parser.register(float_opt.handle);
    try parser.register(bool_opt.handle);
    try parser.register(string_opt.handle);

    // 32-slot capacity minus the two built-ins (--help, --version).
    try std.testing.expectEqual(@as(u32, 30), parser.maxOptions());

    // Well-formed and fully satisfied: Parse() never touches stdout here, so
    // this one call needs no silencing.
    const argv = [_][*:0]const u8{ "prog", "--count=42", "--scale=2.5", "--verbose", "--name=hello" };
    const result = try parser.parseCommandLine(&argv, "1.0", "a test usage string");
    try std.testing.expectEqual(zozz.OptionsParseResult.success, result);

    try std.testing.expectEqual(@as(i32, 42), try int_opt.value());
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), try float_opt.value(), 1e-6);
    try std.testing.expect(try bool_opt.value());
    try std.testing.expectEqualStrings("hello", try string_opt.value());

    try std.testing.expect(int_opt.statisfied());
    try std.testing.expect(!int_opt.required());
    try std.testing.expect(string_opt.required());
    try std.testing.expect(string_opt.statisfied());
    try std.testing.expectEqualStrings("count", int_opt.name());
    try std.testing.expectEqualStrings("an int option", int_opt.help());
    try std.testing.expectEqualStrings("prog", parser.executableName());
    try std.testing.expectEqualStrings("a test usage string", parser.usage());

    try int_opt.restoreDefault();
    try std.testing.expectEqual(@as(i32, 1), try int_opt.value());

    try parser.unregister(int_opt.handle);
    try parser.unregister(float_opt.handle);
    try parser.unregister(bool_opt.handle);
    try parser.unregister(string_opt.handle);
}

test "options: an unknown argument fails the parse" {
    if (!zozz.options.options) return error.SkipZigTest;

    const parser = try zozz.OptionsParser.init();
    defer parser.deinit();

    const argv = [_][*:0]const u8{ "prog", "--this-option-does-not-exist" };
    const result = try silencingStdout(
        zozz.Error!zozz.OptionsParseResult,
        zozz.OptionsParser.parseCommandLine,
        .{ parser, &argv, @as(?[*:0]const u8, "1.0"), @as(?[*:0]const u8, "usage") },
    );
    try std.testing.expectEqual(zozz.OptionsParseResult.exit_failure, result);
}

test "options: a missing required option fails the parse" {
    if (!zozz.options.options) return error.SkipZigTest;

    const parser = try zozz.OptionsParser.init();
    defer parser.deinit();
    const required = try zozz.StringOption.init("mandatory", null, "", true);
    defer required.deinit();
    try parser.register(required.handle);

    const argv = [_][*:0]const u8{"prog"};
    const result = try silencingStdout(
        zozz.Error!zozz.OptionsParseResult,
        zozz.OptionsParser.parseCommandLine,
        .{ parser, &argv, @as(?[*:0]const u8, null), @as(?[*:0]const u8, null) },
    );
    try std.testing.expectEqual(zozz.OptionsParseResult.exit_failure, result);
    try std.testing.expect(!required.statisfied());

    try parser.unregister(required.handle);
}

test "options: --help returns the help result rather than crashing" {
    if (!zozz.options.options) return error.SkipZigTest;

    const parser = try zozz.OptionsParser.init();
    defer parser.deinit();

    const argv = [_][*:0]const u8{ "prog", "--help" };
    const result = try silencingStdout(
        zozz.Error!zozz.OptionsParseResult,
        zozz.OptionsParser.parseCommandLine,
        .{ parser, &argv, @as(?[*:0]const u8, "1.0"), @as(?[*:0]const u8, "usage") },
    );
    try std.testing.expectEqual(zozz.OptionsParseResult.exit_success, result);

    // The direct call writes the same screen to stdout on demand.
    try silencingStdout(zozz.Error!void, zozz.OptionsParser.help, .{parser});
}

test "options: register/unregister failures are errors, not crashes" {
    if (!zozz.options.options) return error.SkipZigTest;

    const parser = try zozz.OptionsParser.init();
    defer parser.deinit();
    const opt = try zozz.BoolOption.init("flag", null, false, false);
    defer opt.deinit();

    // Not registered anywhere yet.
    try std.testing.expectError(zozz.Error.InvalidArgument, parser.unregister(opt.handle));

    try parser.register(opt.handle);
    // Duplicate name.
    const dup = try zozz.BoolOption.init("flag", null, true, false);
    defer dup.deinit();
    try std.testing.expectError(zozz.Error.InvalidArgument, parser.register(dup.handle));

    try parser.unregister(opt.handle);
}

test "options: every entry point is unsupported without -Doptions" {
    if (zozz.options.options) return error.SkipZigTest;

    try std.testing.expectError(zozz.Error.Unsupported, zozz.OptionsParser.init());
    try std.testing.expectError(zozz.Error.Unsupported, zozz.IntOption.init("x", null, 0, false));
    try std.testing.expectError(zozz.Error.Unsupported, zozz.FloatOption.init("x", null, 0, false));
    try std.testing.expectError(zozz.Error.Unsupported, zozz.BoolOption.init("x", null, false, false));
    try std.testing.expectError(zozz.Error.Unsupported, zozz.StringOption.init("x", null, null, false));
}
