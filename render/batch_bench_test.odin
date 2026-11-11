package mirai_render

import "core:fmt"
import "core:math/linalg"
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
			for &instance, k in instances {instance = batch_instance(cell + {f32(k % 25), 0, f32(k / 25)}, 1, 1, 1)}
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
			for &instance, k in instances {instance = batch_instance(cell + {f32(k % 25), 0, f32(k / 25)}, 1, 1, 1)}
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
