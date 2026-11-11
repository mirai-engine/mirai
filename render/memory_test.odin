package mirai_render

import "base:runtime"
import "core:strings"
import "core:testing"
import mm "mirai:std/math"

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private)
Memory_Limit :: struct {owner: runtime.Allocator, remaining: int}

@(private)
memory_limit_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	limit := (^Memory_Limit)(data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if limit.remaining <= 0 {return nil, .Out_Of_Memory}
		limit.remaining -= 1
	}
	return limit.owner.procedure(limit.owner.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private = "file")
MEMORY_CATALOG :: `{"programs":[{"id":3,"name":"Paint","domain":"vfx","attributes":8,"size":24,
	"resources":[{"name":"field","kind":"grid"},{"name":"words","kind":"data","words":4}],
	"stages":[{"name":"spread","iterations":2,"over":"field","writes":["field"]}],
	"parameters":[
		{"name":"image","kind":"texture","components":1,"offset":0,"default":"","min":0,"max":0,"srgb":true},
		{"name":"steps","kind":"int32","components":2,"offset":4,"default":[-2,5],"min":-8,"max":8,"group":"Pattern"}]}]}`

// What the renderer asks its allocator for without a device, with the memory
// ending at each request in turn: the call is refused, says so where it has
// an error to say it in, and leaves what it had; with memory enough it goes
// through.
@(test)
renderer_calls_without_memory_are_refused_and_keep_what_they_had :: proc(t: ^testing.T) {
	limit := Memory_Limit{owner = context.allocator, remaining = max(int)}
	limited := runtime.Allocator{memory_limit_proc, &limit}
	Call :: enum {Bvh, Light_Tree, Texture, Catalog, Scene_Init, Materials, Scene_Whole, Scene_Update, Lights, Shader_Reload, Mesh}
	SAYS :: bit_set[Call]{.Materials, .Scene_Whole, .Scene_Update, .Lights, .Shader_Reload}

	vertices: [8]Mesh_Vertex
	for &v, i in vertices {
		v.position = {f32(i & 1) - 0.5, f32(i >> 1 & 1) - 0.5, f32(i >> 2 & 1) - 0.5}
		v.normal, v.color, v.tangent = v.position * 2, {1, 1, 1}, {1, 0, 0, 1}
	}
	indices := [36]u32{0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5}
	items: [9]mm.Aabb
	for &item, i in items {
		center := Vec3{f32(i % 3), f32(i / 3), 0} * 2
		item = {center - 0.5, center + 0.5}
	}
	lights: [6]Gpu_Light
	for &light, i in lights {
		light.position_range = {f32(i) * 3, 1, 0, 5}
		light.color_intensity = {1, 1, 1, 10}
		light.direction_cone = {0, 0, 0, GPU_LIGHT_POINT}
	}
	light_descs: [3]Light_Desc
	for &light, i in light_descs {light = {position = {f32(i) * 3, 1, 0}, color = {1, 1, 1}, intensity = 10, range = 5}}
	pixels: [8 * 8 * 4]u8
	for &value, i in pixels {value = u8(i * 7)}
	materials := [3]Material_Desc{DEFAULT_MATERIAL, DEFAULT_MATERIAL, DEFAULT_MATERIAL}

	for call in Call {
		r := new(Renderer)
		defer free(r)
		r.allocator = limited
		if !testing.expect(t, scene_init(r)) {return}
		defer scene_destroy(r)
		s := &r.scene
		nodes := make([dynamic]Gpu_Bvh_Node, limited)
		order := make([dynamic]u32, limited)
		tree := make([dynamic]Gpu_Light_Node, limited)
		keys := make([dynamic]Light_Key, limited)
		leaves := make([dynamic]u32, limited)
		defer {delete(nodes);delete(order);delete(tree);delete(keys);delete(leaves)}
		instances: [4]Instance_Desc
		#partial switch call {
		case .Light_Tree:
			_, built := light_tree_build(&tree, &keys, &leaves, lights[:2])
			if !testing.expect(t, built) {return}
		case .Scene_Whole, .Scene_Update:
			mesh, added := mesh_add(r, vertices[:], indices[:])
			if !testing.expect(t, added) {return}
			for &instance, i in instances {instance = {object_id = u64(i + 1), mesh = mesh, transform = Mat4(1), tint = {1, 1, 1}}}
			if call == .Scene_Update && !testing.expect(t, scene_given(r, instances[:1], nil, {}, {})) {return}
		}
		held := [4]int{len(tree), len(leaves), len(s.instances), len(s.meshes)}
		words := len(s.vertices) + len(s.indices)
		done, refused := false, false
		for served in 0 ..< 256 {
			r.error = ""
			limit.remaining = served
			switch call {
			case .Bvh:
				done = bvh_build(items[:], 2, &nodes, &order)
			case .Light_Tree:
				_, done = light_tree_build(&tree, &keys, &leaves, lights[:])
			case .Texture:
				data: Texture_Data
				data, done = texture_build({pixels = pixels[:], width = 8, height = 8}, 8, limited)
				if !done {testing.expectf(t, len(data.levels) == 0, "a texture refused with %d requests served keeps no level", served)}
				texture_data_destroy(&data, limited)
			case .Catalog:
				catalog: Program_Catalog
				catalog, done = program_catalog_parse(transmute([]u8)string(MEMORY_CATALOG), limited)
				if !done {testing.expectf(t, len(catalog.programs) == 0, "a catalog refused with %d requests served keeps no program", served)}
				program_catalog_destroy(&catalog)
			case .Scene_Init:
				fresh := new(Renderer)
				fresh.allocator = limited
				done = scene_init(fresh)
				scene_destroy(fresh)
				free(fresh)
			case .Materials:
				done = materials_set(r, materials[:])
				if !done {testing.expectf(t, len(s.materials) == 0, "a table refused with %d requests served has no row", served)}
			case .Scene_Whole:
				done = scene_update(r, 0, instances[:], true)
			case .Scene_Update:
				done = scene_update(r, 1, instances[1:])
			case .Lights:
				done = scene_light_update(r, 0, light_descs[0])
				if !done {testing.expectf(t, len(s.lights) == 0, "a light refused with %d requests served is not there", served)}
			case .Shader_Reload:
				assets := Shader_Assets{owned = true}
				candidate := renderer_shader_reload_begin(r, &assets)
				done = candidate != nil
				renderer_abort_shader_reload(candidate)
			case .Mesh:
				_, done = mesh_add(r, vertices[:], indices[:])
			}
			limit.remaining = max(int)
			if done {break}
			refused = true
			if call in SAYS {testing.expectf(t, strings.contains(r.error, "out of memory"), "%v with %d requests served says: %s", call, served, r.error)}
			testing.expectf(t, held == [4]int{len(tree), len(leaves), len(s.instances), len(s.meshes)} && len(nodes) == 0 && len(order) == 0 && words == len(s.vertices) + len(s.indices),
				"%v with %d requests served leaves what it had", call, served)
		}
		testing.expectf(t, done && refused, "%v: refused without memory, and with it it goes through", call)
		#partial switch call {
		case .Scene_Whole, .Scene_Update:
			testing.expectf(t, len(s.instances) == len(instances), "%v: %d instances", call, len(s.instances))
		case .Lights:
			testing.expect_value(t, len(s.lights), 1)
		case .Materials:
			testing.expect_value(t, len(s.materials), len(materials) + 1)
		}
	}
}
