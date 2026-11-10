package editor

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
    s:Session,
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
    f.s=Session{info=&f.info,edit_world=w,edits=&f.edits,selection=&f.selection}
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
    journal_read_done(&f.edits,collab)
    testing.expect_value(t,len(f.edits.changes),0)
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
    testing.expect_value(t,len(f.edits.changes),0)
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
// other from the journal, as Sets, Turns and Removes, and what arrives is not
// sent back.
@(private="file")
Journal_End :: struct {f:Journal_Fixture,st:^Collab_State}

@(private="file")
journal_end_open :: proc(end:^Journal_End) {
    journal_init(&end.f,12)
    end.st=new(Collab_State)
    end.st.role,end.st.phase=.Guest,.Joined
    collab_tables_build(&end.f.s,end.st)
    collab_journal_reset(&end.f.s,end.st)
}

@(private="file")
journal_end_close :: proc(end:^Journal_End) {
    for message in end.st.peers[0].out {delete(message)}
    delete(end.st.peers[0].out)
    collab_tables_free(end.st)
    free(end.st)
    journal_free(&end.f)
}

// What one end sends, applied by the other; how many messages went.
@(private="file")
journal_end_send :: proc(from,to:^Journal_End) -> int {
    collab_edits_send(&from.f.s,from.st)
    out:=&from.st.peers[0].out
    sent:=len(out)
    for message in out {
        collab_edit_apply(&to.f.s,to.st,message)
        delete(message)
    }
    clear(out)
    return sent
}

@(test)
collaboration_reads_the_journal_and_does_not_echo_what_it_applies :: proc(t:^testing.T) {
    a,b:=new(Journal_End),new(Journal_End)
    defer {free(a);free(b)}
    journal_end_open(a);defer journal_end_close(a)
    journal_end_open(b);defer journal_end_close(b)
    wa,wb:=journal_world(&a.f),journal_world(&b.f)
    at :: proc(end:^Journal_End,id:base.Entity_Id) -> core.Entity {return journal_entity(&end.f,id)}
    // An edit not committed yet travels live; cancelled, its row goes back too.
    testing.expect(t,edits_begin(&a.f.edits,&a.f.selection,"Drag"))
    testing.expect_value(t,edits_cancel_prepare(&a.f.edits,wa),Edit_Error.None)
    core.get(&a.f.world.transforms,at(a,1)).position.y=3
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect_value(t,core.get(&b.f.world.transforms,at(b,1)).position.y,f32(3))
    testing.expect_value(t,len(b.f.edits.steps),0)
    testing.expect_value(t,journal_end_send(b,a),0)
    edits_cancel(&a.f.edits,wa)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect_value(t,core.get(&b.f.world.transforms,at(b,1)).position.y,f32(0))
    testing.expect_value(t,journal_end_send(a,b),0)
    // A step that turns a component off, gives a parent and destroys an
    // entity; its undo turns it on and brings the entity back with its Id.
    testing.expect(t,edits_begin(&a.f.edits,&a.f.selection,"Step"))
    core.disable(&a.f.world.lamps,at(a,2))
    core.add(&a.f.world.parents,at(a,4),{entity=at(a,3)})
    core.destroy(&a.f.world.entities,at(a,5))
    journal_settle(&a.f.world,nil,nil)
    edits_end(&a.f.edits)
    testing.expect(t,edits_commit(&a.f.edits,wa,&a.f.selection))
    testing.expect_value(t,journal_end_send(a,b),1)
    _,off,_:=core.raw_state(core.raw(&b.f.world.lamps),at(b,2))
    testing.expect(t,off)
    parent,_:=core.get(core.read(&b.f.world.parents),at(b,4))
    testing.expect_value(t,parent.entity,at(b,3))
    testing.expect(t,at(b,5)==core.NONE)
    testing.expect_value(t,journal_end_send(b,a),0)
    testing.expect(t,undo(&a.f.edits,wa,&a.f.selection))
    testing.expect_value(t,journal_end_send(a,b),1)
    _,off,_=core.raw_state(core.raw(&b.f.world.lamps),at(b,2))
    testing.expect(t,!off && !core.has(&b.f.world.parents,at(b,4)))
    testing.expect(t,at(b,5)!=core.NONE && core.has(&b.f.world.transforms,at(b,5)))
    testing.expect_value(t,core.get(&b.f.world.transforms,at(b,5)).position.x,f32(5))
    testing.expect(t,journal_settled(&b.f.edits,wb) && len(b.f.edits.steps)==0)
    testing.expect_value(t,journal_end_send(b,a),0)
    // What arrives in the middle of an edit of its own stays out of its step.
    testing.expect(t,edits_begin(&b.f.edits,&b.f.selection,"Own"))
    core.get(&b.f.world.transforms,at(b,7)).position.z=1
    core.get(&a.f.world.transforms,at(a,8)).position.z=2
    testing.expect_value(t,journal_end_send(a,b),1)
    edits_end(&b.f.edits)
    testing.expect(t,edits_commit(&b.f.edits,wb,&b.f.selection))
    testing.expect_value(t,len(b.f.edits.steps[0].tables),1)
    testing.expect_value(t,b.f.edits.steps[0].tables[0].entities[0],at(b,7))
    testing.expect_value(t,journal_end_send(b,a),1)
    testing.expect_value(t,core.get(&a.f.world.transforms,at(a,7)).position.z,f32(1))
}

// Each end undoes its own steps: what the other end wrote after them stays.
@(test)
undo_at_each_end_keeps_what_the_other_end_wrote_since :: proc(t:^testing.T) {
    a,b:=new(Journal_End),new(Journal_End)
    defer {free(a);free(b)}
    journal_end_open(a);defer journal_end_close(a)
    journal_end_open(b);defer journal_end_close(b)
    at :: proc(end:^Journal_End,id:base.Entity_Id) -> core.Entity {return journal_entity(&end.f,id)}
    position :: proc(end:^Journal_End,id:base.Entity_Id) -> [3]f32 {return core.get(&end.f.world.transforms,at(end,id)).position}
    commit :: proc(t:^testing.T,end:^Journal_End,loc:=#caller_location) {
        journal_settle(&end.f.world,nil,nil)
        edits_end(&end.f.edits)
        testing.expect(t,edits_commit(&end.f.edits,journal_world(&end.f),&end.f.selection),loc=loc)
    }
    // The same field: A's undo keeps what B wrote after it, and tells nothing.
    testing.expect(t,edits_begin(&a.f.edits,&a.f.selection,"A moves"))
    core.get(&a.f.world.transforms,at(a,1)).position.y=3
    commit(t,a)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,edits_begin(&b.f.edits,&b.f.selection,"B moves"))
    core.get(&b.f.world.transforms,at(b,1)).position.y=4
    commit(t,b)
    testing.expect_value(t,journal_end_send(b,a),1)
    move:=history_undo(&a.f.s)
    testing.expect(t,move.done && move.kept==1)
    testing.expect_value(t,position(a,1).y,f32(4))
    testing.expect_value(t,journal_end_send(a,b),0)
    // Another entity: A's undo goes in order and B's row stays.
    testing.expect(t,edits_begin(&a.f.edits,&a.f.selection,"A lifts"))
    core.get(&a.f.world.transforms,at(a,2)).position.z=1
    commit(t,a)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,edits_begin(&b.f.edits,&b.f.selection,"B lifts"))
    core.get(&b.f.world.transforms,at(b,3)).position.z=2
    commit(t,b)
    testing.expect_value(t,journal_end_send(b,a),1)
    cursor:=a.f.edits.cursor
    testing.expect(t,history_undo(&a.f.s).done)
    testing.expect_value(t,a.f.edits.cursor,cursor-1)
    testing.expect(t,position(a,2).z==0 && position(a,3).z==2)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,position(b,2).z==0 && position(b,3).z==2)
    // B's undo of its own step reaches A.
    testing.expect(t,history_undo(&b.f.s).done)
    testing.expect_value(t,journal_end_send(b,a),1)
    testing.expect(t,position(a,3).z==0 && position(b,3).z==0)
    // An entity A made stays at A's undo while a child B made hangs from it.
    testing.expect(t,edits_begin(&a.f.edits,&a.f.selection,"A makes"))
    made:=core.create(&a.f.world.entities)
    core.add(&a.f.world.ids,made,{value=100})
    core.add(&a.f.world.transforms,made,core.TRANSFORM_IDENTITY)
    commit(t,a)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,edits_begin(&b.f.edits,&b.f.selection,"B hangs"))
    child:=core.create(&b.f.world.entities)
    core.add(&b.f.world.ids,child,{value=101})
    core.add(&b.f.world.transforms,child,core.TRANSFORM_IDENTITY)
    core.add(&b.f.world.parents,child,{entity=at(b,100)})
    commit(t,b)
    testing.expect_value(t,journal_end_send(b,a),1)
    parent,_:=core.get(core.read(&a.f.world.parents),at(a,101))
    testing.expect_value(t,parent.entity,at(a,100))
    move=history_undo(&a.f.s)
    testing.expect(t,move.done && move.kept==1)
    testing.expect(t,at(a,100)!=core.NONE && at(a,101)!=core.NONE)
    testing.expect_value(t,journal_end_send(a,b),0)
    // Once B takes its child back, A's undo takes the entity.
    testing.expect(t,history_undo(&b.f.s).done)
    testing.expect_value(t,journal_end_send(b,a),1)
    testing.expect(t,at(a,101)==core.NONE)
    testing.expect(t,history_redo(&a.f.s).done && history_undo(&a.f.s).done)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,at(a,100)==core.NONE && at(b,100)==core.NONE)
    testing.expect(t,journal_settled(&a.f.edits,journal_world(&a.f)) && journal_settled(&b.f.edits,journal_world(&b.f)))
}
