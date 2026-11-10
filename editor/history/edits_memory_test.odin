package history

import "base:runtime"
import "core:testing"
import "mirai:core"

@(private="file")
Edit_Memory_Failure :: struct {owner:runtime.Allocator,remaining,attempts:int}

@(private="file")
edit_memory_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    failure:=(^Edit_Memory_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        failure.attempts+=1
        if failure.remaining==0 {return nil,.Out_Of_Memory}
        if failure.remaining>0 {failure.remaining-=1}
    }
    return failure.owner.procedure(failure.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(private="file")
Edit_Memory_Value :: struct {value:int,derived:int `mirai:"transient"`}
@(private="file")
Edit_Memory_Other :: struct {value:int}
@(private="file")
Edit_Memory_World :: struct {entities:core.Entities,ids:core.Table(core.Id),values:core.Table(Edit_Memory_Value),others:core.Table(Edit_Memory_Other)}
@(private="file")
Edit_Memory_Fixture :: struct {world:Edit_Memory_World,tables:[4]core.Table_Info,info:core.World_Info,edits:Edits,selection:Selection,entity:core.Entity}

@(private="file")
edit_memory_settle :: proc(data,shared,editor:rawptr) {
    world:=(^Edit_Memory_World)(data)
    core.table_settle(&world.ids,&world.entities)
    core.table_settle(&world.values,&world.entities)
    core.table_settle(&world.others,&world.entities)
    core.entities_settle(&world.entities)
}

@(private="file")
edit_memory_init :: proc(f:^Edit_Memory_Fixture) {
    core.entities_init(&f.world.entities)
    core.table_init(&f.world.ids,"Id")
    core.table_init(&f.world.values,"Value")
    core.table_init(&f.world.others,"Other")
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Edit_Memory_World,ids)},
        {name="Value",type=Edit_Memory_Value,info=type_info_of(Edit_Memory_Value),offset=offset_of(Edit_Memory_World,values)},
        {name="Other",type=Edit_Memory_Other,info=type_info_of(Edit_Memory_Other),offset=offset_of(Edit_Memory_World,others)},
        {name="Editor_Only",type=core.Name,info=type_info_of(core.Name),place=.Editor},
    }
    f.info={entities=offset_of(Edit_Memory_World,entities),tables=f.tables[:]}
    f.entity=core.create(&f.world.entities)
    core.add(&f.world.ids,f.entity,{value=1})
    core.add(&f.world.values,f.entity,{value=10,derived=5})
    core.add(&f.world.others,f.entity,{value=2})
    edit_memory_settle(&f.world,nil,nil)
    selection_set(&f.selection,{f.entity})
    edits_reset(&f.edits,core.world_ref(&f.world,&f.info))
}

@(private="file")
edit_memory_free :: proc(f:^Edit_Memory_Fixture) {
    edits_free(&f.edits)
    delete(f.selection.entities)
    core.table_destroy(&f.world.ids);core.table_destroy(&f.world.values);core.table_destroy(&f.world.others)
    core.entities_destroy(&f.world.entities)
}

@(test)
edits_prepare_memory_failure_preserves_baselines_redo_and_the_open_gesture :: proc(t:^testing.T) {
    failures:=0
    completed:=false
    for budget in 0..<64 {
        failure:=Edit_Memory_Failure{owner=context.allocator,remaining=-1}
        f:Edit_Memory_Fixture
        {
            context.allocator={edit_memory_allocator,&failure}
            edit_memory_init(&f)
        }
        w:=core.world_ref(&f.world,&f.info)
        for value in 11..=12 {
            testing.expect(t,edits_begin(&f.edits,&f.selection,"Original"))
            core.get(&f.world.values,f.entity).value=value
            testing.expect(t,edits_commit(&f.edits,w,&f.selection))
        }
        testing.expect(t,undo(&f.edits,w,&f.selection))
        serial,cursor,steps,bytes:=f.edits.serial,f.edits.cursor,len(f.edits.steps),f.edits.bytes
        testing.expect(t,edits_begin(&f.edits,&f.selection,"Candidate"))
        core.get(&f.world.values,f.entity).value=20
        core.remove(&f.world.others,f.entity)
        added:=core.create(&f.world.entities)
        core.add(&f.world.ids,added,{value=2});core.add(&f.world.values,added,{value=30})
        edit_memory_settle(&f.world,nil,nil)
        failure.remaining,failure.attempts=budget,0
        prepared:Edit_Preparation
        error:Edit_Error
        {
            context.allocator={edit_memory_allocator,&failure}
            context.temp_allocator=context.allocator
            prepared,error=edits_prepare(&f.edits,w,&f.selection)
        }
        failure.remaining=-1
        if error!=.None {
            failures+=1
            testing.expect_value(t,error,Edit_Error.Memory)
            testing.expect(t,!prepared.ready && f.edits.open)
            testing.expect_value(t,f.edits.serial,serial)
            testing.expect_value(t,f.edits.cursor,cursor)
            testing.expect_value(t,len(f.edits.steps),steps)
            testing.expect_value(t,f.edits.bytes,bytes)
            image:=&f.edits.image[1]
            copied:=cast(^Edit_Memory_Value)journal_value(image,size_of(Edit_Memory_Value),journal_row(image,f.entity))
            testing.expect_value(t,copied.value,11)
            actual,_:=core.get(core.read(&f.world.values),f.entity)
            testing.expect_value(t,actual.value,20)
            testing.expect(t,core.alive(&f.world.entities,added))
            prepared,error=edits_prepare(&f.edits,w,&f.selection)
        } else {completed=true}
        testing.expect_value(t,error,Edit_Error.None)
        failure.remaining,failure.attempts=0,0
        {
            context.allocator={edit_memory_allocator,&failure}
            context.temp_allocator=context.allocator
            testing.expect_value(t,edits_preparation_valid(&f.edits,w,&prepared),Edit_Error.None)
            testing.expect_value(t,edits_commit_prepared(&f.edits,w,&prepared),Edit_Error.None)
        }
        testing.expect_value(t,failure.attempts,0)
        failure.remaining=-1
        edits_preparation_destroy(&prepared)
        testing.expect(t,undo(&f.edits,w,&f.selection))
        actual,_:=core.get(core.read(&f.world.values),f.entity)
        testing.expect_value(t,actual.value,11)
        testing.expect(t,core.has(&f.world.others,f.entity) && !core.alive(&f.world.entities,added))
        testing.expect(t,redo(&f.edits,w,&f.selection))
        actual,_=core.get(core.read(&f.world.values),f.entity)
        testing.expect_value(t,actual.value,20)
        testing.expect(t,!core.has(&f.world.others,f.entity) && core.alive(&f.world.entities,added))
        edit_memory_free(&f)
        if completed {break}
    }
    testing.expect(t,completed && failures>=6)
}

@(test)
edits_reserved_cancel_restores_deleted_rows_and_handles_without_allocating :: proc(t:^testing.T) {
    failure:=Edit_Memory_Failure{owner=context.allocator,remaining=-1}
    f:Edit_Memory_Fixture
    {
        context.allocator={edit_memory_allocator,&failure}
        edit_memory_init(&f)
    }
    defer edit_memory_free(&f)
    w:=core.world_ref(&f.world,&f.info)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Delete and reuse"))
    testing.expect_value(t,edits_cancel_prepare(&f.edits,w,4),Edit_Error.None)
    core.destroy(&f.world.entities,f.entity)
    edit_memory_settle(&f.world,nil,nil)
    reused:=core.create(&f.world.entities)
    core.add(&f.world.ids,reused,{value=2})
    core.add(&f.world.values,reused,{value=99,derived=77})
    for index in 0..<10 {
        added:=core.create(&f.world.entities)
        core.add(&f.world.ids,added,{value=type_of(core.Id{}.value)(index+10)})
        core.add(&f.world.values,added,{value=index})
    }
    edit_memory_settle(&f.world,nil,nil)
    testing.expect_value(t,core.entity_index(reused),core.entity_index(f.entity))
    serial:=f.edits.serial
    failure.remaining,failure.attempts=0,0
    {
        context.allocator={edit_memory_allocator,&failure}
        context.temp_allocator=context.allocator
        edits_cancel(&f.edits,w)
    }
    testing.expect_value(t,failure.attempts,0)
    failure.remaining=-1
    testing.expect(t,!f.edits.open && f.edits.error==.None)
    testing.expect(t,core.alive(&f.world.entities,f.entity) && !core.alive(&f.world.entities,reused))
    testing.expect(t,core.has(&f.world.others,f.entity))
    actual,_:=core.get(core.read(&f.world.values),f.entity)
    testing.expect_value(t,actual.value,10)
    testing.expect_value(t,f.edits.serial,serial)
    testing.expect_value(t,len(f.edits.steps),0)
}

@(test)
edits_prepared_tokens_reject_changed_tables_pending_writes_and_selection :: proc(t:^testing.T) {
    f:Edit_Memory_Fixture;edit_memory_init(&f);defer edit_memory_free(&f)
    w:=core.world_ref(&f.world,&f.info)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Candidate"))
    core.get(&f.world.values,f.entity).value=20
    for kind in 0..<3 {
        prepared,error:=edits_prepare(&f.edits,w,&f.selection)
        testing.expect_value(t,error,Edit_Error.None)
        switch kind {
        case 0:core.get(&f.world.values,f.entity).value+=1
        case 1:core.add(&f.world.others,f.entity,{value=3})
        case 2:selection_clear(&f.selection)
        }
        testing.expect_value(t,edits_preparation_valid(&f.edits,w,&prepared),Edit_Error.Stale)
        testing.expect_value(t,edits_commit_prepared(&f.edits,w,&prepared),Edit_Error.Stale)
        testing.expect(t,f.edits.open && len(f.edits.steps)==0)
        edits_preparation_destroy(&prepared)
    }
    edits_cancel(&f.edits,w)
    actual,_:=core.get(core.read(&f.world.values),f.entity)
    testing.expect_value(t,actual.value,10)
}
