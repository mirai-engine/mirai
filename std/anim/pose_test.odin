package mirai_anim

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

HIP :: u64(11)
ARM :: u64(22)

// A clip that holds one position on HIP for `duration` seconds.
pose_clip :: proc(lib:^Library,x:f32,duration:f32=1,loop:Loop=.Loop) -> Clip {
    clip,_:=clip_add(lib,{loop=loop,tracks={{target=HIP,property=.Position,keys={{time=0,value={x,0,0,0}},{time=duration,value={x,0,0,0}}}}}})
    return clip
}

@(test)
pose_blends_players_by_weight :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    pose:Pose
    testing.expect(t,pose_init(&pose,8))
    defer pose_destroy(&pose)
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,0),1,1))
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,8),1,3))
    position,weight,ok:=pose_position(&pose,HIP)
    testing.expect(t,ok && near_vec(position,math.Vec3{6,0,0}) && near(weight,4))
    testing.expect_value(t,pose.count,1)
    _,_,missing:=pose_position(&pose,ARM)
    testing.expect(t,!missing)
    pose_clear(&pose)
    _,_,gone:=pose_position(&pose,HIP)
    testing.expect(t,!gone && pose.count==0)
}

@(test)
pose_keeps_the_value_of_a_player_whose_weight_is_small :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,5),1,0.3))
    position,weight,_:=pose_position(&pose,HIP)
    testing.expect(t,near_vec(position,math.Vec3{5,0,0}) && near(weight,0.3))
    pose_blend(&pose,&lib,player_make(pose_clip(&lib,9),1,0))
    _,after,_:=pose_position(&pose,HIP)
    testing.expect(t,near(after,0.3))
}

@(test)
pose_blends_rotations_on_the_short_arc :: proc(t:^testing.T) {
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    a:=math.quat_axis_angle({0,0,1},0.2)
    b:=math.quat_axis_angle({0,0,1},0.6)
    pose_add(&pose,HIP,.Rotation,0,quat_vec4(a),1)
    pose_add(&pose,HIP,.Rotation,0,-quat_vec4(b),1)
    q,weight,ok:=pose_rotation(&pose,HIP)
    testing.expect(t,ok && near(weight,2) && near(abs(q),1,1e-4))
    testing.expect(t,near(math.quat_angle(q,math.quat_axis_angle({0,0,1},0.4)),0,1e-3))
}

@(test)
pose_separates_targets_properties_and_slots :: proc(t:^testing.T) {
    pose:Pose
    testing.expect(t,pose_init(&pose,8))
    defer pose_destroy(&pose)
    pose_add(&pose,HIP,.Float,0,{1,0,0,0},1)
    pose_add(&pose,HIP,.Float,1,{2,0,0,0},1)
    pose_add(&pose,ARM,.Float,0,{3,0,0,0},1)
    pose_add(&pose,HIP,.Scale,0,{4,4,4,0},1)
    testing.expect_value(t,pose.count,4)
    a,_,_:=pose_float(&pose,HIP,0)
    b,_,_:=pose_float(&pose,HIP,1)
    c,_,_:=pose_float(&pose,ARM)
    scale,_,ok:=pose_scale(&pose,HIP)
    testing.expect(t,a==1 && b==2 && c==3 && ok && scale==math.Vec3{4,4,4})
    _,_,none:=pose_find(&pose,ARM,.Float,5)
    testing.expect(t,!none)
}

@(test)
pose_refuses_entries_past_its_capacity :: proc(t:^testing.T) {
    pose:Pose
    testing.expect(t,pose_init(&pose,2))
    defer pose_destroy(&pose)
    testing.expect(t,pose_add(&pose,1,.Float,0,{1,0,0,0},1))
    testing.expect(t,pose_add(&pose,2,.Float,0,{1,0,0,0},1))
    testing.expect(t,!pose_add(&pose,3,.Float,0,{1,0,0,0},1))
    testing.expect(t,pose_add(&pose,2,.Float,0,{3,0,0,0},1)) // an existing entry still mixes
    testing.expect_value(t,pose.failed,u64(1))
    testing.expect_value(t,pose.count,2)
    value,_,_:=pose_float(&pose,2)
    testing.expect(t,near(value,2))
    other:Pose
    testing.expect(t,!pose_init(&other,0))
    testing.expect(t,!pose_add(&other,1,.Float,0,{},1))
}

@(test)
fader_cross_fades_from_the_old_clip_to_the_new_one :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    idle,run:=pose_clip(&lib,0),pose_clip(&lib,10)
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    f:Fader
    fader_play(&f,idle)
    fader_advance(&lib,&f,0.5,nil)
    fader_play(&f,run,1,1)
    testing.expect(t,fader_fading(f) && near(fader_current_weight(f),0))
    fader_advance(&lib,&f,0.5,nil)
    fader_blend(&pose,&lib,f)
    position,weight,_:=pose_position(&pose,HIP)
    testing.expect(t,near(position.x,5) && near(weight,1))
    fader_advance(&lib,&f,0.75,nil)
    testing.expect(t,!fader_fading(f) && near(fader_current_weight(f),1))
    pose_clear(&pose)
    fader_blend(&pose,&lib,f)
    position,_,_=pose_position(&pose,HIP)
    testing.expect(t,near(position.x,10))
}

@(test)
fader_cuts_without_a_fade_and_nested_fades_keep_the_pose_where_it_was :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    a,b,c:=pose_clip(&lib,0),pose_clip(&lib,4),pose_clip(&lib,8)
    pose:Pose
    testing.expect(t,pose_init(&pose,8))
    defer pose_destroy(&pose)
    sample :: proc(pose:^Pose,lib:^Library,f:Fader) -> f32 {
        pose_clear(pose)
        fader_blend(pose,lib,f)
        position,_,_:=pose_position(pose,HIP)
        return position.x
    }
    f:Fader
    fader_play(&f,a)
    fader_play(&f,b)
    testing.expect(t,!fader_fading(f) && f.current.clip==b)
    fader_play(&f,a,1,2)
    fader_advance(&lib,&f,1,nil)
    before:=sample(&pose,&lib,f)
    testing.expect(t,near(before,2))
    // A third clip in the middle of the fade: the pose does not jump, and all three blend until it ends.
    fader_play(&f,c,1,2)
    testing.expect(t,f.current.clip==c && f.outgoing_count==2 && f.outgoing[0].player.clip==a && f.outgoing[1].player.clip==b)
    testing.expect(t,near(sample(&pose,&lib,f),before))
    fader_advance(&lib,&f,0.5,nil)
    middle:=sample(&pose,&lib,f)
    testing.expect(t,f.outgoing_count==2 && middle>before && middle<8)
    fader_advance(&lib,&f,1.5,nil)
    testing.expect(t,!fader_fading(f) && near(sample(&pose,&lib,f),8))
    // More fades than FADER_OUTGOING: the faintest leaves.
    for clip in ([?]Clip{a,b,c,a,b}) {
        fader_play(&f,clip,1,1)
        fader_advance(&lib,&f,0.1,nil)
    }
    testing.expect_value(t,f.outgoing_count,FADER_OUTGOING)
}

@(test)
fader_reports_the_markers_of_both_clips :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    a,_:=clip_add(&lib,{loop=.Loop,tracks={{target=HIP,property=.Float,keys={key(0,0),key(1,1)}}},markers={{0.5,1}}})
    b,_:=clip_add(&lib,{loop=.Loop,tracks={{target=HIP,property=.Float,keys={key(0,0),key(1,1)}}},markers={{0.5,2}}})
    f:Fader
    fader_play(&f,a)
    fader_advance(&lib,&f,0.25,nil)
    fader_play(&f,b,1,1)
    events:[4]Event
    written,dropped:=fader_advance(&lib,&f,0.5,events[:])
    testing.expect(t,written==2 && dropped==0 && events[0].id==2 && events[1].id==1)
    testing.expect(t,near(events[0].weight,1) && near(events[1].weight,1))
    written,dropped=fader_advance(&lib,&f,1,events[:0])
    testing.expect(t,written==0 && dropped==2)
}

@(test)
pose_drives_a_whole_clip_through_a_player :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{loop=.Once,tracks={
        {target=HIP,property=.Position,keys={{time=0,value={0,0,0,0}},{time=2,value={4,0,0,0}}}},
        {target=ARM,property=.Rotation,keys={rot_key(0,math.QUAT_IDENTITY),rot_key(2,math.quat_axis_angle({1,0,0},math.PI/2))}}}})
    p:=player_make(clip)
    player_advance(&lib,&p,1,nil)
    pose:Pose
    testing.expect(t,pose_init(&pose,4))
    defer pose_destroy(&pose)
    pose_blend(&pose,&lib,p)
    position,_,_:=pose_position(&pose,HIP)
    rotation,_,_:=pose_rotation(&pose,ARM)
    testing.expect(t,near_vec(position,math.Vec3{2,0,0}) && near(math.quat_angle(math.QUAT_IDENTITY,rotation),math.PI/4,1e-3))
    pose_blend(&pose,&lib,player_make(99))
    testing.expect_value(t,pose.count,2)
}

// A clip of the bones test: each track takes its two keys from its place, so every one differs.
@(private="file")
BONE_TEST_TRACKS :: 7
@(private="file")
bones_test_clip :: proc(lib:^Library,name:u64,tracks:[]Track_Desc,keys:^[BONE_TEST_TRACKS][2]Keyframe) -> Clip {
    for &track,i in tracks {
        for &key,k in keys[i] {
            seed:=f32(name)*.37+f32(i)*1.3+f32(k)*.9
            key.time=f32(k)
            #partial switch track.property {
            case .Rotation:
                key.value=quat_vec4(math.quat_axis_angle(linalg.normalize(math.Vec3{1,seed,.5}),seed))
                if (i+k)%2==1 {key.value=-key.value}
            case: key.value={seed,seed*.5-1,2-seed,0}
            }
        }
        track.keys=keys[i][:]
    }
    clip,_:=clip_add(lib,{name=name,loop=.Loop,tracks=tracks})
    return clip
}

// Clips that list their tracks in other orders, lack some, repeat a target under another slot and
// move what the rig does not have, blended through faders, a lock and additive layers.
@(test)
bones_blend_what_a_pose_blends_for_their_targets :: proc(t:^testing.T) {
    LEG :: u64(33)
    HEAD :: u64(44)
    lib:=make_library(t,keys=64,tracks=24,clips=4)
    defer library_destroy(&lib)
    keys:[3][BONE_TEST_TRACKS][2]Keyframe
    walk_tracks:=[?]Track_Desc{{target=HIP,property=.Position},{target=HIP,property=.Rotation},{target=ARM,property=.Rotation},{target=LEG,property=.Position},{target=LEG,property=.Scale},{target=HEAD,property=.Rotation}}
    wave_tracks:=[?]Track_Desc{{target=HEAD,property=.Rotation},{target=ARM,property=.Rotation},{target=ARM,property=.Position},{target=99,property=.Position},{target=HIP,property=.Rotation},{target=HIP,property=.Float},{target=HIP,property=.Position,slot=1}}
    lean_tracks:=[?]Track_Desc{{target=LEG,property=.Scale},{target=HIP,property=.Position},{target=ARM,property=.Rotation}}
    walk:=bones_test_clip(&lib,1,walk_tracks[:],&keys[0])
    wave:=bones_test_clip(&lib,2,wave_tracks[:],&keys[1])
    lean:=bones_test_clip(&lib,3,lean_tracks[:],&keys[2])
    if !testing.expect(t,walk!=0 && wave!=0 && lean!=0) {return}

    // The last bone is one no clip moves.
    targets:=[?]u64{HIP,ARM,LEG,HEAD,55}
    rest:[len(targets)]math.Transform
    for &value,b in rest {value={position={f32(b),1,-2},rotation=math.quat_axis_angle({0,0,1},.2*f32(b+1)),scale={1,2,.5}}}
    track_bones:[24]i32
    for track,i in lib.tracks[:lib.track_count] {
        track_bones[i]=-1
        if track.slot!=0 || track.property>.Scale {continue}
        for target,b in targets {if target==track.target {track_bones[i]=i32(b)}}
    }
    pose:Pose
    testing.expect(t,pose_init(&pose,32))
    defer pose_destroy(&pose)
    bones:[len(targets)]Bone_Blend
    references:[len(targets)*3]i32

    blended :: proc(t:^testing.T,pose:^Pose,bones:[]Bone_Blend,targets:[]u64,rest:[]math.Transform,what:string) {
        for target,b in targets {
            expected,expected_weights,expected_properties:=pose_bone(pose,target,rest[b])
            got,weights,properties:=bone_transform(bones[b],rest[b])
            testing.expectf(t,properties==expected_properties && near_vec(weights,expected_weights,1e-6) && near_vec(got.position,expected.position,1e-5) && near_vec(got.scale,expected.scale,1e-5) && math.quat_angle(got.rotation,expected.rotation)<1e-4,"%s, bone %d: %v, by name %v",what,b,got,expected)
        }
    }
    added :: proc(t:^testing.T,pose:^Pose,bones:[]Bone_Blend,targets:[]u64,what:string) {
        for target,b in targets {
            position,_,has_position:=pose_position(pose,target)
            rotation,_,has_rotation:=pose_rotation(pose,target)
            scale,_,has_scale:=pose_scale(pose,target)
            moved,moves:=bone_added_position(bones[b])
            turned,turns:=bone_added_rotation(bones[b])
            grown,grows:=bone_added_scale(bones[b])
            testing.expectf(t,moves==has_position && turns==has_rotation && grows==has_scale,"%s, bone %d: channels",what,b)
            testing.expectf(t,(!moves || near_vec(moved,position,1e-5)) && (!turns || math.quat_angle(turned,rotation)<1e-4) && (!grows || near_vec(grown,scale,1e-5)),"%s, bone %d: %v %v %v, by name %v %v %v",what,b,moved,turned,grown,position,rotation,scale)
        }
    }

    f:Fader
    fader_play(&f,walk)
    fader_advance(&lib,&f,.3,nil)
    fader_play(&f,wave,1,.5)
    fader_advance(&lib,&f,.2,nil)
    fader_play(&f,lean,1,.4,.Quad_Out)
    fader_advance(&lib,&f,.1,nil)
    testing.expect_value(t,f.outgoing_count,2)
    testing.expect(t,fader_blend(&pose,&lib,f))
    bones_fader_blend(bones[:],track_bones[:],&lib,f)
    blended(t,&pose,bones[:],targets[:],rest[:],"three clips fading")

    lock:=Pose_Lock{target=HIP,position=true,rotation=true,value=rest[0]}
    first,second:=player_make(walk,1,.7),player_make(wave,1,.6)
    first.time,second.time=.4,.8
    pose_clear(&pose);bones={}
    pose_blend(&pose,&lib,first,.5,lock);pose_blend(&pose,&lib,second)
    bones_blend(bones[:],track_bones[:],&lib,first,.5,lock);bones_blend(bones[:],track_bones[:],&lib,second)
    blended(t,&pose,bones[:],targets[:],rest[:],"a locked root under its weight")

    for from in ([?]Clip{0,walk,lean}) {
        pose_clear(&pose);bones={}
        pose_blend_additive(&pose,&lib,second,.25,1,from);pose_blend_additive(&pose,&lib,first,.25,.5,from)
        testing.expect(t,bones_blend_additive(bones[:],track_bones[:],&lib,second,.25,1,from,references[:]) && bones_blend_additive(bones[:],track_bones[:],&lib,first,.25,.5,from,references[:]))
        added(t,&pose,bones[:],targets[:],"additives over a reference clip" if from!=0 else "additives over their own pose")
    }

    // Without room to pair the reference clip nothing is added; tracks paired outside the bones are left out.
    bones={}
    testing.expect(t,!bones_blend_additive(bones[:],track_bones[:],&lib,second,.25,1,walk,references[:3]) && bones==([len(targets)]Bone_Blend{}))
    for &bone,i in track_bones {bone=i32(i*7-20)}
    bones_blend(bones[:2],track_bones[:5],&lib,first)
    testing.expect(t,bones_blend_additive(bones[:2],track_bones[:],&lib,second,.25,1,walk,references[:]))
}
