package editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:ui"

// What the brushes of the plugin tools share: the ring of a brush and its
// colors, and F and Shift F dragging its radius and its strength on the
// ground, as Blender's radial control and TerraBrush's selector.

// The color of a ring says what a touch does: yellow adds or raises, blue
// takes away, white smooths or changes what is there.
BRUSH_ADD :: ui.Color{255,217,51,255}
BRUSH_TAKE :: ui.Color{98,168,255,255}
BRUSH_CHANGE :: ui.Color{232,232,238,255}
BRUSH_OUTLINE :: ui.Color{18,20,24,230}
// A part that generates, as the cells of foliage that do.
BRUSH_GENERATED :: ui.Color{120,220,120,255}

// A closed ring through points of the world, outlined to read on any ground;
// a part that goes behind the eye is left out.
brush_ring_draw :: proc(s:^Session,points:[][3]f32,color:ui.Color,width:f32=3,dashed:=false) {
    screen:=make([][2]f32,len(points),context.temp_allocator)
    seen:=make([]bool,len(points),context.temp_allocator)
    for point,i in points {screen[i],seen[i]=viewport_screen(s.viewport,point)}
    for layer in 0..<2 {
        line:=layer==0?width+3:width
        c:=layer==0?BRUSH_OUTLINE:color
        if layer==0 {c.a=u8(u32(BRUSH_OUTLINE.a)*u32(color.a)/255)}
        for i in 0..<len(points) {
            if dashed && i%4>=2 {continue}
            next:=(i+1)%len(points)
            if seen[i] && seen[next] {ui.draw_line(s.gui.ctx,screen[i],screen[next],line,c)}
        }
    }
}

// The points of a ring of radius around center on the plane of normal, in
// the world.
brush_ring_points :: proc(center,normal:[3]f32,radius:f32,out:[][3]f32) {
    n:=linalg.normalize0(normal)
    if n=={} {n={0,1,0}}
    reference:=abs(n.y)>0.9?[3]f32{1,0,0}:[3]f32{0,1,0}
    tangent:=linalg.normalize(linalg.cross(n,reference));bitangent:=linalg.cross(n,tangent)
    for &point,i in out {
        angle:=f32(i)/f32(len(out))*math.TAU
        point=center+(tangent*math.cos(angle)+bitangent*math.sin(angle))*radius
    }
}

// F over the ground begins to drag the radius and Shift F the strength, from
// anchor on the plane through it with normal, all in the world; radius and
// value are those before.
Brush_Adjust :: struct {
    active,strength:bool,
    anchor,normal:[3]f32,
    radius,value:f32,
    measured:bool, // last is the distance of the pointer from anchor the frame before
    last:f32,
}

// Whether F, or Shift F, begins to adjust a brush whose ring is at point.
brush_adjust_key :: proc(s:^Session,a:^Brush_Adjust,input:core.Input,point,normal:[3]f32,radius,value:f32) -> bool {
    ctx:=s.gui.ctx
    if !core.key_pressed(input,.F) || ctx.edit.id!=0 || s.gui.modal!=.None || ctx.popup.count!=0 {return false}
    if ctx.input.modifiers!={} && ctx.input.modifiers!={.Shift} {return false}
    a^={active=true,strength=.Shift in ctx.input.modifiers,anchor=point,normal=linalg.normalize0(normal),radius=radius,value=value}
    if a.normal=={} {a.normal={0,1,0}}
    return true
}

// While F holds the radius or the strength: the pointer on the plane of the
// anchor sets it, with Ctrl finely; a click, Enter or F keep it; Escape or
// the right button put back the one before. The strength is the distance
// over the radius. False once it ended.
brush_adjust_frame :: proc(s:^Session,a:^Brush_Adjust,input:core.Input,radius,value:^f32,radius_min,radius_max:f32) -> bool {
    ctx:=s.gui.ctx
    if ui.escape(ctx) || core.mouse_pressed(input,.Right) {radius^,value^=a.radius,a.value;a^={};return false}
    if core.mouse_pressed(input,.Left) || ctx.edit.id==0 && (core.key_pressed(input,.Enter) || core.key_pressed(input,.F)) {a^={};return false}
    ray:=viewport_ray(s.viewport,input.mouse_position)
    if denominator:=linalg.dot(ray.direction,a.normal);abs(denominator)>1e-6 {
        if t:=linalg.dot(a.anchor-ray.origin,a.normal)/denominator;t>0 {
            distance:=linalg.length(ray.origin+ray.direction*t-a.anchor)
            // With Ctrl the pointer moves the value a tenth as fast, from where it is.
            if .Primary in ctx.input.modifiers {
                if a.measured {
                    change:=(distance-a.last)*0.1
                    if a.strength {value^=clamp(value^+change/radius^,0,1)} else {radius^=clamp(radius^+change,radius_min,radius_max)}
                }
            } else if a.strength {value^=clamp(distance/radius^,0,1)} else {radius^=clamp(distance,radius_min,radius_max)}
            a.last,a.measured=distance,true
        }
    }
    brush_adjust_draw(s,a,input,radius^,value^)
    return true
}

// Both rings on the plane of the anchor, a line to the pointer and the value.
@(private)
brush_adjust_draw :: proc(s:^Session,a:^Brush_Adjust,input:core.Input,radius,value:f32) {
    points:[64][3]f32
    brush_ring_points(a.anchor,a.normal,radius,points[:])
    brush_ring_draw(s,points[:],BRUSH_ADD)
    brush_ring_points(a.anchor,a.normal,radius*clamp(value,0,1),points[:])
    brush_ring_draw(s,points[:],{BRUSH_ADD.r,BRUSH_ADD.g,BRUSH_ADD.b,150},2)
    middle,seen:=viewport_screen(s.viewport,a.anchor)
    if !seen {return}
    ctx:=s.gui.ctx
    ui.draw_line(ctx,middle,input.mouse_position,1.5,{BRUSH_ADD.r,BRUSH_ADD.g,BRUSH_ADD.b,150})
    text:=a.strength?fmt.tprintf("%.0f %%",value*100):fmt.tprintf("%.1f m",radius)
    size:=ui.metric(ctx,"font")
    width:=ui.text_width(&ctx.font,text,size)
    at:=input.mouse_position+{16,-24}
    ui.draw_rounded(ctx,{at.x-6,at.y-3,width+12,size+8},4,ui.tone(ctx,"popup"))
    ui.draw_text(ctx,text,at.x,at.y,size,ui.tone(ctx,"text"))
}

// The key that does the same as a field of a row, after it, as the buttons
// show theirs.
key_hint :: proc(ctx:^ui.Context,key:string) {
    ui.spacer(ctx)
    ui.label(ctx,key,ui.metric(ctx,"font_small"),ui.tone(ctx,"text_muted"))
}
