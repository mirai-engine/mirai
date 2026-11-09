package asset

import "base:runtime"
import "core:testing"
import "mirai:std/serial"

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private)
Type_Allocation_Failure :: struct {owner:runtime.Allocator,remaining:int}

@(private)
type_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Type_Allocation_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
asset_rows_retry_cold_types_after_each_metadata_allocation_fails :: proc(t:^testing.T) {
    Sample :: struct {value:f32,temporary:u32 `mirai:"transient"`}
    writer_types:Types;types_init(&writer_types);defer types_destroy(&writer_types)
    doc:Document;document_init(&doc,KIND_MATERIAL,{1,2});defer document_destroy(&doc)
    value:=Sample{7,81}
    _,put_error:=document_put_row(&doc,&writer_types,"sample",&value)
    if !testing.expect_value(t,put_error,Error.None) {return}
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    if !testing.expect_value(t,document_write(&doc,&bytes),Error.None) {return}
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    failure:=Type_Allocation_Failure{owner=context.allocator}
    allocator:=runtime.Allocator{type_failure_allocator,&failure}
    for failed_buffer in 0..<3 {
        types:Types;types_init(&types);defer types_destroy(&types)
        switch failed_buffer {
        case 0: types.hashes.allocator=allocator
        case 1: types.transient.allocator=allocator
        case 2: types.layouts.allocator=allocator
        }
        failure.remaining=0
        rows,error:=asset_rows(&file,&types,"sample","",Sample)
        testing.expect_value(t,error,Error.Out_Of_Memory)
        testing.expect(t,rows==nil)
        testing.expect_value(t,types.error,Error.Out_Of_Memory)
        _,known:=types.schema.lookup[typeid_of(Sample)]
        testing.expect(t,known)
        failure.remaining=128
        rows,error=asset_rows(&file,&types,"sample","",Sample)
        if !testing.expect_value(t,error,Error.None) {continue}
        testing.expect_value(t,len(rows),1)
        testing.expect_value(t,rows[0],Sample{7,0})
        testing.expect_value(t,len(types.hashes),len(types.schema.types))
        testing.expect_value(t,len(types.transient),len(types.schema.types))
        testing.expect_value(t,len(types.layouts),len(types.schema.types))
        testing.expect_value(t,types.error,Error.None)
    }
}

@(test)
asset_and_document_reads_propagate_migration_hash_allocation_failures :: proc(t:^testing.T) {
    Before :: struct {value:i32}
    After :: struct {value:f64}
    types:Types;types_init(&types);defer types_destroy(&types)
    doc:Document;document_init(&doc,KIND_MATERIAL,{1,2});defer document_destroy(&doc)
    value:=Before{42}
    table,put_error:=document_put_row(&doc,&types,"sample",&value)
    if !testing.expect_value(t,put_error,Error.None) {return}
    _,known:=document_type(&doc,&types,After)
    if !testing.expect(t,known) {return}
    bytes:serial.Writer;serial.writer_init(&bytes);defer serial.writer_destroy(&bytes)
    if !testing.expect_value(t,document_write(&doc,&bytes),Error.None) {return}
    file:Asset
    if !testing.expect_value(t,asset_open(&file,serial.writer_bytes(&bytes)),Error.None) {return}
    defer asset_close(&file)
    out:=make([dynamic]After);defer delete(out)
    failure:=Type_Allocation_Failure{owner=context.allocator}
    original_temp:=context.temp_allocator
    allocator:=runtime.Allocator{type_failure_allocator,&failure}
    for budget in 0..<3 {
        context.temp_allocator=allocator
        failure.remaining=budget
        rows,error:=asset_rows(&file,&types,"sample","",After)
        testing.expect_value(t,error,Error.Out_Of_Memory)
        testing.expect(t,rows==nil)
        failure.remaining=budget
        testing.expect_value(t,document_rows(&doc,&types,"sample",&out),Error.Out_Of_Memory)
        testing.expect_value(t,len(out),0)
        failure.remaining=budget
        testing.expect_value(t,document_column_convert(&doc,&types,table,0,After),Error.Out_Of_Memory)
        context.temp_allocator=original_temp
        unchanged:=make([dynamic]Before);defer delete(unchanged)
        testing.expect_value(t,document_rows(&doc,&types,"sample",&unchanged),Error.None)
        testing.expect_value(t,unchanged[0].value,i32(42))
    }
    rows,error:=asset_rows(&file,&types,"sample","",After)
    if testing.expect_value(t,error,Error.None) {testing.expect_value(t,rows[0].value,f64(42))}
    testing.expect_value(t,document_column_convert(&doc,&types,table,0,After),Error.None)
    testing.expect_value(t,document_rows(&doc,&types,"sample",&out),Error.None)
    testing.expect_value(t,out[0].value,f64(42))
}
