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
pub fn encodeGV4(values: [4]u32, out: []u8, failure: *err.Failure) err.Error!usize {
    var used: usize = undefined;
    try err.check(failure, .encode_gv4, c.zozzEncodeGV4(&values, out.ptr, out.len, &used));
    return used;
}

/// Decodes 4 values encoded by `encodeGV4`, reading nothing past `buffer`:
/// `error.BufferTooSmall` when it holds less than the group its first byte
/// describes (5-17 bytes). Returns the bytes the group occupied.
pub fn decodeGV4(buffer: err.Bytes, out: *[4]u32, failure: *err.Failure) err.Error!usize {
    const bytes = buffer.readForParse();
    var consumed: usize = undefined;
    try err.check(failure, .decode_gv4, c.zozzDecodeGV4(bytes.ptr, bytes.len, out, &consumed));
    return consumed;
}

/// Worst-case buffer size (bytes) for encoding `values_count` values with
/// `encodeGV4Stream`. `values_count` must be a multiple of 4.
pub fn computeGV4WorstBufferSize(values_count: usize, failure: *err.Failure) err.Error!usize {
    var out: usize = undefined;
    try err.check(failure, .compute_gv4_worst_buffer_size, c.zozzComputeGV4WorstBufferSize(values_count, &out));
    return out;
}

/// Encodes `values.len` (a multiple of 4) values as a stream of GV4 groups.
/// `out` must be at least `computeGV4WorstBufferSize(values.len)` bytes.
/// Returns the number of bytes actually used.
pub fn encodeGV4Stream(values: []const u32, out: []u8, failure: *err.Failure) err.Error!usize {
    var used: usize = undefined;
    try err.check(failure, .encode_gv4_stream, c.zozzEncodeGV4Stream(values.ptr, values.len, out.ptr, out.len, &used));
    return used;
}

/// Decodes a stream produced by `encodeGV4Stream`. `values.len` must be a
/// multiple of 4. Nothing past `buffer` is read: `error.BufferTooSmall` when
/// it holds less than `values.len + values.len / 4` bytes (the minimum
/// encoding) or than the groups' first bytes describe. Returns the bytes
/// consumed.
pub fn decodeGV4Stream(buffer: err.Bytes, values: []u32, failure: *err.Failure) err.Error!usize {
    const bytes = buffer.readForParse();
    var consumed: usize = undefined;
    try err.check(failure, .decode_gv4_stream, c.zozzDecodeGV4Stream(bytes.ptr, bytes.len, values.ptr, values.len, &consumed));
    return consumed;
}
