//! ozz::animation::offline::OzzImporter, ozz's converter interface, in both
//! directions:
//!
//!  * a concrete glTF-backed importer (`Importer.initFromGltf`, `-Dgltf`);
//!  * a host-implementable `ImporterInterface`, so a Zig host with its own
//!    source format can plug into the same pipeline (`-Doptions`, ozz's
//!    `ozz_animation_tools`).
//!
//! Every method returns `error.Unsupported` when the option its
//! implementation needs is off. `run` (`OzzImporter::operator()`, the CLI
//! driver) always returns `error.Unsupported`: its dependency chain needs
//! jsoncpp, which UPSTREAM.md records as deliberately excluded from the
//! vendored tree. It is kept so the interface stays complete.
//!
//! An `Importer` is opaque regardless of which side created it: every method
//! below drives it through `OzzImporter`'s own virtual interface, so a
//! host-implemented importer gets the exact same accessors a glTF import
//! does.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const skeleton_mod = @import("skeleton.zig");
const offline_mod = @import("offline.zig");
const rawtrack_mod = @import("rawtrack.zig");

/// Mirrors `OzzImporter::NodeType` exactly: which source node kinds should be
/// considered skeleton joints.
pub const ImportNodeType = c.ImportNodeType;

/// Mirrors `OzzImporter::NodeProperty::Type` exactly.
pub const NodePropertyType = c.NodePropertyType;

/// One property `iterateNodeProperties` reports. `name` is borrowed and
/// valid only for the duration of the visit call it is passed to.
pub const NodeProperty = c.NodeProperty;

/// A host's own `ImporterInterface`, reused verbatim rather than wrapped —
/// the same shape `archive.zig`'s `Stream` takes from `ZozzStream`. `load`,
/// `import_skeleton` and `import_animation` are required: `Importer.init`
/// rejects a NULL one with `error.InvalidArgument` at the call, rather than
/// on the first use that would have needed it. The rest are optional; leave
/// `null` to report "nothing here" the way `GltfImporter` itself does for
/// tracks and properties, which it does not support.
pub const ImporterInterface = c.ImporterInterface;

/// A skeleton or animation import, glTF-backed or host-backed.
pub const Importer = struct {
    handle: *c.Importer,

    /// Wraps a host's `ImporterInterface`. Behind `-Doptions`.
    pub fn init(interface: *const ImporterInterface) err.Error!Importer {
        var handle: *c.Importer = undefined;
        try err.check(c.zozzImporterCreate(interface, &handle));
        return .{ .handle = handle };
    }

    /// Constructs a glTF importer and loads `path` (.gltf or .glb, guessed
    /// from the extension) in one call. Behind `-Dgltf`.
    pub fn initFromGltf(path: [*:0]const u8) err.Error!Importer {
        var handle: *c.Importer = undefined;
        try err.check(c.zozzGltfImporterCreate(path, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: Importer) void {
        c.zozzImporterDestroy(self.handle);
    }

    /// Loads (or reloads) source data. Most callers only need this to point
    /// a host-backed importer at its source; `initFromGltf` already loaded.
    pub fn load(self: Importer, filename: [*:0]const u8) err.Error!void {
        try err.check(c.zozzImporterLoad(self.handle, filename));
    }

    /// Imports a skeleton, handed back as the same `RawSkeleton` type
    /// `RawSkeleton.init` + `addJoint` builds by hand.
    pub fn importSkeleton(self: Importer, types: ImportNodeType) err.Error!offline_mod.RawSkeleton {
        var handle: *c.RawSkeleton = undefined;
        try err.check(c.zozzImporterImportSkeleton(self.handle, types, &handle));
        return .{ .handle = handle };
    }

    /// Visits every animation name available from the source data.
    /// `context` must be a pointer; it is handed back to `visit` unchanged.
    pub fn iterateAnimationNames(
        self: Importer,
        context: anytype,
        comptime visit: fn (@TypeOf(context), name: [:0]const u8) void,
    ) err.Error!void {
        const Context = @TypeOf(context);
        comptime if (@typeInfo(Context) != .pointer) {
            @compileError("iterateAnimationNames: context must be a pointer");
        };
        const Trampoline = struct {
            fn call(name: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
                const ctx: Context = @ptrCast(@alignCast(user.?));
                visit(ctx, std.mem.span(name));
            }
        };
        try err.check(c.zozzImporterIterateAnimationNames(self.handle, &Trampoline.call, @ptrCast(context)));
    }

    /// Imports one named animation against `skeleton`'s joints, handed back
    /// as the same `RawAnimation` type `RawAnimation.init` + `push*` builds
    /// by hand. `sampling_rate` of 0 means "let the importer choose".
    pub fn importAnimation(
        self: Importer,
        animation_name: [*:0]const u8,
        skeleton: skeleton_mod.Skeleton,
        sampling_rate: f32,
    ) err.Error!offline_mod.RawAnimation {
        var handle: *c.RawAnimation = undefined;
        try err.check(c.zozzImporterImportAnimation(
            self.handle,
            animation_name,
            skeleton.handle,
            sampling_rate,
            &handle,
        ));
        return .{ .handle = handle };
    }

    /// Visits every property available for `node_name`. `context` must be a
    /// pointer; it is handed back to `visit` unchanged.
    pub fn iterateNodeProperties(
        self: Importer,
        node_name: [*:0]const u8,
        context: anytype,
        comptime visit: fn (@TypeOf(context), property: NodeProperty) void,
    ) err.Error!void {
        const Context = @TypeOf(context);
        comptime if (@typeInfo(Context) != .pointer) {
            @compileError("iterateNodeProperties: context must be a pointer");
        };
        const Trampoline = struct {
            fn call(property: *const NodeProperty, user: ?*anyopaque) callconv(.c) void {
                const ctx: Context = @ptrCast(@alignCast(user.?));
                visit(ctx, property.*);
            }
        };
        try err.check(c.zozzImporterIterateNodeProperties(self.handle, node_name, &Trampoline.call, @ptrCast(context)));
    }

    /// Track imports, one per value width, mirroring `OzzImporter`'s four
    /// `Import(...Raw*Track*)` overloads.
    pub fn importFloatTrack(
        self: Importer,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
    ) err.Error!rawtrack_mod.RawFloatTrack {
        var handle: *c.RawFloatTrack = undefined;
        try err.check(c.zozzImporterImportFloatTrack(
            self.handle,
            animation_name,
            node_name,
            track_name,
            track_type,
            sampling_rate,
            &handle,
        ));
        return .{ .handle = handle };
    }

    pub fn importFloat2Track(
        self: Importer,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
    ) err.Error!rawtrack_mod.RawFloat2Track {
        var handle: *c.RawFloat2Track = undefined;
        try err.check(c.zozzImporterImportFloat2Track(
            self.handle,
            animation_name,
            node_name,
            track_name,
            track_type,
            sampling_rate,
            &handle,
        ));
        return .{ .handle = handle };
    }

    pub fn importFloat3Track(
        self: Importer,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
    ) err.Error!rawtrack_mod.RawFloat3Track {
        var handle: *c.RawFloat3Track = undefined;
        try err.check(c.zozzImporterImportFloat3Track(
            self.handle,
            animation_name,
            node_name,
            track_name,
            track_type,
            sampling_rate,
            &handle,
        ));
        return .{ .handle = handle };
    }

    pub fn importFloat4Track(
        self: Importer,
        animation_name: [*:0]const u8,
        node_name: [*:0]const u8,
        track_name: [*:0]const u8,
        track_type: NodePropertyType,
        sampling_rate: f32,
    ) err.Error!rawtrack_mod.RawFloat4Track {
        var handle: *c.RawFloat4Track = undefined;
        try err.check(c.zozzImporterImportFloat4Track(
            self.handle,
            animation_name,
            node_name,
            track_name,
            track_type,
            sampling_rate,
            &handle,
        ));
        return .{ .handle = handle };
    }

    /// `OzzImporter::operator()`: parses `argv` as ozz's own importer CLI
    /// would, reads a JSON config file and writes .ozz files to disk.
    /// Currently always `error.Unsupported`; see the module comment above.
    pub fn run(self: Importer, argv: []const [*:0]const u8) err.Error!void {
        try err.check(c.zozzImporterRun(self.handle, @intCast(argv.len), argv.ptr));
    }
};
