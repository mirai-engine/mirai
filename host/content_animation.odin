package host

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:asset"
import anim "mirai:std/anim"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:std/serial"

// The .anim of a project keeps its keys; the runtime plays them compressed into streams
// (asset.animation_compress). A compression is kept in App.animation_cache as the cooked
// document a shipped game carries, named by the asset and by a hash of what it is made from:
// the .anim, the skeletons its clips are measured on, the container and .anim formats and the
// compressor. A load takes it from there when it is whole and holds the clips of the .anim
// (content_animation_cache_matches); else, as without a cache, it compresses in a job of
// the application (at once with fewer than two workers), and the main thread takes the library
// at the start of the frame after the job ended (app_content_adopt), writing the cache then.
// Until then the job owns what it builds: the entry keeps what it had, and one that never loaded
// is pending.

// What a load of an .anim reads and builds: between content_animation_start and the end of its
// job, only the job touches it.
@(private)
Content_Animation_Load :: struct {
    allocator:runtime.Allocator,
    id:base.Asset_Id,
    file:asset.Asset, // the .anim, or its compression from the cache: view points into it
    view:asset.Animation_View,
    skeletons:[]Content_Skeleton, // those its clips name: a job does not read the registry
    compress:bool,    // its tracks are keys, which the job compresses
    path:string,      // where the cache keeps the compression; "": nowhere
    built:Content_Animation,
    cached:[]u8,      // the cooked document to write at path
    ok:bool,
    counter:jobs.Counter,
    read_ns,build_ns:i64, // what reading it on the main thread and building it took
}

@(private)
Content_Skeleton :: struct {
    id:base.Asset_Id,
    file:asset.Asset, // closed when it could not be read: the clips are measured on their tracks
}

// Whether the first load of an .anim compresses: content_animation gives nil until it ends. In a
// frame played again, also while the frame it recorded had not seen that load yet.
content_animation_pending :: proc(app:^App,id:base.Asset_Id) -> bool {
    c:=app.content
    if c==nil {return false}
    ref,known:=c.index[id]
    if !known || ref.kind!=.Animation {return false}
    entry:=&c.animations[ref.index]
    if entry.generation==0 {return entry.load!=nil}
    return content_animation_replay_pending(c,entry)
}

// content_animation for whoever needs the library now, as an API call: it waits for the
// compression of its first load and takes it, between frames.
content_animation_wait :: proc(app:^App,id:base.Asset_Id) -> ^Content_Animation {
    content:=content_animation(app,id)
    if content!=nil || !content_animation_pending(app,id) {return content}
    entry:=&app.content.animations[app.content.index[id].index]
    if entry.load==nil {return nil}
    jobs.wait(&app.jobs,jobs.OWNER,&entry.load.counter)
    content_animation_finish(app,entry,job=true)
    return content_animation(app,id)
}

// Starts the first load of each .anim that ids name, directly or through the assets they depend
// on in the registry, and appends them to out: what a world that starts playing with those ids
// can play. Scenes of several roots are not followed: they load apart.
content_animations_start :: proc(app:^App,ids:[]base.Asset_Id,out:^[dynamic]base.Asset_Id) {
    a:=app.assets
    if a==nil {return}
    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    pending:=make([dynamic]base.Asset_Id,context.temp_allocator)
    append(&pending,..ids)
    for len(pending)>0 {
        id:=pop(&pending)
        if id=={} || id in seen {continue}
        seen[id]=true
        file,found:=asset.registry_find(&a.registry,id)
        if !found || file.kind==asset.KIND_SCENE && !asset.registry_prefab(file) {continue}
        if file.kind==asset.KIND_ANIMATION {
            _=content_animation(app,id)
            append(out,id)
            continue
        }
        append(&pending,..asset.registry_dependencies(&a.registry,file))
    }
}

// Whether the first load of one of ids still compresses (content_animation_pending). With wait,
// it waits for them and takes them, between frames, for a world that must not start without
// them; false then.
content_animations_pending :: proc(app:^App,ids:[]base.Asset_Id,wait:=false) -> bool {
    for id in ids {
        if !content_animation_pending(app,id) {continue}
        if !wait {return true}
        _=content_animation_wait(app,id)
    }
    return false
}

// Takes the loads whose jobs ended, at the start of the frame of the application: what a job
// loads changes only there, so a frame sees the same content from its start to its end and the
// generations a Frame_Record keeps say what it saw.
@(private)
app_content_adopt :: proc(app:^App) {
    c:=app.content
    if c==nil {return}
    for &entry in c.animations {
        if entry.load==nil || jobs.pending(&entry.load.counter) {continue}
        content_animation_finish(app,&entry,job=true)
    }
}

// A first load a job made after the frame that plays again had seen it.
@(private)
content_animation_replay_pending :: proc "contextless" (
    c:^Content,entry:^Content_Animation,
) -> bool {
    seen,replaying:=c.replay.?
    return replaying && entry.adopted>seen
}

// Starts loading the file of entry: false when it cannot be read. What already holds its streams (a
// cooked .anim or a compression of the cache) is built at once, and so is a compression without
// job threads; else a job compresses and content_animation_finish takes what it built.
@(private)
content_animation_start :: proc(app:^App,entry:^Content_Animation) -> bool {
    c:=app.content
    load,error:=new(Content_Animation_Load,c.allocator)
    if error!=nil {return false}
    load.allocator,load.id=c.allocator,entry.id
    started:=time.tick_now()
    if !content_animation_read(app,entry,load) {
        content_animation_load_free(c,load)
        return false
    }
    load.read_ns=time.duration_nanoseconds(time.tick_since(started))
    entry.load=load
    if load.compress && jobs.worker_count(&app.jobs)>1 {
        jobs.run(&app.jobs,jobs.OWNER,.Background,content_animation_build,load,&load.counter)
        return true
    }
    content_animation_build(load,jobs.OWNER)
    content_animation_finish(app,entry,job=false)
    return true
}

// Takes what the ended load of entry built: its library replaces what entry had, and its
// compression goes to the cache. One that failed leaves what entry had, and fails a first load.
// The first load a job made keeps its generation in adopted.
@(private)
content_animation_finish :: proc(app:^App,entry:^Content_Animation,job:bool) {
    c,load:=app.content,entry.load
    entry.load=nil
    defer content_animation_load_free(c,load)
    first:=entry.generation==0
    defer if first && job {entry.adopted=entry.generation}
    if first {
        main,worker:=load.read_ns,load.build_ns
        if !job {main,worker=main+worker,0}
        load_asset_done(&app.load_profile,entry.id,.Animation,entry.size,main,worker,!load.ok)
    }
    if !load.ok {
        if first {content_loaded(c,entry,false)}
        return
    }
    if load.compress {c.stats.compressed+=1}
    content_animation_cache_write(app.animation_cache,load)
    content_animation_free(c,entry)
    built:=&load.built
    entry.lib,entry.clip_count,entry.markers=built.lib,built.clip_count,built.markers
    entry.names,entry.roots,entry.morphs,entry.fields=built.names,built.roots,built.morphs,built.fields
    built^={}
    if first {content_loaded(c,entry,true)} else {content_reloaded(c,entry)}
}

// Waits for the load under way of entry and drops it: entry keeps what it had. A compression
// that ended is kept in the cache all the same.
@(private)
content_animation_drop :: proc(app:^App,entry:^Content_Animation) {
    load:=entry.load
    if load==nil {return}
    entry.load=nil
    if jobs.pending(&load.counter) {jobs.wait(&app.jobs,jobs.OWNER,&load.counter)}
    if load.ok {content_animation_cache_write(app.animation_cache,load)}
    content_animation_load_free(app.content,load)
}

@(private="file")
content_animation_load_free :: proc(c:^Content,load:^Content_Animation_Load) {
    asset.asset_close(&load.file)
    for &skeleton in load.skeletons {asset.asset_close(&skeleton.file)}
    delete(load.skeletons,load.allocator)
    delete(load.path,load.allocator)
    mem.free_bytes(load.cached,load.allocator)
    content_animation_free(c,&load.built)
    free(load,load.allocator)
}

// Opens the .anim of entry and what its compression is made from, on the main thread; a
// compression the cache has whole replaces its keys.
@(private="file")
content_animation_read :: proc(
    app:^App,entry:^Content_Animation,
    load:^Content_Animation_Load,
) -> bool {
    a:=app.assets
    content_open(a,entry.id,asset.KIND_ANIMATION,&load.file,entry) or_return
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    opened,error:=asset.animation_view(&load.file,&a.types)
    load.view=opened
    if error!=.None {return false}
    for track in load.view.tracks {
        if track.encoding!=.Raw {return true}
    }
    load.compress=true
    allocation:runtime.Allocator_Error
    load.skeletons,allocation=make([]Content_Skeleton,len(load.view.clips),load.allocator)
    if allocation!=nil {return false}
    count:=0
    config:=anim.COMPRESS_DEFAULT
    versions:=u64(asset.VERSION)<<32|u64(anim.COMPRESS_VERSION)<<16|u64(asset.ANIMATION_VERSION)
    key:=base.hash_combine(load.file.blob.header.content_hash,versions)
    shell:=u64(transmute(u32)config.precision)|u64(transmute(u32)config.shell)<<32
    key=base.hash_combine(key,shell)
    curves:=u64(transmute(u32)config.float_precision)|u64(transmute(u32)config.vector_precision)<<32
    key=base.hash_combine(key,curves)
    for clip in load.view.clips {
        if clip.skeleton=={} {continue}
        known:=false
        for skeleton in load.skeletons[:count] {known||=skeleton.id==clip.skeleton}
        if known {continue}
        skeleton:=&load.skeletons[count]
        count+=1
        skeleton.id=clip.skeleton
        hash:u64
        if assets_file(a,clip.skeleton,asset.KIND_SKELETON,&skeleton.file)==.None {
            hash=skeleton.file.blob.header.content_hash
        }
        key=base.hash_combine(key,base.hash_combine(clip.skeleton[0],clip.skeleton[1]))
        key=base.hash_combine(key,hash)
    }
    if app.animation_cache=="" {return true}
    text:[base.ASSET_ID_TEXT]u8
    digits:[16]u8
    name,hex:=base.asset_id_format(entry.id,text[:]),base.hex_format_u64(key,digits[:])
    no_path:runtime.Allocator_Error
    if load.path,no_path=strings.clone(fmt.tprintf("%s/%s-%s.anim",app.animation_cache,name,hex),load.allocator);no_path!=nil {return false}
    cached:asset.Asset
    if asset.asset_load(&cached,load.path,a.allocator)!=.None {return true}
    header:=cached.blob.header
    view:asset.Animation_View
    error=.Corrupt
    whole:=asset.blob_verify_hash(&cached.blob) && header.id==entry.id
    if whole && header.kind==asset.KIND_ANIMATION {view,error=asset.animation_view(&cached,&a.types)}
    if error!=.None || !content_animation_cache_matches(load.view,view) {
        asset.asset_close(&cached)
        return true
    }
    asset.asset_close(&load.file)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    load.file=cached
    load.view=view
    load.compress=false
    return true
}

// Whether a compression of the cache holds the clips of source: the same clips, tracks and
// markers by name, place, root and skeleton, whatever the encoding of its tracks. One that
// another build wrote otherwise is compressed again and replaced, never played.
@(private="file")
content_animation_cache_matches :: proc(source,cached:asset.Animation_View) -> bool {
    if len(cached.clips)!=len(source.clips) || len(cached.tracks)!=len(source.tracks) || len(cached.markers)!=len(source.markers) {return false}
    for clip,i in source.clips {
        other:=cached.clips[i]
        same:=other.name==clip.name && other.root==clip.root && other.skeleton==clip.skeleton
        same&&=other.first_track==clip.first_track && other.track_count==clip.track_count
        same&&=other.first_marker==clip.first_marker && other.marker_count==clip.marker_count
        if !same {return false}
    }
    for track,i in source.tracks {
        other:=cached.tracks[i]
        if other.target!=track.target || other.property!=track.property || other.slot!=track.slot {return false}
    }
    for marker,i in source.markers {
        if cached.markers[i]!=marker {return false}
    }
    return true
}

// Builds the library of what a load read, compressing its keys: in a job, or at once.
@(private="file")
content_animation_build :: proc(load:^Content_Animation_Load,worker:int) {
    started:=time.tick_now()
    defer load.build_ns=time.duration_nanoseconds(time.tick_since(started))
    context.allocator=load.allocator
    view:=load.view
    built:=&load.built
    desc:=asset.animation_library_desc(view)
    desc.max_clips*=2
    desc.allocator=load.allocator
    if !anim.library_init(&built.lib,desc) {return}
    count:=len(view.clips)
    e1,e2,e3:runtime.Allocator_Error
    built.markers,e1=make([]Content_Marker,len(view.markers),load.allocator)
    built.names,e2=make([][asset.ANIMATION_NAME_CAPACITY]u8,count,load.allocator)
    built.roots,e3=make([]asset.Animation_Root,count,load.allocator)
    morphing:bool
    built.morphs,morphing=content_animation_morphs(view,load.allocator)
    fielded:bool
    built.fields,fielded=content_animation_fields(view,load.allocator)
    if e1!=nil || e2!=nil || e3!=nil || !morphing || !fielded {return}
    if count>0 && asset.animation_clips_add(view,&built.lib,.Once)==0 {return}
    content_animation_loops(&built.lib,count)
    built.clip_count=count
    for &marker,i in view.markers {
        target:=base.text_get(marker.target[:])
        built.markers[i]={name=base.name_hash(base.text_get(marker.name[:]))}
        if target!="" {built.markers[i].target,built.markers[i].text=base.name_hash(target),marker.name}
    }
    for clip,i in view.clips {built.names[i]=clip.name;built.roots[i]=clip.root}
    if !load.compress {
        built.lib.prepared=true
        load.ok=true
        return
    }
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    open :: proc(data:rawptr,id:base.Asset_Id,file:^asset.Asset) -> bool {
        for &skeleton in (^Content_Animation_Load)(data).skeletons {
            if skeleton.id!=id || skeleton.file.file==nil {continue}
            return asset.asset_open(file,skeleton.file.file,context.temp_allocator)==.None
        }
        return false
    }
    if _,error:=asset.animation_compress(view,&built.lib,&types,open,load);error!=.None {return}
    load.ok=true
    if load.path=="" {return}
    doc:asset.Document
    header:=load.file.blob.header
    cooked:=asset.animation_cooked_document(
        &doc,&types,load.id,header.owner,view,&built.lib,context.temp_allocator)
    if cooked!=.None {return}
    defer asset.document_destroy(&doc)
    doc.flags=header.flags
    load.cached,_=asset.document_bytes(&doc,load.allocator)
}

// Writes the compression a load made to the cache, where it replaces those of what the asset
// was before. A cache that cannot be written only costs the next load its compression.
@(private="file")
content_animation_cache_write :: proc(folder:string,load:^Content_Animation_Load) {
    if load.cached==nil || load.path=="" {return}
    data:=load.cached
    load.cached=nil
    defer mem.free_bytes(data,load.allocator)
    if !os.is_dir(folder) && os.make_directory_all(folder)!=nil {return}
    if serial.file_write_atomic(load.path,data)!=.None {return}
    text:[base.ASSET_ID_TEXT]u8
    prefix:=base.asset_id_format(load.id,text[:])
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    name:=load.path[len(folder)+1:]
    for entry in entries {
        stale:=entry.type==.Regular && strings.has_prefix(entry.name,prefix) && entry.name!=name
        if stale {_=os.remove(entry.fullpath)}
    }
}
