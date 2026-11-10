package previews_editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import eanim "plugins:animation/runtime"
import erender "mirai:engine/render"
import "mirai:host"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// The document of an .anim: its clips in the Hierarchy of the left panel, the
// clip posed on a subject with a timeline of its markers under it, and what
// the clip is in Details, as a scene places it at the right; what plays goes
// in the toolbar. The
// subject is the entity of the scene that plays the asset, else the skinned
// mesh its thumbnail shows (thumbnail_animation_model), else the
// selected entity; Details chooses another. Tracks bind as the animation
// library binds them: those without a target move the root, the others use
// Animation_Target, or Name when the entity has no target, or the bones of a
// skeleton. The pose is sampled with std/anim over the transforms the World
// has, kept in the document: the World is only read.

PART_CAPACITY :: 256        // entities of a subject
TRIANGLE_CAPACITY :: 131072 // of a subject; what does not fit is left out
FIT_SAMPLES :: 16           // times of the clip the view frames

// An entity of the subject.
Part :: struct {
    entity:core.Entity,
    parent:i32,         // its part's parent; -1 for the root
    local:mm.Transform, // as the World has it
    target:u64,
    skinned:bool,
    first,count:u32,    // its vertices in Subject.locals
    low,high:[3]f32,    // bounds of its vertices, in its own space
}

Subject :: struct {
    root:core.Entity,
    key:u64, // of what it was gathered from: 0 when nothing was
    parts:[PART_CAPACITY]Part,
    part_count:int,
    worlds:[PART_CAPACITY]mm.Transform, // of the parts in the pose last sampled, in the space of the parent of the root
    locals:[dynamic]editor.Thumbnail_Vertex, // in the space of their part
    posed:[dynamic]editor.Thumbnail_Vertex,
    materials:[dynamic]erender.Material_Desc,
    skins:[dynamic]Subject_Skin,
    renderer:^erender.Renderer,
    short:bool, // parts or triangles were left out
    fit:[2][3]f32,
    fit_key:u64,
}

// What a clip of the asset is.
Clip_Info :: struct {
    name:[asset.ANIMATION_NAME_CAPACITY]u8,
    duration:f32,
    tracks,keys:int,
    first_marker,marker_count:int,
    root:asset.Animation_Root,
}

// The cards of Details.
Animation_Card :: enum u8 {Clip,Preview}

// What a clip is, in the read-only rows of Details.
@(private)
Root_Motion :: enum u8 {None,Translation,Rotation,Translation_And_Rotation}
@(private)
Clip_Values :: struct {
    duration:f32 `mirai:"readonly,unit=s"`,
    tracks:i32 `mirai:"readonly"`,
    keys:i32 `mirai:"readonly"`,
    markers:i32 `mirai:"readonly"`,
    root_bone:[asset.ANIMATION_NAME_CAPACITY]u8 `mirai:"readonly,text"`,
    root_motion:Root_Motion `mirai:"readonly"`,
}

// A marker the menu of the timeline adds, renames or deletes: at time, the
// index-th of the clip (-1: a new one), with the name being written.
Marker_Edit :: struct {
    time:f32,
    index:int,
    name:[asset.ANIMATION_NAME_CAPACITY]u8,
    length:int,
    anchor:ui.Rect, // where the menu opened
}

Animation :: struct {
    image:editor.Asset_Image,
    marker:Marker_Edit,
    chosen:base.Asset_Id, // the .anim of the document in front
    clip_name:[asset.ANIMATION_NAME_CAPACITY]u8 `mirai:"text"`, // empty: the first of the asset
    using playback:editor.Asset_Playback, // inside the clip
    strip_clip:anim.Clip, // the clip the strip was last set for
    mesh:base.Asset_Id, // the skinned mesh the clip plays on; zero: an entity of the scene
    clips_scroll,details_scroll:[2]f32,
    folded:bit_set[Animation_Card], // the cards of Details closed
    camera:editor.Asset_View,
    sun:bool, // the sun lights the subject besides the sky
    // The asset in memory.
    loaded:base.Asset_Id,
    stamp:[2]i64, // size and time of its file when it was read
    lib:anim.Library,
    clips:[]Clip_Info,
    markers:[]asset.Animation_Marker,
    pose:anim.Pose,
    subject:Subject,
}

// The tables of the World that describe a subject; nil for a component the project does not have.
Scene :: struct {
    transforms:^core.Table(core.Transform),
    names:^core.Table(core.Name),
    targets:^core.Table(eanim.Animation_Target),
    parents:^core.Table(core.Parent),
    hierarchy:core.Ref(core.Hierarchy),
    meshes:^core.Table(erender.Mesh_Renderer),
    hidden:^core.Table(erender.Hidden),
    tints:^core.Table(erender.Tint),
    overrides:^core.Table(erender.Material_Override),
    animations:^core.Table(eanim.Animation),
    skins:^core.Table(eanim.Pose_Source),
}

@(private)
scene_of :: proc(w:core.World_Ref) -> Scene {
    return {
        transforms=core.world_table_of(w,core.Transform),names=core.world_table_of(w,core.Name),targets=core.world_table_of(w,eanim.Animation_Target),parents=core.world_table_of(w,core.Parent),hierarchy=core.ref(core.world_storage_of(w,core.Hierarchy)),
        meshes=core.world_table_of(w,erender.Mesh_Renderer),hidden=core.world_table_of(w,erender.Hidden),tints=core.world_table_of(w,erender.Tint),
        overrides=core.world_table_of(w,erender.Material_Override),animations=core.world_table_of(w,eanim.Animation),
        skins=core.world_table_of(w,eanim.Pose_Source),
    }
}

@(private)
animation_destroy :: proc(p:^Animation,allocator:runtime.Allocator) {
    if allocator.procedure!=nil {context.allocator=allocator}
    subject_skins_clear(&p.subject)
    delete(p.subject.skins)
    animation_unload(p,allocator)
    delete(p.subject.locals)
    delete(p.subject.posed)
    delete(p.subject.materials)
}

@(private)
animation_unload :: proc(p:^Animation,allocator:runtime.Allocator) {
    if p.lib.clips!=nil {anim.library_destroy(&p.lib)}
    if p.pose.entries!=nil {anim.pose_destroy(&p.pose)}
    delete(p.clips,allocator)
    delete(p.markers,allocator)
    p.lib,p.pose,p.clips,p.markers={},{},nil,nil
    p.loaded,p.stamp={},{}
}

// Reads the chosen asset when it is not the one in memory or its file changed.
@(private)
animation_load :: proc(a:^host.Assets,allocator:runtime.Allocator,p:^Animation) {
    record:^asset.Registry_File
    found:=false
    if a!=nil && p.chosen!={} {record,found=asset.registry_find(&a.registry,p.chosen)}
    stamp:=found?[2]i64{record.size,record.time}:{}
    if p.chosen==p.loaded && stamp==p.stamp {return}
    animation_unload(p,allocator)
    p.loaded,p.stamp=p.chosen,stamp
    if !found || record.kind!=asset.KIND_ANIMATION {return}
    file:asset.Asset
    if host.assets_file(a,p.chosen,asset.KIND_ANIMATION,&file)!=.None {return}
    defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&a.types)
    if error!=.None {return}
    desc:=asset.animation_library_desc(view)
    desc.allocator=allocator
    if !anim.library_init(&p.lib,desc) {return}
    if len(view.clips)>0 && asset.animation_clips_add(view,&p.lib)==0 || !anim.pose_init(&p.pose,max(len(view.tracks),1),allocator) {
        animation_unload(p,allocator)
        p.loaded,p.stamp=p.chosen,stamp
        return
    }
    p.clips=make([]Clip_Info,len(view.clips),allocator)
    for &clip,i in view.clips {
        info:=&p.clips[i]
        info^={name=clip.name,duration=anim.clip_duration(&p.lib,anim.Clip(i+1)),tracks=int(clip.track_count),first_marker=int(clip.first_marker),marker_count=int(clip.marker_count),root=clip.root}
        for track in view.tracks[clip.first_track:][:clip.track_count] {info.keys+=int(track.key_count)}
    }
    p.markers=make([]asset.Animation_Marker,len(view.markers),allocator)
    copy(p.markers,view.markers)
}

// The clip chosen, by its name: the first one when it has none or the asset does not have it. 0: none.
@(private)
animation_clip :: proc(p:^Animation) -> anim.Clip {
    if len(p.clips)==0 {return 0}
    wanted:=base.text_get(p.clip_name[:])
    for &clip,i in p.clips {
        if base.text_get(clip.name[:])==wanted {return anim.Clip(i+1)}
    }
    return 1
}

@(private)
pose_put :: proc(pose:^anim.Pose,target:u64,local:^mm.Transform) {
    if value,_,ok:=anim.pose_position(pose,target);ok {local.position=value}
    if value,_,ok:=anim.pose_rotation(pose,target);ok {local.rotation=value}
    if value,_,ok:=anim.pose_scale(pose,target);ok {local.scale=value}
}

// The transforms of the parts at a time of a clip; at rest without one.
@(private)
subject_pose :: proc(p:^Animation,clip:anim.Clip,time:f32) {
    sub:=&p.subject
    sampled:=clip!=0 && p.pose.entries!=nil
    if p.pose.entries!=nil {anim.pose_clear(&p.pose)}
    if sampled {
        player:=anim.player_make(clip)
        player.time=time
        anim.pose_blend(&p.pose,&p.lib,player)
    }
    for i in 0..<sub.part_count {
        part:=&sub.parts[i]
        local:=part.local
        if sampled {
            if i==0 {pose_put(&p.pose,0,&local)}
            if part.target!=0 {pose_put(&p.pose,part.target,&local)}
        }
        sub.worlds[i]=part.parent<0?local:mm.transform_compose(sub.worlds[part.parent],local)
    }
}

// The vertices of the parts where the pose puts them.
@(private)
subject_place :: proc(sub:^Subject) {
    for i in 0..<sub.part_count {
        part:=sub.parts[i]
        if part.skinned {continue}
        world:=sub.worlds[i]
        inverse:=[3]f32{1,1,1}
        for axis in 0..<3 {
            if abs(world.scale[axis])>1e-6 {inverse[axis]=1/world.scale[axis]}
        }
        for &vertex,at in sub.locals[part.first:][:part.count] {
            placed:=&sub.posed[int(part.first)+at]
            placed^=vertex
            placed.position=mm.transform_point(world,vertex.position)
            placed.normal=linalg.normalize0(mm.quat_rotate(world.rotation,vertex.normal*inverse))
            placed.tangent.xyz=linalg.normalize0(mm.quat_rotate(world.rotation,vertex.tangent.xyz*world.scale))
            if world.scale.x*world.scale.y*world.scale.z<0 {placed.tangent.w=-vertex.tangent.w}
        }
    }
}

// The box the parts fill over the whole clip, so that the view does not follow them.
@(private)
subject_fit :: proc(p:^Animation,clip:anim.Clip) {
    sub:=&p.subject
    low,high:=[3]f32{math.F32_MAX,math.F32_MAX,math.F32_MAX},[3]f32{-math.F32_MAX,-math.F32_MAX,-math.F32_MAX}
    duration:=clip!=0?anim.clip_duration(&p.lib,clip):0
    for sample in 0..=FIT_SAMPLES {
        subject_pose(p,clip,duration*f32(sample)/FIT_SAMPLES)
        if len(sub.skins)>0 {
            subject_place(sub)
            if !subject_skins_place(p) {sub.short=true;break}
            for vertex in sub.posed {low,high=linalg.min(low,vertex.position),linalg.max(high,vertex.position)}
            if duration<=0 {break}
            continue
        }
        for i in 0..<sub.part_count {
            part:=sub.parts[i]
            if part.count==0 {continue}
            for corner in 0..<8 {
                point:=[3]f32{corner&1==0?part.low.x:part.high.x,corner&2==0?part.low.y:part.high.y,corner&4==0?part.low.z:part.high.z}
                placed:=mm.transform_point(sub.worlds[i],point)
                low,high=linalg.min(low,placed),linalg.max(high,placed)
            }
        }
        if duration<=0 {break}
    }
    sub.fit=low.x<=high.x?[2][3]f32{low,high}:{}
}

// A part that shows a mesh: its triangles, skinned when the mesh has a
// skeleton and no Pose_Source follows another rig.
@(private)
part_mesh_add :: proc(a:^host.Assets,sub:^Subject,part:^Part,mesh:erender.Mesh_Renderer,tint:erender.Tint,override:^erender.Material_Override,rig:core.Entity) {
    skinned:=Subject_Skin{rig=rig,part=sub.part_count-1,rig_part=-1}
    switch editor.triangles_append(a,mesh,tint,override,mm.TRANSFORM_IDENTITY,TRIANGLE_CAPACITY*3-len(sub.locals),&sub.locals,&sub.materials) {
    case .Nothing:
    case .No_Room: sub.short=true
    case .Added:
        // Only a mesh on a skeleton is read again for its skin.
        if file,found:=asset.registry_find(&a.registry,mesh.mesh);found && asset.registry_skeleton(&a.registry,file)!={} {skin_geometry_read(&skinned.geometry,a,mesh.mesh)}
    }
    if len(skinned.geometry.posed)>0 {
        if _,error:=append(&sub.skins,skinned);error!=nil {skin_geometry_free(&skinned.geometry);sub.short=true} else {part.skinned=true}
    }
    part.count=u32(len(sub.locals))-part.first
    part.low,part.high={math.F32_MAX,math.F32_MAX,math.F32_MAX},{-math.F32_MAX,-math.F32_MAX,-math.F32_MAX}
    for vertex in sub.locals[part.first:] {part.low,part.high=linalg.min(part.low,vertex.position),linalg.max(part.high,vertex.position)}
}

@(private)
part_add :: proc(a:^host.Assets,scene:Scene,sub:^Subject,e:core.Entity,parent:i32) {
    part:=&sub.parts[sub.part_count]
    sub.part_count+=1
    part^={entity=e,parent=parent,local=mm.TRANSFORM_IDENTITY,first=u32(len(sub.locals))}
    if scene.transforms!=nil {
        if t,ok:=core.get(core.read(scene.transforms),e);ok {part.local=core.to_math(t)}
    }
    if scene.targets!=nil {
        if target,ok:=core.get(core.read(scene.targets),e);ok {part.target=base.name_hash(base.text_get(target.path[:]))}
    }
    if part.target==0 && scene.names!=nil {
        if text:=core.name_get(core.read(scene.names),e);text!="" {part.target=base.name_hash(text)}
    }
    if scene.meshes==nil {return}
    mesh,has_mesh:=core.get(core.read(scene.meshes),e)
    if !has_mesh || scene.hidden!=nil && core.has(scene.hidden,e) {return}
    tint:=erender.TINT_DEFAULT
    if scene.tints!=nil {
        if value,ok:=core.get(core.read(scene.tints),e);ok {tint=value}
    }
    overridden:erender.Material_Override
    override:^erender.Material_Override
    if scene.overrides!=nil {
        if value,ok:=core.get(core.read(scene.overrides),e);ok {overridden,override=value,&overridden}
    }
    rig:=e
    if scene.skins!=nil {
        if skin,found:=core.get(core.read(scene.skins),e);found {rig=skin.rig}
    }
    part_mesh_add(a,sub,part,mesh,tint,override,rig)
}

// Reads the subtree of an entity from the World, in preorder.
@(private)
subject_node :: proc(a:^host.Assets,scene:Scene,sub:^Subject,e:core.Entity,parent:i32) {
    if sub.part_count>=PART_CAPACITY {
        sub.short=true
        return
    }
    index:=i32(sub.part_count)
    part_add(a,scene,sub,e,parent)
    for child:=core.first_child(scene.hierarchy,e);child!=core.NONE;child=core.next_sibling(scene.hierarchy,child) {subject_node(a,scene,sub,child,index)}
}

@(private)
subject_begin :: proc(renderer:^erender.Renderer,sub:^Subject,root:core.Entity,key:u64) {
    subject_skins_clear(sub)
    sub.renderer=renderer
    clear(&sub.locals);clear(&sub.posed);clear(&sub.materials)
    sub.root,sub.key,sub.part_count,sub.short,sub.fit_key=root,key,0,false,0
}

// The skins find the part of their rig, and the vertices their room to be posed.
@(private)
subject_end :: proc(app:^host.App,w:core.World_Ref,sub:^Subject) {
    for &skin in sub.skins {
        for part,i in sub.parts[:sub.part_count] {if part.entity==skin.rig {skin.rig_part=i;break}}
        if skin.rig_part<0 || !subject_skin_ready(app,w,&skin) {sub.short=true}
    }
    if resize(&sub.posed,len(sub.locals))!=nil {
        subject_skins_clear(sub)
        clear(&sub.locals);clear(&sub.posed)
        sub.part_count,sub.short=0,true
    }
}

@(private)
subject_gather :: proc(app:^host.App,w:core.World_Ref,scene:Scene,sub:^Subject,root:core.Entity,key:u64) {
    context.allocator=app.allocator
    subject_begin(app.renderer,sub,root,key)
    if !core.alive(core.world_entities(w),root) || app.assets==nil {return}
    subject_node(app.assets,scene,sub,root,-1)
    subject_end(app,w,sub)
}

// A skinned mesh of the project alone, at rest at the origin, its own rig.
@(private)
subject_gather_mesh :: proc(app:^host.App,w:core.World_Ref,sub:^Subject,mesh:base.Asset_Id,key:u64) {
    context.allocator=app.allocator
    subject_begin(app.renderer,sub,core.NONE,key)
    if app.assets==nil || mesh=={} {return}
    part:=&sub.parts[0]
    sub.part_count=1
    part^={entity=core.NONE,parent=-1,local=mm.TRANSFORM_IDENTITY}
    part_mesh_add(app.assets,sub,part,{mesh=mesh},erender.TINT_DEFAULT,nil,core.NONE)
    subject_end(app,w,sub)
}

// What changes the subject: the tables that describe it and the assets it is made of.
@(private)
scene_key :: proc(scene:Scene,root:core.Entity,mesh:base.Asset_Id,a:^host.Assets,reloads:u64) -> u64 {
    version :: proc(t:^core.Table($T)) -> u64 {return t!=nil?t.version+t.layout:0}
    return signature_of({
        u64(root),mesh[0],mesh[1],version(scene.transforms),version(scene.names),version(scene.targets),version(scene.parents),version(scene.meshes),version(scene.hidden),
        version(scene.tints),version(scene.overrides),version(scene.skins),a!=nil?a.revision:0,reloads,
    })
}

// The entity of the scene a clip of the asset plays on: one whose Animation
// plays it, else the selected one; its rig when it follows one.
@(private)
animation_scene_subject :: proc(s:^editor.Session,scene:Scene,chosen:base.Asset_Id) -> core.Entity {
    if scene.animations!=nil {
        for value,row in scene.animations.values[:core.count(scene.animations)] {
            if value.asset==chosen {return animation_subject(scene,scene.animations.entities[row])}
        }
    }
    return animation_subject(scene,history.selection_active(s.selection))
}

// Reads the subject again when it changed and draws the pose of the time when the image does not show it.
@(private)
animation_refresh :: proc(s:^editor.Session,app:^host.App,w:core.World_Ref,scene:Scene,p:^Animation,root:core.Entity) {
    a:=app.assets
    clip:=animation_clip(p)
    key:=scene_key(scene,root,p.mesh,a,app.shaders.reloads)
    sub:=&p.subject
    if key!=sub.key || sub.renderer!=app.renderer {
        if p.mesh!={} {subject_gather_mesh(app,w,sub,p.mesh,key)} else {subject_gather(app,w,scene,sub,root,key)}
    }
    fit_key:=signature_of({sub.key,u64(p.loaded[0]),u64(p.stamp[1]),u64(clip)})
    if fit_key!=sub.fit_key {
        subject_fit(p,clip)
        sub.fit_key=fit_key
    }
    time_bits:=transmute(u32)p.time
    view_bits:=editor.asset_view_bits(&p.camera)
    if signature:=signature_of({fit_key,u64(time_bits),u64(view_bits[0]),u64(view_bits[1]),u64(view_bits[2]),u64(view_bits[3]),u64(view_bits[4]),u64(p.sun)});editor.asset_image_due(s,&p.image,signature) {
        subject_pose(p,clip,p.time)
        subject_place(sub)
        if !subject_skins_place(p) {p.image.ready=false;return}
        sun:=editor.PREVIEW_SUN
        sun.enabled=p.sun
        editor.asset_image_draw(s,&p.image,IMAGE_SIDE,signature,sub.posed[:],sub.materials[:],sub.fit,p.camera.view,{outdoor=true,sun=sun,environment=editor.PREVIEW_ENVIRONMENT})
    }
}

// The document: the clips in the Hierarchy, the preview with its timeline and the details.
@(private)
animation_document :: proc(s:^editor.Session,previews:^Previews,w:core.World_Ref,app:^host.App,frame:core.Frame_Time,d:^editor.Asset_Document) {
    p:=&previews.animation
    chosen:=d.id
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    a:=app.assets
    scene:=scene_of(w)
    if p.chosen!=chosen {
        // Another document: its first clip from the start, on what it plays on.
        p.chosen=chosen
        base.text_clear(p.clip_name[:])
        p.time,p.playing=0,false
        animation_load(a,previews.allocator,p)
        p.mesh={}
        if !animation_plays(scene,chosen) {p.mesh=thumbnail_animation_model(&previews.models,a,chosen).mesh}
    }
    // A clip the document was opened on, from the content browser.
    if part:=base.text_get(d.part[:]);part!="" {
        base.text_set(p.clip_name[:],part)
        p.time,p.playing=0,false
        base.text_clear(d.part[:])
    }
    animation_load(a,previews.allocator,p)
    clip:=animation_clip(p)
    // Another clip starts at its beginning, in view whole and without a range.
    if clip!=p.strip_clip {p.strip,p.strip_clip={},clip}
    duration:=clip!=0?anim.clip_duration(&p.lib,clip):0
    editor.asset_playback_advance(&p.playback,duration,frame.dt)
    root:=animation_scene_subject(s,scene,chosen)

    editor.asset_preview_sun(s,&p.sun)
    animation_toolbar(s,p,clip)
    animation_clips(s,p,clip)
    subject_name:=""
    if p.mesh!={} {subject_name=editor.asset_name_of(a,p.mesh)} else if scene.names!=nil {subject_name=core.name_get(core.read(scene.names),root)}
    animation_say(d,p,clip,duration,subject_name)
    document,details,room:=editor.asset_workspace_details(s)
    id:=ui.id_derive(ctx,DOCUMENT_SCOPE,"animation")
    if ui.panel(ctx,id,document) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        ui.id_push(ctx,SCOPE_ANIMATION)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column}) {
            it,area:=editor.asset_image_show(s,&p.image)
            editor.asset_view_input(ctx,&p.camera,it,area)
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column,padding={editor.asset_workspace_under(g),0,0,0}}) {
                animation_timeline(s,p,a,clip,duration)
            }
        }
    }
    details_id:=ui.id_derive(ctx,DOCUMENT_SCOPE,"animation_details")
    if ui.panel(ctx,details_id,details) {
        ui.id_push(ctx,details_id)
        defer ui.id_pop(ctx)
        animation_details(s,p,&previews.models,a,clip,details.width.value,room)
    }
    animation_refresh(s,app,w,scene,p,root)
}

// What the document shows, for the context of the AI: the clip, its frame and
// time and how it plays, and the subject it plays on.
@(private)
animation_say :: proc(d:^editor.Asset_Document,p:^Animation,clip:anim.Clip,duration:f32,subject:string) {
    if clip==0 {editor.asset_document_show_say(d,"the asset without a clip");return}
    state:="paused"
    if p.playing {state=fmt.tprintf("playing at %gx%s",p.speed,p.loop?" in a loop":"")}
    if p.strip.range {state=fmt.tprintf("%s within frames %d to %d",state,int(p.strip.range_in),int(p.strip.range_out))}
    on:=subject!=""?fmt.tprintf(" on %s",subject):""
    editor.asset_document_show_say(d,fmt.tprintf("clip %s at frame %d of %d (%.3f s of %.3f s at %g frames per second), %s%s",base.text_get(p.clips[clip-1].name[:]),int(p.time*editor.ASSET_PLAYBACK_RATE+0.5),int(duration*editor.ASSET_PLAYBACK_RATE+0.5),p.time,duration,editor.ASSET_PLAYBACK_RATE,state,on))
}

// The clip shown, in the middle of the toolbar: a list of the clips of the
// asset that chooses another, as the Hierarchy does.
@(private)
animation_toolbar :: proc(s:^editor.Session,p:^Animation,clip:anim.Clip) {
    g:=s.gui;ctx:=g.ctx;th:=&ctx.theme
    rect,found:=editor.asset_toolbar_whole(g)
    if !found || rect.w<=0 || len(p.clips)==0 {return}
    if ui.box(ctx,{width=ui.fixed(rect.w),height=ui.fixed(rect.h),align_x=.Center,align_y=.Center,float={to=.Surface,offset={rect.x,rect.y},layer=ui.LAYER_BAR}}) {
        ui.id_push(ctx,ui.id_derive(ctx,DOCUMENT_SCOPE,"animation_toolbar"))
        defer ui.id_pop(ctx)
        names:=make([]string,len(p.clips),context.temp_allocator)
        for &info,i in p.clips {names[i]=base.text_get(info.name[:])}
        selected:=max(int(clip)-1,0)
        if ui.dropdown(ctx,ui.id(ctx,"clip"),{list=names},&selected,{width=200,height=th.control,searchable=len(names)>10}) {
            base.text_set(p.clip_name[:],names[selected])
            p.time,p.playing=0,false
        }
    }
}

// The clips of the asset, in the room the Hierarchy of the left panel leaves
// to the document: a click plays one from its start.
@(private)
animation_clips :: proc(s:^editor.Session,p:^Animation,clip:anim.Clip) {
    g:=s.gui
    ctx:=g.ctx
    room,found:=editor.hierarchy_room(g)
    if !found || room.w<=0 || room.h<=0 {return}
    column:=ui.Box{width=ui.fixed(room.w),height=ui.fixed(room.h),direction=.Column,float={to=.Surface,offset={room.x,room.y},layer=ui.LAYER_BAR}}
    ui.box_begin(ctx,column)
    defer ui.box_end(ctx,column)
    ui.id_push(ctx,ui.id_derive(ctx,DOCUMENT_SCOPE,"animation_hierarchy"))
    defer ui.id_pop(ctx)
    if ui.scroll_area(ctx,ui.id(ctx,"clips"),&p.clips_scroll,{width=ui.GROW,height=ui.GROW,direction=.Column}) {
        for &info,i in p.clips {
            name:=base.text_get(info.name[:])
            if ui.row(ctx,ui.id(ctx,"clip",i+1),{label=name,detail=fmt.tprintf("%.2f s",info.duration),icon=.Play,icon_size=14,selected=int(clip)==i+1,height=editor.OUTLINER_ROW}).clicked {
                base.text_set(p.clip_name[:],name)
                p.time,p.playing=0,false
            }
        }
    }
}

// Whether an entity of the scene plays the asset.
@(private)
animation_plays :: proc(scene:Scene,chosen:base.Asset_Id) -> bool {
    if scene.animations==nil {return false}
    for value in scene.animations.values[:core.count(scene.animations)] {if value.asset==chosen {return true}}
    return false
}

// The time strip of the clip under its preview, with its markers in a lane:
// a drag moves one, its button adds one at the head, and the right button
// opens a menu that adds one where it was pressed, or renames or deletes the
// one under it.
@(private)
animation_timeline :: proc(s:^editor.Session,p:^Animation,a:^host.Assets,clip:anim.Clip,duration:f32) {
    ctx:=s.gui.ctx
    marks:[]editor.Timeline_Mark
    if clip!=0 {
        info:=&p.clips[clip-1]
        markers:=p.markers[info.first_marker:][:info.marker_count]
        marks=make([]editor.Timeline_Mark,len(markers),context.temp_allocator)
        for &marker,i in markers {marks[i]={frame=marker.time*editor.ASSET_PLAYBACK_RATE,name=base.text_get(marker.name[:])}}
    }
    lanes:=[1]editor.Timeline_Lane{{name="Markers",marks=marks,add=clip!=0}}
    r:=editor.asset_playback_strip(s,&p.playback,duration,lanes[:],p.chosen,clip!=0?base.text_get(p.clips[clip-1].name[:]):"")
    menu:=ui.id(ctx,"marker_menu")
    naming:=ui.id(ctx,"marker_name")
    field:=ui.id(ctx,"marker_name_field")
    name_begin :: proc(ctx:^ui.Context,p:^Animation,naming,field:ui.Id,name:string) {
        p.marker.length=copy(p.marker.name[:],name)
        ui.popup_open(ctx,naming,p.marker.anchor)
        ui.edit_request(ctx,field)
    }
    pointer:=ctx.input.pointer
    switch {
    case clip==0:
    case r.moved:
        p.marker={time=r.to/editor.ASSET_PLAYBACK_RATE,index=r.index}
        animation_marker_write(s,a,p,clip,marks[r.index].name,false,"Move marker")
    case r.add:
        p.marker={time=r.to/editor.ASSET_PLAYBACK_RATE,index=-1,anchor={pointer.x,pointer.y,1,1}}
        name_begin(ctx,p,naming,field,"")
    case r.menu:
        p.marker={time=r.to/editor.ASSET_PLAYBACK_RATE,index=r.index,anchor=r.anchor}
        ui.popup_open(ctx,menu,p.marker.anchor)
    }
    if ui.popup(ctx,menu,{min_width=ui.MENU_CHOICE_WIDTH}) {
        if p.marker.index<0 {
            if ui.menu_item(ctx,ui.id(ctx,"marker_add"),"Add marker",{icon=.Plus}) {name_begin(ctx,p,naming,field,"")}
        } else if clip!=0 && p.marker.index<len(marks) {
            if ui.menu_item(ctx,ui.id(ctx,"marker_rename"),"Rename marker",{icon=.Edit}) {name_begin(ctx,p,naming,field,marks[p.marker.index].name)}
            if ui.menu_item(ctx,ui.id(ctx,"marker_delete"),"Delete marker",{icon=.Cross}) {animation_marker_write(s,a,p,clip,"",true)}
        }
    }
    if ui.popup(ctx,naming,{width=200}) {
        result:=ui.text_field(ctx,field,p.marker.name[:],&p.marker.length,{height=ctx.theme.control,placeholder="Marker name"})
        if result.committed || result.cancelled {ui.popup_close(ctx,naming)}
        if name:=strings.trim_space(string(p.marker.name[:p.marker.length]));result.committed && name!="" {animation_marker_write(s,a,p,clip,name,false)}
    }
}

// Writes the marker of the menu of the timeline into the clip, with name, or
// takes it out with remove: the .anim changes in memory, unsaved, as a step of
// the history of the document. Markers keep the order of their times.
@(private)
animation_marker_write :: proc(s:^editor.Session,a:^host.Assets,p:^Animation,clip:anim.Clip,name:string,remove:bool,label:="") -> bool {
    if a==nil || clip==0 || p.loaded=={} {return false}
    record,found:=asset.registry_find(&a.registry,p.loaded)
    if !found {return false}
    file:asset.Asset
    if host.assets_file(a,p.loaded,asset.KIND_ANIMATION,&file)!=.None {return false}
    defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&a.types)
    if error!=.None {return false}
    clips,ok:=asset.animation_descs(view,context.temp_allocator)
    if !ok || int(clip)>len(clips) {return false}
    edited:=&clips[clip-1]
    markers:=make([dynamic]asset.Animation_Marker_Desc,0,len(edited.markers)+1,context.temp_allocator)
    for marker,i in edited.markers {
        if i!=p.marker.index {append(&markers,marker)}
    }
    label:=label
    if label=="" {label=remove?"Delete marker":(p.marker.index<0?"Add marker":"Rename marker")}
    if !remove {
        at:=len(markers)
        for marker,i in markers {
            if marker.time>p.marker.time {at=i;break}
        }
        inject_at(&markers,at,asset.Animation_Marker_Desc{p.marker.time,name})
    }
    edited.markers=markers[:]
    doc:asset.Document
    defer asset.document_destroy(&doc)
    if asset.animation_document(&doc,&a.types,{id=p.loaded,clips=clips,source=view.source},context.temp_allocator)!=.None {return false}
    bytes,bytes_error:=asset.document_bytes(&doc,context.temp_allocator)
    if bytes_error!=.None {return false}
    return editor.file_write(s,asset.registry_file_path(&a.registry,record.path,context.temp_allocator),bytes,label)
}

// What the clip is and what it plays on, as Details shows an entity: the
// line of the clip over cards that fold. width: of the panel; room: the
// height it can take.
@(private)
animation_details :: proc(s:^editor.Session,p:^Animation,models:^Thumbnail_Models,a:^host.Assets,clip:anim.Clip,width,room:f32) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(editor.INSPECTOR_HEAD),padding={11,0,7,0},gap=6,align_y=.Center}) {
        ui.icon(ctx,.Rotate,th.text_muted,15)
        title:=clip!=0?base.text_get(p.clips[clip-1].name[:]):editor.asset_name_of(a,p.chosen)
        ui.label(ctx,title,th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
    }
    origin:=editor.ai_provenance_asset_row(s)
    if ui.scroll_area(ctx,ui.id(ctx,"details"),&p.details_scroll,{height=ui.FIT,max_height=max(room-editor.INSPECTOR_HEAD-origin,40),padding={8,7,8,8},gap=7,fade=th.panel}) {animation_cards(s,p,models,a,clip,width)}
}

@(private)
animation_cards :: proc(s:^editor.Session,p:^Animation,models:^Thumbnail_Models,a:^host.Assets,clip:anim.Clip,width:f32) {
    ctx:=s.gui.ctx;th:=&ctx.theme
    if clip!=0 {
        if details_card(s,p,.Clip,"Clip",.Play) {
            info:=&p.clips[clip-1]
            values:=Clip_Values{duration=info.duration,tracks=i32(info.tracks),keys=i32(info.keys),markers=i32(info.marker_count)}
            bone:=base.text_get(info.root.bone[:])
            base.text_set(values.root_bone[:],bone)
            switch {
            case info.root.translation && info.root.rotation: values.root_motion=.Translation_And_Rotation
            case info.root.translation: values.root_motion=.Translation
            case info.root.rotation: values.root_motion=.Rotation
            }
            // As Details: the rows of a card, short of its padding and that of the scroll.
            held:=editor.Held_Values{key=KEY_ANIMATION,info=type_info_of(Clip_Values),value=&values,defaults=&values,width=width-28}
            for field in ([4]string{"duration","tracks","keys","markers"}) {editor.held_field_row(s,held,field)}
            if bone!="" {
                editor.held_field_row(s,held,"root_bone")
                editor.held_field_row(s,held,"root_motion")
            }
        }
    }
    if details_card(s,p,.Preview,"Preview",.Eye) {
        // What it plays on: an entity of the scene, or a skinned mesh.
        meshes:=skinned_meshes(models,a)
        names:=make([]string,len(meshes)+1,context.temp_allocator)
        names[0]="Scene"
        selected:=0
        for candidate,i in meshes {
            names[i+1]=editor.asset_name_of(a,candidate.mesh)
            if candidate.mesh==p.mesh {selected=i+1}
        }
        editor.row_begin(ctx,"Subject")
        if ui.dropdown(ctx,ui.id(ctx,"subject"),{list=names},&selected,{width=-1,height=th.row,searchable=len(names)>10}) {p.mesh=selected>0?meshes[selected-1].mesh:{}}
        editor.row_end(ctx)
        if p.subject.short {ui.label(ctx,"Part of the subject is left out",th.font_small,th.text_muted)}
    }
}

// A card of Details whose band folds it: true while it is open, with its rows to build.
@(private,deferred_in_out=details_card_end)
details_card :: proc(s:^editor.Session,p:^Animation,card:Animation_Card,title:string,icon:ui.Icon) -> (open:bool) {
    editor.card_begin(s)
    open=card not_in p.folded
    if editor.section_band(s,ui.id(s.gui.ctx,"card",int(card)+1),title,open,icon).clicked {
        p.folded~={card}
        open=!open
    }
    if open {editor.card_body_begin(s)}
    return
}
@(private)
details_card_end :: proc(s:^editor.Session,p:^Animation,card:Animation_Card,title:string,icon:ui.Icon,open:bool) {
    if open {editor.card_body_end(s)}
    editor.card_end(s)
}
