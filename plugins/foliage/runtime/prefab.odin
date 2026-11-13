package foliage

import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import physics "plugins:physics/runtime"

// A type armed from a prefab draws each Mesh_Renderer of the prefab where
// its instances are: a batch per cell, type and part, with the transform of
// the part from the root of the prefab composed with each instance's.

// A Mesh_Renderer of a prefab and where it is from the root.
Prefab_Part :: struct {
    renderer:render.Mesh_Renderer,
    placement:mm.Mat4,
}

// A Collider of a prefab, as a type of Prefab collision collides, and where
// it is from the root; for a Hull, what its entity shows.
Prefab_Collider :: struct {
    collider:physics.Collider,
    placement:mm.Mat4,
    renderer:render.Mesh_Renderer,
}

// The parts of an open prefab, appended to out: its entities with a
// Mesh_Renderer that is on and not hidden, under its root; and with
// colliders, its Colliders that are on, block and are of a kind an instance
// has (Box, Sphere, Capsule, Cylinder, or Hull or Auto of an entity that shows
// a mesh, which collide as its hulls), appended there: left_out counts the others. False when it is not a
// prefab this reads (no single root, a parent that is not there).
prefab_parts :: proc(file:^asset.Asset,types:^asset.Types,out:^[dynamic]Prefab_Part,colliders:^[dynamic]Prefab_Collider=nil) -> (ok:bool,left_out:int) {
    view,error:=asset.scene_view(file,types)
    if error!=.None {return}
    count:=len(view.ids)
    if !asset.asset_prefab(file) {return}
    root:=-1
    for parent,row in view.parents {
        if parent==0 {root=row}
    }
    row_of :: proc(view:asset.Scene_View,id:base.Entity_Id) -> int {
        for held,row in view.ids {if held==id {return row}}
        return -1
    }
    locals:=make([]mm.Mat4,count,context.temp_allocator)
    for &m in locals {m=1}
    hidden:=make([]bool,count,context.temp_allocator)
    renderers:[]render.Mesh_Renderer
    renderer_rows:[]u32
    shapes:[]physics.Collider
    shape_rows:[]u32
    for &component in view.components {
        switch component.name {
        case "Transform":
            rows:=asset.asset_rows(file,types,component.name,asset.COLUMN_ENTITY,u32) or_else nil
            values:=asset.asset_rows(file,types,component.name,asset.COLUMN_VALUE,core.Transform) or_else nil
            for value,k in values[:min(len(values),len(rows))] {
                if int(rows[k])<count {locals[rows[k]]=mm.transform_matrix({position=value.position,rotation=value.rotation,scale=value.scale})}
            }
        case "Hidden":
            for row in component.entities {if int(row)<count {hidden[row]=true}}
        case "Mesh_Renderer":
            renderer_rows=component.entities
            renderers=asset.asset_rows(file,types,component.name,asset.COLUMN_VALUE,render.Mesh_Renderer) or_else nil
        case "Collider":
            if colliders==nil {continue}
            shape_rows=component.entities
            shapes=asset.asset_rows(file,types,component.name,asset.COLUMN_VALUE,physics.Collider) or_else nil
        }
    }
    // Up to the root, whose own placement is the instance's; and whether one on the way is hidden.
    placed :: proc(view:asset.Scene_View,locals:[]mm.Mat4,hidden:[]bool,root,row:int) -> (placement:mm.Mat4,off,ok:bool) {
        placement=1
        at:=row
        for steps:=0;at!=root;steps+=1 {
            if at<0 || steps>len(locals) {return}
            off||=hidden[at]
            placement=locals[at]*placement
            at=row_of(view,view.parents[at])
        }
        return placement,off||hidden[root],true
    }
    is_off :: proc(view:asset.Scene_View,row:int,name:string) -> bool {
        hash:=base.name_hash(name)
        for record in view.off {if record.entity==view.ids[row] && record.component==hash {return true}}
        return false
    }
    for renderer,k in renderers[:min(len(renderers),len(renderer_rows))] {
        row:=int(renderer_rows[k])
        if row>=count || renderer.mesh=={} && renderer.shape==.None {continue}
        placement,off,walked:=placed(view,locals,hidden,root,row)
        if !walked {return}
        if !off && !is_off(view,row,"Mesh_Renderer") {append(out,Prefab_Part{renderer=renderer,placement=placement})}
    }
    for shape,k in shapes[:min(len(shapes),len(shape_rows))] {
        row:=int(shape_rows[k])
        if row>=count || is_off(view,row,"Collider") {continue}
        placement,_,walked:=placed(view,locals,hidden,root,row)
        if !walked {return}
        shown:render.Mesh_Renderer
        for renderer,j in renderers[:min(len(renderers),len(renderer_rows))] {if int(renderer_rows[j])==row {shown=renderer}}
        #partial switch shape.kind {
        case .Box,.Sphere,.Capsule,.Cylinder: if !shape.sensor {append(colliders,Prefab_Collider{shape,placement,{}});continue}
        case .Hull,.Auto:
            // An Auto one collides as the hulls of its mesh, as a type of Hull collision does.
            hull:=shape
            hull.kind=.Hull
            if !shape.sensor && (shown.mesh!={} || shown.shape!=.None) {append(colliders,Prefab_Collider{hull,placement,shown});continue}
        }
        left_out+=1
    }
    return true,left_out
}

// An instance as a batch draws it, for a part placed by `part` under the
// instance, carried by the matrix of its entity. What Batch_Instance does
// not hold (a shear, a mirror) is approximated: error is how much of the
// transform is left out, as a part of it.
part_instance :: proc "contextless" (p:Placed,owner:mm.Mat4,part:mm.Mat4) -> (instance:render.Batch_Instance,error:f32) {
    placed:=mm.transform_matrix({position=p.position,rotation=p.rotation,scale={p.scale[0],p.scale[1],p.scale[0]}})
    position,rotation,scale,left:=matrix_pose(owner*placed*part)
    return render.batch_instance(position,rotation,scale),left
}

// A matrix as a place, a rotation and a scale along each axis of it: y keeps
// its direction, x is made square to it and z to both. left: how much of the
// matrix that leaves out (a shear, a mirror), as a part of it; 1 for one
// without size along an axis, given the least scale.
matrix_pose :: proc "contextless" (m:mm.Mat4) -> (position:[3]f32,rotation:mm.Quat,scale:[3]f32,left:f32) {
    c:=[3][3]f32{m[0].xyz,m[1].xyz,m[2].xyz}
    position,rotation=m[3].xyz,1
    scale={linalg.length(c[0]),linalg.length(c[1]),linalg.length(c[2])}
    if !(scale.x>1e-12) || !(scale.y>1e-12) || !(scale.z>1e-12) {return position,1,1e-6,1}
    y:=c[1]/scale.y
    x:=c[0]-y*linalg.dot(c[0],y)
    if linalg.length(x)<1e-9 {x=linalg.cross(y,c[2])}
    x=linalg.normalize(x)
    z:=linalg.cross(x,y)
    left=(linalg.length(c[0]-x*scale.x)+linalg.length(c[1]-y*scale.y)+linalg.length(c[2]-z*scale.z))/(scale.x+scale.y+scale.z)
    rotation=linalg.normalize(mm.quat_from_mat3(mm.Mat3{x.x,y.x,z.x,x.y,y.y,z.y,x.z,y.z,z.z}))
    return
}
