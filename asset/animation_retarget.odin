package asset

import "core:math/linalg"
import "core:slice"
import anim "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// A clip made on another skeleton (the .skeleton its clip names) plays on a skeleton it was not
// made on as the retarget of its .anim onto that skeleton: an .anim of the same clips, curves,
// markers and names whose bone tracks are those of that skeleton. It binds by name as it is when
// every bone it moves has, on that skeleton, a bone of its path with the same parent and rest (a
// variant with an extra bone, a skeleton imported twice): an .anim whose clips all do needs no
// retarget (direct). Otherwise its bones pair by name or path, else by the parts of the body both
// .skeletons mark (anim.retarget_map), with the crotch kept off the floor
// (anim.retarget_crotch_pose), and each clip is sampled at its own rate into raw keys, leaving
// out the channels that stay at the rest of their bone, which animation_compress then compresses
// as any .anim. A cooked .anim (of a shipped game) retargets as well: what it keeps in streams is
// sampled at the rate of its clip. The cook writes it for each .anim and skeleton a scene plays
// together or cook.mirai declares, as the cooked .anim of animation_retarget_id; an application,
// a shipped game too, makes any other in a job (host.content_animation_retarget). Both make it
// here.

// Raise it when a retarget is made otherwise from the same inputs: what caches keep is made again.
ANIMATION_RETARGET_VERSION :: 1
// How far two rests may differ and still be the same bone: of a translation, relative to its
// length past one unit; of a rotation, 1 minus the absolute dot of the quaternions; of a scale.
ANIMATION_RETARGET_REST_TOLERANCE :: 1e-4
// What a retargeted channel may stay from the rest of its bone and still be left out.
ANIMATION_RETARGET_STATIC_TOLERANCE :: 1e-5

Animation_Retarget_Failure :: enum u8 {
    None,
    Unread,        // a skeleton, `failed`, cannot be read
    Unpaired,      // the skeleton `failed` shares no bone name and no part of the body with the target
    Invalid,       // the .anim does not hold together, or a clip does not sample
    Out_Of_Memory,
    Budget,        // the application has no room left for it (host.App_Desc.retarget_budget)
}

// The retarget of an .anim onto a skeleton: view holds its clips as raw keys in the allocator it
// was made with (animation_retarget_free), none when direct or failed.
Animation_Retarget :: struct {
    view:Animation_View,
    direct:bool,                 // every clip binds by name: the .anim plays as it is
    failure:Animation_Retarget_Failure,
    failed:base.Asset_Id,        // the skeleton the failure is about
}

// The id of the retarget of an .anim onto a skeleton: that of the cooked .anim a cook writes for
// it, and its place in the content of an application.
animation_retarget_id :: proc "contextless" (animation,skeleton:base.Asset_Id) -> base.Asset_Id {
    SALT :: 0x7265746172676574 // "retarget"
    return {base.hash_combine(base.hash_combine(animation[0],skeleton[0]),SALT),base.hash_combine(base.hash_combine(animation[1],skeleton[1]),SALT)}
}

// Whether a clip of a skeleton other than `skeleton` is among those of view: only then can it
// need a retarget onto it.
animation_retarget_needed :: proc "contextless" (skeletons:[]base.Asset_Id,skeleton:base.Asset_Id) -> bool {
    for id in skeletons {if id!={} && id!=skeleton {return true}}
    return false
}

animation_retarget_free :: proc(retarget:^Animation_Retarget,allocator:=context.allocator) {
    delete(retarget.view.clips,allocator);delete(retarget.view.tracks,allocator);delete(retarget.view.keys,allocator)
    retarget.view={}
}

// The retarget of a checked view onto the skeleton `skeleton`, whose .skeleton and those of the
// clips `open` opens. Scratch goes to the temp allocator; the view to allocator.
animation_retarget :: proc(view:Animation_View,types:^Types,open:Skeleton_Open,data:rawptr,skeleton:base.Asset_Id,allocator:=context.allocator) -> (out:Animation_Retarget) {
    if !animation_check(view) || skeleton=={} || open==nil {out.failure=.Invalid;return}
    scratch:=context.temp_allocator
    ids:=make([dynamic]base.Asset_Id,scratch)
    for clip in view.clips {if clip.skeleton!={} && clip.skeleton!=skeleton && !slice.contains(ids[:],clip.skeleton) {append(&ids,clip.skeleton)}}
    if len(ids)==0 {out.direct=true;return}
    target:Retarget_Skeleton
    if !retarget_skeleton(&target,types,open,data,skeleton) {out.failure,out.failed=.Unread,skeleton;return}
    sources:=make([]Retarget_Skeleton,len(ids),scratch)
    for id,i in ids {
        if !retarget_skeleton(&sources[i],types,open,data,id) {out.failure,out.failed=.Unread,id;return}
    }
    library:anim.Library
    desc:=animation_library_desc(view);desc.allocator=scratch
    if !anim.library_init(&library,desc) {out.failure=.Out_Of_Memory;return}
    if len(view.clips)>0 && animation_clips_add(view,&library)==0 {out.failure=.Invalid;return}
    // A cooked .anim (that of a shipped game) holds streams, which the library samples as they are.
    for track in view.tracks {if track.encoding!=.Raw {library.prepared=true;break}}
    // Which clips keep their tracks and which take those of the target.
    retargeted:=make([]i32,len(view.clips),scratch) // the source skeleton a clip retargets from, -1: kept
    any:=false
    for clip,c in view.clips {
        retargeted[c]=-1
        if clip.skeleton=={} || clip.skeleton==skeleton {continue}
        at,_:=slice.linear_search(ids[:],clip.skeleton)
        if animation_clip_binds(&library,anim.Clip(c+1),sources[at].bones,sources[at].sorted,target.bones,target.sorted) {continue}
        retargeted[c]=i32(at);any=true
    }
    if !any {out.direct=true;return}
    pairs:=make([]Retarget_Pair,len(ids),scratch)
    for at in retargeted {
        if at<0 || pairs[at].tried {continue}
        pair:=&pairs[at];pair.tried=true
        if !retarget_pair(pair,&sources[at],&target) {out.failure,out.failed=.Unpaired,ids[at];return}
    }
    n:=len(target.bones)
    clips,no_clips:=make([dynamic]Animation_Clip,0,len(view.clips),allocator)
    if no_clips!=nil {out.failure=.Out_Of_Memory;return}
    tracks:=make([dynamic]Animation_Track,allocator)
    keys:=make([dynamic]anim.Keyframe,allocator)
    defer if out.failure!=.None {delete(clips);delete(tracks);delete(keys)}
    for clip,c in view.clips {
        own:=view.tracks[clip.first_track:][:clip.track_count]
        made:=clip
        made.first_track,made.stream,made.stream_bytes=u32(len(tracks)),0,0
        at:=retargeted[c]
        if at<0 {
            for track,i in own {
                if out.failure=retarget_keep(&library,c,i,track,view,&tracks,&keys);out.failure!=.None {return}
            }
        } else {
            source:=&sources[at];pair:=&pairs[at]
            m:=len(source.bones)
            rate:=anim.clip_rate(&library,anim.Clip(c+1))
            duration:=anim.clip_duration(&library,anim.Clip(c+1))
            samples,exact:=anim.frames_layout(duration,rate,ANIMATION_MAX_KEYS)
            if samples==0 {samples,exact=1,rate}
            if samples>ANIMATION_MAX_KEYS/max(3*n,1) {out.failure=.Invalid;return}
            bindings:=make([]anim.Bone_Tracks,m,scratch)
            source_local:=make([]mm.Transform,m,scratch);source_world:=make([]mm.Transform,m,scratch)
            target_world:=make([]mm.Transform,n,scratch)
            poses,no_poses:=make([]mm.Transform,samples*n,scratch)
            if no_poses!=nil {out.failure=.Out_Of_Memory;return}
            if !anim.skeleton_bind(&library,anim.Clip(c+1),source.rig,bindings) {out.failure=.Invalid;return}
            for frame in 0..<samples {
                time:=min(f32(frame)/exact,duration)
                pose:=poses[frame*n:][:n]
                sampled:=anim.skeleton_sample(&library,bindings,source.rig.rest,time,source_local)
                sampled&&=anim.retarget_pose(source.rig,target.rig,pair.prepared,source_local,source_world,target_world,pose)
                sampled&&=anim.retarget_crotch_pose(target.rig,pair.crotch,source_world,pose,target_world)
                if !sampled {out.failure=.Invalid;return}
            }
            for b in 0..<n {
                for property in ([3]anim.Property{.Position,.Rotation,.Scale}) {
                    if retarget_static(poses,n,b,property,target.rig.rest[b]) {continue}
                    track:=Animation_Track{target=target.bones[b].path,property=property,first_key=u32(len(keys)),key_count=u32(samples)}
                    previous:mm.Vec4
                    for frame in 0..<samples {
                        value:=poses[frame*n+b]
                        key:=anim.Keyframe{time=min(f32(frame)/exact,duration),interpolation=.Linear}
                        switch property {
                        case .Position: key.value={value.position.x,value.position.y,value.position.z,0}
                        case .Scale: key.value={value.scale.x,value.scale.y,value.scale.z,0}
                        case .Rotation:
                            key.value=anim.quat_vec4(value.rotation)
                            // Each key on the side of the one before, so a key blends the short way.
                            if frame>0 && linalg.dot(key.value,previous)<0 {key.value=-key.value}
                            previous=key.value
                        case .Float,.Vector:
                        }
                        if _,error:=append(&keys,key);error!=nil {out.failure=.Out_Of_Memory;return}
                    }
                    if _,error:=append(&tracks,track);error!=nil {out.failure=.Out_Of_Memory;return}
                }
            }
            // Curves keep their keys.
            for track,i in own {
                if track.property!=.Float && track.property!=.Vector {continue}
                if out.failure=retarget_keep(&library,c,i,track,view,&tracks,&keys);out.failure!=.None {return}
            }
            made.skeleton=skeleton
            // The root bone follows its pair, else the clip moves no root.
            if made.root.translation || made.root.rotation {
                from:=retarget_bone_named(source.bones,made.root.bone)
                to:=-1
                if from>=0 {for bone,b in pair.mapping {if int(bone)==from {to=b;break}}}
                made.root.bone={}
                if to>=0 {made.root.bone=target.bones[to].path} else {made.root.translation,made.root.rotation=false,false}
            }
        }
        made.track_count=u32(len(tracks))-made.first_track
        if _,error:=append(&clips,made);error!=nil {out.failure=.Out_Of_Memory;return}
    }
    if len(tracks)>ANIMATION_MAX_TRACKS || len(keys)>ANIMATION_MAX_KEYS {out.failure=.Invalid;return}
    out.view={clips=clips[:],tracks=tracks[:],keys=keys[:],markers=view.markers,source=view.source}
    if !animation_check(out.view) {out.failure=.Invalid;return}
    return
}

// Appends track i of clip c as raw keys: its own, or, of one a stream holds, its values sampled at
// the rate of the clip.
@(private="file")
retarget_keep :: proc(library:^anim.Library,c,i:int,track:Animation_Track,view:Animation_View,tracks:^[dynamic]Animation_Track,keys:^[dynamic]anim.Keyframe) -> Animation_Retarget_Failure {
    kept:=track
    kept.encoding,kept.first_key=.Raw,u32(len(keys))
    if track.encoding==.Raw {
        if _,error:=append(keys,..view.keys[track.first_key:][:track.key_count]);error!=nil {return .Out_Of_Memory}
    } else {
        clip:=anim.Clip(c+1)
        duration:=anim.clip_duration(library,clip)
        samples,exact:=anim.frames_layout(duration,anim.clip_rate(library,clip),ANIMATION_MAX_KEYS)
        if samples==0 {samples,exact=1,1}
        stored:=library.tracks[int(anim.clip_data(library,clip).first_track)+i]
        previous:mm.Vec4
        for frame in 0..<samples {
            key:=anim.Keyframe{time=min(f32(frame)/exact,duration),interpolation=.Linear}
            key.value=anim.clip_evaluate(library,stored,key.time)
            // Each key on the side of the one before, so a key blends the short way.
            if track.property==.Rotation && frame>0 && linalg.dot(key.value,previous)<0 {key.value=-key.value}
            previous=key.value
            if _,error:=append(keys,key);error!=nil {return .Out_Of_Memory}
        }
        kept.key_count=u32(samples)
    }
    if _,error:=append(tracks,kept);error!=nil {return .Out_Of_Memory}
    return .None
}

// Whether every bone a clip of library moves has, in target, a bone of its target with the parent
// and rest it has in source: the clip binds there by name as it is. sorted: the bones of each by
// their targets (retarget_sorted).
@(private="file")
animation_clip_binds :: proc(library:^anim.Library,clip:anim.Clip,source:[]Skeleton_Bone,source_sorted:[]Retarget_Key,target:[]Skeleton_Bone,target_sorted:[]Retarget_Key) -> bool {
    for track in anim.clip_tracks(library,clip) {
        if track.slot!=0 || track.property==.Float || track.property==.Vector {continue}
        from:=retarget_bone_of(source_sorted,track.target)
        if from<0 {continue}
        to:=retarget_bone_of(target_sorted,track.target)
        if to<0 {return false}
        a,b:=&source[from],&target[to]
        above:=source[a.parent].target if a.parent>=0 else 0
        if above!=(target[b.parent].target if b.parent>=0 else 0) {return false}
        tolerance:=f32(ANIMATION_RETARGET_REST_TOLERANCE)
        if linalg.length(a.translation-b.translation)>tolerance*max(1,linalg.length(a.translation)) {return false}
        if 1-abs(linalg.dot(a.rotation,b.rotation))>tolerance || linalg.length(a.scale-b.scale)>tolerance {return false}
    }
    return true
}

// A bone by its target, for a search.
@(private="file")
Retarget_Key :: struct {target:u64,bone:i32}

// The bones by their targets, sorted, in the temp allocator.
@(private="file")
retarget_sorted :: proc(bones:[]Skeleton_Bone) -> []Retarget_Key {
    sorted:=make([]Retarget_Key,len(bones),context.temp_allocator)
    for &bone,i in bones {sorted[i]={bone.target,i32(i)}}
    slice.sort_by(sorted,proc(a,b:Retarget_Key) -> bool {return a.target<b.target})
    return sorted
}

// The bone of a target, -1 for none; the first of a target that repeats.
@(private="file")
retarget_bone_of :: proc(bones:[]Retarget_Key,target:u64) -> i32 {
    at,_:=slice.binary_search_by(bones,target,proc(key:Retarget_Key,target:u64) -> slice.Ordering {return .Less if key.target<target else .Greater if key.target>target else .Equal})
    for at>0 && bones[at-1].target==target {at-=1}
    return bones[at].bone if at<len(bones) && bones[at].target==target else -1
}

// A bone by its path, else by its name.
@(private="file")
retarget_bone_named :: proc(bones:[]Skeleton_Bone,path:[NODE_PATH_CAPACITY]u8) -> int {
    if at:=skeleton_bone_index(bones,path);at>=0 {return int(at)}
    path:=path
    name:=base.text_get(path[:])
    for &bone,i in bones {if base.text_get(bone.name[:])==name {return i}}
    return -1
}

// A skeleton as the math of std/anim takes it, the hashes of the names of its bones, its body and
// its bones by their targets, in the temp allocator.
@(private="file")
Retarget_Skeleton :: struct {
    bones:[]Skeleton_Bone,
    rig:anim.Skeleton,
    aliases:[]u64,
    body:anim.Body_Map,
    sorted:[]Retarget_Key,
}

@(private="file")
retarget_skeleton :: proc(out:^Retarget_Skeleton,types:^Types,open:Skeleton_Open,data:rawptr,id:base.Asset_Id) -> bool {
    scratch:=context.temp_allocator
    file:Asset
    if !open(data,id,&file) {return false}
    view,error:=skeleton_view(&file,types)
    if error!=.None || !skeleton_check(view) {return false}
    // The file closes with the scratch it was opened in: its rows are copied.
    out.bones=slice.clone(view.bones,scratch)
    out.body=skeleton_body_map(out.bones,view.body,view.body_parts)
    rig,made:=skeleton_anim(view,scratch)
    if !made {return false}
    out.rig=rig
    out.aliases=make([]u64,len(out.bones),scratch)
    for &bone,i in out.bones {out.aliases[i]=base.name_hash(base.text_get(bone.name[:]))}
    out.sorted=retarget_sorted(out.bones)
    return true
}

// How the bones of a target take those of a skeleton its clips were made on.
@(private="file")
Retarget_Pair :: struct {
    mapping:[]i32, // by bone of the target: its source bone, -1: none
    prepared:[]anim.Retarget_Bone,
    crotch:anim.Retarget_Crotch,
    tried:bool,
}

// Pairs each bone of target with one of source (anim.retarget_map) and prepares their retarget.
// False when none pairs or a rest is not valid.
@(private="file")
retarget_pair :: proc(pair:^Retarget_Pair,source,target:^Retarget_Skeleton) -> bool {
    scratch:=context.temp_allocator
    n,m:=len(target.bones),len(source.bones)
    pair.mapping=make([]i32,n,scratch);pair.prepared=make([]anim.Retarget_Bone,n,scratch)
    source_world:=make([]mm.Transform,m,scratch);target_world:=make([]mm.Transform,n,scratch)
    paired,ok:=anim.retarget_map(source.rig,target.rig,source.aliases,target.aliases,source.body,target.body,pair.mapping,scratch)
    if !ok || paired==0 {return false}
    if !anim.retarget_prepare(source.rig,target.rig,pair.mapping,source_world,target_world,pair.prepared) {return false}
    crotch,error:=anim.retarget_crotch_prepare(source.rig,target.rig,source.body,target.body,source_world,target_world)
    pair.crotch=crotch if error==.None else anim.RETARGET_CROTCH_NONE
    return true
}

// Whether a channel of bone b stays at its rest over the poses of every frame.
@(private="file")
retarget_static :: proc "contextless" (poses:[]mm.Transform,n,b:int,property:anim.Property,rest:mm.Transform) -> bool {
    tolerance:=f32(ANIMATION_RETARGET_STATIC_TOLERANCE)
    for frame:=b;frame<len(poses);frame+=n {
        value:=poses[frame]
        switch property {
        case .Position: if linalg.length(value.position-rest.position)>tolerance {return false}
        case .Scale: if linalg.length(value.scale-rest.scale)>tolerance {return false}
        case .Rotation: if 1-abs(linalg.dot(value.rotation,rest.rotation))>tolerance {return false}
        case .Float,.Vector:
        }
    }
    return true
}

// The cooked .anim of the retarget of a checked view onto skeleton, under the id `id`: the
// retarget compressed as animation_compress compresses any .anim. direct and failures as
// animation_retarget says, with nothing made.
animation_retarget_cooked :: proc(doc:^Document,types:^Types,id,owner:base.Asset_Id,view:Animation_View,open:Skeleton_Open,data:rawptr,skeleton:base.Asset_Id,allocator:=context.allocator) -> (result:Animation_Retarget) {
    retarget:=animation_retarget(view,types,open,data,skeleton,context.temp_allocator)
    result=retarget
    result.view={}
    if retarget.direct || retarget.failure!=.None {return}
    defer animation_retarget_free(&retarget,context.temp_allocator)
    desc:=animation_library_desc(retarget.view)
    desc.allocator=context.temp_allocator
    library:anim.Library
    if !anim.library_init(&library,desc) {result.failure=.Out_Of_Memory;return}
    defer anim.library_destroy(&library)
    if len(retarget.view.clips)>0 && animation_clips_add(retarget.view,&library)==0 {result.failure=.Invalid;return}
    if _,error:=animation_compress(retarget.view,&library,types,open,data);error!=.None {result.failure=.Out_Of_Memory if error==.Out_Of_Memory else .Invalid;return}
    if animation_cooked_document(doc,types,id,owner,retarget.view,&library,allocator)!=.None {result.failure=.Invalid}
    return
}
