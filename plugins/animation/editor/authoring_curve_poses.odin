package animation_editor

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import aa "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

PROFILE_POSES_TOLERANCE :: 1e-4 // the least change of a bone, in meters, radians or scale, that a pose keeps

// A pose of a clip: the frame at time, which the Float curve of its name brings.
Profile_Pose_Frame :: struct {
    time:f32 `mirai:"min=0,unit=s"`,
    curve:[64]u8 `mirai:"text"`,
}
Profile_Poses_Params :: struct {
    asset:base.Asset_Id `mirai:"label=The .character whose curve poses of these curves are replaced"`,
    animation:base.Asset_Id `mirai:"kind=.anim"`,
    clip:[64]u8 `mirai:"optional,text,label=Empty: the first"`,
    skeleton:base.Asset_Id `mirai:"kind=.skeleton,label=The skeleton the clip poses"`,
    base:f32 `mirai:"optional,min=0,unit=s,label=The frame the poses are measured from: the rest of the face"`,
    poses:[256]Profile_Pose_Frame `mirai:"optional,label=A frame per pose; none: each marker of the clip is a pose of its name"`,
    tolerance:f32 `mirai:"optional,min=0"`,
    full:bool `mirai:"optional,label=Full poses: each row keeps the frame of its bone instead of its change from base"`,
    dry_run:bool `mirai:"optional,label=Validates and answers without writing"`,
}
Profile_Poses_Result :: struct {
    asset:base.Asset_Id,
    path:[1024]u8 `mirai:"text"`,
    poses,rows:u32 `mirai:"label=The poses made and the rows of the bones they move"`,
    still:u32 `mirai:"optional,label=Poses whose frame moves no bone from base: they make no row"`,
    drives:u32 `mirai:"optional,label=Curve drives from the Float curves of the clip at the frame of each pose"`,
    dry_run:bool `mirai:"optional"`,
}

@(private)
authoring_profile_poses :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Profile_Poses_Params)
    if !authoring_editable(s,call) {return}
    tolerance:=p.tolerance if p.tolerance>0 else PROFILE_POSES_TOLERANCE
    if !(tolerance<1e9) || !(p.base>=0) || p.base>1e9 {authoring_failure(call,"tolerance","Invalid_Value","a finite tolerance and base",fmt.tprintf("%v, %v",p.tolerance,p.base),"The poses cannot be measured");return}
    allocator:=context.temp_allocator
    poses:=make([dynamic]Profile_Pose_Frame,0,len(p.poses),allocator)
    for &pose,i in p.poses {
        name:=base.text_get(pose.curve[:])
        if name=="" {continue}
        if !(pose.time>=0) || pose.time>1e9 {authoring_failure(call,fmt.tprintf("poses[%d].time",i),"Invalid_Value","a time in the clip",fmt.tprintf("%v",pose.time),"The pose has no frame");return}
        for &other in p.poses[:i] {if other.curve==pose.curve {authoring_failure(call,fmt.tprintf("poses[%d].curve",i),"Duplicate","a curve once",name,"Two poses have one curve",fix="Give each pose its own curve");return}}
        append(&poses,pose)
    }

    clips:Authoring_File;defer aa.asset_close(&clips.file)
    view,opened:=authoring_clip_open(s,call,p.animation,&clips);if !opened {return}
    index,found:=authoring_clip_index(call,view,base.text_get(p.clip[:]));if !found {return}
    clip:=&view.clips[index]
    // Without a list, the poses are the markers of the clip, as pose libraries are exported.
    if len(poses)==0 {
        for &marker in view.markers[clip.first_marker:][:clip.marker_count] {
            pose:=Profile_Pose_Frame{time=marker.time}
            if base.text_get(marker.name[:])=="" || len(base.text_get(marker.name[:]))>=len(pose.curve) {continue}
            base.text_set(pose.curve[:],base.text_get(marker.name[:]))
            repeated:=false
            for &other in poses {repeated ||= other.curve==pose.curve}
            if !repeated && len(poses)<len(p.poses) {append(&poses,pose)}
        }
    }
    if len(poses)==0 {authoring_failure(call,"poses","Required","at least one pose with a curve, or a clip with markers","none","There are no poses to make",fix="List the poses, or name the frame of each pose with a marker of the clip");return}
    bones:Authoring_File;defer aa.asset_close(&bones.file)
    skeleton,read:=authoring_skeleton_open(s,call,p.skeleton,&bones);if !read {return}
    n:=len(skeleton.bones)
    parents:=make([]i32,n,allocator);names:=make([]u64,n,allocator);rest:=make([]mm.Transform,n,allocator)
    for &bone,i in skeleton.bones {
        parents[i],names[i]=bone.parent,bone.target
        rest[i]={position=bone.translation,rotation=bone.rotation,scale=bone.scale}
    }
    library:lib.Library
    desc:=aa.animation_library_desc(view);desc.allocator=allocator
    if !lib.library_init(&library,desc) {authoring_failure(call,"animation","Out_Of_Memory","memory for the clips","allocation failed","The clips could not be loaded",api.SERVER_ERROR);return}
    first:=aa.animation_clips_add(view,&library)
    if first==0 {authoring_failure(call,"animation","Invalid_Asset","clips that fit a library","refused","The clips could not be loaded");return}
    handle:=lib.Clip(int(first)+index)
    bindings:=make([]lib.Bone_Tracks,n,allocator)
    if !lib.skeleton_bind(&library,handle,{parents,names,rest},bindings) {authoring_failure(call,"skeleton","Invalid_Skeleton","a skeleton whose rest pose is valid","bind failed","The clip could not be bound to the skeleton");return}
    duration:=lib.clip_duration(&library,handle)
    origin:=make([]mm.Transform,n,allocator);frame:=make([]mm.Transform,n,allocator)
    if p.base>duration+1e-4 || !lib.skeleton_sample(&library,bindings,rest,p.base,origin) {authoring_failure(call,"base","Invalid_Value",fmt.tprintf("a time within the clip (0 to %v s)",duration),fmt.tprintf("%v",p.base),"The base pose could not be sampled");return}

    file:Authoring_File;defer aa.asset_close(&file.file)
    set,ok:=character_open(s,call,p.asset,&file);if !ok {return}
    profile:=&set.pose
    rows:=make([dynamic]anim.Curve_Pose,0,len(profile.curve_poses),allocator)
    for row in profile.curve_poses {
        replaced:=false
        for &pose in poses {if pose.curve==row.curve {replaced=true;break}}
        if !replaced {append(&rows,row)}
    }
    drives:=make([dynamic]anim.Curve_Drive,0,len(profile.curve_drives),allocator)
    for row in profile.curve_drives {
        replaced:=false
        for &pose in poses {if pose.curve==row.from {replaced=true;break}}
        if !replaced {append(&drives,row)}
    }
    result:=Profile_Poses_Result{asset=p.asset,dry_run=p.dry_run}
    base.text_set(result.path[:],file.path)
    for &pose,i in poses {
        if pose.time>duration+1e-4 || !lib.skeleton_sample(&library,bindings,rest,pose.time,frame) {authoring_failure(call,fmt.tprintf("poses[%d].time",i),"Invalid_Value",fmt.tprintf("a time within the clip (0 to %v s)",duration),fmt.tprintf("%v",pose.time),"The pose could not be sampled");return}
        moved:=false
        for b in 0..<n {
            if bindings[b]==lib.BONE_TRACKS_NONE {continue}
            from,to:=origin[b],frame[b]
            // Additive, as pose_delta_accumulate adds it: in the space of the parent, scale a factor.
            delta:=mm.Transform{position=to.position-from.position,rotation=linalg.normalize0(to.rotation*conj(from.rotation)),scale={1,1,1}}
            for axis in 0..<3 {if abs(from.scale[axis])>1e-8 {delta.scale[axis]=to.scale[axis]/from.scale[axis]}}
            if delta.rotation.w<0 {delta.rotation=-delta.rotation}
            if linalg.length(delta.position)<=tolerance && mm.quat_angle(delta.rotation,1)<=tolerance && linalg.length(delta.scale-mm.Vec3{1,1,1})<=tolerance {continue}
            row:=anim.CURVE_POSE_DEFAULT
            row.curve,row.delta,row.full=pose.curve,delta,p.full
            if p.full {row.delta=to;row.delta.rotation=linalg.normalize0(row.delta.rotation)}
            path:=base.text_get(skeleton.bones[b].path[:])
            if path=="" {path=base.text_get(skeleton.bones[b].name[:])}
            row.bone=anim.bone_ref(path)
            if len(rows)>=anim.POSE_CURVE_ROWS {authoring_failure(call,"poses","Capacity",fmt.tprintf("at most %d curve pose rows",anim.POSE_CURVE_ROWS),fmt.tprintf("%d and more",len(rows)),"The poses move more bones than a .character holds",fix="Make fewer poses, or raise tolerance");return}
            append(&rows,row)
            result.rows+=1;moved=true
        }
        if moved {result.poses+=1} else {result.still+=1}
        // The Float curves of the clip at its frame are what the pose brings with it.
        for &track,t in view.tracks[clip.first_track:][:clip.track_count] {
            name:=base.text_get(track.target[:])
            if track.property!=.Float || track.slot!=0 || strings.contains(name,aa.ANIMATION_MORPH_PATH) || len(name)>=64 || name==base.text_get(pose.curve[:]) {continue}
            value:=lib.clip_evaluate(&library,lib.clip_tracks(&library,handle)[t],pose.time).x
            if abs(value)<=tolerance || !(abs(value)<1e9) {continue}
            drive:=anim.CURVE_DRIVE_DEFAULT
            drive.from,drive.scale=pose.curve,value
            base.text_set(drive.to[:],name)
            if len(drives)>=anim.POSE_CURVE_ROWS {authoring_failure(call,"poses","Capacity",fmt.tprintf("at most %d curve drives",anim.POSE_CURVE_ROWS),fmt.tprintf("%d and more",len(drives)),"The curves of the poses are more than a .character holds",fix="Make fewer poses, or raise tolerance");return}
            append(&drives,drive)
            result.drives+=1
        }
    }
    profile.curve_poses,profile.curve_drives=rows[:],drives[:]
    doc:aa.Document;defer aa.document_destroy(&doc)
    if error:=anim.character_document(&doc,&s.app.assets.types,p.asset,set,s.app.allocator);error!=.None {authoring_failure(call,"asset","Out_Of_Memory" if error==.Out_Of_Memory else "Invalid_Definition","valid curve poses within the capacities of a .character",fmt.tprintf("%v",error),"The edit of the .character could not be prepared",api.SERVER_ERROR if error==.Out_Of_Memory else api.INVALID_PARAMS);return}
    write :: proc(call:^api.Call,data:rawptr) {
        result:=(^Profile_Poses_Result)(data)
        api.write_uint(call.out,"poses",u64(result.poses));api.write_uint(call.out,"rows",u64(result.rows));api.write_uint(call.out,"still",u64(result.still));api.write_uint(call.out,"drives",u64(result.drives))
    }
    _=authoring_publish(s,call,file,&doc,write,&result)
}
