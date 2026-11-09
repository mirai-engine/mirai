package main

import "core:fmt"
import "core:math"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import cam "mirai:engine/camera"
import inp "mirai:engine/input"
import spawn "plugins:spawn/runtime"
import cine "plugins:cinematics/runtime"
import render "mirai:engine/render"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(private)
control_camera :: proc(s:^Scene_Out,name:string,position:[3]f32,pitch,yaw:f32) -> base.Entity_Id {
    id:=entity(s,name,position)
    transform:=core.Transform{position,mm.quat_from_euler({pitch,yaw,0}),{1,1,1}}
    camera:=render.Camera{fov=game.VIEW_FOV,near=0.05}
    put(s,id,"Transform",&transform)
    put(s,id,"Camera",&camera)
    return id
}

@(private)
control_visual :: proc(s:^Scene_Out,body:base.Entity_Id,dog:bool) {
    parts:=game.actor_parts(dog)
    for part in parts.items[:parts.count] {
        id:=entity(s,part.name,part.position,part.scale,body)
        mesh:=render.Mesh_Renderer{shape=.Cube}
        tint:=render.Tint{color=part.color}
        put(s,id,"Mesh_Renderer",&mesh)
        put(s,id,"Tint",&tint)
        // A camera at the eyes of the person does not draw its head.
        if !dog && part.name=="Head" {
            layers:=render.Layers{mask=cam.HEAD_LAYER}
            put(s,id,"Layers",&layers)
        }
    }
}

// Where the bodies of the players appear, one place per player.
@(private)
control_spawns :: proc(s:^Scene_Out,name:string,prefab:base.Asset_Id,first:[3]f32) {
    for i in 0..<inp.LOCAL_CAPACITY {
        point:=spawn.Spawn_Point{prefab=prefab}
        put(s,placed(s,fmt.tprintf("%s %d",name,i+1),first+{f32(i)*2,0,0},HALF_TURN,{1,1,1}),"Spawn_Point",&point)
    }
}

write_control_scene :: proc(o:^Out) {
    s:Scene_Out
    asset.scene_init(&s.scene,&o.types,asset.KIND_SCENE,id_of("scene","control"))
    defer asset.scene_destroy(&s.scene)
    demo:=game.Control_Demo{}
    put(&s,entity(&s,"Control demo"),"Control_Demo",&demo)
    environment,turn,to_sun,disc:=sky_of(o,.Day,mm.quat_rotate(mm.quat_from_euler({-0.9,-0.6,0}),render.SUN_DIRECTION),LAMPLIT,1.3)
    sky_set(&s,&environment,turn)
    sun:=render.Sun{color={1,0.94,0.85},illuminance=lux(LAMPLIT,1.3),disc=disc}
    sun_entity:=entity(&s,"Sun",{0,6,0})
    pose:=sun_pose(to_sun,{0,6,0})
    put(&s,sun_entity,"Transform",&pose)
    put(&s,sun_entity,"Sun",&sun)
    lamp:=render.Point_Light{color={1,0.86,0.66},intensity=candela(LAMPLIT,30),range=15,radius=0.1}
    put(&s,entity(&s,"Room light",{2,4,1}),"Point_Light",&lamp)
    solid(&s,entity(&s,"Floor",{0,-0.05,0},{14,0.1,14}),"Tiles")
    north:=entity(&s,"Red wall",{0,1.5,-6},{14,3,0.2})
    solid(&s,north,"Lacquer")
    tint:=render.Tint{color={0.82,0.18,0.14,1}}
    put(&s,north,"Tint",&tint)
    solid(&s,entity(&s,"West wall",{-6,1.5,0},{0.2,3,14}),"Marble")
    solid(&s,entity(&s,"Stone block",{-2,0.75,-1},{1.5,1.5,1.5}),"Brushed steel")
    solid(&s,entity(&s,"Wood box",{3,0.5,-3},{1,1,1}),"Planks")
    control_spawns(&s,"Player start",game.PERSON_PREFAB,{-3,0,2})
    control_camera(&s,game.CONTROL_SHARED_CAMERA,{0,12,0},-math.PI/2,0)

    timeline:=entity(&s,game.CONTROL_INTRO)
    cinematic:=cine.Cinematic{duration_ticks=100,auto_play=true}
    put(&s,timeline,"Cinematic",&cinematic)
    first:=control_camera(&s,"Intro room camera",{5,5,9},-0.48,0.62)
    shot:=cine.Cinematic_Shot{timeline=core.Entity(timeline),camera=core.Entity(first)}
    put(&s,first,"Cinematic_Shot",&shot)
    track:=cine.Cinematic_Track{timeline=core.Entity(timeline),target=core.Entity(first),property=.Position,key_count=2}
    track.keys[0]={time=0,value={5,5,9,0}}
    track.keys[1]={time=50,value={4,4.5,8,0},ease=.Cubic_In_Out}
    put(&s,first,"Cinematic_Track",&track)
    second:=control_camera(&s,"Intro dog camera",{-4,3,7},-0.35,-0.72)
    shot={timeline=core.Entity(timeline),camera=core.Entity(second),tick=50,blend_ticks=20,ease=.Cubic_In_Out}
    put(&s,second,"Cinematic_Shot",&shot)
    fov_track:=cine.Cinematic_Track{timeline=core.Entity(timeline),target=core.Entity(second),property=.Fov,key_count=2}
    fov_track.keys[0]=lib.Keyframe{time=50,value={game.VIEW_FOV,0,0,0}}
    fov_track.keys[1]=lib.Keyframe{time=100,value={0.9,0,0,0},ease=.Cubic_In_Out}
    put(&s,second,"Cinematic_Track",&fov_track)
    marker:=cine.Cinematic_Marker{timeline=core.Entity(timeline),tick=25,id=base.name_hash("intro.bark")}
    put(&s,entity(&s,"Intro bark event"),"Cinematic_Marker",&marker)
    output:=control_camera(&s,"Intro output",{5,5,9},-0.48,0.62)
    viewer:=cine.Cinematic_Viewer{timeline=core.Entity(timeline),block_mask=inp.ALL_ACTIONS}
    put(&s,output,"Cinematic_Viewer",&viewer)
    split:=inp.Local_Multiplayer{players=2}
    put(&s,entity(&s,"Local multiplayer"),"Local_Multiplayer",&split)
    if s.failed {
        fmt.eprintln("demo_content: the control scene could not be built")
        o.failed=true
        return
    }
    check(o,"assets/control/control.scene",asset.scene_save(&s.scene,path(o,"assets/control/control.scene")))
}
