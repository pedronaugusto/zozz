//! What ozz may print in a test (tests/quiet.h): a test that expects a
//! refusal silences ozz's log and asserts through the refusal record, and one
//! that drives ozz's options parser expects its text. Any other write ozz
//! makes stops the test that made it, so a passing run prints nothing.

const std = @import("std");
const zozz = @import("../zozz.zig");

extern fn zozzTestExpectOutput(expect: c_int) void;
extern fn zozzTestOutputGuarded() c_int;

/// ozz's log silenced until `end`: for a test that expects a refusal, which
/// the refusal record states, or one whose ozz call logs its progress and
/// whose result the test asserts directly.
pub const SilentLog = struct {
    was: zozz.LogLevel,

    pub fn begin() SilentLog {
        const was = zozz.logLevel();
        zozz.setLogLevel(.silent);
        return .{ .was = was };
    }

    pub fn end(self: SilentLog) void {
        zozz.setLogLevel(self.was);
    }
};

/// What ozz writes outside its log expected and dropped until `end`: the
/// options parser's help, version and errors, and a refused registration.
pub const Expecting = struct {
    pub fn begin() Expecting {
        zozzTestExpectOutput(1);
        return .{};
    }

    pub fn end(self: Expecting) void {
        _ = self;
        zozzTestExpectOutput(0);
    }
};

test "ozz's three output streams are guarded in this test binary" {
    try std.testing.expectEqual(@as(c_int, 1), zozzTestOutputGuarded());
}
