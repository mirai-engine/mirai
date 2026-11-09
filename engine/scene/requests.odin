package scene

import "core:fmt"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

SCENE_PATH_CAPACITY :: 256

// A scene to load as the roots of the world: by id, or by path when the id is
// zero (a path of the assets, or the absolute path of a scene file outside them).
Scene_Request :: struct {
    scene:base.Asset_Id,
    path:[SCENE_PATH_CAPACITY]u8 `mirai:"text"`,
    restart:bool, // the scene the world is now (Scene_Root), when it is served
}

Scene_Result :: struct {
    scene:base.Asset_Id,
    path:[SCENE_PATH_CAPACITY]u8 `mirai:"text"`,
    error:Error,
}

// Requests: the game, the player and agents push; this library loads them at
// the start of the next frame. Loading keeps them.
@(storage,queue,keep)
Scene_Requests :: struct {queue:core.Queue(Scene_Request)}

// Events: cleared at each frame, one per request served, after the load.
@(storage,events,keep)
Scene_Results :: struct {queue:core.Queue(Scene_Result)}

// Whether this world already asked for the scene the player was launched with.
@(storage,keep)
Scene_Launch :: struct {
    taken:bool,
    first:bool, // the load under way is the one the player was launched with
}

request :: proc(requests:^Scene_Requests,scene:base.Asset_Id) {
    core.push(&requests.queue,Scene_Request{scene=scene})
}

// One that names no scene, or does not fit SCENE_PATH_CAPACITY, is served as a
// scene that is not there: its result and a problem say so.
request_path :: proc(requests:^Scene_Requests,path:string) {
    r:Scene_Request
    base.text_set(r.path[:],path)
    core.push(&requests.queue,r)
}

// Loads again the scene the world is, as it is in the assets.
request_restart :: proc(requests:^Scene_Requests) {
    core.push(&requests.queue,Scene_Request{restart=true})
}

// The result of a request for this scene in the frame, by id or by path.
result_of :: proc(results:^Scene_Results,scene:base.Asset_Id,path:string="") -> (result:Scene_Result,found:bool) {
    for &r in results.queue.items {
        if scene!={} && r.scene==scene || scene=={} && path!="" && base.text_get(r.path[:])==path {return r,true}
    }
    return
}

// Loads the scenes asked for, first the one the player was launched with, one
// at a time and in phases (loading.odin): a request waits while another loads.
// Its result comes in the frame the scene replaces the world.
@(step="input",loops="game editor")
scene_requests :: proc(world:core.World_Ref,app:^host.App,requests:^Scene_Requests,results:^Scene_Results,launch:^Scene_Launch,loads:^Scene_Loads,loading:^Scene_Loading,root:core.Ref(Scene_Root),problems:^core.Problems) {
    core.queue_clear(&results.queue)
    launched:=!launch.taken && app.launch.scene!=""
    if launched {
        launch.taken=true
        request_path(requests,app.launch.scene)
    }
    // The load under way goes on; once done, the scene is the world.
    if loads!=nil && loads.job!=nil {
        job:=loads.job
        if !load_step(job) {
            if loading!=nil {loading^=load_progress(job)}
            return
        }
        r:=job.request
        loads.job=nil
        _,error:=load_end(job,world)
        if loading!=nil {loading^={}}
        // The swap traded the contents of the World: the storages are where they were.
        load_report(app,r,error,launch.first,results,problems)
        launch.first=false
        return
    }
    if len(requests.queue.items)==0 {return}
    // One at a time: the others wait for it.
    r:=requests.queue.items[0]
    kept,_:=slice.clone(requests.queue.items[1:],context.temp_allocator)
    core.queue_clear(&requests.queue)
    for k in kept {core.push(&requests.queue,k)}
    launch.first=launched
    if r.restart {
        if root.ptr!=nil {r.scene=root.scene}
        if r.scene=={} {
            core.push(&results.queue,Scene_Result{error=.Not_Found})
            core.report(problems,core.NONE,"scene.restart","there is no scene to restart: the world did not come from a scene of the assets; load one with request or request_path first")
            return
        }
    }
    id:=r.scene
    error:Error
    if id=={} {
        path:=base.text_get(r.path[:])
        if app.assets==nil {error=.No_Assets} else {
            host.assets_scan(app.assets)
            if file,found:=asset.registry_find_path(&app.assets.registry,path);found {id=file.id} else {
                // A scene file outside the assets (the copy a network game of the editor runs) loads at once.
                _,error=load_path(world,app,path)
                load_report(app,r,error,launched,results,problems)
                launch.first=false
                return
            }
        }
    }
    job:^Load_Job
    if error==.None {job,error=load_begin(app,id,r)}
    if error!=.None || loads==nil {
        if job!=nil {
            load_step(job,all=true)
            _,error=load_end(job,world)
        }
        load_report(app,r,error,launched,results,problems)
        launch.first=false
        return
    }
    // The scene the player starts with: there is no game yet to keep smooth.
    job.whole=launched
    loads.job=job
    if loading!=nil {loading^=load_progress(job)}
}

// The result of a request, and the problem of one that failed; one the player
// was launched with ends the player.
@(private)
load_report :: proc(app:^host.App,r:Scene_Request,error:Error,launched:bool,results:^Scene_Results,problems:^core.Problems) {
    r:=r
    if results!=nil {core.push(&results.queue,Scene_Result{scene=r.scene,path=r.path,error=error})}
    if error==.None {return}
    path:=base.text_get(r.path[:])
    name:[base.ASSET_ID_TEXT]u8
    what:=path
    if r.scene!={} && app.assets!=nil {what=host.assets_name(app.assets,r.scene,&name)}
    if launched {
        fmt.eprintfln("mirai: could not load the scene %s: %s",what,error_text(error))
        if app.assets!=nil {for problem in host.assets_errors(app.assets) {fmt.eprintfln("  %v",problem)}}
        host.app_exit(app,host.PLAYER_SCENE)
    }
    if problems!=nil {core.report(problems,core.NONE,"scene.load","scene %s did not load: %s; %s",what,error_text(error),load_fix(error))}
}

@(private)
load_fix :: proc(error:Error) -> string {
    #partial switch error {
    case .No_Assets:     return "run the game from a project with an assets folder"
    case .Not_Found:     return "ask for a .scene of the assets by its id or by a path shorter than SCENE_PATH_CAPACITY, or import or create it"
    case .Invalid:       return "ask for a .scene, not another kind of asset"
    case .Corrupt:       return "open the scene in the editor and save it again"
    case .Out_Of_Memory: return "free memory or make the scene smaller"
    }
    return "check the scene in the editor"
}
