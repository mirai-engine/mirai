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
INSTANCE_UNSHADOWED         :: u32(1) << 26
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
MESH_FLAG_CLOSED   :: 1 // asset.Mesh_Flag.Closed: it bounds a solid (glass walks inside it)
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
BATCH_WORDS             :: 6
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
// The side of a page of a map, texels, and the most pages along a side of one.
SHADOW_PAGE                :: u32(128)
SHADOW_MAP_PAGES           :: 16
// The levels of the sun, each twice as wide as the one before around the eye.
SHADOW_SUN_MAPS            :: 14
SUN_MAP_ROWS               :: SHADOW_SUN_MAPS * SHADOW_MAP_ROWS
// The maps of a view lie in slots, each a square of SHADOW_MAP_PAGES pages a
// side of which the pages points read lie in a pool, the atlas, whose side is
// SHADOW_POOL texels: the levels of the sun, then SHADOW_LIGHT_SLOTS for each
// light rasterized (the faces of its cube, then the one along a spot).
SHADOW_POOL                :: u32(4096)
SHADOW_LIGHT_SLOTS         :: 7
SHADOW_RASTER_LIGHTS       :: 32
SHADOW_SLOTS               :: SHADOW_SUN_MAPS + SHADOW_RASTER_LIGHTS * SHADOW_LIGHT_SLOTS
SHADOW_SLOT_PAGES          :: SHADOW_MAP_PAGES * SHADOW_MAP_PAGES
// The table of the pages, an entry for each page of each slot: the page of
// the pool + 1 that holds it (0: none), and SHADOW_PAGE_CACHED while what
// stays is drawn in the cache there and SHADOW_PAGE_COMPOSED while the atlas
// holds it with what moves. The atlas keeps a copy of it, an entry a texel as
// a depth of entry / SHADOW_ENTRY_SCALE, in its last SHADOW_TABLE_PAGES pages,
// SHADOW_TABLE_WIDTH texels a row from SHADOW_TABLE_X, SHADOW_TABLE_Y.
SHADOW_PAGE_CACHED         :: u32(1) << 16
SHADOW_PAGE_COMPOSED       :: u32(1) << 17
SHADOW_ENTRY_SCALE         :: f32(1 << 20)
SHADOW_TABLE_PAGES         :: 4
SHADOW_TABLE_WIDTH         :: SHADOW_TABLE_PAGES * SHADOW_PAGE
SHADOW_TABLE_X             :: SHADOW_POOL - SHADOW_TABLE_WIDTH
SHADOW_TABLE_Y             :: SHADOW_POOL - SHADOW_PAGE
SHADOW_POOL_PAGES          :: (SHADOW_POOL / SHADOW_PAGE) * (SHADOW_POOL / SHADOW_PAGE) - SHADOW_TABLE_PAGES
SHADOW_REQUESTS            :: 4096 // the most pages a frame can ask for that are not in the pool
// The words of the buffer of the pages of a view (render.Shadow_Raster.pages):
// the table, the slot of the table each page of the pool holds + 1, and the
// frame it was last read in; then what each frame writes again: a bit for
// each page of each slot that points read, that the cache draws, that the
// atlas composes and that the pool holds ready, SHADOW_MASK_WORDS a slot; a
// word for each slot of each of the last three, whether it has one; the
// counts (SHADOW_COUNT_*) and the arguments of the dispatches and draws
// (SHADOW_ARGS_*); then the slots of each of the last three, the pages the
// cache draws and the atlas composes, those asked for, and the pages of the
// pool free and those no point reads.
SHADOW_MASK_WORDS          :: SHADOW_SLOT_PAGES / 32
SHADOW_WORDS_TABLE         :: 0
SHADOW_WORDS_OWNER         :: SHADOW_WORDS_TABLE + SHADOW_SLOTS * SHADOW_SLOT_PAGES
SHADOW_WORDS_AGE           :: SHADOW_WORDS_OWNER + SHADOW_POOL_PAGES
SHADOW_WORDS_NEEDED        :: SHADOW_WORDS_AGE + SHADOW_POOL_PAGES
SHADOW_WORDS_DRAWN         :: SHADOW_WORDS_NEEDED + SHADOW_SLOTS * SHADOW_MASK_WORDS
SHADOW_WORDS_COMPOSE       :: SHADOW_WORDS_DRAWN + SHADOW_SLOTS * SHADOW_MASK_WORDS
SHADOW_WORDS_READY         :: SHADOW_WORDS_COMPOSE + SHADOW_SLOTS * SHADOW_MASK_WORDS
SHADOW_WORDS_HAS           :: SHADOW_WORDS_READY + SHADOW_SLOTS * SHADOW_MASK_WORDS
SHADOW_WORDS_COUNTS        :: SHADOW_WORDS_HAS + 3 * SHADOW_SLOTS
SHADOW_WORDS_ARGS          :: SHADOW_WORDS_COUNTS + 16
SHADOW_WORDS_SLOTS         :: SHADOW_WORDS_ARGS + 20
SHADOW_WORDS_JOBS          :: SHADOW_WORDS_SLOTS + 3 * SHADOW_SLOTS
SHADOW_WORDS_REQUESTS      :: SHADOW_WORDS_JOBS + 2 * SHADOW_POOL_PAGES
SHADOW_WORDS_FREE          :: SHADOW_WORDS_REQUESTS + SHADOW_REQUESTS
SHADOW_WORDS_SPARE         :: SHADOW_WORDS_FREE + SHADOW_POOL_PAGES
SHADOW_WORDS               :: SHADOW_WORDS_SPARE + SHADOW_POOL_PAGES
// The counts: pages the cache draws, the atlas composes, asked for, free in
// the pool, of the pool no point read, asked for and left out; slots with
// pages the cache draws, the atlas composes, the pool holds ready.
SHADOW_COUNT_DRAWN         :: 0
SHADOW_COUNT_COMPOSED      :: 1
SHADOW_COUNT_REQUESTS      :: 2
SHADOW_COUNT_FREE          :: 3
SHADOW_COUNT_SPARE         :: 4
SHADOW_COUNT_LEFT          :: 5
SHADOW_COUNT_SLOTS         :: 6 // three
// The arguments: the dispatches of the cull of the cache, of the atlas and of
// the glass, three words each, then the draws of the pages the cache clears
// and the atlas copies from it, four each.
SHADOW_ARGS_DISPATCH       :: 0
SHADOW_ARGS_DRAW           :: 9
REFLECTION_SHARED_ROUGHNESS :: f32(0.15)

// The probe volume, and the rays of its contact occlusion at each pixel.
DISTANCE_TILE :: 16
PROBE_BUCKETS :: 22
// Texels across the tile of the narrow lobes of a probe, with its border of one.
PROBE_GLOSS_TILE :: 12
CONTACT_RAYS  :: 2

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

// The raster bins of the visible clusters (render.Gpu_Cull_State.draws): a
// cluster of a two-sided material is drawn without leaving its back faces
// out, and one of a masked material or of an instance that fades is tested
// by its alpha and its fade before it writes its pixels.
RASTER_BIN_TWO_SIDED :: 1
RASTER_BIN_TESTED    :: 2
RASTER_BINS          :: 4

// The words of render.Gpu_Cull_State.
CULL_DRAWS              :: 0  // of each phase and raster bin: vertices, instances (its visible clusters), first vertex, first instance
CULL_CHUNK_DISPATCH     :: 32
CULL_CHUNK_COUNT        :: 35
CULL_CANDIDATE_DISPATCH :: 36
CULL_CANDIDATE_COUNT    :: 39
CULL_LISTED             :: 40 // of each phase, the clusters the cull listed, past the capacity too
CULL_BINS_DISPATCH      :: 42 // of each phase, three words: the groups of cull_bins.comp over its clusters
CULL_BIN_COUNTS         :: 48 // of each phase, the clusters of each raster bin
CULL_BIN_CURSORS        :: 56
CULL_DROPPED            :: 64 // of each list of the cull (render.Cull_List)

// What an instance gives over the rows of its materials, in the index pool:
// how many rows it shows otherwise than the table holds them, how much it
// fades every row out, then INSTANCE_ROW_WORDS each: the row and its words
// as the instance shows them, whole: the values shading holds
// (MATERIAL_WORDS), the blocks of its layers (MATERIAL_BLOCK_WORDS) and the
// parameters of its program. A shader reads of them what it reads of a row.
INSTANCE_VALUES_MAX    :: 16
INSTANCE_VALUES_HEADER :: 2
INSTANCE_ROW_WORDS     :: 1 + MATERIAL_WORDS + MATERIAL_BLOCK_WORDS + PROGRAM_PARAMETER_BYTES / 4
// The words of a row of the material table (render.Gpu_Material_Row): the
// values shading holds, then the blocks of its layers, and from
// MATERIAL_PARAMETERS_WORD the parameters of its program.
MATERIAL_WORDS           :: 29 + len(asset.Material_Map_Kind)
MATERIAL_BLOCK_WORDS     :: 19
MATERIAL_PARAMETERS_WORD :: MATERIAL_WORDS + MATERIAL_BLOCK_WORDS + 4 + 8 * len(asset.Material_Map_Kind)

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

// What a generation of shaders says of its material programs and of what it
// adds to the constants of every view, in SHADER_CATALOG of its folder. A
// material, a post-process effect or an emitter of particles names a program
// by its id and gives it up to PROGRAM_PARAMETER_BYTES of parameters, laid
// out as the program reflects them.
SHADER_CATALOG :: "catalog.json"
SHADER_CATALOG_VERSION :: 3

Shader_Catalog :: struct {
    version:int,
    fingerprint:string, // of the compiler, the shared includes and every program source
    compiler:string,
    programs:[]Program,
    frame:Frame_Catalog,
}

// The constants of a view: Gpu_Frame, then the nested views when the
// generation has them, then the struct each extension declared. size 0
// without nested views: Gpu_Frame alone.
Frame_Catalog :: struct {
    size:int,
    nested:bool,
    instance_ids:bool, // the G-buffer keeps the instance that drew each pixel
    extensions:[]Frame_Extension,
}
Frame_Extension :: struct {name:string,offset,size:int}

Program_Domain :: enum u8 {Surface,Postprocess,Vfx,Ui}
Program_Kind :: enum u8 {Float,Int,Uint,Bool,Texture}
// The surface of a mesh or of what an entity draws, the births a game gives,
// a grid of the world, the particles of another emitter, or a data channel.
Program_Resource_Kind :: enum u8 {Surface,Channel,Grid,Emitter,Data}
PROGRAM_STAGE_PARTICLES :: 255 // Program_Stage.over of a stage over the particles

Program :: struct {
    id:u32, // 1-based, in the order of the catalog
    name:string,
    domain:Program_Domain,
    source:string, // builtin/<file>, project/<file> or plugins/<name>/<file>, below include/programs
    size:int,
    parameters:[]Program_Parameter,
    layers:asset.Material_Layers, // of a Surface program: those of the OpenPBR model its source writes
    coverage:bool,                // of a Surface program: its alpha is not that of the default material
    standard:bool,                // of a Surface program: it builds on the standard model of its material (mirai_surface_standard), whose maps it reads
    attributes:int,               // of a Vfx program: bytes of what it keeps of each particle
    attribute_fields:[]Program_Attribute, // of a Vfx program: the fields of those bytes, in the order it declares them
    resources:[]Program_Resource, // of a Vfx program, in the order it declares them
    stages:[]Program_Stage,       // of a Vfx program, in the order they run
    moves:bool,                   // of a Vfx program: it moves and ages its particles itself
    births:bool,                  // of a Vfx program: it gives how many particles its emitter starts
    prepare:bool,                 // of a Vfx program: it prepares each frame what its emitter keeps
    vertex:Program_Vertex,        // of a Surface program: its function vertex, which moves the vertices of what shows it
}

Program_Parameter :: struct {
    name:string,
    kind:Program_Kind,
    components:u8,   // 1 to 4; a texture is one word
    offset:u16,      // bytes into the parameters of the program
    defaults:[4]f64, // a texture has none
    min,max:f64,
    srgb,normal,color:bool,
    group:string, // the section of Details that shows it; empty: the first, without a title
}

// A field of the Attributes of a Vfx program: a Float, Int, Uint or Bool
// scalar or vector, at offset bytes of what it keeps of a particle.
Program_Attribute :: struct {
    name:string,
    kind:Program_Kind,
    components:u8, // 1 to 4
    offset:u16,
}

// A resource of a Vfx program, which each emitter binds by its name: its
// index is its place among those of the program. A grid that is cleared
// starts at zero each stage that writes it.
Program_Resource :: struct {
    name:string,
    kind:Program_Resource_Kind,
    cleared:bool,
    words:u32, // of an entry of a data channel
}

// A stage of a Vfx program: a pass of its own each step before update, over
// the particles of its emitter or over the cells of one of its grids.
Program_Stage :: struct {
    name:string,
    over:u8,         // the resource of the grid; PROGRAM_STAGE_PARTICLES: the particles
    iterations:u8,   // each after the one before
    writes:u32,      // the grid resources it writes besides the one it goes over, one bit each
}

// The function vertex of a Surface program (`//! vertex`). reach: how far it
// moves a vertex from its rest, in the space of the mesh; with reach_offset,
// the float parameter at those bytes gives it instead.
Program_Vertex :: struct {
    declared,animated:bool,
    reach:f32,
    reach_offset:i32, // -1: reach
}
