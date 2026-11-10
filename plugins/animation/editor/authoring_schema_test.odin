package animation_editor

import "base:runtime"
import "core:strings"
import "mirai:editor/api"
import "mirai:std/serial"

// The JSON Schema the API describes T with.
authoring_result_schema :: proc($T:typeid, info:^runtime.Type_Info, allocator:=context.allocator) -> string {
    context.allocator=allocator
    server:api.Server
    server.allocator=allocator
    serial.schema_init(&server.schema,allocator)
    server.schema.unsized=true
    defer serial.schema_destroy(&server.schema)
    index,ok:=api.schema_register(&server,T,info)
    if !ok {return ""}
    writer:serial.Writer
    serial.writer_init(&writer,4096,allocator)
    defer serial.writer_destroy(&writer)
    api.schema_write(&writer,&server,index)
    if writer.overflow!=0 {return ""}
    return strings.clone(string(serial.writer_bytes(&writer)),allocator)
}
