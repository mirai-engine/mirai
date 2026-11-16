package serial

import "core:strings"
import "core:testing"

@(test)
text_runtime_inspection_is_explicit_and_recurses_without_changing_saved_values :: proc(t:^testing.T) {
    Counters :: struct {ticks:u32 `mirai:"transient"`,total:u32,compiled:u32 `mirai:"hidden"`}
    Value :: struct {speed:f32,diagnostics:Counters `mirai:"hidden,transient"`,entries:[2]Counters}
    value:=Value{speed=2,diagnostics={7,11,19},entries={{3,5,23},{13,17,29}}}
    before:=value
    schema:Schema;schema_init(&schema);defer schema_destroy(&schema)
    type,ok:=schema_add(&schema,Value)
    if !testing.expect(t,ok) {return}
    out:Writer;writer_init(&out);defer writer_destroy(&out)
    bytes:=([^]u8)(&value)[:size_of(Value)]
    text_write(&out,&schema,type,bytes,.Line)
    saved:=string(writer_bytes(&out))
    testing.expect_value(t,saved,`{"speed": 2, "entries": [{"total": 5, "compiled": 23}, {"total": 17, "compiled": 29}]}`)
    out.count=0
    text_write(&out,&schema,type,bytes,.Line,omit_fields={})
    inspected:=string(writer_bytes(&out))
    testing.expect(t,strings.contains(inspected,`"diagnostics": {"ticks": 7, "total": 11, "compiled": 19}`))
    testing.expect(t,strings.contains(inspected,`"entries": [{"ticks": 3, "total": 5, "compiled": 23}, {"ticks": 13, "total": 17, "compiled": 29}]`))
    testing.expect_value(t,value,before)
    out.count=0
    text_write(&out,&schema,type,bytes,.Line,omit_fields={.Transient,.Hidden})
    testing.expect_value(t,string(writer_bytes(&out)),`{"speed": 2, "entries": [{"total": 5}, {"total": 17}]}`)
    out.count=0
    text_write(&out,&schema,type,bytes,.Line)
    testing.expect_value(t,string(writer_bytes(&out)),saved)
}
