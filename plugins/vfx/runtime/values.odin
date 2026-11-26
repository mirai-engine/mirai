package vfx

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/effect"

PARTICLE_OVERRIDE_CAPACITY :: 16
PARTICLE_PARAMETER_PATH :: "parameters." // a parameter of the program of an effect, by its name after it, as the file's table names it
PARTICLE_LAYER_PATH :: "layers."         // then the layer (0 the primary) and a path of that layer: "layers.1.rate", "layers.2.parameters.heat"

// Values of this entity alone for its effect, as erender.Material_Override
// keeps those of a material: names are base.name_hash of a path of
// effect.Particle_Info (effect.particle_fields) or of a parameter of the Vfx
// program of the effect (parameter_hash: "parameters.heat"); values, the
// bytes of the field, or of a parameter its numbers as [4]f32 or the
// base.Asset_Id of its texture (parameter_value). A path without
// "layers.N." is of the primary layer, but a parameter, which every layer
// whose program declares it takes; layers keeps the layer a path names, + 1.
// Assets an effect names belong to the effect: an instance does not change them.
@(component)
Particle_Override :: struct {
    count:u32,
    names:[PARTICLE_OVERRIDE_CAPACITY]u64,
    values:[PARTICLE_OVERRIDE_CAPACITY][effect.PARTICLE_VALUE_BYTES]u8,
    layers:[PARTICLE_OVERRIDE_CAPACITY]u8, // 0: of no layer named
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
    case .Unknown_Field: return fmt.tprintf("Name a value of the effect by its path, as effect.particle_fields lists them (rate, colors.1, bursts.0.count), or a parameter of its Vfx program as parameters. and its name in fewer than 64 bytes (parameters.heat); layers.N. before either names layer N, below %d (layers.1.rate)",effect.PARTICLE_LAYERS)
    case .Type_Mismatch: return "Give a field a value of its type (f32, [N]f32, u32, bool or its enum), and a parameter one to four numbers or bools, or the base.Asset_Id of a texture"
    case .Invalid_Value: return "Give a finite value inside the range of its field; curve key times go up from 0 to 1"
    case .Effect_Field: return "The assets and the program of an effect are the effect's: change them in the .particle (particle.set), not in an instance"
    case .Override_Capacity: return fmt.tprintf("An entity changes at most %d values of its effect: remove one first",PARTICLE_OVERRIDE_CAPACITY)
    case .Invalid_Entity: return "Name a live entity that has a Particle_Emitter"
    case .Asset_Not_Found: return "Name a .particle, material or mesh of the project"
    case .Asset_Kind: return "material takes a material, meshes take meshes and sub_particle a .particle"
    }
    return ""
}

// Gives an instance the value of a field of its effect, by its path, of its
// type and inside its range; or of a parameter of the program of its effect,
// by "parameters." and its name: one to four numbers or bools, or the
// base.Asset_Id of a texture. Whether the program has that parameter is told
// when the emitter resolves it (particle_program).
value_set :: proc(override:^Particle_Override,name:string,value:$T,resolved:^effect.Particle_Info=nil) -> Error {
    bytes:[effect.PARTICLE_VALUE_BYTES]u8
    path,layer,named:=value_layer(name)
    if !named {return .Unknown_Field}
    if error:=value_encode(path,value,&bytes);error!=.None {return error}
    return value_put(override,base.name_hash(path),bytes[:],resolved,layer)
}

#assert(effect.PARTICLE_LAYERS<=100) // a layer is named by up to two digits

// The path of a value inside the layer it names, and that layer + 1 (0: no
// layer named); false for a layer the effect cannot have.
@(private)
value_layer :: proc(name:string) -> (path:string,layer:u8,ok:bool) {
    if !strings.has_prefix(name,PARTICLE_LAYER_PATH) {return name,0,true}
    rest:=name[len(PARTICLE_LAYER_PATH):]
    dot:=strings.index_byte(rest,'.')
    if dot<1 || dot>2 || dot==2 && rest[0]=='0' {return}
    index:=0
    for c in transmute([]u8)rest[:dot] {
        if c<'0' || c>'9' {return}
        index=index*10+int(c-'0')
    }
    if index>=effect.PARTICLE_LAYERS {return}
    return rest[dot+1:],u8(index+1),true
}

@(private)
value_encode :: proc(name:string,value:$T,bytes:^[effect.PARTICLE_VALUE_BYTES]u8) -> Error {
    if strings.has_prefix(name,PARTICLE_PARAMETER_PATH) {
        parameter:effect.Particle_Parameter
        if error:=parameter_of(name[len(PARTICLE_PARAMETER_PATH):],value,&parameter);error!=.None {return error}
        if effect.particle_parameter_validate(&parameter).message!="" {return .Invalid_Value}
        bytes^=parameter_value(&parameter)
    } else {
        field,found:=effect.particle_value_at(name)
        if !found {return .Unknown_Field}
        if field.kind==.Asset {return .Effect_Field}
        if size_of(T)!=field.size || !types_match(type_info_of(T),field.info) {return .Type_Mismatch}
        stored:=value
        mem.copy(bytes,&stored,size_of(T))
        if !effect.particle_field_valid(field,bytes[:]) {return .Invalid_Value}
    }
    return .None
}

// The name of a parameter of the program of an effect in a Particle_Override.
parameter_hash :: proc(name:string) -> u64 {return base.name_hash(fmt.tprintf("%s%s",PARTICLE_PARAMETER_PATH,name))}

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
value_remove :: proc(override:^Particle_Override,name:string) {
    if path,layer,named:=value_layer(name);named {value_drop(override,base.name_hash(path),layer)}
}

@(private)
value_drop :: proc(override:^Particle_Override,name:u64,layer:u8=0) {
    count:=int(min(override.count,PARTICLE_OVERRIDE_CAPACITY))
    for stored,i in override.names[:count] {
        if stored!=name || override.layers[i]!=layer {continue}
        copy(override.names[i:count-1],override.names[i+1:count])
        copy(override.values[i:count-1],override.values[i+1:count])
        copy(override.layers[i:count-1],override.layers[i+1:count])
        override.names[count-1],override.values[count-1],override.layers[count-1]=0,{},0
        override.count=u32(count-1)
        return
    }
}

// Whether some value of an override may change a layer (0 the primary): one
// of that layer, or a parameter of no layer, which its program may declare.
@(private)
override_reaches :: proc(override:^Particle_Override,layer:u8) -> bool {
    for name,at in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
        if value_of_layer(override,at,layer) {return true}
        if _,field:=effect.particle_value_find(name);!field && override.layers[at]==0 {return true}
    }
    return false
}

// Whether the value at of an override is of a layer (0 the primary): one that
// names it, or a field that names none for the primary layer.
@(private)
value_of_layer :: proc "contextless" (override:^Particle_Override,at:int,layer:u8) -> bool {
    named:=override.layers[at]
    return named==layer+1 || named==0 && layer==0
}

// Puts the bytes of a value by the hash of its name, as value_set does by the
// name: those of a field of the effect inside its range, those of a parameter
// as parameter_value gives them. layer: the layer its path names + 1, 0 for
// none (value_layer); resolved: the values of that layer.
value_put :: proc(override:^Particle_Override,name:u64,bytes:[]u8,resolved:^effect.Particle_Info=nil,layer:u8=0) -> Error {
    if override==nil || override.count>PARTICLE_OVERRIDE_CAPACITY || len(bytes)>effect.PARTICLE_VALUE_BYTES || int(layer)>effect.PARTICLE_LAYERS {return .Invalid_Value}
    if field,found:=effect.particle_value_find(name);found {
        if field.kind==.Asset {return .Effect_Field}
        if len(bytes)<field.size {return .Type_Mismatch}
        if resolved!=nil {
            candidate:=resolved^
            mem.copy(rawptr(uintptr(&candidate)+field.offset),raw_data(bytes),field.size)
            if !effect.particle_check({info=candidate}) {return .Invalid_Value}
        } else if !effect.particle_field_valid(field,bytes) {return .Invalid_Value}
    }
    at:=-1
    for stored,i in override.names[:override.count] {
        if stored==name && override.layers[i]==layer {at=i;break}
    }
    if at<0 {
        if override.count>=PARTICLE_OVERRIDE_CAPACITY {return .Override_Capacity}
        at=int(override.count)
        override.count+=1
    }
    override.names[at],override.layers[at]=name,layer
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
        if parameter_hash(declared.name)!=name {continue}
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

// The values an entity shows of a layer of its effect (0 the primary): those
// of the effect (the defaults without one) with the fields the entity gives
// that layer over them. Its parameters, and values for assets, are left out.
particle_resolve :: proc(a:^host.Assets,particle:base.Asset_Id,override:^Particle_Override,preset:=effect.Particle_Preset.Default,layer:u8=0) -> (info:effect.Particle_Info) {
    info=effect.particle_preset(preset)
    if a!=nil && particle!={} {
        if view,ok:=effect_view(a,particle);ok {
            info=view.info
            if layer>0 && int(layer)<=len(view.layers) {info=view.layers[layer-1]}
        }
    }
    if override==nil {return}
    for name,i in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
        if !value_of_layer(override,i,layer) {continue}
        value,found:=effect.particle_value_find(name)
        if !found || value.kind==.Asset {continue}
        mem.copy(rawptr(uintptr(&info)+value.offset),&override.values[i],value.size)
    }
    return
}

// particle_resolve, saying what is wrong with the effect or the fields of
// the entity instead of leaving them out.
particle_resolve_checked :: proc(a:^host.Assets,particle:base.Asset_Id,override:^Particle_Override,info:^effect.Particle_Info,preset:=effect.Particle_Preset.Default,layer:u8=0) -> Error {
    info^=effect.particle_preset(preset)
    if particle!={} {
        if a==nil {return .Asset_Not_Found}
        if _,found:=effect_view(a,particle);!found {return .Asset_Not_Found}
    }
    if override!=nil {
        for name in override.names[:min(override.count,PARTICLE_OVERRIDE_CAPACITY)] {
            if value,found:=effect.particle_value_find(name);found && value.kind==.Asset {return .Effect_Field}
        }
    }
    info^=particle_resolve(a,particle,override,preset,layer)
    if !effect.particle_check({info=info^}) {return .Invalid_Value}
    return .None
}

// The document of an effect as its file holds it, which the assets keep open
// and read again when it changes. ok is false when it cannot be loaded, or
// its tables are not those of an effect: then a problem of the asset.
effect_view :: proc(a:^host.Assets,id:base.Asset_Id) -> (view:effect.Particle_Desc,ok:bool) {
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
particle_program :: proc(a:^host.Assets,particle:base.Asset_Id,info:^effect.Particle_Info,override:^Particle_Override,program:^Program,needs:^Program_Needs=nil,layer:u8=0) -> (problem:string) {
    stored:[]effect.Particle_Parameter
    others:[effect.PARTICLE_LAYERS]effect.Particle_Info
    count:=0
    if a!=nil && particle!={} {
        if view,ok:=effect_view(a,particle);ok {
            stored=view.parameters
            others[0]=view.info
            copy(others[1:],view.layers)
            count=1+min(len(view.layers),effect.PARTICLE_LAYERS-1)
        }
    }
    return particle_program_check(a,info,stored,override,program,needs,layer,others[:count])
}
