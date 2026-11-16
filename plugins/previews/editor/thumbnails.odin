package previews_editor

import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// The thumbnails of animations: the model they move (thumbnail_models.odin),
// posed through its skeleton halfway through a clip, with the skinning of
// the animation document.

@(storage)
Previews_Thumbnails :: struct {provider:editor.Thumbnail_Provider}
PREVIEWS_THUMBNAILS_DEFAULT :: Previews_Thumbnails{provider={kinds={0=asset.KIND_ANIMATION},count=1,subject=thumbnail_subject,triangles=thumbnail_triangles}}

// What the thumbnail of an animation, or of its clip-th clip from 1, shows.
@(private)
thumbnail_subject :: proc(s:^editor.Session,file:^asset.Registry_File,clip:u32,subject:^editor.Thumbnail_Subject) -> bool {
    p:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Previews)
    a:=s.app.assets
    if p==nil || a==nil {return false}
    switch file.kind {
    case asset.KIND_ANIMATION:
        model:=thumbnail_animation_model(&p.models,a,file.id)
        switch {
        case model.mesh!={}:     subject^={mesh={mesh=model.mesh},tint=erender.MATERIAL_VALUES_DEFAULT,provider=file.kind,pose=file.id,clip=max(clip,1)}
        case model.document!={}: subject^={document=model.document,root=model.root}
        case:                    return false
        }
    case:
        return false
    }
    return true
}

// The triangles of the finest level of a skinned mesh posed through its
// skeleton, and the materials of its slots: by the clip-th clip of an
// animation halfway through it, or at rest when the clip cannot be read.
@(private)
thumbnail_triangles :: proc(s:^editor.Session,subject:^editor.Thumbnail_Subject,vertices:^[dynamic]editor.Thumbnail_Vertex,materials:^[dynamic]erender.Material_Desc) -> bool {
    app:=s.app
    a:=app.assets
    if a==nil || app.renderer==nil {return false}
    first:=len(vertices)
    if editor.triangles_append(a,subject.mesh,subject.tint,mm.TRANSFORM_IDENTITY,editor.THUMBNAIL_TRIANGLES*3-first,vertices,materials)!=.Added {return false}
    skin:Subject_Skin
    defer subject_skin_free(app.renderer,&skin)
    if !skin_geometry_read(&skin.geometry,a,subject.mesh.mesh) || !subject_skin_ready(app,core.world_ref(s.editor_world,s.info,.Editor),&skin) {return false}
    lib:anim.Library
    at:Clip_Time
    if subject.pose!={} {at,_=animation_halfway(a,subject.pose,subject.clip,&lib)}
    return skin_pose(app.renderer,&skin,at,mm.TRANSFORM_IDENTITY) && skin_place(&skin,vertices[first:])
}

// The clip-th clip of an animation, from 1, halfway through it, read into lib;
// the last clip for one past them. Temporary memory. False when the
// animation cannot be read.
@(private)
animation_halfway :: proc(a:^host.Assets,id:base.Asset_Id,clip:u32,lib:^anim.Library) -> (at:Clip_Time,ok:bool) {
    data:asset.Asset
    if host.assets_file(a,id,asset.KIND_ANIMATION,&data)!=.None {return}
    defer asset.asset_close(&data)
    view,error:=asset.animation_view(&data,&a.types)
    if error!=.None || len(view.clips)==0 {return}
    one:=view
    one.clips=view.clips[clamp(int(clip),1,len(view.clips))-1:][:1]
    desc:=asset.animation_library_desc(one)
    desc.allocator=context.temp_allocator
    if !anim.library_init(lib,desc) {return}
    played:=asset.animation_clips_add(one,lib)
    if played==0 {return}
    return {lib,played,anim.clip_duration(lib,played)*0.5},true
}
