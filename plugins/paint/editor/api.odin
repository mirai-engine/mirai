package paint_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import paint "plugins:paint/runtime"
import "mirai:std/base"

@(storage)
Paint_Api :: struct {provider:editor.Api_Provider}

PAINT_API_DEFAULT :: Paint_Api{provider={register=api_register}}

STROKE_POINTS :: 256
CLEAR_IDS :: 64

Stroke_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    points:[STROKE_POINTS][3]f32 `mirai:"unit=m,label=World points in order: the brush stamps at the first and along each segment to the next"`,
    radius:f32 `mirai:"optional,min=0.01,max=100,unit=m,label=Vertices closer than it to the stroke take paint; fully at the center and none at the edge"`,
    strength:f32 `mirai:"optional,min=0,max=1,label=How far the stroke takes a color toward the one of the brush"`,
    color:[3]f32 `mirai:"optional,min=0,max=1"`,
}

Stroke_Result :: struct {
    id:base.Entity_Id,
    mesh:base.Asset_Id `mirai:"label=The painted copy the entity shows now; unsaved until saved"`,
    path:[128]u8 `mirai:"text,label=Of the painted copy under the asset root"`,
    vertices:u32 `mirai:"label=Of the mesh"`,
    changed:u32 `mirai:"label=Vertices whose color the stroke changed"`,
}

Clear_Params :: struct {
    entities:[CLEAR_IDS]editor.Api_Entity_Text `mirai:"text,entity,label=Painted entities"`,
}

Clear_Result :: struct {cleared:u32}

@(private)
api_register :: proc(s:^editor.Session) {
    defaults:=Stroke_Params{radius=RADIUS_DEFAULT,strength=STRENGTH_DEFAULT,color=COLOR_DEFAULT}
    editor.api_method_register(s,{name="paint.stroke",summary="Paints the vertex colors of the mesh of an entity with the brush of the Paint tool along world points. One step of undo; the entity shows a painted copy of its mesh that stays unsaved until saved.",params=Stroke_Params,params_info=type_info_of(Stroke_Params),result=Stroke_Result,result_info=type_info_of(Stroke_Result),defaults=&defaults,run=api_stroke})
    editor.api_method_register(s,{name="paint.clear",summary="Gives painted entities back the mesh or primitive they showed before their first stroke. One step of undo.",params=Clear_Params,params_info=type_info_of(Clear_Params),result=Clear_Result,result_info=type_info_of(Clear_Result),run=api_clear})
}

@(private)
api_stroke :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Stroke_Params)
    count,_:=api.params_array_count(call,"points")
    if count==0 {api.call_fail(call,api.INVALID_PARAMS,"points must list at least one world point of the stroke");return}
    app:=s.app
    if app.assets==nil {api.call_fail(call,api.SERVER_ERROR,"The editor has no asset registry to write the painted mesh to");return}
    w:=editor.edited_world(s)
    e,named:=editor.api_call_entity(call,w,p.entity[:])
    if !named {return}
    given:=base.text_get(p.entity[:])
    source,shown:=editor.entity_get(w,e,erender.Mesh_Renderer)
    if !shown || (source.mesh=={} && source.shape==.None) {api.call_failf(call,api.INVALID_PARAMS,"entity %s shows no mesh; give it a Mesh_Renderer with a mesh asset or a shape",given);return}
    tool:=Paint_Tool{radius=p.radius,strength=p.strength,color=p.color}
    defer paint_tool_free(&tool)
    stroke:=&tool.stroke
    if !stroke_load(stroke,app.assets,e,source,editor.entity_world(w,e),app.allocator) {
        api.call_failf(call,api.INVALID_PARAMS,"the mesh of entity %s cannot be painted: it is not a mesh asset with vertices and valid indices",given)
        return
    }
    touched:=stamp(stroke.positions,stroke.weights,p.points[0],tool.radius)
    for at in 1..<count {
        if stamp_segment(stroke.positions,stroke.weights,p.points[at-1],p.points[at],tool.radius) {touched=true}
    }
    if !touched {
        api.call_failf(call,api.INVALID_PARAMS,"points: no vertex of entity %x is within %g m of the stroke; give points on its surface or a larger radius",p.entity,tool.radius)
        return
    }
    if !editor.api_edit_begin(s,call,"Paint") {return}
    written:=stroke_apply(s,stroke,w,app.assets,app.allocator,tool.color,tool.strength)
    if !written {api.call_fail(call,api.SERVER_ERROR,"The painted mesh could not be written under the asset root")}
    if !editor.api_edit_end(s,call,written) {return}
    out:=api.call_result(call,Stroke_Result)
    out.id,out.mesh,out.vertices=editor.api_entity_id(w,e),stroke.id,u32(len(stroke.before))
    fmt.bprintf(out.path[:],"%s/%016x.mesh",FOLDER,stroke.id[0])
    for vertex,at in stroke.canvas.vertices {
        if vertex.color!=stroke.before[at] {out.changed+=1}
    }
}

@(private)
api_clear :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Clear_Params)
    w:=editor.edited_world(s)
    painted:=core.world_table_of(w,paint.Painted)
    entities:[CLEAR_IDS]core.Entity
    count:=0
    for &text,at in p.entities {
        if text[0]==0 {continue}
        e,named:=editor.api_call_entity(call,w,text[:],fmt.tprintf("entities[%d]",at))
        if !named {return}
        if painted==nil || !core.has(painted,e) {api.call_failf(call,api.INVALID_PARAMS,"entities[%d]: %s has no paint to clear: it has no Painted component",at,base.text_get(text[:]));return}
        entities[count]=e
        count+=1
    }
    if count==0 {api.call_fail(call,api.INVALID_PARAMS,"entities must list at least one painted entity");return}
    if !editor.api_edit_begin(s,call,"Clear paint") {return}
    cleared:=paint_restore(w,entities[:count])
    if !editor.api_edit_end(s,call,cleared>0) {return}
    api.call_result(call,Clear_Result).cleared=u32(cleared)
}
