package mirai_render

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// A box of size 1, counter-clockwise seen from outside.
@(private = "file")
trace_box :: proc(r: ^Renderer) -> Mesh_Handle {
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	for n, face in ([6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		u := Vec3{n.y, n.z, n.x}
		v := Vec3{n.y * u.z - n.z * u.y, n.z * u.x - n.x * u.z, n.x * u.y - n.y * u.x}
		for c, i in ([4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}) {vertices[face * 4 + i] = {position = c * 0.5, normal = n, color = {1, 1, 1}}}
		base := u32(face * 4)
		quad := [6]u32{base, base + 1, base + 2, base, base + 2, base + 3}
		copy(indices[face * 6:], quad[:])
	}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	return mesh
}

@(private = "file")
trace_placed :: proc(position, scale: Vec3) -> Mat4 {
	m := Mat4(1)
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

@(private = "file")
// Where a point of the world shows, from 0 to 1 across the image from its top left corner.
trace_pixel :: proc(r: ^Renderer, camera: Camera, world: Vec3) -> [2]f32 {
	view, proj, _ := camera_matrices(camera, f32(r.targets.width) / f32(r.targets.height))
	clip := (proj * view) * Vec4{world.x, world.y, world.z, 1}
	ndc := clip.xy / clip.w
	return {ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5}
}

@(private = "file")
Trace_Image :: struct {pixels: []u8, width, height: int}

@(private = "file")
trace_frame :: proc(t: ^testing.T, r: ^Renderer, camera: Camera) -> Trace_Image {
	// A new scene: the light it gathers starts over.
	renderer_camera_cut(r)
	for _ in 0 ..< 12 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(r.device)
	pixels, width, height, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	return {pixels, width, height}
}

@(private = "file")
trace_at :: proc(image: Trace_Image, p: [2]f32) -> Vec3 {
	x, y := clamp(int(p.x * f32(image.width)), 0, image.width - 1), clamp(int(p.y * f32(image.height)), 0, image.height - 1)
	i := (y * image.width + x) * 4
	return {f32(image.pixels[i]), f32(image.pixels[i + 1]), f32(image.pixels[i + 2])}
}

// Posts on a floor in the sun, before a mirror, as instances of the scene and as a
// batch whose instances cast shadows and are seen by rays: by software rays,
// which walk the tree of the batch, and by hardware ones where there are.
@(test)
a_batch_casts_the_shadows_and_shows_in_the_reflections_of_its_instances :: proc(t: ^testing.T) {
	settings := DEFAULT_SETTINGS
	settings.occlusion_culling = false
	settings.reflections = true
	f: Fixture
	if !fixture_init(t, &f, 160, 96, settings) {return}
	defer fixture_destroy(&f)
	r, device := f.renderer, f.device
	mirror := DEFAULT_MATERIAL
	mirror.base_color, mirror.metallic, mirror.roughness = {0.9, 0.9, 0.9}, 1, 0.05
	materials_set(r, {mirror})
	box := trace_box(r)
	// A white floor takes the shadows, and a strip of mirror in front of the posts their reflections.
	floor := Instance_Desc{object_id = 1, mesh = box, transform = trace_placed({0, -0.1, 0}, {14, 0.2, 14}), tint = {0.8, 0.8, 0.8}}
	strip := Instance_Desc{object_id = 2, mesh = box, material = 1, transform = trace_placed({0, -0.09, 2}, {14, 0.2, 3}), tint = 1}
	color := Vec3{0.8, 0.3, 0.2}
	places := [3]Vec3{{-2, 1, 0}, {0, 1, 0}, {2, 1, 0}}
	posts: [5]Instance_Desc
	posts[0], posts[1] = floor, strip
	batched: [3]Batch_Instance
	for p, i in places {
		posts[i + 2] = {object_id = u64(i + 3), mesh = box, transform = trace_placed(p, {0.4, 2, 0.4}), tint = color}
		batched[i] = batch_instance(p, 1, 0.4, 2)
	}
	sun := Sun_Desc{direction = {0.70710678, 0.70710678, 0}, color = {1, 1, 1}, illuminance = 1.5 * math.PI, enabled = true}
	sky := Environment{sky = {0.3, 0.4, 0.6}}
	camera := Camera{position = {0, 7, 4}, forward = {0, -7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// The shadow of the middle post falls away from the sun; the mirror 0.75 m in front of it reflects it.
	shadow, reflection := trace_pixel(r, camera, {-1, 0, 0}), trace_pixel(r, camera, {0, 0.01, 0.75})
	for provider in ([]Trace_Mode{.Software, .Hardware}) {
		if provider == .Hardware && !r.hardware_rt_verified {continue}
		applied := r.settings
		applied.trace_mode = provider
		testing.expect(t, renderer_apply_settings(r, applied))
		scene_set(r, posts[:2], nil, sun, sky)
		empty := trace_frame(t, r, camera)
		defer delete(empty.pixels)
		scene_set(r, posts[:], nil, sun, sky)
		instanced := trace_frame(t, r, camera)
		defer delete(instanced.pixels)
		scene_set(r, posts[:2], nil, sun, sky)
		handle, error := batch_set(r, 0, r.world_key, {mesh = box, tint = color, flags = {.Casts_Shadow, .Ray_Visible}}, batched[:])
		testing.expect_value(t, error, "")
		batch := trace_frame(t, r, camera)
		defer delete(batch.pixels)
		testing.expect(t, batch_remove(r, handle))
		if len(empty.pixels) == 0 || len(instanced.pixels) == 0 || len(batch.pixels) != len(instanced.pixels) {continue}
		testing.expectf(t, trace_at(instanced, shadow).x + 30 < trace_at(empty, shadow).x, "%v: the posts cast a shadow: %v under them, %v without them", provider, trace_at(instanced, shadow), trace_at(empty, shadow))
		reflected, sky_reflected := trace_at(instanced, reflection), trace_at(empty, reflection)
		testing.expectf(t, abs(reflected.x - sky_reflected.x) + abs(reflected.z - sky_reflected.z) > 30, "%v: the floor reflects the posts: %v, %v without them", provider, reflected, sky_reflected)
		// The batch gives what its instances give: shadows, reflections and what is drawn.
		total, worst := f64(0), f32(0)
		for i in 0 ..< len(batch.pixels) / 4 {
			for c in 0 ..< 3 {
				d := abs(f32(batch.pixels[i * 4 + c]) - f32(instanced.pixels[i * 4 + c]))
				total += f64(d * d)
				worst = max(worst, d)
			}
		}
		rms := math.sqrt(total / f64(len(batch.pixels) / 4 * 3))
		testing.expectf(t, rms < 2, "%v: the batch differs from its instances by %.2f (rms of 0-255), at most %v", provider, rms, worst)
		// Half floats make the posts of the batch a hair thinner: a pixel at the edge of a shadow may differ a little.
		delta := trace_at(batch, shadow) - trace_at(instanced, shadow)
		testing.expectf(t, max(abs(delta.x), abs(delta.y), abs(delta.z)) <= 4, "%v: the shadow of the batch %v, of the instances %v", provider, trace_at(batch, shadow), trace_at(instanced, shadow))
	}
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}

// Instances of the large TLAS test; 0: as many as overflow the ring of the test.
TLAS_INSTANCES :: #config(TLAS_INSTANCES, 0)

// A native TLAS with more instances than the upload ring of the frame holds
// (64 bytes each) is built from buffers of its own: the post among them casts
// its shadow, and the renderer reports nothing it could not do. It prints
// what a frame that builds the TLAS costs the CPU against one that does not.
@(test)
a_native_tlas_larger_than_the_upload_ring_is_built_and_met :: proc(t: ^testing.T) {
	RING :: 4 << 20
	settings := DEFAULT_SETTINGS
	settings.occlusion_culling = false
	settings.trace_mode = .Hardware
	device := shared_device.create_or_skip(t, {on_message = rhi.message_print, app_name = "mirai large tlas test", validation = true, allow_hardware_ray_tracing = true, upload_bytes_per_frame = RING})
	if device == nil {return}
	defer rhi.device_destroy(device)
	renderer:=new(Renderer);defer free(renderer)
	if !testing.expect(t, renderer_init(renderer, {device = device, width = 160, height = 96, settings = settings}), renderer.error) {return}
	defer renderer_destroy(renderer)
	r := renderer
	if !r.hardware_rt_verified {fmt.eprintln("large tlas test skipped: no hardware ray tracing");return}
	box := trace_box(r)
	floor := Instance_Desc{object_id = 1, mesh = box, transform = trace_placed({0, -0.1, 0}, {14, 0.2, 14}), tint = {0.8, 0.8, 0.8}}
	// The post, then many more instances far below the floor, which no ray of the view meets.
	count := TLAS_INSTANCES if TLAS_INSTANCES > 0 else RING / 64 + 40_000
	batched := make([]Batch_Instance, count)
	defer delete(batched)
	batched[0] = batch_instance({0, 1, 0}, 1, 0.4, 2)
	for &b, i in batched[1:] {b = batch_instance({f32(i % 300) * 2 - 300, -200, f32(i / 300) * 2 - 300}, 1, 0.4, 0.4)}
	sun := Sun_Desc{direction = {0.70710678, 0.70710678, 0}, color = {1, 1, 1}, illuminance = 1.5 * math.PI, enabled = true}
	camera := Camera{position = {0, 7, 4}, forward = {0, -7, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 500, exposure = UNIT_EXPOSURE}
	shadow := trace_pixel(r, camera, {-1, 0, 0})
	scene_set(r, {floor}, nil, sun, {sky = {0.3, 0.4, 0.6}})
	empty := trace_frame(t, r, camera)
	defer delete(empty.pixels)
	_, error := batch_set(r, 0, r.world_key, {mesh = box, tint = {0.8, 0.3, 0.2}, flags = {.Casts_Shadow}}, batched)
	testing.expect_value(t, error, "")
	cast_shadow := trace_frame(t, r, camera)
	defer delete(cast_shadow.pixels)
	testing.expectf(t, r.stats.problem == "", "the renderer built its TLAS: %s", r.stats.problem)
	testing.expect(t, !r.scene.tlas_dirty, "nothing is left to build")
	if len(empty.pixels) > 0 && len(cast_shadow.pixels) == len(empty.pixels) {
		testing.expectf(t, trace_at(cast_shadow, shadow).x + 30 < trace_at(empty, shadow).x, "the post among %d instances casts its shadow: %v, %v without it", count, trace_at(cast_shadow, shadow), trace_at(empty, shadow))
	}
	FRAMES :: 16
	cost: [2]f64
	for rebuild in 0 ..< 2 {
		for frame in 0 ..< FRAMES + 2 {
			r.scene.tlas_dirty = rebuild == 1
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
			if frame >= 2 {cost[rebuild] += f64(r.stats.cpu_record_ms) / FRAMES}
		}
	}
	fmt.printfln("native TLAS of %d instances: a frame records in %.3f ms of CPU, %.3f ms when it builds the TLAS", count + 1, cost[0], cost[1])
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}
