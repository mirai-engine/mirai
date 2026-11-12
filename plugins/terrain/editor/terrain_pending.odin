package terrain_editor

import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import terrain "plugins:terrain/runtime"
import "mirai:ui"

Pending_Kind :: enum u8 {None,Ramp,Shape}
// A ramp or a shape placed on the terrain and not applied yet: the preview
// shows it until Enter applies it and Escape takes it away. Ends and centers
// are in the terrain.
Pending :: struct {
    kind:Pending_Kind,
    placing:bool, // the press that places it is still held
    a,b:[3]f32,   // the ends of a ramp or a capsule; a is the center of a sphere or a box
    handle:int,   // what a held press moves: 0 a, 1 b, -1 nothing
    plane:[3]f32, // a shape moves on the plane of the view through it
    brush:terrain.Brush, // the one the preview shows
    low,high:[3]int,     // the samples the preview changed
    shown:bool,
}
HANDLE_REACH :: f32(10) // points from a handle within which a press takes it

@(private)
pending_begin :: proc(tool:^Terrain_Tool,point:[3]f32) {
    tool.stroke.pending={kind=tool_shaping(tool)?.Shape:.Ramp,placing=true,a=point,b=point,handle=1,plane=tool.stroke.view}
}

// A frame of a ramp or a shape not applied yet; false when it ended.
@(private)
pending_frame :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets,input:core.Input,view:core.View) -> bool {
    stroke:=&tool.stroke
    p:=&stroke.pending
    if ui.escape(s.gui.ctx) {stroke_cancel(tool);return false}
    if !p.placing && p.handle<0 && core.key_pressed(input,.Enter) && s.gui.ctx.edit.id==0 {pending_apply(s,tool,world,assets);return stroke.active}
    if p.handle>=0 {
        if core.mouse_down(input,.Left) {
            if point,ok:=pending_point(tool,s.viewport,input.mouse_position);ok {pending_move(tool,point)}
        } else {
            if p.placing && p.kind==.Ramp && linalg.length(p.b.xz-p.a.xz)<stroke.source.cell {stroke_cancel(tool);return false}
            p.placing,p.handle=false,-1
        }
    } else if tool.begin {
        // A press on a handle moves it; anywhere else it applies what was placed.
        if handle:=pending_handle(s,tool,input.mouse_position);handle>=0 {p.handle=handle} else {pending_apply(s,tool,world,assets);return stroke.active}
    }
    pending_preview(s,tool,world)
    return true
}

// Where the pointer puts the handle being moved: on the surface as it was for
// a ramp, on the plane of the view through the handle for a shape.
@(private)
pending_point :: proc(tool:^Terrain_Tool,v:^editor.Viewport,at:[2]f32) -> (point:[3]f32,ok:bool) {
    stroke:=&tool.stroke
    p:=&stroke.pending
    from,toward:=stroke_ray(stroke,v,at)
    if p.kind==.Ramp {point,_,ok=terrain.source_ray(stroke_original(tool),from,toward);return}
    anchor:=p.handle==0 || p.placing?p.a:p.b
    denominator:=linalg.dot(toward,p.plane)
    if abs(denominator)<1e-6 {return}
    t:=linalg.dot(anchor-from,p.plane)/denominator
    if t<0 {return}
    return from+toward*t,true
}

@(private)
pending_move :: proc(tool:^Terrain_Tool,point:[3]f32) {
    p:=&tool.stroke.pending
    if p.handle==0 {p.a=point} else {p.b=point}
    // A sphere or a box grows with the drag of the press that places it.
    if p.kind==.Shape && p.placing && tool.shape!=.Capsule {
        if radius:=linalg.length(p.b-p.a)*tool.stroke.scale;radius>RADIUS_MIN {brush_of(tool).radius=min(radius,RADIUS_MAX)}
    }
}

// The handle of a ramp or a shape under a point of the window; -1: none.
@(private)
pending_handle :: proc(s:^editor.Session,tool:^Terrain_Tool,at:[2]f32) -> int {
    p:=&tool.stroke.pending
    ends:=[2][3]f32{p.a,p.b}
    count:=p.kind==.Ramp || tool.shape==.Capsule?2:1
    for i in 0..<count {
        if screen,seen:=pending_screen(s,&tool.stroke,ends[i]);seen && linalg.length(screen-at)<=HANDLE_REACH {return i}
    }
    return -1
}

@(private)
pending_screen :: proc(s:^editor.Session,stroke:^Stroke,point:[3]f32) -> ([2]f32,bool) {
    return editor.viewport_screen(s.viewport,(stroke.to_world*[4]f32{point.x,point.y,point.z,1}).xyz)
}

// What the ramp or the shape does: a ramp keeps its radius as half its width
// and falls off over its sides.
@(private)
pending_brush :: proc(tool:^Terrain_Tool) -> terrain.Brush {
    stroke:=&tool.stroke
    p:=&stroke.pending
    radius:=brush_of(tool).radius/stroke.scale
    if p.kind==.Ramp {
        sides:=max(tool.ramp_sides,0)/stroke.scale
        return {kind=.Ramp,center=p.a,delta=p.b-p.a,radius=radius+sides,hardness=min(radius/(radius+sides),0.99),falloff=brush_of(tool).falloff,amount=1}
    }
    brush:=terrain.Brush{kind=tool.brush,center=p.a,radius=radius,amount=1,rotation=1,layer=u32(tool.layer),blend=max(tool.blend,0)/stroke.scale}
    switch tool.shape {
    case .Sphere,.Selected: brush.shape=.Sphere
    case .Capsule: brush.shape,brush.delta=.Capsule,p.b-p.a
    case .Box: brush.shape,brush.extent=.Box,radius
    }
    return brush
}

// Shows what a ramp or a shape does, on the source as it was.
@(private)
pending_preview :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref) {
    stroke:=&tool.stroke
    p:=&stroke.pending
    brush:=pending_brush(tool)
    if p.shown && brush==p.brush {return}
    if p.shown {stroke_changed(stroke,terrain.source_restore(&stroke.source,stroke_original(tool),p.low,p.high))}
    p.shown=false
    p.brush=brush
    if p.kind==.Ramp && linalg.length(p.b.xz-p.a.xz)<stroke.source.cell {return}
    change:=terrain.source_edit(&stroke.source,brush)
    if change.error!=.None {edit_error(s,change.error,brush.kind);return}
    p.low,p.high,p.shown=change.low,change.high,change.changed
    stroke_changed(stroke,change)
}

@(private)
pending_apply :: proc(s:^editor.Session,tool:^Terrain_Tool,world:core.World_Ref,assets:^host.Assets) {
    stroke:=&tool.stroke
    label:=stroke.pending.kind==.Ramp?"Ramp":"Shape"
    pending_preview(s,tool,world)
    if stroke.pending.shown {stroke_brush_keep(tool,stroke.pending.brush)}
    stroke_end(s,tool,world,assets,label=label,layered=true)
}
