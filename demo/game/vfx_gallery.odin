package game

import "core:math/linalg"
import "mirai:core"
import inp "mirai:engine/input"
import "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"

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
    channel:[core.CHANNEL_NAME_BYTES]u8 `mirai:"text"`,
    size:[2]f32 `mirai:"min=0,unit=m"`,
    interval:f32 `mirai:"min=0,unit=s"`,
    speed:f32 `mirai:"unit=m/s"`,
    count:u32,  // particles of a hit; 0: those of the effect
    volley:u32,
    station:u32,
    next:u64 `mirai:"transient,readonly"`, // the tick of the next hit
    hits:u32 `mirai:"transient,readonly"`,
    volleys:u32 `mirai:"transient,readonly"`, // of the view it fired
}

@(step="input")
vfx_gallery_reset :: proc(views:^core.Table(Vfx_Gallery_View,.Read),actions:inp.Frame_Input_Of(Action),scenes:^scene.Scene_Requests) {
    if core.count(views)>0 && inp.pressed(actions,.Physics_Reset) {scene.request_restart(scenes)}
}

@(step="fixed")
vfx_gallery_actions :: proc(views:^core.Table(Vfx_Gallery_View),actions:inp.Input_Of(Action),time:core.Time) {
    if !time.playing || !(time.dt>0) || core.count(views)==0 {return}
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
vfx_gallery_impacts :: proc(impacts:^core.Table(Vfx_Impacts),views:^core.Table(Vfx_Gallery_View,.Read),worlds:^core.Table(core.World_Transform,.Read),births:^core.Births,time:core.Time) {
    if !time.playing || !(time.dt>0) {return}
    view:=core.at(views,0) if core.count(views)>0 else VFX_GALLERY_VIEW_DEFAULT
    for row in 0..<core.count(impacts) {
        e:=core.entity_at(impacts,row)
        world,placed:=core.get(worlds,e)
        if !placed {continue}
        wall:=core.edit_at(impacts,row)
        due:=u32(0)
        if view.volleys!=wall.volleys {
            if i32(wall.station)==view.volley_station {due=wall.volley}
            wall.volleys=view.volleys
        }
        if wall.interval>0 && core.due(time,wall.next) {wall.next,due=core.deadline(time,wall.interval),due+1}
        origin:=mm.transform_point(world.transform,{0,0,0})
        out:=linalg.normalize0(mm.transform_point(world.transform,{0,0,1})-origin)
        for _ in 0..<min(due,64) {
            wall.hits+=1
            u,v:=vfx_gallery_random(wall.hits,1),vfx_gallery_random(wall.hits,2)
            at:=mm.transform_point(world.transform,{(u-0.5)*wall.size.x,(v-0.5)*wall.size.y,0})
            core.push(&births.queue,core.Birth{channel=core.birth_channel(base.text_get(wall.channel[:])),position=at,velocity=out*wall.speed,count=wall.count})
        }
    }
}

// A number between 0 and 1 for the hit n, one for each of its uses.
@(private="file")
vfx_gallery_random :: proc(n,use:u32) -> f32 {
    return f32(base.hash_combine(u64(n),u64(use)*0x9e3779b97f4a7c15)>>40)/f32(1<<24)
}

@(step="late")
vfx_gallery_camera :: proc(views:^core.Table(Vfx_Gallery_View,.Read),stations:^core.Table(Vfx_Gallery,.Read),transforms:^core.Table(core.Transform)) {
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
        current,found:=core.get(transforms,entity)
        rotation:=mm.quat_look(target-position,{0,1,0})
        if found && (current.position!=position || current.rotation!=rotation) {
            if output:=core.free(transforms,entity);output!=nil {output.position,output.rotation=position,rotation}
        }
    }
}

// What vfx_hud.ui shows of the exhibit the view it is on looks at.
@(component,description="The HUD of the gallery of effects: the exhibit its view looks at.")
Vfx_Gallery_Hud :: struct {
    overview:bool, // it looks at all of them
    exhibit:bool,  // at one: number of count
    number,count:i32,
    title:[64]u8 `mirai:"text"`,
    detail:[320]u8 `mirai:"text"`,
}

@(step="frame")
vfx_gallery_hud :: proc(huds:^core.Table(Vfx_Gallery_Hud),views:^core.Table(Vfx_Gallery_View,.Read),stations:^core.Table(Vfx_Gallery,.Read)) {
    for row in 0..<core.count(huds) {
        view,has_view:=core.get(views,core.entity_at(huds,row))
        if !has_view {continue}
        next:=Vfx_Gallery_Hud{overview=true,count=VFX_GALLERY_STATIONS}
        for at in 0..<core.count(stations) {
            item:=core.at(stations,at)
            if i32(item.station)!=view.station {continue}
            next.overview,next.exhibit,next.number=false,true,i32(item.station)+1
            next.title,next.detail=item.title,item.detail
            break
        }
        core.edit_at(huds,row)^=next
    }
}
