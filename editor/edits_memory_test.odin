package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"

@(test)
api_edit_end_reports_history_memory_failure_and_rolls_back_the_scene :: proc(t:^testing.T) {
    failure:=history.Test_Memory_Failure{owner=context.allocator,remaining=-1}
    f:history.Test_Memory
    {
        context.allocator={history.test_memory_allocator,&failure}
        if !history.test_memory_init(t,&f) {return}
    }
    defer history.test_memory_free(&f)
    w:=core.world_ref(&f.world,&f.info)
    testing.expect(t,history.edits_begin(&f.edits,&f.selection,"API candidate"))
    testing.expect_value(t,history.edits_cancel_prepare(&f.edits,w),history.Edit_Error.None)
    core.edit(&f.world.values,f.entity).value=20
    core.edit(&f.world.values,f.entity).derived=99
    core.remove(&f.world.others,f.entity)
    history.test_memory_settle(&f)
    history.selection_clear(&f.selection)
    session:=Session{info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,mode=.Edit}
    call:=api.Call{allocator=context.temp_allocator}
    failure.remaining,failure.attempts=0,0
    success:=true
    {
        context.allocator={history.test_memory_allocator,&failure}
        context.temp_allocator=context.allocator
        success=api_edit_end(&session,&call,true)
    }
    failure.remaining=-1
    testing.expect(t,!success && call.failed && call.error.code==api.SERVER_ERROR)
    testing.expect(t,!f.edits.open && len(f.edits.steps)==0)
    actual,_:=core.get(&f.world.values,f.entity)
    testing.expect_value(t,actual.value,10)
    testing.expect_value(t,actual.derived,99)
    testing.expect(t,core.has(&f.world.others,f.entity))
    testing.expect(t,len(f.selection.entities)==1 && f.selection.entities[0]==f.entity)
}

@(test)
ui_edit_open_memory_failure_keeps_the_component_and_its_stamp_unchanged :: proc(t:^testing.T) {
    failure:=history.Test_Memory_Failure{owner=context.allocator,remaining=-1}
    f:history.Test_Memory
    {
        context.allocator={history.test_memory_allocator,&failure}
        if !history.test_memory_init(t,&f) {return}
    }
    defer history.test_memory_free(&f)
    session:=Session{info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,mode=.Edit}
    prior:=f.world.values.version
    value:=history.Test_Memory_Value{value=20}
    written:=true
    failure.remaining=0
    {
        context.allocator={history.test_memory_allocator,&failure}
        context.temp_allocator=context.allocator
        written=field_write(&session,&f.info.tables[1],{f.entity},0,(cast([^]u8)&value)[:size_of(value.value)])
    }
    failure.remaining=-1
    testing.expect(t,!written && f.edits.error==.Memory && !f.edits.open)
    testing.expect_value(t,f.world.values.version,prior)
    actual,_:=core.get(&f.world.values,f.entity)
    testing.expect_value(t,actual.value,10)
    testing.expect(t,field_write(&session,&f.info.tables[1],{f.entity},0,(cast([^]u8)&value)[:size_of(value.value)]))
    testing.expect(t,history.edits_commit(&f.edits,core.world_ref(&f.world,&f.info),&f.selection))
    testing.expect(t,history.undo(&f.edits,core.world_ref(&f.world,&f.info),&f.selection))
    actual,_=core.get(&f.world.values,f.entity)
    testing.expect_value(t,actual.value,10)
}
