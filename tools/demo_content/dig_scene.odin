package main

import "core:fmt"
import "core:os"
import "mirai:asset"
import game "mirai:demo/game"
import render "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"
import terrain "plugins:terrain/runtime"
import debris "plugins:terrain_debris/runtime"
import terrain_vfx "plugins:terrain_vfx/runtime"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

DIG_GRASS :: 0
DIG_SOIL :: 1
DIG_ROCK :: 2
DIG_ORE :: 3

// A material of one color for a layer of the dig.
@(private="file")
dig_material :: proc(o:^Out,name:string,color:[3]f32,roughness:f32,metallic:f32=0) -> base.Asset_Id {
    info:=asset.MATERIAL_DEFAULTS
    info.base_color,info.roughness,info.metallic=color,roughness,metallic
    id:=asset.content_id(PROJECT,"material",name)
    asset.content_check(&o.content,name,asset.material_save(path(o,fmt.tprintf("assets/dig/%s.mat",name)),&o.content.types,{id=id,info=info}))
    return id
}

// A prefab of one body: a piece that flies out of the dig, or a drop to pick
// up. Its shape hangs from the body, scaled: a spawn places the root.
@(private="file")
dig_prefab :: proc(o:^Out,name,file:string,shape:render.Shape,material:base.Asset_Id,size:[3]f32,pickup:bool) -> base.Asset_Id {
    id:=asset.content_id(PROJECT,"prefab",file)
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,id)
    defer asset.builder_destroy(&s)
    e:=asset.builder_entity(&s,name)
    body:=phys.RIGID_BODY_DYNAMIC
    asset.builder_set(&s,e,body)
    look:=asset.builder_entity(&s,"Shape",{scale=size},e)
    mesh:=render.Mesh_Renderer{shape=shape}
    mesh.materials[0]=material
    asset.builder_set(&s,look,mesh)
    collider:=shape==.Sphere?phys.collider_sphere(0.5):phys.collider_box({0.5,0.5,0.5})
    asset.builder_set(&s,look,collider)
    if pickup {
        asset.builder_set(&s,e,game.Dig_Pickup{material=material})
        tinted(&s,look,{1,1,1},{2.5,1.4,0.4})
    }
    asset.builder_save(&s,path(o,fmt.tprintf("assets/dig/%s.scene",file)))
    return id
}

// A Volume to dig, standing in the open: grass over soil over rock with
// pockets of ore, the dust each raises and the pieces and drops each leaves
// (plugins terrain, terrain_vfx and terrain_debris), and a site that digs a
// pit by itself at the start of a Play (game/dig_site.odin).
write_dig_scene :: proc(o:^Out) {
    os.make_directory_all(path(o,"assets/dig"))
    grass:=dig_material(o,"Dig grass",{0.2,0.36,0.1},0.9)
    soil:=dig_material(o,"Dig soil",{0.34,0.23,0.14},0.95)
    rock:=material_id("Cobblestone")
    ore:=dig_material(o,"Dig ore",{0.85,0.5,0.22},0.35,0.85)

    // 32 by 16 by 32 m: solid from 7.5 m under the surface, at 0, up to it.
    source:terrain.Source
    defer terrain.source_destroy(&source)
    if !terrain.source_make(&source,.Volume,{65,33,65},0.5,16) {fmt.eprintln("demo_content: the dig terrain could not be made");o.content.failed=true;return}
    layers:=[4]base.Asset_Id{grass,soil,rock,ore}
    for material,i in layers {
        layer:=terrain.LAYER_DEFAULT
        layer.material,layer.tiling=material,i==DIG_ROCK?2:4
        if !terrain.source_layer_set(&source,i,layer) {o.content.failed=true;return}
    }
    source.interior={
        strata_count=3,strata={{layer=DIG_GRASS,depth=0.4},{layer=DIG_SOIL,depth=2.2},{layer=DIG_ROCK,depth=100},{}},
        vein_count=1,veins={{layer=DIG_ORE,shape=.Pocket,scale=1.6,amount=0.45,depth={2.8,100},seed=7},{},{},{}},
        wave=0.5,wave_scale=6,seed=3,
    }
    if !terrain.source_interior_apply(&source) {fmt.eprintln("demo_content: the interior of the dig could not be written");o.content.failed=true;return}
    terrain_id:=asset.content_id(PROJECT,"terrain","dig")
    asset.content_check(&o.content,"dig terrain",terrain.source_save(&source,path(o,"assets/dig/dig.terrain"),terrain_id,&o.content.types))

    dust:=effect.PARTICLE_DEFAULTS
    dust.duration,dust.max_particles,dust.rate=1,4000,0
    dust.shape,dust.shape_size=.Sphere,{0.7,0.4,0.7}
    dust.lifetime,dust.speed,dust.size=[2]f32{1.6,3.2},[2]f32{0.2,1.1},[2]f32{0.2,0.55}
    dust.gravity,dust.drag=0.05,1.4
    dust.colors={{0.85,0.8,0.7,0.6},{0.8,0.76,0.68,0}}
    dust_id:=asset.content_id(PROJECT,"particle","dig_dust")
    asset.content_check(&o.content,"dig dust",effect.particle_save(path(o,"assets/dig/dig_dust.particle"),&o.content.types,{id=dust_id,info=dust}))

    soil_piece:=dig_prefab(o,"Soil piece","dig_soil_piece",.Cube,soil,{0.22,0.16,0.2},false)
    rock_piece:=dig_prefab(o,"Rock piece","dig_rock_piece",.Cube,rock,{0.26,0.2,0.24},false)
    ore_drop:=dig_prefab(o,"Ore","dig_ore_drop",.Sphere,ore,{0.3,0.3,0.3},true)

    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.content_id(PROJECT,"scene","dig"))
    defer asset.builder_destroy(&s)
    u:=daylight(3)
    environment,turn,to_sun,disc:=sky_of(o,.Day,mm.quat_rotate(mm.quat_from_euler({-0.75,0.6,0}),render.SUN_DIRECTION),u,3)
    sky_set(&s,&environment,turn)
    sun:=asset.builder_entity(&s,"Sun")
    pose:=sun_pose(to_sun)
    asset.builder_set(&s,sun,pose)
    asset.builder_set(&s,sun,render.Sun{color={1,0.95,0.86},illuminance=lux(u,3),disc=disc})

    site:=asset.builder_entity(&s,"Dig site")
    asset.builder_set(&s,site,terrain.Terrain{source=terrain_id,solid=true})
    site_dig:=game.DIG_SITE_DEFAULT
    asset.builder_set(&s,site,site_dig)
    raised:=terrain_vfx.TERRAIN_DUST_DEFAULT
    raised.layers[DIG_GRASS].color={0.62,0.66,0.45,1}
    raised.layers[DIG_SOIL].color={0.78,0.62,0.45,1}
    raised.layers[DIG_ROCK].color={0.8,0.8,0.78,1}
    raised.layers[DIG_ORE].color={1,0.72,0.42,1}
    asset.builder_set(&s,site,raised)
    left:=debris.TERRAIN_DEBRIS_DEFAULT
    left.layers={}
    left.layers[DIG_SOIL]={piece=soil_piece,piece_volume=1}
    left.layers[DIG_ROCK]={piece=rock_piece,piece_volume=0.8}
    left.layers[DIG_ORE]={piece=rock_piece,piece_volume=1,drop=ore_drop,drop_volume=0.6}
    asset.builder_set(&s,site,left)

    dust_entity:=asset.builder_entity(&s,"Dig dust")
    asset.builder_set(&s,dust_entity,vfx.Particle_Emitter{particle=dust_id,active=true,loop=true})
    channel:vfx.Particle_Channel
    base.text_set(channel.name[:],terrain_vfx.CHANNEL_DUST)
    asset.builder_set(&s,dust_entity,channel)
    spawn_point(&s,{0,0.2,7})
    asset.builder_save(&s,path(o,"assets/dig/dig.scene"))
}
