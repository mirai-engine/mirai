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

// Writes every asset of the game: a badge (.tex), the HUD, the sign and the
// menus of game/shell.odin (.ui), a hum (.sound, imported from the WAV this writes into source/) and
// the scene assets/scenes/main.scene that uses them. Running it again gives
// the same bytes. From the folder of the project:
//
//   odin run tools/content -collection:mirai=<engine> -collection:plugins=<engine>/plugins -collection:project=. -ignore-unknown-attributes

PROJECT :: "game_content"
BADGE_SIZE :: 64
HUM_RATE :: 22050
HUM_SECONDS :: 2
WHITE :: ui.Color{255,255,255,255}

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

// The HUD: a panel in the top left corner with a badge that never stops
// pulsing, the message of the game and how many hits landed.
write_hud :: proc(c:^asset.Content,badge:base.Asset_Id) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","hud")
    styles:=[]ui.Node_Style{
        {},
        {fill={16,22,34,220},radius=8},
        {text={size=18,color=WHITE}},
        {text={size=13,color={170,184,210,255}}},
    }
    images:=[]ui.Tree_Image{{texture=badge}}
    keys:=[]ui.Keyframe{
        {time=0,value={1,1,0,0}},{time=0.6,value={1.2,1.2,0,0},ease=.In_Out_Quad},
    }
    tracks:=[]ui.Tree_Track{{.Scale,0,2}}
    anims:=[]ui.Tree_Anim{{kind=.Clip,loop=.Ping_Pong,first=0,count=1}}
    anim_sets:=[]ui.Anim_Set{{shown=1}}
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="panel",style=1,
            float={to=.Safe,anchor=.Top_Left,pivot=.Top_Left,offset={16,16}},
            layout={width=ui.fixed(260),gap=12,padding=ui.padding_all(12),align_y=.Center}}),
        ui.tree_node_record(&texts,0,{kind=.Image,name="badge",image=1,anims=1,layout={width=ui.fixed(36),height=ui.fixed(36)}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="lines",layout={direction=.Column,gap=4}}),
        ui.tree_node_record(&texts,2,{kind=.Text,name="message",style=2,bind_text="Status.message"}),
        ui.tree_node_record(&texts,2,{kind=.Box,name="count",layout={gap=6}}),
        ui.tree_node_record(&texts,4,{kind=.Text,name="hits_label",style=3,text="Hits:"}),
        ui.tree_node_record(&texts,4,{kind=.Text,name="hits",style=3,bind_text="Status.hits"}),
    }
    data:=ui.Tree_Data{text=texts[:],nodes=nodes,styles=styles,images=images,anims=anims,tracks=tracks,keys=keys,anim_sets=anim_sets}
    asset.content_check(c,"assets/ui/hud.ui",host.ui_tree_save("assets/ui/hud.ui",&c.types,id,data))
    return id
}

// The sign above the speaker: the message and the hits, facing the camera.
write_sign :: proc(c:^asset.Content) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=asset.content_id(PROJECT,"ui","sign")
    styles:=[]ui.Node_Style{
        {},
        {fill={16,22,34,235},stroke={96,118,160,255},radius=8},
        {text={size=18,color=WHITE}},
        {text={size=14,color={255,170,40,255}}},
    }
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="sign",style=1,layout={width=ui.fixed(220),height=ui.fixed(70),direction=.Column,padding=ui.padding_all(10),gap=6}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="message",style=2,bind_text="Status.message"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="hits",style=3,bind_text="Status.hits"}),
    }
    asset.content_check(c,"assets/ui/sign.ui",host.ui_tree_save("assets/ui/sign.ui",&c.types,id,{nodes=nodes,styles=styles,text=texts[:]}))
    return id
}

// The interface of game/shell.odin: a Switcher with a node named after each
// game.Shell_Page but Playing. Restyle it here: the colors,
// the styles and the sizes of the controls are all in this procedure.
write_shell :: proc(c:^asset.Content) -> base.Asset_Id {
    GAME_TITLE :: "Game"
    PANEL_FILL :: ui.Color{16,22,34,240}
    EDGE :: ui.Color{96,118,160,255}
    FACE :: ui.Color{34,46,70,255}
    FACE_LIT :: ui.Color{52,70,104,255}
    ACCENT :: ui.Color{255,170,40,255}
    DIM,PANEL,TITLE,BUTTON,LABEL,CONTROL :: 1,2,3,4,5,6 // indices of styles

    styles:=[]ui.Node_Style{
        {},
        {fill={8,12,20,170}},
        {fill=PANEL_FILL,stroke=EDGE,stroke_width=1,radius=12},
        {text={size=40,color=WHITE,align_x=.Center}},
        {text={size=22,color=WHITE,align_x=.Center,align_y=.Center},fill=FACE,stroke=EDGE,stroke_width=1,radius=8,transition=0.08},
        {text={size=18,color={190,204,228,255}}},
        {text={size=18,color=WHITE,align_x=.Center,align_y=.Center},fill=FACE,stroke=EDGE,stroke_width=1,radius=6,mark=ACCENT,transition=0.08},
    }
    lit :: proc(style:u16,states:ui.Style_States,fill,stroke:ui.Color) -> ui.Tree_Style_Variant {
        values:ui.Node_Style
        values.fill,values.stroke=fill,stroke
        return ui.tree_variant_record(style,"",states,{fields={.Fill,.Stroke},values=values})
    }
    variants:=[]ui.Tree_Style_Variant{
        lit(BUTTON,{.Hovered},FACE_LIT,EDGE),lit(BUTTON,{.Focused},FACE_LIT,ACCENT),lit(BUTTON,{.Pressed},ACCENT,ACCENT),
        lit(CONTROL,{.Hovered},FACE_LIT,EDGE),lit(CONTROL,{.Focused},FACE_LIT,ACCENT),
    }

    Tree :: struct {texts:[dynamic]u8,nodes:[dynamic]ui.Tree_Node}
    add :: proc(t:^Tree,parent:i32,desc:ui.Node_Desc) -> i32 {
        append(&t.nodes,ui.tree_node_record(&t.texts,parent,desc))
        return i32(len(t.nodes)-1)
    }
    // A dimmed page with a centered panel and its title; what it holds goes in the panel.
    page :: proc(t:^Tree,pages:i32,member:game.Shell_Page,title:string) -> i32 {
        dim:=add(t,pages,{kind=.Box,name=fmt.tprint(member),style=DIM,layout={width=ui.grow(),height=ui.grow(),align_x=.Center,align_y=.Center}})
        panel:=add(t,dim,{kind=.Box,style=PANEL,layout={direction=.Column,align_x=.Center,gap=12,padding=ui.padding_all(28)},flags={.Wrap_Y}})
        add(t,panel,{kind=.Text,style=TITLE,text=title})
        return panel
    }
    // The first control of a page takes the focus of the keyboard when it shows.
    first :: proc(on:bool) -> ui.Node_Flags {return on?{.Focus_First}:{}}
    button :: proc(t:^Tree,parent:i32,name,text:string,is_first:=false) {
        add(t,parent,{kind=.Button,name=name,text=text,style=BUTTON,flags=first(is_first),layout={width=ui.fixed(280),height=ui.fixed(50)}})
    }
    row :: proc(t:^Tree,parent:i32,label:string) -> i32 {
        at:=add(t,parent,{kind=.Box,layout={gap=16,align_y=.Center}})
        add(t,at,{kind=.Text,style=LABEL,text=label,layout={width=ui.fixed(190)}})
        return at
    }
    selector :: proc(t:^Tree,parent:i32,label,name,bind,options:string,is_first:=false) {
        add(t,row(t,parent,label),{kind=.Selector,name=name,bind_value=bind,text=options,style=CONTROL,flags=first(is_first),layout={width=ui.fixed(280),height=ui.fixed(36)}})
    }
    checkbox :: proc(t:^Tree,parent:i32,label,name,bind:string) {
        add(t,row(t,parent,label),{kind=.Checkbox,name=name,bind_value=bind,style=CONTROL,layout={width=ui.fixed(36),height=ui.fixed(36)}})
    }

    t:=Tree{texts=make([dynamic]u8,context.temp_allocator),nodes=make([dynamic]ui.Tree_Node,context.temp_allocator)}
    root:=add(&t,-1,{kind=.Box,name="shell",float={to=.Surface,anchor=.Top_Left,pivot=.Top_Left},layout={width=ui.grow(),height=ui.grow()}})
    pages:=add(&t,root,{kind=.Switcher,name="pages",bind_value="Shell.page",layout={width=ui.grow(),height=ui.grow()}})

    menu:=page(&t,pages,.Menu,GAME_TITLE)
    button(&t,menu,"menu_play","Play",true)
    button(&t,menu,"menu_exit","Exit")

    pause:=page(&t,pages,.Pause,"Paused")
    button(&t,pause,"pause_resume","Resume",true)
    button(&t,pause,"pause_settings","Settings")
    button(&t,pause,"pause_quit","Quit to Menu")

    // The options of each selector are in the order of the SHELL_ tables of game/shell.odin.
    settings:=page(&t,pages,.Settings,"Graphics")
    selector(&t,settings,"Quality","settings_preset","Shell_Options.preset","Low|Medium|High|Custom",true)
    selector(&t,settings,"Render scale","settings_scale","Shell_Options.scale","50%|75%|100%")
    selector(&t,settings,"Shadows","settings_shadows","Shell_Options.shadows","Off|Low|Medium|High")
    selector(&t,settings,"Anti-aliasing","settings_aa","Shell_Options.antialiasing","Off|TAA")
    selector(&t,settings,"Reflections","settings_reflections","Shell_Options.reflections","Off|Traced|Detailed")
    selector(&t,settings,"Frame limit","settings_limit","Shell_Options.limit","30|60|120|None")
    checkbox(&t,settings,"Fullscreen","settings_fullscreen","Shell_Options.fullscreen")
    checkbox(&t,settings,"VSync","settings_vsync","Shell_Options.vsync")
    button(&t,settings,"settings_back","Back")

    id:=asset.content_id(PROJECT,"ui","shell")
    asset.content_check(c,"assets/ui/shell.ui",host.ui_tree_save("assets/ui/shell.ui",&c.types,id,{nodes=t.nodes[:],styles=styles,variants=variants,text=t.texts[:]}))
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

// Half a turn about +Y. A body's front is its +Z (the glTF model front): a spawn turned so looks
// along -Z, and a camera child of a body turned so looks where the body faces.
HALF_TURN :: quaternion(w=0,x=0,y=1,z=0)
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
    eyes:=asset.builder_entity(&b,"Player view",{position={0,EYE_HEIGHT,0},rotation=HALF_TURN},root)
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
    player_start:=asset.builder_entity(&b,"Player start",{position={0,0,5},rotation=HALF_TURN})
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

    // Over the HUD, and Modal: while it shows the seats get no actions and the pointer is free.
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
    hud,sign,hum,shell:=write_hud(&c,badge),write_sign(&c),write_hum(&c),write_shell(&c)
    write_player(&c)
    if !c.failed {write_scene(&c,hud,sign,hum,shell)}
    free_all(context.temp_allocator)
    if c.failed {os.exit(1)}
}
