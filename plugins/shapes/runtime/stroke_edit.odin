package shapes

import "core:math/linalg"
import "core:mem"
import "mirai:core"
import "mirai:std/geom"
import mm "mirai:std/math"

// A stroke applied to the polygons of the shapes of a plane, which the caller gives
// as pieces with their entities and where their local XY is. Each change of
// the area combines the shape of a piece as it was given with the whole area:
// adding goes into one piece, the first the area joins at the first point or
// else a new one; cutting goes out of every piece it reaches. The polygons
// past the first of a result go to the pieces split from it, which keep their
// place, and so their entities, while the edit lasts; a piece cut away whole
// is gone. The caller writes what changed (shape_edit_next) into its world.

COPLANAR_TURN :: f32(1e-4)     // 1 - |cos| of the angle between the normals of shapes of one plane
COPLANAR_DISTANCE :: f32(1e-3) // m between the planes of shapes of one plane

Shape_Edit :: struct {
    cut:bool,
    made:Shape,         // what a shape the edit makes outside every piece starts from
    plane:mm.Transform, // the XY of the stroke at z = 0, in the world
    stroke:Shape_Stroke,
    pieces:[dynamic]Shape_Piece,
    target:int,         // the piece an add goes into; -1 until the first point finds or makes it
    set:geom.Polygon_Set,
    local:[dynamic]geom.Vec2,
}

Shape_Piece :: struct {
    entity:core.Entity, // the caller's: NONE while the shape has none
    given:bool,         // the caller gave it (shape_edit_piece), and it has a base
    from:core.Entity,   // the given entity a piece split from copies; NONE: a shape of its own
    split_of:int,       // the piece whose result it takes a polygon of; -1: none
    world:mm.Transform, // where its local XY is
    base:Shape,         // as it was given
    shape:Shape,        // now
    reached:bool,       // the area of the stroke reached its base
    changed:bool,       // the edit changed, made or took it
    dirty:bool,         // changed since shape_edit_next last gave it
    gone:bool,          // a cut took it away whole
}

// Starts an edit: a stamp (stamp_points around 0, in the units of the plane)
// swept on a plane, cutting or adding. tolerance: as in shape_stroke_begin.
// made: the depth, material, uv scale and bevel of a shape an add makes outside
// every piece. Invalid for a size that is not positive and for a plane that
// is not finite or has a zero axis.
shape_edit_begin :: proc(e:^Shape_Edit,plane:mm.Transform,cut:bool,kind:Stamp_Kind,size,angle,tolerance:f32,made:Shape,allocator:=context.allocator) -> Shape_Error {
    shape_edit_free(e)
    q:=plane.rotation
    if !(size>0) || !finite3(plane.position) || !scale_usable(plane.scale) || !(abs(q.x)<=2 && abs(q.y)<=2 && abs(q.z)<=2 && abs(q.w)<=2) {return .Invalid}
    brush:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(kind,{},size,angle,&brush)
    if error:=shape_stroke_begin(&e.stroke,brush[:],tolerance,allocator);error!=.None {return error}
    e.pieces=make([dynamic]Shape_Piece,allocator)
    geom.polygon_set_init(&e.set,allocator)
    e.local=make([dynamic]geom.Vec2,allocator)
    e.cut,e.made,e.plane,e.target=cut,made,plane,-1
    return .None
}

shape_edit_free :: proc(e:^Shape_Edit) {
    shape_stroke_destroy(&e.stroke)
    delete(e.pieces)
    geom.polygon_set_destroy(&e.set)
    delete(e.local)
    e^={}
}

// Gives the edit a Solid shape with a polygon it may change, of an entity whose local XY
// is at world: its base is the shape as given, also when the stroke reaches
// it later. False when the edit has not begun, the shape has no valid
// polygon or its plane is not that of the edit.
shape_edit_piece :: proc(e:^Shape_Edit,entity:core.Entity,world:mm.Transform,shape:Shape) -> bool {
    shape:=shape
    if len(e.stroke.brush)<3 || shape_valid_counts(&shape)!=.None || !shape_coplanar(world,e.plane) {return false}
    _,error:=append(&e.pieces,Shape_Piece{entity=entity,given=true,split_of=-1,world=world,base=shape,shape=shape})
    return error==nil
}

// The next point of the path, on the plane: the first one starts it. What
// the area changed goes into the pieces; on an error they keep the last
// result that applied.
shape_edit_to :: proc(e:^Shape_Edit,p:geom.Vec2) -> Shape_Error {
    if !shape_stroke_to(&e.stroke,p) {return .None}
    return e.cut?edit_cut(e):edit_add(e,p)
}

// Whether a piece changed since shape_edit_next last gave it.
shape_edit_dirty :: proc(e:^Shape_Edit) -> bool {
    for piece in e.pieces {if piece.dirty {return true}}
    return false
}

// The next piece from index on that changed since it was last given, marked
// written: the caller makes an entity for it when it has none (a copy of
// from when there is one), takes its entity away when it is gone or else
// writes its shape, and keeps the entity in it.
// for piece in shape_edit_next(&e,&index) {...}
shape_edit_next :: proc(e:^Shape_Edit,index:^int) -> (piece:^Shape_Piece,ok:bool) {
    for index^<len(e.pieces) {
        piece=&e.pieces[index^]
        index^+=1
        if piece.dirty {
            piece.dirty=false
            return piece,true
        }
    }
    return nil,false
}

// Whether the local XY of t lies on the plane, its local XY at z = 0.
shape_coplanar :: proc(t,plane:mm.Transform) -> bool {
    if !scale_usable(t.scale) || !finite3(t.position) {return false}
    n:=mm.quat_rotate(plane.rotation,{0,0,1})
    m:=mm.quat_rotate(t.rotation,{0,0,1})
    return abs(linalg.dot(n,m))>=1-COPLANAR_TURN && abs(linalg.dot(t.position-plane.position,n))<=COPLANAR_DISTANCE
}

// Whether every axis of a scale is finite and not zero.
scale_usable :: proc "contextless" (scale:[3]f32) -> bool {
    return abs(scale.x)>1e-6 && abs(scale.y)>1e-6 && abs(scale.z)>1e-6 && finite3(scale)
}

// The area goes into the piece an add joins: the first point takes the
// first given piece it joins, or makes a new one there.
@(private)
edit_add :: proc(e:^Shape_Edit,at:geom.Vec2) -> Shape_Error {
    if e.target<0 {
        for i in 0..<len(e.pieces) {
            if !e.pieces[i].given {continue}
            loops,ok:=edit_area_local(e,&e.pieces[i])
            if !ok {continue}
            t:=e.pieces[i].base
            if shape_combine(&t,e.local[:],loops,.Union,&e.set)!=.None || len(e.set.polygon_loops)!=1 {continue}
            e.target=i
            break
        }
    }
    if e.target<0 {
        world:=e.plane
        world.position=mm.transform_point(e.plane,{at.x,at.y,0})
        if _,error:=append(&e.pieces,Shape_Piece{split_of=-1,world=world,shape=e.made});error!=nil {return .Geometry}
        e.target=len(e.pieces)-1
    }
    return edit_apply(e,e.target,.Union)
}

// Cuts the area out of every given piece it reaches.
@(private)
edit_cut :: proc(e:^Shape_Edit) -> (error:Shape_Error) {
    for i in 0..<len(e.pieces) {
        if !e.pieces[i].given {continue}
        if !e.pieces[i].reached {
            if _,ok:=edit_area_local(e,&e.pieces[i]);!ok {continue}
            e.pieces[i].reached=bounds_meet(e.local[:],&e.pieces[i].base)
            if !e.pieces[i].reached {continue}
        }
        if failed:=edit_apply(e,i,.Difference);failed!=.None {error=failed}
    }
    return
}

// A piece becomes its base combined with the whole area, or the area alone
// without a base; the other polygons of the result go to the pieces split
// from it. On an error the pieces keep what they had.
@(private)
edit_apply :: proc(e:^Shape_Edit,index:int,op:geom.Polygon_Op) -> Shape_Error {
    loops,ok:=edit_area_local(e,&e.pieces[index])
    if !ok {return .Invalid}
    t:=e.pieces[index].shape
    if e.pieces[index].given {
        t=e.pieces[index].base
        if error:=shape_combine(&t,e.local[:],loops,op,&e.set);error!=.None {return error}
    } else {
        geom.polygon_set_clear(&e.set)
        append(&e.set.points,..e.local[:])
        append(&e.set.loop_sizes,..loops)
        append(&e.set.polygon_loops,len(loops))
        if error:=shape_outline_set(&t,&e.set,0);error!=.None {return error}
    }
    polygons:=len(e.set.polygon_loops)
    edit_gone(&e.pieces[index],polygons==0)
    if polygons>0 {edit_take(&e.pieces[index],&t)}
    // The polygons past the first, in order, go to the pieces split from this one.
    polygon:=1
    for i in 0..<len(e.pieces) {
        if e.pieces[i].split_of!=index {continue}
        split:=e.pieces[i].shape
        if polygon<polygons && shape_outline_set(&split,&e.set,polygon)==.None {
            edit_gone(&e.pieces[i],false)
            edit_take(&e.pieces[i],&split)
        } else {
            edit_gone(&e.pieces[i],true)
        }
        polygon+=1
    }
    for ;polygon<polygons;polygon+=1 {
        source:=&e.pieces[index]
        piece:=Shape_Piece{from=source.given?source.entity:source.from,split_of=index,world=source.world,shape=source.shape,changed=true,dirty=true}
        if shape_outline_set(&piece.shape,&e.set,polygon)!=.None {continue}
        if _,error:=append(&e.pieces,piece);error!=nil {return .Geometry}
    }
    return .None
}

@(private)
edit_take :: proc(piece:^Shape_Piece,shape:^Shape) {
    if mem.compare_ptrs(&piece.shape,shape,size_of(Shape))==0 {return}
    piece.shape=shape^
    piece.changed,piece.dirty=true,true
}

@(private)
edit_gone :: proc(piece:^Shape_Piece,gone:bool) {
    if piece.gone==gone {return}
    piece.gone=gone
    piece.changed,piece.dirty=true,true
}

// The area of the stroke in the local XY of a piece, into e.local, and the
// sizes of its loops.
@(private)
edit_area_local :: proc(e:^Shape_Edit,piece:^Shape_Piece) -> (loops:[]int,ok:bool) {
    if !scale_usable(piece.world.scale) {return}
    points,sizes:=shape_stroke_area(&e.stroke)
    if len(sizes)==0 {return}
    clear(&e.local)
    for p in points {append(&e.local,mm.transform_inverse_point(piece.world,mm.transform_point(e.plane,{p.x,p.y,0})).xy)}
    return sizes,true
}

// Whether the box of a loop meets the box of the points of a shape.
@(private)
bounds_meet :: proc(loop:[]geom.Vec2,shape:^Shape) -> bool {
    count:=min(int(shape.point_count),SHAPE_POINTS)
    if len(loop)==0 || count==0 {return false}
    lo,hi:=loop[0],loop[0]
    for p in loop {lo,hi=linalg.min(lo,p),linalg.max(hi,p)}
    a,b:=shape.points[0],shape.points[0]
    for p in shape.points[:count] {a,b=linalg.min(a,p),linalg.max(b,p)}
    return lo.x<=b.x && a.x<=hi.x && lo.y<=b.y && a.y<=hi.y
}
