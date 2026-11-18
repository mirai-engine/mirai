package mirai_render

import "mirai:asset"
import "mirai:rhi"

// Geometry that goes to the GPU over frames: a mesh added so
// (mesh_add_over_frames), a pose larger than what a frame uploads or of a
// mesh or a binding that still go (skin_create), and the inputs of the native
// BLAS of a mesh larger than that (blas_inputs_queue) keep their ranges of
// the pools out of the dirty ranges, and the publication of each frame sends
// the next of them, sharing UPLOAD_FRAME_BYTES with the levels of textures
// (texture_uploads_record). A publication without a frame sends them all.
// The buffers of the influences and targets of a pose go with it. Until all
// of a mesh or a pose went, nothing reads it on the GPU: its instances are
// hidden (INSTANCE_FLAG_COLLAPSED), its batches are not built, extensions do
// not draw it, its BLAS is not built and its pose is not posed. Before the
// frame after its last range it shows at once (geometry_uploads_install); a
// BLAS whose inputs went is built then.
// A range goes as the copy of the pools of the CPU holds it then, so a mesh
// that takes the slot or the ranges another left never shows what that one
// had. Of a mesh added over frames with its cuts, the copy of the CPU is
// written as its ranges go (Upload_Fill), from the geometry and the cuts the
// caller keeps meanwhile; what reads it on the CPU before writes it first
// (mesh_filled).

GEOMETRY_UPLOADS :: 8 // meshes that go over frames at once
UPLOAD_FRAME_BYTES :: 4 << 20 // of what goes over frames, recorded in a frame: levels of textures and geometry together

// A mesh whose geometry goes over frames: its handle, and which of the meshes
// that took that handle it is.
Mesh_Upload :: struct {
	mesh:   Mesh_Handle,
	serial: u64,
}

// Where the copy of the CPU of a range comes from.
@(private)
Upload_Fill :: enum u8 {
	Held,  // the pool holds it
	Bytes, // source, written into the pool as the range goes
	Pages, // the blocks of the pages of Geometry_Upload.geometry, gathered as the range goes
	Inputs, // the inputs of the native BLAS of a cut of its mesh (Upload_Range.ray), decoded as the range goes
}

// Elements of a pool, or words of a buffer that is not a pool.
@(private)
Upload_Range :: struct {
	pool:         Mesh_Pool,
	first, count: u32,
	buffer:       rhi.Buffer, // 0: the pool; else first and count are words of it
	bytes:        []u8,       // of buffer, the copy of the CPU, from byte 0
	fill:         Upload_Fill,
	source:       []u8, // of fill .Bytes
	filled:       u32,  // of fill other than .Held, the elements written into the pool
	ray:          u8,   // of fill .Inputs, the cut
}

// Its block of each pool (its clusters apart from the rest of its block of
// the index pool), the tables and trees of its cuts, and the buffers of a binding.
@(private)
UPLOAD_RANGES :: 3 + 3 * asset.MESH_RAY_LEVELS + 3

@(private)
Geometry_Upload :: struct {
	request:  Mesh_Upload,
	ranges:   [UPLOAD_RANGES]Upload_Range,
	count:    int,
	at:       int, // the range that goes next
	sent:     u32, // of it, the elements, or words, that went
	binding:  ^Skin_Binding, // its buffers go with it: on the GPU once this went
	inputs:   bool, // the inputs of the native BLAS of a mesh that is drawn
	geometry: asset.Mesh_Geometry, // whose pages a range of fill .Pages gathers
	page:     u32, // the next of them
	active:   bool,
	done:     bool, // its last range went in a frame: it shows before the next
}

// What the copy of the CPU of a mesh registered over frames is written from.
@(private)
Upload_From :: struct {
	geometry: asset.Mesh_Geometry, // its clusters and the blocks of its pages from stored on
	stored:   u32,
	rays:     ^Mesh_Rays, // its tables and trees; nil: the pools hold them
}

@(private)
Geometry_Uploads :: struct {
	entries:        [GEOMETRY_UPLOADS]Geometry_Upload,
	serial:         u64,
	textures_spent: u64, // of UPLOAD_FRAME_BYTES, what the levels of textures took in the frame being recorded
}

// Whether the queue has room for another mesh.
mesh_upload_room :: proc(r: ^Renderer) -> bool {
	for &e in r.scene.uploads.entries {if !e.active {return true}}
	return false
}

// Whether the geometry of a mesh added over frames still goes to the GPU.
mesh_upload_pending :: proc(r: ^Renderer, request: Mesh_Upload) -> bool {
	if request == {} {return false}
	for &e in r.scene.uploads.entries {if e.active && !e.inputs && e.request == request {return true}}
	return false
}

// Whether a mesh is not drawn yet because its geometry still goes to the GPU.
mesh_uploading :: proc(r: ^Renderer, mesh: Mesh_Handle) -> bool {return mesh_pending(&r.scene, u32(mesh))}

@(private)
mesh_pending :: proc "contextless" (s: ^Scene_State, mesh: u32) -> bool {
	for &e in s.uploads.entries {if e.active && !e.inputs && u32(e.request.mesh) == mesh {return true}}
	return false
}

// Whether the inputs of the native BLAS of a mesh still go to the GPU.
@(private)
inputs_queued :: proc "contextless" (s: ^Scene_State, mesh: u32) -> bool {
	for &e in s.uploads.entries {if e.active && e.inputs && u32(e.request.mesh) == mesh {return true}}
	return false
}

// Whether a pose of the queue carries the buffers of a binding.
@(private)
binding_queued :: proc "contextless" (s: ^Scene_State, binding: ^Skin_Binding) -> bool {
	for &e in s.uploads.entries {if e.active && e.binding == binding {return true}}
	return false
}

// Whether ranges wait for the publication of a frame.
@(private)
geometry_uploads_left :: proc "contextless" (s: ^Scene_State) -> bool {
	for &e in s.uploads.entries {if e.active && !e.done {return true}}
	return false
}

// Registers a mesh as mesh_add_geometry does, and gives its geometry to the
// GPU over the frames that follow: until all of it went, no instance draws
// it and no ray meets it, and then it shows at once. With the cuts of
// ahead, the copy of the CPU is written as it goes too, and g and the cuts
// are read until then: the caller keeps them while mesh_upload_pending.
// request names it while mesh_upload_pending; none when the queue had no
// room (mesh_upload_room) and it went at once.
mesh_add_over_frames :: proc(r: ^Renderer, g: asset.Mesh_Geometry, given_words: []u32, ahead: ^Mesh_Ahead = nil) -> (handle: Mesh_Handle, request: Mesh_Upload, ok: bool) {
	if !mesh_upload_room(r) {
		handle, ok = mesh_add_geometry(r, g, given_words, ahead)
		return
	}
	later: Geometry_Upload
	if handle, ok = mesh_register(r, g, given_words, ahead, &later); !ok {return}
	request = upload_start(r, later)
	return
}

@(private = "file")
upload_add :: proc(e: ^Geometry_Upload, range: Upload_Range) {
	if range.count == 0 {return}
	range := range
	// A source that is not the range is not what the pool lacks.
	_, element := upload_range_bytes(range)
	if range.fill == .Bytes && u64(len(range.source)) != u64(range.count) * element {range.fill, range.source = .Held, nil}
	e.ranges[e.count] = range
	e.count += 1
}

// The ranges of a mesh and of the buffers of a binding, as they go. from:
// where the copy of the CPU of a mesh registered over frames comes from.
@(private)
upload_make :: proc(s: ^Scene_State, handle: Mesh_Handle, binding: ^Skin_Binding, from: ^Upload_From = nil) -> (e: Geometry_Upload) {
	m := s.meshes[handle]
	e.request.mesh = handle
	if from == nil {
		upload_add(&e, {pool = .Vertex, first = m.vertex_word, count = m.vertex_span})
		upload_add(&e, {pool = .Index, first = m.index_word, count = m.index_span})
	} else {
		e.geometry, e.page = from.geometry, from.stored
		clusters := m.cluster_count * CLUSTER_WORDS
		upload_add(&e, {pool = .Vertex, first = m.vertex_word, count = m.vertex_span, fill = .Pages})
		upload_add(&e, {pool = .Index, first = m.cluster_word, count = clusters, fill = .Bytes, source = slice_bytes(from.geometry.clusters)})
		upload_add(&e, {pool = .Index, first = m.index_word + clusters, count = m.index_span - clusters})
	}
	for ray, k in m.rays[:m.ray_count] {
		cut: Mesh_Ray_Cut
		fill := Upload_Fill.Held
		if from != nil && from.rays != nil && k < from.rays.count {cut, fill = from.rays.cuts[k], .Bytes}
		upload_add(&e, {pool = .Index, first = ray.table_word, count = ray.table_count, fill = fill, source = slice_bytes(cut.primitives)})
		upload_add(&e, {pool = .Node, first = ray.bvh_root, count = ray.bvh_node_count, fill = fill, source = slice_bytes(cut.nodes)})
		upload_add(&e, {pool = .Triangle, first = ray.triangle_offset, count = ray.triangle_count, fill = fill, source = slice_bytes(cut.triangles)})
	}
	if binding == nil {return}
	e.binding = binding
	Copied :: struct {buffer: rhi.Buffer, bytes: []u8}
	for b in ([3]Copied{{binding.source, slice_bytes(binding.influences)}, {binding.morph_ranges, slice_bytes(binding.morph.ranges)}, {binding.morph_deltas, slice_bytes(binding.morph.deltas)}}) {
		if b.buffer != 0 {upload_add(&e, {buffer = b.buffer, bytes = b.bytes, count = u32(len(b.bytes) / 4)})}
	}
	return
}
#assert(size_of(Skin_Influence) % 4 == 0 && size_of(Morph_Range) % 4 == 0 && size_of(Morph_Delta) % 4 == 0)

// The bytes of a range, and those of one of its elements.
@(private)
upload_range_bytes :: proc "contextless" (range: Upload_Range) -> (bytes, element: u64) {
	element = 4
	if range.buffer == 0 {
		switch range.pool {
		case .Vertex, .Index: element = size_of(u32)
		case .Node:           element = size_of(Gpu_Bvh_Node)
		case .Triangle:       element = size_of(Gpu_Bvh_Triangle)
		}
	}
	return u64(range.count) * element, element
}

@(private)
upload_bytes :: proc "contextless" (e: ^Geometry_Upload) -> (bytes: u64) {
	for range in e.ranges[:e.count] {
		range_bytes, _ := upload_range_bytes(range)
		bytes += range_bytes
	}
	return
}

// Takes the ranges of e out of the dirty ranges, which the next publication
// would send whole, into the queue. None, with everything left to go at
// once, when the queue has no room.
@(private)
upload_start :: proc(r: ^Renderer, e: Geometry_Upload) -> Mesh_Upload {
	s := &r.scene
	for &slot in s.uploads.entries {
		if slot.active {continue}
		slot = e
		slot.active = true
		s.uploads.serial += 1
		slot.request.serial = s.uploads.serial
		for range in slot.ranges[:slot.count] {
			if range.buffer == 0 {range_remove(&s.pool_dirty[range.pool], {range.first, range.count})}
		}
		if slot.binding != nil {slot.binding.uploading = true}
		s.geometry_dirty = true
		return slot.request
	}
	return {}
}

// What the levels of textures may take of UPLOAD_FRAME_BYTES in a frame:
// half while geometry waits too. The geometry takes what they left.
@(private)
textures_upload_budget :: proc "contextless" (s: ^Scene_State) -> u64 {
	return UPLOAD_FRAME_BYTES / 2 if geometry_uploads_left(s) else UPLOAD_FRAME_BYTES
}
@(private)
geometry_upload_budget :: proc "contextless" (s: ^Scene_State) -> u64 {
	return UPLOAD_FRAME_BYTES - min(s.uploads.textures_spent, UPLOAD_FRAME_BYTES)
}

// The next ranges of the queue, in the order of its slots, budget bytes of
// them at most, as copies of the publication of a frame: what the budget
// leaves of one goes to none after it. held: the elements the buffer of each
// pool holds; a range past it waits for the pool to grow, and the next mesh
// goes meanwhile. An entry whose ranges all went is done. What the copies
// took.
@(private)
geometry_uploads_take :: proc(r: ^Renderer, copies: ^[dynamic]Geometry_Copy, held: [Mesh_Pool]int, budget: u64) -> (spent: u64, ok: bool) {
	s := &r.scene
	for &e in s.uploads.entries {
		if !e.active || e.done {continue}
		for e.at < e.count {
			range := e.ranges[e.at]
			_, element := upload_range_bytes(range)
			reach := range.count
			if range.buffer == 0 {reach = u32(clamp(held[range.pool] - int(range.first), 0, int(range.count)))}
			count := u32(min(u64(reach - min(e.sent, reach)), (budget - spent) / element))
			if count > 0 {
				upload_fill(s, &e, &e.ranges[e.at], e.sent + count)
				copy := Geometry_Copy{buffer = range.buffer, offset = u64(e.sent) * element}
				if range.buffer == 0 {
					buffer, _, _, _, _ := pool_gpu(s, range.pool)
					copy.buffer = buffer^
					copy.offset += u64(range.first) * element
					copy.bytes = upload_pool_bytes(s, range.pool, range.first + e.sent, count)
				} else {
					copy.bytes = range.bytes[e.sent * 4:][:count * 4]
				}
				if _, error := append(copies, copy); error != nil {set_error(r, "geometry copy allocation failed");return spent, false}
				spent += u64(count) * element
				e.sent += count
			}
			if e.sent < reach {return spent, true}
			if e.sent < range.count {break}
			e.at, e.sent = e.at + 1, 0
		}
		e.done = e.at == e.count
	}
	return spent, true
}

// Writes into the pool what a range lacks up to its element until, from
// where its copy of the CPU comes: what goes next reads the pool. A range of
// pages writes whole pages, the last past until.
@(private)
upload_fill :: proc(s: ^Scene_State, e: ^Geometry_Upload, range: ^Upload_Range, until: u32) {
	until := min(until, range.count)
	switch range.fill {
	case .Held:
	case .Bytes:
		if range.filled >= until {return}
		_, element := upload_range_bytes(range^)
		count := until - range.filled
		copy(upload_pool_bytes(s, range.pool, range.first + range.filled, count), range.source[u64(range.filled) * element:][:u64(count) * element])
		range.filled = until
	case .Pages:
		g := e.geometry
		for range.filled < until && int(e.page) < len(g.pages) {
			page := g.pages[e.page]
			words := page_words(g, page)
			asset.mesh_page_gather(g, page, s.vertices[range.first + range.filled:][:words])
			range.filled += words
			e.page += 1
		}
	case .Inputs:
		m := s.meshes[e.request.mesh]
		ray := m.rays[range.ray]
		p := record_pooled(s, m)
		primitives := s.indices[ray.table_word:][:ray.table_count]
		posed := m.posed_word != GPU_NONE
		// Whole primitives: nine positions or three indices each.
		for range.filled < until {
			if range.pool == .Vertex {
				blas_input_positions(p, primitives[range.filled / 9], s.vertices[range.first + range.filled:][:9])
				range.filled += 9
			} else {
				blas_input_indices(p, primitives[range.filled / 3], range.filled / 3, posed, s.indices[range.first + range.filled:][:3])
				range.filled += 3
			}
		}
	}
}

// Writes into the pools of the CPU all a mesh whose geometry still goes
// lacks, for what reads them on the CPU before it went.
@(private)
mesh_filled :: proc(s: ^Scene_State, mesh: u32) {
	for &e in s.uploads.entries {
		if !e.active || e.inputs || u32(e.request.mesh) != mesh {continue}
		for &range in e.ranges[:e.count] {upload_fill(s, &e, &range, range.count)}
	}
}

// Whether the inputs blas_inputs_add would give the cuts of a mesh now take
// more than a frame uploads.
@(private)
blas_inputs_over :: proc(r: ^Renderer, m: ^Mesh_Record) -> bool {
	words := 3 if m.posed_word != GPU_NONE else 12
	return u64(blas_inputs_cost(r, m)) * u64(words) * size_of(u32) > UPLOAD_FRAME_BYTES
}

// The inputs whose room blas_inputs_add just took for the cuts of a mesh are
// decoded and go to the GPU with the uploads of the frames, and its BLAS is
// built once they went (inputs_queued). The queue has room.
@(private)
blas_inputs_queue :: proc(r: ^Renderer, mesh: u32) {
	m := r.scene.meshes[mesh]
	e := Geometry_Upload{inputs = true}
	e.request.mesh = Mesh_Handle(mesh)
	for ray, k in m.rays[:m.ray_count] {
		if ray.blas != 0 || ray.input_indices == 0 {continue}
		upload_add(&e, {pool = .Vertex, first = ray.input_vertex, count = ray.input_vertices, fill = .Inputs, ray = u8(k)})
		upload_add(&e, {pool = .Index, first = ray.input_index, count = ray.input_indices, fill = .Inputs, ray = u8(k)})
	}
	upload_start(r, e)
}
#assert(UPLOAD_RANGES >= 2 * asset.MESH_RAY_LEVELS)

@(private)
upload_pool_bytes :: proc(s: ^Scene_State, pool: Mesh_Pool, first, count: u32) -> []u8 {
	switch pool {
	case .Vertex:   return slice_bytes(s.vertices[first:][:count])
	case .Index:    return slice_bytes(s.indices[first:][:count])
	case .Node:     return slice_bytes(s.blas_nodes[first:][:count])
	case .Triangle: return slice_bytes(s.blas_triangles[first:][:count])
	}
	return nil
}

// The meshes whose last ranges went with the publication before show,
// between frames: the frame after them reads them. The BLAS of one whose
// inputs went is built with the next publication.
@(private)
geometry_uploads_install :: proc(r: ^Renderer) {
	for &e in r.scene.uploads.entries {
		if !e.active || !e.done {continue}
		mesh, inputs := e.request.mesh, e.inputs
		if e.binding != nil {e.binding.uploading = false}
		e = {}
		if inputs {r.scene.geometry_dirty = true} else {mesh_shown(r, u32(mesh))}
	}
}

// A mesh leaves the queue: it goes, or all of them do (handle -1).
@(private)
geometry_uploads_cancel :: proc "contextless" (s: ^Scene_State, handle: i64 = -1) {
	for &e in s.uploads.entries {
		if e.active && (handle < 0 || i64(e.request.mesh) == handle) {e = {}}
	}
}

// Takes a range out of ranges: what they held before and after it stays.
@(private)
range_remove :: proc(ranges: ^[dynamic]Pool_Range, removed: Pool_Range) {
	if removed.count == 0 {return}
	end := removed.first + removed.count
	for i := 0; i < len(ranges); {
		held := ranges[i]
		held_end := held.first + held.count
		if held_end <= removed.first || held.first >= end {i += 1;continue}
		unordered_remove(ranges, i)
		if held.first < removed.first {append(ranges, Pool_Range{held.first, removed.first - held.first})}
		if held_end > end {append(ranges, Pool_Range{end, held_end - end})}
	}
}
