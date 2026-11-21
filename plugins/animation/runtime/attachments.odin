package anim

import "core:mem"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

Attachment_Binding :: struct {
    entity:core.Entity,
    skeleton:base.Asset_Id,
    stamp,revision,bone,bound:u64,
    generation:u32,
    index:int,
    offset:mm.Transform,
}

@(private)
modifier_attachments_prepare :: proc(runtime:^Modifier_Runtime,attachments:^core.Table(Bone_Attachment,$A),
    skeletons:^Skeleton_Assets,playback:^Playback,loaded:^host.Assets,allocator:mem.Allocator,
    problems:^core.Problems,meshes:^core.Table(erender.Mesh_Renderer,.Read)) -> bool {
    for &rig in runtime.rigs {
        #reverse for &binding,i in rig.attachments {
            config,found:=core.get(attachments,binding.entity)
            if !found || !config.enabled || config.rig!=rig.entity {
                unordered_remove(&rig.attachments,i)
            }
        }
    }
    for row in 0..<core.count(attachments) {
        entity:=core.entity_at(attachments,row)
        config:=core.at(attachments,row)
        if !config.enabled {continue}
        rig:=modifier_rig(runtime,config.rig)
        current:=-1
        if rig!=nil {
            for &binding,i in rig.attachments {if binding.entity==entity {current=i;break}}
        }
        shown:=rig_find(playback,config.rig)
        if shown<0 {
            if current>=0 {unordered_remove(&rig.attachments,current)}
            if meshes!=nil {
                if renderer,has:=core.get(meshes,config.rig);has && renderer.mesh!={} {
                    mesh:=host.assets_mesh_shown(loaded,renderer.mesh)
                    if mesh==nil || mesh.arriving ||
                        mesh.failed && !host.assets_loaded(loaded,renderer.mesh) {continue}
                }
            }
            core.report(problems,entity,"animation.attachment_rig",
                "this Bone_Attachment needs a rig that shows a skinned mesh")
            continue
        }
        definition:=skeleton_content(skeletons,loaded,allocator,playback.rigs[shown].skeleton)
        if definition==nil {if current>=0 {unordered_remove(&rig.attachments,current)};continue}
        stamp:=core.stamp(attachments,row)
        if current>=0 {
            cached:=&rig.attachments[current]
            if cached.stamp==stamp && cached.skeleton==definition.id &&
                cached.revision==definition.revision {continue}
        }
        binding:=Attachment_Binding{entity=entity,stamp=stamp,revision=definition.revision,
            skeleton=definition.id,offset=config.offset,index=-1}
        if config.bone!={} {
            if config.socket[0]==0 {binding.bone=bone_ref_hash(config.bone)}
        } else {
            for &socket in definition.sockets {
                if socket.name!=config.socket {continue}
                binding.bone=bone_ref_hash({socket.bone})
                binding.offset=mm.transform_compose(socket.offset,config.offset)
                break
            }
        }
        if binding.bone==0 {
            if current>=0 {unordered_remove(&rig.attachments,current)}
            core.report(problems,entity,"animation.attachment_target",
                "this Bone_Attachment needs one valid bone or socket of its rig; set one and clear the other")
            continue
        }
        if rig==nil {rig=modifier_rig_add(runtime,config.rig)}
        if rig==nil {return false}
        if current>=0 {rig.attachments[current]=binding}
        else if append(&rig.attachments,binding)!=1 {return false}
    }
    return true
}
