//! Bridges a Zig `std.mem.Allocator` onto ozz's global allocator seam.
//!
//! ozz frees with `deallocate(block)` — no size, no alignment — but Zig's
//! allocator interface requires both back at free time. The gap is closed by
//! allocating a little extra and stashing the length, the alignment and the
//! allocator itself in a header placed immediately before the pointer handed
//! to ozz, in a prefix rounded up to the requested alignment so the returned
//! pointer keeps it; subtracting that prefix recovers the base.
//!
//! ozz's allocator is process-wide, so this one is too — surfaced rather than
//! hidden behind a per-object parameter that could not be honoured. Thread
//! safety follows: two threads may use zozz at once only if the allocator
//! installed here is thread-safe, since every allocation arrives at this one
//! seam, and installing is not itself synchronised.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");

/// Recorded ahead of every block so `deallocate` can reconstruct the slice
/// Zig's allocator needs, and reach the allocator that produced it.
const Header = struct {
    /// Total bytes handed out by the backing allocator, prefix included.
    total_len: usize,
    /// Alignment the backing allocation was made with, as a log2 value.
    alignment: std.mem.Alignment,
    /// The allocator this block came from. ozz's seam holds ONE allocator at a
    /// time, so a block outstanding across a swap would otherwise be freed
    /// through whichever is installed at destruction — a free against a heap
    /// that never allocated it. Carrying the producer per block makes a swap
    /// between two Zig allocators correct rather than merely discouraged, and
    /// costs two pointers in a header already paid for.
    gpa: std.mem.Allocator,
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
    header.* = .{ .total_len = total, .alignment = backing, .gpa = gpa.* };
    return @ptrCast(payload);
}

fn deallocate(user: ?*anyopaque, block: ?*anyopaque) callconv(.c) void {
    // `user` is deliberately unread: the block's own header names the
    // allocator that produced it, which is not necessarily the one installed
    // now.
    _ = user;
    const payload: [*]u8 = @ptrCast(block orelse return);

    const header: *const Header = @ptrCast(@alignCast(payload - @sizeOf(Header)));
    const total_len = header.total_len;
    const backing = header.alignment;
    const gpa = header.gpa;

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

/// Routes every subsequent ozz allocation through `gpa`. Process-wide, and to
/// be called at start-up. Swapping one Zig allocator for another is safe with
/// blocks outstanding — each records its own — but `error.AllocatorInUse` if
/// some other allocator installed through the C seam still has blocks live.
/// `installed` is written only after the seam accepts the bridge, so a refused
/// call leaves the previous one readable.
pub fn setAllocator(gpa: std.mem.Allocator) err.Error!void {
    const bridge = c.Allocator{
        .allocate = allocate,
        .deallocate = deallocate,
        .user = @ptrCast(&installed),
    };
    try err.check(c.zozzSetAllocator(&bridge));
    installed = gpa;
}

/// Restores ozz's built-in malloc/free allocator.
///
/// Fails with `error.AllocatorInUse` while any block allocated through the
/// installed allocator is still live: ozz's own `free` would be handed a block
/// it never malloc'd. Destroy every handle first — `liveBlocks` says how many
/// are outstanding.
pub fn resetAllocator() err.Error!void {
    try err.check(c.zozzSetAllocator(null));
}

/// Blocks the installed allocator has handed out and not yet freed. Zero
/// before the first `setAllocator` and zero again once everything allocated
/// through it is destroyed, which makes it a leak check for a host whose own
/// allocator has none.
pub fn liveBlocks() usize {
    return c.zozzAllocatorLiveBlocks();
}

/// Reads back the raw `c.Allocator` `setAllocator` most recently installed —
/// `null` if none is. No equivalent returns a `std.mem.Allocator`. Same
/// save-and-restore `zozzGetAllocator` documents in zozz_core.h: read here
/// before installing a temporary allocator (via `c.zozzSetAllocator`, for a
/// non-Zig one), then pass the result back afterward. That sequence can only
/// start while nothing is live, since a different allocator is refused.
pub fn getAllocator() err.Error!?c.Allocator {
    var out: c.Allocator = undefined;
    var is_installed: bool = undefined;
    try err.check(c.zozzGetAllocator(&out, &is_installed));
    return if (is_installed) out else null;
}

test "allocator bridge round-trips every alignment ozz may ask for" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator() catch unreachable;

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
    defer resetAllocator() catch unreachable;

    const block = allocate(@ptrCast(&installed), 0, 16) orelse {
        return error.TestUnexpectedResult;
    };
    deallocate(@ptrCast(&installed), block);
    deallocate(@ptrCast(&installed), null);
}

test "allocator bridge rejects a non-power-of-two alignment" {
    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator() catch unreachable;

    try std.testing.expect(allocate(@ptrCast(&installed), 32, 3) == null);
    try std.testing.expect(allocate(@ptrCast(&installed), 32, 0) == null);
}

test "getAllocator distinguishes a never-installed state from the exact allocator installed" {
    // Restore to a known baseline first: another test earlier in this file
    // may have left an allocator installed.
    try resetAllocator();
    try std.testing.expect((try getAllocator()) == null);

    const gpa = std.testing.allocator;
    try setAllocator(gpa);
    defer resetAllocator() catch unreachable;

    const got = (try getAllocator()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(got.allocate != null);
    try std.testing.expect(got.allocate.? == &allocate);
    try std.testing.expect(got.deallocate != null);
    try std.testing.expect(got.deallocate.? == &deallocate);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&installed)), got.user);

    try resetAllocator();
    try std.testing.expect((try getAllocator()) == null);
}

test "a block outstanding across a swap is freed by the allocator that produced it" {
    // Two allocators that each account for their own blocks, so a free landing
    // on the wrong one is not a matter of opinion: the producer reports a leak
    // and the other reports a free it never issued.
    var first: std.heap.DebugAllocator(.{}) = .init;
    var second: std.heap.DebugAllocator(.{}) = .init;

    try resetAllocator();
    try setAllocator(first.allocator());

    const block = allocate(@ptrCast(&installed), 128, 16) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, 0), liveBlocks());

    // The swap is the same ZozzAllocator either way — same two functions, same
    // `user` — so the seam accepts it, and the header is what keeps it sound.
    try setAllocator(second.allocator());
    deallocate(@ptrCast(&installed), block);

    try resetAllocator();
    try std.testing.expectEqual(std.heap.Check.ok, first.deinit());
    try std.testing.expectEqual(std.heap.Check.ok, second.deinit());
}

test "the seam refuses to change allocator while blocks it produced are live" {
    const gpa = std.testing.allocator;
    try resetAllocator();
    try setAllocator(gpa);

    // Allocated through ozz's own seam, so the counter sees it: a raw call to
    // `allocate` here would bypass the adapter that does the counting.
    const context = try @import("sampling.zig").SamplingContext.init(8);
    try std.testing.expect(liveBlocks() > 0);

    try std.testing.expectError(error.AllocatorInUse, resetAllocator());

    // The refusal left the allocator installed, so the handle still frees
    // through the allocator that produced it.
    context.deinit();
    try std.testing.expectEqual(@as(usize, 0), liveBlocks());
    try resetAllocator();
}
