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
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.KIND_SCENE,DESTRUCTION_SCENE)
    defer asset.builder_destroy(&s)

    environment,turn,to_sun,disc:=sky_of(o,.Overcast,mm.quat_rotate(mm.quat_from_euler({-0.9,0.5,0}),render.SUN_DIRECTION),LAMPLIT,1)
    sky_set(&s,&environment,turn)
    solid(&s,asset.builder_entity(&s,"Floor",{position={0,-0.5,0},scale={40,1,40}}),"Tiles")

    // A wall of 5 x 2.6 x 0.4 m standing on the floor, held by its base.
    wall:=asset.builder_entity(&s,"Wall",{position={0,1.3,-2},scale={5,2.6,0.4}})
    breakable:=destruct.destructible(32,true,11)
    breakable.damage_radius,breakable.interior=0.8,game.material_asset("Cobblestone")
    cube(&s,wall,"Bricks")
    asset.builder_set(&s,wall,breakable)
    pieces:=destruct.collider_fracture()
    asset.builder_set(&s,wall,pieces)

    // Free blocks: each one a body that breaks where it is hit. The last one starts in the air and breaks on the one below.
    places:=[DESTRUCTION_BLOCKS][3]f32{{-3.2,0.5,0.5},{3.2,0.5,0.8},{3.0,3.4,0.9}}
    names:=[DESTRUCTION_BLOCKS]string{"Block west","Block east","Block falling"}
    for place,at in places {
        block:=asset.builder_entity(&s,names[at],{position=place})
        turn:=core.Transform{place,mm.quat_axis_angle({0,1,0},0.3*f32(at)),{1,1,1}}
        asset.builder_set(&s,block,turn)
        loose:=destruct.destructible(8,false,u64(21+at))
        loose.damage_radius,loose.interior=0.7,game.material_asset("Planks")
        cube(&s,block,"Decking")
        asset.builder_set(&s,block,loose)
        asset.builder_set(&s,block,pieces)
    }

    sun:=render.Sun{color={1,0.97,0.94},illuminance=lux(LAMPLIT,1),disc=disc}
    sun_entity:=asset.builder_entity(&s,"Sun",{position={0,8,0}})
    pose:=sun_pose(to_sun,{0,8,0})
    asset.builder_set(&s,sun_entity,pose)
    asset.builder_set(&s,sun_entity,sun)
    lamp:=render.Point_Light{color={1,0.85,0.7},intensity=candela(LAMPLIT,12),range=14,radius=0.1}
    asset.builder_set(&s,asset.builder_entity(&s,"Lamp",{position={0,3.2,1.5}}),lamp)
    spawn_point(&s,{0,0,4})
    asset.builder_save(&s,path(o,"assets/scenes/destruction.scene"))
}
