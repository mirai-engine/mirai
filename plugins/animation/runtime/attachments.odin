package anim

import "core:mem"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// The longest a socket switch (attach) takes, seconds.
ATTACH_BLEND_MAX :: 0.2

Attachment_Binding :: struct {
    entity:core.Entity,
    skeleton:base.Asset_Id,
    stamp,revision,bone,bound:u64,
    asked:u64, // the serial of the attach it is bound by; 0: none
    generation:u32,
    index:int,
    offset:mm.Transform,
    placed:mm.Transform, // where it last put its entity, in the world
    from:mm.Transform,   // where a switch starts: in the world until the first pose after it (from_world), then in the axes of its bone
    blend,blended:f32,   // seconds of the switch and of it gone
    placed_ok,from_world:bool,
}

// A socket a game asked a Bone_Attachment to be at instead of its own (attach); serial grows with
// each change, which binds it again.
Attach_Asked :: struct {
    entity:core.Entity,
    socket:[64]u8,
    blend:f32,
    serial:u64,
}

Attach_Request :: struct {
    entity:core.Entity,
    socket:[64]u8,
    blend:f32,
}

// Moves the entity of a Bone_Attachment to socket of the skeleton of its rig (from the hip to the
// hand) over blend seconds, 0 to ATTACH_BLEND_MAX (0: at once), from where it is toward the socket
// as the bone moves; an empty socket takes it back to the bone or socket of its Bone_Attachment,
// which says where it rests. Asking for where it is does nothing, so a game may ask every tick.
attach :: proc(requests:^Animation_Requests,entity:core.Entity,socket:string,blend:f32=0) {
    if requests==nil {return}
    asked:=Attach_Request{entity=entity,blend=blend}
    if len(socket)>=len(asked.socket) {asked.blend=-1} else {base.text_set(asked.socket[:],socket)}
    core.push(&requests.attaches,asked)
}

// Takes the attach requests: the socket each Bone_Attachment is asked to be at.
@(private)
attaches_take :: proc(runtime:^Modifier_Runtime,requests:^Animation_Requests,problems:^core.Problems) {
    for asked in core.take(&requests.attaches) {
        if !(asked.blend>=0 && asked.blend<=ATTACH_BLEND_MAX) {
            core.report(problems,asked.entity,"animation.attach","attach was refused: its socket name is longer than 63 bytes or its blend %v is not 0 to %v seconds; ask with a shorter name and a blend in that range",asked.blend,ATTACH_BLEND_MAX)
            continue
        }
        at:=-1
        for a,i in runtime.attached {if a.entity==asked.entity {at=i;break}}
        if at>=0 && runtime.attached[at].socket==asked.socket {continue}
        if at<0 {
            if asked.socket[0]==0 {continue}
            if append(&runtime.attached,Attach_Asked{entity=asked.entity})!=1 {
                memory_problem(problems,asked.entity,"the socket attach asked");continue
            }
            at=len(runtime.attached)-1
        }
        runtime.attach_serial+=1
        a:=&runtime.attached[at]
        a.socket,a.blend,a.serial=asked.socket,asked.blend,runtime.attach_serial
    }
}

// Where the attachment of an entity is asked to be, by attach: nil when it rests where its
// Bone_Attachment says.
@(private)
attach_asked :: proc(runtime:^Modifier_Runtime,entity:core.Entity) -> ^Attach_Asked {
    for &a in runtime.attached {if a.entity==entity {return &a}}
    return nil
}

// The offset an attachment takes this tick from the bone it is on: toward its own along a switch,
// which starts where it was. dt: seconds of the tick.
@(private)
attachment_offset :: proc(attachment:^Attachment_Binding,bone:mm.Transform,dt:f32) -> mm.Transform {
    if !(attachment.blended<attachment.blend) {return attachment.offset}
    if attachment.from_world {
        local,ok:=mm.transform_relative(attachment.from,bone)
        if !ok {attachment.blended=attachment.blend;return attachment.offset}
        attachment.from,attachment.from_world=local,false
    }
    attachment.blended=min(attachment.blended+dt,attachment.blend)
    return mm.transform_interpolate(attachment.from,attachment.offset,mm.smoothstep(0,1,attachment.blended/attachment.blend))
}

@(private)
modifier_attachments_prepare :: proc(runtime:^Modifier_Runtime,attachments:^core.Table(Bone_Attachment,$A),
    skeletons:^Skeleton_Assets,playback:^Playback,loaded:^host.Assets,allocator:mem.Allocator,
    problems:^core.Problems,meshes:^core.Table(erender.Mesh_Renderer,.Read)) -> bool {
    #reverse for a,i in runtime.attached {
        config,found:=core.get(attachments,a.entity)
        if !found {
            core.report(problems,a.entity,"animation.attach","attach was asked of an entity without a Bone_Attachment; give it one, or ask for the entity that has it")
        }
        if !found || !config.enabled {unordered_remove(&runtime.attached,i)}
    }
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
        rig:=modifier_rig(core.ref(runtime),config.rig)
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
        asked:=attach_asked(runtime,entity)
        serial:=asked.serial if asked!=nil else 0
        if current>=0 {
            cached:=&rig.attachments[current]
            if cached.stamp==stamp && cached.skeleton==definition.id &&
                cached.revision==definition.revision && cached.asked==serial {continue}
        }
        binding:=Attachment_Binding{entity=entity,stamp=stamp,revision=definition.revision,
            skeleton=definition.id,offset=config.offset,index=-1,asked=serial}
        if current>=0 {
            // A switch starts where it was; bound again for another reason, it goes on.
            was:=rig.attachments[current]
            binding.placed,binding.placed_ok=was.placed,was.placed_ok
            if was.asked==serial {
                binding.from,binding.from_world,binding.blend,binding.blended=was.from,was.from_world,was.blend,was.blended
            } else if asked!=nil && asked.blend>0 && was.placed_ok {
                binding.from,binding.from_world,binding.blend=was.placed,true,asked.blend
            }
        }
        if asked!=nil && asked.socket[0]!=0 {
            for &socket in definition.sockets {
                if socket.name!=asked.socket {continue}
                binding.bone=bone_ref_hash({socket.bone})
                binding.offset=socket.offset
                break
            }
            if binding.bone==0 {
                core.report(problems,entity,"animation.attach_socket",
                    "attach asked for the socket %s, which the skeleton of its rig does not have, so it stays at the bone or socket of its Bone_Attachment; ask for a socket of that skeleton (skeleton.socket.set)",base.text_get(asked.socket[:]))
            }
        }
        if binding.bone==0 && config.bone!={} {
            if config.socket[0]==0 {binding.bone=bone_ref_hash(config.bone)}
        } else if binding.bone==0 {
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
