package vfx

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
ui_effects_sync :: proc(p:^UI_Particles,requests:[]gui.UI_Effect,app:^host.App,dt:f32,shaders:u64,descs:^[dynamic]Emitter_Desc) {
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
    a:=app.assets
    if a==nil {return}
    for &effect in p.effects[:p.count] {
        effect.asked=false
        shown,clock:=&effect.shown,&effect.clock
        key:=base.hash_combine(base.hash_combine(base.hash_combine(effect.effect[0],effect.effect[1]),a.revision),shaders)|1
        if shown.resolved!=key {
            shown.info=particle_resolve(a,effect.effect,nil)
            problem:=particle_program(a,effect.effect,&shown.info,nil,&shown.program)
            shown.sub,shown.has_sub,shown.sub_program={},false,{}
            if shown.info.trigger!=.None && shown.info.sub_particle!={} {
                shown.sub=particle_resolve(a,shown.info.sub_particle,nil)
                shown.has_sub=true
                sub_problem:=particle_program(a,shown.info.sub_particle,&shown.sub,nil,&shown.sub_program)
                if problem=="" {problem=sub_problem}
            }
            base.text_set(shown.problem[:],problem)
            desc,ready:=emitter_desc(&shown.info,app.assets,app.renderer,base.hash_combine(effect.key,0x75695f7061727469))
            shown.desc=desc
            shown.desc.program,shown.desc.view=shown.program,effect.view
            shown.sub_desc={}
            if shown.has_sub {
                sub_desc,sub_ready:=emitter_desc(&shown.sub,app.assets,app.renderer,base.hash_combine(effect.key,0x75695f7375625f70))
                ready&&=sub_ready
                shown.sub_desc=sub_desc
                sub:=&shown.sub_desc
                sub.program,sub.view=shown.sub_program,effect.view
                sub.capacity+=min(shown.desc.capacity*shown.info.sub_count,1<<16)
                shown.desc.event,shown.desc.event_target,shown.desc.event_count=shown.info.trigger,sub.id,shown.info.sub_count
                alone(sub)
            }
            alone(&shown.desc)
            shown.resolved=ready?key:0
            shown.sub_desc.revision=shown.resolved
            shown.desc.revision=shown.resolved
        }
        if clock.resolved!=key {
            clock.emission=emission_of(a,&shown.info)
            clock.resolved=key
        }
        emission_step(clock,&clock.emission,true,true,{},dt)
        if clock.generation!=shown.generation {
            shown.generation=clock.generation
            shown.started=max(shown.started,clock.first)
        }
        if shown.has_sub {
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
    // Alone in its texture: nothing to collide with, fade into, light or be lit by.
    alone :: proc(desc:^Emitter_Desc) {desc.lit,desc.relative,desc.collision,desc.soft,desc.lights=false,true,.None,0,0}
}
