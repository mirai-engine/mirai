package vfx

import "core:fmt"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

// The Vfx program of info, of layer of its effect, with the parameters
// stored, those of the effect or of a file the editor did not write yet, and
// those an instance gives over them: the values of override that are not
// fields of the effect, those of the layer and those of no layer its program
// declares; needs: the resources and stages it declares; a channel resource
// reads the channel of its name (`//! resource displacers channel` reads
// "displacers"). layers: the values of every layer of the effect, which say
// whether a parameter of no layer is some program's.
particle_program_check :: proc(a:^host.Assets,info:^effect.Particle_Info,stored:[]effect.Particle_Parameter,override:^Particle_Override,program:^Program,needs:^Program_Needs=nil,layer:u8=0,layers:[]effect.Particle_Info=nil) -> (problem:string) {
    program^={}
    if needs!=nil {needs^={}}
    given,shared:[dynamic]int
    given.allocator,shared.allocator=context.temp_allocator,context.temp_allocator
    if override!=nil {
        for name,at in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
            if _,field:=effect.particle_value_find(name);field {continue}
            if override.layers[at]==0 {append(&shared,at)} else if override.layers[at]==layer+1 {append(&given,at)}
        }
    }
    name:=base.text_get(info.program[:])
    stored_count:=0
    for &value in stored {stored_count+=1 if value.layer==layer else 0}
    found:^erender.Program
    if name!="" && a!=nil && a.renderer!=nil {found=erender.program_find(a,name,.Vfx)}
    // A parameter of no layer: of each layer whose program declares it; the
    // primary layer says so when none does.
    for at in shared {
        if found!=nil {
            if _,declared:=value_parameter(found,override.names[at],override.values[at]);declared {append(&given,at);continue}
        }
        if layer==0 && !layers_declare(a,layers,override.names[at]) {append(&given,at)}
    }
    if name=="" {
        if stored_count>0 || len(given)>0 {return "The effect has no Vfx program: name one in program before giving it parameters"}
        return ""
    }
    if a==nil || a.renderer==nil {return ""}
    if found==nil {return fmt.tprintf("The shaders have no Vfx program %q: add a source with `//! mirai vfx %s` to the shaders of the project",name,name)}
    // Its births are counted on the GPU: nothing of the effect says how many live at once.
    if found.births && info.max_particles==0 {
        return fmt.tprintf("Vfx program %s gives the births of its emitter: say in max_particles of the effect how many particles live at once",name)
    }
    program.id=found.id
    program.attributes,program.moves,program.births,program.prepare=u32(found.attributes),found.moves,found.births,found.prepare
    if needs!=nil {
        for resource,at in found.resources[:min(len(found.resources),RESOURCES)] {
            kinds:=[erender.Program_Resource_Kind]Resource_Kind{.Surface=.Surface,.Channel=.Channel,.Grid=.Grid,.Bones=.Bones}
            needs.resources[at]={name=base.name_hash(resource.name),kind=kinds[resource.kind],channel=core.birth_channel(resource.name)}
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
    list:=make([dynamic]effect.Particle_Parameter,0,stored_count+len(given),context.temp_allocator)
    for &value in stored {if value.layer==layer {append(&list,value)}}
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

// Whether the program of some layer declares the parameter of a name.
@(private)
layers_declare :: proc(a:^host.Assets,layers:[]effect.Particle_Info,name:u64) -> bool {
    if a==nil || a.renderer==nil {return false}
    for &each in layers {
        program:=base.text_get(each.program[:])
        if program=="" {continue}
        if found:=erender.program_find(a,program,.Vfx);found!=nil {
            if _,declared:=value_parameter(found,name,{});declared {return true}
        }
    }
    return false
}
