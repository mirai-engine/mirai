package mirai_render

import "mirai:rhi"
import "mirai:std/base"

// Textures of the table that an extension fills on the GPU each frame and
// that materials read as any other (mirai_sample_texture): of a world, under
// a name, RGBA16F, one level, copied from one of its buffers
// (pass_table_texture_copy). The renderer keeps one until the extension
// releases it (table_texture_release) or the renderer closes. Making one, or
// one of another size, is a load transaction between frames (table_texture):
// a stable frame makes nothing.

Table_Texture_Desc :: struct {
	name:          string,
	width, height: u32,
}

EXTENSION_TABLE_TEXTURE_CAPACITY :: 16

@(private)
Extension_Table_Texture :: struct {
	key:           u64, // of its name; 0: a free place
	world:         u64,
	width, height: u32,
	handle:        Texture_Handle,
	texture:       rhi.Texture,
}

// The table texture of a world under a description, made the first time,
// black, and made again with another size, between frames. index: its place
// in the table, what a material samples it by. made: it was now.
table_texture :: proc(r: ^Renderer, world: u64, desc: Table_Texture_Desc) -> (index: u32, made, ok: bool) {
	entry: ^Extension_Table_Texture
	if entry, made = extension_table_texture(r, world, desc); entry == nil {return}
	return texture_entry(int(entry.handle) - 1), made, true
}

// Copies the texels of a table texture of the world of the pass from a
// buffer of the world (pass_buffer) at offset, rows of width texels of four
// halves, outside a pass of draws: the materials of the views after it and of
// the next frames read them. False for a texture table_texture did not make
// with that size, or a buffer that does not hold them.
pass_table_texture_copy :: proc(s: ^Stage_Pass, buffer: Extension_Buffer_Desc, offset: u64, desc: Table_Texture_Desc) -> bool {
	r := s.pass.r
	key := base.name_hash(desc.name) | 1
	source := extension_buffer_find(r, s.world, buffer)
	if source == nil || offset % 16 != 0 || offset + u64(desc.width) * u64(desc.height) * 8 > source.size {return false}
	for &entry in r.table_textures {
		if entry.key != key || entry.world != s.world {continue}
		if entry.width != desc.width || entry.height != desc.height || !extension_table_texture_held(r, &entry) {return false}
		rhi.cmd_copy_buffer_to_texture(s.pass.cmd, source.buffer, offset, entry.texture)
		rhi.cmd_barrier_texture(s.pass.cmd, entry.texture, .Shader_Read)
		return true
	}
	return false
}

// Releases the table texture of a world under a name; false without one.
table_texture_release :: proc(r: ^Renderer, world: u64, name: string) -> bool {
	key := base.name_hash(name) | 1
	for &entry in r.table_textures {
		if entry.key != key || entry.world != world {continue}
		if extension_table_texture_held(r, &entry) {texture_remove(r, entry.handle)}
		entry = {}
		return true
	}
	return false
}

@(private)
extension_table_textures_destroy :: proc(r: ^Renderer) {
	for &entry in r.table_textures {
		if entry.key != 0 && extension_table_texture_held(r, &entry) {texture_remove(r, entry.handle)}
		entry = {}
	}
}

// Whether the table still holds the texture of an entry: a transaction that
// drops what it brought (textures_truncate) may have taken its place.
@(private)
extension_table_texture_held :: proc(r: ^Renderer, entry: ^Extension_Table_Texture) -> bool {
	index := int(entry.handle) - 1
	return entry.handle != 0 && index < r.textures.count && r.textures.textures[index] == entry.texture
}

@(private)
extension_table_texture :: proc(r: ^Renderer, world: u64, desc: Table_Texture_Desc) -> (entry: ^Extension_Table_Texture, made: bool) {
	if desc.width == 0 || desc.height == 0 || desc.width > 8192 || desc.height > 8192 {
		set_error(r, "table texture %s: give it a size from 1 to 8192 texels", desc.name)
		return
	}
	key := base.name_hash(desc.name) | 1
	free: ^Extension_Table_Texture
	for &place in r.table_textures {
		if place.key == key && place.world == world {entry = &place; break}
		if place.key == 0 && free == nil {free = &place}
	}
	if entry != nil && entry.width == desc.width && entry.height == desc.height && extension_table_texture_held(r, entry) {return entry, false}
	if entry != nil {
		if extension_table_texture_held(r, entry) {texture_remove(r, entry.handle)}
		entry^ = {}
	} else if free == nil {
		set_error(r, "table texture %s: the renderer has no room for more than %d", desc.name, EXTENSION_TABLE_TEXTURE_CAPACITY)
		return nil, false
	} else {
		entry = free
	}
	state := &r.textures
	index := texture_slot(state)
	if !textures_room(r, index, desc.name) {return nil, false}
	texture := rhi.texture_create(r.device, {width = desc.width, height = desc.height, format = .RGBA16_Float, usage = {.Sampled}, name = desc.name})
	if texture == 0 {
		set_error(r, "table texture %s: %s", desc.name, rhi.device_error(r.device))
		return nil, false
	}
	black, error := make([]u8, int(desc.width) * int(desc.height) * 8, r.allocator)
	if error != nil || !rhi.texture_upload(r.device, texture, black, desc.width * 8) {
		set_error(r, "table texture %s: %s", desc.name, rhi.device_error(r.device))
		delete(black, r.allocator)
		rhi.texture_destroy(r.device, texture)
		return nil, false
	}
	delete(black, r.allocator)
	if !rhi.texture_table_set(r.device, texture_entry(index), texture) {
		set_error(r, "table texture %s: %s", desc.name, rhi.device_error(r.device))
		rhi.texture_destroy(r.device, texture)
		return nil, false
	}
	state.textures[index] = texture
	state.keys[index] = 0
	state.sizes[index] = {int(desc.width), int(desc.height)}
	state.count = max(state.count, index + 1)
	entry^ = {key = key, world = world, width = desc.width, height = desc.height, handle = Texture_Handle(index + 1), texture = texture}
	return entry, true
}
