# Adding surface to zozz

How a new area gets bound, written down so every one of them comes out the same
shape. This is the contract a change has to satisfy.

## Start with recon

```sh
tools/recon.sh BlendingJob
```

ozz is C++, and what decides whether a binding is correct is not in the
signatures — it is an `assert()` in a method body, a `Validate()` that rejects
what the signature suggests is fine, a span the job expects the caller to keep
alive, a private constructor. `tools/recon.sh` pulls those out with line
numbers: a page instead of a file. It is a lead generator, not an oracle.

## One entry point, all the way through

This is the whole pattern. Read it instead of reading another area.

`ffi/zozz_pose.h`
```c
ZOZZ_API ZozzResult zozzSoaPoseCreate(int num_joints, ZozzSoaPose** out);
```

`ffi/zozz_pose.cpp`
```cpp
ZozzResult zozzSoaPoseCreate(int num_joints, ZozzSoaPose** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;                       // clear the out BEFORE any failure
  if (num_joints <= 0 || num_joints > zozz::kMaxJoints) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  // ... allocate through ozz::memory::default_allocator(), which is the
  // host allocator once zozzSetAllocator has run.
}
```

`src/c.zig`
```zig
pub extern fn zozzSoaPoseCreate(num_joints: c_int, out: **SoaPose) Result;
```

`src/pose.zig`
```zig
pub fn init(num_joints: u32) err.Error!SoaPose {
    var handle: *c.SoaPose = undefined;
    try err.check(c.zozzSoaPoseCreate(@intCast(num_joints), &handle));
    return .{ .handle = handle };
}
```

`src/zozz.zig` — one re-export line. `build.zig` — the `.h` in the public
header list, the `.cpp` in the FFI source list, any new ozz `.cc` in
`ozz_runtime_sources` or `ozz_offline_sources`. Those lists are explicit, never
globs: a re-vendor must not silently start compiling something new.

## Do not read anything else

Startup reading is the largest cost in binding an area and almost all of it is
wasted. **Read this file, run `tools/recon.sh` on your classes, then write.**
Do not read `README.md`, do not read `git log`, do not open another area "for
style" — the style is above. Do not open an ozz header that recon already
summarised unless recon pointed you at a line in it.

## Naming, which is load-bearing

`src/abi_check.zig` pairs the two sides by name with **no hand-maintained
list**, so a name that breaks convention is a build failure, not a style nit:

| Zig side | C side |
|---|---|
| type `Foo` | `ZozzFoo` |
| function `zozzFoo` | `zozzFoo` |
| constant `foo_bar` | `ZOZZ_FOO_BAR` |
| enum `Foo`'s field `bar` | `ZOZZ_FOO_BAR` |

Enumerators take the **full type name**: `ZOZZ_RESULT_ERR_IO`, never
`ZOZZ_ERR_IO`. translate-c flattens a C enum to a plain integer alias, so the
strict prefix is the only thing that can pair an enumerator back to its enum.

**No enumerator may be negative.** C leaves an enum's underlying type to the
implementation and the implementations disagree — clang and gcc pick unsigned
when no enumerator is negative, MSVC uses `int`. Every value being non-negative
is what makes that unobservable, and the guard enforces it. Need a negative
sentinel? Use a fixed-width constant, the way `ZOZZ_NO_PARENT` is one — and put
it in `src/c.zig`, because the guard only walks that file.

## The C ABI

- **Every fallible entry point returns `ZozzResult`** and delivers its answer
  through an out-parameter. Infallible ones return the value directly.
- **Clear every out-parameter before the first failure return**, so a refused
  call leaves the caller's outputs defined rather than untouched.
- **Reject null pointers** with `ZOZZ_RESULT_INVALID_ARGUMENT`.
- **A job's `Validate()` returning false is a real error path**, not an
  assertion. Map it to **`ZOZZ_RESULT_JOB_INVALID`**, which exists for exactly
  that and is what the rest of the package already returns — ozz jobs check
  their own spans and will happily run garbage if you skip it.
  `ZOZZ_RESULT_INVALID_ARGUMENT` is for what *this* layer rejects: a null
  handle, a negative count, a NaN. Keeping the two apart is what lets a caller
  tell "you passed me nonsense" from "ozz would not accept this job".
- **The declared surface never depends on build options.** A header whose
  contents move with a `-D` flag cannot be checked.
- **Allocate through `ozz::memory::default_allocator()`**, never `new` or
  `malloc`. That allocator is the host's once `zozzSetAllocator` has run, and
  the suite fails on an unbalanced seam.
- **Spans do not own.** ozz jobs take `ozz::span` into memory the caller owns;
  the C boundary takes a pointer and a count and must document who keeps it
  alive across the call.
- **Nothing may unwind out of a callback**, and a Zig callback must never
  return a Zig error across the C boundary — stash it in the user context and
  re-raise after the call returns.

## The Zig wrapper

- Turn `ZozzResult` into `Error!T` with `err.check`.
- Turn count-then-fill pairs into slices; take an allocator explicitly.
- Never widen a lifetime the C side did not promise.
- Document what ozz actually does, not what would be tidy.

## Before you call it done

`zig build test` is the bar. It is your compile, and it runs the ABI
cross-check and the allocator-balance assertions for free.
