package terrain_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"
import "mirai:ui"

@(private)
tool_painting :: proc "contextless" (t:^Terrain_Tool) -> bool {return t.brush==.Paint || t.brush==.Erase}
@(private)
tool_holing :: proc "contextless" (t:^Terrain_Tool) -> bool {return t.brush==.Hole || t.brush==.Fill}

// Hole cuts the cells under the brush out of a Heightfield; Fill gives them back.
@(private)
terrain_holes_panel :: proc(s:^editor.Session,tool:^Terrain_Tool) {
    ctx:=s.gui.ctx
    selected:=-1 if editor.tool_aside(s,"terrain") else 1 if tool.brush==.Fill else 0
    if ui.tabs(ctx,ui.id(ctx,"holes"),{"Hole","Fill"},&selected) {tool.brush=selected==1?.Fill:.Hole;editor.tool_take(s,"terrain")}
    brush_fields(s,tool,false,false,true)
    slope_fields(s,tool)
}

// What the selected terrain shows: the materials of the slots of a Mesh past
// slot 0 and the layers slot 0 shows, each with its thumbnail, and under the
// list what the chosen one has; the brush paints it. The program that blends
// them shows only when it is not the one of the plugin.
@(private)
terrain_paint_panel :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App) {
    ctx:=s.gui.ctx
    source:=&tool.stroke.source
    count:=int(source.layer_count)
    tool.layer=clamp(tool.layer,0,count-1)
    if len(source.slots)>0 {
        ui.section(ctx,"Materials","",80)
        for material,i in source.slots {
            if chosen,changed:=material_field(s,u64(i+1),fmt.tprintf("Slot %d",i+1),material);changed {terrain_material_commit(s,tool,world,app,i+1,chosen)}
        }
    }
    add,remove:=layers_heading(ctx,count)
    if source.layers_material!={} {if material,changed:=material_field(s,0x200,"Blend",source.layers_material);changed {terrain_material_commit(s,tool,world,app,LAYERS_SLOT,material)}}
    for i in 0..<count {
        if editor.asset_list_row_begin(s,ui.id(ctx,"layer",i+1),source.layers[i].material,asset.KIND_MATERIAL,layer_name(app.assets,source.layers[i],i),i==tool.layer).clicked {tool.layer=i}
        editor.asset_list_row_end(s)
    }
    if add && count<terrain.LAYERS_MAX && terrain_layer_commit(s,tool,world,app,count,terrain.LAYER_DEFAULT,false) {tool.layer=count}
    if remove && count>1 {terrain_layer_commit(s,tool,world,app,tool.layer,{},true)}
    count=int(source.layer_count)
    tool.layer=clamp(tool.layer,0,count-1)
    layer:=source.layers[tool.layer]
    if layer_fields(s,tool,&layer) {terrain_layer_commit(s,tool,world,app,tool.layer,layer,false)}
    if source.kind==.Volume {terrain_interior_panel(s,tool,world,app)}
    ui.section(ctx,"Brush","",80)
    selected:=-1 if editor.tool_aside(s,"terrain") else 1 if tool.brush==.Erase else 0
    if ui.tabs(ctx,ui.id(ctx,"paint"),{"Paint","Erase"},&selected) {tool.brush=selected==1?.Erase:.Paint;editor.tool_take(s,"terrain")}
    brush_fields(s,tool,true,true,tool.stroke.source.kind!=.Mesh)
    if tool.brush==.Paint {
        if ui.property(ctx,"Up to a weight") {ui.checkbox(ctx,ui.id(ctx,"toward"),&tool.toward)}
        if tool.toward {
            percent:=f64(tool.target)*100
            if ui.property(ctx,"Weight") {if ui.number_field(ctx,ui.id(ctx,"target"),&percent,{width=ui.fixed(FIELD_WIDTH),min=0,max=100,has_min=true,has_max=true,speed=0.5,decimals=0,unit="%"}).changed {tool.target=f32(percent/100)}}
        }
    }
    if tool.stroke.source.kind==.Heightfield {slope_fields(s,tool)}
}

// The heading of the layers, as a section: how many of the most it has, and
// the buttons that add one and take the chosen one out, while another stays.
@(private)
layers_heading :: proc(ctx:^ui.Context,count:int) -> (add,remove:bool) {
    th:=&ctx.theme
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(22),gap=8,align_y=.End}) {
        ui.label(ctx,"Layers",th.font_label,th.text_faint)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(9),align_y=.Center}) {ui.divider(ctx)}
        note:=fmt.tprintf("%d of %d",count,terrain.LAYERS_MAX)
        ui.label(ctx,note,th.font_label,th.text_muted,ui.text_width(&ctx.font,note,th.font_label)+1)
        add=ui.icon_button(ctx,ui.id(ctx,"add_layer"),.Plus,18,disabled=count>=terrain.LAYERS_MAX).clicked
        remove=ui.icon_button(ctx,ui.id(ctx,"remove_layer"),.Cross,18,disabled=count<=1).clicked
    }
    return
}

@(private)
layer_name :: proc(a:^host.Assets,layer:terrain.Terrain_Layer,index:int) -> string {
    if a!=nil {
        if file,found:=asset.registry_find(&a.registry,layer.material);found {return filepath.stem(filepath.base(file.path))}
    }
    return fmt.tprintf("Layer %d",index+1)
}

// A material of the terrain, as the inspector shows a field of one: its
// thumbnail, the list of the materials, Find and what is dropped on it.
@(private)
Material_Field :: struct {material:base.Asset_Id}

@(private)
material_field :: proc(s:^editor.Session,key:u64,label:string,material:base.Asset_Id) -> (chosen:base.Asset_Id,changed:bool) {
    value,defaults:=Material_Field{material},Material_Field{}
    changed=editor.held_field_row(s,{key=u64(PANEL_SCOPE)<<32|key+1,info=type_info_of(Material_Field),value=&value,defaults=&defaults},"material",label)
    return value.material,changed && value.material!=material
}

// The material, tiling, height blend and rule of a layer; true once a value
// is settled (an edit or a scrub ended).
@(private)
layer_fields :: proc(s:^editor.Session,tool:^Terrain_Tool,layer:^terrain.Terrain_Layer) -> (changed:bool) {
    ctx:=s.gui.ctx
    settled :: proc(result:ui.Number_Result) -> bool {return result.ended && !result.cancelled || result.changed && !result.scrubbing && !result.editing}
    if material,picked:=material_field(s,u64(0x100+tool.layer),"Material",layer.material);picked {layer.material=material;changed=true}
    tiling,blend:=f64(layer.tiling),f64(layer.height_blend)
    if ui.property(ctx,"Tiling") {
        result:=ui.number_field(ctx,ui.id(ctx,"tiling"),&tiling,{min=0.01,max=10000,has_min=true,has_max=true,speed=0.05,unit="m"})
        if result.changed {layer.tiling=f32(tiling)}
        changed|=settled(result)
    }
    if ui.property(ctx,"Height blend") {
        result:=ui.number_field(ctx,ui.id(ctx,"blend"),&blend,{min=0,max=1,has_min=true,has_max=true,speed=0.01})
        if result.changed {layer.height_blend=f32(blend)}
        changed|=settled(result)
    }
    if tool.stroke.source.kind==.Heightfield {
        if ui.property(ctx,"Displacement") {
            displacement:=f64(layer.displacement)
            result:=ui.number_field(ctx,ui.id(ctx,"displacement"),&displacement,{min=0,max=f64(terrain.DISPLACEMENT_MAX),has_min=true,has_max=true,speed=0.005,decimals=2,unit="m"})
            if result.changed {layer.displacement=f32(displacement)}
            changed|=settled(result)
        }
    }
    if ui.property(ctx,"Automatic") {if ui.checkbox(ctx,ui.id(ctx,"auto"),&layer.auto.enabled) {changed=true}}
    if !layer.auto.enabled {return}
    numbers:=[6]f64{f64(layer.auto.slope.x)*180/math.PI,f64(layer.auto.slope.y)*180/math.PI,f64(layer.auto.height.x),f64(layer.auto.height.y),f64(layer.auto.softness.x)*180/math.PI,f64(layer.auto.softness.y)}
    labels:=[6]string{"Slope from","Slope to","Height from","Height to","Slope softness","Height softness"}
    for label,i in labels {
        angle:=i==0 || i==1 || i==4
        if !ui.property(ctx,label) {continue}
        low,high:=f64(0),f64(90)
        if !angle {low,high=f64(-terrain.HEIGHT_LIMIT),f64(terrain.HEIGHT_LIMIT)}
        if i==5 {low=0}
        result:=ui.number_field(ctx,ui.id(ctx,"auto",i+1),&numbers[i],{min=low,max=high,has_min=true,has_max=true,speed=angle?0.5:0.1,unit=angle?"°":"m"})
        if result.changed {
            value:=f32(angle?numbers[i]*math.PI/180:numbers[i])
            switch i {
            case 0:layer.auto.slope.x=min(value,layer.auto.slope.y)
            case 1:layer.auto.slope.y=max(value,layer.auto.slope.x)
            case 2:layer.auto.height.x=min(value,layer.auto.height.y)
            case 3:layer.auto.height.y=max(value,layer.auto.height.x)
            case 4:layer.auto.softness.x=value
            case 5:layer.auto.softness.y=value
            }
        }
        changed|=settled(result)
    }
    return
}

// The slot of terrain_material_commit that is the material of the layers.
@(private)
LAYERS_SLOT :: -1

// Sets the material of a slot of a Mesh past slot 0, which shows the layers,
// or the one that blends them, as one step of undo.
@(private)
terrain_material_commit :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App,slot:int,material:base.Asset_Id) -> bool {
    stroke:=&tool.stroke
    if stroke.active || stroke.id=={} || slot<LAYERS_SLOT || slot==0 || slot>len(stroke.source.slots) {return false}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return false}
    if slot==LAYERS_SLOT {stroke.source.layers_material=material} else {stroke.source.slots[slot-1]=material}
    stroke.changed=true;stroke.dirty_all=true
    stroke_end(s,tool,world,app,label="Terrain material")
    return true
}

// What a Volume holds under its surface, as its layers: the rows of the
// interior the tool holds, and Apply writes it into every sample.
@(private)
terrain_interior_panel :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App) {
    ctx:=s.gui.ctx
    stroke:=&tool.stroke
    of:=Interior_Of{stroke.id,stroke.revision}
    if tool.interior_of!=of {tool.interior,tool.interior_of=stroke.source.interior,of}
    ui.section(ctx,"Interior","",80)
    defaults:terrain.Interior
    held:=editor.Held_Values{key=u64(PANEL_SCOPE)<<32|0x300,info=type_info_of(terrain.Interior),value=&tool.interior,defaults=&defaults}
    for name in ([?]string{"strata_count","strata","vein_count","veins","wave","wave_scale","seed"}) {editor.held_field_row(s,held,name)}
    valid:=terrain.interior_valid(tool.interior,stroke.source.layer_count)
    if ui.button(ctx,ui.id(ctx,"interior_apply"),{label="Apply",style=.Field,width=-1,center=true,disabled=!valid}).clicked {
        if !terrain_interior_commit(s,tool,world,app,tool.interior) {return}
        tool.interior_of={stroke.id,stroke.revision}
    }
}

// Sets the interior of the selected Volume and writes it into its samples, as
// one step of undo.
@(private)
terrain_interior_commit :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App,interior:terrain.Interior) -> bool {
    stroke:=&tool.stroke
    if stroke.active || stroke.id=={} {return false}
    if stroke.source.kind!=.Volume {editor.notify(s,"Only a Volume has an interior");return false}
    if !terrain.interior_valid(interior,stroke.source.layer_count) {editor.notify(s,"The interior names a layer the terrain does not have, or its depths are out of order");return false}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return false}
    previous:=stroke.source.interior
    stroke.source.interior=interior
    if !terrain.source_interior_apply(&stroke.source) {stroke.source.interior=previous;editor.notify(s,"Out of memory for the interior of the terrain");return false}
    stroke.changed=true;stroke.dirty_all=true
    stroke_end(s,tool,world,app,label="Terrain interior")
    return true
}

// Sets, adds or removes a layer of the terrain of the stroke as one step of undo.
@(private)
terrain_layer_commit :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App,index:int,layer:terrain.Terrain_Layer,remove:bool) -> bool {
    stroke:=&tool.stroke
    if stroke.active || stroke.id=={} {return false}
    if !stroke_baseline(tool) {editor.notify(s,"The terrain history could not be stored");return false}
    done:=remove?terrain.source_layer_remove(&stroke.source,index):terrain.source_layer_set(&stroke.source,index,layer)
    if !done {editor.notify(s,remove?"A terrain keeps one layer at least":"The terrain layer is invalid");return false}
    stroke.changed=true;stroke.dirty_all=true
    stroke_end(s,tool,world,app,label=remove?"Remove terrain layer":"Terrain layer")
    return true
}
