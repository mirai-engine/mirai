package physics_cache

import "core:math"
import "core:mem"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "base:runtime"

@(component,description="Plays baked rigid or fractured geometry without simulating physics. Negative rate reverses playback.")
Geometry_Playback :: struct {
    source:base.Asset_Id `mirai:"kind=.physics_cache"`,
    time:f32 `mirai:"min=0,unit=s"`,
    rate:f32,
    playing,loop:bool,
}

GEOMETRY_PLAYBACK_DEFAULT :: Geometry_Playback{rate=1,playing=true,loop=true}

Geometry_Request :: struct {entity:core.Entity,kind:enum u8 {Play,Pause,Seek,Rate},value:f32,restart:bool}
@(storage,queue)
Geometry_Requests :: struct {queue:core.Queue(Geometry_Request)}

play :: proc(requests:^Geometry_Requests,e:core.Entity,rate:f32=1,restart:bool=false) {core.push(&requests.queue,Geometry_Request{entity=e,kind=.Play,value=rate,restart=restart})}
pause :: proc(requests:^Geometry_Requests,e:core.Entity) {core.push(&requests.queue,Geometry_Request{entity=e,kind=.Pause})}
seek :: proc(requests:^Geometry_Requests,e:core.Entity,time:f32) {core.push(&requests.queue,Geometry_Request{entity=e,kind=.Seek,value=time})}
rate :: proc(requests:^Geometry_Requests,e:core.Entity,speed:f32) {core.push(&requests.queue,Geometry_Request{entity=e,kind=.Rate,value=speed})}

@(private)
Cache_Content :: struct {
    source:base.Asset_Id,
    file:asset.Asset,
    view:Cache_View,
    meshes:[]base.Asset_Id,
    stamp:[2]i64,
    checked:u64,
    error:asset.Error,
}

@(storage,host,free="cache_library_free")
Cache_Library :: struct {
    contents:[dynamic]Cache_Content,
    allocator:mem.Allocator,
    assets:^host.Assets,
    sampled:[]Playback_Piece,
    geometry:geom.Mesh_Buffer,
}

CACHE_SOURCES :: 64 // physics caches loaded at once

cache_library_free :: proc(library:^Cache_Library) {
    for &content in library.contents {cache_content_free(library,&content)}
    delete(library.contents)
    delete(library.sampled,library.allocator)
    if library.allocator.procedure!=nil {geom.mesh_buffer_destroy(&library.geometry)}
    library^={}
}

@(private)
cache_content_free :: proc(library:^Cache_Library,content:^Cache_Content) {
    if library.assets!=nil {for id in content.meshes {if id!={} {host.assets_mesh_release(library.assets,id)}}}
    delete(content.meshes,library.allocator)
    asset.asset_close(&content.file)
    content.view,content.meshes={},nil
}

@(private)
cache_content :: proc(library:^Cache_Library,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> ^Cache_View {
    content,_:=cache_content_find(library,assets,allocator,id)
    return content!=nil && content.error==.None?&content.view:nil
}

// The physics cache of an asset, read again when its file changes, and why
// it cannot be played: Too_Large when CACHE_SOURCES are loaded.
@(private)
cache_content_find :: proc(library:^Cache_Library,assets:^host.Assets,allocator:runtime.Allocator,id:base.Asset_Id) -> (^Cache_Content,asset.Error) {
    if library==nil || assets==nil {return nil,.Invalid}
    if id=={} {return nil,.Not_Found}
    if library.allocator.procedure==nil {
        library.allocator=allocator
        library.assets=assets
        geom.mesh_buffer_init(&library.geometry,allocator)
    }
    index:=-1
    for content,i in library.contents {if content.source==id {index=i;break}}
    if index<0 {
        if len(library.contents)>=CACHE_SOURCES {return nil,.Too_Large}
        if library.contents.allocator.procedure==nil {
            contents,error:=make([dynamic]Cache_Content,0,CACHE_SOURCES,allocator)
            if error!=nil {return nil,.Out_Of_Memory}
            library.contents=contents
        }
        index=len(library.contents)
        if append(&library.contents,Cache_Content{source=id})!=1 {return nil,.Out_Of_Memory}
    }
    content:=&library.contents[index]
    revision:=assets.revision+assets.registry.revision+1
    if content.checked==revision {return content,content.error}
    record,found:=asset.registry_find(&assets.registry,id)
    stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=revision;return content,content.error}
    fresh:=Cache_Content{source=id,stamp=stamp,checked=revision,error=.Not_Found}
    if found {
        fresh.error=host.assets_file(assets,id,PHYSICS_CACHE_KIND,&fresh.file)
        if fresh.error==.None {
            if fresh.file.blob.header.id!=id || !asset.blob_verify_hash(&fresh.file.blob) {fresh.error=.Corrupt}
            else {fresh.view,fresh.error=cache_view(&fresh.file,&assets.types)}
        }
    }
    if fresh.error==.None {
        allocation:mem.Allocator_Error
        fresh.meshes,allocation=make([]base.Asset_Id,len(fresh.view.tracks),allocator)
        if allocation!=nil {fresh.error=.Out_Of_Memory}
        if len(library.sampled)<len(fresh.view.tracks) {
            sampled,error:=make([]Playback_Piece,len(fresh.view.tracks),allocator)
            if error!=nil {fresh.error=.Out_Of_Memory}
            else {delete(library.sampled,allocator);library.sampled=sampled}
        }
    }
    if fresh.error==.None {
        for &track,index in fresh.view.tracks {
            if !cache_mesh(fresh.view,u32(index),&library.geometry) {fresh.error=.Out_Of_Memory;break}
            id,ok:=host.assets_mesh_generate(assets,geom.mesh_buffer_view(&library.geometry),track.materials[:])
            if !ok {fresh.error=.Out_Of_Memory;break}
            fresh.meshes[index]=id
        }
    }
    if fresh.error==.Out_Of_Memory {cache_content_free(library,&fresh);return nil,.Out_Of_Memory}
    cache_content_free(library,content)
    content^=fresh
    return content,content.error
}

// Why the Geometry_Playback of an entity plays nothing.
@(private)
source_problem :: proc(problems:^core.Problems,e:core.Entity,assets:^host.Assets,id:base.Asset_Id,error:asset.Error) {
    name:[base.ASSET_ID_TEXT]u8
    source:=host.assets_name(assets,id,&name)
    #partial switch error {
    case .None,.Invalid:
    case .Not_Found:
        if id=={} {
            core.report(problems,e,"physics_cache.source","its Geometry_Playback has no source, so it plays nothing; give Geometry_Playback.source a physics cache of the assets")
        } else {
            core.report(problems,e,"physics_cache.source","Geometry_Playback.source %s is not a physics cache of the assets, so it plays nothing; bake it again, or give source the id of a physics cache",source)
        }
    case .Too_Large:
        core.report(problems,e,"physics_cache.sources","Geometry_Playback.source %s is not played: %d physics caches are loaded, as many as fit; play fewer different caches",source,CACHE_SOURCES)
    case .Out_Of_Memory:
        core.report(problems,e,"physics_cache.memory","out of memory for physics cache %s of its Geometry_Playback, so it plays nothing; free memory, or bake a shorter cache",source)
    case:
        core.report(problems,e,"physics_cache.source","physics cache %s of its Geometry_Playback cannot be read (%v), so it plays nothing; bake it again",source,error)
    }
}

@(private)
player_advance :: proc(player:^Geometry_Playback,duration,dt:f32) {
    if !finite(player.time) {player.time=0}
    if !finite(player.rate) {player.rate=1}
    if !finite(duration) || duration<0 || !finite(dt) || dt<0 {return}
    if player.playing {player.time+=dt*player.rate}
    if player.loop && duration>0 {
        if player.time<0 || player.time>duration {player.time=f32(math.mod(f64(player.time),f64(duration)));if player.time<0 {player.time+=duration}}
    } else if player.time<0 || player.time>duration {player.time=clamp(player.time,0,duration);player.playing=false}
    if duration==0 {player.time=0}
}

@(step="fixed",stage="react")
physics_cache_update :: proc(players:^core.Table(Geometry_Playback),requests:^Geometry_Requests,library:^Cache_Library,time:core.Time,assets:^host.Assets,allocator:runtime.Allocator) {
    for request in core.take(&requests.queue) {
        player:=core.edit(players,request.entity)
        if player==nil {continue}
        if !finite(request.value) {continue}
        switch request.kind {
        case .Play:
            player.playing,player.rate=true,request.value
            if request.restart {view:=cache_content(library,assets,allocator,player.source);player.time=player.rate<0 && view!=nil?view.info.duration:0}
        case .Pause: player.playing=false
        case .Seek: player.time=max(request.value,0)
        case .Rate: player.rate=request.value
        }
    }
    for index in 0..<core.count(players) {
        player:=core.at(players,index)
        view:=cache_content(library,assets,allocator,player.source)
        if view==nil {continue}
        next:=player
        player_advance(&next,view.info.duration,time.dt)
        if next!=player {core.edit_at(players,index)^=next}
    }
}

@(step="render",loops="game editor",before="render_sync")
physics_cache_draw :: proc(players:core.Read(Geometry_Playback),worlds:core.Read(core.World_Transform),hidden:core.Read(render.Hidden),library:^Cache_Library,assets:^host.Assets,extras:^host.Frame_Extras,allocator:runtime.Allocator,problems:^core.Problems) {
    if assets==nil {return}
    for row in 0..<core.count(players) {
        e:=core.entity_at(players,row)
        if core.has(hidden,e) {continue}
        player:=core.at(players,row)
        content,error:=cache_content_find(library,assets,allocator,player.source)
        if content==nil || error!=.None {source_problem(problems,e,assets,player.source,error);continue}
        world,has:=core.get(worlds,e)
        if !has {continue}
        count:=cache_sample(content.view,player.time,library.sampled)
        for piece in library.sampled[:min(count,len(library.sampled))] {
            mesh:=content.meshes[piece.track]
            if mesh=={} {continue}
            pose:=mm.transform_compose(world.transform,piece.pose)
            instance,ok:=render.mesh_instance(assets,{mesh=mesh},mm.transform_matrix(pose))
            if !ok {continue}
            instance.object_id=u64(e)
            host.extras_instance_add(extras,instance)
        }
    }
}
