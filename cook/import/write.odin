package importer

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:project"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

Written :: struct {
    id:base.Asset_Id,
    kind:asset.Fourcc,
    name:string,
    path:string,
    source:string, // the source as imports name it
    bytes:int,
    detail:string, // what it holds, for a report: levels and colliders of a mesh, format and size of a texture
    kept:bool,     // its file already was the one this import gives: nothing was built
}

Import_Report :: struct {
    assets:[dynamic]Written,
    warnings:[dynamic]string,
    others:[dynamic]string, // files of other imports whose owner this one cleared: what it shares with them
    programs:[dynamic]string, // the Surface programs written to the shaders of the project, their files: the editor publishes them
    // The asset of each mesh, material and image of the model, by row; zero for an image that was not written.
    mesh_ids,material_ids,image_ids,skeleton_ids:[]base.Asset_Id,
    animation_id:base.Asset_Id,
    // The prefab of a model, the owner its parts name: the id the sidecar of
    // the source lists and the file that has it, else new ones. Zero for a
    // model without nodes that had no prefab. import_source writes it, with
    // prefab_info.
    prefab:base.Asset_Id,
    prefab_path:string,
    prefab_info:asset.Import_Info,
    settings:Import_Settings, // what the source was imported with: what its sidecar keeps
    saved:string,             // the sidecar of the source, which the import wrote or found saying the same
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
    for other in report.others {delete(other,report.allocator)}
    for program in report.programs {delete(program,report.allocator)}
    delete(report.assets)
    delete(report.warnings)
    delete(report.others)
    delete(report.programs)
    delete(report.mesh_ids,report.allocator)
    delete(report.material_ids,report.allocator)
    delete(report.image_ids,report.allocator)
    delete(report.skeleton_ids,report.allocator)
    delete(report.saved,report.allocator)
    delete(report.prefab_path,report.allocator)
    report^={}
}

// A report whose lists live in allocator.
report_init :: proc(report:^Import_Report,allocator:=context.allocator) {
    report.allocator=allocator
    report.assets.allocator=allocator
    report.warnings.allocator=allocator
    report.others.allocator=allocator
    report.programs.allocator=allocator
}

// Moves what src lists (assets, warnings, others and programs) to the end of
// dst and destroys src; both live in the same allocator.
report_take :: proc(dst,src:^Import_Report) {
    append(&dst.assets,..src.assets[:])
    append(&dst.warnings,..src.warnings[:])
    append(&dst.others,..src.others[:])
    append(&dst.programs,..src.programs[:])
    clear(&src.assets);clear(&src.warnings);clear(&src.others);clear(&src.programs)
    report_destroy(src)
}

// A source path as imports name it: relative to options.root when it is inside, with forward slashes.
source_path :: proc(options:Import_Options,path:string,allocator:=context.temp_allocator) -> string {
    absolute,error:=filepath.abs(path,context.temp_allocator)
    if error!=nil {absolute=path}
    cleaned,_:=filepath.clean(absolute,context.temp_allocator)
    slashed,_:=strings.replace_all(cleaned,"\\","/",context.temp_allocator)
    if options.root!="" {
        root_absolute,_:=filepath.abs(options.root,context.temp_allocator)
        root_clean,_:=filepath.clean(root_absolute,context.temp_allocator)
        root,_:=strings.replace_all(root_clean,"\\","/",context.temp_allocator)
        prefix:=strings.concatenate({strings.trim_right(root,"/"),"/"},context.temp_allocator)
        if len(slashed)>len(prefix) && strings.equal_fold(slashed[:len(prefix)],prefix) {
            return strings.clone(slashed[len(prefix):],allocator)
        }
    }
    return strings.clone(slashed,allocator)
}

@(private)
read_whole :: proc(path:string) -> ([]u8,serial.File_Error) {
    if unsafe_path(path) {return nil,.Not_Found}
    return serial.file_read(path,context.temp_allocator,limit=MAX_SOURCE_BYTES)
}

@(private)
Writer :: struct {
    options:Import_Options,
    folder:string,
    search:string,               // where the documents of the import are looked for by their ids
    types:asset.Types,
    report:^Import_Report,
    created:[dynamic]string,
    names:map[string]bool,       // files of the folder new parts took, in lower case
    earlier:[dynamic]Earlier,
    by_id:map[base.Asset_Id]int, // into earlier
    source:string,               // the source as imports name it (source_path)
    sidecar_file:string,
    sidecar:Sidecar,             // of the source, as the import found it
    taken:[]bool,                // the outputs of sidecar the import gives again
    outputs:[dynamic]Output,     // what the import gives: the outputs of the sidecar it writes
    imported:string,             // the imported folder of options.root
    cached:bool,                 // what the import builds of the cache kinds goes there, each file named by its id
    owner:base.Asset_Id,         // of the parts: the prefab of a model
    rng:base.Rng,
    allocator:mem.Allocator,
    error:Error,
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

@(private)
record :: proc(w:^Writer,id:base.Asset_Id,kind:asset.Fourcc,name,path,source:string,existed:bool,detail:="",kept:=false) {
    size:int
    if info,error:=os.stat(path,context.temp_allocator);error==nil {size=int(info.size)}
    clone,_:=strings.clone(path,w.allocator)
    named,_:=strings.clone(name,w.allocator)
    from,_:=strings.clone(source,w.allocator)
    described,_:=strings.clone(detail,w.allocator)
    append(&w.report.assets,Written{id=id,kind=kind,name=named,path=clone,source=from,bytes=size,detail=described,kept=kept})
    if !existed {append(&w.created,clone)}
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

// Whether the file at path already is the asset a write gives: the same id
// and kind at the version this build writes, whole, with the Import_Info it
// would carry. That record is the cache of an import: the source by size and
// hash, the versions of the writer and of the format, and the settings. A
// file that names another owner is kept with only its header written again.
// An asset that is kept is open in file, for its report; the caller closes it.
@(private="file")
writer_kept :: proc(w:^Writer,path:string,kind:asset.Fourcc,version:u16,id,owner:base.Asset_Id,info:^asset.Import_Info,file:^asset.Asset) -> bool {
    if w.options.rebuild || !os.exists(path) {return false}
    if asset.asset_load(file,path,context.temp_allocator)!=.None {return false}
    header:=file.blob.header
    if header.kind==kind && header.kind_version==version && header.id==id && asset.blob_verify_hash(&file.blob) {
        if stored,error:=asset.import_info(file,&w.types);error==.None && stored!=nil && stored^==info^ {
            if header.owner==owner {return true}
            if asset.header_owner_set(file.blob.data,owner)==.None && serial.file_write_atomic(path,file.blob.data)==.None {
                file.blob.header.owner=owner
                return true
            }
        }
    }
    asset.asset_close(file)
    return false
}

// Writes a material the source gives as desc. Over the file of the same
// material it follows what the source gives now and keeps what was changed
// after the last import, with the parameters, layers and hidden names it has.
@(private="file")
material_write :: proc(w:^Writer,path:string,existed:bool,desc:asset.Material_Desc) -> asset.Error {
    desc:=desc
    file:asset.Asset
    if !existed || asset.asset_load(&file,path,context.temp_allocator)!=.None {return asset.material_save(path,&w.types,desc)}
    defer asset.asset_close(&file)
    if view,error:=asset.material_view(&file,&w.types);error==.None && file.blob.header.id==desc.id {
        desc.info=asset.material_follow(&w.types,view,desc.imported^)
        desc.parameters=asset.material_parameters_follow(view,desc.imported_parameters,context.temp_allocator)
        desc.overlays,desc.hidden=view.overlays,view.hidden
    }
    return asset.material_save(path,&w.types,desc)
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
    file:string,      // the image file as imports name it; "" for an image inside the source
    bytes:[]u8,       // encoded, or the texels of an image the format made
    made:textures.Source,   // of those texels; width 0 for an encoded image
    decoded:textures.Image, // the RGBA8 pixels of an encoded image, once a verdict read them (job_pixels)
    size:u64,
    hash:u64,
    srgb,normal_map,green_down,keep_precision:bool,
    alpha_cutoff:f32,
    channels:textures.Channels,
    index:int,
    version:u32,
    cooked:^Cooked_Texture,        // built ahead (model_cook); nil when not
}

@(private)
texture_options :: proc(w:^Writer,job:Texture_Job) -> textures.Build_Options {
    return image_build_options({srgb=job.srgb,normal_map=job.normal_map,green_down=job.green_down,alpha_cutoff=job.alpha_cutoff,keep_precision=job.keep_precision,channels=job.channels},w.options.settings)
}

// Builds and writes one texture of source as the asset id at path; false when
// the image cannot be turned into one (a warning says why).
@(private)
write_texture :: proc(w:^Writer,job:Texture_Job,id,owner:base.Asset_Id,path,source:string) -> bool {
    options:=texture_options(w,job)
    info:=import_info(source,job.name,job.index,job.size,job.hash,textures.settings_hash(options),job.version)
    file:asset.Asset
    kept:=writer_kept(w,path,asset.KIND_TEXTURE,asset.TEXTURE_VERSION,id,owner,&info,&file)
    // A Fast texture stays until the cache keeps it as Final.
    if !kept && w.options.fast_textures && !textures.cache_has(w.options.texture_cache,textures.cache_key_build(job.bytes,job.made,options)) {
        fast:=info
        fast.settings_hash=fast_settings(options)
        if kept=writer_kept(w,path,asset.KIND_TEXTURE,asset.TEXTURE_VERSION,id,owner,&fast,&file);kept {info=fast}
    }
    if kept {
        defer asset.asset_close(&file)
        if view,error:=asset.texture_view(&file,&w.types);error==.None {
            record(w,id,asset.KIND_TEXTURE,job.name,path,source,true,texture_detail(view.info.format,int(view.info.width),int(view.info.height),len(view.mips)),kept=true)
            return true
        }
    }
    cooked:=job.cooked
    own:Cooked_Texture
    if cooked==nil || cooked.settings!=info.settings_hash && (!w.options.fast_textures || cooked.settings!=fast_settings(options)) || cooked.size!=job.size || cooked.hash!=job.hash {
        texture_cook(job.bytes,job.made,job.decoded,options,w.options,&own,context.temp_allocator)
        cooked=&own
    }
    defer if cooked==&own {cooked_texture_destroy(&own)}
    if cooked.error!=.None {
        writer_warn(w,"image %s is not used: %v",job.name,cooked.error)
        return false
    }
    built:=&cooked.built
    info.settings_hash=cooked.settings
    desc:=textures.built_desc(built,id,&info)
    desc.owner=owner
    existed:=os.exists(path)
    zone(w.options,"texture.save")
    if error:=asset.texture_save(path,&w.types,desc);error!=.None {
        save_failed(w,error,path)
        return false
    }
    record(w,id,asset.KIND_TEXTURE,job.name,path,source,existed,texture_detail(built.format,built.width,built.height,len(built.mips)))
    return true
}

// "BC1 512x512, 10 mips": what a texture holds.
@(private="file")
texture_detail :: proc(format:asset.Texture_Format,width,height,mips:int) -> string {
    return fmt.tprintf("%v %dx%d, %d mips",format,width,height,mips)
}

// Starts the writes of the import of the source at path into folder: reads
// its sidecar and the fronts of the assets its documents are found among,
// under the assets folder of the project at options.root, else under
// options.root, else under folder (what a game was built into is no output of
// an import), and of those of the imported folder of the root.
@(private)
writer_init :: proc(w:^Writer,path,folder:string,options:Import_Options,report:^Import_Report,allocator:mem.Allocator) -> bool {
    w^={options=options,folder=folder,report=report,allocator=allocator}
    w.created.allocator=context.temp_allocator
    w.names.allocator=context.temp_allocator
    w.earlier.allocator=context.temp_allocator
    w.by_id.allocator=context.temp_allocator
    w.rng=base.rng_make(u64(time.time_to_unix_nano(time.now())),u64(uintptr(w)))
    asset.types_init(&w.types)
    if !writer_source(w,path) {return false}
    w.search=folder
    if options.root!="" {
        w.search=options.root
        if assets:=project.folder_path(options.root,.Assets,context.temp_allocator);os.is_dir(assets) {w.search=assets}
    }
    zone(options,"import.scan")
    earlier_scan(w,w.search)
    if w.imported!="" {earlier_scan(w,w.imported)}
    return true
}

@(private)
writer_rollback :: proc(w:^Writer) {
    for path in w.created {os.remove(path)}
}

// Writes the meshes, materials, textures, skeletons and clips of a model as
// assets. Importing a source again writes each part again with the id its
// sidecar lists, to the file it has (identity.odin); a new part gets a random
// id and <name>.mesh, <name>.mat, <name>.tex, <name>.skeleton or <name>.anim
// in folder, or for what nobody edits a file of the imported folder of the
// root named by its id (sidecar.odin). The parts name the prefab of the model as
// their owner (Import_Report.prefab), which import_source writes. A mesh or a
// texture whose file already is the one it would write is kept as it is
// (Written.kept), unless options.rebuild. A failure removes the files this
// call created.
import_write :: proc(model:^Imported_Model,folder:string,options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    scratch:mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch,allocator,allocator,block_size=1<<20,out_band_size=1<<20)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator=base.dynamic_arena_allocator(&scratch)
    report_init(&report,allocator)

    w:Writer
    ok:=writer_init(&w,model.source,folder,options,&report,allocator)
    defer asset.types_destroy(&w.types)
    defer model_cooked_destroy(model)
    if ok {
        // Without a job system the writer builds each one when it gets to it, holding one at a time.
        if options.worker.system!=nil {
            known:=known_make(w.earlier[:],context.temp_allocator)
            model_cook(model,w.options,&known)
        }
        ok=write_model(&w,model) && writer_finish(&w)
    }
    if !ok {
        writer_rollback(&w)
        error=writer_error(&w,caller)
        report_destroy(&report)
        return {},error
    }
    return report,{}
}

@(private="file")
write_model :: proc(w:^Writer,model:^Imported_Model) -> bool {
    source:=w.source
    // The settings kept with the source are those of every import of it.
    if model.stored && !w.options.ignore_stored {w.options.settings=model.settings}
    chosen:=w.options.settings
    w.report.settings=chosen
    mesh_settings:=mesh_settings_hash(chosen)
    for warning in model.warnings {writer_warn(w,"%s",warning)}
    for program in model.programs {append(&w.report.programs,strings.clone(program,w.allocator))}

    name:=model.name if model.name!="" else filepath.stem(source)
    if chosen.skeleton!={} {return write_clips_onto(w,model,source,name,chosen.skeleton)}

    // The prefab of the model: the one its sidecar lists, which a model that lost its nodes keeps.
    listed:=false
    for output in w.sidecar.outputs {listed||=output.kind==asset.KIND_SCENE}
    if listed || len(model.nodes)>0 {
        prefab_path:string
        w.owner,prefab_path=root_take(w,asset.KIND_SCENE,name,".scene")
        w.report.prefab,w.report.prefab_path=w.owner,strings.clone(prefab_path,w.allocator)
        w.report.prefab_info=import_info(source,name,0,model.source_size,model.source_hash,0,model.version)
    }

    jobs:=make([dynamic]Texture_Job,context.temp_allocator)
    for image,i in model.images {
        job:=Texture_Job{name=image.name,srgb=image.srgb,normal_map=image.normal_map,green_down=image.green_down,keep_precision=image.keep_precision,alpha_cutoff=image.alpha_cutoff,channels=image.channels,index=i,version=model.version,cooked=image.cooked}
        if image.path!="" {
            data,read_error:=read_whole(image.path)
            if read_error!=.None {
                if read_error==.Not_Found {writer_warn(w,"image %s: the file %s does not exist",image.name,image.path)} else {writer_warn(w,"image %s: the file %s could not be read: %v",image.name,image.path,read_error)}
                continue
            }
            job.bytes=data
            job.file=source_path(w.options,image.path)
        } else {
            job.bytes=image.data
            if image.made.width>0 {job.bytes,job.made=image.made.texels,image.made}
        }
        job.size=u64(len(job.bytes))
        job.hash=base.hash64(job.bytes)
        append(&jobs,job)
    }
    parts:=make([dynamic]Part,context.temp_allocator)
    for job in jobs {
        options:=texture_options(w,job)
        // An import of the editor also takes what another wrote Fast with the same content.
        fast:=fast_settings(options) if w.options.fast_textures else 0
        append(&parts,Part{kind=asset.KIND_TEXTURE,name=job.name,index=job.index,extension=".tex",file=job.file,size=job.size,hash=job.hash,settings=textures.settings_hash(options),fast=fast})
    }
    first_material:=len(parts)
    for material,i in model.materials {append(&parts,Part{kind=asset.KIND_MATERIAL,name=material.name,index=w.options.material_index+i,extension=".mat"})}
    first_skeleton:=len(parts)
    for skeleton,i in model.skeletons {append(&parts,Part{kind=asset.KIND_SKELETON,name=skeleton.name,index=i,extension=".skeleton"})}
    first_mesh:=len(parts)
    for mesh,i in model.meshes {append(&parts,Part{kind=asset.KIND_MESH,name=mesh.name,index=i,extension=".mesh"})}
    animation:=len(parts)
    if len(model.animations)>0 {append(&parts,Part{kind=asset.KIND_ANIMATION,name=name,extension=".anim"})}
    parts_plan(w,parts[:])
    reasons:=make([]string,len(model.materials),context.temp_allocator)
    parts_own(w,model,jobs[:],parts[:],first_material,reasons)
    parts_record(w,parts[:])

    image_ids:=make([]base.Asset_Id,len(model.images),w.allocator)
    w.report.image_ids=image_ids
    for job,i in jobs {
        part:=&parts[i]
        if part.shared!=NOT_SHARED {
            image_ids[job.index]=part.id
            continue
        }
        built:=write_texture(w,job,part.id,part.owner,part.path,source)
        if w.error.code!=.None {return false}
        if built {image_ids[job.index]=part.id}
    }

    material_ids:=make([]base.Asset_Id,len(model.materials),w.allocator)
    w.report.material_ids=material_ids
    for &material,i in model.materials {
        part:=&parts[first_material+i]
        info:=material_given(&material,image_ids)
        material_ids[i]=part.id
        if part.shared!=NOT_SHARED {continue}
        import_data:=import_info(source,material.name,i,model.source_size,model.source_hash,0,model.version)
        existed:=os.exists(part.path)
        parameters:=material_given_parameters(&material,image_ids)
        material_zone:=zone_begin(w.options,"material.save")
        if error:=material_write(w,part.path,existed,{id=part.id,owner=part.owner,info=info,imported=&info,parameters=parameters,imported_parameters=parameters,source=&import_data});error!=.None {return save_failed(w,error,part.path)}
        record(w,part.id,asset.KIND_MATERIAL,material.name,part.path,source,existed,fmt.tprintf("%s: %s",part.owner!={}?fmt.tprintf("part of %s",name):"of its own",reasons[i]))
        base.profile_end(material_zone)
    }

    w.report.skeleton_ids=make([]base.Asset_Id,len(model.skeletons),w.allocator)
    root_bones:=make([]int,len(model.skeletons),context.temp_allocator)
    for skeleton,i in model.skeletons {
        part:=&parts[first_skeleton+i]
        w.report.skeleton_ids[i]=part.id
        import_data:=import_info(source,skeleton.name,i,model.source_size,model.source_hash,0,model.version)
        existed:=os.exists(part.path)
        // The file it replaces: what a person set on it stays (body parts, sockets of their own).
        previous_file:asset.Asset
        previous:^asset.Skeleton_View
        previous_view:asset.Skeleton_View
        loaded:bool
        if existed && asset.asset_load(&previous_file,part.path,context.temp_allocator)==.None {
            loaded=true
            view,error:=asset.skeleton_view(&previous_file,&w.types)
            if error==.None {previous_view=view;previous=&previous_view}
            if error==.Version {writer_warn(w,"%s is of a version this build does not read: the body parts, axes and sockets set by hand on it were not kept; set them again",part.path)}
        }
        defer if loaded {asset.asset_close(&previous_file)}
        body:asset.Skeleton_Body
        body_parts:[len(anim.Body_Part)]asset.Skeleton_Body_Part
        count,map_:=skeleton_body(previous,skeleton.bones,&body,&body_parts)
        root_bones[i]=skeleton_root_bone(skeleton.bones,map_) if count>0 else -1
        sockets:=skeleton_sockets(model,skeleton)
        if count>0 {skeleton_grips(w,model,i,map_,&sockets)}
        skeleton_sockets_kept(previous,skeleton.bones,&sockets)
        if error:=asset.skeleton_save(part.path,&w.types,{id=part.id,owner=part.owner,bones=skeleton.bones,sockets=sockets[:],body=&body if count>0 else nil,body_parts=body_parts[:count],source=&import_data});error!=.None {return save_failed(w,error,part.path)}
        record(w,part.id,asset.KIND_SKELETON,skeleton.name,part.path,source,existed,fmt.tprintf("%d bones",len(skeleton.bones)))
    }
    w.report.mesh_ids=make([]base.Asset_Id,len(model.meshes),w.allocator)
    for &mesh,i in model.meshes {
        part:=&parts[first_mesh+i]
        id,path,owner:=part.id,part.path,part.owner
        w.report.mesh_ids[i]=id
        skeleton:base.Asset_Id
        if len(mesh.skin)>0 {
            if mesh.skeleton<0 || mesh.skeleton>=len(w.report.skeleton_ids) {return writer_fail(w,.Malformed,"mesh %s has no skeleton",mesh.name)}
            skeleton=w.report.skeleton_ids[mesh.skeleton]
        }
        import_data:=import_info(source,mesh.name,i,model.source_size,model.source_hash,mesh_settings,model.version)
        file:asset.Asset
        kept_zone:=zone_begin(w.options,"mesh.kept")
        if writer_kept(w,path,asset.KIND_MESH,asset.MESH_VERSION,id,owner,&import_data,&file) {
            view,view_error:=asset.mesh_view(&file,&w.types)
            // The ids a kept mesh names are those of this import: its skeleton and the material of each slot.
            if view_error==.None && (view.info.skeleton!=skeleton || len(view.slots)!=len(mesh.slots)) {view_error=.Invalid}
            for slot,at in mesh.slots {
                if view_error==.None && view.slots[at].material!=(slot.material>=0?material_ids[slot.material]:base.Asset_Id{}) {view_error=.Invalid}
            }
            if view_error==.None {
                if chosen.collision!=.None && len(view.colliders)==0 {writer_warn(w,"mesh %s: no %v collider could be made of it",mesh.name,chosen.collision)}
                record(w,id,asset.KIND_MESH,mesh.name,path,source,true,mesh_detail(view.levels,view.colliders,len(view.collision_points),len(view.collision_indices)),kept=true)
            }
            asset.asset_close(&file)
            if view_error==.None {base.profile_end(kept_zone);continue}
        }
        base.profile_end(kept_zone)
        slots:=make([]asset.Material_Slot,len(mesh.slots),context.temp_allocator)
        for slot,at in mesh.slots {
            slots[at].id=slot.id
            asset.text_set(slots[at].label[:],slot.label)
            if slot.material>=0 {slots[at].material=material_ids[slot.material]}
        }
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
        if !cooked.collides {writer_warn(w,"mesh %s: no %v collider could be made of it",mesh.name,chosen.collision)}
        geometry,collision:=cooked.geometry,cooked.collision
        desc:=asset.Mesh_Desc{
            id=id,owner=owner,geometry=geometry,slots=slots,joints=mesh.joints,skeleton=skeleton,
            colliders=collision.colliders,collision_points=collision.points,collision_indices=collision.indices,source=&import_data,
        }
        existed:=os.exists(path)
        save_zone:=zone_begin(w.options,"mesh.save")
        saved:=asset.mesh_save(path,&w.types,desc)
        base.profile_end(save_zone)
        if saved==.None {record(w,id,asset.KIND_MESH,mesh.name,path,source,existed,mesh_detail(geometry.levels,collision.colliders,len(collision.points),len(collision.indices)))}
        if cooked==&own {cooked_mesh_destroy(&own)}
        if saved!=.None {return save_failed(w,saved,path)}
    }
    if len(model.animations)>0 {
        part:=&parts[animation]
        import_data:=import_info(source,name,0,model.source_size,model.source_hash,0,model.version)
        existed:=os.exists(part.path)
        clips:=make([]asset.Animation_Clip_Desc,len(model.animations),context.temp_allocator)
        copy(clips,model.animations)
        // The file it replaces: the root a person set on a clip stays.
        previous_file:asset.Asset
        previous:asset.Animation_View
        loaded:=existed && asset.asset_load(&previous_file,part.path,context.temp_allocator)==.None
        defer if loaded {asset.asset_close(&previous_file)}
        if loaded {
            view_error:asset.Error
            previous,view_error=asset.animation_view(&previous_file,&w.types)
            if view_error==.Version {writer_warn(w,"%s is of a version this build does not read: the root bones set by hand on its clips were not kept; set them again",part.path)}
        }
        for &clip in clips {
            index:int
            clip.skeleton,index=clip_skeleton(model,clip,w.report.skeleton_ids)
            if index>=0 {clip.root=clip_root(model.skeletons[index].bones,root_bones[index],clip,previous)}
        }
        desc:=asset.Animation_Desc{id=part.id,owner=part.owner,clips=clips,source=&import_data}
        if error:=asset.animation_save(part.path,&w.types,desc);error!=.None {return save_failed(w,error,part.path)}
        w.report.animation_id=part.id
        record(w,part.id,asset.KIND_ANIMATION,name,part.path,source,existed,fmt.tprintf("%d clips",len(model.animations)))
    }
    return true
}

// Only the clips of a model, as an .anim of its own bound to a skeleton the project has
// (Import_Settings.skeleton): the motion of another file onto a character imported before. Each clip
// keeps the root the model's own skeleton gives it, and the root a person set on the .anim it
// replaces. A clip that moves no bone at all (its markers alone, or curves) goes on that skeleton as
// well: only one whose bones the skeleton lacks is refused.
@(private="file")
write_clips_onto :: proc(w:^Writer,model:^Imported_Model,source,name:string,skeleton:base.Asset_Id) -> bool {
    if len(model.animations)==0 {return writer_fail(w,.Malformed,"%s has no clips to put on the skeleton of Import_Settings.skeleton",source)}
    parts:=[1]Part{{kind=asset.KIND_ANIMATION,name=name,extension=".anim"}}
    parts_plan(w,parts[:])
    part:=&parts[0]
    import_data:=import_info(source,name,0,model.source_size,model.source_hash,0,model.version)
    existed:=os.exists(part.path)
    clips:=make([]asset.Animation_Clip_Desc,len(model.animations),context.temp_allocator)
    copy(clips,model.animations)
    previous_file:asset.Asset
    previous:asset.Animation_View
    loaded:=existed && asset.asset_load(&previous_file,part.path,context.temp_allocator)==.None
    defer if loaded {asset.asset_close(&previous_file)}
    if loaded {previous,_=asset.animation_view(&previous_file,&w.types)}
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
        clip.root=clip_root(bones,skeleton_root_bone(bones,map_) if count>0 else -1,clip,previous)
    }
    desc:=asset.Animation_Desc{id=part.id,owner=part.owner,clips=clips,source=&import_data}
    if error:=asset.animation_save(part.path,&w.types,desc);error!=.None {return save_failed(w,error,part.path)}
    w.report.animation_id=part.id
    text:[base.ASSET_ID_TEXT]u8
    record(w,part.id,asset.KIND_ANIMATION,name,part.path,source,existed,fmt.tprintf("%d clips on skeleton %s",len(model.animations),base.asset_id_format(skeleton,text[:])))
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
// an Unreal skeleton, which a clamber or a jump start moves up and along). -1 when the pelvis is its
// top bone: its track is the bob of the body, which a root kept in place would flatten.
@(private="file")
skeleton_root_bone :: proc(bones:[]asset.Skeleton_Bone,map_:anim.Body_Map) -> int {
    pelvis:=int(map_.bones[.Pelvis])
    if pelvis<0 || pelvis>=len(bones) {return -1}
    parent:=int(bones[pelvis].parent)
    return parent if parent>=0 && parent<len(bones) else -1
}

// The root of a clip of the skeleton of bones: the one a person set on the clip of that name in the
// file the import replaces while its bone is still there, else its root bone with translation and
// rotation when the clip moves or turns it (a clamber, a jump start), so that a character whose
// capsule moves the body plays it in place (Root_Motion_Policy.In_Place); else none.
@(private="file")
clip_root :: proc(bones:[]asset.Skeleton_Bone,root:int,clip:asset.Animation_Clip_Desc,previous:asset.Animation_View) -> (value:asset.Animation_Root) {
    for &kept in previous.clips {
        if base.text_get(kept.name[:])!=clip.name || !kept.root.translation && !kept.root.rotation {continue}
        for &bone in bones {if bone.path==kept.root.bone {return kept.root}}
    }
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
// its sidecar keeps say otherwise. The texture is the root of the import:
// importing the file again writes the asset its sidecar lists.
import_texture :: proc(path,folder:string,options:Import_Options={},allocator:=context.allocator) -> (report:Import_Report,error:Error) {
    caller:=context.temp_allocator
    options:=options
    if !options.ignore_stored {
        stored,found,settings_error:=settings_load(path,options.root,folder)
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
    ok:=writer_init(&w,path,folder,options,&report,allocator)
    defer asset.types_destroy(&w.types)
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
            id,target:=root_take(&w,asset.KIND_TEXTURE,job.name,".tex")
            built:=write_texture(&w,job,id,{},target,source)
            if w.error.code!=.None {ok=false} else if !built {ok=writer_fail(&w,.Unsupported,"%s is not an image that can be decoded",path)}
            ok=ok && writer_finish(&w)
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

// The sockets of the file an import replaces that it does not make again (one a person or an agent
// added, such as where a weapon hangs), on a bone it still has. Those it makes (named by the
// source, bone.*, grips) are made again from the source.
@(private="file")
skeleton_sockets_kept :: proc(previous:^asset.Skeleton_View,bones:[]asset.Skeleton_Bone,sockets:^[dynamic]asset.Skeleton_Socket) {
    if previous==nil {return}
    made:=len(sockets)
    for &socket in previous.sockets {
        name:=base.text_get(socket.name[:])
        if strings.has_prefix(name,"bone.") {continue}
        again:=false
        for &other in sockets[:made] {if other.name==socket.name {again=true;break}}
        if again {continue}
        for &bone in bones {if bone.path==socket.bone {append(sockets,socket);break}}
    }
}

// The body of an imported skeleton: found on its bones, keeping the parts a
// person set in the file it replaces when their bones are still there.
// Returns how many parts it wrote, 0 for a skeleton without a body, and the map they come from.
@(private="file")
skeleton_body :: proc(previous_file:^asset.Skeleton_View,bones:[]asset.Skeleton_Bone,body:^asset.Skeleton_Body,parts:^[len(anim.Body_Part)]asset.Skeleton_Body_Part) -> (count:int,map_:anim.Body_Map) {
    previous:=anim.body_map_empty()
    if previous_file!=nil {
        previous=asset.skeleton_body_map(bones,previous_file.body,previous_file.body_parts)
        for part in anim.Body_Part {if part not_in previous.manual {previous.bones[part],previous.confidence[part]=-1,0}}
    }
    found:bool
    map_,found=asset.skeleton_body_detect(bones,previous)
    if !found {return 0,map_}
    count,_=asset.skeleton_body_rows(bones,map_,body,parts)
    return count,map_
}
