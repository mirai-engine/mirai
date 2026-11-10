package foliage

import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"

// A type armed from a prefab draws each Mesh_Renderer of the prefab where
// its instances are: a batch per cell, type and part, with the transform of
// the part from the root of the prefab composed with each instance's.

// A Mesh_Renderer of a prefab and where it is from the root.
Prefab_Part :: struct {
    renderer:render.Mesh_Renderer,
    placement:mm.Mat4,
}

// The parts of an open prefab, appended to out: its entities with a
// Mesh_Renderer that is on and not hidden, under its root. False when it is
// not a prefab this reads (no single root, a parent that is not there).
prefab_parts :: proc(file:^asset.Asset,types:^asset.Types,out:^[dynamic]Prefab_Part) -> bool {
    view,error:=asset.scene_view(file,types)
    if error!=.None {return false}
    count:=len(view.ids)
    if view.roots!=1 {return false}
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
        }
    }
    mesh_hash:=base.name_hash("Mesh_Renderer")
    for renderer,k in renderers[:min(len(renderers),len(renderer_rows))] {
        row:=int(renderer_rows[k])
        if row>=count || renderer.mesh=={} && renderer.shape==.None {continue}
        off:=false
        for record in view.off {if record.entity==view.ids[row] && record.component==mesh_hash {off=true}}
        // Up to the root, whose own placement is the instance's.
        placement:=mm.Mat4(1)
        at:=row
        for steps:=0;at!=root;steps+=1 {
            if at<0 || steps>count {return false}
            off||=hidden[at]
            placement=locals[at]*placement
            at=row_of(view,view.parents[at])
        }
        off||=hidden[root]
        if !off {append(out,Prefab_Part{renderer=renderer,placement=placement})}
    }
    return true
}

// An instance as a batch draws it, for a part placed by `part` under the
// instance, carried by the matrix of its entity. What Batch_Instance does
// not hold (a scale along x unlike along z, a shear) is approximated:
// error is how much of the transform is left out, as a part of it.
part_instance :: proc "contextless" (p:Placed,owner:mm.Mat4,part:mm.Mat4) -> (instance:render.Batch_Instance,error:f32) {
    placed:=mm.transform_matrix({position=p.position,rotation=p.rotation,scale={p.scale[0],p.scale[1],p.scale[0]}})
    m:=owner*placed*part
    c:=[3][3]f32{m[0].xyz,m[1].xyz,m[2].xyz}
    sx,sy,sz:=linalg.length(c[0]),linalg.length(c[1]),linalg.length(c[2])
    if !(sx>1e-12) || !(sy>1e-12) || !(sz>1e-12) {return render.batch_instance(m[3].xyz,1,1e-6,1e-6),1}
    y:=c[1]/sy
    x:=c[0]-y*linalg.dot(c[0],y)
    if linalg.length(x)<1e-9 {x=linalg.cross(y,c[2])}
    x=linalg.normalize(x)
    z:=linalg.cross(x,y)
    across,along:=(sx+sz)*0.5,sy
    // What is left: the columns against those of the rotation scaled.
    left:=linalg.length(c[0]-x*across)+linalg.length(c[1]-y*along)+linalg.length(c[2]-z*across)
    error=left/(sx+sy+sz)
    rotation:=linalg.normalize(mm.quat_from_mat3(mm.Mat3{x.x,y.x,z.x,x.y,y.y,z.y,x.z,y.z,z.z}))
    return render.batch_instance(m[3].xyz,rotation,across,along),error
}
