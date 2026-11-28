package mirai_render

import "mirai:asset"
import "mirai:rhi"

// Dynamic textures: one level of an uncompressed format that the CPU writes
// rows of in any frame (Frame_Desc.texture_writes) or an extension copies
// from one of its buffers on the GPU (pass_texture_copy). Materials sample
// them by texture_index as any other; they never stream nor count against
// the pool. Making and removing one (texture_remove) is a load transaction
// between frames; a write is not, and allocates nothing.

// Rows of a dynamic texture the CPU gives in a frame, from the top, tightly
// packed. rows: the first row and how many; zero: all of them. The texels
// are read while the frame is recorded: they live until renderer_frame
// returns.
Texture_Write :: struct {
	texture: Texture_Handle,
	texels:  []u8,
	rows:    [2]u32,
}

// Why a dynamic texture or a write of one is refused.
Texture_Dynamic_Problem :: enum u8 {
	None,
	Size,       // a side of 0 or past the largest the device takes
	Format,     // a block format, which the CPU does not write row by row
	Srgb,       // srgb for a format other than RGBA8
	Gone,       // no texture of that handle
	Not_Dynamic, // a texture of another kind, which only loads replace
	Rows,       // rows past the bottom of the texture
	Bytes,      // texels that are not width * rows * texel size bytes
	Not_Finite, // a half float that is infinite or not a number
}

// The format a dynamic texture of an asset format is created in; Undefined
// for a format a dynamic texture cannot have.
texture_dynamic_format :: proc "contextless" (format: asset.Texture_Format, srgb: bool) -> rhi.Format {
	#partial switch format {
	case .RGBA8:   return .RGBA8_Srgb if srgb else .RGBA8_Unorm
	case .R8:      return .R8_Unorm
	case .RGBA16:  return .RGBA16_Unorm
	case .RGBA16F: return .RGBA16_Float
	}
	return .Undefined
}

// Whether a dynamic texture can be made of a size and format, with pixels
// (nil: zeros) for all of it.
texture_dynamic_check :: proc "contextless" (width, height, max_size: u32, format: asset.Texture_Format, srgb: bool, pixels: []u8) -> Texture_Dynamic_Problem {
	if width == 0 || height == 0 || width > max_size || height > max_size {return .Size}
	if texture_dynamic_format(format, false) == .Undefined {return .Format}
	if srgb && format != .RGBA8 {return .Srgb}
	if pixels == nil {return .None}
	if u64(len(pixels)) != u64(width) * u64(height) * u64(asset.texture_level_size(format, 1, 1)) {return .Bytes}
	if format == .RGBA16F && !halves_finite(pixels) {return .Not_Finite}
	return .None
}

// Whether a write fits the dynamic texture of a handle as the state holds
// it now, and the region of the texture it covers.
texture_write_check :: proc "contextless" (state: ^Texture_State, write: Texture_Write) -> (problem: Texture_Dynamic_Problem, region: rhi.Texture_Region) {
	index := int(write.texture) - 1
	if index < 0 || index >= state.count || state.textures[index] == 0 {return .Gone, {}}
	format := state.dynamic_format[index]
	if format == .Undefined {return .Not_Dynamic, {}}
	width, height := u32(state.sizes[index].x), u32(state.sizes[index].y)
	first, count := write.rows[0], write.rows[1]
	if write.rows == {} {first, count = 0, height}
	if count == 0 || first >= height || count > height - first {return .Rows, {}}
	if u64(len(write.texels)) != u64(width) * u64(count) * u64(rhi.format_size(format)) {return .Bytes, {}}
	if format == .RGBA16_Float && !halves_finite(write.texels) {return .Not_Finite, {}}
	return .None, {0, first, width, count}
}

// Every half float of bytes is finite: its exponent is not all ones.
@(private)
halves_finite :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) % 2 != 0 {return false}
	for i := 1; i < len(bytes); i += 2 {
		if bytes[i] & 0x7c == 0x7c {return false}
	}
	return true
}

@(private)
texture_dynamic_error :: proc(r: ^Renderer, problem: Texture_Dynamic_Problem, name: string, handle: Texture_Handle = 0, rows: [2]u32 = {}, bytes := 0) {
	switch problem {
	case .None:
	case .Size:        set_error(r, "dynamic texture %s: give it sides from 1 to %d texels", name, rhi.device_info(r.device).max_texture_size)
	case .Format:      set_error(r, "dynamic texture %s: make it RGBA8, R8, RGBA16 or RGBA16F; block formats are cooked, not written", name)
	case .Srgb:        set_error(r, "dynamic texture %s: only RGBA8 is stored as sRGB; pass srgb=false or make it RGBA8", name)
	case .Gone:        set_error(r, "texture write: texture %d is gone; make a new one with texture_add_dynamic", handle)
	case .Not_Dynamic: set_error(r, "texture write: texture %d was not made by texture_add_dynamic, so only a load replaces it", handle)
	case .Rows:        set_error(r, "texture write to %d: rows %d to %d lie past its %d rows", handle, rows[0], u64(rows[0]) + u64(rows[1]), r.textures.sizes[handle - 1].y)
	case .Bytes:       set_error(r, "%s: %d bytes are not width * rows * texel size; give tightly packed rows from the top", name, bytes)
	case .Not_Finite:  set_error(r, "%s: a half float is infinite or not a number; write finite values", name)
	}
}

// A dynamic texture of one level, of the pixels (rows from the top, tightly
// packed) or of zeros without them. srgb only for RGBA8. texture_remove
// frees it. Between frames.
texture_add_dynamic :: proc(r: ^Renderer, width, height: u32, format: asset.Texture_Format, srgb: bool, name: string, pixels: []u8 = nil) -> (Texture_Handle, bool) {
	if problem := texture_dynamic_check(width, height, rhi.device_info(r.device).max_texture_size, format, srgb, pixels); problem != .None {
		texture_dynamic_error(r, problem, name, bytes = len(pixels))
		return 0, false
	}
	state := &r.textures
	index := texture_slot(state)
	if !textures_room(r, index, name) {return 0, false}
	gpu_format := texture_dynamic_format(format, srgb)
	texel := u32(rhi.format_size(gpu_format))
	texture := rhi.texture_create(r.device, {width = width, height = height, format = gpu_format, usage = {.Sampled}, name = name})
	if texture == 0 {
		set_error(r, "dynamic texture %s: %s", name, rhi.device_error(r.device))
		return 0, false
	}
	// A new image of Vulkan holds whatever its memory held before.
	data := pixels
	if data == nil {
		zeros, error := make([]u8, int(width) * int(height) * int(texel), r.allocator)
		if error != nil {
			set_error(r, "dynamic texture %s: out of memory for its %dx%d texels", name, width, height)
			rhi.texture_destroy(r.device, texture)
			return 0, false
		}
		data = zeros
	}
	defer if pixels == nil {delete(data, r.allocator)}
	if !rhi.texture_upload(r.device, texture, data, width * texel) || !rhi.texture_table_set(r.device, texture_entry(index), texture) {
		set_error(r, "dynamic texture %s: %s", name, rhi.device_error(r.device))
		rhi.texture_destroy(r.device, texture)
		return 0, false
	}
	state.textures[index] = texture
	state.keys[index] = 0
	state.sizes[index] = {int(width), int(height)}
	state.stored[index] = 0
	state.partial[index] = false
	state.dynamic_format[index] = gpu_format
	texture_stream_forget(state, index)
	state.count = max(state.count, index + 1)
	return Texture_Handle(index + 1), true
}

// Whether a write fits its dynamic texture now; the error of the renderer
// says why not.
texture_write_valid :: proc(r: ^Renderer, write: Texture_Write) -> bool {
	problem, _ := texture_write_check(&r.textures, write)
	if problem != .None {texture_dynamic_error(r, problem, "texture write", write.texture, write.rows, len(write.texels))}
	return problem == .None
}

// The writes of a frame, before its passes: each one checked again, as a
// texture may have gone since it was asked for. They are never held back by
// the budget of uploads; a write that finds no room in the ring of the frame
// is dropped with an error.
@(private)
texture_writes_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List, writes: []Texture_Write) {
	state := &r.textures
	for write in writes {
		problem, region := texture_write_check(state, write)
		if problem != .None {
			texture_dynamic_error(r, problem, "texture write", write.texture, write.rows, len(write.texels))
			continue
		}
		ring := rhi.frame_alloc(r.device, u64(len(write.texels)), 16)
		if ring.ptr == nil {
			set_error(r, "texture write to %d: %s", write.texture, rhi.device_error(r.device))
			continue
		}
		copy(([^]u8)(ring.ptr)[:len(write.texels)], write.texels)
		texture := state.textures[write.texture - 1]
		rhi.cmd_copy_buffer_to_texture(cmd, ring.buffer, ring.offset, texture, 0, region)
		rhi.cmd_barrier_texture(cmd, texture, .Shader_Read)
	}
}
