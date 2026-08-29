//===----------------------------------------------------------------------===//
// zozz — the concrete runtime track handles, shared by the two translation
// units that need them.
//
// `zozz_track.cpp` samples these and `zozz_rawtrack.cpp` builds them, so both
// need the layout. Separate per-file definitions were an ODR violation that
// happened to be benign only because the two definitions were identical, and
// unsafe the moment either one was edited.
//
// The destroy entry points live in `zozz_track.cpp` alone. Defining them in
// both was a latent duplicate-symbol error: a static archive pulls in one
// object until something needs both, so it linked fine until a caller both
// authored a track and sampled it — which is the documented workflow.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_TRACK_TYPES_H
#define ZOZZ_TRACK_TYPES_H

#include "ozz/animation/runtime/track.h"

struct ZozzFloatTrack {
  ozz::animation::FloatTrack impl;
};
struct ZozzFloat2Track {
  ozz::animation::Float2Track impl;
};
struct ZozzFloat3Track {
  ozz::animation::Float3Track impl;
};
struct ZozzFloat4Track {
  ozz::animation::Float4Track impl;
};
struct ZozzQuaternionTrack {
  ozz::animation::QuaternionTrack impl;
};

#endif  // ZOZZ_TRACK_TYPES_H
