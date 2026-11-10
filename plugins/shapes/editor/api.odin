package shapes_editor

import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import shapes "plugins:shapes/runtime"
import "mirai:std/base"

@(storage)
Shapes_Api :: struct {provider:editor.Api_Provider}

SHAPES_API_DEFAULT :: Shapes_Api{provider={register=api_register}}

STAMP_POINTS :: 256
STAMP_IDS :: 64

Stamp_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,optional,label=A shape whose local XY at z 0 is the plane, and the first an add joins; 0: the plane z 0 of the world"`,
    points:[STAMP_POINTS][3]f32 `mirai:"unit=m,label=World points in order, taken onto the plane: the stamp swept along the path through them"`,
    kind:shapes.Stamp_Kind `mirai:"optional"`,
    size:f32 `mirai:"optional,min=0.01,max=100,unit=m,label=Half the width of the square and the radius of the circle; the other kinds reach about as far"`,
    angle:f32 `mirai:"optional,angle"`,
    cut:bool `mirai:"optional,label=Cuts the stamps out of every outline shape of the plane instead of adding them to one"`,
    material:base.Asset_Id `mirai:"optional,kind=.mat,label=Of a shape the stroke makes"`,
}

Stamp_Result :: struct {
    ids:[STAMP_IDS]base.Entity_Id `mirai:"label=The shapes the stroke changed or made"`,
    count:u32 `mirai:"label=Of ids"`,
    removed:u32 `mirai:"label=Shapes the cut took away whole"`,
}

Corner_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=An outline shape"`,
    op:Corner_Op,
    at:[3]f32 `mirai:"unit=m,label=World point: the corner nearest it is moved or removed; a corner is inserted at the point of the nearest edge"`,
    to:[3]f32 `mirai:"optional,unit=m,label=Where a moved corner goes, taken onto the plane of the shape"`,
}

Corner_Result :: struct {
    id:base.Entity_Id,
    corner:u32 `mirai:"label=Index of the corner moved, inserted or removed"`,
    corners:u32 `mirai:"label=Of the shape now"`,
}

@(private)
api_register :: proc(s:^editor.Session) {
    editor.tool_entry(s,TOOL,"Shapes",.Prism,{key=.K,set=true})
    defaults:=Stamp_Params{size=SETTINGS_DEFAULT.size}
    editor.api_method_register(s,{name="shapes.stamp",summary="Sweeps a stamp (square, circle, star, heart...) along world points over the outline shapes of a plane, as the Stamp mode of the Shapes tool: adding joins the area to the first shape it touches at the first point or makes one, cutting takes it out of every outline shape of the plane, splitting it into shapes or deleting it. One step of undo.",params=Stamp_Params,params_info=type_info_of(Stamp_Params),result=Stamp_Result,result_info=type_info_of(Stamp_Result),defaults=&defaults,run=api_stamp})
    editor.api_method_register(s,{name="shapes.corner",summary="Moves, inserts or removes a corner of an outline shape at world points, as the Corners mode of the Shapes tool. A change that would make edges cross is refused. One step of undo.",params=Corner_Params,params_info=type_info_of(Corner_Params),result=Corner_Result,result_info=type_info_of(Corner_Result),run=api_corner})
}

@(private)
api_stamp :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Stamp_Params)
    count,_:=api.params_array_count(call,"points")
    if count==0 {api.call_fail(call,api.INVALID_PARAMS,"points must list at least one world point of the stroke");return}
    w:=editor.edited_world(s)
    if core.world_table_of(w,shapes.Shape)==nil {api.call_fail(call,api.SERVER_ERROR,"The project world has no Shape: enable the shapes plugin");return}
    first:=core.NONE
    if p.entity[0]!=0 {
        named:bool
        if first,named=editor.api_call_entity(call,w,p.entity[:]);!named {return}
        if !editor.entity_has(w,first,shapes.Shape) {api.call_failf(call,api.INVALID_PARAMS,"entity %s has no Shape; give 0 for the plane z 0 of the world",base.text_get(p.entity[:]));return}
    }
    plane:=plane_of(w,first)
    stroke:Stroke
    defer stroke_free(&stroke)
    // The points of a call are meant: the path keeps every turn.
    if !stroke_begin(&stroke,w,plane,first,p.cut,p.kind,p.size,p.angle,0,p.material,context.temp_allocator) {
        api.call_fail(call,api.INVALID_PARAMS,"size must be more than 0")
        return
    }
    refused:shapes.Shape_Error
    for at in 0..<count {
        if error:=stroke_to(&stroke,local_of(plane,p.points[at]));error!=.None {refused=error}
    }
    if refused!=.None {api.call_failf(call,api.INVALID_PARAMS,"points: the stroke was refused: %s",shapes.shape_error_text(refused));return}
    if !stroke_dirty(&stroke) {api.call_fail(call,api.INVALID_PARAMS,"points: the cut touches no outline shape of the plane; give points over a shape, or its id");return}
    if !editor.api_edit_begin(s,call,p.cut?"Cut":"Stamp") {return}
    written:=stroke_sync(s,&stroke)
    if !written {api.call_fail(call,api.SERVER_ERROR,"The scene refused a shape of the stroke: an entity another editor holds or a section that is not edited")}
    if !editor.api_edit_end(s,call,written) {return}
    out:=api.call_result(call,Stamp_Result)
    entities:[STAMP_IDS]core.Entity
    made,removed:=stroke_results(&stroke,entities[:])
    for e,i in entities[:min(made,STAMP_IDS)] {out.ids[i]=editor.api_entity_id(w,e)}
    out.count,out.removed=u32(min(made,STAMP_IDS)),u32(removed)
}

@(private)
api_corner :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Corner_Params)
    w:=editor.edited_world(s)
    e,named:=editor.api_call_entity(call,w,p.entity[:])
    if !named {return}
    shape,found:=editor.entity_get(w,e,shapes.Shape)
    if !found || shape.kind!=.Outline {api.call_failf(call,api.INVALID_PARAMS,"entity %s has no outline Shape",base.text_get(p.entity[:]));return}
    if p.op==.Move && !editor.tool_call_given(call,"to") {api.call_fail(call,api.INVALID_PARAMS,"to: a move needs the world point the corner goes to");return}
    t:=editor.entity_world(w,e)
    if !shapes.scale_usable(t.scale) {api.call_failf(call,api.INVALID_PARAMS,"entity %s has a scale with a zero axis",base.text_get(p.entity[:]));return}
    at,to:=local_of(t,p.at),local_of(t,p.to)
    index:int
    found_place:bool
    switch p.op {
    case .Move,.Remove: index,found_place=shapes.shape_vertex_near(&shape,at,1e30)
    case .Insert:
        edge,point,near:=shapes.shape_edge_near(&shape,at,1e30)
        index,at,found_place=edge,point,near
    }
    if !found_place {api.call_failf(call,api.INVALID_PARAMS,"entity %s has no corners",base.text_get(p.entity[:]));return}
    if p.op==.Move {at=to}
    if !editor.api_edit_begin(s,call,p.op==.Move?"Move corner":p.op==.Insert?"Insert corner":"Remove corner") {return}
    error:=corner_edit(s,e,p.op,index,at,"")
    switch {
    case error==.None:
    case p.op==.Remove && error==.Invalid: api.call_fail(call,api.INVALID_PARAMS,"at: a loop keeps at least three corners")
    case error==.Self_Intersecting:        api.call_failf(call,api.INVALID_PARAMS,"%s: %s; give a point that keeps the loops apart",p.op==.Move?"to":"at",shapes.shape_error_text(error))
    case:                                  api.call_fail(call,api.INVALID_PARAMS,shapes.shape_error_text(error))
    }
    if !editor.api_edit_end(s,call,error==.None) {return}
    now,_:=editor.entity_get(w,e,shapes.Shape)
    out:=api.call_result(call,Corner_Result)
    out.id,out.corners=editor.api_entity_id(w,e),u32(now.point_count)
    out.corner=u32(p.op==.Insert?index+1:index)
}
