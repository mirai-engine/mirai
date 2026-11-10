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

// The position a fader blends for HIP, the only bone, and the weight that blended it.
@(private="file")
hip_position :: proc(lib:^Library,f:Fader) -> (x,weight:f32) {
    track_bones:[16]i32
    library_track_bones(lib,{HIP},track_bones[:])
    bones:[1]Bone_Blend
    bones_fader_blend(bones[:],track_bones[:],lib,f)
    value,w,_:=bone_position(bones[0])
    return value.x,w
}

@(test)
bones_blend_players_by_weight_and_keep_what_a_small_weight_gave :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    first,second,faint:=pose_clip(&lib,0),pose_clip(&lib,8),pose_clip(&lib,5)
    track_bones:[16]i32
    testing.expect(t,library_track_bones(&lib,{HIP,ARM},track_bones[:]))
    bones:[2]Bone_Blend
    bones_blend(bones[:],track_bones[:],&lib,player_make(first,1,1))
    bones_blend(bones[:],track_bones[:],&lib,player_make(second,1,3))
    position,weight,ok:=bone_position(bones[0])
    testing.expect(t,ok && near_vec(position,math.Vec3{6,0,0}) && near(weight,4))
    _,_,moved:=bone_position(bones[1])
    _,_,turned:=bone_rotation(bones[0])
    testing.expect(t,!moved && !turned,"a channel no clip gave has no weight")
    bones={}
    bones_blend(bones[:],track_bones[:],&lib,player_make(faint,1,0.3))
    bones_blend(bones[:],track_bones[:],&lib,player_make(second,1,0))
    position,weight,_=bone_position(bones[0])
    testing.expect(t,near_vec(position,math.Vec3{5,0,0}) && near(weight,0.3))
    // A table shorter than the tracks of the library, or no library, binds nothing.
    testing.expect(t,!library_track_bones(&lib,{HIP},track_bones[:lib.track_count-1]) && !library_track_bones(nil,{HIP},track_bones[:]))
    bones_blend(bones[:],track_bones[:],&lib,player_make(99))
}

@(test)
bones_blend_rotations_on_the_short_arc :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    a:=math.quat_axis_angle({0,0,1},0.2)
    b:=math.quat_axis_angle({0,0,1},0.6)
    one,_:=clip_add(&lib,{loop=.Loop,tracks={{target=HIP,property=.Rotation,keys={rot_key(0,a),rot_key(1,a)}}}})
    other,_:=clip_add(&lib,{loop=.Loop,tracks={{target=HIP,property=.Rotation,keys={{time=0,value=-quat_vec4(b)},{time=1,value=-quat_vec4(b)}}}}})
    track_bones:[16]i32
    library_track_bones(&lib,{HIP},track_bones[:])
    bones:[1]Bone_Blend
    bones_blend(bones[:],track_bones[:],&lib,player_make(one))
    bones_blend(bones[:],track_bones[:],&lib,player_make(other))
    q,weight,ok:=bone_rotation(bones[0])
    testing.expect(t,ok && near(weight,2) && near(abs(q),1,1e-4))
    testing.expect(t,near(math.quat_angle(q,math.quat_axis_angle({0,0,1},0.4)),0,1e-3))
}

@(test)
fader_cross_fades_from_the_old_clip_to_the_new_one :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    idle,run:=pose_clip(&lib,0),pose_clip(&lib,10)
    f:Fader
    fader_play(&f,idle)
    fader_advance(&lib,&f,0.5,nil)
    fader_play(&f,run,1,1)
    testing.expect(t,fader_fading(f) && near(fader_current_weight(f),0))
    fader_advance(&lib,&f,0.5,nil)
    x,weight:=hip_position(&lib,f)
    testing.expect(t,near(x,5) && near(weight,1))
    fader_advance(&lib,&f,0.75,nil)
    testing.expect(t,!fader_fading(f) && near(fader_current_weight(f),1))
    x,_=hip_position(&lib,f)
    testing.expect(t,near(x,10))
}

@(test)
fader_cuts_without_a_fade_and_nested_fades_keep_the_pose_where_it_was :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    a,b,c:=pose_clip(&lib,0),pose_clip(&lib,4),pose_clip(&lib,8)
    sample :: proc(lib:^Library,f:Fader) -> f32 {x,_:=hip_position(lib,f);return x}
    f:Fader
    fader_play(&f,a)
    fader_play(&f,b)
    testing.expect(t,!fader_fading(f) && f.current.clip==b)
    fader_play(&f,a,1,2)
    fader_advance(&lib,&f,1,nil)
    before:=sample(&lib,f)
    testing.expect(t,near(before,2))
    // A third clip in the middle of the fade: the pose does not jump, and all three blend until it ends.
    fader_play(&f,c,1,2)
    testing.expect(t,f.current.clip==c && f.outgoing_count==2 && f.outgoing[0].player.clip==a && f.outgoing[1].player.clip==b)
    testing.expect(t,near(sample(&lib,f),before))
    fader_advance(&lib,&f,0.5,nil)
    middle:=sample(&lib,f)
    testing.expect(t,f.outgoing_count==2 && middle>before && middle<8)
    fader_advance(&lib,&f,1.5,nil)
    testing.expect(t,!fader_fading(f) && near(sample(&lib,f),8))
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
bones_take_a_whole_clip_through_a_player :: proc(t:^testing.T) {
    lib:=make_library(t)
    defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{loop=.Once,tracks={
        {target=HIP,property=.Position,keys={{time=0,value={0,0,0,0}},{time=2,value={4,0,0,0}}}},
        {target=ARM,property=.Rotation,keys={rot_key(0,math.QUAT_IDENTITY),rot_key(2,math.quat_axis_angle({1,0,0},math.PI/2))}}}})
    p:=player_make(clip)
    player_advance(&lib,&p,1,nil)
    track_bones:[16]i32
    library_track_bones(&lib,{HIP,ARM},track_bones[:])
    bones:[2]Bone_Blend
    bones_blend(bones[:],track_bones[:],&lib,p)
    position,_,_:=bone_position(bones[0])
    rotation,_,_:=bone_rotation(bones[1])
    testing.expect(t,near_vec(position,math.Vec3{2,0,0}) && near(math.quat_angle(math.QUAT_IDENTITY,rotation),math.PI/4,1e-3))
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
bones_blend_what_each_track_gives_their_bones :: proc(t:^testing.T) {
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
    testing.expect(t,library_track_bones(&lib,targets[:],track_bones[:]))
    bones:[len(targets)]Bone_Blend
    references:[len(targets)*3]i32

    // What each track of a clip gives a channel of a target at the time of its player, evaluated
    // track by track: the oracle the blend by bone is held to.
    Channel :: struct {sum:math.Vec4,weight:f32,added:math.Vec4,adds:bool}
    Oracle :: [5][3]Channel // a row a target
    mix :: proc(lib:^Library,o:^Oracle,targets:[]u64,p:Player,scale:f32,lock:Pose_Lock={}) {
        for track in clip_tracks(lib,p.clip) {
            if track.slot!=0 || track.property>.Scale {continue}
            for target,b in targets {
                if target!=track.target {continue}
                value:=clip_evaluate(lib,track,player_time(lib,p))
                if track.target==lock.target && track.property==.Position && lock.position {value.xyz=lock.value.position}
                if track.target==lock.target && track.property==.Rotation && lock.rotation {value=quat_vec4(lock.value.rotation)}
                channel:=&o[b][int(track.property)]
                if track.property==.Rotation && channel.weight>0 {value=quat_align(value,channel.sum)}
                channel.sum+=value*(p.weight*scale);channel.weight+=p.weight*scale
                break
            }
        }
    }
    add :: proc(lib:^Library,o:^Oracle,targets:[]u64,p:Player,reference,scale:f32,from:Clip) {
        for track in clip_tracks(lib,p.clip) {
            if track.slot!=0 || track.property>.Scale {continue}
            for target,b in targets {
                if target!=track.target {continue}
                source:=track
                if from!=0 {for other in clip_tracks(lib,from) {if other.target==track.target && other.property==track.property && other.slot==0 {source=other;break}}}
                now,rest:=clip_evaluate(lib,track,player_time(lib,p)),clip_evaluate(lib,source,reference)
                channel:=&o[b][int(track.property)]
                if track.property==.Rotation {
                    turn:=math.quat_slerp(1,conj(vec4_quat(rest))*vec4_quat(now),p.weight*scale)
                    channel.added=quat_vec4((vec4_quat(channel.added) if channel.adds else 1)*turn)
                } else {channel.added+=(now-rest)*(p.weight*scale)}
                channel.adds=true
                break
            }
        }
    }
    blended :: proc(t:^testing.T,o:^Oracle,bones:[]Bone_Blend,rest:[]math.Transform,what:string) {
        for b in 0..<len(bones) {
            expected:=rest[b]
            if c:=o[b][0];c.weight>0 {expected.position=math.lerp(rest[b].position,c.sum.xyz/c.weight,math.saturate(c.weight))}
            if c:=o[b][1];c.weight>0 {expected.rotation=math.quat_slerp(rest[b].rotation,linalg.normalize0(vec4_quat(c.sum)),math.saturate(c.weight))}
            if c:=o[b][2];c.weight>0 {expected.scale=math.lerp(rest[b].scale,c.sum.xyz/c.weight,math.saturate(c.weight))}
            got,weights,properties:=bone_transform(bones[b],rest[b])
            for c,channel in o[b] {
                testing.expectf(t,(Property(channel) in properties)==(c.weight>0) && near(weights[channel],math.saturate(c.weight),1e-6),"%s, bone %d: channel %d",what,b,channel)
            }
            testing.expectf(t,near_vec(got.position,expected.position,1e-5) && near_vec(got.scale,expected.scale,1e-5) && math.quat_angle(got.rotation,expected.rotation)<1e-4,"%s, bone %d: %v, track by track %v",what,b,got,expected)
        }
    }
    added :: proc(t:^testing.T,o:^Oracle,bones:[]Bone_Blend,what:string) {
        for b in 0..<len(bones) {
            moved,moves:=bone_added_position(bones[b])
            turned,turns:=bone_added_rotation(bones[b])
            grown,grows:=bone_added_scale(bones[b])
            testing.expectf(t,moves==o[b][0].adds && turns==o[b][1].adds && grows==o[b][2].adds,"%s, bone %d: channels",what,b)
            testing.expectf(t,(!moves || near_vec(moved,o[b][0].added.xyz,1e-5)) && (!turns || math.quat_angle(turned,linalg.normalize0(vec4_quat(o[b][1].added)))<1e-4) && (!grows || near_vec(grown,o[b][2].added.xyz,1e-5)),"%s, bone %d: %v %v %v",what,b,moved,turned,grown)
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
    oracle:Oracle
    mix(&lib,&oracle,targets[:],f.current,fader_current_weight(f))
    for outgoing in f.outgoing[:f.outgoing_count] {mix(&lib,&oracle,targets[:],outgoing.player,fade_out_weight(outgoing))}
    bones_fader_blend(bones[:],track_bones[:],&lib,f)
    blended(t,&oracle,bones[:],rest[:],"three clips fading")

    lock:=Pose_Lock{target=HIP,position=true,rotation=true,value=rest[0]}
    first,second:=player_make(walk,1,.7),player_make(wave,1,.6)
    first.time,second.time=.4,.8
    oracle={};bones={}
    mix(&lib,&oracle,targets[:],first,.5,lock);mix(&lib,&oracle,targets[:],second,1)
    bones_blend(bones[:],track_bones[:],&lib,first,.5,lock);bones_blend(bones[:],track_bones[:],&lib,second)
    blended(t,&oracle,bones[:],rest[:],"a locked root under its weight")

    for from in ([?]Clip{0,walk,lean}) {
        oracle={};bones={}
        add(&lib,&oracle,targets[:],second,.25,1,from);add(&lib,&oracle,targets[:],first,.25,.5,from)
        testing.expect(t,bones_blend_additive(bones[:],track_bones[:],&lib,second,.25,1,from,references[:]) && bones_blend_additive(bones[:],track_bones[:],&lib,first,.25,.5,from,references[:]))
        added(t,&oracle,bones[:],"additives over a reference clip" if from!=0 else "additives over their own pose")
    }

    // Without room to pair the reference clip nothing is added; tracks paired outside the bones are left out.
    bones={}
    testing.expect(t,!bones_blend_additive(bones[:],track_bones[:],&lib,second,.25,1,walk,references[:3]) && bones==([len(targets)]Bone_Blend{}))
    for &bone,i in track_bones {bone=i32(i*7-20)}
    bones_blend(bones[:2],track_bones[:5],&lib,first)
    testing.expect(t,bones_blend_additive(bones[:2],track_bones[:],&lib,second,.25,1,walk,references[:]))
}
