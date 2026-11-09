package api

import "core:strings"
import "core:fmt"
import "core:testing"
import "mirai:std/base"
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
        {"hand",`{"kind":"gama"}`,"",`kind "gama" is not one of its names`},
        {"hand",`{"entity":["a","b"]}`,"","entity takes one value"},
        {"typed",`{"entity":123}`,`{"entity":"123"}`,""},
        {"typed",`{"entity":true}`,`{"entity":"true"}`,""},
        {"typed",`{"methods":[1,"a"]}`,`{"methods":["1","a"]}`,""},
        {"hand",`{"entity":-1.5}`,`{"entity":"-1.5"}`,""},
        {"hand",`{"parent":5}`,`{"parent":5}`,""},
        {"hand",`{"kind":1}`,`{"kind":1}`,""},
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
Named_Params :: struct {
    entity:base.Entity_Id,
    parent:base.Entity_Id `mirai:"optional"`,
    list:[3]base.Entity_Id `mirai:"optional"`,
}

@(private="file")
named_resolve :: proc(user:rawptr,text:string) -> (id:base.Entity_Id,problem:string) {
    switch text {
    case "Floor": return 7,""
    case "123":   return 8,""
    case "0000000000000009": return 9,""
    }
    return 0,fmt.tprintf("%q names no entity",text)
}

@(private="file")
named_echo :: proc(call:^Call) {
    p:=call_params(call,Named_Params)
    raw(call.out,fmt.tprintf("%d %d %d",p.entity,p.parent,p.list[1]))
}

@(test)
a_param_of_an_entity_id_takes_what_the_resolver_of_the_server_takes :: proc(t:^testing.T) {
    s,ok:=test_server(t);if !ok {return}
    defer server_destroy(&s)
    s.entities={nil,named_resolve}
    testing.expect_value(t,method_register(&s,{name="named",params=Named_Params,handler=named_echo}),Register_Error.None)
    cases:=[]struct{params,echo,error:string}{
        {`{"entity":"Floor"}`,"7 0 0",""},
        {`{"entity":123}`,"8 0 0",""},
        {`{"entity":"0000000000000009","parent":"Floor","list":["Floor","123"]}`,"9 7 8",""},
        {`{"id":"Floor"}`,"7 0 0",""},
        {`{"entity":"Nope"}`,"",`entity: "Nope" names no entity`},
        {`{"entity":"Floor","list":["Floor","Nope"]}`,"",`list[1]: "Nope" names no entity`},
    }
    buffer:=make([]u8,4096,context.temp_allocator)
    for c in cases {
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer)
        err,ran:=method_execute(&s,method_find(&s,"named"),c.params,&w)
        if c.error!="" {
            testing.expectf(t,!ran && err.message==c.error,"%s: %s",c.params,err.message)
            continue
        }
        testing.expectf(t,ran,"%s: %s",c.params,err.message)
        testing.expect_value(t,string(serial.writer_bytes(&w)),c.echo)
    }
    schema:=params_schema_text(&s,method_find(&s,"named"))
    testing.expectf(t,strings.contains(schema,`"x-entity":`) && !strings.contains(schema,"pattern"),"the schema of a param says how it names: %s",schema)
    described:=strings.builder_make(context.temp_allocator)
    describe_params(&described,schema)
    describe_example(&described,"named",schema)
    testing.expectf(t,strings.contains(strings.to_string(described),"entity: entity name, path or id, required") && strings.contains(strings.to_string(described),"example: mirai rpc named entity=Floor\n"),"%s",strings.to_string(described))
}

@(test)
an_example_is_written_with_key_value_unless_it_needs_json :: proc(t:^testing.T) {
    SCHEMA :: `{{"type":"object","properties":{{%s}},"required":[%s]}}`
    cases:=[]struct{properties,required,example:string}{
        {`"count":{"type":"integer","minimum":2},"on":{"type":"boolean"},"name":{"type":"string"},"at":{"type":"array","items":{"type":"number"},"minItems":3}`,`"count","on","name","at"`,"example: mirai rpc m count=2 on=false name=x at=[0,0,0]"},
        {`"to":{"type":"object","properties":{"a":{"type":"integer","minimum":1},"b":{"enum":["Up","Down"]}},"required":["a","b"]}`,`"to"`,"example: mirai rpc m to.a=1 to.b=Up"},
        {`"tags":{"type":"array","items":{"type":"string"},"minItems":1}`,`"tags"`,`example: mirai rpc m '{"tags":["x"]}'`},
        {`"text":{"type":"string","default":"two words"}`,`"text"`,`example: mirai rpc m '{"text":"two words"}'`},
        {`"text":{"type":"string"}`,"",`example: mirai rpc m`},
    }
    for c in cases {
        b:=strings.builder_make(context.temp_allocator)
        describe_example(&b,"m",fmt.tprintf(SCHEMA,c.properties,c.required))
        testing.expectf(t,strings.has_suffix(strings.trim_space(strings.to_string(b)),c.example),"%s",strings.to_string(b))
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
    testing.expectf(t,strings.contains(usage,"count: integer 1..9, required\n") && strings.contains(usage,"example: mirai rpc small count=1\n"),"%s",usage)
    testing.expectf(t,!strings.contains(usage,"Count") && !strings.contains(usage,"unit"),"the labels stay out: %s",usage)
    failures:=[]struct{method,params,data:string}{
        {"small",`{"count":"x"}`,"usage"},
        {"small",`{"ratio":1}`,"usage"},
        {"small",`{"count":99}`,""},
        {"refuses",`{"count":1}`,""},
        {"own",`{"count":1}`,"own"},
        {"named",`{"entity":"Nope"}`,""},
        {"named",`{"entity":"Floor","bogus":1}`,"usage"},
    }
    testing.expect_value(t,method_register(&s,{name="named",params=Named_Params,handler=noop}),Register_Error.None)
    s.entities={nil,named_resolve}
    for c in failures {
        err,ran=run(&s,c.method,c.params,buffer)
        testing.expectf(t,!ran && (c.data=="" && err.data=="" || c.data!="" && strings.contains(err.data,c.data)),"%s %s: %s",c.method,c.params,err.data)
    }
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
