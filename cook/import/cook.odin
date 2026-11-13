package importer

import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/jobs"

// What writing a model costs most is built apart from writing it: the
// levels and clusters of each mesh and the levels of each
// texture. model_cook builds them ahead, in parallel on the job system of the
// import, and the writer takes them; what was not built ahead, the writer
// builds when it gets to it. Either way they are the same bytes. An import
// whose files of the cache are current builds nothing (writer_current).
//
// The meshes built are kept by what they are made from in the mesh cache of
// the project (Import_Options.mesh_cache, cook/cache), as textures are in the
// texture cache: building the same geometry with the same settings again
// reads it.

// The version of what builds a mesh: its file of the cache is built again
// when the writer, the format of .mesh or the key of its settings change.
MESH_CACHE_VERSION :: u64(MESH_SETTINGS_KEY)<<32|u64(IMPORTER_VERSION)<<16|u64(asset.MESH_VERSION)
@(private="file")
MESH_SETTINGS_KEY :: 3 // raise it when mesh_settings_hash hashes otherwise

Cook_Failure :: enum u8 {
    None,
    Not_Finite, // a position or texture coordinate is NaN or infinite
    Clusters,   // no memory for its clusters, or more than a .mesh holds
}

// A mesh built for the settings whose mesh_settings_hash is settings. Its
// memory is its arena.
Cooked_Mesh :: struct {
    settings:u64,
    content:u64, // mesh_content_hash of what it was built from
    failure:Cook_Failure,
    geometry:asset.Mesh_Geometry,
    collision:Mesh_Collision, // the colliders of the source, as it gives them
    arena:mem.Dynamic_Arena,
}

// A texture built for the options whose settings_hash is settings, from an
// image of size and hash. Its memory is its arena.
Cooked_Texture :: struct {
    settings:u64,
    size,hash:u64,
    built:textures.Built,
    error:textures.Error,
    arena:mem.Dynamic_Arena,
}

// The settings a model is written with: those kept with its source, unless
// the options say to ignore them.
model_settings :: proc(model:^Imported_Model,options:Import_Options) -> Import_Settings {
    if model.stored && !options.ignore_stored {return model.settings}
    return options.settings
}

// The options a texture of an image is built with.
image_build_options :: proc(image:Imported_Image,settings:Import_Settings) -> textures.Build_Options {
    return {srgb=image.srgb,normal_map=image.normal_map,green_down=image.green_down,alpha_coverage=image.alpha_cutoff,keep_precision=image.keep_precision,encoding=settings.textures,rdo_lambda=settings.rdo_lambda,channels=image.channels}
}

// What a mesh is built with: the settings of its levels and the version of
// what builds it. What its Import_Info records as its settings.
mesh_build_hash :: proc(settings:Import_Settings) -> u64 {
    return base.hash_combine(mesh_settings_hash(settings),MESH_CACHE_VERSION)
}

// The mesh as the reader gives it: vertices, indices, skin, submeshes, morph
// targets, colliders and flags.
mesh_content_hash :: proc(mesh:^Imported_Mesh) -> u64 {
    key:=base.hash64(mem.slice_to_bytes(mesh.vertices))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.indices)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.skin)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.submeshes)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.morphs)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.morph_deltas)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.collision.colliders)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.collision.points)))
    key=base.hash_combine(key,base.hash64(mem.slice_to_bytes(mesh.collision.indices)))
    flags:=mesh.flags
    return base.hash_combine(key,base.hash64(mem.ptr_to_bytes(&flags)))
}

// What a mesh is made from: its content as read (mesh_content_hash) and what
// it is built with (mesh_build_hash).
mesh_cache_key :: proc(content:u64,settings:Import_Settings) -> u64 {
    return base.hash_combine(mesh_build_hash(settings),content)|1
}

// Builds the levels and clusters of a mesh, or reads them from the mesh
// cache, into the arena of cooked. options gives the cache, rebuild
// and the worker it runs on.
mesh_cook :: proc(mesh:^Imported_Mesh,settings:Import_Settings,options:Import_Options,cooked:^Cooked_Mesh,parent:mem.Allocator) {
    mem.dynamic_arena_init(&cooked.arena,parent,parent,block_size=1<<20,out_band_size=1<<20)
    allocator:=base.dynamic_arena_allocator(&cooked.arena)
    cooked.settings=mesh_settings_hash(settings)
    cooked.content=mesh_content_hash(mesh)
    if !asset.vertices_finite({vertices=mesh.vertices,flags=mesh.flags}) {cooked.failure=.Not_Finite;return}
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    folder:=options.mesh_cache
    key:u64
    if folder!="" {
        key=mesh_cache_key(cooked.content,settings)
        file:asset.Asset
        if !options.rebuild && cache.load(folder,key,MESH_CACHE_VERSION,".mesh",&file,allocator) {
            if view,error:=asset.mesh_view(&file,&types);error==.None {
                cooked.geometry=view.geometry
                cooked.collision={view.colliders,view.collision_points,view.collision_indices}
                return
            }
        }
    }
    levels_zone:=jobs.worker_zone_begin(options.worker,"mesh.levels")
    levels:=mesh_levels(mesh.vertices,mesh.indices,mesh.skin,mesh.submeshes,settings.lods==.Auto,context.temp_allocator,mesh.morphs,mesh.morph_deltas)
    base.profile_end(levels_zone)
    cooked.collision={slice.clone(mesh.collision.colliders,allocator),slice.clone(mesh.collision.points,allocator),slice.clone(mesh.collision.indices,allocator)}
    clusters_zone:=jobs.worker_zone_begin(options.worker,"mesh.clusters")
    clustered:=levels_geometry(levels,mesh.flags,&cooked.geometry,allocator)
    base.profile_end(clusters_zone)
    if !clustered {cooked.failure=.Clusters;return}
    if folder!="" && cache.ready(folder) {
        // The slots of the file of the cache name no material: an import names its own.
        slots:=make([]asset.Material_Slot,len(mesh.slots),context.temp_allocator)
        for slot,at in mesh.slots {slots[at].id=slot.id}
        desc:=asset.Mesh_Desc{
            id=cache.id(key,MESH_CACHE_VERSION),geometry=cooked.geometry,slots=slots,joints=mesh.joints,
            colliders=cooked.collision.colliders,collision_points=cooked.collision.points,collision_indices=cooked.collision.indices,
        }
        if asset.mesh_save(cache.file_path(folder,key,".mesh"),&types,desc)==.None {cache.written(folder)}
    }
}

// Builds the levels of a texture, or reads them from the texture cache, into
// the arena of cooked. bytes are the encoded image, the texels of made when
// its width is not 0, or what make makes the texels of; decoded, when given,
// the RGBA8 pixels of encoded bytes that were decoded already, which an image
// of more than 8 bits does not build from.
texture_cook :: proc(bytes:[]u8,made:textures.Source,decoded:textures.Image,build:textures.Build_Options,options:Import_Options,cooked:^Cooked_Texture,parent:mem.Allocator,make:Image_Make=nil) {
    build:=build
    mem.dynamic_arena_init(&cooked.arena,parent,parent,block_size=1<<20,out_band_size=1<<20)
    allocator:=base.dynamic_arena_allocator(&cooked.arena)
    cooked.settings=textures.settings_hash(build)
    cooked.size,cooked.hash=u64(len(bytes)),base.hash64(bytes)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    // The same image with the same settings, built before by any import, is read from the cache.
    folder:=options.texture_cache
    key:u64
    if folder!="" {
        key=textures.cache_key_build(bytes,made,build)
        if !options.rebuild {
            if built,cached:=textures.cache_read(folder,key,&types,allocator);cached {cooked.built=built;return}
        }
    }
    if options.fast_textures {
        build.speed=.Fast
        cooked.settings=textures.settings_hash(build)
        if folder!="" {
            key=textures.cache_key_build(bytes,made,build)
            if !options.rebuild {
                if built,cached:=textures.cache_read(folder,key,&types,allocator);cached {cooked.built=built;return}
            }
        }
    }
    jobs.worker_zone(options.worker,"texture.build")
    switch {
    case make!=nil && decoded.pixels!=nil:
        cooked.built,cooked.error=textures.build(textures.rgba8(decoded.pixels,decoded.width,decoded.height),build,allocator,options.worker)
    case make!=nil:
        source,ok:=make(bytes,context.temp_allocator)
        if !ok {cooked.error=.Unsupported;return}
        cooked.built,cooked.error=textures.build(source,build,allocator,options.worker)
    case made.width>0:
        cooked.built,cooked.error=textures.build(made,build,allocator,options.worker)
    case decoded.pixels!=nil && !textures.source_wide(bytes):
        cooked.built,cooked.error=textures.build(textures.rgba8(decoded.pixels,decoded.width,decoded.height),build,allocator,options.worker)
    case:
        cooked.built,cooked.error=textures.from_bytes(bytes,build,allocator,options.worker)
    }
    if cooked.error==.None {textures.cache_write(folder,key,&types,&cooked.built)}
}

// The settings hash of a texture of build built Fast.
@(private)
fast_settings :: proc(build:textures.Build_Options) -> u64 {
    fast:=build
    fast.speed=.Fast
    return textures.settings_hash(fast)
}

// The bytes a texture of an image is built from: the image file, the encoded
// image inside the source, what the format makes the texels of (Image_Make)
// or the texels the format made (made, of width above 0). In the temp
// allocator.
@(private)
image_bytes :: proc(image:Imported_Image) -> (bytes:[]u8,made:textures.Source,ok:bool) {
    if image.path!="" {
        data,error:=read_whole(image.path)
        return data,{},error==.None
    }
    if image.made.width>0 {return image.made.texels,image.made,true}
    return image.data,{},true
}

// Builds ahead the meshes and textures of a model that were not built for
// the same settings, but those whose file the writer keeps (kept, by row of
// the meshes and of the images; nil, none), each a job of the job
// system of options.worker (or one after the other without one). Their
// arenas take their memory from that system, which any thread can call, or
// from the allocator of the model.
model_cook :: proc(model:^Imported_Model,options:Import_Options,kept_meshes:[]bool=nil,kept_images:[]bool=nil) {
    settings:=model_settings(model,options)
    mesh_settings:=mesh_settings_hash(settings)
    Item :: struct {mesh,image:int}
    items:=make([dynamic]Item,context.temp_allocator)
    for &mesh,i in model.meshes {
        if i<len(kept_meshes) && kept_meshes[i] || mesh.cooked!=nil && mesh.cooked.settings==mesh_settings {continue}
        append(&items,Item{i,-1})
    }
    for &image,i in model.images {
        if i<len(kept_images) && kept_images[i] {continue}
        build:=image_build_options(image,settings)
        if image.cooked!=nil && (image.cooked.settings==textures.settings_hash(build) || options.fast_textures && image.cooked.settings==fast_settings(build)) {continue}
        // An image file that cannot be read is the writer's to tell.
        if _,_,ok:=image_bytes(image);!ok {continue}
        append(&items,Item{-1,i})
    }
    if len(items)==0 {return}
    // The results live in the model, in memory of the caller's thread; each item writes only its own.
    holder:=base.dynamic_arena_allocator(model.arena) if model.arena!=nil else context.temp_allocator
    for item in items {
        if item.mesh>=0 {
            mesh:=&model.meshes[item.mesh]
            if mesh.cooked!=nil {cooked_mesh_destroy(mesh.cooked)} else {mesh.cooked=new(Cooked_Mesh,holder)}
        } else {
            image:=&model.images[item.image]
            if image.cooked!=nil {cooked_texture_destroy(image.cooked)} else {image.cooked=new(Cooked_Texture,holder)}
        }
    }
    Cook :: struct {model:^Imported_Model,items:[]Item,settings:Import_Settings,options:Import_Options,parent:mem.Allocator}
    work:=Cook{model,items[:],settings,options,model.allocator if model.arena!=nil else context.allocator}
    run :: proc(work:^Cook,first,last:int,worker:int) {
        options:=work.options
        options.worker=jobs.worker_ref_at(options.worker,worker)
        // On a job system, what nothing names an allocator for comes from the one every thread can call.
        if js:=options.worker.system;js!=nil {context.allocator=js.allocator}
        for item in work.items[first:last] {
            if item.mesh>=0 {
                mesh:=&work.model.meshes[item.mesh]
                mesh_cook(mesh,work.settings,options,mesh.cooked,work.parent)
            } else {
                image:=work.model.images[item.image]
                bytes,made,_:=image_bytes(image)
                texture_cook(bytes,made,{},image_build_options(image,work.settings),options,image.cooked,work.parent,image.make)
            }
        }
    }
    if js:=options.worker.system;js!=nil {
        work.parent=js.allocator
        jobs.parallel_for(js,options.worker.worker,len(items),1,run,&work)
    } else {
        run(&work,0,len(items),options.worker.worker)
    }
}

cooked_mesh_destroy :: proc(cooked:^Cooked_Mesh) {
    mem.dynamic_arena_destroy(&cooked.arena)
    cooked^={}
}

cooked_texture_destroy :: proc(cooked:^Cooked_Texture) {
    mem.dynamic_arena_destroy(&cooked.arena)
    cooked^={}
}

// The meshes and textures built for a model, their memory let go.
model_cooked_destroy :: proc(model:^Imported_Model) {
    for &mesh in model.meshes {
        if mesh.cooked!=nil {cooked_mesh_destroy(mesh.cooked);mesh.cooked=nil}
    }
    for &image in model.images {
        if image.cooked!=nil {cooked_texture_destroy(image.cooked);image.cooked=nil}
    }
}
