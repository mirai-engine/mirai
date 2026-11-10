package shapes_editor

import "core:math"
import "core:mem"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import volume "mirai:engine/volume"
import shapes "plugins:shapes/runtime"
import mm "mirai:std/math"

// The corners of an entity: the polygon of its Shape or the points of its
// volume.Spline. A drag moves one, an insertion or a removal changes one;
// each is one step. A move the polygon refuses (edges that would cross) does
// not apply and the corner stays where it was last taken.

CORNER_REACH :: f32(10) // points of the window from a corner or an edge within which the pointer takes it

Corner_Op :: enum u8 {Move,Insert,Remove}

// What the corners of an entity are: the polygon of its Shape, in its local
// XY, or else the path of its Spline, which is open, its points in its local XZ.
Corners :: struct {
    spline:bool,
    shape:shapes.Shape,
    path:volume.Spline,
}

Corner_Drag :: struct {
    active:bool,
    opened:bool, // its step is open: a move applied
    entity:core.Entity,
    vertex:int,
    corners:Corners, // as the drag leaves them
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

// The corners of an entity: those of the polygon of its Shape, else those of its Spline.
corners_of :: proc(w:core.World_Ref,e:core.Entity) -> (c:Corners,found:bool) {
    if shape,ok:=editor.entity_get(w,e,shapes.Shape);ok && shape.loop_count>0 {return {shape=shape},true}
    if path,ok:=editor.entity_get(w,e,volume.Spline);ok {return {spline=true,path=path},true}
    return
}

corner_count :: proc(c:^Corners) -> int {
    return c.spline?min(int(c.path.count),volume.SPLINE_POINTS):min(int(c.shape.point_count),shapes.SHAPE_POINTS)
}

// A corner in the plane of the corners.
corner_at :: proc(c:^Corners,vertex:int) -> [2]f32 {
    if c.spline {return c.path.points[vertex].position.xz}
    return c.shape.points[vertex]
}

// Writes the corners of an entity, in the step that is open.
corners_write :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity,c:^Corners) -> bool {
    if !c.spline {
        _,info:=core.world_table(w,shapes.Shape)
        return info!=nil && shape_write(s,w,info,e,&c.shape)
    }
    _,info:=core.world_table(w,volume.Spline)
    return info!=nil && editor.field_write(s,info,{e},0,mem.ptr_to_bytes(&c.path))
}

// Moves, inserts or removes a corner: on a polygon as the Shape allows; on a
// spline a point inserted takes the width and height in proportion between
// the ends of its edge, and the path keeps two points.
corner_apply :: proc(c:^Corners,op:Corner_Op,index:int,at:[2]f32) -> shapes.Shape_Error {
    if !c.spline {
        switch op {
        case .Move:   return shapes.shape_vertex_move(&c.shape,index,at)
        case .Insert: return shapes.shape_vertex_insert(&c.shape,index,at)
        case .Remove: return shapes.shape_vertex_remove(&c.shape,index)
        }
    }
    p:=&c.path
    count:=corner_count(c)
    if !(at.x-at.x==0 && at.y-at.y==0) || index<0 || index>=count-(op==.Insert?1:0) {return .Invalid}
    switch op {
    case .Move:
        p.points[index].position.xz=at
    case .Insert:
        if count>=volume.SPLINE_POINTS {return .Too_Many_Points}
        a,b:=p.points[index],p.points[index+1]
        along:=segment_along(a.position.xz,b.position.xz,at)
        copy(p.points[index+2:count+1],p.points[index+1:count])
        p.points[index+1]={linalg.lerp(a.position,b.position,along),math.lerp(a.width,b.width,along),math.lerp(a.height,b.height,along)}
        p.points[index+1].position.xz=at
        p.count+=1
    case .Remove:
        if count<=2 {return .Invalid}
        copy(p.points[index:count-1],p.points[index+1:count])
        p.points[count-1]={}
        p.count-=1
    }
    return .None
}

// Writes the width or the height of the point taken, in the step that is open or in one of its own.
corner_size_write :: proc(s:^editor.Session,user:rawptr,offset:int,bytes:[]u8) {
    taken:=(^Corner_Taken)(user)^
    w:=editor.editing_world(s)
    c,found:=corners_of(w,taken.entity)
    if !found || !c.spline || taken.vertex<0 || taken.vertex>=corner_count(&c) {return}
    point:=&c.path.points[taken.vertex]
    size:=Corner_Size{point.width,point.height}
    if offset<0 || offset+len(bytes)>size_of(size) {return}
    mem.copy(rawptr(uintptr(&size)+uintptr(offset)),raw_data(bytes),len(bytes))
    point.width,point.height=max(size.width,0),size.height
    opened:=!s.edits.open
    if opened && !history.edits_begin(s.edits,s.selection,"Point size") {return}
    written:=corners_write(s,w,taken.entity,&c)
    if opened {
        if written {history.edits_end(s.edits)} else {history.edits_cancel(s.edits,w)}
    }
}

corner_drag_begin :: proc(drag:^Corner_Drag,e:core.Entity,vertex:int,c:Corners) {
    drag^={active=true,entity=e,vertex=vertex,corners=c}
}

// Moves the corner of the drag to a point of the plane of the corners, in the
// step of the drag, which the first move that applies opens.
corner_drag_move :: proc(s:^editor.Session,drag:^Corner_Drag,to:[2]f32) -> shapes.Shape_Error {
    if !drag.active {return .Invalid}
    // A call of the API or an undo closed the step of the drag: it ends there.
    if drag.opened && !s.edits.open {
        drag^={}
        return .Invalid
    }
    c:=drag.corners
    if error:=corner_apply(&c,.Move,drag.vertex,to);error!=.None {return error}
    if corner_at(&c,drag.vertex)==corner_at(&drag.corners,drag.vertex) {return .None}
    w:=editor.editing_world(s)
    if !drag.opened {
        if !history.edits_begin(s.edits,s.selection,"Move corner") {return .Invalid}
        drag.opened=true
    }
    if !corners_write(s,w,drag.entity,&c) {return .Invalid}
    drag.corners=c
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

// Inserts or removes a corner of an entity, or moves one, in the step that is
// open or in one of its own named label. index: the corner, or the edge by its
// first corner for an insertion; at: in the plane of the corners.
corner_edit :: proc(s:^editor.Session,e:core.Entity,op:Corner_Op,index:int,at:[2]f32,label:string) -> shapes.Shape_Error {
    w:=editor.editing_world(s)
    c,found:=corners_of(w,e)
    if !found {return .Invalid}
    if error:=corner_apply(&c,op,index,at);error!=.None {return error}
    opened:=!s.edits.open
    if opened && !history.edits_begin(s.edits,s.selection,label) {return .Invalid}
    written:=corners_write(s,w,e,&c)
    if opened {
        if written {history.edits_end(s.edits)} else {history.edits_cancel(s.edits,w)}
    }
    return written?.None:.Invalid
}

// The plane the corners of an entity placed at t lie on, as a transform whose
// local XY holds them: its local XY for a polygon; its local XZ for a spline,
// at the height of a point over the plane of the entity, or at its plane for -1.
corner_plane :: proc(t:mm.Transform,c:^Corners,vertex:int) -> mm.Transform {
    if !c.spline {return t}
    up:=f32(0)
    if vertex>=0 && vertex<volume.SPLINE_POINTS {up=c.path.points[vertex].position.y+c.path.points[vertex].height}
    return mm.transform_compose(t,{{0,up,0},mm.quat_axis_angle({1,0,0},0.5*math.PI),{1,1,1}})
}

// A corner of an entity placed at t, in the world.
corner_world :: proc(t:mm.Transform,c:^Corners,vertex:int) -> [3]f32 {
    p:=corner_at(c,vertex)
    return mm.transform_point(corner_plane(t,c,vertex),{p.x,p.y,0})
}

// The edges of the corners, each by its first corner and the one it runs to:
// the loops of a polygon close, the path of a spline does not.
corner_edges :: proc(c:^Corners,out:^[dynamic][2]int) {
    count:=corner_count(c)
    if c.spline {
        for i in 0..<count-1 {append(out,[2]int{i,i+1})}
        return
    }
    first:=0
    for l in 0..<min(int(c.shape.loop_count),shapes.SHAPE_LOOPS) {
        n:=int(c.shape.loops[l])
        if first+n>count {break}
        for i in 0..<n {append(out,[2]int{first+i,first+(i+1)%n})}
        first+=n
    }
}

// The corner nearest to a point of the plane of the corners, and the edge
// nearest to it with the point of that edge nearest to it.
corner_near :: proc(c:^Corners,p:[2]f32) -> (vertex,edge:int,at:[2]f32) {
    vertex,edge=-1,-1
    best:=max(f32)
    for i in 0..<corner_count(c) {
        if d:=linalg.length2(corner_at(c,i)-p);d<best {vertex,best=i,d}
    }
    best=max(f32)
    edges:=make([dynamic][2]int,context.temp_allocator)
    corner_edges(c,&edges)
    for e in edges {
        a,b:=corner_at(c,e[0]),corner_at(c,e[1])
        q:=a+(b-a)*segment_along(a,b,p)
        if d:=linalg.length2(q-p);d<best {edge,at,best=e[0],q,d}
    }
    return
}

// The corner, or else the edge, of an entity placed at t that is within
// CORNER_REACH of a point of the window.
corner_hover :: proc(s:^editor.Session,c:^Corners,t:mm.Transform,pointer:[2]f32) -> (hover:Corner_Hover) {
    hover.vertex,hover.edge=-1,-1
    best:=CORNER_REACH
    for i in 0..<corner_count(c) {
        screen,seen:=editor.viewport_screen(s.viewport,corner_world(t,c,i))
        if d:=linalg.distance(screen,pointer);seen && d<=best {hover.vertex,best=i,d}
    }
    if hover.vertex>=0 {return}
    best=CORNER_REACH
    edges:=make([dynamic][2]int,context.temp_allocator)
    corner_edges(c,&edges)
    for edge in edges {
        sa,seen_a:=editor.viewport_screen(s.viewport,corner_world(t,c,edge[0]))
        sb,seen_b:=editor.viewport_screen(s.viewport,corner_world(t,c,edge[1]))
        if !seen_a || !seen_b {continue}
        along:=segment_along(sa,sb,pointer)
        if d:=linalg.distance(sa+(sb-sa)*along,pointer);d<=best {
            a,b:=corner_at(c,edge[0]),corner_at(c,edge[1])
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
