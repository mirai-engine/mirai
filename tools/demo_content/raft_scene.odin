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
    s:Scene_Out
    prefab_root(o,&s,game.RAFT_PLAYER_PREFAB,"Swimmer")
    character,capsule,walk,swim:=phys.character_default(),phys.collider_character(),game.player_walk(),phys.SWIM_DEFAULT
    diver:=game.DIVER_DEFAULT
    put(&s,1,"Character",&character)
    put(&s,1,"Walk",&walk)
    put(&s,1,"Swim",&swim)
    put(&s,1,"Collider",&capsule)
    put(&s,1,"Diver",&diver)
    eyes:=placed(&s,"Swimmer view",{0,game.EYE_HEIGHT,0},HALF_TURN,{1,1,1},1)
    put(&s,1,"Drivable",&inp.Drivable{camera=core.Entity(eyes)})
    put(&s,eyes,"Camera",&render.Camera{fov=game.VIEW_FOV,near=0.05})
    put(&s,eyes,"Audio_Listener",&audio.Audio_Listener{})
    first_person:=cam.Camera_Follow{mode=.Eyes,offset={0,game.EYE_HEIGHT,0}}
    put(&s,eyes,"Camera_Follow",&first_person)
    prefab_save(o,&s,"assets/raft/Swimmer.prefab")
}

write_raft_scene :: proc(o:^Out) {
    s:Scene_Out
    asset.scene_init(&s.scene,&o.types,asset.KIND_SCENE,id_of("scene","raft"))
    // The sun alone lights the sea: a sun of 3 is noon.
    u:=daylight(3)
    environment:=render.SKY_DEFAULT
    // The sky shows as it lights: the window of Snell from under the sea is that sky.
    environment.luminance,environment.use_background=nits(u,{.42,.56,.78}),false
    sky_set(&s,&environment,0)
    sun:=entity(&s,"Sun")
    sun_placed:=sun_pose(render.SUN_DIRECTION)
    put(&s,sun,"Transform",&sun_placed)
    put(&s,sun,"Sun",&render.Sun{color={1,0.95,0.86},illuminance=lux(u,3)})

    sea:=entity(&s,"Sea")
    volume:=phys.fluid_volume_sea(1025)
    put(&s,sea,"Fluid_Volume",&volume)
    look:=water.WATER_DEFAULT
    put(&s,sea,"Water",&look)
    // A sea the breeze raises over a long, low swell.
    swell:=phys.FLUID_WAVES_DEFAULT
    swell.wind=0.6
    swell.waves[0]={amplitude=0.25,length=18,yaw=0.4}
    put(&s,sea,"Fluid_Waves",&swell)
    breeze:=placed(&s,"Breeze",{0,4,0},mm.quat_axis_angle({0,1,0},-0.5),{1,1,1})
    put(&s,breeze,"Wind",&zone.Wind{speed=5,gusts=0.5})
    os.make_directory_all(path(o,"assets/raft"))
    // The drops a body throws up as it falls into the sea, from the channel the water writes.
    splash_effect:=effect.PARTICLE_DEFAULTS
    splash_effect.duration,splash_effect.max_particles,splash_effect.rate=1,4000,0
    splash_effect.shape,splash_effect.shape_size,splash_effect.shape_angle=.Cone,{0.4,0.05,0.4},0.6
    splash_effect.lifetime,splash_effect.speed,splash_effect.size=[2]f32{0.5,1.1},[2]f32{1.5,4},[2]f32{0.04,0.12}
    splash_effect.gravity,splash_effect.drag=1,0.4
    splash_effect.colors={{0.9,0.95,1,0.9},{0.8,0.9,0.95,0.7}}
    splash_id:=id_of("particle","raft_splash")
    check(o,"raft splash",effect.particle_save(path(o,"assets/raft/raft_splash.particle"),&o.types,{id=splash_id,info=splash_effect}))
    splashes:=entity(&s,"Splashes")
    put(&s,splashes,"Particle_Emitter",&vfx.Particle_Emitter{particle=splash_id,active=true,loop=true})
    splash_channel:=vfx.Particle_Channel{name=water.CHANNEL_SPLASHES}
    put(&s,splashes,"Particle_Channel",&splash_channel)
    // The bubbles a body leaves as it moves under the surface, which rise and wobble.
    bubble_effect:=effect.PARTICLE_DEFAULTS
    bubble_effect.duration,bubble_effect.max_particles,bubble_effect.rate=1,2000,0
    bubble_effect.shape,bubble_effect.shape_size=.Sphere,{0.2,0.2,0.2}
    bubble_effect.lifetime,bubble_effect.speed,bubble_effect.size=[2]f32{0.8,1.8},[2]f32{0,0.15},[2]f32{0.01,0.035}
    bubble_effect.acceleration,bubble_effect.drag=[3]f32{0,2.5,0},3
    bubble_effect.noise,bubble_effect.noise_frequency,bubble_effect.noise_speed=1,2,1
    bubble_effect.colors={{0.85,0.95,1,0.7},{0.7,0.88,0.95,0.5}}
    bubble_effect.soft=0.05
    bubble_id:=id_of("particle","raft_bubbles")
    check(o,"raft bubbles",effect.particle_save(path(o,"assets/raft/raft_bubbles.particle"),&o.types,{id=bubble_id,info=bubble_effect}))
    // The motes in suspension around a camera under the water, which drift and stay where they are.
    mote_effect:=effect.PARTICLE_DEFAULTS
    mote_effect.duration,mote_effect.max_particles,mote_effect.rate=1,1200,0
    mote_effect.shape,mote_effect.shape_size=.Sphere,{4,4,4}
    mote_effect.lifetime,mote_effect.speed,mote_effect.size=[2]f32{4,7},[2]f32{0,0.02},[2]f32{0.006,0.02}
    mote_effect.drag,mote_effect.noise,mote_effect.noise_frequency,mote_effect.noise_speed=1,0.05,0.5,0.2
    mote_effect.colors={{0.8,0.85,0.75,0.5},{0.6,0.7,0.6,0.35}}
    mote_effect.soft=0.05
    mote_id:=id_of("particle","raft_motes")
    check(o,"raft motes",effect.particle_save(path(o,"assets/raft/raft_motes.particle"),&o.types,{id=mote_id,info=mote_effect}))
    sand:=mm.Vec4{0.62,0.55,0.4,1}
    seabed:=sand*0.6
    seabed.a=1
    gallery_cube(&s,"Seabed",{0,-13,0},{400,2,400},seabed,true)
    // A beach that rises out of the sea to an island: wading in and out.
    beach:=placed(&s,"Beach",{28,-3,0},mm.quat_axis_angle({0,0,1},0.3),{24,2,14})
    put(&s,beach,"Mesh_Renderer",&render.Mesh_Renderer{shape=.Cube});put(&s,beach,"Tint",&render.Tint{color=sand})
    ground:=phys.COLLIDER_DEFAULT
    put(&s,beach,"Collider",&ground)
    gallery_cube(&s,"Island",{46,0.45,0},{14,2,14},sand,true)
    // A room open to the sky that stands in the sea: its air takes the sea out down to its floor.
    base_at:=mm.Vec3{-16,0,8}
    room:=entity(&s,"Dry room",base_at+{0,0.5,0})
    air:=phys.fluid_volume_dry({2.5,2,2.5})
    put(&s,room,"Fluid_Volume",&air)
    concrete:=mm.Vec4{0.55,0.55,0.53,1}
    gallery_cube(&s,"Dry room floor",base_at+{0,-1.65,0},{5.6,0.3,5.6},concrete,true)
    gallery_cube(&s,"Dry room wall east",base_at+{2.65,0.35,0},{0.3,4.3,5.6},concrete,true)
    gallery_cube(&s,"Dry room wall west",base_at+{-2.65,0.35,0},{0.3,4.3,5.6},concrete,true)
    gallery_cube(&s,"Dry room wall north",base_at+{0,0.35,-2.65},{5,4.3,0.3},concrete,true)
    gallery_cube(&s,"Dry room wall south",base_at+{0,0.35,2.65},{5,4.3,0.3},concrete,true)

    // Wood floats with a little more than half of it out of the sea.
    raft:=entity(&s,"Raft",{0,0.1,0},{3.2,0.4,2.4})
    put(&s,raft,"Mesh_Renderer",&render.Mesh_Renderer{shape=.Cube});put(&s,raft,"Tint",&render.Tint{color={0.45,0.3,0.17,1}})
    body:=phys.RIGID_BODY_DYNAMIC
    planks:=phys.collider_box({0.5,0.5,0.5})
    planks.density=450
    put(&s,raft,"Rigid_Body",&body);put(&s,raft,"Collider",&planks)
    floating :: proc(s:^Scene_Out,name:string,position,scale:mm.Vec3,shape:render.Shape,collider:phys.Collider,density:f32,color:mm.Vec4) {
        e:=entity(s,name,position,scale)
        put(s,e,"Mesh_Renderer",&render.Mesh_Renderer{shape=shape});put(s,e,"Tint",&render.Tint{color=color})
        rigid:=phys.RIGID_BODY_DYNAMIC
        collider:=collider
        collider.density=density
        put(s,e,"Rigid_Body",&rigid);put(s,e,"Collider",&collider)
    }
    floating(&s,"Crate",{4,0.4,3},{0.7,0.7,0.7},.Cube,phys.collider_box({0.5,0.5,0.5}),300,{0.7,0.55,0.3,1})
    floating(&s,"Crate 2",{-3.5,0.4,-3},{0.6,0.6,0.6},.Cube,phys.collider_box({0.5,0.5,0.5}),500,{0.6,0.45,0.25,1})
    floating(&s,"Barrel",{2.5,0.4,-3.5},{0.6,1,0.6},.Cylinder,phys.collider_cylinder(0.5,0.5),600,{0.35,0.25,0.15,1})
    floating(&s,"Stone",{-5,0.4,2},{0.5,0.5,0.5},.Sphere,phys.collider_sphere(0.5),2600,{0.5,0.5,0.52,1})

    start:=spawn.Spawn_Point{prefab=game.RAFT_PLAYER_PREFAB}
    put(&s,placed(&s,"Swimmer start",{0,0.7,0},HALF_TURN,{1,1,1}),"Spawn_Point",&start)
    holder:=entity(&s,"Raft game")
    put(&s,holder,"Raft_Game",&game.Raft_Game{raft=core.Entity(raft),deck=0.6})
    // After the others, which keep their entities.
    bubbles:=entity(&s,"Bubbles")
    put(&s,bubbles,"Particle_Emitter",&vfx.Particle_Emitter{particle=bubble_id,active=true,loop=true})
    bubble_channel:=vfx.Particle_Channel{name=water.CHANNEL_BUBBLES}
    put(&s,bubbles,"Particle_Channel",&bubble_channel)
    motes:=entity(&s,"Motes")
    put(&s,motes,"Particle_Emitter",&vfx.Particle_Emitter{particle=mote_id,active=true,loop=true})
    mote_channel:=vfx.Particle_Channel{name=water.CHANNEL_MOTES}
    put(&s,motes,"Particle_Channel",&mote_channel)
    feature_scene_end(&s,o,"raft")
}
