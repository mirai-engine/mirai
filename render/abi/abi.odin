package abi

import "mirai:asset"

// What the renderer and its shaders agree on by value: binding slots, flag
// bits, the words of the layouts of the pools and the limits both size their
// arrays with. Each is written here alone. render uses them under the same
// names, where it says what each is for, and cook/shaders writes those the
// shaders read into the include they take them from (shared_constants.slang):
// a package apart from render, so that the tool that generates the shaders
// builds without the tables it generates for render.

// Binding slots: one table for all passes. Samplers stay below 16 (Metal
// limit), buffers below 30 and textures below 128, so the slot is also the
// Metal index.
SLOT_FRAME            :: 0
SLOT_PARAMS           :: 1
SLOT_LINEAR_SAMPLER   :: 2
SLOT_POINT_SAMPLER    :: 3
SLOT_INSTANCES        :: 4
SLOT_MESHES           :: 5
SLOT_VERTICES         :: 6
SLOT_INDICES          :: 7
SLOT_MATERIALS        :: 8
SLOT_LIGHTS           :: 9
SLOT_LIGHT_TREE       :: 10
SLOT_BLAS_NODES       :: 11
SLOT_BLAS_TRIANGLES   :: 12
SLOT_TLAS_NODES       :: 13
SLOT_TLAS_REFS        :: 14
SLOT_MATERIAL_SAMPLER :: 15
SLOT_PROBES           :: 16
TEXTURE_FEEDBACK_SLOT :: 17
SLOT_POINTS           :: 18
SLOT_PASS0            :: 19
SLOT_PASS1            :: 20
SLOT_PASS2            :: 21
SLOT_PASS3            :: 22
SLOT_PASS4            :: 23
SLOT_PASS5            :: 24
SLOT_PASS6            :: 25
SLOT_PASS7            :: 26
SLOT_PASS8            :: 27
SLOT_PASS9            :: 28
SLOT_TLAS             :: 29
SLOT_SURFACE          :: 30
SLOT_VIEWS            :: 31
SLOT_LAYERS           :: 32
SLOT_DISTANCE         :: 33
SLOT_IRRADIANCE       :: 34
SLOT_DRAW             :: SLOT_PASS9

// The finest level the passes that shade surfaces sample of each texture
// (render/texture_residency.odin): words before the first texture (the first
// says how many textures the passes may write), and the code of a level:
// steps of 1/TEXTURE_FEEDBACK_STEPS from TEXTURE_FEEDBACK_LOW, below
// TEXTURE_FEEDBACK_CODES. Its buffer has a slot of its own, not a SLOT_PASS
// one: the material points bind it between the dispatches of any pass.
TEXTURE_FEEDBACK_FIRST :: 1
TEXTURE_FEEDBACK_LOW   :: -32
TEXTURE_FEEDBACK_STEPS :: 16
TEXTURE_FEEDBACK_CODES :: 64 * TEXTURE_FEEDBACK_STEPS
// Of the material sampler: the samples anisotropic filtering spreads along the longer axis of a footprint.
MATERIAL_ANISOTROPY    :: 8

// The texture table: its first entries hold the tables of the renderer.
TEXTURE_RESERVED          :: 4
DFG_TEXTURE               :: 0
AIR_TRANSMITTANCE_TEXTURE :: 1
AIR_SCATTERING_TEXTURE    :: 2
AIR_SKY_TEXTURE           :: 3

// The constants of a frame (Gpu_Frame).
VIEW_CAPACITY        :: 4
NESTED_VIEW_CAPACITY :: 4
VOLUME_CASCADES_MAX  :: 6
OCCLUDER_CHANGES_MAX :: 16
LIGHT_MOVES_MAX      :: 16
OCCLUDERS_MANY       :: max(u32)
SUN_UNSHADOWED       :: f32(2)
MOVED_SUN            :: 1
MOVED_LIGHTS_ALL     :: 2
ORIGIN_STEP          :: f32(1024)

// Gpu_Frame.flags.
FRAME_FLAG_GI           :: 1
FRAME_FLAG_GI_GIVEN     :: 2   // a custom pass of the pipeline wrote Gi: the composite takes it as the diffuse indirect light
FRAME_FLAG_HW_RT        :: 4
FRAME_FLAG_STUDIO       :: 8   // a preview lit by the analytic studio
FRAME_FLAG_GRID         :: 16
FRAME_FLAG_GLASS        :: 32  // some instance has blended triangles
FRAME_FLAG_REFLECTANCE  :: 64  // the G-buffer keeps what each pixel reflects (surface_specular)
FRAME_FLAG_NEUTRAL      :: 128 // the display transform is PBR Neutral, computed (display_encode); else the display LUT

// Gpu_Instance.meta: the mesh and the cut rays trace in x, the flags in w.
INSTANCE_MESH_MASK          :: u32(0xffffff)
INSTANCE_RAY_SHIFT          :: 24
INSTANCE_FLAG_HIDDEN        :: 1
INSTANCE_FLAG_COLLAPSED     :: 2
INSTANCE_FLAG_SMALL         :: 4
INSTANCE_FLAG_ALPHA_TESTED  :: 8
INSTANCE_FLAG_UNIFORM_COLOR :: 16
INSTANCE_FLAG_BLENDED       :: 32
INSTANCE_FLAG_TRANSLUCENT   :: 64
INSTANCE_FLAG_OUTLINE_ONLY  :: 128
INSTANCE_HIGHLIGHT_SHIFT    :: 8
INSTANCE_FLAG_OWNED         :: u32(1) << 13
INSTANCE_OWNER_SHIFT        :: 14
INSTANCE_LAYERS_SHIFT       :: 16
HIGHLIGHT_LEVELS            :: 15
OUTLINE_STYLES              :: 15

// Gpu_Mesh.flags.
MESH_FLAG_CLOSED   :: 1
MESH_FLAG_LEVEL0   :: 2
MESH_FLAG_SURFACE  :: 4
MESH_FLAG_UV1      :: 8
MESH_FLAG_COLORS   :: 16
MESH_FLAG_STREAMED :: 32

// The geometry pools, in u32 words.
Gpu_Posed_Vertex :: struct {
	position: [3]f32,
	normal:   u32, // octahedral snorm16x2
	tangent:  u32, // std/math tangent_pack
}
Gpu_Mesh_Page :: struct {
	base, first_vertex, vertex_count, first_triangle: u32,
}
CLUSTER_WORDS           :: size_of(asset.Cluster) / 4
VERTEX_WORDS            :: size_of(asset.Cluster_Vertex) / 4
POSED_WORDS             :: size_of(Gpu_Posed_Vertex) / 4
PAGE_ENTRY_WORDS        :: size_of(Gpu_Mesh_Page) / 4
LEVEL_WORDS             :: 5
CLUSTER_DRAW_VERTICES   :: asset.CLUSTER_TRIANGLES * 3
PRIMITIVE_TRIANGLE_BITS :: 7
PAGE_SLOT_WORDS         :: asset.MESH_PAGE_WORDS
PAGE_REQUEST_FIRST      :: 4
BATCH_GROUP             :: 64
BATCH_WORDS             :: 5
// Of a pose, from Gpu_Mesh.bounds_word, POSED_BOUNDS_WORDS for each cluster it
// poses as the skin wrote them this frame: the low corner of its box and its
// flags (POSED_BOUNDS_BOX, POSED_BOUNDS_CONE, and in bits 8-15 the cutoff of
// the cone, snorm8, as Cluster.counts holds it), then the high corner and the
// axis of the cone (octahedral snorm8), in the space of the mesh.
POSED_BOUNDS_WORDS      :: 8
POSED_BOUNDS_BOX        :: 1
POSED_BOUNDS_CONE       :: 2

// The classes of instances for rays.
RAY_SOLID       :: 1
RAY_GLASS       :: 2
RAY_SMALL       :: 4
RAY_SHADOW_ONLY :: 8
RAY_UNSHADOWED  :: 16
TLAS_REF_GLASS  :: u32(1) << 31

// Local lights and their tree.
GPU_LIGHT_POINT            :: -2.0
GPU_LIGHT_RECT             :: -3.0
GPU_LIGHT_NODE_LEAF        :: 1
GPU_LIGHT_NODE_SPOT        :: 2
GPU_LIGHT_NODE_COUNT_SHIFT :: 2
LIGHT_TREE_DEPTH           :: 48
LIGHT_CUT_MAX              :: 32
// The rows of the grid of the lights a light keeps for a pixel to weigh it by.
LIGHT_WEIGHT_ROWS          :: 2

// The maps of the shadows of a view. The buffer of the maps (uint4 rows): a
// word for each light, four to a row, 0 for a light without maps, else its
// first map + 1 and, from bit SHADOW_LIGHT_FACES, which faces of its cube have
// one; then SHADOW_MAP_ROWS for each map. The constants of a view hold those of
// the cascades of the sun, SUN_MAP_ROWS.
SHADOW_MAP_ROWS            :: 6
SHADOW_LIGHT_FACES         :: 16
// The face of a spot whose one map lies along its cone, after the six of the cube.
SHADOW_SPOT_FACE           :: 6
SHADOW_MAP_ORTHOGRAPHIC    :: 1
SHADOW_SUN_MAPS            :: 6
SUN_MAP_ROWS               :: SHADOW_SUN_MAPS * SHADOW_MAP_ROWS
REFLECTION_SHARED_ROUGHNESS :: f32(0.15)

// The probe volume, and the rays of its contact occlusion at each pixel.
DISTANCE_TILE :: 16
PROBE_BUCKETS :: 22
CONTACT_RAYS  :: 4

// The tables of the lobe and of the air, and the display.
DFG_SIZE               :: 64
AIR_TRANSMITTANCE_SIZE :: [2]u32{256, 64}
AIR_SCATTERING_SIZE    :: 32
AIR_SKY_SIZE           :: [2]u32{256, 128}
AIR_SKY_ROWS           :: VIEW_CAPACITY
AIR_AERIAL_SIZE        :: 32
AIR_AERIAL_SLICES      :: 32
DISPLAY_LUT_SIZE       :: 65
MIDDLE_GRAY            :: f32(0.18)
EXPOSURE_BINS          :: 128

// The depth the CPU reads around a pixel.
DEPTH_PROBE_CAPACITY :: 8
DEPTH_PROBE_CELLS    :: 32
DEPTH_PROBE_CELL     :: 2

// The points of the outlines of one table of volumes a shader weighs (engine/volume).
VOLUME_OUTLINE_POINTS :: 64

// The winds a shader combines (engine/volume).
WIND_VOLUMES :: 8

// What a view shows instead of its lit image (DEBUG_* in the shaders).
Debug_View :: enum u32 {
	None, Albedo, Normal, Direct, Indirect, Probes, Motion, Depth, Roughness, Metallic, Emission, Unlit, Lighting,
	Shadows, Reflections, Reflections_Raw, Lights,
}

// The header of the material points, in words. Points and heads go round the
// buffer: a round appends past the window the resume reads, in the larger
// room before or after it; those that do not fit are dropped.
POINTS_CAPACITY    :: 0  // points a batch holds at once; a head per point at most
POINTS_PROGRAMS    :: 1  // bins: the largest program id, plus one
POINTS_WANTED      :: 2  // the most room a round of the frame asked for: the buffer grows to it
POINTS_COUNT       :: 3  // points appended since the last resolve
POINTS_BASE        :: 4  // where they go: from the base up to the limit
POINTS_LIMIT       :: 5
POINTS_HEADS       :: 6  // and the same of heads
POINTS_HEADS_BASE  :: 7
POINTS_HEADS_LIMIT :: 8
POINTS_FROM        :: 9  // the window of points the last resolve evaluated
POINTS_TO          :: 10
POINTS_HEADS_FROM  :: 11 // and the heads of the round it ended, which the resume reads
POINTS_HEADS_TO    :: 12
POINTS_ARGS        :: 13 // three words: a thread per point of the window
POINTS_HEAD_ARGS   :: 16 // three words: a thread per head of the round, in groups of POINTS_HEAD_GROUP
POINTS_HEADER      :: 20
POINT_WORDS        :: 9
RECORD_WORDS       :: 18
HEAD_WORDS         :: 8

// The header of the visible clusters of Surface programs, in words.
PROGRAMS_COUNT    :: 0 // a word a phase
PROGRAMS_DISPATCH :: 2 // three words a phase
PROGRAMS_HEADER   :: 8

// The values an instance gives over the rows of its materials, in the index
// pool: how many, then INSTANCE_VALUE_WORDS each: its row, its target with how
// many of its four words it gives from INSTANCE_VALUE_COUNT_SHIFT, and the
// words. A target is a word of the parameters of the program of the row, or
// from INSTANCE_VALUE_STANDARD a value of the standard model.
INSTANCE_VALUES_MAX         :: 16
INSTANCE_VALUE_WORDS        :: 6
INSTANCE_VALUE_COUNT_SHIFT  :: 8
INSTANCE_VALUE_STANDARD     :: 64
// The values of the standard model an instance gives. A row holds the others
// (the index of refraction, the transmission and the alpha mode), which choose
// the passes that draw it and the media its glass leaves.
Instance_Value :: enum u32 {
	Base_Color = INSTANCE_VALUE_STANDARD, Opacity, Metallic, Roughness, Emission, Specular,
	Coat, Coat_Roughness, Coat_Color, Coat_Ior, Fuzz, Fuzz_Color, Fuzz_Roughness, Anisotropy, Anisotropy_Rotation,
	Unlit, Emission_Mode, Diffuse_Transmission, Diffuse_Transmission_Color,
}

// The limits of a program of the catalog.
PROGRAM_PARAMETER_BYTES  :: 256
PARTICLE_ATTRIBUTE_BYTES :: 1024
PROGRAM_RESOURCES        :: 16
PROGRAM_STAGES           :: 32
PROGRAM_DATA_WORDS       :: 32

// What a generation of shaders publishes in its folder (SHADER_MANIFEST): its
// stages with their bindings and the files of their code, which the renderer
// loads and the next generation reuses.
SHADER_MANIFEST :: "manifest.json"

Shader_Manifest :: struct {
    version:int,
    compiler:string,
    engine:string, // what the engine stages bind and lay out: the renderer loads only those of its own
    catalog:string,
    shaders,program_stages,extensions,tests:[]Shader_Entry,
}

Shader_Stage :: enum u8 {Vertex,Fragment,Compute}
Shader_Binding :: struct {slot:int,kind:string}

// A stage of a generation.
Shader_Entry :: struct {
    id,name:string,
    stage:Shader_Stage,
    spv,msl:string,     // file names in the folder of the generation
    entry:string,       // the entry point SPIRV-Cross gave the Metal source
    bindings:[]Shader_Binding,
    constants:[]string, // the names of its constants, by id
    group:[3]int,
    fingerprint,spv_hash,msl_hash:string,
    staged:bool `mirai:"transient"`, // of the generator: its files are in the staging folder, to be published
}
