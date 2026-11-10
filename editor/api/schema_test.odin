package api

import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

Small :: struct {
    count:u8 `mirai:"min=1,max=9,label=Count"`,
    ratio:f32 `mirai:"optional,min=0,max=1,unit=m"`,
}

Mode :: enum u8 {Idle,Walk,Run}
Flag :: enum u8 {Fire,Ice,Wind}
Flags :: bit_set[Flag;u8]
Inner :: struct {x:u8,y:i16 `mirai:"optional"`}

Shapes :: struct {
    position:[3]f32 `mirai:"min=-10,max=10"`,
    mode:Mode `mirai:"optional"`,
    flags:Flags `mirai:"optional"`,
    name:[16]u8 `mirai:"text,optional"`,
    entity:base.Entity_Id `mirai:"optional"`,
    asset:base.Asset_Id `mirai:"optional"`,
    inner:Inner `mirai:"optional"`,
    wide:u64 `mirai:"optional"`,
    signed:i32 `mirai:"optional,min=-5,max=5"`,
    scratch:u8 `mirai:"transient"`,
}

noop :: proc(call:^Call) {}

test_server :: proc(t:^testing.T,desc:Server_Desc={}) -> (s:Server,ok:bool) {
    err:=server_init(&s,desc)
    testing.expect_value(t,err,Init_Error.None)
    return s,err==.None
}

schema_text :: proc(s:^Server,id:typeid,buffer:[]u8,image:[]u8=nil) -> string {
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    schema_write(&w,s,s.schema.lookup[id],nil,image)
    return string(serial.writer_bytes(&w))
}

@(test)
schema_of_a_struct_has_ranges_required_fields_and_defaults :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    defaults:=Small{ratio=0.5}
    testing.expect_value(t,method_register(&s,{name="small",params=Small,defaults=&defaults,handler=noop}),Register_Error.None)
    buffer:[1024]u8
    testing.expect_value(t,schema_text(&s,Small,buffer[:],s.methods[s.method_count-1].defaults),
        `{"type":"object","properties":{"count":{"type":"integer","minimum":1,"maximum":9,"description":"Count"},"ratio":{"type":"number","minimum":0,"maximum":1,"x-unit":"m","default":0.5}},"required":["count"],"additionalProperties":false}`)
}

Listed :: struct {
    scale:[3]f32 `mirai:"optional"`,
    rotation:[4]f32 `mirai:"optional"`,
    parts:[8]Inner `mirai:"optional"`,
}

@(test)
an_array_shows_the_default_of_its_elements_and_not_its_own :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    defaults:=Listed{scale={1,1,1},rotation={0,0,0,1}}
    for &part in defaults.parts {part={x=3,y=2}}
    testing.expect_value(t,method_register(&s,{name="listed",params=Listed,defaults=&defaults,handler=noop}),Register_Error.None)
    buffer:[1024]u8
    testing.expect_value(t,schema_text(&s,Listed,buffer[:],s.methods[s.method_count-1].defaults),
        `{"type":"object","properties":{"scale":{"type":"array","items":{"type":"number","default":1},"minItems":3,"maxItems":3},"rotation":{"type":"array","items":{"type":"number"},"minItems":4,"maxItems":4},"parts":{"type":"array","items":{"type":"object","properties":{"x":{"type":"integer","minimum":0,"maximum":255},"y":{"type":"integer","minimum":-32768,"maximum":32767,"default":2}},"required":["x"],"additionalProperties":false},"maxItems":8}},"additionalProperties":false}`)
}

Written :: struct {
    count:u8,
    names:[][16]u8 `mirai:"text"`,
    rows:[]Inner,
    value:serial.Json `mirai:"optional,label=Any JSON"`,
    filter:bool `mirai:"name=where"`,
}

written_handler :: proc(call:^Call) {
    raw(call.out,`{"count":2,"names":["a","b"],"rows":[{"x":1},{"x":2,"y":3}],"value":{"free":[1]},"where":true}`)
}

@(test)
a_result_the_handler_writes_is_described_by_its_type :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="bare",writes_result=true,handler=noop}),Register_Error.Invalid_Type)
    testing.expect_value(t,method_register(&s,{name="written",result=Written,writes_result=true,handler=written_handler}),Register_Error.None)
    method:=method_find(&s,"written")
    buffer:[1024]u8
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer[:])
    method_schema_write(&w,&s,method,true)
    text:=string(serial.writer_bytes(&w))
    for part in ([]string{
        `"names":{"type":"array","items":{"type":"string","maxLength":16}}`,
        `"rows":{"type":"array","items":{"type":"object","properties":{"x":`,
        `"value":{"description":"Any JSON"}`,
        `"where":{"type":"boolean"}`,
        `"required":["count","names","rows","where"]`,
    }) {testing.expectf(t,strings.contains(text,part),"missing %s in %s",part,text)}
    out_buffer:[256]u8
    out:serial.Writer
    serial.writer_init_fixed(&out,out_buffer[:])
    _,executed:=method_execute(&s,method,"{}",&out)
    testing.expect(t,executed)
    testing.expect_value(t,string(serial.writer_bytes(&out)),`{"count":2,"names":["a","b"],"rows":[{"x":1},{"x":2,"y":3}],"value":{"free":[1]},"where":true}`)
}

@(test)
schema_of_every_kind_of_field :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="shapes",params=Shapes,result=Shapes,handler=noop}),Register_Error.None)
    buffer:[4096]u8
    text:=schema_text(&s,Shapes,buffer[:])
    expected:=[]string{
        `"position":{"type":"array","items":{"type":"number","minimum":-10,"maximum":10},"minItems":3,"maxItems":3}`,
        `"mode":{"type":"string","enum":["Idle","Walk","Run"]}`,
        `"flags":{"type":"array","items":{"type":"string","enum":["Fire","Ice","Wind"]},"uniqueItems":true}`,
        `"name":{"type":"string","maxLength":16}`,
        `"entity":{"type":"string","pattern":"^(0x)?[0-9a-fA-F]{1,16}$"}`,
        `"asset":{"type":"string","x-asset":"any"}`,
        `"inner":{"type":"object","properties":{"x":{"type":"integer","minimum":0,"maximum":255},"y":{"type":"integer","minimum":-32768,"maximum":32767}},"required":["x"],"additionalProperties":false}`,
        `"wide":{"type":"integer","minimum":0,"maximum":18446744073709551615}`,
        `"signed":{"type":"integer","minimum":-5,"maximum":5}`,
        `"required":["position"]`,
    }
    for part in expected {testing.expectf(t,strings.contains(text,part),"missing %s in %s",part,text)}
    testing.expect(t,!strings.contains(text,"scratch"),"transient fields are not described")
}

@(test)
free_form_methods_describe_any_json :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="free",handler=noop}),Register_Error.None)
    buffer:[64]u8
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer[:])
    method_schema_write(&w,&s,method_find(&s,"free"),false)
    method_schema_write(&w,&s,method_find(&s,"free"),true)
    testing.expect_value(t,string(serial.writer_bytes(&w)),`{"type":"object"}{}`)
}

@(test)
registry_refuses_invalid_duplicate_and_excess_methods :: proc(t:^testing.T) {
    s,ok:=test_server(t,{max_methods=4});if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="",handler=noop}),Register_Error.Invalid_Name)
    testing.expect_value(t,method_register(&s,{name="has space",handler=noop}),Register_Error.Invalid_Name)
    testing.expect_value(t,method_register(&s,{name="1leading",handler=noop}),Register_Error.Invalid_Name)
    testing.expect_value(t,method_register(&s,{name=strings.repeat("a",MAX_NAME+1,context.temp_allocator),handler=noop}),Register_Error.Invalid_Name)
    testing.expect_value(t,method_register(&s,{name="a.b"}),Register_Error.Invalid_Handler)
    testing.expect_value(t,method_register(&s,{name="a.b",handler=noop}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="a.b",handler=noop}),Register_Error.Duplicate)
    testing.expect_value(t,method_register(&s,{name="a_b",handler=noop}),Register_Error.Duplicate)
    testing.expect_value(t,method_register(&s,{name="c",params=i32,handler=noop}),Register_Error.Invalid_Type)
    testing.expect_value(t,method_register(&s,{name="c",params=struct{p:^int},handler=noop}),Register_Error.Invalid_Type)
    testing.expect(t,s.schema.error!="","the schema says why a type is refused")
    testing.expect_value(t,method_register(&s,{name="c",result=string,handler=noop}),Register_Error.Invalid_Type)
    testing.expect_value(t,method_register(&s,{name="c",defaults=&s,handler=noop}),Register_Error.Invalid_Type)
    testing.expect_value(t,method_register(&s,{name="c",handler=noop}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="d",handler=noop}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="e",handler=noop}),Register_Error.Full)
    testing.expect_value(t,s.stats.methods_refused,1)
}

@(test)
registry_refuses_types_larger_than_the_scratch :: proc(t:^testing.T) {
    s,ok:=test_server(t,{scratch=1<<20});if !ok {return}
    defer server_destroy(&s)
    Huge :: struct {data:[1<<20]u8}
    testing.expect_value(t,method_register(&s,{name="huge",params=Huge,handler=noop}),Register_Error.Too_Large)
    testing.expect_value(t,method_register(&s,{name="huge",result=Huge,handler=noop}),Register_Error.Too_Large)
}

@(test)
pretty_printing_keeps_order_strings_and_empty_containers :: proc(t:^testing.T) {
    text:=`{"b": [1, 2, {"c": "a\"b,{"}], "a": {}, "e": [], "d": null}`
    expected:="{\n  \"b\": [\n    1,\n    2,\n    {\n      \"c\": \"a\\\"b,{\"\n    }\n  ],\n  \"a\": {},\n  \"e\": [],\n  \"d\": null\n}"
    testing.expect_value(t,json_pretty(text,context.temp_allocator),expected)
    testing.expect_value(t,json_single_line("{\n  \"a\": 1\n}",context.temp_allocator),`{  "a": 1}`)
    testing.expect_value(t,json_single_line(`{"a":1}`,context.temp_allocator),`{"a":1}`)
}

@(test)
a_value_of_another_schema_is_checked_like_the_params_of_a_method :: proc(t:^testing.T) {
    schema:serial.Schema
    serial.schema_init(&schema)
    defer serial.schema_destroy(&schema)
    type,added:=serial.schema_add(&schema,Shapes)
    testing.expect(t,added)
    value:=Shapes{position={1,2,3},mode=.Run,flags={.Ice},signed=-5}
    bytes:=(cast([^]u8)&value)[:size_of(Shapes)]
    message,ok:=value_check(&schema,type,bytes,"components.Shapes",context.temp_allocator)
    testing.expect(t,ok && message=="")
    value.position[1]=11
    message,ok=value_check(&schema,type,bytes,"components.Shapes",context.temp_allocator)
    testing.expect(t,!ok)
    testing.expect_value(t,message,"components.Shapes.position[1] must be at most 10")
    value.position[1]=0
    zero:=f32(0)
    value.position[2]=zero/zero
    message,ok=value_check(&schema,type,bytes,"",context.temp_allocator)
    testing.expect(t,!ok)
    testing.expect_value(t,message,"position[2] must be finite")
    value.position[2]=0
    value.mode=Mode(9)
    message,ok=value_check(&schema,type,bytes,"x",context.temp_allocator)
    testing.expect_value(t,message,"x.mode is not a member of its enum")
    value.mode=.Idle
    value.flags=transmute(Flags)u8(0x80)
    message,ok=value_check(&schema,type,bytes,"x",context.temp_allocator)
    testing.expect_value(t,message,"x.flags has bits that are not members of its set")
}

@(test)
a_free_form_method_is_described_by_the_schema_written_for_it :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    PARAMS :: `{"type":"object","properties":{"open":{"type":"object"}}}`
    testing.expect_value(t,method_register(&s,{name="open",params_schema=PARAMS,result_schema=`{"type":"array"}`,handler=noop}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="broken",params_schema=`{"type":`,handler=noop}),Register_Error.Invalid_Schema)
    testing.expect_value(t,method_register(&s,{name="typed",params=Small,params_schema=PARAMS,handler=noop}),Register_Error.Invalid_Schema)
    buffer:[1024]u8
    for result in ([2]bool{false,true}) {
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer[:])
        method_schema_write(&w,&s,&s.methods[s.method_count-1],result)
        testing.expect_value(t,string(serial.writer_bytes(&w)),result?`{"type":"array"}`:`{"type":"object","properties":{`+SELECT_SCHEMA+`,"open":{"type":"object"}}}`)
    }
    testing.expect_value(t,method_register(&s,{name="bare",handler=noop}),Register_Error.None)
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer[:])
    method_schema_write(&w,&s,&s.methods[s.method_count-1],false)
    testing.expect_value(t,string(serial.writer_bytes(&w)),`{"type":"object"}`)
}

@(test)
the_description_of_the_methods_has_the_shape_it_declares :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="shapes",params=Shapes,result=Shapes,handler=noop,flags={.Read_Only,.Idempotent}}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="grow",plugin="foliage",handler=noop}),Register_Error.None)
    server_plugins_set(&s,{{"foliage",true},{"terrain",false}})
    buffer:=make([]u8,64*1024,context.temp_allocator)
    for params in ([]string{`{}`,`{"plugin":"foliage"}`,`{"plugin":"editor","prefix":"sh"}`,`{"methods":["shapes","grow"]}`}) {
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer)
        _,ran:=method_execute(&s,method_find(&s,"engine.describe"),params,&w)
        testing.expect(t,ran)
        testing.expect_value(t,result_mismatch(Describe_Result,string(serial.writer_bytes(&w))),"")
    }
}
