//===----------------------------------------------------------------------===//
// zozz — GV4 group-varint codec.
//
// A direct, faithful binding rather than a port: the encoding is a wire
// format that has to stay bit-identical with what ozz's own animation loader
// reads, and it is what a host needs in order to interpret the
// iframe_entries buffer zozzAnimationKeyframeIframeEntries hands back. See
// group_varint.h upstream for the format itself.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_ENCODE_H_
#define ZOZZ_ENCODE_H_

#include <stddef.h>
#include <stdint.h>

#include "zozz.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Encodes 4 uint32 values with group-varint (GV4) encoding. `out_capacity`
/// must be at least 17 bytes (4 full uint32 plus the header byte) regardless
/// of how small `values` actually are -- ozz's own encoder requires that much
/// room unconditionally. Writes `*out_size` (5-17) with the number of bytes
/// actually used.
ZOZZ_API ZozzResult zozzEncodeGV4(const uint32_t values[4], uint8_t* out,
                                  size_t out_capacity, size_t* out_size);

/// Decodes 4 uint32 values encoded by zozzEncodeGV4. Nothing past
/// `buffer_size` is read: ZOZZ_RESULT_BUFFER_TOO_SMALL when the buffer holds
/// less than the group its first byte describes (5-17 bytes). Writes
/// `*bytes_read` with the bytes the group occupied.
ZOZZ_API ZozzResult zozzDecodeGV4(const uint8_t* buffer, size_t buffer_size,
                                  uint32_t out[4], size_t* bytes_read);

/// Worst-case buffer size (bytes) for encoding `values_count` values with
/// zozzEncodeGV4Stream. `values_count` must be a multiple of 4.
ZOZZ_API ZozzResult zozzComputeGV4WorstBufferSize(size_t values_count,
                                                  size_t* out);

/// Encodes `values_count` (a multiple of 4) uint32 values as a stream of GV4
/// groups. `out_capacity` must be at least
/// zozzComputeGV4WorstBufferSize(values_count), else
/// ZOZZ_RESULT_BUFFER_TOO_SMALL. Writes `*out_size` with the bytes used.
ZOZZ_API ZozzResult zozzEncodeGV4Stream(const uint32_t* values,
                                        size_t values_count, uint8_t* out,
                                        size_t out_capacity, size_t* out_size);

/// Decodes `values_count` (a multiple of 4) uint32 values from a GV4 stream
/// produced by zozzEncodeGV4Stream. Nothing past `buffer_size` is read:
/// ZOZZ_RESULT_BUFFER_TOO_SMALL when it holds less than values_count +
/// values_count/4 bytes (the minimum encoding) or than the groups' first bytes
/// describe. Writes `*bytes_read`.
ZOZZ_API ZozzResult zozzDecodeGV4Stream(const uint8_t* buffer,
                                        size_t buffer_size, uint32_t* values,
                                        size_t values_count,
                                        size_t* bytes_read);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_ENCODE_H_
