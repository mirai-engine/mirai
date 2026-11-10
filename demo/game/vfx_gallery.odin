package game

import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"
import vfx "plugins:vfx/runtime"

VFX_GALLERY_STATIONS :: 5

// A station of the VFX gallery (vfx_gallery/vfx.scene): what it shows, and where
// the camera looks at it from.
@(component)
Vfx_Gallery :: struct {
    station:u32,
    title:[64]u8 `mirai:"text"`,
    detail:[320]u8 `mirai:"text"`,
    origin:mm.Vec3 `mirai:"unit=m"`, // what the camera looks at
    eye:mm.Vec3 `mirai:"unit=m"`,    // where it looks from, from origin
}

// The camera of the gallery: the station it shows; -1 for the overview.
// volleys counts the volleys asked for with E, at the station shown then.
@(component)
Vfx_Gallery_View :: struct {
    station:i32 `mirai:"min=-1"`,
    volleys:u32 `mirai:"transient,readonly"`,
    volley_station:i32 `mirai:"transient,readonly"`,
}
VFX_GALLERY_VIEW_DEFAULT :: Vfx_Gallery_View{station=-1}

// Hits on a wall, given to its channel: one every interval
// while the world plays, somewhere on the rectangle of size along x and y of
// the entity, bouncing off along its +z; a volley of volley more with E at
// its station.
@(component)
Vfx_Impacts :: struct {
    channel:vfx.Particle_Channel_Name,
    size:[2]f32 `mirai:"min=0,unit=m"`,
    interval:f32 `mirai:"min=0,unit=s"`,
    speed:f32 `mirai:"unit=m/s"`,
    count:u32,  // particles of a hit; 0: those of the effect
    volley:u32,
    station:u32,
    clock:f32 `mirai:"transient,readonly"`,
    hits:u32 `mirai:"transient,readonly"`,
    volleys:u32 `mirai:"transient,readonly"`, // of the view it fired
}

@(step="input")
vfx_gallery_reset :: proc(views:core.Read(Vfx_Gallery_View),actions:inp.Frame_Input_Of(Action),scenes:^scene.Scene_Requests) {
    if core.count(views)>0 && inp.pressed(actions,.Physics_Reset) {scene.request_restart(scenes)}
}

@(step="fixed")
vfx_gallery_actions :: proc(views:^core.Table(Vfx_Gallery_View),actions:inp.Input_Of(Action),time:core.Time) {
    if !time.playing || !(time.dt>0) || core.count(core.read(views))==0 {return}
    previous,next,overview:=inp.pressed(actions,.Gallery_Previous),inp.pressed(actions,.Gallery_Next),inp.pressed(actions,.Gallery_Overview)
    use:=inp.pressed(actions,.Use)
    if !(previous || next || overview || use) {return}
    for &view in core.writable(views) {
        if overview {view.station=-1}
        if previous {view.station=(view.station+VFX_GALLERY_STATIONS-1)%%VFX_GALLERY_STATIONS if view.station>=0 else VFX_GALLERY_STATIONS-1}
        if next {view.station=(view.station+1)%%VFX_GALLERY_STATIONS}
        if use && view.station>=0 {view.volleys,view.volley_station=view.volleys+1,view.station}
    }
}

@(step="fixed")
vfx_gallery_impacts :: proc(impacts:^core.Table(Vfx_Impacts),views:core.Read(Vfx_Gallery_View),worlds:core.Read(core.World_Transform),channels:^vfx.Particle_Channels,time:core.Time) {
    if !time.playing || !(time.dt>0) {return}
    view:=core.at(views,0) if core.count(views)>0 else VFX_GALLERY_VIEW_DEFAULT
    for row in 0..<core.count(core.read(impacts)) {
        e:=core.entity_at(core.read(impacts),row)
        world,placed:=core.get(worlds,e)
        if !placed {continue}
        wall:=core.at(impacts,row)
        due:=u32(0)
        if view.volleys!=wall.volleys {
            if i32(wall.station)==view.volley_station {due=wall.volley}
            wall.volleys=view.volleys
        }
        if wall.interval>0 {
            wall.clock+=time.dt
            for wall.clock>=wall.interval {wall.clock-=wall.interval;due+=1}
        }
        origin:=mm.transform_point(world.transform,{0,0,0})
        out:=linalg.normalize0(mm.transform_point(world.transform,{0,0,1})-origin)
        for _ in 0..<min(due,64) {
            wall.hits+=1
            u,v:=vfx_gallery_random(wall.hits,1),vfx_gallery_random(wall.hits,2)
            at:=mm.transform_point(world.transform,{(u-0.5)*wall.size.x,(v-0.5)*wall.size.y,0})
            vfx.channel_emit(channels,wall.channel,vfx.Channel_Birth{position=at,velocity=out*wall.speed,count=wall.count})
        }
    }
}

// A number between 0 and 1 for the hit n, one for each of its uses.
@(private="file")
vfx_gallery_random :: proc(n,use:u32) -> f32 {
    return f32(base.hash_combine(u64(n),u64(use)*0x9e3779b97f4a7c15)>>40)/f32(1<<24)
}

@(step="late")
vfx_gallery_camera :: proc(views:core.Read(Vfx_Gallery_View),stations:core.Read(Vfx_Gallery),transforms:^core.Table(core.Transform)) {
    for row in 0..<core.count(views) {
        config:=core.at(views,row)
        position,target:=mm.Vec3{42,34,42},mm.Vec3{42,0,-2}
        for at in 0..<core.count(stations) {
            item:=core.at(stations,at)
            if i32(item.station)!=config.station {continue}
            target=item.origin
            position=target+(item.eye if item.eye!={} else mm.Vec3{0,2.5,7})
            break
        }
        entity:=core.entity_at(views,row)
        current,found:=core.get(core.read(transforms),entity)
        rotation:=mm.quat_look(target-position,{0,1,0})
        if found && (current.position!=position || current.rotation!=rotation) {
            if output:=core.free(transforms,entity);output!=nil {output.position,output.rotation=position,rotation}
        }
    }
}

@(step="ui")
vfx_gallery_hud :: proc(g:^gui.Gui,views:core.Read(Vfx_Gallery_View),stations:core.Read(Vfx_Gallery)) {
    ctx:=gui.gui_context(g)
    if ctx==nil || core.count(views)==0 {return}
    selected:=core.at(views,0).station
    title,detail,progress:="Particles and grids","Five exhibits of the plugin vfx, from particle lights to sprite materials.","Overview"
    for row in 0..<core.count(stations) {
        item:=core.at(stations,row)
        if i32(item.station)!=selected {continue}
        title,detail=base.text_get(item.title[:]),base.text_get(item.detail[:])
        progress=fmt.tprintf("Exhibit %d / %d",item.station+1,VFX_GALLERY_STATIONS)
        break
    }
    width:=min(650,ctx.size.x-40)
    box:=ui.Box{id=ui.id(ctx,"vfx.gallery.hud"),layout={width=ui.fixed(width),direction=.Column,padding=ui.padding_all(14),gap=5},float={to=.Surface,anchor=.Top_Left,pivot=.Top_Left,offset={20,20},layer=1000},fill={16,22,32,235},radius=8}
    if ui.box(ctx,box) {
        ui.label(ctx,progress,size=12,color={138,184,225,255})
        ui.label(ctx,title,size=20,color={255,255,255,255})
        ui.text(ctx,detail,{size=14,color={203,216,232,255},wrap=.Words},width=ui.fixed(width-28))
        ui.text(ctx,"Left / Right: exhibit    Home: overview    E: volley of impacts    R: reset scene",{size=13,color={255,210,116,255},wrap=.Words},width=ui.fixed(width-28))
    }
}
