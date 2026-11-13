package mirai_render

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:rhi"
import "mirai:std/jobs"
import "mirai:render/abi"

// The pages of streamed meshes. A mesh with the blocks of its pages (of a
// file, or made in memory and packed: asset.mesh_pages_pack) whose root is
// not every page (asset.Mesh_Info.root_page) keeps its root in its block of
// the vertex pool and the others out of it: their entries start GPU_NONE. The renderer
// keeps its pages and their compressed blocks (Mesh_Stream), and a region of
// the vertex pool of Settings.page_pool_bytes, reserved once when the first
// such mesh comes, holds the pages the views ask for in slots of
// PAGE_SLOT_WORDS words. The CPU copy of a slot is the decoded block of its
// page, which the publication uploads as any other range.
//
// The cull (cull_clusters.comp) asks for the page of the children of a
// cluster it draws in their place, once a frame each in a table that keeps
// its highest priority, and stamps the slot of every page it draws; both come
// back MAX_FRAMES_IN_FLIGHT frames later. Each frame the
// most wanted pages whose parents are in the pools load, up to
// PAGE_LOAD_WORDS decoded words, into a free slot or that of the page drawn
// least recently, not within PAGE_KEEP frames, with no children in the
// pools and not in a cut rays trace. So every page in the pools has its
// parents there too, and the clusters the cull draws cover each mesh once.

PAGE_SLOT_WORDS :: abi.PAGE_SLOT_WORDS // PAGE_SLOT_WORDS of cull_clusters.comp
// Frames after its last stamp before a page in use may give its slot up: past
// the frames its stamps take to come back.
PAGE_KEEP :: u64(60)
// The decoded words of the pages one frame loads; the first page loads whatever it has.
PAGE_LOAD_WORDS :: 1 << 19
PAGE_LOADS_MAX :: 64
// Entries of the table of the pages the cull asks for, a power of two: it doubles
// while a frame fills half of it or a request finds no entry (counted, dropped).
PAGE_REQUEST_START :: 4096
// Words before the first request: the first counts them (cull_clusters.comp).
PAGE_REQUEST_FIRST :: abi.PAGE_REQUEST_FIRST
// Frames in a row with pages that found no room before Stats.problem says so.
PAGE_SHORT_FRAMES :: 120
PAGE_SLOT_NONE :: max(u32)
// The most slots a region takes: its words stay within the u32 words of the pool.
PAGE_SLOTS_MAX :: 16384

// A page the cull asks for: the mesh, the page, the most pixels the error of a
// cluster drawn in place of its children spans, and its key in the table of
// the cull (0: an empty entry). Rays ask with priority 0.
Page_Request :: struct {
	mesh, page: u32,
	priority:   f32,
	key:        u32,
}
#assert(size_of(Page_Request) == 4 * 4)

// What the renderer keeps of a mesh with pages out of the root.
Mesh_Stream :: struct {
	id:           u32, // of the decoded block in Page_Scratch; never 0
	mesh:         u32, // its handle
	pages:        []asset.Mesh_Page,
	data:         []u8, // the compressed blocks of its pages (asset.Mesh_Geometry.page_data)
	flags:        asset.Mesh_Flags,
	root:         u32, // pages from it on are in its block
	slots:        []u32, // of each page out of the root, its slot; PAGE_SLOT_NONE while it has none
	children:     []u32, // of each page, the pages in slots it is a parent of
	parent_first: []u32, // page k has the parents parents[parent_first[k]:parent_first[k + 1]]
	parents:      []u32, // the pages of the clusters a page holds the children of
	cuts:         []u8, // of each page, a bit for each ray cut that takes some cluster of it
	cut_missing:  [asset.MESH_RAY_LEVELS]u32, // pages of each cut out of the pools
	allocator:    mem.Allocator,
}

// A slot of the region: the page in it, and the frame + 1 it was last drawn or loaded.
Page_Slot :: struct {
	mesh, page: u32, // mesh GPU_NONE: free
	stamp:      u64,
}

// A page out of the pools decoded for the CPU (pooled_cluster).
Page_Scratch :: struct {
	words:        []u32, // MESH_PAGE_WORDS
	coded:        []u8, // MESH_PAGE_SCRATCH_BYTES, what decoding it works in
	decoder:      asset.Stream_Decoder,
	stream, page: u32, // what it holds; stream 0: nothing
}

// A slot that may give its page up this frame, and the frame + 1 it was drawn.
@(private)
Page_Victim :: struct {
	stamp: u64,
	slot:  u32,
}

@(private)
Page_Load :: struct {
	stream:     ^Mesh_Stream,
	page, slot: u32,
	ok:         bool,
}

Pages_State :: struct {
	region:           u32, // the first word of the slots in the vertex pool
	slot_count:       u32, // 0: no region
	tried, refused:   bool, // the region was asked for, and the GPU had no memory for it
	slots:            []Page_Slot,
	free:             [dynamic]u32,
	requests:         [dynamic]Page_Request,
	victims:          [dynamic]Page_Victim, // the oldest last, sorted by the first eviction of a frame
	victims_sorted:   bool,
	loads:            [PAGE_LOADS_MAX]Page_Load,
	load_count:       int,
	scratch:          Page_Scratch,
	decode_scratch:   []u8, // MESH_PAGE_SCRATCH_BYTES of each worker of jobs, at least one
	decoders:         []asset.Stream_Decoder, // of each worker of jobs, at least one
	streamed:         [dynamic]u32, // the handles of the meshes with a Mesh_Stream
	next_id:          u32,
	jobs:             ^jobs.Job_System, // the pages decode in its jobs; nil: on the calling thread
	request_buffer:   rhi.Buffer, // the requests of the frame (PAGE_REQUEST_FIRST, then a table of Page_Request)
	request_capacity: u32, // entries of the table
	stamp_buffer:     rhi.Buffer, // the stamp of the last frame that drew each slot
	request_readback: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	stamp_readback:   [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	readback_frame:   [rhi.MAX_FRAMES_IN_FLIGHT]u64, // frame + 1 of what each holds; 0: nothing
	stamps_clear:     bool, // the stamp buffer is zeroed before the next frame stamps it
	// Of the last frame.
	requested, loaded, evicted, dropped: u32,
	short_frames:     u32, // in a row with requests dropped or no room for a page
	problem_buffer:   [512]u8,
}

@(private)
page_resident :: #force_inline proc "contextless" (stream: ^Mesh_Stream, page: u32) -> bool {
	return page >= stream.root || stream.slots[page] != PAGE_SLOT_NONE
}

@(private)
page_parents :: #force_inline proc "contextless" (stream: ^Mesh_Stream, page: u32) -> []u32 {
	return stream.parents[stream.parent_first[page]:stream.parent_first[page + 1]]
}

@(private)
page_parents_resident :: proc "contextless" (stream: ^Mesh_Stream, page: u32) -> bool {
	for parent in page_parents(stream, page) {if !page_resident(stream, parent) {return false}}
	return true
}

// The region of the slots, reserved once, and the tables and GPU buffers of
// the streaming. False without it: then streamed meshes keep their root alone.
@(private)
pages_region_ensure :: proc(r: ^Renderer) -> bool {
	s := &r.scene
	st := &s.pages
	if st.tried {return st.slot_count > 0}
	st.tried = true
	slots := u32(min(r.settings.page_pool_bytes / (PAGE_SLOT_WORDS * 4), PAGE_SLOTS_MAX))
	if slots == 0 {return false}
	words := int(slots) * PAGE_SLOT_WORDS
	a := r.allocator
	ok := false
	defer if !ok {
		pages_buffers_destroy(r)
		delete(st.slots, a);delete(st.free);delete(st.requests);delete(st.victims)
		st.slots, st.free, st.requests, st.victims = nil, nil, nil, nil
		st.refused = true
	}
	if !pool_room(r, .Vertex, words) {return false}
	error: mem.Allocator_Error
	if st.slots, error = make([]Page_Slot, slots, a); error != nil {return false}
	if st.free, error = make([dynamic]u32, 0, slots, a); error != nil {return false}
	if st.requests, error = make([dynamic]Page_Request, 0, PAGE_REQUEST_START, a); error != nil {return false}
	if st.victims, error = make([dynamic]Page_Victim, 0, slots, a); error != nil {return false}
	if d := r.device; d != nil {
		st.stamp_buffer = rhi.buffer_create(d, {size = u64(slots) * 4, usage = {.Storage}, name = "page stamps"})
		if st.stamp_buffer == 0 || !page_table_make(r, PAGE_REQUEST_START) {return false}
		for &b in st.stamp_readback {
			b = rhi.buffer_create(d, {size = u64(slots) * 4, memory = .Readback, name = "page stamps readback"})
			if b == 0 {return false}
		}
	}
	at := len(s.vertices)
	// A slot holds nothing until a page loads into it.
	if !pool_reserve(&s.vertices, words) || non_zero_resize(&s.vertices, at + words) != nil {return false}
	st.region, st.slot_count = u32(at), slots
	for &slot in st.slots {slot = {mesh = GPU_NONE}}
	for k := slots; k > 0; k -= 1 {append(&st.free, k - 1)}
	st.stamps_clear = true
	st.readback_frame = {}
	s.geometry_dirty = true
	ok = true
	return true
}

// The table of the requests with entries entries and its readbacks, in place
// of those there were, whose requests are dropped. False without memory: then
// nothing asks for pages or stamps them.
@(private)
page_table_make :: proc(r: ^Renderer, entries: u32) -> bool {
	st := &r.scene.pages
	bytes := u64(PAGE_REQUEST_FIRST * 4) + u64(entries) * size_of(Page_Request)
	if st.request_buffer != 0 {rhi.buffer_destroy(r.device, st.request_buffer)}
	st.request_buffer = rhi.buffer_create(r.device, {size = bytes, usage = {.Storage}, name = "page requests"})
	made := st.request_buffer != 0
	for &b in st.request_readback {
		if b != 0 {rhi.buffer_destroy(r.device, b)}
		b = rhi.buffer_create(r.device, {size = bytes, memory = .Readback, name = "page requests readback"})
		made &&= b != 0
	}
	st.request_capacity = entries if made else 0
	st.readback_frame = {}
	return made
}

@(private)
pages_buffers_destroy :: proc(r: ^Renderer) {
	st := &r.scene.pages
	if r.device == nil {return}
	for b in ([]rhi.Buffer{st.request_buffer, st.stamp_buffer}) {if b != 0 {rhi.buffer_destroy(r.device, b)}}
	for k in 0 ..< rhi.MAX_FRAMES_IN_FLIGHT {
		if st.request_readback[k] != 0 {rhi.buffer_destroy(r.device, st.request_readback[k])}
		if st.stamp_readback[k] != 0 {rhi.buffer_destroy(r.device, st.stamp_readback[k])}
	}
	st.request_buffer, st.stamp_buffer, st.request_readback, st.stamp_readback, st.request_capacity = 0, 0, {}, {}, 0
}

@(private)
pages_destroy :: proc(r: ^Renderer) {
	st := &r.scene.pages
	pages_buffers_destroy(r)
	a := r.allocator
	delete(st.slots, a);delete(st.free);delete(st.requests);delete(st.victims);delete(st.scratch.words, a);delete(st.scratch.coded, a);delete(st.decode_scratch, a);delete(st.streamed)
	asset.stream_decoder_destroy(&st.scratch.decoder)
	for &d in st.decoders {asset.stream_decoder_destroy(&d)}
	delete(st.decoders, a)
	st^ = {}
}

// What a streamed mesh keeps: its pages and their blocks, the parents of each
// page and the ray cuts (rays, those made for it) each holds clusters of, in
// a, where it lives until the mesh goes. Any thread; nil without memory.
@(private)
mesh_stream_build :: proc(g: asset.Mesh_Geometry, rays: ^Mesh_Rays, a: mem.Allocator) -> ^Mesh_Stream {
	stream, error := new(Mesh_Stream, a)
	if error != nil {return nil}
	stream.allocator = a
	ok := false
	defer if !ok {mesh_stream_free(stream)}
	count := len(g.pages)
	if stream.pages, error = make([]asset.Mesh_Page, count, a); error != nil {return nil}
	if stream.data, error = make([]u8, len(g.page_data), a); error != nil {return nil}
	if stream.slots, error = make([]u32, count, a); error != nil {return nil}
	if stream.children, error = make([]u32, count, a); error != nil {return nil}
	if stream.parent_first, error = make([]u32, count + 1, a); error != nil {return nil}
	if stream.cuts, error = make([]u8, count, a); error != nil {return nil}
	copy(stream.pages, g.pages)
	copy(stream.data, g.page_data)
	slice.fill(stream.slots, PAGE_SLOT_NONE)
	stream.flags, stream.root = g.flags, g.root_page
	// The clusters come by page: a page names a parent page once, the first
	// time one of its clusters holds it as its children's.
	last := make([]u32, count, context.temp_allocator)
	slice.fill(last, PAGE_SLOT_NONE)
	pairs := 0
	for c in g.clusters {
		if c.child_page == asset.MESH_PAGE_NONE || last[c.child_page] == c.page {continue}
		last[c.child_page] = c.page
		stream.parent_first[c.child_page + 1] += 1
		pairs += 1
	}
	for k in 0 ..< count {stream.parent_first[k + 1] += stream.parent_first[k]}
	if stream.parents, error = make([]u32, pairs, a); error != nil {return nil}
	slice.fill(last, PAGE_SLOT_NONE)
	filled := make([]u32, count, context.temp_allocator)
	for c in g.clusters {
		if c.child_page == asset.MESH_PAGE_NONE || last[c.child_page] == c.page {continue}
		last[c.child_page] = c.page
		stream.parents[stream.parent_first[c.child_page] + filled[c.child_page]] = c.page
		filled[c.child_page] += 1
	}
	for cut, k in rays.cuts[:rays.count] {
		for primitive in cut.primitives {stream.cuts[g.clusters[primitive >> PRIMITIVE_TRIANGLE_BITS].page] |= 1 << u8(k)}
	}
	for bits in stream.cuts[:stream.root] {
		for k in 0 ..< asset.MESH_RAY_LEVELS {if bits & (1 << u8(k)) != 0 {stream.cut_missing[k] += 1}}
	}
	ok = true
	return stream
}

// A stream the renderer takes gets its id; the first one reserves the region
// of the slots. A load transaction; false without memory.
@(private)
mesh_stream_start :: proc(r: ^Renderer, stream: ^Mesh_Stream) -> bool {
	st := &r.scene.pages
	pages_region_ensure(r)
	if st.scratch.words == nil {
		words, error := make([]u32, asset.MESH_PAGE_WORDS, r.allocator)
		if error != nil {return false}
		st.scratch.words = words
	}
	if st.scratch.coded == nil {
		coded, error := make([]u8, asset.MESH_PAGE_SCRATCH_BYTES, r.allocator)
		if error != nil {return false}
		st.scratch.coded = coded
	}
	if st.scratch.decoder.data == nil && asset.stream_decoder_init(&st.scratch.decoder, r.allocator) != .None {return false}
	if st.decode_scratch == nil {
		workers := jobs.worker_count(st.jobs) if st.jobs != nil else 1
		coded, error := make([]u8, max(workers, 1) * asset.MESH_PAGE_SCRATCH_BYTES, r.allocator)
		if error != nil {return false}
		decoders, decoders_error := make([]asset.Stream_Decoder, max(workers, 1), r.allocator)
		if decoders_error != nil {delete(coded, r.allocator);return false}
		for &d in decoders {
			if asset.stream_decoder_init(&d, r.allocator) == .None {continue}
			for &made in decoders {asset.stream_decoder_destroy(&made)}
			delete(decoders, r.allocator);delete(coded, r.allocator)
			return false
		}
		st.decode_scratch, st.decoders = coded, decoders
	}
	st.next_id = st.next_id + 1 if st.next_id + 1 != 0 else 1
	stream.id = st.next_id
	return true
}

@(private)
mesh_stream_free :: proc(stream: ^Mesh_Stream) {
	if stream == nil {return}
	a := stream.allocator
	delete(stream.pages, a);delete(stream.data, a);delete(stream.slots, a);delete(stream.children, a)
	delete(stream.parent_first, a);delete(stream.parents, a);delete(stream.cuts, a)
	free(stream, a)
}

// A mesh that streams goes: its slots are free again. Its entries go with its block.
@(private)
mesh_stream_remove :: proc(r: ^Renderer, handle: u32, stream: ^Mesh_Stream) {
	st := &r.scene.pages
	for slot in stream.slots[:stream.root] {
		if slot == PAGE_SLOT_NONE {continue}
		st.slots[slot] = {mesh = GPU_NONE}
		append(&st.free, slot)
	}
	for known, at in st.streamed {if known == handle {unordered_remove(&st.streamed, at);break}}
	if st.scratch.stream == stream.id {st.scratch.stream = 0}
	mesh_stream_free(stream)
}

// Writes the base of a page in the page table of its mesh.
@(private)
page_entry_write :: proc(s: ^Scene_State, m: Mesh_Record, page, base: u32) {
	word := m.page_word + page * PAGE_ENTRY_WORDS
	s.indices[word] = base
	range_add(&s.pool_dirty[.Index], {word, 1})
	s.geometry_dirty = true
	// The clusters the maps of the shadows take of its instances change with the page.
	low, high := Vec3(max(f32)), Vec3(-max(f32))
	for index := m.first_instance; index >= 0; index = s.instance_next[index] {
		inst := s.instances[index]
		if inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED) != 0 {continue}
		low, high = linalg.min(low, inst.bounds_min.xyz), linalg.max(high, inst.bounds_max.xyz)
	}
	occluder_add(&s.paged, OCCLUDERS_MANY, low, high)
}

// Whether a ray cut an instance traced within RAY_CUT_KEEP frames takes clusters of a page.
@(private)
page_traced :: proc "contextless" (r: ^Renderer, m: Mesh_Record, page: u32) -> bool {
	bits := m.stream.cuts[page]
	for k in 0 ..< int(m.ray_count) {
		traced := m.rays[k].traced
		if bits & (1 << u8(k)) != 0 && traced > 0 && r.frame + 1 - traced <= RAY_CUT_KEEP {return true}
	}
	return false
}

// A page leaves its slot: its entry goes back to GPU_NONE, and the slot is free.
@(private)
page_release :: proc(r: ^Renderer, slot: u32) {
	s := &r.scene
	st := &s.pages
	held := st.slots[slot]
	m := s.meshes[held.mesh]
	stream := m.stream
	stream.slots[held.page] = PAGE_SLOT_NONE
	page_entry_write(s, m, held.page, GPU_NONE)
	for parent in page_parents(stream, held.page) {stream.children[parent] -= 1}
	for k in 0 ..< asset.MESH_RAY_LEVELS {
		if stream.cuts[held.page] & (1 << u8(k)) == 0 {continue}
		// The instances that trace the cut choose another.
		if stream.cut_missing[k] == 0 {s.ray_cuts_stale = true}
		stream.cut_missing[k] += 1
	}
	st.slots[slot] = {mesh = GPU_NONE}
	append(&st.free, slot)
}

// A slot for a page of a mesh: a free one, or that of the page drawn least
// recently, not within PAGE_KEEP frames, without children in the pools, not
// in a ray cut traced and not a parent of the page. False when none is. The
// first eviction of a frame sorts by stamp the slots that may give theirs up,
// and the next ones go on along that list.
@(private)
page_slot_take :: proc(r: ^Renderer, stream: ^Mesh_Stream, page: u32) -> (u32, bool) {
	s := &r.scene
	st := &s.pages
	if len(st.free) > 0 {return pop(&st.free), true}
	if !st.victims_sorted {
		st.victims_sorted = true
		clear(&st.victims)
		for held, k in st.slots {
			if held.mesh == GPU_NONE || held.stamp + PAGE_KEEP > r.frame + 1 {continue}
			m := s.meshes[held.mesh]
			if !page_traced(r, m, held.page) && !mesh_whole(r, m) {append(&st.victims, Page_Victim{held.stamp, u32(k)})}
		}
		slice.sort_by(st.victims[:], proc(a, b: Page_Victim) -> bool {return a.stamp > b.stamp})
	}
	for len(st.victims) > 0 {
		victim := pop(&st.victims).slot
		// Children loaded this frame keep it, and so does being a parent of the
		// page, which then holds it as a parent once it loads.
		held := st.slots[victim]
		m := s.meshes[held.mesh]
		if m.stream.children[held.page] > 0 || m.stream == stream && slice.contains(page_parents(stream, page), held.page) {continue}
		page_release(r, victim)
		st.evicted += 1
		return pop(&st.free), true
	}
	return 0, false
}

// A page takes a slot: it counts in the pools for its parents and its cuts.
// Its entry waits for its block.
@(private)
page_assign :: proc(r: ^Renderer, stream: ^Mesh_Stream, page, slot: u32) {
	s := &r.scene
	stream.slots[page] = slot
	s.pages.slots[slot] = {stream.mesh, page, r.frame + 1}
	for parent in page_parents(stream, page) {stream.children[parent] += 1}
	for k in 0 ..< asset.MESH_RAY_LEVELS {
		if stream.cuts[page] & (1 << u8(k)) == 0 {continue}
		stream.cut_missing[k] -= 1
		// The instances that want the cut may trace it now.
		if stream.cut_missing[k] == 0 {s.ray_cuts_stale = true}
	}
}

// Loads the pages requests ask for, which it reorders: the most wanted first
// (a page asked twice loads once), while their parents are in the pools and
// up to PAGE_LOAD_WORDS. Decoded in the jobs of the renderer when it has
// them. How many it loaded.
@(private)
pages_load :: proc(r: ^Renderer, requests: []Page_Request) -> int {
	s := &r.scene
	st := &s.pages
	if st.slot_count == 0 {return 0}
	st.victims_sorted = false
	kept := 0
	for request in requests {
		if int(request.mesh) >= len(s.meshes) {continue}
		stream := s.meshes[request.mesh].stream
		if stream == nil || request.page >= stream.root || stream.slots[request.page] != PAGE_SLOT_NONE {continue}
		requests[kept] = request
		kept += 1
	}
	wanted := requests[:kept]
	// Ties by page: the order the GPU listed them in does not matter.
	slice.sort_by(wanted, proc(a, b: Page_Request) -> bool {
		return a.priority > b.priority || a.priority == b.priority && (a.mesh < b.mesh || a.mesh == b.mesh && a.page < b.page)
	})
	st.requested += u32(kept)
	st.load_count = 0
	words := 0
	loads: for request, at in wanted {
		stream := s.meshes[request.mesh].stream
		// A page whose parents are not all in the pools takes, in its place,
		// those of them whose own parents are: a fine group can be the child
		// of coarse clusters of several pages, and the view may ask for one.
		page := request.page
		for depth := 0; !page_parents_resident(stream, page); depth += 1 {
			missing := asset.MESH_PAGE_NONE
			for parent in page_parents(stream, page) {if !page_resident(stream, parent) && parent < stream.root {missing = parent;break}}
			if missing == asset.MESH_PAGE_NONE || depth == len(stream.pages) {continue loads}
			page = missing
		}
		if st.load_count == PAGE_LOADS_MAX {break}
		if stream.slots[page] != PAGE_SLOT_NONE || page_loading(st, stream, page) {continue}
		size := int(stream.pages[page].words)
		if st.load_count > 0 && words + size > PAGE_LOAD_WORDS {break}
		slot, found := page_slot_take(r, stream, page)
		if !found {
			st.dropped += u32(len(wanted) - at)
			break
		}
		page_assign(r, stream, page, slot)
		st.loads[st.load_count] = {stream = stream, page = page, slot = slot}
		st.load_count += 1
		words += size
	}
	pages_decode(r)
	loaded := 0
	for load in st.loads[:st.load_count] {
		m := s.meshes[load.stream.mesh]
		// A page that does not decode, or whose parents did not, leaves.
		if !load.ok || !page_parents_resident(load.stream, load.page) {
			page_release(r, load.slot)
			continue
		}
		base := st.region + load.slot * PAGE_SLOT_WORDS
		page_entry_write(s, m, load.page, base)
		range_add(&s.pool_dirty[.Vertex], {base, load.stream.pages[load.page].words})
		loaded += 1
	}
	st.loaded += u32(loaded)
	st.load_count = 0
	return loaded
}

// Whether a page is among the loads of this frame already.
@(private = "file")
page_loading :: proc(st: ^Pages_State, stream: ^Mesh_Stream, page: u32) -> bool {
	for load in st.loads[:st.load_count] {if load.stream == stream && load.page == page {return true}}
	return false
}

// Decodes the loads into the CPU copy of their slots.
@(private)
pages_decode :: proc(r: ^Renderer) {
	Decode :: struct {loads: []Page_Load, vertices: []u32, region: u32, scratch: []u8, decoders: []asset.Stream_Decoder}
	st := &r.scene.pages
	decode := Decode{st.loads[:st.load_count], r.scene.vertices[:], st.region, st.decode_scratch, st.decoders}
	run :: proc(d: ^Decode, first, last: int, worker: int) {
		scratch: []u8
		decoder: ^asset.Stream_Decoder
		if (worker + 1) * asset.MESH_PAGE_SCRATCH_BYTES <= len(d.scratch) && worker < len(d.decoders) {
			scratch = d.scratch[worker * asset.MESH_PAGE_SCRATCH_BYTES:][:asset.MESH_PAGE_SCRATCH_BYTES]
			decoder = &d.decoders[worker]
		}
		for &load in d.loads[first:last] {
			page := load.stream.pages[load.page]
			out := d.vertices[d.region + load.slot * PAGE_SLOT_WORDS:][:PAGE_SLOT_WORDS]
			load.ok = asset.mesh_page_decode(load.stream.flags, page, load.stream.data, scratch, out, decoder)
		}
	}
	if js := st.jobs; js != nil && jobs.worker_count(js) > 1 && len(decode.loads) > 1 {
		jobs.parallel_for(js, jobs.OWNER, len(decode.loads), 1, run, &decode)
	} else {
		run(&decode, 0, len(decode.loads), jobs.OWNER)
	}
}

// The pages of the ray cuts instances want that are not in the pools and
// whose parents are, to the requests, with priority 0: rays trace a cut once
// all its pages are there.
@(private)
pages_ray_requests :: proc(r: ^Renderer) {
	s := &r.scene
	for handle in s.pages.streamed {
		m := s.meshes[handle]
		stream := m.stream
		always := ray_cut_always(m)
		for k in 0 ..< int(m.ray_count) {
			if k == always || stream.cut_missing[k] == 0 || !ray_cut_wanted(r, m, k) {continue}
			for page in 0 ..< stream.root {
				if stream.cuts[page] & (1 << u8(k)) == 0 || stream.slots[page] != PAGE_SLOT_NONE || !page_parents_resident(stream, page) {continue}
				append(&s.pages.requests, Page_Request{mesh = handle, page = page})
			}
		}
	}
}

// Whether an extension drew the mesh whole within the frames a page in use
// keeps its slot (frame_mesh_whole).
@(private)
mesh_whole :: #force_inline proc "contextless" (r: ^Renderer, m: Mesh_Record) -> bool {
	return m.whole > 0 && r.frame + 1 - m.whole <= PAGE_KEEP
}

// The pages out of the pools of the meshes extensions draw whole, to the requests.
@(private)
pages_whole_requests :: proc(r: ^Renderer) {
	s := &r.scene
	for handle in s.pages.streamed {
		m := s.meshes[handle]
		if !mesh_whole(r, m) {continue}
		for page in 0 ..< m.stream.root {
			if m.stream.slots[page] == PAGE_SLOT_NONE {append(&s.pages.requests, Page_Request{mesh = handle, page = page})}
		}
	}
}

// Reads what the cull of the frame that used slot last stamped and asked
// for, and loads the pages it, the ray cuts and the meshes drawn whole want.
@(private)
pages_update :: proc(r: ^Renderer, slot: int) {
	st := &r.scene.pages
	st.requested, st.loaded, st.evicted, st.dropped = 0, 0, 0, 0
	if st.slot_count == 0 {return}
	clear(&st.requests)
	grow := false
	if frame := st.readback_frame[slot]; frame > 0 && r.device != nil {
		if mapped := rhi.buffer_mapped(r.device, st.stamp_readback[slot]); mapped != nil {
			stamps := ([^]u32)(mapped)[:st.slot_count]
			for &held, k in st.slots {
				if held.mesh == GPU_NONE || stamps[k] == 0 {continue}
				// The stamps are the low words of frame + 1.
				full := frame &~ u64(max(u32)) | u64(stamps[k])
				if full > frame {full -= 1 << 32}
				held.stamp = max(held.stamp, full)
			}
		}
		if mapped := rhi.buffer_mapped(r.device, st.request_readback[slot]); mapped != nil {
			words := ([^]u32)(mapped)
			for request in ([^]Page_Request)(&words[PAGE_REQUEST_FIRST])[:st.request_capacity] {
				if request.key != 0 {append(&st.requests, request)}
			}
			// The pages listed, and the requests that found no entry.
			st.dropped += words[1]
			grow = words[1] > 0 || 2 * words[0] > st.request_capacity
		}
		st.readback_frame[slot] = 0
	}
	pages_ray_requests(r)
	pages_whole_requests(r)
	pages_load(r, st.requests[:])
	st.short_frames = st.short_frames + 1 if st.dropped > 0 else 0
	if grow {page_table_make(r, st.request_capacity * 2)}
}

// The parameters of the cull for the slots (Params_Block.pages of cull_common.slang).
@(private)
pages_cull_params :: proc "contextless" (r: ^Renderer) -> [4]u32 {
	st := &r.scene.pages
	if st.slot_count == 0 || st.request_capacity == 0 {return {}}
	return {st.region, st.slot_count, u32(r.frame + 1), st.request_capacity}
}

// The table of the requests starts empty in each frame, before any cull.
@(private)
pages_record_begin :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	st := &r.scene.pages
	if st.request_capacity == 0 {return}
	if st.stamps_clear {
		rhi.cmd_fill_buffer(cmd, st.stamp_buffer, 0, u64(st.slot_count) * 4, 0)
		st.stamps_clear = false
	}
	rhi.cmd_fill_buffer(cmd, st.request_buffer, 0, rhi.buffer_size(r.device, st.request_buffer), 0)
}

// What the cull of the frame asked for and stamped goes back to the CPU.
@(private)
pages_record_end :: proc(r: ^Renderer, cmd: ^rhi.Command_List, slot: int) {
	st := &r.scene.pages
	if st.request_capacity == 0 {return}
	rhi.cmd_copy_buffer(cmd, st.request_buffer, 0, st.request_readback[slot], 0, rhi.buffer_size(r.device, st.request_buffer))
	rhi.cmd_copy_buffer(cmd, st.stamp_buffer, 0, st.stamp_readback[slot], 0, u64(st.slot_count) * 4)
	rhi.cmd_barrier_buffer(cmd, st.request_readback[slot], .Host_Read)
	rhi.cmd_barrier_buffer(cmd, st.stamp_readback[slot], .Host_Read)
	st.readback_frame[slot] = r.frame + 1
}

// The counts of the pages for Stats.
@(private)
pages_stats :: proc(r: ^Renderer, s: ^Stats) {
	st := &r.scene.pages
	s.page_slots = st.slot_count
	s.pages_resident = st.slot_count - u32(len(st.free))
	s.pages_requested, s.pages_loaded, s.pages_evicted, s.page_requests_dropped = st.requested, st.loaded, st.evicted, st.dropped
	s.page_region_bytes = u64(st.slot_count) * PAGE_SLOT_WORDS * 4
}

// What the slots could not do, and how to avoid it; "" when nothing.
@(private)
pages_problem :: proc(r: ^Renderer) -> string {
	st := &r.scene.pages
	MB :: f64(1 << 20)
	if st.refused {
		return fmt.bprintf(st.problem_buffer[:], "the GPU has no memory for the %.0f MB of page slots (Settings.page_pool_bytes): streamed meshes draw their root pages alone, coarse near the eye. A smaller page_pool_bytes fits", f64(r.settings.page_pool_bytes) / MB)
	}
	if st.short_frames >= PAGE_SHORT_FRAMES {
		return fmt.bprintf(st.problem_buffer[:], "the %d page slots (%.0f MB) are short of what the views ask for: %d pages waited in the last frame and meshes near the eye stay coarser. A larger Settings.page_pool_bytes, or a larger lod_error_pixels, avoids it", st.slot_count, f64(u64(st.slot_count) * PAGE_SLOT_WORDS * 4) / MB, st.dropped)
	}
	return ""
}
