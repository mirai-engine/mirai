package api

import "core:strings"
import "core:fmt"
import "core:testing"
import "mirai:std/serial"

@(private="file")
Shape_Params :: struct {
    methods:[4][32]u8 `mirai:"text,optional"`,
    entity:[32]u8 `mirai:"text,optional"`,
    count:u8 `mirai:"optional"`,
    mode:Mode `mirai:"optional"`,
    position:[3]f32 `mirai:"optional"`,
    rows:[2]Inner `mirai:"optional"`,
}

@(private="file")
SHAPE_HAND :: `{"type":"object","properties":{"entity":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"kind":{"enum":["Alpha","Beta"]},"position":{"type":"array","items":{"type":"number"},"minItems":3,"maxItems":3},"parent":{"type":["string","null"]}}}`

@(private="file")
shape_echo :: proc(call:^Call) {raw(call.out,call.raw)}

@(test)
params_are_taken_in_the_singular_or_plural_and_as_a_value_or_a_list_of_one :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="typed",params=Shape_Params,handler=shape_echo}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="hand",params_schema=SHAPE_HAND,handler=shape_echo}),Register_Error.None)
    cases:=[]struct{method,params,shaped,problem:string}{
        {"typed",`{"method":"a"}`,`{"methods":["a"]}`,""},
        {"typed",`{"methods":"a"}`,`{"methods":["a"]}`,""},
        {"typed",`{"entity":["x"]}`,`{"entity":"x"}`,""},
        {"typed",`{"entities":["x"]}`,`{"entity":"x"}`,""},
        {"typed",`{"id":"x"}`,`{"entity":"x"}`,""},
        {"typed",`{"ids":["x"]}`,`{"entity":"x"}`,""},
        {"typed",`{"count":[3]}`,`{"count":3}`,""},
        {"typed",`{"rows":{"x":1}}`,`{"rows":[{"x":1}]}`,""},
        {"typed",`{"rows":[{"xs":1}]}`,`{"rows":[{"x":1}]}`,""},
        {"typed",`{"mode":"run"}`,`{"mode":"run"}`,""},
        {"typed",` { "ids" : [ "x" ] } `,` { "entity" : "x" } `,""},
        {"typed",`{"entity":["a","b"]}`,"","entity takes one value, not a list of several"},
        {"typed",`{"entities":["a","b"]}`,"","entity takes one value"},
        {"typed",`{"position":1}`,"","expected an array"},
        {"typed",`{"entity":"a","entities":["b"]}`,"",`"entities" is not a field`},
        {"hand",`{"path":"a"}`,`{"paths":["a"]}`,""},
        {"hand",`{"paths":"a"}`,`{"paths":["a"]}`,""},
        {"hand",`{"paths":["a","b"]}`,`{"paths":["a","b"]}`,""},
        {"hand",`{"entity":["x"],"kind":"beta"}`,`{"entity":"x","kind":"Beta"}`,""},
        {"hand",`{"parent":null,"position":[1,2,3]}`,`{"parent":null,"position":[1,2,3]}`,""},
        {"hand",`{"parent":["x"]}`,`{"parent":"x"}`,""},
        {"hand",`{"kind":"gama"}`,"",`kind "gama" is not one of its names; the nearest are Beta, Alpha`},
        {"hand",`{"entity":["a","b"]}`,"","entity takes one value"},
    }
    buffer:=make([]u8,4096,context.temp_allocator)
    for c in cases {
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer)
        err,ran:=method_execute(&s,method_find(&s,c.method),c.params,&w)
        if c.problem!="" {
            testing.expectf(t,!ran && strings.contains(err.message,c.problem),"%s: %s",c.params,err.message)
            continue
        }
        testing.expectf(t,ran,"%s: %s",c.params,err.message)
        testing.expect_value(t,string(serial.writer_bytes(&w)),c.shaped)
    }
}

@(private="file")
Clamp_Params :: struct {
    limit:int `mirai:"optional,min=1,max=10,clamp"`,
    rows:[2]struct {count:u16 `mirai:"optional,max=4,clamp"`} `mirai:"optional"`,
    times:int `mirai:"optional,max=3"`,
}
@(private="file")
Clamp_Result :: struct {limit:int}

@(private="file")
clamp_handler :: proc(call:^Call) {call_result(call,Clamp_Result).limit=call_params(call,Clamp_Params).limit}

@(test)
a_limit_past_its_maximum_takes_it_and_the_answer_says_so :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="clamp",params=Clamp_Params,result=Clamp_Result,handler=clamp_handler}),Register_Error.None)
    method:=method_find(&s,"clamp")
    cases:=[]struct{params,says,error:string}{
        {`{"limit":10}`,`"limit": 10}`,""},
        {`{"limit":99}`,`"_clamped":{"limit":{"asked":99,"used":10}}}`,""},
        {`{"limit":99,"rows":[{"count":9}]}`,`"rows[0].count":{"asked":9,"used":4}`,""},
        {`{"limit":0}`,"","limit must be at least 1"},
        {`{"limit":1,"times":4}`,"","times must be at most 3"},
    }
    buffer:=make([]u8,4096,context.temp_allocator)
    for c in cases {
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer)
        err,ran:=method_execute(&s,method,c.params,&w)
        testing.expectf(t,ran==(c.error=="") && strings.contains(err.message,c.error),"%s: %s",c.params,err.message)
        testing.expectf(t,strings.contains(string(serial.writer_bytes(&w)),c.says),"%s: %s",c.params,string(serial.writer_bytes(&w)))
        if c.params==`{"limit":10}` {testing.expect(t,!strings.contains(string(serial.writer_bytes(&w)),"_clamped"))}
    }
    w:serial.Writer
    serial.writer_init_fixed(&w,buffer)
    method_schema_write(&w,&s,method,true)
    testing.expect(t,strings.contains(string(serial.writer_bytes(&w)),`"_clamped":`),"the result of what can clamp declares it")
}

@(private="file")
usage_refuses :: proc(call:^Call) {call_fail(call,INVALID_PARAMS,"no such thing")}
@(private="file")
usage_refuses_with_data :: proc(call:^Call) {call_fail(call,INVALID_PARAMS,"no such thing",`{"own":1}`)}

@(test)
an_invalid_params_error_says_what_the_method_takes_and_only_it_does :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    testing.expect_value(t,method_register(&s,{name="small",params=Small,handler=noop}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="refuses",params=Small,handler=usage_refuses}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="own",params=Small,handler=usage_refuses_with_data}),Register_Error.None)
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,`{"type":"object","properties":{`)
    for i in 0..<512 {fmt.sbprintf(&b,`%s"field%d":{{"type":"integer","description":"a description long enough to fill the room there is"}}`,i>0?",":"",i)}
    strings.write_string(&b,`},"required":["field0"]}`)
    testing.expect_value(t,method_register(&s,{name="long",params_schema=strings.to_string(b),handler=noop}),Register_Error.None)
    testing.expect_value(t,method_register(&s,{name="no_schema",handler=usage_refuses}),Register_Error.None)
    buffer:=make([]u8,64*1024,context.temp_allocator)
    run :: proc(s:^Server,name,params:string,buffer:[]u8) -> (err:Error,ran:bool) {
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer)
        return method_execute(s,method_find(s,name),params,&w)
    }
    err,ran:=run(&s,"small",`{"count":1,"bogus":2}`,buffer)
    testing.expect(t,!ran)
    usage,is_text:=json_string(json_member(err.data,"usage"))
    testing.expect(t,is_text,"the data of the error has usage")
    testing.expectf(t,strings.contains(usage,"count: integer 1..9, required") && strings.contains(usage,`example: mirai rpc small '{"count":1}'`),"%s",usage)
    schema:=params_schema_text(&s,method_find(&s,"small"))
    described:=strings.builder_make(context.temp_allocator)
    describe_params(&described,schema)
    testing.expectf(t,strings.has_prefix(usage,strings.to_string(described)),"the text mirai rpc describe gives: %s",usage)
    err,ran=run(&s,"small",`{"count":1}`,buffer)
    testing.expect(t,ran && err.data=="")
    err,_=run(&s,"refuses",`{"count":1}`,buffer)
    testing.expect(t,strings.contains(err.data,"usage"),"a handler that refuses its params gets it too")
    err,_=run(&s,"own",`{"count":1}`,buffer)
    testing.expect_value(t,err.data,`{"own":1}`)
    err,_=run(&s,"no_schema",`{}`,buffer)
    testing.expect_value(t,err.data,"")
    err,_=run(&s,"long",`{"field0":"x"}`,buffer)
    err,_=run(&s,"long",`{"field0":[1,2]}`,buffer)
    usage,is_text=json_string(json_member(err.data,"usage"))
    testing.expect(t,is_text && len(usage)<=USAGE_BYTES && strings.contains(usage,"example: mirai rpc long"),"a long description keeps its example and fits")
    full:=s.out.count
    s.out.count=len(s.out.data)-USAGE_BYTES
    err,_=run(&s,"small",`{"bogus":2}`,buffer)
    s.out.count=full
    testing.expect_value(t,err.data,"")
}
