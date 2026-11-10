package host

import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:project"
import render "mirai:render"
import "mirai:std/base"

// The shaders the renderer of an application runs. The executable embeds
// those of the engine; a project with Slang programs of its own has a
// generation (project.shader_generation_find) that carries them, built by
// `mirai build`. It is loaded when the application starts and again when its
// manifest changes. A load reads the generation between frames and has the
// driver compile its pipelines on a thread of its own while the frames go on
// with the resident ones; they are replaced whole between frames, and the
// materials then find their programs in the new catalog.

Shaders_State :: enum u8 {
    Embedded, // the shaders of the executable: the project has no generation
    Loaded,   // the generation of the project
    Stale,    // a generation built from other engine shaders than this executable has: it waits for a build
    Failed,   // unreadable, or the device refused its pipelines: what ran before still does
}

// Frames between two looks at the manifest of the generation.
SHADERS_POLL_FRAMES :: 30

@(private)
Shaders_Stamp :: struct {
    time_ns:i64,
    size:i64,
}

// A generation on its way to the renderer.
@(private)
Shaders_Load :: struct {
    ticket:u64,
    folder:string,
    stamp:Shaders_Stamp, // of its manifest when it was read
    identity:u64,        // shaders_identity of its folder
    assets:render.Shader_Assets,
    catalog:render.Program_Catalog,
    candidate:^render.Renderer, // its pipelines; nil when its codes are the resident ones
    worker:^thread.Thread,
    ready:bool, // atomic: the pipelines were made or refused
    built:bool,
    dropped:bool, // atomic: app_shaders_drop; its pipelines stop being made and it is not published
    asked:time.Tick,
    making:f64, // seconds its pipelines took to make
}

App_Shaders :: struct {
    root:string, // folder of the project; "": no generation is looked for
    state:Shaders_State,
    stamp:Shaders_Stamp, // of the manifest last read; zero: none
    identity:u64,        // of the generation the renderer runs; 0: the shaders of the executable (render.SHADERS_FINGERPRINT)
    frames:int,          // since the last look
    reloads:u64,         // generations that replaced a running one
    published_frame:u64, // App_Stats.frames when the last one did
    loads:[dynamic]^Shaders_Load, // in the order they were asked for
    requested:u64,       // ticket of the last load asked for
    published:u64,       // ticket of the load the renderer runs; 0: the one it started with
}

@(private)
shaders_stamp :: proc(folder:string) -> (stamp:Shaders_Stamp) {
    if folder=="" {return}
    info,error:=os.stat(project.path(folder,project.SHADERS_MANIFEST,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return}
    return {time.to_unix_nanoseconds(info.modification_time),info.size}
}

// What the shaders of a generation are: the hash of its manifest, which names
// the hash of every stage. Equal while it is the same generation, in any run.
@(private)
shaders_identity :: proc(folder:string) -> u64 {
    manifest,error:=os.read_entire_file(project.path(folder,project.SHADERS_MANIFEST,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return 0}
    return base.hash64(manifest)|1
}

// Reads the generation in folder into assets. False with one of another
// engine, or when it cannot be read; the state says which.
@(private)
app_shaders_read :: proc(app:^App,folder:string,assets:^render.Shader_Assets) -> bool {
    sh:=&app.shaders
    if !render.shader_generation_current(folder) {
        sh.state=.Stale
        log.warnf("shaders: %s was built from other engine shaders than this executable has; build the project again",folder)
        return false
    }
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    loaded,error:=render.shader_assets_load(folder,app.allocator)
    assets^=loaded
    if error!="" {
        sh.state=.Failed
        log.errorf("shaders: %s: %s",folder,error)
        return false
    }
    return true
}

// The generation the renderer starts with, or nil for the embedded shaders.
// The project is the folder desc.shaders_root names, or the one that holds
// the assets. Not ok without memory for the name of that folder.
@(private)
app_shaders_open :: proc(app:^App,desc:App_Desc,assets:^render.Shader_Assets) -> (shaders:^render.Shader_Assets,ok:bool) {
    app.shaders.loads=make([dynamic]^Shaders_Load,app.allocator)
    root:=desc.shaders_root
    if root=="" && desc.assets_root!="" {root=filepath.dir(strings.trim_right(desc.assets_root,"/\\"))}
    if root=="" {return nil,true}
    no_root:runtime.Allocator_Error
    if app.shaders.root,no_root=strings.clone(root,app.allocator);no_root!=nil {return nil,false}
    folder:=project.shader_generation_find(root,context.temp_allocator)
    app.shaders.stamp=shaders_stamp(folder)
    if folder=="" || !app_shaders_read(app,folder,assets) {return nil,true}
    app.shaders.state=.Loaded
    app.shaders.identity=shaders_identity(folder)
    return assets,true
}

// Waits for the pipeline the driver compiles of each load.
@(private)
app_shaders_close :: proc(app:^App) {
    sh:=&app.shaders
    for load in sh.loads {sync.atomic_store(&load.dropped,true)}
    for load in sh.loads {shaders_load_discard(app,load)}
    delete(sh.loads)
    delete(sh.root,app.allocator)
    sh^={}
}

// Loads the generation of the project again: it replaces the one the renderer
// runs once its pipelines are made (app_shaders_poll). The ticket of the load;
// 0 when there is none to load or it is refused at once.
app_shaders_reload :: proc(app:^App) -> u64 {
    sh:=&app.shaders
    if app.renderer==nil || sh.root=="" {return 0}
    folder:=project.shader_generation_find(sh.root,context.temp_allocator)
    sh.stamp=shaders_stamp(folder)
    if folder=="" {return 0}
    return app_shaders_load(app,folder)
}

// Loads the generation in a folder other than the one of the project, as
// app_shaders_reload does; the watch goes on comparing the manifest of the
// project. The ticket of the load; 0 when it is refused at once.
app_shaders_load :: proc(app:^App,folder:string) -> u64 {
    sh:=&app.shaders
    if app.renderer==nil {return 0}
    // The watch and whoever made the generation may both ask for it: one load serves.
    stamp:=shaders_stamp(folder)
    for load in sh.loads {
        if load.folder==folder && load.stamp==stamp && !sync.atomic_load(&load.dropped) {return load.ticket}
    }
    assets:render.Shader_Assets
    if !app_shaders_read(app,folder,&assets) {return 0}
    catalog,valid:=render.program_catalog_parse(assets.catalog,app.renderer.allocator)
    if !valid {
        render.shader_assets_destroy(&assets)
        sh.state=.Failed
        log.errorf("shaders: %s has an invalid catalog of material programs",folder)
        return 0
    }
    load,error:=new(Shaders_Load,app.allocator)
    kept,no_folder:=strings.clone(folder,app.allocator)
    if error!=nil || no_folder!=nil {
        free(load,app.allocator)
        delete(kept,app.allocator)
        render.shader_assets_destroy(&assets)
        render.program_catalog_destroy(&catalog)
        sh.state=.Failed
        log.errorf("shaders: out of memory to load %s",folder)
        return 0
    }
    sh.requested+=1
    load.ticket,load.folder,load.stamp,load.identity=sh.requested,kept,stamp,shaders_identity(folder)
    load.asked=time.tick_now()
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    load.assets=assets
    load.catalog=catalog
    shaders_load_build(app,load)
    append(&sh.loads,load)
    return load.ticket
}

// Whether the load of a ticket goes on. Once it ended, the renderer runs it
// or a later one when app.shaders.published is that ticket or more.
app_shaders_loading :: proc(app:^App,ticket:u64) -> bool {
    for load in app.shaders.loads {if load.ticket==ticket {return true}}
    return false
}

// Gives up a load that another one makes obsolete: the driver stops making
// its pipelines after the one it compiles, and it is not published. It goes
// on loading until app_shaders_poll sees it end.
app_shaders_drop :: proc(app:^App,ticket:u64) {
    for load in app.shaders.loads {if load.ticket==ticket {sync.atomic_store(&load.dropped,true)}}
}

// Makes on a thread the pipelines of a load whose codes are not the resident
// ones; without them it is ready at once.
@(private)
shaders_load_build :: proc(app:^App,load:^Shaders_Load) {
    if render.shader_assets_match_codes(&load.assets,&app.renderer.shader_codes) {
        load.built=true
        sync.atomic_store(&load.ready,true)
        return
    }
    load.candidate=render.renderer_shader_reload_begin(app.renderer,&load.assets,&load.dropped)
    if load.candidate==nil {
        // The renderer had no memory for it: the generation is not taken.
        log.errorf("shaders: the generation of %s was not taken: %s",load.folder,app.renderer.error)
        load.built=false
        sync.atomic_store(&load.ready,true)
        return
    }
    make :: proc(load:^Shaders_Load) {
        started:=time.tick_now()
        load.built=render.renderer_shader_reload_build(load.candidate)
        load.making=time.duration_seconds(time.tick_since(started))
        sync.atomic_store(&load.ready,true)
    }
    load.worker=thread.create_and_start_with_poly_data(load,proc(load:^Shaders_Load) {
        defer free_all(context.temp_allocator)
        make(load)
    })
    if load.worker==nil {make(load)}
}

@(private)
shaders_load_discard :: proc(app:^App,load:^Shaders_Load) {
    if load.worker!=nil {
        thread.join(load.worker)
        thread.destroy(load.worker)
    }
    render.renderer_abort_shader_reload(load.candidate)
    render.shader_assets_destroy(&load.assets)
    render.program_catalog_destroy(&load.catalog)
    delete(load.folder,app.allocator)
    free(load,app.allocator)
}

// Between frames: the loads whose pipelines are made replace the generation
// the renderer runs, in the order they were asked for. One that a later load
// replaced already is dropped.
app_shaders_poll :: proc(app:^App) {
    sh:=&app.shaders
    r:=app.renderer
    for i:=0;i<len(sh.loads); {
        load:=sh.loads[i]
        if !sync.atomic_load(&load.ready) {i+=1;continue}
        if load.worker!=nil {
            thread.join(load.worker)
            thread.destroy(load.worker)
            load.worker=nil
        }
        dropped:=sync.atomic_load(&load.dropped)
        // Its codes were the resident ones when it was asked for; another load replaced them since.
        if !dropped && load.ticket>sh.published && load.built && load.candidate==nil && !render.shader_assets_match_codes(&load.assets,&r.shader_codes) {
            sync.atomic_store(&load.ready,false)
            shaders_load_build(app,load)
            i+=1
            continue
        }
        ordered_remove(&sh.loads,i)
        switch {
        case dropped,load.ticket<sh.published:
        case !load.built:
            sh.state=.Failed
            if load.candidate!=nil {log.errorf("shaders: the generation of %s was not taken: %s",load.folder,load.candidate.error)}
        case:
            if load.candidate!=nil {render.renderer_publish_shader_reload(r,&load.assets,load.candidate)}
            else {render.renderer_publish_shader_metadata(r,&load.assets)}
            r.programs=load.catalog
            r.programs.loaded=true
            load.catalog={}
            sh.published,sh.identity=load.ticket,load.identity
            sh.state=.Loaded
            sh.reloads+=1
            sh.published_frame=app.stats.frames
            if app.assets!=nil {assets_programs_refresh(app.assets)}
            log.infof("shaders: %s in use %.1f s after it was asked for, %.1f s of them making its pipelines",load.folder,time.duration_seconds(time.tick_since(load.asked)),load.making)
        }
        shaders_load_discard(app,load)
    }
}

// Every frame the loads that are ready go in; every SHADERS_POLL_FRAMES
// frames, a manifest that is not the one last read is a new generation. One
// that went away leaves the renderer as it is.
@(private)
app_shaders_watch :: proc(app:^App) {
    sh:=&app.shaders
    if app.renderer==nil {return}
    if len(sh.loads)>0 {app_shaders_poll(app)}
    if sh.root=="" {return}
    sh.frames+=1
    if sh.frames<SHADERS_POLL_FRAMES {return}
    sh.frames=0
    stamp:=shaders_stamp(project.shader_generation_find(sh.root,context.temp_allocator))
    if stamp==sh.stamp {return}
    if stamp=={} {
        sh.stamp={}
        return
    }
    app_shaders_reload(app)
}
