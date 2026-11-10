package editor

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"

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
Edit_Memory_Fixture :: struct {world:Edit_Memory_World,tables:[4]core.Table_Info,info:core.World_Info,edits:history.Edits,selection:history.Selection,entity:core.Entity}

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
    history.selection_set(&f.selection,{f.entity})
    history.edits_reset(&f.edits,core.world_ref(&f.world,&f.info))
}

@(private="file")
edit_memory_free :: proc(f:^Edit_Memory_Fixture) {
    history.edits_free(&f.edits)
    delete(f.selection.entities)
    core.table_destroy(&f.world.ids);core.table_destroy(&f.world.values);core.table_destroy(&f.world.others)
    core.entities_destroy(&f.world.entities)
}

@(test)
api_edit_end_reports_history_memory_failure_and_rolls_back_the_scene :: proc(t:^testing.T) {
    failure:=Edit_Memory_Failure{owner=context.allocator,remaining=-1}
    f:Edit_Memory_Fixture
    {
        context.allocator={edit_memory_allocator,&failure}
        edit_memory_init(&f)
    }
    defer edit_memory_free(&f)
    w:=core.world_ref(&f.world,&f.info)
    testing.expect(t,history.edits_begin(&f.edits,&f.selection,"API candidate"))
    testing.expect_value(t,history.edits_cancel_prepare(&f.edits,w),history.Edit_Error.None)
    core.get(&f.world.values,f.entity).value=20
    core.get(&f.world.values,f.entity).derived=99
    core.remove(&f.world.others,f.entity)
    edit_memory_settle(&f.world,nil,nil)
    history.selection_clear(&f.selection)
    session:=Session{info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,mode=.Edit}
    call:=api.Call{allocator=context.temp_allocator}
    failure.remaining,failure.attempts=0,0
    success:=true
    {
        context.allocator={edit_memory_allocator,&failure}
        context.temp_allocator=context.allocator
        success=api_edit_end(&session,&call,true)
    }
    failure.remaining=-1
    testing.expect(t,!success && call.failed && call.error.code==api.SERVER_ERROR)
    testing.expect(t,!f.edits.open && len(f.edits.steps)==0)
    actual,_:=core.get(core.read(&f.world.values),f.entity)
    testing.expect_value(t,actual.value,10)
    testing.expect_value(t,actual.derived,99)
    testing.expect(t,core.has(&f.world.others,f.entity))
    testing.expect(t,len(f.selection.entities)==1 && f.selection.entities[0]==f.entity)
}

@(test)
ui_edit_open_memory_failure_keeps_the_component_and_its_stamp_unchanged :: proc(t:^testing.T) {
    failure:=Edit_Memory_Failure{owner=context.allocator,remaining=-1}
    f:Edit_Memory_Fixture
    {
        context.allocator={edit_memory_allocator,&failure}
        edit_memory_init(&f)
    }
    defer edit_memory_free(&f)
    session:=Session{info=&f.info,edit_world=&f.world,edits=&f.edits,selection=&f.selection,mode=.Edit}
    prior:=f.world.values.version
    value:=Edit_Memory_Value{value=20}
    written:=true
    failure.remaining=0
    {
        context.allocator={edit_memory_allocator,&failure}
        context.temp_allocator=context.allocator
        written=field_write(&session,&f.tables[1],{f.entity},0,(cast([^]u8)&value)[:size_of(value.value)])
    }
    failure.remaining=-1
    testing.expect(t,!written && f.edits.error==.Memory && !f.edits.open)
    testing.expect_value(t,f.world.values.version,prior)
    actual,_:=core.get(core.read(&f.world.values),f.entity)
    testing.expect_value(t,actual.value,10)
    testing.expect(t,field_write(&session,&f.tables[1],{f.entity},0,(cast([^]u8)&value)[:size_of(value.value)]))
    testing.expect(t,history.edits_commit(&f.edits,core.world_ref(&f.world,&f.info),&f.selection))
    testing.expect(t,history.undo(&f.edits,core.world_ref(&f.world,&f.info),&f.selection))
    actual,_=core.get(core.read(&f.world.values),f.entity)
    testing.expect_value(t,actual.value,10)
}
