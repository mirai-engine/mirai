package mirai_render

import "core:math/linalg"
import "mirai:render/abi"

// What the renderer holds of one instance of its scene and what the cull of
// the last view did with it, while the cull probes it (Instance_Probe): the
// inspection of an entity reads it from the frames it draws, never by testing
// its box again on the CPU.

// The instance whose cull each view writes back with its counts
// (Gpu_Cull_Stats.probe).
Instance_Probe :: struct {
	instance: u32,    // + 1; 0: none
	eye:      Vec3,   // of the last view culled while it was asked, relative to the origin as the instances
	found:    [2]u32, // Gpu_Cull_Stats.probe of the last frame read back
}

// The instance the cull of the next frames probes; -1: none. What they found
// is read with renderer_stats_of_last_frame and renderer_instance_inspect.
renderer_probe_set :: proc(r: ^Renderer, instance: int) {
	r.probe = {instance = u32(instance + 1) if instance >= 0 && instance < len(r.scene.instances) else 0}
}

// What the cull of the last view did with an instance.
Instance_Cull :: enum u8 {
	None,     // drawn
	Hidden,   // hidden, out of the layers of the view, behind its clip plane or faded out
	Frustum,  // its box is out of the frustum
	Occluded, // its box is behind what the depth pyramid holds
	Untested, // no view culled it while it was probed
}

Instance_Inspect :: struct {
	mesh:      Mesh_Handle,
	low, high: Vec3, // its box in the world
	distance:  f32,  // m from the eye of the view that culled it to the middle of its box; 0: untested
	hidden:    bool,
	blended:   bool, // its own passes draw it, not the G-buffer
	cull:      Instance_Cull,
	level:     int,  // the finest level of its mesh the cut takes; -1: not drawn
	levels:    int,  // of its mesh
	skinned:   bool, // a pose: its vertices are written on the GPU
	posed:     bool, // its library gave its skin joints other than the rest it starts at
}

// An instance of the scene as the renderer holds it, with what the cull of
// the last frame did with it when it was the instance probed.
renderer_instance_inspect :: proc(r: ^Renderer, instance: int) -> (found: Instance_Inspect, ok: bool) {
	s := &r.scene
	if instance < 0 || instance >= len(s.instances) {return}
	inst := s.instances[instance]
	back :: proc "contextless" (point, origin: Vec3) -> Vec3 {
		return {f32(f64(point.x) + f64(origin.x)), f32(f64(point.y) + f64(origin.y)), f32(f64(point.z) + f64(origin.z))}
	}
	found = {
		mesh = Mesh_Handle(inst.meta.x & INSTANCE_MESH_MASK),
		low = back(inst.bounds_min, r.origin), high = back(inst.bounds_max.xyz, r.origin),
		hidden = inst.meta.w & INSTANCE_FLAG_HIDDEN != 0, blended = inst.meta.w & INSTANCE_FLAG_BLENDED != 0,
		cull = .Untested, level = -1,
	}
	if int(found.mesh) < len(s.meshes) {
		m := &s.meshes[found.mesh]
		found.levels = int(m.level_count)
		if skin := m.skin; skin != nil && !skin.displaced {
			found.skinned = true
			rest := rows_3x4(Mat4(1))
			for joint in skin.joints {if joint.current != rest {found.posed = true; break}}
		}
	}
	bits := r.probe.found[0]
	if r.probe.instance != u32(instance + 1) || bits & abi.CULL_PROBE_TESTED == 0 {return found, true}
	middle := (inst.bounds_min + inst.bounds_max.xyz) * 0.5 - r.probe.eye
	found.distance = linalg.length(middle)
	switch {
	case found.hidden || bits & (abi.CULL_PROBE_DRAWS | abi.CULL_PROBE_FRUSTUM) == abi.CULL_PROBE_FRUSTUM: found.cull = .Hidden
	case bits & abi.CULL_PROBE_DRAWS == 0: found.cull = .Frustum
	case bits & abi.CULL_PROBE_VISIBLE == 0: found.cull = .Occluded
	case:
		found.cull = .None
		found.level = int(r.probe.found[1]) - 1
	}
	return found, true
}

// Whether a streamed texture does not hold yet the levels the frames sample of it.
renderer_texture_pending :: proc(r: ^Renderer, handle: Texture_Handle) -> bool {
	streams := r.textures.residency.streams[:]
	index := int(handle) - 1
	if index < 0 || index >= len(streams) || index >= r.textures.count {return false}
	stream := &streams[index]
	return stream.levels > 0 && stream.target != stream.top
}
