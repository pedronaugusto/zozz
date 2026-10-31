# The ABI guard

`src/c.zig` hand-writes the `extern` declarations for `ffi/zozz.h` rather than
running translate-c, so the wrapper gets the types it wants and the shipped
module never compiles C. Nothing in either compiler checks that those
declarations still agree with the header: a `size_t` narrowed to an `int` links
cleanly and corrupts. Three checks close that, on three different axes.

## `src/abi_test.zig` — the header against the declarations

The real header, translated by the build's translate-c step, compared against
`src/c.zig` by reflection: every struct field paired by name with its own offset, every
scalar's size, alignment, signedness and int-versus-float, every function's
arity and variadic-ness, every enumerator's value, every constant.

There is no hand-maintained list. Declarations are discovered by reflection,
and one the check cannot classify is a compile error rather than a silent pass.
It sweeps the other direction too, so a symbol the header exports that `c.zig`
never declares — or declares as something that is not an extern — fails as
well. The `@cImport` happens in a test only.

## `zozzAbiLayout()` — the compiled library against the declarations

The header is a source file and the library is a binary; they can describe
different structs while looking identical. This entry point asks the linked
translation unit what it really laid out. Neither check replaces the other.

## `static_assert`s in `ffi/zozz_abi.cpp` — ozz against the C++

These fail the build if a vendored ozz upgrade changes a type this package
casts to or from: the SoA pose, the blending layer, the transform and matrix
types.

## Proving the first check is not vacuous

`src/abi_test.zig` is the check that guards the other two, and it is the one
test here that cannot test itself — a refactor that quietly makes it vacuous
looks exactly like a passing build. `bay probe` applies the deliberate
drifts in `ci/probes/` one at a time and requires each to be refused, including
a field swap that leaves every offset in the struct unchanged and so defeats
any positional or offsets-only comparison.

It compares `src/c.zig` against the header *as preprocessed for a target*, so
firing on the Itanium ABI proves nothing about MSVC's, where a C enum is `int`
rather than `unsigned int` — a difference `ZozzResult` and
`ZozzTrackInterpolation` cross in signatures and in struct fields. A drift is
a compile error, so the check fires wherever the tests compile, and the gate
compiles them for `x86_64-windows-msvc` as well as the Itanium targets. The
probes run outside the gate, because each rebuilds the suite, and on the
host's ABI only.

## Naming is load-bearing

Because the check pairs declarations to the header by name, the naming
convention is a build requirement rather than a style preference, and no
enumerator may be negative. BINDING.md has the table and the reasons; a new
area has to follow it.
