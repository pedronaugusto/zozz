//! The OArchive write path: persisting a skeleton or an animation to a
//! stream a host controls, or straight to a file.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const Skeleton = @import("skeleton.zig").Skeleton;
const Animation = @import("animation.zig").Animation;

/// A host-provided sink standing in for ozz::io::Stream's write half — the
/// same role a Zig allocator plays for `c.Allocator` in `memory.zig`. Reused
/// verbatim rather than wrapped, the way `math.Transform` reuses `c.Transform`:
/// a Zig-side implementation fills this struct directly.
pub const Stream = c.Stream;

/// An archive bound to one `Stream`, open for writing.
///
/// Every archive is scoped to one logical file: `init`, save everything that
/// belongs together, `deinit`.
pub const OArchive = struct {
    handle: *c.OArchive,

    pub fn init(stream: *const Stream) err.Error!OArchive {
        var handle: *c.OArchive = undefined;
        try err.check(c.zozzOArchiveCreate(stream, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: OArchive) void {
        c.zozzOArchiveDestroy(self.handle);
    }

    /// Writes `data` untyped and unswapped, for framing custom data around
    /// the tagged objects below.
    pub fn saveBinary(self: OArchive, data: []const u8) err.Error!void {
        try err.check(c.zozzOArchiveSaveBinary(self.handle, data.ptr, data.len));
    }

    pub fn saveInt32(self: OArchive, value: i32) err.Error!void {
        try err.check(c.zozzOArchiveSaveInt32(self.handle, value));
    }

    pub fn saveFloat(self: OArchive, value: f32) err.Error!void {
        try err.check(c.zozzOArchiveSaveFloat(self.handle, value));
    }

    pub fn saveSkeleton(self: OArchive, skeleton: Skeleton) err.Error!void {
        try err.check(c.zozzOArchiveSaveSkeleton(self.handle, skeleton.handle));
    }

    pub fn saveAnimation(self: OArchive, animation: Animation) err.Error!void {
        try err.check(c.zozzOArchiveSaveAnimation(self.handle, animation.handle));
    }
};

/// Writes `skeleton` alone to a new file at `path`.
pub fn saveSkeletonToFile(skeleton: Skeleton, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzSkeletonSaveFile(skeleton.handle, path));
}

/// Writes `animation` alone to a new file at `path`.
pub fn saveAnimationToFile(animation: Animation, path: [*:0]const u8) err.Error!void {
    try err.check(c.zozzAnimationSaveFile(animation.handle, path));
}
