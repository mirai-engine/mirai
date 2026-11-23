package game

import "core:math"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:engine/scene"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import cache "plugins:physics_cache/runtime"
import rag "plugins:ragdoll/runtime"

PHYSICS_GALLERY_STATIONS :: 23
PHYSICS_GALLERY_BURST :: "physics_gallery/physics_burst.scene"

@(component)
Physics_Gallery :: struct {
    station:u32,
    title:[64]u8 `mirai:"text"`,
    detail:[160]u8 `mirai:"text"`,
    origin:mm.Vec3,
    target,secondary,field:core.Entity,
    trigger:u32,
    fade_seconds:f32 `mirai:"min=0,unit=s"`,
}

@(component,derived)
Physics_Gallery_State :: struct {uses,activations:u32}

@(storage)
Physics_Gallery_Events :: struct {scene:core.Entity,counts:[PHYSICS_GALLERY_STATIONS]u32}

@(component)
Physics_Gallery_View :: struct {station:i32 `mirai:"min=-1"`}
PHYSICS_GALLERY_VIEW_DEFAULT :: Physics_Gallery_View{station=-1}

@(component,derived)
Physics_Gallery_View_State :: struct {station:i32}

@(component)
Physics_Gallery_Motion :: struct {origin:mm.Vec3,axis:mm.Vec3,amplitude,frequency:f32}

@(step="input")
physics_gallery_reset :: proc(views:^core.Table(Physics_Gallery_View,.Read),actions:inp.Frame_Input_Of(Action),scenes:^scene.Scene_Requests) {
    if core.count(views)>0 && inp.pressed(actions,.Physics_Reset) {scene.request_restart(scenes)}
}

@(step="fixed")
physics_gallery_actions :: proc(
    views:^core.Table(Physics_Gallery_View,.Read),selections:^core.Table(Physics_Gallery_View_State),
    stations:^core.Table(Physics_Gallery,.Read),states:^core.Table(Physics_Gallery_State),actions:inp.Input_Of(Action),
    requests:^destruct.Destruct_Requests,bodies:^phys.Body_Requests,force_fields:^core.Table(phys.Force_Field),strain_fields:^core.Table(destruct.Strain_Field),
    caches:^cache.Geometry_Requests,ragdolls:^Ragdoll_Gallery_Requests,time:core.Time,
    view:destruct.Destruct_View,problems:^core.Problems,
) {
    if !time.playing || !(time.dt>0) || core.count(views)==0 {return}
    previous,next,overview:=inp.pressed(actions,.Gallery_Previous),inp.pressed(actions,.Gallery_Next),inp.pressed(actions,.Gallery_Overview)
    use:=inp.pressed(actions,.Use)
    if previous || next || overview || use {
        for row in 0..<core.count(views) {
            camera:=core.entity_at(views,row)
            initial:=Physics_Gallery_View_State{station=core.at(views,row).station}
            selected:=demo_state(selections,camera,initial,problems)
            if selected==nil {continue}
            if overview {selected.station=-1}
            if previous {
                selected.station=(selected.station+PHYSICS_GALLERY_STATIONS-1)%%PHYSICS_GALLERY_STATIONS if selected.station>=0 else PHYSICS_GALLERY_STATIONS-1
            }
            if next {selected.station=(selected.station+1)%%PHYSICS_GALLERY_STATIONS}
            if !use || selected.station<0 {continue}
            for at in 0..<core.count(stations) {
                if i32(core.at(stations,at).station)!=selected.station {continue}
                e:=core.entity_at(stations,at)
                if state:=demo_state(states,e,Physics_Gallery_State{},problems);state!=nil {state.uses+=1}
            }
        }
    }
    for row in 0..<core.count(stations) {
        item:=core.view_at(stations,row)
        e:=core.entity_at(stations,row)
        before,_:=core.get(states,e)
        if use {if pending:=core.staged(states,e);pending!=nil {before=pending^}}
        trigger:=item.trigger+before.uses
        if trigger==before.activations {continue}
        needs_destructible:=item.station>0 && item.station<17 && item.station!=8 && item.station!=12 && item.station!=14
        if needs_destructible && destruct.pieces(view,item.target,nil)==0 {continue}
        state:=demo_state(states,e,Physics_Gallery_State{},problems)
        if state==nil {continue}
        state.activations=trigger
        point:=physics_gallery_piece_center(view,item.target,item.origin+mm.Vec3{0,.5,0}) if needs_destructible else item.origin
        switch item.station {
        case 0,8,19,21:
            phys.apply_area(bodies,volume.sphere(4),{position=item.origin+mm.Vec3{0,-.6,0}},35,impulse=true,per_mass=true,blend=4)
        case 22:
            phys.apply_area(bodies,volume.sphere(4),{position=item.origin+mm.Vec3{0,-1,0}},6,impulse=true,per_mass=true,blend=4)
        case 2,4,5,7:
            normal:=mm.Vec3{1,0,0} if trigger%2==1 else mm.Vec3{0,1,0}
            destruct.slice(requests,item.target,point,normal)
        case 11:
            if trigger%2==1 {destruct.weaken(requests,item.target,point,4,10000)}
            else {destruct.strain(requests,item.target,point,4,1)}
        case 12,14:
            // The force of the field and, where it has one, its strain: on and off together.
            if on,_,found:=core.raw_state(core.raw(force_fields),item.field);found {
                core.set_on(force_fields,item.field,!on)
                if _,_,strains:=core.raw_state(core.raw(strain_fields),item.field);strains {core.set_on(strain_fields,item.field,!on)}
            }
        case 17:
            cache.play(caches,item.target,1 if trigger%2==1 else -1,restart=true)
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
physics_gallery_motion :: proc(motions:^core.Table(Physics_Gallery_Motion,.Read),bodies:^phys.Body_Requests,time:core.Time) {
    if !time.playing {return}
    for row in 0..<core.count(motions) {
        motion:=core.at(motions,row)
        phys.move_kinematic(bodies,core.entity_at(motions,row),motion.origin+motion.axis*(motion.amplitude*math.sin(f32(time.tick)*time.dt*motion.frequency)))
    }
}

// Where the burst of a station shows, over the point of the event and toward the player.
physics_gallery_burst_at :: proc(point:mm.Vec3) -> mm.Vec3 {return point+mm.Vec3{0,.5,.8}}

@(step="fixed",stage="react")
physics_gallery_events :: proc(stations:^core.Table(Physics_Gallery,.Read),counts:^Physics_Gallery_Events,events:core.Ref(destruct.Destruct_Events),spawner:scene.Spawner,bodies:^phys.Body_Requests) {
    current,_:=core.first(stations)
    if current!=counts.scene {counts^=Physics_Gallery_Events{scene=current}}
    for event in events.fractured.items {
        if event.kind==.Remove {continue}
        for row in 0..<core.count(stations) {
            item:=core.at(stations,row)
            if item.target!=event.entity {continue}
            if item.station!=11 && item.station!=13 {
                center:=event.point-mm.Vec3{0,.5,.3} if event.kind==.Slice else item.origin-mm.Vec3{0,1,.3}
                phys.apply_area(bodies,volume.sphere(4),{position=center},3,impulse=true,per_mass=true)
            }
            if item.station<PHYSICS_GALLERY_STATIONS {counts.counts[item.station]+=1}
            if item.station==10 {
                scene.spawn(spawner,PHYSICS_GALLERY_BURST,{position=physics_gallery_burst_at(event.point)},transient=true)
            }
        }
    }
}

@(step="fixed")
physics_gallery_fade :: proc(stations:^core.Table(Physics_Gallery,.Read),view:destruct.Destruct_View,tints:^core.Table(render.Material_Values),time:core.Time) {
    if !(time.dt>0) {return}
    for row in 0..<core.count(stations) {
        station:=core.at(stations,row)
        if !(station.fade_seconds>0 && station.fade_seconds<=max(f32)) {continue}
        poses:[128]destruct.Group_Info
        count:=min(destruct.groups(view,station.target,poses[:]),len(poses))
        for group in poses[:count] {
            if !group.expires {continue}
            alpha:=clamp(core.seconds_of(time,u64(group.remaining_ticks))/station.fade_seconds,0,1)
            tint,has:=core.get(tints,group.entity)
            if !has {tint=render.MATERIAL_VALUES_DEFAULT}
            if tint.color.a==alpha {continue}
            tint.color.a=alpha
            if has {core.edit(tints,group.entity)^=tint} else {core.add(tints,group.entity,tint)}
        }
    }
}

@(step="late")
physics_gallery_camera :: proc(views:^core.Table(Physics_Gallery_View,.Read),selections:^core.Table(Physics_Gallery_View_State,.Read),stations:^core.Table(Physics_Gallery,.Read),transforms:^core.Table(core.Transform)) {
    for row in 0..<core.count(views) {
        e:=core.entity_at(views,row)
        selected,ready:=core.get(selections,e)
        station:=selected.station if ready else core.at(views,row).station
        position,target:=mm.Vec3{0,29,28},mm.Vec3{0,0,-18}
        for at in 0..<core.count(stations) {
            item:=core.at(stations,at)
            if i32(item.station)==station {target=item.origin+mm.Vec3{0,.8,0};position=target+mm.Vec3{3,2.5,5.5};break}
        }
        current,found:=core.get(transforms,e)
        rotation:=mm.quat_look(target-position,{0,1,0})
        if found && (current.position!=position || current.rotation!=rotation) {
            if output:=core.free(transforms,e);output!=nil {output.position,output.rotation=position,rotation}
        }
    }
}

// What the first line of physics_hud.ui counts of a station.
Physics_Hud_Line :: enum u8 {Overview,Counts,Playback,Ragdoll}

// What physics_hud.ui shows of the station the view it is on looks at.
@(component,description="The HUD of the gallery of physics: the station its view looks at and what happens in it.")
Physics_Gallery_Hud :: struct {
    line:Physics_Hud_Line,
    overview,station:bool, // it looks at all the stations, or at one
    number,count:i32, // the station, of how many
    pieces,bodies,actions,events:i32,
    playing,forward:bool, // of a station that plays a cache
    seconds:f32,          // where that cache is, in hundredths
    ragdoll:rag.Ragdoll_Mode,
    note:Physics_Hud_Note,
    title:[64]u8 `mirai:"text"`,
    detail:[160]u8 `mirai:"text"`,
}

// What the station of the suspended collection says in place of its detail.
Physics_Hud_Note :: enum u8 {Detail,Released,Strained}

PHYSICS_STRAIN_STATION :: 11
PHYSICS_CACHE_STATION :: 17
PHYSICS_RAGDOLL_STATION :: 18

@(step="frame")
physics_gallery_hud :: proc(huds:^core.Table(Physics_Gallery_Hud),views:^core.Table(Physics_Gallery_View,.Read),selections:^core.Table(Physics_Gallery_View_State,.Read),stations:^core.Table(Physics_Gallery,.Read),states:^core.Table(Physics_Gallery_State,.Read),counts:core.Ref(Physics_Gallery_Events),view:destruct.Destruct_View,players:^core.Table(cache.Geometry_Playback,.Read),ragdolls:^core.Table(rag.Ragdoll,.Read)) {
    for row in 0..<core.count(huds) {
        e:=core.entity_at(huds,row)
        looked:=core.get(views,e) or_continue
        selected,ready:=core.get(selections,e)
        station:=selected.station if ready else looked.station
        next:=Physics_Gallery_Hud{overview=true,count=PHYSICS_GALLERY_STATIONS}
        for at in 0..<core.count(stations) {
            item:=core.at(stations,at)
            if i32(item.station)!=station {continue}
            state,_:=core.get(states,core.entity_at(stations,at))
            next.line,next.overview,next.station,next.number,next.actions=.Counts,false,true,i32(item.station)+1,i32(state.activations)
            next.title=item.title
            next.detail=item.detail
            next.pieces,next.bodies=i32(destruct.pieces(view,item.target,nil)),i32(destruct.groups(view,item.target,nil))
            next.events=i32(counts.counts[item.station] if item.station<PHYSICS_GALLERY_STATIONS else 0)
            switch item.station {
            case PHYSICS_STRAIN_STATION:
                body,ready:=core.get(view.states,item.target)
                if ready && body.broken {next.note=.Released} else if state.activations>0 {next.note=.Strained}
            case PHYSICS_CACHE_STATION:
                if player,ready:=core.get(players,item.target);ready {
                    next.line,next.playing,next.forward,next.seconds=.Playback,player.playing,player.rate>=0,player.time
                }
            case PHYSICS_RAGDOLL_STATION:
                if config,ready:=core.get(ragdolls,item.target);ready {next.line,next.ragdoll=.Ragdoll,config.mode}
            }
            break
        }
        if core.at(huds,row)!=next {core.edit_at(huds,row)^=next}
    }
}
