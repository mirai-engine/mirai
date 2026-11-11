package mirai_physics

import "core:testing"
import cmath "core:math"
import "core:math/rand"
import "mirai:std/spatial"

@(private)
test_world :: proc(w:^World,bodies:=256,contacts:=2048) -> bool {
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=bodies,bodies,contacts,64
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=8,4,2,256
    return world_init(w,desc)
}

@(private)
test_ground :: proc(w:^World,half:Vec3={50,1,50}) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.type=.Static
    desc.position={0,-half.y,0}
    ground:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{half}
    shape_create(w,ground,shape)
    return ground
}

@(private)
test_body :: proc(w:^World,geometry:Geometry,position:Vec3,type:=Body_Type.Dynamic,friction:f32=0.6,restitution:f32=0) -> Body_Handle {
    desc:=BODY_DESC_DEFAULT
    desc.type=type
    desc.position=position
    body:=body_create(w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=geometry
    shape.friction,shape.restitution=friction,restitution
    shape_create(w,body,shape)
    return body
}

@(private)
test_steps :: proc(w:^World,count:int,dt:f32=1.0/60) {
    for _ in 0..<count {world_step(w,dt)}
}

@(test)
world_init_rejects_empty_capacities :: proc(t:^testing.T) {
    w:World
    desc:=world_desc_default()
    desc.body_capacity=0
    testing.expect(t,!world_init(&w,desc))
    testing.expect(t,test_world(&w))
    testing.expect_value(t,world_gravity(&w),Vec3{0,-9.81,0})
    world_destroy(&w)
}

@(test)
stale_body_handles_are_rejected :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    a:=test_body(&w,Sphere{0.5},{0,5,0})
    testing.expect(t,a!={})
    testing.expect(t,body_valid(&w,a))
    testing.expect(t,!body_valid(&w,{}))
    body_destroy(&w,a)
    testing.expect(t,!body_valid(&w,a))
    b:=test_body(&w,Sphere{0.5},{1,5,0})
    testing.expect(t,b!=a)
    testing.expect(t,body_valid(&w,b))
    testing.expect_value(t,body_position(&w,a),Vec3{})
    testing.expect_value(t,body_position(&w,b),Vec3{1,5,0})
    stats:=world_stats(&w)
    testing.expect_value(t,stats.bodies,1)
    testing.expect_value(t,stats.shapes,1)
}

@(test)
exhausted_capacity_returns_null_handles_and_counts :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w,bodies=4))
    defer world_destroy(&w)
    for i in 0..<4 {testing.expect(t,test_body(&w,Sphere{0.5},{f32(i)*2,0,0})!={})}
    desc:=BODY_DESC_DEFAULT
    testing.expect_value(t,body_create(&w,desc),Body_Handle{})
    testing.expect_value(t,world_stats(&w).body_capacity_exhausted,1)
    bodies:[1]Shape_Handle
    first:=Body_Handle(1<<32)
    testing.expect(t,body_valid(&w,first))
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Sphere{0.1}
    testing.expect_value(t,shape_create(&w,first,shape),Shape_Handle{})
    testing.expect_value(t,world_stats(&w).shape_capacity_exhausted,1)
    testing.expect_value(t,body_shapes(&w,first,bodies[:]),1)
}

@(test)
invalid_shapes_are_refused :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    body:=body_create(&w,BODY_DESC_DEFAULT)
    shape:=SHAPE_DESC_DEFAULT
    testing.expect_value(t,shape_create(&w,body,shape),Shape_Handle{})
    shape.geometry=Sphere{-1}
    testing.expect_value(t,shape_create(&w,body,shape),Shape_Handle{})
    shape.geometry=Box{{1,0,1}}
    testing.expect_value(t,shape_create(&w,body,shape),Shape_Handle{})
    shape.geometry=Hull_Handle(77)
    testing.expect_value(t,shape_create(&w,body,shape),Shape_Handle{})
    shape.geometry=Sphere{1}
    testing.expect_value(t,shape_create(&w,{},shape),Shape_Handle{})
    testing.expect_value(t,world_stats(&w).shapes,0)
}

@(private)
Test_Inputs :: struct {body,kinematic,ground:Body_Handle,shape:Shape_Handle,character:Character_Handle,joint:Joint_Handle,hull:Hull_Handle}

@(private)
test_inputs_world :: proc(w:^World) -> (scene:Test_Inputs,ok:bool) {
    test_character_world(w) or_return
    scene.ground=test_ground(w)
    scene.body=test_body(w,Sphere{0.5},{0,2,0})
    scene.kinematic=test_body(w,Sphere{0.5},{3,2,0},.Kinematic)
    shapes:[1]Shape_Handle
    body_shapes(w,scene.body,shapes[:])
    scene.shape=shapes[0]
    scene.character=character_create(w,CHARACTER_DESC_DEFAULT,{6,0,0})
    scene.joint=joint_create(w,test_distance(scene.body,scene.kinematic,1,4))
    corners:=[8]Vec3{{-1,-1,-1},{1,-1,-1},{-1,1,-1},{1,1,-1},{-1,-1,1},{1,-1,1},{-1,1,1},{1,1,1}}
    counts,indices:=BOX_FACE_COUNTS,BOX_FACE_INDICES
    scene.hull=hull_create(w,{corners[:],counts[:],indices[:]}) or_return
    test_steps(w,2)
    return scene,scene.shape!={} && scene.character!={} && scene.joint!={}
}

TEST_INPUT_CALLS :: 36

// Calls one creation or setter of the solver with the values of v; finite: every value it was given is a number.
@(private)
test_input_call :: proc(w:^World,scene:Test_Inputs,call:int,v:[16]f32) -> (ok,finite_values:bool) {
    p,a:=Vec3{v[0],v[1],v[2]},Vec3{v[7],v[8],v[9]}
    q:=Quat(quaternion(x=v[3],y=v[4],z=v[5],w=v[6]))
    s,r:=v[10],v[11]
    m:Mat3
    for i in 0..<9 {m[i/3,i%3]=v[i]}
    pq:=finite(p) && finite(q)
    switch call {
    case 0:  return body_set_transform(w,scene.body,p,q),pq
    case 1:  return body_set_velocity(w,scene.body,p,a),finite(p,a)
    case 2:  return body_set_linear_velocity(w,scene.body,p),finite(p)
    case 3:  return body_set_angular_velocity(w,scene.body,a),finite(a)
    case 4:  return body_set_kinematic_target(w,scene.kinematic,p,q,s),pq && finite(s)
    case 5:  return body_apply_force(w,scene.body,p),finite(p)
    case 6:  return body_apply_force_at(w,scene.body,p,a),finite(p,a)
    case 7:  return body_apply_torque(w,scene.body,a),finite(a)
    case 8:  return body_apply_impulse(w,scene.body,p),finite(p)
    case 9:  return body_apply_impulse_at(w,scene.body,p,a),finite(p,a)
    case 10: return body_apply_angular_impulse(w,scene.body,a),finite(a)
    case 11: return body_set_mass_properties(w,scene.body,s,p,m),finite(s) && finite(p) && finite(m)
    case 12: return body_set_mass(w,scene.body,s),finite(s)
    case 13: return body_rest(w,scene.body,p,q),pq
    case 14: return body_set_sleep_threshold(w,scene.body,s),finite(s)
    case 15: return body_set_damping(w,scene.body,s,r),finite(s,r)
    case 16: return body_set_gravity_scale(w,scene.body,s),finite(s)
    case 17: return world_set_body_gravity(w,p,nil,nil),finite(p)
    case 18: return world_set_gravity(w,p),finite(p)
    case 19: return shape_set_rolling_resistance(w,scene.shape,s),finite(s)
    case 20: return shape_set_material(w,scene.shape,s,r),finite(s,r)
    case 21: return shape_set_surface(w,scene.shape,p,false,0),finite(p)
    case 22: return shape_set_drag(w,scene.shape,s),finite(s)
    case 23: return shape_set_density(w,scene.shape,s),finite(s)
    case 24:
        move:=Character_Move{ground={p,s},air={a,r},launch=p,yaw=s,float_height=r,pace=s,gravity_scale=r}
        return character_set_move(w,scene.character,move),finite(p,a) && finite(s,r)
    case 25:
        desc:=CHARACTER_DESC_DEFAULT
        desc.traction_force,desc.adhesion_force,desc.gravity_scale=s,r,s
        return character_set_desc(w,scene.character,desc),finite(s,r)
    case 26: return character_set_height(w,scene.character,s),finite(s)
    case 27: return character_set_position(w,scene.character,p),finite(p)
    case 28: return character_set_rotation(w,scene.character,q),finite(q)
    case 29: return character_launch(w,scene.character,p),finite(p)
    case 30: return joint_set_break(w,scene.joint,s,r),finite(s,r)
    case 31: return hull_set_mass(w,scene.hull,s,p,m),finite(s) && finite(p) && finite(m)
    case 32:
        desc:=BODY_DESC_DEFAULT
        desc.position,desc.rotation,desc.linear_velocity,desc.angular_velocity=p,q,a,p
        desc.linear_damping,desc.angular_damping,desc.gravity_scale,desc.sleep_threshold=s,r,s,r
        return body_create(w,desc)!={},pq && finite(a) && finite(s,r)
    case 33:
        desc:=SHAPE_DESC_DEFAULT
        desc.geometry,desc.transform,desc.surface_speed=Box{{1+abs(s),1,1}},{p,q},a
        desc.friction,desc.restitution,desc.density,desc.drag=r,r,s,r
        return shape_create(w,scene.body,desc)!={},pq && finite(a) && finite(s,r)
    case 34:
        desc:=CHARACTER_DESC_DEFAULT
        desc.push_force,desc.up_speed=abs(s),abs(r)
        return character_create(w,desc,p,q)!={},pq && finite(s,r)
    case 35:
        desc:=test_distance(scene.body,scene.ground,0,1)
        desc.frame_a,desc.break_force=Transform{p,q},abs(s)
        return joint_create(w,desc)!={},pq && finite(s)
    }
    return false,true
}

@(test)
values_that_are_not_finite_are_refused_and_change_nothing :: proc(t:^testing.T) {
    w:World
    defer world_destroy(&w)
    scene,made:=test_inputs_world(&w)
    if !testing.expect(t,made) {return}
    valid:=[16]f32{1,2,3,0,0,0,1,0.5,-0.5,0.25,0.5,0.25,4,5,6,7}
    for bad in ([3]f32{cmath.nan_f32(),cmath.inf_f32(1),cmath.inf_f32(-1)}) {
        for slot in 0..<len(valid) {
            v:=valid
            v[slot]=bad
            for call in 0..<TEST_INPUT_CALLS {
                before:=world_hash(&w)
                ok,finite_values:=test_input_call(&w,scene,call,v)
                if finite_values {continue}
                testing.expectf(t,!ok,"call %d took %v in value %d",call,bad,slot)
                testing.expectf(t,world_hash(&w)==before,"call %d changed the world with %v in value %d",call,bad,slot)
            }
        }
    }
    for &tree in w.trees {testing.expect(t,spatial.dynamic_tree_validate(&tree))}
}

@(test)
random_bytes_given_to_the_setters_never_break_the_world :: proc(t:^testing.T) {
    w:World
    defer world_destroy(&w)
    scene,made:=test_inputs_world(&w)
    if !testing.expect(t,made) {return}
    rng:=rand.create(0x9e37)
    gen:=rand.default_random_generator(&rng)
    for _ in 0..<4000 {
        v:[16]f32
        for &value in v {value=transmute(f32)rand.uint32(gen)}
        before:=world_hash(&w)
        ok,finite_values:=test_input_call(&w,scene,rand.int_max(TEST_INPUT_CALLS,gen),v)
        testing.expect(t,finite_values || !ok)
        if !ok {testing.expect(t,world_hash(&w)==before)}
    }
    for &tree in w.trees {testing.expect(t,spatial.dynamic_tree_validate(&tree))}
}

@(test)
mass_properties_come_from_the_shapes :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    body:=body_create(&w,BODY_DESC_DEFAULT)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{0.5,1,2}}
    shape.density=100
    shape_create(&w,body,shape)
    mass,center,inertia:=body_mass_properties(&w,body)
    expect_near(t,mass,800,1e-2)
    expect_near3(t,center,{0,0,0})
    expect_near(t,inertia[0,0],800.0/3*(1+4),1e-1)
    expect_near(t,inertia[1,1],800.0/3*(0.25+4),1e-1)
    expect_near(t,inertia[2,2],800.0/3*(0.25+1),1e-1)
    // A second box beside the first moves the center and adds the parallel axis term.
    shape.transform.p={2,0,0}
    second:=shape_create(&w,body,shape)
    mass,center,inertia=body_mass_properties(&w,body)
    expect_near(t,mass,1600,1e-2)
    expect_near3(t,center,{1,0,0})
    expect_near(t,inertia[1,1],2*(800.0/3*(0.25+4)+800),2e-1)
    expect_near3(t,body_center(&w,body),{1,0,0})
    shape_destroy(&w,second)
    mass,center,_=body_mass_properties(&w,body)
    expect_near(t,mass,800,1e-2)
    expect_near3(t,center,{0,0,0})
    sphere:=test_body(&w,Sphere{1},{10,0,0})
    mass,_,inertia=body_mass_properties(&w,sphere)
    expect_near(t,mass,1000*4.0/3*cmath.PI,1e-1)
    expect_near(t,inertia[0,0],0.4*mass,1e-1)
    body_set_mass_properties(&w,sphere,2,{0,0.5,0},mat3_diagonal({3,3,3}))
    mass,center,_=body_mass_properties(&w,sphere)
    expect_near(t,mass,2)
    expect_near3(t,body_center(&w,sphere),{10,0.5,0})
    body_reset_mass_properties(&w,sphere)
    expect_near(t,body_mass(&w,sphere),1000*4.0/3*cmath.PI,1e-1)
}

@(test)
a_body_falls_freely_under_gravity :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    body:=test_body(&w,Sphere{0.5},{0,100,0})
    static:=test_body(&w,Sphere{0.5},{5,100,0},.Static)
    weightless:=test_body(&w,Sphere{0.5},{10,100,0})
    body_set_gravity_scale(&w,weightless,0)
    test_steps(&w,60)
    expect_near(t,body_linear_velocity(&w,body).y,-9.81,1e-3)
    expect_near(t,body_position(&w,body).y,100-0.5*9.81,0.05)
    testing.expect_value(t,body_position(&w,static),Vec3{5,100,0})
    testing.expect_value(t,body_position(&w,weightless),Vec3{10,100,0})
    testing.expect_value(t,world_tick(&w),60)
}

@(test)
forces_and_impulses_change_velocity_by_the_mass :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    body:=test_body(&w,Sphere{0.5},{})
    mass:=body_mass(&w,body)
    body_apply_impulse(&w,body,{mass*2,0,0})
    expect_near3(t,body_linear_velocity(&w,body),{2,0,0})
    for _ in 0..<60 {
        body_apply_force(&w,body,{0,mass*3,0})
        world_step(&w,1.0/60)
    }
    expect_near3(t,body_linear_velocity(&w,body),{2,3,0},1e-3)
    // An off-center impulse also spins the body.
    body_set_velocity(&w,body,{},{})
    body_apply_impulse_at(&w,body,{0,0,mass},body_center(&w,body)+{0.5,0,0})
    expect_near3(t,body_linear_velocity(&w,body),{0,0,1})
    _,_,inertia:=body_mass_properties(&w,body)
    expect_near3(t,body_angular_velocity(&w,body),{0,-0.5*mass/inertia[1,1],0},1e-3)
    expect_near3(t,body_point_velocity(&w,body,body_center(&w,body)),{0,0,1})
}

@(test)
damping_slows_a_body_down :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    body:=test_body(&w,Sphere{0.5},{})
    body_set_damping(&w,body,1,1)
    body_set_velocity(&w,body,{10,0,0},{0,10,0})
    test_steps(&w,60)
    expect_near(t,body_linear_velocity(&w,body).x,10*cmath.exp_f32(-1),0.1)
    expect_near(t,body_angular_velocity(&w,body).y,10*cmath.exp_f32(-1),0.1)
}

@(test)
a_box_rests_on_the_ground_and_sleeps :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.6,0})
    test_steps(&w,120)
    testing.expect(t,!body_is_awake(&w,box))
    expect_near3(t,body_position(&w,box),{0,0.5,0},0.01)
    testing.expect_value(t,body_linear_velocity(&w,box),Vec3{})
    testing.expect_value(t,world_stats(&w).awake_bodies,0)
}

// A box made 15 cm into the ground is pushed out slowly, the velocity of the push taken away by the relaxation
// each substep; with its rotation and sideways motion locked nothing else moves it. The move of that push keeps
// it awake until it no longer overlaps.
@(test)
a_box_made_inside_the_ground_does_not_sleep_until_it_is_pushed_out :: proc(t:^testing.T) {
    w:World
    desc:=world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity=8,8,64
    desc.contact_speed=0.2
    testing.expect(t,world_init(&w,desc))
    defer world_destroy(&w)
    test_ground(&w)
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.35,0})
    body_set_locks(&w,box,{.Lock_Linear_X,.Lock_Linear_Z,.Lock_Angular_X,.Lock_Angular_Y,.Lock_Angular_Z})
    for step in 0..<600 {
        world_step(&w,1.0/60)
        if body_is_awake(&w,box) {continue}
        depth:=0.5-body_position(&w,box).y
        testing.expectf(t,depth<0.005,"it fell asleep %v m inside the ground at step %v",depth,step)
        return
    }
    testing.expect(t,false,"it never fell asleep")
}

@(private)
test_stack_rests :: proc(t:^testing.T,w:^World,bodies:[]Body_Handle,positions:[]Vec3,seconds:f32) {
    steps:=int(seconds*60)
    settled:=steps
    for step in 0..<steps {
        world_step(w,1.0/60)
        awake:=false
        for body in bodies {awake||=body_is_awake(w,body)}
        if !awake {settled=step;break}
    }
    testing.expectf(t,settled<steps,"the stack is still awake after %v s",seconds)
    for body,i in bodies {
        position:=body_position(w,body)
        expected:=positions[i]
        // Soft contacts give a little under load: a few millimeters per level below.
        sag:=0.01+0.006*expected.y
        ok:=abs(position.x-expected.x)<0.03 && abs(position.z-expected.z)<0.03 && position.y<expected.y+0.01 && position.y>expected.y-sag
        testing.expectf(t,ok,"body %v rests at %v, expected %v",i,position,expected)
        rotation:=body_rotation(w,body)
        testing.expectf(t,abs(rotation.w)>0.9999,"body %v tilted: %v",i,rotation)
    }
}

@(test)
a_stack_of_ten_boxes_rests_and_sleeps :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    bodies:[10]Body_Handle
    positions:[10]Vec3
    for i in 0..<10 {
        positions[i]={0,0.5+f32(i),0}
        bodies[i]=test_body(&w,Box{{0.5,0.5,0.5}},positions[i])
    }
    test_stack_rests(t,&w,bodies[:],positions[:],5)
}

@(test)
a_pyramid_of_boxes_rests_and_sleeps :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    bodies:[55]Body_Handle
    positions:[55]Vec3
    count:=0
    for row in 0..<10 {
        for column in 0..<10-row {
            positions[count]={f32(column)*1.05+f32(row)*0.525-4.7,0.5+f32(row),0}
            bodies[count]=test_body(&w,Box{{0.5,0.5,0.5}},positions[count])
            count+=1
        }
    }
    test_stack_rests(t,&w,bodies[:],positions[:],6)
}

@(test)
spheres_and_capsules_rest_on_the_ground :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    sphere:=test_body(&w,Sphere{0.5},{0,0.6,0})
    capsule:=test_body(&w,Capsule{0.3,0.5},{3,0.9,0})
    lying:=body_create(&w,{type=.Dynamic,position={6,0.4,0},rotation=q_axis_angle({0,0,1},cmath.PI/2),gravity_scale=1,sleep_threshold=0.05})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Capsule{0.3,0.5}
    shape_create(&w,lying,shape)
    test_steps(&w,240)
    expect_near3(t,body_position(&w,sphere),{0,0.5,0},0.01)
    expect_near(t,body_position(&w,capsule).y,0.8,0.01)
    expect_near3(t,body_position(&w,lying),{6,0.3,0},0.02)
    testing.expect(t,!body_is_awake(&w,sphere))
    testing.expect(t,!body_is_awake(&w,lying))
}

@(test)
friction_holds_a_box_on_a_slope_until_it_is_too_slippery :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    angle:f32=0.35
    ground:=body_create(&w,{type=.Static,rotation=q_axis_angle({0,0,1},angle)})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{20,0.5,20}}
    shape.friction=1
    shape_create(&w,ground,shape)
    up:=q_rotate(q_axis_angle({0,0,1},angle),Vec3{0,1,0})
    boxes:[2]Body_Handle
    for friction,i in ([2]f32{0.6,0.01}) {
        desc:=BODY_DESC_DEFAULT
        desc.position=up*1.005+{0,0,f32(i)*5}
        desc.rotation=q_axis_angle({0,0,1},angle)
        boxes[i]=body_create(&w,desc)
        shape.geometry=Box{{0.5,0.5,0.5}}
        shape.friction=friction
        shape_create(&w,boxes[i],shape)
    }
    start:=body_position(&w,boxes[1])
    test_steps(&w,90)
    testing.expect(t,length(body_position(&w,boxes[0])-(up*1.005))<0.05)
    // sqrt(1*0.01)=0.1 is less than tan(0.35)=0.365: it slides down with a=g(sin-mu cos).
    slid:=length(body_position(&w,boxes[1])-start)
    expected:=0.5*9.81*(cmath.sin(angle)-0.1*cmath.cos(angle))*1.5*1.5
    testing.expectf(t,abs(slid-expected)<0.15*expected,"slid %v, expected %v",slid,expected)
}

@(test)
restitution_bounces_a_ball :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    bouncy:=test_body(&w,Sphere{0.5},{0,3,0},restitution=0.8)
    dull:=test_body(&w,Sphere{0.5},{3,3,0})
    peak:[2]f32
    hit:[2]bool
    for _ in 0..<150 {
        world_step(&w,1.0/60)
        for body,i in ([2]Body_Handle{bouncy,dull}) {
            y:=body_position(&w,body).y
            if y<0.6 {hit[i]=true}
            if hit[i] && body_linear_velocity(&w,body).y>0 {peak[i]=max(peak[i],y)}
        }
    }
    // Dropped 2.5 m: a restitution of 0.8 returns 0.64 of the height.
    testing.expectf(t,abs(peak[0]-(0.5+0.64*2.5))<0.25,"bounced to %v",peak[0])
    testing.expect(t,peak[1]<0.52)
}

@(test)
filters_decide_which_shapes_collide :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    ghost:=body_create(&w,BODY_DESC_DEFAULT)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Sphere{0.5}
    shape.filter={layers=2,block=2}
    ghost_shape:=shape_create(&w,ghost,shape)
    body_set_transform(&w,ghost,{0,0.6,0},QUAT_IDENTITY)
    solid:=test_body(&w,Sphere{0.5},{3,0.6,0})
    test_steps(&w,60)
    testing.expect(t,body_position(&w,ghost).y<-1)
    expect_near(t,body_position(&w,solid).y,0.5,0.01)
    testing.expect_value(t,shape_filter(&w,ghost_shape),Filter{layers=2,block=2})
    wall:=Filter{layers=1,block=2,overlap=4}
    testing.expect_value(t,filter_response(wall,{layers=2,block=1}),Response.Block)
    testing.expect_value(t,filter_response(wall,{layers=4,block=1}),Response.Overlap)
    testing.expect_value(t,filter_response(wall,{layers=4,overlap=1}),Response.Overlap)
    testing.expect_value(t,filter_response(wall,{layers=8,block=1}),Response.Ignore)
    testing.expect_value(t,filter_response(wall,{layers=2}),Response.Ignore)
    testing.expect_value(t,filter_response({layers=1,block=1,group=9},{layers=1,block=1,group=9}),Response.Ignore)
    testing.expect_value(t,filter_response({layers=1,block=1,group=9},{layers=1,block=1,group=8}),Response.Block)
}

@(test)
a_wall_blocks_one_layer_and_lets_another_through_with_events :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    wall_body:=body_create(&w,{type=.Static})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{0.25,2,2}}
    shape.filter={layers=1,block=2,overlap=4}
    wall:=shape_create(&w,wall_body,shape)
    movers:[2]Body_Handle
    for layer,i in ([2]Collision_Layers{2,4}) {
        movers[i]=body_create(&w,{type=.Dynamic,position={-2,f32(i)*2-1,0}})
        shape=SHAPE_DESC_DEFAULT
        shape.geometry=Sphere{0.25}
        shape.filter={layers=layer,block=0xffffffff}
        shape_create(&w,movers[i],shape)
        body_set_velocity(&w,movers[i],{2,0,0},{})
        body_set_sleep_disabled(&w,movers[i],true)
    }
    entered,left:=0,0
    for _ in 0..<180 {
        world_step(&w,1.0/60)
        events:=world_events(&w)
        for event in events.overlap_begin {
            testing.expect(t,event.shape==wall && event.other_body==movers[1] || event.other==wall && event.body==movers[1])
            entered+=1
        }
        left+=len(events.overlap_end)
    }
    testing.expect(t,body_position(&w,movers[0]).x<-0.4)
    testing.expect(t,body_position(&w,movers[1]).x>2)
    testing.expect_value(t,entered,2)
    testing.expect_value(t,left,2)
}

@(test)
contact_events_report_begin_and_end :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ground:=test_ground(&w)
    ball:=test_body(&w,Sphere{0.5},{0,1.5,0})
    began,ended:=0,0
    impulse:f32
    for _ in 0..<60 {
        world_step(&w,1.0/60)
        events:=world_events(&w)
        for event in events.contact_begin {
            began+=1
            impulse=event.impulse
            testing.expect(t,(event.body_a==ground && event.body_b==ball) || (event.body_a==ball && event.body_b==ground))
            expect_near(t,abs(event.normal.y),1,1e-3)
            expect_near(t,event.point.y,0,0.05)
        }
        ended+=len(events.contact_end)
    }
    testing.expect_value(t,began,1)
    testing.expect_value(t,ended,0)
    // The ball of 523 kg arrives at about 4.4 m/s: the impulse that stops it is near m v.
    testing.expectf(t,impulse>0.5*523*4.4 && impulse<1.5*523*4.4,"impulse %v",impulse)
    body_set_transform(&w,ball,{0,10,0},QUAT_IDENTITY)
    world_step(&w,1.0/60)
    testing.expect_value(t,len(world_events(&w).contact_end),1)
    world_step(&w,1.0/60)
    testing.expect_value(t,len(world_events(&w).contact_end),0)
}

@(test)
triggers_report_overlaps_without_pushing :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    trigger:=body_create(&w,{type=.Static})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{1,1,1}}
    shape.filter={layers=1,overlap=0xffffffff}
    sensor:=shape_create(&w,trigger,shape)
    ball:=test_body(&w,Sphere{0.25},{-3,0,0})
    body_set_velocity(&w,ball,{2,0,0},{})
    body_set_sleep_disabled(&w,ball,true)
    entered,left:=-1,-1
    for step in 0..<240 {
        world_step(&w,1.0/60)
        events:=world_events(&w)
        for event in events.overlap_begin {
            if event.shape!=sensor {continue}
            testing.expect_value(t,event.other_body,ball)
            entered=step
        }
        if len(events.overlap_end)>0 {left=step}
        testing.expect_value(t,len(events.contact_begin),0)
    }
    expect_near3(t,body_linear_velocity(&w,ball),{2,0,0})
    // Enters when x reaches -1.25 and leaves past 1.25, at 2 m/s.
    testing.expectf(t,abs(entered-52)<=2,"entered at step %v",entered)
    testing.expectf(t,abs(left-127)<=2,"left at step %v",left)
}

@(test)
a_kinematic_platform_carries_a_box :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    platform:=test_body(&w,Box{{2,0.25,2}},{0,0,0},.Kinematic)
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.76,0})
    test_steps(&w,60)
    for step in 0..<120 {
        target:=Vec3{f32(step+1)*(1.0/60),0,0}
        body_set_kinematic_target(&w,platform,target,QUAT_IDENTITY,1.0/60)
        world_step(&w,1.0/60)
    }
    expect_near3(t,body_position(&w,platform),{2,0,0},1e-3)
    // Friction needs v/(mu g) seconds to bring the box up to speed: it trails by v*v/(2 mu g).
    expect_near3(t,body_position(&w,box),{2-1/(2*0.6*9.81),0.75,0},0.03)
    testing.expect(t,body_is_awake(&w,box))
    body_set_velocity(&w,platform,{},{})
    test_steps(&w,120)
    testing.expect(t,!body_is_awake(&w,box))
    testing.expect(t,!body_is_awake(&w,platform))
}

@(test)
locked_axes_do_not_move :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    desc:=BODY_DESC_DEFAULT
    desc.position={0,3,0}
    desc.locks={.Lock_Linear_Z,.Lock_Angular_X,.Lock_Angular_Y}
    body:=body_create(&w,desc)
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Box{{0.5,0.5,0.5}}
    shape_create(&w,body,shape)
    testing.expect_value(t,body_locks(&w,body),desc.locks)
    body_set_sleep_disabled(&w,body,true)
    for _ in 0..<180 {
        body_apply_force_at(&w,body,{9000,0,9000},body_center(&w,body)+{0.3,0.4,0.2})
        world_step(&w,1.0/60)
        expect_near(t,body_position(&w,body).z,0,1e-4)
        rotation:=body_rotation(&w,body)
        expect_near(t,rotation.x,0,1e-4)
        expect_near(t,rotation.y,0,1e-4)
    }
    testing.expect(t,body_position(&w,body).x>0.5)
}

@(test)
a_sleeping_stack_wakes_when_hit :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    lower:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5,0})
    upper:=test_body(&w,Box{{0.5,0.5,0.5}},{0,1.5,0})
    far:=test_body(&w,Box{{0.5,0.5,0.5}},{20,0.5,0})
    slept:=0
    for _ in 0..<120 {
        world_step(&w,1.0/60)
        slept+=len(world_events(&w).sleep)
    }
    testing.expect_value(t,slept,3)
    testing.expect(t,!body_is_awake(&w,lower) && !body_is_awake(&w,upper) && !body_is_awake(&w,far))
    ball:=test_body(&w,Sphere{0.3},{-3,0.5,0})
    body_set_velocity(&w,ball,{15,0,0},{})
    woke:=0
    for _ in 0..<30 {
        world_step(&w,1.0/60)
        woke+=len(world_events(&w).wake)
    }
    testing.expect_value(t,woke,2)
    testing.expect(t,body_is_awake(&w,lower) || body_position(&w,lower).x>0.01)
    testing.expect(t,!body_is_awake(&w,far))
    testing.expect(t,body_position(&w,upper).x!=0 || body_position(&w,upper).y!=1.5)
    // Putting a body to sleep by hand takes its island with it.
    test_steps(&w,10)
    body_set_awake(&w,far,true)
    testing.expect(t,body_is_awake(&w,far))
    body_set_awake(&w,far,false)
    testing.expect(t,!body_is_awake(&w,far))
}

@(test)
destroying_a_support_wakes_what_rested_on_it :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    lower:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5,0})
    upper:=test_body(&w,Box{{0.5,0.5,0.5}},{0,1.5,0})
    test_steps(&w,120)
    testing.expect(t,!body_is_awake(&w,upper))
    body_destroy(&w,lower)
    testing.expect(t,body_is_awake(&w,upper))
    test_steps(&w,120)
    expect_near3(t,body_position(&w,upper),{0,0.5,0},0.02)
    testing.expect_value(t,world_stats(&w).contacts,1)
}

@(test)
changing_the_type_of_a_body_takes_effect :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    shelf:=test_body(&w,Box{{1,0.1,1}},{0,3,0},.Static)
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{0,3.6,0})
    test_steps(&w,90)
    expect_near(t,body_position(&w,box).y,3.6,0.02)
    body_set_type(&w,shelf,.Dynamic)
    testing.expect_value(t,body_type(&w,shelf),Body_Type.Dynamic)
    testing.expect(t,body_mass(&w,shelf)>0)
    test_steps(&w,180)
    expect_near(t,body_position(&w,shelf).y,0.1,0.02)
    expect_near(t,body_position(&w,box).y,0.7,0.03)
    body_set_type(&w,shelf,.Static)
    testing.expect_value(t,body_mass(&w,shelf),0)
}

@(test)
a_body_with_several_shapes_collides_with_each_of_them :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    // A table: a top and four legs, each with its own local transform.
    table:=body_create(&w,{type=.Dynamic,position={0,1.2,0},rotation=QUAT_IDENTITY,gravity_scale=1,sleep_threshold=0.05})
    desc:=SHAPE_DESC_DEFAULT
    desc.geometry=Box{{1,0.1,0.6}}
    desc.transform.p={0,0.5,0}
    shape_create(&w,table,desc)
    for i in 0..<4 {
        desc.geometry=Capsule{0.08,0.4}
        desc.transform.p={i&1!=0?f32(0.8):-0.8,-0.08,i&2!=0?f32(0.4):-0.4}
        shape_create(&w,table,desc)
    }
    shapes:[8]Shape_Handle
    testing.expect_value(t,body_shapes(&w,table,shapes[:]),5)
    // A dumbbell lying across the table top, and a ball that lands between its weights.
    bar:=body_create(&w,{type=.Dynamic,position={0,2.5,0},rotation=q_axis_angle({0,1,0},0.5),gravity_scale=1,sleep_threshold=0.05})
    desc.geometry=Sphere{0.25}
    desc.transform.p={-0.5,0,0}
    shape_create(&w,bar,desc)
    desc.transform.p={0.5,0,0}
    shape_create(&w,bar,desc)
    desc.geometry=Box{{0.5,0.05,0.05}}
    desc.transform={{0,0,0},q_axis_angle({1,0,0},0.3)}
    shape_create(&w,bar,desc)
    test_steps(&w,300)
    // The legs reach 0.56 below the origin of the table; the top is 0.6 above it.
    expect_near3(t,body_position(&w,table),{0,0.56,0},0.03)
    testing.expect(t,abs(body_rotation(&w,table).w)>0.9999)
    expect_near(t,body_position(&w,bar).y,0.56+0.6+0.25,0.03)
    testing.expect(t,!body_is_awake(&w,table) && !body_is_awake(&w,bar))
    hit,ok:=ray_cast_closest(&w,{0.8,3,0.4},{0,-10,0})
    testing.expect(t,ok && hit.body==table)
    expect_near(t,hit.point.y,0.56+0.6,0.03)
    // Removing a shape updates the mass and frees its contacts.
    mass:=body_mass(&w,table)
    shape_destroy(&w,shapes[0])
    testing.expect(t,body_mass(&w,table)<mass)
    testing.expect(t,body_is_awake(&w,table))
    testing.expect_value(t,body_shapes(&w,table,shapes[:]),4)
}

@(test)
a_body_put_to_rest_sleeps_alone_without_waking_what_it_touches :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    lower:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5,0})
    upper:=test_body(&w,Box{{0.5,0.5,0.5}},{0,1.5,0})
    flying:=test_body(&w,Box{{0.5,0.5,0.5}},{6,4,0})
    test_steps(&w,180)
    testing.expect(t,!body_is_awake(&w,lower) && !body_is_awake(&w,upper))
    // An awake body is stopped where it is put; one of a sleeping pair moves without waking the other.
    body_set_velocity(&w,flying,{3,0,0},{0,2,0})
    body_rest(&w,flying,{6,0.5,0},QUAT_IDENTITY)
    body_rest(&w,upper,{0.02,1.5,0},QUAT_IDENTITY)
    testing.expect(t,!body_is_awake(&w,flying) && !body_is_awake(&w,upper) && !body_is_awake(&w,lower))
    testing.expect_value(t,body_linear_velocity(&w,flying),Vec3{})
    testing.expect_value(t,body_angular_velocity(&w,flying),Vec3{})
    test_steps(&w,30)
    testing.expect_value(t,body_position(&w,flying),Vec3{6,0.5,0})
    testing.expect_value(t,body_position(&w,upper),Vec3{0.02,1.5,0})
    testing.expect(t,!body_is_awake(&w,flying) && !body_is_awake(&w,upper) && !body_is_awake(&w,lower))
    // Each sleeps in an island of its own: waking one leaves the other.
    body_set_awake(&w,upper,true)
    testing.expect(t,body_is_awake(&w,upper) && !body_is_awake(&w,lower))
    // What is not dynamic is moved and stopped.
    platform:=test_body(&w,Box{{1,0.1,1}},{-6,1,0},.Kinematic)
    body_set_velocity(&w,platform,{1,0,0},{})
    body_rest(&w,platform,{-6,2,0},QUAT_IDENTITY)
    testing.expect_value(t,body_position(&w,platform),Vec3{-6,2,0})
    testing.expect_value(t,body_linear_velocity(&w,platform),Vec3{})
    body_rest(&w,{},{0,0,0},QUAT_IDENTITY)
}

@(test)
bodies_group_joins_what_a_push_could_reach :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    ground:=test_ground(&w)
    // A stack of two, a box beside it that touches nothing but the ground, and a pusher against the stack.
    lower:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5,0})
    upper:=test_body(&w,Box{{0.5,0.5,0.5}},{0,1.5,0})
    apart:=test_body(&w,Box{{0.5,0.5,0.5}},{4,0.5,0})
    pusher:=test_body(&w,Box{{0.5,0.5,0.5}},{-0.99,0.5,0},.Kinematic)
    test_steps(&w,10)
    bodies_group(&w)
    group:=body_group(&w,pusher)
    testing.expect(t,group!=0 && body_group(&w,lower)==group && body_group(&w,upper)==group)
    // The ground joins nothing.
    testing.expect(t,body_group(&w,apart)!=0 && body_group(&w,apart)!=group)
    testing.expect_value(t,body_group(&w,ground),0)
    testing.expect_value(t,body_group(&w,{}),0)
    // What stops touching leaves the group in the next grouping.
    body_set_transform(&w,upper,{8,0.5,0},QUAT_IDENTITY)
    test_steps(&w,1)
    bodies_group(&w)
    testing.expect(t,body_group(&w,upper)!=body_group(&w,pusher) && body_group(&w,lower)==body_group(&w,pusher))
    // What sleeps is in no group.
    body_set_awake(&w,apart,false)
    test_steps(&w,1)
    bodies_group(&w)
    testing.expect_value(t,body_group(&w,apart),0)
}

@(test)
a_stack_of_ten_boxes_sags_less_than_three_centimeters :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    bodies:[10]Body_Handle
    for i in 0..<10 {bodies[i]=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.5+f32(i),0})}
    for _ in 0..<300 {world_step(&w,1.0/60)}
    // Soft contacts give under load, more where more weight rests: about a millimeter on the ground.
    testing.expectf(t,body_position(&w,bodies[0]).y>0.5-0.001,"the bottom box sank to %v",body_position(&w,bodies[0]).y)
    testing.expectf(t,body_position(&w,bodies[9]).y>9.5-0.03,"the top box sank to %v",body_position(&w,bodies[9]).y)
}

@(test)
a_box_pushed_out_of_a_deep_overlap_stops_where_it_rests :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    box:=test_body(&w,Box{{0.5,0.5,0.5}},{0,0.2,0})
    highest,rising:f32
    for _ in 0..<180 {
        world_step(&w,1.0/60)
        p:=body_position(&w,box)
        highest=max(highest,p.y)
        if p.y>0.49 {rising=max(rising,body_linear_velocity(&w,box).y)}
    }
    testing.expectf(t,highest<0.501,"it popped up to %v",highest)
    testing.expectf(t,rising<0.01,"it left the overlap at %v m/s",rising)
}

@(test)
rolling_resistance_stops_a_rolling_ball_and_holds_it_on_a_gentle_slope :: proc(t:^testing.T) {
    ball :: proc(w:^World,position:Vec3,rolling:f32,speed:f32) -> Body_Handle {
        desc:=BODY_DESC_DEFAULT
        desc.position=position
        desc.linear_velocity={speed,0,0}
        desc.angular_velocity={0,0,-speed/0.5}
        body:=body_create(w,desc)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Sphere{0.5}
        shape.rolling_resistance=rolling
        shape_create(w,body,shape)
        return body
    }
    {
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        test_ground(&w)
        free:=ball(&w,{0,0.5,0},0,3)
        braked:=ball(&w,{0,0.5,5},0.1,3)
        for _ in 0..<240 {world_step(&w,1.0/60)}
        testing.expectf(t,body_linear_velocity(&w,free).x>2.9,"without resistance it keeps rolling: %v",body_linear_velocity(&w,free))
        // 0.1 m on a solid ball of 0.5 m decelerates it at 0.1*g/0.5/1.4, about 1.4 m/s2: it stops after 3.2 m.
        testing.expectf(t,length(body_linear_velocity(&w,braked))<0.05,"it still rolls at %v",body_linear_velocity(&w,braked))
        testing.expectf(t,abs(body_position(&w,braked).x-3.2)<0.3,"it stopped at %v",body_position(&w,braked).x)
    }
    {
        // A slope of 3 degrees needs 0.5*tan(3) = 0.026 m to hold the ball.
        w:World
        testing.expect(t,test_world(&w))
        defer world_destroy(&w)
        slope:=q_axis_angle({0,0,1},3*PI/180)
        ground:=BODY_DESC_DEFAULT
        ground.type=.Static
        ground.rotation=slope
        body:=body_create(&w,ground)
        shape:=SHAPE_DESC_DEFAULT
        shape.geometry=Box{{20,0.5,20}}
        shape_create(&w,body,shape)
        up:=q_rotate(slope,{0,1,0})
        held:=ball(&w,up*1.001,0.05,0)
        loose:=ball(&w,up*1.001+q_rotate(slope,{0,0,5}),0,0)
        start_held,start_loose:=body_position(&w,held),body_position(&w,loose)
        for _ in 0..<180 {world_step(&w,1.0/60)}
        testing.expectf(t,length(body_position(&w,held)-start_held)<0.02,"the held ball moved %v",length(body_position(&w,held)-start_held))
        testing.expectf(t,length(body_position(&w,loose)-start_loose)>1,"the loose ball moved %v",length(body_position(&w,loose)-start_loose))
    }
}
