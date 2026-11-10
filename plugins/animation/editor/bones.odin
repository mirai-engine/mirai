package animation_editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import "mirai:ui"
import anim "plugins:animation/runtime"

@(private)
bone_inspector_rig :: proc(c:editor.Inspector_Context) -> core.Entity {
    owner:=c.entities[len(c.entities)-1]
    value:=core.raw_find(core.world_table_at(c.world,c.table),c.table.info,owner)
    if value==nil {return core.NONE}
    field:="rig"
    fields,ok:=runtime.type_info_base(c.table.info).variant.(runtime.Type_Info_Struct)
    if ok {for i in 0..<int(fields.field_count) {
        if fields.names[i]==field && fields.types[i].id==core.Entity {
            rig:=(^core.Entity)(rawptr(uintptr(value)+fields.offsets[i]))^
            return rig if rig!=core.NONE else owner
        }
    }}
    return owner
}

// The skeleton a rig poses: that of the mesh it shows, or of the rig whose pose its Pose_Source shares.
@(private)
rig_skeleton :: proc(s:^editor.Session,w:core.World_Ref,rig:core.Entity) -> base.Asset_Id {
    return mesh_skeleton(s,w,pose_owner(s,w,rig))
}

@(private)
mesh_skeleton :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) -> base.Asset_Id {
    shown,has:=editor.entity_get(w,e,erender.Mesh_Renderer)
    if !has || shown.mesh=={} || s.app==nil || s.app.assets==nil {return {}}
    mesh:=host.assets_mesh(s.app.assets,shown.mesh)
    return mesh.skeleton if mesh!=nil && !mesh.failed else {}
}

// The rig whose pose an entity shows: the rig of its Pose_Source when it shares that rig's
// skeleton, else itself. A mesh of another skeleton is a rig of its own that follows that one.
@(private)
pose_owner :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) -> core.Entity {
    skin,has:=editor.entity_get(w,e,anim.Pose_Source)
    if !has || skin.rig==core.NONE || skin.rig==e {return e}
    own,theirs:=mesh_skeleton(s,w,e),mesh_skeleton(s,w,skin.rig)
    return e if own!={} && theirs!={} && own!=theirs else skin.rig
}

@(private)
field_inspector :: proc(c:editor.Inspector_Context,info:^runtime.Type_Info,offset:uintptr,label:string) -> bool {
    return bone_inspector(c,info,offset,label) || clip_inspector(c,info,offset,label)
}

// The clip of an Animation, chosen among those of its asset.
@(private)
clip_inspector :: proc(c:editor.Inspector_Context,info:^runtime.Type_Info,offset:uintptr,label:string) -> bool {
    if c.table.type!=anim.Animation || offset!=offset_of(anim.Animation,clip) || len(c.entities)!=1 {return false}
    s:=c.session
    if s.app==nil {return false}
    value:=core.raw_find(core.world_table_at(c.world,c.table),c.table.info,c.entities[0])
    if value==nil {return false}
    animation:=(^anim.Animation)(value)
    content:=host.content_animation(s.app,animation.asset) if animation.asset!={} else nil
    if content==nil || len(content.names)==0 {return false}
    current:=base.text_get(animation.clip[:])
    names:=make([]string,len(content.names)+1,context.temp_allocator)
    selected:=0
    for &name,i in content.names {
        names[i]=base.text_get(name[:])
        if names[i]==current {selected=i}
    }
    count:=len(content.names)
    if current!="" && names[selected]!=current {names[count]=fmt.tprintf("Missing: %s",current);selected=count;count+=1}
    ctx:=s.gui.ctx
    if ui.property(ctx,label) {
        if ui.dropdown(ctx,ui.id(ctx,"clip",int(offset)+1),{list=names[:count]},&selected,{width=-1}) && selected<len(content.names) {
            chosen:=content.names[selected]
            editor.field_write(s,c.table,c.entities,int(offset),mem.ptr_to_bytes(&chosen))
        }
    }
    return true
}

@(private)
bone_inspector :: proc(c:editor.Inspector_Context,info:^runtime.Type_Info,offset:uintptr,label:string) -> bool {
    if info.id!=anim.Bone_Ref || len(c.entities)!=1 {return false}
    s:=c.session
    if s.app==nil || s.app.shared==nil {return false}
    skeleton:=rig_skeleton(s,c.world,bone_inspector_rig(c))
    if skeleton=={} {return false}
    cache:=core.world_storage_of(core.world_ref(s.app.shared,s.info,.Shared),anim.Skeleton_Assets)
    if cache==nil {return false}
    content:=anim.skeleton_content(cache,s.app.assets,s.app.allocator,skeleton)
    if content==nil {return false}
    value:=core.raw_find(core.world_table_at(c.world,c.table),c.table.info,c.entities[0])
    if value==nil {return false}
    reference:=(^anim.Bone_Ref)(rawptr(uintptr(value)+offset))^
    path:=base.text_get(reference.path[:])
    // None, the parts of the body the skeleton has by their label, then its bones.
    choices:=make([]anim.Bone_Ref,len(lib.Body_Part)+len(content.bones)+1,context.temp_allocator)
    count:=1
    for bone,part in content.body.bones {if bone>=0 {choices[count]=anim.bone_ref_part(part);count+=1}}
    for &bone in content.bones {choices[count].path=bone.path;count+=1}
    names:=make([]string,count+1,context.temp_allocator)
    names[0]="None"
    selected:=0
    for &choice,i in choices[1:count] {
        names[i+1]=base.text_get(choice.path[:])
        if names[i+1]==path {selected=i+1}
    }
    if path!="" && selected==0 {
        if index:=anim.skeleton_bone_find(content.bones,content.body,reference);index>=0 {
            for &choice,i in choices[1:count] {if choice.path==content.bones[index].path {selected=i+1;break}}
        }
    }
    known:=count
    if path!="" && selected==0 {names[count]=fmt.tprintf("Missing: %s",path);selected=count;count+=1}
    ctx:=s.gui.ctx
    if ui.property(ctx,label) {
        if ui.dropdown(ctx,ui.id(ctx,"bone",int(offset)+1),{list=names[:count]},&selected,{width=-1}) && selected<known {
            chosen:=choices[selected]
            editor.field_write(s,c.table,c.entities,int(offset),mem.ptr_to_bytes(&chosen))
        }
    }
    return true
}

// Where a Bone_Attachment puts its entity in Edit is the attachment's, not an
// edit of the scene: the journal takes it, so the next step of the user or
// the API does not hold it and the document stays without changes.
@(step="frame",stage="begin",before="editor_tools")
animation_attachments_derived :: proc(s:^editor.Session,attachments:core.Read(anim.Bone_Attachment),world:core.World_Ref) {
    if s.edits==nil || world.data!=s.edits.world {return}
    for row in 0..<core.count(attachments) {
        if core.at(attachments,row).enabled {history.edits_take_derived(s.edits,world,core.Transform,core.entity_at(attachments,row))}
    }
}
