package mirai_render

import "core:fmt"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// The levels of a texture go in one transaction, each at its own place of the
// staging buffer: mip 0 reads back as written with the smaller mips after it.
@(test)
the_levels_of_a_texture_upload_in_one_transaction :: proc(t: ^testing.T) {
	device, error := shared_device.take(t, hardware_rt = false)
	if device == nil {
		if rhi.gpu_skip_allowed() {fmt.eprintln("texture upload test skipped:", error)} else {testing.expect(t, false, error)}
		return
	}
	texture := rhi.texture_create(device, {width = 4, height = 4, layers = 1, mip_levels = 3, format = .RGBA8_Unorm, usage = {.Sampled, .Transfer_Src}, name = "levels test"})
	if !testing.expect(t, texture != 0, rhi.device_error(device)) {return}
	defer rhi.texture_destroy(device, texture)
	mip0 := make([]u8, 4 * 4 * 4, context.temp_allocator)
	for &v, i in mip0 {v = u8(i)}
	mip1 := make([]u8, 2 * 2 * 4, context.temp_allocator)
	mip2 := make([]u8, 4, context.temp_allocator)
	levels := [][]u8{mip0, mip1, mip2}
	testing.expect(t, rhi.texture_upload_levels(device, texture, levels), rhi.device_error(device))
	back := make([]u8, len(mip0), context.temp_allocator)
	if !testing.expect(t, rhi.texture_read(device, texture, back), rhi.device_error(device)) {return}
	for v, i in back {
		if v != mip0[i] {testing.expectf(t, false, "byte %d is %d and not %d", i, v, mip0[i]); break}
	}
}
