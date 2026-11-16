package asset

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"
import anim "mirai:std/anim"
import math "mirai:std/math"
import "mirai:std/serial"

// The demo's animations as the project keeps them against their cooked form: bytes, the farthest
// a point 3 cm from a bone moves, sampling time per bone and load time. Run with
//   mirai test asset animation_compression_of_the_demo --release -define:ANIMATION_BENCH=true

@(private="file") ANIMATION_BENCH :: #config(ANIMATION_BENCH,false)
@(private="file") ANIMATION_BENCH_FILES :: [?]string{
    "characters/tall_mirai/tall_mirai.anim","characters/mirai/mirai_gallery.anim","characters/mirai/mirai_locomotion.anim",
    "characters/mirai/mirai.anim","characters/jelly/jelly.gltf/jelly.anim","showcase/lift.anim",
    "physics_gallery/ragdoll/wave.anim",
}

@(private="file")
Bench_Bone :: struct {target:u64,parent,depth:int,tracks:[3]int,rest:math.Transform}

// The farthest a shell point of any bone moves between two libraries holding the same clips, on
// the skeleton of the clip when it has one.
@(private="file")
bench_pose_error :: proc(exact,compressed:^anim.Library,view:Animation_View,parents:[]i32,skeleton:anim.Skeleton,clip:anim.Clip,steps:int) -> (worst:f32) {
    data:=anim.clip_data(exact,clip)
    bones:=make([dynamic]Bench_Bone,context.temp_allocator)
    for target,b in skeleton.names {append(&bones,Bench_Bone{target=target,parent=int(skeleton.parents[b]),tracks={-1,-1,-1},rest=skeleton.rest[b]})}
    bone_of:=make([]int,data.track_count,context.temp_allocator)
    for &b in bone_of {b=-1}
    tracks:=anim.clip_tracks(exact,clip)
    for track,i in tracks {
        if track.property>.Scale || track.slot!=0 {continue}
        at:=-1
        for bone,b in bones {if bone.target==track.target {at=b}}
        if at<0 {at=len(bones);append(&bones,Bench_Bone{target=track.target,parent=-1,tracks={-1,-1,-1},rest=math.TRANSFORM_IDENTITY})}
        bones[at].tracks[track.property]=i;bone_of[i]=at
    }
    for &bone in bones[len(skeleton.names):] {
        for t in bone.tracks {if t>=0 {if p:=int(parents[int(data.first_track)+t])-int(data.first_track);p>=0 {bone.parent=bone_of[p]};break}}
    }
    for &bone in bones {for at:=bone.parent;at>=0;at=bones[at].parent {bone.depth+=1}}
    order:=make([]int,len(bones),context.temp_allocator)
    for &o,i in order {o=i}
    slice.sort_by(order,proc(a,b:int) -> bool {return false})
    // Parents first: by depth, then the transforms of each bone in that order.
    for i in 0..<len(order) {for j in i+1..<len(order) {if bones[order[j]].depth<bones[order[i]].depth {order[i],order[j]=order[j],order[i]}}}
    world:=make([][2]math.Transform,len(bones),context.temp_allocator)
    duration:=data.duration
    compressed_tracks:=anim.clip_tracks(compressed,clip)
    for step in 0..=steps {
        time:=f32(step)/f32(steps)*duration
        for b in order {
            bone:=bones[b]
            for side in 0..<2 {
                library:=exact if side==0 else compressed
                list:=tracks if side==0 else compressed_tracks
                local:=bone.rest
                if t:=bone.tracks[0];t>=0 {local.position=anim.clip_evaluate(library,list[t],time).xyz}
                if t:=bone.tracks[1];t>=0 {local.rotation=linalg.normalize0(anim.vec4_quat(anim.clip_evaluate(library,list[t],time)))}
                if t:=bone.tracks[2];t>=0 {local.scale=anim.clip_evaluate(library,list[t],time).xyz}
                world[b][side]=local if bone.parent<0 else math.transform_compose(world[bone.parent][side],local)
            }
            a,c:=world[b][0],world[b][1]
            ratio:=c.scale/a.scale
            worst=max(worst,linalg.length(a.position-c.position))
            for point in ([2]math.Vec3{{.03,0,0},{0,.03,0}}) {
                worst=max(worst,linalg.length(a.position+math.quat_rotate(a.rotation,point)-c.position-math.quat_rotate(c.rotation,point*ratio)))
            }
        }
    }
    return
}

// Nanoseconds to sample every transform track of every clip once, per bone.
@(private="file")
bench_sample :: proc(lib:^anim.Library,clips:int,steps:int) -> (per_bone:f64,sink:f32) {
    bones,samples:=0,0
    best:=max(time.Duration)
    for _ in 0..<5 {
        start:=time.tick_now()
        bones=0
        for clip in 1..=clips {
            tracks:=anim.clip_tracks(lib,anim.Clip(clip))
            duration:=anim.clip_duration(lib,anim.Clip(clip))
            for step in 0..<steps {
                at:=f32(step)/f32(steps)*duration
                for track in tracks {if track.property<=.Scale {sink+=anim.clip_evaluate(lib,track,at).x}}
            }
            for track in tracks {if track.property==.Rotation {bones+=1}}
        }
        best=min(best,time.tick_since(start))
    }
    samples=bones*steps
    return f64(time.duration_nanoseconds(best))/f64(max(samples,1)),sink
}

@(test)
animation_compression_of_the_demo :: proc(t:^testing.T) {
    when !ANIMATION_BENCH {return}
    types:Types;types_init(&types);defer types_destroy(&types)
    fmt.println("| file | .anim bytes | cooked bytes | resident keys | resident cooked | worst mm | raw ns/bone | cooked ns/bone | editor load ms | cooked load ms |")
    fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    totals:[4]int
    registry:Registry
    registry_init(&registry,fmt.tprintf("%s/../demo/assets",#directory))
    defer registry_destroy(&registry)
    testing.expect_value(t,registry_scan(&registry),Error.None)
    for name in ANIMATION_BENCH_FILES {
        defer free_all(context.temp_allocator)
        path:=fmt.tprintf("%s/../demo/assets/%s",#directory,name)
        bytes,read_error:=os.read_entire_file(path,context.allocator)
        if !testing.expect(t,read_error==nil,path) {continue}
        defer delete(bytes)
        a:Asset
        testing.expect_value(t,asset_open(&a,bytes),Error.None)
        defer asset_close(&a)
        view,error:=animation_view(&a,&types)
        if !testing.expect_value(t,error,Error.None) {continue}
        exact:anim.Library
        testing.expect(t,anim.library_init(&exact,animation_library_desc(view)))
        defer anim.library_destroy(&exact)
        animation_clips_add(view,&exact)
        // As the editor loads it: open, add and compress.
        load_start:=time.tick_now()
        loaded:Asset
        testing.expect_value(t,asset_open(&loaded,bytes),Error.None)
        loaded_view,_:=animation_view(&loaded,&types)
        compressed:anim.Library
        testing.expect(t,anim.library_init(&compressed,animation_library_desc(loaded_view)))
        defer anim.library_destroy(&compressed)
        animation_clips_add(loaded_view,&compressed)
        stats,compressing:=animation_compress(loaded_view,&compressed,&types,skeleton_open_registry,&registry)
        editor_load:=time.tick_since(load_start)
        asset_close(&loaded)
        testing.expect_value(t,compressing,anim.Compress_Error.None)
        doc:Document
        testing.expect_value(t,animation_cooked_document(&doc,&types,a.blob.header.id,a.blob.header.owner,view,&compressed),Error.None)
        w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
        testing.expect_value(t,document_write(&doc,&w),Error.None)
        document_destroy(&doc)
        // As a shipped game loads it: open the cooked bytes and add them.
        cooked_start:=time.tick_now()
        cooked:Asset
        testing.expect_value(t,asset_open(&cooked,serial.writer_bytes(&w)),Error.None)
        cooked_view,_:=animation_view(&cooked,&types)
        played:anim.Library
        testing.expect(t,anim.library_init(&played,animation_library_desc(cooked_view)))
        animation_clips_add(cooked_view,&played)
        cooked_load:=time.tick_since(cooked_start)
        defer {anim.library_destroy(&played);asset_close(&cooked)}
        parents,_:=animation_parents(view,context.temp_allocator)
        worst:f32
        for clip,c in view.clips {
            skeleton:anim.Skeleton
            file:Asset
            if clip.skeleton!={} && skeleton_open_registry(&registry,clip.skeleton,&file) {
                if bones,read:=skeleton_view(&file,&types);read==.None {skeleton,_=skeleton_anim(bones,context.temp_allocator)}
                asset_close(&file)
            }
            worst=max(worst,bench_pose_error(&exact,&played,view,parents,skeleton,anim.Clip(c+1),2000))
        }
        raw_ns,s1:=bench_sample(&exact,len(view.clips),200)
        cooked_ns,s2:=bench_sample(&played,len(view.clips),200)
        resident_raw,resident_cooked:=anim.library_resident_bytes(&exact),anim.library_resident_bytes(&played)
        fmt.printfln("tracks: %d sampled, %d constant, %d default, %d raw; streams %d bytes, keys %d",stats.sampled_tracks,stats.constant_tracks,stats.default_tracks,stats.raw_tracks,compressed.stream_bytes,compressed.key_count)
        fmt.printfln("| %s | %d | %d | %d | %d | %.4f (compressor %.4f) | %.1f | %.1f | %.2f | %.2f |%v",name,len(bytes),len(serial.writer_bytes(&w)),resident_raw,resident_cooked,worst*1000,stats.error*1000,raw_ns,cooked_ns,time.duration_milliseconds(editor_load),time.duration_milliseconds(cooked_load),"" if s1+s2!=0.5 else " ")
        totals+={len(bytes),len(serial.writer_bytes(&w)),resident_raw,resident_cooked}
    }
    fmt.printfln("| total | %d | %d | %d | %d | | | | | |",totals[0],totals[1],totals[2],totals[3])
}
