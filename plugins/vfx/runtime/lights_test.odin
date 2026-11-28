package vfx

import "core:testing"
import erender "mirai:engine/render"
import "plugins:vfx/runtime/effect"

// The lights of particles on the CPU: what the row of an emitter tells the
// GPU of them, which emitters give them and the order that puts those of
// Light layers first. What the GPU writes and lights: gpu_test.odin
// (particle_lights_*).

// The row of an emitter carries its Particle_Light as the GPU writes each
// light: color, intensity, range, radius, its fraction within 0 and 1, the
// shares and the most lights of the emitter.
@(test)
an_emitter_row_carries_the_light_of_its_particles :: proc(t:^testing.T) {
    info:Emitter_Info
    info.info=effect.PARTICLE_DEFAULTS
    info.info.light={color={0.2,0.4,1},intensity=300,range=4,radius=0.05,fraction=0.25,max_lights=6,indirect=0.5,scattering=2}
    s:Pool_Slot
    s.desc={spec=&info,id=1,capacity=16}
    g:Gpu_Emitter
    emitter_row(&g,&s,1024)
    testing.expect_value(t,g.light,[4]f32{0.2,0.4,1,300})
    testing.expect_value(t,g.light_reach.xyz,[3]f32{4,0.05,0.25})
    testing.expect_value(t,transmute(u32)g.light_reach.w,transmute(u32)erender.light_shares(0.5,2))
    testing.expect_value(t,g.light_limit,[4]u32{6,0,max(u32),transmute(u32)f32(1)}) // no flipbook motion, at its default scale
}

// Which emitters give lights: those of a Light layer, also with no intensity
// (their program may give it), and the others while their light has an
// intensity and a range; never one drawn into an effect view.
@(test)
emitters_give_lights_by_their_layer_and_their_light :: proc(t:^testing.T) {
    Case :: struct {render:effect.Particle_Render,intensity,range:f32,view:erender.Texture_Handle,gives:bool}
    cases:=[]Case{
        {.Light,0,0,0,true},
        {.Light,100,2,0,true},
        {.Billboard,100,2,0,true},
        {.Mesh,100,2,0,true},
        {.Billboard,0,2,0,false},
        {.Billboard,100,0,0,false},
        {.Light,100,2,1,false},
    }
    for c,i in cases {
        info:Emitter_Info
        info.info.render,info.info.light.intensity,info.info.light.range=c.render,c.intensity,c.range
        d:=Emitter_Desc{spec=&info,view=c.view}
        testing.expectf(t,emitter_lights(&d)==c.gives,"case %d (%v): gives %v",i,c.render,c.gives)
    }
}

// The slots of a frame put the emitters of Light layers first, which write
// their lights in a pass before the others (particles_simulate), and a pool
// of Light layers alone draws no sprite.
@(test)
light_layers_take_the_first_slots_of_the_frame :: proc(t:^testing.T) {
    sync:=new(Particle_Sync)
    defer free(sync)
    defer particle_sync_free(sync)
    if !testing.expect(t,pool_make(&sync.pool,4096)) {return}
    sparks,beacon:Emitter_Info
    sparks.info.render,sparks.info.light.intensity,sparks.info.light.range=.Velocity,50,1
    beacon.info.render=.Light
    descs:=[4]Emitter_Desc{
        {id=1,capacity=64,spec=&sparks},
        {id=2,capacity=8,spec=&beacon},
        {id=3,capacity=64,spec=&sparks},
        {id=4,capacity=8,spec=&beacon},
    }
    for &d in descs {testing.expect(t,pool_put(&sync.pool,&d))}
    pool_kinds(&sync.pool)
    testing.expect(t,sync.pool.lights && sync.pool.light_layers && sync.pool.sprites)
    if !testing.expect(t,programs_find(sync,nil,nil)) {return}
    group:=sync.pipelines.groups[0]
    testing.expect_value(t,group.count,u32(4))
    testing.expect_value(t,group.lights,u32(2))
    for slot in sync.pool.frame_slots[:2] {
        testing.expect_value(t,sync.pool.slots[slot].desc.info.render,effect.Particle_Render.Light)
    }
    pool_remove(&sync.pool,1)
    pool_remove(&sync.pool,3)
    pool_kinds(&sync.pool)
    testing.expect(t,sync.pool.lights && !sync.pool.sprites,"Light layers alone draw no sprite")
}

// A light that an edit of the look of an effect turns on or off groups the
// emitters again: the frame asks for lights only while some emitter gives them.
@(test)
a_light_turned_on_by_an_edit_groups_the_emitters_again :: proc(t:^testing.T) {
    pool:Pool
    if !testing.expect(t,pool_make(&pool,4096)) {return}
    defer pool_free(&pool)
    dark,lit:Emitter_Info
    lit.info.light.intensity,lit.info.light.range=20,1
    desc:=Emitter_Desc{id=1,capacity=16,spec=&dark,look=1}
    testing.expect(t,pool_put(&pool,&desc))
    pool_kinds(&pool)
    pool.regroup=false
    testing.expect(t,!pool.lights)
    desc.spec,desc.look=&lit,2
    testing.expect(t,pool_put(&pool,&desc))
    testing.expect(t,pool.regroup,"the emitter gives lights now")
    pool_kinds(&pool)
    testing.expect(t,pool.lights)
}
