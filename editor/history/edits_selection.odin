package history

import "core:fmt"
import "core:slice"
import "mirai:core"

// Steps of the selection: what the user or a call selects is a step of undo
// of its author, apart from the steps of the World (it changes no row, and
// collaboration, the review of a turn and the saved state do not read it).
// Edits.selected is the selection as the history knows it: a step that
// selects (edits_publish_prepared), an undo or a redo leave it there, and
// edits_select makes a step of what differs. The steps of the selection and
// of the World are taken back in the order they were made: a step of the
// selection made is newer than the steps up to that state.

EDITS_SELECTION_CAPACITY :: 256 // steps of the selection kept: the oldest goes first

Selection_Step :: struct {
    label:[EDIT_LABEL_BYTES]u8,
    before,after:[dynamic]core.Entity, // the active entity last
    author:Edit_Author,
    made:u64,   // Edits.serial when it was made
    undone:u64, // while its author can redo it, the order of the undo that took it back
}

// Records what selection changed since the history knew it as a step of the
// author of the edits. What only lost entities that are gone (w given), and
// the first selection after the history was reset, are taken without one.
edits_select :: proc(edits:^Edits,w:core.World_Ref,selection:^Selection) {
    if selection==nil || edits.open || edits.commit || edits.preview || w.data!=nil && w.data!=edits.world {return}
    if edits.selected_known && edits.selected_serial==selection.serial {return}
    if !edits.selected_known || slice.equal(edits.selected[:],selection.entities[:]) || w.data!=nil && selection_pruned_from(w,edits.selected[:],selection.entities[:]) {
        edits_selection_take(edits,selection)
        return
    }
    label:string
    switch len(selection.entities) {
    case 0: label="Deselect"
    case 1:
        label="Select"
        if w.data!=nil {
            e:=selection.entities[0]
            name:=""
            if names:=core.world_table_of(w,core.Name);names!=nil {name=core.name_get(names,e)}
            label=fmt.tprintf("Select %s",name) if name!="" else fmt.tprintf("Select Entity %d",core.entity_index(e))
        }
    case:   label=fmt.tprintf("Select %d entities",len(selection.entities))
    }
    step:=Selection_Step{author=edits.author,made=edits.serial}
    text_put(step.label[:],label)
    _,before_failed:=append(&step.before,..edits.selected[:])
    _,after_failed:=append(&step.after,..selection.entities[:])
    if failed:=reserve(&edits.selections,len(edits.selections)+1);before_failed!=nil || after_failed!=nil || failed!=nil {
        selection_step_free(&step)
        edits_selection_take(edits,selection)
        return
    }
    edits_redo_drop(edits,step.author)
    append(&edits.selections,step)
    for len(edits.selections)>EDITS_SELECTION_CAPACITY {
        selection_step_free(&edits.selections[0])
        ordered_remove(&edits.selections,0)
    }
    edits_selection_take(edits,selection)
}

// The history knows the selection as it is. edits.selected must have room.
edits_selection_take :: proc(edits:^Edits,selection:^Selection) {
    if resize(&edits.selected,len(selection.entities))!=nil {
        edits.selected_known=false
        return
    }
    copy(edits.selected[:],selection.entities[:])
    edits.selected_serial,edits.selected_known=selection.serial,true
}

// A new step of an author drops what it could redo: its steps undone in
// order, which leave the history, and the redo by ids of the others.
@(private)
edits_redo_drop :: proc(edits:^Edits,author:Edit_Author) {
    kept:=edits.cursor
    for i in edits.cursor..<len(edits.steps) {
        step:=edits.steps[i]
        if step.author==author {
            edits.bytes-=step.bytes
            step_free(&step)
            continue
        }
        edits.steps[kept]=step
        kept+=1
    }
    resize(&edits.steps,kept)
    for &step in edits.steps {if step.author==author {step.undone=0}}
    edits_selection_redo_drop(edits,author)
}

@(private)
edits_selection_redo_drop :: proc(edits:^Edits,author:Edit_Author) {
    kept:=0
    for &step in edits.selections {
        if step.author==author && step.undone>0 {selection_step_free(&step);continue}
        edits.selections[kept]=step
        kept+=1
    }
    resize(&edits.selections,kept)
}

// The newest step of the selection of the author of the edits that stands; -1 without one.
@(private)
selection_undo_index :: proc(edits:^Edits) -> int {
    for i:=len(edits.selections)-1;i>=0;i-=1 {
        if step:=&edits.selections[i];step.author==edits.author && step.undone==0 {return i}
    }
    return -1
}

// The step of the selection the newest undo of the author took back; -1 without one.
@(private)
selection_redo_index :: proc(edits:^Edits) -> int {
    index,order:=-1,u64(0)
    for &step,i in edits.selections {
        if step.author==edits.author && step.undone>order {index,order=i,step.undone}
    }
    return index
}

// Whether undo takes back a step of the selection before the step of the
// World it would take: the one made after.
selection_undo_first :: proc(edits:^Edits) -> (index:int,first:bool) {
    index=selection_undo_index(edits)
    if index<0 {return}
    edit:=edits_undo_index(edits)
    return index,edit<0 || edits.selections[index].made>=edits.steps[edit].state
}

// Whether redo brings again a step of the selection: the one an undo took back after.
selection_redo_first :: proc(edits:^Edits) -> (index:int,first:bool) {
    index=selection_redo_index(edits)
    if index<0 {return}
    edit:=edits_redo_index(edits)
    return index,edit<0 || edits.selections[index].undone>edits.steps[edit].undone
}

// Takes back (forward false) or brings again a step of the selection.
selection_step_move :: proc(edits:^Edits,w:core.World_Ref,selection:^Selection,index:int,forward:bool) -> bool {
    edits_cancel(edits,w)
    if edits.open || edits.commit || edits.preview {return false}
    step:=&edits.selections[index]
    selection_restore(selection,w,step.after[:] if forward else step.before[:])
    if forward {
        step.undone=0
    } else {
        edits.order+=1
        step.undone=edits.order
    }
    edits_selection_take(edits,selection)
    return true
}

// Whether after is before without the entities that are gone, in its order.
@(private)
selection_pruned_from :: proc(w:core.World_Ref,before,after:[]core.Entity) -> bool {
    es:=core.world_entities(w)
    at:=0
    for e in before {
        if !core.alive(es,e) {continue}
        if at>=len(after) || after[at]!=e {return false}
        at+=1
    }
    return at==len(after)
}

@(private)
selection_step_free :: proc(step:^Selection_Step) {
    delete(step.before);delete(step.after)
    step^={}
}
