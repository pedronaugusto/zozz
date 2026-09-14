# The allocator seam

How `setAllocator` is wired underneath, for anyone changing `src/memory.zig`,
`ffi/zozz_core.cpp` or the rules the README states. The caller-facing rules are
in README.md under Design; this file is the mechanism behind them.

## Why it is process-wide

ozz's allocator is a single global (`ozz::memory::default_allocator()`,
`include/ozz/base/memory/allocator.h`). Every ozz allocation goes through it,
and no ozz entry point takes an allocator parameter. A per-object allocator on
this side would be a parameter zozz could not honour, so the seam is surfaced
with the shape ozz gives it.

## The block header

ozz frees with `deallocate(block)` — no size, no alignment. Zig's
`std.mem.Allocator` requires both at free. `src/memory.zig` stores a header
ahead of every block holding the length, the alignment and the allocator the
block came from.

The recorded allocator is what makes swapping one Zig allocator for another
safe with blocks outstanding: each block frees through its own producer rather
than through whoever is installed at destruction time.

## Why zozz takes ozz's global slot at start-up

Below the Zig layer the C seam holds one `ZozzAllocator`, so it cannot route a
free back to a producer. `zozzSetAllocator` therefore refuses any call that
would change where a free lands, reporting `ZOZZ_RESULT_ALLOCATOR_IN_USE` for
as long as `zozzAllocatorLiveBlocks()` is non-zero.

That refusal is only meaningful if the counter sees every outstanding block,
including the ones ozz's own allocator handed out before a host was installed.
ozz frees through whichever allocator is installed at destruction, not through
the one that made the block, so a skeleton loaded before `setAllocator` and
destroyed after it would hand malloc'd memory to the Zig bridge. zozz occupies
ozz's global allocator slot from the start of the process and forwards to ozz's
own allocator until a host arrives; the count is then total and the refusal
holds in both directions. CHANGELOG.md 0.5.0 has the failure this fixed.

A call that leaves the same allocator in place is not a change of destination:
reinstalling the identical allocator, or resetting while none is installed,
succeeds with blocks live.

## Thread safety

Every entry point that allocates arrives at this one seam, so distinct handles
may be used concurrently as long as the installed allocator is thread-safe. A
single handle is not internally synchronised, and neither is installing or
resetting the allocator.

`src/concurrency_test.zig` runs it: four threads, each with its own sampling
context, poses and matrices, sharing one skeleton and one clip, creating and
destroying handles for two hundred frames each against a `DebugAllocator` that
accounts for every block.

## The C host

The C API keeps ozz's shape, so a plain C host passes `malloc` and `free` in
two lines. The live-block counter doubles as a leak check for a host whose own
allocator has none.
