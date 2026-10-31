//===----------------------------------------------------------------------===//
// zozz — GV4 group-varint codec.
//===----------------------------------------------------------------------===//

#include "zozz_encode.h"

#include <cstring>

#include "ozz/base/encode/group_varint.h"
#include "zozz_internal.h"

namespace {

constexpr size_t kGV4GroupSize = 4;
/// EncodeGV4's own fixed contract: room for 4 full uint32 plus the prefix
/// byte, whatever the values actually need.
constexpr size_t kGV4WorstGroupSize = 4 * sizeof(uint32_t) + 1;
/// DecodeGV4's minimum: the prefix byte plus (at least) one byte per value.
constexpr size_t kGV4MinGroupSize = 1 + kGV4GroupSize;
/// DecodeGV4 loads four bytes for each value, so it reads up to three past
/// the group.
constexpr size_t kGV4Overread = 3;

/// Decodes the group at the front of `input` with ozz's decoder, reading
/// nothing past `input`: a group ending within kGV4Overread bytes of its end
/// is decoded from a copy. The bytes it occupies, or 0 when its prefix
/// claims more than `input` holds.
size_t DecodeGroupWithin(const ozz::span<const ozz::byte>& input,
                         uint32_t out[4]) {
  if (input.size() < kGV4MinGroupSize) return 0;
  const uint8_t prefix = input[0];
  const size_t size = kGV4MinGroupSize + (prefix & 0x3) +
                      ((prefix >> 2) & 0x3) + ((prefix >> 4) & 0x3) +
                      (prefix >> 6);
  if (size > input.size()) return 0;
  const ozz::span<uint32_t> output(out, kGV4GroupSize);
  if (input.size() - size >= kGV4Overread) {
    ozz::DecodeGV4(input, output);
  } else {
    ozz::byte copy[kGV4WorstGroupSize + kGV4Overread] = {};
    std::memcpy(copy, input.data(), size);
    ozz::DecodeGV4(ozz::span<const ozz::byte>(copy, sizeof(copy)), output);
  }
  return size;
}

}  // namespace

extern "C" {

ZozzResult zozzEncodeGV4(const uint32_t values[4], uint8_t* out,
                         size_t out_capacity, size_t* out_size) {
  if (values == nullptr || out == nullptr || out_size == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (out_capacity < kGV4WorstGroupSize) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  const ozz::span<const uint32_t> input(values, kGV4GroupSize);
  const ozz::span<ozz::byte> buffer(out, out_capacity);
  const ozz::span<ozz::byte> remaining = ozz::EncodeGV4(input, buffer);
  *out_size = out_capacity - remaining.size();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzDecodeGV4(const uint8_t* buffer, size_t buffer_size,
                         uint32_t out[4], size_t* bytes_read) {
  if (buffer == nullptr || out == nullptr || bytes_read == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  const size_t size =
      DecodeGroupWithin(ozz::span<const ozz::byte>(buffer, buffer_size), out);
  if (size == 0) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
  *bytes_read = size;
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzComputeGV4WorstBufferSize(size_t values_count, size_t* out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (values_count % kGV4GroupSize != 0) return ZOZZ_RESULT_INVALID_ARGUMENT;

  // Only .size() is read by ComputeGV4WorstBufferSize; the data pointer is
  // never dereferenced, so a null one sized to values_count is safe here.
  const ozz::span<const uint32_t> stream(
      static_cast<const uint32_t*>(nullptr), values_count);
  *out = ozz::ComputeGV4WorstBufferSize(stream);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzEncodeGV4Stream(const uint32_t* values, size_t values_count,
                               uint8_t* out, size_t out_capacity,
                               size_t* out_size) {
  if (values == nullptr || out == nullptr || out_size == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (values_count % kGV4GroupSize != 0) return ZOZZ_RESULT_INVALID_ARGUMENT;

  const ozz::span<const uint32_t> stream(values, values_count);
  const size_t worst = ozz::ComputeGV4WorstBufferSize(stream);
  if (out_capacity < worst) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  const ozz::span<ozz::byte> buffer(out, out_capacity);
  const ozz::span<ozz::byte> remaining = ozz::EncodeGV4Stream(stream, buffer);
  *out_size = out_capacity - remaining.size();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzDecodeGV4Stream(const uint8_t* buffer, size_t buffer_size,
                               uint32_t* values, size_t values_count,
                               size_t* bytes_read) {
  if (buffer == nullptr || values == nullptr || bytes_read == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  if (values_count % kGV4GroupSize != 0) return ZOZZ_RESULT_INVALID_ARGUMENT;

  const size_t minimum = values_count + values_count / kGV4GroupSize;
  if (buffer_size < minimum) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  // DecodeGV4Stream is DecodeGV4 group after group; each is bounded here.
  size_t at = 0;
  for (size_t i = 0; i < values_count; i += kGV4GroupSize) {
    const size_t size = DecodeGroupWithin(
        ozz::span<const ozz::byte>(buffer + at, buffer_size - at), values + i);
    if (size == 0) return ZOZZ_RESULT_BUFFER_TOO_SMALL;
    at += size;
  }
  *bytes_read = at;
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
