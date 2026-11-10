package physics

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
    if held:=core.entity_map_held(&state.links,e);held!=core.NONE {
        l:=core.entity_map_get(&state.links,held)
        if l.kind!=.Proxy && l.kind!=.None {return false}
        if l.kind==.Proxy && held==e && l.body==body {return true}
        if l.kind==.Proxy {proxy_remove(state,held)}
    }
    // The step brings back the rows of every proxy: who owns its body changes it without telling.
    record:=proxy_of(state,e)
    if record==nil {
        if _,err:=append(&state.proxies,Proxy{entity=e});err!=nil {return false}
        record=&state.proxies[len(state.proxies)-1]
    }
    record.position,record.rotation=position,rotation
    if links_put(state,e,Link{kind=.Proxy,body=body})==nil {return false}
    // Without room for the links it looks at, the step looks at every one.
    if cap(state.touched)<2*len(state.links.values) && reserve(&state.touched,4*len(state.links.values))!=nil {state.touched_all=true}
    return true
}

proxy_remove :: proc(state:^Physics_State,e:core.Entity) {
    at:=core.entity_map_index(&state.links,e)
    if at<0 || state.links.values[at].kind!=.Proxy {return}
    body:=state.links.values[at].body
    if h:=held_of(state,e);h!=nil {
        if h.by!={} && sim.body_valid(&state.world,body) {
            sim.body_set_velocity(&state.world,body,{},{})
            sim.body_set_type(&state.world,body,h.type_before)
        }
        h^={entity=e}
    }
    for &joint in state.joints.values {
        if joint.a!=body && joint.b!=body {continue}
        if sim.joint_valid(&state.world,joint.joint) {sim.joint_destroy(&state.world,joint.joint)}
        joint.joint,joint.a,joint.b={},{},{}
    }
    links_remove_at(state,at)
    // The links moved, and poses_write drops the entity from the proxies.
    state.touched_all=true
}

@(private)
proxy_of :: proc(state:^Physics_State,e:core.Entity) -> ^Proxy {
    for &record in state.proxies {
        if record.entity==e {return &record}
    }
    return nil
}

// The Transform a proxy was last left with, by whoever moves it or by its pose target.
proxy_pose :: proc(state:^Physics_State,e:core.Entity) -> (position:[3]f32,rotation:mm.Quat,ok:bool) {
    l:=link_find(state,e)
    record:=proxy_of(state,e)
    if l==nil || l.kind!=.Proxy || record==nil {return}
    return record.position,record.rotation,true
}

proxy_written :: proc(state:^Physics_State,e:core.Entity,position:[3]f32,rotation:mm.Quat) {
    if record:=proxy_of(state,e);record!=nil {record.position,record.rotation=position,rotation}
}
