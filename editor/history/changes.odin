package history

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import "mirai:cook/author"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// Change sets: what steps of the history did, named by the ids of the
// entities, with what each row and file of the project was before and after.
// The review of an agent keeps those of a turn; the undo and redo of an
// author take back or bring again a step of its own after steps of others.
//
// Put on one side, a field, whether a component is there and whether it is
// turned off change only while they hold what the other side left: what
// someone else wrote since stays and counts as kept. An entity goes only when
// all of it is as that side left it and no author that stays names it; one
// comes back with its id while the id is free.

Change_Row :: struct {
    table:int, // of the world info
    layout:u64,
    id:base.Entity_Id,
    before_present,after_present:bool,
    before_off,after_off:bool, // turned off by itself
    before,after:[]u8,         // canonical: Entity fields hold ids, transient fields zero
}

// A file of the project a change set changed: what it held before and after
// (a side without the file is absent).
Change_File :: struct {
    path:string, // relative to the project
    before_present,after_present:bool,
    before,after:[]u8,
}

Change_Set :: struct {state:u64,rows:[dynamic]Change_Row,files:[dynamic]Change_File}

// What change sets may hold: rows and files, and their bytes.
Change_Limit :: struct {rows,bytes,row_capacity,byte_capacity:int}

change_entity :: proc(w:core.World_Ref,id:base.Entity_Id) -> core.Entity {
    return core.entity_of(core.world_entities(w),id)
}

// The id of an entity: in the World, or in the rows of Id of a step, on either side.
@(private)
change_step_id :: proc(w:core.World_Ref,step:^Edit_Step,e:core.Entity) -> base.Entity_Id {
    if id:=core.id_of(core.world_table_of(w,core.Id),e);id!=0 {return id}
    if step==nil {return 0}
    for &rows in step.tables {
        if rows.table<0 || rows.table>=len(w.info.tables) || w.info.tables[rows.table].type!=core.Id {continue}
        for known,i in rows.entities {
            if known!=e {continue}
            for side in ([2]^Step_Side{&rows.other,&rows.held}) {
                if !side.present[i] {continue}
                id:core.Id
                mem.copy(&id,raw_data(side.values[i*size_of(core.Id):][:size_of(core.Id)]),size_of(core.Id))
                return id.value
            }
        }
    }
    return 0
}

change_layout :: proc(info:^runtime.Type_Info) -> u64 {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    index,ok:=serial.schema_add_type_info(&schema,info)
    return ok?serial.schema_layout_hash(&schema,index):0
}

// A value with the ids of the entities its Entity fields name, found in the
// World, the step or the history, and its transient fields zero.
change_canonical :: proc(w:core.World_Ref,step:^Edit_Step,info:^runtime.Type_Info,source:rawptr,allocator:=context.allocator,history:[]Edit_Step=nil) -> []u8 {
    bytes,error:=make([]u8,info.size,allocator)
    if error!=nil || info.size>0 && raw_data(bytes)==nil {return nil}
    if info.size>0 && !core.value_copy(raw_data(bytes),source,info) {delete(bytes,allocator);return nil}
    for at in author.entity_offsets(info) {
        reference:core.Entity
        mem.copy(&reference,rawptr(uintptr(raw_data(bytes))+at),size_of(reference))
        id:=change_step_id(w,step,reference)
        if id==0 {for &previous in history {if candidate:=change_step_id(w,&previous,reference);candidate!=0 {id=candidate;break}}}
        mem.copy(rawptr(uintptr(raw_data(bytes))+at),&id,size_of(id))
    }
    for range in transient_ranges(info) {mem.zero(rawptr(uintptr(raw_data(bytes))+uintptr(range[0])),range[1])}
    return bytes
}

// A canonical value with the entities of the World its ids name, in the temporary allocator.
change_materialize :: proc(w:core.World_Ref,info:^runtime.Type_Info,bytes:[]u8) -> []u8 {
    copy_bytes:=make([]u8,len(bytes),context.temp_allocator)
    copy(copy_bytes,bytes)
    for at in author.entity_offsets(info) {
        id:base.Entity_Id
        mem.copy(&id,rawptr(uintptr(raw_data(copy_bytes))+at),size_of(id))
        reference:=change_entity(w,id)
        mem.copy(rawptr(uintptr(raw_data(copy_bytes))+at),&reference,size_of(reference))
    }
    return copy_bytes
}

// The Entity fields of a type a scene saves: what is not transient.
@(private)
saved_entity_offsets :: proc(info:^runtime.Type_Info) -> []uintptr {
    offsets:=author.entity_offsets(info)
    transient:=transient_ranges(info)
    kept:=0
    each: for at in offsets {
        for range in transient {if int(at)>=range[0] && int(at)<range[0]+range[1] {continue each}}
        offsets[kept]=at
        kept+=1
    }
    return offsets[:kept]
}

change_file_free :: proc(file:^Change_File) {
    delete(file.path);delete(file.before);delete(file.after)
    file^={}
}

change_set_free :: proc(set:^Change_Set) {
    for &row in set.rows {delete(row.before);delete(row.after)}
    delete(set.rows)
    for &file in set.files {change_file_free(&file)}
    delete(set.files)
    set^={}
}

// Whether a change set changed nothing it keeps.
change_set_empty :: proc(set:^Change_Set) -> bool {return len(set.rows)==0 && len(set.files)==0}

// Adds what a step did to a change set, by the ids of the entities: the first
// step that changes a row or a file gives what it was before, the last what it
// left. history resolves the ids of entities gone since. False when part of it
// could not be kept (a component that is not plain data, or past the limit);
// the rest is kept. Its files are named from project_root.
change_set_take :: proc(w:core.World_Ref,project_root:string,set:^Change_Set,step:^Edit_Step,history:[]Edit_Step,limit:^Change_Limit=nil) -> (complete:bool) {
    complete=true
    set.state=step.state
    for &rows in step.tables {
        if rows.table<0 || rows.table>=len(w.info.tables) {continue}
        descriptor:=&w.info.tables[rows.table]
        if descriptor.place!=.World || !author.type_saved(descriptor.info) {continue}
        info:=descriptor.info
        if !core.value_flat(info) {complete=false;continue}
        layout:=change_layout(info)
        if layout==0 {complete=false;continue}
        before,after:=&rows.other,&rows.held
        if step.swapped {before,after=after,before}
        size:=info.size
        for entity,i in rows.entities {
            id:=change_step_id(w,step,entity)
            if id==0 {for &previous in history {if candidate:=change_step_id(w,&previous,entity);candidate!=0 {id=candidate;break}}}
            if id==0 {continue}
            row:^Change_Row
            for &known in set.rows {if known.id==id && known.table==rows.table {row=&known;break}}
            if row==nil {
                if limit!=nil && (limit.rows>=limit.row_capacity || limit.bytes>limit.byte_capacity-size*2) {complete=false;continue}
                append(&set.rows,Change_Row{table=rows.table,layout=layout,id=id,before_present=before.present[i],before_off=before.off[i]})
                row=&set.rows[len(set.rows)-1]
                if row.before_present {row.before=change_canonical(w,step,info,raw_data(before.values[i*size:]),history=history)}
                if limit!=nil {limit.rows+=1;limit.bytes+=len(row.before)}
            } else {
                if limit!=nil {limit.bytes-=len(row.after)}
                delete(row.after)
                row.after=nil
            }
            row.after_present,row.after_off=after.present[i],after.off[i]
            if row.after_present {row.after=change_canonical(w,step,info,raw_data(after.values[i*size:]),history=history)}
            if limit!=nil {limit.bytes+=len(row.after)}
        }
    }
    each: for &file in step.files {
        path:=file_relative(project_root,file.path)
        before_present,before,after_present,after:=file.other_present,file.other,file.held_present,file.held
        if step.swapped {before_present,before,after_present,after=after_present,after,before_present,before}
        for &known in set.files {
            if known.path!=path {continue}
            if limit!=nil {limit.bytes+=len(after)-len(known.after)}
            delete(known.after)
            known.after_present,known.after=after_present,slice.clone(after)
            continue each
        }
        if limit!=nil && (limit.rows>=limit.row_capacity || limit.bytes>limit.byte_capacity-len(before)-len(after)) {complete=false;continue}
        append(&set.files,Change_File{path=strings.clone(path),before_present=before_present,after_present=after_present,before=slice.clone(before),after=slice.clone(after)})
        if limit!=nil {limit.rows+=1;limit.bytes+=len(before)+len(after)}
    }
    return
}

// Whether two values of a type agree in what a scene saves.
change_equal :: proc(info:^runtime.Type_Info,a,b:rawptr) -> bool {
    fields,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if is_struct && fields.field_count>0 {
        for i in 0..<int(fields.field_count) {
            if _,transient:=core.field_option(reflect.Struct_Tag(fields.tags[i]),"transient");transient {continue}
            if !change_equal(fields.types[i],rawptr(uintptr(a)+fields.offsets[i]),rawptr(uintptr(b)+fields.offsets[i])) {return false}
        }
        return true
    }
    return info.size==0 || mem.compare_ptrs(a,b,info.size)==0
}

// Writes into current, field by field, what before has where current holds
// what after has; a field that holds another value stays and counts as kept.
// Whether any field changed.
@(private)
change_restore_fields :: proc(info:^runtime.Type_Info,current,before,after:rawptr,kept:^int) -> bool {
    fields,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    changed:=false
    if is_struct && fields.field_count>0 {
        for i in 0..<int(fields.field_count) {
            if _,transient:=core.field_option(reflect.Struct_Tag(fields.tags[i]),"transient");transient {continue}
            offset:=fields.offsets[i]
            if change_restore_fields(fields.types[i],rawptr(uintptr(current)+offset),rawptr(uintptr(before)+offset),rawptr(uintptr(after)+offset),kept) {changed=true}
        }
        return changed
    }
    if change_equal(info,before,after) {return false}
    if change_equal(info,current,before) {return false}
    if !change_equal(info,current,after) {kept^+=1;return false}
    if info.size>0 {mem.copy(current,before,info.size)}
    return true
}

// Whether all of an entity is still as one side of a change set left it: the
// one after it (forward false), or the one before it (forward true).
@(private)
change_entity_clean :: proc(w:core.World_Ref,set:^Change_Set,id:base.Entity_Id,e:core.Entity,forward:bool) -> bool {
    for &descriptor,i in w.info.tables {
        if descriptor.place!=.World || !author.type_saved(descriptor.info) {continue}
        table:=core.world_table_at(w,&descriptor)
        current:=core.raw_find(table,descriptor.info,e)
        if current!=nil && !core.value_flat(descriptor.info) {return false}
        expected:^Change_Row
        for &row in set.rows {if row.id==id && row.table==i {expected=&row;break}}
        present:=expected!=nil && (forward?expected.before_present:expected.after_present)
        if current==nil {
            if present {return false}
            continue
        }
        if !present {return false}
        if _,off,_:=core.raw_state(table,e);off!=(forward?expected.before_off:expected.after_off) {return false}
        canonical:=change_canonical(w,nil,descriptor.info,current,context.temp_allocator)
        if !change_equal(descriptor.info,raw_data(canonical),raw_data(forward?expected.before:expected.after)) {return false}
    }
    return true
}

// Puts a row of an entity where one side of its change set left it: after it
// (forward true), or before it (forward false). A field, and whether the
// component is turned off by itself, change only while they hold what the
// other side left; what someone else wrote since stays and counts as kept. A
// component turns at the next settle.
change_row_put :: proc(w:core.World_Ref,row:^Change_Row,e:core.Entity,forward:bool,kept:^int) {
    descriptor:=&w.info.tables[row.table]
    info,table:=descriptor.info,core.world_table_at(w,descriptor)
    current:=core.raw_find(table,info,e)
    _,off,_:=core.raw_state(table,e)
    had,has:=forward?row.before_present:row.after_present,forward?row.after_present:row.before_present
    from,to:=forward?row.before:row.after,forward?row.after:row.before
    from_off,to_off:=forward?row.before_off:row.after_off,forward?row.after_off:row.before_off
    switch {
    case has && had && current!=nil:
        canonical:=change_canonical(w,nil,info,current,context.temp_allocator)
        if change_restore_fields(info,raw_data(canonical),raw_data(to),raw_data(from),kept) {
            restored:=change_materialize(w,info,canonical)
            saved_copy(core.raw_author(table,info,e),raw_data(restored),info.size,transient_ranges(info))
        }
        if from_off!=to_off && off!=to_off {
            if to_off {core.raw_disable(table,e)} else {core.raw_enable(table,e)}
        }
    case has && !had:
        if current!=nil {
            canonical:=change_canonical(w,nil,info,current,context.temp_allocator)
            if off!=to_off || !change_equal(info,raw_data(canonical),raw_data(to)) {kept^+=1}
            return
        }
        restored:=change_materialize(w,info,to)
        core.raw_add(table,info,e,raw_data(restored))
        if to_off {core.raw_disable(table,e)}
    case !has && had && current!=nil:
        canonical:=change_canonical(w,nil,info,current,context.temp_allocator)
        if off==from_off && change_equal(info,raw_data(canonical),raw_data(from)) {core.raw_remove(table,e)} else {kept^+=1}
    case has && had:
        kept^+=1
    }
}

// The entities about to go (marked ENTITY_GOING by index) that an author that
// stays names in an Entity field a scene saves stay, and so do those they
// name in turn: their mark goes. How many stay. The rows a swap of step
// writes are left out: what they name after it is what the step holds, which
// step_exact looks at (the members of an instance whose root an undo takes).
@(private)
entities_named_keep :: proc(w:core.World_Ref,marks:[]u8,step:^Edit_Step=nil) -> (kept:int) {
    es:=core.world_entities(w)
    ids:=core.world_table_of(w,core.Id)
    going :: proc(es:^core.Entities,marks:[]u8,e:core.Entity) -> bool {
        i:=core.entity_index(e)
        return i<len(marks) && marks[i]&ENTITY_GOING!=0 && core.alive(es,e)
    }
    for {
        changed:=false
        for &descriptor,index in w.info.tables {
            if descriptor.place!=w.place || !author.type_saved(descriptor.info) {continue}
            offsets:=saved_entity_offsets(descriptor.info)
            if len(offsets)==0 {continue}
            table:=core.world_table_at(w,&descriptor)
            written:map[core.Entity]bool
            if step!=nil {
                for &rows in step.tables {
                    if rows.table!=index {continue}
                    written=make(map[core.Entity]bool,len(rows.entities),context.temp_allocator)
                    for e in rows.entities {written[e]=true}
                }
            }
            for source,row in table.entities {
                if going(es,marks,source) || ids!=nil && core.raw_row(core.raw(ids),source)<0 || written[source] {continue}
                value:=core.raw_value(table,descriptor.info,row)
                for at in offsets {
                    target:=(^core.Entity)(uintptr(value)+at)^
                    if !going(es,marks,target) {continue}
                    marks[core.entity_index(target)]&~=ENTITY_GOING
                    kept+=1
                    changed=true
                }
            }
        }
        if !changed {return}
    }
}

// Puts the rows of a change set where it says: back to before it (forward
// false) or again to what it left (forward true), inside the open gesture.
// How many fields, components and entities stayed as someone else left them.
// The caller puts its files, settles the World and, after the last set,
// prunes what was turned (world_turned_prune).
change_set_rows_apply :: proc(w:core.World_Ref,set:^Change_Set,forward:bool) -> (kept:int) {
    from_present :: proc(row:^Change_Row,forward:bool) -> bool {return forward?row.before_present:row.after_present}
    to_present :: proc(row:^Change_Row,forward:bool) -> bool {return forward?row.after_present:row.before_present}
    removed:=make(map[base.Entity_Id]bool,context.temp_allocator)
    blocked:=make(map[base.Entity_Id]bool,context.temp_allocator)
    for &row in set.rows {
        if row.table<0 || row.table>=len(w.info.tables) || w.info.tables[row.table].type!=core.Id {continue}
        if !to_present(&row,forward) && from_present(&row,forward) {
            e:=change_entity(w,row.id)
            if e==core.NONE {removed[row.id]=true;continue}
            if !change_entity_clean(w,set,row.id,e,forward) {blocked[row.id]=true;kept+=1;continue}
            removed[row.id]=true
        }
    }
    // A kept entity may name one about to go: its parent, another reference.
    es:=core.world_entities(w)
    marks:=make([]u8,len(es.generation),context.temp_allocator)
    for id,remove in removed {
        if e:=change_entity(w,id);remove && e!=core.NONE {marks[core.entity_index(e)]|=ENTITY_GOING}
    }
    if entities_named_keep(w,marks)>0 {
        for id,remove in removed {
            if e:=change_entity(w,id);remove && e!=core.NONE && marks[core.entity_index(e)]&ENTITY_GOING==0 {
                removed[id]=false;blocked[id]=true
                kept+=1
            }
        }
    }
    for id,remove in removed {
        if remove {if entity:=change_entity(w,id);entity!=core.NONE {core.destroy(es,entity)}}
    }
    core.world_settle(w)
    // All the identities that come back exist before Parent and other references are remapped.
    for &row in set.rows {
        if row.table<0 || row.table>=len(w.info.tables) || w.info.tables[row.table].type!=core.Id {continue}
        if to_present(&row,forward) && !from_present(&row,forward) && change_entity(w,row.id)==core.NONE {
            entity:=core.create(core.world_entities(w))
            core.add(core.world_table_of(w,core.Id),entity,core.Id{row.id})
        }
    }
    core.world_settle(w)
    for &row in set.rows {
        if removed[row.id] || blocked[row.id] {continue}
        if row.table<0 || row.table>=len(w.info.tables) {kept+=1;continue}
        e:=change_entity(w,row.id)
        if e==core.NONE {kept+=1;continue}
        change_row_put(w,&row,e,forward,&kept)
    }
    return
}
