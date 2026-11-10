package destruct

import "mirai:asset"
import render "mirai:engine/render"
import "mirai:host"
import sim "plugins:physics/runtime/sim"
import fr "plugins:destruct/runtime/fracture"
import "mirai:std/geom"

@(private)
prepare_authored :: proc(assets:^host.Assets,p:^Prepared,d:Destructible,static:render.Mesh_Renderer,scale:[3]f32,interior:u32) -> bool {
    file:asset.Asset
    if host.assets_file(assets,d.fracture,FRACTURE_KIND,&file)!=.None {return false}
    defer asset.asset_close(&file)
    view,error:=fracture_view(&file,&assets.types)
    if error!=.None {return false}
    if view.info.source_mesh!={} && view.info.source_mesh!=static.mesh {return false}
    f:=&p.fracture
    if fracture_geometry(view,f,scale)!=.None {return false}
    for piece in view.pieces {
        append(&p.anchors,piece.anchor)
        append(&p.piece_clusters,piece.cluster)
    }
    for connection in view.connections {
        append(&p.connection_strength,connection.strength)
    }
    for cluster,at in view.clusters {
        hull:=view.cluster_hulls[at]
        append(&p.clusters,fr.Cluster_Desc{parent=cluster.parent,strength=cluster.strength,first_point=u32(len(p.cluster_points)),point_count=hull.point_count})
        for point in view.cluster_points[hull.first_point:][:hull.point_count] {append(&p.cluster_points,point*scale)}
    }
    p.desc.lo,p.desc.hi=geom.mesh_bounds(f.mesh.positions[:])
    p.interior=interior
    p.key={pieces=d.pieces,seed=d.seed,pattern=d.pattern,mesh=static.mesh,fracture=d.fracture,shape=static.shape,scale=scale,interior=interior}
    return true
}
