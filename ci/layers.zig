//! Production source layers, lowest first. Every production source has one
//! place; test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "C boundary", .patterns = &.{ "src/c.zig", "src/math.zig" } },
    .{ .name = "errors", .patterns = &.{"src/error.zig"} },
    .{ .name = "runtime objects and jobs", .patterns = &.{
        "src/animation.zig", "src/skeleton.zig", "src/track.zig",    "src/pose.zig",
        "src/encode.zig",    "src/options.zig",  "src/blending.zig", "src/ik.zig",
        "src/motion.zig",    "src/skinning.zig",
    } },
    .{ .name = "sampling and raw tracks", .patterns = &.{ "src/sampling.zig", "src/rawtrack.zig", "src/utils.zig" } },
    .{ .name = "memory", .patterns = &.{"src/memory.zig"} },
    .{ .name = "offline", .patterns = &.{"src/offline.zig"} },
    .{ .name = "optimizer and importer", .patterns = &.{ "src/optimizer.zig", "src/importer.zig" } },
    .{ .name = "archive", .patterns = &.{"src/archive.zig"} },
    .{ .name = "bindings", .patterns = &.{"src/zozz.zig"} },
};

pub const entries: []const []const u8 = &.{"src/zozz.zig"};

pub const modules: []const gantry.NamedModule = &.{};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "aegis",
        "builtin",
        "mathref_h",
        "std",
        "test_options",
        "zozz_h",
        "zozz_options",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/c.zig",
    "src/zozz.zig",
};
