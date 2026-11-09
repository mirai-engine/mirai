package foliage

import "core:fmt"
import "core:math"
import "mirai:asset"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// What a content tool gives to write a .foliage and the entity that shows it
// in one pass, with the rest of its scene: its types and the areas whose cells
// its generator fills.

// A type of foliage a tool writes, named as foliage.type_add names its params:
// angles in degrees, the fields left out with the values of FOLIAGE_TYPE_DEFAULT.
Type_Desc :: struct {
    name:string,   // omitted: "Type" and its place in the list
    mesh:base.Asset_Id,
    density:f32,   // per square metre
    scale,height:[2]f32,
    yaw,tilt:Maybe(f32),
    align:Maybe(f32),  // how much it leans with the ground; 0 stands straight up
    offset:[2]f32,
    rule:bool,         // it stands only where slope, ground_height and layers take it
    slope,ground_height:[2]f32,
    layers:bit_set[0..<RULE_LAYERS;u32], // layers of the terrain under it, by their place in the terrain; empty: any
    weight:Maybe(f32),
    fade_distance,cull_distance:Maybe(f32),
    wind:Maybe(f32),   // 0: it does not sway; its vertex colors (their red) weigh the sway
    casts_shadow:bool,
}

Area :: struct {
    at:[3]f32,    // in the space of the entity
    radius:f32,
}

AREA_RADIUS_MAX :: f32(16000) // metres: a square of this half side holds CELLS_MAX cells

Foliage_Desc :: struct {
    file:string,     // the .foliage, relative to where the tool runs: assets/island/plants.foliage
    types:[]Type_Desc,
    generate:[]Area, // the areas its generator fills
    at:[3]f32,       // where its entity stands
}

// Writes the .foliage of a desc and adds its entity to the scene; its id and
// its seed are the same on every run, so the same plants come out. The first
// error is reported as builder_set does.
builder_foliage :: proc(b:^asset.Scene_Builder,name:string,desc:Foliage_Desc) -> base.Entity_Id {
    if b.failed {return 0}
    fail :: proc(b:^asset.Scene_Builder,name,why:string) -> base.Entity_Id {
        asset.builder_fail(b,fmt.tprintf("%s: %s",name,why),.Invalid)
        return 0
    }
    if desc.file=="" {return fail(b,name,"file is required: where the .foliage goes, in a folder of its theme")}
    if len(desc.types)==0 || len(desc.types)>TYPES_MAX {return fail(b,name,fmt.tprintf("types holds from 1 to %d types",TYPES_MAX))}
    id:=asset.content_id(b.content.project,"foliage",desc.file)
    source:Source
    defer source_destroy(&source)
    source.info={seed=u32(id[0]~id[1]),revision=1}
    for type,i in desc.types {
        if type.mesh=={} {return fail(b,name,fmt.tprintf("type %d has no mesh: foliage draws meshes of the assets, not primitives",i))}
        t:=source_type_add(&source,type.name!=""?type.name:fmt.tprintf("Type %d",i+1),type.mesh)
        if type.density!=0 {t.density=type.density}
        if type.scale!={} {t.scale={min(type.scale.x,type.scale.y),max(type.scale.x,type.scale.y)}}
        if type.height!={} {t.height={min(type.height.x,type.height.y),max(type.height.x,type.height.y)}}
        if yaw,set:=type.yaw.?;set {t.yaw=math.to_radians(yaw)}
        if tilt,set:=type.tilt.?;set {t.tilt=math.to_radians(tilt)}
        if align,set:=type.align.?;set {t.align=align}
        if type.offset!={} {t.offset={min(type.offset.x,type.offset.y),max(type.offset.x,type.offset.y)}}
        t.rule.enabled=type.rule
        if type.slope!={} {t.rule.slope={math.to_radians(min(type.slope.x,type.slope.y)),math.to_radians(max(type.slope.x,type.slope.y))}}
        if type.ground_height!={} {t.rule.height={min(type.ground_height.x,type.ground_height.y),max(type.ground_height.x,type.ground_height.y)}}
        t.rule.layers=transmute(u32)type.layers
        if weight,set:=type.weight.?;set {t.rule.weight=weight}
        if fade,set:=type.fade_distance.?;set {t.fade_distance=fade}
        if cull,set:=type.cull_distance.?;set {t.cull_distance=cull}
        if wind,set:=type.wind.?;set {t.wind=wind}
        t.casts_shadow=type.casts_shadow
    }
    if !source_valid(&source) {return fail(b,name,"a type is out of range: densities and distances at least 0, slopes from 0 to 90 degrees, align and weight from 0 to 1")}
    for area in desc.generate {
        for v in area.at {if !(abs(v)<=POSITION_MAX) {return fail(b,name,fmt.tprintf("an area to generate is at %v, past the limit of %v",area.at,POSITION_MAX))}}
        if !(area.radius>0) || area.radius>AREA_RADIUS_MAX {return fail(b,name,fmt.tprintf("the radius of an area to generate is above 0 and at most %v",AREA_RADIUS_MAX))}
        source_generate_area(&source,area.at,area.radius,true)
    }
    bytes,error:=source_bytes(&source,id,&b.content.types)
    if error!=.None {
        asset.builder_fail(b,fmt.tprintf("%s: %s",name,desc.file),error)
        return 0
    }
    defer delete(bytes)
    asset.content_folder(desc.file)
    if serial.file_write_atomic(desc.file,bytes)!=.None {
        asset.builder_fail(b,fmt.tprintf("%s: %s",name,desc.file),.IO)
        return 0
    }
    fmt.printfln("wrote %s",desc.file)
    e:=asset.builder_entity(b,name,mm.Transform{position=desc.at})
    if e==0 {return 0}
    asset.builder_set(b,e,Foliage{source=id,revision=1})
    return e
}
