//! The plain-data types that cross the boundary.
//!
//! These are the C types re-exported, not copies: a wrapper struct would mean
//! a conversion on every joint of every frame for no benefit.

const std = @import("std");
const c = @import("c.zig");

/// One joint's local-space transform.
///
/// `rotation` is a quaternion in (x, y, z, w) order — w LAST. Consumers whose
/// own quaternion type is w-first must reorder; there is no silent conversion
/// here to get wrong.
pub const Transform = c.Transform;

/// A column-major 4x4 matrix: `m[0..4]` is the first column.
///
/// 16-byte aligned to match ozz's SIMD stores. Arrays of these must start on a
/// 16-byte boundary — `localToModel` rejects a misaligned destination.
pub const Mat4 = c.Float4x4;

pub const transform_identity: Transform = .{
    .translation = .{ 0, 0, 0 },
    .rotation = .{ 0, 0, 0, 1 },
    .scale = .{ 1, 1, 1 },
};

pub const mat4_identity: Mat4 = .{ .m = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
} };

test "identity constants are what their names claim" {
    try std.testing.expectEqual(@as(f32, 1), transform_identity.rotation[3]);
    try std.testing.expectEqual(@as(f32, 1), transform_identity.scale[0]);
    try std.testing.expectEqual(@as(f32, 1), mat4_identity.m[0]);
    try std.testing.expectEqual(@as(f32, 0), mat4_identity.m[1]);
    try std.testing.expectEqual(@as(f32, 1), mat4_identity.m[15]);
}
