package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:asset"
import mm "mirai:std/math"
import "mirai:std/compressor"

// A bumpy sheet of side cells as a file holds it: a DAG with pages out of
// its root and the LZ block of each page in page_data.
@(private)
streamed_sheet :: proc(side: int) -> (g: asset.Mesh_Geometry, ok: bool) {
	vertices := make([dynamic]asset.Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for z in 0 ..= side {
		for x in 0 ..= side {
			y := 0.3 * math.sin(f32(x) * 0.4) * math.cos(f32(z) * 0.3)
			uv := [2]f32{f32(x), f32(z)} / f32(side)
			append(&vertices, asset.Vertex{position = {f32(x), y, f32(z)}, normal = mm.normal_pack({0, 1, 0}), uv = uv, uv1 = uv.yx * 2, color = mm.rgba8_pack({uv.x, uv.y, 0.5, 1}), tangent = mm.tangent_pack({1, 0, 0}, 1)})
		}
	}
	row := u32(side + 1)
	for z in 0 ..< u32(side) {
		for x in 0 ..< u32(side) {
			a := z * row + x
			append(&indices, a, a + row, a + 1, a + 1, a + row, a + row + 1)
		}
	}
	if !asset.mesh_build_dag({vertices = vertices[:], flags = {.Has_Colors, .Has_Uv1}}, indices[:], &g, context.temp_allocator) {return}
	if !asset.mesh_pages_pack(&g, context.temp_allocator) {return}
	return g, g.root_page > 0
}

// A renderer without a device whose region has room for slots pages.
@(private = "file")
streamed_renderer :: proc(r: ^Renderer, slots: int) {
	r.allocator = context.allocator
	r.settings = DEFAULT_SETTINGS
	r.settings.page_pool_bytes = u64(slots) * PAGE_SLOT_WORDS * 4
	scene_init(r)
}

// The pages out of the root whose parents are all in parents_from on: with
// parents_from the root, those the root alone lets load.
@(private = "file")
pages_under :: proc(stream: ^Mesh_Stream, inside: proc(stream: ^Mesh_Stream, page: u32) -> bool) -> [dynamic]u32 {
	found := make([dynamic]u32, context.temp_allocator)
	for page in 0 ..< stream.root {
		parents := page_parents(stream, page)
		if len(parents) == 0 {continue}
		all := true
		for parent in parents {all &&= inside(stream, parent)}
		if all {append(&found, page)}
	}
	return found
}

@(private = "file")
in_root :: proc(stream: ^Mesh_Stream, page: u32) -> bool {return page >= stream.root}

// Whether the decoded whole of a mesh, its pages out of the pools read from
// their compressed blocks, is the geometry it was given.
@(private = "file")
decodes_as_given :: proc(t: ^testing.T, r: ^Renderer, handle: Mesh_Handle, g: asset.Mesh_Geometry) -> bool {
	decoded, ok := record_decode(&r.scene, r.scene.meshes[handle], context.temp_allocator)
	if !testing.expect(t, ok, "the mesh decodes whole") {return false}
	same :: proc(a, b: []$T) -> bool {return len(a) == len(b) && mem.compare(mem.slice_to_bytes(a), mem.slice_to_bytes(b)) == 0}
	return testing.expect(t, same(decoded.clusters, g.clusters) && same(decoded.vertices, g.vertices) && same(decoded.uv1s, g.uv1s) &&
		same(decoded.colors, g.colors) && same(decoded.triangles, g.triangles), "decoded whole, the mesh has the arrays it was given")
}

// A mesh of a file keeps its root in its block and its other pages out of
// the pools, and reads whole all the same; a page that loads takes a slot,
// whose copy is its decoded block, and the mesh that goes frees its slots.
@(test)
a_streamed_mesh_keeps_its_root_and_loads_its_other_pages_into_slots :: proc(t: ^testing.T) {
	g, built := streamed_sheet(160)
	if !testing.expect(t, built, "the sheet has pages out of its root") {return}
	r:=new(Renderer);defer free(r)
	streamed_renderer(r, 8)
	defer scene_destroy(r)
	handle, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	s := &r.scene
	m := s.meshes[handle]
	stream := m.stream
	if !testing.expect(t, stream != nil && m.flags & MESH_FLAG_STREAMED != 0, "the mesh streams") {return}
	testing.expect_value(t, s.pages.slot_count, 8)
	stored: u32
	for page, k in record_pooled(s, m).pages {
		testing.expectf(t, (page.base == GPU_NONE) == (u32(k) < g.root_page), "page %d is in the pools only in the root", k)
		if u32(k) >= g.root_page {stored += g.pages[k].words}
	}
	testing.expect_value(t, m.vertex_span, stored)
	decodes_as_given(t, r, handle, g)

	frontier := pages_under(stream, in_root)
	if !testing.expect(t, len(frontier) > 0, "some page has its parents in the root") {return}
	page := frontier[0]
	requests := []Page_Request{{mesh = u32(handle), page = page, priority = 2}}
	testing.expect_value(t, pages_load(r, requests), 1)
	slot := stream.slots[page]
	if !testing.expect(t, slot != PAGE_SLOT_NONE) {return}
	m = s.meshes[handle]
	base := record_pooled(s, m).pages[page].base
	testing.expect_value(t, base, s.pages.region + slot * PAGE_SLOT_WORDS)
	block := make([]u32, asset.MESH_PAGE_WORDS, context.temp_allocator)
	scratch := make([]u8, asset.MESH_PAGE_SCRATCH_BYTES, context.temp_allocator)
	decoder: compressor.Decoder
	testing.expect_value(t, compressor.decoder_init(&decoder), compressor.Error.None)
	defer compressor.decoder_destroy(&decoder)
	testing.expect(t, asset.mesh_page_decode(g.flags, g.pages[page], g.page_data, scratch, block, &decoder))
	words := g.pages[page].words
	testing.expect(t, mem.compare(mem.slice_to_bytes(s.vertices[base:][:words]), mem.slice_to_bytes(block[:words])) == 0, "the copy of the slot is the decoded block of its page")
	for parent in page_parents(stream, page) {testing.expect_value(t, stream.children[parent], 1)}
	decodes_as_given(t, r, handle, g)

	testing.expect(t, mesh_remove(r, handle))
	testing.expect_value(t, len(s.pages.free), 8)
	testing.expect_value(t, len(s.pages.streamed), 0)
	for held in s.pages.slots {testing.expect_value(t, held.mesh, GPU_NONE)}
}

// The far mesh of a section, made in memory (asset.mesh_build_far), streams
// as a mesh of a file: its root in its block, its other pages into slots
// from the blocks it carries, and its coarsest ray cut of the root alone.
@(test)
a_far_mesh_made_in_memory_streams_as_a_mesh_of_a_file :: proc(t: ^testing.T) {
	sheet, built := streamed_sheet(96)
	if !testing.expect(t, built) {return}
	parts := [2]asset.Far_Part{{geometry = sheet, placement = Mat4(1)}, {geometry = sheet, placement = linalg.matrix4_translate_f32({200, 0, 0})}}
	for &part in parts {part.materials[0] = {base_color = {0.5, 0.5, 0.5, 1}, roughness = 0.5}}
	g: asset.Mesh_Geometry
	if !testing.expect(t, asset.mesh_build_far(parts[:], 0, &g, context.temp_allocator)) {return}
	if !testing.expect(t, g.root_page > 0 && len(g.page_data) > 0, "the far mesh has pages out of its root and their blocks") {return}
	r := new(Renderer);defer free(r)
	streamed_renderer(r, 8)
	defer scene_destroy(r)
	handle, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	s := &r.scene
	m := s.meshes[handle]
	stream := m.stream
	if !testing.expect(t, stream != nil && m.flags & MESH_FLAG_STREAMED != 0 && m.flags & MESH_FLAG_SURFACE != 0, "the far mesh streams") {return}
	stored: u32
	for page, k in record_pooled(s, m).pages {
		testing.expectf(t, (page.base == GPU_NONE) == (u32(k) < g.root_page), "page %d is in the pools only in the root", k)
		if u32(k) >= g.root_page {stored += g.pages[k].words}
	}
	testing.expect_value(t, m.vertex_span, stored)
	testing.expect(t, m.ray_count > 1 && stream.cut_missing[ray_cut_always(m)] == 0, "rays always trace its coarsest cut, of the root")
	decodes_as_given(t, r, handle, g)
	decoded, _ := record_decode(&r.scene, m, context.temp_allocator)
	testing.expect(t, mem.compare(mem.slice_to_bytes(decoded.surfaces), mem.slice_to_bytes(g.surfaces)) == 0 && len(decoded.surfaces) == len(g.surfaces), "and its surfaces")

	frontier := pages_under(stream, in_root)
	if !testing.expect(t, len(frontier) > 0) {return}
	page := frontier[0]
	testing.expect_value(t, pages_load(r, []Page_Request{{mesh = u32(handle), page = page, priority = 2}}), 1)
	slot := stream.slots[page]
	if !testing.expect(t, slot != PAGE_SLOT_NONE) {return}
	base := record_pooled(s, s.meshes[handle]).pages[page].base
	block := make([]u32, asset.MESH_PAGE_WORDS, context.temp_allocator)
	scratch := make([]u8, asset.MESH_PAGE_SCRATCH_BYTES, context.temp_allocator)
	decoder: compressor.Decoder
	testing.expect_value(t, compressor.decoder_init(&decoder), compressor.Error.None)
	defer compressor.decoder_destroy(&decoder)
	testing.expect(t, asset.mesh_page_decode(g.flags, g.pages[page], g.page_data, scratch, block, &decoder))
	words := g.pages[page].words
	testing.expect(t, mem.compare(mem.slice_to_bytes(s.vertices[base:][:words]), mem.slice_to_bytes(block[:words])) == 0, "the copy of the slot is the decoded block of its page")
	testing.expect(t, mesh_remove(r, handle))
	testing.expect_value(t, len(s.pages.free), 8)
}

// Requests load once each, the most wanted first, and the slot a page takes
// is a free one, else that of the page drawn least recently, never one drawn
// within PAGE_KEEP frames, one with children in the pools or a parent of the
// page that asks.
@(test)
pages_load_the_most_wanted_once_into_free_then_least_recent_slots :: proc(t: ^testing.T) {
	g, built := streamed_sheet(160)
	if !testing.expect(t, built) {return}
	r:=new(Renderer);defer free(r)
	streamed_renderer(r, 2)
	defer scene_destroy(r)
	h1, added1 := mesh_add_geometry(r, g, {0})
	h2, added2 := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added1 && added2) {return}
	s := &r.scene
	s1, s2 := s.meshes[h1].stream, s.meshes[h2].stream
	m1, m2 := u32(h1), u32(h2)
	// A page whose parents are in the root, a page whose one parent is that
	// one, and one whose one parent is that other.
	a := pages_under(s1, in_root)[0]
	b, c := PAGE_SLOT_NONE, PAGE_SLOT_NONE
	for page in 0 ..< s1.root {
		parents := page_parents(s1, page)
		if len(parents) == 1 && parents[0] == a {b = page}
	}
	if !testing.expect(t, b != PAGE_SLOT_NONE, "a page has the first one as its parent") {return}
	for page in 0 ..< s1.root {
		parents := page_parents(s1, page)
		if len(parents) == 1 && parents[0] == b {c = page}
	}
	if !testing.expect(t, c != PAGE_SLOT_NONE, "a page has the second one as its parent") {return}
	resident :: proc(r: ^Renderer, mesh, page: u32) -> bool {return page_resident(r.scene.meshes[mesh].stream, page)}
	stamp :: proc(r: ^Renderer, mesh, page: u32, frame: u64) {r.scene.pages.slots[r.scene.meshes[mesh].stream.slots[page]].stamp = frame}

	// Duplicates count once, what is no page out of the pools not at all, and
	// one whose parents are not there waits.
	r.frame = 100
	requests := []Page_Request{{m1, a, 1, 0}, {m1, a, 9, 0}, {m1, s1.root, 50, 0}, {m2 + 7, a, 50, 0}, {m1, c, 50, 0}, {m2, a, 5, 0}}
	testing.expect_value(t, pages_load(r, requests), 2)
	testing.expect_value(t, s.pages.requested, 3)
	testing.expect(t, resident(r, m1, a) && resident(r, m2, a) && !resident(r, m1, c), "the two free slots take the pages whose parents are there")
	testing.expect_value(t, len(s.pages.free), 0)

	// Pages drawn within PAGE_KEEP frames keep their slots.
	s.pages.dropped = 0
	testing.expect_value(t, pages_load(r, []Page_Request{{m2, b, 1, 0}}), 0)
	testing.expect(t, s.pages.dropped > 0, "the page found no slot")

	// Past them, the least recently drawn gives its slot up.
	r.frame += 10 * PAGE_KEEP
	stamp(r, m1, a, 10);stamp(r, m2, a, 20)
	testing.expect_value(t, pages_load(r, []Page_Request{{m2, b, 1, 0}}), 1)
	testing.expect(t, !resident(r, m1, a) && resident(r, m2, a) && resident(r, m2, b), "the page of the first mesh, drawn first, left")
	testing.expect_value(t, record_pooled(s, s.meshes[h1]).pages[a].base, GPU_NONE)
	testing.expect_value(t, s2.children[a], 1)

	// A page with children in the pools keeps its slot.
	r.frame += 10 * PAGE_KEEP
	stamp(r, m2, a, 10);stamp(r, m2, b, 20)
	testing.expect_value(t, pages_load(r, []Page_Request{{m1, a, 1, 0}}), 1)
	testing.expect(t, resident(r, m2, a) && !resident(r, m2, b) && resident(r, m1, a), "the child left, not its parent")
	testing.expect_value(t, s2.children[a], 0)
	testing.expect_value(t, record_pooled(s, s.meshes[h2]).pages[b].base, GPU_NONE)

	// The parent of the page that asks keeps its slot.
	r.frame += 10 * PAGE_KEEP
	stamp(r, m2, a, 10);stamp(r, m1, a, 20)
	testing.expect_value(t, pages_load(r, []Page_Request{{m2, b, 1, 0}}), 1)
	testing.expect(t, resident(r, m2, a) && resident(r, m2, b) && !resident(r, m1, a), "the parent stayed")
	_ = c
}

// Of the pages a frame wants, the decoded words it loads stay within
// PAGE_LOAD_WORDS once a page loaded.
@(test)
a_frame_loads_pages_up_to_its_budget_of_words :: proc(t: ^testing.T) {
	g, built := streamed_sheet(220)
	if !testing.expect(t, built) {return}
	r:=new(Renderer);defer free(r)
	streamed_renderer(r, 64)
	defer scene_destroy(r)
	handle, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	stream := r.scene.meshes[handle].stream
	// Every page out of the root, the coarsest most wanted: a page loads after its parents in the same frame.
	requests := make([]Page_Request, stream.root, context.temp_allocator)
	total := 0
	for page in 0 ..< stream.root {
		requests[page] = {mesh = u32(handle), page = page, priority = f32(page)}
		total += int(stream.pages[page].words)
	}
	if !testing.expectf(t, total > PAGE_LOAD_WORDS, "the pages out of the root (%d words) pass the budget", total) {return}
	loaded := pages_load(r, requests)
	words := 0
	for page in 0 ..< stream.root {if stream.slots[page] != PAGE_SLOT_NONE {words += int(stream.pages[page].words)}}
	testing.expectf(t, loaded > 1 && words <= PAGE_LOAD_WORDS, "%d pages of %d words load in a frame", loaded, words)
	testing.expect(t, int(r.scene.pages.loaded) == loaded)
}

// An instance traces the cut its distance asks for only once its pages are
// all in the pools; until then the nearest it can on the way to the
// coarsest, which a streamed mesh always has.
@(test)
the_ray_cut_of_a_streamed_mesh_falls_back_toward_the_coarsest :: proc(t: ^testing.T) {
	g, built := streamed_sheet(160)
	if !testing.expect(t, built) {return}
	r:=new(Renderer);defer free(r)
	streamed_renderer(r, 4)
	defer scene_destroy(r)
	handle, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	s := &r.scene
	m := &s.meshes[handle]
	if !testing.expect(t, m.ray_count > 1, "the sheet has coarser ray cuts") {return}
	always := ray_cut_always(m^)
	testing.expect_value(t, always, int(m.ray_count) - 1)
	testing.expect_value(t, m.stream.cut_missing[always], 0)
	testing.expect(t, m.stream.cut_missing[0] > 0, "level 0 has pages out of the root")
	scene_given(r, []Instance_Desc{{object_id = 1, mesh = handle, transform = Mat4(1)}}, nil, {}, {})
	cut :: proc(s: ^Scene_State) -> int {return int(s.instances[0].meta.x >> INSTANCE_RAY_SHIFT & 3)}
	testing.expect_value(t, cut(s), always)
	eye := (m.bounds_min + m.bounds_max) * 0.5
	ray_cuts_update(r, eye)
	traceable := always
	for k := always; k >= 0; k -= 1 {
		if m.stream.cut_missing[k] != 0 {break}
		traceable = k
	}
	testing.expect_value(t, cut(s), traceable)
	testing.expect(t, m.rays[0].wanted > 0, "the instance wants level 0")
	// Once its pages are there, the instance traces it.
	m.stream.cut_missing[0] = 0
	s.ray_cuts_stale = true
	ray_cuts_update(r, eye)
	testing.expect_value(t, cut(s), 0)
}


// The inputs of the BLAS of a cut whose pages are out of the pools come from
// their compressed blocks: the corners of each triangle as the mesh has them.
@(test)
blas_inputs_of_a_cut_out_of_the_pools_decode_its_pages :: proc(t: ^testing.T) {
	g, built := streamed_sheet(160)
	if !testing.expect(t, built) {return}
	r:=new(Renderer);defer free(r)
	streamed_renderer(r, 2)
	defer scene_destroy(r)
	r.hardware_rt = true
	handle, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	s := &r.scene
	m := &s.meshes[handle]
	testing.expect(t, !ray_cut_wanted(r, m^, 0) && ray_cut_wanted(r, m^, ray_cut_always(m^)), "a streamed mesh builds its coarsest cut alone")
	m.rays[0].wanted = r.frame + 1
	if _, ok := blas_inputs_add(r, m); !testing.expect(t, ok) {return}
	ray := m.rays[0]
	if !testing.expect(t, ray.input_vertices == ray.table_count * 9 && ray.table_count > 0) {return}
	positions := s.vertices[ray.input_vertex:][:ray.input_vertices]
	for primitive, k in s.indices[ray.table_word:][:ray.table_count] {
		a, b, c := primitive_positions(g, primitive)
		for want, corner in ([3]Vec3{a, b, c}) {
			at := k * 9 + corner * 3
			got := transmute(Vec3)[3]u32{positions[at], positions[at + 1], positions[at + 2]}
			if got != want {testing.expectf(t, false, "corner %d of primitive %d is %v, not %v", corner, k, got, want);return}
		}
	}
}

// A page asked for whose parents are not all in the pools brings, in its
// place, a missing parent whose own parents are: the request does not stay
// stuck because the view drew only one of its parents.
@(test)
a_page_whose_parents_are_missing_brings_its_parents_first :: proc(t: ^testing.T) {
	g, built := streamed_sheet(256)
	if !testing.expect(t, built, "the sheet has pages out of its root") {return}
	r:=new(Renderer);defer free(r)
	streamed_renderer(r, 256)
	defer scene_destroy(r)
	handle, added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added) {return}
	stream := r.scene.meshes[handle].stream
	// The deepest page of a chain whose ancestors out of the root are all missing.
	deep := asset.MESH_PAGE_NONE
	for page in 0 ..< stream.root {
		for parent in page_parents(stream, page) {if parent < stream.root {deep = page;break}}
		if deep != asset.MESH_PAGE_NONE {break}
	}
	if !testing.expect(t, deep != asset.MESH_PAGE_NONE, "some page has a parent out of the root") {return}
	for _ in 0 ..< 64 {
		if page_resident(stream, deep) {break}
		testing.expect(t, pages_load(r, []Page_Request{{mesh = u32(handle), page = deep, priority = 1}}) > 0, "each frame loads an ancestor or the page")
	}
	testing.expect(t, page_resident(stream, deep) && page_parents_resident(stream, deep), "the page arrives after its parents")
}

// A mesh an extension draws whole (the meshes of particles) loads every page
// out of its root over the frames it asks for it, and while it asks no page
// of it gives its slot to another mesh.
@(test)
a_mesh_drawn_whole_loads_every_page_and_keeps_them :: proc(t: ^testing.T) {
	g, built := streamed_sheet(160)
	if !testing.expect(t, built, "the sheet has pages out of its root") {return}
	r:=new(Renderer);defer free(r)
	streamed_renderer(r, int(g.root_page))
	defer scene_destroy(r)
	whole, added := mesh_add_geometry(r, g, {0})
	other, other_added := mesh_add_geometry(r, g, {0})
	if !testing.expect(t, added && other_added) {return}
	stream := r.scene.meshes[whole].stream
	for _ in 0 ..< 4 * int(stream.root) {
		frame_mesh_whole(r, whole)
		pages_update(r, 0)
		r.frame += 1
	}
	for page in 0 ..< stream.root {testing.expectf(t, stream.slots[page] != PAGE_SLOT_NONE, "page %d of the mesh drawn whole is in the pools", page)}
	r.frame += PAGE_KEEP + 1
	frame_mesh_whole(r, whole)
	frontier := pages_under(r.scene.meshes[other].stream, in_root)
	if !testing.expect(t, len(frontier) > 0) {return}
	testing.expect_value(t, pages_load(r, {{mesh = u32(other), page = frontier[0], priority = 2}}), 0)
}
