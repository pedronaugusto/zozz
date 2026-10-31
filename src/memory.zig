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
const aegis = @import("aegis");
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
    return @fromBackingInt(@max(
        @backingInt(alignment),
        @backingInt(std.mem.Alignment.of(Header)),
    ));
}

/// The allocator `user` guards, copied out under its lock so the allocation
/// itself runs outside it.
fn installedAllocator(user: *anyopaque) std.mem.Allocator {
    const owner: *aegis.Guarded(std.mem.Allocator) = @ptrCast(@alignCast(user)); // aegis: no-danger: user is &installed, which setAllocator hands the C side
    var held = owner.acquire();
    defer held.deinit();
    return held.value().*;
}

fn allocate(user: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const gpa = installedAllocator(user orelse return null);

    // ozz documents alignment as a power of two; refuse anything else rather
    // than computing a bogus prefix from it.
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;

    const want = std.mem.Alignment.fromByteUnits(alignment);
    const backing = backingAlignment(want);
    const prefix = prefixSize(want);
    const total = std.math.add(usize, prefix, size) catch return null;

    const base = gpa.rawAlloc(total, backing, @returnAddress()) orelse return null;

    const payload = base + prefix;
    const header: *Header = @ptrCast(@alignCast(payload - @sizeOf(Header))); // aegis: no-danger: the header slot allocate reserves in front of every payload, aligned by backingAlignment
    header.* = .{ .total_len = total, .alignment = backing, .gpa = gpa };
    return @ptrCast(payload); // aegis: no-danger: the payload, as the seam's untyped pointer
}

fn deallocate(user: ?*anyopaque, block: ?*anyopaque) callconv(.c) void {
    // `user` is deliberately unread: the block's own header names the
    // allocator that produced it, which is not necessarily the one installed
    // now.
    _ = user;
    const payload: [*]u8 = @ptrCast(block orelse return); // aegis: no-danger: a block allocate issued, as its bytes

    const header: *const Header = @ptrCast(@alignCast(payload - @sizeOf(Header))); // aegis: no-danger: the header slot allocate reserves in front of every payload, aligned by backingAlignment
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
/// installed. `user` in the C struct points at this. ozz's hook is
/// process-wide and read on whichever thread allocates, so the allocator sits
/// behind a lock, held only to copy it in or out.
var installed: aegis.Guarded(std.mem.Allocator) = .init(undefined);

/// Routes every subsequent ozz allocation through `gpa`. Process-wide, and to
/// be called at start-up. Swapping one Zig allocator for another is safe with
/// blocks outstanding — each records its own — but `error.AllocatorInUse` if
/// any other allocator, ozz's own built-in one included, still has blocks
/// live. `installed` is written only after the seam accepts the bridge, so a
/// refused call leaves the previous one readable.
pub fn setAllocator(gpa: std.mem.Allocator, failure: *err.Failure) err.Error!void {
    const bridge = c.Allocator{
        .allocate = allocate,
        .deallocate = deallocate,
        .user = @ptrCast(&installed), // aegis: no-danger: the guarded allocator's address, which allocate reads back
    };
    try err.check(failure, .set_allocator, c.zozzSetAllocator(&bridge));
    var held = installed.acquire();
    defer held.deinit();
    held.value().* = gpa;
}

/// Restores ozz's built-in malloc/free allocator. `error.AllocatorInUse`
/// while any block from the installed allocator is still live: ozz's own
/// `free` would be handed a block it never malloc'd. Destroy every handle
/// first — `liveBlocks` says how many are outstanding. A reset while none is
/// installed changes nothing and always succeeds.
pub fn resetAllocator(failure: *err.Failure) err.Error!void {
    try err.check(failure, .set_allocator, c.zozzSetAllocator(null));
}

/// Blocks ozz has been handed and has not yet freed — through the installed
/// allocator, or through ozz's own built-in one while none is installed. Zero
/// again once every handle is destroyed, which makes it a leak check for a
/// host whose own allocator has none, and it is what refuses an allocator
/// swap: every outstanding block must be freed by the allocator that produced
/// it, and nothing below this layer records which one that was.
pub fn liveBlocks() usize {
    return c.zozzAllocatorLiveBlocks();
}

/// The raw `c.Allocator` `setAllocator` most recently installed, `null` if
/// none is; no equivalent returns a `std.mem.Allocator`. Read it before
/// installing a temporary non-Zig one via `c.zozzSetAllocator`, then pass it
/// back (the save-and-restore zozz_core.h documents), which can only start
/// while nothing is live. Never fails: the seam refuses only a null
/// out-pointer, and this passes none.
pub fn getAllocator() ?c.Allocator {
    var out: c.Allocator = undefined;
    var is_installed: bool = undefined;
    err.map(c.zozzGetAllocator(&out, &is_installed)) catch aegis.assert.never("zozz: zozzGetAllocator refused two live out-pointers");
    return if (is_installed) out else null;
}

test "allocator bridge round-trips every alignment ozz may ask for" {
    const gpa = std.testing.allocator;
    var failure: err.Failure = .{};
    try setAllocator(gpa, &failure);
    defer resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

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
    var failure: err.Failure = .{};
    try setAllocator(gpa, &failure);
    defer resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const block = allocate(@ptrCast(&installed), 0, 16) orelse {
        return error.TestUnexpectedResult;
    };
    deallocate(@ptrCast(&installed), block);
    deallocate(@ptrCast(&installed), null);
}

test "allocator bridge rejects a non-power-of-two alignment" {
    const gpa = std.testing.allocator;
    var failure: err.Failure = .{};
    try setAllocator(gpa, &failure);
    defer resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    try std.testing.expect(allocate(@ptrCast(&installed), 32, 3) == null);
    try std.testing.expect(allocate(@ptrCast(&installed), 32, 0) == null);
}

test "getAllocator distinguishes a never-installed state from the exact allocator installed" {
    // Restore to a known baseline first: another test earlier in this file
    // may have left an allocator installed.
    var failure: err.Failure = .{};
    try resetAllocator(&failure);
    try std.testing.expect(getAllocator() == null);

    const gpa = std.testing.allocator;
    try setAllocator(gpa, &failure);
    defer resetAllocator(&failure) catch |e| std.debug.panic("zozz: {s}", .{@errorName(e)});

    const got = getAllocator() orelse return error.TestUnexpectedResult;
    try std.testing.expect(got.allocate != null);
    try std.testing.expect(got.allocate.? == &allocate);
    try std.testing.expect(got.deallocate != null);
    try std.testing.expect(got.deallocate.? == &deallocate);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&installed)), got.user);

    try resetAllocator(&failure);
    try std.testing.expect(getAllocator() == null);
}

test "a block outstanding across a swap is freed by the allocator that produced it" {
    // Two allocators that each account for their own blocks, so a free landing
    // on the wrong one is not a matter of opinion: the producer reports a leak
    // and the other, whose canary differs, panics on a block it never issued.
    var first: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .canary = 0x1f1f1f1f });
    var second: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .canary = 0x2e2e2e2e });

    var failure: err.Failure = .{};
    try resetAllocator(&failure);
    try setAllocator(first.allocator(), &failure);

    const block = allocate(@ptrCast(&installed), 128, 16) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, 0), liveBlocks());

    // The swap is the same ZozzAllocator either way — same two functions, same
    // `user` — so the seam accepts it, and the header is what keeps it sound.
    try setAllocator(second.allocator(), &failure);
    deallocate(@ptrCast(&installed), block);

    try resetAllocator(&failure);
    try std.testing.expectEqual(@as(usize, 0), first.deinit());
    try std.testing.expectEqual(@as(usize, 0), second.deinit());
}

test "the seam refuses to change allocator while blocks it produced are live" {
    const gpa = std.testing.allocator;
    var failure: err.Failure = .{};
    try resetAllocator(&failure);
    try setAllocator(gpa, &failure);

    // Allocated through ozz's own seam, so the counter sees it: a raw call to
    // `allocate` here would bypass the adapter that does the counting.
    var context = try @import("sampling.zig").SamplingContext.init(8, &failure);
    try std.testing.expect(liveBlocks() > 0);

    try std.testing.expectError(error.AllocatorInUse, resetAllocator(&failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .set_allocator, .result = .allocator_in_use }}, failure.frames());

    // The refusal left the allocator installed, so the handle still frees
    // through the allocator that produced it.
    context.deinit();
    try std.testing.expectEqual(@as(usize, 0), liveBlocks());
    try resetAllocator(&failure);
}

test "the seam refuses to install an allocator while ozz's own blocks are live" {
    // The reverse ordering of the test above, and the one that has no header
    // to fall back on: the block below is ozz's own malloc'd memory, and
    // `ozz::Delete` frees through whichever allocator is installed when the
    // handle is destroyed, not through the one that produced the block. Were
    // the install allowed here, `deinit` would hand a malloc'd pointer to the
    // Zig bridge, which would read the bytes ahead of it as a header.
    var failure: err.Failure = .{};
    try resetAllocator(&failure);
    try std.testing.expect(getAllocator() == null);

    var context = try @import("sampling.zig").SamplingContext.init(8, &failure);
    try std.testing.expect(liveBlocks() > 0);

    try std.testing.expectError(error.AllocatorInUse, setAllocator(std.testing.allocator, &failure));
    try std.testing.expectEqualSlices(err.Frame, &.{.{ .call = .set_allocator, .result = .allocator_in_use }}, failure.frames());
    // Refused means untouched: still ozz's own allocator, which is what the
    // handle needs.
    try std.testing.expect(getAllocator() == null);

    context.deinit();
    try std.testing.expectEqual(@as(usize, 0), liveBlocks());
}
