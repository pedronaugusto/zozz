# Validation at the boundary

What the loaders check, and why each check is there. The short version is in
README.md under Design; the upstream sites are in UPSTREAM.md with file and
line.

## What ozz does not check

`IArchive::operator>>` for a primitive is `Read(&v, sizeof(v))` followed by
`assert(size == sizeof(v))`. Under `NDEBUG` that assert is gone, so a short
read leaves `v` holding stack garbage and parsing continues — and a count read
that way decides how much ozz allocates and copies. The tag check is an assert
too. An unsupported archive version is logged and leaves an empty object with
no error returned.

## What the loaders add

**Tag test before parsing.** Wrong-type or non-ozz input is `BadFormat`, not a
parse of unrelated bytes.

**Truncation detection.** Every archive, files included, is parsed through
`ConstMemoryStream`, which satisfies each read in full, zero-fills past the end
and latches a flag the loader checks. Zeros are the safe filler: a zeroed count
is zero, so ozz's loops do nothing rather than run wild, and no
partially-overwritten count can round upward. Files are buffered whole rather
than handed to ozz's own `File` stream, precisely because that stream returns
the short reads ozz fails to check.

**Sanity check after parsing.** Joint counts within ozz's own limit, arrays of
consistent length, positive duration. This is what turns a version-mismatched
clip into `BadFormat` instead of a zero-duration animation that samples to
garbage.

**Checked allocation.** `ozz::New` is a placement-new on an unchecked
allocation, so a failed allocation constructs at address zero.
`ffi/zozz_internal.h` replaces it with a checked version, which is what makes
the `OutOfMemory` paths reachable rather than decorative.

That last one does not cover ozz's own internal allocations. `Skeleton` and
`Animation` each build spans over an unchecked `Allocate` and write through
them, so a load under memory pressure is a null dereference inside ozz. There
is no position from which to intercept it; UPSTREAM.md records it. Sampling,
once loaded, allocates nothing.

## What is tested

Every prefix of a valid archive, across both fixtures, is verified to be
rejected, and the whole archives still load. NaN ratios and misaligned matrix
buffers are refused rather than faulting inside SIMD code.

## What it does not cover

ozz's parser is not hardened against arbitrary hostile input, and zozz cannot
make it so from the outside. What holds here is that truncation and type
confusion fail cleanly and deterministically, with counts bounded rather than
attacker-influenced. To load `.ozz` from an untrusted source, put a
length-and-checksum container around it and validate that first.
