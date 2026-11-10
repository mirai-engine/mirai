package mirai_net

import "core:math"
import "core:mem"
import "core:testing"

@(test)
smoothing_keeps_the_picture_still_through_a_correction_and_fades_it_out :: proc(t:^testing.T) {
    s:Smoothing
    smoothing_init(&s,0.1,4)
    turned:quaternion128=quaternion(w=math.cos(f32(0.4)),x=0,y=math.sin(f32(0.4)),z=0)
    straight:quaternion128=quaternion(w=1,x=0,y=0,z=0)
    smoothing_correct(&s,{1,0,0},{2,0,1},turned,straight)
    position,rotation:=smoothing_apply(&s,{2,0,1},straight)
    testing.expect(t,abs(position.x-1)<1e-5 && abs(position.z)<1e-5)
    testing.expect(t,abs(rotation.y-turned.y)<1e-5 && abs(rotation.w-turned.w)<1e-5)
    smoothing_update(&s,0.1)
    position,_=smoothing_apply(&s,{2,0,1},straight)
    testing.expect(t,abs(position.x-1.5)<1e-4 && abs(position.z-0.5)<1e-4)
    for _ in 0..<100 {smoothing_update(&s,0.05)}
    position,rotation=smoothing_apply(&s,{2,0,1},straight)
    testing.expect(t,abs(position.x-2)<1e-4 && abs(rotation.w-1)<1e-4 && abs(rotation.y)<1e-3)
    // Too far to slide: show it where it is.
    smoothing_correct(&s,{0,0,0},{10,0,0},straight,straight)
    testing.expect_value(t,s.offset,[3]f32{0,0,0})
}

@(test)
interpolation_returns_the_two_snapshots_around_a_tick :: proc(t:^testing.T) {
    i:Interpolation
    testing.expect_value(t,interpolation_init(&i,{state_size=0,capacity=2}),Error.Invalid)
    testing.expect_value(t,interpolation_init(&i,{state_size=size_of(Test_Transform),capacity=2,depth=4}),Error.None)
    defer interpolation_destroy(&i)
    a,_:=interpolation_add(&i)
    b,_:=interpolation_add(&i)
    _,third:=interpolation_add(&i)
    testing.expect(t,!third && a!=b)
    snapshot :: proc(x:f32,angle:f32) -> Test_Transform {
        return {position={x,0,0},rotation=quaternion(w=math.cos(angle*0.5),x=0,y=math.sin(angle*0.5),z=0)}
    }
    _,_,_,empty:=interpolation_sample(&i,a,5)
    testing.expect_value(t,empty,Interpolation_Status.Empty)
    for tick,n in ([?]u32{10,12,16}) {
        state:=snapshot(f32(tick),f32(n))
        testing.expect(t,interpolation_push(&i,a,tick,mem.ptr_to_bytes(&state)))
    }
    stale:=snapshot(0,0)
    testing.expect(t,!interpolation_push(&i,a,12,mem.ptr_to_bytes(&stale)))
    testing.expect(t,!interpolation_push(&i,a,17,mem.ptr_to_bytes(&stale)[:8]))
    from,to,alpha,status:=interpolation_sample(&i,a,13)
    testing.expect_value(t,status,Interpolation_Status.Between)
    testing.expect(t,abs(alpha-0.25)<1e-6)
    testing.expect(t,(^Test_Transform)(raw_data(from)).position.x==12 && (^Test_Transform)(raw_data(to)).position.x==16)
    _,_,_,status=interpolation_sample(&i,a,11)
    testing.expect_value(t,status,Interpolation_Status.Between)
    from,_,_,status=interpolation_sample(&i,a,3)
    testing.expect(t,status==.Before && (^Test_Transform)(raw_data(from)).position.x==10)
    from,_,alpha,status=interpolation_sample(&i,a,16.5)
    testing.expect(t,status==.After && (^Test_Transform)(raw_data(from)).position.x==16 && alpha==0.5)
    // Gaps of two and four ticks: the longest counts at once.
    testing.expect_value(t,interpolation_spacing(&i,a),f32(4))
    newest,newest_tick,_:=interpolation_newest(&i,a)
    testing.expect(t,newest_tick==16 && (^Test_Transform)(raw_data(newest)).position.x==16)
    // Only the last four are kept.
    for tick in u32(17)..=20 {
        state:=snapshot(f32(tick),0)
        interpolation_push(&i,a,tick,mem.ptr_to_bytes(&state))
    }
    from,_,_,status=interpolation_sample(&i,a,12)
    testing.expect(t,status==.Before && (^Test_Transform)(raw_data(from)).position.x==17)
    // Gaps of one tick bring it down an eighth of the way each.
    testing.expect(t,interpolation_spacing(&i,a)<4 && interpolation_spacing(&i,a)>2)
    _,_,_,status=interpolation_sample(&i,b,12)
    testing.expect_value(t,status,Interpolation_Status.Empty)
    interpolation_clear(&i,a)
    _,_,_,status=interpolation_sample(&i,a,18)
    testing.expect_value(t,status,Interpolation_Status.Empty)
    interpolation_remove(&i,a)
    again,ok:=interpolation_add(&i)
    testing.expect(t,ok && again==a)
}
