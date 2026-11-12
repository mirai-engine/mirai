package terrain_editor

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/kit"
import volume "mirai:engine/volume"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The edit layers of a Heightfield in Sculpt and through the API: the base
// and each layer of sculpting, which strokes take when it is chosen, shown or
// hidden, added and taken out, each one step of undo. The layer of splines is
// derived: before the history records a gesture, every Heightfield whose
// splines with a Terrain_Conform changed takes them again (terrain_follow),
// and that change joins the step of the gesture, so its undo takes both back.

@(storage)
Terrain_Follow :: struct {provider:editor.Edit_Follow_Provider}

TERRAIN_FOLLOW_DEFAULT :: Terrain_Follow{provider={follow=terrain_follow}}

Edit_Layer_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity of a Heightfield Terrain"`,
    layer:int `mirai:"optional,min=1,max=8,label=The edit layer to change or take out, from the lowest; omitted adds one on top (under that of splines)"`,
    remove:bool `mirai:"optional,label=Takes the layer out, and what it adds out of the ground"`,
    hidden:bool `mirai:"optional,label=Hides the layer, taking what it adds out of the ground until it is shown"`,
}

Terrain_Edit_Layer_Result :: struct {
    layers:int,
    layer:int `mirai:"optional"`,
}

// What the splines with a Terrain_Conform of a world give the terrain of the
// stroke, in the space of its source: curves sampled at its spacing that
// reach it, from temp memory, and the hash of all of them. problem says what
// one of them names wrong, which paints nothing.
@(private)
conform_paths :: proc(tool:^Terrain_Tool,world:core.World_Ref) -> (paths:[dynamic]terrain.Conform_Path,hash:u64,problem:string) {
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
            if layer<0 {problem="A Terrain_Conform paints a material that is no layer of the terrain under it: add it with terrain.layer, or clear paint"}
        }
        // At the spacing of the terrain, so its bed meets every sample.
        samples:=make([]mm.Path_Point,RIBBON_SAMPLES,context.temp_allocator)
        count:=volume.spline_sample(&spline,source.cell*scale,samples)
        if count<2 {continue}
        path:=terrain.Conform_Path{points=samples[:count],depth=conform.depth/scale,sides=max(conform.sides,0)/scale,smooth=max(conform.smooth,0)/scale,layer=layer}
        low,high:=[2]f32{max(f32),max(f32)},[2]f32{-max(f32),-max(f32)}
        for &p in path.points {
            world_point:=mm.transform_point(place.transform,p.position)
            p.position=local_of(tool,world_point)
            p.width=p.width*abs(place.transform.scale.x)/scale
            reach:=p.width*0.5+path.sides
            low,high=linalg.min(low,p.position.xz-reach),linalg.max(high,p.position.xz+reach)
        }
        // One that does not reach the terrain leaves it as it is.
        a,b:=terrain.source_box(source,{},{int(source.samples.x)-1,0,int(source.samples.z)-1})
        if high.x<a.x || low.x>b.x || high.y<a.z || low.y>b.z {continue}
        append(&paths,path)
        hash=base.hash64(mem.slice_to_bytes(path.points),hash)
        settings:=[4]f32{path.depth,path.sides,path.smooth,f32(path.layer)}
        hash=base.hash64(mem.slice_to_bytes(settings[:]),hash)
    }
    // None reaching it is no layer of splines: the hash of a terrain without one.
    if len(paths)==0 {hash=0} else if hash==0 {hash=1}
    return
}

@(private) RIBBON_SAMPLES :: 4096

// The editor's hook before it records a gesture of the edited scene.
@(private)
terrain_follow :: proc(s:^editor.Session) {
    tool:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Terrain_Tool)
    if tool==nil || s.app==nil || s.app.assets==nil {return}
    tool_ready(tool)
    terrain_splines_follow(s,tool,editor.edited_world(s),s.app.assets)
}

// Every Heightfield whose splines with a Terrain_Conform are not those its
// layer of splines was made from takes them again, inside the open gesture.
// Which terrains to look at comes from what the runtime holds of them and
// where the splines are, so a gesture far from any reads no source.
terrain_splines_follow :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets) {
    terrains:=core.world_table_of(world,terrain.Terrain)
    places:=core.world_table_of(world,core.World_Transform)
    if terrains==nil || places==nil || tool.stroke.active {return}
    data:=core.world_storage_of(world,terrain.Terrain_Data)
    reaches:=make([dynamic]mm.Aabb,context.temp_allocator)
    if conforms,splines:=core.world_table_of(world,terrain.Terrain_Conform),core.world_table_of(world,volume.Spline);conforms!=nil && splines!=nil {
        for row in 0..<core.count(conforms) {
            e:=core.entity_at(conforms,row)
            spline,has:=core.get(splines,e)
            place,placed:=core.get(places,e)
            if !has || !placed {continue}
            if reach,ok:=volume.spline_reach(&spline,place.transform);ok {append(&reaches,reach)}
        }
    }
    owners:=make([dynamic]core.Entity,context.temp_allocator)
    for marker,row in terrains.values[:core.count(terrains)] {
        e:=core.entity_at(terrains,row)
        place,placed:=core.get(places,e)
        if !placed {continue}
        held:=data!=nil?terrain.terrain_source(core.ref(data),marker.source):nil
        // A source the runtime has not read yet is looked at as one with splines.
        look:=held==nil || held.conform!=0
        if !look && held.kind==.Heightfield {
            a,b:=terrain.source_box(held,{},{int(held.samples.x)-1,0,int(held.samples.z)-1})
            box:=mm.aabb_transform(mm.Aabb{min={a.x,-terrain.HEIGHT_LIMIT,a.z},max={b.x,terrain.HEIGHT_LIMIT,b.z}},mm.transform_matrix(place.transform))
            for reach in reaches {if box.min.x<=reach.max.x && box.max.x>=reach.min.x && box.min.z<=reach.max.z && box.max.z>=reach.min.z {look=true;break}}
        }
        if look {append(&owners,e)}
    }
    for e in owners {
        if !stroke_prepare(tool,assets,s.app.allocator,terrains,places,editor.Pick{entity=e}) {continue}
        stroke:=&tool.stroke
        if stroke.source.kind!=.Heightfield {continue}
        paths,hash,problem:=conform_paths(tool,world)
        if hash==stroke.source.conform {continue}
        if problem!="" {editor.notify(s,problem)}
        if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");continue}
        change:=terrain.source_conform(&stroke.source,paths[:])
        if change.error!=.None {edit_error(s,change.error,.Flatten);stroke_cancel(tool);continue}
        stroke.source.conform=hash
        stroke.active=true
        if change.changed {stroke_changed(stroke,change)}
        stroke.changed,stroke.dirty_all=true,true
        // Inside the open gesture: its step takes the revision of the terrain too.
        stroke_end(s,tool,world,assets,label="Conform to splines")
    }
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
    case: change=terrain.source_edit_layer_hide(&stroke.source,index,hidden)
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
        // That of splines follows its splines: it is shown, never chosen.
        if layer.splines {
            ui.label(ctx,name,ui.metric(ctx,"font"),ui.tone(ctx,"text_muted"))
            continue
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
            chosen:=tool.edit_layer==i+1
            if ui.button(ctx,ui.id(ctx,"edit_layer",i+1),{label=name,variant="tab",active=chosen,width=-1}).clicked && !layer.hidden {tool.edit_layer=i+1}
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
    if given && source.edit_layers[index].splines {api.call_fail(call,api.INVALID_PARAMS,"That is the layer of splines, which follows the splines with a Terrain_Conform over the terrain: move, change or delete those instead");return}
    s.toast_length=0
    at,done:=edit_layer_commit(s,tool,world,s.app.assets,index,!given,p.remove,p.hidden)
    if !done {editor.tool_call_fail(s,call,"The edit layer could not be changed");return}
    api.call_result(call,Terrain_Edit_Layer_Result)^={int(tool.stroke.source.edit_count),p.remove?0:at+1}
}

@(private)
edit_layer_param :: proc(s:^editor.Session,call:^api.Call,tool:^Terrain_Tool,layer:int) -> bool {
    tool.edit_layer=0
    if !editor.tool_call_given(call,"edit_layer") || layer==0 {return true}
    source:=&tool.stroke.source
    if source.kind!=.Heightfield || layer<0 || layer>int(source.edit_count) {api.call_failf(call,api.INVALID_PARAMS,"edit_layer is 0 (the base) or from 1 to %d, the edit layers of the terrain: terrain.edit_layer adds one",source.edit_count);return false}
    if l:=source.edit_layers[layer-1];l.hidden || l.splines {api.call_fail(call,api.INVALID_PARAMS,"That edit layer is hidden or is the layer of splines, which follows its splines: show it with terrain.edit_layer, or choose another");return false}
    tool.edit_layer=layer
    return true
}

