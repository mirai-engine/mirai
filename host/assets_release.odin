package host

import "mirai:asset"
import render "mirai:render"
import "mirai:std/jobs"

// What jobs read for the loads (Assets_Prepared, the documents of a scene) is
// freed in a job: giving back the memory of a large file and of what it
// decoded holds a thread long enough to show in a frame. What the renderer
// still uploads from (a texture or a mesh taken over frames) stays until all
// of it went. What a library read in jobs goes the same way (app_release).
// The main thread queues and, between frames, hands the queue to one job at
// a time; without job threads it frees in the call.

Assets_Releases :: struct {
    uploading:[dynamic]Assets_Prepared, // their levels or geometry go to the GPU (Assets_Prepared.upload, mesh_upload)
    queued:[dynamic]Assets_Prepared,    // for the next job
    freeing:[dynamic]Assets_Prepared,   // of the job while counter is pending
    calls:[dynamic]Release_Call,        // for the next job
    calling:[dynamic]Release_Call,      // of the job while counter is pending
    counter:jobs.Counter,
}

// What a library frees: data, by procedure, on any thread.
Release_Call :: struct {
    procedure:proc(data:rawptr),
    data:rawptr,
}

// Gives the assets what a job prepared (assets_take) and takes it from the
// caller, which finds it zeroed: what it read is freed in a job once the
// renderer no longer reads it. over_frames: a texture or a mesh larger than
// LOAD_FRAME_BYTES goes over the frames that follow (app_assets_uploading).
// False, with prepared as it was and nothing taken, when it waits for a
// later frame: the renderer takes the levels of other textures. What it
// took counts in tally, or in the current load without one.
app_assets_take :: proc(app:^App,prepared:^Assets_Prepared,over_frames:=false,tally:^Load_Tally=nil) -> bool {
    a:=app.assets
    id,ns,failed:=prepared.source.id,prepared.ns,!prepared.ok
    kinds:=[Assets_Kind]Load_Asset{.Mesh=.Mesh,.Texture=.Texture,.Material=.Material,.Scene=.Plugin,.Shape=.Mesh,.Document=.Plugin}
    kind:=kinds[prepared.kind]
    fresh:=id!={} && !assets_loaded(a,id)
    scope:=load_asset_begin(a.load_profile)
    taken:=assets_take(a,prepared,over_frames)
    loaded:=fresh && taken!=.Wait && assets_loaded(a,id)
    load_asset_end(a.load_profile,scope,id,kind,assets_file_bytes(a,id) if loaded else 0,failed,ns,tally,loaded)
    switch taken {
    case .Wait: return false
    case .Uploading:
        releases_init(app)
        append(&app.asset_releases.uploading,prepared^)
        prepared^={}
    case .Taken: app_assets_release(app,prepared)
    }
    return true
}

// Frees in a job what a job prepared and nobody takes; prepared is zeroed.
app_assets_release :: proc(app:^App,prepared:^Assets_Prepared) {
    if jobs.worker_count(&app.jobs)<=1 {
        assets_prepared_free(prepared)
        return
    }
    releases_init(app)
    append(&app.asset_releases.queued,prepared^)
    prepared^={}
}

// Frees in a job what a library read in jobs and nothing reads any more:
// call.procedure gets call.data there.
app_release :: proc(app:^App,call:Release_Call) {
    if jobs.worker_count(&app.jobs)<=1 {
        call.procedure(call.data)
        return
    }
    releases_init(app)
    append(&app.asset_releases.calls,call)
}

// Frees in a job a file a job opened; file is zeroed.
app_assets_release_file :: proc(app:^App,file:^asset.Asset) {
    prepared:=Assets_Prepared{file=file^,opened=true}
    file^={}
    app_assets_release(app,&prepared)
}

// Whether levels or geometry a load gave the renderer over frames still go to the GPU.
app_assets_uploading :: proc(app:^App) -> bool {return len(app.asset_releases.uploading)>0}

// Between frames: what the renderer no longer uploads from joins the queue,
// and a job frees the queue unless one still frees the last.
app_assets_releases_step :: proc(app:^App) {
    rel:=&app.asset_releases
    for at:=0;at<len(rel.uploading); {
        if app.renderer!=nil && assets_prepared_uploading(app.renderer,&rel.uploading[at]) {
            at+=1
            continue
        }
        prepared:=rel.uploading[at]
        unordered_remove(&rel.uploading,at)
        app_assets_release(app,&prepared)
    }
    if len(rel.queued)==0 && len(rel.calls)==0 || jobs.pending(&rel.counter) {return}
    rel.queued,rel.freeing=rel.freeing,rel.queued
    rel.calls,rel.calling=rel.calling,rel.calls
    jobs.run(&app.jobs,jobs.OWNER,.Background,releases_free,rel,&rel.counter)
}

// Waits for the job and frees the rest here: before the renderer or the job
// threads go. The uploads of the renderer are to be cancelled first.
app_assets_releases_stop :: proc(app:^App) {
    rel:=&app.asset_releases
    if jobs.pending(&rel.counter) {jobs.wait(&app.jobs,jobs.OWNER,&rel.counter)}
    for list in ([3]^[dynamic]Assets_Prepared{&rel.uploading,&rel.queued,&rel.freeing}) {
        for &prepared in list^ {assets_prepared_free(&prepared)}
        delete(list^)
    }
    for list in ([2]^[dynamic]Release_Call{&rel.calls,&rel.calling}) {
        for call in list^ {call.procedure(call.data)}
        delete(list^)
    }
    rel^={}
}

@(private="file")
releases_init :: proc(app:^App) {
    rel:=&app.asset_releases
    if rel.queued.allocator.procedure!=nil {return}
    rel.uploading=make([dynamic]Assets_Prepared,app.allocator)
    rel.queued=make([dynamic]Assets_Prepared,app.allocator)
    rel.freeing=make([dynamic]Assets_Prepared,app.allocator)
    rel.calls=make([dynamic]Release_Call,app.allocator)
    rel.calling=make([dynamic]Release_Call,app.allocator)
}

// Whether the renderer still uploads from what a load took over frames.
@(private="file")
assets_prepared_uploading :: proc(r:^render.Renderer,prepared:^Assets_Prepared) -> bool {
    return render.mesh_upload_pending(r,prepared.mesh_upload) if prepared.kind==.Mesh else render.texture_upload_pending(r,prepared.upload)
}

// A job: frees what the main thread handed it.
@(private="file")
releases_free :: proc(rel:^Assets_Releases,worker:int) {
    for &prepared in rel.freeing {assets_prepared_free(&prepared)}
    clear(&rel.freeing)
    for call in rel.calling {call.procedure(call.data)}
    clear(&rel.calling)
}
