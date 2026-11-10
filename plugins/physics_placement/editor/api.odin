package physics_placement

import "core:math"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

@(storage)
Placement_Api :: struct {provider:editor.Api_Provider}

PLACEMENT_API_DEFAULT :: Placement_Api{provider={register=placement_api_register}}

Drop :: struct {
    mesh:base.Asset_Id `mirai:"optional,label=A static .mesh asset; without it the shape"`,
    shape:host.Shape `mirai:"optional"`,
    point:[3]f32 `mirai:"unit=m,label=World point on the surface under the drop"`,
    height:f32 `mirai:"optional,min=0,max=1000,unit=m,label=Of the bottom of the mesh above the point"`,
    scale:[3]f32 `mirai:"optional,min=0.001,max=1000"`,
}

Drop_Params :: struct {
    drops:[PLACEMENT_CAPACITY]Drop `mirai:"label=Meshes in the order they fall"`,
    interval:f32 `mirai:"optional,min=0,max=10,unit=s,label=Simulated between two drops"`,
    time:f32 `mirai:"optional,min=0,max=30,unit=s,label=The most simulated after the last drop; the poses are kept when everything rests or it runs out"`,
}

Placed :: struct {
    id:base.Entity_Id,
    position:[3]f32 `mirai:"unit=m"`,
    rotation_deg:[3]f32,
    scale:[3]f32,
    rested:bool `mirai:"label=It came to rest; false when the time ran out first"`,
}

Drop_Result :: struct {
    placed:[PLACEMENT_CAPACITY]Placed `mirai:"trim,label=The new entities in the order of drops; roots of the scene"`,
    time:f32 `mirai:"unit=s,label=Simulated after the last drop"`,
}

@(private)
placement_api_register :: proc(s:^editor.Session) {
    editor.tool_entry(s,PLACEMENT_TOOL,"Placement",.Import,{key=.P,set=true})
    defaults:=Drop_Params{interval=1/f32(5),time=PLACEMENT_TICKS*PLACEMENT_DT}
    for &drop in defaults.drops {drop.shape,drop.height,drop.scale=.Cube,1,{1,1,1}}
    editor.api_method_register(s,{params=type_info_of(Drop_Params),result=type_info_of(Drop_Result),name="placement.drop",summary="Drops new meshes onto the scene and lets physics settle them as the Physics placement tool does; the scene stays fixed. One step of undo with the entities and their poses.",defaults=&defaults,run=placement_api_drop})
}

@(private)
placement_api_drop :: proc(s:^editor.Session,call:^api.Call) {
    tool:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Physics_Placement)
    if tool==nil {api.call_fail(call,api.INTERNAL_ERROR,"The editor world has no Physics_Placement storage");return}
    placement_api_run(s,call,tool)
}

// Drops, settles and confirms within the call, through the preview of the
// tool: the call never leaves it open, and the tool that was on is on again.
@(private)
placement_api_run :: proc(s:^editor.Session,call:^api.Call,tool:^Physics_Placement) {
    p:=api.call_params(call,Drop_Params)
    count,_:=api.params_array_count(call,"drops")
    if count==0 {api.call_fail(call,api.INVALID_PARAMS,"drops must list at least one mesh to drop");return}
    if editor.asset_document_active(s)!=nil {api.call_fail(call,api.SERVER_ERROR,"An asset document is in front of the scene: bring the scene to the front with editor.document");return}
    descs:[PLACEMENT_CAPACITY]Placement_Desc
    bounds:[PLACEMENT_CAPACITY]mm.Aabb
    for drop,at in p.drops[:count] {
        mesh:=erender.Mesh_Renderer{mesh=drop.mesh,shape=drop.mesh!={}?.None:drop.shape}
        descs[at]={mesh=mesh,scale=drop.scale,point=drop.point,height=drop.height}
        if !placement_valid(descs[at]) {
            api.call_failf(call,api.INVALID_PARAMS,"drops[%d]: point must be finite, height within 0 and 1000 m and each scale within 0.001 and 1000",at)
            return
        }
        measured:bool
        if bounds[at],measured=placement_box(s.app.assets,mesh);!measured {
            api.call_failf(call,api.INVALID_PARAMS,"drops[%d]: %s has no geometry to measure; give a static .mesh asset or a shape other than None",at,drop.mesh!={}?"the mesh":"the shape")
            return
        }
    }
    if editor.playing(s) {editor.api_playing(call,"placement.drop simulates on the document, whose physics runs only in Edit");return}
    if !editor.api_guard(s,call) {return}
    previous,keys:=s.viewport.plugin_tool,s.viewport.plugin_keys
    defer {
        placement_cancel(tool)
        s.viewport.plugin_tool,s.viewport.plugin_keys=previous,keys
    }
    if !placement_start(s,tool,descs[0]) {
        api.call_fail(call,api.SERVER_ERROR,"The physics placement preview could not be started: physics could not make a body or a shape of the scene; engine.diagnostics names it")
        return
    }
    between:=int(math.round(p.interval/PLACEMENT_DT))
    for at in 1..<count {
        for _ in 0..<between {
            if !placement_update(tool,PLACEMENT_DT) {api.call_fail(call,api.SERVER_ERROR,"Physics stopped while the meshes fell; engine.diagnostics names what failed");return}
        }
        if !placement_drop(tool,descs[at],bounds[at]) {
            api.call_failf(call,api.SERVER_ERROR,"drops[%d] could not be dropped: physics could not make its body; engine.diagnostics names it",at)
            return
        }
    }
    limit:=int(math.round(p.time/PLACEMENT_DT))
    for !tool.resting && tool.ticks<limit {
        if !placement_update(tool,PLACEMENT_DT) {api.call_fail(call,api.SERVER_ERROR,"Physics stopped while the meshes fell; engine.diagnostics names what failed");return}
    }
    out:=api.call_result(call,Drop_Result)
    roots,placed,ticks:=tool.roots,tool.count,tool.ticks
    motions:=core.read(core.world_table_of(tool.preview,core.Motion))
    for e,at in roots[:placed] {
        motion,made:=core.get(motions,e)
        out.placed[at].rested=made && !motion.awake
    }
    if !placement_confirm(tool) {api.call_fail(call,api.SERVER_ERROR,"The placed meshes could not be kept as a step of undo");return}
    w:=editor.edited_world(s)
    for e,at in roots[:placed] {
        pose:=editor.entity_world(w,e)
        id,_:=editor.entity_get(w,e,core.Id)
        row:=&out.placed[at]
        row.id,row.position,row.scale=id.value,pose.position,pose.scale
        row.rotation_deg=mm.quat_to_euler(pose.rotation)*mm.DEG_PER_RAD
    }
    out.time=f32(ticks)*PLACEMENT_DT
}
