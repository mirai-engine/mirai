package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:core"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import multiplayer "plugins:multiplayer/runtime"
import cam "mirai:engine/camera"
import spawn "plugins:spawn/runtime"
import destruct "plugins:destruct/runtime"
import gui "mirai:engine/gui"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "mirai:std/base"
import game "project:game"

PLAYER_PREFAB_ID :: base.Asset_Id{0x6d6972616967616d,0x706c617965720001} // the id main.scene names the player prefab by

// Writes the assets the .ui do not name by their documents: a badge (.tex), a
// hum (.sound, imported from the WAV this writes into source/) and the scene
// assets/scenes/main.scene that uses the .ui of assets/ui. The .ui are the
// source: an agent changes them with ui.write and the visual editor edits the
// same files, so running this again leaves them alone. mirai content runs it.

PROJECT :: "game_content"
BADGE_SIZE :: 64
HUM_RATE :: 22050
HUM_SECONDS :: 2

// An orange disc with a white core, transparent around it.
write_badge :: proc(c:^asset.Content) {
    id:=asset.content_id(PROJECT,"texture","badge")
    pixels:=make([]u8,BADGE_SIZE*BADGE_SIZE*4,context.temp_allocator)
    coverage :: proc(distance,radius:f32) -> f32 {return clamp(radius-distance+0.5,0,1)}
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
    asset.content_check(c,"assets/textures/badge.tex",asset.texture_save("assets/textures/badge.tex",&c.types,
        {id=id,width=BADGE_SIZE,height=BADGE_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
}

// Two seconds of a low hum that loops without a click: every partial fits a
// whole number of times. The WAV is the source; the .sound is its import.
write_hum :: proc(c:^asset.Content) -> base.Asset_Id {
    FRAMES :: HUM_RATE*HUM_SECONDS
    file:=make([]u8,44+FRAMES*2,context.temp_allocator)
    le :: proc(file:[]u8,at:int,value:u32,size:int) {for i in 0..<size {file[at+i]=u8(value>>uint(8*i))}}
    copy(file,"RIFF");le(file,4,u32(len(file)-8),4);copy(file[8:],"WAVEfmt ")
    le(file,16,16,4);le(file,20,1,2);le(file,22,1,2);le(file,24,HUM_RATE,4);le(file,28,HUM_RATE*2,4);le(file,32,2,2);le(file,34,16,2)
    copy(file[36:],"data");le(file,40,FRAMES*2,4)
    for frame in 0..<FRAMES {
        t:=f64(frame)/HUM_RATE
        wave:=0.5*math.sin(2*math.PI*110*t)+0.25*math.sin(2*math.PI*220*t)+0.12*math.sin(2*math.PI*330*t)
        tremolo:=0.75+0.25*math.sin(2*math.PI*1.5*t)
        le(file,44+frame*2,u32(u16(i16(wave*tremolo*20000))),2)
    }
    os.make_directory_all("source/sounds")
    // Written only when it differs, so that the import of an unchanged source is the same file.
    existing,read_error:=os.read_entire_file("source/sounds/hum.wav",context.temp_allocator)
    if (read_error!=nil || string(existing)!=string(file)) && os.write_entire_file("source/sounds/hum.wav",file)!=nil {
        fmt.eprintln("content: source/sounds/hum.wav could not be written")
        c.failed=true
        return {}
    }
    report,error:=importer.import_sound("source/sounds/hum.wav","assets/sounds",{},{root="."})
    if error.code!=.None {
        fmt.eprintfln("content: %s",error.message)
        c.failed=true
        return {}
    }
    defer importer.report_destroy(&report)
    fmt.printfln("imported %s",report.assets[0].path)
    return report.assets[0].id
}

EYE_HEIGHT :: f32(1.6)

// A tinted cube.
@(private)
block :: proc(b:^asset.Scene_Builder,id:base.Entity_Id,color:[3]f32) {
    asset.builder_set(b,id,render.Mesh_Renderer{shape=.Cube})
    asset.builder_set(b,id,render.Tint{color={color.r,color.g,color.b,1}})
}

// The body of a player: a character its seat walks, with a camera
// at its eyes that looks where it looks.
write_player :: proc(c:^asset.Content) {
    b:asset.Scene_Builder
    asset.builder_init(&b,c,asset.KIND_PREFAB,PLAYER_PREFAB_ID)
    defer asset.builder_destroy(&b)
    root:=asset.builder_entity(&b,"Player")
    asset.builder_set(&b,root,phys.character_default())
    asset.builder_set(&b,root,game.player_walk())
    asset.builder_set(&b,root,phys.collider_character())
    asset.builder_set(&b,root,game.Player{})
    asset.builder_set(&b,root,multiplayer.Replicate{priority=1,radius=1})
    eyes:=asset.builder_entity(&b,"Player view",{position={0,EYE_HEIGHT,0}},root)
    asset.builder_set(&b,eyes,render.Camera{fov=game.VIEW_FOV,near=0.05,active=true})
    asset.builder_set(&b,eyes,audio.Audio_Listener{})
    asset.builder_set(&b,eyes,cam.Camera_Follow{mode=.Eyes,offset={0,EYE_HEIGHT,0}})
    asset.builder_set(&b,root,inp.Drivable{camera=core.Entity(eyes)})
    asset.builder_save(&b,"assets/prefabs/Player.prefab")
}

write_scene :: proc(c:^asset.Content,hud,sign,hum,shell:base.Asset_Id) {
    b:asset.Scene_Builder
    asset.builder_init(&b,c,asset.KIND_SCENE,asset.content_id(PROJECT,"scene","main"))
    defer asset.builder_destroy(&b)

    // The air lit by the Sun below, and the exposure the meter gives: a clear day.
    asset.builder_set(&b,asset.builder_entity(&b,"Sky"),render.SKY_DEFAULT)
    // It shines toward its -Z, from where the sun of the editor's preset is.
    sun:=asset.builder_entity(&b,"Sun",{rotation=linalg.quaternion_between_two_vector3([3]f32{0,0,1},linalg.normalize(render.SUN_DIRECTION))})
    light:=render.SUN_DEFAULT
    light.disc=false
    asset.builder_set(&b,sun,light)

    floor:=asset.builder_entity(&b,"Floor",{position={0,-0.05,0},scale={20,0.1,20}})
    block(&b,floor,{0.35,0.38,0.42})
    asset.builder_set(&b,floor,phys.collider_box({0.5,0.5,0.5}))
    player_start:=asset.builder_entity(&b,"Player start",{position={0,0,5}})
    asset.builder_set(&b,player_start,spawn.Spawn_Point{prefab=PLAYER_PREFAB_ID})

    // The wall breaks into 24 pieces where it is hit; the ones that reach the floor stay.
    wall:=asset.builder_entity(&b,"Wall",{position={0,1.25,0},scale={4,2.5,0.4}})
    block(&b,wall,{0.75,0.45,0.3})
    asset.builder_set(&b,wall,destruct.destructible(pieces=24,anchored=true))
    asset.builder_set(&b,wall,destruct.collider_fracture())

    status:game.Status
    base.text_set(status.message[:],"Hit the wall")
    speaker:=asset.builder_entity(&b,"Speaker",{position={-3,0.35,2},scale={0.7,0.7,0.7}})
    block(&b,speaker,{0.2,0.2,0.25})
    source:=audio.AUDIO_SOURCE_DEFAULT
    source.sound,source.loop,source.spatial,source.volume,source.max_distance=hum,true,true,0.7,25
    asset.builder_set(&b,speaker,source)
    board:=asset.builder_entity(&b,"Sign",{position={-3,1.6,2}})
    widget:=gui.WORLD_WIDGET_DEFAULT
    widget.asset,widget.size,widget.scale,widget.facing,widget.pivot=sign,{220,70},0.01,.Billboard_Upright,.Bottom_Center
    asset.builder_set(&b,board,widget)
    asset.builder_set(&b,board,status)

    overlay:=asset.builder_entity(&b,"Hud")
    asset.builder_set(&b,overlay,gui.UI_Screen{asset=hud})
    asset.builder_set(&b,overlay,status)
    asset.builder_set(&b,overlay,game.Shell_Hud{})

    // Over the HUD, and Modal: while it shows the seats get no actions and the mouse is free;
    // shell_frame turns UI_Screen.pause on for the pause and settings pages.
    menus:=asset.builder_entity(&b,"Shell")
    asset.builder_set(&b,menus,gui.UI_Screen{asset=shell,order=10,input=.Modal})
    asset.builder_set(&b,menus,game.Shell_Screen{})

    asset.builder_save(&b,"assets/scenes/main.scene")
}

main :: proc() {
    c:asset.Content
    asset.content_init(&c,PROJECT)
    defer asset.content_destroy(&c)
    for folder in ([]string{"assets/sounds","assets/textures","assets/scenes","assets/prefabs"}) {os.make_directory_all(folder)}
    write_badge(&c)
    hum:=write_hum(&c)
    write_player(&c)
    // The ids of the .ui of assets/ui: written by their ui.write, not here.
    if !c.failed {write_scene(&c,asset.content_id(PROJECT,"ui","hud"),asset.content_id(PROJECT,"ui","sign"),hum,asset.content_id(PROJECT,"ui","shell"))}
    free_all(context.temp_allocator)
    if c.failed {os.exit(1)}
}
