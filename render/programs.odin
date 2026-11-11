package mirai_render

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "mirai:asset"
import "mirai:render/abi"

// The programs of the shaders in use: what catalog.json of their generation
// lists. A material, a post-process effect or an emitter of particles names a
// program by its id and gives it up to 256 bytes of parameters, laid out as
// the program reflects them; a node of a UI gives its first four floats
// (UI_MATERIAL_PROGRAM_BIT).

PROGRAM_PARAMETER_BYTES :: abi.PROGRAM_PARAMETER_BYTES
PARTICLE_ATTRIBUTE_BYTES :: abi.PARTICLE_ATTRIBUTE_BYTES // of the Attributes of a Vfx program, for each particle, at most

Program_Domain :: enum u8 {Surface,Postprocess,Vfx,Ui}
PROGRAM_RESOURCES :: abi.PROGRAM_RESOURCES // that a Vfx program reads at most
PROGRAM_STAGES :: abi.PROGRAM_STAGES    // that a Vfx program has at most
PROGRAM_STAGE_PARTICLES :: 255 // Program_Stage.over of a stage over the particles

// What a resource of a Vfx program is: the surface of a mesh or of what an
// entity draws, the births a game gives, a grid of the world, the particles
// of another emitter, or a data channel.
Program_Resource_Kind :: enum u8 {Surface,Channel,Grid,Emitter,Data}
PROGRAM_DATA_WORDS :: abi.PROGRAM_DATA_WORDS // of an entry of a data channel

// A stage of a Vfx program: a pass of its own each step before update, over
// the particles of its emitter or over the cells of one of its grids.
Program_Stage :: struct {
    name:string,
    over:u8,         // the resource of the grid; PROGRAM_STAGE_PARTICLES: the particles
    iterations:u8,   // each after the one before
    writes:u32,      // the grid resources it writes besides the one it goes over, one bit each
}

// A resource of a Vfx program: its index is its place among those of the program.
Program_Resource :: struct {
    name:string,
    kind:Program_Resource_Kind,
    cleared:bool, // a grid that starts at zero each stage that writes it
    words:u32,    // of an entry of a data channel
}
Program_Kind :: enum u8 {Float,Int,Uint,Bool,Texture}

Program_Parameter :: struct {
    name:string,
    kind:Program_Kind,
    components:u8,   // 1 to 4; a texture is one word
    offset:u16,      // bytes into the parameters of the program
    defaults:[4]f64, // a texture has none
    min,max:f64,
    srgb,normal,color:bool,
    group:string, // the section of Details that shows it; empty: the first, without a title
}

Program :: struct {
    id:u32, // what Material_Desc.program and Postprocess_Desc.program take; never 0
    name:string,
    domain:Program_Domain,
    size:int,
    parameters:[]Program_Parameter,
    layers:asset.Material_Layers, // of a Surface program: those of the OpenPBR model it may give
    attributes:int,               // of a Vfx program: bytes of what it keeps of each particle
    resources:[]Program_Resource, // of a Vfx program, in the order it declares them
    stages:[]Program_Stage,       // of a Vfx program, in the order they run
    moves:bool,                   // of a Vfx program: it moves and ages its particles itself
    births:bool,                  // of a Vfx program: it gives how many particles its emitter starts
    prepare:bool,                 // of a Vfx program: it prepares each frame what its emitter keeps
    vertex:Program_Vertex,        // of a Surface program: its function vertex, which moves the vertices of what shows it
}

// The function vertex of a Surface program (`//! vertex`, displace.odin).
// reach: how far it moves a vertex from its rest, in the space of the mesh;
// with reach_offset, the float parameter at those bytes gives it instead.
Program_Vertex :: struct {
    declared,animated:bool,
    reach:f32,
    reach_offset:i32, // -1: reach
}

Program_Catalog :: struct {
    programs:[]Program,
    loaded:bool,
    allocator:runtime.Allocator,
}

@(private,rodata) EMBEDDED_CATALOG := #load("../shaders/build/catalog.json")

program_catalog_destroy :: proc(catalog:^Program_Catalog) {
    if catalog.allocator.procedure!=nil {
        for program in catalog.programs {
            for parameter in program.parameters {
                delete(parameter.name,catalog.allocator)
                delete(parameter.group,catalog.allocator)
            }
            delete(program.parameters,catalog.allocator)
            for resource in program.resources {delete(resource.name,catalog.allocator)}
            delete(program.resources,catalog.allocator)
            for stage in program.stages {delete(stage.name,catalog.allocator)}
            delete(program.stages,catalog.allocator)
            delete(program.name,catalog.allocator)
        }
        delete(catalog.programs,catalog.allocator)
    }
    catalog^={}
}

@(private="file")
catalog_number :: proc(value:json.Value) -> (number:f64,ok:bool) {
    #partial switch v in value {
    case json.Integer: return f64(v),true
    case json.Float:   return v,true
    case json.Boolean: return v?1:0,true
    }
    return 0,false
}

// A text of the catalog, copied. False when the value is not one or there is no memory for it.
@(private="file")
catalog_text :: proc(value:json.Value,allocator:runtime.Allocator) -> (text:string,ok:bool) {
    source:=value.(json.String) or_return
    copied,error:=strings.clone(source,allocator)
    return copied,error==nil
}

// Reads a catalog.json. A program or parameter that does not fit what a
// material row holds makes the whole catalog invalid, as running out of
// memory does: nothing is kept.
program_catalog_parse :: proc(bytes:[]u8,allocator:=context.allocator) -> (catalog:Program_Catalog,ok:bool) {
    catalog.allocator=allocator
    if !catalog_read(&catalog,bytes) {
        program_catalog_destroy(&catalog)
        return {},false
    }
    return catalog,true
}

@(private="file")
catalog_read :: proc(catalog:^Program_Catalog,bytes:[]u8) -> (ok:bool) {
    allocator:=catalog.allocator
    value,parse_error:=json.parse(bytes,allocator=context.temp_allocator)
    root,is_object:=value.(json.Object)
    if parse_error!=.None || !is_object {return}
    list,is_list:=root["programs"].(json.Array)
    if !is_list {return}
    allocation_error:runtime.Allocator_Error
    catalog.programs,allocation_error=make([]Program,len(list),allocator)
    if allocation_error!=nil {return}
    for entry,at in list {
        item:=entry.(json.Object) or_return
        reach_name:string
        program:=&catalog.programs[at]
        id:=catalog_number(item["id"]) or_return
        size:=catalog_number(item["size"]) or_return
        if id<1 || id>f64(max(u32)) || size<0 || size>PROGRAM_PARAMETER_BYTES {return}
        program.id,program.size=u32(id),int(size)
        program.name=catalog_text(item["name"],allocator) or_return
        switch item["domain"].(json.String) or_return {
        case "surface":     program.domain=.Surface
        case "postprocess": program.domain=.Postprocess
        case "ui":          program.domain=.Ui
        case "vfx":
            program.domain=.Vfx
            attributes:=catalog_number(item["attributes"]) or_return
            if attributes<0 || attributes>PARTICLE_ATTRIBUTE_BYTES || int(attributes)%4!=0 {return}
            program.attributes=int(attributes)
            program.moves,_=item["moves"].(json.Boolean)
            program.births,_=item["births"].(json.Boolean)
            program.prepare,_=item["prepare"].(json.Boolean)
        case: return
        }
        program.vertex.reach_offset=-1
        if vertex,declared:=item["vertex"].(json.Object);declared {
            if program.domain!=.Surface {return}
            program.vertex.declared=true
            program.vertex.animated,_=vertex["animated"].(json.Boolean)
            if name,named:=vertex["reach"].(json.String);named {
                reach_name=strings.clone(name,context.temp_allocator)
            } else {
                reach:=catalog_number(vertex["reach"]) or_return
                if !(reach>=0) || reach>1e30 {return}
                program.vertex.reach=f32(reach)
            }
        }
        if layers,listed:=item["layers"].(json.Array);listed {
            for entry in layers {
                switch entry.(json.String) or_return {
                case "coat":       program.layers+={.Coat}
                case "fuzz":       program.layers+={.Fuzz}
                case "diffuse_transmission": program.layers+={.Diffuse_Transmission}
                case "anisotropy": program.layers+={.Anisotropy}
                case "unlit":      program.layers+={.Unlit}
                case: return
                }
            }
        }
        if resources,listed:=item["resources"].(json.Array);listed {
            if len(resources)>PROGRAM_RESOURCES {return}
            program.resources,allocation_error=make([]Program_Resource,len(resources),allocator)
            if allocation_error!=nil {return}
            for entry,at in resources {
                source:=entry.(json.Object) or_return
                resource:=&program.resources[at]
                resource.name=catalog_text(source["name"],allocator) or_return
                switch source["kind"].(json.String) or_return {
                case "surface": resource.kind=.Surface
                case "channel": resource.kind=.Channel
                case "grid": resource.kind=.Grid
                case "emitter": resource.kind=.Emitter
                case "data": resource.kind=.Data
                case: return
                }
                resource.cleared,_=source["cleared"].(json.Boolean)
                if resource.kind==.Data {
                    words:=catalog_number(source["words"]) or_return
                    if words<1 || words>PROGRAM_DATA_WORDS {return}
                    resource.words=u32(words)
                }
            }
        }
        if stages,listed:=item["stages"].(json.Array);listed {
            if len(stages)>PROGRAM_STAGES {return}
            program.stages,allocation_error=make([]Program_Stage,len(stages),allocator)
            if allocation_error!=nil {return}
            for entry,at in stages {
                source:=entry.(json.Object) or_return
                stage:=&program.stages[at]
                stage.name=catalog_text(source["name"],allocator) or_return
                iterations:=catalog_number(source["iterations"]) or_return
                if iterations<1 || iterations>255 {return}
                stage.iterations=u8(iterations)
                over:=source["over"].(json.String) or_return
                stage.over=PROGRAM_STAGE_PARTICLES
                if over!="particles" {
                    found:=false
                    for resource,index in program.resources {
                        if resource.name==over && resource.kind==.Grid {stage.over,found=u8(index),true}
                    }
                    if !found {return}
                }
                if written,listed:=source["writes"].(json.Array);listed {
                    for target in written {
                        name:=target.(json.String) or_return
                        found:=false
                        for resource,index in program.resources {
                            if resource.name==name && resource.kind==.Grid {stage.writes|=1<<u32(index);found=true}
                        }
                        if !found {return}
                    }
                }
            }
        }
        parameters:=item["parameters"].(json.Array) or_return
        program.parameters,allocation_error=make([]Program_Parameter,len(parameters),allocator)
        if allocation_error!=nil {return}
        for field,index in parameters {
            source:=field.(json.Object) or_return
            parameter:=&program.parameters[index]
            parameter.name=catalog_text(source["name"],allocator) or_return
            switch source["kind"].(json.String) or_return {
            case "float32": parameter.kind=.Float
            case "int32":   parameter.kind=.Int
            case "uint32":  parameter.kind=.Uint
            case "bool":    parameter.kind=.Bool
            case "texture": parameter.kind=.Texture
            case: return
            }
            components:=catalog_number(source["components"]) or_return
            offset:=catalog_number(source["offset"]) or_return
            if components<1 || components>4 || offset<0 || offset+components*4>PROGRAM_PARAMETER_BYTES || int(offset)%4!=0 {return}
            parameter.components,parameter.offset=u8(components),u16(offset)
            parameter.min,_=catalog_number(source["min"])
            parameter.max,_=catalog_number(source["max"])
            parameter.srgb,_=source["srgb"].(json.Boolean)
            parameter.normal,_=source["normal"].(json.Boolean)
            parameter.color,_=source["color"].(json.Boolean)
            if _,named:=source["group"].(json.String);named {parameter.group=catalog_text(source["group"],allocator) or_return}
            if defaults,many:=source["default"].(json.Array);many {
                for element,axis in defaults {
                    if axis<4 {parameter.defaults[axis],_=catalog_number(element)}
                }
            } else {
                parameter.defaults[0],_=catalog_number(source["default"])
            }
            if parameter.name==reach_name {
                if parameter.kind!=.Float || parameter.components!=1 {return}
                program.vertex.reach_offset=i32(parameter.offset)
            }
        }
        if reach_name!="" && program.vertex.reach_offset<0 {return}
    }
    return true
}

// The programs of the shaders the renderer runs.
renderer_programs :: proc(r:^Renderer) -> []Program {
    if !r.programs.loaded {
        catalog,valid:=program_catalog_parse(r.shader_assets.owned?r.shader_assets.catalog:EMBEDDED_CATALOG,r.allocator)
        if !valid {set_error(r,"material program catalog: invalid, or out of memory for it");return nil}
        r.programs=catalog
        r.programs.loaded=true
    }
    return r.programs.programs
}

// The program of an id; nil when the shaders have none.
program_of_id :: proc(r:^Renderer,id:u32) -> ^Program {
    programs:=renderer_programs(r)
    if id>0 && int(id)<=len(programs) && programs[id-1].id==id {return &programs[id-1]}
    for &program in programs {if program.id==id {return &program}}
    return nil
}

// The program of that name and domain; nil when the shaders have none.
program_find :: proc(r:^Renderer,name:string,domain:Program_Domain) -> ^Program {
    for &program in renderer_programs(r) {
        if program.domain==domain && program.name==name {return &program}
    }
    return nil
}

program_parameter :: proc(program:^Program,name:string) -> ^Program_Parameter {
    for &parameter in program.parameters {
        if parameter.name==name {return &parameter}
    }
    return nil
}

@(private="file")
program_words :: #force_inline proc "contextless" (params:^[16]Vec4,parameter:^Program_Parameter) -> []u32 {
    return (cast(^[PROGRAM_PARAMETER_BYTES/4]u32)params)[parameter.offset/4:][:parameter.components]
}

// The parameters of a program with every default; a texture starts as none.
program_defaults :: proc(program:^Program) -> (params:[16]Vec4) {
    for &parameter in program.parameters {
        if parameter.kind==.Texture {program_words(&params,&parameter)[0]=GPU_NONE}
        else {program_parameter_set(&params,&parameter,parameter.defaults)}
    }
    return
}

// Writes the numbers of a parameter in the type the program declares. False,
// writing nothing, for a texture or when a number is not a value of that
// type inside the range of the parameter.
program_parameter_set :: proc(params:^[16]Vec4,parameter:^Program_Parameter,values:[4]f64) -> bool {
    words:[4]u32
    for axis in 0..<int(parameter.components) {
        n:=values[axis]
        if n!=n || n<parameter.min && parameter.min<parameter.max || n>parameter.max && parameter.min<parameter.max {return false}
        switch parameter.kind {
        case .Texture: return false
        case .Float:   words[axis]=transmute(u32)f32(n)
        case .Bool:
            if n!=0 && n!=1 {return false}
            words[axis]=u32(n)
        case .Int:
            if n!=f64(i32(n)) {return false}
            words[axis]=transmute(u32)i32(n)
        case .Uint:
            if n!=f64(u32(n)) {return false}
            words[axis]=u32(n)
        }
    }
    copy(program_words(params,parameter),words[:parameter.components])
    return true
}

// The numbers of a parameter as its program reads them; zeros for a texture.
program_parameter_get :: proc(params:^[16]Vec4,parameter:^Program_Parameter) -> (values:[4]f64) {
    if parameter.kind==.Texture {return}
    for word,axis in program_words(params,parameter) {
        switch parameter.kind {
        case .Texture:
        case .Float:      values[axis]=f64(transmute(f32)word)
        case .Int:        values[axis]=f64(transmute(i32)word)
        case .Uint,.Bool: values[axis]=f64(word)
        }
    }
    return
}

// Points a texture parameter at a texture of the renderer; 0 is none.
program_parameter_set_texture :: proc(r:^Renderer,params:^[16]Vec4,parameter:^Program_Parameter,texture:Texture_Handle) -> bool {
    if parameter.kind!=.Texture {return false}
    program_words(params,parameter)[0]=texture_index(r,texture)
    return true
}
