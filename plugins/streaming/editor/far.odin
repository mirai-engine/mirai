package streaming_editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "mirai:asset"
import "mirai:cook/far"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import streaming "plugins:streaming/runtime"

// The editor makes, in jobs, the far mesh of each scene the references of its
// worlds name whose far cache (project.FAR_CACHE) has none of what the scene
// is now (streaming.Far_Mesh.key): once, written into the cache, which the
// registry mounts, so the next session and a game of the project that is not
// cooked read it. A scene without static meshes leaves a mark of its key, so
// it is not looked at again. The proxies show the far mesh before until the
// new one is there.

FAR_BUILDS :: 2 // far meshes made at once

// The far meshes the editor makes.
@(storage,host,free="far_builds_free")
Far_Builds :: struct {
    app:^host.App,
    jobs:[dynamic]^Far_Job,
    tried:map[u64]bool, // keys made, or that failed, in this session
}

far_builds_free :: proc(builds:^Far_Builds) {
    for j in builds.jobs {far_job_free(builds.app,j)}
    delete(builds.jobs)
    delete(builds.tried)
    builds^={}
}

// A far mesh being made: its jobs read in rounds what the main thread finds
// for them and write it into the cache once nothing is missing.
Far_Job :: struct {
    build:far.Far_Build,
    key:u64,
    path:string,                         // of the file it writes, in the cache
    sources:[dynamic]host.Assets_Source, // what the main thread found for the next round
    wanted:[dynamic]base.Asset_Id,       // what the last round asks for
    arena:mem.Dynamic_Arena,
    done:bool,
    written:bool, // done with a file
    counter:jobs.Counter,
}

@(private)
far_job_new :: proc(scene:base.Asset_Id,key:u64,path:string) -> ^Far_Job {
    heap:=runtime.heap_allocator()
    j,allocation_error:=new(Far_Job,heap)
    if allocation_error!=nil {return nil}
    j.key=key
    j.sources=make([dynamic]host.Assets_Source,heap)
    j.wanted=make([dynamic]base.Asset_Id,heap)
    mem.dynamic_arena_init(&j.arena,heap,heap)
    far.far_init(&j.build,scene,base.dynamic_arena_allocator(&j.arena))
    j.path=fmt.aprint(path,allocator=base.dynamic_arena_allocator(&j.arena))
    append(&j.wanted,scene)
    j.build.asked[scene]=true
    return j
}

@(private)
far_job_free :: proc(app:^host.App,j:^Far_Job) {
    if jobs.pending(&j.counter) && app!=nil {jobs.wait(&app.jobs,jobs.OWNER,&j.counter)}
    for &source in j.sources {host.assets_source_free(&source)}
    far.far_destroy(&j.build)
    delete(j.sources);delete(j.wanted)
    mem.dynamic_arena_destroy(&j.arena)
    free(j,runtime.heap_allocator())
}

@(private)
far_job_release :: proc(data:rawptr) {far_job_free(nil,(^Far_Job)(data))}

// A round, on a job: takes what was found and asks for what is still missing
// or, with nothing missing, makes the far mesh and writes it into the cache,
// or the mark of a scene without static meshes.
@(private)
far_round :: proc(j:^Far_Job,worker:int) {
    context.allocator=j.build.allocator
    for &source in j.sources {
        file:asset.Asset
        opened:=host.assets_source_open(&source,&file)==.None
        far.far_take(&j.build,source.id,source.hash,opened?&file:nil)
    }
    for &source in j.sources {host.assets_source_free(&source)}
    clear(&j.sources)
    far.far_wanted(&j.build,&j.wanted)
    if len(j.wanted)>0 {return}
    j.done=true
    g:asset.Mesh_Geometry
    if !far.far_make(&j.build,&g,j.build.allocator) {
        if !j.build.starved {_=os.write_entire_file(fmt.tprintf("%s.none",j.path[:len(j.path)-len(".mesh")]),"")}
        return
    }
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    staged:=fmt.tprintf("%s.tmp",j.path)
    j.written=asset.mesh_save(staged,&types,{id=asset.far_cache_id(j.key),geometry=g})==.None && os.rename(staged,j.path)==nil
}

// Moves the builds on: gives each round what it asked for, and makes the far
// meshes the cache lacks.
@(step="frame",after="streaming_far")
streaming_far_build :: proc(app:^host.App,far_meshes:core.Ref(streaming.Streaming_Far),builds:^Far_Builds,problems:^core.Problems) {
    if app==nil || app.assets==nil || app.assets.indexed || far_meshes.ptr==nil {return}
    a:=app.assets
    builds.app=app
    context.allocator=app.allocator
    folder:=project.cache_path(app.root,project.FAR_CACHE,allocator=context.temp_allocator)
    for s in far_meshes.ptr.scenes {
        if len(builds.jobs)>=FAR_BUILDS {break}
        if s.key==0 || s.key in builds.tried {continue}
        if _,found:=asset.registry_find(&a.registry,asset.far_cache_id(s.key));found {continue}
        name:=fmt.tprintf("%016x",s.key)
        if os.exists(fmt.tprintf("%s/%s.none",folder,name)) {continue}
        builds.tried[s.key]=true
        if j:=far_job_new(s.scene,s.key,fmt.tprintf("%s/%s.mesh",folder,name));j!=nil {append(&builds.jobs,j)} else {far_starved(problems,a,s.scene)}
    }
    for i:=len(builds.jobs)-1;i>=0;i-=1 {
        j:=builds.jobs[i]
        if jobs.pending(&j.counter) {continue}
        if j.done {
            if j.build.starved {
                far_starved(problems,a,j.build.scene)
                delete_key(&builds.tried,j.key)
            }
            if j.written {host.assets_refresh(a,{fmt.tprintf("%s/%016x.mesh",project.FAR_PREFIX,j.key)})}
            // Its jobs are done: what they read goes in a job too.
            host.app_release(app,{far_job_release,j})
            unordered_remove(&builds.jobs,i)
            continue
        }
        for id in j.wanted {
            if source,found:=host.assets_source(a,id,runtime.heap_allocator());found {append(&j.sources,source)} else {far.far_take(&j.build,id,0,nil)}
        }
        clear(&j.wanted)
        if jobs.worker_count(&app.jobs)>1 {jobs.run(&app.jobs,jobs.OWNER,far_round,j,&j.counter)} else {far_round(j,jobs.OWNER)}
    }
}

@(private)
far_starved :: proc(problems:^core.Problems,a:^host.Assets,scene_id:base.Asset_Id) {
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,core.NONE,"streaming.memory","out of memory to make the far mesh of scene %s; it is made again: free memory",host.assets_name(a,scene_id,&name))
}
