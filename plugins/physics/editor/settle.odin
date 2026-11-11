package physics_editor

import "core:fmt"
import "core:slice"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

SETTLE_CAPACITY :: 64
SETTLE_TICKS :: 1800

Settle_Params :: struct {
    entities:[SETTLE_CAPACITY]editor.Api_Entity_Text `mirai:"text,entity,label=Scene entities with a Collider that fall and come to rest; every other body stays still"`,
    ticks:int `mirai:"optional,min=1,max=36000,label=The most ticks simulated; the poses are kept when all rest or they run out"`,
}

Settled :: struct {
    id:base.Entity_Id,
    position:[3]f32 `mirai:"unit=m"`,
    rotation_deg:[3]f32,
    rested:bool `mirai:"label=It came to rest; false when the ticks ran out first"`,
}

Settle_Result :: struct {
    settled:[SETTLE_CAPACITY]Settled `mirai:"trim,label=In the order given, as the document keeps them"`,
    ticks:int `mirai:"label=Simulated"`,
    reason:[256]u8 `mirai:"text,label=Why some did not rest; empty when all did"`,
}

@(private)
api_settle_register :: proc(s:^editor.Session) {
    defaults:=Settle_Params{ticks=SETTLE_TICKS}
    editor.api_method_register(s,Settle_Params,Settle_Result,{
        name="physics.settle",
        summary="Simulates the scene with only the given entities moving until they rest or the ticks run out, and keeps their poses as one step of undo: what drops placed objects onto the scene and onto each other. Create them above where they fall with scene.write, each with a Collider.",
        defaults=&defaults,run=api_settle,
        entry={label="Drop to rest",params=`{"entities":["$selection"]}`,icon=.Import,menu=.Tools,state=settle_state,scene=true},
    })
}

@(private)
settle_state :: proc(s:^editor.Session,b:^editor.Binding) -> editor.Command_State {
    return {disabled=s.mode!=.Edit || len(s.selection.entities)==0}
}

@(private)
api_settle :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Settle_Params)
    w:=editor.edited_world(s)
    entities,named:=editor.api_call_entities(call,w,p.entities[:],"entities",call.allocator)
    if !named {return}
    if len(entities)==0 {api.call_fail(call,api.INVALID_PARAMS,"entities must name at least one scene entity with a Collider");return}
    if len(entities)>SETTLE_CAPACITY {api.call_failf(call,api.INVALID_PARAMS,"entities: at most %d at once",SETTLE_CAPACITY);return}
    if !editor.api_guard(s,call) {return}
    rested:=make([]bool,len(entities),context.temp_allocator)
    ran,at,problem:=editor.simulate_until_rest(s,entities,p.ticks,rested)
    if problem!="" {
        if at>=0 {api.call_failf(call,api.INVALID_PARAMS,"entities[%d] %s",at,problem)} else {api.call_fail(call,api.SERVER_ERROR,problem)}
        return
    }
    out:=api.call_result(call,Settle_Result)
    out.ticks=ran
    still:=0
    for e,i in entities {
        pose:=editor.entity_world(w,e)
        row:=&out.settled[i]
        row.id,row.position,row.rested=editor.api_entity_id(w,e),pose.position,rested[i]
        row.rotation_deg=mm.quat_to_euler(pose.rotation)*mm.DEG_PER_RAD
        if !rested[i] {still+=1}
    }
    if still>0 {fmt.bprintf(out.reason[:],"%d of %d were still moving after %d ticks and keep where they were: give more ticks, or a surface to rest on",still,len(entities),ran)}
}

// For a Simulate limited to moving: each is a dynamic body (with its Rigid_Body when that is
// dynamic, or one that comes to rest soon), every other body is static and every character the
// still capsule of its collider. Physics runs alone there: what another plugin gives its shapes
// (an External collider, as a Destructible has) is the mesh it shows. Again with more entities,
// those that already moved go on as they were.
@(private)
simulation_limit :: proc(w:core.World_Ref,app:^host.App,moving:[]core.Entity) -> (at:int,problem:string) {
    rigids,colliders,motions:=core.world_table_of(w,phys.Rigid_Body),core.world_table_of(w,phys.Collider),core.world_table_of(w,core.Motion)
    if rigids==nil || colliders==nil || motions==nil {return -1,"The world has no tables of bodies: generate the project with the physics plugin"}
    for e,i in moving {
        collider,found:=core.get(colliders,e)
        if !found {return i,"has no Collider: give it one with scene.write, so it has a shape to fall with"}
        if collider.kind==.Mesh || collider.kind==.Heightfield {return i,"has a Collider of kind Mesh or Heightfield, which has no mass: give it a Box, Sphere, Capsule, Cylinder or Hull"}
    }
    if requests:=core.world_storage_of(w,phys.Body_Requests);requests!=nil {core.queue_clear(&requests.queue)}
    if characters:=core.world_table_of(w,phys.Character);characters!=nil {
        for e in characters.entities {core.remove(characters,e)}
    }
    for &rigid,row in core.writable(rigids) {
        if rigid.type!=.Dynamic || !slice.contains(moving,rigids.entities[row]) {rigid=phys.RIGID_BODY_STATIC}
    }
    for &collider,row in core.writable(colliders) {
        if collider.kind!=.External {continue}
        e:=colliders.entities[row]
        if slice.contains(moving,e) {collider.kind=.Hull} else if editor.entity_has(w,e,erender.Mesh_Renderer) {collider.kind=.Mesh}
    }
    for e in moving {
        if rigid,found:=core.get(rigids,e);!found || rigid.type!=.Dynamic {
            body:=phys.RIGID_BODY_DYNAMIC
            body.linear_damping,body.angular_damping=0.15,0.2
            core.add(rigids,e,body)
        }
        // Made by a step that does not play, a body gets no Motion of physics: without one its rest is never read.
        if !core.has(motions,e) {core.add(motions,e,core.Motion{awake=true})}
    }
    core.world_settle(w)
    made:=phys.step_world(w,app,0)
    if problems:=host.app_world_storage(app,w.data,core.Problems);problems!=nil && problems.count>0 {
        return -1,fmt.tprintf("Physics could not make the bodies of the scene: %s",core.problem_text(&problems.entries[0]))
    }
    if !made {return -1,"Physics could not make the bodies of the scene"}
    return -1,""
}
