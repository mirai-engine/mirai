package vfx

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

UI_EFFECT_CAPACITY :: 32

// The effects the interfaces show, with their clocks.
@(storage,host,by_world)
UI_Particles :: struct {
    effects:[UI_EFFECT_CAPACITY]UI_Effect,
    count:int,
}

UI_Effect :: struct {
    using request:gui.UI_Effect,
    asked:bool,             // in this frame
    clock:Emitter_Clock,
    shown:Emitter_Shown,
}

// The emitters of the effects the UI showed in this frame, after those of the
// world; those it did not show go. Past UI_EFFECT_CAPACITY, the last asked
// for are left out.
@(private)
ui_effects_sync :: proc(p:^UI_Particles,requests:[]gui.UI_Effect,assets:^host.Assets,renderer:^erender.Renderer,dt:f32,shaders:u64,descs:^[dynamic]Emitter_Desc) {
    each: for request in requests {
        for &effect in p.effects[:p.count] {
            if effect.key!=request.key {continue}
            if effect.request!=request {effect={request=request,clock={last=-max(f64)}}}
            effect.asked=true
            continue each
        }
        if p.count>=len(p.effects) {continue}
        p.effects[p.count]={request=request,asked=true,clock={last=-max(f64)}}
        p.count+=1
    }
    for i:=p.count-1;i>=0;i-=1 {
        if p.effects[i].asked {continue}
        p.effects[i]=p.effects[p.count-1]
        p.count-=1
    }
    a:=assets
    if a==nil {return}
    for &effect in p.effects[:p.count] {
        effect.asked=false
        shown,clock:=&effect.shown,&effect.clock
        key:=base.hash_combine(base.hash_combine(base.hash_combine(effect.effect[0],effect.effect[1]),a.revision),shaders)|1
        if shown.resolved!=key {
            ready:=shown_resolve(shown,a,renderer,effect.effect,nil,{base.hash_combine(effect.key,0x75695f7061727469),base.hash_combine(effect.key,0x75695f7375625f70)},nil)
            shown.resolved=ready?key:0
            // Alone in its texture: nothing to collide with, fade into, light or be lit by.
            for d in ([2]^Emitter_Desc{&shown.desc,&shown.sub_desc}) {
                d.view,d.revision=effect.view,shown.resolved
                d.info.lit,d.info.emission_mode,d.info.collision,d.info.soft,d.info.lights=false,.Relative,.None,0,0
            }
        }
        if clock.resolved!=key {
            clock.emission=emission_of(a,&shown.desc.info)
            clock.resolved=key
        }
        emission_step(clock,&clock.emission,true,true,{},dt)
        if clock.generation!=shown.generation {
            shown.generation=clock.generation
            shown.started=max(shown.started,clock.first)
        }
        if shown.sub_desc.id!=0 {
            sub:=shown.sub_desc
            sub.transform,sub.previous=mm.Mat4(1),mm.Mat4(1)
            sub.generation=shown.generation
            append(descs,sub)
        }
        desc:=shown.desc
        desc.transform,desc.previous=mm.Mat4(1),mm.Mat4(1)
        desc.spawns=births_since(clock,&shown.started)
        desc.generation=shown.generation
        append(descs,desc)
    }
}
