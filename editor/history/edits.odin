package history

import "base:runtime"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:core"

// Undo and redo by rows, over the journal of the edited World (journal.odin).
// A gesture (a drag, a typed value, a command) ends with a commit: the rows
// the World and the image of the journal disagree on, found by core.changes,
// go to a step with what they were, and the image takes what they are, with
// the entities born and gone. Undo and redo exchange the rows and entities of
// a step with what the World has. The tables a scene does not save (state derived by their libraries) drop the rows of the entities
// an undo took away, and their owners derive the rest. The files of the
// project a gesture writes are part of its step (files.odin).
//
// Every step has an author, and undo and redo are those of one: a step keeps
// both of its sides and is exchanged with the World only while it is the last
// one done and the World holds what it left (step_exact). Otherwise the
// history of the author goes back or forward by ids, in a step of its own,
// keeping what others wrote since (history_undo and history_redo of the editor).
//
// Edits made while a Play runs are made to its World and are not kept: the
// history is that of the World of the document.

EDITS_STEP_CAPACITY :: 256    // steps kept: the oldest goes first
EDITS_BYTE_CAPACITY :: 512<<20 // bytes the steps may hold
EDIT_LABEL_BYTES :: 48

// Who makes a step: the user of this editor, an agent by the id of its task,
// or a call of the API outside a task.
Edit_Author :: u64
EDIT_AUTHOR_USER :: Edit_Author(0)
EDIT_AUTHOR_API :: max(Edit_Author)

// A step is an edit, or the undo or the redo by ids of the step of state target.
Edit_Kind :: enum u8 {Edit,Undo,Redo}

// A side of some rows of a table: by entity, a value and whether it was
// turned off by itself, or no row.
Step_Side :: struct {
    present:[dynamic]bool,
    off:[dynamic]bool,
    values:[dynamic]u8, // the size of the component by entity, zero without a row
}

// The rows of a table a step changed, on its two sides: held is what the step
// left in the World where it is, the other what a swap puts back.
Step_Rows :: struct {
    table:int,
    entities:[dynamic]core.Entity,
    using other:Step_Side,
    held:Step_Side,
}

Edit_Step :: struct {
    label:[EDIT_LABEL_BYTES]u8,
    tables:[dynamic]Step_Rows,
    entities:Entity_Changes,
    before,after:[dynamic]core.Entity, // the selection, the active entity last
    files:[dynamic]Edit_File,          // of the project, as the step left them
    state:u64,                         // of the World once the step is done
    bytes:int,
    author:Edit_Author,
    kind:Edit_Kind,
    target:u64,
    swapped:bool,  // undone in order: held is what the step found, the other side what it did
    reverted:bool, // the World does not hold it: a later step took it back, or it left the redo in order
    undone:u64,    // while its author can redo it, the order of the undo that took it back
    turned:u64,    // the turn of the history that last changed what of it the World holds
}

@(storage)
Edits :: struct {
    world:rawptr,                 // the World this history is of
    saved:[dynamic]bool,          // by table of the world info: a scene saves its components
    image:[dynamic]Journal_Table, // by table of the world info
    image_entities:Journal_Entities,
    ranges:[dynamic]Edit_Transient_Ranges, // by table a scene saves
    changes:[dynamic]Journal_Change,       // what the image took since collaboration or the recovery log read, while they read
    changes_first:u64,            // how many changes went before changes[0]
    change_values:[dynamic]u8,    // what the rows of the changes held before, one after another (Journal_Change.value)
    change_values_first:u64,      // how many bytes went before change_values[0]
    reading:bool,                 // collaboration reads the changes
    read_done:u64,                // up to where it read them
    logging:bool,                 // the recovery log of the editor reads the changes
    logged:u64,                   // up to where it wrote them
    steps:[dynamic]Edit_Step,
    cursor:int,               // the steps done are steps[:cursor]; steps[cursor:] were undone in order
    author:Edit_Author,       // of what changes now: a method of the API sets its own while it runs
    opener:Edit_Author,       // of the open gesture
    order:u64,                // the last given to an undo
    serial:u64,               // the last state given out
    initial:u64,              // the state of the World before the first step kept
    epoch:u64,                // changes only when edits_reset takes a World: another document, not a shorter history
    resolved:u64,             // scene.Unresolved_References.written the image last took (sections_resolved)
    turns:u64,                // counts the steps recorded and swapped: what changed the World
    label:[EDIT_LABEL_BYTES]u8,
    open:bool,                // a gesture is open: its edits are one step
    commit:bool,              // the gesture ended: the next safe point records it
    preview:bool,             // only tool_preview_end may confirm this gesture
    selection:[dynamic]core.Entity, // when the gesture opened
    bytes:int,
    stats:Edits_Stats,
    error:Edit_Error,
    cancel_ready:bool,
    cancel_limit:int,
    marks:[dynamic]u8,       // by entity index, for the entities an undo or a cancel turns
    cancel_scratch:[dynamic]u8,
    files:[dynamic]Edit_File, // the open gesture changed them
    registry:^asset.Registry, // whose memory keeps the asset files of the steps (file_write)
    touched:[dynamic]string,  // changed since files_settle loaded them again
    files_kept:int,           // changed outside the editor, they kept their content
    selections:[dynamic]Selection_Step, // steps of the selection (edits_selection.odin)
    selected:[dynamic]core.Entity,      // the selection as the history knows it
    selected_serial:u64,      // Selection.serial when the history took it
    selected_known:bool,      // false after a reset: the next selection is taken without a step
}

Edits_Stats :: struct {steps,compared,discarded,undos,redos:u64}

// The place in the history: the state of the last step done. A step that
// left the redo in order did nothing where it is.
edits_state :: proc(edits:^Edits) -> u64 {
    for i:=edits.cursor-1;i>=0;i-=1 {
        if step:=&edits.steps[i];!step.swapped {return step.state}
    }
    return edits.initial
}

// The state of the World as the history knows it, without the steps that
// only changed files of the project (written as they changed): what a saved
// document compares with.
edits_scene_state :: proc(edits:^Edits) -> u64 {
    for i:=edits.cursor-1;i>=0;i-=1 {
        step:=&edits.steps[i]
        if step.swapped || len(step.tables)==0 && len(step.entities.indices)==0 && len(step.files)>0 {continue}
        return step.state
    }
    return edits.initial
}

edits_label :: proc(step:^Edit_Step) -> string {return cstring_text(step.label[:])}

// Opens a gesture: what changes until edits_end is one step, named label.
// Opening one while another is open keeps the first.
edits_begin :: proc(edits:^Edits,selection:^Selection,label:string) -> bool {
    if edits.open {return true}
    // A selection made before the gesture is a step of its own.
    edits_select(edits,{},selection)
    if resize(&edits.selection,len(selection.entities))!=nil {edits.error=.Memory;return false}
    edits.open=true
    edits.opener=edits.author
    edits.error=.None
    text_put(edits.label[:],label)
    copy(edits.selection[:],selection.entities[:])
    return true
}

// Ends the gesture: the editor records it at the end of the frame, once
// what the functions added and removed is applied. Outside the loop,
// edits_commit records it at once.
edits_end :: proc(edits:^Edits) {
    if edits.open && !edits.preview {edits.commit=true}
}

// Failure preserves the baseline and redo; the open gesture can be retried.
edits_commit :: proc(edits:^Edits,w:core.World_Ref,selection:^Selection,external_change:=false) -> bool {
    prepared,error:=edits_prepare(edits,w,selection,external_change)
    defer edits_preparation_destroy(&prepared)
    if error!=.None {edits.error=error;return false}
    edits.error=edits_commit_prepared(edits,w,&prepared)
    return edits.error==.None
}

// Puts back what changed since the last step and closes the gesture. In a
// World that is not the one of the history it only closes it.
edits_cancel :: proc(edits:^Edits,w:core.World_Ref) {
    if !edits.open && !edits.commit && !edits.preview {return}
    if w.data!=edits.world {
        edits.open,edits.commit,edits.preview,edits.cancel_ready=false,false,false,false
        for &file in edits.files {edit_file_free(&file)}
        clear(&edits.files)
        return
    }
    if !edits.cancel_ready {
        if error:=edits_cancel_prepare(edits,w);error!=.None {edits.error=error;return}
    }
    edits_cancel_reserved(edits,w)
}

// The gesture that is open records itself if it ended. Run at the safe points: the end of a frame.
edits_flush :: proc(edits:^Edits,w:core.World_Ref,selection:^Selection) {
    if edits.commit {edits_commit(edits,w,selection)}
}

// Undoes in order the newest step of the author of the edits (Edits.author):
// only while it is the last step done and the World holds what it left.
// Otherwise false with the error Interleaved, and history_undo takes it back
// by ids. With a preview open it cancels the preview.
undo :: proc(edits:^Edits,w:core.World_Ref,selection:^Selection) -> bool {
    if edits.preview && w.data==edits.world {
        edits_cancel(edits,w)
        if edits.open || edits.commit || edits.preview {return false}
        selection_restore(selection,w,edits.selection[:])
        edits_selection_take(edits,selection)
        return true
    }
    index:=edits_undo_index(edits)
    if index<0 || w.data!=edits.world {return false}
    edits_cancel(edits,w)
    if edits.open || edits.commit || edits.preview {return false}
    step:=&edits.steps[index]
    if index!=edits.cursor-1 {edits.error=.Interleaved;return false}
    if !edits_step_swap(edits,w,step,selection,step.before[:]) {return false}
    edits.cursor-=1
    edits.order+=1
    step.undone=edits.order
    edits.stats.undos+=1
    return true
}

// Redoes in order the step the newest undo of the author took back: while it
// is the first undone in order, or the undo that took it back by ids is the
// last step done, and the World holds what is to be exchanged. Otherwise false
// with the error Interleaved, and history_redo brings it again by ids.
redo :: proc(edits:^Edits,w:core.World_Ref,selection:^Selection) -> bool {
    if edits.preview && w.data==edits.world {
        edits_cancel(edits,w)
        if edits.open || edits.commit || edits.preview {return false}
        selection_restore(selection,w,edits.selection[:])
        edits_selection_take(edits,selection)
        return true
    }
    index:=edits_redo_index(edits)
    if index<0 || w.data!=edits.world {return false}
    edits_cancel(edits,w)
    if edits.open || edits.commit || edits.preview {return false}
    step:=&edits.steps[index]
    switch {
    case index==edits.cursor:
        if !edits_step_swap(edits,w,step,selection,step.after[:]) {return false}
        edits.cursor+=1
    case step.reverted && edits.cursor>0 && edits_undoes(&edits.steps[edits.cursor-1],step):
        taken:=&edits.steps[edits.cursor-1]
        if !edits_step_swap(edits,w,taken,selection,taken.before[:]) {return false}
        edits.cursor-=1
        step.reverted=false
    case:
        edits.error=.Interleaved
        return false
    }
    step.undone=0
    edits.stats.redos+=1
    return true
}

// Whether a step is the undo by ids of another, made by its author, that
// nothing took back.
@(private)
edits_undoes :: proc(taken,step:^Edit_Step) -> bool {
    return taken.kind==.Undo && taken.target==step.state && taken.author==step.author && !taken.reverted
}

// Exchanges a step with the World once its room is reserved, while the World
// holds what the step left; then selects selected.
@(private)
edits_step_swap :: proc(edits:^Edits,w:core.World_Ref,step:^Edit_Step,selection:^Selection,selected:[]core.Entity) -> bool {
    if error:=edits_step_prepare(edits,w,step,selection,selected);error!=.None {edits.error=error;return false}
    if !step_exact(edits,w,step) {edits.error=.Interleaved;return false}
    step_swap(edits,w,step)
    selection_restore(selection,w,selected)
    edits_selection_take(edits,selection)
    return true
}

// The newest step the author of the edits can undo: one of its own that is
// done, was not taken back and is not an undo; -1 without one.
edits_undo_index :: proc(edits:^Edits) -> int {
    for i:=edits.cursor-1;i>=0;i-=1 {
        step:=&edits.steps[i]
        if step.author==edits.author && !step.reverted && step.kind!=.Undo {return i}
    }
    return -1
}

// The step the newest undo of the author of the edits took back; -1 without one.
edits_redo_index :: proc(edits:^Edits) -> int {
    index,order:=-1,u64(0)
    for &step,i in edits.steps {
        if step.author==edits.author && step.undone>order {index,order=i,step.undone}
    }
    return index
}

// The index of the step of a state; -1 once it is gone.
edits_step_index :: proc(edits:^Edits,state:u64) -> int {
    for &step,i in edits.steps {if step.state==state {return i}}
    return -1
}

// How many steps the author of the edits can undo, and redo, with those of the selection.
edits_undo_count :: proc(edits:^Edits) -> (count:int) {
    for &step in edits.steps[:edits.cursor] {
        if step.author==edits.author && !step.reverted && step.kind!=.Undo {count+=1}
    }
    for &step in edits.selections {if step.author==edits.author && step.undone==0 {count+=1}}
    return
}
edits_redo_count :: proc(edits:^Edits) -> (count:int) {
    for &step in edits.steps {if step.author==edits.author && step.undone>0 {count+=1}}
    for &step in edits.selections {if step.author==edits.author && step.undone>0 {count+=1}}
    return
}

// The label of the step undo or redo of the author of the edits would take
// back or bring again; empty without one.
undo_label :: proc(edits:^Edits) -> string {
    if index,first:=selection_undo_first(edits);first {return cstring_text(edits.selections[index].label[:])}
    if index:=edits_undo_index(edits);index>=0 {return edits_label(&edits.steps[index])}
    return ""
}
redo_label :: proc(edits:^Edits) -> string {
    if index,first:=selection_redo_first(edits);first {return cstring_text(edits.selections[index].label[:])}
    if index:=edits_redo_index(edits);index>=0 {return edits_label(&edits.steps[index])}
    return ""
}

// Forgets the history and takes the World again: after it was replaced.
edits_reset :: proc(edits:^Edits,w:core.World_Ref) {
    for &step in edits.steps {step_free(&step)}
    clear(&edits.steps)
    for &step in edits.selections {selection_step_free(&step)}
    clear(&edits.selections)
    edits.selected_known=false
    for &file in edits.files {edit_file_free(&file)}
    clear(&edits.files)
    edits.cursor,edits.bytes=0,0
    edits.open,edits.commit,edits.preview=false,false,false
    edits.cancel_ready,edits.error=false,.None
    edits.serial+=1
    edits.initial=edits.serial
    edits.epoch+=1
    edits.world=w.data
    journal_changes_drop(edits)
    core.world_settle(w)
    edits_image_take(edits,w)
}

// The image of the journal is the World as it is.
edits_image_take :: proc(edits:^Edits,w:core.World_Ref) {
    for &image in edits.image[min(len(w.info.tables),len(edits.image)):] {journal_table_free(&image)}
    resize(&edits.saved,len(w.info.tables))
    resize(&edits.image,len(w.info.tables))
    ids:=core.world_table_of(w,core.Id)
    authors:=History_Authors{current=ids!=nil?core.raw(ids):nil}
    for &t,i in w.info.tables {
        edits.saved[i]=t.place==.World && author.component_saved(t.type)
        if edits.saved[i] {journal_table_take(&edits.image[i],core.world_table_at(w,&t),t.info.size,authors,ids!=nil && t.type!=core.Id)} else {journal_table_free(&edits.image[i])}
    }
    journal_ranges(edits,w)
    journal_entities_take(&edits.image_entities,core.world_entities(w))
}

// Accept initial values resolved from assets before the first authored step.
edits_sync_initial :: proc(edits:^Edits,w:core.World_Ref) -> bool {
    if edits==nil || w.data==nil || w.info==nil || edits.world!=w.data || edits.open || edits.commit || len(edits.steps)>0 {return false}
    core.world_settle(w)
    if !journal_ranges(edits,w) {return false}
    authors,only_authors:=history_authors(edits,w)
    id:=journal_id_table(w)
    for i in 0..<min(len(w.info.tables),len(edits.image)) {
        if !edits.saved[i] {continue}
        rows,adds:=journal_count(edits,w,i,authors,only_authors && i!=id)
        if rows>0 && !journal_room(&edits.image[i],len(edits.image[i].entities)+adds,w.info.tables[i].info.size,len(core.world_entities(w).generation)) {return false}
    }
    journal_sync(edits,w) or_return
    return true
}

// The image takes the row of e of the table of type as the World has it,
// without a step nor a change: a value a library derives in Edit (where a
// Bone_Attachment puts its entity), which no step holds. Nothing while a
// gesture is open or pending, which holds what changed meanwhile, nor for an
// entity the image has no row of, which is new to the next step whole.
edits_take_derived :: proc(edits:^Edits,w:core.World_Ref,type:typeid,e:core.Entity) {
    if edits==nil || w.data==nil || edits.world!=w.data || edits.open || edits.commit || edits.preview {return}
    for &t,i in w.info.tables {
        if t.place==w.place && t.type==type {journal_take_field(edits,w,i,e,0,t.info.size);return}
    }
}

edits_free :: proc(edits:^Edits) {
    for &step in edits.steps {step_free(&step)}
    delete(edits.steps)
    for &step in edits.selections {selection_step_free(&step)}
    delete(edits.selections);delete(edits.selected)
    for &image in edits.image {journal_table_free(&image)}
    delete(edits.image);delete(edits.saved);delete(edits.selection)
    journal_entities_free(&edits.image_entities)
    delete(edits.changes)
    delete(edits.change_values)
    for ranges in edits.ranges {delete(ranges.ranges)}
    delete(edits.ranges);delete(edits.marks);delete(edits.cancel_scratch)
    edits_files_free(edits)
    edits^={}
}

// Exchanges a step with the World: its entities, its rows and its files. What the World drops or derives again of what was
// turned follows, and the journal takes the World.
@(private)
step_swap :: proc(edits:^Edits,w:core.World_Ref,step:^Edit_Step) {
    core.world_settle(w)
    transforms:core.Seen
    if locals:=core.world_table_of(w,core.Transform);locals!=nil {_=core.changes(locals,&transforms)}
    marks:=edits.marks[:]
    es:=core.world_entities(w)
    bound:=len(es.generation)
    entity_changes_swap(&step.entities,es,marks)
    for &rows in step.tables {
        t:=&w.info.tables[rows.table]
        rows_swap(&rows,core.world_table_at(w,t),t.info,edits.cancel_scratch[:],edits.ranges[rows.table].ranges)
    }
    edits_files_swap(edits,step)
    world_turned_prune(w,marks,bound,transforms)
    journal_sync(edits,w)
    step.swapped=!step.swapped
    edits.turns+=1
    step.turned=edits.turns
    edits.cancel_ready,edits.error=false,.None
}

// Whether a swap of a step would take nothing someone else wrote since the
// step left the World: every row and entity of the step is as it left them, the entities the swap takes away are whole (the step
// holds every row of theirs) and named by no author that stays, and those
// the other side names are there after the swap. edits_step_prepare reserved
// the marks.
@(private)
step_exact :: proc(edits:^Edits,w:core.World_Ref,step:^Edit_Step) -> bool {
    core.world_settle(w)
    es:=core.world_entities(w)
    marks:=edits.marks[:]
    if len(marks)<len(es.generation) {return false}
    for index in es.free {marks[index]|=ENTITY_FREE}
    defer for &mark in marks {mark&~=ENTITY_FREE|ENTITY_GOING}
    changes:=&step.entities
    for i,k in changes.indices {
        if int(i)>=len(es.generation) {return false}
        alive:=marks[i]&ENTITY_FREE==0
        if alive!=changes.held.alive[k] || alive && es.generation[i]!=changes.held.generation[k] {return false}
        if alive && (!changes.alive[k] || changes.generation[k]!=es.generation[i]) {marks[i]|=ENTITY_GOING}
    }
    going :: proc(es:^core.Entities,marks:[]u8,e:core.Entity) -> bool {
        i:=core.entity_index(e)
        return i<len(marks) && marks[i]&ENTITY_GOING!=0 && core.alive(es,e)
    }
    // After the swap an entity is there when it stays, or when the swap gives
    // its index that generation alive.
    there :: proc(es:^core.Entities,marks:[]u8,changes:^Entity_Changes,e:core.Entity) -> bool {
        if e==core.NONE {return true}
        if k,turned:=slice.binary_search(changes.indices[:],u32(core.entity_index(e)));turned {
            return changes.alive[k] && changes.generation[k]==core.entity_generation(e)
        }
        return core.alive(es,e) && !going(es,marks,e)
    }
    authors,only_authors:=history_authors(edits,w)
    rows_going:=0
    for &rows in step.tables {
        info:=&w.info.tables[rows.table]
        table:=core.world_table_at(w,info)
        size:=info.info.size
        ranges:=edits.ranges[rows.table].ranges
        offsets:=saved_entity_offsets(info.info)
        for e,k in rows.entities {
            row:=core.raw_row(table,e)
            if (row>=0)!=rows.held.present[k] {return false}
            if row>=0 && (table.off[row]!=rows.held.off[k] || !saved_equal(table_value(table,size,row),raw_data(rows.held.values[k*size:]),size,ranges)) {return false}
            if row>=0 && going(es,marks,e) {rows_going+=1}
            if !rows.present[k] {continue}
            for at in offsets {
                if !there(es,marks,changes,(^core.Entity)(&rows.values[k*size+int(at)])^) {return false}
            }
        }
    }
    for &info,index in w.info.tables {
        if info.place!=w.place || index>=len(edits.saved) || !edits.saved[index] {continue}
        for e in core.world_table_at(w,&info).entities {
            if going(es,marks,e) && (!only_authors || history_is_author(authors,e)) {rows_going-=1}
        }
    }
    return rows_going==0 && entities_named_keep(w,marks,step)==0
}

history_authors :: proc(edits:^Edits,w:core.World_Ref) -> (authors:History_Authors,only_authors:bool) {
    ids:=core.world_table_of(w,core.Id)
    if ids==nil {return}
    authors.current=core.raw(ids)
    only_authors=true
    for table,i in w.info.tables {
        if table.place==w.place && table.type==core.Id && i<len(edits.image) {
            authors.previous=&edits.image[i]
            break
        }
    }
    return
}

// Puts the other side of the rows of a step in a table: the step then holds
// what it put and keeps what the table had as the other side. A row that
// stays keeps the transient fields its library derived; one turned off or on
// turns at the next settle.
@(private)
rows_swap :: proc(r:^Step_Rows,t:^core.Raw_Table,info:^runtime.Type_Info,had:[]u8,transient:[][2]int) {
    size:=info.size
    for e,k in r.entities {
        value:=r.values[k*size:][:size]
        current:=core.raw_find(t,info,e)
        _,was_off,_:=core.raw_state(t,e)
        if current!=nil {mem.copy(raw_data(had),current,size)}
        switch {
        case r.present[k] && current!=nil: saved_copy(core.raw_author(t,info,e),raw_data(value),size,transient)
        case r.present[k]:                 core.raw_add(t,info,e,raw_data(value))
        case current!=nil:                 core.raw_remove(t,e)
        }
        if r.present[k] && r.off[k]!=was_off {
            if r.off[k] {core.raw_disable(t,e)} else {core.raw_enable(t,e)}
        }
        copy(r.held.values[k*size:][:size],value)
        r.held.present[k],r.held.off[k]=r.present[k],r.off[k]
        r.present[k]=current!=nil
        r.off[k]=was_off
        if current!=nil {copy(value,had[:size])} else {mem.zero_slice(value)}
    }
}

// Adds the row of an entity to a step: its other side and what it holds.
@(private)
rows_put :: proc(r:^Step_Rows,e:core.Entity,present,off:bool,value:rawptr,held_present,held_off:bool,held:rawptr,size:int) -> bool {
    next:=len(r.entities)+1
    if reserve(&r.entities,next)!=nil || !step_side_room(&r.other,next,size) || !step_side_room(&r.held,next,size) {return false}
    append(&r.entities,e)
    step_side_put(&r.other,present,off,value,size)
    step_side_put(&r.held,held_present,held_off,held,size)
    return true
}

@(private)
step_side_room :: proc(side:^Step_Side,rows,size:int) -> bool {
    return reserve(&side.present,rows)==nil && reserve(&side.off,rows)==nil && reserve(&side.values,rows*size)==nil
}

@(private)
step_side_put :: proc(side:^Step_Side,present,off:bool,value:rawptr,size:int) {
    append(&side.present,present);append(&side.off,present && off)
    at:=len(side.values)
    resize(&side.values,at+size)
    if present && size>0 {mem.copy(&side.values[at],value,size)}
}

rows_free :: proc(r:^Step_Rows) {
    delete(r.entities)
    delete(r.present);delete(r.off);delete(r.values)
    delete(r.held.present);delete(r.held.off);delete(r.held.values)
    r^={}
}

// Whether two values of a component agree in what a scene saves.
@(private)
saved_equal :: proc(a,b:rawptr,size:int,transient:[][2]int) -> bool {
    start:=0
    for r in transient {
        if r[0]>start && mem.compare_ptrs(rawptr(uintptr(a)+uintptr(start)),rawptr(uintptr(b)+uintptr(start)),r[0]-start)!=0 {return false}
        start=max(start,r[0]+r[1])
    }
    return size<=start || mem.compare_ptrs(rawptr(uintptr(a)+uintptr(start)),rawptr(uintptr(b)+uintptr(start)),size-start)==0
}

// Copies what a scene saves of a value.
@(private)
saved_copy :: proc(dst,src:rawptr,size:int,transient:[][2]int) {
    start:=0
    for r in transient {
        if r[0]>start {mem.copy(rawptr(uintptr(dst)+uintptr(start)),rawptr(uintptr(src)+uintptr(start)),r[0]-start)}
        start=max(start,r[0]+r[1])
    }
    if size>start {mem.copy(rawptr(uintptr(dst)+uintptr(start)),rawptr(uintptr(src)+uintptr(start)),size-start)}
}

@(private)
step_free :: proc(step:^Edit_Step) {
    for &rows in step.tables {rows_free(&rows)}
    delete(step.tables)
    entity_changes_free(&step.entities)
    delete(step.before);delete(step.after)
    for &file in step.files {edit_file_free(&file)}
    delete(step.files)
    step^={}
}

// Text in a fixed buffer, cut to fit and ended by a zero.
text_put :: proc(buffer:[]u8,text:string) -> int {
    if len(buffer)==0 {return 0}
    n:=copy(buffer[:len(buffer)-1],text)
    buffer[n]=0
    return n
}

cstring_text :: proc(buffer:[]u8) -> string {
    for b,i in buffer {
        if b==0 {return string(buffer[:i])}
    }
    return string(buffer)
}
