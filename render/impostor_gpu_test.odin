package mirai_render

import "core:testing"
import "mirai:rhi"

// The frames of an impostor keep, where they cover, the roughness and the
// diffuse transmission of the material, and the color of the light it lets
// through.
@(test)
gpu_impostor_frames_keep_the_surface_of_their_material :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, 64, 64, DEFAULT_SETTINGS, hardware_rt = false) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	leaf := DEFAULT_MATERIAL
	leaf.base_color = {0.2, 0.6, 0.1}
	leaf.roughness = 0.4
	leaf.diffuse_transmission = {weight = 0.6, color = {0.5, 1, 0.25}}
	if !testing.expect(t, materials_set(r, {leaf}), r.error) {return}
	// A leaf lying flat and one standing, crossed.
	vertices := [8]Mesh_Vertex {
		{position = {-1, 0, -1}, normal = {0, 1, 0}, color = {1, 1, 1}, material = 1},
		{position = {1, 0, -1}, normal = {0, 1, 0}, color = {1, 1, 1}, material = 1},
		{position = {1, 0, 1}, normal = {0, 1, 0}, color = {1, 1, 1}, material = 1},
		{position = {-1, 0, 1}, normal = {0, 1, 0}, color = {1, 1, 1}, material = 1},
		{position = {-1, -1, 0}, normal = {0, 0, 1}, color = {1, 1, 1}, material = 1},
		{position = {1, -1, 0}, normal = {0, 0, 1}, color = {1, 1, 1}, material = 1},
		{position = {1, 1, 0}, normal = {0, 0, 1}, color = {1, 1, 1}, material = 1},
		{position = {-1, 1, 0}, normal = {0, 0, 1}, color = {1, 1, 1}, material = 1},
	}
	indices := [12]u32{0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7}
	mesh, added := mesh_add(r, vertices[:], indices[:])
	if !testing.expect(t, added, r.error) {return}
	images, captured := impostor_capture(r, {{mesh = mesh, placement = 1}}, 4, 16)
	if !testing.expect(t, captured, r.error) {return}
	defer impostor_images_destroy(&images)
	covered := 0
	for i := 0; i < len(images.color); i += 4 {
		if images.color[i + 3] != 255 {continue}
		covered += 1
		testing.expectf(t, abs(int(images.surface[i]) - 102) <= 3, "roughness 0.4: %v", images.surface[i:][:4])
		testing.expectf(t, abs(int(images.surface[i + 3]) - 153) <= 3, "transmission 0.6: %v", images.surface[i:][:4])
	}
	testing.expect(t, covered > 0, "the leaves cover some of the frames")
	want := Vec3{0.5, 1, 0.25}
	testing.expectf(t, abs(images.transmission.x - want.x) < 0.02 && abs(images.transmission.y - want.y) < 0.02 && abs(images.transmission.z - want.z) < 0.02, "the light let through: %v", images.transmission)
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}
