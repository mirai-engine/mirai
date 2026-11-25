package mirai_anim

import "base:runtime"
import cmath "core:math"
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

// A transition lasts what it asks, also when it interrupts one that had interrupted another: a
// target that turns 20 degrees further every 3 ticks, each at .4 s, never moves the pose by more
// than SWITCH_STEP_MOST in a tick, and a single transition follows its curve to the target in .4 s.
@(test)
a_transition_lasts_what_it_asks_also_when_it_interrupts_another :: proc(t:^testing.T) {
    DT :: f32(1.0/60)
    SWITCH_STEP_MOST :: f32(8*cmath.RAD_PER_DEG) // the target itself turns about 6.7 degrees a tick
    angle :: proc(a,b:math.Quat) -> f32 {return 2*cmath.acos(min(abs(real(conj(a)*b)),1))}
    turned:=math.quat_axis_angle({0,1,0},cmath.PI/2)
    target,shown,before:[1]math.Transform
    target[0],shown[0]=math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY
    bones:[1]Inertial_Bone;state:Inertial_State
    worst:f32
    for tick in 0..<90 {
        if tick%3==0 {
            target[0].rotation=math.quat_axis_angle({0,1,0},f32(tick/3+1)*20*cmath.RAD_PER_DEG)
            ok:=inertial_capture(&state,bones[:],nil,{previous=before[:] if tick>0 else shown[:],current=shown[:],target=target[:],dt=DT,duration=.4})
            testing.expectf(t,ok && state.duration==.4,"tick %d: the transition lasts %v",tick,state.duration)
        }
        before=shown
        testing.expect(t,inertial_pose_apply(state,bones[:],target[:],shown[:]) && inertial_advance(&state,DT))
        worst=max(worst,angle(before[0].rotation,shown[0].rotation))
    }
    testing.expectf(t,worst<=SWITCH_STEP_MOST,"a tick moves the pose by %v degrees",worst*cmath.DEG_PER_RAD)
    // A single transition from rest: at .2 s it keeps inertial_remaining of its offset, at .4 s none.
    target[0].rotation,shown[0].rotation,state=1,turned,{}
    testing.expect(t,inertial_capture(&state,bones[:],nil,{previous=shown[:],current=shown[:],target=target[:],dt=DT,duration=.4}) && state.duration==.4)
    out:[1]math.Transform
    testing.expect(t,inertial_advance(&state,.2) && inertial_pose_apply(state,bones[:],target[:],out[:]))
    testing.expectf(t,abs(angle(out[0].rotation,1)-cmath.PI/2*inertial_remaining(.2,.4))<1e-4,"at .2 s: %v",out[0].rotation)
    testing.expect(t,inertial_advance(&state,.2) && inertial_pose_apply(state,bones[:],target[:],out[:]) && out[0].rotation==1 && !state.active)
}

// Each bone closes over its own time, and one given a negative time keeps what the transition it
// interrupts had left.
@(test)
each_bone_closes_over_its_own_time_or_the_time_left_of_the_one_it_interrupts :: proc(t:^testing.T) {
    pose:=[2]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY};moved:=pose;moved[0].position.x=1;moved[1].position.x=1
    bones:[2]Inertial_Bone;state:Inertial_State;out:[2]math.Transform
    durations:=[2]f32{.1,.3}
    testing.expect(t,inertial_capture(&state,bones[:],nil,{previous=moved[:],current=moved[:],target=pose[:],durations=durations[:],duration=.1}) && state.duration==.3)
    testing.expect(t,inertial_advance(&state,.15) && inertial_pose_apply(state,bones[:],pose[:],out[:]))
    testing.expectf(t,out[0].position.x==0 && out[1].position.x>.1,"the first bone ends at .1 s and the second goes on: %v",out)
    durations={-1,.2}
    testing.expect(t,inertial_capture(&state,bones[:],nil,{previous=moved[:],current=moved[:],target=pose[:],durations=durations[:],duration=.2}))
    testing.expectf(t,abs(bones[0].end.x-.15)<1e-6 && bones[1].end.x==.2 && state.duration==.2,"the first keeps the .15 s left, the second takes .2 s: %v %v",bones,state)
    durations={.1,f32(0h7fc00000)}
    testing.expect(t,!inertial_capture(&state,bones[:],nil,{previous=moved[:],current=moved[:],target=pose[:],durations=durations[:],duration=.2}) && !inertial_capture(&state,bones[:],nil,{previous=moved[:],current=moved[:],target=pose[:],durations=durations[:1],duration=.2}))
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
