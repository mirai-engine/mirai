package main

import "core:fmt"
import "core:math"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import cam "mirai:engine/camera"
import inp "mirai:engine/input"
import spawn "plugins:spawn/runtime"
import anim "plugins:animation/runtime"
import cine "plugins:cinematics/runtime"
import render "mirai:engine/render"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private)
control_camera :: proc(s:^asset.Scene_Builder,name:string,position:[3]f32,pitch,yaw:f32) -> base.Entity_Id {
    id:=asset.builder_entity(s,name,{position=position})
    transform:=core.Transform{position,mm.quat_from_euler({pitch,yaw,0}),{1,1,1}}
    camera:=render.Camera{fov=game.VIEW_FOV,near=0.05}
    asset.builder_set(s,id,transform)
    asset.builder_set(s,id,camera)
    return id
}

@(private)
control_visual :: proc(s:^asset.Scene_Builder,body:base.Entity_Id,dog:bool) {
    parts:=game.actor_parts(dog)
    for part in parts.items[:parts.count] {
        id:=asset.builder_entity(s,part.name,{position=part.position,scale=part.scale},body)
        mesh:=render.Mesh_Renderer{shape=.Cube}
        tint:=render.Tint{color=part.color}
        asset.builder_set(s,id,mesh)
        asset.builder_set(s,id,tint)
        // A camera at the eyes of the person does not draw its head.
        if !dog && part.name=="Head" {
            layers:=render.Layers{mask=cam.HEAD_LAYER}
            asset.builder_set(s,id,layers)
        }
    }
}

// Where the bodies of the players appear, one place per player.
@(private)
control_spawns :: proc(s:^asset.Scene_Builder,name:string,prefab:base.Asset_Id,first:[3]f32) {
    for i in 0..<inp.LOCAL_CAPACITY {
        point:=spawn.Spawn_Point{prefab=prefab}
        asset.builder_set(s,placed(s,fmt.tprintf("%s %d",name,i+1),first+{f32(i)*2,0,0},1,{1,1,1}),point)
    }
}

write_control_scene :: proc(o:^Out) {
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.content_id(PROJECT,"scene","control"))
    defer asset.builder_destroy(&s)
    demo:=game.Control_Demo{}
    asset.builder_set(&s,asset.builder_entity(&s,"Control demo"),demo)
    environment,turn,to_sun,disc:=sky_of(o,.Day,mm.quat_rotate(mm.quat_from_euler({-0.9,-0.6,0}),render.SUN_DIRECTION),LAMPLIT,1.3)
    sky_set(&s,&environment,turn)
    sun:=render.Sun{color={1,0.94,0.85},illuminance=lux(LAMPLIT,1.3),disc=disc}
    sun_entity:=asset.builder_entity(&s,"Sun",{position={0,6,0}})
    pose:=sun_pose(to_sun,{0,6,0})
    asset.builder_set(&s,sun_entity,pose)
    asset.builder_set(&s,sun_entity,sun)
    lamp:=render.Point_Light{color={1,0.86,0.66},intensity=candela(LAMPLIT,30),range=15,radius=0.1}
    asset.builder_set(&s,asset.builder_entity(&s,"Room light",{position={2,4,1}}),lamp)
    solid(&s,asset.builder_entity(&s,"Floor",{position={0,-0.05,0},scale={14,0.1,14}}),"Tiles")
    north:=asset.builder_entity(&s,"Red wall",{position={0,1.5,-6},scale={14,3,0.2}})
    solid(&s,north,"Lacquer")
    tint:=render.Tint{color={0.82,0.18,0.14,1}}
    asset.builder_set(&s,north,tint)
    solid(&s,asset.builder_entity(&s,"West wall",{position={-6,1.5,0},scale={0.2,3,14}}),"Marble")
    solid(&s,asset.builder_entity(&s,"Stone block",{position={-2,0.75,-1},scale={1.5,1.5,1.5}}),"Brushed steel")
    solid(&s,asset.builder_entity(&s,"Wood box",{position={3,0.5,-3}}),"Planks")
    control_spawns(&s,"Player start",PERSON_PREFAB_ID,{-3,0,2})
    control_camera(&s,game.CONTROL_SHARED_CAMERA,{0,12,0},-math.PI/2,0)

    // The intro is a clip: it moves the room camera, narrows the lens of the dog camera and marks
    // the bark; the cameras are its actors by name, and two shots choose which one is seen.
    ROOM,DOG :: "Intro room camera","Intro dog camera"
    CUT :: f32(50)/60
    intro:=asset.content_id(PROJECT,"animation","control_intro")
    {
        dolly:=[]lib.Keyframe{{time=0,value={5,5,9,0}},{time=CUT,value={4,4.5,8,0},ease=.Cubic_In_Out}}
        zoom:=[]lib.Keyframe{{time=CUT,value={game.VIEW_FOV,0,0,0}},{time=2*CUT,value={0.9,0,0,0},ease=.Cubic_In_Out}}
        clips:=[]asset.Animation_Clip_Desc{{name="intro",tracks={{target=ROOM,property=.Position,keys=dolly},{target=DOG+"/"+asset.ANIMATION_FIELD_PATH+"Camera.fov",property=.Float,keys=zoom}},markers={{CUT/2,"intro.bark"}}}}
        asset.content_check(&o.content,"assets/control/intro.anim",asset.animation_save(path(o,"assets/control/intro.anim"),&o.content.types,{id=intro,clips=clips}))
    }
    timeline:=asset.builder_entity(&s,game.CONTROL_INTRO)
    {
        value:=anim.ANIMATION_DEFAULT
        value.asset,value.loop,value.fade=intro,false,0
        asset.builder_set(&s,timeline,value)
        asset.builder_set(&s,timeline,cine.Cinematic{})
    }
    actor :: proc(s:^asset.Scene_Builder,timeline,e:base.Entity_Id,name:string) {
        target:=anim.Animation_Target{animation=core.Entity(timeline)}
        base.text_set(target.path[:],name)
        asset.builder_set(s,e,target)
    }
    first:=control_camera(&s,ROOM,{5,5,9},-0.48,0.62)
    actor(&s,timeline,first,ROOM)
    shot:=cine.Cinematic_Shot{timeline=core.Entity(timeline),camera=core.Entity(first)}
    asset.builder_set(&s,first,shot)
    second:=control_camera(&s,DOG,{-4,3,7},-0.35,-0.72)
    actor(&s,timeline,second,DOG)
    shot={timeline=core.Entity(timeline),camera=core.Entity(second),time=CUT,blend=f32(20)/60,ease=.Cubic_In_Out}
    asset.builder_set(&s,second,shot)
    output:=control_camera(&s,"Intro output",{5,5,9},-0.48,0.62)
    viewer:=cine.Cinematic_Viewer{timeline=core.Entity(timeline),block_mask=inp.ALL_ACTIONS}
    asset.builder_set(&s,output,viewer)
    split:=inp.Local_Multiplayer{players=2}
    asset.builder_set(&s,asset.builder_entity(&s,"Local multiplayer"),split)
    asset.builder_save(&s,path(o,"assets/control/control.scene"))
}
