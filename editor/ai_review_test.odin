package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:math/linalg"
import "mirai:editor/history"
import mm "mirai:std/math"
import "mirai:editor/api"
import "mirai:std/serial"
import "mirai:core"
import "mirai:project"
import "mirai:std/base"

@(private="file")
Ai_Review_Test_Lamp :: struct {intensity:f32}

@(private="file")
Ai_Review_Test_World :: struct {
    using world:core.Test_World,
    using scene_tables:Test_Scene,
    lamps:core.Table(Ai_Review_Test_Lamp) `mirai:"name=Lamp"`,
}

@(private="file")
Ai_Review_Fixture :: struct {
    w:Ai_Review_Test_World,
    using edited:Test_Session,
    ai:Ai,
}

@(private="file")
ai_review_test_open :: proc(t:^testing.T) -> ^Ai_Review_Fixture {
    f:=new(Ai_Review_Fixture)
    if !core.test_world_init(t,&f.w) {free(f);return nil}
    test_session_open(&f.edited,core.test_world_ref(&f.w))
    f.s.ai=&f.ai
    return f
}

@(private="file")
ai_review_test_close :: proc(f:^Ai_Review_Fixture) {
    delete(f.ai.marks)
    test_session_close(&f.edited)
    core.test_world_destroy(&f.w)
    free(f)
}

@(private="file")
ai_review_test_entity :: proc(w:^Ai_Review_Test_World,id:base.Entity_Id) -> core.Entity {
    e:=core.create(&w.entities)
    core.add(&w.ids,e,core.Id{id})
    core.add(&w.transforms,e,core.TRANSFORM_IDENTITY)
    return e
}

@(private="file")
ai_review_test_transform :: proc(w:^Ai_Review_Test_World,e:core.Entity) -> core.Transform {
    value,_:=core.get(core.read(&w.transforms),e)
    return value
}

@(private="file")
ai_review_test_parent :: proc(w:^Ai_Review_Test_World,e:core.Entity) -> core.Parent {
    value,_:=core.get(core.read(&w.parents),e)
    return value
}

@(private="file")
ai_review_test_id :: proc(w:^Ai_Review_Test_World,id:base.Entity_Id) -> core.Entity {
    for value,i in w.ids.values {if value.value==id {return w.ids.entities[i]}}
    return core.NONE
}

@(test)
ai_review_attributes_concurrent_entities_and_fields_and_reverts_as_one_undo :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    first:=ai_review_test_entity(&f.w,11)
    second:=ai_review_test_entity(&f.w,22)
    core.world_settle(ref)
    history.edits_reset(&f.edits,ref)
    a,b:=&f.ai.tasks[0],&f.ai.tasks[1]
    a.id,b.id=1,2;a.world,b.world=&f.w,&f.w
    defer ai_review_free(&a.review);defer ai_review_free(&b.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"A position")
    core.edit(&f.w.transforms,first).position={1,2,3}
    history.edits_commit(&f.edits,ref,&f.selection)
    ai_review_record(&f.s,a,before)
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"B scale and other entity")
    core.edit(&f.w.transforms,first).scale={2,2,2}
    core.edit(&f.w.transforms,second).position={7,8,9}
    history.edits_commit(&f.edits,ref,&f.selection)
    ai_review_record(&f.s,b,before)
    testing.expect_value(t,len(a.review.changed_ids),1)
    testing.expect_value(t,a.review.changed_ids[0],base.Entity_Id(11))
    testing.expect_value(t,len(b.review.changed_ids),2)
    testing.expect(t,a.review.pending && b.review.pending)
    a.state,b.state=.Done,.Done
    undo_before:=f.edits.cursor
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,a),"")
    testing.expect_value(t,f.edits.cursor,undo_before+1)
    testing.expect_value(t,ai_review_test_transform(&f.w,first).position,[3]f32{0,0,0})
    testing.expect_value(t,ai_review_test_transform(&f.w,first).scale,[3]f32{2,2,2})
    testing.expect_value(t,ai_review_test_transform(&f.w,second).position,[3]f32{7,8,9})
    testing.expect(t,a.review_finished && !a.review.pending && b.review.pending)
    testing.expect(t,history.undo(&f.edits,ref,&f.selection))
    testing.expect_value(t,ai_review_test_transform(&f.w,first).position,[3]f32{1,2,3})
    testing.expect_value(t,ai_review_test_transform(&f.w,first).scale,[3]f32{2,2,2})
    testing.expect(t,history.redo(&f.edits,ref,&f.selection))
    testing.expect_value(t,ai_review_test_transform(&f.w,first).position,[3]f32{0,0,0})
}

@(test)
ai_review_reverts_and_restores_a_turn_that_outgrew_its_record_from_the_history :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    COUNT :: AI_REVIEW_ROW_CAPACITY+8
    entities:=make([]core.Entity,COUNT);defer delete(entities)
    for &e,i in entities {e=ai_review_test_entity(&f.w,base.Entity_Id(i+1))}
    core.world_settle(ref)
    history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0]
    task.id,task.world=1,&f.w
    defer ai_review_free(&task.review)
    for half in 0..<2 {
        before:=f.edits.serial
        history.edits_begin(&f.edits,&f.selection,"Move all")
        for e in entities {core.edit(&f.w.transforms,e).position[half]=1}
        history.edits_commit(&f.edits,ref,&f.selection)
        ai_review_record(&f.s,task,before)
    }
    task.state=.Done
    testing.expect(t,task.review.incomplete && len(task.review.states)==2,"the record is full and the turn keeps its steps")
    testing.expect(t,ai_review_revertible(&f.s,&task.review))
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    for e in entities {testing.expect_value(t,ai_review_test_transform(&f.w,e).position,[3]f32{0,0,0})}
    testing.expect(t,task.declined)
    testing.expect_value(t,ai_task_restore(&f.s,&f.ai,task),"")
    for e in entities {testing.expect_value(t,ai_review_test_transform(&f.w,e).position,[3]f32{1,1,0})}
    history.edits_reset(&f.edits,ref)
    testing.expect(t,!ai_review_revertible(&f.s,&task.review),"without its steps in the history the turn is not reverted in part")
    testing.expect(t,ai_task_revert(&f.s,&f.ai,task)!="")
    for e in entities {testing.expect_value(t,ai_review_test_transform(&f.w,e).position,[3]f32{1,1,0})}
}

@(test)
ai_review_preserves_later_overlapping_edits_and_finish_keeps_output :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    entity:=ai_review_test_entity(&f.w,33)
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent")
    core.edit(&f.w.transforms,entity).position={1,0,0}
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    history.edits_begin(&f.edits,&f.selection,"User")
    core.edit(&f.w.transforms,entity).position={2,0,0}
    history.edits_commit(&f.edits,ref,&f.selection)
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent again")
    core.edit(&f.w.transforms,entity).position={3,0,0}
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Done
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect_value(t,ai_review_test_transform(&f.w,entity).position,[3]f32{2,0,0})
    testing.expect_value(t,task.review.skipped,1)
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Accepted agent")
    core.edit(&f.w.transforms,entity).scale={4,4,4}
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    state:=history.edits_state(&f.edits)
    testing.expect(t,ai_task_finish(&f.s,&f.ai,task))
    testing.expect_value(t,ai_review_test_transform(&f.w,entity).scale,[3]f32{4,4,4})
    testing.expect_value(t,history.edits_state(&f.edits),state)
    testing.expect(t,task.review_finished && !task.review.pending && len(task.review.transactions)==0)
}

@(test)
ai_review_restores_deleted_hierarchies_without_replacing_reused_entities :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    parent:=ai_review_test_entity(&f.w,44)
    child:=ai_review_test_entity(&f.w,55)
    core.add(&f.w.parents,child,core.Parent{entity=parent})
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Delete hierarchy")
    core.destroy(&f.w.entities,parent);core.destroy(&f.w.entities,child)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    replacement:=ai_review_test_entity(&f.w,66)
    core.world_settle(ref)
    history.edits_commit(&f.edits,ref,&f.selection)
    task.state=.Done
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    restored_parent:=ai_review_test_id(&f.w,44)
    restored_child:=ai_review_test_id(&f.w,55)
    testing.expect(t,restored_parent!=core.NONE && restored_child!=core.NONE && core.alive(&f.w.entities,replacement))
    testing.expect_value(t,api_entity_id(ref,replacement),base.Entity_Id(66))
    testing.expect_value(t,ai_review_test_parent(&f.w,restored_child).entity,restored_parent)
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Create object")
    created:=ai_review_test_entity(&f.w,67)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    history.edits_begin(&f.edits,&f.selection,"User changed created object")
    core.edit(&f.w.transforms,created).position={9,0,0}
    history.edits_commit(&f.edits,ref,&f.selection)
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect(t,core.alive(&f.w.entities,created))
    testing.expect_value(t,ai_review_test_transform(&f.w,created).position,[3]f32{9,0,0})
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Create untouched object")
    untouched:=ai_review_test_entity(&f.w,68)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect(t,!core.alive(&f.w.entities,untouched))
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Create referenced object")
    referenced:=ai_review_test_entity(&f.w,69)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    history.edits_begin(&f.edits,&f.selection,"Other agent's child")
    external_child:=ai_review_test_entity(&f.w,70)
    core.add(&f.w.parents,external_child,core.Parent{entity=referenced})
    history.edits_commit(&f.edits,ref,&f.selection)
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect(t,core.alive(&f.w.entities,referenced) && core.alive(&f.w.entities,external_child))
    testing.expect_value(t,ai_review_test_parent(&f.w,external_child).entity,referenced)
}

@(test)
ai_review_persists_project_reviews_and_remaps_entity_references_on_reopen :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-review");if root=="" {return}
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    f.s.project_root=root
    ref:=edited_world(&f.s)
    first:=ai_review_test_entity(&f.w,77)
    second:=ai_review_test_entity(&f.w,88)
    child:=ai_review_test_entity(&f.w,99)
    core.add(&f.w.parents,child,core.Parent{entity=first})
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w;task.conversation.id=123;task.icon=3;task.color_index=2;task.anchor={1,2,3};task.anchor_set=true
    base.text_set(task.name[:],"123-0")
    task.region={10,20,300,200};task.window={800,600}
    task.context_ids[0],task.context_count=77,1
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Reparent")
    core.edit(&f.w.parents,child).entity=second
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Running
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    ai_review_free(&task.review)
    core.destroy(&f.w.entities,first);core.destroy(&f.w.entities,second);core.destroy(&f.w.entities,child)
    core.world_settle(ref)
    ai_review_test_entity(&f.w,101)
    child=ai_review_test_entity(&f.w,99)
    second=ai_review_test_entity(&f.w,88)
    first=ai_review_test_entity(&f.w,77)
    core.add(&f.w.parents,child,core.Parent{entity=second})
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task.icon=0;task.anchor_set=false;task.context_count=0
    base.text_set(task.name[:],"123-1")
    testing.expect_value(t,ai_review_load(&f.s,task),"Stored scene review belongs to an earlier chat turn")
    base.text_set(task.name[:],"123-0")
    testing.expect_value(t,ai_review_load(&f.s,task),"")
    testing.expect_value(t,task.state,Ai_Task_State.Failed)
    testing.expect_value(t,task.icon,u8(3))
    testing.expect(t,task.review.pending && task.anchor_set && !task.review_finished)
    testing.expect(t,task.context_count==1 && task.context_ids[0]==77,"sent context survives a project reopen and entity handle remapping")
    testing.expect_value(t,task.region.w,f32(300))
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect_value(t,ai_review_test_parent(&f.w,child).entity,first)
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    testing.expect_value(t,ai_review_load(&f.s,task),"")
    testing.expect(t,task.review_finished && !task.review.pending)
}

@(test)
ai_scene_follows_committed_edits_to_new_entities_and_keeps_the_sent_context :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    f.viewport.orbit=ORBIT_DEFAULT
    ref:=edited_world(&f.s)
    first:=ai_review_test_entity(&f.w,11)
    core.world_settle(ref)
    history.edits_reset(&f.edits,ref)
    history.selection_set(&f.selection,{first})
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w
    task.context_ids[0],task.context_count=11,1
    defer ai_review_free(&task.review)
    initial:=ai_scene_anchor(&f.s,task)
    testing.expect(t,(initial.x==0 || initial.z==0) && initial.y>0,"the figure starts on a single horizontal gizmo axis and above its pivot")
    history.selection_clear(&f.selection)
    serial:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Create agent object")
    second:=ai_review_test_entity(&f.w,22)
    core.world_settle(ref)
    core.edit(&f.w.transforms,second).position={20,2,30}
    history.edits_commit(&f.edits,ref,&f.selection)
    ai_review_record(&f.s,task,serial)
    testing.expect(t,task.anchor!=initial && (task.anchor.x==20 || task.anchor.z==30) && task.anchor.y>2,"committed creation moves the figure along one gizmo axis above the new entity")
    testing.expect(t,task.context_count==1 && task.context_ids[0]==11,"following edits preserves the context captured at send")
    serial=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Move original context")
    core.edit(&f.w.transforms,first).position={-15,1,-25}
    history.edits_commit(&f.edits,ref,&f.selection)
    ai_review_record(&f.s,task,serial)
    testing.expect(t,(task.anchor.x==-15 || task.anchor.z==-25) && task.anchor.y>1,"the next transaction relocates the same figure on a single gizmo axis")
}

@(test)
ai_review_storage_reclaims_bulk_scratch_and_rejects_oversized_files_before_reading :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-review-memory");if root=="" {return}
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    f.s.project_root=root
    ref:=edited_world(&f.s)
    entity:=ai_review_test_entity(&f.w,1)
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.conversation.id=1;task.world=&f.w
    base.text_set(task.name[:],"1-0")
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent move")
    core.edit(&f.w.transforms,entity).position={1,2,3}
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    exemplar:=task.review.transactions[0].rows[0]
    for i in 1..<512 {
        row:=exemplar
        row.before=make([]u8,len(exemplar.before));copy(row.before,exemplar.before)
        row.after=make([]u8,len(exemplar.after));copy(row.after,exemplar.after)
        transaction:=history.Change_Set{state=u64(i+1)}
        append(&transaction.rows,row);append(&task.review.transactions,transaction)
        task.review.rows+=1;task.review.bytes+=len(row.before)+len(row.after)
    }
    defer ai_review_free(&task.review)
    task.state=.Done
    scratch:base.Arena
    if !testing.expect(t,base.arena_init(&scratch,64<<10)) {return}
    defer base.arena_destroy(&scratch)
    previous:=context.temp_allocator
    context.temp_allocator=base.arena_allocator(&scratch)
    defer context.temp_allocator=previous
    for _ in 0..<3 {
        testing.expect_value(t,ai_review_save(&f.s,task),"")
        testing.expect(t,ai_review_pending(&f.s,task.conversation.id))
        testing.expect_value(t,ai_review_load(&f.s,task),"")
    }
    testing.expect(t,base.arena_stats(&scratch).used<4096,"bulk JSON buffers do not accumulate in the caller's frame scratch")
    path:=project.path(root,".mirai/ai/chats/1.review.json",allocator=context.allocator)
    defer delete(path)
    file,error:=os.create(path)
    if !testing.expect(t,error==nil) {return}
    testing.expect(t,os.truncate(file,AI_REVIEW_BYTE_CAPACITY*6+1)==nil)
    _=os.close(file)
    testing.expect(t,!ai_review_pending(&f.s,task.conversation.id))
    testing.expect_value(t,ai_review_load(&f.s,task),"Stored project scene review exceeds capacity")
}

@(test)
ai_scene_places_figures_on_gizmo_axes_above_the_handles_at_different_zooms :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    e:=ai_review_test_entity(&f.w,11)
    ref:=core.test_world_ref(&f.w)
    core.world_settle(ref)
    targets:=[1]core.Entity{e}
    f.viewport.orbit,f.viewport.size=ORBIT_DEFAULT,{1440,900}
    task:Ai_Task
    for space in ([2]Space{.World,.Local}) {
        f.viewport.space=space
        core.edit(&f.w.transforms,e).rotation=mm.quat_axis_angle({0,1,0},0.7)
        for distance in ([3]f32{5,17,40}) {
            f.viewport.orbit.distance=distance
            viewport_camera(&f.viewport)
            g:=gizmo_at(&f.s,ref,{},e,.Move)
            testing.expect(t,g.visible && g.size>0)
            ai_scene_place(&f.s,&task,ref,{},targets[:])
            testing.expect(t,task.anchor.y>g.size,"the figure's base is above the gizmo's upper handle")
            horizontal:=task.anchor;horizontal.y=0
            aligned:=false
            for axis in ([2]int{0,2}) {
                direction:=g.axes[axis];direction.y=0
                if abs(horizontal.x*direction.z-horizontal.z*direction.x)<0.001 && linalg.length(horizontal)>g.size+0.5 {aligned=true}
            }
            testing.expect(t,aligned,"the base clears the gizmo along X or Z, including local axes")
        }
    }
}

@(test)
ai_review_resolves_one_field_and_one_entity_at_a_time :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    first:=ai_review_test_entity(&f.w,11)
    second:=ai_review_test_entity(&f.w,22)
    core.world_settle(ref)
    history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0]
    task.id=1;task.world=&f.w;f.ai.task_count=1
    defer ai_review_free(&task.review)
    // Two transactions of one turn move the same field twice.
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent edits")
    core.edit(&f.w.transforms,first).position={1,2,3}
    core.edit(&f.w.transforms,first).scale={2,2,2}
    core.edit(&f.w.transforms,second).position={7,8,9}
    history.edits_commit(&f.edits,ref,&f.selection)
    history.edits_begin(&f.edits,&f.selection,"Agent edits again")
    core.edit(&f.w.transforms,first).position={4,5,6}
    history.edits_commit(&f.edits,ref,&f.selection)
    ai_review_record(&f.s,task,before)
    task.state=.Done
    testing.expect(t,ai_task_reviewable(task) && len(task.review.changed_ids)==2)
    transform:=&f.s.info.tables[2]
    position:=int(offset_of(core.Transform,position))
    found,ok:=ai_review_field(&f.s,&f.ai,ref,transform,first,position,size_of([3]f32))
    testing.expect(t,ok && found==task)
    _,on_parent:=ai_review_field(&f.s,&f.ai,ref,&f.s.info.tables[3],first,0,size_of(core.Entity))
    testing.expect(t,!on_parent,"a field that holds an entity is not offered")
    // The field goes back to what it had before the turn, not to the middle step.
    serial:=f.ai.scene_serial
    restored,kept:=ai_review_field_revert(&f.s,&f.ai,ref,transform,{first},position,size_of([3]f32))
    testing.expect(t,restored && !kept)
    testing.expect_value(t,ai_review_test_transform(&f.w,first).position,[3]f32{0,0,0})
    testing.expect_value(t,ai_review_test_transform(&f.w,first).scale,[3]f32{2,2,2})
    testing.expect(t,f.ai.scene_serial!=serial,"the outlines follow what is left")
    _,again:=ai_review_field(&f.s,&f.ai,ref,transform,first,position,size_of([3]f32))
    testing.expect(t,!again,"the field it resolved is not offered twice")
    owners:[4]int
    testing.expect_value(t,ai_review_tasks_of(&f.s,&f.ai,ref,first,owners[:]),1)
    // The rest of that entity is kept, and the other one is put back.
    ai_review_entity_accept(&f.s,&f.ai,task,11)
    testing.expect_value(t,ai_review_tasks_of(&f.s,&f.ai,ref,first,owners[:]),0)
    testing.expect_value(t,ai_review_test_transform(&f.w,first).scale,[3]f32{2,2,2})
    testing.expect_value(t,len(task.review.changed_ids),1)
    testing.expect(t,task.review.pending,"the other entity keeps the review open")
    testing.expect_value(t,ai_review_entity_revert(&f.s,&f.ai,task,22),"")
    testing.expect_value(t,ai_review_test_transform(&f.w,second).position,[3]f32{0,0,0})
    testing.expect(t,!task.review.pending && task.review_finished,"with nothing left the turn stops asking")
}

@(test)
ai_review_takes_out_or_keeps_an_entity_the_turn_created :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    core.world_settle(ref)
    history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0]
    task.id=1;task.world=&f.w;f.ai.task_count=1
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent creates")
    _=ai_review_test_entity(&f.w,33)
    _=ai_review_test_entity(&f.w,34)
    core.world_settle(ref)
    history.edits_commit(&f.edits,ref,&f.selection)
    ai_review_record(&f.s,task,before)
    task.state=.Done
    testing.expect(t,len(task.review.changed_ids)==2 && task.review.pending)
    testing.expect_value(t,ai_review_entity_revert(&f.s,&f.ai,task,33),"")
    testing.expect(t,history.change_entity(ref,33)==core.NONE && len(task.review.changed_ids)==1,"putting back a created entity takes it out")
    ai_review_entity_accept(&f.s,&f.ai,task,34)
    testing.expect(t,len(task.review.changed_ids)==0 && !task.review.pending,"keeping it resolves it")
    testing.expect_value(t,len(task.review.transactions),0)
}

@(test)
the_document_is_edited_while_a_run_belongs_to_an_agent :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    live:Ai_Review_Test_World
    if !core.test_world_init(t,&live) {return}
    defer core.test_world_destroy(&live)
    defer viewport_free(&f.viewport)
    out:serial.Writer;serial.writer_init(&out);defer serial.writer_destroy(&out)
    call:=api.Call{out=&out,allocator=context.temp_allocator}
    // While the editor shows a game, the scene of the document still takes edits.
    f.s.mode=.Play
    f.s.runs[0]={world=&live}
    testing.expect(t,running(&f.s))
    testing.expect(t,shown_world(&f.s).data==rawptr(&live) && edited_world(&f.s).data==rawptr(&f.w))
    testing.expect(t,api_guard(&f.s,&call) && !call.failed,"the document is edited while a game runs")
    // A run an agent keeps alive is not what the editor shows.
    f.s.mode,f.s.runs[0].owner=.Edit,7
    testing.expect(t,running(&f.s) && run_find(&f.s,0)==nil)
    testing.expect(t,shown_world(&f.s).data==rawptr(&f.w) && run_find(&f.s,7).world==rawptr(&live))
    // A turn that began inside the run of the user inherits it when the user
    // leaves; one that did not, or that has a run of its own, does not.
    task:=&f.ai.tasks[0];task.id=7;task.state=.Running;task.world=&f.w;task.play=true;f.ai.task_count=1
    defer ai_review_free(&task.review)
    f.s.mode,f.s.runs[0].owner=.Play,0
    testing.expect_value(t,play_heir(&f.s),7)
    f.s.runs[1]={world=&f.w,owner=7}
    testing.expect_value(t,play_heir(&f.s),0)
    f.s.runs[1]={}
    task.play=false
    testing.expect_value(t,play_heir(&f.s),0)
    task.play=true;task.state=.Done
    testing.expect_value(t,play_heir(&f.s),0)
    f.s.mode=.Edit
    testing.expect_value(t,play_heir(&f.s),0)
    // A turn reads the game of the user it began inside and changes only a run of its own.
    base.text_set(task.name[:],"1-1")
    call.client_tag="1-1"
    f.s.mode,f.s.runs[0].owner=.Play,0
    r,own:=api_play_run(&f.s,&call)
    testing.expect(t,r==&f.s.runs[0] && !own,"a turn does not step or stop the game of the user")
    f.s.mode,f.s.runs[0].owner=.Edit,7
    r,own=api_play_run(&f.s,&call)
    testing.expect(t,r==&f.s.runs[0] && own,"the turn that owns the run drives it")
    call.client_tag=""
    r,own=api_play_run(&f.s,&call)
    testing.expect(t,r==nil && own,"outside a turn a call is about the game of the user, which is not playing")
}

@(test)
ai_review_keeps_deletions_reviewable_and_puts_them_back_one_by_one :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    parent:=ai_review_test_entity(&f.w,44)
    child:=ai_review_test_entity(&f.w,55)
    core.add(&f.w.parents,child,core.Parent{entity=parent})
    core.world_settle(ref)
    core.edit(&f.w.transforms,parent).position={2,0,0}
    core.edit(&f.w.transforms,child).position={0,1,0}
    history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Delete hierarchy")
    core.destroy(&f.w.entities,parent);core.destroy(&f.w.entities,child)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Done

    // What was deleted stays in the review where it was.
    testing.expect(t,ai_review_deleted(ref,task,44) && ai_review_deleted(ref,task,55))
    place,found:=ai_review_deleted_world(ref,task,55,0)
    testing.expect(t,found && place.position==[3]f32{2,1,0})
    // Details shows the deletion the walk brought into sight while the selection stays as the walk left it.
    f.ai.task_count=1
    f.ai.review_task,f.ai.review_shown,f.ai.review_selection=task.id,55,f.selection.serial
    _,shown_id,shown:=ai_review_shown(&f.s)
    testing.expect(t,shown && shown_id==55)
    history.selection_set(&f.selection,{core.NONE})
    _,_,shown=ai_review_shown(&f.s)
    testing.expect(t,!shown,"another selection takes Details")
    f.ai.review_shown=0
    // A child comes back after its parent, one at a time, each as it was.
    testing.expect(t,ai_review_entity_restore(&f.s,&f.ai,task,55)!="")
    testing.expect_value(t,ai_review_entity_restore(&f.s,&f.ai,task,44),"")
    testing.expect_value(t,ai_review_entity_restore(&f.s,&f.ai,task,55),"")
    history.edits_commit(&f.edits,ref,&f.selection)
    restored_parent,restored_child:=ai_review_test_id(&f.w,44),ai_review_test_id(&f.w,55)
    testing.expect(t,restored_parent!=core.NONE && restored_child!=core.NONE)
    testing.expect_value(t,ai_review_test_parent(&f.w,restored_child).entity,restored_parent)
    testing.expect_value(t,ai_review_test_transform(&f.w,restored_child).position,[3]f32{0,1,0})
    testing.expect(t,!task.review.pending && len(task.review.changed_ids)==0)

    // Keeping a deletion takes it out of the review and leaves it deleted.
    next:=&f.ai.tasks[1];next.id=2;next.world=&f.w
    defer ai_review_free(&next.review)
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Delete again")
    core.destroy(&f.w.entities,restored_child)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,next,before)
    next.state=.Done
    testing.expect(t,ai_review_deleted(ref,next,55))
    ai_review_entity_accept(&f.s,&f.ai,next,55)
    testing.expect(t,!ai_review_deleted(ref,next,55) && ai_review_test_id(&f.w,55)==core.NONE)
}

@(test)
ai_review_takes_declined_changes_back_for_review :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    moved:=ai_review_test_entity(&f.w,44)
    gone:=ai_review_test_entity(&f.w,45)
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent edits")
    core.edit(&f.w.transforms,moved).position={3,0,0}
    core.destroy(&f.w.entities,gone)
    created:=ai_review_test_entity(&f.w,46)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Done

    // Reverting declines: the scene is as before, the record stays and the chat says so.
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect(t,task.declined && !task.review.pending && len(task.review.transactions)>0)
    testing.expect_value(t,ai_review_test_transform(&f.w,ai_review_test_id(&f.w,44)).position,[3]f32{0,0,0})
    testing.expect(t,ai_review_test_id(&f.w,45)!=core.NONE && ai_review_test_id(&f.w,46)==core.NONE && !core.alive(&f.w.entities,created))
    testing.expect(t,ai_transcript_declined(&task.transcript)>=0)

    // Taking them back puts the scene as the agent left it, to review again.
    testing.expect_value(t,ai_task_restore(&f.s,&f.ai,task),"")
    testing.expect(t,!task.declined && task.review.pending && !task.review_finished)
    testing.expect_value(t,ai_review_test_transform(&f.w,ai_review_test_id(&f.w,44)).position,[3]f32{3,0,0})
    testing.expect(t,ai_review_test_id(&f.w,45)==core.NONE && ai_review_test_id(&f.w,46)!=core.NONE)
    testing.expect(t,ai_review_deleted(ref,task,45))

    // And it can be declined again, and kept at last.
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect_value(t,ai_task_restore(&f.s,&f.ai,task),"")
    testing.expect(t,ai_task_finish(&f.s,&f.ai,task))
    testing.expect(t,!task.declined && !task.review.pending && ai_review_test_id(&f.w,46)!=core.NONE)
    testing.expect(t,ai_task_restore(&f.s,&f.ai,task)!="")
}

@(test)
ai_review_follows_the_scene_it_is_read_with :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    gone:=ai_review_test_entity(&f.w,45)
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w
    f.ai.task_count=1
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent deletes")
    core.destroy(&f.w.entities,gone)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Done

    // A scene that holds what the turn left keeps it waiting for review.
    ai_review_reconcile(&f.s,&f.ai,task)
    testing.expect(t,task.review.pending && !task.declined)
    // Closed without saving, the scene is read as it was before the turn: its
    // changes wait declined and the chat offers to take them back.
    testing.expect(t,history.undo(&f.edits,ref,&f.selection))
    ai_review_reconcile(&f.s,&f.ai,task)
    testing.expect(t,task.declined && !task.review.pending && task.review_finished && !ai_task_reviewable(task))
    testing.expect(t,ai_transcript_declined(&task.transcript)>=0)
    testing.expect_value(t,ai_task_restore(&f.s,&f.ai,task),"")
    testing.expect(t,ai_review_test_id(&f.w,45)==core.NONE && task.review.pending && ai_task_reviewable(task))
    // Reverted, and then read again with the changes: they wait for review again.
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect(t,task.declined && ai_review_test_id(&f.w,45)!=core.NONE)
    testing.expect(t,history.undo(&f.edits,ref,&f.selection))
    ai_review_reconcile(&f.s,&f.ai,task)
    testing.expect(t,!task.declined && task.review.pending && !task.review_finished && ai_review_deleted(ref,task,45))
}

@(test)
quitting_asks_while_agents_work_and_stops_them_before_going_on :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    defer documents_free(&f.s)
    f.document.saved=history.edits_state(&f.edits)
    running:=&f.ai.tasks[0];running.id=1;running.world=&f.w;running.state=.Running
    queued:=&f.ai.tasks[1];queued.id=2;queued.world=&f.w;queued.state=.Queued
    f.ai.task_count=2
    testing.expect_value(t,ai_working_count(&f.s),2)

    // With nothing unsaved, quitting asks while agents work; Cancel leaves them working.
    documents_quit_next(&f.s)
    testing.expect(t,f.gui.modal==.Confirm && f.gui.pending==.Quit && !f.s.quit)
    confirm_resolve(&f.s,.Cancel)
    testing.expect_value(t,ai_working_count(&f.s),2)
    // Going on stops them first, so the API refuses what they would still do.
    documents_quit_next(&f.s)
    confirm_resolve(&f.s,.Discard)
    testing.expect_value(t,ai_working_count(&f.s),0)
    testing.expect(t,running.stop && queued.state==.Cancelled)
    testing.expect(t,.Quit_Check in f.s.requests)
    documents_quit_next(&f.s)
    testing.expect(t,f.s.quit,"the agents answered, nothing else is asked")
}

@(test)
ai_review_walk_goes_on_to_the_next_change_after_one_is_resolved :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    first:=ai_review_test_entity(&f.w,44)
    second:=ai_review_test_entity(&f.w,45)
    gone:=ai_review_test_entity(&f.w,46)
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w
    f.ai.task_count=1
    defer ai_review_free(&task.review)
    // Three changes, in this order: two moves and a deletion.
    step :: proc(s:^Session,task:^Ai_Task,w:^Ai_Review_Test_World,change:proc(w:^Ai_Review_Test_World)) {
        before:=s.edits.serial
        history.edits_begin(s.edits,s.selection,"Agent edit")
        change(w)
        history.edits_commit(s.edits,edited_world(s),s.selection);ai_review_record(s,task,before)
    }
    step(&f.s,task,&f.w,proc(w:^Ai_Review_Test_World) {core.edit(&w.transforms,ai_review_test_id(w,44)).position={1,0,0}})
    step(&f.s,task,&f.w,proc(w:^Ai_Review_Test_World) {core.edit(&w.transforms,ai_review_test_id(w,45)).position={2,0,0}})
    step(&f.s,task,&f.w,proc(w:^Ai_Review_Test_World) {core.destroy(&w.entities,ai_review_test_id(w,46))})
    task.state=.Done
    testing.expect(t,!core.alive(&f.w.entities,gone))

    // The walk shows the first change; keeping it brings the next into sight.
    ai_review_walk(&f.s,task)
    testing.expect_value(t,history.selection_active(&f.selection),first)
    ai_review_entity_accept(&f.s,&f.ai,task,44)
    ai_review_resolved(&f.s,task,44,true)
    testing.expect_value(t,history.selection_active(&f.selection),second)
    // Putting one back goes on too, here to a deletion that Details shows.
    testing.expect_value(t,ai_review_entity_revert(&f.s,&f.ai,task,45),"")
    ai_review_resolved(&f.s,task,45,true)
    _,shown,in_sight:=ai_review_shown(&f.s)
    testing.expect(t,in_sight && shown==46 && len(f.selection.entities)==0)
    // With nothing left to walk, the deletion put back is selected.
    testing.expect_value(t,ai_review_entity_revert(&f.s,&f.ai,task,46),"")
    ai_review_resolved(&f.s,task,46,true)
    restored:=ai_review_test_id(&f.w,46)
    testing.expect(t,restored!=core.NONE && history.selection_active(&f.selection)==restored)
}

// Turning a component off with the same value is a change of the turn: the
// review shows it, Revert and Restore turn it, and so does the bar of the
// entity. A deletion comes back with its components turned off.
@(test)
ai_review_shows_reverts_and_restores_a_component_turned_off :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    lamp:=ai_review_test_entity(&f.w,11)
    core.add(&f.w.lamps,lamp,Ai_Review_Test_Lamp{10})
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w;f.ai.task_count=1
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent turns the lamp off")
    core.disable(&f.w.lamps,lamp)
    core.world_settle(ref)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Done
    testing.expect(t,!core.has(&f.w.lamps,lamp))
    testing.expect(t,task.review.pending && len(task.review.changed_ids)==1 && len(task.review.transactions)==1)
    if len(task.review.transactions)==1 && testing.expect_value(t,len(task.review.transactions[0].rows),1) {
        row:=task.review.transactions[0].rows[0]
        testing.expect(t,row.table==5 && row.before_present && row.after_present && !row.before_off && row.after_off)
    }
    _,shown:=ai_review_component(&f.s,&f.ai,ref,&f.s.info.tables[5],lamp)
    testing.expect(t,shown,"Details shows the component the turn turned off")

    // Revert turns it on in one step of undo, and Restore turns it off again.
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    value,on:=core.get(core.read(&f.w.lamps),lamp)
    testing.expect(t,on && value.intensity==10)
    testing.expect(t,history.undo(&f.edits,ref,&f.selection) && !core.has(&f.w.lamps,lamp))
    testing.expect(t,history.redo(&f.edits,ref,&f.selection) && core.has(&f.w.lamps,lamp))
    testing.expect_value(t,ai_task_restore(&f.s,&f.ai,task),"")
    testing.expect(t,!core.has(&f.w.lamps,lamp) && task.review.pending)
    testing.expect_value(t,ai_review_entity_revert(&f.s,&f.ai,task,11),"")
    history.edits_commit(&f.edits,ref,&f.selection)
    testing.expect(t,core.has(&f.w.lamps,lamp) && !task.review.pending)

    // A lamp the user turned off and the agent deleted comes back off.
    history.edits_begin(&f.edits,&f.selection,"User turns the lamp off")
    core.disable(&f.w.lamps,lamp)
    core.world_settle(ref)
    history.edits_commit(&f.edits,ref,&f.selection)
    next:=&f.ai.tasks[1];next.id=2;next.world=&f.w;f.ai.task_count=2
    defer ai_review_free(&next.review)
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent deletes the lamp")
    core.destroy(&f.w.entities,lamp)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,next,before)
    next.state=.Done
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,next),"")
    _,turned_off,found:=core.raw_state(core.raw(&f.w.lamps),ai_review_test_id(&f.w,11))
    testing.expect(t,found && turned_off,"Revert puts the lamp back turned off")
    testing.expect_value(t,ai_task_restore(&f.s,&f.ai,next),"")
    testing.expect(t,ai_review_deleted(ref,next,11))
    testing.expect_value(t,ai_review_entity_restore(&f.s,&f.ai,next,11),"")
    history.edits_commit(&f.edits,ref,&f.selection)
    _,turned_off,found=core.raw_state(core.raw(&f.w.lamps),ai_review_test_id(&f.w,11))
    testing.expect(t,found && turned_off,"putting the deletion back from Details keeps it off")
}

// Turning an entity off is its Disabled tag: one more row of the review, put
// back by Revert, Restore and the bar of the entity.
@(test)
ai_review_covers_turning_an_entity_off_as_its_disabled_row :: proc(t:^testing.T) {
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    ref:=edited_world(&f.s)
    lamp:=ai_review_test_entity(&f.w,11)
    core.add(&f.w.lamps,lamp,Ai_Review_Test_Lamp{10})
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w;f.ai.task_count=1
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent disables the lamp")
    core.add(&f.w.disabled,lamp,core.Disabled{})
    core.world_settle(ref)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Done
    testing.expect(t,core.entity_off(&f.w.entities,lamp) && !core.has(&f.w.lamps,lamp))
    testing.expect(t,!task.review.incomplete && task.review.pending && len(task.review.transactions)==1)
    if len(task.review.transactions)==1 && testing.expect_value(t,len(task.review.transactions[0].rows),1) {
        row:=task.review.transactions[0].rows[0]
        testing.expect(t,row.table==4 && !row.before_present && row.after_present && !row.after_off,"the lamp keeps its own state: only Disabled changed")
    }
    testing.expect_value(t,ai_task_revert(&f.s,&f.ai,task),"")
    testing.expect(t,!core.entity_off(&f.w.entities,lamp) && core.has(&f.w.lamps,lamp))
    testing.expect_value(t,ai_task_restore(&f.s,&f.ai,task),"")
    testing.expect(t,core.entity_off(&f.w.entities,lamp))
    testing.expect_value(t,ai_review_entity_revert(&f.s,&f.ai,task,11),"")
    history.edits_commit(&f.edits,ref,&f.selection)
    testing.expect(t,!core.entity_off(&f.w.entities,lamp) && core.has(&f.w.lamps,lamp) && !task.review.pending)
}

// The stored record keeps whether each component was off on each side, and
// the scene it is read with decides by it too. A row that turns off what is
// absent or the base of an entity, or a file of another version, is refused.
@(test)
ai_review_persists_turned_off_components_and_refuses_invalid_rows :: proc(t:^testing.T) {
    root:=base.test_folder(t,"ai-review-off");if root=="" {return}
    f:=ai_review_test_open(t);if f==nil {return}
    defer ai_review_test_close(f)
    f.s.project_root=root
    ref:=edited_world(&f.s)
    lamp:=ai_review_test_entity(&f.w,11)
    other:=ai_review_test_entity(&f.w,22)
    core.add(&f.w.lamps,lamp,Ai_Review_Test_Lamp{10})
    core.world_settle(ref);history.edits_reset(&f.edits,ref)
    task:=&f.ai.tasks[0];task.id=1;task.world=&f.w;task.conversation.id=7;f.ai.task_count=1
    base.text_set(task.name[:],"7-0")
    defer ai_review_free(&task.review)
    before:=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent turns the lamp off")
    core.disable(&f.w.lamps,lamp)
    core.world_settle(ref)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    task.state=.Done
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    ai_review_free(&task.review)
    testing.expect_value(t,ai_review_load(&f.s,task),"")
    testing.expect(t,task.review.pending && !task.declined)
    if testing.expect_value(t,len(task.review.transactions),1) && testing.expect_value(t,len(task.review.transactions[0].rows),1) {
        row:=task.review.transactions[0].rows[0]
        testing.expect(t,!row.before_off && row.after_off,"the record keeps the lamp turned off")
    }
    // Read with the scene before the turn it waits declined; with the turn, for review again.
    testing.expect(t,history.undo(&f.edits,ref,&f.selection) && core.has(&f.w.lamps,lamp))
    testing.expect_value(t,ai_review_load(&f.s,task),"")
    testing.expect(t,task.declined && !task.review.pending)
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    testing.expect(t,history.redo(&f.edits,ref,&f.selection) && !core.has(&f.w.lamps,lamp))
    testing.expect_value(t,ai_review_load(&f.s,task),"")
    testing.expect(t,!task.declined && task.review.pending)

    // A Disabled row has no bytes and goes and comes back as it is.
    testing.expect(t,ai_task_finish(&f.s,&f.ai,task))
    base.text_set(task.name[:],"7-1")
    before=f.edits.serial
    history.edits_begin(&f.edits,&f.selection,"Agent disables the other")
    core.add(&f.w.disabled,other,core.Disabled{})
    core.world_settle(ref)
    history.edits_commit(&f.edits,ref,&f.selection);ai_review_record(&f.s,task,before)
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    testing.expect_value(t,ai_review_load(&f.s,task),"")
    if !testing.expect(t,len(task.review.transactions)==1 && len(task.review.transactions[0].rows)==1) {return}
    row:=&task.review.transactions[0].rows[0]
    testing.expect(t,row.table==4 && !row.before_present && row.after_present)
    row.after_off=true
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    testing.expect_value(t,ai_review_load(&f.s,task),"Stored scene review row is invalid")
    row.after_off,row.before_off=false,true
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    testing.expect_value(t,ai_review_load(&f.s,task),"Stored scene review row is invalid")
    row.before_off=false
    testing.expect_value(t,ai_review_save(&f.s,task),"")
    path:=project.path(root,".mirai/ai/chats/7.review.json",allocator=context.temp_allocator)
    data,error:=os.read_entire_file(path,context.temp_allocator)
    if !testing.expect(t,error==nil) {return}
    older,replaced:=strings.replace(string(data),fmt.tprintf(`"version":%d`,AI_REVIEW_VERSION),`"version":2`,1,context.temp_allocator)
    testing.expect(t,replaced)
    testing.expect(t,serial.file_write_atomic(path,transmute([]u8)older)==.None)
    testing.expect(t,!ai_review_pending(&f.s,task.conversation.id))
    testing.expect_value(t,ai_review_load(&f.s,task),"Stored project scene review is invalid")
}

