package game

import "core:math"
import "core:math/linalg"
import "mirai:core"
import inp "mirai:engine/input"
import gui "mirai:engine/gui"
import locomotion "plugins:locomotion/runtime"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Gallery_Kind :: enum u8 {Direct,Matching,Layered,Sync,Events,Root_Motion,Retarget,IK,Additive,Actions,Warp,Walker,Jumper,Spider,Sequence,Rig,Morph,Budget}

GALLERY_WAVE :: "Wave"   // axis of the wave space the additive station adds
GALLERY_ARM :: "Arm"     // layer of the greeting station: its weight
GALLERY_JOG :: "Jog"     // layer of the synchronized station: its weight
GALLERY_REACH :: "Reach" // motion window of the stride that ends at the goal of the warp station
GALLERY_MATCH_SPEED :: 4 // m/s the matching station is asked at most: about its jog
GALLERY_WARP_PERIOD :: 4 // s between the strides of the warp station
GALLERY_ACTIONS_PERIOD :: 6 // s between the greetings of the actions station; it steps halfway
GALLERY_JUMPER_SPEED :: 2 // m/s the jump station walks at

// What the automatic demo asks of a station at an age: the speed of the matching station, and the
// parameter of the stations that have one (gallery_parameter).
gallery_automatic :: proc(kind:Gallery_Kind,age:f32) -> (speed,value:f32) {
    #partial switch kind {
    case .Matching: speed=GALLERY_MATCH_SPEED*(.5-.5*math.cos(age*.5))
    case .Additive: value=.5+.5*math.cos(age*.31)
    case .Sync: value=.5+.5*math.sin(age*.7)
    case .Layered: value=f32(int(age/4)%2)
    }
    return
}

// The parameter of the .character a station sets with anim.set: the axis of its wave space, or the
// weight of its layer. Its value is values[0] of the station.
gallery_parameter :: proc "contextless" (kind:Gallery_Kind) -> string {
    #partial switch kind {
    case .Additive: return GALLERY_WAVE
    case .Sync: return GALLERY_JOG
    case .Layered: return GALLERY_ARM
    }
    return ""
}

// Whether a period starts in the tick that took the age from age-dt.
gallery_period :: proc "contextless" (age,dt,period,offset:f32) -> bool {
    return int(math.floor((age-offset)/period))!=int(math.floor((age-dt-offset)/period)) && age-offset>=0
}

// s the warp station turns in place toward its next goal before each stride.
GALLERY_WARP_TURN :: 1

// Where the warp station stands first: half its stride behind its origin, facing +Z.
gallery_warp_start :: proc "contextless" (item:Animation_Gallery) -> mm.Vec3 {return item.origin+mm.Vec3{0,0,-.5*item.stride}}

// The warp station walks between goals on either side of its origin: it turns in place toward the
// next one and strides to it, warped to end there. A cycle says which way it goes along Z
// (direction), whether it is turning (turn), whether its stride starts in this tick (start) and
// where its goal is, as a share of what its stride covers unwarped. Every few seconds on its own,
// or when the panel asks. A warp corrects what the clip nearly covers; asked for much less or
// more, the feet slide.
Gallery_Warp :: struct {share,direction:f32,turn,start:bool}

// values of the warp station: [0] the share of its stride, [1] the age at which the panel asked
// for one (0: none), [2] the direction of the last one.
gallery_warp :: proc(item:Animation_Gallery,dt:f32) -> (warp:Gallery_Warp) {
    last:=item.values[2] if item.values[2]!=0 else -1
    if item.manual {
        warp={share=item.values[0],direction=last}
        if asked:=item.values[1];asked>0 {
            warp.direction=-last
            warp.turn=item.age>=asked && item.age<asked+GALLERY_WARP_TURN
            warp.start=item.age>=asked+GALLERY_WARP_TURN && item.age-dt<asked+GALLERY_WARP_TURN
        }
        return
    }
    cycle:=int(math.floor((item.age-.5)/GALLERY_WARP_PERIOD))
    if cycle<0 {return {share=.8,direction=1}}
    warp={share=.8+.2*f32(cycle%%3),direction=1 if cycle%%2==0 else -1}
    warp.turn=item.age-.5-f32(cycle)*GALLERY_WARP_PERIOD<GALLERY_WARP_TURN
    warp.start=gallery_period(item.age,dt,GALLERY_WARP_PERIOD,.5+GALLERY_WARP_TURN)
    return
}

gallery_warp_goal :: proc "contextless" (item:Animation_Gallery,warp:Gallery_Warp) -> mm.Vec3 {
    return item.origin+mm.Vec3{0,0,warp.direction*(warp.share-.5)*item.stride}
}

@(component)
Gallery_Label :: struct {title:[64]u8 `mirai:"text"`,detail:[96]u8 `mirai:"text"`}

@(component,description="Configures this animation gallery station and records its playback and foot contact measurements.")
Animation_Gallery :: struct {
    kind:Gallery_Kind,
    title:[64]u8 `mirai:"text"`,
    detail:[96]u8 `mirai:"text"`,
    origin:mm.Vec3,
    stride:f32 `mirai:"unit=m"`, // what the clip of the warp station covers unwarped
    indicator,target:core.Entity,
    diagnostics:Animation_Gallery_Diagnostics `mirai:"hidden,readonly,transient"`,
    age:f32 `mirai:"hidden,readonly,transient"`,
    speed:f32 `mirai:"hidden,readonly,transient"`, // m/s the matching station is asked
    values:[4]f32 `mirai:"hidden,readonly,transient"`, // what its panel adjusts that is not on its Animation: the target of the IK, the distance of the warp
    grounded:bool `mirai:"hidden,readonly,transient"`,
    manual:bool `mirai:"hidden,readonly,transient"`,
}

Animation_Gallery_Diagnostics :: struct {
    events,jumps,landings:u32,
    states_seen:u32,
    foot_samples:u32,
    foot_error_max,root_distance:f32,
    stable_foot_samples:u32,
    stable_foot_error_max,stable_foot_rotation_error_max:f32,
    leg_stable_samples:[16]u32,
    leg_stable_error_max,leg_stable_rotation_error_max:[16]f32,
    swing_samples:u32,
    leg_swing_samples:[16]u32,
    airborne_samples,airborne_contact_violations:u32,
}

// The bodies of the gallery that walk on their own go back and forth along the walkway; the jumper
// jumps its obstacle. One that fell or wandered off goes back to its station.
@(step="fixed",after="gallery_player_move")
gallery_move_inputs :: proc(gallery:core.Read(Animation_Gallery),inputs:^core.Table(inp.Move_Input),walks:core.Read(locomotion.Walk),worlds:core.Read(core.World_Transform),placer:core.Placer,seats:inp.Players,walk_actions:inp.Input_Of(locomotion.Walk_Action),time:core.Time) {
    for row in 0..<core.count(gallery) {
        entity:=core.entity_at(gallery,row)
        item:=core.at(gallery,row)
        placed,exists:=core.get(worlds,entity)
        if !exists {continue}
        home:=gallery_warp_start(item) if item.kind==.Warp else item.origin+(mm.Vec3{} if item.kind==.Actions else mm.Vec3{0,.05,1.2})
        #partial switch item.kind {
        case .Actions,.Warp:
            // The warp walks up to its stride from its origin; past that, or fallen, it goes back.
            limit:=1.2*item.stride if item.kind==.Warp else 2.6
            if placed.position.y< -2 || linalg.length((placed.position-item.origin).xz)>limit {core.place(placer,entity,home,at_rest=true)}
            // While it turns toward its next goal its motor is off: it stands and faces that way.
            if item.kind==.Warp {
                if warp:=gallery_warp(item,time.dt);warp.turn {
                    if input:=core.edit(inputs,entity);input!=nil {
                        // Half a turn in a bit less than the time it has, so that it faces its goal before it strides.
                        desired:=f32(math.PI) if warp.direction>0 else 0
                        input.move,input.buttons={},{}
                        input.look_yaw=mm.angle_wrap(mm.angle_approach(yaw_of(placed.rotation),desired,1.25*math.PI/GALLERY_WARP_TURN*time.dt))
                    }
                }
            }
            continue
        case .Walker,.Jumper,.Spider:
        case: continue
        }
        if owner,driven:=core.get(seats.drivables,entity);driven && owner.seat!=core.NONE {continue}
        input:=core.edit(inputs,entity)
        config,configured:=core.get(walks,entity)
        if input==nil || !configured {continue}
        input.move,input.buttons={},{}
        target:=item.origin
        target.z+=1.25 if int(item.age/3)%2==0 else -1.25
        delta:=target.z-placed.position.z
        wish:mm.Vec3
        // The jumper walks faster, so that its jump carries it over its obstacle.
        if config.max_speed>0 && abs(delta)>.08 {wish.z=clamp(delta*2,-1,1)*(GALLERY_JUMPER_SPEED if item.kind==.Jumper else 1)/max(config.max_speed,1)}
        gallery_move(input,placed.rotation,wish,time.dt)
        // The jumper takes off just before the obstacle at its origin when it walks toward it.
        ahead:=(item.origin.z-placed.position.z)*math.sign(delta)
        if item.kind==.Jumper && ahead>.7 && ahead<1.05 {input.buttons|=inp.action_bit(inp.action_of(walk_actions,.Jump))}
        if placed.position.y< -2 || linalg.length((placed.position-item.origin).xz)>4 {core.place(placer,entity,home,at_rest=true)}
    }
}

gallery_direct_clips :: proc(gallery:core.Read(Animation_Gallery),animations:^core.Table(anim.Animation),requests:^anim.Animation_Requests,commands:[]Gallery_Command) {
    for row in 0..<core.count(gallery) {
        item:=core.at(gallery,row)
        entity:=core.entity_at(gallery,row)
        if item.kind!=.Direct || gallery_manual(item.manual,entity,commands) {continue}
        value,found:=core.get(animations,entity)
        if !found {continue}
        phase:=int(item.age/3)%3
        wanted:="wave" if phase==1 else "walk"
        speed:=f32(-1) if phase==2 else f32(1)
        if base.text_get(value.clip[:])!=wanted || value.speed!=speed {
            next:=core.edit(animations,entity)
            base.text_set(next.clip[:],wanted);next.speed=speed
            anim.animation_seek(requests,entity,1.5 if phase==2 else 0)
        }
    }
}

// The bodies that walk by their physics plant their feet only while they stand on the ground.
// It reads the gallery as gallery_observe left it in the last tick.
@(step="fixed",stage="react",before="gallery_observe")
gallery_control :: proc(gallery:core.Read(Animation_Gallery),players:core.Read(Gallery_Player),characters:core.Read(phys.Character_State),requests:^anim.Modifier_Requests) {
    ground :: proc(characters:core.Read(phys.Character_State),requests:^anim.Modifier_Requests,entity:core.Entity) {
        character,exists:=core.get(characters,entity)
        if exists {anim.modifier_goal(requests,{rig=entity,kind=.Grounding,weight=1 if character.standing else 0,enabled=true})}
    }
    for row in 0..<core.count(gallery) {
        kind:=core.at(gallery,row).kind
        if kind==.Walker || kind==.Jumper || kind==.Spider {ground(characters,requests,core.entity_at(gallery,row))}
    }
    for row in 0..<core.count(players) {ground(characters,requests,core.at(players,row).mirai)}
}

// The matching station is told the speed it walks at and now and then plays a wave over its whole
// body, entered and left by inertialization; the additive, greeting and synchronized stations set
// their parameter; the actions station greets and steps; the warp station strides to its goal.
@(step="fixed")
gallery_animate :: proc(gallery:core.Read(Animation_Gallery),animations:^core.Table(anim.Animation),worlds:core.Read(core.World_Transform),time:core.Time,requests:^anim.Animation_Requests,goals:^anim.Modifier_Requests,motion:^anim.Motion_Requests,playback:core.Ref(anim.Playback),motors:^core.Table(Animation_Motor),ui_events:core.Ref(gui.UI_Events),names:core.Read(core.Name),panel:core.Ref(Gallery_UI),morphs:core.Read(Morph_Playground),morph_weights:^core.Table(anim.Morph_Weights)) {
    if morphs.table!=nil && morph_weights!=nil {morph_playground_animate(morphs,requests,morph_weights,time)}
    for event in ui_events.items {if event.kind==.Clicked && event.name==base.name_hash("toggle") {if value:=core.edit(animations,core.entity_named(names,SHOWCASE_LIFT));value!=nil {value.playing=!value.playing}}}
    commands:=panel.commands[:panel.count]
    gallery_playback_commands(commands,animations,requests,goals)
    gallery_direct_clips(gallery,animations,requests,commands)
    for row in 0..<core.count(gallery) {
        entity:=core.entity_at(gallery,row)
        item:=core.at(gallery,row)
        if item.target!=core.NONE {
            anim.modifier_goal(goals,{rig=entity,kind=.IK,target=anim.spatial_entity(item.target),weight=1,enabled=true})
            anim.look(requests,entity,anim.spatial_entity(item.target))
        }
        manual:=gallery_manual(item.manual,entity,commands)
        speed,value:=gallery_automatic(item.kind,item.age)
        #partial switch item.kind {
        case .Matching:
            placed,_:=core.get(worlds,entity)
            forward:=mm.quat_forward(placed.rotation)
            velocity:=forward*(item.speed if manual else speed)
            anim.match_goal(requests,{rig=entity,mode=u16(locomotion.MODE_WALKING),velocity=velocity,desired=velocity,facing=forward})
            if !manual && gallery_period(item.age,time.dt,9,4.5) {anim.play(requests,entity,"Wave")}
        case .Additive,.Sync,.Layered:
            anim.set(requests,entity,gallery_parameter(item.kind),item.values[0] if manual else value)
        case .Actions:
            if manual {continue}
            if gallery_period(item.age,time.dt,GALLERY_ACTIONS_PERIOD,1) {anim.play(requests,entity,"Greet")}
            if gallery_period(item.age,time.dt,GALLERY_ACTIONS_PERIOD,1+GALLERY_ACTIONS_PERIOD*.5) {anim.play(requests,entity,"Step")}
        case .Warp:
            // It turns in idle with its motor off, strides by its root motion to the goal and waits
            // there in idle.
            animation:=core.edit(animations,entity)
            if animation==nil {continue}
            warp:=gallery_warp(item,time.dt)
            if warp.turn {
                if motor:=core.edit(motors,entity);motor!=nil && motor.enabled {motor.enabled=false}
                if base.text_get(animation.clip[:])!="idle" {anim.animation_clip(animation,"idle",.2,loop=true)}
            }
            if warp.start {
                if motor:=core.edit(motors,entity);motor!=nil {motor.enabled=true}
                anim.motion_target(motion,entity,GALLERY_REACH,anim.spatial_point(gallery_warp_goal(item,warp)))
                animation.playing=true
                anim.animation_clip(animation,"stride",.2,loop=false)
            } else if _,_,ended,ok:=anim.animation_progress(playback.ptr,entity);ok && ended && base.text_get(animation.clip[:])=="stride" {
                anim.animation_clip(animation,"idle",.3,loop=true)
            }
        }
    }
}

@(step="fixed",stage="apply")
gallery_root_motion :: proc(gallery:core.Read(Animation_Gallery),transforms:^core.Table(core.Transform),playback:core.Ref(anim.Playback)) {
    for row in 0..<core.count(gallery) {
        item:=core.at(gallery,row)
        if item.kind!=.Root_Motion {continue}
        entity:=core.entity_at(gallery,row)
        motion,exists:=anim.animation_root_delta(playback.ptr,entity)
        if !exists {continue}
        if root:=core.free(transforms,entity);root!=nil {
            root.position+=mm.quat_rotate(root.rotation,motion.translation*root.scale)
            root.rotation=linalg.normalize(root.rotation*motion.rotation)
            forward:=mm.quat_forward(root.rotation)
            along:=linalg.dot(root.position-item.origin,forward)
            if along>1.4 {root.position-=forward*2.8}
            if along< -1.4 {root.position+=forward*2.8}
        }
    }
}

// Where the IK station puts its target, in the frame of its actor: the panel's height and reach
// when adjusted, a slow circle in front of the hand otherwise.
gallery_ik_target :: proc(item:Animation_Gallery) -> mm.Vec3 {
    if item.manual {return {.42,item.values[0],-item.values[1]}}
    return {.42-.15*math.sin(item.age),1.3+.12*math.cos(item.age),-.42}
}

@(step="fixed",stage="react")
gallery_observe :: proc(gallery:^core.Table(Animation_Gallery),transforms:^core.Table(core.Transform),characters:core.Read(phys.Character_State),moving:core.Read(core.Motion),events:core.Ref(anim.Animation_Events),playback:core.Ref(anim.Playback),grounding:core.Ref(anim.Grounding_Runtime),modifiers:core.Ref(anim.Modifier_Runtime),time:core.Time,panel:^Gallery_UI) {
    if !time.playing {return}
    feet:=core.read(&modifiers.grounding)
    commands:=panel.commands[:panel.count]
    for &item,row in core.writable(gallery) {
        entity:=gallery.entities[row]
        // The warp asks with the age gallery_animate saw, before it advances.
        if item.kind==.Warp {
            if warp:=gallery_warp(item,time.dt);warp.start {item.values[0],item.values[1],item.values[2]=warp.share,0,warp.direction}
            for command in commands {if command.entity==entity && command.kind==.Warp {item.values[1]=max(item.age,1e-3)}}
        }
        item.manual=gallery_manual(item.manual,entity,commands)
        item.age+=time.dt
        if !item.manual {
            // The panel shows what the automatic demo asks.
            speed,value:=gallery_automatic(item.kind,item.age)
            if item.kind==.Matching {item.speed=speed}
            if gallery_parameter(item.kind)!="" {item.values[0]=value}
        }
        for command in commands {
            if command.entity!=entity {continue}
            if command.kind==.Speed {item.speed=command.value}
            if command.kind==.Value && int(command.slot)<len(item.values) {item.values[command.slot]=command.value}
        }
        if item.kind==.Warp {
            if item.values[0]==0 {item.values[0]=1}
            // The goal shows where its next stride ends.
            if goal:=core.free(transforms,item.indicator);goal!=nil {goal.position=gallery_warp_goal(item,gallery_warp(item,time.dt))+mm.Vec3{0,.1,0}}
        }
        for marker in events.items {if marker.entity==entity {item.diagnostics.events+=1}}
        if item.kind==.Events && item.indicator!=core.NONE {
            value:=anim.animation_curve(playback.ptr,entity,"pulse")
            {if visual:=core.free(transforms,item.indicator);visual!=nil {visual.scale={.12+.22*value,.12+.22*value,.12+.22*value}}}
        }
        if item.kind==.IK && item.target!=core.NONE {
            local:=gallery_ik_target(item)
            if !item.manual {item.values[0],item.values[1]=local.y,-local.z}
            actor,_:=core.get(transforms,entity)
            if target:=core.free(transforms,item.target);target!=nil {target.position=item.origin+mm.quat_rotate(actor.rotation,local)}
        }
        if item.kind==.Root_Motion {
            motion,exists:=anim.animation_root_delta(playback.ptr,entity)
            if exists {item.diagnostics.root_distance+=linalg.length(motion.translation)}
        }
        going,_:=core.get(moving,entity)
        if character,exists:=core.get(characters,entity);exists {
            if item.grounded && !character.standing && going.linear.y>.1 {item.diagnostics.jumps+=1}
            if !item.grounded && character.standing && item.age>.2 {item.diagnostics.landings+=1}
            item.grounded=character.standing
            item.diagnostics.states_seen|=1 if character.standing else 2 if going.linear.y>0 else 4
            if !character.standing {
                item.diagnostics.airborne_samples+=1
                if config,present:=core.get(feet,entity);present && config.global_contact!=0 {item.diagnostics.airborne_contact_violations+=1}
            }
        }
        for &record in grounding.records {
            if record.rig!=entity || record.count<=0 {continue}
            for target,i in record.targets[:record.count] {
                for &pose in playback.states {
                    if pose.entity!=entity || !pose.pose_ready {continue}
                    bone:=record.bones[i][2]
                    if bone<0 || bone>=len(pose.world) {continue}
                    if record.mode==.Animated && !record.placements[i].anchor.active {
                        if config,present:=core.get(feet,entity);present {
                            leg:=config.legs[i]
                            offset:=leg.contact_offset if leg.contact_bone!={} else leg.sole_height
                            clearance:=linalg.dot(record.previous[i].position-pose.world[0].position,linalg.normalize0(config.up))-offset
                            if config.global_contact>=.8 && leg.contact>=.8 && clearance>.06 {item.diagnostics.swing_samples+=1;item.diagnostics.leg_swing_samples[i]+=1}
                        }
                    }
                    if target.weight<.8 {continue}
                    item.diagnostics.foot_samples+=1
                    item.diagnostics.foot_error_max=max(item.diagnostics.foot_error_max,linalg.length(pose.world[bone].position-target.position))
                    locked:=!record.legs[i].swinging && record.legs[i].anchor.active && record.legs[i].weight>=.99 if record.mode==.Procedural else record.placements[i].anchor.active && record.placements[i].weight>=.99
                    if locked && target.weight>=.99 {
                        error:=linalg.length(pose.world[bone].position-target.position)
                        item.diagnostics.stable_foot_samples+=1;item.diagnostics.stable_foot_error_max=max(item.diagnostics.stable_foot_error_max,error)
                        item.diagnostics.leg_stable_samples[i]+=1;item.diagnostics.leg_stable_error_max[i]=max(item.diagnostics.leg_stable_error_max[i],error)
                        rotation_error:=mm.quat_angle(pose.world[bone].rotation,record.rotations[i])
                        item.diagnostics.stable_foot_rotation_error_max=max(item.diagnostics.stable_foot_rotation_error_max,rotation_error)
                        item.diagnostics.leg_stable_rotation_error_max[i]=max(item.diagnostics.leg_stable_rotation_error_max[i],rotation_error)
                    }
                }
            }
        }
    }
    panel.count=0
}
