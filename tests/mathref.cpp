//===----------------------------------------------------------------------===//
// zozz — the reference half of the maths differential test. Every case is one
// call into ozz and nothing else: this file must add no arithmetic of its own,
// or it stops being a reference.
//===----------------------------------------------------------------------===//

#include "mathref.h"

#include <cstring>

#include "ozz/base/maths/box.h"
#include "ozz/animation/offline/raw_animation_utils.h"
#include "ozz/base/maths/quaternion.h"
#include "ozz/base/maths/simd_math.h"
#include "ozz/base/maths/simd_quaternion.h"
#include "ozz/base/maths/soa_float.h"
#include "ozz/base/maths/soa_quaternion.h"
#include "ozz/base/maths/transform.h"

namespace {

using ozz::math::Float4x4;
using ozz::math::SimdFloat4;
using ozz::math::SimdInt4;
using ozz::math::SoaFloat3;
using ozz::math::SoaQuaternion;

const float* Floats(const void* regs, size_t index) {
  return reinterpret_cast<const float*>(regs) + index * 4;
}

float* OutFloats(void* regs, size_t index) {
  return reinterpret_cast<float*>(regs) + index * 4;
}

SimdFloat4 In(const void* regs, size_t index) {
  return ozz::math::simd_float4::LoadPtr(Floats(regs, index));
}

SimdInt4 InInt(const void* regs, size_t index) {
  return ozz::math::simd_int4::LoadPtr(
      reinterpret_cast<const int*>(Floats(regs, index)));
}

float Scalar(const void* regs, size_t index) { return Floats(regs, index)[0]; }

void Out(void* regs, size_t index, const SimdFloat4& value) {
  ozz::math::StorePtr(value, OutFloats(regs, index));
}

void OutInt(void* regs, size_t index, const SimdInt4& value) {
  ozz::math::StorePtr(value, reinterpret_cast<int*>(OutFloats(regs, index)));
}

void OutBool(void* regs, size_t index, bool value) {
  OutInt(regs, index, value ? ozz::math::simd_int4::all_true()
                            : ozz::math::simd_int4::all_false());
}

Float4x4 InMatrix(const void* regs, size_t index) {
  const Float4x4 m = {{In(regs, index + 0), In(regs, index + 1),
                       In(regs, index + 2), In(regs, index + 3)}};
  return m;
}

void OutMatrix(void* regs, size_t index, const Float4x4& m) {
  for (size_t i = 0; i < 4; ++i) Out(regs, index + i, m.cols[i]);
}

SoaFloat3 InSoaFloat3(const void* regs, size_t index) {
  const SoaFloat3 v = {In(regs, index + 0), In(regs, index + 1),
                       In(regs, index + 2)};
  return v;
}

void OutSoaFloat3(void* regs, size_t index, const SoaFloat3& v) {
  Out(regs, index + 0, v.x);
  Out(regs, index + 1, v.y);
  Out(regs, index + 2, v.z);
}

SoaQuaternion InSoaQuaternion(const void* regs, size_t index) {
  const SoaQuaternion q = {In(regs, index + 0), In(regs, index + 1),
                           In(regs, index + 2), In(regs, index + 3)};
  return q;
}

void OutSoaQuaternion(void* regs, size_t index, const SoaQuaternion& q) {
  Out(regs, index + 0, q.x);
  Out(regs, index + 1, q.y);
  Out(regs, index + 2, q.z);
  Out(regs, index + 3, q.w);
}

// ozz defines NLerp, SLerp, FromEuler and ToEuler on the scalar Quaternion
// only, and that is what src/math.zig ports for those four; a Quaternion is
// four floats in x, y, z, w order, so one register carries it unchanged.
ozz::math::Quaternion InQuaternion(const void* regs, size_t index) {
  ozz::math::Quaternion q;
  std::memcpy(&q, Floats(regs, index), sizeof(q));
  return q;
}

void OutQuaternion(void* regs, size_t index, const ozz::math::Quaternion& q) {
  std::memcpy(OutFloats(regs, index), &q, sizeof(q));
}

ozz::math::Float3 InFloat3(const void* regs, size_t index) {
  ozz::math::Float3 v;
  std::memcpy(&v, Floats(regs, index), sizeof(v));
  return v;
}

void OutFloat3(void* regs, size_t index, const ozz::math::Float3& v) {
  float* f = OutFloats(regs, index);
  f[0] = v.x;
  f[1] = v.y;
  f[2] = v.z;
  f[3] = 0.f;
}

// A Transform is ten scalar floats -- Float3, Quaternion, Float3 -- carried in
// three registers with the last two lanes unused.
ozz::math::Transform InTransform(const void* regs, size_t index) {
  ozz::math::Transform t;
  std::memcpy(&t, Floats(regs, index), sizeof(t));
  return t;
}

void OutTransform(void* regs, size_t index, const ozz::math::Transform& t) {
  std::memset(OutFloats(regs, index), 0, 3 * 4 * sizeof(float));
  std::memcpy(OutFloats(regs, index), &t, sizeof(t));
}

/// A Float3 whose three scalars ride in lane 0 of three registers, which is
/// how a function taking plain floats rather than a vector is marshalled.
ozz::math::Float3 InFloat3Lanes(const void* regs, size_t index) {
  return ozz::math::Float3(Scalar(regs, index + 0), Scalar(regs, index + 1),
                           Scalar(regs, index + 2));
}

void OutFloat3Lanes(void* regs, size_t index, const ozz::math::Float3& v) {
  Out(regs, index + 0, ozz::math::simd_float4::Load1(v.x));
  Out(regs, index + 1, ozz::math::simd_float4::Load1(v.y));
  Out(regs, index + 2, ozz::math::simd_float4::Load1(v.z));
}

const int* Ints(const void* regs, size_t index) {
  return reinterpret_cast<const int*>(Floats(regs, index));
}

bool InBool(const void* regs, size_t index) {
  return Floats(regs, index)[0] != 0.f;
}

/// A plain int result -- MoveMask's -- in lane 0, the rest zeroed so the
/// comparison has known bytes rather than whatever was there.
void OutScalarInt(void* regs, size_t index, int value) {
  int* i = reinterpret_cast<int*>(OutFloats(regs, index));
  i[0] = value;
  i[1] = 0;
  i[2] = 0;
  i[3] = 0;
}

/// Copies the caller's initial output register, so a partial store writes over
/// known bytes and the lanes it must leave alone are visible in the result.
void SeedOut(void* out, const void* in, size_t index) {
  std::memcpy(OutFloats(out, 0), Floats(in, index), 4 * sizeof(float));
}

struct Arity {
  unsigned char in_regs;
  unsigned char out_regs;
};

#define ZOZZ_MATHREF_ARITY(name, in_regs, out_regs) {in_regs, out_regs},
const Arity kArity[] = {ZOZZ_MATHREF_OPS(ZOZZ_MATHREF_ARITY)};
#undef ZOZZ_MATHREF_ARITY

#define ZOZZ_MATHREF_NAME(name, in_regs, out_regs) #name,
const char* const kNames[] = {ZOZZ_MATHREF_OPS(ZOZZ_MATHREF_NAME)};
#undef ZOZZ_MATHREF_NAME

}  // namespace

extern "C" {

int zozzMathRefArity(int op, size_t* in_regs, size_t* out_regs) {
  if (op < 0 || op >= ZOZZ_MATHREF_OP_COUNT) return -1;
  if (in_regs != NULL) *in_regs = kArity[op].in_regs;
  if (out_regs != NULL) *out_regs = kArity[op].out_regs;
  return 0;
}

const char* zozzMathRefName(int op) {
  if (op < 0 || op >= ZOZZ_MATHREF_OP_COUNT) return NULL;
  return kNames[op];
}

int zozzMathRefEval(int op, const void* in, size_t in_regs, void* out,
                    size_t out_regs) {
  if (op < 0 || op >= ZOZZ_MATHREF_OP_COUNT) return -1;
  if (in_regs != kArity[op].in_regs || out_regs != kArity[op].out_regs) {
    return -2;
  }

  namespace sf = ozz::math::simd_float4;
  namespace si = ozz::math::simd_int4;
  using namespace ozz::math;  // NOLINT -- the operations under test are here.

  switch (op) {
    // simd_float4 -- arithmetic
    case ZOZZ_MATHREF_MADD:
      Out(out, 0, MAdd(In(in, 0), In(in, 1), In(in, 2)));
      return 0;
    case ZOZZ_MATHREF_MSUB:
      Out(out, 0, MSub(In(in, 0), In(in, 1), In(in, 2)));
      return 0;
    case ZOZZ_MATHREF_NMADD:
      Out(out, 0, NMAdd(In(in, 0), In(in, 1), In(in, 2)));
      return 0;
    case ZOZZ_MATHREF_NMSUB:
      Out(out, 0, NMSub(In(in, 0), In(in, 1), In(in, 2)));
      return 0;
    case ZOZZ_MATHREF_DIVX:
      Out(out, 0, DivX(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_HADD2:
      Out(out, 0, HAdd2(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_HADD3:
      Out(out, 0, HAdd3(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_HADD4:
      Out(out, 0, HAdd4(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SQRT:
      Out(out, 0, Sqrt(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SQRTX:
      Out(out, 0, SqrtX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ABS:
      Out(out, 0, Abs(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_MIN0:
      Out(out, 0, Min0(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_MAX0:
      Out(out, 0, Max0(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_FROMINT:
      Out(out, 0, sf::FromInt(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SELECT:
      Out(out, 0, Select(InInt(in, 0), In(in, 1), In(in, 2)));
      return 0;

    // simd_float4 -- geometry
    case ZOZZ_MATHREF_DOT2:
      Out(out, 0, Dot2(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_DOT3:
      Out(out, 0, Dot3(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_DOT4:
      Out(out, 0, Dot4(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_CROSS3:
      Out(out, 0, Cross3(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_LENGTH2:
      Out(out, 0, Length2(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LENGTH3:
      Out(out, 0, Length3(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LENGTH4:
      Out(out, 0, Length4(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LENGTH2SQR:
      Out(out, 0, Length2Sqr(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LENGTH3SQR:
      Out(out, 0, Length3Sqr(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LENGTH4SQR:
      Out(out, 0, Length4Sqr(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZE2:
      Out(out, 0, Normalize2(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZE3:
      Out(out, 0, Normalize3(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZE4:
      Out(out, 0, Normalize4(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZESAFE2:
      Out(out, 0, NormalizeSafe2(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZESAFE3:
      Out(out, 0, NormalizeSafe3(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZESAFE4:
      Out(out, 0, NormalizeSafe4(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_ISNORMALIZED2:
      OutInt(out, 0, IsNormalized2(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ISNORMALIZED3:
      OutInt(out, 0, IsNormalized3(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ISNORMALIZED4:
      OutInt(out, 0, IsNormalized4(In(in, 0)));
      return 0;

    // simd_float4 -- estimates
    case ZOZZ_MATHREF_RCPEST:
      Out(out, 0, RcpEst(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_RCPESTNR:
      Out(out, 0, RcpEstNR(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_RCPESTX:
      Out(out, 0, RcpEstX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_RCPESTXNR:
      Out(out, 0, RcpEstXNR(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_RSQRTEST:
      Out(out, 0, RSqrtEst(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_RSQRTESTNR:
      Out(out, 0, RSqrtEstNR(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_RSQRTESTX:
      Out(out, 0, RSqrtEstX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_RSQRTESTXNR:
      Out(out, 0, RSqrtEstXNR(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZEEST2:
      Out(out, 0, NormalizeEst2(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZEEST3:
      Out(out, 0, NormalizeEst3(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZEEST4:
      Out(out, 0, NormalizeEst4(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZESAFEEST2:
      Out(out, 0, NormalizeSafeEst2(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZESAFEEST3:
      Out(out, 0, NormalizeSafeEst3(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_NORMALIZESAFEEST4:
      Out(out, 0, NormalizeSafeEst4(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_ISNORMALIZEDEST2:
      OutInt(out, 0, IsNormalizedEst2(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ISNORMALIZEDEST3:
      OutInt(out, 0, IsNormalizedEst3(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ISNORMALIZEDEST4:
      OutInt(out, 0, IsNormalizedEst4(In(in, 0)));
      return 0;

    // simd_float4 -- trigonometry
    case ZOZZ_MATHREF_COS:
      Out(out, 0, Cos(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_COSX:
      Out(out, 0, CosX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SIN:
      Out(out, 0, Sin(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SINX:
      Out(out, 0, SinX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_TAN:
      Out(out, 0, Tan(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_TANX:
      Out(out, 0, TanX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ACOS:
      Out(out, 0, ACos(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ACOSX:
      Out(out, 0, ACosX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ASIN:
      Out(out, 0, ASin(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ASINX:
      Out(out, 0, ASinX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ATAN:
      Out(out, 0, ATan(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_ATANX:
      Out(out, 0, ATanX(In(in, 0)));
      return 0;

    // simd_float4 -- lanes and memory
    case ZOZZ_MATHREF_LOADX:
      Out(out, 0, sf::LoadX(Scalar(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LOAD1:
      Out(out, 0, sf::Load1(Scalar(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LOADPTR:
      Out(out, 0, sf::LoadPtr(Floats(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LOADPTRU:
      Out(out, 0, sf::LoadPtrU(Floats(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LOADXPTRU:
      Out(out, 0, sf::LoadXPtrU(Floats(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LOAD1PTRU:
      Out(out, 0, sf::Load1PtrU(Floats(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LOAD2PTRU:
      Out(out, 0, sf::Load2PtrU(Floats(in, 0)));
      return 0;
    case ZOZZ_MATHREF_LOAD3PTRU:
      Out(out, 0, sf::Load3PtrU(Floats(in, 0)));
      return 0;
    case ZOZZ_MATHREF_GETX:
      Out(out, 0, sf::Load1(GetX(In(in, 0))));
      return 0;
    case ZOZZ_MATHREF_GETY:
      Out(out, 0, sf::Load1(GetY(In(in, 0))));
      return 0;
    case ZOZZ_MATHREF_GETZ:
      Out(out, 0, sf::Load1(GetZ(In(in, 0))));
      return 0;
    case ZOZZ_MATHREF_GETW:
      Out(out, 0, sf::Load1(GetW(In(in, 0))));
      return 0;
    case ZOZZ_MATHREF_SETX:
      Out(out, 0, SetX(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_SETY:
      Out(out, 0, SetY(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_SETZ:
      Out(out, 0, SetZ(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_SETW:
      Out(out, 0, SetW(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_SETI:
      Out(out, 0,
          SetI(In(in, 0), In(in, 1), static_cast<int>(Scalar(in, 2))));
      return 0;
    case ZOZZ_MATHREF_SPLATX:
      Out(out, 0, SplatX(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SPLATY:
      Out(out, 0, SplatY(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SPLATZ:
      Out(out, 0, SplatZ(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SPLATW:
      Out(out, 0, SplatW(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SWIZZLEWZYX:
      Out(out, 0, Swizzle<3, 2, 1, 0>(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_STOREPTR:
      SeedOut(out, in, 1);
      StorePtr(In(in, 0), OutFloats(out, 0));
      return 0;
    case ZOZZ_MATHREF_STORE1PTR:
      SeedOut(out, in, 1);
      Store1Ptr(In(in, 0), OutFloats(out, 0));
      return 0;
    case ZOZZ_MATHREF_STORE2PTR:
      SeedOut(out, in, 1);
      Store2Ptr(In(in, 0), OutFloats(out, 0));
      return 0;
    case ZOZZ_MATHREF_STORE3PTR:
      SeedOut(out, in, 1);
      Store3Ptr(In(in, 0), OutFloats(out, 0));
      return 0;
    case ZOZZ_MATHREF_STOREPTRU:
      SeedOut(out, in, 1);
      StorePtrU(In(in, 0), OutFloats(out, 0));
      return 0;
    case ZOZZ_MATHREF_STORE1PTRU:
      SeedOut(out, in, 1);
      Store1PtrU(In(in, 0), OutFloats(out, 0));
      return 0;
    case ZOZZ_MATHREF_STORE2PTRU:
      SeedOut(out, in, 1);
      Store2PtrU(In(in, 0), OutFloats(out, 0));
      return 0;
    case ZOZZ_MATHREF_STORE3PTRU:
      SeedOut(out, in, 1);
      Store3PtrU(In(in, 0), OutFloats(out, 0));
      return 0;

    // simd_float4 -- transposes
    case ZOZZ_MATHREF_TRANSPOSE4X1: {
      const SimdFloat4 v[4] = {In(in, 0), In(in, 1), In(in, 2), In(in, 3)};
      SimdFloat4 r[1];
      Transpose4x1(v, r);
      Out(out, 0, r[0]);
      return 0;
    }
    case ZOZZ_MATHREF_TRANSPOSE1X4: {
      const SimdFloat4 v[1] = {In(in, 0)};
      SimdFloat4 r[4];
      Transpose1x4(v, r);
      for (size_t i = 0; i < 4; ++i) Out(out, i, r[i]);
      return 0;
    }
    case ZOZZ_MATHREF_TRANSPOSE4X2: {
      const SimdFloat4 v[4] = {In(in, 0), In(in, 1), In(in, 2), In(in, 3)};
      SimdFloat4 r[2];
      Transpose4x2(v, r);
      for (size_t i = 0; i < 2; ++i) Out(out, i, r[i]);
      return 0;
    }
    case ZOZZ_MATHREF_TRANSPOSE2X4: {
      const SimdFloat4 v[2] = {In(in, 0), In(in, 1)};
      SimdFloat4 r[4];
      Transpose2x4(v, r);
      for (size_t i = 0; i < 4; ++i) Out(out, i, r[i]);
      return 0;
    }
    case ZOZZ_MATHREF_TRANSPOSE4X3: {
      const SimdFloat4 v[4] = {In(in, 0), In(in, 1), In(in, 2), In(in, 3)};
      SimdFloat4 r[3];
      Transpose4x3(v, r);
      for (size_t i = 0; i < 3; ++i) Out(out, i, r[i]);
      return 0;
    }
    case ZOZZ_MATHREF_TRANSPOSE3X4: {
      const SimdFloat4 v[3] = {In(in, 0), In(in, 1), In(in, 2)};
      SimdFloat4 r[4];
      Transpose3x4(v, r);
      for (size_t i = 0; i < 4; ++i) Out(out, i, r[i]);
      return 0;
    }
    case ZOZZ_MATHREF_TRANSPOSE4X4: {
      const SimdFloat4 v[4] = {In(in, 0), In(in, 1), In(in, 2), In(in, 3)};
      SimdFloat4 r[4];
      Transpose4x4(v, r);
      for (size_t i = 0; i < 4; ++i) Out(out, i, r[i]);
      return 0;
    }
    case ZOZZ_MATHREF_TRANSPOSE16X16: {
      SimdFloat4 v[16];
      SimdFloat4 r[16];
      for (size_t i = 0; i < 16; ++i) v[i] = In(in, i);
      Transpose16x16(v, r);
      for (size_t i = 0; i < 16; ++i) Out(out, i, r[i]);
      return 0;
    }

    // quaternion
    case ZOZZ_MATHREF_QUATCONJUGATE:
      Out(out, 0, Conjugate(SimdQuaternion{In(in, 0)}).xyzw);
      return 0;
    case ZOZZ_MATHREF_QUATMUL:
      Out(out, 0, (SimdQuaternion{In(in, 0)} * SimdQuaternion{In(in, 1)}).xyzw);
      return 0;
    case ZOZZ_MATHREF_QUATTRANSFORMVECTOR:
      Out(out, 0, TransformVector(SimdQuaternion{In(in, 0)}, In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_QUATNLERP:
      OutQuaternion(
          out, 0, NLerp(InQuaternion(in, 0), InQuaternion(in, 1), Scalar(in, 2)));
      return 0;
    case ZOZZ_MATHREF_QUATSLERP:
      OutQuaternion(
          out, 0, SLerp(InQuaternion(in, 0), InQuaternion(in, 1), Scalar(in, 2)));
      return 0;
    case ZOZZ_MATHREF_QUATFROMAXISANGLE:
      Out(out, 0, SimdQuaternion::FromAxisAngle(In(in, 0), In(in, 1)).xyzw);
      return 0;
    case ZOZZ_MATHREF_QUATFROMAXISCOSANGLE:
      Out(out, 0, SimdQuaternion::FromAxisCosAngle(In(in, 0), In(in, 1)).xyzw);
      return 0;
    case ZOZZ_MATHREF_QUATTOAXISANGLE:
      Out(out, 0, ToAxisAngle(SimdQuaternion{In(in, 0)}));
      return 0;
    case ZOZZ_MATHREF_QUATFROMVECTORS:
      Out(out, 0, SimdQuaternion::FromVectors(In(in, 0), In(in, 1)).xyzw);
      return 0;
    case ZOZZ_MATHREF_QUATFROMUNITVECTORS:
      Out(out, 0, SimdQuaternion::FromUnitVectors(In(in, 0), In(in, 1)).xyzw);
      return 0;
    case ZOZZ_MATHREF_QUATFROMEULER:
      OutQuaternion(out, 0, Quaternion::FromEuler(InFloat3(in, 0)));
      return 0;
    case ZOZZ_MATHREF_QUATTOEULER:
      OutFloat3(out, 0, ToEuler(InQuaternion(in, 0)));
      return 0;

    // Float4x4
    case ZOZZ_MATHREF_MAT4TRANSPOSE:
      OutMatrix(out, 0, Transpose(InMatrix(in, 0)));
      return 0;
    case ZOZZ_MATHREF_MAT4INVERT: {
      SimdInt4 invertible;
      OutMatrix(out, 0, Invert(InMatrix(in, 0), &invertible));
      OutInt(out, 4, invertible);
      return 0;
    }
    case ZOZZ_MATHREF_MAT4COLUMNMULTIPLY:
      OutMatrix(out, 0, ColumnMultiply(InMatrix(in, 0), In(in, 4)));
      return 0;
    case ZOZZ_MATHREF_MAT4SCALING:
      OutMatrix(out, 0, Float4x4::Scaling(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_MAT4TRANSLATE:
      OutMatrix(out, 0, Translate(InMatrix(in, 0), In(in, 4)));
      return 0;
    case ZOZZ_MATHREF_MAT4ISORTHOGONAL:
      OutInt(out, 0, IsOrthogonal(InMatrix(in, 0)));
      return 0;
    case ZOZZ_MATHREF_MAT4TRANSFORMPOINT:
      Out(out, 0, TransformPoint(InMatrix(in, 0), In(in, 4)));
      return 0;
    case ZOZZ_MATHREF_MAT4TRANSFORMVECTOR:
      Out(out, 0, TransformVector(InMatrix(in, 0), In(in, 4)));
      return 0;
    case ZOZZ_MATHREF_MAT4FROMAFFINE:
      OutMatrix(out, 0,
                Float4x4::FromAffine(In(in, 0), In(in, 1), In(in, 2)));
      return 0;
    case ZOZZ_MATHREF_MAT4TOAFFINE: {
      SimdFloat4 translation, rotation, scale;
      const bool ok =
          ToAffine(InMatrix(in, 0), &translation, &rotation, &scale);
      Out(out, 0, translation);
      Out(out, 1, rotation);
      Out(out, 2, scale);
      OutBool(out, 3, ok);
      return 0;
    }
    case ZOZZ_MATHREF_MAT4FROMQUATERNION:
      OutMatrix(out, 0, Float4x4::FromQuaternion(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_MAT4TOQUATERNION:
      Out(out, 0, ToQuaternion(InMatrix(in, 0)));
      return 0;
    case ZOZZ_MATHREF_MAT4MULVEC:
      Out(out, 0, InMatrix(in, 0) * In(in, 4));
      return 0;
    case ZOZZ_MATHREF_MAT4MUL:
      OutMatrix(out, 0, InMatrix(in, 0) * InMatrix(in, 4));
      return 0;
    case ZOZZ_MATHREF_MAT4ADD:
      OutMatrix(out, 0, InMatrix(in, 0) + InMatrix(in, 4));
      return 0;
    case ZOZZ_MATHREF_MAT4SUB:
      OutMatrix(out, 0, InMatrix(in, 0) - InMatrix(in, 4));
      return 0;

    // Transform
    case ZOZZ_MATHREF_TRANSFORMMUL:
      OutTransform(out, 0, InTransform(in, 0) * InTransform(in, 3));
      return 0;

    // SoaFloat3
    case ZOZZ_MATHREF_SOAFLOAT3ADD:
      OutSoaFloat3(out, 0, InSoaFloat3(in, 0) + InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3SUB:
      OutSoaFloat3(out, 0, InSoaFloat3(in, 0) - InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3NEG:
      OutSoaFloat3(out, 0, -InSoaFloat3(in, 0));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3MUL:
      OutSoaFloat3(out, 0, InSoaFloat3(in, 0) * InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3MULSCALAR:
      OutSoaFloat3(out, 0, InSoaFloat3(in, 0) * In(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3DIV:
      OutSoaFloat3(out, 0, InSoaFloat3(in, 0) / InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3DIVSCALAR:
      OutSoaFloat3(out, 0, InSoaFloat3(in, 0) / In(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3LT:
      OutInt(out, 0, InSoaFloat3(in, 0) < InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3LE:
      OutInt(out, 0, InSoaFloat3(in, 0) <= InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3GT:
      OutInt(out, 0, InSoaFloat3(in, 0) > InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3GE:
      OutInt(out, 0, InSoaFloat3(in, 0) >= InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3EQ:
      OutInt(out, 0, InSoaFloat3(in, 0) == InSoaFloat3(in, 3));
      return 0;
    case ZOZZ_MATHREF_SOAFLOAT3NE:
      OutInt(out, 0, InSoaFloat3(in, 0) != InSoaFloat3(in, 3));
      return 0;

    // SoaQuaternion
    case ZOZZ_MATHREF_SOAQUATNEG:
      OutSoaQuaternion(out, 0, -InSoaQuaternion(in, 0));
      return 0;
    case ZOZZ_MATHREF_SOAQUATCONJUGATE:
      OutSoaQuaternion(out, 0, Conjugate(InSoaQuaternion(in, 0)));
      return 0;
    case ZOZZ_MATHREF_SOAQUATADD:
      OutSoaQuaternion(out, 0,
                       InSoaQuaternion(in, 0) + InSoaQuaternion(in, 4));
      return 0;
    case ZOZZ_MATHREF_SOAQUATMUL:
      OutSoaQuaternion(out, 0,
                       InSoaQuaternion(in, 0) * InSoaQuaternion(in, 4));
      return 0;
    case ZOZZ_MATHREF_SOAQUATMULSCALAR:
      OutSoaQuaternion(out, 0, InSoaQuaternion(in, 0) * In(in, 4));
      return 0;
    case ZOZZ_MATHREF_SOAQUATDOT:
      Out(out, 0, Dot(InSoaQuaternion(in, 0), InSoaQuaternion(in, 4)));
      return 0;
    case ZOZZ_MATHREF_SOAQUATEQ:
      OutInt(out, 0, InSoaQuaternion(in, 0) == InSoaQuaternion(in, 4));
      return 0;

    // simd_int4 -- constants
    case ZOZZ_MATHREF_INTALLTRUE:
      OutInt(out, 0, si::all_true());
      return 0;
    case ZOZZ_MATHREF_INTALLFALSE:
      OutInt(out, 0, si::all_false());
      return 0;
    case ZOZZ_MATHREF_INTMASKSIGN:
      OutInt(out, 0, si::mask_sign());
      return 0;
    case ZOZZ_MATHREF_INTMASKSIGNXYZ:
      OutInt(out, 0, si::mask_sign_xyz());
      return 0;
    case ZOZZ_MATHREF_INTMASKSIGNW:
      OutInt(out, 0, si::mask_sign_w());
      return 0;
    case ZOZZ_MATHREF_INTMASKNOTSIGN:
      OutInt(out, 0, si::mask_not_sign());
      return 0;
    case ZOZZ_MATHREF_INTMASKFFFF:
      OutInt(out, 0, si::mask_ffff());
      return 0;
    case ZOZZ_MATHREF_INTMASK0000:
      OutInt(out, 0, si::mask_0000());
      return 0;
    case ZOZZ_MATHREF_INTMASKFFF0:
      OutInt(out, 0, si::mask_fff0());
      return 0;
    case ZOZZ_MATHREF_INTMASKF000:
      OutInt(out, 0, si::mask_f000());
      return 0;
    case ZOZZ_MATHREF_INTMASK0F00:
      OutInt(out, 0, si::mask_0f00());
      return 0;
    case ZOZZ_MATHREF_INTMASK00F0:
      OutInt(out, 0, si::mask_00f0());
      return 0;
    case ZOZZ_MATHREF_INTMASK000F:
      OutInt(out, 0, si::mask_000f());
      return 0;

    // simd_int4 -- loads and conversions
    case ZOZZ_MATHREF_INTLOADX:
      OutInt(out, 0, si::LoadX(InBool(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOAD1:
      OutInt(out, 0, si::Load1(InBool(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOADPTR:
      OutInt(out, 0, si::LoadPtr(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOADPTRU:
      OutInt(out, 0, si::LoadPtrU(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOADXPTR:
      OutInt(out, 0, si::LoadXPtr(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOADXPTRU:
      OutInt(out, 0, si::LoadXPtrU(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOAD1PTR:
      OutInt(out, 0, si::Load1Ptr(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOAD1PTRU:
      OutInt(out, 0, si::Load1PtrU(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOAD2PTR:
      OutInt(out, 0, si::Load2Ptr(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOAD2PTRU:
      OutInt(out, 0, si::Load2PtrU(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOAD3PTR:
      OutInt(out, 0, si::Load3Ptr(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTLOAD3PTRU:
      OutInt(out, 0, si::Load3PtrU(Ints(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTFROMFLOATROUND:
      OutInt(out, 0, si::FromFloatRound(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTFROMFLOATTRUNC:
      OutInt(out, 0, si::FromFloatTrunc(In(in, 0)));
      return 0;

    // simd_int4 -- bitwise, comparisons and reductions
    case ZOZZ_MATHREF_INTAND:
      OutInt(out, 0, And(InInt(in, 0), InInt(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTXOR:
      OutInt(out, 0, Xor(InInt(in, 0), InInt(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTNOT:
      OutInt(out, 0, Not(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTANDNOT:
      OutInt(out, 0, AndNot(InInt(in, 0), InInt(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTCMPLT:
      OutInt(out, 0, CmpLt(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTCMPLE:
      OutInt(out, 0, CmpLe(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTCMPGT:
      OutInt(out, 0, CmpGt(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTCMPGE:
      OutInt(out, 0, CmpGe(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTCMPEQ:
      OutInt(out, 0, CmpEq(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTCMPNE:
      OutInt(out, 0, CmpNe(In(in, 0), In(in, 1)));
      return 0;
    case ZOZZ_MATHREF_INTSIGN:
      OutInt(out, 0, Sign(In(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTSWIZZLEZWXY:
      OutInt(out, 0, Swizzle<2, 3, 0, 1>(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTSHIFTL:
      OutInt(out, 0, ShiftL(InInt(in, 0), static_cast<int>(Scalar(in, 1))));
      return 0;
    case ZOZZ_MATHREF_INTSHIFTR:
      OutInt(out, 0, ShiftR(InInt(in, 0), static_cast<int>(Scalar(in, 1))));
      return 0;
    case ZOZZ_MATHREF_INTSHIFTRU:
      OutInt(out, 0, ShiftRu(InInt(in, 0), static_cast<int>(Scalar(in, 1))));
      return 0;
    case ZOZZ_MATHREF_INTAREALLTRUE:
      OutBool(out, 0, AreAllTrue(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTAREALLTRUE3:
      OutBool(out, 0, AreAllTrue3(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTAREALLTRUE2:
      OutBool(out, 0, AreAllTrue2(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTAREALLTRUE1:
      OutBool(out, 0, AreAllTrue1(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTAREALLFALSE:
      OutBool(out, 0, AreAllFalse(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTAREALLFALSE3:
      OutBool(out, 0, AreAllFalse3(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTAREALLFALSE2:
      OutBool(out, 0, AreAllFalse2(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTAREALLFALSE1:
      OutBool(out, 0, AreAllFalse1(InInt(in, 0)));
      return 0;
    case ZOZZ_MATHREF_INTMOVEMASK:
      OutScalarInt(out, 0, MoveMask(InInt(in, 0)));
      return 0;

    // simd_float4 -- constants
    case ZOZZ_MATHREF_ZERO:
      Out(out, 0, sf::zero());
      return 0;
    case ZOZZ_MATHREF_ONE:
      Out(out, 0, sf::one());
      return 0;
    case ZOZZ_MATHREF_XAXIS:
      Out(out, 0, sf::x_axis());
      return 0;
    case ZOZZ_MATHREF_YAXIS:
      Out(out, 0, sf::y_axis());
      return 0;
    case ZOZZ_MATHREF_ZAXIS:
      Out(out, 0, sf::z_axis());
      return 0;
    case ZOZZ_MATHREF_WAXIS:
      Out(out, 0, sf::w_axis());
      return 0;

    // offline interpolation
    case ZOZZ_MATHREF_LERPTRANSLATION:
      OutFloat3Lanes(out, 0,
                     ozz::animation::offline::LerpTranslation(
                         InFloat3Lanes(in, 0), InFloat3Lanes(in, 3),
                         Scalar(in, 6)));
      return 0;
    case ZOZZ_MATHREF_LERPSCALE:
      OutFloat3Lanes(out, 0, ozz::animation::offline::LerpScale(
                                 InFloat3Lanes(in, 0), InFloat3Lanes(in, 3),
                                 Scalar(in, 6)));
      return 0;
    case ZOZZ_MATHREF_LERPROTATION:
      OutQuaternion(out, 0, ozz::animation::offline::LerpRotation(
                                InQuaternion(in, 0), InQuaternion(in, 1),
                                Scalar(in, 2)));
      return 0;

    default:
      return -1;
  }
}

}  // extern "C"
