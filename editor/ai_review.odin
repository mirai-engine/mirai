package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:core"
import "mirai:editor/history"
import "mirai:project"
import "mirai:std/base"
import mm "mirai:std/math"

AI_REVIEW_BYTE_CAPACITY :: 16<<20
AI_REVIEW_ROW_CAPACITY :: 4096
AI_REVIEW_STAYS :: 6 // entities a revert names when it leaves them as they are; the rest is a count

Ai_Review :: struct {
    transactions:[dynamic]history.Change_Set,
    changed_ids:[dynamic]base.Entity_Id,
    changed_files:[dynamic]string, // project paths, in the order the turn changed them
    states:[dynamic]u64, // of the steps of the history the turn committed, oldest first
    moves:[dynamic]u64,  // of the steps that reverted or restored it: they are not of another author
    pending:bool,
    skipped,bytes,rows:int,
    incomplete:bool, // the transactions lack what did not fit: Revert takes the steps of states from the history
}

@(private="file")
ai_review_add_id :: proc(review:^Ai_Review,id:base.Entity_Id) {
    if id==0 {return}
    for known in review.changed_ids {if known==id {return}}
    append(&review.changed_ids,id)
}

@(private="file")
ai_review_add_file :: proc(review:^Ai_Review,path:string) {
    for known in review.changed_files {if known==path {return}}
    append(&review.changed_files,strings.clone(path))
}

ai_review_free :: proc(review:^Ai_Review) {
    for &transaction in review.transactions {history.change_set_free(&transaction)}
    for path in review.changed_files {delete(path)}
    delete(review.transactions);delete(review.changed_ids);delete(review.changed_files);delete(review.states);delete(review.moves)
    review^={}
}

// Whether a turn left something waiting for the user: entities or files.
@(private)
ai_review_waiting :: proc(review:^Ai_Review) -> int {return len(review.changed_ids)+len(review.changed_files)}

// The transactions of the turn as one: what each file held before the first
// one that changed it and what the last one left.
@(private)
Ai_File_Span :: struct {first,last:^history.Change_File}

@(private)
ai_review_file_span :: proc(review:^Ai_Review,path:string) -> (span:Ai_File_Span,ok:bool) {
    for &transaction in review.transactions {
        for &file in transaction.files {
            if file.path!=path {continue}
            if span.first==nil {span.first=&file}
            span.last=&file
        }
    }
    return span,span.first!=nil
}

// The steps a call of the turn committed (those past serial_before) are one
// transaction of its review.
ai_review_record :: proc(s:^Session,task:^Ai_Task,serial_before:u64) {
    if task==nil || s.edits==nil || task.document_closed || task.world!=nil && task.world!=s.edit_world {return}
    w:=edited_world(s)
    // New changes leave behind the ones the user declined.
    if task.declined {
        ai_review_free(&task.review)
        task.declined,task.undone=false,false
    }
    review:=&task.review
    transaction:history.Change_Set
    steps:=s.edits.steps[:s.edits.cursor]
    limit:=history.Change_Limit{review.rows,review.bytes,AI_REVIEW_ROW_CAPACITY,AI_REVIEW_BYTE_CAPACITY}
    for &step in steps {
        if step.state<=serial_before {continue}
        append(&review.states,step.state)
        if !history.change_set_take(edited_world(s),s.project_root,&transaction,&step,steps,&limit) {review.incomplete=true}
    }
    review.rows,review.bytes=limit.rows,limit.bytes
    if history.change_set_empty(&transaction) {
        history.change_set_free(&transaction)
        return
    }
    for row in transaction.rows {ai_review_add_id(review,row.id)}
    for file in transaction.files {ai_review_add_file(review,file.path)}
    append(&review.transactions,transaction)
    ai_provenance_record(s,task,&review.transactions[len(review.transactions)-1])
    review.pending=true;task.review_finished=false;s.ai.scene_serial+=1
    task.follows=true
}

ai_task_finish :: proc(s:^Session,m:^Ai,task:^Ai_Task) -> bool {
    if task==nil || !ai_task_finished(task) {return false}
    if task.review_finished && !task.review.pending && !task.declined {return true}
    // What was not put back is kept: the chat says how the review ended.
    kept,rejected:=task.kept+ai_review_count(task),task.rejected
    switch {
    case kept>0 && rejected>0: ai_note(task,fmt.tprintf("%s · %d kept · %d reverted",AI_REVIEWED_NOTE,kept,rejected))
    case kept>0:               ai_note(task,fmt.tprintf("%s · %d kept",AI_REVIEWED_NOTE,kept))
    case rejected>0:           ai_note(task,fmt.tprintf("%s · %d reverted",AI_REVIEWED_NOTE,rejected))
    }
    task.kept,task.rejected=0,0
    skipped:=task.review.skipped
    ai_review_free(&task.review)
    task.review.skipped=skipped
    task.review_finished,task.declined=true,false
    task.question=.None
    ai_task_dirty(task);ai_task_persist(s,task)
    m.scene_serial+=1
    m.deliveries_due=true
    return true
}

ai_task_revert :: proc(s:^Session,m:^Ai,task:^Ai_Task) -> string {
    if task==nil {return "This task is unavailable"}
    if !ai_task_finished(task) {return "Wait for the agent to finish before reverting"}
    if task.document_closed || task.world!=nil && task.world!=s.edit_world || !ai_task_current(s,task) {return "Open the task's document before reverting"}
    if task.files_changed {return "This task changed files of the project its review could not keep (larger than 1 MB or past its capacity): revert them by hand or with git"}
    if !task.review.pending {ai_task_finish(s,m,task);return ""}
    if !ai_review_revertible(s,&task.review) {return "The task outgrew its review and the history no longer holds all its steps; use scene history to revert"}
    if s.mode!=.Edit {return "Stop Play before reverting scene changes"}
    firm:=ai_review_firm(s,task)
    if !ai_review_apply(s,task,false,firm) {return "The task outgrew its review and the history cannot put it back; use scene history to revert"}
    if stays:=ai_review_stays(s,task,firm);stays!="" {
        ai_transcript_add(&task.transcript,stays,.Note)
        notify(s,stays)
    }
    task.kept,task.rejected=0,0
    // The record stays: the chat offers to take the changes back for review.
    task.undone,task.declined,task.review_finished=true,true,true
    task.review.pending=false
    task.question=.None
    ai_transcript_add(&task.transcript,AI_DECLINED_NOTE,.Note)
    ai_task_dirty(task);ai_task_persist(s,task)
    m.scene_serial+=1
    m.deliveries_due=true
    return ""
}

// The changes of a turn the user reverted come back, as the turn left them,
// to be reviewed again: kept or reverted, whole or one entity at a time.
ai_task_restore :: proc(s:^Session,m:^Ai,task:^Ai_Task) -> string {
    if task==nil || !task.declined {return "This task has no reverted changes to take back"}
    if line:=ai_transcript_declined(&task.transcript);line>=0 {task.transcript.heights[line]=0}
    if task.document_closed || task.world!=nil && task.world!=s.edit_world || !ai_task_current(s,task) {return "Open the task's document before taking its changes back"}
    if s.mode!=.Edit {return "Stop Play before taking the changes back"}
    if !ai_review_revertible(s,&task.review) || !ai_review_apply(s,task,true,nil) {return "The task outgrew its review and the history no longer holds all its steps"}
    task.undone,task.declined,task.review_finished=false,false,false
    ai_transcript_add(&task.transcript,AI_RESTORED_NOTE,.Note)
    ai_review_settle(s,m,task)
    return ""
}

// The entities of a turn that another author changed after the turn began:
// what the turn did to them is firm, and a revert leaves them as they are.
// In the temporary allocator.
ai_review_firm :: proc(s:^Session,task:^Ai_Task) -> []base.Entity_Id {
    review:=&task.review
    if s.edits==nil || len(review.states)==0 {return nil}
    w:=edited_world(s)
    author:=history.Edit_Author(task.id)
    firm:=make([dynamic]base.Entity_Id,context.temp_allocator)
    touched:=make([dynamic]base.Entity_Id,context.temp_allocator)
    for &step in s.edits.steps[:s.edits.cursor] {
        if step.state<=review.states[0] || step.author==author || step.reverted || step.swapped || slice.contains(review.moves[:],step.state) {continue}
        clear(&touched)
        history.step_ids(w,&step,&touched)
        for id in touched {
            if slice.contains(review.changed_ids[:],id) && !slice.contains(firm[:],id) {append(&firm,id)}
        }
    }
    return firm[:]
}

// What a revert of a turn left as it is, and why: the entities another
// author changed after, and those the turn created that something else
// hangs from or names. "" when it took everything back.
@(private="file")
ai_review_stays :: proc(s:^Session,task:^Ai_Task,firm:[]base.Entity_Id) -> string {
    w:=edited_world(s)
    b:=strings.builder_make(context.temp_allocator)
    count:=0
    say :: proc(b:^strings.Builder,count:^int,w:core.World_Ref,id:base.Entity_Id,why:string) {
        e:=history.change_entity(w,id)
        if e==core.NONE {return}
        if count^<AI_REVIEW_STAYS {fmt.sbprintf(b,"%s%s (%s)",count^>0?", ":"",entity_label(w,e),why)}
        count^+=1
    }
    for id in firm {say(&b,&count,w,id,"changed by someone else after the agent")}
    for &transaction in task.review.transactions {
        for &row in transaction.rows {
            created:=row.table>=0 && row.table<len(w.info.tables) && w.info.tables[row.table].type==core.Id && !row.before_present
            if created && !slice.contains(firm,row.id) {say(&b,&count,w,row.id,"something else hangs from it or names it")}
        }
    }
    if count==0 {return ""}
    more:=count>AI_REVIEW_STAYS?fmt.tprintf(" and %d more",count-AI_REVIEW_STAYS):""
    return fmt.tprintf("%d %s as %s: %s%s",count,count==1?"entity stays":"entities stay",count==1?"it is":"they are",strings.to_string(b),more)
}

// Puts the scene where the record of a turn says: back to before it
// (forward false), newest first, or again to what it left (forward true),
// oldest first. The entities of firm are left as they are. Of the others, an
// entity the turn created goes only when nothing kept hangs from it or names
// it, and one it removed comes back with its id when the id is free; a field
// someone else wrote since is kept and counted as skipped. It is one step
// of undo. False, changing nothing, when the record outgrew the journal and
// the history cannot give all of the turn back.
@(private="file")
ai_review_apply :: proc(s:^Session,task:^Ai_Task,forward:bool,firm:[]base.Entity_Id) -> bool {
    w:=edited_world(s)
    label:=forward?"Restore agent task":"Revert agent task"
    sets:=task.review.transactions[:]
    taken:[dynamic]history.Change_Set
    defer {
        for &set in taken {history.change_set_free(&set)}
        delete(taken)
    }
    if task.review.incomplete {
        if !ai_review_history_sets(s,&task.review,&taken) {return false}
        sets=taken[:]
    }
    if len(firm)>0 {
        // The same sets without the rows of what is firm: they share the bytes of the record.
        partial:=make([]history.Change_Set,len(sets),context.temp_allocator)
        for &set,i in sets {
            partial[i]={state=set.state,files=set.files,rows=make([dynamic]history.Change_Row,0,len(set.rows),context.temp_allocator)}
            for row in set.rows {
                if !slice.contains(firm,row.id) {append(&partial[i].rows,row)}
            }
        }
        sets=partial
    }
    tools_release(s)
    history.edits_cancel(s.edits,w)
    history.edits_begin(s.edits,s.selection,label)
    task.review.skipped+=change_sets_apply(s,sets,forward,label)
    history.edits_end(s.edits)
    if history.edits_commit(s.edits,w,s.selection) {append(&task.review.moves,s.edits.serial)}
    history.selection_prune(s.selection,w)
    return true
}

// Whether Revert and Restore can put the whole turn back: from its record,
// or, when the record outgrew the journal, from the steps of the history,
// while it keeps all of them and they hold plain data.
ai_review_revertible :: proc(s:^Session,review:^Ai_Review) -> bool {
    if !review.incomplete {return true}
    if s.edits==nil || len(review.states)==0 {return false}
    for state in review.states {if history.edits_step_index(s.edits,state)<0 {return false}}
    return true
}

// The changes of a turn whose record outgrew the journal, one set per step,
// taken again from the history without the limits of the record.
@(private="file")
ai_review_history_sets :: proc(s:^Session,review:^Ai_Review,sets:^[dynamic]history.Change_Set) -> bool {
    for state in review.states {
        index:=history.edits_step_index(s.edits,state)
        if index<0 {return false}
        set:history.Change_Set
        complete:=history.change_set_take(edited_world(s),s.project_root,&set,&s.edits.steps[index],s.edits.steps[:])
        append(sets,set)
        if !complete {return false}
    }
    return true
}

// The record of a turn follows the scene when its document is read again
// (its file changed outside the editor, as a discard does): a scene without
// the changes of the turn has them declined, to be taken back; one that
// holds them has them waiting for review again. A scene with part of them
// stays as the record says.
ai_review_reconcile :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    if len(task.review.transactions)==0 || task.world==nil || task.world!=s.edit_world || !ai_task_current(s,task) {return}
    w:=edited_world(s)
    Key :: struct {id:base.Entity_Id,table:int}
    first:=make(map[Key]^history.Change_Row,context.temp_allocator)
    last:=make(map[Key]^history.Change_Row,context.temp_allocator)
    for &transaction in task.review.transactions {
        for &row in transaction.rows {
            key:=Key{row.id,row.table}
            if key not_in first {first[key]=&row}
            last[key]=&row
        }
    }
    holds :: proc(world:^core.World_Info,info:^runtime.Type_Info,has,off:bool,canonical:[]u8,present,expected_off:bool,value:[]u8) -> bool {
        return has==present && (!has || off==expected_off && history.change_equal(world,info,raw_data(canonical),raw_data(value)))
    }
    before,after:=true,true
    for key,oldest in first {
        descriptor:=&w.info.tables[key.table]
        current:rawptr
        off:bool
        if e:=history.change_entity(w,key.id);e!=core.NONE {
            table:=core.world_table_at(w,descriptor)
            current=core.raw_find(table,descriptor.info,e)
            _,off,_=core.raw_state(table,e)
        }
        canonical:[]u8
        if current!=nil {canonical=history.change_canonical(w,nil,descriptor.info,current,context.temp_allocator)}
        newest:=last[key]
        before&&=holds(w.info,descriptor.info,current!=nil,off,canonical,oldest.before_present,oldest.before_off,oldest.before)
        after&&=holds(w.info,descriptor.info,current!=nil,off,canonical,newest.after_present,newest.after_off,newest.after)
    }
    for path in task.review.changed_files {
        span,_:=ai_review_file_span(&task.review,path)
        full:=project.path(s.project_root,path,allocator=context.temp_allocator)
        before&&=history.file_holds(files_registry(s),full,span.first.before_present,span.first.before)
        after&&=history.file_holds(files_registry(s),full,span.last.after_present,span.last.after)
    }
    switch {
    case after && task.declined:
        task.declined,task.undone,task.review_finished=false,false,false
        task.review.pending=ai_review_waiting(&task.review)>0
    case before && !after && !task.declined && task.review.pending:
        task.declined,task.undone,task.review_finished=true,true,true
        task.review.pending=false
        task.question=.None
        ai_transcript_add(&task.transcript,AI_UNDONE_NOTE,.Note)
    case:
        return
    }
    ai_task_dirty(task);ai_task_persist(s,task)
    m.scene_serial+=1
}

// Revision of one entity, and of one field of it: what the panel walks
// through and what Details offers while a turn waits for the user. An entity
// is resolved when its rows leave the record; the turn stops waiting when no
// entity is left.

// A row of a review waiting on the user that belongs to the entity Details
// shows. The list is made again only when a review or that entity change.
Ai_Review_Mark :: struct {task,transaction,row:int}

@(private)
ai_review_marks :: proc(m:^Ai,id:base.Entity_Id) -> []Ai_Review_Mark {
    if m==nil || id==0 {return nil}
    if m.marks_id!=id || m.marks_serial!=m.scene_serial {
        clear(&m.marks)
        m.marks_id,m.marks_serial=id,m.scene_serial
        for &task in m.tasks[:m.task_count] {
            if !ai_task_reviewable(&task) {continue}
            for &transaction,t in task.review.transactions {
                for row,r in transaction.rows {if row.id==id {append(&m.marks,Ai_Review_Mark{task.id,t,r})}}
            }
        }
    }
    return m.marks[:]
}

// The task and the row of a mark, checked against what the review holds now.
@(private)
ai_review_mark_row :: proc(s:^Session,m:^Ai,mark:Ai_Review_Mark,id:base.Entity_Id) -> (task:^Ai_Task,row:^history.Change_Row,ok:bool) {
    task=ai_task_find(m,mark.task)
    if task==nil || !ai_task_reviewable(task) || !ai_task_current(s,task) || mark.transaction>=len(task.review.transactions) {return}
    rows:=&task.review.transactions[mark.transaction].rows
    if mark.row>=len(rows) || rows[mark.row].id!=id {return}
    return task,&rows[mark.row],true
}

@(private)
ai_review_table_index :: proc(w:core.World_Ref,t:^core.Table_Info) -> int {
    for &descriptor,index in w.info.tables {if &descriptor==t {return index}}
    return -1
}

// The turns waiting on the user that changed this entity, each once.
ai_review_tasks_of :: proc(s:^Session,m:^Ai,w:core.World_Ref,e:core.Entity,out:[]int) -> int {
    if m==nil || s.mode!=.Edit {return 0}
    id:=api_entity_id(w,e)
    count:=0
    for mark in ai_review_marks(m,id) {
        task,_,ok:=ai_review_mark_row(s,m,mark,id)
        if !ok {continue}
        seen:=false
        for known in out[:count] {if known==task.id {seen=true;break}}
        if !seen && count<len(out) {out[count]=task.id;count+=1}
    }
    return count
}

// The turn that changed any field of this component of this entity.
ai_review_component :: proc(s:^Session,m:^Ai,w:core.World_Ref,t:^core.Table_Info,e:core.Entity) -> (task:^Ai_Task,ok:bool) {
    if m==nil || t==nil || e==core.NONE || s.mode!=.Edit {return}
    id:=api_entity_id(w,e)
    table:=ai_review_table_index(w,t)
    for mark in ai_review_marks(m,id) {
        found,row,valid:=ai_review_mark_row(s,m,mark,id)
        if valid && row.table==table {return found,true}
    }
    return
}

// The turn that changed this field of this entity and still waits. Only a
// field the turn changed on an entity that existed before and after it is
// offered, and never one that holds an entity reference: those bytes are an
// authoring id, not a handle.
ai_review_field :: proc(s:^Session,m:^Ai,w:core.World_Ref,t:^core.Table_Info,e:core.Entity,offset,size:int) -> (task:^Ai_Task,ok:bool) {
    if m==nil || t==nil || e==core.NONE || s.mode!=.Edit || size<=0 || offset<0 || offset+size>t.info.size {return}
    for at in entity_offsets(t.info) {
        if int(at)<offset+size && offset<int(at)+size_of(core.Entity) {return}
    }
    id:=api_entity_id(w,e)
    table:=ai_review_table_index(w,t)
    owner:^Ai_Task
    for mark in ai_review_marks(m,id) {
        found,row,valid:=ai_review_mark_row(s,m,mark,id)
        if !valid || row.table!=table {continue}
        if owner!=nil && found!=owner {continue}
        if !row.before_present || !row.after_present {return nil,false}
        if !slice.equal(row.before[offset:][:size],row.after[offset:][:size]) {owner=found}
    }
    return owner,owner!=nil
}

// Puts the field back to the value it had before the turn, when what the
// turn left is still there, and forgets that change: the rest of the turn
// stays. kept: someone wrote the field afterwards and their value stays.
ai_review_field_revert :: proc(s:^Session,m:^Ai,w:core.World_Ref,t:^core.Table_Info,entities:[]core.Entity,offset,size:int) -> (restored,kept:bool) {
    active:=len(entities)>0?entities[len(entities)-1]:core.NONE
    task,ok:=ai_review_field(s,m,w,t,active,offset,size)
    if !ok {return}
    id:=api_entity_id(w,active)
    table:=ai_review_table_index(w,t)
    review:=&task.review
    // What the field had before the first change of the turn and what the
    // last one left.
    first,last:^history.Change_Row
    for &transaction in review.transactions {
        for &row in transaction.rows {
            if row.id!=id || row.table!=table {continue}
            if first==nil {first=&row}
            last=&row
        }
    }
    if first==nil {return}
    current:=cast([^]u8)core.raw_find(core.world_table_at(w,t),t.info,active)
    if current!=nil && slice.equal(current[offset:][:size],last.after[offset:][:size]) {
        restored=field_write(s,t,{active},offset,first.before[offset:][:size])
        // Its step is of the review, not of another author that makes the entity firm.
        if restored && history.edits_commit(s.edits,w,document_selection(s)) {append(&review.moves,s.edits.serial)}
    } else {
        kept=true
        review.skipped+=1
    }
    for &transaction in review.transactions {
        for i:=len(transaction.rows)-1;i>=0;i-=1 {
            row:=&transaction.rows[i]
            if row.id!=id || row.table!=table {continue}
            copy(row.after[offset:][:size],row.before[offset:][:size])
            if row.before_off==row.after_off && history.change_equal(w.info,t.info,raw_data(row.before),raw_data(row.after)) {ai_review_row_remove(review,&transaction,i)}
        }
    }
    ai_review_settle(s,m,task)
    return
}

// Whether the turn deleted an entity and it is still gone: kept or undone, it is not.
ai_review_deleted :: proc(w:core.World_Ref,task:^Ai_Task,id:base.Entity_Id) -> bool {
    if history.change_entity(w,id)!=core.NONE {return false}
    #reverse for &transaction in task.review.transactions {
        for &row in transaction.rows {
            if row.id!=id || row.table<0 || row.table>=len(w.info.tables) || w.info.tables[row.table].type!=core.Id {continue}
            return row.before_present && !row.after_present
        }
    }
    return false
}

// A component of an entity the turn deleted as it was before, in its
// canonical form: its Entity fields hold the ids of what they named.
ai_review_deleted_value :: proc(w:core.World_Ref,task:^Ai_Task,id:base.Entity_Id,$T:typeid) -> (value:T,ok:bool) {
    #reverse for &transaction in task.review.transactions {
        for &row in transaction.rows {
            if row.id!=id || row.table<0 || row.table>=len(w.info.tables) || w.info.tables[row.table].type!=T {continue}
            if !row.before_present || row.after_present || len(row.before)!=size_of(T) {return}
            mem.copy(&value,raw_data(row.before),size_of(T))
            return value,true
        }
    }
    return
}

// Where an entity the turn deleted was in the world: through the parent that
// is still there, or the one deleted with it.
ai_review_deleted_world :: proc(w:core.World_Ref,task:^Ai_Task,id:base.Entity_Id,depth:int) -> (place:mm.Transform,ok:bool) {
    if depth>64 || !ai_review_deleted(w,task,id) {return}
    local,has:=ai_review_deleted_value(w,task,id,core.Transform)
    if !has {return}
    place=core.to_math(local)
    if parent,child:=ai_review_deleted_value(w,task,id,core.Parent);child {
        parent_id:base.Entity_Id
        mem.copy(&parent_id,&parent.entity,size_of(parent_id))
        if e:=history.change_entity(w,parent_id);e!=core.NONE {
            place=mm.transform_compose(entity_world(w,e),place)
        } else if outer,found:=ai_review_deleted_world(w,task,parent_id,depth+1);found {
            place=mm.transform_compose(outer,place)
        }
    }
    return place,true
}

// The last transaction of the turn that deleted an entity: its rows hold
// what the entity was.
@(private)
ai_review_deletion :: proc(w:core.World_Ref,task:^Ai_Task,id:base.Entity_Id) -> ^history.Change_Set {
    #reverse for &transaction in task.review.transactions {
        for &row in transaction.rows {
            if row.id!=id || row.table<0 || row.table>=len(w.info.tables) || w.info.tables[row.table].type!=core.Id {continue}
            if row.before_present && !row.after_present {return &transaction}
        }
    }
    return nil
}

// Its name, for the review of a deletion.
ai_review_deleted_name :: proc(w:core.World_Ref,task:^Ai_Task,id:base.Entity_Id) -> string {
    name,named:=ai_review_deleted_value(w,task,id,core.Name)
    if !named {return "Entity"}
    return strings.clone(base.text_get(name.text[:]),context.temp_allocator)
}

// Puts back an entity the turn deleted as it was before it, with its id;
// its parent has to be in the scene. What hung from it stays deleted until
// it is put back too.
ai_review_entity_restore :: proc(s:^Session,m:^Ai,task:^Ai_Task,id:base.Entity_Id) -> string {
    if s.mode!=.Edit {return "Stop Play before reverting scene changes"}
    if !ai_task_current(s,task) {return "Open the task's document before reverting"}
    w:=edited_world(s)
    if !ai_review_deleted(w,task,id) {return "That entity is already in the scene"}
    if parent,child:=ai_review_deleted_value(w,task,id,core.Parent);child {
        parent_id:base.Entity_Id
        mem.copy(&parent_id,&parent.entity,size_of(parent_id))
        if parent_id!=0 && history.change_entity(w,parent_id)==core.NONE {
            return fmt.tprintf("Put back %s first: it was the parent of this entity",ai_review_deleted_name(w,task,parent_id))
        }
    }
    transaction:=ai_review_deletion(w,task,id)
    opened,edit_ready:=edit_open(s,"Restore agent deletion")
    if !edit_ready {return history.edits_error_text(s.edits.error)}
    defer edit_close(s,opened)
    e:=core.create(core.world_entities(w))
    core.add(core.world_table_of(w,core.Id),e,core.Id{id})
    core.world_settle(w)
    for &row in transaction.rows {
        if row.id!=id || !row.before_present || row.after_present || row.table<0 || row.table>=len(w.info.tables) {continue}
        descriptor:=&w.info.tables[row.table]
        if descriptor.type==core.Id {continue}
        restored:=history.change_materialize(w,descriptor.info,row.before)
        table:=core.world_table_at(w,descriptor)
        core.raw_add(table,descriptor.info,e,raw_data(restored))
        if row.before_off {core.raw_disable(table,e)}
    }
    core.world_settle(w)
    ai_review_entity_forget(&task.review,id)
    ai_review_settle(s,m,task)
    return ""
}

// Keeps what the turn did to one entity: its rows leave the record.
ai_review_entity_accept :: proc(s:^Session,m:^Ai,task:^Ai_Task,id:base.Entity_Id) {
    task.kept+=1
    ai_review_entity_forget(&task.review,id)
    ai_review_settle(s,m,task)
}

// Puts back what the turn did to one entity, newest first: the values it
// wrote, the components it added, removed or turned off or on. What others
// wrote afterwards stays. An entity the turn created or deleted belongs to the
// revert of the whole turn, which resolves what depends on it.
ai_review_entity_revert :: proc(s:^Session,m:^Ai,task:^Ai_Task,id:base.Entity_Id) -> string {
    // Counted before the settle that may end the review and write its note.
    task.rejected+=1
    message:=ai_review_entity_put_back(s,m,task,id)
    if message!="" {task.rejected-=1}
    return message
}

@(private)
ai_review_entity_put_back :: proc(s:^Session,m:^Ai,task:^Ai_Task,id:base.Entity_Id) -> string {
    if s.mode!=.Edit {return "Stop Play before reverting scene changes"}
    if !ai_task_current(s,task) {return "Open the task's document before reverting"}
    w:=edited_world(s)
    if ai_review_deleted(w,task,id) {return ai_review_entity_restore(s,m,task,id)}
    e:=history.change_entity(w,id)
    if e==core.NONE {return "That entity is no longer in the scene"}
    if slice.contains(ai_review_firm(s,task),id) {return fmt.tprintf("%s stays as it is: it was changed by someone else after the agent",entity_label(w,e))}
    for &transaction in task.review.transactions {
        for &row in transaction.rows {
            if row.id==id && row.table>=0 && row.table<len(w.info.tables) && w.info.tables[row.table].type==core.Id && !row.before_present {return ai_review_entity_take_out(s,m,task,id,e)}
        }
    }
    opened,edit_ready:=edit_open(s,"Revert agent entity")
    if !edit_ready {return history.edits_error_text(s.edits.error)}
    defer edit_close(s,opened)
    #reverse for &transaction in task.review.transactions {
        for &row in transaction.rows {
            if row.id!=id {continue}
            if row.table<0 || row.table>=len(w.info.tables) {task.review.skipped+=1;continue}
            history.change_row_put(w,&row,e,false,&task.review.skipped)
        }
        core.world_settle(w)
    }
    ai_review_entity_forget(&task.review,id)
    ai_review_settle(s,m,task)
    return ""
}

// Keeps what the turn did to one file: it leaves the record.
ai_review_file_accept :: proc(s:^Session,m:^Ai,task:^Ai_Task,path:string) {
    task.kept+=1
    ai_review_file_forget(&task.review,path)
    ai_review_settle(s,m,task)
}

// Puts back what one file held before the turn while it holds what the turn
// left; what someone wrote after the turn stays and counts as skipped. The
// file leaves the record either way. One step of undo.
ai_review_file_revert :: proc(s:^Session,m:^Ai,task:^Ai_Task,path:string) -> string {
    // Counted before the settle that may end the review and write its note.
    task.rejected+=1
    message:=ai_review_file_put_back(s,m,task,path)
    if message!="" {task.rejected-=1}
    return message
}

@(private)
ai_review_file_put_back :: proc(s:^Session,m:^Ai,task:^Ai_Task,path:string) -> string {
    if s.mode!=.Edit {return "Stop Play before reverting the files of a task"}
    span,found:=ai_review_file_span(&task.review,path)
    if !found {return "The task did not change that file"}
    if !change_file_side(s,path,span.last.after_present,span.last.after,span.first.before_present,span.first.before,"Revert agent file") {
        // Another turn changed it after this one: its change goes first.
        if other:=ai_code_other(m,task,path);other!=nil {return fmt.tprintf("\"%s\" changed %s after this turn: revert its change first",base.text_get(other.title[:]),path)}
        task.review.skipped+=1
    }
    ai_review_file_forget(&task.review,path)
    ai_review_settle(s,m,task)
    return ""
}

@(private)
ai_review_file_forget :: proc(review:^Ai_Review,path:string) {
    for &transaction in review.transactions {
        for i:=len(transaction.files)-1;i>=0;i-=1 {
            file:=&transaction.files[i]
            if file.path!=path {continue}
            review.bytes-=len(file.before)+len(file.after)
            review.rows-=1
            history.change_file_free(file)
            ordered_remove(&transaction.files,i)
        }
    }
}

@(private)
ai_review_row_remove :: proc(review:^Ai_Review,transaction:^history.Change_Set,index:int) {
    row:=&transaction.rows[index]
    review.bytes-=len(row.before)+len(row.after)
    review.rows-=1
    delete(row.before);delete(row.after)
    ordered_remove(&transaction.rows,index)
}

// Takes out an entity the turn created, with what hangs from it; the
// entities of the turn that go with it stop asking for review.
@(private)
ai_review_entity_take_out :: proc(s:^Session,m:^Ai,task:^Ai_Task,id:base.Entity_Id,e:core.Entity) -> string {
    w:=edited_world(s)
    alive:=make([dynamic]base.Entity_Id,context.temp_allocator)
    for changed in task.review.changed_ids {
        if history.change_entity(w,changed)!=core.NONE {append(&alive,changed)}
    }
    entities_delete(s,{e})
    if history.change_entity(w,id)!=core.NONE {return "The entity could not be taken out: it is held by a prefab or by another editor"}
    for changed in alive {
        if history.change_entity(w,changed)==core.NONE {ai_review_entity_forget(&task.review,changed)}
    }
    ai_review_settle(s,m,task)
    return ""
}

// The rows of an entity leave the record, and with the last one its id.
@(private)
ai_review_entity_forget :: proc(review:^Ai_Review,id:base.Entity_Id) {
    for &transaction in review.transactions {
        for i:=len(transaction.rows)-1;i>=0;i-=1 {
            if transaction.rows[i].id==id {ai_review_row_remove(review,&transaction,i)}
        }
    }
}

// What is left of a review after resolving part of it: empty transactions go,
// an entity without rows and a file without changes stop being
// changed, the outlines follow, the file is written again with the next
// flush, and a turn with nothing left stops asking for review.
@(private)
ai_review_settle :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    review:=&task.review
    for i:=len(review.transactions)-1;i>=0;i-=1 {
        if !history.change_set_empty(&review.transactions[i]) {continue}
        history.change_set_free(&review.transactions[i])
        ordered_remove(&review.transactions,i)
    }
    for i:=len(review.changed_files)-1;i>=0;i-=1 {
        if _,held:=ai_review_file_span(review,review.changed_files[i]);held {continue}
        delete(review.changed_files[i])
        ordered_remove(&review.changed_files,i)
    }
    for i:=len(review.changed_ids)-1;i>=0;i-=1 {
        id:=review.changed_ids[i]
        held:=false
        for &transaction in review.transactions {
            for row in transaction.rows {if row.id==id {held=true;break}}
            if held {break}
        }
        if !held {ordered_remove(&review.changed_ids,i)}
    }
    review.pending=ai_review_waiting(review)>0
    m.scene_serial+=1
    ai_task_dirty(task);ai_task_persist(s,task)
    // Nothing left to keep or put back: the turn is done, as Accept all leaves it.
    if !review.pending && (task.context_count==0 || ai_review_count(task)==0) && ai_task_finished(task) {ai_task_finish(s,m,task)}
}
