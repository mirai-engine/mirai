package editor

import "core:testing"
import "mirai:core"
import "mirai:editor/history"
import "mirai:std/base"

@(private="file")
History_Lamp :: struct {intensity:f32,range:f32}

@(private="file")
History_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    lamps:core.Table(History_Lamp),
}

@(private="file")
History_Fixture :: struct {
    world:History_World,
    using edited:Test_Session,
}

@(private="file")
AGENT :: history.Edit_Author(7)

// A World of count entities with an Id from 1, a Transform and a Lamp.
@(private="file")
history_init :: proc(t:^testing.T,f:^History_Fixture,count:int) -> bool {
    if !core.test_world_init(t,&f.world) {return false}
    for i in 0..<count {history_entity(f,base.Entity_Id(i+1))}
    core.test_world_settle(&f.world)
    test_session_open(&f.edited,history_world(f))
    return true
}

@(private="file")
history_free :: proc(f:^History_Fixture) {
    test_session_close(&f.edited)
    core.test_world_destroy(&f.world)
}

@(private="file")
history_world :: proc(f:^History_Fixture) -> core.World_Ref {return core.test_world_ref(&f.world)}

@(private="file")
history_entity :: proc(f:^History_Fixture,id:base.Entity_Id) -> core.Entity {
    e:=core.create(&f.world.entities)
    core.add(&f.world.ids,e,{value=id})
    core.add(&f.world.transforms,e,core.TRANSFORM_IDENTITY)
    core.add(&f.world.lamps,e,{intensity=1,range=1})
    return e
}

@(private="file")
history_at :: proc(f:^History_Fixture,id:base.Entity_Id) -> core.Entity {
    for value,row in f.world.ids.values {if value.value==id {return f.world.ids.entities[row]}}
    return core.NONE
}

@(private="file")
history_transform :: proc(f:^History_Fixture,id:base.Entity_Id) -> ^core.Transform {return core.edit(&f.world.transforms,history_at(f,id))}

// The Lamp of an entity, also while it is turned off; written, the row is stamped.
@(private="file")
history_lamp :: proc(f:^History_Fixture,id:base.Entity_Id) -> ^History_Lamp {
    return (^History_Lamp)(core.raw_edit(core.raw(&f.world.lamps),type_info_of(History_Lamp),history_at(f,id)))
}

// Opens a gesture of an author; history_commit records it as a step of that author.
@(private="file")
history_begin :: proc(f:^History_Fixture,author:history.Edit_Author,label:string) {
    f.edits.author=author
    history.edits_begin(&f.edits,&f.selection,label)
}

@(private="file")
history_commit :: proc(t:^testing.T,f:^History_Fixture,loc:=#caller_location) {
    core.test_world_settle(&f.world)
    history.edits_end(&f.edits)
    testing.expect(t,history.edits_commit(&f.edits,history_world(f),&f.selection),loc=loc)
    f.edits.author=history.EDIT_AUTHOR_USER
}

@(private="file")
history_move :: proc(f:^History_Fixture,author:history.Edit_Author,forward:bool) -> History_Move {
    f.edits.author=author
    defer f.edits.author=history.EDIT_AUTHOR_USER
    return history_redo(&f.s) if forward else history_undo(&f.s)
}

@(test)
undo_of_each_author_takes_back_its_own_steps_between_those_of_others :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,2) {return}
    defer history_free(f)
    history_begin(f,history.EDIT_AUTHOR_USER,"Move one")
    history_transform(f,1).position.x=1
    history_commit(t,f)
    history_begin(f,AGENT,"Move two")
    history_transform(f,2).position.x=2
    history_commit(t,f)
    // The newest step of the agent is the last one done: it goes and comes in order.
    testing.expect(t,history_move(f,AGENT,false).done)
    testing.expect(t,f.edits.cursor==1 && len(f.edits.steps)==2)
    testing.expect_value(t,history_transform(f,2).position.x,f32(0))
    testing.expect(t,history_move(f,AGENT,true).done)
    testing.expect(t,f.edits.cursor==2 && len(f.edits.steps)==2)
    history_begin(f,history.EDIT_AUTHOR_USER,"Scale one")
    history_transform(f,1).scale={2,2,2}
    history_commit(t,f)
    history_begin(f,AGENT,"Scale two")
    history_transform(f,2).scale={3,3,3}
    history_commit(t,f)
    f.edits.author=history.EDIT_AUTHOR_USER
    testing.expect_value(t,history.undo_label(&f.edits),"Scale one")
    testing.expect_value(t,history.edits_undo_count(&f.edits),2)
    // The user takes back its own steps by ids, newest first, and the agent's stay.
    move:=history_move(f,history.EDIT_AUTHOR_USER,false)
    testing.expect(t,move.done && move.kept==0 && move.label=="Scale one")
    testing.expect_value(t,history_transform(f,1).scale,[3]f32{1,1,1})
    testing.expect_value(t,history_transform(f,2).scale,[3]f32{3,3,3})
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(0))
    testing.expect_value(t,history_transform(f,2).position.x,f32(2))
    move=history_move(f,history.EDIT_AUTHOR_USER,false)
    testing.expect(t,!move.done && move.error=="","the user has nothing left to undo")
    testing.expect_value(t,history.edits_redo_count(&f.edits),2)
    // The agent takes back its newest step after the undos of the user.
    testing.expect(t,history_move(f,AGENT,false).done)
    testing.expect_value(t,history_transform(f,2).scale,[3]f32{1,1,1})
    testing.expect_value(t,history_transform(f,1).position.x,f32(0))
    // Redo of the user brings its steps again, oldest undo last.
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(1))
    testing.expect_value(t,history_transform(f,1).scale,[3]f32{1,1,1})
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect_value(t,history_transform(f,1).scale,[3]f32{2,2,2})
    testing.expect_value(t,history_transform(f,2).scale,[3]f32{1,1,1})
    testing.expect(t,!history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect_value(t,history.edits_undo_count(&f.edits),2)
    testing.expect(t,history.journal_settled(&f.edits,history_world(f)))
}

@(test)
undo_keeps_a_field_another_author_wrote_after_the_step :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,1) {return}
    defer history_free(f)
    history_begin(f,history.EDIT_AUTHOR_USER,"Move")
    history_transform(f,1).position.x=1
    history_commit(t,f)
    history_begin(f,AGENT,"Move too")
    history_transform(f,1).position.x=5
    history_commit(t,f)
    steps:=len(f.edits.steps)
    move:=history_move(f,history.EDIT_AUTHOR_USER,false)
    testing.expect(t,move.done && move.kept==1)
    testing.expect_value(t,history_transform(f,1).position.x,f32(5))
    testing.expect_value(t,len(f.edits.steps),steps)
    // Nor does the redo bring it back; the step stands again, and its undo keeps the field too.
    move=history_move(f,history.EDIT_AUTHOR_USER,true)
    testing.expect(t,move.done && move.kept==1)
    testing.expect_value(t,history_transform(f,1).position.x,f32(5))
    move=history_move(f,history.EDIT_AUTHOR_USER,false)
    testing.expect(t,move.done && move.kept==1)
    testing.expect_value(t,len(f.edits.steps),steps)
    // The agent's own step is still the last one done: it goes in order.
    testing.expect(t,history_move(f,AGENT,false).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(1))
}

@(test)
undo_restores_its_fields_and_off_state_beside_those_another_author_changed :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,1) {return}
    defer history_free(f)
    e:=history_at(f,1)
    history_begin(f,history.EDIT_AUTHOR_USER,"Move and turn off")
    history_transform(f,1).position={1,2,3}
    core.disable(&f.world.lamps,e)
    history_commit(t,f)
    history_begin(f,AGENT,"Scale and brighten")
    history_transform(f,1).scale={4,4,4}
    history_lamp(f,1).intensity=9
    history_commit(t,f)
    move:=history_move(f,history.EDIT_AUTHOR_USER,false)
    core.test_world_settle(&f.world)
    testing.expect(t,move.done && move.kept==0)
    testing.expect_value(t,history_transform(f,1).position,[3]f32{0,0,0})
    testing.expect_value(t,history_transform(f,1).scale,[3]f32{4,4,4})
    _,off,_:=core.raw_state(core.raw(&f.world.lamps),e)
    testing.expect(t,!off)
    testing.expect_value(t,history_lamp(f,1).intensity,f32(9))
    // The undo of the user is a step of its own: the agent's step goes by ids now.
    testing.expect_value(t,f.edits.steps[f.edits.cursor-1].kind,history.Edit_Kind.Undo)
    testing.expect(t,history_move(f,AGENT,false).done)
    core.test_world_settle(&f.world)
    testing.expect_value(t,history_transform(f,1).scale,[3]f32{1,1,1})
    testing.expect_value(t,history_lamp(f,1).intensity,f32(1))
    testing.expect_value(t,history_transform(f,1).position,[3]f32{0,0,0})
    _,off,_=core.raw_state(core.raw(&f.world.lamps),e)
    testing.expect(t,!off)
}

@(test)
undo_leaves_an_entity_another_author_deleted :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,2) {return}
    defer history_free(f)
    history_begin(f,history.EDIT_AUTHOR_USER,"Move")
    history_transform(f,1).position.x=1
    history_commit(t,f)
    history_begin(f,AGENT,"Delete")
    core.destroy(&f.world.entities,history_at(f,1))
    history_commit(t,f)
    move:=history_move(f,history.EDIT_AUTHOR_USER,false)
    core.test_world_settle(&f.world)
    testing.expect(t,move.done && move.kept==1)
    testing.expect(t,history_at(f,1)==core.NONE,"the user's undo does not bring back what the agent deleted")
    testing.expect_value(t,f.world.entities.alive,1)
    // The agent puts it back in order, as the user's step left it.
    testing.expect(t,history_move(f,AGENT,false).done)
    testing.expect(t,history_at(f,1)!=core.NONE)
    testing.expect_value(t,history_transform(f,1).position.x,f32(1))
    testing.expect(t,history.journal_settled(&f.edits,history_world(f)))
}

@(test)
undo_of_a_creation_keeps_the_entity_while_a_child_of_another_author_hangs_from_it :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,1) {return}
    defer history_free(f)
    history_begin(f,history.EDIT_AUTHOR_USER,"Create")
    made:=history_entity(f,10)
    history_commit(t,f)
    history_begin(f,AGENT,"Create child")
    child:=history_entity(f,11)
    core.add(&f.world.parents,child,{entity=made})
    history_commit(t,f)
    move:=history_move(f,history.EDIT_AUTHOR_USER,false)
    core.test_world_settle(&f.world)
    testing.expect(t,move.done && move.kept==1)
    testing.expect(t,core.alive(&f.world.entities,made) && core.alive(&f.world.entities,child))
    parent,_:=core.get(core.read(&f.world.parents),child)
    testing.expect_value(t,parent.entity,made)
    // Without the child, the creation goes.
    testing.expect(t,history_move(f,AGENT,false).done)
    core.test_world_settle(&f.world)
    testing.expect(t,history_at(f,11)==core.NONE)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    core.test_world_settle(&f.world)
    testing.expect(t,history_at(f,10)==core.NONE)
    testing.expect(t,history.journal_settled(&f.edits,history_world(f)))
}

@(test)
redo_of_an_author_survives_the_edits_of_others_and_a_new_edit_drops_it :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,2) {return}
    defer history_free(f)
    history_begin(f,history.EDIT_AUTHOR_USER,"Move")
    history_transform(f,1).position.x=1
    history_commit(t,f)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,f.edits.cursor==0 && len(f.edits.steps)==1)
    history_begin(f,AGENT,"Agent")
    history_transform(f,2).position.x=2
    history_commit(t,f)
    // The step undone in order stays, taken back, below the agent's.
    testing.expect(t,len(f.edits.steps)==2 && f.edits.steps[0].reverted && f.edits.steps[0].swapped)
    testing.expect_value(t,history.edits_state(&f.edits),f.edits.steps[1].state)
    f.edits.author=history.EDIT_AUTHOR_USER
    testing.expect_value(t,history.redo_label(&f.edits),"Move")
    move:=history_move(f,history.EDIT_AUTHOR_USER,true)
    testing.expect(t,move.done && move.kept==0)
    testing.expect_value(t,history_transform(f,1).position.x,f32(1))
    testing.expect_value(t,history_transform(f,2).position.x,f32(2))
    testing.expect_value(t,f.edits.steps[f.edits.cursor-1].kind,history.Edit_Kind.Redo)
    // The redo stands for the step: undone and redone in order now.
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(0))
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(1))
    // The redo of a step undone by ids, while that undo is the last step, is its undo in order.
    testing.expect(t,history_move(f,AGENT,false).done)
    testing.expect_value(t,history_transform(f,2).position.x,f32(0))
    steps:=len(f.edits.steps)
    testing.expect(t,history_move(f,AGENT,true).done)
    testing.expect_value(t,history_transform(f,2).position.x,f32(2))
    testing.expect_value(t,len(f.edits.steps),steps)
    // A new edit of the user drops what the user could redo, not what the agent can.
    testing.expect(t,history_move(f,AGENT,false).done)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    history_begin(f,history.EDIT_AUTHOR_USER,"Again")
    history_transform(f,1).position.y=3
    history_commit(t,f)
    f.edits.author=history.EDIT_AUTHOR_USER
    testing.expect_value(t,history.edits_redo_count(&f.edits),0)
    f.edits.author=AGENT
    testing.expect_value(t,history.edits_redo_count(&f.edits),1)
    f.edits.author=history.EDIT_AUTHOR_USER
    testing.expect(t,history_move(f,AGENT,true).done)
    testing.expect_value(t,history_transform(f,2).position.x,f32(2))
    testing.expect_value(t,history_transform(f,1).position.y,f32(3))
    testing.expect(t,history.journal_settled(&f.edits,history_world(f)))
}

// An author selects entities, and the end of the frame records it.
@(private="file")
history_select :: proc(f:^History_Fixture,author:history.Edit_Author,ids:..base.Entity_Id) {
    f.edits.author=author
    defer f.edits.author=history.EDIT_AUTHOR_USER
    picked:=make([dynamic]core.Entity,context.temp_allocator)
    for id in ids {append(&picked,history_at(f,id))}
    history.selection_set(&f.selection,picked[:])
    history.edits_select(&f.edits,history_world(f),&f.selection)
}

@(private="file")
history_selected :: proc(f:^History_Fixture,ids:..base.Entity_Id) -> bool {
    if len(f.selection.entities)!=len(ids) {return false}
    for id,i in ids {if f.selection.entities[i]!=history_at(f,id) {return false}}
    return true
}

@(test)
undo_and_redo_go_back_and_forth_through_each_selection :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,3) {return}
    defer history_free(f)
    history.edits_select(&f.edits,history_world(f),&f.selection)
    history_select(f,history.EDIT_AUTHOR_USER,1)
    history_select(f,history.EDIT_AUTHOR_USER,2)
    // The same selection again is no step.
    history_select(f,history.EDIT_AUTHOR_USER,2)
    testing.expect_value(t,len(f.edits.selections),2)
    testing.expect_value(t,history.undo_label(&f.edits),"Select Entity 2")
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_selected(f,1))
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_selected(f))
    testing.expect(t,!history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect(t,history_selected(f,2))
    testing.expect(t,!history_move(f,history.EDIT_AUTHOR_USER,true).done)
    // What undo and redo selected is no step either.
    history.edits_select(&f.edits,history_world(f),&f.selection)
    testing.expect_value(t,len(f.edits.selections),2)
    testing.expect_value(t,len(f.edits.steps),0)
    testing.expect_value(t,history.edits_undo_count(&f.edits),2)
}

@(test)
selections_go_back_between_the_edits_in_the_order_they_were_made :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,2) {return}
    defer history_free(f)
    history.edits_select(&f.edits,history_world(f),&f.selection)
    history_select(f,history.EDIT_AUTHOR_USER,1)
    history_begin(f,history.EDIT_AUTHOR_USER,"Move one")
    history_transform(f,1).position.x=1
    history_commit(t,f)
    history_select(f,history.EDIT_AUTHOR_USER,2)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_selected(f,1))
    testing.expect_value(t,history_transform(f,1).position.x,f32(1))
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(0))
    testing.expect(t,history_selected(f,1))
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_selected(f))
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,true).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(1))
    testing.expect_value(t,history.redo_label(&f.edits),"Select Entity 2")
    // A selection after an undo drops what the user could redo, the edit too.
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect_value(t,history_transform(f,1).position.x,f32(0))
    history_select(f,history.EDIT_AUTHOR_USER,2)
    testing.expect_value(t,history.edits_redo_count(&f.edits),0)
    testing.expect_value(t,len(f.edits.steps),0)
    testing.expect(t,history.journal_settled(&f.edits,history_world(f)))
}

@(test)
a_selection_inside_an_edit_is_part_of_its_step :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,2) {return}
    defer history_free(f)
    history.edits_select(&f.edits,history_world(f),&f.selection)
    history_select(f,history.EDIT_AUTHOR_USER,1)
    // A selection made in the frame the gesture opens goes before it.
    history.selection_set(&f.selection,{history_at(f,2)})
    history_begin(f,history.EDIT_AUTHOR_USER,"Move and select")
    history_transform(f,2).position.x=2
    history.selection_set(&f.selection,{history_at(f,1)})
    history_commit(t,f)
    history.edits_select(&f.edits,history_world(f),&f.selection)
    testing.expect_value(t,len(f.edits.selections),2)
    testing.expect_value(t,len(f.edits.steps),1)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect_value(t,history_transform(f,2).position.x,f32(0))
    testing.expect(t,history_selected(f,2))
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_selected(f,1))
}

@(test)
the_selections_of_each_author_and_what_goes_away_stay_out_of_the_undo_of_the_others :: proc(t:^testing.T) {
    f:=new(History_Fixture);defer free(f)
    if !history_init(t,f,3) {return}
    defer history_free(f)
    history.edits_select(&f.edits,history_world(f),&f.selection)
    history_select(f,history.EDIT_AUTHOR_USER,1,2)
    history_select(f,AGENT,3)
    testing.expect_value(t,history.edits_undo_count(&f.edits),1)
    testing.expect(t,history_move(f,AGENT,false).done)
    testing.expect(t,history_selected(f,1,2))
    testing.expect(t,history_move(f,AGENT,true).done)
    testing.expect(t,history_selected(f,3))
    history_select(f,history.EDIT_AUTHOR_USER,1,2)
    // An entity another editor deleted leaves the selection without a step.
    core.destroy(&f.world.entities,history_at(f,2))
    core.test_world_settle(&f.world)
    history.selection_prune(&f.selection,history_world(f))
    history.edits_select(&f.edits,history_world(f),&f.selection)
    testing.expect_value(t,len(f.edits.selections),3)
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_selected(f,3))
    testing.expect(t,history_move(f,history.EDIT_AUTHOR_USER,false).done)
    testing.expect(t,history_selected(f))
    // Another document starts without them, and its first selection is not a step.
    history.edits_reset(&f.edits,history_world(f))
    history.selection_set(&f.selection,{history_at(f,1)})
    history.edits_select(&f.edits,history_world(f),&f.selection)
    testing.expect_value(t,len(f.edits.selections),0)
}
