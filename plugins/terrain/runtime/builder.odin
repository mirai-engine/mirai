package terrain

import "core:fmt"
import "core:math"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"

// What a content tool gives to write a Heightfield terrain and the entity that
// shows it in one pass, with the rest of its scene: the heights by a proc or
// by rows, and its layers by material.

// A layer of a terrain a tool writes. Zero fields take those of LAYER_DEFAULT;
// slope and softness[0] are in degrees and height in metres.
Layer_Desc :: struct {
    material:base.Asset_Id,
    tiling:f32,
    automatic:bool,   // it covers where slope and height are in their ranges
    slope:[2]f32,     // from the horizontal; zero: any
    height:[2]f32,    // of the terrain; zero: any
    softness:[2]f32,  // degrees and metres past the ranges over which it fades out
}

// A Heightfield of samples*samples heights, spacing metres apart, centered on
// its entity. Give height or heights; neither: flat.
Terrain_Desc :: struct {
    file:string,                // the .terrain, relative to where the tool runs: assets/island/ground.terrain
    samples:int,
    spacing:f32,                // 0: 1
    chunk_cells:int,            // 0: 32
    height:proc(x,z:f32) -> f32, // metres at a point of the terrain, of x and z from its center
    heights:[]f32,              // or samples*samples values, row of z by row, x along each
    layers:[]Layer_Desc,        // the first covers everything; none: one without a material
    at:[3]f32,                  // where its entity stands
}

// Writes the .terrain of a desc and adds its entity to the scene; its id is
// the same on every run. The first error is reported as builder_set does.
builder_terrain :: proc(b:^asset.Scene_Builder,name:string,desc:Terrain_Desc) -> base.Entity_Id {
    if b.failed {return 0}
    fail :: proc(b:^asset.Scene_Builder,name,why:string) -> base.Entity_Id {
        asset.builder_fail(b,fmt.tprintf("%s: %s",name,why),.Invalid)
        return 0
    }
    if desc.file=="" {return fail(b,name,"file is required: where the .terrain goes, in a folder of its theme")}
    samples,spacing,chunk:=desc.samples,desc.spacing,desc.chunk_cells
    if spacing==0 {spacing=1}
    if chunk==0 {chunk=32}
    if samples<3 || samples>HEIGHT_SAMPLES_MAX {return fail(b,name,fmt.tprintf("samples is from 3 to %d",HEIGHT_SAMPLES_MAX))}
    if desc.heights!=nil && len(desc.heights)!=samples*samples {return fail(b,name,fmt.tprintf("heights has samples*samples values, %d, and has %d",samples*samples,len(desc.heights)))}
    if len(desc.layers)>LAYERS_MAX {return fail(b,name,fmt.tprintf("layers holds up to %d",LAYERS_MAX))}
    source:Source
    defer source_destroy(&source)
    if !source_make(&source,.Heightfield,{samples,1,samples},spacing,chunk) {return fail(b,name,"spacing and chunk_cells are out of their ranges, or there is no memory")}
    if !grid_prepare(&source.heights,{0,0,0},{samples-1,0,samples-1},source.allocator) {return fail(b,name,"there is no memory for its heights")}
    origin:=source_origin(&source)
    for z in 0..<samples {for x in 0..<samples {
        h:f32
        switch {
        case desc.heights!=nil: h=desc.heights[z*samples+x]
        case desc.height!=nil:  h=desc.height(origin.x+f32(x)*spacing,origin.z+f32(z)*spacing)
        }
        if !(abs(h)<=HEIGHT_LIMIT) {return fail(b,name,fmt.tprintf("the height at sample %d,%d is %v, past the limit of %v",x,z,h,HEIGHT_LIMIT))}
        grid_set(&source.heights,x,z,h)
    }}
    for layer,i in desc.layers {
        made:=LAYER_DEFAULT
        made.material=layer.material
        if layer.tiling!=0 {made.tiling=layer.tiling}
        made.auto.enabled=layer.automatic
        if layer.slope!={} {made.auto.slope={math.to_radians(min(layer.slope.x,layer.slope.y)),math.to_radians(max(layer.slope.x,layer.slope.y))}}
        if layer.height!={} {made.auto.height={min(layer.height.x,layer.height.y),max(layer.height.x,layer.height.y)}}
        if layer.softness!={} {made.auto.softness={math.to_radians(layer.softness.x),layer.softness.y}}
        if !source_layer_set(&source,i,made) {return fail(b,name,fmt.tprintf("layer %d is out of range: tiling above 0, slope from 0 to 90 degrees",i))}
    }
    source.revision=1
    id:=asset.content_id(b.content.project,"terrain",desc.file)
    asset.content_folder(desc.file)
    if error:=source_save(&source,desc.file,id,&b.content.types);error!=.None {
        asset.builder_fail(b,fmt.tprintf("%s: %s",name,desc.file),error)
        return 0
    }
    fmt.printfln("wrote %s",desc.file)
    e:=asset.builder_entity(b,name,mm.Transform{position=desc.at})
    if e==0 {return 0}
    asset.builder_set(b,e,Terrain{source=id,revision=1,solid=true})
    return e
}
