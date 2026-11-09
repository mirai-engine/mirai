package game

import "base:runtime"
import "core:fmt"
import cmath "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

when #config(MIRAI_AVATAR_TEST,false) {
    @(test)
    imported_mirai_avatar_walk_and_land_preserve_contact_phases_and_animated_foot_roll_on_slopes :: proc(t:^testing.T) {
        mirai_avatar_grounding_case(t,"walk",.35)
        mirai_avatar_grounding_case(t,"walk",.35,2.9154)
        mirai_avatar_grounding_case(t,"land",.5)
    }

    @(private="file")
    mirai_avatar_grounding_case :: proc(t:^testing.T,clip_name:string,max_drop:f32,speed:f32=1) {
        f:Grounding_Fixture;grounding_fixture_init(&f,t,0.12);defer grounding_fixture_free(&f)
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        skeleton_file,animation_file:asset.Asset
        defer asset.asset_close(&skeleton_file);defer asset.asset_close(&animation_file)
        if !testing.expect_value(t,asset.asset_load(&skeleton_file,"demo/assets/characters/mirai/Armature.skeleton"),asset.Error.None) {return}
        if !testing.expect_value(t,asset.asset_load(&animation_file,"demo/assets/characters/mirai/mirai_locomotion.anim"),asset.Error.None) {return}
        skeleton_view,skeleton_error:=asset.skeleton_view(&skeleton_file,&types)
        animation_view,animation_error:=asset.animation_view(&animation_file,&types)
        if !testing.expect(t,skeleton_error==.None && animation_error==.None) {return}
        library:lib.Library;defer lib.library_destroy(&library)
        if !testing.expect(t,lib.library_init(&library,asset.animation_library_desc(animation_view))) {return}
        if !testing.expect(t,asset.animation_clips_add(animation_view,&library,.Loop)!=0) {return}
        clip:=lib.clip_find(&library,base.name_hash(clip_name))
        if !testing.expect(t,clip!=0) {return}
        anim.playing_free(&f.state);f.state.entity=f.rig
        playback:anim.Playback;defer anim.playback_free(&playback)
        definition:=anim.Skeleton_Content{id=skeleton_file.blob.header.id,revision=1,bones=skeleton_view.bones}
        if !testing.expect(t,anim.skeleton_bind(&playback,&f.state,&definition,nil,&f.transforms)) {return}
        skeleton:=anim.playing_skeleton(&f.state)
        tracks:=make([]lib.Bone_Tracks,len(f.state.local));defer delete(tracks)
        if !testing.expect(t,lib.skeleton_bind(&library,clip,skeleton,tracks)) {return}
        lib.skeleton_world(skeleton,f.state.rest[:],f.state.world[:])
        config:=anim.FOOT_GROUNDING_DEFAULT;config.count=2;config.body=anim.bone_ref("Hips")
        config.max_drop=max_drop;config.max_rise=.15;config.trace_above=.55;config.trace_below=.9
        for side,i in ([]string{"Left","Right"}) {
            leg:=anim.GROUNDED_LEG_DEFAULT;leg.hip=anim.bone_ref(fmt.tprintf("%sUpLeg",side));leg.knee=anim.bone_ref(fmt.tprintf("%sLeg",side));leg.foot=anim.bone_ref(fmt.tprintf("%sFoot",side))
            leg.pole_offset={};leg.max_distance=.55;leg.contact_height=.04;leg.plant_speed=.6
            leg.contact_bone=anim.bone_ref(fmt.tprintf("%sToeBase",side))
            foot:=anim.bone_resolve(&f.state,leg.foot)
            leg.foot_up=mm.quat_rotate(conj(f.state.world[foot].rotation),{0,1,0})
            leg.sole_height=max(0,f.state.world[foot].position.y)
            leg.contact_offset=max(0,f.state.world[anim.bone_resolve(&f.state,leg.contact_bone)].position.y)
            config.legs[i]=leg
        }
        core.get(&f.configs,f.rig)^=config
        maximum,normal_error,pitch_error,stance_drift:f32;samples:=0
        swings:[2]int
        last_probe:[2]mm.Vec3
        last_locked:[2]bool
        terrain_normal:=mm.quat_rotate(mm.quat_axis_angle({0,0,1},.12),{0,1,0})
        for frame in 0..<720 {
            age:=f32(frame)/60
            time:=cmath.mod(age*speed/(2.9154 if clip_name=="walk" else f32(1)),lib.clip_duration(&library,clip))
            testing.expect(t,lib.skeleton_sample(&library,tracks,f.state.rest[:],time,f.state.local[:]))
            phase:=cmath.mod(age*speed,f32(4));x:=phase-1 if phase<2 else 3-phase
            if clip_name=="land" {x=0}
            f.state.local[0].position={x,x*.120579,0}
            f.state.local[0].rotation=mm.quat_axis_angle({0,1,0},-mm.PI*.5 if phase<2 else mm.PI*.5)
            lib.skeleton_world(skeleton,f.state.local[:],f.state.world[:])
            before:[2]mm.Transform
            probes:[2]mm.Vec3
            for i in 0..<2 {
                before[i]=f.state.world[anim.bone_resolve(&f.state,config.legs[i].foot)]
                probes[i]=f.state.world[anim.bone_resolve(&f.state,anim.bone_ref("LeftToeBase" if i==0 else "RightToeBase"))].position
            }
            testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
            record:=&f.cache.records[0]
            for target,i in record.targets[:record.count] {
                foot:=record.bones[i][2]
                contact:=f.state.world[record.contact_bones[i]].position
                raw_clearance:=probes[i].y-f.state.local[0].position.y-config.legs[i].contact_offset
                solved_clearance:=linalg.dot(contact,terrain_normal)-config.legs[i].contact_offset
                if raw_clearance>.06 {
                    swings[i]+=1
                    testing.expect(t,!record.placements[i].anchor.active)
                    testing.expectf(t,solved_clearance>.02,"frame %d leg %d source %.4f solved %.4f",frame,i,raw_clearance,solved_clearance)
                }
                raw_up:=mm.quat_rotate(before[i].rotation,config.legs[i].foot_up)
                solved_up:=mm.quat_rotate(f.state.world[foot].rotation,config.legs[i].foot_up)
                aligned_up:=mm.quat_rotate(mm.quat_slerp(mm.QUAT_IDENTITY,record.alignment[i].turn,target.weight),{0,1,0})
                pitch_error=max(pitch_error,abs(linalg.dot(raw_up,{0,1,0})-linalg.dot(solved_up,aligned_up)))
                locked:=record.placements[i].anchor.active && record.placements[i].weight>=.99
                if locked && last_locked[i] {
                    delta:=contact-last_probe[i];delta-=terrain_normal*linalg.dot(delta,terrain_normal)
                    stance_drift=max(stance_drift,linalg.length(delta))
                }
                last_probe[i],last_locked[i]=contact,locked
                when #config(MIRAI_AVATAR_TRACE,false) {
                    if clip_name=="walk" && speed==1 && frame<120 {
                        fmt.printf("PHASE,%d,%.5f,%d,%.5f,%.5f,%.5f,%.5f,%.5f,%v,%.3f,%.5f,%.5f\n",frame,time,i,before[i].position.x-f.state.local[0].position.x,before[i].position.y-f.state.local[0].position.y,probes[i].x-f.state.local[0].position.x,probes[i].y-f.state.local[0].position.y,f.state.world[foot].position.y-f.state.local[0].position.y,record.placements[i].anchor.active,target.weight,linalg.dot(mm.quat_rotate(before[i].rotation,config.legs[i].foot_up),{0,1,0}),linalg.dot(mm.quat_rotate(f.state.world[foot].rotation,config.legs[i].foot_up),{0,1,0}))
                    }
                }
                if target.weight<.99 || !record.placements[i].anchor.active || record.placements[i].weight<.99 {continue}
                samples+=1
                hip,knee:=record.bones[i][0],record.bones[i][1]
                residual:=linalg.length(f.state.world[foot].position-target.position)
                if residual>maximum+.02 {
                    length:=linalg.length(f.state.world[knee].position-f.state.world[hip].position)+linalg.length(f.state.world[foot].position-f.state.world[knee].position)
                    fmt.eprintf("Mirai %s frame=%d leg=%d error=%.5f distance=%.5f length=%.5f pelvis=%v\n",clip_name,frame,i,residual,linalg.length(target.position-f.state.world[hip].position),length,record.body_offset)
                }
                maximum=max(maximum,residual)
                normal_error=max(normal_error,mm.quat_angle(f.state.world[foot].rotation,record.rotations[i]))
            }
        }
        fmt.eprintf("Mirai CPU %s speed=%.4f samples=%d max=%.6f rotation=%.6f pitch=%.6f drift=%.6f swing=%v\n",clip_name,speed,samples,maximum,normal_error,pitch_error,stance_drift,swings)
        testing.expect(t,samples>100 && maximum<.02 && normal_error<.005 && pitch_error<.002 && stance_drift<.003)
        if clip_name=="walk" {testing.expect(t,swings[0]>30 && swings[1]>30)}
    }
}

@(private)
Grounding_Fixture :: struct {
    entities:core.Entities,
    rig:core.Entity,
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    configs:core.Table(anim.Foot_Grounding),
    state:anim.Playing,
    physics:phys.Physics_State,
    cache:anim.Grounding_Runtime,
    platform:sim.Body_Handle,
    problems:core.Problems,
}

@(private)
grounding_fixture_init :: proc(f:^Grounding_Fixture,t:^testing.T,angle:f32=0.2) {
    core.entities_init(&f.entities)
    f.rig=core.create(&f.entities)
    f.state.entity=f.rig;f.state.bound=1
    core.add(&f.transforms,f.rig,core.TRANSFORM_IDENTITY)
    core.table_settle(&f.transforms,&f.entities)
    parents:=[8]i32{-1,0,1,2,3,1,5,6}
    names:=[8]string{"","body","hip.l","knee.l","foot.l","hip.r","knee.r","foot.r"}
    positions:=[8]mm.Vec3{{},{0,1.7,0},{-0.3,0,0},{0,-0.8,-0.1},{0,-0.8,0.1},{0.3,0,0},{0,-0.8,-0.1},{0,-0.8,0.1}}
    for parent,i in parents {
        reference:=mm.Transform{positions[i],1,{1,1,1}}
        append(&f.state.parents,parent)
        append(&f.state.targets,base.name_hash(names[i]) if i>0 else u64(0))
        append(&f.state.rest,reference);append(&f.state.local,reference)
        append(&f.state.world,reference)
    }
    config:=anim.FOOT_GROUNDING_DEFAULT
    config.count=2;config.body=anim.bone_ref("body");config.blend_time=0;config.max_swinging=1
    for i in 0..<2 {
        config.legs[i]=anim.GROUNDED_LEG_DEFAULT
        config.legs[i].sole_height=.1
        config.legs[i].hip=anim.bone_ref(names[2+i*3]);config.legs[i].knee=anim.bone_ref(names[3+i*3]);config.legs[i].foot=anim.bone_ref(names[4+i*3])
        config.legs[i].phase=f32(i)*0.5
        config.legs[i].pole_offset={0,0,-1}
    }
    core.add(&f.configs,f.rig,config);core.table_settle(&f.configs,&f.entities)
    testing.expect(t,sim.world_init(&f.physics.world,{body_capacity=8,shape_capacity=8,contact_capacity=32,joint_capacity=0}))
    f.physics.ready=true
    rotation:=mm.quat_axis_angle({0,0,1},angle)
    f.platform=sim.body_create(&f.physics.world,{type=.Kinematic,position=-mm.quat_rotate(rotation,{0,0.5,0}),rotation=rotation})
    desc:=sim.SHAPE_DESC_DEFAULT;desc.geometry=sim.Box{{5,0.5,5}}
    testing.expect(t,sim.shape_create(&f.physics.world,f.platform,desc)!=0)
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
}

@(private)
grounding_fixture_free :: proc(f:^Grounding_Fixture) {
    anim.grounding_free(&f.cache);anim.playing_free(&f.state)
    phys.state_destroy(&f.physics)
    core.table_destroy(&f.transforms);core.table_destroy(&f.parents);core.table_destroy(&f.configs)
    core.entities_destroy(&f.entities)
}

@(private)
grounding_fixture_inputs :: proc(f:^Grounding_Fixture) -> anim.Grounding_Inputs {
    return {core.read(&f.configs),grounding_fixture_ground(f),core.read(&f.transforms),core.read(&f.parents),0,&f.problems,{}}
}

@(private)
grounding_fixture_ground :: proc(f:^Grounding_Fixture) -> core.World_Query {
    ground,_:=phys.query_of(&f.physics)
    return ground
}

@(test)
grounding_keeps_procedural_swing_and_animated_heels_above_raised_geometry :: proc(t:^testing.T) {
    for mode in ([2]anim.Grounding_Mode{.Procedural,.Animated}) {
        f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
        config:=core.get(&f.configs,f.rig);config.count=1;config.mode=mode;config.adjust_body=false
        config.legs[0].step_distance=.05;config.legs[0].max_distance=2
        obstacle:=sim.body_create(&f.physics.world,{type=.Static,position={.3,.15,0}})
        desc:=sim.SHAPE_DESC_DEFAULT;desc.geometry=sim.Box{{.5,.15,1}}
        testing.expect(t,sim.shape_create(&f.physics.world,obstacle,desc)!=0)
        source:[9]mm.Transform
        saved:anim.Grounding_Record
        if mode==.Animated {
            pose:=mm.Transform{{-.4,0,0},1,{1,1,1}}
            append(&f.state.parents,i32(4));append(&f.state.targets,base.name_hash("ball.l"))
            append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
            config.legs[0].contact_bone=anim.bone_ref("ball.l");config.legs[0].contact_offset=.1
            f.state.local[0].position.x=.3
            testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
            testing.expect(t,anim.grounding_prepare(&f.cache,core.read(&f.configs),nil))
            copy(source[:],f.state.local[:]);saved=f.cache.records[0]
            testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        } else {
            testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
            leg:=&f.cache.records[0].legs[0]
            leg.from,leg.from_normal=leg.anchor.position,leg.anchor.normal
            testing.expect(t,lib.surface_anchor_set(&leg.landing,{position={.4,.4,0},normal={0,1,0},valid=true}))
            leg.swinging=true;leg.elapsed=.05
            copy(f.state.local[:],f.state.rest[:])
            testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
            copy(source[:],f.state.local[:]);saved=f.cache.records[0]
            testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),0))
        }
        record:=&f.cache.records[0]
        foot:=f.state.world[4]
        testing.expect(t,record.targets[0].position.x>=-.2 && record.targets[0].position.x<.8)
        testing.expect(t,foot.position.y>=.4-.001)
        testing.expect(t,mm.quat_angle(foot.rotation,mm.QUAT_IDENTITY)<.001)
        expected:=record^
        copy(f.state.local[:],source[:]);f.cache.records[0]=saved
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        previous_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
        applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1 if mode==.Animated else f32(0))
        context=previous_context
        testing.expect(t,applied)
        testing.expect_value(t,f.cache.records[0],expected)
        testing.expect_value(t,f.state.world[4],foot)
        testing.expect_value(t,f.problems.count,0)
    }
}

@(test)
grounding_checks_the_planted_ball_target_when_new_geometry_covers_its_support :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    config:=core.get(&f.configs,f.rig);config.count=1;config.adjust_body=false
    pose:=mm.Transform{{.4,0,0},1,{1,1,1}}
    append(&f.state.parents,i32(4));append(&f.state.targets,base.name_hash("ball.l"))
    append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
    config.legs[0].contact_bone=anim.bone_ref("ball.l");config.legs[0].contact_offset=.1
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    testing.expect(t,f.cache.records[0].placements[0].anchor.active)
    obstacle:=sim.body_create(&f.physics.world,{type=.Kinematic,position={.2,.15,0}})
    desc:=sim.SHAPE_DESC_DEFAULT;desc.geometry=sim.Box{{.2,.15,1}}
    testing.expect(t,sim.shape_create(&f.physics.world,obstacle,desc)!=0)
    copy(f.state.local[:],f.state.rest[:])
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    saved:=f.cache.records[0]
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    ball:=f.state.world[8]
    testing.expect(t,ball.position.y>=.4-.001)
    testing.expect(t,f.cache.records[0].placements[0].anchor.active)
    expected:=f.cache.records[0]
    copy(f.state.local[:],f.state.rest[:]);f.cache.records[0]=saved
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    previous_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1)
    context=previous_context
    testing.expect(t,applied)
    testing.expect_value(t,f.cache.records[0],expected)
    testing.expect_value(t,f.state.world[8],ball)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_replants_all_four_blocked_spider_shins_on_the_real_step_without_stretching :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    obstacle:=grounding_spider_step_fixture(&f,t)
    before:[26]mm.Transform;copy(before[:],f.state.world[:])
    source:[26]mm.Transform;copy(source[:],f.state.local[:])
    testing.expect(t,anim.grounding_prepare(&f.cache,core.read(&f.configs),nil))
    saved:=f.cache.records[0]
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    record:=&f.cache.records[0]
    for i in 0..<8 {
        hip,knee,foot:=record.bones[i][0],record.bones[i][1],record.bones[i][2]
        testing.expect(t,linalg.length(f.state.world[foot].position-record.targets[i].position)<.001)
        testing.expect(t,abs(linalg.length(f.state.world[knee].position-f.state.world[hip].position)-linalg.length(before[knee].position-before[hip].position))<.0001)
        testing.expect(t,abs(linalg.length(f.state.world[foot].position-f.state.world[knee].position)-linalg.length(before[foot].position-before[knee].position))<.0001)
        if i<4 {testing.expect(t,linalg.length(f.state.world[foot].position-before[foot].position)<.001);continue}
        testing.expect(t,record.legs[i].anchor.active && record.legs[i].anchor.support==u64(obstacle))
        testing.expect(t,f.state.world[foot].position.y>=.19-.001)
        for segment in ([2][2]int{{hip,knee},{knee,foot}}) {
            origin:=f.state.world[segment[0]].position
            delta:=f.state.world[segment[1]].position-origin
            hit,found:=phys.raycast(core.ref(&f.physics),origin,delta,linalg.length(delta))
            testing.expect(t,!found || hit.distance>=linalg.length(delta)-.0001)
        }
    }
    testing.expect_value(t,record.blocked,u16(0))
    expected:=record^
    expected_pose:[26]mm.Transform;copy(expected_pose[:],f.state.world[:])
    copy(f.state.local[:],source[:]);record^=saved
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    previous_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1)
    context=previous_context
    testing.expect(t,applied)
    testing.expect_value(t,record^,expected)
    for pose,i in expected_pose {testing.expect_value(t,f.state.world[i],pose)}
    sim.body_set_transform(&f.physics.world,obstacle,{.6,.16,0},1)
    copy(f.state.local[:],source[:]);lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    for i in 4..<8 {
        testing.expect_value(t,record.legs[i].anchor.support,u64(obstacle))
        testing.expect(t,linalg.length(record.legs[i].anchor.position-expected.legs[i].anchor.position-mm.Vec3{.1,.1,0})<.0001)
        foot:=record.bones[i][2]
        testing.expect(t,linalg.length(f.state.world[foot].position-record.targets[i].position)<.001)
    }
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_corrects_released_procedural_reference_clearance_without_restoring_contact :: proc(t:^testing.T) {
    for variant in 0..<4 {
        f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
        config:=core.get(&f.configs,f.rig);config.mode=.Procedural;config.count=1;config.adjust_body=false;config.blend_time=.1
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        record:=&f.cache.records[0]
        record.legs[0].anchor.active=false;record.legs[0].swinging=false
        record.legs[0].weight=f32(1.0/60)/config.blend_time
        if variant==1 {config.weight=0}
        if variant==2 {config.global_contact=0}
        if variant==3 {config.legs[0].contact=0}
        copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.y=-.2
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        source,source_world:[8]mm.Transform;copy(source[:],f.state.local[:]);copy(source_world[:],f.state.world[:]);saved:=record^
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
        foot:=record.bones[0][2]
        testing.expect(t,record.legs[0].weight==0 && !record.legs[0].anchor.active && !record.legs[0].swinging)
        testing.expect_value(t,record.gait,saved.gait)
        if variant==0 {
            testing.expect(t,record.targets[0].weight==1 && f.state.world[foot].position.y>=.1-.001)
            bones:=record.bones[0]
            _,blocked:=anim.grounding_limb_hit(grounding_fixture_ground(&f),f.state.world[bones[0]].position,f.state.world[bones[1]].position,f.state.world[bones[2]].position)
            testing.expect(t,!blocked)
        } else {
            testing.expect_value(t,record.targets[0].weight,f32(0))
            for pose,i in source_world {testing.expect_value(t,f.state.world[i],pose)}
        }
        expected:=record^;pose:[8]mm.Transform;copy(pose[:],f.state.world[:])
        copy(f.state.local[:],source[:]);record^=saved
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        previous:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
        applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60)
        context=previous
        testing.expect(t,applied);testing.expect_value(t,record^,expected)
        for transform,i in pose {testing.expect_value(t,f.state.world[i],transform)}
        testing.expect_value(t,f.problems.count,0)
    }
}

@(test)
grounding_changes_only_the_knee_plane_for_the_spider_step_corner :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    _=grounding_spider_step_fixture(&f,t)
    root:=mm.Transform{{-.29162979,-.050069,0},mm.quat_axis_angle({0,1,0},-mm.PI*.5),{1,1,1}}
    f.state.local[0]=root
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    record:=&f.cache.records[0]
    support:=sim.body_transform(&f.physics.world,f.platform)
    contact:=lib.Surface_Contact{position={.29837227,-.02000001,-.9199996},normal={0,1,0},support=u64(f.platform),support_transform={support.p,support.q,{1,1,1}},valid=true}
    testing.expect(t,lib.surface_anchor_set(&record.legs[0].anchor,contact))
    record.body_offset={0,.00005425,0};record.body_turn=mm.QUAT_IDENTITY
    copy(f.state.local[:],f.state.rest[:]);f.state.local[0]=root
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    hip,knee,foot:=record.bones[0][0],record.bones[0][1],record.bones[0][2]
    points:=[3]mm.Transform{f.state.world[hip],f.state.world[knee],f.state.world[foot]}
    pole:=points[1].position+mm.quat_rotate(root.rotation,core.get(&f.configs,f.rig).legs[0].pole_offset)
    for &point in points {point.position+=record.body_offset}
    original,ok:=lib.two_bone_ik(points[0],points[1],points[2],contact.position,pole)
    testing.expect(t,ok && original.reached)
    hit,blocked:=anim.grounding_limb_hit(grounding_fixture_ground(&f),original.root.position,original.joint.position,original.end.position)
    testing.expect(t,blocked && hit.normal.x<-.99 && hit.point.y<.16)
    source:[26]mm.Transform;copy(source[:],f.state.local[:]);saved:=record^
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
    _,blocked=anim.grounding_limb_hit(grounding_fixture_ground(&f),f.state.world[hip].position,f.state.world[knee].position,f.state.world[foot].position)
    testing.expect(t,!blocked && record.blocked&1==0)
    testing.expect(t,linalg.length(record.targets[0].position-contact.position)<.0001)
    testing.expect(t,record.legs[0].anchor.active && record.legs[0].anchor.support==u64(f.platform) && !record.legs[0].swinging)
    testing.expect(t,linalg.length(record.legs[0].anchor.position-contact.position)<.0001)
    testing.expect(t,linalg.length(f.state.world[foot].position-record.targets[0].position)<.001)
    testing.expect(t,abs(linalg.length(f.state.world[knee].position-f.state.world[hip].position)-linalg.length(f.state.rest[knee].position))<.0001)
    testing.expect(t,abs(linalg.length(f.state.world[foot].position-f.state.world[knee].position)-linalg.length(f.state.rest[foot].position))<.0001)
    expected:=record^;pose:[26]mm.Transform;copy(pose[:],f.state.world[:])
    copy(f.state.local[:],source[:]);record^=saved
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    previous:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60)
    context=previous
    testing.expect(t,applied);testing.expect_value(t,record^,expected)
    for transform,i in pose {testing.expect_value(t,f.state.world[i],transform)}
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_procedural_turn_release_keeps_final_segments_above_the_floor :: proc(t:^testing.T) {
    blocked_samples,releases:=0,0
    startup:=[10]mm.Vec3{{.0005,-.0017031431,0},{.0015,-.0061312914,0},{.0030003,-.013284415,0},{.005,-.023162544,0},{.0075,-.035765678,0},{.0105,-.051093817,0},{.0151668,-.05092722,0},{.0215,-.05070898,0},{.0295,-.05054623,0},{.0391665,-.050424874,0}}
    for variant in 0..<2 {
        f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
        _=grounding_spider_step_fixture(&f,t)
        testing.expect(t,anim.grounding_prepare(&f.cache,core.read(&f.configs),nil))
        for frame in 0..<(len(startup) if variant==0 else 80) {
            copy(f.state.local[:],f.state.rest[:])
            turn:=min(max(frame-30,0),20)
            f.state.local[0]={{1.172305-f32(turn)*.016667,-.050069,0},mm.quat_axis_angle({0,1,0},-mm.PI*.5-f32(turn)*9*mm.RAD_PER_DEG),{1,1,1}}
            if variant==0 {
                f.state.local[0]={startup[frame],mm.quat_axis_angle({0,1,0},f32(frame+1)*9*mm.RAD_PER_DEG),{1,1,1}}
                core.get(&f.configs,f.rig).global_contact=0 if frame<6 else 1
            }
            testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
            source:[26]mm.Transform;copy(source[:],f.state.local[:]);before:=f.cache.records[0]
            testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
            record:=&f.cache.records[0]
            swinging:=0
            for target,i in record.targets[:8] {
                if record.legs[i].swinging {swinging+=1}
                if (variant==1 && frame<30) || target.weight<=0 {continue}
                if !record.legs[i].anchor.active {releases+=1}
                bones:=record.bones[i]
                _,blocked:=anim.grounding_limb_hit(grounding_fixture_ground(&f),f.state.world[bones[0]].position,f.state.world[bones[1]].position,f.state.world[bones[2]].position)
                if blocked {blocked_samples+=1}
            }
            testing.expect(t,swinging<=4)
            expected:=record^;pose:[26]mm.Transform;copy(pose[:],f.state.world[:])
            copy(f.state.local[:],source[:]);record^=before
            testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
            previous:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            replayed:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60)
            context=previous
            testing.expect(t,replayed);testing.expect_value(t,record^,expected)
            for transform,i in pose {testing.expect_value(t,f.state.world[i],transform)}
        }
        testing.expect_value(t,f.problems.count,0)
    }
    fmt.eprintf("Spider turn blocked=%d releases=%d\n",blocked_samples,releases)
    testing.expect(t,releases>0 && blocked_samples==0)
}

@(test)
grounding_replants_unreachable_spider_stance_during_step_descent_without_stretching :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    _=grounding_spider_step_fixture(&f,t)
    root:=mm.Transform{{.124236,.09238827,0},mm.quat_axis_angle({0,1,0},mm.PI*.5),{1,1,1}}
    f.state.local[0]=root
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
    record:=&f.cache.records[0]
    support:=sim.body_transform(&f.physics.world,f.platform)
    old:=lib.Surface_Contact{position={1.463966,-.02,-.92},normal={0,1,0},support=u64(f.platform),support_transform={support.p,support.q,{1,1,1}},valid=true}
    testing.expect(t,lib.surface_anchor_set(&record.legs[7].anchor,old))
    record.legs[7].swinging=false;record.legs[7].weight=1;record.gait.phase=.5
    record.body_offset={0,-.25,0};record.body_turn=mm.QUAT_IDENTITY
    record.root_position=root.position-mm.Vec3{-.69115,0,0}/60
    copy(f.state.local[:],f.state.rest[:]);f.state.local[0]=root
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    source:[26]mm.Transform;copy(source[:],f.state.local[:])
    saved:=record^
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
    hip,knee,foot:=record.bones[7][0],record.bones[7][1],record.bones[7][2]
    residual:=linalg.length(f.state.world[foot].position-record.targets[7].position)
    fmt.eprintf("Spider descent residual=%.6f anchor=%v body=%v\n",residual,record.legs[7].anchor.position,record.body_offset)
    testing.expect(t,residual<.001)
    testing.expect(t,record.legs[7].anchor.active && !record.legs[7].swinging && record.targets[7].weight==1)
    testing.expect(t,record.legs[7].anchor.support==u64(f.platform))
    testing.expect(t,linalg.length(record.legs[7].anchor.position-old.position)>.05 && linalg.length(record.legs[7].anchor.position-old.position)<.2)
    testing.expect(t,abs(record.legs[7].anchor.position.y+.02)<.0001)
    testing.expect(t,abs(linalg.length(f.state.world[knee].position-f.state.world[hip].position)-linalg.length(f.state.rest[knee].position))<.0001)
    testing.expect(t,abs(linalg.length(f.state.world[foot].position-f.state.world[knee].position)-linalg.length(f.state.rest[foot].position))<.0001)
    testing.expect(t,record.body_offset.y>=-.25001 && record.body_offset.y<=.25001)
    expected:=record^;pose:[26]mm.Transform;copy(pose[:],f.state.world[:])
    copy(f.state.local[:],source[:]);record^=saved
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    previous:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60)
    context=previous
    testing.expect(t,applied);testing.expect_value(t,record^,expected)
    for transform,i in pose {testing.expect_value(t,f.state.world[i],transform)}
    sim.body_set_transform(&f.physics.world,f.platform,{.01,-.54,0},1)
    copy(f.state.local[:],source[:]);lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
    testing.expect_value(t,record.legs[7].anchor.support,u64(f.platform))
    testing.expect(t,linalg.length(record.legs[7].anchor.position-expected.legs[7].anchor.position-mm.Vec3{.01,.01,0})<.0001)
    testing.expect(t,linalg.length(f.state.world[foot].position-record.targets[7].position)<.001)
    sim.body_set_transform(&f.physics.world,f.platform,{0,-.55,0},1)
    wall:=sim.body_create(&f.physics.world,{type=.Static,position={1.1,.5,-.92}})
    desc:=sim.SHAPE_DESC_DEFAULT;desc.geometry=sim.Box{{.3,.5,.1}}
    testing.expect(t,sim.shape_create(&f.physics.world,wall,desc)!=0)
    copy(f.state.local[:],source[:]);record^=saved
    lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
    testing.expect(t,linalg.length(f.state.world[foot].position-record.targets[7].position)>.02)
    testing.expect(t,linalg.length(record.legs[7].anchor.position-old.position)<.0001)
    testing.expect(t,record.targets[7].weight==1 && record.blocked&128!=0)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_preserves_animated_targets_and_reports_unwalkable_procedural_obstacles :: proc(t:^testing.T) {
    for mode in ([2]anim.Grounding_Mode{.Animated,.Procedural}) {
        f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
        _=grounding_spider_step_fixture(&f,t)
        core.get(&f.configs,f.rig).mode=mode
        if mode==.Procedural {
            wall:=sim.body_create(&f.physics.world,{type=.Static,position={.65,.5,0}})
            desc:=sim.SHAPE_DESC_DEFAULT;desc.geometry=sim.Box{{.025,.5,.85}}
            testing.expect(t,sim.shape_create(&f.physics.world,wall,desc)!=0)
        }
        before:[26]mm.Transform;copy(before[:],f.state.world[:])
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        record:=&f.cache.records[0]
        for i in 4..<8 {
            hip,knee,foot:=record.bones[i][0],record.bones[i][1],record.bones[i][2]
            testing.expect(t,linalg.length(record.targets[i].position-before[foot].position)<.001)
            testing.expect(t,linalg.length(f.state.world[foot].position-record.targets[i].position)<.001)
            _,blocked:=anim.grounding_limb_hit(grounding_fixture_ground(&f),f.state.world[hip].position,f.state.world[knee].position,f.state.world[foot].position)
            testing.expect(t,blocked)
        }
        testing.expect_value(t,record.blocked,u16(0xf0) if mode==.Procedural else u16(0))
        testing.expect_value(t,f.problems.count,0)
    }
}

@(private)
grounding_spider_step_fixture :: proc(f:^Grounding_Fixture,t:^testing.T) -> sim.Body_Handle {
    anim.playing_free(&f.state);f.state={entity=f.rig,bound=1}
    for i in 0..<2 {
        pose:=mm.TRANSFORM_IDENTITY;if i==1 {pose.position.y=.6}
        append(&f.state.parents,i32(i)-1);append(&f.state.targets,base.name_hash("body") if i==1 else u64(0))
        append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
    }
    config:=anim.FOOT_GROUNDING_DEFAULT;config.count=8;config.mode=.Procedural;config.body=anim.bone_ref("body")
    config.cycle_duration=.6;config.prediction=.12;config.body_height=.57;config.trace_above=.6;config.trace_below=1.2
    config.max_swinging=4;config.max_drop,config.max_rise=.25,.25
    for i in 0..<8 {
        side:f32=-1 if i<4 else 1
        row:=i%4
        points:=[3]mm.Vec3{{side*.22,0,f32(row)*.3-.45},{side*.35,.1,(f32(row)-1.5)*.09},{side*.35,-.67,(f32(row)-1.5)*.09}}
        names:=[3]string{fmt.tprintf("hip.%d",i),fmt.tprintf("knee.%d",i),fmt.tprintf("foot.%d",i)}
        first:=len(f.state.parents)
        for point,j in points {
            pose:=mm.Transform{point,1,{1,1,1}}
            append(&f.state.parents,i32(1) if j==0 else i32(first+j-1));append(&f.state.targets,base.name_hash(names[j]))
            append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
        }
        leg:=anim.GROUNDED_LEG_DEFAULT;leg.hip=anim.bone_ref(names[0]);leg.knee=anim.bone_ref(names[1]);leg.foot=anim.bone_ref(names[2])
        leg.phase=f32((i+i/4)%2)*.5;leg.step_distance=.3;leg.step_height=.15;leg.sole_height=.03;leg.pole_offset={side,.2,0}
        config.legs[i]=leg
    }
    core.get(&f.configs,f.rig)^=config
    sim.body_set_transform(&f.physics.world,f.platform,{0,-.55,0},1)
    obstacle:=sim.body_create(&f.physics.world,{type=.Kinematic,position={.5,.06,0}})
    desc:=sim.SHAPE_DESC_DEFAULT;desc.geometry=sim.Box{{.225,.1,.85}}
    testing.expect(t,sim.shape_create(&f.physics.world,obstacle,desc)!=0)
    f.state.local[0].position={-.15,-.05,0}
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    return obstacle
}

@(test)
grounding_zero_weight_preserves_the_input_pose_after_body_corrections :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t);defer grounding_fixture_free(&f)
    core.get(&f.configs,f.rig).blend_time=.2
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    testing.expect(t,f.cache.records[0].body_offset.y!=0)
    core.get(&f.configs,f.rig).weight=0
    copy(f.state.local[:],f.state.rest[:]);lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    expected:[8]mm.Transform;copy(expected[:],f.state.local[:])
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    context=saved
    for pose,i in expected {testing.expect_value(t,f.state.local[i],pose)}
    for target in f.cache.records[0].targets[:2] {testing.expect_value(t,target.weight,f32(0))}
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_queries_real_slopes_places_both_feet_and_releases_when_jumping :: proc(t:^testing.T) {
    fixture:Grounding_Fixture;grounding_fixture_init(&fixture,t);defer grounding_fixture_free(&fixture)
    f:=&fixture
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0.1))
    expected_normal:=mm.quat_rotate(mm.quat_axis_angle({0,0,1},0.2),{0,1,0})
    for index in ([2]int{4,7}) {
        foot:=f.state.world[index]
        testing.expect(t,abs(linalg.dot(foot.position,expected_normal)-0.1)<0.001)
        testing.expect(t,linalg.length(mm.quat_rotate(foot.rotation,{0,1,0})-expected_normal)<0.001)
    }
    testing.expect(t,f.state.local[1].position.y<1.7)
    testing.expect_value(t,f.problems.count,0)
    core.get(&f.configs,f.rig).global_contact=0
    copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.y=1
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0.1))
    testing.expect(t,f.cache.records[0].targets[0].weight==0 && f.cache.records[0].targets[1].weight==0)
    testing.expect_value(t,f.state.local[1].position,f.state.rest[1].position)
    testing.expect(t,f.state.world[4].position.y>1)
}

@(test)
grounding_animated_swing_over_lower_ground_preserves_pelvis_and_planted_feet_still_lower_it :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
    previous_context:=context
    context.allocator=mem.tracking_allocator(&track);context.temp_allocator=context.allocator
    defer context=previous_context
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    config:=core.get(&f.configs,f.rig);config.count=1;config.legs[0].plant_speed=10;config.legs[0].pole_offset={}
    sim.body_set_transform(&f.physics.world,f.platform,{0,-.9,0},1)
    source:=f.state.rest[1]
    copy(f.state.local[:],f.state.rest[:]);f.state.local[4].position.y+=.12
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    allocations:=track.total_allocation_count
    maximum_drop:f32
    for frame in 1..=30 {
        copy(f.state.local[:],f.state.rest[:]);f.state.local[4].position+={f32(frame)*.001,.12,0}
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        record:=&f.cache.records[0]
        maximum_drop=max(maximum_drop,abs(record.body_offset.y))
        testing.expect(t,!record.placements[0].anchor.active && record.placements[0].weight==0)
        testing.expect(t,record.targets[0].weight==1 && record.targets[0].position.y>=.21999)
        testing.expect(t,f.state.world[4].position.y>=.21999)
    }
    testing.expect(t,maximum_drop<1e-6)
    testing.expect_value(t,f.state.local[1].position,source.position)
    copy(f.state.local[:],f.state.rest[:])
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    record:=&f.cache.records[0]
    testing.expect(t,record.placements[0].anchor.active && record.placements[0].weight==1)
    testing.expect(t,record.body_offset.y<-.39 && record.body_offset.y>=-.50001)
    testing.expect(t,linalg.length(f.state.world[4].position-record.targets[0].position)<.001)
    testing.expect_value(t,track.total_allocation_count,allocations)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_animated_knee_plane_follows_the_corrected_pelvis :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    config:=core.get(&f.configs,f.rig);config.count=1;config.legs[0].plant_speed=10;config.legs[0].pole_offset={}
    sim.body_set_transform(&f.physics.world,f.platform,{0,-.9,0},1)
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.x=.15
    testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    source_hip:=f.state.world[2].position
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    record:=&f.cache.records[0]
    testing.expect(t,record.placements[0].anchor.active && record.body_offset.y<-.39)
    corrected_hip:=source_hip+record.body_offset
    expected:=linalg.normalize0(linalg.cross(record.targets[0].position-corrected_hip,mm.Vec3{0,0,-1}))
    actual:=linalg.normalize0(linalg.cross(f.state.world[4].position-f.state.world[2].position,f.state.world[3].position-f.state.world[2].position))
    testing.expect(t,linalg.dot(expected,actual)>.99999)
    testing.expect(t,linalg.length(f.state.world[4].position-record.targets[0].position)<.001)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_animated_rejects_distant_lower_floors_without_planting_or_lowering_the_pose :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    config:=core.get(&f.configs,f.rig);config.count=1;config.blend_time=.08;config.legs[0].pole_offset={}
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    sim.body_set_transform(&f.physics.world,f.platform,{0,-1.4,0},1)
    for frame in 0..<30 {
        copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.x=f32(frame)*.001
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        source:[8]mm.Transform;copy(source[:],f.state.world[:])
        saved:=f.cache.records[0]
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
        expected:=f.cache.records[0]
        final:[8]mm.Transform;copy(final[:],f.state.world[:])
        testing.expect(t,!expected.placements[0].anchor.active && expected.placements[0].weight<1)
        testing.expect(t,abs(expected.body_offset.y)<1e-5)
        testing.expect(t,linalg.length(final[4].position-source[4].position)<1e-5)
        if frame>=5 {testing.expect(t,expected.targets[0].weight==0)}
        f.cache.records[0]=saved;copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.x=f32(frame)*.001
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        previous_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
        applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60)
        context=previous_context
        testing.expect(t,applied && f.cache.records[0]==expected)
        for bone,i in final {testing.expect_value(t,f.state.world[i],bone)}
    }
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_animated_interpolates_descending_support_height_and_normal_without_sliding_locked_contacts :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    config:=core.get(&f.configs,f.rig);config.count=1;config.adjust_body=false;config.blend_time=.1
    config.legs[0].pole_offset={};config.legs[0].plant_speed=100
    sim.body_set_transform(&f.physics.world,f.platform,{0,-.25,0},1)
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    previous:=f.state.world[4]
    sim.body_set_transform(&f.physics.world,f.platform,{0,-.45,0},mm.quat_axis_angle({0,0,1},.2))
    copy(f.state.local[:],f.state.rest[:]);testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
    testing.expect(t,abs(f.state.world[4].position.y-previous.position.y)<.04)
    testing.expect(t,mm.quat_angle(f.state.world[4].rotation,previous.rotation)<.04)
    for frame in 0..<90 {
        copy(f.state.local[:],f.state.rest[:]);testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),1.0/60))
    }
    testing.expect(t,mm.quat_angle(f.state.world[4].rotation,mm.quat_axis_angle({0,0,1},.2))<1e-5)
    testing.expect(t,f.cache.records[0].placements[0].anchor.active && f.cache.records[0].placements[0].weight==1)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_clears_the_resolved_heel_and_ball_when_an_unreachable_anchor_clamps_inside_a_ledge :: proc(t:^testing.T) {
    for ball in ([2]bool{false,true}) {
        f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
        config:=core.get(&f.configs,f.rig);config.count=1;config.adjust_body=false;config.trace_above=2;config.trace_below=2
        config.release_distance=3;config.replant_distance=2;config.legs[0].max_distance=2;config.legs[0].plant_speed=100;config.legs[0].pole_offset={}
        if ball {
            bone:=mm.Transform{{-.2,0,0},1,{1,1,1}}
            append(&f.state.parents,i32(4));append(&f.state.targets,base.name_hash("ball.l"))
            append(&f.state.rest,bone);append(&f.state.local,bone);append(&f.state.world,bone)
            config.legs[0].contact_bone=anim.bone_ref("ball.l");config.legs[0].contact_offset=.1
        }
        obstacle:=sim.body_create(&f.physics.world,{type=.Static,position={-.4,.2,0}})
        shape:=sim.SHAPE_DESC_DEFAULT;shape.geometry=sim.Box{{.6,.5,1}}
        testing.expect(t,sim.shape_create(&f.physics.world,obstacle,shape)!=0)
        start:f32=.8 if ball else .6
        f.state.local[0].position.x=start
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.x=start-1.1
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        source:[9]mm.Transform;copy(source[:],f.state.local[:]);saved:=f.cache.records[0]
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        expected:=f.cache.records[0];final:[9]mm.Transform;copy(final[:],f.state.world[:])
        points:=[2]mm.Vec3{f.state.world[4].position-mm.Vec3{0,.1,0},f.state.world[8 if ball else 4].position-mm.Vec3{0,.1,0}}
        for point in points {
            hit,ok:=phys.raycast(core.ref(&f.physics),point+mm.Vec3{0,2,0},{0,-1,0},4,f.rig)
            testing.expect(t,ok && point.y>=hit.point.y-1e-5)
        }
        _,blocked:=anim.grounding_limb_hit(grounding_fixture_ground(&f),f.state.world[2].position,f.state.world[3].position,f.state.world[4].position,f.rig)
        testing.expect(t,!blocked)
        testing.expect(t,linalg.length(f.state.world[4].position-expected.targets[0].position)<1e-5)
        f.cache.records[0]=saved;copy(f.state.local[:],source[:]);lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
        previous_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
        applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1)
        context=previous_context
        testing.expect(t,applied && f.cache.records[0]==expected)
        for bone,i in final[:len(f.state.world)] {testing.expect_value(t,f.state.world[i],bone)}
        testing.expect_value(t,f.problems.count,0)
    }
}

@(test)
grounding_animated_clears_the_reference_heel_when_its_ball_ray_only_sees_a_distant_lower_floor :: proc(t:^testing.T) {
    for contact in ([3]f32{0,.25,1}) {
        f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
        config:=core.get(&f.configs,f.rig);config.count=1;config.adjust_body=false
        config.legs[0].pole_offset={};config.legs[0].max_distance=.55;config.legs[0].contact=contact
        config.legs[0].contact_bone=anim.bone_ref("ball.l");config.legs[0].contact_offset=.1
        bone:=mm.Transform{{.6,0,0},1,{1,1,1}}
        append(&f.state.parents,i32(4));append(&f.state.targets,base.name_hash("ball.l"))
        append(&f.state.rest,bone);append(&f.state.local,bone);append(&f.state.world,bone)
        sim.body_set_transform(&f.physics.world,f.platform,{0,-1.4,0},1)
        obstacle:=sim.body_create(&f.physics.world,{type=.Static,position={-.3,-.21,0}})
        shape:=sim.SHAPE_DESC_DEFAULT;shape.geometry=sim.Box{{.3,.25,1}}
        testing.expect(t,sim.shape_create(&f.physics.world,obstacle,shape)!=0)
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        source:[9]mm.Transform;copy(source[:],f.state.world[:])
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        record:=&f.cache.records[0]
        testing.expect(t,!record.placements[0].anchor.active && record.placements[0].weight==0)
        testing.expect(t,record.alignment[0].weight==0)
        testing.expect(t,record.targets[0].weight==contact)
        if contact==1 {testing.expect(t,f.state.world[4].position.y>=.13999)}
        else if contact==0 {for value,i in source {testing.expect_value(t,f.state.world[i],value)}}
        else {
            pole,valid:=lib.two_bone_pole_from_pose(source[2],source[3],source[4],record.targets[0].position)
            testing.expect(t,valid)
            expected,ok:=lib.two_bone_ik(source[2],source[3],source[4],record.targets[0].position,pole,contact)
            testing.expect(t,ok && linalg.length(f.state.world[4].position-expected.end.position)<1e-5)
            testing.expect(t,f.state.world[4].position.y<.13)
        }
        testing.expect_value(t,f.problems.count,0)
    }
}

@(test)
grounding_animated_raised_contacts_keep_the_source_knee_bending_side_while_crossing_a_straight_leg :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
    previous_context:=context
    context.allocator=mem.tracking_allocator(&track);context.temp_allocator=context.allocator
    defer context=previous_context
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    config:=core.get(&f.configs,f.rig);config.count=1;config.adjust_body=false
    config.legs[0].plant_speed=10;config.legs[0].pole_offset={}
    sim.body_set_transform(&f.physics.world,f.platform,{0,-.3,0},1)
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
    allocations:=track.total_allocation_count
    previous_knee:mm.Vec3
    minimum_forward:f32=1
    maximum_step:f32
    for step in 0..<9 {
        copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.z=.14+.01*f32(step)
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        source:[8]mm.Transform;copy(source[:],f.state.local[:])
        saved:=f.cache.records[0]
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1))
        record:=&f.cache.records[0]
        testing.expect(t,record.placements[0].anchor.active && record.placements[0].weight==1)
        testing.expect(t,linalg.length(f.state.world[4].position-record.targets[0].position)<.001)
        knee:=f.state.world[3].position
        minimum_forward=min(minimum_forward,f.state.world[2].position.z-knee.z)
        if step>0 {maximum_step=max(maximum_step,linalg.length(knee-previous_knee))}
        previous_knee=knee
        expected:=record^
        poses:[8]mm.Transform;copy(poses[:],f.state.world[:])
        record^=saved;copy(f.state.local[:],source[:])
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        allocator_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
        applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1)
        context=allocator_context
        testing.expect(t,applied)
        testing.expect_value(t,record^,expected)
        for pose,i in poses {testing.expect_value(t,f.state.world[i],pose)}
    }
    testing.expect_value(t,track.total_allocation_count,allocations)
    testing.expect(t,minimum_forward>.25 && maximum_step<.02)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
grounding_releases_fast_low_swing_preserves_roll_and_compensates_support_velocity :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
    previous_context:=context
    context.allocator=mem.tracking_allocator(&track);context.temp_allocator=context.allocator
    defer context=previous_context
    fixture:Grounding_Fixture;grounding_fixture_init(&fixture,t,0);defer grounding_fixture_free(&fixture)
    f:=&fixture
    config:=core.get(&f.configs,f.rig);config.blend_time=.08
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),.1))
    allocations:=track.total_allocation_count
    for frame in 1..=120 {
        movement:=mm.Vec3{f32(frame)*.02,0,0}
        turn:=mm.quat_axis_angle({0,1,0},f32(frame)*.005)
        sim.body_set_transform(&f.physics.world,f.platform,movement+mm.Vec3{0,-.5,0},turn)
        copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position=movement;f.state.local[0].rotation=turn
        lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),1.0/60))
        for placement in f.cache.records[0].placements[:2] {testing.expect(t,placement.anchor.active && placement.weight==1)}
    }
    copy(f.state.local[:],f.state.rest[:])
    f.state.local[0].position={2.4,0,0};f.state.local[0].rotation=mm.quat_axis_angle({0,1,0},.6)
    f.state.local[4].position.x+=.08
    f.state.local[4].rotation=mm.quat_axis_angle({1,0,0},.4)
    lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    animated:=f.state.world[4]
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),1.0/60))
    record:=&f.cache.records[0]
    testing.expect(t,!record.placements[0].anchor.active && record.placements[0].weight>0)
    testing.expect(t,record.placements[1].anchor.active)
    testing.expect(t,linalg.length(f.state.world[4].position-animated.position)<.001)
    testing.expect(t,mm.quat_angle(f.state.world[4].rotation,animated.rotation)<.001)
    testing.expect_value(t,track.total_allocation_count,allocations)
}

@(test)
grounding_fades_missing_contacts_and_recovers_while_preserving_stance_and_swing_motion :: proc(t:^testing.T) {
    for missing_ticks in ([3]int{1,2,5}) {
    for swinging in ([2]bool{false,true}) {
        fixture:Grounding_Fixture;grounding_fixture_init(&fixture,t,.2)
        f:=&fixture
        config:=core.get(&f.configs,f.rig);config.count=1;config.adjust_body=false;config.blend_time=.1
        platform:=sim.body_transform(&f.physics.world,f.platform)
        sim.body_set_transform(&f.physics.world,f.platform,platform.p+mm.Vec3{0,.2,0},platform.q)
        source:=f.state.world[4]
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),.1))
        correction:=f.cache.records[0].targets[0].position-source.position
        testing.expect(t,linalg.length(correction)>.1 && f.cache.records[0].targets[0].weight==1)
        core.get(&f.configs,f.rig).collision_mask=0
        for frame in 1..=missing_ticks {
            copy(f.state.local[:],f.state.rest[:])
            if swinging {f.state.local[4].position+={f32(frame)*.04,.12,0}}
            f.state.local[4].rotation=mm.quat_axis_angle({1,0,0},f32(frame)*.1)
            lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
            raw:=f.state.world[4]
            saved:=f.cache.records[0]
            source_pose:[8]mm.Transform;copy(source_pose[:],f.state.local[:])
            previous_context:=context
            context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
            applied:=anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),.02)
            context=previous_context
            testing.expect(t,applied)
            expected:=f.cache.records[0]
            expected_pose:[8]mm.Transform;copy(expected_pose[:],f.state.world[:])
            f.cache.records[0]=saved
            copy(f.state.local[:],source_pose[:]);lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
            testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),.02))
            testing.expect_value(t,f.cache.records[0],expected)
            for transform,i in expected_pose {testing.expect_value(t,f.state.world[i],transform)}
            target:=f.cache.records[0].targets[0]
            testing.expect(t,abs(target.weight-max(0,1-f32(frame)*.2))<1e-6)
            testing.expect(t,!f.cache.records[0].placements[0].anchor.active)
            if frame<5 {
                testing.expect(t,linalg.length(target.position-raw.position-correction)<1e-5)
                testing.expect(t,abs(mm.quat_angle(f.state.world[4].rotation,raw.rotation)-.2*target.weight)<1e-4)
            } else {
                testing.expect(t,linalg.length(f.state.world[4].position-raw.position)<1e-5)
                testing.expect(t,mm.quat_angle(f.state.world[4].rotation,raw.rotation)<1e-4)
            }
        }
        core.get(&f.configs,f.rig).collision_mask=0xffffffff
        copy(f.state.local[:],f.state.rest[:])
        if swinging {f.state.local[4].position+={.24,.12,0}}
        f.state.local[4].rotation=mm.quat_axis_angle({1,0,0},.6)
        lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
        raw:=f.state.world[4]
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),.02))
        recovered_weight:=min(1,1-f32(missing_ticks-1)*.2)
        testing.expect(t,abs(f.cache.records[0].targets[0].weight-recovered_weight)<1e-6)
        testing.expect(t,abs(mm.quat_angle(f.state.world[4].rotation,raw.rotation)-.2*recovered_weight)<1e-4)
        grounding_fixture_free(f)
    }
    }
}

@(test)
grounding_contact_bone_requires_a_foot_descendant_and_recovers_after_configuration_edits :: proc(t:^testing.T) {
    fixture:Grounding_Fixture;grounding_fixture_init(&fixture,t,0);defer grounding_fixture_free(&fixture)
    f:=&fixture
    core.get(&f.configs,f.rig).legs[0].contact_bone=anim.bone_ref("foot.r")
    testing.expect(t,!anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0))
    core.get(&f.configs,f.rig).legs[0].contact_bone=anim.bone_ref("body")
    testing.expect(t,!anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0))
    core.get(&f.configs,f.rig).legs[0].contact_bone=anim.bone_ref("missing")
    testing.expect(t,!anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0))
    config:=core.get(&f.configs,f.rig)
    config.legs[0].contact_bone=anim.bone_ref("foot.l");config.legs[0].contact_offset=.1
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),.1))
    testing.expect(t,f.cache.records[0].placements[0].anchor.active)
}

@(test)
grounding_procedural_pose_follows_platform_replays_clones_and_allocates_nothing_when_stable :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
    previous_context:=context
    context.allocator=mem.tracking_allocator(&track);context.temp_allocator=context.allocator
    defer context=previous_context
    fixture:Grounding_Fixture;grounding_fixture_init(&fixture,t,0);defer grounding_fixture_free(&fixture)
    f:=&fixture
    config:=core.get(&f.configs,f.rig);config.mode=.Procedural;config.body_height=1.65
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),1.0/60))
    allocations:=track.total_allocation_count
    first:=f.cache.records[0].targets
    for _ in 0..<120 {
        copy(f.state.local[:],f.state.rest[:])
        lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),1.0/60))
    }
    testing.expect_value(t,track.total_allocation_count,allocations)
    for target,i in f.cache.records[0].targets[:2] {testing.expect(t,linalg.length(target.position-first[i].position)<0.00001 && target.weight==first[i].weight)}
    saved:anim.Grounding_Runtime;defer anim.grounding_free(&saved)
    core.value_copy(&saved,&f.cache,type_info_of(anim.Grounding_Runtime))
    testing.expect(t,raw_data(saved.records)!=raw_data(f.cache.records) && raw_data(saved.rows)!=raw_data(f.cache.rows))
    testing.expect(t,raw_data(saved.hierarchies)!=raw_data(f.cache.hierarchies) && raw_data(saved.links)!=raw_data(f.cache.links))
    sim.body_set_transform(&f.physics.world,f.platform,{0.1,-0.4,0},1)
    copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position={0.1,0.1,0}
    lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),1.0/60))
    expected:=f.state.world[4]
    testing.expect(t,linalg.length(f.cache.records[0].targets[0].position-first[0].position-mm.Vec3{0.1,0.1,0})<0.001)
    copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position={0.1,0.1,0}
    lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    testing.expect(t,anim.grounding_apply(&f.state,&saved,grounding_fixture_inputs(f),1.0/60))
    testing.expect_value(t,f.state.world[4],expected)
    testing.expect_value(t,saved.records[0],f.cache.records[0])
    sim.body_destroy(&f.physics.world,f.platform)
    copy(f.state.local[:],f.state.rest[:]);lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:])
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0.1))
    testing.expect_value(t,f.cache.records[0].targets[0].weight,f32(0))
}

@(test)
grounding_prepared_hierarchies_rebind_atomically_repack_rigs_and_replay_copied_worlds :: proc(t:^testing.T) {
    f:Grounding_Fixture;grounding_fixture_init(&f,t,0);defer grounding_fixture_free(&f)
    if !testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1)) {return}
    other:anim.Playing;defer anim.playing_free(&other)
    core.value_copy(&other,&f.state,type_info_of(anim.Playing))
    other.entity=core.create(&f.entities);other.bound+=1
    core.add(&f.transforms,other.entity,core.TRANSFORM_IDENTITY)
    core.table_settle(&f.transforms,&f.entities)
    config,_:=core.get(core.read(&f.configs),f.rig)
    core.add(&f.configs,other.entity,config)
    core.table_settle(&f.configs,&f.entities)
    if !testing.expect(t,anim.grounding_apply(&other,&f.cache,grounding_fixture_inputs(&f),.1)) {return}
    testing.expect(t,len(f.cache.links)==16 && f.cache.hierarchies[1].first==8)
    parents_count:=len(f.state.parents)
    pose:=mm.Transform{{.2,0,0},mm.quat_axis_angle({0,1,0},.2),{1,.8,1.2}}
    append(&f.state.parents,i32(4));append(&f.state.targets,base.name_hash("socket"))
    append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
    f.state.bound+=1
    records:[2]anim.Grounding_Record;hierarchies:[2]anim.Grounding_Hierarchy;links:[16]lib.Pose_Link
    copy(records[:],f.cache.records[:]);copy(hierarchies[:],f.cache.hierarchies[:]);copy(links[:],f.cache.links[:])
    pointer:=raw_data(f.cache.links)
    previous:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    rejected:=!anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1)
    context=previous
    testing.expect(t,rejected && f.problems.count==1 && core.problem_find(&f.problems,f.rig,"animation.grounding_bones")!=nil && raw_data(f.cache.links)==pointer)
    for value,i in records {testing.expect_value(t,f.cache.records[i],value)}
    for value,i in hierarchies {testing.expect_value(t,f.cache.hierarchies[i],value)}
    for value,i in links {testing.expect_value(t,f.cache.links[i],value)}
    if !testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(&f),.1)) {return}
    testing.expect(t,len(f.cache.links)==17 && f.cache.hierarchies[0].count==parents_count+1 && f.cache.hierarchies[1].first==parents_count+1)
    saved:anim.Grounding_Runtime;defer anim.grounding_free(&saved)
    core.value_copy(&saved,&f.cache,type_info_of(anim.Grounding_Runtime))
    testing.expect(t,raw_data(saved.links)!=raw_data(f.cache.links) && raw_data(saved.hierarchies)!=raw_data(f.cache.hierarchies))
    source_local,source_world:[8]mm.Transform
    copy(source_local[:],other.local[:]);copy(source_world[:],other.world[:])
    if !testing.expect(t,anim.grounding_apply(&other,&f.cache,grounding_fixture_inputs(&f),.1)) {return}
    expected_local,expected_world:[8]mm.Transform
    copy(expected_local[:],other.local[:]);copy(expected_world[:],other.world[:])
    copy(other.local[:],source_local[:]);copy(other.world[:],source_world[:])
    previous=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    replayed:=anim.grounding_apply(&other,&saved,grounding_fixture_inputs(&f),.1)
    context=previous
    testing.expect(t,replayed)
    for value,i in expected_local {testing.expect_value(t,other.local[i],value)}
    for value,i in expected_world {testing.expect_value(t,other.world[i],value)}
    testing.expect_value(t,saved.records[1],f.cache.records[1])
    core.remove(&f.configs,f.rig);core.table_settle(&f.configs,&f.entities)
    testing.expect(t,anim.grounding_prepare(&f.cache,core.read(&f.configs),nil))
    testing.expect(t,len(f.cache.records)==1 && f.cache.records[0].rig==other.entity && len(f.cache.links)==8 && f.cache.hierarchies[0].first==0)
    previous=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    reused:=anim.grounding_apply(&other,&f.cache,grounding_fixture_inputs(&f),.1)
    context=previous
    testing.expect(t,reused)
    core.remove(&f.configs,other.entity);core.table_settle(&f.configs,&f.entities)
    testing.expect(t,anim.grounding_prepare(&f.cache,core.read(&f.configs),nil))
    testing.expect(t,len(f.cache.records)==0 && len(f.cache.rows)==0 && len(f.cache.hierarchies)==0 && len(f.cache.links)==0)
}

@(test)
grounding_configuration_retires_removed_rigs_and_retries_out_of_memory :: proc(t:^testing.T) {
    fixture:Grounding_Fixture;grounding_fixture_init(&fixture,t);defer grounding_fixture_free(&fixture)
    f:=&fixture
    previous_context:=context
    context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    failed:=!anim.grounding_prepare(&f.cache,core.read(&f.configs),&f.problems)
    context=previous_context
    testing.expect(t,failed && len(f.cache.records)==0 && core.problem_find(&f.problems,core.NONE,"animation.memory")!=nil)
    testing.expect(t,anim.grounding_prepare(&f.cache,core.read(&f.configs),nil))
    testing.expect_value(t,len(f.cache.records),1)
    core.remove(&f.configs,f.rig);core.table_settle(&f.configs,&f.entities)
    testing.expect(t,anim.grounding_prepare(&f.cache,core.read(&f.configs),nil))
    testing.expect(t,len(f.cache.records)==0 && len(f.cache.rows)==0)
    testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0))
    config:=anim.FOOT_GROUNDING_DEFAULT;config.count=1;config.legs[0]=anim.GROUNDED_LEG_DEFAULT
    core.add(&f.configs,f.rig,config);core.table_settle(&f.configs,&f.entities)
    testing.expect(t,!anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),0))
    testing.expect(t,f.problems.count==2 && core.problem_find(&f.problems,f.rig,"animation.grounding_bones")!=nil)
}

@(test)
eight_legged_grounding_walks_without_animation_clips_or_per_leg_entities :: proc(t:^testing.T) {
    fixture:Grounding_Fixture;grounding_fixture_init(&fixture,t,0);defer grounding_fixture_free(&fixture)
    f:=&fixture
    anim.playing_free(&f.state);f.state={entity=f.rig,bound=1}
    for i in 0..<2 {
        pose:=mm.TRANSFORM_IDENTITY;if i==1 {pose.position.y=0.75}
        append(&f.state.parents,i32(i)-1);append(&f.state.targets,base.name_hash("body") if i==1 else u64(0))
        append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
    }
    config:=anim.FOOT_GROUNDING_DEFAULT
    config.mode=.Procedural;config.count=8;config.body=anim.bone_ref("body");config.body_height=0.7
    config.cycle_duration=0.4;config.blend_time=0
    for i in 0..<8 {
        side:f32=-1 if i%2==0 else 1
        points:=[3]mm.Vec3{{side*0.2,0,f32(i/2)*0.2-0.3},{side*0.5,-0.1,0},{side*0.3,-0.6,0}}
        names:=[3]string{fmt.tprintf("hip.%d",i),fmt.tprintf("knee.%d",i),fmt.tprintf("foot.%d",i)}
        first:=len(f.state.parents)
        for point,j in points {
            pose:=mm.Transform{point,1,{1,1,1}}
            append(&f.state.parents,i32(1) if j==0 else i32(first+j-1))
            append(&f.state.targets,base.name_hash(names[j]))
            append(&f.state.rest,pose);append(&f.state.local,pose);append(&f.state.world,pose)
        }
        leg:=anim.GROUNDED_LEG_DEFAULT
        leg.hip=anim.bone_ref(names[0]);leg.knee=anim.bone_ref(names[1]);leg.foot=anim.bone_ref(names[2])
        leg.step_distance=0.08;leg.step_duration=0.1;leg.max_distance=1.5
        leg.pole_offset={0,1,0};leg.phase=f32((i+i/2)%2)*0.5
        config.legs[i]=leg
    }
    core.get(&f.configs,f.rig)^=config
    started:[8]bool
    for frame in 0..<360 {
        copy(f.state.local[:],f.state.rest[:]);f.state.local[0].position.x=f32(frame)*0.002
        testing.expect(t,lib.skeleton_world(anim.playing_skeleton(&f.state),f.state.local[:],f.state.world[:]))
        testing.expect(t,anim.grounding_apply(&f.state,&f.cache,grounding_fixture_inputs(f),1.0/60))
        flying:=0
        for leg,i in f.cache.records[0].legs[:8] {
            if leg.swinging {started[i]=true;flying+=1}
            foot:=f.state.world[4+3*i]
            testing.expect(t,linalg.length(foot.position-f.cache.records[0].targets[i].position)<0.01)
        }
        testing.expect(t,flying<=4)
    }
    for did in started {testing.expect(t,did)}
    testing.expect_value(t,f.entities.alive,1)
    testing.expect_value(t,len(f.transforms.values),1)
    testing.expect_value(t,f.problems.count,0)
}
