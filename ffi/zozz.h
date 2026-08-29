//===----------------------------------------------------------------------===//
// zozz — a C ABI over ozz-animation's runtime.
//
// This header is the umbrella: the ONLY contract between the C++
// implementation and any consumer (the Zig wrapper in ../src, or a plain C
// host) is the union of what it pulls in below, one header per concern,
// matching the .cpp file that implements it. Include this one header for the
// whole surface, or include a concern's own header directly — each stands on
// its own, at the cost of a little redundant preprocessing the very first
// time it is reached.
//
// Conventions that apply to the whole ABI — ownership rules, thread safety,
// the ZOZZ_API linkage macro, ZozzResult, and the plain-data types every other
// header builds on — are documented once, in zozz_core.h, rather than
// repeated here.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_H_
#define ZOZZ_H_

#include "zozz_core.h"

//===----------------------------------------------------------------------===//
// Joint-visitor callback — forward declared here, ahead of every header that
// uses it, rather than in the one that first happens to need it.
//
// zozz_utils.h's runtime-skeleton traversal and zozz_offline.h's raw-skeleton
// traversal (below) share this one callback shape. Whichever of the two a
// translation unit includes directly is the file whose own header guard
// blocks the umbrella's later attempt to include it again, so the OTHER
// header — reached first through this umbrella, before control ever returns
// to the directly-included one's own body — would otherwise see an
// undeclared type. Declaring it here, ahead of both, is what the
// ZozzRawFloatTrack forward declarations further down do for the
// optimizer/rawtrack pair, applied before the hazard can occur rather than
// after.
//===----------------------------------------------------------------------===//

#ifdef __cplusplus
extern "C" {
#endif

/// Visits one joint of a hierarchy traversal. `parent` is ZOZZ_NO_PARENT when
/// `joint` is a root of the traversal. Must not throw or unwind: nothing on
/// this side of the call can propagate an exception across it, and a Zig
/// implementation must stash any error in `user` and re-raise it after the
/// call returns rather than crossing the boundary with it.
typedef void (*ZozzJointVisitor)(int joint, int parent, void* user);

#ifdef __cplusplus
}  // extern "C"
#endif

#include "zozz_skeleton.h"
#include "zozz_animation.h"
#include "zozz_pose.h"
#include "zozz_sampling.h"
#include "zozz_ik.h"
#include "zozz_skinning.h"
#include "zozz_utils.h"
#include "zozz_motion.h"
#include "zozz_offline.h"

//===----------------------------------------------------------------------===//
// Offline animation processing and raw tracks — forward declarations
//
// Declared here, ahead of zozz_optimizer.h and zozz_rawtrack.h, rather than
// inside either one: the motion extractor (zozz_optimizer.h) reads and writes
// a RawFloat3Track and a RawQuaternionTrack (zozz_rawtrack.h) directly, so
// whichever of the two headers is textually included second would otherwise
// see an undeclared type. A forward-declared opaque tag may be repeated by
// the header that actually owns the type without conflict, so this does not
// make either header authoritative over the other.
//===----------------------------------------------------------------------===//

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZozzRawFloatTrack ZozzRawFloatTrack;
typedef struct ZozzRawFloat2Track ZozzRawFloat2Track;
typedef struct ZozzRawFloat3Track ZozzRawFloat3Track;
typedef struct ZozzRawFloat4Track ZozzRawFloat4Track;
typedef struct ZozzRawQuaternionTrack ZozzRawQuaternionTrack;

#ifdef __cplusplus
}  // extern "C"
#endif

#include "zozz_optimizer.h"
#include "zozz_rawtrack.h"

//===----------------------------------------------------------------------===//
// Runtime user tracks — keyframed curves sampled independently of the
// skeletal animation pipeline, plus edge triggering over a FloatTrack. Split
// out into its own header because ozz templates the runtime type over five
// value types, which is a lot of declarations for one area.
//===----------------------------------------------------------------------===//

#include "zozz_track.h"

//===----------------------------------------------------------------------===//
// Pose blending — weighted, additive and per-joint partial blending, all one
// job. Split out into its own header for the same reason tracks are.
//===----------------------------------------------------------------------===//

#include "zozz_blending.h"

//===----------------------------------------------------------------------===//
// The OArchive write path — persisting a skeleton or a clip to a stream a
// host controls, or straight to a file.
//===----------------------------------------------------------------------===//

#include "zozz_archive.h"

//===----------------------------------------------------------------------===//
// GV4 group-varint codec — the wire format zozzAnimationKeyframeIframeEntries'
// buffer is encoded with.
//===----------------------------------------------------------------------===//

#include "zozz_encode.h"

//===----------------------------------------------------------------------===//
// ozz's command-line option parser (-Doptions) and the OzzImporter converter
// interface (generic accessors always available; the concrete glTF backend
// behind -Dgltf, the host-implementable side and the CLI driver behind
// -Doptions).
//===----------------------------------------------------------------------===//

#include "zozz_options.h"
#include "zozz_gltf.h"

#endif  // ZOZZ_H_
