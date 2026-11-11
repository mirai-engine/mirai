package asset

import "core:mem"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// document_merge of two scenes or prefabs, and what a scene needs that a
// merge of rows does not give: parents that exist and close no loop, records
// about entities that exist, members whose root is still the root of an
// instance, an instance both sides brought up to date marked as not known to
// be, and the counter of Scene_Info at the highest of the three. Another kind
// of document merges as document_merge does.
scene_merge :: proc(m:^Merge,types:^Types,ours,origin,theirs:^Document) -> Error {
    if ours.kind!=KIND_SCENE && ours.kind!=KIND_PREFAB {return document_merge(m,ours,origin,theirs)}
    before:Scene_Records
    records_read(ours,types,&before) or_return
    defer records_destroy(&before)
    parents:=make(map[base.Entity_Id]base.Entity_Id,ours.allocator)
    defer delete(parents)
    if ids,links,found:=entity_columns(ours);found {
        for id,row in ids {parents[id]=links[row]}
    }
    document_merge(m,ours,origin,theirs) or_return
    parents_fix(m,ours,parents) or_return
    return records_fix(m,ours,origin,theirs,types,&before)
}

@(private="file")
Scene_Records :: struct {
    info:[dynamic]Scene_Info,
    overrides:[dynamic]Override,
    off:[dynamic]Component_Off,
}

@(private="file")
records_read :: proc(doc:^Document,types:^Types,out:^Scene_Records) -> Error {
    allocator:=doc!=nil?doc.allocator:context.allocator
    out^={}
    out.info=make([dynamic]Scene_Info,allocator)
    out.overrides=make([dynamic]Override,allocator)
    out.off=make([dynamic]Component_Off,allocator)
    if doc==nil {return .None}
    read :: proc(doc:^Document,types:^Types,name:string,out:^[dynamic]$T) -> Error {
        if _,found:=document_table(doc,name);!found {return .None}
        return document_rows(doc,types,name,out)
    }
    read(doc,types,TABLE_SCENE,&out.info) or_return
    read(doc,types,TABLE_OVERRIDES,&out.overrides) or_return
    return read(doc,types,TABLE_OFF,&out.off)
}

@(private="file")
records_destroy :: proc(records:^Scene_Records) {
    delete(records.info);delete(records.overrides);delete(records.off)
}

@(private="file")
entity_columns :: proc(doc:^Document) -> (ids,parents:[]base.Entity_Id,found:bool) {
    table,has:=document_table(doc,TABLE_ENTITIES)
    if !has {return}
    id_column,has_id:=document_column(doc,table,"id")
    parent_column,has_parent:=document_column(doc,table,"parent")
    columns:=doc.tables[table].columns[:]
    if !has_id || !has_parent || columns[id_column].size!=8 || columns[parent_column].size!=8 {return}
    return mem.slice_data_cast([]base.Entity_Id,columns[id_column].data),mem.slice_data_cast([]base.Entity_Id,columns[parent_column].data),true
}

// A parent the merge removed leaves its child at the root; a loop the two
// sides closed between them opens where a parent is not the one of ours.
@(private="file")
parents_fix :: proc(m:^Merge,doc:^Document,before:map[base.Entity_Id]base.Entity_Id) -> Error {
    ids,parents,found:=entity_columns(doc)
    if !found {return .None}
    table,_:=document_table(doc,TABLE_ENTITIES)
    rows,no_rows:=make(map[base.Entity_Id]int,len(ids),doc.allocator)
    defer delete(rows)
    state,no_state:=make([]u8,len(ids),doc.allocator)
    defer delete(state,doc.allocator)
    if no_rows!=nil || no_state!=nil {return .Out_Of_Memory}
    for id,row in ids {rows[id]=row}
    for &parent,row in parents {
        if parent==0 || parent in rows {continue}
        parent=0
        if !merge_conflict_add(m,.Removed,doc,table,row,true,true,".parent") {return .Out_Of_Memory}
    }
    for {
        mem.zero_slice(state)
        looped:=-1
        search: for start in 0..<len(ids) {
            row:=start
            for state[row]==0 {
                state[row]=1
                if parents[row]==0 {break}
                row=rows[parents[row]]
                if state[row]==1 {looped=row;break search}
            }
            for row=start;state[row]==1; {
                state[row]=2
                if parents[row]==0 {break}
                row=rows[parents[row]]
            }
        }
        if looped<0 {return .None}
        opened:=false
        row:=looped
        for {
            next:=rows[parents[row]]
            original:=before[ids[row]] or_else 0
            if parents[row]!=original {
                parents[row]=original
                if original!=0 && !(original in rows) {parents[row]=0}
                if !merge_conflict_add(m,.Value,doc,table,row,true,true,".parent") {return .Out_Of_Memory}
                opened=true
            }
            row=next
            if row==looped {break}
        }
        if !opened {
            parents[looped]=0
            if !merge_conflict_add(m,.Value,doc,table,looped,true,true,".parent") {return .Out_Of_Memory}
        }
    }
}

@(private="file")
records_fix :: proc(m:^Merge,doc,origin,theirs:^Document,types:^Types,before:^Scene_Records) -> Error {
    now,base_records,theirs_records:Scene_Records
    records_read(doc,types,&now) or_return
    defer records_destroy(&now)
    records_read(origin,types,&base_records) or_return
    defer records_destroy(&base_records)
    records_read(theirs,types,&theirs_records) or_return
    defer records_destroy(&theirs_records)
    ids,_,_:=entity_columns(doc)
    exists,no_exists:=make(map[base.Entity_Id]bool,len(ids),doc.allocator)
    defer delete(exists)
    if no_exists!=nil {return .Out_Of_Memory}
    for id in ids {exists[id]=true}

    // Records go with the entities they are about.
    kept:=0
    for override in now.overrides {
        if !exists[override.entity] {continue}
        now.overrides[kept]=override
        kept+=1
    }
    base.truncate(&now.overrides,kept)
    kept=0
    for record in now.off {
        if !exists[record.entity] {continue}
        now.off[kept]=record
        kept+=1
    }
    base.truncate(&now.off,kept)

    // The counter only grows: the highest of the three, and no conflict over it.
    info:Scene_Info
    if len(now.info)>0 {info=now.info[0]}
    for list in ([][]Scene_Info{before.info[:],base_records.info[:],theirs_records.info[:]}) {
        for other in list {info.id_counter=max(info.id_counter,other.id_counter)}
    }
    for i:=len(m.conflicts)-1;i>=0;i-=1 {
        conflict:=m.conflicts[i]
        counter:=conflict.table==TABLE_SCENE && (conflict.path=="scene.value.id_counter" || conflict.path=="scene.id_counter")
        // Each side brought the instance up to date with another file: what the rows hold is of neither.
        stale:=conflict.table==COMPONENT_INSTANCE && strings.has_suffix(conflict.path,".value.stamp")
        if !counter && !stale {continue}
        if stale {instance_stamp_forget(doc,base.Entity_Id(conflict.key))}
        delete(conflict.path,m.conflicts.allocator)
        delete(conflict.table,m.conflicts.allocator)
        ordered_remove(&m.conflicts,i)
    }

    for name in ([]string{TABLE_SCENE,TABLE_OVERRIDES,TABLE_OFF}) {
        if table,found:=document_table(doc,name);found {document_table_remove(doc,table)}
    }
    if len(now.info)>0 || len(before.info)>0 {document_put_row(doc,types,TABLE_SCENE,&info) or_return}
    if len(now.overrides)>0 {document_put(doc,types,TABLE_OVERRIDES,now.overrides[:],{},.LZ) or_return}
    if len(now.off)>0 {document_put(doc,types,TABLE_OFF,now.off[:],{},.LZ) or_return}
    return members_fix(doc)
}

// A component table of the document and the entity each of its rows is of.
@(private="file")
component_rows_of :: proc(doc:^Document,name:string) -> (table:int,rows:[]u32,ids:[]base.Entity_Id,found:bool) {
    table=document_table(doc,name) or_return
    target:=&doc.tables[table]
    if len(target.columns)!=2 || target.columns[0].size!=size_of(u32) {return}
    ids,_,found=entity_columns(doc)
    return table,mem.slice_data_cast([]u32,target.columns[0].data),ids,found
}

// The part of the value of a row that a field holds; nil without it.
@(private="file")
component_field :: proc(doc:^Document,table,row:int,field:string) -> []u8 {
    column:=&doc.tables[table].columns[1]
    _,part,error:=serial.value_slice(&doc.schema,column.type,column.data[row*column.size:][:column.size],field)
    return error==.None?part:nil
}

// The instance rooted at an entity is not known to be up to date with any file.
@(private="file")
instance_stamp_forget :: proc(doc:^Document,root:base.Entity_Id) {
    table,rows,ids,found:=component_rows_of(doc,COMPONENT_INSTANCE)
    if !found {return}
    for entity,row in rows {
        if int(entity)<len(ids) && ids[entity]==root {mem.zero_slice(component_field(doc,table,row,"stamp"))}
    }
}

// A member goes with the instance that placed it: one whose root the merge
// left without its instance is an ordinary entity.
@(private="file")
members_fix :: proc(doc:^Document) -> Error {
    table,rows,ids,found:=component_rows_of(doc,COMPONENT_MEMBER)
    if !found {return .None}
    roots,no_roots:=make(map[base.Entity_Id]bool,len(rows),doc.allocator)
    defer delete(roots)
    if no_roots!=nil {return .Out_Of_Memory}
    if _,placed,_,any:=component_rows_of(doc,COMPONENT_INSTANCE);any {
        for entity in placed {
            if int(entity)<len(ids) {roots[ids[entity]]=true}
        }
    }
    for row:=len(rows)-1;row>=0;row-=1 {
        root:u64
        if part:=component_field(doc,table,row,"instance");len(part)==size_of(u64) {mem.copy(&root,raw_data(part),size_of(u64))}
        if !roots[base.Entity_Id(root)] {document_rows_remove(doc,table,row,1) or_return}
    }
    return .None
}
