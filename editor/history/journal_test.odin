package history

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:std/base"

@(private="file")
Journal_Lamp :: struct {power:f32,glow:f32 `mirai:"transient"`}

@(private="file")
Journal_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),
    transforms:core.Table(core.Transform),
    parents:core.Table(core.Parent),
    lamps:core.Table(Journal_Lamp),
}

@(private="file")
Journal_Fixture :: struct {
    world:Journal_World,
    tables:[4]core.Table_Info,
    info:core.World_Info,
    edits:Edits,
    selection:Selection,
}

@(private="file")
journal_settle :: proc(data,shared,editor:rawptr) {
    w:=(^Journal_World)(data)
    core.table_settle(&w.ids,&w.entities);core.table_settle(&w.transforms,&w.entities)
    core.table_settle(&w.parents,&w.entities);core.table_settle(&w.lamps,&w.entities)
    core.entities_settle(&w.entities)
}

// A World of count entities with an Id from 1, a Transform at x=Id and a
// Lamp, and every tenth without an Id: derived.
@(private="file")
journal_init :: proc(f:^Journal_Fixture,count:int) {
    w:=&f.world
    core.entities_init(&w.entities)
    core.table_init(&w.ids,"Id");core.table_init(&w.transforms,"Transform");core.table_init(&w.parents,"Parent");core.table_init(&w.lamps,"Lamp")
    f.tables={
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Journal_World,ids)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Journal_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Journal_World,parents)},
        {name="Lamp",type=Journal_Lamp,info=type_info_of(Journal_Lamp),offset=offset_of(Journal_World,lamps)},
    }
    f.info={entities=offset_of(Journal_World,entities),tables=f.tables[:]}
    for i in 0..<count {
        e:=core.create(&w.entities)
        if i%10!=9 {core.add(&w.ids,e,{value=base.Entity_Id(i+1)})}
        core.add(&w.transforms,e,core.Transform{{f32(i+1),0,0},1,{1,1,1}})
        core.add(&w.lamps,e,{power=1,glow=f32(i)})
    }
    journal_settle(w,nil,nil)
    edits_reset(&f.edits,journal_world(f))
}

@(private="file")
journal_free :: proc(f:^Journal_Fixture) {
    edits_free(&f.edits)
    delete(f.selection.entities)
    w:=&f.world
    core.table_destroy(&w.ids);core.table_destroy(&w.transforms);core.table_destroy(&w.parents);core.table_destroy(&w.lamps)
    core.entities_destroy(&w.entities)
}

@(private="file")
journal_world :: proc(f:^Journal_Fixture) -> core.World_Ref {return core.world_ref(&f.world,&f.info)}

@(private="file")
journal_entity :: proc(f:^Journal_Fixture,id:base.Entity_Id) -> core.Entity {
    for value,row in f.world.ids.values {if value.value==id {return f.world.ids.entities[row]}}
    return core.NONE
}

@(test)
journal_readers_keep_cursors_of_their_own :: proc(t:^testing.T) {
    f:=new(Journal_Fixture);defer free(f)
    journal_init(f,20);defer journal_free(f)
    w:=journal_world(f)
    // The image keeps the authors: the derived rows never enter it.
    testing.expect_value(t,len(f.edits.image[1].entities),18)
    testing.expect_value(t,len(f.edits.image[3].entities),18)
    collab:=journal_reading(&f.edits,true)
    first:=journal_entity(f,1)
    // Undo reads the steps, the review of an agent and prefabs the state of a step, collaboration the changes.
    review:=edits_state(&f.edits)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Move"))
    core.get(&f.world.transforms,first).position.y=5
    core.get(&f.world.lamps,first).glow=99 // transient: not a change
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
    core.disable(&f.world.lamps,journal_entity(f,2))
    journal_settle(&f.world,nil,nil)
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
    _,off,_:=core.raw_state(core.raw(&f.world.lamps),journal_entity(f,2))
    testing.expect(t,!off)
    read=journal_read(&f.edits,&collab)
    testing.expect(t,len(read)==1 && read[0].table==3 && read[0].off)
    journal_read_done(&f.edits,collab)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Cancelled"))
    testing.expect_value(t,edits_cancel_prepare(&f.edits,w),Edit_Error.None)
    core.get(&f.world.transforms,first).position.y=7
    edits_cancel(&f.edits,w)
    testing.expect_value(t,core.get(&f.world.transforms,first).position.y,f32(5))
    testing.expect_value(t,len(journal_read(&f.edits,&collab)),0)
    testing.expect(t,journal_settled(&f.edits,w))
    journal_reading(&f.edits,false)
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Unread"))
    core.get(&f.world.transforms,first).position.y=8
    edits_end(&f.edits)
    testing.expect(t,edits_commit(&f.edits,w,&f.selection))
    testing.expect(t,len(f.edits.changes)==0 && len(f.edits.change_values)==0)
}

@(test)
journal_steps_hold_what_changed_whatever_the_size_of_the_world :: proc(t:^testing.T) {
    f:=new(Journal_Fixture);defer free(f)
    journal_init(f,4000);defer journal_free(f)
    w:=journal_world(f)
    // A step that makes and destroys entities keeps those indices, not the entities of the World.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Replace"))
    gone:=journal_entity(f,51)
    core.destroy(&f.world.entities,gone)
    journal_settle(&f.world,nil,nil)
    made:=core.create(&f.world.entities)
    core.add(&f.world.ids,made,{value=9001})
    core.add(&f.world.transforms,made,core.TRANSFORM_IDENTITY)
    derived:=core.create(&f.world.entities)
    core.add(&f.world.transforms,derived,core.TRANSFORM_IDENTITY)
    journal_settle(&f.world,nil,nil)
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
    testing.expect_value(t,core.get(&f.world.transforms,gone).position.x,f32(51))
    testing.expect(t,redo(&f.edits,w,&f.selection))
    testing.expect(t,!core.alive(&f.world.entities,gone) && core.alive(&f.world.entities,made) && core.has(&f.world.ids,made))
    testing.expect(t,!core.alive(&f.world.entities,derived),"what a library derived is derived again")
    testing.expect(t,journal_settled(&f.edits,w))
    // A move of a World this size compares only the row it wrote.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Move"))
    core.get(&f.world.transforms,journal_entity(f,7)).position.z=3
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
    f:=new(Journal_Fixture);defer free(f)
    failure:=Journal_Failure{owner=context.allocator}
    context.allocator={journal_allocator,&failure}
    journal_init(f,300);defer journal_free(f)
    w:=journal_world(f)
    lamp,moved,gone,parent:=journal_entity(f,3),journal_entity(f,4),journal_entity(f,5),journal_entity(f,6)
    core.disable(&f.world.lamps,gone)
    journal_settle(&f.world,nil,nil)
    edits_reset(&f.edits,w)
    // A gesture that turns, writes, removes off rows, destroys, reuses and
    // makes more entities than it reserved.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Everything"))
    testing.expect_value(t,edits_cancel_prepare(&f.edits,w,2),Edit_Error.None)
    core.disable(&f.world.lamps,lamp)
    core.get(&f.world.transforms,moved).position.y=4
    core.add(&f.world.parents,moved,{entity=parent})
    core.destroy(&f.world.entities,gone)
    journal_settle(&f.world,nil,nil)
    for _ in 0..<40 {
        e:=core.create(&f.world.entities)
        core.add(&f.world.ids,e,{value=base.Entity_Id(1000+core.entity_index(e))})
        core.add(&f.world.transforms,e,core.TRANSFORM_IDENTITY)
        core.add(&f.world.lamps,e,{power=2})
    }
    journal_settle(&f.world,nil,nil)
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
    testing.expect_value(t,core.get(&f.world.transforms,moved).position.y,f32(0))
    // Undo and redo of that gesture, committed, do not allocate either once prepared.
    testing.expect(t,edits_begin(&f.edits,&f.selection,"Everything"))
    core.disable(&f.world.lamps,lamp)
    core.destroy(&f.world.entities,gone)
    journal_settle(&f.world,nil,nil)
    for _ in 0..<40 {
        e:=core.create(&f.world.entities)
        core.add(&f.world.ids,e,{value=base.Entity_Id(1000+core.entity_index(e))})
        core.add(&f.world.transforms,e,core.TRANSFORM_IDENTITY)
    }
    journal_settle(&f.world,nil,nil)
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
