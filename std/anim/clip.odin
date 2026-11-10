package mirai_anim

import "base:runtime"
import "core:slice"
import math "mirai:std/math"

// A moment of a clip that playback reports when it crosses it; with a duration, a span that
// starts there.
Marker :: struct {
    time:f32,
    id:u32,
    duration:f32,
}

// One property of one target over time. `target` is the name_hash of whatever
// the caller drives (a node, a bone, a material); `slot` tells apart several
// Float or Vector tracks of one target.
// A track is its keys or, with encoding Sampled, its part of the clip's stream.
Track_Desc :: struct {
    target:u64,
    property:Property,
    slot:u8,
    encoding:Key_Encoding,
    keys:[]Keyframe,
}
// stream: what library_compress made of the clip's tracks (sampled.odin), without its padding;
// nil when every track is keys.
Clip_Desc :: struct {
    name:u64,
    loop:Loop,
    tracks:[]Track_Desc,
    markers:[]Marker,
    stream:[]u8,
}

Track :: struct {
    target:u64,
    first,count:u32, // keys of the library; sampled: its clip's stream in Library.streams and its place in the clip
    property:Property,
    slot:u8,
    encoding:Key_Encoding,
}
Clip_Data :: struct {
    name:u64,
    loop:Loop,
    duration:f32,
    first_track,track_count:u32,
    first_marker,marker_count:u32,
    stream,stream_bytes:u32, // its stream in Library.streams; 0 bytes: none
}

// Handle of a clip of a library: its index plus one. Zero is none.
Clip :: distinct u32

// The clips of a game: immutable once added, shared by every player. Capacities
// are fixed at init; clip_add refuses what does not fit and says why.
Library :: struct {
    keys:[]Keyframe,
    streams:[]u8, // the streams of the clips, with STREAM_PADDING bytes after the last
    tracks:[]Track,
    clips:[]Clip_Data,
    markers:[]Marker,
    key_count,track_count,clip_count,marker_count,stream_bytes:int,
    prepared:bool,
    allocator:runtime.Allocator,
}
Library_Desc :: struct {
    max_keys,max_tracks,max_clips,max_markers:int,
    max_stream_bytes:int, // of the streams clip_add takes
    allocator:runtime.Allocator, // context.allocator when unset
}

library_init :: proc(lib:^Library,desc:Library_Desc) -> bool {
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    lib^={allocator=allocator}
    if desc.max_keys<=0 || desc.max_tracks<=0 || desc.max_clips<=0 || desc.max_markers<0 || desc.max_stream_bytes<0 {return false}
    e1,e2,e3,e4,e5:runtime.Allocator_Error
    lib.keys,e1=make([]Keyframe,desc.max_keys,allocator)
    lib.tracks,e2=make([]Track,desc.max_tracks,allocator)
    lib.clips,e3=make([]Clip_Data,desc.max_clips,allocator)
    lib.markers,e4=make([]Marker,desc.max_markers,allocator)
    if desc.max_stream_bytes>0 {lib.streams,e5=make([]u8,desc.max_stream_bytes+STREAM_PADDING,allocator)}
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil {library_destroy(lib);return false}
    return true
}
library_destroy :: proc(lib:^Library) {
    if lib.allocator.procedure==nil {lib^={};return}
    delete(lib.keys,lib.allocator);delete(lib.tracks,lib.allocator);delete(lib.clips,lib.allocator);delete(lib.markers,lib.allocator)
    delete(lib.streams,lib.allocator)
    lib^={}
}

// Why clip_add refused a clip.
Clip_Error :: enum u8 {
    None,
    Prepared, // the library was prepared: it takes no more clips
    Unsorted, // the keys of a track are not sorted by time
    Full,     // the clip passes max_clips, max_tracks, max_keys, max_markers or max_stream_bytes of the library
    Invalid,  // a stream that does not match the clip's tracks or is not consistent
}

// Adds a clip, copying its keys and markers; markers are stored sorted by
// time. Its duration is the time of its last key or marker. Returns 0 and
// why when it is refused.
clip_add :: proc(lib:^Library,desc:Clip_Desc) -> (Clip,Clip_Error) {
    if lib.prepared {return 0,.Prepared}
    keys,sampled:=0,0
    for track in desc.tracks {
        keys+=len(track.keys)
        for i in 1..<len(track.keys) {
            if track.keys[i].time<track.keys[i-1].time {return 0,.Unsorted}
        }
        if track.encoding==.Sampled {
            if len(track.keys)>0 {return 0,.Invalid}
            sampled+=1
        } else if track.encoding!=.Raw {return 0,.Invalid}
    }
    if sampled>0 && len(desc.stream)==0 {return 0,.Invalid}
    if len(desc.stream)>0 {
        if len(desc.stream)>int(max(u32))-STREAM_PADDING {return 0,.Invalid}
        padded,error:=make([]u8,len(desc.stream)+STREAM_PADDING,context.temp_allocator)
        if error!=nil {return 0,.Full}
        copy(padded,desc.stream)
        bytes,ok:=stream_check(padded,desc.tracks)
        if !ok || bytes!=len(desc.stream) {return 0,.Invalid}
    }
    if lib.stream_bytes<0 || lib.stream_bytes>max(len(lib.streams)-STREAM_PADDING,0) || lib.clip_count>=len(lib.clips) || lib.track_count+len(desc.tracks)>len(lib.tracks) || lib.key_count+keys>len(lib.keys) || lib.marker_count+len(desc.markers)>len(lib.markers) || len(desc.stream)>0 && lib.stream_bytes+len(desc.stream)>len(lib.streams)-STREAM_PADDING {
        return 0,.Full
    }
    data:=Clip_Data{name=desc.name,loop=desc.loop,first_track=u32(lib.track_count),track_count=u32(len(desc.tracks)),first_marker=u32(lib.marker_count),marker_count=u32(len(desc.markers))}
    if len(desc.stream)>0 {
        data.stream,data.stream_bytes=u32(lib.stream_bytes),u32(len(desc.stream))
        copy(lib.streams[lib.stream_bytes:],desc.stream)
        lib.stream_bytes+=len(desc.stream)
        data.duration=stream_load(Stream_Header,desc.stream,0).duration
    }
    for track,i in desc.tracks {
        if track.encoding==.Sampled {
            lib.tracks[lib.track_count]={target=track.target,property=track.property,slot=track.slot,encoding=.Sampled,first=data.stream,count=u32(i)}
            lib.track_count+=1
            continue
        }
        lib.tracks[lib.track_count]={target=track.target,property=track.property,slot=track.slot,first=u32(lib.key_count),count=u32(len(track.keys))}
        lib.track_count+=1
        copy(lib.keys[lib.key_count:],track.keys)
        lib.key_count+=len(track.keys)
        if len(track.keys)>0 {data.duration=max(data.duration,track.keys[len(track.keys)-1].time)}
    }
    stored:=lib.markers[lib.marker_count:][:len(desc.markers)]
    copy(stored,desc.markers)
    slice.stable_sort_by(stored,proc(a,b:Marker) -> bool {return a.time<b.time})
    for marker in stored {data.duration=max(data.duration,marker.time)}
    lib.marker_count+=len(desc.markers)
    lib.clips[lib.clip_count]=data
    lib.clip_count+=1
    return Clip(lib.clip_count),.None
}

clip_valid :: #force_inline proc "contextless" (lib:^Library,clip:Clip) -> bool {return clip!=0 && int(clip)<=lib.clip_count}
// The clip added with this name hash, or 0.
clip_find :: proc "contextless" (lib:^Library,name:u64) -> Clip {
    for i in 0..<lib.clip_count {if lib.clips[i].name==name {return Clip(i+1)}}
    return 0
}
// Zero data for a handle that is not valid.
clip_data :: proc "contextless" (lib:^Library,clip:Clip) -> Clip_Data {
    if !clip_valid(lib,clip) {return {}}
    return lib.clips[clip-1]
}
clip_duration :: proc "contextless" (lib:^Library,clip:Clip) -> f32 {return clip_data(lib,clip).duration}
clip_tracks :: proc "contextless" (lib:^Library,clip:Clip) -> []Track {
    if !clip_valid(lib,clip) {return nil}
    data:=lib.clips[clip-1]
    return lib.tracks[data.first_track:][:data.track_count]
}
clip_markers :: proc "contextless" (lib:^Library,clip:Clip) -> []Marker {
    if !clip_valid(lib,clip) {return nil}
    data:=lib.clips[clip-1]
    return lib.markers[data.first_marker:][:data.marker_count]
}
// Empty for a track whose keys lie outside the library.
track_keys :: #force_inline proc "contextless" (lib:^Library,track:Track) -> []Keyframe {
    if lib==nil || track.encoding!=.Raw || lib.key_count<0 || lib.key_count>len(lib.keys) || int(track.first)>lib.key_count || int(track.count)>lib.key_count-int(track.first) {return nil}
    return lib.keys[track.first:][:track.count]
}

// The value of one track of a clip at a time inside the clip.
clip_evaluate :: #force_inline proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {
    if track.encoding==.Raw {return track_evaluate(track_keys(lib,track),track.property,time)}
    return stream_evaluate(lib,track,time)
}

clip_curve :: proc "contextless" (lib:^Library,player:Player,target:u64,slot:u8,default_value:f32=0) -> f32 {
    for track in clip_tracks(lib,player.clip) {
        if track.target==target && track.slot==slot && track.property==.Float {return clip_evaluate(lib,track,player_time(lib,player)).x}
    }
    return default_value
}
