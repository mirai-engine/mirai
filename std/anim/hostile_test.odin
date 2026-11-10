package mirai_anim

import "core:testing"
import math "mirai:std/math"

// Every public procedure takes whatever it is given and returns: durations,
// times and speeds that are zero, negative, NaN or infinite, clips, tracks and
// keyframes that are empty, unsorted or from another library, and states,
// parameters and handles out of range.

@(private="file") HOSTILE_ROUNDS :: #config(ANIM_HOSTILE_ROUNDS,400)

@(private="file")
Hostile :: struct {state:u64}

@(private="file")
hostile_next :: proc(h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    z:=h.state
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file")
hostile_int :: proc(h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}

@(private="file")
hostile_f32 :: proc(h:^Hostile) -> f32 {
    switch hostile_int(h,12) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    }
    return f32(hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_time :: proc(h:^Hostile) -> f32 {
    if hostile_int(h,3)==0 {return hostile_f32(h)}
    return f32(hostile_int(h,600)-100)/100
}

@(private="file")
hostile_u32 :: proc(h:^Hostile) -> u32 {
    switch hostile_int(h,8) {
    case 0: return 0
    case 1: return max(u32)
    case 2: return 1
    }
    return u32(hostile_int(h,100))
}

@(private="file")
hostile_size :: proc(h:^Hostile) -> int {
    switch hostile_int(h,12) {
    case 0: return 0
    case 1: return -1
    case 2: return 1
    case 3: return min(int)
    case 4: return 1<<50
    case 5: return 1<<52
    case 6: return 3
    }
    return hostile_int(h,60)+1
}

@(private="file")
hostile_vec4 :: proc(h:^Hostile) -> math.Vec4 {return {hostile_f32(h),hostile_f32(h),hostile_f32(h),hostile_f32(h)}}

@(private="file")
hostile_quat :: proc(h:^Hostile) -> math.Quat {
    v:=hostile_vec4(h)
    return quaternion(w=v.w,x=v.x,y=v.y,z=v.z)
}

@(private="file")
hostile_ease :: proc(h:^Hostile) -> math.Ease {return math.Ease(hostile_int(h,4)==0?hostile_int(h,256):hostile_int(h,31))}

@(private="file")
hostile_loop :: proc(h:^Hostile) -> Loop {return Loop(hostile_int(h,5)==0?hostile_int(h,256):hostile_int(h,3))}

@(private="file")
hostile_keys :: proc(h:^Hostile,keys:^[dynamic]Keyframe,sorted:bool,lonely:=false) {
    clear(keys)
    n:=hostile_int(h,8)
    if n==1 && !lonely {n=2}
    time:f32
    for _ in 0..<n {
        time=sorted?time+f32(hostile_int(h,4))/2:hostile_time(h)
        key:=Keyframe{time=time,value=hostile_vec4(h),ease=hostile_ease(h),interpolation=Interpolation(hostile_int(h,5)==0?hostile_int(h,256):hostile_int(h,3)),tangents=hostile_int(h,2)==0}
        key.in_slope,key.out_slope=hostile_vec4(h),hostile_vec4(h)
        append(keys,key)
    }
}

@(private="file")
hostile_property :: proc(h:^Hostile) -> Property {return Property(hostile_int(h,6)==0?hostile_int(h,256):hostile_int(h,5))}

// A library with a few clips whose tracks and markers are broken in some way.
@(private="file")
hostile_library :: proc(h:^Hostile,lib:^Library) -> bool {
    if !library_init(lib,{max_keys=64,max_tracks=12,max_clips=5,max_markers=12}) {return false}
    keys:[dynamic]Keyframe
    defer delete(keys)
    for _ in 0..<hostile_int(h,6) {
        tracks:[3]Track_Desc
        markers:[3]Marker
        for &track in tracks {
            hostile_keys(h,&keys,hostile_int(h,6)!=0)
            track={target=u64(hostile_int(h,3)),property=hostile_property(h),slot=u8(hostile_int(h,2)),keys=keys[:]}
            _,_=clip_add(lib,{name=u64(hostile_int(h,4)),loop=hostile_loop(h),tracks={track}})
        }
        for &marker in markers {marker={time=hostile_time(h),id=u32(hostile_int(h,9))}}
        _,_=clip_add(lib,{name=u64(hostile_int(h,4)),loop=hostile_loop(h),markers=markers[:hostile_int(h,4)]})
    }
    return true
}

@(test)
hostile_numbers_through_the_tweens :: proc(t:^testing.T) {
    h:=Hostile{1}
    for _ in 0..<HOSTILE_ROUNDS {
        scalar:=tween_make(hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_ease(&h),hostile_f32(&h),hostile_loop(&h))
        vector:=tween_make(math.Vec3{hostile_f32(&h),0,0},math.Vec3{0,hostile_f32(&h),0},hostile_f32(&h),hostile_ease(&h),hostile_f32(&h),hostile_loop(&h))
        color:=tween_make_color(hostile_vec4(&h),hostile_vec4(&h),hostile_f32(&h),hostile_ease(&h),hostile_f32(&h),hostile_loop(&h))
        rotation:=tween_make(hostile_quat(&h),hostile_quat(&h),hostile_f32(&h),hostile_ease(&h),hostile_f32(&h),hostile_loop(&h))
        if hostile_int(&h,3)==0 {
            scalar.duration,scalar.delay,scalar.elapsed=hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)
            color.duration,color.delay,color.elapsed=hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)
        }
        for _ in 0..<4 {
            dt:=hostile_f32(&h)
            _=tween_advance(&scalar,dt);_=tween_advance(&vector,dt);_=tween_advance(&color,dt);_=tween_advance(&rotation,dt)
            _=tween_progress(scalar);_=tween_value(color)
        }
        tween_reset(&scalar);tween_reset(&color)
    }
}

@(test)
hostile_numbers_through_the_loops :: proc(t:^testing.T) {
    h:=Hostile{2}
    for _ in 0..<HOSTILE_ROUNDS {
        loop:=hostile_loop(&h)
        _,_=loop_time(loop,hostile_f32(&h),hostile_f32(&h))
        _=loop_wrap(hostile_f32(&h),hostile_f32(&h))
        _=loop_period(loop,hostile_f32(&h))
    }
}

@(test)
hostile_keyframes_through_the_tracks :: proc(t:^testing.T) {
    h:=Hostile{3}
    keys:[dynamic]Keyframe
    defer delete(keys)
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_keys(&h,&keys,hostile_int(&h,3)!=0)
        for _ in 0..<6 {
            _=track_evaluate(keys[:],hostile_property(&h),hostile_time(&h))
        }
        a,b,c,d:=hostile_quat(&h),hostile_quat(&h),hostile_quat(&h),hostile_quat(&h)
        _=squad(a,b,c,d,hostile_f32(&h));_=squad_control(a,b,c)
        v:=math.Vec3{hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)}
        _=quat_log(a);_=quat_exp(v)
        _=quat_align(hostile_vec4(&h),hostile_vec4(&h))
    }
}

@(test)
hostile_descriptions_through_the_library :: proc(t:^testing.T) {
    h:=Hostile{4}
    keys:[dynamic]Keyframe
    defer delete(keys)
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        desc:=Library_Desc{max_keys=hostile_size(&h),max_tracks=hostile_size(&h),max_clips=hostile_size(&h),max_markers=hostile_size(&h)}
        if library_init(&lib,desc) {
            for _ in 0..<6 {
                tracks:[4]Track_Desc
                markers:[5]Marker
                for &track in tracks {
                    hostile_keys(&h,&keys,hostile_int(&h,3)!=0)
                    track={target=u64(hostile_int(&h,3)),property=hostile_property(&h),slot=u8(hostile_int(&h,2)),keys=hostile_int(&h,5)==0?nil:keys[:]}
                }
                for &marker in markers {marker={time=hostile_time(&h),id=u32(hostile_int(&h,9))}}
                clip,_:=clip_add(&lib,{name=hostile_next(&h),loop=hostile_loop(&h),tracks=tracks[:hostile_int(&h,5)],markers=markers[:hostile_int(&h,6)]})
                forged:=Clip(hostile_int(&h,3)==0?hostile_next(&h):u64(hostile_int(&h,8)))
                _=clip_valid(&lib,clip);_=clip_valid(&lib,forged);_=clip_find(&lib,hostile_next(&h))
                _=clip_data(&lib,forged);_=clip_duration(&lib,forged)
                for track in clip_tracks(&lib,forged) {
                    _=clip_evaluate(&lib,track,hostile_time(&h));_=track_keys(&lib,track)
                }
                _=clip_markers(&lib,forged)
            }
            library_destroy(&lib)
        }
        library_destroy(&lib)
        zero:Library
        _,_=clip_add(&zero,{});_=clip_find(&zero,1);_=clip_data(&zero,1);_=clip_tracks(&zero,1);_=clip_markers(&zero,1);_=clip_duration(&zero,1)
        library_destroy(&zero)
    }
}

@(test)
hostile_tracks_from_another_library :: proc(t:^testing.T) {
    h:=Hostile{5}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b:Library
        if !hostile_library(&h,&a) {continue}
        if !hostile_library(&h,&b) {library_destroy(&a);continue}
        for clip in 1..=Clip(a.clip_count) {
            for track in clip_tracks(&a,clip) {
                _=clip_evaluate(&b,track,hostile_time(&h))
            }
        }
        library_destroy(&a);library_destroy(&b)
    }
}

@(test)
hostile_numbers_through_the_player :: proc(t:^testing.T) {
    h:=Hostile{6}
    events:[16]Event
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !hostile_library(&h,&lib) {continue}
        clip:=Clip(hostile_int(&h,3)==0?hostile_next(&h):u64(hostile_int(&h,lib.clip_count+2)))
        p:=player_make(clip,hostile_f32(&h),hostile_f32(&h))
        for _ in 0..<5 {
            switch hostile_int(&h,5) {
            case 0,1,2: _,_=player_advance(&lib,&p,hostile_int(&h,3)==0?hostile_f32(&h):hostile_time(&h),events[:hostile_int(&h,17)])
            case 3: player_restart(&lib,&p)
            case 4: _=player_time(&lib,p);_=player_normalized(&lib,p)
            }
        }
        if hostile_int(&h,4)==0 {
            p.time=hostile_f32(&h)
            _,_=player_advance(&lib,&p,hostile_f32(&h),events[:])
        }
        library_destroy(&lib)
    }
}

@(test)
hostile_spans_through_the_player_markers :: proc(t:^testing.T) {
    h:=Hostile{7}
    events:[16]Event
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !library_init(&lib,{max_keys=2,max_tracks=1,max_clips=1,max_markers=4}) {continue}
        markers:=[?]Marker{{0.5,1},{1,2},{0,3},{2,4}}
        clip,_:=clip_add(&lib,{loop=Loop(hostile_int(&h,3)),markers=markers[:hostile_int(&h,5)]})
        p:=player_make(clip,hostile_int(&h,2)==0?1:-1)
        p.time=hostile_int(&h,2)==0?0:hostile_f32(&h)
        _,_=player_advance(&lib,&p,hostile_int(&h,2)==0?1e30:-1e30,events[:])
        library_destroy(&lib)
    }
}

@(private="file")
finite :: proc(h:^Hostile) -> f32 {return f32(hostile_int(h,600)-100)/100}

@(test)
hostile_spans_through_the_root_motion :: proc(t:^testing.T) {
    h:=Hostile{8}
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !hostile_library(&h,&lib) {continue}
        clip:=Clip(hostile_int(&h,3)==0?hostile_next(&h):u64(hostile_int(&h,lib.clip_count+2)))
        _,_=clip_root_motion(&lib,clip,u64(hostile_int(&h,3)),finite(&h),finite(&h))
        p:=player_make(clip,finite(&h))
        p.time=finite(&h)
        _,_=player_root_motion(&lib,p,u64(hostile_int(&h,3)),finite(&h))
        library_destroy(&lib)
    }
}

@(test)
hostile_huge_spans_through_the_root_motion :: proc(t:^testing.T) {
    h:=Hostile{9}
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !library_init(&lib,{max_keys=8,max_tracks=2,max_clips=1,max_markers=1}) {continue}
        rotation:=[?]Keyframe{{time=0,value={0,0,0,1}},{time=1,value={0,0.7071,0,0.7071}}}
        position:=[?]Keyframe{{time=0,value={0,0,0,0}},{time=1,value={1,0,0,0}}}
        clip,_:=clip_add(&lib,{loop=.Loop,tracks={{target=1,property=.Rotation,keys=rotation[:]},{target=1,property=.Position,keys=position[:]}}})
        spans:=[?]f32{1e30,-1e30,1e12,-1e12,1e9,3e18,f32(0h7f800000)}
        span:=spans[hostile_int(&h,7)]
        _,_=clip_root_motion(&lib,clip,1,0,span)
        library_destroy(&lib)
    }
}

@(test)
hostile_weights_through_the_pose :: proc(t:^testing.T) {
    h:=Hostile{10}
    for _ in 0..<HOSTILE_ROUNDS {
        pose:Pose
        if pose_init(&pose,hostile_size(&h)) {
            lib:Library
            hostile_library(&h,&lib)
            for _ in 0..<30 {
                target:=u64(hostile_int(&h,4))
                switch hostile_int(&h,8) {
                case 0,1: _=pose_add(&pose,target,hostile_property(&h),u8(hostile_int(&h,3)),hostile_vec4(&h),hostile_f32(&h))
                case 2: _=pose_add_additive(&pose,target,hostile_property(&h),u8(hostile_int(&h,3)),hostile_vec4(&h),hostile_f32(&h))
                case 3:
                    p:=player_make(Clip(hostile_int(&h,lib.clip_count+2)),1,hostile_f32(&h))
                    p.time=hostile_time(&h)
                    pose_blend(&pose,&lib,p,hostile_f32(&h))
                case 4:
                    p:=player_make(Clip(hostile_int(&h,lib.clip_count+2)),1,hostile_f32(&h))
                    p.time=hostile_time(&h)
                    pose_blend_additive(&pose,&lib,p,hostile_time(&h),hostile_f32(&h))
                case 5:
                    _,_,_=pose_find(&pose,target,hostile_property(&h),u8(hostile_int(&h,3)))
                    _,_,_=pose_position(&pose,target);_,_,_=pose_scale(&pose,target);_,_,_=pose_rotation(&pose,target);_,_,_=pose_float(&pose,target,u8(hostile_int(&h,3)))
                case 6: for entry in pose.entries[:pose.count] {_=pose_entry_value(entry)}
                case 7: if hostile_int(&h,8)==0 {pose_clear(&pose)}
                }
            }
            library_destroy(&lib)
            pose_destroy(&pose)
        }
        pose_destroy(&pose)
        zero:Pose
        _=pose_add(&zero,1,.Float,0,{},1);_=pose_add_additive(&zero,1,.Float,0,{},1);_,_,_=pose_find(&zero,1,.Float);pose_clear(&zero)
        pose_destroy(&zero)
    }
}

@(test)
hostile_fades_through_the_fader :: proc(t:^testing.T) {
    h:=Hostile{11}
    events:[8]Event
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !hostile_library(&h,&lib) {continue}
        pose:Pose
        if !pose_init(&pose,16) {library_destroy(&lib);continue}
        fader:Fader
        for _ in 0..<20 {
            switch hostile_int(&h,5) {
            case 0,1: fader_play(&fader,Clip(hostile_int(&h,lib.clip_count+2)),hostile_f32(&h),hostile_f32(&h),hostile_ease(&h))
            case 2,3: _,_=fader_advance(&lib,&fader,hostile_time(&h),events[:hostile_int(&h,9)])
            case 4: pose_clear(&pose);fader_blend(&pose,&lib,fader);_=fader_fading(fader);_=fader_current_weight(fader)
                bones:[4]Bone_Blend;track_bones,references:[12]i32
                for &bone in track_bones {bone=i32(hostile_int(&h,8))-2}
                bones_fader_blend(bones[:hostile_int(&h,5)],track_bones[:hostile_int(&h,13)],&lib,fader)
                _=bones_blend_additive(bones[:],track_bones[:],&lib,fader.current,hostile_time(&h),hostile_f32(&h),Clip(hostile_int(&h,lib.clip_count+2)),references[:hostile_int(&h,13)])
                for bone in bones {_,_,_=bone_transform(bone,math.TRANSFORM_IDENTITY);_,_=bone_added_position(bone);_,_=bone_added_rotation(bone);_,_=bone_added_scale(bone)}
            }
        }
        for o in fader.outgoing[:fader.outgoing_count] {_=fade_out_weight(o)}
        pose_destroy(&pose)
        library_destroy(&lib)
    }
}

@(test)
hostile_time_through_a_track_of_one_key :: proc(t:^testing.T) {
    h:=Hostile{14}
    keys:[dynamic]Keyframe
    defer delete(keys)
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_keys(&h,&keys,true,true)
        resize(&keys,1)
        _=track_evaluate(keys[:],hostile_property(&h),hostile_time(&h))
    }
}

@(test)
hostile_skeletons_and_solvers_reject_invalid_inputs :: proc(t:^testing.T) {
    h:=Hostile{77}
    rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    parents:=[3]i32{-1,0,1};names:=[3]u64{1,2,3}
    out:[3]math.Transform;mask:[3]f32;links:[3]Pose_Link
    for _ in 0..<HOSTILE_ROUNDS {
        bone:=hostile_int(&h,3)
        saved:=rest[bone]
        rest[bone].position=hostile_vec4(&h).xyz
        rest[bone].rotation=hostile_quat(&h)
        parents[bone]=i32(hostile_int(&h,7)-2)
        skeleton:=Skeleton{parents[:],names[:],rest[:]}
        _=skeleton_validate(skeleton)
        _=skeleton_world(skeleton,rest[:],out[:])
        _=pose_world(parents[:],rest[:],out[:])
        links[bone]={i32(hostile_int(&h,7)-2),i32(hostile_int(&h,7)-2)}
        _,_=pose_hierarchy_prepare(parents[:],links[:])
        hierarchy:=Pose_Hierarchy{parents[:],links[:]}
        _=pose_world_branch(hierarchy,rest[:],out[:],hostile_int(&h,7)-2)
        _=pose_ik_apply(hierarchy,rest[:],out[:],hostile_int(&h,7)-2,hostile_int(&h,7)-2,hostile_int(&h,7)-2,{rest[0],rest[1],rest[2],false})
        _=pose_mask_branch(skeleton,hostile_int(&h,7)-2,hostile_f32(&h),mask[:])
        _=pose_layer(rest[:],rest[:],mask[:],hostile_f32(&h),out[:])
        _=pose_additive(rest[:],rest[:],rest[:],mask[:],hostile_f32(&h),out[:])
        _,_=two_bone_ik(rest[0],rest[1],rest[2],hostile_vec4(&h).xyz,hostile_vec4(&h).xyz,hostile_f32(&h))
        _,_=two_bone_pole_from_pose(rest[0],rest[1],rest[2],hostile_vec4(&h).xyz)
        _,_=look_at(rest[bone].rotation,hostile_vec4(&h).xyz,hostile_vec4(&h).xyz,hostile_f32(&h),hostile_f32(&h))
        _,_=rotation_limit(rest[bone].rotation,1,{hostile_vec4(&h).xyz,hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)})
        rest[bone]=saved
        parents[bone]=i32(bone)-1
    }
}

// Streams changed after they were checked, and sampled tracks that point anywhere: every read
// stays inside the library.
@(test)
hostile_streams_through_the_decoder :: proc(t:^testing.T) {
    h:=Hostile{23}
    keys:[3][48]Keyframe
    for k in 0..<48 {
        phase:=f32(k)/30
        keys[0][k]={time=phase,value={phase,phase*phase,1-phase,0}}
        keys[1][k]={time=phase,value=quat_vec4(math.quat_axis_angle({0,1,0},phase*3))}
        keys[2][k]={time=phase,value={phase*.5,0,0,0}}
    }
    still:=[1]Keyframe{{value={1,1,1,0}}}
    off:=[3]Keyframe{{time=0,value={1,0,0,0}},{time=.41,value={-3,0,0,0}},{time=1.3,value={2,0,0,0}}}
    lib:=make_library(t,keys=200,tracks=8,clips=2,markers=0);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks={{target=1,property=.Position,keys=keys[0][:]},{target=1,property=.Rotation,keys=keys[1][:]},{target=1,property=.Scale,keys=still[:]},{target=2,property=.Float,keys=keys[2][:]},{target=3,property=.Vector},{target=4,property=.Float,keys=off[:]}}})
    _,error:=library_compress(&lib);testing.expect_value(t,error,Compress_Error.None)
    testing.expect_value(t,clip_tracks(&lib,clip)[5].encoding,Key_Encoding.Sampled)
    for step in 0..=40 {
        time:=f32(step)/40*1.6
        testing.expect_value(t,clip_evaluate(&lib,clip_tracks(&lib,clip)[5],time),track_evaluate(off[:],.Float,time))
    }
    saved:=make([]u8,len(lib.streams));defer delete(saved)
    copy(saved,lib.streams)
    values:[8]math.Vec4
    for _ in 0..<HOSTILE_ROUNDS {
        for _ in 0..<1+hostile_int(&h,4) {lib.streams[hostile_int(&h,len(lib.streams))]=u8(hostile_next(&h))}
        time:=hostile_time(&h)
        _=clip_sample(&lib,clip,time,values[:])
        for track in clip_tracks(&lib,clip) {_=clip_evaluate(&lib,track,time)}
        stray:=Track{property=Property(hostile_int(&h,5)),encoding=.Sampled,first=hostile_u32(&h),count=hostile_u32(&h)}
        _=clip_evaluate(&lib,stray,time)
        if hostile_int(&h,3)==0 {lib.clips[0].stream,lib.clips[0].stream_bytes=hostile_u32(&h),hostile_u32(&h)}
        _=clip_sample(&lib,clip,time,values[:])
        copy(lib.streams,saved)
        lib.clips[0].stream,lib.clips[0].stream_bytes=0,u32(lib.stream_bytes)
    }
}
