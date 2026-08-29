//! GV4 group-varint codec: a direct binding, not a port — the wire format has
//! to stay bit-identical with what ozz's own animation loader reads, which is
//! what a host needs to interpret the `iframe_entries` buffer
//! `zozzAnimationKeyframeIframeEntries` hands back. See
//! `libs/ozz/include/ozz/base/encode/group_varint.h` for the format itself.

const c = @import("c.zig");
const err = @import("error.zig");

/// Encodes 4 values with group-varint encoding. `out` must be at least 17
/// bytes (4 full uint32 plus the header byte), regardless of how small
/// `values` actually are. Returns the number of bytes actually used (5-17).
pub fn encodeGV4(values: [4]u32, out: []u8) err.Error!usize {
    var used: usize = undefined;
    try err.check(c.zozzEncodeGV4(&values, out.ptr, out.len, &used));
    return used;
}

/// Decodes 4 values encoded by `encodeGV4`. `buffer` must be at least 5
/// bytes; per the format, up to 3 bytes past what this group actually needs
/// may be read (and must be valid to read, even though their value is
/// discarded). Returns the number of bytes this group actually occupied.
pub fn decodeGV4(buffer: []const u8, out: *[4]u32) err.Error!usize {
    var consumed: usize = undefined;
    try err.check(c.zozzDecodeGV4(buffer.ptr, buffer.len, out, &consumed));
    return consumed;
}

/// Worst-case buffer size (bytes) for encoding `values_count` values with
/// `encodeGV4Stream`. `values_count` must be a multiple of 4.
pub fn computeGV4WorstBufferSize(values_count: usize) err.Error!usize {
    var out: usize = undefined;
    try err.check(c.zozzComputeGV4WorstBufferSize(values_count, &out));
    return out;
}

/// Encodes `values.len` (a multiple of 4) values as a stream of GV4 groups.
/// `out` must be at least `computeGV4WorstBufferSize(values.len)` bytes.
/// Returns the number of bytes actually used.
pub fn encodeGV4Stream(values: []const u32, out: []u8) err.Error!usize {
    var used: usize = undefined;
    try err.check(c.zozzEncodeGV4Stream(values.ptr, values.len, out.ptr, out.len, &used));
    return used;
}

/// Decodes a stream produced by `encodeGV4Stream`. `values.len` must be a
/// multiple of 4; `buffer` must hold at least `values.len + values.len / 4`
/// bytes (the minimum possible encoding) — and, per `decodeGV4`, a few bytes
/// past that minimum must be valid to read for the last group. Returns the
/// number of bytes consumed.
pub fn decodeGV4Stream(buffer: []const u8, values: []u32) err.Error!usize {
    var consumed: usize = undefined;
    try err.check(c.zozzDecodeGV4Stream(buffer.ptr, buffer.len, values.ptr, values.len, &consumed));
    return consumed;
}
