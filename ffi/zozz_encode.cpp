//===----------------------------------------------------------------------===//
// zozz — GV4 group-varint codec.
//===----------------------------------------------------------------------===//

#include "zozz_encode.h"

#include "ozz/base/encode/group_varint.h"
#include "zozz_internal.h"

namespace {

constexpr size_t kGV4GroupSize = 4;
/// EncodeGV4's own fixed contract: room for 4 full uint32 plus the prefix
/// byte, whatever the values actually need.
constexpr size_t kGV4WorstGroupSize = 4 * sizeof(uint32_t) + 1;
/// DecodeGV4's minimum: the prefix byte plus (at least) one byte per value.
constexpr size_t kGV4MinGroupSize = 1 + kGV4GroupSize;

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
  if (buffer_size < kGV4MinGroupSize) return ZOZZ_RESULT_BUFFER_TOO_SMALL;

  const ozz::span<const ozz::byte> input(buffer, buffer_size);
  const ozz::span<uint32_t> output(out, kGV4GroupSize);
  const ozz::span<const ozz::byte> remaining = ozz::DecodeGV4(input, output);
  *bytes_read = buffer_size - remaining.size();
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

  const ozz::span<const ozz::byte> input(buffer, buffer_size);
  const ozz::span<uint32_t> stream(values, values_count);
  const ozz::span<const ozz::byte> remaining =
      ozz::DecodeGV4Stream(input, stream);
  *bytes_read = buffer_size - remaining.size();
  return ZOZZ_RESULT_OK;
}

}  // extern "C"
