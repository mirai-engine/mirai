package history

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"

// A component with a field a scene does not save.
Test_Lamp :: struct {power:f32,glow:f32 `mirai:"transient"`}

@(test_world)
Test_Journal_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    lamps:core.Table(Test_Lamp),
}

// A World with its history and its selection, for the tests of the journal
// and of what reads it.
Test_Journal :: struct {
    world:Test_Journal_World,
    edits:Edits,
    selection:Selection,
}

// A World of count entities with an Id from 1, a Transform at x=Id and a
// Lamp, and every tenth without an Id: derived.
test_journal_init :: proc(t:^testing.T,f:^Test_Journal,count:int) -> bool {
    w:=&f.world
    if !test_world_init(t,w) {return false}
    for i in 0..<count {
        e:=core.create(&w.entities)
        if i%10!=9 {core.add(&w.ids,e,{value=base.Entity_Id(i+1)})}
        core.add(&w.transforms,e,core.Transform{{f32(i+1),0,0},1,{1,1,1}})
        core.add(&w.lamps,e,{power=1,glow=f32(i)})
    }
    test_world_settle(w)
    edits_reset(&f.edits,test_world_ref(w))
    return true
}

test_journal_free :: proc(f:^Test_Journal) {
    edits_free(&f.edits)
    delete(f.selection.entities)
    test_world_destroy(&f.world)
}

test_journal_entity :: proc(f:^Test_Journal,id:base.Entity_Id) -> core.Entity {
    for value,row in f.world.ids.values {if value.value==id {return f.world.ids.entities[row]}}
    return core.NONE
}

// An allocator that fails once remaining allocations of its owner went: -1, never.
Test_Memory_Failure :: struct {owner:runtime.Allocator,remaining,attempts:int}

test_memory_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    failure:=(^Test_Memory_Failure)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        failure.attempts+=1
        if failure.remaining==0 {return nil,.Out_Of_Memory}
        if failure.remaining>0 {failure.remaining-=1}
    }
    return failure.owner.procedure(failure.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

Test_Memory_Value :: struct {value:int,derived:int `mirai:"transient"`}
Test_Memory_Other :: struct {value:int}

@(test_world,editor="Test_Memory_Editor")
Test_Memory_World :: struct {
    using world:Test_World,
    ids:core.Table(core.Id),
    values:core.Table(Test_Memory_Value),
    others:core.Table(Test_Memory_Other),
}

// A table of the editor, which a history does not keep.
Test_Memory_Editor :: struct {
    names:core.Table(core.Name) `mirai:"name=Editor_Only"`,
}

// A World of one entity with a Value and an Other, selected, with its
// history, for the tests of what an edit does without memory.
Test_Memory :: struct {
    world:Test_Memory_World,
    info:core.World_Info,
    edits:Edits,
    selection:Selection,
    entity:core.Entity,
}

test_memory_init :: proc(t:^testing.T,f:^Test_Memory) -> bool {
    described:bool
    f.info,described=test_info(t,Test_Memory_World)
    if !described {return false}
    if !testing.expect(t,core.world_init(&f.info,.World,&f.world,context.allocator)) {
        test_memory_free(f)
        return false
    }
    f.entity=core.create(&f.world.entities)
    core.add(&f.world.ids,f.entity,{value=1})
    core.add(&f.world.values,f.entity,{value=10,derived=5})
    core.add(&f.world.others,f.entity,{value=2})
    test_memory_settle(f)
    selection_set(&f.selection,{f.entity})
    edits_reset(&f.edits,core.world_ref(&f.world,&f.info))
    return true
}

test_memory_free :: proc(f:^Test_Memory) {
    edits_free(&f.edits)
    delete(f.selection.entities)
    if f.info.sizes[.World]>0 {core.world_destroy(&f.info,.World,&f.world)}
    test_info_destroy(&f.info)
}

test_memory_settle :: proc(f:^Test_Memory) {core.settle(&f.info,&f.world,nil)}
