package mirai_render

import "core:math/linalg"
import "core:math"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// Every mode of inspection draws a frame without errors of the device, says
// what it cannot show and why, changing it keeps the targets of the view,
// and the modes of other passes show what those passes left: shadows under a
// box, more lights where more of them reach.
@(test)
debug_views_show_their_buffers_and_say_what_they_cannot_show :: proc(t: ^testing.T) {
	device, _ := shared_device.take(t)
	if device == nil {
		if !rhi.gpu_skip_allowed() {testing.expect(t, false, "no GPU device (set MIRAI_ALLOW_GPU_SKIP=1 to skip)")}
		return
	}
	settings := DEFAULT_SETTINGS
	settings.taa = false
	r:=new(Renderer);defer free(r)
	if !testing.expect(t, renderer_init(r, {device = device, width = 96, height = 96, settings = settings}), r.error) {return}
	defer renderer_destroy(r)
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	normals := [6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for n, face in normals {
		u := Vec3{n.y, n.z, n.x}
		v := linalg.cross(n, u)
		corners := [4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}
		for c, i in corners {vertices[face * 4 + i] = {position = c * 0.5, normal = n, color = {1, 1, 1}}}
		base := u32(face * 4)
		for q, i in ([6]u32{base, base + 1, base + 2, base, base + 2, base + 3}) {indices[face * 6 + i] = q}
	}
	cube, _ := mesh_add(r, vertices[:], indices[:])
	floor, box := Mat4(1), Mat4(1)
	floor[0, 0], floor[1, 1], floor[2, 2], floor[1, 3] = 10, 0.1, 10, -0.05
	box[1, 3] = 0.5
	instances := []Instance_Desc{{object_id = 1, mesh = cube, transform = floor, tint = {0.8, 0.8, 0.8}}, {object_id = 2, mesh = cube, transform = box, tint = {0.8, 0.3, 0.2}}}
	// Four lights over the left half, none over the right.
	lights: [4]Light_Desc
	for &light, i in lights {light = {position = {-2 + 0.3 * f32(i), 1.2, -0.5 + 0.3 * f32(i)}, color = {1, 1, 1}, intensity = 1 * math.PI, range = 2.5, radius = 0.05}}
	scene_set(r, instances, lights[:], {direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}, {sky = {0.2, 0.3, 0.5}})
	camera := Camera{position = {0, 6, 0.001}, forward = {0, -6, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 3 {renderer_frame(r, {camera = camera})}
	albedo := r.main.targets.albedo

	read :: proc(r: ^Renderer, values: []f16) -> bool {return rhi.texture_read(r.device, r.main.targets.display, ([^]u8)(raw_data(values))[:len(values) * 2])}
	width := int(r.main.targets.width)
	display := make([]f16, width * int(r.main.targets.height) * 4, context.temp_allocator)
	at :: proc(display: []f16, width: int, x, y: int) -> Vec3 {
		i := (y * width + x) * 4
		return {f32(display[i]), f32(display[i + 1]), f32(display[i + 2])}
	}
	for mode in Debug_View {
		available, reason := renderer_debug_view_status(r, mode)
		testing.expectf(t, available == (reason == ""), "%v: available %v with reason %q", mode, available, reason)
		for _ in 0 ..< 2 {testing.expectf(t, renderer_frame(r, {camera = camera, inspection = {mode = mode}}), "%v: %s", mode, r.error)}
	}
	testing.expect_value(t, r.main.targets.albedo, albedo)
	// The scene has no smooth material.
	reflections, _ := renderer_debug_view_status(r, .Reflections)
	testing.expect(t, !reflections)
	shadows, _ := renderer_debug_view_status(r, .Shadows)
	testing.expect(t, shadows)
	// What the views can show is what the pipeline they were last drawn with leaves.
	testing.expect(t, renderer_main_pipeline(r, renderer_standard_pipeline(r, .Light)))
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	shadows, _ = renderer_debug_view_status(r, .Shadows)
	testing.expect(t, shadows, "the Light pipeline takes the direct light from its samples too")

	// Shadows: the floor beside the box is lit, under its shadow less.
	for _ in 0 ..< 4 {renderer_frame(r, {camera = camera, inspection = {mode = .Shadows}})}
	if !testing.expect(t, read(r, display)) {return}
	lit_side := at(display, width, width / 2, width / 2 + 30)
	testing.expectf(t, lit_side.x > 0.9, "the floor away from the box lets the light through: %v", lit_side)
	// Lights: more reach the left of the view than the right.
	renderer_frame(r, {camera = camera, inspection = {mode = .Lights}})
	if !testing.expect(t, read(r, display)) {return}
	left, right := at(display, width, width / 2 - 30, width / 2), at(display, width, width / 2 + 40, width / 2)
	testing.expectf(t, linalg.length(left - Vec3{0.03, 0.03, 0.03}) > 0.1 && linalg.length(right - Vec3{0.03, 0.03, 0.03}) < 0.01, "lights reach the left (%v) and not the right (%v)", left, right)
}
