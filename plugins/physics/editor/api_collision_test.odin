package physics_editor

import "mirai:editor"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import phys "plugins:physics/runtime"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") Collision_Test_Filter :: struct {filter:phys.Query_Filter,unchanged:u32}
@(private="file") Collision_Test_Nested :: struct {region:Collision_Test_Filter}
@(private="file") Collision_Test_Wrong :: struct {layers,mask:u32}
@(private="file") Collision_Test_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    colliders:core.Table(phys.Collider),
    filters:core.Table(Collision_Test_Filter),
    nested:core.Table(Collision_Test_Nested),
    wrong:core.Table(Collision_Test_Wrong),
    settings:phys.Collision_Settings,
}

@(private="file") Collision_Test_Editor :: struct {api:editor.Api}

@(test)
collision_api_reads_and_edits_presets_masks_and_queries_by_name_in_one_undo_step :: proc(t:^testing.T) {
    info,described:=core.test_info(t,Collision_Test_World,core.Test_None,Collision_Test_Editor,test_types)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Collision_Test_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    world.settings.presets[4]={preset=9,belongs=1,collides=2}
    names:=[7]core.Name_Info{
        {type=phys.Collision_Category,value=0,name="default"},{type=phys.Collision_Category,value=1,name="player"},
        {type=phys.Collision_Category,value=2,name="world"},{type=phys.Collision_Category,value=3,name="camera"},
        {type=phys.Collision_Preset,value=0,name="default"},{type=phys.Collision_Preset,value=1,name="trigger"},
        {type=phys.Collision_Preset,value=255,name="custom"},
    }
    named_types:=[2]core.Named_Type_Info{{type=phys.Collision_Category,name="Collision_Category",prefix="CATEGORY_",limit=32},{type=phys.Collision_Preset,name="Collision_Preset",prefix="PRESET_",limit=256}}
    info.names,info.named_types=names[:],named_types[:]
    core.test_info_index(&info)
    entity,held:=core.create(&world.entities),core.create(&world.entities)
    alone:=core.create(&world.entities)
    collider:=phys.COLLIDER_DEFAULT;collider.group=held;collider.friction=.8
    config:=Collision_Test_Filter{filter=phys.QUERY_FILTER_DEFAULT,unchanged=93};config.filter.debris=true
    core.add(&world.ids,entity,{value=7});core.add(&world.ids,held,{value=9});core.add(&world.ids,alone,{value=11});core.add(&world.colliders,entity,collider);core.add(&world.colliders,alone,phys.COLLIDER_DEFAULT)
    core.add(&world.filters,entity,config);core.add(&world.nested,entity,{region=config});core.add(&world.wrong,entity,{1,2})
    core.settle(&info,&world,nil)
    selection:history.Selection;defer delete(selection.entities)
    viewport:editor.Viewport;gui:editor.Editor_Ui;edits:history.Edits;defer history.edits_free(&edits)
    tools:Collision_Test_Editor
    session:=editor.Session{info=&info,edit_world=&world,editor_world=&tools,selection=&selection,viewport=&viewport,gui=&gui,edits=&edits}
    history.edits_reset(&edits,editor.edited_world(&session))
    if !testing.expect_value(t,editor.api_open(&session,0,true),editor.Api_Open_Error.None) {return};defer editor.api_close(&session)
    state:=editor.api_state(&session);state.poll_temp=context.temp_allocator
    if api.method_find(&state.server,"physics.collision.get")==nil {api_collision_register(&session)}
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    execute :: proc(state:^editor.Api_State,out:^serial.Writer,name,params:string) -> api.Error {
        base.arena_reset(&state.server.scratch);serial.writer_reset(out)
        method:=api.method_find(&state.server,name)
        error,_:=api.method_execute(&state.server,method,params,out)
        return error
    }
    error:=execute(state,&out,"physics.collision.inspect","{}")
    testing.expect_value(t,error.code,0)
    text:=api.json_compact(string(serial.writer_bytes(&out)))
    testing.expectf(t,strings.contains(text,`"categories":["default","player","world","camera"]`),"%s",text)
    testing.expectf(t,strings.contains(text,`{"name":"default","sensor":false,"belongs":["default"],"collides":["*"]}`),"%s",text)
    testing.expectf(t,strings.contains(text,`{"name":"trigger","sensor":true,"belongs":["default"],"collides":["*"]}`),"%s",text)
    testing.expect(t,!strings.contains(text,`"custom"`))
    testing.expectf(t,strings.contains(text,`"undeclared":[{"field":"presets","index":4,"value":9}]`),"%s",text)
    error=execute(state,&out,"physics.collision.get",`{"entity":"0000000000000007","component":"Collider"}`)
    testing.expect_value(t,error.code,0)
    text=api.json_compact(string(serial.writer_bytes(&out)))
    testing.expectf(t,strings.contains(text,`"preset":"default","belongs":["default"],"collides":["*"],"pushes":{},"group":"0x0000000000000009"`),"%s",text)
    // Without component: the only one of the entity, or an error that lists them.
    error=execute(state,&out,"physics.collision.get",`{"entity":"000000000000000b"}`)
    testing.expect_value(t,error.code,0)
    text=api.json_compact(string(serial.writer_bytes(&out)));testing.expectf(t,strings.contains(text,`"component":"Collider"`),"%s",text)
    error=execute(state,&out,"physics.collision.get",`{"entity":"0000000000000007"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expectf(t,strings.contains(error.message,"Collider, Collision_Test_Filter"),"%s",error.message)
    error=execute(state,&out,"physics.collision.get",`{"entity":"0000000000000009"}`)
    testing.expect_value(t,error.code,api.INVALID_PARAMS)
    testing.expectf(t,strings.contains(error.message,"no collision component"),"%s",error.message)
    error=execute(state,&out,"physics.collision.set",`{"entity":"0000000000000007","component":"Collider","belongs":["player"],"collides":["world","camera"]}`)
    if !testing.expect_value(t,error.code,0) {return}
    value,_:=core.get(core.read(&world.colliders),entity)
    testing.expect(t,value.preset==phys.PRESET_CUSTOM && value.belongs==0b10 && value.collides==0b1100 && !value.sensor)
    testing.expect(t,value.group==held && value.friction==collider.friction)
    testing.expect_value(t,edits.cursor,1)
    error=execute(state,&out,"physics.collision.set",`{"entity":"0000000000000007","component":"Collider","sensor":true}`)
    testing.expect_value(t,error.code,0)
    value,_=core.get(core.read(&world.colliders),entity)
    testing.expect(t,value.sensor && value.belongs==0b10 && value.collides==0b1100)
    error=execute(state,&out,"physics.collision.set",`{"entity":"0000000000000007","component":"Collider","preset":"trigger"}`)
    testing.expect_value(t,error.code,0)
    value,_=core.get(core.read(&world.colliders),entity)
    testing.expect(t,value.preset==phys.PRESET_TRIGGER && value.group==held)
    // Custom chosen as a preset keeps what the preset gave as its own.
    error=execute(state,&out,"physics.collision.set",`{"entity":"0000000000000007","component":"Collider","preset":"custom"}`)
    testing.expect_value(t,error.code,0)
    value,_=core.get(core.read(&world.colliders),entity)
    testing.expect(t,value.preset==phys.PRESET_CUSTOM && value.sensor && value.belongs==1 && value.collides==phys.COLLISION_LAYERS_ALL)
    // The steps are of the API: it undoes them, as history.undo does.
    edits.author=history.EDIT_AUTHOR_API
    for _ in 0..<4 {testing.expect(t,history.undo(&edits,editor.edited_world(&session),&selection))}
    value,_=core.get(core.read(&world.colliders),entity);testing.expect_value(t,value,collider)
    testing.expect(t,history.redo(&edits,editor.edited_world(&session),&selection))
    edits.author=history.EDIT_AUTHOR_USER
    before:=history.edits_scene_state(&edits);cursor:=edits.cursor
    for params in ([]string{
        `{"entity":"0000000000000007","component":"Collider","preset":"Trigger"}`,
        `{"entity":"0000000000000007","component":"Collider","belongs":["missing"]}`,
        `{"entity":"0000000000000007","component":"Collider","collides":["world","missing"]}`,
        `{"entity":"0000000000000007","component":"Collider","sensor":"yes"}`,
        `{"entity":"0000000000000007","component":"Collider","preset":"trigger","belongs":["world"]}`,
        `{"entity":"0000000000000007","component":"Collider","hits":["camera"]}`,
        `{"entity":"0000000000000007","component":"Collider"}`,
        `{"entity":"0000000000000007","component":"Collision_Test_Wrong","preset":"trigger"}`,
        `{"entity":"0000000000000007","component":"Collision_Test_Filter","hits":["missing"]}`,
        `{"entity":"0000000000000007","component":"Collision_Test_Filter","preset":"trigger"}`,
    }) {
        error=execute(state,&out,"physics.collision.set",params)
        testing.expect_value(t,error.code,api.INVALID_PARAMS)
        testing.expect_value(t,history.edits_scene_state(&edits),before);testing.expect_value(t,edits.cursor,cursor)
    }
    error=execute(state,&out,"physics.collision.set",`{"entity":"0000000000000007","component":"Collision_Test_Filter","hits":["player","world"]}`)
    testing.expect_value(t,error.code,0)
    filtered,_:=core.get(core.read(&world.filters),entity)
    testing.expect(t,filtered.filter.filter.block==6 && filtered.filter.filter.layers==phys.COLLISION_LAYERS_ALL && filtered.filter.objects==0)
    testing.expect(t,filtered.filter.debris && filtered.unchanged==93)
    error=execute(state,&out,"physics.collision.get",`{"entity":"0000000000000007","component":"Collision_Test_Filter"}`)
    testing.expect_value(t,error.code,0)
    text=api.json_compact(string(serial.writer_bytes(&out)));testing.expectf(t,strings.contains(text,`"prefix":"filter","hits":["player","world"]}`),"%s",text)
    error=execute(state,&out,"physics.collision.set",`{"entity":"0000000000000007","component":"Collision_Test_Nested","prefix":"region.filter","hits":["camera"],"sensors":true}`)
    testing.expect_value(t,error.code,0)
    nested,_:=core.get(core.read(&world.nested),entity)
    testing.expect(t,nested.region.filter.filter.block==8 && nested.region.filter.overlaps && nested.region.filter.objects==0)
    testing.expect(t,nested.region.filter.debris && nested.region.unchanged==93)
    error=execute(state,&out,"physics.collision.get",`{"entity":"0000000000000007","component":"Collision_Test_Nested","prefix":"region.filter"}`)
    testing.expect_value(t,error.code,0)
    text=api.json_compact(string(serial.writer_bytes(&out)));testing.expectf(t,strings.contains(text,`"hits":["camera"],"sensors":true`),"%s",text)
    error=execute(state,&out,"physics.collision.set",`{"entity":"000000000000000b","sensor":true}`)
    testing.expect_value(t,error.code,0)
    testing.expect(t,core.get(&world.colliders,alone).sensor)
    session.mode=.Play;session.runs[0]={world=&world}
    error=execute(state,&out,"physics.collision.get",`{"entity":"0000000000000007","component":"Collider"}`)
    testing.expect_value(t,error.code,0)
    text=api.json_compact(string(serial.writer_bytes(&out)));testing.expect(t,strings.contains(text,`"playing":true`))
    world.settings.presets[3]={preset=phys.PRESET_CUSTOM,belongs=1}
    error=execute(state,&out,"physics.collision.set",`{"entity":"0000000000000007","component":"Collider","preset":"trigger"}`)
    testing.expect_value(t,error.code,api.SERVER_ERROR)
}
