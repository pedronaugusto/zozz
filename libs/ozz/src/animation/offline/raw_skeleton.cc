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

#include "ozz/animation/offline/raw_skeleton.h"

#include "ozz/animation/runtime/skeleton.h"
#include "ozz/base/maths/simd_math.h"

namespace ozz {
namespace animation {
namespace offline {

RawSkeleton::RawSkeleton() {}

RawSkeleton::~RawSkeleton() {}

namespace {
// SkeletonBuilder normalizes each joint's rotation into the rest pose, and
// LocalToModelJob asserts that pose's rotations are unit: a rotation it
// cannot normalize, not a number or squaring past a float, is invalid.
struct RotationChecker {
  void operator()(const RawSkeleton::Joint& _joint, const RawSkeleton::Joint*) {
    const math::SimdFloat4 rotation = math::NormalizeSafe4(
        math::simd_float4::LoadPtrU(&_joint.transform.rotation.x),
        math::simd_float4::w_axis());
    valid = valid && math::AreAllTrue1(math::IsNormalizedEst4(rotation));
  }
  bool valid = true;
};
}  // namespace

bool RawSkeleton::Validate() const {
  if (num_joints() > Skeleton::kMaxJoints) {
    return false;
  }
  return IterateJointsDF(*this, RotationChecker()).valid;
}

namespace {
struct JointCounter {
  JointCounter() : num_joints(0) {}
  void operator()(const RawSkeleton::Joint&, const RawSkeleton::Joint*) {
    ++num_joints;
  }
  int num_joints;
};
}  // namespace

// Iterates through all the root children and count them.
int RawSkeleton::num_joints() const {
  return IterateJointsDF(*this, JointCounter()).num_joints;
}
}  // namespace offline
}  // namespace animation
}  // namespace ozz
