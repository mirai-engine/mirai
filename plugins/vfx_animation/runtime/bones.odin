package vfx_animation

import "mirai:core"
import anim "plugins:animation/runtime"
import vfx "plugins:vfx/runtime"

// The bones of the entities a Particle_Binding names, for the bones resources
// of Vfx programs: the pose each shows in the frame without the entity of the
// pose, once the skins are posed.
@(step="render",loops="game editor",after="animation_skin",before="particles_sync")
vfx_animation_bones :: proc(
    bindings:^core.Table(vfx.Particle_Binding,.Read),skins:^core.Table(anim.Pose_Source,.Read),
    playback:core.Ref(anim.Playback),instances:core.Ref(anim.Skin_Instances),bones:^vfx.Particle_Bones,
    time:core.Time,frame:core.Frame_Time,
) {
    if bones==nil || core.count(bindings)==0 && len(bones.entries)==0 {return}
    vfx.bones_begin(bones)
    for row in 0..<core.count(bindings) {
        e:=core.at(bindings,row).entity
        if e==core.NONE {continue}
        world,parents,tick,posed:=anim.animation_shown_pose(playback,instances,skins,e)
        if !posed {continue}
        epoch:=tick if time.playing && time.dt>0 else 0
        dt:=time.dt if epoch!=0 else frame.dt
        given:=vfx.bones_publish(bones,e,world[1:],dt,epoch)
        for &parent,i in given {parent=u32(parents[1+i]-1) if parents[1+i]>=1 else max(u32)}
    }
}
