package mirai_anim

import "base:runtime"
import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

@(test)
inertial_transitions_preserve_velocity_curves_and_interrupted_pose_without_allocations :: proc(t:^testing.T) {
    // The bone heads toward its target at 1 m/s: the transition keeps that velocity.
    previous:=[1]math.Transform{math.TRANSFORM_IDENTITY};previous[0].position.x=.9
    current:=previous;current[0].position.x=1;current[0].rotation=math.quat_axis_angle({0,1,0},.2)
    target:=[1]math.Transform{math.TRANSFORM_IDENTITY};target[0].position.x=2
    old_curves:=[2]f32{2.9,7};new_curves:=[2]f32{3,8};target_curves:=[2]f32{1,2}
    bones:[1]Inertial_Bone;curves:[2]Inertial_Curve;state:Inertial_State
    out:[1]math.Transform;values:[2]f32
    filtered:=[2]bool{false,true}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    ok:=inertial_capture(&state,bones[:],curves[:],{previous=previous[:],current=current[:],target=target[:],previous_curves=old_curves[:],current_curves=new_curves[:],target_curves=target_curves[:],dt=.1,duration=1})
    ok &&=inertial_pose_apply(state,bones[:],target[:],out[:]) && inertial_curves_apply(state,curves[:],target_curves[:],values[:],filtered[:])
    first,first_curve:=out[0],values
    ok &&=inertial_advance(&state,.001) && inertial_pose_apply(state,bones[:],target[:],out[:])
    moving:=out[0]
    target[0].position.x=3
    current[0]=moving;previous[0]=first
    ok &&=inertial_capture(&state,bones[:],curves[:],{previous=previous[:],current=current[:],target=target[:],previous_curves=old_curves[:],current_curves=new_curves[:],target_curves=target_curves[:],dt=.001,duration=.2})
    ok &&=inertial_pose_apply(state,bones[:],target[:],out[:])
    interrupted:=out[0]
    ok &&=inertial_advance(&state,1) && inertial_pose_apply(state,bones[:],target[:],out[:]) && inertial_curves_apply(state,curves[:],target_curves[:],values[:])
    context=saved
    testing.expect(t,ok)
    testing.expect(t,abs(first.position.x-1)<1e-6 && abs(first_curve[0]-3)<1e-6 && first_curve[1]==2)
    testing.expect(t,moving.position.x>first.position.x && abs((moving.position.x-first.position.x)/.001-1)<.01)
    testing.expect(t,abs(interrupted.position.x-moving.position.x)<1e-6 && math.quat_angle(interrupted.rotation,moving.rotation)<1e-5)
    testing.expect_value(t,out[0],target[0]);testing.expect_value(t,values,target_curves)
    testing.expect(t,!state.active)
}

@(test)
inertial_offsets_never_overshoot_and_drop_a_velocity_that_heads_away_from_the_target :: proc(t:^testing.T) {
    // One metre from the target: one bone moves away from it at 5 m/s, another closes at 40 m/s.
    Case :: struct {previous,closing,end:f32}
    cases:=[2]Case{{previous=.9,closing=0,end=.5},{previous=1.8,closing=-40,end=5.0/40}}
    for c in cases {
        previous,current,target:=[1]math.Transform{math.TRANSFORM_IDENTITY},[1]math.Transform{math.TRANSFORM_IDENTITY},[1]math.Transform{math.TRANSFORM_IDENTITY}
        previous[0].position.x,current[0].position.x=c.previous,1
        state:Inertial_State;bones:[1]Inertial_Bone;out:[1]math.Transform
        testing.expect(t,inertial_capture(&state,bones[:],nil,{previous=previous[:],current=current[:],target=target[:],dt=.02,duration=.5}))
        testing.expectf(t,abs(bones[0].speed.x-c.closing)<1e-3 && abs(bones[0].end.x-c.end)<1e-5,"closes at %v by %v s, not %v",c.closing,c.end,bones[0])
        last:=f32(1)
        for step in 0..=200 {
            testing.expect(t,inertial_pose_apply(state,bones[:],target[:],out[:]))
            x:=out[0].position.x
            testing.expectf(t,x>=-1e-6 && x<=last+1e-6,"the offset only closes toward the target: %.6f after %.6f at step %d",x,last,step)
            last=x
            testing.expect(t,inertial_advance(&state,.0025))
        }
        testing.expect(t,last==0)
    }
}

@(test)
transitions_that_interrupt_each_other_give_up_the_time_the_one_before_left_undone :: proc(t:^testing.T) {
    pose:=[1]math.Transform{math.TRANSFORM_IDENTITY};moved:=pose;moved[0].position.x=1
    bones:[1]Inertial_Bone;state:Inertial_State
    input:=Inertial_Input{previous=moved[:],current=moved[:],target=pose[:],dt=.01,duration=.2}
    durations:[4]f32
    for i in 0..<4 {
        testing.expect(t,inertial_capture(&state,bones[:],nil,input))
        durations[i]=state.duration
        testing.expect(t,inertial_advance(&state,.05 if i<2 else 1))
    }
    // The second interrupts the first with .15 s left; the third interrupts it too and gives
    // those up.
    testing.expectf(t,durations[0]==.2 && durations[1]==.2 && abs(durations[2]-.05)<1e-6 && durations[3]==.2,"durations %v",durations)
}

@(test)
inertial_zero_duration_zero_dt_masks_and_short_buffers_have_defined_results :: proc(t:^testing.T) {
    current:=[1]math.Transform{math.TRANSFORM_IDENTITY};current[0].position.x=4
    target:=[1]math.Transform{math.TRANSFORM_IDENTITY};bones:[1]Inertial_Bone;state:Inertial_State;out:[1]math.Transform
    input:=Inertial_Input{previous=current[:],current=current[:],target=target[:],duration=1}
    testing.expect(t,inertial_capture(&state,bones[:],nil,input) && bones[0].speed=={})
    mask:=[1]f32{0};testing.expect(t,inertial_pose_apply(state,bones[:],target[:],out[:],mask[:]) && out==target)
    input.duration=0;testing.expect(t,inertial_capture(&state,bones[:],nil,input) && inertial_pose_apply(state,bones[:],target[:],out[:]) && out==target)
    testing.expect(t,!inertial_capture(nil,bones[:],nil,input) && !inertial_capture(&state,nil,nil,input) && !inertial_pose_apply(state,bones[:],target[:],nil))
    input.dt= -1;testing.expect(t,!inertial_capture(&state,bones[:],nil,input));testing.expect(t,!inertial_advance(&state,-1))
}

@(test)
hostile_inertial_inputs_return_without_nonfinite_successes :: proc(t:^testing.T) {
    values:=[10]f32{0,1,-1,1e30,-1e30,1e-30,f32(0h7fc00000),f32(0h7f800000),f32(0hff800000),.25}
    for iteration in 0..<#config(ANIM_INERTIAL_HOSTILE_ROUNDS,400) {
        previous:=[1]math.Transform{math.TRANSFORM_IDENTITY};current:=previous;target:=previous
        value:=values[iteration%len(values)]
        current[0].position.x=value
        input:=Inertial_Input{previous=previous[:],current=current[:],target=target[:],dt=values[(iteration/3)%len(values)],duration=values[(iteration/7)%len(values)]}
        state:Inertial_State;bones:[1]Inertial_Bone;out:[1]math.Transform
        if inertial_capture(&state,bones[:],nil,input) && inertial_advance(&state,values[(iteration/11)%len(values)]) && inertial_pose_apply(state,bones[:],target[:],out[:]) {testing.expect(t,anim_transform_valid(out[0]))}
    }
}

@(test)
inertial_rotation_closes_against_noncommuting_moving_targets_and_quaternion_hemispheres :: proc(t:^testing.T) {
    DT :: f32(.0005)
    // Half a radian of residual about X from a target that turns about other axes, closing at .3.
    offset:=math.Vec3{.25,0,0};closing:=f32(.3)
    current,target:=[1]math.Transform{math.TRANSFORM_IDENTITY},[1]math.Transform{math.TRANSFORM_IDENTITY}
    target[0].rotation=math.quat_axis_angle({0,1,0},.7)
    current[0].rotation=target[0].rotation*quat_exp(offset)
    target_velocity:=math.Vec3{-.1,.2,.3}
    previous,previous_target:=current,target
    previous_target[0].rotation=target[0].rotation*quat_exp(-target_velocity*DT)
    previous[0].rotation=previous_target[0].rotation*quat_exp(offset*(1+closing*DT/.25))
    state:Inertial_State;bones:[1]Inertial_Bone;out:[1]math.Transform
    testing.expect(t,inertial_capture(&state,bones[:],nil,{previous=previous[:],current=current[:],target_previous=previous_target[:],target=target[:],dt=DT,duration=1}))
    testing.expectf(t,abs(bones[0].speed.y+closing)<.002,"the residual closes at %.3f, not %v",closing,bones[0].speed.y)
    target[0].rotation*=quat_exp(target_velocity*DT)
    testing.expect(t,inertial_advance(&state,DT) && inertial_pose_apply(state,bones[:],target[:],out[:]))
    left:=linalg.length(inertial_rotation_delta(target[0].rotation,out[0].rotation))
    testing.expectf(t,abs(left-(.25-closing*DT))<2e-5,"the residual against the moving target is %.6f",left)
    current[0].rotation=math.quat_axis_angle({0,1,0},math.PI-.0002);previous[0].rotation=math.quat_axis_angle({0,1,0},math.PI+.0002)
    target[0],previous_target[0]=math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY
    state={}
    testing.expect(t,inertial_capture(&state,bones[:],nil,{previous=previous[:],current=current[:],target_previous=previous_target[:],target=target[:],dt=DT,duration=1}))
    testing.expect(t,abs(bones[0].speed.y)<1)
    previous[0].rotation=-previous[0].rotation
    repeated:[1]Inertial_Bone
    state={}
    testing.expect(t,inertial_capture(&state,repeated[:],nil,{previous=previous[:],current=current[:],target_previous=previous_target[:],target=target[:],dt=DT,duration=1}) && repeated==bones)
}
