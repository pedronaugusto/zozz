//===----------------------------------------------------------------------===//
// zozz — ozz's own maths, reachable from a test.
//
// src/math.zig is a hand port of ozz::math. Every test it had compared the
// port against itself, which cannot detect a port that is wrong in the same
// way twice. This shim is the other operand: one entry point that evaluates a
// named ozz operation on caller-supplied registers, so a test can run both
// implementations on the same inputs and compare the bits.
//
// Registers, not typed structs, because every operand ozz::math takes is
// sixteen bytes: a SimdFloat4, a SimdInt4, or a slice of a Float4x4, a
// SoaFloat3, a SoaQuaternion. One shape carries all of them, and the arity
// table below is what says how many go in and how many come out.
//
// Test-only. Not part of the zozz library or its ABI, and not installed.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_TEST_MATHREF_H_
#define ZOZZ_TEST_MATHREF_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The operation list, and the ONE place it is written. The enum, the name
// table and the arity table are all expanded from here, so an operation
// cannot exist in one and be missing from another. X(name, in_regs, out_regs).
//
// A register is sixteen bytes, aligned to sixteen. An operation taking a
// scalar takes it in lane 0 of a register of its own; one returning a bool or
// a SimdInt4 writes a register of int lanes.
#define ZOZZ_MATHREF_OPS(X)                 \
  /* simd_float4 -- arithmetic */           \
  X(MADD, 3, 1)                             \
  X(MSUB, 3, 1)                             \
  X(NMADD, 3, 1)                            \
  X(NMSUB, 3, 1)                            \
  X(DIVX, 2, 1)                             \
  X(HADD2, 1, 1)                            \
  X(HADD3, 1, 1)                            \
  X(HADD4, 1, 1)                            \
  X(SQRT, 1, 1)                             \
  X(SQRTX, 1, 1)                            \
  X(ABS, 1, 1)                              \
  X(MIN0, 1, 1)                             \
  X(MAX0, 1, 1)                             \
  X(FROMINT, 1, 1)                          \
  X(SELECT, 3, 1)                           \
  /* simd_float4 -- geometry */             \
  X(DOT2, 2, 1)                             \
  X(DOT3, 2, 1)                             \
  X(DOT4, 2, 1)                             \
  X(CROSS3, 2, 1)                           \
  X(LENGTH2, 1, 1)                          \
  X(LENGTH3, 1, 1)                          \
  X(LENGTH4, 1, 1)                          \
  X(LENGTH2SQR, 1, 1)                       \
  X(LENGTH3SQR, 1, 1)                       \
  X(LENGTH4SQR, 1, 1)                       \
  X(NORMALIZE2, 1, 1)                       \
  X(NORMALIZE3, 1, 1)                       \
  X(NORMALIZE4, 1, 1)                       \
  X(NORMALIZESAFE2, 2, 1)                   \
  X(NORMALIZESAFE3, 2, 1)                   \
  X(NORMALIZESAFE4, 2, 1)                   \
  X(ISNORMALIZED2, 1, 1)                    \
  X(ISNORMALIZED3, 1, 1)                    \
  X(ISNORMALIZED4, 1, 1)                    \
  /* simd_float4 -- estimates */            \
  X(RCPEST, 1, 1)                           \
  X(RCPESTNR, 1, 1)                         \
  X(RCPESTX, 1, 1)                          \
  X(RCPESTXNR, 1, 1)                        \
  X(RSQRTEST, 1, 1)                         \
  X(RSQRTESTNR, 1, 1)                       \
  X(RSQRTESTX, 1, 1)                        \
  X(RSQRTESTXNR, 1, 1)                      \
  X(NORMALIZEEST2, 1, 1)                    \
  X(NORMALIZEEST3, 1, 1)                    \
  X(NORMALIZEEST4, 1, 1)                    \
  X(NORMALIZESAFEEST2, 2, 1)                \
  X(NORMALIZESAFEEST3, 2, 1)                \
  X(NORMALIZESAFEEST4, 2, 1)                \
  X(ISNORMALIZEDEST2, 1, 1)                 \
  X(ISNORMALIZEDEST3, 1, 1)                 \
  X(ISNORMALIZEDEST4, 1, 1)                 \
  /* simd_float4 -- trigonometry */         \
  X(COS, 1, 1)                              \
  X(COSX, 1, 1)                             \
  X(SIN, 1, 1)                              \
  X(SINX, 1, 1)                             \
  X(TAN, 1, 1)                              \
  X(TANX, 1, 1)                             \
  X(ACOS, 1, 1)                             \
  X(ACOSX, 1, 1)                            \
  X(ASIN, 1, 1)                             \
  X(ASINX, 1, 1)                            \
  X(ATAN, 1, 1)                             \
  X(ATANX, 1, 1)                            \
  /* simd_float4 -- lanes and memory */     \
  X(LOADX, 1, 1)                            \
  X(LOAD1, 1, 1)                            \
  X(LOADPTR, 1, 1)                          \
  X(LOADPTRU, 1, 1)                         \
  X(LOADXPTRU, 1, 1)                        \
  X(LOAD1PTRU, 1, 1)                        \
  X(LOAD2PTRU, 1, 1)                        \
  X(LOAD3PTRU, 1, 1)                        \
  X(GETX, 1, 1)                             \
  X(GETY, 1, 1)                             \
  X(GETZ, 1, 1)                             \
  X(GETW, 1, 1)                             \
  X(SETX, 2, 1)                             \
  X(SETY, 2, 1)                             \
  X(SETZ, 2, 1)                             \
  X(SETW, 2, 1)                             \
  X(SETI, 3, 1)                             \
  X(SPLATX, 1, 1)                           \
  X(SPLATY, 1, 1)                           \
  X(SPLATZ, 1, 1)                           \
  X(SPLATW, 1, 1)                           \
  X(SWIZZLEWZYX, 1, 1)                      \
  X(STOREPTR, 2, 1)                         \
  X(STORE1PTR, 2, 1)                        \
  X(STORE2PTR, 2, 1)                        \
  X(STORE3PTR, 2, 1)                        \
  X(STOREPTRU, 2, 1)                        \
  X(STORE1PTRU, 2, 1)                       \
  X(STORE2PTRU, 2, 1)                       \
  X(STORE3PTRU, 2, 1)                       \
  /* simd_float4 -- transposes */           \
  X(TRANSPOSE4X1, 4, 1)                     \
  X(TRANSPOSE1X4, 1, 4)                     \
  X(TRANSPOSE4X2, 4, 2)                     \
  X(TRANSPOSE2X4, 2, 4)                     \
  X(TRANSPOSE4X3, 4, 3)                     \
  X(TRANSPOSE3X4, 3, 4)                     \
  X(TRANSPOSE4X4, 4, 4)                     \
  X(TRANSPOSE16X16, 16, 16)                 \
  /* quaternion */                          \
  X(QUATCONJUGATE, 1, 1)                    \
  X(QUATMUL, 2, 1)                          \
  X(QUATTRANSFORMVECTOR, 2, 1)              \
  X(QUATNLERP, 3, 1)                        \
  X(QUATSLERP, 3, 1)                        \
  X(QUATFROMAXISANGLE, 2, 1)                \
  X(QUATFROMAXISCOSANGLE, 2, 1)             \
  X(QUATTOAXISANGLE, 1, 1)                  \
  X(QUATFROMVECTORS, 2, 1)                  \
  X(QUATFROMUNITVECTORS, 2, 1)              \
  X(QUATFROMEULER, 1, 1)                    \
  X(QUATTOEULER, 1, 1)                      \
  /* Float4x4 */                            \
  X(MAT4TRANSPOSE, 4, 4)                    \
  X(MAT4INVERT, 4, 5)                       \
  X(MAT4COLUMNMULTIPLY, 5, 4)               \
  X(MAT4SCALING, 1, 4)                      \
  X(MAT4TRANSLATE, 5, 4)                    \
  X(MAT4ISORTHOGONAL, 4, 1)                 \
  X(MAT4TRANSFORMPOINT, 5, 1)               \
  X(MAT4TRANSFORMVECTOR, 5, 1)              \
  X(MAT4FROMAFFINE, 3, 4)                   \
  X(MAT4TOAFFINE, 4, 4)                     \
  X(MAT4FROMQUATERNION, 1, 4)               \
  X(MAT4TOQUATERNION, 4, 1)                 \
  X(MAT4MULVEC, 5, 1)                       \
  X(MAT4MUL, 8, 4)                          \
  X(MAT4ADD, 8, 4)                          \
  X(MAT4SUB, 8, 4)                          \
  /* Transform */                           \
  X(TRANSFORMMUL, 6, 3)                     \
  /* SoaFloat3 */                           \
  X(SOAFLOAT3ADD, 6, 3)                     \
  X(SOAFLOAT3SUB, 6, 3)                     \
  X(SOAFLOAT3NEG, 3, 3)                     \
  X(SOAFLOAT3MUL, 6, 3)                     \
  X(SOAFLOAT3MULSCALAR, 4, 3)               \
  X(SOAFLOAT3DIV, 6, 3)                     \
  X(SOAFLOAT3DIVSCALAR, 4, 3)               \
  X(SOAFLOAT3LT, 6, 1)                      \
  X(SOAFLOAT3LE, 6, 1)                      \
  X(SOAFLOAT3GT, 6, 1)                      \
  X(SOAFLOAT3GE, 6, 1)                      \
  X(SOAFLOAT3EQ, 6, 1)                      \
  X(SOAFLOAT3NE, 6, 1)                      \
  /* SoaQuaternion */                       \
  X(SOAQUATNEG, 4, 4)                       \
  X(SOAQUATCONJUGATE, 4, 4)                 \
  X(SOAQUATADD, 8, 4)                       \
  X(SOAQUATMUL, 8, 4)                       \
  X(SOAQUATMULSCALAR, 5, 4)                 \
  X(SOAQUATDOT, 8, 1)                       \
  X(SOAQUATEQ, 8, 1)                        \
  /* simd_int4 */                           \
  X(INTALLTRUE, 0, 1)                       \
  X(INTALLFALSE, 0, 1)                      \
  X(INTMASKSIGN, 0, 1)                      \
  X(INTMASKSIGNXYZ, 0, 1)                   \
  X(INTMASKSIGNW, 0, 1)                     \
  X(INTMASKNOTSIGN, 0, 1)                   \
  X(INTMASKFFFF, 0, 1)                      \
  X(INTMASK0000, 0, 1)                      \
  X(INTMASKFFF0, 0, 1)                      \
  X(INTMASKF000, 0, 1)                      \
  X(INTMASK0F00, 0, 1)                      \
  X(INTMASK00F0, 0, 1)                      \
  X(INTMASK000F, 0, 1)                      \
  X(INTLOADX, 1, 1)                         \
  X(INTLOAD1, 1, 1)                         \
  X(INTLOADPTR, 1, 1)                       \
  X(INTLOADPTRU, 1, 1)                      \
  X(INTLOADXPTR, 1, 1)                      \
  X(INTLOADXPTRU, 1, 1)                     \
  X(INTLOAD1PTR, 1, 1)                      \
  X(INTLOAD1PTRU, 1, 1)                     \
  X(INTLOAD2PTR, 1, 1)                      \
  X(INTLOAD2PTRU, 1, 1)                     \
  X(INTLOAD3PTR, 1, 1)                      \
  X(INTLOAD3PTRU, 1, 1)                     \
  X(INTFROMFLOATROUND, 1, 1)                \
  X(INTFROMFLOATTRUNC, 1, 1)                \
  X(INTAND, 2, 1)                           \
  X(INTXOR, 2, 1)                           \
  X(INTNOT, 1, 1)                           \
  X(INTANDNOT, 2, 1)                        \
  X(INTCMPLT, 2, 1)                         \
  X(INTCMPLE, 2, 1)                         \
  X(INTCMPGT, 2, 1)                         \
  X(INTCMPGE, 2, 1)                         \
  X(INTCMPEQ, 2, 1)                         \
  X(INTCMPNE, 2, 1)                         \
  X(INTSIGN, 1, 1)                          \
  X(INTAREALLTRUE, 1, 1)                    \
  X(INTAREALLTRUE3, 1, 1)                   \
  X(INTAREALLTRUE2, 1, 1)                   \
  X(INTAREALLTRUE1, 1, 1)                   \
  X(INTAREALLFALSE, 1, 1)                   \
  X(INTAREALLFALSE3, 1, 1)                  \
  X(INTAREALLFALSE2, 1, 1)                  \
  X(INTAREALLFALSE1, 1, 1)                  \
  X(INTMOVEMASK, 1, 1)                      \
  X(INTSWIZZLEZWXY, 1, 1)                   \
  X(INTSHIFTL, 2, 1)                        \
  X(INTSHIFTR, 2, 1)                        \
  X(INTSHIFTRU, 2, 1)                       \
  /* simd_float4 -- constants */            \
  X(ZERO, 0, 1)                             \
  X(ONE, 0, 1)                              \
  X(XAXIS, 0, 1)                            \
  X(YAXIS, 0, 1)                            \
  X(ZAXIS, 0, 1)                            \
  X(WAXIS, 0, 1)                            \
  /* offline interpolation */               \
  X(LERPTRANSLATION, 7, 3)                  \
  X(LERPSCALE, 7, 3)                        \
  X(LERPROTATION, 3, 1)

#define ZOZZ_MATHREF_ENUMERATOR(name, in_regs, out_regs) ZOZZ_MATHREF_##name,

typedef enum ZozzMathRefOp {
  ZOZZ_MATHREF_OPS(ZOZZ_MATHREF_ENUMERATOR) ZOZZ_MATHREF_OP_COUNT
} ZozzMathRefOp;

#undef ZOZZ_MATHREF_ENUMERATOR

/// Runs ozz's own implementation of `op` on `in_regs` sixteen-byte registers
/// at `in`, writing `out_regs` at `out`. Both must be sixteen-byte aligned.
/// Returns 0 on success, -1 if `op` is not an operation, -2 if either count
/// disagrees with zozzMathRefArity -- which is what makes a Zig-side arity
/// that has drifted a failure rather than a read past an operand.
int zozzMathRefEval(int op, const void* in, size_t in_regs, void* out,
                    size_t out_regs);

/// Registers `op` consumes and produces. Returns 0, or -1 if `op` is not an
/// operation.
int zozzMathRefArity(int op, size_t* in_regs, size_t* out_regs);

/// Name of `op` without its prefix, for a failure message. NULL if unknown.
const char* zozzMathRefName(int op);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_TEST_MATHREF_H_
