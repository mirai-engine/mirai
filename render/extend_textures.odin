package mirai_render

import "mirai:rhi"

// Copies rows of a dynamic texture (texture_add_dynamic) from a buffer of the
// world of the pass (pass_buffer) at offset, a multiple of 16, tightly packed
// from the top, outside a pass of draws: the materials of the views after it
// and of the next frames read them. rows: the first row and how many; zero:
// all of them. False for a texture that is gone or not dynamic, rows past its
// bottom, or a buffer that does not hold them.
pass_texture_copy :: proc(s: ^Stage_Pass, buffer: Extension_Buffer_Desc, offset: u64, handle: Texture_Handle, rows: [2]u32 = {}) -> bool {
	r := s.pass.r
	state := &r.textures
	index := int(handle) - 1
	if index < 0 || index >= state.count || state.textures[index] == 0 || state.dynamic_format[index] == .Undefined {return false}
	width, height := u32(state.sizes[index].x), u32(state.sizes[index].y)
	first, count := rows[0], rows[1]
	if rows == {} {first, count = 0, height}
	if count == 0 || first >= height || count > height - first {return false}
	source := extension_buffer_find(r, s.world, buffer)
	bytes := u64(width) * u64(count) * u64(rhi.format_size(state.dynamic_format[index]))
	if source == nil || offset % 16 != 0 || offset > source.size || bytes > source.size - offset {return false}
	texture := state.textures[index]
	rhi.cmd_copy_buffer_to_texture(s.pass.cmd, source.buffer, offset, texture, 0, {0, first, width, count})
	rhi.cmd_barrier_texture(s.pass.cmd, texture, .Shader_Read)
	return true
}
