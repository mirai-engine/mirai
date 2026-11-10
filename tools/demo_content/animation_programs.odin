package main

import "mirai:asset"
import "core:fmt"
import importer "mirai:cook/import"
import game "mirai:demo/game"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import locomotion "plugins:locomotion/runtime"

// Writes the .character of name in folder: set over its clips of animation.
@(private)
gallery_set :: proc(o:^Out,folder,name:string,animation:base.Asset_Id,set:anim.Character_Set) {
    id:=asset.content_id(PROJECT,"character",name)
    set:=set;set.info.animation=animation
    if set.match.info==({}) {set.match.info=anim.MATCH_INFO_DEFAULT}
    if set.motion.warp==({}) {set.motion.warp=anim.POSE_WARP_PROFILE_DEFAULT}
    file:=fmt.tprintf("assets/%s/%s.character",folder,name)
    asset.content_check(&o.content,file,anim.character_save(path(o,file),&o.content.types,id,set))
}

// The .character sets of the gallery's Mirai over mirai_gallery.anim: its locomotion by matching
// over idle, walk and jog with its named actions, and those of its stations: a greeting layer
// over the left arm, a jog layer in step with the walk, a wave space added over the walk, the
// named actions alone, and the warp of its stride to a target.
@(private)
gallery_program_assets :: proc(o:^Out,model:^importer.Imported_Model,animation:base.Asset_Id) {
    folder:="characters/mirai"
    shoulder:=rig_path(model,"LeftShoulder")
    layer :: proc(name:string) -> anim.Stack_Layer {value:=anim.STACK_LAYER_DEFAULT;base.text_set(value.name[:],name);return value}
    // The wave over the left arm of the walk, by the weight the game sets.
    arm:=layer(game.GALLERY_ARM);base.text_set(arm.clip[:],"wave");arm.over,arm.fade=anim.bone_ref(shoulder),.35
    gallery_set(o,folder,"mirai_greeting",animation,{actions={layers={arm}}})
    // The jog in step with the walk, by the weight the game sets.
    jog:=layer(game.GALLERY_JOG);base.text_set(jog.clip[:],"jog");jog.sync,jog.weight,jog.fade=true,.5,.25
    gallery_set(o,folder,"mirai_strides",animation,{actions={layers={jog}}})
    // What the wave space changes from its start, added over the walk at the place its axis is set to.
    wave:=anim.Blend_Info{dimension=.One,x={min=0,max=1}};base.text_set(wave.name[:],"wave");base.text_set(wave.x.name[:],game.GALLERY_WAVE)
    samples:=[2]anim.Blend_Sample{{position={0,0},speed=1},{position={1,0},speed=1}}
    base.text_set(samples[0].clip[:],"idle");base.text_set(samples[1].clip[:],"wave")
    offset:=layer("Wave offset");offset.mode,offset.fade=.Additive,0;base.text_set(offset.space[:],"wave")
    gallery_set(o,folder,"mirai_wave_additive",animation,{actions={layers={offset}},spaces={wave},space_samples=samples[:]})
    // Greet in a layer over the left arm; Step and Wave over the whole body, which over
    // locomotion leave it and come back to it by inertialization. Their sections are spans of
    // their clips (mirai_gallery_animation).
    greet:=layer("Arm");greet.over=anim.bone_ref(shoulder)
    definitions:=[3]anim.Action_Definition{anim.ACTION_DEFINITION_DEFAULT,anim.ACTION_DEFINITION_DEFAULT,anim.ACTION_DEFINITION_DEFAULT}
    base.text_set(definitions[0].name[:],"Greet");base.text_set(definitions[0].clip[:],"wave");base.text_set(definitions[0].layer[:],"Arm");definitions[0].priority=1
    base.text_set(definitions[1].name[:],"Step");base.text_set(definitions[1].clip[:],"stride");definitions[1].root_motion=.In_Place;definitions[1].priority=2;definitions[1].fade_in=.15;definitions[1].fade_out=.2
    base.text_set(definitions[2].name[:],"Wave");base.text_set(definitions[2].clip[:],"wave");definitions[2].fade_in,definitions[2].fade_out=.15,.2
    sections:=[2]anim.Action_Section{{action=0,next=-1},{action=1,next=-1}}
    base.text_set(sections[0].name[:],"Greeting");base.text_set(sections[1].name[:],"Advance")
    actions:=anim.Action_Profile{layers={greet},actions=definitions[:],sections=sections[:]}
    gallery_set(o,folder,"mirai_actions",animation,{actions=actions})
    clips:[3]anim.Match_Source
    for name,i in ([3]string{"idle","walk","jog"}) {base.text_set(clips[i].clip[:],name);clips[i].loop=true;clips[i].modes=1<<u32(locomotion.MODE_WALKING)}
    info:=anim.MATCH_INFO_DEFAULT;info.keep_loop_phase=true;info.stationary_speed=.15
    gallery_set(o,folder,"mirai_gallery",animation,{match={info=info,clips=clips[:]},actions=actions})
    window:=anim.MOTION_WINDOW_DEFAULT;window.rotation=false;window.axes={true,false,true};base.text_set(window.name[:],game.GALLERY_REACH)
    gallery_set(o,folder,"mirai_reach",animation,{motion={warp=anim.POSE_WARP_PROFILE_DEFAULT,windows={window}}})
}
