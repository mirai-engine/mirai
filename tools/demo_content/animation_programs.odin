package main

import "mirai:asset"
import "core:fmt"
import importer "mirai:cook/import"
import game "mirai:demo/game"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

@(private)
Mirai_Programs :: struct {matching,additive,graph,actions,reach,locomotion:base.Asset_Id}


// The programs of the gallery's Mirai over mirai_gallery.anim: its locomotion by matching over
// idle, walk and jog, a wave space added over the walk, a greeting layer over the walk, its named
// actions and the warp of its stride to a target.
@(private)
gallery_program_assets :: proc(o:^Out,model:^importer.Imported_Model,animation:base.Asset_Id,stride_time:f32) -> (programs:Mirai_Programs) {
    programs={asset.content_id(PROJECT,"match","mirai_gallery"),asset.content_id(PROJECT,"graph","mirai_wave_additive"),asset.content_id(PROJECT,"graph","mirai_greeting"),asset.content_id(PROJECT,"action","mirai_actions"),asset.content_id(PROJECT,"motion","mirai_reach"),gallery_mirai_motion(o)}
    shoulder:=rig_path(model,"LeftShoulder")
    clips:[3]anim.Match_Source
    for name,i in ([3]string{"idle","walk","jog"}) {base.text_set(clips[i].clip[:],name);clips[i].loop=true;clips[i].modes=1<<u32(phys.MODE_WALKING)}
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
    parameters:=[1]anim.Graph_Parameter{{value=1,min=0,max=1}}
    base.text_set(parameters[0].name[:],game.GALLERY_WAVE)
    additive:=[3]anim.Graph_Node{anim.GRAPH_NODE_DEFAULT,anim.GRAPH_NODE_DEFAULT,anim.GRAPH_NODE_DEFAULT}
    additive[0].kind=.Clip;base.text_set(additive[0].clip[:],"walk");additive[0].sync_mode=.Independent
    additive[1].kind,additive[1].blend_space,additive[1].x_param=.Blend_Space,space,0
    additive[2].kind,additive[2].left,additive[2].right,additive[2].weight=.Additive,0,1,1
    for name,i in ([3]string{"Walk","Wave space","Wave over walk"}) {base.text_set(additive[i].name[:],name)}
    file:="assets/characters/mirai/mirai_wave_additive.agraph"
    asset.content_check(&o.content,file,anim.graph_save(path(o,file),&o.content.types,programs.additive,{info={animation=animation,output=2},parameters=parameters[:],nodes=additive[:]}))
    greeting:=[3]anim.Graph_Node{anim.GRAPH_NODE_DEFAULT,anim.GRAPH_NODE_DEFAULT,anim.GRAPH_NODE_DEFAULT}
    for name,i in ([2]string{"walk","wave"}) {greeting[i].kind=.Clip;base.text_set(greeting[i].clip[:],name);greeting[i].sync_mode=.Independent}
    greeting[2].kind,greeting[2].left,greeting[2].right,greeting[2].weight_param=.Layer,0,1,0
    base.text_set(greeting[2].over[:],shoulder)
    for name,i in ([3]string{"Walk","Greeting clip","Left arm greeting"}) {base.text_set(greeting[i].name[:],name)}
    file="assets/characters/mirai/mirai_greeting.agraph"
    asset.content_check(&o.content,file,anim.graph_save(path(o,file),&o.content.types,programs.graph,{info={animation=animation,output=2},parameters=parameters[:],nodes=greeting[:]}))
    definitions:=[2]anim.Action_Definition{anim.ACTION_DEFINITION_DEFAULT,anim.ACTION_DEFINITION_DEFAULT}
    base.text_set(definitions[0].name[:],"Greet");base.text_set(definitions[0].clip[:],"wave");definitions[0].over=anim.bone_ref(shoulder);definitions[0].priority=1
    base.text_set(definitions[1].name[:],"Step");base.text_set(definitions[1].clip[:],"stride");definitions[1].layer=2;definitions[1].root_motion=.In_Place;definitions[1].priority=2;definitions[1].fade_in=.15;definitions[1].fade_out=.2
    sections:=[2]anim.Action_Section{{action=0,start=0,end=2,next=-1},{action=1,start=0,end=1.5,next=-1}}
    base.text_set(sections[0].name[:],"Greeting");base.text_set(sections[1].name[:],"Advance")
    action_window:=anim.Action_Window{action=1,start=.3,end=1.2};base.text_set(action_window.name[:],"Movement")
    asset.content_check(&o.content,"assets/characters/mirai/mirai_actions.action",anim.action_profile_save(path(o,"assets/characters/mirai/mirai_actions.action"),&o.content.types,programs.actions,{info={animation=animation},actions=definitions[:],sections=sections[:],windows={action_window}}))
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
