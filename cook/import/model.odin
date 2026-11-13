package importer

import "core:fmt"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// What an importer reads from a source file, as plain data that depends on no
// engine component: the geometry as .mesh is built of it, the materials with
// the values of .mat, the images they refer to and the hierarchy of the
// source. import_write turns it into assets; the hierarchy is for whoever
// builds a prefab from it.

IMPORTER_NAME :: "mirai-import"
// Of the writer: raise it when import_write gives other bytes for the same model.
IMPORTER_VERSION :: 11

// What Import_Info.importer_version holds: the version of the writer in the
// low 16 bits and the one of the format the source was read with in the high
// 16. An asset whose number is another one is imported again.
import_version :: proc "contextless" (format_version:u16) -> u32 {
    return u32(IMPORTER_VERSION)|u32(format_version)<<16
}

MAX_SOURCE_BYTES :: 1<<31
MAX_DEPTH :: 512

Error_Code :: enum u8 {
    None,
    Not_Found,   // the source does not exist
    Read,        // it could not be read
    Unsupported, // not a format an importer reads, or a feature it rejects
    Malformed,   // truncated or contradicting itself
    Limit,       // more than an asset can hold
    Tool,        // an external tool failed or is missing
    Write,       // an asset could not be written
}

// message lives in context.temp_allocator of the caller.
Error :: struct {
    code:Error_Code,
    message:string,
}

Import_Options :: struct {
    // Replaced by the settings the sidecar of the source keeps when it has
    // one, unless ignore_stored.
    using settings:Import_Settings,
    ignore_stored:bool,
    // The project or the plugin whose assets folder the source is in: sources
    // are named relative to it in Import_Info, its documents are found among
    // its assets, and what it builds of the cache kinds goes to its imported
    // folder (sidecar.odin).
    root:string,
    registry:^asset.Registry, // the scanned assets of root, which the import does not change; nil: it scans them
    world:^core.World_Info,   // the types of the game of root, which the prefab of a model is written in
    rebuild:bool,        // writes every asset, also one whose file already is the one the import would write
    texture_cache:string, // folder of textures built before, kept by image and settings (textures.cache_read); "": none
    // A texture is built Fast unless the texture cache keeps it as Final
    // (textures.Encode_Speed): the imports of the editor, which a cook
    // encodes again as Final. False: Final, what tools and the CLI build.
    fast_textures:bool,
    mesh_cache:string,    // folder of meshes built before, kept by geometry and settings (mesh_cook); "": none
    // The identity of the code of the plugin that imports the source whole
    // (sources.code_identity), 0 for the engine's: part of what its outputs
    // are built from (import_key).
    importer_code:u64,
    material_index:int,   // the index of the first material among those of the source: imports that write its materials apart give each its own
    // Where the import cooks: the worker that calls it (the owner of its
    // job system, or the job that imports), which runs its builds in
    // parallel on that system, and records zones in its profile.
    worker:jobs.Worker_Ref,
    progress:^Progress, // where it says how far it is as it writes; nil: nowhere
}

// A zone of the import that base.profile_end ends.
zone_begin :: #force_inline proc "contextless" (options:Import_Options,name:string) -> base.Profile_Scope {
    return jobs.worker_zone_begin(options.worker,name)
}

// A zone of the import until the end of the enclosing block.
@(deferred_out=base.profile_end)
zone :: #force_inline proc "contextless" (options:Import_Options,name:string) -> base.Profile_Scope {
    return jobs.worker_zone_begin(options.worker,name)
}

material_map :: #force_inline proc(info:^asset.Material_Info,slot:asset.Material_Map_Kind) -> ^asset.Material_Map {
    return &asset.material_maps(&info.maps)[slot]
}

Imported_Image :: struct {
    name:string,         // file name without extension; for an embedded image, its name in the model
    path:string,         // absolute path of the file; "" when the image is inside the model
    data:[]u8,           // the encoded image, when it is inside the model; with make, what its format makes the texels from
    // Makes the texels of data, for an image only its format decodes: the
    // texture cache keeps its texture by data, so a texture built before is
    // taken without making them. nil for an encoded image or file.
    make:Image_Make,
    made:textures.Source, // the texels, when the format made the image itself (a conversion, a texture of an engine); width 0 when not
    srgb:bool,
    normal_map:bool,
    green_down:bool,     // a normal map whose green points down the image: it is turned to +Y up
    alpha_cutoff:f32,    // above 0: the base color of a masked material
    keep_precision:bool, // its source asks for the precision of its 16 bits or floats (textures.Build_Options)
    channels:textures.Channels, // what each channel of its texture is made of (a gloss map turned into roughness); the zero value keeps them
    cooked:^Cooked_Texture, // built ahead by model_cook; nil when not
}

// The texels a format makes of the data of one of its images, in allocator;
// false when it cannot. Called from any thread, and more than once.
Image_Make :: #type proc(data:[]u8,allocator:mem.Allocator) -> (made:textures.Source,ok:bool)

Imported_Material :: struct {
    name:string,
    info:asset.Material_Info,       // the textures of its maps are named by images
    images:[asset.Material_Map_Kind]int,           // row of the model's images, -1 for none
    // The values of the parameters of info.program, as the source gives them;
    // the texture of one of kind Texture is the image parameter_images names.
    parameters:[]asset.Material_Parameter,
    parameter_images:[]int,         // by parameter: row of the model's images, -1 for none
}

Imported_Slot :: struct {
    id:u32,
    label:string,
    material:int, // row of the model's materials, -1 for none
}

// Geometry as asset.mesh_build takes it; skinned vertices stay in bind space.
Imported_Mesh :: struct {
    name:string,
    vertices:[]asset.Vertex,
    indices:[]u32,
    skin:[]asset.Skin_Vertex,
    morphs:[]asset.Morph_Target,
    morph_deltas:[]asset.Morph_Delta, // in the engine's space
    submeshes:[]Submesh,
    slots:[]Imported_Slot,
    joints:[]asset.Rig_Joint,
    skeleton:int,
    flags:asset.Mesh_Flags,
    bounds_min,bounds_max:[3]f32,
    // The colliders the source gives, in the space of the mesh: its collision.
    collision:Mesh_Collision,
    cooked:^Cooked_Mesh, // built ahead by model_cook; nil when not
}

Light_Kind :: enum u8 {Directional,Point,Spot,Rect}

// It shines toward -Z of its node. A rectangle is sized by the scale of its
// entity, so its node has no children and no mesh.
Imported_Light :: struct {
    kind:Light_Kind,
    color:[3]f32,
    intensity:f32,      // lux for directional lights, nits for rectangles, candela for the others
    range:f32,          // 0: unlimited
    inner_cone,outer_cone:f32, // radians
    radius:Maybe(f32),  // of the sphere a point or spot glows from; nil: the engine's default
    size:[2]f32,        // of a rectangle, along x and y of its node
}

Imported_Node :: struct {
    name:string,
    path:string,
    target:u64,
    parent:int,                // row of nodes, -1 for a root; a parent comes before its children
    transform:mm.Transform,    // relative to the parent, in the engine's space once the import is done
    mesh:int,                  // row of the model's meshes, -1 for none
    morph_weights:[]f32,       // of each morph target of its mesh at rest, or none: those of the mesh
    light:Maybe(Imported_Light),
    visible:bool,
}

Imported_Skeleton :: struct {
    name:string,
    bones:[]asset.Skeleton_Bone,
    sockets:[]asset.Skeleton_Socket, // named places on its bones that the source gives, their offsets in the space of their bone
}

Imported_Model :: struct {
    source:string,      // absolute path with forward slashes
    source_size:u64,
    source_hash:u64,
    format:string,      // the name of the Format it was read with
    name:string,        // of its prefab and its animations (Reader.stem)
    folder:string,      // beside the source, where a first import puts its assets (Format.folder, else its stem)
    version:u32,        // import_version of that format: what its assets record
    meshes:[]Imported_Mesh,
    materials:[]Imported_Material,
    images:[]Imported_Image,
    nodes:[]Imported_Node,
    skeletons:[]Imported_Skeleton,
    animations:[]asset.Animation_Clip_Desc,
    warnings:[]string,  // what the importer left out or could not honor
    programs:[]string,  // the Surface programs reading it wrote to the shaders of the project, their files
    files:[]string,     // the files reading it read besides the source and its images (buffers, material libraries)
    settings:Import_Settings, // those of the sidecar of the source when stored is set, else those of the options it was read with
    stored:bool,
    arena:^mem.Dynamic_Arena,
    allocator:mem.Allocator,
}

model_destroy :: proc(model:^Imported_Model) {
    model_cooked_destroy(model)
    if model.arena!=nil {
        mem.dynamic_arena_destroy(model.arena)
        free(model.arena,model.allocator)
    }
    model^={}
}

error_make :: proc(code:Error_Code,format:string,args:..any,allocator:=context.temp_allocator) -> Error {
    return {code,fmt.aprintf(format,..args,allocator=allocator)}
}

// The slice of a mesh triangle: the three vertices of triangle i of level 0.
mesh_triangle :: proc(mesh:^Imported_Mesh,i:int) -> (corners:[3]asset.Vertex) {
    for k in 0..<3 {corners[k]=mesh.vertices[mesh.indices[i*3+k]]}
    return
}
