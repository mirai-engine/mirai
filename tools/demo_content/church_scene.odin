package main

import "mirai:asset"
import "core:fmt"
import "core:math/linalg"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import fog "plugins:fog/runtime"

// A church full of haze in the morning: a high sun from the north east comes in
// through the stained glass of the east wall and of the apse behind the altar and
// draws shafts of their colors across the nave, toward its door, over the pews and
// the floor; the windows of the west wall glow with the sky. The glass is of jewel
// colors in large panes (scripts/demo_church_glass.py), so that their colors hold
// in the haze and in the light the stone sends back; candles by the altar and two
// lamps over the pews, faint by day, light the haze around them.
CHURCH_DAY :: f32(10)
CHURCH_DARK :: [3]f32{0.4,0.38,0.36}
// The windows of the side walls: 1.6 m wide from 2.5 to 6.5 m up; those of the apse,
// 1.3 m wide from 3 to 8 m up.
CHURCH_SIDE_WINDOWS :: [4]f32{-7.5,-2.5,2.5,7.5}
CHURCH_APSE_WINDOWS :: [3]f32{-2.5,0,2.5}

// With wisps the haze drifts through the shafts by itself (church_fog); church
// keeps it even, for the render check, which takes what changes in a still
// view as noise.
write_church_scene :: proc(o:^Out,meshes:Feature_Meshes,name:string,wisps:bool) {
    s:asset.Scene_Builder
    feature_scene_begin(&s,o,name,.Day,{1,0.86,0.66},CHURCH_DAY,{0.9,1.05,-0.75},daylight(CHURCH_DAY))
    // The nave: 10 m across, 24 m long and 9 m high, inside, of a dark old brick.
    slab(&s,o,"Floor",{0,-0.25,0},{11,0.5,25},"Tiles")
    tinted(&s,slab(&s,o,"Roof",{0,9.25,0},{11,0.5,25},"Planks"),CHURCH_DARK)
    tinted(&s,slab(&s,o,"Wall south",{0,4.5,12.25},{11,9,0.5},"Bricks"),CHURCH_DARK)
    // Each side wall around its four windows: a band under them, one over them and the piers between.
    piers:=[5][2]f32{{-12.5,-8.3},{-6.7,-3.3},{-1.7,1.7},{3.3,6.7},{8.3,12.5}}
    for x,k in ([2]f32{5.25,-5.25}) {
        side:=k==0?"east":"west"
        tinted(&s,slab(&s,o,fmt.tprintf("Wall %s low",side),{x,1.25,0},{0.5,2.5,25},"Bricks"),CHURCH_DARK)
        tinted(&s,slab(&s,o,fmt.tprintf("Wall %s high",side),{x,7.75,0},{0.5,2.5,25},"Bricks"),CHURCH_DARK)
        for pier,i in piers {
            tinted(&s,slab(&s,o,fmt.tprintf("Pier %s %d",side,i+1),{x,4.5,(pier.x+pier.y)*0.5},{0.5,4,pier.y-pier.x},"Bricks"),CHURCH_DARK)
        }
        for z,i in CHURCH_SIDE_WINDOWS {
            stained_window(&s,fmt.tprintf("Window %s %d",side,i+1),{x,4.5,z},{0.03,4,1.6})
        }
    }
    // The apse wall behind the altar, around its three tall windows.
    tinted(&s,slab(&s,o,"Wall north low",{0,1.5,-12.25},{11,3,0.5},"Bricks"),CHURCH_DARK)
    tinted(&s,slab(&s,o,"Wall north high",{0,8.5,-12.25},{11,1,0.5},"Bricks"),CHURCH_DARK)
    apse_piers:=[4][2]f32{{-5.5,-3.15},{-1.85,-0.65},{0.65,1.85},{3.15,5.5}}
    for pier,i in apse_piers {
        tinted(&s,slab(&s,o,fmt.tprintf("Pier north %d",i+1),{(pier.x+pier.y)*0.5,5.5,-12.25},{pier.y-pier.x,5,0.5},"Bricks"),CHURCH_DARK)
    }
    for x,i in CHURCH_APSE_WINDOWS {
        stained_window(&s,fmt.tprintf("Window north %d",i+1),{x,5.5,-12.25},{1.3,5,0.03})
    }
    for x in ([2]f32{-3.2,3.2}) {
        for z,i in ([3]f32{-5,0,5}) {column(&s,meshes,fmt.tprintf("Column %s %d",x<0?"west":"east",i+1),{x,0,z},0.7,9)}
    }
    for row in 0..<10 {
        z:=7.5-f32(row)*1.3
        for x in ([2]f32{-1.7,1.7}) {solid(&s,asset.builder_entity(&s,fmt.tprintf("Pew %d %s",row+1,x<0?"west":"east"),{position={x,0.25,z},scale={2.1,0.5,0.45}}),"Planks")}
    }
    solid(&s,asset.builder_entity(&s,"Step",{position={0,0.1,-9.6},scale={5,0.2,2.4}}),"Marble")
    solid(&s,asset.builder_entity(&s,"Altar",{position={0,0.7,-10},scale={2.6,1,1}}),"Marble")
    for x in ([2]f32{-1.8,1.8}) {
        stand:=asset.builder_entity(&s,x<0?"Candles west":"Candles east",{position={x,0.2,-9.4}})
        shape(&s,asset.builder_entity(&s,"Stand",{position={0,0.6,0},scale={0.08,1.2,0.08}},stand),.Cylinder,"Cast metal")
        flame:=asset.builder_entity(&s,"Flame",{position={0,1.27,0},scale={0.05,0.12,0.05}},stand)
        shape(&s,flame,.Sphere,"Matte paint")
        tinted(&s,flame,{1,0.6,0.25},[3]f32{1,0.6,0.25}*8000)
        point_light(&s,"Light",{0,1.3,0},{1,0.62,0.3},20,9,stand,0.04)
    }
    for z in ([2]f32{5,-1}) {lamp_hanging(&s,fmt.tprintf("Lamp %d",z>0?1:2),{0,6,z})}
    haze:=fog.FOG_VOLUME_DEFAULT
    haze.density,haze.color,haze.anisotropy,haze.falloff,haze.variable=0.025,{0.95,0.95,0.95},0.75,0.05,wisps
    haze_entity:=asset.builder_entity(&s,"Haze",{position={0,4.5,0},scale={10,9,24}})
    asset.builder_set(&s,haze_entity,haze)
    asset.builder_set(&s,haze_entity,volume.box({0.5,0.5,0.5},blend=0.5))
    eye:=[3]f32{0,1.6,11}
    camera:=placed(&s,"Camera",eye,mm.quat_look(linalg.normalize([3]f32{0,3.2,-11}-eye),{0,1,0}),{1,1,1})
    asset.builder_set(&s,camera,render.Camera{fov=60*mm.RAD_PER_DEG,near=0.05,active=true})
    spawn_point(&s,{0,0,10})
    feature_scene_end(&s,o,name)
}

// A pane of the stained glass of the church filling a window.
@(private)
stained_window :: proc(s:^asset.Scene_Builder,name:string,position,size:[3]f32) {
    cube(s,asset.builder_entity(s,name,{position=position,scale=size}),"Stained glass window")
}

// A lamp that hangs from the roof: a chain and a warm globe that lights the haze around it.
@(private)
lamp_hanging :: proc(s:^asset.Scene_Builder,name:string,position:[3]f32) {
    root:=asset.builder_entity(s,name,{position=position})
    shape(s,asset.builder_entity(s,"Chain",{position={0,1.5,0},scale={0.03,3,0.03}},root),.Cylinder,"Cast metal")
    globe:=asset.builder_entity(s,"Globe",{scale={0.35,0.35,0.35}},root)
    shape(s,globe,.Sphere,"Matte paint")
    tinted(s,globe,{1,0.8,0.55},[3]f32{1,0.8,0.55}*3000)
    point_light(s,"Light",{0,0,0},{1,0.8,0.55},400,14,root,0.17)
}
