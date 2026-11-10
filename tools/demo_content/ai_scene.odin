package main

import "core:fmt"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import gui "mirai:engine/gui"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import phys "plugins:physics/runtime"
import nav "plugins:navigation/runtime"
import behavior "plugins:behavior/runtime"
import "mirai:std/base"
import mm "mirai:std/math"

// The AI level: the arenas of game/ai_arena.odin around a plaza where the
// player starts, each with its sign. The scene holds their places, so the
// editor builds their navigation meshes and links in Edit; their agents come
// when it runs.

AI_ARENAS :: [?]struct {kind:game.Arena_Kind,origin:mm.Vec3,agents:i32,title,detail:string}{
    {.Horde,{-75,0,-70},30,"Horde","Zombies jump between roofs and drop off ledges after the runner; three bite, the rest circle; more come in waves."},
    {.Firefight,{0,0,-70},4,"Firefight: smart objects","Squads fire by tokens, take cover a query finds, fetch ammo and health, man turrets and sound alarms."},
    {.Boss,{65,0,-70},1,"Boss: phases and combos","Attacks by score, combos below half health; a stagger interrupts all."},
    {.Swarm,{-75,0,55},16,"Swarm: flight","Drones fly the volume of the air and dive under the wall after the runner."},
    {.Paths,{0,0,55},6,"Paths: links, areas, obstacles","A ladder up, drops down, a blocked area, a fence vaulted one at a time and a cart that blocks the lane."},
    {.Senses,{65,0,55},6,"Senses: hearing, forgetting","Listeners that barely see go to the bells they hear, and forget them."},
}

WAVES_FILE :: "assets/ai/horde_waves.records"
ZOMBIES_FILE :: "assets/ai/zombie_kinds.records"

// The waves of the horde and the kinds of zombie they send: three of ten,
// so the horde ends as many as it had before it had waves.
@(private)
write_horde_records :: proc(o:^Out) {
    kinds:=[]Row_Out(game.Zombie_Kind){
        {"walker",game.ZOMBIE_KIND_DEFAULT},
        {"runner",{speed=5.5,sight=30,color={0.85,0.55,0.25,1}}},
        {"brute",{speed=2.5,sight=18,color={0.55,0.25,0.25,1}}},
    }
    write_records(o,ZOMBIES_FILE,"game.Zombie_Kind",game.Zombie_Kind,kinds)
    kind :: proc(name:string,weight:f32) -> game.Horde_Wave_Kind {return {record_ref(game.Zombie_Kind,ZOMBIES_FILE,name),weight}}
    next :: proc(name:string) -> core.Record(game.Horde_Wave) {return record_ref(game.Horde_Wave,WAVES_FILE,name)}
    waves:=[]Row_Out(game.Horde_Wave){
        {"first",{delay=10,interval=0.5,count=10,kinds={kind("walker",1),{},{},{}},next=next("second")}},
        {"second",{delay=20,interval=0.4,count=10,kinds={kind("walker",2),kind("runner",1),{},{}},next=next("last")}},
        {"last",{delay=30,interval=0.5,count=10,kinds={kind("walker",2),kind("runner",2),kind("brute",1),{}}}},
    }
    write_records(o,WAVES_FILE,"game.Horde_Wave",game.Horde_Wave,waves)
}

write_ai_scene :: proc(o:^Out) {
    write_horde_records(o)
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.content_id(PROJECT,"scene","ai"))
    defer asset.builder_destroy(&s)
    environment,turn,to_sun,disc:=sky_of(o,.Day,mm.quat_rotate(mm.quat_from_euler({-0.6,0.8,0}),render.SUN_DIRECTION),LAMPLIT,1.6)
    sky_set(&s,&environment,turn)
    sun:=render.Sun{color={1,0.96,0.9},illuminance=lux(LAMPLIT,1.6),disc=disc}
    sun_entity:=asset.builder_entity(&s,"Sun",{position={0,20,0}})
    pose:=sun_pose(to_sun,{0,20,0})
    asset.builder_set(&s,sun_entity,pose)
    asset.builder_set(&s,sun_entity,sun)
    // Below the floors of the arenas, which stand 5 cm higher.
    gallery_cube(&s,"Ground",{-15,-0.55,-7.5},{210,1,200},{0.28,0.3,0.27,1},true)
    label:=ui_id("physics_gallery_label")
    sign :: proc(s:^asset.Scene_Builder,label:base.Asset_Id,name:string,position:mm.Vec3,title,detail:string) {
        e:=asset.builder_entity(s,name,{position=position})
        text:=game.Gallery_Label{}
        base.text_set(text.title[:],title)
        base.text_set(text.detail[:],detail)
        asset.builder_set(s,e,text)
        widget:=gui.WORLD_WIDGET_DEFAULT
        widget.asset,widget.size,widget.scale,widget.passive=label,{380,88},0.012,true
        asset.builder_set(s,e,widget)
    }
    sign(&s,label,"Sign: AI level",{0,3,-6},"AI level","Navigation, decisions and senses. Editor: view mode Navigation shows tiles, links and paths.")
    for arena in AI_ARENAS {
        root:=asset.builder_entity(&s,fmt.tprintf("Arena: %s",arena.title),{position=arena.origin})
        a:=game.AI_ARENA_DEFAULT
        a.kind,a.agents,a.place=arena.kind,arena.agents,false
        asset.builder_set(&s,root,a)
        if arena.kind==.Horde {
            waves:=game.Horde_Waves{first=record_ref(game.Horde_Wave,WAVES_FILE,"first"),seed=11}
            asset.builder_set(&s,root,waves)
        }
        pieces:=make([dynamic]game.Arena_Piece,context.temp_allocator)
        game.arena_place(arena.kind,arena.origin,&pieces)
        for piece in pieces {ai_piece(&s,piece)}
        // On the side of the arena toward the plaza.
        toward:=linalg.normalize0(mm.Vec3{0,0,-arena.origin.z})
        sign(&s,label,fmt.tprintf("Sign: %s",arena.title),arena.origin+toward*20+{0,3,0},arena.title,arena.detail)
    }
    spawn_point(&s,{0,0,4})
    asset.builder_save(&s,path(o,"assets/ai/ai.scene"))
}

// A piece of an arena in the scene, as arena_piece_add puts it in a running world.
@(private)
ai_piece :: proc(s:^asset.Scene_Builder,piece:game.Arena_Piece) {
    switch piece.kind {
    case .Solid,.Cart:
        e:=asset.builder_entity(s,piece.name,{position=piece.position,scale=piece.half*2})
        asset.builder_set(s,e,render.Mesh_Renderer{shape=.Cube})
        asset.builder_set(s,e,render.Material_Values{color=piece.color})
        collider:=phys.collider_box({0.5,0.5,0.5})
        asset.builder_set(s,e,collider)
        if piece.kind==.Cart {
            rigid:=phys.RIGID_BODY_KINEMATIC
            asset.builder_set(s,e,rigid)
            asset.builder_set(s,e,nav.Nav_Obstacle{settle=1})
            asset.builder_set(s,e,volume.box({0.5,0.5,0.5}))
            asset.builder_set(s,e,game.Arena_Cart{from=piece.position,to=piece.to})
        }
    case .Area:
        e:=asset.builder_entity(s,piece.name,{position=piece.position})
        asset.builder_set(s,e,nav.Nav_Area{area=piece.area})
        asset.builder_set(s,e,volume.box(piece.half+{0,1,0}))
        slab:=asset.builder_entity(s,"Slab",{position={0,0.01,0},scale=piece.half*2},e)
        asset.builder_set(s,slab,render.Mesh_Renderer{shape=.Cube})
        asset.builder_set(s,slab,render.Material_Values{color=piece.color})
    case .Link:
        e:=asset.builder_entity(s,piece.name,{position=piece.position})
        asset.builder_set(s,e,nav.Nav_Link{end=piece.end,kind=piece.link,two_way=true,area=nav.AREA_WALKABLE,abilities=game.arena_link_abilities(piece.link)})
        if piece.offers[0].use!=behavior.USE_NONE {asset.builder_set(s,e,behavior.Smart_Object{offers={0=piece.offers[0],1=piece.offers[1]}})}
    case .Offer:
        e:=asset.builder_entity(s,piece.name,{position=piece.position})
        asset.builder_set(s,e,behavior.Smart_Object{offers={0=piece.offers[0],1=piece.offers[1]}})
    case .Air:
        e:=asset.builder_entity(s,piece.name,{position=piece.position})
        asset.builder_set(s,e,nav.Nav_Bounds{air=true})
        asset.builder_set(s,e,volume.box(piece.half))
    }
}
