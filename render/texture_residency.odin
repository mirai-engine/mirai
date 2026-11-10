package mirai_render

import "core:hash"
import "core:math"
import "mirai:asset"
import "mirai:render/abi"
import "mirai:rhi"

// Residency of the levels of a texture by what the GPU samples. A texture
// whose levels its loader can read again (Texture_Data.source) is streamed: it
// holds the levels of its source from the one the frames sampled it at, and
// its loader reads and gives another range of levels (texture_requests,
// texture_levels_set) when that changes. The passes that shade surfaces (the
// G-buffer, the glass layers, traced reflections and lighting, the probe
// rays, the material points of programs) write, for each texture they sample,
// the finest level they read into a buffer with an atomic minimum
// (texture_feedback in scene.slang), which comes back to the CPU as the page
// requests do. A raster sample reports the level its footprint and the bias
// read; a ray the level its cone at the hit reads; a program, every level.
// A texture asks for a finer level as soon as a frame reads it and lets one
// go only when TEXTURE_FEEDBACK_FRAMES frames read it TEXTURE_KEEP_LEVELS
// coarser; one no frame reads keeps the levels it has, and while the pool of
// textures has no room those give levels up first (texture_targets). Giving
// a range of levels is a transaction: a texture of its own replaces the
// entry, whose handle stays.

// Texels of side of the levels a streamed texture holds whatever it shows:
// what a load brings first (assets of a section). A .tex stores them so that
// they decode alone.
TEXTURE_TAIL :: asset.TEXTURE_TAIL
// log2(1.25): a level stays until the frames read it 1.25 times coarser, as
// what streams by distance (scene.RESIDENT_KEEP).
TEXTURE_KEEP_LEVELS :: f32(0.32192809)
// Frames whose feedback a texture takes the coarsest level of before it lets
// levels go, and after which one no frame read is unseen.
TEXTURE_FEEDBACK_FRAMES :: 60
TEXTURE_FEEDBACK_FIRST :: abi.TEXTURE_FEEDBACK_FIRST
TEXTURE_FEEDBACK_SLOT :: abi.TEXTURE_FEEDBACK_SLOT
TEXTURE_FEEDBACK_LOW :: f32(abi.TEXTURE_FEEDBACK_LOW)
TEXTURE_FEEDBACK_STEPS :: f32(abi.TEXTURE_FEEDBACK_STEPS)
// A texture no pass sampled in the frame.
TEXTURE_FEEDBACK_NONE :: max(u32)

// A texture whose levels follow what the GPU samples of it.
Texture_Stream :: struct {
	chain:  [rhi.MAX_TEXTURE_MIPS]u64, // bytes of the levels of its source from each one to its last
	size:   [2]u32,                    // of the level 0 of its source
	format: rhi.Format,
	levels: u8,   // its source has; 0: not streamed, it keeps the levels it was given
	top:    u8,   // the level of its source its first resident level is
	target: u8,   // the one it should have (texture_targets)
	shown:  bool, // a frame of the last TEXTURE_FEEDBACK_FRAMES sampled it
	width:  f32,  // log2 of the width of its source
	lod:    f32,  // the finest level of its source the frames sample
	window: f32,  // the finest level sampled in the frames of the window under way; max(f32): none
	stamp:  u32,  // grows with each texture that takes its entry and each range of levels it gets
}

// Levels a loader should give a texture: those of its source from `level`.
Texture_Request :: struct {
	handle: Texture_Handle,
	level:  int,
	stamp:  u32, // texture_levels_set refuses a request whose texture changed since
}

Texture_Residency :: struct {
	streams:   [dynamic]Texture_Stream, // by handle - 1, as long as the textures of Texture_State
	retarget:  bool, // what the textures should have is chosen again before the next requests
	pending:   int,  // streamed textures whose levels are not their target
	reduced:   int,  // shown streamed textures held coarser than the frames sample by the pool
	frames:    int,  // feedback taken in the window under way
	uploads:   [TEXTURE_UPLOADS]Texture_Upload,
	// The buffer the passes write (TEXTURE_FEEDBACK_FIRST words, then one per
	// texture of room) and where each frame in flight copies it.
	feedback:  rhi.Buffer,
	room:      int,
	readbacks: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	written:   [rhi.MAX_FRAMES_IN_FLIGHT]int, // textures each readback holds; 0: none
	recording: bool, // the frame being recorded writes feedback
	views:     u64,  // key of the views of the last frame that wrote feedback (feedback_views)
	changed:   u64,  // frame + 1 of the first frame after other views or another texture
	read:      u64,  // frame + 1 of the last feedback taken
	read_from: [rhi.MAX_FRAMES_IN_FLIGHT]u64,
}

TEXTURE_UPLOADS :: 8 // streamed textures that take their levels over frames at once

// A streamed texture that takes the levels a request asked for over frames
// (texture_levels_queue): its rows go to the GPU in the list of the frame,
// those of all of them the part of UPLOAD_FRAME_BYTES textures_upload_budget
// gives, and once all of them are there the texture takes its entry of the
// table. The caller keeps the levels until texture_upload_pending says they
// went.
@(private)
Texture_Upload :: struct {
	request: Texture_Request,
	texture: rhi.Texture,
	data:    Texture_Data,
	mip:     int,
	row:     u32, // of rows of blocks, or of texels, of its mip
	bytes:   u64,
	active:  bool,
	done:    bool, // its rows went in a frame: it takes its entry before the next (texture_uploads_install)
}

// Room in the feedback for `room` textures: a buffer and its readbacks of
// that size, made when the table grows (textures_room).
@(private)
textures_feedback_reserve :: proc(r: ^Renderer, room: int) -> bool {
	t := &r.textures.residency
	if r.device == nil || room <= t.room {return true}
	bytes := u64(TEXTURE_FEEDBACK_FIRST + room) * 4
	feedback := rhi.buffer_create(r.device, {size = bytes, usage = {.Storage}, name = "texture feedback"})
	if feedback == 0 {return false}
	readbacks: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer
	for &readback in readbacks {
		readback = rhi.buffer_create(r.device, {size = u64(room) * 4, memory = .Readback, name = "texture feedback readback"})
		if readback != 0 {continue}
		rhi.buffer_destroy(r.device, feedback)
		for made in readbacks {if made != 0 {rhi.buffer_destroy(r.device, made)}}
		return false
	}
	textures_feedback_release(r)
	t.feedback, t.readbacks, t.room = feedback, readbacks, room
	return true
}

@(private)
textures_feedback_release :: proc(r: ^Renderer) {
	t := &r.textures.residency
	if r.device == nil {return}
	if t.feedback != 0 {rhi.buffer_destroy(r.device, t.feedback)}
	for readback in t.readbacks {if readback != 0 {rhi.buffer_destroy(r.device, readback)}}
	t.feedback, t.readbacks, t.room, t.written = 0, {}, 0, {}
}

// The feedback of a frame starts empty, before any pass samples a texture:
// its first word says how many textures the passes may write, none in a
// frame the window does not show (a preview of another world) unless it
// waits for its textures (Frame_Desc.streamed).
@(private)
textures_feedback_begin :: proc(r: ^Renderer, cmd: ^rhi.Command_List, frame: Frame_Desc) -> bool {
	t := &r.textures.residency
	if t.feedback == 0 {return true}
	room := min(r.textures.count, t.room)
	t.recording = !frame.ui_only && (!frame.offscreen || frame.streamed) && room > 0
	count := [1]u32{u32(room) if t.recording else 0}
	if !upload_transient(r, cmd, count[:], t.feedback) {return false}
	if t.recording {
		rhi.cmd_fill_buffer(cmd, t.feedback, TEXTURE_FEEDBACK_FIRST * 4, u64(room) * 4, 0xff)
		views := feedback_views(frame)
		if views != t.views {t.changed = r.frame + 1}
		t.views = views
	}
	rhi.cmd_barrier_buffer(cmd, t.feedback, .Shader_Write)
	return true
}

// A key of the cameras a frame sees the scene from: another one is another
// view whose feedback has not come back.
@(private = "file")
feedback_views :: proc(frame: Frame_Desc) -> u64 {
	frame := frame
	key := hash.fnv64a(([^]u8)(&frame.camera)[:size_of(Camera)])
	if frame.detail.on {key = hash.fnv64a(([^]u8)(&frame.detail.camera)[:size_of(Camera)], key)}
	for &view in frame.views {
		if view.disabled {continue}
		key = hash.fnv64a(([^]u8)(&view.camera)[:size_of(Camera)], key)
		key = hash.fnv64a(([^]u8)(&view.rect)[:size_of(view.rect)], key)
	}
	return key
}

// The feedback where the stages that report what they sample write it
// (MIRAI_TEXTURE_FEEDBACK in scene.slang).
@(private)
textures_feedback_bind :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	rhi.cmd_bind_buffer(cmd, TEXTURE_FEEDBACK_SLOT, or_dummy(r, r.textures.residency.feedback))
}

// What the passes of the frame sampled goes back to the CPU.
@(private)
textures_feedback_end :: proc(r: ^Renderer, cmd: ^rhi.Command_List, slot: int) {
	t := &r.textures.residency
	if !t.recording {return}
	count := min(r.textures.count, t.room)
	rhi.cmd_barrier_buffer(cmd, t.feedback, .Transfer_Read)
	rhi.cmd_copy_buffer(cmd, t.feedback, TEXTURE_FEEDBACK_FIRST * 4, t.readbacks[slot], 0, u64(count) * 4)
	rhi.cmd_barrier_buffer(cmd, t.readbacks[slot], .Host_Read)
	t.written[slot], t.read_from[slot] = count, r.frame + 1
}

// Takes what the frame that used slot last sampled of each texture.
@(private)
textures_feedback_read :: proc(r: ^Renderer, slot: int) {
	t := &r.textures.residency
	count := t.written[slot]
	if count == 0 || r.device == nil {return}
	t.written[slot] = 0
	mapped := rhi.buffer_mapped(r.device, t.readbacks[slot])
	if mapped == nil {return}
	textures_feedback_take(t, ([^]u32)(mapped)[:count])
	t.read = t.read_from[slot]
}

// What one frame sampled of each texture, by handle - 1 (texture_feedback in
// scene.slang): log2 of the texels across the width of a texture a sample
// spans at the level it reads, less log2 of that width, in steps of
// 1/TEXTURE_FEEDBACK_STEPS from TEXTURE_FEEDBACK_LOW, or TEXTURE_FEEDBACK_NONE.
// A finer level is taken at once; the coarsest of a window of
// TEXTURE_FEEDBACK_FRAMES frames at its end, and a texture none of them
// sampled is unseen.
textures_feedback_take :: proc(t: ^Texture_Residency, codes: []u32) {
	for code, index in codes[:min(len(codes), len(t.streams))] {
		stream := &t.streams[index]
		if stream.levels == 0 || code == TEXTURE_FEEDBACK_NONE {continue}
		lod := f32(code) / TEXTURE_FEEDBACK_STEPS + TEXTURE_FEEDBACK_LOW + stream.width
		stream.window = min(stream.window, lod)
		if stream.shown && lod >= stream.lod {continue}
		stream.shown, stream.lod = true, lod
		t.retarget = true
	}
	t.frames += 1
	if t.frames < TEXTURE_FEEDBACK_FRAMES {return}
	t.frames = 0
	for &stream in t.streams {
		if stream.levels == 0 {continue}
		seen := stream.window < max(f32)
		if seen != stream.shown || seen && stream.window != stream.lod {t.retarget = true}
		stream.shown = seen
		if seen {stream.lod = stream.window}
		stream.window = max(f32)
	}
}

// Looks again, between frames, at the levels each streamed texture should
// have, if what the frames sample or the pool changed since. The streamed
// textures whose levels are not their target, and one more while the
// feedback of a frame that saw other views or textures has not come back.
textures_update :: proc(r: ^Renderer) -> int {
	t := &r.textures.residency
	if len(t.streams) == 0 {return 0}
	if t.retarget {
		t.retarget = false
		streams := t.streams[:r.textures.count]
		streamed: u64
		for &stream, index in streams {if stream.levels > 0 {streamed += r.textures.stored[index]}}
		room := max(u64)
		if pool, limited := texture_pool_room(r); limited {
			fixed := r.textures.bytes - min(streamed, r.textures.bytes)
			room = pool - min(fixed, pool)
		}
		t.reduced, t.pending = texture_targets(streams, texture_limits(r).max_size, room)
	}
	return t.pending + int(t.read < t.changed)
}

// The level of its source each streamed texture should start at:
// - the one the frames sample, from the largest max_size allows down to the
//   one of side TEXTURE_TAIL;
// - with TEXTURE_KEEP_LEVELS of hysteresis: a texture that has more levels
//   keeps them until it is sampled that much coarser;
// - one no frame samples keeps the levels it has;
// - and, while the levels of all of them take more than room bytes, those
//   no frame samples the same share of a level coarser, the least that fits,
//   and past their last level the others too.
// reduced: those shown held coarser than the frames sample; pending: those
// whose levels are not their target.
texture_targets :: proc(streams: []Texture_Stream, max_size: int, room: u64) -> (reduced, pending: int) {
	total :: proc(streams: []Texture_Stream, max_size: int, shown, unseen: f32) -> (bytes: u64) {
		for &stream in streams {
			if stream.levels > 0 {bytes += stream.chain[texture_target(&stream, max_size, shown if stream.shown else unseen)]}
		}
		return
	}
	// Bytes fall as a bias grows: the least that fits, to a fraction of a level.
	least :: proc(streams: []Texture_Stream, max_size: int, room: u64, unseen: f32, shown: bool) -> f32 {
		low, high := f32(0), f32(rhi.MAX_TEXTURE_MIPS)
		for _ in 0 ..< 16 {
			middle := (low + high) * 0.5
			if total(streams, max_size, middle if shown else 0, unseen if shown else middle) > room {low = middle} else {high = middle}
		}
		return high
	}
	shown, unseen: f32
	if total(streams, max_size, 0, 0) > room {
		unseen = f32(rhi.MAX_TEXTURE_MIPS)
		if total(streams, max_size, 0, unseen) > room {shown = least(streams, max_size, room, unseen, true)} else {unseen = least(streams, max_size, room, 0, false)}
	}
	for &stream in streams {
		if stream.levels == 0 {continue}
		stream.target = texture_target(&stream, max_size, shown if stream.shown else unseen)
		if stream.target != stream.top {pending += 1}
		if stream.shown && shown > 0 && stream.target > texture_target(&stream, max_size, 0) {reduced += 1}
	}
	return
}

// The first level a streamed texture should have, with a bias of levels.
texture_target :: proc "contextless" (stream: ^Texture_Stream, max_size: int, bias: f32) -> u8 {
	first, last := texture_level_range(stream, max_size)
	asked := clamp(stream.lod, -1, 64) if stream.shown else f32(stream.top)
	level := int(stream.top)
	if grow := int(math.floor(asked + bias)); grow < level {
		level = grow
	} else if shrink := int(math.floor(asked + bias - TEXTURE_KEEP_LEVELS)); shrink > level {
		level = shrink
	}
	return u8(clamp(level, first, last))
}

// The levels a streamed texture can start at: from the largest whose side
// max_size takes to the one of side TEXTURE_TAIL, or its last.
texture_level_range :: proc "contextless" (stream: ^Texture_Stream, max_size: int) -> (first, last: int) {
	if stream.levels == 0 {return}
	side := max(int(stream.size.x), int(stream.size.y))
	for first + 1 < int(stream.levels) && side >> uint(first) > max(max_size, 1) {first += 1}
	last = first
	for last + 1 < int(stream.levels) && side >> uint(last) > TEXTURE_TAIL {last += 1}
	return
}


// Streamed textures to read the levels of, the most urgent first: those
// that need more levels before those that have too many, unless the pool is
// past its room; the ones farthest from their target first. busy: textures
// whose levels are being read. Between frames, after textures_update.
texture_requests :: proc(r: ^Renderer, out: []Texture_Request, busy: []Texture_Handle) -> int {
	t := &r.textures.residency
	if t.pending == 0 || len(out) == 0 {return 0}
	shrink_first := false
	if pool, limited := texture_pool_room(r); limited {shrink_first = r.textures.bytes > pool}
	urgency :: proc "contextless" (stream: ^Texture_Stream, shrink_first: bool) -> int {
		grow := stream.target < stream.top
		steps := abs(int(stream.top) - int(stream.target))
		return steps + (rhi.MAX_TEXTURE_MIPS if grow != shrink_first else 0)
	}
	count := 0
	each: for &stream, index in t.streams[:r.textures.count] {
		if stream.levels == 0 || stream.target == stream.top {continue}
		handle := Texture_Handle(index + 1)
		for held in busy {if held == handle {continue each}}
		at := count
		weight := urgency(&stream, shrink_first)
		for at > 0 && urgency(&t.streams[out[at - 1].handle - 1], shrink_first) < weight {at -= 1}
		if at >= len(out) {continue}
		if count < len(out) {count += 1}
		copy(out[at + 1:count], out[at:count - 1])
		out[at] = {handle = handle, level = int(stream.target), stamp = stream.stamp}
	}
	return count
}

Texture_Levels_Result :: enum u8 {
	Set,
	Stale,    // the texture changed since the request: it was removed, replaced or given other levels
	Mismatch, // the data is not the levels of its source the request asked for
	Failed,   // the device did not take them: Renderer.error says why
	Busy,     // TEXTURE_UPLOADS textures take levels already: ask again later
}

// What a request may become: the texture with those levels, or why not.
@(private = "file")
texture_levels_check :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data) -> (texture: rhi.Texture, result: Texture_Levels_Result) {
	state := &r.textures
	index := int(request.handle) - 1
	if index < 0 || index >= state.count || state.textures[index] == 0 {return 0, .Stale}
	stream := &state.residency.streams[index]
	if stream.levels == 0 || stream.stamp != request.stamp {return 0, .Stale}
	if data.level != request.level || data.source != {int(stream.size.x), int(stream.size.y)} || len(data.levels) == 0 || data.level + len(data.levels) != int(stream.levels) {return 0, .Mismatch}
	texture = rhi.texture_create(r.device, {width = u32(data.width), height = u32(data.height), mip_levels = u32(len(data.levels)), format = data.format, usage = {.Sampled}, name = "streamed texture"})
	if texture == 0 {set_error(r, "texture levels: %s", rhi.device_error(r.device));return 0, .Failed}
	return texture, .Set
}

// The texture with the levels of a request takes its entry of the table.
@(private = "file")
texture_levels_install :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data, texture: rhi.Texture, bytes: u64) -> Texture_Levels_Result {
	state := &r.textures
	index := int(request.handle) - 1
	if index < 0 || index >= state.count || state.textures[index] == 0 || state.residency.streams[index].stamp != request.stamp {
		rhi.texture_destroy(r.device, texture)
		return .Stale
	}
	stream := &state.residency.streams[index]
	if !rhi.texture_table_set(r.device, texture_entry(index), texture) {
		set_error(r, "texture levels: %s", rhi.device_error(r.device))
		rhi.texture_destroy(r.device, texture)
		return .Failed
	}
	rhi.texture_destroy(r.device, state.textures[index])
	state.textures[index] = texture
	state.bytes = state.bytes - state.stored[index] + bytes
	state.stored[index] = bytes
	was := stream.target != stream.top
	stream.top, stream.format = u8(data.level), data.format
	texture_chain(stream)
	stream.stamp += 1
	state.residency.pending = max(state.residency.pending + int(stream.target != stream.top) - int(was), 0)
	return .Set
}

// Gives a streamed texture the levels of its source a request asked for over
// the frames that follow (texture_uploads_record): Set when they will go,
// and data is to stay as it is until texture_upload_pending is false.
texture_levels_queue :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data) -> Texture_Levels_Result {
	t := &r.textures.residency
	slot := -1
	for &upload, i in t.uploads {
		if upload.active && upload.request.handle == request.handle {return .Busy}
		if !upload.active && slot < 0 {slot = i}
	}
	if slot < 0 {return .Busy}
	texture, result := texture_levels_check(r, request, data)
	if result != .Set {return result}
	t.uploads[slot] = {request = request, texture = texture, data = data, active = true}
	return .Set
}

// Whether texture_levels_queue has room for another texture now.
texture_upload_room :: proc(r: ^Renderer) -> bool {
	for upload in r.textures.residency.uploads {if !upload.active {return true}}
	return false
}

// The first of the levels of data a texture added over frames
// (texture_add_over_frames) gets at once: the largest of side TEXTURE_TAIL
// or less. 0 when no level is larger, or when its loader cannot read the
// levels again (no source): then it goes whole.
texture_tail_first :: proc "contextless" (data: Texture_Data) -> int {
	if data.source.x <= 0 || data.source.y <= 0 || data.layers > 1 || data.cube {return 0}
	for level in 0 ..< len(data.levels) {
		if max(data.width >> uint(level), data.height >> uint(level)) <= TEXTURE_TAIL {return level}
	}
	return 0
}

// Adds a streamed texture with the levels of data from texture_tail_first
// on, at once, and gives it the larger ones over the frames that follow, as
// texture_levels_queue does: until every row of them went it is sampled with
// its small levels, never with a level half there. The levels are borrowed;
// first the largest ones the pool has no room for are left out of data.
// - Set: the larger levels go; data stays as it is while
//   texture_upload_pending(request).
// - Busy: TEXTURE_UPLOADS textures take levels already; nothing was added.
// - Mismatch: data has no larger level to give later; nothing was added.
// - Failed with no handle: the texture was not added (Renderer.error).
// Any other result with a handle leaves the texture with its small levels,
// which its distance can widen.
texture_add_over_frames :: proc(r: ^Renderer, data: ^Texture_Data, name: string) -> (handle: Texture_Handle, request: Texture_Request, result: Texture_Levels_Result) {
	if !texture_upload_room(r) {return 0, {}, .Busy}
	skip, _ := texture_pool_first(r, data^)
	if skip > 0 {
		remove_range(&data.levels, 0, skip)
		data.width, data.height, data.level = max(data.width >> uint(skip), 1), max(data.height >> uint(skip), 1), data.level + skip
	}
	now := texture_tail_first(data^)
	if now == 0 {return 0, {}, .Mismatch}
	small := Texture_Data{format = data.format, width = max(data.width >> uint(now), 1), height = max(data.height >> uint(now), 1), level = data.level + now, source = data.source}
	small.levels = make([dynamic][]u8, 0, len(data.levels) - now, context.temp_allocator)
	append(&small.levels, ..data.levels[now:])
	added: bool
	if handle, added = texture_add_data(r, small, name); !added {return 0, {}, .Failed}
	index := int(handle) - 1
	if index >= len(r.textures.residency.streams) {return handle, {}, .Stale}
	request = {handle = handle, level = data.level, stamp = r.textures.residency.streams[index].stamp}
	return handle, request, texture_levels_queue(r, request, data^)
}

// Whether the levels of a request still go to the GPU, which reads them from
// the data texture_levels_queue was given.
texture_upload_pending :: proc(r: ^Renderer, request: Texture_Request) -> bool {
	for upload in r.textures.residency.uploads {if upload.active && upload.request == request {return true}}
	return false
}

// Drops the levels that still go: before what they are read from goes.
texture_uploads_cancel :: proc(r: ^Renderer) {
	for &upload in r.textures.residency.uploads {
		if upload.active {rhi.texture_destroy(r.device, upload.texture)}
		upload = {}
	}
}

// Rows of the levels that go, their part of UPLOAD_FRAME_BYTES
// (textures_upload_budget), through the ring of the frame into the list of
// the frame; a texture whose rows all went takes its entry of the table
// before the next frame. One whose request is stale goes.
@(private)
texture_uploads_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) {
	state := &r.textures
	share := textures_upload_budget(&r.scene)
	budget := share
	defer r.scene.uploads.textures_spent = share - budget
	for &upload in state.residency.uploads {
		if !upload.active || upload.done {continue}
		index := int(upload.request.handle) - 1
		if index < 0 || index >= state.count || state.textures[index] == 0 || state.residency.streams[index].stamp != upload.request.stamp {
			rhi.texture_destroy(r.device, upload.texture)
			upload = {}
			continue
		}
		for upload.mip < len(upload.data.levels) && budget > 0 {
			width, height := u32(max(upload.data.width >> uint(upload.mip), 1)), u32(max(upload.data.height >> uint(upload.mip), 1))
			row, rows := rhi.format_rows(upload.data.format, width, height)
			block := u32(4) if rhi.format_block_size(upload.data.format) > 0 else 1
			count := u32(min(u64(rows) - u64(upload.row), max(budget / row, 1)))
			bytes := u64(count) * row
			ring := rhi.frame_alloc(r.device, bytes, 16)
			if ring.ptr == nil {budget = 0;break}
			level := upload.data.levels[upload.mip]
			copy(([^]u8)(ring.ptr)[:bytes], level[u64(upload.row) * row:][:bytes])
			y := upload.row * block
			rhi.cmd_copy_buffer_to_texture(cmd, ring.buffer, ring.offset, upload.texture, u32(upload.mip), {0, y, width, min(count * block, height - y)})
			budget -= min(bytes, budget)
			upload.bytes += bytes
			upload.row += count
			if u64(upload.row) >= u64(rows) {upload.mip, upload.row = upload.mip + 1, 0}
		}
		if upload.mip < len(upload.data.levels) {continue}
		rhi.cmd_barrier_texture(cmd, upload.texture, .Shader_Read)
		upload.done = true
	}
}

// The textures whose rows all went take their entries of the table, between
// frames: the frame after them reads them.
@(private)
texture_uploads_install :: proc(r: ^Renderer) {
	for &upload in r.textures.residency.uploads {
		if !upload.active || !upload.done {continue}
		texture_levels_install(r, upload.request, upload.data, upload.texture, upload.bytes)
		upload = {}
	}
}

// Gives a streamed texture the levels of its source a request asked for,
// as a transaction between frames: a texture with those levels takes its
// entry of the table, and its handle stays. Anything but Set changes nothing.
texture_levels_set :: proc(r: ^Renderer, request: Texture_Request, data: Texture_Data) -> Texture_Levels_Result {
	texture, result := texture_levels_check(r, request, data)
	if result != .Set {return result}
	bytes: u64
	for level in data.levels {bytes += u64(len(level))}
	if !rhi.texture_upload_levels(r.device, texture, data.levels[:]) {
		set_error(r, "texture levels: %s", rhi.device_error(r.device))
		rhi.texture_destroy(r.device, texture)
		return .Failed
	}
	return texture_levels_install(r, request, data, texture, bytes)
}

// The texture of a request keeps the levels it has from now on: its loader
// cannot read other levels of its source. Nothing when it changed since.
texture_stream_stop :: proc(r: ^Renderer, request: Texture_Request) {
	index := int(request.handle) - 1
	if index < 0 || index >= len(r.textures.residency.streams) || r.textures.residency.streams[index].stamp != request.stamp {return}
	texture_stream_forget(&r.textures, index)
}

// The stream of a texture given data, of which it holds the levels from
// `dropped` on: none for one not streamed, as an array or a cube. What shows it is not known yet.
@(private)
texture_stream_set :: proc(stream: ^Texture_Stream, data: Texture_Data, dropped: int) {
	stream^ = {stamp = stream.stamp + 1}
	if data.source.x <= 0 || data.source.y <= 0 || data.layers > 1 || data.cube || data.level + len(data.levels) > rhi.MAX_TEXTURE_MIPS {return}
	stream.size = {u32(data.source.x), u32(data.source.y)}
	stream.width = math.log2(f32(stream.size.x))
	stream.window = max(f32)
	stream.format = data.format
	stream.levels = u8(data.level + len(data.levels))
	stream.top = u8(data.level + dropped)
	stream.target = stream.top
	texture_chain(stream)
}

// The bytes of the levels of the source of a stream from each one on, in its format.
@(private)
texture_chain :: proc "contextless" (stream: ^Texture_Stream) {
	below: u64
	for level := int(stream.levels) - 1; level >= 0; level -= 1 {
		row, rows := rhi.format_rows(stream.format, max(stream.size.x >> uint(level), 1), max(stream.size.y >> uint(level), 1))
		below += row * rows
		stream.chain[level] = below
	}
}

// The entry of the table holds no streamed texture any more.
@(private)
texture_stream_forget :: proc "contextless" (state: ^Texture_State, index: int) {
	t := &state.residency
	if index < 0 || index >= len(t.streams) {return}
	stream := &t.streams[index]
	if stream.levels > 0 && stream.target != stream.top {t.pending = max(t.pending - 1, 0)}
	stream^ = {stamp = stream.stamp + 1}
	t.retarget = true
}
