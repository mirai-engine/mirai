package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import "mirai:std/base"

@(private="file")
Journal_Fixture :: struct {
    using journal:history.Test_Journal,
    document:Document,
    s:Session,
}

@(private="file")
journal_init :: proc(t:^testing.T,f:^Journal_Fixture,count:int) -> bool {
    if !history.test_journal_init(t,&f.journal,count) {return false}
    f.s=Session{info=test_world_info(&f.world),edit_world=&f.world,edits=&f.edits,selection=&f.selection,document=&f.document}
    return true
}

@(private="file")
Journal_End :: struct {f:Journal_Fixture,st:^Collab_State}

@(private="file")
journal_end_open :: proc(t:^testing.T,end:^Journal_End) -> bool {
    if !journal_init(t,&end.f,12) {return false}
    end.st=new(Collab_State)
    end.st.role,end.st.phase=.Guest,.Joined
    collab_tables_build(&end.f.s,end.st)
    collab_journal_reset(&end.f.s,end.st)
    return true
}

@(private="file")
journal_end_close :: proc(end:^Journal_End) {
    if end.st!=nil {
        for &peer in end.st.peers {
            for message in peer.out {delete(message)}
            delete(peer.out)
        }
        collab_tables_free(end.st)
        free(end.st)
    }
    history.test_journal_free(&end.f.journal)
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
    if !journal_end_open(t,a) {return}
    defer journal_end_close(a)
    if !journal_end_open(t,b) {return}
    defer journal_end_close(b)
    wa,wb:=test_world_ref(&a.f.world),test_world_ref(&b.f.world)
    at :: proc(end:^Journal_End,id:base.Entity_Id) -> core.Entity {return history.test_journal_entity(&end.f.journal,id)}
    // An edit not committed yet travels live; cancelled, its row goes back too.
    testing.expect(t,history.edits_begin(&a.f.edits,&a.f.selection,"Drag"))
    testing.expect_value(t,history.edits_cancel_prepare(&a.f.edits,wa),history.Edit_Error.None)
    core.edit(&a.f.world.transforms,at(a,1)).position.y=3
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect_value(t,core.at(&b.f.world.transforms,core.row_of(&b.f.world.transforms,at(b,1))).position.y,f32(3))
    testing.expect_value(t,len(b.f.edits.steps),0)
    testing.expect_value(t,journal_end_send(b,a),0)
    history.edits_cancel(&a.f.edits,wa)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect_value(t,core.at(&b.f.world.transforms,core.row_of(&b.f.world.transforms,at(b,1))).position.y,f32(0))
    testing.expect_value(t,journal_end_send(a,b),0)
    // A step that turns a component off, gives a parent and destroys an
    // entity; its undo turns it on and brings the entity back with its Id.
    testing.expect(t,history.edits_begin(&a.f.edits,&a.f.selection,"Step"))
    core.disable(&a.f.world.lamps,at(a,2))
    core.add(&a.f.world.parents,at(a,4),{entity=at(a,3)})
    core.destroy(&a.f.world.entities,at(a,5))
    test_world_settle(&a.f.world)
    history.edits_end(&a.f.edits)
    testing.expect(t,history.edits_commit(&a.f.edits,wa,&a.f.selection))
    testing.expect_value(t,journal_end_send(a,b),1)
    _,off,_:=core.raw_state(core.raw(&b.f.world.lamps),at(b,2))
    testing.expect(t,off)
    parent,_:=core.get(&b.f.world.parents,at(b,4))
    testing.expect_value(t,parent.entity,at(b,3))
    testing.expect(t,at(b,5)==core.NONE)
    testing.expect_value(t,journal_end_send(b,a),0)
    testing.expect(t,history.undo(&a.f.edits,wa,&a.f.selection))
    testing.expect_value(t,journal_end_send(a,b),1)
    _,off,_=core.raw_state(core.raw(&b.f.world.lamps),at(b,2))
    testing.expect(t,!off && !core.has(&b.f.world.parents,at(b,4)))
    testing.expect(t,at(b,5)!=core.NONE && core.has(&b.f.world.transforms,at(b,5)))
    testing.expect_value(t,core.at(&b.f.world.transforms,core.row_of(&b.f.world.transforms,at(b,5))).position.x,f32(5))
    testing.expect(t,history.journal_settled(&b.f.edits,wb) && len(b.f.edits.steps)==0)
    testing.expect_value(t,journal_end_send(b,a),0)
    // What arrives in the middle of an edit of its own stays out of its step.
    testing.expect(t,history.edits_begin(&b.f.edits,&b.f.selection,"Own"))
    core.edit(&b.f.world.transforms,at(b,7)).position.z=1
    core.edit(&a.f.world.transforms,at(a,8)).position.z=2
    testing.expect_value(t,journal_end_send(a,b),1)
    history.edits_end(&b.f.edits)
    testing.expect(t,history.edits_commit(&b.f.edits,wb,&b.f.selection))
    testing.expect_value(t,len(b.f.edits.steps[0].tables),1)
    testing.expect_value(t,b.f.edits.steps[0].tables[0].entities[0],at(b,7))
    testing.expect_value(t,journal_end_send(b,a),1)
    testing.expect_value(t,core.at(&a.f.world.transforms,core.row_of(&a.f.world.transforms,at(a,7))).position.z,f32(1))
}

// Each end undoes its own steps: what the other end wrote after them stays.
@(test)
undo_at_each_end_keeps_what_the_other_end_wrote_since :: proc(t:^testing.T) {
    a,b:=new(Journal_End),new(Journal_End)
    defer {free(a);free(b)}
    if !journal_end_open(t,a) {return}
    defer journal_end_close(a)
    if !journal_end_open(t,b) {return}
    defer journal_end_close(b)
    at :: proc(end:^Journal_End,id:base.Entity_Id) -> core.Entity {return history.test_journal_entity(&end.f.journal,id)}
    position :: proc(end:^Journal_End,id:base.Entity_Id) -> [3]f32 {return core.at(&end.f.world.transforms,core.row_of(&end.f.world.transforms,at(end,id))).position}
    commit :: proc(t:^testing.T,end:^Journal_End,loc:=#caller_location) {
        test_world_settle(&end.f.world)
        history.edits_end(&end.f.edits)
        testing.expect(t,history.edits_commit(&end.f.edits,test_world_ref(&end.f.world),&end.f.selection),loc=loc)
    }
    // The same field: A's undo keeps what B wrote after it, and tells nothing.
    testing.expect(t,history.edits_begin(&a.f.edits,&a.f.selection,"A moves"))
    core.edit(&a.f.world.transforms,at(a,1)).position.y=3
    commit(t,a)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,history.edits_begin(&b.f.edits,&b.f.selection,"B moves"))
    core.edit(&b.f.world.transforms,at(b,1)).position.y=4
    commit(t,b)
    testing.expect_value(t,journal_end_send(b,a),1)
    move:=history_undo(&a.f.s)
    testing.expect(t,move.done && move.kept==1)
    testing.expect_value(t,position(a,1).y,f32(4))
    testing.expect_value(t,journal_end_send(a,b),0)
    // Another entity: A's undo goes in order and B's row stays.
    testing.expect(t,history.edits_begin(&a.f.edits,&a.f.selection,"A lifts"))
    core.edit(&a.f.world.transforms,at(a,2)).position.z=1
    commit(t,a)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,history.edits_begin(&b.f.edits,&b.f.selection,"B lifts"))
    core.edit(&b.f.world.transforms,at(b,3)).position.z=2
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
    testing.expect(t,history.edits_begin(&a.f.edits,&a.f.selection,"A makes"))
    made:=core.create(&a.f.world.entities)
    core.add(&a.f.world.ids,made,{value=100})
    core.add(&a.f.world.transforms,made,core.TRANSFORM_IDENTITY)
    commit(t,a)
    testing.expect_value(t,journal_end_send(a,b),1)
    testing.expect(t,history.edits_begin(&b.f.edits,&b.f.selection,"B hangs"))
    child:=core.create(&b.f.world.entities)
    core.add(&b.f.world.ids,child,{value=101})
    core.add(&b.f.world.transforms,child,core.TRANSFORM_IDENTITY)
    core.add(&b.f.world.parents,child,{entity=at(b,100)})
    commit(t,b)
    testing.expect_value(t,journal_end_send(b,a),1)
    parent,_:=core.get(&a.f.world.parents,at(a,101))
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
    testing.expect(t,history.journal_settled(&a.f.edits,test_world_ref(&a.f.world)) && history.journal_settled(&b.f.edits,test_world_ref(&b.f.world)))
}

// A session of several ends, the host first, each with its document: what a
// guest edits goes to the host, which applies it and sends it to every
// guest, the sender included.
@(private="file")
journal_session_open :: proc(t:^testing.T,ends:[]^Journal_End) -> bool {
    for end,i in ends {
        if !journal_end_open(t,end) {return false}
        end.st.self=u8(i)
        if i>0 {continue}
        end.st.role=.Host
        for &peer in end.st.peers[:len(ends)] {peer.used,peer.joined=true,true}
    }
    return true
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
    local:=core.edit(&end.f.world.transforms,history.test_journal_entity(&end.f.journal,id))
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
        local,_:=core.get(&end.f.world.transforms,history.test_journal_entity(&end.f.journal,id))
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
    opened:=journal_session_open(t,ends[:])
    defer for end in ends {journal_end_close(end)}
    if !opened {return}
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
            testing.expect(t,history.edits_begin(&end.f.edits,&end.f.selection,c.name))
            journal_field_write(end,id,change.field,change.value)
            history.edits_end(&end.f.edits)
            testing.expect(t,history.edits_commit(&end.f.edits,test_world_ref(&end.f.world),&end.f.selection),c.name)
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
        testing.expect(t,history.edits_begin(&guest.f.edits,&guest.f.selection,"Twice"))
        journal_field_write(guest,7,.Scale,value)
        history.edits_end(&guest.f.edits)
        testing.expect(t,history.edits_commit(&guest.f.edits,test_world_ref(&guest.f.world),&guest.f.selection))
        if value==5 {journal_session_up(ends[:],1)}
    }
    journal_session_down(ends[:])
    testing.expect_value(t,core.at(&guest.f.world.transforms,core.row_of(&guest.f.world.transforms,history.test_journal_entity(&guest.f.journal,7))).scale.x,f32(8))
    journal_session_sync(ends[:],1)
    journal_session_expect(t,ends[:],7,{.Position=7,.Rotation=1,.Scale=8},"two edits in a row")
    for end in ends {testing.expect(t,history.journal_settled(&end.f.edits,test_world_ref(&end.f.world)))}
}

// A gesture one end leaves open tells its field as it goes; a field of the
// same row another end changes meanwhile stays, at every end and in the
// row of the gesture, whose step holds its own field alone.
@(test)
a_gesture_left_open_keeps_what_another_end_writes_to_another_field :: proc(t:^testing.T) {
    for cancel in ([2]bool{false,true}) {
        ends:=[3]^Journal_End{new(Journal_End),new(Journal_End),new(Journal_End)}
        defer for end in ends {free(end)}
        opened:=journal_session_open(t,ends[:])
        defer for end in ends {journal_end_close(end)}
        if !opened {return}
        dragging,other:=ends[1],ends[2]
        w:=test_world_ref(&dragging.f.world)
        testing.expect(t,history.edits_begin(&dragging.f.edits,&dragging.f.selection,"Drag"))
        testing.expect_value(t,history.edits_cancel_prepare(&dragging.f.edits,w),history.Edit_Error.None)
        journal_field_write(dragging,1,.Position,5)
        testing.expect(t,history.edits_begin(&other.f.edits,&other.f.selection,"Scale"))
        journal_field_write(other,1,.Scale,3)
        history.edits_end(&other.f.edits)
        testing.expect(t,history.edits_commit(&other.f.edits,test_world_ref(&other.f.world),&other.f.selection))
        journal_session_sync(ends[:],1,2)
        journal_session_expect(t,ends[:],1,{.Position=5,.Rotation=1,.Scale=3},"both fields")
        // The drag goes on: what arrived of the other field is not its edit.
        journal_field_write(dragging,1,.Position,6)
        testing.expect_value(t,journal_session_sync(ends[:],1),1)
        journal_session_expect(t,ends[:],1,{.Position=6,.Rotation=1,.Scale=3},"the drag goes on")
        testing.expect_value(t,journal_session_sync(ends[:],1,2),0)
        if cancel {
            history.edits_cancel(&dragging.f.edits,w)
            journal_session_sync(ends[:],1)
            journal_session_expect(t,ends[:],1,{.Position=1,.Rotation=1,.Scale=3},"the drag cancelled")
            testing.expect_value(t,len(dragging.f.edits.steps),0)
            continue
        }
        history.edits_end(&dragging.f.edits)
        testing.expect(t,history.edits_commit(&dragging.f.edits,w,&dragging.f.selection))
        testing.expect_value(t,journal_session_sync(ends[:],1),0)
        testing.expect(t,history_undo(&dragging.f.s).done)
        journal_session_sync(ends[:],1)
        journal_session_expect(t,ends[:],1,{.Position=1,.Rotation=1,.Scale=3},"the drag undone")
        testing.expect(t,history_undo(&other.f.s).done)
        journal_session_sync(ends[:],2)
        journal_session_expect(t,ends[:],1,{.Position=1,.Rotation=1,.Scale=1},"the scale undone")
    }
}
