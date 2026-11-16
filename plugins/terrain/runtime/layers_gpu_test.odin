package terrain

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:testing"
import "mirai:core"
import render "mirai:engine/render"
import gpu "mirai:render"
import "mirai:rhi"
import "mirai:rhi/shared_device"

// Terrain_Layers on the GPU over a grid of points (testdata/terrain_layers_test.comp),
// its maps and the table of its layers given texel by texel and its samples
// of the maps of the layers counted.

@(private = "file")
ROOT :: #directory + "/../../.."
@(private = "file")
SIDE :: 96 // points along each axis of the grid
@(private = "file")
TEXTURE_TEXELS :: 8 * 8 // TEST_SIDE squared
@(private = "file")
TEST_COLORS :: 100
@(private = "file")
TEST_NORMALS :: 200
@(private = "file")
WORLD :: core.World_Id{index = 1}

@(private = "file")
Layers_Run :: struct {
	pipeline: render.Pipeline,
	texels:   [3 * TEXTURE_TEXELS][4]f32, // the table, the control map and the normal map
	params:   struct {side, kind: u32, time: f32, pad: u32, piece: [4]f32},
	name:     string, // of its readback
	done:     bool,
}

@(private = "file")
layers_run_record :: proc(pass: ^render.Pass, user: rawptr) {
	run := cast(^Layers_Run)user
	if run.done || run.pipeline == 0 {return}
	results := render.Buffer_Desc{name = "terrain layers test", size = 2 * SIDE * SIDE * size_of([4]f32)}
	render.pass_pipeline(pass, run.pipeline)
	if !render.pass_params(pass, &run.params, size_of(run.params)) || !render.pass_upload(pass, 0, &run.texels, size_of(run.texels)) {return}
	if bound, _ := render.pass_buffer(pass, 1, results); !bound {return}
	render.pass_dispatch(pass, (SIDE * SIDE + 63) / 64)
	run.done = render.pass_readback(pass, results, 0, {name = run.name, size = results.size})
}

// The base color (rgb) and the maps sampled (a) of each point, then its
// normal (xyz) and roughness (w).
@(private = "file")
layers_run :: proc(t: ^testing.T, r: ^gpu.Renderer, run: ^Layers_Run) -> (results: [][4]f32, ok: bool) {
	for _ in 0 ..< 8 {
		run.pipeline = render.stage_pipeline(r, {stage = .Geometry, shader = "terrain_layers_test", name = "terrain layers test"})
		if run.pipeline == 0 {gpu.renderer_pipelines_wait(r)}
		render.frame_pass(r, .Geometry, layers_run_record, run)
		if !testing.expect(t, gpu.renderer_frame(r, {}), r.error) {return}
		if data, _, read := render.readback(r, WORLD, run.name); read && len(data) == 2 * SIDE * SIDE * size_of([4]f32) {
			results = make([][4]f32, 2 * SIDE * SIDE, context.temp_allocator)
			copy(results, ([^][4]f32)(raw_data(data))[:2 * SIDE * SIDE])
			return results, true
		}
		rhi.device_wait_idle(r.device)
	}
	testing.expect(t, false, "the points come back")
	return
}

// Three layers, red, green and blue, each with a color map and a normal
// map, those of `mapless` without: none of them repeats far away or detiles.
@(private = "file")
layers_table_texels :: proc(run: ^Layers_Run, mapless: int) {
	s: Source
	defer source_destroy(&s)
	if !source_make(&s, .Heightfield, {9, 1, 9}, 1, 4) {return}
	for i in 0 ..< 3 {source_layer_set(&s, i, LAYER_DEFAULT)}
	pixels: [4 * LAYERS_TEXELS * 3]u8
	layers_table(nil, &s, pixels[:])
	put :: proc(pixels: []u8, layer, texel: int, value: u32) {
		at := 4 * (texel + LAYERS_TEXELS * layer)
		pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] = u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)
	}
	for i in 0 ..< 3 {
		if i != mapless {
			put(pixels[:], i, 0, u32(TEST_COLORS + i))
			put(pixels[:], i, 1, u32(TEST_NORMALS + i))
			put(pixels[:], i, 6, transmute(u32)f32(1))
		}
		tint: [3]u8
		tint[i] = 255
		at := 4 * (2 + LAYERS_TEXELS * i)
		pixels[at], pixels[at + 1], pixels[at + 2] = tint[0], tint[1], tint[2]
	}
	for i in 0 ..< 3 * LAYERS_TEXELS {
		for c in 0 ..< 4 {run.texels[i][c] = f32(pixels[4 * i + c]) / 255}
	}
}

@(private = "file")
texel_of :: proc(word: u32) -> [4]f32 {
	return {f32(word & 255) / 255, f32(word >> 8 & 255) / 255, f32(word >> 16 & 255) / 255, f32(word >> 24) / 255}
}

// A cell of a Heightfield whose corners are red, green, blue, and green and
// blue alike: the three weigh alike at a point of its diagonal, where green
// and blue swap the second place.
@(private = "file")
layers_cell :: proc(run: ^Layers_Run) {
	corners := [4]Weights{
		weights_pack({0, 0, 0}, {WEIGHT_FULL, 0, 0}),
		weights_pack({1, 0, 0}, {WEIGHT_FULL, 0, 0}),
		weights_pack({2, 0, 0}, {WEIGHT_FULL, 0, 0}),
		weights_pack({1, 2, 0}, {128, 127, 0}),
	}
	for c, i in corners {run.texels[TEXTURE_TEXELS + (i >> 1) * 8 + (i & 1)] = texel_of(u32(c))}
	up := normal_bytes({0, 1, 0})
	for i in 0 ..< 4 {run.texels[2 * TEXTURE_TEXELS + (i >> 1) * 8 + (i & 1)] = texel_of(transmute(u32)up)}
	run.params.side, run.params.kind, run.params.piece = SIDE, 0, {2, 2, 0, 1}
}

// The most a value of a point differs from that of the next point along x or
// along y.
@(private = "file")
largest_step :: proc(results: [][4]f32, second: bool) -> (largest: f32) {
	value :: proc(results: [][4]f32, second: bool, x, y: int) -> [4]f32 {return results[2 * (y * SIDE + x) + int(second)]}
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			here := value(results, second, x, y)
			for next in ([2][2]int{{x + 1, y}, {x, y + 1}}) {
				if next.x >= SIDE || next.y >= SIDE {continue}
				there := value(results, second, next.x, next.y)
				for c in 0 ..< 3 {largest = max(largest, abs(here[c] - there[c]))}
			}
		}
	}
	return
}

// Where layers or projections meet, two of them show. Of layers, the heaviest
// two, each less the third, so across a cell where three layers meet no point
// steps from the next, and a third shows only where three weigh about alike;
// of projections, two at most everywhere. Each layer shown samples its two
// maps in each projection shown; a layer without maps samples none.
// The same points give the same result at any time.
@(test)
terrain_layers_blend_two_at_a_time_without_a_step :: proc(t: ^testing.T) {
	root, _ := filepath.clean(ROOT, context.temp_allocator)
	// mirai test generates them: cook is not shipped, and the game compiles its test files.
	loaded, problem := gpu.shader_assets_load(fmt.tprintf("%s/.mirai/tmp/terrain-test-shaders", root))
	if !testing.expect(t, problem == "", problem) {return}
	device := shared_device.take_or_skip(t)
	if device == nil {
		gpu.shader_assets_destroy(&loaded)
		return
	}
	r := new(gpu.Renderer)
	defer free(r)
	if !testing.expect(t, gpu.renderer_init(r, {device = device, width = 64, height = 64, settings = gpu.DEFAULT_SETTINGS, shaders = &loaded}), r.error) {return}
	defer gpu.renderer_destroy(r)
	gpu.scene_world(r, render.world_key(WORLD))
	// The weights at a point of the cell, red, green and blue (layers_cell).
	weights_at :: proc(x, y: int) -> [3]f32 {
		u, v := (f32(x) + 0.5) / SIDE, (f32(y) + 0.5) / SIDE
		return {(1 - u) * (1 - v), u * (1 - v) + u * v * 128.0 / 255, (1 - u) * v + u * v * 127.0 / 255}
	}
	spread :: proc(w: [3]f32) -> f32 {return max(w.x, w.y, w.z) - min(w.x, w.y, w.z)}

	cell := new(Layers_Run)
	defer free(cell)
	layers_table_texels(cell, -1)
	layers_cell(cell)
	cell.name = "terrain layers cell"
	first, ok := layers_run(t, r, cell)
	if !ok {return}
	three := 0
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			p := first[2 * (y * SIDE + x)]
			shown := int(p.r > 0) + int(p.g > 0) + int(p.b > 0)
			three += int(shown == 3)
			testing.expectf(t, abs(p.r + p.g + p.b - 1) < 1e-4, "(%d, %d): the layers shown add up to 1: %v", x, y, p)
			testing.expectf(t, p.a == f32(2 * shown), "(%d, %d): %d layers shown sample %v maps", x, y, shown, p.a)
			// Two at most where the three do not weigh about alike.
			testing.expectf(t, shown <= 2 || spread(weights_at(x, y)) < 0.3, "(%d, %d): %d layers shown of %v", x, y, shown, weights_at(x, y))
		}
	}
	testing.expect(t, three > 0, "where the three weigh alike they show alike")
	testing.expectf(t, largest_step(first, false) < 0.2, "no point steps from the next: %v", largest_step(first, false))

	again := new(Layers_Run)
	defer free(again)
	again^ = cell^
	again.params.time, again.name, again.done = 17.5, "terrain layers again", false
	if later, read := layers_run(t, r, again); read {
		same := true
		for v, i in later {same &&= v == first[i]}
		testing.expect(t, same, "the same points give the same result at another time")
	}

	// Green has no maps: it shows, and samples none.
	mapless := new(Layers_Run)
	defer free(mapless)
	layers_table_texels(mapless, 1)
	layers_cell(mapless)
	mapless.name = "terrain layers mapless"
	if results, read := layers_run(t, r, mapless); read {
		green := 0
		for i in 0 ..< SIDE * SIDE {
			p := results[2 * i]
			green += int(p.g > 0)
			testing.expectf(t, p.a == f32(2 * (int(p.r > 0) + int(p.b > 0))), "point %d: only the layers with maps sample them: %v", i, p)
		}
		testing.expect(t, green > 0, "the layer without maps shows")
	}

	// A Volume of one layer whose normal sweeps an eighth of the sphere and
	// past its borders, a degree from point to point, through the direction
	// that faces the three axes alike (testdata/terrain_layers_test.comp):
	// two projections show at most, each sampling the two maps, and a normal
	// a twentieth of a degree away weighs them about alike. Only within two
	// degrees of that direction may they turn fast: two of three cannot go
	// round it without passing through each pair.
	turn := new(Layers_Run)
	defer free(turn)
	layers_table_texels(turn, -1)
	turn.params.side, turn.params.kind, turn.params.piece = SIDE, 1, {2, 2, 1, 1}
	turn.name = "terrain layers turn"
	if results, read := layers_run(t, r, turn); read {
		for y in 0 ..< SIDE {
			for x in 0 ..< SIDE {
				w, next := results[2 * (y * SIDE + x)], results[2 * (y * SIDE + x) + 1]
				shown := int(w.x > 0) + int(w.y > 0) + int(w.z > 0)
				testing.expectf(t, shown <= 2 && abs(w.x + w.y + w.z - 1) < 1e-4, "(%d, %d): two projections show at most, adding up to 1: %v", x, y, w)
				testing.expectf(t, w.a == f32(2 * shown), "(%d, %d): %d projections shown sample %v maps", x, y, shown, w.a)
				lat, lon := f64(y - 3) * math.RAD_PER_DEG, f64(x - 3) * math.RAD_PER_DEG
				n := [3]f64{abs(math.cos(lat) * math.cos(lon)), abs(math.sin(lat)), abs(math.cos(lat) * math.sin(lon))}
				if math.acos(min((n.x + n.y + n.z) / math.sqrt(f64(3)), 1)) * math.DEG_PER_RAD < 2 {continue}
				step := max(abs(w.x - next.x), abs(w.y - next.y), abs(w.z - next.z))
				testing.expectf(t, step <= 0.05, "(%d, %d): the weights %v step to %v a twentieth of a degree away", x, y, w.xyz, next.xyz)
			}
		}
	}
	testing.expectf(t, rhi.device_validation_errors(device) == 0, "validation: %s", rhi.device_validation_message(device))
}
