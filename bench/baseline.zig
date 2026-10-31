//! The C++ twins of the bench rows, defined in bench/baseline.cpp.

const zozz = @import("zozz");
const SoaTransform = zozz.SoaTransform;
const Mat4 = zozz.Mat4;
const Vec4 = zozz.ik.Vec4;

pub extern fn zozz_baseline_open(skeleton: [*]const u8, skeleton_size: usize, animation: [*]const u8, animation_size: usize) ?*anyopaque;
pub extern fn zozz_baseline_close(world: *anyopaque) void;
pub extern fn zozz_baseline_load_skeleton(image: [*]const u8, size: usize, times: u64) u64;
pub extern fn zozz_baseline_load_animation(image: [*]const u8, size: usize, times: u64) u64;
pub extern fn zozz_baseline_sample(world: *anyopaque, ratios: [*]const f32, count: usize, out: [*]SoaTransform, blocks: usize, times: u64, checksum: *f32) bool;
pub extern fn zozz_baseline_local_to_model(world: *anyopaque, locals: [*]const SoaTransform, blocks: usize, models: [*]Mat4, times: u64, checksum: *f32) bool;
pub extern fn zozz_baseline_blend(poses: [*]const [*]const SoaTransform, weights: [*]const f32, count: usize, rest: [*]const SoaTransform, out: [*]SoaTransform, blocks: usize, times: u64, checksum: *f32) bool;
pub extern fn zozz_baseline_skin(matrices: [*]const Mat4, joints: usize, indices: [*]const u16, weights: [*]const f32, positions: [*]const f32, normals: [*]const f32, out_positions: [*]f32, out_normals: [*]f32, vertices: c_int, influences: c_int, times: u64, checksum: *f32) bool;
pub extern fn zozz_baseline_two_bone(start: *const Mat4, mid: *const Mat4, end: *const Mat4, targets: [*]const Vec4, count: usize, times: u64, checksum: *f32) bool;
