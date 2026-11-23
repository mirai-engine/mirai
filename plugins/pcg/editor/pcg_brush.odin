package pcg_editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:editor/kit"
import "mirai:host"
import mm "mirai:std/math"
import "mirai:ui"
import pcg "plugins:pcg/runtime"

// The density brush of the PCG tool: Paint raises toward all of it the
// density the painted cells of the selected Pcg_Graph keep under the ring,
// Erase lowers it toward none, by strength at each touch and fading over the
// falloff of the radius; Ctrl turns one into the other. [ and ] change the
// radius, F drags it and Shift F the strength. The cells under the ring ask
// the runtime for their ground (pcg.ground_request); the stroke shows as it
// goes through the file in the memory of the registry, and is one step of
// undo when the button is let go. The panel of the tool also shows the rows
// of the layers of the source.

Brush_Mode :: enum u8 {Paint,Erase}
@(rodata) MODE_NAMES := [Brush_Mode]string{.Paint="Paint",.Erase="Erase"}
@(rodata) MODE_KEYS := [Brush_Mode]core.Key{.Paint=.One,.Erase=.Two}
TOOL_KEYS :: core.Keys{.F,.Left_Bracket,.Right_Bracket,.One,.Two}
RADIUS_MIN :: f32(0.5)
RADIUS_MAX :: f32(500)
RADIUS_STEP :: f32(1.15)  // what [ and ] multiply the radius by
STROKE_SPACING :: f32(0.5) // a drag touches at least every this part of the radius
STROKE_TOUCHES_MAX :: 16
BRUSH_RATE :: 30           // touches a second at most, each with the time it waited
RING_SEGMENTS :: 64
FIELD_WIDTH :: f32(84)

Brush :: struct {
    mode:Brush_Mode,
    radius:f32,   // m in the world
    strength:f32, // of the way to the value a touch goes, 0 to 1
    falloff:f32,  // of the radius over which a touch fades out, 0 to 1
}
BRUSH_DEFAULT :: Brush{radius=8,strength=0.5,falloff=0.5}

Stroke :: struct {
    active,changed,touched:bool,
    mode:Brush_Mode,
    last:[3]f32,  // the point of the last touch, in the world
    waited:f32,   // seconds since it last touched
    over:bool,    // the pointer is over a surface
    point,normal:[3]f32,
}

// Where a touch paints, in the frame of the cells: a disc fading over its
// falloff, or a box.
Paint_Area :: struct {
    disc:bool,
    center:[2]f32, // x and z
    radius,falloff:f32,
    low,high:[2]f32,
}

// How much a touch over an area moves a sample at a point of the frame, 0 to 1.
area_weight :: proc "contextless" (a:Paint_Area,p:[2]f32) -> f32 {
    if !a.disc {return 1 if p.x>=a.low.x && p.y>=a.low.y && p.x<=a.high.x && p.y<=a.high.y else 0}
    d:=linalg.length(p-a.center)
    if !(d<=a.radius) {return 0}
    inner:=a.radius*(1-clamp(a.falloff,0,1))
    if d<=inner {return 1}
    x:=(a.radius-d)/max(a.radius-inner,1e-6)
    return x*x*(3-2*x)
}

// The cells an area reaches, from low to high.
area_cells :: proc "contextless" (cell_size:f32,a:Paint_Area) -> (low,high:[2]i32) {
    lo,hi:=a.low,a.high
    if a.disc {lo,hi=a.center-a.radius,a.center+a.radius}
    low,_=pcg.cell_of(cell_size,lo)
    high,_=pcg.cell_of(cell_size,hi)
    return
}

// Moves the density the painted samples under an area keep toward value (0
// to 1) by strength, each by the weight of the area there; a cell that ends
// keeping all of its density everywhere, with no ecotopes, goes. True when a
// sample changed. Coordinates past what a source holds are left alone.
density_paint :: proc(source:^pcg.Pcg_Source,a:Paint_Area,value,strength:f32) -> (changed:bool) {
    if !(strength>0) || !(value>=0) {return}
    target:=clamp(value,0,1)*255
    cell:=source.info.cell_size
    n:=pcg.PAINT_SAMPLES
    step:=cell/f32(n-1)
    low,high:=area_cells(cell,a)
    low={max(low.x,-pcg.COORD_MAX),max(low.y,-pcg.COORD_MAX)}
    high={min(high.x,pcg.COORD_MAX),min(high.y,pcg.COORD_MAX)}
    if high.x<low.x || high.y<low.y || i64(high.x-low.x+1)*i64(high.y-low.y+1)>pcg.CELLS_MAX {return}
    for z in low.y..=high.y {
        for x in low.x..=high.x {
            corner:=pcg.cell_corner(cell,{x,z}).xz
            touched:=false
            for j in 0..<n {for i in 0..<n {
                if area_weight(a,corner+{f32(i)*step,f32(j)*step})>0 {touched=true;break}
            }}
            if !touched {continue}
            painted:=pcg.source_cell(source,{x,z},true)
            if painted==nil {return}
            if len(painted.density)==0 {
                if resize(&painted.density,n*n)!=nil {return}
                for &v in painted.density {v=255}
            }
            for j in 0..<n {for i in 0..<n {
                w:=area_weight(a,corner+{f32(i)*step,f32(j)*step})*clamp(strength,0,1)
                if !(w>0) {continue}
                old:=f32(painted.density[j*n+i])
                next:=u8(clamp(math.round(old+(target-old)*w),0,255))
                // A weight too small to move a step still reaches the value.
                if next==painted.density[j*n+i] && old!=target {next=u8(clamp(old+math.sign(target-old),0,255))}
                if next!=painted.density[j*n+i] {painted.density[j*n+i]=next;changed=true}
            }}
            full:=true
            for v in painted.density {if v!=255 {full=false;break}}
            if full && len(painted.ecotopes)==0 {
                at:=pcg.coord_lower(source.cells[:],{x,z})
                delete(source.cells[at].density);delete(source.cells[at].ecotopes)
                ordered_remove(&source.cells,at)
            }
        }
    }
    if changed {pcg.source_compiled_free(source)}
    return
}

// The frame of the cells of a graph and its inverse; false when it cannot be inverted.
graph_frames :: proc(graph:pcg.Pcg_Graph,place:mm.Transform) -> (frame:mm.Transform,to_frame:mm.Mat4,ok:bool) {
    frame=pcg.graph_frame(graph,place)
    to_frame,ok=mm.transform_inverse_matrix(frame)
    return
}

@(step="input",after="editor_begin")
pcg_pointer :: proc(s:^editor.Session,tool:^Pcg_Tool,input:core.Input) {
    tool_ready(tool)
    tool.active,tool.over,tool.begin=editor.tool_pointer(s,TOOL,input)
}

@(step="frame")
pcg_tool :: proc(
    s:^editor.Session,tool:^Pcg_Tool,world:core.World_Ref,graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),
    grounds:core.Ref(pcg.Pcg_Ground),requests:^pcg.Pcg_Ground_Requests,assets:^host.Assets,allocator:runtime.Allocator,input:core.Input,frame:core.Frame_Time,
) {
    if !tool.active || editor.playing(s) {
        if tool.stroke.active {edit_cancel(s,tool,assets,true)}
        tool.stroke,tool.adjust={},{}
        return
    }
    if !s.gui.begun {return}
    keys:=TOOL_KEYS
    if tool.adjust.active || tool.stroke.active {keys+={.Escape,.Enter}}
    editor.tool_keys(s,TOOL,keys)
    e:=target(s,graphs)
    if e==core.NONE || !edit_prepare(tool,assets,allocator,graphs,e) {return}
    graph,_:=core.get(graphs,e)
    placed,has_place:=core.get(worlds,e)
    if !has_place {return}
    if !tool.stroke.active && !tool.adjust.active {tool_keys_frame(s,tool,assets,input)}
    brush_frame(s,tool,world,e,graph,placed.transform,grounds.ptr,requests,assets,input,frame)
}

// The keys of the tool while no field is edited and no menu is open.
@(private)
tool_keys_frame :: proc(s:^editor.Session,tool:^Pcg_Tool,assets:^host.Assets,input:core.Input) {
    ctx:=s.gui.ctx
    if ctx.edit.id!=0 || s.gui.modal!=.None || ctx.popup.count!=0 || ctx.input.modifiers!={} {return}
    if core.key_pressed(input,.Left_Bracket) {tool.radius=max(tool.radius/RADIUS_STEP,RADIUS_MIN)}
    if core.key_pressed(input,.Right_Bracket) {tool.radius=min(tool.radius*RADIUS_STEP,RADIUS_MAX)}
    for key,mode in MODE_KEYS {if core.key_pressed(input,key) {tool.mode=mode}}
}

// The mode a press works in: Ctrl turns one into the other.
@(private)
mode_held :: proc "contextless" (tool:^Pcg_Tool,modifiers:ui.Modifiers) -> Brush_Mode {
    if .Primary in modifiers {return .Erase if tool.mode==.Paint else .Paint}
    return tool.mode
}

@(private)
brush_frame :: proc(s:^editor.Session,tool:^Pcg_Tool,world:core.World_Ref,e:core.Entity,graph:pcg.Pcg_Graph,place:mm.Transform,grounds:^pcg.Pcg_Ground,requests:^pcg.Pcg_Ground_Requests,assets:^host.Assets,input:core.Input,frame:core.Frame_Time) {
    stroke:=&tool.stroke
    if tool.adjust.active {
        editor.brush_adjust_frame(s,&tool.adjust,input,&tool.radius,&tool.strength,RADIUS_MIN,RADIUS_MAX)
        return
    }
    mode:=stroke.active?stroke.mode:mode_held(tool,s.gui.ctx.input.modifiers)
    if stroke.active {
        if ui.escape(s.gui.ctx) {edit_cancel(s,tool,assets,true);tool.stroke={};return}
        if !core.mouse_down(input,.Left) {
            if stroke.changed {edit_commit(s,tool,world,assets,"Paint PCG density" if stroke.mode==.Paint else "Erase PCG density",true)}
            tool.stroke={}
            return
        }
    }
    if !tool.over {stroke.over=false;return}
    hit:=editor.pick_point(s,world,input.mouse_position)
    stroke.over=hit.entity!=core.NONE && !hit.indicator
    if !stroke.over {return}
    stroke.point,stroke.normal=hit.position,hit.normal
    frame_pose,to_frame,inverted:=graph_frames(graph,place)
    if !inverted {return}
    scale:=max(abs(frame_pose.scale.x),1e-6)
    center:=mm.mat4_point(to_frame,hit.position)
    area:=Paint_Area{disc=true,center=center.xz,radius=tool.radius/scale,falloff=tool.falloff}
    ground_ask(grounds,requests,e,&tool.edit.source,area)
    ring_draw(s,hit.position,hit.normal,tool.radius,editor.BRUSH_ADD if mode==.Paint else editor.BRUSH_TAKE)
    if !stroke.active {
        if editor.brush_adjust_key(s,&tool.adjust,input,hit.position,hit.normal,tool.radius,tool.strength) {return}
        if !tool.begin {return}
        stroke^={active=true,mode=mode,point=hit.position,normal=hit.normal,over=true,last=hit.position}
        if !edit_baseline(tool) {editor.notify(s,"There is no memory to keep the PCG history");tool.stroke={};return}
    }
    stroke.waited+=frame.dt
    if stroke.touched && stroke.waited<1.0/BRUSH_RATE {return}
    first:=!stroke.touched
    stroke.touched,stroke.waited=true,0
    // Between the last touch and this one, every part of the radius.
    from:=first?hit.position:stroke.last
    delta:=hit.position-from
    count:=clamp(int(math.ceil(linalg.length(delta)/(tool.radius*STROKE_SPACING))),1,STROKE_TOUCHES_MAX)
    value:=f32(1) if stroke.mode==.Paint else 0
    changed:=false
    for i in 1..=count {
        p:=mm.mat4_point(to_frame,from+delta*(f32(i)/f32(count)))
        area.center=p.xz
        changed|=density_paint(&tool.edit.source,area,value,tool.strength)
    }
    stroke.last=hit.position
    if changed {
        stroke.changed=true
        edit_preview(s,tool,assets)
    }
}

// Asks the runtime for the ground of the cells of an area of a graph it has
// not read fine, so what it places there shows.
ground_ask :: proc(grounds:^pcg.Pcg_Ground,requests:^pcg.Pcg_Ground_Requests,e:core.Entity,source:^pcg.Pcg_Source,a:Paint_Area) {
    if requests==nil {return}
    low,high:=area_cells(source.info.cell_size,a)
    if i64(high.x-low.x+1)*i64(high.y-low.y+1)>64 {return}
    owner:=pcg.ground_owner(grounds,e)
    for z in low.y..=high.y {for x in low.x..=high.x {
        if owner==nil || pcg.ground_tile_find(owner,{x,z})<0 {pcg.ground_request(requests,e,{x,z})}
    }}
}

@(private)
ring_draw :: proc(s:^editor.Session,center,normal:[3]f32,radius:f32,color:ui.Color) {
    points:[RING_SEGMENTS][3]f32
    editor.brush_ring_points(center,normal,radius,points[:])
    editor.brush_ring_draw(s,points[:],color)
}

@(step="ui",after="editor_panels")
pcg_panel :: proc(s:^editor.Session,tool:^Pcg_Tool,world:core.World_Ref,graphs:^core.Table(pcg.Pcg_Graph,.Read),assets:^host.Assets,allocator:runtime.Allocator) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    tool_ready(tool)
    ctx:=g.ctx
    tool.active=editor.tool_on(s,TOOL)
    if !tool.active || s.viewport.pick.active {return}
    id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
    panel:=editor.tool_panel(g,id)
    room:=max(ctx.size.y-panel.offset.y-ui.metric(ctx,"margin")-panel.padding[1]-panel.padding[3],ui.metric(ctx,"row"))
    if ui.panel(ctx,id,panel) {
        ui.id_push(ctx,id);defer ui.id_pop(ctx)
        if ui.scroll_area(ctx,ui.id(ctx,"scroll"),&tool.scroll,{height=ui.FIT,max_height=room,gap=panel.gap,padding={0,0,SCROLL_GUTTER,0}}) {panel_rows(s,tool,world,graphs,assets,allocator)}
    }
}

// What the panel of the tool shows: a graph to choose, or the brush and the
// layers of the one selected.
@(private)
panel_rows :: proc(s:^editor.Session,tool:^Pcg_Tool,world:core.World_Ref,graphs:^core.Table(pcg.Pcg_Graph,$A),assets:^host.Assets,allocator:runtime.Allocator) {
    ctx:=s.gui.ctx
    e:=target(s,graphs)
    if e==core.NONE {
        kit.section(ctx,"Select a PCG graph","",80)
        for i in 0..<core.count(graphs) {
            graph:=core.entity_at(graphs,i)
            if ui.button(ctx,ui.id(ctx,"graph",core.entity_index(graph)+1),{label=editor.entity_label(world,graph),icon=.Sparkle,variant="field",width=-1}).clicked {history.selection_set(s.selection,{graph})}
        }
        return
    }
    kit.section(ctx,editor.entity_label(world,e),"",80)
    if !edit_prepare(tool,assets,allocator,graphs,e) {
        ui.label(ctx,fmt.tprintf("The source cannot be edited: %s",issue_text(tool.edit.issue)),ui.metric(ctx,"font_small"),ui.tone(ctx,"danger"))
        return
    }
    if kit.segments(ctx,ui.GROW,ui.metric(ctx,"control")) {
        for mode in Brush_Mode {
            if ui.button(ctx,ui.id(ctx,"mode",int(mode)+1),{label=MODE_NAMES[mode],detail=fmt.tprintf("%d",int(mode)+1),variant="tab",active=tool.mode==mode,width=-1,height=ui.metric(ctx,"control")-4,size=ui.metric(ctx,"font_small")}).clicked {tool.mode=mode}
        }
    }
    radius,strength,falloff:=f64(tool.radius),f64(tool.strength)*100,f64(tool.falloff)*100
    if kit.property(ctx,"Radius") {
        if ui.number_field(ctx,ui.id(ctx,"radius"),&radius,{width=ui.fixed(FIELD_WIDTH),min=f64(RADIUS_MIN),max=f64(RADIUS_MAX),has_min=true,has_max=true,speed=0.05,unit="m"}).changed {tool.radius=f32(radius)}
        editor.key_hint(ctx,"F")
    }
    if kit.property(ctx,"Strength") {
        if ui.number_field(ctx,ui.id(ctx,"strength"),&strength,{width=ui.fixed(FIELD_WIDTH),min=1,max=100,has_min=true,has_max=true,speed=0.5,unit="%",integer=true}).changed {tool.strength=f32(strength/100)}
        editor.key_hint(ctx,"Shift F")
    }
    if kit.property(ctx,"Falloff") {
        if ui.number_field(ctx,ui.id(ctx,"falloff"),&falloff,{width=ui.fixed(FIELD_WIDTH),min=0,max=100,has_min=true,has_max=true,speed=0.5,unit="%",integer=true}).changed {tool.falloff=f32(falloff/100)}
    }
    if tool.stroke.over {
        graph,_:=core.get(graphs,e)
        places:=core.world_table_of(world,core.World_Transform)
        if place,placed:=core.get(places,e);placed {
            if _,to_frame,ok:=graph_frames(graph,place.transform);ok {
                p:=mm.mat4_point(to_frame,tool.stroke.point)
                coord,local:=pcg.cell_of(tool.edit.source.info.cell_size,p.xz)
                kept:=pcg.paint_at(pcg.source_cell(&tool.edit.source,coord),0,tool.edit.source.info.cell_size,local.x,local.y,false)
                if kit.property(ctx,"Cell") {ui.label(ctx,fmt.tprintf("%d, %d",coord.x,coord.y),ui.metric(ctx,"font"),ui.tone(ctx,"text"))}
                if kit.property(ctx,"Density") {ui.label(ctx,fmt.tprintf("%.0f %%",kept*100),ui.metric(ctx,"font"),ui.tone(ctx,"text"))}
            }
        }
    }
    graph_rows(s,tool,world)
}
