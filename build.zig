const std = @import("std");

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
};

/// ozz's offline builders, needed only by the test fixture. They turn raw
/// keyframe data into runtime objects — the same path a future glTF cook would
/// take, which is a second reason to keep them compiling.
const ozz_offline_sources = [_][]const u8{
    "libs/ozz/src/animation/offline/raw_skeleton.cc",
    "libs/ozz/src/animation/offline/raw_animation.cc",
    "libs/ozz/src/animation/offline/raw_animation_utils.cc",
    "libs/ozz/src/animation/offline/skeleton_builder.cc",
    "libs/ozz/src/animation/offline/animation_builder.cc",
};

/// The zozz C boundary. One translation unit per concern — deliberately not a
/// single monolithic binding file.
const zozz_ffi_sources = [_][]const u8{
    "ffi/zozz_core.cpp",
    "ffi/zozz_offline.cpp",
    "ffi/zozz_pose.cpp",
    "ffi/zozz_skeleton.cpp",
    "ffi/zozz_animation.cpp",
    "ffi/zozz_sampling.cpp",
    "ffi/zozz_abi.cpp",
};

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
        .sanitize_c = b.option(
            bool,
            "sanitize_c",
            "Keep Zig's C undefined-behaviour sanitizer enabled",
        ) orelse (optimize == .Debug),
    };

    // Every ABI- or behaviour-affecting option is mirrored into a Zig module
    // so the wrapper can never disagree with how the C++ was compiled. The
    // single `options` struct above is the one source both sides read from.
    const options_step = b.addOptions();
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
    lib.root_module.sanitize_c = if (options.sanitize_c) .full else .off;

    // Consumers get the public header without reaching into the source tree.
    lib.installHeader(b.path("ffi/zozz.h"), "zozz.h");

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

    // Only installed when zozz is built directly; as a dependency the
    // consumer decides what lands in its prefix.
    if (b.pkg_hash.len == 0) b.installArtifact(lib);

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
