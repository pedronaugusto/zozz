//! A file load's one read, through `std.Io`: the whole `.ozz` image, which
//! the loader then parses as a memory load does. No C stdio sits under the
//! Zig API; the C ABI's file entry points are a C host's.

const std = @import("std");
const aegis = @import("aegis");
const err = @import("error.zig");

/// The most bytes a file load reads. A file holding more is refused before
/// ozz sees any of it.
pub const Limit = aegis.units.Bytes(u64);

/// The `.ozz` image at `sub_path` in `dir`, at most `limit` bytes of it, read
/// through `io` into a block from `gpa` the caller frees. A refusal names
/// `call`: `FileNotFound`; `OutOfMemory`; `BadFormat` for a file over `limit`,
/// its record naming `File.length` with a value one past `limit`; or
/// `ReadFailed` for any other failure to read it.
pub fn readImage(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, limit: Limit, call: err.Call, failure: *err.Failure) err.Error![]u8 {
    return aegis.own.readFile(io, dir, sub_path, gpa, limit) catch |e| switch (e) {
        error.FileNotFound => err.refuse(failure, call, err.Error.FileNotFound),
        error.OutOfMemory => err.refuse(failure, call, err.Error.OutOfMemory),
        error.StreamTooLong => err.refuseRecorded(failure, call, err.Error.BadFormat, "File.length", limit.raw() +| 1, limit.raw()),
        else => err.refuse(failure, call, err.Error.ReadFailed),
    };
}
