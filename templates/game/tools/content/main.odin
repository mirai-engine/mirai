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

// Writes every asset of the game: a badge (.tex), the HUD and the sign
// (.ui), a hum (.sound, imported from the WAV this writes into source/) and
// the scene assets/arena/main.scene that uses them. Running it again gives
// the same bytes. From the folder of the project:
//
//   odin run tools/content -collection:mirai=<engine> -collection:project=. -custom-attribute:component,storage,step,loops,stage,after,before,server,shared,locks,host,by_world,copy,copy_kept,swap,free,replicated,setting,description,queue,events,keep,persist,single,far,reset,net_message,from,reliable,params,names,name_bits,name,name_requires,presentation,record

@(private) id_of :: proc(kind,name:string) -> base.Asset_Id {return base.asset_id_named(fmt.tprintf("%s\x1fgame_content\x1f%s",kind,name))}

BADGE_SIZE :: 64
HUM_RATE :: 22050
HUM_SECONDS :: 2
WHITE :: ui.Color{255,255,255,255}

Out :: struct {
    types:asset.Types,
    failed:bool,
}

@(private)
check :: proc(o:^Out,what:string,error:asset.Error) {
    if error==.None {
        fmt.printfln("wrote %s",what)
        return
    }
    fmt.eprintfln("content: %s: %v",what,error)
    o.failed=true
}

// An orange disc with a white core, transparent around it.
write_badge :: proc(o:^Out) -> base.Asset_Id {
    id:=id_of("texture","badge")
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
    check(o,"assets/hud/badge.tex",asset.texture_save("assets/hud/badge.tex",&o.types,
        {id=id,width=BADGE_SIZE,height=BADGE_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
    return id
}

// The HUD: a panel in the top left corner with a badge that never stops
// pulsing, the message of the game and how many hits landed.
write_hud :: proc(o:^Out,badge:base.Asset_Id) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=id_of("ui","hud")
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
    check(o,"assets/hud/hud.ui",host.ui_tree_save("assets/hud/hud.ui",&o.types,id,data))
    return id
}

// The sign above the speaker: the message and the hits, facing the camera.
write_sign :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=id_of("ui","sign")
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
    check(o,"assets/arena/sign.ui",host.ui_tree_save("assets/arena/sign.ui",&o.types,id,{nodes=nodes,styles=styles,text=texts[:]}))
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
        wave:=0.5*math.sin(2*math.PI*110*t)+0.25*math.sin(2*math.PI*220*t)+0.12*math.sin(2*math.PI*330*t)
        tremolo:=0.75+0.25*math.sin(2*math.PI*1.5*t)
        le(file,44+frame*2,u32(u16(i16(wave*tremolo*20000))),2)
    }
    os.make_directory_all("source/sounds")
    // Written only when it differs, so that the import of an unchanged source is the same file.
    existing,read_error:=os.read_entire_file("source/sounds/hum.wav",context.temp_allocator)
    if (read_error!=nil || string(existing)!=string(file)) && os.write_entire_file("source/sounds/hum.wav",file)!=nil {
        fmt.eprintln("content: source/sounds/hum.wav could not be written")
        o.failed=true
        return {}
    }
    report,error:=importer.import_sound("source/sounds/hum.wav","assets/arena",{},{root="."})
    if error.code!=.None {
        fmt.eprintfln("content: %s",error.message)
        o.failed=true
        return {}
    }
    defer importer.report_destroy(&report)
    fmt.printfln("imported %s",report.assets[0].path)
    return report.assets[0].id
}

Scene_Out :: struct {
    scene:asset.Scene,
    next:base.Entity_Id,
    failed:bool,
}

// Half a turn about +Y. A body's front is its +Z (the glTF model front): a spawn turned so looks
// along -Z, and a camera child of a body turned so looks where the body faces.
HALF_TURN :: quaternion(w=0,x=0,y=1,z=0)

@(private)
entity :: proc(s:^Scene_Out,name:string,position:[3]f32={},scale:[3]f32={1,1,1},parent:base.Entity_Id=0) -> base.Entity_Id {
    s.next+=1
    if _,error:=asset.scene_entity_add(&s.scene,s.next,parent,name);error!=.None {s.failed=true}
    transform:=core.Transform{position,1,scale}
    put(s,s.next,"Transform",&transform)
    return s.next
}
@(private)
put :: proc(s:^Scene_Out,id:base.Entity_Id,name:string,value:^$T) {
    if asset.scene_set(&s.scene,id,name,value)!=.None {s.failed=true}
}
// A tinted cube.
@(private)
block :: proc(s:^Scene_Out,id:base.Entity_Id,color:[3]f32) {
    mesh:=render.Mesh_Renderer{shape=.Cube}
    tint:=render.Tint{color={color.r,color.g,color.b,1}}
    put(s,id,"Mesh_Renderer",&mesh)
    put(s,id,"Tint",&tint)
}

// The body of a player: a character its seat walks, with a camera
// at its eyes that looks where it looks.
write_player :: proc(o:^Out) {
    s:Scene_Out
    asset.scene_init(&s.scene,&o.types,asset.KIND_PREFAB,game.PLAYER_PREFAB)
    defer asset.scene_destroy(&s.scene)
    root:=entity(&s,"Player")
    s.scene.info.root=root
    character,capsule,walk:=phys.character_default(),phys.collider_character(),game.player_walk()
    player:=game.Player{}
    put(&s,root,"Character",&character)
    put(&s,root,"Walk",&walk)
    put(&s,root,"Collider",&capsule)
    put(&s,root,"Player",&player)
    put(&s,root,"Replicate",&multiplayer.Replicate{priority=1,radius=1})
    eyes:=entity(&s,"Player view",{0,game.EYE_HEIGHT,0},parent=root)
    put(&s,eyes,"Transform",&core.Transform{{0,game.EYE_HEIGHT,0},HALF_TURN,{1,1,1}})
    view:=render.Camera{fov=game.VIEW_FOV,near=0.05,active=true}
    follow:=cam.Camera_Follow{mode=.Eyes,offset={0,game.EYE_HEIGHT,0}}
    put(&s,eyes,"Camera",&view)
    put(&s,eyes,"Audio_Listener",&audio.Audio_Listener{})
    put(&s,eyes,"Camera_Follow",&follow)
    put(&s,root,"Drivable",&inp.Drivable{camera=core.Entity(eyes)})
    if s.failed {
        fmt.eprintln("content: the prefab could not be built")
        o.failed=true
        return
    }
    check(o,"assets/player/Player.prefab",asset.scene_save(&s.scene,"assets/player/Player.prefab"))
}

write_scene :: proc(o:^Out,hud,sign,hum:base.Asset_Id) {
    s:Scene_Out
    asset.scene_init(&s.scene,&o.types,asset.KIND_SCENE,id_of("scene","main"))
    defer asset.scene_destroy(&s.scene)

    // The sun of noon, lux, and a sky as bright next to it as the template has
    // always had it, nits.
    sky:=render.SKY_DEFAULT
    sky.luminance,sky.use_background={8950,10940,14920},false
    put(&s,entity(&s,"Sky"),"Sky",&sky)
    // Three quarters of a stop over the meter in the whole scene.
    look:=render.VIEW_VOLUME_DEFAULT
    look.exposure.compensation=0.75
    put(&s,entity(&s,"Exposure"),"View_Volume",&look)
    // It shines toward its -Z, from where the sun of the editor's preset is.
    sun:=render.Sun{color={1,0.96,0.9},illuminance=100000}
    sun_entity:=entity(&s,"Sun")
    sun_placed:=core.Transform{{},linalg.quaternion_between_two_vector3([3]f32{0,0,1},linalg.normalize(render.SUN_DIRECTION)),{1,1,1}}
    put(&s,sun_entity,"Transform",&sun_placed)
    put(&s,sun_entity,"Sun",&sun)

    floor:=entity(&s,"Floor",{0,-0.05,0},{20,0.1,20})
    block(&s,floor,{0.35,0.38,0.42})
    ground:=phys.collider_box({0.5,0.5,0.5})
    put(&s,floor,"Collider",&ground)
    start:=spawn.Spawn_Point{prefab=game.PLAYER_PREFAB}
    player_start:=entity(&s,"Player start")
    put(&s,player_start,"Transform",&core.Transform{{0,0,5},HALF_TURN,{1,1,1}})
    put(&s,player_start,"Spawn_Point",&start)

    // The wall breaks into 24 pieces where it is hit; the ones that reach the floor stay.
    wall:=entity(&s,"Wall",{0,1.25,0},{4,2.5,0.4})
    block(&s,wall,{0.75,0.45,0.3})
    breakable:=destruct.destructible(pieces=24,anchored=true)
    put(&s,wall,"Destructible",&breakable)
    pieces:=destruct.collider_fracture()
    put(&s,wall,"Collider",&pieces)

    status:game.Status
    base.text_set(status.message[:],"Hit the wall")
    speaker:=entity(&s,"Speaker",{-3,0.35,2},{0.7,0.7,0.7})
    block(&s,speaker,{0.2,0.2,0.25})
    source:=audio.AUDIO_SOURCE_DEFAULT
    source.sound,source.loop,source.spatial,source.volume,source.max_distance=hum,true,true,0.7,25
    put(&s,speaker,"Audio_Source",&source)
    board:=entity(&s,"Sign",{-3,1.6,2})
    widget:=gui.WORLD_WIDGET_DEFAULT
    widget.asset,widget.size,widget.scale,widget.facing,widget.pivot=sign,{220,70},0.01,.Billboard_Upright,.Bottom_Center
    put(&s,board,"World_Widget",&widget)
    put(&s,board,"Status",&status)

    screen:=gui.UI_Screen{asset=hud}
    overlay:=entity(&s,"Hud")
    put(&s,overlay,"UI_Screen",&screen)
    put(&s,overlay,"Status",&status)

    if s.failed {
        fmt.eprintln("content: the scene could not be built")
        o.failed=true
        return
    }
    check(o,"assets/arena/main.scene",asset.scene_save(&s.scene,"assets/arena/main.scene"))
}

main :: proc() {
    o:Out
    asset.types_init(&o.types)
    defer asset.types_destroy(&o.types)
    for folder in ([]string{"assets/arena","assets/hud","assets/player"}) {os.make_directory_all(folder)}
    badge:=write_badge(&o)
    hud,sign,hum:=write_hud(&o,badge),write_sign(&o),write_hum(&o)
    write_player(&o)
    if !o.failed {write_scene(&o,hud,sign,hum)}
    free_all(context.temp_allocator)
    if o.failed {os.exit(1)}
}
