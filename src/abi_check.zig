//! Comptime cross-check: the hand-written externs in `c.zig` against the real C
//! header, `@cImport`-ed in a test only (the shipped module stays
//! translate-c-free). Every public declaration in `c.zig` is discovered by
//! reflection, paired with its counterpart by naming convention, and compared
//! — a declaration fitting no category is a compile error, not a silent pass.
//! Naming pairs: type `Foo` -> `ZozzFoo`; function `zozzFoo` -> itself;
//! constant `foo_bar` -> `ZOZZ_FOO_BAR`; enum `Foo` field `bar` ->
//! `ZOZZ_FOO_BAR`.
//! Pointee types compare only by size/alignment (translate-c's `[*c]T` vs
//! `c.zig`'s intended pointer form are not compared directly) —
//! `tests/c_smoke.c` covers that residue. This also checks against this build's
//! *header*, not its *library*; `zozzAbiLayout` (see `zozz.zig`) covers that
//! axis instead. `zozz.h` defines nothing inline, so an inline helper added
//! later needs an explicit skip list, not a loosened filter.

const std = @import("std");
const c = @import("c.zig");

const h = @cImport({
    @cInclude("zozz.h");
});

//=============================================================================
// Name conventions, computed rather than tabulated
//=============================================================================

/// `AbiLayout` -> `ABI_LAYOUT`, `no_parent` -> `NO_PARENT`.
fn screaming(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var prev_lower = false;
        for (name) |ch| {
            if (std.ascii.isUpper(ch)) {
                if (prev_lower) out = out ++ "_";
                out = out ++ [_]u8{ch};
                prev_lower = false;
            } else if (ch == '_') {
                out = out ++ "_";
                prev_lower = false;
            } else {
                out = out ++ [_]u8{std.ascii.toUpper(ch)};
                prev_lower = true;
            }
        }
        return out;
    }
}

fn typeCName(comptime name: []const u8) []const u8 {
    return "Zozz" ++ name;
}

fn constCName(comptime name: []const u8) []const u8 {
    return "ZOZZ_" ++ screaming(name);
}

fn fieldCName(comptime type_name: []const u8, comptime field_name: []const u8) []const u8 {
    return "ZOZZ_" ++ screaming(type_name) ++ "_" ++ screaming(field_name);
}

//=============================================================================
// Comparison primitives
//
// Every failure is a compile error naming both sides, because a build that
// cannot state which declaration drifted is a guard that costs more to read
// than the drift it found.
//=============================================================================

fn fail(comptime msg: []const u8) void {
    @compileError("zozz ABI drift: " ++ msg);
}

fn theirDecl(comptime name: []const u8, comptime because: []const u8) type {
    if (!@hasDecl(h, name)) {
        fail("`" ++ because ++ "` in src/c.zig expects `" ++ name ++
            "` in ffi/zozz.h, which does not declare it");
    }
    return @TypeOf(@field(h, name));
}

fn sameSizeAndAlign(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
) void {
    if (@sizeOf(Ours) != @sizeOf(Theirs)) {
        fail(what ++ " is " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(Ours)}) ++
            " bytes in src/c.zig but " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(Theirs)}) ++
            " in ffi/zozz.h");
    }
    if (@alignOf(Ours) != @alignOf(Theirs)) {
        fail(what ++ " has alignment " ++ std.fmt.comptimePrint("{d}", .{@alignOf(Ours)}) ++
            " in src/c.zig but " ++ std.fmt.comptimePrint("{d}", .{@alignOf(Theirs)}) ++
            " in ffi/zozz.h");
    }
}

/// The scalar a type really is at the boundary, with the Zig-side wrapper
/// removed. translate-c renders a C enum as a plain integer alias while this
/// side keeps e.g. `Result` as `enum(c_int)`; comparing those as-is would
/// report false drift on every enum, so each resolves to its backing integer
/// first. Not a loosening: an `enum(u32)` paired with a C `int` enum is a real
/// signedness disagreement, and resolving to backing integers surfaces it.
fn scalarIdentity(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| e.tag_type,
        .@"struct" => |st| st.backing_integer orelse T,
        else => T,
    };
}

/// Size and alignment, plus the part of a scalar's identity they do not
/// carry: two same-width integers are interchangeable to `@sizeOf`, so a
/// `uint32_t` field declared as `i32` (or a `float` as `u32`) would pass a
/// size/alignment check and silently reinterpret every value. Comparing
/// signedness and int-vs-float closes that gap, applied wherever a type
/// crosses the boundary — fields, parameters, returns — not just typedefs.
fn sameScalar(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
) void {
    sameSizeAndAlign(what, Ours, Theirs);

    const oi = @typeInfo(scalarIdentity(Ours));
    const ti = @typeInfo(scalarIdentity(Theirs));

    // Signedness, EXCEPT across an enum: C leaves an enum's underlying type to
    // the implementation, and implementations disagree (clang/gcc pick unsigned
    // when no enumerator is negative, MSVC uses `int`), so comparing it would
    // fail a correct binding on one toolchain and pass it on another. Skipping
    // it is safe only because every enumerator in this ABI is non-negative;
    // `checkEnumValues` asserts that precondition rather than assuming it.
    const across_enum = scalarIdentity(Ours) != Ours or scalarIdentity(Theirs) != Theirs;
    if (!across_enum and oi == .int and ti == .int and
        oi.int.signedness != ti.int.signedness)
    {
        fail(what ++ " is " ++ @tagName(oi.int.signedness) ++ " in src/c.zig but " ++
            @tagName(ti.int.signedness) ++ " in ffi/zozz.h");
    }
    if ((oi == .int) != (ti == .int) or (oi == .float) != (ti == .float)) {
        fail(what ++ " is a " ++ @tagName(oi) ++ " in src/c.zig but a " ++
            @tagName(ti) ++ " in ffi/zozz.h");
    }
}

/// Compares two function types by the only things translate-c preserves:
/// how many parameters there are, how each one is passed, and whether the
/// signature is variadic.
fn checkFnType(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
) void {
    const ours = @typeInfo(Ours).@"fn";
    const theirs = @typeInfo(Theirs).@"fn";

    if (ours.params.len != theirs.params.len) {
        fail(what ++ " takes " ++ std.fmt.comptimePrint("{d}", .{ours.params.len}) ++
            " parameters in src/c.zig but " ++ std.fmt.comptimePrint("{d}", .{theirs.params.len}) ++
            " in ffi/zozz.h");
    }
    if (ours.is_var_args != theirs.is_var_args) {
        fail(what ++ " is variadic on one side of the boundary only");
    }

    inline for (ours.params, theirs.params, 0..) |op, tp, i| {
        const OP = op.type orelse fail(what ++ " has an untyped parameter in src/c.zig");
        const TP = tp.type orelse fail(what ++ " has an untyped parameter in ffi/zozz.h");
        sameScalar(
            what ++ " parameter " ++ std.fmt.comptimePrint("{d}", .{i}),
            OP,
            TP,
        );
    }

    const OR = ours.return_type orelse fail(what ++ " has no return type in src/c.zig");
    const TR = theirs.return_type orelse fail(what ++ " has no return type in ffi/zozz.h");
    sameScalar(what ++ " return value", OR, TR);
}

/// Struct layout, compared field by NAME rather than by position — the
/// distinction that makes the check worth having. Two same-sized fields
/// swapping places leaves the *sequence* of offsets identical, so a
/// positional comparison (or a digest folded over offsets alone) passes a
/// swap that silently reinterprets both. `ZozzTransform`'s `translation`
/// and `scale` are exactly that pair; pairing name with offset catches it.
fn checkStructLayout(
    comptime what: []const u8,
    comptime Ours: type,
    comptime Theirs: type,
) void {
    sameSizeAndAlign(what, Ours, Theirs);

    const ours = @typeInfo(Ours).@"struct";
    const theirs = switch (@typeInfo(Theirs)) {
        .@"struct" => |s| s,
        else => fail(what ++ " is a struct in src/c.zig but not in ffi/zozz.h"),
    };

    if (ours.fields.len != theirs.fields.len) {
        fail(what ++ " has " ++ std.fmt.comptimePrint("{d}", .{ours.fields.len}) ++
            " fields in src/c.zig but " ++ std.fmt.comptimePrint("{d}", .{theirs.fields.len}) ++
            " in ffi/zozz.h");
    }

    inline for (ours.fields) |f| {
        if (!@hasField(Theirs, f.name)) {
            fail(what ++ " has field `" ++ f.name ++ "` in src/c.zig, which ffi/zozz.h does not");
        }
        if (@offsetOf(Ours, f.name) != @offsetOf(Theirs, f.name)) {
            fail(what ++ "." ++ f.name ++ " is at byte " ++
                std.fmt.comptimePrint("{d}", .{@offsetOf(Ours, f.name)}) ++ " in src/c.zig but " ++
                std.fmt.comptimePrint("{d}", .{@offsetOf(Theirs, f.name)}) ++ " in ffi/zozz.h");
        }
        sameScalar(
            what ++ "." ++ f.name,
            f.type,
            @FieldType(Theirs, f.name),
        );
    }
}

/// Enumerator values, paired by the `ZOZZ_<TYPE>_<FIELD>` convention.
///
/// translate-c flattens a C enum to an integer alias and loses which
/// enumerators belonged to it, so the values cannot be recovered from the type.
/// The convention is what puts them back together — and it is why the header's
/// enumerators are named strictly, with no readable-but-irregular exceptions.
fn checkEnumValues(
    comptime what: []const u8,
    comptime Ours: type,
    comptime ours_name: []const u8,
) void {
    inline for (@typeInfo(Ours).@"enum".fields) |f| {
        const cname = fieldCName(ours_name, f.name);
        _ = theirDecl(cname, what ++ "." ++ f.name);
        // The precondition that lets sameScalar skip signedness across an
        // enum. C leaves the underlying type to the implementation, and the
        // implementations disagree; that is only unobservable while every
        // enumerator is non-negative. One negative value and the same
        // declaration means different things on MSVC and on clang.
        if (f.value < 0) {
            fail(what ++ "." ++ f.name ++ " is negative, which makes the enum's " ++
                "underlying type observable — C leaves that to the implementation " ++
                "and MSVC and clang choose differently. Use an explicit " ++
                "fixed-width constant instead, the way ZOZZ_NO_PARENT is one.");
        }
        if (@as(i128, @field(h, cname)) != @as(i128, f.value)) {
            fail(what ++ "." ++ f.name ++ " is " ++
                std.fmt.comptimePrint("{d}", .{f.value}) ++ " in src/c.zig but " ++ cname ++
                " is " ++ std.fmt.comptimePrint("{d}", .{@field(h, cname)}) ++ " in ffi/zozz.h");
        }
    }
}

//=============================================================================
// The sweep
//=============================================================================

const Counts = struct {
    types: usize = 0,
    functions: usize = 0,
    constants: usize = 0,
    fields: usize = 0,
    enumerators: usize = 0,
};

/// Every public declaration in `c.zig`, classified and compared. The `else`
/// arms are compile errors: a declaration this does not know how to check is a
/// hole in the guard, and a hole should stop the build rather than be counted
/// as a pass.
fn sweepOurs() Counts {
    comptime {
        var n = Counts{};

        for (@typeInfo(c).@"struct".decls) |d| {
            const Decl = @TypeOf(@field(c, d.name));

            // ---- types -----------------------------------------------------
            if (Decl == type) {
                const Ours = @field(c, d.name);
                const cname = typeCName(d.name);
                const what = "type " ++ d.name;
                n.types += 1;

                switch (@typeInfo(Ours)) {
                    .@"opaque" => {
                        // Nothing to compare but existence: an opaque handle
                        // has no layout on either side, which is the point.
                        const Theirs = theirDecl(cname, what);
                        if (Theirs != type) fail(cname ++ " is not a type in ffi/zozz.h");
                        if (@typeInfo(@field(h, cname)) != .@"opaque") {
                            fail(what ++ " is opaque in src/c.zig but not in ffi/zozz.h");
                        }
                    },
                    .@"struct" => |s| {
                        _ = theirDecl(cname, what);
                        const Theirs = @field(h, cname);
                        switch (s.layout) {
                            .@"extern" => {
                                checkStructLayout(what, Ours, Theirs);
                                n.fields += s.fields.len;
                            },
                            // No packed struct crosses this boundary today —
                            // zozz has no bit-mask type. One added later would
                            // land in the `else` arm below with a message
                            // saying so, rather than being waved through.
                            .@"packed", .auto => fail(what ++ " has " ++ @tagName(s.layout) ++
                                " layout, which this check does not know how to compare " ++
                                "against the header; declare it extern, or add a case here"),
                        }
                    },
                    .@"enum" => |e| {
                        _ = theirDecl(cname, what);
                        sameSizeAndAlign(what, Ours, @field(h, cname));
                        checkEnumValues(what, Ours, d.name);
                        n.enumerators += e.fields.len;
                    },
                    .int, .float, .bool => {
                        _ = theirDecl(cname, what);
                        const Theirs = @field(h, cname);
                        sameSizeAndAlign(what, Ours, Theirs);
                        const oi = @typeInfo(Ours);
                        const ti = @typeInfo(Theirs);
                        if (oi == .int and ti == .int and oi.int.signedness != ti.int.signedness) {
                            fail(what ++ " is " ++ @typeName(Ours) ++ " in src/c.zig but " ++
                                @typeName(Theirs) ++ " in ffi/zozz.h");
                        }
                    },
                    .pointer => {
                        // A callback typedef. translate-c makes every C
                        // function pointer optional; unwrap before comparing.
                        _ = theirDecl(cname, what);
                        const Theirs = @field(h, cname);
                        sameSizeAndAlign(what, Ours, Theirs);
                        const OursFn = @typeInfo(Ours).pointer.child;
                        const TheirsOpt = @typeInfo(Theirs);
                        const TheirsPtr = if (TheirsOpt == .optional) TheirsOpt.optional.child else Theirs;
                        checkFnType(what, OursFn, @typeInfo(TheirsPtr).pointer.child);
                    },
                    else => fail("type " ++ d.name ++ " is a " ++
                        @tagName(@typeInfo(Ours)) ++ ", which this check does not know how to " ++
                        "compare against the header"),
                }
                continue;
            }

            // ---- functions -------------------------------------------------
            if (@typeInfo(Decl) == .@"fn") {
                if (@typeInfo(Decl).@"fn".calling_convention == .auto) {
                    // A Zig helper, not an extern — skipping it is right, but
                    // skipping it SILENTLY is not: the reverse sweep only
                    // checks that a name exists, so a helper reusing an
                    // exported symbol's name would pass both sweeps while the
                    // extern it displaced silently vanishes. A helper is
                    // allowed; one wearing a boundary name is not.
                    if (std.mem.startsWith(u8, d.name, "zozz")) {
                        fail("src/c.zig declares `" ++ d.name ++ "` as a Zig function, not an " ++
                            "extern. The `zozz` prefix is reserved for the C boundary here: a " ++
                            "helper on that name hides the extern it replaced from both " ++
                            "directions of this check. Rename the helper.");
                    }
                    continue;
                }
                const what = "function " ++ d.name;
                _ = theirDecl(d.name, what);
                checkFnType(what, Decl, @TypeOf(@field(h, d.name)));
                n.functions += 1;
                continue;
            }

            // ---- constants -------------------------------------------------
            if (@typeInfo(Decl) == .int or @typeInfo(Decl) == .comptime_int or
                @typeInfo(Decl) == .@"enum")
            {
                const cname = constCName(d.name);
                const what = "constant " ++ d.name;
                _ = theirDecl(cname, what);
                const ours_val: i128 = @intCast(if (@typeInfo(Decl) == .@"enum")
                    @intFromEnum(@field(c, d.name))
                else
                    @field(c, d.name));
                const theirs_val: i128 = @intCast(@field(h, cname));
                if (ours_val != theirs_val) {
                    fail(what ++ " is " ++ std.fmt.comptimePrint("{d}", .{ours_val}) ++
                        " in src/c.zig but " ++ cname ++ " is " ++
                        std.fmt.comptimePrint("{d}", .{theirs_val}) ++ " in ffi/zozz.h");
                }
                n.constants += 1;
                continue;
            }

            fail("src/c.zig declares `" ++ d.name ++ "` as a " ++ @tagName(@typeInfo(Decl)) ++
                ", which this check does not know how to compare. Add a case rather than " ++
                "leaving it unchecked.");
        }

        return n;
    }
}

/// The other direction: a function the header exports that `c.zig` never
/// declared is invisible to the sweep above, because the sweep only walks what
/// `c.zig` has.
fn sweepTheirs() usize {
    comptime {
        var found: usize = 0;

        for (@typeInfo(h).@"struct".decls) |d| {
            // Filter by name BEFORE touching the value: translate-c emits
            // `@compileError` declarations for system macros it cannot render,
            // and evaluating one of those would fail the build for a reason
            // that has nothing to do with zozz.
            if (!std.mem.startsWith(u8, d.name, "zozz")) continue;
            if (@typeInfo(@TypeOf(@field(h, d.name))) != .@"fn") continue;

            found += 1;
            if (!@hasDecl(c, d.name)) {
                fail("ffi/zozz.h exports `" ++ d.name ++ "` but src/c.zig never declares it");
            }
            // Existence is not enough: the name has to resolve to something
            // that actually links. A Zig helper or a type sitting on the name
            // satisfies `@hasDecl` while the extern is gone. The forward sweep
            // already rejects those first, so this is the backstop, not the
            // catch: it depends on nothing but the header, so widening the
            // forward sweep's name filter later cannot reopen the hole.
            const Ours = @TypeOf(@field(c, d.name));
            if (@typeInfo(Ours) != .@"fn") {
                fail("ffi/zozz.h exports `" ++ d.name ++ "` but src/c.zig declares that name " ++
                    "as a " ++ @tagName(@typeInfo(Ours)) ++ " rather than a function");
            }
            if (@typeInfo(Ours).@"fn".calling_convention == .auto) {
                fail("ffi/zozz.h exports `" ++ d.name ++ "` but src/c.zig declares that name " ++
                    "as a Zig function rather than an extern, so nothing binds the symbol");
            }
        }
        return found;
    }
}

//=============================================================================
// Link coverage: every extern analysed above also has a definition
//
// `sweepOurs` proves an extern matches the header, not that the library
// defines it: an analysed-but-unreferenced extern leaves only a debug-info
// mention, and what a linker does with that is the object format's business —
// ELF refuses it, COFF and Mach-O drop it. Four entry points had no definition
// at all in the default configuration and only the Linux link said so
// (`ffi/zozz_options.cpp`, the `!ZOZZ_WITH_OPTIONS` branch).
//
// Taking every address into a table with external linkage makes each one a
// relocation, which no object format may drop and no optimiser may fold, so
// the link is the check — on every target and in every configuration.
//=============================================================================

/// True for the extern declarations `sweepOurs` compares against the header,
/// and false for the Zig helpers it skips.
fn isBoundaryExtern(comptime name: []const u8) bool {
    const Decl = @TypeOf(@field(c, name));
    if (@typeInfo(Decl) != .@"fn") return false;
    return @typeInfo(Decl).@"fn".calling_convention != .auto;
}

const entry_point_count = blk: {
    @setEvalBranchQuota(1_000_000);
    var n: usize = 0;
    for (@typeInfo(c).@"struct".decls) |d| {
        if (isBoundaryExtern(d.name)) n += 1;
    }
    break :blk n;
};

/// Exported rather than local: a symbol with external linkage cannot be
/// discarded, so its initialiser's relocations reach the linker whatever the
/// optimiser concludes about the reads below.
export const zozz_abi_entry_points: [entry_point_count]*const anyopaque = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [entry_point_count]*const anyopaque = undefined;
    var i: usize = 0;
    for (@typeInfo(c).@"struct".decls) |d| {
        if (!isBoundaryExtern(d.name)) continue;
        table[i] = @ptrCast(&@field(c, d.name));
        i += 1;
    }
    break :blk table;
};

//=============================================================================
// The test
//
// The comparisons above are compile errors, so reaching this body at all means
// they passed. What is left to assert is that they actually ran: a sweep that
// silently matched nothing would be indistinguishable from a sweep that
// matched everything.
//=============================================================================

test "ABI: src/c.zig agrees with ffi/zozz.h" {
    @setEvalBranchQuota(1_000_000);

    const ours = comptime sweepOurs();
    const theirs = comptime sweepTheirs();

    try std.testing.expect(ours.types >= 10);
    try std.testing.expect(ours.functions >= 45);
    try std.testing.expect(ours.constants >= 1);
    try std.testing.expect(ours.fields >= 20);
    try std.testing.expect(ours.enumerators >= 10);
    try std.testing.expectEqual(ours.functions, theirs);
}

test "ABI: every extern in src/c.zig has a definition in this build" {
    @setEvalBranchQuota(1_000_000);

    // Linking is the check; this asserts the table it lives in is neither
    // empty nor smaller than the sweep that named its entries.
    const swept = comptime sweepOurs();
    try std.testing.expectEqual(swept.functions, zozz_abi_entry_points.len);
    for (zozz_abi_entry_points) |address| {
        try std.testing.expect(@intFromPtr(address) != 0);
    }
}
