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
PARTICLE_PARAMS_SCHEMA :: `{"type":"object","properties":{"particle":{"type":"string","description":"An effect: its path under the assets folder, or its id"},"path":{"type":"string","description":"particle.create: where the new effect goes, under the assets folder"},"values":{"type":"object","description":"Fields of the effect to change, as particle.inspect shows them"},"parameters":{"type":"object","description":"Parameters of its Vfx program by name: a number, a list, true or false, or a texture by path or id; null takes one away"},"hidden":{"type":"array","items":{"type":"string"},"description":"The fields its instances do not show; replaces the list"},"resources":{"type":"object","description":"What each resource of its Vfx program reads when an instance binds nothing else, by name: a mesh by its path or id; null takes one away"}},"additionalProperties":false}`

@(private)
PARTICLE_INSTANCE_SET_SCHEMA :: `{"type":"object","properties":{"entity":{`+api.ENTITY_SCHEMA+`,"description":"The entity with the Particle_Emitter"},"values":{"type":"object","description":"Values it shows, as particle.instance.inspect gives them: those that differ from its effect become its own, at most 16 and not its assets or program"},"parameters":{"type":"object","description":"Parameters of the Vfx program of its effect for this entity, by name, at most 8; null takes one away"}},"required":["entity"],"additionalProperties":false}`

// The keys of the params of an effect besides its name, path and values.
@(private)
PARTICLE_EXTRA :: [3]string{"parameters","hidden","resources"}

@(private)
Particle_World :: enum u8 {Edit,Play}

@(private)
Api_Particle_Instance_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    world:Particle_World `mirai:"optional,label=Edit: the document; Play: the Play of the caller"`,
}

@(private)
Api_Particle_Id_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
}

@(private)
Particle_Action :: enum u8 {Start,Stop,Restart,Pause,Resume,Authored,Burst}

@(private)
Api_Particle_Control_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    world:Particle_World `mirai:"optional,label=Edit: the preview of the document; Play: the Play of the caller"`,
    action:Particle_Action `mirai:"label=Start and Stop emit or not whatever active says; Restart drops its particles and starts its cycle; Authored gives it back to its fields; Burst starts count particles at once"`,
    count:u32 `mirai:"optional,max=1048576,label=Particles of a Burst"`,
}

@(private)
Api_Particle_Control_Result :: struct {
    id:base.Entity_Id,
    queued:bool `mirai:"label=It takes the request in its next fixed step"`,
}

@(private)
api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="particle.inspect",params_schema=PARTICLE_PARAMS_SCHEMA,summary="The values of a particle effect (.particle), the parameters of its Vfx program and the fields its instances do not show; problem says why its program would not run.",flags={.Read_Only},run=api_particle_inspect})
    editor.api_method_register(s,{name="particle.set",params_schema=PARTICLE_PARAMS_SCHEMA,summary="Changes the values, Vfx parameters or hidden fields of a particle effect for every entity that shows it, or makes a new one at path over the defaults.",flags={.Idempotent},run=api_particle_set})
    bake:=Api_Grid_Bake_Params{}
    editor.api_method_register(s,Api_Grid_Bake_Params,{name="particle.grid.bake",defaults=&bake,summary="Writes the cells of the grid of an entity of the edited world, as the steps of the next frame leave them, as a .grid at path (one there takes the new state) in an undo step of its own: a Particle_Grid that names it in cached starts from that state. The call holds until the cells come back from the GPU and names the file and its id, or fails when they do not come back.",run=api_grid_bake})
    editor.api_method_register(s,{name="particle.programs",summary="The Vfx programs of the shaders: their parameters with kind, components, default and range, the bytes each keeps per particle, the resources it reads by name (surfaces, bones, channels, grids) and its stages: what each goes over, its iterations and the radius of its neighbors.",flags={.Read_Only},run=api_particle_programs})
    inspect:=Api_Particle_Instance_Params{world=.Edit}
    control:=Api_Particle_Control_Params{world=.Play}
    editor.api_method_register(s,Api_Particle_Instance_Params,{name="particle.instance.inspect",defaults=&inspect,summary="What an emitter shows: the values of its effect with its own over them, its own values by path, the parameters of its program, why its program does not run, and its clock (state, control, seconds, generation, births).",flags={.Read_Only},run=api_particle_instance_inspect})
    editor.api_method_register(s,{name="particle.instance.set",params_schema=PARTICLE_INSTANCE_SET_SCHEMA,summary="In Edit, one undo step: the values given that differ from the effect become the entity's own (at most 16, not its assets or program), and the parameters given its own (at most 8). The result is as particle.instance.inspect's.",run=api_particle_instance_set})
    editor.api_method_register(s,Api_Particle_Id_Params,{name="particle.instance.revert",summary="In Edit, one undo step: the entity takes back every value and parameter of its effect.",run=api_particle_instance_revert})
    editor.api_method_register(s,Api_Particle_Id_Params,{name="particle.instance.apply",summary="Writes the values and parameters the entity shows into its effect, for every entity that shows it, and reverts the entity, in one undo step.",run=api_particle_instance_apply})
    editor.api_method_register(s,Api_Particle_Control_Params,Api_Particle_Control_Result,{name="particle.instance.control",defaults=&control,summary="Asks an emitter in the Play of the caller, or in the preview of the document, to start, stop, restart, pause, resume, go back to its fields or burst count particles. It takes it in its next fixed step; its fields do not change.",run=api_particle_instance_control})
}

// The params of an effect: its name, path and values, its parameters (the
// text of the object) and its hidden fields.
@(private)
Particle_Params :: struct {
    using common:editor.Asset_Params,
    parameters:string,
    resources:string, // the text of the object
    hidden:[dynamic]effect.Particle_Field,
    has_hidden:bool,
}

@(private)
particle_params :: proc(call:^api.Call) -> (p:Particle_Params,ok:bool) {
    extra:=PARTICLE_EXTRA
    p.common=editor.asset_params(call,"particle",extra[:]) or_return
    p.parameters=p.extra[0]
    p.resources=p.extra[2]
    p.hidden=make([dynamic]effect.Particle_Field,context.temp_allocator)
    if p.extra[1]=="" {return p,true}
    p.has_hidden=true
    r:serial.Text_Reader
    serial.text_reader_init(&r,p.extra[1],context.temp_allocator)
    if !serial.text_accept(&r,'[') {
        api.call_fail(call,api.INVALID_PARAMS,"hidden must be an array of the names of fields")
        return p,false
    }
    for !serial.text_accept(&r,']') {
        text,read:=serial.text_string(&r)
        if !read {
            api.call_fail(call,api.INVALID_PARAMS,"hidden must be an array of the names of fields")
            return p,false
        }
        entry:effect.Particle_Field
        base.text_set(entry.name[:],text)
        append(&p.hidden,entry)
        serial.text_accept(&r,',')
    }
    return p,true
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

// Puts the parameters of the params ({name: value|null}) over list, as the
// program of the effect declares them.
@(private)
particle_parameters_read :: proc(s:^editor.Session,call:^api.Call,text:string,info:^effect.Particle_Info,list:^[dynamic]effect.Particle_Parameter) -> bool {
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
            for &stored,at in list {
                if base.text_get(stored.name[:])==name {ordered_remove(list,at);break}
            }
        } else {
            if program==nil {return fail(call,"parameters: %s",problem!="" ? problem : "the effect has no Vfx program: name one in program first")}
            declared:=erender.program_parameter(program,name)
            if declared==nil {return fail(call,"parameters: %s has no parameter %q; particle.programs lists them",program.name,name)}
            parameter:=effect.Particle_Parameter{kind=asset.Parameter_Kind(declared.kind),components=declared.components}
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
            if stored:=effect.particle_parameter_find(list[:],name);stored!=nil {stored^=parameter} else {append(list,parameter)}
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

@(private)
particle_parameters_write :: proc(out:^serial.Writer,key:string,list:[]effect.Particle_Parameter) {
    api.write_key(out,key)
    serial.write_u8(out,'{')
    for &parameter,i in list {
        if i>0 {serial.write_u8(out,',')}
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
    out:=call.out
    editor.asset_named_write(s,out,"particle",id)
    editor.asset_values_write(out,"values",view.info)
    particle_parameters_write(out,"parameters",view.parameters)
    api.write_key(out,"hidden")
    serial.write_u8(out,'[')
    for &h,i in view.hidden {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,base.text_get(h.name[:]))
    }
    serial.write_u8(out,']')
    api.write_key(out,"resources")
    serial.write_u8(out,'{')
    for &resource,i in view.resources {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,base.text_get(resource.name[:]))
        serial.write_u8(out,':')
        serial.write_u8(out,'"')
        serial.text_write_asset_id(out,resource.mesh)
        serial.write_u8(out,'"')
    }
    serial.write_u8(out,'}')
    program:vfx.Program
    api.write_text(out,"problem",vfx.particle_program(a,id,view.info,nil,&program))
    serial.write_u8(out,'}')
}

@(private)
api_particle_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p,read:=particle_params(call)
    if !read {return}
    id,found:=editor.asset_named(s,call,p.named,effect.KIND,effect.EXTENSION,"a particle effect")
    if !found {return}
    api_particle_write(s,call,id)
}

// The file of the params over file: its values, its parameters and its hidden fields.
@(private)
particle_params_apply :: proc(s:^editor.Session,call:^api.Call,p:^Particle_Params,file:^Particle_File) -> bool {
    if !editor.asset_values_read(call,p.values,&file.info) {return false}
    if !particle_parameters_read(s,call,p.parameters,&file.info,&file.parameters) {return false}
    if p.has_hidden {
        clear(&file.hidden)
        append(&file.hidden,..p.hidden[:])
    }
    if !particle_resources_read(s,call,p.resources,&file.info,&file.resources) {return false}
    if problem:=effect.particle_validate({info=&file.info,parameters=file.parameters[:],hidden=file.hidden[:],resources=file.resources[:]});problem.message!="" {
        api.call_failf(call,api.INVALID_PARAMS,"%s: %s",problem.field,problem.message)
        return false
    }
    // Values a program the shaders have does not take are refused; a program they do not have yet is named all the same.
    if program,_:=particle_program_of(s,&file.info);program!=nil {
        checked:vfx.Program
        if problem:=vfx.particle_program_check(s.app.assets,&file.info,file.parameters[:],nil,&checked);problem!="" {
            api.call_failf(call,api.INVALID_PARAMS,"parameters: %s",problem)
            return false
        }
    }
    return true
}

// The resources of the text of an object over list: a name of a surface the
// program of the effect reads and a mesh by its path or id, or null to take it
// away.
@(private)
particle_resources_read :: proc(s:^editor.Session,call:^api.Call,text:string,info:^effect.Particle_Info,list:^[dynamic]effect.Particle_Resource) -> bool {
    if text=="" {return true}
    program,problem:=particle_program_of(s,info)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    malformed :: proc(call:^api.Call) -> bool {
        api.call_fail(call,api.INVALID_PARAMS,"resources: give an object of the names of the resources of the program and a mesh by its path or id, or null")
        return false
    }
    if !serial.text_accept(&r,'{') {return malformed(call)}
    for !serial.text_accept(&r,'}') {
        serial.text_space(&r)
        name,named:=serial.text_string(&r)
        if !named || !serial.text_expect(&r,':') {return malformed(call)}
        name=strings.clone(name,context.temp_allocator)
        serial.text_space(&r)
        at:=-1
        for &stored,i in list {
            if base.text_get(stored.name[:])==name {at=i}
        }
        if serial.text_keyword(&r,"null") {
            if at>=0 {ordered_remove(list,at)}
        } else {
            if program==nil {
                api.call_failf(call,api.INVALID_PARAMS,"resources: %s",problem!="" ? problem : "the effect has no Vfx program: name one in program first")
                return false
            }
            surface:=false
            for &declared in program.resources {surface||=declared.name==name && (declared.kind==.Surface || declared.kind==.Bones)}
            if !surface {
                api.call_failf(call,api.INVALID_PARAMS,"resources: %s reads no surface or bones %q; particle.programs lists its resources",program.name,name)
                return false
            }
            path,read:=serial.text_string(&r)
            if !read {return malformed(call)}
            mesh,found:=editor.asset_named(s,call,path,asset.KIND_MESH,".mesh","a mesh")
            if !found {return false}
            resource:effect.Particle_Resource
            base.text_set(resource.name[:],name)
            resource.mesh=mesh
            if at>=0 {list[at]=resource} else {append(list,resource)}
        }
        serial.text_accept(&r,',')
    }
    return true
}

@(private)
api_particle_set :: proc(s:^editor.Session,call:^api.Call) {
    p,read:=particle_params(call)
    if !read {return}
    t,found:=editor.asset_target(s,call,&p.common,"particle",effect.KIND,effect.EXTENSION,"a particle effect")
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
    out:=call.out
    serial.text_write_raw(out,`{"programs":[`)
    first:=true
    if s.app.renderer!=nil {
        for &program in erender.programs(s.app.renderer) {
            if program.domain!=.Vfx {continue}
            if !first {serial.write_u8(out,',')}
            first=false
            serial.write_u8(out,'{')
            api.write_text(out,"name",program.name,first=true)
            api.write_uint(out,"attributes",u64(program.attributes))
            api.write_key(out,"parameters")
            serial.write_u8(out,'[')
            for &parameter,i in program.parameters {
                if i>0 {serial.write_u8(out,',')}
                serial.write_u8(out,'{')
                api.write_text(out,"name",parameter.name,first=true)
                api.write_text(out,"kind",fmt.tprint(parameter.kind))
                api.write_uint(out,"components",u64(parameter.components))
                if parameter.kind!=.Texture {
                    api.write_key(out,"default")
                    serial.write_u8(out,'[')
                    for value,axis in parameter.defaults[:parameter.components] {
                        if axis>0 {serial.write_u8(out,',')}
                        serial.text_write_float(out,transmute(u64)value,8)
                    }
                    serial.write_u8(out,']')
                    api.write_key(out,"min");serial.text_write_float(out,transmute(u64)parameter.min,8)
                    api.write_key(out,"max");serial.text_write_float(out,transmute(u64)parameter.max,8)
                }
                serial.write_u8(out,'}')
            }
            serial.write_u8(out,']')
            api.write_key(out,"resources")
            serial.write_u8(out,'[')
            for &resource,i in program.resources {
                if i>0 {serial.write_u8(out,',')}
                serial.write_u8(out,'{')
                api.write_text(out,"name",resource.name,first=true)
                api.write_text(out,"kind",fmt.tprint(resource.kind))
                serial.write_u8(out,'}')
            }
            serial.write_u8(out,']')
            api.write_key(out,"stages")
            serial.write_u8(out,'[')
            for &stage,i in program.stages {
                if i>0 {serial.write_u8(out,',')}
                serial.write_u8(out,'{')
                api.write_text(out,"name",stage.name,first=true)
                over:="particles"
                if stage.over!=erender.PROGRAM_STAGE_PARTICLES && int(stage.over)<len(program.resources) {over=program.resources[stage.over].name}
                api.write_text(out,"over",over)
                api.write_uint(out,"iterations",u64(stage.iterations))
                api.write_key(out,"neighbors");serial.text_write_float(out,transmute(u64)f64(stage.neighbors),8)
                serial.write_u8(out,'}')
            }
            serial.text_write_raw(out,"]}")
        }
    }
    serial.text_write_raw(out,"]}")
}

// ---------------------------------------------------------------- instances

// The world an instance method acts on: the document, or the Play of the caller.
@(private)
particle_world :: proc(s:^editor.Session,call:^api.Call,world:Particle_World) -> (w:core.World_Ref,ok:bool) {
    if world==.Edit {return editor.edited_world(s),true}
    r,_:=editor.api_play_run(s,call)
    if r==nil {
        api.call_fail(call,api.INVALID_PARAMS,"Start a Play (play.start) before addressing its emitters, or use world Edit")
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

// The text of each value of an instance, by the path of its field.
@(private)
particle_overrides_write :: proc(out:^serial.Writer,override:^vfx.Particle_Override) {
    api.write_key(out,"overrides")
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
            serial.text_write_string(out,field.path)
            serial.write_u8(out,':')
            type,_:=serial.schema_add_type_info(&schema,field.info)
            serial.text_write(out,&schema,type,override.values[i][:field.size],.Line)
        }
    }
    serial.write_u8(out,'}')
}

@(private)
particle_instance_write :: proc(s:^editor.Session,call:^api.Call,w:core.World_Ref,e:core.Entity,world:Particle_World) {
    a:=s.app.assets
    emitter,_:=editor.entity_get(w,e,vfx.Particle_Emitter)
    override,_:=editor.entity_get(w,e,vfx.Particle_Override)
    given,_:=editor.entity_get(w,e,vfx.Particle_Parameters)
    info:effect.Particle_Info
    error:=vfx.particle_resolve_checked(a,emitter.particle,&override,&info)
    out:=call.out
    serial.write_u8(out,'{')
    api.write_key(out,"id",first=true)
    api.write_id(out,editor.api_entity_id(w,e))
    api.write_text(out,"world",fmt.tprint(world))
    api.write_key(out,"particle")
    serial.write_u8(out,'"')
    serial.text_write_asset_id(out,emitter.particle)
    serial.write_u8(out,'"')
    editor.asset_values_write(out,"values",&info)
    particle_overrides_write(out,&override)
    particle_parameters_write(out,"parameters",given.values[:min(given.count,vfx.PARTICLE_PARAMETER_CAPACITY)])
    problem:=vfx.error_message(error)
    if problem=="" {
        program:vfx.Program
        problem=vfx.particle_program(a,emitter.particle,&info,&given,&program)
    }
    api.write_text(out,"problem",problem)
    if clocks:=core.world_storage_of(w,vfx.Particle_Clocks);clocks!=nil {
        if status,found:=vfx.status(clocks,emitter,e);found {
            api.write_key(out,"status")
            serial.write_u8(out,'{')
            api.write_text(out,"state",fmt.tprint(status.state),first=true)
            api.write_text(out,"control",fmt.tprint(status.control))
            api.write_key(out,"seconds");serial.text_write_float(out,transmute(u64)status.time,8)
            api.write_uint(out,"generation",u64(status.generation))
            api.write_uint(out,"births",status.emitted)
            serial.write_u8(out,'}')
        }
    }
    // What the GPU copied back of its particles, and the editor watches it from now on.
    if sync:=host.app_world_storage(s.app,s.edit_world,vfx.Particle_Sync);sync!=nil {
        sync.watch=u64(e)
        if list,frame,ok:=vfx.watched(sync,s.app.renderer);ok {
            api.write_key(out,"gpu")
            serial.write_u8(out,'{')
            api.write_uint(out,"alive",u64(len(list)),first=true)
            if state,read:=vfx.watched_state(sync,s.app.renderer);read {
                api.write_uint(out,"dead",u64(state.dead))
                api.write_uint(out,"births",u64(state.births))
                api.write_uint(out,"born",u64(state.born))
            }
            api.write_uint(out,"frame",frame)
            api.write_key(out,"particles")
            serial.write_u8(out,'[')
            for p,i in list[:min(len(list),8)] {
                if i>0 {serial.write_u8(out,',')}
                serial.write_u8(out,'{')
                api.write_uint(out,"slot",u64(p.slot),first=true)
                for value,name in ([2][3]f32{p.position,p.velocity}) {
                    api.write_key(out,"position" if name==0 else "velocity")
                    serial.write_u8(out,'[');watch_float(out,value.x);serial.write_u8(out,',');watch_float(out,value.y);serial.write_u8(out,',');watch_float(out,value.z);serial.write_u8(out,']')
                }
                api.write_key(out,"age");watch_float(out,p.age)
                api.write_key(out,"size");watch_float(out,p.size)
                api.write_uint(out,"seed",u64(p.seed))
                api.write_key(out,"attributes")
                serial.write_u8(out,'[')
                for word,k in p.attributes[:min(len(p.attributes),48)] {
                    if k>0 {serial.write_u8(out,',')}
                    watch_float(out,transmute(f32)word)
                }
                serial.write_u8(out,']')
                serial.write_u8(out,'}')
            }
            serial.write_u8(out,']')
            serial.write_u8(out,'}')
        }
    }
    serial.write_u8(out,'}')
}

@(private)
watch_float :: proc(out:^serial.Writer,value:f32) {serial.text_write_float(out,transmute(u64)f64(value),8)}

@(private)
api_particle_instance_inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Api_Particle_Instance_Params)
    w,ok:=particle_world(s,call,p.world)
    if !ok {return}
    e,found:=particle_entity(w,call,p.entity[:])
    if found {particle_instance_write(s,call,w,e,p.world)}
}

@(private)
api_particle_instance_set :: proc(s:^editor.Session,call:^api.Call) {
    if editor.watching(s) {
        api.call_fail(call,api.INVALID_PARAMS,"Stop watching another run before editing the document")
        return
    }
    request:editor.Rpc_Args
    editor.rpc_init(&request,call,call.raw)
    if !editor.rpc_object_begin(&request,"params") {return}
    fields:editor.Rpc_Object
    named:editor.Api_Entity_Text
    values,parameters:string
    has_id:bool
    for key in editor.rpc_next(&request,&fields) {
        switch key {
        case "entity": _,has_id=editor.rpc_text(&request,"entity",named[:])
        case "values": values,_=editor.rpc_raw(&request)
        case "parameters": parameters,_=editor.rpc_raw(&request)
        }
    }
    if request.failed {return}
    if !has_id {
        api.call_fail(call,api.INVALID_PARAMS,"entity is required")
        return
    }
    w:=editor.edited_world(s)
    e,found:=particle_entity(w,call,named[:])
    if !found {return}
    emitter,_:=editor.entity_get(w,e,vfx.Particle_Emitter)
    override,_:=editor.entity_get(w,e,vfx.Particle_Override)
    given,_:=editor.entity_get(w,e,vfx.Particle_Parameters)
    file:=particle_file(s,emitter.particle)
    // The values it shows, with those given over them; what differs from the effect is its own.
    shown:=vfx.particle_resolve(s.app.assets,emitter.particle,&override)
    if !editor.asset_values_read(call,values,&shown) {return}
    if problem:=effect.particle_validate({info=&shown});problem.message!="" {
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
        if next.count==vfx.PARTICLE_OVERRIDE_CAPACITY {
            api.call_fail(call,api.INVALID_PARAMS,vfx.error_message(.Override_Capacity))
            return
        }
        next.names[next.count]=base.name_hash(field.path)
        copy(next.values[next.count][:],now)
        next.count+=1
    }
    list:=make([dynamic]effect.Particle_Parameter,context.temp_allocator)
    append(&list,..given.values[:min(given.count,vfx.PARTICLE_PARAMETER_CAPACITY)])
    if !particle_parameters_read(s,call,parameters,&file.info,&list) {return}
    if len(list)>vfx.PARTICLE_PARAMETER_CAPACITY {
        api.call_fail(call,api.INVALID_PARAMS,vfx.error_message(.Parameter_Capacity))
        return
    }
    checked:vfx.Program
    if problem:=vfx.particle_program_check(s.app.assets,&file.info,file.parameters[:],list[:],&checked);problem!="" {
        api.call_failf(call,api.INVALID_PARAMS,"parameters: %s",problem)
        return
    }
    next_given:vfx.Particle_Parameters
    next_given.count=u32(len(list))
    copy(next_given.values[:],list[:])
    if !editor.api_edit_begin(s,call,"Particle values") {return}
    w=editor.edited_world(s)
    values_table,parameters_table:=core.world_table_of(w,vfx.Particle_Override),core.world_table_of(w,vfx.Particle_Parameters)
    if values_table==nil || parameters_table==nil {editor.api_edit_end(s,call,false);return}
    if next.count>0 {core.add(values_table,e,next)} else if core.has(values_table,e) {core.remove(values_table,e)}
    if next_given.count>0 {core.add(parameters_table,e,next_given)} else if core.has(parameters_table,e) {core.remove(parameters_table,e)}
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

// Takes from the entity its values and its parameters for its effect.
@(private)
instance_clear :: proc(w:core.World_Ref,e:core.Entity) {
    for table in ([2]^core.Raw_Table{core.raw(core.world_table_of(w,vfx.Particle_Override)),core.raw(core.world_table_of(w,vfx.Particle_Parameters))}) {
        if table!=nil && core.raw_row(table,e)>=0 {core.raw_remove(table,e)}
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
    given,_:=editor.entity_get(w,e,vfx.Particle_Parameters)
    file:=particle_file(s,emitter.particle)
    file.info=vfx.particle_resolve(s.app.assets,emitter.particle,&override)
    for &parameter in given.values[:min(given.count,vfx.PARTICLE_PARAMETER_CAPACITY)] {
        if stored:=effect.particle_parameter_find(file.parameters[:],base.text_get(parameter.name[:]));stored!=nil {stored^=parameter} else {append(&file.parameters,parameter)}
    }
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
    case .Authored: vfx.authored(requests,e)
    case .Burst: vfx.burst(requests,e,p.count)
    }
    api.call_result(call,Api_Particle_Control_Result)^={id=editor.api_entity_id(w,e),queued=true}
}
