package animation_editor

import "base:runtime"
import "mirai:asset"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(private) Bake_Chain :: struct {source,target:[]i32,mapping:[]lib.Chain_Retarget_Bone,weight:f32}

// Bakes clips of source onto target as a rig takes the pose of another (Pose_Source, stage
// Sampled): by the chains of the target's .character where the topology differs, otherwise each
// bone by the bone of its name, or of its path when a name repeats. With legs in both bodies, the
// feet of the target stay locked to the ground (lib.Lock_Feet) over the frames the feet of the
// source stand; with crotch_floor, its crotch keeps off the floor as the source's does
// (lib.retarget_crotch_pose).
retarget_bake :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,clips:asset.Animation_View,source,target:asset.Skeleton_View,retarget_chains:[]anim.Chain_Retarget_Constraint,rate:f32=60,allocator:=context.allocator,skeleton:=base.Asset_Id{},crotch_floor:=false) -> asset.Error {
    if !asset.animation_check(clips) || !asset.skeleton_check(source) || !asset.skeleton_check(target) || len(retarget_chains)>anim.POSE_CONSTRAINTS || rate<1 || rate>240 || rate-rate!=0 {return .Invalid}
    scratch:=context.temp_allocator
    rig :: proc(bones:[]asset.Skeleton_Bone,allocator:runtime.Allocator) -> (result:lib.Skeleton,aliases:[]u64,error:asset.Error) {
        result.parents=bake_array(i32,len(bones),allocator) or_return
        result.names=bake_array(u64,len(bones),allocator) or_return
        result.rest=bake_array(mm.Transform,len(bones),allocator) or_return
        aliases=bake_array(u64,len(bones),allocator) or_return
        for &bone,i in bones {result.parents[i]=bone.parent;result.names[i]=bone.target;result.rest[i]={bone.translation,bone.rotation,bone.scale};aliases[i]=base.name_hash(base.text_get(bone.name[:]))}
        return result,aliases,.None
    }
    find :: proc(view:asset.Skeleton_View,ref:anim.Bone_Ref) -> int {
        return anim.skeleton_bone_find(view.bones,asset.skeleton_body_map(view.bones,view.body,view.body_parts),ref)
    }
    source_rig,source_aliases:=rig(source.bones,scratch) or_return
    target_rig,target_aliases:=rig(target.bones,scratch) or_return
    mapping:=bake_array(i32,len(target.bones),scratch) or_return
    for &index in mapping {index=-1}
    bound:=false
    if len(retarget_chains)==0 {
        follow:=bake_array(lib.Follow_Bone,len(target.bones),scratch) or_return
        shared,paired:=lib.follow_prepare(target_rig,source_rig,target_aliases,source_aliases,follow)
        if !paired {return .Invalid}
        for bone,i in follow {mapping[i]=bone.leader}
        bound=shared>0
    }
    source_world:=bake_array(mm.Transform,len(source.bones),scratch) or_return;target_world:=bake_array(mm.Transform,len(target.bones),scratch) or_return
    prepared:=bake_array(lib.Retarget_Bone,len(target.bones),scratch) or_return
    if !lib.retarget_prepare(source_rig,target_rig,mapping,source_world,target_world,prepared) {return .Invalid}
    chains:=bake_array(Bake_Chain,len(retarget_chains),scratch) or_return;chain_count:=0
    for value in retarget_chains {
        if !value.enabled || value.weight<=0 {continue}
        source_bones:=bake_array(i32,anim.RIG_CHAIN_BONES,scratch) or_return
        target_bones:=bake_array(i32,anim.RIG_CHAIN_BONES,scratch) or_return
        source_count,a:=lib.skeleton_chain(source_rig,i32(find(source,value.source_root)),i32(find(source,value.source_end)),source_bones)
        target_count,b:=lib.skeleton_chain(target_rig,i32(find(target,value.target_root)),i32(find(target,value.target_end)),target_bones)
        if !a || !b {return .Invalid}
        chain_mapping:=bake_array(lib.Chain_Retarget_Bone,target_count,scratch) or_return
        if !lib.chain_retarget_prepare(source_rig,target_rig,source_bones[:source_count],target_bones[:target_count],source_world,target_world,chain_mapping) {return .Invalid}
        chains[chain_count]={source_bones[:source_count],target_bones[:target_count],chain_mapping,value.weight};chain_count+=1
    }
    if !bound && chain_count==0 {return .Invalid}
    source_body:=asset.skeleton_body_map(source.bones,source.body,source.body_parts)
    target_body:=asset.skeleton_body_map(target.bones,target.body,target.body_parts)
    crotch:=lib.RETARGET_CROTCH_NONE
    if crotch_floor {
        error:lib.Retarget_Error
        crotch,error=lib.retarget_crotch_prepare(source_rig,target_rig,source_body,target_body,source_world,target_world)
        if error!=.None || crotch==lib.RETARGET_CROTCH_NONE {return .Invalid}
    }
    legs :: proc(body:lib.Body_Map) -> bool {
        for part in ([6]lib.Body_Part{.Hip_L,.Knee_L,.Foot_L,.Hip_R,.Knee_R,.Foot_R}) {if body.bones[part]<0 {return false}}
        return true
    }
    library:lib.Library
    desc:=asset.animation_library_desc(clips);desc.allocator=allocator
    if !lib.library_init(&library,desc) {return .Out_Of_Memory};defer lib.library_destroy(&library)
    if len(clips.clips)>0 && asset.animation_clips_add(clips,&library,.Once)==0 {return .Invalid}
    bindings:=bake_array(lib.Bone_Tracks,len(source.bones),scratch) or_return
    output:=bake_array(asset.Animation_Clip_Desc,len(clips.clips),scratch) or_return
    keys_total:=0
    for &clip,i in clips.clips {
        duration:=lib.clip_duration(&library,lib.Clip(i+1))
        if f64(duration)*f64(rate)>f64(asset.ANIMATION_MAX_KEYS) {return .Invalid}
        frames,exact:=lib.frames_layout(duration,rate,asset.ANIMATION_MAX_KEYS)
        if frames==0 {frames,exact=1,rate}
        if len(target.bones)>asset.ANIMATION_MAX_TRACKS/3 || frames>(asset.ANIMATION_MAX_KEYS-keys_total)/max(len(target.bones)*3,1) {return .Invalid}
        keys_total+=frames*len(target.bones)*3
        curves:=0
        for track in clips.tracks[clip.first_track:][:clip.track_count] {if track.property==.Float || track.property==.Vector {curves+=1}}
        tracks:=bake_array(asset.Animation_Track_Desc,len(target.bones)*3+curves,scratch) or_return
        for &bone,b in target.bones {
            for property in 0..<3 {
                keys:=bake_array(lib.Keyframe,frames,scratch) or_return
                tracks[b*3+property]={target=base.text_get(bone.path[:]),property=lib.Property(property),keys=keys}
            }
        }
        root:=clip.root
        root_bone,source_bone:=-1,-1
        if root.translation || root.rotation {
            source_bone=find(source,{root.bone})
            for index,b in mapping {if index==i32(source_bone) && source_bone>=0 {root_bone=b;break}}
            if root_bone<0 && source_bone>=0 {
                for chain in chains[:chain_count] {
                    for binding in chain.mapping {
                        if binding.source_a==i32(source_bone) && binding.fraction==0 || binding.source_b==i32(source_bone) && binding.fraction==1 {root_bone=int(binding.target);break}
                    }
                    if root_bone>=0 {break}
                }
            }
            root.bone={}
            if root_bone>=0 {root.bone=target.bones[root_bone].path} else {root.translation,root.rotation=false,false}
        }
        if !lib.skeleton_bind(&library,lib.Clip(i+1),source_rig,bindings) {return .Invalid}
        baked:=lib.Frames{rate=exact,bones=len(target.bones),local=bake_array(mm.Transform,frames*len(target.bones),scratch) or_return}
        sampled:=lib.Frames{rate=exact,bones=len(source.bones),local=bake_array(mm.Transform,frames*len(source.bones),scratch) or_return}
        for frame in 0..<frames {
            time:=min(f32(frame)/exact,duration)
            target_local,source_local:=lib.frames_pose(baked,frame),lib.frames_pose(sampled,frame)
            if !lib.skeleton_sample(&library,bindings,source_rig.rest,time,source_local) {return .Invalid}
            if !lib.retarget_pose(source_rig,target_rig,prepared,source_local,source_world,target_world,target_local) {return .Invalid}
            for chain in chains[:chain_count] {
                if !lib.chain_retarget_pose(target_rig,chain.mapping,source_world,target_local,target_world,chain.weight) {return .Invalid}
            }
            if !lib.retarget_crotch_pose(target_rig,crotch,source_world,target_local,target_world) {return .Invalid}
        }
        if legs(source_body) && legs(target_body) && frames>=3 {
            rig:=lib.Body_Rig{parents=target_rig.parents,rest=target_rig.rest,body=target_body,root=i32(root_bone)}
            // Where the feet of the source stand, and whether it loops.
            measured:=lib.Body_Rig{parents=source_rig.parents,rest=source_rig.rest,body=source_body,root=i32(source_bone)}
            found:=bake_array(lib.Contact,frames+4,scratch) or_return
            metrics,ok:=lib.clip_metrics(measured,sampled,{contacts=found},bake_array(mm.Transform,lib.frames_scratch_size(sampled),scratch) or_return)
            if !ok {return .Invalid}
            baked.loop=clip_loops(metrics)
            lock:=lib.Lock_Feet{contacts=found[:min(metrics.contacts,len(found))]}
            if len(lock.contacts)>0 {
                locked:=baked;locked.local=bake_array(mm.Transform,len(baked.local),scratch) or_return
                transforms,contacts,heights:=lib.clip_edit_buffers(lock,baked)
                buffers:=lib.Edit_Buffers{bake_array(mm.Transform,transforms,scratch) or_return,bake_array(lib.Contact,contacts,scratch) or_return,bake_array(f32,heights,scratch) or_return}
                if lib.clip_edit(rig,lock,baked,locked,buffers).error!=.None {return .Invalid}
                baked=locked
            }
        }
        for frame in 0..<frames {
            time:=min(f32(frame)/exact,duration)
            for value,b in lib.frames_pose(baked,frame) {
                tracks[b*3].keys[frame]={time=time,value={value.position.x,value.position.y,value.position.z,0}}
                tracks[b*3+1].keys[frame]={time=time,value=lib.quat_vec4(value.rotation)}
                tracks[b*3+2].keys[frame]={time=time,value={value.scale.x,value.scale.y,value.scale.z,0}}
            }
        }
        at:=len(target.bones)*3
        for &track in clips.tracks[clip.first_track:][:clip.track_count] {
            if track.property!=.Float && track.property!=.Vector {continue}
            tracks[at]={target=base.text_get(track.target[:]),property=track.property,slot=track.slot,keys=clips.keys[track.first_key:][:track.key_count]};at+=1
        }
        markers:=bake_array(asset.Animation_Marker_Desc,int(clip.marker_count),scratch) or_return
        for &marker,j in clips.markers[clip.first_marker:][:clip.marker_count] {markers[j]={marker.time,base.text_get(marker.name[:]),marker.duration,base.text_get(marker.target[:])}}
        output[i]={name=base.text_get(clip.name[:]),tracks=tracks,markers=markers,root=root,skeleton=skeleton}
    }
    return asset.animation_document(doc,types,{id=id,clips=output},allocator)
}

@(private="file")
bake_array :: proc($T:typeid,count:int,allocator:runtime.Allocator) -> ([]T,asset.Error) {
    values,error:=make([]T,count,allocator)
    if error!=nil {return nil,.Out_Of_Memory}
    return values,.None
}
