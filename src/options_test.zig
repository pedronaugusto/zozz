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

const crt = if (@import("builtin").os.tag == .windows) struct {
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

test "options: register int/float/bool/string, parse a command line, read values" {
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init();
    defer parser.deinit();

    var int_opt = try zozz.IntOption.init("count", "an int option", 1, false);
    defer int_opt.deinit();
    var float_opt = try zozz.FloatOption.init("scale", "a float option", 1.0, false);
    defer float_opt.deinit();
    var bool_opt = try zozz.BoolOption.init("verbose", "a bool option", false, false);
    defer bool_opt.deinit();
    var string_opt = try zozz.StringOption.init("name", "a string option", "default", true);
    defer string_opt.deinit();

    try parser.register(int_opt);
    try parser.register(float_opt);
    try parser.register(bool_opt);
    try parser.register(string_opt);

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

    try parser.unregister(int_opt);
    try parser.unregister(float_opt);
    try parser.unregister(bool_opt);
    try parser.unregister(string_opt);
}

test "options: an unknown argument fails the parse" {
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init();
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

    var parser = try zozz.OptionsParser.init();
    defer parser.deinit();
    var required = try zozz.StringOption.init("mandatory", null, "", true);
    defer required.deinit();
    try parser.register(required);

    const argv = [_][*:0]const u8{"prog"};
    const result = try silencingStdout(
        zozz.Error!zozz.OptionsParseResult,
        zozz.OptionsParser.parseCommandLine,
        .{ parser, &argv, @as(?[*:0]const u8, null), @as(?[*:0]const u8, null) },
    );
    try std.testing.expectEqual(zozz.OptionsParseResult.exit_failure, result);
    try std.testing.expect(!required.statisfied());

    try parser.unregister(required);
}

test "options: --help returns the help result rather than crashing" {
    if (!zozz.options.options) return error.SkipZigTest;

    var parser = try zozz.OptionsParser.init();
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

    var parser = try zozz.OptionsParser.init();
    defer parser.deinit();
    var opt = try zozz.BoolOption.init("flag", null, false, false);
    defer opt.deinit();

    // Not registered anywhere yet.
    try std.testing.expectError(zozz.Error.InvalidArgument, parser.unregister(opt));

    try parser.register(opt);
    // Duplicate name.
    var dup = try zozz.BoolOption.init("flag", null, true, false);
    defer dup.deinit();
    try std.testing.expectError(zozz.Error.InvalidArgument, parser.register(dup));

    try parser.unregister(opt);
}

test "options: every entry point is unsupported without -Doptions" {
    if (zozz.options.options) return error.SkipZigTest;

    try std.testing.expectError(zozz.Error.Unsupported, zozz.OptionsParser.init());
    try std.testing.expectError(zozz.Error.Unsupported, zozz.IntOption.init("x", null, 0, false));
    try std.testing.expectError(zozz.Error.Unsupported, zozz.FloatOption.init("x", null, 0, false));
    try std.testing.expectError(zozz.Error.Unsupported, zozz.BoolOption.init("x", null, false, false));
    try std.testing.expectError(zozz.Error.Unsupported, zozz.StringOption.init("x", null, null, false));
}
