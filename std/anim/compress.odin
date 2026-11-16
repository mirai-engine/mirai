package mirai_anim

import "base:runtime"
import cmath "core:math"
import "core:math/linalg"
import "core:slice"
import math "mirai:std/math"

// How far library_compress may move what a clip animates. The error of a transform is measured
// on the skeleton the clip plays on: three points `shell` away from each bone along its axes, in
// the space of the entity that plays it, so that a rotation near the root counts for everything
// below it.
Compress_Config :: struct {
    precision:f32, // the farthest a shell point may move, in scene units
    shell:f32,
    float_precision,vector_precision:f32, // per component of Float and Vector tracks
}
COMPRESS_DEFAULT :: Compress_Config{precision=.0001,shell=.03,float_precision=.0001,vector_precision=.0001}
// Advances whenever library_compress gives other streams for the same keys and config: a
// compression kept by its inputs is made again.
COMPRESS_VERSION :: 4
// The sample rate of a clip whose keys have no interval in common.
COMPRESS_RATE :: 30
Compress_Error :: enum u8 {None,Invalid,Out_Of_Memory,Prepared}
Compress_Stats :: struct {
    raw_bytes,resident_bytes:int,
    raw_tracks,default_tracks,constant_tracks,sampled_tracks:int,
    // The farthest a shell point moved and the largest change of a curve component, measured at
    // the samples and at three points between each two.
    error,curve_error:f32,
}

// Points measured per sample interval: the samples and those between them.
@(private) COMPRESS_SUBDIVISIONS :: 4
// Bits per component of each bit rate; the last keeps the f32.
@(private) COMPRESS_BITS :: [?]u8{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,STREAM_RAW}
@(private) COMPRESS_RATES :: len(COMPRESS_BITS)
@(private) COMPRESS_RAW :: COMPRESS_RATES-1
// The rate of a slot of a bone that has nothing to search: no track, or one that holds still.
@(private) COMPRESS_FIXED :: 255
@(private) SEGMENT_IDEAL :: 16
@(private) SEGMENT_MAX :: 31
// ACL's search levels: the longest chain of bones and the samples decide how many bit rates of a
// chain the object-space search raises at once.
@(private) Compress_Level :: enum u8 {Medium,High,Highest}

// A bone measured by the search: its tracks in ACL's order of slots (rotation, position, scale).
@(private)
Compress_Bone :: struct {
    target:u64,
    slot:u8,
    parent:int,
    tracks:[3]int, // its Rotation, Position and Scale tracks in the clip, -1 for none
    rest:math.Transform,
    depth:int,
    // ACL's rigid shell: how far from the bone the farthest point it moves sits, and the
    // precision of the bone that point belongs to; over the clip and over the segment searched.
    shell,precision,segment_shell,segment_precision:f32,
}

// What one clip needs while its tracks are compressed: per track and fine sample (the samples and
// COMPRESS_SUBDIVISIONS-1 points between each two) its exact value, per bone and fine sample its
// exact transform in the space of the entity.
@(private)
Compress_Work :: struct {
    first,count,samples,fine:int,
    skeleton:Skeleton,
    rate,duration:f32,
    level:Compress_Level,
    exact:[]math.Vec4,
    world:[]math.Transform,
    bones:[]Compress_Bone,
    bone_count:int,
    bone_of:[]int,
    kind:[]Stream_Kind,
    value:[]math.Vec4, // what a Default or Constant track holds
    minimum,extent:[]math.Vec4,
    starts:[]int, // the first sample of each segment and, last, the sample count
    segments:int,
    rates:[]u8,   // per track and segment
    low,span:[]u8, // per track, segment and component: the segment's range in 255ths of the track's
    middle:[]u16, // per track, segment and component: where it holds still with 0 bits, in 65535ths
    // The search of one segment: per Animated track (slot) and rate its decoded samples, and the
    // tracks' rates while a plan is tried.
    best:[]u8,
    lossy:[]math.Vec4,
    lossy_done:[]bool,
    trial:[]u8,
    decoded:[]math.Vec4, // per track and sample, at the final rates
    order:[]int,
    sorted:[]Compress_Bone,
    tables:^Compress_Tables,
    allocator:runtime.Allocator,
}

// Pass 1 of the search: per set of slots that can change, every combination of their rates
// sorted by the bits it costs and then by rate, as ACL's table of permutations.
@(private)
Compress_Tables :: struct {
    entries:[8][][3]u8,
    allocator:runtime.Allocator,
}

library_resident_bytes :: proc "contextless" (lib:^Library) -> int {
    if lib==nil {return 0}
    return len(lib.keys)*size_of(Keyframe)+len(lib.streams)+len(lib.tracks)*size_of(Track)+len(lib.clips)*size_of(Clip_Data)+len(lib.markers)*size_of(Marker)
}

@(private)
compress_config_valid :: proc "contextless" (config:Compress_Config) -> bool {
    for value in ([4]f32{config.precision,config.shell,config.float_precision,config.vector_precision}) {if !anim_finite(value) || value<0 {return false}}
    return true
}
@(private)
compress_keys_valid :: proc "contextless" (keys:[]Keyframe,property:Property) -> bool {
    if property>.Vector {return false}
    for key,i in keys {
        if !anim_finite(key.time) || key.time<0 || i>0 && key.time<keys[i-1].time || key.interpolation>max(Interpolation) || key.ease>max(math.Ease) {return false}
        for v in key.value {if !anim_finite(v) {return false}}
        if key.tangents {for v in key.in_slope {if !anim_finite(v) {return false}};for v in key.out_slope {if !anim_finite(v) {return false}}}
        if property==.Rotation && abs(key.value.x)+abs(key.value.y)+abs(key.value.z)+abs(key.value.w)<1e-8 {return false}
    }
    return true
}

// Transaction: the tracks of every clip go into one stream per clip (sampled.odin) within
// `config`, with the approach of ACL; a track that the samples would not follow keeps its keys.
// `skeletons` gives for each clip of the library the skeleton it plays on, whose rest pose holds
// what the clip does not move; an empty or invalid one is none. A track whose target is no bone
// of it hangs from the track `parents` gives for it, of the bone above its target in the same
// clip, -1 for none; without both, every bone is measured alone. Failures leave the library as it
// was; after success it does not accept clip_add.
library_compress :: proc(lib:^Library,parents:[]i32=nil,skeletons:[]Skeleton=nil,config:=COMPRESS_DEFAULT) -> (stats:Compress_Stats,error:Compress_Error) {
    if lib==nil || lib.allocator.procedure==nil || !compress_config_valid(config) || lib.key_count<0 || lib.key_count>len(lib.keys) || lib.track_count<0 || lib.track_count>len(lib.tracks) || lib.clip_count<0 || lib.clip_count>len(lib.clips) || lib.marker_count<0 || lib.marker_count>len(lib.markers) {return {},.Invalid}
    if lib.prepared {return {},.Prepared}
    if parents!=nil && len(parents)!=lib.track_count {return {},.Invalid}
    for clip in lib.clips[:lib.clip_count] {
        if !anim_finite(clip.duration) || clip.duration<0 || int(clip.first_track)>lib.track_count || int(clip.track_count)>lib.track_count-int(clip.first_track) || int(clip.first_marker)>lib.marker_count || int(clip.marker_count)>lib.marker_count-int(clip.first_marker) || clip.stream_bytes!=0 {return {},.Invalid}
    }
    for track in lib.tracks[:lib.track_count] {
        if track.encoding!=.Raw {return {},.Invalid}
        keys:=track_keys(lib,track)
        if len(keys)!=int(track.count) || !compress_keys_valid(keys,track.property) {return {},.Invalid}
    }
    for parent in parents {if parent< -1 || int(parent)>=lib.track_count {return {},.Invalid}}
    allocator:=lib.allocator
    stats.raw_bytes=library_resident_bytes(lib)
    kinds,e1:=make([]Stream_Kind,lib.track_count,allocator)
    // Keys tracks the stream holds; the others keep their keys in the library.
    held,e0:=make([]bool,lib.track_count,allocator)
    // Per clip that heads its tracks: where its stream starts in `out` and its bytes.
    placed,e2:=make([][2]int,lib.clip_count,allocator)
    owner,e3:=make([]int,lib.track_count,allocator)
    out:=make([dynamic]u8,allocator)
    tables:=Compress_Tables{allocator=allocator}
    defer {delete(kinds,allocator);delete(held,allocator);delete(placed,allocator);delete(owner,allocator);delete(out);compress_tables_free(&tables)}
    if e0!=nil || e1!=nil || e2!=nil || e3!=nil {return stats,.Out_Of_Memory}
    for &o in owner {o=-1}
    for &kind in kinds {kind=.Keys}
    for clip,c in lib.clips[:lib.clip_count] {
        placed[c]={-1,0}
        if clip.track_count==0 {continue}
        if head:=owner[clip.first_track];head>=0 {
            same:=lib.clips[head]
            if same.track_count==clip.track_count {placed[c]=placed[head]}
            continue
        }
        for i in 0..<int(clip.track_count) {if owner[int(clip.first_track)+i]<0 {owner[int(clip.first_track)+i]=c}}
        skeleton:Skeleton
        if c<len(skeletons) && len(skeletons[c].parents)>0 && skeleton_validate(skeletons[c]) {skeleton=skeletons[c]}
        at:=len(out)
        clip_error,curve_error,ok:=compress_clip(lib,clip,parents,skeleton,config,kinds[clip.first_track:][:clip.track_count],held[clip.first_track:][:clip.track_count],&out,&tables)
        if !ok {return stats,.Out_Of_Memory}
        if len(out)>at {placed[c]={at,len(out)-at}}
        stats.error=max(stats.error,clip_error);stats.curve_error=max(stats.curve_error,curve_error)
    }
    raw_count:=0
    for kind,i in kinds {
        switch kind {
        case .Keys:
            stats.raw_tracks+=1
            if !held[i] {raw_count+=int(lib.tracks[i].count)}
        case .Default:stats.default_tracks+=1
        case .Constant:stats.constant_tracks+=1
        case .Animated:stats.sampled_tracks+=1
        }
    }
    keys,e4:=make([]Keyframe,raw_count,allocator)
    streams,e5:=make([]u8,len(out)+STREAM_PADDING,allocator)
    if e4!=nil || e5!=nil {delete(keys,allocator);delete(streams,allocator);return stats,.Out_Of_Memory}
    copy(streams,out[:])
    key_at:=0
    for clip,c in lib.clips[:lib.clip_count] {
        if placed[c][0]<0 || owner[clip.first_track]!=c {continue}
        for &track,i in lib.tracks[clip.first_track:][:clip.track_count] {
            if kinds[int(clip.first_track)+i]==.Keys && !held[int(clip.first_track)+i] {continue}
            track={target=track.target,property=track.property,slot=track.slot,encoding=.Sampled,first=u32(placed[c][0]),count=u32(i)}
        }
    }
    for &track in lib.tracks[:lib.track_count] {
        if track.encoding!=.Raw {continue}
        copy(keys[key_at:],track_keys(lib,track));track.first=u32(key_at);key_at+=int(track.count)
    }
    for &clip,c in lib.clips[:lib.clip_count] {
        if placed[c][0]<0 {continue}
        clip.stream,clip.stream_bytes=u32(placed[c][0]),u32(placed[c][1])
    }
    delete(lib.keys,allocator);delete(lib.streams,allocator)
    lib.keys,lib.streams=keys,streams
    lib.key_count,lib.stream_bytes=raw_count,len(out)
    lib.prepared=true
    stats.resident_bytes=library_resident_bytes(lib)
    return stats,.None
}

// Plans the tracks of one clip and appends its stream to `out`, when any track goes in one. A
// clip without memory to measure it keeps its keys; ok is false only when `out` cannot grow.
@(private)
compress_clip :: proc(lib:^Library,clip:Clip_Data,parents:[]i32,skeleton:Skeleton,config:Compress_Config,kinds:[]Stream_Kind,held:[]bool,out:^[dynamic]u8,tables:^Compress_Tables) -> (worst,curve_worst:f32,ok:bool) {
    tracks:=lib.tracks[clip.first_track:][:clip.track_count]
    if len(tracks)>STREAM_MAX_TRACKS {return 0,0,true}
    w:=Compress_Work{first=int(clip.first_track),count=len(tracks),duration=clip.duration,skeleton=skeleton,allocator=lib.allocator,tables=tables}
    rate,rated:=compress_rate(lib,tracks,w.allocator)
    if !rated {return 0,0,true}
    // On the grid of the keys from 0; a duration between two samples makes the last interval shorter.
    w.samples=1
    if clip.duration>0 && rate>0 {w.samples=min(int(cmath.ceil(f64(clip.duration)*f64(rate)-1e-3))+1,STREAM_MAX_COUNT)}
    if w.samples>=STREAM_MAX_COUNT {return 0,0,true}
    w.rate=rate if w.samples>1 else 0
    w.fine=COMPRESS_SUBDIVISIONS*(w.samples-1)+1
    defer compress_work_free(&w)
    if !compress_work_init(&w) {return 0,0,true}
    for track,i in tracks {
        w.kind[i]=.Keys if track.count==0 else .Animated
        for j in 0..<w.fine {w.exact[i*w.fine+j]=compress_exact(lib,track,compress_time(&w,j))}
    }
    compress_bones(&w,tracks,parents,config)
    compress_classify(&w,tracks,config)
    if w.samples>1 {
        if !compress_segment(&w) {return 0,0,true}
        compress_ranges(&w,tracks)
        for s in 0..<w.segments {compress_search(&w,tracks,s,config)}
        if !compress_verify(&w,tracks,config) {return 0,0,true}
        // A track takes its keys back when they cost fewer bytes than its samples.
        for track,i in tracks {
            if w.kind[i]==.Animated && compress_track_bytes(&w,track,i)>=compress_keys_bytes(lib,track) {w.kind[i]=.Keys}
        }
    } else {
        for &kind,i in w.kind {if kind==.Animated {kind,w.value[i]=.Constant,stream_finish(w.exact[i],tracks[i].property)}}
    }
    // The stream holds the keys of a Keys track when they are linear: fewer bytes than Keyframes.
    for track,i in tracks {held[i]=w.kind[i]==.Keys && track.count>0 && compress_linear(track_keys(lib,track))}
    animated:=0
    any:=false
    for kind,i in w.kind {any ||= kind!=.Keys || held[i];if kind==.Animated {animated+=1}}
    if animated==0 {w.segments=0}
    worst,curve_worst=compress_measure(&w,tracks,config)
    copy(kinds,w.kind)
    if !any {return worst,curve_worst,true}
    return worst,curve_worst,compress_encode(&w,lib,tracks,held,out)
}

// Keys that the stream can hold: linear without easing after the first.
@(private)
compress_linear :: proc "contextless" (keys:[]Keyframe) -> bool {
    if len(keys)==0 {return false}
    for key in keys[1:] {if key.interpolation!=.Linear || key.ease!=.Linear {return false}}
    return true
}
// What the keys of a track cost: in the stream when linear, else as Keyframes.
@(private)
compress_keys_bytes :: proc "contextless" (lib:^Library,track:Track) -> int {
    keys:=track_keys(lib,track)
    if compress_linear(keys) {return 4+4*len(keys)*(1+stream_key_width(track.property))}
    return len(keys)*size_of(Keyframe)
}

@(private)
compress_work_init :: proc(w:^Compress_Work) -> bool {
    a:=w.allocator
    e:[12]runtime.Allocator_Error
    bones:=w.count+len(w.skeleton.parents)
    w.exact,e[0]=make([]math.Vec4,w.count*w.fine,a)
    w.bones,e[1]=make([]Compress_Bone,bones,a)
    w.world,e[2]=make([]math.Transform,bones*w.fine,a)
    w.order,e[3]=make([]int,2*bones,a)
    w.sorted,e[4]=make([]Compress_Bone,bones,a)
    w.bone_of,e[5]=make([]int,w.count,a)
    w.kind,e[6]=make([]Stream_Kind,w.count,a)
    w.value,e[7]=make([]math.Vec4,w.count,a)
    w.minimum,e[8]=make([]math.Vec4,w.count,a)
    w.extent,e[9]=make([]math.Vec4,w.count,a)
    w.best,e[10]=make([]u8,w.count,a)
    w.trial,e[11]=make([]u8,w.count,a)
    for value in e {if value!=nil {return false}}
    return true
}
@(private)
compress_work_free :: proc(w:^Compress_Work) {
    a:=w.allocator
    delete(w.exact,a);delete(w.bones,a);delete(w.world,a);delete(w.order,a);delete(w.sorted,a);delete(w.bone_of,a);delete(w.kind,a)
    delete(w.value,a);delete(w.minimum,a);delete(w.extent,a);delete(w.best,a);delete(w.trial,a)
    delete(w.starts,a);delete(w.rates,a);delete(w.low,a);delete(w.span,a);delete(w.middle,a)
    delete(w.lossy,a);delete(w.lossy_done,a);delete(w.decoded,a)
}
@(private)
compress_tables_free :: proc(t:^Compress_Tables) {
    for entries in t.entries {delete(entries,t.allocator)}
    t.entries={}
}

@(private)
compress_time :: #force_inline proc "contextless" (w:^Compress_Work,fine:int) -> f32 {
    if w.samples<2 {return 0}
    k:=fine/COMPRESS_SUBDIVISIONS
    at:=min(f32(k)/w.rate,w.duration)
    if fine%COMPRESS_SUBDIVISIONS==0 {return at}
    next:=min(f32(k+1)/w.rate,w.duration)
    return at+(next-at)*(f32(fine%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS)
}
// The exact value of a raw track, a rotation as a unit quaternion with w>=0.
@(private)
compress_exact :: proc "contextless" (lib:^Library,track:Track,time:f32) -> math.Vec4 {
    value:=track_evaluate(track_keys(lib,track),track.property,time)
    if track.property==.Rotation {
        value=linalg.normalize0(value)
        if value.w<0 {value=-value}
    }
    return value
}

// The rate the keys of a clip were made at: the interval most of them share, else COMPRESS_RATE.
@(private)
compress_rate :: proc(lib:^Library,tracks:[]Track,allocator:runtime.Allocator) -> (rate:f32,ok:bool) {
    count:=0
    for track in tracks {count+=max(int(track.count)-1,0)}
    if count==0 {return 0,true}
    intervals,e:=make([]f32,count,allocator);if e!=nil {return}
    defer delete(intervals,allocator)
    at:=0
    for track in tracks {
        keys:=track_keys(lib,track)
        for i in 1..<len(keys) {if keys[i].time>keys[i-1].time {intervals[at]=keys[i].time-keys[i-1].time;at+=1}}
    }
    if at==0 {return 0,true}
    sorted:=intervals[:at]
    slice.sort(sorted)
    best,best_count,start:=f32(0),0,0
    for i in 1..=len(sorted) {
        if i<len(sorted) && sorted[i]-sorted[start]<=sorted[start]*1e-3 {continue}
        if i-start>best_count {best,best_count=sorted[(start+i-1)/2],i-start}
        start=i
    }
    if best_count*4<at || !(best>0) || 1/best>FRAMES_MAX_RATE {return COMPRESS_RATE,true}
    rate=1/best
    // The interval of f32 times is off by their rounding: over the span of the longest track whose
    // keys all share it, the samples land on its keys.
    longest:=0
    for track in tracks {
        keys:=track_keys(lib,track)
        if len(keys)<3 || len(keys)<=longest {continue}
        uniform:=true
        for i in 1..<len(keys) {if abs(keys[i].time-keys[i-1].time-best)>best*1e-3 {uniform=false;break}}
        if uniform {longest=len(keys);rate=f32(f64(len(keys)-1)/(f64(keys[len(keys)-1].time)-f64(keys[0].time)))}
    }
    if whole:=cmath.round(rate);abs(rate-whole)<=whole*1e-4 {rate=whole}
    return rate,true
}

// The bones of the skeleton the clip plays on and those its other transform tracks move, parents
// first, with their rigid shells over the clip, from the exact samples. Outside a skeleton, a
// bone without a Position track sits at its parent.
@(private)
compress_bones :: proc(w:^Compress_Work,tracks:[]Track,parents:[]i32,config:Compress_Config) {
    for &bone in w.bone_of {bone=-1}
    for target,b in w.skeleton.names {
        w.bones[b]={target=target,parent=int(w.skeleton.parents[b]),tracks={-1,-1,-1},rest=w.skeleton.rest[b]}
    }
    w.bone_count=len(w.skeleton.names)
    slot_of:=[Property]int{.Rotation=0,.Position=1,.Scale=2,.Float=-1,.Vector=-1}
    for track,i in tracks {
        if track.property>.Scale || track.count==0 {continue}
        b:=-1
        for &bone,at in w.bones[:w.bone_count] {if bone.target==track.target && bone.slot==track.slot {b=at;break}}
        if b<0 {b=w.bone_count;w.bones[b]={target=track.target,slot=track.slot,parent=-1,tracks={-1,-1,-1},rest=math.TRANSFORM_IDENTITY};w.bone_count+=1}
        w.bones[b].tracks[slot_of[track.property]]=i
        w.bone_of[i]=b
    }
    bones:=w.bones[:w.bone_count]
    // A bone outside the skeleton hangs from the bone of the track `parents` names, in this clip.
    for &bone in bones[len(w.skeleton.names):] {
        if parents==nil {continue}
        parent:=int(parents[w.first+compress_bone_track(bone)])-w.first
        if parent>=0 && parent<w.count && w.bone_of[parent]>=0 {bone.parent=w.bone_of[parent]}
    }
    // Depths by walking up; a loop of parents leaves its bones without one.
    for &bone in bones {
        depth,at:=0,bone.parent
        for at>=0 && depth<=len(bones) {depth+=1;at=bones[at].parent}
        if depth>len(bones) {bone.parent=-1;depth=0}
        bone.depth=depth
    }
    // Parents first: a stable sort by depth, then parents and tracks follow their bones.
    order,moved_to:=w.order[:len(bones)],w.order[len(bones):][:len(bones)]
    for &o,i in order {o=i}
    for i in 1..<len(order) {
        at,j:=order[i],i
        for j>0 && bones[order[j-1]].depth>bones[at].depth {order[j]=order[j-1];j-=1}
        order[j]=at
    }
    sorted:=w.sorted[:len(bones)]
    for old,i in order {moved_to[old]=i;sorted[i]=bones[old]}
    for &bone in sorted {if bone.parent>=0 {bone.parent=moved_to[bone.parent]}}
    copy(bones,sorted)
    for &b in w.bone_of {if b>=0 {b=moved_to[b]}}
    longest:=0
    for bone in bones {longest=max(longest,bone.depth+1)}
    w.level=.Medium if w.samples>500 else .Highest if longest<18 else .High if longest<25 else .Medium
    for &bone,b in bones {
        for j in 0..<w.fine {
            local:=bone.rest
            if t:=bone.tracks[1];t>=0 {local.position=w.exact[t*w.fine+j].xyz}
            if t:=bone.tracks[0];t>=0 {local.rotation=vec4_quat(w.exact[t*w.fine+j])}
            if t:=bone.tracks[2];t>=0 {local.scale=w.exact[t*w.fine+j].xyz}
            w.world[b*w.fine+j]=local if bone.parent<0 else math.transform_compose(w.world[bone.parent*w.fine+j],local)
        }
    }
    compress_shells(w,0,w.fine-1,config,false)
}
@(private)
compress_bone_track :: proc "contextless" (bone:Compress_Bone) -> int {
    for t in bone.tracks {if t>=0 {return t}}
    return -1
}

// ACL's rigid shells from the leaves up, over the fine samples from..to: a bone whose child's
// shell points (and that child's precision past them, once dominated) reach farther from it than
// its own shell takes that distance and the child's precision.
@(private)
compress_shells :: proc(w:^Compress_Work,from,to:int,config:Compress_Config,segment:bool) {
    bones:=w.bones[:w.bone_count]
    for &bone in bones {
        if segment {bone.segment_shell,bone.segment_precision=config.shell,config.precision} else {bone.shell,bone.precision=config.shell,config.precision}
    }
    #reverse for &bone,b in bones {
        if bone.parent<0 {continue}
        shell:=bone.segment_shell if segment else bone.shell
        precision:=bone.segment_precision if segment else bone.precision
        reach:f32
        for j in from..=to {
            t:=w.world[b*w.fine+j]
            origin:=w.world[bone.parent*w.fine+j].position
            for axis in 0..<3 {
                point:math.Vec3;point[axis]=shell
                reach=max(reach,linalg.length(t.position+math.quat_rotate(t.rotation,point)-origin))
            }
        }
        if shell!=config.shell {reach+=precision}
        parent:=&bones[bone.parent]
        if segment {
            if reach>parent.segment_shell {parent.segment_shell,parent.segment_precision=reach,precision}
        } else if reach>parent.shell {parent.shell,parent.precision=reach,precision}
    }
}

// How far the origin and the shell points of a bone move from `exact` to `lossy`, both in the
// space of the entity: the points turn with the bone and keep its exact scale, so a bone scaled
// down by its parents is still measured in scene units.
@(private)
compress_points :: #force_inline proc "contextless" (exact,lossy:math.Transform,shell:f32) -> f32 {
    ratio:math.Vec3=1
    for c in 0..<3 {if abs(exact.scale[c])>1e-12 {ratio[c]=lossy.scale[c]/exact.scale[c]}}
    worst:=linalg.length(exact.position-lossy.position)
    for axis in 0..<3 {
        point:math.Vec3;point[axis]=shell
        a:=exact.position+math.quat_rotate(exact.rotation,point)
        b:=lossy.position+math.quat_rotate(lossy.rotation,point*ratio)
        worst=max(worst,linalg.length(a-b))
    }
    return worst
}
// How far apart two values of a curve are: the largest component.
@(private)
compress_curve_distance :: #force_inline proc "contextless" (a,b:math.Vec4,property:Property) -> f32 {
    if property==.Float {return abs(a.x-b.x)}
    return max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z),abs(a.w-b.w))
}
@(private)
compress_curve_precision :: #force_inline proc "contextless" (property:Property,config:Compress_Config) -> f32 {
    return config.float_precision if property==.Float else config.vector_precision
}
// The local transform of a bone at a fine sample with one of its tracks replaced by `value`.
@(private)
compress_local_with :: #force_inline proc "contextless" (w:^Compress_Work,bone:Compress_Bone,j:int,replaced:int,value:math.Vec4) -> math.Transform {
    local:=bone.rest
    for t,slot in bone.tracks {
        if t<0 {continue}
        v:=value if t==replaced else w.exact[t*w.fine+j]
        switch slot {
        case 0:local.rotation=vec4_quat(v)
        case 1:local.position=v.xyz
        case 2:local.scale=v.xyz
        }
    }
    return local
}
// The farthest the shell points of a bone move over the clip when one of its tracks takes the
// values `at` gives, its parents and its other tracks exact: ACL's local-space error.
@(private)
compress_track_error :: proc(w:^Compress_Work,b,t:int,at:proc(w:^Compress_Work,t,j:int,data:rawptr) -> math.Vec4,data:rawptr,limit:f32) -> f32 {
    bone:=w.bones[b]
    worst:f32
    for j in 0..<w.fine {
        local:=compress_local_with(w,bone,j,t,at(w,t,j,data))
        moved:=local if bone.parent<0 else math.transform_compose(w.world[bone.parent*w.fine+j],local)
        worst=max(worst,compress_points(w.world[b*w.fine+j],moved,bone.shell))
        if worst>limit {return worst}
    }
    return worst
}

// Which tracks hold still (Default or Constant, by ACL's test in local space on the clip's rigid
// shells) and which the samples would not follow between them: those keep their keys.
@(private)
compress_classify :: proc(w:^Compress_Work,tracks:[]Track,config:Compress_Config) {
    still :: proc(w:^Compress_Work,t,j:int,data:rawptr) -> math.Vec4 {return (^math.Vec4)(data)^}
    between :: proc(w:^Compress_Work,t,j:int,data:rawptr) -> math.Vec4 {
        property:=(^Property)(data)^
        k:=j/COMPRESS_SUBDIVISIONS
        a:=stream_finish(w.exact[t*w.fine+k*COMPRESS_SUBDIVISIONS],property)
        if j%COMPRESS_SUBDIVISIONS==0 {return a}
        return stream_mix(a,stream_finish(w.exact[t*w.fine+(k+1)*COMPRESS_SUBDIVISIONS],property),f32(j%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS,property)
    }
    defaults:=STREAM_DEFAULTS
    for track,i in tracks {
        if w.kind[i]!=.Animated {continue}
        exact:=w.exact[i*w.fine:][:w.fine]
        first:=stream_finish(exact[0],track.property)
        default_value:=defaults[track.property]
        if b:=w.bone_of[i];b>=0 {
            precision:=w.bones[b].precision
            property:=track.property
            if compress_track_error(w,b,i,still,&first,precision)<=precision {
                w.kind[i],w.value[i]=.Constant,first
                if compress_track_error(w,b,i,still,&default_value,precision)<=precision {w.kind[i],w.value[i]=.Default,default_value}
                continue
            }
            if w.samples>1 && compress_track_error(w,b,i,between,&property,precision)>precision {w.kind[i]=.Keys}
            continue
        }
        precision:=compress_curve_precision(track.property,config)
        moves,away:=false,false
        for value in exact {
            moves ||= compress_curve_distance(value,first,track.property)>precision
            away ||= compress_curve_distance(value,default_value,track.property)>precision
        }
        if !moves {
            w.kind[i],w.value[i]=.Constant,first
            if !away {w.kind[i],w.value[i]=.Default,default_value}
            continue
        }
        for j in 0..<w.fine {
            if j%COMPRESS_SUBDIVISIONS==0 {continue}
            k:=j/COMPRESS_SUBDIVISIONS
            mixed:=stream_mix(exact[k*COMPRESS_SUBDIVISIONS],exact[(k+1)*COMPRESS_SUBDIVISIONS],f32(j%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS,track.property)
            if compress_curve_distance(mixed,exact[j],track.property)>precision {w.kind[i]=.Keys;break}
        }
    }
}

// ACL's segments: SEGMENT_IDEAL samples each, the remainder spread over the others while none
// passes SEGMENT_MAX; one segment up to SEGMENT_MAX samples.
@(private)
compress_segment :: proc(w:^Compress_Work) -> bool {
    n:=w.samples
    count:=1 if n<=SEGMENT_MAX else (n+SEGMENT_IDEAL-1)/SEGMENT_IDEAL
    lengths,e:=make([]int,count,w.allocator)
    if e!=nil {return false}
    defer delete(lengths,w.allocator)
    if count==1 {lengths[0]=n} else {
        for &l in lengths {l=SEGMENT_IDEAL}
        lengths[count-1]=SEGMENT_IDEAL-(count*SEGMENT_IDEAL-n)
        if (SEGMENT_MAX-SEGMENT_IDEAL)*(count-1)>=lengths[count-1] {
            for lengths[count-1]>0 {
                for i in 0..<count-1 {
                    if lengths[count-1]==0 {break}
                    lengths[i]+=1;lengths[count-1]-=1
                }
            }
            count-=1
        }
    }
    a:=w.allocator
    e1,e2,e3,e4,e5,e6,e7:runtime.Allocator_Error
    w.segments=count
    w.starts,e1=make([]int,count+1,a)
    w.rates,e2=make([]u8,w.count*count,a)
    w.low,e3=make([]u8,w.count*count*4,a)
    w.span,e4=make([]u8,w.count*count*4,a)
    w.middle,e5=make([]u16,w.count*count*4,a)
    w.lossy,e6=make([]math.Vec4,w.count*COMPRESS_RATES*(SEGMENT_MAX+1),a)
    w.lossy_done,e7=make([]bool,w.count*COMPRESS_RATES,a)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil || e6!=nil || e7!=nil {return false}
    at:=0
    for s in 0..<count {w.starts[s]=at;at+=lengths[s]}
    w.starts[count]=n
    return true
}

// What a track stores of a value: a rotation's x, y and z with w>=0.
@(private)
compress_stored :: #force_inline proc "contextless" (v:math.Vec4,property:Property) -> math.Vec4 {
    if property==.Rotation {return v if v.w>=0 else -v}
    return v
}
// Where a stored component falls in its track's range.
@(private)
compress_normalized :: #force_inline proc "contextless" (value,minimum,extent:f32) -> f32 {
    if !(extent>=1e-9) {return 0}
    return clamp((value-minimum)/extent,0,1)
}

// The range of each Animated track over the clip and, with more than one segment, over each
// segment in 255ths of it, made to hold every sample (ACL's fixup), and the middle of it where
// the segment holds still with 0 bits.
@(private)
compress_ranges :: proc(w:^Compress_Work,tracks:[]Track) {
    for track,i in tracks {
        if w.kind[i]!=.Animated {continue}
        components:=stream_components(track.property)
        low,high:=compress_stored(w.exact[i*w.fine],track.property),compress_stored(w.exact[i*w.fine],track.property)
        for k in 0..<w.samples {
            v:=compress_stored(w.exact[i*w.fine+k*COMPRESS_SUBDIVISIONS],track.property)
            for c in 0..<components {low[c]=min(low[c],v[c]);high[c]=max(high[c],v[c])}
        }
        w.minimum[i],w.extent[i]=low,high-low
        for c in components..<4 {w.minimum[i][c],w.extent[i][c]=0,0}
        for s in 0..<w.segments {
            seg_low,seg_high:=f32(1),f32(0)
            for c in 0..<components {
                seg_low,seg_high=1,0
                for k in w.starts[s]..<w.starts[s+1] {
                    n:=compress_normalized(compress_stored(w.exact[i*w.fine+k*COMPRESS_SUBDIVISIONS],track.property)[c],w.minimum[i][c],w.extent[i][c])
                    seg_low,seg_high=min(seg_low,n),max(seg_high,n)
                }
                at:=(i*w.segments+s)*4+c
                lo:=clamp(cmath.floor(seg_low*255),0,255)
                if lo/255>seg_low {lo=max(lo-1,0)}
                ext:=clamp(cmath.ceil((seg_high-lo/255)*255),0,255-lo)
                if lo/255+ext/255<seg_high && lo+ext<255 {ext+=1}
                w.low[at],w.span[at]=u8(lo),u8(ext)
                w.middle[at]=u16(clamp((seg_low+seg_high)*.5*65535+.5,0,65535))
            }
        }
    }
}

// The decoded value of sample k of an Animated track at a bit rate, in segment s.
@(private)
compress_lossy_sample :: proc "contextless" (w:^Compress_Work,property:Property,t,k,s,rate:int) -> math.Vec4 {
    stored:=compress_stored(w.exact[t*w.fine+k*COMPRESS_SUBDIVISIONS],property)
    if rate==COMPRESS_RAW {return stream_finish(stored,property)}
    bits_table:=COMPRESS_BITS
    bits:=int(bits_table[rate])
    ranged:=w.segments>1
    low,span:[4]u8
    q:[4]u32
    for c in 0..<stream_components(property) {
        at:=(t*w.segments+s)*4+c
        if bits==0 {low[c],span[c]=u8(w.middle[at]&255),u8(w.middle[at]>>8);continue}
        if ranged {low[c],span[c]=w.low[at],w.span[at]}
        q[c]=compress_quantized(w,property,t,k,s,rate,c)
    }
    return stream_finish(stream_dequantize(w.minimum[t],w.extent[t],low,span,bits,q,ranged),property)
}

// The search of one segment: per Animated track and rate, its decoded samples of the segment,
// made when first asked.
@(private)
compress_lossy :: #force_inline proc "contextless" (w:^Compress_Work,track:Track,t,k,s,rate:int) -> math.Vec4 {
    slot:=t*COMPRESS_RATES+rate
    local:=k-w.starts[s]
    if !w.lossy_done[slot] {
        for sample in w.starts[s]..<w.starts[s+1] {w.lossy[slot*(SEGMENT_MAX+1)+sample-w.starts[s]]=compress_lossy_sample(w,track.property,t,sample,s,rate)}
        w.lossy_done[slot]=true
    }
    return w.lossy[slot*(SEGMENT_MAX+1)+local]
}
// The value a track decodes at fine sample j of segment s with the rates of `rates`: the first
// sample of the next segment is taken exact while this one is searched.
@(private)
compress_value :: #force_inline proc "contextless" (w:^Compress_Work,tracks:[]Track,rates:[]u8,t,j,s:int) -> math.Vec4 {
    switch w.kind[t] {
    case .Default,.Constant:return w.value[t]
    case .Keys:return w.exact[t*w.fine+j]
    case .Animated:
    }
    property:=tracks[t].property
    k:=j/COMPRESS_SUBDIVISIONS
    sample :: #force_inline proc "contextless" (w:^Compress_Work,tracks:[]Track,rates:[]u8,t,k,s:int) -> math.Vec4 {
        if k>=w.starts[s+1] {return stream_finish(compress_stored(w.exact[t*w.fine+k*COMPRESS_SUBDIVISIONS],tracks[t].property),tracks[t].property)}
        return compress_lossy(w,tracks[t],t,k,s,int(rates[t]))
    }
    a:=sample(w,tracks,rates,t,k,s)
    if j%COMPRESS_SUBDIVISIONS==0 {return a}
    return stream_mix(a,sample(w,tracks,rates,t,k+1,s),f32(j%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS,property)
}
@(private)
compress_local :: #force_inline proc "contextless" (w:^Compress_Work,tracks:[]Track,rates:[]u8,bone:Compress_Bone,j,s:int) -> math.Transform {
    local:=bone.rest
    if t:=bone.tracks[0];t>=0 {local.rotation=vec4_quat(compress_value(w,tracks,rates,t,j,s))}
    if t:=bone.tracks[1];t>=0 {local.position=compress_value(w,tracks,rates,t,j,s).xyz}
    if t:=bone.tracks[2];t>=0 {local.scale=compress_value(w,tracks,rates,t,j,s).xyz}
    return local
}
// The fine samples of segment s: from its first sample to the first of the next.
@(private)
compress_fine_range :: #force_inline proc "contextless" (w:^Compress_Work,s:int) -> (from,to:int) {
    return w.starts[s]*COMPRESS_SUBDIVISIONS,min(w.starts[s+1],w.samples-1)*COMPRESS_SUBDIVISIONS
}
// ACL's errors of bone b over segment s with `rates`: in local space (its parents exact) or in
// object space (its chain decoded). Stops at the first fine sample at `limit` or beyond.
@(private)
compress_local_error :: proc "contextless" (w:^Compress_Work,tracks:[]Track,rates:[]u8,b,s:int,limit:f32) -> f32 {
    bone:=w.bones[b]
    from,to:=compress_fine_range(w,s)
    worst:f32
    for j in from..=to {
        local:=compress_local(w,tracks,rates,bone,j,s)
        moved:=local if bone.parent<0 else math.transform_compose(w.world[bone.parent*w.fine+j],local)
        worst=max(worst,compress_points(w.world[b*w.fine+j],moved,bone.segment_shell))
        if worst>=limit {return worst}
    }
    return worst
}
@(private)
compress_object_error :: proc "contextless" (w:^Compress_Work,tracks:[]Track,rates:[]u8,chain:[]int,s:int,limit:f32) -> f32 {
    b:=chain[len(chain)-1]
    from,to:=compress_fine_range(w,s)
    worst:f32
    for j in from..=to {
        moved:=math.TRANSFORM_IDENTITY
        for bone,i in chain {
            local:=compress_local(w,tracks,rates,w.bones[bone],j,s)
            moved=local if i==0 && w.bones[bone].parent<0 else math.transform_compose(moved if i>0 else w.world[w.bones[bone].parent*w.fine+j],local)
        }
        worst=max(worst,compress_points(w.world[b*w.fine+j],moved,w.bones[b].segment_shell))
        if worst>=limit {return worst}
    }
    return worst
}

// The slots of a bone that the search may change in a segment: those of its Animated tracks.
@(private)
compress_free :: #force_inline proc "contextless" (w:^Compress_Work,bone:Compress_Bone) -> (mask:int) {
    for t,slot in bone.tracks {if t>=0 && w.kind[t]==.Animated {mask|=1<<uint(slot)}}
    return
}
@(private)
compress_size :: #force_inline proc "contextless" (rates:[3]u8) -> int {
    bits:=COMPRESS_BITS
    size:=0
    for r in rates {if r!=COMPRESS_FIXED {size+=int(bits[r])}}
    return size
}
// The combinations of rates of the slots in `mask`, sorted by bits and then by rate.
@(private)
compress_table :: proc(tables:^Compress_Tables,mask:int) -> [][3]u8 {
    if tables.entries[mask]!=nil {return tables.entries[mask]}
    free:=0
    for slot in 0..<3 {if mask&(1<<uint(slot))!=0 {free+=1}}
    count:=1
    for _ in 0..<free {count*=COMPRESS_RATES}
    entries,e:=make([][3]u8,count,tables.allocator)
    if e!=nil {return nil}
    for &entry,i in entries {
        at:=i
        entry={COMPRESS_FIXED,COMPRESS_FIXED,COMPRESS_FIXED}
        for slot:=2;slot>=0;slot-=1 {
            if mask&(1<<uint(slot))==0 {continue}
            entry[slot]=u8(at%COMPRESS_RATES);at/=COMPRESS_RATES
        }
    }
    slice.stable_sort_by(entries,proc(a,b:[3]u8) -> bool {
        sa,sb:=compress_size(a),compress_size(b)
        if sa!=sb {return sa<sb}
        for slot in 0..<3 {if a[slot]!=b[slot] {return a[slot]<b[slot]}}
        return false
    })
    tables.entries[mask]=entries
    return entries
}

@(private)
compress_get :: #force_inline proc "contextless" (w:^Compress_Work,rates:[]u8,bone:Compress_Bone) -> (r:[3]u8) {
    for t,slot in bone.tracks {r[slot]=rates[t] if t>=0 && w.kind[t]==.Animated else COMPRESS_FIXED}
    return
}
@(private)
compress_put :: #force_inline proc "contextless" (w:^Compress_Work,rates:[]u8,bone:Compress_Bone,r:[3]u8) {
    for t,slot in bone.tracks {if t>=0 && w.kind[t]==.Animated {rates[t]=r[slot]}}
}

// The bit rates of segment s by ACL's search: per bone the cheapest rates that keep it within its
// precision in local space, then, parents first, raising the rates of each bone's chain until it
// is within its precision in object space. Curves take the lowest rate within their precision.
@(private)
compress_search :: proc(w:^Compress_Work,tracks:[]Track,s:int,config:Compress_Config) {
    for &done in w.lossy_done {done=false}
    from,to:=compress_fine_range(w,s)
    compress_shells(w,w.starts[s]*COMPRESS_SUBDIVISIONS,to,config,true)
    rates:=w.rates[s*w.count:][:w.count]
    lowest:=u8(0 if w.segments>1 else 1)
    for &r,t in rates {r=lowest if w.kind[t]==.Animated else COMPRESS_FIXED}
    // Curves.
    for track,t in tracks {
        if w.kind[t]!=.Animated || w.bone_of[t]>=0 {continue}
        precision:=compress_curve_precision(track.property,config)
        for rate in int(lowest)..<COMPRESS_RATES {
            rates[t]=u8(rate)
            worst:f32
            for j in from..=to {worst=max(worst,compress_curve_distance(compress_value(w,tracks,rates,t,j,s),w.exact[t*w.fine+j],track.property))}
            if worst<=precision {break}
        }
    }
    bones:=w.bones[:w.bone_count]
    // Pass 1: local space.
    for &bone,b in bones {
        mask:=compress_free(w,bone)
        if mask==0 {continue}
        threshold:=bone.segment_precision
        best,best_error:=compress_get(w,rates,bone),max(f32)
        previous,good:=-1,false
        for entry in compress_table(w.tables,mask) {
            if lowest==1 && (entry[0]==0 || entry[1]==0 || entry[2]==0) {continue}
            size:=compress_size(entry)
            if size!=previous && good {break}
            previous=size
            compress_put(w,rates,bone,entry)
            e:=compress_local_error(w,tracks,rates,b,s,threshold)
            if e<best_error {best_error,best,good=e,entry,e<threshold}
        }
        compress_put(w,rates,bone,best)
    }
    // Pass 2: object space, parents first.
    chain_buffer:[256]int
    for _,b in bones {
        n:=0
        for at:=b;at>=0 && n<len(chain_buffer);at=bones[at].parent {chain_buffer[n]=at;n+=1}
        chain:=chain_buffer[:n]
        slice.reverse(chain)
        movable:=false
        for bone in chain {movable ||= compress_free(w,bones[bone])!=0}
        if !movable {continue}
        threshold:=bones[b].segment_precision
        e:=compress_object_error(w,tracks,rates,chain,s,threshold)
        if e<threshold {continue}
        for e>=threshold {
            original,best:=e,e
            accepted:=false
            plans:[6][3]int
            plan_count:=1
            plans[0]={0,0,1}
            if w.level>=.High {plans[1]={0,0,2};plans[2]={0,1,1};plan_count=3}
            if w.level==.Highest {plans[3]={0,0,3};plans[4]={0,2,1};plans[5]={1,1,1};plan_count=6}
            for plan in plans[:plan_count] {
                tried:=compress_plan(w,tracks,rates,chain,s,plan,original,threshold)
                if tried<best {best=tried;copy(rates,w.best)}
                if tried<threshold {accepted=true;break}
            }
            if accepted {e=best;break}
            if best>=original {break}
            e=best
        }
        if e<threshold {continue}
        // Raise the smallest rate of each bone of the chain from b up while that lowers the error.
        for {
            e=compress_object_error(w,tracks,rates,chain,s,max(f32))
            if e<threshold {break}
            raised:=false
            #reverse for bone in chain {
                current:=compress_get(w,rates,bones[bone])
                slot,lowest_rate:=-1,COMPRESS_RAW
                for r,i in current {if r!=COMPRESS_FIXED && int(r)<lowest_rate {slot,lowest_rate=i,int(r)}}
                if slot<0 {continue}
                current[slot]+=1
                compress_put(w,rates,bones[bone],current)
                raised=true
                if compress_object_error(w,tracks,rates,chain,s,threshold)<threshold {break}
            }
            if !raised {break}
        }
    }
}


// Tries the arrangements of `plan` (increments of the last bones of a chain, ACL's plans) over
// the chain, as std::next_permutation gives them from the plan laid on its end; the rates with the
// lowest error go to w.best. Each bone takes the split of its increment over its slots that
// lowers the error most with it alone raised.
@(private)
compress_plan :: proc(w:^Compress_Work,tracks:[]Track,rates:[]u8,chain:[]int,s:int,plan:[3]int,original,threshold:f32) -> f32 {
    n:=len(chain)
    best:=max(f32)
    values:[3]int
    count:=0
    for v in plan {if v>0 {values[count]=v;count+=1}}
    if count>n || n>256 {return best}
    increments:[256]int
    arrangement:=increments[:n]
    for i in 0..<count {arrangement[n-count+i]=values[i]}
    for {
        copy(w.trial,rates)
        valid:=false
        for inc,i in arrangement {
            if inc==0 {continue}
            bone:=w.bones[chain[i]]
            if raised,ok:=compress_raise(w,tracks,rates,chain,bone,inc,original,s);ok {valid=true;compress_put(w,w.trial,bone,raised)}
        }
        if valid {
            e:=compress_object_error(w,tracks,w.trial,chain,s,threshold)
            if e<best {
                best=e;copy(w.best,w.trial)
                if e<threshold {return best}
            }
        }
        if !compress_next_permutation(arrangement) {break}
    }
    return best
}
// ACL's increase of one bone: every split of `increment` over its slots, each measured with only
// this bone raised; the best when it lowers the error below `original`.
@(private)
compress_raise :: proc(w:^Compress_Work,tracks:[]Track,rates:[]u8,chain:[]int,bone:Compress_Bone,increment:int,original:f32,s:int) -> (best:[3]u8,ok:bool) {
    current:=compress_get(w,rates,bone)
    best=current
    best_error:=original
    for a in 0..=increment {
        for b in 0..=increment-a {
            split:=[3]int{a,b,increment-a-b}
            trial:=current
            skip:=false
            for slot in 0..<3 {
                if trial[slot]==COMPRESS_FIXED {skip ||= split[slot]!=0;continue}
                trial[slot]=u8(min(int(trial[slot])+split[slot],COMPRESS_RAW))
            }
            if skip || trial==current {continue}
            compress_put(w,rates,bone,trial)
            e:=compress_object_error(w,tracks,rates,chain,s,best_error)
            compress_put(w,rates,bone,current)
            if e<best_error {best_error,best,ok=e,trial,true}
        }
    }
    return
}
@(private)
compress_next_permutation :: proc "contextless" (a:[]int) -> bool {
    i:=len(a)-2
    for i>=0 && a[i]>=a[i+1] {i-=1}
    if i<0 {return false}
    j:=len(a)-1
    for a[j]<=a[i] {j-=1}
    a[i],a[j]=a[j],a[i]
    for l,h:=i+1,len(a)-1;l<h;l,h=l+1,h-1 {a[l],a[h]=a[h],a[l]}
    return true
}

// The values of every Animated track at its samples, decoded at the rates chosen.
@(private)
compress_decode_all :: proc "contextless" (w:^Compress_Work,tracks:[]Track) {
    for track,t in tracks {
        if w.kind[t]!=.Animated {continue}
        for s in 0..<w.segments {
            for k in w.starts[s]..<w.starts[s+1] {w.decoded[t*w.samples+k]=compress_lossy_sample(w,track.property,t,k,s,int(w.rates[s*w.count+t]))}
        }
    }
}
@(private)
compress_final_value :: #force_inline proc "contextless" (w:^Compress_Work,tracks:[]Track,t,j:int,exact_track:=-1) -> math.Vec4 {
    if t==exact_track {return w.exact[t*w.fine+j]}
    switch w.kind[t] {
    case .Default,.Constant:return w.value[t]
    case .Keys:return w.exact[t*w.fine+j]
    case .Animated:
    }
    k:=j/COMPRESS_SUBDIVISIONS
    a:=w.decoded[t*w.samples+k]
    if j%COMPRESS_SUBDIVISIONS==0 {return a}
    return stream_mix(a,w.decoded[t*w.samples+k+1],f32(j%COMPRESS_SUBDIVISIONS)/COMPRESS_SUBDIVISIONS,tracks[t].property)
}
// The decoded transform of bone b at fine sample j in the space of the entity, its chain decoded,
// with one track exact when exact_track names it.
@(private)
compress_final_world :: proc "contextless" (w:^Compress_Work,tracks:[]Track,b,j:int,exact_track:=-1) -> math.Transform {
    chain:[256]int
    n:=0
    for at:=b;at>=0 && n<len(chain);at=w.bones[at].parent {chain[n]=at;n+=1}
    moved:=math.TRANSFORM_IDENTITY
    for i:=n-1;i>=0;i-=1 {
        bone:=w.bones[chain[i]]
        local:=bone.rest
        if t:=bone.tracks[0];t>=0 {local.rotation=vec4_quat(compress_final_value(w,tracks,t,j,exact_track))}
        if t:=bone.tracks[1];t>=0 {local.position=compress_final_value(w,tracks,t,j,exact_track).xyz}
        if t:=bone.tracks[2];t>=0 {local.scale=compress_final_value(w,tracks,t,j,exact_track).xyz}
        moved=local if i==n-1 else math.transform_compose(moved,local)
    }
    return moved
}
@(private)
compress_segment_of :: #force_inline proc "contextless" (w:^Compress_Work,k:int) -> int {
    s:=0
    for s+1<w.segments && w.starts[s+1]<=k {s+=1}
    return s
}

// Measures the whole clip as the runtime decodes it, the samples of one segment next to those of
// the next: where a shell point at config.shell or a curve moves too far, raises the rate that
// makes it move most, until nothing does or nothing can be raised.
@(private)
compress_verify :: proc(w:^Compress_Work,tracks:[]Track,config:Compress_Config) -> bool {
    if w.decoded==nil {
        e:runtime.Allocator_Error
        if w.decoded,e=make([]math.Vec4,w.count*w.samples,w.allocator);e!=nil {return false}
    }
    for _ in 0..<4096 {
        compress_decode_all(w,tracks)
        raised:=false
        for b in 0..<w.bone_count {
            for j in 0..<w.fine {
                exact:=w.world[b*w.fine+j]
                e:=compress_points(exact,compress_final_world(w,tracks,b,j),config.shell)
                if e<=config.precision {continue}
                k:=j/COMPRESS_SUBDIVISIONS
                sides:=[2]int{k,min(k+1,w.samples-1)} if j%COMPRESS_SUBDIVISIONS!=0 else [2]int{k,k}
                best,best_track,best_segment:=e,-1,-1
                for at:=b;at>=0;at=w.bones[at].parent {
                    for t in w.bones[at].tracks {
                        if t<0 || w.kind[t]!=.Animated {continue}
                        left:=compress_points(exact,compress_final_world(w,tracks,b,j,t),config.shell)
                        if left>=best {continue}
                        for k_side in sides {
                            s:=compress_segment_of(w,k_side)
                            if int(w.rates[s*w.count+t])>=COMPRESS_RAW {continue}
                            best,best_track,best_segment=left,t,s
                            break
                        }
                    }
                }
                if best_track<0 {continue}
                w.rates[best_segment*w.count+best_track]+=1
                raised=true
            }
        }
        for track,t in tracks {
            if w.kind[t]!=.Animated || w.bone_of[t]>=0 {continue}
            precision:=compress_curve_precision(track.property,config)
            for j in 0..<w.fine {
                if compress_curve_distance(compress_final_value(w,tracks,t,j),w.exact[t*w.fine+j],track.property)<=precision {continue}
                k:=j/COMPRESS_SUBDIVISIONS
                for k_side in ([2]int{k,min(k+1,w.samples-1)}) {
                    s:=compress_segment_of(w,k_side)
                    if int(w.rates[s*w.count+t])<COMPRESS_RAW {w.rates[s*w.count+t]+=1;raised=true}
                }
            }
        }
        if !raised {break}
    }
    return true
}

// The farthest a shell point at config.shell and a curve component move over the clip.
@(private)
compress_measure :: proc "contextless" (w:^Compress_Work,tracks:[]Track,config:Compress_Config) -> (worst,curve_worst:f32) {
    if w.decoded!=nil {compress_decode_all(w,tracks)}
    for b in 0..<w.bone_count {
        for j in 0..<w.fine {worst=max(worst,compress_points(w.world[b*w.fine+j],compress_final_world(w,tracks,b,j),config.shell))}
    }
    for track,t in tracks {
        if w.bone_of[t]>=0 || w.kind[t]==.Keys {continue}
        for j in 0..<w.fine {curve_worst=max(curve_worst,compress_curve_distance(compress_final_value(w,tracks,t,j),w.exact[t*w.fine+j],track.property))}
    }
    return
}

@(private)
compress_track_bytes :: proc "contextless" (w:^Compress_Work,track:Track,t:int) -> int {
    components:=stream_components(track.property)
    bits_table:=COMPRESS_BITS
    total_bits:=8*8*components
    for s in 0..<w.segments {
        bits:=int(bits_table[w.rates[s*w.count+t]])
        total_bits+=8+bits*components*(w.starts[s+1]-w.starts[s])
        if w.segments>1 && bits!=STREAM_RAW {total_bits+=16*components}
    }
    return (total_bits+7)/8
}

// The quantized component c of sample k of an Animated track in segment s at a bit rate.
@(private)
compress_quantized :: #force_inline proc "contextless" (w:^Compress_Work,property:Property,t,k,s,rate,c:int) -> u32 {
    stored:=compress_stored(w.exact[t*w.fine+k*COMPRESS_SUBDIVISIONS],property)
    bits_table:=COMPRESS_BITS
    bits:=int(bits_table[rate])
    if bits==STREAM_RAW {return transmute(u32)stored[c]}
    if bits==0 {return 0}
    at:=(t*w.segments+s)*4+c
    n:=compress_normalized(stored[c],w.minimum[t][c],w.extent[t][c])
    m:=n
    if w.segments>1 {m=clamp((n*255-f32(w.low[at]))/f32(w.span[at]),0,1) if w.span[at]>0 else 0}
    return u32(m*f32(u32(1)<<uint(bits)-1)+.5)
}

@(private)
compress_put_bytes :: proc(out:^[dynamic]u8,value:$T) -> bool {
    v:=value
    bytes:=transmute([size_of(T)]u8)v
    _,e:=append(out,..bytes[:])
    return e==nil
}

// Appends the stream of the clip, as stream_decode reads it. False when `out` cannot grow.
@(private)
compress_encode :: proc(w:^Compress_Work,lib:^Library,tracks:[]Track,held:[]bool,out:^[dynamic]u8) -> bool {
    put :: compress_put_bytes
    start:=len(out)
    // The Animated tracks in the blocks of the stream's order.
    order,e:=make([dynamic]int,0,w.count,w.allocator)
    if e!=nil {return false}
    defer delete(order)
    for block in 0..<3 {for track,t in tracks {if w.kind[t]==.Animated && stream_block(track.property)==block {append(&order,t)}}}
    h:=Stream_Header{count=u32(max(w.samples,1)),rate=w.rate,duration=w.duration,tracks=u32(w.count),segments=u32(w.segments)}
    for kind,t in w.kind {
        if kind==.Constant {h.constants+=1}
        if kind!=.Animated {continue}
        h.animated+=1
        switch stream_block(tracks[t].property) {
        case 0:h.rotations+=1
        case 1:h.threes+=1
        }
    }
    if h.animated==0 {h.count,h.rate,h.segments=1,0,0}
    if !put(out,h) {return false}
    for i:=0;i<w.count;i+=2 {
        code:u8
        for side in 0..<2 {
            if i+side>=w.count {break}
            width:=u8(3) if w.kind[i+side]==.Keys && !held[i+side] else u8(stream_width(tracks[i+side].property))
            code|=(u8(w.kind[i+side])|width<<2)<<uint(4*side)
        }
        if !put(out,code) {return false}
    }
    for track,t in tracks {
        if w.kind[t]!=.Constant {continue}
        for c in 0..<stream_components(track.property) {if !put(out,w.value[t][c]) {return false}}
    }
    h.keys=u32(len(out)-start)
    for track,t in tracks {
        if !held[t] {continue}
        keys:=track_keys(lib,track)
        width:=stream_key_width(track.property)
        h.keyed+=1
        if !put(out,u32(len(keys))|u32(width)<<28) {return false}
        for key in keys {if !put(out,key.time) {return false}}
        for key in keys {for c in 0..<width {if !put(out,key.value[c]) {return false}}}
    }
    h.order=u32(len(out)-start)
    for t in order {if !put(out,u16(t)) {return false}}
    h.ranges=u32(len(out)-start)
    for side in 0..<2 {
        for t in order {
            for c in 0..<stream_components(tracks[t].property) {if !put(out,w.minimum[t][c] if side==0 else w.extent[t][c]) {return false}}
        }
    }
    h.table=u32(len(out)-start)
    if h.animated>0 {
        table:=len(out)
        for _ in 0..<w.segments {if !put(out,Stream_Segment{}) {return false}}
        bits_table:=COMPRESS_BITS
        for s in 0..<w.segments {
            segment:=Stream_Segment{start=u32(w.starts[s]),bits=u32(len(out)-start)}
            for t in order {
                bits:=bits_table[w.rates[s*w.count+t]]
                if !put(out,bits) {return false}
                segment.stride+=u32(int(bits)*stream_components(tracks[t].property))
            }
            if w.segments>1 {
                for t in order {
                    bits:=bits_table[w.rates[s*w.count+t]]
                    if bits==STREAM_RAW {continue}
                    for c in 0..<stream_components(tracks[t].property) {
                        at:=(t*w.segments+s)*4+c
                        pair:=[2]u8{w.low[at],w.span[at]} if bits>0 else [2]u8{u8(w.middle[at]&255),u8(w.middle[at]>>8)}
                        if !put(out,pair) {return false}
                    }
                }
            }
            segment.samples=u32(len(out)-start)
            word:u64;used:uint
            for k in w.starts[s]..<w.starts[s+1] {
                for t in order {
                    track:=tracks[t]
                    rate:=int(w.rates[s*w.count+t])
                    bits:=uint(bits_table[rate])
                    if bits==0 {continue}
                    for c in 0..<stream_components(track.property) {
                        word|=u64(compress_quantized(w,track.property,t,k,s,rate,c))<<used;used+=bits
                        for used>=8 {if !put(out,u8(word)) {return false};word>>=8;used-=8}
                    }
                }
            }
            if used>0 {if !put(out,u8(word)) {return false}}
            bytes:=transmute([size_of(Stream_Segment)]u8)segment
            copy(out[table+s*size_of(Stream_Segment):],bytes[:])
        }
    }
    h.bytes=u32(len(out)-start)
    bytes:=transmute([size_of(Stream_Header)]u8)h
    copy(out[start:],bytes[:])
    return true
}
