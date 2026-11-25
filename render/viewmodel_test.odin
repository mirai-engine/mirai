package mirai_render

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "mirai:rhi"

// The viewmodel of a view (viewmodel.odin) on the GPU: a weapon held under
// the eye of a first-person camera of 70 degrees, drawn with 55.

@(private = "file")
viewmodel_settings :: proc() -> Settings {
	s := DEFAULT_SETTINGS
	s.gi_enabled = false
	s.taa = false
	return s
}

@(private = "file")
EYE :: Vec3{0, 1.6, 0}

// The eye of the player of slot 1, looking down -Z.
@(private = "file")
FIRST_PERSON :: Camera{position = EYE, forward = {0, 0, -1}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100, exposure = UNIT_EXPOSURE, own = 1}

@(private = "file")
VIEWMODEL_FOV :: f32(55 * math.RAD_PER_DEG)

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

// A box of size at center, held by a camera at EYE turned yaw radians around
// the vertical: center from the eye as the camera sees it.
@(private = "file")
held :: proc(center, size: Vec3, yaw: f32 = 0) -> Mat4 {
	c, s := math.cos(yaw), math.sin(yaw)
	m := Mat4(1)
	m[0, 0], m[0, 2], m[2, 0], m[2, 2] = c * size.x, s * size.z, -s * size.x, c * size.z
	m[1, 1] = size.y
	m[0, 3], m[1, 3], m[2, 3] = EYE.x + c * center.x + s * center.z, EYE.y + center.y, EYE.z - s * center.x + c * center.z
	return m
}

// Where the mark on the muzzle of the weapon is, from the eye.
@(private = "file")
MARK :: Vec3{0.12, -0.095, -0.66}

// A floor, the weapon of slot 1 (a red bar from 0.25 m to the muzzle, with a
// green mark on it) and a white wall.
@(private = "file")
Viewmodel_Scene :: struct {
	floor, bar, mark, wall: Instance_Desc,
}

@(private = "file")
viewmodel_scene :: proc(r: ^Renderer, extra: ..Material_Desc) -> (s: Viewmodel_Scene) {
	white, green, red := DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL
	white.base_color, green.base_color, red.base_color = {0.8, 0.8, 0.8}, {0, 1, 0}, {1, 0, 0}
	materials := make([dynamic]Material_Desc, context.temp_allocator)
	append(&materials, white, green, red)
	append(&materials, ..extra)
	materials_set(r, materials[:])
	box := cube(r, 1)
	s.floor = {object_id = 1, mesh = box, transform = held({0, -1.65, 0}, {20, 0.1, 20}), tint = {1, 1, 1}}
	s.bar = {object_id = 2, mesh = cube(r, 3), transform = held({0.12, -0.12, -0.455}, {0.04, 0.04, 0.41}), tint = {1, 1, 1}, owner = 1, viewmodel = true}
	s.mark = {object_id = 3, mesh = cube(r, 2), transform = held(MARK, {0.01, 0.01, 0.01}), tint = {1, 1, 1}, owner = 1, viewmodel = true}
	s.wall = {object_id = 4, mesh = box, transform = held({0, 0, -0.325}, {6, 6, 0.05}), tint = {1, 1, 1}}
	scene_set_viewmodels(r, {VIEWMODEL_FOV, 0, 0, 0})
	return
}

@(private = "file")
SUN :: Sun_Desc{direction = {0, 0.6, 0.8}, color = {1, 1, 1}, illuminance = 10000, enabled = true}

// The pixels of a target of the main view.
@(private = "file")
read_target :: proc(t: ^testing.T, f: ^Fixture, target: rhi.Texture, $T: typeid, channels: int) -> []T {
	rhi.device_wait_idle(f.device)
	pixels := make([]T, WIDTH * HEIGHT * channels, context.temp_allocator)
	testing.expect(t, golden_read_texture(f.device, target, mem.slice_data_cast([]u8, pixels)), rhi.device_error(f.device))
	return pixels
}

// The pixels of the weapon (red or green albedo), and the middle of its mark.
@(private = "file")
Weapon_Seen :: struct {pixels, marks: int, mark: Vec2, at: int}
@(private = "file")
weapon_seen :: proc(t: ^testing.T, f: ^Fixture) -> (seen: Weapon_Seen) {
	albedo := read_target(t, f, f.renderer.targets.albedo, u8, 4)
	for i in 0 ..< WIDTH * HEIGHT {
		red, green := albedo[i * 4] > 200 && albedo[i * 4 + 1] < 60, albedo[i * 4 + 1] > 200 && albedo[i * 4] < 60
		if red || green {seen.pixels += 1}
		if green {seen.mark += {f32(i % WIDTH) + 0.5, f32(i / WIDTH) + 0.5}; seen.marks += 1}
	}
	if seen.marks == 0 {return}
	seen.mark /= f32(seen.marks)
	seen.at = int(seen.mark.y) * WIDTH + int(seen.mark.x)
	return
}

// Where the view of a field of view shows a point from the eye, pixels.
@(private = "file")
project :: proc(p: Vec3, fov: f32) -> Vec2 {
	tangent := math.tan(fov * 0.5)
	ndc := Vec2{p.x / (-p.z * tangent * f32(WIDTH) / f32(HEIGHT)), p.y / (-p.z * tangent)}
	return {(ndc.x + 1) * 0.5 * f32(WIDTH), (1 - ndc.y) * 0.5 * f32(HEIGHT)}
}

@(private = "file")
draw :: proc(t: ^testing.T, f: ^Fixture, camera: Camera, frames := 2) {
	for _ in 0 ..< frames {testing.expect(t, renderer_frame(f.renderer, {camera = camera}), f.renderer.error)}
}

// The muzzle is where the projection of 55 degrees puts it, VIEWMODEL_SCALE
// nearer the eye; the view of another player draws none of the weapon.
@(test)
the_viewmodel_is_drawn_nearer_with_its_own_field_of_view :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	scene_given(r, {s.floor, s.bar, s.mark}, nil, SUN, {sky = {1000, 1000, 1000}})
	draw(t, &f, FIRST_PERSON)
	seen := weapon_seen(t, &f)
	if !testing.expectf(t, seen.marks > 0, "the mark is drawn") {return}
	own, world := project(MARK, VIEWMODEL_FOV), project(MARK, math.to_radians(f32(70)))
	testing.expectf(t, abs(seen.mark.x - own.x) < 0.75 && abs(seen.mark.y - own.y) < 0.75, "the mark is at %v, the projection of 55 degrees puts it at %v (that of the world: %v)", seen.mark, own, world)
	depths := read_target(t, &f, r.targets.linear_depth, f32, 1)
	drawn := VIEWMODEL_SCALE * (-MARK.z - 0.005)
	testing.expectf(t, abs(depths[seen.at] - drawn) < 0.02 * drawn, "the mark is drawn %v from the eye: %v", drawn, depths[seen.at])
	other := FIRST_PERSON
	other.own = 2
	draw(t, &f, other)
	testing.expectf(t, weapon_seen(t, &f).pixels == 0, "the view of another player draws none of the weapon")
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A wall as near as the capsule of a character lets it, 0.3 m ahead of the
// eye, hides none of the weapon; it is cut from where a wall reaches its
// drawn muzzle, VIEWMODEL_SCALE as far as it is.
@(test)
a_wall_as_near_as_a_character_goes_hides_none_of_the_viewmodel :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	scene_given(r, {s.floor, s.bar, s.mark}, nil, SUN, {})
	draw(t, &f, FIRST_PERSON)
	open := weapon_seen(t, &f).pixels
	seen :: proc(t: ^testing.T, f: ^Fixture, s: Viewmodel_Scene, distance: f32) -> int {
		wall := s.wall
		wall.transform = held({0, 0, -distance - 0.025}, {6, 6, 0.05})
		scene_given(f.renderer, {s.floor, s.bar, s.mark, wall}, nil, SUN, {})
		draw(t, f, FIRST_PERSON)
		return weapon_seen(t, f).pixels
	}
	counts: [3]int
	for distance, i in ([3]f32{0.3, 0.15, 0.06}) {counts[i] = seen(t, &f, s, distance)}
	// The first centimetre a wall cuts it at, coming from 0.3 m.
	cut := f32(0)
	for step := 29; step > 5 && cut == 0; step -= 1 {
		if seen(t, &f, s, f32(step) * 0.01) < open {cut = f32(step) * 0.01}
	}
	fmt.printfln("viewmodel pixels: %d in the open, %v with a wall at 0.30, 0.15 and 0.06 m; cut from %.2f m", open, counts, cut)
	testing.expectf(t, open > 100 && counts[0] == open, "a wall at 0.3 m hides none of the weapon: %d pixels, %d without it", counts[0], open)
	muzzle := VIEWMODEL_SCALE * (-MARK.z + 0.005)
	testing.expectf(t, cut <= muzzle && cut >= muzzle - 0.015, "a wall cuts the weapon from %.2f m, its drawn muzzle is %.3f m away", cut, muzzle)
	testing.expectf(t, counts[1] < open && counts[2] < counts[1], "nearer walls cut more of it: %v of %d", counts, open)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The light of each pixel of the main view, render units.
@(private = "file")
light_of :: proc(t: ^testing.T, f: ^Fixture) -> []f32 {
	display := read_target(t, f, f.renderer.targets.display, f16, 4)
	light := make([]f32, WIDTH * HEIGHT, context.temp_allocator)
	for &l, i in light {l = 0.2126 * f32(display[i * 4]) + 0.7152 * f32(display[i * 4 + 1]) + 0.0722 * f32(display[i * 4 + 2])}
	return light
}

// The body of the player shades the ground as in the same scene without a
// viewmodel, and the weapon casts no shadow.
@(test)
the_body_shades_the_ground_as_without_a_viewmodel :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	// Its top 0.4 m under the eye, behind it; seen looking down.
	body := Instance_Desc{object_id = 5, mesh = s.floor.mesh, transform = held({0, -1, 0.15}, {0.5, 1.2, 0.3}), tint = {1, 1, 1}, owner = 1}
	down := FIRST_PERSON
	down.forward, down.up = {0, -0.95, -0.3}, {0, 0.3, -0.95}
	sun := Sun_Desc{direction = {0.15, 0.55, 0.82}, color = {1, 1, 1}, illuminance = 10000, enabled = true}
	scene_given(r, {s.floor, body}, nil, sun, {})
	draw(t, &f, down, 10)
	without := light_of(t, &f)
	scene_given(r, {s.floor, body, s.bar, s.mark}, nil, sun, {})
	draw(t, &f, down, 10)
	with := light_of(t, &f)
	albedo := read_target(t, &f, r.targets.albedo, u8, 4)
	lit, shaded, apart, compared := f32(0), 0, 0, 0
	for l in without {lit = max(lit, l)}
	for i in 0 ..< WIDTH * HEIGHT {
		red, green := albedo[i * 4] > 200 && albedo[i * 4 + 1] < 60, albedo[i * 4 + 1] > 200 && albedo[i * 4] < 60
		if red || green || without[i] <= 0 {continue}
		compared += 1
		if without[i] < 0.5 * lit {shaded += 1}
		if abs(with[i] - without[i]) > 0.02 * lit {apart += 1}
	}
	testing.expectf(t, shaded > 100, "the body shades the ground: %d pixels", shaded)
	testing.expectf(t, apart == 0, "%d of %d pixels around the weapon are lit otherwise than without it", apart, compared)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The motion of the weapon is where it was drawn in the frame before: still
// on the view as the camera turns with it, and its own move when it moves.
@(test)
the_motion_of_the_viewmodel_is_where_it_was_drawn :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	turned :: proc(yaw: f32) -> Camera {
		c := FIRST_PERSON
		c.forward = {-math.sin(yaw), 0, -math.cos(yaw)}
		return c
	}
	place :: proc(r: ^Renderer, s: ^Viewmodel_Scene, yaw: f32, step: Vec3) {
		s.bar.transform = held(Vec3{0.12, -0.12, -0.455} + step, {0.04, 0.04, 0.41}, yaw)
		s.mark.transform = held(MARK + step, {0.01, 0.01, 0.01}, yaw)
		scene_given(r, {s.floor, s.bar, s.mark}, nil, SUN, {})
	}
	motion_at :: proc(t: ^testing.T, f: ^Fixture, at: int) -> Vec2 {
		motion := read_target(t, f, f.renderer.targets.motion, f16, 2)
		return Vec2{f32(motion[at * 2]), f32(motion[at * 2 + 1])} * Vec2{WIDTH, HEIGHT}
	}
	place(r, &s, 0, {})
	draw(t, &f, turned(0))
	before := weapon_seen(t, &f)
	YAW :: f32(0.05)
	place(r, &s, YAW, {})
	draw(t, &f, turned(YAW), 1)
	still := weapon_seen(t, &f)
	held_motion := motion_at(t, &f, still.at)
	floor_motion := motion_at(t, &f, (HEIGHT - 4) * WIDTH + WIDTH / 2)
	testing.expectf(t, before.marks > 0 && abs(still.mark.x - before.mark.x) < 0.25 && abs(held_motion.x) < 0.25 && abs(held_motion.y) < 0.25,
		"the mark stays at %v as the camera turns with it (%v), its motion %v", still.mark, before.mark, held_motion)
	testing.expectf(t, abs(floor_motion.x) > 2, "the floor moves on the view: %v", floor_motion)
	place(r, &s, YAW, {0.03, 0.02, 0})
	draw(t, &f, turned(YAW), 1)
	moved := weapon_seen(t, &f)
	given := motion_at(t, &f, moved.at)
	testing.expectf(t, abs(given.x - (still.mark.x - moved.mark.x)) < 0.75 && abs(given.y - (still.mark.y - moved.mark.y)) < 0.75, "the motion of the mark is %v pixels, it moved %v", given, still.mark - moved.mark)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// What the weapon lays over itself, blends and holds as glass is drawn over
// it where its projection puts it: a red overlay of its bar, a red blended
// pane and a red pane of glass before its muzzle.
@(test)
overlays_blends_and_glass_of_the_viewmodel_are_drawn :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	blend, glass := DEFAULT_MATERIAL, DEFAULT_MATERIAL
	blend.base_color, blend.alpha_mode, blend.opacity = {1, 0, 0}, .Blend, 0.8
	glass.base_color, glass.alpha_mode, glass.opacity, glass.transmission, glass.roughness = {1, 0, 0}, .Blend, 1, 1, 0.3
	s := viewmodel_scene(r, blend, glass)
	white := s.bar
	white.mesh = s.floor.mesh
	PANE :: Vec3{0.09, -0.09, -0.6}
	pane := s.mark
	pane.object_id, pane.transform = 6, held(PANE, {0.06, 0.06, 0.005})
	at := project(PANE, VIEWMODEL_FOV)
	pixel := int(at.y) * WIDTH + int(at.x)
	shown :: proc(t: ^testing.T, f: ^Fixture, instances: []Instance_Desc, pixel: int) -> (color: Vec3, overlay: Vec3) {
		r := f.renderer
		scene_given(r, instances, nil, SUN, {})
		draw(t, f, FIRST_PERSON, 3)
		display := read_target(t, f, r.targets.display, f16, 4)
		depths := read_target(t, f, r.targets.linear_depth, f32, 1)
		count := 0
		// The weapon, drawn within 0.3 m of the eye, but around the pane.
		for i in 0 ..< WIDTH * HEIGHT {
			if !(depths[i] > 0 && depths[i] < 0.3) {continue}
			if abs(f32(i % WIDTH) - f32(pixel % WIDTH)) < 6 && abs(f32(i / WIDTH) - f32(pixel / WIDTH)) < 6 {continue}
			overlay += {f32(display[i * 4]), f32(display[i * 4 + 1]), f32(display[i * 4 + 2])}
			count += 1
		}
		overlay /= f32(max(count, 1))
		return {f32(display[pixel * 4]), f32(display[pixel * 4 + 1]), f32(display[pixel * 4 + 2])}, overlay
	}
	// The weapon white, so a red that covers it shows.
	bare, plain := shown(t, &f, {s.floor, white}, pixel)
	laid := white
	laid.overlays = {count = 1, entries = {0 = {id = 10, material = 3, blend = .Alpha, enabled = true}}}
	_, over := shown(t, &f, {s.floor, laid}, pixel)
	testing.expectf(t, plain.x < plain.y * 1.2 && over.x > over.y * 2, "the red overlay of the bar is drawn on it: %v, %v without it", over, plain)
	pane.material = 4
	blended, _ := shown(t, &f, {s.floor, white, pane}, pixel)
	pane.material = 5
	glazed, _ := shown(t, &f, {s.floor, white, pane}, pixel)
	testing.expectf(t, bare.x < bare.y * 1.2, "without a pane the weapon and the floor are not red there: %v", bare)
	testing.expectf(t, blended.x > blended.y * 2, "the blended pane before the muzzle is drawn: %v", blended)
	testing.expectf(t, glazed.x > glazed.y * 2, "the pane of glass before the muzzle is drawn: %v", glazed)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The view of another player, which draws no viewmodel, draws the scene as
// if the viewmodel of the first were not in it, byte for byte.
@(test)
a_view_without_a_viewmodel_draws_as_if_there_were_none :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	body := Instance_Desc{object_id = 5, mesh = s.floor.mesh, transform = held({0, -0.8, 0.1}, {0.5, 1.6, 0.3}), tint = {1, 1, 1}, owner = 1}
	other := FIRST_PERSON
	other.own, other.position, other.forward = 2, {1.2, 1.7, -1.5}, {-1, -0.4, 0.9}
	scene_given(r, {s.floor, body}, nil, SUN, {})
	draw(t, &f, other, 4)
	without := read_target(t, &f, r.targets.display, u16, 4)
	scene_given(r, {s.floor, body, s.bar, s.mark}, nil, SUN, {})
	draw(t, &f, other, 4)
	with := read_target(t, &f, r.targets.display, u16, 4)
	different := 0
	for value, i in with {if value != without[i] {different += 1}}
	testing.expectf(t, different == 0, "%d values of the image differ", different)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// With the history of the view, the weapon held as the camera turns keeps
// its colour, and where it was before a move shows what is behind it, with
// no trail of it (red on a grey floor).
@(test)
the_history_of_the_view_leaves_no_trail_of_the_viewmodel :: proc(t: ^testing.T) {
	settings := viewmodel_settings()
	settings.taa = true
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, settings) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	turned :: proc(yaw: f32) -> Camera {
		c := FIRST_PERSON
		c.forward = {-math.sin(yaw), 0, -math.cos(yaw)}
		return c
	}
	place :: proc(r: ^Renderer, s: ^Viewmodel_Scene, yaw: f32, step: Vec3) {
		s.bar.transform = held(Vec3{0.12, -0.12, -0.455} + step, {0.04, 0.04, 0.41}, yaw)
		s.mark.transform = held(MARK + step, {0.01, 0.01, 0.01}, yaw)
		scene_given(r, {s.floor, s.bar, s.mark}, nil, SUN, {})
	}
	// The share of a channel in the light of the pixels of a mask: at most and in the mean.
	share_of :: proc(t: ^testing.T, f: ^Fixture, mask: []bool, channel: int) -> (most: f32, mean: f32) {
		display := read_target(t, f, f.renderer.targets.display, f16, 4)
		count := 0
		for inside, i in mask {
			if !inside {continue}
			red, green, blue := f32(display[i * 4]), f32(display[i * 4 + 1]), f32(display[i * 4 + 2])
			share := f32(display[i * 4 + channel]) / max(red + green + blue, 1e-6)
			most, mean, count = max(most, share), mean + share, count + 1
		}
		return most, mean / f32(max(count, 1))
	}
	// The pixels of the red bar, or of the green mark on it.
	weapon_mask :: proc(t: ^testing.T, f: ^Fixture, mark := false) -> []bool {
		albedo := read_target(t, f, f.renderer.targets.albedo, u8, 4)
		mask := make([]bool, WIDTH * HEIGHT, context.temp_allocator)
		for &inside, i in mask {
			red, green := albedo[i * 4], albedo[i * 4 + 1]
			inside = green > 200 && red < 60 if mark else red > 200 && green < 60
		}
		return mask
	}
	place(r, &s, 0, {})
	draw(t, &f, turned(0), 16)
	for frame in 1 ..= 8 {
		yaw := f32(frame) * 0.04
		place(r, &s, yaw, {})
		draw(t, &f, turned(yaw), 1)
	}
	_, turning := share_of(t, &f, weapon_mask(t, &f, true), 1)
	draw(t, &f, turned(8 * 0.04), 16)
	_, still := share_of(t, &f, weapon_mask(t, &f, true), 1)
	testing.expectf(t, still > 0.5 && abs(turning - still) < 0.05, "the mark on the weapon held as the camera turns keeps its green: %.3f, %.3f held still there", turning, still)
	before := weapon_mask(t, &f)
	place(r, &s, 8 * 0.04, {0.06, 0.05, 0})
	draw(t, &f, turned(8 * 0.04), 1)
	moved := weapon_mask(t, &f)
	left := make([]bool, WIDTH * HEIGHT, context.temp_allocator)
	count := 0
	for &inside, i in left {
		inside = before[i] && !moved[i]
		if inside {count += 1}
	}
	most, _ := share_of(t, &f, left, 0)
	testing.expectf(t, count > 20 && most < 0.45, "where the weapon was the frame before shows the floor: a share of red of %.3f at most, over %d pixels", most, count)
	fmt.printfln("viewmodel history: green of the mark %.3f still, %.3f turning; red %.3f at most where the bar was, of %d pixels", still, turning, most, count)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The motion of the weapon at a pixel of the main view, pixels.
@(private = "file")
motion_at :: proc(t: ^testing.T, f: ^Fixture, at: int) -> Vec2 {
	motion := read_target(t, f, f.renderer.targets.motion, f16, 2)
	return Vec2{f32(motion[at * 2]), f32(motion[at * 2 + 1])} * Vec2{WIDTH, HEIGHT}
}

// What the weapon was drawn at the frame before follows a new origin, and a
// cut that takes the eye and the weapon 40 m away leaves none: neither moves
// the held weapon on the view.
@(test)
the_motion_of_the_viewmodel_stays_through_a_new_origin_and_a_cut :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	scene_given(r, {s.floor, s.bar, s.mark}, nil, SUN, {})
	draw(t, &f, FIRST_PERSON, 3)
	seen := weapon_seen(t, &f)
	if !testing.expectf(t, seen.marks > 0, "the mark is drawn") {return}
	renderer_origin_set(r, r.origin + {512, 0, 0})
	draw(t, &f, FIRST_PERSON, 1)
	rebased := motion_at(t, &f, seen.at)
	testing.expectf(t, abs(rebased.x) < 0.25 && abs(rebased.y) < 0.25, "a new origin leaves the weapon still: its motion %v", rebased)
	away := FIRST_PERSON
	away.position.x += 40
	moved := []^Instance_Desc{&s.floor, &s.bar, &s.mark}
	for inst in moved {inst.transform[0, 3] += 40}
	scene_given(r, {s.floor, s.bar, s.mark}, nil, SUN, {})
	testing.expect(t, renderer_frame(r, {camera = away, camera_cut = true}), r.error)
	cut := motion_at(t, &f, weapon_seen(t, &f).at)
	testing.expectf(t, abs(cut.x) < 0.25 && abs(cut.y) < 0.25, "a cut leaves the weapon still: its motion %v", cut)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The view of the window of the body draws its viewmodel, placed for its
// camera, though a view into a texture of the same body comes first; one of
// 0 degrees draws it where it is.
@(test)
the_viewmodel_is_of_the_view_of_the_window_and_one_of_no_field_of_view_is_where_it_is :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	s := viewmodel_scene(r)
	scene_given(r, {s.floor, s.bar, s.mark}, nil, SUN, {})
	image, made := view_texture_add(r, 32, 24, "another view of the body")
	if !testing.expect(t, made, r.error) {return}
	defer view_texture_remove(r, image)
	aside := FIRST_PERSON
	aside.forward = {1, 0, 0}
	views := []Frame_View{{camera = aside, texture = image, rect = {0, 0, 32, 24}}, {camera = FIRST_PERSON, rect = {0, 0, WIDTH, HEIGHT}}}
	for _ in 0 ..< 2 {testing.expect(t, renderer_frame(r, {camera = FIRST_PERSON, views = views}), r.error)}
	seen := weapon_seen(t, &f)
	own := project(MARK, VIEWMODEL_FOV)
	testing.expectf(t, seen.marks > 0 && abs(seen.mark.x - own.x) < 0.75 && abs(seen.mark.y - own.y) < 0.75, "the window draws the mark at %v, its projection of 55 degrees at %v", seen.mark, own)
	scene_set_viewmodels(r, {})
	draw(t, &f, FIRST_PERSON)
	plain := weapon_seen(t, &f)
	world := project(MARK, math.to_radians(f32(70)))
	testing.expectf(t, plain.marks > 0 && abs(plain.mark.x - world.x) < 0.75 && abs(plain.mark.y - world.y) < 0.75, "of 0 degrees the mark is at %v, where it is at %v", plain.mark, world)
	depths := read_target(t, &f, r.targets.linear_depth, f32, 1)
	testing.expectf(t, abs(depths[plain.at] - (-MARK.z - 0.005)) < 0.02, "and as far: %v", depths[plain.at])
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// A blended sight before the muzzle is drawn in the frame the camera turns
// with the weapon toward a wall a metre ahead.
@(test)
a_blended_sight_of_the_viewmodel_is_drawn_as_the_view_turns_to_a_wall :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_init(t, &f, WIDTH, HEIGHT, viewmodel_settings()) {return}
	defer fixture_destroy(&f)
	r := f.renderer
	blend := DEFAULT_MATERIAL
	blend.base_color, blend.alpha_mode, blend.opacity = {1, 0, 0}, .Blend, 0.8
	s := viewmodel_scene(r, blend)
	PANE :: Vec3{0.09, -0.09, -0.6}
	turned :: proc(yaw: f32) -> Camera {
		c := FIRST_PERSON
		c.forward = {-math.sin(yaw), 0, -math.cos(yaw)}
		return c
	}
	white := s.bar
	white.mesh = s.floor.mesh
	pane := s.mark
	pane.object_id, pane.material = 6, 4
	wall := s.wall
	// The wall a metre ahead of the eye turned by a quarter.
	wall.transform = held({1.025, 0, 0}, {0.05, 6, 6})
	place :: proc(r: ^Renderer, white, pane: ^Instance_Desc, floor, wall: Instance_Desc, yaw: f32) {
		white.transform = held({0.12, -0.12, -0.455}, {0.04, 0.04, 0.41}, yaw)
		pane.transform = held(PANE, {0.06, 0.06, 0.005}, yaw)
		scene_given(r, {floor, white^, pane^, wall}, nil, SUN, {sky = {1000, 1000, 1000}})
	}
	place(r, &white, &pane, s.floor, wall, 0)
	draw(t, &f, turned(0), 3)
	place(r, &white, &pane, s.floor, wall, -math.PI / 2)
	draw(t, &f, turned(-math.PI / 2), 1)
	at := project(PANE, VIEWMODEL_FOV)
	pixel := int(at.y) * WIDTH + int(at.x)
	display := read_target(t, &f, r.targets.display, f16, 4)
	red, green := f32(display[pixel * 4]), f32(display[pixel * 4 + 1])
	testing.expectf(t, red > green * 2, "the sight is drawn before the wall: red %v, green %v", red, green)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}
