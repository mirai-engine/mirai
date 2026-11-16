package editor

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:editor/history"
import "mirai:std/base"

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
        move.done=history.undo(edits,w,selection)
        return
    }
    if w.data!=edits.world {return}
    history.edits_select(edits,w,selection)
    if at,first:=history.selection_undo_first(edits);first {
        move.label=strings.clone(history.cstring_text(edits.selections[at].label[:]),context.temp_allocator)
        move.done=history.selection_step_move(edits,w,selection,at,false)
        if !move.done {move.error=history_error(edits)}
        return
    }
    index:=history.edits_undo_index(edits)
    if index<0 || w.data!=edits.world {return}
    state:=edits.steps[index].state
    move.label=strings.clone(history.edits_label(&edits.steps[index]),context.temp_allocator)
    if history.undo(edits,w,selection) {move.done=true;return}
    if edits.error!=.Interleaved {move.error=history_error(edits);return}
    return history_by_ids(s,state,false)
}

history_redo :: proc(s:^Session) -> (move:History_Move) {
    edits,w,selection:=s.edits,edited_world(s),document_selection(s)
    if edits.preview && w.data==edits.world {
        move.done=history.redo(edits,w,selection)
        return
    }
    if w.data!=edits.world {return}
    history.edits_select(edits,w,selection)
    if at,first:=history.selection_redo_first(edits);first {
        move.label=strings.clone(history.cstring_text(edits.selections[at].label[:]),context.temp_allocator)
        move.done=history.selection_step_move(edits,w,selection,at,true)
        if !move.done {move.error=history_error(edits)}
        return
    }
    index:=history.edits_redo_index(edits)
    if index<0 || w.data!=edits.world {return}
    state:=edits.steps[index].state
    move.label=strings.clone(history.edits_label(&edits.steps[index]),context.temp_allocator)
    if history.redo(edits,w,selection) {move.done=true;return}
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
history_error :: proc(edits:^history.Edits) -> string {
    if text:=history.edits_error_text(edits.error);text!="" {return text}
    return "Finish or cancel the edit in progress first"
}

// Takes back (forward false) or brings again (forward true) the step of a
// state by the ids of its entities, in a step of its own.
@(private="file")
history_by_ids :: proc(s:^Session,state:u64,forward:bool) -> (move:History_Move) {
    edits,w,selection:=s.edits,edited_world(s),document_selection(s)
    index:=history.edits_step_index(edits,state)
    if index<0 {return}
    step:=&edits.steps[index]
    move.label=strings.clone(history.edits_label(step),context.temp_allocator)
    if history_prefab_step(step) {
        move.error=fmt.tprintf("%s only undoes and redoes in order, and others edited after it: it wrote a prefab that the instances of the scene follow; make the opposite change by hand (revert or apply the prefab again)",move.label)
        return
    }
    set:history.Change_Set
    defer history.change_set_free(&set)
    if !history.change_set_take(w,s.project_root,&set,step,edits.steps[:]) {
        move.error=fmt.tprintf("%s only undoes and redoes in order, and others edited after it: its components are not plain data; change them back by hand",move.label)
        return
    }
    selected:=slice.clone(step.after[:] if forward else step.before[:],context.temp_allocator)
    label:=move.label if forward else fmt.tprintf("Undo %s",move.label)
    history.edits_cancel(edits,w)
    if edits.open || edits.commit || edits.preview || !history.edits_begin(edits,selection,label) {move.error=history_error(edits);return}
    if error:=history.edits_cancel_prepare(edits,w);error!=.None {
        edits.open=false
        move.error=history.edits_error_text(error)
        return
    }
    sets:=[1]history.Change_Set{set}
    move.kept=change_sets_apply(s,sets[:],forward,label)
    history.edits_end(edits)
    prepared,error:=history.edits_prepare(edits,w,selection)
    defer history.edits_preparation_destroy(&prepared)
    if error==.None {
        prepared.step.kind,prepared.step.target=.Redo if forward else .Undo,state
        error=history.edits_commit_prepared(edits,w,&prepared)
    }
    if error!=.None && error!=.No_Change {
        history.edits_cancel(edits,w)
        history.selection_restore(selection,w,edits.selection[:])
        history.edits_selection_take(edits,selection)
        move.error=history.edits_error_text(error)
        return
    }
    // An undo leaves the step waiting for redo; a redo that changed nothing
    // (the World holds what the step did, or others changed all of it) makes
    // it stand again, and one that changed something stands for it.
    if index=history.edits_step_index(edits,state);index>=0 {
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
    history.selection_restore(selection,w,selected)
    history.edits_selection_take(edits,selection)
    if forward {edits.stats.redos+=1} else {edits.stats.undos+=1}
    move.done=true
    return
}

// Whether a step wrote a prefab file.
@(private="file")
history_prefab_step :: proc(step:^history.Edit_Step) -> bool {
    for &file in step.files {
        if strings.has_suffix(file.path,SCENE_EXTENSION) {return true}
    }
    return false
}

// Takes back what the steps of an author still hold of some entities, by
// their ids, or of every entity with none: in one step of whoever asks,
// newest first, keeping what others wrote since. Returns how many rows it
// went through and how many of their fields, components and entities stayed
// as others left them, or why nothing changed.
history_revert_author :: proc(s:^Session,author:history.Edit_Author,ids:[]base.Entity_Id,label:string) -> (rows,kept:int,message:string) {
    edits,w:=s.edits,edited_world(s)
    if w.data!=edits.world {return 0,0,"A game plays: stop it first"}
    sets:=make([dynamic]history.Change_Set,context.temp_allocator)
    defer for &set in sets {history.change_set_free(&set)}
    steps:=edits.steps[:edits.cursor]
    for &step in steps {
        if step.author!=author || step.reverted || step.swapped || step.kind==.Undo {continue}
        set:history.Change_Set
        if !history.change_set_take(w,s.project_root,&set,&step,steps) {
            history.change_set_free(&set)
            return 0,0,fmt.tprintf("%s cannot be taken back by ids: its components are not plain data; change them back by hand",history.edits_label(&step))
        }
        if len(ids)>0 {
            #reverse for &row,at in set.rows {
                if slice.contains(ids,row.id) {continue}
                delete(row.before);delete(row.after)
                ordered_remove(&set.rows,at)
            }
            for &file in set.files {history.change_file_free(&file)}
            clear(&set.files)
        }
        if history.change_set_empty(&set) {
            history.change_set_free(&set)
            continue
        }
        rows+=len(set.rows)
        append(&sets,set)
    }
    if len(sets)==0 {return 0,0,"That author has no step in the history that holds them"}
    history.edits_cancel(edits,w)
    opened,ready:=edit_open(s,label)
    if !ready {return 0,0,history_error(edits)}
    if error:=history.edits_cancel_prepare(edits,w);error!=.None {
        edits.open=false
        return 0,0,history.edits_error_text(error)
    }
    kept=change_sets_apply(s,sets[:],false,label)
    edit_close(s,opened)
    return
}
