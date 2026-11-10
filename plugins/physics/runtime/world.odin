package physics

import "mirai:core"
import "mirai:host"
import volume "mirai:engine/volume"
import "mirai:std/jobs"
import sim "plugins:physics/runtime/sim"

// Advances only physics, outside the loops: the functions of this library in
// the fixed phase of the editor loop, with the binding and the settle the
// generator gives them. Zero dt reconciles authoring poses.
step_world :: proc(w:core.World_Ref,app:^host.App,dt:f32) -> bool {
    if w.data==nil || w.info==nil || w.place!=.World || app==nil || app.shared==nil || !(dt>=0 && dt<=max(f32)) {return false}
    defer core.world_events_age(w)
    if !core.world_run(w,app.shared,nil,app,.Editor,.Fixed,{"physics"},{dt=dt,playing=dt>0}) {return false}
    state:=core.world_storage_of(w,Physics_State)
    return state!=nil && state.ready
}

// Advances by dt a simulation that no world steps, made with state_make: a bake, or the test of a library that
// makes its bodies itself (owned bodies, breakables). The requests of areas (fields, radial forces and
// impulses, strain) reach its bodies, which fall with gravity; one that names an entity does nothing and says so.
// A world advances with physics_step.
simulate :: proc(state:^Physics_State,requests:^Body_Requests,job_system:^jobs.Job_System,dt:f32,gravity:=volume.GRAVITY_WORLD,problems:^core.Problems=nil) -> bool {
    if state==nil || !state.ready || job_system==nil || !(dt>0 && dt<=max(f32)) {return false}
    for value in gravity {if !(value>=-max(f32) && value<=max(f32)) {return false}}
    w:=&state.world
    asked:[]Body_Request
    if requests!=nil {
        asked=core.take(&requests.queue)
        s:=Sync{state=state,problems=problems}
        for request in asked {
            if !area_apply(&s,request) {request_problem(&s,request.entity,request.kind,"physics.request_body","it is in a simulation without rows","send it to the Body_Requests of a world")}
        }
    }
    sim.world_set_gravity(w,gravity)
    parallel:=Parallel{job_system}
    w.desc.parallel_user=&parallel
    sim.world_step(w,dt)
    w.desc.parallel_user=nil
    strains_apply(w,asked)
    return true
}
