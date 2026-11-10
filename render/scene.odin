package mirai_render

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:rhi"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:render/abi"

// GPU scene: one global vertex/index pool for every mesh, per-mesh BLAS (a
// software BVH always, a native acceleration structure when hardware ray
// queries are active), per-instance transforms, a material table and a TLAS.
// Geometry changes are load transactions; instance, material and light
// changes are uploaded inside the next frame through the transient ring.

Mesh_Handle :: distinct u32

// Row of the material table. 0 is the default material: white, rough, not
// metallic and without textures.
Material_Handle :: distinct u32

Mesh_Vertex :: struct {
	position: Vec3,
	normal:   Vec3,
	uv:       Vec2, // UV0, origin at the top left of the image, v downwards
	uv1:      Vec2, // UV1; importers copy UV0 when the second set is absent
	color:    Vec3, // multiplies the base color of the material; a program reads it instead (ctx.vertex_color)
	material: Material_Handle,
	slot: u32, // source slot 1..32; zero means no slot
	tangent:  Vec4, // MikkTSpace: xyz along u, w the sign of the bitangent sign * cross(normal, tangent)
}

// A row of the material table: the values a material stores, of which the
// renderer reads every one but the texture ids and the name of the program,
// with what it resolved of those two.
Material_Desc :: struct {
	using info:    asset.Material_Info,
	textures:      [asset.Material_Map_Kind]Texture_Handle,
	program_id:    u32, // compiled Surface program; 0: the standard model
	custom_params: [16]Vec4,
}

DEFAULT_MATERIAL :: Material_Desc{info = asset.MATERIAL_DEFAULTS}

OVERLAY_CAPACITY :: 4
Overlay_Desc :: struct {id:u32,material:Material_Handle,blend:asset.Overlay_Blend,enabled:bool}
Instance_Overlays :: struct {count:u32,entries:[OVERLAY_CAPACITY]Overlay_Desc}

Instance_Desc :: struct {
	object_id: u64,
	mesh:      Mesh_Handle,
	transform: Mat4,            // object to world, column vectors, relative to anchor
	// The place of the world transform is relative to; zero for one of the
	// world. What a camera carries comes from the place of the camera: f32
	// keeps it to the step of its size, not to that of the place of the world.
	anchor:    Vec3,
	material:  Material_Handle, // replaces the materials of the mesh's vertices; 0 keeps them
	tint:      Vec3,            // multiplies the base color
	emission:  Vec3,            // added to the emission of the material
	material_values: Instance_Material_Values, // over the rows of its materials, where it shows them
	hidden:    bool,
	highlight: u8,              // outline level: 0 none, then the editor's and the game's (HIGHLIGHT_LEVELS)
	copy_owner, copy_variant: u64, // distinguishes rendered copies; zero identifies the original
	replace_source: bool, // a visual frame instance hides the world mesh with the same object_id
	slot_materials: [32]u32, // row+1 per source slot; zero inherits global/model
	overlays: Instance_Overlays, // camera-only surface layers, reuse this instance
	uniform_color: bool,       // use tint without the mesh's vertex colors
	outline_only: bool,        // with a highlight: only its outline is drawn, as of something that is not there
	layers: u32,               // the layers it is in (16 of them), which a view draws or not; 0: the first one alone
	owner: u8,                 // 1 + the local slot whose body it is: a view of that slot that hides its body fades it out; 0: none
}

// An instance whose materials need more of the G-buffer than base color and metallic.
Reflective_Instance :: struct {
	instance: u32,
	layered:  bool, // some of its materials have layers (asset.Material_Layers): the layers target too
}

// Rendered copies retain the source object id without sharing its motion history.
Instance_Key :: struct {object, owner, variant: u64}

// A local light: a sphere, a capsule (a sphere drawn along a segment) or a
// rectangle that glows on one side. A sphere or a capsule gives its
// intensity, in candela, as a point light would: the illuminance far along
// its axis is the intensity over the square of the distance. A rectangle
// glows with a luminance, in nits, so a larger one gives more light.
Light_Desc :: struct {
	position:  Vec3,
	color:     Vec3,
	intensity: f32,  // candela; a rectangle: the luminance of its face, nits
	range:     f32,
	direction: Vec3, // spot lights: where the cone points; a rectangle: the side it lights
	cone:      f32,  // spot lights: half-angle in radians; 0 for point lights
	radius:    f32,  // of the sphere, or of the capsule, that gives the light, metres
	axis:      Vec3, // a capsule: along its segment; a rectangle: along its width
	length:    f32,  // a capsule: of its segment, metres; 0: a sphere
	size:      Vec2, // a rectangle: its width and height, metres; zero: not one
	material:  Material_Handle, // a rectangle: the material whose emission colors it across, its texture mapped to it as to a unit quad (0: its color alone)
}

Sun_Desc :: struct {
	direction:   Vec3, // towards the sun
	color:       Vec3,
	illuminance: f32,  // lux, on a surface that faces it
	enabled:   bool,
	disc:      bool, // it is seen in the sky
}

Environment :: struct {
	sky:            Vec3, // luminance of the sky, nits (it lights the scene through misses); with an image, what multiplies its values
	sky_texture:    Texture_Handle, // an image of the whole sky, twice as wide as tall; 0: a gradient of `sky`
	sky_orientation: quaternion128, // the turn of the sky, that of its entity; zero is none
	sky_from:       Vec3, // a change on its way: the luminance the sky changes from, nits
	sky_from_texture: Texture_Handle, // and the image it changes from; 0: a gradient
	sky_from_weight: f32, // how much of what it changes from still shows, 0 to 1
	sky_atmosphere: bool, // the sky is the air lit by the sun (air.odin), whose light it crosses: sky does not apply
	sky_from_atmosphere: bool, // and what it changes from, of the same air
	air:            Air,  // of an atmosphere
	background:     Vec3, // luminance behind the scene, nits
	use_background: bool, // false: show the sky gradient
	ground_grid:    bool, // display-only reference plane; never geometry or lighting
}

@(private) Mesh_Pool :: enum {Vertex,Index,Node,Triangle}
@(private) Pool_Range :: struct {first,count:u32}
@(private) Geometry_Copy :: struct {buffer:rhi.Buffer,offset:u64,bytes:[]u8}

// An instance with blended triangles, and how far it is from the camera.
Translucent :: struct {
	instance: u32,
	distance: f32,
	solid:    bool, // a blended material of it has a medium (material_solid): the camera can be in it
	layered:  bool, // a blended material of it has layers: the glass layers keep them in a target
}

// Where the light of the world changed since the GI last looked: spheres
// (center, radius), or everywhere. The probe volume traces again the probes
// they reach.
LIGHT_CHANGES_MAX :: 64
Light_Changes :: struct {
	spheres: [LIGHT_CHANGES_MAX]Vec4,
	count:   int,
	all:     bool,
}
// How far around an instance a change of its glow changes the light, metres;
// what it changes otherwise, by its shadow and the light it reflects, falls
// with the square of the distance over its size: LIGHT_CHANGE_SIZES of its
// radius (one hundredth of the light), and never further than the glow.
LIGHT_CHANGE_REACH :: f32(8)
LIGHT_CHANGE_SIZES :: f32(10)

// What casts shadows and changed since the frame before: each instance that
// moved, took another pose or shape, came or went, with the box it covers in
// both frames, and the lights that moved. The shadow passes mark what their
// rays meet of it (occluder_changed of trace.slang) and their histories start
// again there. Past its room an instance joins the box it grows least, which
// then stands for several (OCCLUDERS_MANY).
OCCLUDER_CHANGES_MAX :: abi.OCCLUDER_CHANGES_MAX
LIGHT_MOVES_MAX :: abi.LIGHT_MOVES_MAX
OCCLUDERS_MANY :: abi.OCCLUDERS_MANY
Occluder_Change :: struct {
	low, high: Vec3,
	instance:  u32, // OCCLUDERS_MANY: several, or one that is gone
}
Occluder_Changes :: struct {
	boxes:       [OCCLUDER_CHANGES_MAX]Occluder_Change,
	count:       int,
	lights:      [LIGHT_MOVES_MAX]u32,
	light_count: int, // past LIGHT_MOVES_MAX every light counts as moved
	sun:         bool,
}

// An instance that casts shadows covered low to high in the frame before, or
// covers it now: the box it changed in grows by it.
@(private)
occluder_changed :: proc(s: ^Scene_State, instance: u32, low, high: Vec3) {
	o := &s.occluders
	if !(low.x <= high.x && low.y <= high.y && low.z <= high.z) {return}
	if instance != OCCLUDERS_MANY {
		for &box in o.boxes[:o.count] {
			if box.instance != instance {continue}
			box.low, box.high = linalg.min(box.low, low), linalg.max(box.high, high)
			return
		}
	}
	if o.count < OCCLUDER_CHANGES_MAX {
		o.boxes[o.count] = {low, high, instance}
		o.count += 1
		return
	}
	volume :: proc "contextless" (low, high: Vec3) -> f32 {e := high - low; return e.x * e.y * e.z}
	best, growth := 0, f32(max(f32))
	for box, i in o.boxes {
		grown := volume(linalg.min(box.low, low), linalg.max(box.high, high)) - volume(box.low, box.high)
		if grown < growth {best, growth = i, grown}
	}
	box := &o.boxes[best]
	box.low, box.high, box.instance = linalg.min(box.low, low), linalg.max(box.high, high), OCCLUDERS_MANY
}

// What an instance that came or went covers in the frame it is not there.
@(private)
INSTANCE_ABSENT :: Gpu_Instance{meta = {0, 0, 0, INSTANCE_FLAG_HIDDEN}}

// An instance that changed what it covers: the box of the frame before, then the one now.
@(private)
occluder_moved :: proc(s: ^Scene_State, index: u32, before, after: Gpu_Instance) {
	shown :: proc "contextless" (inst: Gpu_Instance) -> bool {return inst.meta.w & (INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED) == 0}
	if shown(before) {occluder_changed(s, index, before.bounds_min.xyz, before.bounds_max.xyz)}
	if shown(after) {occluder_changed(s, index, after.bounds_min.xyz, after.bounds_max.xyz)}
}

// A light of the set that moved or changed its shape: what it shades is new.
@(private)
occluder_light_moved :: proc(s: ^Scene_State, light: u32) {
	o := &s.occluders
	for moved in o.lights[:min(o.light_count, LIGHT_MOVES_MAX)] {if moved == light {return}}
	if o.light_count < LIGHT_MOVES_MAX {o.lights[o.light_count] = light}
	o.light_count += 1
}

// What changed of the occluders and the lights, as the shaders of the frame read it.
@(private)
frame_occluders :: proc(f: ^Gpu_Frame, o: ^Occluder_Changes) {
	lights := min(o.light_count, LIGHT_MOVES_MAX)
	f.moved = {u32(o.count), u32(lights), (MOVED_SUN if o.sun else 0) | (MOVED_LIGHTS_ALL if o.light_count > LIGHT_MOVES_MAX else 0), 0}
	for box, i in o.boxes[:o.count] {
		f.moved_boxes[i] = {{box.low.x, box.low.y, box.low.z, transmute(f32)box.instance}, {box.high.x, box.high.y, box.high.z, 0}}
	}
	for light, i in o.lights[:lights] {f.moved_lights[i / 4][i % 4] = light}
}

scene_changed :: proc(s: ^Scene_State) {s.changes.all = true}

// The light changed within `radius` of `center`; past the capacity, everywhere.
scene_changed_near :: proc(s: ^Scene_State, center: Vec3, radius: f32) {
	if s.changes.all {return}
	if s.changes.count == LIGHT_CHANGES_MAX {s.changes.all = true; return}
	s.changes.spheres[s.changes.count] = {center.x, center.y, center.z, radius}
	s.changes.count += 1
}

scene_changed_box :: proc(s: ^Scene_State, low, high: Vec3) {
	scene_changed_near(s, (low + high) * 0.5, linalg.length(high - low) * 0.5)
}

Scene_State :: struct {
	vertices:             [dynamic]u32, // the vertex pool (gpu_types.odin)
	indices:              [dynamic]u32, // the index pool
	meshes:               [dynamic]Mesh_Record,
	skinned:              [dynamic]Mesh_Handle,
	blas_nodes:           [dynamic]Gpu_Bvh_Node,
	blas_triangles:       [dynamic]Gpu_Bvh_Triangle,
	free_meshes:          [dynamic]u32,
	pool_free:           [Mesh_Pool][dynamic]Pool_Range,
	pool_dirty:          [Mesh_Pool][dynamic]Pool_Range,
	mesh_dirty:          [dynamic]Pool_Range,
	translucent:          [dynamic]Translucent, // sorted back to front every frame
	geometry_dirty:       bool,
	vertices_made:        u64, // times the vertex buffer was made again: what an extension wrote in it is gone
	vertex_buffer:        rhi.Buffer,
	index_buffer:         rhi.Buffer,
	mesh_buffer:          rhi.Buffer,
	blas_node_buffer:     rhi.Buffer,
	blas_triangle_buffer: rhi.Buffer,
	geometry_staging:     [rhi.MAX_FRAMES_IN_FLIGHT + 1]rhi.Buffer, // one per frame in flight, which a frame writes while the GPU may still copy from that of the frame before, and the last for the copies waited for between frames
	pool_moves:           [Mesh_Pool]Pool_Move,
	pool_refused:         [Mesh_Pool]Pool_Refusal,
	pools_grown:          bit_set[Mesh_Pool], // since the last publication
	blas_refused:         Pool_Refusal, // a BLAS the GPU had no memory for: bytes, its size, while one is refused
	released:             u64, // bytes of meshes, batches, BLASes and textures let go: what the GPU refused may fit after
	refused:              Geometry_Refused,
	pool_bytes_max:       u64, // what the buffer of a pool may take, as if the GPU had no more; 0: what the GPU gives

	instances:            [dynamic]Gpu_Instance,
	instance_next:        [dynamic]i32,
	instance_prev:        [dynamic]i32, // the one before in the list of its mesh, -1 for the first: an instance leaves it at once
	overlays:             [dynamic]Instance_Overlays, // parallel to instances; never ray instances
	overlay_count:        int,
	// Opaque instances that need stored F0/F90, and those that need the
	// layers of their materials too; checked against the camera frustum
	// without walking their materials on every frame.
	reflective:           [dynamic]Reflective_Instance,
	materials:            [dynamic]Gpu_Material_Row, // the material table; row 0 is the default
	program_rows:         [POINTS_PROGRAM_CAPACITY]u32, // rows of the table of each Surface program, by id
	programs_used:        u32, // ids with rows there
	programmed_rows:      u32, // rows with a Surface program
	programmed_glass:     u32, // and of them, blended ones
	materials_dirty:      bool,                      // the whole table goes to the GPU
	material_ranges:      [dynamic]Pool_Range,       // else the rows that changed since the last upload
	material_capacity:    int,
	smoothest:            f32, // lowest roughness a material of the table can have
	instance_keys:        [dynamic]Instance_Key,
	desc_instance:        [dynamic]i32, // Instance_Desc index of the last scene_set -> instance index, -1 if skipped
	highlighted:          int,          // instances with a highlight level
	previous:             map[Instance_Key]Gpu_Instance, // the instances before scene_set, by identity
	displaced:            map[Instance_Key]Mesh_Handle, // the poses of the instances whose material programs move their vertices (displace.odin)
	displaced_stale:      bool, // an instance may need a pose it lacks or have one it no longer needs: displaced_reconcile
	material_versions:    [dynamic]u32, // of each row of the table, counted up whenever its values change
	tlas_nodes:           [dynamic]Gpu_Bvh_Node,
	tlas_refs:            [dynamic]u32,
	tlas_off:             bool, // rays are traced by hardware: the tree of the instances is not kept, and stays stale until they are not
	tlas_items:           [dynamic]Bvh_Item,
	tlas_scratch:         [dynamic]Bvh_Item,         // the items of the instances and of the batches rays meet, while the tree is built
	hw_instances:         [dynamic]rhi.Tlas_Instance, // of the native TLAS, one by instance; their BLAS when it is built (tlas_instances_record)
	instances_dirty:      bool,
	touched:              [dynamic]u64, // a bit by instance that goes to the GPU alone: changed since the last upload, or drawn in motion by it
	touched_count:        int,
	hidden_count:         int,          // instances of the set that are hidden
	tlas_nodes_dirty:     bool,         // the nodes changed and the instances did not: a move
	tlas_refs_dirty:      bool,         // with them, their references: the tree was built again
	tlas_cost:            f32,          // of the tree when it was built: tlas_refit
	tlas_stale:           bool,         // instances came or went: the tree is built again before the frame uploads it (tlas_settle)
	tlas_moved:           bool,         // boxes changed: the tree is refit before the frame uploads it
	tlas_classify:        bool,         // what rays see of instances changed: their references are classified again
	instance_capacity:    int,
	candidate_capacity:   int, // of the candidates: one per instance and per slot of a batch
	tlas_node_capacity:   int,
	tlas_ref_capacity:    int,
	tlas_node_count:      int, // nodes of the tree in tlas_nodes; the glass instances are listed after them, a box each
	glass_node_count:     int,
	instance_buffer:      rhi.Buffer,
	material_buffer:      rhi.Buffer,
	tlas_node_buffer:     rhi.Buffer,
	tlas_ref_buffer:      rhi.Buffer,
	cull_state_buffer:    rhi.Buffer, // Gpu_Cull_State of the view being culled: the draws of its phases and what its passes count
	chunk_buffer:         rhi.Buffer, // the chunks the instance pass hands the cluster pass
	visible_buffer:       rhi.Buffer, // the visible clusters of both phases
	cluster_candidate_buffer: rhi.Buffer, // the clusters phase 0 found hidden
	program_bins:         rhi.Buffer, // the visible clusters of Surface programs as the cull lists them, their counts by program and the draws of each (cull_programs.slang)
	program_visible:      rhi.Buffer, // and the same, by program: the list those draws read
	cull_capacity:        [Cull_List]u32, // of those lists, in entries
	cull_wanted:          [Cull_List]u32, // what a frame that dropped asked for: they grow to it
	candidate_buffer:     rhi.Buffer, // per instance and slot of a batch: rejected by the phase 0 occlusion test
	batch:                Batch_State,
	tlas:                 rhi.Accel,
	tlas_capacity:        u32,
	tlas_instance_buffer: rhi.Buffer, // rhi.Tlas_Instance of the native TLAS, tlas_capacity: those of the scene, then of the batches rays meet
	tlas_dirty:           bool,

	lights:               [dynamic]Gpu_Light,
	light_tree:           [dynamic]Gpu_Light_Node, // the lights by groups of neighbors (light_tree.odin)
	light_keys:           [dynamic]Light_Key,
	light_leaves:         [dynamic]u32, // of each light, its leaf in light_tree, or LIGHT_TREE_NONE
	light_tree_cost:      f64,          // of the tree now (light_tree_cost)
	light_tree_built:     f64,          // of the tree when it was built
	light_capacity:       int,
	light_tree_capacity:  int,
	light_buffer:         rhi.Buffer,
	light_tree_buffer:    rhi.Buffer,
	lights_dirty:         bool,               // every light and node goes to the GPU
	light_ranges:         [dynamic]Pool_Range, // else the lights that changed since the last upload
	light_node_ranges:    [dynamic]Pool_Range, // and the nodes of the tree
	lights_changed:       bool, // scene_set_lights ran since the last frame began
	light_region:         Light_Region, // lights a pass writes on the GPU, in the room before the tree (light_region_first)
	light_region_written: bool, // by a pass of the frame before (pass_lights)
	light_revision:       u64,  // counts the sets of lights: an index means the same light while it holds
	light_scale:          f32,  // render units per nit (light_scale_of)
	light_key:            f32,  // of the local lights alone (light_key)
	exposure:             Exposure, // of the views whose camera has no exposure of its own (Exposure.own)
	changes:              Light_Changes, // where the light of the world changed since the GI last looked
	occluders:            Occluder_Changes, // what casts shadows and changed since the last frame drew the scene
	sun:                  Sun_Desc,
	environment:          Environment,

	bounds_min:           Vec3,
	bounds_max:           Vec3,
	has_bounds:           bool,
	triangle_total:       u64,
	ray_cut_eye:          Vec3, // where the eye was when the cuts rays trace were chosen (ray_cuts_update)
	ray_cut_frame:        u64,  // and the frame
	ray_cuts_stale:       bool, // the instances changed since
	pages:                Pages_State, // the slots of the pages of streamed meshes
	uploads:              Geometry_Uploads, // meshes whose geometry goes to the GPU over frames (geometry_uploads.odin)
}

// The tables of the scene grow in the allocator of the renderer. False
// without memory for the lists of a fixed size.
@(private)
scene_init :: proc(r: ^Renderer) -> bool {
	s := &r.scene
	a := r.allocator
	s.vertices = make([dynamic]u32, a)
	s.indices = make([dynamic]u32, a)
	s.meshes = make([dynamic]Mesh_Record, a)
	s.skinned = make([dynamic]Mesh_Handle, a)
	s.blas_nodes = make([dynamic]Gpu_Bvh_Node, a)
	s.blas_triangles = make([dynamic]Gpu_Bvh_Triangle, a)
	s.free_meshes = make([dynamic]u32,a)
	s.pages.streamed = make([dynamic]u32, a)
	s.light_scale = 1
	// An empty table has no smooth material.
	s.smoothest = 1
	for &ranges in s.pool_free {ranges=make([dynamic]Pool_Range,a)}
	for &ranges in s.pool_dirty {ranges=make([dynamic]Pool_Range,a)}
	s.mesh_dirty=make([dynamic]Pool_Range,a)
	s.translucent = make([dynamic]Translucent, a)
	s.instances = make([dynamic]Gpu_Instance, a)
	s.instance_next=make([dynamic]i32,a)
	s.instance_prev=make([dynamic]i32,a)
	s.overlays = make([dynamic]Instance_Overlays, a)
	s.reflective = make([dynamic]Reflective_Instance, a)
	s.materials = make([dynamic]Gpu_Material_Row, a)
	errors: [3]mem.Allocator_Error
	s.material_ranges, errors[0] = make([dynamic]Pool_Range, 0, MATERIAL_RANGES_MAX + 1, a)
	s.instance_keys = make([dynamic]Instance_Key, a)
	s.desc_instance = make([dynamic]i32, a)
	s.previous = make(map[Instance_Key]Gpu_Instance, a)
	s.displaced = make(map[Instance_Key]Mesh_Handle, a)
	s.material_versions = make([dynamic]u32, a)
	s.tlas_nodes = make([dynamic]Gpu_Bvh_Node, a)
	s.tlas_refs = make([dynamic]u32, a)
	s.tlas_items = make([dynamic]Bvh_Item, a)
	s.tlas_scratch = make([dynamic]Bvh_Item, a)
	batches_init(r)
	s.touched = make([dynamic]u64, a)
	s.hw_instances = make([dynamic]rhi.Tlas_Instance, a)
	s.lights = make([dynamic]Gpu_Light, a)
	s.light_tree = make([dynamic]Gpu_Light_Node, a)
	s.light_keys = make([dynamic]Light_Key, a)
	s.light_leaves = make([dynamic]u32, a)
	// A refit adds a path of the tree before the ranges are counted.
	s.light_ranges, errors[1] = make([dynamic]Pool_Range, 0, LIGHT_RANGES_MAX + LIGHT_TREE_DEPTH + 1, a)
	s.light_node_ranges, errors[2] = make([dynamic]Pool_Range, 0, LIGHT_RANGES_MAX + LIGHT_TREE_DEPTH + 1, a)
	return errors == {}
}

// ---------------------------------------------------------------- materials

MATERIAL_RANGES_MAX :: 64 // rows that go to the GPU in ranges; past them the whole table goes

@(private)
gpu_material :: proc(r: ^Renderer, m: Material_Desc) -> Gpu_Material_Row {
	mode, opacity := m.alpha_mode, clamp(m.opacity, 0, 1)
	transmission := clamp(m.transmission, 0, 1) if mode != .Mask else 0
	// The opacity of an opaque material is not a filter: its glass passes its base color.
	if transmission > 0 && mode == .Opaque {mode, opacity = .Blend, 1}
	result := Gpu_Material_Row{
		shared = {
			base_color = m.base_color, opacity = opacity,
			emission = m.emission, normal_scale = m.normal_scale,
			roughness = clamp(m.roughness, 0, 1), metallic = clamp(m.metallic, 0, 1),
			occlusion_strength = clamp(m.occlusion_strength, 0, 1), alpha_cutoff = clamp(m.alpha_cutoff, 0, 1),
			specular_color = linalg.clamp(m.specular_color, 0, 1), specular_factor = m.specular_factor,
			transmission = transmission, ior = max(m.ior, 0), thickness = max(m.thickness, 0), attenuation_distance = max(m.attenuation_distance, 0),
			attenuation_color = {clamp(m.attenuation_color.x, 0, 1), clamp(m.attenuation_color.y, 0, 1), clamp(m.attenuation_color.z, 0, 1)},
			alpha_mode = u32(mode), emission_mode = u32(m.emission_mode), program_id = m.program_id,
		},
		custom_params = m.custom_params,
	}
	if transmission > 0 && m.thickness > 0 {result.volume.scatter = linalg.clamp(m.scatter_color, 0, 1)}
	info := m.info
	layers := asset.material_layers(&info)
	// A program gives the layers its source writes; the row holds the values
	// of those it does not.
	if m.program_id != 0 {
		for program in renderer_programs(r) {
			if program.id == m.program_id && program.domain == .Surface {layers += program.layers}
		}
	}
	result.layers = transmute(u32)layers
	if .Coat in layers {
		c := m.coat
		result.coat = {color = linalg.clamp(c.color, 0, 1), weight = clamp(c.weight, 0, 1), roughness = clamp(c.roughness, 0, 1), ior = max(c.ior, 1), normal_scale = c.normal_scale}
	}
	if .Fuzz in layers {
		f := m.fuzz
		result.fuzz = {color = linalg.clamp(f.color, 0, 1), weight = clamp(f.weight, 0, 1), roughness = clamp(f.roughness, 0, 1)}
	}
	if .Anisotropy in layers {
		result.anisotropy = {amount = clamp(m.anisotropy.amount, 0, 1), rotation = {math.cos(m.anisotropy.rotation), math.sin(m.anisotropy.rotation)}}
	}
	if .Diffuse_Transmission in layers {
		d := m.diffuse_transmission
		result.diffuse_transmission = {color = linalg.clamp(d.color, 0, 1), weight = clamp(d.weight, 0, 1)}
	}
	maps := m.maps
	placed := asset.material_maps(&maps)
	for transform, kind in placed {
		result.textures[kind] = texture_index(r, m.textures[kind])
		// rotation * (scale_map * (scale * uv + offset)) + offset_map, as one matrix and one offset.
		sine, cosine := math.sin(transform.rotation), math.cos(transform.rotation)
		scale := m.uv_scale * transform.scale
		shift := m.uv_offset * transform.scale
		result.map_transforms[kind] = {
			linear = {cosine * scale.x, -sine * scale.y, sine * scale.x, cosine * scale.y},
			offset = {cosine * shift.x - sine * shift.y + transform.offset.x, sine * shift.x + cosine * shift.y + transform.offset.y},
			uv_set = transform.uv_set,
			ray_lod = 0.5 * math.log2(max(abs(scale.x * scale.y), 1e-12)),
		}
	}
	// The usual packing of glTF: occlusion in the red of the metallic-roughness
	// texture. Placed the same way, the shader reads it from that sample.
	if packed := m.textures[.Occlusion]; packed != 0 && packed == m.textures[.Metallic_Roughness] && placed[.Occlusion] == placed[.Metallic_Roughness] {
		result.textures[.Occlusion] = GPU_OCCLUSION_PACKED
	}
	return result
}

// Replaces the material table: materials[i] becomes row i + 1, and row 0 stays
// the default material. Vertices and instances name rows, so while meshes are
// resident the table only grows or changes the values of its rows. Only the
// rows whose values differ go to the GPU, with the next frame, and they keep
// the BLASes, the TLAS and the light list (materials_store). False without
// memory for the rows: the table stays as it was.
materials_set :: proc(r: ^Renderer, materials: []Material_Desc) -> bool {
	s := &r.scene
	// Rows that vertices may still name keep existing, as the default material.
	rows := max(len(s.materials), len(materials) + 1)
	changes := materials_grow(r, rows) or_return
	for row in 1 ..< rows {
		material_store(s, u32(row), gpu_material(r, materials[row - 1] if row <= len(materials) else DEFAULT_MATERIAL), &changes)
	}
	materials_changed(s, changes)
	return true
}

// Gives some rows of the table the values they have in materials, as
// materials_set reads it: row n takes materials[n - 1]. The other rows are
// not looked at. False without memory for the rows: the table stays as it was.
materials_update :: proc(r: ^Renderer, materials: []Material_Desc, rows: []u32) -> bool {
	s := &r.scene
	last := 0
	for row in rows {if row > 0 && int(row) <= len(materials) {last = max(last, int(row))}}
	changes := materials_grow(r, last + 1) or_return
	for row in rows {
		if row == 0 || int(row) > len(materials) {continue}
		material_store(s, row, gpu_material(r, materials[row - 1]), &changes)
	}
	materials_changed(s, changes)
	return true
}

// What some rows that changed values change for the rest of the scene.
@(private = "file")
Material_Changes :: struct {
	lit:       [MATERIAL_LIT_ROWS]u32, // rows whose light changed (material_lit)
	lit_count: int,                    // past MATERIAL_LIT_ROWS the light changed everywhere
	class:     bool, // how their instances are traced and drawn (material_class)
	smoothest: bool, // the smoothest row of the table may be another
}

MATERIAL_LIT_ROWS :: 16

// The table holds at least rows rows: the new ones are the default material.
// False without memory for them, with the error set and the table as it was.
@(private = "file")
materials_grow :: proc(r: ^Renderer, rows: int) -> (changes: Material_Changes, ok: bool) {
	s := &r.scene
	if len(s.materials) >= rows {return {}, true}
	if reserve(&s.materials, max(rows, 2 * cap(s.materials)) if rows > cap(s.materials) else rows) != nil || resize(&s.material_versions, rows) != nil {
		set_error(r, "material table of %d rows: out of memory", rows)
		return {}, false
	}
	if len(s.materials) == 0 {
		append(&s.materials, gpu_material(r, DEFAULT_MATERIAL))
		s.materials_dirty = true
	}
	for len(s.materials) < rows {
		material_range_add(s, u32(len(s.materials)))
		append(&s.materials, gpu_material(r, DEFAULT_MATERIAL))
	}
	changes.smoothest = true
	return changes, true
}

// One row takes a value. Equal values change nothing; other ones go to the
// GPU alone, as a range of the table.
@(private = "file")
material_store :: proc(s: ^Scene_State, row: u32, value: Gpu_Material_Row, changes: ^Material_Changes) {
	held := &s.materials[row]
	if held^ == value {return}
	if material_lit(held^) != material_lit(value) {
		if changes.lit_count < MATERIAL_LIT_ROWS {changes.lit[changes.lit_count] = row}
		changes.lit_count += 1
	}
	changes.class ||= material_class(held^) != material_class(value)
	changes.smoothest ||= material_smoothness(value) < s.smoothest || material_smoothness(held^) == s.smoothest
	if held.program_id != value.program_id || held.alpha_mode != value.alpha_mode {
		program_rows_count(s, held^, false)
		program_rows_count(s, value, true)
	}
	held^ = value
	if int(row) < len(s.material_versions) {s.material_versions[row] += 1}
	material_range_add(s, row)
}

@(private = "file")
program_rows_count :: proc(s: ^Scene_State, row: Gpu_Material_Row, added: bool) {
	program := row.program_id
	if program == 0 {return}
	if added {s.programmed_rows += 1} else {s.programmed_rows -= 1}
	if row.alpha_mode == u32(asset.Alpha_Mode.Blend) {
		if added {s.programmed_glass += 1} else {s.programmed_glass -= 1}
	}
	if program >= POINTS_PROGRAM_CAPACITY {return}
	if added {s.program_rows[program] += 1} else {s.program_rows[program] -= 1}
	if s.program_rows[program] == (1 if added else 0) {
		if added {s.programs_used += 1} else {s.programs_used -= 1}
	}
}

// Past MATERIAL_RANGES_MAX ranges the whole table goes, which costs less.
@(private = "file")
material_range_add :: proc(s: ^Scene_State, row: u32) {
	if s.materials_dirty {return}
	if len(s.material_ranges) == MATERIAL_RANGES_MAX {
		s.materials_dirty = true
		clear(&s.material_ranges)
		return
	}
	range_add(&s.material_ranges, {row, 1})
}

// The light changed around what shows rows that changed what it sees, as
// around an instance scene_tint gives another color: each instance that
// shows one in a slot or a layer, and each rectangle of light that shows its
// emission. Past LIGHT_CHANGES_MAX places it changed everywhere.
@(private = "file")
materials_lit :: proc(s: ^Scene_State, rows: []u32) {
	shows :: proc "contextless" (rows: []u32, row: u32) -> bool {
		for changed in rows {if changed == row {return true}}
		return false
	}
	each: for &inst, i in s.instances {
		if inst.meta.w & INSTANCE_FLAG_HIDDEN != 0 || int(inst.meta.x & INSTANCE_MESH_MASK) >= len(s.meshes) {continue}
		mesh := s.meshes[inst.meta.x & INSTANCE_MESH_MASK]
		found := false
		for packed in s.indices[mesh.slot_word:][:mesh.slot_count] {
			if shows(rows, instance_row(packed, inst.meta.y, &inst.slot_materials)) {found = true;break}
		}
		for layer in s.overlays[i].entries[:s.overlays[i].count] {
			if layer.enabled && shows(rows, u32(layer.material)) {found = true}
		}
		if !found {continue}
		scene_changed_near(s, (inst.bounds_min.xyz + inst.bounds_max.xyz) * 0.5, linalg.length(inst.bounds_max.xyz - inst.bounds_min.xyz) * 0.5 + LIGHT_CHANGE_REACH)
		if s.changes.all {return}
	}
	for light in s.lights {
		if light.direction_cone.w == GPU_LIGHT_RECT && shows(rows, transmute(u32)light.size.w) {scene_changed_near(s, light.position_range.xyz, light.position_range.w)}
	}
}

// The row of the table a material word of a mesh names in an instance: its
// slot in the palette of the instance, else the material that replaces those
// of the mesh (GPU_NONE: none), else the row of the word.
@(private)
instance_row :: #force_inline proc "contextless" (packed, material: u32, palette: ^[32]u32) -> u32 {
	slot := packed >> 24
	if slot > 0 && slot <= 32 && palette[slot - 1] != 0 {return palette[slot - 1] - 1}
	if material != GPU_NONE {return material}
	return packed & 0xffffff
}

// What the light of the world sees of a row: all of it but what only a view
// reads, the strength of its occlusion and, without a program, its normal map,
// which the diffuse rays of the GI average away.
@(private = "file")
material_lit :: proc "contextless" (row: Gpu_Material_Row) -> Gpu_Material_Row {
	seen := row
	seen.occlusion_strength = 0
	if seen.program_id == 0 {
		seen.normal_scale = 0
		seen.textures[.Normal] = GPU_NONE
		seen.map_transforms[.Normal] = {}
	}
	return seen
}

// What of a row decides how the instances that show it are traced and drawn (instance_alpha).
@(private = "file")
Material_Class :: struct {
	alpha_mode, program_id, layers: u32,
	specular_color:                 Vec3,
	specular_factor, ior:           f32,
	specular, specular_colored:     u32,
}

@(private = "file")
material_class :: proc "contextless" (row: Gpu_Material_Row) -> Material_Class {
	return {
		alpha_mode = row.alpha_mode, program_id = row.program_id, layers = row.layers,
		specular_color = row.specular_color, specular_factor = row.specular_factor, ior = row.ior,
		specular = row.textures[.Specular], specular_colored = row.textures[.Specular_Color],
	}
}

// Grows the table with the default material up to row, as the slots of a mesh that name rows past it ask.
// False without memory for them, with the error set and the table as it was.
@(private)
materials_reach :: proc(r: ^Renderer, row: u32) -> bool {
	s := &r.scene
	rows := max(len(s.materials), int(row) + 1)
	if reserve(&s.materials, max(rows, 2 * cap(s.materials)) if rows > cap(s.materials) else rows) != nil || resize(&s.material_versions, rows) != nil {
		set_error(r, "material table of %d rows: out of memory", rows)
		return false
	}
	for int(row) >= len(s.materials) {
		value := gpu_material(r, DEFAULT_MATERIAL)
		append(&s.materials, value)
		s.smoothest = min(s.smoothest, material_smoothness(value))
		s.materials_dirty = true
	}
	return true
}

// The lowest roughness a row can have: a roughness texture or a Surface
// program can make a mirror regardless of the roughness stored in it.
@(private = "file")
material_smoothness :: proc "contextless" (row: Gpu_Material_Row) -> f32 {
	return 0 if row.program_id != 0 || row.textures[.Metallic_Roughness] != GPU_NONE else row.roughness
}

@(private = "file")
materials_changed :: proc(s: ^Scene_State, changes: Material_Changes) {
	changes := changes
	if changes.lit_count > MATERIAL_LIT_ROWS {scene_changed(s)} else if changes.lit_count > 0 {materials_lit(s, changes.lit[:changes.lit_count])}
	if changes.smoothest {
		s.smoothest = 1
		for m in s.materials {s.smoothest = min(s.smoothest, material_smoothness(m))}
	}
	// The alpha mode of a material decides how its instances are traced and drawn,
	// and its program whether they move their vertices.
	if changes.class {instances_classify(s);s.displaced_stale=true}
	// The rows of the batches take the classes of their materials when they are built.
	if changes.class {s.batch.built = false}
}

// The instances that reflect and those with glass, and how rays see each, from
// their materials and whether they are hidden.
@(private = "file")
instances_classify :: proc(s: ^Scene_State) {
	clear(&s.translucent)
	clear(&s.reflective)
	for &inst, i in s.instances {
		if int(inst.meta.x & INSTANCE_MESH_MASK) >= len(s.meshes) {continue}
		tested, blended, glass, reflectance, layered, solid, glass_layered := instance_alpha(s, s.meshes[inst.meta.x & INSTANCE_MESH_MASK], inst.meta.y, inst.slot_materials)
		flags := (inst.meta.w &~ (INSTANCE_FLAG_ALPHA_TESTED | INSTANCE_FLAG_BLENDED | INSTANCE_FLAG_TRANSLUCENT)) | alpha_flags(tested, blended, glass)
		if reflectance && flags & INSTANCE_FLAG_HIDDEN == 0 {append(&s.reflective, Reflective_Instance{u32(i), layered})}
		if flags != inst.meta.w {
			inst.meta.w = flags
			s.hw_instances[i].mask_flags = tlas_mask_flags(ray_class(flags), tested)
			s.instances_dirty = true
			s.tlas_dirty = true
		}
		if blended && flags & INSTANCE_FLAG_HIDDEN == 0 {append(&s.translucent, Translucent{instance = u32(i), solid = solid, layered = glass_layered})}
	}
	overlay_count_update(s)
	tlas_refs_classify(s)
}

// Marks the references of the instances that are glass for rays.
@(private = "file")
tlas_refs_classify :: proc(s: ^Scene_State) {
	if s.tlas_off {return}
	s.glass_node_count = 0
	if len(s.instances) == 0 || s.tlas_node_count == 0 {return}
	for &ref in s.tlas_refs {
		index := ref &~ TLAS_REF_GLASS
		if int(index) >= len(s.instances) {continue}
		ref = index | (TLAS_REF_GLASS if s.instances[index].meta.w & INSTANCE_FLAG_BLENDED != 0 else 0)
	}
	// A ray that only looks for glass tests these boxes, usually a handful,
	// instead of walking the whole tree: left_first is the instance.
	base.truncate(&s.tlas_nodes, s.tlas_node_count)
	for inst, i in s.instances {
		if inst.meta.w & INSTANCE_FLAG_BLENDED != 0 && inst.meta.w & INSTANCE_FLAG_HIDDEN == 0 {
			append(&s.tlas_nodes, Gpu_Bvh_Node{bounds_min = inst.bounds_min.xyz, left_first = u32(i), bounds_max = inst.bounds_max.xyz, count = 1})
			s.glass_node_count += 1
		}
	}
}

// Whether rays have to ask the materials of an instance, whether some of its
// triangles are blended, and whether all of them are. material is the row
// that replaces those of the mesh, or GPU_NONE.
@(private)
// reflectance: one of its opaque materials reflects other than the default
// dielectric, which the albedo and metallic of the G-buffer give by themselves.
// glass_layered: one of its blended materials has layers.
instance_alpha :: proc(s: ^Scene_State, mesh: Mesh_Record, material: u32, slots:[32]u32) -> (tested, blended, glass, reflectance, layered, solid, glass_layered: bool) {
    palette:=slots
    defaults:=asset.MATERIAL_DEFAULTS
    glass = mesh.slot_count > 0
    for packed in s.indices[mesh.slot_word:][:mesh.slot_count] {
        row:=instance_row(packed,material,&palette)
        m:=asset.Alpha_Mode.Opaque
        if int(row)<len(s.materials) {
            values:=&s.materials[row]
            m=asset.Alpha_Mode(values.alpha_mode)
            departs:=values.program_id!=0 || values.specular_color!=defaults.specular_color || values.specular_factor!=defaults.specular_factor || values.ior!=defaults.ior
            if m != .Blend && (departs || values.textures[.Specular]!=GPU_NONE || values.textures[.Specular_Color]!=GPU_NONE) {reflectance=true}
            lit:=transmute(asset.Material_Layers)values.layers-{.Unlit}
            if card(lit)>0 {
                if m == .Blend {glass_layered=true} else {layered=true}
            }
        }
        tested ||= m != .Opaque
        blended ||= m == .Blend
        if m == .Blend && int(row)<len(s.materials) {solid ||= s.materials[row].transmission > 0 && s.materials[row].thickness > 0}
        glass &&= m == .Blend
    }
    // The layers of a material reach the G-buffer with its reflectance.
    reflectance ||= layered
    return
}

@(private)
alpha_flags :: proc "contextless" (tested, blended, glass: bool) -> u32 {
	return (INSTANCE_FLAG_ALPHA_TESTED if tested else 0) | (INSTANCE_FLAG_TRANSLUCENT if blended else 0) | (INSTANCE_FLAG_BLENDED if glass else 0)
}

@(private = "file")
instance_small :: proc "contextless" (low, high: Vec3) -> u32 {
	return INSTANCE_FLAG_SMALL if linalg.length(high - low) * 0.5 <= SMALL_INSTANCE_REACH else 0
}

// The class of rays an instance meets follows its box, which a move or a pose changes.
@(private)
instance_resized :: proc(s: ^Scene_State, index: int, low, high: Vec3) {
	inst := &s.instances[index]
	inst.meta.w = (inst.meta.w & ~u32(INSTANCE_FLAG_SMALL)) | instance_small(low, high)
	hw := &s.hw_instances[index]
	hw.mask_flags = tlas_mask_flags(ray_class(inst.meta.w), hw.mask_flags & rhi.TLAS_ALPHA_TESTED != 0)
}

@(private = "file")
ray_class :: proc "contextless" (flags: u32) -> u8 {
	if flags & INSTANCE_FLAG_HIDDEN != 0 {return 0}
	if flags & INSTANCE_FLAG_BLENDED != 0 {return RAY_GLASS}
	return RAY_SMALL if flags & INSTANCE_FLAG_SMALL != 0 else RAY_SOLID
}

// ---------------------------------------------------------------- meshes

// Drops every mesh (scene reload). Instances referencing old handles must be
// replaced with scene_set before the next frame.
meshes_clear :: proc(r: ^Renderer) {
	s := &r.scene
	scene_changed(s)
	for &m in s.meshes {
		skin_free(r,m.skin);skin_binding_release(r,m.skin_binding)
		for ray in m.rays[:m.ray_count] {if ray.blas != 0 {rhi.accel_destroy(r.device, ray.blas)}}
	}
	clear(&s.vertices)
	clear(&s.indices)
	clear(&s.meshes)
	clear(&s.skinned)
	clear(&s.displaced)
	clear(&s.blas_nodes)
	clear(&s.blas_triangles)
	clear(&s.free_meshes)
	for &ranges in s.pool_free {clear(&ranges)}
	for &ranges in s.pool_dirty {clear(&ranges)}
	clear(&s.mesh_dirty)
	geometry_uploads_cancel(s)
	scene_instances_clear(s)
	batches_clear(s)
	s.triangle_total = 0
	s.geometry_dirty = true
	s.instances_dirty = true
	s.tlas_dirty = true
}

mesh_count :: proc(r: ^Renderer) -> int {return len(r.scene.meshes)-len(r.scene.free_meshes)}

// Grows a GPU buffer geometrically; reports whether it was recreated (its
// previous contents are gone and must be uploaded again).
@(private)
ensure_buffer :: proc(r: ^Renderer, buffer: ^rhi.Buffer, size: u64, usage: rhi.Buffer_Usage, name: string,memory:rhi.Memory=.GPU) -> (ok, recreated: bool) {
	needed := max(size, 256)
	if buffer^ != 0 && rhi.buffer_size(r.device, buffer^) >= needed {return true, false}
	if buffer^ != 0 {rhi.buffer_destroy(r.device, buffer^)}
	buffer^ = rhi.buffer_create(r.device, {size = needed + needed / 2, usage = usage, memory = memory, name = name})
	return buffer^ != 0, true
}

@(private)
slice_bytes :: proc(data: []$T) -> []u8 {
	return ([^]u8)(raw_data(data))[:len(data) * size_of(T)]
}

@(private)
geometry_copies_add :: proc(r:^Renderer,copies:^[dynamic]Geometry_Copy,buffer:rhi.Buffer,data:[]$T,dirty:[]Pool_Range,offset:u64=0) -> bool {
    #assert(size_of(T)%4==0)
    for range in dirty {
        first,count:=int(range.first),int(range.count)
        if first>=len(data) {continue}
        count=min(count,len(data)-first)
        if _,error:=append(copies,Geometry_Copy{buffer,offset+u64(first*size_of(T)),slice_bytes(data[first:][:count])});error!=nil {set_error(r,"geometry copy allocation failed");return false}
    }
    return true
}

@(private)
geometry_mesh_copies_add :: proc(r:^Renderer,copies:^[dynamic]Geometry_Copy) -> bool {
    s:=&r.scene
    for range in s.mesh_dirty {
        first,count:=int(range.first),int(range.count)
        if first>=len(s.meshes) {continue}
        count=min(count,len(s.meshes)-first)
        rows,error:=make([]Gpu_Mesh,count,context.temp_allocator)
        if error!=nil {set_error(r,"geometry mesh rows allocation failed");return false}
        for m,i in s.meshes[first:][:count] {
            rows[i]=gpu_mesh(m)
        }
        if !geometry_copies_add(r,copies,s.mesh_buffer,rows,{{0,u32(count)}},u64(first*size_of(Gpu_Mesh))) {return false}
    }
    return true
}

@(private)
geometry_blases_discard :: proc(r:^Renderer,pending:[]rhi.Accel) {
    s:=&r.scene
    for &mesh in s.meshes {
        for &ray in mesh.rays[:mesh.ray_count] {
            for blas in pending {if ray.blas==blas {rhi.accel_destroy(r.device,blas);ray.blas=0;break}}
        }
    }
}

// The inputs of the BLAS of the cuts that lack one, in the pools before they
// are published: what geometry_blases_prepare builds them from. In a frame,
// those of a mesh larger than a frame uploads go with the uploads of the
// frames. Whether cuts are left for the publications after it.
@(private)
geometry_blas_inputs :: proc(r:^Renderer,frame:bool) -> (left:bool) {
    if !r.hardware_rt {return}
    s:=&r.scene
    // After a BLAS the GPU had no memory for, none is made until enough goes.
    if s.blas_refused.bytes!=0 && s.released-s.blas_refused.released<max(s.blas_refused.bytes,POOL_RETRY_BYTES) {return}
    s.blas_refused={}
    triangles:=0
    // Room for what a frame adds, grown by doubling: blas_inputs_add makes room for each mesh, and
    // one pool made again for each would copy it whole each time. Without memory for it each mesh
    // still asks for its own room, and waits when there is none.
    grow :: proc(pool:^[dynamic]u32,more:int) -> bool {return len(pool)+more<=cap(pool) || reserve(pool,max(len(pool)+more,2*cap(pool)))==nil}
    _=grow(&s.vertices,BLAS_INPUT_TRIANGLES*9)
    _=grow(&s.indices,BLAS_INPUT_TRIANGLES*3)
    for &m,index in s.meshes {
        // The BLAS of a mesh whose geometry goes over frames is built once it went.
        if m.vertex_count==0 || mesh_pending(s,u32(index)) {continue}
        missing:=false
        for ray,k in m.rays[:m.ray_count] {missing||=ray.blas==0 && ray.input_indices==0 && ray_cut_wanted(r,m,k)}
        if !missing {continue}
        // A frame takes the inputs of BLAS_INPUT_TRIANGLES at most, the first mesh whatever it has: the
        // others wait for the frames that follow. A mesh without its tables yet counts its triangles.
        tables:=m.rays[0].table_count>0
        cost:=blas_inputs_cost(r,&m) if tables else int(m.triangle_count)
        if tables && cost==0 {continue}
        if triangles>0 && triangles+cost>BLAS_INPUT_TRIANGLES {left=true;continue}
        if !tables && !mesh_rays_complete(r,u32(index)) {continue}
        queued:=frame && blas_inputs_over(r,&m)
        if queued && !mesh_upload_room(r) {left=true;continue}
        // The pools have no room: the next publication after enough goes tries again.
        if _,ok:=blas_inputs_add(r,&m,queued);!ok {s.blas_refused={u64(max(cost,1))*BLAS_TRIANGLE_BYTES,0,s.released};break}
        if queued {blas_inputs_queue(r,u32(index))}
        triangles+=max(cost,1)
        range_add(&s.mesh_dirty,{u32(index),1})
    }
    return
}

BLAS_INPUT_TRIANGLES :: 1<<18 // of the meshes whose native BLAS a frame builds, before the next mesh waits

@(private)
geometry_blases_prepare :: proc(r:^Renderer,pending:^[dynamic]rhi.Accel) -> bool {
    if !r.hardware_rt {return true}
    s:=&r.scene
    for &m,index in s.meshes {
        if m.vertex_count==0 || inputs_queued(s,u32(index)) {continue}
        for &ray in m.rays[:m.ray_count] {
            if ray.blas!=0 || ray.input_indices==0 {continue}
            blas:=rhi.blas_create(r.device,blas_desc(r,m,ray))
            if blas==0 {
                // Its inputs wait in the pools, and the mesh is drawn without being traced.
                s.blas_refused={u64(ray.table_count)*BLAS_TRIANGLE_BYTES,0,s.released}
                return true
            }
            if _,error:=append(pending,blas);error!=nil {rhi.accel_destroy(r.device,blas);set_error(r,"geometry BLAS list allocation failed");return false}
            ray.blas=blas
            // The instances that wait for this cut take it.
            if ray.error>0 {s.ray_cuts_stale=true}
        }
    }
    return true
}

// Copies the ranges through the staging buffer of the slot and builds the
// BLASes: in cmd, the list of the frame, whose passes read them after it; or,
// without one, in a list of their own that the CPU waits for, through the
// staging buffer no frame in flight reads.
@(private)
geometry_copies_commit :: proc(r:^Renderer,copies:[]Geometry_Copy,pending:[]rhi.Accel,cmd:^rhi.Command_List=nil,slot:=0) -> bool {
    s:=&r.scene
    staging:=&s.geometry_staging[slot if cmd!=nil else rhi.MAX_FRAMES_IN_FLIGHT]
    required:u64
    for copy in copies {
        if required>max(u64)-15 {set_error(r,"geometry staging size overflow");return false}
        required=(required+15)&~u64(15)
        if u64(len(copy.bytes))>max(u64)-required {set_error(r,"geometry staging size overflow");return false}
        required+=u64(len(copy.bytes))
    }
    // The staging of a load as large as a level lives in the memory of the
    // host, and goes once a publication needs a quarter of it.
    if staging^!=0 && rhi.buffer_size(r.device,staging^)>max(4*required,GEOMETRY_STAGING_KEPT) {rhi.buffer_destroy(r.device,staging^);staging^=0}
    if required>0 {
        if ok,_:=ensure_buffer(r,staging,required,{.Transfer_Src},"geometry staging",.Staging);!ok {set_error(r,"geometry staging: %s",rhi.device_error(r.device));return false}
        mapped:=rhi.buffer_mapped(r.device,staging^)
        if mapped==nil {set_error(r,"geometry staging is not mapped");return false}
        at:u64
        for copy in copies {
            at=(at+15)&~u64(15)
            mem.copy(rawptr(uintptr(mapped)+uintptr(at)),raw_data(copy.bytes),len(copy.bytes))
            at+=u64(len(copy.bytes))
        }
    }
    if len(copies)==0 && len(pending)==0 && !pool_moves_pending(s) {return true}
    immediate:=cmd==nil
    list:=immediate?rhi.immediate_begin(r.device):cmd
    if list==nil {set_error(r,"geometry publication: %s",rhi.device_error(r.device));return false}
    pool_moves_record(r,list)
    at:u64
    for copy in copies {
        at=(at+15)&~u64(15)
        rhi.cmd_copy_buffer(list,staging^,at,copy.buffer,copy.offset,u64(len(copy.bytes)))
        at+=u64(len(copy.bytes))
    }
    for blas in pending {rhi.cmd_build_blas(list,blas)}
    if immediate {
        if !rhi.immediate_end(r.device,list) {set_error(r,"geometry publication: %s",rhi.device_error(r.device));return false}
        return true
    }
    // The passes of the frame read the pools without declaring it.
    for buffer in ([]rhi.Buffer{s.vertex_buffer,s.index_buffer,s.mesh_buffer,s.blas_node_buffer,s.blas_triangle_buffer}) {rhi.cmd_barrier_buffer(list,buffer,.Shader_Read)}
    return true
}

// Bytes of a staging buffer of the geometry kept however little a publication uploads.
GEOMETRY_STAGING_KEPT :: u64(64) << 20

// Uploads changed ranges and builds new native BLASes: at the start of the
// list of a frame (cmd, with the slot of its staging), which the CPU does
// not wait for, or between frames, waiting. A pool that grew copies its old
// buffer first (pool_room). The inputs of the BLASes the publication before
// built go back to the pools first: the GPU took them in its list. What the
// pools could not make room for waits, and the rest is published. What goes
// over frames goes with the budget of a frame; between frames all of it
// goes, and shows when it returns.
renderer_commit_geometry :: proc(r: ^Renderer, cmd: ^rhi.Command_List = nil, slot := 0) -> bool {
	s := &r.scene
	dirty := s.geometry_dirty
	if !dirty && !geometry_uploads_left(s) {return true}
	d := r.device
	blas_inputs_release(r)
	left := geometry_blas_inputs(r, cmd != nil)
	held: [Mesh_Pool]int
	for pool in Mesh_Pool {
		pool_room(r, pool, 0)
		buffer, count, element, _, _ := pool_gpu(s, pool)
		held[pool] = min(count, int(rhi.buffer_size(d, buffer^) / u64(element))) if buffer^ != 0 else 0
	}
	ok, new_meshes := ensure_buffer(r, &s.mesh_buffer, u64(len(s.meshes) * size_of(Gpu_Mesh)), {.Storage}, "meshes")
	if !ok {set_error(r, "geometry buffers: %s", rhi.device_error(d)); return false}
	if new_meshes {clear(&s.mesh_dirty);range_add(&s.mesh_dirty,{0,u32(len(s.meshes))})}
	grown := s.pools_grown
	s.pools_grown = {}
	// A BLAS a pose refits reads the pools it was made over: new ones make it again.
	for &m,index in s.meshes {
		if m.skin!=nil && grown & {.Vertex,.Node,.Triangle} != {} {m.skin.dirty=true}
		if m.skin!=nil && m.rays[0].blas!=0 && grown & {.Vertex,.Index} != {} {
			rhi.accel_destroy(d,m.rays[0].blas);m.rays[0].blas=0;range_add(&s.mesh_dirty,{u32(index),1})
		}
	}
	copies:=make([dynamic]Geometry_Copy,context.temp_allocator)
	if !geometry_copies_add(r,&copies,s.vertex_buffer,s.vertices[:held[.Vertex]],s.pool_dirty[.Vertex][:]) ||
	   !geometry_copies_add(r,&copies,s.index_buffer,s.indices[:held[.Index]],s.pool_dirty[.Index][:]) ||
	   !geometry_mesh_copies_add(r,&copies) ||
	   !geometry_copies_add(r,&copies,s.blas_node_buffer,s.blas_nodes[:held[.Node]],s.pool_dirty[.Node][:]) ||
	   !geometry_copies_add(r,&copies,s.blas_triangle_buffer,s.blas_triangles[:held[.Triangle]],s.pool_dirty[.Triangle][:]) {return false}
	queued:=s.uploads.entries
	if geometry_uploads_left(s) {
		budget:=geometry_upload_budget(s) if cmd!=nil else max(u64)
		if _,taken:=geometry_uploads_take(r,&copies,held,budget);!taken {s.uploads.entries=queued;return false}
	}
	s.uploads.textures_spent=0
	pending:=make([dynamic]rhi.Accel,context.temp_allocator)
	if !geometry_blases_prepare(r,&pending) || !geometry_copies_commit(r,copies[:],pending[:],cmd,slot) {
		geometry_blases_discard(r,pending[:])
		s.uploads.entries=queued
		return false
	}
	clear(&s.mesh_dirty)
	for &ranges, pool in s.pool_dirty {
		// What lies past the buffer of a pool that could not grow waits for room.
		_, count, _, _, _ := pool_gpu(s, pool)
		if held[pool] < count {pool_ranges_keep_past(&ranges, u32(held[pool]))} else {clear(&ranges)}
	}
	// Meshes whose BLAS waits for the budget of a frame come in the next one.
	s.geometry_dirty = left
	// What goes over frames alone is of meshes nothing draws yet.
	if dirty {
		s.tlas_dirty = true
		r.glass_stale = true
	}
	if cmd == nil {geometry_uploads_install(r)}
	return true
}

// ---------------------------------------------------------------- instances and lights

@(private)
rows_3x4 :: proc "contextless" (m: Mat4) -> [3]Vec4 {
	return {{m[0, 0], m[0, 1], m[0, 2], m[0, 3]}, {m[1, 0], m[1, 1], m[1, 2], m[1, 3]}, {m[2, 0], m[2, 1], m[2, 2], m[2, 3]}}
}

@(private)
transform_bounds :: proc "contextless" (m: Mat4, bmin, bmax: Vec3) -> (Vec3, Vec3) {
	center := (bmin + bmax) * 0.5
	extent := (bmax - bmin) * 0.5
	world_center := Vec3{
		m[0, 0] * center.x + m[0, 1] * center.y + m[0, 2] * center.z + m[0, 3],
		m[1, 0] * center.x + m[1, 1] * center.y + m[1, 2] * center.z + m[1, 3],
		m[2, 0] * center.x + m[2, 1] * center.y + m[2, 2] * center.z + m[2, 3],
	}
	world_extent := Vec3{
		abs(m[0, 0]) * extent.x + abs(m[0, 1]) * extent.y + abs(m[0, 2]) * extent.z,
		abs(m[1, 0]) * extent.x + abs(m[1, 1]) * extent.y + abs(m[1, 2]) * extent.z,
		abs(m[2, 0]) * extent.x + abs(m[2, 1]) * extent.y + abs(m[2, 2]) * extent.z,
	}
	return world_center - world_extent, world_center + world_extent
}

// The inverse of an instance's transform and its box. Without an inverse (a
// zero scale, or a transform that is not finite) the inverse is zero and the
// box finite: rays could not enter the mesh, and the instance is hidden.
@(private = "file")
instance_placement :: proc "contextless" (m: Mat4, low, high: Vec3) -> (inverse: Mat4, bmin, bmax: Vec3, invertible: bool) {
	finite :: proc "contextless" (v: f32) -> bool {return abs(v) <= max(f32)}
	inverse = linalg.inverse(m)
	bmin, bmax = transform_bounds(m, low, high)
	invertible = true
	for row in 0 ..< 3 {for col in 0 ..< 4 {invertible &&= finite(m[row, col]) && finite(inverse[row, col])}}
	if invertible {return}
	inverse = {}
	for axis in 0 ..< 3 {if !finite(bmin[axis]) || !finite(bmax[axis]) {bmin, bmax = {}, {}}}
	return
}

TLAS_REFIT_SLACK :: 1.5 // how much worse than when it was built a refit tree may get before it is built again

// The tree of the instances, their references classified, from tlas_items,
// and of the batches drawn that rays meet, from their boxes: a reference past
// the instances names such a batch (tlas_item), whose own tree trace.slang walks.
@(private)
tlas_build :: proc(s: ^Scene_State) {
	if s.tlas_off {
		s.tlas_stale = true
		return
	}
	s.tlas_stale, s.tlas_moved, s.tlas_classify = false, false, false
	items := s.tlas_items[:]
	batches := s.batch.built && s.batch.built_instances == len(s.instances) && len(s.batch.traced) > 0
	if batches {
		clear(&s.tlas_scratch)
		append(&s.tlas_scratch, ..s.tlas_items[:])
		for drawn in s.batch.traced {append(&s.tlas_scratch, s.batch.boxes[drawn])}
		items = s.tlas_scratch[:]
	}
	built := bvh_build(items, 2, &s.tlas_nodes, &s.tlas_refs)
	if built && batches {
		for &ref in s.tlas_refs {
			if int(ref) >= len(s.instances) {ref = u32(len(s.instances)) + s.batch.traced[int(ref) - len(s.instances)]}
		}
	}
	if !built {
		clear(&s.tlas_nodes)
		append(&s.tlas_nodes, Gpu_Bvh_Node{bounds_min = {1, 1, 1}, bounds_max = {-1, -1, -1}})
		clear(&s.tlas_refs)
		append(&s.tlas_refs, 0)
	}
	s.tlas_node_count = len(s.tlas_nodes)
	// Without memory for the tree rays meet nothing, and the next frame builds it again.
	if !built && len(items) > 0 {
		s.tlas_stale, s.tlas_cost, s.glass_node_count = true, 0, 0
		return
	}
	tlas_refs_classify(s)
	s.tlas_cost = tlas_refit(s)
}

// Gives every node of the tree the bounds of what is under it now and keeps
// its shape: for instances that moved since it was built. The boxes of the
// glass instances follow them. Returns what the tree costs the rays that
// cross the scene: the surface of every node, by its instances in a leaf.
// It grows as the nodes stretch over what moved apart.
@(private = "file")
tlas_refit :: proc(s: ^Scene_State) -> f32 {
	nodes := s.tlas_nodes[:s.tlas_node_count]
	if len(s.instances) == 0 && len(s.batch.traced) == 0 || len(nodes) == 0 {return 0}
	total: f64
	// Children are stored after their parent.
	#reverse for &node in nodes {
		weight := f64(1)
		if node.count > 0 {
			bmin, bmax := Vec3{1e30, 1e30, 1e30}, Vec3{-1e30, -1e30, -1e30}
			for ref in s.tlas_refs[node.left_first:][:node.count] {
				item := tlas_item(s, ref)
				bmin, bmax = linalg.min(bmin, item.bounds_min), linalg.max(bmax, item.bounds_max)
			}
			node.bounds_min, node.bounds_max = bmin, bmax
			weight = f64(node.count)
		} else {
			left, right := &nodes[node.left_first], &nodes[node.left_first + 1]
			node.bounds_min, node.bounds_max = linalg.min(left.bounds_min, right.bounds_min), linalg.max(left.bounds_max, right.bounds_max)
		}
		total += f64(aabb_area(node.bounds_min, node.bounds_max)) * weight
	}
	for &node in s.tlas_nodes[s.tlas_node_count:] {
		inst := &s.instances[node.left_first]
		node.bounds_min, node.bounds_max = inst.bounds_min.xyz, inst.bounds_max.xyz
	}
	return f32(total)
}

// Moves instances of the last scene_set, which stays as it is otherwise:
// descs are positions in the list it was given and transforms where each one
// is now. The transform an instance had becomes its previous one, so the next
// frame draws its motion. Nothing else of the scene is touched: the lists of
// the set, the materials, the lights and the temporal history stay. The tree
// of the instances is refit, not built: it holds the same instances in other
// boxes than scene_set would give them, so rays find the same surfaces. A
// transform without an inverse hides the instance, and one with it shows it
// again, as scene_update would (INSTANCE_FLAG_COLLAPSED). anchors: what each
// transform is relative to (Instance_Desc.anchor), or none for the world.
// count takes how many were somewhere else. False, with nothing changed, when
// the lists differ in length or name an instance that the set did not have.
scene_move :: proc(r: ^Renderer, descs: []u32, transforms: []Mat4, anchors: []Vec3 = nil, count: ^int = nil) -> bool {
	s := &r.scene
	if count != nil {count^ = 0}
	if len(descs) != len(transforms) || anchors != nil && len(anchors) != len(descs) {return false}
	for desc in descs {
		if int(desc) >= len(s.desc_instance) {return false}
	}
	moved, collapsed := false, false
	for desc, at in descs {
		index := s.desc_instance[desc]
		if index < 0 {continue}
		inst := &s.instances[index]
		transform := origin_matrix(transforms[at], r.origin - (anchors[at] if anchors != nil else 0))
		world := rows_3x4(transform)
		if inst.world == world {continue}
		mesh := &s.meshes[inst.meta.x & INSTANCE_MESH_MASK]
		inverse, bmin, bmax, invertible := instance_placement(transform, mesh.bounds_min, mesh.bounds_max)
		scene_changed_box(s, inst.bounds_min.xyz, inst.bounds_max.xyz)
		scene_changed_box(s, bmin, bmax)
		before := inst^
		inst.prev_world = inst.world
		inst.world = world
		inst.world_inv = rows_3x4(inverse)
		inst.bounds_min = {bmin.x, bmin.y, bmin.z, inst.bounds_min.w}
		inst.bounds_max = {bmax.x, bmax.y, bmax.z, inst.bounds_max.w}
		if !invertible && inst.meta.w & INSTANCE_FLAG_HIDDEN == 0 {
			inst.meta.w |= INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_COLLAPSED
			s.hidden_count += 1
			collapsed = true
		} else if invertible && instance_uncollapse(s, u32(index)) {
			collapsed = true
		}
		instance_resized(s, int(index), bmin, bmax)
		occluder_moved(s, u32(index), before, inst^)
		s.tlas_items[index] = Bvh_Item{bounds_min = bmin, bounds_max = bmax, center = (bmin + bmax) * 0.5}
		s.hw_instances[index].transform = world if invertible else {}
		instance_touch(s, u32(index))
		moved = true
		if count != nil {count^ += 1}
	}
	// What a hidden instance leaves out of the lists, a move that hides or shows one changes.
	if collapsed {instances_classify(s)}
	if moved {instances_moved(s)}
	return true
}

// Shows an instance hidden only because it could not be drawn yet
// (INSTANCE_FLAG_COLLAPSED), once its transform has an inverse and the
// geometry of its mesh is on the GPU. An outline-only one stays hidden.
// Whether it changed.
@(private)
instance_uncollapse :: proc(s: ^Scene_State, index: u32) -> bool {
	inst := &s.instances[index]
	if inst.meta.w & INSTANCE_FLAG_COLLAPSED == 0 || inst.world_inv == {} || mesh_pending(s, inst.meta.x & INSTANCE_MESH_MASK) {return false}
	inst.meta.w &~= INSTANCE_FLAG_COLLAPSED
	if inst.meta.w & INSTANCE_FLAG_OUTLINE_ONLY == 0 {
		inst.meta.w &~= INSTANCE_FLAG_HIDDEN
		s.hidden_count -= 1
	}
	s.hw_instances[index].mask_flags = tlas_mask_flags(ray_class(inst.meta.w), inst.meta.w & INSTANCE_FLAG_ALPHA_TESTED != 0)
	return true
}

// A mesh whose geometry went to the GPU over frames shows at once: its
// instances, as a move shows one whose transform has an inverse again, and
// its batches, which are built again. The light changes around them.
@(private)
mesh_shown :: proc(r: ^Renderer, handle: u32) {
	s := &r.scene
	if int(handle) >= len(s.meshes) || s.meshes[handle].vertex_count == 0 {return}
	m := &s.meshes[handle]
	// The boxes of its instances follow the pose it has now.
	if m.skin != nil {m.skin.bounds_dirty = true}
	// An instance whose programs move its vertices takes its pose once its mesh is there.
	s.displaced_stale = true
	s.batch.built = false
	// Its native BLAS is built with the next publication.
	s.geometry_dirty = true
	shown := false
	for index := m.first_instance; index >= 0; index = s.instance_next[index] {
		inst := &s.instances[index]
		before := inst^
		if !instance_uncollapse(s, u32(index)) {continue}
		instance_changed_near(s, inst)
		occluder_moved(s, u32(index), before, inst^)
		instance_touch(s, u32(index))
		shown = true
	}
	if shown {
		instances_classify(s)
		instances_moved(s)
		s.ray_cuts_stale = true
	}
}

// The bounds of the scene and the tree of the instances once some instances
// have other boxes. The tree keeps its shape, refit, until it fits them too badly.
@(private)
instances_moved :: proc(s: ^Scene_State) {
	s.has_bounds = false
	s.bounds_min = {1e30, 1e30, 1e30}
	s.bounds_max = {-1e30, -1e30, -1e30}
	if s.hidden_count == 0 {
		for &item in s.tlas_items {
			s.bounds_min, s.bounds_max = linalg.min(s.bounds_min, item.bounds_min), linalg.max(s.bounds_max, item.bounds_max)
		}
		s.has_bounds = len(s.tlas_items) > 0
	} else {
		for &inst, i in s.instances {
			if inst.meta.w & INSTANCE_FLAG_HIDDEN != 0 {continue}
			item := &s.tlas_items[i]
			s.bounds_min, s.bounds_max = linalg.min(s.bounds_min, item.bounds_min), linalg.max(s.bounds_max, item.bounds_max)
			s.has_bounds = true
		}
	}
	// A move is one call a frame: the tree is refit now, unless it is to be built again anyway.
	if !s.tlas_stale {
		if tlas_refit(s) > s.tlas_cost * TLAS_REFIT_SLACK {
			tlas_build(s)
			s.tlas_refs_dirty = true
		}
		s.tlas_nodes_dirty = true
	}
	s.tlas_dirty = true
}

// The tree of the instances once a frame, whatever the updates before it
// were: built again when instances came or went, else classified and refit
// as their boxes and what rays see of them changed. Each update alone would
// walk every instance.
@(private)
tlas_settle :: proc(s: ^Scene_State) {
	if s.tlas_stale {
		tlas_build(s)
		s.tlas_nodes_dirty, s.tlas_refs_dirty = true, true
		return
	}
	if s.tlas_classify {
		s.tlas_classify = false
		tlas_refs_classify(s)
		s.tlas_nodes_dirty, s.tlas_refs_dirty = true, true
	}
	if s.tlas_moved {
		s.tlas_moved = false
		if tlas_refit(s) > s.tlas_cost * TLAS_REFIT_SLACK {
			tlas_build(s)
			s.tlas_refs_dirty = true
		}
		s.tlas_nodes_dirty = true
	}
}

// Gives instances of the last scene_set another tint and emission, and
// nothing else: descs are positions in the list it was given. count takes how
// many had another. False, with nothing changed, when the lists differ in
// length or name an instance that the set did not have.
scene_tint :: proc(r: ^Renderer, descs: []u32, tints, emissions: []Vec3, count: ^int = nil) -> bool {
	s := &r.scene
	if count != nil {count^ = 0}
	if len(descs) != len(tints) || len(descs) != len(emissions) {return false}
	for desc in descs {
		if int(desc) >= len(s.desc_instance) {return false}
	}
	for desc, at in descs {
		index := s.desc_instance[desc]
		if index < 0 {continue}
		inst := &s.instances[index]
		tint := Vec4{tints[at].x, tints[at].y, tints[at].z, inst.tint.w}
		emission := Vec4{emissions[at].x, emissions[at].y, emissions[at].z, inst.emission.w}
		if inst.tint == tint && inst.emission == emission {continue}
		glowed := inst.emission != emission
		inst.tint, inst.emission = tint, emission
		instance_changed_near(s, inst, glowed)
		instance_touch(s, u32(index))
		if count != nil {count^ += 1}
	}
	return true
}

// Gives instances of the last scene_set other values over the rows of their
// materials (Instance_Material_Values), and nothing else: descs are positions in the
// list it was given. A value changed touches its instance alone: no row of
// the material table, no texture and no other instance. count takes how many
// had other values. False, with nothing changed, when the lists differ in
// length or name an instance that the set did not have; an instance whose
// values find no room in the index pool keeps those it had
// (stats.problem says what is missing).
scene_material_values :: proc(r: ^Renderer, descs: []u32, values: []Instance_Material_Values, count: ^int = nil) -> bool {
	s := &r.scene
	if count != nil {count^ = 0}
	if len(descs) != len(values) {return false}
	for desc in descs {
		if int(desc) >= len(s.desc_instance) {return false}
	}
	for desc, at in descs {
		index := s.desc_instance[desc]
		if index < 0 {continue}
		inst := &s.instances[index]
		given := values[at]
		glowed := instance_material_values_glow(s, inst.material_values)
		if !instance_material_values_give(r, inst, &given) {continue}
		instance_changed_near(s, inst, glowed || instance_material_values_glow(s, inst.material_values))
		instance_touch(s, u32(index))
		if count != nil {count^ += 1}
	}
	return true
}

// The words of the values of an instance in the index pool (Gpu_Instance.values); none for 0.
@(private)
instance_material_values_words :: proc "contextless" (s: ^Scene_State, values: u32) -> []u32 {
	if values == 0 || int(values) > len(s.indices) {return nil}
	count := int(min(s.indices[values - 1], INSTANCE_VALUES_MAX))
	if int(values) + count * INSTANCE_VALUE_WORDS > len(s.indices) {return nil}
	return s.indices[values:][:count * INSTANCE_VALUE_WORDS]
}

@(private = "file")
instance_material_values_same :: proc(s: ^Scene_State, held: u32, given: ^Instance_Material_Values) -> bool {
	words := instance_material_values_words(s, held)
	count := min(int(given.count), len(given.entries))
	if len(words) != count * INSTANCE_VALUE_WORDS {return false}
	return count == 0 || slice.equal(words, slice.reinterpret([]u32, given.entries[:count]))
}

// Whether the values of an instance give it an emission: its glow reaches as far as that of a tint.
@(private = "file")
instance_material_values_glow :: proc "contextless" (s: ^Scene_State, values: u32) -> bool {
	words := instance_material_values_words(s, values)
	for at := 0; at + INSTANCE_VALUE_WORDS <= len(words); at += INSTANCE_VALUE_WORDS {
		if words[at + 1] & 0xff == u32(Instance_Material_Value_Target.Emission) {return true}
	}
	return false
}

// Puts the values of an instance in the index pool in place of those it had:
// over them when they are as many, else in room of their own. False when
// they are those it had, or without room for them: the instance keeps what
// it had.
@(private)
instance_material_values_give :: proc(r: ^Renderer, inst: ^Gpu_Instance, given: ^Instance_Material_Values) -> (changed: bool) {
	s := &r.scene
	if instance_material_values_same(s, inst.material_values, given) {return false}
	count := min(int(given.count), len(given.entries))
	entries := slice.reinterpret([]u32, given.entries[:count])
	if held := instance_material_values_words(s, inst.material_values); len(held) == len(entries) && count > 0 {
		copy(held, entries)
		range_add(&s.pool_dirty[.Index], {inst.material_values, u32(len(held))})
		return true
	}
	stored: u32
	if count > 0 {
		if !pool_room(r, .Index, len(entries) + 1) {return false}
		first := u32(len(s.indices))
		if _, error := append(&s.indices, u32(count)); error != nil {return false}
		if _, error := append(&s.indices, ..entries); error != nil {base.truncate(&s.indices, int(first)); return false}
		stored = pool_store(&s.indices, &s.pool_free[.Index], &s.pool_dirty[.Index], first) + 1
	}
	instance_material_values_release(s, inst)
	inst.material_values = stored
	return true
}

// Gives back the words of the values of an instance, which has none after.
@(private)
instance_material_values_release :: proc(s: ^Scene_State, inst: ^Gpu_Instance) {
	if words := instance_material_values_words(s, inst.material_values); inst.material_values != 0 {
		pool_release(&s.indices, &s.pool_free[.Index], inst.material_values - 1, u32(len(words)) + 1)
	}
	inst.material_values = 0
}

// An instance of the last scene_set described again at another place of the
// list: `descriptor` is what `from` was, and takes where that one was drawn
// as its previous transform, so the next frame draws its motion. For whoever
// closes the gap an instance leaves with another, before it truncates the
// scene. False for a descriptor the scene does not have.
scene_instance_was :: proc(r: ^Renderer, descriptor, from: u32) -> bool {
	s := &r.scene
	if int(descriptor) >= len(s.desc_instance) || int(from) >= len(s.desc_instance) {return false}
	to, was := s.desc_instance[descriptor], s.desc_instance[from]
	if to < 0 || was < 0 {return true}
	s.instances[to].prev_world = s.instances[was].world
	instance_touch(s, u32(to))
	return true
}

// The mesh an instance of the last scene_set shows, the one its description
// named, and where it is: its transform into the world. False for a
// descriptor the scene does not have or the set skipped.
scene_instance_placed :: proc(r: ^Renderer, descriptor: u32) -> (mesh: Mesh_Handle, transform: Mat4, ok: bool) {
	s := &r.scene
	if int(descriptor) >= len(s.desc_instance) || s.desc_instance[descriptor] < 0 {return}
	inst := &s.instances[s.desc_instance[descriptor]]
	mesh = Mesh_Handle(inst.meta.x & INSTANCE_MESH_MASK)
	// The pose of an instance whose programs move its vertices stands for the mesh it was given.
	if int(mesh) < len(s.meshes) && s.meshes[mesh].skin != nil && s.meshes[mesh].skin.displaced {mesh = s.meshes[mesh].skin.source}
	rows := origin_to_world(inst.world, -r.origin)
	transform = 1
	for row in 0 ..< 3 {for col in 0 ..< 4 {transform[row, col] = rows[row][col]}}
	return mesh, transform, true
}

// The rows of the material table an instance of the last scene_set shows, as
// its description named them: its material, those of its slots and its
// layers. False for a descriptor the scene does not have or the set skipped.
scene_instance_materials :: proc(r: ^Renderer, descriptor: u32) -> (material: Material_Handle, slots: [32]u32, overlays: Instance_Overlays, ok: bool) {
	s := &r.scene
	if int(descriptor) >= len(s.desc_instance) || s.desc_instance[descriptor] < 0 {return}
	index := s.desc_instance[descriptor]
	inst := &s.instances[index]
	if inst.meta.y != GPU_NONE {material = Material_Handle(inst.meta.y)}
	return material, inst.slot_materials, s.overlays[index], true
}

// Four numbers of each instance that extensions give it and read in their
// shaders (instance_values of scene.slang), by the descriptor of the
// instance. They stay while the instance keeps its identity, and change
// neither its light nor its rays. False for a descriptor the scene does not
// have or a value that is not finite.
scene_set_instance_values :: proc(r:^Renderer,descriptor:u32,values:Vec4) -> bool {
    s:=&r.scene
    if int(descriptor)>=len(s.desc_instance) {return false}
    for value in values {if value!=value || value-value!=0 {return false}}
    index:=s.desc_instance[descriptor]
    if index<0 {return true}
    inst:=&s.instances[index]
    if instance_values(inst^)==values {return true}
    inst.tint.w,inst.emission.w,inst.bounds_min.w,inst.bounds_max.w=values.x,values.y,values.z,values.w
    instance_touch(s, u32(index))
    return true
}

@(private)
instance_values :: proc "contextless" (inst:Gpu_Instance) -> Vec4 {return {inst.tint.w,inst.emission.w,inst.bounds_min.w,inst.bounds_max.w}}

// How wet an instance is, 0 dry to 1 soaked, by the descriptor of the
// instance: the materials read it (Mirai_Surface_Context.wet) and the
// renderer darkens and smooths by it what is not metal, glass or unlit. It
// stays while the instance keeps its identity, as its values, and changes
// neither its light nor its rays. False for a descriptor the scene does not
// have or a value that is not finite; others are clamped to 0..1.
scene_set_instance_wet :: proc(r:^Renderer,descriptor:u32,wet:f32) -> bool {
    s:=&r.scene
    if int(descriptor)>=len(s.desc_instance) || wet!=wet || wet-wet!=0 {return false}
    index:=s.desc_instance[descriptor]
    if index<0 {return true}
    inst:=&s.instances[index]
    if value:=clamp(wet,0,1);inst.wet!=value {
        inst.wet=value
        instance_touch(s, u32(index))
    }
    return true
}

// What extensions gave an instance, which it keeps with its identity. held:
// the values it had in the index pool (Gpu_Instance.values), which whatever
// is written in its place takes or gives back.
@(private)
Instance_Given :: struct {values:Vec4,wet:f32,held:u32}

@(private)
instance_given :: proc "contextless" (inst:Gpu_Instance) -> Instance_Given {return {instance_values(inst),inst.wet,inst.material_values}}

// Room for count instances in every table that holds one of each, and in
// those of what rays and glass need of them. False without memory.
@(private="file")
instances_reserve :: proc(s:^Scene_State,count:int) -> bool {
    return reserve(&s.instances,count)==nil && reserve(&s.instance_next,count)==nil && reserve(&s.instance_prev,count)==nil &&
           reserve(&s.overlays,count)==nil && reserve(&s.instance_keys,count)==nil && reserve(&s.tlas_items,count)==nil &&
           reserve(&s.hw_instances,count)==nil && reserve(&s.desc_instance,count)==nil && reserve(&s.touched,(count+63)/64)==nil &&
           reserve(&s.translucent,count)==nil && reserve(&s.reflective,count)==nil &&
           reserve(&s.tlas_nodes,count*2+1)==nil && reserve(&s.tlas_refs,max(count,1))==nil
}

// False when the instance is past the tables and they have no room for it
// (instances_reserve makes it): nothing is written.
@(private)
instance_write :: proc(r:^Renderer,index:u32,desc:Instance_Desc,previous:Mat4,given:Instance_Given) -> (written,revalued:bool) {
    s:=&r.scene
    desc:=desc
    // An instance whose material programs move its vertices shows its own pose of its mesh.
    desc.mesh=displaced_mesh(r,desc)
    values:=given.values
    s.ray_cuts_stale=true
    count:=int(index)+1
    if before:=len(s.instances);count>before {
        if resize(&s.instances,count)!=nil || resize(&s.instance_next,count)!=nil || resize(&s.instance_prev,count)!=nil || resize(&s.overlays,count)!=nil ||
           resize(&s.instance_keys,count)!=nil || resize(&s.tlas_items,count)!=nil || resize(&s.hw_instances,count)!=nil || resize(&s.touched,(count+63)/64)!=nil {
            base.truncate(&s.instances,before);base.truncate(&s.instance_next,before);base.truncate(&s.instance_prev,before);base.truncate(&s.overlays,before)
            base.truncate(&s.instance_keys,before);base.truncate(&s.tlas_items,before);base.truncate(&s.hw_instances,before);base.truncate(&s.touched,(before+63)/64)
            held:=Gpu_Instance{material_values=given.held}
            instance_material_values_release(s,&held)
            return false,false
        }
    }
		mesh := s.meshes[desc.mesh]
		// The cut rays trace an instance with stays while it shows the same mesh
		// (ray_cuts_update) and, of a streamed mesh, has its pages in the pools.
		was := s.instances[index].meta.x >> INSTANCE_RAY_SHIFT
		kept := s.instances[index].meta.x & INSTANCE_MESH_MASK == u32(desc.mesh) && int(desc.mesh) < len(s.meshes) && was < max(mesh.ray_count, 1) && (mesh.stream == nil || mesh.stream.cut_missing[was] == 0)
		cut := was << INSTANCE_RAY_SHIFT if kept else u32(ray_cut_always(mesh)) << INSTANCE_RAY_SHIFT
		reach := pose_reach(mesh)
		inverse, bmin, bmax, invertible := instance_placement(desc.transform, mesh.bounds_min - reach, mesh.bounds_max + reach)
		key := Instance_Key{desc.object_id, desc.copy_owner, desc.copy_variant}

		// Its mesh is drawn once all its geometry is on the GPU.
		pending := mesh_pending(s, u32(desc.mesh))
		hidden := desc.hidden || desc.outline_only || !invertible || pending
		flags: u32 = INSTANCE_FLAG_HIDDEN if hidden else 0
		if !desc.hidden && (pending || !invertible && !desc.outline_only) {flags |= INSTANCE_FLAG_COLLAPSED}
		if desc.outline_only {flags |= INSTANCE_FLAG_OUTLINE_ONLY}
		if desc.uniform_color {flags |= INSTANCE_FLAG_UNIFORM_COLOR}
		flags |= highlight_flags(desc.highlight)
		flags |= (desc.layers & LAYERS_ALL if desc.layers & LAYERS_ALL != 0 else 1) << INSTANCE_LAYERS_SHIFT
		if desc.owner != 0 {flags |= INSTANCE_FLAG_OWNED | (u32(desc.owner - 1) & 3) << INSTANCE_OWNER_SHIFT}
		if desc.highlight != 0 {s.highlighted += 1}
		if hidden {s.hidden_count += 1}
		material := u32(desc.material) if desc.material != 0 && int(desc.material) < len(s.materials) else GPU_NONE
        slot_materials:=desc.slot_materials
        for &row in slot_materials {if row>u32(len(s.materials)) {row=0}}
		tested, blended, glass, reflectance, layered, solid, glass_layered := instance_alpha(s, mesh, material,slot_materials)
		flags |= alpha_flags(tested, blended, glass)
		flags |= instance_small(bmin, bmax)
		if reflectance && !hidden {append(&s.reflective, Reflective_Instance{index, layered})}
		if blended && !hidden {append(&s.translucent, Translucent{instance = index, solid = solid, layered = glass_layered})}
		s.instances[index]=Gpu_Instance{
			slot_materials=slot_materials,
			world = rows_3x4(desc.transform),
			world_inv = rows_3x4(inverse),
			prev_world = rows_3x4(previous),
			meta = {u32(desc.mesh) | cut, material, u32(desc.object_id), flags},
			bounds_min = {bmin.x, bmin.y, bmin.z, values.z},
			bounds_max = {bmax.x, bmax.y, bmax.z, values.w},
			tint = {desc.tint.x, desc.tint.y, desc.tint.z, values.x},
			emission = {desc.emission.x, desc.emission.y, desc.emission.z, values.y},
			wet = given.wet,
			material_values = given.held,
		}
		// Without room for them it keeps those it had (stats.problem says what is missing).
		given_values := desc.material_values
		glowed := instance_material_values_glow(s, given.held)
		revalued = instance_material_values_give(r, &s.instances[index], &given_values)
		if revalued && (glowed || instance_material_values_glow(s, s.instances[index].material_values)) {instance_changed_near(s, &s.instances[index], true)}
		head:=s.meshes[desc.mesh].first_instance
		s.instance_next[index],s.instance_prev[index]=head,-1
		if head>=0 {s.instance_prev[head]=i32(index)}
		s.meshes[desc.mesh].first_instance=i32(index)
		layers:=desc.overlays
		layers.count=min(layers.count,OVERLAY_CAPACITY)
		for &layer in layers.entries[:layers.count] {
			if int(layer.material)>=len(s.materials) || layer.material==0 {layer.enabled=false}
			if layer.enabled && !hidden && !blended {s.overlay_count+=1}
		}
		s.overlays[index]=layers
		s.instance_keys[index]=key
		s.tlas_items[index]=Bvh_Item{bounds_min = bmin, bounds_max = bmax, center = (bmin + bmax) * 0.5}
		s.hw_instances[index]=rhi.Tlas_Instance{transform = rows_3x4(desc.transform) if invertible else {}, custom_index = index, mask_flags = tlas_mask_flags(ray_class(flags), tested)}
		if !hidden {
			s.bounds_min = linalg.min(s.bounds_min, bmin)
			s.bounds_max = linalg.max(s.bounds_max, bmax)
			s.has_bounds = true
		}
    return true,revalued
}

@(private)
instance_unlink :: proc(s:^Scene_State,index:u32) {
    inst:=s.instances[index]
    mesh:=&s.meshes[inst.meta.x&INSTANCE_MESH_MASK]
    before,after:=s.instance_prev[index],s.instance_next[index]
    if before>=0 {s.instance_next[before]=after} else if mesh.first_instance==i32(index) {mesh.first_instance=after}
    if after>=0 {s.instance_prev[after]=before}
    if inst.meta.w&INSTANCE_FLAG_HIDDEN!=0 {s.hidden_count-=1}
    if inst.meta.w&INSTANCE_HIGHLIGHT_MASK!=0 {s.highlighted-=1}
    if inst.meta.w&(INSTANCE_FLAG_HIDDEN|INSTANCE_FLAG_TRANSLUCENT)==0 {
        for layer in s.overlays[index].entries[:s.overlays[index].count] {if layer.enabled {s.overlay_count-=1}}
    }
    for i:=len(s.translucent)-1;i>=0;i-=1 {if s.translucent[i].instance==index {unordered_remove(&s.translucent,i)}}
    for i:=len(s.reflective)-1;i>=0;i-=1 {if s.reflective[i].instance==index {unordered_remove(&s.reflective,i)}}
}

// Replaces a descriptor range, optionally appending or truncating its suffix.
// A set that skipped invalid meshes must be replaced with scene_set first.
// False also without memory for the instances it appends: none is changed.
scene_update :: proc(r:^Renderer,first:u32,instances:[]Instance_Desc,truncate:bool=false) -> bool {
    s:=&r.scene
    old:=len(s.instances)
    if int(first)>old || len(s.desc_instance)!=old || len(instances)>max(int)-int(first) {return false}
    for desc in instances {if int(desc.mesh)>=len(s.meshes) || s.meshes[desc.mesh].vertex_count==0 {return false}}
    end:=int(first)+len(instances)
    if len(instances)==0 && (!truncate || end==old) {return true}
    spatial,classification,ray_properties:bool
    if end>old && !instances_reserve(s,end) {
        set_error(r,"scene of %d instances: out of memory",end)
        return false
    }
    written:=true
    for given,at in instances {
        desc:=given
        desc.transform=origin_matrix(given.transform,r.origin-given.anchor)
        index:=first+u32(at)
        previous:=desc.transform
        flags:u32
        given:Instance_Given
        before:Gpu_Instance
        layers:Instance_Overlays
        if int(index)<old {
            inst:=s.instances[index]
            before=inst
            layers=s.overlays[index]
            flags=inst.meta.w
            instance_changed_near(s,&s.instances[index])
            if s.instance_keys[index]==(Instance_Key{desc.object_id,desc.copy_owner,desc.copy_variant}) {
                for row in 0..<3 {for col in 0..<4 {previous[row,col]=s.instances[index].world[row][col]}}
                given=instance_given(inst)
            }
            given.held=inst.material_values
            instance_unlink(s,index)
        } else {append(&s.desc_instance,i32(index))}
        // Only an instance past the old ones takes room, and it was reserved.
        if made,_:=instance_write(r,index,desc,previous,given);!made {pop(&s.desc_instance);written=false;break}
        instance_changed_near(s,&s.instances[index])
        if int(index)<old {
            mesh:=s.instances[index].meta.x&INSTANCE_MESH_MASK
            spatial||=before.meta.x&INSTANCE_MESH_MASK!=mesh || before.world!=s.instances[index].world
            // A pose its instance no longer shows goes.
            if before.meta.x&INSTANCE_MESH_MASK!=mesh && mesh_displaced(s,before.meta.x&INSTANCE_MESH_MASK) {s.displaced_stale=true}
            // Another mesh or other materials show other textures: their levels are estimated again (textures_touched).
            if before.meta.x&INSTANCE_MESH_MASK!=mesh || before.meta.y!=s.instances[index].meta.y || before.slot_materials!=s.instances[index].slot_materials || layers!=s.overlays[index] {
                r.textures.residency.stale=true
            }
        }
        if int(index)>=old {before=INSTANCE_ABSENT}
        if !instance_shades_same(before,s.instances[index]) {occluder_moved(s,index,before,s.instances[index])}
        changed:=flags~s.instances[index].meta.w
        classification||=changed&(INSTANCE_FLAG_BLENDED|INSTANCE_FLAG_HIDDEN)!=0
        ray_properties||=classification || changed&INSTANCE_FLAG_ALPHA_TESTED!=0
        instance_touch(s, index)
    }
    if truncate && end<old {
        for index in end..<old {
            occluder_moved(s,OCCLUDERS_MANY,s.instances[index],INSTANCE_ABSENT)
            instance_changed_near(s,&s.instances[index])
            if mesh_displaced(s,s.instances[index].meta.x&INSTANCE_MESH_MASK) {s.displaced_stale=true}
            instance_unlink(s,u32(index))
            instance_material_values_release(s,&s.instances[index])
        }
        base.truncate(&s.instances,end);base.truncate(&s.instance_next,end);base.truncate(&s.instance_prev,end);base.truncate(&s.overlays,end)
        base.truncate(&s.instance_keys,end);base.truncate(&s.tlas_items,end);base.truncate(&s.hw_instances,end);base.truncate(&s.desc_instance,end)
        touched_trim(s,end)
    }
    if len(s.instances)!=old {
        s.tlas_stale,s.instances_dirty=true,true
    } else {
        s.tlas_classify||=classification
        s.tlas_moved||=spatial
    }
    s.tlas_dirty||=spatial || ray_properties || len(s.instances)!=old
    return written
}

// The light changes around an instance that comes, goes or shows something
// else: its box and the reach of its glow, or of its shadow and color.
@(private = "file")
instance_changed_near :: proc(s: ^Scene_State, inst: ^Gpu_Instance, glowed := false) {
	radius := linalg.length(inst.bounds_max.xyz - inst.bounds_min.xyz) * 0.5
	glows := glowed || inst.emission.xyz != {}
	reach := LIGHT_CHANGE_REACH if glows else min(LIGHT_CHANGE_REACH, LIGHT_CHANGE_SIZES * radius)
	scene_changed_near(s, (inst.bounds_min.xyz + inst.bounds_max.xyz) * 0.5, radius + reach)
}

// Whether two instances cast the same shadows.
@(private = "file")
instance_shades_same :: proc(a, b: Gpu_Instance) -> bool {
	FLAGS :: INSTANCE_FLAG_HIDDEN | INSTANCE_FLAG_BLENDED | INSTANCE_FLAG_ALPHA_TESTED
	return a.world == b.world && a.meta.x == b.meta.x && a.meta.y == b.meta.y && a.meta.w & FLAGS == b.meta.w & FLAGS && a.slot_materials == b.slot_materials
}

// Whether two instances give the scene the same light: what a highlight
// changes is drawn over the image and leaves it.
@(private = "file")
instance_lit_same :: proc(a, b: Gpu_Instance) -> bool {
	return a.world == b.world && a.meta.x & INSTANCE_MESH_MASK == b.meta.x & INSTANCE_MESH_MASK && a.meta.y == b.meta.y && a.meta.w &~ INSTANCE_HIGHLIGHT_MASK == b.meta.w &~ INSTANCE_HIGHLIGHT_MASK && a.tint.xyz == b.tint.xyz && a.emission.xyz == b.emission.xyz && a.slot_materials == b.slot_materials
}

// Replaces the instance, light and environment sets (an edit transaction).
// Geometry stays resident; previous instances are matched by object and
// rendered-copy identity to produce motion vectors, and the light changes
// only around those that come, go or show something else (scene_set_lights
// marks the lights, the sun and the environment that change). False without
// memory for the instances or the lights: the scene stays as it was.
scene_set :: proc(r: ^Renderer, instances: []Instance_Desc, lights: []Light_Desc, sun: Sun_Desc, environment: Environment) -> bool {
	s := &r.scene
	if !instances_reserve(s, len(instances)) || !lights_reserve(s, len(lights)) {
		set_error(r, "scene of %d instances and %d lights: out of memory", len(instances), len(lights))
		return false
	}
	// The instances take other indices: what changed before stays as boxes.
	for &box in s.occluders.boxes[:s.occluders.count] {box.instance=OCCLUDERS_MANY}
	clear(&s.previous)
	for key, i in s.instance_keys {s.previous[key] = s.instances[i]}
	clear(&s.instances)
	clear(&s.instance_next)
	clear(&s.instance_prev)
	for &mesh in s.meshes {mesh.first_instance=-1}
	clear(&s.overlays);s.overlay_count=0;clear(&s.reflective)
	clear(&s.instance_keys)
	clear(&s.desc_instance)
	clear(&s.tlas_items)
	clear(&s.hw_instances)
	clear(&s.translucent)
	touched_trim(s, 0)
	s.highlighted = 0
	s.hidden_count = 0
	s.has_bounds = false
	s.bounds_min = {1e30, 1e30, 1e30}
	s.bounds_max = {-1e30, -1e30, -1e30}
	// The poses of the instances that do not come again go.
	if len(s.displaced) > 0 {s.displaced_stale = true}
	for given in instances {
        desc:=given
        desc.transform=origin_matrix(given.transform,r.origin-given.anchor)
        if int(desc.mesh)>=len(s.meshes) || s.meshes[desc.mesh].vertex_count==0 {append(&s.desc_instance,-1);continue}
        index:=u32(len(s.instances))
        key:=Instance_Key{desc.object_id,desc.copy_owner,desc.copy_variant}
        before,found:=s.previous[key]
        previous:=desc.transform
        given:Instance_Given
        if found {
            for row in 0..<3 {for col in 0..<4 {previous[row,col]=before.world[row][col]}}
            given=instance_given(before)
            delete_key(&s.previous,key)
        }
        // Its room was reserved; without it the instance is left out as one of a mesh that is not there.
        written,revalued:=instance_write(r,index,desc,previous,given)
        append(&s.desc_instance,i32(index) if written else -1)
        if !written {continue}
        // What moved since the set before is drawn in motion and goes once more, at rest.
        if s.instances[index].prev_world!=s.instances[index].world {instance_touch(s,index)}
        if !found || revalued || !instance_lit_same(before,s.instances[index]) {
            instance_changed_near(s,&s.instances[index])
            if found {instance_changed_near(s,&before)}
        }
        if !found {before=INSTANCE_ABSENT}
        if !instance_shades_same(before,s.instances[index]) {occluder_moved(s,index,before,s.instances[index])}
    }
    for _,&gone in s.previous {
        instance_changed_near(s,&gone,instance_material_values_glow(s,gone.material_values))
        occluder_moved(s,OCCLUDERS_MANY,gone,INSTANCE_ABSENT)
        instance_material_values_release(s,&gone)
    }
	tlas_build(s)
	s.instances_dirty = true
	s.tlas_dirty = true
	lit := scene_set_lights(r, lights, sun, environment)
	// A world shown again (scene_world) has the light of this scene already.
	if r.world_kept {s.changes = {}}
	r.world_kept = false
	return lit
}

// Lighting runs in render units: a luminance in nits by the light scale of
// the scene, with the irradiance of a light as the luminance of the white
// Lambert surface it lights (lux over pi), and every light enters them here:
// local lights in scene_set_lights, the sun, the sky and the background in the
// constants of each frame, emission in the shaders (frame.sky_color.w). The
// scale is a power of two that brings the strongest light near one, so the
// half floats of the targets hold a sunlit scene and a night one alike.
LIGHT_SCALE_KEEP :: f32(16) // the scale holds while the strongest light stays within this factor of one

@(private)
luminance_of :: proc "contextless" (c: Vec3) -> f32 {return c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722}

// What a local light gives a white surface a metre away that faces it, nits.
@(private)
light_key :: proc "contextless" (l: Light_Desc) -> f32 {
	area := l.size.x * l.size.y if l.size.x > 0 && l.size.y > 0 else 1
	return l.intensity * area * luminance_of(l.color) / math.PI
}

// The light scale for the strongest light of the scene, `key`, given the one
// in use; one without lights.
light_scale_of :: proc "contextless" (current, key: f32) -> f32 {
	if !(key > 0) || key > 1e30 {return 1}
	if current > 0 && key * current >= 1 / LIGHT_SCALE_KEEP && key * current <= LIGHT_SCALE_KEEP {return current}
	return math.pow(2, -math.round(math.log2(key)))
}

// A local light in render units; false for one that gives no light.
@(private = "file")
gpu_light :: proc(l: Light_Desc, scale: f32) -> (Gpu_Light, bool) {
	if !(l.intensity > 0) || !(luminance_of(l.color) > 0) || !(l.range > 0) {return {}, false}
	power := l.intensity / math.PI * scale
	if l.size.x > 0 && l.size.y > 0 {power *= l.size.x * l.size.y}
	light := Gpu_Light{position_range = {l.position.x, l.position.y, l.position.z, l.range}, color_intensity = {l.color.x, l.color.y, l.color.z, power}, direction_cone = {0, 0, 0, GPU_LIGHT_POINT}, size = {max(l.radius, 0), 0, 0, 0}}
	facing := linalg.length(l.direction) > 1e-6
	along := l.axis - linalg.dot(l.axis, l.direction) / max(linalg.dot(l.direction, l.direction), 1e-12) * l.direction
	switch {
	case l.size.x > 0 && l.size.y > 0 && facing && linalg.length(along) > 1e-6:
		normal, width := linalg.normalize(l.direction), linalg.normalize(along)
		light.direction_cone = {normal.x, normal.y, normal.z, GPU_LIGHT_RECT}
		light.size = {0, l.size.x * 0.5, l.size.y * 0.5, transmute(f32)u32(l.material)}
		light.axis = {width.x, width.y, width.z, 0}
	case l.cone > 0 && facing:
		direction := linalg.normalize(l.direction)
		light.direction_cone = {direction.x, direction.y, direction.z, math.cos(clamp(l.cone, 0.001, math.PI * 0.5))}
	}
	if l.length > 0 && linalg.length(l.axis) > 1e-6 && light.direction_cone.w != GPU_LIGHT_RECT {
		axis := linalg.normalize(l.axis)
		light.size.y = l.length * 0.5
		light.axis = {axis.x, axis.y, axis.z, 0}
	}
	return light, true
}

// Whether two lights send their shadow rays the same way: from the same
// place, the same shape, turned the same way. Their color and strength do not.
@(private = "file")
light_placed_same :: proc "contextless" (a, b: Gpu_Light) -> bool {
	return a.position_range.xyz == b.position_range.xyz && a.direction_cone.xyz == b.direction_cone.xyz && a.size.xyz == b.size.xyz && a.axis.xyz == b.axis.xyz
}

// The most changed lights refit one by one, each up its path of the tree;
// more refit the whole tree.
LIGHT_REFITS_MAX :: 32
// Ranges of lights, or of nodes of their tree, that go to the GPU one by one;
// with more, the whole tables go.
LIGHT_RANGES_MAX :: 64

// Replaces the lights, the sun and the environment, and nothing else of the
// scene. While the lights keep their number and each keeps its kind (spot or
// rectangle, or not; with a place or without one) an index names the same
// light: the tree is refit, rebuilt only once it costs too much
// (LIGHT_TREE_REFIT_SLACK), and only what changed goes to the GPU. False
// without memory for the lights and their tree: they stay as they were.
scene_set_lights :: proc(r: ^Renderer, lights: []Light_Desc, sun: Sun_Desc, environment: Environment) -> bool {
	s := &r.scene
	if !lights_reserve(s, len(lights)) {
		set_error(r, "%d lights: out of memory", len(lights))
		return false
	}
	s.lights_changed = true
	s.light_key = 0
	for l in lights {s.light_key = max(s.light_key, light_key(l))}
	scale := scene_light_scale(r, sun, environment)
	old := len(s.lights)
	count, changes := 0, 0
	same := true
	changed: [LIGHT_REFITS_MAX]u32
	moved: [LIGHT_MOVES_MAX + 1]u32
	moves := 0
	// A blackout: how much the light of the whole scene changes,
	// as a sum, which a light that comes or goes does not reorder as the list does.
	flux_before := sky_flux(s.sun, s.environment, scale)
	for l in s.lights {if light_in_volume(&r.ddgi, l) {flux_before += light_flux(l)}}
	flux_after := sky_flux(sun, environment, scale)
	Bits :: [size_of(Gpu_Light) / 4]u32
	for given in lights {
		l := given
		l.position = origin_point(l.position, r.origin)
		light, gives := gpu_light(l, scale)
		if !gives {continue}
		if light_in_volume(&r.ddgi, light) {flux_after += light_flux(light)}
		if count >= old {
			append(&s.lights, light)
			scene_changed_near(s, light.position_range.xyz, light.position_range.w)
		} else {
			before := s.lights[count]
			if transmute(Bits)before != transmute(Bits)light {
				same &&= light_directed(before) == light_directed(light) && light_placed(before) == light_placed(light)
				if changes < LIGHT_REFITS_MAX {changed[changes] = u32(count)}
				changes += 1
				if !light_placed_same(before, light) && moves < len(moved) {moved[moves] = u32(count); moves += 1}
				scene_changed_near(s, before.position_range.xyz, before.position_range.w)
				scene_changed_near(s, light.position_range.xyz, light.position_range.w)
				s.lights[count] = light
			}
		}
		count += 1
	}
	for gone in s.lights[count:] {
		scene_changed_near(s, gone.position_range.xyz, gone.position_range.w)
	}
	if abs(flux_after - flux_before) > GI_BLACKOUT_SHARE * max(flux_before, flux_after) {
		scene_changed(s)
		r.gi_warm_spread = GI_BLACKOUT_FRAMES
	}
	base.truncate(&s.lights, count)
	// An index names the same light only while the set holds.
	if count == old && same {for light in moved[:moves] {occluder_light_moved(s, light)}}
	switch {
	case count != old || !same:
		// lights_reserve made the room of the tree.
		if !light_tree_rebuild(s) {set_error(r, "light tree of %d lights: out of memory", count);return false}
		s.light_revision += 1
		s.lights_dirty = true
	case changes > LIGHT_REFITS_MAX:
		s.light_tree_cost = light_tree_refit_all(s.light_tree[:], s.lights[:], s.light_region)
		s.lights_dirty = true
	case:
		for light in changed[:changes] {
			tracked := !s.lights_dirty
			if tracked {range_add(&s.light_ranges, {light, 1})}
			if leaf := s.light_leaves[light]; leaf != LIGHT_TREE_NONE {
				s.light_tree_cost += light_tree_refit(s.light_tree[:], s.lights[:], leaf, &s.light_node_ranges if tracked else nil, s.light_region)
			}
			if len(s.light_ranges) > LIGHT_RANGES_MAX || len(s.light_node_ranges) > LIGHT_RANGES_MAX {s.lights_dirty = true}
		}
	}
	if changes > 0 && s.light_tree_cost > s.light_tree_built * LIGHT_TREE_REFIT_SLACK {
		if !light_tree_rebuild(s) {set_error(r, "light tree of %d lights: out of memory", count);return false}
		s.lights_dirty = true
	}
	if s.lights_dirty {
		clear(&s.light_ranges)
		clear(&s.light_node_ranges)
	}
	scene_set_environment(r, sun, environment)
	return true
}

// Room for count lights and their tree: with it scene_set_lights does not
// run out of memory half way. False without memory.
@(private = "file")
lights_reserve :: proc(s: ^Scene_State, count: int) -> bool {
	return reserve(&s.lights, count) == nil && light_tree_reserve(&s.light_tree, &s.light_keys, &s.light_leaves, count, s.light_region)
}

// Builds the tree of the lights again. False without memory: it stays as it was.
@(private = "file")
light_tree_rebuild :: proc(s: ^Scene_State) -> bool {
	built := light_tree_build(&s.light_tree, &s.light_keys, &s.light_leaves, s.lights[:], s.light_region) or_return
	s.light_tree_built, s.light_tree_cost = built, built
	return true
}

// Takes the room for lights on the GPU the extensions asked for since the
// last frame (lights_ask): another size builds the tree again. A room no pass
// wrote in the frame before goes back to the root of the scene alone, and
// its part without shadows to none. False without memory for the tree of
// another room: the room stays as it was.
@(private)
scene_light_region :: proc(r: ^Renderer) -> bool {
	s := &r.scene
	asked := light_region_of(r.lights_asked, r.shadowless_asked)
	r.lights_asked, r.shadowless_asked = 0, 0
	if asked != s.light_region {
		previous := s.light_region
		s.light_region = asked
		if !light_tree_rebuild(s) {
			s.light_region = previous
			set_error(r, "light tree with room for %d lights of the passes: out of memory", asked.lights + asked.shadowless)
			return false
		}
		s.light_revision += 1
		s.lights_dirty = true
		clear(&s.light_ranges)
		clear(&s.light_node_ranges)
	} else if s.light_region.lights > 0 && !s.light_region_written && !s.lights_dirty {
		range_add(&s.light_node_ranges, {0, 2})
		if root := light_region_shadowless(s.light_region); root > 0 {range_add(&s.light_node_ranges, {root, 1})}
	}
	s.light_region_written = false
	return true
}

// The light scale for the local lights of the scene with a sun and an
// environment. A new one, which only a change of many times in the strongest
// light gives, is a change of units: what the histories hold of light
// (radiance, probes) is brought to it in the next frame
// (histories_rescale), and none starts over.
@(private)
scene_light_scale :: proc(r: ^Renderer, sun: Sun_Desc, environment: Environment) -> f32 {
	s := &r.scene
	key := max(s.light_key, luminance_of(environment.sky))
	if sun.enabled {key = max(key, sun.illuminance * luminance_of(sun.color) / math.PI)}
	scale := light_scale_of(s.light_scale, key)
	if s.light_scale > 0 && scale != s.light_scale {
		ratio := scale / s.light_scale
		for &l in s.lights {l.color_intensity.w *= ratio}
		s.light_tree_cost = light_tree_refit_all(s.light_tree[:], s.lights[:], s.light_region)
		s.lights_dirty = true
		r.light_rescale = (r.light_rescale if r.light_rescale > 0 else 1) * ratio
	}
	s.light_scale = scale
	return scale
}

// Changes the view environment without uploading geometry or rebuilding the
// TLAS. A preview lighting toggle can discard radiance history in-place.
scene_set_environment :: proc(r:^Renderer,sun:Sun_Desc,environment:Environment,reset_history:bool=false) {
    scene_light_scale(r,sun,environment)
    normalized:=sun
    if linalg.length(normalized.direction)>1e-6 {normalized.direction=linalg.normalize(normalized.direction)} else {normalized.enabled=false}
    if r.scene.sun!=normalized || r.scene.environment!=environment {scene_changed(&r.scene)}
    // A sun that turns by less than its radius moves its shadows by less than their penumbra.
    before:=r.scene.sun
    if normalized.enabled && (!before.enabled || linalg.dot(before.direction,normalized.direction)<math.cos(max(r.settings.sun_radius,SUN_RADIUS))) {r.scene.occluders.sun=true}
    r.scene.sun=normalized;r.scene.environment=environment
    if reset_history {
        renderer_reset_history(r)
    }
}

// Discard temporal radiance after a document reset or an environment change.
// A reset camera also discards the previous motion-vector matrices.
renderer_reset_history :: proc(r:^Renderer,reset_camera:bool=false) {
    ddgi_release(r)
    scene_changed(&r.scene)
    r.gi_warm=true
    for view in views_all(r) {
        view.targets.reflect_valid,view.targets.gi_reference_valid,view.targets.taa_valid=false,false,false
        view.targets.glass_valid,view.targets.shadow.valid,view.targets.hiz_valid=false,false,false
        if reset_camera {view.has_previous=false}
    }
}

@(private)
highlight_flags :: proc "contextless" (level: u8) -> u32 {return (u32(level) << INSTANCE_HIGHLIGHT_SHIFT) & INSTANCE_HIGHLIGHT_MASK}

// Restyles highlights without touching transforms, the TLAS, lights or the
// temporal history: only the instances whose level is another go to the GPU.
// levels is indexed like the instances of the last scene_set; a length
// mismatch is rejected.
scene_set_highlights :: proc(r: ^Renderer, levels: []u8) -> bool {
	s := &r.scene
	if len(levels) != len(s.desc_instance) {return false}
	s.highlighted = 0
	for level, i in levels {
		index := s.desc_instance[i]
		if index < 0 {continue}
		inst := &s.instances[index]
		if level != 0 {s.highlighted += 1}
		flags := (inst.meta.w & ~INSTANCE_HIGHLIGHT_MASK) | highlight_flags(level)
		if flags == inst.meta.w {continue}
		inst.meta.w = flags
		instance_touch(s, u32(index))
	}
	return true
}

// Ensures GPU capacity for the current instance/light sets (between frames).
@(private)
ensure_scene_capacity :: proc(r: ^Renderer) -> bool {
	s := &r.scene
	d := r.device
	if len(s.materials) == 0 {
		changes := materials_grow(r, 1) or_return
		materials_changed(s, changes)
	}
	if len(s.materials) > s.material_capacity || s.material_buffer == 0 {
		capacity := max(len(s.materials) + len(s.materials) / 2, 32)
		if s.material_buffer != 0 {rhi.buffer_destroy(d, s.material_buffer)}
		s.material_buffer = rhi.buffer_create(d, {size = u64(capacity * size_of(Gpu_Material_Row)), usage = {.Storage}, name = "materials"})
		s.material_capacity = capacity
		s.materials_dirty = true
	}
	// The rows of the batches drawn follow the instances in the table.
	count := max(len(s.instances) + len(s.batch.rows), 1)
	if count > s.instance_capacity || s.instance_buffer == 0 {
		capacity := max(count + count / 2, 64)
		if s.instance_buffer != 0 {rhi.buffer_destroy(d, s.instance_buffer)}
		s.instance_buffer = rhi.buffer_create(d, {size = u64(capacity * size_of(Gpu_Instance)), usage = {.Storage}, name = "instances"})
		s.instance_capacity = capacity
		s.instances_dirty = true
	}
	// The lists of the cull of a view: what passes their capacity is dropped
	// and counted, and they grow to what the frame that dropped asked for.
	if s.cull_state_buffer == 0 {
		s.cull_state_buffer = rhi.buffer_create(d, {size = size_of(Gpu_Cull_State), usage = {.Storage, .Indirect}, name = "cull state"})
	}
	start := CULL_START
	for list in Cull_List {
		buffer := [Cull_List]^rhi.Buffer{.Chunks = &s.chunk_buffer, .Visible = &s.visible_buffer, .Candidates = &s.cluster_candidate_buffer, .Programs = &s.program_visible}[list]
		wanted := max(start[list], s.cull_wanted[list])
		if buffer^ != 0 && wanted <= s.cull_capacity[list] {continue}
		capacity := max(wanted + wanted / 2, start[list], s.cull_capacity[list])
		if buffer^ != 0 {rhi.buffer_destroy(d, buffer^)}
		names := [Cull_List]string{.Chunks = "cull chunks", .Visible = "visible clusters", .Candidates = "cluster occlusion candidates", .Programs = "visible clusters by program"}
		buffer^ = rhi.buffer_create(d, {size = u64(capacity) * size_of([2]u32), usage = {.Storage}, name = names[list]})
		made := buffer^ != 0
		if list == .Programs {
			if s.program_bins != 0 {rhi.buffer_destroy(d, s.program_bins)}
			s.program_bins = rhi.buffer_create(d, {size = u64(program_entry_word(capacity)) * size_of(u32), usage = {.Storage, .Indirect}, name = "visible clusters of programs"})
			made &&= s.program_bins != 0
		}
		s.cull_capacity[list] = capacity if made else 0
	}
	candidates := max(len(s.instances) + int(s.batch.slots), 1)
	if candidates > s.candidate_capacity || s.candidate_buffer == 0 {
		capacity := max(candidates + candidates / 2, 64)
		if s.candidate_buffer != 0 {rhi.buffer_destroy(d, s.candidate_buffer)}
		s.candidate_buffer = rhi.buffer_create(d, {size = u64(capacity * size_of(u32)), usage = {.Storage}, name = "occlusion candidates"})
		s.candidate_capacity = capacity
	}
	// The native TLAS holds the instances and those of the batches rays meet.
	if tlas_count := max(len(s.instances) + s.batch.hw_count, 1); r.hardware_rt && (u32(tlas_count) > s.tlas_capacity || s.tlas == 0) {
		capacity := max(tlas_count + tlas_count / 2, 64)
		if s.tlas != 0 {rhi.accel_destroy(d, s.tlas)}
		s.tlas = rhi.tlas_create(d, u32(capacity), "scene tlas")
		if s.tlas_instance_buffer != 0 {rhi.buffer_destroy(d, s.tlas_instance_buffer)}
		s.tlas_instance_buffer = rhi.buffer_create(d, {size = u64(capacity) * size_of(rhi.Tlas_Instance), usage = {.Storage}, name = "tlas instances"})
		s.tlas_capacity = u32(capacity) if s.tlas != 0 && s.tlas_instance_buffer != 0 else 0
		s.tlas_dirty = true
	}
	// Only rays traced by software walk the tree of instances on the GPU.
	nodes := max(len(s.tlas_nodes), 1)
	if !r.hardware_rt && (nodes > s.tlas_node_capacity || s.tlas_node_buffer == 0) {
		capacity := max(nodes + nodes / 2, 128)
		if s.tlas_node_buffer != 0 {rhi.buffer_destroy(d, s.tlas_node_buffer)}
		s.tlas_node_buffer = rhi.buffer_create(d, {size = u64(capacity * size_of(Gpu_Bvh_Node)), usage = {.Storage}, name = "tlas nodes"})
		s.tlas_node_capacity = capacity
		s.instances_dirty = true
	}
	// One reference per instance, independent of the node count (leaves may
	// hold several instances).
	refs := max(len(s.tlas_refs), 1)
	if !r.hardware_rt && (refs > s.tlas_ref_capacity || s.tlas_ref_buffer == 0) {
		capacity := max(refs + refs / 2, 128)
		if s.tlas_ref_buffer != 0 {rhi.buffer_destroy(d, s.tlas_ref_buffer)}
		s.tlas_ref_buffer = rhi.buffer_create(d, {size = u64(capacity * size_of(u32)), usage = {.Storage}, name = "tlas refs"})
		s.tlas_ref_capacity = capacity
		s.instances_dirty = true
	}
	lights := max(len(s.lights) + light_region_lights(s.light_region), 1)
	if lights > s.light_capacity || s.light_buffer == 0 {
		capacity := max(lights + lights / 2, 32)
		if s.light_buffer != 0 {rhi.buffer_destroy(d, s.light_buffer)}
		s.light_buffer = rhi.buffer_create(d, {size = u64(capacity * size_of(Gpu_Light)), usage = {.Storage}, name = "lights"})
		s.light_capacity = capacity
		s.lights_dirty = true
	}
	if len(s.light_tree) > s.light_tree_capacity || s.light_tree_buffer == 0 {
		capacity := max(len(s.light_tree) + len(s.light_tree) / 2, 64)
		if s.light_tree_buffer != 0 {rhi.buffer_destroy(d, s.light_tree_buffer)}
		s.light_tree_buffer = rhi.buffer_create(d, {size = u64(capacity * size_of(Gpu_Light_Node)), usage = {.Storage}, name = "light tree"})
		s.light_tree_capacity = capacity
		s.lights_dirty = true
	}
	ok := s.instance_buffer != 0 && s.material_buffer != 0 && s.cull_state_buffer != 0 && s.chunk_buffer != 0 && s.visible_buffer != 0 && s.cluster_candidate_buffer != 0 && s.candidate_buffer != 0 && (r.hardware_rt || s.tlas_node_buffer != 0 && s.tlas_ref_buffer != 0) && s.light_buffer != 0 && s.light_tree_buffer != 0
	if !ok {set_error(r, "scene buffers: %s", rhi.device_error(d))}
	return ok
}

@(private)
upload_transient :: proc(r: ^Renderer, cmd: ^rhi.Command_List, data: []$T, target: rhi.Buffer, offset: u64 = 0) -> bool {
	if len(data) == 0 {return true}
	bytes := slice_bytes(data)
	t := rhi.frame_alloc(r.device, u64(len(bytes)), 16)
	if t.ptr == nil {set_error(r, "transient ring exhausted uploading %d bytes", len(bytes)); return false}
	copy(([^]u8)(t.ptr)[:len(bytes)], bytes)
	rhi.cmd_copy_buffer(cmd, t.buffer, t.offset, target, offset, u64(len(bytes)))
	return true
}

// Marks an instance of the table to go to the GPU alone with the next frame.
@(private)
instance_touch :: proc(s: ^Scene_State, index: u32) {
	word, bit := &s.touched[index >> 6], u64(1) << (index & 63)
	if word^ & bit != 0 {return}
	word^ |= bit
	s.touched_count += 1
}

// The next run of touched instances that starts at `from` or after it. False past the last one.
@(private)
touched_range :: proc(s: ^Scene_State, from: u32) -> (range: Pool_Range, ok: bool) {
	words := u32(len(s.touched))
	first := from
	for {
		if first >> 6 >= words {return}
		if rest := s.touched[first >> 6] >> (first & 63); rest != 0 {
			first += u32(intrinsics.count_trailing_zeros(rest))
			break
		}
		first = ((first >> 6) + 1) << 6
	}
	end := first
	for end >> 6 < words {
		// The bits the shift brings in are not of the word: without a clear one the run goes on in the next.
		if rest := ~s.touched[end >> 6] >> (end & 63); rest != 0 {
			end += u32(intrinsics.count_trailing_zeros(rest))
			break
		}
		end = ((end >> 6) + 1) << 6
	}
	return {first, end - first}, true
}

// The table keeps `count` instances: those past them are touched no more.
@(private)
touched_trim :: proc(s: ^Scene_State, count: int) {
	for range, ok := touched_range(s, u32(count)); ok; range, ok = touched_range(s, range.first + range.count) {s.touched_count -= int(range.count)}
	words := (count + 63) / 64
	base.truncate(&s.touched, words)
	if count & 63 != 0 && words <= len(s.touched) {s.touched[words - 1] &= (u64(1) << uint(count & 63)) - 1}
}

// The touched instances, each run of them to its place in the table.
@(private = "file")
upload_touched :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	s := &r.scene
	size := u64(size_of(Gpu_Instance))
	t := rhi.frame_alloc(r.device, u64(s.touched_count) * size, 16)
	if t.ptr == nil {set_error(r, "transient ring exhausted uploading %d instances", s.touched_count); return false}
	at := u64(0)
	for range, ok := touched_range(s, 0); ok; range, ok = touched_range(s, range.first + range.count) {
		bytes := slice_bytes(s.instances[range.first:][:range.count])
		mem.copy(rawptr(uintptr(t.ptr) + uintptr(at)), raw_data(bytes), len(bytes))
		rhi.cmd_copy_buffer(cmd, t.buffer, t.offset + at, s.instance_buffer, u64(range.first) * size, u64(len(bytes)))
		at += u64(len(bytes))
	}
	return true
}

// The rows of data in ranges, each to its place in target.
@(private = "file")
upload_ranges :: proc(r: ^Renderer, cmd: ^rhi.Command_List, data: []$T, ranges: []Pool_Range, target: rhi.Buffer) -> bool {
	rows := 0
	for range in ranges {rows += int(range.count)}
	if rows == 0 {return true}
	size := u64(size_of(T))
	t := rhi.frame_alloc(r.device, u64(rows) * size, 16)
	if t.ptr == nil {set_error(r, "transient ring exhausted uploading %d rows", rows); return false}
	at := u64(0)
	for range in ranges {
		bytes := slice_bytes(data[range.first:][:range.count])
		mem.copy(rawptr(uintptr(t.ptr) + uintptr(at)), raw_data(bytes), len(bytes))
		rhi.cmd_copy_buffer(cmd, t.buffer, t.offset + at, target, u64(range.first) * size, u64(len(bytes)))
		at += u64(len(bytes))
	}
	return true
}

// After an upload: what was drawn in motion is at rest in the next frame,
// previous = current, and goes once more; what was at rest is done.
@(private)
touched_settle :: proc(s: ^Scene_State) {
	for range, ok := touched_range(s, 0); ok; range, ok = touched_range(s, range.first + range.count) {
		for index in range.first ..< range.first + range.count {
			inst := &s.instances[index]
			if inst.prev_world != inst.world {
				inst.prev_world = inst.world
				continue
			}
			s.touched[index >> 6] &~= u64(1) << (index & 63)
			s.touched_count -= 1
		}
	}
}

// Records uploads of dirty scene data and the hardware TLAS build.
@(private)
upload_scene :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	s := &r.scene
	tlas_settle(s)
	if !poses_record(r,cmd) {return false}
	// What the frame's transient memory has no room for stays dirty and goes
	// with the next frame: the GPU never falls behind the scene unnoticed.
	ok := true
	textures_touched(r)
	if s.instances_dirty || s.materials_dirty || len(s.material_ranges) > 0 {r.glass_stale = true}
	// The row of an instance with glass brings the mean the CPU holds, not the one glass_mean.comp gave it.
	if !r.glass_stale && len(s.translucent) > 0 {
		each: for range, more := touched_range(s, 0); more; range, more = touched_range(s, range.first + range.count) {
			for &inst in s.instances[range.first:][:range.count] {
				if inst.meta.w & INSTANCE_FLAG_TRANSLUCENT != 0 {r.glass_stale = true;break each}
			}
		}
	}
	if s.materials_dirty {
		if upload_transient(r, cmd, s.materials[:], s.material_buffer) {
			s.materials_dirty = false
			clear(&s.material_ranges)
		} else {ok = false}
	} else if len(s.material_ranges) > 0 {
		if upload_ranges(r, cmd, s.materials[:], s.material_ranges[:], s.material_buffer) {clear(&s.material_ranges)} else {ok = false}
	}
	// Only rays traced by software walk the tree of instances.
	tree := !r.hardware_rt
	if s.instances_dirty {
		if upload_transient(r, cmd, s.instances[:], s.instance_buffer) && batches_upload(r, cmd, true) && (!tree || upload_transient(r, cmd, s.tlas_nodes[:], s.tlas_node_buffer) && upload_transient(r, cmd, s.tlas_refs[:], s.tlas_ref_buffer)) {
			s.instances_dirty = false
			s.tlas_nodes_dirty, s.tlas_refs_dirty = false, false
			touched_settle(s)
		} else {ok = false}
	} else {
		if !batches_upload(r, cmd, false) {ok = false}
		if s.touched_count > 0 {
			if upload_touched(r, cmd) {touched_settle(s)} else {ok = false}
		}
		if s.tlas_nodes_dirty {
			if !tree || upload_transient(r, cmd, s.tlas_nodes[:], s.tlas_node_buffer) && (!s.tlas_refs_dirty || upload_transient(r, cmd, s.tlas_refs[:], s.tlas_ref_buffer)) {
				s.tlas_nodes_dirty, s.tlas_refs_dirty = false, false
			} else {ok = false}
		}
	}
	if s.lights_dirty {
		if s.light_region.lights > 0 {rhi.cmd_fill_buffer(cmd, s.light_buffer, u64(len(s.lights) * size_of(Gpu_Light)), u64(light_region_lights(s.light_region) * size_of(Gpu_Light)), 0)}
		if upload_transient(r, cmd, s.lights[:], s.light_buffer) && upload_transient(r, cmd, s.light_tree[:], s.light_tree_buffer) {
			s.lights_dirty = false
			clear(&s.light_ranges)
			clear(&s.light_node_ranges)
		} else {ok = false}
	} else if len(s.light_ranges) > 0 || len(s.light_node_ranges) > 0 {
		if upload_ranges(r, cmd, s.lights[:], s.light_ranges[:], s.light_buffer) && upload_ranges(r, cmd, s.light_tree[:], s.light_node_ranges[:], s.light_tree_buffer) {
			clear(&s.light_ranges)
			clear(&s.light_node_ranges)
		} else {ok = false}
	}
	// The programs of the instances read the tables just uploaded.
	if ok && !displaced_record(r, cmd) {ok = false}
	return ok
}

// The trees of the poses that changed, once the extensions wrote their
// vertices, and the native TLAS over them.
@(private)
deformables_record :: proc(r: ^Renderer, cmd: ^rhi.Command_List) -> bool {
	s := &r.scene
	if !poses_refit(r, cmd) {return false}
	if r.hardware_rt && s.tlas_dirty && s.tlas != 0 {
		instances := tlas_instances_record(r, cmd)
		if instances >= 0 && rhi.cmd_build_tlas(cmd, s.tlas, s.tlas_instance_buffer, 0, u32(instances)) {
			s.tlas_dirty = false
			r.tlas_problem = ""
		} else {
			// It stays dirty: the next frame tries again, and rays traced by
			// hardware meet nothing until one builds it.
			r.tlas_problem = fmt.bprintf(r.tlas_buffer[:], "the native TLAS of %d instances was not built (%s): rays traced by hardware meet nothing until it is. Fewer instances of batches that rays meet (Casts_Shadow, Ray_Visible), or rays traced by software (Settings.trace_mode = .Software), avoid it", len(s.hw_instances) + s.batch.hw_count, rhi.device_error(r.device))
		}
	}
	// Rays traced by software walk the tree of instances, uploaded with them:
	// nothing waits for a native one. Turning hardware rays on marks it again.
	if !r.hardware_rt {s.tlas_dirty = false}
	return true
}

scene_destroy :: proc(r: ^Renderer) {
	s := &r.scene
	d := r.device
	batches_destroy(r)
	for &m in s.meshes {skin_free(r,m.skin);skin_binding_release(r,m.skin_binding);mesh_stream_free(m.stream);for ray in m.rays[:m.ray_count] {if ray.blas != 0 {rhi.accel_destroy(d, ray.blas)}}}
	pages_destroy(r)
	if s.tlas != 0 {rhi.accel_destroy(d, s.tlas)}
	for b in s.geometry_staging {if b != 0 {rhi.buffer_destroy(d, b)}}
	for move in s.pool_moves {if move.from != 0 {rhi.buffer_destroy(d, move.from)}}
	for b in ([]rhi.Buffer{s.vertex_buffer, s.index_buffer, s.mesh_buffer, s.blas_node_buffer, s.blas_triangle_buffer, s.instance_buffer, s.material_buffer, s.tlas_node_buffer, s.tlas_ref_buffer, s.cull_state_buffer, s.chunk_buffer, s.visible_buffer, s.cluster_candidate_buffer, s.program_bins, s.program_visible, s.candidate_buffer, s.light_buffer, s.light_tree_buffer, s.tlas_instance_buffer}) {
		if b != 0 {rhi.buffer_destroy(d, b)}
	}
	delete(s.vertices)
	delete(s.indices)
	delete(s.meshes)
	delete(s.skinned)
	delete(s.blas_nodes)
	delete(s.blas_triangles)
	delete(s.free_meshes);delete(s.mesh_dirty)
	for ranges in s.pool_free {delete(ranges)}
	for ranges in s.pool_dirty {delete(ranges)}
	delete(s.translucent)
	delete(s.instances)
	delete(s.instance_next)
	delete(s.instance_prev)
	delete(s.overlays)
	delete(s.reflective)
	delete(s.materials)
	delete(s.material_ranges)
	delete(s.instance_keys)
	delete(s.desc_instance)
	delete(s.previous)
	delete(s.displaced)
	delete(s.material_versions)
	delete(s.tlas_nodes)
	delete(s.tlas_refs)
	delete(s.tlas_items)
	delete(s.tlas_scratch)
	delete(s.touched)
	delete(s.hw_instances)
	delete(s.lights)
	delete(s.light_tree)
	delete(s.light_keys)
	delete(s.light_leaves)
	delete(s.light_ranges)
	delete(s.light_node_ranges)
	s^ = {}
}
