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
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// Writes every generated asset of the demo project: the imports of
// demo/source (sources.odin) and the showcase, which is the scene
// demo/assets/scenes/showcase.scene and the assets it uses: a HUD and a sign
// (.ui) with their two images (.tex), the clips of a lift (.anim) and the hum
// of a speaker (.sound, imported from a WAV this also writes). Running it
// again gives the same bytes. The other scenes, the prefabs of
// demo/assets/prefabs and the materials of demo/assets/materials are authored.
//
//   odin run tools/demo_content -collection:mirai=. -collection:plugins=plugins -ignore-unknown-attributes -- [root of the repository]

@(private) id_of :: proc(kind,name:string) -> base.Asset_Id {return base.asset_id_named(fmt.tprintf("%s\x1fdemo_content\x1f%s",kind,name))}

BADGE_SIZE :: 64
PANEL_SIZE :: 32
HUM_RATE :: 22050
HUM_SECONDS :: 2

Out :: struct {
    root:string,
    types:asset.Types,
    actions:[]serial.Choice, // the actions of the demo with their numbers, which types.schema names
    failed:bool,
    slabs:map[string]base.Asset_Id, // the meshes of slab(), by their file
}

@(private)
path :: proc(o:^Out,relative:string) -> string {return fmt.tprintf("%s/demo/%s",o.root,relative)}

@(private)
check :: proc(o:^Out,what:string,error:asset.Error) {
    if error==.None {
        fmt.printfln("wrote %s",what)
        return
    }
    fmt.eprintfln("demo_content: %s: %v",what,error)
    o.failed=true
}

// Writes a mesh of one level of a source and its indices (asset.mesh_build)
// to file, a path relative to the demo.
@(private)
mesh_write_built :: proc(o:^Out,what,file:string,desc:asset.Mesh_Desc,source:asset.Mesh_Source,indices:[]u32) {
    desc:=desc
    if !asset.mesh_build(source,indices,nil,&desc.geometry,context.temp_allocator) {check(o,what,.Invalid);return}
    check(o,what,asset.mesh_save(path(o,file),&o.types,desc))
}

// How much of a pixel a disc of a radius covers, from the distance of its center.
@(private)
coverage :: proc(distance,radius:f32) -> f32 {return clamp(radius-distance+0.5,0,1)}

// An orange disc with a white core, transparent around it.
write_badge :: proc(o:^Out) -> base.Asset_Id {
    id:=id_of("texture","hud_badge")
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
    check(o,"assets/textures/hud_badge.tex",asset.texture_save(path(o,"assets/textures/hud_badge.tex"),&o.types,
        {id=id,width=BADGE_SIZE,height=BADGE_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
    return id
}

// A dark rounded panel with a light border: the nine slice of the HUD.
write_panel :: proc(o:^Out) -> base.Asset_Id {
    id:=id_of("texture","hud_panel")
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
    check(o,"assets/textures/hud_panel.tex",asset.texture_save(path(o,"assets/textures/hud_panel.tex"),&o.types,
        {id=id,width=PANEL_SIZE,height=PANEL_SIZE,format=.RGBA8,flags={.Srgb},mips={pixels}}))
    return id
}

WHITE :: ui.Color{255,255,255,255}

// The HUD: a panel hung from the top right corner of the screen that slides
// in, with a badge that never stops pulsing, the name and the bar of the
// lift, its count of trips and a line that exists while it runs.
write_hud :: proc(o:^Out,badge,panel:base.Asset_Id) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=id_of("ui","hud")
    // Row 0 is the style of the nodes that name none: the rows of the layout, which draw nothing.
    styles:=[]ui.Node_Style{
        {},
        {text={size=18,color=WHITE}},
        {fill={255,170,40,255},track={40,48,66,255},radius=4},
        {text={size=13,color={170,184,210,255}}},
        {text={size=13,color=WHITE}},
        {text={size=13,color={120,220,140,255}}},
        {fill=WHITE},
    }
    images:=[]ui.Tree_Image{
        {texture=panel,border={10,10,10,10},border_uv={10.0/PANEL_SIZE,10.0/PANEL_SIZE,10.0/PANEL_SIZE,10.0/PANEL_SIZE}},
        {texture=badge},
    }
    keys:=[]ui.Keyframe{
        {time=0,value={48,0,0,0}},{time=0.4,value={0,0,0,0},ease=.Out_Cubic},
        {time=0,value={0,0,0,0}},{time=0.4,value={1,0,0,0},ease=.Linear},
        {time=0,value={1,1,0,0}},{time=0.6,value={1.2,1.2,0,0},ease=.In_Out_Quad},
        {time=0,value={-0.3,0,0,0}},{time=0.6,value={0.3,0,0,0},ease=.In_Out_Quad},
    }
    tracks:=[]ui.Tree_Track{{.Offset,0,2},{.Opacity,2,2},{.Scale,4,2},{.Rotation,6,2}}
    anims:=[]ui.Tree_Anim{{kind=.Clip,loop=.Once,first=0,count=2},{kind=.Clip,loop=.Ping_Pong,first=2,count=2}}
    anim_sets:=[]ui.Anim_Set{{shown=1},{shown=2}}
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="panel",style=6,image=1,anims=1,
            float={to=.Safe,anchor=.Top_Right,pivot=.Top_Right,offset={-16,16}},
            layout={width=ui.fixed(280),direction=.Column,padding=ui.padding_all(14),gap=8}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="header",layout={gap=10,align_y=.Center}}),
        ui.tree_node_record(&texts,1,{kind=.Image,name="badge",image=2,anims=2,layout={width=ui.fixed(40),height=ui.fixed(40)}}),
        ui.tree_node_record(&texts,1,{kind=.Text,name="title",style=1,bind_text="Showcase.label"}),
        ui.tree_node_record(&texts,0,{kind=.Progress,name="charge",style=2,bind_value="Showcase.charge",layout={width=ui.fixed(252),height=ui.fixed(14)}}),
        ui.tree_node_record(&texts,0,{kind=.Box,name="count",layout={gap=6}}),
        ui.tree_node_record(&texts,5,{kind=.Text,name="trips_label",style=3,text="Trips to the top:"}),
        ui.tree_node_record(&texts,5,{kind=.Text,name="trips",style=4,bind_text="Showcase.trips"}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="state",style=5,text="Running",bind_visible="Showcase.running"}),
    }
    data:=ui.Tree_Data{text=texts[:],nodes=nodes,styles=styles,images=images,anims=anims,tracks=tracks,keys=keys,anim_sets=anim_sets}
    check(o,"assets/ui/hud.ui",host.ui_tree_save(path(o,"assets/ui/hud.ui"),&o.types,id,data))
    return id
}

// The sign above the lift: its name, its bar and a button.
write_sign :: proc(o:^Out) -> base.Asset_Id {
    texts:=make([dynamic]u8,context.temp_allocator)
    id:=id_of("ui","sign")
    styles:=[]ui.Node_Style{
        {},
        {text={size=18,color=WHITE}},
        {fill={255,170,40,255},track={40,48,66,255},radius=3},
        {text={size=14,color=WHITE},fill={52,64,92,255},radius=5},
        {fill={16,22,34,235},stroke={96,118,160,255},radius=8},
    }
    sign_variants:=[2]ui.Tree_Style_Variant{
        ui.tree_variant_record(3,"",{.Hovered},{fields={.Fill},values={fill={76,94,134,255}}}),
        ui.tree_variant_record(3,"",{.Pressed},{fields={.Fill},values={fill={30,38,56,255}}}),
    }
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&texts,-1,{kind=.Box,name="sign",style=4,layout={width=ui.fixed(220),height=ui.fixed(100),direction=.Column,padding=ui.padding_all(10),gap=7}}),
        ui.tree_node_record(&texts,0,{kind=.Text,name="name",style=1,bind_text="Showcase.label"}),
        ui.tree_node_record(&texts,0,{kind=.Progress,name="charge",style=2,bind_value="Showcase.charge",layout={width=ui.fixed(200),height=ui.fixed(10)}}),
        ui.tree_node_record(&texts,0,{kind=.Button,name="toggle",style=3,text="Stop / go",layout={width=ui.fixed(110),height=ui.fixed(28)}}),
    }
    check(o,"assets/ui/sign.ui",host.ui_tree_save(path(o,"assets/ui/sign.ui"),&o.types,id,{nodes=nodes,styles=styles,variants=sign_variants[:],text=texts[:]}))
    return id
}

// The lift: its platform goes up and comes down in four seconds while its
// beacon turns once. "top" marks the highest point.
write_lift :: proc(o:^Out) -> base.Asset_Id {
    id:=id_of("animation","lift")
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
        {name="ride",tracks={{target="Platform",property=.Position,keys=rise},{target="Beacon",property=.Rotation,keys=turn}},markers={{seconds/2,"top"}}},
        {name="parked",tracks={{target="Platform",property=.Position,keys=rise[:1]}}},
    }
    check(o,"assets/animations/lift.anim",asset.animation_save(path(o,"assets/animations/lift.anim"),&o.types,{id=id,clips=clips}))
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
        o.failed=true
        return {}
    }
    report,error:=sources.import_source(source,path(o,"assets/sounds"),{root=fmt.tprintf("%s/demo",o.root)})
    if error.code!=.None {
        fmt.eprintfln("demo_content: %s",error.message)
        o.failed=true
        return {}
    }
    defer importer.report_destroy(&report)
    fmt.printfln("wrote source/sounds/hum.wav and imported %s",report.assets[0].path)
    return report.assets[0].id
}

Scene_Out :: struct {
    scene:asset.Scene,
    next:base.Entity_Id,
    failed:bool,
}

// Half a turn about +Y. A body's front is its +Z (the glTF model front): a spawn turned so looks
// along -Z, and a camera child of a body turned so looks where the body faces.
HALF_TURN :: mm.Quat(quaternion(w=0,x=0,y=1,z=0))

@(private)
entity :: proc(s:^Scene_Out,name:string,position:[3]f32={},scale:[3]f32={1,1,1},parent:base.Entity_Id=0) -> base.Entity_Id {
    s.next+=1
    id:=s.next
    if _,error:=asset.scene_entity_add(&s.scene,id,parent,name);error!=.None {s.failed=true}
    transform:=core.Transform{position,1,scale}
    put(s,id,"Transform",&transform)
    return id
}
@(private)
put :: proc(s:^Scene_Out,id:base.Entity_Id,name:string,value:^$T) {
    if asset.scene_set(&s.scene,id,name,value)!=.None {s.failed=true}
}

// Turns a component of an entity off by itself: the world loads it off.
@(private)
turn_off :: proc(s:^Scene_Out,id:base.Entity_Id,name:string) {
    if asset.scene_component_turn(&s.scene,id,base.name_hash(name),true)!=.None {s.failed=true}
}
@(private)
// The sky turned about the vertical by turn, and how the views of the scene
// expose: a View_Volume of the whole scene when it is not the default.
sky_set :: proc(s:^Scene_Out,sky:^render.Sky,turn:f32=0,exposure:=render.EXPOSURE_DEFAULT) {
    e:=entity(s,"Sky")
    placed:=core.Transform{{},mm.quat_axis_angle({0,1,0},turn),{1,1,1}}
    put(s,e,"Transform",&placed)
    put(s,e,"Sky",sky)
    if exposure==render.EXPOSURE_DEFAULT {return}
    look:=render.View_Volume{exposure=exposure,tint={1,1,1}}
    put(s,entity(s,"Exposure"),"View_Volume",&look)
}
@(private)
cube :: proc(s:^Scene_Out,id:base.Entity_Id,material:string) {
    mesh:=render.Mesh_Renderer{shape=.Cube}
    mesh.materials[0]=game.material_asset(material)
    put(s,id,"Mesh_Renderer",&mesh)
}

// A cube that the player stands on and walks into.
@(private)
solid :: proc(s:^Scene_Out,id:base.Entity_Id,material:string) {
    cube(s,id,material)
    collider:=phys.collider_box({0.5,0.5,0.5})
    put(s,id,"Collider",&collider)
}

// Where a player appears.
@(private)
spawn_point :: proc(s:^Scene_Out,position:[3]f32) {
    point:=spawn.Spawn_Point{prefab=game.PLAYER_PREFAB}
    put(s,placed(s,"Player start",position,HALF_TURN,{1,1,1}),"Spawn_Point",&point)
}

write_scene :: proc(o:^Out,hud,sign,lift,hum:base.Asset_Id) {
    s:Scene_Out
    asset.scene_init(&s.scene,&o.types,asset.KIND_SCENE,id_of("scene","showcase"))
    defer asset.scene_destroy(&s.scene)

    environment,turn,to_sun,disc:=sky_of(o,.Day,render.SUN_DIRECTION,LAMPLIT,1.6)
    // Its view is mostly sky: a stop under the meter keeps it as the demo has it.
    exposure:=render.EXPOSURE_DEFAULT
    exposure.compensation=-1
    sky_set(&s,&environment,turn,exposure)
    sun:=render.Sun{color={1,0.96,0.9},illuminance=lux(LAMPLIT,1.6),disc=disc}
    sun_entity:=entity(&s,"Sun",{0,6,0})
    pose:=sun_pose(to_sun,{0,6,0})
    put(&s,sun_entity,"Transform",&pose)
    put(&s,sun_entity,"Sun",&sun)
    lamp:=render.Point_Light{color={1,0.8,0.6},intensity=candela(LAMPLIT,12),range=14,radius=0.1}
    put(&s,entity(&s,"Lamp",{2.5,3.5,2.5}),"Point_Light",&lamp)
    solid(&s,entity(&s,"Floor",{0,-0.05,0},{14,0.1,14}),"Tiles")
    solid(&s,entity(&s,"Pillar west",{-3,1.5,-1},{0.5,3,0.5}),"Marble")
    solid(&s,entity(&s,"Pillar east",{3,1.5,-1},{0.5,3,0.5}),"Marble")
    spawn_point(&s,{0,0,5.5})

    // The Animation of the lift moves Platform and turns Beacon, found by name below it.
    root:=entity(&s,game.SHOWCASE_LIFT)
    playing:=anim.ANIMATION_DEFAULT
    playing.asset=lift
    base.text_set(playing.clip[:],"ride")
    put(&s,root,"Animation",&playing)
    platform:=entity(&s,"Platform",{0,0.1,0},{1,1,1},root)
    cube(&s,entity(&s,"Deck",{0,0,0},{2,0.2,2},platform),"Brushed steel")
    beacon:=entity(&s,"Beacon",{0,0.45,0},{0.45,0.45,0.45},platform)
    cube(&s,beacon,"Neon sign")
    shown:=game.Showcase{}
    base.text_set(shown.label[:],"Lift")
    board:=entity(&s,"Sign",{0,1.0,0},{1,1,1},platform)
    widget:=gui.WORLD_WIDGET_DEFAULT
    widget.asset,widget.size,widget.scale,widget.facing,widget.pivot=sign,{220,100},0.01,.Billboard_Upright,.Bottom_Center
    put(&s,board,"World_Widget",&widget)
    put(&s,board,"Showcase",&shown)

    screen:=gui.UI_Screen{asset=hud}
    overlay:=entity(&s,"Hud")
    put(&s,overlay,"UI_Screen",&screen)
    put(&s,overlay,"Showcase",&shown)

    speaker:=entity(&s,"Speaker",{-3,0.35,1.5},{0.7,0.7,0.7})
    cube(&s,speaker,"Lacquer")
    source:=audio.AUDIO_SOURCE_DEFAULT
    source.sound,source.loop,source.spatial,source.volume,source.max_distance=hum,true,true,0.7,25
    put(&s,speaker,"Audio_Source",&source)

    if s.failed {
        fmt.eprintln("demo_content: the scene could not be built")
        o.failed=true
        return
    }
    check(o,"assets/scenes/showcase.scene",asset.scene_save(&s.scene,path(o,"assets/scenes/showcase.scene")))
}

main :: proc() {
    o:Out
    o.root=len(os.args)>1?os.args[1]:"."
    asset.types_init(&o.types)
    defer asset.types_destroy(&o.types)
    actions_load(&o)
    if o.failed {os.exit(1)}
    for folder in ([]string{"assets/ui","assets/animations","assets/sounds","assets/textures","assets/scenes","assets/prefabs","assets/data"}) {os.make_directory_all(path(&o,folder))}
    if len(os.args)>2 && os.args[2]=="--physics-only" {
        write_destruction_scene(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--prefabs-only" {
        write_prefabs(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--control-only" {
        write_control_scene(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--portal-only" {
        write_portal_player(&o)
        if !o.failed {write_portal_chamber_scene(&o)}
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--raft-only" {
        write_raft_player(&o)
        if !o.failed {write_raft_scene(&o)}
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--features-only" {
        write_feature_scenes(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--church-only" {
        meshes:=write_feature_meshes(&o)
        if !o.failed {write_church_scene(&o,meshes,"church",false)}
        if !o.failed {write_church_scene(&o,meshes,"church_fog",true)}
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--lights-only" {
        write_lights_scene(&o)
        if !o.failed {write_night_scene(&o)}
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--animation-only" {
        import_model(&o,"mirai/mirai.glb")
        if !o.failed {write_animation_scene(&o)}
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--sky-only" {
        write_sky_scene(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--interface-only" {
        write_interface_scene(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--dig-only" {
        write_dig_scene(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--horror-only" {
        write_horror_scene(&o)
        if o.failed {os.exit(1)}
        return
    }
    if len(os.args)>2 && os.args[2]=="--ai-only" {
        write_ai_scene(&o)
        if o.failed {os.exit(1)}
        return
    }
    import_sources(&o)
    badge,panel:=write_badge(&o),write_panel(&o)
    hud,sign:=write_hud(&o,badge,panel),write_sign(&o)
    lift,hum:=write_lift(&o),write_hum(&o)
    write_prefabs(&o)
    if !o.failed {write_scene(&o,hud,sign,lift,hum)}
    if !o.failed {write_control_scene(&o)}
    if !o.failed {write_destruction_scene(&o)}
    if !o.failed {write_ai_scene(&o)}
    if !o.failed {write_animation_scene(&o)}
    if !o.failed {write_feature_scenes(&o)}
    if !o.failed {write_portal_player(&o)}
    if !o.failed {write_portal_chamber_scene(&o)}
    if !o.failed {write_raft_player(&o)}
    if !o.failed {write_raft_scene(&o)}
    if !o.failed {write_lights_scene(&o)}
    if !o.failed {write_night_scene(&o)}
    if !o.failed {write_horror_scene(&o)}
    if !o.failed {write_dig_scene(&o)}
    if !o.failed {write_interface_scene(&o)}
    if !o.failed {write_sky_scene(&o)}
    free_all(context.temp_allocator)
    if o.failed {os.exit(1)}
}
