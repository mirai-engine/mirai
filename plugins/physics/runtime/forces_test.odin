package physics

import "core:testing"
import "mirai:core"
import volume "mirai:engine/volume"
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
area_requests_reach_more_than_256_bodies_once_per_compound :: proc(t:^testing.T) {
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
    apply_area(&f.requests,volume.sphere(1000),{},2,impulse=true)
    physics_test_step(&f)
    for e in objects {
        body:=body_of(core.ref(&f.state),e)
        velocity:=sim.body_linear_velocity(&f.state.world,body)
        testing.expectf(t,abs(linalg.length(velocity)-1)<0.001,"radial missed or doubled %v: %v",e,velocity)
    }
    apply_area(&f.requests,volume.sphere(1000),{},1,impulse=true,velocity_change=true)
    physics_test_step(&f)
    for e in objects {
        testing.expect(t,abs(linalg.length(sim.body_linear_velocity(&f.state.world,body_of(core.ref(&f.state),e)))-2)<0.01)
    }
    results:[400]core.Entity
    count,_:=overlap_sphere(core.ref(&f.state),{},1000,results[:])
    testing.expect(t,count>0)
}

// An area request pushes the bodies in its volume, where the volume is: by the weight of the volume through
// the falloff, its range and its noise, away from it or along a direction.
@(test)
area_requests_push_by_the_weight_of_their_volume_its_range_and_its_noise :: proc(t:^testing.T) {
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
    speeds :: proc(w:^sim.World,bodies:[2]sim.Body_Handle,axis:=0) -> [2]f32 {
        return {sim.body_linear_velocity(w,bodies[0])[axis],sim.body_linear_velocity(w,bodies[1])[axis]}
    }
    Case :: struct {
        name:string,
        area:volume.Volume,
        pose:mm.Transform,
        strength:f32,
        along:[3]f32,
        falloff:Radial_Falloff,
        range:Weight_Range,
        axis:int,
        gained:[2]f32, // m/s in the tick, on axis
        blend:f32,
    }
    cases:=[?]Case{
        // Under a plane at y=1 whose weight rises over 1 m: 0.5 and 0.1 of 120 N on 2 kg.
        {"a plane along a direction",volume.plane(),{position={0,1,0}},120,{1,0,0},.Linear,{},0,{0.5,0.1},1},
        // Away from a plane is along its up; the same weights squared.
        {"a plane away",volume.plane(),{position={0,1,0}},120,{},.Squared,{},1,{0.25,0.01},1},
        // A plane turned on its side holds only what is under it: +X of x=1.
        {"a turned plane",volume.plane(),{position={1,0,0},rotation=mm.quat_axis_angle({0,0,1},0.5*mm.PI)},120,{0,0,1},.Linear,{},2,{0,1},0},
        // The whole of a range of one weight, wherever in the sphere.
        {"a range",volume.sphere(5),{position={1,0.5,0}},120,{1,0,0},.Linear,{0.25,0.25},0,{0.25,0.25},5},
        // A box of half 1 scaled by 2 in x, without blend: whole inside, nothing outside.
        {"a scaled box",volume.box({0.5,1,1}),{position={-0.5,0.5,0},rotation=1,scale={2,1,1}},120,{1,0,0},.Linear,{},0,{1,0},0},
        // Away from the center of a sphere, pulled in by a negative strength.
        {"a pull",volume.sphere(1),{position={0,1.2,0}},-120,{},.Linear,{},1,{1,0},0},
    }
    for c in cases {
        before:=speeds(w,bodies,c.axis)
        apply_area(&f.requests,c.area,c.pose,c.strength,c.along,blend=c.blend,falloff=c.falloff,range=c.range)
        physics_test_step(&f)
        gained:=speeds(w,bodies,c.axis)-before
        testing.expectf(t,abs(gained[0]-c.gained[0])<2e-3 && abs(gained[1]-c.gained[1])<2e-3,"%s: gained %v, not %v",c.name,gained,c.gained)
        for body in bodies {sim.body_set_velocity(w,body,{},{})}
        sim.body_set_transform(w,bodies[0],{0,0.5,0},1)
        sim.body_set_transform(w,bodies[1],{2,0.9,0},1)
    }
    // An outline by the Spline of the entity it names: an L whose notch, inside its box, holds the shallow body.
    holder:=core.create(&f.entities)
    core.add(&f.splines,holder,volume.Spline{count=6,points={0={position={-1,0,-1}},1={position={3,0,-1}},2={position={3,0,-0.5}},3={position={1,0,-0.5}},4={position={1,0,1}},5={position={-1,0,1}}}})
    physics_test_step(&f,0)
    apply_area(&f.requests,volume.outline(4),{position={0,0.5,0},rotation=1,scale=1},120,{1,0,0},outline_of=holder)
    physics_test_step(&f)
    gained:=speeds(w,bodies)
    testing.expectf(t,abs(gained[0]-1)<2e-3 && abs(gained[1])<2e-3,"an outline: gained %v, not [1, 0]",gained)
    for body in bodies {sim.body_set_velocity(w,body,{},{})}
    noise:=Field_Noise{scale=0.5,seed=11,range={0,2}}
    expected:[2]f32
    for body,i in bodies {expected[i]=0.5*sim.noise_weight(sim.body_position(w,body),{1,0.5,0},mm.QUAT_IDENTITY,noise)}
    apply_area(&f.requests,volume.box({2,1,1}),{position={1,0.5,0}},60,{1,0,0},noise=noise)
    physics_test_step(&f)
    after:=speeds(w,bodies)
    testing.expectf(t,abs(after[0]-expected[0])<1e-3 && abs(after[1]-expected[1])<1e-3,"noise %v against %v",after,expected)
    testing.expect(t,core.problem_find(&f.problems,core.NONE,"physics.request_area")==nil)
    // What cannot push says so once per request, and pushes nothing.
    nan:=f32(0)
    nan/=nan
    for body in bodies {sim.body_set_velocity(w,body,{},{})}
    apply_area(&f.requests,volume.sphere(5),{},10,noise={scale=-1})
    apply_area(&f.requests,volume.sphere(0),{},10)
    apply_area(&f.requests,volume.box({1,-1,1}),{},10)
    apply_area(&f.requests,volume.sphere(5),{position={nan,0,0}},10)
    apply_area(&f.requests,volume.sphere(5),{},nan)
    apply_area(&f.requests,volume.sphere(5),{},10,{nan,0,0})
    apply_area(&f.requests,volume.sphere(5),{},10,blend=nan)
    apply_area(&f.requests,volume.Volume{shape=volume.Volume_Shape(9)},{},10)
    apply_area(&f.requests,volume.sphere(5),{},10,velocity_change=true)
    physics_test_step(&f)
    testing.expect(t,core.problem_find(&f.problems,core.NONE,"physics.request_area")!=nil)
    testing.expect_value(t,speeds(w,bodies),[2]f32{})
}

@(private) @(test_world) Field_World :: struct {
    using world:Test_World,
    fields:core.Table(Force_Field),
    volumes:core.Table(volume.Volume),
    worlds:core.Table(core.World_Transform),
    requests:Body_Requests,
}

// A Force_Field asks, each tick, for the area of the Volume of its entity where the entity is: its
// direction turns with the entity, and one that is off or without force asks for nothing.
@(test)
a_force_field_pushes_in_the_volume_of_its_entity :: proc(t:^testing.T) {
    w:Field_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    turn:=mm.quat_axis_angle({0,1,0},0.5*mm.PI)
    lift,idle:=core.create(&w.entities),core.create(&w.entities)
    config:=FORCE_FIELD_DEFAULT
    config.force,config.along,config.blend,config.falloff_range,config.filter.objects=10,{0,0,-2},1,{0.5,1},4
    core.add(&w.fields,lift,config)
    core.add(&w.volumes,lift,volume.box({1,2,3}))
    core.add(&w.worlds,lift,core.World_Transform{transform={{3,4,5},turn,{2,1,0.5}}})
    core.add(&w.fields,idle,FORCE_FIELD_DEFAULT)
    test_world_settle(&w)
    step :: proc(w:^Field_World,time:core.Time) {
        force_fields_step(core.read(&w.fields),core.read(&w.volumes),core.read(&w.worlds),{},{},&w.requests,time)
    }
    step(&w,{playing=true,dt=0.25})
    if !testing.expect_value(t,len(w.requests.queue.items),1) {return}
    request:=w.requests.queue.items[0]
    testing.expect_value(t,request.kind,Body_Request_Kind.Area_Force)
    testing.expect(t,request.area==volume.box({1,2,3}) && request.blend==1)
    testing.expect(t,request.position==[3]f32{3,4,5} && request.rotation==turn && request.scale==[3]f32{2,1,0.5})
    testing.expectf(t,linalg.length(request.linear-[3]f32{-1,0,0})<1e-5,"its forward, a quarter turn to the left: %v",request.linear)
    testing.expect(t,request.strength==10 && request.falloff_range==Weight_Range{0.5,1} && request.filter.objects==4)
    core.queue_clear(&w.requests.queue)
    step(&w,{playing=false,dt=0.25})
    testing.expect_value(t,len(w.requests.queue.items),0)
    core.disable(&w.fields,lift)
    test_world_settle(&w)
    step(&w,{playing=true,dt=0.25})
    testing.expect_value(t,len(w.requests.queue.items),0)
}

@(test)
external_proxies_replace_the_own_body_and_accept_impulses_forces_joints_and_manipulation :: proc(t:^testing.T) {
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
    // The body of its own Collider and Rigid_Body ends: the proxy stands for them, and no sync makes it again.
    e:=core.create(&f.entities)
    core.add(&f.transforms,e,core.Transform{{2,0,0},1,{1,1,1}})
    core.add(&f.rigids,e,RIGID_BODY_DYNAMIC);core.add(&f.colliders,e,collider_sphere(0.5))
    physics_test_step(&f,0)
    own:=body_of(core.ref(&f.state),e)
    testing.expect(t,own!={} && own!=body)
    testing.expect(t,proxy_set(&f.state,e,body))
    testing.expect(t,!sim.body_valid(&f.state.world,own))
    core.edit(&f.colliders,e).friction=0.3
    physics_test_step(&f,0)
    testing.expect_value(t,body_of(core.ref(&f.state),e),body)
    apply_impulse(&f.requests,e,{2,0,0})
    apply_force(&f.requests,e,{120,0,0})
    physics_test_step(&f)
    testing.expect(t,abs(sim.body_linear_velocity(&f.state.world,body).x-2)<0.01)
    testing.expect_value(t,manipulation_owner(core.ref(&f.state),e),e)
    joint:=physics_test_joint(&f,e,{},joint_fixed(core.NONE))
    physics_test_step(&f)
    testing.expect(t,sim.joint_valid(&f.state.world,core.entity_map_get(&f.state.joints,joint).joint))
    core.remove(&f.joints,joint)
    manipulation_target(&f.requests,e,{3,0,0},follow=true)
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
    core.edit(&f.characters,e).push_force=600
    physics_test_step(&f,0)
    testing.expect_value(t,sim.character_desc(&f.state.world,link_find(&f.state,e).character).push_force,f32(600))
    testing.expect_value(t,f.state.stats.characters_created,created)
}

// A compound of two pieces whose second becomes a proxy weighs and balances as a body made of the first alone,
// with the mass its Rigid_Body gives or that of its shapes.
@(test)
a_compound_that_gives_a_piece_to_a_proxy_weighs_as_what_it_keeps :: proc(t:^testing.T) {
    for mass in ([2]f32{0,4}) {
        f:Physics_Test
        if !physics_test_init(t,&f) {return}
        defer physics_test_destroy(&f)
        rigid:=RIGID_BODY_DYNAMIC
        rigid.mass=mass
        compound:=owner_of(&f,{0,5,0},rigid)
        piece_of(&f,compound,{-1,0,0},{0.5,0.5,0.5})
        given:=piece_of(&f,compound,{1,0,0},{0.5,1,0.5})
        alone:=owner_of(&f,{0,5,10},rigid)
        piece_of(&f,alone,{-1,0,0},{0.5,0.5,0.5})
        other:=physics_test_box(&f,{5,5,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)
        physics_test_step(&f,0)
        testing.expect(t,proxy_set(&f.state,given,body_of(core.ref(&f.state),other)))
        a,a_center,_:=sim.body_mass_properties(&f.state.world,body_of(core.ref(&f.state),compound))
        b,b_center,_:=sim.body_mass_properties(&f.state.world,body_of(core.ref(&f.state),alone))
        testing.expectf(t,abs(a-b)<1e-4 && linalg.length(a_center-b_center)<1e-4,"mass %v: %v kg at %v, alone %v kg at %v",mass,a,a_center,b,b_center)
    }
    owner_of :: proc(f:^Physics_Test,at:[3]f32,rigid:Rigid_Body) -> core.Entity {
        e:=core.create(&f.entities)
        core.add(&f.transforms,e,core.Transform{at,1,{1,1,1}})
        core.add(&f.rigids,e,rigid)
        return e
    }
    piece_of :: proc(f:^Physics_Test,owner:core.Entity,at,half:[3]f32) -> core.Entity {
        e:=physics_test_box(f,at,half)
        core.add(&f.parents,e,core.Parent{owner,0})
        return e
    }
}
