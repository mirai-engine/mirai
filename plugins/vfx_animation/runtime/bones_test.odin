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
            vfx_animation_bones(core.read(&w.bindings),core.read(&w.skins),core.ref(&w.playback),{},bones,{},{dt=0.5,alpha=1})
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

// When animation_shown_pose falls back to the uninterpolated tick pose, sub-tick
// render frames keep the tick velocity without dropping to zero or spiking on
// tick frames; the render-interpolated Skin_Instances path still uses frame.dt.
@(test)
tick_pose_velocity_is_smooth_across_sub_tick_render_frames :: proc(t:^testing.T) {
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
    state:=anim.Playing{entity=rig,bound=1,seen=1,finished=1,pose_ready=true}
    append(&state.parents,-1,0,1,2)
    for name in names {append(&state.targets,base.name_hash(name));append(&state.aliases,base.name_hash(name))}
    if !testing.expect(t,anim.playing_pose_resize(&state,len(names))) {anim.playing_free(&state);return}
    pose:=anim.playing_pose(&state,.World)
    pose[0]={{0,0,0},1,{1,1,1}}
    pose[1]={{0,1,0},1,{1,1,1}}
    pose[2]={{0,2,0},1,{1,1,1}}
    pose[3]={{0,3,0},1,{1,1,1}}
    append(&w.playback.states,state)
    resize(&w.playback.rows,core.entity_index(rig)+1)
    w.playback.rows[core.entity_index(rig)]=1
    test_world_settle(w)

    state_ptr:=&w.playback.states[0]
    pose=anim.playing_pose(state_ptr,.World)
    TICK :: core.Time{playing=true,dt=1.0/60}
    SUB :: core.Frame_Time{dt=1.0/240,alpha=0.25}

    tracker:mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker,context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    bones:vfx.Particle_Bones
    {
        context.allocator=mem.tracking_allocator(&tracker)
        defer vfx.particle_bones_free(&bones)
        step :: proc(w:^Bones_World,instances:core.Ref(anim.Skin_Instances),bones:^vfx.Particle_Bones) {
            vfx_animation_bones(core.read(&w.bindings),core.read(&w.skins),core.ref(&w.playback),instances,bones,TICK,SUB)
        }
        // Tick 1: initial frame + 3 sub-tick frames at 240 Hz render / 60 Hz tick.
        step(w,{},&bones)
        allocations:=tracker.total_allocation_count
        for _ in 0..<3 {
            step(w,{},&bones)
            given:=vfx.bones_given(&bones,rig)
            testing.expect(t,given!=nil && given.velocity[2]=={})
        }
        // Tick 2: hand moves +0.1 m in 1/60 s => 6 m/s on tick frame AND all sub-tick frames.
        state_ptr.finished=2
        pose[3].position.y+=0.1
        for sub in 0..<4 {
            step(w,{},&bones)
            given:=vfx.bones_given(&bones,rig)
            if testing.expect(t,given!=nil) {
                testing.expectf(t,abs(given.velocity[2].y-6)<1e-4,"tick 2 sub %d: vel %v, want 6",sub,given.velocity[2])
            }
        }
        // Tick 3: steady motion continues without spike.
        state_ptr.finished=3
        pose[3].position.y+=0.1
        for sub in 0..<2 {
            step(w,{},&bones)
            given:=vfx.bones_given(&bones,rig)
            if testing.expect(t,given!=nil) {
                testing.expectf(t,abs(given.velocity[2].y-6)<1e-4,"tick 3 sub %d: vel %v, want 6",sub,given.velocity[2])
            }
        }
        // Tick 5 (2 ticks elapsed, e.g. LOD skip): +0.2 m over 2/60 s => still 6 m/s.
        state_ptr.finished=5
        pose[3].position.y+=0.2
        step(w,{},&bones)
        if given:=vfx.bones_given(&bones,rig);testing.expect(t,given!=nil) {
            testing.expectf(t,abs(given.velocity[2].y-6)<1e-4,"lod skip: vel %v, want 6",given.velocity[2])
        }
        // Tick 6: rig stops moving => velocity returns cleanly to zero.
        state_ptr.finished=6
        step(w,{},&bones)
        if given:=vfx.bones_given(&bones,rig);testing.expect(t,given!=nil) {
            testing.expect_value(t,given.velocity[2],[3]f32{})
        }
        testing.expect_value(t,tracker.total_allocation_count,allocations)

        // Render-interpolated Skin_Instances path uses frame.dt (SUB.dt = 1/240).
        instances:anim.Skin_Instances
        defer core.entity_map_destroy(&instances.instances)
        drawn_pose:[4]mm.Transform
        copy(drawn_pose[:],pose)
        instances.frame=1
        if _,kept:=core.entity_map_put(&instances.instances,rig,anim.Skin_Instance{pose=rig,copied=true,seen=1,world=drawn_pose[:]});!testing.expect(t,kept) {return}
        // First interpolated frame after tick-pose mode resets cleanly to zero.
        step(w,core.ref(&instances),&bones)
        if given:=vfx.bones_given(&bones,rig);testing.expect(t,given!=nil) {
            testing.expect_value(t,given.velocity[2],[3]f32{})
        }
        instances.frame=2
        instances.instances.values[0].seen=2
        drawn_pose[3].position.y+=0.025 // 0.025 m / (1/240 s) = 6 m/s
        step(w,core.ref(&instances),&bones)
        if given:=vfx.bones_given(&bones,rig);testing.expect(t,given!=nil) {
            testing.expectf(t,abs(given.velocity[2].y-6)<1e-4,"interpolated: vel %v, want 6",given.velocity[2])
        }
    }
    testing.expect_value(t,len(tracker.allocation_map),0)
}
