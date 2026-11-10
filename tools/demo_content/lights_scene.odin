package main

import "core:fmt"
import "mirai:asset"
import game "mirai:demo/game"
import render "mirai:engine/render"
import mm "mirai:std/math"

LIGHTS_SCENE_LIGHTS :: 1024
// What a light gives when there are 256, candela: with any other number, all of them together give the same.
LIGHTS_SCENE_INTENSITY :: 16*LAMP

// A floor, 48 posts and 1024 point lights over them, with no sky and no sun:
// what direct light costs with many lights. The lights are in the order in
// which the first 4, 16, 64 or 256 of them are spread evenly over the floor.
write_lights_scene :: proc(o:^Out) {
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.content_id(PROJECT,"scene","lights"))
    floor:=asset.builder_entity(&s,"Receiver",{position={0,-0.15,0},scale={24,0.3,20}})
    asset.builder_set(&s,floor,render.Mesh_Renderer{shape=.Cube})
    tinted(&s,floor,{0.4,0.4,0.4})
    posts:=asset.builder_entity(&s,"Occluders")
    for i in 0..<48 {
        post:=asset.builder_entity(&s,fmt.tprintf("Occluder %d",i),{position={-9+f32(i%8)*2.5,0.7,-7+f32(i/8)*2.5},scale={0.8,1.4,0.8}},posts)
        asset.builder_set(&s,post,render.Mesh_Renderer{shape=.Cube})
    }
    lights:=asset.builder_entity(&s,"Lights")
    for i in 0..<LIGHTS_SCENE_LIGHTS {
        x,z:u32
        for bit in 0..<uint(5) {
            x|=((u32(i)>>(2*bit))&1)<<(4-bit)
            z|=((u32(i)>>(2*bit+1))&1)<<(4-bit)
        }
        position:=[3]f32{-9+18*(f32(x)+0.5)/32,3.5,-8+16*(f32(z)+0.5)/32}
        point_light(&s,fmt.tprintf("Budget light %d",i),position,{1,0.7,0.4},LIGHTS_SCENE_INTENSITY*256/f32(LIGHTS_SCENE_LIGHTS),8,lights)
    }
    eye:=[3]f32{16,12,18}
    camera:=placed(&s,"Camera",eye,mm.quat_look(-eye,{0,1,0}),{1,1,1})
    asset.builder_set(&s,camera,render.Camera{fov=50*mm.RAD_PER_DEG,near=0.1,active=true})
    feature_scene_end(&s,o,"lights")
}
