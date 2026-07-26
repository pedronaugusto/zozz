//! Bridges a Zig `std.mem.Allocator` onto ozz's global allocator seam.
//!
//! ## Why this is not a two-line shim
//!
//! ozz frees with `deallocate(block)` — no size, no alignment. Zig's allocator
//! interface requires both back at free time. The gap is closed by allocating
//! a little extra and stashing the length and alignment in a header placed
//! immediately before the pointer handed to ozz:
//!
//! ```text
//!   base                       returned pointer
//!    |                          |
//!    v                          v
//!   [ .... padding .... ][Header][ ..... payload ..... ]
//!    \___ prefix, a multiple of the requested alignment ___/
//! ```
//!
//! The prefix is rounded up to the requested alignment so the returned pointer
//! keeps that alignment, and the base pointer is recoverable by subtracting
//! the same rounded prefix at free time.
//!
//! ## Global state
//!
//! ozz's allocator is process-wide, so this one is too. That is a property of
//! ozz, not a shortcut taken here — it is surfaced rather than hidden behind
//! a per-object allocator parameter that could not be honoured.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");

/// Recorded ahead of every block so `deallocate` can reconstruct the slice
/// Zig's allocator needs.
const Header = struct {
    /// Total bytes handed out by the backing allocator, prefix included.
    total_len: usize,
    /// Alignment the backing allocation was made with, as a log2 value.
    alignment: std.mem.Alignment,
};

/// Bytes reserved before the payload for a given payload alignment: enough for
/// the header, rounded up so the payload stays aligned.
fn prefixSize(alignment: std.mem.Alignment) usize {
    const min = @max(@sizeOf(Header), @alignOf(Header));
    return alignment.forward(min);
}

/// The alignment the backing allocation must use: at least the caller's, and
/// at least what the header itself needs.
fn backingAlignment(alignment: std.mem.Alignment) std.mem.Alignment {
    return @enumFromInt(@max(
        @intFromEnum(alignment),
        @intFromEnum(std.mem.Alignment.of(Header)),
    ));
}

fn allocate(user: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(user orelse return null));

    // ozz documents alignment as a power of two; refuse anything else rather
    // than computing a bogus prefix from it.
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;

    const want = std.mem.Alignment.fromByteUnits(alignment);
    const backing = backingAlignment(want);
    const prefix = prefixSize(want);
    const total = std.math.add(usize, prefix, size) catch return null;

    const base = gpa.rawAlloc(total, backing, @returnAddress()) orelse return null;

    const payload = base + prefix;
    const header: *Header = @ptrCast(@alignCast(payload - @sizeOf(Header)));
    header.* = .{ .total_len = total, .alignment = backing };
    return @ptrCast(payload);
}

fn deallocate(user: ?*anyopaque, block: ?*anyopaque) callconv(.c) void {
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(user orelse return));
    const payload: [*]u8 = @ptrCast(block orelse return);

    const header: *const Header = @ptrCast(@alignCast(payload - @sizeOf(Header)));
    const total_len = header.total_len;
    const backing = header.alignment;

    // Recompute the prefix from the recorded BACKING alignment rather than
    // the caller's original request, which is not stored. The two agree:
    // prefixSize rounds a fixed minimum up to the alignment, and that minimum
    // is already a multiple of every alignment below it, so rounding to
    // max(requested, alignof(Header)) lands on the same value as rounding to
    // `requested`.
    const prefix = prefixSize(backing);
    const base = payload - prefix;
    gpa.rawFree(base[0..total_len], backing, @returnAddress());
}

/// The allocator ozz is currently pointed at, kept alive for as long as it is
/// installed. `user` in the C struct points at this.
var installed: std.mem.Allocator = undefined;

/// Routes every subsequent ozz allocation through `gpa`.
///
/// Process-wide. Call once during start-up, before loading anything, and do
/// not swap it while handles are alive — a handle is freed through whichever
/// allocator is installed when it is destroyed.
pub fn setAllocator(gpa: std.mem.Allocator) err.Error!void {
    installed = gpa;
    const bridge = c.Allocator{
        .allocate = allocate,
        .deallocate = deallocate,
        .user = @ptrCast(&installed),
    };
    try err.check(c.zozzSetAllocator(&bridge));
}

/// Restores ozz's built-in malloc/free allocator.
///
/// Only safe once every handle allocated through the Zig allocator has been
/// destroyed.
pub fn resetAllocator() void {
    _ = c.zozzSetAllocator(null);
}

test "allocator bridge round-trips every alignment ozz may ask for" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator();

    // Exercised through the C entry points so the test covers the real path,
    // not just the Zig helpers.
    var alignment: usize = 1;
    while (alignment <= 64) : (alignment *= 2) {
        const block = allocate(@ptrCast(&installed), 100, alignment) orelse {
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(@intFromPtr(block) % alignment == 0);
        // Write the payload so a too-small allocation trips the test allocator.
        const bytes: [*]u8 = @ptrCast(block);
        @memset(bytes[0..100], 0xAB);
        deallocate(@ptrCast(&installed), block);
    }
}

test "allocator bridge tolerates a zero-size request and a null free" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator();

    const block = allocate(@ptrCast(&installed), 0, 16) orelse {
        return error.TestUnexpectedResult;
    };
    deallocate(@ptrCast(&installed), block);
    deallocate(@ptrCast(&installed), null);
}

test "allocator bridge rejects a non-power-of-two alignment" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator();

    try std.testing.expect(allocate(@ptrCast(&installed), 32, 3) == null);
    try std.testing.expect(allocate(@ptrCast(&installed), 32, 0) == null);
}
