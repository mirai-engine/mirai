package vfx_animation

import "core:mem"
import "core:testing"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import vfx "plugins:vfx/runtime"

@(private)
@(test_world)
Bones_World :: struct {
    using world:Test_World,
    bindings:core.Table(vfx.Particle_Binding),
    skins:core.Table(anim.Pose_Source),
    playback:anim.Playback,
}

// The bones of a rig an emitter binds are its pose in the world without the
// entity of the pose, with their parents among them and how fast each moved
// since the frame before; a frame like the one before allocates nothing.
@(test)
the_bones_of_a_bound_rig_are_its_pose_in_the_world_with_their_velocity :: proc(t:^testing.T) {
    w:=new(Bones_World)
    defer free(w)
    if !test_world_init(t,w) {return}
    defer test_world_destroy(w)
    rig:=core.create(&w.entities)
    emitter:=core.create(&w.entities)
    binding:=vfx.Particle_Binding{entity=rig}
    base.text_set(binding.resource[:],"body")
    core.add(&w.bindings,emitter,binding)
    names:=[]string{"rig","root","spine","hand"}
    state:=anim.Playing{entity=rig,bound=1,seen=1,pose_ready=true}
    append(&state.parents,-1,0,1,2)
    for name in names {append(&state.targets,base.name_hash(name));append(&state.aliases,base.name_hash(name))}
    if !testing.expect(t,anim.playing_pose_resize(&state,len(names))) {anim.playing_free(&state);return}
    pose:=anim.playing_pose(&state,.World)
    pose[0]={{5,0,0},1,{1,1,1}}
    pose[1]={{5,1,0},1,{1,1,1}}
    pose[2]={{5,2,0},mm.quat_axis_angle({0,0,1},0.5),{1,1,1}}
    pose[3]={{6,3,0},1,{2,2,2}}
    append(&w.playback.states,state)
    resize(&w.playback.rows,core.entity_index(rig)+1)
    w.playback.rows[core.entity_index(rig)]=1
    test_world_settle(w)

    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    bones:vfx.Particle_Bones
    {
        context.allocator=mem.tracking_allocator(&tracker)
        defer vfx.particle_bones_free(&bones)
        step :: proc(w:^Bones_World,bones:^vfx.Particle_Bones) {
            vfx_animation_bones(core.read(&w.bindings),core.read(&w.skins),core.ref(&w.playback),{},bones,{dt=0.5,alpha=1})
        }
        step(w,&bones)
        first:=vfx.bones_given(&bones,rig)
        if !testing.expect(t,first!=nil && len(first.world)==3) {return}
        testing.expect_value(t,first.velocity[2],[3]f32{})
        allocations:=tracker.total_allocation_count
        pose[3].position.y+=2
        step(w,&bones)
        testing.expect_value(t,tracker.total_allocation_count,allocations)
        given:=vfx.bones_given(&bones,rig)
        if !testing.expect(t,given!=nil && len(given.world)==3) {return}
        for name,i in names[1:] {
            expected,found:=anim.animation_bone_transform(core.ref(&w.playback),rig,anim.bone_ref(name))
            testing.expectf(t,found && given.world[i]==expected,"%s: %v, not %v",name,given.world[i],expected)
        }
        testing.expect_value(t,[3]u32{given.parents[0],given.parents[1],given.parents[2]},[3]u32{max(u32),0,1})
        testing.expect_value(t,given.velocity[0],[3]f32{})
        testing.expectf(t,abs(given.velocity[2].y-4)<1e-5 && given.velocity[2].x==0 && given.velocity[2].z==0,"the hand moves at %v",given.velocity[2])
        // Not bound any more: its bones go after two frames.
        core.remove(&w.bindings,emitter)
        test_world_settle(w)
        for _ in 0..<3 {step(w,&bones)}
        testing.expect_value(t,len(bones.entries),0)
    }
    testing.expect_value(t,len(tracker.allocation_map),0)
}
