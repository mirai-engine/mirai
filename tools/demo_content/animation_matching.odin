package main

import importer "mirai:cook/import"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// The locomotion of the Mirai that walks by its physics: matching over idle and walk for walking
// and fall for falling, with jump starting falling and land starting walking; the warp of its walk
// to the velocity of its body, turning the pose toward where it goes and stretching the stride to
// its speed; and its feet on the ground.
@(private)
gallery_mirai_matching :: proc(o:^Out,model:^importer.Imported_Model,animation:base.Asset_Id) {
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
    gallery_set(o,"characters/mirai","mirai_matching",animation,{match={info=info,clips=clips[:]},motion={warp=warp},pose={grounding=mirai_feet(model)}})
}
