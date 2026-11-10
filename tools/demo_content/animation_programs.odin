package main

import "mirai:asset"
import "core:fmt"
import importer "mirai:cook/import"
import game "mirai:demo/game"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"

@(private)
Mirai_Programs :: struct {matching,greeting,strides,additive,actions,reach,locomotion:base.Asset_Id}

// The action set of a station of the gallery: its layers over the base, and its actions.
@(private)
gallery_action_set :: proc(o:^Out,name:string,id,animation:base.Asset_Id,profile:anim.Action_Profile) {
    profile:=profile;profile.info.animation=animation
    file:=fmt.tprintf("assets/characters/mirai/%s.action",name)
    asset.content_check(&o.content,file,anim.action_profile_save(path(o,file),&o.content.types,id,profile))
}

// The programs of the gallery's Mirai over mirai_gallery.anim: its locomotion by matching over
// idle, walk and jog, and the action sets of its stations: a greeting layer over the left arm, a
// jog layer in step with the walk, a wave space added over the walk, and its named actions, with
// the warp of its stride to a target.
@(private)
gallery_program_assets :: proc(o:^Out,model:^importer.Imported_Model,animation:base.Asset_Id,stride_time:f32) -> (programs:Mirai_Programs) {
    programs={
        matching=asset.content_id(PROJECT,"match","mirai_gallery"),greeting=asset.content_id(PROJECT,"action","mirai_greeting"),strides=asset.content_id(PROJECT,"action","mirai_strides"),
        additive=asset.content_id(PROJECT,"action","mirai_wave_additive"),actions=asset.content_id(PROJECT,"action","mirai_actions"),reach=asset.content_id(PROJECT,"motion","mirai_reach"),locomotion=gallery_mirai_motion(o),
    }
    shoulder:=rig_path(model,"LeftShoulder")
    clips:[3]anim.Match_Source
    for name,i in ([3]string{"idle","walk","jog"}) {base.text_set(clips[i].clip[:],name);clips[i].loop=true;clips[i].modes=1<<u32(locomotion.MODE_WALKING)}
    info:=anim.MATCH_INFO_DEFAULT;info.animation=animation;info.keep_loop_phase=true;info.stationary_speed=.15
    asset.content_check(&o.content,"assets/characters/mirai/mirai_gallery.match",anim.match_save(path(o,"assets/characters/mirai/mirai_gallery.match"),&o.content.types,programs.matching,{info=info,clips=clips[:]}))
    space:=asset.content_id(PROJECT,"blend","mirai_wave")
    wave_info:=anim.Blend_Info{animation=animation,dimension=.One,x={min=0,max=1}}
    base.text_set(wave_info.x.name[:],game.GALLERY_WAVE)
    samples:=[2]anim.Blend_Sample{{position={0,0},speed=1},{position={1,0},speed=1}}
    base.text_set(samples[0].clip[:],"idle");base.text_set(samples[1].clip[:],"wave")
    wave:=anim.Blend_Profile{info=wave_info,samples=samples[:]}
    wave_error:=anim.blend_space_prepare(&wave)
    defer {delete(wave.segments);delete(wave.triangles)}
    if wave_error!=.None {asset.content_check(&o.content,"mirai_wave.blend",wave_error);return}
    asset.content_check(&o.content,"assets/characters/mirai/mirai_wave.blend",anim.blend_space_save(path(o,"assets/characters/mirai/mirai_wave.blend"),&o.content.types,space,wave))
    layer :: proc(name:string) -> anim.Stack_Layer {value:=anim.STACK_LAYER_DEFAULT;base.text_set(value.name[:],name);return value}
    // The wave over the left arm of the walk, by the weight the game sets.
    arm:=layer(game.GALLERY_ARM);base.text_set(arm.clip[:],"wave");arm.over,arm.fade=anim.bone_ref(shoulder),.35
    gallery_action_set(o,"mirai_greeting",programs.greeting,animation,{layers={arm}})
    // The jog in step with the walk, by the weight the game sets.
    jog:=layer(game.GALLERY_JOG);base.text_set(jog.clip[:],"jog");jog.sync,jog.weight,jog.fade=true,.5,.25
    gallery_action_set(o,"mirai_strides",programs.strides,animation,{layers={jog}})
    // What the wave space changes from its start, added over the walk at the place its axis is set to.
    offset:=layer("Wave offset");offset.mode,offset.space,offset.fade=.Additive,space,0
    gallery_action_set(o,"mirai_wave_additive",programs.additive,animation,{layers={offset}})
    // Greet in a layer over the left arm; Step and Wave over the whole body, which over the matching
    // of a .match leave it and come back to it by inertialization.
    greet:=layer("Arm");greet.over=anim.bone_ref(shoulder)
    definitions:=[3]anim.Action_Definition{anim.ACTION_DEFINITION_DEFAULT,anim.ACTION_DEFINITION_DEFAULT,anim.ACTION_DEFINITION_DEFAULT}
    base.text_set(definitions[0].name[:],"Greet");base.text_set(definitions[0].clip[:],"wave");base.text_set(definitions[0].layer[:],"Arm");definitions[0].priority=1
    base.text_set(definitions[1].name[:],"Step");base.text_set(definitions[1].clip[:],"stride");definitions[1].root_motion=.In_Place;definitions[1].priority=2;definitions[1].fade_in=.15;definitions[1].fade_out=.2
    base.text_set(definitions[2].name[:],"Wave");base.text_set(definitions[2].clip[:],"wave");definitions[2].fade_in,definitions[2].fade_out=.15,.2
    sections:=[2]anim.Action_Section{{action=0,start=0,end=2,next=-1},{action=1,start=0,end=1.5,next=-1}}
    base.text_set(sections[0].name[:],"Greeting");base.text_set(sections[1].name[:],"Advance")
    action_window:=anim.Action_Window{action=1,start=.3,end=1.2};base.text_set(action_window.name[:],"Movement")
    gallery_action_set(o,"mirai_actions",programs.actions,animation,{layers={greet},actions=definitions[:],sections=sections[:],windows={action_window}})
    window:=anim.MOTION_WINDOW_DEFAULT;window.end=stride_time;window.rotation=false;window.axes={true,false,true};base.text_set(window.clip[:],"stride");base.text_set(window.name[:],game.GALLERY_REACH)
    asset.content_check(&o.content,"assets/characters/mirai/mirai_reach.motion",anim.motion_profile_save(path(o,"assets/characters/mirai/mirai_reach.motion"),&o.content.types,programs.reach,{info={pose=anim.POSE_WARP_PROFILE_DEFAULT},windows={window}}))
    return
}

// The warp of the walk of Mirai to the velocity of its body: it turns the pose toward where it
// goes and stretches the stride to its speed.
@(private)
gallery_mirai_motion :: proc(o:^Out) -> base.Asset_Id {
    id:=asset.content_id(PROJECT,"motion","mirai_locomotion")
    pose:=anim.POSE_WARP_PROFILE_DEFAULT;pose.orientation,pose.stride=true,true;pose.max_angle=mm.PI*.4;pose.min_stride,pose.max_stride=.05,1.5
    pose.pelvis=anim.bone_ref("Hips");pose.spine_count=2;pose.spine[0],pose.spine[1]=anim.bone_ref("Spine02"),anim.bone_ref("Spine01");pose.count=2
    for side,i in ([2]string{"Left","Right"}) {pose.legs[i]={hip=anim.bone_ref(fmt.tprintf("%sUpLeg",side)),knee=anim.bone_ref(fmt.tprintf("%sLeg",side)),foot=anim.bone_ref(fmt.tprintf("%sFoot",side))}}
    asset.content_check(&o.content,"assets/characters/mirai/mirai_locomotion.motion",anim.motion_profile_save(path(o,"assets/characters/mirai/mirai_locomotion.motion"),&o.content.types,id,{info={pose=pose}}))
    return id
}
