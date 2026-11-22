package importer

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:project"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:store"

Written :: struct {
    id:base.Asset_Id,
    kind:asset.Fourcc,
    name:string,
    path:string,   // for a document, its file in the folder of the documents; "" for an object of the store alone
    object:store.Hash,
    source:string, // the source as imports name it
    bytes:int,
    detail:string, // what it holds, for a report: levels and colliders of a mesh, format and size of a texture
    kept:bool,     // an object the store had was taken: nothing was built
}

// Opens what an import wrote: a document from its file, an output of the
// cache from its object of s.
written_open :: proc(s:^store.Store,w:Written,a:^asset.Asset,allocator:=context.allocator) -> asset.Error {
    if w.path!="" {return asset.asset_load(a,w.path,allocator)}
    return asset.asset_open_object(a,s,w.object,allocator)
}

Import_Report :: struct {
    assets:[dynamic]Written,
    warnings:[dynamic]string,
    programs:[dynamic]string, // programs the editor publishes after importing
    // The asset of each mesh, material and image of the model, by row; zero for an image that was not written.
    mesh_ids,material_ids,image_ids,skeleton_ids:[]base.Asset_Id,
    animation_id:base.Asset_Id,
    // The prefab of a model, the owner its parts name: the id the previous
    // manifest lists, else a new one, and the file it is written to: in the
    // folder of the documents (none without one), or for Outputs the file
    // output_written takes. Zero for a model without nodes that had no
    // prefab. import_source writes it, with prefab_info.
    prefab:base.Asset_Id,
    prefab_path:string,
    prefab_info:asset.Import_Info,
    settings:Import_Settings, // what the source was imported with: what its package keeps
    // What the project's file of each document the import writes over in
    // Import_Options.documents holds as it leaves it: the pin records it.
    written:[dynamic]asset.Package_Written,
    // The package the import wrote: its id, the hash of its manifest, its
    // build, the key of the build and whether its textures are Final.
    package_id:base.Asset_Id,
    manifest,build,key:store.Hash,
    final:bool,
    allocator:mem.Allocator,
}

report_destroy :: proc(report:^Import_Report) {
    for written in report.assets {
        delete(written.name,report.allocator)
        delete(written.path,report.allocator)
        delete(written.source,report.allocator)
        delete(written.detail,report.allocator)
    }
    for warning in report.warnings {delete(warning,report.allocator)}
    for program in report.programs {delete(program,report.allocator)}
    delete(report.assets)
    delete(report.warnings)
    delete(report.programs)
    delete(report.written)
    delete(report.mesh_ids,report.allocator)
    delete(report.material_ids,report.allocator)
    delete(report.image_ids,report.allocator)
    delete(report.skeleton_ids,report.allocator)
    delete(report.prefab_path,report.allocator)
    report^={}
}

// A report whose lists live in allocator.
report_init :: proc(report:^Import_Report,allocator:=context.allocator) {
    report.allocator=allocator
    report.assets.allocator=allocator
    report.warnings.allocator=allocator
    report.programs.allocator=allocator
    report.written.allocator=allocator
}

// Moves what src lists (assets, warnings, programs and what was written) to the end of dst and
// destroys src; both live in the same allocator.
report_take :: proc(dst,src:^Import_Report) {
    append(&dst.assets,..src.assets[:])
    append(&dst.warnings,..src.warnings[:])
    append(&dst.programs,..src.programs[:])
    append(&dst.written,..src.written[:])
    clear(&src.assets);clear(&src.warnings);clear(&src.programs);clear(&src.written)
    report_destroy(src)
}

// A source path as imports name it, relative to its package: the name of its
// file, the same on every machine.
source_path :: proc(path:string,allocator:=context.temp_allocator) -> string {
    return strings.clone(filepath.base(path_key(path)),allocator)
}

@(private)
read_whole :: proc(path:string) -> ([]u8,serial.File_Error) {
    if unsafe_path(path) {return nil,.Not_Found}
    return serial.file_read(path,context.temp_allocator,limit=MAX_SOURCE_BYTES)
}

@(private)
Writer :: struct {
    options:Import_Options,
    gpu:textures.Gpu_Context,
    folder:string,               // where new documents go: under the folder of the documents; "": none are written there
    documents:string,            // under the folder of the documents, where new ones go (asset.Package.documents)
    catalog_path:string,
    registry:^asset.Registry,    // the assets of the root, where documents are found by id; nil without a folder of the documents
    types:asset.Types,
    report:^Import_Report,
    created:[dynamic]string,     // the documents the import wrote that were not there
    names:map[string]bool,       // files of the folder new parts took, in lower case
    path:string,                 // the source
    origin:string,               // the source as an absolute path with forward slashes
    source:string,               // the source as imports name it (source_path)
    previous:asset.Package,      // the manifest the source was ingested as, when stored
    previous_manifest:store.Hash,
    stored:bool,
    package_id:base.Asset_Id,
    taken:[]bool,                // the assets of previous the import gives again
    outputs:[dynamic]asset.Package_Asset, // what the import gives: the assets of the manifest it writes
    paths:[dynamic]string,       // the scratch file of each of outputs
    targets:[dynamic]string,     // the file of each document of outputs in the folder of the documents; "": none
    objects:[dynamic]store.Hash, // the object of each of outputs once the store took it; zero: none
    programs:map[store.Hash]struct{},
    followed:[dynamic]Followed_Skeleton, // the baselines of the skeletons taken, which clips follow onto
    scratch:string,              // the folder parts are written in before the store takes them
    version:u32,                 // import_version of what reads the source
    inputs:[dynamic]string,      // the files read besides the source, as the manifest lists them (writer_input)
    fixed:bool,                  // identity and key are fixed (writer_identity): inputs are whole
    identity,key:store.Hash,
    candidates:[dynamic]Candidate, // the builds outputs may be taken from (writer_candidates)
    candidates_read:bool,
    fast:bool,                   // a texture taken or built is Fast
    owner:base.Asset_Id,         // of the parts: the prefab of a model
    whole:bool,                  // writes a model for Outputs: its prefab and clips are parts by their names
    given:int,                   // of outputs, those a part of the same kind and name is (parts_plan)
    keeping:map[base.Asset_Id]u64, // the documents changed since the import wrote them that it leaves as they are (Changed.Keep), with what the pin recorded of each
    rng:base.Rng,
    allocator:mem.Allocator,
    keep:mem.Allocator,          // what lives as long as the writer: the temp allocator it began in
    error:Error,
}

// A build of the package this machine has, whose objects an import takes.
@(private)
Candidate :: struct {
    build:asset.Build,
    current:bool, // of what the import is made from now (its key)
}

// The message goes to the allocator of the writer: the temp one where the
// failure happens may be the one that ran out of memory.
@(private)
writer_fail :: proc(w:^Writer,code:Error_Code,format:string,args:..any) -> bool {
    if w.error.code==.None {w.error=error_make(code,format,..args,allocator=w.allocator)}
    return false
}

// The failure of the writer, its message moved to allocator.
@(private)
writer_error :: proc(w:^Writer,allocator:mem.Allocator) -> Error {
    error:=Error{w.error.code,fmt.aprintf("%s",w.error.message,allocator=allocator)}
    delete(w.error.message,w.allocator)
    w.error.message=""
    return error
}

@(private)
writer_warn :: proc(w:^Writer,format:string,args:..any) {
    append(&w.report.warnings,fmt.aprintf(format,..args,allocator=w.allocator))
}

// Lists an output the store took in the report.
@(private)
record :: proc(w:^Writer,output:int,name:string,detail:="",kept:=false) {
    o:=w.outputs[output]
    path:=w.targets[output]
    size:int
    if path!="" {
        if info,error:=os.stat(path,context.temp_allocator);error==nil {size=int(info.size)}
    } else {
        dependencies:=make([dynamic]base.Asset_Id,context.temp_allocator)
        if header,error:=asset.object_header(w.options.store,w.objects[output],&dependencies);error==.None {size=int(header.total_size)}
    }
    clone,_:=strings.clone(path,w.allocator)
    named,_:=strings.clone(name,w.allocator)
    from,_:=strings.clone(w.source,w.allocator)
    described,_:=strings.clone(detail,w.allocator)
    append(&w.report.assets,Written{id=o.id,kind=o.kind,name=named,path=clone,object=w.objects[output],source=from,bytes=size,detail=described,kept=kept})
    progress_written(w.options.progress,len(w.previous.assets))
}

@(private)
save_failed :: proc(w:^Writer,error:asset.Error,path:string) -> bool {
    return writer_fail(w,.Write,"%s could not be written: %v",path,error)
}

@(private)
import_info :: proc(source:string,name:string,index:int,size:u64,hash:u64,settings:u64,version:u32) -> asset.Import_Info {
    info:=asset.Import_Info{index=i32(index),source_size=size,source_hash=hash,importer_version=version,settings_hash=settings}
    asset.text_set(info.source[:],source)
    asset.text_set(info.name[:],name)
    asset.text_set(info.importer[:],IMPORTER_NAME)
    return info
}

// Reads the builds outputs may be taken from: that of what the import is made
// from now (which fixes it), Final and Fast; and the one this machine chose
// for the previous manifest. A Final import can reuse the meshes of a Fast build.
// Read before any writer_reuse, on the writer's thread.
@(private)
writer_candidates :: proc(w:^Writer) {
    if w.candidates_read {return}
    w.candidates_read=true
    w.candidates.allocator=w.keep
    writer_identity(w)
    s:=w.options.store
    digits:[64]u8
    take :: proc(w:^Writer,s:^store.Store,namespace,name:string,current:bool) {
        hash,error:=store.ref_get(s,namespace,name)
        if error!=.None {return}
        b,read_error:=asset.build_get(s,hash,w.keep)
        if read_error==.None && b.package_id==w.package_id {append(&w.candidates,Candidate{b,current})}
    }
    take(w,s,asset.REF_IMPORTS,store.hex(w.key,&digits),true)
    take(w,s,asset.REF_IMPORTS_FAST,store.hex(w.key,&digits),w.options.fast_textures)
    if w.stored {take(w,s,asset.REF_BUILDS,store.hex(asset.build_select(w.previous_manifest,&w.previous),&digits),false)}
}

// The object of a build of the package (writer_candidates) for the output id,
// to take without building it: of kind in the version it is written in now,
// with owner, and made from one of expected, which records what decides its
// bytes beyond the key (the image of a texture and its encoders, the mesh as
// read and what builds it). Never with rebuild. Reads what it is given only:
// any thread, with types of its own.
@(private)
writer_reuse :: proc(w:^Writer,types:^asset.Types,id:base.Asset_Id,kind:asset.Fourcc,owner:base.Asset_Id,expected:..asset.Import_Info) -> (hash:store.Hash,info:asset.Import_Info,found:bool) {
    if w.options.rebuild {return}
    known,_:=asset.kind_info(kind)
    for &c in w.candidates {
        for o in c.build.outputs {
            if o.id!=id || o.kind!=kind || o.kind_version!=known.version {continue}
            header,recorded,imported,error:=asset.object_peek(w.options.store,o.object,types)
            if error!=.None || !imported || header.kind!=kind || header.owner!=owner || !slice.contains(expected,recorded) {continue}
            return o.object,recorded,true
        }
    }
    return
}

// The object a texture had, built from the same image with the same settings and
// encoders (Import_Info.settings_hash): Final, or Fast for an import of fast
// textures while the texture cache holds no Final of it.
@(private="file")
texture_reuse :: proc(w:^Writer,types:^asset.Types,job:Texture_Job,id,owner:base.Asset_Id,source:string) -> (hash:store.Hash,found:bool) {
    options:=texture_options(w,job)
    final:=import_info(source,job.name,job.index,job.size,job.hash,textures.settings_hash(options),job.version)
    quick:=final
    if w.options.fast_textures && !textures.cache_has(import_cache(w.options),textures.cache_key_build(job.bytes,job.made,options)) {quick.settings_hash=fast_settings(options)}
    hash,_,found=writer_reuse(w,types,id,asset.KIND_TEXTURE,owner,final,quick)
    return
}

// The slots of a mesh as its file stores them, naming the materials by row; in
// the temp allocator.
@(private="file")
mesh_slots :: proc(mesh:^Imported_Mesh,material_ids:[]base.Asset_Id) -> []asset.Material_Slot {
    slots:=make([]asset.Material_Slot,len(mesh.slots),context.temp_allocator)
    for slot,at in mesh.slots {
        slots[at].id=slot.id
        asset.text_set(slots[at].label[:],slot.label)
        if slot.material>=0 {slots[at].material=material_ids[slot.material]}
    }
    return slots
}

// What the Import_Info of a mesh records: as its source, the mesh as read
// (content, mesh_content_hash) with its slots, joints and skeleton, and the
// bytes of its vertices and indices as its size; as its settings, what
// builds it (mesh_build_hash).
@(private="file")
mesh_info :: proc(source:string,mesh:^Imported_Mesh,index:int,content:u64,slots:[]asset.Material_Slot,skeleton:base.Asset_Id,settings:Import_Settings,version:u32) -> asset.Import_Info {
    hash:=base.hash_combine(content,base.hash64(mem.slice_to_bytes(slots)))
    hash=base.hash_combine(hash,base.hash64(mem.slice_to_bytes(mesh.joints)))
    skeleton:=skeleton
    hash=base.hash_combine(hash,base.hash64(mem.ptr_to_bytes(&skeleton)))
    size:=u64(len(mesh.vertices)*size_of(asset.Vertex)+len(mesh.indices)*size_of(u32))
    return import_info(source,mesh.name,index,size,hash,mesh_build_hash(settings),version)
}

// What the source gives a material, its maps naming the textures of the
// images by row.
@(private)
material_given :: proc(material:^Imported_Material,image_ids:[]base.Asset_Id) -> asset.Material_Info {
    info:=material.info
    for slot in asset.Material_Map_Kind {
        if row:=material.images[slot];row>=0 {material_map(&info,slot).texture=image_ids[row]}
    }
    return info
}

// The parameters the source gives a material, their textures named by the
// images by row; in the temp allocator.
@(private)
material_given_parameters :: proc(material:^Imported_Material,image_ids:[]base.Asset_Id) -> []asset.Material_Parameter {
    parameters:=make([]asset.Material_Parameter,len(material.parameters),context.temp_allocator)
    for parameter,i in material.parameters {
        parameters[i]=parameter
        parameters[i].overlay=0
        if i<len(material.parameter_images) && material.parameter_images[i]>=0 {parameters[i].texture=image_ids[material.parameter_images[i]]}
    }
    return parameters
}

@(private)
Texture_Job :: struct {
    name:string,
    bytes:[]u8,       // encoded, or the texels of an image the format made
    made:textures.Source,   // of those texels; width 0 for an encoded image
    decoded:textures.Image, // the RGBA8 pixels of an encoded image, once a verdict read them (job_pixels)
    make:Image_Make,        // of an image only its format decodes
    size:u64,
    hash:u64,
    srgb,normal_map,green_down,keep_precision:bool,
    alpha_cutoff:f32,
    alpha_fill:f32,
    channels:textures.Channels,
    index:int,
    version:u32,
    cooked:^Cooked_Texture,        // built ahead (model_cook); nil when not
}

@(private)
texture_options :: proc(w:^Writer,job:Texture_Job) -> textures.Build_Options {
    return image_build_options({srgb=job.srgb,normal_map=job.normal_map,green_down=job.green_down,alpha_cutoff=job.alpha_cutoff,alpha_fill=job.alpha_fill,keep_precision=job.keep_precision,channels=job.channels},w.options.settings)
}

// Builds one texture of source as the asset id at path, or takes the object it
// had, and puts it in the store as output; false when the image cannot be
// turned into one (a warning says why) or the store does not take it (the
// writer failed).
@(private)
write_texture :: proc(w:^Writer,job:Texture_Job,id,owner:base.Asset_Id,path,source:string,output:int) -> bool {
    writer_candidates(w)
    return texture_written(w,job,texture_write(w,job,id,owner,path,source,w.options.worker),output)
}

// What building and saving a texture gave, for its writer to record.
@(private)
Texture_Write :: struct {
    kept:bool,       // an object of a build was taken (hash)
    hash:store.Hash,
    fast:bool,       // its blocks are Fast
    format:asset.Texture_Format,
    width,height,mips:int,
    built:textures.Error,
    saved:asset.Error,
}

// Builds and saves a texture as write_texture does, or finds the object to take
// (writer_reuse), without changing w: on worker, so that the textures of a
// model are written on the job system at once.
@(private)
texture_write :: proc(w:^Writer,job:Texture_Job,id,owner:base.Asset_Id,path,source:string,worker:jobs.Worker_Ref) -> (out:Texture_Write) {
    import_options:=w.options
    import_options.worker=worker
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    options:=texture_options(w,job)
    info:=import_info(source,job.name,job.index,job.size,job.hash,textures.settings_hash(options),job.version)
    if hash,found:=texture_reuse(w,&types,job,id,owner,source);found {
        file:asset.Asset
        if asset.asset_open_object(&file,w.options.store,hash,context.temp_allocator)==.None {
            defer asset.asset_close(&file)
            if view,error:=asset.texture_view(&file,&types);error==.None {
                return {kept=true,hash=hash,fast=.Fast in view.info.flags,format=view.info.format,width=int(view.info.width),height=int(view.info.height),mips=len(view.mips)}
            }
        }
    }
    cooked:=job.cooked
    own:Cooked_Texture
    if cooked==nil || cooked.settings!=info.settings_hash && (!w.options.fast_textures || cooked.settings!=fast_settings(options)) || cooked.size!=job.size || cooked.hash!=job.hash {
        texture_cook(job.bytes,job.made,job.decoded,options,import_options,&own,context.temp_allocator,job.make)
        cooked=&own
    }
    defer if cooked==&own {cooked_texture_destroy(&own)}
    out.built=cooked.error
    if cooked.error!=.None {return}
    built:=&cooked.built
    out.fast=.Fast in built.flags
    info.settings_hash=cooked.settings
    desc:=textures.built_desc(built,id,&info)
    desc.owner=owner
    out.format,out.width,out.height,out.mips=built.format,built.width,built.height,len(built.mips)
    zone(import_options,"texture.save")
    doc:asset.Document
    out.saved=asset.texture_document(&doc,&types,desc)
    if out.saved!=.None {return}
    defer asset.document_destroy(&doc)
    if out.fast {
        _,out.saved=asset.document_put_row(&doc,&types,TEXTURE_FINAL,&cooked.final)
        if out.saved!=.None {return}
    }
    out.saved=asset.document_save(&doc,path)
    return
}

// Puts what texture_write gave in the store as output and records it; false,
// with a warning, for an image that does not become a texture, or with the
// writer failed.
@(private)
texture_written :: proc(w:^Writer,job:Texture_Job,out:Texture_Write,output:int) -> bool {
    switch {
    case out.built==.Too_Large:
        writer_warn(w,"image %s is not used: a side is above the %d texels a texture holds; scale it down in the source",job.name,asset.TEXTURE_MAX_SIZE)
        return false
    case out.built==.Gpu:
        return writer_fail(w,.Write,"image %s: %s",job.name,textures.GPU_ERROR)
    case out.built!=.None:
        writer_warn(w,"image %s is not used: %v",job.name,out.built)
        return false
    case out.saved!=.None:
        return save_failed(w,out.saved,w.paths[output])
    }
    if !(writer_take(w,output,out.hash) if out.kept else writer_put(w,output,w.paths[output])) {return false}
    w.fast||=out.fast
    record(w,output,job.name,texture_detail(out.format,out.width,out.height,out.mips),kept=out.kept)
    return true
}

// The textures of parts not given already, written as write_texture writes
// them, each a job of the job system of the import: into out by row.
@(private)
textures_write :: proc(w:^Writer,texture_jobs:[]Texture_Job,parts:[]Part,source:string,out:[]Texture_Write) {
    writer_candidates(w)
    Work :: struct {w:^Writer,jobs:[]Texture_Job,parts:[]Part,source:string,out:[]Texture_Write}
    work:=Work{w,texture_jobs,parts,source,out}
    run :: proc(work:^Work,first,last:int,worker:int) {
        ref:=jobs.worker_ref_at(work.w.options.worker,worker)
        if js:=ref.system;js!=nil {context.allocator=js.allocator}
        for i in first..<last {
            part:=work.parts[i]
            if part.given {continue}
            // What one texture takes is let go before the next on a worker.
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            work.out[i]=texture_write(work.w,work.jobs[i],part.id,part.owner,part.path,work.source,ref)
        }
    }
    if js:=w.options.worker.system;js!=nil {
        jobs.parallel_for(js,w.options.worker.worker,len(texture_jobs),1,run,&work)
    } else {
        run(&work,0,len(texture_jobs),w.options.worker.worker)
    }
}

// "BC1 512x512, 10 mips": what a texture holds.
@(private="file")
texture_detail :: proc(format:asset.Texture_Format,width,height,mips:int) -> string {
    return fmt.tprintf("%v %dx%d, %d mips",format,width,height,mips)
}

// Starts the writes of the import of the source at path (writer_source).
// folder: under the folder of the documents, where the documents of a first
// import go ("" in it).
@(private)
writer_init :: proc(w:^Writer,path,folder:string,options:Import_Options,report:^Import_Report,allocator:mem.Allocator) -> bool {
    w^={options=options,report=report,allocator=allocator,version=import_version(0)}
    if w.options.gpu==nil {w.options.gpu=&w.gpu}
    w.created.allocator=context.temp_allocator
    w.names.allocator=context.temp_allocator
    w.followed.allocator=context.temp_allocator
    w.rng=base.rng_make(u64(time.time_to_unix_nano(time.now())),u64(uintptr(w)))
    asset.types_init(&w.types)
    zone(options,"import.scan")
    return writer_source(w,path,folder) && writer_changed(w)
}

// Whether the build of what the import is made from now has an object in the
// store for every output of the cache the previous manifest lists: then
// nothing is built ahead. It fixes what the import is made from.
@(private)
writer_current :: proc(w:^Writer) -> bool {
    if w.options.rebuild || !w.stored {return false}
    writer_candidates(w)
    for a in w.previous.assets {
        if !asset.import_cached(a.kind) {continue}
        held:=false
        for &c in w.candidates {
            if !c.current {continue}
            for o in c.build.outputs {held||=o.id==a.id && asset.object_whole(w.options.store,o.object)}
        }
        if !held {return false}
    }
    return true
}

// Writes the meshes, materials, textures, skeletons and clips of a model as
// the objects of a build of its package (package.odin). Importing a source again
// gives each part the asset the previous manifest lists (identity.odin); a new
// one gets a random id. A document is also written or followed in the folder
// of the documents (documents.odin): <name>.mat, <name>.skeleton or
// <name>.anim there (under model.folder the first time). The parts name the
// prefab of the model as their owner (Import_Report.prefab), which
// import_source writes. A mesh or a texture a build of the package already
// has, made from what it would be made from now, is taken as it is
// (Written.kept), unless options.rebuild. A failure removes the documents this
// call created and records nothing.
import_write :: proc(model:^Imported_Model,options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    report_init(&report,allocator)

    w:Writer
    ok:=writer_init(&w,model.source,model.folder,options,&report,allocator)
    defer writer_close(&w)
    defer model_cooked_destroy(model)
    if ok {
        model_begin(&w,model)
        ok=write_model(&w,model) && writer_finish(&w,model.name if model.name!="" else filepath.stem(model.source),model.format)
    }
    if !ok {
        writer_rollback(&w)
        error=writer_error(&w,caller)
        report_destroy(&report)
        return {},error
    }
    return report,{}
}

// Writes a model as parts of the import of o, with what import_write writes
// one with: its meshes, materials, textures, skeletons and clips, each the
// asset of the previous manifest of its kind and name (then index), named as
// the model names them, a name with '/' in that folder under the one of the
// documents. A part of the kind and name of one o already gave is that asset,
// which is not written again. When the model has nodes, its prefab is the
// scene of its name, the owner of its meshes and skeletons: the caller writes
// it at prefab_path (cook/prefab.model_prefab) and records it
// (output_written), unless prefab_path is "" (o gave it already, or the import
// keeps it as it is). The report
// gives, in allocator, the ids by row as that of import_write and the prefab;
// what is written, the warnings and the programs of the model go to the
// report of o. The files the model was read from are inputs of the import
// (output_input). Its assets name the source of o, with its size, hash and
// version, and are made with its settings. A failure leaves in o what was
// written, for outputs_end.
output_model :: proc(o:^Outputs,model:^Imported_Model,allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    w:=&o.w
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,w.allocator,w.allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    defer model_cooked_destroy(model)
    for file in model.files {
        if !writer_input(w,file) {return {},input_late(file,caller)}
    }
    for image in model.images {
        if image.path!="" && !writer_input(w,image.path) {return {},input_late(image.path,caller)}
    }
    for warning in model.warnings {writer_warn(w,"%s",warning)}
    for program in model.programs {append(&o.report.programs,strings.clone(program,w.allocator))}

    written:Import_Report
    report_init(&written,w.allocator)
    written.settings=o.report.settings
    w.report,w.whole,w.given=&written,true,len(w.outputs)
    // The source its assets name is that of o.
    m:=model^
    m.source_size,m.source_hash,m.version,m.stored=o.size,o.hash,o.version,false
    ok:=write_model(w,&m)
    w.report,w.whole,w.given=&o.report,false,0
    append(&o.report.assets,..written.assets[:])
    append(&o.report.warnings,..written.warnings[:])
    clear(&written.assets);clear(&written.warnings)
    defer report_destroy(&written)
    if !ok {
        error=writer_error(w,caller)
        w.error={}
        return {},error
    }
    report_init(&report,allocator)
    report.settings=written.settings
    report.mesh_ids=slice.clone(written.mesh_ids,allocator)
    report.material_ids=slice.clone(written.material_ids,allocator)
    report.image_ids=slice.clone(written.image_ids,allocator)
    report.skeleton_ids=slice.clone(written.skeleton_ids,allocator)
    report.animation_id=written.animation_id
    report.prefab,report.prefab_info=written.prefab,written.prefab_info
    report.prefab_path=strings.clone(written.prefab_path,allocator)
    return report,{}
}

// The error of an input given once what the import is made from was fixed.
@(private)
input_late :: proc(file:string,allocator:mem.Allocator) -> Error {
    return error_make(.Malformed,"%s is an input given after the first output of the cache was planned, when what the import is made from was fixed: give every input (output_input) before",file,allocator=allocator)
}

// What a model is written with: its settings, its warnings and programs, and
// the files it was read from.
@(private="file")
model_begin :: proc(w:^Writer,model:^Imported_Model) {
    // The settings its package keeps are those of every import of it.
    if model.stored && !w.options.ignore_stored {w.options.settings=model.settings}
    w.report.settings=w.options.settings
    for warning in model.warnings {writer_warn(w,"%s",warning)}
    for program in model.programs {append(&w.report.programs,strings.clone(program,w.allocator))}
    w.version=model.version
    for file in model.files {writer_input(w,file)}
    for image in model.images {
        if image.path!="" {writer_input(w,image.path)}
    }
}

@(private="file")
write_model :: proc(w:^Writer,model:^Imported_Model) -> bool {
    source:=w.source
    chosen:=w.options.settings
    mesh_settings:=mesh_settings_hash(chosen)
    name:=model.name if model.name!="" else filepath.stem(source)
    if chosen.skeleton!={} {return write_clips_onto(w,model,source,name,chosen.skeleton)}

    // The prefab of the model: the one its package lists, which a model that lost its nodes keeps.
    // For Outputs, a scene of its name, written to the file output_written takes.
    listed:=false
    for a in w.previous.assets {listed||=a.kind==asset.KIND_SCENE && (!w.whole || a.name==name)}
    w.owner={}
    if listed || len(model.nodes)>0 {
        prefab:=[1]Part{{kind=asset.KIND_SCENE,name=name,extension=".scene",only=!w.whole}}
        parts_plan(w,prefab[:])
        w.owner=prefab[0].id
        _,keeping:=w.keeping[w.owner]
        if keeping && !w.whole {writer_written(w,w.owner,asset.KIND_SCENE,0)}
        w.report.prefab,w.report.prefab_path=w.owner,strings.clone(prefab[0].path if w.whole else prefab[0].target,w.allocator)
        w.report.prefab_info=import_info(source,name,0,model.source_size,model.source_hash,0,model.version)
    }

    jobs:=make([dynamic]Texture_Job,context.temp_allocator)
    for image,i in model.images {
        job:=Texture_Job{name=image.name,srgb=image.srgb,normal_map=image.normal_map,green_down=image.green_down,keep_precision=image.keep_precision,alpha_cutoff=image.alpha_cutoff,alpha_fill=image.alpha_fill,channels=image.channels,index=i,version=model.version}
        if image.path!="" {
            data,read_error:=read_whole(image.path)
            if read_error!=.None {
                if read_error==.Not_Found {writer_warn(w,"image %s: the file %s does not exist",image.name,image.path)} else {writer_warn(w,"image %s: the file %s could not be read: %v",image.name,image.path,read_error)}
                continue
            }
            job.bytes=data
        } else {
            job.bytes,job.make=image.data,image.make
            if image.made.width>0 {job.bytes,job.made=image.made.texels,image.made}
        }
        job.size=u64(len(job.bytes))
        job.hash=base.hash64(job.bytes)
        append(&jobs,job)
    }
    parts:=make([dynamic]Part,context.temp_allocator)
    for job in jobs {append(&parts,Part{kind=asset.KIND_TEXTURE,name=job.name,index=job.index,extension=".tex"})}
    first_material:=len(parts)
    for material,i in model.materials {append(&parts,Part{kind=asset.KIND_MATERIAL,name=material.name,index=w.options.material_index+i,extension=".mat"})}
    first_skeleton:=len(parts)
    for skeleton,i in model.skeletons {append(&parts,Part{kind=asset.KIND_SKELETON,name=skeleton.name,index=i,extension=".skeleton"})}
    first_mesh:=len(parts)
    for mesh,i in model.meshes {append(&parts,Part{kind=asset.KIND_MESH,name=mesh.name,index=i,extension=".mesh"})}
    animation:=len(parts)
    if len(model.animations)>0 {append(&parts,Part{kind=asset.KIND_ANIMATION,name=name,extension=".anim",only=!w.whole})}
    parts_plan(w,parts[:])
    reasons:=make([]string,len(model.materials),context.temp_allocator)
    parts_own(w,model,jobs[:],parts[:],first_material,reasons)

    // What a build of the package has, made from what it is made from now,
    // is taken, not built; the rest is built ahead on a job system. Without
    // one the writer builds each when it gets to it, holding one at a time.
    writer_candidates(w)
    kept_images:=make([]bool,len(model.images),context.temp_allocator)
    kept_meshes:=make([]store.Hash,len(model.meshes),context.temp_allocator)
    given_meshes:=make([]bool,len(model.meshes),context.temp_allocator)
    if !w.options.rebuild {
        reuse_zone:=zone_begin(w.options,"import.reuse")
        defer base.profile_end(reuse_zone)
        for job,i in jobs {
            part:=parts[i]
            _,found:=texture_reuse(w,&w.types,job,part.id,part.owner,source)
            kept_images[job.index]=part.given || found
        }
        material_part_ids:=make([]base.Asset_Id,len(model.materials),context.temp_allocator)
        for i in 0..<len(model.materials) {material_part_ids[i]=parts[first_material+i].id}
        for &mesh,i in model.meshes {
            part:=parts[first_mesh+i]
            if part.given {given_meshes[i]=true;continue}
            skeleton:base.Asset_Id
            if len(mesh.skin)>0 && mesh.skeleton>=0 && mesh.skeleton<len(model.skeletons) {skeleton=parts[first_skeleton+mesh.skeleton].id}
            info:=mesh_info(source,&mesh,i,mesh_content_hash(&mesh),mesh_slots(&mesh,material_part_ids),skeleton,chosen,model.version)
            kept_meshes[i],_,_=writer_reuse(w,&w.types,part.id,asset.KIND_MESH,part.owner,info)
        }
    }
    if w.options.worker.system!=nil {
        cook_meshes:=make([]bool,len(model.meshes),context.temp_allocator)
        for &kept,i in cook_meshes {kept=given_meshes[i] || kept_meshes[i]!={}}
        model_cook(model,w.options,cook_meshes,kept_images)
    }
    for &job in jobs {job.cooked=model.images[job.index].cooked}

    image_ids:=make([]base.Asset_Id,len(model.images),w.allocator)
    w.report.image_ids=image_ids
    writes:=make([]Texture_Write,len(jobs),context.temp_allocator)
    textures_write(w,jobs[:],parts[:len(jobs)],source,writes)
    for job,i in jobs {
        part:=&parts[i]
        if part.given || texture_written(w,job,writes[i],part.output) {image_ids[job.index]=part.id}
        if w.error.code!=.None {return false}
    }

    material_ids:=make([]base.Asset_Id,len(model.materials),w.allocator)
    w.report.material_ids=material_ids
    for &material,i in model.materials {
        part:=&parts[first_material+i]
        material_ids[i]=part.id
        if part.given {continue}
        info:=material_given(&material,image_ids)
        import_data:=import_info(source,material.name,i,model.source_size,model.source_hash,0,model.version)
        parameters:=material_given_parameters(&material,image_ids)
        material_zone:=zone_begin(w.options,"material.save")
        if error:=asset.material_save(part.path,&w.types,{id=part.id,owner=part.owner,info=info,imported=&info,parameters=parameters,imported_parameters=parameters,source=&import_data});error!=.None {return save_failed(w,error,part.path)}
        writer_put(w,part.output,part.path) or_return
        record(w,part.output,material.name,fmt.tprintf("%s: %s",part.owner!={}?fmt.tprintf("part of %s",name):"of its own",reasons[i]))
        base.profile_end(material_zone)
    }

    w.report.skeleton_ids=make([]base.Asset_Id,len(model.skeletons),w.allocator)
    root_bones:=make([]int,len(model.skeletons),context.temp_allocator)
    for skeleton,i in model.skeletons {
        part:=&parts[first_skeleton+i]
        w.report.skeleton_ids[i]=part.id
        body:asset.Skeleton_Body
        body_parts:[len(anim.Body_Part)]asset.Skeleton_Body_Part
        count,map_:=skeleton_body(nil,skeleton.bones,&body,&body_parts)
        root_bones[i]=skeleton_root_bone(skeleton.bones,map_) if count>0 else -1
        if part.given {continue}
        import_data:=import_info(source,skeleton.name,i,model.source_size,model.source_hash,0,model.version)
        sockets:=skeleton_sockets(model,skeleton)
        if count>0 {skeleton_grips(w,model,i,map_,&sockets)}
        if error:=asset.skeleton_save(part.path,&w.types,{id=part.id,owner=part.owner,bones=skeleton.bones,sockets=sockets[:],body=&body if count>0 else nil,body_parts=body_parts[:count],source=&import_data});error!=.None {return save_failed(w,error,part.path)}
        writer_put(w,part.output,part.path) or_return
        record(w,part.output,skeleton.name,fmt.tprintf("%d bones",len(skeleton.bones)))
    }
    w.report.mesh_ids=make([]base.Asset_Id,len(model.meshes),w.allocator)
    for &mesh,i in model.meshes {
        part:=&parts[first_mesh+i]
        id,path,owner:=part.id,part.path,part.owner
        w.report.mesh_ids[i]=id
        if part.given {continue}
        skeleton:base.Asset_Id
        if len(mesh.skin)>0 {
            if mesh.skeleton<0 || mesh.skeleton>=len(w.report.skeleton_ids) {return writer_fail(w,.Malformed,"mesh %s has no skeleton",mesh.name)}
            skeleton=w.report.skeleton_ids[mesh.skeleton]
        }
        if kept:=kept_meshes[i];kept!={} {
            kept_zone:=zone_begin(w.options,"mesh.kept")
            file:asset.Asset
            if asset.asset_open_object(&file,w.options.store,kept,context.temp_allocator)==.None {
                view,view_error:=asset.mesh_view(&file,&w.types)
                detail:=mesh_detail(view.levels,view.colliders,len(view.collision_points),len(view.collision_indices)) if view_error==.None else ""
                asset.asset_close(&file)
                if view_error==.None {
                    writer_take(w,part.output,kept) or_return
                    record(w,part.output,mesh.name,detail,kept=true)
                    base.profile_end(kept_zone)
                    continue
                }
            }
            base.profile_end(kept_zone)
        }
        slots:=mesh_slots(&mesh,material_ids)
        cooked:=mesh.cooked
        own:Cooked_Mesh
        if cooked==nil || cooked.settings!=mesh_settings {
            mesh_cook(&mesh,chosen,w.options,&own,context.temp_allocator)
            cooked=&own
        }
        switch cooked.failure {
        case .None:
        case .Not_Finite:return writer_fail(w,.Malformed,"mesh %s has a vertex whose position or texture coordinate is not a number (NaN or infinite); fix it in the source",mesh.name)
        case .Clusters:return writer_fail(w,.Limit,"mesh %s could not be encoded in clusters: there was no memory left for it, or it is larger than a .mesh holds",mesh.name)
        }
        geometry,collision:=cooked.geometry,cooked.collision
        import_data:=mesh_info(source,&mesh,i,cooked.content,slots,skeleton,chosen,model.version)
        desc:=asset.Mesh_Desc{
            id=id,owner=owner,geometry=geometry,slots=slots,joints=mesh.joints,skeleton=skeleton,
            colliders=collision.colliders,collision_points=collision.points,collision_indices=collision.indices,source=&import_data,
        }
        save_zone:=zone_begin(w.options,"mesh.save")
        saved:=asset.mesh_save(path,&w.types,desc)
        base.profile_end(save_zone)
        detail:=mesh_detail(geometry.levels,collision.colliders,len(collision.points),len(collision.indices))
        if cooked==&own {cooked_mesh_destroy(&own)}
        if saved!=.None {return save_failed(w,saved,path)}
        writer_put(w,part.output,path) or_return
        record(w,part.output,mesh.name,detail)
    }
    if len(model.animations)>0 && parts[animation].given {w.report.animation_id=parts[animation].id}
    if len(model.animations)>0 && !parts[animation].given {
        part:=&parts[animation]
        import_data:=import_info(source,name,0,model.source_size,model.source_hash,0,model.version)
        clips:=make([]asset.Animation_Clip_Desc,len(model.animations),context.temp_allocator)
        copy(clips,model.animations)
        for &clip in clips {
            index:int
            clip.skeleton,index=clip_skeleton(model,clip,w.report.skeleton_ids)
            if index>=0 {clip.root=clip_root(model.skeletons[index].bones,root_bones[index],clip)}
        }
        desc:=asset.Animation_Desc{id=part.id,owner=part.owner,clips=clips,source=&import_data}
        if error:=asset.animation_save(part.path,&w.types,desc);error!=.None {return save_failed(w,error,part.path)}
        writer_put(w,part.output,part.path) or_return
        w.report.animation_id=part.id
        record(w,part.output,name,fmt.tprintf("%d clips",len(model.animations)))
    }
    return true
}

// Only the clips of a model, as an .anim of its own bound to a skeleton the project has
// (Import_Settings.skeleton): the motion of another file onto a character imported before. Each clip
// keeps the root the model's own skeleton gives it. A clip that moves no bone at all (its markers
// alone, or curves) goes on that skeleton as well: only one whose bones the skeleton lacks is
// refused.
@(private="file")
write_clips_onto :: proc(w:^Writer,model:^Imported_Model,source,name:string,skeleton:base.Asset_Id) -> bool {
    if len(model.animations)==0 {return writer_fail(w,.Malformed,"%s has no clips to put on the skeleton of Import_Settings.skeleton",source)}
    parts:=[1]Part{{kind=asset.KIND_ANIMATION,name=name,extension=".anim",only=!w.whole}}
    parts_plan(w,parts[:])
    part:=&parts[0]
    w.report.animation_id=part.id
    if part.given {return true}
    import_data:=import_info(source,name,0,model.source_size,model.source_hash,0,model.version)
    clips:=make([]asset.Animation_Clip_Desc,len(model.animations),context.temp_allocator)
    copy(clips,model.animations)
    ids:=make([]base.Asset_Id,len(model.skeletons),context.temp_allocator)
    for &id in ids {id=skeleton}
    for &clip in clips {
        index:int
        clip.skeleton,index=clip_skeleton(model,clip,ids)
        if index<0 && len(model.skeletons)>0 && !clip_moves(clip) {index=0}
        if index<0 {return writer_fail(w,.Malformed,"clip %s of %s moves no bone of a skeleton of the file, which the skeleton it goes on should share",clip.name,source)}
        clip.skeleton=skeleton
        body:asset.Skeleton_Body
        body_parts:[len(anim.Body_Part)]asset.Skeleton_Body_Part
        bones:=model.skeletons[index].bones
        count,map_:=skeleton_body(nil,bones,&body,&body_parts)
        clip.root=clip_root(bones,skeleton_root_bone(bones,map_) if count>0 else -1,clip)
    }
    desc:=asset.Animation_Desc{id=part.id,owner=part.owner,clips=clips,source=&import_data}
    if error:=asset.animation_save(part.path,&w.types,desc);error!=.None {return save_failed(w,error,part.path)}
    writer_put(w,part.output,part.path) or_return
    w.report.animation_id=part.id
    text:[base.ASSET_ID_TEXT]u8
    record(w,part.output,name,fmt.tprintf("%d clips on skeleton %s",len(model.animations),base.asset_id_format(skeleton,text[:])))
    return true
}

// The skeleton a clip plays on: the one with the most bones its transform tracks move, and its
// index (-1: none).
@(private="file")
clip_skeleton :: proc(model:^Imported_Model,clip:asset.Animation_Clip_Desc,ids:[]base.Asset_Id) -> (id:base.Asset_Id,index:int) {
    best:=0;index=-1
    for skeleton,i in model.skeletons {
        if i>=len(ids) {break}
        moved:=0
        for track in clip.tracks {
            if track.property>.Scale {continue}
            target:=base.name_hash(track.target)
            for &bone in skeleton.bones {if bone.target==target {moved+=1;break}}
        }
        if moved>best {best,id,index=moved,ids[i],i}
    }
    return
}

// Whether a clip has a transform track: what binds it to the bones of a skeleton.
@(private="file")
clip_moves :: proc(clip:asset.Animation_Clip_Desc) -> bool {
    for track in clip.tracks {
        if track.property<=.Scale {return true}
    }
    return false
}

// The bone a skeleton carries the motion of its body on: the parent of its pelvis (the root bone of
// a mannequin-style skeleton, which a clamber or a jump start moves up and along). -1 when the pelvis is its
// top bone: its track is the bob of the body, which a root kept in place would flatten.
@(private="file")
skeleton_root_bone :: proc(bones:[]asset.Skeleton_Bone,map_:anim.Body_Map) -> int {
    pelvis:=int(map_.bones[.Pelvis])
    if pelvis<0 || pelvis>=len(bones) {return -1}
    parent:=int(bones[pelvis].parent)
    return parent if parent>=0 && parent<len(bones) else -1
}

// The root of a clip of the skeleton of bones: its root bone with translation and rotation when the
// clip moves or turns it (a clamber, a jump start), so that a character whose capsule moves the
// body plays it in place (Root_Motion_Policy.In_Place); else none. A root a person set on the clip
// in a project stays there (document_follow).
@(private="file")
clip_root :: proc(bones:[]asset.Skeleton_Bone,root:int,clip:asset.Animation_Clip_Desc) -> (value:asset.Animation_Root) {
    if root<0 {return}
    for track in clip.tracks {
        if track.property!=.Position && track.property!=.Rotation || base.name_hash(track.target)!=bones[root].target || len(track.keys)<2 {continue}
        first:=track.keys[0].value
        for key in track.keys[1:] {
            moved:=linalg.length(key.value.xyz-first.xyz)>ROOT_STILL if track.property==.Position else abs(linalg.dot(key.value,first))<1-ROOT_STILL
            if moved {
                value.bone,value.translation,value.rotation=bones[root].path,true,true
                return
            }
        }
    }
    return
}
// Least change of the position of a root bone, in its units, or of the cosine of half its turn,
// that moves it.
@(private="file")
ROOT_STILL :: 1e-4

// "12034/3008/752 triangles, 3 hulls of 87 points, 1 box": the levels and the colliders of a mesh.
@(private="file")
mesh_detail :: proc(levels:[]asset.Mesh_Level,colliders:[]asset.Collider,points,indices:int) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for level,at in levels {fmt.sbprintf(&b,"%s%d",at>0?"/":"",level.triangle_count)}
    strings.write_string(&b," triangles")
    counts:[asset.Collider_Kind]int
    for collider in colliders {counts[collider.kind]+=1}
    if counts[.Mesh]>0 {fmt.sbprintf(&b,", collision mesh of %d triangles",indices/3)}
    if counts[.Hull]>0 {fmt.sbprintf(&b,", %d hull%s of %d points",counts[.Hull],counts[.Hull]>1?"s":"",points)}
    names:=[asset.Collider_Kind][2]string{.Box={"box","boxes"},.Sphere={"sphere","spheres"},.Capsule={"capsule","capsules"},.Hull={},.Mesh={}}
    for kind in ([]asset.Collider_Kind{.Box,.Sphere,.Capsule}) {
        if counts[kind]>0 {fmt.sbprintf(&b,", %d %s",counts[kind],names[kind][counts[kind]>1?1:0])}
    }
    return strings.to_string(b)
}

// Imports an image file as a texture of its own, read as options.image says
// and keeping the coverage of options.alpha_coverage, unless the settings
// its package keeps say otherwise. The texture is the root of the import:
// importing the file again gives the asset its package lists.
import_texture :: proc(path:string,options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    options:=options
    if !options.ignore_stored {
        stored,found,settings_error:=settings_load(options,path)
        if settings_error.code!=.None {return {},settings_error}
        if found {options.settings=stored}
    }
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    report_init(&report,allocator)
    report.settings=options.settings

    w:Writer
    ok:=writer_init(&w,path,"",options,&report,allocator)
    defer writer_close(&w)
    if ok {
        data,read_error:=read_whole(path)
        if read_error!=.None {
            ok=writer_fail(&w,read_error==.Not_Found?Error_Code.Not_Found:Error_Code.Read,"%s could not be read: %v",path,read_error)
        } else {
            use:=options.image
            source:=w.source
            job:=Texture_Job{
                name=filepath.stem(path),bytes=data,size=u64(len(data)),hash=base.hash64(data),
                srgb=use==.Color,normal_map=use==.Normal || use==.Normal_Green_Down,green_down=use==.Normal_Green_Down,alpha_cutoff=options.alpha_coverage,version=import_version(0),
            }
            id,target,output:=root_take(&w,asset.KIND_TEXTURE,job.name,".tex")
            built:=write_texture(&w,job,id,{},target,source,output)
            if w.error.code!=.None {ok=false} else if !built {ok=writer_fail(&w,.Unsupported,"%s is not an image that can be decoded",path)}
            ok=ok && writer_finish(&w,job.name,"image")
        }
    }
    if !ok {
        writer_rollback(&w)
        error=writer_error(&w,caller)
        report_destroy(&report)
        return {},error
    }
    return report,{}
}

// The sockets of a skeleton: those the source names, and one on each bone
// that a rigid node of the model hangs from.
@(private="file")
skeleton_sockets :: proc(model:^Imported_Model,skeleton:Imported_Skeleton) -> [dynamic]asset.Skeleton_Socket {
    bones:=skeleton.bones
    sockets:=make([dynamic]asset.Skeleton_Socket,context.temp_allocator)
    append(&sockets,..skeleton.sockets)
    for &bone in bones {
        used:=false
        for node,i in model.nodes {
            if node.mesh>=0 && node.mesh<len(model.meshes) && len(model.meshes[node.mesh].skin)>0 {continue}
            pure_bone:=false
            for &candidate in bones {if base.text_get(candidate.path[:])==node.path {pure_bone=true;break}}
            if _,light:=node.light.?;pure_bone && node.mesh<0 && !light {continue}
            attached:=i
            for attached>=0 {
                path:=model.nodes[attached].path
                nearest:=false
                for &candidate in bones {if base.text_get(candidate.path[:])==path {nearest=true;break}}
                if nearest {used=path==base.text_get(bone.path[:]);break}
                attached=model.nodes[attached].parent
            }
            if used {break}
        }
        if !used {continue}
        socket:=asset.Skeleton_Socket{bone=bone.path,offset=mm.TRANSFORM_IDENTITY}
        base.text_set(socket.name[:],fmt.tprintf("bone.%016x",bone.target));append(&sockets,socket)
    }
    return sockets
}

// The grip sockets of the hands of a skeleton's body (hand_grip_socket), unless the source names
// one alike. A hand it cannot measure is a warning: the import keeps the rest.
@(private="file")
skeleton_grips :: proc(w:^Writer,model:^Imported_Model,skeleton:int,map_:anim.Body_Map,sockets:^[dynamic]asset.Skeleton_Socket) {
    names:=GRIP_NAMES
    for part,side in GRIP_PARTS {
        hand:=map_.bones[part]
        if hand<0 {continue}
        name:=names[side]
        given:=false
        for &socket in sockets {if base.text_get(socket.name[:])==name {given=true;break}}
        if given {continue}
        socket,found,error:=hand_grip_socket(model,skeleton,int(hand),name)
        if error.code!=.None {writer_warn(w,"%s",error.message);continue}
        if found {append(sockets,socket)}
    }
}
