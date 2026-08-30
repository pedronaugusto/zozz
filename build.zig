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
        const at = std.mem.indexOf(u8, source, needle) orelse
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{
        .shared = b.option(
            bool,
            "shared",
            "Build the C library as a shared object",
        ) orelse false,
        .enable_asserts = b.option(
            bool,
            "enable_asserts",
            "Keep ozz's internal asserts (defaults to on in Debug)",
        ) orelse (optimize == .Debug),
        // Off by default, and deliberately NOT tied to `optimize`.
        //
        // Zig's full C sanitizer emits calls into a runtime that is linked
        // only into a compilation that is itself sanitized. Defaulting it on
        // in Debug means a consumer who writes `b.dependency("zozz", .{})` —
        // forgetting to forward `optimize`, the most common Zig packaging
        // mistake — gets a Debug zozz inside a release executable and a link
        // failure reading `undefined symbol: __ubsan_handle_type_mismatch_v1`,
        // which names nothing they can act on.
        //
        // zozz's own suite turns it on explicitly instead: `ci/run.sh` and CI
        // both pass `-Dsanitize_c=true` for the Debug runs. A library should
        // not decide that its consumers are running a sanitizer.
        .sanitize_c = b.option(
            bool,
            "sanitize_c",
            "Compile the C and C++ with Zig's undefined-behaviour sanitizer",
        ) orelse false,
        // Off by default: options.cc writes to <iostream> in about twenty
        // places, and zozz otherwise never pulls that header in. A consumer
        // who only wants the runtime should not pay for it.
        .options = b.option(
            bool,
            "options",
            "Build ozz's command-line option parser and the OzzImporter " ++
                "host-implementable interface / CLI driver (zozz_options.h, " ++
                "zozz_gltf.h)",
        ) orelse false,
        // Off by default: pulls in tinygltf's whole TINYGLTF_IMPLEMENTATION.
        .gltf = b.option(
            bool,
            "gltf",
            "Build the concrete glTF importer backend (zozz_gltf.h)",
        ) orelse false,
    };

    // Every ABI- or behaviour-affecting option is mirrored into a Zig module
    // so the wrapper can never disagree with how the C++ was compiled. The
    // single `options` struct above is the one source both sides read from.
    const options_step = b.addOptions();
    // Not an option: the version, carried along so a test can hold what the
    // library REPORTS to build.zig.zon rather than to a literal of its own.
    options_step.addOption([]const u8, "version", @import("build.zig.zon").version);
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }
    const options_module = options_step.createModule();

    //=====================================================================
    // The C library: vendored ozz runtime + the zozz FFI layer.
    //=====================================================================

    const lib = b.addLibrary(.{
        .name = "zozz",
        .linkage = if (options.shared) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.root_module.link_libc = true;
    if (target.result.abi != .msvc) lib.root_module.link_libcpp = true;

    lib.root_module.addIncludePath(b.path("libs/ozz/include"));
    // ozz's own translation units include implementation-private headers
    // relative to its src root (e.g. "animation/runtime/animation_keyframe.h").
    lib.root_module.addIncludePath(b.path("libs/ozz/src"));
    lib.root_module.addIncludePath(b.path("ffi"));

    if (!options.enable_asserts) lib.root_module.addCMacro("NDEBUG", "");
    if (options.shared and target.result.abi == .msvc) {
        lib.root_module.addCMacro("ZOZZ_SHARED", "");
        lib.root_module.addCMacro("ZOZZ_BUILD", "");
    }

    // ozz throws nothing and uses no RTTI, so both are disabled where doing so
    // is reliable. Under the MSVC ABI they are not: the Microsoft standard
    // library headers that ozz pulls in (<iostream> in its logger) are written
    // assuming exceptions are available, and disabling them through Clang
    // flags is a well-known source of header errors. The saving is a little
    // code size; the cost would be a toolchain-specific build failure, so the
    // MSVC ABI keeps the defaults.
    //
    // Note what is NOT here on any target: no -fno-access-control (the FFI
    // layer uses only ozz's public API, so it has no reason to defeat access
    // checking) and no blanket -fno-sanitize=undefined (UBSan stays on in
    // Debug, controlled by the `sanitize_c` option, so that real undefined
    // behaviour surfaces instead of being suppressed).
    const cxx_flags: []const []const u8 = if (target.result.abi == .msvc)
        &.{"-std=c++17"}
    else
        &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" };

    // The vendored TUs alone additionally drop UBSan's nonnull-attribute
    // check. Upstream serialisation memcpy's a null source when an array is
    // empty (`MemoryStream::Write`, src/base/io/stream.cc:160) — and an empty
    // array is the NORMAL case: every short animation has empty
    // `iframe_entries`, so the trap fires on well-formed input (CI run
    // 32667186311, ubuntu Debug). The tree stays pristine
    // (ci/verify-vendor.sh), so the site cannot be patched; the suppression
    // is one check class, vendored code only — zozz's own ffi keeps the full
    // sanitizer. UPSTREAM.md § "Known upstream behaviour" has the entry.
    const ozz_cxx_flags = std.mem.concat(b.allocator, []const u8, &.{
        cxx_flags,
        &.{"-fno-sanitize=nonnull-attribute"},
    }) catch @panic("OOM");

    lib.root_module.addCSourceFiles(.{
        .files = &ozz_runtime_sources,
        .flags = ozz_cxx_flags,
    });
    lib.root_module.addCSourceFiles(.{
        .files = &ozz_offline_sources,
        .flags = ozz_cxx_flags,
    });
    lib.root_module.addCSourceFiles(.{
        .files = &zozz_ffi_sources,
        .flags = cxx_flags,
    });

    // -Doptions / -Dgltf: see ozz_options_sources / zozz_gltf_backend_sources
    // above for why each is kept out of the unconditional lists. The macros
    // gate zozz_options.cpp's and zozz_gltf.cpp's own implementations (always
    // compiled, in zozz_ffi_sources above) between the real thing and a
    // ZOZZ_RESULT_UNSUPPORTED stub — see those files' own comments.
    if (options.options) {
        lib.root_module.addCMacro("ZOZZ_WITH_OPTIONS", "");
        lib.root_module.addCSourceFiles(.{
            .files = &ozz_options_sources,
            .flags = ozz_cxx_flags,
        });
    }
    if (options.gltf) {
        lib.root_module.addCMacro("ZOZZ_WITH_GLTF", "");
        lib.root_module.addCSourceFiles(.{
            .files = &zozz_gltf_backend_sources,
            .flags = ozz_cxx_flags,
        });
    }

    lib.root_module.sanitize_c = if (options.sanitize_c) .full else .off;

    // Consumers get the public headers without reaching into the source tree.
    // zozz.h is the umbrella and #includes every one of the rest by relative
    // path, so all of them have to land side by side in the installed include
    // directory for that #include to resolve from an installed prefix.
    lib.installHeader(b.path("ffi/zozz.h"), "zozz.h");
    lib.installHeader(b.path("ffi/zozz_core.h"), "zozz_core.h");
    lib.installHeader(b.path("ffi/zozz_skeleton.h"), "zozz_skeleton.h");
    lib.installHeader(b.path("ffi/zozz_animation.h"), "zozz_animation.h");
    lib.installHeader(b.path("ffi/zozz_pose.h"), "zozz_pose.h");
    lib.installHeader(b.path("ffi/zozz_sampling.h"), "zozz_sampling.h");
    lib.installHeader(b.path("ffi/zozz_ik.h"), "zozz_ik.h");
    lib.installHeader(b.path("ffi/zozz_skinning.h"), "zozz_skinning.h");
    lib.installHeader(b.path("ffi/zozz_utils.h"), "zozz_utils.h");
    lib.installHeader(b.path("ffi/zozz_motion.h"), "zozz_motion.h");
    lib.installHeader(b.path("ffi/zozz_offline.h"), "zozz_offline.h");
    lib.installHeader(b.path("ffi/zozz_optimizer.h"), "zozz_optimizer.h");
    lib.installHeader(b.path("ffi/zozz_rawtrack.h"), "zozz_rawtrack.h");
    lib.installHeader(b.path("ffi/zozz_track.h"), "zozz_track.h");
    lib.installHeader(b.path("ffi/zozz_blending.h"), "zozz_blending.h");
    lib.installHeader(b.path("ffi/zozz_archive.h"), "zozz_archive.h");
    lib.installHeader(b.path("ffi/zozz_encode.h"), "zozz_encode.h");
    lib.installHeader(b.path("ffi/zozz_options.h"), "zozz_options.h");
    lib.installHeader(b.path("ffi/zozz_gltf.h"), "zozz_gltf.h");

    //=====================================================================
    // The Zig module.
    //=====================================================================

    const module = b.addModule("zozz", .{
        .root_source_file = b.path("src/zozz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zozz_options", .module = options_module },
        },
    });
    // No include path: the wrapper hand-writes its externs rather than
    // @cImport-ing the header, so nothing Zig-side compiles C.
    module.linkLibrary(lib);

    // Registered unconditionally, including when zozz is consumed as a
    // dependency. `std.Build.Dependency.artifact` finds an artifact by
    // scanning the dependency's install step, so anything NOT installed here
    // is invisible to a consumer — `dep.artifact("zozz")` panics rather than
    // failing gracefully, and the installed header goes with it.
    //
    // This does not put zozz's library in a consumer's prefix: a dependency's
    // install step only runs when something the consumer builds actually
    // depends on it. `tests/consumer` is what keeps this honest.
    b.installArtifact(lib);

    //=====================================================================
    // Tests.
    //=====================================================================

    // Synthetic assets, built through ozz's offline builders and serialised in
    // memory. Keeps the suite self-contained: no vendored third-party clips,
    // and the fixture can never drift out of version-sync with the runtime.
    const fixture = b.addLibrary(.{
        .name = "zozz-fixture",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    fixture.root_module.link_libc = true;
    if (target.result.abi != .msvc) fixture.root_module.link_libcpp = true;
    fixture.root_module.addIncludePath(b.path("libs/ozz/include"));
    fixture.root_module.addIncludePath(b.path("libs/ozz/src"));
    fixture.root_module.addIncludePath(b.path("ffi"));
    fixture.root_module.addIncludePath(b.path("tests"));
    if (!options.enable_asserts) fixture.root_module.addCMacro("NDEBUG", "");
    // The offline builders live in the zozz library itself now (they are part
    // of the public surface); the fixture links them from there.
    fixture.root_module.addCSourceFile(.{
        .file = b.path("tests/fixture.cpp"),
        .flags = cxx_flags,
    });
    // ozz's own maths, reachable from a test so the hand port in src/math.zig
    // has something other than itself to be compared against.
    fixture.root_module.addCSourceFile(.{
        .file = b.path("tests/mathref.cpp"),
        .flags = cxx_flags,
    });
    fixture.root_module.sanitize_c = if (options.sanitize_c) .full else .off;
    fixture.root_module.linkLibrary(lib);

    // An optional second integration test against real .ozz files on disk,
    // for checking a specific asset or a specific archive version.
    const test_options = b.addOptions();
    test_options.addOption(?[]const u8, "skeleton_path", b.option(
        []const u8,
        "skeleton_path",
        "Path to a .ozz skeleton for the integration test",
    ));
    test_options.addOption(?[]const u8, "animation_path", b.option(
        []const u8,
        "animation_path",
        "Path to a .ozz animation matching -Dskeleton_path",
    ));

    const tests = b.addTest(.{
        .name = "zozz-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zozz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zozz_options", .module = options_module },
                .{ .name = "test_options", .module = test_options.createModule() },
            },
        }),
    });
    tests.root_module.linkLibrary(lib);
    tests.root_module.linkLibrary(fixture);

    // The ABI cross-check @cImport-s ffi/zozz.h. It is wired here, on the test
    // module, and deliberately not on the module above: the shipped module has
    // no include path and never runs translate-c.
    //
    // No build macros go with it, and that is a property of the header rather
    // than an oversight. Nothing in ffi/zozz.h changes shape with a `-D` flag —
    // ZOZZ_API expands to a linkage attribute and nothing else, and no type's
    // width moves — so this build's preprocessor renders the same declarations
    // in every configuration. A header that did vary would have to be
    // preprocessed here with the same macros the library was compiled with, or
    // the check would be comparing against something nobody ships.
    tests.root_module.addIncludePath(b.path("ffi"));
    // tests/mathref.h, for the same reason and on the same module only.
    tests.root_module.addIncludePath(b.path("tests"));

    const test_step = b.step("test", "Run zozz tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // A C-only smoke test proves the boundary stands on its own, independent
    // of anything Zig-side — the header is a real C contract, not a private
    // detail of the wrapper.
    const c_smoke = b.addExecutable(.{
        .name = "zozz-c-smoke",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    c_smoke.root_module.link_libc = true;
    c_smoke.root_module.addIncludePath(b.path("ffi"));
    c_smoke.root_module.addCSourceFile(.{
        .file = b.path("tests/c_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    c_smoke.root_module.addIncludePath(b.path("tests"));
    c_smoke.root_module.linkLibrary(lib);
    c_smoke.root_module.linkLibrary(fixture);

    const c_test_step = b.step("test-c", "Run the C-level smoke test");
    c_test_step.dependOn(&b.addRunArtifact(c_smoke).step);
    test_step.dependOn(c_test_step);
}
