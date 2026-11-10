package mirai_render

import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:rhi"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:render/abi"

// The meshes of the scene in the two word pools (gpu_types.odin): each one a
// block of the vertex pool (the blocks of its pages one after the other, in
// their order, and where a pose puts its vertices) and one of the index pool
// (its clusters, its page table, its levels and the material word of each
// slot), as asset.mesh_build encoded them. A cluster is read through the
// entry of its page, on the GPU (geometry.slang) as on the CPU, which keeps
// a copy of both pools and reads it with the decoders of asset over the
// block of the page (pooled_cluster), the same that read a file.

// A cut of a mesh rays trace (Gpu_Mesh_Ray): its software tree, the table of
// the triangles of its native BLAS in the index pool, the BLAS, and where
// its positions and indices are while the BLAS is built.
Mesh_Ray_Record :: struct {
	bvh_root, bvh_node_count:        u32, // none (no nodes) until rays are traced by software
	triangle_offset, triangle_count: u32,
	table_word, table_count:         u32, // a word a triangle: its cluster << 7 | its triangle; none until rays are traced by hardware
	blas:                            rhi.Accel,
	input_vertex, input_vertices:    u32, // f32 positions in the vertex pool, while its BLAS waits to be built
	input_index, input_indices:      u32, // u32 indices in the index pool
	error:                           f32,
	wanted:                          u64, // the last frame + 1 an instance wanted the cut or traced it (ray_cuts_update); 0: never
	traced:                          u64, // the last frame + 1 an instance traced it: its pages stay in the pools
}

Mesh_Record :: struct {
	vertex_word, vertex_span:        u32, // its block of the vertex pool
	index_word, index_span:          u32, // and of the index pool
	cluster_word, cluster_count:     u32,
	page_word, page_count:           u32, // its page table, PAGE_ENTRY_WORDS a page
	level_word, level_count:         u32,
	vertex_count, vertices_posed:    u32, // of its clusters, and of those a pose moves (level 0, or all)
	slot_word, slot_count:           u32,
	posed_word, previous_word:       u32, // GPU_NONE: as its clusters
	part_word, rest_word:            u32, // posed with its part collapsed, and the rest an extension deforms from; GPU_NONE: none
	flags:                           u32, // MESH_FLAG_*
	position_step, uv_step, uv1_step, lod_reach: f32,
	bounds_min, bounds_max:          Vec3,
	slab_axes:                       u32,
	uv_density:                      [MESH_UV_ENTRIES][2]f32, // of each of its slots (mesh_uv_density)
	triangle_count:                  u32, // of level 0
	rays:                            [asset.MESH_RAY_LEVELS]Mesh_Ray_Record,
	ray_count:                       u32,
	first_instance:                  i32,
	skin:                            ^Skin_State,
	skin_binding:                    ^Skin_Binding,
	stream:                          ^Mesh_Stream, // of a mesh whose pages out of the root come and go (pages.odin)
	whole:                           u64, // the frame + 1 an extension last drew all of its level 0 (frame_mesh_whole); 0: none
}

// A mesh as the pools hold it: its clusters and levels, and the page table
// through which the vertices and triangles of each cluster are read from the
// vertex pool. Slices of the pools, valid until they change. A page of a
// streamed mesh out of the pools is read from its compressed block, decoded
// into the scratch of the scene.
@(private)
Pooled_Mesh :: struct {
	clusters:                         []asset.Cluster,
	levels:                           []asset.Mesh_Level,
	pages:                            []Gpu_Mesh_Page,
	vertices:                         []u32, // the vertex pool
	flags:                            asset.Mesh_Flags, // the streams of the blocks of its pages
	position_step, uv_step, uv1_step: f32,
	stream:                           ^Mesh_Stream,
	scratch:                          ^Page_Scratch,
}

@(private)
record_pooled :: proc(s: ^Scene_State, m: Mesh_Record) -> (p: Pooled_Mesh) {
	if m.vertex_count == 0 {return}
	p.clusters = mem.slice_data_cast([]asset.Cluster, s.indices[m.cluster_word:][:m.cluster_count * CLUSTER_WORDS])
	p.levels = mem.slice_data_cast([]asset.Mesh_Level, s.indices[m.level_word:][:m.level_count * LEVEL_WORDS])
	p.pages = mem.slice_data_cast([]Gpu_Mesh_Page, s.indices[m.page_word:][:m.page_count * PAGE_ENTRY_WORDS])
	p.vertices = s.vertices[:]
	p.flags = mesh_streams(m.flags)
	p.position_step, p.uv_step, p.uv1_step = m.position_step, m.uv_step, m.uv1_step
	p.stream, p.scratch = m.stream, &s.pages.scratch
	return
}

// The MESH_FLAG_* of the streams the blocks of the pages of a mesh have past
// its vertices, and back.
@(private)
mesh_stream_flags :: proc "contextless" (flags: asset.Mesh_Flags) -> (bits: u32) {
	if .Has_Uv1 in flags {bits |= MESH_FLAG_UV1}
	if .Has_Colors in flags {bits |= MESH_FLAG_COLORS}
	if .Has_Surface in flags {bits |= MESH_FLAG_SURFACE}
	return
}
@(private)
mesh_streams :: proc "contextless" (bits: u32) -> (flags: asset.Mesh_Flags) {
	if bits & MESH_FLAG_UV1 != 0 {flags += {.Has_Uv1}}
	if bits & MESH_FLAG_COLORS != 0 {flags += {.Has_Colors}}
	if bits & MESH_FLAG_SURFACE != 0 {flags += {.Has_Surface}}
	return
}

// The block of a page of a mesh: in the vertex pool, or, out of it, decoded
// from the compressed blocks of a streamed mesh into the scratch, which holds
// it until another page is read. nil for a page out of the pools of a mesh
// that does not stream, or whose block does not decode.
@(private)
pooled_page_block :: proc(p: Pooled_Mesh, page: u32) -> []u32 {
	entry := p.pages[page]
	if entry.base != GPU_NONE {return p.vertices[entry.base:]}
	if p.stream == nil || p.scratch == nil || len(p.scratch.words) == 0 {return nil}
	if p.scratch.stream != p.stream.id || p.scratch.page != page {
		p.scratch.stream = 0
		if !asset.mesh_page_decode(p.stream.flags, p.stream.pages[page], p.stream.data, p.scratch.coded, p.scratch.words, &p.scratch.decoder) {return nil}
		p.scratch.stream, p.scratch.page = p.stream.id, page
	}
	return p.scratch.words
}

// A cluster of a mesh and the geometry of its page, in which the decoders of
// asset read it: in both its vertices and its words of triangles count from
// those of the page. ok false when its page cannot be read (pooled_page_block).
@(private)
pooled_cluster :: proc(p: Pooled_Mesh, ordinal: u32) -> (g: asset.Mesh_Geometry, c: asset.Cluster, ok: bool) {
	c = p.clusters[ordinal]
	page := p.pages[c.page]
	source := pooled_page_block(p, c.page)
	if source == nil {return}
	layout := asset.mesh_page_layout(p.flags, page.vertex_count, 0)
	c.vertex_first -= page.first_vertex
	c.triangle_first -= page.first_triangle
	block := source[:layout.triangles + c.triangle_first + asset.cluster_triangle_words(c)]
	g.vertices = mem.slice_data_cast([]asset.Cluster_Vertex, block[:layout.uv1s])
	if .Has_Uv1 in p.flags {g.uv1s = block[layout.uv1s:layout.colors]}
	if .Has_Colors in p.flags {g.colors = block[layout.colors:layout.surfaces]}
	if .Has_Surface in p.flags {g.surfaces = mem.slice_data_cast([]asset.Surface_Vertex, block[layout.surfaces:layout.triangles])}
	g.triangles = block[layout.triangles:]
	g.flags = p.flags
	g.position_step, g.uv_step, g.uv1_step = p.position_step, p.uv_step, p.uv1_step
	return g, c, true
}

// The corners of the triangle a primitive names, in the space of the mesh;
// zero while its page is not in the pools.
@(private)
pooled_primitive_positions :: proc(p: Pooled_Mesh, primitive: u32) -> (a, b, c: Vec3) {
	g, cluster, ok := pooled_cluster(p, primitive >> PRIMITIVE_TRIANGLE_BITS)
	if !ok {return}
	return cluster_triangle_positions(g, cluster, primitive & (1 << PRIMITIVE_TRIANGLE_BITS - 1))
}

// The whole geometry of a mesh decoded from its pages, those out of the
// pools too, for what wants the arrays of asset.Mesh_Geometry: its clusters,
// levels, vertices, streams and triangles in allocator
// (geometry_decoded_free), without pages. False without memory or with a
// page that cannot be read.
@(private)
record_decode :: proc(s: ^Scene_State, m: Mesh_Record, allocator: mem.Allocator) -> (g: asset.Mesh_Geometry, ok: bool) {
	p := record_pooled(s, m)
	if len(p.clusters) == 0 {return}
	defer if !ok {geometry_decoded_free(&g, allocator)}
	words: u32
	for c in p.clusters {words = max(words, c.triangle_first + asset.cluster_triangle_words(c))}
	error: mem.Allocator_Error
	if g.clusters, error = make([]asset.Cluster, len(p.clusters), allocator); error != nil {return}
	if g.levels, error = make([]asset.Mesh_Level, len(p.levels), allocator); error != nil {return}
	if g.vertices, error = make([]asset.Cluster_Vertex, m.vertex_count, allocator); error != nil {return}
	if g.triangles, error = make([]u32, words, allocator); error != nil {return}
	if .Has_Uv1 in p.flags {if g.uv1s, error = make([]u32, m.vertex_count, allocator); error != nil {return}}
	if .Has_Colors in p.flags {if g.colors, error = make([]u32, m.vertex_count, allocator); error != nil {return}}
	if .Has_Surface in p.flags {if g.surfaces, error = make([]asset.Surface_Vertex, m.vertex_count, allocator); error != nil {return}}
	copy(g.clusters, p.clusters)
	copy(g.levels, p.levels)
	for whole, ordinal in p.clusters {
		page, c, resident := pooled_cluster(p, u32(ordinal))
		if !resident {return}
		count, held := asset.cluster_vertex_count(c), asset.cluster_triangle_words(c)
		copy(g.vertices[whole.vertex_first:][:count], page.vertices[c.vertex_first:][:count])
		if len(g.uv1s) > 0 {copy(g.uv1s[whole.vertex_first:][:count], page.uv1s[c.vertex_first:][:count])}
		if len(g.colors) > 0 {copy(g.colors[whole.vertex_first:][:count], page.colors[c.vertex_first:][:count])}
		if len(g.surfaces) > 0 {copy(g.surfaces[whole.vertex_first:][:count], page.surfaces[c.vertex_first:][:count])}
		copy(g.triangles[whole.triangle_first:][:held], page.triangles[c.triangle_first:][:held])
	}
	g.flags = p.flags
	if m.flags & MESH_FLAG_CLOSED != 0 {g.flags += {.Closed}}
	g.position_step, g.uv_step, g.uv1_step = p.position_step, p.uv_step, p.uv1_step
	g.bounds_min, g.bounds_max = m.bounds_min, m.bounds_max
	return g, true
}

@(private)
geometry_decoded_free :: proc(g: ^asset.Mesh_Geometry, allocator: mem.Allocator) {
	delete(g.clusters, allocator);delete(g.levels, allocator);delete(g.vertices, allocator);delete(g.triangles, allocator)
	delete(g.uv1s, allocator);delete(g.colors, allocator);delete(g.surfaces, allocator)
	g^ = {}
}

// Appends the blocks of the pages of g from page first on to vertices, one
// after the other in the order of the pages, and the entry of every page to
// indices: its base counted from the word vertex_start of vertices, GPU_NONE
// before first. False without memory.
@(private)
pages_append :: proc(g: asset.Mesh_Geometry, vertices, indices: ^[dynamic]u32, vertex_start: u32, first: u32 = 0) -> bool {
	words := 0
	for page in g.pages[first:] {words += int(page_words(g, page))}
	at := len(vertices)
	if resize(vertices, at + words) != nil || reserve(indices, len(indices) + len(g.pages) * PAGE_ENTRY_WORDS) != nil {
		base.truncate(vertices, at)
		return false
	}
	for page, k in g.pages {
		if u32(k) < first {
			entry := page_entry(page, GPU_NONE)
			append(indices, ..entry[:])
			continue
		}
		words := page_words(g, page)
		asset.mesh_page_gather(g, page, vertices[at:][:words])
		entry := page_entry(page, u32(at) - vertex_start)
		append(indices, ..entry[:])
		at += int(words)
	}
	return true
}

// The entry of a page in the page table of its mesh, its block at base.
@(private)
page_entry :: proc "contextless" (page: asset.Mesh_Page, base: u32) -> [PAGE_ENTRY_WORDS]u32 {
	return {base, page.first_vertex, page.vertex_count, page.first_triangle}
}

// The words of the block of a page of g, with the streams g has.
@(private)
page_words :: proc "contextless" (g: asset.Mesh_Geometry, page: asset.Mesh_Page) -> u32 {
	return asset.mesh_page_layout(g.flags, page.vertex_count, page.triangle_words).words
}
#assert(size_of(asset.Mesh_Level) == LEVEL_WORDS * 4)
// The words of a cluster the shaders read (geometry.slang, cluster_at) are its fields.
#assert(offset_of(asset.Cluster, vertex_first) == 3 * 4 && offset_of(asset.Cluster, triangle_first) == 8 * 4 && offset_of(asset.Cluster, lod) == 12 * 4)
#assert(offset_of(asset.Cluster, error) == 16 * 4 && offset_of(asset.Cluster, parent) == 17 * 4 && offset_of(asset.Cluster, parent_error) == 21 * 4)
#assert(offset_of(asset.Cluster, page) == 22 * 4)

// The clusters of a level of a record: its first and how many.
@(private)
record_level :: proc(s: ^Scene_State, m: Mesh_Record, level: u32) -> (first, count: u32) {
	return s.indices[m.level_word + level * LEVEL_WORDS], s.indices[m.level_word + level * LEVEL_WORDS + 1]
}

// The triangles of a cut rays trace and what makes their trees: for every
// triangle, its cluster << 7 | its triangle, in the order of the clusters.
Mesh_Ray_Cut :: struct {
	primitives: []u32,
	nodes:      []Gpu_Bvh_Node,     // the software tree, with software
	triangles:  []Gpu_Bvh_Triangle,
	error:      f32,
}
// The cuts a mesh is traced with, level 0 first, and the density of its uv
// (mesh_uv_density), which its textures stream by: made on any thread ahead
// of mesh_add_geometry, or by it.
Mesh_Rays :: struct {
	cuts:       [asset.MESH_RAY_LEVELS]Mesh_Ray_Cut,
	count:      int,
	software:   bool, // the cuts have their trees
	uv_density: [MESH_UV_ENTRIES][2]f32,
	allocator:  mem.Allocator,
}

mesh_rays_destroy :: proc(rays: ^Mesh_Rays) {
	for cut in rays.cuts[:rays.count] {
		delete(cut.primitives, rays.allocator)
		delete(cut.nodes, rays.allocator)
		delete(cut.triangles, rays.allocator)
	}
	rays^ = {}
}

// What a job makes of a mesh ahead of mesh_add_geometry (mesh_ahead_make),
// so that the frame that registers it walks none of its geometry: its cuts,
// the check of its geometry with its slots, what the record derives from its
// clusters and vertices, and the stream of a mesh whose pages stream.
Mesh_Ahead :: struct {
	rays:      Mesh_Rays,
	stream:    ^Mesh_Stream, // the renderer takes it, and leaves nil
	slots:     int,          // the slots it was checked with; 0: not checked, nor are slab_axes and lod_reach its own
	slab_axes: u32,
	lod_reach: f32,
}

// The cuts of a mesh (mesh_rays_build), in allocator, and the rest of what
// registering it with slots slots derives from its geometry, with the stream
// of its pages in keep, where it lives until the mesh goes: one any thread
// frees in. Any thread. False without memory or for geometry that does not
// hold together, with what it made kept: the renderer makes the rest or
// refuses it.
mesh_ahead_make :: proc(g: asset.Mesh_Geometry, slots: int, software: bool, keep: mem.Allocator, allocator := context.allocator) -> (ahead: Mesh_Ahead, ok: bool) {
	ahead.rays = mesh_rays_build(g, software, allocator) or_return
	if slots < 1 || !mesh_geometry_check(g, slots) {return}
	if len(g.page_data) > 0 && g.root_page > 0 {
		if ahead.stream = mesh_stream_build(g, &ahead.rays, keep); ahead.stream == nil {return}
	}
	ahead.slots, ahead.slab_axes, ahead.lod_reach = slots, mesh_slab_axes(g, g.bounds_min, g.bounds_max), lod_reach(g)
	return ahead, true
}

mesh_ahead_destroy :: proc(ahead: ^Mesh_Ahead) {
	mesh_rays_destroy(&ahead.rays)
	mesh_stream_free(ahead.stream)
	ahead^ = {}
}

// Whether the geometry of a mesh holds together as the renderer reads it,
// with slots slots: its skin and morphs come apart (skin_create), and the
// rig was checked with the whole mesh. Linear in its size.
@(private)
mesh_geometry_check :: proc(g: asset.Mesh_Geometry, slots: int) -> bool {
	if len(g.clusters) == 0 || len(g.levels) == 0 || slots > asset.MESH_MAX_SLOTS {return false}
	info := asset.Mesh_Info{vertex_count = u32(len(g.vertices)), cluster_count = u32(len(g.clusters)), bounds_min = g.bounds_min, bounds_max = g.bounds_max, flags = g.flags - {.Skinned}, position_step = g.position_step, uv_step = g.uv_step, uv1_step = g.uv1_step, ray_errors = g.ray_errors, root_page = g.root_page}
	for c in g.clusters {info.triangle_count += asset.cluster_triangle_count(c)}
	view := asset.Mesh_View{info = &info, geometry = g}
	view.skin, view.morphs, view.morph_deltas = nil, nil, nil
	ids := make([]asset.Material_Slot, slots, context.temp_allocator)
	for &slot, at in ids {slot.id = u32(at)}
	view.slots = ids
	return asset.mesh_check(view) && asset.mesh_check_indices(view)
}

// The clusters a cut at error takes: their own error is within it and that of
// what replaces them is not.
cut_takes :: #force_inline proc "contextless" (c: asset.Cluster, error: f32) -> bool {
	return c.error <= error && c.parent_error > error
}

// Whether cut k of a mesh at error holds a cluster: cut 0 is level 0, the
// others take what the cut at their error takes.
@(private = "file")
cut_holds :: proc "contextless" (g: asset.Mesh_Geometry, ordinal, k: int, error: f32) -> bool {
	if k == 0 {return ordinal < int(g.levels[0].cluster_count)}
	return cut_takes(g.clusters[ordinal], error)
}

// The cuts of a mesh rays trace: level 0, and the coarser ones its file
// names (Mesh_Info.ray_errors), with their software trees when software is
// set. Any thread; what it returns is in allocator. False without memory.
mesh_rays_build :: proc(g: asset.Mesh_Geometry, software: bool, allocator := context.allocator) -> (rays: Mesh_Rays, ok: bool) {
	rays.allocator, rays.software = allocator, software
	errors: [asset.MESH_RAY_LEVELS]f32
	count := 1
	for e in g.ray_errors {
		if e <= 0 {break}
		errors[count] = e
		count += 1
	}
	defer if !ok {mesh_rays_destroy(&rays)}
	for e, k in errors[:count] {
		cut := &rays.cuts[k]
		cut.error = e
		rays.count = k + 1
		triangles := 0
		for c, ordinal in g.clusters {if cut_holds(g, ordinal, k, e) {triangles += int(asset.cluster_triangle_count(c))}}
		error: mem.Allocator_Error
		cut.primitives, error = make([]u32, triangles, allocator)
		if error != nil {return}
		at := 0
		for c, ordinal in g.clusters {
			if !cut_holds(g, ordinal, k, e) {continue}
			for t in 0 ..< asset.cluster_triangle_count(c) {
				cut.primitives[at] = u32(ordinal) << PRIMITIVE_TRIANGLE_BITS | t
				at += 1
			}
		}
		if software && !cut_tree(g, cut, allocator) {return}
	}
	rays.uv_density = mesh_uv_density(g)
	return rays, true
}

// A primitive a ray meets: its cluster among those of the mesh, then its triangle.
PRIMITIVE_TRIANGLE_BITS :: abi.PRIMITIVE_TRIANGLE_BITS
#assert(1 << PRIMITIVE_TRIANGLE_BITS >= CLUSTER_TRIANGLES)

// The corners of the triangle a primitive names, in the space of the mesh.
primitive_positions :: proc "contextless" (g: asset.Mesh_Geometry, primitive: u32) -> (a, b, c: Vec3) {
	return cluster_triangle_positions(g, g.clusters[primitive >> PRIMITIVE_TRIANGLE_BITS], primitive & (1 << PRIMITIVE_TRIANGLE_BITS - 1))
}

// The corners of a triangle of a cluster, in the space of the mesh.
cluster_triangle_positions :: proc "contextless" (g: asset.Mesh_Geometry, cluster: asset.Cluster, t: u32) -> (a, b, c: Vec3) {
	corners := asset.cluster_triangle(g.triangles, cluster, t)
	return asset.cluster_position(g, cluster, corners[0]), asset.cluster_position(g, cluster, corners[1]), asset.cluster_position(g, cluster, corners[2])
}

// The software tree of a cut over its triangles at rest.
@(private = "file")
cut_tree :: proc(g: asset.Mesh_Geometry, cut: ^Mesh_Ray_Cut, allocator: mem.Allocator) -> bool {
	items, items_error := make([]mm.Aabb, len(cut.primitives), allocator)
	if items_error != nil {return false}
	defer delete(items, allocator)
	for primitive, t in cut.primitives {
		a, b, c := primitive_positions(g, primitive)
		items[t] = {linalg.min(linalg.min(a, b), c), linalg.max(linalg.max(a, b), c)}
	}
	nodes := make([dynamic]Gpu_Bvh_Node, 0, 0, allocator)
	order := make([dynamic]u32, 0, 0, allocator)
	defer delete(order)
	if !bvh_build(items, 4, &nodes, &order) {delete(nodes); return false}
	cut.nodes = nodes[:]
	error: mem.Allocator_Error
	cut.triangles, error = make([]Gpu_Bvh_Triangle, len(order), allocator)
	if error != nil {return false}
	for index, at in order {
		primitive := cut.primitives[index]
		a, b, c := primitive_positions(g, primitive)
		cut.triangles[at] = {v0 = a, primitive = primitive, e1 = {b.x - a.x, b.y - a.y, b.z - a.z, 0}, e2 = {c.x - a.x, c.y - a.y, c.z - a.z, 0}}
	}
	return true
}

// Registers the geometry of a mesh, as asset.mesh_build encoded it or a file
// holds it: it is copied into the pools once; of one with the blocks of its
// pages (a file, or asset.mesh_pages_pack) whose root is not every page, the
// root alone, and the others come and go (pages.odin). given_words is the material word
// of each slot (the row of the material table, and its source slot << 24);
// none is one slot of row 0. ahead: what a job made of it (mesh_ahead_make),
// whose stream it takes; nil, or without cuts, makes it here. A load
// transaction: the GPU takes it with the next frame or
// renderer_commit_geometry. False for geometry that does not hold together
// or more than asset.MESH_MAX_SLOTS slots.
mesh_add_geometry :: proc(r: ^Renderer, g: asset.Mesh_Geometry, given_words: []u32, ahead: ^Mesh_Ahead = nil) -> (Mesh_Handle, bool) {
	return mesh_register(r, g, given_words, ahead, nil)
}

// mesh_add_geometry, or, with later, the blocks of its pages, its clusters
// and the tables and trees of the cuts of ahead are taken in the pools
// without being written: later is the upload that writes them as it sends
// them (Upload_Fill), and reads g and the cuts until then.
@(private)
mesh_register :: proc(r: ^Renderer, g: asset.Mesh_Geometry, given_words: []u32, ahead: ^Mesh_Ahead, later: ^Geometry_Upload) -> (Mesh_Handle, bool) {
	s := &r.scene
	if len(g.clusters) == 0 || len(g.levels) == 0 || len(given_words) > asset.MESH_MAX_SLOTS {return 0, false}
	default_word := [1]u32{0}
	slot_words := given_words if len(given_words) > 0 else default_word[:]
	rays := &ahead.rays if ahead != nil && ahead.rays.count > 0 else nil
	checked := rays != nil && ahead.slots == len(slot_words)
	if !checked && !mesh_geometry_check(g, len(slot_words)) {return 0, false}
	triangles: u32
	for level in g.levels {triangles += level.triangle_count}
	for word in slot_words {
		if !materials_reach(r, word & 0xffffff) {return 0, false}
	}
	made: Mesh_Rays
	given := rays
	if given == nil || !r.hardware_rt && !given.software {
		ok: bool
		if made, ok = mesh_rays_build(g, !r.hardware_rt, r.allocator); !ok {return 0, false}
		given = &made
	}
	defer if given == &made {mesh_rays_destroy(&made)}
	// Without the blocks of its pages there is nothing to stream from.
	streamed := len(g.page_data) > 0 && g.root_page > 0
	stored := g.root_page if streamed else 0
	// The region of the slots comes first: the room of the mesh is past it.
	if streamed {pages_region_ensure(r)}
	if !mesh_room(r, g, stored, len(slot_words), given) {
		s.refused.meshes += 1
		s.refused.triangles += u64(triangles)
		set_error(r, "the GPU has no memory for a mesh of %d triangles (renderer_stats().problem)", triangles)
		return 0, false
	}

	record := Mesh_Record{vertex_count = u32(len(g.vertices)), vertices_posed = u32(len(g.vertices)), position_step = g.position_step, uv_step = g.uv_step, uv1_step = g.uv1_step, bounds_min = g.bounds_min, bounds_max = g.bounds_max}
	record.flags = MESH_FLAG_CLOSED if .Closed in g.flags else 0
	record.flags |= mesh_stream_flags(g.flags)
	if streamed {
		record.flags |= MESH_FLAG_STREAMED
		if ahead != nil && ahead.stream != nil {
			record.stream, ahead.stream = ahead.stream, nil
		} else if record.stream = mesh_stream_build(g, given, r.allocator); record.stream == nil {return 0, false}
		if !mesh_stream_start(r, record.stream) {
			mesh_stream_free(record.stream)
			return 0, false
		}
	}
	record.posed_word, record.previous_word, record.part_word, record.rest_word = GPU_NONE, GPU_NONE, GPU_NONE, GPU_NONE
	record.cluster_count, record.page_count, record.level_count, record.slot_count = u32(len(g.clusters)), u32(len(g.pages)), u32(len(g.levels)), u32(len(slot_words))
	record.triangle_count = g.levels[0].triangle_count
	record.lod_reach = ahead.lod_reach if checked else lod_reach(g)
	record.ray_count = u32(given.count)
	for cut, k in given.cuts[:given.count] {record.rays[k].error = cut.error}
	handle: Mesh_Handle
	// Room first for its record and for its place among the streamed: the mesh is not left without them.
	if len(s.free_meshes) == 0 && !pool_reserve(&s.meshes, 1) || record.stream != nil && !pool_reserve(&s.pages.streamed, 1) {
		mesh_stream_free(record.stream)
		return 0, false
	}
	if later != nil {
		if !mesh_reserve(s, g, stored, slot_words, &record) {
			mesh_stream_free(record.stream)
			return 0, false
		}
		handle = mesh_place(r, record)
	} else {
		// And in the pools for its blocks, its tables and its trees: they are written whole or not at all.
		vertices, indices, nodes, triangles := mesh_pool_counts(g, stored, len(slot_words), given, r.hardware_rt)
		if !pool_reserve(&s.vertices, vertices) || !pool_reserve(&s.indices, indices) || !pool_reserve(&s.blas_nodes, nodes) || !pool_reserve(&s.blas_triangles, triangles) {
			mesh_stream_free(record.stream)
			return 0, false
		}
		vertex_start, index_start := u32(len(s.vertices)), u32(len(s.indices))
		append(&s.indices, ..mem.slice_data_cast([]u32, g.clusters))
		record.page_word = u32(len(s.indices)) - index_start
		if !pages_append(g, &s.vertices, &s.indices, vertex_start, stored) {
			base.truncate(&s.indices, index_start)
			mesh_stream_free(record.stream)
			return 0, false
		}
		record.level_word = u32(len(s.indices)) - index_start
		append(&s.indices, ..mem.slice_data_cast([]u32, g.levels))
		record.slot_word = u32(len(s.indices)) - index_start
		append(&s.indices, ..slot_words)
		record.cluster_word = 0
		record.vertex_word = 0
		handle = mesh_store(r, record, vertex_start, index_start)
	}
	m := &s.meshes[handle]
	if m.stream != nil {
		m.stream.mesh = u32(handle)
		append(&s.pages.streamed, u32(handle))
	}
	m.slab_axes = ahead.slab_axes if checked else mesh_slab_axes(g, m.bounds_min, m.bounds_max)
	m.uv_density = given.uv_density
	// Cuts made here go now: nothing keeps them for the upload.
	deferred := later != nil && given == rays
	if given.software {mesh_rays_publish(r, m, given^, deferred)}
	if r.hardware_rt {mesh_tables_publish(r, m, given^, deferred)}
	if later != nil {
		from := Upload_From{geometry = g, stored = stored, rays = rays if deferred else nil}
		later^ = upload_make(s, handle, nil, &from)
	}
	return handle, true
}

// Takes the blocks of a mesh in the pools for record and writes its page
// table, levels and slots: the blocks of its pages and its clusters are its
// upload's to write. False without memory, with nothing taken.
@(private = "file")
mesh_reserve :: proc(s: ^Scene_State, g: asset.Mesh_Geometry, stored: u32, slot_words: []u32, record: ^Mesh_Record) -> bool {
	vertex_words: u32
	for page in g.pages[stored:] {vertex_words += page_words(g, page)}
	clusters := u32(len(g.clusters)) * CLUSTER_WORDS
	pages := u32(len(g.pages)) * PAGE_ENTRY_WORDS
	levels := u32(len(g.levels)) * LEVEL_WORDS
	index_words := clusters + pages + levels + u32(len(slot_words))
	vertex_word, taken := pool_take(&s.vertices, &s.pool_free[.Vertex], vertex_words)
	if !taken {return false}
	index_word: u32
	if index_word, taken = pool_take(&s.indices, &s.pool_free[.Index], index_words); !taken {
		pool_release(&s.vertices, &s.pool_free[.Vertex], vertex_word, vertex_words)
		return false
	}
	block := s.indices[index_word:][:index_words]
	base := vertex_word
	for page, k in g.pages {
		entry := page_entry(page, GPU_NONE)
		if u32(k) >= stored {
			entry[0] = base
			base += page_words(g, page)
		}
		copy(block[clusters + u32(k) * PAGE_ENTRY_WORDS:], entry[:])
	}
	copy(block[clusters + pages:], mem.slice_data_cast([]u32, g.levels))
	copy(block[clusters + pages + levels:], slot_words)
	record.vertex_word, record.vertex_span = vertex_word, vertex_words
	record.index_word, record.index_span = index_word, index_words
	record.cluster_word, record.page_word = index_word, index_word + clusters
	record.level_word, record.slot_word = index_word + clusters + pages, index_word + clusters + pages + levels
	return true
}

// Room in the pools for the blocks of the pages of a mesh from stored on, its tables and its trees.
@(private = "file")
mesh_room :: proc(r: ^Renderer, g: asset.Mesh_Geometry, stored: u32, slots: int, rays: ^Mesh_Rays) -> bool {
	vertices, indices, nodes, triangles := mesh_pool_counts(g, stored, slots, rays, r.hardware_rt)
	return pool_room(r, .Vertex, vertices) && pool_room(r, .Index, indices) && pool_room(r, .Node, nodes) && pool_room(r, .Triangle, triangles)
}

// What the pools take of a mesh: words of the vertex and index pools, nodes and triangles of the trees.
@(private = "file")
mesh_pool_counts :: proc(g: asset.Mesh_Geometry, stored: u32, slots: int, rays: ^Mesh_Rays, hardware: bool) -> (vertices, indices, nodes, triangles: int) {
	for page in g.pages[stored:] {vertices += int(page_words(g, page))}
	indices = len(g.clusters) * CLUSTER_WORDS + len(g.pages) * PAGE_ENTRY_WORDS + len(g.levels) * LEVEL_WORDS + slots
	if rays == nil {return}
	for cut in rays.cuts[:rays.count] {
		if hardware {indices += len(cut.primitives)}
		if rays.software {nodes += len(cut.nodes); triangles += len(cut.triangles)}
	}
	return
}

// Bytes mesh_add_geometry gives the GPU at once for a mesh with its cuts
// (nil: none), on a renderer that traces rays by hardware or not: the blocks
// of its root pages (of every page when its pages do not stream), its tables
// and what its rays trace. Its other pages come with the frames that show
// them (pages.odin).
mesh_add_bytes :: proc(g: asset.Mesh_Geometry, slots: int, rays: ^Mesh_Rays, hardware: bool) -> int {
	stored := g.root_page if len(g.page_data) > 0 && g.root_page > 0 else 0
	if int(stored) > len(g.pages) {return 0}
	vertices, indices, nodes, triangles := mesh_pool_counts(g, stored, max(slots, 1), rays, hardware)
	return (vertices + indices) * size_of(u32) + nodes * size_of(Gpu_Bvh_Node) + triangles * size_of(Gpu_Bvh_Triangle)
}

// How far a sphere of the levels of a mesh reaches past its box: what the cull
// widens the box of an instance by to bound the distance of any of them.
@(private = "file")
lod_reach :: proc(g: asset.Mesh_Geometry) -> (reach: f32) {
	for c in g.clusters {
		for sphere in ([2][4]f32{c.lod, c.parent}) {
			outside := linalg.length(linalg.max(linalg.max(g.bounds_min - sphere.xyz, sphere.xyz - g.bounds_max), 0))
			reach = max(reach, outside + sphere.w)
		}
	}
	return
}

// The trees of the cuts of a mesh into the pools of the software BVH; taken
// alone, for its upload to write (mesh_register).
@(private)
mesh_rays_publish :: proc(r: ^Renderer, m: ^Mesh_Record, rays: Mesh_Rays, taken := false) -> bool {
	s := &r.scene
	for k in 0 ..< rays.count {
		cut := rays.cuts[k]
		ray := &m.rays[k]
		if ray.bvh_node_count > 0 || len(cut.nodes) == 0 {continue}
		if !pool_room(r, .Node, len(cut.nodes)) || !pool_room(r, .Triangle, len(cut.triangles)) {return false}
		nodes, triangles := u32(len(cut.nodes)), u32(len(cut.triangles))
		if taken {
			first_node, first_triangle: u32
			ok: bool
			if first_node, ok = pool_take(&s.blas_nodes, &s.pool_free[.Node], nodes); !ok {return false}
			if first_triangle, ok = pool_take(&s.blas_triangles, &s.pool_free[.Triangle], triangles); !ok {
				pool_release(&s.blas_nodes, &s.pool_free[.Node], first_node, nodes)
				return false
			}
			ray.bvh_root, ray.triangle_offset = first_node, first_triangle
		} else {
			first_node, first_triangle := u32(len(s.blas_nodes)), u32(len(s.blas_triangles))
			append(&s.blas_nodes, ..cut.nodes)
			append(&s.blas_triangles, ..cut.triangles)
			ray.bvh_root = pool_store(&s.blas_nodes, &s.pool_free[.Node], &s.pool_dirty[.Node], first_node)
			ray.triangle_offset = pool_store(&s.blas_triangles, &s.pool_free[.Triangle], &s.pool_dirty[.Triangle], first_triangle)
		}
		ray.bvh_node_count, ray.triangle_count = nodes, triangles
	}
	s.geometry_dirty = true
	return true
}

// The tables of the triangles of the cuts of a mesh, which name where each
// primitive of their native BLAS comes from; taken alone, for its upload to
// write (mesh_register).
@(private)
mesh_tables_publish :: proc(r: ^Renderer, m: ^Mesh_Record, rays: Mesh_Rays, taken := false) -> bool {
	s := &r.scene
	for k in 0 ..< rays.count {
		cut := rays.cuts[k]
		ray := &m.rays[k]
		if ray.table_count > 0 || len(cut.primitives) == 0 {continue}
		if !pool_room(r, .Index, len(cut.primitives)) {return false}
		count := u32(len(cut.primitives))
		if taken {
			first, ok := pool_take(&s.indices, &s.pool_free[.Index], count)
			if !ok {return false}
			ray.table_word = first
		} else {
			first := u32(len(s.indices))
			append(&s.indices, ..cut.primitives)
			ray.table_word = pool_store(&s.indices, &s.pool_free[.Index], &s.pool_dirty[.Index], first)
		}
		ray.table_count = count
	}
	s.geometry_dirty = true
	return true
}

// The cuts of a mesh registered while rays were traced the other way: its
// trees by software, or its tables by hardware, from the pools.
@(private)
mesh_rays_complete :: proc(r: ^Renderer, handle: u32) -> bool {
	s := &r.scene
	m := &s.meshes[handle]
	if m.vertex_count == 0 {return true}
	software := !r.hardware_rt
	if software && m.rays[0].bvh_node_count > 0 || !software && m.rays[0].table_count > 0 {return true}
	mesh_filled(s, handle)
	g, decoded := record_decode(s, m^, r.allocator)
	if !decoded {return false}
	defer geometry_decoded_free(&g, r.allocator)
	for ray, k in m.rays[1:m.ray_count] {g.ray_errors[k] = ray.error}
	rays, ok := mesh_rays_build(g, software, r.allocator)
	if !ok {return false}
	defer mesh_rays_destroy(&rays)
	if software {
		if !mesh_rays_publish(r, m, rays) {return false}
		if m.skin != nil {
			if !pose_tree_breadth_first(r, m) {return false}
		}
	} else if !mesh_tables_publish(r, m, rays) {return false}
	range_add(&s.mesh_dirty, {handle, 1})
	return true
}

// The row of the mesh table of a record.
@(private)
gpu_mesh :: proc(m: Mesh_Record) -> Gpu_Mesh {
	row := Gpu_Mesh{
		cluster_word = m.cluster_word, cluster_count = m.cluster_count, level_word = m.level_word, level_count = m.level_count,
		page_word = m.page_word, page_count = m.page_count, vertex_count = m.vertex_count, slot_word = m.slot_word,
		posed_word = m.posed_word, previous_word = m.previous_word,
		part_word = m.part_word, part_layers = m.skin.part_layers if m.skin != nil else 0, flags = m.flags, slab_axes = m.slab_axes,
		position_step = m.position_step, uv_step = m.uv_step, uv1_step = m.uv1_step, lod_reach = m.lod_reach,
		bounds_min = {m.bounds_min.x, m.bounds_min.y, m.bounds_min.z, 0}, bounds_max = {m.bounds_max.x, m.bounds_max.y, m.bounds_max.z, 0},
	}
	for ray, k in m.rays {row.rays[k] = {ray.bvh_root, ray.triangle_offset, ray.table_word, ray.error}}
	// A mesh traces level 0 where it has no coarser cut.
	for k in m.ray_count ..< asset.MESH_RAY_LEVELS {row.rays[k] = row.rays[0]}
	return row
}

// Gives a mesh its blocks of the pools, appended from vertex_start and
// index_start with every word of the record and the base of every page
// relative to them, and its handle: the slot a removed mesh left, or a new one.
@(private)
mesh_store :: proc(r: ^Renderer, record: Mesh_Record, vertex_start, index_start: u32) -> Mesh_Handle {
	s := &r.scene
	record := record
	record.vertex_span = u32(len(s.vertices)) - vertex_start
	record.index_span = u32(len(s.indices)) - index_start
	record.vertex_word = pool_store(&s.vertices, &s.pool_free[.Vertex], &s.pool_dirty[.Vertex], vertex_start)
	record.index_word = pool_store(&s.indices, &s.pool_free[.Index], &s.pool_dirty[.Index], index_start)
	for word in ([]^u32{&record.posed_word, &record.previous_word, &record.part_word, &record.rest_word}) {
		if word^ != GPU_NONE {word^ += record.vertex_word}
	}
	for word in ([]^u32{&record.cluster_word, &record.page_word, &record.level_word, &record.slot_word}) {word^ += record.index_word}
	for &page in mem.slice_data_cast([]Gpu_Mesh_Page, s.indices[record.page_word:][:record.page_count * PAGE_ENTRY_WORDS]) {
		if page.base != GPU_NONE {page.base += record.vertex_word}
	}
	return mesh_place(r, record)
}

// Gives a mesh whose blocks are in place its handle: the slot a removed mesh
// left, or a new one.
@(private)
mesh_place :: proc(r: ^Renderer, record: Mesh_Record) -> Mesh_Handle {
	s := &r.scene
	record := record
	record.first_instance = -1
	// No instance shows it yet: those that come mark the light around them.
	s.geometry_dirty = true
	s.triangle_total += u64(record.triangle_count)
	if len(s.free_meshes) > 0 {
		at := pop(&s.free_meshes)
		s.meshes[at] = record
		range_add(&s.mesh_dirty, {at, 1})
		return Mesh_Handle(at)
	}
	append(&s.meshes, record)
	range_add(&s.mesh_dirty, {u32(len(s.meshes) - 1), 1})
	return Mesh_Handle(len(s.meshes) - 1)
}

// Bit per object axis across which every vertex of level 0 lies on one of
// the two faces of the box: across it the mesh is a slab between two
// parallel planes.
mesh_slab_axes :: proc(g: asset.Mesh_Geometry, bounds_min, bounds_max: Vec3) -> u32 {
	size := bounds_max - bounds_min
	tolerance := 1e-4 * max(size.x, size.y, size.z)
	axes := u32(0b111)
	level0 := g.clusters[:g.levels[0].cluster_count] if len(g.levels) > 0 else g.clusters
	for c in level0 {
		for local in 0 ..< asset.cluster_vertex_count(c) {
			p := asset.cluster_position(g, c, local)
			for a in 0 ..< 3 {
				if min(p[a] - bounds_min[a], bounds_max[a] - p[a]) > tolerance {axes &~= 1 << u32(a)}
			}
			if axes == 0 {return 0}
		}
	}
	return axes
}

// The triangles of the cuts of a mesh blas_inputs_add would take now.
@(private)
blas_inputs_cost :: proc(r: ^Renderer, m: ^Mesh_Record) -> (triangles: int) {
	for ray, k in m.rays[:m.ray_count] {
		if ray.blas != 0 || ray.table_count == 0 || ray.input_indices > 0 || !ray_cut_wanted(r, m^, k) {continue}
		triangles += int(ray.table_count)
	}
	return
}

// The positions and indices of each cut of a mesh that lacks its native BLAS,
// in the pools for the build: decoded from the clusters at rest, or the posed
// vertices of a pose, whose indices stay while it is refit. The inputs of a
// mesh at rest go back to the pools at the next publication, once the GPU
// took them. The clusters and the tables it reads are in the pools it grows:
// it makes room for all it adds before it reads them, so that no append moves
// them. later: their room is taken without being written, for the uploads of
// the frames to decode them as they go (blas_inputs_queue). The words it
// added; false without memory, with nothing taken.
@(private)
blas_inputs_add :: proc(r: ^Renderer, m: ^Mesh_Record, later := false) -> (words: int, ok: bool) {
	s := &r.scene
	posed := m.posed_word != GPU_NONE
	vertices, indices := 0, 0
	for ray, k in m.rays[:m.ray_count] {
		if ray.blas != 0 || ray.table_count == 0 || ray.input_indices > 0 || !ray_cut_wanted(r, m^, k) {continue}
		if !posed {vertices += int(ray.table_count) * 9}
		indices += int(ray.table_count) * 3
	}
	if !pool_room(r, .Vertex, vertices) || !pool_room(r, .Index, indices) {return 0, false}
	if reserve(&s.vertices, len(s.vertices) + vertices) != nil || reserve(&s.indices, len(s.indices) + indices) != nil {return 0, false}
	p := record_pooled(s, m^)
	for &ray, k in m.rays[:m.ray_count] {
		if ray.blas != 0 || ray.table_count == 0 || ray.input_indices > 0 || !ray_cut_wanted(r, m^, k) {continue}
		if later {
			// What was reserved holds them: neither take fails.
			if !posed {ray.input_vertex, _ = pool_take(&s.vertices, &s.pool_free[.Vertex], ray.table_count * 9);ray.input_vertices = ray.table_count * 9}
			ray.input_index, _ = pool_take(&s.indices, &s.pool_free[.Index], ray.table_count * 3)
			ray.input_indices = ray.table_count * 3
			continue
		}
		primitives := s.indices[ray.table_word:][:ray.table_count]
		if !posed {
			first := len(s.vertices)
			if resize(&s.vertices, first + len(primitives) * 9) != nil {return 0, false}
			for primitive, t in primitives {blas_input_positions(p, primitive, s.vertices[first + t * 9:][:9])}
			ray.input_vertices = u32(len(s.vertices) - first)
			ray.input_vertex = pool_store(&s.vertices, &s.pool_free[.Vertex], &s.pool_dirty[.Vertex], u32(first))
		}
		first := len(s.indices)
		if resize(&s.indices, first + len(primitives) * 3) != nil {return 0, false}
		for primitive, t in primitives {blas_input_indices(p, primitive, u32(t), posed, s.indices[first + t * 3:][:3])}
		ray.input_indices = u32(len(s.indices) - first)
		ray.input_index = pool_store(&s.indices, &s.pool_free[.Index], &s.pool_dirty[.Index], u32(first))
	}
	return vertices + indices, true
}

// The corners of a primitive as the inputs of a native BLAS hold them: nine floats.
@(private)
blas_input_positions :: proc(p: Pooled_Mesh, primitive: u32, out: []u32) {
	a, b, c := pooled_primitive_positions(p, primitive)
	for corner, k in ([3]Vec3{a, b, c}) {out[k * 3], out[k * 3 + 1], out[k * 3 + 2] = transmute(u32)corner.x, transmute(u32)corner.y, transmute(u32)corner.z}
}

// The indices of primitive, the t-th of its cut, as the inputs of a native
// BLAS hold them: of the posed vertices of its mesh, or of its own positions.
@(private)
blas_input_indices :: proc(p: Pooled_Mesh, primitive, t: u32, posed: bool, out: []u32) {
	if !posed {
		out[0], out[1], out[2] = t * 3, t * 3 + 1, t * 3 + 2
		return
	}
	first_vertex := p.clusters[primitive >> PRIMITIVE_TRIANGLE_BITS].vertex_first
	g, cluster, _ := pooled_cluster(p, primitive >> PRIMITIVE_TRIANGLE_BITS)
	corners := asset.cluster_triangle(g.triangles, cluster, primitive & (1 << PRIMITIVE_TRIANGLE_BITS - 1))
	out[0], out[1], out[2] = first_vertex + corners[0], first_vertex + corners[1], first_vertex + corners[2]
}

// The inputs of the BLAS of meshes at rest built by the publication before.
@(private)
blas_inputs_release :: proc(r: ^Renderer) {
	s := &r.scene
	for &m in s.meshes {
		if m.posed_word != GPU_NONE {continue}
		for &ray in m.rays[:m.ray_count] {
			if ray.blas == 0 || ray.input_indices == 0 {continue}
			if ray.input_vertices > 0 {pool_release(&s.vertices, &s.pool_free[.Vertex], ray.input_vertex, ray.input_vertices)}
			pool_release(&s.indices, &s.pool_free[.Index], ray.input_index, ray.input_indices)
			ray.input_vertex, ray.input_vertices, ray.input_index, ray.input_indices = 0, 0, 0, 0
		}
	}
}

// The native BLAS of a cut whose inputs are in the pools.
@(private)
blas_desc :: proc(r: ^Renderer, m: Mesh_Record, ray: Mesh_Ray_Record) -> rhi.Blas_Desc {
	s := &r.scene
	posed := m.posed_word != GPU_NONE
	desc := rhi.Blas_Desc{
		vertex_buffer = s.vertex_buffer, index_buffer = s.index_buffer, index_offset = u64(ray.input_index) * 4,
		triangle_count = ray.input_indices / 3, name = "mesh blas", deformable = posed, compact = !posed,
	}
	if posed {
		desc.vertex_offset, desc.vertex_stride, desc.vertex_count = u64(m.posed_word) * 4, size_of(Gpu_Posed_Vertex), m.vertices_posed
	} else {
		desc.vertex_offset, desc.vertex_stride, desc.vertex_count = u64(ray.input_vertex) * 4, size_of(Vec3), ray.input_vertices / 3
	}
	return desc
}

// The vertices and indices of a mesh, every triangle of the slot of its first
// vertex, as asset.mesh_build encodes them: the vertices that name the same
// row and source slot share a slot.
@(private)
mesh_vertices_source :: proc(vertices: []Mesh_Vertex, out: []asset.Vertex, slot_words: ^[dynamic]u32) -> bool {
	for v, at in vertices {
		word := u32(v.material) | v.slot << 24
		slot := -1
		for known, k in slot_words {if known == word {slot = k}}
		if slot < 0 {
			if len(slot_words) == asset.MESH_MAX_SLOTS {return false}
			append(slot_words, word)
			slot = len(slot_words) - 1
		}
		out[at] = {
			position = v.position, normal = packed_normal(v.normal), uv = v.uv, uv1 = v.uv1, material = u32(slot),
			color = packed_color(v.color), tangent = packed_tangent(v.tangent),
		}
	}
	return true
}

@(private = "file")
packed_normal :: #force_inline proc "contextless" (n: Vec3) -> u32 {return mm.normal_pack(n)}
@(private = "file")
packed_color :: #force_inline proc "contextless" (c: Vec3) -> u32 {return mm.rgba8_pack({c.x, c.y, c.z, 1})}
@(private = "file")
packed_tangent :: #force_inline proc "contextless" (t: Vec4) -> u32 {return mm.tangent_pack(t.xyz, t.w)}

// Registers a mesh given as vertices and indices: the constructor of asset
// (asset.mesh_build) encodes it, in its one level, and mesh_add_geometry
// takes it. The vertices that name the same material and source slot make a
// slot. Scratch from the temporary allocator.
mesh_add :: proc(r: ^Renderer, vertices: []Mesh_Vertex, indices: []u32) -> (Mesh_Handle, bool) {
	if len(vertices) == 0 || len(indices) < 3 || len(indices) % 3 != 0 {return 0, false}
	for index in indices {if int(index) >= len(vertices) {return 0, false}}
	for v in vertices {if v.slot > 32 || u32(v.material) > 0xffffff {return 0, false}}
	source := make([]asset.Vertex, len(vertices), context.temp_allocator)
	slot_words := make([dynamic]u32, 0, asset.MESH_MAX_SLOTS, context.temp_allocator)
	if source == nil || !mesh_vertices_source(vertices, source, &slot_words) {return 0, false}
	flags: asset.Mesh_Flags
	for v in vertices {
		if v.color != {1, 1, 1} {flags += {.Has_Colors}}
		if v.uv1 != v.uv {flags += {.Has_Uv1}}
	}
	g: asset.Mesh_Geometry
	if !asset.mesh_build({vertices = source, flags = flags}, indices, nil, &g, context.temp_allocator) {return 0, false}
	return mesh_add_geometry(r, g, slot_words[:])
}
