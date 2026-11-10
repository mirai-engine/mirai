package portals

import "core:math/linalg"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import mm "mirai:std/math"

// A traveler halfway through a portal is seen on both of its sides: while a
// mesh of it reaches across the plane of an opening, it is drawn again where
// the portal carries it, so the part that went in comes out of the exit. The
// part of each copy behind its plane is inside the wall the portal is on.

@(step="render",loops="game editor",before="render_sync")
portals_doubles :: proc(
    portals:core.Read(Portal),travelers:core.Read(Traveler),worlds:core.Read(core.World_Transform),
    meshes:core.Read(erender.Mesh_Renderer),tints:core.Read(erender.Tint),hidden:core.Read(erender.Hidden),
    parents:core.Read(core.Parent),hierarchy:core.Ref(core.Hierarchy),assets:^host.Assets,extras:^host.Frame_Extras,frame:core.Frame_Time,
) {
    if assets==nil || core.count(portals)==0 || core.count(travelers)==0 {return}
    for row in 0..<core.count(portals) {
        e:=core.entity_at(portals,row)
        portal:=core.at(portals,row)
        world,placed:=core.get(worlds,e)
        exit_world,has_exit:=core.get(worlds,portal.exit)
        if !placed || !has_exit || erender.is_hidden(hidden,parents,e) {continue}
        entrance:=erender.drawn_transform(world,frame)
        through:=mm.transform_matrix(through_of(entrance,erender.drawn_transform(exit_world,frame)))
        for t in 0..<core.count(travelers) {
            traveler:=core.entity_at(travelers,t)
            double_draw(meshes,tints,hidden,parents,worlds,assets,extras,frame,traveler,e,entrance,through)
            for child:=core.first_child(hierarchy,traveler);child!=core.NONE;child=core.next_sibling(hierarchy,child) {
                double_draw(meshes,tints,hidden,parents,worlds,assets,extras,frame,child,e,entrance,through)
            }
        }
    }
}

// The copy of the mesh of an entity behind the exit of a portal, when the mesh reaches across its opening.
@(private)
double_draw :: proc(
    meshes:core.Read(erender.Mesh_Renderer),tints:core.Read(erender.Tint),hidden:core.Read(erender.Hidden),
    parents:core.Read(core.Parent),worlds:core.Read(core.World_Transform),assets:^host.Assets,extras:^host.Frame_Extras,frame:core.Frame_Time,
    e,portal:core.Entity,entrance:mm.Transform,through:mm.Mat4,
) {
    shown,has_mesh:=core.get(meshes,e)
    world,placed:=core.get(worlds,e)
    if !has_mesh || !placed || erender.is_hidden(hidden,parents,e) {return}
    mesh:=shown.mesh!={}?host.assets_mesh(assets,shown.mesh):host.assets_shape(assets,shown.shape)
    if mesh==nil {return}
    drawn:=erender.drawn_transform(world,frame)
    size:=[2]f32{abs(entrance.scale.x),abs(entrance.scale.y)}
    if size.x<1e-5 || size.y<1e-5 {return}
    inverse:=conj(entrance.rotation)
    low:=[3]f32{max(f32),max(f32),max(f32)}
    high:=-low
    for i in 0..<8 {
        corner:=[3]f32{i&1!=0?mesh.bounds_max.x:mesh.bounds_min.x,i&2!=0?mesh.bounds_max.y:mesh.bounds_min.y,i&4!=0?mesh.bounds_max.z:mesh.bounds_min.z}
        local:=mm.quat_rotate(inverse,mm.transform_point(drawn,corner)-entrance.position)
        low,high=linalg.min(low,local),linalg.max(high,local)
    }
    if !(low.z<0 && high.z>0) || high.x< -0.5*size.x || low.x>0.5*size.x || high.y< -0.5*size.y || low.y>0.5*size.y {return}
    tint:=erender.TINT_DEFAULT
    if value,tinted:=core.get(tints,e);tinted {tint=value}
    instance,ok:=erender.mesh_instance(assets,shown,through*mm.transform_matrix(drawn),tint)
    if !ok {return}
    instance.object_id,instance.copy_owner,instance.copy_variant=u64(e),u64(portal),1
    host.extras_instance_add(extras,instance)
}
