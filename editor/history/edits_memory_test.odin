package history

import "base:runtime"
import "core:testing"
import "mirai:core"

@(test)
edits_prepare_memory_failure_preserves_baselines_redo_and_the_open_gesture :: proc(t:^testing.T) {
    failures:=0
    completed:=false
    for budget in 0..<64 {
        failure:=Test_Memory_Failure{owner=context.allocator,remaining=-1}
        f:Test_Memory
        {
            context.allocator={test_memory_allocator,&failure}
            if !test_memory_init(t,&f) {return}
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
        test_memory_settle(&f)
        failure.remaining,failure.attempts=budget,0
        prepared:Edit_Preparation
        error:Edit_Error
        {
            context.allocator={test_memory_allocator,&failure}
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
            copied:=cast(^Test_Memory_Value)journal_value(image,size_of(Test_Memory_Value),journal_row(image,f.entity))
            testing.expect_value(t,copied.value,11)
            actual,_:=core.get(core.read(&f.world.values),f.entity)
            testing.expect_value(t,actual.value,20)
            testing.expect(t,core.alive(&f.world.entities,added))
            prepared,error=edits_prepare(&f.edits,w,&f.selection)
        } else {completed=true}
        testing.expect_value(t,error,Edit_Error.None)
        failure.remaining,failure.attempts=0,0
        {
            context.allocator={test_memory_allocator,&failure}
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
        test_memory_free(&f)
        if completed {break}
    }
    testing.expect(t,completed && failures>=6)
}

@(test)
edits_reserved_cancel_restores_deleted_rows_and_handles_without_allocating :: proc(t:^testing.T) {
    failure:=Test_Memory_Failure{owner=context.allocator,remaining=-1}
    f:Test_Memory
    {
        context.allocator={test_memory_allocator,&failure}
        if !test_memory_init(t,&f) {return}
    }
    defer test_memory_free(&f)
    w:=core.world_ref(&f.world,&f.info)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Delete and reuse"))
    testing.expect_value(t,edits_cancel_prepare(&f.edits,w,4),Edit_Error.None)
    core.destroy(&f.world.entities,f.entity)
    test_memory_settle(&f)
    reused:=core.create(&f.world.entities)
    core.add(&f.world.ids,reused,{value=2})
    core.add(&f.world.values,reused,{value=99,derived=77})
    for index in 0..<10 {
        added:=core.create(&f.world.entities)
        core.add(&f.world.ids,added,{value=type_of(core.Id{}.value)(index+10)})
        core.add(&f.world.values,added,{value=index})
    }
    test_memory_settle(&f)
    testing.expect_value(t,core.entity_index(reused),core.entity_index(f.entity))
    serial:=f.edits.serial
    failure.remaining,failure.attempts=0,0
    {
        context.allocator={test_memory_allocator,&failure}
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
    f:Test_Memory
    if !test_memory_init(t,&f) {return}
    defer test_memory_free(&f)
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
