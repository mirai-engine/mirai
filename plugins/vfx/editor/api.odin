package vfx_editor

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import vfx "plugins:vfx/runtime"
import "plugins:vfx/runtime/effect"

// particle.*: particle effects (.particle) and the emitters that show them,
// by code. The values of an effect are the text of effect.Particle_Info. The
// parameters of its Vfx program go by name, each as the program declares it:
// a number, a list of two to four, true or false, or a texture by its path
// or id; null takes one away. Writes of effects and edits of an instance are
// steps of the history of the document (history.undo), with the file
// the step wrote.

@(private)
Particle_World :: enum u8 {Edit,Play}

@(private)
Api_Particle_Instance_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    world:Particle_World `mirai:"optional,label=Edit: the document; Play: the Play of the caller"`,
    layer:u8 `mirai:"optional,max=7,label=The layer of its effect it reads: 0 the primary"`,
}

@(private)
Api_Particle_Id_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
}

@(private)
Particle_Action :: enum u8 {Start,Stop,Restart,Pause,Resume,Burst}

@(private)
Api_Particle_Control_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    world:Particle_World `mirai:"optional,label=Edit: the preview of the document; Play: the Play of the caller"`,
    action:Particle_Action `mirai:"label=Start and Stop set active, in Play; Restart drops its particles and starts its cycle; Burst starts count particles at once"`,
    count:u32 `mirai:"optional,max=1048576,label=Particles of a Burst"`,
}

@(private)
Api_Particle_Control_Result :: struct {
    id:base.Entity_Id,
    queued:bool `mirai:"label=It takes the request in its next fixed step"`,
}

@(private)
Api_Particle_Pool_Params :: struct {
    world:Particle_World `mirai:"optional,label=Edit: the document; Play: the Play of the caller"`,
}

Pool_Result :: struct {
    world:string,
    frame:u64 `mirai:"label=Of the renderer when the GPU had these counters; 0: none came back yet, ask again"`,
    capacity:u32 `mirai:"label=Particles of the pool of the world"`,
    emitters:[]Pool_Emitter `mirai:"label=The most particles alive first"`,
}
Pool_Emitter :: struct {
    id:base.Entity_Id,
    sub:bool `mirai:"optional,label=The sub effect of the entity"`,
    program:string `mirai:"optional,label=Its Vfx program"`,
    alive,dead,capacity:u32,
    bytes:u64 `mirai:"label=Of the pool its particles, lists, Attributes and counters take"`,
    paused:bool `mirai:"optional"`,
}

Particle_Inspect_Params :: struct {
    particle:string `mirai:"optional,label=An effect: its path under the assets folder, or its id"`,
    path:string `mirai:"optional,label=particle.set: where a new effect goes, under the assets folder"`,
    preset:effect.Particle_Preset `mirai:"optional,label=Starter values of the primary layer"`,
    layers:[]Particle_Layer_Params `mirai:"optional,label=Additional emitter layers; replaces the sequence"`,
    values:serial.Json `mirai:"optional,label=Fields of the effect to change, as particle.inspect shows them"`,
    parameters:serial.Json `mirai:"optional,label=Parameters of its Vfx program by name: a number, a list, true or false, or a texture by path or id; null takes one away"`,
    hidden:[]string `mirai:"optional,label=The fields its instances do not show; replaces the list"`,
}

Particle_Layer_Params :: struct {
    preset:effect.Particle_Preset `mirai:"optional"`,
    values:serial.Json `mirai:"optional"`,
    parameters:serial.Json `mirai:"optional"`,
}

Particle_Layer_Result :: struct {
    values:effect.Particle_Info,
    parameters:serial.Json,
    problem:string `mirai:"optional"`,
}

Particle_Instance_Set_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity,label=The entity with the Particle_Emitter"`,
    values:serial.Json `mirai:"optional,label=Values it shows, as particle.instance.inspect gives them: those that differ from its effect become its own, not its assets or program"`,
    parameters:serial.Json `mirai:"optional,label=Parameters of the Vfx program of its effect for this entity, by name; null takes one away. With its values, at most 16"`,
}

Particle_Result :: struct {
    particle:base.Asset_Id,
    path:string `mirai:"optional,label=Under the assets folder"`,
    values:effect.Particle_Info,
    layers:[]Particle_Layer_Result,
    parameters:serial.Json `mirai:"label=Of its Vfx program by name, as particle.set takes them"`,
    hidden:[]string `mirai:"label=The fields its instances do not show"`,
    problem:string `mirai:"optional,label=Why its program would not run"`,
}

Programs_Result :: struct {programs:[]Program_Result}
Program_Result :: struct {
    name:string,
    attributes:u32 `mirai:"label=Bytes it keeps per particle"`,
    parameters:[]Program_Parameter_Result,
    resources:[]Program_Resource_Result,
    stages:[]Program_Stage_Result,
}
Program_Parameter_Result :: struct {
    name,kind:string,
    components:u32,
    default:[]f64 `mirai:"optional,label=Not of a texture"`,
    min,max:f64,
}
Program_Resource_Result :: struct {name,kind:string}
Program_Stage_Result :: struct {
    name:string,
    over:string `mirai:"label=particles, or the resource it goes over"`,
    iterations:u32,
}

Instance_Result :: struct {
    id:base.Entity_Id,
    world:string,
    particle:base.Asset_Id,
    layer:u8 `mirai:"label=The layer it reads, 0 the primary"`,
    layers:u8 `mirai:"label=Of its effect, the primary one among them"`,
    why:string `mirai:"label=The first link that keeps it from being seen (unresolved, invalid_program, hidden, culled, pool_full, missing_resource, zero_alive), or the pass that draws it (gbuffer, blend)"`,
    space:string `mirai:"label=Where its particles move: local (with the entity) or world; their places here are in the world either way"`,
    values:effect.Particle_Info `mirai:"label=Of that layer of its effect with its own over them"`,
    overrides:serial.Json `mirai:"label=Its own values by their path: layers.N. names a layer, a parameter without it every layer that declares it"`,
    parameters:serial.Json `mirai:"label=Its own parameters of the program of that layer by name"`,
    problem:string `mirai:"optional,label=Why its program does not run"`,
    status:Instance_Status `mirai:"optional,label=The clock of that layer"`,
    gpu:Instance_Gpu `mirai:"optional,label=What the GPU copied back of the particles of that layer"`,
}
Instance_Status :: struct {
    state:string,
    seconds:f64 `mirai:"unit=s,label=Of its generation"`,
    generation:u64,
    births:u64,
}
Instance_Gpu :: struct {
    alive:int,
    dead,births,born:u64 `mirai:"optional"`,
    frame:u64,
    not_finite:int `mirai:"optional,label=Particles that hold NaN or Inf: the vfx.nan problem of the entity names where"`,
    particles:[]Gpu_Particle `mirai:"label=The first of them"`,
}
Gpu_Particle :: struct {
    slot:u32,
    position,velocity:[3]f32,
    age,size:f32,
    seed:u32,
    attributes:serial.Json `mirai:"optional,label=Of its Vfx program, by the names of its fields"`,
}

@(private)
api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="particle.inspect",params=type_info_of(Particle_Inspect_Params),summary="The primary and additional layers of a particle effect (.particle), and the primary layer’s Vfx parameters and hidden fields.",flags={.Read_Only},result=type_info_of(Particle_Result),run=api_particle_inspect})
    editor.api_method_register(s,{name="particle.set",params=type_info_of(Particle_Inspect_Params),summary="Changes a particle effect for every entity that shows it, or makes one at path. Set preset to start from a starter effect and layers to give additional emitters.",flags={.Idempotent},result=type_info_of(Particle_Result),run=api_particle_set})
    editor.api_method_register(s,{name="particle.programs",summary="The Vfx programs of the shaders: their parameters with kind, components, default and range, the bytes each keeps per particle, the resources it reads by name (surfaces, channels, grids) and its stages: what each goes over and its iterations.",flags={.Read_Only},result=type_info_of(Programs_Result),run=api_particle_programs})
    inspect:=Api_Particle_Instance_Params{world=.Edit}
    control:=Api_Particle_Control_Params{world=.Play}
    editor.api_method_register(s,{name="particle.instance.inspect",params=type_info_of(Api_Particle_Instance_Params),defaults=&inspect,summary="What an emitter shows: the values of its effect with its own over them, its own values by path, the parameters of its program, why its program does not run, and its clock (state, seconds, generation, births).",flags={.Read_Only},result=type_info_of(Instance_Result),run=api_particle_instance_inspect})
    editor.api_method_register(s,{name="particle.instance.set",params=type_info_of(Particle_Instance_Set_Params),summary="In Edit, one undo step: the values given that differ from the effect, and the parameters given, become the entity's own (at most 16 together, not its assets or program). The result is as particle.instance.inspect's.",result=type_info_of(Instance_Result),run=api_particle_instance_set})
    editor.api_method_register(s,{name="particle.instance.revert",params=type_info_of(Api_Particle_Id_Params),summary="In Edit, one undo step: the entity takes back every value and parameter of its effect.",result=type_info_of(Instance_Result),run=api_particle_instance_revert})
    editor.api_method_register(s,{name="particle.instance.apply",params=type_info_of(Api_Particle_Id_Params),summary="Writes the values and parameters the entity shows into its effect, for every entity that shows it, and reverts the entity, in one undo step.",result=type_info_of(Instance_Result),run=api_particle_instance_apply})
    editor.api_method_register(s,{name="particle.instance.control",params=type_info_of(Api_Particle_Control_Params),result=type_info_of(Api_Particle_Control_Result),defaults=&control,summary="Starts, stops, restarts, pauses, resumes or bursts an emitter in Edit or the caller's Play. The emitter takes the request in its next fixed step.",run=api_particle_instance_control})
    pool:=Api_Particle_Pool_Params{world=.Edit}
    editor.api_method_register(s,{name="particle.pool.inspect",params=type_info_of(Api_Particle_Pool_Params),defaults=&pool,summary="Every emitter of a world with its particles alive, free slots, capacity, Vfx program and the bytes it takes of the pool, as the GPU had them some frames ago; the editor reads them from the first call on.",flags={.Read_Only},result=type_info_of(Pool_Result),run=api_particle_pool_inspect})
}

// The params of an effect: its name, path and values, its parameters (the
// text of the object) and its hidden fields.
@(private)
Particle_Params :: struct {
    named,path,values:string,
    parameters:string,
    preset:effect.Particle_Preset,
    layers:[]Particle_Layer_Params,
    has_layers:bool,
    hidden:[dynamic]effect.Particle_Field,
    has_hidden:bool,
}

@(private)
particle_params :: proc(call:^api.Call) -> (p:Particle_Params) {
    given:=api.call_params(call,Particle_Inspect_Params)
    p.named,p.path,p.values=given.particle,given.path,string(given.values)
    p.parameters=string(given.parameters)
    p.preset,p.layers=given.preset,given.layers
    p.has_layers=api.call_given(call,"layers")
    p.has_hidden=api.call_given(call,"hidden")
    p.hidden=make([dynamic]effect.Particle_Field,context.temp_allocator)
    for name in given.hidden {
        entry:effect.Particle_Field
        base.text_set(entry.name[:],name)
        append(&p.hidden,entry)
    }
    return
}

// ---------------------------------------------------------------- parameters of programs

// The Vfx program an effect names; nil for none, with a message for one the
// shaders do not have.
@(private)
particle_program_of :: proc(s:^editor.Session,info:^effect.Particle_Info) -> (program:^erender.Program,problem:string) {
    name:=base.text_get(info.program[:])
    if name=="" {return}
    if s.app.renderer==nil {return nil,"The editor has no renderer to read the programs of its shaders"}
    program=erender.program_find(s.app.assets,name,.Vfx)
    if program==nil {problem=fmt.tprintf("The shaders have no Vfx program %q: particle.programs lists them",name)}
    return
}

// Puts the parameters of the params ({name: value|null}) over those of
// file, as the program of info declares them.
@(private)
particle_parameters_read :: proc(s:^editor.Session,call:^api.Call,text:string,info:^effect.Particle_Info,file:^Particle_File,layer:u8=0) -> bool {
    if text=="" {return true}
    program,problem:=particle_program_of(s,info)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    fail :: proc(call:^api.Call,format:string,args:..any) -> bool {
        api.call_failf(call,api.INVALID_PARAMS,format,..args)
        return false
    }
    if !serial.text_accept(&r,'{') {return fail(call,"parameters must be an object of names")}
    if serial.text_accept(&r,'}') {return true}
    for {
        serial.text_space(&r)
        name,named:=serial.text_string(&r)
        if !named || !serial.text_expect(&r,':') {return fail(call,"parameters: malformed JSON")}
        name=strings.clone(name,context.temp_allocator)
        serial.text_space(&r)
        if serial.text_keyword(&r,"null") {
            effect_parameter_remove(file,name,layer)
        } else {
            if program==nil {return fail(call,"parameters: %s",problem!="" ? problem : "the effect has no Vfx program: name one in program first")}
            declared:=erender.program_parameter(program,name)
            if declared==nil {return fail(call,"parameters: %s has no parameter %q; particle.programs lists them",program.name,name)}
            parameter:=effect.Particle_Parameter{kind=asset.Parameter_Kind(declared.kind),components=declared.components,layer=layer}
            base.text_set(parameter.name[:],name)
            switch {
            case declared.kind==.Texture:
                path,read:=serial.text_string(&r)
                if !read {return fail(call,"parameters: %s takes a texture by its path or id",name)}
                texture,found:=editor.asset_named(s,call,path,asset.KIND_TEXTURE,".tex","a texture")
                if !found {return false}
                parameter.texture=texture
            case serial.text_accept(&r,'['):
                count:=0
                for !serial.text_accept(&r,']') {
                    value,ok:=parameter_number(&r)
                    if !ok || count>=4 {return fail(call,"parameters: %s takes %d number%s",name,declared.components,declared.components>1?"s":"")}
                    parameter.value[count]=value
                    count+=1
                    serial.text_accept(&r,',')
                }
                if count!=int(declared.components) {return fail(call,"parameters: %s takes %d number%s",name,declared.components,declared.components>1?"s":"")}
            case:
                value,ok:=parameter_number(&r)
                if !ok || declared.components!=1 {return fail(call,"parameters: %s takes %d number%s",name,declared.components,declared.components>1?"s":"")}
                parameter.value[0]=value
            }
            if problem:=effect.particle_parameter_validate(&parameter);problem.message!="" {return fail(call,"parameters: %s",problem.message)}
            if !effect_parameter_store(file,parameter) {return fail(call,"parameters: give at most %d",len(file.parameters))}
        }
        if serial.text_accept(&r,',') {continue}
        if !serial.text_expect(&r,'}') {return fail(call,"parameters: malformed JSON")}
        return true
    }
}

// A number, or true and false as 1 and 0.
@(private="file")
parameter_number :: proc(r:^serial.Text_Reader) -> (value:f64,ok:bool) {
    serial.text_space(r)
    if serial.text_keyword(r,"true") {return 1,true}
    if serial.text_keyword(r,"false") {return 0,true}
    token:=serial.text_number(r) or_return
    return strconv.parse_f64(token)
}

// The parameters of a list as the object particle.set takes, by name.
@(private)
particle_parameters_json :: proc(call:^api.Call,list:[]effect.Particle_Parameter,layer:u8=0) -> serial.Json {
    w:serial.Writer
    serial.writer_init(&w,256,call.allocator)
    out:=&w
    serial.write_u8(out,'{')
    first:=true
    for &parameter in list {
        if parameter.layer!=layer {continue}
        if !first {serial.write_u8(out,',')}
        first=false
        serial.text_write_string(out,base.text_get(parameter.name[:]))
        serial.write_u8(out,':')
        if parameter.kind==.Texture {
            serial.write_u8(out,'"')
            serial.text_write_asset_id(out,parameter.texture)
            serial.write_u8(out,'"')
            continue
        }
        if parameter.components>1 {serial.write_u8(out,'[')}
        for value,axis in parameter.value[:parameter.components] {
            if axis>0 {serial.write_u8(out,',')}
            switch parameter.kind {
            case .Bool: api.write_flag(out,value!=0)
            case .Int: serial.text_write_int(out,i64(value))
            case .Uint: serial.text_write_uint(out,u64(value))
            case .Float,.Texture: serial.text_write_float(out,transmute(u64)value,8)
            }
        }
        if parameter.components>1 {serial.write_u8(out,']')}
    }
    serial.write_u8(out,'}')
    return serial.Json(serial.writer_bytes(out))
}

// ---------------------------------------------------------------- effects

@(private)
api_particle_write :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id) {
    a:=s.app.assets
    view,ok:=vfx.effect_view(a,id)
    if !ok {
        api.call_fail(call,api.SERVER_ERROR,"The particle effect could not be read")
        return
    }
    r:=api.call_result(call,Particle_Result)
    r.particle=id
    r.values=view.info
    items,err:=make([]Particle_Layer_Result,len(view.layers),call.allocator)
    if err!=nil {
        api.call_fail(call,api.SERVER_ERROR,"Out of memory for particle layers")
        return
    }
    r.layers=items
    for &item,i in items {
        item.values=view.layers[i]
        item.parameters=particle_parameters_json(call,view.parameters,u8(i+1))
        program:vfx.Program
        item.problem=vfx.particle_program_check(a,&item.values,view.parameters,nil,&program,layer=u8(i+1))
    }
    r.path=editor.asset_path(s,id)
    r.parameters=particle_parameters_json(call,view.parameters)
    hidden:=make([]string,len(view.hidden),call.allocator)
    for &h,i in view.hidden {hidden[i]=strings.clone(base.text_get(h.name[:]),call.allocator)}
    r.hidden=hidden
    program:vfx.Program
    r.problem=vfx.particle_program(a,id,&view.info,nil,&program)
}

@(private)
api_particle_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=particle_params(call)
    id,found:=editor.asset_named(s,call,p.named,effect.PARTICLE_KIND,effect.PARTICLE_EXTENSION,"a particle effect")
    if !found {return}
    api_particle_write(s,call,id)
}

// The file of the params over file: its values, its parameters and its hidden fields.
@(private)
particle_params_apply :: proc(s:^editor.Session,call:^api.Call,p:^Particle_Params,file:^Particle_File) -> bool {
    if p.preset!=.Default {file.info=effect.particle_preset(p.preset)}
    if !editor.asset_values_read(call,p.values,&file.info) {return false}
    if p.has_layers {
        if len(p.layers)>len(file.layers) {
            api.call_failf(call,api.INVALID_PARAMS,"layers: give at most %d additional layers",len(file.layers))
            return false
        }
        file.layers={}
        particle_layer_parameters_remove(file,1,all_after=true)
        for &layer,i in p.layers {
            info:=&file.layers[i]
            info^=effect.particle_preset(layer.preset)
            if !editor.asset_values_read(call,string(layer.values),info) ||
                !particle_parameters_read(s,call,string(layer.parameters),info,file,u8(i+1)) {
                return false
            }
        }
        file.layer_count=len(p.layers)
    }
    if !particle_parameters_read(s,call,p.parameters,&file.info,file) {return false}
    if p.has_hidden {
        if len(p.hidden)>len(file.hidden) {
            api.call_failf(call,api.INVALID_PARAMS,"hidden: give at most %d fields",len(file.hidden))
            return false
        }
        file.hidden={}
        file.hidden_count=copy(file.hidden[:],p.hidden[:])
    }
    if problem:=effect.particle_validate(particle_desc(file));problem.message!="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",problem.field,problem.message)
        return false
    }
    // Values a program the shaders have does not take are refused; a program they do not have yet is named all the same.
    if program,_:=particle_program_of(s,&file.info);program!=nil {
        checked:vfx.Program
        if problem:=vfx.particle_program_check(s.app.assets,&file.info,file.parameters[:file.parameter_count],nil,&checked);problem!="" {
            api.call_failf(call,api.INVALID_PARAMS,"parameters: %s",problem)
            return false
        }
    }
    return true
}

@(private)
api_particle_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=particle_params(call)
    t,found:=editor.asset_target(s,call,p.named,p.path,"particle",effect.PARTICLE_KIND,effect.PARTICLE_EXTENSION,"a particle effect")
    if !found {return}
    file:=particle_file(s,t.created?base.Asset_Id{}:t.id)
    if !particle_params_apply(s,call,&p,&file) {return}
    label:=t.created?"Create particle":"Particle"
    if !editor.api_edit_begin(s,call,label) {return}
    problem:=particle_publish(s,t.id,t.file,&file,label)
    if problem!="" {api.call_fail(call,api.SERVER_ERROR,problem)}
    if !editor.api_edit_end(s,call,problem=="") {return}
    api_particle_write(s,call,t.id)
}

@(private)
api_particle_programs :: proc(s:^editor.Session,call:^api.Call) {
    programs:=make([dynamic]Program_Result,call.allocator)
    if s.app.renderer!=nil {
        for &program in erender.programs(s.app.renderer) {
            if program.domain!=.Vfx {continue}
            parameters:=make([]Program_Parameter_Result,len(program.parameters),call.allocator)
            for &parameter,i in program.parameters {
                shown:=&parameters[i]
                shown^={name=parameter.name,kind=fmt.tprint(parameter.kind),components=u32(parameter.components)}
                if parameter.kind!=.Texture {
                    shown.default=make([]f64,parameter.components,call.allocator)
                    for value,axis in parameter.defaults[:parameter.components] {shown.default[axis]=f64(value)}
                    shown.min,shown.max=f64(parameter.min),f64(parameter.max)
                }
            }
            resources:=make([]Program_Resource_Result,len(program.resources),call.allocator)
            for &resource,i in program.resources {resources[i]={resource.name,fmt.tprint(resource.kind)}}
            stages:=make([]Program_Stage_Result,len(program.stages),call.allocator)
            for &stage,i in program.stages {
                over:="particles"
                if stage.over!=erender.PROGRAM_STAGE_PARTICLES && int(stage.over)<len(program.resources) {over=program.resources[stage.over].name}
                stages[i]={stage.name,over,u32(stage.iterations)}
            }
            append(&programs,Program_Result{program.name,u32(program.attributes),parameters,resources,stages})
        }
    }
    api.call_result(call,Programs_Result).programs=programs[:]
}

// ---------------------------------------------------------------- instances

// The world an instance method acts on: the document, or the Play of the caller.
@(private)
particle_world :: proc(s:^editor.Session,call:^api.Call,world:Particle_World) -> (w:core.World_Ref,ok:bool) {
    if world==.Edit {return editor.edited_world(s),true}
    r,_:=editor.api_play_run(s,call)
    if r==nil {
        editor.api_no_game(call,"or address the emitters of world Edit")
        return
    }
    return editor.run_ref(s,r),true
}

// The entity of an id in a world, which must have a Particle_Emitter.
@(private)
particle_entity :: proc(w:core.World_Ref,call:^api.Call,named:[]u8) -> (e:core.Entity,ok:bool) {
    e=editor.api_call_entity(call,w,named) or_return
    if !editor.entity_has(w,e,vfx.Particle_Emitter) {
        api.call_failf(call,api.INVALID_PARAMS,"entity %q has no Particle_Emitter",base.text_get(named))
        return
    }
    return e,true
}

// The text of each value of an instance that is a field of its effect, by its
// path, layers.N. before it for a layer it names.
@(private)
particle_overrides_json :: proc(call:^api.Call,override:^vfx.Particle_Override) -> serial.Json {
    w:serial.Writer
    serial.writer_init(&w,256,call.allocator)
    out:=&w
    serial.write_u8(out,'{')
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    first:=true
    for field in effect.particle_fields() {
        hash:=base.name_hash(field.path)
        for name,i in override.names[:min(override.count,vfx.PARTICLE_OVERRIDE_CAPACITY)] {
            if name!=hash {continue}
            if !first {serial.write_u8(out,',')}
            first=false
            path:=field.path
            if layer:=override.layers[i];layer>0 {path=fmt.tprintf("%s%d.%s",vfx.PARTICLE_LAYER_PATH,layer-1,field.path)}
            serial.text_write_string(out,path)
            serial.write_u8(out,':')
            type,_:=serial.schema_add_type_info(&schema,field.info)
            serial.text_write(out,&schema,type,override.values[i][:field.size],.Line)
        }
    }
    serial.write_u8(out,'}')
    return serial.Json(serial.writer_bytes(out))
}

@(private)
particle_instance_write :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,e:core.Entity,world:Particle_World,layer:=0) {
    a:=s.app.assets
    emitter,_:=editor.entity_get(w,e,vfx.Particle_Emitter)
    override,_:=editor.entity_get(w,e,vfx.Particle_Override)
    layers:=1
    if a!=nil && emitter.particle!={} {
        if view,found:=vfx.effect_view(a,emitter.particle);found {layers=1+len(view.layers)}
    }
    if layer>=layers {
        api.call_failf(call,api.INVALID_PARAMS,"its effect has %d layers: read one from 0 to %d",layers,layers-1)
        return
    }
    // The editor watches its particles from now on; the frames the first
    // readback takes go by here, before what they would leave in temporary
    // memory is read.
    id:=vfx.layer_id(e,layer)
    v:=vfx_editor_of(s)
    if v!=nil {
        watch_emitter(s,&v.watch,w.data,id)
        rows_wait(s,v,w.data,e,layer)
    }
    info:effect.Particle_Info
    error:=vfx.particle_resolve_checked(a,emitter.particle,&override,&info,emitter.preset,u8(layer))
    given:=particle_file(s,emitter.particle)
    given.info=vfx.particle_resolve(a,emitter.particle,&override,emitter.preset)
    given.parameter_count=0
    instance_parameters(s,&override,&given,emitter.particle,emitter.preset)
    r:=api.call_result(call,Instance_Result)
    r.id,r.world,r.particle=editor.api_entity_id(w,e),fmt.tprint(world),emitter.particle
    r.layer,r.layers=u8(layer),u8(layers)
    r.values=info
    r.space="local" if info.local_space else "world"
    r.overrides=particle_overrides_json(call,&override)
    r.parameters=particle_parameters_json(call,given.parameters[:given.parameter_count],u8(layer))
    r.problem=vfx.error_message(error)
    facts:=Why_Facts{unresolved=error!=.None,alive=-1}
    if r.problem=="" {
        program:vfx.Program
        r.problem=vfx.particle_program(a,emitter.particle,&info,&override,&program,layer=u8(layer))
        facts.program=r.problem!=""
    }
    if clocks:=core.world_storage_of(w,vfx.Particle_Clocks);clocks!=nil {
        if status,found:=vfx.status(clocks,emitter,e,layer);found {
            r.status={fmt.tprint(status.state),status.time,u64(status.generation),u64(status.emitted)}
            facts.culled=status.state==.Culled
        }
    }
    facts.hidden=erender.is_hidden(core.world_table_of(w,erender.Hidden),core.world_table_of(w,core.Parent),e)
    // What the GPU copied back of its particles.
    if v!=nil {
        if sync:=host.app_world_storage(s.app,w.data,vfx.Particle_Sync);sync!=nil {
            shown:=vfx.shown_find(sync,e,layer)
            facts.told=shown!=nil && shown.resolved!=0 && shown.desc.spec!=nil
            facts.pooled=vfx.pool_slot_find(&sync.pool,id)>=0
            facts.missing=vfx.resource_missing(sync,shown)
            facts.gbuffer=info.render==.Mesh && shown!=nil && !shown.desc.blended
            facts.program||=shown!=nil && base.text_get(shown.problem[:])!=""
            if instance_gpu(s,call,sync,&v.watch,id,&info,&r.gpu) {facts.alive=r.gpu.alive}
        }
    }
    names:=WHY_NAMES
    r.why=names[instance_why(facts)]
}

// The frames that tell the renderer of a layer of the emitter at e and bring
// back its rows go by, a few at most: none when they came already, or once
// it is resolved and the pool does not hold it (hidden, or no room).
@(private)
rows_wait :: proc(s:^editor.Session,v:^Vfx_Editor,world:rawptr,e:core.Entity,layer:int) {
    id:=vfx.layer_id(e,layer)
    for _ in 0..<WATCH_WAIT {
        sync:=host.app_world_storage(s.app,world,vfx.Particle_Sync)
        if sync==nil || s.app.renderer==nil {return}
        shown:=vfx.shown_find(sync,e,layer)
        told:=shown!=nil && shown.resolved!=0
        if told && vfx.pool_slot_find(&sync.pool,id)<0 {return}
        if rows,ok:=emitter_rows(s.app.renderer,sync,v.watch.poses[:]);told && ok && rows.id==id {return}
        if editor.api_frames(s,1,0)==0 || !world_live(s,world) {return}
    }
}

// What the GPU copied back of an emitter: its counters and its first
// particles in the world, with their Attributes by name. False while none
// came back.
@(private)
instance_gpu :: proc(s:^editor.Session,call:^api.Call,sync:^vfx.Particle_Sync,w:^Particle_Watch,id:u64,info:^effect.Particle_Info,out:^Instance_Gpu) -> bool {
    rows,ok:=emitter_rows(s.app.renderer,sync,w.poses[:])
    if !ok || rows.id!=id {return false}
    fields:[]erender.Program_Attribute
    if program,_:=particle_program_of(s,info);program!=nil {fields=program.attribute_fields}
    out.frame=rows.frame
    out.dead,out.births,out.born=u64(rows.state.dead),u64(rows.state.births),u64(rows.state.born)
    out.not_finite=rows_scan(&rows,fields).particles
    out.particles=make([]Gpu_Particle,8,call.allocator)
    shown:=0
    for p,slot in rows.particles {
        if !particle_live(p) {continue}
        out.alive+=1
        if shown==len(out.particles) {continue}
        out.particles[shown]=gpu_particle(&rows,slot,fields,call.allocator)
        shown+=1
    }
    out.particles=out.particles[:shown]
    return true
}

// A particle of rows in the world, with its Attributes by name.
@(private)
gpu_particle :: proc(rows:^Emitter_Rows,slot:int,fields:[]erender.Program_Attribute,allocator:=context.temp_allocator) -> Gpu_Particle {
    p:=rows.particles[slot]
    position,velocity:=pose_world(rows.pose,p)
    shown:=Gpu_Particle{slot=u32(slot),position=position,velocity=velocity,age=p.age,size=p.size,seed=p.seed}
    if words:=int(rows.stride/4);words>0 && len(fields)>0 && (slot+1)*words<=len(rows.words) {
        shown.attributes=serial.Json(attributes_text(rows.words[slot*words:][:words],fields,allocator))
    }
    return shown
}

// What particle.instance.inspect knows of an emitter, link by link, from
// its effect to the pass that draws it.
@(private)
Why_Facts :: struct {
    unresolved:bool, // its effect or its values are not those of an effect
    told:bool,       // the renderer has what it shows: its effect, its assets and the triangles of its meshes
    program:bool,    // its Vfx program does not run
    hidden:bool,
    culled:bool,
    pooled:bool,     // the pool of its world holds it
    missing:bool,    // a resource it reads has no source
    alive:int,       // particles the GPU copied back; -1: none came back
    gbuffer:bool,    // its opaque Mesh particles are drawn in the G-buffer
}

@(private)
Why :: enum u8 {Unresolved,Invalid_Program,Hidden,Culled,Pool_Full,Missing_Resource,Zero_Alive,Gbuffer,Blend}

@(private)
WHY_NAMES :: [Why]string{
    .Unresolved="unresolved",.Invalid_Program="invalid_program",.Hidden="hidden",.Culled="culled",
    .Pool_Full="pool_full",.Missing_Resource="missing_resource",.Zero_Alive="zero_alive",.Gbuffer="gbuffer",.Blend="blend",
}

// The first link that keeps an emitter from being seen, or the pass that
// draws it when none does.
@(private)
instance_why :: proc(f:Why_Facts) -> Why {
    switch {
    case f.unresolved || !f.told: return .Unresolved
    case f.program: return .Invalid_Program
    case f.hidden: return .Hidden
    case f.culled: return .Culled
    case !f.pooled: return .Pool_Full
    case f.missing: return .Missing_Resource
    case f.alive==0: return .Zero_Alive
    case f.gbuffer: return .Gbuffer
    }
    return .Blend
}

@(private)
api_particle_instance_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Particle_Instance_Params)
    w,ok:=particle_world(s,call,p.world)
    if !ok {return}
    e,found:=particle_entity(w,call,p.entity[:])
    if found {particle_instance_write(s,call,w,e,p.world,int(p.layer))}
}

@(private)
api_particle_instance_set :: proc(s:^editor.Session,call:^api.Call) {
    if editor.watching(s) {
        api.call_fail(call,api.INVALID_PARAMS,"Stop watching another run before editing the document")
        return
    }
    p:=api.call_params(call,Particle_Instance_Set_Params)
    values,parameters:=string(p.values),string(p.parameters)
    w:=editor.edited_world(s)
    e,found:=particle_entity(w,call,p.entity[:])
    if !found {return}
    emitter,_:=editor.entity_get(w,e,vfx.Particle_Emitter)
    override,_:=editor.entity_get(w,e,vfx.Particle_Override)
    file:=particle_file(s,emitter.particle)
    // The values it shows, with those given over them; what differs from the effect is its own.
    shown:=vfx.particle_resolve(s.app.assets,emitter.particle,&override,emitter.preset)
    if !editor.asset_values_read(call,values,&shown) {return}
    if problem:=effect.particle_validate({info=shown});problem.message!="" {
        api.call_failf(call,api.INVALID_PARAMS,"values: %s: %s",problem.field,problem.message)
        return
    }
    if shown.program!=file.info.program {
        api.call_fail(call,api.INVALID_PARAMS,vfx.error_message(.Effect_Field))
        return
    }
    next:vfx.Particle_Override
    for field in effect.particle_fields() {
        now:=mem.byte_slice(rawptr(uintptr(&shown)+field.offset),field.size)
        if mem.compare(now,mem.byte_slice(rawptr(uintptr(&file.info)+field.offset),field.size))==0 {continue}
        if field.kind==.Asset {
            api.call_failf(call,api.INVALID_PARAMS,"values: %s: %s",field.path,vfx.error_message(.Effect_Field))
            return
        }
        if error:=vfx.value_put(&next,base.name_hash(field.path),now);error!=.None {
            api.call_failf(call,api.INVALID_PARAMS,"values: %s: %s",field.path,vfx.error_message(error))
            return
        }
    }
    given:Particle_File
    given.info=file.info
    instance_parameters(s,&override,&given)
    if !particle_parameters_read(s,call,parameters,&file.info,&given) {return}
    for &parameter in given.parameters[:given.parameter_count] {
        value:=vfx.parameter_value(&parameter)
        if error:=vfx.value_put(&next,vfx.parameter_hash(base.text_get(parameter.name[:])),value[:]);error!=.None {
            api.call_failf(call,api.INVALID_PARAMS,"parameters: %s",vfx.error_message(error))
            return
        }
    }
    checked:vfx.Program
    if problem:=vfx.particle_program_check(s.app.assets,&file.info,file.parameters[:file.parameter_count],&next,&checked);problem!="" {
        api.call_failf(call,api.INVALID_PARAMS,"parameters: %s",problem)
        return
    }
    if !editor.api_edit_begin(s,call,"Particle values") {return}
    w=editor.edited_world(s)
    values_table:=core.world_table_of(w,vfx.Particle_Override)
    if values_table==nil {editor.api_edit_end(s,call,false);return}
    if next.count>0 {core.add(values_table,e,next)} else if core.has(values_table,e) {core.remove(values_table,e)}
    if !editor.api_edit_end(s,call,true) {return}
    particle_instance_write(s,call,editor.edited_world(s),e,.Edit)
}

@(private)
api_particle_instance_revert :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Particle_Id_Params)
    w:=editor.edited_world(s)
    e,found:=particle_entity(w,call,p.entity[:])
    if !found {return}
    if !editor.api_edit_begin(s,call,"Revert particle") {return}
    instance_clear(editor.edited_world(s),e)
    if !editor.api_edit_end(s,call,true) {return}
    particle_instance_write(s,call,editor.edited_world(s),e,.Edit)
}

// Takes from the entity its values for its effect.
@(private)
instance_clear :: proc(w:core.World_Ref,e:core.Entity) {
    if table:=core.world_table_of(w,vfx.Particle_Override);table!=nil && core.has(table,e) {core.remove(table,e)}
}

// Puts what an instance gives each layer of the file over its own: the
// values of the layers past the primary, resolved again from its effect
// (particle: none leaves them), and the parameters of every layer as the
// program of each declares them, a parameter of no layer in each that
// declares it; what none declares is left out.
@(private)
instance_parameters :: proc(s:^editor.Session,override:^vfx.Particle_Override,file:^Particle_File,particle:base.Asset_Id={},preset:=effect.Particle_Preset.Default) {
    for layer in 0..=file.layer_count {
        info:=&file.info if layer==0 else &file.layers[layer-1]
        if layer>0 && particle!={} {info^=vfx.particle_resolve(s.app.assets,particle,override,preset,u8(layer))}
        program,_:=particle_program_of(s,info)
        if program==nil {continue}
        for name,at in override.names[:min(override.count,vfx.PARTICLE_OVERRIDE_CAPACITY)] {
            if named:=override.layers[at];named!=0 && int(named)!=layer+1 {continue}
            if parameter,declared:=vfx.value_parameter(program,name,override.values[at]);declared {
                parameter.layer=u8(layer)
                effect_parameter_store(file,parameter)
            }
        }
    }
}

@(private)
api_particle_instance_apply :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Particle_Id_Params)
    w:=editor.edited_world(s)
    e,found:=particle_entity(w,call,p.entity[:])
    if !found {return}
    emitter,_:=editor.entity_get(w,e,vfx.Particle_Emitter)
    if emitter.particle=={} {
        api.call_fail(call,api.INVALID_PARAMS,"The entity shows the default effect, which has no file: give it one made with particle.set and path")
        return
    }
    override,_:=editor.entity_get(w,e,vfx.Particle_Override)
    file:=particle_file(s,emitter.particle)
    file.info=vfx.particle_resolve(s.app.assets,emitter.particle,&override,emitter.preset)
    instance_parameters(s,&override,&file,emitter.particle,emitter.preset)
    a:=s.app.assets
    record,_:=asset.registry_find(&a.registry,emitter.particle)
    // The file and the entity in one step.
    if !editor.api_edit_begin(s,call,"Apply to particle") {return}
    problem:=particle_publish(s,emitter.particle,asset.registry_file_path(&a.registry,record.path,context.temp_allocator),&file,"Apply to particle")
    if problem!="" {
        api.call_fail(call,api.SERVER_ERROR,problem)
    } else {
        instance_clear(editor.edited_world(s),e)
    }
    if !editor.api_edit_end(s,call,problem=="") {return}
    particle_instance_write(s,call,editor.edited_world(s),e,.Edit)
}

@(private)
api_particle_instance_control :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Particle_Control_Params)
    if p.action==.Burst && p.count==0 {
        api.call_fail(call,api.INVALID_PARAMS,"Burst takes count: the particles it starts")
        return
    }
    w,ok:=particle_world(s,call,p.world)
    if !ok {return}
    if p.world==.Play {
        if _,own:=editor.api_play_run(s,call);!own {editor.api_play_refused(call);return}
    }
    e,found:=particle_entity(w,call,p.entity[:])
    if !found {return}
    requests:=core.world_storage_of(w,vfx.Particle_Requests)
    if requests==nil {
        api.call_fail(call,api.SERVER_ERROR,"This world has no Particle_Requests")
        return
    }
    switch p.action {
    case .Start: vfx.start(requests,e)
    case .Stop: vfx.stop(requests,e)
    case .Restart: vfx.restart(requests,e)
    case .Pause: vfx.pause(requests,e)
    case .Resume: vfx.resume(requests,e)
    case .Burst: vfx.burst(requests,e,p.count)
    }
    api.call_result(call,Api_Particle_Control_Result)^={id=editor.api_entity_id(w,e),queued=true}
}

@(private)
api_particle_pool_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Particle_Pool_Params)
    w,ok:=particle_world(s,call,p.world)
    if !ok {return}
    r:=api.call_result(call,Pool_Result)
    r.world=fmt.tprint(p.world)
    v,sync:=vfx_editor_of(s),host.app_world_storage(s.app,w.data,vfx.Particle_Sync)
    if v==nil || sync==nil {return}
    watch_pool(s,&v.watch,w.data)
    r.capacity=sync.pool.capacity
    list,frame,listed:=pool_overview(s.app.renderer,sync,call.allocator)
    if !listed {
        api.call_fail(call,api.SERVER_ERROR,"Out of memory for the list of emitters")
        return
    }
    r.frame=frame
    error:mem.Allocator_Error
    if r.emitters,error=make([]Pool_Emitter,len(list),call.allocator);error!=nil {
        api.call_fail(call,api.SERVER_ERROR,"Out of memory for the list of emitters")
        return
    }
    for row,i in list {
        desc:=&sync.pool.slots[row.slot].desc
        r.emitters[i]={id=editor.api_entity_id(w,row.owner),sub=row.id!=u64(row.owner),alive=row.alive,dead=row.dead,capacity=row.capacity,bytes=row.bytes,paused=row.paused}
        if row.program!=0 {r.emitters[i].program=strings.clone(base.text_get(desc.info.program[:]),call.allocator)}
    }
}
