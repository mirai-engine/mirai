package editor

import "core:fmt"
import "core:slice"
import "core:strings"

// Undo and redo of one author (Edits.author: the user, or the author of a
// method of the API while it runs). Undo takes back the newest step of the
// author, and redo brings again the step its newest undo took back, whatever
// others did after it: in order while the history can exchange the step with
// the World (undo, redo in edits.odin), otherwise by the ids of its entities
// in a step of the author of its own, which keeps what others wrote since
// (change sets). A step that wrote a prefab file goes only in order: the
// instances it brought up to date follow that file. The steps of the
// selection of the author go back and forward between them in the order they
// were made (edits_selection.odin).

History_Move :: struct {
    done:bool,    // the history moved, or a preview was cancelled
    label:string, // of the step taken back or brought again
    kept:int,     // fields, components, entities and files left as others wrote them
    error:string, // why nothing moved; empty when there was nothing to move
}

history_undo :: proc(s:^Session) -> (move:History_Move) {
    edits,w,selection:=s.edits,edited_world(s),document_selection(s)
    if edits.preview && w.data==edits.world {
        move.done=undo(edits,w,selection)
        return
    }
    if w.data!=edits.world {return}
    edits_select(edits,w,selection)
    if at,first:=selection_undo_first(edits);first {
        move.label=strings.clone(cstring_text(edits.selections[at].label[:]),context.temp_allocator)
        move.done=selection_step_move(edits,w,selection,at,false)
        if !move.done {move.error=history_error(edits)}
        return
    }
    index:=edits_undo_index(edits)
    if index<0 || w.data!=edits.world {return}
    state:=edits.steps[index].state
    move.label=strings.clone(edits_label(&edits.steps[index]),context.temp_allocator)
    if undo(edits,w,selection) {move.done=true;return}
    if edits.error!=.Interleaved {move.error=history_error(edits);return}
    return history_by_ids(s,state,false)
}

history_redo :: proc(s:^Session) -> (move:History_Move) {
    edits,w,selection:=s.edits,edited_world(s),document_selection(s)
    if edits.preview && w.data==edits.world {
        move.done=redo(edits,w,selection)
        return
    }
    if w.data!=edits.world {return}
    edits_select(edits,w,selection)
    if at,first:=selection_redo_first(edits);first {
        move.label=strings.clone(cstring_text(edits.selections[at].label[:]),context.temp_allocator)
        move.done=selection_step_move(edits,w,selection,at,true)
        if !move.done {move.error=history_error(edits)}
        return
    }
    index:=edits_redo_index(edits)
    if index<0 || w.data!=edits.world {return}
    state:=edits.steps[index].state
    move.label=strings.clone(edits_label(&edits.steps[index]),context.temp_allocator)
    if redo(edits,w,selection) {move.done=true;return}
    if edits.error!=.Interleaved {move.error=history_error(edits);return}
    return history_by_ids(s,state,true)
}

// What a toast says of a move of the history: verb Undo or Redo.
history_text :: proc(move:History_Move,verb:string) -> string {
    switch {
    case move.error!="":  return move.error
    case move.label=="":  return ""
    case move.kept==1:    return fmt.tprintf("%s %s; one change of another author stays",verb,move.label)
    case move.kept>1:     return fmt.tprintf("%s %s; %d changes of other authors stay",verb,move.label,move.kept)
    }
    return fmt.tprintf("%s %s",verb,move.label)
}

@(private="file")
history_error :: proc(edits:^Edits) -> string {
    if text:=edits_error_text(edits.error);text!="" {return text}
    return "Finish or cancel the edit in progress first"
}

// Takes back (forward false) or brings again (forward true) the step of a
// state by the ids of its entities, in a step of its own.
@(private="file")
history_by_ids :: proc(s:^Session,state:u64,forward:bool) -> (move:History_Move) {
    edits,w,selection:=s.edits,edited_world(s),document_selection(s)
    index:=edits_step_index(edits,state)
    if index<0 {return}
    step:=&edits.steps[index]
    move.label=strings.clone(edits_label(step),context.temp_allocator)
    if history_prefab_step(step) {
        move.error=fmt.tprintf("%s only undoes and redoes in order, and others edited after it: it wrote a prefab that the instances of the scene follow; make the opposite change by hand (revert or apply the prefab again)",move.label)
        return
    }
    set:Change_Set
    defer change_set_free(&set)
    if !change_set_take(s,&set,step,edits.steps[:]) {
        move.error=fmt.tprintf("%s only undoes and redoes in order, and others edited after it: its components are not plain data; change them back by hand",move.label)
        return
    }
    selected:=slice.clone(step.after[:] if forward else step.before[:],context.temp_allocator)
    label:=move.label if forward else fmt.tprintf("Undo %s",move.label)
    edits_cancel(edits,w)
    if edits.open || edits.commit || edits.preview || !edits_begin(edits,selection,label) {move.error=history_error(edits);return}
    if error:=edits_cancel_prepare(edits,w);error!=.None {
        edits.open=false
        move.error=edits_error_text(error)
        return
    }
    sets:=[1]Change_Set{set}
    move.kept=change_sets_apply(s,sets[:],forward,label)
    edits_end(edits)
    prepared,error:=edits_prepare(edits,w,selection)
    defer edits_preparation_destroy(&prepared)
    if error==.None {
        prepared.step.kind,prepared.step.target=.Redo if forward else .Undo,state
        error=edits_commit_prepared(edits,w,&prepared)
    }
    if error!=.None && error!=.No_Change {
        edits_cancel(edits,w)
        selection_restore(selection,w,edits.selection[:])
        edits_selection_take(edits,selection)
        move.error=edits_error_text(error)
        return
    }
    // An undo leaves the step waiting for redo; a redo that changed nothing
    // (the World holds what the step did, or others changed all of it) makes
    // it stand again, and one that changed something stands for it.
    if index=edits_step_index(edits,state);index>=0 {
        step=&edits.steps[index]
        step.undone=0
        switch {
        case !forward:
            step.reverted=true
            edits.order+=1
            step.undone=edits.order
        case error==.No_Change:
            step.reverted=false
        }
    }
    selection_restore(selection,w,selected)
    edits_selection_take(edits,selection)
    if forward {edits.stats.redos+=1} else {edits.stats.undos+=1}
    move.done=true
    return
}

// Whether a step wrote a prefab file.
@(private="file")
history_prefab_step :: proc(step:^Edit_Step) -> bool {
    for &file in step.files {
        if strings.has_suffix(file.path,PREFAB_EXTENSION) {return true}
    }
    return false
}
