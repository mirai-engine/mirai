package serial

import "core:testing"
import "mirai:std/base"

@(test)
entity_reference_requirements_survive_schema_binary_and_clone :: proc(t:^testing.T) {
    Ref :: struct {camera:base.Entity `mirai:"requires=Camera"`}
    schema:Schema
    schema_init(&schema)
    defer schema_destroy(&schema)
    index,ok:=schema_add(&schema,Ref)
    testing.expect(t,ok)
    field:=schema_field(&schema,index,base.name_hash("camera"))
    testing.expect_value(t,field.required_component,base.name_hash("Camera"))
    writer:Writer
    writer_init(&writer,128)
    defer writer_destroy(&writer)
    schema_write(&writer,&schema)
    reader:=reader_init(writer_bytes(&writer))
    restored:Schema
    testing.expect_value(t,schema_read(&reader,&restored),Schema_Error.None)
    defer schema_destroy(&restored)
    testing.expect_value(t,schema_field(&restored,index,field.name_hash).required_component,field.required_component)
    cloned:Schema
    schema_clone(&cloned,&restored)
    defer schema_destroy(&cloned)
    testing.expect_value(t,schema_field(&cloned,index,field.name_hash).required_component,field.required_component)
}
