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
    document:Document,
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
    f.info={entities=offset_of(Journal_World,entities),tables=f.tables[:],settle=journal_settle}
    for i in 0..<count {
        e:=core.create(&w.entities)
        if i%10!=9 {core.add(&w.ids,e,{value=base.Entity_Id(i+1)})}
        core.add(&w.transforms,e,core.Transform{{f32(i+1),0,0},1,{1,1,1}})
        core.add(&w.lamps,e,{power=1,glow=f32(i)})
    }
    journal_settle(w,nil,nil)
    f.s=Session{info=&f.info,edit_world=w,edits=&f.edits,selection=&f.selection,document=&f.document}
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
    for &peer in end.st.peers {
        for message in peer.out {delete(message)}
        delete(peer.out)
    }
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

// A session of several ends, the host first, each with its document: what a
// guest edits goes to the host, which applies it and sends it to every
// guest, the sender included.
@(private="file")
journal_session_open :: proc(ends:[]^Journal_End) {
    for end,i in ends {
        journal_end_open(end)
        end.st.self=u8(i)
        if i>0 {continue}
        end.st.role=.Host
        for &peer in end.st.peers[:len(ends)] {peer.used,peer.joined=true,true}
    }
}

// What the ends of order edited reaches the host in that order (0: the host
// tells its own then; it tells it anyway before it applies what arrives).
@(private="file")
journal_session_up :: proc(ends:[]^Journal_End,order:..int) {
    host:=ends[0]
    for from in order {
        if from==0 {
            collab_edits_send(&host.f.s,host.st)
            continue
        }
        guest:=ends[from]
        collab_edits_send(&guest.f.s,guest.st)
        out:=&guest.st.peers[0].out
        for message in out {
            collab_receive(&host.f.s,host.st,from,message,0)
            delete(message)
        }
        clear(out)
    }
    collab_edits_send(&host.f.s,host.st)
}

// Every guest takes what the host sent it.
@(private="file")
journal_session_down :: proc(ends:[]^Journal_End) {
    host:=ends[0]
    for end,i in ends[1:] {
        out:=&host.st.peers[i+1].out
        for message in out {
            collab_receive(&end.f.s,end.st,-1,message,0)
            delete(message)
        }
        clear(out)
    }
}

// Both ways; how many messages the ends sent of their own.
@(private="file")
journal_session_sync :: proc(ends:[]^Journal_End,order:..int) -> (sent:int) {
    for end in ends {sent-=int(end.st.sent_edits)}
    journal_session_up(ends,..order)
    journal_session_down(ends)
    for end in ends {sent+=int(end.st.sent_edits)}
    return
}

@(private="file")
Journal_Field :: enum u8 {Position,Rotation,Scale}

// A field of the Transform of an entity, written whole from one number.
@(private="file")
journal_field_write :: proc(end:^Journal_End,id:base.Entity_Id,field:Journal_Field,value:f32) {
    local:=core.get(&end.f.world.transforms,journal_entity(&end.f,id))
    switch field {
    case .Position: local.position={value,value,value}
    case .Rotation: local.rotation=quaternion(w=value,x=0,y=0,z=0)
    case .Scale:    local.scale={value,value,value}
    }
}

// The same three numbers of the Transform every end has of an entity.
@(private="file")
journal_session_expect :: proc(t:^testing.T,ends:[]^Journal_End,id:base.Entity_Id,want:[Journal_Field]f32,what:string,loc:=#caller_location) {
    for end,i in ends {
        local:=core.get(&end.f.world.transforms,journal_entity(&end.f,id))
        got:=[Journal_Field]f32{.Position=local.position.x,.Rotation=real(local.rotation),.Scale=local.scale.x}
        testing.expectf(t,got==want,"%s, end %d: %v, not %v",what,i,got,want,loc=loc)
    }
}

// Two ends that change different fields of one row both keep theirs at every
// end; a field both changed is the one the host took last. Then one of them
// undoes its step: its field goes back and what the others wrote stays, also
// in the field it wrote when another wrote it afterwards.
@(test)
fields_changed_at_several_ends_stay_and_a_field_two_changed_follows_the_host :: proc(t:^testing.T) {
    ends:=[3]^Journal_End{new(Journal_End),new(Journal_End),new(Journal_End)}
    defer for end in ends {free(end)}
    journal_session_open(ends[:])
    defer for end in ends {journal_end_close(end)}
    Change :: struct {end:int,field:Journal_Field,value:f32}
    // Each case edits the entity of its place, whose position starts at its id.
    cases:=[?]struct {
        name:string,
        changes:[]Change,
        order:[]int, // in which what the guests edited reaches the host
        want:[Journal_Field]f32,
        undoes,kept:int,
        after:[Journal_Field]f32,
    }{
        {"two guests, a field each",{{1,.Position,5},{2,.Scale,3}},{1,2},{.Position=5,.Rotation=1,.Scale=3},1,0,{.Position=1,.Rotation=1,.Scale=3}},
        {"the host and a guest, a field each",{{0,.Rotation,0.5},{1,.Scale,4}},{1},{.Position=2,.Rotation=0.5,.Scale=4},0,0,{.Position=2,.Rotation=1,.Scale=4}},
        {"three ends, a field each",{{0,.Position,7},{1,.Rotation,0.25},{2,.Scale,2}},{2,1},{.Position=7,.Rotation=0.25,.Scale=2},2,0,{.Position=7,.Rotation=0.25,.Scale=1}},
        {"two guests, one field: the second the host took",{{1,.Position,5},{2,.Position,6}},{1,2},{.Position=6,.Rotation=1,.Scale=1},1,1,{.Position=6,.Rotation=1,.Scale=1}},
        {"two guests, one field, the other order",{{1,.Position,8},{2,.Position,9}},{2,1},{.Position=8,.Rotation=1,.Scale=1},1,0,{.Position=5,.Rotation=1,.Scale=1}},
        {"the host and a guest, one field: the guest's reached the host after its own",{{0,.Scale,2},{1,.Scale,3}},{1},{.Position=6,.Rotation=1,.Scale=3},0,1,{.Position=6,.Rotation=1,.Scale=3}},
    }
    for c,at in cases {
        id:=base.Entity_Id(at+1)
        for change in c.changes {
            end:=ends[change.end]
            testing.expect(t,edits_begin(&end.f.edits,&end.f.selection,c.name))
            journal_field_write(end,id,change.field,change.value)
            edits_end(&end.f.edits)
            testing.expect(t,edits_commit(&end.f.edits,journal_world(&end.f),&end.f.selection),c.name)
        }
        journal_session_sync(ends[:],..c.order)
        journal_session_expect(t,ends[:],id,c.want,c.name)
        testing.expectf(t,journal_session_sync(ends[:],1,2)==0,"%s: what arrived is not told again",c.name)
        move:=history_undo(&ends[c.undoes].f.s)
        testing.expectf(t,move.done && move.kept==c.kept,"%s: undo kept %d",c.name,move.kept)
        journal_session_sync(ends[:],c.undoes)
        journal_session_expect(t,ends[:],id,c.after,c.name)
    }
    // An edit that comes back from the host to the end that made it does not
    // take that end back to it: it has made another since.
    guest:=ends[1]
    for value in ([2]f32{5,8}) {
        testing.expect(t,edits_begin(&guest.f.edits,&guest.f.selection,"Twice"))
        journal_field_write(guest,7,.Scale,value)
        edits_end(&guest.f.edits)
        testing.expect(t,edits_commit(&guest.f.edits,journal_world(&guest.f),&guest.f.selection))
        if value==5 {journal_session_up(ends[:],1)}
    }
    journal_session_down(ends[:])
    testing.expect_value(t,core.get(&guest.f.world.transforms,journal_entity(&guest.f,7)).scale.x,f32(8))
    journal_session_sync(ends[:],1)
    journal_session_expect(t,ends[:],7,{.Position=7,.Rotation=1,.Scale=8},"two edits in a row")
    for end in ends {testing.expect(t,journal_settled(&end.f.edits,journal_world(&end.f)))}
}

// A gesture one end leaves open tells its field as it goes; a field of the
// same row another end changes meanwhile stays, at every end and in the
// row of the gesture, whose step holds its own field alone.
@(test)
a_gesture_left_open_keeps_what_another_end_writes_to_another_field :: proc(t:^testing.T) {
    for cancel in ([2]bool{false,true}) {
        ends:=[3]^Journal_End{new(Journal_End),new(Journal_End),new(Journal_End)}
        defer for end in ends {free(end)}
        journal_session_open(ends[:])
        defer for end in ends {journal_end_close(end)}
        dragging,other:=ends[1],ends[2]
        w:=journal_world(&dragging.f)
        testing.expect(t,edits_begin(&dragging.f.edits,&dragging.f.selection,"Drag"))
        testing.expect_value(t,edits_cancel_prepare(&dragging.f.edits,w),Edit_Error.None)
        journal_field_write(dragging,1,.Position,5)
        testing.expect(t,edits_begin(&other.f.edits,&other.f.selection,"Scale"))
        journal_field_write(other,1,.Scale,3)
        edits_end(&other.f.edits)
        testing.expect(t,edits_commit(&other.f.edits,journal_world(&other.f),&other.f.selection))
        journal_session_sync(ends[:],1,2)
        journal_session_expect(t,ends[:],1,{.Position=5,.Rotation=1,.Scale=3},"both fields")
        // The drag goes on: what arrived of the other field is not its edit.
        journal_field_write(dragging,1,.Position,6)
        testing.expect_value(t,journal_session_sync(ends[:],1),1)
        journal_session_expect(t,ends[:],1,{.Position=6,.Rotation=1,.Scale=3},"the drag goes on")
        testing.expect_value(t,journal_session_sync(ends[:],1,2),0)
        if cancel {
            edits_cancel(&dragging.f.edits,w)
            journal_session_sync(ends[:],1)
            journal_session_expect(t,ends[:],1,{.Position=1,.Rotation=1,.Scale=3},"the drag cancelled")
            testing.expect_value(t,len(dragging.f.edits.steps),0)
            continue
        }
        edits_end(&dragging.f.edits)
        testing.expect(t,edits_commit(&dragging.f.edits,w,&dragging.f.selection))
        testing.expect_value(t,journal_session_sync(ends[:],1),0)
        testing.expect(t,history_undo(&dragging.f.s).done)
        journal_session_sync(ends[:],1)
        journal_session_expect(t,ends[:],1,{.Position=1,.Rotation=1,.Scale=3},"the drag undone")
        testing.expect(t,history_undo(&other.f.s).done)
        journal_session_sync(ends[:],2)
        journal_session_expect(t,ends[:],1,{.Position=1,.Rotation=1,.Scale=1},"the scale undone")
    }
}
