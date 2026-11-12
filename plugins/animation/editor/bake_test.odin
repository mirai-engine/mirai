package animation_editor

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"
import lib "mirai:std/anim"
import anim "plugins:animation/runtime"
import mm "mirai:std/math"

@(test)
baking_without_chains_pairs_bones_by_name_once_and_preserves_curves_markers_and_root_metadata :: proc(t:^testing.T) {
    bones:=[2]asset.Skeleton_Bone{{parent=-1,rotation=1,scale={1,1,1}},{parent=0,translation={0,1,0},rotation=1,scale={1,1,1}}}
    base.text_set(bones[0].name[:],"root");base.text_set(bones[0].path[:],"root");bones[0].target=base.name_hash("root")
    base.text_set(bones[1].name[:],"tip");base.text_set(bones[1].path[:],"root/tip");bones[1].target=base.name_hash("root/tip")
    target:=bones;target[1].translation.y=2
    info:=asset.Skeleton_Info{2}
    clip:=asset.Animation_Clip{first_track=0,track_count=2,first_marker=0,marker_count=1}
    base.text_set(clip.name[:],"walk");base.text_set(clip.root.bone[:],"root");clip.root.translation=true
    tracks:=[2]asset.Animation_Track{{property=.Rotation,first_key=0,key_count=2},{property=.Float,first_key=2,key_count=2}}
    base.text_set(tracks[0].target[:],"root");base.text_set(tracks[1].target[:],"pulse")
    keys:=[4]lib.Keyframe{{time=0,value={0,0,0,1}},{time=1,value={0,0,.70710677,.70710677}},{time=0,value={0,0,0,0}},{time=1,value={1,0,0,0}}}
    marker:=asset.Animation_Marker{time=.5};base.text_set(marker.name[:],"step")
    clips:=asset.Animation_View{clips={clip},tracks=tracks[:],keys=keys[:],markers={marker}}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    rejected:asset.Document
    saved:=context;context.temp_allocator=runtime.nil_allocator()
    error:=retarget_bake(&rejected,&types,{1,2},clips,{info=&info,bones=bones[:]},{info=&info,bones=target[:]},nil,rate=30)
    context=saved
    testing.expect_value(t,error,asset.Error.Out_Of_Memory)
    testing.expect_value(t,len(rejected.tables),0)
    doc:asset.Document;defer asset.document_destroy(&doc)
    testing.expect_value(t,retarget_bake(&doc,&types,{1,2},clips,{info=&info,bones=bones[:]},{info=&info,bones=target[:]},nil,rate=30),asset.Error.None)
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    if !testing.expect_value(t,asset.document_write(&doc,&bytes),asset.Error.None) {return}
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&bytes)),asset.Error.None) {return};defer asset.asset_close(&file)
    output,read:=asset.animation_view(&file,&types)
    if !testing.expect_value(t,read,asset.Error.None) {return}
    testing.expect_value(t,len(output.tracks),7)
    testing.expect_value(t,len(output.markers),1)
    testing.expect_value(t,output.markers[0],marker)
    testing.expect_value(t,output.clips[0].root,clip.root)
    rotation:=output.tracks[1]
    testing.expect_value(t,output.keys[rotation.first_key].value,keys[0].value)
    last:=output.keys[rotation.first_key+rotation.key_count-1].value
    testing.expect(t,abs(last.z-keys[1].value.z)<.0001 && abs(last.w-keys[1].value.w)<.0001)
    middle:=output.keys[rotation.first_key+rotation.key_count/2].value
    testing.expect(t,middle.z>.3 && middle.z<.5)
    testing.expect_value(t,output.keys[output.tracks[3].first_key].value.y,f32(2))
    testing.expect_value(t,output.keys[output.tracks[6].first_key+1].value.x,f32(1))
}

@(private)
bake_test_bones :: proc(bones:[]asset.Skeleton_Bone,prefix:string,step:f32) {
    for &bone,i in bones {
        bone={parent=i32(i-1),rotation=1,scale={1,1,1}}
        if i>0 {bone.translation.y=step}
        name:=fmt.tprintf("%s%d",prefix,i);base.text_set(bone.name[:],name);base.text_set(bone.path[:],name);bone.target=base.name_hash(name)
    }
}

@(test)
baking_semantic_chains_with_distinct_names_and_topologies_preserves_destination_lengths_and_root_mapping :: proc(t:^testing.T) {
    source:[3]asset.Skeleton_Bone;target:[5]asset.Skeleton_Bone
    bake_test_bones(source[:],"source",1);bake_test_bones(target[:],"target",.5)
    source_info,target_info:=asset.Skeleton_Info{3},asset.Skeleton_Info{5}
    source_view,target_view:=asset.Skeleton_View{info=&source_info,bones=source[:]},asset.Skeleton_View{info=&target_info,bones=target[:]}
    clip:=asset.Animation_Clip{track_count=2,marker_count=1};base.text_set(clip.name[:],"bend");clip.root.rotation=true;base.text_set(clip.root.bone[:],"source1")
    tracks:=[2]asset.Animation_Track{{property=.Rotation,key_count=2},{property=.Vector,slot=9,first_key=2,key_count=2}}
    base.text_set(tracks[0].target[:],"source1");base.text_set(tracks[1].target[:],"tint")
    keys:=[4]lib.Keyframe{{time=0,value={0,0,0,1}},{time=1,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},.8))},{time=0,value={1,2,3,4}},{time=1,value={5,6,7,8}}}
    marker:=asset.Animation_Marker{time=.5};base.text_set(marker.name[:],"hit")
    clips:=asset.Animation_View{clips={clip},tracks=tracks[:],keys=keys[:],markers={marker}}
    chain:=anim.CHAIN_RETARGET_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"arm")
    chain.source_root,chain.source_end,chain.target_root,chain.target_end=anim.bone_ref("source0"),anim.bone_ref("source2"),anim.bone_ref("target0"),anim.bone_ref("target4")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document;defer asset.document_destroy(&doc)
    testing.expect_value(t,retarget_bake(&doc,&types,{9,10},clips,source_view,target_view,{chain},rate=20),asset.Error.None)
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    if !testing.expect_value(t,asset.document_write(&doc,&bytes),asset.Error.None) {return}
    file:asset.Asset;if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&bytes)),asset.Error.None) {return};defer asset.asset_close(&file)
    output,read:=asset.animation_view(&file,&types);if !testing.expect_value(t,read,asset.Error.None) {return}
    testing.expect_value(t,len(output.tracks),16);testing.expect_value(t,output.markers[0],marker)
    testing.expect_value(t,base.text_get(output.clips[0].root.bone[:]),"target2")
    testing.expect(t,output.clips[0].root.rotation && !output.clips[0].root.translation)
    curve:=output.tracks[15];testing.expect_value(t,curve.slot,u8(9));testing.expect_value(t,curve.property,lib.Property.Vector)
    testing.expect_value(t,output.keys[curve.first_key+1].value,keys[3].value)
    locals:[5]mm.Transform;world:[5]mm.Transform;rest:[5]mm.Transform;parents:[5]i32;names:[5]u64
    for bone,i in target {parents[i]=bone.parent;names[i]=bone.target;rest[i]={bone.translation,bone.rotation,bone.scale}}
    for frame in 0..<21 {
        for &value,b in locals {
            position,rotation,scale:=output.tracks[b*3],output.tracks[b*3+1],output.tracks[b*3+2]
            p,q,s:=output.keys[position.first_key+u32(frame)].value,output.keys[rotation.first_key+u32(frame)].value,output.keys[scale.first_key+u32(frame)].value
            value={position={p.x,p.y,p.z},rotation=lib.vec4_quat(q),scale={s.x,s.y,s.z}}
            testing.expect_value(t,value.position,target[b].translation)
        }
        testing.expect(t,lib.skeleton_world({parents=parents[:],names=names[:],rest=rest[:]},locals[:],world[:]))
        testing.expect(t,abs(mm.quat_angle(mm.Quat(1),world[2].rotation)-.8*f32(frame)/20)<1e-4)
        testing.expect(t,abs(mm.quat_angle(mm.Quat(1),world[1].rotation)-.4*f32(frame)/20)<1e-4)
    }
}

@(test)
baking_semantic_chains_rejects_unbound_chains_and_allocation_failure_without_publishing :: proc(t:^testing.T) {
    source:[2]asset.Skeleton_Bone;target:[3]asset.Skeleton_Bone
    bake_test_bones(source[:],"old",1);bake_test_bones(target[:],"new",.5)
    si,ti:=asset.Skeleton_Info{2},asset.Skeleton_Info{3}
    clip:=asset.Animation_Clip{track_count=1};base.text_set(clip.name[:],"idle")
    track:=asset.Animation_Track{property=.Rotation,key_count=1};base.text_set(track.target[:],"old0")
    clips:=asset.Animation_View{clips={clip},tracks={track},keys={{time=0,value={0,0,0,1}}}}
    chain:=anim.CHAIN_RETARGET_CONSTRAINT_DEFAULT;base.text_set(chain.name[:],"body")
    chain.source_root,chain.source_end,chain.target_root,chain.target_end=anim.bone_ref("old0"),anim.bone_ref("old1"),anim.bone_ref("new0"),anim.bone_ref("new2")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document
    saved:=context;context.temp_allocator=runtime.nil_allocator()
    error:=retarget_bake(&doc,&types,{1,2},clips,{info=&si,bones=source[:]},{info=&ti,bones=target[:]},{chain})
    context=saved
    testing.expect_value(t,error,asset.Error.Out_Of_Memory);testing.expect(t,len(doc.tables)==0)
    chain.target_end=anim.bone_ref("absent")
    testing.expect_value(t,retarget_bake(&doc,&types,{1,2},clips,{info=&si,bones=source[:]},{info=&ti,bones=target[:]},{chain}),asset.Error.Invalid)
    testing.expect(t,len(doc.tables)==0)
}

// A walker of the given size: root, pelvis and two legs of hip, knee, foot and toe, every bone
// named as its path, with its body.
@(private="file")
Bake_Walker :: struct {
    bones:[10]asset.Skeleton_Bone,
    parts:[9]asset.Skeleton_Body_Part,
    body:asset.Skeleton_Body,
    info:asset.Skeleton_Info,
}

@(private="file")
bake_walker :: proc(w:^Bake_Walker,pelvis,hip,thigh,shin,ankle,toe:f32) -> asset.Skeleton_View {
    names:=[10]string{"root","pelvis","hip_l","knee_l","foot_l","toe_l","hip_r","knee_r","foot_r","toe_r"}
    offsets:=[10]mm.Vec3{{},{0,pelvis,0},{hip,-hip/2,0},{0,-thigh,0},{0,-shin,0},{0,-ankle,-toe},{-hip,-hip/2,0},{0,-thigh,0},{0,-shin,0},{0,-ankle,-toe}}
    parents:=[10]i32{-1,0,1,2,3,4,1,6,7,8}
    for &bone,i in w.bones {
        bone={parent=parents[i],translation=offsets[i],rotation=1,scale={1,1,1}}
        base.text_set(bone.name[:],names[i]);base.text_set(bone.path[:],names[i]);bone.target=base.name_hash(names[i])
    }
    parts:=[9]lib.Body_Part{.Pelvis,.Hip_L,.Knee_L,.Foot_L,.Toe_L,.Hip_R,.Knee_R,.Foot_R,.Toe_R}
    for &row,i in w.parts {row={part=parts[i],confidence=1};base.text_set(row.bone[:],names[i+1])}
    w.body={up={0,1,0},confidence=1}
    w.info={10}
    return {info=&w.info,bones=w.bones[:],body=&w.body,body_parts=w.parts[:]}
}

@(private="file")
bake_walker_rig :: proc(view:asset.Skeleton_View,parents:[]i32,rest:[]mm.Transform) -> lib.Body_Rig {
    for &bone,i in view.bones {parents[i]=bone.parent;rest[i]={bone.translation,bone.rotation,bone.scale}}
    return {parents=parents,rest=rest,body=asset.skeleton_body_map(view.bones,view.body,view.body_parts),root=0}
}

@(test)
baking_a_walk_onto_a_shorter_body_keeps_its_feet_from_sliding_more_than_the_source :: proc(t:^testing.T) {
    source_walker,target_walker:Bake_Walker
    source:=bake_walker(&source_walker,1,.1,.45,.42,.08,.12)
    target:=bake_walker(&target_walker,.5,.05,.3,.135,.04,.06)
    source_parents:[10]i32;source_rest:[10]mm.Transform
    source_rig:=bake_walker_rig(source,source_parents[:],source_rest[:])
    skeleton:=lib.Skeleton{parents=source_parents[:],names=make([]u64,10,context.temp_allocator),rest=source_rest[:]}
    // A walk in place: each foot stands half the cycle while the ground goes back under it,
    // skidding a little as feet captured from people do, and swings forward the other half.
    RATE :: 30
    FRAMES :: RATE+1
    poses:[FRAMES][10]mm.Transform
    for frame in 0..<FRAMES {
        time:=f32(frame)/RATE
        pose:=&poses[frame];pose^=source_rest
        pose[1].position={0,.95+.01*math.cos(4*math.PI*time),0}
        world:[10]mm.Transform
        testing.expect(t,lib.pose_world(source_parents[:],pose[:],world[:]))
        for leg in 0..<2 {
            phase:=math.mod(time+.25+f32(leg)*.5,1)
            side:=f32(.1) if leg==0 else -.1
            ankle:=mm.Vec3{side,.08,-.2+.8*phase+.005*math.sin(4*math.PI*phase)}
            if phase>=.5 {
                swing:=(phase-.5)/.5
                ankle={side,.08+.1*math.sin(math.PI*swing),.2-.4*swing}
            }
            hip,knee,foot:=2+leg*4,3+leg*4,4+leg*4
            testing.expect(t,lib.skeleton_ik(skeleton,pose[:],world[:],hip,knee,foot,ankle,ankle+{0,.5,-1}))
            pose[foot].rotation=conj(world[knee].rotation)
        }
    }
    tracks:=make([]asset.Animation_Track,8,context.temp_allocator)
    keys:=make([]lib.Keyframe,8*FRAMES,context.temp_allocator)
    animated:=[8]int{0,1,2,3,4,6,7,8}
    for bone,k in animated {
        property:=lib.Property.Position if bone<2 else .Rotation
        tracks[k]={property=property,first_key=u32(k*FRAMES),key_count=FRAMES}
        base.text_set(tracks[k].target[:],base.text_get(source.bones[bone].path[:]))
        for frame in 0..<FRAMES {
            value:=poses[frame][bone]
            keys[k*FRAMES+frame]={time=f32(frame)/RATE,value=lib.quat_vec4(value.rotation) if bone>=2 else {value.position.x,value.position.y,value.position.z,0}}
        }
    }
    clip:=asset.Animation_Clip{track_count=8};base.text_set(clip.name[:],"walk")
    clips:=asset.Animation_View{clips={clip},tracks=tracks,keys=keys}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    doc:asset.Document;defer asset.document_destroy(&doc)
    if !testing.expect_value(t,retarget_bake(&doc,&types,{1,2},clips,source,target,nil,rate=RATE,crotch_floor=true),asset.Error.None) {return}
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    if !testing.expect_value(t,asset.document_write(&doc,&bytes),asset.Error.None) {return}
    file:asset.Asset;if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&bytes)),asset.Error.None) {return};defer asset.asset_close(&file)
    output,read:=asset.animation_view(&file,&types);if !testing.expect_value(t,read,asset.Error.None) {return}
    target_parents:[10]i32;target_rest:[10]mm.Transform
    target_rig:=bake_walker_rig(target,target_parents[:],target_rest[:])
    source_frames:=lib.Frames{rate=RATE,bones=10,loop=true,local=make([]mm.Transform,FRAMES*10,context.temp_allocator)}
    baked:=lib.Frames{rate=RATE,bones=10,loop=true,local=make([]mm.Transform,FRAMES*10,context.temp_allocator)}
    for frame in 0..<FRAMES {
        copy(lib.frames_pose(source_frames,frame),poses[frame][:])
        for &value,b in lib.frames_pose(baked,frame) {
            p,q,s:=output.keys[output.tracks[b*3].first_key+u32(frame)].value,output.keys[output.tracks[b*3+1].first_key+u32(frame)].value,output.keys[output.tracks[b*3+2].first_key+u32(frame)].value
            value={{p.x,p.y,p.z},lib.vec4_quat(q),{s.x,s.y,s.z}}
        }
    }
    measure :: proc(rig:lib.Body_Rig,frames:lib.Frames) -> (slide:f32,ok:bool) {
        scratch:=make([]mm.Transform,lib.frames_scratch_size(frames),context.temp_allocator)
        metrics:=lib.clip_metrics(rig,frames,{},scratch) or_return
        return max(metrics.foot_slide[.Left].mean,metrics.foot_slide[.Right].mean)/metrics.height,metrics.contacts>=2
    }
    source_slide,source_ok:=measure(source_rig,source_frames)
    baked_slide,baked_ok:=measure(target_rig,baked)
    testing.expect(t,source_ok && baked_ok)
    testing.expectf(t,baked_slide<=source_slide+1e-3,"the bake slides %v body heights per second, the source %v",baked_slide,source_slide)
    // Keeping the crotch off the floor needs a body on both skeletons.
    rejected:asset.Document
    target.body=nil
    testing.expect_value(t,retarget_bake(&rejected,&types,{1,3},clips,source,target,nil,rate=RATE,crotch_floor=true),asset.Error.Invalid)
    testing.expect_value(t,len(rejected.tables),0)
}
