package terrain_editor

import "core:fmt"
import "core:math"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:std/geom"
import "mirai:editor/kit"
import "mirai:ui"
import "base:runtime"

FIELD_WIDTH :: f32(84) // of the number fields of the panel: a value and its unit
@(rodata) KEY_NAMES := [9]string{"1","2","3","4","5","6","7","8","9"}
@(rodata) FALLOFF_NAMES := [len(geom.Falloff)]string{"Smooth","Sphere","Linear","Sharp","Flat"}
@(rodata) SHAPE_NAMES := [len(Shape_Kind)]string{"Sphere","Capsule","Box","Selected mesh"}
ALPHA_PREVIEW :: 24 // cells on a side of the preview of an alpha

@(step="ui",after="editor_panels")
terrain_panel :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App,input:core.Input) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    tool_ready(tool);ctx:=g.ctx
    tool.active=editor.tool_on(s,"terrain")
    if !tool.active || s.viewport.pick.active {return}
    selected_entity:=history.selection_active(s.selection)
    if !tool.stroke.active {
        terrains:=core.world_table_of(world,terrain.Terrain);worlds:=core.world_table_of(world,core.World_Transform)
        target:=history.selection_has(s.selection,tool.stroke.entity)?tool.stroke.entity:core.NONE
        if terrains!=nil && (selected_entity!=tool.selection || target==core.NONE) && core.has(terrains,selected_entity) {target=selected_entity}
        tool.selection=selected_entity
        if terrains!=nil && worlds!=nil && core.has(terrains,target) {
            _=stroke_prepare(tool,app.assets,app.allocator,terrains,worlds,editor.Pick{entity=target})
        } else if tool.stroke.id!={} {stroke_free(tool)}
    }
    terrain_heightmap_dialogs(s,tool,world,app)
    id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
    panel:=editor.tool_panel(g,id)
    room:=max(ctx.size.y-panel.offset.y-ui.metric(ctx,"margin")-panel.padding[1]-panel.padding[3],ui.metric(ctx,"row"))
    if ui.panel(ctx,id,panel) {
        ui.id_push(ctx,id);defer ui.id_pop(ctx)
        if ui.scroll_area(ctx,ui.id(ctx,"scroll"),&tool.scroll,{height=ui.FIT,max_height=room,gap=panel.gap,padding={0,0,SCROLL_GUTTER,0}}) {
            if tool.stroke.id=={} {
                terrain_choose_panel(s,world)
                kit.section(ctx,"Create","",80)
                terrain_creation_panel(s,tool,world,app)
                return
            }
            kind:=tool.stroke.source.kind
            kit.section(ctx,editor.entity_label(world,tool.stroke.entity),terrain_kind_name(kind),140)
            mode:=tool_mode_index(tool)
            if kit.tabs(ctx,ui.id(ctx,"mode"),mode_names(kind),&mode) {mode_set(s,tool,world,app.assets,mode)}
            switch {
            case tool_painting(tool): terrain_paint_panel(s,tool,world,app)
            case tool_holing(tool):   terrain_holes_panel(s,tool)
            case tool_shaping(tool):  terrain_shapes_panel(s,tool,world,app.assets,app.allocator)
            case:                     terrain_sculpt_panel(s,tool,world,app)
            }
            // The entity of the terrain, as Details shows it, which the panel covers.
            if kit.collapsible(ctx,ui.id(ctx,"entity"),"Entity",&tool.entity_open).open {
                editor.details_build(s,world,editor.tool_panel_inner(g)-SCROLL_GUTTER,room)
            }
        }
    }
}

@(private,rodata) GRID_MODES := [3]string{"Sculpt","Holes","Paint"}
@(private,rodata) SOLID_MODES := [3]string{"Sculpt","Shapes","Paint"}

@(private)
mode_names :: proc(kind:terrain.Source_Kind) -> []string {return kind==.Heightfield?GRID_MODES[:]:SOLID_MODES[:]}

@(private)
tool_mode_index :: proc "contextless" (tool:^Terrain_Tool) -> int {return tool_painting(tool)?2:tool_holing(tool) || tool_shaping(tool)?1:0}

// Sculpt, Holes or Shapes, or Paint, with the first brush of each; Shift and
// the number keys too. A ramp or a shape placed and not applied is applied:
// the work of a drag does not go with a change of mode.
@(private)
mode_set :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,mode:int) {
    if mode==tool_mode_index(tool) {return}
    stroke:=&tool.stroke
    if stroke.active && stroke.pending.kind!=.None && !stroke.pending.placing {pending_apply(s,tool,world,assets)}
    if stroke.active {stroke_cancel(tool)}
    kind:=stroke.source.kind
    switch mode {
    case 0: tool.brush,tool.level,tool.shaping=sculpt_brushes(kind)[0].kind,false,false
    case 1: tool.shaping=kind==.Volume;tool.brush=tool.shaping?.Add:.Hole
    case 2: tool.brush,tool.shaping=.Paint,false
    }
    tool.picking=false
    editor.tool_take(s,"terrain")
}

@(private)
terrain_sculpt_panel :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,app:^host.App) {
    ctx:=s.gui.ctx
    stroke:=&tool.stroke
    kind:=stroke.source.kind
    brushes:=sculpt_brushes(kind)
    names:[9]string
    chosen:=-1
    for brush,i in brushes {
        names[i]=brush.name
        if brush.kind==tool.brush && brush.level==tool.level && !editor.tool_aside(s,"terrain") {chosen=i}
    }
    if clicked:=choice_grid(ctx,ui.id(ctx,"brushes"),names[:len(brushes)],chosen,3);clicked>=0 && !stroke.active {brush_choose(s,tool,clicked)}
    if chosen>=0 {kit.section(ctx,brushes[chosen].name,"",80)}
    brush:=tool.brush
    falloff:=brush!=.Add && brush!=.Carve
    brush_fields(s,tool,brush_strong(brush),falloff,falloff && brush!=.Ramp)
    if tool.level {
        height:=f64(tool.height)
        if kit.property(ctx,"Height") {
            if ui.number_field(ctx,ui.id(ctx,"height"),&height,{width=ui.fixed(FIELD_WIDTH),min=-f64(terrain.HEIGHT_LIMIT),max=f64(terrain.HEIGHT_LIMIT),has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.height=f32(height)}
            // The next press takes the height under it, as Ctrl and a press do.
            if ui.icon_button(ctx,ui.id(ctx,"pick"),.Target,variant="tab",tip="Pick height (Ctrl click)",active=tool.picking).clicked {tool.picking=!tool.picking}
        }
    }
    if brush==.Flatten || brush==.Smooth || brush==.Terrace || brush==.Noise {
        way:=int(tool.way)
        if kit.property(ctx,"Way") {if kit.tabs(ctx,ui.id(ctx,"way"),{"Both","Raise","Lower"},&way) {tool.way=terrain.Brush_Way(way)}}
    }
    if (brush==.Raise || brush==.Lower) && kind==.Heightfield {
        if kit.property(ctx,"To the press") {
            ui.checkbox(ctx,ui.id(ctx,"capped"),&tool.capped)
            editor.key_hint(ctx,"Alt")
        }
    }
    if brush==.Terrace {
        interval,riser:=f64(tool.interval),f64(tool.riser)
        if kit.property(ctx,"Step") {if ui.number_field(ctx,ui.id(ctx,"interval"),&interval,{width=ui.fixed(FIELD_WIDTH),min=0.01,max=1000,has_min=true,has_max=true,speed=0.02,unit="m"}).changed {tool.interval=f32(interval)}}
        if kit.property(ctx,"Riser") {if ui.number_field(ctx,ui.id(ctx,"riser"),&riser,{width=ui.fixed(FIELD_WIDTH),min=0,max=1,has_min=true,has_max=true,speed=0.005,decimals=2}).changed {tool.riser=f32(riser)}}
    }
    if brush==.Noise {
        scale:=f64(tool.noise_scale)
        if kit.property(ctx,"Scale") {if ui.number_field(ctx,ui.id(ctx,"noise"),&scale,{width=ui.fixed(FIELD_WIDTH),min=0.1,max=10000,has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.noise_scale=f32(scale)}}
    }
    if brush==.Ramp {
        sides:=f64(tool.ramp_sides)
        if kit.property(ctx,"Sides") {if ui.number_field(ctx,ui.id(ctx,"sides"),&sides,{width=ui.fixed(FIELD_WIDTH),min=0,max=500,has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.ramp_sides=f32(sides)}}
        if p:=&stroke.pending;stroke.active && p.kind==.Ramp && !p.placing {
            a,b:=f64(p.a.y),f64(p.b.y)
            if kit.property(ctx,"Height A") {if ui.number_field(ctx,ui.id(ctx,"ramp_a"),&a,{width=ui.fixed(FIELD_WIDTH),speed=0.05,unit="m"}).changed {p.a.y=f32(a)}}
            if kit.property(ctx,"Height B") {if ui.number_field(ctx,ui.id(ctx,"ramp_b"),&b,{width=ui.fixed(FIELD_WIDTH),speed=0.05,unit="m"}).changed {p.b.y=f32(b)}}
            pending_buttons(s,tool,world,app.assets)
        }
    }
    if kind==.Heightfield {
        if brush!=.Ramp {
            axis:=int(tool.axis)
            if kit.property(ctx,"Axis") {if kit.tabs(ctx,ui.id(ctx,"axis"),{"Free","X","Z"},&axis) {tool.axis=Stroke_Axis(axis)}}
        }
        slope_fields(s,tool)
        kit.section(ctx,"Heightmap","",80)
        heightmap_fields(s,tool)
        if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=4}) {
            if ui.button(ctx,ui.id(ctx,"heightmap_import"),{label="Import",variant="field",width=-1,center=true}).clicked {heightmap_dialog(s,tool,app,REIMPORT_DIALOG)}
            if ui.button(ctx,ui.id(ctx,"heightmap_export"),{label="Export",variant="field",width=-1,center=true}).clicked {heightmap_dialog(s,tool,app,EXPORT_DIALOG)}
        }
        kit.section(ctx,"Size",fmt.tprintf("%.0f × %.0f m",f32(stroke.source.samples.x-1)*stroke.source.cell,f32(stroke.source.samples.z-1)*stroke.source.cell),140)
        resize_fields(s,tool,world,app.assets)
    } else {
        kit.section(ctx,"Mesh","",80)
        if ui.button(ctx,ui.id(ctx,"export_mesh"),{label="Save surface as mesh",variant="field",width=-1,center=true}).clicked {terrain_surface_mesh(s,tool,app.assets,app.allocator)}
    }
}


// Radius, the strength of what has one, the falloff of what fades out, the
// pressure of a pen and, where it takes one, the shape of an alpha.
@(private)
brush_fields :: proc(s:^editor.Session,tool:^Terrain_Tool,strength,falloff:bool,alpha:=false) {
    ctx:=s.gui.ctx
    b:=brush_of(tool)
    radius:=f64(b.radius)
    if kit.property(ctx,"Radius") {
        if ui.number_field(ctx,ui.id(ctx,"radius"),&radius,{width=ui.fixed(FIELD_WIDTH),min=f64(RADIUS_MIN),max=f64(RADIUS_MAX),has_min=true,has_max=true,speed=0.05,decimals=2,unit="m"}).changed {b.radius=f32(radius)}
        editor.key_hint(ctx,"F")
    }
    if strength {
        percent:=f64(b.strength)*100
        if kit.property(ctx,"Strength") {
            if ui.number_field(ctx,ui.id(ctx,"strength"),&percent,{width=ui.fixed(FIELD_WIDTH),min=0,max=100,has_min=true,has_max=true,speed=0.5,decimals=0,unit="%"}).changed {b.strength=f32(percent/100)}
            editor.key_hint(ctx,"Shift F")
        }
        if kit.property(ctx,"Pen pressure") {ui.checkbox(ctx,ui.id(ctx,"pressure"),&b.pressure)}
    }
    if falloff {
        chosen:=int(b.falloff)
        // The names of the curves need the whole width of the panel.
        if kit.tabs(ctx,ui.id(ctx,"falloff"),FALLOFF_NAMES[:],&chosen) {b.falloff=geom.Falloff(chosen)}
        hardness:=f64(b.hardness)
        if kit.property(ctx,"Hardness") {if ui.number_field(ctx,ui.id(ctx,"hardness"),&hardness,{width=ui.fixed(FIELD_WIDTH),min=0,max=0.95,has_min=true,has_max=true,speed=0.005,decimals=2}).changed {b.hardness=f32(hardness)}}
    }
    if alpha {alpha_fields(s,tool)}
}

// The alpha of the brush, a preview of it, and its turn.
@(private)
alpha_fields :: proc(s:^editor.Session,tool:^Terrain_Tool) {
    ctx:=s.gui.ctx
    b:=brush_of(tool)
    alphas_ready(&tool.alphas)
    names:=make([]string,len(tool.alphas.names)+1,context.temp_allocator)
    names[0]="Disc"
    copy(names[1:],tool.alphas.names[:])
    chosen:=clamp(int(b.alpha),0,len(names)-1)
    if kit.property(ctx,"Shape") {if ui.dropdown(ctx,ui.id(ctx,"alpha"),{list=names},&chosen,{width=-1}) {b.alpha=u8(chosen)}}
    a:=alpha_of(tool,b)
    if a==nil {return}
    side:=editor.tool_panel_inner(s.gui)-SCROLL_GUTTER
    side=min(side,96)
    editor.drawing(s.gui,ui.id(ctx,"alpha_preview"),ui.fixed(side),ui.fixed(side),alpha_draw,a)
    turn:=f64(math.to_degrees(b.turn))
    if kit.property(ctx,"Turn") {if ui.number_field(ctx,ui.id(ctx,"turn"),&turn,{width=ui.fixed(FIELD_WIDTH),min=-360,max=360,has_min=true,has_max=true,speed=0.5,decimals=0,unit="°"}).changed {b.turn=f32(math.to_radians(turn))}}
    if kit.property(ctx,"Turn at random") {ui.checkbox(ctx,ui.id(ctx,"spin"),&b.spin)}
}

@(private)
alpha_draw :: proc(ctx:^ui.Context,rect:ui.Rect,user:rawptr) {
    a:=cast(^terrain.Brush_Alpha)user
    cell:=rect.w/ALPHA_PREVIEW
    for z in 0..<ALPHA_PREVIEW {for x in 0..<ALPHA_PREVIEW {
        offset:=([2]f32{f32(x),f32(z)}+0.5)/ALPHA_PREVIEW*2-1
        v:=terrain.alpha_sample(a^,offset,1,0)
        shade:=u8(clamp(v,0,1)*230+18)
        ui.draw_rect(ctx,{rect.x+f32(x)*cell,rect.y+f32(z)*cell,cell+0.5,cell+0.5},{shade,shade,shade,255})
    }}
}

// Where a brush of a Heightfield touches by the slope there.
@(private)
slope_fields :: proc(s:^editor.Session,tool:^Terrain_Tool) {
    ctx:=s.gui.ctx
    b:=brush_of(tool)
    if kit.property(ctx,"Slope filter") {ui.checkbox(ctx,ui.id(ctx,"slope_filter"),&b.slope_filter)}
    if !b.slope_filter {return}
    low,high:=f64(math.to_degrees(b.slope.x)),f64(math.to_degrees(b.slope.y))
    if kit.property(ctx,"Slope from") {if ui.number_field(ctx,ui.id(ctx,"slope_low"),&low,{width=ui.fixed(FIELD_WIDTH),min=0,max=90,has_min=true,has_max=true,speed=0.5,decimals=0,unit="°"}).changed {b.slope.x=f32(math.to_radians(low))}}
    if kit.property(ctx,"Slope to") {if ui.number_field(ctx,ui.id(ctx,"slope_high"),&high,{width=ui.fixed(FIELD_WIDTH),min=0,max=90,has_min=true,has_max=true,speed=0.5,decimals=0,unit="°"}).changed {b.slope.y=f32(math.to_radians(high))}}
    if kit.property(ctx,"Outside it") {ui.checkbox(ctx,ui.id(ctx,"slope_invert"),&b.slope_invert)}
}

@(private)
terrain_shapes_panel :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,allocator:runtime.Allocator) {
    ctx:=s.gui.ctx
    stroke:=&tool.stroke
    shown:=editor.tool_aside(s,"terrain")?-1:int(tool.shape)
    if clicked:=choice_grid(ctx,ui.id(ctx,"shapes"),SHAPE_NAMES[:],shown,2);clicked>=0 && !stroke.active {tool.shape=Shape_Kind(clicked);editor.tool_take(s,"terrain")}
    mode:=tool.brush==.Carve?1:0
    if kit.property(ctx,"Mode") {if kit.tabs(ctx,ui.id(ctx,"shape_mode"),{"Add","Carve"},&mode) {tool.brush=mode==1?.Carve:.Add}}
    if tool.shape!=.Selected {brush_fields(s,tool,false,false)}
    blend:=f64(tool.blend)
    if kit.property(ctx,"Blend") {if ui.number_field(ctx,ui.id(ctx,"blend"),&blend,{width=ui.fixed(FIELD_WIDTH),min=0,max=100,has_min=true,has_max=true,speed=0.02,unit="m"}).changed {tool.blend=f32(blend)}}
    if tool.shape==.Selected {
        if ui.button(ctx,ui.id(ctx,"operand"),{label="Apply and consume selected mesh",variant="field",width=-1,center=true}).clicked {terrain_operand(s,tool,world,assets,allocator)}
        return
    }
    if stroke.active && stroke.pending.kind==.Shape && !stroke.pending.placing {pending_buttons(s,tool,world,assets)}
}

@(private)
pending_buttons :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets) {
    ctx:=s.gui.ctx
    if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
        if ui.button(ctx,ui.id(ctx,"apply"),{label="Apply",detail="Enter",variant="accent",width=-1,center=true}).clicked {pending_apply(s,tool,world,assets)}
        if ui.button(ctx,ui.id(ctx,"cancel"),{label="Cancel",detail="Esc",variant="field",width=-1,center=true}).clicked {stroke_cancel(tool)}
    }
}

// Buttons of names in rows of columns, each with the number key that chooses
// it; the one clicked, or -1.
@(private)
choice_grid :: proc(ctx:^ui.Context,id:ui.Id,names:[]string,selected,columns:int) -> (clicked:int) {
    clicked=-1
    ui.id_push(ctx,id);defer ui.id_pop(ctx)
    for row:=0;row<len(names);row+=columns {
        height:=ui.metric(ctx,"control")
        if kit.segments(ctx,ui.GROW,height) {
            for i in row..<min(row+columns,len(names)) {
                if ui.button(ctx,ui.id(ctx,"choice",i+1),{label=names[i],detail=KEY_NAMES[i],variant="tab",active=i==selected,width=-1,height=height-4,size=ui.metric(ctx,"font_small")}).clicked {clicked=i}
            }
            for _ in max(len(names),row)..<row+columns {ui.spacer(ctx,-1,0)}
        }
    }
    return
}

// Without a terrain to sculpt the tool offers those of the scene, and to
// create one.
@(private)
terrain_choose_panel :: proc(s:^editor.Session,world:core.World_Ref) {
    ctx:=s.gui.ctx
    terrains:=core.world_table_of(world,terrain.Terrain)
    if terrains==nil || core.count(terrains)==0 {return}
    kit.section(ctx,"Terrains","",80)
    table:=core.read(terrains)
    for i in 0..<core.count(table) {
        e:=core.entity_at(table,i)
        if ui.button(ctx,ui.id(ctx,"terrain",core.entity_index(e)+1),{label=editor.entity_label(world,e),icon=ui.icon_user(u8(editor.User_Icon.Terrain)),variant="field",width=-1}).clicked {history.selection_set(s.selection,{e})}
    }
}
