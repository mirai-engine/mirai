package main

import "core:fmt"
import "core:os"
import "mirai:asset"
import "mirai:std/base"
import terrain "plugins:terrain/runtime"

DIG_GRASS :: 0
DIG_SOIL :: 1
DIG_ROCK :: 2
DIG_ORE :: 3

// The Volume of the dig scene: grass over soil over rock with pockets of ore,
// with the materials of assets/dig.
write_dig_assets :: proc(o:^Out) {
    os.make_directory_all(path(o,"assets/dig"))
    grass:=asset.content_id(PROJECT,"material","Dig grass")
    soil:=asset.content_id(PROJECT,"material","Dig soil")
    rock:=material_id("Cobblestone")
    ore:=asset.content_id(PROJECT,"material","Dig ore")

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

}
