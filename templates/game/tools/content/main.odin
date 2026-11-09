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
import "mirai:host"
import "mirai:std/base"
import "mirai:ui"
import game "project:game"

PLAYER_PREFAB_ID :: base.Asset_Id{0x6d6972616967616d,0x706c617965720001} // the id main.scene names the player prefab by

// Writes every asset of the game: a badge (.tex), the look every screen shares
// (write_theme, its tokens first), the HUD, the sign and the menus of
// game/shell.odin (.ui), a hum (.sound, imported from the WAV this writes into source/) and
// the scene assets/scenes/main.scene that uses them. Running it again gives
// the same bytes. From the folder of the project:
//
//   odin run tools/content -collection:mirai=<engine> -collection:plugins=<engine>/plugins -collection:project=. -ignore-unknown-attributes

PROJECT :: "game_content"
BADGE_SIZE :: 64
HUM_RATE :: 22050
HUM_SECONDS :: 2

// An orange disc with a white core, transparent around it.
write_badge :: proc(c:^asset.Content) -> base.Asset_Id {
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
    return id
}

// The look of the game, in one place: change a token and every screen follows.
// theme.ui holds these styles and the components every screen shares; the
// other screens take them with ui.sheet_take, so two screens share button.
write_theme :: proc(c:^asset.Content) -> (theme:ui.Sheet,id:base.Asset_Id) {
    theme=ui.sheet_make("theme")
    ui.sheet_tokens(&theme,{
        {"ink","#3a1d4f"},        // text and thick edges
        {"cream","#fff6e9"},      // panel, top
        {"peach","#ffdfbe"},      // panel, bottom
        {"berry_light","#ff8fa9"}, // button, top
        {"berry","#f0467f"},      // button, bottom
        {"sun_light","#ffe07a"},  // button under the pointer, top
        {"sun","#ffb238"},
        {"mint","#46dfc4"},       // the focus of keys and gamepad
        {"sky","#fff0dc"},        // controls, top
        {"sky_low","#ffd4a6"},    // controls, bottom
        {"dim_color","#2c163f8c"},
        {"clear","#00000000"},
        {"edge",4},
        {"round",20},
        {"soft",12},
        {"title",92},
        {"heading",46},
        {"body",22},
    })
    ui.sheet_styles(&theme,{
        // Behind a menu: the world, dimmed and blurred.
        {name="dim",fill="dim_color",blur=6},
        {name="menu_back",fill="#2c163f30"},
        {name="title",size="title",color="cream",font=ui.FONT_SEMIBOLD,outline=6,outline_color="ink",text_shadow={x=0,y=7,color="ink"},align_x=.Center},
        {name="heading",size="heading",color="ink",font=ui.FONT_SEMIBOLD,align_x=.Center},
        {name="hint",size=16,color="cream",text_shadow={x=0,y=2,color="#2c163fc0"},align_x=.Center},
        {name="label",size="body",color="ink",font=ui.FONT_MEDIUM},
        {name="panel",fill="cream",fill2="peach",stroke="ink",border=6,radius=32,
            shadow={color="#2c163f70",blur=30,y=18}},
        // A thick rounded button whose hard shadow is its edge: it lifts under the
        // pointer and sinks when pressed.
        {name="button",fill="berry_light",fill2="berry",stroke="ink",border="edge",radius="round",
            size=26,color="cream",font=ui.FONT_SEMIBOLD,align_x=.Center,align_y=.Center,text_shadow={x=0,y=2,color="ink"},
            shadow={color="ink",y=7},transition=0.09,
            hover={fill="sun_light",fill2="sun",color="ink",text_shadow={color="clear"},move_y=-3,shadow={y=10}},
            focus={fill="sun_light",fill2="sun",color="ink",text_shadow={color="clear"},stroke="mint",border=6,move_y=-3,shadow={y=10}},
            pressed={move_y=5,shadow={y=2}},
            disabled={fill="#b5acc4",fill2="#9a90ab",color="#ece6f4",shadow={y=3}},
        },
        // The value of a setting.
        {name="control",fill="sky",fill2="sky_low",stroke="ink",border=3,radius="soft",
            size=20,color="ink",font=ui.FONT_SEMIBOLD,align_x=.Center,align_y=.Center,mark="berry",
            shadow={color="ink",y=3},transition=0.08,
            hover={fill="sun_light",fill2="sun",move_y=-1,shadow={y=4}},
            focus={stroke="mint",border=5,fill="sun_light",fill2="sun"},
            pressed={move_y=2,shadow={y=1}},
        },
        {name="chip",fill="cream",fill2="peach",stroke="ink",border=4,radius=16,shadow={color="ink",y=5}},
        {name="chip_value",size=20,color="ink",font=ui.FONT_SEMIBOLD},
        {name="chip_label",size=14,color="#6b4a7a"},
    })
    // The pieces every screen builds with: a screen sets their text, what they bind and their focus.
    if ui.sheet_component(&theme,"button") {
        ui.sheet_node(&theme,-1,"button",{kind=.Button,layout={width=ui.fixed(300),height=ui.fixed(60)}})
    }
    if ui.sheet_component(&theme,"panel") {
        root:=ui.sheet_node(&theme,-1,"panel",{kind=.Box,flags={.Slot,.Wrap_Y},layout={direction=.Column,align_x=.Center,gap=14,padding=ui.padding_all(34)}})
        ui.sheet_node(&theme,root,"heading",{kind=.Text,name="heading"})
    }
    // One row of a settings page: its label and a control that binds what the use names with data.
    if ui.sheet_component(&theme,"select_row") {
        row:=ui.sheet_node(&theme,-1,"",{kind=.Box,layout={width=ui.grow(),gap=22,align_y=.Center}})
        ui.sheet_node(&theme,row,"label",{kind=.Text,name="label",layout={width=ui.grow()}})
        ui.sheet_node(&theme,row,"control",{kind=.Selector,name="control",bind_value="@",layout={width=ui.fixed(310),height=ui.fixed(44)}})
    }
    if ui.sheet_component(&theme,"check_row") {
        row:=ui.sheet_node(&theme,-1,"",{kind=.Box,layout={width=ui.grow(),gap=22,align_y=.Center}})
        ui.sheet_node(&theme,row,"label",{kind=.Text,name="label",layout={width=ui.grow()}})
        ui.sheet_node(&theme,row,"control",{kind=.Checkbox,name="control",bind_value="@",layout={width=ui.fixed(44),height=ui.fixed(44)}})
    }
    id=asset.content_id(PROJECT,"ui","theme")
    host.ui_sheet_save(c,"assets/ui/theme.ui",id,&theme)
    return
}

// The HUD: a chip in the top left corner with a badge that never stops
// pulsing, the message of the game and how many hits landed.
write_hud :: proc(c:^asset.Content,theme:^ui.Sheet,theme_id,badge:base.Asset_Id) -> base.Asset_Id {
    s:=ui.sheet_make("hud")
    ui.sheet_take(&s,theme_id,theme)
    badge_image:=ui.sheet_image(&s,{texture=badge})
    s.keys=[]ui.Keyframe{
        {time=0,value={1,1,0,0}},{time=0.6,value={1.2,1.2,0,0},ease=.In_Out_Quad},
    }
    s.tracks=[]ui.Tree_Track{{.Scale,0,2}}
    s.anims=[]ui.Tree_Anim{{kind=.Clip,loop=.Ping_Pong,first=0,count=1}}
    s.anim_sets=[]ui.Anim_Set{{shown=1}}
    panel:=ui.sheet_node(&s,-1,"chip",{kind=.Box,name="panel",
        float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left,offset={18,18}},
        layout={width=ui.fixed(290),gap=14,padding={16,12,16,12},align_y=.Center}})
    ui.sheet_node(&s,panel,"",{kind=.Image,name="badge",image=badge_image,anims=1,layout={width=ui.fixed(40),height=ui.fixed(40)}})
    lines:=ui.sheet_node(&s,panel,"",{kind=.Box,name="lines",layout={direction=.Column,gap=3}})
    ui.sheet_node(&s,lines,"chip_value",{kind=.Text,name="message",bind_text="Status.message"})
    count:=ui.sheet_node(&s,lines,"",{kind=.Box,name="count",layout={gap=6}})
    ui.sheet_node(&s,count,"chip_label",{kind=.Text,name="hits_label",text="Hits:"})
    ui.sheet_node(&s,count,"chip_label",{kind=.Text,name="hits",bind_text="Status.hits"})
    id:=asset.content_id(PROJECT,"ui","hud")
    host.ui_sheet_save(c,"assets/ui/hud.ui",id,&s)
    return id
}

// The sign above the speaker: the message and the hits, facing the camera.
write_sign :: proc(c:^asset.Content,theme:^ui.Sheet,theme_id:base.Asset_Id) -> base.Asset_Id {
    s:=ui.sheet_make("sign")
    ui.sheet_take(&s,theme_id,theme)
    sign:=ui.sheet_node(&s,-1,"chip",{kind=.Box,name="sign",layout={width=ui.fixed(220),height=ui.fixed(70),direction=.Column,padding=ui.padding_all(10),gap=4}})
    ui.sheet_node(&s,sign,"chip_value",{kind=.Text,name="message",bind_text="Status.message"})
    ui.sheet_node(&s,sign,"chip_label",{kind=.Text,name="hits",bind_text="Status.hits"})
    id:=asset.content_id(PROJECT,"ui","sign")
    host.ui_sheet_save(c,"assets/ui/sign.ui",id,&s)
    return id
}

// The interface of game/shell.odin: a Switcher with a node named after each
// game.Shell_Page but Playing. It names styles and components of theme.ui:
// restyle write_theme, add screens here.
write_shell :: proc(c:^asset.Content,theme:^ui.Sheet,theme_id:base.Asset_Id) -> base.Asset_Id {
    GAME_TITLE :: "Game"
    first :: proc(on:bool) -> ui.Node_Flags {return on?{.Focus_First}:{}}
    // The first control of a page takes the focus of keys and gamepad when it shows.
    button :: proc(s:^ui.Sheet,parent:i32,name,text:string,is_first:=false) {
        ui.sheet_use(s,parent,"button",{name=name,text=text,flags=first(is_first)})
    }
    // A screen over the world, named after its page of Shell_Page: dimmed and blurred behind a menu that stops the game.
    page :: proc(s:^ui.Sheet,pages:i32,member:game.Shell_Page,back:="dim") -> i32 {
        return ui.sheet_node(s,pages,back,{kind=.Box,name=fmt.tprint(member),layout={width=ui.grow(),height=ui.grow(),align_x=.Center,align_y=.Center}})
    }
    panel :: proc(s:^ui.Sheet,pages:i32,member:game.Shell_Page,title:string,width:f32) -> i32 {
        return ui.sheet_use(s,page(s,pages,member),"panel",{layout={width=ui.fixed(width),direction=.Column,align_x=.Center,gap=14,padding=ui.padding_all(34)}},{{"heading",{text=title},""}})
    }
    select :: proc(s:^ui.Sheet,parent:i32,label,name,bind,options:string,is_first:=false) {
        ui.sheet_use(s,parent,"select_row",{name=name,data=bind},{{"label",{text=label},""},{"control",{text=options,flags=first(is_first)},""}})
    }
    check :: proc(s:^ui.Sheet,parent:i32,label,name,bind:string) {
        ui.sheet_use(s,parent,"check_row",{name=name,data=bind},{{"label",{text=label},""}})
    }

    s:=ui.sheet_make("shell")
    ui.sheet_take(&s,theme_id,theme)
    root:=ui.sheet_node(&s,-1,"",{kind=.Box,name="shell",float={to=.Surface,anchor=.Top_Left,pivot=.Top_Left},layout={width=ui.grow(),height=ui.grow()}})
    pages:=ui.sheet_node(&s,root,"",{kind=.Switcher,name="pages",bind_value="Shell.page",layout={width=ui.grow(),height=ui.grow()}})

    menu:=ui.sheet_node(&s,page(&s,pages,.Menu,"menu_back"),"",{kind=.Box,flags={.Wrap_Y},layout={direction=.Column,align_x=.Center,gap=16}})
    ui.sheet_node(&s,menu,"title",{kind=.Text,text=GAME_TITLE,layout={height=ui.fixed(150)}})
    button(&s,menu,"menu_play","Play",true)
    button(&s,menu,"menu_exit","Exit")
    ui.sheet_node(&s,menu,"hint",{kind=.Text,text="Arrow keys and Enter, or the mouse"})

    pause:=panel(&s,pages,.Pause,"Paused",470)
    button(&s,pause,"pause_resume","Resume",true)
    button(&s,pause,"pause_settings","Settings")
    button(&s,pause,"pause_quit","Quit to Menu")

    // Bound to the settings of the engine: choosing writes them, and "Label=Value" is what each option writes.
    settings:=panel(&s,pages,.Settings,"Graphics",680)
    select(&s,settings,"Quality","settings_quality","Graphics_Settings.quality","Low|Medium|High|Ultra|Custom",true)
    select(&s,settings,"Render scale","settings_scale","Graphics_Settings.render_scale","Auto=0|50%=0.5|75%=0.75|100%=1")
    select(&s,settings,"Shadow rays","settings_rays","Graphics_Settings.shadowed_lights","Low=4|Medium=8|High=16")
    check(&s,settings,"Sun shadows","settings_sun","Graphics_Settings.sun_shadows")
    select(&s,settings,"Anti-aliasing","settings_aa","Graphics_Settings.antialiasing","Off=off|TAA=taa")
    select(&s,settings,"Reflections","settings_reflections","Graphics_Settings.reflections","Off|Traced|Detailed")
    select(&s,settings,"Frame limit","settings_limit","Graphics_Settings.frame_limit","30=30|60=60|120=120|None=0")
    select(&s,settings,"Window","settings_window","Display_Settings.mode","Project=Project|Windowed=Windowed|Fullscreen=Fullscreen")
    check(&s,settings,"VSync","settings_vsync","Graphics_Settings.vsync")
    button(&s,settings,"settings_back","Back")

    id:=asset.content_id(PROJECT,"ui","shell")
    host.ui_sheet_save(c,"assets/ui/shell.ui",id,&s)
    return id
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
    asset.builder_set(&b,sun,render.Sun{color={1,0.96,0.9},illuminance=100000})

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
    for folder in ([]string{"assets/ui","assets/sounds","assets/textures","assets/scenes","assets/prefabs"}) {os.make_directory_all(folder)}
    badge:=write_badge(&c)
    theme,theme_id:=write_theme(&c)
    hud,sign,hum,shell:=write_hud(&c,&theme,theme_id,badge),write_sign(&c,&theme,theme_id),write_hum(&c),write_shell(&c,&theme,theme_id)
    write_player(&c)
    if !c.failed {write_scene(&c,hud,sign,hum,shell)}
    free_all(context.temp_allocator)
    if c.failed {os.exit(1)}
}
