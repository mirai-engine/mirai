package mirai_render

import "core:math"
import "mirai:rhi"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:render/abi"

// Material textures. Each one takes an entry of the RHI texture table, which
// shaders index with the number a material stores, so no pass binds a texture
// per material or per object. Adding one is a load transaction between
// frames. A cooked texture arrives with its levels in the format it is
// sampled in (texture_add_data); block compression is work of the cook. An
// image made while running (texture_add) gets its RGBA8 mip chain here.

// An entry of the texture table, plus one. 0 is no texture.
Texture_Handle :: distinct u32

// The first entries of the table hold the split-sum table of the lobe
// (DFG_TEXTURE) and the tables of the air (AIR_*_TEXTURE): the texture of a
// handle is in the entry TEXTURE_RESERVED + handle - 1. The table grows with
// the textures, up to texture_capacity.
TEXTURE_RESERVED :: abi.TEXTURE_RESERVED

Texture_Desc :: struct {
	pixels:        []u8, // RGBA8, rows from the top of the image
	width, height: int,
	srgb:           bool, // color (base color, emission): stored as sRGB, filtered and averaged as light
	normal_map:     bool, // tangent-space normals: levels are averaged as vectors and renormalized
	alpha_coverage: f32,  // above 0: the cutoff of a masked material; every level keeps the share of texels above it
	name:           string,
}

Texture_State :: struct {
	// By handle - 1, as long as the largest handle given; count, one past the last alive, is at most that.
	textures:  [dynamic]rhi.Texture,
	keys:      [dynamic]u64,
	sizes:     [dynamic][2]int,
	stored:    [dynamic]u64,  // GPU memory of each one
	partial:   [dynamic]bool, // not streamed, and left levels out to fit the pool
	count:     int,
	bytes:     u64, // GPU memory of every level
	reduced:   int, // textures not streamed that left levels out to fit the pool
	residency: Texture_Residency, // of the streamed ones
}

@(private = "file")
to_byte :: proc "contextless" (v: f32) -> u8 {
	return u8(clamp(v, 0, 1) * 255 + 0.5)
}

// Source texels a destination texel covers along one axis, with the share of
// each. A level is half the one above, rounded down: an odd size leaves every
// texel covering a little more than two.
@(private = "file")
Taps :: struct {
	first:   int,
	count:   int,
	weights: [3]f32,
}

@(private = "file")
reduce_taps :: proc(source, target, index: int) -> (taps: Taps) {
	scale := f32(source) / f32(target)
	start := f32(index) * scale
	end := start + scale
	taps.first = int(start)
	last := min(int(math.ceil(end)) - 1, source - 1)
	taps.count = min(last - taps.first + 1, len(taps.weights))
	for i in 0 ..< taps.count {
		lo := max(f32(taps.first + i), start)
		hi := min(f32(taps.first + i + 1), end)
		taps.weights[i] = max(hi - lo, 0) / scale
	}
	return
}

// Writes the next smaller level of src into dst (already sized dw * dh * 4).
@(private = "file")
texture_reduce :: proc(src: []u8, sw, sh: int, dst: []u8, dw, dh: int, decode: ^[256]f32, srgb, normal_map: bool) {
	for y in 0 ..< dh {
		rows := reduce_taps(sh, dh, y)
		for x in 0 ..< dw {
			columns := reduce_taps(sw, dw, x)
			sum: [4]f32
			for j in 0 ..< rows.count {
				for i in 0 ..< columns.count {
					w := rows.weights[j] * columns.weights[i]
					at := ((rows.first + j) * sw + columns.first + i) * 4
					sum.r += decode[src[at]] * w
					sum.g += decode[src[at + 1]] * w
					sum.b += decode[src[at + 2]] * w
					sum.a += f32(src[at + 3]) / 255 * w
				}
			}
			if normal_map {
				n := Vec3{sum.r, sum.g, sum.b} * 2 - 1
				length := math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
				n = n / length if length > 1e-6 else Vec3{0, 0, 1}
				sum.r, sum.g, sum.b = n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5
			}
			if srgb {sum.r, sum.g, sum.b = mm.linear_to_srgb(sum.r), mm.linear_to_srgb(sum.g), mm.linear_to_srgb(sum.b)}
			at := (y * dw + x) * 4
			dst[at], dst[at + 1], dst[at + 2], dst[at + 3] = to_byte(sum.r), to_byte(sum.g), to_byte(sum.b), to_byte(sum.a)
		}
	}
}

// Share of the texels whose alpha, scaled, reaches the cutoff.
@(private = "file")
alpha_coverage :: proc(pixels: []u8, cutoff, scale: f32) -> f32 {
	covered := 0
	for i := 3; i < len(pixels); i += 4 {
		if f32(pixels[i]) * scale >= cutoff * 255 {covered += 1}
	}
	return f32(covered) / f32(max(len(pixels) / 4, 1))
}

// Averaging thins a cutout: fewer texels of each smaller level pass the test,
// and foliage or a fence fades away with distance. Scaling the alpha of the
// level brings its coverage back to the one of the image (Castano 2010; the
// alpha coverage setting of Unreal textures).
@(private = "file")
alpha_coverage_keep :: proc(pixels: []u8, cutoff, wanted: f32) {
	lo, hi := f32(0), f32(8)
	for _ in 0 ..< 12 {
		scale := (lo + hi) * 0.5
		if alpha_coverage(pixels, cutoff, scale) < wanted {lo = scale} else {hi = scale}
	}
	scale := (lo + hi) * 0.5
	for i := 3; i < len(pixels); i += 4 {pixels[i] = u8(min(f32(pixels[i]) * scale + 0.5, 255))}
}

// A texture ready for the GPU: its levels to the last, the largest first, in
// the format it will be sampled in, each with its layers one after another.
// A texture of one layer whose loader can read other levels of its source
// names the source: its levels follow what the GPU samples (texture_residency.odin).
// An array or a cube takes its entry, which shaders sample as a 2D texture:
// the table shows the white default in it, and a pass binds the texture of
// the entry itself.
Texture_Data :: struct {
	format:        rhi.Format,
	width, height: int, // of its first level
	layers:        int,  // 0 or 1: one; those of an array, or six per cube
	cube:          bool, // its layers are faces of cubes (asset.Texture_Flag.Cube)
	levels:        [dynamic][]u8,
	level:         int,    // the level of the source its first level is
	source:        [2]int, // the size of the level 0 of its source; zero: it keeps these levels
}

texture_data_destroy :: proc(data: ^Texture_Data, allocator := context.allocator) {
	for level in data.levels {delete(level, allocator)}
	delete(data.levels)
	data^ = {}
}

// What the device and the settings allow of a texture: the side of its first
// level, and whether block formats are uploaded as they are. Without blocks
// whoever loads a compressed texture decodes it to RGBA8 first.
Texture_Limits :: struct {
	max_size: int,
	blocks:   bool,
}

texture_limits :: proc(r: ^Renderer) -> Texture_Limits {return texture_limits_of(r, r.settings)}

// What the device allows of a texture under some settings.
texture_limits_of :: proc(r: ^Renderer, settings: Settings) -> Texture_Limits {
	info := rhi.device_info(r.device)
	limit := min(max(settings.texture_max_size, 1), info.max_texture_size, 1 << (rhi.MAX_TEXTURE_MIPS - 1))
	return {max_size = int(limit), blocks = info.features.texture_bc}
}

// Builds the levels of a texture from its RGBA8 pixels. Images larger than
// max_size start at the first level that fits. False when the pixels do not
// hold the image or there is no memory for the levels.
texture_build :: proc(desc: Texture_Desc, max_size: int, allocator := context.allocator) -> (data: Texture_Data, ok: bool) {
	if desc.width <= 0 || desc.height <= 0 || len(desc.pixels) < desc.width * desc.height * 4 {return {}, false}
	decode: [256]f32
	for &value, i in decode {
		value = f32(i) / 255
		if desc.srgb {value = mm.srgb_to_linear(value)}
	}
	level := desc.pixels[:desc.width * desc.height * 4]
	width, height := desc.width, desc.height
	coverage := alpha_coverage(level, desc.alpha_coverage, 1) if desc.alpha_coverage > 0 else 0
	owned: []u8
	defer delete(owned, allocator)
	next :: proc(level: []u8, width, height: int, decode: ^[256]f32, desc: Texture_Desc, coverage: f32, allocator := context.allocator) -> ([]u8, int, int, bool) {
		w, h := max(width / 2, 1), max(height / 2, 1)
		reduced, error := make([]u8, w * h * 4, allocator)
		if error != nil {return nil, 0, 0, false}
		texture_reduce(level, width, height, reduced, w, h, decode, desc.srgb, desc.normal_map)
		if desc.alpha_coverage > 0 {alpha_coverage_keep(reduced, desc.alpha_coverage, coverage)}
		return reduced, w, h, true
	}
	for max(width, height) > max(max_size, 1) {
		reduced, w, h, reduced_ok := next(level, width, height, &decode, desc, coverage, allocator)
		if !reduced_ok {return {}, false}
		delete(owned, allocator)
		owned, level, width, height = reduced, reduced, w, h
	}
	data.format, data.width, data.height = .RGBA8_Srgb if desc.srgb else .RGBA8_Unorm, width, height
	data.levels = make([dynamic][]u8, allocator)
	for {
		stored, stored_error := make([]u8, len(level), allocator)
		if stored_error != nil {
			texture_data_destroy(&data, allocator)
			return {}, false
		}
		copy(stored, level)
		if _, append_error := append(&data.levels, stored); append_error != nil {
			delete(stored, allocator)
			texture_data_destroy(&data, allocator)
			return {}, false
		}
		if width == 1 && height == 1 || len(data.levels) == rhi.MAX_TEXTURE_MIPS {break}
		reduced, w, h, reduced_ok := next(level, width, height, &decode, desc, coverage, allocator)
		if !reduced_ok {
			texture_data_destroy(&data, allocator)
			return {}, false
		}
		delete(owned, allocator)
		owned, level, width, height = reduced, reduced, w, h
	}
	return data, true
}

// The most textures the renderer holds at once: what the texture table of
// its device grows to, but for the entries of its own tables.
texture_capacity :: proc(r: ^Renderer) -> int {return rhi.texture_table_limit(r.device) - TEXTURE_RESERVED}

// The entry of the texture table that the texture of handle index + 1 is in.
@(private)
texture_entry :: proc "contextless" (index: int) -> u32 {return u32(TEXTURE_RESERVED + index)}

@(private)
textures_init :: proc(r: ^Renderer) {
	state := &r.textures
	state.textures = make([dynamic]rhi.Texture, r.allocator)
	state.keys = make([dynamic]u64, r.allocator)
	state.sizes = make([dynamic][2]int, r.allocator)
	state.stored = make([dynamic]u64, r.allocator)
	state.partial = make([dynamic]bool, r.allocator)
	state.residency.streams = make([dynamic]Texture_Stream, r.allocator)
}

@(private)
textures_destroy :: proc(r: ^Renderer) {
	state := &r.textures
	delete(state.textures)
	delete(state.keys)
	delete(state.sizes)
	delete(state.stored)
	delete(state.partial)
	delete(state.residency.streams)
	textures_feedback_release(r)
}

// Makes room for the texture of handle index + 1 in what the renderer keeps
// of each texture, doubling it as the table grows. False past
// texture_capacity or without memory.
@(private)
textures_room :: proc(r: ^Renderer, index: int, name: string) -> bool {
	state := &r.textures
	if index >= texture_capacity(r) {
		set_error(r, "texture %s: the texture table is full (%d textures)", name, texture_capacity(r))
		return false
	}
	if index < len(state.textures) {return true}
	before := len(state.textures)
	fits := true
	if index >= cap(state.textures) {
		size := max(2 * cap(state.textures), rhi.TEXTURE_TABLE_FIRST, index + 1)
		fits = reserve(&state.textures, size) == nil && reserve(&state.keys, size) == nil && reserve(&state.sizes, size) == nil &&
			reserve(&state.stored, size) == nil && reserve(&state.partial, size) == nil && reserve(&state.residency.streams, size) == nil
		if fits && !textures_feedback_reserve(r, size) {
			set_error(r, "texture %s: the GPU has no memory for the feedback of %d textures: %s", name, size, rhi.device_error(r.device))
			return false
		}
	}
	fits = fits && resize(&state.textures, index + 1) == nil && resize(&state.keys, index + 1) == nil && resize(&state.sizes, index + 1) == nil &&
		resize(&state.stored, index + 1) == nil && resize(&state.partial, index + 1) == nil && resize(&state.residency.streams, index + 1) == nil
	if !fits {
		base.truncate(&state.textures, before)
		base.truncate(&state.keys, before)
		base.truncate(&state.sizes, before)
		base.truncate(&state.stored, before)
		base.truncate(&state.partial, before)
		base.truncate(&state.residency.streams, before)
		set_error(r, "texture %s: out of memory for the table of %d textures", name, index + 1)
		return false
	}
	return true
}

// Uploads a built texture and gives it an entry of the table. While the pool
// (settings.texture_pool_megabytes) has no room for all of it, its largest
// levels are left out: the texture is still there, less sharp, and one with
// a source gets them back when there is room. Fails when the table is full
// (texture_capacity).
texture_add_data :: proc(r: ^Renderer, data: Texture_Data, name: string, key:u64=0) -> (Texture_Handle, bool) {
	state := &r.textures
	if handle,_,_,found:=texture_find(r,key);found {return handle,true}
	d := r.device
	if len(data.levels) == 0 {set_error(r, "texture %s has no levels", name); return 0, false}
	if !textures_room(r, texture_slot(state), name) {return 0, false}
	first, bytes := texture_pool_first(r, data)
	width, height := max(data.width >> uint(first), 1), max(data.height >> uint(first), 1)
	levels := data.levels[first:]
	layered := data.layers > 1 || data.cube
	texture := rhi.texture_create(d, {width = u32(width), height = u32(height), layers = u32(max(data.layers, 1)), cube = data.cube, mip_levels = u32(len(levels)), format = data.format, usage = {.Sampled}, name = name})
	if texture == 0 {set_error(r, "texture %s: %s", name, rhi.device_error(d)); return 0, false}
	if !rhi.texture_upload_levels(d, texture, levels) {
		set_error(r, "texture %s: %s", name, rhi.device_error(d))
		rhi.texture_destroy(d, texture)
		return 0, false
	}
	index := texture_slot(state)
	if !rhi.texture_table_set(d, texture_entry(index), 0 if layered else texture) {
		set_error(r, "texture %s: %s", name, rhi.device_error(d))
		rhi.texture_destroy(d, texture)
		return 0, false
	}
	state.textures[index] = texture
	state.keys[index]=key
	state.sizes[index]={data.width,data.height}
	state.stored[index]=bytes
	texture_stream_set(&state.residency.streams[index], data, first)
	state.residency.retarget, state.residency.changed = true, r.frame + 1
	streamed := state.residency.streams[index].levels > 0
	state.partial[index]=first>0 && !streamed
	if state.partial[index] {state.reduced += 1}
	state.count = max(state.count, index + 1)
	state.bytes += bytes
	return Texture_Handle(index + 1), true
}

// The bytes the textures may take, and whether they have such a limit: the
// pool of the settings (texture_pool_megabytes) less what the targets of the
// views drawn into textures hold.
texture_pool_room :: proc(r: ^Renderer) -> (bytes: u64, limited: bool) {
	pool := u64(r.settings.texture_pool_megabytes) * 1024 * 1024
	return pool - min(r.texture_view_bytes, pool), pool > 0
}

// The levels of data the pool (texture_pool_room) has no room for, the
// largest, and the bytes of the others.
texture_pool_first :: proc(r: ^Renderer, data: Texture_Data) -> (first: int, bytes: u64) {
	pool, limited := texture_pool_room(r)
	for level in data.levels {bytes += u64(len(level))}
	// Never below 64 texels: a pool that small is a setting to fix, not a texture to erase.
	for limited && r.textures.bytes + bytes > pool && first + 1 < len(data.levels) && max(data.width >> uint(first + 1), data.height >> uint(first + 1)) >= 64 {
		bytes -= u64(len(data.levels[first]))
		first += 1
	}
	return
}

// A texture another process draws (rhi.texture_open_shared), as an entry of
// the table the UI shows. texture_remove releases it. Between frames.
texture_add_shared :: proc(r: ^Renderer, shared: rhi.Shared_Texture, width, height: int, format: rhi.Format, name: string) -> (Texture_Handle, bool) {
	state := &r.textures
	if !textures_room(r, texture_slot(state), name) {return 0, false}
	texture := rhi.texture_open_shared(r.device, {width = u32(width), height = u32(height), format = format, usage = {.Sampled}, name = name}, shared)
	if texture == 0 {set_error(r, "texture %s: %s", name, rhi.device_error(r.device)); return 0, false}
	index := texture_slot(state)
	if !rhi.texture_table_set(r.device, texture_entry(index), texture) {
		set_error(r, "texture %s: %s", name, rhi.device_error(r.device))
		rhi.texture_destroy(r.device, texture)
		return 0, false
	}
	state.textures[index] = texture
	state.keys[index] = 0
	state.sizes[index] = {width, height}
	texture_stream_forget(state, index)
	state.count = max(state.count, index + 1)
	return Texture_Handle(index + 1), true
}

// Builds a texture from its pixels and adds it: texture_build and
// texture_add_data in one step, for callers that keep no cache.
texture_add :: proc(r: ^Renderer, desc: Texture_Desc) -> (Texture_Handle, bool) {
	// Scratch lives on the heap: an image can exceed the per-frame arena.
	data, built := texture_build(desc, texture_limits(r).max_size)
	if !built {
		if desc.width <= 0 || desc.height <= 0 || len(desc.pixels) < desc.width * desc.height * 4 {
			set_error(r, "texture %s: %d bytes do not hold %dx%d RGBA8 pixels", desc.name, len(desc.pixels), desc.width, desc.height)
		} else {
			set_error(r, "texture %s: out of memory for its levels", desc.name)
		}
		return 0, false
	}
	defer texture_data_destroy(&data)
	return texture_add_data(r, data, desc.name)
}

// An image its owner draws again, as an editor preview: the entry of the table
// with that key, added the first time as one level of sRGB RGBA8 and given
// the new pixels after. Fails when the entry has another size. Between frames.
texture_image :: proc(r: ^Renderer, key: u64, pixels: []u8, width, height: int, name: string) -> (Texture_Handle, bool) {
	if key == 0 || width <= 0 || height <= 0 || len(pixels) < width * height * 4 {return 0, false}
	handle, w, h, found := texture_find(r, key)
	if !found {
		data := Texture_Data{format = .RGBA8_Srgb, width = width, height = height, levels = make([dynamic][]u8, 0, 1, context.temp_allocator)}
		append(&data.levels, pixels[:width * height * 4])
		return texture_add_data(r, data, name, key)
	}
	if w != width || h != height {return 0, false}
	if !rhi.texture_upload(r.device, r.textures.textures[handle - 1], pixels, u32(width) * 4) {
		set_error(r, "texture %s: %s", name, rhi.device_error(r.device))
		return 0, false
	}
	return handle, true
}

// Drops every texture. Materials that name them must be replaced with
// materials_set before the next frame.
textures_clear :: proc(r: ^Renderer) {
	texture_uploads_cancel(r)
	state := &r.textures
	for texture in state.textures[:state.count] {rhi.texture_destroy(r.device, texture)}
	for index in 0 ..< state.count {texture_stream_forget(state, index)}
	clear(&state.textures)
	clear(&state.keys)
	clear(&state.sizes)
	clear(&state.stored)
	clear(&state.partial)
	clear(&state.residency.streams)
	state.count, state.bytes, state.reduced = 0, 0, 0
	state.residency.pending = 0
}

texture_count :: proc(r: ^Renderer) -> int {return r.textures.count}

// Content/build identity shared by scene loads and preview transactions.
texture_find :: proc(r:^Renderer,key:u64)->(handle:Texture_Handle,width,height:int,found:bool) {
	if key==0 {return}
	for value,i in r.textures.keys[:r.textures.count] {if value==key {return Texture_Handle(i+1),r.textures.sizes[i][0],r.textures.sizes[i][1],true}}
	return
}

@(private)
texture_index :: proc(r: ^Renderer, handle: Texture_Handle) -> u32 {
	if handle == 0 || int(handle) > r.textures.count || r.textures.textures[handle - 1] == 0 {return max(u32)}
	return texture_entry(int(handle) - 1)
}

// What the pool holds of a texture, and whether one that does not follow its
// distance left its largest levels out to fit.
texture_stored :: proc(r: ^Renderer, handle: Texture_Handle) -> (bytes: u64, reduced: bool) {
	index := int(handle) - 1
	if index < 0 || index >= r.textures.count || r.textures.textures[index] == 0 {return 0, false}
	return r.textures.stored[index], r.textures.partial[index]
}

