package vfx_editor

import "base:runtime"
import "core:fmt"
import "mirai:core"
import "mirai:editor"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// What the audit of the playtest plugin is told of the emitters of a world:
// an effect whose Vfx program the shaders do not have (it draws without it,
// often nothing), the emitters with particles alive and the box they draw in,
// and the frames that leave one of them out so that the pixels it drew count.

@(storage)
Vfx_Audit :: struct {provider:editor.Audit_Provider}
VFX_AUDIT_DEFAULT :: Vfx_Audit{provider={audit=vfx_audit,shown=vfx_audit_shown,leave_out=vfx_audit_leave_out}}

@(private)
vfx_audit :: proc(s:^editor.Session,w:core.World_Ref,out:^[dynamic]editor.Audit_Finding,allocator:runtime.Allocator) {
    emitters:=core.world_table_of(w,vfx.Particle_Emitter)
    a:=s.app.assets if s.app!=nil else nil
    if emitters==nil || a==nil || a.renderer==nil {return}
    // One finding for each effect and layer, at its first emitter.
    Missing :: struct {particle:base.Asset_Id,layer:int,entity:core.Entity,count:int,problem:string}
    missing:=make([dynamic]Missing,context.temp_allocator)
    for &emitter,row in emitters.values[:core.count(emitters)] {
        e:=emitters.entities[row]
        override,_:=editor.entity_get(w,e,vfx.Particle_Override)
        layers:=1
        if emitter.particle!={} {
            if view,found:=vfx.effect_view(a,emitter.particle);found {layers=1+len(view.layers)}
        }
        effect_layers: for layer in 0..<layers {
            info:effect.Particle_Info
            if vfx.particle_resolve_checked(a,emitter.particle,&override,&info,emitter.preset,u8(layer))!=.None {continue}
            program:vfx.Program
            problem:=vfx.particle_program(a,emitter.particle,&info,&override,&program,layer=u8(layer))
            if problem=="" {continue}
            for &m in missing {
                if m.particle==emitter.particle && m.layer==layer {m.count+=1;continue effect_layers}
            }
            append(&missing,Missing{emitter.particle,layer,e,1,fmt.aprint(problem,allocator=allocator)})
        }
    }
    for m in missing {
        layer:=fmt.tprintf(" layer %d",m.layer) if m.layer>0 else ""
        append(out,editor.Audit_Finding{severity=.Error,area=.Render,entity=m.entity,code="render.particle_program",
            message=fmt.aprintf("%s%s names a Vfx program the shaders do not have, so it draws without it, usually nothing (%d emitters): %s",editor.asset_path(s,m.particle),layer,m.count,m.problem,allocator=allocator),
            fix="material.program.check says why its source does not compile; fix it, or name a program the shaders have"})
    }
}

// The emitters of w with particles alive, neither hidden nor culled, and the
// box they are drawn in.
@(private)
vfx_audit_shown :: proc(s:^editor.Session,w:core.World_Ref,out:^[dynamic]editor.Audit_Shown,allocator:runtime.Allocator) {
    emitters:=core.world_table_of(w,vfx.Particle_Emitter)
    clocks:=core.world_storage_of(w,vfx.Particle_Clocks)
    if emitters==nil || clocks==nil || s.app==nil {return}
    sync:=host.app_world_storage(s.app,w.data,vfx.Particle_Sync)
    if sync==nil {return}
    hidden,parents:=core.world_table_of(w,erender.Hidden),core.world_table_of(w,core.Parent)
    for &emitter,row in emitters.values[:core.count(emitters)] {
        e:=emitters.entities[row]
        if core.row_off(emitters,row) || erender.is_hidden(hidden,parents,e) {continue}
        status,found:=vfx.status(clocks,emitter,e)
        if !found || !status.alive || status.state==.Culled || status.state==.Done {continue}
        low,high,boxed:=vfx.emitter_box(&sync.pool,e)
        if !boxed {continue}
        append(out,editor.Audit_Shown{entity=e,low=low,high=high,what=fmt.aprint(editor.asset_path(s,emitter.particle),allocator=allocator)})
    }
}

@(private)
vfx_audit_leave_out :: proc(s:^editor.Session,w:core.World_Ref,e:core.Entity) {
    if s.app==nil {return}
    if sync:=host.app_world_storage(s.app,w.data,vfx.Particle_Sync);sync!=nil {sync.pool.left_out=e}
}
