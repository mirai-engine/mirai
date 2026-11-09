package mirai_render

import "core:math"
import "core:math/linalg"
import "mirai:asset"
import "mirai:rhi"

// The cut of the levels of a mesh on the CPU, as cut.slang decides it on the
// GPU, and the cuts rays trace each instance with.

// The pixels an error of the world spans at the point of a sphere nearest
// the eye: footprint is the width of a pixel at depth 0 and what it grows by
// per unit of depth (Gpu_Frame.footprint), near the nearest depth.
lod_pixels :: proc "contextless" (center: Vec3, radius, error: f32, eye: Vec3, near: f32, footprint: Vec2) -> f32 {
	distance := max(linalg.length(center - eye) - radius, near)
	return error / max(footprint.x + footprint.y * distance, 1e-9)
}

// Whether a view draws a cluster of a mesh under transform: its own error
// is within threshold pixels and that of what replaces it is not.
cluster_in_cut :: proc "contextless" (transform: Mat4, c: asset.Cluster, eye: Vec3, near: f32, footprint: Vec2, threshold: f32) -> bool {
	scale := max(linalg.length(transform[0].xyz), linalg.length(transform[1].xyz), linalg.length(transform[2].xyz))
	own := (transform * Vec4{c.lod.x, c.lod.y, c.lod.z, 1}).xyz
	up := (transform * Vec4{c.parent.x, c.parent.y, c.parent.z, 1}).xyz
	return lod_pixels(own, c.lod.w * scale, c.error * scale, eye, near, footprint) <= threshold &&
		lod_pixels(up, c.parent.w * scale, c.parent_error * scale, eye, near, footprint) > threshold
}

// How far an instance goes past the distance of a coarser cut before rays
// take it, so one at that distance does not switch every frame.
RAY_CUT_HYSTERESIS :: f32(1.1)
// How far the eye moves before the cuts of the instances are chosen again, metres.
RAY_CUT_STEP :: f32(1)
// Frames a coarser cut keeps its native BLAS after no instance wants it, and
// at most between two choices of the cuts: one at the distance where it
// starts to serve is not built and let go over and over.
RAY_CUT_KEEP :: u64(600)

// The spacing of the cascade of probes that holds a point at distance from
// the eye: each holds probe_grid / 2 of its spacings around the eye, and the
// next doubles it.
probe_spacing_at :: proc "contextless" (settings: Settings, distance: f32) -> f32 {
	spacing := settings.probe_spacing
	reach := f32(max(settings.probe_grid / 2, 2))
	for _ in 1 ..< max(settings.probe_cascades, 1) {
		if distance <= spacing * reach {break}
		spacing *= 2
	}
	return spacing
}

// The least distance from the eye at which rays may trace a cut whose error
// in the world is error: the error is under the bias of the origin of a ray
// there, under half the penumbra the sun gives across that distance and under
// half the spacing of the probes there.
ray_cut_distance :: proc "contextless" (settings: Settings, error: f32) -> f32 {
	if error <= 0 {return 0}
	distance := max((error - 0.01) / 0.0015, 0)
	if settings.sun_radius > 0 {distance = max(distance, error / math.tan(settings.sun_radius))}
	for probe_spacing_at(settings, distance) * 0.5 < error {
		distance = max(distance * 2, 1)
		if distance > 1e7 {return max(f32)}
	}
	return distance
}

// Chooses the cut rays trace each instance with by its distance from the eye
// (Gpu_Mesh.rays), finer near, with hysteresis. Traced by hardware, a cut
// other than the one a mesh always has (ray_cut_always) has its native BLAS
// only while an instance wants it: the instance traces the cut it can
// (ray_cut_traceable) nearest the one it wants on the way to that one, the
// BLAS of the one it wants is built with the next publication, and one no
// instance wanted for RAY_CUT_KEEP frames goes. A change of cut changes the light around the
// instance only when its error changes by more than half the spacing of the
// probes there. Runs again when the eye moved RAY_CUT_STEP, the instances or
// the BLASes changed, or RAY_CUT_KEEP frames went by.
ray_cuts_update :: proc(r: ^Renderer, eye: Vec3) {
	s := &r.scene
	if !s.ray_cuts_stale && linalg.length(eye - s.ray_cut_eye) < RAY_CUT_STEP && r.frame < s.ray_cut_frame + RAY_CUT_KEEP {return}
	s.ray_cuts_stale, s.ray_cut_eye, s.ray_cut_frame = false, eye, r.frame
	stamp := r.frame + 1
	for &inst, index in s.instances {
		mesh := inst.meta.x & INSTANCE_MESH_MASK
		if int(mesh) >= len(s.meshes) || inst.meta.w & INSTANCE_FLAG_HIDDEN != 0 {continue}
		m := &s.meshes[mesh]
		if m.ray_count <= 1 && inst.meta.x >> INSTANCE_RAY_SHIFT == 0 {continue}
		low, high := inst.bounds_min.xyz, inst.bounds_max.xyz
		distance := linalg.length(eye - linalg.clamp(eye, low, high))
		c0 := Vec3{inst.world[0].x, inst.world[1].x, inst.world[2].x}
		c1 := Vec3{inst.world[0].y, inst.world[1].y, inst.world[2].y}
		c2 := Vec3{inst.world[0].z, inst.world[1].z, inst.world[2].z}
		scale := max(linalg.length(c0), linalg.length(c1), linalg.length(c2))
		was := min(inst.meta.x >> INSTANCE_RAY_SHIFT & 3, max(m.ray_count, 1) - 1)
		// The cut its distance asks for; a structure the tracer can build or has.
		want := was
		for want + 1 < m.ray_count && (r.hardware_rt || m.rays[want + 1].bvh_node_count > 0) && distance >= ray_cut_distance(r.settings, m.rays[want + 1].error * scale) * RAY_CUT_HYSTERESIS {want += 1}
		for want > 0 && distance < ray_cut_distance(r.settings, m.rays[want].error * scale) {want -= 1}
		m.rays[want].wanted = stamp
		cut := want
		always := u32(ray_cut_always(m^))
		for cut != always && !ray_cut_traceable(m^, int(cut), r.hardware_rt) {cut = cut + 1 if always > cut else cut - 1}
		m.rays[cut].wanted, m.rays[cut].traced = stamp, stamp
		if cut == inst.meta.x >> INSTANCE_RAY_SHIFT {continue}
		inst.meta.x = mesh | cut << INSTANCE_RAY_SHIFT
		if abs(m.rays[cut].error - m.rays[was].error) * scale > probe_spacing_at(r.settings, distance) * 0.5 {scene_changed_box(s, low, high)}
		if len(s.touched) < cap(s.touched) {append(&s.touched, u32(index))} else {s.instances_dirty = true}
		s.tlas_dirty = true
	}
	if !r.hardware_rt {return}
	// The native BLASes of coarser cuts no instance wants any more go; their
	// instances trace finer ones already.
	for &m in s.meshes {
		for k in 0 ..< int(m.ray_count) {
			ray := &m.rays[k]
			if k == ray_cut_always(m) || ray.blas == 0 || ray_cut_wanted(r, m, k) {continue}
			rhi.accel_destroy(r.device, ray.blas)
			ray.blas = 0
			geometry_released(s, u64(ray.table_count) * BLAS_TRIANGLE_BYTES)
			if ray.input_vertices > 0 {pool_release(&s.vertices, &s.pool_free[.Vertex], ray.input_vertex, ray.input_vertices)}
			if ray.input_indices > 0 {pool_release(&s.indices, &s.pool_free[.Index], ray.input_index, ray.input_indices)}
			ray.input_vertex, ray.input_vertices, ray.input_index, ray.input_indices = 0, 0, 0, 0
		}
	}
}

// Whether cut k of a mesh has its native BLAS built: the one it always has
// (ray_cut_always); another while an instance wanted it within RAY_CUT_KEEP
// frames.
@(private)
ray_cut_wanted :: proc "contextless" (r: ^Renderer, m: Mesh_Record, k: int) -> bool {
	wanted := m.rays[k].wanted
	return k == ray_cut_always(m) || wanted > 0 && r.frame + 1 - wanted <= RAY_CUT_KEEP
}

// The cut of a mesh rays can always trace, and its instances fall back to:
// level 0, or the coarsest of a streamed mesh, whose clusters are all in
// its root.
@(private)
ray_cut_always :: proc "contextless" (m: Mesh_Record) -> int {
	return int(max(m.ray_count, 1)) - 1 if m.stream != nil else 0
}

// Whether rays can trace a cut: it has the structure of the tracer in use.
@(private)
blas_or_tree :: proc "contextless" (ray: Mesh_Ray_Record, hardware: bool) -> bool {
	return ray.blas != 0 if hardware else ray.bvh_node_count > 0
}

// Whether rays can trace cut k of a mesh: it has its structure, and every
// page that holds its clusters is in the pools, where a hit reads them.
@(private)
ray_cut_traceable :: proc "contextless" (m: Mesh_Record, k: int, hardware: bool) -> bool {
	return blas_or_tree(m.rays[k], hardware) && (m.stream == nil || m.stream.cut_missing[k] == 0)
}
