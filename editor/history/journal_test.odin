package history

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"

@(test)
journal_readers_keep_cursors_of_their_own :: proc(t:^testing.T) {
    f:=new(Test_Journal);defer free(f)
    if !test_journal_init(t,f,20) {return}
    defer test_journal_free(f)
    w:=core.test_world_ref(&f.world)
    // The image keeps the authors: the derived rows never enter it.
    testing.expect_value(t,len(f.edits.image[1].entities),18)
    testing.expect_value(t,len(f.edits.image[3].entities),18)
    collab:=journal_reading(&f.edits,true)
    first:=test_journal_entity(f,1)
    // Undo reads the steps, the review of an agent and prefabs the state of a step, collaboration the changes.
    review:=edits_state(&f.edits)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Move"))
    core.edit(&f.world.transforms,first).position.y=5
    core.edit(&f.world.lamps,first).glow=99 // transient: not a change
    edits_end(&f.edits)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    testing.expect_value(t,f.edits.cursor,1)
    read:=journal_read(&f.edits,&collab)
    testing.expect(t,len(read)==1 && read[0].entity==first && read[0].table==1 && read[0].present && read[0].id==1)
    // The change keeps the row as it was, until its readers are done with it.
    if before,kept:=journal_change_value(&f.edits,read[0],size_of(core.Transform));testing.expect(t,kept) {
        testing.expect_value(t,(^core.Transform)(raw_data(before)).position,[3]f32{1,0,0})
    }
    journal_read_done(&f.edits,collab)
    testing.expect(t,len(f.edits.changes)==0 && len(f.edits.change_values)==0)
    observed:=edits_state(&f.edits)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Turn off"))
    core.disable(&f.world.lamps,test_journal_entity(f,2))
    core.test_world_settle(&f.world)
    edits_end(&f.edits)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    after_review:=0
    for step in f.edits.steps[:f.edits.cursor] {if step.state>review {after_review+=1}}
    after_observed:=0
    for step in f.edits.steps[:f.edits.cursor] {if step.state>observed {after_observed+=1}}
    testing.expect(t,after_review==2 && after_observed==1)
    read=journal_read(&f.edits,&collab)
    testing.expect(t,len(read)==1 && read[0].table==3 && read[0].present && !read[0].off)
    journal_read_done(&f.edits,collab)
    // Undo is a change for collaboration too; a cancel puts the World back
    // where the journal is, without a change.
    testing.expect(t,undo(&f.edits,w,&f.selection))
    _,off,_:=core.raw_state(core.raw(&f.world.lamps),test_journal_entity(f,2))
    testing.expect(t,!off)
    read=journal_read(&f.edits,&collab)
    testing.expect(t,len(read)==1 && read[0].table==3 && read[0].off)
    journal_read_done(&f.edits,collab)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Cancelled"))
    testing.expect_value(t,edits_cancel_prepare(&f.edits,w),Edit_Error.None)
    core.edit(&f.world.transforms,first).position.y=7
    edits_cancel(&f.edits,w)
    testing.expect_value(t,core.at(&f.world.transforms,core.row_of(&f.world.transforms,first)).position.y,f32(5))
    testing.expect_value(t,len(journal_read(&f.edits,&collab)),0)
    testing.expect(t,journal_settled(&f.edits,w))
    journal_reading(&f.edits,false)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Unread"))
    core.edit(&f.world.transforms,first).position.y=8
    edits_end(&f.edits)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    testing.expect(t,len(f.edits.changes)==0 && len(f.edits.change_values)==0)
}

@(test)
journal_steps_hold_what_changed_whatever_the_size_of_the_world :: proc(t:^testing.T) {
    f:=new(Test_Journal);defer free(f)
    if !test_journal_init(t,f,4000) {return}
    defer test_journal_free(f)
    w:=core.test_world_ref(&f.world)
    // A step that makes and destroys entities keeps those indices, not the entities of the World.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Replace"))
    gone:=test_journal_entity(f,51)
    core.destroy(&f.world.entities,gone)
    core.test_world_settle(&f.world)
    made:=core.create(&f.world.entities)
    core.add(&f.world.ids,made,{value=9001})
    core.add(&f.world.transforms,made,core.TRANSFORM_IDENTITY)
    derived:=core.create(&f.world.entities)
    core.add(&f.world.transforms,derived,core.TRANSFORM_IDENTITY)
    core.test_world_settle(&f.world)
    edits_end(&f.edits)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    step:=&f.edits.steps[0]
    testing.expect_value(t,core.entity_index(made),core.entity_index(gone))
    testing.expect_value(t,len(step.entities.indices),2)
    testing.expect(t,step.bytes<1024,"a step costs what it changed")
    rows:=0
    for r in step.tables {rows+=len(r.entities)}
    testing.expect_value(t,rows,5) // Id, Transform and Lamp of the one gone; Id and Transform of the one made
    testing.expect(t,undo(&f.edits,w,&f.selection))
    testing.expect(t,core.alive(&f.world.entities,gone) && !core.alive(&f.world.entities,made) && !core.alive(&f.world.entities,derived))
    testing.expect_value(t,core.at(&f.world.transforms,core.row_of(&f.world.transforms,gone)).position.x,f32(51))
    testing.expect(t,redo(&f.edits,w,&f.selection))
    testing.expect(t,!core.alive(&f.world.entities,gone) && core.alive(&f.world.entities,made) && core.has(&f.world.ids,made))
    testing.expect(t,!core.alive(&f.world.entities,derived),"what a library derived is derived again")
    testing.expect(t,journal_settled(&f.edits,w))
    // A move of a World this size compares only the row it wrote.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Move"))
    core.edit(&f.world.transforms,test_journal_entity(f,7)).position.z=3
    edits_end(&f.edits)
    compared:=f.edits.stats.compared
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    testing.expect_value(t,f.edits.stats.compared-compared,1)
    testing.expect(t,f.edits.steps[f.edits.cursor-1].bytes<128)
}

@(private="file")
Journal_Failure :: struct {owner:runtime.Allocator,attempts:int,fail:bool}

@(private="file")
journal_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    failure:=(^Journal_Failure)(data)
    if failure.fail && (mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed) {
        failure.attempts+=1
        return nil,.Out_Of_Memory
    }
    return failure.owner.procedure(failure.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
journal_cancel_and_undo_put_the_world_back_in_the_room_they_reserved :: proc(t:^testing.T) {
    f:=new(Test_Journal);defer free(f)
    failure:=Journal_Failure{owner=context.allocator}
    context.allocator={journal_allocator,&failure}
    if !test_journal_init(t,f,300) {return}
    defer test_journal_free(f)
    w:=core.test_world_ref(&f.world)
    lamp,moved,gone,parent:=test_journal_entity(f,3),test_journal_entity(f,4),test_journal_entity(f,5),test_journal_entity(f,6)
    core.disable(&f.world.lamps,gone)
    core.test_world_settle(&f.world)
    edits_reset(&f.edits,w)
    // A gesture that turns, writes, removes off rows, destroys, reuses and
    // makes more entities than it reserved.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Everything"))
    testing.expect_value(t,edits_cancel_prepare(&f.edits,w,2),Edit_Error.None)
    core.disable(&f.world.lamps,lamp)
    core.edit(&f.world.transforms,moved).position.y=4
    core.add(&f.world.parents,moved,{entity=parent})
    core.destroy(&f.world.entities,gone)
    core.test_world_settle(&f.world)
    for _ in 0..<40 {
        e:=core.create(&f.world.entities)
        core.add(&f.world.ids,e,{value=base.Entity_Id(1000+core.entity_index(e))})
        core.add(&f.world.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&f.world.lamps,e,{power=2})
    }
    core.test_world_settle(&f.world)
    failure.fail=true
    edits_cancel(&f.edits,w)
    failure.fail=false
    testing.expect_value(t,failure.attempts,0)
    testing.expect(t,!f.edits.open && f.edits.error==.None)
    testing.expect(t,journal_settled(&f.edits,w))
    testing.expect_value(t,f.world.entities.alive,300)
    testing.expect(t,core.alive(&f.world.entities,gone) && core.has(&f.world.ids,gone))
    _,off,found:=core.raw_state(core.raw(&f.world.lamps),gone)
    testing.expect(t,found && off,"an off row that went comes back off")
    testing.expect(t,core.has(&f.world.lamps,lamp) && !core.has(&f.world.parents,moved))
    testing.expect_value(t,core.at(&f.world.transforms,core.row_of(&f.world.transforms,moved)).position.y,f32(0))
    // Undo and redo of that gesture, committed, do not allocate either once prepared.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Everything"))
    core.disable(&f.world.lamps,lamp)
    core.destroy(&f.world.entities,gone)
    core.test_world_settle(&f.world)
    for _ in 0..<40 {
        e:=core.create(&f.world.entities)
        core.add(&f.world.ids,e,{value=base.Entity_Id(1000+core.entity_index(e))})
        core.add(&f.world.transforms,e,core.TRANSFORM_IDENTITY)
    }
    core.test_world_settle(&f.world)
    edits_end(&f.edits)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    step:=&f.edits.steps[f.edits.cursor-1]
    testing.expect_value(t,edits_step_prepare(&f.edits,w,step,&f.selection,step.before[:]),Edit_Error.None)
    failure.fail=true
    step_swap(&f.edits,w,step)
    failure.fail=false
    f.edits.cursor-=1
    f.edits.order+=1
    step.undone=f.edits.order
    testing.expect_value(t,failure.attempts,0)
    testing.expect(t,journal_settled(&f.edits,w))
    testing.expect(t,core.alive(&f.world.entities,gone) && core.has(&f.world.lamps,lamp))
    testing.expect_value(t,f.world.entities.alive,300)
    testing.expect(t,redo(&f.edits,w,&f.selection))
    testing.expect(t,!core.alive(&f.world.entities,gone) && !core.has(&f.world.lamps,lamp))
    testing.expect_value(t,f.world.entities.alive,339)
}

// Two ends of a session, each with its document: what one edits reaches the
// other from the journal, as Sets, Fields, Turns and Removes, and what
// arrives is not sent back.
