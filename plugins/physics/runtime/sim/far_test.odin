package mirai_physics

import "core:fmt"
import "core:testing"

// 20 km from the origin along x, where a step of f32 is 1.95 mm (2^-9 m).
@(private="file")
FAR :: Vec3{20000,0,0}

@(private="file")
Far_Scene :: struct {
    stack:[6]Body_Handle,
    ball:Body_Handle,
    walker:Character_Handle,
}

// A pile of six boxes, a ball rolling over the floor and a character on it,
// placed around offset.
@(private="file")
far_scene :: proc(w:^World,offset:Vec3,sleep:bool) -> (scene:Far_Scene,ok:bool) {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity=32,32,256
    desc.character_capacity,desc.event_capacity=2,64
    desc.sleep_disabled=!sleep
    world_init(w,desc) or_return
    test_static_box(w,{60,1,60},offset+{0,-1,0})
    for &box,i in scene.stack {box=test_dynamic_box(w,{0.5,0.5,0.5},offset+{0,0.5+f32(i),0},10)}
    scene.ball=test_shape_body(w,Sphere{0.5},offset+{-20,0.5,10},velocity={4,0,0})
    scene.walker=test_character(w,offset+{-10,0,-10})
    return scene,scene.ball!={} && scene.walker!={}
}

@(private="file")
Far_Run :: struct {
    ball,walker:[360]Vec3, // by tick, from the offset
    stack:[6]Vec3,         // at the end
    tilt:f32,              // of the most turned box, 1-|w|
    landed:int,            // jumps that ended standing
    asleep:int,            // tick the pile slept; -1 awake
    jitter:f32,            // m, the largest move of a box or the standing walker in one tick of the last second
}

// Six seconds: the walker goes along x and jumps every 50 ticks for four,
// then stands; the ball rolls. Positions are measured from the offset.
@(private="file")
far_run :: proc(offset:Vec3,sleep:bool) -> (run:Far_Run,ok:bool) {
    w:=new(World)
    defer free(w)
    scene:=far_scene(w,offset,sleep) or_return
    defer world_destroy(w)
    run.asleep=-1
    previous:[7]Vec3
    for tick in 0..<len(run.ball) {
        walking:=tick<240
        jump:=walking && tick%50==25
        was:=test_standing(w,scene.walker)
        character_set_move(w,scene.walker,test_move(w,scene.walker,walking?{1,0,0}:{},jump))
        world_step(w,1.0/60)
        if !was && test_standing(w,scene.walker) && tick>0 {run.landed+=1}
        run.ball[tick]=body_position(w,scene.ball)-offset
        run.walker[tick]=character_position(w,scene.walker)-offset
        awake:=false
        for box in scene.stack {awake||=body_is_awake(w,box)}
        if !awake && run.asleep<0 {run.asleep=tick}
        now:[7]Vec3
        for box,i in scene.stack {now[i]=body_position(w,box)}
        now[6]=run.walker[tick]+offset
        if tick>=len(run.ball)-60 {
            for p,i in now {run.jitter=max(run.jitter,length(p-previous[i]))}
        }
        previous=now
    }
    for box,i in scene.stack {
        run.stack[i]=body_position(w,box)-offset
        run.tilt=max(run.tilt,1-abs(body_rotation(w,box).w))
    }
    return run,true
}

// A ball that glides at 4 m/s along x without gravity or contacts for one
// second: how far from 4 m it goes.
@(private="file")
far_glide :: proc(offset:Vec3) -> (drift:f32,ok:bool) {
    w:=new(World)
    defer free(w)
    test_world(w) or_return
    defer world_destroy(w)
    desc:=BODY_DESC_DEFAULT
    desc.position,desc.linear_velocity,desc.gravity_scale,desc.sleep_disabled=offset,{4,0,0},0,true
    ball:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Sphere{0.5}
    shape_create(w,ball,shape)
    test_steps(w,60)
    return (body_position(w,ball)-offset).x-4,true
}

// The same scene 20 km from the origin rests, sleeps, lands and stands still
// as at the origin. What moves across the far axis follows its path within a
// few steps of f32 there; what moves along it strays by the rounding of its
// position to that step at the end of every step, which the glide measures.
@(test)
the_physics_twenty_kilometres_from_the_origin_moves_as_at_the_origin :: proc(t:^testing.T) {
    STEP :: 1.0/512 // m, of f32 at 20 km
    for offset in ([2]Vec3{{20000,0,0},{0,0,20000}}) {
        along:=offset.x!=0
        for sleep in ([2]bool{true,false}) {
            near,near_ok:=far_run({},sleep)
            far,far_ok:=far_run(offset,sleep)
            if !testing.expect(t,near_ok && far_ok) {return}
            ball,walker:f32
            for tick in 0..<len(near.ball) {
                ball=max(ball,length(far.ball[tick]-near.ball[tick]))
                walker=max(walker,length(far.walker[tick]-near.walker[tick]))
            }
            stack:f32
            for p,i in far.stack {stack=max(stack,length(p-near.stack[i]))}
            fmt.printfln(
                "FAR %v sleep %v: ball path %.4f m (rolled %.2f m), walker path %.4f m (walked %.2f m), pile %.5f m, tilt %.1e, landed %v / %v, asleep at %v / %v, jitter %.5f / %.5f m",
                offset,sleep,ball,near.ball[len(near.ball)-1].x+20,walker,near.walker[len(near.walker)-1].x+10,stack,far.tilt,
                far.landed,near.landed,far.asleep,near.asleep,far.jitter,near.jitter,
            )
            // Along the far axis each step may round the position by half a step of f32.
            path:=f32(along?len(near.ball)*STEP/2:8*STEP)
            testing.expectf(t,ball<=path,"the ball strays %v m from its path at the origin",ball)
            testing.expectf(t,walker<=path,"the walker strays %v m from its path at the origin",walker)
            testing.expectf(t,stack<=4*STEP,"the pile rests %v m from where it rests at the origin",stack)
            testing.expectf(t,far.tilt<1e-4,"a box of the pile tilts: %v",far.tilt)
            testing.expect_value(t,far.landed,near.landed)
            testing.expectf(t,far.landed>=3,"the walker landed %v jumps",far.landed)
            testing.expectf(t,far.jitter<=STEP,"what stands still moves %v m in a tick",far.jitter)
            if sleep {
                testing.expectf(t,far.asleep>=0 && far.asleep<=near.asleep+30,"the pile sleeps at tick %v, at the origin at %v",far.asleep,near.asleep)
            }
        }
    }
    // 4 m/s moves 34.13 steps of f32 at 20 km in a step of 1/60 s, which rounds to 34.
    drift,glided:=far_glide({20000,0,0})
    near,near_glided:=far_glide({})
    if !testing.expect(t,glided && near_glided) {return}
    rounded:=f32(60*(34*STEP-4.0/60))
    fmt.printfln("FAR glide at 4 m/s for 1 s: %.4f m at 20 km, %.6f m at the origin, %.4f m from rounding every step",drift,near,rounded)
    testing.expectf(t,abs(drift-rounded)<=0.1*abs(rounded),"the glide strays %v m, not the %v m of rounding every step",drift,rounded)
}
