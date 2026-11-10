package physics

import "core:testing"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import "core:math/linalg"
import mm "mirai:std/math"

@(test)
force_and_torque_requests_use_si_units_and_clear_after_one_tick :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=2
    e:=physics_test_box(&f,{},{0.5,0.5,0.5},rigid)
    physics_test_step(&f,0)
    body:=body_of(core.ref(&f.state),e)
    apply_force(&f.requests,e,{120,0,0})
    apply_torque(&f.requests,e,{0,12,0})
    physics_test_step(&f)
    first:=sim.body_linear_velocity(&f.state.world,body)
    angular:=sim.body_angular_velocity(&f.state.world,body)
    testing.expectf(t,abs(first.x-1)<0.001,"force velocity %v",first)
    testing.expect(t,angular.y>0)
    physics_test_step(&f)
    testing.expectf(t,abs(sim.body_linear_velocity(&f.state.world,body).x-first.x)<0.001,"force persisted")
    apply_force(&f.requests,e,{0,120,0},[3]f32{1,0,0})
    physics_test_step(&f)
    testing.expect(t,sim.body_angular_velocity(&f.state.world,body).z>0)
}

@(test)
radial_requests_reach_more_than_256_bodies_once_per_compound :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    f.settings.bodies,f.settings.shapes,f.settings.contacts=400,800,1600
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=2
    objects:[300]core.Entity
    for &e,i in objects {
        e=physics_test_box(&f,{f32(i+1),0,0},{0.1,0.1,0.1},rigid)
        child:=physics_test_box(&f,{0,0.5,0},{0.1,0.1,0.1})
        core.add(&f.parents,child,core.Parent{entity=e})
    }
    physics_test_step(&f,0)
    apply_radial_impulse(&f.requests,{},1000,2,.Constant)
    physics_test_step(&f)
    for e in objects {
        body:=body_of(core.ref(&f.state),e)
        velocity:=sim.body_linear_velocity(&f.state.world,body)
        testing.expectf(t,abs(linalg.length(velocity)-1)<0.001,"radial missed or doubled %v: %v",e,velocity)
    }
    apply_radial_impulse(&f.requests,{},1000,1,.Constant,true)
    physics_test_step(&f)
    for e in objects {
        testing.expect(t,abs(linalg.length(sim.body_linear_velocity(&f.state.world,body_of(core.ref(&f.state),e)))-2)<0.01)
    }
    results:[400]core.Entity
    count,_:=overlap_sphere(core.ref(&f.state),{},1000,results[:])
    testing.expect(t,count>0)
}

@(test)
plane_requests_and_the_range_and_noise_of_volume_requests_reach_the_simulation :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    rigid:=RIGID_BODY_DYNAMIC
    rigid.mass=2
    deep:=physics_test_box(&f,{0,0.5,0},{0.1,0.1,0.1},rigid)
    shallow:=physics_test_box(&f,{2,0.9,0},{0.1,0.1,0.1},rigid)
    physics_test_step(&f,0)
    w:=&f.state.world
    bodies:=[2]sim.Body_Handle{body_of(core.ref(&f.state),deep),body_of(core.ref(&f.state),shallow)}
    speeds :: proc(w:^sim.World,bodies:[2]sim.Body_Handle) -> [2]f32 {
        return {sim.body_linear_velocity(w,bodies[0]).x,sim.body_linear_velocity(w,bodies[1]).x}
    }
    // The plane is the +Y face at y=1 and the box is 1 m deep: Linear weighs 0.5 and 0.9 at those depths.
    apply_plane_force(&f.requests,{1,0.5,0},{2,0.5,1},1,{120,0,0},.Linear)
    physics_test_step(&f)
    after:=speeds(w,bodies)
    testing.expectf(t,abs(after[0]-0.5)<1e-3 && abs(after[1]-0.9)<1e-3,"plane %v",after)
    before:=after
    apply_sphere_force(&f.requests,{1,0.5,0},5,{120,0,0},.Linear,QUERY_FILTER_DEFAULT,{0.25,0.25})
    physics_test_step(&f)
    after=speeds(w,bodies)
    testing.expectf(t,abs(after[0]-before[0]-0.25)<1e-3 && abs(after[1]-before[1]-0.25)<1e-3,"range %v",after-before)
    noise:=Field_Noise{scale=0.5,seed=11,range={0,2}}
    expected:[2]f32
    for body,i in bodies {expected[i]=0.5*sim.noise_weight(sim.body_position(w,body),{1,0.5,0},mm.QUAT_IDENTITY,noise)}
    before=after
    apply_box_force(&f.requests,{1,0.5,0},{2,1,1},1,{60,0,0},.Constant,QUERY_FILTER_DEFAULT,{},noise)
    physics_test_step(&f)
    after=speeds(w,bodies)
    testing.expectf(t,abs(after[0]-before[0]-expected[0])<1e-3 && abs(after[1]-before[1]-expected[1])<1e-3,"noise %v against %v",after-before,expected)
    problems:=f.problems.count
    apply_radial_force(&f.requests,{},5,10,.Linear,QUERY_FILTER_DEFAULT,{},{scale=-1})
    physics_test_step(&f)
    testing.expect_value(t,f.problems.count,problems+1)
}

@(test)
external_proxies_accept_impulses_forces_joints_and_manipulation :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    physics_test_step(&f,0)
    desc:=sim.BODY_DESC_DEFAULT
    desc.gravity_scale=0
    desc.position={2,0,0}
    body:=sim.body_create(&f.state.world,desc)
    shape:=sim.SHAPE_DESC_DEFAULT
    shape.geometry=sim.Box{{0.5,0.5,0.5}}
    sim.shape_create(&f.state.world,body,shape)
    sim.body_set_mass_properties(&f.state.world,body,2,{},sim.Mat3{1,0,0,0,1,0,0,0,1})
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{2,0,0},1,{1,1,1}})
    physics_test_settle(&f)
    testing.expect(t,proxy_set(&f.state,e,body,{2,0,0},1))
    apply_impulse(&f.requests,e,{2,0,0})
    apply_force(&f.requests,e,{120,0,0})
    physics_test_step(&f)
    testing.expect(t,abs(sim.body_linear_velocity(&f.state.world,body).x-2)<0.01)
    testing.expect_value(t,manipulation_owner(core.ref(&f.state),e),e)
    core.add(&f.joints,e,joint_fixed(core.NONE))
    physics_test_step(&f)
    testing.expect(t,sim.joint_valid(&f.state.world,core.entity_map_get(&f.state.joints,e).joint))
    core.remove(&f.joints,e)
    manipulation_target(&f.requests,e,{3,0,0})
    physics_test_step(&f,0)
    testing.expect_value(t,sim.body_type(&f.state.world,body),sim.Body_Type.Kinematic)
    manipulation_end(&f.requests,e)
    physics_test_step(&f,0)
    testing.expect_value(t,sim.body_type(&f.state.world,body),sim.Body_Type.Dynamic)
    testing.expect_value(t,sim.body_mass(&f.state.world,body),f32(2))
    testing.expect_value(t,sim.body_position(&f.state.world,body),sim.Vec3{3,0,0})
    proxy_remove(&f.state,e)
    testing.expect(t,sim.body_valid(&f.state.world,body))
    testing.expect_value(t,body_of(core.ref(&f.state),e),sim.Body_Handle{})
}

@(test)
the_push_force_of_a_character_reaches_the_simulation_without_making_it_again :: proc(t:^testing.T) {
    f:Physics_Test
    if !physics_test_init(t,&f) {return}
    defer physics_test_destroy(&f)
    testing.expect_value(t,character_default().push_force,sim.CHARACTER_DESC_DEFAULT.push_force)
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{0,1,0},1,{1,1,1}})
    core.add(&f.colliders,e,collider_character())
    config:=character_default()
    config.push_force=250
    core.add(&f.characters,e,config)
    physics_test_step(&f,0)
    l:=link_find(&f.state,e)
    testing.expect(t,l!=nil && l.kind==.Character)
    testing.expect_value(t,sim.character_desc(&f.state.world,l.character).push_force,f32(250))
    created:=f.state.stats.characters_created
    core.get(&f.characters,e).push_force=600
    physics_test_step(&f,0)
    testing.expect_value(t,sim.character_desc(&f.state.world,link_find(&f.state,e).character).push_force,f32(600))
    testing.expect_value(t,f.state.stats.characters_created,created)
}
