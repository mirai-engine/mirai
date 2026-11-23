package physics_editor

import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"

Physics_Inspect_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=By its name or a path Parent/Child or its id; in Play or Simulate also its handle as scene.inspect with world Game gives it"`,
}

// What the simulation holds of an entity that its components do not say:
// whether its body sleeps and its mass, what it touches after the last step
// and the joints on its body with the load they carried.
Physics_Inspect_Result :: struct {
    entity:core.Entity,
    body:bool `mirai:"label=It has a body of its own; false: a Collider without a Rigid_Body, part of the static body of the world"`,
    awake:bool `mirai:"optional,label=Its body moves in the steps; false: it sleeps, or does not move (static)"`,
    mass:f32 `mirai:"optional,unit=kg"`,
    inv_mass:f32 `mirai:"optional,unit=1/kg,label=0: nothing pushes it (static, kinematic or held)"`,
    contacts:[]Physics_Inspect_Contact `mirai:"label=The shapes it touches after the last step, one per manifold"`,
    joints:[]Physics_Inspect_Joint `mirai:"label=The joints on its body, and those of its Joint components that broke"`,
}

Physics_Inspect_Contact :: struct {
    other:core.Entity `mirai:"label=The entity of the body it touches, or of the collider on the static body of the world"`,
    sensor:bool `mirai:"optional,label=The pair only overlaps: no points and no push"`,
    normal:[3]f32 `mirai:"optional,label=Unit, from this entity toward other"`,
    points:[]Physics_Inspect_Point `mirai:"optional"`,
}

Physics_Inspect_Point :: struct {
    point:[3]f32 `mirai:"unit=m,label=Midway between the surfaces"`,
    separation:f32 `mirai:"unit=m,label=Below 0: how deep the shapes overlap"`,
    impulse:f32 `mirai:"unit=N s,label=Normal impulse of the last step"`,
}

Physics_Inspect_Joint :: struct {
    joint:core.Entity `mirai:"label=The entity of its Joint"`,
    a,b:core.Entity `mirai:"label=The entities of its bodies; none for the static body of the world"`,
    broken:bool `mirai:"optional,label=It broke: the simulation has it no more until the game repairs it (Joint_State.broken)"`,
    anchor_a,anchor_b:[3]f32 `mirai:"optional,unit=m,label=Where its frame is on each body, in the world"`,
    separation:f32 `mirai:"optional,unit=m,label=Between the two anchors: how far the solver is from what it locks"`,
    force:f32 `mirai:"optional,unit=N,label=What it applied in the last step"`,
    torque:f32 `mirai:"optional,unit=N m,label=What it applied in the last step"`,
    break_force:f32 `mirai:"optional,unit=N,label=Above it the joint breaks; 0: never"`,
    break_torque:f32 `mirai:"optional,unit=N m,label=Above it the joint breaks; 0: never"`,
}

@(private)
api_inspect_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="physics.inspect",summary="What the simulation holds of an entity in Play or Simulate that scene.inspect does not read: whether its body is awake or asleep, its mass, the shapes it touches after the last step (the other entity, the points, the normal, the separation or depth and the impulse of each, sensors) and the joints on its body (their anchors in the world, how far apart they are, the force and torque of the last step against those that break them, and those that broke).",params=type_info_of(Physics_Inspect_Params),result=type_info_of(Physics_Inspect_Result),flags={.Read_Only},run=api_inspect})
}

@(private)
api_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Physics_Inspect_Params)
    w:=editor.shown_world(s)
    e,named:=editor.api_call_entity(call,w,p.entity[:],game=s.mode!=.Edit)
    if !named {return}
    physics_inspect(call,w,e,base.text_get(p.entity[:]))
}

// Fills the result of physics.inspect for e of w; fails the call when the
// simulation is not running or holds nothing of e.
@(private)
physics_inspect :: proc(call:^api.Call,w:core.World_Ref,e:core.Entity,name:string) {
    state:=core.world_storage_of(w,phys.Physics_State)
    if state==nil || !state.ready {
        api.call_fail(call,api.INVALID_PARAMS,"The simulation of the shown world is not running: physics.inspect reads it in Play or Simulate, after a step (play.step)")
        return
    }
    world:=&state.world
    // The body that follows e: the one its link names, else one whose user data is e.
    body:=phys.body_of(core.ref(state),e)
    if !sim.body_valid(world,body) {body=body_following(world,e)}
    own:=sim.body_valid(world,body)
    // A Collider on the static body of the world stands for itself on its shapes.
    if !own && !shapes_of(world,e) {
        api.call_failf(call,api.INVALID_PARAMS,"%s has no body or collider in the simulation: give it a Rigid_Body, a Collider or a Character, and step the game once after adding it",name)
        return
    }
    r:=api.call_result(call,Physics_Inspect_Result)
    r.entity,r.body=e,own
    if own {
        index:=base.handle_index(base.Handle(body))
        r.awake=sim.body_is_awake(world,body)
        r.mass,r.inv_mass=world.bodies[index].mass,world.bodies[index].inv_mass
    }
    // Each side of a pair stands for e when its body follows e, or its shape is a collider of e.
    side :: proc(world:^sim.World,e:core.Entity,body,shape:i32) -> bool {
        return world.bodies[body].user_data==u64(e) || world.shapes[shape].user_data==u64(e)
    }
    standing :: proc(world:^sim.World,body,shape:i32) -> core.Entity {
        if user:=world.bodies[body].user_data;user!=0 {return core.Entity(user)}
        return core.Entity(world.shapes[shape].user_data)
    }
    contacts:=make([dynamic]Physics_Inspect_Contact,call.allocator)
    for &contact,index in world.contacts[:world.contact_high] {
        if .Touching not_in contact.flags {continue}
        on_a:=side(world,e,contact.body_a,contact.shape_a)
        on_b:=side(world,e,contact.body_b,contact.shape_b)
        if on_a==on_b {continue}
        other:=on_a?standing(world,contact.body_b,contact.shape_b):standing(world,contact.body_a,contact.shape_a)
        if .Overlap in contact.flags {
            append(&contacts,Physics_Inspect_Contact{other=other,sensor=true})
            continue
        }
        for m in 0..<int(contact.manifold_count) {
            manifold:=m==0?&world.manifolds[index]:&world.extra_manifolds[contact.extra][m-1]
            points:=make([]Physics_Inspect_Point,int(manifold.count),call.allocator)
            for &point,i in points {
                at:=manifold.points[i]
                point={at.point,at.separation,at.impulse}
            }
            append(&contacts,Physics_Inspect_Contact{other=other,normal=on_a?manifold.normal:-manifold.normal,points=points})
        }
    }
    r.contacts=contacts[:]
    joints:=make([dynamic]Physics_Inspect_Joint,call.allocator)
    for &joint,index in world.joints[:world.joint_high] {
        if joint.generation&1==0 {continue}
        if world.bodies[joint.body_a].user_data!=u64(e) && world.bodies[joint.body_b].user_data!=u64(e) {continue}
        h:=sim.Joint_Handle(base.handle_make(u32(index),joint.generation))
        a,b:=sim.joint_bodies(world,h)
        frame_a,frame_b,_:=sim.joint_local_frames(world,h)
        pose_a,pose_b:=sim.body_transform(world,a),sim.body_transform(world,b)
        shown:=Physics_Inspect_Joint{
            joint=core.Entity(joint.user_data),a=phys.entity_of(core.ref(state),a),b=phys.entity_of(core.ref(state),b),
            anchor_a=pose_a.p+mm.quat_rotate(pose_a.q,frame_a.p),anchor_b=pose_b.p+mm.quat_rotate(pose_b.q,frame_b.p),
            break_force=joint.break_force,break_torque=joint.break_torque,
        }
        shown.separation=linalg.length(shown.anchor_b-shown.anchor_a)
        shown.force,shown.torque=sim.joint_reaction(world,h)
        append(&joints,shown)
    }
    // A joint that broke is gone from the simulation; its components remain.
    if table:=core.world_table_of(w,phys.Joint);table!=nil {
        for joint,i in table.values {
            j:=table.entities[i]
            st,known:=editor.entity_get(w,j,phys.Joint_State)
            if !known || !st.broken {continue}
            a:=joint.a
            if a==core.NONE {a=editor.entity_parent(w,j)}
            if a!=e && joint.b!=e {continue}
            append(&joints,Physics_Inspect_Joint{joint=j,a=a,b=joint.b,broken=true,break_force=joint.break_force,break_torque=joint.break_torque})
        }
    }
    r.joints=joints[:]
}

// Whether a shape of the simulation is a collider of e.
@(private)
shapes_of :: proc(world:^sim.World,e:core.Entity) -> bool {
    for &shape in world.shapes[:world.shape_high] {
        if shape.generation&1!=0 && shape.user_data==u64(e) {return true}
    }
    return false
}

// The body whose user data is e; none without one.
@(private)
body_following :: proc(world:^sim.World,e:core.Entity) -> sim.Body_Handle {
    for &body,index in world.bodies[:world.body_high] {
        if body.generation&1!=0 && body.user_data==u64(e) {return sim.Body_Handle(base.handle_make(u32(index),body.generation))}
    }
    return {}
}
