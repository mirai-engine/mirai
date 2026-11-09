package main

import "core:fmt"
import "mirai:asset"
import render "mirai:engine/render"
import mm "mirai:std/math"

// Toward the sun of the sky scene: low over the west, a while before it sets.
SKY_SCENE_SUN :: [3]f32{0.35, 0.09, -1}

// Mountains of the sky scene: where they stand, metres, how wide at their foot and how high.
@(private)
SKY_SCENE_MOUNTAINS :: [?][4]f32{
    {-1500, -3000, 1800, 600}, {1800, -5200, 3200, 1100}, {-4200, -8500, 5000, 1600},
    {3600, -12500, 6000, 2200}, {-2400, -19000, 8000, 2700}, {6500, -2500, 2400, 500},
    {-7000, 1500, 4000, 900}, {2500, 9500, 5000, 1400}, {-9000, -14000, 7000, 2000},
}

// A plain under the air of an atmosphere (Sky.atmosphere) and a low sun: a
// few things near the eye and mountains from 3 to 20 km, where the air
// lays its haze. How the sky changes over a day shows by turning the sun.
write_sky_scene :: proc(o:^Out) {
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.KIND_SCENE,asset.content_id(PROJECT,"scene","sky"))
    sky:=render.SKY_DEFAULT
    sky.atmosphere,sky.use_background=true,false
    sky_set(&s,&sky)
    sun:=render.Sun{color={1,1,1},illuminance=NOON,disc=true}
    sun_entity:=asset.builder_entity(&s,"Sun",{position={0,10,0}})
    pose:=sun_pose(SKY_SCENE_SUN,{0,10,0})
    asset.builder_set(&s,sun_entity,pose)
    asset.builder_set(&s,sun_entity,sun)
    ground:=asset.builder_entity(&s,"Ground",{position={0,-0.5,0},scale={60000,1,60000}})
    asset.builder_set(&s,ground,render.Mesh_Renderer{shape=.Cube})
    tinted(&s,ground,{0.22,0.26,0.16})
    near:=asset.builder_entity(&s,"Near")
    for i in 0..<5 {
        x:=-6+f32(i)*3
        post:=asset.builder_entity(&s,fmt.tprintf("Post %d",i),{position={x,1,-10-f32(i%2)*4},scale={0.8,2,0.8}},near)
        asset.builder_set(&s,post,render.Mesh_Renderer{shape=.Cube})
        tinted(&s,post,{0.8,0.8,0.8})
    }
    ball:=asset.builder_entity(&s,"Ball",{position={2,0.75,-5},scale={1.5,1.5,1.5}},near)
    asset.builder_set(&s,ball,render.Mesh_Renderer{shape=.Sphere})
    mountains:=asset.builder_entity(&s,"Mountains")
    for m,i in SKY_SCENE_MOUNTAINS {
        mountain:=asset.builder_entity(&s,fmt.tprintf("Mountain %d",i),{position={m[0],m[3]*0.5,m[1]},scale={m[2],m[3],m[2]}},mountains)
        asset.builder_set(&s,mountain,render.Mesh_Renderer{shape=.Cone})
        tinted(&s,mountain,{0.3,0.3,0.27})
    }
    eye:=[3]f32{0,2,8}
    camera:=placed(&s,"Camera",eye,mm.quat_look({0,-0.02,-1},{0,1,0}),{1,1,1})
    asset.builder_set(&s,camera,render.Camera{fov=60*mm.RAD_PER_DEG,near=0.1,active=true})
    feature_scene_end(&s,o,"sky")
}
