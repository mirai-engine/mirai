package importer

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:std/geom"

// Level 0 of a mesh of the demo, in the space and with the submeshes of
// its asset; ok is false, with a warning, when MIRAI_ROOT is not set.
@(private="file")
demo_level0 :: proc(t:^testing.T,relative:string,file:^asset.Asset,types:^asset.Types) -> (vertices:[]asset.Vertex,indices:[]u32,submeshes:[]Submesh,ok:bool) {
    root,has_root:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !has_root {
        fmt.eprintln("MIRAI_ROOT is not set: the meshes of the demo were not read. Use `mirai test cook/import`.")
        return
    }
    path,_:=filepath.join({root,relative},context.temp_allocator)
    if !testing.expect_value(t,asset.asset_load(file,path),asset.Error.None) {return}
    view,error:=asset.mesh_view(file,types)
    if !testing.expect_value(t,error,asset.Error.None) {return}
    decoded:=make([dynamic]asset.Vertex,context.temp_allocator)
    decoded_indices:=make([dynamic]u32,context.temp_allocator)
    if !testing.expect(t,asset.mesh_level_decode(view.geometry,0,&decoded,&decoded_indices)) {return}
    // The clusters of a slot follow one another: a run of its triangles.
    ranges:=make([dynamic]Submesh,context.temp_allocator)
    for at:=0;at<len(decoded_indices);at+=3 {
        slot:=decoded[decoded_indices[at]].material
        if len(ranges)==0 || ranges[len(ranges)-1].slot!=slot {append(&ranges,Submesh{first_index=u32(at),slot=slot})}
        ranges[len(ranges)-1].index_count+=3
    }
    return decoded[:],decoded_indices[:],ranges[:],true
}

@(test)
the_cluster_dag_of_demo_meshes_cuts_without_cracks_with_errors_that_grow :: proc(t:^testing.T) {
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    for relative in ([]string{"demo/assets/gallery/vase.obj/Vase.mesh","demo/assets/gallery/plant.gltf/Plant.mesh","demo/assets/characters/mirai/output_unwrapped.mesh"}) {
        file:asset.Asset
        vertices,indices,submeshes,ok:=demo_level0(t,relative,&file,&types)
        if !ok {return}
        defer asset.asset_close(&file)
        positions,attributes,protect:=asset.mesh_simplify_inputs(vertices,context.temp_allocator)
        weights:=asset.MESH_SIMPLIFY_WEIGHTS
        ranges:=make([]geom.Cluster_Range,len(submeshes),context.temp_allocator)
        for s,i in submeshes {ranges[i]={s.first_index,s.index_count,s.slot}}
        source:=geom.Cluster_Source{positions=positions,indices=indices,ranges=ranges,attributes=attributes,attribute_weights=weights[:],vertex_lock=protect}
        dag,again:geom.Cluster_Dag
        defer {geom.cluster_dag_destroy(&dag);geom.cluster_dag_destroy(&again)}
        start:=time.tick_now()
        if !testing.expect_value(t,geom.cluster_dag_build(&dag,source),geom.Cluster_Error.None) {continue}
        ms:=time.duration_milliseconds(time.tick_since(start))
        geom.cluster_dag_build(&again,source)
        testing.expect(t,len(again.clusters)==len(dag.clusters) && string(([^]u8)(raw_data(again.clusters))[:len(again.clusters)*size_of(geom.Cluster)])==string(([^]u8)(raw_data(dag.clusters))[:len(dag.clusters)*size_of(geom.Cluster)]),"the DAG is deterministic")
        slot_of:=make(map[u32]u32,context.temp_allocator)
        for s in submeshes {for index in indices[s.first_index:][:s.index_count] {slot_of[index]=s.slot}}
        level0,roots,root_triangles:=0,0,0
        for c in dag.clusters {
            for v in dag.vertices[c.first_vertex:][:c.vertex_count] {
                if slot_of[v]!=c.submesh {testing.expectf(t,false,"%s: a cluster crosses submeshes",relative);return}
            }
            d:=c.parent.center-c.own.center
            if !(c.own.error<=c.parent.error) || math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z)+c.own.radius>c.parent.radius*1.0001+1e-6 {testing.expectf(t,false,"%s: an error or sphere shrinks towards the roots",relative);return}
            if c.level==0 {level0+=int(c.triangle_count)}
            if c.parent.error==max(f32) {roots+=1;root_triangles+=int(c.triangle_count)}
        }
        testing.expect_value(t,level0,len(indices)/3)
        // Every open edge of a cut joins places on the border of level 0: no crack opens between clusters.
        weld:=make([]u32,len(positions),context.temp_allocator)
        geom.positions_weld(positions,0,weld)
        border:=make(map[u32]bool,context.temp_allocator)
        for edge in open_edges_of(weld,indices) {border[edge[0]]=true;border[edge[1]]=true}
        lo,hi:=geom.mesh_bounds(positions)
        size:=linalg_length(hi-lo)
        for camera_at in 0..<16 {
            turn:=f32(camera_at)/16
            camera:=(lo+hi)/2+geom.Vec3{math.cos(turn*math.TAU),0.3,math.sin(turn*math.TAU)}*size*f32(1+camera_at*3)
            threshold:=f32(camera_at%4)*0.005
            drawn:=make([dynamic]u32,context.temp_allocator)
            for c in dag.clusters {
                if lod_projected(c.own,camera)<=threshold && lod_projected(c.parent,camera)>threshold {
                    for k in 0..<c.triangle_count*3 {append(&drawn,dag.vertices[c.first_vertex+u32(dag.triangles[c.first_triangle*3+k])])}
                }
            }
            for edge in open_edges_of(weld,drawn[:]) {
                if !border[edge[0]] || !border[edge[1]] {testing.expectf(t,false,"%s: a cut from %v at %f opens an edge inside the surface",relative,camera,threshold);return}
            }
        }
        fmt.printfln("%s: %d triangles, %d levels, %d groups, %d clusters (%.1f triangles each), roots %d of %d triangles, %.1f ms",filepath.base(relative),len(indices)/3,dag.levels,dag.groups,len(dag.clusters),f32(len(dag.triangles)/3)/f32(len(dag.clusters)),roots,root_triangles,ms)
    }
}

@(private="file")
linalg_length :: proc(v:geom.Vec3) -> f32 {return math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)}

@(private="file")
lod_projected :: proc(lod:geom.Cluster_Lod,camera:geom.Vec3) -> f32 {
    return lod.error/max(linalg_length(lod.center-camera)-lod.radius,0.01)
}

// The edges by place with one triangle.
@(private="file")
open_edges_of :: proc(weld,indices:[]u32) -> [dynamic][2]u32 {
    uses:=make(map[[2]u32]int,context.temp_allocator)
    for t:=0;t<len(indices);t+=3 {
        for k in 0..<3 {
            a,b:=weld[indices[t+k]],weld[indices[t+(k+1)%3]]
            if a!=b {uses[{min(a,b),max(a,b)}]+=1}
        }
    }
    open:=make([dynamic][2]u32,context.temp_allocator)
    for edge,n in uses {if n%2!=0 {append(&open,edge)}}
    return open
}
