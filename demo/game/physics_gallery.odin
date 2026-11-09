package game

import "core:fmt"
import "core:math"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import gui "mirai:engine/gui"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"
import cache "plugins:physics_cache/runtime"
import fields "plugins:physics_fields/runtime"
import rag "plugins:ragdoll/runtime"

PHYSICS_GALLERY_STATIONS :: 23
PHYSICS_GALLERY_SCENE :: "physics_gallery/physics.scene"
PHYSICS_GALLERY_BURST :: base.Asset_Id{0x6d697261695f7068,0x79735f6275727374}

@(component)
Physics_Gallery :: struct {
    station:u32,
    title:[64]u8 `mirai:"text"`,
    detail:[160]u8 `mirai:"text"`,
    origin:mm.Vec3,
    target,secondary,field:core.Entity,
    trigger:u32,
    fade_seconds:f32 `mirai:"min=0,unit=s"`,
    activations:u32 `mirai:"transient,readonly"`,
}

@(storage)
Physics_Gallery_Events :: struct {scene:core.Entity,counts:[PHYSICS_GALLERY_STATIONS]u32}

@(component)
Physics_Gallery_View :: struct {station:i32 `mirai:"min=-1"`}
PHYSICS_GALLERY_VIEW_DEFAULT :: Physics_Gallery_View{station=-1}

@(component)
Physics_Gallery_Motion :: struct {origin:mm.Vec3,axis:mm.Vec3,amplitude,frequency:f32}

@(step="input")
physics_gallery_reset :: proc(views:core.Read(Physics_Gallery_View),actions:inp.Frame_Input_Of(Action),scenes:^scene.Scene_Requests) {
    if core.count(views)>0 && inp.pressed(actions,.Physics_Reset) {scene.request_path(scenes,PHYSICS_GALLERY_SCENE)}
}

@(step="fixed")
physics_gallery_actions :: proc(
    views:^core.Table(Physics_Gallery_View),stations:^core.Table(Physics_Gallery),actions:inp.Input_Of(Action),
    requests:^destruct.Destruct_Requests,bodies:^phys.Body_Requests,field_configs:^core.Table(fields.Physics_Field),
    caches:^cache.Geometry_Requests,ragdolls:^Ragdoll_Gallery_Requests,time:core.Time,
    view:destruct.Destruct_View,
) {
    if !time.playing || !(time.dt>0) || core.count(core.read(views))==0 {return}
    previous,next,overview:=inp.pressed(actions,.Gallery_Previous),inp.pressed(actions,.Gallery_Next),inp.pressed(actions,.Gallery_Overview)
    use:=inp.pressed(actions,.Use)
    if previous || next || overview || use {for &view in core.writable(views) {
        if overview {view.station=-1}
        if previous {view.station=(view.station+PHYSICS_GALLERY_STATIONS-1)%%PHYSICS_GALLERY_STATIONS if view.station>=0 else PHYSICS_GALLERY_STATIONS-1}
        if next {view.station=(view.station+1)%%PHYSICS_GALLERY_STATIONS}
        if use && view.station>=0 {
            for &item in core.writable(stations) {if i32(item.station)==view.station {item.trigger+=1}}
        }
    }}
    for row in 0..<core.count(core.read(stations)) {
        held:=core.at(core.read(stations),row)
        if held.trigger==held.activations {continue}
        needs_destructible:=held.station>0 && held.station<17 && held.station!=8 && held.station!=12 && held.station!=14
        if needs_destructible && destruct.pieces(view,held.target,nil)==0 {continue}
        item:=core.at(stations,row)
        item.activations=item.trigger
        point:=physics_gallery_piece_center(view,item.target,item.origin+mm.Vec3{0,.5,0}) if needs_destructible else item.origin
        switch item.station {
        case 0,8,19,21:
            phys.apply_radial_impulse(bodies,item.origin+mm.Vec3{0,-.6,0},4,35,velocity_change=true)
        case 22:
            phys.apply_radial_impulse(bodies,item.origin+mm.Vec3{0,-1,0},4,6,velocity_change=true)
        case 2,4,5,7:
            normal:=mm.Vec3{1,0,0} if item.activations%2==1 else mm.Vec3{0,1,0}
            destruct.slice(requests,item.target,point,normal)
        case 11:
            if item.activations%2==1 {destruct.weaken(requests,item.target,point,4,10000)}
            else {destruct.strain(requests,item.target,point,4,1)}
        case 12,14:
            if on,_,found:=core.raw_state(core.raw(field_configs),item.field);found {
                if on {core.disable(field_configs,item.field)} else {core.enable(field_configs,item.field)}
            }
        case 17:
            cache.play(caches,item.target,1 if item.activations%2==1 else -1,restart=true)
        case 18:
            ragdoll_gallery_cycle(ragdolls,item.target)
        case 20:
            phys.apply_impulse(bodies,item.target,{30,10,0})
        case:
            destruct.strain(requests,item.target,point,4,300 if item.station==3 else 10000,impulse={0,30,0} if item.station==9 || item.station==10 else {})
        }
    }
}

physics_gallery_piece_center :: proc(view:destruct.Destruct_View,e:core.Entity,fallback:mm.Vec3) -> mm.Vec3 {
    pieces:[128]destruct.Piece_Info;poses:[128]destruct.Group_Info
    count:=min(destruct.pieces(view,e,pieces[:]),len(pieces))
    bodies:=min(destruct.groups(view,e,poses[:]),len(poses))
    for piece in pieces[:count] {
        if piece.body==0 {continue}
        for pose in poses[:bodies] {if pose.body==piece.body {return pose.position+mm.quat_rotate(pose.rotation,piece.center)}}
    }
    return fallback
}

@(step="fixed")
physics_gallery_motion :: proc(motions:core.Read(Physics_Gallery_Motion),transforms:^core.Table(core.Transform),time:core.Time) {
    if !time.playing {return}
    for row in 0..<core.count(motions) {
        motion:=core.at(motions,row)
        if local:=core.free(transforms,core.entity_at(motions,row));local!=nil {
            local.position=motion.origin+motion.axis*(motion.amplitude*math.sin(f32(time.tick)*time.dt*motion.frequency))
        }
    }
}

@(step="fixed",stage="react",after="destruct_step")
physics_gallery_events :: proc(stations:core.Read(Physics_Gallery),counts:^Physics_Gallery_Events,events:core.Ref(destruct.Destruct_Events),spawns:^scene.Spawns,bodies:^phys.Body_Requests) {
    current:=core.entity_at(stations,0) if core.count(stations)>0 else core.NONE
    if current!=counts.scene {counts^=Physics_Gallery_Events{scene=current}}
    for event in events.fractured.items {
        if event.kind==.Remove {continue}
        for row in 0..<core.count(stations) {
            item:=core.at(stations,row)
            if item.target!=event.entity {continue}
            if item.station!=11 && item.station!=13 {
                center:=event.point-mm.Vec3{0,.5,.3} if event.kind==.Slice else item.origin-mm.Vec3{0,1,.3}
                phys.apply_radial_impulse(bodies,center,4,3,.Constant,velocity_change=true)
            }
            if item.station<PHYSICS_GALLERY_STATIONS {counts.counts[item.station]+=1}
            if item.station==10 {
                core.push(&spawns.queue,scene.Spawn{prefab=PHYSICS_GALLERY_BURST,transform={event.point+mm.Vec3{0,.5,.8},1,{1,1,1}},transient=true})
            }
        }
    }
}

physics_gallery_fade :: proc(stations:core.Read(Physics_Gallery),view:destruct.Destruct_View,tints:^core.Table(render.Tint),time:core.Time) {
    if !(time.dt>0) {return}
    for row in 0..<core.count(stations) {
        station:=core.at(stations,row)
        if !(station.fade_seconds>0 && station.fade_seconds<=max(f32)) {continue}
        poses:[128]destruct.Group_Info
        count:=min(destruct.groups(view,station.target,poses[:]),len(poses))
        for group in poses[:count] {
            if !group.expires {continue}
            alpha:=clamp(f32(group.remaining_ticks)*time.dt/station.fade_seconds,0,1)
            tint,has:=core.get(core.read(tints),group.entity)
            if !has {tint=render.TINT_DEFAULT}
            if tint.color.a==alpha {continue}
            tint.color.a=alpha
            if has {core.get(tints,group.entity)^=tint} else {core.add(tints,group.entity,tint)}
        }
    }
}

@(step="late")
physics_gallery_camera :: proc(views:core.Read(Physics_Gallery_View),stations:core.Read(Physics_Gallery),transforms:^core.Table(core.Transform)) {
    for row in 0..<core.count(views) {
        config:=core.at(views,row)
        position,target:=mm.Vec3{0,29,28},mm.Vec3{0,0,-18}
        for at in 0..<core.count(stations) {
            item:=core.at(stations,at)
            if i32(item.station)==config.station {target=item.origin+mm.Vec3{0,.8,0};position=target+mm.Vec3{3,2.5,5.5};break}
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
physics_gallery_hud :: proc(g:^gui.Gui,views:core.Read(Physics_Gallery_View),stations:core.Read(Physics_Gallery),counts:core.Ref(Physics_Gallery_Events),view:destruct.Destruct_View,players:core.Read(cache.Geometry_Playback),ragdolls:core.Read(rag.Ragdoll)) {
    ctx:=gui.gui_context(g)
    if ctx==nil || core.count(views)==0 {return}
    selected:=core.at(views,0).station
    title,detail,progress:="Physics and destruction","18 destruction studies, plus ragdoll, chain, motor, character and water","Overview"
    for row in 0..<core.count(stations) {
        item:=core.at(stations,row)
        if i32(item.station)!=selected {continue}
        title,detail=base.text_get(item.title[:]),base.text_get(item.detail[:])
        progress=fmt.tprintf("Station %d / %d    pieces %d    bodies %d    actions %d    events %d",item.station+1,PHYSICS_GALLERY_STATIONS,destruct.pieces(view,item.target,nil),destruct.groups(view,item.target,nil),item.activations,counts.counts[item.station] if item.station<PHYSICS_GALLERY_STATIONS else 0)
        if item.station==11 {
            state,ready:=core.get(view.states,item.target)
            if ready && state.broken {detail="Pieces released without impulse. Gravity makes them fall. R restores the suspended collection."}
            else if item.activations>0 {detail="Rest strain stored; connections still hold. Press E to apply external strain and release pieces."}
        } else if item.station==17 {
            if player,ready:=core.get(players,item.target);ready {
                progress=fmt.tprintf("Station %d / %d    %s    %s    time %.2f s    actions %d",item.station+1,PHYSICS_GALLERY_STATIONS,"Playing" if player.playing else "Paused","Forward" if player.rate>=0 else "Reverse",player.time,item.activations)
            }
        } else if item.station==18 {
            if config,ready:=core.get(ragdolls,item.target);ready {
                progress=fmt.tprintf("Station %d / %d    %v    actions %d",item.station+1,PHYSICS_GALLERY_STATIONS,config.mode,item.activations)
            }
        }
        break
    }
    box:=ui.Box{id=ui.id(ctx,"physics.gallery.hud"),layout={width=ui.fixed(min(650,ctx.size.x-40)),direction=.Column,padding=ui.padding_all(14),gap=5},float={to=.Surface,anchor=.Top_Left,pivot=.Top_Left,offset={20,20},layer=1000},fill={16,22,32,235},radius=8}
    if ui.box(ctx,box) {
        ui.label(ctx,progress,size=12,color={138,184,225,255})
        ui.label(ctx,title,size=20,color={255,255,255,255})
        ui.text(ctx,detail,{size=14,color={203,216,232,255},wrap=.Words},width=ui.fixed(min(650,ctx.size.x-40)-28))
        ui.text(ctx,"Left / Right: station    Home: overview    E: action    R: reset scene",{size=13,color={255,210,116,255},wrap=.Words},width=ui.fixed(min(650,ctx.size.x-40)-28))
    }
}
