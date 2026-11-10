package physics

import "core:math/linalg"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

// A proxy is an entity that stands for a body some other library owns, as the
// groups of a broken destructible do: it can be placed and given a pose target like a
// body of its own, but the simulation never makes or ends the body.

// Makes the entity stand for a body that exists in the simulation, with the Transform it was left with.
// False when the entity, or another generation of its index, has a body of
// its own, or without memory.
proxy_set :: proc(state:^Physics_State,e:core.Entity,body:sim.Body_Handle,position:[3]f32,rotation:mm.Quat) -> bool {
    if !state.ready || !sim.body_valid(&state.world,body) {return false}
    listed:=false
    if held:=core.entity_map_held(&state.links,e);held!=core.NONE {
        l:=core.entity_map_get(&state.links,held)
        if l.kind!=.Proxy && l.kind!=.None {return false}
        if l.kind==.Proxy && held==e && l.body==body {return true}
        if l.kind==.Proxy {
            proxy_remove(state,held)
            listed=held==e
        }
    }
    // The step brings back the rows of every proxy: who owns its body changes it without telling.
    if !listed {
        if _,err:=append(&state.proxies,e);err!=nil {return false}
    }
    _,ok:=core.entity_map_put(&state.links,e,Link{kind=.Proxy,body=body,written_position=position,written_rotation=rotation,placed={position,rotation}})
    // Without room for the links it looks at, the step looks at every one.
    if ok && cap(state.touched)<2*len(state.links.values) && reserve(&state.touched,4*len(state.links.values))!=nil {state.touched_all=true}
    return ok
}

proxy_remove :: proc(state:^Physics_State,e:core.Entity) {
    l:=link_find(state,e)
    if l==nil || l.kind!=.Proxy {return}
    if l.hold.by!={} && sim.body_valid(&state.world,l.body) {
        sim.body_set_velocity(&state.world,l.body,{},{})
        sim.body_set_type(&state.world,l.body,l.hold.type_before)
    }
    for &joint,at in state.joints.values {
        if state.joints.entities[at]==e || joint.applied.target==e {
            if sim.joint_valid(&state.world,joint.joint) {sim.joint_destroy(&state.world,joint.joint)}
            joint.joint,joint.body,joint.target={}, {}, {}
        }
    }
    core.entity_map_remove(&state.links,e)
    // The links moved, and poses_write drops the entity from the proxies.
    state.touched_all=true
}

// The Transform a proxy was last left with, by whoever moves it or by its pose target.
proxy_pose :: proc(state:^Physics_State,e:core.Entity) -> (position:[3]f32,rotation:mm.Quat,ok:bool) {
    l:=link_find(state,e)
    if l==nil || l.kind!=.Proxy {return}
    return l.written_position,l.written_rotation,true
}

proxy_written :: proc(state:^Physics_State,e:core.Entity,position:[3]f32,rotation:mm.Quat) {
    if l:=link_find(state,e);l!=nil && l.kind==.Proxy {l.written_position,l.written_rotation=position,rotation}
}
