/* A downstream C consumer, using the installed header and artifact directly.
 *
 * The point is the #include: it resolves only if build.zig installs the public
 * header alongside the library artifact, under the spelling the README tells a
 * C host to use. In-repo that is invisible, because the whole `ffi/` directory
 * is on the include path.
 *
 * It also spells the result enumerators the way a consumer written today
 * should: ZOZZ_RESULT_OK. */
#include <stdio.h>

#include <zozz.h>

int main(void) {
  ZozzRawSkeleton *raw_skeleton = NULL;
  if (zozzRawSkeletonCreate(&raw_skeleton) != ZOZZ_RESULT_OK) return 1;

  const ZozzTransform rest = {{0.f, 0.f, 0.f}, {0.f, 0.f, 0.f, 1.f}, {1.f, 1.f, 1.f}};
  int32_t root = -1;
  if (zozzRawSkeletonAddJoint(raw_skeleton, ZOZZ_NO_PARENT, "root", &rest,
                              &root) != ZOZZ_RESULT_OK) {
    return 1;
  }

  ZozzSkeleton *skeleton = NULL;
  if (zozzSkeletonBuild(raw_skeleton, &skeleton) != ZOZZ_RESULT_OK) return 1;
  zozzRawSkeletonDestroy(raw_skeleton);

  if (zozzSkeletonNumJoints(skeleton) != 1) return 1;
  if (zozzSkeletonJointParent(skeleton, 0) != ZOZZ_NO_PARENT) return 1;

  ZozzTransform out = {{0}, {0}, {0}};
  if (zozzSkeletonRestPose(skeleton, &out, 1) != ZOZZ_RESULT_OK) return 1;
  if (out.scale[0] != 1.f) return 1;

  /* A refused call still has to report why, in the caller's own spelling. */
  if (zozzSkeletonRestPose(skeleton, &out, 0) != ZOZZ_RESULT_BUFFER_TOO_SMALL) {
    return 1;
  }

  /* The library's own account of its layout, which is the thing a C host
   * cannot get from the header alone -- the header describes what this
   * translation unit compiled to, not what the linked library did. */
  ZozzAbiLayout layout;
  zozzAbiLayout(&layout);
  if (layout.layout_size != (uint32_t)sizeof(ZozzAbiLayout)) return 1;

  const uint32_t v = zozzVersion();
  const uint32_t o = zozzOzzVersion();
  printf("c consumer ok: zozz %u.%u.%u, ozz %u.%u.%u, transform %u bytes\n",
         v >> 16, (v >> 8) & 0xFFu, v & 0xFFu,
         o >> 16, (o >> 8) & 0xFFu, o & 0xFFu,
         (unsigned)layout.transform_size);

  zozzSkeletonDestroy(skeleton);
  return 0;
}
