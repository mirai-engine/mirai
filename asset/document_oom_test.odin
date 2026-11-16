package asset

import "base:runtime"
import "core:testing"

@(private="file")
Document_Allocation_Failure :: struct {owner:runtime.Allocator,remaining:int}
@(private="file")
document_failure_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    state:=(^Document_Allocation_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(private="file")
document_oom_fixture :: proc(doc:^Document,types:^Types,allocator:runtime.Allocator) -> (int,bool) {
    document_init(doc,KIND_MATERIAL,{31,32},allocator)
    table,error:=document_table_add(doc,"seed",{.Single})
    if error!=.None {return -1,false}
    value:=[1]u32{42}
    _,column_error:=document_column_put(doc,types,table,"value",value[:])
    if column_error!=.None {return -1,false}
    return table,true
}

@(test)
document_table_add_rejects_each_allocation_failure_without_publishing_an_empty_name :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    failure:=Document_Allocation_Failure{owner=context.allocator}
    allocator:=runtime.Allocator{document_failure_allocator,&failure}
    succeeded:=false;failed:=0
    for budget in 0..<8 {
        failure.remaining=1000
        doc:Document
        table,ready:=document_oom_fixture(&doc,&types,allocator)
        defer document_destroy(&doc)
        if !testing.expect(t,ready) {return}
        tight:=make([dynamic]Doc_Table,len(doc.tables),len(doc.tables),allocator)
        copy(tight[:],doc.tables[:]);delete(doc.tables);doc.tables=tight
        old_table:=raw_data(doc.tables)
        seed:=doc.tables[table]
        failure.remaining=budget
        added,error:=document_table_add(&doc,"requested",{.Single})
        if error==.None {
            testing.expect_value(t,added,1)
            testing.expect_value(t,doc.tables[added].name,"requested")
            succeeded=true
        } else {
            failed+=1
            testing.expect_value(t,error,Error.Out_Of_Memory)
            testing.expect_value(t,added,-1)
            testing.expect_value(t,len(doc.tables),1)
            testing.expect_value(t,raw_data(doc.tables),old_table)
            testing.expect_value(t,doc.tables[table].name,seed.name)
            testing.expect_value(t,doc.tables[table].name_hash,seed.name_hash)
            testing.expect_value(t,doc.tables[table].rows,seed.rows)
            _,exists:=document_table(&doc,"requested");testing.expect(t,!exists)
            failure.remaining=1000
            retry,retried:=document_table_add(&doc,"requested",{.Single})
            testing.expect_value(t,retried,Error.None)
            testing.expect_value(t,retry,1)
        }
        testing.expect_value(t,(^u32)(raw_data(document_cell(&doc,table,0,0)))^,u32(42))
        if succeeded {break}
    }
    testing.expect(t,succeeded && failed==2)
}

@(test)
document_column_add_releases_each_partial_allocation_and_preserves_existing_rows :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    failure:=Document_Allocation_Failure{owner=context.allocator}
    allocator:=runtime.Allocator{document_failure_allocator,&failure}
    succeeded:=false;failed:=0
    for budget in 0..<8 {
        failure.remaining=1000
        doc:Document
        table,ready:=document_oom_fixture(&doc,&types,allocator)
        defer document_destroy(&doc)
        if !testing.expect(t,ready) {return}
        tight:=make([dynamic]Doc_Column,len(doc.tables[table].columns),len(doc.tables[table].columns),allocator)
        copy(tight[:],doc.tables[table].columns[:]);delete(doc.tables[table].columns);doc.tables[table].columns=tight
        old_columns:=raw_data(doc.tables[table].columns)
        old_data:=raw_data(doc.tables[table].columns[0].data)
        type:=doc.tables[table].columns[0].type
        failure.remaining=budget
        added,error:=document_column_add(&doc,table,"requested",type)
        if error==.None {
            testing.expect_value(t,added,1)
            testing.expect_value(t,doc.tables[table].columns[added].name,"requested")
            testing.expect_value(t,(^u32)(raw_data(document_cell(&doc,table,added,0)))^,u32(0))
            succeeded=true
        } else {
            failed+=1
            testing.expect_value(t,error,Error.Out_Of_Memory)
            testing.expect_value(t,added,-1)
            testing.expect_value(t,len(doc.tables[table].columns),1)
            testing.expect_value(t,raw_data(doc.tables[table].columns),old_columns)
            testing.expect_value(t,raw_data(doc.tables[table].columns[0].data),old_data)
            _,exists:=document_column(&doc,table,"requested");testing.expect(t,!exists)
            failure.remaining=1000
            retry,retried:=document_column_add(&doc,table,"requested",type)
            testing.expect_value(t,retried,Error.None)
            testing.expect_value(t,retry,1)
        }
        testing.expect_value(t,doc.tables[table].rows,1)
        testing.expect_value(t,(^u32)(raw_data(document_cell(&doc,table,0,0)))^,u32(42))
        if succeeded {break}
    }
    testing.expect(t,succeeded && failed==3)
}
