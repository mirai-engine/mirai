package vfx

import "mirai:core"
import "plugins:vfx/runtime/effect"
import erender "mirai:engine/render"
import gui "mirai:engine/gui"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// Effects the interfaces of the game play in a rectangle (a Particles node
// of a .ui, gui.UI_Effects): emitters of the pool of the world like any
// other, drawn only into the texture of their effect view (the Effect stage),
// never in the views of the world, with its sub effect. Each has its own
// clock, which goes with the frames, as the UI does, and loops. The UI asks for an effect in each
// frame it shows it; one it did not ask for in a frame goes with its
// particles.

// The effects the interfaces show, with their clocks.
@(storage,host,by_world,free="ui_particles_free")
UI_Particles :: struct {
    effects:[dynamic]UI_Effect,
}

ui_particles_free :: proc(p:^UI_Particles) {
    for &entry in p.effects {shown_drop(&entry.shown)}
    delete(p.effects)
    p.effects=nil
}

UI_Effect :: struct {
    using request:gui.UI_Effect,
    layer:int,
    asked:bool,             // in this frame
    clock:Emitter_Clock,
    shown:Emitter_Shown,
}

// The emitters of the effects the UI showed in this frame, put in the pool of
// the world; those it did not show go with their particles.
@(private)
ui_effects_sync :: proc(p:^UI_Particles,requests:[]gui.UI_Effect,assets:^host.Assets,
    renderer:^erender.Renderer,dt:f32,shaders:u64,sync:^Particle_Sync,
) {
    pool:=&sync.pool
    if assets!=nil {
        for request in requests {
            view,_:=effect_view(assets,request.effect)
            for layer in 0..=len(view.layers) {
                entry:=ui_effect_of(p,request,layer,pool)
                if entry==nil {continue}
                info:=&view.layers[layer-1] if layer>0 else nil
                ui_effect_tell(entry,assets,renderer,dt,shaders,sync,info)
            }
        }
    }
    for i:=len(p.effects)-1;i>=0;i-=1 {
        entry:=&p.effects[i]
        if entry.asked {entry.asked=false;continue}
        pool_remove(pool,entry.shown.desc.id)
        pool_remove(pool,entry.shown.sub_desc.id)
        shown_drop(&entry.shown)
        unordered_remove(&p.effects,i)
    }
}

@(private)
ui_effect_of :: proc(p:^UI_Particles,request:gui.UI_Effect,layer:int,pool:^Pool) -> ^UI_Effect {
    for &entry in p.effects {
        if entry.key!=request.key || entry.layer!=layer {continue}
        if entry.request!=request {
            pool_remove(pool,entry.shown.desc.id)
            pool_remove(pool,entry.shown.sub_desc.id)
            shown_drop(&entry.shown)
            entry.shown={}
            entry.request=request
            entry.clock={last=-max(f64)}
        }
        entry.asked=true
        return &entry
    }
    if resize(&p.effects,len(p.effects)+1)!=nil {return nil}
    entry:=&p.effects[len(p.effects)-1]
    entry.request=request
    entry.layer=layer
    entry.asked=true
    entry.clock.last=-max(f64)
    return entry
}

@(private)
ui_effect_tell :: proc(entry:^UI_Effect,assets:^host.Assets,renderer:^erender.Renderer,
    dt:f32,shaders:u64,sync:^Particle_Sync,info:^effect.Particle_Info,
) {
    shown,clock:=&entry.shown,&entry.clock
    key:=base.hash_combine(emission_key(entry.effect,0,assets.revision),shaders)|1
    if shown.resolved!=key {
        id:=base.hash_combine(entry.key,u64(entry.layer)+0x75695f7061727469)
        sub:=shown.sub_desc.id
        ready:=shown_resolve(shown,&sync.emitter_infos,assets,renderer,entry.effect,nil,
            {id,sub_id(core.Entity(id))},nil,info,view=entry.view,layer=u8(entry.layer))
        shown.resolved=key if ready else 0
        if sub!=0 && sub!=shown.sub_desc.id {pool_remove(&sync.pool,sub)}
    }
    if shown.desc.spec==nil {return}
    if clock.resolved!=key {
        clock.emission=emission_of(assets,&shown.desc.info)
        clock.resolved=key
    }
    emission_step(clock,&clock.emission,true,true,{},dt)
    if clock.generation!=shown.generation {
        shown.generation=clock.generation
        shown.started=max(shown.started,clock.first)
    }
    if shown.sub_desc.id!=0 {
        sub:=&shown.sub_desc
        sub.transform,sub.previous=mm.Mat4(1),mm.Mat4(1)
        sub.generation=shown.generation
        pool_put(&sync.pool,sub)
    }
    desc:=&shown.desc
    desc.transform,desc.previous=mm.Mat4(1),mm.Mat4(1)
    desc.spawns=births_since(clock,&shown.started)
    desc.generation=shown.generation
    pool_put(&sync.pool,desc)
}
