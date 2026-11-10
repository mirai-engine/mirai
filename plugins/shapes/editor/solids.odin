package shapes_editor

import "core:math"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import shapes "plugins:shapes/runtime"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"

// The brushes of Solid shapes are entities: a child of the solid with
// Shape_Brush, placed by its Transform. The tool places one on the surface
// under the pointer, as one step, and finds the one under the pointer so the
// editor's gizmo can take it.

BRUSH_NAMES :: [geom.Boolean_Op][shapes.Brush_Kind]string{
    .Union={.Box="Box",.Sphere="Sphere",.Cylinder="Cylinder"},
    .Subtract={.Box="Cut box",.Sphere="Cut sphere",.Cylinder="Cut cylinder"},
    .Intersect={.Box="Intersect box",.Sphere="Intersect sphere",.Cylinder="Intersect cylinder"},
}

// Where a brush goes for a point of a surface of the world and the normal
// there: its Y along the normal, turned by angle around it, size across (half
// its width or its radius), an added brush resting on the surface and one that
// cuts or intersects centered on it.
brush_place_at :: proc(op:geom.Boolean_Op,at,normal:[3]f32,size,angle:f32) -> mm.Transform {
    n:=linalg.normalize0(normal)
    if n=={} {n={0,0,1}}
    turn:=mm.quat_between({0,1,0},n)*mm.quat_axis_angle({0,1,0},angle)
    return {op!=.Union?at:at+n*size,turn,{2*size,2*size,2*size}}
}

// Adds a brush placed in the world as the last child of the Solid target or,
// when target is NONE, makes a Solid at the point at with the brush as its
// first. One step; the brush entity, or NONE with the reason.
brush_place :: proc(s:^editor.Session,place:mm.Transform,at:[3]f32,kind:shapes.Brush_Kind,op:geom.Boolean_Op,material:base.Asset_Id,target:core.Entity) -> (brush:core.Entity,error:shapes.Shape_Error) {
    w:=editor.editing_world(s)
    _,shape_info:=core.world_table(w,shapes.Shape)
    _,brush_info:=core.world_table(w,shapes.Shape_Brush)
    if shape_info==nil || brush_info==nil || !(min(place.scale.x,place.scale.y,place.scale.z)>0) {return core.NONE,.Invalid}
    // Nothing to cut from or intersect with.
    if target==core.NONE && op!=.Union {return core.NONE,.Empty}
    solid_world:=mm.Transform{at,mm.QUAT_IDENTITY,{1,1,1}}
    if target!=core.NONE {
        shape,found:=editor.entity_get(w,target,shapes.Shape)
        if !found || shape.kind!=.Solid {return core.NONE,.Invalid}
        solid_world=editor.entity_world(w,target)
    }
    local,usable:=mm.transform_relative(place,solid_world)
    if !usable {return core.NONE,.Invalid}
    opened:=!s.edits.open
    if opened && !history.edits_begin(s.edits,s.selection,op==.Union?"Add brush":op==.Subtract?"Cut brush":"Intersect brush") {return core.NONE,.Invalid}
    solid:=target
    if solid==core.NONE {
        solid=editor.entity_create(s,{preset=.Empty,name="Solid",transform=core.from_math(solid_world)})
        if solid!=core.NONE {
            // A solid takes its form from its brushes: none of the polygon of the default.
            shape:shapes.Shape
            shape.kind,shape.uv_scale,shape.material=.Solid,1,material
            editor.component_add(s,solid,shape_info,&shape)
        }
    }
    if solid!=core.NONE {
        names:=BRUSH_NAMES
        brush=editor.entity_create(s,{preset=.Empty,name=names[op][kind],parent=solid,transform=core.from_math(local)})
        if brush!=core.NONE {
            value:=shapes.Shape_Brush{kind=kind,op=op}
            editor.component_add(s,brush,brush_info,&value)
        }
    }
    if opened {
        if brush!=core.NONE {history.edits_end(s.edits)} else {history.edits_cancel(s.edits,w)}
    }
    return brush,brush!=core.NONE?.None:.Invalid
}

// The Solid an entity belongs to: itself, or the parent of a brush.
solid_of :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    if e==core.NONE {return core.NONE}
    if shape,ok:=editor.entity_get(w,e,shapes.Shape);ok {return shape.kind==.Solid?e:core.NONE}
    if !editor.entity_has(w,e,shapes.Shape_Brush) {return core.NONE}
    parent:=editor.entity_parent(w,e)
    if shape,ok:=editor.entity_get(w,parent,shapes.Shape);ok && shape.kind==.Solid {return parent}
    return core.NONE
}

// The Solid selected last, or the one of the brush selected last.
selected_solid :: proc(s:^editor.Session,w:core.World_Ref) -> core.Entity {
    #reverse for selected in s.selection.entities {
        if solid:=solid_of(w,selected);solid!=core.NONE {return solid}
    }
    return core.NONE
}

// A brush entity placed in the world, through its solid.
brush_world :: proc(w:core.World_Ref,solid,brush:core.Entity) -> mm.Transform {
    return mm.transform_compose(editor.entity_world(w,solid),editor.entity_local(w,brush))
}

// The brush of a Solid whose surface a ray meets at distance along it: the
// one whose primitive the ray enters or leaves nearest there (a brush that
// cuts makes the surface where the ray leaves it).
brush_under :: proc(w:core.World_Ref,solid:core.Entity,ray:mm.Ray,distance:f32) -> (brush:core.Entity,kind:shapes.Brush_Kind,place:mm.Transform,found:bool) {
    best:=f32(math.INF_F32)
    for child in editor.entity_children(w,solid) {
        value:=editor.entity_get(w,child,shapes.Shape_Brush) or_continue
        t:=brush_world(w,solid,child)
        if !shapes.scale_usable(t.scale) {continue}
        origin:=mm.transform_inverse_point(t,ray.origin)
        direction:=mm.transform_inverse_vector(t,ray.direction)
        enter,leave:=unit_hit(value.kind,origin,direction) or_continue
        gap:=min(abs(enter-distance),abs(leave-distance))
        if gap<best {best,brush,kind,place,found=gap,child,value.kind,t,true}
    }
    return
}

// Where a ray enters and leaves a primitive of one meter centered at the
// origin, in units of its direction.
@(private)
unit_hit :: proc "contextless" (kind:shapes.Brush_Kind,origin,direction:[3]f32) -> (enter,leave:f32,hit:bool) {
    enter,leave=-math.INF_F32,math.INF_F32
    // The slabs of the box, or of the height of the cylinder along Y.
    for axis in 0..<3 {
        if kind==.Sphere || kind==.Cylinder && axis!=1 {continue}
        if abs(direction[axis])<1e-12 {
            if abs(origin[axis])>0.5 {return}
            continue
        }
        a,b:=(-0.5-origin[axis])/direction[axis],(0.5-origin[axis])/direction[axis]
        enter,leave=max(enter,min(a,b)),min(leave,max(a,b))
    }
    if kind!=.Box {
        // Round: the sphere in three axes, the cylinder across Y.
        o,d:=origin,direction
        if kind==.Cylinder {o.y,d.y=0,0}
        qa,qb,qc:=linalg.dot(d,d),2*linalg.dot(o,d),linalg.dot(o,o)-0.25
        if qa<1e-12 {
            if qc>0 {return}
        } else {
            disc:=qb*qb-4*qa*qc
            if disc<0 {return}
            root:=math.sqrt(disc)
            enter,leave=max(enter,(-qb-root)/(2*qa)),min(leave,(-qb+root)/(2*qa))
        }
    }
    return enter,leave,enter<=leave && leave>=0
}
