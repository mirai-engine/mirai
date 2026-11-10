package physics

import "core:math/linalg"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// Keeps the joints of the simulation equal to the Joint rows, while playing.
// The body of the entity is body B of the joint and the one of the target is
// body A, so the angle or translation of the joint is that of the entity
// relative to its target.

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
joint_world_body :: proc(s:^Sync) -> sim.Body_Handle {
    state:=s.state
    if !sim.body_valid(&state.world,state.world_body) {
        desc:=sim.BODY_DESC_DEFAULT
        desc.type=.Static
        state.world_body=sim.body_create(&state.world,desc)
    }
    return state.world_body
}

@(private)
joint_quat :: proc "contextless" (q:mm.Quat) -> mm.Quat {return q==0?1:linalg.normalize(q)}

@(private)
joint_scale :: proc(s:^Sync,e:core.Entity) -> [3]f32 {
    world,ok:=core.world_of(s.locals,s.parents,e)
    return ok?linalg.abs(world.scale):{1,1,1}
}

// What the joint is made from: it is made again when it changes.
joint_frames_same :: proc "contextless" (a,b:Joint) -> bool {
    return a.kind==b.kind && a.target==b.target && a.collide==b.collide && a.auto_target==b.auto_target && a.anchor==b.anchor &&
        a.target_anchor==b.target_anchor && a.rotation==b.rotation && a.target_rotation==b.target_rotation && a.cone==b.cone
}

// What of a Joint_State the joint is made from.
@(private)
joint_frames :: proc "contextless" (joint:Joint,st:Joint_State) -> (frames:Joint_Frames) {
    if joint.auto_target {frames.taken,frames.target_anchor,frames.target_rotation=st.taken,st.target_anchor,st.target_rotation}
    if joint.kind==.Distance && joint.length<=0 {frames.length=st.length}
    return
}

@(private)
joint_state_read :: proc(states:^core.Table(Joint_State),e:core.Entity) -> (value:Joint_State,found:bool) {
    for i:=len(states.pending)-1;i>=0;i-=1 {
        pending:=states.pending[i]
        if pending.entity!=e {continue}
        return pending.value>=0?states.added[pending.value]:Joint_State{},pending.value>=0
    }
    return core.get(core.read(states),e)
}

// What the setters of the joint change.
@(private)
joint_tuned_same :: proc "contextless" (a,b:Joint) -> bool {
    return a.limit==b.limit && a.lower==b.lower && a.upper==b.upper && a.motor==b.motor && a.motor_speed==b.motor_speed &&
        a.max_motor==b.max_motor && a.spring==b.spring && a.hertz==b.hertz && a.damping_ratio==b.damping_ratio &&
        a.spring_target==b.spring_target && a.length==b.length && a.break_force==b.break_force && a.break_torque==b.break_torque &&
        a.linear==b.linear && a.angular==b.angular
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
    body:=joint_body(s,e)
    target:=joint.target==core.NONE?joint_world_body(s):joint_body(s,joint.target)
    if st.error==.None && (body=={} || target=={} || body==target) {st.error=.Invalid_Bodies}
    wanted:=!st.broken && st.error==.None && body!={} && target!={} && body!=target
    scale:=joint_scale(s,e)
    target_scale:=joint.target!=core.NONE?joint_scale(s,joint.target):[3]f32{1,1,1}
    valid:=sim.joint_valid(w,l.joint)
    same:=joint_frames_same(l.applied,joint) && l.frames==joint_frames(joint,held) && l.body==body && l.target==target && l.scale==scale && l.target_scale==target_scale
    if valid && (!wanted || !same) {
        sim.joint_destroy(w,l.joint)
        l.joint,valid={},false
        // The frames of a body another owner places are those that owner took.
        if joint.auto_target && !core.has(s.targets,e) {st.taken=false}
    }
    if !wanted || l.refused && same {
        if l.refused && same && st.error==.None {st.error=.Capacity}
        if st!=held || !has_state {core.add(states,e,st)}
        return
    }
    if !valid {
        frame:=sim.Transform{joint.anchor*scale,joint_quat(joint.rotation)}
        frame_a:=sim.Transform{joint.target_anchor*target_scale,joint_quat(joint.target_rotation)}
        if joint.auto_target {
            if !st.taken {
                // Where the frame of the entity is now, seen from the target.
                here,there:=sim.body_transform(w,body),sim.body_transform(w,target)
                anchor:=mm.quat_rotate(mm.quat_inverse(there.q),here.p+mm.quat_rotate(here.q,frame.p)-there.p)
                st.target_anchor=anchor/linalg.max(target_scale,[3]f32{1e-6,1e-6,1e-6})
                st.target_rotation=linalg.normalize(mm.quat_inverse(there.q)*here.q*frame.q)
                st.taken=true
            }
            frame_a={st.target_anchor*target_scale,joint_quat(st.target_rotation)}
        }
        length:=joint.length>0?joint.length:st.length
        desc:=sim.Joint_Desc{
            type=sim.Joint_Type(joint.kind),body_a=target,body_b=body,frame_a=frame_a,frame_b=frame,collide_connected=joint.collide,
            enable_limit=joint.limit,lower=joint.lower,upper=joint.upper,cone=joint.cone,
            enable_motor=joint.motor,motor_speed=joint.motor_speed,max_motor=joint.max_motor,
            enable_spring=joint.spring,hertz=joint.hertz,damping_ratio=joint.damping_ratio,target=joint.spring_target,
            length=length,break_force=joint.break_force,break_torque=joint.break_torque,user_data=u64(e),
            linear=joint.linear,angular=joint.angular,
        }
        l.joint=sim.joint_create(w,desc)
        l.applied,l.body,l.target,l.scale,l.target_scale=joint,body,target,scale,target_scale
        l.refused=l.joint=={}
        if l.refused {
            core.report(s.problems,e,"physics.joints","its Joint was refused by the simulation: the %d joints of Physics_Settings.joints are in use; raise joints, or remove joints (Joint_State.error is Capacity)",w.desc.joint_capacity)
            st.error=.Capacity
        } else if joint.kind==.Distance && joint.length<=0 && st.length<=0 {
            st.length=sim.joint_distance(w,l.joint)
        }
        l.frames=joint_frames(joint,st)
    } else if !joint_tuned_same(l.applied,joint) {
        sim.joint_set_limit(w,l.joint,joint.limit,joint.lower,joint.upper)
        sim.joint_set_motor(w,l.joint,joint.motor,joint.motor_speed,joint.max_motor)
        sim.joint_set_spring(w,l.joint,joint.spring,joint.hertz,joint.damping_ratio,joint.spring_target)
        if joint.kind==.Distance && joint.length>0 {sim.joint_set_length(w,l.joint,joint.length)}
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
    w:=&state.world
    for event in sim.world_events(w).joint_break {
        e:=core.Entity(sim.body_user_data(w,event.body_b))
        l:=core.entity_map_get(&state.joints,e)
        if l==nil || l.joint!=event.joint {
            l=nil
            for &candidate,at in state.joints.values {
                if candidate.joint==event.joint {
                    l,e=&candidate,state.joints.entities[at]
                    break
                }
            }
            if l==nil {continue}
        }
        target:=l.applied.target
        l.joint,l.refused,l.applied={},false,{}
        if row:=core.edit(states,e);row!=nil {row.broken=true}
        core.push(&events.joint_break,Joint_Break{entity=e,target=target,force=event.force,torque=event.torque})
    }
}
