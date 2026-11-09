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
prefab_root :: proc(o:^Out,s:^Scene_Out,id:base.Asset_Id,name:string) {
    asset.scene_init(&s.scene,&o.types,asset.KIND_PREFAB,id)
    s.next=0
    root:=entity(s,name)
    s.scene.info.root=root
}

@(private)
prefab_save :: proc(o:^Out,s:^Scene_Out,file:string) {
    defer asset.scene_destroy(&s.scene)
    s.scene.info.id_counter=max(s.scene.info.id_counter,u64(s.next))
    if s.failed {
        o.failed=true
        return
    }
    check(o,file,asset.scene_save(&s.scene,path(o,file)))
}

// A camera that turns with the look of its body, 4.5 m behind a point height meters above its feet.
@(private)
behind_camera :: proc(s:^Scene_Out,name:string,height:f32) -> base.Entity_Id {
    view:=placed(s,name,{0,height,-4.5},HALF_TURN,{1,1,1},1)
    put(s,view,"Camera",&render.Camera{fov=game.VIEW_FOV,near=0.05})
    follow:=cam.CAMERA_FOLLOW_DEFAULT
    follow.offset,follow.distance,follow.half_life=[3]f32{0,height,0},4.5,0
    follow.pitch,follow.min_pitch,follow.max_pitch,follow.aim=0.3,-0.4,1.2,true
    put(s,view,"Camera_Follow",&follow)
    return view
}

// The actions of the demo project as its generator numbers them: the schema
// of what this writes names them, so data keeps an action by its name.
@(private)
actions_load :: proc(o:^Out) {
    p,error:=project.open(fmt.tprintf("%s/demo",o.root),o.root,context.temp_allocator)
    if error.code!=.None {
        fmt.eprintfln("demo_content: the demo project could not be opened: %v",error)
        o.failed=true
        return
    }
    actions,errors:=build.world_actions(&p)
    if len(errors)>0 {
        fmt.eprintfln("demo_content: the actions of the demo are not known: %v",errors)
        o.failed=true
        return
    }
    o.actions=actions
    o.types.schema.named=make(map[typeid]serial.Named)
    o.types.schema.named[inp.Action]={choices=actions,by_name=true}
    o.types.schema.named[inp.Action_Mask]={choices=actions,bits=true,by_name=true}
}

// The action of the world a member of the actions of the demo is.
@(private)
demo_action :: proc(o:^Out,member:game.Action) -> inp.Action {
    name:=strings.to_lower(fmt.tprint(member),context.temp_allocator)
    for action in o.actions {
        if action.name==name {return inp.Action(action.value)}
    }
    fmt.eprintfln("demo_content: the demo project declares no action %q",name)
    o.failed=true
    return max(inp.Action)
}

// A camera over the shoulder of the body that the seat that drives it sees
// through while it holds aim.
aim_camera :: proc(s:^Scene_Out,name:string,aim:inp.Action) {
    setup:=cam.camera_preset(.Aim)
    view:=placed(s,name,{-0.65,1.55,-1.8},HALF_TURN,{1,1,1},1)
    lens:=render.Camera{}
    cam.camera_lens_set(&lens,setup.lens)
    put(s,view,"Camera",&lens)
    follow:=setup.follow
    follow.target=core.Entity(1)
    put(s,view,"Camera_Follow",&follow)
    activation:=cam.Camera_Activation{action=aim,blend={seconds=0.25,ease=.Cubic_Out}}
    put(s,view,"Camera_Activation",&activation)
}

write_prefabs :: proc(o:^Out) {
    // The player of the scenes in first person: a camera at its eyes that looks where it looks.
    s:Scene_Out
    prefab_root(o,&s,game.PLAYER_PREFAB,"Player")
    character,capsule,walk:=phys.character_default(),phys.collider_character(),game.player_walk()
    put(&s,1,"Character",&character)
    put(&s,1,"Walk",&walk)
    put(&s,1,"Collider",&capsule)
    put(&s,1,"Player",&game.Player{})
    put(&s,1,"Replicate",&multiplayer.Replicate{priority=1,radius=1})
    put(&s,1,"Traveler",&portals.Traveler{point={0,game.EYE_HEIGHT,0}})
    eyes:=placed(&s,"Player view",{0,game.EYE_HEIGHT,0},HALF_TURN,{1,1,1},1)
    put(&s,1,"Drivable",&inp.Drivable{camera=core.Entity(eyes)})
    put(&s,eyes,"Camera",&render.Camera{fov=game.VIEW_FOV,near=0.05})
    put(&s,eyes,"Audio_Listener",&audio.Audio_Listener{})
    first_person:=cam.Camera_Follow{mode=.Eyes,offset={0,game.EYE_HEIGHT,0}}
    put(&s,eyes,"Camera_Follow",&first_person)
    prefab_save(o,&s,"assets/characters/player/Player.prefab")

    // The person and the dog of the control scene, each with a camera behind it.
    person:Scene_Out
    prefab_root(o,&person,game.PERSON_PREFAB,"Person")
    walker,walker_capsule:=phys.character_default(),phys.collider_character()
    walker.move_relative_to=.View
    put(&person,1,"Character",&walker)
    put(&person,1,"Walk",&walk)
    put(&person,1,"Collider",&walker_capsule)
    put(&person,1,"Player",&game.Player{})
    put(&person,1,"Replicate",&multiplayer.Replicate{priority=1,radius=1})
    view:=behind_camera(&person,"Person camera",1.0)
    put(&person,1,"Drivable",&inp.Drivable{camera=core.Entity(view)})
    control_visual(&person,1,false)
    aim_camera(&person,"Person aim camera",demo_action(o,.Aim))
    prefab_save(o,&person,"assets/control/Person.prefab")

    dog:Scene_Out
    prefab_root(o,&dog,game.DOG_PREFAB,"Dog")
    dog_body,dog_capsule,dog_walk:=game.dog_character(),game.dog_capsule(),game.dog_walk()
    dog_body.move_relative_to=.View
    put(&dog,1,"Character",&dog_body)
    put(&dog,1,"Walk",&dog_walk)
    put(&dog,1,"Collider",&dog_capsule)
    put(&dog,1,"Barker",&game.Barker{})
    put(&dog,1,"Replicate",&multiplayer.Replicate{priority=1,radius=1})
    dog_view:=behind_camera(&dog,"Dog camera",0.45)
    put(&dog,1,"Drivable",&inp.Drivable{camera=core.Entity(dog_view)})
    control_visual(&dog,1,true)
    prefab_save(o,&dog,"assets/control/Dog.prefab")

    thrown:Scene_Out
    prefab_root(o,&thrown,game.THROWN_CUBE,"Thrown cube")
    put(&thrown,1,"Mesh_Renderer",&render.Mesh_Renderer{shape=.Cube})
    put(&thrown,1,"Tint",&render.Tint{color={1,0.55,0.15,1},emission=game.BARK_GLOW})
    // Its glow lights around it from a light inside, as the globe of a lamp: what the
    // six faces give off, pi times their area times the glow, over the sphere.
    glow:=game.BARK_GLOW
    peak:=max(glow.x,glow.y,glow.z)
    side:=game.THROWN_CUBE_SIZE
    put(&thrown,1,"Point_Light",&render.Point_Light{color=glow/peak,intensity=1.5*side*side*peak,range=6,radius=0.6})
    body:=phys.RIGID_BODY_DYNAMIC
    collider:=phys.collider_box({0.5,0.5,0.5})
    projectile:=game.PROJECTILE_DEFAULT
    put(&thrown,1,"Rigid_Body",&body)
    put(&thrown,1,"Collider",&collider)
    put(&thrown,1,"Projectile",&projectile)
    put(&thrown,1,"Traveler",&portals.Traveler{})
    prefab_save(o,&thrown,"assets/characters/player/Thrown cube.prefab")
}
