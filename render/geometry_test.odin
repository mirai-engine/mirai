package mirai_render

import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:rhi"
import mm "mirai:std/math"

// The geometry asset.mesh_build makes of vertices and indices, in whole
// levels when given, the slot words of their materials, and the vertex of
// `vertices` each vertex of its clusters is: what lays out data by vertex
// (influences, the ranges of morph targets) in the order of the clusters
// (test_by_cluster).
@(private)
test_geometry :: proc(vertices: []Mesh_Vertex, indices: []u32, levels: []asset.Level_Source = nil) -> (g: asset.Mesh_Geometry, origins, slot_words: []u32, ok: bool) {
	source := make([]asset.Vertex, len(vertices), context.temp_allocator)
	slots := make([dynamic]u32, 0, asset.MESH_MAX_SLOTS, context.temp_allocator)
	if !mesh_vertices_source(vertices, source, &slots) {return}
	// The index of each vertex rides in the joints of a skin the geometry then leaves out.
	marks := make([]asset.Skin_Vertex, len(vertices), context.temp_allocator)
	for &mark, i in marks {mark = {joints = {u16(i), u16(i >> 16), 0, 0, 0, 0, 0, 0}, weights = {255, 0, 0, 0, 0, 0, 0, 0}}}
	flags: asset.Mesh_Flags
	for v in vertices {
		if v.color != {1, 1, 1} {flags += {.Has_Colors}}
		if v.uv1 != v.uv {flags += {.Has_Uv1}}
	}
	if !asset.mesh_build({vertices = source, skin = marks, flags = flags}, indices, levels, &g, context.temp_allocator) {return}
	origins = make([]u32, len(g.skin), context.temp_allocator)
	for mark, v in g.skin {origins[v] = u32(mark.joints[0]) | u32(mark.joints[1]) << 16}
	g.skin = nil
	return g, origins, slots[:], true
}

// Registers a mesh as mesh_add does, in whole levels when given, with what test_geometry gives.
@(private)
test_mesh_add :: proc(r: ^Renderer, vertices: []Mesh_Vertex, indices: []u32, levels: []asset.Level_Source = nil) -> (handle: Mesh_Handle, origins: []u32, ok: bool) {
	slot_words: []u32
	geometry: asset.Mesh_Geometry
	geometry, origins, slot_words, ok = test_geometry(vertices, indices, levels)
	if !ok {return}
	handle, ok = mesh_add_geometry(r, geometry, slot_words)
	return
}

// The vertices of the clusters of a mesh as its pools hold them at rest, decoded.
@(private)
test_rest :: proc(r: ^Renderer, handle: Mesh_Handle) -> []Mesh_Vertex {
	m := r.scene.meshes[handle]
	g, _ := record_decode(&r.scene, m, context.temp_allocator)
	out := make([]Mesh_Vertex, m.vertex_count, context.temp_allocator)
	for c in g.clusters {
		for local in 0 ..< asset.cluster_vertex_count(c) {
			v := asset.cluster_vertex(g, c, local)
			tangent, sign := mm.tangent_unpack(v.tangent)
			out[c.vertex_first + local] = {position = v.position, normal = mm.normal_unpack(v.normal), uv = v.uv, uv1 = v.uv1, color = {1, 1, 1}, tangent = {tangent.x, tangent.y, tangent.z, sign}}
		}
	}
	return out
}

// Data by vertex of a mesh as given, in the order of its clusters.
@(private)
test_by_cluster :: proc(origins: []u32, given: []$T) -> []T {
	out := make([]T, len(origins), context.temp_allocator)
	for origin, v in origins {out[v] = given[origin]}
	return out
}

// The ranges of morph targets of the vertices as given, for those of the clusters.
@(private)
test_morph_by_cluster :: proc(origins: []u32, morph: Morph_Data) -> Morph_Data {
	if morph.count == 0 {return morph}
	ranges := make([]Morph_Range, len(origins), context.temp_allocator)
	deltas := make([dynamic]Morph_Delta, 0, len(morph.deltas), context.temp_allocator)
	for origin, v in origins {
		given := morph.ranges[origin]
		ranges[v] = {u32(len(deltas)), given.count}
		append(&deltas, ..morph.deltas[given.first:][:given.count])
	}
	return {ranges = ranges, deltas = deltas[:], count = morph.count, step = morph.step}
}

// A delta of a target quantized on step, as a mesh stores it.
@(private)
test_morph_delta :: proc(target: u32, position: Vec3, normal: Vec3 = {}, tangent: Vec3 = {}, step: f32 = TEST_MORPH_STEP) -> Morph_Delta {
	q := asset.morph_quantize({position = position, normal = normal, tangent = tangent}, step)
	return {target = target, position = q.position, normal = q.normal, tangent = q.tangent}
}
TEST_MORPH_STEP :: 1.0 / 4096

// Influences of two joints at weights 1 - w and w.
@(private)
test_two_joints :: proc(w: f32) -> Skin_Influence {
	return {joints = {0, 1, 0, 0, 0, 0, 0, 0}, weights = asset.skin_weights_quantize({1 - w, w, 0, 0, 0, 0, 0, 0})}
}

@(test)
the_cut_takes_one_of_a_cluster_and_the_clusters_that_replace_it_at_any_distance :: proc(t: ^testing.T) {
	// Level 0: two clusters in spheres inside that of their parent, a root.
	child_a := asset.Cluster{lod = {-0.5, 0, 0, 0.6}, error = 0, parent = {0, 0, 0, 1.2}, parent_error = 0.01}
	child_b := asset.Cluster{lod = {0.5, 0, 0, 0.6}, error = 0, parent = {0, 0, 0, 1.2}, parent_error = 0.01}
	root := asset.Cluster{lod = {0, 0, 0, 1.2}, error = 0.01, parent = {0, 0, 0, 1.2}, parent_error = asset.CLUSTER_ROOT}
	footprint := Vec2{0.0005, 0.001}
	for scale in ([]f32{0.5, 1, 4}) {
		transform := Mat4(1)
		for axis in 0 ..< 3 {transform[axis, axis] = scale}
		switched := false
		for step in 0 ..< 400 {
			eye := Vec3{0, 0, 0.05 * f32(step) * f32(step)}
			a := cluster_in_cut(transform, child_a, eye, 0.1, footprint, 1)
			b := cluster_in_cut(transform, child_b, eye, 0.1, footprint, 1)
			up := cluster_in_cut(transform, root, eye, 0.1, footprint, 1)
			testing.expectf(t, a == b && a != up, "one of the two levels at %v, scale %v: %v %v %v", eye, scale, a, b, up)
			// Farther never goes back to the finer level.
			if up {switched = true} else {testing.expect(t, !switched, "the cut does not return to level 0 farther away")}
		}
		testing.expectf(t, switched, "far away the root alone, scale %v", scale)
	}
	// Without a threshold, level 0 alone.
	testing.expect(t, cluster_in_cut(1, child_a, {0, 0, 1e6}, 0.1, footprint, 0) && !cluster_in_cut(1, root, {0, 0, 1e6}, 0.1, footprint, 0))
}

@(test)
whole_levels_take_one_level_of_the_cut_at_any_distance :: proc(t: ^testing.T) {
	vertices := make([dynamic]asset.Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for cell in 0 ..< 600 {
		x, z := f32(cell % 30), f32(cell / 30)
		first := u32(len(vertices))
		for corner in 0 ..< 4 {
			dx, dz := f32(corner & 1), f32(corner >> 1)
			append(&vertices, asset.Vertex{position = {x + dx, 0, z + dz}, normal = mm.normal_pack({0, 1, 0}), uv = {dx, dz}, color = 0xffffffff, tangent = mm.tangent_pack({1, 0, 0}, 1)})
		}
		append(&indices, first, first + 1, first + 2, first + 2, first + 1, first + 3)
	}
	coarse := make([dynamic]u32, context.temp_allocator)
	for q := 0; q < len(indices) / 6; q += 2 {append(&coarse, ..indices[q * 6:][:6])}
	all := make([dynamic]u32, context.temp_allocator)
	append(&all, ..indices[:])
	append(&all, ..coarse[:])
	levels := [2]asset.Level_Source{{0, u32(len(indices)), 0}, {u32(len(indices)), u32(len(coarse)), 0.2}}
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build({vertices = vertices[:]}, all[:], levels[:], &g, context.temp_allocator)) {return}
	for step in 0 ..< 200 {
		eye := Vec3{15, 1, 10 + f32(step) * f32(step) * 0.1}
		taken: [2]int
		for c, at in g.clusters {
			level := 0 if u32(at) < g.levels[1].first_cluster else 1
			if cluster_in_cut(1, c, eye, 0.1, {0.0005, 0.001}, 1) {taken[level] += 1}
		}
		whole := [2]int{int(g.levels[0].cluster_count), int(g.levels[1].cluster_count)}
		testing.expectf(t, taken == {whole[0], 0} || taken == {0, whole[1]}, "a whole level at %v: %v of %v", eye, taken, whole)
	}
}

// Where the vertices a pose moves are now on the GPU, or where they were in the frame before.
@(private)
test_posed :: proc(device: ^rhi.Device, r: ^Renderer, handle: Mesh_Handle, previous := false) -> (posed: []Gpu_Posed_Vertex, ok: bool) {
	m := r.scene.meshes[handle]
	posed = make([]Gpu_Posed_Vertex, m.vertices_posed, context.temp_allocator)
	word := m.previous_word if previous else m.posed_word
	return posed, rhi.buffer_read_slice(device, r.scene.vertex_buffer, u64(word) * 4, posed)
}

// An allocator that fills what it frees with ones, and what a resize moves
// away from: reading memory a pool left reads them.
@(private = "file")
poison_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	parent := (^mem.Allocator)(data)^
	#partial switch mode {
	case .Free:
		if old_memory != nil && old_size > 0 {mem.set(old_memory, 0xff, old_size)}
	case .Resize, .Resize_Non_Zeroed:
		bytes, error := parent.procedure(parent.data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		if error != nil {return nil, error}
		if old_memory != nil {
			mem.copy(raw_data(bytes), old_memory, min(old_size, size))
			mem.set(old_memory, 0xff, old_size)
			parent.procedure(parent.data, .Free, 0, 0, old_memory, old_size, loc)
		}
		return bytes, nil
	}
	return parent.procedure(parent.data, mode, size, alignment, old_memory, old_size, loc)
}

// The inputs of a native BLAS are the triangles of its cut, though the pools
// they are added to move while the clusters they come from are in them.
@(test)
blas_inputs_take_the_triangles_of_their_cut_while_the_pools_move :: proc(t: ^testing.T) {
	parent := context.allocator
	r:=new(Renderer);defer free(r)
	r.allocator = {poison_proc, &parent}
	scene_init(r)
	defer scene_destroy(r)
	r.hardware_rt = true
	vertices, indices, influences := skin_test_grid(24)
	defer delete(vertices);defer delete(indices);defer delete(influences)
	handle, added := mesh_add(r, vertices, indices)
	if !testing.expect(t, added) {return}
	s := &r.scene
	m := &s.meshes[handle]
	if !testing.expect(t, m.rays[0].table_count > 0, "traced by hardware, a cut has its table") {return}
	// The pools are full: what is added next moves them.
	shrink(&s.vertices)
	shrink(&s.indices)
	if _, ok := blas_inputs_add(r, m); !testing.expect(t, ok) {return}
	ray := m.rays[0]
	testing.expect_value(t, ray.input_vertices, ray.table_count * 9)
	p := record_pooled(s, m^)
	positions := s.vertices[ray.input_vertex:][:ray.input_vertices]
	for primitive, k in s.indices[ray.table_word:][:ray.table_count] {
		a, b, c := pooled_primitive_positions(p, primitive)
		for want, corner in ([3]Vec3{a, b, c}) {
			at := k * 9 + corner * 3
			got := transmute(Vec3)[3]u32{positions[at], positions[at + 1], positions[at + 2]}
			if got != want {testing.expectf(t, false, "corner %d of primitive %d is %v, not %v", corner, k, got, want);return}
		}
	}
}
