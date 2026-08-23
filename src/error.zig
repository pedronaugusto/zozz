//! Translation between the C result enum and a Zig error set.

const std = @import("std");
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
    /// A null handle, a negative count, a NaN, or a misaligned buffer.
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
};

/// Turns a C result into a Zig error, or void on success.
///
/// The switch is exhaustive over `c.Result` with no `else` branch: adding a
/// result to the C enum without handling it here is a compile error, which is
/// the property `AbiLayout.result_count` also checks at runtime.
pub fn check(result: c.Result) Error!void {
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
    };
}

/// Borrowed, static description of a result, for logging.
pub fn name(result: c.Result) [:0]const u8 {
    return std.mem.span(c.zozzResultName(result));
}
