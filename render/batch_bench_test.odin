package mirai_render

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:render/abi"
import "core:testing"
import "core:time"

BATCH_BENCHMARK :: #config(BATCH_BENCHMARK, false)

// What a stroke of the foliage brush costs the renderer with many batches:
// a few batches set again (the cells under the brush), then the tables of
// the frame. 2000 batches of 500 instances, a third that rays meet.
@(test)
a_touch_of_a_brush_over_many_batches_costs_what_it_changes :: proc(t: ^testing.T) {
	when !BATCH_BENCHMARK {return}
	for hardware in ([]bool{false, true}) {
		r:=new(Renderer);defer free(r)
		r.allocator = context.allocator
		r.hardware_rt = hardware
		scene_init(r)
		defer scene_destroy(r)
		vertices: [8]Mesh_Vertex
		for &v, i in vertices {
			v.position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2 & 1) - 0.5}
			v.normal = linalg.normalize(v.position)
			v.color = {1, 1, 1}
		}
		indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
		mesh, _ := mesh_add(r, vertices[:], indices[:])
		BATCHES :: 2000
		INSTANCES :: 500
		instances := make([]Batch_Instance, INSTANCES)
		defer delete(instances)
		handles := make([]Batch_Handle, BATCHES)
		defer delete(handles)
		start := time.tick_now()
		for b in 0 ..< BATCHES {
			cell := Vec3{f32(b % 50) * 32, 0, f32(b / 50) * 32}
			for &instance, k in instances {instance = batch_instance(cell + {f32(k % 25), 0, f32(k / 25)}, 1, {1, 1, 1})}
			flags := Batch_Flags{.Casts_Shadow, .Ray_Visible} if b % 3 == 0 else {}
			handles[b], _ = batch_set(r, 0, 0, {mesh = mesh, flags = flags}, instances)
		}
		made := time.tick_since(start)
		start = time.tick_now()
		batches_build(r)
		first := time.tick_since(start)
		// A touch: eight batches set again, a third traced, and the frame after.
		touch :: proc(r: ^Renderer, mesh: Mesh_Handle, handles: []Batch_Handle, instances: []Batch_Instance, round: int) -> (set, build: time.Duration) {
			start := time.tick_now()
			for k in 0 ..< 8 {
				b := (round * 8 + k) * 37 % len(handles)
				for &instance, i in instances {instance.position.y = f32(round % 3) * 0.1 + f32(i % 2) * 0.01}
				flags := Batch_Flags{.Casts_Shadow, .Ray_Visible} if b % 3 == 0 else {}
				handles[b], _ = batch_set(r, handles[b], 0, {mesh = mesh, flags = flags}, instances)
			}
			set = time.tick_since(start)
			start = time.tick_now()
			batches_build(r)
			build = time.tick_since(start)
			return
		}
		ROUNDS :: 20
		set_total, build_total: time.Duration
		for round in 0 ..< ROUNDS {
			set, build := touch(r, mesh, handles, instances, round)
			set_total += set
			build_total += build
		}
		fmt.printfln("batches %d x %d, %s: made %.1f ms, first tables %.2f ms; a touch of 8: set %.3f ms, tables %.3f ms", BATCHES, INSTANCES, "hardware rt" if hardware else "software rt", time.duration_milliseconds(made), time.duration_milliseconds(first), time.duration_milliseconds(set_total) / ROUNDS, time.duration_milliseconds(build_total) / ROUNDS)
		testing.expect(t, r.scene.batch.built)
	}
}

// What a jump of the origin costs the CPU with many instances of batches: it
// moves the instances of the scene and the rows of the batches, and builds
// their tables again, whatever the instances each batch holds. 2000 batches
// of 500 instances, a third that rays meet, and 2000 instances of the scene.
@(test)
a_jump_of_the_origin_costs_what_the_batches_are_not_what_they_hold :: proc(t: ^testing.T) {
	when !BATCH_BENCHMARK {return}
	for hardware in ([]bool{false, true}) {
		r:=new(Renderer);defer free(r)
		r.allocator = context.allocator
		r.hardware_rt = hardware
		scene_init(r)
		defer scene_destroy(r)
		vertices: [8]Mesh_Vertex
		for &v, i in vertices {
			v.position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2 & 1) - 0.5}
			v.normal = linalg.normalize(v.position)
			v.color = {1, 1, 1}
		}
		indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
		mesh, _ := mesh_add(r, vertices[:], indices[:])
		BATCHES :: 2000
		INSTANCES :: 500
		SCENE :: 2000
		far := Vec3{15000, 0, -12000}
		instances := make([]Batch_Instance, INSTANCES)
		defer delete(instances)
		for b in 0 ..< BATCHES {
			cell := far + Vec3{f32(b % 50) * 32, 0, f32(b / 50) * 32}
			for &instance, k in instances {instance = batch_instance(cell + {f32(k % 25), 0, f32(k / 25)}, 1, {1, 1, 1})}
			flags := Batch_Flags{.Casts_Shadow, .Ray_Visible} if b % 3 == 0 else {}
			batch_set(r, 0, 0, {mesh = mesh, flags = flags}, instances)
		}
		descs := make([]Instance_Desc, SCENE)
		defer delete(descs)
		for &desc, i in descs {desc = {object_id = u64(i + 1), mesh = mesh, transform = linalg.matrix4_translate_f32(far + {f32(i % 40) * 3, 0, f32(i / 40) * 3}), tint = 1}}
		scene_given(r, descs, nil, {}, {})
		batches_build(r)
		ROUNDS :: 20
		jump, tables: time.Duration
		uploads: int
		for round in 0 ..< ROUNDS {
			for &ranges in r.scene.pool_dirty {clear(&ranges)}
			start := time.tick_now()
			renderer_origin_set(r, far + {f32(round % 2) * ORIGIN_STEP * 2, 0, 0})
			jump += time.tick_since(start)
			for ranges, pool in r.scene.pool_dirty {for range in ranges {uploads += int(range.count) * (size_of(Gpu_Bvh_Node) if pool == .Node else 4)}}
			start = time.tick_now()
			batches_build(r)
				tables += time.tick_since(start)
		}
		fmt.printfln("origin jump, %s: %d batches x %d, %d instances of the scene: move %.3f ms, tables %.3f ms, %.1f MB of pools to upload", "hardware rt" if hardware else "software rt", BATCHES, INSTANCES, SCENE, time.duration_milliseconds(jump) / ROUNDS, time.duration_milliseconds(tables) / ROUNDS, f64(uploads) / ROUNDS / 1e6)
	}
}

// What the instances the culls of the shadow maps of a view go over cost the
// CPU of a frame (shadow_reach) with batches of a large world: 10000 batches
// of 91 instances over two kilometres, half of them gone past 150 m, 18 levels
// of the sun and 32 lights of six faces near the eye; a still frame, frames whose eye moves a metre, and
// the frames after a jump of the eye, while batches are set again each frame.
@(test)
the_reach_of_the_shadow_maps_costs_what_changed :: proc(t: ^testing.T) {
	when !BATCH_BENCHMARK {return}
	r := new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	vertices: [8]Mesh_Vertex
	for &v, i in vertices {
		v.position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2 & 1) - 0.5}
		v.normal = linalg.normalize(v.position)
		v.color = {1, 1, 1}
	}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	mesh, _ := mesh_add(r, vertices[:], indices[:])
	BATCHES :: 10000
	INSTANCES :: 91
	instances := make([]Batch_Instance, INSTANCES)
	defer delete(instances)
	handles := make([]Batch_Handle, BATCHES)
	defer delete(handles)
	cell :: proc(instances: []Batch_Instance, b: int, lift: f32) {
		corner := Vec3{f32(b % 100) * 20 - 1000, lift, f32(b / 100) * 20 - 1000}
		for &instance, k in instances {instance = batch_instance(corner + {f32(k % 13) * 1.5, 0, f32(k / 13) * 2.8}, 1, {1, 4, 1})}
	}
	for b in 0 ..< BATCHES {
		cell(instances, b, 0)
		handles[b], _ = batch_set(r, 0, 0, {mesh = mesh, flags = {.Casts_Shadow, .Ray_Visible}, cull_distance = 150 if b % 2 == 0 else 0}, instances)
	}
	batches_build(r)
	s := &r.scene
	low, high := s.batch.bounds_min, s.batch.bounds_max
	b: Shadow_Raster
	defer shadow_reach_release(r, &b)
	// The maps of a view whose eye is at `eye`: the levels of the sun, then the faces of the lights.
	plan :: proc(r: ^Renderer, b: ^Shadow_Raster, eye, low, high: Vec3, wants: ^[SHADOW_SLOTS]Shadow_Want) {
		wants^ = {}
		b.cull = shadow_cull_cell(eye, {})
		levels := shadow_sun_levels(wants, {-0.3, -1, -0.2}, eye, {}, 3000, low, high, true, b.held[:SHADOW_SUN_LEVELS])
		for &h, k in b.held[:levels] {h = {m = wants[k].m, grid = wants[k].grid}}
		forward := linalg.normalize(Vec3{0, -0.3, -1})
		right := linalg.normalize(linalg.cross(forward, Vec3{0, 1, 0}))
		up := linalg.cross(right, forward)
		for light in 0 ..< SHADOW_RASTER_LIGHTS {
			angle := f32(light) * 0.196
			l := Gpu_Light{position_range = {eye.x + 30 * math.cos(angle), 3, eye.z - 30 + 30 * math.sin(angle), 20}, size = {0.1, 0, 0, 0}, direction_cone = {0, -1, 0, GPU_LIGHT_POINT}}
			faces: [abi.SHADOW_LIGHT_SLOTS]Shadow_Want
			shadow_light_faces(&faces, l, 0.1, eye, forward, right, up, 1, 0.6, 0.1, low, high, true)
			for &w, face in faces {
				if w.weight <= 0 {continue}
				slot := SHADOW_SUN_LEVELS + light * abi.SHADOW_LIGHT_SLOTS + face
				w.m.rect = {u32(slot), 0, SHADOW_MAP_SIDE, u32(light)}
				wants[slot] = w
			}
		}
	}
	wants: [SHADOW_SLOTS]Shadow_Want
	plans: [SHADOW_SLOTS]Shadow_Slot_Plan
	reach: [SHADOW_SLOTS]Shadow_Reach
	eye := Vec3{0, 12, 0}
	plan(r, &b, eye, low, high, &wants)
	testing.expect(t, shadow_reach(r, &b, wants[:], plans[:], reach[:]))
	ROUNDS :: 50
	still, moving: time.Duration
	for _ in 0 ..< ROUNDS {
		start := time.tick_now()
		shadow_reach(r, &b, wants[:], plans[:], reach[:])
		still += time.tick_since(start)
	}
	for round in 0 ..< ROUNDS {
		eye.x += 1
		plan(r, &b, eye, low, high, &wants)
		start := time.tick_now()
		shadow_reach(r, &b, wants[:], plans[:], reach[:])
		moving += time.tick_since(start)
	}
	// A jump of the eye, and the frames after it, eight batches set again in each.
	JUMPS :: 5
	JUMP_FRAMES :: 6
	jump, jump_most, tables: time.Duration
	for n in 0 ..< JUMPS {
		eye.x = -600 if n % 2 == 0 else 600
		for frame in 0 ..< JUMP_FRAMES {
			for k in 0 ..< 8 {
				at := (n * 97 + frame * 8 + k) * 31 % BATCHES
				cell(instances, at, f32(frame % 2) * 0.1)
				handles[at], _ = batch_set(r, handles[at], 0, {mesh = mesh, flags = {.Casts_Shadow, .Ray_Visible}, cull_distance = 150 if at % 2 == 0 else 0}, instances)
			}
			start := time.tick_now()
			batches_build(r)
			tables += time.tick_since(start)
			plan(r, &b, eye, low, high, &wants)
			start = time.tick_now()
			shadow_reach(r, &b, wants[:], plans[:], reach[:])
			took := time.tick_since(start)
			jump += took
			jump_most = max(jump_most, took)
		}
	}
	// What was kept over the frames is what the maps give found anew.
	kept := reach
	ranges := make([][2]u32, len(s.shadow_ranges))
	defer delete(ranges)
	copy(ranges, s.shadow_ranges[:])
	shadow_reach_release(r, &b)
	testing.expect(t, shadow_reach(r, &b, wants[:], plans[:], reach[:]))
	testing.expect(t, kept == reach && slice.equal(ranges, s.shadow_ranges[:]), "what was kept differs from what the maps give found anew")
	slots := 0
	for w in wants {if w.m.rect.z != 0 {slots += 1}}
	fmt.printfln("shadow reach, %d batches x %d, %d slots with a map: still %.3f ms, the eye moving %.3f ms; after a jump %.3f ms a frame, %.3f at most (the tables of the batches %.3f ms); %d ranges", BATCHES, INSTANCES, slots, time.duration_milliseconds(still) / ROUNDS, time.duration_milliseconds(moving) / ROUNDS, time.duration_milliseconds(jump) / (JUMPS * JUMP_FRAMES), time.duration_milliseconds(jump_most), time.duration_milliseconds(tables) / (JUMPS * JUMP_FRAMES), len(s.shadow_ranges))
}

// The maps of a view whose eye is at `eye` for the benchmarks of the plan of
// the maps: the levels of the sun, then the faces of 32 lights near the eye.
@(private = "file")
bench_shadow_wants :: proc(r: ^Renderer, b: ^Shadow_Raster, eye, low, high: Vec3, wants: ^[SHADOW_SLOTS]Shadow_Want) {
	wants^ = {}
	levels := shadow_sun_levels(wants, {-0.3, -1, -0.2}, eye, {}, 3000, low, high, true, b.held[:SHADOW_SUN_LEVELS])
	for &h, k in b.held[:levels] {h = {m = wants[k].m, grid = wants[k].grid}}
	forward := linalg.normalize(Vec3{0, -0.3, -1})
	right := linalg.normalize(linalg.cross(forward, Vec3{0, 1, 0}))
	up := linalg.cross(right, forward)
	for light in 0 ..< SHADOW_RASTER_LIGHTS {
		angle := f32(light) * 0.196
		l := Gpu_Light{position_range = {eye.x + 30 * math.cos(angle), 3, eye.z - 30 + 30 * math.sin(angle), 20}, size = {0.1, 0, 0, 0}, direction_cone = {0, -1, 0, GPU_LIGHT_POINT}}
		faces: [abi.SHADOW_LIGHT_SLOTS]Shadow_Want
		shadow_light_faces(&faces, l, 0.1, eye, forward, right, up, 1, 0.6, 0.1, low, high, true)
		for &w, face in faces {
			if w.weight <= 0 {continue}
			slot := SHADOW_SUN_LEVELS + light * abi.SHADOW_LIGHT_SLOTS + face
			w.m.rect = {u32(slot), 0, SHADOW_MAP_SIDE, u32(light)}
			wants[slot] = w
		}
	}
}

// What the plan of the maps of a view costs the CPU of a frame while the wind
// sways a dense foliage scene: 8000 batches of 114 instances (912,000) over a
// kilometre, of 40 deformables that sway 0.3 m, two kinds of five with a cull
// distance of 150 m, 18 levels of the sun and 32 lights of six faces near the
// eye; the frames right after the wind starts, then still and flying frames
// while everything sways. What it moves (shadow_movers_update) and what the
// plan finds of the casters (shadow_plan_casters).
@(test)
the_plan_of_the_shadow_maps_costs_little_while_everything_sways :: proc(t: ^testing.T) {
	when !BATCH_BENCHMARK {return}
	r := new(Renderer);defer free(r)
	r.allocator = context.allocator
	scene_init(r)
	defer scene_destroy(r)
	vertices: [8]Mesh_Vertex
	for &v, i in vertices {
		v.position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2 & 1) - 0.5}
		v.normal = linalg.normalize(v.position)
		v.color = {1, 1, 1}
	}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	source, _ := mesh_add(r, vertices[:], indices[:])
	MESHES :: 40
	KINDS :: 5
	SIDE :: 40
	BATCHES :: SIDE * SIDE * KINDS
	INSTANCES :: 114
	meshes: [MESHES]Mesh_Handle
	for &mesh in meshes {
		made: bool
		mesh, made = deformable_create(r, source, false, 0.3)
		testing.expect(t, made)
	}
	instances := make([]Batch_Instance, INSTANCES)
	defer delete(instances)
	for b in 0 ..< BATCHES {
		cell, kind := b / KINDS, b % KINDS
		corner := Vec3{f32(cell % SIDE) * 24 - 480, 0, f32(cell / SIDE) * 24 - 480}
		for &instance, k in instances {instance = batch_instance(corner + {f32(k % 12) * 2 + f32(kind) * 0.3, 0.5, f32(k / 12) * 2.5}, 1, {1, 2 if kind < 2 else 0.5, 1})}
		_, problem := batch_set(r, 0, 0, {mesh = meshes[b % MESHES], flags = {.Casts_Shadow, .Ray_Visible}, cull_distance = 150 if kind >= 3 else 0}, instances)
		testing.expect(t, problem == "", problem)
	}
	batches_build(r)
	s := &r.scene
	low, high := s.batch.bounds_min, s.batch.bounds_max
	b := &r.main.targets.shadow_raster
	defer shadow_reach_release(r, b)
	frame :: proc(r: ^Renderer, b: ^Shadow_Raster, meshes: []Mesh_Handle, eye, low, high: Vec3, sways: bool) -> time.Duration {
		if sways {for mesh in meshes {deformable_update(r, mesh, {-0.8, -0.8, -0.8}, {0.8, 0.8, 0.8})}}
		wants: [SHADOW_SLOTS]Shadow_Want
		plans: [SHADOW_SLOTS]Shadow_Slot_Plan
		reach: [SHADOW_SLOTS]Shadow_Reach
		sway: [SHADOW_SLOTS]u32
		sway_count := 0
		stale, moved: Occluder_Changes
		plan: Shadow_Plan
		bench_shadow_wants(r, b, eye, low, high, &wants)
		start := time.tick_now()
		shadow_movers_update(r)
		shadow_plan_casters(r, b, eye, false, wants[:], plans[:], &plan, reach[:], sway[:], &sway_count, &stale, &moved)
		took := time.tick_since(start)
		for mesh in meshes {r.scene.meshes[mesh].skin.dirty = false}
		r.frame += 1
		b.frame += 1
		return took
	}
	eye := Vec3{0, 12, 0}
	for _ in 0 ..< 4 {frame(r, b, meshes[:], eye, low, high, false)}
	still_before := frame(r, b, meshes[:], eye, low, high, false)
	// The wind starts.
	first: time.Duration
	for _ in 0 ..< 3 {first = max(first, frame(r, b, meshes[:], eye, low, high, true))}
	for _ in 0 ..< 8 {frame(r, b, meshes[:], eye, low, high, true)}
	ROUNDS :: 50
	still, flying: time.Duration
	for _ in 0 ..< ROUNDS {still += frame(r, b, meshes[:], eye, low, high, true)}
	for _ in 0 ..< ROUNDS {
		eye.x += 0.25
		flying += frame(r, b, meshes[:], eye, low, high, true)
	}
	fmt.printfln("shadow plan, %d batches x %d swaying: before the wind %.3f ms; the first frames of the wind %.3f ms at most; swaying, still %.3f ms, flying %.3f ms a frame", BATCHES, INSTANCES, time.duration_milliseconds(still_before), time.duration_milliseconds(first), time.duration_milliseconds(still) / ROUNDS, time.duration_milliseconds(flying) / ROUNDS)
}
