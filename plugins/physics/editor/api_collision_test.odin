package physics_editor

import "mirai:editor"
import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import phys "plugins:physics/runtime"
import "mirai:std/serial"

@(test_world,editor="Collision_Test_Editor") @(private) Collision_Test_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    colliders:core.Table(phys.Collider),
    settings:phys.Collision_Settings,
}

@(private) Collision_Test_Editor :: struct {api:editor.Api}

// physics.collision.inspect lists the names the code declares, and they are
// what the schema of the world reads and writes a Collider and a Query_Filter
// with: what scene.write and scene.inspect go through.
@(test)
collision_is_read_and_written_by_the_names_the_code_declares :: proc(t:^testing.T) {
    info,described:=test_info(t,Collision_Test_World)
    if !described {return}
    defer test_info_destroy(&info)
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
    name_bits:=[1]core.Name_Bits_Info{{phys.Collision_Layers,phys.Collision_Category}}
    info.names,info.named_types,info.name_bits=names[:],named_types[:],name_bits[:]
    test_info_index(&info)
    selection:history.Selection;defer delete(selection.entities)
    viewport:editor.Viewport;gui:editor.Editor_Ui;edits:history.Edits;defer history.edits_free(&edits)
    tools:Collision_Test_Editor
    session:=editor.Session{info=&info,edit_world=&world,editor_world=&tools,selection=&selection,viewport=&viewport,gui=&gui,edits=&edits}
    history.edits_reset(&edits,editor.edited_world(&session))
    api_opened,api_problem:=editor.api_open(&session,0,true)
    if !testing.expectf(t,api_opened==.None,"%v: %s",api_opened,api_problem) {return};defer editor.api_close(&session)
    state:=editor.api_state(&session);state.poll_temp=context.temp_allocator
    if api.method_find(&state.server,"physics.collision.inspect")==nil {api_collision_register(&session)}
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    error,_:=api.method_execute(&state.server,api.method_find(&state.server,"physics.collision.inspect"),"{}",&out)
    testing.expect_value(t,error.code,0)
    text:=api.json_compact(string(serial.writer_bytes(&out)))
    testing.expectf(t,strings.contains(text,`"categories":["default","player","world","camera"]`),"%s",text)
    testing.expectf(t,strings.contains(text,`{"name":"default","sensor":false,"belongs":["default"],"collides":["*"]}`),"%s",text)
    testing.expectf(t,strings.contains(text,`{"name":"trigger","sensor":true,"belongs":["default"],"collides":["*"]}`),"%s",text)
    testing.expect(t,!strings.contains(text,`"custom"`))
    testing.expectf(t,strings.contains(text,`"undeclared":[{"field":"presets","index":4,"value":9}]`),"%s",text)
    testing.expect(t,api.method_find(&state.server,"physics.collision.set")==nil && api.method_find(&state.server,"physics.collision.get")==nil)

    schema:=&state.schema
    collider_type,_:=serial.schema_add_type_info(schema,type_info_of(phys.Collider))
    filter_type,_:=serial.schema_add_type_info(schema,type_info_of(phys.Query_Filter))
    collider:=phys.COLLIDER_DEFAULT
    r:serial.Text_Reader
    serial.text_reader_init(&r,`{"preset":"custom","sensor":true,"belongs":["player"],"collides":["world","camera"]}`,context.temp_allocator)
    testing.expect(t,serial.text_read(&r,schema,collider_type,mem.ptr_to_bytes(&collider)))
    testing.expect(t,collider.preset==phys.PRESET_CUSTOM && collider.sensor && collider.belongs==0b10 && collider.collides==0b1100 && collider.friction==phys.COLLIDER_DEFAULT.friction)
    serial.writer_reset(&out)
    serial.text_write(&out,schema,collider_type,mem.ptr_to_bytes(&collider),.Line)
    text=string(serial.writer_bytes(&out))
    testing.expectf(t,strings.contains(text,`"preset": "custom"`) && strings.contains(text,`"belongs": ["player"]`) && strings.contains(text,`"collides": ["world", "camera"]`),"%s",text)
    serial.text_reader_init(&r,`{"collides":["*"]}`,context.temp_allocator)
    testing.expect(t,serial.text_read(&r,schema,collider_type,mem.ptr_to_bytes(&collider)) && collider.collides==phys.COLLISION_LAYERS_ALL)
    serial.writer_reset(&out)
    serial.text_write(&out,schema,collider_type,mem.ptr_to_bytes(&collider),.Line)
    testing.expectf(t,strings.contains(string(serial.writer_bytes(&out)),`"collides": ["*"]`),"%s",string(serial.writer_bytes(&out)))
    filter:=phys.QUERY_FILTER_DEFAULT
    serial.text_reader_init(&r,`{"filter":{"block":["player","world"]}}`,context.temp_allocator)
    testing.expect(t,serial.text_read(&r,schema,filter_type,mem.ptr_to_bytes(&filter)) && filter.filter.block==6 && filter.filter.layers==phys.COLLISION_LAYERS_ALL)
    for wrong in ([]string{`{"belongs":["missing"]}`,`{"preset":"Trigger"}`,`{"collides":["world",99]}`}) {
        before:=collider
        serial.text_reader_init(&r,wrong,context.temp_allocator)
        testing.expectf(t,!serial.text_read(&r,schema,collider_type,mem.ptr_to_bytes(&collider)),"%s",wrong)
        collider=before
    }
}
