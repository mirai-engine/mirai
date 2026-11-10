package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:cook/author"
import "mirai:editor/api"
import "mirai:std/serial"

@(test)
every_result_of_the_ui_methods_registers_with_its_schema :: proc(t:^testing.T) {
    s:api.Server
    if !testing.expect_value(t,api.server_init(&s,{}),api.Init_Error.None) {return}
    defer api.server_destroy(&s)
    Result :: struct {result:typeid,info:^runtime.Type_Info,writes:bool,part:string}
    results:=[?]Result{
        {Tree_Inspect,type_info_of(Tree_Inspect),true,`"required":["name"]`},
        {Ui_Ok,type_info_of(Ui_Ok),false,`"required":["ok"]`},
        {Tree_Write_Answer,type_info_of(Tree_Write_Answer),false,`"required":["ok","made","removed"]`},
        {Ui_Paths_Result,type_info_of(Ui_Paths_Result),true,`"required":["name","path","fits","navigable"]`},
        {Ui_Check_Result,type_info_of(Ui_Check_Result),true,`"required":["asset","node","binding","path","loads","message"]`},
        {Ui_Rename_Result,type_info_of(Ui_Rename_Result),true,`"files":{"type":"array","items":{"type":"string","maxLength":1024}`},
    }
    buffer:=make([]u8,1<<16,context.temp_allocator)
    for r,i in results {
        name:=fmt.tprintf("ui.m%d",i)
        handler :: proc(call:^api.Call) {}
        testing.expect_value(t,api.method_register(&s,{name=name,result=r.result,result_info=r.info,writes_result=r.writes,handler=handler}),api.Register_Error.None)
        method:=api.method_find(&s,name)
        if method==nil {continue}
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer)
        api.method_schema_write(&w,&s,method,true)
        text:=string(serial.writer_bytes(&w))
        testing.expectf(t,strings.contains(text,r.part),"%v lacks %s in %s",r.result,r.part,text)
    }
}

// The node of the document ui.inspect describes, and ui.write's schema, name
// the keys the reader of the document takes, and only those.
@(test)
the_node_the_ui_methods_describe_is_the_one_the_reader_takes :: proc(t:^testing.T) {
    keys:=author.DOCUMENT_NODE_KEYS
    fields:=runtime.type_info_base(type_info_of(Tree_Document_Node)).variant.(runtime.Type_Info_Struct)
    testing.expect_value(t,int(fields.field_count),len(keys))
    for name in fields.names[:fields.field_count] {testing.expectf(t,slice.contains(keys[:],name),"the described node has %s, which the reader refuses",name)}
    words:=strings.fields_proc(TREE_WRITE_SCHEMA,proc(r:rune) -> bool {return !(r>='a' && r<='z' || r=='_')},context.temp_allocator)
    for key in keys {testing.expectf(t,slice.contains(words,key),"the schema of ui.write does not name the key %s of a node",key)}
}
