package main

import "core:fmt"
import "core:math/linalg"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

@(private)
rig_path :: proc(model:^importer.Imported_Model,name:string) -> string {
    for &bone in model.skeletons[0].bones {if base.text_get(bone.name[:])==name {return base.text_get(bone.path[:])}}
    return name
}

// The walkway of animation_gallery/animation.scene runs toward -Z from where the player starts;
// its stations alternate on its left and right, one row every GALLERY_ROW meters. A constraint of
// a set aims at a point of the world, so the set follows where the scene puts its station.
@(private) GALLERY_SIDE :: 5.5 // m from the center of the walkway to a station
@(private) GALLERY_ROW :: 5
@(private) GALLERY_CONSTRAINTS :: 12 // the stations of the sets, in the order of the scene
@(private) GALLERY_RIGS :: 14

// Where a station stands, and the turn of its actor toward the walkway.
@(private)
gallery_place :: proc(index:int) -> (origin:mm.Vec3,facing:mm.Quat) {
    side:=f32(-1) if index%2==0 else 1
    return {side*GALLERY_SIDE,0,2-f32(index/2)*GALLERY_ROW},mm.quat_axis_angle({0,1,0},side*mm.PI*.5)
}

// The right hand of the actor of the constraints station reaches a point in front of it, in line
// with its forearm, and its head looks at that point within a limit, over the clips of animation.
@(private)
mirai_constraints :: proc(o:^Out,model:^importer.Imported_Model,animation:base.Asset_Id) {
    origin,facing:=gallery_place(GALLERY_CONSTRAINTS)
    reach,pole:=origin+mm.quat_rotate(facing,{.42,1.3,-.42}),origin+mm.quat_rotate(facing,{.9,.9,.6})
    ik:=anim.IK_CONSTRAINT_DEFAULT;ik.target,ik.hold,ik.pole=anim.spatial_point(reach),.Joint,pole
    ik.root,ik.joint,ik.end=anim.bone_ref("RightArm"),anim.bone_ref("RightForeArm"),anim.bone_ref("RightHand")
    rig,_:=mirai_rig(model)
    head:=mirai_bone(model,"Head")
    look:=anim.LOOK_CONSTRAINT_DEFAULT;look.bone=anim.bone_ref("Head");look.target=ik.target
    look.forward,look.max_angle=linalg.normalize0(mm.quat_forward(mm.quat_inverse(rig.rest_world[head].rotation))),.6
    limit:=anim.ROTATION_CONSTRAINT_DEFAULT;limit.bone=anim.bone_ref("Head");limit.max_swing,limit.min_twist,limit.max_twist=.35,-.6,.6
    gallery_set(o,"characters/mirai","mirai_constraints",animation,{pose={ik={ik},look={look},limits={limit}}})
}

// The clips of the source hold each hand 25 to 50 degrees off its bind, bent out of line with the
// forearm: its rotations turn around the bind instead of around their mean.
@(private)
mirai_hands :: proc(model:^importer.Imported_Model,rig:Mirai_Rig,clip:^asset.Animation_Clip_Desc) {
    paths:=[2]string{rig_path(model,"LeftHand"),rig_path(model,"RightHand")}
    bones:=[2]int{mirai_bone(model,"LeftHand"),mirai_bone(model,"RightHand")}
    tracks:=make([]asset.Animation_Track_Desc,len(clip.tracks),context.temp_allocator);copy(tracks,clip.tracks)
    for &track in tracks {
        for hand,side in paths {
            if track.target!=hand || track.property!=.Rotation || bones[side]<0 || len(track.keys)==0 {continue}
            mean:mm.Vec4
            for key in track.keys {mean+=key.value if linalg.dot(key.value,track.keys[0].value)>=0 else -key.value}
            around:=mm.quat_inverse(lib.vec4_quat(linalg.normalize0(mean)))
            keys:=make([]lib.Keyframe,len(track.keys),context.temp_allocator);copy(keys,track.keys)
            for &key in keys {key.value=lib.quat_vec4(linalg.normalize(rig.rest[bones[side]].rotation*around*lib.vec4_quat(key.value)))}
            track.keys=keys
        }
    }
    clip.tracks=tracks
}

// The locomotion clips of Mirai with its hands in line and those on the ground lowered to its floor:
// retargeting raised it above the height of its feet at rest. It returns them for the gallery
// clips made from them.
@(private)
mirai_animation :: proc(o:^Out,model:^importer.Imported_Model) -> (id:base.Asset_Id,clips:[]asset.Animation_Clip_Desc) {
    id=asset.content_id(PROJECT,"animation","mirai_locomotion")
    bones:=model.skeletons[0].bones
    rig,valid:=mirai_rig(model)
    ground_bones:=[4]int{mirai_bone(model,"LeftFoot"),mirai_bone(model,"LeftToeBase"),mirai_bone(model,"RightFoot"),mirai_bone(model,"RightToeBase")}
    hips:=mirai_bone(model,"Hips")
    if hips<0 || !valid {o.content.failed=true;return}
    for bone in ground_bones {if bone<0 {o.content.failed=true;return}}
    clips=make([]asset.Animation_Clip_Desc,len(model.animations),context.temp_allocator)
    copy(clips,model.animations)
    skeleton:=imported_id(o,"assets/characters/mirai/mirai.glb",asset.KIND_SKELETON,model.skeletons[0].name)
    for &clip in clips {
        clip.skeleton=skeleton
        mirai_hands(model,rig,&clip)
        if clip.name!="idle" && clip.name!="walk" && clip.name!="land" {continue}
        hip_track:=-1
        for track,i in clip.tracks {if track.target==rig_path(model,"Hips") && track.property==.Position {hip_track=i}}
        if hip_track<0 {o.content.failed=true;return}
        frames,times,sampled:=mirai_clip_frames(rig,clip,60)
        if !sampled {o.content.failed=true;return}
        keys:=make([]lib.Keyframe,len(frames),context.temp_allocator)
        for world,frame in frames {
            // The lowest ankle or toe stays at its rest height without changing X/Z.
            lift:=max(f32)
            for bone in ground_bones {lift=min(lift,world[bone].position.y-rig.rest_world[bone].position.y)}
            parent:=bones[hips].parent
            placed:=world[hips].position-mm.Vec3{0,lift,0}
            point:=mm.transform_inverse_point(world[parent],placed) if parent>=0 else placed
            keys[frame]={time=times[frame],value={point.x,point.y,point.z,0},interpolation=.Linear}
        }
        adjusted:=make([]asset.Animation_Track_Desc,len(clip.tracks),context.temp_allocator)
        copy(adjusted,clip.tracks);adjusted[hip_track].keys=keys;clip.tracks=adjusted
    }
    asset.content_check(&o.content,"assets/characters/mirai/mirai_locomotion.anim",asset.animation_save(path(o,"assets/characters/mirai/mirai_locomotion.anim"),&o.content.types,{id=id,clips=clips}))
    return
}

@(private)
mirai_feet :: proc(model:^importer.Imported_Model) -> anim.Foot_Grounding {
    // Its body and legs are those of the body of its skeleton.
    feet:=anim.FOOT_GROUNDING_DEFAULT;feet.count=2
    feet.global_contact=0;feet.max_rise=.15;feet.trace_above=.55;feet.trace_below=.9;feet.blend_time=.08
    bones:=model.skeletons[0].bones
    rest:=make([]mm.Transform,len(bones),context.temp_allocator)
    for bone,i in bones {
        rest[i]={bone.translation,bone.rotation,bone.scale}
        if bone.parent>=0 {rest[i]=mm.transform_compose(rest[bone.parent],rest[i])}
    }
    for side,i in ([]string{"Left","Right"}) {
        leg:=anim.GROUNDED_LEG_DEFAULT
        leg.pole_offset={};leg.max_distance=.55;leg.contact_height=.04;leg.plant_speed=.6
        for &bone,j in bones {
            if base.text_get(bone.name[:])==fmt.tprintf("%sFoot",side) {
                leg.foot_up=mm.quat_rotate(conj(rest[j].rotation),{0,1,0})
                leg.sole_height=max(0,rest[j].position.y)
            }
            if base.text_get(bone.name[:])==fmt.tprintf("%sToeBase",side) {leg.contact_offset=max(0,rest[j].position.y)}
        }
        feet.legs[i]=leg
    }
    return feet
}

// The clips, .character sets, rigs and meshes of the animation gallery
// (animation_gallery/animation.scene), made from the import of Mirai.
write_animation_assets :: proc(o:^Out) {
    source:="assets/characters/mirai/mirai.glb"
    model,error:=importer.import_model(path(o,source),sources.FORMATS[:],{root=fmt.tprintf("%s/demo",o.root)})
    if error.code!=.None {fmt.eprintln(error.message);o.content.failed=true;return}
    defer importer.model_destroy(&model)
    locomotion,locomotion_clips:=mirai_animation(o,&model)
    if o.content.failed {return}
    clip:=mirai_gallery_animation(o,&model,locomotion_clips)
    if o.content.failed {return}
    gallery_program_assets(o,&model,clip)
    gallery_mirai_matching(o,&model,locomotion)
    mirai_constraints(o,&model,clip)
    gallery_retarget(o,&model,source)
    gallery_rigs(o)
    gallery_spider(o)
    gallery_morphs(o)
}
