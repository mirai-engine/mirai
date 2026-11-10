package main

import "mirai:asset"
import "core:fmt"
import "mirai:core"
import build "mirai:cook/build"
import game "mirai:demo/game"
import audio "mirai:engine/audio"
import inp "mirai:engine/input"
import multiplayer "plugins:multiplayer/runtime"
import cam "mirai:engine/camera"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import "core:strings"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import portals "plugins:portals/runtime"

// The prefabs the game spawns: the bodies the spawn points of the scenes give
// the seats of the spawn library, which the network replicates, and the
// cube the player throws.

@(private)
prefab_root :: proc(o:^Out,s:^asset.Scene_Builder,id:base.Asset_Id,name:string) {
    asset.builder_init(s,&o.content,id)
    s.next=0
    asset.builder_entity(s,name)
}

// The ids the scenes this tool writes name these prefabs by: game code names them by path.
PLAYER_PREFAB_ID :: base.Asset_Id{0x6d69726169646d6f,0x706c617965720001}
PERSON_PREFAB_ID :: base.Asset_Id{0x6d69726169646d6f,0x6e6574706572736f}
DOG_PREFAB_ID :: base.Asset_Id{0x6d69726169646d6f,0x6e6574646f670003}
THROWN_CUBE_ID :: base.Asset_Id{0x6d69726169646d6f,0x7468726f776e0002}
RAFT_PLAYER_PREFAB_ID :: base.Asset_Id{0x6d69726169646d6f,0x7261667400000001}
PORTAL_PLAYER_PREFAB_ID :: base.Asset_Id{0x6d69726169646d6f,0x706f7274616c0005}
PHYSICS_GALLERY_BURST_ID :: base.Asset_Id{0x6d697261695f7068,0x79735f6275727374}

@(private)
prefab_save :: proc(o:^Out,s:^asset.Scene_Builder,file:string) {
    defer asset.builder_destroy(s)
    s.scene.info.id_counter=max(s.scene.info.id_counter,u64(s.next))
    asset.builder_save(s,path(o,file))
}

// A camera that turns with the look of its body, 4.5 m behind a point height meters above its feet.
@(private)
behind_camera :: proc(s:^asset.Scene_Builder,name:string,height:f32) -> base.Entity_Id {
    view:=placed(s,name,{0,height,4.5},1,{1,1,1},1)
    asset.builder_set(s,view,render.Camera{fov=game.VIEW_FOV,near=0.05})
    follow:=cam.CAMERA_FOLLOW_DEFAULT
    follow.offset,follow.distance,follow.half_life=[3]f32{0,height,0},4.5,0
    follow.pitch,follow.min_pitch,follow.max_pitch,follow.aim=0.3,-0.4,1.2,true
    asset.builder_set(s,view,follow)
    return view
}

// The actions of the demo project as its generator numbers them: the schema
// of what this writes names them, so data keeps an action by its name.
@(private)
actions_load :: proc(o:^Out) {
    p,error:=project.open(fmt.tprintf("%s/demo",o.root),o.root,context.temp_allocator)
    if error.code!=.None {
        fmt.eprintfln("demo_content: the demo project could not be opened: %v",error)
        o.content.failed=true
        return
    }
    actions,errors:=build.world_actions(&p)
    if len(errors)>0 {
        fmt.eprintfln("demo_content: the actions of the demo are not known: %v",errors)
        o.content.failed=true
        return
    }
    o.actions=actions
    o.content.types.schema.named=make(map[typeid]serial.Named)
    o.content.types.schema.named[inp.Action]={choices=actions,by_name=true}
    o.content.types.schema.named[inp.Action_Mask]={choices=actions,bits=true,by_name=true}
}

// The action of the world a member of the actions of the demo is.
@(private)
demo_action :: proc(o:^Out,member:game.Action) -> inp.Action {
    name:=strings.to_lower(fmt.tprint(member),context.temp_allocator)
    for action in o.actions {
        if action.name==name {return inp.Action(action.value)}
    }
    fmt.eprintfln("demo_content: the demo project declares no action %q",name)
    o.content.failed=true
    return max(inp.Action)
}

// A camera over the shoulder of the body that the seat that drives it sees
// through while it holds aim.
aim_camera :: proc(s:^asset.Scene_Builder,name:string,aim:inp.Action) {
    setup:=cam.camera_preset(.Aim)
    view:=placed(s,name,{0.65,1.55,1.8},1,{1,1,1},1)
    lens:=render.Camera{}
    cam.camera_lens_set(&lens,setup.lens)
    asset.builder_set(s,view,lens)
    follow:=setup.follow
    follow.target=core.Entity(1)
    asset.builder_set(s,view,follow)
    activation:=cam.Camera_Activation{action=aim,blend={seconds=0.25,ease=.Cubic_Out}}
    asset.builder_set(s,view,activation)
}

write_prefabs :: proc(o:^Out) {
    // The player of the scenes in first person: a camera at its eyes that looks where it looks.
    s:asset.Scene_Builder
    prefab_root(o,&s,PLAYER_PREFAB_ID,"Player")
    character,capsule,walk:=phys.character_default(),phys.collider_character(),game.player_walk()
    asset.builder_set(&s,1,character)
    asset.builder_set(&s,1,walk)
    asset.builder_set(&s,1,capsule)
    asset.builder_set(&s,1,game.Player{})
    asset.builder_set(&s,1,multiplayer.Replicate{priority=1,radius=1})
    asset.builder_set(&s,1,portals.Traveler{point={0,EYE_HEIGHT,0}})
    eyes:=placed(&s,"Player view",{0,EYE_HEIGHT,0},1,{1,1,1},1)
    asset.builder_set(&s,1,inp.Drivable{camera=core.Entity(eyes)})
    asset.builder_set(&s,eyes,render.Camera{fov=game.VIEW_FOV,near=0.05})
    asset.builder_set(&s,eyes,audio.Audio_Listener{})
    first_person:=cam.Camera_Follow{mode=.Eyes,offset={0,EYE_HEIGHT,0}}
    asset.builder_set(&s,eyes,first_person)
    prefab_save(o,&s,"assets/characters/player/Player.scene")

    // The person and the dog of the control scene, each with a camera behind it.
    person:asset.Scene_Builder
    prefab_root(o,&person,PERSON_PREFAB_ID,"Person")
    walker,walker_capsule:=phys.character_default(),phys.collider_character()
    walker.move_relative_to=.View
    asset.builder_set(&person,1,walker)
    asset.builder_set(&person,1,walk)
    asset.builder_set(&person,1,walker_capsule)
    asset.builder_set(&person,1,game.Player{})
    asset.builder_set(&person,1,multiplayer.Replicate{priority=1,radius=1})
    view:=behind_camera(&person,"Person camera",1.0)
    asset.builder_set(&person,1,inp.Drivable{camera=core.Entity(view)})
    control_visual(&person,1,false)
    aim_camera(&person,"Person aim camera",demo_action(o,.Aim))
    prefab_save(o,&person,"assets/control/Person.scene")

    dog:asset.Scene_Builder
    prefab_root(o,&dog,DOG_PREFAB_ID,"Dog")
    dog_body,dog_capsule,dog_walk:=game.dog_character(),game.dog_capsule(),game.dog_walk()
    dog_body.move_relative_to=.View
    asset.builder_set(&dog,1,dog_body)
    asset.builder_set(&dog,1,dog_walk)
    asset.builder_set(&dog,1,dog_capsule)
    asset.builder_set(&dog,1,game.Barker{})
    asset.builder_set(&dog,1,multiplayer.Replicate{priority=1,radius=1})
    dog_view:=behind_camera(&dog,"Dog camera",0.45)
    asset.builder_set(&dog,1,inp.Drivable{camera=core.Entity(dog_view)})
    control_visual(&dog,1,true)
    prefab_save(o,&dog,"assets/"+game.DOG_PREFAB)

    thrown:asset.Scene_Builder
    prefab_root(o,&thrown,THROWN_CUBE_ID,"Thrown cube")
    asset.builder_set(&thrown,1,render.Mesh_Renderer{shape=.Cube})
    asset.builder_set(&thrown,1,render.Material_Values{color={1,0.55,0.15,1},emission=game.BARK_GLOW})
    // Its glow lights around it from a light inside, as the globe of a lamp: what the
    // six faces give off, pi times their area times the glow, over the sphere.
    glow:=game.BARK_GLOW
    peak:=max(glow.x,glow.y,glow.z)
    side:=game.THROWN_CUBE_SIZE
    asset.builder_set(&thrown,1,render.Point_Light{color=glow/peak,intensity=1.5*side*side*peak,range=6,radius=0.6})
    body:=phys.RIGID_BODY_DYNAMIC
    collider:=phys.collider_box({0.5,0.5,0.5})
    projectile:=game.PROJECTILE_DEFAULT
    asset.builder_set(&thrown,1,body)
    asset.builder_set(&thrown,1,collider)
    asset.builder_set(&thrown,1,projectile)
    asset.builder_set(&thrown,1,portals.Traveler{})
    prefab_save(o,&thrown,"assets/"+game.THROWN_CUBE)
}
