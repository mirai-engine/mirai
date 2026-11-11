package mirai_anim

import "mirai:std/base"
import "core:testing"
import math "mirai:std/math"

// Every public procedure is handed durations, times and speeds that are zero,
// negative, NaN or infinite, clips, tracks and keyframes that are empty,
// unsorted or from another library, and states, parameters and handles out of
// range. A time stays inside its clip, a handle that is not of the library
// reads as nothing, an index out of range is refused, and nothing stays
// allocated.

@(private="file") HOSTILE_ROUNDS :: #config(ANIM_HOSTILE_ROUNDS,400)


@(private="file")
hostile_time :: proc(h:^base.Hostile) -> f32 {
    if base.hostile_int(h,3)==0 {return base.hostile_f32(h)}
    return f32(base.hostile_int(h,600)-100)/100
}

@(private="file")
hostile_u32 :: proc(h:^base.Hostile) -> u32 {
    switch base.hostile_int(h,8) {
    case 0: return 0
    case 1: return max(u32)
    case 2: return 1
    }
    return u32(base.hostile_int(h,100))
}

@(private="file")
hostile_size :: proc(h:^base.Hostile) -> int {
    switch base.hostile_int(h,12) {
    case 0: return 0
    case 1: return -1
    case 2: return 1
    case 3: return min(int)
    case 4: return 1<<50
    case 5: return 1<<52
    case 6: return 3
    }
    return base.hostile_int(h,60)+1
}

@(private="file")
hostile_vec4 :: proc(h:^base.Hostile) -> math.Vec4 {return {base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h),base.hostile_f32(h)}}

@(private="file")
hostile_quat :: proc(h:^base.Hostile) -> math.Quat {
    v:=hostile_vec4(h)
    return quaternion(w=v.w,x=v.x,y=v.y,z=v.z)
}

@(private="file")
hostile_ease :: proc(h:^base.Hostile) -> math.Ease {return math.Ease(base.hostile_int(h,4)==0?base.hostile_int(h,256):base.hostile_int(h,31))}

@(private="file")
hostile_loop :: proc(h:^base.Hostile) -> Loop {return Loop(base.hostile_int(h,5)==0?base.hostile_int(h,256):base.hostile_int(h,3))}

@(private="file")
hostile_keys :: proc(h:^base.Hostile,keys:^[dynamic]Keyframe,sorted:bool,lonely:=false) {
    clear(keys)
    n:=base.hostile_int(h,8)
    if n==1 && !lonely {n=2}
    time:f32
    for _ in 0..<n {
        time=sorted?time+f32(base.hostile_int(h,4))/2:hostile_time(h)
        key:=Keyframe{time=time,value=hostile_vec4(h),ease=hostile_ease(h),interpolation=Interpolation(base.hostile_int(h,5)==0?base.hostile_int(h,256):base.hostile_int(h,3)),tangents=base.hostile_int(h,2)==0}
        key.in_slope,key.out_slope=hostile_vec4(h),hostile_vec4(h)
        append(keys,key)
    }
}

@(private="file")
hostile_property :: proc(h:^base.Hostile) -> Property {return Property(base.hostile_int(h,6)==0?base.hostile_int(h,256):base.hostile_int(h,5))}

// A library with a few clips whose tracks and markers are broken in some way.
@(private="file")
hostile_library :: proc(h:^base.Hostile,lib:^Library) -> bool {
    if !library_init(lib,{max_keys=64,max_tracks=12,max_clips=5,max_markers=12}) {return false}
    keys:[dynamic]Keyframe
    defer delete(keys)
    for _ in 0..<base.hostile_int(h,6) {
        tracks:[3]Track_Desc
        markers:[3]Marker
        for &track in tracks {
            hostile_keys(h,&keys,base.hostile_int(h,6)!=0)
            track={target=u64(base.hostile_int(h,3)),property=hostile_property(h),slot=u8(base.hostile_int(h,2)),keys=keys[:]}
            _,_=clip_add(lib,{name=u64(base.hostile_int(h,4)),loop=hostile_loop(h),tracks={track}})
        }
        for &marker in markers {marker={time=hostile_time(h),id=u32(base.hostile_int(h,9))}}
        _,_=clip_add(lib,{name=u64(base.hostile_int(h,4)),loop=hostile_loop(h),markers=markers[:base.hostile_int(h,4)]})
    }
    return true
}

// Equal, or both NaN.
@(private="file")
same4 :: proc(a,b:math.Vec4) -> bool {
    for i in 0..<4 {if a[i]!=b[i] && (a[i]==a[i] || b[i]==b[i]) {return false}}
    return true
}

@(private="file")
numbers :: proc(values:..f32) -> bool {
    for value in values {if value-value!=0 {return false}}
    return true
}

// An easing that keeps a progress from 0 to 1 inside 0..1: every one before the back curves, and the numbers of none.
@(private="file")
hostile_ease_bounded :: proc(ease:math.Ease) -> bool {return ease<.Back_In || int(ease)>=len(math.Ease)}

@(test)
hostile_numbers_through_the_loops :: proc(t:^testing.T) {
    h:=base.Hostile{2}
    for _ in 0..<HOSTILE_ROUNDS {
        loop:=hostile_loop(&h)
        duration,time,period:=base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h)
        clip_time,finished:=loop_time(loop,duration,time)
        wrapped:=loop_wrap(time,period)
        testing.expect(t,loop_period(loop,duration)==(duration if loop==.Loop else 2*duration if loop==.Ping_Pong else 0) || duration!=duration,"The period of a loop is one or two lengths of its duration, and none for the others")
        if duration<=0 || int(loop)>=len(Loop) {testing.expect(t,clip_time==0 && finished,"A playback without a length, or of a loop that does not exist, is at 0 and over")}
        if !numbers(duration,time,period) {continue}
        testing.expectf(t,!(duration>0) || (clip_time>=0 && clip_time<=duration),"The time %v inside a clip of %v left it: %v",time,duration,clip_time)
        testing.expectf(t,!(period>0) || (wrapped>=0 && wrapped<period),"The time %v folded into %v left it: %v",time,period,wrapped)
    }
}

@(test)
hostile_keyframes_through_the_tracks :: proc(t:^testing.T) {
    h:=base.Hostile{3}
    keys:[dynamic]Keyframe
    defer delete(keys)
    for _ in 0..<HOSTILE_ROUNDS {
        sorted:=base.hostile_int(&h,3)!=0
        hostile_keys(&h,&keys,sorted,base.hostile_int(&h,4)==0)
        property:=hostile_property(&h)
        for _ in 0..<6 {
            time:=hostile_time(&h)
            value:=track_evaluate(keys[:],property,time)
            if len(keys)==0 {
                testing.expect(t,value=={},"A track without keys has a value")
                continue
            }
            if !sorted {continue}
            first,last:=keys[0].time,keys[len(keys)-1].time
            // Outside its keys, and at a NaN time, a track holds one value: that of an end.
            beyond:=first-1 if !(time>first) else last+1
            if !(time>first) || time>=last {
                if !testing.expectf(t,same4(value,track_evaluate(keys[:],property,beyond)),"A track of %d keys from %v to %v does not hold its end at %v",len(keys),first,last,time) {return}
            }
        }
    }
}

@(test)
hostile_descriptions_through_the_library :: proc(t:^testing.T) {
    memory:base.Hostile_Memory
    context.allocator=base.hostile_memory_begin(&memory)
    defer {
        leaked,bad_frees:=base.hostile_memory_end(&memory)
        testing.expectf(t,leaked==0 && bad_frees==0,"%d allocations were left and %d frees were of nothing",leaked,bad_frees)
    }
    h:=base.Hostile{4}
    keys:[dynamic]Keyframe
    defer delete(keys)
    for _ in 0..<HOSTILE_ROUNDS {
        if testing.failed(t) {return}
        lib:Library
        desc:=Library_Desc{max_keys=hostile_size(&h),max_tracks=hostile_size(&h),max_clips=hostile_size(&h),max_markers=hostile_size(&h)}
        fits:=desc.max_keys>0 && desc.max_tracks>0 && desc.max_clips>0 && desc.max_markers>=0 && max(desc.max_keys,desc.max_tracks,desc.max_clips,desc.max_markers)<=61
        made:=library_init(&lib,desc)
        testing.expect(t,made==fits && (made || (len(lib.keys)==0 && len(lib.clips)==0)),"The library takes the sizes it can hold and has nothing on the others")
        if made {
            added:=0
            for _ in 0..<6 {
                tracks:[4]Track_Desc
                markers:[5]Marker
                for &track in tracks {
                    hostile_keys(&h,&keys,base.hostile_int(&h,3)!=0)
                    track={target=u64(base.hostile_int(&h,3)),property=hostile_property(&h),slot=u8(base.hostile_int(&h,2)),keys=base.hostile_int(&h,5)==0?nil:keys[:]}
                }
                for &marker in markers {marker={time=hostile_time(&h),id=u32(base.hostile_int(&h,9))}}
                given:=tracks[:base.hostile_int(&h,5)]
                clip,error:=clip_add(&lib,{name=base.hostile_next(&h),loop=hostile_loop(&h),tracks=given,markers=markers[:base.hostile_int(&h,6)]})
                if error==.None {added+=1}
                testing.expect(t,int(clip)==(added if error==.None else 0) && lib.clip_count==added,"A clip gets the next handle, or none with the reason it was refused")
                testing.expect(t,error!=.None || len(clip_tracks(&lib,clip))==len(given),"A clip has the tracks it was given")
                forged:=Clip(base.hostile_int(&h,3)==0?base.hostile_next(&h):u64(base.hostile_int(&h,8)))
                known:=forged!=0 && u64(forged)<=u64(added)
                found:=clip_find(&lib,base.hostile_next(&h))
                testing.expect(t,clip_valid(&lib,forged)==known && (found==0 || clip_valid(&lib,found)),"Only the clips that were added are of the library")
                if !known {
                    testing.expect(t,clip_data(&lib,forged)=={} && clip_duration(&lib,forged)==0 && len(clip_tracks(&lib,forged))==0 && len(clip_markers(&lib,forged))==0,"A clip that is not of the library reads as nothing")
                }
                for track in clip_tracks(&lib,forged) {
                    _=clip_evaluate(&lib,track,hostile_time(&h))
                    testing.expect(t,len(track_keys(&lib,track))==int(track.count),"A track of the library has its keys")
                }
                stored:=clip_markers(&lib,forged)
                for i in 1..<len(stored) {
                    testing.expect(t,!(stored[i].time<stored[i-1].time),"The markers of a clip are not sorted by time")
                }
            }
            library_destroy(&lib)
        }
        library_destroy(&lib)
        zero:Library
        clip,error:=clip_add(&zero,{})
        testing.expect(t,clip==0 && error!=.None && clip_find(&zero,1)==0 && clip_data(&zero,1)=={} && len(clip_tracks(&zero,1))==0 && len(clip_markers(&zero,1))==0 && clip_duration(&zero,1)==0,"A zeroed library has no clips")
        library_destroy(&zero)
    }
}

@(test)
hostile_tracks_from_another_library :: proc(t:^testing.T) {
    h:=base.Hostile{5}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b:Library
        if !hostile_library(&h,&a) {continue}
        if !hostile_library(&h,&b) {library_destroy(&a);continue}
        for clip in 1..=Clip(a.clip_count) {
            for track in clip_tracks(&a,clip) {
                // A track of another library reads the keys that library has there, or none: never past them.
                inside:=int(track.first)+int(track.count)<=b.key_count
                keys:=track_keys(&b,track)
                testing.expect(t,len(keys)==(int(track.count) if inside else 0),"A track reads keys that its library does not have")
                value:=clip_evaluate(&b,track,hostile_time(&h))
                testing.expect(t,inside && track.count>0 || value=={},"A track without keys in its library has a value")
            }
        }
        library_destroy(&a);library_destroy(&b)
    }
}

// The time of a player is inside its clip, and a player of no clip is at 0.
@(private="file")
hostile_player_inside :: proc(lib:^Library,p:Player) -> bool {
    time,duration:=player_time(lib,p),clip_duration(lib,p.clip)
    if !clip_valid(lib,p.clip) {return time==0}
    if p.time!=p.time || duration!=duration {return true}
    return time>=0 && time<=max(duration,0)
}

@(test)
hostile_numbers_through_the_player :: proc(t:^testing.T) {
    h:=base.Hostile{6}
    events:[16]Event
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !hostile_library(&h,&lib) {continue}
        clip:=Clip(base.hostile_int(&h,3)==0?base.hostile_next(&h):u64(base.hostile_int(&h,lib.clip_count+2)))
        p:=player_make(clip,base.hostile_f32(&h),base.hostile_f32(&h))
        for _ in 0..<5 {
            switch base.hostile_int(&h,5) {
            case 0,1,2:
                room:=events[:base.hostile_int(&h,17)]
                written,dropped:=player_advance(&lib,&p,base.hostile_int(&h,3)==0?base.hostile_f32(&h):hostile_time(&h),room)
                testing.expect(t,written>=0 && written<=len(room) && dropped>=0 && (clip_valid(&lib,clip) || written+dropped==0),"A player writes the events that fit, and none without a clip")
                for event in room[:written] {testing.expect(t,event.clip==clip,"An event is of another clip")}
            case 3: player_restart(&lib,&p)
            case 4: _=player_normalized(&lib,p)
            }
            if !testing.expectf(t,hostile_player_inside(&lib,p),"A player left its clip: %v of %v",p,clip_data(&lib,p.clip)) {break}
        }
        if base.hostile_int(&h,4)==0 {
            p.time=base.hostile_f32(&h)
            _,_=player_advance(&lib,&p,base.hostile_f32(&h),events[:])
            testing.expectf(t,hostile_player_inside(&lib,p),"A player set to any time left its clip: %v of %v",p,clip_data(&lib,p.clip))
        }
        library_destroy(&lib)
    }
}

@(test)
hostile_spans_through_the_player_markers :: proc(t:^testing.T) {
    h:=base.Hostile{7}
    events:[16]Event
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !library_init(&lib,{max_keys=2,max_tracks=1,max_clips=1,max_markers=4}) {continue}
        markers:=[?]Marker{{0.5,1,0},{1,2,0},{0,3,0},{2,4,0}}
        given:=markers[:base.hostile_int(&h,5)]
        clip,_:=clip_add(&lib,{loop=Loop(base.hostile_int(&h,3)),markers=given})
        p:=player_make(clip,base.hostile_int(&h,2)==0?1:-1)
        p.time=base.hostile_int(&h,2)==0?0:base.hostile_f32(&h)
        written,dropped:=player_advance(&lib,&p,base.hostile_int(&h,2)==0?1e30:-1e30,events[:])
        testing.expectf(t,written>=0 && written<=len(events) && dropped>=0 && (len(given)>0 || written+dropped==0),"A span of any length writes the events that fit, and none without markers: %d written and %d dropped of %d markers",written,dropped,len(given))
        for event in events[:written] {
            testing.expect(t,event.clip==clip && event.id>=1 && event.id<=4,"An event is not of a marker of the clip")
        }
        testing.expectf(t,hostile_player_inside(&lib,p),"A player left its clip after a span of any length: %v of %v",p,clip_data(&lib,clip))
        library_destroy(&lib)
    }
}

@(private="file")
finite :: proc(h:^base.Hostile) -> f32 {return f32(base.hostile_int(h,600)-100)/100}

// A root motion is a movement of numbers and a rotation, the identity when nothing turns.
@(private="file")
hostile_motion :: proc(moved:math.Vec3,turned:math.Quat) -> bool {
    return numbers(moved.x,moved.y,moved.z) && (abs(abs(turned)-1)<1e-3)
}

@(test)
hostile_spans_through_the_root_motion :: proc(t:^testing.T) {
    h:=base.Hostile{8}
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !hostile_library(&h,&lib) {continue}
        clip:=Clip(base.hostile_int(&h,3)==0?base.hostile_next(&h):u64(base.hostile_int(&h,lib.clip_count+2)))
        moved,turned:=clip_root_motion(&lib,clip,u64(base.hostile_int(&h,3)),finite(&h),finite(&h))
        testing.expect(t,clip_valid(&lib,clip) || (moved=={} && turned==1),"A clip that is not of the library moves its root")
        p:=player_make(clip,finite(&h))
        p.time=finite(&h)
        moved,turned=player_root_motion(&lib,p,u64(base.hostile_int(&h,3)),finite(&h))
        testing.expect(t,clip_valid(&lib,clip) || (moved=={} && turned==1),"A player of no clip moves its root")
        library_destroy(&lib)
    }
}

@(test)
hostile_huge_spans_through_the_root_motion :: proc(t:^testing.T) {
    h:=base.Hostile{9}
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !library_init(&lib,{max_keys=8,max_tracks=2,max_clips=1,max_markers=1}) {continue}
        rotation:=[?]Keyframe{{time=0,value={0,0,0,1}},{time=1,value={0,0.7071,0,0.7071}}}
        position:=[?]Keyframe{{time=0,value={0,0,0,0}},{time=1,value={1,0,0,0}}}
        clip,_:=clip_add(&lib,{loop=.Loop,tracks={{target=1,property=.Rotation,keys=rotation[:]},{target=1,property=.Position,keys=position[:]}}})
        spans:=[?]f32{1e30,-1e30,1e12,-1e12,1e9,3e18,f32(0h7f800000)}
        span:=spans[base.hostile_int(&h,7)]
        moved,turned:=clip_root_motion(&lib,clip,1,0,span)
        // The clip lasts 1 second: past 2^62 passes, or without a number of them, nothing moves.
        still:=abs(span)>=1e30
        testing.expectf(t,hostile_motion(moved,turned) && (!still || (moved=={} && turned==1)),"A span of %v moved the root by %v and turned it by %v",span,moved,turned)
        library_destroy(&lib)
    }
}

@(test)
hostile_fades_through_the_fader :: proc(t:^testing.T) {
    h:=base.Hostile{11}
    events:[8]Event
    for _ in 0..<HOSTILE_ROUNDS {
        lib:Library
        if !hostile_library(&h,&lib) {continue}
        fader:Fader
        for _ in 0..<20 {
            switch base.hostile_int(&h,5) {
            case 0,1: fader_play(&fader,Clip(base.hostile_int(&h,lib.clip_count+2)),base.hostile_f32(&h),base.hostile_f32(&h),hostile_ease(&h))
            case 2,3:
                room:=events[:base.hostile_int(&h,9)]
                written,dropped:=fader_advance(&lib,&fader,hostile_time(&h),room)
                testing.expect(t,written>=0 && written<=len(room) && dropped>=0,"A fader writes more events than fit")
            case 4:
                bones:[4]Bone_Blend;track_bones,references:[12]i32
                for &bone in track_bones {bone=i32(base.hostile_int(&h,8))-2}
                bones_fader_blend(bones[:base.hostile_int(&h,5)],track_bones[:base.hostile_int(&h,13)],&lib,fader)
                _=bones_blend_additive(bones[:],track_bones[:],&lib,fader.current,hostile_time(&h),base.hostile_f32(&h),Clip(base.hostile_int(&h,lib.clip_count+2)),references[:base.hostile_int(&h,13)])
                for bone in bones {_,_,_=bone_transform(bone,math.TRANSFORM_IDENTITY);_,_=bone_added_position(bone);_,_=bone_added_rotation(bone);_,_=bone_added_scale(bone)}
            }
            if !testing.expect(t,fader.outgoing_count>=0 && fader.outgoing_count<=FADER_OUTGOING && fader_fading(fader)==(fader.outgoing_count>0),"A fader has more clips fading out than it holds") {break}
            // With numbers for its times and an easing that stays in 0..1, every weight of a fade is a share.
            weight:=fader_current_weight(fader)
            testing.expect(t,!numbers(fader.duration,fader.elapsed) || !hostile_ease_bounded(fader.ease) || (weight>=0 && weight<=1),"The weight of the clip that fades in left 0..1")
            for o in fader.outgoing[:max(fader.outgoing_count,0)] {
                weight=fade_out_weight(o)
                testing.expect(t,!numbers(o.duration,o.elapsed,o.weight) || !hostile_ease_bounded(o.ease) || !(o.weight>=0 && o.weight<=1) || (weight>=0 && weight<=1),"The weight of a clip that fades out left 0..1")
            }
        }
        library_destroy(&lib)
    }
}

@(test)
hostile_skeletons_and_solvers_reject_invalid_inputs :: proc(t:^testing.T) {
    h:=base.Hostile{77}
    rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY}
    parents:=[3]i32{-1,0,1};names:=[3]u64{1,2,3}
    out:[3]math.Transform;mask:[3]f32;links:[3]Pose_Link
    for _ in 0..<HOSTILE_ROUNDS {
        bone:=base.hostile_int(&h,3)
        saved:=rest[bone]
        rest[bone].position=hostile_vec4(&h).xyz
        rest[bone].rotation=hostile_quat(&h)
        parents[bone]=i32(base.hostile_int(&h,7)-2)
        skeleton:=Skeleton{parents[:],names[:],rest[:]}
        // A parent that is not an earlier bone, or -1, is not a parent.
        ordered:=parents[bone]>=-1 && parents[bone]<i32(bone)
        testing.expect(t,ordered || (!skeleton_validate(skeleton) && !skeleton_world(skeleton,rest[:],out[:]) && !pose_world(parents[:],rest[:],out[:])),"A skeleton whose parent is not an earlier bone was taken")
        links[bone]={i32(base.hostile_int(&h,7)-2),i32(base.hostile_int(&h,7)-2)}
        _,prepared:=pose_hierarchy_prepare(parents[:],links[:])
        testing.expect(t,ordered || !prepared,"A hierarchy whose parent is not an earlier bone was prepared")
        hierarchy:=Pose_Hierarchy{parents[:],links[:]}
        outside :: proc(index:int) -> bool {return index<0 || index>=3}
        branch:=base.hostile_int(&h,7)-2
        testing.expect(t,!outside(branch) || !pose_world_branch(hierarchy,rest[:],out[:],branch),"A branch from a bone out of range was computed")
        chain:=[3]int{base.hostile_int(&h,7)-2,base.hostile_int(&h,7)-2,base.hostile_int(&h,7)-2}
        applied:=pose_ik_apply(hierarchy,rest[:],out[:],chain[0],chain[1],chain[2],{rest[0],rest[1],rest[2],false})
        testing.expect(t,!applied || !(outside(chain[0]) || outside(chain[1]) || outside(chain[2])),"A solved chain with a bone out of range was applied")
        masked:=base.hostile_int(&h,7)-2
        testing.expect(t,!outside(masked) || !pose_mask_branch(skeleton,masked,base.hostile_f32(&h),mask[:]),"A mask from a bone out of range was written")
        solved,reaches:=two_bone_ik(rest[0],rest[1],rest[2],hostile_vec4(&h).xyz,hostile_vec4(&h).xyz,base.hostile_f32(&h),{base.hostile_f32(&h),base.hostile_f32(&h)})
        for joint in ([3]math.Transform{solved.root,solved.joint,solved.end}) {
            testing.expect(t,!reaches || (numbers(joint.position.x,joint.position.y,joint.position.z) && numbers(abs(joint.rotation))),"A solved chain is not of numbers")
        }
        pole,poled:=two_bone_pole_from_pose(rest[0],rest[1],rest[2],hostile_vec4(&h).xyz)
        testing.expect(t,!poled || numbers(pole.x,pole.y,pole.z),"The pole of a pose is not of numbers")
        looked,looks:=look_at(rest[bone].rotation,hostile_vec4(&h).xyz,hostile_vec4(&h).xyz,base.hostile_f32(&h),base.hostile_f32(&h),hostile_vec4(&h).xyz)
        limited,limits:=rotation_limit(rest[bone].rotation,1,{hostile_vec4(&h).xyz,base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h)})
        testing.expect(t,(!looks || numbers(abs(looked))) && (!limits || numbers(abs(limited))),"A rotation that was solved is not of numbers")
        rest[bone]=saved
        parents[bone]=i32(bone)-1
    }
}

// Streams changed after they were checked, and sampled tracks that point anywhere: every read
// stays inside the library.
@(test)
hostile_streams_through_the_decoder :: proc(t:^testing.T) {
    h:=base.Hostile{23}
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
        for _ in 0..<1+base.hostile_int(&h,4) {lib.streams[base.hostile_int(&h,len(lib.streams))]=u8(base.hostile_next(&h))}
        time:=hostile_time(&h)
        _=clip_sample(&lib,clip,time,values[:])
        for track in clip_tracks(&lib,clip) {_=clip_evaluate(&lib,track,time)}
        stray:=Track{property=Property(base.hostile_int(&h,5)),encoding=.Sampled,first=hostile_u32(&h),count=hostile_u32(&h)}
        _=clip_evaluate(&lib,stray,time)
        if base.hostile_int(&h,3)==0 {lib.clips[0].stream,lib.clips[0].stream_bytes=hostile_u32(&h),hostile_u32(&h)}
        _=clip_sample(&lib,clip,time,values[:])
        copy(lib.streams,saved)
        lib.clips[0].stream,lib.clips[0].stream_bytes=0,u32(lib.stream_bytes)
    }
}
