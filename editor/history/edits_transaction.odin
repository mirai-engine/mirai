package history

import "base:runtime"
import "core:mem"
import "mirai:core"
import "mirai:std/base"

// Interleaved: the step to undo or redo is not where the history can
// exchange it with the World (history_undo, history_redo).
Edit_Error :: enum {None,No_Change,World,Memory,Stale,Preview,Interleaved}

Edit_Preparation :: struct {
    step:Edit_Step,
    tables:[dynamic]int,
    world:rawptr,
    info:^core.World_Info,
    selection:^Selection,
    fingerprint,serial,selection_fingerprint:u64,
    cursor:int,
    ready,changed:bool,
}

Edit_Transient_Ranges :: struct {info:^runtime.Type_Info,ranges:[][2]int}

History_Authors :: struct {current:^core.Raw_Table,previous:^Journal_Table}

history_is_author :: proc(authors:History_Authors,e:core.Entity) -> bool {
    return authors.current!=nil && core.raw_row(authors.current,e)>=0 || authors.previous!=nil && journal_row(authors.previous,e)>=0
}

@(private)
edits_world_fingerprint :: proc(edits:^Edits,w:core.World_Ref) -> u64 {
    key:=base.hash_u64(u64(uintptr(w.info)))
    for &table,index in w.info.tables {
        if index>=len(edits.saved) || !edits.saved[index] {continue}
        current:=core.world_table_at(w,&table)
        key=base.hash_u64(key~current.version~base.hash_u64(current.layout)~u64(index)~base.hash_u64(u64(len(current.pending)))~u64(uintptr(table.info)))
        image:=&edits.image[index]
        key=base.hash_u64(key~image.seen.version~base.hash_u64(image.seen.gone)~base.hash_u64(u64(len(image.entities))))
    }
    entities:=core.world_entities(w)
    key=base.hash64(mem.slice_to_bytes(entities.generation[:]),key)
    key=base.hash64(mem.slice_to_bytes(entities.free[:]),key)
    key=base.hash64(mem.slice_to_bytes(entities.doomed[:]),key)
    return base.hash_u64(key~u64(entities.alive))
}

@(private)
edits_selection_fingerprint :: proc(selection:^Selection) -> u64 {
    return base.hash64(mem.slice_to_bytes(selection.entities[:]),selection.serial)
}

edits_preparation_destroy :: proc(prepared:^Edit_Preparation) {
    step_free(&prepared.step)
    delete(prepared.tables)
    prepared^={}
}

@(private)
edits_prepare_failed :: proc(prepared:^Edit_Preparation,error:Edit_Error) -> (Edit_Preparation,Edit_Error) {
    edits_preparation_destroy(prepared)
    return {},error
}

// The step of what the World and the journal disagree on, and every
// reservation its publication needs, without moving the journal, the serial,
// the cursor or redo.
edits_prepare :: proc(edits:^Edits,w:core.World_Ref,selection:^Selection,external_change:=false) -> (prepared:Edit_Preparation,error:Edit_Error) {
    if edits==nil || w.data==nil || w.info==nil || w.data!=edits.world {return {},.World}
    if edits.preview {return {},.Preview}
    core.world_settle(w)
    if !journal_ranges(edits,w) {return {},.Memory}
    authors,only_authors:=history_authors(edits,w)
    id:=journal_id_table(w)
    entities:=core.world_entities(w)
    notes:=0
    for &table,index in w.info.tables {
        if index>=len(edits.saved) || !edits.saved[index] {continue}
        current:=core.world_table_at(w,&table)
        image:=&edits.image[index]
        if !journal_moved(current,image) {continue}
        size:=table.info.size
        rows:=Step_Rows{table=index}
        adds:=0
        d:=journal_diff(current,image,size,edits.ranges[index].ranges,authors,only_authors && index!=id)
        for r in journal_diff_next(&d) {
            if r.image_row<0 {adds+=1}
            value:=r.image_row>=0?journal_value(image,size,r.image_row):nil
            held:=r.row>=0?table_value(current,size,r.row):nil
            if !rows_put(&rows,r.entity,r.image_row>=0,r.image_row>=0 && image.off[r.image_row],value,r.row>=0,r.row>=0 && current.off[r.row],held,size) {rows_free(&rows);return edits_prepare_failed(&prepared,.Memory)}
        }
        notes+=len(rows.entities)
        if len(rows.entities)>0 {
            _,failed:=append(&prepared.step.tables,rows)
            if failed!=nil {rows_free(&rows);return edits_prepare_failed(&prepared,.Memory)}
            prepared.step.bytes+=2*len(rows.values)+len(rows.entities)*(size_of(core.Entity)+4)
        } else {rows_free(&rows)}
        _,failed:=append(&prepared.tables,index)
        if failed!=nil || adds>0 && !journal_room(image,len(image.entities)+adds,size,len(entities.generation)) {return edits_prepare_failed(&prepared,.Memory)}
    }
    if !journal_entities_same(&edits.image_entities,entities) {
        if reserve(&edits.image_entities.generation,len(entities.generation))!=nil || reserve(&edits.image_entities.alive,len(entities.generation))!=nil {return edits_prepare_failed(&prepared,.Memory)}
        if len(prepared.step.tables)>0 || !only_authors {
            marks,failed:=make([]u8,len(entities.generation),context.temp_allocator)
            defer delete(marks,context.temp_allocator)
            if failed!=nil || !entity_changes_take(&prepared.step.entities,&edits.image_entities,entities,marks) {return edits_prepare_failed(&prepared,.Memory)}
            prepared.step.bytes+=len(prepared.step.entities.indices)*(size_of(u32)*3+2)
        }
    }
    if (edits.reading || edits.logging) && reserve(&edits.changes,len(edits.changes)+notes)!=nil {return edits_prepare_failed(&prepared,.Memory)}
    prepared.changed=len(prepared.step.tables)>0 || len(prepared.step.entities.indices)>0 || external_change || len(edits.files)>0
    if prepared.changed {
        prepared.step.label=edits.label
        prepared.step.author=edits.opener if edits.open else edits.author
        if !edits.open {text_put(prepared.step.label[:],"Edit")}
        before:=edits.selection[:] if edits.open else selection.entities[:]
        if resize(&prepared.step.before,len(before))!=nil || resize(&prepared.step.after,len(selection.entities))!=nil || reserve(&edits.steps,len(edits.steps)+1)!=nil || reserve(&edits.selected,len(selection.entities))!=nil {return edits_prepare_failed(&prepared,.Memory)}
        copy(prepared.step.before[:],before)
        copy(prepared.step.after[:],selection.entities[:])
    }
    prepared.world,prepared.info,prepared.selection=w.data,w.info,selection
    prepared.serial,prepared.cursor=edits.serial,edits.cursor
    prepared.fingerprint=edits_world_fingerprint(edits,w)
    prepared.selection_fingerprint=edits_selection_fingerprint(selection)
    prepared.ready=true
    return prepared,.None
}

edits_commit_prepared :: proc(edits:^Edits,w:core.World_Ref,prepared:^Edit_Preparation) -> Edit_Error {
    if error:=edits_preparation_valid(edits,w,prepared);error!=.None {return error}
    return edits_publish_prepared(edits,w,prepared)
}

edits_preparation_valid :: proc(edits:^Edits,w:core.World_Ref,prepared:^Edit_Preparation) -> Edit_Error {
    if edits==nil || prepared==nil || !prepared.ready || w.data!=prepared.world || w.info!=prepared.info || edits.world!=w.data {return .World}
    if edits.serial!=prepared.serial || edits.cursor!=prepared.cursor || edits_world_fingerprint(edits,w)!=prepared.fingerprint || edits_selection_fingerprint(prepared.selection)!=prepared.selection_fingerprint {return .Stale}
    return .None
}

@(private)
edits_publish_prepared :: proc(edits:^Edits,w:core.World_Ref,prepared:^Edit_Preparation) -> Edit_Error {
    journal_sync(edits,w)
    edits.stats.compared+=u64(len(prepared.tables))
    edits.open,edits.commit,edits.cancel_ready=false,false,false
    prepared.ready=false
    if !prepared.changed {edits.error=.No_Change;return .No_Change}
    // What was undone in order no longer follows the World: a new edit drops
    // what its author undid, and the steps of the others stay before it as
    // taken back, their redo by ids.
    author,edit:=prepared.step.author,prepared.step.kind==.Edit
    kept:=edits.cursor
    for i in edits.cursor..<len(edits.steps) {
        step:=edits.steps[i]
        if edit && step.author==author {
            edits.bytes-=step.bytes
            step_free(&step)
            continue
        }
        step.reverted=true
        edits.steps[kept]=step
        kept+=1
    }
    resize(&edits.steps,kept)
    if edit {
        for &step in edits.steps {if step.author==author {step.undone=0}}
        edits_selection_redo_drop(edits,author)
    }
    // The selection the step left is the one the history knows.
    edits_selection_take(edits,prepared.selection)
    edits.serial+=1
    prepared.step.state=edits.serial
    edits.turns+=1
    prepared.step.turned=edits.turns
    prepared.step.files,edits.files=edits.files,{}
    for &file in prepared.step.files {prepared.step.bytes+=edit_file_bytes(&file)}
    append(&edits.steps,prepared.step)
    edits.bytes+=prepared.step.bytes
    prepared.step={}
    edits.cursor=len(edits.steps)
    edits.stats.steps+=1
    for len(edits.steps)>1 && (len(edits.steps)>EDITS_STEP_CAPACITY || edits.bytes>EDITS_BYTE_CAPACITY) {
        first:=edits.steps[0]
        edits.initial=first.state
        edits.bytes-=first.bytes
        step_free(&first)
        ordered_remove(&edits.steps,0)
        edits.cursor-=1
        edits.stats.discarded+=1
    }
    edits.error=.None
    return .None
}

edits_error_text :: proc(error:Edit_Error) -> string {
    switch error {
    case .None,.No_Change:return ""
    case .World:return "The edit belongs to another world; reopen the scene and retry"
    case .Memory:return "The edit could not reserve its history and rollback memory; free memory and retry"
    case .Stale:return "The scene, history or selection changed after the edit was prepared; prepare it again before publishing"
    case .Preview:return "Finish or cancel the current preview before committing another edit"
    case .Interleaved:return "Other edits came after the step; it is taken back by ids"
    }
    return "The edit could not be committed"
}

// Reserves what a cancel needs to put the World back as the journal has it,
// before the World is written: the rows the journal holds and the World may
// lose, additional_entities created meanwhile, and the entities.
edits_cancel_prepare :: proc(edits:^Edits,w:core.World_Ref,additional_entities:int=0) -> Edit_Error {
    if edits==nil || w.data==nil || w.info==nil || edits.world!=w.data || additional_entities<0 {return .World}
    edits.cancel_ready=false
    core.world_settle(w)
    if !journal_ranges(edits,w) {return .Memory}
    entities:=core.world_entities(w)
    if additional_entities>max(int)-len(entities.generation) {return .Memory}
    limit:=max(len(entities.generation),len(edits.image_entities.generation))+additional_entities
    if reserve(&entities.generation,limit)!=nil || reserve(&entities.free,limit)!=nil || reserve(&entities.doomed,limit)!=nil || reserve(&edits.image_entities.generation,limit)!=nil || reserve(&edits.image_entities.alive,limit)!=nil {return .Memory}
    if len(edits.marks)<limit && resize(&edits.marks,limit)!=nil {return .Memory}
    for &table,index in w.info.tables {
        if table.place!=w.place || index>=len(edits.saved) || !edits.saved[index] {continue}
        current:=core.world_table_at(w,&table)
        image:=&edits.image[index]
        seen:=image.seen
        c:=core.raw_changes(current,&seen)
        missing:=len(c.gone)
        if c.all {
            missing=0
            for e in image.entities {if core.raw_row(current,e)<0 {missing+=1}}
        }
        rows:=max(len(image.entities),len(current.entities)+missing)+additional_entities
        size:=table.info.size
        if size>0 && rows>max(int)/size {return .Memory}
        if !runtime.__dynamic_array_reserve(&current.values,size,table.info.align,rows) || reserve(&current.entities,rows)!=nil || reserve(&current.stamps,rows)!=nil || reserve(&current.off,rows)!=nil || reserve(&current.pending,len(current.entities)+additional_entities)!=nil {return .Memory}
        if current.single && reserve(&current.turns,rows)!=nil {return .Memory}
        if !core.raw_room(current,len(image.entities)>0?limit:0) {return .Memory}
        if len(image.entities)>0 {
            for lock in current.locks {if reserve(core.lock_owners(current,lock),limit)!=nil {return .Memory}}
        }
        if resize(&edits.cancel_scratch,max(len(edits.cancel_scratch),size))!=nil {return .Memory}
    }
    edits.cancel_limit,edits.cancel_ready=limit,true
    return .None
}

// What undo or redo of a step needs: the reservations of a cancel, room for
// its rows in the World, and room in the journal for what it takes after.
@(private)
edits_step_prepare :: proc(edits:^Edits,w:core.World_Ref,step:^Edit_Step,selection:^Selection,selected:[]core.Entity) -> Edit_Error {
    if error:=edits_cancel_prepare(edits,w);error!=.None {return error}
    if reserve(&selection.entities,len(selected))!=nil || reserve(&edits.selected,len(selected))!=nil {return .Memory}
    authors,only_authors:=history_authors(edits,w)
    id:=journal_id_table(w)
    notes:=0
    for &table,index in w.info.tables {
        if index>=len(edits.saved) || !edits.saved[index] {continue}
        rows,adds:=journal_count(edits,w,index,authors,only_authors && index!=id)
        for &r in step.tables {
            if r.table==index {rows+=len(r.entities);adds+=len(r.entities)}
        }
        notes+=rows
        if rows>0 && !journal_room(&edits.image[index],len(edits.image[index].entities)+adds,table.info.size,edits.cancel_limit) {return .Memory}
    }
    if (edits.reading || edits.logging) && reserve(&edits.changes,len(edits.changes)+notes)!=nil {return .Memory}
    for rows in step.tables {
        table:=&w.info.tables[rows.table]
        current:=core.world_table_at(w,table)
        count:=len(current.entities)+len(rows.entities)
        if !runtime.__dynamic_array_reserve(&current.values,table.info.size,table.info.align,count) || !runtime.__dynamic_array_reserve(&current.added,table.info.size,table.info.align,len(rows.entities)) || reserve(&current.entities,count)!=nil || reserve(&current.stamps,count)!=nil || reserve(&current.off,count)!=nil || reserve(&current.pending,len(current.pending)+2*len(rows.entities))!=nil || !core.raw_room(current,edits.cancel_limit) {return .Memory}
        for lock in current.locks {if reserve(core.lock_owners(current,lock),edits.cancel_limit)!=nil {return .Memory}}
    }
    return .None
}

// Puts the World back as the journal has it, in the room edits_cancel_prepare
// reserved: the entities, then the rows the World holds otherwise, and once
// what was taken away settled, the rows it lost.
@(private)
edits_cancel_reserved :: proc(edits:^Edits,w:core.World_Ref) -> bool {
    if !edits.cancel_ready || w.data!=edits.world || len(edits.image_entities.generation)>edits.cancel_limit || len(edits.ranges)!=len(w.info.tables) {edits.error=.Stale;return false}
    core.world_settle(w)
    es:=core.world_entities(w)
    marks:=edits.marks[:]
    transforms:core.Seen
    if locals:=core.world_table_of(w,core.Transform);locals!=nil {_=core.changes(locals,&transforms)}
    bound:=len(es.generation)
    journal_entities_put(&edits.image_entities,es,marks)
    turned_rows_drop(w,es,marks,bound)
    authors,only_authors:=history_authors(edits,w)
    id:=journal_id_table(w)
    for pass in 0..<2 {
        for at in 0..=len(w.info.tables) {
            index,saved:=journal_order(edits,w,id,at)
            if !saved {continue}
            info:=&w.info.tables[index]
            current:=core.world_table_at(w,info)
            image:=&edits.image[index]
            if !journal_moved(current,image) {continue}
            size:=info.info.size
            ranges:=edits.ranges[index].ranges
            d:=journal_diff(current,image,size,ranges,authors,only_authors && index!=id)
            for r in journal_diff_next(&d) {
                if (r.row>=0)!=(pass==0) {continue}
                if r.row<0 {
                    value:=journal_value(image,size,r.image_row)
                    if !core.raw_put(current,info.info,es,r.entity,value,image.off[r.image_row]) {
                        core.raw_add(current,info.info,r.entity,value)
                        if image.off[r.image_row] {core.raw_disable(current,r.entity)}
                    }
                    continue
                }
                if r.image_row<0 {core.raw_remove(current,r.entity);continue}
                value:=journal_value(image,size,r.image_row)
                if !saved_equal(table_value(current,size,r.row),value,size,ranges) {saved_copy(core.raw_get(current,info.info,r.entity),value,size,ranges)}
                if image.off[r.image_row]!=current.off[r.row] {
                    if image.off[r.image_row] {core.raw_disable(current,r.entity)} else {core.raw_enable(current,r.entity)}
                }
            }
        }
        core.world_settle(w)
    }
    world_turned_prune(w,marks,bound,transforms)
    for &table,index in w.info.tables {
        if index<len(edits.saved) && edits.saved[index] {_=core.raw_changes(core.world_table_at(w,&table),&edits.image[index].seen)}
    }
    journal_entities_take(&edits.image_entities,es)
    edits_files_cancel(edits)
    edits.open,edits.commit,edits.preview,edits.cancel_ready=false,false,false,false
    edits.error=.None
    return true
}
