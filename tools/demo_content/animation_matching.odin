package main

import "mirai:asset"
import "mirai:std/base"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// The locomotion of Mirai by motion matching: idle and walk serve walking and fall serves
// falling; jump starts falling and land starts walking.
@(private)
gallery_mirai_matching :: proc(o:^Out,animation:base.Asset_Id) {
    id:=asset.content_id(PROJECT,"match","mirai_matching")
    Clip :: struct {name:string,mode:phys.Locomotion_Mode,loop:bool}
    clips:[5]anim.Match_Source
    for value,i in ([5]Clip{{"idle",phys.MODE_WALKING,true},{"walk",phys.MODE_WALKING,true},{"fall",phys.MODE_FALLING,true},{"jump",phys.MODE_FALLING,false},{"land",phys.MODE_WALKING,false}}) {
        base.text_set(clips[i].clip[:],value.name);clips[i].modes=1<<u32(value.mode);clips[i].loop,clips[i].entry=value.loop,!value.loop
    }
    info:=anim.MATCH_INFO_DEFAULT;info.animation=animation
    // Keep the adapted walk advancing instead of repeatedly seeking within its cycle.
    info.interval=.2;info.bias=.5;info.keep_loop_phase=true;info.stationary_speed=.15
    // Cover both the slow automatic path and the player's full walking speed.
    info.min_rate=.05;info.max_rate=1.3
    file:="assets/characters/mirai/mirai_matching.match"
    asset.content_check(&o.content,file,anim.match_save(path(o,file),&o.content.types,id,{info=info,clips=clips[:]}))
}
