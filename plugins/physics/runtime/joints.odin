package physics

import "core:math/linalg"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// Keeps the joints of the simulation equal to the Joint rows, while playing.
// Body a of a Joint is body A of the simulation, whose frame is the Transform
// of the entity of the joint, so the angle or translation of the joint is
// that of b relative to it.

// The link of the joint of an entity; the joint of another generation of its
// index goes first. nil without memory.
@(private)
joint_link :: proc(s:^Sync,e:core.Entity) -> ^Joint_Link {
    state:=s.state
    if l:=core.entity_map_get(&state.joints,e);l!=nil {return l}
    if held:=core.entity_map_held(&state.joints,e);held!=core.NONE {
        if l:=core.entity_map_get(&state.joints,held);sim.joint_valid(&state.world,l.joint) {sim.joint_destroy(&state.world,l.joint)}
    }
    l,_:=core.entity_map_put(&state.joints,e,Joint_Link{})
    return l
}

// The body an entity owns: not the one that carries it as part of a compound.
@(private)
joint_body :: proc(s:^Sync,e:core.Entity) -> sim.Body_Handle {
    l:=link_find(s.state,e)
    if l==nil {return {}}
    #partial switch l.kind {
    case .Body,.Proxy: return sim.body_valid(&s.state.world,l.body)?l.body:{}
    case .Character: return sim.character_body(&s.state.world,l.character)
    }
    return {}
}

@(private)
joint_world_body :: proc(state:^Physics_State) -> sim.Body_Handle {
    if !sim.body_valid(&state.world,state.world_body) {
        desc:=sim.BODY_DESC_DEFAULT
        desc.type=.Static
        state.world_body=sim.body_create(&state.world,desc)
    }
    return state.world_body
}

@(private)
joint_quat :: proc "contextless" (q:mm.Quat) -> mm.Quat {return q==0?1:linalg.normalize(q)}

// Entity a of a joint: the parent of its entity unless it names one.
@(private)
joint_a :: proc(s:^Sync,e:core.Entity,joint:Joint) -> core.Entity {
    if joint.a!=core.NONE {return joint.a}
    parent,_:=core.get(s.parents,e)
    return parent.entity
}

// Where a frame in the world is seen from an entity, NONE being the world.
@(private)
joint_frame_from :: proc(s:^Sync,from:core.Entity,frame:mm.Transform) -> sim.Transform {
    if from==core.NONE {return {frame.position,frame.rotation}}
    there,_:=core.world_of(s.locals,s.parents,from)
    inverse:=mm.quat_inverse(there.rotation)
    return {mm.quat_rotate(inverse,frame.position-there.position),linalg.normalize(inverse*frame.rotation)}
}

// What the joint is made from: it is made again when it changes.
joint_frames_same :: proc "contextless" (a,b:Joint) -> bool {
    return a.a==b.a && a.b==b.b && a.collide==b.collide && a.b_frame==b.b_frame && a.b_anchor==b.b_anchor && a.b_rotation==b.b_rotation
}

// What of a Joint_State the joint is made from.
@(private)
joint_frames :: proc "contextless" (joint:Joint,st:Joint_State) -> (frames:Joint_Frames) {
    if !joint.b_frame {frames.taken,frames.b_anchor,frames.b_rotation=st.taken,st.b_anchor,st.b_rotation}
    return
}

@(private)
joint_state_read :: proc(states:^core.Table(Joint_State),e:core.Entity) -> (value:Joint_State,found:bool) {
    for i:=len(states.pending)-1;i>=0;i-=1 {
        pending:=states.pending[i]
        if pending.entity!=e {continue}
        return pending.value>=0?states.added[pending.value]:Joint_State{},pending.value>=0
    }
    return core.get(states,e)
}

// What the setters of the joint change.
@(private)
joint_tuned_same :: proc "contextless" (a,b:Joint) -> bool {
    return a.break_force==b.break_force && a.break_torque==b.break_torque && a.linear==b.linear && a.angular==b.angular
}

@(private)
joints_sync :: proc(s:^Sync,joints:core.Read(Joint),states:^core.Table(Joint_State)) {
    state:=s.state
    #reverse for &l,at in state.joints.values {
        if core.has(joints,state.joints.entities[at]) {continue}
        if sim.joint_valid(&state.world,l.joint) {sim.joint_destroy(&state.world,l.joint)}
        core.entity_map_remove_at(&state.joints,at)
    }
    for row in 0..<core.count(joints) {
        e:=core.entity_at(joints,row)
        joint_reconcile(s,states,e,core.at(joints,row))
    }
}

@(private)
joint_reconcile :: proc(s:^Sync,states:^core.Table(Joint_State),e:core.Entity,joint:Joint) {
    state:=s.state
    w:=&state.world
    l:=joint_link(s,e)
    if l==nil {
        memory_problem(s.problems,e,"the link of the Joint")
        return
    }
    held,has_state:=joint_state_read(states,e)
    st:=held
    st.error=joint_configuration_error(joint)
    a:=joint_a(s,e,joint)
    body_a:=a==core.NONE?sim.Body_Handle{}:joint_body(s,a)
    body_b:=joint.b==core.NONE?joint_world_body(s.state):joint_body(s,joint.b)
    if st.error==.None && (body_a=={} || body_b=={} || body_a==body_b) {st.error=.Invalid_Bodies}
    wanted:=!st.broken && st.error==.None
    // Its frame on a moves with its own Transform, unless it is on the entity of a, whose frame it is.
    local:core.Transform
    if a!=e {local,_=core.get(s.locals,e)}
    valid:=sim.joint_valid(w,l.joint)
    same:=joint_frames_same(l.applied,joint) && l.frames==joint_frames(joint,held) && l.a==body_a && l.b==body_b && l.local==local
    if valid && (!wanted || !same) {
        sim.joint_destroy(w,l.joint)
        l.joint,valid={},false
        // The frame on b of a body another owner places is the one that owner took.
        if !joint.b_frame && !core.has(s.targets,e) {st.taken=false}
    }
    if !wanted || l.refused && same {
        if l.refused && same && st.error==.None {st.error=.Capacity}
        if st!=held || !has_state {core.add(states,e,st)}
        return
    }
    if !valid {
        here,_:=core.world_of(s.locals,s.parents,e)
        frame_b:=sim.Transform{joint.b_anchor,joint_quat(joint.b_rotation)}
        if !joint.b_frame {
            if !st.taken {
                taken:=joint_frame_from(s,joint.b,here)
                st.b_anchor,st.b_rotation,st.taken=taken.p,taken.q,true
            }
            frame_b={st.b_anchor,joint_quat(st.b_rotation)}
        }
        desc:=sim.Joint_Desc{
            body_a=body_a,body_b=body_b,frame_a=joint_frame_from(s,a,here),frame_b=frame_b,collide_connected=joint.collide,
            break_force=joint.break_force,break_torque=joint.break_torque,user_data=u64(e),linear=joint.linear,angular=joint.angular,
        }
        l.joint=sim.joint_create(w,desc)
        l.applied,l.a,l.b,l.local=joint,body_a,body_b,local
        l.refused=l.joint=={}
        if l.refused {
            core.report(s.problems,e,"physics.joints","its Joint was refused by the simulation: the %d joints of Physics_Settings.joints are in use; raise joints, or remove joints (Joint_State.error is Capacity)",w.desc.joint_capacity)
            st.error=.Capacity
        }
        l.frames=joint_frames(joint,st)
    } else if !joint_tuned_same(l.applied,joint) {
        sim.joint_set_break(w,l.joint,joint.break_force,joint.break_torque)
        st.error=sim.joint_set_axes(w,l.joint,joint.linear,joint.angular)
        l.applied=joint
    }
    if st!=held || !has_state {core.add(states,e,st)}
}

// The joints the step broke: their state says so and the game hears of it.
@(private)
joints_events :: proc(s:^Sync,events:^Physics_Events,states:^core.Table(Joint_State)) {
    state:=s.state
    for event in sim.world_events(&state.world).joint_break {
        for &l,at in state.joints.values {
            if l.joint!=event.joint {continue}
            e:=state.joints.entities[at]
            l.joint,l.refused,l.applied={},false,{}
            if row:=core.edit(states,e);row!=nil {row.broken=true}
            core.push(&events.joint_break,Joint_Break{entity=e,force=event.force,torque=event.torque})
            break
        }
    }
}
