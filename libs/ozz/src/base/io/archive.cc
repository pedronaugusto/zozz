//----------------------------------------------------------------------------//
//                                                                            //
// ozz-animation is hosted at http://github.com/guillaumeblanc/ozz-animation  //
// and distributed under the MIT License (MIT).                               //
//                                                                            //
// Copyright (c) Guillaume Blanc                                              //
//                                                                            //
// Permission is hereby granted, free of charge, to any person obtaining a    //
// copy of this software and associated documentation files (the "Software"), //
// to deal in the Software without restriction, including without limitation  //
// the rights to use, copy, modify, merge, publish, distribute, sublicense,   //
// and/or sell copies of the Software, and to permit persons to whom the      //
// Software is furnished to do so, subject to the following conditions:       //
//                                                                            //
// The above copyright notice and this permission notice shall be included in //
// all copies or substantial portions of the Software.                        //
//                                                                            //
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR //
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,   //
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL    //
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER //
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING    //
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER        //
// DEALINGS IN THE SOFTWARE.                                                  //
//                                                                            //
//----------------------------------------------------------------------------//

#include "ozz/base/io/archive.h"

#include <cassert>

namespace ozz {
namespace io {

// OArchive implementation.

OArchive::OArchive(Stream* _stream, Endianness _endianness)
    : stream_(_stream), endian_swap_(_endianness != GetNativeEndianness()) {
  assert(stream_ && stream_->opened() &&
         "_stream argument must point a valid opened stream.");
  // Save as a single byte as it does not need to be swapped.
  uint8_t endianness = static_cast<uint8_t>(_endianness);
  *this << endianness;
}

// IArchive implementation.

IArchive::IArchive(Stream* _stream) : stream_(_stream), endian_swap_(false) {
  assert(stream_ && stream_->opened() &&
         "_stream argument must point a valid opened stream.");
  // Endianness was saved as a single byte, as it does not need to be swapped.
  uint8_t endianness;
  *this >> endianness;
  endian_swap_ = endianness != GetNativeEndianness();
}

void IArchive::Refuse(const char* _what, uint64_t _value, uint64_t _limit) {
  if (refusal_what_ != nullptr) {
    return;
  }
  refusal_what_ = _what;
  refusal_value_ = _value;
  refusal_limit_ = _limit;
}

size_t IArchive::remaining() const {
  const int tell = stream_->Tell();
  const size_t size = stream_->Size();
  if (tell < 0 || static_cast<size_t>(tell) >= size) {
    return 0;
  }
  return size - static_cast<size_t>(tell);
}

bool IArchive::CheckCount(const char* _what, uint64_t _count,
                          size_t _element_size, uint64_t _limit) {
  if (refused()) {
    return false;
  }
  const uint64_t fit = _element_size ? remaining() / _element_size : _limit;
  const uint64_t limit = fit < _limit ? fit : _limit;
  if (_count <= limit) {
    return true;
  }
  if (!refused()) {
    refusal_past_end_ = fit < _limit;
  }
  Refuse(_what, _count, limit);
  return false;
}

bool IArchive::Enter(const char* _what, uint64_t _limit) {
  if (refused()) {
    return false;
  }
  if (depth_ >= _limit) {
    Refuse(_what, depth_ + 1, _limit);
    return false;
  }
  ++depth_;
  return true;
}
}  // namespace io
}  // namespace ozz
