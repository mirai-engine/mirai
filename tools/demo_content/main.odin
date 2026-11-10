package main

import "core:fmt"
import "core:math"
import "core:os"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:core"
import game "mirai:demo/game"
import anim "plugins:animation/runtime"
import audio "mirai:engine/audio"
import spawn "plugins:spawn/runtime"
import gui "mirai:engine/gui"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// Writes every generated asset of the demo project: the imports of
// demo/source (sources.odin) and the showcase, which is the scene
// demo/assets/showcase/showcase.scene and the assets it uses: the two images
// (.tex) of its HUD, the clips of a lift (.anim) and the hum of a speaker
// (.sound, imported from a WAV this also writes). Running it again gives the
// same bytes. The other scenes and prefabs, the materials of
// demo/assets/surfaces and the interfaces are authored: this names a .ui by
// its id and never writes one.
//
//   odin run tools/demo_content -collection:mirai=. -collection:plugins=plugins -ignore-unknown-attributes -- [root of the repository]

PROJECT :: "demo_content"
BADGE_SIZE :: 64
PANEL_SIZE :: 32
HUM_RATE :: 22050
HUM_SECONDS :: 2

Out :: struct {
    root:string,
    content:asset.Content,
    actions:[]serial.Choice, // the actions of the demo with their numbers, which types.schema names
    slabs:map[string]base.Asset_Id, // the meshes of slab(), by their file
}

@(private)
path :: proc(o:^Out,relative:string) -> string {return fmt.tprintf("%s/demo/%s",o.root,relative)}

// The id of a .ui of the demo, which its file keeps.
@(private)
ui_id :: proc(name:string) -> base.Asset_Id {return asset.content_id(PROJECT,"ui",name)}

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
write_lift :: proc(o:^Out) -> base.Asset_Id {
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
    return id
}

// Two seconds of a low hum that loops without a click: every partial fits a
// whole number of times. The WAV is the source; the .sound is its import.
write_hum :: proc(o:^Out) -> base.Asset_Id {
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
        return {}
    }
    report,error:=sources.import_source(source,path(o,"assets/showcase"),{root=fmt.tprintf("%s/demo",o.root)})
    if error.code!=.None {
        fmt.eprintfln("demo_content: %s",error.message)
        o.content.failed=true
        return {}
    }
    defer importer.report_destroy(&report)
    fmt.printfln("wrote source/sounds/hum.wav and imported %s",report.assets[0].path)
    return report.assets[0].id
}

EYE_HEIGHT :: f32(1.6)


// Turns a component of an entity off by itself: the world loads it off.
@(private)
turn_off :: proc(s:^asset.Scene_Builder,id:base.Entity_Id,name:string) {
    if asset.scene_component_turn(&s.scene,id,base.name_hash(name),true)!=.None {s.failed=true}
}
@(private)
// The sky turned about the vertical by turn, and how the views of the scene
// expose: a View_Volume of the whole scene when it is not the default.
sky_set :: proc(s:^asset.Scene_Builder,sky:^render.Sky,turn:f32=0,exposure:=render.EXPOSURE_DEFAULT) {
    e:=asset.builder_entity(s,"Sky")
    placed:=core.Transform{{},mm.quat_axis_angle({0,1,0},turn),{1,1,1}}
    asset.builder_set(s,e,placed)
    asset.builder_set(s,e,sky^)
    if exposure==render.EXPOSURE_DEFAULT {return}
    look:=render.View_Volume{exposure=exposure,tint={1,1,1}}
    asset.builder_set(s,asset.builder_entity(s,"Exposure"),look)
}
// The id the import of source/materials/<name>.json gives the material <name>.mat.
material_id :: proc(name:string) -> base.Asset_Id {
    buffer:[192]u8
    return base.asset_id_named(fmt.bprintf(buffer[:],"material\x1fsource/materials/%s.json\x1f%s",name,name))
}

@(private)
cube :: proc(s:^asset.Scene_Builder,id:base.Entity_Id,material:string) {
    mesh:=render.Mesh_Renderer{shape=.Cube}
    mesh.materials[0]=material_id(material)
    asset.builder_set(s,id,mesh)
}

// A cube that the player stands on and walks into.
@(private)
solid :: proc(s:^asset.Scene_Builder,id:base.Entity_Id,material:string) {
    cube(s,id,material)
    collider:=phys.collider_box({0.5,0.5,0.5})
    asset.builder_set(s,id,collider)
}

// Where a player appears.
@(private)
spawn_point :: proc(s:^asset.Scene_Builder,position:[3]f32) {
    point:=spawn.Spawn_Point{prefab=PLAYER_PREFAB_ID}
    asset.builder_set(s,placed(s,"Player start",position,1,{1,1,1}),point)
}

write_scene :: proc(o:^Out,hud,sign,lift,hum:base.Asset_Id) {
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.content_id(PROJECT,"scene","showcase"))
    defer asset.builder_destroy(&s)

    environment,turn,to_sun,disc:=sky_of(o,.Day,render.SUN_DIRECTION,LAMPLIT,1.6)
    // Its view is mostly sky: a stop under the meter keeps it as the demo has it.
    exposure:=render.EXPOSURE_DEFAULT
    exposure.compensation=-1
    sky_set(&s,&environment,turn,exposure)
    sun:=render.Sun{color={1,0.96,0.9},illuminance=lux(LAMPLIT,1.6),disc=disc}
    sun_entity:=asset.builder_entity(&s,"Sun",{position={0,6,0}})
    pose:=sun_pose(to_sun,{0,6,0})
    asset.builder_set(&s,sun_entity,pose)
    asset.builder_set(&s,sun_entity,sun)
    lamp:=render.Point_Light{color={1,0.8,0.6},intensity=candela(LAMPLIT,12),range=14,radius=0.1}
    asset.builder_set(&s,asset.builder_entity(&s,"Lamp",{position={2.5,3.5,2.5}}),lamp)
    solid(&s,asset.builder_entity(&s,"Floor",{position={0,-0.05,0},scale={14,0.1,14}}),"Tiles")
    solid(&s,asset.builder_entity(&s,"Pillar west",{position={-3,1.5,-1},scale={0.5,3,0.5}}),"Marble")
    solid(&s,asset.builder_entity(&s,"Pillar east",{position={3,1.5,-1},scale={0.5,3,0.5}}),"Marble")
    spawn_point(&s,{0,0,5.5})

    // The Animation of the lift moves Platform and turns Beacon, found by name below it.
    root:=asset.builder_entity(&s,game.SHOWCASE_LIFT)
    playing:=anim.ANIMATION_DEFAULT
    playing.asset=lift
    base.text_set(playing.clip[:],"ride")
    asset.builder_set(&s,root,playing)
    platform:=asset.builder_entity(&s,"Platform",{position={0,0.1,0}},root)
    cube(&s,asset.builder_entity(&s,"Deck",{scale={2,0.2,2}},platform),"Brushed steel")
    beacon:=asset.builder_entity(&s,"Beacon",{position={0,0.45,0},scale={0.45,0.45,0.45}},platform)
    cube(&s,beacon,"Neon sign")
    shown:=game.Showcase{}
    base.text_set(shown.label[:],"Lift")
    board:=asset.builder_entity(&s,"Sign",{position={0,1.0,0}},platform)
    widget:=gui.WORLD_WIDGET_DEFAULT
    widget.asset,widget.size,widget.scale,widget.facing,widget.pivot=sign,{220,100},0.01,.Billboard_Upright,.Bottom_Center
    asset.builder_set(&s,board,widget)
    asset.builder_set(&s,board,shown)

    screen:=gui.UI_Screen{asset=hud}
    overlay:=asset.builder_entity(&s,"Hud")
    asset.builder_set(&s,overlay,screen)
    asset.builder_set(&s,overlay,shown)

    speaker:=asset.builder_entity(&s,"Speaker",{position={-3,0.35,1.5},scale={0.7,0.7,0.7}})
    cube(&s,speaker,"Lacquer")
    source:=audio.AUDIO_SOURCE_DEFAULT
    source.sound,source.loop,source.spatial,source.volume,source.max_distance=hum,true,true,0.7,25
    asset.builder_set(&s,speaker,source)

    asset.builder_save(&s,path(o,"assets/showcase/showcase.scene"))
}

@(private)
AREAS :: [?]string{
    "ai","animation_gallery/rig_playground","blockout","characters/jelly","characters/mirai","characters/player","characters/robot",
    "characters/spider","characters/tall_mirai","church","control","decals","deform","destruction","dig","gallery","horror","interface",
    "lights","monitors","ocean","physics_gallery/ragdoll","portals","raft","showcase","sky","surfaces/bricks","surfaces/cobblestone",
    "surfaces/glass","surfaces/marble","surfaces/metal","surfaces/neon","surfaces/paint","surfaces/tiles","surfaces/water","surfaces/wood",
    "vfx_gallery",
}

main :: proc() {
    o:Out
    o.root=len(os.args)>1?os.args[1]:"."
    asset.content_init(&o.content,PROJECT)
    defer asset.content_destroy(&o.content)
    actions_load(&o)
    if o.content.failed {os.exit(1)}
    for folder in AREAS {os.make_directory_all(path(&o,fmt.tprintf("assets/%s",folder)))}
    if len(os.args)>2 && os.args[2]=="--physics-only" {
        write_destruction_scene(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--prefabs-only" {
        write_prefabs(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--control-only" {
        write_control_scene(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--portal-only" {
        write_portal_player(&o)
        if !o.content.failed {write_portal_chamber_scene(&o)}
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--raft-only" {
        write_raft_player(&o)
        if !o.content.failed {write_raft_scene(&o)}
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--features-only" {
        write_feature_scenes(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--church-only" {
        meshes:=write_feature_meshes(&o)
        if !o.content.failed {write_church_scene(&o,meshes,"church",false)}
        if !o.content.failed {write_church_scene(&o,meshes,"church_fog",true)}
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--lights-only" {
        write_lights_scene(&o)
        if !o.content.failed {write_night_scene(&o)}
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--animation-only" {
        import_model(&o,"mirai/mirai.glb")
        if !o.content.failed {write_animation_scene(&o)}
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--sky-only" {
        write_sky_scene(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--interface-only" {
        write_interface_scene(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--dig-only" {
        write_dig_scene(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--horror-only" {
        write_horror_scene(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--ai-only" {
        write_ai_scene(&o)
        if o.content.failed {os.exit(1)}
        return
    }
    import_sources(&o)
    write_badge(&o)
    write_panel(&o)
    lift,hum:=write_lift(&o),write_hum(&o)
    write_prefabs(&o)
    if !o.content.failed {write_scene(&o,ui_id("hud"),ui_id("sign"),lift,hum)}
    if !o.content.failed {write_control_scene(&o)}
    if !o.content.failed {write_destruction_scene(&o)}
    if !o.content.failed {write_ai_scene(&o)}
    if !o.content.failed {write_animation_scene(&o)}
    if !o.content.failed {write_feature_scenes(&o)}
    if !o.content.failed {write_portal_player(&o)}
    if !o.content.failed {write_portal_chamber_scene(&o)}
    if !o.content.failed {write_raft_player(&o)}
    if !o.content.failed {write_raft_scene(&o)}
    if !o.content.failed {write_lights_scene(&o)}
    if !o.content.failed {write_night_scene(&o)}
    if !o.content.failed {write_horror_scene(&o)}
    if !o.content.failed {write_dig_scene(&o)}
    if !o.content.failed {write_interface_scene(&o)}
    if !o.content.failed {write_sky_scene(&o)}
    free_all(context.temp_allocator)
    if o.content.failed {os.exit(1)}
}
