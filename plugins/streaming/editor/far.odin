package streaming_editor

import "base:runtime"
import "core:mem"
import "mirai:asset"
import "mirai:cook/far"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"
import streaming "plugins:streaming/runtime"

// The editor makes the far mesh of each scene the references of its worlds
// ask for (streaming.Streaming_Far), in jobs, the first time it is asked, and
// again when what it was made of changes, as any cooking: each asset it read
// is kept with its content hash, and a registry whose hash of one of them
// changed (or that now has one it lacked) makes it again, the proxies showing
// the one before until the new one is ready. A shipped game reads the one its
// cook made.

FAR_BUILDS :: 2 // far meshes made at once
FAR_RETIRE :: 4 // frames a far mesh made again stays for the proxies of every world to take the new one

// The far mesh of a scene.
Far_Scene :: struct {
    scene:base.Asset_Id,
    mesh:base.Asset_Id, // generated; none until made, or for a scene without static meshes
    made:bool,          // tried at least once
    read:[dynamic]far.Far_Read,
    build:^Far_Job,     // making it again
}

// A far mesh made again, released once the proxies took the new one.
Far_Retired :: struct {mesh:base.Asset_Id,frame:u64}

// The far meshes the editor makes, by scene.
@(storage,host,free="far_builds_free")
Far_Builds :: struct {
    app:^host.App,
    scenes:[dynamic]Far_Scene,
    retired:[dynamic]Far_Retired,
    revision:u64, // of the registry when the reads were last compared
}

far_builds_free :: proc(builds:^Far_Builds) {
    assets:=builds.app.assets if builds.app!=nil else nil
    for &s in builds.scenes {
        if s.build!=nil {far_job_free(builds.app,s.build)}
        if s.mesh!={} && assets!=nil {host.assets_mesh_release(assets,s.mesh)}
        delete(s.read)
    }
    for r in builds.retired {if assets!=nil {host.assets_mesh_release(assets,r.mesh)}}
    delete(builds.scenes);delete(builds.retired)
    builds^={}
}

// A far mesh being made: its jobs read in rounds what the main thread finds
// for them and build it once nothing is missing.
Far_Job :: struct {
    build:far.Far_Build,
    limits:host.Assets_Limits,
    sources:[dynamic]host.Assets_Source, // what the main thread found for the next round
    wanted:[dynamic]base.Asset_Id,       // what the last round asks for
    arena:mem.Dynamic_Arena,
    made:host.Mesh_Render_Geometry,
    done:bool,
    built:bool, // done with a mesh
    counter:jobs.Counter,
}

@(private)
far_job_new :: proc(scene:base.Asset_Id,limits:host.Assets_Limits) -> ^Far_Job {
    heap:=runtime.heap_allocator()
    j,allocation_error:=new(Far_Job,heap)
    if allocation_error!=nil {return nil}
    j.limits=limits
    j.sources=make([dynamic]host.Assets_Source,heap)
    j.wanted=make([dynamic]base.Asset_Id,heap)
    mem.dynamic_arena_init(&j.arena,heap,heap)
    far.far_init(&j.build,scene,base.dynamic_arena_allocator(&j.arena))
    host.assets_render_geometry_init(&j.made,heap)
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
    host.assets_render_geometry_destroy(&j.made)
    mem.dynamic_arena_destroy(&j.arena)
    free(j,runtime.heap_allocator())
}

@(private)
far_job_release :: proc(data:rawptr) {far_job_free(nil,(^Far_Job)(data))}

// A round, on a job: takes what was found and asks for what is still
// missing or, with nothing missing, makes the far mesh with its rays.
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
    arena:=base.dynamic_arena_allocator(&j.made.arena)
    j.built=far.far_make(&j.build,&j.made.geometry,arena) && host.assets_render_geometry_rays(&j.made,j.limits)
    j.done=true
}

// Moves the builds on: gives each round what it asked for, publishes what is
// made, and makes again the far meshes whose reads changed.
@(step="frame")
streaming_far_build :: proc(app:^host.App,wanted:core.Ref(streaming.Streaming_Far),meshes:^streaming.Streaming_Far_Meshes,builds:^Far_Builds,problems:^core.Problems) {
    if app==nil || app.assets==nil || app.assets.renderer==nil || wanted.ptr==nil {return}
    a:=app.assets
    builds.app=app
    context.allocator=app.allocator
    for id in wanted.ptr.wanted {
        known:=false
        for s in builds.scenes {known||=s.scene==id}
        if !known {append(&builds.scenes,Far_Scene{scene=id})}
    }
    for i:=len(builds.retired)-1;i>=0;i-=1 {
        if app.stats.frames<builds.retired[i].frame+FAR_RETIRE {continue}
        host.assets_mesh_release(a,builds.retired[i].mesh)
        unordered_remove(&builds.retired,i)
    }
    // What a far mesh was made of changed: it is made again.
    if revision:=a.registry.revision;revision!=builds.revision {
        builds.revision=revision
        for &s in builds.scenes {
            if !s.made || s.build!=nil {continue}
            for r in s.read {
                hash:u64
                if file,found:=asset.registry_find(&a.registry,r.id);found {hash=file.content_hash}
                if hash!=r.hash {s.made=false;break}
            }
        }
    }
    building:=0
    for s in builds.scenes {if s.build!=nil {building+=1}}
    for &s in builds.scenes {
        if s.made || s.build!=nil || building>=FAR_BUILDS {continue}
        s.build=far_job_new(s.scene,host.assets_limits(a))
        if s.build==nil {far_starved(problems,a,s.scene);continue}
        building+=1
    }
    published:=false
    for &s in builds.scenes {
        j:=s.build
        if j==nil || jobs.pending(&j.counter) {continue}
        if j.done {
            if j.build.starved {
                // The section keeps the far mesh it had, and a new build starts.
                far_starved(problems,a,s.scene)
            } else {
                mesh:base.Asset_Id
                if j.built {mesh,_=host.assets_mesh_publish(a,&j.made)}
                if s.mesh!={} {append(&builds.retired,Far_Retired{s.mesh,app.stats.frames})}
                s.mesh,s.made=mesh,true
                clear(&s.read)
                // Asked and not found counts too: its arrival makes it again.
                for id in j.build.asked {
                    hash:u64
                    for r in j.build.read {if r.id==id {hash=r.hash;break}}
                    append(&s.read,far.Far_Read{id,hash})
                }
                published=true
            }
            // Its jobs are done: what they read goes in a job too.
            host.app_release(app,{far_job_release,j})
            s.build=nil
            continue
        }
        for id in j.wanted {
            if source,found:=host.assets_source(a,id,runtime.heap_allocator());found {append(&j.sources,source)} else {far.far_take(&j.build,id,0,nil)}
        }
        clear(&j.wanted)
        if jobs.worker_count(&app.jobs)>1 {jobs.run(&app.jobs,jobs.OWNER,far_round,j,&j.counter)} else {far_round(j,jobs.OWNER)}
    }
    if !published {return}
    clear(&meshes.items)
    for s in builds.scenes {if s.mesh!={} {append(&meshes.items,streaming.Far_Mesh{s.scene,s.mesh})}}
}

@(private)
far_starved :: proc(problems:^core.Problems,a:^host.Assets,scene_id:base.Asset_Id) {
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,core.NONE,"streaming.memory","out of memory to make the far mesh of scene %s; it is made again: free memory",host.assets_name(a,scene_id,&name))
}
