package animation_editor

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "mirai:core"
import "mirai:editor"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

// What the audit of the playtest plugin is told of the attachments of a
// world: one whose drawn box is farther from its bone than its size allows
// floats off the hand or the hip it should be on (a guessed socket offset, a
// mesh whose pivot is far from its triangles).

// Of the diagonal of the box of what is attached: how far from it its bone may
// be. What sits on a bone touches it or nearly (a grip around the hand, a
// scabbard on the hip, a shield a hand's width off the spine).
ATTACH_FAR_SHARE :: f32(0.25)
// m, the least distance that is far: a ring or a coin a few centimetres off its bone is not.
ATTACH_FAR_LEAST :: f32(0.1)

@(storage)
Attachments_Audit :: struct {provider:editor.Audit_Provider}
ATTACHMENTS_AUDIT_DEFAULT :: Attachments_Audit{provider={audit=attachments_audit}}

// How far a bone is from the box [low, high] of what is attached to it, and
// the most it may be for the size of that box.
attachment_far :: proc "contextless" (bone,low,high:[3]f32) -> (distance,tolerance:f32,far:bool) {
    distance=linalg.length(bone-linalg.clamp(bone,low,high))
    tolerance=max(ATTACH_FAR_SHARE*linalg.length(high-low),ATTACH_FAR_LEAST)
    return distance,tolerance,distance>tolerance
}

@(private)
attachments_audit :: proc(s:^editor.Session,w:core.World_Ref,out:^[dynamic]editor.Audit_Finding,allocator:runtime.Allocator) {
    modifiers:=core.world_storage_of(w,anim.Modifier_Runtime)
    playback:=core.world_storage_of(w,anim.Playback)
    if modifiers==nil || playback==nil || s.app==nil || s.app.assets==nil {return}
    for &rig in modifiers.rigs {
        if len(rig.attachments)==0 {continue}
        pose,posed:=anim.pose_space(core.ref(playback),rig.entity,context.temp_allocator)
        if !posed {continue}
        placed:=editor.entity_world(w,rig.entity)
        for &binding in rig.attachments {
            if !binding.placed_ok || binding.index<0 || binding.index>=len(pose) {continue}
            bone:=mm.transform_compose(placed,pose[binding.index]).position
            low,high,found:=editor.entities_bounds(s,w,{binding.entity})
            if !found {continue}
            distance,tolerance,far:=attachment_far(bone,low,high)
            if !far {continue}
            config,_:=editor.entity_get(w,binding.entity,anim.Bone_Attachment)
            target:=base.text_get(config.socket[:])
            if target=="" {target=base.text_get(config.bone.path[:])}
            append(out,editor.Audit_Finding{severity=.Error,area=.Animation,entity=binding.entity,code="animation.attachment_far",
                message=fmt.aprintf("It is attached to %s of %s, but what it draws is %.2f m from that bone, more than the %.2f m its size of %.2f m allows: it floats off",target,editor.entity_label(w,rig.entity,context.temp_allocator),distance,tolerance,linalg.length(high-low),allocator=allocator),
                fix="Bring the offset of its Bone_Attachment (or the socket, skeleton.socket.set) to where it touches the bone; a mesh whose pivot is far from its triangles needs its pivot fixed in the source"})
        }
    }
}
