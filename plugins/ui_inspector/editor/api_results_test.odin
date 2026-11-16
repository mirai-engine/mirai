package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:reflect"
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
    Result :: struct {info:^runtime.Type_Info,part:string}
    results:=[?]Result{
        {type_info_of(Tree_Inspect),`"required":["document"]`},
        {type_info_of(Ui_Ok),`"required":["ok"]`},
        {type_info_of(Tree_Write_Answer),`"required":["ok","made","removed"]`},
        {type_info_of(Ui_Paths_Result),`"required":["name","path","fits","navigable"]`},
        {type_info_of(Ui_Check_Result),`"required":["asset","node","binding","path","loads","message"]`},
        {type_info_of(Ui_Rename_Result),`"files":{"type":"array","items":{"type":"string"}`},
    }
    buffer:=make([]u8,1<<16,context.temp_allocator)
    for r,i in results {
        name:=fmt.tprintf("ui.m%d",i)
        handler :: proc(call:^api.Call) {}
        testing.expect_value(t,api.method_register(&s,{name=name,result=r.info,handler=handler}),api.Register_Error.None)
        method:=api.method_find(&s,name)
        if method==nil {continue}
        w:serial.Writer
        serial.writer_init_fixed(&w,buffer)
        api.method_schema_write(&w,&s,method,true)
        text:=string(serial.writer_bytes(&w))
        testing.expectf(t,strings.contains(text,r.part),"%v lacks %s in %s",r.info.id,r.part,text)
    }
}

// What ui.write says of its document names every key the reader of the
// document takes of a node.
@(test)
the_document_ui_write_describes_names_the_keys_the_reader_takes :: proc(t:^testing.T) {
    keys:=author.DOCUMENT_NODE_KEYS
    field:=reflect.struct_field_by_name(Ui_Write_Params,"document")
    words:=strings.fields_proc(string(field.tag),proc(r:rune) -> bool {return !(r>='a' && r<='z' || r=='_')},context.temp_allocator)
    for key in keys {testing.expectf(t,slice.contains(words,key),"ui.write does not name the key %s of a node",key)}
}
