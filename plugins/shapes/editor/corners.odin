package shapes_editor

import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import shapes "plugins:shapes/runtime"
import mm "mirai:std/math"

// The corners of an outline shape: a drag moves one, an insertion or a
// removal changes one; each is one step. A move the shape refuses (edges
// that would cross) does not apply and the corner stays where it was last
// taken.

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
// and the point of that edge nearest to it, in the local XY.
Corner_Hover :: struct {
    entity:core.Entity,
    vertex,edge:int, // -1: none
    at:[2]f32,
}

corner_drag_begin :: proc(drag:^Corner_Drag,e:core.Entity,vertex:int,shape:shapes.Shape) {
    drag^={active=true,entity=e,vertex=vertex,shape=shape}
}

// Moves the corner of the drag to a point of the local XY of the shape, in
// the step of the drag, which the first move that applies opens.
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
        if !editor.edits_begin(s.edits,s.selection,"Move corner") {return .Invalid}
        drag.opened=true
    }
    if !shape_write(s,w,info,drag.entity,&t) {return .Invalid}
    drag.shape=t
    return .None
}

// The drag becomes its step; without a move that applied there is none.
corner_drag_end :: proc(s:^editor.Session,drag:^Corner_Drag) {
    if drag.opened {editor.edits_end(s.edits)}
    drag^={}
}

corner_drag_cancel :: proc(s:^editor.Session,drag:^Corner_Drag) {
    if drag.opened {editor.edits_cancel(s.edits,editor.editing_world(s))}
    drag^={}
}

// Inserts or removes a corner of an outline shape, or moves one, in the
// step that is open or in one of its own named label. index: the corner, or
// the edge by its first corner for an insertion; at: in the local XY.
corner_edit :: proc(s:^editor.Session,e:core.Entity,op:Corner_Op,index:int,at:[2]f32,label:string) -> shapes.Shape_Error {
    w:=editor.editing_world(s)
    _,info:=core.world_table(w,shapes.Shape)
    shape,found:=editor.entity_get(w,e,shapes.Shape)
    if info==nil || !found || shape.kind!=.Outline {return .Invalid}
    error:shapes.Shape_Error
    switch op {
    case .Move:   error=shapes.shape_vertex_move(&shape,index,at)
    case .Insert: error=shapes.shape_vertex_insert(&shape,index,at)
    case .Remove: error=shapes.shape_vertex_remove(&shape,index)
    }
    if error!=.None {return error}
    opened:=!s.edits.open
    if opened && !editor.edits_begin(s.edits,s.selection,label) {return .Invalid}
    written:=shape_write(s,w,info,e,&shape)
    if opened {
        if written {editor.edits_end(s.edits)} else {editor.edits_cancel(s.edits,w)}
    }
    return written?.None:.Invalid
}

// The corner, or else the edge, of a shape placed at t that is within
// CORNER_REACH of a point of the window; local is the pointer on its plane.
corner_hover :: proc(s:^editor.Session,shape:^shapes.Shape,t:mm.Transform,pointer:[2]f32,local:[2]f32,on_plane:bool) -> (hover:Corner_Hover) {
    hover.vertex,hover.edge=-1,-1
    count:=min(int(shape.point_count),shapes.SHAPE_POINTS)
    best:=CORNER_REACH
    for p,i in shape.points[:count] {
        screen,seen:=editor.viewport_screen(s.viewport,mm.transform_point(t,{p.x,p.y,0}))
        if d:=linalg.distance(screen,pointer);seen && d<=best {hover.vertex,best=i,d}
    }
    if hover.vertex>=0 || !on_plane {return}
    best=CORNER_REACH
    first:=0
    for l in 0..<min(int(shape.loop_count),shapes.SHAPE_LOOPS) {
        n:=int(shape.loops[l])
        if first+n>count {break}
        for i in 0..<n {
            a,b:=shape.points[first+i],shape.points[first+(i+1)%n]
            sa,seen_a:=editor.viewport_screen(s.viewport,mm.transform_point(t,{a.x,a.y,0}))
            sb,seen_b:=editor.viewport_screen(s.viewport,mm.transform_point(t,{b.x,b.y,0}))
            if !seen_a || !seen_b {continue}
            if d:=linalg.distance(segment_nearest(sa,sb,pointer),pointer);d<=best {
                hover.edge,best=first+i,d
                hover.at=segment_nearest(a,b,local)
            }
        }
        first+=n
    }
    return
}

@(private)
segment_nearest :: proc "contextless" (a,b,p:[2]f32) -> [2]f32 {
    ab:=b-a
    length:=ab.x*ab.x+ab.y*ab.y
    if !(length>0) {return a}
    return a+ab*clamp(((p.x-a.x)*ab.x+(p.y-a.y)*ab.y)/length,0,1)
}
