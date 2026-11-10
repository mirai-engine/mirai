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
Mirai_Programs :: struct {matching,greeting,strides,additive,actions,reach:base.Asset_Id}

// Writes the .character of name in folder: set over its clips of animation.
@(private)
gallery_set :: proc(o:^Out,folder,name:string,animation:base.Asset_Id,set:anim.Character_Set) -> base.Asset_Id {
    id:=asset.content_id(PROJECT,"character",name)
    set:=set;set.info.animation=animation
    if set.match.info==({}) {set.match.info=anim.MATCH_INFO_DEFAULT}
    if set.motion.warp==({}) {set.motion.warp=anim.POSE_WARP_PROFILE_DEFAULT}
    file:=fmt.tprintf("assets/%s/%s.character",folder,name)
    asset.content_check(&o.content,file,anim.character_save(path(o,file),&o.content.types,id,set))
    return id
}

// The .character of the actor root: set over the clips its Animation plays, which then plays it.
@(private)
gallery_character :: proc(o:^Out,s:^asset.Scene_Builder,root:base.Entity_Id,folder,name:string,set:anim.Character_Set) {
    value,found:=asset.scene_get(&s.scene,root,"Animation",anim.Animation)
    if !found {value=anim.ANIMATION_DEFAULT}
    value.asset=gallery_set(o,folder,name,value.asset if found else {},set)
    asset.builder_set(s,root,value)
}

// The .character sets of the gallery's Mirai over mirai_gallery.anim: its locomotion by matching
// over idle, walk and jog with its named actions, and those of its stations: a greeting layer
// over the left arm, a jog layer in step with the walk, a wave space added over the walk, the
// named actions alone, and the warp of its stride to a target.
@(private)
gallery_program_assets :: proc(o:^Out,model:^importer.Imported_Model,animation:base.Asset_Id) -> (programs:Mirai_Programs) {
    folder:="characters/mirai"
    shoulder:=rig_path(model,"LeftShoulder")
    layer :: proc(name:string) -> anim.Stack_Layer {value:=anim.STACK_LAYER_DEFAULT;base.text_set(value.name[:],name);return value}
    // The wave over the left arm of the walk, by the weight the game sets.
    arm:=layer(game.GALLERY_ARM);base.text_set(arm.clip[:],"wave");arm.over,arm.fade=anim.bone_ref(shoulder),.35
    programs.greeting=gallery_set(o,folder,"mirai_greeting",animation,{actions={layers={arm}}})
    // The jog in step with the walk, by the weight the game sets.
    jog:=layer(game.GALLERY_JOG);base.text_set(jog.clip[:],"jog");jog.sync,jog.weight,jog.fade=true,.5,.25
    programs.strides=gallery_set(o,folder,"mirai_strides",animation,{actions={layers={jog}}})
    // What the wave space changes from its start, added over the walk at the place its axis is set to.
    wave:=anim.Blend_Info{dimension=.One,x={min=0,max=1}};base.text_set(wave.name[:],"wave");base.text_set(wave.x.name[:],game.GALLERY_WAVE)
    samples:=[2]anim.Blend_Sample{{position={0,0},speed=1},{position={1,0},speed=1}}
    base.text_set(samples[0].clip[:],"idle");base.text_set(samples[1].clip[:],"wave")
    offset:=layer("Wave offset");offset.mode,offset.fade=.Additive,0;base.text_set(offset.space[:],"wave")
    programs.additive=gallery_set(o,folder,"mirai_wave_additive",animation,{actions={layers={offset}},spaces={wave},space_samples=samples[:]})
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
    programs.actions=gallery_set(o,folder,"mirai_actions",animation,{actions=actions})
    clips:[3]anim.Match_Source
    for name,i in ([3]string{"idle","walk","jog"}) {base.text_set(clips[i].clip[:],name);clips[i].loop=true;clips[i].modes=1<<u32(phys.MODE_WALKING)}
    info:=anim.MATCH_INFO_DEFAULT;info.keep_loop_phase=true;info.stationary_speed=.15
    programs.matching=gallery_set(o,folder,"mirai_gallery",animation,{match={info=info,clips=clips[:]},actions=actions})
    window:=anim.MOTION_WINDOW_DEFAULT;window.rotation=false;window.axes={true,false,true};base.text_set(window.name[:],game.GALLERY_REACH)
    programs.reach=gallery_set(o,folder,"mirai_reach",animation,{motion={warp=anim.POSE_WARP_PROFILE_DEFAULT,windows={window}}})
    return
}

// The locomotion of the Mirai that walks by its physics: matching over idle and walk for walking
// and fall for falling, with jump starting falling and land starting walking; the warp of its walk
// to the velocity of its body, turning the pose toward where it goes and stretching the stride to
// its speed; and its feet on the ground.
@(private)
gallery_mirai_matching :: proc(o:^Out,model:^importer.Imported_Model,animation:base.Asset_Id) -> base.Asset_Id {
    Clip :: struct {name:string,mode:phys.Locomotion_Mode,loop:bool}
    clips:[5]anim.Match_Source
    for value,i in ([5]Clip{{"idle",phys.MODE_WALKING,true},{"walk",phys.MODE_WALKING,true},{"fall",phys.MODE_FALLING,true},{"jump",phys.MODE_FALLING,false},{"land",phys.MODE_WALKING,false}}) {
        base.text_set(clips[i].clip[:],value.name);clips[i].modes=1<<u32(value.mode);clips[i].loop,clips[i].entry=value.loop,!value.loop
    }
    info:=anim.MATCH_INFO_DEFAULT
    // Keep the adapted walk advancing instead of repeatedly seeking within its cycle.
    info.interval=.2;info.bias=.5;info.keep_loop_phase=true;info.stationary_speed=.15
    // Cover both the slow automatic path and the player's full walking speed.
    info.min_rate=.05;info.max_rate=1.3
    warp:=anim.POSE_WARP_PROFILE_DEFAULT;warp.orientation,warp.stride=true,true;warp.max_angle=mm.PI*.4;warp.min_stride,warp.max_stride=.05,1.5
    return gallery_set(o,"characters/mirai","mirai_matching",animation,{match={info=info,clips=clips[:]},motion={warp=warp},pose={grounding={mirai_feet(model)}}})
}
