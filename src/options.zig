//! ozz's command-line option parser (ozz/options/options.h), behind
//! `-Doptions`. Every function here returns `error.Unsupported` when the
//! library was built without it. ozz's own API is macro-driven
//! (`OZZ_OPTIONS_DECLARE_INT` and friends declare options with static storage
//! duration), which has no Zig equivalent; this binds the runtime classes those
//! macros drive instead: create an option, register it with a parser, parse a
//! command line. A parser here is a caller-owned instance, not ozz's hidden
//! process-global one — `ozz::options::ParseCommandLine()` only reaches a
//! `Parser` private to `options.cc`, through macros a Zig host cannot use.
//! `OptionsParser.parseCommandLine` does what that free function does (set
//! usage/version, then parse), against a caller-owned parser.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");

pub const ParseResult = c.OptionsParseResult;

/// A caller-owned option parser. Options are registered with one before
/// `parseCommandLine`; destroying it releases its own reference to whatever
/// is still registered (see `Option`'s doc comment).
pub const OptionsParser = struct {
    handle: ?*c.OptionsParser,

    pub fn init() err.Error!OptionsParser {
        var handle: *c.OptionsParser = undefined;
        try err.check(c.zozzOptionsParserCreate(&handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *OptionsParser) void {
        if (self.handle) |handle| c.zozzOptionsParserDestroy(handle);
        self.handle = null;
    }

    /// Sets usage/version, then parses `argv[1..]` against every option
    /// currently registered — `argv[0]` is taken as the executable path,
    /// matching `ozz::options::ParseCommandLine`. `.exit_success` (e.g.
    /// `--help` was given) is not a failure.
    pub fn parseCommandLine(
        self: OptionsParser,
        argv: []const [*:0]const u8,
        version_string: ?[*:0]const u8,
        usage_string: ?[*:0]const u8,
    ) err.Error!ParseResult {
        var result: ParseResult = undefined;
        try err.check(c.zozzOptionsParserParseCommandLine(
            self.handle.?,
            @intCast(argv.len),
            argv.ptr,
            version_string,
            usage_string,
            &result,
        ));
        return result;
    }

    /// Writes the usage/help screen directly to stdout — the same one a
    /// `--help` argument to `parseCommandLine` writes.
    pub fn help(self: OptionsParser) err.Error!void {
        try err.check(c.zozzOptionsParserHelp(self.handle.?));
    }

    /// Fails on a duplicate name, a duplicate registration of `option`, or a
    /// full parser (see `maxOptions`).
    /// Registers `option` — an `IntOption`, `FloatOption`, `BoolOption` or
    /// `StringOption`, all four of which wrap one `c.Option`. Taking the
    /// option rather than its handle keeps `.handle` out of calling code.
    pub fn register(self: OptionsParser, option: anytype) err.Error!void {
        try err.check(c.zozzOptionsParserRegister(self.handle.?, option.handle.?));
    }

    /// Fails if `option` is not currently registered with `self`.
    pub fn unregister(self: OptionsParser, option: anytype) err.Error!void {
        try err.check(c.zozzOptionsParserUnregister(self.handle.?, option.handle.?));
    }

    pub fn setUsage(self: OptionsParser, usage_string: ?[*:0]const u8) err.Error!void {
        try err.check(c.zozzOptionsParserSetUsage(self.handle.?, usage_string));
    }

    pub fn usage(self: OptionsParser) [:0]const u8 {
        return std.mem.span(c.zozzOptionsParserUsage(self.handle.?));
    }

    pub fn setVersion(self: OptionsParser, version_string: ?[*:0]const u8) err.Error!void {
        try err.check(c.zozzOptionsParserSetVersion(self.handle.?, version_string));
    }

    /// Capacity for custom options (excludes the built-in --help/--version).
    pub fn maxOptions(self: OptionsParser) u32 {
        return @intCast(c.zozzOptionsParserMaxOptions(self.handle.?));
    }

    /// "" until `parseCommandLine` has run once.
    pub fn executableName(self: OptionsParser) [:0]const u8 {
        return std.mem.span(c.zozzOptionsParserExecutableName(self.handle.?));
    }

    /// "" until `parseCommandLine` has run once.
    pub fn executablePath(self: OptionsParser) [:0]const u8 {
        return std.mem.span(c.zozzOptionsParserExecutablePath(self.handle.?));
    }
};

/// Shared accessors every option kind below repeats. Not called directly;
/// each of IntOption/FloatOption/BoolOption/StringOption below forwards to
/// it against its own `handle`.
fn optionName(handle: *const c.Option) [:0]const u8 {
    return std.mem.span(c.zozzOptionName(handle));
}
fn optionHelp(handle: *const c.Option) [:0]const u8 {
    return std.mem.span(c.zozzOptionHelp(handle));
}
fn optionRequired(handle: *const c.Option) bool {
    return c.zozzOptionRequired(handle);
}
/// A required option is statisfied once parsed; a non-required one always is.
/// (Spelling matches ozz::options::Option::statisfied().)
fn optionStatisfied(handle: *const c.Option) bool {
    return c.zozzOptionStatisfied(handle);
}
fn optionRestoreDefault(handle: *c.Option) err.Error!void {
    try err.check(c.zozzOptionRestoreDefault(handle));
}

pub const IntOption = struct {
    handle: ?*c.Option,

    /// `name` and `help` are borrowed for the life of the option (ozz stores
    /// the pointers it is given, not copies).
    pub fn init(option_name: [*:0]const u8, option_help: ?[*:0]const u8, default_value: i32, option_required: bool) err.Error!IntOption {
        var handle: *c.Option = undefined;
        try err.check(c.zozzIntOptionCreate(option_name, option_help, default_value, option_required, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *IntOption) void {
        if (self.handle) |handle| c.zozzOptionDestroy(handle);
        self.handle = null;
    }

    pub fn value(self: IntOption) err.Error!i32 {
        var out: i32 = undefined;
        try err.check(c.zozzIntOptionValue(self.handle.?, &out));
        return out;
    }

    /// The default this option was created with, unchanged by parsing.
    pub fn default(self: IntOption) err.Error!i32 {
        var out: i32 = undefined;
        try err.check(c.zozzIntOptionDefault(self.handle.?, &out));
        return out;
    }

    pub fn name(self: IntOption) [:0]const u8 {
        return optionName(self.handle.?);
    }
    pub fn help(self: IntOption) [:0]const u8 {
        return optionHelp(self.handle.?);
    }
    pub fn required(self: IntOption) bool {
        return optionRequired(self.handle.?);
    }
    pub fn statisfied(self: IntOption) bool {
        return optionStatisfied(self.handle.?);
    }
    pub fn restoreDefault(self: IntOption) err.Error!void {
        try optionRestoreDefault(self.handle.?);
    }
};

pub const FloatOption = struct {
    handle: ?*c.Option,

    pub fn init(option_name: [*:0]const u8, option_help: ?[*:0]const u8, default_value: f32, option_required: bool) err.Error!FloatOption {
        var handle: *c.Option = undefined;
        try err.check(c.zozzFloatOptionCreate(option_name, option_help, default_value, option_required, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *FloatOption) void {
        if (self.handle) |handle| c.zozzOptionDestroy(handle);
        self.handle = null;
    }

    pub fn value(self: FloatOption) err.Error!f32 {
        var out: f32 = undefined;
        try err.check(c.zozzFloatOptionValue(self.handle.?, &out));
        return out;
    }

    /// The default this option was created with, unchanged by parsing.
    pub fn default(self: FloatOption) err.Error!f32 {
        var out: f32 = undefined;
        try err.check(c.zozzFloatOptionDefault(self.handle.?, &out));
        return out;
    }

    pub fn name(self: FloatOption) [:0]const u8 {
        return optionName(self.handle.?);
    }
    pub fn help(self: FloatOption) [:0]const u8 {
        return optionHelp(self.handle.?);
    }
    pub fn required(self: FloatOption) bool {
        return optionRequired(self.handle.?);
    }
    pub fn statisfied(self: FloatOption) bool {
        return optionStatisfied(self.handle.?);
    }
    pub fn restoreDefault(self: FloatOption) err.Error!void {
        try optionRestoreDefault(self.handle.?);
    }
};

pub const BoolOption = struct {
    handle: ?*c.Option,

    pub fn init(option_name: [*:0]const u8, option_help: ?[*:0]const u8, default_value: bool, option_required: bool) err.Error!BoolOption {
        var handle: *c.Option = undefined;
        try err.check(c.zozzBoolOptionCreate(option_name, option_help, default_value, option_required, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *BoolOption) void {
        if (self.handle) |handle| c.zozzOptionDestroy(handle);
        self.handle = null;
    }

    pub fn value(self: BoolOption) err.Error!bool {
        var out: bool = undefined;
        try err.check(c.zozzBoolOptionValue(self.handle.?, &out));
        return out;
    }

    /// The default this option was created with, unchanged by parsing.
    pub fn default(self: BoolOption) err.Error!bool {
        var out: bool = undefined;
        try err.check(c.zozzBoolOptionDefault(self.handle.?, &out));
        return out;
    }

    pub fn name(self: BoolOption) [:0]const u8 {
        return optionName(self.handle.?);
    }
    pub fn help(self: BoolOption) [:0]const u8 {
        return optionHelp(self.handle.?);
    }
    pub fn required(self: BoolOption) bool {
        return optionRequired(self.handle.?);
    }
    pub fn statisfied(self: BoolOption) bool {
        return optionStatisfied(self.handle.?);
    }
    pub fn restoreDefault(self: BoolOption) err.Error!void {
        try optionRestoreDefault(self.handle.?);
    }
};

pub const StringOption = struct {
    handle: ?*c.Option,

    /// `default_value` is borrowed the same way `name`/`help` are.
    pub fn init(option_name: [*:0]const u8, option_help: ?[*:0]const u8, default_value: ?[*:0]const u8, option_required: bool) err.Error!StringOption {
        var handle: *c.Option = undefined;
        try err.check(c.zozzStringOptionCreate(option_name, option_help, default_value, option_required, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *StringOption) void {
        if (self.handle) |handle| c.zozzOptionDestroy(handle);
        self.handle = null;
    }

    /// Borrowed: the default_value pointer until a command line is parsed,
    /// then a pointer into whichever argv this option's value last parsed
    /// from — valid only as long as that buffer is.
    pub fn value(self: StringOption) err.Error![:0]const u8 {
        var out: [*:0]const u8 = undefined;
        try err.check(c.zozzStringOptionValue(self.handle.?, &out));
        return std.mem.span(out);
    }

    /// The default this option was created with, unchanged by parsing.
    /// Borrowed the same way `name` is.
    pub fn default(self: StringOption) err.Error![:0]const u8 {
        var out: [*:0]const u8 = undefined;
        try err.check(c.zozzStringOptionDefault(self.handle.?, &out));
        return std.mem.span(out);
    }

    pub fn name(self: StringOption) [:0]const u8 {
        return optionName(self.handle.?);
    }
    pub fn help(self: StringOption) [:0]const u8 {
        return optionHelp(self.handle.?);
    }
    pub fn required(self: StringOption) bool {
        return optionRequired(self.handle.?);
    }
    pub fn statisfied(self: StringOption) bool {
        return optionStatisfied(self.handle.?);
    }
    pub fn restoreDefault(self: StringOption) err.Error!void {
        try optionRestoreDefault(self.handle.?);
    }
};
