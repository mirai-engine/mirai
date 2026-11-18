package mirai_render

import "mirai:asset"
import mm "mirai:std/math"
import "mirai:render/abi"

// CPU mirrors of shaders/include/common.slang. The generated shaders_gen.odin
// asserts the size and the offset of each field of those it shares, as Slang
// lays them out: a change on either side fails the build instead of
// corrupting GPU data.
Mat4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Gpu_Frame :: struct {
	view, proj, view_proj, inv_view_proj, prev_view_proj: Mat4, // from the eye: camera_position, prev_eye for prev_view_proj
	view_proj_unjittered: Mat4,
	camera_position: Vec4, // w = near
	camera_forward:  Vec4, // w = far
	sun_direction:   Vec4, // w = 0: no sun; 1: active; SUN_UNSHADOWED: active, and no ray goes to it
	sun_color:       Vec4, // above the air of an atmosphere; w = the angular radius of its disc in the sky, radians; 0: it is not seen
	sky_color:       Vec4, // rgb the luminance of the sky, render units; w the light scale, render units per nit
	background:      Vec4, // w = 1: solid background instead of the sky
	frustum:         [6]Vec4,
	volume_cascades: [VOLUME_CASCADES_MAX]Vec4, // xyz the place of the probe at the lowest corner of each cascade, relative to the origin, w its spacing
	volume_counts:   [4]u32, // xyz probes of a cascade along each axis, w cascades
	volume_atlas:    [4]u32, // x probes per atlas row, y irradiance tile, z distance tile, w 1 when the volume holds light
	resolution:      Vec2,
	inv_resolution:  Vec2,
	frame_index:     u32,
	light_nodes:     u32,
	instance_count:  u32,
	debug_view:      u32,
	gi_strength:     f32,
	exposure:        f32,  // the scene-linear value of one render unit, as a frame before exposed the view
	own:             u32,  // bits 0-7: 1 + the local slot whose body (INSTANCE_FLAG_OWNED) is the view's own, 0: none; bits 16-31: how much of it the view fades out, unorm
	flags:           u32,
	shadowless_lights: [4]u32, // x the root of the tree of the local lights that cast no shadows (light_region_frame), 0: none; y the node after it; zw 0
	jitter:          Vec4, // xy current jitter (render pixels), zw previous
	texturing:       Vec4, // x mip bias of rasterized material textures, y traced reflection roughness, zw where the boxes of the glass instances are listed after the TLAS nodes and how many
	time: Vec4, // current seconds, previous seconds, frame dt, reserved
	// The ray of the pixel at uv: a point at linear depth d along it is
	// (eye_origin + eye_du * u + eye_dv * v) + d * (ray_origin + ray_du * u + ray_dv * v).
	eye_origin, eye_du, eye_dv: Vec4,
	ray_origin, ray_du, ray_dv: Vec4,
	eye:              Vec4, // the eye as a point (xyz, 1), or the direction towards it (xyz, 0) for a parallel projection
	depth_plane:      Vec4, // linear depth of a world point: dot(xyz, point) + w
	prev_depth_plane: Vec4,
	prev_eye:         Vec4, // xyz the eye prev_view_proj takes points from
	clip_plane:       Vec4, // world plane nothing is drawn behind; zero: none
	footprint:        Vec2, // width of a pixel at depth 0, and what it grows by per unit of depth
	layers:           u32,  // bits 0-15: the layers the view draws; bits 16-31: those of its own body it does not draw
	view_index:       u32,  // of the nested view these constants draw; 0: the view itself
	sky_map:          Vec4, // x = the image of the sky in the texture table, y = 1 for an atmosphere lit by the sun, z = its last level, w = 1 with an image
	sky_orientation:  Vec4, // the turn of the sky, a quaternion (xyz, w)
	sky_from:         Vec4, // rgb the luminance a change of the sky comes from (render units), a how much of it still shows
	sky_from_map:     Vec4, // the image it comes from, as sky_map
	tint:             Vec4, // rgb what the image is multiplied by before the display
	air:              Gpu_Air, // the air of an atmosphere (sky_map.y), with sun_color the light of the sun above it
	origin:           [4]i32, // xyz what every place of the frame is relative to (origin.odin), in steps of ORIGIN_STEP
	scene_box:        [2]Vec4, // xyz the lowest corner of what rays meet, relative to the origin, then the highest; low above high: nothing
	volume_cells:     [VOLUME_CASCADES_MAX][4]i32, // xyz the cell of the world of the probe at the lowest corner of each cascade
	volume_center:    Vec4, // xyz where the cascades centre, relative to the origin, which moves on smoothly as they step a cell at a time
	detail_eye:       Vec4, // where the levels of detail are chosen from (xyz) and its near plane (w): the eye of the view, or that of Frame_Detail
	detail_footprint: Vec4, // xy the footprint of a pixel of that eye, as footprint; zw 0
	cut:              Vec4, // x the error in pixels the cut of the levels of the meshes allows (Settings.lod_error_pixels); 0 draws level 0. y the pixels across below which an instance of a batch is not rasterized (Settings.batch_min_pixels); 0 draws every one
	batches:          [4]u32, // the batches drawn: x their instance slots, y the first word of their group table in the u32 pool, z how many, w how many rays meet
	moved:            [4]u32, // what casts shadows and changed since the frame before (Occluder_Changes): x the boxes of moved_boxes, y the lights of moved_lights, z MOVED_* bits
	moved_boxes:      [OCCLUDER_CHANGES_MAX][2]Vec4, // low (w: the instance, as bits; OCCLUDERS_MANY: several) and high, relative to the origin
	moved_lights:     [LIGHT_MOVES_MAX / 4][4]u32,
	sun_maps:         [4]u32, // x the maps of the shadows of the sun the view drew this frame, the nearest cascade first (shadow_maps_pass), 0: none; y where the rows of the maps start in their buffer; z the side of their atlas, texels, while the view drew maps, else 0; w 1 while they keep the tint of glass
	sun_map_rows:     [abi.SUN_MAP_ROWS][4]u32,
}
SUN_UNSHADOWED   :: abi.SUN_UNSHADOWED
MOVED_SUN        :: abi.MOVED_SUN // the sun moved further than its radius, or came on
MOVED_LIGHTS_ALL :: abi.MOVED_LIGHTS_ALL // more lights moved than moved_lights holds: each counts as moved

// A nested view in the constants of its view (Nested_View of common.slang),
// which follow Gpu_Frame in a generation of shaders that has them.
Gpu_Nested :: struct {
	to_world:            [3]Vec4,
	from_world_previous: [3]Vec4,
	eye:                 Vec4,
	opening:             Vec4, // the plane its pixels are seen through, in the world of the view; zero: none known
}

FRAME_FLAG_GI           :: abi.FRAME_FLAG_GI
FRAME_FLAG_GI_GIVEN     :: abi.FRAME_FLAG_GI_GIVEN
FRAME_FLAG_HW_RT        :: abi.FRAME_FLAG_HW_RT
FRAME_FLAG_STUDIO       :: abi.FRAME_FLAG_STUDIO
FRAME_FLAG_GRID         :: abi.FRAME_FLAG_GRID
FRAME_FLAG_GLASS        :: abi.FRAME_FLAG_GLASS
FRAME_FLAG_REFLECTANCE  :: abi.FRAME_FLAG_REFLECTANCE
FRAME_FLAG_NEUTRAL      :: abi.FRAME_FLAG_NEUTRAL

// A whole vertex, which thumbnails and previews upload for themselves; the
// scene keeps its vertices in clusters (Gpu_Cluster).
Gpu_Vertex :: struct {
	position: Vec3,
	normal:   u32, // octahedral snorm16x2
	uv:       Vec2,
	color:    u32, // rgba8
	material: u32, // row of the material table, high bits carry source slot
	uv1:      Vec2,
	tangent:  u32, // std/math tangent_pack
}

// The geometry of the scene is in two pools of u32 words. The vertex pool
// holds the block of each page of each mesh (asset.mesh_page_layout: the
// vertices of its clusters, VERTEX_WORDS each, then its uv1, colors and
// surfaces, then the words of its triangles, three u8 indices a triangle)
// and the posed vertices of skinned and deformed meshes (POSED_WORDS each,
// Gpu_Posed_Vertex, by the index of the vertex in its mesh). The index pool
// holds the clusters (CLUSTER_WORDS each), the page table, the levels and
// the material of each slot of each mesh, the triangles of each cut that
// rays trace with hardware, and the instances of the batches. Every vertex
// and triangle of a cluster is read through the entry of its page.
Gpu_Cluster :: asset.Cluster
CLUSTER_WORDS :: abi.CLUSTER_WORDS
VERTEX_WORDS :: abi.VERTEX_WORDS
CLUSTER_TRIANGLES :: asset.CLUSTER_TRIANGLES
// The vertices a draw gives every cluster: the corners of as many triangles as one has.
CLUSTER_DRAW_VERTICES :: abi.CLUSTER_DRAW_VERTICES
// A level of a mesh in the index pool (asset.Mesh_Level): its first cluster,
// how many, their triangles, their error and that of what replaces them.
LEVEL_WORDS :: abi.LEVEL_WORDS

// A vertex of a skinned or deformed mesh where it is now: in the space of
// the mesh, unquantized.
Gpu_Posed_Vertex :: abi.Gpu_Posed_Vertex
POSED_WORDS :: abi.POSED_WORDS

// A page of a mesh in the page table (Gpu_Mesh.page_word): where its block
// is in the vertex pool, GPU_NONE while it is not there, and the first vertex,
// the vertices and the first word of triangles of the mesh it holds.
Gpu_Mesh_Page :: abi.Gpu_Mesh_Page
PAGE_ENTRY_WORDS :: abi.PAGE_ENTRY_WORDS

Gpu_Instance :: struct {
	world:      [3]Vec4,
	world_inv:  [3]Vec4,
	prev_world: [3]Vec4,
	meta:       [4]u32, // mesh (INSTANCE_MESH_MASK) and the cut rays trace it with (INSTANCE_RAY_SHIFT), material in place of the slots' (GPU_NONE: theirs), object id (low bits), flags
	bounds_min: Vec4,
	bounds_max: Vec4,
	tint:       Vec4,
	emission:   Vec4,
	glass:      Vec4, // written on the GPU by glass_mean.comp after every upload (glass_means_record)
	slot_materials: [32]u32,
	wet:        f32,    // 0 dry to 1 soaked, which the materials read (scene_set_instance_wet)
	material_values: u32, // 1 + the word of the index pool where what it gives over the rows of its materials starts (Instance_Material_Values); 0: nothing
	colors:     u32,    // its own color of each vertex of its mesh in the vertex pool, by index in the mesh (scene_set_instance_colors)
	color_count: u32,   // the vertices of its mesh; 0: the colors of the mesh
}
#assert(size_of(Gpu_Instance) % 16 == 0)
GPU_NONE :: max(u32)
// meta.x: the mesh in bits 0-23 and in bits 24-25 the cut of it rays trace,
// Gpu_Mesh.rays: 0 is level 0.
INSTANCE_MESH_MASK :: abi.INSTANCE_MESH_MASK
INSTANCE_RAY_SHIFT :: abi.INSTANCE_RAY_SHIFT
INSTANCE_FLAG_HIDDEN :: abi.INSTANCE_FLAG_HIDDEN
// Hidden only because it cannot be drawn yet: its transform has no inverse
// (a zero scale, or not finite) or the geometry of its mesh still goes to the
// GPU (geometry_uploads.odin). Nothing of it is drawn, outlined or traced
// until a move gives it one and its mesh is there (the CPU reads it).
INSTANCE_FLAG_COLLAPSED :: abi.INSTANCE_FLAG_COLLAPSED
// Within SMALL_INSTANCE_REACH of its centre: rays of the RAY_SMALL class meet
// it, and the probe volume, which does not ask for that class, never sees
// it. What moves of that size changes no light they hold:
// its shadow near it is the contact occlusion's, and what it gives off, the
// light inside it (light_stands_for) gives. A few fixed rays of a probe met a
// small thing that moves in some frames and not in others.
INSTANCE_FLAG_SMALL :: abi.INSTANCE_FLAG_SMALL
SMALL_INSTANCE_REACH :: f32(1) // metres
// Bits 8-12: outline level (0 none; see HIGHLIGHT_LEVELS), drawn in the
// outline mask and outlined after tonemapping.
INSTANCE_HIGHLIGHT_SHIFT :: abi.INSTANCE_HIGHLIGHT_SHIFT
INSTANCE_HIGHLIGHT_MASK :: u32(31) << INSTANCE_HIGHLIGHT_SHIFT
// Some triangles of the instance have a masked or blended material: rays ask
// the material whether they stop.
INSTANCE_FLAG_ALPHA_TESTED :: abi.INSTANCE_FLAG_ALPHA_TESTED
// The instance tint replaces vertex colors for every material consumer.
INSTANCE_FLAG_UNIFORM_COLOR :: abi.INSTANCE_FLAG_UNIFORM_COLOR
// Every material of the instance is blended: it has nothing for the G-buffer
// and belongs to the RAY_GLASS class.
INSTANCE_FLAG_BLENDED :: abi.INSTANCE_FLAG_BLENDED

// Some of the triangles of the instance are blended: seeing it turns on the
// glass passes.
INSTANCE_FLAG_TRANSLUCENT :: abi.INSTANCE_FLAG_TRANSLUCENT
// Bit 13: the instance is of the body of a local player, whose slot is in bits 14-15: a
// view of that slot (Gpu_Frame.own) fades it out and leaves out the layers it does not draw of it.
INSTANCE_FLAG_OWNED :: abi.INSTANCE_FLAG_OWNED
INSTANCE_OWNER_SHIFT :: abi.INSTANCE_OWNER_SHIFT
// Bits 16-31: the layers the instance is in. A view draws those that share one with its own.
INSTANCE_LAYERS_SHIFT :: abi.INSTANCE_LAYERS_SHIFT
LAYERS_ALL :: u32(0xffff)

// Hidden but outlined: only the highlight mask draws it (the CPU reads it).
INSTANCE_FLAG_OUTLINE_ONLY :: abi.INSTANCE_FLAG_OUTLINE_ONLY

// Whether the highlight mask draws an instance: highlighted, and shown or
// outline only and not collapsed.
highlight_drawn :: proc "contextless" (flags: u32) -> bool {
	return flags & INSTANCE_HIGHLIGHT_MASK != 0 && (flags & INSTANCE_FLAG_HIDDEN == 0 || flags & (INSTANCE_FLAG_OUTLINE_ONLY | INSTANCE_FLAG_COLLAPSED) == INSTANCE_FLAG_OUTLINE_ONLY)
}

// Classes of instances for rays, the mask of the instance in a native TLAS.
RAY_SOLID :: abi.RAY_SOLID
RAY_GLASS :: abi.RAY_GLASS
RAY_SMALL :: abi.RAY_SMALL // the solid instances of INSTANCE_FLAG_SMALL
RAY_SHADOW_ONLY :: abi.RAY_SHADOW_ONLY // the instances of a batch that casts shadows and that other rays do not see
RAY_UNSHADOWED :: abi.RAY_UNSHADOWED // the instances of a batch that rays see and that casts no shadow
// Set in the reference of a RAY_GLASS instance in the software TLAS.
TLAS_REF_GLASS :: abi.TLAS_REF_GLASS

// A cut of a mesh rays trace: the root of its tree and its first triangle
// (Gpu_Bvh_Triangle) by software; with hardware, where the clusters and
// triangles of the primitives of its BLAS are listed in the index pool. error:
// that of the cut, in the space of the mesh; 0 for level 0.
Gpu_Mesh_Ray :: struct {
	bvh_root, triangle_offset, table_word: u32,
	error: f32,
}

Gpu_Mesh :: struct {
	cluster_word:    u32, // its first cluster in the index pool
	cluster_count:   u32,
	level_word:      u32, // its levels in the index pool, LEVEL_WORDS each
	level_count:     u32,
	page_word:       u32, // its first page entry in the index pool, PAGE_ENTRY_WORDS each
	page_count:      u32,
	vertex_count:    u32,
	slot_word:       u32, // the material word of each of its slots in the index pool: row, and source slot << 24
	posed_word:      u32, // where it is posed, POSED_WORDS a vertex in the vertex pool; GPU_NONE: as its clusters
	previous_word:   u32, // where it was posed in the frame before
	part_word:       u32, // posed with its part collapsed, then where that was; GPU_NONE: none
	part_layers:     u32, // of its part: a view that does not draw them draws those vertices
	flags:           u32, // MESH_FLAG_*
	slab_axes:       u32, // see mesh_slab_axes
	position_step:   f32, // of the grids of its clusters (asset.Mesh_Info)
	uv_step:         f32,
	uv1_step:        f32,
	lod_reach:       f32, // how far a sphere of its levels reaches past its box, in its space
	bounds_word:     u32, // of a pose: the box and the cone of the normals of each cluster it poses, POSED_BOUNDS_WORDS each in the vertex pool, as the skin writes them; GPU_NONE: none
	pad0:            u32,
	bounds_min:      Vec4,
	bounds_max:      Vec4,
	rays:            [asset.MESH_RAY_LEVELS]Gpu_Mesh_Ray,
}
// Level 0 is closed: a cluster of it seen from behind the cone of its normals is hidden.
MESH_FLAG_CLOSED :: abi.MESH_FLAG_CLOSED
// Only level 0 is posed: the cut stays there.
MESH_FLAG_LEVEL0 :: abi.MESH_FLAG_LEVEL0
// The streams of the blocks of its pages past the vertices: the surface of a
// far mesh (asset.Surface_Vertex, two words a vertex), uv1 and colors (rgba8),
// a word a vertex; without uv1 a vertex has its uv, without colors white.
MESH_FLAG_SURFACE :: abi.MESH_FLAG_SURFACE
MESH_FLAG_UV1 :: abi.MESH_FLAG_UV1
MESH_FLAG_COLORS :: abi.MESH_FLAG_COLORS
// Its pages out of the root come and go in slots (pages.odin): the cull
// draws what is in the pools and asks for what it lacks.
MESH_FLAG_STREAMED :: abi.MESH_FLAG_STREAMED

// What an instance gives over the rows of its materials, which the shaders
// read where they read one of those rows at a point of it. It costs the
// instance its words in the index pool and no row of the material table.
INSTANCE_VALUES_MAX :: abi.INSTANCE_VALUES_MAX
INSTANCE_VALUES_HEADER :: abi.INSTANCE_VALUES_HEADER
INSTANCE_ROW_WORDS :: abi.INSTANCE_ROW_WORDS
// What an instance is given of them: the words of a row that differ from the
// table's, from which the renderer makes the row as the instance shows it.
INSTANCE_VALUE_COUNT_SHIFT :: 16
Instance_Material_Value :: struct {
	row:   u32,    // of the material table: the words are for the points of the instance that show it
	word:  u32,    // the first word of the row (Gpu_Material_Row) it gives; from INSTANCE_VALUE_COUNT_SHIFT, how many from it
	words: [4]u32, // in place of those of the row
}
Instance_Material_Values :: struct {
	count:   u32,
	fade:    f32, // how much of every row it fades out, 0 none to 1 all: an opaque row it fades blends
	entries: [INSTANCE_VALUES_MAX]Instance_Material_Value,
}
#assert(offset_of(Instance_Material_Values, entries) == abi.INSTANCE_VALUES_HEADER * size_of(u32))

// uv' = linear * uv + offset: the transform of the material and that of the
// map, composed. ray_lod: the texture level a ray adds for what they shrink.
Gpu_Material_Map_Transform :: struct {linear:Vec4,offset:Vec2,uv_set:u32,ray_lod:f32}
// The occlusion texture of a material whose occlusion is read from its metallic-roughness sample.
GPU_OCCLUSION_PACKED :: 0xFFFFFFFE

// The values of a row of the material table that shading holds by value.
// A texture is an index of the texture table, GPU_NONE for none.
Gpu_Material :: struct {
	base_color:           Vec3,
	opacity:              f32,
	emission:             Vec3, // by emission_mode: luminance in nits, or the exposed value
	normal_scale:         f32,
	roughness:            f32,
	metallic:             f32,
	occlusion_strength:   f32,
	alpha_cutoff:         f32,
	specular_color:       Vec3, // multiplies the dielectric F0 of its IOR
	specular_factor:      f32,
	transmission:         f32,
	ior:                  f32,
	thickness:            f32,
	attenuation_distance: f32,
	attenuation_color:    Vec3,
	alpha_mode:           u32, // asset.Alpha_Mode; a transmissive material is drawn blended unless masked
	layers:               u32, // asset.Material_Layers: which blocks of the row it reads
	emission_mode:        u32, // asset.Emission_Mode
	program_id:           u32,
	textures:             [asset.Material_Map_Kind]u32,
	row:                  u32, // shaders write the index they fetched it by; the CPU leaves it zero
}

// The blocks of a row read only when the bit of their layer is set.
Gpu_Material_Coat :: struct {
	color:        Vec3,
	weight:       f32,
	roughness:    f32,
	ior:          f32,
	normal_scale: f32,
}
Gpu_Material_Fuzz :: struct {
	color:     Vec3,
	weight:    f32,
	roughness: f32,
}
Gpu_Material_Anisotropy :: struct {
	amount:   f32,
	rotation: Vec2, // cosine and sine
}
Gpu_Material_Diffuse_Transmission :: struct {
	color:  Vec3,
	weight: f32,
}
// What a solid of glass scatters of what it stops (asset.Material_Info.scatter_color).
Gpu_Material_Volume :: struct {
	scatter: Vec3,
	_:       f32,
}

Gpu_Material_Blocks :: struct {
	coat:                 Gpu_Material_Coat,
	fuzz:                 Gpu_Material_Fuzz,
	anisotropy:           Gpu_Material_Anisotropy,
	diffuse_transmission: Gpu_Material_Diffuse_Transmission,
}
#assert(size_of(Gpu_Material) == abi.MATERIAL_WORDS * size_of(u32))
#assert(size_of(Gpu_Material_Blocks) == abi.MATERIAL_BLOCK_WORDS * size_of(u32))
#assert(offset_of(Gpu_Material_Row, custom_params) == abi.MATERIAL_PARAMETERS_WORD * size_of(u32))

// A row of the material table: the values, then what shading fetches at
// the point that uses it.
Gpu_Material_Row :: struct {
	using shared:   Gpu_Material,
	using blocks:   Gpu_Material_Blocks,
	volume:         Gpu_Material_Volume,
	map_transforms: [asset.Material_Map_Kind]Gpu_Material_Map_Transform,
	custom_params:  [16]Vec4,
}

Gpu_Light :: struct {
	position_range:  Vec4,
	color_intensity: Vec4,
	direction_cone:  Vec4, // spot: direction and cos(half-angle); a rectangle: the side it lights, w = GPU_LIGHT_RECT; w = GPU_LIGHT_POINT for the others
	size:            Vec4, // x the radius of the sphere or the capsule, metres; y half the segment of a capsule, or half the width of a rectangle; z half its height; w the bits of the material row whose emission a rectangle shows (0: none)
	axis:            Vec4, // xyz along the segment of a capsule, or the width of a rectangle
}
GPU_LIGHT_POINT :: abi.GPU_LIGHT_POINT
GPU_LIGHT_RECT :: abi.GPU_LIGHT_RECT

Gpu_Bvh_Node :: struct {
	bounds_min: Vec3,
	left_first: u32,
	bounds_max: Vec3,
	count:      u32,
}

Gpu_Bvh_Triangle :: struct {
	v0:        Vec3,
	primitive: u32, // index within the mesh
	v1, v2:    Vec4, // corners whole, so that one two triangles share is the same in both; w unused
}

Gpu_Probe :: struct {
	offset: Vec4,   // xyz from the center of its cell, metres; w how near it is to the change that keeps it awake, 0 to 1 (ddgi_touch.comp)
	cell:   [4]i32, // xyz the cell of the world it was last traced for, w PROBE_* flags
	frames: [4]u32, // x when it was last traced, y last used by a pixel, z last reached by a change
}

// The arguments of a draw indirect without indices, as Vulkan and Metal read them.
Gpu_Draw :: struct {
	vertex_count, instance_count, first_vertex, first_instance: u32,
}
#assert(size_of(Gpu_Draw) == 16)

// What the cull passes of a view count, in words of the buffer of its state.
// The draws of its two phases go first: an instance of a draw is a visible
// cluster, and those of phase 1 follow those of phase 0 in the visible list.
Gpu_Cull_State :: struct {
	draws:            [2]Gpu_Draw,
	chunk_dispatch:   [3]u32, // groups of the cluster pass over the chunks: x, y, 1
	chunk_count:      u32,
	candidate_dispatch: [3]u32, // groups of the pass of phase 1 over the clusters phase 0 found hidden
	candidate_count:  u32,
	dropped:          [Cull_List]u32, // past the capacities of the lists of the cull
}
#assert(size_of(Gpu_Cull_State) == 88)

// What the cull of the clusters the maps of the shadows draw counts
// (shadow_cull.slang): the draws of those that hide whole, of those of masked
// materials and of those of glass, the groups of its cluster pass over the
// chunks and how many chunks its instance pass handed over.
Gpu_Shadow_State :: struct {
	draws:            [SHADOW_DRAWS]Gpu_Draw,
	cluster_dispatch: [3]u32,
	chunk_count:      u32,
}
#assert(size_of(Gpu_Shadow_State) == 64)

Gpu_Cull_Stats :: struct {
	visible_instances, visible_triangles, culled_instances, occluded_instances: u32,
	probes_traced: u32, // copied at the end of the frame from the list of the probe volume
	visible_clusters: u32,
	kinds: [3]Visible_Kind, // by Visible_Kind_Id
	late:  Visible_Kind,    // what phase 1 drew: instances and clusters the pyramid of the frame showed after all
	dropped: [Cull_List]u32, // past the capacities of the lists of the cull, which grow from them
}
// Instances, clusters and triangles that passed the cull of a frame, of one kind.
Visible_Kind :: struct {instances, clusters, triangles: u32}
// Of the scene with a mesh of levels, of the scene with a mesh of one (terrain
// pieces and other meshes made at run time), or of a batch (cull_kind of cull_common.slang).
Visible_Kind_Id :: enum {Levels, Single, Batch}

// Indirect dispatch sizes of the glass passes, at render and at half
// resolution. The cull pass leaves them at zero while no instance with
// blended triangles passes its tests.
Gpu_Glass_Dispatch :: struct {
	full, half: [3]u32,
}

// The parameters of a post-process effect (Post_Parameters of common.slang).
Gpu_Post_Parameters :: struct {program,exposed,outlined:u32,fade:f32,values:[16]Vec4}

// A texel of the normal target of the G-buffer as gbuffer.slang decodes it:
// the shading normal (octahedral), its roughness and the layer bits.
gbuffer_normal_decode :: proc "contextless" (texel: Vec4) -> (normal: Vec3, roughness: f32, layers: u32) {
	return mm.octahedral_decode(texel.xy), texel.z, u32(texel.w + 0.5)
}

// The lists of the cull of a view: chunks of the instance pass, visible
// clusters of both phases, and clusters phase 0 found hidden; and of the cull
// of its maps of the shadows, its chunks and the clusters the maps draw, of 16
// bytes each (shadow_cull.slang). What does not
// fit is dropped and counted (Gpu_Cull_State.dropped, Gpu_Cull_Stats.dropped),
// and the renderer grows the list for the frames after: a frame may show
// holes where a list first overflows, never again at that size.
// Programs: the visible clusters of materials with a Surface program
// (Scene_State.program_bins), which the G-buffer draws by program.
Cull_List :: enum {Chunks, Visible, Candidates, Programs, Shadow_Chunks, Shadow_Entries}
CULL_START :: [Cull_List]u32{.Chunks = 1 << 16, .Visible = 1 << 18, .Candidates = 1 << 16, .Programs = 1 << 14, .Shadow_Chunks = 1 << 14, .Shadow_Entries = 1 << 18}
