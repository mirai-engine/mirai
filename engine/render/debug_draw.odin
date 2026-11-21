package render

import "core:math"
import "mirai:core"
import "mirai:host"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"

DEBUG_DRAW_CAPACITY :: 1024
DEBUG_DRAW_VERTICES :: 4096

@(private)
Debug_Shape :: enum u8 {Line,Box,Sphere,Arrow,Cross}

@(private)
Debug_Primitive :: struct {
    kind:Debug_Shape,
    a,b:mm.Vec3,
    color:mm.Vec4,
    size:f32,
    seconds:f32,
}

@(storage,copy=false)
Debug_Draw :: struct {
    shapes:[dynamic]Debug_Primitive,
    vertices:[]Debug_Vertex,
}

@(private)
debug_draw_offer :: proc(draw:^Debug_Draw,shape:Debug_Primitive) -> bool {
    if draw==nil || len(draw.shapes)>=DEBUG_DRAW_CAPACITY ||
       !(shape.seconds>=0) || math.is_inf(shape.seconds) {return false}
    if cap(draw.shapes)==0 && reserve(&draw.shapes,DEBUG_DRAW_CAPACITY)!=nil {return false}
    _,error:=append(&draw.shapes,shape)
    return error==nil
}

debug_draw_line :: proc(draw:^Debug_Draw,from,to:mm.Vec3,color:mm.Vec4,duration:f32=0) -> bool {
    return debug_draw_offer(draw,{kind=.Line,a=from,b=to,color=color,seconds=duration})
}

debug_ray :: proc(
    draw:^Debug_Draw,origin,direction:mm.Vec3,length:f32,color:mm.Vec4,duration:f32=0,
) -> bool {
    return debug_draw_line(draw,origin,origin+direction*length,color,duration)
}

debug_draw_box :: proc(draw:^Debug_Draw,low,high:mm.Vec3,color:mm.Vec4,duration:f32=0) -> bool {
    return debug_draw_offer(draw,{kind=.Box,a=low,b=high,color=color,seconds=duration})
}

debug_draw_sphere :: proc(
    draw:^Debug_Draw,center:mm.Vec3,radius:f32,color:mm.Vec4,duration:f32=0,
) -> bool {
    return debug_draw_offer(draw,{kind=.Sphere,a=center,color=color,size=radius,seconds=duration})
}

debug_draw_arrow :: proc(
    draw:^Debug_Draw,from,to:mm.Vec3,color:mm.Vec4,duration:f32=0,head:f32=0.2,
) -> bool {
    return debug_draw_offer(draw,{kind=.Arrow,a=from,b=to,color=color,size=head,seconds=duration})
}

debug_cross :: proc(
    draw:^Debug_Draw,center:mm.Vec3,radius:f32,color:mm.Vec4,duration:f32=0,
) -> bool {
    return debug_draw_offer(draw,{kind=.Cross,a=center,color=color,size=radius,seconds=duration})
}

@(step="render",stage="end",loops="game editor")
debug_draw_submit :: proc(
    draw:^Debug_Draw,extras:^host.Frame_Extras,frame:core.Frame_Time,problems:^core.Problems,
) {
    if len(draw.shapes)==0 {return}
    if draw.vertices==nil {
        vertices,error:=make([]Debug_Vertex,DEBUG_DRAW_VERTICES)
        if error!=nil {
            core.report(problems,core.NONE,"render.debug_memory","out of memory for debug vertices")
            clear(&draw.shapes)
            return
        }
        draw.vertices=vertices
    }
    lines:=debug_draw_batch(draw,frame.dt)
    if lines.count>0 {_=host.extras_debug_lines_add(extras,lines)}
    if lines.dropped>0 {
        core.report(problems,core.NONE,"render.debug_capacity",
            "debug lines exceeded the frame capacity; draw fewer primitives")
    }
}

@(private)
debug_draw_batch :: proc(draw:^Debug_Draw,dt:f32) -> Debug_Lines {
    lines:=debug_lines_make(draw.vertices)
    kept:=0
    for shape in draw.shapes {
        switch shape.kind {
        case .Line: gpu.debug_line(&lines,shape.a,shape.b,shape.color)
        case .Box: gpu.debug_box(&lines,shape.a,shape.b,shape.color)
        case .Sphere: gpu.debug_sphere(&lines,shape.a,shape.size,shape.color,16)
        case .Arrow: gpu.debug_arrow(&lines,shape.a,shape.b,shape.color,shape.size)
        case .Cross:
            for axis in 0..<3 {
                offset:mm.Vec3
                offset[axis]=shape.size
                gpu.debug_line(&lines,shape.a-offset,shape.a+offset,shape.color)
            }
        }
        if shape.seconds>max(dt,0) {
            draw.shapes[kept]=shape
            draw.shapes[kept].seconds-=max(dt,0)
            kept+=1
        }
    }
    base.truncate(&draw.shapes,kept)
    return lines
}
