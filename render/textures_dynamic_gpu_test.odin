package mirai_render

import "core:slice"
import "core:testing"
import "mirai:rhi"

// Dynamic textures start with their pixels or with zeros, and the rows a
// frame writes are what every pass of that frame samples: an emitter that
// shows one turns from red to green in the frame that writes green, and the
// textures read back exactly what was written, whole or by rows. A write to a
// texture removed before the frame is refused and the others still land.
@(test)
dynamic_textures_take_their_writes_before_the_passes_of_the_frame :: proc(t: ^testing.T) {
	f: Fixture
	settings := DEFAULT_SETTINGS
	settings.gi_enabled, settings.taa = false, false
	if !fixture_init(t, &f, 64, 64, settings, hardware_rt = false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device

	red, green: [2 * 2 * 4]u8
	for i in 0 ..< 4 {
		red[i * 4], red[i * 4 + 3] = 255, 255
		green[i * 4 + 1], green[i * 4 + 3] = 255, 255
	}
	color, color_ok := texture_add_dynamic(r, 2, 2, .RGBA8, true, "dynamic color", red[:])
	mask, mask_ok := texture_add_dynamic(r, 3, 2, .R8, false, "dynamic mask")
	field, field_ok := texture_add_dynamic(r, 2, 3, .RGBA16F, false, "dynamic field")
	gone, gone_ok := texture_add_dynamic(r, 1, 1, .RGBA8, false, "dynamic gone")
	if !testing.expect(t, color_ok && mask_ok && field_ok && gone_ok, r.error) {return}
	_, refused := texture_add_dynamic(r, 2, 2, .R8, true, "dynamic srgb mask")
	testing.expect(t, !refused && r.error != "", "only RGBA8 is stored as sRGB")
	testing.expect(t, texture_index(r, color) != GPU_NONE && texture_size(r, mask) == {3, 2})

	read :: proc(r: ^Renderer, handle: Texture_Handle, out: []u8) -> bool {return rhi.texture_read(r.device, r.textures.textures[handle - 1], out)}
	color_back: [16]u8
	mask_back: [6]u8
	field_back: [2 * 3 * 4]f16
	testing.expect(t, read(r, color, color_back[:]) && color_back == red, "a dynamic texture starts with its pixels")
	testing.expect(t, read(r, mask, mask_back[:]) && mask_back == {}, "one without pixels starts at zero")
	testing.expect(t, read(r, field, slice.to_bytes(field_back[:])) && field_back == {}, "one without pixels starts at zero")

	quad: Mesh_Handle
	{
		corners := [4]Vec3{{-0.5, 0, -0.5}, {0.5, 0, -0.5}, {0.5, 0, 0.5}, {-0.5, 0, 0.5}}
		vertices: [4]Mesh_Vertex
		for c, i in corners {vertices[i] = {position = c, normal = {0, 1, 0}, tangent = {1, 0, 0, 1}, uv = {c.x + 0.5, c.z + 0.5}, color = {1, 1, 1}}}
		indices := [6]u32{0, 2, 1, 0, 3, 2}
		added: bool
		quad, added = mesh_add(r, vertices[:], indices[:])
		if !testing.expect(t, added, r.error) {return}
	}
	lamp := DEFAULT_MATERIAL
	lamp.base_color, lamp.emission = {0, 0, 0}, {1, 1, 1}
	lamp.textures[.Emission] = color
	materials_set(r, {lamp})
	floor := Mat4(1)
	floor[0, 0], floor[1, 1], floor[2, 2] = 8, 8, 8
	testing.expect(t, scene_update(r, 0, {{object_id = 1, mesh = quad, transform = floor, material = 1, tint = {1, 1, 1}}}, true))
	camera := Camera{position = {0, 2, 0}, forward = {0, -1, 0}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	centre :: proc(t: ^testing.T, r: ^Renderer) -> (rgb: [3]u8) {
		rhi.device_wait_idle(r.device)
		pixels, w, h, ok := renderer_capture(r, context.temp_allocator)
		if !testing.expect(t, ok, r.error) {return}
		at := ((h / 2) * w + w / 2) * 4
		return {pixels[at], pixels[at + 1], pixels[at + 2]}
	}
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	before := centre(t, r)
	testing.expectf(t, before.r > before.g + 40, "the emitter shows the red it started with: %v", before)

	testing.expect(t, texture_remove(r, gone))
	mask_row := [3]u8{10, 20, 30}
	halves: [2 * 3 * 4]f16
	for &h, i in halves {h = f16(f32(i) * 0.25 - 1)}
	last_row: [2 * 4]f16
	for &h, i in last_row {h = f16(100 + f32(i))}
	writes := []Texture_Write{
		{color, green[:], {}},
		{gone, red[:4], {}},
		{mask, mask_row[:], {1, 1}},
		{field, slice.to_bytes(halves[:]), {}},
		{field, slice.to_bytes(last_row[:]), {2, 1}},
	}
	testing.expect(t, renderer_frame(r, {camera = camera, texture_writes = writes}), r.error)
	testing.expect(t, r.error != "", "the write to the removed texture is refused")
	after := centre(t, r)
	testing.expectf(t, after.g > after.r + 40, "the frame that writes green samples green: %v", after)

	testing.expect(t, read(r, color, color_back[:]) && color_back == green, "the whole write lands")
	testing.expectf(t, read(r, mask, mask_back[:]) && mask_back == {0, 0, 0, 10, 20, 30}, "rows of R8 land alone: %v", mask_back)
	want := halves
	copy(want[2 * 2 * 4:], last_row[:])
	testing.expectf(t, read(r, field, slice.to_bytes(field_back[:])) && field_back == want, "rows of RGBA16F land after the whole write: %v", field_back)

	for handle in ([]Texture_Handle{color, mask, field}) {testing.expect(t, texture_remove(r, handle))}
	testing.expect(t, renderer_frame(r, {camera = camera, texture_writes = writes[:1]}), r.error)
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}
