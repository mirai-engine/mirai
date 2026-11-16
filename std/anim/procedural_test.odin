package mirai_anim

import "base:runtime"
import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

@(test)
limb_height_ranges_bound_actual_reach_and_reject_unreachable_horizontal_targets :: proc(t:^testing.T) {
    hip,target,up:=math.Vec3{0,1,0},math.Vec3{.6,0,0},math.Vec3{0,1,0}
    low,high,ok:=limb_height_range(hip,target,up,1)
    testing.expect(t,ok && abs(low+1.8)<1e-6 && abs(high+.2)<1e-6)
    testing.expect(t,abs(linalg.length(hip+up*high-target)-1)<1e-6)
    testing.expect(t,linalg.length(hip+up*(high+.01)-target)>1)
    turn:=math.quat_axis_angle({0,0,1},.7)
    rotated_low,rotated_high,rotated_ok:=limb_height_range(math.quat_rotate(turn,hip),math.quat_rotate(turn,target),math.quat_rotate(turn,up)*3,1)
    testing.expect(t,rotated_ok && abs(rotated_low-low)<1e-5 && abs(rotated_high-high)<1e-5)
    _,_,ok=limb_height_range(hip,{1.1,0,0},up,1);testing.expect(t,!ok)
    _,_,ok=limb_height_range(hip,target,{},1);testing.expect(t,!ok)
    _,_,ok=limb_height_range(hip,target,up,0);testing.expect(t,!ok)
}

@(private="file")
procedural_hostile_number :: proc(random:^math.Rng) -> f32 {
    values:=[10]f32{0,1,-1,1e30,-1e30,1e-30,f32(0h7fc00000),f32(0h7f800000),f32(0hff800000),math.random_range(random,-10,10)}
    return values[math.rng_u32(random)%u32(len(values))]
}

@(test)
surface_anchors_follow_scaled_rotating_platforms_and_release_missing_supports :: proc(t:^testing.T) {
    platform:=math.Transform{{3,2,1},math.quat_axis_angle({0,0,1},0.3),{2,1,3}}
    local_point:=math.Vec3{1,0,1}
    normal:=math.quat_rotate(platform.rotation,{0,1,0})
    contact:=Surface_Contact{position=math.transform_point(platform,local_point),normal=normal,support=7,support_transform=platform,valid=true}
    anchor:Surface_Anchor
    testing.expect(t,surface_anchor_set(&anchor,contact))
    testing.expect(t,skel_near(anchor.local_position,local_point))
    platform.position+={2,1,0}
    platform.rotation=math.quat_axis_angle({1,0,0},0.4)
    platform.scale={1,3,2}
    supports:=[1]Surface_Support{{7,platform}}
    testing.expect(t,surface_anchor_follow(&anchor,supports[:]))
    testing.expect(t,skel_near(anchor.position,math.transform_point(platform,local_point)))
    testing.expect(t,skel_near(anchor.normal,math.quat_rotate(platform.rotation,{0,1,0})))
    testing.expect(t,!surface_anchor_follow(&anchor,nil) && !anchor.active)
    contact.support=0
    testing.expect(t,surface_anchor_set(&anchor,contact) && surface_anchor_follow(&anchor,nil))
    testing.expect(t,!surface_anchor_set(nil,contact))
    contact.support=7;contact.support_transform.scale.y=0
    testing.expect(t,!surface_anchor_set(&anchor,contact))
}

@(test)
foot_placement_uses_contact_strength_hysteresis_and_moving_supports :: proc(t:^testing.T) {
    state:Foot_Placement_State
    config:=Foot_Placement_Config{release_distance=0.5,replant_distance=0.2,blend_time=0.1}
    contact:=Surface_Contact{position={},normal={0,1,0},support=9,support_transform=math.TRANSFORM_IDENTITY,valid=true}
    supports:=[1]Surface_Support{{9,math.TRANSFORM_IDENTITY}}
    target,ok:=foot_placement_update(&state,{},contact,supports[:],1,0.1,config)
    testing.expect(t,ok && target.weight==1 && state.anchor.active)
    supports[0].transform.position.x=2
    contact.support_transform=supports[0].transform
    contact.position.x=2.1
    target,ok=foot_placement_update(&state,{2.1,0,0},contact,supports[:],1,0.05,config)
    testing.expect(t,ok && target.position.x==2 && state.anchor.active)
    snapshot:=state
    target,ok=foot_placement_update(&state,{2.6,0,0},contact,supports[:],1,0.05,config)
    testing.expect(t,ok && state.blocked && !state.anchor.active && near(target.weight,0.5))
    replay:=snapshot
    repeated,replayed:=foot_placement_update(&replay,{2.6,0,0},contact,supports[:],1,0.05,config)
    testing.expect(t,replayed && repeated==target && replay==state)
    target,ok=foot_placement_update(&state,{2.3,0,0},contact,supports[:],1,0.05,config)
    testing.expect(t,ok && state.blocked && target.weight==0)
    target,ok=foot_placement_update(&state,{2.1,0,0},contact,supports[:],1,0.1,config)
    testing.expect(t,ok && !state.blocked && state.anchor.active && near(target.position.x,2.1))
    target,ok=foot_placement_update(&state,{2.1,0,0},contact,supports[:],0,0.1,config)
    testing.expect(t,ok && !state.anchor.active && target.weight==0)
    contact.valid=false
    target,ok=foot_placement_update(&state,{2.1,1,0},contact,supports[:],1,0.1,config)
    testing.expect(t,ok && target.weight==0 && target.position==math.Vec3{2.1,1,0})
}

@(test)
foot_release_preserves_animated_swing_motion_while_blending_its_offset :: proc(t:^testing.T) {
    state:Foot_Placement_State
    config:=Foot_Placement_Config{release_distance=1,replant_distance=.2,blend_time=.1}
    contact:=Surface_Contact{position={},normal={0,1,0},support=9,support_transform=math.TRANSFORM_IDENTITY,valid=true}
    supports:=[1]Surface_Support{{9,math.TRANSFORM_IDENTITY}}
    planted,ok:=foot_placement_update(&state,{.2,0,0},contact,supports[:],1,.1,config)
    testing.expect(t,ok && state.anchor.active && planted.weight==1 && skel_near(planted.position,{}))
    supports[0].transform.position.x=2
    contact.support_transform=supports[0].transform;contact.position.x=2.2
    released,valid:=foot_placement_update(&state,{2.4,.3,0},contact,supports[:],0,.025,config)
    testing.expect(t,valid && !state.anchor.active && near(released.weight,.75))
    testing.expect(t,skel_near(released.position,{2.2,.3,0}))
    animated:=math.Vec3{2.7,.5,0}
    swing,advanced:=foot_placement_update(&state,animated,contact,supports[:],0,.025,config)
    testing.expect(t,advanced && near(swing.weight,.5) && skel_near(swing.position-released.position,{.3,.2,0}))
    blended:=animated+(swing.position-animated)*swing.weight
    testing.expect(t,skel_near(blended,{2.6,.5,0}))
    finished,complete:=foot_placement_update(&state,{3,.6,0},contact,supports[:],0,.05,config)
    testing.expect(t,complete && finished.weight==0 && skel_near(finished.position,{3,.6,0}))
}

@(test)
procedural_gait_release_follows_reference_motion_during_fade_and_replays_without_allocations :: proc(t:^testing.T) {
    config:=GAIT_CONFIG_DEFAULT
    legs:=[1]Gait_Leg{GAIT_LEG_DEFAULT}
    contacts:=[1]Surface_Contact{{position={},normal={0,1,0},valid=true}}
    desired:=[1]math.Vec3{{.2,0,0}}
    gait:Gait_State;states:[1]Gait_Leg_State;out:[1]Foot_Target
    testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&gait,states[:],.1,false,out[:]))
    testing.expect(t,states[0].anchor.active && out[0].weight==1)
    before,before_legs:=gait,states
    desired[0]={1.2,.3,0}
    testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&gait,states[:],.025,false,out[:]))
    testing.expect(t,!states[0].anchor.active && near(out[0].weight,.75) && skel_near(out[0].position,{1,.3,0}))
    replay,replay_legs:=before,before_legs;replay_out:[1]Foot_Target
    previous:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    replayed:=gait_update(config,legs[:],contacts[:],nil,desired[:],&replay,replay_legs[:],.025,false,replay_out[:])
    context=previous
    testing.expect(t,replayed && replay==gait && replay_legs==states && replay_out==out)
    released:=out[0]
    desired[0]={1.5,.5,0};contacts[0].valid=false
    testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&gait,states[:],.025,false,out[:]))
    testing.expect(t,near(out[0].weight,.5) && skel_near(out[0].position-released.position,{.3,.2,0}))
    desired[0]={1.8,.6,0}
    testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&gait,states[:],.05,false,out[:]))
    testing.expect(t,out[0].weight==0 && out[0].position==desired[0])
}

@(test)
procedural_gait_keeps_still_feet_alternates_steps_and_replays_without_allocations :: proc(t:^testing.T) {
    legs:=[4]Gait_Leg{GAIT_LEG_DEFAULT,GAIT_LEG_DEFAULT,GAIT_LEG_DEFAULT,GAIT_LEG_DEFAULT}
    contacts:[4]Surface_Contact
    desired:=[4]math.Vec3{{-1,0,-1},{1,0,-1},{-1,0,1},{1,0,1}}
    for &leg,i in legs {
        leg.phase=f32(i)*0.25
        contacts[i]={position=desired[i],normal={0,1,0},valid=true}
    }
    config:=GAIT_CONFIG_DEFAULT;config.max_swinging=2;config.blend_time=0
    state:Gait_State
    states:[4]Gait_Leg_State
    targets:[4]Foot_Target
    testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],0,false,targets[:]))
    initial:=states
    for _ in 0..<120 {testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],1.0/60,false,targets[:]))}
    testing.expect(t,state.phase==0 && states==initial)
    for &contact in contacts {contact.position.x+=0.4}
    started:[4]bool
    for _ in 0..<180 {
        before,leg_before:=state,states
        testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],1.0/60,true,targets[:]))
        replay,replay_legs:=before,leg_before
        replay_targets:[4]Foot_Target
        testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&replay,replay_legs[:],1.0/60,true,replay_targets[:]))
        testing.expect(t,state==replay && states==replay_legs && targets==replay_targets)
        swinging:=0
        for leg,i in states {
            if leg.swinging {swinging+=1;started[i]=true}
            testing.expect(t,targets[i].position.y>=0 && targets[i].position.y<=legs[i].step_height+0.0001)
        }
        testing.expect(t,swinging<=2)
    }
    for did in started {testing.expect(t,did)}
    for target,i in targets {testing.expect(t,skel_near(target.position,contacts[i].position))}
    old_context:=context
    context.allocator=runtime.nil_allocator()
    context.temp_allocator=runtime.nil_allocator()
    no_memory_ok:=true
    for _ in 0..<1000 {no_memory_ok=no_memory_ok && gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],1.0/60,false,targets[:])}
    context=old_context
    testing.expect(t,no_memory_ok)
}

@(test)
procedural_gait_releases_unsupported_feet_and_adapts_body_to_slopes :: proc(t:^testing.T) {
    config:=GAIT_CONFIG_DEFAULT
    leg:=[1]Gait_Leg{GAIT_LEG_DEFAULT}
    contact:=[1]Surface_Contact{{position={0,0,0},normal={0,1,0},valid=true}}
    desired:=[1]math.Vec3{{}}
    state:Gait_State;states:[1]Gait_Leg_State;out:[1]Foot_Target
    testing.expect(t,gait_update(config,leg[:],contact[:],nil,desired[:],&state,states[:],0.1,false,out[:]) && out[0].weight==1)
    contact[0].valid=false
    testing.expect(t,gait_update(config,leg[:],contact[:],nil,desired[:],&state,states[:],0.1,false,out[:]) && out[0].weight==0)
    contact[0].valid=true
    leg[0].contact=0
    testing.expect(t,gait_update(config,leg[:],contact[:],nil,desired[:],&state,states[:],0.1,false,out[:]) && out[0].weight==0)
    tilt:=math.quat_axis_angle({0,0,1},0.3)
    normal:=math.quat_rotate(tilt,{0,1,0})
    targets:=[2]Foot_Target{{{-1,-0.309336,0},normal,1},{{1,0.309336,0},normal,1}}
    body:=math.Transform{{0,1.5,0},1,{1,1,1}}
    adjusted,ok:=gait_body_target(body,targets[:],{0,1,0},1,0.8,0.4,0.5)
    testing.expect(t,ok && abs(adjusted.position.y-1)<0.001 && math.quat_angle(adjusted.rotation,tilt)<0.001)
    adjusted,ok=gait_body_target(body,targets[:],{0,1,0},1,0.2,0.4,0.1)
    testing.expect(t,ok && near(adjusted.position.y,1.3) && abs(math.quat_angle(1,adjusted.rotation)-0.1)<0.001)
    start,first_ok:=gait_step_position({},{1,0,0},{0,1,0},0.2,0)
    middle,middle_ok:=gait_step_position({},{1,0,0},{0,1,0},0.2,0.5)
    end,last_ok:=gait_step_position({},{1,0,0},{0,1,0},0.2,1)
    testing.expect(t,first_ok && middle_ok && last_ok && start==math.Vec3{} && skel_near(middle,{0.5,0.2,0}) && end==math.Vec3{1,0,0})
}

@(test)
procedural_gait_rejects_invalid_batches_and_zero_configuration :: proc(t:^testing.T) {
    state:Gait_State;states:[1]Gait_Leg_State;out:[1]Foot_Target
    legs:=[1]Gait_Leg{GAIT_LEG_DEFAULT}
    contacts:=[1]Surface_Contact{{normal={0,1,0},valid=true}}
    desired:[1]math.Vec3
    testing.expect(t,!gait_update({},nil,nil,nil,nil,&state,nil,0,false,nil))
    testing.expect(t,!gait_update(GAIT_CONFIG_DEFAULT,legs[:],contacts[:],nil,desired[:],&state,nil,0,false,out[:]))
    legs[0].step_duration=0
    testing.expect(t,!gait_update(GAIT_CONFIG_DEFAULT,legs[:],contacts[:],nil,desired[:],&state,states[:],0,false,out[:]))
    legs[0]=GAIT_LEG_DEFAULT
    contacts[0].normal={}
    testing.expect(t,!gait_update(GAIT_CONFIG_DEFAULT,legs[:],contacts[:],nil,desired[:],&state,states[:],0,false,out[:]))
    contacts[0].valid=false
    testing.expect(t,gait_update(GAIT_CONFIG_DEFAULT,legs[:],contacts[:],nil,desired[:],&state,states[:],0,false,out[:]))
    testing.expect(t,!gait_update(GAIT_CONFIG_DEFAULT,legs[:],contacts[:],nil,desired[:],&state,states[:],f32(0h7fc00000),false,out[:]))
}

@(test)
procedural_gait_follows_landing_platform_during_a_step :: proc(t:^testing.T) {
    config:=GAIT_CONFIG_DEFAULT;config.blend_time=0
    legs:=[1]Gait_Leg{GAIT_LEG_DEFAULT}
    legs[0].step_duration=0.4
    contacts:=[1]Surface_Contact{{normal={0,1,0},support=7,support_transform=math.TRANSFORM_IDENTITY,valid=true}}
    supports:=[1]Surface_Support{{7,math.TRANSFORM_IDENTITY}}
    desired:[1]math.Vec3
    state:Gait_State;states:[1]Gait_Leg_State;out:[1]Foot_Target
    testing.expect(t,gait_update(config,legs[:],contacts[:],supports[:],desired[:],&state,states[:],0,false,out[:]))
    supports[0].transform.position.x=2
    contacts[0].position.x=2
    contacts[0].support_transform=supports[0].transform
    desired[0].x=2
    testing.expect(t,gait_update(config,legs[:],contacts[:],supports[:],desired[:],&state,states[:],0.1,false,out[:]))
    testing.expect(t,out[0].position.x==2 && state.phase==0 && !states[0].swinging)
    contacts[0].position.x=2.4
    testing.expect(t,gait_update(config,legs[:],contacts[:],supports[:],desired[:],&state,states[:],0.1,true,out[:]))
    testing.expect(t,states[0].swinging)
    supports[0].transform.position.x=2.2
    contacts[0].position.x=2.6
    contacts[0].support_transform=supports[0].transform
    desired[0].x=2.2
    testing.expect(t,gait_update(config,legs[:],contacts[:],supports[:],desired[:],&state,states[:],0.2,false,out[:]))
    testing.expect(t,states[0].swinging && near(out[0].position.x,2.3) && near(out[0].position.y,legs[0].step_height))
    testing.expect(t,gait_update(config,legs[:],contacts[:],supports[:],desired[:],&state,states[:],0.2,false,out[:]))
    testing.expect(t,!states[0].swinging && near(out[0].position.x,2.6) && out[0].position.y==0)
    contacts[0].valid=false
    testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],0.1,false,out[:]))
    testing.expect(t,out[0].weight==0 && !states[0].anchor.active)
}

@(test)
procedural_inputs_reject_nonfinite_numbers_and_preserve_chain_lengths :: proc(t:^testing.T) {
    random:=math.rng_make(389)
    rounds:=#config(ANIM_PROCEDURAL_HOSTILE_ROUNDS,400)
    for _ in 0..<rounds {
        legs:=[1]Gait_Leg{GAIT_LEG_DEFAULT}
        contacts:=[1]Surface_Contact{{normal={0,1,0},valid=true}}
        desired:[1]math.Vec3;out:[1]Foot_Target;states:[1]Gait_Leg_State
        config:=GAIT_CONFIG_DEFAULT
        state:Gait_State
        dt:f32=0.1
        switch int(math.rng_u32(&random)%8) {
        case 0: config.up={procedural_hostile_number(&random),procedural_hostile_number(&random),procedural_hostile_number(&random)}
        case 1: contacts[0].position={procedural_hostile_number(&random),procedural_hostile_number(&random),procedural_hostile_number(&random)}
        case 2: legs[0].step_duration=procedural_hostile_number(&random)
        case 3: legs[0].contact=procedural_hostile_number(&random)
        case 4: dt=procedural_hostile_number(&random)
        case 5: states[0].weight=procedural_hostile_number(&random)
        case 6: state.phase=procedural_hostile_number(&random)
        case 7: config.cycle_duration=procedural_hostile_number(&random)
        }
        if gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],dt,true,out[:]) {
            testing.expect(t,anim_vec3_valid(out[0].position) && anim_vec3_valid(out[0].normal) && anim_finite(out[0].weight))
        }
        foot:Foot_Placement_State
        target,foot_ok:=foot_placement_update(&foot,desired[0],contacts[0],nil,legs[0].contact,dt)
        if foot_ok {testing.expect(t,anim_vec3_valid(target.position) && anim_vec3_valid(target.normal) && anim_finite(target.weight))}
        _,_=gait_step_position(desired[0],contacts[0].position,config.up,procedural_hostile_number(&random),procedural_hostile_number(&random))
        low,high,valid:=limb_height_range(desired[0],contacts[0].position,config.up,procedural_hostile_number(&random))
        if valid {testing.expect(t,anim_finite(low) && anim_finite(high) && low<=high)}
        points:=[4]math.Vec3{{},{1,0,0},{2,0,0},{3,0,0}}
        lengths:=[3]f32{1,1,1};solved:[4]math.Vec3
        settings:=CHAIN_IK_DEFAULT
        settings.target={procedural_hostile_number(&random),procedural_hostile_number(&random),procedural_hostile_number(&random)}
        result,ok:=chain_ik(points[:],lengths[:],nil,settings,solved[:])
        if ok {
            testing.expect(t,anim_finite(result.error) && solved[0]==points[0])
            for i in 1..<4 {testing.expect(t,abs(linalg.length(solved[i]-solved[i-1])-1)<0.0001)}
        }
    }
}
