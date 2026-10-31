const std = @import("std");

// `build.zig.zon`'s version and `ffi/zozz_core.h`'s ZOZZ_VERSION_* are two
// homes for one fact: the first is what a Zig consumer resolves, the second
// is what `zozzVersion()` reports to a C consumer and what the ABI handshake
// compares. They are compared here, so a bump that misses one is a build
// failure rather than two libraries disagreeing about which they are.
comptime {
    const zon = @import("build.zig.zon");
    const header = @embedFile("ffi/zozz_core.h");
    const expected = std.fmt.comptimePrint("{d}.{d}.{d}", .{
        headerDefine(header, "ZOZZ_VERSION_MAJOR"),
        headerDefine(header, "ZOZZ_VERSION_MINOR"),
        headerDefine(header, "ZOZZ_VERSION_PATCH"),
    });
    if (!std.mem.eql(u8, zon.version, expected)) {
        @compileError("build.zig.zon says version \"" ++ zon.version ++
            "\" but ffi/zozz_core.h's ZOZZ_VERSION_* say \"" ++ expected ++
            "\". Bump both: the header is the ABI handshake.");
    }
}

/// Value of a `#define NAME <integer>` in `source`. A missing or non-integer
/// define is a compile error, so a renamed macro cannot make the check above
/// vacuous.
fn headerDefine(comptime source: []const u8, comptime name: []const u8) comptime_int {
    comptime {
        @setEvalBranchQuota(200_000);
        const needle = "#define " ++ name ++ " ";
        const at = std.mem.find(u8, source, needle) orelse
            @compileError("ffi/zozz_core.h has no `" ++ needle ++ "`");
        const rest = source[at + needle.len ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
        return std.fmt.parseInt(u32, rest[0..end], 10) catch
            @compileError(name ++ " is not a plain integer define");
    }
}

/// Sources of the vendored ozz runtime that zozz actually needs.
///
/// This list is explicit rather than a directory glob for two reasons: a glob
/// would silently start compiling whatever a future re-vendor drops in, and
/// several ozz translation units (the offline builders, the FBX/glTF
/// importers, the sample framework) pull in dependencies that have no place in
/// a runtime library.
const ozz_runtime_sources = [_][]const u8{
    // base — allocation, logging, platform shims
    "libs/ozz/src/base/log.cc",
    "libs/ozz/src/base/platform.cc",
    "libs/ozz/src/base/memory/allocator.cc",
    // base — archive serialisation, the .ozz reader
    "libs/ozz/src/base/io/archive.cc",
    "libs/ozz/src/base/io/stream.cc",
    "libs/ozz/src/base/containers/string_archive.cc",
    "libs/ozz/src/base/encode/group_varint.cc",
    // base — maths and their archive extensions
    "libs/ozz/src/base/maths/box.cc",
    "libs/ozz/src/base/maths/math_archive.cc",
    "libs/ozz/src/base/maths/simd_math.cc",
    "libs/ozz/src/base/maths/simd_math_archive.cc",
    "libs/ozz/src/base/maths/soa_math_archive.cc",
    // animation runtime — the sampling pipeline
    "libs/ozz/src/animation/runtime/animation.cc",
    "libs/ozz/src/animation/runtime/skeleton.cc",
    "libs/ozz/src/animation/runtime/sampling_job.cc",
    "libs/ozz/src/animation/runtime/local_to_model_job.cc",
    "libs/ozz/src/animation/runtime/blending_job.cc",
    // animation runtime — user tracks and edge triggering. track.cc is also
    // what TrackBuilder in the offline sources below builds INTO, and
    // skeleton_utils.cc is what the animation optimizer and the motion
    // extractor walk hierarchies with; one entry each covers both uses.
    "libs/ozz/src/animation/runtime/track.cc",
    "libs/ozz/src/animation/runtime/track_sampling_job.cc",
    "libs/ozz/src/animation/runtime/track_triggering_job.cc",
    "libs/ozz/src/animation/runtime/skeleton_utils.cc",
    "libs/ozz/src/animation/runtime/animation_utils.cc",
    "libs/ozz/src/animation/runtime/motion_blending_job.cc",
    "libs/ozz/src/animation/runtime/ik_two_bone_job.cc",
    "libs/ozz/src/animation/runtime/ik_aim_job.cc",
    // geometry — matrix-palette skinning
    "libs/ozz/src/geometry/runtime/skinning_job.cc",
};

/// ozz's offline pipeline: the builders that turn raw keyframe data into
/// runtime objects, the processors that reshape it on the way, and the
/// archive traits that let a cook stage hand its raw output to the next one.
const ozz_offline_sources = [_][]const u8{
    "libs/ozz/src/animation/offline/raw_skeleton.cc",
    "libs/ozz/src/animation/offline/raw_animation.cc",
    "libs/ozz/src/animation/offline/raw_animation_utils.cc",
    // The offline types' archive traits. Separate translation units in ozz,
    // and separate here for the same reason they are there: without them a
    // raw skeleton or clip has no Save/Load at all, which is what left the
    // offline half of the pipeline unable to persist anything between cook
    // stages.
    "libs/ozz/src/animation/offline/raw_skeleton_archive.cc",
    "libs/ozz/src/animation/offline/raw_animation_archive.cc",
    "libs/ozz/src/animation/offline/skeleton_builder.cc",
    "libs/ozz/src/animation/offline/animation_builder.cc",
    // animation processing: key-frame reduction, additive deltas, root-motion
    // extraction.
    "libs/ozz/src/animation/offline/animation_optimizer.cc",
    "libs/ozz/src/animation/offline/additive_animation_builder.cc",
    "libs/ozz/src/animation/offline/motion_extractor.cc",
    // raw tracks: the five user-channel value types, their builder and their
    // optimizer. raw_track_utils is motion_extractor's dependency (it samples
    // the extracted rotation track while fixing up joint translations).
    "libs/ozz/src/animation/offline/raw_track.cc",
    "libs/ozz/src/animation/offline/raw_track_utils.cc",
    "libs/ozz/src/animation/offline/track_builder.cc",
    "libs/ozz/src/animation/offline/track_optimizer.cc",
};

/// ozz's command-line option parser. Kept out of ozz_runtime_sources above,
/// unlike everything else the runtime needs: it is optional (-Doptions,
/// default off) and writes to <iostream> in about twenty places, which no
/// unconditionally-compiled zozz source does.
const ozz_options_sources = [_][]const u8{
    "libs/ozz/src/options/options.cc",
};

/// The zozz C boundary. One translation unit per concern — deliberately not a
/// single monolithic binding file.
const zozz_ffi_sources = [_][]const u8{
    "ffi/zozz_core.cpp",
    "ffi/zozz_offline.cpp",
    "ffi/zozz_optimizer.cpp",
    "ffi/zozz_rawtrack.cpp",
    "ffi/zozz_pose.cpp",
    "ffi/zozz_skeleton.cpp",
    "ffi/zozz_animation.cpp",
    "ffi/zozz_sampling.cpp",
    "ffi/zozz_track.cpp",
    "ffi/zozz_ik.cpp",
    "ffi/zozz_skinning.cpp",
    "ffi/zozz_abi.cpp",
    "ffi/zozz_utils.cpp",
    "ffi/zozz_motion.cpp",
    "ffi/zozz_blending.cpp",
    "ffi/zozz_archive.cpp",
    "ffi/zozz_encode.cpp",
    "ffi/zozz_options.cpp",
    "ffi/zozz_gltf.cpp",
};

/// The -Dgltf half of the importer: wraps ozz's vendored GltfImporter
/// (gltf2ozz.cc, which #include's tinygltf) as a ZozzImporter. Kept out of
/// zozz_ffi_sources above because it pulls in tinygltf's whole
/// TINYGLTF_IMPLEMENTATION, weight a runtime-only consumer should not pay
/// for; see ffi/zozz_gltf_backend.cpp for why it is one file rather than
/// gltf2ozz.cc compiled directly.
const zozz_gltf_backend_sources = [_][]const u8{
    "ffi/zozz_gltf_backend.cpp",
};

// Refuses a source listed twice, across all five lists at once.
//
// A duplicate is invisible in a static archive — the linker takes one member
// and never looks at the other — so it survives every default build and every
// test, and only surfaces when something needs both objects at once. The
// shared-library configuration is the first thing that does, which is a long
// way from the edit that caused it. Two sources were listed twice here for
// exactly that reason before this check existed.
comptime {
    @setEvalBranchQuota(100_000);
    const lists = .{
        ozz_runtime_sources, ozz_offline_sources,       ozz_options_sources,
        zozz_ffi_sources,    zozz_gltf_backend_sources,
    };
    var all: []const []const u8 = &.{};
    for (lists) |list| all = all ++ @as([]const []const u8, &list);
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) {
                @compileError("build.zig lists `" ++ a ++ "` more than once. " ++
                    "A duplicate source is a duplicate symbol, which a static " ++
                    "archive hides and a shared library refuses.");
            }
        }
    }
}

/// How the C++ was built. Every ABI- or behaviour-affecting option is mirrored
/// into the `zozz_options` module, so the wrapper can never disagree with the
/// library it links.
const Options = struct {
    shared: bool,
    enable_asserts: bool,
    sanitize_c: bool,
    options: bool,
    gltf: bool,
    simd_ref: bool,
};

/// What a project that depends on zozz builds: the `zozz` C library (the
/// vendored ozz plus the FFI layer in ffi/) and the `zozz` module over it.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options: Options = .{
        .shared = b.option(bool, "shared", "Build the C library as a shared object") orelse false,
        .enable_asserts = b.option(bool, "enable_asserts", "Keep ozz's internal asserts (defaults to on in Debug)") orelse (optimize == .debug),
        // Off by default, and deliberately NOT tied to `optimize`: Zig's C
        // sanitizer emits calls into a runtime linked only into a compilation
        // that is itself sanitized, so defaulting it on in Debug hands a
        // consumer who forgot to forward `optimize` a link failure naming a
        // __ubsan symbol. The development build turns it on for its own arms.
        .sanitize_c = b.option(bool, "sanitize_c", "Compile the C and C++ with Zig's undefined-behaviour sanitizer") orelse false,
        // Off by default: options.cc writes to <iostream> in about twenty
        // places, and zozz otherwise never pulls that header in.
        .options = b.option(bool, "options", "Build ozz's command-line option parser and the OzzImporter " ++
            "host-implementable interface / CLI driver (zozz_options.h, zozz_gltf.h)") orelse false,
        // Off by default: pulls in tinygltf's whole TINYGLTF_IMPLEMENTATION.
        .gltf = b.option(bool, "gltf", "Build the concrete glTF importer backend (zozz_gltf.h)") orelse false,
        // ozz ships two SIMD backends and no NEON one, so an x86-64 host
        // compiles the SSE kernels and never the scalar reference ones a
        // non-x86 build runs. This forces the reference backend on any host,
        // the only way to exercise that half without the hardware; two
        // upstream undefined-behaviour sites live there alone (docs/design.md).
        .simd_ref = b.option(bool, "simd_ref", "Compile ozz's scalar reference SIMD backend instead of this " ++
            "target's (what a non-x86 host gets)") orelse false,
    };

    const lib = library(b, target, optimize, options);

    // Registered unconditionally: `std.Build.Dependency.artifact` scans the
    // dependency's install step, so an artifact not installed here is one
    // `dep.artifact("zozz")` cannot find, and the installed headers go with it.
    b.installArtifact(lib);

    // No include path: the wrapper hand-writes its externs rather than
    // translating the header, so nothing Zig-side compiles C.
    const module = b.addModule("zozz", .{
        .root_source_file = b.path("src/zozz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zozz_options", .module = optionsModule(b, options) },
            .{ .name = "aegis", .module = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
        },
    });
    module.linkLibrary(lib);
}

/// The C library: the vendored ozz runtime and offline pipeline, plus the
/// zozz FFI layer, with the public headers installed beside it.
fn library(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, options: Options) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "zozz",
        .linkage = if (options.shared) .dynamic else .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    if (target.result.abi != .msvc) lib.root_module.link_libcpp = true;

    lib.root_module.addIncludePath(b.path("libs/ozz/include"));
    // ozz's own translation units include implementation-private headers
    // relative to its src root (e.g. "animation/runtime/animation_keyframe.h").
    lib.root_module.addIncludePath(b.path("libs/ozz/src"));
    lib.root_module.addIncludePath(b.path("ffi"));
    if (options.shared and target.result.abi == .msvc) {
        lib.root_module.addCMacro("ZOZZ_SHARED", "");
        lib.root_module.addCMacro("ZOZZ_BUILD", "");
    }

    const own_flags = cxxFlags(b, target, options, false);
    const ozz_flags = cxxFlags(b, target, options, true);
    lib.root_module.addCSourceFiles(.{ .files = &ozz_runtime_sources, .flags = ozz_flags });
    lib.root_module.addCSourceFiles(.{ .files = &ozz_offline_sources, .flags = ozz_flags });
    lib.root_module.addCSourceFiles(.{ .files = &zozz_ffi_sources, .flags = own_flags });

    // -Doptions / -Dgltf: see ozz_options_sources / zozz_gltf_backend_sources
    // for why each is kept out of the unconditional lists. The macros switch
    // zozz_options.cpp's and zozz_gltf.cpp's own implementations (always
    // compiled) between the real thing and a ZOZZ_RESULT_UNSUPPORTED stub.
    if (options.options) {
        lib.root_module.addCMacro("ZOZZ_WITH_OPTIONS", "");
        lib.root_module.addCSourceFiles(.{ .files = &ozz_options_sources, .flags = ozz_flags });
    }
    if (options.gltf) {
        lib.root_module.addCMacro("ZOZZ_WITH_GLTF", "");
        lib.root_module.addCSourceFiles(.{ .files = &zozz_gltf_backend_sources, .flags = ozz_flags });
    }
    lib.root_module.sanitize_c = if (options.sanitize_c) .full else .off;

    // zozz.h is the umbrella and #includes every one of the rest by relative
    // path, so all of them land side by side in the installed include
    // directory for that #include to resolve from an installed prefix.
    for (public_headers) |header| lib.installHeader(b.path(b.fmt("ffi/{s}", .{header})), header);
    return lib;
}

/// The C++ flags, for zozz's own translation units or for ozz's.
///
/// ozz throws nothing and uses no RTTI, so both are disabled where doing so is
/// reliable. Under the MSVC ABI they are not: the Microsoft standard library
/// headers ozz pulls in (<iostream> in its logger) assume exceptions, and
/// disabling them through Clang flags is a known source of header errors.
///
/// Not here on any target: -fno-access-control (the FFI layer uses only ozz's
/// public API) and a blanket -fno-sanitize=undefined (`sanitize_c` decides).
///
/// -Dsimd_ref belongs to EVERY translation unit or none: ozz's SimdFloat4 is a
/// struct in the reference backend and __m128 in the SSE one, so a mixed build
/// would hand one definition's objects to the other's.
///
/// NDEBUG follows `enable_asserts` in every mode, and so it is a flag rather
/// than a macro: Zig defines NDEBUG for C by itself in ReleaseFast and
/// ReleaseSmall, and only an -UNDEBUG after its own flags keeps the asserts
/// there when they are asked for.
///
/// A translation unit whose arithmetic is ozz's (the vendored sources, and
/// tests/mathref.cpp, which dispatches into ozz's inline maths) loses three
/// UBSan check classes, each answering one upstream site no local change can
/// reach, since the vendored tree stays pristine; zozz's own ffi keeps all of
/// them. docs/design.md has an entry for each:
///
///   nonnull-attribute: upstream serialisation memcpy's a null source when an
///   array is empty (`MemoryStream::Write`, src/base/io/stream.cc:160), the
///   normal case for a short clip's `iframe_entries`.
///
///   signed-integer-overflow: `OZZ_RCP_EST`
///   (include/ozz/base/maths/internal/simd_math_ref-inl.h:57) seeds a
///   reciprocal with `(0x3f800000 * 2) - uf.i` over the input's bit pattern;
///   a negative input passes INT_MAX, and the bit trick is the routine.
///
///   shift-base: `ShiftL` (simd_math_ref-inl.h:1491) left-shifts each `int`
///   lane, and a lane holding a comparison mask is negative; the SSE backend's
///   `_mm_slli_epi32` has no such rule.
fn cxxFlags(b: *std.Build, target: std.Build.ResolvedTarget, options: Options, upstream: bool) []const []const u8 {
    const base: []const []const u8 = if (target.result.abi == .msvc)
        &.{"-std=c++17"}
    else
        &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" };
    const exemptions: []const []const u8 = &.{
        "-fno-sanitize=nonnull-attribute",
        "-fno-sanitize=signed-integer-overflow",
        "-fno-sanitize=shift-base",
    };
    return std.mem.concat(b.allocator, []const u8, &.{
        base,
        if (options.simd_ref) &.{"-DOZZ_BUILD_SIMD_REF"} else &.{},
        &.{if (options.enable_asserts) "-UNDEBUG" else "-DNDEBUG"},
        if (upstream) exemptions else &.{},
    }) catch @panic("out of memory");
}

/// How the C++ was built, plus the package version, as the `zozz_options`
/// module. The version's home is build.zig.zon; the comptime check at the top
/// of this file holds ffi/zozz_core.h's ZOZZ_VERSION_* to it.
fn optionsModule(b: *std.Build, options: Options) *std.Build.Module {
    const step = b.addOptions();
    step.addOption([]const u8, "version", @import("build.zig.zon").version);
    inline for (@typeInfo(Options).@"struct".field_names) |name| step.addOption(bool, name, @field(options, name));
    return step.createModule();
}

/// zozz's development: its tests, examples and checks, under preflight's
/// gate. Run through bay. The package is reached as a dependency here, the way
/// a consumer reaches it, so the artifact, its installed headers and the
/// module are the ones a consumer gets.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const preflight = tools.preflight;
    const package = b.dependency("zozz", .{ .target = target, .optimize = optimize });
    const p = package.builder;

    const test_step = b.step("test", "Run the zozz tests");
    const check_step = b.step("check", "Compile the zozz tests, examples and build configurations without running them");
    const filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| b.allocator.dupe([]const u8, &.{filter}) catch @panic("OOM") else &.{};
    // An optional second integration test against real .ozz files on disk,
    // for checking a specific asset or a specific archive version.
    const assets: Assets = .{
        .skeleton_path = b.option([]const u8, "skeleton_path", "Path to a .ozz skeleton for the integration test"),
        .animation_path = b.option([]const u8, "animation_path", "Path to a .ozz animation matching -Dskeleton_path"),
    };

    //=====================================================================
    // Tests: against the C++ under Zig's undefined-behaviour sanitizer, as a
    // consumer builds it by default, with the asserts flipped from the mode's
    // default so both sides of every NDEBUG seam run, with each optional
    // half and both, and on ozz's scalar reference SIMD backend, which an
    // x86-64 host otherwise never compiles. The suite's C++ is the
    // dependency's artifact, so the C++ a consumer links is the C++ tested.
    //=====================================================================

    const asserts_default = optimize == .debug;
    const plain: Options = .{ .shared = false, .enable_asserts = asserts_default, .sanitize_c = false, .options = false, .gltf = false, .simd_ref = false };
    const arms = [_]struct { name: []const u8, options: Options }{
        .{ .name = "zozz-tests-ubsan", .options = with(plain, .{ .sanitize_c = true }) },
        .{ .name = "zozz-tests", .options = plain },
        .{ .name = "zozz-tests-asserts-flipped", .options = with(plain, .{ .enable_asserts = !asserts_default }) },
        .{ .name = "zozz-tests-options", .options = with(plain, .{ .options = true }) },
        .{ .name = "zozz-tests-gltf", .options = with(plain, .{ .gltf = true }) },
        .{ .name = "zozz-tests-options-gltf", .options = with(plain, .{ .options = true, .gltf = true }) },
        .{ .name = "zozz-tests-simd-ref-ubsan", .options = with(plain, .{ .simd_ref = true, .sanitize_c = true }) },
    };
    for (arms) |arm| {
        const tests = suite(b, p, target, optimize, arm.name, arm.options, assets, filters);
        test_step.dependOn(&b.addRunArtifact(tests).step);
        check_step.dependOn(&tests.step);
    }

    // The C boundary on its own, with no Zig in the picture: plain C11 that
    // includes "zozz.h" through the artifact's installed headers, with a host
    // allocator that knows nothing about Zig. Twice: as a consumer links it,
    // and with the program and the C++ under the sanitizer, since some of the
    // boundary's paths only C reaches.
    const c_test_step = b.step("test-c", "Run the C smoke test, with no Zig in the picture");
    test_step.dependOn(c_test_step);
    for ([_]struct { name: []const u8, options: Options }{
        .{ .name = "zozz-c-smoke", .options = plain },
        .{ .name = "zozz-c-smoke-ubsan", .options = with(plain, .{ .sanitize_c = true }) },
    }) |arm| {
        const linked = libraryOf(b, target, optimize, arm.options);
        const c_smoke = b.addExecutable(.{
            .name = arm.name,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        c_smoke.root_module.sanitize_c = if (arm.options.sanitize_c) .full else .off;
        c_smoke.root_module.addIncludePath(p.path("tests"));
        c_smoke.root_module.addCSourceFile(.{ .file = p.path("tests/c_smoke.c"), .flags = &.{"-std=c11"} });
        c_smoke.root_module.linkLibrary(linked);
        c_smoke.root_module.linkLibrary(fixtureLibrary(b, p, target, optimize, arm.options, linked));
        c_test_step.dependOn(&b.addRunArtifact(c_smoke).step);
        check_step.dependOn(&c_smoke.step);
    }

    // The configurations no arm above links: the shared library, which is
    // what proves every source is listed once, and the asserts flipped under
    // the sanitizer.
    for ([_]Options{
        with(plain, .{ .shared = true }),
        with(plain, .{ .enable_asserts = !asserts_default, .sanitize_c = true }),
    }) |options| {
        const variant = libraryOf(b, target, optimize, options);
        test_step.dependOn(&variant.step);
        check_step.dependOn(&variant.step);
    }

    //=====================================================================
    // Examples, built AND run against the module a consumer gets.
    // examples/usage.zig is also where README.md's Usage block comes from
    // (`bay docs -- usage`), so the snippet a reader copies is code the tests
    // execute. An example that writes files writes them into the install
    // prefix, never into the source tree; the library installed there is
    // what makes the prefix exist before an example runs in it.
    //=====================================================================

    b.installArtifact(package.artifact("zozz"));
    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = p.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zozz", .module = package.module("zozz") }},
            }),
        });
        const run = b.addRunArtifact(example);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(.{ .relative = .{ .base = .install_prefix, .sub_path = "" } });
        examples_step.dependOn(&run.step);
        check_step.dependOn(&example.step);
    }
    test_step.dependOn(examples_step);

    //=====================================================================
    // CI wiring
    //=====================================================================

    for (checks) |c| withAegis(p, preflight.addCheck(b, p, c.name, c.source));
    // Every public ozz name with a verdict (ci/coverage/): the gate, and its
    // other modes for a binder (`zig build coverage -- --summary maths`).
    const coverage_check = preflight.addCheck(b, p, "check-coverage", "ci/coverage.zig");
    withAegis(p, coverage_check);
    const coverage = b.addRunArtifact(coverage_check);
    coverage.setCwd(p.path("."));
    coverage.addPassthruArgs();
    b.step("coverage", "Run ci/coverage.zig in the mode given after --").dependOn(&coverage.step);
    // The generated blocks of README.md and UPSTREAM.md, which the docs check
    // regenerates through these steps (ci/preflight.json).
    _ = tool(b, p, test_step, "measurements", "ci/measurements.zig", "Print README.md's numbers block, recomputed from the tree");
    _ = tool(b, p, test_step, "archive-versions", "ci/archive_versions.zig", "Print UPSTREAM.md's archive-version table, read from the vendored headers");

    // libs/ozz against upstream at the pinned commit, which the manifest
    // fetches as a development dependency.
    const vendor = b.addExecutable(.{
        .name = "zozz-vendor",
        .root_module = b.createModule(.{ .root_source_file = p.path("ci/vendor.zig"), .target = b.graph.host, .optimize = .debug }),
    });
    withAegis(p, vendor);
    const verify = b.addRunArtifact(vendor);
    verify.addDirectoryArg2(p.path("libs/ozz"), .{});
    verify.addDirectoryArg2(b.dependency("ozz", .{}).path("."), .{});
    verify.addFileArg(p.path("build.zig.zon"));
    verify.addFileArg(p.path("UPSTREAM.md"));
    verify.step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vendor.root_module })).step);
    b.step("check-vendor", "Prove libs/ozz is upstream at the pinned commit").dependOn(&verify.step);

    // Outside the gate, a rebuild per input: the mutation probes. Their own
    // tests run with the suite.
    const probe = tool(b, p, test_step, "probe", "ci/probes.zig", "Mutate each invariant in ci/probes/ and require the named failure (`bay probe [filter]`)");
    probe.addPassthruArgs();
    // The binder's first step (BINDING.md): the lines of an ozz class that
    // decide its binding.
    const recon = tool(b, p, test_step, "recon", "ci/recon.zig", "Print what decides the binding of an ozz class (`zig build recon -- <Class>`)");
    recon.addPassthruArgs();

    preflight.addCi(b, p, .{ .tests = test_step });
    // The build a consumer gets: the module and the library, fetching
    // nothing.
    preflight.addConsumerCheck(b, p, .{
        .package = "zozz",
        .program = p.path("ci/consumer.zig"),
        .packages = &.{p.dependency("aegis", .{})},
    });
}

/// The on-disk assets an optional integration test reads.
const Assets = struct { skeleton_path: ?[]const u8, animation_path: ?[]const u8 };

/// `base` with the fields of `changes` replaced.
fn with(base: Options, changes: anytype) Options {
    var out = base;
    inline for (@typeInfo(@TypeOf(changes)).@"struct".field_names) |name| @field(out, name) = @field(changes, name);
    return out;
}

/// The package's library built with `options`, as a consumer passing them
/// gets it.
fn libraryOf(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, options: Options) *std.Build.Step.Compile {
    return b.dependency("zozz", .{
        .target = target,
        .optimize = optimize,
        .shared = options.shared,
        .enable_asserts = options.enable_asserts,
        .sanitize_c = options.sanitize_c,
        .options = options.options,
        .gltf = options.gltf,
        .simd_ref = options.simd_ref,
    }).artifact("zozz");
}

/// The suite, against the package's library built with `options`.
fn suite(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, name: []const u8, options: Options, assets: Assets, filters: []const []const u8) *std.Build.Step.Compile {
    const lib = libraryOf(b, target, optimize, options);
    const test_options = b.addOptions();
    test_options.addOption(?[]const u8, "skeleton_path", assets.skeleton_path);
    test_options.addOption(?[]const u8, "animation_path", assets.animation_path);
    const tests = b.addTest(.{
        .name = name,
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/zozz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zozz_options", .module = optionsModule(b, options) },
                .{ .name = "test_options", .module = test_options.createModule() },
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
            },
        }),
    });
    tests.root_module.linkLibrary(lib);
    tests.root_module.linkLibrary(fixtureLibrary(b, p, target, optimize, options, lib));
    // The ABI cross-check reads ffi/zozz.h translated as `zozz_h`, and the
    // differential maths test tests/mathref.h as `mathref_h`, on the test
    // module alone, never on the shipped one. No build macros go with them:
    // nothing in ffi/zozz.h changes shape with a `-D` flag (ZOZZ_API expands
    // to a linkage attribute and no type's width moves), so every
    // configuration's preprocessor renders the same declarations.
    const header = b.addTranslateC(.{ .root_source_file = p.path("ffi/zozz.h"), .target = target, .optimize = optimize, .link_libc = true });
    tests.root_module.addImport("zozz_h", header.createModule());
    const mathref = b.addTranslateC(.{ .root_source_file = p.path("tests/mathref.h"), .target = target, .optimize = optimize, .link_libc = true });
    tests.root_module.addImport("mathref_h", mathref.createModule());
    // The sanitized C++ calls into the sanitizer's runtime, which Zig bundles
    // by itself only into a Debug compilation.
    tests.bundle_ubsan_rt = options.sanitize_c;
    return tests;
}

/// The test fixture: synthetic assets built through ozz's offline builders
/// and serialised in memory (tests/fixture.cpp), so the suite holds no
/// third-party clips, and ozz's own maths reachable from a test
/// (tests/mathref.cpp), so the hand port in src/math.zig has something other
/// than itself to be compared against. mathref.cpp executes only ozz's inline
/// arithmetic, so it takes ozz's flags and their sanitizer exemptions;
/// fixture.cpp is zozz's own code and keeps the full sanitizer.
fn fixtureLibrary(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, options: Options, lib: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const fixture = b.addLibrary(.{
        .name = "zozz-fixture",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    if (target.result.abi != .msvc) fixture.root_module.link_libcpp = true;
    fixture.root_module.addIncludePath(p.path("libs/ozz/include"));
    fixture.root_module.addIncludePath(p.path("libs/ozz/src"));
    fixture.root_module.addIncludePath(p.path("ffi"));
    fixture.root_module.addIncludePath(p.path("tests"));
    fixture.root_module.addCSourceFile(.{ .file = p.path("tests/fixture.cpp"), .flags = cxxFlags(b, target, options, false) });
    fixture.root_module.addCSourceFile(.{ .file = p.path("tests/mathref.cpp"), .flags = cxxFlags(b, target, options, true) });
    fixture.root_module.sanitize_c = if (options.sanitize_c) .full else .off;
    fixture.root_module.linkLibrary(lib);
    return fixture;
}

/// A development tool: a host program run from the package root, its tests
/// run with the suite.
fn tool(b: *std.Build, p: *std.Build, test_step: *std.Build.Step, name: []const u8, source: []const u8, description: []const u8) *std.Build.Step.Run {
    const exe = b.addExecutable(.{
        .name = b.fmt("zozz-{s}", .{name}),
        .root_module = b.createModule(.{ .root_source_file = p.path(source), .target = b.graph.host, .optimize = .debug }),
    });
    withAegis(p, exe);
    const run = b.addRunArtifact(exe);
    run.setCwd(p.path("."));
    b.step(name, description).dependOn(&run.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    return run;
}

/// Gives a host program under ci/ aegis, whose `own.readFile` reads a file
/// whole with a limit (preflight's P006 holds every package to it).
fn withAegis(p: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.root_module.addImport("aegis", p.dependency("aegis", .{ .target = exe.root_module.resolved_target.?, .optimize = .debug }).module("aegis"));
}

/// The public headers, installed side by side.
const public_headers = [_][]const u8{
    "zozz.h",          "zozz_core.h",     "zozz_skeleton.h", "zozz_animation.h",
    "zozz_pose.h",     "zozz_sampling.h", "zozz_ik.h",       "zozz_skinning.h",
    "zozz_utils.h",    "zozz_motion.h",   "zozz_offline.h",  "zozz_optimizer.h",
    "zozz_rawtrack.h", "zozz_track.h",    "zozz_blending.h", "zozz_archive.h",
    "zozz_encode.h",   "zozz_options.h",  "zozz_gltf.h",
};

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};

/// The repository checks: each is built, its tests run, then it runs over the
/// tree from the repository root. ci/preflight.json runs each as an extra check.
const checks = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "check-alignment", .source = "ci/alignment.zig" },
    .{ .name = "check-comments", .source = "ci/comments.zig" },
    .{ .name = "check-ignored", .source = "ci/ignored.zig" },
    .{ .name = "check-mathref", .source = "ci/mathref.zig" },
    .{ .name = "check-numbers", .source = "ci/numbers.zig" },
};
