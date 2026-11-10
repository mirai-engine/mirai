package shapes_editor

import "core:math"
import "core:mem"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import shapes "plugins:shapes/runtime"
import mm "mirai:std/math"

// The corners of a shape, of the polygon of a Solid or the points of a
// Spline: a drag moves one, an insertion or a removal changes one; each is one
// step. A move the shape refuses (edges that would cross) does not apply and
// the corner stays where it was last taken.

CORNER_REACH :: f32(10) // points of the window from a corner or an edge within which the pointer takes it

Corner_Op :: enum u8 {Move,Insert,Remove}

Corner_Drag :: struct {
    active:bool,
    opened:bool, // its step is open: a move applied
    entity:core.Entity,
    vertex:int,
    shape:shapes.Shape, // as the drag leaves it
}

// What the pointer is over: a corner or else an edge, by its first corner,
// and the point of that edge nearest to it, in the plane of the corners.
Corner_Hover :: struct {
    entity:core.Entity,
    vertex,edge:int, // -1: none
    at:[2]f32,
}

// The point of a spline last taken, whose width and height the panel shows.
Corner_Taken :: struct {
    entity:core.Entity,
    vertex:int,
}

Corner_Size :: struct {
    width:f32 `mirai:"min=0,unit=m"`,
    height:f32 `mirai:"unit=m"`, // over the ground
}

// Writes the width or the height of the point taken, in the step that is open or in one of its own.
corner_size_write :: proc(s:^editor.Session,user:rawptr,offset:int,bytes:[]u8) {
    taken:=(^Corner_Taken)(user)^
    w:=editor.editing_world(s)
    _,info:=core.world_table(w,shapes.Shape)
    shape,found:=editor.entity_get(w,taken.entity,shapes.Shape)
    if info==nil || !found || shape.kind!=.Spline || taken.vertex<0 || taken.vertex>=int(shape.point_count) {return}
    size:=Corner_Size{shape.widths[taken.vertex],shape.heights[taken.vertex]}
    if offset<0 || offset+len(bytes)>size_of(size) {return}
    mem.copy(rawptr(uintptr(&size)+uintptr(offset)),raw_data(bytes),len(bytes))
    shape.widths[taken.vertex],shape.heights[taken.vertex]=max(size.width,0),size.height
    opened:=!s.edits.open
    if opened && !history.edits_begin(s.edits,s.selection,"Point size") {return}
    written:=shape_write(s,w,info,taken.entity,&shape)
    if opened {
        if written {history.edits_end(s.edits)} else {history.edits_cancel(s.edits,w)}
    }
}

corner_drag_begin :: proc(drag:^Corner_Drag,e:core.Entity,vertex:int,shape:shapes.Shape) {
    drag^={active=true,entity=e,vertex=vertex,shape=shape}
}

// Moves the corner of the drag to a point of the plane of the corners of the
// shape, in the step of the drag, which the first move that applies opens.
corner_drag_move :: proc(s:^editor.Session,drag:^Corner_Drag,to:[2]f32) -> shapes.Shape_Error {
    if !drag.active {return .Invalid}
    // A call of the API or an undo closed the step of the drag: it ends there.
    if drag.opened && !s.edits.open {
        drag^={}
        return .Invalid
    }
    t:=drag.shape
    if error:=shapes.shape_vertex_move(&t,drag.vertex,to);error!=.None {return error}
    if t.points[drag.vertex]==drag.shape.points[drag.vertex] {return .None}
    w:=editor.editing_world(s)
    _,info:=core.world_table(w,shapes.Shape)
    if info==nil {return .Invalid}
    if !drag.opened {
        if !history.edits_begin(s.edits,s.selection,"Move corner") {return .Invalid}
        drag.opened=true
    }
    if !shape_write(s,w,info,drag.entity,&t) {return .Invalid}
    drag.shape=t
    return .None
}

// The drag becomes its step; without a move that applied there is none.
corner_drag_end :: proc(s:^editor.Session,drag:^Corner_Drag) {
    if drag.opened {history.edits_end(s.edits)}
    drag^={}
}

corner_drag_cancel :: proc(s:^editor.Session,drag:^Corner_Drag) {
    if drag.opened {history.edits_cancel(s.edits,editor.editing_world(s))}
    drag^={}
}

// Inserts or removes a corner of a shape, or moves one, in the step that is
// open or in one of its own named label. index: the corner, or the edge by its
// first corner for an insertion; at: in the plane of the corners.
corner_edit :: proc(s:^editor.Session,e:core.Entity,op:Corner_Op,index:int,at:[2]f32,label:string) -> shapes.Shape_Error {
    w:=editor.editing_world(s)
    _,info:=core.world_table(w,shapes.Shape)
    shape,found:=editor.entity_get(w,e,shapes.Shape)
    if info==nil || !found || shape.loop_count==0 {return .Invalid}
    error:shapes.Shape_Error
    switch op {
    case .Move:   error=shapes.shape_vertex_move(&shape,index,at)
    case .Insert: error=shapes.shape_vertex_insert(&shape,index,at)
    case .Remove: error=shapes.shape_vertex_remove(&shape,index)
    }
    if error!=.None {return error}
    opened:=!s.edits.open
    if opened && !history.edits_begin(s.edits,s.selection,label) {return .Invalid}
    written:=shape_write(s,w,info,e,&shape)
    if opened {
        if written {history.edits_end(s.edits)} else {history.edits_cancel(s.edits,w)}
    }
    return written?.None:.Invalid
}

// The plane the corners of a shape placed at t lie on, as a transform whose
// local XY holds them: the local XY of a Solid; the local XZ of a Spline,
// raised by the height of a corner, or not for -1.
corner_plane :: proc(t:mm.Transform,shape:^shapes.Shape,vertex:int) -> mm.Transform {
    if shape.kind!=.Spline {return t}
    height:=vertex>=0 && vertex<shapes.SHAPE_POINTS?shape.heights[vertex]:0
    return mm.transform_compose(t,{{0,height,0},mm.quat_axis_angle({1,0,0},0.5*math.PI),{1,1,1}})
}

// A corner of a shape placed at t, in the world.
corner_world :: proc(t:mm.Transform,shape:^shapes.Shape,vertex:int) -> [3]f32 {
    p:=shape.points[vertex]
    return mm.transform_point(corner_plane(t,shape,vertex),{p.x,p.y,0})
}

// The edges of the corners of a shape, each by its first corner and the one it runs to: the loops of a
// polygon close, the path of a Spline does not.
corner_edges :: proc(shape:^shapes.Shape,out:^[dynamic][2]int) {
    count:=min(int(shape.point_count),shapes.SHAPE_POINTS)
    first:=0
    for l in 0..<min(int(shape.loop_count),shapes.SHAPE_LOOPS) {
        n:=int(shape.loops[l])
        if first+n>count {break}
        for i in 0..<(shape.kind==.Spline?n-1:n) {append(out,[2]int{first+i,first+(i+1)%n})}
        first+=n
    }
}

// The corner, or else the edge, of a shape placed at t that is within
// CORNER_REACH of a point of the window.
corner_hover :: proc(s:^editor.Session,shape:^shapes.Shape,t:mm.Transform,pointer:[2]f32) -> (hover:Corner_Hover) {
    hover.vertex,hover.edge=-1,-1
    count:=min(int(shape.point_count),shapes.SHAPE_POINTS)
    best:=CORNER_REACH
    for i in 0..<count {
        screen,seen:=editor.viewport_screen(s.viewport,corner_world(t,shape,i))
        if d:=linalg.distance(screen,pointer);seen && d<=best {hover.vertex,best=i,d}
    }
    if hover.vertex>=0 {return}
    best=CORNER_REACH
    edges:=make([dynamic][2]int,context.temp_allocator)
    corner_edges(shape,&edges)
    for edge in edges {
        sa,seen_a:=editor.viewport_screen(s.viewport,corner_world(t,shape,edge[0]))
        sb,seen_b:=editor.viewport_screen(s.viewport,corner_world(t,shape,edge[1]))
        if !seen_a || !seen_b {continue}
        along:=segment_along(sa,sb,pointer)
        if d:=linalg.distance(sa+(sb-sa)*along,pointer);d<=best {
            a,b:=shape.points[edge[0]],shape.points[edge[1]]
            hover.edge,hover.at,best=edge[0],a+(b-a)*along,d
        }
    }
    return
}

// How far along ab the point of it nearest to p is, from 0 at a to 1 at b.
@(private)
segment_along :: proc "contextless" (a,b,p:[2]f32) -> f32 {
    ab:=b-a
    length:=ab.x*ab.x+ab.y*ab.y
    if !(length>0) {return 0}
    return clamp(((p.x-a.x)*ab.x+(p.y-a.y)*ab.y)/length,0,1)
}
