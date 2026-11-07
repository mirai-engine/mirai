package host

import "mirai:asset"
import "mirai:platform"

@(private)
app_assets_create :: proc(app:^App,root,cache:string,mounts:[]asset.Registry_Mount=nil) -> App_Error {
    assets,error:=new(Assets,app.allocator)
    if error!=nil {return .Out_Of_Memory}
    if !assets_init(assets,{root=root,cache=cache,renderer=app.renderer,allocator=app.allocator,mounts=mounts}) {
        free(assets,app.allocator)
        return .Assets_Failed
    }
    app.assets=assets
    assets.load_profile=&app.load_profile
    // Without a watch nothing reloads; the application still runs.
    app.assets_watch.watch,_=platform.watch_create(app.platform,{path=root,recursive=true})
    return .None
}

@(private)
app_assets_destroy :: proc(app:^App) {
    if app.assets==nil {return}
    app_textures_stream_stop(app)
    app_assets_releases_stop(app)
    if app.assets_watch.watch!=0 {platform.watch_destroy(app.platform,app.assets_watch.watch)}
    assets_destroy(app.assets)
    free(app.assets,app.allocator)
    app.assets=nil
}

ASSETS_WATCH_SECONDS :: 1  // a pass over the asset folder takes about this long, at any frame rate
ASSETS_WATCH_SLICE :: 64   // units of platform.watch_poll in the frames that look
ASSETS_WATCH_RATE :: ASSETS_WATCH_SLICE*60 // units per second at most: the pass of a larger folder takes longer

app_assets_watch_reset :: proc(app:^App) {
    if app.assets_watch.watch!=0 {platform.watch_destroy(app.platform,app.assets_watch.watch)}
    app.assets_watch={}
    if app.assets!=nil {app.assets_watch.watch,_=platform.watch_create(app.platform,{path=app.assets.registry.root,recursive=true})}
}

@(private)
Assets_Watch :: struct {
    watch:platform.Watch,
    due:f32,   // units of the walk that time has earned
    spent:int, // units given since the last pass ended
    pass:int,  // units the last pass that walked the folder took; 0 before the first
    quiet:u64, // passes the system answered without a walk, as the watch counts them
}

// Looks at a part of the asset folder, paced by time so that it costs the
// same at any frame rate. The files that changed are refreshed in the
// registry and reloaded in place: a transaction between frames. A folder
// with more files than the watch remembers is scanned whole.
@(private)
app_assets_watch :: proc(app:^App,dt:f32) {
    aw:=&app.assets_watch
    if app.assets==nil || aw.watch==0 {return}
    rate:=f32(ASSETS_WATCH_RATE)
    if aw.pass>0 {rate=min(rate,f32(aw.pass)/ASSETS_WATCH_SECONDS)}
    aw.due=min(aw.due+rate*max(dt,0),ASSETS_WATCH_SLICE)
    if aw.due<ASSETS_WATCH_SLICE {return}
    aw.due-=ASSETS_WATCH_SLICE
    aw.spent+=ASSETS_WATCH_SLICE
    app.stats.watch_slices+=1
    events:[16]platform.Watch_Event
    count,complete:=platform.watch_poll(app.platform,aw.watch,ASSETS_WATCH_SLICE,events[:])
    if complete {
        quiet:=platform.watch_stats(app.platform,aw.watch).quiet
        if quiet==aw.quiet {aw.pass=aw.spent}
        aw.quiet,aw.spent=quiet,0
    }
    if count==0 {return}
    if platform.watch_stats(app.platform,aw.watch).untracked>0 {
        assets_scan(app.assets)
    } else {
        paths:[len(events)]string
        for event,at in events[:count] {paths[at]=event.path}
        assets_refresh(app.assets,paths[:count])
    }
    for event in events[:count] {
        if event.kind==.Removed {continue}
        if file,found:=asset.registry_find_path(&app.assets.registry,event.path);found {assets_reload(app.assets,file.id)}
    }
    content_refresh(app)
}

// A file of the folder changed, on disk or in memory, by whoever holds the
// assets: what was loaded from it is read again, as when the watch sees it.
app_asset_changed :: proc(app:^App,path:string) {
    a:=app.assets
    if a==nil {return}
    if file,found:=asset.registry_find_path(&a.registry,path);found && file.id!={} {assets_reload(a,file.id)}
    content_refresh(app)
}
