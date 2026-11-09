package mirai_anim

import "core:testing"
import math "mirai:std/math"

@(test)
transform_sequences_preserve_holds_easing_quaternion_arcs_and_reverse_time :: proc(t:^testing.T) {
    frames:=[3]Transform_Frame{TRANSFORM_FRAME_DEFAULT,TRANSFORM_FRAME_DEFAULT,TRANSFORM_FRAME_DEFAULT}
    frames[0].hold=1
    frames[1].pose.position={4,0,0};frames[1].pose.rotation=math.quat_from_euler({0,math.PI/2,0})
    frames[1].duration=2;frames[1].hold=1;frames[1].ease=.Quad_In
    frames[2].pose.position={8,0,0};frames[2].duration=1;frames[2].interpolation=.Step
    duration,ok:=sequence_duration(frames[:])
    testing.expect(t,ok && duration==5)
    at,valid:=sequence_sample(frames[:],0.5);testing.expect(t,valid && at.position.x==0)
    at,valid=sequence_sample(frames[:],2);testing.expect(t,valid && near(at.position.x,1))
    axis:=math.quat_forward(at.rotation);testing.expect(t,near(axis.x,-0.3826834))
    at,valid=sequence_sample(frames[:],3.5);testing.expect(t,valid && at.position.x==4)
    at,valid=sequence_sample(frames[:],4.9);testing.expect(t,valid && at.position.x==4)
    at,valid=sequence_sample(frames[:],5);testing.expect(t,valid && at.position.x==8)
    at,valid=sequence_sample(frames[:],8,.Ping_Pong);testing.expect(t,valid && near(at.position.x,1))
    at,valid=sequence_sample(frames[:],-3,.Loop);testing.expect(t,valid && near(at.position.x,1))
    at,valid=sequence_sample(frames[:],5,.Loop);testing.expect(t,valid && at.position.x==0)
}

@(test)
transform_sequences_reject_invalid_input_and_bound_zero_length_loops :: proc(t:^testing.T) {
    frames:=[2]Transform_Frame{TRANSFORM_FRAME_DEFAULT,TRANSFORM_FRAME_DEFAULT}
    frames[1].duration=0;frames[1].pose.position.x=4
    pose,ok:=sequence_sample(frames[:],1e20,.Loop)
    testing.expect(t,ok && pose.position.x==4)
    frames[1].hold=-1
    _,ok=sequence_sample(frames[:],0);testing.expect(t,!ok)
    frames[1].hold=0;frames[1].pose.rotation=0
    _,ok=sequence_sample(frames[:],0);testing.expect(t,!ok)
    _,ok=sequence_sample(nil,0);testing.expect(t,!ok)
    frames[1]=TRANSFORM_FRAME_DEFAULT
    _,ok=sequence_sample(frames[:],transmute(f32)u32(0x7fc00000));testing.expect(t,!ok)
}
