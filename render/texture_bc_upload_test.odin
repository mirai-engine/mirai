package mirai_render

import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:rhi"
import "mirai:rhi/shared_device"

@(test)
the_gpu_reassembles_bc_fields_bit_for_bit :: proc(t: ^testing.T) {
	device := shared_device.take_or_skip(t, hardware_rt = false)
	if device == nil || !rhi.device_info(device).features.texture_bc {return}
	r := new(Renderer)
	defer free(r)
	if !testing.expect(t, renderer_init(r, {device = device, width = 64, height = 64}),
		r.error) {return}
	defer renderer_destroy(r)
	defer free_all(context.temp_allocator)
	// Partial edge blocks and enough rows to split the larger formats over frames.
	WIDTH :: 1031
	HEIGHT :: 4099
	for format in ([]rhi.Format{.BC1_Srgb, .BC5_Unorm, .BC6H_Ufloat, .BC7_Unorm}) {
		bc := texture_field_format(format)
		data := Texture_Data{format = format, width = WIDTH, height = HEIGHT, fields = true,
			source = {WIDTH, HEIGHT}, levels = make([dynamic][]u8, context.temp_allocator)}
		blocks := make([]u8, asset.texture_level_size(bc, WIDTH, HEIGHT), context.temp_allocator)
		stride := asset.texture_block_bytes(bc)
		for &b, i in blocks {
			// Across the rows, all mode prefixes and reserved values occur.
			b = u8(i / stride) if i % stride == 0 else u8(i * 31 + i / 7)
		}
		raw := blocks
		for i in 0..<2 {
			planes := make([]u8, asset.texture_fields_size(bc, raw), context.temp_allocator)
			if !testing.expect(t, asset.texture_fields_split(bc, raw, planes)) {return}
			append(&data.levels, planes)
			raw = blocks[:asset.texture_level_size(bc, WIDTH >> 1, HEIGHT >> 1)]
		}
		expected := make([]u8, len(blocks), context.temp_allocator)
		actual := make([]u8, len(blocks), context.temp_allocator)
		if !testing.expect(t, asset.texture_fields_join(bc, data.levels[0], expected)) {return}
		handle, added := texture_add_data(r, data, "BC planes")
		if !testing.expect(t, added, r.error) {return}
		compare :: proc(t: ^testing.T, r: ^Renderer, handle: Texture_Handle, actual, expected: []u8,
			loc := #caller_location) {
			texture := r.textures.textures[handle - 1]
			testing.expect(t, rhi.texture_read(r.device, texture, actual),
				rhi.device_error(r.device), loc = loc)
			testing.expect(t, mem.compare(actual, expected) == 0, loc = loc)
		}
		compare(t, r, handle, actual, expected)

		// Replace the first mip through the frame upload path, retaining its tail.
		stream := &r.textures.residency.streams[handle - 1]
		request := Texture_Request{handle = handle, level = 1, held = 0, stamp = stream.stamp}
		if !testing.expect_value(t, texture_levels_queue(r, request, {}), Texture_Levels_Result.Set) {
			return
		}
		record :: proc(t: ^testing.T, r: ^Renderer, loc := #caller_location) {
			cmd, ok := rhi.frame_begin(r.device, false)
			if !testing.expect(t, ok, rhi.device_error(r.device), loc = loc) {return}
			texture_uploads_record(r, cmd)
			testing.expect(t, rhi.frame_end(r.device, cmd), rhi.device_error(r.device), loc = loc)
			texture_uploads_install(r)
		}
		record(t, r)
		request = {handle = handle, level = 0, held = 1, stamp = stream.stamp}
		if !testing.expect_value(t, texture_levels_queue(r, request, data), Texture_Levels_Result.Set) {
			return
		}
		for _ in 0..<4 {
			if !texture_upload_pending(r, request) {break}
			record(t, r)
		}
		if !testing.expect(t, !texture_upload_pending(r, request)) {return}
		compare(t, r, handle, actual, expected)
		testing.expect(t, texture_remove(r, handle))
	}
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s",
		rhi.device_validation_message(device))
}
