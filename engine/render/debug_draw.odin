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

// Requests: any library pushes shapes (debug_line, debug_box and the others)
// and render takes them. Not copied with the world: a rollback does not bring
// back shapes render already took.
@(storage,queue,copy=false)
Debug_Draw :: struct {queue:core.Queue(Debug_Primitive)}

// The shapes render draws: those that last, with the seconds they have left,
// and the room of their lines.
@(storage,copy=false)
Debug_Shapes :: struct {
    shapes:[dynamic]Debug_Primitive,
    vertices:[]Debug_Vertex,
}

// False when the queue is full or the duration is not finite and positive.
@(private)
debug_draw_offer :: proc(draw:^Debug_Draw,shape:Debug_Primitive) -> bool {
    if draw==nil {return false}
    if !(shape.seconds>=0) || math.is_inf(shape.seconds) {
        core.refuse(&draw.queue)
        return false
    }
    dropped:=draw.queue.dropped
    core.offer(&draw.queue,shape)
    return draw.queue.dropped==dropped
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

// Takes what a fixed tick asked for. A tick that runs again (Time.resimulating)
// asks again for what it asked the first time: render already has it.
@(step="fixed late",stage="end",loops="game editor")
debug_draw_tick :: proc(draw:^Debug_Draw,shapes:^Debug_Shapes,time:core.Time,problems:^core.Problems) {
    asked:=core.take(&draw.queue)
    if !time.resimulating {debug_shapes_add(shapes,asked,problems)}
}

// Takes what the frame asked for and gives the lines of every shape to the
// renderer; those that last lose the seconds of the frame.
@(step="render",stage="end",loops="game editor")
debug_draw_submit :: proc(
    draw:^Debug_Draw,shapes:^Debug_Shapes,extras:^host.Frame_Extras,frame:core.Frame_Time,
    problems:^core.Problems,
) {
    core.queue_serve(&draw.queue,DEBUG_DRAW_CAPACITY,problems,"render.debug_capacity","debug shapes",
        "DEBUG_DRAW_CAPACITY","give a duration of 0 or more seconds")
    debug_shapes_add(shapes,core.take(&draw.queue),problems)
    if len(shapes.shapes)==0 {return}
    if shapes.vertices==nil {
        vertices,error:=make([]Debug_Vertex,DEBUG_DRAW_VERTICES)
        if error!=nil {
            core.report(problems,core.NONE,"render.debug_memory","out of memory for debug vertices")
            clear(&shapes.shapes)
            return
        }
        shapes.vertices=vertices
    }
    lines:=debug_draw_batch(shapes,frame.dt)
    if lines.count>0 {_=host.extras_debug_lines_add(extras,lines)}
    if lines.dropped>0 {
        core.report(problems,core.NONE,"render.debug_capacity",
            "debug lines exceeded the frame capacity; draw fewer primitives")
    }
}

@(private)
debug_shapes_add :: proc(shapes:^Debug_Shapes,asked:[]Debug_Primitive,problems:^core.Problems) {
    if len(asked)==0 {return}
    if cap(shapes.shapes)==0 && reserve(&shapes.shapes,DEBUG_DRAW_CAPACITY)!=nil {
        core.report(problems,core.NONE,"render.debug_memory","out of memory for debug shapes")
        return
    }
    room:=DEBUG_DRAW_CAPACITY-len(shapes.shapes)
    append(&shapes.shapes,..asked[:min(len(asked),room)])
    if len(asked)>room {
        core.report(problems,core.NONE,"render.debug_capacity",
            "%d debug shapes are drawn at once; %d did not fit: draw fewer, or for less time",
            DEBUG_DRAW_CAPACITY,len(asked)-room)
    }
}

@(private)
debug_draw_batch :: proc(draw:^Debug_Shapes,dt:f32) -> Debug_Lines {
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
