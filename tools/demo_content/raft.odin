package main

import "core:os"
import "mirai:asset"
import "plugins:vfx/runtime/effect"

// The particles of the sea of the raft scene.
write_raft_particles :: proc(o:^Out) {
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
}
