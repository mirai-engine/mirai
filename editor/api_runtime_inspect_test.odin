package editor

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import erender "mirai:engine/render"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file")
Inspect_Config :: struct {speed:f32,compiled:[2]u32 `mirai:"hidden"`,diagnostics:u32 `mirai:"transient,hidden"`}
@(private="file")
Inspect_Runtime :: struct {ticks:u32 `mirai:"transient"`}
@(private="file")
Inspect_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    transforms:core.Table(core.Transform),
    config:core.Table(Inspect_Config),
    state:core.Table(Inspect_Runtime),
}
@(private="file") Inspect_Editor :: struct {api:Api}

@(private="file") Hidden_State :: struct {value:u32}
@(private="file") Lights_World :: struct {using world:core.Test_World,points:core.Table(erender.Point_Light),spots:core.Table(erender.Spot_Light)}
@(private="file") Lights_Editor :: struct {hidden:core.Table(Hidden_State)}

@(test)
a_name_of_a_component_or_a_key_resolves_as_it_is_written_or_says_the_nearest :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Lights_World,core.Test_None,Lights_Editor,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    tables:=info.tables
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
    info,described:=core.test_info(t,Inspect_World,core.Test_None,Inspect_Editor,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world,running:Inspect_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator) && core.world_init(&info,.World,&running,context.allocator)) {return}
    defer {core.world_destroy(&info,.World,&world);core.world_destroy(&info,.World,&running)}
    tables:=info.tables
    state:Api_State
    editor:=Inspect_Editor{api={state=&state}}
    document:Document
    edits:history.Edits
    session:=Session{info=&info,editor_world=&editor,edit_world=&world,document=&document,edits=&edits}
    api_schema_build(&session,&state)
    defer api_schema_free(&state)
    entity:=core.create(&world.entities)
    core.add(&world.ids,entity,core.Id{7})
    core.add(&world.transforms,entity,core.Transform{rotation=1,scale={1,1,1}})
    core.add(&world.config,entity,Inspect_Config{speed=2,compiled={8,9},diagnostics=13})
    core.add(&world.state,entity,Inspect_Runtime{ticks=21})
    core.settle(&info,&world,nil)
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
    config,_:=core.get(&world.config,entity)
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
    testing.expect(t,core.world_copy(&info,&running,&world))
    core.edit(&running.transforms,entity).position.x=8
    core.edit(&running.config,entity).diagnostics=99
    core.edit(&running.state,entity).ticks=42
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
    config,_=core.get(&world.config,entity)
    testing.expect_value(t,config.diagnostics,u32(13))
}

@(private="file")
Filter_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    cameras:core.Table(erender.Camera),
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
    info,described:=core.test_info(t,Filter_World,core.Test_None,Inspect_Editor,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world,running:Filter_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator) && core.world_init(&info,.World,&running,context.allocator)) {return}
    defer {core.world_destroy(&info,.World,&world);core.world_destroy(&info,.World,&running)}
    rig:=filter_entity(&world,1,"Rig")
    core.add(&world.cameras,filter_entity(&world,2,"Main Camera",rig),erender.CAMERA_DEFAULT)
    filter_entity(&world,3,"Crate 1");filter_entity(&world,4,"Crate 2");filter_entity(&world,5,"crate 3")
    core.settle(&info,&world,nil)
    for i in 0..<300 {filter_entity(&running,0,fmt.tprintf("Body %d",i))}
    core.settle(&info,&running,nil)
    selection:history.Selection;defer delete(selection.entities)
    viewport:Viewport;gui:Editor_Ui;edits:history.Edits;defer history.edits_free(&edits)
    document:Document
    editor:Inspect_Editor
    session:=Session{info=&info,edit_world=&world,editor_world=&editor,selection=&selection,viewport=&viewport,gui=&gui,edits=&edits,document=&document}
    history.edits_reset(&edits,edited_world(&session))
    api_opened,api_problem:=api_open(&session,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return};defer api_close(&session)
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
    using world:core.Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    drivables:core.Table(Inspect_Drivable),
}

// A prefab spawned while playing has no Ids: play.inspect names its parent
// and the entities its fields hold by handle, as it names the entity, and
// scene.inspect keeps the Ids of an edited world.
@(test)
play_inspection_names_the_references_of_spawned_entities_by_handle :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Spawned_World,core.Test_None,Inspect_Editor,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Spawned_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    state:Api_State
    editor:=Inspect_Editor{api={state=&state}}
    document:Document
    edits:history.Edits
    session:=Session{info=&info,editor_world=&editor,edit_world=&world,document=&document,edits=&edits}
    api_schema_build(&session,&state)
    defer api_schema_free(&state)
    root,camera:=core.create(&world.entities),core.create(&world.entities)
    core.add(&world.parents,camera,core.Parent{entity=root})
    core.add(&world.drivables,root,Inspect_Drivable{camera=camera})
    core.settle(&info,&world,nil)
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
    core.settle(&info,&world,nil)
    out.count=0
    api_entity_write(&session,w,&out,root,true,scratch,false)
    text=string(serial.writer_bytes(&out))
    testing.expectf(t,strings.contains(text,`"camera": "0x0000000000000006"`),"an edited world shows Ids: %s",text)
}
