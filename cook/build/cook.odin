package build

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "compressor:data"
import "compressor:blocks"
import "mirai:asset"
import "mirai:cook/far"
import anim "mirai:std/anim"
import "mirai:cook/textures"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"
import "mirai:std/subprocess"

// The assets a game ships: of the assets folder of a project, the ones the
// game can reach, as the runtime loads them fastest.
//
// What is reached starts at the roots: every scene, every prefab (code reaches
// one only by instantiating it), every table of game data (.records, which
// the code reads by the type of its rows) and every .strings (whose keys
// interfaces, rows and code show) of the project and what cook.mirai
// names, the other assets only code refers to. From them, everything an
// asset depends on, and so on. The rest stays behind and is listed in the
// report. A texture that stores RGBA8 is written in the blocks of its use,
// unless only interfaces show it, and the blocks are kept in the texture
// cache for the next cook; a texture the editor imported Fast is encoded
// again as Final from its source, which the cook imports again; a scene or prefab with a stale prefab
// instance is written with its instances brought up to date, so a shipped
// game loads them as they are; every other file is copied byte for byte.
// With far, every scene a section references gets its far mesh beside it
// (cook/far), which the game shows while the section is not loaded. A mesh
// without colliders of its source that a scene or prefab moves with an Auto
// Collider is written with the convex pieces it collides as
// (host.assets_collision_pieces_file, kept in the collision cache), which a
// shipped game reads and never makes. The
// folder gets a packed index, so the game does not look at its files to
// know what they are, and everything written is read back and checked.

COOK_FILE :: "cook.mirai"

Cook_Textures :: enum u8 {
    Blocks, // a texture that stores RGBA8 is compressed by its use
    Keep,   // textures are copied as they are
}

Cook_Desc :: struct {
    assets:string,   // the assets folder of the project
    output:string,   // the assets folder of the shipped game: it ends up holding what was cooked and nothing else
    manifest:string, // the cook.mirai of the project. "", or a file that does not exist: the scenes are the only roots
    plugins:[]project.Asset_Folder, // the assets of active plugins: every file a root, cooked under its prefix
    texture_cache:string, // folder of compressed textures kept by content (textures.cache_read); "": none
    mesh_cache:string,    // folder of the meshes an import keeps (cook/import Import_Options); "": none
    collision_cache:string, // folder of the convex pieces of meshes kept by content (host.assets_collision_pieces_file); "": none
    codecs:asset.Codecs, // what the project ships with (build.compression)
    root:string,          // of the project: the sources of imported assets are named relative to it. "": the folder of assets
    worker:jobs.Worker_Ref, // where the files are cooked, in parallel on its system. No system: a system of the cook, a thread per core
    server:bool, // for a dedicated server: what is only shown or heard (asset.Kind_Info.presentation) stays behind, and is not missing
    quick:bool,  // a cook that checks a change (a dev game): the profile Balanced in place of Ultra
    far:bool,    // the far meshes of the scenes sections reference: the game streams sections (plugin streaming)
    keys:string, // the file where the cook keeps what each file it wrote was made of: a later cook writes again only what changed. "": every file
    allocator:runtime.Allocator, // of the report. Unset: context.allocator
}

// How hard the assets of a cook are compressed.
@(private="file")
cook_profile :: proc(desc:Cook_Desc) -> data.Profile {return .Balanced if desc.quick else .Ultra}

Cook_Error :: enum u8 {
    None,
    Assets_Missing,   // the assets folder cannot be read
    Manifest_Invalid, // detail: what is wrong with cook.mirai
    Root_Missing,     // detail: the root that names no file of the assets
    Read_Failed,      // detail: the file
    Write_Failed,     // detail: the file
    Verify_Failed,    // detail: the file that does not read back as what was written
    Resolve_Failed,   // detail: the scene or prefab whose prefab instances could not be brought up to date
    Source_Failed,    // detail: the texture that is still Fast, which the import of its source by a build makes Final
    Duplicate_Id,     // detail: the two files with one id and how to tell them apart
}

Cook_File :: struct {
    path:string, // from the assets folder
    id:base.Asset_Id, // zero for a file that is not an asset
    kind:asset.Fourcc,
    source_bytes,bytes:i64,
    compressed:bool,  // a texture that was RGBA8 and is blocks now, or an animation that is sampled
    resolved:bool,    // a scene or prefab whose stale prefab instances follow their prefabs now
    reused:bool,      // written by an earlier cook from what it is made of now, and left as it was
}

Cook_Dropped :: struct {
    path:string,
    bytes:i64,
    asset:bool, // false: a file of the folder that is not an asset
    shown:bool, // only shown or heard: a dedicated server leaves it behind, reached or not
}

Cook_Missing :: struct {
    path:string,      // the asset that names it
    id:base.Asset_Id, // a dependency no file of the assets is
}

// Everything it points to is in the allocator of the description.
Cook_Report :: struct {
    error:Cook_Error,
    detail:string,
    roots:int,                // files the cook started from
    files:[]Cook_File,        // what the output holds, by path
    dropped:[]Cook_Dropped,   // what stayed behind, by path
    missing:[]Cook_Missing,
    removed:int,              // files of an earlier cook that the output no longer has
    textures_compressed:int,
    animations_compressed:int,
    scenes_resolved:int,      // scenes and prefabs written with their prefab instances up to date
    reparented:int,           // entities those scenes added under members their prefabs removed, now under the nearest member left
    reused:int,               // files an earlier cook wrote from what they are made of now, left as they were
    far_meshes:int,           // far meshes written beside the scenes sections reference
    source_bytes:i64,         // of the whole assets folder
    output_bytes:i64,         // of what was written, with the index
    seconds:f64,
}

@(private="file")
Cook_Manifest :: struct {
    roots:[]string,
    textures:Cook_Textures,
}

@(private="file")
manifest_read :: proc(path:string,allocator:runtime.Allocator) -> (manifest:Cook_Manifest,problem:string) {
    if path=="" || !os.exists(path) {return}
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return {},"it cannot be read"}
    value,parse_error:=json.parse(data,parse_integers=true,allocator=context.temp_allocator)
    object,is_object:=value.(json.Object)
    if parse_error!=.None || !is_object {return {},"it is not a JSON object"}
    roots:=make([dynamic]string,allocator)
    for key,member in object {
        switch key {
        case "roots":
            list,is_list:=member.(json.Array)
            if !is_list {return {},"roots is a list of paths and ids"}
            for entry in list {
                text,is_text:=entry.(json.String)
                if !is_text || text=="" {return {},"roots is a list of paths and ids"}
                append(&roots,strings.clone(text,allocator))
            }
        case "textures":
            switch member.(json.String) or_else "" {
            case "blocks": manifest.textures=.Blocks
            case "keep":   manifest.textures=.Keep
            case: return {},"textures is \"blocks\" or \"keep\""
            }
        case:
            return {},fmt.aprintf("%s is not a setting of a cook",key,allocator=allocator)
        }
    }
    manifest.roots=roots[:]
    return
}

@(private="file")
cook_fail :: proc(report:^Cook_Report,error:Cook_Error,detail:string,allocator:runtime.Allocator) {
    report.error,report.detail=error,strings.clone(detail,allocator)
}

// Cooks the assets of a project into the folder a game ships them in. On an
// error the output may hold part of the cook, without an index.
cook_assets :: proc(desc:Cook_Desc) -> (report:Cook_Report) {
    // Set after the cook: a defer does not reach the result it returns.
    start:=time.tick_now()
    report=cook_run(desc)
    report.seconds=time.duration_seconds(time.tick_since(start))
    return
}

@(private="file")
cook_run :: proc(desc:Cook_Desc) -> (report:Cook_Report) {
    allocator:=desc.allocator.procedure!=nil?desc.allocator:context.allocator
    temp:=context.temp_allocator
    manifest,problem:=manifest_read(desc.manifest,temp)
    if problem!="" {cook_fail(&report,.Manifest_Invalid,problem,allocator);return}

    registry:asset.Registry
    asset.registry_init(&registry,desc.assets,"",temp,desc.root!=""?project.imported_path(desc.root,temp):"")
    for folder in desc.plugins {asset.registry_mount(&registry,folder.path,folder.prefix,folder.imported)}
    defer asset.registry_destroy(&registry)
    if asset.registry_scan(&registry)!=.None {cook_fail(&report,.Assets_Missing,desc.assets,allocator);return}
    files:=registry.files[:]
    // Which of two files with one id is the asset depends on the machine: the cook takes neither.
    if len(registry.duplicates)>0 {
        twins:=registry.duplicates[0]
        cook_fail(&report,.Duplicate_Id,fmt.tprintf("%s and %s have one id; open the project in the editor, which gives the copy an id of its own",files[twins.first].path,files[twins.second].path),allocator)
        return
    }
    reached:=make([]bool,len(files),temp)
    // What a dedicated server leaves behind counts as reached, and is not written.
    left:=make([]bool,len(files),temp)
    if desc.server {
        for file,at in files {
            if info,known:=asset.kind_info(file.kind);file.state==.Asset && known && info.presentation {reached[at],left[at]=true,true}
        }
    }
    pending:=make([dynamic]u32,temp)
    root_add :: proc(reached:[]bool,pending:^[dynamic]u32,report:^Cook_Report,at:u32) {
        if reached[at] {return}
        reached[at]=true
        report.roots+=1
        append(pending,at)
    }
    for file,at in files {
        if file.state==.Asset && (file.kind==asset.KIND_SCENE || file.kind==asset.KIND_RECORDS || file.kind==asset.KIND_STRINGS) {root_add(reached,&pending,&report,u32(at))}
        // What a plugin brings is for its code, which no scene names; its sources
        // (a file with a sidecar beside it) and their sidecars stay behind.
        source:=strings.has_suffix(file.path,asset.SIDECAR_EXTENSION) || strings.concatenate({file.path,asset.SIDECAR_EXTENSION},temp) in registry.by_path
        for folder in desc.plugins {
            if !source && strings.has_prefix(file.path,folder.prefix) && len(file.path)>len(folder.prefix) && file.path[len(folder.prefix)]=='/' {root_add(reached,&pending,&report,u32(at))}
        }
    }
    for root in manifest.roots {
        named:=false
        if id,is_id:=serial.text_parse_asset_id(root);is_id {
            if at,found:=registry.by_id[id];found {
                root_add(reached,&pending,&report,at)
                named=true
            }
        } else if strings.has_suffix(root,"/") {
            for file,at in files {
                if file.state==.Asset && strings.has_prefix(file.path,root) {
                    root_add(reached,&pending,&report,u32(at))
                    named=true
                }
            }
        } else if at,found:=registry.by_path[root];found {
            root_add(reached,&pending,&report,at)
            named=true
        }
        if !named {cook_fail(&report,.Root_Missing,root,allocator);return}
    }
    missing:=make([dynamic]Cook_Missing,allocator)
    // Whether something that is cooked depends on a file: an interface, or anything else.
    shown:=make([]bool,len(files),temp)
    drawn:=make([]bool,len(files),temp)
    for len(pending)>0 {
        at:=pop(&pending)
        file:=&files[at]
        if file.state!=.Asset {continue}
        for id in asset.registry_dependencies(&registry,file) {
            needed,found:=registry.by_id[id]
            if !found {
                append(&missing,Cook_Missing{strings.clone(file.path,allocator),id})
                continue
            }
            if file.kind==asset.KIND_UI {shown[needed]=true} else {drawn[needed]=true}
            if !reached[needed] {
                reached[needed]=true
                append(&pending,needed)
            }
        }
    }
    report.missing=missing[:]

    if os.make_directory_all(desc.output)!=nil && !os.is_dir(desc.output) {cook_fail(&report,.Write_Failed,desc.output,allocator);return}
    // The index of an earlier cook goes first: one that fails leaves none over half of its files.
    index:=fmt.tprintf("%s/%s",desc.output,asset.REGISTRY_INDEX)
    if os.exists(index) && os.remove(index)!=nil {cook_fail(&report,.Write_Failed,asset.REGISTRY_INDEX,allocator);return}

    own:jobs.Job_System
    on:=desc.worker
    if on.system==nil {
        if !jobs.system_init(&own,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) && !jobs.system_init(&own,{allocator=runtime.heap_allocator()}) {cook_fail(&report,.Write_Failed,desc.output,allocator);return}
        on={system=&own,worker=jobs.OWNER}
    }
    defer if on.system==&own {jobs.system_destroy(&own)}
    work:=Cook_Work{
        desc=desc,registry=&registry,files=files,textures=manifest.textures,drawn=drawn,shown=shown,pieces=pieces_wanted(&registry,reached,left,temp),
        on=on,allocator=on.system.allocator,first_error=len(files),
        results=make([]Cook_Result,len(files),temp),
        types=make([]asset.Types,jobs.worker_count(on.system),temp),
    }
    defer work_destroy(&work)
    asset.types_init(&work.resolver_types,work.allocator)
    asset.registry_prefabs_init(&work.prefabs,&registry,work.allocator)
    asset.resolver_init(&work.resolver,&work.resolver_types,asset.registry_prefab_files(&work.prefabs),work.allocator)
    work.cached.allocator=work.allocator
    order:=make([dynamic]Cook_Order,temp)
    probed:=make([dynamic]u32,temp)
    for file,at in files {
        if !reached[at] || left[at] {continue}
        append(&order,Cook_Order{file.size,u32(at)})
        if file.state==.Asset && file.kind==asset.KIND_TEXTURE {append(&probed,u32(at))}
    }
    // The largest first, so that no worker starts a long file when the others are done.
    slice.sort_by(order[:],proc(a,b:Cook_Order) -> bool {return a.bytes>b.bytes || a.bytes==b.bytes && a.at<b.at})
    work.order,work.probed=order[:],probed[:]
    keys_reuse(&work)

    jobs.parallel_for(on.system,on.worker,len(work.probed),1,texture_probe,&work)
    jobs.parallel_for(on.system,on.worker,len(work.order),1,files_cook,&work)

    // The report is the one of a cook on one thread: the first file that failed, by path, and the rest by path.
    written:=make([dynamic]Cook_File,allocator)
    dropped:=make([dynamic]Cook_Dropped,allocator)
    for &file,at in files {
        report.source_bytes+=file.size
        if !reached[at] || left[at] {
            append(&dropped,Cook_Dropped{strings.clone(file.path,allocator),file.size,file.state==.Asset,left[at]})
            continue
        }
        result:=&work.results[at]
        if result.error!=.None {cook_fail(&report,result.error,result.detail,allocator);return}
        entry:=result.entry
        entry.path=strings.clone(file.path,allocator)
        if entry.reused {report.reused+=1}
        if entry.compressed {
            if entry.kind==asset.KIND_ANIMATION {report.animations_compressed+=1} else {report.textures_compressed+=1}
        }
        if entry.resolved {report.scenes_resolved+=1}
        report.output_bytes+=entry.bytes
        append(&written,entry)
    }
    if desc.far {
        made,error,detail:=far_meshes_cook(&work,reached,left,allocator)
        if error!=.None {cook_fail(&report,error,detail,allocator);return}
        append(&written,..made)
        report.far_meshes=len(made)
        for entry in made {report.output_bytes,report.reused=report.output_bytes+entry.bytes,report.reused+int(entry.reused)}
        slice.sort_by(written[:],proc(a,b:Cook_File) -> bool {return a.path<b.path})
    }
    report.files,report.dropped,report.reparented=written[:],dropped[:],work.resolver.reparented

    // The output is what was cooked: what an earlier cook left and this one did not write goes.
    cooked:asset.Registry
    asset.registry_init(&cooked,desc.output,"",temp)
    defer asset.registry_destroy(&cooked)
    if asset.registry_scan(&cooked)!=.None {cook_fail(&report,.Write_Failed,desc.output,allocator);return}
    stale:=false
    for file in cooked.files {
        if _,kept:=slice.binary_search_by(report.files,file.path,proc(entry:Cook_File,path:string) -> slice.Ordering {return entry.path<path?.Less:entry.path>path?.Greater:.Equal});kept {continue}
        if os.remove(fmt.tprintf("%s/%s",desc.output,file.path))!=nil {cook_fail(&report,.Write_Failed,file.path,allocator);return}
        report.removed+=1
        stale=true
    }
    if stale && asset.registry_scan(&cooked)!=.None {cook_fail(&report,.Write_Failed,desc.output,allocator);return}
    if !asset.registry_save(&cooked,index) {cook_fail(&report,.Write_Failed,asset.REGISTRY_INDEX,allocator);return}
    keys_write(&work)
    if info,stat_error:=os.stat(index,temp);stat_error==nil {report.output_bytes+=info.size}
    return
}

// What the workers of a cook share. Each file has its result, which only the
// worker that cooks it writes; what several files use is behind a lock.
@(private="file")
Cook_Work :: struct {
    desc:Cook_Desc,
    registry:^asset.Registry,
    files:[]asset.Registry_File,
    textures:Cook_Textures,
    drawn,shown:[]bool,
    pieces:[]bool, // a mesh written with the convex pieces a moving body collides as
    on:jobs.Worker_Ref,
    allocator:runtime.Allocator, // of the job system: every worker can call it
    order:[]Cook_Order,    // the files to write
    probed:[]u32,          // the textures among them, by path
    results:[]Cook_Result, // by file
    types:[]asset.Types,   // of each worker, made when it first needs them
    first_error:int,       // the first file, by path, that failed; len(files): none
    resolve:sync.Mutex,    // over the resolver, its types and its prefabs
    resolver:asset.Prefab_Resolver,
    resolver_types:asset.Types,
    prefabs:asset.Registry_Prefabs,
    cache:sync.Mutex,      // over the writes of the texture cache and cached
    cached:map[u64]struct{}, // the keys this cook wrote into the texture cache
    previous:map[string]Cook_Key, // what an earlier cook wrote, by path in the output
    far_keys:[dynamic]Far_Key,    // of the far meshes this cook shipped
}

@(private="file")
Cook_Order :: struct {bytes:i64,at:u32}

@(private="file")
Cook_Result :: struct {
    entry:Cook_File, // without its path
    key:u64,         // of what the file is made of (cook_key)
    error:Cook_Error,
    detail:string,   // in the allocator of the work
    problem:string,  // of a texture: why it cannot be shipped; in the allocator of the work
}

@(private="file")
work_destroy :: proc(work:^Cook_Work) {
    for &types in work.types {
        if types.allocator.procedure!=nil {asset.types_destroy(&types)}
    }
    asset.resolver_destroy(&work.resolver)
    asset.registry_prefabs_destroy(&work.prefabs)
    asset.types_destroy(&work.resolver_types)
    delete(work.cached)
    for result in work.results {
        delete(result.detail,work.allocator)
        delete(result.problem,work.allocator)
    }
}

@(private="file")
work_text :: proc(work:^Cook_Work,format:string,args:..any) -> string {
    return fmt.aprintf(format,..args,allocator=work.allocator)
}

@(private="file")
work_types :: proc(work:^Cook_Work,worker:int) -> ^asset.Types {
    types:=&work.types[worker]
    if types.allocator.procedure==nil {
        asset.types_init(types,work.allocator)
        types.codecs=work.desc.codecs
    }
    return types
}

// A texture still built Fast is not shipped: the imports of the editor build one so until its
// Final is there, and the sync before the cook builds every one Final.
@(private="file")
texture_probe :: proc(work:^Cook_Work,first,last:int,worker:int) {
    context.allocator=work.allocator
    types:=work_types(work,worker)
    for at in work.probed[first:last] {
        result:=&work.results[at]
        if result.entry.reused {continue}
        file:asset.Asset
        if asset.asset_load(&file,asset.registry_file_path(work.registry,work.files[at].path,context.temp_allocator),context.temp_allocator)!=.None {
            result.problem=work_text(work,"it cannot be read")
            continue
        }
        defer asset.asset_close(&file)
        view,error:=asset.texture_view(&file,types)
        if error!=.None || .Fast not_in view.info.flags {continue}
        named:=view.source!=nil?base.text_get(view.source.source[:]):"a source it does not name"
        result.problem=work_text(work,"it was imported Fast and %s was not imported again as Final: `mirai build game` does it before it cooks",named)
    }
}

@(private="file")
files_cook :: proc(work:^Cook_Work,first,last:int,worker:int) {
    context.allocator=work.allocator
    for order in work.order[first:last] {
        at:=int(order.at)
        // A file after one that failed is not needed: the cook reports the first.
        if at>intrinsics.atomic_load(&work.first_error) {continue}
        result:=&work.results[at]
        if result.entry.reused {continue}
        result.error,result.detail=file_cook(work,at,worker,&result.entry)
        if result.error==.None {continue}
        failed:=intrinsics.atomic_load(&work.first_error)
        for at<failed {
            seen,exchanged:=intrinsics.atomic_compare_exchange_weak(&work.first_error,failed,at)
            if exchanged {break}
            failed=seen
        }
    }
}

// Writes a file into the output, read back and checked; detail is in the
// allocator of the work.
@(private="file")
file_cook :: proc(work:^Cook_Work,at:int,worker:int,entry:^Cook_File) -> (error:Cook_Error,detail:string) {
    file:=&work.files[at]
    types:=work_types(work,worker)
    source:=asset.registry_file_path(work.registry,file.path,context.temp_allocator)
    target:=fmt.tprintf("%s/%s",work.desc.output,file.path)
    if slash:=strings.last_index_byte(target,'/');slash>=0 {
        if os.make_directory_all(target[:slash])!=nil && !os.is_dir(target[:slash]) {return .Write_Failed,work_text(work,"%s",file.path)}
    }
    entry.source_bytes=file.size
    if file.state==.Asset {entry.id,entry.kind=file.id,file.kind}
    if file.state==.Asset && file.kind==asset.KIND_TEXTURE {
        if problem:=work.results[at].problem;problem!="" {return .Source_Failed,work_text(work,"%s: %s",file.path,problem)}
    }
    // A texture only interfaces show stays as it is: they draw it texel for texel.
    if file.state==.Asset && file.kind==asset.KIND_TEXTURE && work.textures==.Blocks && (work.drawn[at] || !work.shown[at]) {
        compressed,cooked:=texture_cook(work,source,target,types,jobs.worker_ref_at(work.on,worker))
        if !cooked {return .Write_Failed,work_text(work,"%s",file.path)}
        entry.compressed=compressed
    }
    if file.state==.Asset && file.kind==asset.KIND_ANIMATION {
        compressed,cooked:=animation_cook(work,source,target,types)
        if !cooked {return .Write_Failed,work_text(work,"%s",file.path)}
        entry.compressed=compressed
    }
    // Any other texture is written again with its blocks laid out as the project ships them.
    laid:=!entry.compressed && file.state==.Asset && file.kind==asset.KIND_TEXTURE
    if laid && !texture_lay(work,source,target,types) {return .Write_Failed,work_text(work,"%s",file.path)}
    if !entry.compressed && !laid {
        data,read_error:=serial.file_read(source,context.temp_allocator)
        if read_error!=.None {return .Read_Failed,work_text(work,"%s",file.path)}
        if file.state==.Asset && (file.kind==asset.KIND_SCENE) {
            sync.mutex_lock(&work.resolve)
            resolved,resolve_ok:=scene_cook(&work.resolver,&work.resolver_types,data)
            sync.mutex_unlock(&work.resolve)
            if !resolve_ok {return .Resolve_Failed,work_text(work,"%s",file.path)}
            if resolved!=nil {data,entry.resolved=resolved,true}
        }
        if file.state==.Asset && file.kind==asset.KIND_MESH && work.pieces[at] {
            pieced,made:=mesh_pieces_cook(work,source,data,types)
            if !made {return .Write_Failed,work_text(work,"%s: its convex pieces could not be written",file.path)}
            data=pieced
        }
        if file.state==.Asset {
            repacked,repack_error:=asset.document_repack(data,cook_profile(work.desc),work.desc.codecs,context.temp_allocator,jobs.worker_ref_at(work.on,worker))
            if repack_error!=.None {return .Write_Failed,work_text(work,"%s",file.path)}
            data=repacked
        }
        if os.write_entire_file(target,data)!=nil {return .Write_Failed,work_text(work,"%s",file.path)}
        delete(data,context.temp_allocator)
    }
    // What was written reads back whole, as the asset it was.
    if file.state==.Asset {
        check:asset.Asset
        if asset.asset_load(&check,target,context.temp_allocator)!=.None {return .Verify_Failed,work_text(work,"%s",file.path)}
        valid:=asset.blob_verify_hash(&check.blob) && check.blob.header.id==file.id && check.blob.header.kind==file.kind
        asset.asset_close(&check)
        if !valid {return .Verify_Failed,work_text(work,"%s",file.path)}
    }
    if info,stat_error:=os.stat(target,context.temp_allocator);stat_error==nil {entry.bytes=info.size}
    return .None,""
}

// Raise it when the cook writes a file otherwise from the same inputs: every key changes.
@(private="file")
COOK_KEYS_VERSION :: 1

// What an earlier cook wrote of a file: the key of what it was made of, and the output as it left it.
@(private="file")
Cook_Key :: struct {key:u64,bytes,time:i64,compressed,resolved:bool}

// What a file of the output is made of: how the cook writes it, the file and, for an asset,
// every asset it needs, by content.
@(private="file")
cook_key :: proc(work:^Cook_Work,at:int,closure:^[dynamic]u32,far:=false) -> u64 {
    file:=&work.files[at]
    key:=base.hash_combine(COOK_KEYS_VERSION,u64(work.desc.quick)|u64(work.textures)<<1|u64(work.drawn[at])<<8|u64(work.shown[at])<<9|u64(far)<<10|u64(work.pieces[at])<<11)
    key=base.hash_combine(key,base.hash_combine(u64(work.desc.codecs),base.hash_combine(base.name_hash(data.NAME),base.name_hash(blocks.NAME))))
    if file.state!=.Asset {return base.hash_combine(base.hash_combine(key,u64(file.size)),u64(file.time))}
    key=base.hash_combine(key,file.content_hash)
    asset.registry_closure(work.registry,file.id,closure)
    for needed in closure^ {key=base.hash_combine(key,work.files[needed].content_hash)}
    return key
}

// Marks the files whose output an earlier cook wrote from what they are made of now and that
// are as it left them: the workers neither read nor write them.
@(private="file")
keys_reuse :: proc(work:^Cook_Work) {
    previous:=make(map[string]Cook_Key,context.temp_allocator)
    work.previous=previous
    work.far_keys=make([dynamic]Far_Key,context.temp_allocator)
    if data,error:=serial.file_read(work.desc.keys,context.temp_allocator);work.desc.keys!="" && error==.None {
        r:=serial.reader_init(data)
        count:=serial.read_varint(&r)==COOK_KEYS_VERSION?serial.read_count(&r,11):0
        for _ in 0..<count {
            path:=serial.read_string(&r)
            entry:=Cook_Key{key=serial.read_u64(&r),bytes=i64(serial.read_varint(&r)),time=i64(serial.read_u64(&r))}
            flags:=serial.read_u8(&r)
            entry.compressed,entry.resolved=flags&1!=0,flags&2!=0
            if r.failed {break}
            work.previous[path]=entry
        }
    }
    closure:=make([dynamic]u32,context.temp_allocator)
    for order in work.order {
        at:=int(order.at)
        file:=&work.files[at]
        result:=&work.results[at]
        result.key=cook_key(work,at,&closure)
        old,kept:=output_kept(work,file.path,result.key)
        if !kept {continue}
        result.entry={source_bytes=file.size,bytes=old.bytes,compressed=old.compressed,resolved=old.resolved,reused=true}
        if file.state==.Asset {result.entry.id,result.entry.kind=file.id,file.kind}
    }
}

// What an earlier cook wrote at a path of the output, when it was made of what key says and is
// as it left it.
@(private="file")
output_kept :: proc(work:^Cook_Work,path:string,key:u64) -> (old:Cook_Key,kept:bool) {
    old=work.previous[path] or_return
    info,error:=os.stat(fmt.tprintf("%s/%s",work.desc.output,path),context.temp_allocator)
    return old,old.key==key && error==nil && info.type==.Regular && info.size==old.bytes && time.time_to_unix_nano(info.modification_time)==old.time
}

@(private="file")
Far_Key :: struct {path:string,key:u64}

// Keeps the key of every file of a cook that succeeded, with its output as it is now.
@(private="file")
keys_write :: proc(work:^Cook_Work) {
    if work.desc.keys=="" {return}
    w:serial.Writer;serial.writer_init(&w,allocator=context.temp_allocator)
    serial.write_varint(&w,COOK_KEYS_VERSION)
    serial.write_varint(&w,u64(len(work.order)+len(work.far_keys)))
    entry :: proc(w:^serial.Writer,work:^Cook_Work,path:string,key:u64,flags:u8) {
        info,_:=os.stat(fmt.tprintf("%s/%s",work.desc.output,path),context.temp_allocator)
        serial.write_string(w,path)
        serial.write_u64(w,key)
        serial.write_varint(w,u64(max(info.size,0)))
        serial.write_u64(w,u64(time.time_to_unix_nano(info.modification_time)))
        serial.write_u8(w,flags)
    }
    for order in work.order {
        result:=&work.results[order.at]
        entry(&w,work,work.files[order.at].path,result.key,u8(result.entry.compressed)|u8(result.entry.resolved)<<1)
    }
    for far in work.far_keys {entry(&w,work,far.path,far.key,0)}
    _=serial.file_write_atomic(work.desc.keys,serial.writer_bytes(&w))
}

// The far mesh of each scene a cooked scene references, written beside it
// (<scene>.far.mesh, far.far_mesh_id) and read back; one without static
// meshes has none.
@(private="file")
far_meshes_cook :: proc(work:^Cook_Work,reached,left:[]bool,allocator:runtime.Allocator) -> (made:[]Cook_File,error:Cook_Error,detail:string) {
    scenes:=make([dynamic]base.Asset_Id,context.temp_allocator)
    types:=work_types(work,0)
    for file,at in work.files {
        if !reached[at] || left[at] || file.state!=.Asset || file.kind!=asset.KIND_SCENE {continue}
        source:asset.Asset
        if asset.asset_load(&source,asset.registry_file_path(work.registry,file.path,context.temp_allocator),context.temp_allocator)!=.None {return nil,.Read_Failed,strings.clone(file.path,allocator)}
        far.far_scenes(&source,types,&scenes)
        asset.asset_close(&source)
    }
    Far_Work :: struct {work:^Cook_Work,scenes:[]base.Asset_Id,entries:[]Cook_File,errors:[]Cook_Error}
    fw:=Far_Work{work=work,scenes=scenes[:],entries=make([]Cook_File,len(scenes),context.temp_allocator),errors=make([]Cook_Error,len(scenes),context.temp_allocator)}
    // A far mesh is made of its scene and what that needs: one an earlier cook made of the same is kept.
    keys:=make([]u64,len(scenes),context.temp_allocator)
    closure:=make([dynamic]u32,context.temp_allocator)
    for id,at in scenes {
        record,found:=asset.registry_find(work.registry,id)
        if !found {continue}
        path:=strings.concatenate({strings.trim_suffix(record.path,".scene"),far.FAR_EXTENSION},context.temp_allocator)
        keys[at]=cook_key(work,int(work.registry.by_id[id]),&closure,far=true)
        if old,kept:=output_kept(work,path,keys[at]);kept {fw.entries[at]={path=strings.clone(path,work.allocator),id=asset.far_mesh_id(id),kind=asset.KIND_MESH,bytes=old.bytes,reused=true}}
    }
    each :: proc(fw:^Far_Work,first,last:int,worker:int) {
        context.allocator=fw.work.allocator
        for at in first..<last {
            id:=fw.scenes[at]
            if fw.entries[at].reused {continue}
            record,found:=asset.registry_find(fw.work.registry,id)
            if !found {continue}
            g:asset.Mesh_Geometry
            if !far.far_cook(fw.work.registry,id,&g,context.temp_allocator) {continue}
            path:=strings.concatenate({strings.trim_suffix(record.path,".scene"),far.FAR_EXTENSION},context.temp_allocator)
            target:=fmt.tprintf("%s/%s",fw.work.desc.output,path)
            types:=work_types(fw.work,worker)
            mesh:=asset.far_mesh_id(id)
            if asset.mesh_save(target,types,{id=mesh,geometry=g},context.temp_allocator)!=.None {
                fw.entries[at].path,fw.errors[at]=strings.clone(path,fw.work.allocator),.Write_Failed
                continue
            }
            check:asset.Asset
            if asset.asset_load(&check,target,context.temp_allocator)!=.None || !asset.blob_verify_hash(&check.blob) || check.blob.header.id!=mesh {fw.errors[at]=.Verify_Failed}
            asset.asset_close(&check)
            fw.entries[at]={path=strings.clone(path,fw.work.allocator),id=mesh,kind=asset.KIND_MESH}
            if info,stat_error:=os.stat(target,context.temp_allocator);stat_error==nil {fw.entries[at].bytes=info.size}
        }
    }
    jobs.parallel_for(work.on.system,work.on.worker,len(scenes),1,each,&fw)
    out:=make([dynamic]Cook_File,allocator)
    defer for entry in fw.entries {delete(entry.path,work.allocator)}
    for entry,at in fw.entries {
        if entry.path!="" && fw.errors[at]==.None {append(&work.far_keys,Far_Key{strings.clone(entry.path,context.temp_allocator),keys[at]})}
        if fw.errors[at]!=.None {return nil,fw.errors[at],strings.clone(entry.path,allocator)}
        if entry.path=="" {continue}
        kept:=entry
        kept.path=strings.clone(entry.path,allocator)
        append(&out,kept)
    }
    return out[:],.None,""
}

// Writes a texture that stores RGBA8 as blocks, the ones the cache keeps for
// its content or new ones; compressed is false, with nothing written, for one
// that is blocks already. ok is false when it cannot be read or written.
@(private="file")
texture_cook :: proc(work:^Cook_Work,source,target:string,types:^asset.Types,worker:jobs.Worker_Ref) -> (compressed,ok:bool) {
    file:asset.Asset
    if asset.asset_load(&file,source,context.temp_allocator)!=.None {return}
    defer asset.asset_close(&file)
    view,error:=asset.texture_view(&file,types)
    if error!=.None {return}
    if view.info.format!=.RGBA8 {return false,true}
    cache:=work.desc.texture_cache
    // Blocks that nothing compresses keep the least error.
    rdo:=work.desc.codecs!=.None
    key:=textures.cache_key_blocks(file.blob.header.content_hash,rdo)
    built,cached:=textures.cache_read(cache,key,types,context.temp_allocator)
    if !cached {
        built_ok:bool
        if built,built_ok=textures.blocks_of(view,context.temp_allocator,worker,rdo);!built_ok {return}
        // Textures of one content build the same blocks: the first to get here keeps them.
        if cache!="" {
            sync.mutex_lock(&work.cache)
            if key not_in work.cached {
                work.cached[key]={}
                textures.cache_write(cache,key,types,&built)
            }
            sync.mutex_unlock(&work.cache)
        }
    }
    defer textures.built_destroy(&built)
    return true,asset.texture_save(target,types,textures.built_desc(&built,file.blob.header.id,view.source,work.desc.codecs==.Best),profile=cook_profile(work.desc))==.None
}

// Writes a texture with the blocks it stores, laid out and compressed as the project ships them.
@(private="file")
texture_lay :: proc(work:^Cook_Work,source,target:string,types:^asset.Types) -> bool {
    file:asset.Asset
    if asset.asset_load(&file,source,context.temp_allocator)!=.None {return false}
    defer asset.asset_close(&file)
    view,error:=asset.texture_view(&file,types)
    if error!=.None {return false}
    info:=view.info
    mips:=make([][]u8,len(view.mips),context.temp_allocator)
    for _,level in view.mips {mips[level]=asset.texture_mip(view,level)}
    built:=textures.Built{width=int(info.width),height=int(info.height),layers=int(info.layers),format=info.format,flags=info.flags,alpha_coverage=info.alpha_coverage,mips=mips}
    desc:=textures.built_desc(&built,file.blob.header.id,view.source,work.desc.codecs==.Best)
    desc.owner=file.blob.header.owner
    doc:asset.Document
    if asset.texture_document(&doc,types,desc,context.temp_allocator)!=.None {return false}
    defer asset.document_destroy(&doc)
    doc.flags=file.blob.header.flags
    return asset.document_save(&doc,target,profile=cook_profile(work.desc))==.None
}

@(private="file")
texture_texels_entry :: proc(file:^asset.Asset) -> (entry:asset.Chunk_Entry,found:bool) {
    table,has:=asset.asset_table(file,"texels")
    if !has || len(table.columns)!=1 {return}
    return asset.blob_chunk(&file.blob,table.columns[0].chunk),true
}

// A scene or prefab with its stale prefab instances brought up to date with
// their prefabs, as the bytes of the file; nil when none is stale. ok is
// false when it cannot be read or resolved.
@(private="file")
scene_cook :: proc(resolver:^asset.Prefab_Resolver,types:^asset.Types,data:[]u8) -> (resolved:[]u8,ok:bool) {
    file:asset.Asset
    if asset.asset_open(&file,data,context.temp_allocator)!=.None {return nil,false}
    defer asset.asset_close(&file)
    if !asset.resolver_stale(resolver,&file) {return nil,resolver.error==.None}
    scene:asset.Scene
    if asset.scene_from_asset(&scene,types,&file,context.temp_allocator)!=.None {return nil,false}
    defer asset.scene_destroy(&scene)
    if _,error:=asset.scene_resolve(resolver,&scene);error!=.None {return nil,false}
    bytes,error:=asset.scene_bytes(&scene,context.temp_allocator)
    return bytes,error==.None
}

// "kept 61 of 83 files, 5.1 of 7.1 MB": the lines a build prints of a cook.
cook_summary :: proc(report:^Cook_Report,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    megabytes :: proc(bytes:i64) -> f64 {return f64(bytes)/(1<<20)}
    fmt.sbprintf(&b,"assets: %d of %d files from %d roots, %.2f MB (the folder has %.2f MB)",len(report.files),len(report.files)+len(report.dropped),report.roots,megabytes(report.output_bytes),megabytes(report.source_bytes))
    if report.textures_compressed>0 {fmt.sbprintf(&b,", %d textures compressed",report.textures_compressed)}
    if report.animations_compressed>0 {fmt.sbprintf(&b,", %d animations sampled",report.animations_compressed)}
    if report.scenes_resolved>0 {fmt.sbprintf(&b,", %d scenes and prefabs with their prefab instances brought up to date",report.scenes_resolved)}
    if report.reparented>0 {fmt.sbprintf(&b,", %d entities they added under members their prefabs removed under the nearest member left (an edit of them in the editor writes that)",report.reparented)}
    if report.removed>0 {fmt.sbprintf(&b,", %d files of an earlier cook removed",report.removed)}
    if report.reused>0 {fmt.sbprintf(&b,", %d files kept from an earlier cook: what they are made of did not change",report.reused)}
    strings.write_byte(&b,'\n')
    for shown in ([2]bool{false,true}) {
        bytes,count:=i64(0),0
        for file in report.dropped {
            if file.shown!=shown {continue}
            bytes+=file.bytes
            count+=1
        }
        if count==0 {continue}
        fmt.sbprintf(&b,shown?"left out, %.2f MB only shown or heard, which a dedicated server does not ship:\n":"left out, %.2f MB that nothing reaches:\n",megabytes(bytes))
        for file in report.dropped {
            if file.shown==shown {fmt.sbprintf(&b,"  %s (%d bytes%s)\n",file.path,file.bytes,file.asset?"":", not an asset")}
        }
    }
    buffer:[32]u8
    for lost in report.missing {fmt.sbprintf(&b,"missing: %s depends on %s, which no file is\n",lost.path,base.asset_id_format(lost.id,buffer[:]))}
    return strings.to_string(b)
}

// Writes an animation with its clips sampled as the runtime plays them
// (asset.animation_compress, on the skeletons of the registry); compressed is
// false, with nothing written, for one that is cooked already. ok is false when
// it cannot be read or written.
@(private="file")
animation_cook :: proc(work:^Cook_Work,source,target:string,types:^asset.Types) -> (compressed,ok:bool) {
    file:asset.Asset
    if asset.asset_load(&file,source,context.temp_allocator)!=.None {return}
    defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,types)
    if error!=.None {return}
    for track in view.tracks {if track.encoding!=.Raw {return false,true}}
    desc:=asset.animation_library_desc(view)
    desc.allocator=context.temp_allocator
    library:anim.Library
    if !anim.library_init(&library,desc) {return}
    defer anim.library_destroy(&library)
    if len(view.clips)>0 && asset.animation_clips_add(view,&library)==0 {return}
    if _,compressing:=asset.animation_compress(view,&library,types,asset.skeleton_open_registry,work.registry);compressing!=.None {return}
    doc:asset.Document
    if asset.animation_cooked_document(&doc,types,file.blob.header.id,file.blob.header.owner,view,&library,context.temp_allocator)!=.None {return}
    defer asset.document_destroy(&doc)
    doc.flags=file.blob.header.flags
    return true,asset.document_save(&doc,target,profile=cook_profile(work.desc))==.None
}

// The Collider and Rigid_Body of the physics plugin as a cook reads them from
// a scene: by the names of their fields and of the values of their enums.
@(private="file")
Cooked_Collider :: struct {kind:enum u8 {Box,Sphere,Capsule,Cylinder,Hull,Mesh,Heightfield,External,Auto}}
@(private="file")
Cooked_Body :: struct {type:enum u32 {Static,Kinematic,Dynamic}}

// The meshes, by file, that a reached scene or prefab moves with an Auto
// Collider: the Collider of an entity that shows the mesh, whose own
// Rigid_Body, or that of the nearest ancestor with one, is not Static.
@(private="file")
pieces_wanted :: proc(registry:^asset.Registry,reached,left:[]bool,allocator:runtime.Allocator) -> []bool {
    wanted:=make([]bool,len(registry.files),allocator)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    defer asset.types_destroy(&types)
    for file,at in registry.files {
        if !reached[at] || left[at] || file.state!=.Asset || file.kind!=asset.KIND_SCENE {continue}
        scene:asset.Asset
        if asset.asset_load(&scene,asset.registry_file_path(registry,file.path,context.temp_allocator),context.temp_allocator)!=.None {continue}
        defer asset.asset_close(&scene)
        view,error:=asset.scene_view(&scene,&types)
        if error!=.None {continue}
        rows_of :: proc(scene:^asset.Asset,types:^asset.Types,name:string,$T:typeid,count:int) -> []^T {
            out:=make([]^T,count,context.temp_allocator)
            entities,entities_error:=asset.asset_rows(scene,types,name,asset.COLUMN_ENTITY,u32)
            values,values_error:=asset.asset_rows(scene,types,name,asset.COLUMN_VALUE,T)
            if entities_error!=.None || values_error!=.None {return out}
            for &value,k in values[:min(len(values),len(entities))] {
                if int(entities[k])<count {out[entities[k]]=&value}
            }
            return out
        }
        count:=len(view.ids)
        colliders:=rows_of(&scene,&types,"Collider",Cooked_Collider,count)
        bodies:=rows_of(&scene,&types,"Rigid_Body",Cooked_Body,count)
        shown:=rows_of(&scene,&types,"Mesh_Renderer",render.Mesh_Renderer,count)
        row_of:=make(map[base.Entity_Id]int,context.temp_allocator)
        for id,row in view.ids {row_of[id]=row}
        for collider,row in colliders {
            if collider==nil || collider.kind!=.Auto || shown[row]==nil || shown[row].mesh=={} {continue}
            moving:=false
            for at,steps:=row,0;at>=0 && steps<=count;steps+=1 {
                if body:=bodies[at];body!=nil {
                    moving=body.type!=.Static
                    break
                }
                parent,found:=row_of[view.parents[at]]
                at=parent if found else -1
            }
            if !moving {continue}
            if mesh,known:=registry.by_id[shown[row].mesh];known {wanted[mesh]=true}
        }
    }
    return wanted
}

// A mesh file with the convex pieces a moving body collides as: what the
// collision cache keeps of it, or a decomposition of it that it keeps. The
// file as it is when it stores colliders or no piece is had.
@(private="file")
mesh_pieces_cook :: proc(work:^Cook_Work,source:string,data:[]u8,types:^asset.Types) -> (out:[]u8,ok:bool) {
    file:asset.Asset
    if asset.asset_load(&file,source,context.temp_allocator)!=.None {return}
    defer asset.asset_close(&file)
    points:=make([dynamic][3]f32,context.temp_allocator)
    sizes:=make([dynamic]u32,context.temp_allocator)
    if !host.assets_collision_pieces_file(&file,types,work.desc.collision_cache,&points,&sizes) {return data,true}
    doc:asset.Document
    if asset.document_from_asset(&doc,&file,context.temp_allocator)!=.None {return}
    defer asset.document_destroy(&doc)
    if asset.mesh_pieces_put(&doc,types,points[:],sizes[:])!=.None {return}
    bytes,error:=asset.document_bytes(&doc,context.temp_allocator)
    return bytes,error==.None
}
