package asset

import "core:mem"
import "mirai:std/base"

// document_merge of two scenes or prefabs, and what a scene needs that a
// merge of rows does not give: parents that exist and close no loop, records
// of instances whose entities exist, the instance ids each side gave on its
// own made distinct, and the counters of Scene_Info at the highest of the
// three. Another kind of document merges as document_merge does.
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
    instances:[dynamic]Instance,
    members:[dynamic]Member,
    overrides:[dynamic]Override,
    off:[dynamic]Component_Off,
}

@(private="file")
records_read :: proc(doc:^Document,types:^Types,out:^Scene_Records) -> Error {
    allocator:=doc!=nil?doc.allocator:context.allocator
    out^={}
    out.info=make([dynamic]Scene_Info,allocator)
    out.instances=make([dynamic]Instance,allocator)
    out.members=make([dynamic]Member,allocator)
    out.overrides=make([dynamic]Override,allocator)
    out.off=make([dynamic]Component_Off,allocator)
    if doc==nil {return .None}
    read :: proc(doc:^Document,types:^Types,name:string,out:^[dynamic]$T) -> Error {
        if _,found:=document_table(doc,name);!found {return .None}
        return document_rows(doc,types,name,out)
    }
    read(doc,types,TABLE_SCENE,&out.info) or_return
    read(doc,types,TABLE_INSTANCES,&out.instances) or_return
    read(doc,types,TABLE_MEMBERS,&out.members) or_return
    read(doc,types,TABLE_OVERRIDES,&out.overrides) or_return
    return read(doc,types,TABLE_OFF,&out.off)
}

@(private="file")
records_destroy :: proc(records:^Scene_Records) {
    delete(records.info);delete(records.instances);delete(records.members);delete(records.overrides);delete(records.off)
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
        merge_conflict_add(m,.Removed,doc,table,row,true,true,".parent")
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
                merge_conflict_add(m,.Value,doc,table,row,true,true,".parent")
                opened=true
            }
            row=next
            if row==looped {break}
        }
        if !opened {
            parents[looped]=0
            merge_conflict_add(m,.Value,doc,table,looped,true,true,".parent")
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
    ours_had :: proc(list:[]$T,value:T) -> bool {
        for each in list {if each==value {return true}}
        return false
    }

    // Instances theirs placed take ids after every other when ours gave theirs.
    highest:u32
    for instance in now.instances {highest=max(highest,instance.id)}
    taken,no_taken:=make(map[u32]bool,len(now.instances),doc.allocator)
    defer delete(taken)
    if no_taken!=nil {return .Out_Of_Memory}
    for instance in now.instances {
        if ours_had(before.instances[:],instance) {taken[instance.id]=true}
    }
    renumbered:=make(map[u32]u32,doc.allocator)
    defer delete(renumbered)
    for &instance in now.instances {
        if ours_had(before.instances[:],instance) {continue}
        if instance.id in taken {
            highest+=1
            renumbered[instance.id]=highest
            instance.id=highest
        }
        taken[instance.id]=true
    }
    for &instance in now.instances {
        if !ours_had(before.instances[:],instance) {instance.outer=renumbered[instance.outer] or_else instance.outer}
    }
    for &member in now.members {
        if !ours_had(before.members[:],member) {member.instance=renumbered[member.instance] or_else member.instance}
    }
    for &override in now.overrides {
        if !ours_had(before.overrides[:],override) {override.instance=renumbered[override.instance] or_else override.instance}
    }

    // Records go with the entities and instances they are about.
    kept:=0
    for instance in now.instances {
        if !exists[instance.root] {continue}
        now.instances[kept]=instance
        kept+=1
    }
    base.truncate(&now.instances,kept)
    instance_known :: proc(instances:[]Instance,id:u32) -> bool {
        for instance in instances {if instance.id==id {return true}}
        return false
    }
    for &instance in now.instances {
        if instance.outer!=0 && (!instance_known(now.instances[:],instance.outer) || instance.outer>=instance.id) {instance.outer=0}
    }
    kept=0
    for member in now.members {
        if !exists[member.entity] || !instance_known(now.instances[:],member.instance) {continue}
        now.members[kept]=member
        kept+=1
    }
    base.truncate(&now.members,kept)
    kept=0
    for override in now.overrides {
        if !exists[override.entity] || !instance_known(now.instances[:],override.instance) {continue}
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

    // The counters only grow: the highest of the three, and no conflict over them.
    info:Scene_Info
    if len(now.info)>0 {info=now.info[0]}
    for list in ([][]Scene_Info{before.info[:],base_records.info[:],theirs_records.info[:]}) {
        for other in list {
            info.id_counter=max(info.id_counter,other.id_counter)
            info.last_instance=max(info.last_instance,other.last_instance)
        }
    }
    for instance in now.instances {info.last_instance=max(info.last_instance,instance.id)}
    for i:=len(m.conflicts)-1;i>=0;i-=1 {
        conflict:=m.conflicts[i]
        if conflict.table!=TABLE_SCENE || (conflict.path!="scene.value.id_counter" && conflict.path!="scene.value.last_instance" && conflict.path!="scene.id_counter" && conflict.path!="scene.last_instance") {continue}
        delete(conflict.path,m.conflicts.allocator)
        delete(conflict.table,m.conflicts.allocator)
        ordered_remove(&m.conflicts,i)
    }

    for name in ([]string{TABLE_SCENE,TABLE_INSTANCES,TABLE_MEMBERS,TABLE_OVERRIDES,TABLE_OFF}) {
        if table,found:=document_table(doc,name);found {document_table_remove(doc,table)}
    }
    if len(now.info)>0 || len(before.info)>0 {document_put_row(doc,types,TABLE_SCENE,&info) or_return}
    if len(now.instances)>0 {document_put(doc,types,TABLE_INSTANCES,now.instances[:],{},.LZ) or_return}
    if len(now.members)>0 {document_put(doc,types,TABLE_MEMBERS,now.members[:],{},.LZ) or_return}
    if len(now.overrides)>0 {document_put(doc,types,TABLE_OVERRIDES,now.overrides[:],{},.LZ) or_return}
    if len(now.off)>0 {document_put(doc,types,TABLE_OFF,now.off[:],{},.LZ) or_return}
    return .None
}
