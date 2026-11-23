package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:rhi"
import mm "mirai:std/math"

// Immediate lines and solids for debug views, gizmos and tools: a batch is
// filled every frame with lines and wire shapes, or with triangles, and handed
// to renderer_frame, which draws it over the finished image in display colors:
// lines one pixel wide, triangles shaded by how much they face the view.

Debug_Vertex :: struct {
    position:Vec3,
    color:   u32, // rgba8, display space
}
#assert(size_of(Debug_Vertex)==16)

// Lines in the storage of the caller, two vertices each, or triangles, three
// each, wound counterclockwise seen from their front. A shape that does not fit,
// or is not of the kind of the batch, is dropped and counted.
Debug_Lines :: struct {
    vertices:  []Debug_Vertex,
    count:     int, // vertices written
    dropped:   int, // shapes that did not fit since the last clear
    depth_test:bool, // hidden where an opaque surface of the scene is in front
    triangles: bool,
}

debug_lines_make :: proc(storage:[]Debug_Vertex,depth_test:=true,triangles:=false) -> Debug_Lines {
    return {vertices=storage,depth_test=depth_test,triangles=triangles}
}

debug_lines_clear :: proc(lines:^Debug_Lines) {
    lines.count,lines.dropped=0,0
}

debug_line :: proc(lines:^Debug_Lines,from,to:Vec3,color:Vec4) {
    if lines.triangles || lines.count+2>len(lines.vertices) {lines.dropped+=1;return}
    packed:=mm.rgba8_pack(color)
    lines.vertices[lines.count]={from,packed}
    lines.vertices[lines.count+1]={to,packed}
    lines.count+=2
}

debug_triangle :: proc(lines:^Debug_Lines,a,b,c:Vec3,color:Vec4) {
    if !lines.triangles || lines.count+3>len(lines.vertices) {lines.dropped+=1;return}
    packed:=mm.rgba8_pack(color)
    lines.vertices[lines.count]={a,packed}
    lines.vertices[lines.count+1]={b,packed}
    lines.vertices[lines.count+2]={c,packed}
    lines.count+=3
}

DEBUG_ARROW_SIDES :: 12
DEBUG_ARROW_VERTICES :: DEBUG_ARROW_SIDES*15 // of a solid arrow
DEBUG_ARROW_HEAD :: f32(0.25)                // of the length, the cone
DEBUG_ARROW_HEAD_WIDTH :: f32(2.5)           // times the radius of the shaft

// A solid arrow from `from` to `to`: a shaft `radius` thick, closed at its
// start, and a cone that points at `to`.
debug_arrow_solid :: proc(lines:^Debug_Lines,from,to:Vec3,color:Vec4,radius:f32) {
    span:=to-from
    length:=linalg.length(span)
    if !(length>1e-6) || !(radius>0) || math.is_inf(length) || math.is_inf(radius) {return}
    axis:=span/length
    u:=linalg.normalize(linalg.cross(axis,Vec3{1,0,0} if abs(axis.x)<0.9 else Vec3{0,1,0}))
    v:=linalg.cross(axis,u)
    neck:=to-axis*length*DEBUG_ARROW_HEAD
    shaft:=min(radius,length*DEBUG_ARROW_HEAD/DEBUG_ARROW_HEAD_WIDTH)
    wide:=shaft*DEBUG_ARROW_HEAD_WIDTH
    for i in 0..<DEBUG_ARROW_SIDES {
        a0:=f32(i)/DEBUG_ARROW_SIDES*2*math.PI
        a1:=f32(i+1)/DEBUG_ARROW_SIDES*2*math.PI
        r0:=u*math.cos(a0)+v*math.sin(a0)
        r1:=u*math.cos(a1)+v*math.sin(a1)
        debug_triangle(lines,from+r0*shaft,from+r1*shaft,neck+r1*shaft,color)
        debug_triangle(lines,from+r0*shaft,neck+r1*shaft,neck+r0*shaft,color)
        debug_triangle(lines,from,from+r1*shaft,from+r0*shaft,color)
        debug_triangle(lines,neck+r0*wide,neck+r1*wide,to,color)
        debug_triangle(lines,neck,neck+r1*wide,neck+r0*wide,color)
    }
}

// The twelve edges of a box given by two opposite corners.
debug_box :: proc(lines:^Debug_Lines,low,high:Vec3,color:Vec4) {
    debug_box_transformed(lines,Mat4(1),low,high,color)
}

// The edges of the box between two corners of the space `transform` places in the world.
debug_box_transformed :: proc(lines:^Debug_Lines,transform:Mat4,low,high:Vec3,color:Vec4) {
    corners:[8]Vec3
    for &corner,i in corners {
        local:=Vec4{high.x if i&1!=0 else low.x,high.y if i&2!=0 else low.y,high.z if i&4!=0 else low.z,1}
        corner=(transform*local).xyz
    }
    for i in 0..<8 {
        for axis in 0..<3 {
            bit:=1<<uint(axis)
            if i&bit==0 {debug_line(lines,corners[i],corners[i|bit],color)}
        }
    }
}

// A line that ends in a head of four strokes, `head` long.
debug_arrow :: proc(lines:^Debug_Lines,from,to:Vec3,color:Vec4,head:f32=0.2) {
    debug_line(lines,from,to,color)
    span:=to-from
    length:=linalg.length(span)
    if length<1e-6 {return}
    axis:=span/length
    u:=linalg.normalize(linalg.cross(axis,Vec3{1,0,0} if abs(axis.x)<0.9 else Vec3{0,1,0}))
    v:=linalg.cross(axis,u)
    size:=min(head,length)
    for side in ([4]Vec3{u,-u,v,-v}) {debug_line(lines,to,to-axis*size+side*size*0.4,color)}
}

// A circle around `normal`, of `segments` lines.
debug_circle :: proc(lines:^Debug_Lines,center,normal:Vec3,radius:f32,color:Vec4,segments:=32) {
    axis:=linalg.normalize(normal) if linalg.length(normal)>1e-6 else Vec3{0,1,0}
    u:=linalg.normalize(linalg.cross(axis,Vec3{1,0,0} if abs(axis.x)<0.9 else Vec3{0,1,0}))
    v:=linalg.cross(axis,u)
    count:=max(segments,3)
    previous:=center+u*radius
    for i in 1..=count {
        angle:=f32(i)/f32(count)*2*math.PI
        point:=center+(u*math.cos(angle)+v*math.sin(angle))*radius
        debug_line(lines,previous,point,color)
        previous=point
    }
}

// Three circles, one around each axis.
debug_sphere :: proc(lines:^Debug_Lines,center:Vec3,radius:f32,color:Vec4,segments:=32) {
    for axis in ([3]Vec3{{1,0,0},{0,1,0},{0,0,1}}) {debug_circle(lines,center,axis,radius,color,segments)}
}

// The axes of a transform: x red, y green, z blue.
debug_axes :: proc(lines:^Debug_Lines,transform:Mat4,size:f32=1) {
    origin:=(transform*Vec4{0,0,0,1}).xyz
    colors:=[3]Vec4{{1,0.2,0.2,1},{0.2,1,0.2,1},{0.3,0.5,1,1}}
    for color,axis in colors {
        direction:=Vec3{transform[0,axis],transform[1,axis],transform[2,axis]}
        debug_line(lines,origin,origin+direction*size,color)
    }
}

// Records the batches into the pass of the LDR target. The shapes are
// projected without the jitter of the scene and tested against its depth in
// the shader (overlay.slang).
@(private)
debug_lines_pass :: proc(r:^Renderer,cmd:^rhi.Command_List,t:^Targets,slot:int,batches:[]Debug_Lines) {
    target:=cast([^]Debug_Vertex)rhi.buffer_mapped(r.device,r.debug_buffers[slot])
    written:=0
    bound:=false
    pipeline:=Pipeline_Id.Debug_Lines
    for batch in batches {
        shape:=3 if batch.triangles else 2
        count:=min(batch.count,len(batch.vertices),r.debug_capacity-written)/shape*shape
        r.stats.debug_vertices_dropped+=u32(max(min(batch.count,len(batch.vertices))-count,0))
        if count<shape {continue}
        mem.copy(&target[written],raw_data(batch.vertices),count*size_of(Debug_Vertex))
        kind:=Pipeline_Id.Debug_Triangles if batch.triangles else .Debug_Lines
        if !bound || kind!=pipeline {
            rhi.cmd_bind_pipeline(cmd,r.pipelines[kind])
            rhi.cmd_bind_buffer(cmd,SLOT_PASS0,r.debug_buffers[slot])
            rhi.cmd_bind_texture(cmd,SLOT_PASS1,t.linear_depth)
            rhi.cmd_bind_texture(cmd,SLOT_VIEWS,t.views if t.views!=0 else r.dummy_uint)
            bound,pipeline=true,kind
        }
        Params :: struct {viewport:Vec2,depth_test,triangles:u32}
        params:=Params{viewport={f32(t.output_width),f32(t.output_height)},depth_test=1 if batch.depth_test else 0,triangles=1 if batch.triangles else 0}
        set_params(cmd,&params)
        rhi.cmd_draw(cmd,u32(count),1,u32(written))
        written+=count
    }
}
