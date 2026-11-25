package mirai_render

import "core:math"
import "core:mem"
import "core:testing"
import "mirai:rhi"

// The viewmodel of a view (foreground.odin) on the GPU: a weapon held under
// the eye of a first-person camera, drawn with its own field of view.

@(private = "file")
viewmodel_settings :: proc() -> Settings {
	s := DEFAULT_SETTINGS
	s.gi_enabled = false
	s.taa = false
	return s
}

@(private = "file")
EYE :: Vec3{0, 1.6, 0}

// The eye of the player of slot 1, looking down -Z with the field of view of the world.
@(private = "file")
FIRST_PERSON :: Camera{position = EYE, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 100, near = 0.05, far = 100, exposure = UNIT_EXPOSURE, own = 1}

@(private = "file")
VIEWMODEL_FOV :: f32(60 * math.RAD_PER_DEG)

@(private = "file")
WIDTH :: 128
@(private = "file")
HEIGHT :: 96

// A unit cube of a material, outward faces counter-clockwise.
@(private = "file")
cube :: proc(r: ^Renderer, material: Material_Handle) -> Mesh_Handle {
	vertices: [24]Mesh_Vertex
	indices: [36]u32
	for n, face in ([6]Vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		u := Vec3{n.y, n.z, n.x}
		v := Vec3{n.y * u.z - n.z * u.y, n.z * u.x - n.x * u.z, n.x * u.y - n.y * u.x}
		for c, i in ([4]Vec3{n - u - v, n + u - v, n + u + v, n - u + v}) {vertices[face * 4 + i] = {position = c * 0.5, normal = n, tangent = {u.x, u.y, u.z, 1}, color = {1, 1, 1}, material = material}}
		base := u32(face * 4)
		for q, i in ([6]u32{base, base + 1, base + 2, base, base + 2, base + 3}) {indices[face * 6 + i] = q}
	}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	return mesh
}

@(private = "file")
placed :: proc(center, size: Vec3) -> Mat4 {
	m := Mat4(1)
	m[0, 0], m[1, 1], m[2, 2] = size.x, size.y, size.z
	m[0, 3], m[1, 3], m[2, 3] = center.x, center.y, center.z
	return m
}

// Where the muzzle of the weapon is, from the eye.
@(private = "file")
MUZZLE :: Vec3{0.12, -0.12, -0.66}

// The scene of a first-person view: a floor, the weapon of slot 1 (a white
// bar reaching from 0.25 m to the muzzle, with a green mark on it) and,
// with wall, a white wall 0.3 m ahead of the eye.
@(private = "file")
Viewmodel_Scene :: struct {
	floor, bar, mark, wall: Instance_Desc,
}

@(private = "file")
viewmodel_scene :: proc(r: ^Renderer) -> (s: Viewmodel_Scene) {
	white, green := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	white.base_color, green.base_color = {0.8, 0.8, 0.8}, {0, 1, 0}
	materials_set(r, {white, green})
	box, marker := cube(r, 1), cube(r, 2)
	s.floor = {object_id = 1, mesh = box, transform = placed({0, -0.05, 0}, {20, 0.1, 20}), tint = {1, 1, 1}}
	s.bar = {object_id = 2, mesh = box, transform = placed(EYE + {0.12, -0.12, -0.455}, {0.04, 0.04, 0.41}), tint = {1, 1, 1}, owner = 1, foreground = true}
	s.mark = {object_id = 3, mesh = marker, transform = placed(EYE + MUZZLE + {0, 0.025, 0}, {0.01, 0.01, 0.01}), tint = {1, 1, 1}, owner = 1, foreground = true}
	s.wall = {object_id = 4, mesh = box, transform = placed(EYE + {0, 0, -0.325}, {6, 6, 0.05}), tint = {1, 1, 1}}
	scene_set_foreground(r, {VIEWMODEL_FOV, 0, 0, 0})
	return
}

// The pixels of a target of the main view.
@(private = "file")
read_target :: proc(t: ^testing.T, f: ^Fixture, target: rhi.Texture, $T: typeid, channels: int) -> []T {
	r := f.renderer
	rhi.device_wait_idle(f.device)
	pixels := make([]T, int(r.targets.width * r.targets.height) * channels, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, target, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	return pixels
}

// The pixels the views target tags as of the viewmodel.
@(private = "file")
tagged :: proc(t: ^testing.T, f: ^Fixture) -> (count: int, tags: []u8) {
	tags = read_target(t, f, f.renderer.targets.views, u8, 1)
	for tag in tags {if tag & VIEWS_FOREGROUND != 0 {count += 1}}
	return
}

// The viewmodel is drawn with its own field of view: the mark at its muzzle
// is where the projection of 60 degrees puts it, not that of the world (100),
// its pixels are tagged, and nothing of the world is.
@(test)
the_viewmodel_is_drawn_with_its_own_field_of_view :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	scene_given(r, {s.floor, s.bar, s.mark}, nil, {direction = {0, 0.6, 0.8}, color = {1, 1, 1}, illuminance = 10000, enabled = true}, {sky = {1000, 1000, 1000}})
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = FIRST_PERSON}), r.error)}
	albedo := read_target(t, &f, r.targets.albedo, u8, 4)
	sum, count := Vec2{}, 0
	for y in 0 ..< HEIGHT {
		for x in 0 ..< WIDTH {
			at := (y * WIDTH + x) * 4
			if albedo[at + 1] > 200 && albedo[at] < 60 {sum += {f32(x) + 0.5, f32(y) + 0.5}; count += 1}
		}
	}
	testing.expectf(t, count > 0, "the mark is drawn")
	if count == 0 {return}
	seen := sum / f32(count)
	project :: proc(p: Vec3, fov: f32) -> Vec2 {
		tangent := math.tan(fov * 0.5)
		ndc := Vec2{p.x / (-p.z * tangent * f32(WIDTH) / f32(HEIGHT)), p.y / (-p.z * tangent)}
		return {(ndc.x + 1) * 0.5 * f32(WIDTH), (1 - ndc.y) * 0.5 * f32(HEIGHT)}
	}
	own := project(MUZZLE + {0, 0.025, 0}, VIEWMODEL_FOV)
	world := project(MUZZLE + {0, 0.025, 0}, f32(100 * math.RAD_PER_DEG))
	testing.expectf(t, abs(seen.x - own.x) < 1 && abs(seen.y - own.y) < 1, "the mark is at %v, the projection of 60 degrees puts it at %v (that of the world: %v)", seen, own, world)
	bar, tags := tagged(t, &f)
	testing.expectf(t, bar > count && bar < WIDTH * HEIGHT / 4, "the pixels of the viewmodel are tagged: %d", bar)
	depths := read_target(t, &f, r.targets.linear_depth, f32, 1)
	for tag, i in tags {
		if tag & VIEWS_FOREGROUND == 0 {continue}
		testing.expectf(t, depths[i] > 0.2 && depths[i] < 0.7, "a pixel of the viewmodel keeps its true depth: %v", depths[i])
		break
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A wall 0.3 m ahead of the eye, nearer than most of the weapon, hides none
// of it, and the weapon takes its light in front of the wall: lit by the sun
// behind the eye as without the wall, never black, and not by the red light
// of the room beyond the wall.
@(test)
a_wall_nearer_than_the_viewmodel_neither_hides_nor_darkens_it :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	sun := Sun_Desc{direction = {0, 0.6, 0.8}, color = {1, 1, 1}, illuminance = 10000, enabled = true}
	room := Light_Desc{position = EYE + {0, 0, -1.5}, color = {1, 0, 0}, intensity = 20000, range = 20, radius = 0.05}
	Seen :: struct {pixels: int, light: Vec3}
	look :: proc(t: ^testing.T, f: ^Fixture) -> (seen: Seen) {
		r := f.renderer
		for _ in 0 ..< 3 {testing.expect(t, renderer_frame(r, {camera = FIRST_PERSON}), r.error)}
		count, tags := tagged(t, f)
		display := read_target(t, f, r.targets.display, f16, 4)
		seen.pixels = count
		for tag, i in tags {
			if tag & VIEWS_FOREGROUND == 0 {continue}
			seen.light += Vec3{f32(display[i * 4]), f32(display[i * 4 + 1]), f32(display[i * 4 + 2])} / r.scene.light_scale
		}
		seen.light /= f32(max(count, 1))
		return
	}
	scene_given(r, {s.floor, s.bar, s.mark}, nil, sun, {})
	open := look(t, &f)
	scene_given(r, {s.floor, s.bar, s.mark, s.wall}, {room}, sun, {})
	walled := look(t, &f)
	testing.expectf(t, open.pixels > 0 && walled.pixels == open.pixels, "the wall hides none of the viewmodel: %d pixels, %d without it", walled.pixels, open.pixels)
	testing.expectf(t, walled.light.g > open.light.g * 0.8, "the sun lights it in front of the wall: %v, %v without it", walled.light, open.light)
	testing.expectf(t, walled.light.r < walled.light.g * 1.2, "the light beyond the wall does not reach it: %v", walled.light)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The pixel of the mark of the weapon (green albedo), and its middle.
@(private = "file")
mark_seen :: proc(t: ^testing.T, f: ^Fixture) -> (middle: Vec2, at: int, found: bool) {
	albedo := read_target(t, f, f.renderer.targets.albedo, u8, 4)
	sum, count, nearest := Vec2{}, 0, f32(1e9)
	for y in 0 ..< HEIGHT {
		for x in 0 ..< WIDTH {
			i := (y * WIDTH + x) * 4
			if albedo[i + 1] > 200 && albedo[i] < 60 {sum += {f32(x) + 0.5, f32(y) + 0.5}; count += 1}
		}
	}
	if count == 0 {return}
	middle = sum / f32(count)
	for y in 0 ..< HEIGHT {
		for x in 0 ..< WIDTH {
			if d := abs(f32(x) + 0.5 - middle.x) + abs(f32(y) + 0.5 - middle.y); d < nearest {nearest, at = d, y * WIDTH + x}
		}
	}
	return middle, at, true
}

// A weapon that moves under the eye leaves where it was with the motion its
// own projection gives it: the motion target of its pixels takes them to
// where its previous transform drew them with the field of view of the
// viewmodel, not with that of the world.
@(test)
the_motion_of_the_viewmodel_is_that_of_its_own_projection :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	sun := Sun_Desc{direction = {0, 0.6, 0.8}, color = {1, 1, 1}, illuminance = 10000, enabled = true}
	scene_given(r, {s.floor, s.bar, s.mark}, nil, sun, {})
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = FIRST_PERSON}), r.error)}
	before, _, seen := mark_seen(t, &f)
	STEP :: Vec3{0.03, 0.02, 0}
	for &instance in ([]^Instance_Desc{&s.bar, &s.mark}) {instance.transform[0, 3] += STEP.x; instance.transform[1, 3] += STEP.y}
	scene_given(r, {s.floor, s.bar, s.mark}, nil, sun, {})
	testing.expect(t, renderer_frame(r, {camera = FIRST_PERSON}), r.error)
	after, at, moved := mark_seen(t, &f)
	testing.expect(t, seen && moved, "the mark is drawn")
	if !seen || !moved {return}
	motion := read_target(t, &f, r.targets.motion, f16, 2)
	given := Vec2{f32(motion[at * 2]), f32(motion[at * 2 + 1])} * Vec2{WIDTH, HEIGHT}
	testing.expectf(t, abs(given.x - (before.x - after.x)) < 0.75 && abs(given.y - (before.y - after.y)) < 0.75, "the motion of the mark is %v pixels, it moved %v", given, before - after)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
