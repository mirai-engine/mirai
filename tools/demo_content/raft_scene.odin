package main

import "core:os"
import "mirai:asset"
import "mirai:core"
import game "mirai:demo/game"
import audio "mirai:engine/audio"
import cam "mirai:engine/camera"
import inp "mirai:engine/input"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import mm "mirai:std/math"
import zone "mirai:engine/volume"
import "plugins:vfx/runtime/effect"
import spawn "plugins:spawn/runtime"
import vfx "plugins:vfx/runtime"
import water "plugins:water/runtime"

// A raft on the sea, a beach that rises out of it to an island, and the
// swimmer in first person, who breathes while its head is out.
write_raft_player :: proc(o:^Out) {
    s:asset.Scene_Builder
    prefab_root(o,&s,RAFT_PLAYER_PREFAB_ID,"Swimmer")
    character,capsule,walk,swim:=phys.character_default(),phys.collider_character(),game.player_walk(),phys.SWIM_DEFAULT
    diver:=game.DIVER_DEFAULT
    asset.builder_set(&s,1,character)
    asset.builder_set(&s,1,walk)
    asset.builder_set(&s,1,swim)
    asset.builder_set(&s,1,capsule)
    asset.builder_set(&s,1,diver)
    eyes:=placed(&s,"Swimmer view",{0,EYE_HEIGHT,0},1,{1,1,1},1)
    asset.builder_set(&s,1,inp.Drivable{camera=core.Entity(eyes)})
    asset.builder_set(&s,eyes,render.Camera{fov=game.VIEW_FOV,near=0.05})
    asset.builder_set(&s,eyes,audio.Audio_Listener{})
    first_person:=cam.Camera_Follow{mode=.Eyes,offset={0,EYE_HEIGHT,0}}
    asset.builder_set(&s,eyes,first_person)
    prefab_save(o,&s,"assets/raft/Swimmer.prefab")
}

write_raft_scene :: proc(o:^Out) {
    s:asset.Scene_Builder
    asset.builder_init(&s,&o.content,asset.KIND_SCENE,asset.content_id(PROJECT,"scene","raft"))
    // The sun alone lights the sea: a sun of 3 is noon.
    u:=daylight(3)
    environment:=render.SKY_DEFAULT
    // The sky shows as it lights: the window of Snell from under the sea is that sky.
    environment.luminance,environment.atmosphere,environment.use_background=nits(u,{.42,.56,.78}),false,false
    sky_set(&s,&environment,0)
    sun:=asset.builder_entity(&s,"Sun")
    sun_placed:=sun_pose(render.SUN_DIRECTION)
    asset.builder_set(&s,sun,sun_placed)
    asset.builder_set(&s,sun,render.Sun{color={1,0.95,0.86},illuminance=lux(u,3)})

    sea:=asset.builder_entity(&s,"Sea")
    volume:=phys.fluid_volume_sea(1025)
    asset.builder_set(&s,sea,volume)
    look:=water.WATER_DEFAULT
    asset.builder_set(&s,sea,look)
    // A sea the breeze raises over a long, low swell.
    swell:=phys.FLUID_WAVES_DEFAULT
    swell.wind=0.6
    swell.waves[0]={amplitude=0.25,length=18,yaw=0.4}
    asset.builder_set(&s,sea,swell)
    breeze:=placed(&s,"Breeze",{0,4,0},mm.quat_axis_angle({0,1,0},-0.5),{1,1,1})
    asset.builder_set(&s,breeze,zone.Wind{speed=5,gusts=0.5})
    os.make_directory_all(path(o,"assets/raft"))
    // The drops a body throws up as it falls into the sea, from the channel the water writes.
    splash_effect:=effect.PARTICLE_DEFAULTS
    splash_effect.duration,splash_effect.max_particles,splash_effect.rate=1,4000,0
    splash_effect.shape,splash_effect.shape_size,splash_effect.shape_angle=.Cone,{0.4,0.05,0.4},0.6
    splash_effect.lifetime,splash_effect.speed,splash_effect.size=[2]f32{0.5,1.1},[2]f32{1.5,4},[2]f32{0.04,0.12}
    splash_effect.gravity,splash_effect.drag=1,0.4
    splash_effect.colors={{0.9,0.95,1,0.9},{0.8,0.9,0.95,0.7}}
    splash_id:=asset.content_id(PROJECT,"particle","raft_splash")
    asset.content_check(&o.content,"raft splash",effect.particle_save(path(o,"assets/raft/raft_splash.particle"),&o.content.types,{id=splash_id,info=splash_effect}))
    splashes:=asset.builder_entity(&s,"Splashes")
    asset.builder_set(&s,splashes,vfx.Particle_Emitter{particle=splash_id,active=true,loop=true})
    splash_channel:=vfx.Particle_Channel{name=water.CHANNEL_SPLASHES}
    asset.builder_set(&s,splashes,splash_channel)
    // The bubbles a body leaves as it moves under the surface, which rise and wobble.
    bubble_effect:=effect.PARTICLE_DEFAULTS
    bubble_effect.duration,bubble_effect.max_particles,bubble_effect.rate=1,2000,0
    bubble_effect.shape,bubble_effect.shape_size=.Sphere,{0.2,0.2,0.2}
    bubble_effect.lifetime,bubble_effect.speed,bubble_effect.size=[2]f32{0.8,1.8},[2]f32{0,0.15},[2]f32{0.01,0.035}
    bubble_effect.acceleration,bubble_effect.drag=[3]f32{0,2.5,0},3
    bubble_effect.noise,bubble_effect.noise_frequency,bubble_effect.noise_speed=1,2,1
    bubble_effect.colors={{0.85,0.95,1,0.7},{0.7,0.88,0.95,0.5}}
    bubble_effect.soft=0.05
    bubble_id:=asset.content_id(PROJECT,"particle","raft_bubbles")
    asset.content_check(&o.content,"raft bubbles",effect.particle_save(path(o,"assets/raft/raft_bubbles.particle"),&o.content.types,{id=bubble_id,info=bubble_effect}))
    // The motes in suspension around a camera under the water, which drift and stay where they are.
    mote_effect:=effect.PARTICLE_DEFAULTS
    mote_effect.duration,mote_effect.max_particles,mote_effect.rate=1,1200,0
    mote_effect.shape,mote_effect.shape_size=.Sphere,{4,4,4}
    mote_effect.lifetime,mote_effect.speed,mote_effect.size=[2]f32{4,7},[2]f32{0,0.02},[2]f32{0.006,0.02}
    mote_effect.drag,mote_effect.noise,mote_effect.noise_frequency,mote_effect.noise_speed=1,0.05,0.5,0.2
    mote_effect.colors={{0.8,0.85,0.75,0.5},{0.6,0.7,0.6,0.35}}
    mote_effect.soft=0.05
    mote_id:=asset.content_id(PROJECT,"particle","raft_motes")
    asset.content_check(&o.content,"raft motes",effect.particle_save(path(o,"assets/raft/raft_motes.particle"),&o.content.types,{id=mote_id,info=mote_effect}))
    sand:=mm.Vec4{0.62,0.55,0.4,1}
    seabed:=sand*0.6
    seabed.a=1
    gallery_cube(&s,"Seabed",{0,-13,0},{400,2,400},seabed,true)
    // A beach that rises out of the sea to an island: wading in and out.
    beach:=placed(&s,"Beach",{28,-3,0},mm.quat_axis_angle({0,0,1},0.3),{24,2,14})
    asset.builder_set(&s,beach,render.Mesh_Renderer{shape=.Cube});asset.builder_set(&s,beach,render.Tint{color=sand})
    ground:=phys.COLLIDER_DEFAULT
    asset.builder_set(&s,beach,ground)
    gallery_cube(&s,"Island",{46,0.45,0},{14,2,14},sand,true)
    // A room open to the sky that stands in the sea: its air takes the sea out down to its floor.
    base_at:=mm.Vec3{-16,0,8}
    room:=asset.builder_entity(&s,"Dry room",{position=base_at+{0,0.5,0}})
    air:=phys.fluid_volume_dry({2.5,2,2.5})
    asset.builder_set(&s,room,air)
    concrete:=mm.Vec4{0.55,0.55,0.53,1}
    gallery_cube(&s,"Dry room floor",base_at+{0,-1.65,0},{5.6,0.3,5.6},concrete,true)
    gallery_cube(&s,"Dry room wall east",base_at+{2.65,0.35,0},{0.3,4.3,5.6},concrete,true)
    gallery_cube(&s,"Dry room wall west",base_at+{-2.65,0.35,0},{0.3,4.3,5.6},concrete,true)
    gallery_cube(&s,"Dry room wall north",base_at+{0,0.35,-2.65},{5,4.3,0.3},concrete,true)
    gallery_cube(&s,"Dry room wall south",base_at+{0,0.35,2.65},{5,4.3,0.3},concrete,true)

    // Wood floats with a little more than half of it out of the sea.
    raft:=asset.builder_entity(&s,"Raft",{position={0,0.1,0},scale={3.2,0.4,2.4}})
    asset.builder_set(&s,raft,render.Mesh_Renderer{shape=.Cube});asset.builder_set(&s,raft,render.Tint{color={0.45,0.3,0.17,1}})
    body:=phys.RIGID_BODY_DYNAMIC
    planks:=phys.collider_box({0.5,0.5,0.5})
    planks.density=450
    asset.builder_set(&s,raft,body);asset.builder_set(&s,raft,planks)
    floating :: proc(s:^asset.Scene_Builder,name:string,position,scale:mm.Vec3,shape:render.Shape,collider:phys.Collider,density:f32,color:mm.Vec4) {
        e:=asset.builder_entity(s,name,{position=position,scale=scale})
        asset.builder_set(s,e,render.Mesh_Renderer{shape=shape});asset.builder_set(s,e,render.Tint{color=color})
        rigid:=phys.RIGID_BODY_DYNAMIC
        collider:=collider
        collider.density=density
        asset.builder_set(s,e,rigid);asset.builder_set(s,e,collider)
    }
    floating(&s,"Crate",{4,0.4,3},{0.7,0.7,0.7},.Cube,phys.collider_box({0.5,0.5,0.5}),300,{0.7,0.55,0.3,1})
    floating(&s,"Crate 2",{-3.5,0.4,-3},{0.6,0.6,0.6},.Cube,phys.collider_box({0.5,0.5,0.5}),500,{0.6,0.45,0.25,1})
    floating(&s,"Barrel",{2.5,0.4,-3.5},{0.6,1,0.6},.Cylinder,phys.collider_cylinder(0.5,0.5),600,{0.35,0.25,0.15,1})
    floating(&s,"Stone",{-5,0.4,2},{0.5,0.5,0.5},.Sphere,phys.collider_sphere(0.5),2600,{0.5,0.5,0.52,1})

    start:=spawn.Spawn_Point{prefab=RAFT_PLAYER_PREFAB_ID}
    asset.builder_set(&s,placed(&s,"Swimmer start",{0,0.7,0},1,{1,1,1}),start)
    holder:=asset.builder_entity(&s,"Raft game")
    asset.builder_set(&s,holder,game.Raft_Game{raft=core.Entity(raft),deck=0.6})
    // After the others, which keep their entities.
    bubbles:=asset.builder_entity(&s,"Bubbles")
    asset.builder_set(&s,bubbles,vfx.Particle_Emitter{particle=bubble_id,active=true,loop=true})
    bubble_channel:=vfx.Particle_Channel{name=water.CHANNEL_BUBBLES}
    asset.builder_set(&s,bubbles,bubble_channel)
    motes:=asset.builder_entity(&s,"Motes")
    asset.builder_set(&s,motes,vfx.Particle_Emitter{particle=mote_id,active=true,loop=true})
    mote_channel:=vfx.Particle_Channel{name=water.CHANNEL_MOTES}
    asset.builder_set(&s,motes,mote_channel)
    feature_scene_end(&s,o,"raft")
}
