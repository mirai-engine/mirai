package main

import "core:fmt"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"

DESTRUCTION_SCENE :: base.Asset_Id{0x6d697261695f6465,0x6d6f5f6465737472}
DESTRUCTION_BLOCKS :: 3

// An anchored wall and free blocks marked Destructible, for the cubes the player throws.
write_destruction_scene :: proc(o:^Out) {
    write_physics_gallery(o)
    s:Scene_Out
    asset.scene_init(&s.scene,&o.types,asset.KIND_SCENE,DESTRUCTION_SCENE)
    defer asset.scene_destroy(&s.scene)

    environment,turn,to_sun,disc:=sky_of(o,.Overcast,mm.quat_rotate(mm.quat_from_euler({-0.9,0.5,0}),render.SUN_DIRECTION),LAMPLIT,1)
    sky_set(&s,&environment,turn)
    solid(&s,entity(&s,"Floor",{0,-0.5,0},{40,1,40}),"Tiles")

    // A wall of 5 x 2.6 x 0.4 m standing on the floor, held by its base.
    wall:=entity(&s,"Wall",{0,1.3,-2},{5,2.6,0.4})
    breakable:=destruct.destructible(32,true,11)
    breakable.damage_radius,breakable.interior=0.8,game.material_asset("Cobblestone")
    cube(&s,wall,"Bricks")
    put(&s,wall,"Destructible",&breakable)
    pieces:=destruct.collider_fracture()
    put(&s,wall,"Collider",&pieces)

    // Free blocks: each one a body that breaks where it is hit. The last one starts in the air and breaks on the one below.
    places:=[DESTRUCTION_BLOCKS][3]f32{{-3.2,0.5,0.5},{3.2,0.5,0.8},{3.0,3.4,0.9}}
    names:=[DESTRUCTION_BLOCKS]string{"Block west","Block east","Block falling"}
    for place,at in places {
        block:=entity(&s,names[at],place)
        turn:=core.Transform{place,mm.quat_axis_angle({0,1,0},0.3*f32(at)),{1,1,1}}
        put(&s,block,"Transform",&turn)
        loose:=destruct.destructible(8,false,u64(21+at))
        loose.damage_radius,loose.interior=0.7,game.material_asset("Planks")
        cube(&s,block,"Decking")
        put(&s,block,"Destructible",&loose)
        put(&s,block,"Collider",&pieces)
    }

    sun:=render.Sun{color={1,0.97,0.94},illuminance=lux(LAMPLIT,1),disc=disc}
    sun_entity:=entity(&s,"Sun",{0,8,0})
    pose:=sun_pose(to_sun,{0,8,0})
    put(&s,sun_entity,"Transform",&pose)
    put(&s,sun_entity,"Sun",&sun)
    lamp:=render.Point_Light{color={1,0.85,0.7},intensity=candela(LAMPLIT,12),range=14,radius=0.1}
    put(&s,entity(&s,"Lamp",{0,3.2,1.5}),"Point_Light",&lamp)
    spawn_point(&s,{0,0,4})
    if s.failed {
        fmt.eprintln("demo_content: the destruction scene could not be built")
        o.failed=true
        return
    }
    check(o,"assets/destruction/destruction.scene",asset.scene_save(&s.scene,path(o,"assets/destruction/destruction.scene")))
}
