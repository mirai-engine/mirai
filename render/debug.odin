package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:rhi"
import mm "mirai:std/math"

// Immediate lines for debug views, gizmos and tools: a batch is filled every
// frame with lines and wire shapes and handed to renderer_frame, which draws
// it over the finished image, one pixel wide and in display colors.

Debug_Vertex :: struct {
    position:Vec3,
    color:   u32, // rgba8, display space
}
#assert(size_of(Debug_Vertex)==16)

// Lines in the storage of the caller, two vertices each. A line that does not
// fit is dropped and counted.
Debug_Lines :: struct {
    vertices:  []Debug_Vertex,
    count:     int, // vertices written
    dropped:   int, // lines that did not fit since the last clear
    depth_test:bool, // hidden where an opaque surface of the scene is in front
}

debug_lines_make :: proc(storage:[]Debug_Vertex,depth_test:=true) -> Debug_Lines {
    return {vertices=storage,depth_test=depth_test}
}

debug_lines_clear :: proc(lines:^Debug_Lines) {
    lines.count,lines.dropped=0,0
}

debug_line :: proc(lines:^Debug_Lines,from,to:Vec3,color:Vec4) {
    if lines.count+2>len(lines.vertices) {lines.dropped+=1;return}
    packed:=mm.rgba8_pack(color)
    lines.vertices[lines.count]={from,packed}
    lines.vertices[lines.count+1]={to,packed}
    lines.count+=2
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

// Records the batches into the pass of the LDR target. The lines are
// projected without the jitter of the scene and tested against its depth in
// the shader (overlay.slang).
@(private)
debug_lines_pass :: proc(r:^Renderer,cmd:^rhi.Command_List,t:^Targets,slot:int,batches:[]Debug_Lines) {
    target:=cast([^]Debug_Vertex)rhi.buffer_mapped(r.device,r.debug_buffers[slot])
    written:=0
    bound:=false
    for batch in batches {
        count:=min(batch.count,len(batch.vertices),r.debug_capacity-written)/2*2
        r.stats.debug_vertices_dropped+=u32(max(min(batch.count,len(batch.vertices))-count,0))
        if count<2 {continue}
        mem.copy(&target[written],raw_data(batch.vertices),count*size_of(Debug_Vertex))
        if !bound {
            rhi.cmd_bind_pipeline(cmd,r.pipelines[.Debug_Lines])
            rhi.cmd_bind_buffer(cmd,SLOT_PASS0,r.debug_buffers[slot])
            rhi.cmd_bind_texture(cmd,SLOT_PASS1,t.linear_depth)
            rhi.cmd_bind_texture(cmd,SLOT_VIEWS,t.motion)
            bound=true
        }
        Params :: struct {viewport:Vec2,depth_test,pad:u32}
        params:=Params{viewport={f32(t.output_width),f32(t.output_height)},depth_test=1 if batch.depth_test else 0}
        set_params(cmd,&params)
        rhi.cmd_draw(cmd,u32(count),1,u32(written))
        written+=count
    }
}
