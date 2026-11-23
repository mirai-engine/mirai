package physics_editor

import "core:math/linalg"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"

@(private)
@(test_world)
Physics_Inspect_Test_World :: struct {
    using world:Test_World,
    physics:phys.Physics_State,
    joints:core.Table(phys.Joint),
    joint_states:core.Table(phys.Joint_State),
}

// A crate resting on the ground, a lamp hanging from it by a joint and a
// joint of the crate that broke.
@(private)
Physics_Inspect_Fixture :: struct {
    world:Physics_Inspect_Test_World,
    ground,crate,lamp,hook,snapped,ghost:core.Entity,
    lamp_mass:f32,
}

@(private)
physics_inspect_fixture :: proc(t:^testing.T,f:^Physics_Inspect_Fixture) -> bool {
    if !test_world_init(t,&f.world) {return false}
    w:=&f.world
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=16,16,64,4
    if !testing.expect(t,sim.world_init(&w.physics.world,desc)) {return false}
    w.physics.ready=true
    world:=&w.physics.world
    for e in ([]^core.Entity{&f.ground,&f.crate,&f.lamp,&f.hook,&f.snapped,&f.ghost}) {e^=core.create(&w.entities)}
    body :: proc(world:^sim.World,e:core.Entity,type:sim.Body_Type,position:[3]f32,geometry:sim.Geometry) -> sim.Body_Handle {
        desc:=sim.BODY_DESC_DEFAULT
        desc.type,desc.position,desc.user_data,desc.sleep_disabled=type,position,u64(e),true
        made:=sim.body_create(world,desc)
        sim.shape_create(world,made,{geometry=geometry,density=1000,friction=0.6,filter={layers=1,block=0xffffffff}})
        return made
    }
    ground:=body(world,f.ground,.Static,{0,-0.5,0},sim.Box{{5,0.5,5}})
    body(world,f.crate,.Dynamic,{0,0.5,0},sim.Box{{0.5,0.5,0.5}})
    lamp:=body(world,f.lamp,.Dynamic,{3,2,0},sim.Sphere{0.25})
    f.lamp_mass=sim.body_mass(world,lamp)
    locked:=[3]sim.Joint_Axis{{motion=.Locked},{motion=.Locked},{motion=.Locked}}
    hook:=sim.joint_create(world,{body_a=ground,body_b=lamp,frame_a={{3,3,0},1},frame_b={{0,0.5,0},1},break_force=1e6,user_data=u64(f.hook),linear=locked})
    if !testing.expect(t,sim.joint_valid(world,hook)) {return false}
    core.add(&w.joints,f.snapped,phys.Joint{a=f.crate,break_force=5})
    core.add(&w.joint_states,f.snapped,phys.Joint_State{broken=true})
    test_world_settle(w)
    for _ in 0..<60 {sim.world_step(world,1.0/60)}
    return true
}

@(private)
physics_inspect_call :: proc(f:^Physics_Inspect_Fixture,e:core.Entity,result:^Physics_Inspect_Result) -> api.Call {
    method:=new(api.Method,context.temp_allocator)
    method.result_id=Physics_Inspect_Result
    call:=api.Call{allocator=context.temp_allocator,method=method,result=result}
    physics_inspect(&call,test_world_ref(&f.world),e,"it")
    return call
}

// physics.inspect reads what the simulation holds of an entity: the shapes
// it touches with the normal toward the other, depth and impulse, whether its
// body is awake and its mass, and its joints with their load against what
// breaks them, those that broke too; it fails for what has no body.
@(test)
physics_inspect_reads_contacts_awake_and_mass_and_the_load_of_joints :: proc(t:^testing.T) {
    f:=new(Physics_Inspect_Fixture);defer free(f)
    if !physics_inspect_fixture(t,f) {return}
    defer test_world_destroy(&f.world)
    r:Physics_Inspect_Result
    call:=physics_inspect_call(f,f.crate,&r)
    if !testing.expect(t,!call.failed,call.error.message) {return}
    testing.expect(t,r.body && r.awake,"the crate has a body that is awake")
    testing.expectf(t,abs(r.mass-1000)<1 && abs(r.inv_mass-0.001)<1e-5,"mass %f and inverse %f",r.mass,r.inv_mass)
    if !testing.expect_value(t,len(r.contacts),1) {return}
    contact:=r.contacts[0]
    testing.expect(t,contact.other==f.ground && !contact.sensor,"it touches the ground")
    testing.expectf(t,linalg.length(contact.normal-[3]f32{0,-1,0})<1e-3,"the normal goes from the crate toward the ground: %v",contact.normal)
    testing.expectf(t,len(contact.points)==4,"the crate rests on four points: %d",len(contact.points))
    held:f32
    for point in contact.points {
        testing.expectf(t,point.separation<0.01 && point.separation>-0.05 && point.impulse>0,"point %v",point)
        held+=point.impulse
    }
    // Over a step the points carry the weight of the crate.
    testing.expectf(t,abs(held*60-1000*9.81)<0.1*1000*9.81,"impulses %f N s a step",held)
    if !testing.expect_value(t,len(r.joints),1) {return}
    snapped:=r.joints[0]
    testing.expect(t,snapped.joint==f.snapped && snapped.broken && snapped.a==f.crate && snapped.break_force==5,"the joint of the crate broke")
    // The ground sees the crate from the other side, and does not move.
    call=physics_inspect_call(f,f.ground,&r)
    testing.expect(t,!call.failed && r.body && !r.awake && r.inv_mass==0,"the ground is static")
    found:=false
    for c in r.contacts {
        if c.other==f.crate {found=true;testing.expectf(t,linalg.length(c.normal-[3]f32{0,1,0})<1e-3,"the normal goes from the ground toward the crate: %v",c.normal)}
    }
    testing.expect(t,found,"the ground touches the crate")
    // The lamp hangs: its joint carries its weight, far from what breaks it.
    call=physics_inspect_call(f,f.lamp,&r)
    if !testing.expect(t,!call.failed && len(r.joints)==1,call.error.message) {return}
    hook:=r.joints[0]
    testing.expect(t,hook.joint==f.hook && hook.a==f.ground && hook.b==f.lamp && !hook.broken,"the hook joins the ground and the lamp")
    weight:=f.lamp_mass*9.81
    testing.expectf(t,abs(hook.force-weight)<0.1*weight && hook.break_force==1e6,"force %f N for a weight of %f N",hook.force,weight)
    testing.expectf(t,hook.separation<0.01 && linalg.length(hook.anchor_a-[3]f32{3,2.5,0})<0.01,"anchors %v %v",hook.anchor_a,hook.anchor_b)
    // Without a body, or without a simulation, it says what to do.
    call=physics_inspect_call(f,f.ghost,&r)
    testing.expect(t,call.failed && call.error.code==api.INVALID_PARAMS && strings.contains(call.error.message,"Rigid_Body"),call.error.message)
    f.world.physics.ready=false
    call=physics_inspect_call(f,f.crate,&r)
    testing.expect(t,call.failed && strings.contains(call.error.message,"Play or Simulate"),call.error.message)
    f.world.physics.ready=true
}

// The overlays contacts and joints of capture draw the points where bodies
// touch and the joints, under the names debug gives them.
@(test)
capture_overlays_draw_contacts_and_joints_under_their_names :: proc(t:^testing.T) {
    f:=new(Physics_Inspect_Fixture);defer free(f)
    if !physics_inspect_fixture(t,f) {return}
    defer test_world_destroy(&f.world)
    w:=test_world_ref(&f.world)
    cases:=[]struct{name:string,draw:proc(s:^editor.Session,w:core.World_Ref,lines:^erender.Debug_Lines),color:[4]f32,lines:int}{
        // Four points of the crate on the ground: a cross of three lines and the normal each.
        {"contacts",CONTACTS_CAPTURE_DEFAULT.provider.draw,CONTACTS_CAPTURE_COLOR,4*4},
        // From the center of each body to its anchor and between the anchors.
        {"joints",JOINTS_CAPTURE_DEFAULT.provider.draw,COLLISION_COLORS[.Joint],3},
    }
    testing.expect_value(t,CONTACTS_CAPTURE_DEFAULT.provider.name,"contacts")
    testing.expect_value(t,JOINTS_CAPTURE_DEFAULT.provider.name,"joints")
    for c in cases {
        storage:[256]erender.Debug_Vertex
        lines:=erender.debug_lines_make(storage[:],depth_test=false)
        c.draw(nil,w,&lines)
        drawn:=0
        for vertex in storage[:lines.count] {if vertex.color==mm.rgba8_pack(c.color) {drawn+=1}}
        testing.expectf(t,drawn==2*c.lines,"%s: %d vertices",c.name,drawn)
    }
}
