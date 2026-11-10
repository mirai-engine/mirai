package previews_editor

import "base:runtime"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:host"
import erender "mirai:engine/render"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import eanim "plugins:animation/runtime"

// Level 0 of a skinned mesh, its own copy, and where the last sample posed
// each of its vertices.
Skin_Geometry :: struct {
    clusters:[]asset.Cluster,
    vertices:[]asset.Cluster_Vertex,
    triangles:[]u32,
    pages:[]asset.Mesh_Page, // those of level 0, which come first
    level:asset.Mesh_Level,
    position_step,uv_step,uv1_step:f32,
    posed:[]editor.Posed_Vertex,
    influences:[]erender.Skin_Influence,
    indices:[]u32, // into posed: the corners of the triangles, in the order asset.mesh_level_decode gives them
    joints:[]asset.Rig_Joint,
    skeleton:base.Asset_Id,
}

Subject_Skin :: struct {
    geometry:Skin_Geometry,
    buffers:editor.Skin_Preview,
    rig:core.Entity,
    part,rig_part:int,
    parents:[]i32,
    names:[]u64,
    rest,local,world:[]mm.Transform,
    palette:[]mm.Mat4,
}

@(private)
skin_geometry_free :: proc(skin:^Skin_Geometry) {
    delete(skin.clusters);delete(skin.vertices);delete(skin.triangles);delete(skin.pages)
    delete(skin.posed);delete(skin.influences);delete(skin.indices);delete(skin.joints)
    skin^={}
}

// The geometry skin_preview_init takes: level 0 alone.
@(private)
skin_geometry_level :: proc(skin:^Skin_Geometry)->asset.Mesh_Geometry {
    return {
        clusters=skin.clusters,levels=([^]asset.Mesh_Level)(&skin.level)[:1],vertices=skin.vertices,triangles=skin.triangles,pages=skin.pages,
        position_step=skin.position_step,uv_step=skin.uv_step,uv1_step=skin.uv1_step,
    }
}

// The skin of level 0 of a mesh: false for a mesh without one.
@(private)
skin_geometry_load :: proc(skin:^Skin_Geometry,view:asset.Mesh_View)->bool {
    if len(view.skin)==0 || len(view.joints)==0 || view.info.skeleton=={} || len(view.levels)==0 {return false}
    level:=view.levels[0]
    clusters:=view.clusters[level.first_cluster:][:level.cluster_count]
    // The vertices of level 0 are those of its clusters, which come first.
    vertices:=0
    for c in clusters {vertices=max(vertices,int(c.vertex_first+asset.cluster_vertex_count(c)))}
    next:Skin_Geometry
    success:=false
    defer if !success {skin_geometry_free(&next)}
    err:runtime.Allocator_Error
    next.clusters,err=make([]asset.Cluster,len(clusters));if err!=nil {return false}
    next.vertices,err=make([]asset.Cluster_Vertex,vertices);if err!=nil {return false}
    next.triangles,err=make([]u32,len(view.triangles));if err!=nil {return false}
    pages:=0
    for pages<len(view.pages) && view.pages[pages].level==0 {pages+=1}
    next.pages,err=make([]asset.Mesh_Page,pages);if err!=nil {return false}
    copy(next.pages,view.pages[:pages])
    next.posed,err=make([]editor.Posed_Vertex,vertices);if err!=nil {return false}
    next.influences,err=make([]erender.Skin_Influence,vertices);if err!=nil {return false}
    next.indices,err=make([]u32,3*level.triangle_count);if err!=nil {return false}
    next.joints,err=make([]asset.Rig_Joint,len(view.joints));if err!=nil {return false}
    copy(next.clusters,clusters);copy(next.vertices,view.vertices);copy(next.triangles,view.triangles)
    copy(next.influences,view.skin);copy(next.joints,view.joints)
    next.level=level
    next.level.first_cluster=0
    next.position_step,next.uv_step,next.uv1_step=view.position_step,view.uv_step,view.uv1_step
    at:=0
    for c in clusters {
        for t in 0..<asset.cluster_triangle_count(c) {
            for corner in asset.cluster_triangle(view.triangles,c,t) {next.indices[at]=c.vertex_first+corner;at+=1}
        }
    }
    next.skeleton=view.info.skeleton
    skin_geometry_free(skin);skin^=next;success=true
    return true
}

// A vertex of a triangle where the skin posed it.
@(private)
skin_vertex_place :: proc(placed:^editor.Thumbnail_Vertex,vertex:editor.Posed_Vertex) {
    placed.position=vertex.position
    placed.normal=mm.normal_unpack(vertex.normal)
    tangent,sign:=mm.tangent_unpack(vertex.tangent)
    placed.tangent={tangent.x,tangent.y,tangent.z,sign}
}

// The skin of a mesh of the project, read from its file.
@(private)
skin_geometry_read :: proc(skin:^Skin_Geometry,a:^host.Assets,mesh:base.Asset_Id)->bool {
    file:asset.Asset
    if host.assets_file(a,mesh,asset.KIND_MESH,&file)!=.None {return false}
    defer asset.asset_close(&file)
    view,error:=asset.mesh_view(&file,&a.types)
    return error==.None && asset.mesh_check_indices(view) && skin_geometry_load(skin,view)
}

@(private)
subject_skin_free :: proc(renderer:^erender.Renderer,skin:^Subject_Skin) {
    editor.skin_preview_destroy(renderer,&skin.buffers)
    skin_geometry_free(&skin.geometry)
    delete(skin.parents);delete(skin.names);delete(skin.rest);delete(skin.local);delete(skin.world);delete(skin.palette)
    skin^={}
}

@(private)
subject_skins_clear :: proc(sub:^Subject) {
    for &skin in sub.skins {subject_skin_free(sub.renderer,&skin)}
    clear(&sub.skins)
}

@(private)
subject_skin_ready :: proc(app:^host.App,w:core.World_Ref,skin:^Subject_Skin)->bool {
    if app.shared==nil {return false}
    cache:=core.world_storage_of(core.world_ref(app.shared,w.info,.Shared),eanim.Skeleton_Assets)
    if app.renderer==nil || cache==nil || skin.geometry.skeleton=={} {return false}
    content:=eanim.skeleton_content(cache,app.assets,app.allocator,skin.geometry.skeleton)
    if content==nil {return false}
    count:=len(content.bones)
    err:runtime.Allocator_Error
    skin.parents,err=make([]i32,count);if err!=nil {return false}
    skin.names,err=make([]u64,count);if err!=nil {return false}
    skin.rest,err=make([]mm.Transform,count);if err!=nil {return false}
    skin.local,err=make([]mm.Transform,count);if err!=nil {return false}
    skin.world,err=make([]mm.Transform,count);if err!=nil {return false}
    skin.palette,err=make([]mm.Mat4,len(skin.geometry.joints));if err!=nil {return false}
    for joint in skin.geometry.joints {if int(joint.node)>=count {return false}}
    for bone,i in content.bones {
        skin.parents[i],skin.names[i]=bone.parent,bone.target
        skin.rest[i]={position=bone.translation,rotation=bone.rotation,scale=bone.scale}
    }
    return editor.skin_preview_init(app.renderer,&skin.buffers,skin_geometry_level(&skin.geometry),skin.geometry.influences,u32(len(skin.palette)))
}

// The bones of a skin at rest with what pose puts over them, from root, and
// its vertices skinned on the GPU into geometry.posed.
@(private)
skin_pose :: proc(renderer:^erender.Renderer,skin:^Subject_Skin,pose:^anim.Pose,root:mm.Transform)->bool {
    for rest,i in skin.rest {
        skin.local[i]=rest
        if pose!=nil {pose_put(pose,skin.names[i],&skin.local[i])}
    }
    skeleton:=anim.Skeleton{parents=skin.parents,names=skin.names,rest=skin.rest}
    if !anim.skeleton_world(skeleton,skin.local,skin.world,root) {return false}
    // Thumbnail vertices are already in subject space, so mesh world and its inverse cancel.
    for joint,i in skin.geometry.joints {skin.palette[i]=mm.transform_matrix(skin.world[joint.node])*joint.inverse_bind}
    return editor.skin_preview_sample(renderer,&skin.buffers,skin.palette,skin.geometry.posed)
}

// The skinned vertices of a skin where its triangles are, one per index.
@(private)
skin_place :: proc(skin:^Subject_Skin,vertices:[]editor.Thumbnail_Vertex)->bool {
    if len(vertices)!=len(skin.geometry.indices) {return false}
    for index,i in skin.geometry.indices {skin_vertex_place(&vertices[i],skin.geometry.posed[index])}
    return true
}

@(private)
subject_skins_place :: proc(p:^Animation)->bool {
    sub:=&p.subject
    for &skin in sub.skins {
        if skin.buffers.vertex_count==0 || skin.rig_part<0 || skin.rig_part>=sub.part_count {return false}
        if !skin_pose(sub.renderer,&skin,&p.pose,sub.worlds[skin.rig_part]) {return false}
        part:=sub.parts[skin.part]
        posed:=sub.posed[part.first:][:part.count]
        copy(posed,sub.locals[part.first:][:part.count])
        if !skin_place(&skin,posed) {return false}
    }
    return true
}

@(private)
animation_subject :: proc(scene:Scene,entity:core.Entity)->core.Entity {
    if scene.skins!=nil {
        if skin,found:=core.get(scene.skins,entity);found && skin.rig!=core.NONE {return skin.rig}
    }
    return entity
}
