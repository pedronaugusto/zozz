//! Root-motion blending.
//!
//! ozz 0.17.0 ships no motion_sampling_job.h in the runtime, so there is no
//! sampling counterpart here: root-motion deltas come from wherever the host
//! extracted them (offline, at bake time) and are combined at runtime only
//! through blending.

const std = @import("std");
const c = @import("c.zig");
const err = @import("error.zig");
const math = @import("math.zig");

/// One weighted input to `blend`.
///
/// Re-exported from `c.zig`, not copied — `delta` borrows the caller's
/// transform for the call only, the way `math.Transform` and `math.Mat4` do
/// for the rest of the package.
pub const BlendLayer = c.MotionBlendLayer;

/// Blends `layers` into a single normalized root-motion delta:
/// direction-and-length-separated lerp for translation, shortest-arc NLerp
/// for rotation, identity scale. An empty `layers` yields the identity
/// transform.
pub fn blend(layers: []const BlendLayer, out: *math.Transform) err.Error!void {
    try err.check(c.zozzMotionBlend(layers.ptr, layers.len, out));
}
