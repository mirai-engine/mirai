package mirai_anim

@(require) import "core:log"
@(require) import "base:runtime"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import math "mirai:std/math"

when #config(MIRAI_BENCH,false) {
@(test)
bench_two_bone_pose_pole :: proc(t:^testing.T) {
    REPEATS :: 200000
    poses:[4][3]math.Transform
    poses[0]={{{0,1,0},1,{1,1,1}},{{.05,.5,0},1,{1,1,1}},{{0,0,0},1,{1,1,1}}}
    poses[1]=poses[0];poses[1][1].position.x=0
    poses[2]=poses[0];poses[2][1].position={.002,.5,-.02};poses[2][2].position={0,0,-.1}
    poses[3]=poses[0];poses[3][2]=poses[3][0]
    targets:[64]math.Vec3
    for &target,i in targets {target={f32(i%9)*.06-.24,f32(i%13)*.13-.05,f32(i%7)*.08-.24}}
    targets[0],targets[3]={0,1,0},{0,1,0};targets[1],targets[7]={0,1.8,0},{0,1.8,0}
    previous_context:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator
    valid:=true;sink:f32;best:=max(time.Duration)
    for i in 0..<512 {pose:=poses[i%len(poses)];_,ok:=two_bone_pole_from_pose(pose[0],pose[1],pose[2],targets[i%len(targets)]);valid &&=ok}
    for _ in 0..<5 {
        start:=time.tick_now()
        for i in 0..<REPEATS {
            pose:=poses[i%len(poses)]
            pole,ok:=two_bone_pole_from_pose(pose[0],pose[1],pose[2],targets[i%len(targets)])
            valid &&=ok;sink+=pole.x+pole.y*.25+pole.z*.125
        }
        best=min(best,time.tick_since(start))
    }
    context=previous_context
    testing.expect(t,valid && anim_finite(sink))
    log.infof("two-bone pose pole, 4 source shapes / 64 targets: %.2f ns/pole (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
}

@(test)
bench_skeletal_two_clips_layer :: proc(t:^testing.T) {
    BONES :: 64
    REPEATS :: 10000
    parents:[BONES]i32;names:[BONES]u64;rest,world:[BONES]math.Transform
    tracks:[BONES]Track_Desc;keys:[BONES][2]Keyframe
    for i in 0..<BONES {
        parents[i]=i32(i)-1;names[i]=u64(i+1);rest[i]=math.TRANSFORM_IDENTITY
        keys[i]={{time=0,value={0,0.01,0,0}},{time=1,value={0.01,0.01,0,0}}}
        tracks[i]={target=names[i],property=.Position,keys=keys[i][:]}
    }
    library:Library
    testing.expect(t,library_init(&library,{max_keys=BONES*4,max_tracks=BONES*2,max_clips=2}))
    defer library_destroy(&library)
    a,_:=clip_add(&library,{loop=.Loop,tracks=tracks[:]})
    b,_:=clip_add(&library,{loop=.Loop,tracks=tracks[:]})
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    bindings_a,bindings_b:[BONES]Bone_Tracks
    pose_a,pose_b,mixed:[BONES]math.Transform
    testing.expect(t,skeleton_bind(&library,a,skeleton,bindings_a[:]) && skeleton_bind(&library,b,skeleton,bindings_b[:]))
    player_a,player_b:=player_make(a),player_make(b)
    best:=max(time.Duration)
    sink:f32
    for _ in 0..<5 {
        start:=time.tick_now()
        for _ in 0..<REPEATS {
            player_advance(&library,&player_a,1.0/60,nil);player_advance(&library,&player_b,1.0/60,nil)
            skeleton_sample(&library,bindings_a[:],rest[:],player_time(&library,player_a),pose_a[:])
            skeleton_sample(&library,bindings_b[:],rest[:],player_time(&library,player_b),pose_b[:])
            for value,i in pose_a {mixed[i]=math.transform_interpolate(value,pose_b[i],0.3)}
            skeleton_world(skeleton,mixed[:],world[:])
            sink+=world[BONES-1].position.x
        }
        best=min(best,time.tick_since(start))
    }
    log.infof("skeletal 2 clips + layer + world, 64 bones: %.2f ns/pose, %.2f ns/bone (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,f64(time.duration_nanoseconds(best))/(REPEATS*BONES),sink)
}

// Two clips cross-fading on 64 bones, position and rotation, through the table of the bone of
// each track.
@(test)
bench_bones_blend :: proc(t:^testing.T) {
    BONES :: 64
    REPEATS :: 10000
    names:[BONES]u64;rest:[BONES]math.Transform
    tracks:[BONES*2]Track_Desc;keys:[BONES*2][2]Keyframe
    for i in 0..<BONES {
        names[i]=u64(i+1)*0x9e3779b97f4a7c15;rest[i]=math.TRANSFORM_IDENTITY
        keys[i*2]={{time=0,value={0,0.01,0,0}},{time=1,value={0.01,0.01,0,0}}}
        keys[i*2+1]={{time=0,value={0,0,0,1}},{time=1,value=quat_vec4(math.quat_axis_angle({0,0,1},.4))}}
        tracks[i*2]={target=names[i],property=.Position,keys=keys[i*2][:]}
        tracks[i*2+1]={target=names[i],property=.Rotation,keys=keys[i*2+1][:]}
    }
    library:Library
    testing.expect(t,library_init(&library,{max_keys=BONES*8,max_tracks=BONES*4,max_clips=2}))
    defer library_destroy(&library)
    a,_:=clip_add(&library,{loop=.Loop,tracks=tracks[:]})
    b,_:=clip_add(&library,{loop=.Loop,tracks=tracks[:]})
    track_bones:[BONES*4]i32
    testing.expect(t,library_track_bones(&library,names[:],track_bones[:]))
    bones:[BONES]Bone_Blend
    out:[BONES]math.Transform
    sink:f32
    player_a,player_b:=player_make(a,1,.7),player_make(b,1,.3)
    best:=max(time.Duration)
    for _ in 0..<5 {
        start:=time.tick_now()
        for _ in 0..<REPEATS {
            player_advance(&library,&player_a,1.0/60,nil);player_advance(&library,&player_b,1.0/90,nil)
            bones={}
            bones_blend(bones[:],track_bones[:],&library,player_a);bones_blend(bones[:],track_bones[:],&library,player_b)
            for bone,i in bones {out[i],_,_=bone_transform(bone,rest[i])}
            sink+=out[BONES-1].position.x+out[BONES-1].rotation.z
        }
        best=min(best,time.tick_since(start))
    }
    log.infof("blend of 2 clips, 64 bones / position+rotation: %.2f ns/pose (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
}

@(test)
bench_procedural_gait_and_chain :: proc(t:^testing.T) {
    REPEATS :: 10000
    legs:[8]Gait_Leg;contacts:[8]Surface_Contact;desired:[8]math.Vec3
    states:[8]Gait_Leg_State;out:[8]Foot_Target;state:Gait_State
    for &leg,i in legs {
        leg=GAIT_LEG_DEFAULT;leg.phase=f32(i%2)*0.5
        desired[i]={f32(i/2)*0.2-0.3,0,-0.7 if i%2==0 else 0.7}
        contacts[i]={position=desired[i],normal={0,1,0},valid=true}
    }
    config:=GAIT_CONFIG_DEFAULT;config.max_swinging=4;config.blend_time=0
    testing.expect(t,gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],0,false,out[:]))
    best:=max(time.Duration);sink:f32
    for _ in 0..<5 {
        start:=time.tick_now()
        for frame in 0..<REPEATS {
            for &contact,i in contacts {contact.position.x=desired[i].x+f32(frame%100)*0.005}
            gait_update(config,legs[:],contacts[:],nil,desired[:],&state,states[:],1.0/60,true,out[:])
            for target,i in out {
                root:=math.Transform{{desired[i].x,0.6,0},1,{1,1,1}}
                joint:=math.Transform{{desired[i].x,0.8,desired[i].z*0.5},1,{1,1,1}}
                end:=math.Transform{desired[i],1,{1,1,1}}
                solved,_:=two_bone_ik(root,joint,end,target.position,{desired[i].x,1,desired[i].z})
                sink+=solved.joint.position.y
            }
        }
        best=min(best,time.tick_since(start))
    }
    log.infof("procedural gait + 8 two-bone IK: %.2f ns/creature (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
    points:=[6]math.Vec3{{},{1,0,0},{2,0,0},{3,0,0},{4,0,0},{5,0,0}}
    lengths:=[5]f32{1,1,1,1,1};solved:[6]math.Vec3
    settings:=CHAIN_IK_DEFAULT;settings.target={2,1,0};settings.pole={0,0,2};settings.use_pole=true
    best=max(time.Duration)
    for _ in 0..<5 {
        start:=time.tick_now()
        for _ in 0..<REPEATS {result,_:=chain_ik(points[:],lengths[:],nil,settings,solved[:]);sink+=result.error}
        best=min(best,time.tick_since(start))
    }
    log.infof("FABRIK 6 joints + pole: %.2f ns/chain (check %v)",f64(time.duration_nanoseconds(best))/REPEATS,sink)
}
}
