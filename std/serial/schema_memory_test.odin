package serial

import "base:runtime"
import "core:testing"
import "core:mem"

@(private="file")
Schema_Allocation_Failure :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
schema_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Schema_Allocation_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// A schema read or cloned with the memory ending at each request in turn:
// Out_Of_Memory, nothing of it kept, and with memory enough the schema whole.
@(test)
schema_read_and_clone_release_every_partial_allocation_and_hashes_retry_without_memory :: proc(t:^testing.T) {
    Kind :: enum u8 {First,Second}
    Sample :: struct {kind:Kind,values:[3]f32 `mirai:"label=Values,unit=m"`}
    original:Schema;schema_init(&original);defer schema_destroy(&original)
    if _,ok:=schema_add(&original,Sample);!testing.expect(t,ok) {return}
    bytes:Writer;writer_init(&bytes);defer writer_destroy(&bytes)
    schema_write(&bytes,&original)
    failure:=Schema_Allocation_Failure{owner=context.allocator}
    allocator:=runtime.Allocator{schema_failure_allocator,&failure}
    Call :: enum {Read,Clone}
    for call in Call {
        succeeded,refused:=false,false
        for budget in 0..<128 {
            failure.remaining=budget
            loaded:Schema
            error:Schema_Error
            switch call {
            case .Read:
                reader:=reader_init(writer_bytes(&bytes))
                error=schema_read(&reader,&loaded,allocator)
            case .Clone:
                error=schema_clone(&loaded,&original,allocator)
            }
            if error!=.None {
                refused=true
                testing.expectf(t,error==.Out_Of_Memory,"%v with %d requests served: %v",call,budget,error)
                testing.expectf(t,loaded.types==nil && loaded.fields==nil && loaded.choices==nil,"%v with %d requests served kept a part",call,budget)
                continue
            }
            succeeded=true
            testing.expectf(t,len(loaded.types)==len(original.types) && len(loaded.fields)==len(original.fields) && len(loaded.choices)==len(original.choices),"%v: the schema whole",call)
            for field,i in loaded.fields {testing.expect(t,field.name==original.fields[i].name && field.label==original.fields[i].label && field.unit==original.fields[i].unit)}
            failure.remaining=0
            testing.expect_value(t,schema_validate(&loaded),Schema_Error.Out_Of_Memory)
            hashes:=make([dynamic]u64,allocator)
            testing.expect(t,!schema_hashes_update(&loaded,&hashes))
            testing.expect_value(t,len(hashes),0)
            failure.remaining=128
            testing.expect(t,schema_hashes_update(&loaded,&hashes))
            testing.expect_value(t,len(hashes),len(loaded.types))
            delete(hashes);schema_destroy(&loaded)
            break
        }
        testing.expectf(t,succeeded && refused,"%v: refused without memory, and with it it goes through",call)
    }
}

@(test)
schema_import_retries_after_source_destination_and_remap_allocation_failures :: proc(t:^testing.T) {
    Sample :: struct {value:f32}
    source:Schema;schema_init(&source);defer schema_destroy(&source)
    root,valid:=schema_add(&source,Sample)
    if !testing.expect(t,valid) {return}
    failure:=Schema_Allocation_Failure{owner=context.allocator}
    allocator:=runtime.Allocator{schema_failure_allocator,&failure}
    for failed_buffer in 0..<3 {
        destination:Schema;schema_init(&destination);defer schema_destroy(&destination)
        hashes:=make([dynamic]u64);defer delete(hashes)
        link:Schema_Import;schema_import_init(&link,&destination,&hashes,&source);defer schema_import_destroy(&link)
        switch failed_buffer {
        case 0: link.src_hashes.allocator=allocator
        case 1: hashes.allocator=allocator
        case 2: link.remap.allocator=allocator
        }
        failure.remaining=0
        testing.expect_value(t,schema_import(&link,root),TYPE_NONE)
        testing.expect(t,len(link.remap)==0 || link.remap[root]==TYPE_NONE)
        failure.remaining=128
        imported:=schema_import(&link,root)
        if !testing.expect(t,imported!=TYPE_NONE) {continue}
        testing.expect_value(t,len(hashes),len(destination.types))
        testing.expect_value(t,schema_validate(&destination),Schema_Error.None)
        count:=len(destination.types)
        testing.expect_value(t,schema_import(&link,root),imported)
        testing.expect_value(t,len(destination.types),count)
        testing.expect_value(t,count,len(source.types))
    }
}

@(test)
migration_refuses_incomplete_hashes_and_retries_without_writing_the_destination :: proc(t:^testing.T) {
    Before :: struct {value:i32}
    After :: struct {value:f64}
    source,destination:Schema
    schema_init(&source);defer schema_destroy(&source)
    schema_init(&destination);defer schema_destroy(&destination)
    from,_:=schema_add(&source,Before)
    to,_:=schema_add(&destination,After)
    failure:=Schema_Allocation_Failure{owner=context.allocator}
    context.temp_allocator=runtime.Allocator{schema_failure_allocator,&failure}
    for budget in 0..<3 {
        failure.remaining=budget
        migration:Migration
        testing.expect_value(t,migration_init(&migration,&source,from,&destination,to),Schema_Error.Out_Of_Memory)
        defer migration_destroy(&migration)
        input:=Before{42};output:=After{91}
        migration_apply(&migration,mem.ptr_to_bytes(&output),mem.ptr_to_bytes(&input),1)
        testing.expect_value(t,output.value,f64(91))
        testing.expect_value(t,migration.src_size,0)
        testing.expect_value(t,migration.dst_size,0)
    }
    failure.remaining=128
    migration:Migration
    testing.expect_value(t,migration_init(&migration,&source,from,&destination,to),Schema_Error.None)
    defer migration_destroy(&migration)
    input:=Before{42};output:=After{91}
    migration_apply(&migration,mem.ptr_to_bytes(&output),mem.ptr_to_bytes(&input),1)
    testing.expect_value(t,output.value,f64(42))
}
