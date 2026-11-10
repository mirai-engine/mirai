package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import stbi "vendor:stb/image"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// -define:GI_BENCHMARK=true, with --release and without validation: the GI
// scenes, each a sequence of frames 1/60 s apart, measured
// against the reference of their diffuse indirect light (Settings.reference_gi),
// both in nits.
// MIRAI_RT=software measures the software tracer. MIRAI_GI_REFERENCE=<folder>
// keeps the references there and takes them from it in the next run,
// MIRAI_GI_DUMP=<folder> writes images and the series of each case, and
// MIRAI_GI_CASES=<names separated by commas> runs those cases alone.
GI_BENCHMARK :: #config(GI_BENCHMARK, false)

// Inside a closed box whose walls glow 1 and reflect half of what reaches
// them, every direction brings 1 / (1 - 0.5) = 2: what the reference of the
// indirect light gives with each tracer, and what the composite shows of it.
// Walls whose program gives what a row gives (Grid with its lines the color
// of its cells) light the box as that row does: the paths wait for what the
// program gives where they meet them (points.odin).
@(test)
gi_reference_gives_the_light_of_a_white_furnace :: proc(t: ^testing.T) {
	for mode in ([2]Trace_Mode{.Software, .Hardware}) {
		settings := DEFAULT_SETTINGS
		settings.reflections, settings.taa, settings.reference_gi, settings.trace_mode = false, false, true, mode
		f: Fixture
		if !fixture_init(t, &f, 48, 48, settings) {return}
		defer fixture_destroy(&f)
		r, device := f.renderer, f.device
		if mode == .Hardware && !r.hardware_rt {continue}
		cube, added := gi_cube(r)
		if !testing.expect(t, added) {return}
		grid := program_find(r, "Grid", .Surface)
		if !testing.expect(t, grid != nil, "the engine has the Grid program") {return}
		// A metal of base color 0.5 reflects 0.5 as a diffuse reflector, whatever its dielectric layer.
		metal := DEFAULT_MATERIAL
		metal.base_color, metal.metallic = {0.5, 0.5, 0.5}, 1
		plain := DEFAULT_MATERIAL
		plain.base_color, plain.roughness = {0.5, 0.5, 0.5}, 0.7
		programmed := DEFAULT_MATERIAL
		programmed.program_id = grid.id
		programmed.custom_params = program_defaults(grid)
		for name in ([]string{"color", "line_color"}) {testing.expect(t, program_parameter_set(&programmed.custom_params, program_parameter(grid, name), {0.5, 0.5, 0.5, 0}))}
		testing.expect(t, program_parameter_set(&programmed.custom_params, program_parameter(grid, "roughness"), {0.7, 0, 0, 0}))
		materials_set(r, {metal, plain, programmed})
		camera := Camera{position = {0, 1.5, 1.5}, forward = {0.3, -0.3, -3.5}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 50}
		furnace :: proc(t: ^testing.T, r: ^Renderer, device: ^rhi.Device, cube: Mesh_Handle, camera: Camera, material: Material_Handle) -> (mean, shown_mean, worst: f32, ok: bool) {
			instances: [6]Instance_Desc
			walls := gi_room_walls({-2, 0, -2}, {2, 3, 2}, 0.2)
			for wall, i in walls {
				instances[i] = {object_id = u64(i + 1), mesh = cube, transform = wall, tint = {1, 1, 1}, emission = {1, 1, 1}, material = material}
			}
			scene_set(r, instances[:], nil, {}, {})
			for _ in 0 ..< 48 {testing.expect(t, renderer_frame(r, {camera = camera, inspection = {mode = .Indirect}}), r.error)}
			targets := &r.main.targets
			size := int(targets.width * targets.height)
			reference := make([]f32, size * 4, context.temp_allocator)
			if !testing.expect(t, golden_read_texture(device, targets.gi_reference, slice.to_bytes(reference))) {return}
			shown := make([]f16, size * 4, context.temp_allocator)
			if !testing.expect(t, golden_read_texture(device, targets.display, slice.to_bytes(shown))) {return}
			for i in 0 ..< size {
				mean += gi_luminance({reference[i * 4], reference[i * 4 + 1], reference[i * 4 + 2]}) / f32(size)
				shown_mean += gi_luminance({f32(shown[i * 4]), f32(shown[i * 4 + 1]), f32(shown[i * 4 + 2])}) / f32(size)
			}
			// Over 4x4 pixels: each is a mean of 192 paths.
			for y := 0; y + 4 <= int(targets.height); y += 4 {
				for x := 0; x + 4 <= int(targets.width); x += 4 {
					block: f32
					for dy in 0 ..< 4 {for dx in 0 ..< 4 {
						at := (y + dy) * int(targets.width) + x + dx
						block += gi_luminance({reference[at * 4], reference[at * 4 + 1], reference[at * 4 + 2]}) / 16
					}}
					worst = max(worst, abs(block - mean))
				}
			}
			return mean, shown_mean, worst, true
		}
		mean, shown_mean, worst, ok := furnace(t, r, device, cube, camera, 1)
		if !ok {return}
		testing.expectf(t, abs(mean - 2) < 0.03, "%v: the reference gives %.4f on average, not 2", mode, mean)
		testing.expectf(t, worst < 0.12, "%v: a block of 4x4 pixels of the reference is %.4f from its mean", mode, worst)
		testing.expectf(t, abs(shown_mean - 2) < 0.03, "%v: the debug view of the indirect light shows %.4f on average, not 2", mode, shown_mean)
		row, _, _, row_ok := furnace(t, r, device, cube, camera, 2)
		program, _, _, program_ok := furnace(t, r, device, cube, camera, 3)
		testing.expectf(t, row_ok && program_ok && abs(program - row) < 0.03, "%v: walls of the program give %.4f, the row %.4f", mode, program, row)
		testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation reported %d errors; last: %s", rhi.device_validation_errors(device), rhi.device_validation_message(device))
	}
}

// The mean of the indirect light of the view in nits, over what it sees, the
// frame `frames` frames after the last one drawn.
@(private = "file")
gi_mean_after :: proc(t: ^testing.T, f: ^Gi_Fixture, frames: int) -> f64 {
	r := f.r
	for _ in 0 ..< frames {
		testing.expect(t, renderer_frame(r, {camera = f.camera, time = r.time + 1.0 / 60, inspection = {mode = .Indirect}}), r.error)
		free_all(context.temp_allocator)
	}
	width, height := int(r.main.targets.width), int(r.main.targets.height)
	image := gi_image_make(width, height)
	defer gi_image_delete(image)
	texels := make([]f16, width * height * 4)
	defer delete(texels)
	depth := make([]f32, width * height)
	defer delete(depth)
	testing.expect(t, rhi.texture_read(f.device, r.main.targets.linear_depth, slice.to_bytes(depth)))
	testing.expect(t, gi_read_half(f, r.main.targets.display, image, texels))
	sum: f64
	count := 0
	for v, i in image.lum {if depth[i] != 0 {sum += f64(v); count += 1}}
	return sum / f64(max(count, 1))
}

// The indirect light of a sequence, as gi_measure draws it (Debug_View.Indirect).
@(private = "file")
gi_indirect_fixture :: proc(t: ^testing.T, f: ^Gi_Fixture) -> bool {
	if !gi_fixture_init(t, f, 320, 180, true) {return false}
	settings := f.r.settings
	settings.taa = false
	return testing.expect(t, renderer_apply_settings(f.r, settings))
}

// A light scale changes when the strongest light changes many times over: the
// histories are brought to its units, and none starts over. A light far away
// whose range reaches nothing of the room, 32 or 512 times the strongest,
// gives the scene a new scale and no light: the indirect light of the next
// frame, and of two seconds after, is the one that had settled. 512 times
// lost a fifth of it in two seconds while the cutoff of the lights not worth
// their shadow ray was in render units (light_cutoff).
@(test)
a_new_light_scale_keeps_the_indirect_light :: proc(t: ^testing.T) {
	f: Gi_Fixture
	defer gi_fixture_destroy(&f)
	if !gi_indirect_fixture(t, &f) {return}
	r := f.r
	for times in ([]f32{32, 512}) {
		gi_restart(r)
		gi_setup(&f, .Lamp)
		before := gi_mean_after(t, &f, 240)
		scale := r.scene.light_scale
		append(&f.lights, Light_Desc{position = {1000, 1000, 1000}, color = {1, 1, 1}, intensity = 9425 * times, range = 0.5, radius = 0.05})
		scene_set_lights(r, f.lights[:], f.sun, f.environment)
		after := gi_mean_after(t, &f, 1)
		later := gi_mean_after(t, &f, 120)
		testing.expectf(t, r.scene.light_scale != scale, "a light %v times the strongest leaves the light scale at %v", times, scale)
		testing.expectf(t, abs(after - before) < 0.03 * before, "a light %v times the strongest takes the indirect light from %.4g to %.4g nits", times, before, after)
		testing.expectf(t, abs(later - before) < 0.03 * before, "a light %v times the strongest takes the indirect light from %.4g to %.4g nits in 2 s", times, before, later)
	}
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// The frame that shows a world anew gathers its light at once (gi_warm): the
// indirect light it shows is near the one it settles at. A world shown again
// (scene_world) takes back the light it had: its first frame shows it.
@(test)
a_world_shows_its_light_from_its_first_frame :: proc(t: ^testing.T) {
	f: Gi_Fixture
	defer gi_fixture_destroy(&f)
	if !gi_indirect_fixture(t, &f) {return}
	r := f.r
	gi_restart(r)
	gi_setup(&f, .Interior)
	lamp_world := r.world_key
	first := gi_mean_after(t, &f, 1)
	settled := gi_mean_after(t, &f, 600)
	testing.expectf(t, abs(first - settled) < 0.03 * settled, "a world shown anew shows %.4g nits of indirect light in its first frame, %.4g once settled", first, settled)
	scene_world(r, lamp_world + 1)
	gi_setup(&f, .Emissive)
	_ = gi_mean_after(t, &f, 60)
	scene_world(r, lamp_world)
	gi_setup(&f, .Interior)
	again := gi_mean_after(t, &f, 1)
	testing.expectf(t, abs(again - settled) < 0.03 * settled, "the world shown again shows %.4g nits of indirect light, not the %.4g it had", again, settled)
	testing.expectf(t, rhi.device_validation_errors(f.device) == 0, "validation: %s", rhi.device_validation_message(f.device))
}

// ---------------------------------------------------------------- fixtures

@(private = "file")
gi_luminance :: proc "contextless" (c: Vec3) -> f32 {return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z}

// A unit cube centered at the origin.
@(private = "file")
gi_cube :: proc(r: ^Renderer) -> (Mesh_Handle, bool) {
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
	return mesh_add(r, vertices[:], indices[:])
}

// A sphere of diameter 1 centered at the origin.
@(private = "file")
gi_sphere :: proc(r: ^Renderer) -> (Mesh_Handle, bool) {
	RINGS :: 10
	SEGMENTS :: 20
	vertices: [(RINGS + 1) * (SEGMENTS + 1)]Mesh_Vertex
	indices: [RINGS * SEGMENTS * 6]u32
	for ring in 0 ..= RINGS {
		for segment in 0 ..= SEGMENTS {
			theta := f32(ring) / RINGS * math.PI
			phi := f32(segment) / SEGMENTS * 2 * math.PI
			n := Vec3{math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi)}
			vertices[ring * (SEGMENTS + 1) + segment] = {position = n * 0.5, normal = n, color = {1, 1, 1}}
		}
	}
	at := 0
	for ring in 0 ..< RINGS {
		for segment in 0 ..< SEGMENTS {
			a := u32(ring * (SEGMENTS + 1) + segment)
			b := a + SEGMENTS + 1
			for q in ([6]u32{a, a + 1, b, a + 1, b + 1, b}) {indices[at] = q; at += 1}
		}
	}
	return mesh_add(r, vertices[:], indices[:])
}

// A figure 1.75 m tall, standing on the origin, skinned to two joints: its
// lower half to the first and, above the waist at 0.9 m, its upper half to
// the second, which leans it.
@(private = "file")
BODY_WAIST :: f32(0.9)
@(private = "file")
gi_body :: proc(r: ^Renderer) -> (Mesh_Handle, bool) {
	ROWS :: 12
	HEIGHT :: f32(1.75)
	vertices := make([dynamic]Mesh_Vertex, context.temp_allocator)
	influences := make([dynamic]Skin_Influence, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	upper :: proc(y: f32) -> f32 {
		s := clamp((y - BODY_WAIST + 0.1) / 0.2, 0, 1)
		return s * s * (3 - 2 * s)
	}
	Side :: struct {n, u: Vec3, along, across: f32}
	sides := [4]Side{{{1, 0, 0}, {0, 0, 1}, 0.22, 0.15}, {{-1, 0, 0}, {0, 0, -1}, 0.22, 0.15}, {{0, 0, 1}, {-1, 0, 0}, 0.15, 0.22}, {{0, 0, -1}, {1, 0, 0}, 0.15, 0.22}}
	for side in sides {
		base := u32(len(vertices))
		for row in 0 ..= ROWS {
			y := HEIGHT * f32(row) / ROWS
			for across in 0 ..= 1 {
				p := side.n * side.along + side.u * (side.across * (f32(across) * 2 - 1))
				p.y = y
				append(&vertices, Mesh_Vertex{position = p, normal = side.n, color = {1, 1, 1}})
				w := upper(y)
				append(&influences, test_two_joints(w))
			}
		}
		for row in 0 ..< ROWS {
			a := base + u32(row * 2)
			append(&indices, a, a + 3, a + 1, a, a + 2, a + 3)
		}
	}
	for top in 0 ..< 2 {
		y := HEIGHT if top == 1 else 0
		base := u32(len(vertices))
		for corner in ([4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) {
			append(&vertices, Mesh_Vertex{position = {corner.x * 0.22, y, corner.y * 0.15}, normal = {0, 1 if top == 1 else -1, 0}, color = {1, 1, 1}})
			w := upper(y)
			append(&influences, test_two_joints(w))
		}
		if top == 1 {append(&indices, base, base + 2, base + 1, base, base + 3, base + 2)} else {append(&indices, base, base + 1, base + 2, base, base + 2, base + 3)}
	}
	source, origins, added := test_mesh_add(r, vertices[:], indices[:])
	if !added {return 0, false}
	return skin_create(r, source, test_by_cluster(origins, influences[:]), 2)
}

// The upper half of the figure leaned forward by `angle` radians about its waist.
@(private = "file")
gi_body_palette :: proc(angle: f32) -> [2]Mat4 {
	waist := Vec3{0, BODY_WAIST, 0}
	return {Mat4(1), linalg.matrix4_translate(waist) * linalg.matrix4_rotate(angle, Vec3{1, 0, 0}) * linalg.matrix4_translate(-waist)}
}

// The transform of a box from `low` to `high`, turned by `yaw` about its vertical axis.
@(private = "file")
gi_span :: proc(low, high: Vec3, yaw: f32 = 0) -> Mat4 {
	center, size := (low + high) * 0.5, high - low
	return linalg.matrix4_translate(center) * linalg.matrix4_rotate(yaw, Vec3{0, 1, 0}) * linalg.matrix4_scale(size)
}

// The six walls of a room whose inside spans `low` to `high`, `thick` thick:
// floor, ceiling, -x, +x, -z, +z.
@(private = "file")
gi_room_walls :: proc(low, high: Vec3, thick: f32) -> [6]Mat4 {
	e := Vec3{thick, thick, thick}
	return {
		gi_span({low.x - thick, low.y - thick, low.z - thick}, {high.x + thick, low.y, high.z + thick}),
		gi_span({low.x - thick, high.y, low.z - thick}, {high.x + thick, high.y + thick, high.z + thick}),
		gi_span({low.x - thick, low.y, low.z} - {0, 0, thick}, {low.x, high.y, high.z + thick}),
		gi_span({high.x, low.y, low.z - thick}, {high.x + thick, high.y, high.z} + {0, 0, thick}),
		gi_span({low.x, low.y, low.z - thick}, {high.x, high.y, low.z}),
		gi_span({low.x, low.y, high.z}, {high.x, high.y, high.z} + e * {0, 0, 1}),
	}
}

@(private = "file")
Gi_Kind :: enum {Interior, Interior_Day, Lamp, Flashlight, Box_Push, Character, Exterior, Many_Lights, Emissive, Thin_Wall, Shade, Shade_Night, Camera_Move, Pan, Horror_Sweep, Horror_Blackout, Horror_Flicker, Shadow_Push, Shadow_Drop}

// A case: a scene and how it changes over its sequence. Times in seconds;
// a negative one is none.
@(private = "file")
Gi_Case :: struct {
	kind:      Gi_Kind,
	name:      string,
	warmup:    f32, // drawn at the first pose before the sequence, unmeasured
	duration:  f32,
	still:     [2]f32, // nothing changes and the light has had time to settle
	changes:   [2]f32, // what changes then settles until the next change or the end; 0: the first frame
	keyframes: [3]f32, // frames compared with their reference; the one in `still` stands for the window
	focus:     [2]Vec3, // the box of the world whose mean light shows the changes settling; zero: the whole view
	pan:       f32, // Pan: pixels the view turns each frame, at the size of GI_PAN_SIZE and whatever the frame rate; gi_timed gives its times
	direct:    bool, // it measures the direct light with its shadows (Debug_View.Direct) against Settings.reference_lights in the same pose, not the indirect
}

// A pan: still for PAN_BEFORE seconds, turning PAN_SWEEP radians at the pixels
// a frame of its case, then still for PAN_AFTER seconds, in a fixture of the
// size of the viewport of the editor.
@(private = "file") GI_PAN_SIZE :: [2]u32{1600, 900}
@(private = "file") PAN_BEFORE :: f32(1)
@(private = "file") PAN_AFTER :: f32(6)
@(private = "file") PAN_SWEEP :: f32(1.05)

@(private = "file")
GI_CASES :: [?]Gi_Case{
	{kind = .Interior, name = "interior", duration = 16, still = {12, 16}, changes = {0, -1}, keyframes = {14, -1, -1}},
	{kind = .Interior_Day, name = "interior_day", duration = 16, still = {12, 16}, changes = {0, -1}, keyframes = {14, -1, -1}},
	{kind = .Lamp, name = "lamp", warmup = 10, duration = 18, still = {3, 5}, changes = {5, 10}, keyframes = {4.9, 5.5, 10.5}},
	{kind = .Flashlight, name = "flashlight", warmup = 10, duration = 16, still = {12, 16}, changes = {6, -1}, keyframes = {4, 6.5, 14}},
	{kind = .Box_Push, name = "box_push", warmup = 10, duration = 16, still = {12, 16}, changes = {5, -1}, keyframes = {4, 5.5, 14}, focus = {{0.5, 0, -2.2}, {3.5, 2.2, -0.4}}},
	{kind = .Character, name = "character", warmup = 10, duration = 16, still = {12, 16}, changes = {6, -1}, keyframes = {4, 6.5, 14}, focus = {{-0.5, 0, -3}, {3, 3, 1}}},
	{kind = .Exterior, name = "exterior", duration = 16, still = {12, 16}, changes = {0, -1}, keyframes = {14, -1, -1}},
	{kind = .Many_Lights, name = "many_lights", warmup = 10, duration = 16, still = {12, 16}, changes = {5, -1}, keyframes = {2.5, 5.5, 14}},
	{kind = .Emissive, name = "emissive", duration = 16, still = {12, 16}, changes = {0, -1}, keyframes = {14, -1, -1}},
	{kind = .Thin_Wall, name = "thin_wall", duration = 16, still = {12, 16}, changes = {0, -1}, keyframes = {14, -1, -1}},
	{kind = .Shade, name = "shade", duration = 30, still = {14, 30}, changes = {0, -1}, keyframes = {22, -1, -1}},
	{kind = .Shade_Night, name = "shade_night", duration = 30, still = {14, 30}, changes = {0, -1}, keyframes = {22, -1, -1}},
	{kind = .Camera_Move, name = "camera_move", warmup = 10, duration = 14, still = {10, 14}, changes = {5, -1}, keyframes = {3, 4.5, 12}},
	{kind = .Pan, name = "pan_2", warmup = 10, pan = 2},
	{kind = .Pan, name = "pan_8", warmup = 10, pan = 8},
	{kind = .Pan, name = "pan_16", warmup = 10, pan = 16},
	{kind = .Horror_Sweep, name = "horror_sweep", warmup = 10, duration = 8, still = {5, 8}, changes = {2.6, -1}, keyframes = {2.3, 3.0, 7}},
	{kind = .Horror_Blackout, name = "horror_blackout", warmup = 10, duration = 8, still = {5, 8}, changes = {3, -1}, keyframes = {2.5, 3.5, 7}},
	{kind = .Horror_Flicker, name = "horror_flicker", warmup = 10, duration = 8, still = {5, 8}, changes = {4, -1}, keyframes = {3.05, 3.15, 7}},
	{kind = .Shadow_Push, name = "shadow_push", warmup = 10, duration = 10, still = {8, 10}, changes = {SHADOW_PUSH_STOP, -1}, keyframes = {3.5, SHADOW_PUSH_STOP + 0.1, 9}, focus = {{-2.6, 0, -2.2}, {2.6, 1.2, 1.2}}, direct = true},
	{kind = .Shadow_Drop, name = "shadow_drop", warmup = 10, duration = 10, still = {8, 10}, changes = {SHADOW_DROP_LANDS, -1}, keyframes = {3.3, SHADOW_DROP_LANDS + 0.05, 9}, focus = {{-1.2, 0, -2.2}, {1.8, 1.2, 1.2}}, direct = true},
}

// Shadow_Push: a box slides 3 m across a sunlit floor beside a wall, from 3 s
// to SHADOW_PUSH_STOP. Shadow_Drop: the box falls SHADOW_DROP_HEIGHT metres
// from 3 s and lands at SHADOW_DROP_LANDS: its shadow on the floor closes
// into a contact one.
@(private = "file") SHADOW_PUSH_STOP :: f32(4)
@(private = "file") SHADOW_DROP_HEIGHT :: f32(1.2)
@(private = "file") SHADOW_DROP_LANDS :: f32(3.495) // 3 + sqrt(2 * SHADOW_DROP_HEIGHT / 9.81)
// Frames a reference of the direct light gathers: each traces every point of
// every light, turned at random by frame.
@(private = "file") GI_DIRECT_REFERENCE_FRAMES :: 64

// The horror house: a dark room under the moon through a window, two
// ceiling lights, a flashlight from the eye. Sweep: the house dark, the
// flashlight turns from one wall to the other at the pace of a mouse (100 degrees
// in 0.6 s). Blackout: the house lights and the flashlight go out at 3 s.
// Flicker: one ceiling light, alone, goes on and off five times a second
// between 2 s and 4 s, then stays on.
@(private = "file") HORROR_FLASHLIGHT :: 0
@(private = "file") HORROR_CEILING :: 1
@(private = "file")
horror_flashlight :: proc(yaw: f32) -> Light_Desc {
	return {position = {0.25, 1.45, 2.2}, color = {1, 0.97, 0.9}, intensity = 9425, range = 14, direction = {math.sin(yaw), -0.12, -math.cos(yaw)}, cone = 0.3, radius = 0.03}
}

// Radians a second a view of GI_PAN_SIZE turns at `pixels` a frame.
@(private = "file")
gi_pan_speed :: proc(f: ^Gi_Fixture, pixels: f32) -> f32 {
	return pixels * f.hz * 2 * math.tan(f.camera_fov * math.RAD_PER_DEG * 0.5) / f32(GI_PAN_SIZE.y)
}

// The times of a pan at the frame rate of the fixture: it turns as many
// pixels a frame at any rate, so it lasts longer at a lower one. The light
// settles after it stops; the reference is taken halfway and once settled.
@(private = "file")
gi_timed :: proc(f: ^Gi_Fixture, c: Gi_Case) -> Gi_Case {
	if c.pan <= 0 {return c}
	c := c
	f.pan_speed = gi_pan_speed(f, c.pan)
	turning := PAN_SWEEP / f.pan_speed
	c.duration = PAN_BEFORE + turning + PAN_AFTER
	c.changes = {-1, PAN_BEFORE + turning}
	c.still = {c.duration - 4, c.duration}
	c.keyframes = {PAN_BEFORE + turning * 0.5, c.duration - 2, -1}
	return c
}

@(private = "file")
Gi_Fixture :: struct {
	device:      ^rhi.Device,
	r:           ^Renderer, // on the heap: a Renderer is too big for the stack
	cube, sphere, body: Mesh_Handle,
	// What the case sets at its start, and what the renderer has now.
	base:        [dynamic]Instance_Desc,
	base_lights: [dynamic]Light_Desc,
	instances:   [dynamic]Instance_Desc,
	lights:      [dynamic]Light_Desc,
	palette:     [2]Mat4,
	sun:         Sun_Desc,
	environment: Environment,
	camera:      Camera,
	// What the changes asked of the CPU: scene_set_lights.
	light_ms:    f64,
	light_sets:  int,
	hz:          f32, // frames a second of the sequences (MIRAI_GI_HZ, 60)
	pan_speed:   f32, // radians a second the view of a pan turns (gi_timed)
	camera_fov:  f32, // of the view of a pan
}

// The settings of the renderer the sequences are drawn with: those of the
// device type, with what MIRAI_GI_SETTINGS changes, as name=value separated
// by commas.
@(private = "file")
gi_settings :: proc(t: ^testing.T, settings: Settings) -> (Settings, bool) {
	s := settings
	list, found := os.lookup_env("MIRAI_GI_SETTINGS", context.temp_allocator)
	if !found {return s, true}
	for pair in strings.split(list, ",", context.temp_allocator) {
		parts := strings.split(strings.trim_space(pair), "=", context.temp_allocator)
		if len(parts) != 2 {testing.expectf(t, false, "MIRAI_GI_SETTINGS: %q is not name=value", pair); return s, false}
		value, parsed := strconv.parse_f32(parts[1])
		if !parsed {testing.expectf(t, false, "MIRAI_GI_SETTINGS: %q is not a number", parts[1]); return s, false}
		switch parts[0] {
		case "probe_grid":           s.probe_grid = u32(value)
		case "probe_cascades":       s.probe_cascades = u32(value)
		case "probe_budget":         s.probe_budget = u32(value)
		case "probe_rays":           s.probe_rays = u32(value)
		case "probe_spacing":        s.probe_spacing = value
		case "light_budget":         s.light_budget = u32(value)
		case:
			testing.expectf(t, false, "MIRAI_GI_SETTINGS: %q is not a setting it changes", parts[0])
			return s, false
		}
	}
	return s, true
}

@(private = "file")
gi_fixture_init :: proc(t: ^testing.T, f: ^Gi_Fixture, width, height: u32, validation := false) -> bool {
	shared_device.hold(t)
	message: string
	f.device, message = rhi.device_create({app_name = "mirai gi benchmark", validation = validation, allow_hardware_ray_tracing = true, on_message = rhi.message_print if validation else nil, upload_bytes_per_frame = 16 << 20})
	if f.device == nil {
		if validation && rhi.gpu_skip_allowed() {return false}
		testing.expect(t, false, message)
		return false
	}
	f.r = new(Renderer)
	if !testing.expect(t, renderer_init(f.r, {device = f.device, width = width, height = height}), f.r.error) {return false}
	f.hz = 60
	f.camera_fov = 60
	if text, found := os.lookup_env("MIRAI_GI_HZ", context.temp_allocator); found {
		hz, parsed := strconv.parse_f32(text)
		if !testing.expectf(t, parsed && hz >= 10, "MIRAI_GI_HZ: %q is not a frame rate of 10 or more", text) {return false}
		f.hz = hz
	}
	settings, ok := gi_settings(t, f.r.settings)
	if !ok || !testing.expect(t, renderer_apply_settings(f.r, settings), "MIRAI_GI_SETTINGS: the renderer does not take them") {return false}
	ok1, ok2, ok3: bool
	f.cube, ok1 = gi_cube(f.r)
	f.sphere, ok2 = gi_sphere(f.r)
	f.body, ok3 = gi_body(f.r)
	return testing.expect(t, ok1 && ok2 && ok3, f.r.error)
}

@(private = "file")
gi_fixture_destroy :: proc(f: ^Gi_Fixture) {
	if f.device == nil {return}
	if f.r != nil {renderer_destroy(f.r); free(f.r)}
	rhi.device_destroy(f.device)
	delete(f.base); delete(f.base_lights); delete(f.instances); delete(f.lights)
}

@(private = "file")
gi_add :: proc(f: ^Gi_Fixture, mesh: Mesh_Handle, transform: Mat4, tint: Vec3, emission := Vec3{}) -> u32 {
	append(&f.base, Instance_Desc{object_id = u64(len(f.base) + 1), mesh = mesh, transform = transform, tint = tint, emission = emission})
	return u32(len(f.base) - 1)
}

@(private = "file")
gi_block :: proc(f: ^Gi_Fixture, low, high: Vec3, tint: Vec3, emission := Vec3{}, yaw: f32 = 0) -> u32 {
	return gi_add(f, f.cube, gi_span(low, high, yaw), tint, emission)
}

@(private = "file")
gi_room :: proc(f: ^Gi_Fixture, low, high: Vec3, tints: [6]Vec3) {
	for wall, i in gi_room_walls(low, high, 0.2) {gi_add(f, f.cube, wall, tints[i])}
}

// The instances of each case that move, light or change: the first ones it adds.
@(private = "file") GI_GLOBE :: u32(0)   // Lamp
@(private = "file") GI_MOVER :: u32(0)   // Box_Push, Character
@(private = "file") LIGHTS_MOVING :: 64 // Many_Lights

// Sets the scene of a case as it is at its start.
@(private = "file")
gi_setup :: proc(f: ^Gi_Fixture, kind: Gi_Kind) {
	clear(&f.base)
	clear(&f.base_lights)
	f.sun, f.environment, f.palette = {}, {}, gi_body_palette(0)
	white := Vec3{0.75, 0.75, 0.75}
	switch kind {
	case .Interior, .Interior_Day:
		// A closed room inside a sunlit yard, lit by a square light under its
		// ceiling: red and green walls to bleed, and walls 0.2 m thick between
		// the sun outside and the room.
		// Its top just below the floor of the room, which would hide it.
		gi_block(f, {-12, -0.4, -12}, {12, -0.01, 12}, {0.45, 0.45, 0.4})
		gi_room(f, {-2, 0, -2}, {2, 3, 2}, {white, white, {0.75, 0.08, 0.06}, {0.1, 0.6, 0.12}, white, white})
		gi_block(f, {-1.2, 0, -1.2}, {-0.2, 1.8, -0.2}, white, yaw = 0.3)
		gi_block(f, {0.35, 0, 0.05}, {1.25, 0.9, 0.95}, white, yaw = -0.3)
		append(&f.base_lights, Light_Desc{position = {0, 2.98, 0}, color = {1, 0.92, 0.8}, intensity = 314159, range = 12, direction = {0, -1, 0}, axis = {1, 0, 0}, size = {1, 1}})
		f.sun = {direction = {0.4, 0.8, 0.3}, color = {1, 0.95, 0.85}, illuminance = 94248, enabled = true}
		if kind == .Interior_Day {
			// As light really is: a room of some 450 lux next to a yard at noon.
			f.base_lights[0].intensity = 4000
			f.sun.illuminance = 100000
		}
		f.environment = {sky = {2500, 3500, 5500}}
		f.camera = {position = {0, 1.5, 1.85}, forward = {0, -0.3, -3.85}, up = {0, 1, 0}, fov_y = 65, near = 0.05, far = 100}
	case .Lamp, .Camera_Move:
		// A living room with a window the sun comes through and a lamp in a
		// corner, its globe glowing around its light.
		gi_add(f, f.sphere, linalg.matrix4_translate(Vec3{2.2, 1.6, -2.2}) * linalg.matrix4_scale(Vec3{0.25, 0.25, 0.25}), {1, 1, 1}, {6000, 4800, 3300})
		gi_block(f, {-15, -0.2, -15}, {15, 0, 15}, {0.4, 0.42, 0.35})
		gi_block(f, {-3.2, 0, -3.2}, {3.2, -0.01, 3.2} + {0, 0.02, 0}, {0.55, 0.42, 0.3})
		gi_block(f, {-3.2, 2.8, -3.2}, {3.2, 3.0, 3.2}, white)
		gi_block(f, {3.0, 0, -3.2}, {3.2, 2.8, 3.2}, {0.7, 0.68, 0.6})
		gi_block(f, {-3.0, 0, -3.2}, {3.0, 2.8, -3.0}, {0.7, 0.68, 0.6})
		gi_block(f, {-3.0, 0, 3.0}, {3.0, 2.8, 3.2}, {0.7, 0.68, 0.6})
		// The wall with the window: below, above and either side of it.
		gi_block(f, {-3.2, 0, -3.2}, {-3.0, 0.9, 3.2}, {0.7, 0.68, 0.6})
		gi_block(f, {-3.2, 2.1, -3.2}, {-3.0, 2.8, 3.2}, {0.7, 0.68, 0.6})
		gi_block(f, {-3.2, 0.9, -3.2}, {-3.0, 2.1, -0.75}, {0.7, 0.68, 0.6})
		gi_block(f, {-3.2, 0.9, 0.75}, {-3.0, 2.1, 3.2}, {0.7, 0.68, 0.6})
		gi_block(f, {-1.0, 0, -2.9}, {1.4, 0.8, -1.9}, {0.25, 0.3, 0.55})
		gi_block(f, {-0.6, 0, -0.4}, {0.6, 0.5, 0.6}, {0.5, 0.35, 0.2})
		append(&f.base_lights, Light_Desc{position = {2.2, 1.6, -2.2}, color = {1, 0.8, 0.55}, intensity = 9425, range = 12, radius = 0.08})
		f.sun = {direction = {-0.75, 0.45, 0.2}, color = {1, 0.95, 0.85}, illuminance = 9425, enabled = true}
		f.environment = {sky = {250, 350, 550}}
		f.camera = {position = {-2.4, 1.6, 2.6}, forward = {3.4, -0.6, -4.1}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100}
	case .Flashlight:
		// A closed corridor 20 m long, dark but for a dim light by the camera
		// and a flashlight carried away from it.
		gi_room(f, {-1, 0, -1}, {1, 2.5, 20}, {{0.4, 0.4, 0.4}, {0.65, 0.65, 0.6}, {0.7, 0.62, 0.5}, {0.7, 0.62, 0.5}, white, white})
		for i in 0 ..< 6 {
			z := 2 + f32(i) * 3
			x: f32 = -1 if i % 2 == 0 else 0.7
			gi_block(f, {x, 0, z}, {x + 0.3, 2.5, z + 0.4}, {0.6, 0.6, 0.6})
		}
		append(&f.base_lights, Light_Desc{position = {0.3, 1.4, 1}, color = {1, 0.97, 0.9}, intensity = 9425, range = 30, direction = {0, -0.15, 1}, cone = 0.35, radius = 0.03})
		append(&f.base_lights, Light_Desc{position = {0, 2.3, 0.5}, color = {1, 0.9, 0.8}, intensity = 157, range = 6, radius = 0.05})
		f.camera = {position = {0, 1.6, -0.5}, forward = {0, -0.4, 20.5}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100}
	case .Box_Push:
		// A red box pushed 4 m along a white wall in the sun.
		gi_block(f, {-2.5, 0, -1.7}, {-1.5, 1, -0.7}, {0.8, 0.12, 0.08})
		gi_block(f, {-10, -0.2, -10}, {10, 0, 10}, {0.45, 0.45, 0.42})
		gi_block(f, {-5, 0, -2.2}, {5, 3, -1.9}, {0.8, 0.8, 0.78})
		f.sun = {direction = {0.35, 0.7, 0.62}, color = {1, 0.95, 0.85}, illuminance = 94248, enabled = true}
		f.environment = {sky = {2500, 3500, 5500}}
		f.camera = {position = {0, 1.5, 4}, forward = {0, -0.7, -5.5}, up = {0, 1, 0}, fov_y = 65, near = 0.05, far = 100}
	case .Character:
		// A figure with a skin walks 5 m across a room lit from its ceiling,
		// through the probes of the volume.
		gi_add(f, f.body, linalg.matrix4_translate(Vec3{-2.5, 0, 0}), {0.2, 0.3, 0.75})
		gi_room(f, {-3, 0, -3}, {3, 3, 3}, {{0.5, 0.45, 0.4}, white, white, white, {0.7, 0.6, 0.45}, white})
		gi_block(f, {1.5, 0, -2.9}, {2.9, 0.9, -2.2}, {0.6, 0.6, 0.6})
		append(&f.base_lights, Light_Desc{position = {0, 2.98, 0}, color = {1, 0.95, 0.9}, intensity = 11170, range = 12, direction = {0, -1, 0}, axis = {1, 0, 0}, size = {1.5, 1.5}})
		f.camera = {position = {0, 1.6, 2.8}, forward = {0, -0.6, -3.8}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100}
	case .Exterior:
		// 200 m of streets between blocks, in the sun.
		gi_block(f, {-100, -0.2, -100}, {100, 0, 100}, {0.4, 0.4, 0.38})
		seed := u32(12345)
		for gx in -4 ..< 4 {
			for gz in -4 ..< 4 {
				if gx == -1 || gx == 0 {continue} // the street the camera looks along
				seed = seed * 1664525 + 1013904223
				height := 4 + f32(seed >> 24) / 255 * 20
				size := 8 + f32((seed >> 16) & 0xff) / 255 * 8
				x, z := f32(gx) * 25 + 12.5, f32(gz) * 25 + 12.5
				gi_block(f, {x - size / 2, 0, z - size / 2}, {x + size / 2, height, z + size / 2}, {0.55 + f32((seed >> 8) & 0x3f) / 255, 0.5, 0.45})
			}
		}
		f.sun = {direction = {0.5, 0.6, 0.3}, color = {1, 0.95, 0.85}, illuminance = 94248, enabled = true}
		f.environment = {sky = {3000, 4500, 7500}}
		f.camera = {position = {0, 1.7, 90}, forward = {2, 2.3, -90}, up = {0, 1, 0}, fov_y = 65, near = 0.1, far = 500}
	case .Many_Lights:
		// 64 small colored lights circling over a square between pillars.
		gi_block(f, {-15, -0.2, -15}, {15, 0, 15}, {0.5, 0.5, 0.5})
		for i in 0 ..< 9 {
			x, z := f32(i % 3) * 8 - 8, f32(i / 3) * 8 - 8
			gi_block(f, {x - 0.5, 0, z - 0.5}, {x + 0.5, 4, z + 0.5}, {0.7, 0.7, 0.7})
		}
		for i in 0 ..< LIGHTS_MOVING {
			hue := f32(i) / LIGHTS_MOVING * 6
			color := Vec3{clamp(abs(hue - 3) - 1, 0, 1), clamp(2 - abs(hue - 2), 0, 1), clamp(2 - abs(hue - 4), 0, 1)}
			append(&f.base_lights, Light_Desc{color = color, intensity = 471, range = 6, radius = 0.05})
		}
		f.environment = {sky = {2, 2, 3}}
		f.camera = {position = {0, 9, 16}, forward = {0, -9, -16}, up = {0, 1, 0}, fov_y = 65, near = 0.1, far = 100}
	case .Thin_Wall:
		// A hall 30 m long with walls 0.1 m thick in a sunlit yard, lit inside
		// only near the camera: its far end, dark, lies where the probe
		// cascades are cells far wider than a wall, so the sun they let through
		// shows as light where the reference has almost none.
		gi_block(f, {-20, -0.4, -10}, {20, -0.01, 45}, {0.45, 0.45, 0.4})
		for wall in gi_room_walls({-3, 0, 0}, {3, 4, 30}, 0.1) {gi_add(f, f.cube, wall, white)}
		gi_block(f, {-2.6, 0, 12}, {-1.8, 4, 12.8}, white)
		gi_block(f, {1.8, 0, 20}, {2.6, 4, 20.8}, white)
		append(&f.base_lights, Light_Desc{position = {0, 3.98, 2}, color = {1, 0.92, 0.8}, intensity = 4000, range = 12, direction = {0, -1, 0}, axis = {1, 0, 0}, size = {1, 1}})
		f.sun = {direction = {0.4, 0.8, 0.3}, color = {1, 0.95, 0.85}, illuminance = 100000, enabled = true}
		f.environment = {sky = {2500, 3500, 5500}}
		f.camera = {position = {0, 1.6, 1}, forward = {0, -0.2, 29}, up = {0, 1, 0}, fov_y = 65, near = 0.05, far = 100}
	case .Shadow_Push, .Shadow_Drop:
		// A red box on a floor beside a wall, under the sun and a small lamp
		// at its side: its shadows on the floor and the wall, sharp where it
		// touches and opening with the distance, move while the view stays.
		gi_block(f, {-0.4, 0, -0.4}, {0.4, 0.8, 0.4}, {0.75, 0.15, 0.1})
		gi_block(f, {-8, -0.2, -6}, {8, 0, 6}, {0.6, 0.6, 0.58})
		gi_block(f, {-8, 0, -2.4}, {8, 3, -2.2}, {0.75, 0.75, 0.72})
		append(&f.base_lights, Light_Desc{position = {1.6, 1.4, 0.9}, color = {1, 0.85, 0.65}, intensity = 2000, range = 10, radius = 0.1})
		f.sun = {direction = {0.45, 0.7, 0.55}, color = {1, 0.95, 0.85}, illuminance = 50000, enabled = true}
		f.environment = {sky = {1500, 2000, 3000}}
		f.camera = {position = {0, 2.4, 4.6}, forward = {0, -1.9, -5.4}, up = {0, 1, 0}, fov_y = 65, near = 0.05, far = 100}
	case .Emissive:
		// A closed room lit by a large glowing panel alone.
		gi_room(f, {-3, 0, -3}, {3, 3, 3}, {{0.5, 0.5, 0.5}, white, white, white, white, white})
		gi_block(f, {-1.5, 0.6, -3.0}, {1.5, 2.4, -2.96}, {0.8, 0.8, 0.8}, {400, 360, 300})
		gi_block(f, {-2.2, 0, -1.0}, {-1.2, 1.0, 0}, {0.7, 0.2, 0.15}, yaw = 0.4)
		gi_add(f, f.sphere, linalg.matrix4_translate(Vec3{1.2, 0.6, -0.6}) * linalg.matrix4_scale(Vec3{1.2, 1.2, 1.2}), {0.2, 0.5, 0.75})
		f.camera = {position = {0, 1.6, 2.6}, forward = {0, -0.4, -5.6}, up = {0, 1, 0}, fov_y = 70, near = 0.05, far = 100}
	case .Horror_Sweep, .Horror_Blackout, .Horror_Flicker:
		walls := Vec3{0.55, 0.52, 0.48}
		gi_block(f, {-6, -0.2, -6}, {6, 0, 6}, {0.35, 0.3, 0.26})
		gi_block(f, {-4.2, 2.8, -3.2}, {4.2, 3.0, 3.2}, walls)
		gi_block(f, {4, 0, -3}, {4.2, 2.8, 3}, {0.45, 0.5, 0.55})
		gi_block(f, {-4.2, 0, -3.2}, {4.2, 2.8, -3}, walls)
		gi_block(f, {-4.2, 0, 3}, {4.2, 2.8, 3.2}, walls)
		// The wall with the window: below, above and either side of it.
		gi_block(f, {-4.2, 0, -3}, {-4, 1.0, 3}, {0.5, 0.35, 0.3})
		gi_block(f, {-4.2, 2.0, -3}, {-4, 2.8, 3}, {0.5, 0.35, 0.3})
		gi_block(f, {-4.2, 1.0, -3}, {-4, 2.0, -0.6}, {0.5, 0.35, 0.3})
		gi_block(f, {-4.2, 1.0, 0.6}, {-4, 2.0, 3}, {0.5, 0.35, 0.3})
		gi_block(f, {-1.0, 0, -1.5}, {0.6, 0.8, -0.7}, {0.4, 0.25, 0.15})
		gi_block(f, {2.6, 0, -2.9}, {3.8, 2.1, -2.2}, {0.3, 0.2, 0.12})
		gi_block(f, {-3.8, 0, 1.6}, {-2.9, 0.5, 2.8}, {0.6, 0.6, 0.62})
		append(&f.base_lights, horror_flashlight(-0.87))
		append(&f.base_lights, Light_Desc{position = {-1.5, 2.6, 0}, color = {1, 0.85, 0.65}, intensity = 800, range = 10, radius = 0.05})
		append(&f.base_lights, Light_Desc{position = {2.0, 2.6, -1}, color = {1, 0.85, 0.65}, intensity = 800, range = 10, radius = 0.05})
		// The moon, low through the window, and a night sky.
		f.sun = {direction = {-0.8, 0.45, 0.2}, color = {0.75, 0.85, 1}, illuminance = 0.4, enabled = true}
		f.environment = {sky = {0.01, 0.014, 0.03}}
		f.camera = {position = {0, 1.6, 2.6}, forward = {0, -0.4, -3.6}, up = {0, 1, 0}, fov_y = 75, near = 0.05, far = 100}
	case .Shade, .Shade_Night, .Pan:
		// The entry hall of the demo's main scene: a room open above and in
		// front, under a dim sun and sky (at night, none), lit by a lamp 13 cm
		// under the shade that stands for it, whose underside the lamp makes a
		// small spot about a thousand times brighter than the walls. A pan
		// turns from inside it, from the red wall to the blue one.
		gi_block(f, {-5, -0.4, -5}, {5, 0, 5}, {0.9, 0.9, 0.9})
		gi_block(f, {-5.15, -0.2, -5}, {-4.85, 5.4, 5}, {0.82, 0.13, 0.12})
		gi_block(f, {4.85, -0.2, -5}, {5.15, 5.4, 5}, {0.12, 0.3, 0.85})
		gi_block(f, {-5, -0.2, -5.15}, {-2.65, 5.4, -4.85}, {0.65, 0.66, 0.7})
		gi_block(f, {-0.95, -0.2, -5.15}, {5, 5.4, -4.85}, {0.65, 0.66, 0.7})
		gi_block(f, {-2.65, 2.6, -5.15}, {-0.95, 5.4, -4.85}, {0.65, 0.66, 0.7})
		gi_block(f, {-2.75, 0, -4.83}, {-0.85, 2.7, -4.67}, {0.55, 0.38, 0.22})
		gi_block(f, {-1, 0, -1}, {1, 1.6, 1}, {0.92, 0.94, 0.97})
		gi_block(f, {0.5, 2.3, -0.5}, {1.5, 3.3, 0.5}, {0.08, 0.65, 0.5})
		gi_block(f, {-0.64, 1.51, -4.86}, {-0.46, 1.69, -4.74}, {0.9, 0.9, 0.9}, {47.7, 4, 2.4})
		gi_block(f, {-0.9, 3.83, -2.6}, {0.9, 3.97, -1.4}, {0.8, 0.8, 0.8}, {111.4, 92.3, 55.7})
		append(&f.base_lights, Light_Desc{position = {0, 3.7, -2}, color = {1, 0.82, 0.62}, intensity = 1500, range = 9, radius = 0.15})
		if kind != .Shade_Night {
			f.sun = {direction = {0.13, 0.99, -0.09}, color = {1, 0.95, 0.85}, illuminance = 50, enabled = true}
			f.environment = {sky = {8.75, 8.75, 8.75}}
		}
		f.camera = {position = {0, 3, 9}, forward = {0, -2, -9}, up = {0, 1, 0}, fov_y = 55, near = 0.05, far = 100}
		if kind == .Pan {f.camera = gi_pan_camera(f, 0)}
	}
	resize(&f.instances, len(f.base))
	copy(f.instances[:], f.base[:])
	resize(&f.lights, len(f.base_lights))
	copy(f.lights[:], f.base_lights[:])
	scene_set(f.r, f.instances[:], f.lights[:], f.sun, f.environment)
	skin_update(f.r, f.body, f.palette[:], true)
}

// The view of a pan, `turned` radians into its sweep.
@(private = "file")
gi_pan_camera :: proc(f: ^Gi_Fixture, turned: f32) -> Camera {
	yaw := turned - PAN_SWEEP * 0.5
	eye := Vec3{0, 1.7, 4}
	return {position = eye, forward = Vec3{math.sin(yaw), -0.12, -math.cos(yaw)}, up = {0, 1, 0}, fov_y = f.camera_fov, near = 0.05, far = 100}
}

// Brings the scene to what the case is at `at` seconds, changing in the
// renderer what differs from what it has, as the engine does: moves, glow,
// poses and the set of lights.
@(private = "file")
gi_pose :: proc(f: ^Gi_Fixture, kind: Gi_Kind, at: f32) {
	want := slice.clone(f.base[:], context.temp_allocator)
	lights := make([dynamic]Light_Desc, 0, len(f.base_lights), context.temp_allocator)
	append(&lights, ..f.base_lights[:])
	palette := gi_body_palette(0)
	share :: proc(at, from, to: f32) -> f32 {return clamp((at - from) / (to - from), 0, 1)}
	switch kind {
	case .Interior, .Interior_Day, .Exterior, .Emissive, .Thin_Wall, .Shade, .Shade_Night:
	case .Lamp:
		if at >= 5 && at < 10 {
			clear(&lights)
			want[GI_GLOBE].emission = {}
		}
	case .Flashlight:
		lights[0].position.z = 1 + 12 * share(at, 2, 6)
		if at > 2 && at < 6 {lights[0].position.y += 0.04 * math.sin(at * 9)}
	case .Box_Push:
		want[GI_MOVER].transform = linalg.matrix4_translate(Vec3{4 * share(at, 3, 5), 0, 0}) * f.base[GI_MOVER].transform
	case .Shadow_Push:
		want[GI_MOVER].transform = linalg.matrix4_translate(Vec3{3 * share(at, 3, SHADOW_PUSH_STOP) - 1.5, 0, 0}) * f.base[GI_MOVER].transform
	case .Shadow_Drop:
		fallen := clamp(at - 3, 0, SHADOW_DROP_LANDS - 3)
		want[GI_MOVER].transform = linalg.matrix4_translate(Vec3{0, max(SHADOW_DROP_HEIGHT - 4.905 * fallen * fallen, 0), 0}) * f.base[GI_MOVER].transform
	case .Character:
		walked := share(at, 2, 6)
		want[GI_MOVER].transform = linalg.matrix4_translate(Vec3{5 * walked, 0, 0}) * f.base[GI_MOVER].transform
		if walked > 0 && walked < 1 {palette = gi_body_palette(0.3 * math.sin((at - 2) * 2 * math.PI * 1.2))}
	case .Camera_Move:
		// Across the living room, turning, at walking pace.
		s := share(at, 2, 5)
		f.camera.position = linalg.lerp(Vec3{-2.4, 1.6, 2.6}, Vec3{1.6, 1.4, 2.2}, s)
		f.camera.forward = linalg.lerp(Vec3{1.0, 1.0, -1.5}, Vec3{-1.8, 1.0, -1.8}, s) - f.camera.position
	case .Pan:
		f.camera = gi_pan_camera(f, clamp((at - PAN_BEFORE) * f.pan_speed, 0, PAN_SWEEP))
	case .Horror_Sweep:
		// The house dark; the flashlight from the left wall to the right one.
		lights[HORROR_FLASHLIGHT] = horror_flashlight(-0.87 + 1.74 * share(at, 2, 2.6))
		resize(&lights, 1)
	case .Horror_Blackout:
		if at >= 3 {clear(&lights)}
	case .Horror_Flicker:
		on := at < 2 || at >= 4 || math.mod(at - 2, 0.2) < 0.1
		ceiling := lights[HORROR_CEILING]
		clear(&lights)
		if on {append(&lights, ceiling)}
	case .Many_Lights:
		moving := clamp(at, 0, 5)
		for &light, i in lights {
			center := Vec3{f32(i % 8) * 3.5 - 12.25, 0, f32(i / 8) * 3.5 - 12.25}
			angle := f32(i) * 2.4 + moving * (0.6 + 0.1 * f32(i % 5))
			light.position = center + Vec3{1.5 * math.cos(angle), 0.5 + 0.2 * f32(i % 3), 1.5 * math.sin(angle)}
		}
	}
	moved := make([dynamic]u32, context.temp_allocator)
	transforms := make([dynamic]Mat4, context.temp_allocator)
	tinted := make([dynamic]u32, context.temp_allocator)
	tints := make([dynamic]Vec3, context.temp_allocator)
	emissions := make([dynamic]Vec3, context.temp_allocator)
	for instance, i in want {
		if instance.transform != f.instances[i].transform {append(&moved, u32(i)); append(&transforms, instance.transform)}
		if instance.emission != f.instances[i].emission {append(&tinted, u32(i)); append(&tints, instance.tint); append(&emissions, instance.emission)}
		f.instances[i] = instance
	}
	if len(moved) > 0 {scene_move(f.r, moved[:], transforms[:])}
	if len(tinted) > 0 {scene_tint(f.r, tinted[:], tints[:], emissions[:])}
	if !slice.equal(lights[:], f.lights[:]) {
		resize(&f.lights, len(lights))
		copy(f.lights[:], lights[:])
		started := time.tick_now()
		scene_set_lights(f.r, f.lights[:], f.sun, f.environment)
		f.light_ms += time.duration_milliseconds(time.tick_since(started))
		f.light_sets += 1
	}
	if palette != f.palette {
		f.palette = palette
		skin_update(f.r, f.body, f.palette[:])
	}
}

// ---------------------------------------------------------------- measures

@(private = "file")
Gi_Image :: struct {
	width, height: int,
	rgb:           []Vec3,
	lum:           []f32,
}

@(private = "file")
gi_image_make :: proc(width, height: int) -> Gi_Image {
	return {width, height, make([]Vec3, width * height), make([]f32, width * height)}
}

@(private = "file")
gi_image_delete :: proc(image: Gi_Image) {delete(image.rgb); delete(image.lum)}

@(private = "file")
gi_read_half :: proc(f: ^Gi_Fixture, texture: rhi.Texture, out: Gi_Image, texels: []f16) -> bool {
	if !rhi.texture_read(f.device, texture, slice.to_bytes(texels)) {return false}
	nits := gi_nits(f.r)
	for i in 0 ..< len(out.lum) {
		c := Vec3{f32(texels[i * 4]), f32(texels[i * 4 + 1]), f32(texels[i * 4 + 2])} * nits
		out.rgb[i], out.lum[i] = c, gi_luminance(c)
	}
	return true
}

// The reference of the indirect light of the case at `at`, or of its direct
// light (Gi_Case.direct), from the folder of MIRAI_GI_REFERENCE when it holds
// one of as many frames.
@(private = "file")
gi_reference :: proc(t: ^testing.T, f: ^Gi_Fixture, c: Gi_Case, at: f32, frames: int, out: Gi_Image) -> bool {
	frames := GI_DIRECT_REFERENCE_FRAMES if c.direct else frames
	// The frames free the temporary allocator: these live in the test's.
	folder, keep := os.lookup_env("MIRAI_GI_REFERENCE", context.allocator)
	defer delete(folder)
	path := fmt.aprintf("%s/%s-%.2f-%dx%d-%d.bin", folder, c.name, at, out.width, out.height, frames)
	defer delete(path)
	if keep {
		if bytes, error := os.read_entire_file(path, context.temp_allocator); error == nil && len(bytes) == len(out.rgb) * size_of(Vec3) {
			copy(slice.to_bytes(out.rgb), bytes)
			for value, i in out.rgb {out.lum[i] = gi_luminance(value)}
			return true
		}
	}
	r := f.r
	before := r.settings
	settings := before
	if c.direct {
		settings.reference_lights, settings.taa = true, false
	} else {
		settings.reference_gi, settings.taa, settings.gi_enabled = true, false, true
	}
	if !testing.expect(t, renderer_apply_settings(r, settings)) {return false}
	gi_restart(r)
	gi_setup(f, c.kind)
	gi_pose(f, c.kind, at)
	started := time.tick_now()
	// The direct light is the mean of the frames, each with every point of
	// every light turned another way; the indirect, what the renderer gathers.
	texels := make([]f16, len(out.rgb) * 4)
	defer delete(texels)
	frame := gi_image_make(out.width, out.height)
	defer gi_image_delete(frame)
	for &v in out.rgb {v = {}}
	for i in 0 ..< frames {
		if !renderer_frame(r, {camera = f.camera, camera_cut = i == 0, time = at, inspection = {mode = .Direct if c.direct else .Indirect}}) {
			failure, text := rhi.device_failure(f.device)
			testing.expectf(t, false, "the reference of %s at %.2f s stops at frame %d of %d: %s %v %s", c.name, at, i, frames, r.error, failure, text)
			return false
		}
		free_all(context.temp_allocator)
		if !c.direct {continue}
		if !testing.expect(t, gi_read_half(f, r.main.targets.display, frame, texels)) {return false}
		for v, p in frame.rgb {out.rgb[p] += v / f32(frames)}
	}
	if !c.direct {
		gathered := make([]f32, len(out.rgb) * 4)
		defer delete(gathered)
		if !testing.expect(t, rhi.texture_read(f.device, r.main.targets.gi_reference, slice.to_bytes(gathered))) {return false}
		nits := gi_nits(r)
		for &v, i in out.rgb {v = Vec3{gathered[i * 4], gathered[i * 4 + 1], gathered[i * 4 + 2]} * nits}
	}
	for v, i in out.rgb {out.lum[i] = gi_luminance(v)}
	fmt.printfln("  reference %s at %.2f s: %d frames, %.1f s", c.name, at, frames, time.duration_seconds(time.tick_since(started)))
	if keep {
		os.make_directory_all(folder)
		testing.expect(t, os.write_entire_file(path, slice.to_bytes(out.rgb)) == nil, path)
	}
	return testing.expect(t, renderer_apply_settings(r, before))
}

// How far an image is from its reference, over blocks of 2x2 pixels where
// both see geometry: the mean relative error of their luminance (against at
// least 5 % of the mean of the reference), SSIM of both tone mapped at the
// exposure of the mean of the reference, the error of the mean, and the
// light in excess over the darkest tenth of the reference (leaks), as a share
// of its mean.
@(private = "file")
Gi_Error :: struct {relative, ssim, bias, leak: f64}

@(private = "file")
gi_compare :: proc(image, reference: []f32, mask: []bool, width, height: int) -> (e: Gi_Error) {
	w, h := width / 2, height / 2
	a := make([]f32, w * h, context.temp_allocator)
	b := make([]f32, w * h, context.temp_allocator)
	inside := make([]bool, w * h, context.temp_allocator)
	sum_a, sum_b: f64
	count := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			all := true
			va, vb: f32
			for d in ([4][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
				at := (y * 2 + d.y) * width + x * 2 + d.x
				all &&= mask[at]
				va += image[at] / 4
				vb += reference[at] / 4
			}
			a[y * w + x], b[y * w + x], inside[y * w + x] = va, vb, all
			if all {sum_a += f64(va); sum_b += f64(vb); count += 1}
		}
	}
	if count == 0 || sum_b <= 0 {return}
	mean := sum_b / f64(count)
	e.bias = (sum_a - sum_b) / sum_b
	floor := 0.05 * mean
	darkest := make([dynamic]f32, 0, count, context.temp_allocator)
	for v, i in b {
		if !inside[i] {continue}
		e.relative += abs(f64(a[i]) - f64(v)) / max(f64(v), floor)
		append(&darkest, v)
	}
	e.relative /= f64(count)
	slice.sort(darkest[:])
	dark := darkest[len(darkest) / 10]
	dark_count := 0
	for v, i in b {
		if !inside[i] || v > dark {continue}
		e.leak += max(f64(a[i]) - f64(v), 0)
		dark_count += 1
	}
	if dark_count > 0 {e.leak /= f64(dark_count) * mean}
	tone :: proc(v: f32, mean: f64) -> f64 {x := f64(v) / mean; return x / (1 + x)}
	C1 :: 0.01 * 0.01
	C2 :: 0.03 * 0.03
	windows := 0
	for y := 0; y + 8 <= h; y += 4 {
		for x := 0; x + 8 <= w; x += 4 {
			ma, mb, aa, bb, ab: f64
			all := true
			for dy in 0 ..< 8 {for dx in 0 ..< 8 {
				i := (y + dy) * w + x + dx
				all &&= inside[i]
				ta, tb := tone(a[i], mean), tone(b[i], mean)
				ma += ta; mb += tb; aa += ta * ta; bb += tb * tb; ab += ta * tb
			}}
			if !all {continue}
			ma /= 64; mb /= 64
			va, vb, cov := aa / 64 - ma * ma, bb / 64 - mb * mb, ab / 64 - ma * mb
			e.ssim += ((2 * ma * mb + C1) * (2 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2))
			windows += 1
		}
	}
	if windows > 0 {e.ssim /= f64(windows)}
	return
}

// Statistics of the frames of a still window, pixel by pixel.
@(private = "file")
Gi_Still :: struct {
	frames:              int,
	sum, sum2, change:   []f64,
	previous:            []f32,
	block_sum, block_sum2: []f64, // of the means of blocks of 8x8 pixels
	fireflies:           int,
	error:               Gi_Error,
}

@(private = "file")
gi_still_make :: proc(size, blocks: int) -> Gi_Still {
	return {sum = make([]f64, size), sum2 = make([]f64, size), change = make([]f64, size), previous = make([]f32, size), block_sum = make([]f64, blocks), block_sum2 = make([]f64, blocks)}
}

@(private = "file")
gi_still_delete :: proc(s: Gi_Still) {
	delete(s.sum); delete(s.sum2); delete(s.change); delete(s.previous); delete(s.block_sum); delete(s.block_sum2)
}

// A frame of a still window. reference: nil for the image of the window,
// which has none. A firefly is a pixel more than four times as bright as
// the reference around it, of the pixels of 2x2 that see geometry (and at
// least 5 % of its mean).
@(private = "file")
gi_still_add :: proc(s: ^Gi_Still, image: []f32, reference: []f32, mask: []bool, width, height: int) {
	for v, i in image {
		if !mask[i] {continue}
		s.sum[i] += f64(v)
		s.sum2[i] += f64(v) * f64(v)
		if s.frames > 0 {s.change[i] += abs(f64(v) - f64(s.previous[i]))}
		s.previous[i] = v
	}
	bw := width / 8
	for by in 0 ..< height / 8 {
		for bx in 0 ..< bw {
			mean: f64
			for dy in 0 ..< 8 {for dx in 0 ..< 8 {mean += f64(image[(by * 8 + dy) * width + bx * 8 + dx]) / 64}}
			s.block_sum[by * bw + bx] += mean
			s.block_sum2[by * bw + bx] += mean * mean
		}
	}
	if reference != nil {
		mean: f64
		count := 0
		for v, i in reference {if mask[i] {mean += f64(v); count += 1}}
		mean /= f64(max(count, 1))
		for y in 0 ..< height - 1 {
			for x in 0 ..< width - 1 {
				i := y * width + x
				if !mask[i] {continue}
				around, inside: f64
				for o in ([4]int{0, 1, width, width + 1}) {if mask[i + o] {around += f64(reference[i + o]); inside += 1}}
				if f64(image[i]) > 4 * max(around / inside, 0.05 * mean) {s.fireflies += 1}
			}
		}
		e := gi_compare(image, reference, mask, width, height)
		s.error.relative += e.relative
		s.error.ssim += e.ssim
		s.error.bias += e.bias
		s.error.leak += e.leak
	}
	s.frames += 1
}

// Noise: the deviation of each pixel over the window against its mean;
// boiling: the same of the means of blocks of 8x8 pixels; flicker: the mean
// change from a frame to the next against the mean. Means over the pixels
// whose mean is at least 5 % of the mean of the image.
@(private = "file")
gi_still_result :: proc(s: Gi_Still, mask: []bool) -> (noise, boil, flicker, fireflies: f64, error: Gi_Error) {
	n := f64(s.frames)
	total: f64
	count := 0
	for v, i in s.sum {if mask[i] {total += v / n; count += 1}}
	floor := 0.05 * total / f64(max(count, 1))
	used := 0
	for v, i in s.sum {
		if !mask[i] {continue}
		mean := v / n
		if mean < floor {continue}
		noise += math.sqrt(max(s.sum2[i] / n - mean * mean, 0)) / mean
		flicker += s.change[i] / (n - 1) / mean
		used += 1
	}
	noise /= f64(max(used, 1))
	flicker /= f64(max(used, 1))
	blocks := 0
	for v, i in s.block_sum {
		mean := v / n
		if mean < floor {continue}
		boil += math.sqrt(max(s.block_sum2[i] / n - mean * mean, 0)) / mean
		blocks += 1
	}
	boil /= f64(max(blocks, 1))
	fireflies = f64(s.fireflies) / (n * f64(max(count, 1))) * 1e6
	error = {s.error.relative / n, s.error.ssim / n, s.error.bias / n, s.error.leak / n}
	return
}

// Blotches: how the mean of the still window departs from its reference from
// one place to the next at the scale of a few blocks, without the even
// bias. Over blocks of 4x4 pixels that see geometry and get at least 5 % of
// the mean light, where the reference of the 5x5 blocks around them changes by
// less than 20 % (a smooth surface, away from edges, corners and contacts), the
// deviation of the ratio of the two from its mean over the 9x9 blocks around.
@(private = "file")
gi_blotches :: proc(s: Gi_Still, reference: []f32, mask: []bool, width, height: int) -> f64 {
	B :: 4
	R :: 4
	w, h := width / B, height / B
	ratio := make([]f64, w * h, context.temp_allocator)
	valid := make([]bool, w * h, context.temp_allocator)
	total: f64
	count := 0
	for v, i in reference {if mask[i] {total += f64(v); count += 1}}
	floor := 0.05 * total / f64(max(count, 1))
	for by in 0 ..< h {
		for bx in 0 ..< w {
			a, b: f64
			all := true
			for dy in 0 ..< B {for dx in 0 ..< B {
				i := (by * B + dy) * width + bx * B + dx
				all &&= mask[i]
				a += s.sum[i] / f64(s.frames)
				b += f64(reference[i])
			}}
			b /= B * B
			if !all || b < floor {continue}
			ratio[by * w + bx], valid[by * w + bx] = a / (B * B) / b, true
		}
	}
	smooth := make([]bool, w * h, context.temp_allocator)
	for by in 2 ..< h - 2 {
		for bx in 2 ..< w - 2 {
			low, high := max(f64), f64(0)
			all := true
			for y in by - 2 ..= by + 2 {for x in bx - 2 ..= bx + 2 {
				all &&= valid[y * w + x]
				b: f64
				for dy in 0 ..< B {for dx in 0 ..< B {b += f64(reference[(y * B + dy) * width + x * B + dx])}}
				low, high = min(low, b), max(high, b)
			}}
			smooth[by * w + bx] = all && high < 1.2 * low
		}
	}
	sum2: f64
	used := 0
	for by in 0 ..< h {
		for bx in 0 ..< w {
			if !smooth[by * w + bx] {continue}
			around: f64
			n := 0
			for y in max(by - R, 0) ..= min(by + R, h - 1) {for x in max(bx - R, 0) ..= min(bx + R, w - 1) {
				if valid[y * w + x] {around += ratio[y * w + x]; n += 1}
			}}
			d := ratio[by * w + bx] - around / f64(n)
			sum2 += d * d
			used += 1
		}
	}
	return math.sqrt(sum2 / f64(max(used, 1)))
}

// What changed of the points a turning view saw in the frame before too, on
// the same surface: the sum over those pixels of how far their light moved
// from what the frame before shows there (bilinear), and of their light. The
// world stands still, so what moves is noise that crawls with the screen.
@(private = "file")
gi_reprojected :: proc(image, before, depth, depth_before: []f32, camera, camera_before: Camera, width, height: int) -> (change, light: f64) {
	aspect := f32(width) / f32(height)
	view, proj, forward := camera_matrices(camera, aspect)
	inverse := linalg.inverse(proj * view)
	view_before, proj_before, forward_before := camera_matrices(camera_before, aspect)
	to_before := proj_before * view_before
	for y in 0 ..< height {
		for x in 0 ..< width {
			p := y * width + x
			if depth[p] == 0 {continue}
			u, v := (f32(x) + 0.5) / f32(width) * 2 - 1, 1 - (f32(y) + 0.5) / f32(height) * 2
			near := inverse * Vec4{u, v, 1, 1}
			far := inverse * Vec4{u, v, 0.5, 1}
			direction := linalg.normalize(far.xyz / far.w - near.xyz / near.w)
			point := camera.position + direction * (depth[p] / linalg.dot(direction, forward))
			clip := to_before * Vec4{point.x, point.y, point.z, 1}
			if clip.w <= 0 {continue}
			at := Vec2{(clip.x / clip.w * 0.5 + 0.5) * f32(width) - 0.5, (0.5 - clip.y / clip.w * 0.5) * f32(height) - 0.5}
			x0, y0 := int(math.floor(at.x)), int(math.floor(at.y))
			if x0 < 0 || y0 < 0 || x0 + 1 >= width || y0 + 1 >= height {continue}
			expected := linalg.dot(point - camera_before.position, forward_before)
			fx, fy := f64(at.x) - f64(x0), f64(at.y) - f64(y0)
			value: f64
			same := true
			for corner in ([4][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
				q := (y0 + corner.y) * width + x0 + corner.x
				same &&= depth_before[q] != 0 && abs(depth_before[q] - expected) <= 0.02 * expected
				value += f64(before[q]) * (fx if corner.x == 1 else 1 - fx) * (fy if corner.y == 1 else 1 - fy)
			}
			if !same {continue}
			change += abs(f64(image[p]) - value)
			light += f64(image[p])
		}
	}
	return
}

// Blocks of GI_BLOCK pixels on a side whose light the settling follows.
@(private = "file")
GI_BLOCK :: 8

// How long after a change the light of the blocks of the focus stays near
// where it settles. The distance of a frame is the sum over the blocks of how
// far each is from its mean over the last second before the next change,
// against the sum of those means; the step is the distance at the change,
// which in a cold start (a change at the first frame) depends on what the
// first frames happen to trace: there the times are against all the light.
//
// The noise of the blocks stays alike for a while (the correlation: the lag
// at which the correlation of their deviations over the last three seconds
// falls under 1/e), so frames near the last second are near its mean and
// their distance is not that of a settled frame. The distance is taken as its
// median over a quarter of a second, so that a few frames alone do not count.
// The floor and the spread are the median of that and its median deviation
// from halfway after the change to twice the correlation (at least a second)
// before the last second: a pulse of light of a few seconds moves neither.
// The times, in ms, are those after which it stays within 10 % and 1 % of the
// step over the floor, or within three spreads of it; -1 when it does not get
// there in the time it has; -3 when the step is not twice the floor: the
// change is within the noise.
//
// tail90, tail99: the same with the floor and its deviation over the last
// second itself and the distance of each frame, within two deviations: the
// times the tables before this measure gave.
@(private = "file")
Gi_Settle :: struct {
	t90, t99, tail90, tail99: f64,
	step, floor, correlation: f64, // correlation in seconds
}

@(private = "file")
gi_settle :: proc(blocks: []f32, count: int, valid: []bool, from, to: int, hz: f32, dump_name: string) -> (s: Gi_Settle) {
	s = {t90 = -1, t99 = -1, tail90 = -1, tail99 = -1}
	tail := int(hz)
	if to - from <= tail * 2 {return}
	settled := make([]f64, count, context.temp_allocator)
	for k in to - tail ..< to {for b in 0 ..< count {settled[b] += f64(blocks[k * count + b]) / f64(tail)}}
	total: f64
	for b in 0 ..< count {if valid[b] {total += settled[b]}}
	if total <= 0 {return}
	distance := make([]f64, to, context.temp_allocator)
	for k in from ..< to {
		for b in 0 ..< count {if valid[b] {distance[k] += abs(f64(blocks[k * count + b]) - settled[b])}}
		distance[k] /= total
	}
	s.step = distance[from]
	last_above :: proc(distance: []f64, from, to: int, limit: f64) -> int {
		last := from - 1
		for k in from ..< to {if distance[k] > limit {last = k}}
		return last
	}
	time_of :: proc(last, from, end: int, hz: f32) -> f64 {return -1 if last >= end - 1 else f64(last + 1 - from) * 1000 / f64(hz)}
	{
		floor, spread: f64
		for d in distance[to - tail:to] {floor += d / f64(tail)}
		for d in distance[to - tail:to] {spread += (d - floor) * (d - floor) / f64(tail)}
		spread = math.sqrt(spread)
		s.tail90 = time_of(last_above(distance, from, to - tail, floor + max(0.1 * (s.step - floor), 2 * spread)), from, to - tail, hz)
		s.tail99 = time_of(last_above(distance, from, to - tail, floor + max(0.01 * (s.step - floor), 2 * spread)), from, to - tail, hz)
	}
	// The correlation of the deviations of the blocks from their mean over the
	// last three seconds, or the second half of the window if it is shorter.
	start := max(from + (to - from) / 2, to - 3 * tail)
	mean := make([]f64, count, context.temp_allocator)
	for k in start ..< to {for b in 0 ..< count {mean[b] += f64(blocks[k * count + b]) / f64(to - start)}}
	lag := 0
	{
		alike :: proc(blocks: []f32, mean: []f64, valid: []bool, count, start, to, j: int) -> f64 {
			sum: f64
			for k in start ..< to - j {
				for b in 0 ..< count {
					if valid[b] {sum += (f64(blocks[k * count + b]) - mean[b]) * (f64(blocks[(k + j) * count + b]) - mean[b])}
				}
			}
			return sum / f64(to - j - start)
		}
		zero := alike(blocks, mean, valid, count, start, to, 0)
		for lag < (to - start) / 2 && zero > 0 && alike(blocks, mean, valid, count, start, to, lag + 1) > zero / math.E {lag += 1}
		lag += 1
	}
	s.correlation = f64(lag) / f64(hz)
	median := make([]f64, to, context.temp_allocator)
	{
		half := int(hz) / 8
		window := make([]f64, half * 2 + 1, context.temp_allocator)
		for k in from ..< to {
			a, b := max(k - half, from), min(k + half + 1, to)
			copy(window, distance[a:b])
			slice.sort(window[:b - a])
			median[k] = window[(b - a) / 2]
		}
	}
	begin, end := from + (to - from) / 2, to - tail - max(tail, 2 * lag)
	if end - begin < tail / 4 {end = to - tail}
	// The median and the median deviation (as the deviation of a normal
	// distribution), which a few seconds of a pulse of light do not move.
	window := make([]f64, end - begin, context.temp_allocator)
	copy(window, median[begin:end])
	slice.sort(window)
	s.floor = window[len(window) / 2]
	for &d in window {d = abs(d - s.floor)}
	slice.sort(window)
	spread := 1.4826 * window[len(window) / 2]
	// A cold start comes from no light: all of it is the step.
	step := 1.0 if from == 0 else s.step
	if step < 2 * s.floor {
		s.t90, s.t99 = -3, -3
	} else {
		s.t90 = time_of(last_above(median, from, to - tail, s.floor + max(0.1 * (step - s.floor), 3 * spread)), from, to - tail, hz)
		s.t99 = time_of(last_above(median, from, to - tail, s.floor + max(0.01 * (step - s.floor), 3 * spread)), from, to - tail, hz)
	}
	if folder, found := os.lookup_env("MIRAI_GI_DUMP", context.temp_allocator); found {
		builder := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&builder, "# step %.6f floor %.6f spread %.6f correlation %.3f s, floor from %.2f s to %.2f s\nseconds,distance,median\n", s.step, s.floor, spread, s.correlation, f64(begin - from) / f64(hz), f64(end - from) / f64(hz))
		for k in from ..< to {fmt.sbprintf(&builder, "%.4f,%.6f,%.6f\n", f64(k - from) / f64(hz), distance[k], median[k])}
		_ = os.write_entire_file(fmt.tprintf("%s/%s-settle.csv", folder, dump_name), transmute([]u8)strings.to_string(builder))
	}
	return
}

@(private = "file")
gi_dump :: proc(name: string, image: []f32, width, height: int, scale: f32) {
	folder, found := os.lookup_env("MIRAI_GI_DUMP", context.temp_allocator)
	if !found {return}
	os.make_directory_all(folder)
	pixels := make([]u8, width * height, context.temp_allocator)
	for v, i in image {
		x := v * scale
		pixels[i] = u8(clamp(math.pow(x / (1 + x), 1 / 2.2) * 255, 0, 255))
	}
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s.png", folder, name), context.temp_allocator)
	stbi.write_png(path, i32(width), i32(height), 1, raw_data(pixels), i32(width))
}

@(private = "file")
gi_dump_rgb :: proc(name: string, image: []Vec3, width, height: int, scale: f32) {
	folder, found := os.lookup_env("MIRAI_GI_DUMP", context.temp_allocator)
	if !found {return}
	os.make_directory_all(folder)
	pixels := make([]u8, width * height * 3, context.temp_allocator)
	for v, i in image {
		for k in 0 ..< 3 {
			x := v[k] * scale
			pixels[i * 3 + k] = u8(clamp(math.pow(x / (1 + x), 1 / 2.2) * 255, 0, 255))
		}
	}
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s.png", folder, name), context.temp_allocator)
	stbi.write_png(path, i32(width), i32(height), 3, raw_data(pixels), i32(width * 3))
}

// What a case measures of the indirect light and of the image.
@(private = "file")
Gi_Result :: struct {
	noise, boil, flicker, fireflies: f64,
	blotches:                        f64, // of the mean of the still window against its reference (gi_blotches)
	error:                           Gi_Error, // of the still window
	moving:                          [3]Gi_Error, // at the keyframes outside it
	settle:                          [2]Gi_Settle, // of each change
	image_noise, image_flicker:      f64, // of the image after TAA and tone mapping
	pan_flicker:                     f64, // Pan: the change of each point seen in two frames in a row while the view turns, against the mean (gi_reprojected)
	passes:                          [16]struct {name: string, ms: f64},
	pass_count:                      int,
	gpu_ms, cpu_ms, light_ms:        f64,
	probes:                          u32,
	traced:                          f64, // probes traced, a frame
	gpu_peak:                        f64, // the GPU of the slowest frame, ms
}

@(private = "file")
gi_frame_of :: proc(f: ^Gi_Fixture, at: f32) -> int {return int(math.round(at * f.hz))}

// Draws the frame `i` of a case that begins with c.warmup seconds at its
// first pose: false when the frame failed. at: the time of the sequence.
@(private = "file")
gi_step :: proc(t: ^testing.T, f: ^Gi_Fixture, c: Gi_Case, i: int, mode := Debug_View.None) -> (at: f32, ok: bool) {
	at = f32(i) / f.hz - c.warmup
	gi_pose(f, c.kind, max(at, 0))
	ok = testing.expect(t, renderer_frame(f.r, {camera = f.camera, camera_cut = i == 0, time = f32(i) / f.hz, inspection = {mode = mode}}), f.r.error)
	free_all(context.temp_allocator)
	return
}

// The sequence of a case with the settings of the renderer, its indirect
// light against the references of its keyframes.
@(private = "file")
gi_measure :: proc(t: ^testing.T, f: ^Gi_Fixture, c: Gi_Case, references: []Gi_Image, result: ^Gi_Result) -> bool {
	r := f.r
	width, height := int(r.main.targets.width), int(r.main.targets.height)
	settings := r.settings
	settings.taa = false
	if !testing.expect(t, renderer_apply_settings(r, settings)) {return false}
	gi_restart(r)
	gi_setup(f, c.kind)
	warm, frames := gi_frame_of(f, c.warmup), gi_frame_of(f, c.duration)
	image := gi_image_make(width, height)
	defer gi_image_delete(image)
	texels := make([]f16, width * height * 4)
	defer delete(texels)
	depth := make([]f32, width * height)
	defer delete(depth)
	mask := make([]bool, width * height)
	defer delete(mask)
	focus := make([]bool, width * height)
	defer delete(focus)
	bw, bh := width / GI_BLOCK, height / GI_BLOCK
	blocks := make([]f32, frames * bw * bh)
	defer delete(blocks)
	valid := make([]bool, bw * bh)
	defer delete(valid)
	still := gi_still_make(width * height, bw * bh)
	defer gi_still_delete(still)
	before := make([]f32, width * height)
	defer delete(before)
	depth_before := make([]f32, width * height)
	defer delete(depth_before)
	camera_before: Camera
	pan_change, pan_light: f64
	c := c
	window, moving := gi_window(c)
	c.still = window
	still_reference := -1
	for k in 0 ..< 3 {
		if !moving && c.keyframes[k] >= c.still[0] && c.keyframes[k] < c.still[1] {still_reference = k}
	}
	for i in 0 ..< warm + frames {
		at, ok := gi_step(t, f, c, i, .Direct if c.direct else .Indirect)
		if !ok {return false}
		if i < warm {continue}
		k := i - warm
		if !testing.expect(t, rhi.texture_read(f.device, r.main.targets.linear_depth, slice.to_bytes(depth))) {return false}
		for d, p in depth {mask[p] = d != 0}
		if !testing.expect(t, gi_read_half(f, r.main.targets.display, image, texels)) {return false}
		for by in 0 ..< bh {
			for bx in 0 ..< bw {
				sum: f32
				for dy in 0 ..< GI_BLOCK {for dx in 0 ..< GI_BLOCK {sum += image.lum[(by * GI_BLOCK + dy) * width + bx * GI_BLOCK + dx]}}
				blocks[k * bw * bh + by * bw + bx] = sum / (GI_BLOCK * GI_BLOCK)
			}
		}
		if at >= c.still[0] && at < c.still[1] {
			gi_still_add(&still, image.lum, references[still_reference].lum if still_reference >= 0 else nil, mask, width, height)
		}
		// While it turns.
		if c.pan > 0 && k > 0 && at > PAN_BEFORE && at <= c.changes[1] {
			change, light := gi_reprojected(image.lum, before, depth, depth_before, f.camera, camera_before, width, height)
			pan_change += change
			pan_light += light
		}
		copy(before, image.lum)
		copy(depth_before, depth)
		camera_before = f.camera
		for key in 0 ..< 3 {
			if c.keyframes[key] < 0 || gi_frame_of(f, c.keyframes[key]) != k {continue}
			result.moving[key] = gi_compare(image.lum, references[key].lum, mask, width, height)
			mean: f32
			count := 0
			for v, p in references[key].lum {if mask[p] {mean += v; count += 1}}
			scale := f32(count) / max(mean, 1e-6) * 0.5
			gi_dump_rgb(fmt.tprintf("%s-%.2f-reference", c.name, c.keyframes[key]), references[key].rgb, width, height, scale)
			gi_dump_rgb(fmt.tprintf("%s-%.2f-approximation", c.name, c.keyframes[key]), image.rgb, width, height, scale)
		}
	}
	// The blocks of the focus, as the view settles: mostly geometry at the end.
	view, proj, _ := camera_matrices(f.camera, f32(width) / f32(height))
	inverse := linalg.inverse(proj * view)
	forward := linalg.normalize(f.camera.forward)
	for &inside, p in focus {
		inside = mask[p]
		if !inside || c.focus[0] == c.focus[1] {continue}
		x, y := p % width, p / width
		u, v := (f32(x) + 0.5) / f32(width) * 2 - 1, 1 - (f32(y) + 0.5) / f32(height) * 2
		near := inverse * Vec4{u, v, 1, 1}
		far := inverse * Vec4{u, v, 0.5, 1}
		direction := linalg.normalize(far.xyz / far.w - near.xyz / near.w)
		point := f.camera.position + direction * (depth[p] / linalg.dot(direction, forward))
		inside = point.x >= c.focus[0].x && point.y >= c.focus[0].y && point.z >= c.focus[0].z && point.x <= c.focus[1].x && point.y <= c.focus[1].y && point.z <= c.focus[1].z
	}
	for by in 0 ..< bh {
		for bx in 0 ..< bw {
			inside := 0
			for dy in 0 ..< GI_BLOCK {for dx in 0 ..< GI_BLOCK {if focus[(by * GI_BLOCK + dy) * width + bx * GI_BLOCK + dx] {inside += 1}}}
			valid[by * bw + bx] = inside * 4 >= GI_BLOCK * GI_BLOCK * 3
		}
	}
	result.noise, result.boil, result.flicker, result.fireflies, result.error = gi_still_result(still, mask)
	if pan_light > 0 {result.pan_flicker = pan_change / pan_light}
	if still_reference >= 0 {result.blotches = gi_blotches(still, references[still_reference].lum, mask, width, height)}
	for change, k in c.changes {
		if change < 0 {result.settle[k] = {t90 = -2, t99 = -2, tail90 = -2, tail99 = -2}; continue}
		to := frames
		if k == 0 && c.changes[1] >= 0 {to = gi_frame_of(f, c.changes[1])}
		result.settle[k] = gi_settle(blocks, bw * bh, valid, gi_frame_of(f, change), to, f.hz, fmt.tprintf("%s-%d", c.name, k))
	}
	if folder, found := os.lookup_env("MIRAI_GI_DUMP", context.temp_allocator); found {
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, "frame,seconds,focus\n")
		for k in 0 ..< frames {
			sum: f64
			count := 0
			for b in 0 ..< bw * bh {if valid[b] {sum += f64(blocks[k * bw * bh + b]); count += 1}}
			fmt.sbprintf(&builder, "%d,%.4f,%.6f\n", k, f32(k) / f.hz, sum / f64(max(count, 1)))
		}
		_ = os.write_entire_file(fmt.tprintf("%s/%s-series.csv", folder, c.name), transmute([]u8)strings.to_string(builder))
		deviation := make([]f32, width * height, context.temp_allocator)
		for v, i in still.sum {
			n := f64(still.frames)
			deviation[i] = f32(math.sqrt(max(still.sum2[i] / n - (v / n) * (v / n), 0)))
		}
		gi_dump(fmt.tprintf("%s-deviation", c.name), deviation, width, height, 4)
		focus_image := make([]f32, width * height, context.temp_allocator)
		for b in 0 ..< bw * bh {
			if !valid[b] {continue}
			for dy in 0 ..< GI_BLOCK {for dx in 0 ..< GI_BLOCK {focus_image[((b / bw) * GI_BLOCK + dy) * width + (b % bw) * GI_BLOCK + dx] = 1}}
		}
		gi_dump(fmt.tprintf("%s-focus", c.name), focus_image, width, height, 1)
	}
	return true
}

// The same sequence as the window shows it: after TAA and tone mapping, its
// still window. Luma of the bytes of the image, against at least 0.02.
@(private = "file")
gi_measure_image :: proc(t: ^testing.T, f: ^Gi_Fixture, c: Gi_Case, result: ^Gi_Result) -> bool {
	c := c
	c.still, _ = gi_window(c)
	r := f.r
	settings := r.settings
	settings.taa = true
	if !testing.expect(t, renderer_apply_settings(r, settings)) {return false}
	gi_restart(r)
	gi_setup(f, c.kind)
	width, height := int(r.main.targets.output_width), int(r.main.targets.output_height)
	bytes := make([]u8, width * height * 4)
	defer delete(bytes)
	sum := make([]f64, width * height)
	defer delete(sum)
	sum2 := make([]f64, width * height)
	defer delete(sum2)
	change := make([]f64, width * height)
	defer delete(change)
	previous := make([]f64, width * height)
	defer delete(previous)
	n := 0
	for i in 0 ..< gi_frame_of(f, c.warmup) + gi_frame_of(f, c.still[1]) {
		at, ok := gi_step(t, f, c, i)
		if !ok {return false}
		if at < c.still[0] {continue}
		if !testing.expect(t, rhi.texture_read(f.device, r.main.targets.ldr, bytes)) {return false}
		for p in 0 ..< width * height {
			y := (0.2126 * f64(bytes[p * 4]) + 0.7152 * f64(bytes[p * 4 + 1]) + 0.0722 * f64(bytes[p * 4 + 2])) / 255
			sum[p] += y
			sum2[p] += y * y
			if n > 0 {change[p] += abs(y - previous[p])}
			previous[p] = y
		}
		n += 1
	}
	for p in 0 ..< width * height {
		mean := max(sum[p] / f64(n), 0.02)
		result.image_noise += math.sqrt(max(sum2[p] / f64(n) - (sum[p] / f64(n)) * (sum[p] / f64(n)), 0)) / mean
		result.image_flicker += change[p] / f64(n - 1) / mean
	}
	result.image_noise /= f64(width * height)
	result.image_flicker /= f64(width * height)
	return true
}

// GPU time of each pass and CPU time of the frame over the sequence, as a
// game draws it.
@(private = "file")
gi_measure_cost :: proc(t: ^testing.T, f: ^Gi_Fixture, c: Gi_Case, result: ^Gi_Result) -> bool {
	r := f.r
	gi_restart(r)
	gi_setup(f, c.kind)
	// The device writes the timestamps of each pass only while asked to.
	rhi.timestamps_want(f.device, true)
	defer rhi.timestamps_want(f.device, false)
	warm := gi_frame_of(f, c.warmup)
	measured := 0
	for i in 0 ..< warm + gi_frame_of(f, c.duration) {
		if i == warm {f.light_ms, f.light_sets = 0, 0}
		if _, ok := gi_step(t, f, c, i); !ok {return false}
		if i < warm + 30 {continue}
		stats := renderer_stats(r)
		result.cpu_ms += f64(stats.cpu_prepare_ms + stats.cpu_record_ms)
		frame_gpu: f64
		for timing in stats.timings {if timing.name != "end" {frame_gpu += f64(timing.ms)}}
		result.gpu_peak = max(result.gpu_peak, frame_gpu)
		result.traced += f64(stats.probes_traced)
		for timing in stats.timings {
			if timing.name == "end" {continue}
			result.gpu_ms += f64(timing.ms)
			found := false
			for &pass in result.passes[:result.pass_count] {if pass.name == timing.name {pass.ms += f64(timing.ms); found = true; break}}
			if !found && result.pass_count < len(result.passes) {result.passes[result.pass_count] = {timing.name, f64(timing.ms)}; result.pass_count += 1}
		}
		measured += 1
	}
	rhi.device_wait_idle(f.device)
	result.gpu_ms /= f64(measured)
	result.cpu_ms /= f64(measured)
	result.traced /= f64(measured)
	result.light_ms = f.light_ms / f64(max(measured, 1))
	for &pass in result.passes[:result.pass_count] {pass.ms /= f64(measured)}
	result.probes = renderer_stats(r).probes
	return true
}

gi_case_wanted :: proc(name: string) -> bool {
	list, found := os.lookup_env("MIRAI_GI_CASES", context.temp_allocator)
	if !found || list == "" {return true}
	for wanted in strings.split(list, ",", context.temp_allocator) {if strings.trim_space(wanted) == name {return true}}
	return false
}

@(private = "file")
gi_ms :: proc(v: f64) -> string {
	switch {
	case v == -2: return "—"
	case v == -3: return "ruido"
	case v < 0:   return "no"
	}
	return fmt.tprintf("%.0f", v)
}

@(test)
gi_benchmark_reports_noise_error_settling_and_cost :: proc(t: ^testing.T) {
	when !GI_BENCHMARK {return} else {
		WIDTH :: 640
		HEIGHT :: 360
		reference_frames := 512
		if text, found := os.lookup_env("MIRAI_GI_REFERENCE_FRAMES", context.temp_allocator); found {
			for ch in text {if ch < '0' || ch > '9' {reference_frames = -1}}
			if reference_frames >= 0 {
				reference_frames = 0
				for ch in text {reference_frames = reference_frames * 10 + int(ch - '0')}
			}
			reference_frames = max(reference_frames, 1)
		}
		f: Gi_Fixture
		defer gi_fixture_destroy(&f)
		if !gi_fixture_init(t, &f, WIDTH, HEIGHT) {return}
		cost: Gi_Fixture
		defer gi_fixture_destroy(&cost)
		if !gi_fixture_init(t, &cost, 1280, 720) {return}
		// The pans, at the size of the viewport of the editor: made when one is wanted.
		pan: Gi_Fixture
		defer gi_fixture_destroy(&pan)
		changed, _ := os.lookup_env("MIRAI_GI_SETTINGS", context.temp_allocator)
		fmt.printfln("device: %s, hardware rt: %v, %dx%d (pans %dx%d) at %.0f Hz, settings changed: %q, references of %d frames of %d paths", rhi.device_info(f.device).name, f.r.hardware_rt, WIDTH, HEIGHT, GI_PAN_SIZE.x, GI_PAN_SIZE.y, f.hz, changed, reference_frames, GI_REFERENCE_PATHS)
		results: [len(GI_CASES)]Gi_Result
		ran: [len(GI_CASES)]bool
		cases := GI_CASES
		for &c, index in cases {
			if !gi_case_wanted(c.name) {continue}
			fixture := &f
			if c.pan > 0 {
				if pan.device == nil && !gi_fixture_init(t, &pan, GI_PAN_SIZE.x, GI_PAN_SIZE.y) {return}
				fixture = &pan
				_ = gi_timed(&cost, c)
				c = gi_timed(&pan, c)
			}
			width, height := int(fixture.r.main.targets.width), int(fixture.r.main.targets.height)
			if width == 0 {width, height = int(fixture.r.window_width), int(fixture.r.window_height)}
			references: [3]Gi_Image
			for k in 0 ..< 3 {
				references[k] = gi_image_make(width, height)
				if c.keyframes[k] >= 0 && !gi_reference(t, fixture, c, c.keyframes[k], reference_frames, references[k]) {return}
			}
			defer for image in references {gi_image_delete(image)}
			result := &results[index]
			started := time.tick_now()
			if !gi_measure(t, fixture, c, references[:], result) || !gi_measure_image(t, fixture, c, result) || !gi_measure_cost(t, &cost, c, result) {return}
			ran[index] = true
			fmt.printfln("  %s measured in %.1f s", c.name, time.duration_seconds(time.tick_since(started)))
		}
		fmt.println()
		fmt.println("| Scene | Noise | Boil | Flicker | Fireflies/Mpx | Rel. error | SSIM | Bias | Leak | Image noise | Image flicker | Blotches |")
		fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
		for c, i in cases {
			if !ran[i] {continue}
			e := results[i]
			fmt.printfln("| %s | %.1f %% | %.1f %% | %.1f %% | %.0f | %.1f %% | %.3f | %+.1f %% | %.1f %% | %.2f %% | %.2f %% | %.2f %% |", c.name, e.noise * 100, e.boil * 100, e.flicker * 100, e.fireflies, e.error.relative * 100, e.error.ssim, e.error.bias * 100, e.error.leak * 100, e.image_noise * 100, e.image_flicker * 100, e.blotches * 100)
		}
		fmt.println()
		fmt.println("| Scene | Time | Rel. error | SSIM | Bias | Leak |")
		fmt.println("| --- | --- | --- | --- | --- | --- |")
		for c, i in cases {
			if !ran[i] {continue}
			for k in 0 ..< 3 {
				if c.keyframes[k] < 0 {continue}
				e := results[i].moving[k]
				fmt.printfln("| %s | %.2f s | %.1f %% | %.3f | %+.1f %% | %.1f %% |", c.name, c.keyframes[k], e.relative * 100, e.ssim, e.bias * 100, e.leak * 100)
			}
		}
		fmt.println()
		fmt.println("| Scene | Change | Step | Floor | Correlation (s) | 90 % (ms) | 99 % (ms) | 90 % with the tail (ms) | 99 % with the tail (ms) |")
		fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
		for c, i in cases {
			if !ran[i] {continue}
			for k in 0 ..< 2 {
				if c.changes[k] < 0 {continue}
				s := results[i].settle[k]
				fmt.printfln("| %s | %.1f s | %.1f %% | %.2f %% | %.2f | %s | %s | %s | %s |", c.name, c.changes[k], s.step * 100, s.floor * 100, s.correlation, gi_ms(s.t90), gi_ms(s.t99), gi_ms(s.tail90), gi_ms(s.tail99))
			}
		}
		fmt.println()
		fmt.println("| Pan | Hz | px/frame | °/s | Reprojected flicker | Rel. error midway | SSIM midway | Bias midway | 90 % on stop (ms) | 99 % on stop (ms) |")
		fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
		for c, i in cases {
			if !ran[i] || c.pan <= 0 {continue}
			e := results[i]
			fmt.printfln("| %s | %.0f | %.0f | %.0f | %.2f %% | %.1f %% | %.3f | %+.1f %% | %s | %s |", c.name, pan.hz, c.pan, gi_pan_speed(&pan, c.pan) * math.DEG_PER_RAD, e.pan_flicker * 100, e.moving[0].relative * 100, e.moving[0].ssim, e.moving[0].bias * 100, gi_ms(e.settle[1].t90), gi_ms(e.settle[1].t99))
		}
		fmt.println()
		fmt.println("| Scene | ddgi | contact | GPU total | CPU frame | CPU lights | Probes | Traced |")
		fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- |")
		for c, i in cases {
			if !ran[i] {continue}
			e := results[i]
			pass :: proc(e: Gi_Result, name: string) -> f64 {
				passes := e.passes
				for p in passes[:e.pass_count] {if p.name == name {return p.ms}}
				return 0
			}
			fmt.printfln("| %s | %.3f | %.3f | %.3f | %.3f | %.3f | %d | %.0f |", c.name, pass(e, "ddgi"), pass(e, "contact"), e.gpu_ms, e.cpu_ms, e.light_ms, e.probes, e.traced)
		}
		fmt.println("\n| Scene | Mean GPU | GPU of the slowest frame |")
		fmt.println("| --- | --- | --- |")
		for c, i in cases {
			if !ran[i] {continue}
			e := results[i]
			fmt.printfln("| %s | %.3f | %.3f |", c.name, e.gpu_ms, e.gpu_peak)
		}
		// The CPU of a change of one light among many: scene_set_lights builds the tree again.
		fmt.println("\n| Lights | scene_set_lights when moving one (ms) |")
		fmt.println("| --- | --- |")
		for count in ([3]int{64, 1024, 4096}) {
			lights := make([]Light_Desc, count)
			defer delete(lights)
			for &light, i in lights {light = {position = {f32(i % 64) - 32, 1, f32(i / 64) - 32}, color = {1, 1, 1}, intensity = 100, range = 4, radius = 0.05}}
			scene_set_lights(f.r, lights, {}, {})
			started := time.tick_now()
			for _ in 0 ..< 20 {
				lights[0].position.x += 0.01
				scene_set_lights(f.r, lights, {}, {})
			}
			fmt.printfln("| %d | %.3f |", count, time.duration_milliseconds(time.tick_since(started)) / 20)
		}
		// The BVH of a mesh of 200 000 triangles, built and kept whatever traces the rays.
		GRID :: 316
		vertices := make([]Mesh_Vertex, (GRID + 1) * (GRID + 1))
		defer delete(vertices)
		indices := make([]u32, GRID * GRID * 6)
		defer delete(indices)
		for &vertex, i in vertices {
			x, z := f32(i % (GRID + 1)) / GRID, f32(i / (GRID + 1)) / GRID
			vertex = {position = {x * 10, 0.2 * math.sin(x * 40) * math.cos(z * 30), z * 10}, normal = {0, 1, 0}, color = {1, 1, 1}}
		}
		for q in 0 ..< GRID * GRID {
			a := u32(q / GRID * (GRID + 1) + q % GRID)
			for v, k in ([6]u32{a, a + GRID + 1, a + 1, a + 1, a + GRID + 1, a + GRID + 2}) {indices[q * 6 + k] = v}
		}
		s := &f.r.scene
		nodes, triangles := len(s.blas_nodes), len(s.blas_triangles)
		started := time.tick_now()
		_, added := mesh_add(f.r, vertices, indices)
		build_ms := time.duration_milliseconds(time.tick_since(started))
		testing.expect(t, added, f.r.error)
		bytes := (len(s.blas_nodes) - nodes) * size_of(Gpu_Bvh_Node) + (len(s.blas_triangles) - triangles) * size_of(Gpu_Bvh_Triangle)
		fmt.printfln("\nSoftware BVH of a mesh of %d triangles: %.1f MB, mesh_add %.1f ms (hardware rt: %v)", GRID * GRID * 2, f64(bytes) / (1 << 20), build_ms, f.r.hardware_rt)
	}
}

// Every sequence starts as a world just loaded: another world for the
// renderer, without light or history, and with a light scale of its own.
@(private = "file")
gi_restart :: proc(r: ^Renderer) {
	scene_world(r, r.world_key + 1, true)
}

// The window the noise is measured in: the still one of the case, or the one
// MIRAI_GI_WINDOW gives as from,to seconds (moving: then there is no
// reference to compare with, and what changes in it counts as noise too).
@(private = "file")
gi_window :: proc(c: Gi_Case) -> (window: [2]f32, moving: bool) {
	text, found := os.lookup_env("MIRAI_GI_WINDOW", context.temp_allocator)
	if !found {return c.still, false}
	parts := strings.split(text, ",", context.temp_allocator)
	if len(parts) != 2 {return c.still, false}
	from, ok_from := strconv.parse_f32(parts[0])
	to, ok_to := strconv.parse_f32(parts[1])
	if !ok_from || !ok_to || to <= from {return c.still, false}
	return {from, to}, true
}

// Nits of one render unit: images are measured and kept in nits, whatever
// light scale the scene took.
@(private = "file")
gi_nits :: proc(r: ^Renderer) -> f32 {
	return 1 / r.scene.light_scale if r.scene.light_scale > 0 else 1
}
