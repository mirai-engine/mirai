package mirai_physics

import "core:fmt"
import "core:testing"
import "core:time"
import cmath "core:math"

// Cylinders and the convex radius, with -define:PHYSICS_BENCH=true: steps of whole scenes, how still their
// stacks stay, and the narrow phase of single pairs.

@(private="file") Shapes_Scene :: enum {Pyramid_500,Pyramid_500_Rounded,Stacks_400,Stacks_400_Rounded,Cylinder_Stacks_400,Cylinders_2000}

@(private="file")
shapes_scene_build :: proc(w:^World,scene:Shapes_Scene) {
    #partial switch scene {
    case .Pyramid_500,.Pyramid_500_Rounded:
        test_ground(w,{200,1,50})
        round:=scene==.Pyramid_500_Rounded?f32(0.05):0
        base:=31
        for row in 0..<base {
            for column in 0..<base-row {
                test_shape_body(w,Box{{0.5,0.5,0.5}},{(f32(column)+0.5*f32(row)-0.5*f32(base))*1.02,0.5+f32(row),0},convex_radius=round)
            }
        }
    case .Stacks_400,.Stacks_400_Rounded,.Cylinder_Stacks_400:
        test_ground(w,{200,1,200})
        round:=scene==.Stacks_400_Rounded?f32(0.05):0
        for column in 0..<40 {
            for level in 0..<10 {
                p:=Vec3{f32(column%8)*3-12,0.5+f32(level),f32(column/8)*3-6}
                if scene==.Cylinder_Stacks_400 {
                    test_shape_body(w,Cylinder{0.5,0.5},p)
                } else {
                    test_shape_body(w,Box{{0.5,0.5,0.5}},p,convex_radius=round)
                }
            }
        }
    case .Cylinders_2000:
        mesh,_:=test_grid_mesh(w,96,120,proc(x,z:f32)->f32 {return 1.5*cmath.sin(0.15*x)*cmath.cos(0.12*z)+0.02*(x*x+z*z)})
        test_static_shape(w,mesh)
        side:=13
        for i in 0..<2000 {
            x,y,z:=i%side,i/side%side,i/(side*side)
            test_shape_body(w,Cylinder{0.25,0.25},{(f32(x)-0.5*f32(side))*0.9,12+f32(y)*0.9,(f32(z)-0.5*f32(side))*0.9},q_axis_angle({1,0.4,0.2},f32(i)))
        }
    }
}

// Step times of a scene, and how still its bodies stay: the mean speed of the dynamic bodies over the steps
// measured, and how far they moved from where the settling left them.
@(private="file")
shapes_scene_run :: proc(scene:Shapes_Scene,settle,measure:int) -> (result:Bench_Result,speed,drift:f64,stats:Stats) {
    w:=new(World)
    defer free(w)
    if !test_world_threaded(w,nil,8192,65536,64) {return}
    defer world_destroy(w)
    w.desc.sleep_disabled=true
    shapes_scene_build(w,scene)
    for _ in 0..<settle {world_step(w,1.0/60)}
    settled:=make([]Vec3,w.body_high)
    defer delete(settled)
    for &body,i in w.bodies[:w.body_high] {settled[i]=body.position}
    times:=new(Bench_Times)
    defer free(times)
    dynamic_count:=0
    for _ in 0..<measure {
        lap:=time.tick_now()
        world_step(w,1.0/60)
        bench_record(times,time.duration_milliseconds(time.tick_since(lap)),world_profile(w))
        for &body in w.bodies[:w.body_high] {
            if body.generation&1==0 || body.type!=.Dynamic {continue}
            speed+=f64(length(body.linear_velocity))
            dynamic_count+=1
        }
    }
    if dynamic_count>0 {speed/=f64(dynamic_count)}
    bodies:=0
    for &body,i in w.bodies[:w.body_high] {
        if body.generation&1==0 || body.type!=.Dynamic {continue}
        drift+=f64(length(body.position-settled[i]))
        bodies+=1
    }
    if bodies>0 {drift/=f64(bodies)}
    return bench_result(times),speed,drift,world_stats(w)
}

@(private="file") Shapes_Pair :: struct {name:string,a,b:Geometry,xf:Transform,round_a,round_b:f32}

// Nanoseconds of the narrow phase of one pair, over many calls.
@(private="file")
shapes_pair_time :: proc(pair:Shapes_Pair,calls:int) -> (ns:f64,points:int) {
    w:=new(World)
    defer free(w)
    if !test_world(w) {return}
    defer world_destroy(w)
    first:Body_Handle
    if mesh,is_mesh:=pair.a.(Mesh_Handle);is_mesh {
        _=mesh
        grid,_:=test_grid_mesh(w,8,16)
        first=test_shape_body(w,grid,{},type=.Static)
    } else {
        first=test_shape_body(w,pair.a,{},convex_radius=pair.round_a,type=.Static)
    }
    second:=test_shape_body(w,pair.b,pair.xf.p,pair.xf.q,convex_radius=pair.round_b)
    a:=&w.shapes[test_first_shape(w,first)]
    b:=&w.shapes[test_first_shape(w,second)]
    if a.type<b.type {a,b=b,a}
    xf:=xf_inv_mul(shape_transform_of(w,a),shape_transform_of(w,b))
    out:[1+EXTRA_MANIFOLDS]Local_Manifold
    sat:Sat_Cache
    count:=shapes_collide(w,a,b,xf,SPECULATIVE_DISTANCE,&out,&sat)
    for m in out[:count] {points+=int(m.count)}
    start:=time.tick_now()
    for _ in 0..<calls {shapes_collide(w,a,b,xf,SPECULATIVE_DISTANCE,&out,&sat)}
    ns=f64(time.duration_nanoseconds(time.tick_since(start)))/f64(calls)
    return
}

@(test)
bench_shapes :: proc(t:^testing.T) {
    if !PHYSICS_BENCH {return}
    tilt:=q_axis_angle({0,0,1},0.5*PI)
    lean:=q_axis_angle(normalize(Vec3{1,0,1}),0.3)
    pairs:=[?]Shapes_Pair{
        {"box on box",Box{{0.5,0.5,0.5}},Box{{0.5,0.5,0.5}},{{0.1,0.99,0.05},QUAT_IDENTITY},0,0},
        {"rounded box on box",Box{{0.5,0.5,0.5}},Box{{0.5,0.5,0.5}},{{0.1,0.99,0.05},QUAT_IDENTITY},0.05,0.05},
        {"box on box edge",Box{{0.5,0.5,0.5}},Box{{0.5,0.5,0.5}},{{0.4,1.2,0},q_axis_angle({0,0,1},0.25*PI)},0,0},
        {"rounded box on box edge",Box{{0.5,0.5,0.5}},Box{{0.5,0.5,0.5}},{{0.4,1.2,0},q_axis_angle({0,0,1},0.25*PI)},0.05,0.05},
        {"box on mesh",Mesh_Handle{},Box{{0.5,0.5,0.5}},{{0.3,0.495,0.2},QUAT_IDENTITY},0,0},
        {"rounded box on mesh",Mesh_Handle{},Box{{0.5,0.5,0.5}},{{0.3,0.495,0.2},QUAT_IDENTITY},0,0.05},
        {"standing cylinder on box",Box{{1,0.5,1}},Cylinder{0.4,0.5},{{0.1,0.995,0},QUAT_IDENTITY},0,0},
        {"lying cylinder on box",Box{{1,0.5,1}},Cylinder{0.4,0.5},{{0.1,0.895,0},tilt},0,0},
        {"leaning cylinder on box",Box{{1,0.5,1}},Cylinder{0.4,0.5},{{0.1,1.091,0},lean},0,0},
        {"rounded lying cylinder on box",Box{{1,0.5,1}},Cylinder{0.4,0.5},{{0.1,0.895,0},tilt},0,0.05},
        {"stacked cylinders",Cylinder{0.4,0.5},Cylinder{0.4,0.5},{{0.1,0.995,0},QUAT_IDENTITY},0,0},
        {"standing cylinder on mesh",Mesh_Handle{},Cylinder{0.4,0.5},{{0.3,0.495,0.2},QUAT_IDENTITY},0,0},
        {"lying cylinder on mesh",Mesh_Handle{},Cylinder{0.4,0.5},{{0.3,0.395,0.2},tilt},0,0},
        {"cylinder and sphere",Cylinder{0.4,0.5},Sphere{0.3},{{0.69,0.2,0},QUAT_IDENTITY},0,0},
        {"cylinder and capsule",Cylinder{0.4,0.5},Capsule{0.2,0.3},{{0.595,0.1,0},QUAT_IDENTITY},0,0},
    }
    for pair in pairs {
        ns,points:=shapes_pair_time(pair,200000)
        fmt.printfln("BENCH pair %v: %.0f ns, %v points",pair.name,ns,points)
    }
    for scene in Shapes_Scene {
        settle:=scene==.Cylinders_2000?240:120
        result,speed,drift,stats:=shapes_scene_run(scene,settle,BENCH_STEPS)
        fmt.printfln("BENCH %v: 1 thread median %.3f ms (best %.3f, mean %.3f), narrow %.3f ms; mean speed %.4f m/s, drift %.4f m; bodies %v contacts %v",
            scene,result.median,result.best,result.mean,result.stages[1],speed,drift,stats.bodies,stats.active_contacts)
    }
}
