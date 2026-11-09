package camera

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

@(private="file")
near :: proc(a,b:f32,eps:f32=1e-4) -> bool {return abs(a-b)<=eps}
@(private="file")
near_vec :: proc(a,b:$V/[$N]f32,eps:f32=1e-4) -> bool {
    for i in 0..<N {if abs(a[i]-b[i])>eps {return false}}
    return true
}

@(test)
follow_closes_half_the_distance_in_its_half_life_without_overshooting :: proc(t:^testing.T) {
    f:Follow
    target:=math.Vec3{10,0,0}
    for _ in 0..<60 {follow_update(&f,target,1,1.0/60)}
    testing.expect(t,f.position.x>5 && f.position.x<7.5)
    previous:=f.position.x
    for _ in 0..<600 {
        follow_update(&f,target,0.5,1.0/60)
        testing.expect(t,f.position.x<=10+1e-4 && f.position.x>=previous-1e-4)
        previous=f.position.x
    }
    testing.expect(t,near(f.position.x,10,1e-3))
}

@(test)
follow_gives_the_same_result_at_any_frame_rate :: proc(t:^testing.T) {
    a,b:Follow
    target:=math.Vec3{3,-2,8}
    for _ in 0..<30 {follow_update(&a,target,0.4,1.0/60)}
    for _ in 0..<5 {follow_update(&b,target,0.4,0.1)}
    testing.expect(t,near_vec(a.position,b.position,1e-3))
}

@(test)
follow_snaps_and_with_no_half_life_follows_exactly :: proc(t:^testing.T) {
    f:Follow
    follow_snap(&f,{1,2,3})
    testing.expect(t,f.position==math.Vec3{1,2,3} && f.velocity==math.Vec3{})
    testing.expect(t,follow_update(&f,{5,5,5},0,0.016)==math.Vec3{5,5,5})
    testing.expect(t,follow_update(&f,{5,5,5},1,0)==math.Vec3{5,5,5})
}

@(test)
orbit_places_the_camera_around_its_target :: proc(t:^testing.T) {
    o:=orbit_make({1,2,3},5)
    testing.expect(t,near_vec(orbit_position(o),math.Vec3{1,2,8}))
    orbit_rotate(&o,math.PI/2,0)
    testing.expect(t,near_vec(orbit_position(o),math.Vec3{6,2,3}))
    orbit_rotate(&o,0,math.PI/4)
    direction:=orbit_direction(o)
    testing.expect(t,near(linalg.length(direction),1) && direction.y>0.7 && direction.x>0.5)
    testing.expect(t,near_vec(orbit_position(o),o.target+direction*5))
}

@(test)
orbit_rotation_faces_the_target_with_up_kept :: proc(t:^testing.T) {
    o:=orbit_make({0,1,0},4,0.7,0.3)
    q:=orbit_rotation(o)
    forward:=math.quat_forward(q)
    testing.expect(t,near_vec(forward,-orbit_direction(o),1e-3))
    up:=math.quat_rotate(q,{0,1,0})
    testing.expect(t,up.y>0)
    transform:=orbit_transform(o)
    testing.expect(t,near_vec(transform.position,orbit_position(o)) && transform.scale==math.Vec3{1,1,1})
}

@(test)
orbit_clamps_pitch_distance_and_wraps_yaw :: proc(t:^testing.T) {
    o:=orbit_make({},5)
    orbit_rotate(&o,0,10)
    testing.expect(t,near(o.pitch,o.max_pitch))
    orbit_rotate(&o,0,-100)
    testing.expect(t,near(o.pitch,o.min_pitch))
    orbit_rotate(&o,7,0)
    testing.expect(t,o.yaw>=-math.PI && o.yaw<math.PI && near(o.yaw,7-math.TAU,1e-4))
    orbit_zoom(&o,100)
    testing.expect(t,near(o.distance,o.min_distance))
    orbit_zoom(&o,-1e9)
    testing.expect(t,near(o.distance,o.max_distance))
    far:=orbit_make({},1e9)
    testing.expect(t,near(far.distance,far.max_distance))
}

Wall :: struct {distance:f32}

wall_query :: proc(user:rawptr,from,to:math.Vec3,radius:f32) -> (fraction:f32,hit:bool) {
    wall:=cast(^Wall)user
    length:=linalg.length(to-from)
    if wall.distance>=length {return 1,false}
    return wall.distance/length,true
}

@(test)
spring_arm_comes_in_at_once_where_the_camera_meets_a_wall_and_goes_out_after_holding :: proc(t:^testing.T) {
    arm:=spring_arm_make(6)
    pivot,direction:=math.Vec3{0,2,0},math.Vec3{0,0,1}
    wall:=Wall{distance=100}
    free:=spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.016)
    testing.expect(t,near_vec(free,math.Vec3{0,2,6}))
    // The target backs into a wall behind the camera: it comes in with the wall, frame by frame.
    for distance:=f32(5.9);distance>2;distance-=0.1 {
        wall.distance=distance
        at:=spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.016)
        testing.expect(t,near(at.z,distance-arm.margin))
    }
    blocked:=arm.current
    wall.distance=100
    held:=spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.1)
    testing.expect(t,near(held.z,blocked),"it waits before going back out")
    after:=held
    for _ in 0..<3 {after=spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.1)}
    testing.expect(t,after.z>blocked && after.z<6)
    for _ in 0..<200 {after=spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.1)}
    testing.expect(t,near(after.z,6,1e-3))
}

@(test)
spring_arm_lets_a_passing_obstruction_be_and_then_comes_in_smoothly :: proc(t:^testing.T) {
    arm:=spring_arm_make(6)
    pivot,direction:=math.Vec3{0,2,0},math.Vec3{0,0,1}
    wall:=Wall{distance=100}
    _=spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.016)
    // A post between the target and the camera for less than the grace: the camera stays.
    wall.distance=2
    for _ in 0..<5 {testing.expect(t,near(spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.016).z,6))}
    wall.distance=100
    for _ in 0..<5 {testing.expect(t,near(spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.016).z,6))}
    // One that stays: after the grace it comes in, without a jump, until it sits before it.
    wall.distance=2
    previous:=f32(6)
    for _ in 0..<120 {
        at:=spring_arm_update(&arm,pivot,direction,wall_query,&wall,0.016)
        testing.expect(t,at.z<=previous+1e-5 && previous-at.z<1)
        previous=at.z
    }
    testing.expect(t,near(previous,2-arm.margin,1e-3))
}

@(test)
spring_arm_keeps_its_minimum_where_there_is_room_and_stops_before_what_it_hits :: proc(t:^testing.T) {
    // Nearer than the minimum, the hit wins: raising the camera to the minimum
    // there would put it inside what it found.
    Case :: struct {distance,expected:f32}
    for c in ([?]Case{{0.01,0},{0.4,0.35},{0.52,0.5}}) {
        arm:=spring_arm_make(5)
        arm.min_length=0.5
        wall:=Wall{distance=c.distance}
        at:=spring_arm_update(&arm,{},{1,0,0},wall_query,&wall,0.016)
        testing.expectf(t,near(at.x,c.expected),"wall at %v: camera at %v, not %v",c.distance,at.x,c.expected)
        testing.expectf(t,at.x<=c.distance,"wall at %v: the camera stays this side of it (%v)",c.distance,at.x)
    }
    free:=spring_arm_make(5)
    nothing:=spring_arm_update(&free,{},{1,0,0},nil,nil,100)
    testing.expect(t,near_vec(nothing,math.Vec3{5,0,0},1e-3))
    short:=spring_arm_make(0.3)
    wall:=Wall{distance=0.01}
    stays:=spring_arm_update(&short,{},{0,1,0},wall_query,&wall,0.016)
    testing.expect(t,stays.y<=0.01+1e-5 && stays.y>=0)
}

@(test)
shake_is_still_without_trauma_and_settles_after_a_hit :: proc(t:^testing.T) {
    s:=shake_make(5)
    offset,angles:=shake_update(&s,0.016)
    testing.expect(t,offset==math.Vec3{} && angles==math.Vec3{})
    shake_add(&s,0.8)
    shake_add(&s,0.8)
    testing.expect_value(t,s.trauma,f32(1))
    moved:=false
    for _ in 0..<30 {
        offset,angles=shake_update(&s,1.0/60)
        if linalg.length(offset)>1e-4 {moved=true}
        testing.expect(t,abs(offset.x)<=s.max_offset.x && abs(offset.y)<=s.max_offset.y && abs(offset.z)<=s.max_offset.z)
        testing.expect(t,abs(angles.z)<=s.max_angle.z)
    }
    testing.expect(t,moved)
    for _ in 0..<120 {offset,angles=shake_update(&s,1.0/60)}
    testing.expect(t,s.trauma==0 && offset==math.Vec3{} && angles==math.Vec3{})
}

@(test)
shake_intensity_grows_faster_than_trauma_and_is_repeatable :: proc(t:^testing.T) {
    s:=shake_make(1)
    shake_add(&s,0.5)
    testing.expect(t,near(shake_intensity(s),0.25))
    s.power=3
    testing.expect(t,near(shake_intensity(s),0.125))
    run :: proc(seed:u32) -> math.Vec3 {
        s:=shake_make(seed)
        shake_add(&s,0.9)
        total:math.Vec3
        for _ in 0..<20 {
            offset,_:=shake_update(&s,0.02)
            total+=offset
        }
        return total
    }
    testing.expect(t,run(3)==run(3) && run(3)!=run(4))
}

@(test)
look_at_smooth_turns_toward_the_target_at_any_frame_rate :: proc(t:^testing.T) {
    from,target:=math.Vec3{0,0,0},math.Vec3{10,0,0}
    wanted:=math.quat_look({1,0,0},{0,1,0})
    a,b:=math.QUAT_IDENTITY,math.QUAT_IDENTITY
    for _ in 0..<30 {a=look_at_smooth(a,from,target,{0,1,0},5,1.0/60)}
    for _ in 0..<5 {b=look_at_smooth(b,from,target,{0,1,0},5,0.1)}
    testing.expect(t,math.quat_angle(a,b)<2e-3)
    testing.expect(t,math.quat_angle(a,wanted)<math.quat_angle(math.QUAT_IDENTITY,wanted))
    for _ in 0..<200 {a=look_at_smooth(a,from,target,{0,1,0},5,0.1)}
    testing.expect(t,near(math.quat_angle(a,wanted),0,1e-3))
    still:=look_at_smooth(math.QUAT_IDENTITY,from,target,{0,1,0},0,1)
    testing.expect(t,math.quat_angle(still,math.QUAT_IDENTITY)<1e-5)
    same:=look_at_smooth(a,from,from,{0,1,0},5,1) // no direction to face
    testing.expect(t,same==a)
}

// Along up the pivot closes with up_half_life and across with half_life; up_half_life 0 or equal
// to half_life is follow_update.
@(test)
follow_split_closes_up_and_across_at_their_own_half_lives :: proc(t:^testing.T) {
    up:=math.Vec3{0,1,0}
    f:Follow
    for _ in 0..<6 {follow_update_split(&f,{1,1,0},0.2,0.01,up,1.0/60)}
    testing.expectf(t,f.position.y>0.99 && f.position.x<0.5,"after 0.1 s %v",f.position)
    a,b:Follow
    for _ in 0..<10 {
        follow_update_split(&a,{2,3,-1},0.1,0,up,1.0/60)
        follow_update(&b,{2,3,-1},0.1,1.0/60)
    }
    testing.expectf(t,linalg.length(a.position-b.position)<1e-6,"%v and %v",a.position,b.position)
}
