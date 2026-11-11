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

// Values of this entity alone for its effect, as erender.Material_Override
// keeps those of a material: names are base.name_hash of a path of
// effect.Particle_Info (effect.particle_fields) or of a parameter of the Vfx
// program of the effect; values, the bytes of the field, or of a parameter
// its numbers as [4]f32 or the base.Asset_Id of its texture (parameter_value).
// Assets an effect names belong to the effect: an instance does not change them.
@(component)
Particle_Override :: struct {
    count:u32,
    names:[PARTICLE_OVERRIDE_CAPACITY]u64,
    values:[PARTICLE_OVERRIDE_CAPACITY][effect.PARTICLE_VALUE_BYTES]u8,
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
    Invalid_Entity,
    Asset_Not_Found,
    Asset_Kind,
}

error_message :: proc(error:Error) -> string {
    switch error {
    case .None: return ""
    case .Unknown_Field: return "Name a value of the effect by its path, as effect.particle_fields lists them (rate, colors.1, bursts.0.count), or a parameter of its Vfx program in fewer than 64 bytes"
    case .Type_Mismatch: return "Give a field a value of its type (f32, [N]f32, u32, bool or its enum), and a parameter one to four numbers or bools, or the base.Asset_Id of a texture"
    case .Invalid_Value: return "Give a finite value inside the range of its field; curve key times go up from 0 to 1"
    case .Effect_Field: return "The assets and the program of an effect are the effect's: change them in the .particle (particle.set), not in an instance"
    case .Override_Capacity: return fmt.tprintf("An entity changes at most %d values of its effect: remove one first",PARTICLE_OVERRIDE_CAPACITY)
    case .Invalid_Entity: return "Name a live entity that has a Particle_Emitter"
    case .Asset_Not_Found: return "Name a .particle, material or mesh of the project"
    case .Asset_Kind: return "material takes a material, mesh a mesh and sub_particle a .particle"
    }
    return ""
}

// Gives an instance the value of a field of its effect, by its path, of its
// type and inside its range; or of a parameter of the program of its effect,
// by its name: one to four numbers or bools, or the base.Asset_Id of a
// texture. Whether the program has that parameter is told when the emitter
// resolves it (particle_program).
value_set :: proc(override:^Particle_Override,name:string,value:$T) -> Error {
    bytes:[effect.PARTICLE_VALUE_BYTES]u8
    if field,found:=effect.particle_value_at(name);found {
        if field.kind==.Asset {return .Effect_Field}
        if size_of(T)!=field.size || !types_match(type_info_of(T),field.info) {return .Type_Mismatch}
        stored:=value
        mem.copy(&bytes,&stored,size_of(T))
    } else {
        parameter:effect.Particle_Parameter
        if error:=parameter_of(name,value,&parameter);error!=.None {return error}
        if effect.particle_parameter_validate(&parameter).message!="" {return .Invalid_Value}
        bytes=parameter_value(&parameter)
    }
    return value_put(override,base.name_hash(name),bytes[:])
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

// Takes a value away from an instance: that of its effect shows again.
value_remove :: proc(override:^Particle_Override,name:string) {value_drop(override,base.name_hash(name))}

@(private)
value_drop :: proc(override:^Particle_Override,name:u64) {
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

// Puts the bytes of a value by the hash of its name, as value_set does by the
// name: those of a field of the effect inside its range, those of a parameter
// as parameter_value gives them.
value_put :: proc(override:^Particle_Override,name:u64,bytes:[]u8) -> Error {
    if override==nil || override.count>PARTICLE_OVERRIDE_CAPACITY || len(bytes)>effect.PARTICLE_VALUE_BYTES {return .Invalid_Value}
    if field,found:=effect.particle_value_find(name);found {
        if field.kind==.Asset {return .Effect_Field}
        if len(bytes)<field.size {return .Type_Mismatch}
        candidate:=effect.PARTICLE_DEFAULTS
        mem.copy(rawptr(uintptr(&candidate)+field.offset),raw_data(bytes),field.size)
        if !effect.particle_check({info=&candidate}) {return .Invalid_Value}
    }
    at:=-1
    for stored,i in override.names[:override.count] {
        if stored==name {at=i;break}
    }
    if at<0 {
        if override.count>=PARTICLE_OVERRIDE_CAPACITY {return .Override_Capacity}
        at=int(override.count)
        override.count+=1
    }
    override.names[at]=name
    override.values[at]={}
    copy(override.values[at][:],bytes)
    return .None
}

// A parameter of a program: f32, i32, u32, bool or arrays of up to four of
// them, or the base.Asset_Id of a texture.
@(private)
parameter_of :: proc(name:string,value:$T,parameter:^effect.Particle_Parameter) -> Error {
    parameter^={}
    if name=="" || len(name)>=effect.PARTICLE_NAME_BYTES {return .Unknown_Field}
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

// The bytes of a parameter in a Particle_Override: its numbers as [4]f32, or
// its texture.
parameter_value :: proc(parameter:^effect.Particle_Parameter) -> (value:[effect.PARTICLE_VALUE_BYTES]u8) {
    if parameter.kind==.Texture {return transmute([effect.PARTICLE_VALUE_BYTES]u8)parameter.texture}
    numbers:[4]f32
    for &number,i in numbers {number=f32(parameter.value[i])}
    return transmute([effect.PARTICLE_VALUE_BYTES]u8)numbers
}

// The parameter of program a value of an instance gives, as the program
// declares it; false for a name the program does not declare.
value_parameter :: proc(program:^erender.Program,name:u64,value:[effect.PARTICLE_VALUE_BYTES]u8) -> (parameter:effect.Particle_Parameter,ok:bool) {
    for &declared in program.parameters {
        if base.name_hash(declared.name)!=name {continue}
        base.text_set(parameter.name[:],declared.name)
        parameter.kind,parameter.components=asset.Parameter_Kind(declared.kind),declared.components
        if declared.kind==.Texture {
            parameter.texture=transmute(base.Asset_Id)value
        } else {
            numbers:=transmute([4]f32)value
            for i in 0..<int(min(declared.components,4)) {parameter.value[i]=f64(numbers[i])}
        }
        return parameter,true
    }
    return
}

// The values an entity shows: those of its effect (the defaults without one)
// with the fields the entity gives over them. Its parameters, and values for
// assets, are left out.
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

// particle_resolve, saying what is wrong with the effect or the fields of
// the entity instead of leaving them out.
particle_resolve_checked :: proc(a:^host.Assets,particle:base.Asset_Id,override:^Particle_Override,info:^effect.Particle_Info) -> Error {
    info^=effect.PARTICLE_DEFAULTS
    if particle!={} {
        if a==nil {return .Asset_Not_Found}
        if _,found:=effect_view(a,particle);!found {return .Asset_Not_Found}
    }
    if override!=nil {
        for name in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
            if value,found:=effect.particle_value_find(name);found && value.kind==.Asset {return .Effect_Field}
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
// those an instance gives over them. A problem says what is missing, in
// temporary memory; the emitter then shows its effect without a program.
particle_program :: proc(a:^host.Assets,particle:base.Asset_Id,info:^effect.Particle_Info,override:^Particle_Override,program:^Program,needs:^Program_Needs=nil) -> (problem:string) {
    stored:[]effect.Particle_Parameter
    if a!=nil && particle!={} {
        if view,ok:=effect_view(a,particle);ok {stored=view.parameters}
    }
    return particle_program_check(a,info,stored,override,program,needs)
}
