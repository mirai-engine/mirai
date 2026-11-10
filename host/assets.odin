package host

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import render "mirai:render"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// The assets the worlds use, by id. An asset is loaded the first time
// something asks for it, as a transaction between frames, or read by a job
// ahead (assets_prepare) and given to the renderer between frames
// (assets_take), and stays loaded until assets_collect finds that no scope
// uses it (see the scopes below).
// With a renderer, meshes and textures are uploaded to it and materials are
// rows of its material table; without one only the records are read. An
// asset that cannot be loaded leaves an error in the list and a stand-in:
// the cube for a mesh, a magenta material, a checker as base color texture.
//
// The material table holds a row per material asset and, after them, derived
// rows: the values of a material as one entity or one overlay shows them.
// Equal values share a row, and a row nobody asked for in the last round of
// whoever extracts the scene is given to the next values that need one.

// Assets of each kind loaded at once: address space is reserved for them, and
// a table takes memory as loads grow it, so the count a world asks for is not
// a fixed share of memory.
ASSETS_DEFAULT_CAPACITY :: 1<<20
// What the lists beside the tables have room for before they grow, in loads.
ASSETS_START :: 4096
ASSETS_DEFAULT_ERRORS :: 256
ASSETS_ROWS_DIRTY :: 256 // material rows that go to the renderer one by one between two assets_commit
ASSETS_MESH_NONE :: render.Mesh_Handle(max(u32))

Assets_Desc :: struct {
    root:string,               // folder of the asset registry
    cache:string,              // file where the registry keeps what it scanned; "" for none
    renderer:^render.Renderer, // nil: nothing is uploaded
    allocator:mem.Allocator,   // context.allocator when unset
    capacity:int,              // the most assets of each kind loaded at once, and derived material rows: the tables grow to it as they load. 0: ASSETS_DEFAULT_CAPACITY
    error_capacity:int,        // 0: ASSETS_DEFAULT_ERRORS
    mounts:[]asset.Registry_Mount, // folders seen beside root under a prefix: the assets of active plugins
}

Assets_Kind :: enum u8 {Mesh,Texture,Material,Scene,Shape,Document}

Assets_Problem :: enum u8 {
    Missing,     // no file of the registry is that asset
    Unreadable,  // the file could not be read
    Corrupt,     // the file contradicts itself, its hash or its id
    Wrong_Kind,  // the id is an asset of another kind
    Unsupported, // a texture larger than the device takes even at its smallest level, an array or a cube where a 2D image is sampled, a program the shaders do not have
    Rejected,    // the renderer did not take it: Renderer.error says why
    Capacity,    // no room for another asset of its kind
}

Assets_Error :: struct {
    id:base.Asset_Id, // zero for a shape
    kind:Assets_Kind,
    problem:Assets_Problem,
    detail:asset.Error,
}

Assets_Mesh :: struct {
    handle:render.Mesh_Handle, // ASSETS_MESH_NONE without a renderer
    bounds_min,bounds_max:[3]f32,
    vertex_count,index_count:u32, // of level 0
    slot_count:u32,
    slot_materials:[asset.MESH_MAX_SLOTS]base.Asset_Id, // the material each slot came with
    levels:u32,     // simplified levels its file stores: the renderer draws them instead of deriving its own
    skeleton:base.Asset_Id, // the one its skin is bound to; zero for a rigid mesh
    morphs:u32,     // morph targets its file holds
    failed:bool,    // the stand-in of an asset that did not load
    generated:bool, // made by assets_mesh_generate: it has no file
    collision:geom.Mesh,
    disabled_edges:[]u8,
    hull_points:[]geom.Vec3, // the convex pieces of a generated mesh, as Mesh_Generate_Options gives them
    hull_sizes:[]u32,
    heightfield:Assets_Heightfield,
}

Assets_Heightfield :: struct {
    heights:[]f32,
    columns,rows:int,
    cell,origin:[3]f32,
    disabled_borders:[]u8,
    holes:[]u8, // one per cell, row after row, or none: 1 where the cell has no surface
}

Mesh_Generate_Options :: struct {
    no_lods:bool, // level 0 alone, without the DAG of its clusters
    collision:bool,
    heightfield:^Assets_Heightfield,
    disabled_edges:[]u8, // per triangle of what collides
    collision_mesh:geom.Mesh, // what colliders and picking take instead of the mesh drawn; empty: the mesh
    // The convex pieces a Hull collider of the mesh is made of, each a body shape of its own: the points of
    // every piece one after another, in mesh space, and how many each has (at least 4). Empty: one hull.
    hull_points:[]geom.Vec3,
    hull_sizes:[]u32,
    tangents:[][4]f32, // one per vertex, with the sign of the bitangent in w, as MikkTSpace gives them; empty: MikkTSpace's over the uvs
    render_geometry:^Mesh_Render_Geometry, // what assets_render_geometry_make made of the mesh ahead; nil: made here
}

// What the renderer takes of a mesh made at run time: its clusters, as
// asset.mesh_build encodes them, each of the slot of the mesh it names (0
// without slots), and the cuts its rays trace. assets_mesh_generate makes it
// before it registers the mesh and gives its slots the rows of their
// materials; a job can make it ahead (assets_render_geometry_make).
Mesh_Render_Geometry :: struct {
    geometry:asset.Mesh_Geometry,
    ahead:render.Mesh_Ahead, // its cuts and what the renderer derives of it; none without a renderer
    slots:int,
    arena:mem.Dynamic_Arena, // what both are made in, again at each make
}

assets_render_geometry_init :: proc(out:^Mesh_Render_Geometry,allocator:=context.allocator) {
    out^={}
    mem.dynamic_arena_init(&out.arena,allocator,allocator)
}

assets_render_geometry_destroy :: proc(out:^Mesh_Render_Geometry) {
    render.mesh_ahead_destroy(&out.ahead)
    mem.dynamic_arena_destroy(&out.arena)
    out^={}
}

// Makes into out, initialized, the render geometry of a mesh with slots
// slots, as assets_mesh_generate would (levels: in a DAG of clusters, else
// level 0 alone), with the cuts of its rays as the
// renderer of limits traces them. Scratch from the temporary allocator of
// the thread. Any thread. False when the streams do not match or without memory.
assets_render_geometry_make :: proc(mesh:geom.Mesh,uv1s:[]geom.Vec2,slots:int,out:^Mesh_Render_Geometry,limits:Assets_Limits,tangents:[][4]f32=nil,levels:=false) -> bool {
    count:=len(mesh.positions)
    if count==0 || len(mesh.normals)!=count || len(mesh.uvs)!=0 && len(mesh.uvs)!=count || len(uv1s)!=0 && len(uv1s)!=count || slots>asset.MESH_MAX_SLOTS {return false}
    for index in mesh.indices {if int(index)>=count {return false}}
    for slot in mesh.materials[:slots>0?len(mesh.materials):0] {if int(slot)>=slots {return false}}
    return assets_render_geometry(mesh,mesh.normals,uv1s,slots,out,limits,tangents,levels)
}

Assets_Texture :: struct {
    handle:render.Texture_Handle, // 0 without a renderer
    width,height:u32,
    layers:u32, // of an array, or six per cube; 1 for a 2D texture
    format:asset.Texture_Format,
    flags:asset.Texture_Flags,
    failed:bool,
    generated:bool, // made by assets_texture_generate: it has no file
}

Assets_Material :: struct {
    id:base.Asset_Id,
    row:u32, // of the material table of the renderer
    info:asset.Material_Info,
    first_parameter,parameter_count,parameter_room:u32, // its rows of Assets.parameters
    overlay_count:u32,
    overlays:[asset.MATERIAL_MAX_OVERLAYS]asset.Material_Overlay,
    failed:bool,
}

Assets_Stats :: struct {
    meshes,textures,materials,scenes:int,
    generated:int,         // meshes and textures made at run time that are alive
    derived:int,           // derived material rows in use
    loads:int,             // assets read from their file
    reloads:int,
    unloads:int,           // assets that assets_collect unloaded
    streamed:int,          // ranges of levels given to textures that follow their distance
    errors_dropped:int,    // errors that did not fit in the list
}

@(private="file")
Assets_Ref :: struct {kind:Assets_Kind,index:u32}

@(private="file")
Assets_Scene :: struct {file:asset.Asset,kind:asset.Fourcc,failed:bool}

@(private="file") ASSETS_ROW_ASSET :: max(u64)  // marks the row of a material asset
@(private="file") ASSETS_ROW_FREE :: max(u64)-1 // marks a derived row nobody uses

Assets :: struct {
    allocator:mem.Allocator,
    renderer:^render.Renderer,
    registry:asset.Registry,
    indexed:bool, // the registry is the packed index of the folder: its files are not looked at
    types:asset.Types,
    index:map[base.Asset_Id]Assets_Ref,
    regions:[7]base.Region, // of meshes, textures, materials, scenes, material_descs, row_marks and row_hashes
    meshes:[dynamic]Assets_Mesh,
    free_meshes:[dynamic]u32, // entries of meshes that released or unloaded meshes left
    free_textures,free_materials,free_scenes:[dynamic]u32,
    scopes:[ASSETS_SCOPES]Assets_Scope_State,
    generated_next:u64,       // id of the next generated mesh or texture
    textures:[dynamic]Assets_Texture,
    materials:[dynamic]Assets_Material,
    scenes:[dynamic]Assets_Scene,
    parameters:[dynamic]asset.Material_Parameter, // of every material, a run each
    material_descs:[dynamic]render.Material_Desc, // rows 1.. of the renderer
    row_marks:[dynamic]u64,                       // per row: the round that last used a derived row
    row_hashes:[dynamic]u64,
    derived:map[u64]u32,                          // hash of the values -> derived row
    free_rows:[dynamic]u32,
    materials_dirty:bool,    // every row goes to the renderer with the next assets_commit
    rows_dirty:[dynamic]u32, // else the rows that changed since the last one
    shapes:[Shape]Assets_Mesh,
    shapes_ready:[Shape]bool,
    missing_mesh:Assets_Mesh,
    missing_texture:Assets_Texture,
    missing_texture_ready:bool,
    errors:[dynamic]Assets_Error,
    revision:u64,   // advances when something that was given out changes: who holds handles or rows asks again
    structure:u64,  // advances when the instances of a scene are no longer what they need: who extracted it does it again
    structure_changes:[ASSETS_STRUCTURE_LOG]Assets_Structure_Change,
    structure_change_count:int,
    appearance:u64, // the round of derived rows: assets_appearance_begin opens one
    loads:Load_Budget,
    texture_assets:[dynamic]base.Asset_Id, // by handle - 1 of a texture of the renderer: the asset given it, as last given
    stats:Assets_Stats,
    load_profile:^Load_Profile, // of the application, which counts the assets that load; nil: nobody counts
}

Assets_Structure_Change :: struct {version:u64,id:base.Asset_Id}
// Changes of structure kept for whoever looks at them by id: past them a reader rebuilds
// everything. Generated meshes that come and go (terrain pieces, far forms, crowns) fill it.
ASSETS_STRUCTURE_LOG :: 1024

@(private)
assets_structure_changed :: proc(a:^Assets,id:base.Asset_Id={}) {
    a.structure+=1
    if a.structure_change_count==len(a.structure_changes) {
        copy(a.structure_changes[:],a.structure_changes[1:])
        a.structure_change_count-=1
    }
    a.structure_changes[a.structure_change_count]={a.structure,id}
    a.structure_change_count+=1
}

// A zero id requires a full refresh. A consumer older than the retained log does too.
assets_structure_changes :: proc(a:^Assets,seen:u64) -> (changes:[]Assets_Structure_Change,ok:bool) {
    if seen==a.structure {return nil,true}
    for change,i in a.structure_changes[:a.structure_change_count] {
        if change.version<=seen {continue}
        return a.structure_changes[i:a.structure_change_count],change.version==seen+1
    }
    return nil,false
}

// Reads the packed index of the folder (asset.REGISTRY_INDEX, which a cook
// leaves in the assets of a shipped game) or, without one, scans its files.
// False when the folder cannot be scanned or memory ran out.
assets_init :: proc(a:^Assets,desc:Assets_Desc) -> bool {
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    capacity:=desc.capacity>0?desc.capacity:ASSETS_DEFAULT_CAPACITY
    a^={allocator=allocator,renderer=desc.renderer}
    listed:=asset.registry_init(&a.registry,desc.root,desc.cache,allocator)
    // A copy of an asset made outside the editor gets an id of its own.
    a.registry.resolve_duplicates=true
    for mount in desc.mounts {listed&&=asset.registry_mount(&a.registry,mount.folder,mount.prefix)}
    asset.types_init(&a.types,allocator)
    a.index=make(map[base.Asset_Id]Assets_Ref,allocator)
    a.derived=make(map[u64]u32,allocator)
    start:=min(capacity,ASSETS_START)
    ok:=listed && reserve(&a.index,start*4)==nil && reserve(&a.derived,start)==nil
    made:[7]bool
    a.meshes,made[0]=base.region_dynamic(&a.regions[0],Assets_Mesh,capacity)
    a.textures,made[1]=base.region_dynamic(&a.regions[1],Assets_Texture,capacity)
    a.materials,made[2]=base.region_dynamic(&a.regions[2],Assets_Material,capacity)
    a.scenes,made[3]=base.region_dynamic(&a.regions[3],Assets_Scene,capacity)
    a.parameters=make([dynamic]asset.Material_Parameter,allocator)
    a.material_descs,made[4]=base.region_dynamic(&a.regions[4],render.Material_Desc,capacity*2)
    a.row_marks,made[5]=base.region_dynamic(&a.regions[5],u64,capacity*2)
    a.row_hashes,made[6]=base.region_dynamic(&a.regions[6],u64,capacity*2)
    for listed in made {ok&&=listed}
    errors:[7]runtime.Allocator_Error
    a.free_rows,errors[0]=make([dynamic]u32,0,start,allocator)
    a.rows_dirty,errors[1]=make([dynamic]u32,0,ASSETS_ROWS_DIRTY,allocator)
    a.free_meshes,errors[2]=make([dynamic]u32,0,start,allocator)
    a.free_textures,errors[3]=make([dynamic]u32,0,start,allocator)
    a.free_materials,errors[4]=make([dynamic]u32,0,start,allocator)
    a.free_scenes,errors[5]=make([dynamic]u32,0,start,allocator)
    a.errors,errors[6]=make([dynamic]Assets_Error,0,desc.error_capacity>0?desc.error_capacity:ASSETS_DEFAULT_ERRORS,allocator)
    for error in errors {ok&&=error==nil}
    if desc.renderer!=nil {a.texture_assets=make([dynamic]base.Asset_Id,allocator)}
    ok=ok && cap(a.meshes)==capacity && cap(a.textures)==capacity && cap(a.materials)==capacity && cap(a.scenes)==capacity
    ok=ok && cap(a.material_descs)==capacity*2 && cap(a.row_marks)==capacity*2 && cap(a.row_hashes)==capacity*2 && cap(a.free_rows)==start && cap(a.free_meshes)==start && cap(a.rows_dirty)==ASSETS_ROWS_DIRTY
    ok=ok && cap(a.free_textures)==start && cap(a.free_materials)==start && cap(a.free_scenes)==start
    if ok {
        index,no_index:=strings.concatenate({desc.root,"/",asset.REGISTRY_INDEX},allocator)
        ok=no_index==nil
        a.indexed=ok && asset.registry_load(&a.registry,index)==.None
        delete(index,allocator)
    }
    if !ok || (!a.indexed && asset.registry_scan(&a.registry)!=.None) {
        assets_destroy(a)
        return false
    }
    return true
}

assets_destroy :: proc(a:^Assets) {
    if a.allocator.procedure==nil {return}
    for &scene in a.scenes {asset.asset_close(&scene.file)}
    for &mesh in a.meshes {assets_generated_free(&mesh,a.allocator)}
    delete(a.index);delete(a.derived);delete(a.parameters)
    delete(a.free_rows);delete(a.errors);delete(a.free_meshes);delete(a.rows_dirty)
    for &region in a.regions {base.region_release(&region)}
    delete(a.free_textures);delete(a.free_materials);delete(a.free_scenes)
    delete(a.texture_assets)
    for &scope in a.scopes {delete(scope.ids)}
    asset.types_destroy(&a.types)
    asset.registry_destroy(&a.registry)
    a^={}
}

// Looks at the folder again: for files that appeared or went away. A folder
// with a packed index is what its index says, and is not looked at.
assets_scan :: proc(a:^Assets) -> bool {return a.indexed || asset.registry_scan(&a.registry)==.None}

// Looks again at some files of the folder, by their paths in the registry:
// the ones that were written or that a watch saw change. With a packed index,
// only those of folders assets_mount mounted.
assets_refresh :: proc(a:^Assets,paths:[]string) -> bool {
    if !a.indexed {return asset.registry_refresh(&a.registry,paths)==.None}
    guests:=make([dynamic]string,0,len(paths),context.temp_allocator)
    for path in paths {
        if asset.registry_guest(&a.registry,path) {append(&guests,path)}
    }
    return len(guests)==0 || asset.registry_refresh(&a.registry,guests[:])==.None
}

// Mounts under prefix a folder of assets the game did not ship: levels a
// player saved or downloaded, mods. Its files are found by id and by path at
// once, also in a shipped game; one whose id the game or an earlier mount
// already has is left out (refused counts those of this folder, and
// registry.refused lists them all). It is not watched: whoever writes in it
// calls assets_refresh with those paths. Not_Found without the folder; Invalid
// for a prefix that is not a plain relative path, or that the assets or another
// mount already take.
assets_mount :: proc(a:^Assets,folder,prefix:string) -> (refused:int,error:asset.Error) {
    if a==nil || a.allocator.procedure==nil {return 0,.Invalid}
    return asset.registry_mount_guest(&a.registry,folder,prefix)
}

// Takes out of the registry a folder assets_mount mounted. What was loaded from
// it stays until no world names it and assets_collect unloads it; loading it
// again does not find it. Not_Found for a prefix no assets_mount gave.
assets_unmount :: proc(a:^Assets,prefix:string) -> asset.Error {
    if a==nil || a.allocator.procedure==nil {return .Invalid}
    return asset.registry_unmount(&a.registry,prefix)
}

// The files of the folder changed in memory and not written: what an editor
// has unsaved (asset.Registry_Memory). Assets read them instead of the disk.
assets_unsaved :: proc(a:^Assets) -> []asset.Registry_Memory {return a.registry.memory[:]}

assets_errors :: proc(a:^Assets) -> []Assets_Error {return a.errors[:]}
assets_errors_clear :: proc(a:^Assets) {clear(&a.errors)}

// The id of the asset at a path of the folder, as its file is spelled
// ("arena/Chrome.mat"): what code that names an asset by path resolves.
assets_id :: proc(a:^Assets,path:string) -> (id:base.Asset_Id,found:bool) {
    if a==nil {return}
    file:=asset.registry_find_path(&a.registry,path) or_return
    return file.id,file.id!={}
}

// How a message names an asset: its path in the folder, or its id, written in
// buffer, when the folder has no file with it. Without allocating.
assets_name :: proc(a:^Assets,id:base.Asset_Id,buffer:^[base.ASSET_ID_TEXT]u8) -> string {
    if a!=nil {
        if file,found:=asset.registry_find(&a.registry,id);found {return file.path}
    }
    return base.asset_id_format(id,buffer[:])
}

// Gives the renderer the material rows that changed. Whoever asks for assets
// calls it before the next frame; a call with nothing new does nothing.
assets_commit :: proc(a:^Assets) {
    // Rows the renderer had no memory for stay dirty: the next commit gives them again.
    if a.materials_dirty {
        if a.renderer!=nil && !render.materials_set(a.renderer,a.material_descs[:]) {return}
        a.materials_dirty=false
        clear(&a.rows_dirty)
    } else if len(a.rows_dirty)>0 {
        if a.renderer!=nil && !render.materials_update(a.renderer,a.material_descs[:],a.rows_dirty[:]) {return}
        clear(&a.rows_dirty)
    }
}

// A row of the table got other values. Past ASSETS_ROWS_DIRTY every row goes.
@(private="file")
assets_row_changed :: proc(a:^Assets,row:u32) {
    if a.materials_dirty || slice.contains(a.rows_dirty[:],row) {return}
    if len(a.rows_dirty)==cap(a.rows_dirty) {
        a.materials_dirty=true
        return
    }
    append(&a.rows_dirty,row)
}

@(private="file")
assets_fail :: proc(a:^Assets,id:base.Asset_Id,kind:Assets_Kind,problem:Assets_Problem,detail:=asset.Error.None) {
    for known in a.errors {
        if known.id==id && known.kind==kind && known.problem==problem {return}
    }
    if len(a.errors)>=cap(a.errors) {a.stats.errors_dropped+=1;return}
    append(&a.errors,Assets_Error{id,kind,problem,detail})
}

@(private="file")
assets_errors_forget :: proc(a:^Assets,id:base.Asset_Id) {
    #reverse for known,at in a.errors {
        if known.id==id {ordered_remove(&a.errors,at)}
    }
}

// Opens the file of an asset of one kind, whole and matching its hash.
@(private)
assets_open :: proc(a:^Assets,id:base.Asset_Id,kind:Assets_Kind,file:^asset.Asset,document:=asset.Fourcc(0)) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return .Missing,.Not_Found,false}
    expected:bool
    #partial switch kind {
    case .Mesh:     expected=record.kind==asset.KIND_MESH
    case .Texture:  expected=record.kind==asset.KIND_TEXTURE
    case .Material: expected=record.kind==asset.KIND_MATERIAL
    case .Scene:    expected=record.kind==asset.KIND_SCENE
    case .Document: expected=record.kind==document
    }
    if !expected {return .Wrong_Kind,.Invalid,false}
    detail=assets_file(a,id,record.kind,file)
    problem,ok=assets_problem_of(detail)
    return
}

// What loading an asset meets when its file does not open.
@(private="file")
assets_problem_of :: proc "contextless" (detail:asset.Error) -> (problem:Assets_Problem,ok:bool) {
    #partial switch detail {
    case .None:      return {},true
    case .Not_Found: return .Missing,false
    case .IO:        return .Unreadable,false
    }
    return .Corrupt,false
}

// A transaction owned by the caller, which closes file with asset_close.
assets_file :: proc(a:^Assets,id:base.Asset_Id,kind:asset.Fourcc,file:^asset.Asset) -> asset.Error {
    if a==nil || file==nil {return .Invalid}
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return .Not_Found}
    if record.kind!=kind {return .Invalid}
    limit:=assets_byte_limit(a,record.path)
    data:=asset.registry_read(&a.registry,record.path,a.allocator,limit) or_return
    assets_file_take(file,data,id,kind,a.allocator,limit) or_return
    a.stats.loads+=1
    return .None
}

// What a file of a guest mount (assets_mount) may take, read or decompressed:
// what a player downloaded is refused before it takes the memory of the game.
ASSETS_GUEST_LIMIT :: 64<<20

// The most the file of an asset may take: less under a guest mount.
@(private="file")
assets_byte_limit :: proc(a:^Assets,path:string) -> u64 {
    return asset.registry_guest(&a.registry,path)?ASSETS_GUEST_LIMIT:asset.DEFAULT_MEMORY_LIMIT
}

// Opens the bytes of the file of an asset, which it takes: whole, matching its
// hash, its id and its kind. Any thread.
@(private="file")
assets_file_take :: proc(file:^asset.Asset,data:[]u8,id:base.Asset_Id,kind:asset.Fourcc,allocator:mem.Allocator,limit:u64,decoder:^asset.Decoder=nil) -> asset.Error {
    asset.asset_take(file,data,allocator,limit,decoder) or_return
    if !asset.blob_verify_hash(&file.blob) || file.blob.header.id!=id || file.blob.header.kind!=kind {
        asset.asset_close(file)
        return .Hash
    }
    return .None
}

// Where a job reads the file of an asset: a copy of what the registry holds
// in memory, or its path on disk. Its kind and content hash are those of the
// record when it was found.
Assets_Source :: struct {
    id:base.Asset_Id,
    kind:asset.Fourcc,
    hash:u64,
    path:string,
    data:[]u8,
    allocator:mem.Allocator, // of path and data: one any thread can use
    limit:u64,               // the most its file may take; 0: asset.DEFAULT_MEMORY_LIMIT
}

// The source of an asset of the registry; false when the registry has none.
// On the thread of the assets.
assets_source :: proc(a:^Assets,id:base.Asset_Id,allocator:mem.Allocator) -> (source:Assets_Source,found:bool) {
    record:=asset.registry_find(&a.registry,id) or_return
    if record.state!=.Asset {return}
    source={id=id,kind=record.kind,hash=record.content_hash,allocator=allocator,limit=assets_byte_limit(a,record.path)}
    if held,in_memory:=asset.registry_memory_find(&a.registry,record.path);in_memory {
        if held.removed {return {},false}
        data,error:=asset.asset_bytes_clone(held.data,allocator)
        if error!=.None {return {},false}
        source.data=data
    } else {
        source.path=asset.registry_file_path(&a.registry,record.path,allocator)
        if source.path=="" {return {},false}
    }
    return source,true
}

// Opens the file of a source as assets_file does, taking its bytes. Any thread.
assets_source_open :: proc(source:^Assets_Source,file:^asset.Asset,decoder:^asset.Decoder=nil) -> asset.Error {
    data:=source.data
    source.data=nil
    limit:=source.limit!=0?source.limit:asset.DEFAULT_MEMORY_LIMIT
    if data==nil {data=asset.asset_file_read(source.path,source.allocator,limit) or_return}
    return assets_file_take(file,data,source.id,source.kind,source.allocator,limit,decoder)
}

assets_source_free :: proc(source:^Assets_Source) {
    if source.allocator.procedure==nil {return}
    delete(source.path,source.allocator)
    delete(source.data,source.allocator)
    source^={}
}

// An entry for another asset of a kind: one an unloaded asset left, or a new one while there is room.
@(private="file")
assets_slot :: proc(list:^[dynamic]$T,free:^[dynamic]u32,region:^base.Region) -> (at:u32,ok:bool) {
    if len(free^)>0 {
        at=pop(free)
        list^[at]={}
        return at,true
    }
    if !base.region_grow(region,list) {return 0,false}
    append(list,T{})
    return u32(len(list^)-1),true
}

// --------------------------------------------------------------------- shapes

// One of the built-in shapes, generated the first time. nil for None.
assets_shape :: proc(a:^Assets,shape:Shape) -> ^Assets_Mesh {
    if shape==.None || shape>max(Shape) {return nil}
    entry:=&a.shapes[shape]
    if a.shapes_ready[shape] {return entry}
    a.shapes_ready[shape]=true
    buffer:geom.Mesh_Buffer
    geom.mesh_buffer_init(&buffer,a.allocator)
    defer geom.mesh_buffer_destroy(&buffer)
    switch shape {
    case .None:
    case .Cube:     geom.cube_build(&buffer)
    case .Sphere:   geom.sphere_build(&buffer)
    case .Cylinder: geom.cylinder_build(&buffer)
    case .Cone:     geom.cone_build(&buffer)
    case .Capsule:  geom.capsule_build(&buffer)
    case .Plane:    geom.plane_build(&buffer)
    case .Prism:    geom.prism_build(&buffer)
    case .Pyramid:  geom.pyramid_build(&buffer)
    }
    entry^={handle=ASSETS_MESH_NONE,vertex_count=u32(len(buffer.positions)),index_count=u32(len(buffer.indices))}
    entry.bounds_min,entry.bounds_max=geom.mesh_bounds(buffer.positions[:])
    if a.renderer==nil {return entry}
    made:Mesh_Render_Geometry
    assets_render_geometry_init(&made,a.allocator)
    defer assets_render_geometry_destroy(&made)
    added:=false
    if mesh:=geom.mesh_buffer_view(&buffer);assets_render_geometry(mesh,mesh.normals,nil,0,&made,assets_limits(a)) {
        entry.handle,added=assets_render_geometry_add(a,&made,nil)
    }
    if !added {
        entry.handle,entry.failed=ASSETS_MESH_NONE,true
        assets_fail(a,{},.Shape,.Rejected)
    }
    return entry
}

// --------------------------------------------------------------------- meshes

@(private="file")
assets_missing_mesh :: proc(a:^Assets) -> ^Assets_Mesh {
    a.missing_mesh=assets_shape(a,.Cube)^
    a.missing_mesh.failed=true
    return &a.missing_mesh
}

// replace: the mesh of the renderer the new one takes the place of, removed
// once the file proved good; removed says whether it is gone.
@(private="file")
assets_mesh_load :: proc(a:^Assets,id:base.Asset_Id,entry:^Assets_Mesh,replace:=ASSETS_MESH_NONE,removed:^bool=nil) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    file:asset.Asset
    if problem,detail,ok=assets_open(a,id,.Mesh,&file);!ok {return}
    defer asset.asset_close(&file)
    view:asset.Mesh_View
    if view,problem,detail,ok=assets_mesh_view(&file,&a.types);!ok {return}
    return assets_mesh_install(a,view,entry,replace,removed)
}

// The tables of an open mesh, checked. Any thread.
@(private="file")
assets_mesh_view :: proc(file:^asset.Asset,types:^asset.Types) -> (view:asset.Mesh_View,problem:Assets_Problem,detail:asset.Error,ok:bool) {
    view_error:asset.Error
    if view,view_error=asset.mesh_view(file,types);view_error!=.None {return {},.Corrupt,view_error,false}
    if !asset.mesh_check_indices(view) {return {},.Corrupt,.Corrupt,false}
    return view,{},.None,true
}

// The entry of a mesh of view, given to the renderer with the cuts of its
// rays and the rest a job made ahead (render.mesh_ahead_make; nil: made
// here). over_frames: its geometry goes to
// the GPU over the frames that follow (render.mesh_add_over_frames), with
// upload naming it while it goes.
@(private="file")
assets_mesh_install :: proc(a:^Assets,view:asset.Mesh_View,entry:^Assets_Mesh,replace:=ASSETS_MESH_NONE,removed:^bool=nil,ahead:^render.Mesh_Ahead=nil,over_frames:=false,upload:^render.Mesh_Upload=nil) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    loaded:=Assets_Mesh{
        handle=ASSETS_MESH_NONE,bounds_min=view.info.bounds_min,bounds_max=view.info.bounds_max,
        slot_count=u32(len(view.slots)),skeleton=view.info.skeleton,morphs=u32(len(view.morphs)),levels=u32(len(view.levels)-1),
    }
    for slot,at in view.slots {loaded.slot_materials[at]=slot.material}
    level:=view.levels[0]
    loaded.index_count=3*level.triangle_count
    for c in view.clusters[level.first_cluster:][:level.cluster_count] {loaded.vertex_count+=asset.cluster_vertex_count(c)}
    if a.renderer!=nil {
        // A slot is the row of its material and its place among those of the mesh, from 1.
        words:[asset.MESH_MAX_SLOTS]u32
        for slot,at in view.slots {words[at]=assets_material_row(a,slot.material)|u32(at+1)<<24}
        if replace!=ASSETS_MESH_NONE && render.mesh_remove(a.renderer,replace) && removed!=nil {removed^=true}
        added:bool
        if over_frames && upload!=nil {
            loaded.handle,upload^,added=render.mesh_add_over_frames(a.renderer,view.geometry,words[:max(len(view.slots),1)],ahead)
        } else {
            loaded.handle,added=render.mesh_add_geometry(a.renderer,view.geometry,words[:max(len(view.slots),1)],ahead)
        }
        if !added {return .Rejected,.Invalid,false}
    }
    entry^=loaded
    return {},.None,true
}

// The entry of a mesh that loads now, in the index; nil without room, with the error in the list.
@(private="file")
assets_mesh_entry :: proc(a:^Assets,id:base.Asset_Id) -> ^Assets_Mesh {
    at,room:=assets_slot(&a.meshes,&a.free_meshes,&a.regions[0])
    if !room {
        assets_fail(a,id,.Mesh,.Capacity)
        return nil
    }
    a.index[id]={.Mesh,at}
    a.stats.meshes+=1
    return &a.meshes[at]
}

// The mesh of an asset, loaded the first time. nil for the zero id; the
// stand-in, with failed set, for one that cannot be loaded. The pointer is
// valid while the Assets lives; ask again after a.revision changes.
assets_mesh :: proc(a:^Assets,id:base.Asset_Id) -> ^Assets_Mesh {
    if id=={} {return nil}
    if ref,known:=a.index[id];known {
        if ref.kind==.Mesh {return &a.meshes[ref.index]}
        assets_fail(a,id,.Mesh,.Wrong_Kind)
        return assets_missing_mesh(a)
    }
    entry:=assets_mesh_entry(a,id)
    if entry==nil {return assets_missing_mesh(a)}
    scope:=load_asset_begin(a.load_profile)
    problem,detail,ok:=assets_mesh_load(a,id,entry)
    if !ok {
        assets_fail(a,id,.Mesh,problem,detail)
        entry^=assets_missing_mesh(a)^
    }
    load_asset_end(a.load_profile,scope,id,.Mesh,assets_file_bytes(a,id),!ok)
    return entry
}

// The bytes of the file of an asset; 0 for one the registry does not have.
assets_file_bytes :: proc(a:^Assets,id:base.Asset_Id) -> i64 {
    file,found:=asset.registry_find(&a.registry,id)
    return file.size if found else 0
}

@(private="file") ASSETS_GENERATED_TAG :: 0x6d697261695f6765 // first word of the id of every generated mesh and texture

// A mesh made at run time instead of read from a file, with an id of its own
// that a Mesh_Renderer shows like any other. Each triangle belongs to the slot
// mesh.materials names (slot 0 without them) and slot_materials is the
// material each slot comes with; without slot_materials the mesh has no slots
// and mesh.materials is not read.
// Normals are computed when the mesh brings none. It lives until
// assets_mesh_release. A transaction: between frames.
assets_mesh_generate :: proc(a:^Assets,mesh:geom.Mesh,slot_materials:[]base.Asset_Id=nil,uv1s:[]geom.Vec2=nil,options:Mesh_Generate_Options={}) -> (id:base.Asset_Id,ok:bool) {
    count,slots:=len(mesh.positions),len(slot_materials)
    if count==0 || len(mesh.indices)<3 || len(mesh.indices)%3!=0 || slots>asset.MESH_MAX_SLOTS {return}
    if len(mesh.normals)!=0 && len(mesh.normals)!=count || len(mesh.uvs)!=0 && len(mesh.uvs)!=count || len(mesh.colors)!=0 && len(mesh.colors)!=count {return}
    if len(uv1s)!=0 && len(uv1s)!=count {return}
    if len(mesh.materials)!=0 && len(mesh.materials)!=len(mesh.indices)/3 {return}
    for index in mesh.indices {
        if int(index)>=count {return}
    }
    for slot in mesh.materials[:slots>0?len(mesh.materials):0] {
        if int(slot)>=slots {return}
    }
    collides:=mesh
    if len(options.collision_mesh.indices)>0 {
        collides=options.collision_mesh
        if !geom.mesh_is_valid(collides) || len(collides.indices)%3!=0 || len(collides.normals)!=0 && len(collides.normals)!=len(collides.positions) || len(collides.uvs)!=0 && len(collides.uvs)!=len(collides.positions) {return}
        if len(collides.materials)!=0 && len(collides.materials)!=len(collides.indices)/3 {return}
        for slot in collides.materials[:slots>0?len(collides.materials):0] {
            if int(slot)>=slots {return}
        }
    }
    if len(options.disabled_edges)!=0 && len(options.disabled_edges)!=len(collides.indices)/3 {return}
    for mask in options.disabled_edges {if mask&~u8(7)!=0 {return}}
    pieces_total:=0
    for size in options.hull_sizes {
        if size<4 || int(size)>len(options.hull_points)-pieces_total {return}
        pieces_total+=int(size)
    }
    if pieces_total!=len(options.hull_points) {return}
    for point in options.hull_points {
        for value in point {if value-value!=0 {return}}
    }
    if field:=options.heightfield;field!=nil {
        if field.columns<2 || field.rows<2 || field.columns>max(int)/field.rows || len(field.heights)!=field.columns*field.rows {return}
        if len(field.disabled_borders)!=0 && len(field.disabled_borders)!=2*(field.rows-1)+2*(field.columns-1) {return}
        for mask in field.disabled_borders {if mask>1 {return}}
        if len(field.holes)!=0 && len(field.holes)!=(field.columns-1)*(field.rows-1) {return}
        for hole in field.holes {if hole>1 {return}}
        for value in field.cell {if !(value>0) || value-value!=0 {return}}
        for value in field.origin {if value-value!=0 {return}}
        for value in field.heights {if value-value!=0 {return}}
    }
    if len(a.free_meshes)==0 && !base.region_grow(&a.regions[0],&a.meshes) {
        assets_fail(a,{},.Mesh,.Capacity)
        return
    }
    entry:=Assets_Mesh{handle=ASSETS_MESH_NONE,vertex_count=u32(count),index_count=u32(len(mesh.indices)),slot_count=u32(slots),generated=true}
    success:=false
    defer if !success {assets_generated_free(&entry,a.allocator)}
    if options.collision {
        cloned :: proc(source:[]$T,count:int,a:mem.Allocator) -> ([]T,bool) {
            values,error:=make([]T,count,a)
            if error!=nil {return nil,false}
            copy(values,source)
            return values,true
        }
        held:=&entry.collision
        usable:bool
        points:=len(collides.positions)
        if held.positions,usable=cloned(collides.positions,points,a.allocator);!usable {return}
        if held.indices,usable=cloned(collides.indices,len(collides.indices),a.allocator);!usable {return}
        if held.normals,usable=cloned(collides.normals,points,a.allocator);!usable {return}
        if len(collides.normals)==0 {geom.mesh_compute_normals(held.positions,held.indices,held.normals)}
        if held.uvs,usable=cloned(collides.uvs,points,a.allocator);!usable {return}
        if held.colors,usable=cloned(collides.colors,len(collides.colors),a.allocator);!usable {return}
        materials:=collides.materials if slots>0 else nil
        if held.materials,usable=cloned(materials,len(collides.indices)/3,a.allocator);!usable {return}
        if entry.disabled_edges,usable=cloned(options.disabled_edges,len(options.disabled_edges),a.allocator);!usable {return}
    }
    if len(options.hull_sizes)>0 {
        error:mem.Allocator_Error
        if entry.hull_points,error=make([]geom.Vec3,len(options.hull_points),a.allocator);error!=nil {return}
        if entry.hull_sizes,error=make([]u32,len(options.hull_sizes),a.allocator);error!=nil {return}
        copy(entry.hull_points,options.hull_points)
        copy(entry.hull_sizes,options.hull_sizes)
    }
    if field:=options.heightfield;field!=nil {
        values,error:=make([]f32,len(field.heights),a.allocator)
        if error!=nil {return}
        copy(values,field.heights)
        entry.heightfield=field^
        entry.heightfield.heights=values
        entry.heightfield.disabled_borders=nil
        if len(field.disabled_borders)>0 {
            borders,failed:=make([]u8,len(field.disabled_borders),a.allocator)
            if failed!=nil {return}
            copy(borders,field.disabled_borders)
            entry.heightfield.disabled_borders=borders
        }
        entry.heightfield.holes=nil
        if len(field.holes)>0 {
            holes,failed:=make([]u8,len(field.holes),a.allocator)
            if failed!=nil {return}
            copy(holes,field.holes)
            entry.heightfield.holes=holes
        }
    }
    entry.bounds_min,entry.bounds_max=geom.mesh_bounds(mesh.positions)
    copy(entry.slot_materials[:],slot_materials)
    if a.renderer!=nil {
        made:=options.render_geometry
        here:Mesh_Render_Geometry
        defer if made==&here {assets_render_geometry_destroy(&here)}
        if made==nil {
            made=&here
            assets_render_geometry_init(&here,a.allocator)
            normals:=mesh.normals
            if len(normals)==0 {
                normals=make([]geom.Vec3,count,context.temp_allocator)
                geom.mesh_compute_normals(mesh.positions,mesh.indices,normals)
            }
            if !assets_render_geometry(mesh,normals,uv1s,slots,&here,assets_limits(a),options.tangents,!options.no_lods) {
                assets_fail(a,{},.Mesh,.Rejected)
                return
            }
        } else if made.slots!=slots || len(made.geometry.levels)==0 || int(made.geometry.levels[0].triangle_count)*3!=len(mesh.indices) {
            assets_fail(a,{},.Mesh,.Rejected)
            return
        }
        added:bool
        if entry.handle,added=assets_render_geometry_add(a,made,slot_materials);!added {
            assets_fail(a,{},.Mesh,.Rejected)
            return
        }
    }
    at:u32
    if len(a.free_meshes)>0 {
        at=pop(&a.free_meshes)
        a.meshes[at]=entry
    } else {
        append(&a.meshes,entry)
        at=u32(len(a.meshes)-1)
    }
    a.generated_next+=1
    id={ASSETS_GENERATED_TAG,a.generated_next}
    a.index[id]={.Mesh,at}
    a.stats.meshes+=1
    a.stats.generated+=1
    success=true
    return id,true
}

// The cuts the rays of the renderer of limits trace of out.geometry, which a
// job encoded into the arena of out, and the rest the renderer derives of it
// (render.mesh_ahead_make): what assets_mesh_publish takes with it. Any
// thread; false without memory.
assets_render_geometry_rays :: proc(out:^Mesh_Render_Geometry,limits:Assets_Limits) -> bool {
    render.mesh_ahead_destroy(&out.ahead)
    if !limits.renderer {return true}
    ahead,made:=render.mesh_ahead_make(out.geometry,max(out.slots,1),limits.software_rays,runtime.heap_allocator(),base.dynamic_arena_allocator(&out.arena))
    out.ahead=ahead
    return made
}

// A mesh made at run time whose geometry a job already encoded, with its
// rays (assets_render_geometry_make, or asset.mesh_build_far and
// assets_render_geometry_rays into the arena of made): a far mesh, of one slot
// of the default material, without collision. Like assets_mesh_generate it
// lives until assets_mesh_release. A transaction: between frames.
assets_mesh_publish :: proc(a:^Assets,made:^Mesh_Render_Geometry) -> (id:base.Asset_Id,ok:bool) {
    g:=made.geometry
    if len(g.clusters)==0 || len(g.levels)==0 || made.slots>1 {return}
    if len(a.free_meshes)==0 && !base.region_grow(&a.regions[0],&a.meshes) {
        assets_fail(a,{},.Mesh,.Capacity)
        return
    }
    entry:=Assets_Mesh{handle=ASSETS_MESH_NONE,index_count=g.levels[0].triangle_count*3,generated=true}
    for c in g.clusters[:g.levels[0].cluster_count] {entry.vertex_count+=asset.cluster_vertex_count(c)}
    entry.bounds_min,entry.bounds_max=g.bounds_min,g.bounds_max
    if a.renderer!=nil {
        added:bool
        if entry.handle,added=assets_render_geometry_add(a,made,nil);!added {
            assets_fail(a,{},.Mesh,.Rejected)
            return
        }
    }
    at:u32
    if len(a.free_meshes)>0 {
        at=pop(&a.free_meshes)
        a.meshes[at]=entry
    } else {
        append(&a.meshes,entry)
        at=u32(len(a.meshes)-1)
    }
    a.generated_next+=1
    id={ASSETS_GENERATED_TAG,a.generated_next}
    a.index[id]={.Mesh,at}
    a.stats.meshes+=1
    a.stats.generated+=1
    return id,true
}

// Registers render geometry with the rows of the materials of its slots.
@(private="file")
assets_render_geometry_add :: proc(a:^Assets,made:^Mesh_Render_Geometry,slot_materials:[]base.Asset_Id) -> (render.Mesh_Handle,bool) {
    words:[asset.MESH_MAX_SLOTS]u32
    for material,slot in slot_materials {words[slot]=assets_material_row(a,material)|u32(slot+1)<<24}
    return render.mesh_add_geometry(a.renderer,made.geometry,words[:max(made.slots,1)],&made.ahead)
}

// The render geometry of a mesh, into out, initialized: one vertex per source
// vertex, slot and tangent, so the triangles of two slots and the corners at
// a seam of the uvs do not share one, encoded by asset.mesh_build, and the
// cuts of its rays when limits has a renderer. Tangents are those given per
// vertex or, without them, MikkTSpace's over the uvs (geom.corner_tangents).
// slots: of the mesh, which mesh.materials gives each triangle; 0: none.
// Scratch from the temporary allocator. False without memory.
@(private="file")
assets_render_geometry :: proc(mesh:geom.Mesh,normals:[]geom.Vec3,uv1s:[]geom.Vec2,slots:int,out:^Mesh_Render_Geometry,limits:Assets_Limits,tangents:[][4]f32=nil,levels:=false) -> bool {
    scratch:=context.temp_allocator
    count:=len(mesh.positions)
    flags:asset.Mesh_Flags
    vertex_make :: proc(mesh:geom.Mesh,normals:[]geom.Vec3,uv1s:[]geom.Vec2,index,slot:u32,tangent:[4]f32,flags:^asset.Mesh_Flags) -> asset.Vertex {
        v:=asset.Vertex{position=mesh.positions[index],normal=mm.normal_pack(normals[index]),color=0xffffffff,material=slot,tangent=mm.tangent_pack(tangent.xyz,tangent.w)}
        if len(mesh.uvs)!=0 {v.uv,v.uv1=mesh.uvs[index],mesh.uvs[index]}
        if len(uv1s)!=0 {v.uv1=uv1s[index]}
        if v.uv1!=v.uv {flags^+={.Has_Uv1}}
        if len(mesh.colors)==len(mesh.positions) {
            c:=mesh.colors[index]
            v.color=mm.rgba8_pack({c.r,c.g,c.b,1})
            if v.color!=0xffffffff {flags^+={.Has_Colors}}
        }
        return v
    }
    vertices:=make([dynamic]asset.Vertex,0,count,scratch)
    indices,failed:=make([]u32,len(mesh.indices),scratch)
    if failed!=nil || vertices==nil && count>0 {return false}
    given:=len(tangents)==count
    if given && (slots<=1 || len(mesh.materials)==0) {
        // A vertex of each source vertex: with one slot and their tangents nothing splits them.
        for index in 0..<count {append(&vertices,vertex_make(mesh,normals,uv1s,u32(index),0,tangents[index],&flags))}
        copy(indices,mesh.indices)
    } else {
        corners:[][4]f32
        if corners,failed=make([][4]f32,len(mesh.indices),scratch);failed!=nil {return false}
        if given {
            for index,at in mesh.indices {corners[at]=tangents[index]}
        } else if !geom.corner_tangents(mesh.positions,normals,mesh.uvs,mesh.indices,corners) {return false}
        Key :: struct {index,slot:u32,tangent:[4]f32}
        known:=make(map[Key]u32,count,scratch)
        for index,at in mesh.indices {
            slot:=u32(0)
            if slots>0 && len(mesh.materials)!=0 {slot=mesh.materials[at/3]}
            key:=Key{index,slot,corners[at]}
            vertex,seen:=known[key]
            if !seen {
                vertex=u32(len(vertices))
                known[key]=vertex
                append(&vertices,vertex_make(mesh,normals,uv1s,index,slot,corners[at],&flags))
            }
            indices[at]=vertex
        }
    }
    render.mesh_ahead_destroy(&out.ahead)
    mem.dynamic_arena_free_all(&out.arena)
    allocator:=base.dynamic_arena_allocator(&out.arena)
    out.geometry={}
    out.ahead={}
    out.slots=slots
    source:=asset.Mesh_Source{vertices=vertices[:],flags=flags}
    built:=asset.mesh_build_dag(source,indices,&out.geometry,allocator) if levels else asset.mesh_build(source,indices,nil,&out.geometry,allocator)
    if !built {return false}
    if !limits.renderer {return true}
    ahead,made:=render.mesh_ahead_make(out.geometry,max(slots,1),limits.software_rays,runtime.heap_allocator(),allocator)
    out.ahead=ahead
    return made
}

@(private="file")
assets_generated_free :: proc(mesh:^Assets_Mesh,a:mem.Allocator) {
    delete(mesh.collision.positions,a);delete(mesh.collision.indices,a)
    delete(mesh.collision.normals,a);delete(mesh.collision.uvs,a);delete(mesh.collision.colors,a);delete(mesh.collision.materials,a)
    delete(mesh.heightfield.heights,a)
    delete(mesh.heightfield.disabled_borders,a)
    delete(mesh.heightfield.holes,a)
    delete(mesh.disabled_edges,a)
    delete(mesh.hull_points,a);delete(mesh.hull_sizes,a)
    mesh.collision,mesh.heightfield={},{}
    mesh.hull_points,mesh.hull_sizes=nil,nil
}

assets_mesh_generated :: proc(a:^Assets,id:base.Asset_Id) -> bool {
    if a==nil {return false}
    ref,known:=a.index[id]
    return known && ref.kind==.Mesh && a.meshes[ref.index].generated
}

// The box of a mesh loaded from its file, without loading it: false for one
// that is not loaded, failed or was generated.
assets_mesh_bounds :: proc(a:^Assets,id:base.Asset_Id) -> (low,high:[3]f32,ok:bool) {
    if a==nil {return}
    ref,known:=a.index[id]
    if !known || ref.kind!=.Mesh {return}
    entry:=&a.meshes[ref.index]
    if entry.failed || entry.generated {return}
    return entry.bounds_min,entry.bounds_max,true
}

// Whether the file of a mesh may hold a rig, a skin or morphs: false only
// for a mesh loaded from its file without either, whose file needs no
// reading for them.
assets_mesh_rigged :: proc(a:^Assets,id:base.Asset_Id) -> bool {
    if a==nil {return true}
    ref,known:=a.index[id]
    if !known || ref.kind!=.Mesh {return true}
    entry:=&a.meshes[ref.index]
    return entry.failed || entry.generated || entry.skeleton!={} || entry.morphs>0
}

assets_heightfield :: proc(a:^Assets,id:base.Asset_Id) -> (field:Assets_Heightfield,ok:bool) {
    if !assets_mesh_generated(a,id) {return}
    field=a.meshes[a.index[id].index].heightfield
    return field,len(field.heights)>0
}

assets_mesh_disabled_edges :: proc(a:^Assets,id:base.Asset_Id) -> []u8 {
    if !assets_mesh_generated(a,id) {return nil}
    return a.meshes[a.index[id].index].disabled_edges
}

// Removes a generated mesh, from the renderer too: its id names nothing from
// here on. a.revision advances so consumers stop using its retired handle.
// False for an id that is not a generated mesh.
assets_mesh_release :: proc(a:^Assets,id:base.Asset_Id) -> bool {
    ref,known:=a.index[id]
    if !known || ref.kind!=.Mesh || !a.meshes[ref.index].generated {return false}
    entry:=&a.meshes[ref.index]
    if a.renderer!=nil && entry.handle!=ASSETS_MESH_NONE {render.mesh_remove(a.renderer,entry.handle)}
    assets_generated_free(entry,a.allocator)
    entry^={handle=ASSETS_MESH_NONE}
    delete_key(&a.index,id)
    append(&a.free_meshes,ref.index)
    a.stats.meshes-=1
    a.stats.generated-=1
    a.revision+=1
    assets_structure_changed(a,id)
    return true
}

// ------------------------------------------------------------------- textures

@(private="file")
assets_missing_texture :: proc(a:^Assets) -> ^Assets_Texture {
    if a.missing_texture_ready {return &a.missing_texture}
    a.missing_texture_ready=true
    a.missing_texture={width=4,height=4,layers=1,format=.RGBA8,flags={.Srgb},failed=true}
    if a.renderer!=nil {
        pixels:[64]u8
        for at in 0..<16 {
            lit:=(at%4/2+at/8)%2==0
            pixels[at*4],pixels[at*4+1],pixels[at*4+2],pixels[at*4+3]=lit?255:0,0,lit?255:0,255
        }
        a.missing_texture.handle,_=render.texture_add(a.renderer,{pixels=pixels[:],width=4,height=4,srgb=true,name="missing texture"})
    }
    return &a.missing_texture
}

@(private="file")
assets_texture_load :: proc(a:^Assets,id:base.Asset_Id,entry:^Assets_Texture,replace:=render.Texture_Handle(0),removed:^bool=nil) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    file:asset.Asset
    if problem,detail,ok=assets_open(a,id,.Texture,&file);!ok {return}
    defer asset.asset_close(&file)
    view,view_error:=asset.texture_open(&file,&a.types)
    if view_error!=.None {return .Corrupt,view_error,false}
    levels:Assets_Levels
    defer assets_levels_free(&levels)
    first:=0
    if a.renderer!=nil {first,_=assets_texture_first(view,render.texture_limits(a.renderer),0)}
    if view_error=asset.texture_decode(&file,&a.types,&view,first);view_error!=.None {return .Corrupt,view_error,false}
    if a.renderer!=nil {
        if problem,detail,ok=assets_texture_levels(view,render.texture_limits(a.renderer),0,&levels,a.allocator);!ok {return}
    }
    return assets_texture_install(a,id,view.info^,&levels,entry,replace,removed)
}

// The levels of a texture the renderer takes, and the texels they decode to.
@(private="file")
Assets_Levels :: struct {
    data:render.Texture_Data,
    decoded:[]u8,
    allocator:mem.Allocator,
}

@(private="file")
assets_levels_free :: proc(levels:^Assets_Levels) {
    if levels.allocator.procedure==nil {return}
    delete(levels.data.levels)
    delete(levels.decoded,levels.allocator)
    levels^={}
}

// The first level of a texture the renderer takes: `from`, or the first one
// its side allows; for an array or a cube, the first one its side allows.
// fits is false when not even the last one fits.
@(private="file")
assets_texture_first :: proc(view:asset.Texture_View,limits:render.Texture_Limits,from:int) -> (first:int,fits:bool) {
    limit:=u32(limits.max_size)
    for first+1<len(view.mips) && max(view.mips[first].width,view.mips[first].height)>limit {first+=1}
    if max(view.mips[first].width,view.mips[first].height)>limit {return first,false}
    if view.info.layers<=1 && .Cube not_in view.info.flags {first=max(first,min(from,len(view.mips)-1))}
    return first,true
}

// The levels of a texture the renderer takes: from `from`, or the first one
// its side allows, to the last; for a device that does not sample blocks,
// decoded to RGBA8, and BC6H to RGBA16F.
// The levels of one layer name the file as their source, whose other levels
// the renderer can ask for; an array or a cube takes every level its side
// allows at once. Any thread.
@(private="file")
assets_texture_levels :: proc(view:asset.Texture_View,limits:render.Texture_Limits,from:int,levels:^Assets_Levels,allocator:mem.Allocator) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    info:=view.info
    blocks:=info.format!=.RGBA8 && info.format!=.RGBA16 && info.format!=.RGBA16F
    decode:=blocks && !limits.blocks
    srgb:=.Srgb in info.flags
    layers:=int(info.layers)
    layered:=layers>1 || .Cube in info.flags
    levels.allocator=allocator
    data:=&levels.data
    format:=info.format
    if decode {format=.RGBA16F if info.format==.BC6H else .RGBA8}
    switch format {
    case .RGBA8:   data.format=srgb?.RGBA8_Srgb:.RGBA8_Unorm
    case .RGBA16:  data.format=.RGBA16_Unorm
    case .RGBA16F: data.format=.RGBA16_Float
    case .BC1:     data.format=srgb?.BC1_Srgb:.BC1_Unorm
    case .BC3:     data.format=srgb?.BC3_Srgb:.BC3_Unorm
    case .BC5:     data.format=.BC5_Unorm
    case .BC6H:    data.format=.BC6H_Ufloat
    case .BC7:     data.format=srgb?.BC7_Srgb:.BC7_Unorm
    }
    first,fits:=assets_texture_first(view,limits,from)
    if !fits {return .Unsupported,.None,false}
    if first<view.first {return .Corrupt,.Invalid,false}
    data.width,data.height=int(view.mips[first].width),int(view.mips[first].height)
    data.layers,data.cube=layers,.Cube in info.flags
    data.level=first
    if !layered {data.source={int(info.width),int(info.height)}}
    alloc_error:mem.Allocator_Error
    if data.levels,alloc_error=make([dynamic][]u8,0,len(view.mips)-first,allocator);alloc_error!=nil {return .Rejected,.Out_Of_Memory,false}
    texel:=8 if format==.RGBA16F else 4
    if decode {
        total:=0
        for mip in view.mips[first:] {total+=int(mip.width)*int(mip.height)*texel*layers}
        levels.decoded,alloc_error=make([]u8,total,allocator)
        if alloc_error!=nil {return .Rejected,.Out_Of_Memory,false}
    }
    at:=0
    for level in first..<len(view.mips) {
        texels:=asset.texture_mip(view,level)
        if decode {
            mip:=view.mips[level]
            size:=int(mip.width)*int(mip.height)*texel
            for layer in 0..<layers {
                image:=asset.texture_layer(view,level,layer)
                out:=levels.decoded[at+layer*size:][:size]
                decoded:=asset.texture_level_rgba16f(info.format,image,int(mip.width),int(mip.height),out) if format==.RGBA16F else asset.texture_level_rgba8(info.format,image,int(mip.width),int(mip.height),out)
                if !decoded {return .Corrupt,.Invalid,false}
            }
            texels=levels.decoded[at:at+size*layers]
            at+=size*layers
        }
        append(&data.levels,texels)
    }
    return {},.None,true
}

// Notes the asset a texture of the renderer was given, by its handle. Without
// memory for the note the texture keeps the levels it was given.
@(private="file")
assets_texture_given :: proc(a:^Assets,handle:render.Texture_Handle,id:base.Asset_Id) {
    if handle==0 {return}
    if int(handle)>len(a.texture_assets) && resize(&a.texture_assets,int(handle))!=nil {return}
    a.texture_assets[handle-1]=id
}

// The entry of a texture of info, its levels given to the renderer.
@(private="file")
assets_texture_install :: proc(a:^Assets,id:base.Asset_Id,info:asset.Texture_Info,levels:^Assets_Levels,entry:^Assets_Texture,replace:=render.Texture_Handle(0),removed:^bool=nil) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    loaded:=Assets_Texture{width=info.width,height=info.height,layers=info.layers,format=info.format,flags=info.flags}
    if r:=a.renderer;r!=nil {
        name:="texture"
        if record,found:=asset.registry_find(&a.registry,id);found {name=record.path}
        if replace!=0 && render.texture_remove(r,replace) && removed!=nil {removed^=true}
        added:bool
        loaded.handle,added=render.texture_add_data(r,levels.data,name)
        if !added {return .Rejected,.Invalid,false}
        assets_texture_given(a,loaded.handle,id)
    }
    entry^=loaded
    return {},.None,true
}

// The entry of a texture whose levels of side render.TEXTURE_TAIL the
// renderer takes now and the others over frames: the request they go with
// while they go (none when they do not).
@(private="file")
assets_texture_install_over_frames :: proc(a:^Assets,id:base.Asset_Id,prepared:^Assets_Prepared,entry:^Assets_Texture) -> (problem:Assets_Problem,detail:asset.Error,ok:bool,upload:render.Texture_Request) {
    info:=prepared.texture
    loaded:=Assets_Texture{width=info.width,height=info.height,layers=info.layers,format=info.format,flags=info.flags}
    name:="texture"
    if record,found:=asset.registry_find(&a.registry,id);found {name=record.path}
    handle,request,result:=render.texture_add_over_frames(a.renderer,&prepared.levels.data,name)
    if handle==0 && result==.Mismatch {
        // The pool left no level to give later: the texture goes whole.
        problem,detail,ok=assets_texture_install(a,id,info,&prepared.levels,entry)
        return
    }
    if handle==0 {return .Rejected,.Invalid,false,{}}
    loaded.handle=handle
    assets_texture_given(a,handle,id)
    entry^=loaded
    return {},.None,true,request if result==.Set else {}
}

// The entry of a texture that loads now, in the index; nil without room, with the error in the list.
@(private="file")
assets_texture_entry :: proc(a:^Assets,id:base.Asset_Id) -> ^Assets_Texture {
    at,room:=assets_slot(&a.textures,&a.free_textures,&a.regions[1])
    if !room {
        assets_fail(a,id,.Texture,.Capacity)
        return nil
    }
    a.index[id]={.Texture,at}
    a.stats.textures+=1
    return &a.textures[at]
}

// The texture of an asset, loaded the first time. nil for the zero id, when
// there is no room for another, and without a renderer for one the assets do
// not have (a server cooked without textures); the checker, with failed set,
// for one that cannot be loaded.
assets_texture :: proc(a:^Assets,id:base.Asset_Id) -> ^Assets_Texture {
    if id=={} {return nil}
    if ref,known:=a.index[id];known {
        if ref.kind==.Texture {return &a.textures[ref.index]}
        assets_fail(a,id,.Texture,.Wrong_Kind)
        return assets_missing_texture(a)
    }
    if a.renderer==nil {
        if _,found:=asset.registry_find(&a.registry,id);!found {return nil}
    }
    entry:=assets_texture_entry(a,id)
    if entry==nil {return nil}
    scope:=load_asset_begin(a.load_profile)
    problem,detail,ok:=assets_texture_load(a,id,entry)
    if !ok {
        assets_fail(a,id,.Texture,problem,detail)
        entry^=assets_missing_texture(a)^
    }
    load_asset_end(a.load_profile,scope,id,.Texture,assets_file_bytes(a,id),!ok)
    return entry
}

// The texture of an asset where a material or an interface samples a 2D
// image, as assets_texture gives it; nil for an array or a cube, which is
// Unsupported there.
assets_texture_image :: proc(a:^Assets,id:base.Asset_Id) -> ^Assets_Texture {
    texture:=assets_texture(a,id)
    if texture!=nil && (texture.layers>1 || .Cube in texture.flags) {
        assets_fail(a,id,.Texture,.Unsupported)
        return nil
    }
    return texture
}

// A texture made at run time from RGBA8 pixels, rows from the top, with an
// id of its own that an image of the UI or a material shows as it shows a
// texture asset: an image a game read itself, as the thumbnail of a save.
// srgb: it is color. Its levels are made here, and the pixels can go once it
// returns. It lives until assets_texture_release; each id is a version that
// is never used again. A transaction: between frames. False, with nothing
// made, for a size of zero or pixels that do not hold width by height, and
// without room for another texture.
assets_texture_generate :: proc(a:^Assets,pixels:[]u8,width,height:int,srgb:=true,name:="generated texture") -> (id:base.Asset_Id,ok:bool) {
    if width<=0 || height<=0 || len(pixels)!=width*height*4 {return}
    a.generated_next+=1
    id={ASSETS_GENERATED_TAG,a.generated_next}
    entry:=assets_texture_entry(a,id)
    if entry==nil {return {},false}
    made:=Assets_Texture{width=u32(width),height=u32(height),layers=1,format=.RGBA8,flags=srgb?{.Srgb}:{},generated=true}
    if a.renderer!=nil {
        added:bool
        if made.handle,added=render.texture_add(a.renderer,{pixels=pixels,width=width,height=height,srgb=srgb,name=name});!added {
            entry^={}
            append(&a.free_textures,a.index[id].index)
            delete_key(&a.index,id)
            a.stats.textures-=1
            return {},false
        }
    }
    entry^=made
    a.stats.generated+=1
    return id,true
}

// Removes a generated texture, from the renderer too: its id names nothing
// from here on, and a.revision advances so that what shows it lets it go.
// False for an id that is not a generated texture.
assets_texture_release :: proc(a:^Assets,id:base.Asset_Id) -> bool {
    ref,known:=a.index[id]
    if !known || ref.kind!=.Texture || !a.textures[ref.index].generated {return false}
    entry:=&a.textures[ref.index]
    if a.renderer!=nil && entry.handle!=0 {render.texture_remove(a.renderer,entry.handle)}
    entry^={}
    delete_key(&a.index,id)
    append(&a.free_textures,ref.index)
    a.stats.textures-=1
    a.stats.generated-=1
    a.revision+=1
    assets_structure_changed(a,id)
    return true
}

// ------------------------------------------------------------------ materials

// What a material that cannot be loaded shows: magenta, glowing a little.
@(private="file")
assets_missing_material :: proc() -> asset.Material_Info {
    info:=asset.MATERIAL_DEFAULTS
    info.base_color,info.emission={1,0,1},{0.25,0,0.25}
    return info
}

// The parameters a material stores, its own and those of its overlays.
assets_material_parameters :: proc(a:^Assets,material:^Assets_Material) -> []asset.Material_Parameter {
    return a.parameters[material.first_parameter:][:material.parameter_count]
}

// The program of the shaders a material names, in one domain; nil for the
// standard model, without a renderer and when the shaders do not have it.
assets_material_program :: proc(a:^Assets,material:^Assets_Material,domain:render.Program_Domain) -> ^render.Program {
    name:=base.text_get(material.info.program[:])
    if name=="" || a.renderer==nil {return nil}
    return render.program_find(a.renderer,name,domain)
}

// Writes over the parameters of a program the values a material stores for
// itself (layer 0) or for one of its overlays, by name. A value of another
// type than the program declares, or outside its range, leaves what was
// there. Textures are loaded. Returns how many it wrote.
@(private="file")
assets_program_parameters :: proc(a:^Assets,program:^render.Program,params:^[16]render.Vec4,stored:[]asset.Material_Parameter,layer:u32) -> (written:int) {
    for &value in stored {
        if value.overlay!=layer {continue}
        if assets_program_value(a,program,params,base.text_get(value.name[:]),value.kind,value.value,value.texture)==.None {written+=1}
    }
    return
}

Program_Value_Error :: enum u8 {None,Unknown,Kind,Range}

// Writes one value over the parameters of a program, by the name of the
// parameter, loading a texture. Unknown: the program has no parameter of
// that name; Kind: it takes a texture and the value is not one, or the other
// way; Range: a number its parameter does not take.
assets_program_value :: proc(a:^Assets,program:^render.Program,params:^[16]render.Vec4,name:string,kind:asset.Parameter_Kind,values:[4]f64,texture:base.Asset_Id) -> Program_Value_Error {
    parameter:=render.program_parameter(program,name)
    if parameter==nil {return .Unknown}
    if (parameter.kind==.Texture)!=(kind==.Texture) {return .Kind}
    if parameter.kind==.Texture {
        loaded:=assets_texture_image(a,texture)
        render.program_parameter_set_texture(a.renderer,params,parameter,loaded!=nil?loaded.handle:0)
        return .None
    }
    return render.program_parameter_set(params,parameter,values)?.None:.Range
}

// The row of the renderer for a material, loading its textures. A Surface
// program replaces the standard model: of its maps only the normal map is
// read. A texture that failed is only shown as base color.
@(private="file")
assets_material_desc :: proc(a:^Assets,material:^Assets_Material,id:base.Asset_Id) -> render.Material_Desc {
    desc:=render.Material_Desc{info=material.info}
    program:=assets_material_program(a,material,.Surface)
    if program==nil && material.info.program[0]!=0 && a.renderer!=nil && assets_material_program(a,material,.Postprocess)==nil {
        assets_fail(a,id,.Material,.Unsupported)
    }
    for source,which in asset.material_maps(&desc.maps) {
        if program!=nil && which!=.Normal {continue}
        texture:=assets_texture_image(a,source.texture)
        if texture!=nil && (!texture.failed || which==.Base_Color) {desc.textures[which]=texture.handle}
    }
    if program!=nil {
        desc.program_id=program.id
        desc.custom_params=render.program_defaults(program)
        assets_program_parameters(a,program,&desc.custom_params,assets_material_parameters(a,material),0)
    }
    return desc
}

@(private="file")
assets_material_load :: proc(a:^Assets,id:base.Asset_Id,entry:^Assets_Material) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    file:asset.Asset
    if problem,detail,ok=assets_open(a,id,.Material,&file);!ok {return}
    defer asset.asset_close(&file)
    view,view_error:=asset.material_view(&file,&a.types)
    if view_error!=.None {return .Corrupt,view_error,false}
    return assets_material_install(a,view,entry)
}

// The values of a material of view in its entry.
@(private="file")
assets_material_install :: proc(a:^Assets,view:asset.Material_View,entry:^Assets_Material) -> (problem:Assets_Problem,detail:asset.Error,ok:bool) {
    count:=u32(len(view.parameters))
    if count>entry.parameter_room {
        if resize(&a.parameters,len(a.parameters)+int(count))!=nil {return .Rejected,.Out_Of_Memory,false}
        entry.first_parameter,entry.parameter_room=u32(len(a.parameters))-count,count
    }
    entry.parameter_count=count
    copy(assets_material_parameters(a,entry),view.parameters)
    entry.info=view.info^
    entry.overlay_count=u32(copy(entry.overlays[:],view.overlays))
    entry.failed=false
    return {},.None,true
}

// The material of an asset, loaded the first time with the textures it
// names. nil for the zero id and when there is no room for another; the
// stand-in values, with failed set, for one that cannot be loaded. Call
// assets_commit before the next frame.
assets_material :: proc(a:^Assets,id:base.Asset_Id) -> ^Assets_Material {
    if id=={} {return nil}
    if ref,known:=a.index[id];known {
        if ref.kind==.Material {return &a.materials[ref.index]}
        assets_fail(a,id,.Material,.Wrong_Kind)
        return nil
    }
    entry:=assets_material_entry(a,id)
    if entry==nil {return nil}
    scope:=load_asset_begin(a.load_profile)
    problem,detail,ok:=assets_material_load(a,id,entry)
    assets_material_loaded(a,entry,problem,detail,ok)
    load_asset_end(a.load_profile,scope,id,.Material,assets_file_bytes(a,id),!ok)
    return entry
}

// The entry of a material that loads now, with its row, in the index; nil
// without room, with the error in the list.
@(private="file")
assets_material_entry :: proc(a:^Assets,id:base.Asset_Id) -> ^Assets_Material {
    row,has_row:=assets_row_take(a)
    at,room:=u32(0),false
    if has_row {at,room=assets_slot(&a.materials,&a.free_materials,&a.regions[2])}
    if !room {
        if has_row {assets_row_free(a,row)}
        assets_fail(a,id,.Material,.Capacity)
        return nil
    }
    a.materials[at]={id=id,row=row}
    a.row_marks[row-1]=ASSETS_ROW_ASSET
    a.index[id]={.Material,at}
    a.stats.materials+=1
    return &a.materials[at]
}

// The row of a material that loaded, or of its stand-in values when it did not.
@(private="file")
assets_material_loaded :: proc(a:^Assets,entry:^Assets_Material,problem:Assets_Problem,detail:asset.Error,ok:bool) {
    if !ok {
        assets_fail(a,entry.id,.Material,problem,detail)
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        entry.info=assets_missing_material()
        entry.parameter_count,entry.overlay_count,entry.failed=0,0,true
    }
    a.material_descs[entry.row-1]=assets_material_desc(a,entry,entry.id)
    assets_row_changed(a,entry.row)
}

// ------------------------------------------------------------ prepared in jobs

// What a job needs to read assets as these Assets load them.
Assets_Limits :: struct {
    renderer:bool,
    texture:render.Texture_Limits,
    tail:bool, // textures come from their level of side render.TEXTURE_TAIL
    software_rays:bool, // the renderer traces rays by software: the cuts of a mesh take their trees
}

// On the thread of the assets. tail: textures come with their levels of
// side render.TEXTURE_TAIL at most, and their distance asks for the others
// once something shows them: those of what loads far away, as a section.
assets_limits :: proc(a:^Assets,tail:=false) -> Assets_Limits {
    if a==nil || a.renderer==nil {return {}}
    return {true,render.texture_limits(a.renderer),tail,!render.hardware_ray_tracing_active(a.renderer)}
}

// A mesh, a texture or a material a job read, checked and decoded
// (assets_prepare), for assets_take to give to the renderer. Its failure is
// kept: taking it records it as loading would.
Assets_Prepared :: struct {
    source:Assets_Source,
    kind:Assets_Kind,
    file:asset.Asset,
    opened:bool,
    renderer:bool, // read for a renderer (Assets_Limits.renderer)
    problem:Assets_Problem,
    detail:asset.Error,
    ok:bool,
    cost:int, // bytes it gives the renderer at once: of a mesh, the pages it keeps and the trees of its rays (render.mesh_add_bytes); of a texture, its levels
    level:int, // of a texture: the first level of its file it reads; 0: the largest the limits take
    upload:render.Texture_Request, // of a texture taken over frames: its levels go to the GPU while render.texture_upload_pending
    mesh_upload:render.Mesh_Upload, // of a mesh taken over frames: its geometry goes to the GPU while render.mesh_upload_pending
    mesh:asset.Mesh_View,
    ahead:render.Mesh_Ahead, // of mesh, with a renderer
    texture:asset.Texture_Info,
    levels:Assets_Levels,
    material:asset.Material_View,
    ns:i64, // what assets_prepare took
}

// Reads the file of prepared.source and does what loading it does before the
// renderer takes it. Any thread; types and decoder are of the thread and
// outlive nothing of prepared.
assets_prepare :: proc(prepared:^Assets_Prepared,limits:Assets_Limits,types:^asset.Types,decoder:^asset.Decoder=nil) {
    started:=time.tick_now()
    defer prepared.ns=time.duration_nanoseconds(time.tick_since(started))
    // What reads the file after it, on another thread, decodes with a decoder of its own.
    defer if !prepared.file.decoder_owned {prepared.file.decoder=nil}
    switch prepared.source.kind {
    case asset.KIND_MESH:     prepared.kind=.Mesh
    case asset.KIND_TEXTURE:  prepared.kind=.Texture
    case asset.KIND_MATERIAL: prepared.kind=.Material
    case:
        prepared.problem,prepared.detail=.Wrong_Kind,.Invalid
        return
    }
    if prepared.detail=assets_source_open(&prepared.source,&prepared.file,decoder);prepared.detail!=.None {
        prepared.problem,_=assets_problem_of(prepared.detail)
        return
    }
    prepared.opened=true
    prepared.renderer=limits.renderer
    #partial switch prepared.kind {
    case .Mesh:
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        mesh,problem,detail,ok:=assets_mesh_view(&prepared.file,types)
        prepared.mesh=mesh
        prepared.problem,prepared.detail,prepared.ok=problem,detail,ok
        if !prepared.ok {return}
        g:=prepared.mesh.geometry
        defer prepared.cost=render.mesh_add_bytes(g,len(prepared.mesh.slots),&prepared.ahead.rays,!limits.software_rays)
        // Without it the renderer makes it when it takes the mesh.
        if !limits.renderer {return}
        ahead,_:=render.mesh_ahead_make(g,max(len(prepared.mesh.slots),1),limits.software_rays,prepared.source.allocator,prepared.source.allocator)
        prepared.ahead=ahead
    case .Texture:
        view,view_error:=asset.texture_open(&prepared.file,types)
        from,first:=0,0
        if view_error==.None && limits.renderer {
            from=prepared.level
            if limits.tail {
                for from+1<len(view.mips) && max(view.mips[from].width,view.mips[from].height)>render.TEXTURE_TAIL {from+=1}
            }
            // Only the levels it gives decode: the smallest lie at the start of the stream.
            first,_=assets_texture_first(view,limits.texture,from)
        }
        if view_error==.None {view_error=asset.texture_decode(&prepared.file,types,&view,first)}
        if view_error!=.None {
            prepared.problem,prepared.detail=.Corrupt,view_error
            return
        }
        prepared.texture,prepared.ok,prepared.cost=view.info^,true,len(view.texels)
        if limits.renderer {
            prepared.problem,prepared.detail,prepared.ok=assets_texture_levels(view,limits.texture,from,&prepared.levels,prepared.source.allocator)
            prepared.cost=0
            for level in prepared.levels.data.levels {prepared.cost+=len(level)}
        }
    case .Material:
        view,view_error:=asset.material_view(&prepared.file,types)
        if view_error!=.None {
            prepared.problem,prepared.detail=.Corrupt,view_error
            return
        }
        prepared.material,prepared.ok=view,true
    }
}

Assets_Take :: enum u8 {
    Taken,
    Uploading, // over frames, from what prepared keeps: the levels of a texture, while render.texture_upload_pending(prepared.upload); the geometry of a mesh, while render.mesh_upload_pending(prepared.mesh_upload)
    Wait,      // nothing was taken: the renderer takes the levels or geometry of others; again in a later frame
}

// Gives the assets what a job prepared, as loading it here would. Nothing
// when the asset was loaded meanwhile or its file changed since it was read:
// what asks for it then loads it. over_frames: a texture whose levels take
// more than LOAD_FRAME_BYTES gets those of side render.TEXTURE_TAIL at once
// and the others over the frames that follow (render.texture_add_over_frames);
// a mesh that gives the pools more than that at once gives them its geometry
// over the frames that follow, the copy of the CPU too, and no instance draws
// it until all of it went (render.mesh_add_over_frames). What is taken so is
// read from prepared until then. Call assets_commit before the next frame.
assets_take :: proc(a:^Assets,prepared:^Assets_Prepared,over_frames:=false) -> Assets_Take {
    id:=prepared.source.id
    if id=={} || assets_loaded(a,id) {return .Taken}
    record,found:=asset.registry_find(&a.registry,id)
    if !found || record.content_hash!=prepared.source.hash || record.kind!=prepared.source.kind {return .Taken}
    split:=over_frames && a.renderer!=nil && assets_prepared_split(prepared)
    if split && !(render.mesh_upload_room(a.renderer) if prepared.kind==.Mesh else render.texture_upload_room(a.renderer)) {return .Wait}
    if prepared.opened {a.stats.loads+=1}
    problem,detail,ok:=prepared.problem,prepared.detail,prepared.ok
    taken:=Assets_Take.Taken
    #partial switch prepared.kind {
    case .Mesh:
        entry:=assets_mesh_entry(a,id)
        if entry==nil {return .Taken}
        if ok {problem,detail,ok=assets_mesh_install(a,prepared.mesh,entry,ahead=&prepared.ahead,over_frames=split,upload=&prepared.mesh_upload)}
        if ok && prepared.mesh_upload!={} {taken=.Uploading}
        if !ok {
            assets_fail(a,id,.Mesh,problem,detail)
            entry^=assets_missing_mesh(a)^
        }
    case .Texture:
        entry:=assets_texture_entry(a,id)
        if entry==nil {return .Taken}
        if ok && split {
            problem,detail,ok,prepared.upload=assets_texture_install_over_frames(a,id,prepared,entry)
            if prepared.upload.handle!=0 {taken=.Uploading}
        } else if ok {
            problem,detail,ok=assets_texture_install(a,id,prepared.texture,&prepared.levels,entry)
        }
        if !ok {
            assets_fail(a,id,.Texture,problem,detail)
            entry^=assets_missing_texture(a)^
        }
    case .Material:
        entry:=assets_material_entry(a,id)
        if entry==nil {return .Taken}
        if ok {problem,detail,ok=assets_material_install(a,prepared.material,entry)}
        assets_material_loaded(a,entry,problem,detail,ok)
    }
    return taken
}

// Whether a prepared asset goes over frames when it is taken so: it gives
// a renderer more than LOAD_FRAME_BYTES at once, and is a mesh or a texture
// with levels larger than render.TEXTURE_TAIL.
assets_prepared_split :: proc(prepared:^Assets_Prepared) -> bool {
    if !prepared.ok || !prepared.renderer || prepared.cost<=LOAD_FRAME_BYTES {return false}
    return prepared.kind==.Mesh || prepared.kind==.Texture && render.texture_tail_first(prepared.levels.data)>0
}

// The bytes a prepared asset gives the renderer in the frame it is taken:
// over frames, of a texture that splits, its levels of side
// render.TEXTURE_TAIL, and of a mesh, none; the rest goes with the uploads
// of the renderer.
assets_prepared_cost :: proc(prepared:^Assets_Prepared,over_frames:=false) -> int {
    if !over_frames || !assets_prepared_split(prepared) {return prepared.cost}
    if prepared.kind==.Mesh {return 0}
    bytes:=0
    for level in prepared.levels.data.levels[render.texture_tail_first(prepared.levels.data):] {bytes+=len(level)}
    return bytes
}

assets_prepared_free :: proc(prepared:^Assets_Prepared) {
    render.mesh_ahead_destroy(&prepared.ahead)
    assets_levels_free(&prepared.levels)
    asset.asset_close(&prepared.file)
    assets_source_free(&prepared.source)
    prepared^={}
}

// The row of a material takes the values the material has now. It goes to the
// renderer alone, and only when they differ: true when they did.
@(private="file")
assets_material_row_update :: proc(a:^Assets,material:^Assets_Material) -> bool {
    desc:=assets_material_desc(a,material,material.id)
    if a.material_descs[material.row-1]==desc {return false}
    a.material_descs[material.row-1]=desc
    assets_row_changed(a,material.row)
    return true
}

// Gives a loaded material other values where it is, as if its file held
// them, without reading or writing the file: its values and the parameters
// it stores, its own and those of its overlays (a copy, not the slice of
// assets_material_parameters). Its row goes to the renderer alone with the
// next assets_commit, and while rows derived from materials are in use,
// a.structure advances with its id so that only what derives a row from it
// is asked for again. False, with nothing changed, for a material that is
// not loaded or failed, or without memory for its parameters.
assets_material_set :: proc(a:^Assets,id:base.Asset_Id,info:asset.Material_Info,parameters:[]asset.Material_Parameter) -> bool {
    ref,known:=a.index[id]
    if !known || ref.kind!=.Material || a.materials[ref.index].failed {return false}
    material:=&a.materials[ref.index]
    if material.info==info && slice.equal(assets_material_parameters(a,material),parameters) {return true}
    count:=u32(len(parameters))
    if count>material.parameter_room {
        if resize(&a.parameters,len(a.parameters)+int(count))!=nil {return false}
        material.first_parameter,material.parameter_room=u32(len(a.parameters))-count,count
    }
    material.info,material.parameter_count=info,count
    copy(assets_material_parameters(a,material),parameters)
    assets_material_row_update(a,material)
    if a.stats.derived>0 {assets_structure_changed(a,id)}
    return true
}

// The row of a material in the table of the renderer; 0, the default material, for none.
assets_material_row :: proc(a:^Assets,id:base.Asset_Id) -> u32 {
    material:=assets_material(a,id)
    return material!=nil?material.row:0
}

// --------------------------------------------------------------- derived rows

@(private="file")
assets_row_take :: proc(a:^Assets) -> (row:u32,ok:bool) {
    if len(a.free_rows)>0 {return pop(&a.free_rows),true}
    if !base.region_grow(&a.regions[4],&a.material_descs) || !base.region_grow(&a.regions[5],&a.row_marks) || !base.region_grow(&a.regions[6],&a.row_hashes) {return 0,false}
    append(&a.material_descs,render.Material_Desc{})
    append(&a.row_marks,ASSETS_ROW_FREE)
    append(&a.row_hashes,0)
    return u32(len(a.material_descs)),true
}

@(private="file")
assets_row_free :: proc(a:^Assets,row:u32) {
    a.row_marks[row-1]=ASSETS_ROW_FREE
    append(&a.free_rows,row)
}

// Opens a round of derived rows: the rows asked for from here on are the
// ones in use. Whoever extracts the scene opens one before it asks and
// closes it with assets_appearance_end, which frees the rest.
assets_appearance_begin :: proc(a:^Assets) {a.appearance+=1}

// Keeps a derived row used by a visual instance outside the world's tables.
assets_material_retain :: proc(a:^Assets,row:u32) {
    if row==0 || int(row)>len(a.row_marks) {return}
    if a.row_marks[row-1]<ASSETS_ROW_FREE {a.row_marks[row-1]=a.appearance}
}

assets_appearance_end :: proc(a:^Assets) {
    for mark,at in a.row_marks {
        if mark>=ASSETS_ROW_FREE || mark==a.appearance {continue}
        delete_key(&a.derived,a.row_hashes[at])
        assets_row_free(a,u32(at)+1)
        a.stats.derived-=1
    }
}

// The row of values that are no asset: the same values give the same row.
// False when the table has no room: an error of the list, Capacity of a
// Material with no id.
assets_material_derive :: proc(a:^Assets,desc:render.Material_Desc) -> (row:u32,ok:bool) {
    values:=desc
    key:=base.hash64(mem.ptr_to_bytes(&values))
    for {
        known:=a.derived[key] or_break
        if a.material_descs[known-1]==values {
            a.row_marks[known-1]=a.appearance
            return known,true
        }
        key+=1
    }
    if row,ok=assets_row_take(a);!ok {
        assets_fail(a,{},.Material,.Capacity)
        return 0,false
    }
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    a.material_descs[row-1]=values
    a.row_marks[row-1]=a.appearance
    a.row_hashes[row-1]=key
    a.derived[key]=row
    assets_row_changed(a,row)
    a.stats.derived+=1
    return row,true
}

// The values of a row of the table; of the default material for row 0.
assets_material_values :: proc(a:^Assets,row:u32) -> render.Material_Desc {
    return row>0 && int(row)<=len(a.material_descs)?a.material_descs[row-1]:render.DEFAULT_MATERIAL
}

// The row of a material seen through an opacity: its alpha is scaled and an
// opaque material blends. Without room the material stays as it is.
assets_material_faded :: proc(a:^Assets,row:u32,alpha:f32) -> u32 {
    values:=assets_material_values(a,row)
    values.opacity*=clamp(alpha,0,1)
    if values.alpha_mode==.Opaque {values.alpha_mode=.Blend}
    faded,ok:=assets_material_derive(a,values)
    return ok?faded:row
}

// The layers a material draws over the instance that shows it: one per
// enabled overlay whose material loads, in order. A layer is the row of its
// material, or a derived row when the material that owns the overlay stores
// parameters for it.
assets_material_overlays :: proc(a:^Assets,id:base.Asset_Id) -> (layers:render.Instance_Overlays) {
    owner:=assets_material(a,id)
    if owner==nil || owner.overlay_count==0 {return}
    return assets_overlays(a,id,owner.overlays[:owner.overlay_count])
}

// Layers over a material in place of its own, as an entity gives them; the
// parameters the material stores for a layer of the same id apply to it.
assets_overlays :: proc(a:^Assets,id:base.Asset_Id,overlays:[]asset.Material_Overlay) -> (layers:render.Instance_Overlays) {
    owner:=assets_material(a,id)
    if a.renderer==nil {return}
    for overlay in overlays[:min(len(overlays),len(layers.entries))] {
        if !overlay.enabled {continue}
        material:=assets_material(a,overlay.material)
        if material==nil || material.failed {continue}
        row:=material.row
        if program:=assets_material_program(a,material,.Surface);program!=nil {
            values:=a.material_descs[row-1]
            if owner!=nil && assets_program_parameters(a,program,&values.custom_params,assets_material_parameters(a,owner),overlay.id)>0 {
                if derived,ok:=assets_material_derive(a,values);ok {row=derived}
            }
        }
        layers.entries[layers.count]={id=overlay.id,material=render.Material_Handle(row),blend=overlay.blend,enabled=true}
        layers.count+=1
    }
    return
}

// The effect of a material whose program is a PostProcess one, with the
// parameters it stores. False for any other material.
assets_postprocess :: proc(a:^Assets,id:base.Asset_Id) -> (effect:render.Postprocess_Desc,ok:bool) {
    material:=assets_material(a,id)
    if material==nil || material.failed {return}
    program:=assets_material_program(a,material,.Postprocess)
    if program==nil {return}
    effect={program=program.id,params=render.program_defaults(program),enabled=true}
    assets_program_parameters(a,program,&effect.params,assets_material_parameters(a,material),0)
    return effect,true
}

// --------------------------------------------------------------------- scenes

// The document of a scene or prefab, kept open for scene_instantiate. nil
// when it cannot be loaded.
assets_scene :: proc(a:^Assets,id:base.Asset_Id) -> ^asset.Asset {return assets_open_document(a,id,.Scene,asset.KIND_SCENE)}

// The document of an asset of a kind a plugin reads (a particle effect),
// kept open where it is as scenes are, and read again when its file changes
// (a.revision moves). nil when it cannot be loaded.
assets_document :: proc(a:^Assets,id:base.Asset_Id,kind:asset.Fourcc) -> ^asset.Asset {
    return assets_open_document(a,id,.Scene if kind==asset.KIND_SCENE else .Document,kind)
}

// A document of assets_document whose tables its plugin refuses: a problem
// of the asset, and nil from assets_document until its file changes.
assets_document_refuse :: proc(a:^Assets,id:base.Asset_Id,detail:asset.Error) {
    ref,known:=a.index[id]
    if !known || ref.kind!=.Document {return}
    assets_fail(a,id,.Document,.Corrupt,detail)
    a.scenes[ref.index].failed=true
}

// A document read where it is, as scenes are.
@(private="file")
assets_open_document :: proc(a:^Assets,id:base.Asset_Id,kind:Assets_Kind,fourcc:asset.Fourcc) -> ^asset.Asset {
    if id=={} {return nil}
    if ref,known:=a.index[id];known {
        if ref.kind==kind && (kind!=.Document || a.scenes[ref.index].kind==fourcc) {return a.scenes[ref.index].failed?nil:&a.scenes[ref.index].file}
        assets_fail(a,id,kind,.Wrong_Kind)
        return nil
    }
    at,room:=assets_slot(&a.scenes,&a.free_scenes,&a.regions[3])
    if !room {
        assets_fail(a,id,kind,.Capacity)
        return nil
    }
    entry:=&a.scenes[at]
    entry.kind=fourcc
    a.index[id]={kind,at}
    a.stats.scenes+=1
    if problem,detail,ok:=assets_open(a,id,kind,&entry.file,fourcc);!ok {
        assets_fail(a,id,kind,problem,detail)
        entry.failed=true
        return nil
    }
    return &entry.file
}

// --------------------------------------------------------------------- reload

@(private="file")
assets_materials_refresh :: proc(a:^Assets) {
    for &material in a.materials {
        if material.row!=0 {a.material_descs[material.row-1]=assets_material_desc(a,&material,material.id)}
    }
    a.materials_dirty=true
}

// Reads again an asset that is loaded and replaces it where it is. A mesh or
// a texture takes the place of the one the renderer had, which is removed;
// a material gets new values in its row. False when the id is not loaded or
// the new file cannot be loaded: the asset then stays as it was, with the
// error in the list.
//
// a.revision advances with every reload. a.structure advances, and whoever
// extracted the scene does it again, only when what the instances were
// given is no longer what they need: a mesh
// (the renderer drops its instances with it), a texture that got another
// handle, and a material whose overlays changed. A material that only has
// other values and a texture that keeps its handle change where they are:
// only its row goes to the renderer, and only when its values differ. While
// rows derived from the values of materials are in use, a material that
// changed advances a.structure with its id, and only what derives a row from
// it is asked for again.
assets_reload :: proc(a:^Assets,id:base.Asset_Id) -> bool {
    ref,known:=a.index[id]
    if !known || ref.kind==.Mesh && a.meshes[ref.index].generated || ref.kind==.Texture && a.textures[ref.index].generated {return false}
    assets_errors_forget(a,id)
    problem:Assets_Problem
    detail:asset.Error
    ok,removed,rebuild,derived:bool
    switch ref.kind {
    case .Shape:
    case .Mesh:
        entry:=&a.meshes[ref.index]
        fresh:Assets_Mesh
        problem,detail,ok=assets_mesh_load(a,id,&fresh,entry.failed?ASSETS_MESH_NONE:entry.handle,&removed)
        if ok {entry^=fresh} else if removed {entry^=assets_missing_mesh(a)^}
        rebuild=ok || removed
    case .Texture:
        entry:=&a.textures[ref.index]
        fresh:Assets_Texture
        before:=entry.handle
        problem,detail,ok=assets_texture_load(a,id,&fresh,entry.failed?0:entry.handle,&removed)
        if ok {entry^=fresh} else if removed {entry^=assets_missing_texture(a)^}
        if entry.handle!=before {
            assets_materials_refresh(a)
            rebuild=true
        }
    case .Material:
        fresh:=a.materials[ref.index]
        before:=fresh
        stored:=slice.clone(assets_material_parameters(a,&before),context.temp_allocator)
        if problem,detail,ok=assets_material_load(a,id,&fresh);ok {
            a.materials[ref.index]=fresh
            changed:=assets_material_row_update(a,&a.materials[ref.index])
            changed||=!slice.equal(stored,assets_material_parameters(a,&a.materials[ref.index]))
            rebuild=before.overlay_count!=fresh.overlay_count || before.overlays!=fresh.overlays
            derived=!rebuild && changed && a.stats.derived>0
        }
    case .Scene,.Document:
        fresh:asset.Asset
        document:=a.scenes[ref.index].kind
        if problem,detail,ok=assets_open(a,id,ref.kind,&fresh,document);ok {
            asset.asset_close(&a.scenes[ref.index].file)
            a.scenes[ref.index]={file=fresh,kind=document}
        }
    }
    if ok || removed {a.revision+=1}
    if rebuild {assets_structure_changed(a)} else if derived {assets_structure_changed(a,id)}
    assets_commit(a)
    if !ok {
        assets_fail(a,id,ref.kind,problem,detail)
        return false
    }
    a.stats.reloads+=1
    return true
}

// The shaders of the renderer were replaced: every material finds its
// program and the offsets of its parameters in the new catalog, and one
// whose program was missing is no longer in the list of errors unless it
// still is. a.revision advances.
assets_programs_refresh :: proc(a:^Assets) {
    if a.renderer==nil {return}
    #reverse for problem,i in a.errors {
        if problem.kind==.Material && problem.problem==.Unsupported {ordered_remove(&a.errors,i)}
    }
    assets_materials_refresh(a)
    a.revision+=1
    assets_structure_changed(a)
    assets_commit(a)
}

// --------------------------------------------------------------------- scopes

ASSETS_SCOPES :: 16

// Who uses the loaded assets: a scope for each scene that is open (the world
// of a session, the document of the editor). A scope says which assets its
// scene names; what those depend on is reached through them. assets_collect
// unloads what no scope reaches.
Assets_Scope :: distinct u32 // zero: none

@(private="file")
Assets_Scope_State :: struct {
    used:bool,
    owner:rawptr, // whose scope it is, for assets_scope_of; nil for one nobody asks for by owner
    ids:[dynamic]base.Asset_Id,
}

// A scope that references nothing yet. Zero when there are ASSETS_SCOPES.
assets_scope_create :: proc(a:^Assets) -> Assets_Scope {
    for &scope,at in a.scopes {
        if scope.used {continue}
        if scope.ids.allocator.procedure==nil {scope.ids=make([dynamic]base.Asset_Id,a.allocator)}
        clear(&scope.ids)
        scope.used,scope.owner=true,nil
        return Assets_Scope(at+1)
    }
    return 0
}

// The scope of an owner (a session, a document), made the first time it is asked for. Zero for nil and without room.
assets_scope_of :: proc(a:^Assets,owner:rawptr) -> Assets_Scope {
    if owner==nil {return 0}
    for scope,at in a.scopes {
        if scope.used && scope.owner==owner {return Assets_Scope(at+1)}
    }
    scope:=assets_scope_create(a)
    if scope!=0 {a.scopes[scope-1].owner=owner}
    return scope
}

// The scope an owner has; zero when it never asked for one.
assets_scope_find :: proc(a:^Assets,owner:rawptr) -> Assets_Scope {
    for scope,at in a.scopes {
        if owner!=nil && scope.used && scope.owner==owner {return Assets_Scope(at+1)}
    }
    return 0
}

// The scope is gone: what only it referenced is unloaded by the next assets_collect.
assets_scope_destroy :: proc(a:^Assets,scope:Assets_Scope) {
    if scope==0 || int(scope)>len(a.scopes) {return}
    a.scopes[scope-1].used,a.scopes[scope-1].owner=false,nil
    clear(&a.scopes[scope-1].ids)
}

// What a scope references from here on, in place of what it did. False for a
// scope that does not exist and without memory: it then references nothing.
assets_scope_set :: proc(a:^Assets,scope:Assets_Scope,ids:[]base.Asset_Id) -> bool {
    if scope==0 || int(scope)>len(a.scopes) || !a.scopes[scope-1].used {return false}
    state:=&a.scopes[scope-1]
    clear(&state.ids)
    if _,error:=append(&state.ids,..ids);error!=nil {
        clear(&state.ids)
        return false
    }
    return true
}

// The assets a scope was given, as it holds them.
assets_scope_ids :: proc(a:^Assets,scope:Assets_Scope) -> []base.Asset_Id {
    if scope==0 || int(scope)>len(a.scopes) || !a.scopes[scope-1].used {return nil}
    return a.scopes[scope-1].ids[:]
}

// Whether the asset is loaded: something asked for it and it was not unloaded since.
assets_loaded :: proc(a:^Assets,id:base.Asset_Id) -> bool {
    _,known:=a.index[id]
    return known
}

// Unloads every loaded asset that no scope reaches: the ones no scope
// references and that nothing a scope references depends on, by the
// dependencies their files declare. Meshes and textures leave the renderer,
// materials give back their rows and scenes are closed. Shapes, generated
// meshes and the stand-ins stay. A transaction between frames: a.revision
// and a.structure advance when anything was unloaded, and whoever extracted
// the scene does it again.
// Returns how many assets it unloaded.
assets_collect :: proc(a:^Assets) -> (unloaded:int) {
    keep:=assets_reached(a,context.temp_allocator)
    gone:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for id,ref in a.index {
        if keep[id] || ref.kind==.Shape || ref.kind==.Mesh && a.meshes[ref.index].generated || ref.kind==.Texture && a.textures[ref.index].generated {continue}
        append(&gone,id)
    }
    if len(gone)==0 {return 0}
    return assets_unload(a,gone[:])
}

// What the scopes reach: the assets they reference and everything those depend on.
@(private)
assets_reached :: proc(a:^Assets,allocator:=context.temp_allocator) -> map[base.Asset_Id]bool {
    keep:=make(map[base.Asset_Id]bool,allocator)
    pending:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for &scope in a.scopes {
        if !scope.used {continue}
        for id in scope.ids {
            if id!={} && !keep[id] {
                keep[id]=true
                append(&pending,id)
            }
        }
    }
    for len(pending)>0 {
        file,found:=asset.registry_find(&a.registry,pop(&pending))
        if !found {continue}
        for needed in asset.registry_dependencies(&a.registry,file) {
            if needed!={} && !keep[needed] {
                keep[needed]=true
                append(&pending,needed)
            }
        }
    }
    return keep
}

@(private="file")
assets_unload :: proc(a:^Assets,gone:[]base.Asset_Id) -> int {
    materials:=false
    for id in gone {
        ref:=a.index[id]
        switch ref.kind {
        case .Shape:
        case .Mesh:
            entry:=&a.meshes[ref.index]
            // A failed entry shows the stand-in, which is not its own.
            if !entry.failed && a.renderer!=nil && entry.handle!=ASSETS_MESH_NONE {render.mesh_remove(a.renderer,entry.handle)}
            entry^={handle=ASSETS_MESH_NONE}
            append(&a.free_meshes,ref.index)
            a.stats.meshes-=1
        case .Texture:
            entry:=&a.textures[ref.index]
            if !entry.failed && a.renderer!=nil && entry.handle!=0 {render.texture_remove(a.renderer,entry.handle)}
            entry^={}
            append(&a.free_textures,ref.index)
            a.stats.textures-=1
        case .Material:
            entry:=&a.materials[ref.index]
            a.material_descs[entry.row-1]={}
            assets_row_free(a,entry.row)
            entry^={}
            append(&a.free_materials,ref.index)
            a.stats.materials-=1
            materials=true
        case .Scene,.Document:
            asset.asset_close(&a.scenes[ref.index].file)
            a.scenes[ref.index]={}
            append(&a.free_scenes,ref.index)
            a.stats.scenes-=1
        }
        delete_key(&a.index,id)
        assets_errors_forget(a,id)
    }
    if materials {
        // The parameters of the materials that remain, one run after another;
        // without memory for it they stay where they are.
        if kept,error:=make([dynamic]asset.Material_Parameter,0,len(a.parameters),a.allocator);error==nil {
            for &material in a.materials {
                if material.row==0 {continue}
                first:=u32(len(kept))
                append(&kept,..assets_material_parameters(a,&material))
                material.first_parameter,material.parameter_room=first,material.parameter_count
            }
            delete(a.parameters)
            a.parameters=kept
        }
    }
    a.stats.unloads+=len(gone)
    a.materials_dirty=true
    a.revision+=1
    assets_structure_changed(a)
    assets_commit(a)
    return len(gone)
}

// Loads again the loaded textures that the limits the renderer has now
// (texture_limits, the pool) change, from those of before: a change of them
// reaches the textures already in use. One no larger than both sizes keeps
// its levels, unless the pool shrank or it left levels out and the pool
// grew. The smallest are loaded first, so that the pool keeps the largest
// levels of the most of them.
assets_textures_reload :: proc(a:^Assets,before:render.Settings) {
    r:=a.renderer
    if r==nil {return}
    was,now:=render.texture_limits_of(r,before),render.texture_limits(r)
    pool :: proc "contextless" (megabytes:u32) -> u64 {return megabytes==0?max(u64):u64(megabytes)}
    all:=pool(r.settings.texture_pool_megabytes)<pool(before.texture_pool_megabytes)
    grown:=pool(r.settings.texture_pool_megabytes)>pool(before.texture_pool_megabytes)
    side:=min(was.max_size,now.max_size)
    Loaded :: struct {id:base.Asset_Id,index:u32,bytes:u64}
    loaded:=make([dynamic]Loaded,context.temp_allocator)
    for id,ref in a.index {
        if ref.kind!=.Texture {continue}
        texture:=&a.textures[ref.index]
        if texture.failed || texture.generated || texture.handle==0 {continue}
        bytes,reduced:=render.texture_stored(r,texture.handle)
        if !all && int(max(texture.width,texture.height))<=side && !(grown && reduced) {continue}
        append(&loaded,Loaded{id,ref.index,bytes})
    }
    if len(loaded)==0 {return}
    slice.sort_by(loaded[:],proc(x,y:Loaded) -> bool {return x.bytes<y.bytes || x.bytes==y.bytes && (x.id[0]<y.id[0] || x.id[0]==y.id[0] && x.id[1]<y.id[1])})
    // Their levels go back to the pool before any of them takes new ones.
    for texture in loaded {
        render.texture_remove(r,a.textures[texture.index].handle)
        a.textures[texture.index].handle=0
    }
    for texture in loaded {
        entry:=&a.textures[texture.index]
        fresh:Assets_Texture
        if problem,detail,ok:=assets_texture_load(a,texture.id,&fresh);ok {
            entry^=fresh
        } else {
            entry^=assets_missing_texture(a)^
            assets_fail(a,texture.id,.Texture,problem,detail)
        }
    }
    assets_materials_refresh(a)
    a.revision+=1
    assets_structure_changed(a)
    assets_commit(a)
}
