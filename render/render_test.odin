package mirai_render

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:render/abi"
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

// What the maps of the main view drew in the last frame: the pages the cache
// drew again, those the atlas composed again, and those asked for and left
// out of the pool (shadow_pages.comp).
@(private = "file")
shadow_counts :: proc(r: ^Renderer) -> (drawn, composed, left: u32) {
	rhi.device_wait_idle(r.device)
	counts: [8]u32
	if r.main.targets.shadow_raster.pages == 0 || !rhi.buffer_read_slice(r.device, r.main.targets.shadow_raster.pages, u64(abi.SHADOW_WORDS_COUNTS) * 4, counts[:]) {return}
	return counts[abi.SHADOW_COUNT_DRAWN], counts[abi.SHADOW_COUNT_COMPOSED], counts[abi.SHADOW_COUNT_LEFT]
}

// The most units a cluster costs in a page (render.shadow_units): its
// triangles over all of its texels, masked, and its vertices, placed and drawn.
@(private = "file")
PAGE_UNITS :: asset.CLUSTER_TRIANGLES * SHADOW_PAGE * SHADOW_PAGE * abi.SHADOW_MASKED_COST / abi.SHADOW_UNIT_TEXELS + 2 * asset.CLUSTER_VERTICES / abi.SHADOW_UNIT_VERTICES

// The clusters the cache of the maps of the last view drew in the last frame,
// once for each page they cover (Shadow_Stats).
@(private = "file")
shadow_clusters :: proc(r: ^Renderer) -> u32 {
	rhi.device_wait_idle(r.device)
	stats: [1]Shadow_Stats
	if !rhi.buffer_read_slice(r.device, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow)), stats[:]) {return max(u32)}
	return stats[0].clusters + stats[0].clusters_masked
}

// How many times the steps of the pages of the main view gave them (shadow_pages.comp).
@(private = "file")
shadow_page_runs :: proc(r: ^Renderer) -> u32 {
	rhi.device_wait_idle(r.device)
	runs: [1]u32
	if r.main.targets.shadow_raster.pages == 0 || !rhi.buffer_read_slice(r.device, r.main.targets.shadow_raster.pages, u64(abi.SHADOW_STEP_RUNS) * 4, runs[:]) {return max(u32)}
	return runs[0]
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
cube_fixture_init :: proc(t: ^testing.T, f: ^Cube_Fixture, width, height: u32, settings: Settings, programs := false, reference := Reference_Set{}, loc := #caller_location) -> bool {
	if !fixture_init(t, f, width, height, settings, programs = programs, reference = reference, loc = loc) {return false}
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
	scene_given(r, instances, nil, {direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.3, 0.4, 0.6}})
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

// A slab without shadows is drawn and lets the sun through: the floor under
// it is lit as without it, by each tracer. It stops casting in a change of
// the scene, which takes it out of the maps the frames before drew.
@(test)
render_a_mesh_without_shadows_lets_the_sun_through :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 192, 128, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}}
	slab := Instance_Desc{object_id = 2, mesh = f.cube, transform = trs({0, 1.5, 0}, {2, 0.2, 2}), tint = {0.5, 0.5, 0.5}}
	sun := Sun_Desc{direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}
	sky := Environment{sky = {0.3, 0.4, 0.6}}
	camera := Camera{position = {0, 8, 7}, forward = {0, -8, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	under, top := project(r, camera, {0, 0.001, 0.8}), project(r, camera, {0, 1.6, 0})
	for mode in ([]Trace_Mode{.Software, .Hardware}) {
		if !fixture_traces(r, mode) {continue}
		applied := r.settings
		applied.trace_mode = mode
		testing.expect(t, renderer_apply_settings(r, applied))
		// Without the slab, with it, and with it given again without shadows.
		lit, seen: [3]Vec3
		for k in 0 ..< 3 {
			switch k {
			case 0: testing.expect(t, scene_given(r, {floor}, nil, sun, sky), r.error)
			case 1: testing.expect(t, scene_given(r, {floor, slab}, nil, sun, sky), r.error)
			case 2:
				shadowless := slab
				shadowless.shadowless = true
				testing.expect(t, scene_update(r, 1, {shadowless}), r.error)
			}
			for _ in 0 ..< 12 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
			rhi.device_wait_idle(f.device)
			pixels, w, _, ok := golden_capture(r)
			if !testing.expect(t, ok, r.error) {return}
			lit[k], seen[k] = pixel(pixels, w, under), pixel(pixels, w, top)
			delete(pixels)
		}
		testing.expectf(t, lit[1].x + 40 < lit[0].x, "%v: the slab shades the floor: %v under it, %v without it", mode, lit[1], lit[0])
		testing.expectf(t, abs(lit[2].x - lit[0].x) < 12, "%v: the slab without shadows lets the sun through: %v under it, %v without it", mode, lit[2], lit[0])
		testing.expectf(t, abs(seen[2].x - seen[1].x) < 4 && abs(seen[2].x - seen[0].x) > 20, "%v: the slab without shadows is drawn: %v, %v with them, %v without the slab", mode, seen[2], seen[1], seen[0])
	}
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
	scene_given(r, instances, nil, {direction = {1, 1, 0}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0, 0, 0}})
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
	sun := Sun_Desc{direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}
	scene_given(r, instances, nil, sun, {sky = {0, 0, 0}})
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
	scene_given(r, instances[:1], nil, sun, {sky = {0, 0, 0}})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	after := read(t, &f, camera, under)
	testing.expectf(t, after > lit - 12, "the frame after its caster is gone the floor has its light: %f of %f", after, lit)
	expect_clean(t, f.device)
}

// The maps of the shadows keep what does not move: a caster that moves once,
// one that keeps moving, one that stops and a light that moves each change the
// shadow in the frame they change it.
@(test)
render_shadow_maps_follow_what_moves_in_its_frame :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A slab 1.5 m under a light 3 m up shades the floor twice as far from under the light as it is.
	slab :: proc(x: f32) -> Mat4 {return trs({x, 1.5, 0}, {1, 0.2, 1})}
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {16, 0.2, 16}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = slab(-1), tint = {0.5, 0.5, 0.5}},
	}
	light := Light_Desc{position = {0, 3, 0}, color = {1, 1, 1}, intensity = 30 * math.PI, range = 14, indirect = 1, scattering = 1}
	testing.expect(t, scene_given(r, instances, []Light_Desc{light}, {}, {}))
	camera := Camera{position = {0, 9, 0.001}, forward = {0, -9, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// After one frame, the floor at `dark` is in shadow and the one as far from the light at `lit` is not.
	expect_shadow :: proc(t: ^testing.T, f: ^Cube_Fixture, camera: Camera, dark, lit: f32, what: string, loc := #caller_location) {
		r := f.renderer
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error, loc = loc)
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := golden_capture(r)
		testing.expect(t, ok, r.error, loc = loc)
		if !ok {return}
		defer delete(pixels)
		shaded, open := pixel(pixels, w, project(r, camera, {dark, 0.001, 0}))[0], pixel(pixels, w, project(r, camera, {lit, 0.001, 0}))[0]
		testing.expectf(t, open > 40 && shaded < 0.5 * open, "%s: the floor at %v has %f against %f at %v", what, dark, shaded, open, lit, loc = loc)
	}
	for _ in 0 ..< 8 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	expect_shadow(t, &f, camera, -2, 2, "still")
	moved := []u32{1}
	testing.expect(t, scene_move(r, moved, []Mat4{slab(1)}))
	expect_shadow(t, &f, camera, 2, -2, "moved once")
	for k in 0 ..< 4 {
		x := f32(-1) if k % 2 == 0 else 1
		testing.expect(t, scene_move(r, moved, []Mat4{slab(x)}))
		expect_shadow(t, &f, camera, 2 * x, -2 * x, "moving")
	}
	for _ in 0 ..< SHADOW_MOVER_FRAMES {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	expect_shadow(t, &f, camera, 2, -2, "stopped")
	// The light 1 m to the side: the slab at 1 shades the floor at 3, which
	// the light lit as it lit the floor at -1.
	light.position = {-1, 3, 0}
	testing.expect(t, scene_light_update(r, 0, light))
	expect_shadow(t, &f, camera, 3, -5, "the light moved")
	// More casters move than the samples keep boxes of and than the maps once
	// followed: each is drawn over the cache, which draws nothing again, and
	// the image is that of maps drawn whole.
	many: [301]Instance_Desc
	many[0] = instances[0]
	place :: proc(k: int, shift: f32) -> Mat4 {return trs({f32(k % 20) * 0.4 - 3.8 + shift, 1.2, f32(k / 20) * 0.4 - 3}, {0.15, 0.1, 0.15})}
	for k in 1 ..< len(many) {many[k] = {object_id = u64(k + 1), mesh = f.cube, transform = place(k - 1, 0), tint = {0.5, 0.5, 0.5}}}
	light.position = {0, 3, 0}
	testing.expect(t, scene_given(r, many[:], []Light_Desc{light}, {}, {}))
	indices: [300]u32
	moves: [300]Mat4
	for k in 0 ..< 4 {
		for &index, i in indices {index, moves[i] = u32(i + 1), place(i, 0.05 * f32(k % 2))}
		testing.expect(t, scene_move(r, indices[:], moves[:]))
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	}
	drawn, composed, _ := shadow_counts(r)
	testing.expectf(t, r.stats.shadow_movers == 300 && drawn == 0 && composed > 0, "300 moving casters: %d drawn as movers, %d pages of the cache drawn again, %d composed", r.stats.shadow_movers, drawn, composed)
	// Still for a frame, they compose no page of the atlas again.
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	drawn, composed, _ = shadow_counts(r)
	testing.expectf(t, composed == 0 && drawn == 0, "300 still movers: %d pages composed, %d drawn again", composed, drawn)
	read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
		rhi.device_wait_idle(f.device)
		pixels, _, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		return pixels
	}
	cached := read(t, &f)
	defer delete(cached)
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	whole := read(t, &f)
	defer delete(whole)
	differ := 0
	for v, k in cached {if k < len(whole) && abs(int(v) - int(whole[k])) > 2 {differ += 1}}
	testing.expectf(t, len(cached) == len(whole) && differ * 1000 <= len(cached), "%d of %d values differ from the maps drawn whole", differ, len(cached))
	// What moves under what stays casts nothing the cache does not hide there:
	// a cube moving under a roof the light shines on gives the round of what
	// moves no cluster, and the image is that of maps drawn whole.
	roofed := []Instance_Desc{
		instances[0],
		{object_id = 2, mesh = f.cube, transform = trs({0, 2.2, 0}, {6, 0.2, 6}), tint = {0.5, 0.5, 0.5}},
		{object_id = 3, mesh = f.cube, transform = trs({0.5, 0.5, 0}, {0.4, 0.4, 0.4}), tint = {0.5, 0.5, 0.5}},
	}
	testing.expect(t, scene_given(r, roofed, []Light_Desc{light}, {}, {}))
	// What moved before stays long enough to join the cache again.
	for _ in 0 ..< SHADOW_MOVER_FRAMES {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	for k in 0 ..< 6 {
		testing.expect(t, scene_move(r, {2}, {trs({0.5 + 0.1 * f32(k % 2), 0.5, 0}, {0.4, 0.4, 0.4})}))
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	}
	rhi.device_wait_idle(f.device)
	state: [1]Gpu_Cull_State
	testing.expect(t, rhi.buffer_read_slice(f.device, r.shadow_buffers.state, 0, state[:]))
	entries := state[0].listed[0]
	testing.expectf(t, r.stats.shadow_movers == 1 && entries == 0, "a cube moving under a roof: %d movers, %d clusters drawn as what moves", r.stats.shadow_movers, entries)
	hidden := read(t, &f)
	defer delete(hidden)
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	fresh := read(t, &f)
	defer delete(fresh)
	differ = 0
	for v, k in hidden {if k < len(fresh) && abs(int(v) - int(fresh[k])) > 2 {differ += 1}}
	testing.expectf(t, len(hidden) == len(fresh) && differ * 1000 <= len(hidden), "under a roof %d of %d values differ from the maps drawn whole", differ, len(hidden))
	// One caster among many that stay moves once: the cache draws again the
	// texels of its pages its boxes cover, not what else lies in those pages,
	// and the image is that of maps drawn whole.
	testing.expect(t, scene_given(r, many[:], []Light_Desc{light}, {}, {}))
	for _ in 0 ..< SHADOW_MOVER_FRAMES + 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expect(t, scene_move(r, {150}, {place(149, 0.05)}))
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	part := shadow_clusters(r)
	one := read(t, &f)
	defer delete(one)
	// Maps drawn whole draw into the atlas alone, and their cache the frame after.
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	all := read(t, &f)
	defer delete(all)
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	every := shadow_clusters(r)
	testing.expectf(t, part > 0 && part * 8 < every, "one caster of 300 moved: the cache drew %d clusters again, %d when drawn whole", part, every)
	differ = 0
	for v, k in one {if k < len(all) && abs(int(v) - int(all[k])) > 2 {differ += 1}}
	testing.expectf(t, len(one) == len(all) && differ * 1000 <= len(one), "after one caster moved %d of %d values differ from the maps drawn whole", differ, len(one))
	expect_clean(t, f.device)
}

// A batch of a deformable that casts shadows and sways (the wind): where its
// sway is wider than a texel of the maps they draw it as it is each frame it
// sways; where it is narrower they draw it at rest and keep it, drawing
// nothing again.
@(test)
render_a_swaying_batch_shades_where_it_is :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {16, 0.2, 16}), tint = {0.8, 0.8, 0.8}}
	light := Light_Desc{position = {0, 3, 0}, color = {1, 1, 1}, intensity = 30 * math.PI, range = 14, indirect = 1, scattering = 1}
	testing.expect(t, scene_given(r, {floor}, []Light_Desc{light}, {}, {}))
	camera := Camera{position = {0, 9, 0.001}, forward = {0, -9, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// The vertices of the slab, at rest under the light, moved along x by sway.
	Sway :: struct {mesh: Mesh_Handle, x: f32}
	write :: proc(s: ^Stage_Pass, user: rawptr) {
		sway := (^Sway)(user)
		r := s.pass.r
		written, rest, count, _, known := deformable_vertices(r, sway.mesh)
		if !known {return}
		vertices, at := rhi.frame_alloc_typed(r.device, Gpu_Posed_Vertex, int(count))
		if vertices == nil {return}
		copy(vertices, ([^]Gpu_Posed_Vertex)(&r.scene.vertices[rest])[:count])
		for &v in vertices {v.position.x += sway.x}
		rhi.cmd_copy_buffer(s.pass.cmd, at.buffer, at.offset, r.scene.vertex_buffer, u64(written) * 4, u64(count) * size_of(Gpu_Posed_Vertex))
	}
	for wide in ([]bool{true, false}) {
		// Wide: it sways up to 1.2 m, wider than any texel; narrow, it says it
		// sways a tenth of a millimetre, narrower than every texel, and the maps keep it at rest.
		mesh, made := deformable_create(r, f.cube, false, 1.2 if wide else 0.0001)
		if !testing.expect(t, made) {return}
		defer mesh_remove(r, mesh)
		batch, problem := batch_set(r, 0, 0, {mesh = mesh, tint = 0.5, flags = {.Casts_Shadow, .Ray_Visible}}, {batch_instance({0, 1.5, 0}, 1, {1, 0.2, 1})})
		if !testing.expectf(t, problem == "", "%s", problem) {return}
		defer batch_remove(r, batch)
		sway := Sway{mesh = mesh}
		for k in 0 ..< 8 {
			sway.x = f32(-1) if k % 2 == 0 else 1
			low, high, _ := mesh_bounds(r, f.cube)
			testing.expect(t, deformable_update(r, mesh, low - 1.2, high + 1.2))
			testing.expect(t, frame_pass(r, .Geometry, write, &sway))
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
			if k < 4 {continue}
			rhi.device_wait_idle(f.device)
			pixels, w, _, ok := golden_capture(r)
			if !testing.expect(t, ok, r.error) {return}
			defer delete(pixels)
			at :: proc(r: ^Renderer, pixels: []u8, w: int, camera: Camera, x: f32) -> f32 {return pixel(pixels, w, project(r, camera, {x, 0.001, 0}))[0]}
			if wide {
				shaded, open := at(r, pixels, w, camera, 2 * sway.x), at(r, pixels, w, camera, -2 * sway.x)
				testing.expectf(t, open > 40 && shaded < 0.5 * open, "frame %d: the floor under where it sways has %f against %f where it was", k, shaded, open)
				testing.expectf(t, r.stats.shadow_movers == 1, "frame %d: the swaying batch is drawn as what moves: %d movers", k, r.stats.shadow_movers)
			} else {
				shaded, open := at(r, pixels, w, camera, 0), at(r, pixels, w, camera, 2 * sway.x)
				testing.expectf(t, open > 40 && shaded < 0.5 * open, "frame %d: the floor under its rest has %f against %f where it sways", k, shaded, open)
				drawn, composed, _ := shadow_counts(r)
				testing.expectf(t, r.stats.shadow_movers == 0 && drawn == 0 && composed == 0, "frame %d: at rest in every map it moves nothing: %d movers, %d pages drawn again, %d composed", k, r.stats.shadow_movers, drawn, composed)
			}
		}
	}
	expect_clean(t, f.device)
}

// A batch casts into the maps as far as the view draws it: past its cull
// distance from the eye its shadow is gone too; the eye that comes near
// brings it back, and the one that goes away takes it from the pages the
// maps keep, each in the frame it moves.
@(test)
render_a_batch_casts_no_shadow_past_its_cull_distance :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {200, 0.2, 200}), tint = {0.8, 0.8, 0.8}}
	sun := Sun_Desc{direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}
	testing.expect(t, scene_given(r, {floor}, nil, sun, {sky = {0, 0, 0}}), r.error)
	batch, problem := batch_set(r, 0, 0, {mesh = f.cube, tint = 0.5, flags = {.Casts_Shadow, .Ray_Visible}, fade_distance = 25, cull_distance = 30}, {batch_instance({0, 1.5, 0}, 1, {2, 0.2, 2})})
	if !testing.expectf(t, problem == "", "%s", problem) {return}
	defer batch_remove(r, batch)
	far := Camera{position = {0, 20, 45}, forward = {0, -20, -45}, up = {0, 1, 0}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	near := Camera{position = {0, 8, 7}, forward = {0, -8, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// The floor under the slab and beside it, after a frame from the camera.
	floor_at :: proc(t: ^testing.T, f: ^Cube_Fixture, camera: Camera) -> (under, beside: f32) {
		r := f.renderer
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		rhi.device_wait_idle(f.device)
		pixels, w, _, ok := golden_capture(r)
		if !testing.expect(t, ok, r.error) {return}
		defer delete(pixels)
		return pixel(pixels, w, project(r, camera, {0, 0.001, 0.5}))[0], pixel(pixels, w, project(r, camera, {4, 0.001, 0.5}))[0]
	}
	for _ in 0 ..< 8 {testing.expect(t, renderer_frame(r, {camera = far}), r.error)}
	under, beside := floor_at(t, &f, far)
	testing.expectf(t, beside > 40 && abs(under - beside) < 12, "past its cull distance the slab casts no shadow: %f under it, %f beside it", under, beside)
	for k in 0 ..< 2 {
		under, beside = floor_at(t, &f, near)
		testing.expectf(t, beside > 40 && under < 0.5 * beside, "round %d, the eye near: the slab shades the floor under it, %f against %f", k, under, beside)
		under, beside = floor_at(t, &f, far)
		testing.expectf(t, beside > 40 && abs(under - beside) < 12, "round %d, the eye far again: no shadow stays of the slab, %f under it, %f beside it", k, under, beside)
	}
	expect_clean(t, f.device)
}

// A cascade of the sun the eye moves by whole texels keeps what it held where
// it still holds it and draws what came in: the image is the one of maps
// drawn whole.
@(test)
render_moved_cascades_give_what_whole_ones_give :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances: [10]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {40, 0.2, 40}), tint = {0.8, 0.8, 0.8}}
	for k in 1 ..< len(instances) {
		instances[k] = {object_id = u64(k + 1), mesh = f.cube, transform = trs({f32(k % 3) * 2.3 - 2.3, 0.8, f32(k / 3) * 2.1 - 3}, {0.3, 1.6, 0.3}), tint = {0.5, 0.5, 0.5}}
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}
	testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
	camera := Camera{position = {0, 5, 7}, forward = {0, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
		rhi.device_wait_idle(f.device)
		pixels, _, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		return pixels
	}
	for k in 0 ..< 12 {
		camera.position.x = 0.013 * f32(k)
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	}
	moved := read(t, &f)
	defer delete(moved)
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	whole := read(t, &f)
	defer delete(whole)
	if len(moved) != len(whole) || len(moved) == 0 {return}
	differ := 0
	for v, k in moved {if abs(int(v) - int(whole[k])) > 2 {differ += 1}}
	testing.expectf(t, differ * 1000 <= len(moved), "%d of %d values differ from the maps drawn whole", differ, len(moved))
	// A post that moves a little draws again the pages of each cascade its
	// boxes cover, no more than four, and gives what maps drawn whole give;
	// the frame after maps drawn whole draws their cache first.
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	testing.expect(t, scene_move(r, {5}, {trs({f32(5 % 3) * 2.3 - 2.25, 0.8, f32(5 / 3) * 2.1 - 3}, {0.3, 1.6, 0.3})}))
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	levels := 0
	for h in r.main.targets.shadow_raster.held[:SHADOW_SUN_LEVELS] {if h.m.rect.z != 0 {levels += 1}}
	drawn, _, _ := shadow_counts(r)
	testing.expectf(t, drawn > 0 && int(drawn) <= 4 * levels, "a post that moved drew again %d pages of %d levels", drawn, levels)
	paged := read(t, &f)
	defer delete(paged)
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	again := read(t, &f)
	defer delete(again)
	differ = 0
	for v, k in paged {if k < len(again) && abs(int(v) - int(again[k])) > 2 {differ += 1}}
	testing.expectf(t, len(paged) == len(again) && differ * 1000 <= len(paged), "%d of %d values differ from the maps drawn whole after a page", differ, len(paged))
	// The frame after maps drawn whole draws the cache of every page read.
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	whole_drawn, _, _ := shadow_counts(r)
	// Another post lifted a little above the top of the scene: the levels keep how
	// far they reach towards the sun, and draw again only where its boxes are.
	testing.expect(t, scene_move(r, {7}, {trs({f32(7 % 3) * 2.3 - 2.3, 1.7, f32(7 / 3) * 2.1 - 3}, {0.3, 1.6, 0.3})}))
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	drawn, _, _ = shadow_counts(r)
	testing.expectf(t, drawn > 0 && drawn < whole_drawn, "a post lifted above the scene drew %d pages, the maps drawn whole %d", drawn, whole_drawn)
	lifted := read(t, &f)
	defer delete(lifted)
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	fresh := read(t, &f)
	defer delete(fresh)
	differ = 0
	for v, k in lifted {if k < len(fresh) && abs(int(v) - int(fresh[k])) > 2 {differ += 1}}
	testing.expectf(t, len(lifted) == len(fresh) && differ * 1000 <= len(lifted), "%d of %d values differ from the maps drawn whole after a lift", differ, len(lifted))
	expect_clean(t, f.device)
}

// The maps draw only the pages points read: the eye turns to a place no
// point read before, and in the frame it first sees it its posts shade the
// ground there as maps drawn whole do, while the pages nothing reads were
// never drawn.
@(test)
render_a_page_first_read_is_drawn_in_its_frame :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances: [10]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {120, 0.2, 120}), tint = {0.8, 0.8, 0.8}}
	for k in 1 ..< len(instances) {
		instances[k] = {object_id = u64(k + 1), mesh = f.cube, transform = trs({30 + f32(k % 3) * 2.3, 0.8, f32(k / 3) * 2.1 - 3}, {0.3, 1.6, 0.3}), tint = {0.5, 0.5, 0.5}}
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
	away := Camera{position = {-30, 5, 7}, forward = {0, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = away}), r.error)}
	read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
		rhi.device_wait_idle(f.device)
		pixels, _, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		return pixels
	}
	posts := away
	posts.position.x = 32
	testing.expect(t, renderer_frame(r, {camera = posts}), r.error)
	_, composed, left := shadow_counts(r)
	testing.expectf(t, composed > 0 && left == 0, "the pages first read are drawn: %d, %d left out", composed, left)
	seen := read(t, &f)
	defer delete(seen)
	w := int(r.targets.output_width)
	shaded, lit := pixel(seen, w, project(r, posts, {31.9, 0.001, -3.3}))[0], pixel(seen, w, project(r, posts, {36, 0.001, 3}))[0]
	testing.expectf(t, lit > 40 && shaded < 0.5 * lit, "a post shades the ground first seen: %f against %f", shaded, lit)
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = posts}), r.error)
	whole := read(t, &f)
	defer delete(whole)
	if len(seen) != len(whole) || len(seen) == 0 {return}
	differ := 0
	for v, k in seen {if abs(int(v) - int(whole[k])) > 2 {differ += 1}}
	testing.expectf(t, differ * 1000 <= len(seen), "%d of %d values differ from the maps drawn whole", differ, len(seen))
	// The frame after maps drawn whole draws their cache, and a still frame
	// after it draws nothing again.
	testing.expect(t, renderer_frame(r, {camera = posts}), r.error)
	testing.expect(t, renderer_frame(r, {camera = posts}), r.error)
	drawn, _, _ := shadow_counts(r)
	testing.expectf(t, drawn == 0, "a still frame drew %d pages again", drawn)
	// Still frames mark no page and give none again.
	runs := shadow_page_runs(r)
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = posts}), r.error)}
	testing.expectf(t, r.stats.shadow_marked == 0 && shadow_page_runs(r) == runs, "still frames marked %d views and gave the pages %d times", r.stats.shadow_marked, shadow_page_runs(r) - runs)
	// A pool smaller than what the points ask for leaves out the finest pages,
	// the same ones each time the pages are given anew; their points read the
	// coarser pages drawn, or trace, and a post still shades the ground.
	b := &r.main.targets.shadow_raster
	b.pool = 12
	owners: [2][abi.SHADOW_POOL_PAGES]u32
	for &owner, k in owners {
		b.forget = true
		testing.expect(t, renderer_frame(r, {camera = posts}), r.error)
		_, _, left = shadow_counts(r)
		testing.expectf(t, left > 0, "run %d: a small pool leaves pages out: %d", k, left)
		testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_OWNER) * 4, owner[:]))
	}
	testing.expect(t, owners[0] == owners[1], "a small pool gives the same pages each time")
	small := read(t, &f)
	defer delete(small)
	testing.expect(t, renderer_frame(r, {camera = posts}), r.error)
	again := read(t, &f)
	defer delete(again)
	testing.expect(t, slice.equal(small, again), "a small pool gives the same image two frames running")
	shaded, lit = pixel(small, w, project(r, posts, {31.9, 0.001, -3.3}))[0], pixel(small, w, project(r, posts, {36, 0.001, 3}))[0]
	testing.expectf(t, lit > 40 && shaded < 0.5 * lit, "with a small pool a post shades the ground: %f against %f", shaded, lit)
	b.pool = 0
	expect_clean(t, f.device)
}

// A pool smaller than what two ways of looking ask for, with the jitter of
// the view on: a page the points of one frame miss and those of the next read
// keeps its place, so looking back and forth draws no page again; and once
// the eye stays for a cycle of the jitter, the pool holds only what its
// points read.
@(test)
render_a_full_pool_keeps_the_pages_of_a_jitter_cycle :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances: [10]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {120, 0.2, 120}), tint = {0.8, 0.8, 0.8}}
	for k in 1 ..< len(instances) {
		instances[k] = {object_id = u64(k + 1), mesh = f.cube, transform = trs({f32(k % 3) * 2.3 - 2.3, 0.8, f32(k / 3) * 2.1 - 3}, {0.3, 1.6, 0.3}), tint = {0.5, 0.5, 0.5}}
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
	views := [2]Camera {
		{position = {0, 5, 7}, forward = {-4, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE},
		{position = {0, 5, 7}, forward = {4, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE},
	}
	testing.expect(t, renderer_frame(r, {camera = views[0]}), r.error)
	b := &r.main.targets.shadow_raster
	levels := 0
	for h in b.held[:SHADOW_SUN_LEVELS] {if h.m.rect.z != 0 {levels += 1}}
	// The safety net of every level, and a few of the pages the points read.
	pool := 4 * levels + 8
	b.pool, b.forget = u32(pool), true
	for k in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = views[k % 2]}), r.error)}
	_, _, left := shadow_counts(r)
	testing.expectf(t, left > 0, "the pool of %d pages leaves pages out: %d", pool, left)
	again := u32(0)
	for k in 0 ..< 6 {
		testing.expect(t, renderer_frame(r, {camera = views[k % 2]}), r.error)
		drawn, _, _ := shadow_counts(r)
		again += drawn
	}
	testing.expectf(t, again == 0, "looking back and forth drew %d pages again", again)
	for _ in 0 ..< 3 * TAA_JITTER_PHASES {testing.expect(t, renderer_frame(r, {camera = views[0]}), r.error)}
	rhi.device_wait_idle(f.device)
	owners, ages: [abi.SHADOW_POOL_PAGES]u32
	testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_OWNER) * 4, owners[:pool]))
	testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_AGE) * 4, ages[:pool]))
	stale := 0
	for age, k in ages[:pool] {if owners[k] == 0 || age != ages[0] {stale += 1}}
	testing.expectf(t, stale == 0, "after the eye stayed %d pages of the pool are not those its points read", stale)
	expect_clean(t, f.device)
}

// The GPU time the rounds of the maps took in the frame frame_timings last
// gave back, milliseconds, as the bound reads it (shadow_bound_update).
@(private = "file")
shadow_maps_ms :: proc(r: ^Renderer) -> (ms: f32, frame: u64) {
	timings, at, measured := rhi.frame_timings(r.device)
	if !measured {return}
	for t in timings {if strings.has_prefix(t.name, "shadow ") && t.name != SHADOW_PAGES_TIMING {ms += t.ms}}
	return ms, at
}

// Casters as the reference of the pages takes them: three corners in the
// world a triangle, and the grid the vertices of their mesh lie on, metres.
@(private = "file")
Page_Casters :: struct {
	triangles: [dynamic]Vec3,
	step:      f32,
}

// The pages of the levels of the sun the atlas of the main view holds,
// against the triangles of the casters: a texel whose center a triangle
// covers holds the nearest such triangle along the light, and one whose
// center none covers holds nothing. Where the edge of a triangle nearer than
// those that cover a center passes within a twentieth of a texel of it, or
// within twice the grid of its vertices, or a triangle lies there at the near
// or the far plane of the map, a device may place it either side, and the
// texel is left out; so are the levels whose texel is wider than the smallest
// caster (smallest, metres), which the maps leave out. Returns the texels
// compared and those that differ.
@(private = "file")
shadow_pages_against :: proc(r: ^Renderer, casters: []Page_Casters, smallest: f32) -> (compared, differ: int) {
	ALONG :: f32(2e-3) // metres along the light a texel may lie off the triangle
	PAGE :: int(SHADOW_PAGE)
	ROW :: int(SHADOW_POOL) / PAGE
	b := &r.main.targets.shadow_raster
	rhi.device_wait_idle(r.device)
	table := make([]u32, abi.SHADOW_SLOT_ENTRIES * SHADOW_SLOTS)
	atlas := make([]f32, SHADOW_POOL * SHADOW_POOL)
	// Of each texel of the atlas, the nearest along the light a triangle that
	// covers its center lies, and a triangle that may cover it.
	sure := make([]f32, len(atlas))
	maybe := make([]f32, len(atlas))
	defer {delete(table);delete(atlas);delete(sure);delete(maybe)}
	if !rhi.texture_read(r.device, b.table, mem.slice_to_bytes(table)) || !rhi.texture_read(r.device, b.atlas, mem.slice_to_bytes(atlas)) {return 0, -1}
	slice.fill(sure, max(f32))
	slice.fill(maybe, max(f32))
	for level in 0 ..< SHADOW_SUN_LEVELS {
		m := b.held[level].m
		texel := (m.span.z - m.span.x) / f32(max(m.rect.z, 1))
		if m.rect.z == 0 || texel > smallest {continue}
		side := int(m.rect.z)
		// The page of the pool of each page of the map drawn; -1: none.
		pages: [SHADOW_MAP_PAGES * SHADOW_MAP_PAGES]int
		slice.fill(pages[:], -1)
		n, ox, oy := u32(SHADOW_MAP_PAGES), m.rect.y & 0xFF, (m.rect.y >> 8) & 0xFF
		for at in 0 ..< n * n {
			e := table[u32(level) * abi.SHADOW_SLOT_ENTRIES + abi.SHADOW_FINEST_ENTRY + at]
			if e & abi.SHADOW_PAGE_COMPOSED == 0 || e & 0xFFFF == 0 || (e >> abi.SHADOW_ENTRY_COARSER) & 0xF != 0 {continue}
			x, y := (at % n + n - ox % n) % n, (at / n + n - oy % n) % n
			pages[y * n + x] = int(e & 0xFFFF) - 1
		}
		for caster in casters {
			margin := max(0.05, 2 * caster.step / texel)
			for k := 0; k + 2 < len(caster.triangles); k += 3 {
				// The corners in texels of the map, rows down, and along the light.
				p: [3]Vec3
				for j in 0 ..< 3 {
					v := caster.triangles[k + j] - m.origin
					l := Vec3{linalg.dot(v, m.right), linalg.dot(v, m.up), linalg.dot(v, m.forward)}
					p[j] = {(l.x - m.span.x) / texel, (m.span.w - l.y) / texel, l.z}
				}
				e1, e2 := p[1].xy - p[0].xy, p[2].xy - p[0].xy
				area := e1.x * e2.y - e1.y * e2.x
				if abs(area) < 1e-12 {continue}
				lo := linalg.min(p[0].xy, linalg.min(p[1].xy, p[2].xy)) - margin
				hi := linalg.max(p[0].xy, linalg.max(p[1].xy, p[2].xy)) + margin
				x0, y0 := max(int(math.ceil(lo.x - 0.5)), 0), max(int(math.ceil(lo.y - 0.5)), 0)
				x1, y1 := min(int(math.floor(hi.x - 0.5)), side - 1), min(int(math.floor(hi.y - 0.5)), side - 1)
				if x1 < x0 || y1 < y0 {continue}
				// Each edge as a line whose distance, in texels, is positive inside.
				edges: [3]Vec3
				for j in 0 ..< 3 {
					a, d := p[j].xy, p[(j + 1) % 3].xy - p[j].xy
					normal := Vec2{-d.y, d.x} * math.sign(area) / linalg.length(d)
					edges[j] = {normal.x, normal.y, -linalg.dot(normal, a)}
				}
				for py in y0 / PAGE ..= y1 / PAGE {
					for px in x0 / PAGE ..= x1 / PAGE {
						pool := pages[py * SHADOW_MAP_PAGES + px]
						if pool < 0 {continue}
						cx, cy := pool % ROW * PAGE - px * PAGE, pool / ROW * PAGE - py * PAGE
						for ty in max(y0, py * PAGE) ..= min(y1, py * PAGE + PAGE - 1) {
							for tx in max(x0, px * PAGE) ..= min(x1, px * PAGE + PAGE - 1) {
								c := Vec2{f32(tx) + 0.5, f32(ty) + 0.5}
								inside := max(f32)
								for e in edges {inside = min(inside, e.x * c.x + e.y * c.y + e.z)}
								if inside < -margin {continue}
								q := c - p[0].xy
								u, v := (q.x * e2.y - q.y * e2.x) / area, (e1.x * q.y - e1.y * q.x) / area
								z := p[0].z + u * (p[1].z - p[0].z) + v * (p[2].z - p[0].z)
								// The map holds what lies between its near and far planes alone.
								if z < m.near - ALONG || z > m.far + ALONG {continue}
								at := (cy + ty) * int(SHADOW_POOL) + cx + tx
								if inside > margin && z >= m.near + ALONG && z <= m.far - ALONG {sure[at] = min(sure[at], z)}
								maybe[at] = min(maybe[at], z)
							}
						}
					}
				}
			}
		}
		for pool in pages {
			if pool < 0 {continue}
			for j in 0 ..< PAGE {
				for i in 0 ..< PAGE {
					at := (pool / ROW * PAGE + j) * int(SHADOW_POOL) + pool % ROW * PAGE + i
					if maybe[at] < sure[at] - ALONG {continue}
					compared += 1
					if sure[at] == max(f32) {
						if atlas[at] != 0 {differ += 1}
					} else if abs(m.far - atlas[at] * (m.far - m.near) - sure[at]) > ALONG {differ += 1}
				}
			}
		}
	}
	return
}

// Masked cards stacked over the same texels of a map cost the raster what
// the area of their triangles over those texels costs, which neither their
// count nor their boxes say: cards of one layer that each cover pages
// around, cards of many layers inside the box of one cluster, which a tree
// is, and the two together. Under the bound of the renderer each frame's
// rounds take within the time they may, the rest comes in the frames after,
// and the picture ends that of a bound that holds all of them. Of dense
// small triangles the rounds raster only the few that cover a texel center
// of their page, and the pages hold what every triangle gives at those
// centers, none else.
@(test)
render_a_round_of_stacked_masked_cards_keeps_within_its_time :: proc(t: ^testing.T) {
	// The side of a card, metres, the layers of its one cluster, how many; of
	// specks, the side of each of the layers, scattered over the card, and
	// how far apart the specks are laid out in rows (0: over each other).
	Cards :: struct {size: f32, layers, count: int, speck, apart: f32}
	cases := [?]struct {
		name:      string,
		cards:     [2]Cards,
		frames:    u64,  // the cards cost more than this many frames of the most the bound draws
		rastered:  f64,  // the most share of the triangles listed into pages the rounds raster; 0: any
		reference: bool, // the pages are compared with what the triangles give at each texel
	}{
		{"cards over the pages around", {{4, 1, 24000, 0, 0.04}, {}}, 4, 0, false},
		{"layers in the box of a cluster", {{1, 128, 800, 0, 0}, {}}, 4, 0, false},
		{"both", {{4, 1, 12000, 0, 0}, {1, 128, 400, 0, 0}}, 4, 0, false},
		// Vertex-bound: many clusters of small triangles, each over several pages,
		// laid out apart so that what a ray of the sun meets stays small. Each
		// vertex placed once and few triangles drawn, the bound grows with the
		// room the rounds leave: the specks take a few frames of it.
		{"specks over the pages around", {{2, 64, 9000, 0.01, 0.1}, {}}, 2, 0.25, true},
	}
	for c in cases {
		f: Cube_Fixture
		settings := test_settings()
		settings.gi_enabled = false
		settings.taa = false
		if !cube_fixture_init(t, &f, 512, 512, settings) {return}
		r := f.renderer
		masked := DEFAULT_MATERIAL
		masked.alpha_mode = .Mask
		testing.expect(t, materials_set(r, {masked}))
		instances := make([dynamic]Instance_Desc)
		append(&instances, Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {40, 0.2, 40}), tint = {0.8, 0.8, 0.8}})
		// What the reference of the pages draws: the floor and the cards.
		casters: [3]Page_Casters
		smallest := max(f32)
		if c.reference {
			vertices, indices := cube_mesh()
			for index in indices {append(&casters[0].triangles, (instances[0].transform * Vec4{vertices[index].position.x, vertices[index].position.y, vertices[index].position.z, 1}).xyz)}
			casters[0].step = r.scene.meshes[f.cube].position_step * 40
		}
		for kind, n in c.cards {
			if kind.count == 0 {continue}
			vertices := make([]Mesh_Vertex, 4 * kind.layers)
			indices := make([]u32, 6 * kind.layers)
			for l in 0 ..< kind.layers {
				side, at := kind.size, Vec2{}
				if kind.speck > 0 {
					// Spread over the card by the golden ratio.
					side = kind.speck
					at = {(math.mod(f32(l) * 0.618034, 1) - 0.5) * kind.size, (math.mod(f32(l) * 0.381966 * 1.7, 1) - 0.5) * kind.size}
				}
				for i in 0 ..< 4 {vertices[4 * l + i] = {position = {at.x + (f32(i & 1) - 0.5) * side, f32(l) * 1e-4, at.y + (f32(i >> 1) - 0.5) * side}, normal = {0, 1, 0}, uv = {f32(i & 1), f32(i >> 1)}, color = 1, tangent = {1, 0, 0, 1}}}
				for corner, j in ([6]u32{0, 2, 1, 1, 2, 3}) {indices[6 * l + j] = u32(4 * l) + corner}
			}
			mesh, added := mesh_add(r, vertices, indices)
			testing.expect(t, added)
			low, high := Vec3(max(f32)), Vec3(min(f32))
			for v in vertices {low, high = linalg.min(low, v.position), linalg.max(high, v.position)}
			smallest = min(smallest, linalg.length(high - low))
			if c.reference && added {casters[1 + n].step = r.scene.meshes[mesh].position_step}
			for k in 0 ..< kind.count {
				// Turned a little each, so that none lies in another's plane.
				at := trs({f32(k % 7) * 0.01 + f32(k % 80) * kind.apart - 20 * kind.apart, 0.5 + f32(k) * 1e-5, f32(k % 5) * 0.01 + f32(k / 80) * kind.apart - 20 * kind.apart}, {1, 1, 1})
				append(&instances, Instance_Desc{object_id = u64(len(instances) + 1), mesh = mesh, transform = at, material = 1, tint = {0.5, 0.5, 0.5}})
				if c.reference {
					for index in indices {append(&casters[1 + n].triangles, (at * Vec4{vertices[index].position.x, vertices[index].position.y, vertices[index].position.z, 1}).xyz)}
				}
			}
			delete(vertices)
			delete(indices)
		}
		defer for caster in casters {delete(caster.triangles)}
		sun := Sun_Desc{direction = {0.1, 1, 0.05}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
		testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
		delete(instances)
		camera := Camera{position = {2.5, 4, 2.5}, forward = {-0.4, -1, -0.4}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
			rhi.device_wait_idle(f.device)
			pixels, _, _, ok := golden_capture(f.renderer)
			testing.expect(t, ok, f.renderer.error)
			return pixels
		}
		b := &r.main.targets.shadow_raster
		// Until the pages are no longer given, the most the rounds of a frame took.
		// Of the frames from the first, the first included, what comes back,
		// and the triangles the rounds listed into pages and rastered.
		settle :: proc(t: ^testing.T, r: ^Renderer, camera: Camera) -> (frames: int, most: f32, units: u32, total: u64, clusters: u32, frame: f32, listed, rastered: u64) {
			runs, still := u32(0), 0
			first := rhi.frame_number(r.device)
			for frames < 600 && still < 8 {
				testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
				frames += 1
				ms, at := shadow_maps_ms(r)
				if at < first {continue}
				most = max(most, ms)
				units = max(units, r.stats.shadow.units)
				total += u64(r.stats.shadow.units)
				clusters = max(clusters, r.stats.shadow.clusters + r.stats.shadow.clusters_masked)
				frame = max(frame, r.stats.gpu_ms)
				listed += u64(r.stats.shadow.triangles)
				rastered += u64(r.stats.shadow.raster_triangles)
				now := shadow_page_runs(r)
				still = still + 1 if now == runs else 0
				runs = now
			}
			return
		}
		b.budget = abi.SHADOW_COST_UNITS
		whole_frames, whole_ms, whole_units, whole_total, clusters_most, whole_frame, listed, rastered := settle(t, r, camera)
		whole := read(t, &f)
		log.infof("%s: the rounds listed %d triangles into pages and rastered %d", c.name, listed, rastered)
		testing.expectf(t, rastered > 0 && (c.rastered == 0 || f64(rastered) <= c.rastered * f64(listed)), "%s: the rounds rastered %d of the %d triangles they listed into pages", c.name, rastered, listed)
		if c.reference {
			compared, differ := shadow_pages_against(r, casters[:], smallest)
			log.infof("%s: %d texels of the pages compared with what the triangles give there, %d differ", c.name, compared, differ)
			testing.expectf(t, compared > 0 && differ == 0, "%s: %d of %d texels of the pages differ from what the triangles give there", c.name, differ, compared)
		}
		rhi.device_wait_idle(f.device)
		destroy_shadow_maps(r, &r.main.targets)
		b.budget = 0
		r.shadow_bound = {}
		frames, most, units, total, _, frame, _, _ := settle(t, r, camera)
		settled := read(t, &f)
		log.infof("%s: under a bound that holds all %d frames, %.2f ms, %d units a frame at most, %d in all; under that of the renderer %d frames, %.2f ms, %d units a frame at most, %d in all", c.name, whole_frames, whole_ms, whole_units, whole_total, frames, most, units, total)
		log.infof("%s: %d clusters drawn into pages a frame at most; the GPU frame took %.2f ms at most, %.2f under the bound", c.name, clusters_most, whole_frame, frame)
		// What no fixture of the table passes: the frame stays far from the watchdog.
		testing.expectf(t, max(whole_frame, frame) < 100, "%s: a frame took %.2f ms", c.name, max(whole_frame, frame))
		testing.expectf(t, most <= 3 * SHADOW_MAPS_MOST_MS && units <= SHADOW_FRAME_UNITS_MOST + PAGE_UNITS, "%s: under the bound the rounds of a frame took %.2f ms and %d units", c.name, most, units)
		testing.expectf(t, frames < 600 && total > c.frames * u64(units), "%s: the cards cost %d units in %d frames, no more than %d frames of the bound", c.name, total, frames, c.frames)
		differ := 0
		for v, k in settled {if k < len(whole) && abs(int(v) - int(whole[k])) > 2 {differ += 1}}
		testing.expectf(t, len(settled) == len(whole) && differ * 300 <= len(settled), "%s: %d of %d values differ from the cards under a bound that holds all", c.name, differ, len(settled))
		delete(whole)
		delete(settled)
		expect_clean(t, f.device)
		fixture_destroy(&f)
	}
}

// Many batches over a wide ground, most of them outside the maps of a few
// lights, and enough lights to list many slots: a light that moves resets its
// slots, and a turn of the view changes the lights chosen. Under a small
// bound each cull by instance of every frame keeps within it, the slots past
// it waiting, and the pages complete over the frames after into the picture
// of a bound that holds every slot at once.
@(test)
render_the_culls_of_the_maps_keep_within_the_bound :: proc(t: ^testing.T) {
	BOUND :: u32(1 << 16)
	CELLS :: 20 // a side of the square of batches, each 100 instances over 10 m
	cases := [?]struct {
		name:  string,
		turn:  bool, // the view turns to other lights; else one light moves
	}{{"a light that moves resets its slots", false}, {"a turn changes the lights chosen", true}}
	for c in cases {
		f: Cube_Fixture
		settings := test_settings()
		settings.gi_enabled = false
		settings.taa = false
		if !cube_fixture_init(t, &f, 192, 128, settings) {return}
		r := f.renderer
		floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {CELLS * 10, 0.2, CELLS * 10}), tint = {0.8, 0.8, 0.8}}
		// Two groups of six lights over the ground, apart.
		lights: [12]Light_Desc
		for &light, k in lights {
			at := Vec3{f32(k % 3) * 4 - 4, 2.5, f32(k / 3 % 2) * 4 - 2} + Vec3{-40 if k < 6 else 40, 0, 0}
			light = {position = at, color = {1, 1, 1}, intensity = 10 * math.PI, range = 6, indirect = 1, scattering = 1}
		}
		sun := Sun_Desc{direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 0.5 * math.PI, enabled = true}
		testing.expect(t, scene_given(r, {floor}, lights[:], sun, {sky = {0, 0, 0}}), r.error)
		batched: [100]Batch_Instance
		for cell in 0 ..< CELLS * CELLS {
			corner := Vec3{f32(cell % CELLS) * 10 - CELLS * 5, 0, f32(cell / CELLS) * 10 - CELLS * 5}
			for &b, k in batched {b = batch_instance(corner + {f32(k % 10) + 0.5, 0.4, f32(k / 10) + 0.5}, 1, {0.3, 0.8, 0.3})}
			_, problem := batch_set(r, 0, r.world_key, {mesh = f.cube, tint = 0.5, flags = {.Casts_Shadow, .Ray_Visible}}, batched[:])
			if !testing.expectf(t, problem == "", "%s", problem) {return}
		}
		look :: proc(x: f32) -> Camera {
			return {position = {x, 14, 6}, forward = {0, -14, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 400, exposure = UNIT_EXPOSURE}
		}
		read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
			rhi.device_wait_idle(f.device)
			pixels, _, _, ok := golden_capture(f.renderer)
			testing.expect(t, ok, f.renderer.error)
			return pixels
		}
		// Until the pages are no longer given: the frames, and the most threads
		// the culls by instance of a frame ran.
		settle :: proc(t: ^testing.T, r: ^Renderer, camera: Camera) -> (frames: int, most: u32) {
			runs, still := u32(0), 0
			for frames < 600 && still < 8 {
				testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
				frames += 1
				most = max(most, r.stats.shadow.cull_threads)
				now := shadow_page_runs(r)
				still = still + 1 if now == runs else 0
				runs = now
			}
			return
		}
		b := &r.main.targets.shadow_raster
		b.budget = BOUND
		camera := look(-40)
		settle(t, r, camera)
		if c.turn {
			camera = look(40)
		} else {
			lights[0].position += {0.5, 0, 0.5}
			testing.expect(t, scene_lights_given(r, lights[:], sun, {sky = {0, 0, 0}}), r.error)
		}
		frames, most := settle(t, r, camera)
		bounded := read(t, &f)
		rhi.device_wait_idle(f.device)
		destroy_shadow_maps(r, &r.main.targets)
		b.budget = abi.SHADOW_COST_UNITS
		r.shadow_bound = {}
		whole_frames, whole_most := settle(t, r, camera)
		whole := read(t, &f)
		slots := 0
		for h in b.held {if h.m.rect.z != 0 {slots += 1}}
		log.infof("%s: under the bound %d threads a frame at most over %d frames; under one that holds all %d over %d frames; every instance in each of the %d slots with a map, four times: %d", c.name, most, frames, whole_most, whole_frames, slots, 4 * (len(r.scene.instances) + int(r.scene.batch.slots)) * slots)
		// The four culls by instance of a frame, each within the bound: no slot here passes it alone.
		testing.expectf(t, most > 0 && most <= 4 * BOUND, "%s: the culls by instance of a frame ran %d threads, past four times %d", c.name, most, BOUND)
		testing.expectf(t, whole_most > 4 * BOUND, "%s: the fixture culls %d threads a frame at most, within the bound", c.name, whole_most)
		testing.expectf(t, frames < 600 && whole_frames < 600, "%s: the pages settle in %d and %d frames", c.name, frames, whole_frames)
		differ := 0
		for v, k in bounded {if k < len(whole) && abs(int(v) - int(whole[k])) > 2 {differ += 1}}
		testing.expectf(t, len(bounded) == len(whole) && differ * 300 <= len(bounded), "%s: %d of %d values differ from the picture under a bound that holds all", c.name, differ, len(bounded))
		delete(bounded)
		delete(whole)
		expect_clean(t, f.device)
		fixture_destroy(&f)
	}
}

// A still view whose pages the maps cannot hold at once: a pool smaller than
// what its points read, and a list of the chunks of the cull with no room in
// the first frame after the maps are made anew. No point reads lit where a
// post shades it: a page the pool leaves out or that waits stands in a
// coarser one drawn with the pages around it, or its points trace, so the
// image is that of a pool and lists that hold everything within what the
// coarser pages tell; and the view settles: the frames after it are alike,
// and no page is given again.
@(test)
render_a_view_the_maps_cannot_hold_shows_no_lit_hole :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances: [65]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {160, 0.2, 160}), tint = {0.8, 0.8, 0.8}}
	for k in 1 ..< len(instances) {
		instances[k] = {object_id = u64(k + 1), mesh = f.cube, transform = trs({f32((k - 1) % 8) * 0.9 + 0.8, 0.8, f32((k - 1) / 8) * 0.9 + 0.8}, {0.2, 1.6, 0.2}), tint = {0.5, 0.5, 0.5}}
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
	camera := Camera{position = {4, 5, 11}, forward = {0, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
		rhi.device_wait_idle(f.device)
		pixels, _, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		return pixels
	}
	b := &r.main.targets.shadow_raster
	for _ in 0 ..< 8 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	whole := read(t, &f)
	defer delete(whole)
	levels := 0
	for h in b.held[:SHADOW_SUN_LEVELS] {if h.m.rect.z != 0 {levels += 1}}
	cases := [?]struct {
		name:   string,
		pool:   u32, // the pages of the pool it gives; 0: all
		chunks: u32, // the chunks the first frame of maps made anew has room for; 0: as they grow
	}{{"a pool smaller than what the points read", u32(4 * levels + 8), 0}, {"a list of chunks without room", 0, 2}}
	for c in cases {
		rhi.device_wait_idle(f.device)
		destroy_shadow_maps(r, &r.main.targets)
		b.pool = c.pool
		if c.chunks != 0 {r.scene.cull_capacity[.Shadow_Chunks] = c.chunks}
		frames, still := 0, 0
		runs := u32(0)
		for frames < 400 && still < 8 {
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
			frames += 1
			now := shadow_page_runs(r)
			still = still + 1 if now == runs else 0
			runs = now
		}
		testing.expectf(t, still >= 8, "%s: the pages were still given after %d frames", c.name, frames)
		before := read(t, &f)
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		after := read(t, &f)
		testing.expectf(t, slice.equal(before, after) && shadow_page_runs(r) == runs, "%s: a settled view changes from a frame to the next (pages given %d times more)", c.name, shadow_page_runs(r) - runs)
		// Lit where the maps of a pool that holds all shade it: brighter by far
		// than a coarser page blurs the border of a shadow.
		holes := 0
		for k := 0; k + 2 < len(after) && k + 2 < len(whole); k += 4 {
			if int(after[k + 1]) > int(whole[k + 1]) + 48 {holes += 1}
		}
		testing.expectf(t, holes * 200 <= len(after) / 4, "%s: %d of %d pixels lit where the post shades them", c.name, holes, len(after) / 4)
		delete(before)
		delete(after)
		b.pool = 0
	}
	expect_clean(t, f.device)
}

// What the table of the pages holds addresses only words of its own region:
// a table made anew holds what the memory of the texture held before it and
// no page until its first entries are written, and an entry past the pool
// names no page, whoever wrote it. Here every texel names a page of the pool
// whose words of what the cache draws again would lie on the arguments of a
// step of the pages, which dispatched over them would not end; a caster comes
// in that frame, so that what changed reads the table.
@(test)
render_a_table_holds_no_page_past_its_pool :: proc(t: ^testing.T) {
	cases := [?]struct {
		anew: bool,
		step: Shadow_Pages_Step,
	}{{true, .Settle}, {false, .Settle}, {false, .Propagate}, {false, .Grant}}
	for c in cases {
		f: Cube_Fixture
		settings := test_settings()
		settings.gi_enabled = false
		if !cube_fixture_init(t, &f, 128, 96, settings) {return}
		r := f.renderer
		instances := [2]Instance_Desc{
			{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {40, 0.2, 40}), tint = {0.8, 0.8, 0.8}},
			{object_id = 2, mesh = f.cube, transform = trs({0, 1, 0}, {0.4, 2, 0.4}), tint = {0.5, 0.5, 0.5}},
		}
		sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
		testing.expect(t, scene_given(r, instances[:1], nil, sun, {sky = {0, 0, 0}}))
		camera := Camera{position = {0, 5, 7}, forward = {0, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(f.device)
		b := &r.main.targets.shadow_raster
		target := abi.SHADOW_WORDS_STEPS + 3 * u32(c.step) + 1
		pool := (target - abi.SHADOW_WORDS_PART) / 4
		entries := make([]u32, abi.SHADOW_SLOT_ENTRIES * SHADOW_SLOTS)
		for &e in entries {e = abi.SHADOW_PAGE_CACHED | abi.SHADOW_PAGE_COMPOSED | (pool + 1)}
		testing.expect(t, rhi.texture_upload(f.device, b.table, mem.slice_to_bytes(entries), u32(abi.SHADOW_SLOT_ENTRIES * 4)))
		delete(entries)
		if c.anew {
			rhi.buffer_destroy(f.device, b.pages)
			b.pages = 0
		}
		testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		rhi.device_wait_idle(f.device)
		steps: [3 * abi.SHADOW_STEPS]u32
		testing.expect(t, rhi.buffer_read_slice(f.device, b.pages, u64(abi.SHADOW_WORDS_STEPS) * 4, steps[:]))
		for step in 1 ..< abi.SHADOW_STEPS {
			testing.expectf(t, steps[3 * step + 1] == 1 && steps[3 * step + 2] == 1, "%v: the step %v is dispatched over %d x %d x %d groups", c, Shadow_Pages_Step(step), steps[3 * step], steps[3 * step + 1], steps[3 * step + 2])
		}
		expect_clean(t, f.device)
		fixture_destroy(&f)
	}
}

// A frame asked for counts what each mesh and each material of the view cost
// it: the instances, clusters and triangles the view drew, the pixels each
// owns and what the maps of the sun drew of it; a mesh out of the view costs
// the view nothing, and the frames after it count nothing again.
@(test)
render_a_frame_asked_for_counts_its_cost_by_mesh_and_material :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled, settings.taa = false, false
	width, height :: 128, 96
	if !cube_fixture_init(t, &f, width, height, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	red := DEFAULT_MATERIAL
	red.base_color = {1, 0, 0}
	testing.expect(t, materials_set(r, {red}), r.error)
	red_vertices, red_indices := cube_mesh(material = 1)
	red_cube, red_added := mesh_add(r, red_vertices[:], red_indices[:])
	vertices, indices := cube_mesh()
	apart, apart_added := mesh_add(r, vertices[:], indices[:])
	if !testing.expect(t, red_added && apart_added, r.error) {return}
	_, refused := renderer_cost(r)
	testing.expect(t, !refused, "a count nobody asked for")
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = 1},
		{object_id = 2, mesh = red_cube, transform = trs({-1.5, 0.5, 0}, 1), tint = 1},
		{object_id = 3, mesh = red_cube, transform = trs({0, 0.5, 0}, 1), tint = 1},
		{object_id = 4, mesh = red_cube, transform = trs({1.5, 0.5, 0}, 1), tint = 1},
		{object_id = 5, mesh = apart, transform = trs({0, 0.5, 60}, 1), tint = 1},
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances, nil, sun, {sky = {0.3, 0.4, 0.6}}))
	camera := Camera{position = {0, 4, 7}, forward = {0, -4, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	// The maps of a still view keep what they drew: the frame counted draws them whole again.
	b := &r.main.targets.shadow_raster
	b.budget, b.forget = 1 << 20, true
	if !testing.expect_value(t, renderer_cost_ask(r), "") {return}
	cost: Cost
	ready := false
	for _ in 0 ..< 8 {
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		if cost, ready = renderer_cost(r); ready {break}
	}
	if !testing.expect(t, ready, "the count of the frame asked for never came") {return}
	testing.expect(t, len(cost.meshes) == len(r.scene.meshes) && len(cost.materials) == len(r.scene.materials))
	floor, cubes, away := cost.meshes[f.cube], cost.meshes[red_cube], cost.meshes[apart]
	testing.expect_value(t, floor.instances, 1)
	testing.expect_value(t, cubes.instances, 3)
	testing.expect_value(t, away, Cost_Row{})
	for row, name in ([2]Cost_Row{floor, cubes}) {
		testing.expectf(t, row.clusters > 0 && row.raster_triangles > 0 && row.triangles >= row.raster_triangles && row.pixels > 0, "mesh %d: %v", name, row)
	}
	testing.expectf(t, cubes.shadow_clusters > 0 && cubes.shadow_triangles > 0 && cubes.shadow_units > 0, "the maps drew nothing of the cubes: %v", cubes)
	// The red cubes alone are of the red material, which counts no instances.
	shown := cost.materials[1]
	testing.expect_value(t, shown, Cost_Row{clusters = cubes.clusters, triangles = cubes.triangles, raster_triangles = cubes.raster_triangles, pixels = cubes.pixels, shadow_clusters = cubes.shadow_clusters, shadow_triangles = cubes.shadow_triangles, shadow_units = cubes.shadow_units, shadow_over = cubes.shadow_over})
	// Every pixel of the target is of one mesh and one material, or of the sky.
	mesh_pixels, material_pixels: u32
	for row in cost.meshes {mesh_pixels += row.pixels}
	for row in cost.materials {material_pixels += row.pixels}
	testing.expectf(t, mesh_pixels == material_pixels && mesh_pixels <= width * height, "pixels of the meshes %d, of the materials %d", mesh_pixels, material_pixels)
	counted := cost.frame
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	again, still := renderer_cost(r)
	testing.expect(t, still && again.frame == counted, "a frame nobody asked about counted")
}

// No round of the maps draws more clusters in a frame than its bound, also in
// the first frame of a still view that asks for many times more, where a
// page alone passes it too; the pages past it wait, the coarsest first, and
// are all drawn within the frames the bound gives, the image then that of the
// maps drawn whole. A bound that grows while the frames have room, never past
// its most, settles in half the frames or fewer.
@(test)
render_a_frame_draws_no_more_than_its_bound_and_the_rest_comes_after :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances: [65]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {160, 0.2, 160}), tint = {0.8, 0.8, 0.8}}
	for k in 1 ..< len(instances) {
		// Within one page of the levels of the sun the view reads, which they pass alone.
		instances[k] = {object_id = u64(k + 1), mesh = f.cube, transform = trs({f32((k - 1) % 8) * 0.9 + 0.8, 0.8, f32((k - 1) / 8) * 0.9 + 0.8}, {0.2, 1.6, 0.2}), tint = {0.5, 0.5, 0.5}}
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
	camera := Camera{position = {4, 5, 11}, forward = {0, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	stats :: proc(r: ^Renderer) -> (s: Shadow_Stats, waiting: u32) {
		rhi.device_wait_idle(r.device)
		read: [1]Shadow_Stats
		count: [1]u32
		if !rhi.buffer_read_slice(r.device, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow)), read[:]) {return {}, max(u32)}
		if !rhi.buffer_read_slice(r.device, r.main.targets.shadow_raster.pages, u64(abi.SHADOW_WORDS_COUNTS + abi.SHADOW_COUNT_WAITING) * 4, count[:]) {return {}, max(u32)}
		return read[0], count[0]
	}
	read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
		rhi.device_wait_idle(f.device)
		pixels, _, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		return pixels
	}
	// Drawn whole in its first frame: what that frame asks for.
	b := &r.main.targets.shadow_raster
	b.budget = 1 << 20
	// A frame that lets go of every page draws them whole into the atlas, and the cache the next.
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	b.forget = true
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	whole_frame, _ := stats(r)
	asked := whole_frame.units
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	whole := read(t, &f)
	defer delete(whole)
	// A bound a 256th of that, less than the posts in one page: held,
	// and growing while the frames have room, up to eight times as much.
	bound := max(asked / 256, 4)
	cases := [?]struct {
		name:  string,
		grows: bool,
	}{{"a held bound", false}, {"a bound that grows", true}}
	took: [len(cases)]int
	for c, n in cases {
		most_bound := 8 * bound if c.grows else bound
		b.budget, b.forget = 0 if c.grows else bound, true
		if c.grows {r.shadow_bound = {least = bound, most = most_bound}}
		frames, most, banded, narrowed := 0, u32(0), false, false
		foreseen: [SHADOW_SLOTS]bool
		for frames < 2048 {
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
			frames += 1
			s, waiting := stats(r)
			bands: [abi.SHADOW_POOL_PAGES]u32
			testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_BAND) * 4, bands[:]))
			for band in bands {banded ||= (band >> abi.SHADOW_BAND_SHIFT) & 0xFF != 0}
			// Past the bound by the units of a cluster at most, which begins within it.
			most = max(most, s.units, s.units_moving)
			testing.expectf(t, s.units <= most_bound + PAGE_UNITS && s.units_moving <= most_bound + PAGE_UNITS, "%s, frame %d: the cache drew %d units and the atlas %d past the bound of %d", c.name, frames, s.units, s.units_moving, most_bound)
			// A page that waits is foreseen once, and the culls go over the slots of
			// the pages granted alone: the frames it waits cost no instance of it.
			args: [9]u32
			work: [3 * (SHADOW_SLOTS + 1)]u32
			has: [SHADOW_SLOTS]u32
			testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_ARGS + abi.SHADOW_ARGS_DISPATCH) * 4, args[:]))
			testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_SLOTS) * 4, work[:]))
			testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_HAS) * 4, has[:]))
			listed := 0
			for h in has {if h != 0 {listed += 1}}
			if frames > 2 && waiting > 0 {
				// The slots the foresight of this frame went over, where it ran.
				foresee := work[2 * (SHADOW_SLOTS + 1):]
				for entry in foresee[1:][:min(foresee[0], SHADOW_SLOTS) if args[6] != 0 else 0] {
					slot := entry & (1 << abi.SHADOW_WORK_SHIFT - 1)
					testing.expectf(t, slot < SHADOW_SLOTS && !foreseen[slot], "%s, frame %d: the cache foresees the pages of slot %d again", c.name, frames, slot)
					if slot < SHADOW_SLOTS {foreseen[slot] = true}
				}
				narrowed ||= args[0] != 0 && int(work[0]) < listed
			}
			if waiting == 0 {break}
		}
		took[n] = frames
		if !c.grows {
			testing.expect(t, narrowed, "the culls of a frame go over the slots of the pages it grants")
			// Each frame draws near its bound but for what its bands and estimates leave.
			given := 4 * (int(asked) + int(bound) - 1) / int(bound) + 4
			testing.expectf(t, asked > 256 * bound - 256 && most > 0 && banded && frames <= given, "%d clusters asked for under a bound of %d took %d frames, the rule gives %d (a page drawn in bands: %v)", asked, bound, frames, given, banded)
		}
		for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		settled := read(t, &f)
		differ := 0
		for v, k in settled {if k < len(whole) && abs(int(v) - int(whole[k])) > 2 {differ += 1}}
		testing.expectf(t, len(settled) == len(whole) && differ * 1000 <= len(settled), "%s: %d of %d values differ from the maps drawn whole", c.name, differ, len(settled))
		delete(settled)
		r.shadow_bound = {}
	}
	testing.expectf(t, took[1] * 2 <= took[0], "a bound that grows with the room of the frames settled in %d frames, a held one in %d", took[1], took[0])
	b.budget = 0
	expect_clean(t, f.device)
}

// Under the bound of a frame, a batch that sways over a still floor composes
// the same pages every frame, those its instances cover: the points there
// read their own pages every frame, never a coarser one in between, and the
// pages of the floor between its instances, under the box of the batch, stay
// as the cache drew them. One batch over two groups composes no more pages
// than a batch for each group.
@(test)
render_a_swaying_batch_keeps_its_pages_under_the_bound :: proc(t: ^testing.T) {
	Sway :: struct {mesh: Mesh_Handle, x: f32}
	write :: proc(s: ^Stage_Pass, user: rawptr) {
		sway := (^Sway)(user)
		r := s.pass.r
		written, rest, count, _, known := deformable_vertices(r, sway.mesh)
		if !known {return}
		vertices, at := rhi.frame_alloc_typed(r.device, Gpu_Posed_Vertex, int(count))
		if vertices == nil {return}
		copy(vertices, ([^]Gpu_Posed_Vertex)(&r.scene.vertices[rest])[:count])
		for &v in vertices {v.position.x += sway.x}
		rhi.cmd_copy_buffer(s.pass.cmd, at.buffer, at.offset, r.scene.vertex_buffer, u64(written) * 4, u64(count) * size_of(Gpu_Posed_Vertex))
	}
	cases := [?]struct {
		name:    string,
		batches: int, // the groups in one batch, or a batch for each
	}{{"one batch", 1}, {"a batch for each group", 2}}
	composed: [len(cases)]u32
	for c, n in cases {
		f: Cube_Fixture
		settings := test_settings()
		settings.gi_enabled = false
		settings.taa = false
		if !cube_fixture_init(t, &f, 192, 128, settings) {return}
		r := f.renderer
		floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {40, 0.2, 40}), tint = {0.8, 0.8, 0.8}}
		sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
		testing.expect(t, scene_given(r, {floor}, nil, sun, {sky = {0, 0, 0}}))
		camera := Camera{position = {0, 9, 0.001}, forward = {0, -9, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		mesh, made := deformable_create(r, f.cube, false, 0.3)
		if !testing.expect(t, made) {fixture_destroy(&f); return}
		// Two groups of posts 10 m apart, the floor between them still.
		groups: [2][4]Batch_Instance
		for &group, g in groups {
			for &instance, k in group {instance = batch_instance({f32(g) * 10 - 5 + f32(k % 2) * 0.8, 0.6, f32(k / 2) * 0.8}, 1, {0.3, 1.2, 0.3})}
		}
		all := [8]Batch_Instance{}
		copy(all[:4], groups[0][:])
		copy(all[4:], groups[1][:])
		desc := Batch_Desc{mesh = mesh, tint = 0.5, flags = {.Casts_Shadow, .Ray_Visible}}
		handles: [2]Batch_Handle
		problem: string
		if c.batches == 1 {
			handles[0], problem = batch_set(r, 0, 0, desc, all[:])
		} else {
			for &h, g in handles {if problem == "" {h, problem = batch_set(r, 0, 0, desc, groups[g][:])}}
		}
		testing.expectf(t, problem == "", "%s: %s", c.name, problem)
		sway := Sway{mesh = mesh}
		b := &r.main.targets.shadow_raster
		// The posts sway to one side and the other, a frame each.
		frame :: proc(t: ^testing.T, r: ^Renderer, cube: Mesh_Handle, sway: ^Sway, camera: Camera) {
			sway.x = -sway.x if sway.x != 0 else 0.2
			low, high, _ := mesh_bounds(r, cube)
			testing.expect(t, deformable_update(r, sway.mesh, low - 0.3, high + 0.3))
			testing.expect(t, frame_pass(r, .Geometry, write, sway))
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		}
		// What the swaying posts take with room to spare.
		b.budget = 1 << 20
		for _ in 0 ..< 8 {frame(t, r, f.cube, &sway, camera)}
		_, pages, _ := shadow_counts(r)
		stats: [1]Shadow_Stats
		testing.expect(t, rhi.buffer_read_slice(r.device, r.stats_buffer, u64(offset_of(Gpu_Cull_Stats, shadow)), stats[:]))
		// A bound with room for them but little more, from the start again.
		bound := 2 * ((32 * pages + stats[0].units_moving) * 4 / 3 + 64)
		b.budget, b.forget = bound, true
		waiting := u32(1)
		for k := 0; k < 64 && waiting != 0; k += 1 {
			frame(t, r, f.cube, &sway, camera)
			count: [1]u32
			testing.expect(t, rhi.buffer_read_slice(r.device, b.pages, u64(abi.SHADOW_WORDS_COUNTS + abi.SHADOW_COUNT_WAITING) * 4, count[:]))
			waiting = count[0]
		}
		testing.expectf(t, waiting == 0, "%s: under a bound of %d the pages still wait", c.name, bound)
		frame(t, r, f.cube, &sway, camera)
		entries := make([]u32, abi.SHADOW_SLOT_ENTRIES * SHADOW_SLOTS)
		before := make([]u32, len(entries))
		testing.expect(t, rhi.texture_read(f.device, b.table, mem.slice_to_bytes(before)))
		for k in 0 ..< 8 {
			frame(t, r, f.cube, &sway, camera)
			drawn, moved, _ := shadow_counts(r)
			composed[n] = max(composed[n], moved)
			testing.expectf(t, drawn == 0 && moved > 0, "%s, frame %d: the cache drew %d pages again and the atlas composed %d", c.name, k, drawn, moved)
			testing.expect(t, rhi.texture_read(f.device, b.table, mem.slice_to_bytes(entries)))
			changed := 0
			for e, i in entries {if e != before[i] {changed += 1}}
			testing.expectf(t, changed == 0, "%s, frame %d: %d entries of the table changed while the posts swayed", c.name, k, changed)
		}
		delete(entries)
		delete(before)
		b.budget = 0
		for h in handles {if h != 0 {batch_remove(r, h)}}
		mesh_remove(r, mesh)
		expect_clean(t, f.device)
		fixture_destroy(&f)
	}
	testing.expectf(t, composed[0] <= composed[1], "one batch over both groups composes %d pages, a batch for each %d", composed[0], composed[1])
}

// The search of the blockers of a point reaches far where something may
// stand far above it: its far taps read a coarser level, so a tall scene asks
// for hardly more pages of the level its points read than a low one, where
// the whole reach of the taps would ask for a ring of pages around them.
@(test)
render_a_wide_search_asks_for_coarser_pages_not_more_of_the_finest :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	settings.sun_radius = 1e-6
	if !cube_fixture_init(t, &f, 128, 96, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A floor seen from just above, and a post 20 m tall far to the side of what is seen.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {80, 0.2, 80}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({30, 10, 30}, {0.2, 20, 0.2}), tint = {0.5, 0.5, 0.5}},
	}
	sun := Sun_Desc{direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances, nil, sun, {sky = {0, 0, 0}}))
	camera := Camera{position = {10.3, 0.36, 7.7}, forward = {0, -1, -0.001}, up = {0, 0, -1}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	// The pages of each level of the sun the points of the last frame marked.
	marked :: proc(t: ^testing.T, r: ^Renderer) -> (counts: [SHADOW_SUN_LEVELS]int) {
		rhi.device_wait_idle(r.device)
		words: [SHADOW_SUN_LEVELS * abi.SHADOW_MASK_WORDS]u32
		testing.expect(t, rhi.buffer_read_slice(r.device, r.main.targets.shadow_raster.pages, u64(abi.SHADOW_WORDS_NEEDED) * 4, words[:]))
		for word, k in words {
			for bit in 0 ..< u32(32) {if word & (1 << bit) != 0 {counts[k / abi.SHADOW_MASK_WORDS] += 1}}
		}
		return
	}
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	low := marked(t, r)
	own := 0
	for count, level in low {if count > low[own] {own = level}}
	settings.sun_radius = 0.05
	testing.expect(t, renderer_apply_settings(r, settings))
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	tall := marked(t, r)
	coarser := 0
	for count in tall[own + 1:] {coarser += count}
	before := 0
	for count in low[own + 1:] {before += count}
	testing.expectf(t, low[own] > 0 && tall[own] < 2 * low[own] + 3, "level %d: %d pages marked under a narrow sun, %d under a wide one", own, low[own], tall[own])
	testing.expectf(t, coarser > before, "the wide search marked %d pages of coarser levels, the narrow one %d", coarser, before)
	expect_clean(t, f.device)
}

// A sun low over open ground: a line on the ground away from the eye crosses
// several levels of the sun, which meet where the texel of one is twice that
// of the next, and shows no line where they meet, lit beside the long shadow
// of a pole and dark in it.
@(test)
render_a_low_sun_shows_no_line_between_levels :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 256, 192, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, -40}, {120, 0.2, 120}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({-1.5, 1, -2}, {0.6, 2, 0.6}), tint = {0.5, 0.5, 0.5}},
	}
	// Behind the eye, 14 degrees up: the shadow of the pole runs 8 m away from it.
	sun := Sun_Desc{direction = linalg.normalize(Vec3{0, 0.25, 1}), color = {1, 1, 1}, illuminance = 4 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances, nil, sun, {sky = {0, 0, 0}}))
	camera := Camera{position = {0, 1.6, 2}, forward = {0, -0.12, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 200, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	if !testing.expect(t, ok, r.error) {return}
	defer delete(pixels)
	lit: [40]f32
	for &v, k in lit {v = pixel(pixels, w, project(r, camera, {1.2, 0.001, -0.5 - 0.75 * f32(k)}))[0]}
	sorted := lit
	slice.sort(sorted[:])
	middle := sorted[len(sorted) / 2]
	testing.expectf(t, middle > 30, "the ground is lit: %f", middle)
	for v, k in lit {testing.expectf(t, abs(v - middle) <= 0.12 * middle, "the ground %f m away has %f against %f along the line", 0.5 + 0.75 * f32(k), v, middle)}
	for k in 0 ..< 7 {
		shaded := pixel(pixels, w, project(r, camera, {-1.5, 0.001, -3.5 - 0.7 * f32(k)}))[0]
		testing.expectf(t, shaded < 0.5 * middle, "the shadow of the pole %f m away has %f against %f", 3.5 + 0.7 * f32(k), shaded, middle)
	}
	expect_clean(t, f.device)
}

// A jump of the origin keeps no map of the shadows measured from the old one:
// the far cascades of a wide scene, which the eye would not move out of, give
// what maps drawn whole give.
@(test)
render_an_origin_jump_gives_what_whole_maps_give :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances: [7]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {8000, 0.2, 8000}), tint = {0.8, 0.8, 0.8}}
	for k in 1 ..< len(instances) {
		instances[k] = {object_id = u64(k + 1), mesh = f.cube, transform = trs({f32(k % 3) * 300 - 300, 150, -500 - f32(k / 3) * 500}, {40, 300, 40}), tint = {0.5, 0.5, 0.5}}
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	testing.expect(t, scene_given(r, instances[:], nil, sun, {sky = {0, 0, 0}}))
	camera := Camera{position = {0, 40, 200}, forward = {0, -0.08, -1}, up = {0, 1, 0}, fov_y = 60, near = 0.1, far = 5000, exposure = UNIT_EXPOSURE}
	read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
		rhi.device_wait_idle(f.device)
		pixels, _, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		return pixels
	}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	renderer_origin_set(r, {ORIGIN_STEP, 0, 0})
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	jumped := read(t, &f)
	defer delete(jumped)
	r.main.targets.shadow_raster.forget = true
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	whole := read(t, &f)
	defer delete(whole)
	if len(jumped) != len(whole) || len(jumped) == 0 {return}
	differ := 0
	for v, k in jumped {if abs(int(v) - int(whole[k])) > 2 {differ += 1}}
	testing.expectf(t, differ * 1000 <= len(jumped), "%d of %d values differ from the maps drawn whole", differ, len(jumped))
	expect_clean(t, f.device)
}

// A turning sun draws again, in the frame it turns, the pages its levels
// hold that the points read, whole into the atlas alone, and the cache the
// next still frame: each frame gives what maps drawn whole give.
@(test)
render_a_turning_sun_gives_what_whole_maps_give :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances: [10]Instance_Desc
	instances[0] = {object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {40, 0.2, 40}), tint = {0.8, 0.8, 0.8}}
	for k in 1 ..< len(instances) {
		instances[k] = {object_id = u64(k + 1), mesh = f.cube, transform = trs({f32(k % 3) * 2.3 - 2.3, 0.8, f32(k / 3) * 2.1 - 3}, {0.3, 1.6, 0.3}), tint = {0.5, 0.5, 0.5}}
	}
	sun := Sun_Desc{direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true}
	environment := Environment{sky = {0, 0, 0}}
	testing.expect(t, scene_given(r, instances[:], nil, sun, environment))
	camera := Camera{position = {0, 5, 7}, forward = {0, -5, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	read :: proc(t: ^testing.T, f: ^Cube_Fixture) -> []u8 {
		rhi.device_wait_idle(f.device)
		pixels, _, _, ok := golden_capture(f.renderer)
		testing.expect(t, ok, f.renderer.error)
		return pixels
	}
	for k in 0 ..< 4 {
		still := k == 3
		if !still {
			sun.direction.x = 0.4 + 0.1 * f32(k + 1)
			scene_set_environment(r, sun, environment)
		}
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		drawn, composed, _ := shadow_counts(r)
		if still {
			testing.expectf(t, drawn > 0, "the still frame after the turns draws the cache: %d pages", drawn)
		} else {
			testing.expectf(t, drawn == 0 && composed > 0, "turn %d draws the atlas alone: %d pages of the cache, %d of the atlas", k, drawn, composed)
		}
		turned := read(t, &f)
		defer delete(turned)
		r.main.targets.shadow_raster.forget = true
		testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
		whole := read(t, &f)
		defer delete(whole)
		if len(turned) != len(whole) || len(turned) == 0 {return}
		differ := 0
		for v, i in turned {if abs(int(v) - int(whole[i])) > 2 {differ += 1}}
		testing.expectf(t, differ * 1000 <= len(turned), "turn %d: %d of %d values differ from the maps drawn whole", k, differ, len(turned))
	}
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
	scene_given(r, instances, nil, {}, {sky = {0, 0, 0}})
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
    scene_given(r,instances,nil,{}, {sky={0.5,0.5,0.5}})
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

// What the probes trace and light in the frames after the one given, at most
// in one of them: the counts come back two frames late.
@(private = "file")
probe_work_after :: proc(t: ^testing.T, r: ^Renderer, camera: Camera, frames := 4) -> (probes, traced, lit: u32) {
	for _ in 0 ..< frames {
		testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)
		rhi.device_wait_idle(r.device)
		probes, traced, lit = max(probes, r.stats.probes_traced), max(traced, r.stats.probe_rays_traced), max(lit, r.stats.probe_hits_lit)
	}
	return
}

// No probe is traced while nothing changes, but by turns those whose rays
// meet a program that reads the time.
@(test)
render_probes_trace_and_light_only_what_a_change_crosses :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.taa = false
	if !cube_fixture_init(t, &f, 96, 64, settings, programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A floor and a wall, a lamp at one end of them and a box that glows green
	// away from both; none of their faces on a plane of the probes.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.5, 0}, {14, 0.2, 14}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 1.1, -3.5}, {14, 3, 0.2}), tint = {0.8, 0.8, 0.8}, material = 1},
		{object_id = 3, mesh = f.cube, transform = trs({5.65, 0.35, 4}, {1.5, 1.5, 1.5}), tint = {1, 1, 1}, emission = {0, 4, 0}},
	}
	lamp := Light_Desc{position = {-5, 1.1, -1.5}, color = {1, 1, 1}, intensity = 4 * math.PI, range = 3, indirect = 1, scattering = 1}
	testing.expect(t, materials_set(r, {DEFAULT_MATERIAL}))
	scene_given(r, instances, {lamp}, {}, {sky = {0.02, 0.02, 0.02}})
	camera := Camera{position = {2.6, 2.2, 3}, forward = {0.4, -1.6, -5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 96 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
	rhi.device_wait_idle(f.device)
	probes, traced, lit := probe_work_after(t, r, camera)
	testing.expectf(t, probes == 0 && traced == 0 && lit == 0, "with nothing changed no probe is traced: %d probes, %d rays, %d hits", probes, traced, lit)
	rays := r.ddgi.total * r.ddgi.rays_per_probe
	settle :: proc(t: ^testing.T, r: ^Renderer, camera: Camera) {
		for _ in 0 ..< 96 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
		_, traced, lit := probe_work_after(t, r, camera)
		testing.expectf(t, traced == 0 && lit == 0, "settled again: %d rays, %d hits", traced, lit)
	}

	// A texture no material names comes and goes, as the image of a capture: nothing a ray meets changes.
	image, made := view_texture_add(r, 16, 16, "capture")
	testing.expect(t, made, r.error)
	testing.expect(t, view_texture_remove(r, image))
	probes, traced, lit = probe_work_after(t, r, camera)
	testing.expectf(t, probes == 0 && traced == 0 && lit == 0, "a texture no material names traces nothing when it goes: %d probes, %d rays, %d hits", probes, traced, lit)

	// One the wall shows is loaded again under its handle: the rays that meet the wall are traced again.
	white := [4]u8{255, 255, 255, 255}
	paint, painted := texture_add(r, {pixels = white[:], width = 1, height = 1, srgb = true, name = "paint"})
	testing.expect(t, painted, r.error)
	textured := DEFAULT_MATERIAL
	textured.textures[.Base_Color] = paint
	testing.expect(t, materials_set(r, {textured}))
	settle(t, r, camera)
	testing.expect(t, texture_remove(r, paint))
	again, loaded := texture_add(r, {pixels = white[:], width = 1, height = 1, srgb = true, name = "paint"})
	testing.expect(t, loaded && again == paint, r.error)
	probes, traced, lit = probe_work_after(t, r, camera)
	testing.expectf(t, traced > 0, "a texture a material names traces the rays that meet it when it goes: %d rays", traced)
	settle(t, r, camera)

	// The lamp changes color before anything else changes, which the probes it
	// wakes would check their rays against: the hits it reaches take their
	// light again, and no ray is traced.
	lamp.color = {1, 0.9, 0.8}
	testing.expect(t, scene_light_update(r, 0, lamp))
	probes, traced, lit = probe_work_after(t, r, camera)
	testing.expectf(t, lit > 0 && lit < rays / 2 && traced == 0, "a light that changes lights again the hits it reaches and traces nothing: %d hits, %d rays of %d", lit, traced, rays)
	settle(t, r, camera)

	before, width, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(before)
	beside := project(r, camera, {4.2, -0.39, -2})
	was := pixel(before, width, beside)

	// The box comes before the wall: the frame that follows shows its glow on the floor beside it.
	testing.expect(t, scene_move(r, {2}, {trs({2.65, 0.35, -2}, {1.5, 1.5, 1.5})}))
	testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)
	rhi.device_wait_idle(f.device)
	after, _, _, captured := golden_capture(r)
	testing.expect(t, captured, r.error)
	if captured {
		now := pixel(after, width, beside)
		testing.expectf(t, now[1] > was[1] + 20 && now[1] > now[0] * 1.5, "the floor takes the glow of the box in the frame it comes: %v, before %v", now, was)
		delete(after)
	}
	settle(t, r, camera)

	// It moves half a metre: only the rays that cross where it was and where it is are traced again.
	testing.expect(t, scene_move(r, {2}, {trs({3.15, 0.35, -2}, {1.5, 1.5, 1.5})}))
	probes, traced, lit = probe_work_after(t, r, camera)
	testing.expectf(t, traced > 0 && traced < rays / 4, "a box that moves traces again the rays that cross it: %d of %d", traced, rays)
	settle(t, r, camera)

	// The wall takes a program that reads the time (Grid, as if it did): once
	// the change settles, the probes whose rays meet it trace them by turns.
	grid := program_find(r, "Grid", .Surface)
	if !testing.expect(t, grid != nil, "the tests have the Grid program") {return}
	grid.reads += {.Time}
	timed := DEFAULT_MATERIAL
	timed.program_id = grid.id
	timed.custom_params = program_defaults(grid)
	testing.expect(t, materials_set(r, {timed}))
	for _ in 0 ..< 96 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
	probes, traced, lit = probe_work_after(t, r, camera)
	testing.expectf(t, probes > 0 && traced > 0 && traced < rays / 4, "the rays that meet a program that reads the time are traced by turns: %d probes, %d rays of %d", probes, traced, rays)
	expect_clean(t, f.device)
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
	lights := []Light_Desc{{position = {1, 2, 1}, color = {1, 0.9, 0.8}, intensity = 10 * math.PI, range = 10, indirect = 1, scattering = 1}}
	scene_given(r, instances, lights, {direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.2, 0.3, 0.5}})
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
	sun := Sun_Desc{direction = {0.2, 1, 0.3}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true, indirect = 1, scattering = 1}
	scene_given(r, []Instance_Desc{wall, hidden_cube}, nil, sun, {sky = {0.2, 0.2, 0.2}})
	for _ in 0 ..< 5 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expectf(t, r.stats.occluded_instances == 1 && r.stats.visible_instances == 1, "wall hides the cube: occluded %d visible %d", r.stats.occluded_instances, r.stats.visible_instances)
	// Move the wall away: phase 0 still rejects the cube with last frame's
	// pyramid, phase 1 must rescue it in this very frame.
	wall.transform = trs({20, 1, 2}, {6, 4, 0.2})
	scene_given(r, []Instance_Desc{wall, hidden_cube}, nil, sun, {sky = {0.2, 0.2, 0.2}})
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
lights_field :: proc(f: ^Cube_Fixture, count: int, range: f32, height: f32 = 3.5, radius: f32 = 0, shadowless := false) {
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
		l = {position = {-9 + 18 * (f32(x) + 0.5) / 32, height, -8 + 16 * (f32(z) + 0.5) / 32}, color = {1, 0.7, 0.4}, intensity = (2 * 256 / f32(count)) * math.PI, range = range, radius = radius, indirect = 1, scattering = 1, shadowless = shadowless}
	}
	scene_given(f.renderer, instances[:], lights, {}, {})
}

// How much more an image differs from another across the borders of the
// tiles of the lists of the lights (LIGHT_LIST_TILE pixels a side) than in
// the middle of them: the mean, over the pairs of neighbours along x and y
// either image lights, of how far the step from one to the other is from that
// of the reference, in levels of the 255 of a channel.
@(private = "file")
tile_steps :: proc(image, reference: []u8, width, height: int) -> (across, within: f32) {
	sums: [2]f64
	counts: [2]int
	for y in 0 ..< height {for x in 0 ..< width {
		for axis in 0 ..< 2 {
			at := x if axis == 0 else y
			if at == 0 || (at % LIGHT_LIST_TILE != 0 && at % LIGHT_LIST_TILE != LIGHT_LIST_TILE / 2) {continue}
			a, b := (y * width + x) * 4, (y * width + x - 1) * 4 if axis == 0 else ((y - 1) * width + x) * 4
			if max(reference[a], reference[a + 1], reference[a + 2], image[a], image[a + 1], image[a + 2]) < 8 {continue}
			which := 0 if at % LIGHT_LIST_TILE == 0 else 1
			for c in 0 ..< 3 {
				sums[which] += abs((f64(image[a + c]) - f64(image[b + c])) - (f64(reference[a + c]) - f64(reference[b + c])))
			}
			counts[which] += 3
		}
	}}
	return f32(sums[0] / f64(max(counts[0], 1))), f32(sums[1] / f64(max(counts[1], 1)))
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

// What the lighting approximates: the mean of `frames` frames of the
// reference of the lights, whose rays go to other points of the lights each
// frame. The settings of the renderer are those of the image it is compared
// with, without the temporal filter. The fixture has TEST_GENERATION.
@(private = "file")
reference_image :: proc(t: ^testing.T, f: ^Cube_Fixture, camera: Camera, frames: int, mode := Debug_View.None) -> (image: []u8, ok: bool) {
	r := f.renderer
	settings := r.settings
	reference := settings
	reference.taa = false
	testing.expect(t, renderer_apply_settings(r, reference))
	defer testing.expect(t, renderer_apply_settings(r, settings))
	sum: []f32
	defer delete(sum)
	for _ in 0 ..< frames {
		testing.expect(t, reference_frame(r, {camera = camera, inspection = {mode = mode}}, {.Lights}, nil), r.error)
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
// of it, and the same from a frame to the next. Without shadows, many more
// reach most tiles of the screen than a list holds, over posts whose edges
// the tiles straddle: the pixels show what every light gives, with no step
// where a tile ends, whether its pixels sum its list or walk the tree.
@(test)
render_many_lights_match_their_reference :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 480, 300, settings, programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	renderer_set_display_transform(r, .ACES_2)
	camera := Camera{position = {16, 12, 18}, forward = {-16, -12, -18}, up = {0, 1, 0}, fov_y = 50, near = 0.1, far = 100, exposure = UNIT_EXPOSURE}
	for shadowless in ([2]bool{false, true}) {
		lights_field(&f, 1024, 8, radius = 0.1, shadowless = shadowless)
		reference, ok := reference_image(t, &f, camera, 8)
		if !ok {return}
		defer delete(reference)
		renderer_camera_cut(r)
		for _ in 0 ..< 16 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		rhi.device_wait_idle(f.device)
		lit, w, h, ok2 := golden_capture(r)
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
		testing.expectf(t, abs(bias) < 1.5 && rms < 8, "without shadows %v: a few rays give what every light gives: %v brighter, %v apart, of 255", shadowless, bias, rms)
		testing.expectf(t, flicker < 1.5, "without shadows %v: and the same from a frame to the next: %v of 255", shadowless, flicker)
		if shadowless {
			lists := r.stats.light_lists
			testing.expectf(t, lists.walked > 0 && lists.walked < lists.cells && lists.longest > 0 && lists.longest < abi.LIGHT_LIST_WORDS, "some tiles list the lights and others walk them: %v", lists)
			across, within := tile_steps(lit, reference, w, h)
			testing.expectf(t, across < 1.25 * within + 0.5, "the steps across the borders of the tiles are %v of 255 from those of the reference, within the tiles %v", across, within)
		}
	}
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

// Lights that the tree adds up by groups give what they give one by one, the
// same from one frame to the next: a ring of lights with shadows; lights
// without them, one dim that reaches far among bright ones that reach a
// little, which a group of them lost beyond the mean of their ranges; a
// crowd of lights without them, more than a walk visits, under the sun; and
// a ceiling of downlights without them, of two widths, more than a walk
// visits, whose groups stand for them by the cones they shine in; and a few
// downlights, rectangles and tubes without them. Those without shadows also from a view across
// the floor, whose tiles span far and near ground and, where a post stands,
// the edges of it: the tiles give what the lights give, with no step where
// one ends. The few lights fit the lists of the tiles, which their pixels
// sum; the many downlights are more than a list holds, and the pixels of
// those tiles walk the tree (Stats.light_lists counts them).
@(test)
render_groups_of_lights_give_what_their_lights_give :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 64, 48, settings, programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	Case :: enum {Ring, Reaches, Crowd, Spots, Lamps}
	for c in Case {
		lights := make([dynamic]Light_Desc, context.temp_allocator)
		sun: Sun_Desc
		camera := Camera{position = {0, 6, 0.01}, forward = {0, -6, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		// The view across the floor, and where its post stands; no post under the sun, whose shadow is not what is compared.
		across := Camera{position = {4, 1.2, 3}, forward = {-4, -1, -3}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
		post := Vec3{1.2, 0.6, 0.6}
		// The part of the floor compared, from a corner to the other.
		low, high := Vec3{-2, 0, -1.5}, Vec3{2, 0, 1.5}
		switch c {
		case .Ring:
			for i in 0 ..< 24 {
				angle := f32(i) / 24 * 2 * math.PI
				radius := f32(1 + i % 3)
				append(&lights, Light_Desc{position = {math.cos(angle) * radius, 1.2, math.sin(angle) * radius}, color = {0.4 + 0.6 * f32(i % 2), 0.5, 0.4 + 0.6 * f32(i % 3) / 2}, intensity = 0.25 * math.PI, range = 6, indirect = 1, scattering = 1})
			}
		case .Reaches:
			for i in 0 ..< 12 {
				angle := f32(i) / 12 * 2 * math.PI
				append(&lights, Light_Desc{position = {-4.5 + 0.4 * math.cos(angle), 0.6, -4.5 + 0.4 * math.sin(angle)}, color = {1, 0.8, 0.6}, intensity = 2000, range = 1.5, indirect = 1, scattering = 1, shadowless = true})
			}
			append(&lights, Light_Desc{position = {-4.5, 0.6, -4.5}, color = {1, 0.9, 0.8}, intensity = 150, range = 350, indirect = 1, scattering = 1, shadowless = true})
			camera = {position = {0, 14, 0.01}, forward = {0, -14, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
			across = {position = {5, 2.5, 5}, forward = {-9.5, -2.2, -9.5}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
			post = {1.5, 0.6, 1.5}
			low, high = {-1, 0, -1}, {5, 0, 5}
		case .Crowd:
			for i in 0 ..< 256 {
				// Spread through a ball of 1 m by the golden angle.
				height := 1 - 2 * (f32(i) + 0.5) / 256
				inside := math.pow((f32(i % 16) + 0.5) / 16, f32(1) / 3)
				across := math.sqrt(1 - height * height) * inside
				angle := f32(i) * 2.3999632
				append(&lights, Light_Desc{position = {across * math.cos(angle), 1.8 + height * inside, across * math.sin(angle)}, color = {0.5 + 0.5 * f32(i % 2), 0.7, 0.5 + 0.5 * f32(i % 3) / 2}, intensity = 0.015 * math.PI, range = 8, radius = 0.02, indirect = 1, scattering = 1, shadowless = true})
			}
			sun = {direction = linalg.normalize(Vec3{0.3, 1, 0.2}), color = {1, 0.95, 0.9}, illuminance = 0.5 * math.PI, enabled = true, indirect = 1, scattering = 1}
		case .Spots:
			// Downlights a metre apart over a ceiling of 15 by 15 m, of two widths.
			for i in 0 ..< 256 {
				x, z := f32(i % 16) - 7.5 + 0.1 * math.sin(f32(i) * 1.7), f32(i / 16) - 7.5 + 0.1 * math.cos(f32(i) * 2.3)
				append(&lights, Light_Desc{position = {x, 2.2 + 0.2 * f32(i % 3), z}, color = {0.5 + 0.5 * f32(i % 2), 0.7, 0.5 + 0.5 * f32(i % 3) / 2}, intensity = 0.1 * math.PI, range = 8, radius = 0.02, direction = {0, -1, 0}, cone = 0.55 if i % 2 == 0 else 0.75, indirect = 1, scattering = 1, shadowless = true})
			}
		case .Lamps:
			// Downlights a metre and a half apart, of two widths, and among them rectangles that face down and tubes.
			for i in 0 ..< 16 {
				x, z := (f32(i % 4) - 1.5) * 1.5 + 0.1 * math.sin(f32(i) * 1.7), (f32(i / 4) - 1.5) * 1.5 + 0.1 * math.cos(f32(i) * 2.3)
				light := Light_Desc{position = {x, 2.2 + 0.2 * f32(i % 3), z}, color = {0.5 + 0.5 * f32(i % 2), 0.7, 0.5 + 0.5 * f32(i % 3) / 2}, intensity = 0.4 * math.PI, range = 8, radius = 0.02, direction = {0, -1, 0}, cone = 0.55 if i % 2 == 0 else 0.75, indirect = 1, scattering = 1, shadowless = true}
				switch i % 5 {
				case 3: light.cone, light.axis, light.size, light.intensity = 0, {1, 0, 0}, {0.6, 0.4}, 1.5
				case 4: light.cone, light.axis, light.length = 0, {1, 0, 0}, 1
				}
				append(&lights, light)
			}
		}
		instances := [2]Instance_Desc {
			{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {1, 1, 1}},
			{object_id = 2, mesh = f.cube, transform = trs(post, {0.8, 1.2, 0.8}), tint = {1, 1, 1}},
		}
		scene_given(r, instances[:1 if c == .Ring || c == .Crowd else 2], lights[:], sun, {})
		views := [2]Camera{camera, across}
		for view, v in views[:1 if c == .Ring else 2] {
			exact, ok := reference_image(t, &f, view, 1, .Direct)
			if !ok {return}
			defer delete(exact)
			renderer_camera_cut(r)
			for _ in 0 ..< 6 {testing.expect(t, renderer_frame(r, {camera = view, inspection = {mode = .Direct}}), r.error)}
			rhi.device_wait_idle(f.device)
			grouped, w, h, ok2 := golden_capture(r)
			testing.expect(t, ok2, r.error)
			if !ok2 {return}
			defer delete(grouped)
			testing.expect(t, renderer_frame(r, {camera = view, inspection = {mode = .Direct}}), r.error)
			rhi.device_wait_idle(f.device)
			next, _, _, ok3 := golden_capture(r)
			testing.expect(t, ok3, r.error)
			if !ok3 {return}
			defer delete(next)
			if v == 0 {
				a, b := project(r, view, low), project(r, view, high)
				x0, y0, x1, y1 := min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y)
				reference := region_mean(exact, w, x0, y0, x1, y1)
				estimate := region_mean(grouped, w, x0, y0, x1, y1)
				testing.expectf(t, reference[0] > 40, "%v: direct light is visible: %v", c, reference)
				for k in 0 ..< 3 {
					testing.expectf(t, abs(estimate[k] - reference[k]) <= 0.04 * reference[k] + 2, "%v: channel %d: by groups %v, one by one %v", c, k, estimate, reference)
				}
			} else {
				steps, within := tile_steps(grouped, exact, w, h)
				testing.expectf(t, steps < 1.25 * within + 0.5, "%v: the steps across the borders of the tiles are %v of 255 from those of the reference, within the tiles %v", c, steps, within)
			}
			_, rms := image_error(grouped, exact)
			// The groups of downlights the walk keeps blur the edges of their cones on the floor.
			testing.expectf(t, rms < (5 if c == .Spots || c == .Lamps else 4), "%v, view %d: %v of 255 apart", c, v, rms)
			testing.expectf(t, slice.equal(next, grouped), "%v, view %d: the next frame is the same", c, v)
			lists := r.stats.light_lists
			#partial switch c {
			case .Reaches, .Lamps:
				testing.expectf(t, lists.walked == 0 && lists.longest > 0 && lists.longest < abi.LIGHT_LIST_WORDS, "%v, view %d: every tile lists its lights: %v", c, v, lists)
			case .Crowd:
				testing.expectf(t, lists.walked < lists.cells && lists.longest > 0 && lists.longest < abi.LIGHT_LIST_WORDS, "%v, view %d: tiles list their lights: %v", c, v, lists)
			case .Spots:
				testing.expectf(t, lists.walked > 0 && lists.longest < abi.LIGHT_LIST_WORDS, "%v, view %d: tiles with more lights than a list holds are counted: %v", c, v, lists)
			}
		}
		free_all(context.temp_allocator)
	}
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
	if !cube_fixture_init(t, &f, 480, 300, settings, programs = true) {return}
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
	sun := Sun_Desc{direction = {0, math.sin(elevation), -math.cos(elevation)}, color = {1, 0.85, 0.6}, illuminance = 3 * math.PI, enabled = true, indirect = 1, scattering = 1}
	scene_given(r, instances, nil, sun, {sky = {0.05, 0.05, 0.06}})
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

// Where a point covers more of the ground than the penumbra at it, the sun
// tells the share of the point that is lit. A scene that reaches high
// towards the sun widens the search for blockers far past a narrow shadow:
// the inside of that shadow stays dark, with no part of the wide search
// lighting it.
@(test)
render_a_narrow_shadow_stays_dark_under_a_tall_scene :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.taa = false
	if !cube_fixture_init(t, &f, 192, 128, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	elevation := f32(38) * math.RAD_PER_DEG
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {40, 0.2, 40}), tint = {0.8, 0.7, 0.5}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0.75, 0}, {0.4, 1.5, 0.4}), tint = {0.8, 0.6, 0.4}},
		// High towards the sun, its shadow far off the floor.
		{object_id = 3, mesh = f.cube, transform = trs({0, 150, -60}, {1, 1, 1}), tint = {0.5, 0.5, 0.5}},
	}
	sun := Sun_Desc{direction = {0, math.sin(elevation), -math.cos(elevation)}, color = {1, 1, 1}, illuminance = 3 * math.PI, enabled = true, indirect = 1, scattering = 1}
	scene_given(r, instances, nil, sun, {sky = {0.2, 0.25, 0.35}})
	camera := Camera{position = {0, 3, 9}, forward = {0, -3, -8}, up = {0, 1, 0}, fov_y = 55, near = 0.05, far = 300, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 8 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	rhi.device_wait_idle(f.device)
	pixels, w, _, ok := golden_capture(r)
	testing.expect(t, ok, r.error)
	if !ok {return}
	defer delete(pixels)
	// Along the middle of the shadow of the post, and the floor beside it.
	lit := pixel(pixels, w, project(r, camera, {1.5, 0.001, 1.5}))
	for along in ([?]f32{0.6, 1.0, 1.4}) {
		shadow := pixel(pixels, w, project(r, camera, {0, 0.001, 0.2 + along}))
		testing.expectf(t, shadow[0] < 0.5 * lit[0], "the inside of the shadow %v m along it is %v, the lit floor %v", along, shadow, lit)
	}
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
		scene_given(r, instances, []Light_Desc{{position = {0, 2.5, 0}, color = {1, 1, 1}, intensity = 30 * math.PI, range = 12, radius = radius, indirect = 1, scattering = 1}}, {}, {})
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
		// The penumbra crosses the border of two faces of the cube of the
		// light 2.5 m from under it, where the taps of each face read past it:
		// no step there.
		steepest := f32(0)
		for k in 1 ..< brightest {steepest = max(steepest, abs(values[k] - values[k - 1]))}
		testing.expectf(t, i == 0 || steepest < 0.15 * (lit - dark), "the penumbra steps by %f of %f across the border of two faces", steepest, lit - dark)
	}
	testing.expectf(t, widths[0] < 0.2, "a light with no size casts a sharp shadow: %f m of penumbra", widths[0])
	testing.expectf(t, widths[1] > 0.4 && widths[1] > 3 * widths[0], "a wide one, a soft shadow: %f m of penumbra, %f m with none", widths[1], widths[0])
	expect_clean(t, f.device)
}

// A mirror ball under a light with no size, its highlight about a pixel wide,
// the direct light taken at one pixel of each 2x2: each turn of the jitter of
// the TAA moves what the points see of it. The highlight gives the same light
// at every turn, of a light with shadows (the points take it) and of one
// without (the pixels do): none misses it, none counts it twice.
@(test)
render_a_highlight_gives_its_light_at_every_turn_of_the_jitter :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	settings.direct_half_resolution = true
	if !cube_fixture_init(t, &f, 128, 96, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	mirror := DEFAULT_MATERIAL
	mirror.base_color, mirror.metallic, mirror.roughness = {1, 1, 1}, 1, 0
	materials_set(r, {mirror})
	ball := ball_mesh(r)
	camera := Camera{position = {0, 0.4, 3}, forward = {0, -0.4, -3}, up = {0, 1, 0}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	texels: []f16
	defer delete(texels)
	for shadowless in ([2]bool{false, true}) {
		light := Light_Desc{position = {1.5, 2, 2}, color = {1, 1, 1}, intensity = 10 * math.PI, range = 20, indirect = 1, scattering = 1, shadowless = shadowless}
		scene_given(r, {{object_id = 1, mesh = ball, transform = linalg.MATRIX4F32_IDENTITY, material = 1, tint = {1, 1, 1}}}, {light}, {}, {sky = {0, 0, 0}})
		for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
		if texels == nil {texels = make([]f16, int(r.main.targets.width * r.main.targets.height) * 4)}
		lights: [TAA_JITTER_PHASES]f32
		for &sum, turn in lights {
			r.main.turn = u64(turn)
			testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
			rhi.device_wait_idle(f.device)
			if !rhi.texture_read(f.device, r.main.targets.direct, slice.to_bytes(texels)) {
				testing.fail_now(t, "the direct light reads back")
			}
			for i := 0; i < len(texels); i += 4 {sum += 0.2126 * f32(texels[i]) + 0.7152 * f32(texels[i + 1]) + 0.0722 * f32(texels[i + 2])}
		}
		low, high, mean := lights[0], lights[0], f32(0)
		for sum in lights {low, high, mean = min(low, sum), max(high, sum), mean + sum / f32(len(lights))}
		testing.expectf(t, low > 0, "without shadows %v: the highlight shows: %v", shadowless, lights)
		// A tenth: a highlight a point misses or counts twice moves it by more.
		testing.expectf(t, high - low < 0.1 * mean, "without shadows %v: the highlight gives %v to %v over the turns of the jitter: %v", shadowless, low, high, lights)
	}
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
	sun := Sun_Desc{direction = {0, 1, -0.3}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}
	scene_given(r, instances, nil, sun, {sky = {0, 0, 0}})
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
	spot := Light_Desc{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 8 * math.PI, range = 10, direction = {0, -1, 0}, cone = 20 * math.RAD_PER_DEG, indirect = 1, scattering = 1}
	floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {1, 1, 1}}
	scene_given(r, []Instance_Desc{floor}, []Light_Desc{spot}, {}, {})
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

// A light with no place takes no shadow map: the atlas is the others'.
@(test)
render_a_light_with_no_place_takes_no_shadow_map :: proc(t: ^testing.T) {
	f: Cube_Fixture
	settings := test_settings()
	settings.gi_enabled = false
	if !cube_fixture_init(t, &f, 64, 48, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lamp := Light_Desc{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 8 * math.PI, range = 10, indirect = 1, scattering = 1}
	lost := lamp
	lost.position.x = math.nan_f32()
	floor := Instance_Desc{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {1, 1, 1}}
	scene_given(r, []Instance_Desc{floor}, []Light_Desc{lamp, lost}, {}, {})
	camera := Camera{position = {0, 6, 0.01}, forward = {0, -6, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	testing.expect(t, renderer_frame(r, {camera = camera}), r.error)
	b := &r.targets.shadow_raster
	rastered := 0
	for light in b.raster {if light != 0 {rastered += 1}}
	testing.expectf(t, rastered == 1 && b.raster[0] == 1, "only the placed light takes maps: %v", b.raster)
	expect_clean(t, f.device)
}

// A light without shadows lights through the box that holds it, directly and
// by what the room around bounces, and a sun without them through the box in
// its way; neither takes a shadow map. With shadows the box keeps the light.
@(test)
render_a_light_without_shadows_lights_through_what_holds_it :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 96, 64, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	// A floor and the box, then the ceiling and walls of a room around them. The box is
	// larger than SMALL_INSTANCE_REACH: the rays of the probes see it.
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {1, 1, 1}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 1, 0}, {1.6, 1.6, 1.6}), tint = {0.5, 0.5, 0.5}},
		{object_id = 3, mesh = f.cube, transform = trs({0, 3.1, 0}, {6, 0.2, 6}), tint = {1, 1, 1}},
		{object_id = 4, mesh = f.cube, transform = trs({-3.1, 1.5, 0}, {0.2, 3.4, 6}), tint = {1, 1, 1}},
		{object_id = 5, mesh = f.cube, transform = trs({3.1, 1.5, 0}, {0.2, 3.4, 6}), tint = {1, 1, 1}},
		{object_id = 6, mesh = f.cube, transform = trs({0, 1.5, -3.1}, {6, 3.4, 0.2}), tint = {1, 1, 1}},
		{object_id = 7, mesh = f.cube, transform = trs({0, 1.5, 3.1}, {6, 3.4, 0.2}), tint = {1, 1, 1}},
	}
	lamp := Light_Desc{position = {0, 1, 0}, color = {1, 1, 1}, intensity = 20 * math.PI, range = 10, indirect = 1, scattering = 1}
	sun := Sun_Desc{direction = {1, 1, 0}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}
	inside := Camera{position = {0, 2.5, 2.5}, forward = {0, -2.5, -2.5}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	above := Camera{position = {0, 6, 0.01}, forward = {0, -6, -0.01}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	Case :: struct {sun: bool, instances: []Instance_Desc, camera: Camera, at: Vec3}
	// Beside the box in the room, and in the shadow the box casts away from the sun.
	for c in ([]Case{{false, instances, inside, {2.4, 0.001, -2.2}}, {true, instances[:2], above, {-1.2, 0.001, 0}}}) {
		light: [2][2]f32 // with shadows and without: the direct light and the indirect one there
		maps: [2]int
		for shadowless, i in ([2]bool{false, true}) {
			lamp.shadowless, sun.shadowless = shadowless, shadowless
			testing.expect(t, scene_given(r, c.instances, nil if c.sun else []Light_Desc{lamp}, sun if c.sun else {}, {}), r.error)
			for mode, k in ([2]Debug_View{.Direct, .Indirect}) {
				for _ in 0 ..< 16 {testing.expect(t, renderer_frame(r, {camera = c.camera, inspection = {mode = mode}}), r.error)}
				rhi.device_wait_idle(f.device)
				pixels, w, _, ok := golden_capture(r)
				if !testing.expect(t, ok, r.error) {return}
				light[i][k] = pixel(pixels, w, project(r, c.camera, c.at))[0]
				delete(pixels)
			}
			for h in r.targets.shadow_raster.held {if h.m.rect.z != 0 {maps[i] += 1}}
		}
		testing.expectf(t, light[0][0] < 4 && light[1][0] > 30, "sun %v: the direct light there, with shadows and without: %v", c.sun, light)
		// The sun lights the floor around both ways: what it bounces is near alike.
		if !c.sun {testing.expectf(t, light[0][1] < 4 && light[1][1] > 20, "the indirect light of the lamp there, with shadows and without: %v", light)}
		testing.expectf(t, maps[0] > 0 && maps[1] == 0, "sun %v: the maps with shadows and without: %v", c.sun, maps)
	}
	expect_clean(t, f.device)
}

@(test)
render_resize_and_settings_changes_stay_valid :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 64, 48, test_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	lights := []Light_Desc{{position = {0, 2, 0}, color = {1, 1, 1}, intensity = 5 * math.PI, range = 8, indirect = 1, scattering = 1}, {position = {1, 2, 1}, color = {1, 0.5, 0.2}, intensity = 5 * math.PI, range = 8, indirect = 1, scattering = 1}}
	scene_given(r, []Instance_Desc{{object_id = 1, mesh = f.cube, transform = trs({0, 0, 0}, {4, 0.2, 4}), tint = {0.8, 0.8, 0.8}}}, lights, {}, {sky = {0.2, 0.3, 0.4}})
	camera := Camera{position = {0, 3, 4}, forward = {0, -3, -4}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	renderer_resize(r, 80, 60)
	testing.expect(t, !r.targets.taa_valid && !r.targets.hiz_valid, "histories restart after a resize")
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	settings := r.settings
	settings.resolution = 30
	settings.light_budget = 0 // the lights of a cell are sampled from here on
	testing.expect(t, renderer_apply_settings(r, settings))
	for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error)}
	testing.expect_value(t, r.targets.width, u32(40))
	renderer_resize(r, 64, 48)
	settings.resolution = 1080
	testing.expect(t, renderer_apply_settings(r, settings))
	scene_given(r, nil, nil, {}, {}) // empty scene
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
    scene_given(r,{{object_id=1,mesh=f.cube,transform=trs({0,0,0},{1,1,1}),tint={1,1,1}}},nil,{},{use_background=true})
    camera:=Camera{position={0,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    target:=proc(t:^testing.T,r:^Renderer,settings:^Settings,lines:u32) {
        settings.resolution=lines
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
    // Native, 0 lines: those the views span, a pixel per point.
    target(t,r,&settings,20)
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,r.targets.height==20)
    target(t,r,&settings,0)
    testing.expect(t,renderer_frame(r,{camera=camera}),r.error)
    testing.expect(t,r.targets.width==100 && r.targets.height==50)
}

// A settings change starts again only what was made with the fields that
// changed, in every view: the rest keeps its targets, histories and probes.
@(test)
a_settings_change_starts_again_only_what_depends_on_it :: proc(t:^testing.T) {
    f:Cube_Fixture
    if !cube_fixture_init(t,&f,128,64,test_settings()) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    sun:=Sun_Desc{direction={0.2,1,0.1},color={1,1,1},illuminance=math.PI,enabled=true,indirect=1,scattering=1}
    scene_given(r,{{object_id=1,mesh=f.cube,transform=trs({0,0.5,0},{1,1,1}),tint={1,1,1}}},nil,sun,{})
    camera:=Camera{position={0,3,5},forward={0,-3,-5},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    views:=[2]Frame_View{{camera=camera,rect={0,0,64,64}},{camera=camera,rect={64,0,64,64}}}
    Case :: struct {field:string,change:proc(s:^Settings),histories,volume,gather:bool}
    cases:=[]Case{
        {"lod_error_pixels",proc(s:^Settings) {s.lod_error_pixels=2},true,true,false},
        {"light_budget",proc(s:^Settings) {s.light_budget=4},true,true,true},
        {"sun_shadows",proc(s:^Settings) {s.sun_shadows=false},false,false,false},
    }
    for c in cases {
        for _ in 0..<4 {testing.expect(t,renderer_frame(r,{views=views[:]}),r.error)}
        before:=[2]rhi.Texture{r.views[0].targets.taa[0],r.views[1].targets.taa[0]}
        irradiance:=r.ddgi.irradiance
        testing.expectf(t,r.ddgi.valid && !r.scene.changes.all,"before %s the probes are settled",c.field)
        settings:=r.settings
        c.change(&settings)
        testing.expect(t,renderer_apply_settings(r,settings),r.error)
        for &view,i in r.views[:2] {
            kept:=view.targets.taa_valid
            testing.expectf(t,view.targets.taa[0]==before[i] && view.has_previous,"%s keeps the targets and the camera of view %d",c.field,i)
            testing.expectf(t,kept==c.histories,"%s: view %d keeps its histories: %v, not %v",c.field,i,kept,c.histories)
        }
        volume:=r.ddgi.valid && r.ddgi.irradiance==irradiance
        testing.expectf(t,volume==c.volume,"%s: the probe volume is kept: %v, not %v",c.field,volume,c.volume)
        testing.expectf(t,r.scene.changes.all==c.gather,"%s: the probes gather again: %v, not %v",c.field,r.scene.changes.all,c.gather)
    }
    expect_clean(t,f.device)
}

// Views of one size share the targets that live within the frame of each
// (targets_frame) and keep their own histories: each still shows what it sees.
@(test)
views_of_one_size_share_the_targets_of_a_frame :: proc(t:^testing.T) {
    f:Cube_Fixture
    settings:=test_settings()
    settings.taa=true
    if !cube_fixture_init(t,&f,128,64,settings) {return}
    defer fixture_destroy(&f)
    r:=f.renderer
    scene_given(r,{
        {object_id=1,mesh=f.cube,transform=trs({-3,0,0},{2,2,2}),tint={1,0,0},emission={2,0,0}},
        {object_id=2,mesh=f.cube,transform=trs({3,0,0},{2,2,2}),tint={0,1,0},emission={0,2,0}},
    },nil,{direction={0.2,1,0.1},color={1,1,1},illuminance=math.PI,enabled=true,indirect=1,scattering=1},{use_background=true})
    cameras:=[2]Camera{
        {position={-3,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE},
        {position={3,0,4},forward={0,0,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE},
    }
    views:=[2]Frame_View{{camera=cameras[0],rect={0,0,64,64}},{camera=cameras[1],rect={64,0,64,64}}}
    for _ in 0..<4 {testing.expect(t,renderer_frame(r,{views=views[:]}),r.error)}
    pixels,w,_,ok:=renderer_capture(r)
    testing.expect(t,ok)
    if ok {
        for view,index in views {
            center:=pixel(pixels,w,{int(view.rect.x+view.rect.z/2),int(view.rect.y+view.rect.w/2)})
            testing.expectf(t,center[index]>150 && center[index]-center[1-index]>100,"view %d shows %v",index,center)
        }
        delete(pixels)
    }
    a,b:=&r.views[0].targets,&r.views[1].targets
    shared,own:=targets_frame(&a.frame),targets_frame(&b.frame)
    for texture,i in shared {
        testing.expectf(t,texture==own[i],"the views share target %d of the frame",i)
        for other in shared[:i] {testing.expectf(t,texture==0 || texture!=other,"target %d of the frame of a view is one of its own",i)}
    }
    testing.expect(t,a.albedo!=0 && a.taa[0]!=b.taa[0] && a.hiz[0]!=b.hiz[0],"each view keeps its histories")
    expect_clean(t,f.device)
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
    scene_given(r,{
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
    scene_given(r,{{object_id=1,mesh=f.cube,transform=trs({},{1,1,1}),tint={0.8,0.8,0.8}}},nil,{}, {sky={0.2,0.3,0.4}})
    camera:=Camera{position={0,2,4},forward={0,-2,-4},up={0,1,0},fov_y=60,near=0.05,far=100,exposure=UNIT_EXPOSURE}
    for _ in 0..<4 {testing.expect(t,renderer_frame(r,{camera=camera}),r.error)}
    rhi.device_wait_idle(f.device)
    pipelines,probes,irradiance:=r.pipelines,r.ddgi.probes,r.ddgi.irradiance
    testing.expect(t,r.has_previous && r.targets.taa_valid)
    r.targets.glass_valid,r.targets.hiz_valid=true,true
    renderer_camera_cut(r)
    testing.expect(t,!r.has_previous && r.prev_jitter=={})
    testing.expect(t,!r.targets.taa_valid)
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
	scene_given(r, instances, nil, {direction = {0.3, 1, 0.2}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true, indirect = 1, scattering = 1}, {})
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
	scene_given(r, []Instance_Desc{wall, box}, nil, {}, {})
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
	settings.resolution = 32
	settings.gi_enabled = false
	if !cube_fixture_init(t, &f, 96, 64, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, -0.1, 0}, {8, 0.2, 8}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = f.cube, transform = trs({0, 0.6, 0}, {1.2, 1.2, 1.2}), tint = {0.9, 0.2, 0.1}},
	}
	scene_given(r, instances, nil, {direction = {0.4, 1, 0.3}, color = {1, 1, 1}, illuminance = 1.5 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.2, 0.3, 0.4}})
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
		lights := []Light_Desc{{position = {0, 1, 0}, color = {1, 1, 1}, intensity = 4 * math.PI, range = 8, radius = 0.2, indirect = 1, scattering = 1}}
		scene_given(r, instances if c.body else instances[:2], lights if c.light else nil, {}, {sky = {0, 0, 0}})
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
	scene_given(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
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
	instances[0].highlight = 1
	testing.expect(t, scene_update(r, 0, instances))
	testing.expect(t, !r.scene.tlas_dirty || !r.hardware_rt, "a highlight change does not rebuild the hardware TLAS")
	testing.expect_value(t, len(r.scene.tlas_nodes), tlas_nodes)
	outlined, center := count_green(r, t, camera)
	testing.expectf(t, outlined > 40, "the silhouette is outlined, got %d green pixels", outlined)
	testing.expect(t, !center, "the interior of the highlighted object is not tinted")
	instances[0].highlight = 0
	testing.expect(t, scene_update(r, 0, instances))
	cleared, _ := count_green(r, t, camera)
	testing.expect_value(t, cleared, 0)
	// A level with a fill coats the object in its color instead of outlining it: the fourth one, in blue.
	style.fill[3] = 0.8
	testing.expect(t, renderer_set_highlight_style(r, style))
	instances[0].highlight = 4
	testing.expect(t, scene_update(r, 0, instances))
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
    settings.gi_enabled,settings.taa=false,false
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
            scene_given(r,{instance},nil,{},{background={},use_background=true})
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
	scene_given(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
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
	scene_given(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
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
	scene_given(r, instances, nil, {}, {background = {0, 0, 0}, use_background = true})
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
	instances[0].highlight, instances[1].highlight = 1, 0
	testing.expect(t, scene_update(r, 0, instances))
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
    settings.taa = true
    settings.resolution = 40
    if !cube_fixture_init(t, &f, 256, 160, settings) {return}
    defer fixture_destroy(&f)
    r := f.renderer
    renderer_resize(r, 256, 160, 2, 2)
    testing.expect(t, renderer_set_highlight_style(r, {colors = {0={0,1,0,1}}, width = 3}))
    instances := []Instance_Desc{
        {object_id = 1, mesh = f.cube, transform = trs({0,0,0}, {1,1,1}), tint = {}, highlight = 1},
        {object_id = 2, mesh = f.cube, transform = trs({0,0,0.0001}, {1,1,1}), tint = {}},
    }
    scene_given(r, instances, nil, {}, {background = {}, use_background = true})
    camera := Camera{position = {0,0,4}, forward = {0,0,-4}, up = {0,1,0}, fov_y = 50, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
    reference: []u8
    defer delete(reference)
    for variant in 0 ..< 3 {
        if variant == 1 {r.settings.resolution = 1080; renderer_resize(r, 256, 160, 2, 2)}
        if variant == 2 {instances[1].hidden = true; scene_given(r, instances, nil, {}, {background = {}, use_background = true})}
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
	if !r.hardware_rt_verified || !SOFTWARE_TRACER {return}
	camera := Camera{position = {0, 4, 6}, forward = {0, -4, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	sun := Sun_Desc{direction = {0.2, 1, 0.1}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true, indirect = 1, scattering = 1}
	scene_given(r, {{object_id = 1, mesh = f.cube, transform = trs({0, 0.5, 0}, {1, 1, 1}), tint = {1, 1, 1}}}, nil, sun, {})
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
	scene_given(r, instances, nil, sun, {})
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
	if !r.hardware_rt || !SOFTWARE_TRACER {return}
	camera := Camera{position = {0, 4, 6}, forward = {0, -4, -6}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	sun := Sun_Desc{direction = {0.2, 1, 0.1}, color = {1, 1, 1}, illuminance = 1 * math.PI, enabled = true, indirect = 1, scattering = 1}
	vertices, indices := cube_mesh()
	late, added := mesh_add(r, vertices[:], indices[:])
	testing.expect(t, added)
	testing.expect(t, r.scene.meshes[f.cube].rays[0].bvh_node_count == 0 && r.scene.meshes[late].rays[0].bvh_node_count == 0 && len(r.scene.blas_nodes) == 0, "rays traced by hardware keep no software tree")
	instances := []Instance_Desc{
		{object_id = 1, mesh = f.cube, transform = trs({0, 0.5, 0}, {1, 1, 1}), tint = {1, 1, 1}},
		{object_id = 2, mesh = late, transform = trs({0, -0.1, 0}, {8, 0.2, 8}), tint = {1, 1, 1}},
	}
	scene_given(r, instances, nil, sun, {})
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

// ---------------------------------------------------------------- tracers

// Whether r has every pipeline of the rays of tracer, and none of the other
// tracer's when only is set.
@(private = "file")
tracer_made :: proc(t: ^testing.T, r: ^Renderer, tracer: Pipeline_Rays, only: bool, loc := #caller_location) {
	testing.expectf(t, tracer_missing(r, tracer) == "", "the pipeline %s of rays traced by %v is made", tracer_missing(r, tracer), tracer, loc = loc)
	if !only {return}
	list: Pipeline_List
	pipelines_list(r, &list)
	for item in list.items[:list.count] {
		other := item.rays != .Any && item.rays != tracer
		testing.expectf(t, !other || item.target^ == 0, "the pipeline %s of rays traced by %v is not made while they are traced by %v", pipeline_name(r, item), item.rays, tracer, loc = loc)
	}
}

// A slab over a floor in the sun: the floor under it is darker than the
// floor in the open only if the frame traced the shadow rays.
@(private = "file")
tracer_frame_shadows :: proc(t: ^testing.T, r: ^Renderer, cube: Mesh_Handle, loc := #caller_location) {
	instances := []Instance_Desc{
		{object_id = 1, mesh = cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = cube, transform = trs({0, 1.5, 0}, {2, 0.2, 2}), tint = {0.5, 0.5, 0.5}},
	}
	scene_given(r, instances, nil, {direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.3, 0.4, 0.6}})
	camera := Camera{position = {0, 8, 7}, forward = {0, -8, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	for _ in 0 ..< 4 {testing.expect(t, renderer_frame(r, {camera = camera}), r.error, loc = loc)}
	rhi.device_wait_idle(r.device)
	pixels, w, _, ok := renderer_capture(r)
	testing.expect(t, ok, r.error, loc = loc)
	if !ok {return}
	defer delete(pixels)
	shadow := pixel(pixels, w, project(r, camera, {0, 0.001, 0.8}))
	lit := pixel(pixels, w, project(r, camera, {3.5, 0.001, 2.5}))
	testing.expectf(t, lit[0] > shadow[0] + 40, "rays traced by hardware %v: the lit floor %v is brighter than the shadowed floor %v", r.hardware_rt, lit, shadow, loc = loc)
}

@(private = "file")
tracer_settings :: proc(mode: Trace_Mode) -> Settings {
	s := DEFAULT_SETTINGS
	s.trace_mode = mode
	s.gi_enabled = false
	return s
}

@(test)
a_device_makes_only_the_pipelines_of_the_tracer_it_uses_and_the_other_ones_on_a_switch :: proc(t: ^testing.T) {
	if !SOFTWARE_TRACER {return}
	for start in ([]Trace_Mode{.Auto, .Software}) {
		f: Cube_Fixture
		if !cube_fixture_init(t, &f, 192, 128, tracer_settings(start)) {return}
		defer fixture_destroy(&f)
		r := f.renderer
		if !r.hardware_rt_verified {
			fmt.eprintln("tracer switch skipped: the device has no ray queries that pass the self-test")
			return
		}
		first: Pipeline_Rays = .Hardware if start == .Auto else .Software
		testing.expect_value(t, r.hardware_rt, first == .Hardware)
		tracer_made(t, r, first, only = true)
		tracer_frame_shadows(t, r, f.cube)
		for mode in ([]Trace_Mode{.Software if start == .Auto else .Auto, start}) {
			settings := r.settings
			settings.trace_mode = mode
			testing.expect(t, renderer_apply_settings(r, settings), r.error)
			tracer: Pipeline_Rays = .Software if mode == .Software else .Hardware
			testing.expect_value(t, r.hardware_rt, tracer == .Hardware)
			tracer_made(t, r, tracer, only = false)
			tracer_frame_shadows(t, r, f.cube)
		}
		expect_clean(t, f.device)
	}
}

@(test)
a_device_without_ray_queries_starts_with_the_software_pipelines :: proc(t: ^testing.T) {
	if !SOFTWARE_TRACER {return}
	f: Cube_Fixture
	if !fixture_init(t, &f, 192, 128, tracer_settings(.Auto), hardware_rt = false) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	testing.expect(t, !r.hardware_rt)
	tracer_made(t, r, .Software, only = true)
	vertices, indices := cube_mesh()
	added: bool
	f.cube, added = mesh_add(r, vertices[:], indices[:])
	testing.expect(t, added)
	tracer_frame_shadows(t, r, f.cube)
	expect_clean(t, f.device)
}

// ---------------------------------------------------------------- moves

@(private = "file")
move_settings :: proc() -> Settings {
	s := test_settings()
	s.probe_grid, s.probe_cascades = 8, 2
	// The probe volume traces the probes what changed reaches, in an order
	// two renderers do not share: they do not give it byte for byte.
	s.gi_enabled = false
	return s
}

MOVE_TEST_SUN :: Sun_Desc{direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}
MOVE_TEST_ENVIRONMENT :: Environment{sky = {0.3, 0.4, 0.6}}
MOVE_TEST_CAMERA :: Camera{position = {0, 8, 7}, forward = {0, -8, -7}, up = {0, 1, 0}, fov_y = 60, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}

// A floor and a few boxes; the second one is skipped by the renderer: its mesh does not exist.
@(private = "file")
move_scene :: proc(cube: Mesh_Handle, instances: ^[5]Instance_Desc) {
	instances^ = {
		{object_id = 1, mesh = cube, transform = trs({0, -0.1, 0}, {12, 0.2, 12}), tint = {0.8, 0.8, 0.8}},
		{object_id = 2, mesh = cube, transform = trs({0, 5, 0}, {1, 1, 1}), hidden = true},
		{object_id = 3, mesh = cube, transform = trs({0, 1.5, 0}, {2, 0.2, 2}), tint = {0.5, 0.5, 0.5}},
		{object_id = 4, mesh = cube, transform = trs({-3, 0.5, 1}, {1, 1, 1}), tint = {0.9, 0.2, 0.2}},
		{object_id = 5, mesh = cube, transform = trs({3, 0.5, -1}, {1, 1, 1}), tint = {0.2, 0.3, 0.9}},
	}
}

// An image is compared pixel by pixel with another: every pixel traces its
// own rays, those of the reference of the lights (the fixture has
// TEST_GENERATION).
@(private = "file")
move_frames :: proc(t: ^testing.T, r: ^Renderer, count: int) {
	for _ in 0 ..< count {testing.expect(t, reference_frame(r, {camera = MOVE_TEST_CAMERA}, {.Lights}, nil), r.error)}
}

@(test)
scene_move_leaves_the_scene_that_setting_it_again_would :: proc(t: ^testing.T) {
	moved, set: Cube_Fixture
	// The tree of the instances is kept for rays traced by software.
	settings := move_settings()
	settings.trace_mode = .Software
	if !cube_fixture_init(t, &moved, 96, 64, settings, programs = true) {return}
	defer fixture_destroy(&moved)
	if !cube_fixture_init(t, &set, 96, 64, settings, programs = true) {return}
	defer fixture_destroy(&set)
	instances: [5]Instance_Desc
	move_scene(moved.cube, &instances)
	lights := []Light_Desc{{position = {2, 3, 2}, color = {1, 0.9, 0.8}, intensity = 20 * math.PI, range = 9, indirect = 1, scattering = 1}}
	for f in ([]^Cube_Fixture{&moved, &set}) {
		scene_given(f.renderer, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
		move_frames(t, f.renderer, 4)
	}
	r, expected := moved.renderer, set.renderer
	lights_before := len(r.scene.lights)

	// Wrong lists change nothing.
	testing.expect(t, !scene_move(r, {3}, {}))
	testing.expect(t, !scene_move(r, {5}, {trs({1, 1, 1}, {1, 1, 1})}))
	testing.expect(t, scene_move(r, {}, {}))
	// Instances that stay where they were move nothing.
	testing.expect(t, scene_move(r, {1, 3}, {instances[1].transform, instances[3].transform}))
	testing.expect(t, r.scene.touched_count == 0 && !r.scene.tlas_nodes_dirty)

	for step in 1 ..= 3 {
		instances[2].transform = trs({f32(step) * 0.7, 1.5, 0}, {2, 0.2, 2})
		instances[4].transform = trs({3, 0.5 + f32(step) * 0.4, -1}, {1, 1 + f32(step) * 0.2, 1})
		testing.expect(t, scene_move(r, {2, 4}, {instances[2].transform, instances[4].transform}))
		scene_given(expected, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
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
		testing.expect(t, a.instances[2].prev_world == a.instances[2].world)
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
	if !cube_fixture_init(t, &zero, 96, 64, settings, programs = true) {return}
	defer fixture_destroy(&zero)
	if !cube_fixture_init(t, &hidden, 96, 64, settings, programs = true) {return}
	defer fixture_destroy(&hidden)
	instances: [5]Instance_Desc
	move_scene(zero.cube, &instances)
	lights := []Light_Desc{{position = {2, 3, 2}, color = {1, 0.9, 0.8}, intensity = 20 * math.PI, range = 9, indirect = 1, scattering = 1}}
	for f in ([]^Cube_Fixture{&zero, &hidden}) {
		scene_given(f.renderer, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
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
		testing.expectf(t, item.min == item.max, "%s: its box %v is a point", what, item)
	}

	testing.expect(t, scene_move(r, {2}, {trs({0, 1.5, 0}, {0, 0, 0})}))
	instances[2].hidden = true
	scene_given(expected, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	expect_collapsed(t, a, 2, "moved to a zero scale")
	testing.expect_value(t, a.hidden_count, b.hidden_count)
	testing.expect(t, a.bounds_min == b.bounds_min && a.bounds_max == b.bounds_max)
	without_min, without_max := b.bounds_min, b.bounds_max
	testing.expect(t, len(a.translucent) == len(b.translucent) && len(a.reflective) == len(b.reflective) && a.overlay_count == b.overlay_count)
	expect_same_image(t, &zero, &hidden, "moved to a zero scale")

	// A move that gives it an inverse shows it again, as a set that shows it;
	// the images differ by the motion it grows with.
	testing.expect(t, scene_move(r, {2}, {shown}))
	instances[2].hidden = false
	scene_given(expected, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	move_frames(t, r, 2)
	move_frames(t, expected, 2)
	for inst, i in a.instances {testing.expectf(t, inst == b.instances[i], "moved back: instance %d", i)}
	for hw, i in a.hw_instances {testing.expectf(t, hw == b.hw_instances[i], "moved back: hardware instance %d", i)}
	testing.expect_value(t, a.hidden_count, b.hidden_count)
	testing.expect(t, len(a.translucent) == len(b.translucent) && len(a.reflective) == len(b.reflective) && a.overlay_count == b.overlay_count)

	// A set gives the same, and a transform that is not finite hides it too.
	instances[2].transform = trs({0, 1.5, 0}, {0, 0, 0})
	scene_given(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	expect_collapsed(t, a, 2, "set with a zero scale")
	instances[2].transform = trs({math.nan_f32(), 1.5, 0}, {1, 1, 1})
	scene_given(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	expect_collapsed(t, a, 2, "set with a position that is not a number")
	testing.expect(t, a.has_bounds && a.bounds_min == without_min && a.bounds_max == without_max)
	// One hidden by its description stays hidden whatever its transform.
	instances[2].transform = trs({0, 1.5, 0}, {0, 0, 0})
	instances[2].hidden = true
	scene_given(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	testing.expect(t, a.instances[2].meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED) == INSTANCE_FLAG_HIDDEN)
	testing.expect(t, scene_move(r, {2}, {shown}))
	testing.expect(t, a.instances[2].meta.w & INSTANCE_FLAG_HIDDEN != 0)
	testing.expect_value(t, a.hidden_count, 2)
	expect_clean(t, zero.device)
	expect_clean(t, hidden.device)
}

@(test)
scene_tint_leaves_the_scene_that_setting_it_again_would :: proc(t: ^testing.T) {
	tinted, set: Cube_Fixture
	if !cube_fixture_init(t, &tinted, 96, 64, move_settings(), programs = true) {return}
	defer fixture_destroy(&tinted)
	if !cube_fixture_init(t, &set, 96, 64, move_settings(), programs = true) {return}
	defer fixture_destroy(&set)
	instances: [5]Instance_Desc
	move_scene(tinted.cube, &instances)
	for f in ([]^Cube_Fixture{&tinted, &set}) {
		scene_given(f.renderer, instances[:], nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
		move_frames(t, f.renderer, 4)
	}
	r, expected := tinted.renderer, set.renderer
	testing.expect(t, !scene_tint(r, {3}, {}, {}))
	testing.expect(t, !scene_tint(r, {9}, {{1, 1, 1}}, {{}}))
	// The same values touch nothing.
	testing.expect(t, scene_tint(r, {0, 1}, {instances[0].tint, instances[1].tint}, {instances[0].emission, instances[1].emission}))
	testing.expect_value(t, r.scene.touched_count, 0)

	instances[3].tint, instances[3].emission = {0.1, 0.9, 0.2}, {0, 3, 0}
	instances[4].emission = {2, 2, 6}
	nodes := len(r.scene.tlas_nodes)
	testing.expect(t, scene_tint(r, {3, 4}, {instances[3].tint, instances[4].tint}, {instances[3].emission, instances[4].emission}))
	scene_given(expected, instances[:], nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
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
			for axis in 0 ..< 3 {bmin[axis], bmax[axis] = min(bmin[axis], item.min[axis]), max(bmax[axis], item.max[axis])}
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
	if !cube_fixture_init(t, &f, 96, 64, settings, programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := &r.scene
	count := 900
	instances := move_grid(f.cube, count)
	defer delete(instances)
	scene_given(r, instances, nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
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
the_lights_given_alone_change_nothing_else :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 96, 64, move_settings(), programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := &r.scene
	instances: [5]Instance_Desc
	move_scene(f.cube, &instances)
	scene_given(r, instances[:], {{position = {2, 3, 2}, color = {1, 1, 1}, intensity = 20 * math.PI, range = 9, indirect = 1, scattering = 1}}, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	move_frames(t, r, 3)
	nodes := len(s.tlas_nodes)
	scene_lights_given(r, {{position = {2, 3, 2}, color = {1, 1, 1}, intensity = 5 * math.PI, range = 9, indirect = 1, scattering = 1}, {position = {-2, 3, 2}, color = {1, 0, 0}, intensity = 15 * math.PI, range = 9, indirect = 1, scattering = 1}, {position = {0, 1, 0}, intensity = 0 * math.PI, range = 9, indirect = 1, scattering = 1}}, {}, MOVE_TEST_ENVIRONMENT)
	testing.expect_value(t, len(s.lights), 2)
	testing.expect_value(t, len(s.light_tree), 3)
	testing.expect(t, s.lights_dirty && !s.instances_dirty && !s.tlas_nodes_dirty && !s.sun.enabled)
	testing.expect_value(t, len(s.instances), 5)
	testing.expect_value(t, len(s.tlas_nodes), nodes)
	move_frames(t, r, 2)
	testing.expect(t, !s.lights_dirty)
	expect_clean(t, f.device)
}

@(test)
a_light_that_changes_goes_alone_and_the_gpu_holds_the_lights_of_the_scene :: proc(t: ^testing.T) {
	f: Cube_Fixture
	if !cube_fixture_init(t, &f, 96, 64, move_settings(), programs = true) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := &r.scene
	instances: [5]Instance_Desc
	move_scene(f.cube, &instances)
	lights := make([]Light_Desc, 300)
	defer delete(lights)
	for &light, i in lights {light = {position = {f32(i % 20) * 0.6 - 6, 1, f32(i / 20) * 0.6 - 4}, color = {1, 0.8, 0.6}, intensity = 10, range = 3, radius = 0.05, indirect = 1, scattering = 1}}
	scene_given(r, instances[:], lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
	move_frames(t, r, 2)
	for i in 0 ..< 3 {
		lights[37 + i * 50].position.y += 0.4
		lights[37 + i * 50].intensity = 12
		scene_lights_given(r, lights, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
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
			scene_given(r, instances, nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
			set, move := time.Duration(max(i64)), time.Duration(max(i64))
			for round in 0 ..< 10 {
				instances[5].transform[1, 3] = 0.5 + f32(round) * 0.01
				start := time.tick_now()
				scene_given(r, instances, nil, MOVE_TEST_SUN, MOVE_TEST_ENVIRONMENT)
				set = min(set, time.tick_since(start))
			}
			for round in 0 ..< 50 {
				instances[5].transform[1, 3] = 0.7 + f32(round) * 0.01
				start := time.tick_now()
				scene_move(r, {5}, {instances[5].transform})
				move = min(move, time.tick_since(start))
			}
			fmt.printfln("scene: %d instances; given whole %.2f ms, scene_move of one %.1f us", count, time.duration_milliseconds(set), time.duration_microseconds(move))
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
	pyramid:       bool,    // the Gbuffer pass built the depth pyramid and bound it, with no previous one in the first frame; no other stage binds it
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
	scene_given(r, instances, nil, {direction = {0.05, 1, 0.02}, color = {1, 1, 1}, illuminance = 1.2 * math.PI, enabled = true, indirect = 1, scattering = 1}, {sky = {0.3, 0.4, 0.6}})
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
			_, pyramid := pass_depth_pyramid(s, 5)
			seen.pyramid &&= !pyramid && !pass_depth_pyramid_build(s)
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
			_, before := pass_depth_pyramid(s, 1, previous = true)
			built := pass_depth_pyramid_build(s)
			levels, now := pass_depth_pyramid(s, 0)
			seen.pyramid = !before && built && now && levels == s.pass.t.hiz_levels
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
	testing.expect(t, seen.written && seen.gbuffer && seen.counters && seen.pyramid)
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
		lights := []Light_Desc{{position = at + {1.5, 2, 1}, color = {1, 0.9, 0.8}, intensity = 20, range = 10, indirect = 1, scattering = 1}}
		scene_given(r, instances, lights, {direction = {1, 1, 0}, color = {1, 1, 1}, illuminance = math.PI, enabled = true, indirect = 1, scattering = 1}, {use_background = true})
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

// A highlight narrower than a pixel, jittered over the frames: the resolve
// weighs it by how bright it shows, not by the light scale of the scene. Under
// a key light a thousand times stronger that lights nothing in view, the same
// exposure shows the same highlight, and it changes as much from frame to frame.
@(test)
taa_weighs_the_light_as_it_shows :: proc(t: ^testing.T) {
	WIDTH :: 64
	ROW :: 24
	FIRST :: 24
	WIDE :: 16
	settings := DEFAULT_SETTINGS
	settings.gi_enabled = false
	camera := Camera{position = {0, 0, 5}, forward = {0, 0, -5}, up = {0, 1, 0}, fov_y = 40, near = 0.05, far = 100, exposure = UNIT_EXPOSURE}
	change, scale: [2]f32 // change: of the highlight from frame to frame, nits
	for dim, c in ([2]bool{false, true}) {
		f: Fixture
		if !fixture_init(t, &f, WIDTH, 48, settings) {return}
		defer fixture_destroy(&f)
		r := f.renderer
		vertices, indices := cube_mesh()
		mesh, _ := mesh_add(r, vertices[:], indices[:])
		stripe := Instance_Desc{object_id = 1, mesh = mesh, transform = linalg.matrix4_translate_f32({0.01, 0, 0}) * linalg.matrix4_scale_f32({0.05, 2, 0.05}), tint = {0, 0, 0}, emission = {50, 50, 50}}
		key := []Light_Desc{{position = {0, 0, -500}, color = {1, 1, 1}, intensity = 4096, range = 1, indirect = 1, scattering = 1}}
		testing.expect(t, scene_given(r, {stripe}, key if dim else nil, {}, {}))
		scale[c] = r.scene.light_scale
		pixels := make([]f16, WIDTH * 48 * 4, context.temp_allocator)
		before: [WIDE]f32
		for frame in 0 ..< 24 {
			if !testing.expect(t, fixture_frame(&f, {camera = camera}), r.error) {return}
			rhi.device_wait_idle(f.device)
			testing.expect(t, golden_read_texture(f.device, r.main.targets.taa[(r.main.frames - 1) % 2], mem.slice_data_cast([]u8, pixels)))
			for x in 0 ..< WIDE {
				v := f32(pixels[((ROW * WIDTH) + FIRST + x) * 4 + 1]) / scale[c]
				if frame > 0 {change[c] += abs(v - before[x])}
				before[x] = v
			}
		}
		expect_clean(t, f.device)
	}
	testing.expectf(t, scale[0] / scale[1] > 500, "the key light changes the light scale: %v", scale)
	testing.expectf(t, change[0] > 0 && abs(change[1] / change[0] - 1) < 0.05, "the highlight changes as much from frame to frame under either light scale: %v nits", change)
}
