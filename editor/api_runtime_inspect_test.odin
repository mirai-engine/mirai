package editor

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Inspect_Config :: struct {speed:f32,compiled:[2]u32 `mirai:"hidden"`,diagnostics:u32 `mirai:"transient,hidden"`}
@(private="file")
Inspect_Runtime :: struct {ticks:u32 `mirai:"transient"`}
@(private="file")
Inspect_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    transforms:core.Table(core.Transform),
    config:core.Table(Inspect_Config),
    state:core.Table(Inspect_Runtime),
}
@(private="file") Inspect_Editor :: struct {api:Api}

@(test)
a_name_of_a_component_or_a_key_resolves_as_it_is_written_or_says_the_nearest :: proc(t:^testing.T) {
    tables:=[]core.Table_Info{{name="Point_Light",place=.World},{name="Spot_Light",place=.World},{name="Hidden_State",place=.Editor}}
    info:=core.World_Info{tables=tables}
    w:=core.World_Ref{info=&info,place=.World}
    cases:=[]struct{name:string,found:^core.Table_Info,says:string}{
        {"Point_Light",&tables[0],""},
        {"PointLight",&tables[0],""},
        {"spot light",&tables[1],""},
        {"Hidden_State",nil,`"Hidden_State" is not a component of the world`},
        {"Light",nil,`"Light" is not a component of the world; the nearest are Spot_Light, Point_Light`},
    }
    for c in cases {
        found,problem:=api_component_named(w,c.name)
        testing.expectf(t,found==c.found && strings.has_prefix(problem,c.says),"%s: %s",c.name,problem)
    }
    key,known:=api_key_from_name("left-control")
    testing.expect(t,known && key==.Left_Control)
    _,known=api_key_from_name("Return")
    testing.expect(t,!known)
}

@(test)
api_inspection_can_read_transient_state_without_making_it_editable_or_saved :: proc(t:^testing.T) {
    world:Inspect_World
    core.entities_init(&world.entities);defer core.entities_destroy(&world.entities)
    core.table_init(&world.ids,"Id");defer core.table_destroy(&world.ids)
    core.table_init(&world.transforms,"Transform");defer core.table_destroy(&world.transforms)
    core.table_init(&world.config,"Inspect_Config");defer core.table_destroy(&world.config)
    core.table_init(&world.state,"Inspect_Runtime");defer core.table_destroy(&world.state)
    tables:=[4]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Inspect_World,ids)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Inspect_World,transforms)},
        {name="Inspect_Config",type=Inspect_Config,info=type_info_of(Inspect_Config),offset=offset_of(Inspect_World,config)},
        {name="Inspect_Runtime",type=Inspect_Runtime,info=type_info_of(Inspect_Runtime),offset=offset_of(Inspect_World,state)},
    }
    storages:=[1]core.Storage_Info{{name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(Inspect_Editor,api)}}
    info:=core.World_Info{entities=offset_of(Inspect_World,entities),tables=tables[:],storages=storages[:]}
    state:Api_State
    editor:=Inspect_Editor{api={state=&state}}
    document:Document
    edits:Edits
    session:=Session{info=&info,editor_world=&editor,edit_world=&world,document=&document,edits=&edits}
    api_schema_build(&session,&state)
    defer api_schema_free(&state)
    entity:=core.create(&world.entities)
    core.add(&world.ids,entity,core.Id{7})
    core.add(&world.transforms,entity,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&world.config,entity,Inspect_Config{speed=2,compiled={8,9},diagnostics=13})
    core.add(&world.state,entity,Inspect_Runtime{ticks=21})
    core.table_settle(&world.ids,&world.entities)
    core.table_settle(&world.transforms,&world.entities)
    core.table_settle(&world.config,&world.entities)
    core.table_settle(&world.state,&world.entities)
    core.entities_settle(&world.entities)
    testing.expect(t,!inspector_listed(&session,&tables[3]))
    testing.expect(t,!api_component_listed(&session,&tables[3]))
    testing.expect(t,api_component_listed(&session,&tables[3],true))
    testing.expect(t,!api_component_listed(&session,&tables[1],true))
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    scratch:=make([]u8,state.largest);defer delete(scratch)
    w:=edited_world(&session)
    version:=world.config.version
    api_entity_write(&session,w,&out,entity,true,scratch,true)
    text:=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,`"Inspect_Config":{"speed": 2}`))
    testing.expect(t,!strings.contains(text,"compiled") && !strings.contains(text,"diagnostics") && !strings.contains(text,"Inspect_Runtime"))
    out.count=0
    api_entity_write(&session,w,&out,entity,true,scratch,true,true)
    text=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,`"diagnostics": 13`))
    testing.expect(t,strings.contains(text,`"compiled": [8, 9]`))
    testing.expect(t,strings.contains(text,`"Inspect_Runtime":{"ticks": 21}`))
    testing.expect_value(t,world.config.version,version)
    config,_:=core.get(core.read(&world.config),entity)
    testing.expect_value(t,config.diagnostics,u32(13))
    testing.expect_value(t,config.compiled,[2]u32{8,9})
    out.count=0;first:=true
    api_fields_write(&out,&state.schema,state.types[2],"",&first)
    text=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,`"path":"speed"`) && !strings.contains(text,"compiled") && !strings.contains(text,"diagnostics"))
    out.count=0;first=true
    api_fields_write(&out,&state.schema,state.types[2],"",&first,true)
    text=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,"compiled") && strings.contains(text,"diagnostics"))
    running:Inspect_World
    core.entities_init(&running.entities);defer core.entities_destroy(&running.entities)
    core.table_init(&running.ids,"Id");defer core.table_destroy(&running.ids)
    core.table_init(&running.transforms,"Transform");defer core.table_destroy(&running.transforms)
    core.table_init(&running.config,"Inspect_Config");defer core.table_destroy(&running.config)
    core.table_init(&running.state,"Inspect_Runtime");defer core.table_destroy(&running.state)
    core.entities_copy(&running.entities,&world.entities)
    core.table_copy(&running.ids,&world.ids)
    core.table_copy(&running.transforms,&world.transforms)
    core.table_copy(&running.config,&world.config)
    core.table_copy(&running.state,&world.state)
    core.get(&running.transforms,entity).position.x=8
    core.get(&running.config,entity).diagnostics=99
    core.get(&running.state,entity).ticks=42
    session.mode=.Play
    session.runs[0]={world=&running}
    params:=Api_Inspect_Params{include_runtime=true,limit=1}
    method:=api.Method{params_id=Api_Inspect_Params}
    selections:=[]struct{raw,has,lacks,fails:string}{
        {`{"components":true}`,`"ticks": 42`,"",""},
        {`{}`,`"components":["`,`"ticks"`,""},
        {`{"components":false}`,"","","components must be true"},
        {`{"components":["inspect config"]}`,`"speed"`,`"ticks"`,""},
        {`{"components":"Inspect_Runtime"}`,`"ticks": 42`,`"speed"`,""},
        {`{"components":["Inspect"]}`,"","",`"Inspect" is not a component of the world; the nearest are Inspect_Config, Inspect_Runtime`},
        {`{"components":["Transform"]}`,"","","Transform has no values"},
        {`{"components":7}`,"","","components must be true"},
    }
    for selection in selections {
        call:=api.Call{method=&method,raw=selection.raw,params=&params,out=&out,allocator=context.temp_allocator}
        out.count=0
        api_play_inspect(&session,&call)
        text:=string(serial.writer_bytes(&out))
        if selection.fails!="" {
            testing.expectf(t,call.failed && strings.contains(call.error.message,selection.fails),"%s: %s",selection.raw,call.error.message)
            continue
        }
        testing.expectf(t,!call.failed,"%s: %s",selection.raw,call.error.message)
        testing.expectf(t,strings.contains(text,selection.has),"%s: %s",selection.raw,text)
        testing.expectf(t,selection.lacks=="" || !strings.contains(text,selection.lacks),"%s: %s",selection.raw,text)
    }
    call:=api.Call{method=&method,raw=`{"components":true}`,params=&params,out=&out,allocator=context.temp_allocator}
    out.count=0
    api_play_inspect(&session,&call)
    testing.expect(t,!call.failed,call.error.message)
    text=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,`"position":[8,0,0]`),text)
    testing.expect(t,strings.contains(text,`"diagnostics": 99`) && strings.contains(text,`"ticks": 42`))
    out.count=0
    api_scene_inspect(&session,&call)
    text=string(serial.writer_bytes(&out))
    testing.expect(t,strings.contains(text,`"position":[0,0,0]`))
    testing.expect(t,strings.contains(text,`"diagnostics": 13`) && strings.contains(text,`"ticks": 21`))
    testing.expect_value(t,world.config.version,version)
    config,_=core.get(core.read(&world.config),entity)
    testing.expect_value(t,config.diagnostics,u32(13))
}

@(private="file")
Filter_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    names:core.Table(core.Name),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    cameras:core.Table(erender.Camera),
    hierarchy:core.Hierarchy,
}

@(private="file")
filter_world_settle :: proc(data,shared,editor:rawptr) {
    w:=cast(^Filter_World)data
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.names,&w.entities);core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.parents,&w.entities);core.table_settle(&w.cameras,&w.entities)
    core.hierarchy_settle(&w.hierarchy,core.read(&w.parents),&w.entities)
    core.entities_settle(&w.entities)
}

@(private="file")
filter_world_destroy :: proc(w:^Filter_World) {
    core.entities_destroy(&w.entities)
    core.table_destroy(&w.ids);core.table_destroy(&w.names);core.table_destroy(&w.transforms)
    core.table_destroy(&w.parents);core.table_destroy(&w.cameras)
    core.value_free(&w.hierarchy,type_info_of(core.Hierarchy))
}

@(private="file")
filter_entity :: proc(w:^Filter_World,id:u64,name:string,parent:=core.NONE) -> core.Entity {
    e:=core.create(&w.entities)
    label:core.Name
    base.text_set(label.text[:],name)
    if id!=0 {core.add(&w.ids,e,{value=base.Entity_Id(id)})}
    core.add(&w.names,e,label)
    core.add(&w.transforms,e,core.Transform{position={f32(id),0,0},rotation=1,scale={1,1,1}})
    if parent!=core.NONE {core.add(&w.parents,e,core.Parent{entity=parent})}
    return e
}

@(test)
inspect_filters_by_name_and_component_and_summarizes_without_values :: proc(t:^testing.T) {
    world,running:Filter_World
    core.entities_init(&world.entities);defer filter_world_destroy(&world)
    core.entities_init(&running.entities);defer filter_world_destroy(&running)
    tables:=[5]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Filter_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Filter_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Filter_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Filter_World,parents)},
        {name="Camera",type=erender.Camera,info=type_info_of(erender.Camera),offset=offset_of(Filter_World,cameras)},
    }
    storages:=[2]core.Storage_Info{
        {type=Api,info=type_info_of(Api),place=.Editor},
        {type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Filter_World,hierarchy)},
    }
    info:=core.World_Info{entities=offset_of(Filter_World,entities),tables=tables[:],storages=storages[:],settle=filter_world_settle}
    rig:=filter_entity(&world,1,"Rig")
    core.add(&world.cameras,filter_entity(&world,2,"Main Camera",rig),erender.CAMERA_DEFAULT)
    filter_entity(&world,3,"Crate 1");filter_entity(&world,4,"Crate 2");filter_entity(&world,5,"crate 3")
    filter_world_settle(&world,nil,nil)
    for i in 0..<300 {filter_entity(&running,0,fmt.tprintf("Body %d",i))}
    filter_world_settle(&running,nil,nil)
    selection:Selection;defer delete(selection.entities)
    viewport:Viewport;gui:Editor_Ui;edits:Edits;defer edits_free(&edits)
    document:Document
    api_storage:Api
    session:=Session{info=&info,edit_world=&world,editor_world=&api_storage,selection=&selection,viewport=&viewport,gui=&gui,edits=&edits,document=&document}
    edits_reset(&edits,edited_world(&session))
    if !testing.expect(t,api_open(&session,0,true)==.None) {return};defer api_close(&session)
    state:=api_state(&session);state.poll_temp=context.temp_allocator
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    inspect :: proc(state:^Api_State,out:^serial.Writer,method,params:string) -> (error:api.Error,result:json.Object,text:string) {
        base.arena_reset(&state.server.scratch);serial.writer_reset(out)
        error,_=api.method_execute(&state.server,api.method_find(&state.server,method),params,out)
        text=string(serial.writer_bytes(out))
        value:json.Value
        if error.code==0 && json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil {result,_=value.(json.Object)}
        return
    }
    number :: proc(value:json.Value) -> int {
        #partial switch n in value {
        case json.Integer: return int(n)
        case json.Float:   return int(n)
        }
        return -1
    }
    names :: proc(result:json.Object) -> string {
        b:=strings.builder_make(context.temp_allocator)
        for entity,i in result["entities"].(json.Array) {fmt.sbprintf(&b,"%s%s",i==0?"":",",entity.(json.Object)["name"].(string))}
        return strings.to_string(b)
    }

    error,result,text:=inspect(state,&out,"scene.inspect",`{"name":"Crate 1"}`)
    testing.expect_value(t,error.code,0)
    testing.expect_value(t,names(result),"Crate 1")
    _,result,_=inspect(state,&out,"scene.inspect",`{"name":"Crate*"}`)
    testing.expect_value(t,names(result),"Crate 1,Crate 2")
    testing.expect_value(t,number(result["matched"]),2)
    testing.expect_value(t,number(result["total"]),5)
    _,result,_=inspect(state,&out,"scene.inspect",`{"name":"*a*e*3"}`)
    testing.expect_value(t,names(result),"crate 3")
    _,result,_=inspect(state,&out,"scene.inspect",`{"name":"*Camera"}`)
    testing.expect_value(t,names(result),"Main Camera")
    error,result,text=inspect(state,&out,"scene.inspect",`{"component":"Camera"}`)
    testing.expect_value(t,names(result),"Main Camera")
    testing.expectf(t,strings.contains(text,`"parent":"0x0000000000000001","position":[`) && strings.contains(text,`"components":["Camera"]}`),"the place and the names of the components: %s",text)
    testing.expectf(t,!strings.contains(text,"near"),"without the values: %s",text)
    _,result,text=inspect(state,&out,"scene.inspect",`{"component":"Camera","components":true}`)
    testing.expect(t,strings.contains(text,`"components":{"Camera":{`) && strings.contains(text,`"near"`),"the values when it asks for them")
    error,_,text=inspect(state,&out,"scene.inspect",`{"component":"Light"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expect(t,strings.contains(error.message,"component.list"),"the error says where the components are")
    _,result,_=inspect(state,&out,"scene.inspect",`{"limit":2,"offset":1}`)
    testing.expect_value(t,names(result),"Main Camera,Crate 1")
    testing.expect_value(t,[3]int{number(result["shown"]),number(result["matched"]),number(result["omitted"])},[3]int{2,5,2})
    _,result,_=inspect(state,&out,"scene.inspect",`{"name":"Crate*","offset":1}`)
    testing.expect_value(t,names(result),"Crate 2")
    testing.expect_value(t,number(result["omitted"]),0)
    _,result,_=inspect(state,&out,"scene.inspect",`{"entity":"0000000000000003","name":"Crate 2"}`)
    testing.expect_value(t,number(result["matched"]),0)

    session.mode=.Play
    session.runs[0]={world=&running}
    _,result,text=inspect(state,&out,"play.inspect",`{}`)
    testing.expect_value(t,[3]int{number(result["shown"]),number(result["matched"]),number(result["omitted"])},[3]int{API_INSPECT_BRIEF,300,300-API_INSPECT_BRIEF})
    testing.expectf(t,len(text)<256*API_INSPECT_BRIEF,"with no filter it stays small: %d bytes",len(text))
    testing.expectf(t,strings.contains(result["left_out"].(string),"more entities"),"it says what it left out: %s",text)
    _,result,_=inspect(state,&out,"play.inspect",`{"name":"Body*"}`)
    testing.expect_value(t,number(result["shown"]),API_INSPECT_DEFAULT)
    _,result,text=inspect(state,&out,"component.list",`{}`)
    testing.expectf(t,strings.contains(text,`"name":"Camera"`) && !strings.contains(text,`"fields"`) && strings.contains(text,`"left_out"`),"the index of the components: %s",text)
    _,result,text=inspect(state,&out,"component.list",`{"name":"Camera"}`)
    testing.expectf(t,strings.contains(text,`"default"`) && strings.contains(text,`"fields"`) && !strings.contains(text,`"left_out"`),"one whole: %s",text)
    _,result,text=inspect(state,&out,"component.list",`{"names":["Camera","Transform"]}`)
    testing.expectf(t,strings.count(text,`"fields"`)==2,"several in one call: %s",text)
    _,result,_=inspect(state,&out,"play.inspect",`{"name":"Body 29*"}`)
    testing.expect_value(t,number(result["matched"]),11)
    testing.expect_value(t,result["entities"].(json.Array)[0].(json.Object)["name"].(string),"Body 29")
}

@(private="file") Inspect_Drivable :: struct {seat,camera:core.Entity}
@(private="file")
Spawned_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    drivables:core.Table(Inspect_Drivable),
}

// A prefab spawned while playing has no Ids: play.inspect names its parent
// and the entities its fields hold by handle, as it names the entity, and
// scene.inspect keeps the Ids of an edited world.
@(test)
play_inspection_names_the_references_of_spawned_entities_by_handle :: proc(t:^testing.T) {
    world:Spawned_World
    core.entities_init(&world.entities);defer core.entities_destroy(&world.entities)
    core.table_init(&world.ids,"Id");defer core.table_destroy(&world.ids)
    core.table_init(&world.parents,"Parent");defer core.table_destroy(&world.parents)
    core.table_init(&world.drivables,"Inspect_Drivable");defer core.table_destroy(&world.drivables)
    tables:=[3]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Spawned_World,ids)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Spawned_World,parents)},
        {name="Inspect_Drivable",type=Inspect_Drivable,info=type_info_of(Inspect_Drivable),offset=offset_of(Spawned_World,drivables)},
    }
    storages:=[1]core.Storage_Info{{name="Api",type=Api,info=type_info_of(Api),place=.Editor,offset=offset_of(Inspect_Editor,api)}}
    info:=core.World_Info{entities=offset_of(Spawned_World,entities),tables=tables[:],storages=storages[:]}
    state:Api_State
    editor:=Inspect_Editor{api={state=&state}}
    document:Document
    edits:Edits
    session:=Session{info=&info,editor_world=&editor,edit_world=&world,document=&document,edits=&edits}
    api_schema_build(&session,&state)
    defer api_schema_free(&state)
    root,camera:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.parents,camera,core.Parent{entity=root})
    core.add(&world.drivables,root,Inspect_Drivable{camera=camera})
    core.table_settle(&world.parents,&world.entities);core.table_settle(&world.drivables,&world.entities)
    core.entities_settle(&world.entities)
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    scratch:=make([]u8,state.largest);defer delete(scratch)
    w:=edited_world(&session)
    api_entity_write(&session,w,&out,root,true,scratch,true)
    text:=string(serial.writer_bytes(&out))
    testing.expectf(t,strings.contains(text,fmt.tprintf(`"camera": "0x%016x"`,u64(camera))),"the field holds the handle: %s",text)
    out.count=0
    api_entity_write(&session,w,&out,camera,false,scratch,true)
    text=string(serial.writer_bytes(&out))
    testing.expectf(t,strings.contains(text,fmt.tprintf(`"parent":"0x%016x"`,u64(root))),"the parent is the handle: %s",text)
    core.add(&world.ids,root,core.Id{5});core.add(&world.ids,camera,core.Id{6})
    core.table_settle(&world.ids,&world.entities)
    out.count=0
    api_entity_write(&session,w,&out,root,true,scratch,false)
    text=string(serial.writer_bytes(&out))
    testing.expectf(t,strings.contains(text,`"camera": "0x0000000000000006"`),"an edited world shows Ids: %s",text)
}
