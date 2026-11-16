package mirai_anim

import "base:runtime"
import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

// The farthest a shell point of a chain of bones moves between the exact keys and the library,
// over `steps` times of the clip. Bone b has Position, Rotation and Scale tracks 3b..3b+2 and
// is the child of bone b-1.
@(private)
compress_chain_error :: proc(lib:^Library,clip:Clip,keys:[][]Keyframe,steps:int,shell:f32) -> (worst:f32) {
    tracks:=clip_tracks(lib,clip)
    duration:=clip_duration(lib,clip)
    for step in 0..=steps {
        time:=f32(step)/f32(steps)*duration
        exact,decoded:=math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY
        for b in 0..<len(tracks)/3 {
            local_exact:=math.Transform{track_evaluate(keys[3*b][:],.Position,time).xyz,linalg.normalize0(vec4_quat(track_evaluate(keys[3*b+1][:],.Rotation,time))),track_evaluate(keys[3*b+2][:],.Scale,time).xyz}
            local_decoded:=math.Transform{clip_evaluate(lib,tracks[3*b],time).xyz,linalg.normalize0(vec4_quat(clip_evaluate(lib,tracks[3*b+1],time))),clip_evaluate(lib,tracks[3*b+2],time).xyz}
            exact,decoded=math.transform_compose(exact,local_exact),math.transform_compose(decoded,local_decoded)
            for point in ([2]math.Vec3{{shell,0,0},{0,shell,0}}) {
                worst=max(worst,linalg.length(exact.position+math.quat_rotate(exact.rotation,point)-decoded.position-math.quat_rotate(decoded.rotation,point*decoded.scale/exact.scale)))
            }
        }
    }
    return
}

@(test)
compressed_chain_keeps_clip_data_and_moves_shell_points_within_precision :: proc(t:^testing.T) {
    BONES :: 4
    COUNT :: 61
    keys:[BONES*3][COUNT]Keyframe
    tracks:[BONES*3]Track_Desc
    slices:[BONES*3][]Keyframe
    for &track,i in tracks {
        b,property:=i/3,Property(i%3)
        track={target=u64(b+11),property=property,keys=keys[i][:]}
        slices[i]=keys[i][:]
        for &key,k in keys[i] {
            phase:=f32(k)/f32(COUNT-1);s,c:=cmath.sincos(phase*math.TAU+f32(b))
            key.time=phase*2
            switch property {
            case .Position:key.value={.3+s*.02*f32(b),.25,c*.01,0}
            case .Rotation:key.value=quat_vec4(math.quat_axis_angle(linalg.normalize(math.Vec3{1,f32(b),.5}),s*.9));if k%4==1 {key.value=-key.value}
            case .Scale:key.value={1,1,1,0}
            case .Float,.Vector:
            }
        }
    }
    lib:=make_library(t,keys=COUNT*BONES*3,tracks=BONES*3,clips=2,markers=2);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{name=73,loop=.Once,tracks=tracks[:],markers={{time=1.1,id=17},{time=.2,id=11}}})
    original:=clip_data(&lib,clip);lib.clips[1]=original;lib.clips[1].loop=.Loop;lib.clip_count=2
    parents:[BONES*3]i32
    for &parent,i in parents {parent=i32(i/3*3-3) if i>=3 else -1}
    stats,error:=library_compress(&lib,parents[:])
    testing.expect_value(t,error,Compress_Error.None)
    testing.expectf(t,stats.resident_bytes<stats.raw_bytes && stats.sampled_tracks==BONES*2 && stats.default_tracks==BONES,"%v",stats)
    compressed:=clip_data(&lib,clip)
    testing.expect(t,compressed.stream_bytes>0)
    compressed.stream,compressed.stream_bytes=0,0
    testing.expect_value(t,compressed,original)
    testing.expect(t,clip_data(&lib,2).loop==.Loop && clip_tracks(&lib,clip)[0]==clip_tracks(&lib,2)[0])
    testing.expect_value(t,clip_markers(&lib,clip)[0],Marker{time=.2,id=11})
    for track,i in clip_tracks(&lib,clip) {testing.expectf(t,track.encoding==.Sampled && track.target==u64(i/3+11),"track %d: %v",i,track)}
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=runtime.nil_allocator()
    worst:=compress_chain_error(&lib,clip,slices[:],1200,COMPRESS_DEFAULT.shell)
    context=saved
    testing.expect(t,worst<=COMPRESS_DEFAULT.precision*1.05 && stats.error<=COMPRESS_DEFAULT.precision && worst>0)
    _,refused:=clip_add(&lib,{})
    testing.expect_value(t,refused,Clip_Error.Prepared)
    _,error=library_compress(&lib);testing.expect_value(t,error,Compress_Error.Prepared)
}

@(test)
compressed_clip_is_measured_on_the_rest_pose_of_its_skeleton :: proc(t:^testing.T) {
    // Bones in centimeters under a root scaled to meters that the clip does not move.
    COUNT :: 61
    hips,leg:[COUNT]Keyframe
    hips_at:=[1]Keyframe{{value={0,100,0,0}}}
    leg_at:=[1]Keyframe{{value={0,-50,0,0}}}
    for k in 0..<COUNT {
        phase:=f32(k)/30;s:=cmath.sin(phase*5)
        hips[k]={time=phase,value=quat_vec4(math.quat_axis_angle({1,0,0},s*.6))}
        leg[k]={time=phase,value=quat_vec4(math.quat_axis_angle({1,0,0},s*s*.9))}
    }
    tracks:=[4]Track_Desc{{target=2,property=.Position,keys=hips_at[:]},{target=2,property=.Rotation,keys=hips[:]},{target=3,property=.Position,keys=leg_at[:]},{target=3,property=.Rotation,keys=leg[:]}}
    parents:=[4]i32{-1,-1,1,1}
    skeleton:=Skeleton{parents={-1,0,1},names={1,2,3},rest={{{},1,{.01,.01,.01}},{{0,100,0},1,{1,1,1}},{{0,-50,0},1,{1,1,1}}}}
    bytes:[2]int
    for with_skeleton,side in ([2]bool{false,true}) {
        lib:=make_library(t,keys=2*COUNT+2,tracks=4,clips=1,markers=0);defer library_destroy(&lib)
        clip,_:=clip_add(&lib,{tracks=tracks[:]})
        stats,error:=library_compress(&lib,parents[:],{skeleton} if with_skeleton else nil)
        testing.expect_value(t,error,Compress_Error.None)
        bytes[side]=stats.resident_bytes
        if !with_skeleton {continue}
        testing.expect(t,stats.error<=COMPRESS_DEFAULT.precision && stats.raw_tracks==0)
        worst:f32
        for step in 0..=600 {
            time:=f32(step)/300
            exact,decoded:=skeleton.rest[0],skeleton.rest[0]
            for b in 0..<2 {
                keys:=hips[:] if b==0 else leg[:]
                local:=skeleton.rest[b+1]
                exact=math.transform_compose(exact,{local.position,vec4_quat(track_evaluate(keys,.Rotation,time)),local.scale})
                decoded=math.transform_compose(decoded,{clip_evaluate(&lib,clip_tracks(&lib,clip)[2*b],time).xyz,vec4_quat(clip_evaluate(&lib,clip_tracks(&lib,clip)[2*b+1],time)),local.scale})
                for point in ([2]math.Vec3{{.03,0,0},{0,.03,0}}) {worst=max(worst,linalg.length(exact.position+math.quat_rotate(exact.rotation,point)-decoded.position-math.quat_rotate(decoded.rotation,point)))}
            }
        }
        testing.expectf(t,worst<=COMPRESS_DEFAULT.precision*1.05,"worst %v",worst)
    }
    // Measured in meters, the clip needs fewer bits than in the centimeters of its tracks.
    testing.expectf(t,bytes[1]<bytes[0],"%v",bytes)
}

@(test)
compressed_library_keeps_keys_that_samples_would_not_follow :: proc(t:^testing.T) {
    cubic:=[3]Keyframe{key(0,0,.Cubic_Spline),key(1,1,.Cubic_Spline),key(2,0,.Cubic_Spline)}
    for &key in cubic {key.tangents=true;key.in_slope={-2,0,0,0};key.out_slope={3,0,0,0}}
    eased:=[2]Keyframe{key(0,0),key(1,3,.Linear,.Back_Out)}
    step:=[3]Keyframe{key(0,1),key(1,3,.Step),key(2,2,.Step)}
    spline:=[3]Keyframe{rot_key(0,1,.Cubic),rot_key(1,math.quat_axis_angle({0,1,0},.4),.Cubic),rot_key(2,math.quat_axis_angle({0,1,0},.8),.Cubic)}
    // Linear keys off the grid of the others: the stream holds them as they are.
    off:=[4]Keyframe{key(0,0),key(.37,2),key(1.13,-1),key(2,4)}
    turn:=[3]Keyframe{rot_key(0,1),rot_key(.7,math.quat_axis_angle({0,1,0},2.5)),rot_key(1.9,math.quat_axis_angle({1,0,0},-1))}
    desc:=[6]Track_Desc{{property=.Float,keys=cubic[:]},{property=.Float,keys=eased[:]},{property=.Float,keys=step[:]},{target=3,property=.Rotation,keys=spline[:]},{target=4,property=.Position,keys=off[:]},{target=4,property=.Rotation,keys=turn[:]}}
    for &k in off {k.value={k.value.x,1-k.value.x,.5,0}}
    lib:=make_library(t);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks=desc[:]})
    stats,error:=library_compress(&lib)
    testing.expect_value(t,error,Compress_Error.None)
    testing.expect_value(t,stats.raw_tracks,6)
    values:[6]math.Vec4
    for track,i in clip_tracks(&lib,clip) {
        testing.expect_value(t,track.encoding,Key_Encoding.Raw if i<4 else Key_Encoding.Sampled)
        for sample in 0..<101 {
            time:=f32(sample)/100*2
            testing.expect(t,clip_sample(&lib,clip,time,values[:]))
            testing.expect_value(t,clip_evaluate(&lib,track,time),track_evaluate(desc[i].keys,track.property,time))
            testing.expect_value(t,values[i],track_evaluate(desc[i].keys,track.property,time))
        }
    }
    testing.expect(t,lib.key_count==len(cubic)+len(eased)+len(step)+len(spline))
    testing.expect(t,track_keys(&lib,clip_tracks(&lib,clip)[0])[1].out_slope==cubic[1].out_slope)
}

@(test)
compressed_library_holds_still_tracks_in_one_sample_without_changing_duration :: proc(t:^testing.T) {
    constant:=[4]Keyframe{key(0,7),key(1,7),key(2,7),key(5,7)}
    line:=[6]Keyframe{key(0,0),key(1,2),key(2,4),key(3,6),key(4,8),key(5,10)}
    one:=[1]Keyframe{key(1,9)}
    lib:=make_library(t);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks={{property=.Float,keys=constant[:]},{property=.Float,keys=line[:]},{property=.Float,keys=one[:]},{property=.Float}}})
    _,error:=library_compress(&lib);testing.expect_value(t,error,Compress_Error.None)
    tracks:=clip_tracks(&lib,clip)
    testing.expect(t,tracks[0].encoding==.Sampled && tracks[2].encoding==.Sampled && tracks[3].encoding==.Raw && tracks[3].count==0)
    kind,_:=stream_code(lib.streams[tracks[0].first:],0)
    testing.expect_value(t,kind,Stream_Kind.Constant)
    testing.expect_value(t,clip_duration(&lib,clip),f32(5))
    for sample in 0..<101 {
        time:=f32(sample)/20
        testing.expect_value(t,clip_evaluate(&lib,tracks[0],time).x,f32(7))
        testing.expect_value(t,clip_evaluate(&lib,tracks[2],time).x,f32(9))
        testing.expect(t,near(clip_evaluate(&lib,tracks[1],time).x,min(time*2,10),COMPRESS_DEFAULT.float_precision))
    }
}

@(test)
streams_load_into_another_library_and_reject_corrupt_bytes :: proc(t:^testing.T) {
    position,rotation:[80]Keyframe
    for k in 0..<len(position) {
        position[k]={time=f32(k)/30,value={cmath.sin(f32(k)*.3),f32(k)*.01,cmath.cos(f32(k)*.2),0}}
        rotation[k]={time=f32(k)/30,value=quat_vec4(math.quat_axis_angle(linalg.normalize(math.Vec3{1,2,f32(k)*.1}),f32(k)*.05))}
    }
    still:=[2]Keyframe{{time=0,value={0,0,0,1}},{time=1,value={0,0,0,1}}}
    lib:=make_library(t,keys=200,tracks=4,clips=1,markers=0);defer library_destroy(&lib)
    clip,_:=clip_add(&lib,{tracks={{target=5,property=.Position,keys=position[:]},{target=5,property=.Rotation,keys=rotation[:]},{target=6,property=.Rotation,keys=still[:]},{target=7,property=.Float}}})
    _,error:=library_compress(&lib);testing.expect_value(t,error,Compress_Error.None)
    data:=clip_data(&lib,clip)
    testing.expect(t,data.stream_bytes>0)
    stream:=make([]u8,data.stream_bytes);defer delete(stream)
    copy(stream,lib.streams[data.stream:][:data.stream_bytes])
    descs:[4]Track_Desc
    for track,i in clip_tracks(&lib,clip) {descs[i]={target=track.target,property=track.property,encoding=track.encoding}}
    testing.expect(t,descs[0].encoding==.Sampled && descs[1].encoding==.Sampled && descs[2].encoding==.Sampled && descs[3].encoding==.Raw)
    other:Library
    testing.expect(t,library_init(&other,{max_keys=1,max_tracks=8,max_clips=2,max_stream_bytes=len(stream)}))
    defer library_destroy(&other)
    loaded,added:=clip_add(&other,{tracks=descs[:],stream=stream})
    testing.expect_value(t,added,Clip_Error.None)
    testing.expect_value(t,clip_duration(&other,loaded),clip_duration(&lib,clip))
    values:[4]math.Vec4
    for sample in 0..<300 {
        time:=f32(sample)/100
        testing.expect(t,clip_sample(&other,loaded,time,values[:]))
        for track,i in clip_tracks(&other,loaded) {
            single:=clip_evaluate(&other,track,time)
            testing.expect_value(t,single,clip_evaluate(&lib,clip_tracks(&lib,clip)[i],time))
            testing.expect_value(t,values[i],single)
        }
    }
    // Every byte changed to every value: refused or still read inside the stream.
    h:=stream_load(Stream_Header,stream,0)
    for at in 0..<len(stream) {
        saved:=stream[at]
        for value in ([?]u8{0,1,7,31,32,33,200,255}) {
            stream[at]=value
            _,refused:=clip_add(&other,{tracks=descs[:],stream=stream})
            if refused==.None {
                // Accepted: it decodes without leaving the stream, whatever it holds.
                for sample in 0..<8 {_=clip_sample(&other,Clip(other.clip_count),f32(sample)*.4,values[:])}
                other.clip_count-=1;other.track_count-=4;other.stream_bytes-=len(stream)
            } else {testing.expect(t,refused==.Invalid || refused==.Full)}
        }
        stream[at]=saved
    }
    _,refused:=clip_add(&other,{tracks=descs[:],stream=stream[:len(stream)-1]});testing.expect_value(t,refused,Clip_Error.Invalid)
    _,refused=clip_add(&other,{tracks=descs[:3],stream=stream});testing.expect_value(t,refused,Clip_Error.Invalid)
    wrong:=descs;wrong[0].property=.Float
    _,refused=clip_add(&other,{tracks=wrong[:],stream=stream});testing.expect_value(t,refused,Clip_Error.Invalid)
    _,refused=clip_add(&other,{tracks=descs[:]});testing.expect_value(t,refused,Clip_Error.Invalid)
    rate:=h;rate.rate=-1
    bytes:=transmute([size_of(Stream_Header)]u8)rate
    copy(stream,bytes[:])
    _,refused=clip_add(&other,{tracks=descs[:],stream=stream});testing.expect_value(t,refused,Clip_Error.Invalid)
    infinite:=transmute([4]u8)u32(0x7f800000)
    copy(stream[h.ranges+12:],infinite[:])
    _,refused=clip_add(&other,{tracks=descs[:],stream=stream});testing.expect_value(t,refused,Clip_Error.Invalid)
}

@(private) Compress_Allocation_Failure :: struct {owner:runtime.Allocator,remaining:int}
@(private)
compress_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Compress_Allocation_Failure)(data)
    if size>0 && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {if state.remaining==0 {return nil,.Out_Of_Memory};state.remaining-=1}
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
compression_rolls_back_every_allocation_failure_and_rejects_hostile_data :: proc(t:^testing.T) {
    success:=false
    for budget in 0..<64 {
        failure:=Compress_Allocation_Failure{owner=context.allocator,remaining=32}
        lib:Library;testing.expect(t,library_init(&lib,{max_keys=8,max_tracks=2,max_clips=1,max_markers=1,allocator={compress_failure_allocator,&failure}}))
        clip,_:=clip_add(&lib,{tracks={{property=.Position,keys={{time=0,value={0,1,2,0}},{time=1,value={1,0,3,0}},{time=2,value={1,4,3,0}}}},{property=.Float,keys={key(0,0,.Cubic),key(1,3,.Cubic)}}},markers={{time=.5,id=19}}})
        old_keys,old_tracks:=raw_data(lib.keys),raw_data(lib.tracks);old_count:=lib.key_count
        failure.remaining=budget
        _,error:=library_compress(&lib)
        if error==.None {success=true;library_destroy(&lib);break}
        testing.expect_value(t,error,Compress_Error.Out_Of_Memory)
        testing.expect(t,raw_data(lib.keys)==old_keys && raw_data(lib.tracks)==old_tracks && lib.key_count==old_count && !lib.prepared && lib.streams==nil)
        testing.expect(t,near(clip_evaluate(&lib,clip_tracks(&lib,clip)[0],.5).x,.5))
        library_destroy(&lib)
    }
    testing.expect(t,success)
    lib:=make_library(t);defer library_destroy(&lib)
    clip_add(&lib,{tracks={{property=.Float,keys={key(0,0),key(1,1)}}}})
    original:=lib.keys[1];lib.keys[1].time=-.1
    _,error:=library_compress(&lib);testing.expect_value(t,error,Compress_Error.Invalid);testing.expect(t,!lib.prepared)
    lib.keys[1]=original;lib.keys[1].value.x=transmute(f32)u32(0x7f800000)
    _,error=library_compress(&lib);testing.expect_value(t,error,Compress_Error.Invalid)
    lib.keys[1]=original
    config:=COMPRESS_DEFAULT;config.precision=-1
    _,error=library_compress(&lib,config=config);testing.expect_value(t,error,Compress_Error.Invalid)
    _,error=library_compress(&lib,{5});testing.expect_value(t,error,Compress_Error.Invalid)
    _,error=library_compress(&lib,{-1,-1});testing.expect_value(t,error,Compress_Error.Invalid)
    config=COMPRESS_DEFAULT;config.float_precision=0
    _,error=library_compress(&lib,config=config);testing.expect_value(t,error,Compress_Error.None)
    testing.expect(t,clip_evaluate(&lib,clip_tracks(&lib,1)[0],.25).x==.25)
}

@(test)
compressed_random_curves_stay_within_precision_between_samples :: proc(t:^testing.T) {
    rng:=math.rng_make(419)
    ROUNDS :: #config(ANIM_COMPRESS_HOSTILE_ROUNDS,80)
    for round in 0..<ROUNDS {
        keys:[16]Keyframe
        property:=Property(round%5)
        for &key,i in keys {
            key.time=f32(i)*.13
            key.value={math.random_range(&rng,-3,3),math.random_range(&rng,-3,3),math.random_range(&rng,-3,3),math.random_range(&rng,-3,3)}
            if property==.Rotation {key.value=quat_vec4(math.quat_axis_angle({0,1,0},math.random_range(&rng,-3,3)))}
            if property==.Scale {key.value.xyz=linalg.abs(key.value.xyz)+.5}
        }
        lib:=make_library(t,keys=16,tracks=1,clips=1,markers=0)
        clip,_:=clip_add(&lib,{tracks={{property=property,keys=keys[:]}}})
        stats,error:=library_compress(&lib);testing.expect_value(t,error,Compress_Error.None)
        track:=clip_tracks(&lib,clip)[0]
        for sample in 0..<201 {
            time:=f32(sample)/200*keys[len(keys)-1].time;before:=track_evaluate(keys[:],property,time);after:=clip_evaluate(&lib,track,time)
            limit:=COMPRESS_DEFAULT.precision
            error:f32
            switch property {
            case .Position:error=linalg.length(after.xyz-before.xyz)
            case .Rotation:error=math.quat_angle(vec4_quat(linalg.normalize0(before)),vec4_quat(after))*COMPRESS_DEFAULT.shell
            case .Scale:ratio:=linalg.abs(after.xyz/before.xyz-1);error=max(ratio.x,ratio.y,ratio.z)*COMPRESS_DEFAULT.shell
            case .Float:error,limit=abs(after.x-before.x),COMPRESS_DEFAULT.float_precision
            case .Vector:error,limit=max(abs(after.x-before.x),abs(after.y-before.y),abs(after.z-before.z),abs(after.w-before.w)),COMPRESS_DEFAULT.vector_precision
            }
            testing.expectf(t,error<=limit*1.05,"%v round %d: %v over %v (measured %v)",property,round,error,limit,stats.error)
        }
        library_destroy(&lib)
    }
}
