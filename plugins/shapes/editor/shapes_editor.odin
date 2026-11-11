package shapes_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import "mirai:host"
import erender "mirai:engine/render"
import shapes "plugins:shapes/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:editor/kit"
import "mirai:ui"
import "base:runtime"

// The Shapes tool: stamps squares, circles, stars and the other kinds onto the
// polygons of the shapes of a plane, drags, inserts and removes the corners of
// a polygon or the points of a spline, and places brushes of solids on the
// surface under the pointer. The camera stays free; stamps work on the plane
// of the shape selected, its local XY at z = 0, or on the plane z = 0 of the
// world with no shape selected. Every write goes through the steps of the
// document: a stroke, a corner drag, an insertion, a removal or a brush is
// one step.

TOOL :: "shapes"
PANEL_SCOPE :: ui.Id(0x73686170)
LINE_CAPACITY :: 8192
CORNER_MARK :: f32(4) // half the side of the square of a corner, in points of the window

Shapes_Mode :: enum u8 {Stamp,Corners,Brush}
MODE_NAMES :: [Shapes_Mode]string{.Stamp="Stamp",.Corners="Corners",.Brush="Brush"}
MODE_KEYS :: [Shapes_Mode]core.Key{.Stamp=.One,.Corners=.Two,.Brush=.Three}
MODE_KEY_NAMES :: [Shapes_Mode]string{.Stamp="1",.Corners="2",.Brush="3"}

Shapes_Operation :: enum u8 {Add,Cut}

// What the panel chooses, shown with the rows of Details.
Shapes_Settings :: struct {
    stamp:shapes.Stamp_Kind `mirai:"label=Shape"`,
    brush:shapes.Brush_Kind,
    operation:Shapes_Operation,
    combine:geom.Boolean_Op `mirai:"label=Operation"`, // of a brush
    size:f32 `mirai:"min=0.01,max=100,unit=m"`,
    angle:f32 `mirai:"angle"`,
    material:base.Asset_Id `mirai:"kind=.mat"`,
}

SETTINGS_DEFAULT :: Shapes_Settings{size=0.5}

@(storage,free="shapes_tool_free")
Shapes_Tool :: struct {
    active:bool,
    over:bool,  // the pointer is on the scene
    begin:bool, // a press on the scene this frame belongs to the tool
    ready:bool,
    mode:Shapes_Mode,
    settings:Shapes_Settings,
    stroke:Stroke,
    drag:Corner_Drag,
    hover:Corner_Hover,
    lines_storage:[dynamic]erender.Debug_Vertex,
    lines:erender.Debug_Lines,
}

shapes_tool_free :: proc(t:^Shapes_Tool) {
    stroke_free(&t.stroke)
    delete(t.lines_storage)
    t^={}
}

@(private)
tool_ready :: proc(t:^Shapes_Tool) {
    if t.ready {return}
    t.ready=true
    t.settings=SETTINGS_DEFAULT
    resize(&t.lines_storage,LINE_CAPACITY)
    // Lines on the plane lie inside the shapes they outline.
    t.lines=erender.debug_lines_make(t.lines_storage[:],false)
}

@(private)
tool_busy :: proc(t:^Shapes_Tool) -> bool {return t.stroke.active || t.drag.active}

// The scene is the pointer's while the tool is on: a press on it stamps,
// takes a corner or places a brush instead of selecting.
@(step="input",after="editor_begin")
shapes_pointer :: proc(s:^editor.Session,tool:^Shapes_Tool,input:core.Input) {
    tool_ready(tool)
    tool.active,tool.over,tool.begin=editor.tool_pointer(s,TOOL,input)
}

@(step="frame")
shapes_frame :: proc(s:^editor.Session,tool:^Shapes_Tool,world:core.World_Ref,extras:^host.Frame_Extras,allocator:runtime.Allocator,input:core.Input) {
    erender.debug_lines_clear(&tool.lines)
    defer if tool.lines.count>0 {host.extras_debug_lines_add(extras,tool.lines)}
    if !s.gui.begun {return}
    if !tool.active || editor.playing(s) {
        tool_cancel(s,tool)
        return
    }
    keys:core.Keys
    if tool_busy(tool) {keys+={.Escape}}
    if tool.mode==.Corners && tool.hover.vertex>=0 {keys+={.Delete,.Backspace}}
    editor.tool_keys(s,TOOL,keys)
    editor.tool_lend(s,TOOL)
    if editor.tool_aside(s,TOOL) {
        tool_cancel(s,tool)
        return
    }
    ray:=editor.viewport_ray(s.viewport,input.mouse_position)
    switch tool.mode {
    case .Stamp:   stamp_frame(s,tool,world,allocator,input,ray)
    case .Corners: corners_frame(s,tool,world,input,ray)
    case .Brush:   brush_frame(s,tool,world,input,ray)
    }
}

@(private)
tool_cancel :: proc(s:^editor.Session,tool:^Shapes_Tool) {
    if tool.stroke.active {stroke_cancel(s,tool)}
    if tool.drag.active {corner_drag_cancel(s,&tool.drag)}
    tool.hover={vertex=-1,edge=-1}
}

// The shape selected last, if any: the one the tool works on and whose plane it uses.
@(private)
selected_shape :: proc(s:^editor.Session,w:core.World_Ref) -> (e:core.Entity,shape:shapes.Shape,found:bool) {
    #reverse for selected in s.selection.entities {
        if value,ok:=editor.entity_get(w,selected,shapes.Shape);ok {return selected,value,true}
    }
    return
}

// The entity selected last that has corners: the one the Corners mode works on.
@(private)
selected_corners :: proc(s:^editor.Session,w:core.World_Ref) -> (e:core.Entity,c:Corners,found:bool) {
    #reverse for selected in s.selection.entities {
        if value,ok:=corners_of(w,selected);ok {return selected,value,true}
    }
    return
}

// ---------------------------------------------------------------- stamps

@(private)
stamp_frame :: proc(s:^editor.Session,tool:^Shapes_Tool,w:core.World_Ref,allocator:runtime.Allocator,input:core.Input,ray:mm.Ray) {
    stroke:=&tool.stroke
    settings:=&tool.settings
    color:=settings.operation==.Cut?editor.BRUSH_TAKE:editor.BRUSH_ADD
    if stroke.active {
        if ui.escape(s.gui.ctx) {
            stroke_cancel(s,tool)
            return
        }
        if point,hit:=local_point(stroke.edit.plane,ray);hit {
            stroke_refused(s,stroke,stroke_to(stroke,point))
            stamp_draw(tool,stroke.edit.plane,settings.stamp,point,settings.size,settings.angle,color)
        }
        if !stroke_write(s,tool) {return}
        if !core.mouse_down(input,.Left) {stroke_end(s,tool)}
        return
    }
    if !tool.over {return}
    e,_,_:=selected_shape(s,w)
    plane:=plane_of(w,e)
    point,hit:=local_point(plane,ray)
    if !hit {return}
    stamp_draw(tool,plane,settings.stamp,point,settings.size,settings.angle,color)
    if !tool.begin {return}
    tolerance:=stroke_tolerance(s.viewport,plane,point)
    if !stroke_begin(stroke,w,plane,e,settings.operation==.Cut,settings.stamp,settings.size,settings.angle,tolerance,settings.material,allocator) {return}
    stroke_refused(s,stroke,stroke_to(stroke,point))
    stroke_write(s,tool)
}

// Says once in a stroke why its area did not apply: the shapes keep what it
// made until then.
@(private)
stroke_refused :: proc(s:^editor.Session,stroke:^Stroke,error:shapes.Shape_Error) {
    if error==.None || stroke.refused {return}
    stroke.refused=true
    editor.notify(s,shapes.shape_error_text(error))
}

// Writes what the stamps of the frame changed into the step of the stroke,
// which the first change opens. The stroke is cancelled when the scene
// refuses a write.
@(private)
stroke_write :: proc(s:^editor.Session,tool:^Shapes_Tool) -> bool {
    stroke:=&tool.stroke
    // A call of the API or an undo closed the step of the stroke: it ends there.
    if stroke.opened && !s.edits.open {
        stroke_free(stroke)
        return false
    }
    if !stroke_dirty(stroke) {return true}
    if !stroke.opened {
        if !history.edits_begin(s.edits,s.selection,stroke.edit.cut?"Cut":"Stamp") {
            stroke_free(stroke)
            return false
        }
        stroke.opened=true
    }
    if !stroke_sync(s,stroke) {
        editor.notify(s,"The scene refused a shape of the stroke")
        stroke_cancel(s,tool)
        return false
    }
    return true
}

// The stroke becomes one step of the history.
@(private)
stroke_end :: proc(s:^editor.Session,tool:^Shapes_Tool) {
    stroke:=&tool.stroke
    if stroke.opened {history.edits_end(s.edits)}
    stroke_free(stroke)
}

// The shapes go back to what they were when the stroke began.
@(private)
stroke_cancel :: proc(s:^editor.Session,tool:^Shapes_Tool) {
    if tool.stroke.opened {history.edits_cancel(s.edits,editor.shown_world(s))}
    stroke_free(&tool.stroke)
}

// ---------------------------------------------------------------- corners

@(private)
corners_frame :: proc(s:^editor.Session,tool:^Shapes_Tool,w:core.World_Ref,input:core.Input,ray:mm.Ray) {
    drag:=&tool.drag
    ctx:=s.gui.ctx
    if drag.active {
        if ui.escape(ctx) || !editor.entity_alive(w,drag.entity) {
            corner_drag_cancel(s,drag)
            return
        }
        t:=editor.entity_world(w,drag.entity)
        // A move the shape refuses leaves the corner where it was last taken.
        if p,hit:=local_point(corner_plane(t,&drag.corners,drag.vertex),ray);hit {corner_drag_move(s,drag,p)}
        corners_draw(s,tool,t,&drag.corners,{entity=drag.entity,vertex=drag.vertex,edge=-1})
        if !core.mouse_down(input,.Left) {corner_drag_end(s,drag)}
        return
    }
    tool.hover={vertex=-1,edge=-1}
    e,corners,found:=selected_corners(s,w)
    if !found {
        if tool.begin {select_under(s,w,input)}
        return
    }
    t:=editor.entity_world(w,e)
    if tool.over {tool.hover=corner_hover(s,&corners,t,input.mouse_position)}
    tool.hover.entity=e
    corners_draw(s,tool,t,&corners,tool.hover)
    hover:=tool.hover
    removing:=hover.vertex>=0 && ctx.edit.id==0 && (core.key_pressed(input,.Delete) || core.key_pressed(input,.Backspace))
    if tool.begin && hover.vertex>=0 && .Primary in ctx.input.modifiers {removing=true}
    switch {
    case removing:
        corner_refused(s,.Remove,corner_edit(s,e,.Remove,hover.vertex,{},"Remove corner"))
    case !tool.begin:
    case hover.vertex>=0:
        corner_drag_begin(drag,e,hover.vertex,corners)
    case hover.edge>=0:
        if ctx.input.clicks>=2 {corner_refused(s,.Insert,corner_edit(s,e,.Insert,hover.edge,hover.at,"Insert corner"))}
    case:
        select_under(s,w,input)
    }
}

@(private)
corner_refused :: proc(s:^editor.Session,op:Corner_Op,error:shapes.Shape_Error) {
    switch {
    case error==.None:
    case op==.Remove && error==.Invalid: editor.notify(s,"A loop keeps at least three corners, a spline two")
    case:                                editor.notify(s,shapes.shape_error_text(error))
    }
}

// Selects the shape under the pointer, whose corners the tool then shows.
@(private)
select_under :: proc(s:^editor.Session,w:core.World_Ref,input:core.Input) {
    hit:=editor.pick_point(s,w,input.mouse_position)
    if hit.entity==core.NONE || hit.indicator {return}
    e:=editor.entity_author(w,hit.entity)
    if editor.entity_has(w,e,shapes.Shape) {history.selection_set(s.selection,{e})}
}

// ---------------------------------------------------------------- brushes

// A click places a brush on the surface under the pointer, in the Solid
// hit or else the one selected; Alt shows the brush of the Solid under the
// pointer and a click selects it, for the gizmo of W, E and R.
@(private)
brush_frame :: proc(s:^editor.Session,tool:^Shapes_Tool,w:core.World_Ref,input:core.Input,ray:mm.Ray) {
    if !tool.over {return}
    settings:=&tool.settings
    hit:=editor.pick_point(s,w,input.mouse_position)
    surface:=hit.entity!=core.NONE && !hit.indicator
    hit_solid:=surface?solid_of(w,editor.entity_author(w,hit.entity)):core.NONE
    if .Alt in s.gui.ctx.input.modifiers {
        if hit_solid==core.NONE {return}
        along:=linalg.dot(hit.position-ray.origin,ray.direction)/max(linalg.dot(ray.direction,ray.direction),1e-12)
        brush,kind,place,found:=brush_under(w,hit_solid,ray,along)
        if !found {return}
        brush_draw(tool,kind,place,editor.BRUSH_CHANGE)
        if tool.begin {history.selection_set(s.selection,{brush})}
        return
    }
    target:=hit_solid!=core.NONE?hit_solid:selected_solid(s,w)
    at,normal:[3]f32
    if surface {
        at,normal=hit.position,hit.normal
    } else {
        plane:=plane_of(w,target)
        point,on_plane:=local_point(plane,ray)
        if !on_plane {return}
        at,normal=mm.transform_point(plane,{point.x,point.y,0}),mm.quat_rotate(plane.rotation,{0,0,1})
        if linalg.dot(normal,ray.direction)>0 {normal=-normal}
    }
    op:=settings.combine
    place:=brush_place_at(op,at,normal,settings.size,settings.angle)
    brush_draw(tool,settings.brush,place,op==.Union?editor.BRUSH_ADD:op==.Subtract?editor.BRUSH_TAKE:editor.BRUSH_CHANGE)
    if !tool.begin {return}
    if op!=.Union && target==core.NONE {
        editor.notify(s,"A brush that cuts or intersects needs a Solid shape under the pointer or selected to work on")
        return
    }
    if _,error:=brush_place(s,place,at,settings.brush,op,settings.material,target);error!=.None {
        editor.notify(s,shapes.shape_error_text(error))
    }
}

// ---------------------------------------------------------------- lines

@(private)
color_of :: proc "contextless" (c:ui.Color) -> [4]f32 {return {f32(c[0])/255,f32(c[1])/255,f32(c[2])/255,f32(c[3])/255}}

// The outline of a stamp at a point of a plane.
@(private)
stamp_draw :: proc(tool:^Shapes_Tool,plane:Plane,kind:shapes.Stamp_Kind,at:[2]f32,size,angle:f32,color:ui.Color) {
    loop:=make([dynamic][2]f32,context.temp_allocator)
    shapes.stamp_points(kind,at,size,angle,&loop)
    c:=color_of(color)
    for p,i in loop {
        q:=loop[(i+1)%len(loop)]
        erender.debug_line(&tool.lines,mm.transform_point(plane,{p.x,p.y,0}),mm.transform_point(plane,{q.x,q.y,0}),c)
    }
}

// The edges of a brush placed in the world: a box, three circles of a
// sphere, or the two rims and four sides of a cylinder.
@(private)
brush_draw :: proc(tool:^Shapes_Tool,kind:shapes.Brush_Kind,place:mm.Transform,color:ui.Color) {
    c:=color_of(color)
    line :: proc(tool:^Shapes_Tool,place:mm.Transform,a,b:[3]f32,c:[4]f32) {
        erender.debug_line(&tool.lines,mm.transform_point(place,a),mm.transform_point(place,b),c)
    }
    circle :: proc(tool:^Shapes_Tool,place:mm.Transform,center,x,y:[3]f32,c:[4]f32) {
        SEGMENTS :: 32
        for i in 0..<SEGMENTS {
            a,b:=f32(i)*math.TAU/SEGMENTS,f32(i+1)*math.TAU/SEGMENTS
            line(tool,place,center+0.5*(x*math.cos(a)+y*math.sin(a)),center+0.5*(x*math.cos(b)+y*math.sin(b)),c)
        }
    }
    switch kind {
    case .Box:
        for axis in 0..<3 {
            u,v:=(axis+1)%3,(axis+2)%3
            for corner in ([4][2]f32{{-0.5,-0.5},{0.5,-0.5},{-0.5,0.5},{0.5,0.5}}) {
                a,b:[3]f32
                a[axis],b[axis]=-0.5,0.5
                a[u],a[v],b[u],b[v]=corner.x,corner.y,corner.x,corner.y
                line(tool,place,a,b,c)
            }
        }
    case .Sphere:
        circle(tool,place,{},{1,0,0},{0,1,0},c)
        circle(tool,place,{},{0,1,0},{0,0,1},c)
        circle(tool,place,{},{0,0,1},{1,0,0},c)
    case .Cylinder:
        circle(tool,place,{0,-0.5,0},{1,0,0},{0,0,1},c)
        circle(tool,place,{0,0.5,0},{1,0,0},{0,0,1},c)
        for side in ([4][2]f32{{0.5,0},{-0.5,0},{0,0.5},{0,-0.5}}) {
            line(tool,place,{side.x,-0.5,side.y},{side.x,0.5,side.y},c)
        }
    }
}

// The edges of the corners of an entity placed at t and a square at each
// corner, the one under the pointer and the edge it would insert on marked.
@(private)
corners_draw :: proc(s:^editor.Session,tool:^Shapes_Tool,t:mm.Transform,c:^Corners,hover:Corner_Hover) {
    edge,mark,taken:=color_of(editor.BRUSH_CHANGE),color_of(editor.BRUSH_CHANGE),color_of(editor.BRUSH_ADD)
    edge.a*=0.6
    edges:=make([dynamic][2]int,context.temp_allocator)
    corner_edges(c,&edges)
    for e in edges {
        erender.debug_line(&tool.lines,corner_world(t,c,e[0]),corner_world(t,c,e[1]),e[0]==hover.edge?taken:edge)
    }
    plane:=corner_plane(t,c,-1)
    x,y:=mm.quat_rotate(plane.rotation,{1,0,0}),mm.quat_rotate(plane.rotation,{0,1,0})
    square :: proc(s:^editor.Session,lines:^erender.Debug_Lines,center,x,y:[3]f32,color:[4]f32) {
        // A meter along the plane, in points of the window: the square keeps its size on screen.
        a,seen_a:=editor.viewport_screen(s.viewport,center)
        b,seen_b:=editor.viewport_screen(s.viewport,center+x)
        across:=linalg.distance(a,b)
        if !seen_a || !seen_b || !(across>1e-3) {return}
        h:=CORNER_MARK/across
        corners:=[4][3]f32{center+(-x-y)*h,center+(x-y)*h,center+(x+y)*h,center+(-x+y)*h}
        for i in 0..<4 {erender.debug_line(lines,corners[i],corners[(i+1)%4],color)}
    }
    for i in 0..<corner_count(c) {
        square(s,&tool.lines,corner_world(t,c,i),x,y,i==hover.vertex?taken:mark)
    }
    for e in edges {
        if hover.vertex>=0 || e[0]!=hover.edge {continue}
        a,b:=corner_at(c,e[0]),corner_at(c,e[1])
        square(s,&tool.lines,linalg.lerp(corner_world(t,c,e[0]),corner_world(t,c,e[1]),segment_along(a,b,hover.at)),x,y,taken)
    }
}

// ---------------------------------------------------------------- panel

@(step="ui",after="editor_panels")
shapes_panel :: proc(s:^editor.Session,tool:^Shapes_Tool,world:core.World_Ref,input:core.Input) {
    g:=s.gui
    if !g.begun || editor.playing(s) {return}
    tool_ready(tool)
    ctx:=g.ctx
    keys_free:=ctx.edit.id==0 && ctx.input.modifiers=={} && g.modal==.None && ctx.popup.count==0
    tool.active=editor.tool_on(s,TOOL)
    if !tool.active || s.viewport.pick.active {return}
    if keys_free && !tool_busy(tool) {
        keys:=MODE_KEYS
        for key,mode in keys {if core.key_pressed(input,key) {mode_set(s,tool,mode)}}
        if core.key_pressed(input,.X) {
            if tool.mode==.Brush {
                tool.settings.combine=geom.Boolean_Op((int(tool.settings.combine)+1)%len(geom.Boolean_Op))
            } else {
                tool.settings.operation=tool.settings.operation==.Add?.Cut:.Add
            }
        }
    }
    id:=ui.id_derive(ctx,PANEL_SCOPE,"panel")
    if ui.panel(ctx,id,editor.tool_panel(g,id)) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        e,shape,found:=selected_shape(s,world)
        if tool.mode==.Brush {
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            if solid:=selected_solid(s,world);solid!=core.NONE {
                value,has:=editor.entity_get(world,solid,shapes.Shape)
                e,found=solid,has
                shape=value
            }
        }
        note:=""
        if tool.mode==.Corners {
            picked,corners,has:=selected_corners(s,world)
            e,found=picked,has
            note=fmt.tprintf("%d corners",corner_count(&corners))
        }
        if tool.mode==.Stamp && found && shape.loop_count>0 {note=fmt.tprintf("%d corners",shape.point_count)}
        if found && tool.mode==.Brush {
            count:=0
            for child in editor.entity_children(world,e) {
                if editor.entity_has(world,child,shapes.Shape_Brush) {count+=1}
            }
            note=fmt.tprintf("%d brushes",count)
        }
        kit.section(ctx,found?editor.entity_label(world,e):"Shapes",note,80)
        if kit.segments(ctx,ui.GROW,ui.metric(ctx,"control")) {
            names,keys:=MODE_NAMES,MODE_KEY_NAMES
            for mode in Shapes_Mode {
                if ui.button(ctx,ui.id(ctx,"mode",int(mode)+1),{label=names[mode],detail=keys[mode],variant="tab",active=tool.mode==mode && !editor.tool_aside(s,TOOL),width=-1,height=ui.metric(ctx,"control")-4,size=ui.metric(ctx,"font_small")}).clicked {mode_set(s,tool,mode)}
            }
        }
        defaults:=SETTINGS_DEFAULT
        h:=editor.Held_Values{key=u64(PANEL_SCOPE)<<32|1,info=type_info_of(Shapes_Settings),value=&tool.settings,defaults=&defaults,width=editor.tool_panel_inner(g)}
        switch tool.mode {
        case .Stamp:
            editor.held_field_row(s,h,"stamp")
            editor.held_field_row(s,h,"operation")
            editor.held_field_row(s,h,"size","",SIZE_DESCRIPTION)
            editor.held_field_row(s,h,"angle")
            editor.held_field_row(s,h,"material","","Of the shapes a stamp makes outside every shape")
        case .Corners:
        case .Brush:
            editor.held_field_row(s,h,"brush")
            editor.held_field_row(s,h,"combine")
            editor.held_field_row(s,h,"size","",SIZE_DESCRIPTION)
            editor.held_field_row(s,h,"angle")
            editor.held_field_row(s,h,"material","","Of the solid a brush makes with no solid under the pointer or selected")
        }
        tool.settings.size=clamp(tool.settings.size,0.01,100)
    }
}

SIZE_DESCRIPTION :: "Half the width of a square or a box; the radius of a circle, a sphere or a cylinder"

@(private)
mode_set :: proc(s:^editor.Session,tool:^Shapes_Tool,mode:Shapes_Mode) {
    tool.mode=mode
    tool.hover={vertex=-1,edge=-1}
    editor.tool_take(s,TOOL)
}
