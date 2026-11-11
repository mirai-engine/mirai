package vfx

import "core:fmt"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

// The Vfx program of info with the parameters stored, those of the effect or
// of a file the editor did not write yet, and those an instance gives over
// them: the values of override that are not fields of the effect; needs: the
// resources and stages it declares; a channel resource reads the channel of
// its name (`//! resource displacers channel` reads "displacers").
particle_program_check :: proc(a:^host.Assets,info:^effect.Particle_Info,stored:[]effect.Particle_Parameter,override:^Particle_Override,program:^Program,needs:^Program_Needs=nil) -> (problem:string) {
    program^={}
    if needs!=nil {needs^={}}
    given:[dynamic]int
    given.allocator=context.temp_allocator
    if override!=nil {
        for name,at in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
            if _,field:=effect.particle_value_find(name);!field {append(&given,at)}
        }
    }
    name:=base.text_get(info.program[:])
    if name=="" {
        if len(stored)>0 || len(given)>0 {return "The effect has no Vfx program: name one in program before giving it parameters"}
        return ""
    }
    if a==nil || a.renderer==nil {return ""}
    found:=erender.program_find(a,name,.Vfx)
    if found==nil {return fmt.tprintf("The shaders have no Vfx program %q: add a source with `//! mirai vfx %s` to the shaders of the project",name,name)}
    program.id=found.id
    program.attributes,program.moves,program.births,program.prepare=u32(found.attributes),found.moves,found.births,found.prepare
    if needs!=nil {
        for resource,at in found.resources[:min(len(found.resources),RESOURCES)] {
            kinds:=[erender.Program_Resource_Kind]Resource_Kind{.Surface=.Surface,.Channel=.Channel,.Grid=.Grid,.Emitter=.Emitter,.Data=.Data}
            needs.resources[at]={name=base.name_hash(resource.name),kind=kinds[resource.kind],words=resource.words,channel=core.birth_channel(resource.name)}
            if resource.cleared {needs.cleared|=1<<u32(at)}
        }
        for stage,at in found.stages[:min(len(found.stages),erender.PROGRAM_STAGES)] {
            if stage.over==erender.PROGRAM_STAGE_PARTICLES {
                needs.stages[at]={kind=.Particles,iterations=stage.iterations,writes=stage.writes}
            } else {
                needs.stages[at]={kind=.Cells,over=stage.over,iterations=stage.iterations,writes=stage.writes}
            }
        }
    }
    list:=make([dynamic]effect.Particle_Parameter,0,len(stored)+len(given),context.temp_allocator)
    append(&list,..stored)
    for at in given {
        parameter,declared:=value_parameter(found,override.names[at],override.values[at])
        if !declared {
            program^={}
            return fmt.tprintf("A value of the entity names neither a field of the effect nor a parameter of Vfx program %s: particle.programs lists them",name)
        }
        append(&list,parameter)
    }
    parameters:=erender.program_defaults(found)
    for &value in list {
        parameter:=base.text_get(value.name[:])
        failure:string
        switch host.assets_program_value(a,found,&parameters,parameter,value.kind,value.value,value.texture) {
        case .None:
        case .Unknown: failure=fmt.tprintf("Vfx program %s has no parameter %q",name,parameter)
        case .Kind: failure=fmt.tprintf("Parameter %q of %s is %s",parameter,name,value.kind==.Texture?"a number, not a texture":"a texture")
        case .Range: failure=fmt.tprintf("Parameter %q of %s takes values of its kind inside its range",parameter,name)
        }
        if failure!="" {
            program^={}
            return failure
        }
    }
    program.parameters=transmute([16][4]f32)parameters
    return ""
}
