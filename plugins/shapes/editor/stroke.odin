package shapes_editor

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:core"
import "mirai:editor"
import shapes "plugins:shapes/runtime"
import "mirai:std/base"
import mm "mirai:std/math"

// A stroke of a stamp on a plane (shapes.Shape_Edit) in the scene: it takes
// the polygons of the shapes of the plane as its pieces when it begins, and each
// frame writes the pieces that changed into the world, inside the one step
// of the stroke: a split makes a shape entity for each other polygon and a
// shape cut away whole is deleted.

// Where a plane is: its XY at z = 0, with scale 1.
Plane :: mm.Transform

STROKE_POINTS :: f32(2) // the shake of a hand the path leaves out, in points of the window

Stroke :: struct {
    active:bool,
    opened:bool,  // the step of the stroke is open
    refused:bool, // a change was refused and the user was told
    edit:shapes.Shape_Edit,
}

stroke_free :: proc(stroke:^Stroke) {
    shapes.shape_edit_free(&stroke.edit)
    stroke^={}
}

// The plane of a shape entity: its local XY at z = 0. Without one, the plane z = 0 of the world.
plane_of :: proc(w:core.World_Ref,e:core.Entity) -> Plane {
    if e==core.NONE {return mm.TRANSFORM_IDENTITY}
    t:=editor.entity_world(w,e)
    return {t.position,t.rotation,{1,1,1}}
}

// Where a ray of the world meets the local XY plane of t, in its local XY.
local_point :: proc(t:mm.Transform,ray:mm.Ray) -> (point:[2]f32,hit:bool) {
    if !shapes.scale_usable(t.scale) {return}
    origin:=mm.transform_inverse_point(t,ray.origin)
    direction:=mm.transform_inverse_vector(t,ray.direction)
    if abs(direction.z)<1e-9 {return}
    along:=-origin.z/direction.z
    if along<0 {return}
    p:=origin+direction*along
    return p.xy,true
}

// A world point taken onto the local XY plane of t, in its local XY.
local_of :: proc(t:mm.Transform,p:[3]f32) -> [2]f32 {return mm.transform_inverse_point(t,p).xy}

// Gives the edit the shapes with a polygon of the plane, first the one given: the
// shapes a stroke may change. tolerance: how far, in meters on the plane,
// the path may shake and stay one segment. False when the world has no
// shapes or the stamp is not valid.
stroke_begin :: proc(stroke:^Stroke,w:core.World_Ref,plane:Plane,first:core.Entity,cut:bool,kind:shapes.Stamp_Kind,size,angle,tolerance:f32,material:base.Asset_Id,allocator:runtime.Allocator) -> bool {
    stroke_free(stroke)
    table:=core.world_table_of(w,shapes.Shape)
    if table==nil {return false}
    made:=shapes.SHAPE_DEFAULT
    made.material=material
    if shapes.shape_edit_begin(&stroke.edit,plane,cut,kind,size,angle,tolerance,made,allocator)!=.None {return false}
    take :: proc(stroke:^Stroke,w:core.World_Ref,e:core.Entity,shape:^shapes.Shape) {
        if shape.loop_count==0 {return}
        shapes.shape_edit_piece(&stroke.edit,e,editor.entity_world(w,e),shape^)
    }
    if first!=core.NONE {
        if shape:=core.edit(table,first);shape!=nil {take(stroke,w,first,shape)}
    }
    for &shape,row in table.values {
        if e:=table.entities[row];e!=first {take(stroke,w,e,&shape)}
    }
    stroke.active=true
    return true
}

// The tolerance of a stroke at a point of a plane: STROKE_POINTS of the
// window in meters along the plane there, 0 where the view does not see it.
stroke_tolerance :: proc(v:^editor.Viewport,plane:Plane,at:[2]f32) -> f32 {
    center:=mm.transform_point(plane,{at.x,at.y,0})
    a,seen:=editor.viewport_screen(v,center)
    b,seen_x:=editor.viewport_screen(v,center+mm.quat_rotate(plane.rotation,{1,0,0}))
    c,seen_y:=editor.viewport_screen(v,center+mm.quat_rotate(plane.rotation,{0,1,0}))
    // Points of the window per meter, both ways along the plane.
    across:=math.sqrt(linalg.distance(a,b)*linalg.distance(a,c))
    if !seen || !seen_x || !seen_y || !(across>1e-6) {return 0}
    return STROKE_POINTS/across
}

// The next point of the path, on the plane: the first one starts it.
stroke_to :: proc(stroke:^Stroke,to:[2]f32) -> shapes.Shape_Error {
    return shapes.shape_edit_to(&stroke.edit,to)
}

@(private)
stroke_dirty :: proc(stroke:^Stroke) -> bool {return shapes.shape_edit_dirty(&stroke.edit)}

// Writes the pieces that changed into the world, in the step that is open:
// a new piece becomes a shape entity, one a cut took whole is deleted. False
// when the scene refused a write (an entity another editor holds, a section).
stroke_sync :: proc(s:^editor.Session,stroke:^Stroke) -> bool {
    w:=editor.editing_world(s)
    _,info:=core.world_table(w,shapes.Shape)
    if info==nil {return false}
    index:=0
    for piece in shapes.shape_edit_next(&stroke.edit,&index) {
        switch {
        case piece.gone:
            if piece.entity!=core.NONE {
                editor.entities_delete(s,{piece.entity})
                if editor.entity_alive(w,piece.entity) {return false}
                piece.entity=core.NONE
            }
        case piece.entity==core.NONE:
            piece.entity=piece_make(s,w,info,piece)
            if piece.entity==core.NONE {return false}
        case:
            if !shape_write(s,w,info,piece.entity,&piece.shape) {return false}
        }
    }
    return true
}

// The Shape of an entity, in the step that is open or in one of its own. A
// row added in this function waits for its end: it gets the value again.
shape_write :: proc(s:^editor.Session,w:core.World_Ref,info:^core.Table_Info,e:core.Entity,shape:^shapes.Shape) -> bool {
    if editor.field_write(s,info,{e},0,mem.ptr_to_bytes(shape)) {return true}
    if editor.entity_has(w,e,shapes.Shape) || !editor.entity_alive(w,e) {return false}
    editor.component_add(s,e,info,shape)
    return true
}

// A piece as a shape entity: a copy of the shape it split from, with all its
// components, or a new one at its place.
@(private)
piece_make :: proc(s:^editor.Session,w:core.World_Ref,info:^core.Table_Info,piece:^shapes.Shape_Piece) -> core.Entity {
    if piece.from!=core.NONE && editor.entity_alive(w,piece.from) {
        copies:=editor.entities_duplicate(s,{piece.from},"Stamp")
        if len(copies)!=1 || copies[0]==core.NONE {return core.NONE}
        if !shape_write(s,w,info,copies[0],&piece.shape) {return core.NONE}
        return copies[0]
    }
    e:=editor.entity_create(s,{name="Shape",transform=core.from_math(piece.world)})
    if e==core.NONE {return core.NONE}
    editor.component_add(s,e,info,&piece.shape)
    return e
}

// The entities a stroke changed or made, and how many it took away whole.
stroke_results :: proc(stroke:^Stroke,out:[]core.Entity) -> (count,removed:int) {
    for piece in stroke.edit.pieces {
        if !piece.changed {continue}
        if piece.gone {
            if piece.given {removed+=1}
            continue
        }
        if piece.entity==core.NONE {continue}
        if count<len(out) {out[count]=piece.entity}
        count+=1
    }
    return
}
