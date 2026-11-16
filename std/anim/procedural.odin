package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import math "mirai:std/math"

limb_height_range :: proc "contextless" (hip,target,up:math.Vec3,length:f32) -> (minimum,maximum:f32,ok:bool) {
    direction,valid:=anim_unit(up)
    if !valid || !anim_vec3_valid(hip) || !anim_vec3_valid(target) || !anim_finite(length) || length<=0 {return}
    delta:=hip-target
    if !anim_vec3_valid(delta) {return}
    height:=f64(delta.x)*f64(direction.x)+f64(delta.y)*f64(direction.y)+f64(delta.z)*f64(direction.z)
    horizontal:=f64(delta.x)*f64(delta.x)+f64(delta.y)*f64(delta.y)+f64(delta.z)*f64(delta.z)-height*height
    squared:=f64(length)*f64(length)-max(horizontal,0)
    if squared<0 {return}
    extent:=cmath.sqrt(squared)
    minimum,maximum=f32(-height-extent),f32(-height+extent)
    return minimum,maximum,anim_finite(minimum) && anim_finite(maximum)
}

Surface_Support :: struct {id:u64,transform:math.Transform}
Surface_Contact :: struct {
    position,normal:math.Vec3,
    support:u64,
    support_transform:math.Transform,
    valid:bool,
}
Surface_Anchor :: struct {
    support:u64,
    local_position,local_normal:math.Vec3,
    position,normal:math.Vec3,
    active:bool,
}

@(private)
surface_transform_valid :: proc "contextless" (transform:math.Transform) -> bool {
    if !anim_transform_valid(transform) {return false}
    for axis in transform.scale {if abs(axis)<1e-8 {return false}}
    return true
}

@(private)
surface_contact_valid :: proc "contextless" (contact:Surface_Contact) -> bool {
    if !contact.valid {return true}
    _,normal_ok:=anim_unit(contact.normal)
    return anim_vec3_valid(contact.position) && normal_ok && (contact.support==0 || surface_transform_valid(contact.support_transform))
}

@(private)
surface_anchor_valid :: proc "contextless" (anchor:Surface_Anchor) -> bool {
    if !anim_vec3_valid(anchor.position) || !anim_vec3_valid(anchor.normal) {return false}
    if !anchor.active {return true}
    _,normal_ok:=anim_unit(anchor.normal)
    if !normal_ok {return false}
    if anchor.support==0 {return true}
    _,normal_ok=anim_unit(anchor.local_normal)
    return normal_ok && anim_vec3_valid(anchor.local_position)
}

surface_anchor_set :: proc "contextless" (anchor:^Surface_Anchor,contact:Surface_Contact) -> bool {
    if anchor==nil || !contact.valid || !surface_contact_valid(contact) {return false}
    normal,_:=anim_unit(contact.normal)
    next:=Surface_Anchor{support=contact.support,position=contact.position,normal=normal,active=true}
    if contact.support!=0 {
        next.local_position=math.transform_inverse_point(contact.support_transform,contact.position)
        next.local_normal,_=anim_unit(math.quat_rotate(conj(contact.support_transform.rotation),normal)*contact.support_transform.scale)
        if !anim_vec3_valid(next.local_position) || next.local_normal=={} {return false}
    }
    anchor^=next
    return true
}

surface_anchor_follow :: proc "contextless" (anchor:^Surface_Anchor,supports:[]Surface_Support) -> bool {
    if anchor==nil || !anchor.active || !surface_anchor_valid(anchor^) {return false}
    if anchor.support==0 {return true}
    if !anim_vec3_valid(anchor.local_position) || !anim_vec3_valid(anchor.local_normal) {return false}
    for support in supports {
        if support.id!=anchor.support {continue}
        if !surface_transform_valid(support.transform) {return false}
        position:=math.transform_point(support.transform,anchor.local_position)
        normal,ok:=anim_unit(math.quat_rotate(support.transform.rotation,anchor.local_normal/support.transform.scale))
        if !ok || !anim_vec3_valid(position) {return false}
        anchor.position,anchor.normal=position,normal
        return true
    }
    anchor.active=false
    return false
}

Foot_Placement_Config :: struct {release_distance,replant_distance,blend_time:f32}
FOOT_PLACEMENT_CONFIG_DEFAULT :: Foot_Placement_Config{0.5,0.3,0.1}
Foot_Placement_State :: struct {anchor:Surface_Anchor,offset:math.Vec3,weight:f32,blocked:bool}

foot_placement_update :: proc "contextless" (state:^Foot_Placement_State,animated:math.Vec3,contact:Surface_Contact,supports:[]Surface_Support,strength,dt:f32,config:Foot_Placement_Config=FOOT_PLACEMENT_CONFIG_DEFAULT) -> (Foot_Target,bool) {
    if state==nil || !anim_vec3_valid(animated) || !surface_contact_valid(contact) || !anim_finite(strength) || !anim_finite(dt) || dt<0 || !anim_finite(config.release_distance) || !anim_finite(config.replant_distance) || config.replant_distance<0 || config.release_distance<config.replant_distance || !anim_finite(config.blend_time) || config.blend_time<0 || !anim_finite(state.weight) || state.weight<0 || state.weight>1 || !surface_anchor_valid(state.anchor) || !anim_vec3_valid(state.offset) {return {},false}
    if state.anchor.active {surface_anchor_follow(&state.anchor,supports)}
    active:=contact.valid && strength>0.5
    distance:=linalg.length(animated-state.anchor.position)
    if state.anchor.active && distance>config.release_distance {state.blocked=true;state.anchor.active=false}
    if !active || (state.blocked && distance<=config.replant_distance) {state.blocked=false}
    if !active {state.anchor.active=false}
    if active && !state.anchor.active && !state.blocked {
        if !surface_anchor_set(&state.anchor,contact) {return {},false}
    }
    if state.anchor.active {state.offset=state.anchor.position-animated}
    if !anim_vec3_valid(state.offset) {return {},false}
    goal:=math.saturate(strength) if state.anchor.active else 0
    blend:=min(dt/config.blend_time,1) if config.blend_time>0 else 1
    state.weight+=clamp(goal-state.weight,-blend,blend)
    position:=animated+state.offset if state.weight>0 else animated
    if !anim_vec3_valid(position) {return {},false}
    return {position,state.anchor.normal,state.weight},true
}

Gait_Leg :: struct {
    phase,step_distance,step_height,step_duration,max_distance,contact:f32,
}
GAIT_LEG_DEFAULT :: Gait_Leg{phase=0,step_distance=0.2,step_height=0.15,step_duration=0.2,max_distance=1,contact=1}
Gait_Config :: struct {cycle_duration,swing_fraction,blend_time:f32,max_swinging:int,up:math.Vec3}
GAIT_CONFIG_DEFAULT :: Gait_Config{cycle_duration=0.8,swing_fraction=0.4,blend_time=0.1,max_swinging=1,up={0,1,0}}
Gait_State :: struct {phase:f32,next_leg:u32}
Gait_Leg_State :: struct {
    anchor,landing:Surface_Anchor,
    from,from_normal,offset:math.Vec3,
    elapsed,weight:f32,
    swinging:bool,
}

gait_step_position :: proc "contextless" (from,to,up:math.Vec3,height,progress:f32) -> (math.Vec3,bool) {
    direction,ok:=anim_unit(up)
    if !ok || !anim_vec3_valid(from) || !anim_vec3_valid(to) || !anim_finite(height) || height<0 || !anim_finite(progress) {return {},false}
    t:=math.saturate(progress)
    smooth:=t*t*(3-2*t)
    lift:=16*t*t*(1-t)*(1-t)
    result:=from+(to-from)*smooth+direction*(height*lift)
    return result,anim_vec3_valid(result)
}

gait_update :: proc "contextless" (
    config:Gait_Config,legs:[]Gait_Leg,contacts:[]Surface_Contact,supports:[]Surface_Support,
    desired:[]math.Vec3,state:^Gait_State,states:[]Gait_Leg_State,dt:f32,moving:bool,out:[]Foot_Target,
) -> bool {
    count:=len(legs)
    _,up_ok:=anim_unit(config.up)
    if state==nil || count==0 || u64(count)>u64(max(u32)) || len(contacts)!=count || len(desired)!=count || len(states)!=count || len(out)!=count || !up_ok || !anim_finite(dt) || dt<0 || !anim_finite(config.cycle_duration) || config.cycle_duration<=0 || !anim_finite(config.swing_fraction) || config.swing_fraction<=0 || config.swing_fraction>1 || !anim_finite(config.blend_time) || config.blend_time<0 || config.max_swinging<=0 || !anim_finite(state.phase) || state.phase<0 || state.phase>=1 {return false}
    for support,i in supports {
        if support.id==0 || !surface_transform_valid(support.transform) {return false}
        for j in 0..<i {if supports[j].id==support.id {return false}}
    }
    for leg,i in legs {
        current:=states[i]
        if !anim_finite(leg.phase) || leg.phase<0 || !anim_vec3_valid(current.offset) || leg.phase>=1 || !anim_finite(leg.step_distance) || leg.step_distance<0 || !anim_finite(leg.step_height) || leg.step_height<0 || !anim_finite(leg.step_duration) || leg.step_duration<=0 || !anim_finite(leg.max_distance) || leg.max_distance<leg.step_distance || !anim_finite(leg.contact) || !surface_contact_valid(contacts[i]) || !anim_vec3_valid(desired[i]) || !anim_finite(current.elapsed) || current.elapsed<0 || !anim_finite(current.weight) || current.weight<0 || current.weight>1 || !surface_anchor_valid(current.anchor) || !anim_vec3_valid(current.from) || !anim_vec3_valid(current.from_normal) || (current.swinging && (!current.landing.active || !surface_anchor_valid(current.landing))) {return false}
    }
    pending:=moving
    swinging:=0
    for leg,i in legs {
        current:=&states[i]
        if current.anchor.active {surface_anchor_follow(&current.anchor,supports)}
        if current.swinging {
            current.anchor.position,_=gait_step_position(current.from,current.landing.position,config.up,leg.step_height,current.elapsed/leg.step_duration)
            if !surface_anchor_follow(&current.landing,supports) {current.swinging=false;current.anchor.active=false}
        }
        if !contacts[i].valid || leg.contact<=0 {
            current.anchor.active=false
            current.swinging=false
        } else if !current.anchor.active && !current.swinging && current.weight==0 {
            if !surface_anchor_set(&current.anchor,contacts[i]) {return false}
        }
        if current.anchor.active && linalg.length(desired[i]-current.anchor.position)>leg.max_distance {
            current.anchor.active=false
            current.swinging=false
        }
        if current.anchor.active && contacts[i].valid && linalg.length(contacts[i].position-current.anchor.position)>leg.step_distance {pending=true}
        if current.swinging {
            current.elapsed=f32(min(f64(current.elapsed)+f64(dt),f64(leg.step_duration)))
            if current.elapsed>=leg.step_duration {
                current.anchor=current.landing
                current.swinging=false
            } else {swinging+=1}
        }
    }
    if pending && dt>0 {
        phase:=f64(state.phase)+f64(dt)/f64(config.cycle_duration)
        state.phase=f32(phase-cmath.floor(phase))
        if state.phase>=1 {state.phase=0}
        start:=int(state.next_leg%u32(count))
        for offset in 0..<count {
            if swinging>=config.max_swinging {break}
            i:=(start+offset)%count
            leg,current:=legs[i],&states[i]
            if current.swinging || !current.anchor.active || !contacts[i].valid || leg.contact<=0 {continue}
            if linalg.length(contacts[i].position-current.anchor.position)<=leg.step_distance {continue}
            relative:=state.phase-leg.phase
            if relative<0 {relative+=1}
            if relative>=config.swing_fraction {continue}
            if !surface_anchor_set(&current.landing,contacts[i]) {return false}
            current.from,current.from_normal=current.anchor.position,current.anchor.normal
            current.elapsed=0
            current.swinging=true
            state.next_leg=u32((i+1)%count)
            swinging+=1
        }
    }
    for leg,i in legs {
        current:=&states[i]
        goal:=math.saturate(leg.contact) if current.anchor.active || current.swinging else 0
        blend:=min(dt/config.blend_time,1) if config.blend_time>0 else 1
        current.weight+=clamp(goal-current.weight,-blend,blend)
        position,normal:=current.anchor.position,current.anchor.normal
        if current.swinging {
            progress:=math.saturate(current.elapsed/leg.step_duration)
            ok:bool
            position,ok=gait_step_position(current.from,current.landing.position,config.up,leg.step_height,progress)
            if !ok {return false}
            normal,_=anim_unit(current.from_normal+(current.landing.normal-current.from_normal)*progress)
            if normal=={} {normal=current.landing.normal}
        }
        if current.anchor.active || current.swinging {current.offset=position-desired[i]}
        if !anim_vec3_valid(current.offset) {return false}
        if !current.anchor.active && !current.swinging {position=desired[i]+current.offset}
        if current.weight==0 {position=desired[i];normal=config.up;current.offset={}}
        if !anim_vec3_valid(position) {return false}
        out[i]={position,normal,current.weight}
    }
    return true
}

gait_body_target :: proc "contextless" (body:math.Transform,targets:[]Foot_Target,up:math.Vec3,height,max_drop,max_rise,max_tilt:f32,weight:f32=1) -> (math.Transform,bool) {
    direction,up_ok:=anim_unit(up)
    if !anim_transform_valid(body) || !up_ok || !anim_finite(height) || height<0 || !anim_finite(max_drop) || max_drop<0 || !anim_finite(max_rise) || max_rise<0 || !anim_finite(max_tilt) || max_tilt<0 || !anim_finite(weight) {return body,false}
    normal:math.Vec3
    displacement,total:f64
    for target in targets {
        if !anim_vec3_valid(target.position) || !anim_vec3_valid(target.normal) || !anim_finite(target.weight) {return body,false}
        if target.weight<=0 {continue}
        n,ok:=anim_unit(target.normal)
        if !ok {return body,false}
        projection:=linalg.dot(direction,n)
        if projection<=1e-4 {continue}
        w:=math.saturate(target.weight)
        normal+=n*w
        displacement+=(f64(linalg.dot(target.position-body.position,n))/f64(projection)+f64(height))*f64(w)
        total+=f64(w)
    }
    result:=body
    if total>0 {
        normal,up_ok=anim_unit(normal)
        if !up_ok {return body,false}
        result.position+=direction*(f32(clamp(displacement/total,-f64(max_drop),f64(max_rise)))*math.saturate(weight))
        result.rotation,_=look_at(body.rotation,{0,1,0},normal,max_tilt,weight)
    }
    return result,anim_transform_valid(result)
}
