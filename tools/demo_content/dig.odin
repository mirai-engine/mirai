package main

import "core:fmt"
import "core:os"
import "mirai:asset"
import "mirai:std/base"
import terrain "plugins:terrain/runtime"
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

// The Volume of the dig scene: grass over soil over rock with pockets of ore,
// their materials and the dust a dig raises (Terrain_Dust).
write_dig_assets :: proc(o:^Out) {
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
}
