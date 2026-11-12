package host

import "base:intrinsics"
import "base:runtime"
import "core:time"
import "mirai:asset"
import render "mirai:render"
import "mirai:std/base"
import "mirai:std/jobs"

// The levels of the textures of assets follow what the GPU samples of them
// (render/texture_residency.odin): between frames the renderer says which
// textures need other levels of their files, jobs read and decode them,
// TEXTURE_READS at once, and the renderer takes them as the loads give it
// assets, sharing their part of each frame (Load_Budget). Their rows go to
// the GPU over the frames that follow (render.texture_levels_queue), and
// what the job read stays until they went; then a job frees it
// (app_assets_release).
//
// A texture a material asks for arrives the same way (Assets.arrive): the
// material shows without it, a job reads its levels of side TEXTURE_TAIL,
// TEXTURE_ARRIVALS at once, and the frames give them to the renderer before
// the levels of others, in the same part of the frame; the rows of the
// materials that waited take it (assets_arrivals_settle) and what the GPU
// samples asks for its larger levels. No frame reads, decodes or uploads a
// whole texture for a material.

TEXTURE_READS :: 8
TEXTURE_ARRIVALS :: 32

Texture_Read :: struct {
    request:render.Texture_Request,
    prepared:Assets_Prepared,
    limits:Assets_Limits,
    busy:bool,  // a job reads it, or read it
    ready:bool, // the job is done: written by it
    uploading:bool, // the renderer takes its levels over frames
}

Texture_Streaming :: struct {
    reads:[TEXTURE_READS]Texture_Read,
    arrivals:[TEXTURE_ARRIVALS]Texture_Read, // of arriving textures: no request, their small levels
    arrived:int,                             // of Assets.arrivals, those given to a read
    counter:jobs.Counter,
    load:u64, // its id in the budget of the loads while it has levels to give
}

// Between frames: gives the renderer the levels the jobs read, while the
// part of the frame of the loads lasts, and starts reading those it asks for
// next. Nothing without assets or renderer, or while nothing changes.
app_textures_stream :: proc(app:^App) {
    a,r:=app.assets,app.renderer
    if a==nil || r==nil || len(a.texture_assets)==0 && len(a.arrivals)==0 {return}
    st:=&app.texture_streaming
    start:=time.tick_now()
    for &read in st.reads {
        if !read.uploading || render.texture_upload_pending(r,read.request) {continue}
        app_assets_release(app,&read.prepared)
        read={}
    }
    if texture_reads_ready(st) {
        if st.load==0 {st.load=assets_load_open(a)}
        share:=assets_load_share(a,app.stats.frames,st.load)
        taken,first:=0,true
        // What has no level yet goes before more levels of what shows.
        for &read in st.arrivals {
            if !read.busy || !intrinsics.atomic_load(&read.ready) {continue}
            if !first && time.duration_seconds(time.tick_since(start))>=share.seconds {break}
            cost:=read.prepared.cost
            if !(first && share.alone) && taken+cost>share.bytes {
                if first {assets_load_alone(a,st.load)}
                break
            }
            id:=read.prepared.source.id
            if assets_texture_arriving(a,id) {
                app_assets_take(app,&read.prepared)
                // Its file changed after the job read it: it is read again.
                if assets_texture_arriving(a,id) && append(&a.arrivals,id)!=1 {_=assets_texture(a,id)}
            } else {
                app_assets_release(app,&read.prepared)
            }
            read={}
            taken+=cost
            first=false
        }
        for &read in st.reads {
            if !read.busy || read.uploading || !intrinsics.atomic_load(&read.ready) {continue}
            // Its first levels of the frame go if their bytes fit, whatever the time.
            if !first && time.duration_seconds(time.tick_since(start))>=share.seconds {break}
            cost:=read.prepared.cost
            if !(first && share.alone) && taken+cost>share.bytes {
                if first {assets_load_alone(a,st.load)}
                break
            }
            if !texture_read_take(app,&read) {break}
            taken+=cost
            first=false
        }
        assets_load_spend(a,time.duration_seconds(time.tick_since(start)),taken)
    }
    if assets_arrivals_settle(a) {assets_commit(a)}
    arrivals_read(app,st)
    // The load asks for its part only while it has levels to give.
    if st.load!=0 && !texture_reads_ready(st) {
        assets_load_close(a,st.load)
        st.load=0
    }
    if render.textures_update(r)==0 {return}
    busy:[TEXTURE_READS]render.Texture_Handle
    held:=0
    for read in st.reads {
        if !read.busy {continue}
        busy[held]=read.request.handle
        held+=1
    }
    if held==TEXTURE_READS {return}
    requests:[TEXTURE_READS]render.Texture_Request
    count:=render.texture_requests(r,requests[:TEXTURE_READS-held],busy[:held])
    limits:=assets_limits(a)
    // Without job threads a read holds the frame: one in each.
    threads:=jobs.worker_count(&app.jobs)>1
    if !threads {count=min(count,1)}
    next:=0
    for request in requests[:count] {
        id:=a.texture_assets[request.handle-1] if int(request.handle)<=len(a.texture_assets) else {}
        ref,known:=a.index[id]
        source,found:=assets_source(a,id,runtime.heap_allocator())
        if !known || ref.kind!=.Texture || a.textures[ref.index].handle!=request.handle || a.textures[ref.index].failed || !found {
            // Not the texture of an asset whose file can be read: it keeps its levels.
            assets_source_free(&source)
            render.texture_stream_stop(r,request)
            continue
        }
        for st.reads[next].busy {next+=1}
        read:=&st.reads[next]
        read^={request=request,prepared={source=source,level=request.level},limits=limits,busy=true}
        if threads {jobs.run(&app.jobs,jobs.OWNER,.Background,texture_read,read,&st.counter)} else {texture_read(read,jobs.OWNER)}
    }
}

// Waits for the reads under way and drops what they read: before the assets
// or the renderer go.
app_textures_stream_stop :: proc(app:^App) {
    st:=&app.texture_streaming
    if app.renderer!=nil {render.texture_uploads_cancel(app.renderer)}
    if jobs.pending(&st.counter) {jobs.wait(&app.jobs,jobs.OWNER,&st.counter)}
    for &read in st.reads {
        if read.busy {assets_prepared_free(&read.prepared)}
        read={}
    }
    for &read in st.arrivals {
        if read.busy {assets_prepared_free(&read.prepared)}
        read={}
    }
    st.arrived=0
    if st.load!=0 && app.assets!=nil {assets_load_close(app.assets,st.load)}
    st.load=0
}

@(private="file")
texture_reads_ready :: proc(st:^Texture_Streaming) -> bool {
    for &read in st.reads {
        if read.busy && !read.uploading && intrinsics.atomic_load(&read.ready) {return true}
    }
    for &read in st.arrivals {
        if read.busy && intrinsics.atomic_load(&read.ready) {return true}
    }
    return false
}

// Textures still arriving: asked for by a material, their first levels not
// given yet.
app_textures_arriving :: proc(app:^App) -> int {
    if app.assets==nil {return 0}
    st:=&app.texture_streaming
    count:=len(app.assets.arrivals)-st.arrived
    for read in st.arrivals {count+=int(read.busy)}
    return count
}

// Starts reading the arriving textures the free reads take, in the order they
// were asked for. Without job threads one a frame, here.
@(private="file")
arrivals_read :: proc(app:^App,st:^Texture_Streaming) {
    a:=app.assets
    threads:=jobs.worker_count(&app.jobs)>1
    limits:=assets_limits(a,tail=true)
    for &read in st.arrivals {
        if read.busy {continue}
        id:base.Asset_Id
        for st.arrived<len(a.arrivals) && id=={} {
            next:=a.arrivals[st.arrived]
            st.arrived+=1
            if assets_texture_arriving(a,next) {id=next}
        }
        if id=={} {break}
        source,found:=assets_source(a,id,runtime.heap_allocator())
        if !found {
            // The registry lost its file: it loads here, and fails as it would.
            _=assets_texture(a,id)
            continue
        }
        read={prepared={source=source},limits=limits,busy=true}
        if !threads {
            texture_read(&read,jobs.OWNER)
            break
        }
        jobs.run(&app.jobs,jobs.OWNER,.Background,texture_read,&read,&st.counter)
    }
    if st.arrived>0 && st.arrived==len(a.arrivals) {
        clear(&a.arrivals)
        st.arrived=0
    }
}

// A job: reads and decodes the levels of a texture.
@(private="file")
texture_read :: proc(read:^Texture_Read,worker:int) {
    context.allocator=runtime.heap_allocator()
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    assets_prepare(&read.prepared,read.limits,&types)
    intrinsics.atomic_store(&read.ready,true)
}

// Gives the renderer the levels a job read, when they are still those of the
// texture it asked for: unloaded, reloaded or with another file, nothing.
// A file that no longer reads, or levels the device does not take, leave the
// texture with the levels it has. Levels the renderer takes stay with the
// read while they go; false when it takes none now: the read waits.
@(private="file")
texture_read_take :: proc(app:^App,read:^Texture_Read) -> bool {
    kept:=false
    defer if !kept {
        app_assets_release(app,&read.prepared)
        read^={}
    }
    a,r:=app.assets,app.renderer
    id:=read.prepared.source.id
    record,found:=asset.registry_find(&a.registry,id)
    if !found || record.content_hash!=read.prepared.source.hash {return true}
    ref,known:=a.index[id]
    if !known || ref.kind!=.Texture || a.textures[ref.index].handle!=read.request.handle {return true}
    if !read.prepared.ok {
        render.texture_stream_stop(r,read.request)
        return true
    }
    switch render.texture_levels_queue(r,read.request,read.prepared.levels.data) {
    case .Set:
        a.stats.streamed+=1
        kept,read.uploading=true,true
    case .Busy:
        kept=true
        return false
    case .Stale:
    case .Mismatch,.Failed: render.texture_stream_stop(r,read.request)
    }
    return true
}
