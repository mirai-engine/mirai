package main

import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import cam "mirai:engine/camera"
import inp "mirai:engine/input"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// The locomotion of Mirai by motion matching: idle and walk serve walking and fall serves
// falling; jump starts falling and land starts walking.
@(private)
gallery_mirai_matching :: proc(o:^Out,animation:base.Asset_Id) -> base.Asset_Id {
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
    file:="assets/animations/mirai_matching.match"
    asset.content_check(&o.content,file,anim.match_save(path(o,file),&o.content.types,id,{info=info,clips=clips[:]}))
    return id
}

// A Mirai that walks by its physics: the plugin animation_physics tells its matching what its
// Character does, and its feet keep to the ground.
@(private)
gallery_mirai_physical :: proc(g:^Gallery_Build,name:string,position:mm.Vec3,matching,motion:base.Asset_Id,facing:mm.Quat=1) -> base.Entity_Id {
    s:=g.s
    root:=gallery_actor(g.o,s,g.model,g.source,name,position,facing,matching)
    character:=phys.character_default();character.step_height=.3;character.move_relative_to=.Game
    walk:=phys.WALK_DEFAULT;walk.max_speed=game.MIRAI_WALK_SPEED;walk.acceleration=20.48;walk.braking=20;walk.air_control=.35;walk.jump_height=.9
    capsule:=phys.collider_character()
    asset.builder_set(s,root,character);asset.builder_set(s,root,walk);asset.builder_set(s,root,capsule)
    animation,_:=asset.scene_get(&s.scene,root,"Animation",anim.Animation);animation.motion=motion;asset.builder_set(s,root,animation)
    gallery_profile(g.o,s,root,"mirai_grounding",{grounding={mirai_feet(g.model)}})
    return root
}

// The seat of the gallery drives Mirai from the start, behind it with the camera; E at the spider
// hands the seat to the spider's body and its camera.
@(private)
gallery_player :: proc(s:^asset.Scene_Builder,mirai,spider:base.Entity_Id) {
    player:=asset.builder_entity(s,"Gallery player")
    camera:=asset.builder_entity(s,"Mirai camera")
    lens:=render.CAMERA_DEFAULT;lens.active=false;lens.fov=60*mm.RAD_PER_DEG
    asset.builder_set(s,camera,lens)
    follow:=cam.CAMERA_FOLLOW_DEFAULT
    follow.target,follow.offset,follow.distance=core.Entity(mirai),{0,1.05,0},3.8
    follow.yaw,follow.pitch,follow.min_pitch,follow.max_pitch=0,.25,-.5,1.1
    follow.turn=true
    asset.builder_set(s,camera,follow)
    asset.builder_set(s,mirai,inp.Drivable{seat=core.Entity(player),camera=core.Entity(camera)})
    asset.builder_set(s,player,game.Gallery_Player{mirai=core.Entity(mirai),spider=core.Entity(spider)})
    asset.builder_set(s,player,inp.Seat{})
}
