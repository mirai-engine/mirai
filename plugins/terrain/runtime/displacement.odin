package terrain

import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import render "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import "base:runtime"

// Heightfield chunks at level 0 near the view raise the heights of the
// textures of their layers, as Terrain3D displaces its mesh near the camera.
// Such a chunk is built again with each cell split in 2^detail per side
// (chunk_detail_build) and drawn through a deformable copy of that mesh,
// whose vertices a Geometry pass (terrain_displace.comp) moves along their
// normals once, when it is built or what it reads changes. Only what is drawn
// moves: the collider, the picking and the brushes keep the surface of the
// samples.
//
// Two displaced chunks build the side they share at the steps of their
// cells; a side shared with a chunk that is not displaced keeps the samples,
// and the displacement fades out within a cell of it. A displaced chunk shows
// only while each of its sides agrees with the chunk beside it, so no crack
// opens while a neighbor is built again.

DISPLACEMENT_MAX :: f32(4) // metres a layer raises its highest texel over its lowest, at most
DISPLACED_CAPACITY :: 64   // chunks displaced at once: the nearest
DISPLACED_BUILDS :: 2      // displaced chunks built in a frame

@(private)
Displaced :: struct {
    owner:core.Entity,
    coord:[3]i32,
    entity:core.Entity, // the chunk
    source:base.Asset_Id,
    change:u32,         // of the chunk in its source when it was built
    detail:u8,
    fine:[4]bool,       // the sides built at the steps of its cells
    want:[4]bool,       // those that join another displaced chunk now
    mesh:base.Asset_Id, // the generated mesh it was built into
    rest:render.Mesh_Handle,
    copy:render.Mesh_Handle,
    rest_min,rest_max:[3]f32,
    params:Gpu_Displace, // what its vertices were last written with
    made:u64,            // of the vertex buffer they were written in
    settle:bool,         // written in the frame before: once more, so its motion stops
    distance:f32,
    shown:bool,
    seen:u64,
}

// terrain_displace.comp.slang
@(private)
Gpu_Displace_Layer :: struct {color:u32,tiling,blend,displacement:f32}
@(private)
Gpu_Displace :: struct {
    written,rest,count,mesh:u32,
    rows:[3][4]f32,
    origin:[4]i32,
    size:[2]f32,
    fade:f32,
    pinned:u32,
    spacing:f32,
    layer_count:u32,
    pad:[2]u32,
    layers:[LAYERS_MAX]Gpu_Displace_Layer,
}
#assert(size_of(Gpu_Displace)==176)

@(storage,host,free="terrain_displacement_free")
Terrain_Displacement :: struct {
    displaced:[DISPLACED_CAPACITY]Displaced,
    world:[DISPLACED_CAPACITY]matrix[4,4]f32, // of each chunk written this frame
    jobs:[DISPLACED_CAPACITY]Gpu_Displace,     // of this frame; rest holds the row of displaced until the pass is recorded
    job_count:int,
    frame:u64,
    pipeline:render.Pipeline,
    building:Chunk_Mesh,
    ready:bool,
    assets:^host.Assets,
}

// The copies go with the renderer.
terrain_displacement_free :: proc(d:^Terrain_Displacement) {
    for &entry in d.displaced {if d.assets!=nil && entry.mesh!={} {host.assets_mesh_release(d.assets,entry.mesh)}}
    if d.ready {chunk_mesh_destroy(&d.building)}
    d^={}
}

// Its entity draws its own mesh again, and its meshes go.
@(private)
displaced_release :: proc(assets:^host.Assets,renderer:^render.Renderer,poses:^render.Posed_Meshes,entry:^Displaced) {
    render.posed_drop(poses,entry.entity)
    if entry.copy!=0 {render.mesh_remove(renderer,entry.copy)}
    if entry.mesh!={} {host.assets_mesh_release(assets,entry.mesh)}
    entry^={}
}

// The most a layer of a source raises or lowers a vertex.
@(private)
source_displacement :: proc "contextless" (s:^Source) -> (reach:f32) {
    if s.kind!=.Heightfield {return 0}
    for layer in s.layers[:min(s.layer_count,LAYERS_MAX)] {reach=max(reach,layer.displacement*0.5)}
    return
}

@(step="render",loops="game editor",before="render_sync")
terrain_displace :: proc(
    d:^Terrain_Displacement,data:core.Ref(Terrain_Data),settings:Terrain_Settings,terrains:^core.Table(Terrain,.Read),chunks:^core.Table(Terrain_Chunk,.Read),
    meshes:^core.Table(render.Mesh_Renderer,.Read),worlds:^core.Table(core.World_Transform,.Read),parents:^core.Table(core.Parent,.Read),hidden:^core.Table(render.Hidden,.Read),
    offsets:^core.Table(render.Draw_Offset,.Read),assets:^host.Assets,renderer:^render.Renderer,allocator:runtime.Allocator,frame:core.Frame_Time,view:core.View,poses:^render.Posed_Meshes,
) {
    if renderer==nil || assets==nil {return}
    d.assets=assets
    d.frame+=1
    d.job_count=0
    if !d.ready {chunk_mesh_init(&d.building,allocator);d.ready=true}
    distance:=settings.displacement_distance
    d.pipeline=distance>0?render.stage_pipeline(renderer,{stage=.Geometry,shader="terrain_displace",name="terrain displace"}):0
    // The chunks within the distance, nearest first.
    if d.pipeline!=0 {
        for row in 0..<core.count(chunks) {
            chunk:=core.at(chunks,row)
            if chunk.depth!=0 || chunk.lod.level!=0 || chunk.joined {continue}
            e:=core.entity_at(chunks,row)
            marker,found:=core.get(terrains,chunk.owner)
            if !found {continue}
            entry:=data_find(data.ptr,marker.source)
            if entry==nil || source_displacement(&entry.source)<=0 {continue}
            world,placed:=core.get(worlds,e)
            if !placed {continue}
            near:=chunk_view_distance(&entry.source,chunk.coord,mm.transform_matrix(world.transform),view.position)
            if near>distance {continue}
            at:=-1
            for &item,i in d.displaced {
                if item.entity==e && item.coord==chunk.coord && item.owner==chunk.owner {at=i;break}
                if at<0 && item.entity==core.NONE {at=i}
            }
            if at<0 {
                // Full: it takes the place of the farthest when nearer.
                far:=0
                for item,i in d.displaced {if item.distance>d.displaced[far].distance {far=i}}
                if d.displaced[far].distance<=near {continue}
                displaced_release(assets,renderer,poses,&d.displaced[far])
                at=far
            }
            item:=&d.displaced[at]
            if item.entity!=e {displaced_release(assets,renderer,poses,item);item.entity,item.owner,item.coord=e,chunk.owner,chunk.coord}
            item.source,item.distance,item.seen=marker.source,near,d.frame
        }
    }
    for &item in d.displaced {if item.entity!=core.NONE && item.seen!=d.frame {displaced_release(assets,renderer,poses,&item)}}
    // Each side joins another displaced chunk of its terrain, or keeps the samples.
    for &item in d.displaced {
        if item.entity==core.NONE {continue}
        item.want=displaced_neighbors(d,item.owner,item.coord)
    }
    builds:=0
    detail:=u8(clamp(settings.displacement_detail,1,4))
    for &item in d.displaced {
        if item.entity==core.NONE {continue}
        entry:=data_find(data.ptr,item.source)
        if entry==nil {continue}
        index:=chunk_index(&entry.source,item.coord)
        if index<0 || index>=len(entry.versions) {continue}
        if item.mesh!={} && item.change==entry.versions[index] && item.detail==detail && item.fine==item.want {continue}
        if builds>=DISPLACED_BUILDS {continue}
        builds+=1
        if item.copy!=0 {render.mesh_remove(renderer,item.copy)}
        if item.mesh!={} {host.assets_mesh_release(assets,item.mesh)}
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        item.params={}
        item.mesh,item.rest,item.copy,item.made,item.settle={},0,0,0,false
        if !chunk_detail_build(&entry.source,item.coord,{},detail,item.want,&d.building) || !chunk_render_prepare(.Heightfield,&d.building,host.assets_limits(assets)) {continue}
        mesh,ok:=chunk_publish(assets,.Heightfield,&d.building,false)
        if !ok {continue}
        item.mesh,item.change,item.detail,item.fine=mesh,entry.versions[index],detail,item.want
    }
    for &item in d.displaced {item.shown=item.entity!=core.NONE && item.mesh!={} && item.fine==item.want}
    // A chunk whose side was built for a neighbor that does not show displaced waits.
    for changed:=true;changed; {
        changed=false
        for &item in d.displaced {
            if !item.shown {continue}
            for side in 0..<4 {
                if !item.fine[side] {continue}
                neighbor:=displaced_find(d,item.owner,item.coord+SIDE_STEPS[side])
                if neighbor==nil || !neighbor.shown || !neighbor.fine[side~1] {item.shown,changed=false,true;break}
            }
        }
    }
    made:=render.vertices_made(renderer)
    for &item,at in d.displaced {
        if item.entity==core.NONE {continue}
        e:=item.entity
        world,placed:=core.get(worlds,e)
        entry:=data_find(data.ptr,item.source)
        rest:=host.assets_mesh(assets,item.mesh)
        // One not shown draws the mesh of its entity.
        if !item.shown || !core.has(meshes,e) || !placed || entry==nil || rest==nil || rest.handle==host.ASSETS_MESH_NONE || render.is_hidden(hidden,parents,e) {
            render.posed_drop(poses,e)
            continue
        }
        if item.copy==0 || item.rest!=rest.handle {
            if item.copy!=0 {
                render.posed_drop(poses,e)
                render.mesh_remove(renderer,item.copy)
                item.copy=0
            }
            low,high,known:=render.mesh_bounds(renderer,rest.handle)
            if !known {continue}
            copy,created:=render.deformable_create(renderer,rest.handle)
            if !created {continue}
            // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
            item.params={}
            item.rest,item.copy,item.rest_min,item.rest_max,item.made=rest.handle,copy,low,high,0
        }
        params:=displace_params(assets,&entry.source,&item)
        if params!=item.params || made!=item.made || item.settle {
            reach:=source_displacement(&entry.source)/max(abs(world.scale.y),1e-6)
            if render.deformable_update(renderer,item.copy,item.rest_min-reach,item.rest_max+reach) {
                item.settle=params!=item.params || made!=item.made
                // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
                item.params=params
                item.made=made
                params.rest=u32(at)
                d.jobs[d.job_count]=params
                d.world[d.job_count]=render.instance_matrix(world,frame,offsets,parents,worlds,e)
                d.job_count+=1
            }
        }
        if !render.posed_set(poses,e,{mesh=item.copy}) {render.posed_drop(poses,e)}
    }
    if d.job_count>0 {render.frame_pass(renderer,.Geometry,terrain_displace_record,d)}
}

// -X, +X, -Z, +Z: side ~ 1 is the one across.
@(private,rodata)
SIDE_STEPS:=[4][3]i32{{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}}

@(private)
displaced_find :: proc(d:^Terrain_Displacement,owner:core.Entity,coord:[3]i32) -> ^Displaced {
    for &item in d.displaced {if item.entity!=core.NONE && item.owner==owner && item.coord==coord {return &item}}
    return nil
}

@(private)
displaced_neighbors :: proc(d:^Terrain_Displacement,owner:core.Entity,coord:[3]i32) -> (fine:[4]bool) {
    for side in 0..<4 {fine[side]=displaced_find(d,owner,coord+SIDE_STEPS[side])!=nil}
    return
}

// How far the view is from the box of a chunk, in metres of the world.
@(private)
chunk_view_distance :: proc "contextless" (s:^Source,coord:[3]i32,world:matrix[4,4]f32,eye:[3]f32) -> f32 {
    inverse:=linalg.inverse(world)
    local:=(inverse*[4]f32{eye.x,eye.y,eye.z,1}).xyz
    size:=f32(s.chunk_cells)*s.cell
    low,high,_:=chunk_region(s,coord)
    bottom,top:=source_point(s,low).y,source_point(s,low).y
    for z in low.z..=high.z {for x in low.x..=high.x {h:=grid_get(&s.field,x,z);bottom,top=min(bottom,h),max(top,h)}}
    lift:=source_displacement(s)
    nearest:=[3]f32{clamp(local.x,0,size),clamp(local.y,bottom-lift,top+lift),clamp(local.z,0,size)}
    return linalg.length((world*[4]f32{nearest.x,nearest.y,nearest.z,1}).xyz-eye)
}

// What the vertices of a displaced chunk are written with, but where they
// are in the pool and in the world, which the pass gives.
@(private)
displace_params :: proc(a:^host.Assets,s:^Source,item:^Displaced) -> (p:Gpu_Displace) {
    size:=f32(s.chunk_cells)*s.cell
    p.size,p.fade=size,s.cell
    p.spacing=s.cell/f32(int(1)<<item.detail)
    for side in 0..<4 {if !item.fine[side] {p.pinned|=1<<uint(side)}}
    p.layer_count=min(s.layer_count,LAYERS_MAX)
    for i in 0..<int(p.layer_count) {
        layer:=s.layers[i]
        color:=max(u32)
        if material:=host.assets_material(a,layer.material);material!=nil && !material.failed {
            maps:=asset.material_maps(&material.info.maps)
            if texture:=host.assets_texture(a,maps[.Base_Color].texture);texture!=nil && !texture.failed && texture.handle!=0 {color=render.texture_index(texture.handle)}
        }
        p.layers[i]={color,layer.tiling,layer.height_blend,layer.displacement}
    }
    return
}

@(private)
terrain_displace_record :: proc(pass:^render.Pass,user:rawptr) {
    d:=cast(^Terrain_Displacement)user
    if !render.pass_vertices_begin(pass,"terrain displace") {return}
    bound:=false
    for &job,i in d.jobs[:d.job_count] {
        item:=&d.displaced[job.rest]
        written,rest,count,mesh,known:=render.pass_deformable(pass,item.copy)
        if !known {continue}
        if !bound {render.pass_pipeline(pass,d.pipeline);bound=true}
        world:=render.origin_matrix(d.world[i],pass.origin)
        for row in 0..<3 {job.rows[row]={world[row,0],world[row,1],world[row,2],world[row,3]}}
        steps:=pass.origin/render.ORIGIN_STEP
        job.origin={i32(steps.x),i32(steps.y),i32(steps.z),0}
        job.written,job.rest,job.count,job.mesh=written,rest,count,mesh
        if render.pass_params(pass,&job,size_of(Gpu_Displace)) {render.pass_dispatch(pass,(count+63)/64)}
    }
}
