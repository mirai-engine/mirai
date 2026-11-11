package editor

import "core:mem"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import mm "mirai:std/math"
import "mirai:std/serial"

@(private)
List_Lamp :: struct {
    tint:[3]f32 `mirai:"color"`,
    turn:mm.Quat,
    cone:f32 `mirai:"angle,min=0.1,max=1"`,
    age:f32 `mirai:"unit=s,readonly"`,
}
@(private)
@(test_world,editor="List_Editor")
List_World :: struct {
    using world:Test_World,
    lamps:core.Table(List_Lamp),
}
@(private) List_Editor :: struct {api:Api}

// component.list says what a field is in what it already reads: a color, a
// rotation, an angle in radians, read only when it is, and the comment of its
// line; no flags nor sizes. A read-only field is refused to the scene API.
@(test)
component_list_fields_say_their_kind_unit_and_description :: proc(t:^testing.T) {
    descriptions:=[1]core.Field_Description{{"cone","from its axis to the edge"}}
    info,described:=test_info(t,List_World)
    if !described {return}
    defer test_info_destroy(&info)
    info.tables[0].fields=descriptions[:]
    state:Api_State
    editor:=List_Editor{api={state=&state}}
    world:List_World
    if !testing.expect(t,core.world_init(&info,.World,&world,context.allocator)) {return}
    defer core.world_destroy(&info,.World,&world)
    session:=Session{info=&info,editor_world=&editor,edit_world=&world}
    api_schema_build(&session,&state)
    defer api_schema_free(&state)
    text:=api_fields_text(&state.schema,state.types[0])
    for part in ([]string{`{"path":"tint","type":"Color"}`,`{"path":"turn","type":"Quaternion"}`,`"unit":"rad","description":"from its axis to the edge"}`,`"unit":"s","read_only":true}`}) {
        testing.expectf(t,strings.contains(text,part),"%s in %s",part,text)
    }
    testing.expectf(t,!strings.contains(text,"flags") && !strings.contains(text,"size") && strings.count(text,"read_only")==1,"no flags, sizes nor read_only where it is false: %s",text)
    before:=List_Lamp{cone=0.5,age=3}
    after:=before
    after.cone=0.7
    testing.expect_value(t,read_only_written(&state.schema,state.types[0],mem.ptr_to_bytes(&before),mem.ptr_to_bytes(&after),""),"")
    after.age=4
    testing.expect_value(t,read_only_written(&state.schema,state.types[0],mem.ptr_to_bytes(&before),mem.ptr_to_bytes(&after),""),"age")
}

// The fields component.list gives of a type, as JSON without spaces.
api_fields_text :: proc(schema:^serial.Schema,type:serial.Type_Index,include_runtime:=false) -> string {
    fields:=make([dynamic]Api_Component_Field,context.temp_allocator)
    api_fields(schema,type,"",&fields,include_runtime)
    text,_:=serial.text_encode(struct{fields:[]Api_Component_Field}{fields[:]},.Line,context.temp_allocator,sparse=true)
    return api.json_compact(string(text))
}
