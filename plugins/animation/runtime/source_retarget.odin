package anim

import "core:math/linalg"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// A rig plays the clips of its library on its own skeleton. A clip made on another skeleton (the
// .skeleton its .anim names for it) binds by bone name as it is when the bones it moves have the
// same names, parents and rests in both, as a variant with an extra bone or a skeleton imported
// twice; otherwise the library is retargeted onto the skeleton of the rig the first time a rig of
// that skeleton plays it, before its matching database is built, and every rig of that skeleton
// shares it. Its bones pair by name or path, else by the parts of the body both .skeletons mark
// (lib.retarget_map), with the crotch kept off the floor (lib.retarget_crotch_pose); its clips are
// sampled at their own rate into raw keys the player reads as they are, and its curves, markers
// and names stay those of the library. An entry is found by library and skeleton, never kept by a
// rig: it is made again when either or a skeleton its clips were made on changes, and freed with
// the cache.

RETARGET_GENERATION :: u32(1)<<30
// Joined and retargeted libraries count their generations below both marks; host content counts
// its loads from 1 and never reaches them.
SOURCE_GENERATION_COUNT :: RETARGET_GENERATION-1
#assert(SOURCE_GENERATION&RETARGET_GENERATION==0)
#assert(SOURCE_GENERATION_COUNT&(SOURCE_GENERATION|RETARGET_GENERATION)==0)
// How far two rests may differ and still be the same bone: of a translation, relative to its
// length past one unit; of a rotation, 1 minus the absolute dot of the quaternions; of a scale.
RETARGET_REST_TOLERANCE :: 1e-4
// What a retargeted channel may stay from the rest of its bone and still be left out.
RETARGET_STATIC_TOLERANCE :: 1e-5

// A skeleton the clips of a retargeted library were made on, at the revision it was read at; 0:
// it could not be read.
Retarget_Source :: struct {id:base.Asset_Id,revision:u64}
Retarget_Failure :: enum u8 {None,Unread,Unpaired}
Source_Retarget :: struct {
    library:base.Asset_Id,generation:u32, // the library it was made from
    skeleton:base.Asset_Id,revision:u64,  // the skeleton it plays on, at the revision it was made for
    checked:u64,                          // assets_stamp when it was last found current
    sources:[]Retarget_Source,
    failed:base.Asset_Id,                 // a source whose clips hold the rest pose: failure says why
    failure:Retarget_Failure,
    direct:bool,                          // every clip binds by name: the library plays as it is
    content:host.Content_Animation,       // otherwise, the library on skeleton
}

// The library `content` plays on a rig of `skeleton`: itself when each of its clips binds by name
// (above), else its retarget onto that skeleton. rig: the entity a problem is reported on.
source_retarget :: proc(cache:^Source_Assets,app:^host.App,skeletons:^Skeleton_Assets,content:^host.Content_Animation,skeleton:base.Asset_Id,problems:^core.Problems=nil,rig:=core.NONE) -> ^host.Content_Animation {
    if cache==nil || app==nil || app.assets==nil || skeletons==nil || content==nil || skeleton=={} || content.clip_count<=0 || len(content.skeletons)<content.clip_count {return content}
    if cache.allocator.procedure==nil {cache.allocator=app.allocator}
    context.allocator=cache.allocator
    entry:^Source_Retarget
    for &known in cache.retargets {if known.library==content.id && known.skeleton==skeleton {entry=&known;break}}
    stamp:=assets_stamp(app.assets)
    if entry!=nil && entry.generation==content.generation && entry.generation!=0 {
        if entry.checked==stamp {return source_retarget_played(entry,content,problems,rig)}
        if source_retarget_current(entry,skeletons,app) {entry.checked=stamp;return source_retarget_played(entry,content,problems,rig)}
    }
    if entry==nil {
        // A library whose clips were all made on this skeleton, or on none, keeps no entry.
        other:=false
        for id in content.skeletons[:content.clip_count] {if id!={} && id!=skeleton {other=true;break}}
        if !other {return content}
        if len(cache.retargets)>=SOURCE_CACHE_CAPACITY || !program_array_reserve(&cache.retargets,len(cache.retargets)+1) {memory_problem(problems,rig,"the retarget of its clips onto its skeleton");return content}
        if _,error:=append(&cache.retargets,Source_Retarget{library=content.id,skeleton=skeleton});error!=nil {memory_problem(problems,rig,"the retarget of its clips onto its skeleton");return content}
        entry=&cache.retargets[len(cache.retargets)-1]
    }
    switch source_retarget_build(cache,app,skeletons,content,skeleton,entry) {
    case .None:
    case .Out_Of_Memory: memory_problem(problems,rig,"the retarget of its clips onto its skeleton");return content
    case .Pending: return content // its skeleton still loads: the rig waits for it
    }
    entry.checked=stamp
    return source_retarget_played(entry,content,problems,rig)
}

// The retargeted library a state plays, found by the generation it was bound with; nil when that
// library was made again since.
source_retargeted :: proc "contextless" (cache:^Source_Assets,id:base.Asset_Id,generation:u32) -> ^host.Content_Animation {
    if cache==nil || generation&RETARGET_GENERATION==0 {return nil}
    for &entry in cache.retargets {
        if !entry.direct && entry.content.id==id && entry.content.generation==generation {return &entry.content}
    }
    return nil
}

@(private)
source_retarget_free :: proc(entry:^Source_Retarget,allocator:mem.Allocator) {
    source_content_free(&entry.content,allocator)
    delete(entry.sources,allocator)
    entry^={library=entry.library,skeleton=entry.skeleton}
}

@(private)
source_content_free :: proc(content:^host.Content_Animation,allocator:mem.Allocator) {
    lib.library_destroy(&content.lib)
    delete(content.markers,allocator);delete(content.names,allocator);delete(content.roots,allocator)
    delete(content.morphs,allocator);delete(content.fields,allocator);delete(content.skeletons,allocator)
    content^={}
}

@(private="file")
source_retarget_played :: proc(entry:^Source_Retarget,content:^host.Content_Animation,problems:^core.Problems,rig:core.Entity) -> ^host.Content_Animation {
    if entry.failure!=.None {
        text:[base.ASSET_ID_TEXT]u8
        name:=base.asset_id_format(entry.failed,text[:])
        switch entry.failure {
        case .None:
        case .Unread: core.report(problems,rig,"animation.retarget_skeleton","clips of its animation were made on skeleton %s, which cannot be read, so they hold the rest pose of this rig; import that .skeleton again, or import the clips onto this skeleton",name)
        case .Unpaired: core.report(problems,rig,"animation.retarget_skeleton","clips of its animation were made on skeleton %s, which shares no bone name and no part of the body with this one, so they hold its rest pose; mark the body of both .skeletons (skeleton.body.detect) or name their bones alike",name)
        }
    }
    return content if entry.direct else &entry.content
}

// Whether the skeletons an entry was made for are those the cache holds now.
@(private="file")
source_retarget_current :: proc(entry:^Source_Retarget,skeletons:^Skeleton_Assets,app:^host.App) -> bool {
    for source in entry.sources {_=skeleton_content(skeletons,app.assets,app.allocator,source.id)}
    target:=skeleton_content(skeletons,app.assets,app.allocator,entry.skeleton)
    if target==nil || target.revision!=entry.revision {return false}
    for source in entry.sources {
        found:=skeleton_content(skeletons,app.assets,app.allocator,source.id)
        if (found.revision if found!=nil else 0)!=source.revision {return false}
    }
    return true
}

@(private="file")
Retarget_Error :: enum u8 {None,Out_Of_Memory,Pending}
@(private="file")
Retarget_Plan :: enum u8 {Keep,Retarget,Rest}
// How the bones of a target take those of a skeleton its clips were made on.
@(private="file")
Retarget_Pair :: struct {
    source:^Skeleton_Content,
    rig:lib.Skeleton,
    aliases:[]u64,             // the hashes of the names of its bones
    bones:[]Retarget_Bone_Key,
    mapping:[]i32,             // by bone of the target: its source bone, -1: none
    prepared:[]lib.Retarget_Bone,
    crotch:lib.Retarget_Crotch,
    tried,paired:bool,
}

// Room in scratch that a build drops with the tick: failed is set when memory runs out.
@(private="file")
retarget_array :: proc($T:typeid,n:int,allocator:mem.Allocator,failed:^bool) -> []T {
    values,error:=make([]T,n,allocator)
    if error!=nil {failed^=true}
    return values
}

// Makes entry again for content on skeleton: what it held goes, and a failure leaves it to be
// made again in the next tick.
@(private="file")
source_retarget_build :: proc(cache:^Source_Assets,app:^host.App,skeletons:^Skeleton_Assets,content:^host.Content_Animation,skeleton:base.Asset_Id,entry:^Source_Retarget) -> Retarget_Error {
    allocator:=cache.allocator
    source_retarget_free(entry,allocator)
    scratch:=context.temp_allocator
    count:=content.clip_count
    failed:=false
    ids:=retarget_array(base.Asset_Id,count,scratch,&failed)
    plans:=retarget_array(Retarget_Plan,count,scratch,&failed)
    if failed {return .Out_Of_Memory}
    known:=0
    for id in content.skeletons[:count] {if id!={} && id!=skeleton && !slice.contains(ids[:known],id) {ids[known]=id;known+=1}}
    ids=ids[:known]
    // Every skeleton is in the cache before any is held: a later read may move its rows.
    for id in ids {_=skeleton_content(skeletons,app.assets,app.allocator,id)}
    target:=skeleton_content(skeletons,app.assets,app.allocator,skeleton)
    if target==nil {return .Pending}
    sources,no_sources:=make([]Retarget_Source,len(ids),allocator)
    if no_sources!=nil {return .Out_Of_Memory}
    entry.sources,entry.revision=sources,target.revision
    pairs:=retarget_array(Retarget_Pair,len(ids),scratch,&failed)
    target_rig,target_aliases,target_bones:=retarget_rig(target,scratch,&failed)
    if failed {return .Out_Of_Memory}
    for id,i in ids {
        found:=skeleton_content(skeletons,app.assets,app.allocator,id)
        sources[i]={id,found.revision if found!=nil else 0}
        pairs[i].source=found
    }
    retargeted:=false
    for id,c in content.skeletons[:count] {
        if id=={} || id==skeleton {continue}
        at,_:=slice.linear_search(ids,id)
        pair:=&pairs[at]
        if pair.source==nil {
            plans[c]=.Rest;entry.failed,entry.failure=id,.Unread;retargeted=true
            continue
        }
        if pair.bones==nil {
            pair.rig,pair.aliases,pair.bones=retarget_rig(pair.source,scratch,&failed)
            if failed {return .Out_Of_Memory}
        }
        if retarget_binds_by_name(content,c,pair.source,pair.bones,target,target_bones) {continue}
        if !pair.tried {
            pair.tried=true
            pair.paired=retarget_pair(pair,target,target_rig,target_aliases,scratch,&failed)
            if failed {return .Out_Of_Memory}
            if !pair.paired && entry.failure==.None {entry.failed,entry.failure=id,.Unpaired}
        }
        plans[c]=.Retarget if pair.paired else .Rest
        retargeted=true
    }
    entry.direct=!retargeted
    if retargeted {retarget_library(cache,content,target,target_rig,ids,pairs,plans,entry) or_return}
    entry.generation=content.generation
    return .None
}

// A skeleton as the math of std/anim takes it, the hashes of the names of its bones, and its bones
// by their targets, sorted.
@(private="file")
retarget_rig :: proc(content:^Skeleton_Content,allocator:mem.Allocator,failed:^bool) -> (rig:lib.Skeleton,aliases:[]u64,bones:[]Retarget_Bone_Key) {
    n:=len(content.bones)
    rig.parents=retarget_array(i32,n,allocator,failed);rig.names=retarget_array(u64,n,allocator,failed)
    rig.rest=retarget_array(mm.Transform,n,allocator,failed)
    aliases=retarget_array(u64,n,allocator,failed);bones=retarget_array(Retarget_Bone_Key,n,allocator,failed)
    if failed^ {return}
    for &bone,i in content.bones {
        rig.parents[i],rig.names[i],rig.rest[i]=bone.parent,bone.target,{bone.translation,bone.rotation,bone.scale}
        aliases[i]=base.name_hash(base.text_get(bone.name[:]))
        bones[i]={bone.target,i32(i)}
    }
    slice.sort_by(bones,proc(a,b:Retarget_Bone_Key) -> bool {return a.target<b.target})
    return
}
@(private="file")
Retarget_Bone_Key :: struct {target:u64,bone:i32}
// The bone of a target, -1 for none; the first of a target that repeats.
@(private="file")
retarget_bone_of :: proc(bones:[]Retarget_Bone_Key,target:u64) -> i32 {
    at,_:=slice.binary_search_by(bones,target,proc(key:Retarget_Bone_Key,target:u64) -> slice.Ordering {return .Less if key.target<target else .Greater if key.target>target else .Equal})
    for at>0 && bones[at-1].target==target {at-=1}
    return bones[at].bone if at<len(bones) && bones[at].target==target else -1
}

// Whether every bone a clip moves has, in target, a bone of its target with the parent and rest
// it has in source: the clip binds there by name as it is.
@(private="file")
retarget_binds_by_name :: proc(content:^host.Content_Animation,clip:int,source:^Skeleton_Content,source_bones:[]Retarget_Bone_Key,target:^Skeleton_Content,target_bones:[]Retarget_Bone_Key) -> bool {
    for track in lib.clip_tracks(&content.lib,lib.Clip(clip+1)) {
        if track.slot!=0 || track.property==.Float || track.property==.Vector {continue}
        from:=retarget_bone_of(source_bones,track.target)
        if from<0 {continue}
        to:=retarget_bone_of(target_bones,track.target)
        if to<0 {return false}
        a,b:=&source.bones[from],&target.bones[to]
        above:=source.bones[a.parent].target if a.parent>=0 else 0
        if above!=(target.bones[b.parent].target if b.parent>=0 else 0) {return false}
        tolerance:=f32(RETARGET_REST_TOLERANCE)
        if linalg.length(a.translation-b.translation)>tolerance*max(1,linalg.length(a.translation)) {return false}
        if 1-abs(linalg.dot(a.rotation,b.rotation))>tolerance || linalg.length(a.scale-b.scale)>tolerance {return false}
    }
    return true
}

// Pairs each bone of target with one of the source (lib.retarget_map) and prepares their retarget.
// False when none pairs or a rest is not valid.
@(private="file")
retarget_pair :: proc(pair:^Retarget_Pair,target:^Skeleton_Content,target_rig:lib.Skeleton,target_aliases:[]u64,allocator:mem.Allocator,failed:^bool) -> bool {
    n,m:=len(target.bones),len(pair.source.bones)
    pair.mapping=retarget_array(i32,n,allocator,failed);pair.prepared=retarget_array(lib.Retarget_Bone,n,allocator,failed)
    source_world:=retarget_array(mm.Transform,m,allocator,failed);target_world:=retarget_array(mm.Transform,n,allocator,failed)
    if failed^ {return false}
    paired,ok:=lib.retarget_map(pair.rig,target_rig,pair.aliases,target_aliases,pair.source.body,target.body,pair.mapping,allocator)
    if !ok || paired==0 {return false}
    if !lib.retarget_prepare(pair.rig,target_rig,pair.mapping,source_world,target_world,pair.prepared) {return false}
    crotch,error:=lib.retarget_crotch_prepare(pair.rig,target_rig,pair.source.body,target.body,source_world,target_world)
    pair.crotch=crotch if error==.None else lib.RETARGET_CROTCH_NONE
    return true
}

// The retarget of the clips of content by plans into entry: those it keeps share their tracks,
// keys and stream; the others take raw keys of the bones of target their pose moves from its
// rest, sampled at their rate, and the curves they had. A library whose tables do not hold
// together, or a clip that does not sample, plays as it is.
@(private="file")
retarget_library :: proc(cache:^Source_Assets,content:^host.Content_Animation,target:^Skeleton_Content,target_rig:lib.Skeleton,ids:[]base.Asset_Id,pairs:[]Retarget_Pair,plans:[]Retarget_Plan,entry:^Source_Retarget) -> Retarget_Error {
    allocator,scratch:=cache.allocator,context.temp_allocator
    count,n:=content.clip_count,len(target.bones)
    source:=&content.lib
    if source.key_count<0 || source.key_count>len(source.keys) || source.track_count<0 || source.track_count>len(source.tracks) || source.marker_count<0 || source.marker_count>len(source.markers) || source.stream_bytes<0 || source.stream_bytes>0 && source.stream_bytes+lib.STREAM_PADDING>len(source.streams) || count>len(source.clips) || count>len(content.names) || count>len(content.roots) {entry.direct=true;return .None}
    // The room of every clip: its frames, its tracks and its keys, at most a channel a bone a frame.
    frames:=0;track_room:=0;key_room:=0;sources_peak:=0
    for plan,c in plans {
        clip:=source.clips[c]
        if int(clip.first_track)>source.track_count || int(clip.track_count)>source.track_count-int(clip.first_track) {entry.direct=true;return .None}
        track_room+=int(clip.track_count)
        if plan!=.Retarget {continue}
        at,_:=slice.linear_search(ids,content.skeletons[c])
        sources_peak=max(sources_peak,len(pairs[at].source.bones))
        samples,_:=lib.frames_layout(clip.duration,lib.clip_rate(source,lib.Clip(c+1)),asset.ANIMATION_MAX_KEYS)
        frames=max(frames,samples,1);track_room+=3*n;key_room+=3*n*max(samples,1)
    }
    if key_room>int(max(u32))-source.key_count || track_room>int(max(u32)) {return .Out_Of_Memory}
    failed:=false
    keys:=retarget_array(lib.Keyframe,key_room,scratch,&failed)
    tracks:=retarget_array(lib.Track,track_room,scratch,&failed)
    clips:=retarget_array(lib.Clip_Data,count,scratch,&failed)
    roots:=retarget_array(asset.Animation_Root,count,scratch,&failed)
    played:=retarget_array(base.Asset_Id,count,scratch,&failed)
    poses:=retarget_array(mm.Transform,frames*n,scratch,&failed)
    target_world:=retarget_array(mm.Transform,n,scratch,&failed)
    bindings:=retarget_array(lib.Bone_Tracks,sources_peak,scratch,&failed)
    source_local:=retarget_array(mm.Transform,sources_peak,scratch,&failed)
    source_world:=retarget_array(mm.Transform,sources_peak,scratch,&failed)
    if failed {return .Out_Of_Memory}
    copy(roots,content.roots[:count]);copy(played,content.skeletons[:count])
    key_count,track_count:=0,0
    for plan,c in plans {
        clip:=source.clips[c]
        clips[c]=clip
        clips[c].first_track=u32(track_count)
        own:=source.tracks[clip.first_track:][:clip.track_count]
        if plan==.Keep {track_count+=copy(tracks[track_count:],own);continue}
        played[c]=target.id
        clips[c].stream,clips[c].stream_bytes=0,0
        at,_:=slice.linear_search(ids,content.skeletons[c])
        pair:=&pairs[at]
        if plan==.Retarget {
            rate:=lib.clip_rate(source,lib.Clip(c+1))
            samples,exact:=lib.frames_layout(clip.duration,rate,asset.ANIMATION_MAX_KEYS)
            if samples==0 {samples,exact=1,rate}
            m:=len(pair.source.bones)
            if !lib.skeleton_bind(source,lib.Clip(c+1),pair.rig,bindings[:m]) {entry.direct=true;return .None}
            sampled:=true
            for frame in 0..<samples {
                time:=min(f32(frame)/exact,clip.duration)
                pose:=poses[frame*n:][:n]
                sampled&&=lib.skeleton_sample(source,bindings[:m],pair.rig.rest,time,source_local[:m])
                sampled&&=lib.retarget_pose(pair.rig,target_rig,pair.prepared,source_local[:m],source_world[:m],target_world,pose)
                sampled&&=lib.retarget_crotch_pose(target_rig,pair.crotch,source_world[:m],pose,target_world)
                if !sampled {entry.direct=true;return .None}
            }
            for b in 0..<n {
                for property in ([3]lib.Property{.Position,.Rotation,.Scale}) {
                    if retarget_static(poses[:samples*n],n,b,property,target_rig.rest[b]) {continue}
                    previous:=mm.Vec4{}
                    for frame in 0..<samples {
                        value:=poses[frame*n+b]
                        key:=lib.Keyframe{time=min(f32(frame)/exact,clip.duration),interpolation=.Linear}
                        switch property {
                        case .Position: key.value={value.position.x,value.position.y,value.position.z,0}
                        case .Scale: key.value={value.scale.x,value.scale.y,value.scale.z,0}
                        case .Rotation:
                            key.value=lib.quat_vec4(value.rotation)
                            // Each key on the side of the one before, so a key blends the short way.
                            if frame>0 && linalg.dot(key.value,previous)<0 {key.value=-key.value}
                            previous=key.value
                        case .Float,.Vector:
                        }
                        keys[key_count+frame]=key
                    }
                    tracks[track_count]={target=target.bones[b].target,property=property,first=u32(source.key_count+key_count),count=u32(samples)}
                    track_count+=1;key_count+=samples
                }
            }
        }
        // Curves keep their keys, or their place in the stream of the clip, which the library
        // keeps whole.
        for track in own {if track.property==.Float || track.property==.Vector {tracks[track_count]=track;track_count+=1}}
        clips[c].track_count=u32(track_count)-clips[c].first_track
        root:=&roots[c]
        if root.translation || root.rotation {
            to:=-1
            if plan==.Retarget {
                from:=skeleton_bone_find(pair.source.bones,lib.body_map_empty(),{root.bone})
                if from>=0 {for bone,b in pair.mapping {if int(bone)==from {to=b;break}}}
            }
            root.bone={}
            if to>=0 {root.bone=target.bones[to].path} else {root.translation,root.rotation=false,false}
        }
    }
    next:host.Content_Animation
    published:=false
    defer if !published {source_content_free(&next,allocator)}
    desc:=lib.Library_Desc{max_keys=max(source.key_count+key_count,1),max_tracks=max(track_count,1),max_clips=count*2,max_markers=source.marker_count,max_stream_bytes=source.stream_bytes,allocator=allocator}
    if !lib.library_init(&next.lib,desc) {return .Out_Of_Memory}
    e1,e2,e3,e4,e5,e6:mem.Allocator_Error
    next.markers,e1=make([]host.Content_Marker,len(content.markers),allocator)
    next.names,e2=make([][asset.ANIMATION_NAME_CAPACITY]u8,count,allocator)
    next.roots,e3=make([]asset.Animation_Root,count,allocator)
    next.morphs,e4=make([]host.Content_Morph,len(content.morphs),allocator)
    next.fields,e5=make([]host.Content_Field,len(content.fields),allocator)
    next.skeletons,e6=make([]base.Asset_Id,count,allocator)
    if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil || e6!=nil {return .Out_Of_Memory}
    copy(next.markers,content.markers);copy(next.names,content.names[:count]);copy(next.roots,roots)
    copy(next.morphs,content.morphs);copy(next.fields,content.fields);copy(next.skeletons,played)
    built:=&next.lib
    copy(built.keys,source.keys[:source.key_count]);copy(built.keys[source.key_count:],keys[:key_count])
    if source.stream_bytes>0 {copy(built.streams,source.streams[:source.stream_bytes])}
    copy(built.tracks,tracks[:track_count]);copy(built.markers,source.markers[:source.marker_count])
    for &clip,c in clips {clip.loop=.Once;built.clips[c]=clip}
    built.key_count,built.track_count,built.marker_count=source.key_count+key_count,track_count,source.marker_count
    built.stream_bytes,built.clip_count=source.stream_bytes,count
    lib.library_index_clips(built)
    host.content_animation_loops(built,count);built.prepared=true;next.clip_count=count
    cache.generations=(cache.generations+1)&SOURCE_GENERATION_COUNT
    next.id,next.generation=content.id,RETARGET_GENERATION|cache.generations
    entry.content=next;published=true
    return .None
}

// Whether a channel of bone b stays at its rest over the poses of every frame.
@(private="file")
retarget_static :: proc "contextless" (poses:[]mm.Transform,n,b:int,property:lib.Property,rest:mm.Transform) -> bool {
    tolerance:=f32(RETARGET_STATIC_TOLERANCE)
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
