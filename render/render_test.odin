package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "core:time"
import "mirai:rhi"

// 0.6 scene-linear units per render unit: the exposure the bounds of the light
// tests against their reference were set with.
TUNED_EXPOSURE :: Exposure{mode = .Manual, ev100 = 1.263034 + EXPOSURE_BIAS, own = true}

@(private = "file")
expect_clean :: proc(t: ^testing.T, d: ^rhi.Device) {
	testing.expectf(t, rhi.device_validation_errors(d) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(d), rhi.device_validation_message(d))
}

// Unit cube centered at the origin with outward face normals (24 vertices).
// Every face spans the whole texture: u along the first tangent axis, v
// against the second one, so the top of the image is where that axis ends.
@(private = "file")
cube_mesh :: proc(albedo: Vec3 = {1, 1, 1}, material: Material_Handle = 0) -> ([24]Mesh_Vertex, [36]u32) {
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	normals := [6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	uv_corners := [4]Vec2{{0, 1}, {1, 1}, {1, 0}, {0, 0}}
	for n, face in normals {
		// Two tangent axes so that (u x v) == n for counter-clockwise winding.
		u := Vec3{n.y, n.z, n.x}
		v := linalg.cross(n, u)
		corners := [4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}
		for c, i in corners {vertices[face * 4 + i] = {position = c * 0.5, normal = n, uv = uv_corners[i], color = albedo, material = material}}
		base := u32(face * 4)
		quad := [6]u32{base, base + 1, base + 2, base, base + 2, base + 3}
		for q, i in quad {indices[face * 6 + i] = q}
	}
	return vertices, indices
}

@(private = "file")
trs :: proc(position, scale: Vec3) -> Mat4 {
	m := Mat4(1)
	m[0, 0], m[1, 1], m[2, 2] = scale.x, scale.y, scale.z
	m[0, 3], m[1, 3], m[2, 3] = position.x, position.y, position.z
	return m
}

@(private = "file")
project :: proc(r: ^Renderer, c: Camera, p: Vec3) -> [2]int {
	view, proj, _ := camera_matrices(c, f32(r.targets.width) / f32(r.targets.height))
	clip := (proj * view) * Vec4{p.x, p.y, p.z, 1}
	ndc := clip.xy / clip.w
	return {int((ndc.x * 0.5 + 0.5) * f32(r.targets.output_width)), int((0.5 - ndc.y * 0.5) * f32(r.targets.output_height))}
}

@(private = "file")
pixel :: proc(pixels: []u8, width: int, p: [2]int) -> [3]f32 {
	i := (p.y * width + p.x) * 4
	return {f32(pixels[i]), f32(pixels[i + 1]), f32(pixels[i + 2])}
}

@(private = "file")
Cube_Fixture :: struct {
	using base: Fixture,
	cube:       Mesh_Handle,
}

@(private = "file")
cube_fixture_init :: proc(t: ^testing.T, f: ^Cube_Fixture, width, height: u32, settings: Settings, loc := #caller_location) -> bool {
	if !fixture_init(t, f, width, height, settings, loc = loc) {return false}
	vertices, indices := cube_mesh()
	handle, added := mesh_add(f.renderer, vertices[:], indices[:])
	testing.expect(t, added)
	f.cube = handle
	return true
}

@(private = "file")
test_settings :: proc() -> Settings {
	s := DEFAULT_SETTINGS
	s.probe_budget = 4096
	s.probe_rays = 64
	s.probe_grid, s.probe_cascades = 8, 2
	s.probe_spacing = 1.5
	return s
}

@(test)
render_sun_shadow_is_ray_traced :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 192, 128, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 1.5, 0}, {2, 0.2, 2}), tint = {0.5, 0.5, 0.5}},
	}
	scene_set(r, instances, nil, {direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}, {sky = {0.3, 0.4, 0.6}})
	camera := Camera{position = {0, 8, 7}, forward = {0, -8, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 12 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	// Floor right under the slab is in shadow; far from it the floor is lit.
	// From this camera the slab hides the back half of its shadow, so sample
	// the visible front part (z = 0.8 lies under the slab, which ends at 1).
	shadow := pixel(pixels, w, project(r, camera, {0, 0.001, 0.8}))
	lit := pixel(pixels, w, project(r, camera, {3.5, 0.001, 2.5}))
	testing.expectf(t, lit[0] > shadow[0] + 40, "lit floor %v must be brighter than the shadowed floor %v", lit, shadow)
	testing.expect(t, r.stats.instances == 2)
	expect_clean(t, f.device)
}

@(test)
render_soft_shadow_blurs_with_the_distance_to_its_caster :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.sun_radius = 0.05
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 256, 192, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A wall 4 m tall under a sun 45 degrees high: the side of its shadow runs
	// from the foot of the wall, where the caster touches the floor, to 4 m
	// away, where the caster is the top of the wall, 5.7 m up the ray.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {14, 0.2, 14}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 2, 0}, {0.2, 4, 6}), tint = {0.5, 0.5, 0.5}},
	}
	scene_set(r, instances, nil, {direction = {1, 1, 0}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}, {sky = {0, 0, 0}})
	camera := Camera{position = {-2, 7, 0.001}, forward = {0, -7, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 12 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	// Metres across the side of the shadow over which the floor goes from 10 % to 90 % of its light.
	penumbra :: proc(r: ^Renderer, camera: Camera, pixels: []u8, w: int, x: f32) -> (width, dark, lit: f32) {
		dark = pixel(pixels, w, project(r, camera, {x, 0.001, 2.2}))[0]
		lit = pixel(pixels, w, project(r, camera, {x, 0.001, 3.8}))[0]
		for i in 0 ..< 80 {
			v := pixel(pixels, w, project(r, camera, {x, 0.001, 2.2 + 0.02 * f32(i)}))[0]
			if v > dark + 0.1 * (lit - dark) && v < dark + 0.9 * (lit - dark) {width += 0.02}
		}
		return
	}
	near, near_dark, near_lit := penumbra(r, camera, pixels, w, -0.5)
	far, far_dark, far_lit := penumbra(r, camera, pixels, w, -3.5)
	testing.expectf(t, near_lit > near_dark + 40 && far_lit > far_dark + 40, "the wall casts a shadow: %f to %f near it, %f to %f far from it", near_dark, near_lit, far_dark, far_lit)
	testing.expectf(t, near < 0.2, "the shadow is sharp at the foot of the wall: %f m of penumbra", near)
	testing.expectf(t, far > 2 * near && far > 0.2 && far < 0.7, "the shadow blurs away from its caster: %f m of penumbra, %f m at the foot", far, near)
	expect_clean(t, f.device)
}

@(test)
render_soft_shadow_leaves_with_its_caster :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 128, 96, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 1.5, 0}, {2, 0.2, 2}), tint = {0.5, 0.5, 0.5}},
	}
	sun := Sun_Desc{direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	scene_set(r, instances, nil, sun, {sky = {0, 0, 0}})
	camera := Camera{position = {0, 8, 7}, forward = {0, -8, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	under, beside := Vec3{0, 0.001, 0.8}, Vec3{3.5, 0.001, 2.5}
	read :: proc(t: ^testing.T, f: ^Cube_Fixture, camera: Camera, p: Vec3) -> f32 {
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		if !ok {return 0}
		defer delete(pixels)
		return pixel(pixels, w, project(f.renderer, camera, p))[0]
	}
	for _ in 0 ..< 12 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	shadowed, lit := read(t, &f, camera, under), read(t, &f, camera, beside)
	testing.expectf(t, lit > shadowed + 40, "the slab shades the floor under it: %f against %f", shadowed, lit)
	// The slab goes: its shadow has no history to fade from.
	scene_set(r, instances[:1], nil, sun, {sky = {0, 0, 0}})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	after := read(t, &f, camera, under)
	testing.expectf(t, after > lit - 12, "the frame after its caster is gone the floor has its light: %f of %f", after, lit)
	expect_clean(t, f.device)
}

@(test)
render_diffuse_color_bleeding :: proc(t: ^testing.T) {
	f: Cube_Fixture
	// The indirect light itself: the lit floor of a room this bright goes white
	// through the display transform.
	settings := test_settings()
	settings.taa = false
	if !cube_fixture_init(t, &f, 96, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A closed white room whose ceiling is a red emitter: the floor only
	// receives red light, by indirect diffuse transport.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {6, 0.2, 6}), tint = {0.9, 0.9, 0.9}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 3.1, 0}, {6, 0.2, 6}), tint = {1, 0, 0}, emission = {3, 0, 0}},
		{object_id = 3, mesh = f.cube, transform = trs({-3.1, 1.5, 0}, {0.2, 3.4, 6}), tint = {0.9, 0.9, 0.9}},
		{object_id = 4, mesh = f.cube, transform = trs({3.1, 1.5, 0}, {0.2, 3.4, 6}), tint = {0.9, 0.9, 0.9}},
		{object_id = 5, mesh = f.cube, transform = trs({0, 1.5, -3.1}, {6, 3.4, 0.2}), tint = {0.9, 0.9, 0.9}},
		{object_id = 6, mesh = f.cube, transform = trs({0, 1.5, 3.1}, {6, 3.4, 0.2}), tint = {0.9, 0.9, 0.9}},
	}
	scene_set(r, instances, nil, {}, {sky = {0, 0, 0}})
	camera := Camera{position = {0, 2.5, 2.5}, forward = {0, -2.5, -2.5}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 16 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	floor := pixel(pixels, w, project(r, camera, {0, 0.001, 0}))
	testing.expectf(t, floor[0] > 40 && floor[0] > floor[1] * 2 && floor[0] > floor[2] * 2, "floor lit only by red bounce light, got %v", floor)
	expect_clean(t, f.device)
}

@(test)
render_probes_keep_rough_metal_lighting_when_a_wall_moves :: proc(t:^testing.T) {
    f:Cube_Fixture
    settings:=test_settings()
    settings.probe_budget=8
    settings.taa=false
    if !cube_fixture_init(t,&f,128,96,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    metal:=DEFAULT_MATERIAL
    metal.metallic,metal.roughness=1,0.9
    materials_set(r,{metal})
    instances:=[]Instance_Desc{
        {object_id=1,mesh=f.cube,transform=trs({0,-0.1,0},{14,0.2,14}),tint={1,1,1}},
        {object_id=2,mesh=f.cube,transform=trs({0,0.75,0},{1.5,1.5,1.5}),material=1,tint={1,1,1}},
        {object_id=3,mesh=f.cube,transform=trs({-6,1.5,0},{0.2,3,14}),tint={1,1,1}},
    }
    scene_set(r,instances,nil,{}, {sky={0.5,0.5,0.5}})
    camera:=Camera{position={4,5,8},forward={-4,-4.25,-8},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    for _ in 0..<128 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
    before,width,_,ok:=golden_capture(r)
    testing.expect(t,ok)
    if !ok {return}
    defer delete(before)
    point:=project(r,camera,{0,1.5,0})
    reference:=pixel(before,width,point)
    testing.expect(t,reference.r>60)
    for x in ([3]f32{-9,-12,-6}) {
        testing.expect(t,scene_move(r,{2},{trs({x,1.5,0},{0.2,3,14})}))
        testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
        after,w,_,captured:=golden_capture(r)
        testing.expect(t,captured)
        if !captured {continue}
        actual:=pixel(after,w,point)
        testing.expectf(t,actual.r>=reference.r*0.65,"moving wall to %v: metal %v, before %v",x,actual,reference)
        delete(after)
    }
    expect_clean(t,f.device)
}

@(test)
render_culls_and_keeps_steady_frames_allocation_free :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.probe_budget = 64
	if !cube_fixture_init(t, &f, 64, 48, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, 0, 0}, {1, 1, 1}), tint = {0.8, 0.2, 0.2}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0, 30}, {1, 1, 1}), tint = {0.2, 0.8, 0.2}}, // behind the camera
	}
	lights := []Light_Desc{{position = {1, 2, 1}, color = {1, 0.9, 0.8}, intensity = 10 * math.PI, range = 10}}
	scene_set(r, instances, lights, {direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}, {sky = {0.2, 0.3, 0.5}})
	camera := Camera{position = {0, 1, 5}, forward = {0, -1, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expect_value(t, r.stats.culled_instances, u32(1))
	testing.expect_value(t, r.stats.visible_instances, u32(1))
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	{
		context.allocator = mem.tracking_allocator(&tracker)
		for _ in 0 ..< 4 {renderer_frame(r, {camera = camera})}
	}
	testing.expect_value(t, tracker.total_allocation_count, i64(0))
	expect_clean(t, f.device)
}


@(test)
render_two_phase_occlusion_culls_without_popping :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.taa = false
	if !cube_fixture_init(t, &f, 96, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	camera := Camera{position = {0, 1, 6}, forward = {0, 0, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	hidden_cube := Instance_Desc{object_id = 2, mesh = f.cube, transform = trs({0, 1, -2}, {0.5, 0.5, 0.5}), tint = {0, 0.9, 0}, emission = {0, 2, 0}}
	wall := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, 1, 2}, {6, 4, 0.2}), tint = {0.5, 0.5, 0.5}}
	sun := Sun_Desc{direction = {0.2, 1, 0.3}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}
	scene_set(r, []Instance_Desc{wall, hidden_cube}, nil, sun, {sky = {0.2, 0.2, 0.2}})
	for _ in 0 ..< 5 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expectf(t, r.stats.occluded_instances == 1 && r.stats.visible_instances == 1, "wall hides the cube: occluded %d visible %d", r.stats.occluded_instances, r.stats.visible_instances)
	// Move the wall away: phase 0 still rejects the cube with last frame's
	// pyramid, phase 1 must rescue it in this very frame.
	wall.transform = trs({20, 1, 2}, {6, 4, 0.2})
	scene_set(r, []Instance_Desc{wall, hidden_cube}, nil, sun, {sky = {0.2, 0.2, 0.2}})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	cube := pixel(pixels, w, project(r, camera, {0, 1, -1.74}))
	testing.expectf(t, cube[1] > 150 && cube[0] < 120, "cube visible right after the occluder moved, got %v", cube)
	expect_clean(t, f.device)
}

@(private = "file")
region_mean :: proc(pixels: []u8, width, x0, y0, x1, y1: int) -> [3]f32 {
	sum: [3]f32
	for y in y0 ..< y1 {for x in x0 ..< x1 {sum += pixel(pixels, width, {x, y})}}
	return sum / f32((x1 - x0) * (y1 - y0))
}

// A floor, 48 posts on it and `count` point lights of `radius` over them that
// give the same light whatever their number: the field of the lights scene
// of the demo.
@(private = "file")
lights_field :: proc(f: ^Cube_Fixture, count: int, range: f32, height: f32 = 3.5, radius: f32 = 0) {
	instances: [49]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.15, 0}, {24, 0.3, 20}), tint = {0.4, 0.4, 0.4}}
	for i in 0 ..< 48 {
		instances[i + 1] = {object_id = u64(i + 2), mesh = f.cube, transform = trs({-9 + f32(i % 8) * 2.5, 0.7, -7 + f32(i / 8) * 2.5}, {0.8, 1.4, 0.8}), tint = {1, 1, 1}}
	}
	lights := make([]Light_Desc, count, context.temp_allocator)
	for &l, i in lights {
		x, z: u32
		for bit in 0 ..< uint(5) {
			x |= ((u32(i) >> (2 * bit)) & 1) << (4 - bit)
			z |= ((u32(i) >> (2 * bit + 1)) & 1) << (4 - bit)
		}
		l = {position = {-9 + 18 * (f32(x) + 0.5) / 32, height, -8 + 16 * (f32(z) + 0.5) / 32}, color = {1, 0.7, 0.4}, intensity = (2 * 256 / f32(count)) * math.PI, range = range, radius = radius}
	}
	scene_set(f.renderer, instances[:], lights, {}, {})
}

// How far an image is from another, over the pixels either one lights: the
// mean of what it adds, and the root of the mean square of the difference,
// in levels of the 255 of a channel.
@(private = "file")
image_error :: proc(image, reference: []u8) -> (bias, rms: f32) {
	sum, squares: f64
	count := 0
	for i := 0; i < len(reference); i += 4 {
		if max(reference[i], reference[i + 1], reference[i + 2], image[i], image[i + 1], image[i + 2]) < 8 {continue}
		for c in 0 ..< 3 {
			d := f64(image[i + c]) - f64(reference[i + c])
			sum += d
			squares += d * d
		}
		count += 3
	}
	if count == 0 {return 0, 0}
	return f32(sum / f64(count)), f32(math.sqrt(squares / f64(count)))
}

// What the lighting approximates: the mean of `frames` frames of
// reference_lights, whose rays go to other points of the lights each frame.
// The settings of the renderer are those of the image it is compared with,
// with the reference on and without the temporal filter.
@(private = "file")
reference_image :: proc(t: ^testing.T, f: ^Cube_Fixture, camera: Camera, frames: int, mode := Debug_View.None) -> (image: []u8, ok: bool) {
	r := f.renderer
	settings := r.settings
	reference := settings
	reference.reference_lights, reference.taa = true, false
	testing.expect(t, renderer_apply_settings(r, reference))
	defer testing.expect(t, renderer_apply_settings(r, settings))
	sum: []f32
	defer delete(sum)
	for _ in 0 ..< frames {
		testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = mode}}), r.error)
		rhi.device_wait_idle(f.device)
		pixels, _, _, captured := golden_capture(r)
		testing.expect(t, captured, r.error)
		if !captured {return}
		if sum == nil {sum = make([]f32, len(pixels))}
		for value, i in pixels {sum[i] += f32(value)}
		delete(pixels)
	}
	image = make([]u8, len(sum))
	for value, i in sum {image[i] = u8(clamp(value / f32(frames) + 0.5, 0, 255))}
	return image, true
}

// Many more lights reach a pixel than it traces, and they have a size: what
// it shows is what every light gives through rays of its own to every point
// of it, and the same from a frame to the next.
@(test)
render_many_lights_match_their_reference :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 480, 300, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	renderer_set_display_transform(r, .ACES_2)
	lights_field(&f, 1024, 8, radius = 0.1)
	camera := Camera{position = {16, 12, 18}, forward = {-16, -12, -18}, up = {0, 1, 0}, fov_y = 50, near = 0.1, far = 100, exposure = UNIT_EXPOSURE}
	reference, ok := reference_image(t, &f, camera, 8)
	if !ok {return}
	defer delete(reference)
	renderer_camera_cut(r)
	for _ in 0 ..< 16 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	lit, _, _, ok2 := golden_capture(r)
	testing.expect(t, ok2, r.error)
	if !ok2 {return}
	defer delete(lit)
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	rhi.device_wait_idle(f.device)
	next, _, _, ok3 := golden_capture(r)
	testing.expect(t, ok3, r.error)
	if !ok3 {return}
	defer delete(next)
	bias, rms := image_error(lit, reference)
	_, flicker := image_error(next, lit)
	testing.expectf(t, abs(bias) < 1.5 && rms < 8, "a few rays give what every light gives: %v brighter, %v apart, of 255", bias, rms)
	testing.expectf(t, flicker < 1.5, "and the same from a frame to the next: %v of 255", flicker)
	expect_clean(t, f.device)
}

// A scene has many more lights than the budget, and few of them reach each
// pixel: every one that does is lit with its own ray, as with a budget for
// many more.
@(test)
render_lights_that_few_reach_at_a_time_are_each_lit :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	// Without the jitter of the TAA, which the samples of a pixel follow: the two images differ by the budget alone.
	settings.taa = false
	if !cube_fixture_init(t, &f, 240, 150, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lights_field(&f, 64, 3, 2.6)
	camera := Camera{position = {16, 12, 18}, forward = {-16, -12, -18}, up = {0, 1, 0}, fov_y = 50, near = 0.1, far = 100, exposure = UNIT_EXPOSURE}
	images: [2][]u8
	defer for image in images {delete(image)}
	for budget, i in ([2]u32{8, LIGHT_CUT_MAX}) {
		settings.light_budget = budget
		testing.expect(t, renderer_apply_settings(r, settings))
		renderer_camera_cut(r)
		for _ in 0 ..< 32 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(f.device)
		ok: bool
		images[i], _, _, ok = golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return}
	}
	lit := 0
	for value in images[0] {lit += int(value > 32)}
	testing.expect(t, lit > len(images[0]) / 16, "the lights light the floor")
	_, rms := image_error(images[0], images[1])
	testing.expectf(t, rms < 0.5, "%v of 255 apart", rms)
	expect_clean(t, f.device)
}

// Lights that the tree adds up by groups give what they give one by one.
@(test)
render_groups_of_lights_give_what_their_lights_give :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 64, 48, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lights: [24]Light_Desc
	for &l, i in lights {
		angle := f32(i) / 24 * 2 * math.PI
		radius := f32(1 + i % 3)
		l = {position = {math.cos(angle) * radius, 1.2, math.sin(angle) * radius}, color = {0.4 + 0.6 * f32(i % 2), 0.5, 0.4 + 0.6 * f32(i % 3) / 2}, intensity = 0.25 * math.PI, range = 6}
	}
	floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {1, 1, 1}}
	scene_set(r, []Instance_Desc{floor}, lights[:], {}, {})
	camera := Camera{position = {0, 6, 0.01}, forward = {0, -6, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	exact, ok := reference_image(t, &f, camera, 1, .Direct)
	if !ok {return}
	defer delete(exact)
	for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Direct}}), r.error)}
	rhi.device_wait_idle(f.device)
	grouped, w, _, ok2 := golden_capture(r)
	testing.expect(t, ok2, r.error)
	if !ok2 {return}
	defer delete(grouped)
	reference := region_mean(exact, w, 16, 12, 48, 36)
	estimate := region_mean(grouped, w, 16, 12, 48, 36)
	testing.expectf(t, reference[0] > 40, "direct light is visible: %v", reference)
	for c in 0 ..< 3 {
		testing.expectf(t, abs(estimate[c] - reference[c]) <= 0.04 * reference[c] + 2, "channel %d: by groups %v, one by one %v", c, estimate, reference)
	}
	_, rms := image_error(grouped, exact)
	testing.expectf(t, rms < 4, "%v of 255 apart", rms)
	expect_clean(t, f.device)
}

// The sun is half a degree wide. Low over the horizon, the shadow of a
// figure blurs little along its sides and much at its end, where the head
// is far from the ground and the penumbra falls along the shadow: what the
// image shows there is what every point of the disc gives.
@(test)
render_a_low_sun_draws_out_the_end_of_a_shadow :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 480, 300, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	renderer_set_display_transform(r, .ACES_2)
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {20, 0.2, 40}), tint = {0.6, 0.55, 0.45}},
		{object_id = 2, mesh = f.cube, transform = trs({-0.15, 0.45, -8}, {0.14, 0.9, 0.14}), tint = {0.3, 0.3, 0.3}},
		{object_id = 3, mesh = f.cube, transform = trs({0.15, 0.45, -8}, {0.14, 0.9, 0.14}), tint = {0.3, 0.3, 0.3}},
		{object_id = 4, mesh = f.cube, transform = trs({0, 1.3, -8}, {0.45, 0.8, 0.25}), tint = {0.3, 0.3, 0.3}},
	}
	elevation := f32(12) * math.RAD_PER_DEG
	sun := Sun_Desc{direction = {0, math.sin(elevation), -math.cos(elevation)}, color = {1, 0.85, 0.6}, illuminance = 3 * math.PI, enabled = true}
	scene_set(r, instances, nil, sun, {sky = {0.05, 0.05, 0.06}})
	camera := Camera{position = {0.6, 1.7, 3}, forward = {-0.6, -1.7, -6}, up = {0, 1, 0}, fov_y = 55, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	reference, ok := reference_image(t, &f, camera, 16)
	if !ok {return}
	defer delete(reference)
	renderer_camera_cut(r)
	for _ in 0 ..< 32 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	lit, w, h, ok2 := golden_capture(r)
	testing.expect(t, ok2, r.error)
	if !ok2 {return}
	defer delete(lit)
	// Around the end of the shadow of the head.
	tip := project(r, camera, {0, 0, -8 + 1.7 / math.tan(elevation)})
	squares: f64
	count := 0
	for y in max(tip.y - 16, 0) ..< min(tip.y + 16, h) {for x in max(tip.x - 24, 0) ..< min(tip.x + 24, w) {
		a, b := pixel(lit, w, {x, y}), pixel(reference, w, {x, y})
		for c in 0 ..< 3 {squares += f64((a[c] - b[c]) * (a[c] - b[c]))}
		count += 3
	}}
	rms := math.sqrt(squares / f64(max(count, 1)))
	// The blocks of shadows trace fixed points of the disc, the same each frame:
	// the penumbra is a little coarser than the reference, and still.
	testing.expectf(t, rms < 13, "the end of the shadow is %v of 255 from what the disc of the sun gives", rms)
	expect_clean(t, f.device)
}

// A light with a size blurs the shadow of a wall where the shadow falls far
// from it, and a light with none leaves it sharp.
@(test)
render_a_wider_light_casts_a_softer_shadow :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 256, 192, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// The light is 2.5 m up, 1 m from a wall 1.5 m tall: the edge of its
	// shadow falls on the floor 2.75 m from under the light.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {14, 0.2, 14}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({1.1, 0.75, 0}, {0.2, 1.5, 6}), tint = {0.5, 0.5, 0.5}},
	}
	camera := Camera{position = {2.75, 6, 0.001}, forward = {0, -6, -0.001}, up = {0, 0, -1}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	widths: [2]f32
	for radius, i in ([2]f32{0, 0.3}) {
		scene_set(r, instances, []Light_Desc{{position = {0, 2.5, 0}, color = {1, 1, 1}, intensity = 30 * math.PI, range = 12, radius = radius}}, {}, {})
		renderer_camera_cut(r)
		for _ in 0 ..< 12 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return}
		defer delete(pixels)
		// Metres along the floor over which it goes from 10 % to 90 % of the
		// brightest it gets past the shadow, before the light falls off with the distance.
		values: [150]f32
		brightest := 0
		for &v, k in values {
			v = pixel(pixels, w, project(r, camera, {1.6 + 0.02 * f32(k), 0.001, 0}))[0]
			if v > values[brightest] {brightest = k}
		}
		dark, lit := values[0], values[brightest]
		testing.expectf(t, lit > dark + 40, "the wall casts a shadow: %f to %f", dark, lit)
		low, high := brightest, brightest
		for k := brightest; k >= 0; k -= 1 {
			if values[k] > dark + 0.9 * (lit - dark) {high = k}
			if values[k] > dark + 0.1 * (lit - dark) {low = k}
		}
		widths[i] = 0.02 * f32(high - low)
	}
	testing.expectf(t, widths[0] < 0.2, "a light with no size casts a sharp shadow: %f m of penumbra", widths[0])
	testing.expectf(t, widths[1] > 0.4 && widths[1] > 3 * widths[0], "a wide one, a soft shadow: %f m of penumbra, %f m with none", widths[1], widths[0])
	expect_clean(t, f.device)
}

// The top of a box lies in the shadow of a roof, and no light faces its
// front. Seen low over the edge between them, the jitter of the TAA moves
// the pixels of the blocks of shadows from one face to the other: the top
// takes none of the light of the front, which nothing shadows.
@(test)
render_an_edge_takes_no_light_from_the_face_beyond_it :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	if !cube_fixture_init(t, &f, 256, 160, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {14, 0.2, 14}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0.5, 0}, {6, 1, 1}), tint = {0.8, 0.8, 0.8}},
		{object_id = 3, mesh = f.cube, transform = trs({0, 3, -0.7}, {8, 0.2, 2.6}), tint = {0.5, 0.5, 0.5}},
	}
	sun := Sun_Desc{direction = {0, 1, -0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	scene_set(r, instances, nil, sun, {sky = {0, 0, 0}})
	// Tilted, the edge crosses the rows of pixels.
	camera := Camera{position = {0, 1.6, 5}, forward = {0, -0.7, -5}, up = {0.08, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 24 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	brightest, floor: f32
	for _ in 0 ..< 8 {
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		rhi.device_wait_idle(f.device)
		pixels, w, h, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return}
		defer delete(pixels)
		floor = pixel(pixels, w, project(r, camera, {0, 0.001, 2}))[0]
		for i in 0 ..< 40 {
			edge := project(r, camera, {-2.4 + 0.12 * f32(i), 1, 0.5})
			for dy in -3 ..= 3 {
				y := edge.y + dy
				if y < 0 || y >= h {continue}
				c := pixel(pixels, w, {edge.x, y})
				brightest = max(brightest, c[0], c[1], c[2])
			}
		}
	}
	testing.expectf(t, floor > 100, "the sun lights the floor before the box: %f", floor)
	testing.expectf(t, brightest < 24, "the edge of the box stays dark: %f of 255 at its brightest", brightest)
	expect_clean(t, f.device)
}

@(test)
render_spot_light_lights_only_its_cone :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	if !cube_fixture_init(t, &f, 64, 48, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// 2 m above the floor, a 20 degree cone lights a disc of radius ~0.73 m.
	spot := Light_Desc{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 8 * math.PI, range = 10, direction = {0, -1, 0}, cone = 20 * math.RAD_PER_DEG}
	floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {1, 1, 1}}
	scene_set(r, []Instance_Desc{floor}, []Light_Desc{spot}, {}, {})
	camera := Camera{position = {0, 6, 0.01}, forward = {0, -6, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Direct}}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	inside := pixel(pixels, w, project(r, camera, {0, 0.001, 0}))
	outside := pixel(pixels, w, project(r, camera, {1.6, 0.001, 0}))
	testing.expectf(t, inside[0] > 60, "floor under the spot is lit, got %v", inside)
	testing.expectf(t, outside[0] < 4, "floor outside the cone is dark, got %v", outside)
	expect_clean(t, f.device)
}

@(test)
render_resize_and_settings_changes_stay_valid :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 64, 48, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lights := []Light_Desc{{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 5 * math.PI, range = 8}, {position = {1, 2, 1}, color = {1, 0.5, 0.2}, intensity = 5 * math.PI, range = 8}}
	scene_set(r, []Instance_Desc{{object_id = 1, mesh = f.cube, transform = trs({0, 0, 0}, {4, 0.2, 4}), tint = {0.8, 0.8, 0.8}}}, lights, {}, {sky = {0.2, 0.3, 0.4}})
	camera := Camera{position = {0, 3, 4}, forward = {0, -3, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	renderer_resize(r, 80, 60)
	testing.expect(t, !r.targets.taa_valid && !r.targets.hiz_valid, "histories restart after a resize")
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	settings := r.settings
	settings.render_scale = 0.5
	settings.light_budget = 0 // the lights of a cell are sampled from here on
	testing.expect(t, renderer_apply_settings(r, settings))
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expect_value(t, r.targets.width, u32(40))
	renderer_resize(r, 64, 48)
	settings.render_scale = 1
	testing.expect(t, renderer_apply_settings(r, settings))
	scene_set(r, nil, nil, {}, {}) // empty scene
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	// A 2x (Retina) drawable: window resolution output, scene at the point resolution.
	renderer_resize(r, 128, 96, 2, 2)
	testing.expect(t, r.targets.output_width == 128 && r.targets.width == 64 && r.targets.height == 48)
	ui := []Ui_Vertex{{position = {0, 0, 0}, color = {1, 1, 1, 1}}, {position = {64, 0, 0}, color = {1, 1, 1, 1}}, {position = {0, 48, 0}, color = {1, 1, 1, 1}}}
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera, ui = {{vertices = ui}}}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok && w == 128, r.error)
	if ok {
		defer delete(pixels)
		// The triangle covers the top-left quarter of the window in points.
		testing.expect(t, pixel(pixels, w, {10, 10})[0] > 250 && pixel(pixels, w, {120, 90})[0] < 250, "UI vertices are in points")
	}
	renderer_resize(r, 128, 96, 2, 1)
	testing.expect(t, r.targets.output_width==128 && r.targets.width==128 && r.targets.height==96, "Windows content scale keeps the scene at the drawable resolution")
	for _ in 0..<2 {testing.expect(t, renderer_frame(r,{camera=camera,ui={{vertices=ui}}}),r.error)}
	expect_clean(t, f.device)
}

@(test)
a_target_of_lines_scales_the_views_of_the_window_together :: proc(t:^testing.T) {
    f:Cube_Fixture
    settings:=test_settings()
    settings.gi_enabled=false
    if !cube_fixture_init(t,&f,200,100,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    scene_set(r,{{object_id=1,mesh=f.cube,transform=trs({0,0,0},{1,1,1}),tint={1,1,1}}},nil,{},{use_background=true})
    camera:=Camera{position={0,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    target:=proc(t:^testing.T,r:^Renderer,settings:^Settings,lines:u32) {
        settings.render_height=lines
        testing.expect(t,renderer_apply_settings(r,settings^))
    }
    // A target over the lines of the window keeps a pixel per point.
    target(t,r,&settings,200)
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,r.targets.width==200 && r.targets.height==100)
    // Under them both sides shrink alike.
    target(t,r,&settings,50)
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,r.targets.width==100 && r.targets.height==50 && r.targets.output_width==200)
    // Views side by side span the height of the window, and share its scale.
    views:=[2]Frame_View{{camera=camera,rect={0,0,100,100}},{camera=camera,rect={100,0,100,100}}}
    for _ in 0..<2 {testing.expect(t,renderer_frame(r,{views=views[:]}),r.error)}
    for view in r.views[:2] {testing.expect(t,view.targets.width==50 && view.targets.height==50 && view.targets.output_width==100)}
    // Never below the least render scale.
    target(t,r,&settings,1)
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,r.targets.width==50 && r.targets.height==25)
    // Nor above a pixel per point on a 2x drawable.
    target(t,r,&settings,1000)
    renderer_resize(r,200,100,2,2)
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,r.targets.width==100 && r.targets.height==50)
    settings.render_scale=-1
    testing.expect(t,!renderer_apply_settings(r,settings))
}

@(test)
split_screen_preserves_views_and_composes_global_ui :: proc(t:^testing.T) {
    f:Cube_Fixture
    settings:=test_settings()
    settings.gi_enabled=false
    settings.taa=true
    if !cube_fixture_init(t,&f,129,97,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    scene_set(r,{
        {object_id=1,mesh=f.cube,transform=trs({-3,0,0},{2,2,2}),tint={1,0,0},emission={2,0,0}},
        {object_id=2,mesh=f.cube,transform=trs({3,0,0},{2,2,2}),tint={0,1,0},emission={0,2,0}},
    },nil,{}, {use_background=true})
    cameras:=[2]Camera{
        {position={-3,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE},
        {position={3,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE},
    }
    ui_vertices:=[6]Ui_Vertex{
        {position={0,0,0},color={0,0,1,1}}, {position={129,0,0},color={0,0,1,1}}, {position={0,4,0},color={0,0,1,1}},
        {position={129,0,0},color={0,0,1,1}}, {position={129,4,0},color={0,0,1,1}}, {position={0,4,0},color={0,0,1,1}},
    }
    layers:=[]Ui_Layer{{vertices=ui_vertices[:]}}
    views:[VIEW_CAPACITY]Frame_View
    for index in 0..<2 {views[index]={disabled=true,rect={i32(129*index/2),0,i32(129*(index+1)/2-129*index/2),97}}}
    testing.expect(t,renderer_frame(r,{views=views[:2],ui=layers}),r.error)
    materials_set(r,{{base_color={1,1,1},roughness=0.7}})
    for count in 2..=4 {
        columns,rows:=2,count>2?2:1
        for index in 0..<count {
            x,y:=index%columns,index/columns
            left,top:=129*x/columns,97*y/rows
            views[index]={camera=cameras[index%2],rect={i32(left),i32(top),i32(129*(x+1)/columns-left),i32(97*(y+1)/rows-top)}}
        }
        frame:=Frame_Desc{views=views[:count],ui=layers}
        for _ in 0..<4 {testing.expect(t,renderer_frame(r,frame),r.error)}
        pixels,w,_,ok:=renderer_capture(r)
        testing.expect(t,ok)
        if ok {
            for view,index in views[:count] {
                center:=pixel(pixels,w,{int(view.rect.x+view.rect.z/2),int(view.rect.y+view.rect.w/2)})
                channel:=index%2
                testing.expectf(t,center[channel]>150 && center[channel]-center[1-channel]>100,"view %d shows %v",index,center)
            }
            testing.expect_value(t,pixel(pixels,w,{100,1}),[3]f32{0,0,255})
            if count==3 {testing.expect_value(t,pixel(pixels,w,{100,75}),[3]f32{})}
            delete(pixels)
        }
        for view,index in r.views[:count] {
            testing.expect(t,view.has_previous && view.targets.taa_valid)
            for other in 0..<index {testing.expect(t,view.targets.taa[0]!=r.views[other].targets.taa[0])}
        }
        tracker:mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker,context.allocator)
        {
            context.allocator=mem.tracking_allocator(&tracker)
            for _ in 0..<3 {testing.expect(t,renderer_frame(r,frame),r.error)}
        }
        testing.expect_value(t,tracker.total_allocation_count,i64(0))
        mem.tracking_allocator_destroy(&tracker)
    }
    settings.gi_enabled=true
    testing.expect(t,renderer_apply_settings(r,settings))
    for _ in 0..<4 {testing.expect(t,renderer_frame(r,{views=views[:],ui=layers}),r.error)}
    for view in r.views {
        testing.expect(t,view.targets.taa_valid)
    }
    for &view in views {view.disabled=true}
    testing.expect(t,renderer_frame(r,{views=views[:],ui=layers}),r.error)
    empty_pixels,empty_width,_,empty_ok:=renderer_capture(r)
    testing.expect(t,empty_ok)
    if empty_ok {
        testing.expect_value(t,pixel(empty_pixels,empty_width,{32,24}),[3]f32{})
        testing.expect_value(t,pixel(empty_pixels,empty_width,{100,1}),[3]f32{0,0,255})
        delete(empty_pixels)
    }
    testing.expect(t,renderer_frame(r,{camera=cameras[0]}),r.error)
    testing.expect_value(t,r.view_count,0)
    for view in r.views {testing.expect_value(t,view.targets.ldr,rhi.Texture(0))}
    expect_clean(t,f.device)
}

@(test)
camera_cuts_reset_screen_history_and_preserve_world_lighting_and_pipelines :: proc(t:^testing.T) {
    f:Cube_Fixture
    settings:=test_settings()
    settings.taa=true
    if !cube_fixture_init(t,&f,64,48,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    scene_set(r,{{object_id=1,mesh=f.cube,transform=trs({},{1,1,1}),tint={0.8,0.8,0.8}}},nil,{}, {sky={0.2,0.3,0.4}})
    camera:=Camera{position={0,2,4},forward={0,-2,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    for _ in 0..<4 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
    rhi.device_wait_idle(f.device)
    pipelines,probes,irradiance:=r.pipelines,r.ddgi.probes,r.ddgi.irradiance
    testing.expect(t,r.has_previous && r.targets.taa_valid)
    r.targets.gi_reference_valid=true
    r.targets.glass_valid,r.targets.hiz_valid=true,true
    renderer_camera_cut(r)
    testing.expect(t,!r.has_previous && r.prev_jitter=={})
    testing.expect(t,!r.targets.taa_valid && !r.targets.gi_reference_valid)
    testing.expect(t,!r.targets.glass_valid && !r.targets.hiz_valid)
    testing.expect_value(t,r.pipelines,pipelines)
    testing.expect_value(t,r.ddgi.probes,probes)
    testing.expect_value(t,r.ddgi.irradiance,irradiance)
    camera.position={4,1,0}
    testing.expect(t,renderer_frame(r,{camera=camera,camera_cut=true}),r.error)
    rhi.device_wait_idle(f.device)
    testing.expect(t,r.has_previous && r.targets.taa_valid)
    testing.expect_value(t,r.pipelines,pipelines)
    testing.expect_value(t,r.ddgi.probes,probes)
    expect_clean(t,f.device)
}

@(test)
render_many_overlapping_instances_stay_valid :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	// The tree of the instances is kept for rays traced by software.
	settings.trace_mode = .Software
	if !cube_fixture_init(t, &f, 48, 32, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// Dense overlapping stacks make SAH leaves hold several instances, so the
	// TLAS references outnumber its nodes.
	instances := make([]Instance_Desc, 300)
	defer delete(instances)
	for &inst, i in instances {
		inst = {object_id = u64(i + 1), mesh = f.cube, transform = trs({f32(i % 3) * 0.05, f32(i / 3) * 0.01, 0}, {1, 1, 1}), tint = {0.5, 0.5, 0.5}}
	}
	scene_set(r, instances, nil, {direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}, {})
	camera := Camera{position = {0, 2, 5}, forward = {0, -1.5, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expect(t, len(r.scene.tlas_refs) == 300 && r.scene.tlas_ref_capacity >= 300)
	expect_clean(t, f.device)
}

@(test)
render_occlusion_is_conservative_at_odd_resolutions :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	// 250x180: pyramid level 4 has 7 texels of 32 px plus a folded remainder,
	// so mapping UVs evenly lands one texel left of the true footprint.
	if !cube_fixture_init(t, &f, 250, 180, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// The tall wall's right edge projects to pixel ~128. The box behind it is
	// visible at pixels ~130-141 and tall enough to be tested at level 5
	// (64 px texels): an even UV mapping reads only wall texels there.
	wall := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({-2.425, 1, 2}, {5, 20, 0.2}), tint = {0.3, 0.3, 0.3}}
	box := Instance_Desc{object_id = 2, mesh = f.cube, transform = trs({0.52, 1, -2}, {0.55, 2, 0.5}), tint = {0, 1, 0}, emission = {0, 3, 0}}
	scene_set(r, []Instance_Desc{wall, box}, nil, {}, {})
	camera := Camera{position = {0, 1, 6}, forward = {0, 0, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, h, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	green := 0
	for y in 0 ..< h {for x in 0 ..< w {c := pixel(pixels, w, {x, y}); if c[1] > 150 && c[1] - c[0] > 60 {green += 1}}}
	testing.expectf(t, green > 50, "the box next to the wall edge must be drawn (%d green pixels)", green)
	testing.expect_value(t, r.stats.occluded_instances, u32(0))
	expect_clean(t, f.device)
}

@(test)
render_taa_is_stable_on_static_scenes :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.render_scale = 0.5
	settings.gi_enabled = false
	if !cube_fixture_init(t, &f, 96, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {8, 0.2, 8}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0.6, 0}, {1.2, 1.2, 1.2}), tint = {0.9, 0.2, 0.1}},
	}
	scene_set(r, instances, nil, {direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.5 * math.PI, enabled = true}, {sky = {0.2, 0.3, 0.4}})
	camera := Camera{position = {2.5, 2.5, 3.5}, forward = {-2.5, -2, -3.5}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 24 {renderer_frame(r, {camera = camera})}
	lo := make([]u8, 96 * 64 * 4)
	hi := make([]u8, 96 * 64 * 4)
	defer delete(lo)
	defer delete(hi)
	for i in 0 ..< len(lo) {lo[i] = 255}
	for _ in 0 ..< 6 {
		renderer_frame(r, {camera = camera})
		rhi.device_wait_idle(f.device)
		frame_pixels, _, _, ok := golden_capture(r)
		testing.expect(t, ok)
		if !ok {return}
		for v, i in frame_pixels {lo[i] = min(lo[i], v); hi[i] = max(hi[i], v)}
		delete(frame_pixels)
	}
	total := 0
	for i in 0 ..< len(lo) {total += int(hi[i]) - int(lo[i])}
	mean_range := f32(total) / f32(len(lo))
	testing.expectf(t, mean_range < 1, "static scene shimmers: mean temporal range %f", mean_range)
	expect_clean(t, f.device)
}

// A glowing globe with a light inside gives its light once: the rays that
// gather light leave the globe to the light, its emission and what its
// surface reflects of that light, and it gives what the light alone gives. A
// glowing box with no light in it, too large to be small (SMALL_INSTANCE_REACH),
// still lights what is around through them.
@(test)
render_gathered_light_leaves_a_lamp_to_its_light :: proc(t: ^testing.T) {
	camera := Camera{position = {0, 2.5, 4}, forward = {0, -1.9, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	cases := [3]struct {glowing, light, body: bool}{{true, true, true}, {false, true, false}, {true, false, true}}
	total: [3]f32
	for c, i in cases {
		f: Cube_Fixture
		settings := test_settings()
		settings.taa = false
		if !cube_fixture_init(t, &f, 128, 96, settings) {return}
		defer fixture_destroy(&f)
		r := f.renderer
		instances := []Instance_Desc{
			{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}},
			{object_id = 2, mesh = f.cube, transform = trs({0, 2, -2}, {12, 4, 0.2}), tint = {0.8, 0.8, 0.8}},
			{object_id = 3, mesh = f.cube, transform = trs({0, 1, 0}, {0.4, 0.4, 0.4} if c.light else {1.6, 0.4, 1.6}), tint = {1, 1, 1}, emission = {20, 20, 20} if c.glowing else {}},
		}
		lights := []Light_Desc{{position = {0, 1, 0}, color = {1, 1, 1}, intensity = 4 * math.PI, range = 8, radius = 0.2}}
		scene_set(r, instances if c.body else instances[:2], lights if c.light else nil, {}, {sky = {0, 0, 0}})
		for _ in 0 ..< 120 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
		rhi.device_wait_idle(f.device)
		pixels, w, h, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return}
		defer delete(pixels)
		for y in 0 ..< h {for x in 0 ..< w {
			p := pixel(pixels, w, {x, y})
			total[i] += p[0] + p[1] + p[2]
		}}
		expect_clean(t, f.device)
	}
	testing.expectf(t, abs(total[0] - total[1]) < 0.03 * total[1], "the lamp gives what its light gives: %v and %v", total[0], total[1])
	testing.expectf(t, total[2] > 0.2 * total[1], "a glowing box with no light lights around: %v against %v", total[2], total[1])
}

@(test)
render_highlight_outlines_silhouette_without_scene_rebuild :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	if !cube_fixture_init(t, &f, 96, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	style := Highlight_Style{colors = {0={0, 1, 0, 1}, 1={0, 0, 1, 1}, 2={1, 0, 1, 1}, 3={0, 0, 1, 1}}, width = 3}
	testing.expect(t, renderer_set_highlight_style(r, style))
	testing.expect(t, !renderer_set_highlight_style(r, {colors = {0={2, 0, 0, 1}}, width = 3}), "out of range colors are rejected")
	// A dark cube on a black background: green pixels can only be the outline.
	instances := []Instance_Desc{{object_id = 7, mesh = f.cube, transform = trs({0, 0, 0}, {1, 1, 1}), tint = {0.1, 0.1, 0.1}}}
	scene_set(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
	camera := Camera{position = {0, 0, 4}, forward = {0, 0, -4}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	count_green :: proc(r: ^Renderer, t: ^testing.T, camera: Camera) -> (green: int, center_green: bool) {
		for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(r.device)
		pixels, w, h, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return}
		defer delete(pixels)
		for y in 0 ..< h {for x in 0 ..< w {c := pixel(pixels, w, {x, y}); if c[1] > 150 && c[0] < 80 && c[2] < 80 {green += 1}}}
		c := pixel(pixels, w, {w / 2, h / 2})
		center_green = c[1] > 150 && c[0] < 80
		return
	}
	plain, _ := count_green(r, t, camera)
	testing.expect_value(t, plain, 0)
	tlas_nodes := len(r.scene.tlas_nodes)
	testing.expect(t, scene_set_highlights(r, []u8{1}))
	testing.expect(t, !scene_set_highlights(r, []u8{1, 1}), "levels must match the instance list")
	testing.expect(t, !r.scene.tlas_dirty || !r.hardware_rt, "a highlight change does not rebuild the hardware TLAS")
	testing.expect_value(t, len(r.scene.tlas_nodes), tlas_nodes)
	outlined, center := count_green(r, t, camera)
	testing.expectf(t, outlined > 40, "the silhouette is outlined, got %d green pixels", outlined)
	testing.expect(t, !center, "the interior of the highlighted object is not tinted")
	testing.expect(t, scene_set_highlights(r, []u8{0}))
	cleared, _ := count_green(r, t, camera)
	testing.expect_value(t, cleared, 0)
	// A level with a fill coats the object in its color instead of outlining it: the fourth one, in blue.
	style.fill[3] = 0.8
	testing.expect(t, renderer_set_highlight_style(r, style))
	testing.expect(t, scene_set_highlights(r, []u8{4}))
	outlined, _ = count_green(r, t, camera)
	testing.expect_value(t, outlined, 0)
	coated, w, h, captured := golden_capture(r)
	testing.expect(t, captured, r.error)
	if captured {
		c := pixel(coated, w, {w / 2, h / 2})
		testing.expectf(t, int(c[2]) > 150 && int(c[2]) > 2 * int(c[0]) && int(c[2]) > 2 * int(c[1]), "the fourth level coats the object in blue, got %v", c)
		delete(coated)
	}
	expect_clean(t, f.device)
}

@(test)
render_extended_highlights_keep_each_agent_color_and_mirrored_winding :: proc(t:^testing.T) {
    f:Cube_Fixture
    settings:=test_settings()
    settings.gi_enabled,settings.reflections,settings.taa=false,false,false
    if !cube_fixture_init(t,&f,96,64,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    colors:=[6]Vec4{{121.0/255,203.0/255,178.0/255,1},{182.0/255,160.0/255,237.0/255,1},{229.0/255,181.0/255,120.0/255,1},{129.0/255,185.0/255,233.0/255,1},{236.0/255,149.0/255,177.0/255,1},{194.0/255,207.0/255,122.0/255,1}}
    style:=DEFAULT_HIGHLIGHT_STYLE
    for color,index in colors {style.colors[index+4]=color}
    testing.expect(t,renderer_set_highlight_style(r,style))
    camera:=Camera{position={0,0,4},forward={0,0,-4},up={0,1,0},fov_y=50,near=.05,far=100,exposure=UNIT_EXPOSURE}
    for color,index in colors {
        for mirrored in ([2]bool{false,true}) {
            instance:=Instance_Desc{object_id=1,mesh=f.cube,transform=trs({},{mirrored?-1:1,1,1}),tint={.1,.1,.1},emission={.12,.12,.12},highlight=u8(index+5)}
            scene_set(r,{instance},nil,{},{background={},use_background=true})
            for _ in 0..<3 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
            pixels,width,height,ok:=renderer_capture(r)
            testing.expect(t,ok,r.error)
            if !ok {return}
            found:=0
            for i in 0..<width*height {
                match:=true
                for channel in 0..<3 {match&&=abs(f32(pixels[i*4+channel])-color[channel]*255)<16}
                if match {found+=1}
            }
            center:=(height/2*width+width/2)*4
            testing.expectf(t,found>30,"highlight level %d has its own outline color, mirrored=%v, %d pixels",index+5,mirrored,found)
            testing.expectf(t,pixels[center]>25 && pixels[center]<110,"mirrored winding keeps the cube surface and outlines its exterior, got %d",pixels[center])
            delete(pixels)
        }
    }
    expect_clean(t,f.device)
}

@(test)
render_highlight_fill_coats_the_surface_without_an_outline :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 96, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	style := Highlight_Style{colors = {0={0, 1, 0, 1}, 1={0, 0, 1, 1}, 2={1, 0, 1, 1}}, width = 3, fill = {1=0.6}}
	testing.expect(t, renderer_set_highlight_style(r, style))
	testing.expect(t, !renderer_set_highlight_style(r, {colors = style.colors, width = 3, fill = {1=1.5}}), "an out of range fill is rejected")
	// A dark cube on a black background: blue pixels can only come from the highlight.
	instances := []Instance_Desc{{object_id = 7, mesh = f.cube, transform = trs({0, 0, 0}, {1, 1, 1}), tint = {0.1, 0.1, 0.1}, highlight = 2}}
	scene_set(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
	camera := Camera{position = {0, 0, 4}, forward = {0, 0, -4}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	blue_at :: proc(r: ^Renderer, t: ^testing.T, camera: Camera, p: [2]int) -> f32 {
		for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(r.device)
		pixels, w, _, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return -1}
		defer delete(pixels)
		return pixel(pixels, w, p)[2]
	}
	center := project(r, camera, {0, 0, 0.5})
	edge := project(r, camera, {0.5, 0, 0.5})
	inside, outside := [2]int{edge.x - 4, edge.y}, [2]int{edge.x + 4, edge.y}
	testing.expectf(t, abs(blue_at(r, t, camera, center) - 0.6 * 255) < 30, "the whole surface takes the color at the fill opacity, got %v", blue_at(r, t, camera, center))
	testing.expectf(t, blue_at(r, t, camera, inside) > 100, "the coat reaches the edge of the silhouette, got %v", blue_at(r, t, camera, inside))
	testing.expectf(t, blue_at(r, t, camera, outside) < 20, "a filled level has no glow around it, got %v", blue_at(r, t, camera, outside))
	// The same level without a fill is an outline again.
	style.fill = {}
	testing.expect(t, renderer_set_highlight_style(r, style))
	testing.expectf(t, blue_at(r, t, camera, center) < 20, "an outlined level does not tint the interior, got %v", blue_at(r, t, camera, center))
	contour: f32
	for x in edge.x - 2 ..= edge.x + 2 {contour = max(contour, blue_at(r, t, camera, {x, edge.y}))}
	testing.expectf(t, contour > 100, "an outlined level draws its contour on the silhouette, got %v", contour)
	expect_clean(t, f.device)
}

@(test)
render_highlight_ignores_objects_in_front_of_the_selection :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 96, 96, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	testing.expect(t, renderer_set_highlight_style(r, {colors = {0={0, 1, 0, 1}, 1={0, 0, 1, 1}, 2={1, 0, 1, 1}}, width = 3}))
	// A selected floor with an unselected box standing on it, seen from above,
	// unlit on black: green pixels can only be outline.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {4, 0.2, 4}), tint = {0.1, 0.1, 0.1}, highlight = 1},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0.5, 0}, {1, 1, 1}), tint = {0.1, 0.1, 0.1}},
	}
	scene_set(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
	camera := Camera{position = {0, 7, 0.01}, forward = {0, -7, -0.01}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	green :: proc(c: [3]f32) -> bool {return c[1] > 100 && c[0] < 80 && c[2] < 80}
	// Around the box, well inside the floor: no outline.
	lo, hi := project(r, camera, {-1.3, 0.001, -1.3}), project(r, camera, {1.3, 0.001, 1.3})
	inner := 0
	for y in min(lo.y, hi.y) ..= max(lo.y, hi.y) {for x in min(lo.x, hi.x) ..= max(lo.x, hi.x) {if green(pixel(pixels, w, {x, y})) {inner += 1}}}
	testing.expectf(t, inner == 0, "the box on the selected floor is not outlined, got %d green pixels", inner)
	// The floor's own silhouette is.
	edge := 0
	for y in 0 ..< w {for x in 0 ..< w {if green(pixel(pixels, w, {x, y})) {edge += 1}}}
	testing.expectf(t, edge > 40, "the floor silhouette is outlined, got %d green pixels", edge)
	expect_clean(t, f.device)
}

@(test)
render_game_outline_shows_behind_walls_as_its_style_says :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 96, 96, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	testing.expect(t, renderer_set_highlight_style(r, {colors = {0={0, 1, 0, 1}}, width = 3, behind = {0 ..< 16 = 1}}))
	style := Highlight_Style{colors = {0={1, 0, 0, 1}}, width = 3, behind = {0=1}}
	testing.expect(t, renderer_set_outline_style(r, style))
	testing.expect(t, !renderer_set_outline_style(r, {width = 3, behind = {0=2}}), "an out of range opacity is rejected")
	// A box behind a wall, both dark on black: red pixels can only be the
	// game's outline of the box, green ones the editor's.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, 0, 0}, {1, 1, 1}), tint = {0.1, 0.1, 0.1}, highlight = outline_level(1)},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0, 1.5}, {3, 3, 0.1}), tint = {0.1, 0.1, 0.1}},
	}
	scene_set(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
	camera := Camera{position = {0, 0, 4}, forward = {0, 0, -4}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	count :: proc(r: ^Renderer, t: ^testing.T, camera: Camera) -> (red, green: int) {
		for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(r.device)
		pixels, w, h, ok := golden_capture(r)
		testing.expect(t, ok, r.error)
		if !ok {return}
		defer delete(pixels)
		for y in 0 ..< h {for x in 0 ..< w {
			c := pixel(pixels, w, {x, y})
			if c[0] > 150 && c[1] < 80 && c[2] < 80 {red += 1}
			if c[1] > 150 && c[0] < 80 && c[2] < 80 {green += 1}
		}}
		return
	}
	red, green := count(r, t, camera)
	testing.expectf(t, red > 40 && green == 0, "the box behind the wall shows its outline: %d red, %d green", red, green)
	style.behind[0] = 0
	testing.expect(t, renderer_set_outline_style(r, style))
	red, green = count(r, t, camera)
	testing.expectf(t, red == 0, "a style that shows nothing behind other surfaces is hidden by the wall: %d red", red)
	testing.expect(t, scene_set_highlights(r, []u8{1, 0}))
	red, green = count(r, t, camera)
	testing.expectf(t, green > 40 && red == 0, "the editor's level is drawn in place of the game's: %d green, %d red", green, red)
	expect_clean(t, f.device)
}

// Isolated GPU regression: a static editor silhouette must not inherit TAA
// jitter, Retina texel density or scene-resolution changes. A coplanar object
// also cannot toggle its occlusion attenuation or create another silhouette.
@(test)
render_highlight_is_stable_with_retina_taa_downscale_and_coplanar_geometry :: proc(t: ^testing.T) {
    f: Cube_Fixture
    settings := test_settings()
    settings.gi_enabled = false
    settings.reflections = false
    settings.taa = true
    settings.render_scale = 0.5
    if !cube_fixture_init(t, &f, 256, 160, settings) {return}
    defer fixture_destroy(&f)
    r := f.renderer
    renderer_resize(r, 256, 160, 2, 2)
    testing.expect(t, renderer_set_highlight_style(r, {colors = {0={0,1,0,1}}, width = 3}))
    instances := []Instance_Desc{
        {object_id = 1, mesh = f.cube, transform = trs({0,0,0}, {1,1,1}), tint = {}, highlight = 1},
        {object_id = 2, mesh = f.cube, transform = trs({0,0,0.0001}, {1,1,1}), tint = {}},
    }
    scene_set(r, instances, nil, {}, {background = {}, use_background = true})
    camera := Camera{position = {0,0,4}, forward = {0,0,-4}, up = {0,1,0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
    reference: []u8
    defer delete(reference)
    for variant in 0 ..< 3 {
        if variant == 1 {r.settings.render_scale = 1; renderer_resize(r, 256, 160, 2, 2)}
        if variant == 2 {instances[1].hidden = true; scene_set(r, instances, nil, {}, {background = {}, use_background = true})}
        for _ in 0 ..< 8 {
            testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
            rhi.device_wait_idle(r.device)
            pixels, w, h, ok := golden_capture(r)
            testing.expect(t, ok, r.error)
            if !ok {return}
            testing.expect_value(t, r.targets.highlight_width, u32(128))
            testing.expect_value(t, r.targets.highlight_height, u32(80))
            if reference == nil {
                reference = make([]u8, w * h)
                for i in 0 ..< w * h {reference[i] = pixels[i * 4 + 1]}
            } else {
                changed := 0
                for i in 0 ..< w * h {if abs(int(reference[i]) - int(pixels[i * 4 + 1])) > 1 {changed += 1}}
                testing.expectf(t, changed == 0, "editor coat is static through jitter, downscale and coplanar occlusion: %d changed pixels in variant %d", changed, variant)
            }
            delete(pixels)
        }
    }
    expect_clean(t, f.device)
}

@(test)
render_mesh_added_under_software_tracing_gets_its_native_structure_when_hardware_returns :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 64, 48, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// Only a device with ray queries has native structures to build.
	if !r.hardware_rt_verified {return}
	camera := Camera{position = {0, 4, 6}, forward = {0, -4, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	sun := Sun_Desc{direction = {0.2, 1, 0.1}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}
	scene_set(r, {{object_id = 1, mesh = f.cube, transform = trs({0, 0.5, 0}, {1, 1, 1}), tint = {1, 1, 1}}}, nil, sun, {})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect(t, r.scene.meshes[f.cube].rays[0].blas != 0)
	settings := r.settings
	settings.trace_mode = .Software
	testing.expect(t, renderer_apply_settings(r, settings))
	vertices, indices := cube_mesh()
	late, added := mesh_add(r, vertices[:], indices[:])
	testing.expect(t, added)
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, 0.5, 0}, {1, 1, 1}), tint = {1, 1, 1}},
		{object_id = 2, mesh = late, transform = trs({0, -0.1, 0}, {8, 0.2, 8}), tint = {1, 1, 1}},
	}
	scene_set(r, instances, nil, sun, {})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect(t, r.scene.meshes[late].rays[0].blas == 0, "software tracing builds no native structure")
	settings.trace_mode = .Hardware
	testing.expect(t, renderer_apply_settings(r, settings))
	testing.expect(t, r.hardware_rt)
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	testing.expect(t, r.scene.meshes[late].rays[0].blas != 0, "the mesh rays did not have is built when they are traced by hardware again")
	expect_clean(t, f.device)
}

@(test)
render_mesh_added_under_hardware_tracing_gets_its_software_tree_when_software_returns :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 64, 48, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	if !r.hardware_rt {return}
	camera := Camera{position = {0, 4, 6}, forward = {0, -4, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	sun := Sun_Desc{direction = {0.2, 1, 0.1}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true}
	vertices, indices := cube_mesh()
	late, added := mesh_add(r, vertices[:], indices[:])
	testing.expect(t, added)
	testing.expect(t, r.scene.meshes[f.cube].rays[0].bvh_node_count == 0 && r.scene.meshes[late].rays[0].bvh_node_count == 0 && len(r.scene.blas_nodes) == 0, "rays traced by hardware keep no software tree")
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, 0.5, 0}, {1, 1, 1}), tint = {1, 1, 1}},
		{object_id = 2, mesh = late, transform = trs({0, -0.1, 0}, {8, 0.2, 8}), tint = {1, 1, 1}},
	}
	scene_set(r, instances, nil, sun, {})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	settings := r.settings
	settings.trace_mode = .Software
	testing.expect(t, renderer_apply_settings(r, settings))
	testing.expect(t, !r.hardware_rt)
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	s := &r.scene
	for mesh in ([2]Mesh_Handle{f.cube, late}) {
		record := s.meshes[mesh]
		testing.expect(t, record.rays[0].bvh_node_count > 0, "every mesh has its software tree when rays are traced by software again")
		nodes := make([]Gpu_Bvh_Node, int(record.rays[0].bvh_node_count))
		defer delete(nodes)
		triangles := make([]Gpu_Bvh_Triangle, int(record.rays[0].triangle_count))
		defer delete(triangles)
		testing.expect(t, rhi.buffer_read_slice(f.device, s.blas_node_buffer, u64(record.rays[0].bvh_root) * size_of(Gpu_Bvh_Node), nodes))
		testing.expect(t, rhi.buffer_read_slice(f.device, s.blas_triangle_buffer, u64(record.rays[0].triangle_offset) * size_of(Gpu_Bvh_Triangle), triangles))
		distance, primitive := bvh_ray_triangles(nodes, triangles, {0.1, 5, 0.2}, {0, -1, 0}, 10)
		testing.expectf(t, primitive >= 0 && abs(distance - 4.5) < 1e-4, "the top of the cube in the tree of mesh %d: %d at %f", mesh, primitive, distance)
	}
	tlas := make([]Gpu_Bvh_Node, len(s.tlas_nodes))
	defer delete(tlas)
	testing.expect(t, rhi.buffer_read_slice(f.device, s.tlas_node_buffer, 0, tlas))
	testing.expect(t, mem.compare(mem.slice_to_bytes(tlas), mem.slice_to_bytes(s.tlas_nodes[:])) == 0, "the tree of instances goes to the GPU with the rays that walk it")
	expect_clean(t, f.device)
}

// ---------------------------------------------------------------- moves

@(private = "file")
move_settings :: proc() -> Settings {
	s := test_settings()
	s.probe_grid, s.probe_cascades = 8, 2
	// An image is compared pixel by pixel with another: every pixel traces its own rays.
	s.reference_lights = true
	// The probe volume traces the probes what changed reaches, in an order
	// two renderers do not share: they do not give it byte for byte.
	s.gi_enabled = false
	return s
}

MOVE_TEST_SUN :: Sun_Desc{direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
MOVE_TEST_ENVIRONMENT :: Environment{sky = {0.3, 0.4, 0.6}}
MOVE_TEST_CAMERA :: Camera{position = {0, 8, 7}, forward = {0, -8, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}

// A floor and a few boxes; the second one is skipped by the renderer: its mesh does not exist.
@(private = "file")
move_scene :: proc(cube: Mesh_Handle, instances: ^[5]Instance_Desc) {
	instances^ = {
		{object_id = 1, mesh = cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = Mesh_Handle(77), transform = trs({0, 5, 0}, {1, 1, 1})},
		{object_id = 3, mesh = cube, transform = trs({0, 1.5, 0}, {2, 0.2, 2}), tint = {0.5, 0.5, 0.5}},
		{object_id = 4, mesh = cube, transform = trs({-3, 0.5, 1}, {1, 1, 1}), tint = {0.9, 0.2, 0.2}},
		{object_id = 5, mesh = cube, transform = trs({3, 0.5, -1}, {1, 1, 1}), tint = {0.2, 0.3, 0.9}},
	}
}

@(private = "file")
move_frames :: proc(t: ^testing.T, r: ^Renderer, count: int) {
	for _ in 0 ..< count {testing.expect(t, renderer_frame(r, {camera = MOVE_TEST_CAMERA}), r.error)}
}

@(test)
scene_move_leaves_the_scene_that_setting_it_again_would :: proc(t: ^testing.T) {
	moved, set: Cube_Fixture
	// The tree of the instances is kept for rays traced by software.
	settings := move_settings()
	settings.trace_mode = .Software
	if !cube_fixture_init(t, &moved, 96, 64, settings) {return}
	defer fixture_destroy(&moved)
	if !cube_fixture_init(t, &set, 96, 64, settings) {return}
	defer fixture_destroy(&set)
	instances: [5]Instance_Desc
	move_scene(moved.cube, &instances)
	lights := []Light_Desc{{position = {2, 3, 2}, color = {1, 0.9, 0.8}, intensity = 20 * math.PI, range = 9}}
	for f in ([]^Cube_Fixture{&moved, &set}) {
		scene_set(f.renderer, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
		move_frames(t, f.renderer, 4)
	}
	r, expected := moved.renderer, set.renderer
	lights_before := len(r.scene.lights)

	// Wrong lists change nothing.
	testing.expect(t, !scene_move(r, {3}, {}))
	testing.expect(t, !scene_move(r, {5}, {trs({1, 1, 1}, {1, 1, 1})}))
	testing.expect(t, scene_move(r, {}, {}))
	// An instance the set skipped and one that stays where it was move nothing.
	testing.expect(t, scene_move(r, {1, 3}, {trs({9, 9, 9}, {1, 1, 1}), instances[3].transform}))
	testing.expect(t, r.scene.touched_count == 0 && !r.scene.tlas_nodes_dirty)

	for step in 1 ..= 3 {
		instances[2].transform = trs({f32(step) * 0.7, 1.5, 0}, {2, 0.2, 2})
		instances[4].transform = trs({3, 0.5 + f32(step) * 0.4, -1}, {1, 1 + f32(step) * 0.2, 1})
		testing.expect(t, scene_move(r, {2, 4}, {instances[2].transform, instances[4].transform}))
		scene_set(expected, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
		a, b := &r.scene, &expected.scene
		same := len(a.instances) == len(b.instances) && len(a.tlas_refs) == len(b.tlas_refs)
		testing.expect(t, same, "the tables are as long")
		if !same {return}
		for inst, i in a.instances {testing.expectf(t, inst == b.instances[i], "step %d: instance %d", step, i)}
		for item, i in a.tlas_items {testing.expectf(t, item == b.tlas_items[i], "step %d: item %d", step, i)}
		_, _, exact := tlas_exact(a, 0)
		testing.expectf(t, exact, "step %d: every node of the tree holds what is under it", step)
		testing.expect(t, a.tlas_nodes[0].bounds_min == b.tlas_nodes[0].bounds_min && a.tlas_nodes[0].bounds_max == b.tlas_nodes[0].bounds_max)
		for hw, i in a.hw_instances {testing.expectf(t, hw.transform == b.hw_instances[i].transform, "step %d: hardware instance %d", step, i)}
		testing.expect(t, a.bounds_min == b.bounds_min && a.bounds_max == b.bounds_max && a.has_bounds == b.has_bounds)
		testing.expect_value(t, len(a.lights), lights_before)
		testing.expect(t, !a.instances_dirty, "a move does not send the whole table")
		testing.expect_value(t, a.touched_count, 2)
		// The frame that follows draws the motion; the one after it, the instances at rest.
		move_frames(t, r, 1)
		move_frames(t, expected, 1)
		testing.expect_value(t, a.touched_count, 2)
		testing.expect(t, a.instances[a.desc_instance[2]].prev_world == a.instances[a.desc_instance[2]].world)
		move_frames(t, r, 1)
		move_frames(t, expected, 1)
		testing.expect_value(t, a.touched_count, 0)
		for inst, i in a.instances {testing.expectf(t, inst == b.instances[i], "step %d at rest: instance %d", step, i)}
	}
	move_frames(t, r, 4)
	move_frames(t, expected, 4)
	rhi.device_wait_idle(moved.device)
	rhi.device_wait_idle(set.device)
	pixels, w, h, ok := renderer_capture(r)
	other, _, _, other_ok := renderer_capture(expected)
	defer {delete(pixels); delete(other)}
	if !testing.expect(t, ok && other_ok, r.error) {return}
	differing := 0
	for value, i in pixels {
		if value != other[i] {differing += 1}
	}
	testing.expectf(t, differing == 0, "%d of %d bytes of the image differ from the scene set again", differing, len(pixels))
	// The slab is where it was moved to: it shades the floor under its new place.
	shadow := pixel(pixels, w, project(r, MOVE_TEST_CAMERA, {2.1, 0.001, -0.2}))
	lit := pixel(pixels, w, project(r, MOVE_TEST_CAMERA, {-1.5, 0.001, 2.5}))
	testing.expectf(t, lit[0] > shadow[0] + 30, "the floor under the moved slab %v is darker than the open floor %v (%dx%d)", shadow, lit, w, h)
	expect_clean(t, moved.device)
	expect_clean(t, set.device)
}

// A zero scale leaves nothing of an instance to draw nor an inverse to take
// rays into its mesh: with one the software tree walked the whole mesh for
// every ray that reached its box.
@(test)
an_instance_scaled_to_zero_is_drawn_and_traced_as_a_hidden_one :: proc(t: ^testing.T) {
	zero, hidden: Cube_Fixture
	settings := move_settings()
	settings.trace_mode = .Software
	if !cube_fixture_init(t, &zero, 96, 64, settings) {return}
	defer fixture_destroy(&zero)
	if !cube_fixture_init(t, &hidden, 96, 64, settings) {return}
	defer fixture_destroy(&hidden)
	instances: [5]Instance_Desc
	move_scene(zero.cube, &instances)
	lights := []Light_Desc{{position = {2, 3, 2}, color = {1, 0.9, 0.8}, intensity = 20 * math.PI, range = 9}}
	for f in ([]^Cube_Fixture{&zero, &hidden}) {
		scene_set(f.renderer, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
		move_frames(t, f.renderer, 4)
	}
	r, expected := zero.renderer, hidden.renderer
	a, b := &r.scene, &expected.scene
	shown := instances[2].transform
	expect_same_image :: proc(t: ^testing.T, a, b: ^Cube_Fixture, what: string) {
		move_frames(t, a.renderer, 4)
		move_frames(t, b.renderer, 4)
		rhi.device_wait_idle(a.device)
		rhi.device_wait_idle(b.device)
		pixels, _, _, ok := renderer_capture(a.renderer)
		other, _, _, other_ok := renderer_capture(b.renderer)
		defer {delete(pixels); delete(other)}
		if !testing.expect(t, ok && other_ok, a.renderer.error) {return}
		differing := 0
		for value, i in pixels {if value != other[i] {differing += 1}}
		testing.expectf(t, differing == 0, "%s: %d of %d bytes of the image differ", what, differing, len(pixels))
	}
	expect_collapsed :: proc(t: ^testing.T, s: ^Scene_State, index: i32, what: string) {
		inst := s.instances[index]
		testing.expectf(t, inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED) == INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED, "%s: the instance is hidden by its transform", what)
		testing.expectf(t, inst.world_inv == {} && s.hw_instances[index].transform == {} && s.hw_instances[index].mask_flags & 0xff == 0, "%s: rays have no way into it", what)
		item := s.tlas_items[index]
		testing.expectf(t, item.bounds_min == item.bounds_max, "%s: its box %v is a point", what, item)
	}

	testing.expect(t, scene_move(r, {2}, {trs({0, 1.5, 0}, {0, 0, 0})}))
	instances[2].hidden = true
	scene_set(expected, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	expect_collapsed(t, a, a.desc_instance[2], "moved to a zero scale")
	testing.expect_value(t, a.hidden_count, b.hidden_count)
	testing.expect(t, a.bounds_min == b.bounds_min && a.bounds_max == b.bounds_max)
	without_min, without_max := b.bounds_min, b.bounds_max
	testing.expect(t, len(a.translucent) == len(b.translucent) && len(a.reflective) == len(b.reflective) && a.overlay_count == b.overlay_count)
	expect_same_image(t, &zero, &hidden, "moved to a zero scale")

	// A move that gives it an inverse shows it again, as a set that shows it;
	// the images differ by the motion it grows with.
	testing.expect(t, scene_move(r, {2}, {shown}))
	instances[2].hidden = false
	scene_set(expected, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	move_frames(t, r, 2)
	move_frames(t, expected, 2)
	for inst, i in a.instances {testing.expectf(t, inst == b.instances[i], "moved back: instance %d", i)}
	for hw, i in a.hw_instances {testing.expectf(t, hw == b.hw_instances[i], "moved back: hardware instance %d", i)}
	testing.expect_value(t, a.hidden_count, b.hidden_count)
	testing.expect(t, len(a.translucent) == len(b.translucent) && len(a.reflective) == len(b.reflective) && a.overlay_count == b.overlay_count)

	// A set gives the same, and a transform that is not finite hides it too.
	instances[2].transform = trs({0, 1.5, 0}, {0, 0, 0})
	scene_set(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	expect_collapsed(t, a, a.desc_instance[2], "set with a zero scale")
	instances[2].transform = trs({math.nan_f32(), 1.5, 0}, {1, 1, 1})
	scene_set(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	expect_collapsed(t, a, a.desc_instance[2], "set with a position that is not a number")
	testing.expect(t, a.has_bounds && a.bounds_min == without_min && a.bounds_max == without_max)
	// One hidden by its description stays hidden whatever its transform.
	instances[2].transform = trs({0, 1.5, 0}, {0, 0, 0})
	instances[2].hidden = true
	scene_set(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	testing.expect(t, a.instances[a.desc_instance[2]].meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED) == INSTANCE_FLAG_HIDDEN)
	testing.expect(t, scene_move(r, {2}, {shown}))
	testing.expect(t, a.instances[a.desc_instance[2]].meta.w & INSTANCE_FLAG_HIDDEN != 0)
	testing.expect_value(t, a.hidden_count, 1)
	expect_clean(t, zero.device)
	expect_clean(t, hidden.device)
}

@(test)
scene_tint_leaves_the_scene_that_setting_it_again_would :: proc(t: ^testing.T) {
	tinted, set: Cube_Fixture
	if !cube_fixture_init(t, &tinted, 96, 64, move_settings()) {return}
	defer fixture_destroy(&tinted)
	if !cube_fixture_init(t, &set, 96, 64, move_settings()) {return}
	defer fixture_destroy(&set)
	instances: [5]Instance_Desc
	move_scene(tinted.cube, &instances)
	for f in ([]^Cube_Fixture{&tinted, &set}) {
		scene_set(f.renderer, instances[:], nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
		move_frames(t, f.renderer, 4)
	}
	r, expected := tinted.renderer, set.renderer
	testing.expect(t, !scene_tint(r, {3}, {}, {}))
	testing.expect(t, !scene_tint(r, {9}, {{1, 1, 1}}, {{}}))
	// The same values, and an instance the set skipped, touch nothing.
	testing.expect(t, scene_tint(r, {0, 1}, {instances[0].tint, {1, 0, 0}}, {instances[0].emission, {}}))
	testing.expect_value(t, r.scene.touched_count, 0)

	instances[3].tint, instances[3].emission = {0.1, 0.9, 0.2}, {0, 3, 0}
	instances[4].emission = {2, 2, 6}
	nodes := len(r.scene.tlas_nodes)
	testing.expect(t, scene_tint(r, {3, 4}, {instances[3].tint, instances[4].tint}, {instances[3].emission, instances[4].emission}))
	scene_set(expected, instances[:], nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	a, b := &r.scene, &expected.scene
	for inst, i in a.instances {testing.expectf(t, inst == b.instances[i], "instance %d", i)}
	testing.expect(t, !a.instances_dirty && !a.tlas_nodes_dirty && (!a.tlas_dirty || !r.hardware_rt), "a tint sends its instances alone")
	testing.expect_value(t, a.touched_count, 2)
	testing.expect_value(t, len(a.tlas_nodes), nodes)
	move_frames(t, r, 1)
	testing.expect_value(t, a.touched_count, 0)
	move_frames(t, r, 5)
	move_frames(t, expected, 6)
	rhi.device_wait_idle(tinted.device)
	rhi.device_wait_idle(set.device)
	pixels, w, _, ok := renderer_capture(r)
	other, _, _, other_ok := renderer_capture(expected)
	defer {delete(pixels); delete(other)}
	if !testing.expect(t, ok && other_ok, r.error) {return}
	differing := 0
	for value, i in pixels {
		if value != other[i] {differing += 1}
	}
	testing.expectf(t, differing == 0, "%d of %d bytes of the image differ from the scene set again", differing, len(pixels))
	glow := pixel(pixels, w, project(r, MOVE_TEST_CAMERA, {-3, 1.001, 1}))
	testing.expectf(t, glow[1] > glow[0] + 40 && glow[1] > glow[2] + 40, "the box that was tinted glows green, got %v", glow)
	expect_clean(t, tinted.device)
	expect_clean(t, set.device)
}

// Every node holds exactly what is under it.
@(private = "file")
tlas_exact :: proc(s: ^Scene_State, node: int) -> (bmin, bmax: Vec3, ok: bool) {
	n := s.tlas_nodes[node]
	bmin, bmax = Vec3{1e30, 1e30, 1e30}, Vec3{-1e30, -1e30, -1e30}
	ok = true
	if n.count > 0 {
		for ref in s.tlas_refs[n.left_first:][:n.count] {
			item := s.tlas_items[ref &~ TLAS_REF_GLASS]
			for axis in 0 ..< 3 {bmin[axis], bmax[axis] = min(bmin[axis], item.bounds_min[axis]), max(bmax[axis], item.bounds_max[axis])}
		}
	} else {
		for child in ([2]int{int(n.left_first), int(n.left_first) + 1}) {
			cmin, cmax, child_ok := tlas_exact(s, child)
			ok &&= child_ok
			for axis in 0 ..< 3 {bmin[axis], bmax[axis] = min(bmin[axis], cmin[axis]), max(bmax[axis], cmax[axis])}
		}
	}
	return bmin, bmax, ok && bmin == n.bounds_min && bmax == n.bounds_max
}

@(private = "file")
move_grid :: proc(cube: Mesh_Handle, count: int, allocator := context.allocator) -> []Instance_Desc {
	instances := make([]Instance_Desc, count, allocator)
	side := 1
	for side * side < count {side += 1}
	for &instance, i in instances {
		instance = {object_id = u64(i + 1), mesh = cube, transform = trs({(f32(i % side) - f32(side - 1) * 0.5) * 1.5, 0.5, (f32(i / side) - f32(side - 1) * 0.5) * 1.5}, {1, 1, 1}), tint = {0.7, 0.7, 0.7}}
	}
	return instances
}

@(test)
scene_move_refits_the_tree_of_a_large_scene_until_it_fits_badly :: proc(t: ^testing.T) {
	f: Cube_Fixture
	// The tree of the instances is kept for rays traced by software.
	settings := move_settings()
	settings.trace_mode = .Software
	if !cube_fixture_init(t, &f, 96, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := &r.scene
	count := 900
	instances := move_grid(f.cube, count)
	defer delete(instances)
	scene_set(r, instances, nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	move_frames(t, r, 2)
	built := make([]Gpu_Bvh_Node, len(s.tlas_nodes))
	defer delete(built)
	copy(built, s.tlas_nodes[:])
	_, _, exact := tlas_exact(s, 0)
	testing.expect(t, exact, "the tree as it was built")

	// A cube moved a little: the tree keeps its shape and holds it where it is now.
	near := trs({0.3, 2.5, 0.2}, {1, 1, 1})
	testing.expect(t, scene_move(r, {7}, {near}))
	testing.expect(t, s.tlas_nodes_dirty && !s.tlas_refs_dirty && !s.instances_dirty)
	testing.expect_value(t, len(s.tlas_nodes), len(built))
	shape := true
	changed := 0
	for node, i in s.tlas_nodes {
		shape &&= node.left_first == built[i].left_first && node.count == built[i].count
		if node != built[i] {changed += 1}
	}
	testing.expect(t, shape, "a refit keeps the shape of the tree")
	testing.expect(t, changed > 0 && changed < 64, "only what holds the cube changed")
	_, _, exact = tlas_exact(s, 0)
	testing.expect(t, exact, "the refit tree")
	testing.expect(t, s.bounds_max.y >= 3 - 1e-4, "the bounds of the scene follow the move")
	move_frames(t, r, 3)
	testing.expect(t, !s.tlas_nodes_dirty && s.touched_count == 0)

	// Far away it would stretch every node above it: the tree is built again.
	far := trs({5000, 0.5, -4000}, {1, 1, 1})
	testing.expect(t, scene_move(r, {7}, {far}))
	testing.expect(t, s.tlas_refs_dirty, "a tree that fits too badly is built again")
	_, _, exact = tlas_exact(s, 0)
	testing.expect(t, exact, "the tree built again")
	move_frames(t, r, 3)

	// Many at once go as few do: alone, not with the whole table.
	many := make([]u32, 296)
	places := make([]Mat4, len(many))
	defer {delete(many); delete(places)}
	for &desc, i in many {
		desc = u32(20 + i)
		places[i] = instances[20 + i].transform
		places[i][1, 3] += 0.25
	}
	testing.expect(t, scene_move(r, many, places))
	testing.expect(t, !s.instances_dirty && s.touched_count == len(many))
	move_frames(t, r, 3)
	testing.expect(t, !s.instances_dirty && s.touched_count == 0)
	for inst in s.instances {testing.expect(t, inst.prev_world == inst.world)}
	_, _, exact = tlas_exact(s, 0)
	testing.expect(t, exact, "the tree after many moved")
	expect_clean(t, f.device)
}

@(test)
scene_set_lights_replaces_the_lights_alone :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 96, 64, move_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := &r.scene
	instances: [5]Instance_Desc
	move_scene(f.cube, &instances)
	scene_set(r, instances[:], {{position = {2, 3, 2}, color = {1, 1, 1}, intensity = 20 * math.PI, range = 9}}, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	move_frames(t, r, 3)
	nodes := len(s.tlas_nodes)
	scene_set_lights(r, {{position = {2, 3, 2}, color = {1, 1, 1}, intensity = 5 * math.PI, range = 9}, {position = {-2, 3, 2}, color = {1, 0, 0}, intensity = 15 * math.PI, range = 9}, {position = {0, 1, 0}, intensity = 0 * math.PI, range = 9}}, {}, MOVE_TEST_ENVIRONMENT)
	testing.expect_value(t, len(s.lights), 2)
	testing.expect_value(t, len(s.light_tree), 3)
	testing.expect(t, s.lights_dirty && !s.instances_dirty && !s.tlas_nodes_dirty && !s.sun.enabled)
	testing.expect_value(t, len(s.instances), 4)
	testing.expect_value(t, len(s.tlas_nodes), nodes)
	move_frames(t, r, 2)
	testing.expect(t, !s.lights_dirty)
	expect_clean(t, f.device)
}

@(test)
scene_set_lights_sends_only_what_changed_and_the_gpu_holds_the_lights_of_the_scene :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 96, 64, move_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := &r.scene
	instances: [5]Instance_Desc
	move_scene(f.cube, &instances)
	lights := make([]Light_Desc, 300)
	defer delete(lights)
	for &light, i in lights {light = {position = {f32(i % 20) * 0.6 - 6, 1, f32(i / 20) * 0.6 - 4}, color = {1, 0.8, 0.6}, intensity = 10, range = 3, radius = 0.05}}
	scene_set(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	move_frames(t, r, 2)
	for i in 0 ..< 3 {
		lights[37 + i * 50].position.y += 0.4
		lights[37 + i * 50].intensity = 12
		scene_set_lights(r, lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
		testing.expect(t, !s.lights_dirty && len(s.light_ranges) == 1 && len(s.light_node_ranges) > 0, "the light that changed goes alone, with the nodes above it")
		move_frames(t, r, 1)
	}
	rhi.device_wait_idle(f.device)
	gpu_lights := make([]Gpu_Light, len(s.lights))
	defer delete(gpu_lights)
	nodes := make([]Gpu_Light_Node, len(s.light_tree))
	defer delete(nodes)
	testing.expect(t, rhi.buffer_read_slice(f.device, s.light_buffer, 0, gpu_lights) && rhi.buffer_read_slice(f.device, s.light_tree_buffer, 0, nodes))
	testing.expect(t, mem.compare(mem.slice_to_bytes(gpu_lights), mem.slice_to_bytes(s.lights[:])) == 0, "the GPU holds the lights of the scene")
	testing.expect(t, mem.compare(mem.slice_to_bytes(nodes), mem.slice_to_bytes(s.light_tree[:])) == 0, "and their tree")
	expect_clean(t, f.device)
}

MOVE_BENCHMARK :: #config(RENDER_BENCHMARK, false)

// What one instance that moves costs the scene of the renderer, against
// setting the scene again, without the frame that uploads it.
@(test)
scene_benchmark_moves_one_instance_of_many :: proc(t: ^testing.T) {
	when !MOVE_BENCHMARK {return} else {
		f: Cube_Fixture
		if !cube_fixture_init(t, &f, 96, 64, move_settings()) {return}
		defer fixture_destroy(&f)
		r := f.renderer
		for count in ([]int{100, 500, 2000, 20000}) {
			instances := move_grid(f.cube, count)
			defer delete(instances)
			scene_set(r, instances, nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
			set, move := time.Duration(max(i64)), time.Duration(max(i64))
			for round in 0 ..< 10 {
				instances[5].transform[1, 3] = 0.5 + f32(round) * 0.01
				start := time.tick_now()
				scene_set(r, instances, nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
				set = min(set, time.tick_since(start))
			}
			for round in 0 ..< 50 {
				instances[5].transform[1, 3] = 0.7 + f32(round) * 0.01
				start := time.tick_now()
				scene_move(r, {5}, {instances[5].transform})
				move = min(move, time.tick_since(start))
			}
			fmt.printfln("scene: %d instances; scene_set %.2f ms, scene_move of one %.1f us", count, time.duration_milliseconds(set), time.duration_microseconds(move))
		}
	}
}

@(private = "file")
Stages_Seen :: struct {
	runs:          [Frame_Stage]int,
	width, height: u32,
	eye:           Vec4,
	vertices:      bool,
	nested:        u32,
	data:          int,
	image:         bool,
	lit_image:     bool,
	kept:          [4]bool, // of the texture with history, frame by frame
	textures:      bool,    // every texture asked for was bound
	refused:       bool,    // a description no compute shader writes was refused
	worlds:        [2]u64,  // of the Simulate pass, frame by frame
	made:          [2]bool, // the buffer of the world, frame by frame
	written:       bool,    // rows went into it
	sides:         [Glass_Side]int,
	gbuffer:       bool,    // a pass over the G-buffer began and ended
	counters:      bool,    // the counters of a name were bound
	effect:        Texture_Handle, // the texture of the effect view the Effect pass drew
	effect_size:   [2]u32,
	post:          bool,   // the Post pass read the image and wrote the next one
	post_size:     [2]u32,
	mips:          bool,   // a texture with mips bound one of them and refused one past them
}

// What an extension is given at each stage, with the shaders of the engine,
// which have nothing of extensions: no nested views, no constants, no stages.
@(test)
render_stages_run_once_a_frame_and_for_its_view :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 96, 64, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{{object_id = 1, mesh = f.cube, transform = trs({0, 0, 0}, {1, 1, 1}), tint = {0.8, 0.8, 0.8}}}
	scene_set(r, instances, nil, {direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}, {sky = {0.3, 0.4, 0.6}})
	camera := Camera{position = {0, 2, 5}, forward = {0, -2, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	record :: proc(s: ^Stage_Pass, user: rawptr) {
		seen := cast(^Stages_Seen)user
		seen.runs[s.stage] += 1
		switch s.stage {
		case .Geometry:
			seen.vertices = pass_vertices_begin(s, "test vertices") && s.width == 0 && s.height == 0
		case .Mask:
			seen.width, seen.height, seen.eye = s.width, s.height, s.eye
			seen.nested = pass_nested_add(s, {to_world = 1, previous = 1})
			seen.data = len(pass_extension_data(s, "absent"))
			pass_mask_begin(s, "test mask")
			pass_scissor(s, {1, 1, 4, 4})
			pass_scissor(s, {})
			pass_end(s)
		case .Surface:
			pass_surface_begin(s, {.Albedo, .Emission}, "test surfaces")
			pass_end(s)
		case .Lit:
			seen.lit_image = pass_image_bind(s, 0)
			at := seen.runs[.Lit] - 1
			// The texture of the third frame is another size: it is made again and keeps nothing.
			kept_ok, kept := pass_texture(s, 1, {name = "test light", format = .RGBA16_Float, width = 4, height = 4, depth = 3 if at == 2 else 2, history = true})
			previous_ok, _ := pass_texture(s, 2, {name = "test light", format = .RGBA16_Float, width = 4, height = 4, depth = 3 if at == 2 else 2, history = true}, previous = true)
			flat_ok, _ := pass_texture(s, 3, {name = "test flat", format = .R32_Float, width = 8, height = 2})
			refused, _ := pass_texture(s, 4, {name = "test depth", format = .D32_Float, width = 8, height = 2})
			seen.textures = (at == 0 || seen.textures) && kept_ok && previous_ok && flat_ok
			seen.refused = !refused
			if at < len(seen.kept) {seen.kept[at] = kept}
		case .Simulate:
			at := seen.runs[.Simulate] - 1
			if at < len(seen.worlds) {seen.worlds[at] = s.world}
			// The second frame asks for it again: the renderer keeps it.
			ok, made := pass_buffer(s, 0, {name = "test state", size = 64})
			if at < len(seen.made) {seen.made[at] = ok && made}
			rows := [4]u32{1, 2, 3, 4}
			seen.written = pass_buffer_write(s, {name = "test state", size = 64}, 16, &rows, size_of(rows)) && pass_buffer_fill(s, {name = "test state", size = 64}, 0, 16, 0)
			seen.written &&= !pass_buffer_write(s, {name = "test state", size = 32}, 0, &rows, size_of(rows))
			seen.counters = pass_counters(s, 1, "test counters")
		case .Gbuffer:
			pass_gbuffer_begin(s, "test gbuffer")
			pass_end(s)
			seen.gbuffer = true
		case .Blend:
			seen.sides[s.glass] += 1
			pass_blend_begin(s, "test blend")
			pass_end(s)
		case .Effect:
			seen.effect, seen.effect_size = s.texture, {s.width, s.height}
			pass_blend_begin(s, "test effect")
			pass_end(s)
		case .Post:
			seen.post_size = {s.output_width, s.output_height}
			seen.post = pass_image_bind(s, 0) && pass_image_write(s, 0, 1) && !pass_image_write(s, 2, 2)
			chain := Pass_Texture_Desc{name = "test chain", format = .RGBA16_Float, width = 8, height = 4, mips = RENDER_MIPS_ALL}
			last, _ := pass_texture(s, 2, chain, mip = 3)
			beyond, _ := pass_texture(s, 3, chain, mip = 4)
			seen.mips = last && !beyond
		case .Custom:
		case .Inspect:
			seen.width, seen.height = s.width, s.height
			seen.image = pass_image_bind(s, 0)
		}
	}
	seen: Stages_Seen
	for stage in ([]Frame_Stage{.Geometry, .Simulate, .Gbuffer, .Mask, .Surface, .Lit, .Blend, .Post, .Effect}) {testing.expect(t, frame_pass(r, stage, record, &seen))}
	testing.expect(t, !frame_pass(r, .Mask, nil))
	testing.expect(t, !frame_pass(r, .Custom, record, &seen), "a Custom pass goes in a render pipeline")
	testing.expect(t, !frame_pass(r, .Inspect, record, &seen), "an Inspect pass goes in the inspection of a view")
	effect, made := ui_texture_add(r, 8, 4, "test effect", effects = true)
	testing.expect(t, made)
	// The passes are of the frame they were asked for.
	testing.expect(t, renderer_frame(r, {camera = camera, effect_views = {{texture = effect, camera = camera}}}), r.error)
	for i in 0 ..< 2 {
		testing.expect(t, frame_pass(r, .Lit, record, &seen))
		if i == 0 {testing.expect(t, frame_pass(r, .Simulate, record, &seen))}
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, seen.runs, [Frame_Stage]int{.Geometry = 1, .Simulate = 2, .Gbuffer = 1, .Mask = 1, .Surface = 1, .Lit = 3, .Blend = 1, .Post = 1, .Effect = 1, .Custom = 0, .Inspect = 0})
	testing.expect(t, seen.post && seen.mips)
	testing.expect_value(t, seen.post_size, [2]u32{r.main.targets.output_width, r.main.targets.output_height})
	testing.expect_value(t, seen.effect, effect)
	testing.expect_value(t, seen.effect_size, [2]u32{8, 4})
	testing.expect(t, ui_texture_remove(r, effect))
	testing.expect(t, seen.lit_image && seen.textures && seen.refused)
	// The buffer of a world is made once and kept for it.
	testing.expect_value(t, seen.worlds, [2]u64{r.world_key, r.world_key})
	testing.expect_value(t, seen.made, [2]bool{true, false})
	testing.expect(t, seen.written && seen.gbuffer && seen.counters)
	testing.expect_value(t, seen.sides, [Glass_Side]int{.All = 1, .Behind = 0, .Front = 0})
	values, counted := renderer_counters(r, "test counters")
	testing.expect(t, counted && values == {})
	testing.expect(t, buffer_release(r, r.world_key, "test state"))
	testing.expect(t, !buffer_release(r, r.world_key, "test state"))
	// The texture with history keeps the frame before, until it is made again.
	testing.expect_value(t, seen.kept, [4]bool{false, true, false, false})
	held := 0
	for entry in r.main.extension_textures {if entry.key != 0 {held += 1}}
	testing.expect_value(t, held, 2)
	testing.expect(t, seen.vertices)
	testing.expect_value(t, seen.width, r.main.targets.width)
	testing.expect_value(t, seen.height, r.main.targets.height)
	testing.expect_value(t, seen.eye, Vec4{0, 2, 5, 1})
	testing.expect_value(t, seen.nested, u32(0))
	testing.expect_value(t, seen.data, 0)
	// The pass of an inspection runs for the view that names it, in the frames that name it.
	seen.width, seen.height = 0, 0
	testing.expect(t, renderer_frame(r, {camera = camera, inspection = {record = record, user = &seen}}), r.error)
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	rhi.device_wait_idle(f.device)
	testing.expect_value(t, seen.runs[.Inspect], 1)
	testing.expect(t, seen.image && seen.width == r.main.targets.width && seen.height == r.main.targets.height)
	// A view that went a frame without asking for its textures has them no more; one that is inspected runs no Lit pass.
	testing.expect_value(t, seen.runs[.Lit], 3)
	for entry in r.main.extension_textures {testing.expect_value(t, entry.key, u64(0))}
	for _ in 0 ..< 2 {
		testing.expect_value(t, stage_pipeline(r, {stage = .Surface, shader = "absent", targets = {.Albedo}, name = "absent"}), rhi.Pipeline(0))
		testing.expect_value(t, stage_pipeline(r, {stage = .Geometry, shader = "absent", name = "absent"}), rhi.Pipeline(0))
	}
	asked := 0
	for entry in r.stage_pipelines {if entry.asked {asked += 1}}
	testing.expect_value(t, asked, 2)
	expect_clean(t, f.device)
}


// The renderer draws relative to an origin that follows the eye: a scene
// 15 km from the centre of the world looks as it does at the centre, and the
// frame after the origin jumps goes on from the one before as any other does.
@(test)
render_far_from_the_centre_looks_as_at_it_and_a_jump_keeps_the_history :: proc(t: ^testing.T) {
	W :: 96
	H :: 64
	Image :: [W * H * 4]f16
	// On the heap: six images overflow the stack of a test.
	shown :: proc(t: ^testing.T, at: Vec3, jump: bool, offscreen := false) -> (image, next: ^Image, origin: Vec3) {
		image, next = new(Image), new(Image)
		f: Cube_Fixture
		settings := test_settings()
		settings.gi_enabled = false
		if !cube_fixture_init(t, &f, W, H, settings) {return}
		defer fixture_destroy(&f)
		r := f.renderer
		instances := []Instance_Desc{
			{object_id = 1, mesh = f.cube, transform = trs(at + {0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}},
			{object_id = 2, mesh = f.cube, transform = trs(at + {0, 0.5, 0}, {1, 1, 1}), tint = {0.9, 0.3, 0.2}},
		}
		lights := []Light_Desc{{position = at + {1.5, 2, 1}, color = {1, 0.9, 0.8}, intensity = 20, range = 10}}
		scene_set(r, instances, lights, {direction = {1, 1, 0}, color = {1, 1, 1}, illuminance = math.PI, enabled = true}, {use_background = true})
		camera := Camera{position = at + {0, 2, 5}, forward = {0, -2, -5}, up = {0, 1, 0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		for _ in 0 ..< 16 {testing.expect(t, renderer_frame(r, {camera = camera, offscreen = offscreen}), r.error)}
		testing.expect(t, golden_read_texture(f.device, r.targets.display, mem.slice_data_cast([]u8, image[:])), rhi.device_error(f.device))
		origin = renderer_origin(r)
		// The eye stays within reach of where the origin jumps to.
		if jump {renderer_origin_set(r, origin + {-ORIGIN_STEP, 0, ORIGIN_STEP})}
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		testing.expect(t, golden_read_texture(f.device, r.targets.display, mem.slice_data_cast([]u8, next[:])), rhi.device_error(f.device))
		expect_clean(t, f.device)
		return
	}
	difference :: proc(a, b: ^Image) -> (mean, most: f32) {
		for i in 0 ..< len(a) {
			if i % 4 == 3 {continue}
			d := abs(f32(a[i]) - f32(b[i]))
			mean += d
			most = max(most, d)
		}
		return mean / f32(W * H * 3), most
	}
	centre, centre_next, at_centre := shown(t, {}, false)
	far, jumped, at_far := shown(t, {15000, 0, -12000}, true)
	defer {free(centre); free(centre_next); free(far); free(jumped)}
	testing.expect_value(t, at_centre, Vec3{})
	testing.expect_value(t, at_far, Vec3{15360, 0, -12288})
	mean, most := difference(centre, far)
	testing.expectf(t, mean < 0.002 && most < 0.05, "15 km away the image is the one at the centre: mean %v, most %v", mean, most)
	still, still_most := difference(centre, centre_next)
	mean, most = difference(far, jumped)
	testing.expectf(t, mean <= still * 1.5 + 1e-4 && most <= still_most * 1.5 + 1e-3, "the frame after a jump goes on from the one before as any other: mean %v, most %v; without a jump %v, %v", mean, most, still, still_most)
	// An offscreen frame does not move the origin: 15 km from it, its view
	// projects from its eye and looks as one at the centre.
	away, away_next, at_away := shown(t, {15000, 0, -12000}, false, offscreen = true)
	defer {free(away); free(away_next)}
	testing.expect_value(t, at_away, Vec3{})
	mean, most = difference(centre, away)
	testing.expectf(t, mean < 0.002 && most < 0.05, "a view 15 km from the origin is the one at it: mean %v, most %v", mean, most)
}
