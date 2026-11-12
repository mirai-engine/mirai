package terrain_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/kit"
import volume "mirai:engine/volume"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import mm "mirai:std/math"
import "mirai:ui"

// The edit layers of a Heightfield in Sculpt and through the API: the base
// and each layer, which strokes take when it is chosen, shown or hidden,
// added and taken out, and the layer of splines, made again from the splines
// with a Terrain_Conform over the terrain (terrain_conform). Each change is
// one step of undo.

Edit_Layer_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of a Heightfield Terrain"`,
    layer:int `mirai:"optional,min=1,max=8,label=The edit layer to change or take out, from the lowest; omitted adds one on top (under that of splines)"`,
    remove:bool `mirai:"optional,label=Takes the layer out, and what it adds out of the ground"`,
    hidden:bool `mirai:"optional,label=Hides the layer, taking what it adds out of the ground until it is shown"`,
}

Conform_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of a Heightfield Terrain"`,
}

Terrain_Edit_Layer_Result :: struct {
    layers:int,
    layer:int `mirai:"optional"`,
}

Terrain_Conform_Result :: struct {
    changed:bool,
    splines:int,
}

// What the splines with a Terrain_Conform of a world give a terrain, in the
// space of its source: curves sampled at its spacing, from temp memory.
// problem says what one of them names wrong.
@(private)
conform_paths :: proc(tool:^Terrain_Tool,world:core.World_Ref) -> (paths:[dynamic]terrain.Conform_Path,problem:string) {
    paths=make([dynamic]terrain.Conform_Path,context.temp_allocator)
    conforms:=core.world_table_of(world,terrain.Terrain_Conform)
    splines:=core.world_table_of(world,volume.Spline)
    places:=core.world_table_of(world,core.World_Transform)
    if conforms==nil || splines==nil || places==nil {return}
    stroke:=&tool.stroke
    source:=&stroke.source
    scale:=stroke.scale
    for conform,row in conforms.values[:core.count(conforms)] {
        e:=core.entity_at(conforms,row)
        spline,has:=core.get(splines,e)
        place,placed:=core.get(places,e)
        if !has || !placed {continue}
        layer:=-1
        if conform.paint!={} {
            for l,i in source.layers[:source.layer_count] {if l.material==conform.paint {layer=i}}
            if layer<0 {return paths,fmt.tprintf("A Terrain_Conform paints a material that is no layer of this terrain: add it with terrain.layer, or clear paint")}
        }
        // At the spacing of the terrain, so its bed meets every sample.
        samples:=make([]mm.Path_Point,RIBBON_SAMPLES,context.temp_allocator)
        count:=volume.spline_sample(&spline,source.cell*scale,samples)
        if count<2 {continue}
        for &p in samples[:count] {
            world_point:=mm.transform_point(place.transform,p.position)
            p.position=local_of(tool,world_point)
            p.width=p.width*abs(place.transform.scale.x)/scale
        }
        append(&paths,terrain.Conform_Path{points=samples[:count],depth=conform.depth/scale,sides=max(conform.sides,0)/scale,smooth=max(conform.smooth,0)/scale,layer=layer})
    }
    return
}

@(private) RIBBON_SAMPLES :: 4096

// Makes the layer of splines of the selected Heightfield again as one step
// of undo; false with what failed told.
terrain_conform :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets) -> (changed:bool,splines:int,ok:bool) {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.active || stroke.source.kind!=.Heightfield {return}
    paths,problem:=conform_paths(tool,world)
    if problem!="" {editor.notify(s,problem);return}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return}
    change:=terrain.source_conform(&stroke.source,paths[:])
    if change.error!=.None {edit_error(s,change.error,.Flatten);return}
    if !change.changed {return false,len(paths),true}
    stroke.active=true
    stroke_changed(&tool.stroke,change)
    stroke.changed,stroke.dirty_all=true,true
    stroke_end(s,tool,world,assets,label="Conform to splines")
    return true,len(paths),!stroke.active
}

// Adds, takes out, hides or shows an edit layer (index from 0) as one step of undo.
@(private)
edit_layer_commit :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,index:int,add,remove,hidden:bool) -> (at:int,ok:bool) {
    stroke:=&tool.stroke
    if stroke.id=={} || stroke.active || stroke.source.kind!=.Heightfield {return}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return}
    at=index
    change:terrain.Change
    switch {
    case add:
        if at,ok=terrain.source_edit_layer_add(&stroke.source);!ok {editor.notify(s,fmt.tprintf("A terrain holds %d edit layers at most",terrain.EDITS_MAX));return}
        change.changed=true
    case remove: change=terrain.source_edit_layer_remove(&stroke.source,index)
    case:
        change=terrain.source_edit_layer_hide(&stroke.source,index,hidden)
        // That of splines is shown again by making it from its splines.
        if change.error==.None && !hidden && stroke.source.edit_layers[index].splines {
            paths,problem:=conform_paths(tool,world)
            if problem!="" {editor.notify(s,problem);stroke_cancel(tool);return}
            conformed:=terrain.source_conform(&stroke.source,paths[:])
            if conformed.error!=.None {change.error=conformed.error}
        }
    }
    if change.error!=.None {edit_error(s,change.error,.Flatten);stroke_cancel(tool);return}
    if !change.changed {return at,true}
    stroke.active=true
    stroke.changed,stroke.dirty_all=true,true
    stroke_end(s,tool,world,assets,label="Terrain edit layer")
    if remove && tool.edit_layer>index {tool.edit_layer=tool.edit_layer==index+1?0:tool.edit_layer-1}
    return at,!stroke.active
}

// The base and the edit layers in Sculpt of a Heightfield.
@(private)
edit_layers_fields :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets) {
    ctx:=s.gui.ctx
    source:=&tool.stroke.source
    count:=int(source.edit_count)
    tool.edit_layer=clamp(tool.edit_layer,0,count)
    kit.section(ctx,"Edit layers","",80)
    if ui.button(ctx,ui.id(ctx,"edit_base"),{label="Base",variant="tab",active=tool.edit_layer==0,width=-1}).clicked {tool.edit_layer=0}
    for i in 0..<count {
        layer:=source.edit_layers[i]
        name:=layer.splines?"Splines":fmt.tprintf("Layer %d",i+1)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
            chosen:=tool.edit_layer==i+1
            if ui.button(ctx,ui.id(ctx,"edit_layer",i+1),{label=name,variant="tab",active=chosen,width=-1}).clicked && !layer.splines && !layer.hidden {tool.edit_layer=i+1}
            shown:=!layer.hidden
            if ui.checkbox(ctx,ui.id(ctx,"edit_shown",i+1),&shown) {
                edit_layer_commit(s,tool,world,assets,i,false,false,!shown)
                if !shown && tool.edit_layer==i+1 {tool.edit_layer=0}
                return
            }
        }
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
        if ui.button(ctx,ui.id(ctx,"edit_add"),{label="Add",variant="field",width=-1,center=true}).clicked {
            if at,ok:=edit_layer_commit(s,tool,world,assets,0,true,false,false);ok {tool.edit_layer=at+1}
        }
        if tool.edit_layer>0 && ui.button(ctx,ui.id(ctx,"edit_remove"),{label="Remove",variant="field",width=-1,center=true}).clicked {
            edit_layer_commit(s,tool,world,assets,tool.edit_layer-1,false,true,false)
        }
    }
    if ui.button(ctx,ui.id(ctx,"conform"),{label="Conform to splines",variant="field",width=-1,center=true}).clicked {terrain_conform(s,tool,world,assets)}
}

@(private)
api_edit_layer :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Edit_Layer_Params)
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    source:=&tool.stroke.source
    if source.kind!=.Heightfield {api.call_fail(call,api.INVALID_PARAMS,"Edit layers are of a Heightfield Terrain");return}
    given:=editor.tool_call_given(call,"layer")
    if !given && (p.remove || editor.tool_call_given(call,"hidden")) {api.call_fail(call,api.INVALID_PARAMS,"Give layer, the edit layer to take out, hide or show");return}
    index:=p.layer-1
    if given && (index<0 || index>=int(source.edit_count)) {api.call_failf(call,api.INVALID_PARAMS,"layer is from 1 to %d, the edit layers of the terrain: omit it to add one",source.edit_count);return}
    s.toast_length=0
    at,done:=edit_layer_commit(s,tool,world,s.app.assets,index,!given,p.remove,p.hidden)
    if !done {editor.tool_call_fail(s,call,"The edit layer could not be changed");return}
    api.call_result(call,Terrain_Edit_Layer_Result)^={int(tool.stroke.source.edit_count),p.remove?0:at+1}
}

@(private)
api_conform :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Conform_Params)
    tool,world,ok:=api_terrain(s,call,p.entity[:])
    if !ok {return}
    if tool.stroke.source.kind!=.Heightfield {api.call_fail(call,api.INVALID_PARAMS,"A Volume does not conform to splines: carve or add along them with terrain.edit");return}
    s.toast_length=0
    changed,splines,done:=terrain_conform(s,tool,world,s.app.assets)
    if !done {editor.tool_call_fail(s,call,"The terrain could not conform to its splines");return}
    api.call_result(call,Terrain_Conform_Result)^={changed,splines}
}

@(private)
edit_layer_param :: proc(s:^editor.Session,call:^api.Call,tool:^Terrain_Tool,layer:int) -> bool {
    tool.edit_layer=0
    if !editor.tool_call_given(call,"edit_layer") || layer==0 {return true}
    source:=&tool.stroke.source
    if source.kind!=.Heightfield || layer<0 || layer>int(source.edit_count) {api.call_failf(call,api.INVALID_PARAMS,"edit_layer is 0 (the base) or from 1 to %d, the edit layers of the terrain: terrain.edit_layer adds one",source.edit_count);return false}
    if l:=source.edit_layers[layer-1];l.hidden || l.splines {api.call_fail(call,api.INVALID_PARAMS,"That edit layer is hidden or made by splines: show it with terrain.edit_layer, or choose another");return false}
    tool.edit_layer=layer
    return true
}

