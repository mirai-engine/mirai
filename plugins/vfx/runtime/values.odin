package vfx

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "mirai:asset"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

PARTICLE_OVERRIDE_CAPACITY :: 16
PARTICLE_PARAMETER_CAPACITY :: 8

// Values of this entity alone for its effect. names are base.name_hash of a
// path of effect.Particle_Info (effect.particle_fields); values, its bytes.
// Assets an effect names belong to the effect: an instance does not change them.
@(component)
Particle_Override :: struct {
    count:u32,
    names:[PARTICLE_OVERRIDE_CAPACITY]u64,
    values:[PARTICLE_OVERRIDE_CAPACITY][effect.PARTICLE_VALUE_BYTES]u8,
}

// Values of this entity for the parameters of the Vfx program of its
// effect, by name, over those the effect stores.
@(component)
Particle_Parameters :: struct {
    count:u32,
    values:[PARTICLE_PARAMETER_CAPACITY]effect.Particle_Parameter,
}

// What went wrong with a particle request or value; error_message says how to
// correct it.
Error :: enum u8 {
    None,
    Unknown_Field,
    Type_Mismatch,
    Invalid_Value,
    Effect_Field,
    Override_Capacity,
    Missing_Override,
    Parameter_Capacity,
    Invalid_Parameter,
    Invalid_Entity,
    Asset_Not_Found,
    Asset_Kind,
}

error_message :: proc(error:Error) -> string {
    switch error {
    case .None: return ""
    case .Unknown_Field: return "Name a value of the effect by its path, as effect.particle_fields lists them: rate, colors.1, bursts.0.count"
    case .Type_Mismatch: return "Give the value in the type of its field: f32, [N]f32, u32, bool or its enum"
    case .Invalid_Value: return "Give a finite value inside the range of its field; curve key times go up from 0 to 1"
    case .Effect_Field: return "The assets and the program of an effect are the effect's: change them in the .particle (particle.set), not in an instance"
    case .Override_Capacity: return fmt.tprintf("An entity changes at most %d values of its effect: remove one first",PARTICLE_OVERRIDE_CAPACITY)
    case .Missing_Override: return "The entity does not change this value: read it from the effect"
    case .Parameter_Capacity: return fmt.tprintf("An entity gives at most %d program parameters: remove one first",PARTICLE_PARAMETER_CAPACITY)
    case .Invalid_Parameter: return "Name the parameter in fewer than 64 bytes and give one to four finite numbers its kind holds, or a texture"
    case .Invalid_Entity: return "Name a live entity that has a Particle_Emitter"
    case .Asset_Not_Found: return "Name a .particle, material or mesh of the project"
    case .Asset_Kind: return "material takes a material, mesh a mesh and sub_particle a .particle"
    }
    return ""
}

// Sets the value of the field at path for an instance: of its type, inside
// the range of the field.
override_set :: proc(override:^Particle_Override,path:string,value:$T) -> Error {
    stored:=value
    return override_set_bytes(override,path,type_info_of(T),mem.ptr_to_bytes(&stored))
}

// Sets a value whose type the caller knows by reflection (a schema, the API).
override_set_bytes :: proc(override:^Particle_Override,path:string,info:^runtime.Type_Info,bytes:[]u8) -> Error {
    field,found:=effect.particle_value_at(path)
    if !found {return .Unknown_Field}
    if field.kind==.Asset {return .Effect_Field}
    if info==nil || info.size!=field.size || len(bytes)!=field.size || !types_match(info,field.info) {return .Type_Mismatch}
    if override==nil || override.count>PARTICLE_OVERRIDE_CAPACITY {return .Invalid_Value}
    return override_put(override,base.name_hash(path),bytes)
}

@(private)
types_match :: proc(a,b:^runtime.Type_Info) -> bool {
    if a.id==b.id {return true}
    // An enum of the asset (effect.Particle_Render) and its twin of another package hold the same values.
    x,y:=runtime.type_info_base(a),runtime.type_info_base(b)
    #partial switch v in x.variant {
    case runtime.Type_Info_Enum:
        _,enum_too:=y.variant.(runtime.Type_Info_Enum)
        return enum_too && x.size==y.size
    case runtime.Type_Info_Array:
        w,array:=y.variant.(runtime.Type_Info_Array)
        return array && v.count==w.count && types_match(v.elem,w.elem)
    }
    return x.id==y.id
}

override_get :: proc(override:Particle_Override,path:string,$T:typeid) -> (value:T,error:Error) {
    field,found:=effect.particle_value_at(path)
    if !found {return value,.Unknown_Field}
    if size_of(T)!=field.size || !types_match(type_info_of(T),field.info) {return value,.Type_Mismatch}
    name:=base.name_hash(path)
    stored:=override
    for hash,i in stored.names[:min(stored.count,PARTICLE_OVERRIDE_CAPACITY)] {
        if hash==name {
            mem.copy(&value,&stored.values[i],size_of(T))
            return value,.None
        }
    }
    return value,.Missing_Override
}

override_remove :: proc(override:^Particle_Override,path:string) -> Error {
    if _,found:=effect.particle_value_at(path);!found {return .Unknown_Field}
    override_remove_hash(override,base.name_hash(path))
    return .None
}

@(private)
override_remove_hash :: proc(override:^Particle_Override,name:u64) {
    count:=int(min(override.count,PARTICLE_OVERRIDE_CAPACITY))
    for stored,i in override.names[:count] {
        if stored!=name {continue}
        copy(override.names[i:count-1],override.names[i+1:count])
        copy(override.values[i:count-1],override.values[i+1:count])
        override.names[count-1],override.values[count-1]=0,{}
        override.count=u32(count-1)
        return
    }
}

// A parameter of the program of the effect for an instance: f32, i32, u32,
// bool or arrays of up to four of them, or the base.Asset_Id of a texture.
parameter_set :: proc(parameters:^Particle_Parameters,name:string,value:$T) -> Error {
    parameter:effect.Particle_Parameter
    if error:=parameter_of(name,value,&parameter);error!=.None {return error}
    return parameter_put(parameters,&parameter)
}

@(private)
parameter_of :: proc(name:string,value:$T,parameter:^effect.Particle_Parameter) -> Error {
    parameter^={}
    if name=="" || len(name)>=effect.PARTICLE_NAME_BYTES {return .Invalid_Parameter}
    base.text_set(parameter.name[:],name)
    when T==base.Asset_Id {
        parameter.kind,parameter.components,parameter.texture=.Texture,1,value
    } else {
        number :: proc(p:^effect.Particle_Parameter,at:int,v:$E) -> bool {
            when intrinsics.type_is_float(E) {p.kind=.Float;p.value[at]=f64(v)}
            else when E==bool {p.kind=.Bool;p.value[at]=v?1:0}
            else when intrinsics.type_is_integer(E) && intrinsics.type_is_unsigned(E) {p.kind=.Uint;p.value[at]=f64(v)}
            else when intrinsics.type_is_integer(E) {p.kind=.Int;p.value[at]=f64(v)}
            else {return false}
            return true
        }
        when intrinsics.type_is_array(T) {
            if len(value)<1 || len(value)>4 {return .Type_Mismatch}
            parameter.components=u8(len(value))
            for component,i in value {
                if !number(parameter,i,component) {return .Type_Mismatch}
            }
        } else {
            parameter.components=1
            if !number(parameter,0,value) {return .Type_Mismatch}
        }
    }
    return .None
}

// Puts a parameter given whole: its name, kind, components and values.
parameter_put :: proc(parameters:^Particle_Parameters,parameter:^effect.Particle_Parameter) -> Error {
    if effect.particle_parameter_validate(parameter).message!="" {return .Invalid_Parameter}
    if parameters==nil || parameters.count>PARTICLE_PARAMETER_CAPACITY {return .Invalid_Value}
    at:=-1
    for &stored,i in parameters.values[:parameters.count] {
        if stored.name==parameter.name {at=i;break}
    }
    if at<0 {
        if parameters.count==PARTICLE_PARAMETER_CAPACITY {return .Parameter_Capacity}
        at=int(parameters.count)
        parameters.count+=1
    }
    parameters.values[at]=parameter^
    return .None
}

parameter_get :: proc(parameters:Particle_Parameters,name:string) -> (parameter:effect.Particle_Parameter,error:Error) {
    stored:=parameters
    if found:=effect.particle_parameter_find(stored.values[:min(stored.count,PARTICLE_PARAMETER_CAPACITY)],name);found!=nil {return found^,.None}
    return {},.Missing_Override
}

parameter_remove :: proc(parameters:^Particle_Parameters,name:string) {
    count:=int(min(parameters.count,PARTICLE_PARAMETER_CAPACITY))
    for &stored,i in parameters.values[:count] {
        if base.text_get(stored.name[:])!=name {continue}
        copy(parameters.values[i:count-1],parameters.values[i+1:count])
        parameters.values[count-1]={}
        parameters.count=u32(count-1)
        return
    }
}

// The values an entity shows: those of its effect (the defaults without one)
// with the ones of the entity over them. Values of the entity for fields the
// effect does not have, or for its assets, are left out.
particle_resolve :: proc(a:^host.Assets,particle:base.Asset_Id,override:^Particle_Override) -> (info:effect.Particle_Info) {
    info=effect.PARTICLE_DEFAULTS
    if a!=nil && particle!={} {
        if view,ok:=effect_view(a,particle);ok {info=view.info^}
    }
    if override==nil {return}
    for name,i in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
        value,found:=effect.particle_value_find(name)
        if !found || value.kind==.Asset {continue}
        mem.copy(rawptr(uintptr(&info)+value.offset),&override.values[i],value.size)
    }
    return
}

// particle_resolve, saying what is wrong with the effect or the values of
// the entity instead of leaving them out.
particle_resolve_checked :: proc(a:^host.Assets,particle:base.Asset_Id,override:^Particle_Override,info:^effect.Particle_Info) -> Error {
    info^=effect.PARTICLE_DEFAULTS
    if particle!={} {
        if a==nil {return .Asset_Not_Found}
        if _,found:=effect_view(a,particle);!found {return .Asset_Not_Found}
    }
    if override!=nil {
        for name in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
            value,found:=effect.particle_value_find(name)
            if !found {return .Unknown_Field}
            if value.kind==.Asset {return .Effect_Field}
        }
    }
    info^=particle_resolve(a,particle,override)
    if !effect.particle_check({info=info}) {return .Invalid_Value}
    return .None
}

// The document of an effect as its file holds it, which the assets keep open
// and read again when it changes. ok is false when it cannot be loaded, or
// its tables are not those of an effect: then a problem of the asset.
effect_view :: proc(a:^host.Assets,id:base.Asset_Id) -> (view:effect.Particle_View,ok:bool) {
    file:=host.assets_document(a,id,effect.PARTICLE_KIND)
    if file==nil {return}
    error:asset.Error
    if view,error=effect.particle_view(file,&a.types);error!=.None {
        host.assets_document_refuse(a,id,error)
        return {},false
    }
    return view,true
}

// The Vfx program of an effect, with the parameters the effect stores and
// those of an instance over them. A problem says what is missing, in
// temporary memory; the emitter then shows its effect without a program.
particle_program :: proc(a:^host.Assets,particle:base.Asset_Id,info:^effect.Particle_Info,instance:^Particle_Parameters,program:^Program,needs:^Program_Needs=nil) -> (problem:string) {
    stored:[]effect.Particle_Parameter
    if a!=nil && particle!={} {
        if view,ok:=effect_view(a,particle);ok {stored=view.parameters}
    }
    given:[]effect.Particle_Parameter
    if instance!=nil {given=instance.values[:min(instance.count,PARTICLE_PARAMETER_CAPACITY)]}
    return particle_program_check(a,info,stored,given,program,needs)
}
