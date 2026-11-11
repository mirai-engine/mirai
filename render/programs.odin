package mirai_render

import "core:mem/virtual"
import "mirai:render/abi"
import "mirai:std/serial"

// The programs of the shaders in use: what the catalog of their generation
// lists (abi.Shader_Catalog). A node of a UI gives its first four floats
// (UI_MATERIAL_PROGRAM_BIT).

PROGRAM_PARAMETER_BYTES :: abi.PROGRAM_PARAMETER_BYTES
PARTICLE_ATTRIBUTE_BYTES :: abi.PARTICLE_ATTRIBUTE_BYTES // of the Attributes of a Vfx program, for each particle, at most
PROGRAM_RESOURCES :: abi.PROGRAM_RESOURCES // that a Vfx program reads at most
PROGRAM_STAGES :: abi.PROGRAM_STAGES       // that a Vfx program has at most
PROGRAM_STAGE_PARTICLES :: abi.PROGRAM_STAGE_PARTICLES
PROGRAM_DATA_WORDS :: abi.PROGRAM_DATA_WORDS // of an entry of a data channel

Program :: abi.Program
Program_Domain :: abi.Program_Domain
Program_Kind :: abi.Program_Kind
Program_Parameter :: abi.Program_Parameter
Program_Resource :: abi.Program_Resource
Program_Resource_Kind :: abi.Program_Resource_Kind
Program_Stage :: abi.Program_Stage
Program_Vertex :: abi.Program_Vertex

Program_Catalog :: struct {
    programs:[]Program,
    loaded:bool,
    arena:virtual.Arena, // of what the catalog holds
}

@(private,rodata) EMBEDDED_CATALOG := #load("../shaders/build/catalog.json")

program_catalog_destroy :: proc(catalog:^Program_Catalog) {
    virtual.arena_destroy(&catalog.arena)
    catalog^={}
}

// Reads a catalog of abi.Shader_Catalog. A program or parameter that does not
// fit what a material row holds makes the whole catalog invalid, as running
// out of memory does: nothing is kept.
program_catalog_parse :: proc(bytes:[]u8) -> (catalog:Program_Catalog,ok:bool) {
    if virtual.arena_init_growing(&catalog.arena)!=nil {return}
    read:abi.Shader_Catalog
    if serial.text_decode(string(bytes),&read,virtual.arena_allocator(&catalog.arena))!="" || !catalog_valid(read) {
        virtual.arena_destroy(&catalog.arena)
        return {},false
    }
    catalog.programs=read.programs
    return catalog,true
}

@(private="file")
catalog_valid :: proc(catalog:abi.Shader_Catalog) -> bool {
    if catalog.version!=abi.SHADER_CATALOG_VERSION {return false}
    for program in catalog.programs {
        if program.id<1 || program.size<0 || program.size>PROGRAM_PARAMETER_BYTES || program.attributes<0 || program.attributes>PARTICLE_ATTRIBUTE_BYTES || program.attributes%4!=0 {return false}
        if len(program.resources)>PROGRAM_RESOURCES || len(program.stages)>PROGRAM_STAGES {return false}
        grids:u32
        for resource,index in program.resources {
            if resource.kind==.Grid {grids|=1<<u32(index)}
            if resource.kind==.Data && (resource.words<1 || resource.words>PROGRAM_DATA_WORDS) {return false}
        }
        for stage in program.stages {
            if stage.iterations<1 || stage.over!=PROGRAM_STAGE_PARTICLES && grids&(1<<u32(stage.over))==0 || stage.writes&~grids!=0 {return false}
        }
        reach:=program.vertex.reach_offset<0
        for parameter in program.parameters {
            if parameter.components<1 || parameter.components>4 || parameter.offset%4!=0 || int(parameter.offset)+int(parameter.components)*4>PROGRAM_PARAMETER_BYTES {return false}
            reach||=i32(parameter.offset)==program.vertex.reach_offset && parameter.kind==.Float && parameter.components==1
        }
        if program.vertex.declared && (program.domain!=.Surface || !(program.vertex.reach>=0) || program.vertex.reach>1e30 || !reach) {return false}
    }
    return true
}

// The programs of the shaders the renderer runs.
renderer_programs :: proc(r:^Renderer) -> []Program {
    if !r.programs.loaded {
        catalog,valid:=program_catalog_parse(r.shader_assets.owned?r.shader_assets.catalog:EMBEDDED_CATALOG)
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
