package terrain_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import terrain "plugins:terrain/runtime"
import "mirai:ui"

// The color of the cursor says what a touch does: yellow adds or raises, blue
// takes away, white smooths.
CURSOR_ADD :: editor.BRUSH_ADD
CURSOR_TAKE :: editor.BRUSH_TAKE
CURSOR_SMOOTH :: editor.BRUSH_CHANGE
CURSOR_OUTLINE :: editor.BRUSH_OUTLINE

@(private)
cursor_color :: proc "contextless" (kind:terrain.Brush_Kind) -> ui.Color {
    #partial switch kind {
    case .Lower,.Carve,.Erase,.Hole,.Erode,.Thermal: return CURSOR_TAKE
    case .Smooth:                                return CURSOR_SMOOTH
    }
    return CURSOR_ADD
}
@(private)
faded :: proc "contextless" (c:ui.Color) -> ui.Color {return {c.r,c.g,c.b,150}}

// The brush where it touches, on the surface as it is now: its radius,
// inside it the radius times its strength, and what it keeps or reaches
// besides the ground.
@(private)
cursor_draw :: proc(s:^editor.Session,tool:^Terrain_Tool,input:core.Input,view:core.View) {
    stroke:=&tool.stroke
    source:=&stroke.source
    local,normal:[3]f32;ok:bool
    if stroke.active {local,normal,ok=stroke_aim(tool,s.viewport,input.mouse_position)} else {local,normal,ok=stroke_point(stroke,s.viewport,input.mouse_position)}
    if !ok {return}
    grid:=stroke.source.kind==.Heightfield
    if grid {normal={0,1,0}}
    kind,level,capped:=brush_held(tool,s.gui.ctx.input.modifiers,input.eraser)
    radius:=brush_of(tool).radius/stroke.scale
    color:=cursor_color(kind)
    ring_draw(s,stroke,source,local,normal,radius,color,dashed=kind==.Smooth)
    if brush_strong(kind) {ring_draw(s,stroke,source,local,normal,radius*clamp(brush_of(tool).strength,0,1),faded(color),2)}
    if !grid && (kind==.Add || kind==.Carve) {
        _,forward:=core.view_ray(view,view.size*0.5)
        sphere_draw(s,stroke,local,radius,(stroke.to_local*[4]f32{forward.x,forward.y,forward.z,0}).xyz,faded(color))
    }
    // The turn of an alpha, from its center out.
    if alpha_of(tool,brush_of(tool))!=nil && !brush_of(tool).spin {
        turn:=brush_of(tool).turn
        along:=[3]f32{math.cos(turn),0,math.sin(turn)}*radius
        if grid {
            from,to:=local+along*0.55,local+along
            from.y,to.y=terrain.source_height(source,from.x,from.z),terrain.source_height(source,to.x,to.z)
            a,a_seen:=pending_screen(s,stroke,from);b,b_seen:=pending_screen(s,stroke,to)
            if a_seen && b_seen {ui.draw_line(s.gui.ctx,a,b,3,color)}
        }
    }
    // Flatten and a capped Raise or Lower show the plane they keep: the one of
    // the press while held, the typed height of Set height.
    if (kind==.Flatten || capped && stroke.active) && (stroke.active || level) {
        plane:=!grid && stroke.active && !level?stroke.normal:[3]f32{0,1,0}
        target:=stroke.active?stroke.target:tool.height
        ring_draw(s,stroke,source,local-plane*(linalg.dot(plane,local)-target),plane,radius,faded(color),2,dashed=true,flat=true)
    }
}

// A ring around center: on the ground of a grid, on the plane of normal
// otherwise or when flat; outlined to read on any ground.
@(private)
ring_draw :: proc(s:^editor.Session,stroke:^Stroke,source:^terrain.Source,center,normal:[3]f32,radius:f32,color:ui.Color,width:f32=3,dashed:=false,flat:=false) {
    if !(radius>0) {return}
    points:[RING_SEGMENTS][3]f32
    editor.brush_ring_points(center,normal,radius,points[:])
    for &point in points {
        if !flat {point,_=terrain.source_carry(source,point,normal,0)}
        point=(stroke.to_world*[4]f32{point.x,point.y,point.z,1}).xyz
    }
    editor.brush_ring_draw(s,points[:],color,width,dashed)
}

// The outline of a sphere seen along toward.
@(private)
sphere_draw :: proc(s:^editor.Session,stroke:^Stroke,center:[3]f32,radius:f32,toward:[3]f32,color:ui.Color) {
    middle,seen:=pending_screen(s,stroke,center)
    if !seen {return}
    side:=linalg.normalize0(linalg.cross(toward,[3]f32{0,1,0}))
    if side=={} {side={1,0,0}}
    if edge,edge_seen:=pending_screen(s,stroke,center+side*radius);edge_seen {ui.draw_ring(s.gui.ctx,middle,linalg.length(edge-middle),1.5,color)}
}


// A ramp or a shape not applied yet: its outline and the handles that move it.
@(private)
pending_draw :: proc(s:^editor.Session,tool:^Terrain_Tool) {
    stroke:=&tool.stroke
    p:=&stroke.pending
    ctx:=s.gui.ctx
    radius:=brush_of(tool).radius/stroke.scale
    color:=cursor_color(p.kind==.Ramp?.Raise:tool.brush)
    handles:=1
    if p.kind==.Ramp {
        // Its width at the heights of its ends, and the sides that fall off.
        handles=2
        along:=p.b-p.a
        across:=linalg.normalize0([3]f32{-along.z,0,along.x})
        sides:=radius+max(tool.ramp_sides,0)/stroke.scale
        for reach,i in ([2]f32{radius,sides}) {
            for sign in ([2]f32{-1,1}) {
                from,from_seen:=pending_screen(s,stroke,p.a+across*reach*sign)
                to,to_seen:=pending_screen(s,stroke,p.b+across*reach*sign)
                if from_seen && to_seen {ui.draw_line(ctx,from,to,i==0?2:1.5,i==0?color:faded(color))}
            }
        }
        for end in ([2][3]f32{p.a,p.b}) {
            from,from_seen:=pending_screen(s,stroke,end-across*radius)
            to,to_seen:=pending_screen(s,stroke,end+across*radius)
            if from_seen && to_seen {ui.draw_line(ctx,from,to,2,color)}
        }
    } else {
        switch tool.shape {
        case .Sphere,.Selected: sphere_draw(s,stroke,p.a,radius,-p.plane,color)
        case .Capsule:
            handles=2
            sphere_draw(s,stroke,p.a,radius,-p.plane,color);sphere_draw(s,stroke,p.b,radius,-p.plane,color)
            a,a_seen:=pending_screen(s,stroke,p.a);b,b_seen:=pending_screen(s,stroke,p.b)
            side,side_seen:=pending_screen(s,stroke,p.a+linalg.normalize0(linalg.cross(-p.plane,[3]f32{0,1,0}))*radius)
            if a_seen && b_seen && side_seen && linalg.length(b-a)>1 {
                across:=linalg.normalize0([2]f32{a.y-b.y,b.x-a.x})*linalg.length(side-a)
                ui.draw_line(ctx,a+across,b+across,1.5,color);ui.draw_line(ctx,a-across,b-across,1.5,color)
            }
        case .Box:
            corner :: proc(center:[3]f32,reach:f32,i:int) -> [3]f32 {return center+{f32(i&1)*2-1,f32(i>>1&1)*2-1,f32(i>>2)*2-1}*reach}
            for i in 0..<8 {
                for axis in 0..<3 {
                    j:=i|(1<<uint(axis))
                    if j==i {continue}
                    from,from_seen:=pending_screen(s,stroke,corner(p.a,radius,i))
                    to,to_seen:=pending_screen(s,stroke,corner(p.a,radius,j))
                    if from_seen && to_seen {ui.draw_line(ctx,from,to,1.5,color)}
                }
            }
        }
    }
    ends:=[2][3]f32{p.a,p.b}
    for i in 0..<handles {
        if at,seen:=pending_screen(s,stroke,ends[i]);seen {ui.draw_circle(ctx,at,6,ui.tone(ctx,"accent"));ui.draw_circle(ctx,at,3.5,{255,255,255,255})}
    }
}
