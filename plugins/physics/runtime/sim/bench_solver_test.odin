package mirai_physics

import "core:testing"
import "core:fmt"
import "core:time"
import cmath "core:math"

@(private)
bench_box :: proc(w:^World,half,position:Vec3,rotation:Quat=QUAT_IDENTITY,type:=Body_Type.Dynamic,friction:f32=0.6) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.type,desc.position,desc.rotation=type,position,rotation
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{half}
    shape.friction=friction
    shape_create(w,body,shape)
    return body
}

// A ragdoll of 11 bodies standing at `origin`: spherical joints with cone and twist limits at the spine,
// neck, shoulders and hips, revolute joints with limits at the elbows and knees.
@(private)
bench_ragdoll :: proc(w:^World,origin:Vec3) {
    capsule :: proc(w:^World,position:Vec3,radius,half:f32,horizontal:bool) -> Body_Handle {
        desc:=BODY_DESC_DEFAULT
        desc.position=position
        if horizontal {desc.rotation=q_axis_angle({0,0,1},PI/2)}
        body:=body_create(w,desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Capsule{radius,half}
        shape_create(w,body,shape)
        return body
    }
    spherical :: proc(w:^World,a,b:Body_Handle,anchor,axis:Vec3,cone,twist:f32) {
        desc:=test_joint(w,.Spherical,a,b,anchor,axis)
        desc.angular={{motion=.Limited,lower=-twist,upper=twist},{motion=.Limited,lower=-cone,upper=cone},{motion=.Limited,lower=-cone,upper=cone}}
        joint_create(w,desc)
    }
    revolute :: proc(w:^World,a,b:Body_Handle,anchor,axis:Vec3,lower,upper:f32) {
        desc:=test_joint(w,.Revolute,a,b,anchor,axis)
        desc.angular[0]={motion=.Limited,lower=lower,upper=upper}
        joint_create(w,desc)
    }
    o:=origin
    pelvis:=bench_box(w,{0.15,0.1,0.1},o+{0,1,0})
    chest:=bench_box(w,{0.17,0.15,0.1},o+{0,1.3,0})
    spherical(w,pelvis,chest,o+{0,1.12,0},{0,1,0},0.4,0.3)
    head:=test_body(w,Sphere{0.11},o+{0,1.6,0})
    spherical(w,chest,head,o+{0,1.47,0},{0,1,0},0.6,0.6)
    for side in ([2]f32{-1,1}) {
        upper_arm:=capsule(w,o+{side*0.33,1.38,0},0.05,0.09,true)
        spherical(w,chest,upper_arm,o+{side*0.19,1.38,0},{side,0,0},1.2,0.5)
        fore_arm:=capsule(w,o+{side*0.61,1.38,0},0.045,0.09,true)
        revolute(w,upper_arm,fore_arm,o+{side*0.47,1.38,0},{0,0,1},side>0?0:-2.4,side>0?2.4:0)
        thigh:=capsule(w,o+{side*0.09,0.7,0},0.065,0.13,false)
        spherical(w,pelvis,thigh,o+{side*0.09,0.9,0},{0,-1,0},0.9,0.3)
        shin:=capsule(w,o+{side*0.09,0.28,0},0.055,0.13,false)
        revolute(w,thigh,shin,o+{side*0.09,0.49,0},{1,0,0},-2.4,0)
    }
}

@(private)
bench_ragdolls :: proc(w:^World,count:int) {
    test_ground(w,{200,1,50})
    side:=int(cmath.ceil(cmath.sqrt(f64(count))))
    for i in 0..<count {bench_ragdoll(w,{f32(i%side)*1.6,0.2,f32(i/side)*1.6})}
}

// Stacks of ten boxes that fall asleep while a kinematic paddle sweeps through some of them: islands
// wake, merge, come apart and fall asleep again.
@(private)
bench_sleep_piles :: proc(w:^World) {
    test_ground(w,{200,1,50})
    for pile in 0..<80 {
        x,z:=f32(pile%20)*2-19,f32(pile/20)*2-3
        for level in 0..<10 {bench_box(w,{0.25,0.25,0.25},{x,0.25+0.5*f32(level),z})}
    }
    paddle:=bench_box(w,{0.3,3,6},{-22,3,0},type=.Kinematic)
    body_set_velocity(w,paddle,{3,0,0},{})
}

@(private) Color_Scene :: enum {Pile_2000,Rods_1500,Mesh_Boxes_1500,Plank_150}

// How many manifolds find no graph color and go to the serial solver.
@(test)
bench_colors :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    for scene in Color_Scene {
        w:=new(World)
        defer free(w)
        testing.expect(t,test_world_threaded(w,nil,8192,65536,64))
        defer world_destroy(w)
        w.desc.sleep_disabled=true
        switch scene {
        case .Pile_2000:
            floor:=bench_box(w,{4,0.5,4},{0,-0.5,0},type=.Static)
            for wall in 0..<4 {
                angle:=f32(wall)*PI/2
                q:=q_axis_angle({0,1,0},angle)
                bench_box(w,{3.5,3,0.25},q_rotate(q,Vec3{0,3,3.25}),q,.Static)
            }
            _=floor
            for i in 0..<2000 {
                layer,cell:=i/196,i%196
                half:=0.17+0.02*f32(i%3)
                bench_box(w,{half,half,half},{(f32(cell%14)-6.5)*0.45,0.3+0.5*f32(layer),(f32(cell/14)-6.5)*0.45})
            }
        case .Rods_1500:
            bench_box(w,{4,0.5,4},{0,-0.5,0},type=.Static)
            for wall in 0..<4 {
                q:=q_axis_angle({0,1,0},f32(wall)*PI/2)
                bench_box(w,{3.5,4,0.25},q_rotate(q,Vec3{0,4,3.25}),q,.Static)
            }
            for i in 0..<1500 {
                layer,cell:=i/36,i%36
                desc:=BODY_DESC_DEFAULT
                desc.position={(f32(cell%6)-2.5)*1.0,0.5+0.35*f32(layer),(f32(cell/6)-2.5)*1.0}
                desc.rotation=q_axis_angle(normalize(Vec3{f32(i%7)-3,f32(i%5)-2+0.5,f32(i%3)-1}),f32(i%11)*0.6)
                body:=body_create(w,desc)
                shape:=SHAPE_DESC_DEFAULT
                shape.geometry=Capsule{0.08,0.4}
                shape_create(w,body,shape)
            }
        case .Mesh_Boxes_1500:
            mesh,_:=test_grid_mesh(w,96,120,proc(x,z:f32)->f32 {return 1.5*cmath.sin(0.15*x)*cmath.cos(0.12*z)+0.02*(x*x+z*z)})
            test_static_shape(w,mesh)
            for i in 0..<1500 {
                x,y,z:=i%15,i/225,i/15%15
                bench_box(w,{0.25,0.25,0.25},{(f32(x)-7)*0.9,12+f32(y)*0.9,(f32(z)-7)*0.9})
            }
        case .Plank_150:
            test_ground(w)
            bench_box(w,{6,0.1,1},{0,0.1,0})
            for i in 0..<150 {bench_box(w,{0.15,0.15,0.15},{(f32(i%30)-14.5)*0.38,0.36,(f32(i/30)-2)*0.38})}
        }
        constraints,overflow,steps,colors:=0,0,0,0
        worst:f64
        times:=new(Bench_Times)
        defer free(times)
        for step in 0..<360 {
            lap:=time.tick_now()
            world_step(w,1.0/60)
            if step<120 {continue}
            bench_record(times,time.duration_milliseconds(time.tick_since(lap)),world_profile(w))
            stats:=world_stats(w)
            constraints+=stats.constraints
            overflow+=stats.overflow_constraints
            worst=max(worst,f64(stats.overflow_constraints)/f64(max(stats.constraints,1)))
            colors=max(colors,stats.colors)
            steps+=1
        }
        result:=bench_result(times)
        fmt.printfln("BENCH colors %v: %v manifolds per step, %.2f %% without color (worst step %.2f %%), up to %v colors; step median %.3f ms, solve %.3f ms",
            scene,constraints/steps,100*f64(overflow)/f64(max(constraints,1)),100*worst,colors,result.median,result.stages[3])
    }
}

// Quality of friction against closed forms.
@(test)
bench_friction :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    world :: proc(w:^World) {
        test_world(w)
        w.desc.sleep_disabled=true
    }
    ramp :: proc(w:^World,angle,friction:f32) -> Vec3 {
        q:=q_axis_angle({0,0,1},angle)
        bench_box(w,{20,0.5,20},{},q,.Static,friction)
        return q_rotate(q,Vec3{0,1,0})
    }
    // Sliding threshold of a box on a ramp: it should hold below atan(mu) and slide above it.
    for mu in ([3]f32{0.2,0.5,0.8}) {
        critical:=f32(-1)
        creep:f32
        ideal:=cmath.atan(mu)*180/PI
        for k in 0..=24 {
            degrees:=ideal-3+0.25*f32(k)
            angle:=degrees*PI/180
            w:World
            world(&w)
            up:=ramp(&w,angle,mu)
            box:=bench_box(&w,{0.5,0.5,0.5},up*1.001,q_axis_angle({0,0,1},angle),friction=mu)
            start:=body_position(&w,box)
            test_steps(&w,120)
            moved:=length(body_position(&w,box)-start)
            if k==4 {creep=moved}
            if critical<0 && moved>0.05 {critical=degrees}
            world_destroy(&w)
        }
        fmt.printfln("BENCH friction ramp mu %.1f: slides from %.2f deg (atan mu %.2f deg); moved %.4f m in 2 s at 2 deg below",mu,critical,ideal,creep)
    }
    // Leaning towers of eight 1 m boxes, each shifted along X from the one below: stable while the boxes above
    // each one have their center over it, up to 0.125 m.
    for shift in ([6]f32{0.04,0.06,0.07,0.08,0.10,0.12}) {
        w:World
        world(&w)
        test_ground(&w)
        boxes:[8]Body_Handle
        for &box,i in boxes {box=bench_box(&w,{0.5,0.5,0.5},{shift*f32(i),0.5+f32(i),0})}
        test_steps(&w,600)
        drift:f32
        for box,i in boxes {drift=max(drift,length(body_position(&w,box)-Vec3{shift*f32(i),0.5+f32(i),0}))}
        fmt.printfln("BENCH friction leaning tower shifted %.2f m per box: largest drift in 10 s %.4f m",shift,drift)
        world_destroy(&w)
    }
    // A brick stack of ten boxes alternately shifted by a quarter of their length, sideways on a ramp of 10 degrees.
    {
        w:World
        world(&w)
        up:=ramp(&w,10*PI/180,0.6)
        q:=q_axis_angle({0,0,1},10*PI/180)
        boxes:[10]Body_Handle
        starts:[10]Vec3
        for &box,i in boxes {
            starts[i]=up*(0.751+0.5*f32(i))+q_rotate(q,Vec3{0,0,i%2==0?0.125:-0.125})
            box=bench_box(&w,{1,0.25,0.5},starts[i],q)
        }
        test_steps(&w,600)
        drift:f32
        for box,i in boxes {drift=max(drift,length(body_position(&w,box)-starts[i]))}
        fmt.printfln("BENCH friction brick stack on a 10 deg ramp: largest drift in 10 s %.4f m",drift)
        world_destroy(&w)
    }
    // A ball rolls down a 20 degree slope without slipping: a = 5/7 g sin.
    {
        w:World
        world(&w)
        angle:f32=20*PI/180
        up:=ramp(&w,angle,0.6)
        ball:=test_body(&w,Sphere{0.25},up*(0.5+0.25+0.001))
        start:=body_position(&w,ball)
        test_steps(&w,60)
        distance:=length(body_position(&w,ball)-start)
        ideal:=0.5*(5.0/7)*9.81*cmath.sin(angle)
        v,om:=body_linear_velocity(&w,ball),body_angular_velocity(&w,ball)
        slip:=length(v+cross(om,-0.25*up))/max(length(v),1e-6)
        fmt.printfln("BENCH friction rolling ball on 20 deg: %.4f m in 1 s (rolling without slip %.4f m), slip %.4f",distance,ideal,slip)
        world_destroy(&w)
    }
    // A box thrown at 5 m/s along the ground stops after v^2/(2 mu g).
    {
        w:World
        world(&w)
        bench_box(&w,{50,0.5,50},{0,-0.5,0},type=.Static,friction=0.5)
        box:=bench_box(&w,{0.5,0.5,0.5},{0,0.5,0},friction=0.5)
        body_set_velocity(&w,box,{5,0,0},{})
        test_steps(&w,180)
        fmt.printfln("BENCH friction box thrown at 5 m/s: stops after %.4f m (closed form %.4f m)",body_position(&w,box).x,25/(2*0.5*9.81))
        world_destroy(&w)
    }
    // A box spun at 10 rad/s on the ground: with an even pressure under a square of side s the friction torque
    // is 0.3826 mu m g s, and it stops after (s w/6)/(0.3826 mu g).
    {
        w:World
        world(&w)
        bench_box(&w,{50,0.5,50},{0,-0.5,0},type=.Static,friction=0.5)
        box:=bench_box(&w,{0.5,0.5,0.5},{0,0.5,0},friction=0.5)
        body_set_velocity(&w,box,{},{0,10,0})
        stop:f32=-1
        for step in 0..<180 {
            world_step(&w,1.0/60)
            if stop<0 && abs(body_angular_velocity(&w,box).y)<0.05 {stop=f32(step+1)/60}
        }
        fmt.printfln("BENCH friction box spun at 10 rad/s: stops after %.3f s (even pressure %.3f s), drift %.4f m",stop,(10.0/6)/(0.3826*0.5*9.81),length(body_position(&w,box)*Vec3{1,0,1}))
        world_destroy(&w)
    }
}

// 19,000 boxes asleep on the ground and 200 balls that roll apart in a corner and never sleep: the step should
// cost what the awake ones cost.
@(test)
bench_asleep :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    w:=new(World)
    defer free(w)
    testing.expect(t,test_world_threaded(w,nil,20480,65536,64))
    defer world_destroy(w)
    test_ground(w,{200,1,200})
    for i in 0..<19000 {
        desc:=BODY_DESC_DEFAULT
        desc.position,desc.asleep={(f32(i%140)-70)*1.2,0.25,(f32(i/140)-70)*1.2},true
        body:=body_create(w,desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Box{{0.25,0.25,0.25}}
        shape_create(w,body,shape)
    }
    for i in 0..<200 {
        ball:=test_body(w,Sphere{0.25},{150+f32(i%10)*2,0.25,f32(i/10)*2})
        body_set_sleep_disabled(w,ball,true)
        body_set_velocity(w,ball,{0,0,1},{})
    }
    times:=new(Bench_Times)
    defer free(times)
    cycles:u64
    for step in 0..<240 {
        lap:=time.tick_now()
        before:=bench_thread_cycles()
        world_step(w,1.0/60)
        if step>=60 {
            cycles+=bench_thread_cycles()-before
            bench_record(times,time.duration_milliseconds(time.tick_since(lap)),world_profile(w))
        }
    }
    result:=bench_result(times)
    stats:=world_stats(w)
    fmt.printfln("BENCH asleep %v bodies, %v awake, %v contacts, %v active: %.2f Mcycles of the thread per step; step median %.3f ms (best %.3f); pairs %.3f narrow %.3f prepare %.3f solve %.3f finalize %.3f sleep %.3f",
        stats.bodies,stats.awake_bodies,stats.contacts,stats.active_contacts,f64(cycles)/180e6,result.median,result.best,result.stages[0],result.stages[1],result.stages[2],result.stages[3],result.stages[4],result.stages[5])
}

// Cycles the calling thread has run: its work, whatever else shares the machine. Zero where it is not known.
@(private)
bench_thread_cycles :: proc() -> (cycles:u64) {
    when ODIN_OS==.Windows {bench_query_thread_cycles(bench_current_thread(),&cycles)}
    return
}

when ODIN_OS==.Windows {
    foreign import bench_kernel32 "system:Kernel32.lib"
    @(default_calling_convention="system",private)
    foreign bench_kernel32 {
        @(link_name="GetCurrentThread") bench_current_thread :: proc() -> rawptr ---
        @(link_name="QueryThreadCycleTime") bench_query_thread_cycles :: proc(thread:rawptr,cycles:^u64) -> i32 ---
    }
}

// 5,000 balls fall on rolling ground with sleeping on, until they all sleep: what the islands cost while a
// large pile settles.
@(test)
bench_sleep :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    w:=new(World)
    defer free(w)
    testing.expect(t,test_world_threaded(w,nil,8192,65536,64))
    defer world_destroy(w)
    bench_spheres(w,5000)
    steps,stages:=new(Bench_Times),new(Bench_Times)
    defer free(steps)
    defer free(stages)
    asleep:=-1
    worst:f64
    for step in 0..<1200 {
        lap:=time.tick_now()
        world_step(w,1.0/60)
        ms:=time.duration_milliseconds(time.tick_since(lap))
        profile:=world_profile(w)
        if step>=120 && step<360 {
            bench_record(steps,ms,profile)
            worst=max(worst,f64(profile.sleep))
        }
        if asleep<0 && world_stats(w).awake_bodies==0 {asleep=step+1}
    }
    result:=bench_result(steps)
    fmt.printfln("BENCH sleep of 5000 balls: steps 120 to 360 median %.3f ms, prepare %.3f, sleep stage %.3f (worst %.3f); all asleep after %v steps",
        result.median,result.stages[2],result.stages[5],worst,asleep)
}
