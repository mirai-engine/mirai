package mirai_render

import "core:mem"
import "core:slice"
import "core:testing"
import "mirai:asset"
import mm "mirai:std/math"

// A flat grid of quads of side cells, as a file or a job encodes it.
@(private = "file")
uploads_grid :: proc(cells: int) -> (g: asset.Mesh_Geometry, ok: bool) {
	vertices := make([]asset.Vertex, (cells + 1) * (cells + 1), context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for z in 0 ..= cells {
		for x in 0 ..= cells {vertices[z * (cells + 1) + x] = {position = {f32(x), 0, f32(z)}, normal = mm.normal_pack({0, 1, 0})}}
	}
	for z in 0 ..< cells {
		for x in 0 ..< cells {
			a := u32(z * (cells + 1) + x)
			b, c, d := a + 1, a + u32(cells + 1), a + u32(cells + 2)
			append(&indices, a, c, b, b, c, d)
		}
	}
	ok = asset.mesh_build({vertices = vertices}, indices[:], nil, &g, context.temp_allocator)
	return
}

@(private = "file")
uploads_renderer :: proc() -> ^Renderer {
	r := new(Renderer)
	r.allocator = context.allocator
	scene_init(r)
	return r
}

@(private = "file")
uploads_free :: proc(r: ^Renderer) {
	scene_destroy(r)
	free(r)
}

// The elements each pool of the CPU holds, as a GPU that kept up holds them.
@(private = "file")
uploads_held :: proc(s: ^Scene_State) -> [Mesh_Pool]int {
	return {.Vertex = len(s.vertices), .Index = len(s.indices), .Node = len(s.blas_nodes), .Triangle = len(s.blas_triangles)}
}

// The publication of one frame: what was done shows first, then the next
// ranges go. Whether the queue still had something.
@(private = "file")
uploads_frame :: proc(t: ^testing.T, r: ^Renderer, budget: u64, held: [Mesh_Pool]int, sent: ^u64) -> bool {
	geometry_uploads_install(r)
	if !geometry_uploads_left(&r.scene) {return false}
	copies := make([dynamic]Geometry_Copy, context.temp_allocator)
	spent, ok := geometry_uploads_take(r, &copies, held, budget)
	testing.expect(t, ok)
	testing.expectf(t, spent <= budget, "a frame sends %d bytes, more than its %d", spent, budget)
	for c in copies {sent^ += u64(len(c.bytes))}
	return true
}

// A mesh added over frames keeps its geometry out of the dirty ranges and
// sends it a budget at a time: until all of it went its instances are not
// drawn, a move does not show them, and its request is pending; in the frame
// after its last range they show at once. A range past what the buffer of
// its pool holds waits for it to grow.
@(test)
a_mesh_added_over_frames_is_hidden_until_all_its_geometry_went :: proc(t: ^testing.T) {
	r := uploads_renderer()
	defer uploads_free(r)
	s := &r.scene
	small_grid, small_ok := uploads_grid(2)
	big_grid, big_ok := uploads_grid(40)
	if !testing.expect(t, small_ok && big_ok) {return}
	small, _ := mesh_add_geometry(r, small_grid, nil)
	for &ranges in s.pool_dirty {clear(&ranges)}
	big, request, added := mesh_add_over_frames(r, big_grid, nil)
	if !testing.expect(t, added && request.mesh == big && mesh_upload_pending(r, request) && mesh_uploading(r, big)) {return}
	for ranges in s.pool_dirty {testing.expect_value(t, len(ranges), 0)}
	testing.expect(t, !mesh_uploading(r, small))

	scene_given(r, {{object_id = 1, mesh = small, transform = 1}, {object_id = 2, mesh = big, transform = 1, highlight = 1}, {object_id = 3, mesh = big, transform = 1, hidden = true}}, nil, {}, {})
	shown := 1
	testing.expect_value(t, s.instances[shown].meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED), u32(INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED))
	testing.expect(t, !highlight_drawn(s.instances[shown].meta.w) && s.hw_instances[shown].mask_flags == 0, "no outline, and no ray meets it")
	testing.expect_value(t, s.instances[2].meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED), u32(INSTANCE_FLAG_HIDDEN))
	testing.expect_value(t, s.hidden_count, 2)
	testing.expect(t, s.instances[0].meta.w & INSTANCE_FLAG_HIDDEN == 0)
	moved := Mat4(1)
	moved[0, 3] = 3
	testing.expect(t, scene_move(r, {1}, {moved}))
	testing.expect(t, s.instances[shown].meta.w & INSTANCE_FLAG_HIDDEN != 0, "a move does not show it while its mesh goes")

	total := upload_bytes(&s.uploads.entries[0])
	record := s.meshes[big]
	// The vertex pool holds less than its block: the rest waits.
	held := uploads_held(s)
	held[.Vertex] = int(record.vertex_word + record.vertex_span / 2)
	sent: u64
	BUDGET :: 4096
	for _ in 0 ..< 1000 {
		if !uploads_frame(t, r, BUDGET, held, &sent) {break}
	}
	entry := s.uploads.entries[0]
	testing.expect(t, entry.active && !entry.done && entry.at == 0 && entry.sent == record.vertex_span / 2, "past what the pool holds it waits")
	testing.expect(t, mesh_upload_pending(r, request))

	held = uploads_held(s)
	frames := 0
	for ; frames < 1000; frames += 1 {
		if !uploads_frame(t, r, BUDGET, held, &sent) {break}
		if s.uploads.entries[0].done {
			testing.expect(t, mesh_upload_pending(r, request) && s.instances[shown].meta.w & INSTANCE_FLAG_HIDDEN != 0, "it shows before the frame after its last range")
		}
	}
	testing.expect_value(t, sent, total)
	testing.expectf(t, u64(frames) * BUDGET >= total - u64(record.vertex_span / 2) * 4 && frames > 1, "over %d frames", frames)
	testing.expect(t, !mesh_upload_pending(r, request) && !mesh_uploading(r, big))
	testing.expect_value(t, s.instances[shown].meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED), u32(0))
	testing.expect(t, highlight_drawn(s.instances[shown].meta.w) && s.hw_instances[shown].mask_flags != 0, "outlined, and rays meet it")
	testing.expect(t, s.instances[2].meta.w & INSTANCE_FLAG_HIDDEN != 0, "one its description hides stays hidden")
	testing.expect_value(t, s.hidden_count, 1)
	testing.expect(t, s.geometry_dirty && !s.batch.built)
	testing.expect(t, instance_touched(s, u32(shown)) || s.instances_dirty, "the instance that shows goes to the GPU")
}

// The levels of textures take half the bytes of a frame while geometry waits
// too, and the geometry what they left; the meshes go in the order of the
// queue, the next starting in the frame the one before ends, and both show
// in the frame after.
@(test)
geometry_and_textures_share_the_bytes_of_a_frame :: proc(t: ^testing.T) {
	r := uploads_renderer()
	defer uploads_free(r)
	s := &r.scene
	testing.expect_value(t, textures_upload_budget(s), u64(UPLOAD_FRAME_BYTES))
	first_grid, _ := uploads_grid(24)
	second_grid, _ := uploads_grid(8)
	first, first_request, _ := mesh_add_over_frames(r, first_grid, nil)
	_, second_request, _ := mesh_add_over_frames(r, second_grid, nil)
	testing.expect(t, mesh_upload_pending(r, first_request) && mesh_upload_pending(r, second_request) && first_request.serial != second_request.serial)
	testing.expect_value(t, textures_upload_budget(s), u64(UPLOAD_FRAME_BYTES / 2))
	s.uploads.textures_spent = UPLOAD_FRAME_BYTES / 2
	testing.expect_value(t, geometry_upload_budget(s), u64(UPLOAD_FRAME_BYTES / 2))
	s.uploads.textures_spent = UPLOAD_FRAME_BYTES + 1
	testing.expect_value(t, geometry_upload_budget(s), u64(0))
	s.uploads.textures_spent = 0
	testing.expect_value(t, geometry_upload_budget(s), u64(UPLOAD_FRAME_BYTES))

	// Less than the first: the second waits.
	firsts := upload_bytes(&s.uploads.entries[0])
	held := uploads_held(s)
	sent: u64
	uploads_frame(t, r, firsts / 2, held, &sent)
	testing.expect(t, !s.uploads.entries[0].done && s.uploads.entries[1].at == 0 && s.uploads.entries[1].sent == 0)
	// What the first leaves of a frame goes to the second.
	uploads_frame(t, r, firsts, held, &sent)
	testing.expect(t, s.uploads.entries[0].done && (s.uploads.entries[1].at > 0 || s.uploads.entries[1].sent > 0))
	testing.expect(t, !uploads_frame(t, r, UPLOAD_FRAME_BYTES, held, &sent))
	testing.expect(t, !mesh_uploading(r, first) && !mesh_upload_pending(r, second_request) && !geometry_uploads_left(s))
	testing.expect_value(t, textures_upload_budget(s), u64(UPLOAD_FRAME_BYTES))
}

// A mesh removed while its geometry goes leaves the queue; one that takes its
// slot and its ranges is another request, sends every word of its own from
// the copy of the CPU, and its instances wait for it. Past the room of the
// queue a mesh goes at once, with its ranges dirty.
@(test)
a_mesh_that_takes_the_slot_of_one_still_going_shows_only_its_own_geometry :: proc(t: ^testing.T) {
	r := uploads_renderer()
	defer uploads_free(r)
	s := &r.scene
	grid, _ := uploads_grid(16)
	gone, gone_request, _ := mesh_add_over_frames(r, grid, nil)
	scene_given(r, {{object_id = 1, mesh = gone, transform = 1}}, nil, {}, {})
	held := uploads_held(s)
	sent: u64
	uploads_frame(t, r, 256, held, &sent)
	testing.expect(t, sent > 0 && mesh_upload_pending(r, gone_request))
	before := s.meshes[gone]
	testing.expect(t, mesh_remove(r, gone))
	testing.expect(t, !mesh_upload_pending(r, gone_request) && !geometry_uploads_left(s), "it leaves the queue")
	testing.expect(t, s.instances[0].meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED) == INSTANCE_FLAG_HIDDEN)

	other, _ := uploads_grid(15)
	reused, request, _ := mesh_add_over_frames(r, other, nil)
	testing.expect_value(t, reused, gone)
	testing.expect(t, request != gone_request && !mesh_upload_pending(r, gone_request) && mesh_upload_pending(r, request))
	record := s.meshes[reused]
	testing.expect_value(t, record.vertex_word, before.vertex_word)
	entry := s.uploads.entries[0]
	testing.expect(t, entry.at == 0 && entry.sent == 0, "it sends its words from the first")
	copies := make([dynamic]Geometry_Copy, context.temp_allocator)
	_, ok := geometry_uploads_take(r, &copies, uploads_held(s), u64(record.vertex_span) * 4)
	testing.expect(t, ok && len(copies) == 1)
	testing.expect(t, mem.compare(copies[0].bytes, mem.slice_to_bytes(s.vertices[record.vertex_word:][:record.vertex_span])) == 0, "what goes is what it put there")
	testing.expect_value(t, copies[0].offset, u64(record.vertex_word) * 4)
	scene_given(r, {{object_id = 2, mesh = reused, transform = 1}}, nil, {}, {})
	testing.expect(t, s.instances[0].meta.w & INSTANCE_FLAG_COLLAPSED != 0, "its instance waits for it")

	// The queue full, the next goes at once.
	small, _ := uploads_grid(1)
	for _ in 1 ..< GEOMETRY_UPLOADS {_, queued, _ := mesh_add_over_frames(r, small, nil);testing.expect(t, queued != {})}
	testing.expect(t, !mesh_upload_room(r))
	for &ranges in s.pool_dirty {clear(&ranges)}
	last, none, added := mesh_add_over_frames(r, small, nil)
	testing.expect(t, added && none == {} && !mesh_uploading(r, last))
	testing.expect(t, len(s.pool_dirty[.Vertex]) > 0 && len(s.pool_dirty[.Index]) > 0, "its ranges go with the next publication")
	meshes_clear(r)
	testing.expect(t, mesh_upload_room(r) && !geometry_uploads_left(s))
}

// A mesh added over frames with its cuts takes its blocks in the pools of
// the CPU and writes them as its ranges go, a frame's budget at a time (a
// range of pages whole pages): in the end they hold what a mesh added at
// once holds. What reads the pools on the CPU before writes all it lacks.
@(test)
the_copy_of_the_cpu_of_a_mesh_added_over_frames_is_written_as_it_goes :: proc(t: ^testing.T) {
	r := uploads_renderer()
	defer uploads_free(r)
	s := &r.scene
	grid, built := uploads_grid(40)
	ahead, made := mesh_ahead_make(grid, 1, true, context.allocator)
	defer mesh_ahead_destroy(&ahead)
	if !testing.expect(t, built && made) {return}
	whole, _ := mesh_add_geometry(r, grid, nil, &ahead)
	for &ranges in s.pool_dirty {clear(&ranges)}
	later, request, added := mesh_add_over_frames(r, grid, nil, &ahead)
	if !testing.expect(t, added && mesh_upload_pending(r, request)) {return}
	for ranges in s.pool_dirty {testing.expect_value(t, len(ranges), 0)}
	entry := &s.uploads.entries[0]
	for range in entry.ranges[:entry.count] {testing.expect_value(t, range.filled, u32(0))}
	testing.expect(t, entry.ranges[0].fill == .Pages && entry.ranges[1].fill == .Bytes, "its blocks and its clusters wait")

	page_most: u32
	for page in grid.pages {page_most = max(page_most, page_words(grid, page))}
	BUDGET :: 4096
	held := uploads_held(s)
	sent: u64
	for _ in 0 ..< 1000 {
		if !uploads_frame(t, r, BUDGET, held, &sent) || !entry.active {break}
		for range, at in entry.ranges[:entry.count] {
			if range.fill == .Held {continue}
			gone := range.count if at < entry.at else (entry.sent if at == entry.at else 0)
			slack := page_most if range.fill == .Pages else 0
			testing.expectf(t, range.filled >= gone && range.filled <= gone + slack, "range %d holds %d of %d that went", at, range.filled, gone)
		}
	}
	testing.expect(t, !mesh_upload_pending(r, request))

	a, b := s.meshes[whole], s.meshes[later]
	testing.expect(t, a.vertex_span == b.vertex_span && a.index_span == b.index_span)
	same :: proc(x, y: []$T) -> bool {return mem.compare(mem.slice_to_bytes(x), mem.slice_to_bytes(y)) == 0}
	testing.expect(t, same(s.vertices[a.vertex_word:][:a.vertex_span], s.vertices[b.vertex_word:][:b.vertex_span]), "its blocks")
	clusters := a.cluster_count * CLUSTER_WORDS
	testing.expect(t, same(s.indices[a.cluster_word:][:clusters], s.indices[b.cluster_word:][:clusters]), "its clusters")
	pa := mem.slice_data_cast([]Gpu_Mesh_Page, s.indices[a.page_word:][:a.page_count * PAGE_ENTRY_WORDS])
	pb := mem.slice_data_cast([]Gpu_Mesh_Page, s.indices[b.page_word:][:b.page_count * PAGE_ENTRY_WORDS])
	for page, k in pa {
		mine, other := page, pb[k]
		if mine.base != GPU_NONE {mine.base -= a.vertex_word;other.base -= b.vertex_word}
		testing.expectf(t, mine == other, "page %d", k)
	}
	rest := a.index_span - (a.level_word - a.index_word)
	testing.expect(t, same(s.indices[a.level_word:][:rest], s.indices[b.level_word:][:rest]), "its levels and slots")
	for k in 0 ..< a.ray_count {
		x, y := a.rays[k], b.rays[k]
		testing.expect(t, same(s.blas_nodes[x.bvh_root:][:x.bvh_node_count], s.blas_nodes[y.bvh_root:][:y.bvh_node_count]), "its trees")
		testing.expect(t, same(s.blas_triangles[x.triangle_offset:][:x.triangle_count], s.blas_triangles[y.triangle_offset:][:y.triangle_count]))
	}

	early, early_request, _ := mesh_add_over_frames(r, grid, nil, &ahead)
	testing.expect(t, mesh_upload_pending(r, early_request))
	want, got := make([dynamic]Vec3, context.temp_allocator), make([dynamic]Vec3, context.temp_allocator)
	want_indices, got_indices := make([dynamic]u32, context.temp_allocator), make([dynamic]u32, context.temp_allocator)
	testing.expect(t, mesh_triangles(r, whole, &want, &want_indices) && mesh_triangles(r, early, &got, &got_indices))
	testing.expect(t, same(want[:], got[:]) && same(want_indices[:], got_indices[:]), "a reader on the CPU meets it whole")
	testing.expect(t, mesh_upload_pending(r, early_request), "and it still goes")
}

// What a job made of a mesh ahead (mesh_ahead_make) spares the frame that
// takes it every walk of its geometry: it is not checked again, its slab
// axes and reach come with it, and the stream of its pages is the one the
// job made, not a copy. So the frame takes geometry whose page out of the
// root no longer holds together as the job saw it, and the mesh reads whole
// what the job saw.
@(test)
a_mesh_taken_with_what_a_job_made_ahead_walks_none_of_its_geometry :: proc(t: ^testing.T) {
	g, built := streamed_sheet(160)
	if !testing.expect(t, built) {return}
	ahead, made := mesh_ahead_make(g, 1, true, context.allocator)
	defer mesh_ahead_destroy(&ahead)
	if !testing.expect(t, made && ahead.stream != nil && ahead.slots == 1) {return}
	stream, axes, reach := ahead.stream, ahead.slab_axes, ahead.lod_reach
	taken := g
	taken.triangles = make([]u32, len(g.triangles), context.temp_allocator)
	copy(taken.triangles, g.triangles)
	taken.triangles[g.clusters[0].triangle_first] = 0xffffffff
	testing.expect(t, g.clusters[0].page < g.root_page && !mesh_geometry_check(taken, 1), "a corner out of its cluster in a page out of the root")
	r := uploads_renderer()
	defer uploads_free(r)
	s := &r.scene
	handle, request, added := mesh_add_over_frames(r, taken, nil, &ahead)
	if !testing.expect(t, added, "the frame does not check it again") {return}
	m := s.meshes[handle]
	testing.expect(t, m.stream == stream && ahead.stream == nil, "it takes the stream of the job")
	testing.expect(t, m.slab_axes == axes && m.lod_reach == reach)
	held := uploads_held(s)
	sent: u64
	for _ in 0 ..< 1000 {if !uploads_frame(t, r, UPLOAD_FRAME_BYTES, held, &sent) {break}}
	testing.expect(t, !mesh_upload_pending(r, request))
	decoded, decodes := record_decode(s, s.meshes[handle], context.temp_allocator)
	same :: proc(x, y: []$T) -> bool {return len(x) == len(y) && mem.compare(mem.slice_to_bytes(x), mem.slice_to_bytes(y)) == 0}
	testing.expect(t, decodes && same(decoded.triangles, g.triangles) && same(decoded.vertices, g.vertices), "it reads what the job saw")
}

// Traced by hardware, the inputs of the native BLAS of a mesh larger than a
// frame uploads are decoded as they go with the uploads of the frames while
// the mesh is drawn, and its BLAS waits for them; smaller ones, and any
// between frames, are decoded at once and go with the next publication. Both
// ways they are the same.
@(test)
the_blas_inputs_of_a_mesh_larger_than_a_frame_go_over_frames :: proc(t: ^testing.T) {
	big_grid, big_ok := uploads_grid(212)
	small_grid, small_ok := uploads_grid(4)
	if !testing.expect(t, big_ok && small_ok) {return}
	dirty :: proc(s: ^Scene_State, pool: Mesh_Pool, first, count: u32) -> bool {
		for range in s.pool_dirty[pool] {if range.first < first + count && first < range.first + range.count {return true}}
		return false
	}
	at_once: [2][]u32
	for frame in ([]bool{false, true}) {
		r := uploads_renderer()
		defer uploads_free(r)
		r.hardware_rt = true
		s := &r.scene
		big, _ := mesh_add_geometry(r, big_grid, nil)
		small, _ := mesh_add_geometry(r, small_grid, nil)
		testing.expect(t, blas_inputs_over(r, &s.meshes[big]) && !blas_inputs_over(r, &s.meshes[small]))
		for &ranges in s.pool_dirty {clear(&ranges)}
		geometry_blas_inputs(r, frame)
		ray, other := s.meshes[big].rays[0], s.meshes[small].rays[0]
		testing.expect(t, ray.input_indices > 0 && other.input_indices > 0)
		testing.expect(t, dirty(s, .Index, other.input_index, other.input_indices), "the small one goes with the publication")
		if !frame {
			testing.expect(t, !inputs_queued(s, u32(big)) && dirty(s, .Vertex, ray.input_vertex, ray.input_vertices), "between frames all of it goes")
			at_once = {slice.clone(s.vertices[ray.input_vertex:][:ray.input_vertices], context.temp_allocator), slice.clone(s.indices[ray.input_index:][:ray.input_indices], context.temp_allocator)}
			continue
		}
		testing.expect(t, inputs_queued(s, u32(big)) && !inputs_queued(s, u32(small)))
		testing.expect(t, !dirty(s, .Vertex, ray.input_vertex, ray.input_vertices) && !dirty(s, .Index, ray.input_index, ray.input_indices))
		testing.expect(t, !mesh_uploading(r, big), "it is drawn meanwhile")
		for range in s.uploads.entries[0].ranges[:s.uploads.entries[0].count] {
			testing.expect(t, range.fill == .Inputs && range.filled == 0, "nothing of it is decoded in the frame that takes it")
		}
		testing.expect(t, !slice.equal(s.vertices[ray.input_vertex:][:ray.input_vertices], at_once[0]))
		held := uploads_held(s)
		sent: u64
		frames := 0
		s.geometry_dirty = false
		for ; frames < 100 && uploads_frame(t, r, UPLOAD_FRAME_BYTES / 2, held, &sent); frames += 1 {}
		testing.expect_value(t, sent, u64(ray.input_vertices + ray.input_indices) * 4)
		testing.expectf(t, frames > 1 && !inputs_queued(s, u32(big)), "over %d frames", frames)
		testing.expect(t, s.geometry_dirty, "its BLAS is built with the next publication")
		testing.expect(t, slice.equal(s.vertices[ray.input_vertex:][:ray.input_vertices], at_once[0]) && slice.equal(s.indices[ray.input_index:][:ray.input_indices], at_once[1]), "what went is what goes at once")
	}
}

@(test)
range_remove_keeps_what_lies_around_the_range :: proc(t: ^testing.T) {
	ranges := make([dynamic]Pool_Range, context.temp_allocator)
	append(&ranges, Pool_Range{0, 10}, Pool_Range{20, 5}, Pool_Range{40, 10})
	range_remove(&ranges, {5, 38})
	total: u32
	for range in ranges {
		testing.expect(t, range.first + range.count <= 5 || range.first >= 43, "nothing of the range stays")
		total += range.count
	}
	testing.expect_value(t, total, u32(5 + 7))
	range_remove(&ranges, {100, 4})
	testing.expect_value(t, len(ranges), 2)
}
