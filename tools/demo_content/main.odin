package main

import "core:fmt"
import "core:math"
import "core:os"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import game "mirai:demo/game"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

// Writes the assets of the demo project that code computes: the imports of
// demo/source (sources.odin), the images, clips, meshes, sounds, particles,
// fractures, profiles and tables of game data its scenes use, with the same
// bytes on every run. Its scenes, prefabs and interfaces are
// authored assets, as are the materials of demo/assets/surfaces: scene.write or
// the editor change them, and this names those it uses by their ids.
//
//   mirai content demo [-- --physics-only|--control-only|--raft-only|--features-only|
//                          --animation-only|--interface-only|--dig-only|--ai-only]

PROJECT :: "demo_content"
BADGE_SIZE :: 64
PANEL_SIZE :: 32
HUM_RATE :: 22050
HUM_SECONDS :: 2

Out :: struct {
    root:string,
    content:asset.Content,
}

@(private)
path :: proc(o:^Out,relative:string) -> string {return fmt.tprintf("%s/demo/%s",o.root,relative)}

// Writes a mesh of one level of a source and its indices (asset.mesh_build)
// to file, a path relative to the demo.
@(private)
mesh_write_built :: proc(o:^Out,what,file:string,desc:asset.Mesh_Desc,source:asset.Mesh_Source,indices:[]u32) {
    desc:=desc
    if !asset.mesh_build(source,indices,nil,&desc.geometry,context.temp_allocator) {asset.content_check(&o.content,what,.Invalid);return}
    asset.content_check(&o.content,what,asset.mesh_save(path(o,file),&o.content.types,desc))
}

// How much of a pixel a disc of a radius covers, from the distance of its center.
@(private)
coverage :: proc(distance,radius:f32) -> f32 {return clamp(radius-distance+0.5,0,1)}

// An orange disc with a white core, transparent around it: the badge hud.ui shows.
write_badge :: proc(o:^Out) {
    id:=asset.content_id(PROJECT,"texture","hud_badge")
    pixels:=make([]u8,BADGE_SIZE*BADGE_SIZE*4,context.temp_allocator)
    for y in 0..<BADGE_SIZE {
        for x in 0..<BADGE_SIZE {
            distance:=math.sqrt(math.pow(f32(x)+0.5-BADGE_SIZE/2,2)+math.pow(f32(y)+0.5-BADGE_SIZE/2,2))
            core:=coverage(distance,12)
            color:=[3]f32{255,170,40}*(1-core)+[3]f32{255,255,255}*core
            at:=(y*BADGE_SIZE+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=u8(color.r),u8(color.g),u8(color.b)
            pixels[at+3]=u8(255*coverage(distance,30))
        }
    }
    asset.content_check(&o.content,"assets/showcase/hud_badge.tex",asset.texture_save(path(o,"assets/showcase/hud_badge.tex"),&o.content.types,
        {id=id,width=BADGE_SIZE,height=BADGE_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

// A dark rounded panel with a light border: the nine slice of the HUD.
write_panel :: proc(o:^Out) {
    id:=asset.content_id(PROJECT,"texture","hud_panel")
    pixels:=make([]u8,PANEL_SIZE*PANEL_SIZE*4,context.temp_allocator)
    RADIUS :: f32(8)
    for y in 0..<PANEL_SIZE {
        for x in 0..<PANEL_SIZE {
            // Distance to a rounded rectangle that fills the image.
            px,py:=abs(f32(x)+0.5-PANEL_SIZE/2)-(PANEL_SIZE/2-RADIUS),abs(f32(y)+0.5-PANEL_SIZE/2)-(PANEL_SIZE/2-RADIUS)
            distance:=math.sqrt(math.pow(max(px,0),2)+math.pow(max(py,0),2))+min(max(px,py),0)
            border:=1-coverage(distance,RADIUS-2)
            color:=[3]f32{18,24,38}*(1-border)+[3]f32{96,118,160}*border
            at:=(y*PANEL_SIZE+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=u8(color.r),u8(color.g),u8(color.b)
            pixels[at+3]=u8(235*coverage(distance,RADIUS))
        }
    }
    asset.content_check(&o.content,"assets/showcase/hud_panel.tex",asset.texture_save(path(o,"assets/showcase/hud_panel.tex"),&o.content.types,
        {id=id,width=PANEL_SIZE,height=PANEL_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

// The lift: its platform goes up and comes down in four seconds while its
// beacon turns once. "top" marks the highest point.
write_lift :: proc(o:^Out) {
    id:=asset.content_id(PROJECT,"animation","lift")
    seconds:=game.SHOWCASE_RIDE_SECONDS
    rise:=[]lib.Keyframe{
        {time=0,value={0,0.1,0,0}},
        {time=seconds/2,value={0,1.9,0,0},ease=.Sine_In_Out},
        {time=seconds,value={0,0.1,0,0},ease=.Sine_In_Out},
    }
    turn:=make([]lib.Keyframe,5,context.temp_allocator)
    for &key,i in turn {
        key={time=seconds*f32(i)/4,value=lib.quat_vec4(mm.quat_axis_angle({0,1,0},f32(i)*math.PI/2))}
    }
    clips:=[]asset.Animation_Clip_Desc{
        {name="ride",tracks={{target="Platform",property=.Position,keys=rise},{target="Beacon",property=.Rotation,keys=turn}},markers={{time=seconds/2,name="top"}}},
        {name="parked",tracks={{target="Platform",property=.Position,keys=rise[:1]}}},
    }
    asset.content_check(&o.content,"assets/showcase/lift.anim",asset.animation_save(path(o,"assets/showcase/lift.anim"),&o.content.types,{id=id,clips=clips}))
}

// Two seconds of a low hum that loops without a click: every partial fits a
// whole number of times. The WAV is the source; the .sound is its import.
write_hum :: proc(o:^Out) {
    FRAMES :: HUM_RATE*HUM_SECONDS
    file:=make([]u8,44+FRAMES*2,context.temp_allocator)
    le :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");le(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    le(file,16,16,4);le(file,20,1,2);le(file,22,1,2);le(file,24,HUM_RATE,4);le(file,28,HUM_RATE*2,4);le(file,32,2,2);le(file,34,16,2)
    copy(file[36:],"data");le(file,40,FRAMES*2,4)
    for frame in 0..<FRAMES {
        t:=f64(frame)/HUM_RATE
        wave:=0.5*math.sin(2*math.PI*110*t)+0.25*math.sin(2*math.PI*220*t)+0.12*math.sin(2*math.PI*331*t)
        tremolo:=0.75+0.25*math.sin(2*math.PI*1.5*t)
        le(file,44+frame*2,u32(u16(i16(wave*tremolo*20000))),2)
    }
    source:=path(o,"source/sounds/hum.wav")
    os.make_directory_all(path(o,"source/sounds"))
    // Written only when it differs, so that the import of an unchanged source is the same file.
    existing,read_error:=os.read_entire_file(source,context.temp_allocator)
    if (read_error!=nil || string(existing)!=string(file)) && os.write_entire_file(source,file)!=nil {
        fmt.eprintfln("demo_content: %s could not be written",source)
        o.content.failed=true
        return
    }
    report,error:=sources.import_source(source,path(o,"assets/showcase"),{root=fmt.tprintf("%s/demo",o.root)})
    if error.code!=.None {
        fmt.eprintfln("demo_content: %s",error.message)
        o.content.failed=true
        return
    }
    defer importer.report_destroy(&report)
    fmt.printfln("wrote source/sounds/hum.wav and imported %s",report.assets[0].path)
}

// The id the import of source/materials/<name>.json gives the material <name>.mat.
material_id :: proc(name:string) -> base.Asset_Id {
    buffer:[192]u8
    return base.asset_id_named(fmt.bprintf(buffer[:],"material\x1fsource/materials/%s.json\x1f%s",name,name))
}

main :: proc() {
    o:Out
    o.root=len(os.args)>1?os.args[1]:"."
    asset.content_init(&o.content,PROJECT)
    defer asset.content_destroy(&o.content)
    switch len(os.args)>2?os.args[2]:"" {
    case "":
        import_sources(&o)
        write_badge(&o)
        write_panel(&o)
        write_lift(&o)
        write_hum(&o)
        write_control_intro(&o)
        write_physics_gallery(&o)
        write_horde_records(&o)
        write_arena_agent(&o)
        if !o.content.failed {write_animation_assets(&o)}
        write_feature_meshes(&o)
        write_decal_images(&o)
        write_raft_particles(&o)
        write_dig_assets(&o)
        write_interface_assets(&o)
    case "--physics-only":   write_physics_gallery(&o)
    case "--control-only":   write_control_intro(&o)
    case "--raft-only":      write_raft_particles(&o)
    case "--features-only":  write_feature_meshes(&o);write_decal_images(&o)
    case "--animation-only": import_model(&o,"mirai/mirai.glb");if !o.content.failed {write_animation_assets(&o)}
    case "--interface-only": write_interface_assets(&o)
    case "--dig-only":       write_dig_assets(&o)
    case "--ai-only":        write_horde_records(&o);write_arena_agent(&o)
    case:
        fmt.eprintfln("demo_content: unknown option %s",os.args[2])
        o.content.failed=true
    }
    free_all(context.temp_allocator)
    if o.content.failed {os.exit(1)}
}
