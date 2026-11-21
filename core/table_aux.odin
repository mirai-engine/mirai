package core

import "core:mem"
import "core:slice"

Table_Aux :: struct {
    off:[dynamic]bool, // by row, turned off independently of its entity
    turns:[dynamic]u64, // by row of a single table, zero if it does not wait to be on
    owners:[dynamic]Row_Owner, // by entity index, including the generation
}

@(private)
aux_make :: proc(t:^Raw_Table) -> ^Table_Aux {
    if t.aux!=nil {return t.aux}
    allocator:=t.values.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    aux,error:=new(Table_Aux,allocator)
    if error!=nil {return nil}
    t.values.allocator=allocator
    aux.off.allocator=allocator
    aux.turns.allocator=allocator
    aux.owners.allocator=allocator
    t.aux=aux
    return aux
}

@(private)
aux_free :: proc(t:^Raw_Table) {
    if aux:=t.aux;aux!=nil {
        delete(aux.off);delete(aux.turns);delete(aux.owners)
        mem.free(aux,t.values.allocator)
    }
}

@(private)
aux_clear_rows :: proc "contextless" (t:^Raw_Table) {
    if aux:=t.aux;aux!=nil {clear(&aux.off);clear(&aux.turns)}
}

row_off :: #force_inline proc "contextless" (t:^Table($T,$A),row:int) -> bool {
    return raw_off(raw(t),row)
}

raw_off :: #force_inline proc "contextless" (t:^Raw_Table,row:int) -> bool {
    return t.aux!=nil && uint(row)<uint(len(t.aux.off)) && t.aux.off[row]
}

@(private)
off_rows :: #force_inline proc "contextless" (t:^Raw_Table) -> []bool {
    return t.aux==nil?nil:t.aux.off[:]
}

raw_off_equal :: #force_inline proc "contextless" (a,b:^Raw_Table) -> bool {
    if raw_count(a)!=raw_count(b) {return false}
    x,y:=off_rows(a),off_rows(b)
    if len(x)==len(y) {return slice.equal(x,y)}
    for off in (len(x)>0?x:y) {if off {return false}}
    return true
}

@(private)
off_set :: #force_inline proc "contextless" (t:^Raw_Table,row:int,off:bool) {
    if t.aux!=nil && len(t.aux.off)>0 {t.aux.off[row]=off}
}

@(private)
off_push :: #force_inline proc(t:^Raw_Table,off:bool) {
    if t.aux!=nil && cap(t.aux.off)>0 {append(&t.aux.off,off)}
}

@(private)
aux_needs_off :: #force_inline proc "contextless" (t:^Raw_Table,with_off:bool) -> bool {
    return t.single || with_off && !t.base || t.lock_plan!=nil ||
           t.aux!=nil && cap(t.aux.off)>0
}

@(private)
aux_rows_reserve :: proc(t:^Raw_Table,rows:int,with_off:bool) -> bool {
    if rows==0 || !aux_needs_off(t,with_off) {return true}
    aux:=aux_make(t)
    if aux==nil || reserve(&aux.off,rows)!=nil {return false}
    if t.single && reserve(&aux.turns,rows)!=nil {return false}
    return resize(&aux.off,t.values.len)==nil
}

@(private)
aux_has_room :: #force_inline proc "contextless" (t:^Raw_Table,rows:int,off:bool) -> bool {
    return !aux_needs_off(t,off) ||
        t.aux!=nil && cap(t.aux.off)>=rows && (!t.single || cap(t.aux.turns)>=rows)
}

@(private)
owner_at :: #force_inline proc "contextless" (t:^Raw_Table,index:int) -> Row_Owner {
    if t.aux==nil || uint(index)>=uint(len(t.aux.owners)) {return {}}
    return t.aux.owners[index]
}

@(private)
owners_reserve :: proc(t:^Raw_Table,rows:int) -> bool {
    if rows<=0 {return true}
    aux:=aux_make(t)
    return aux!=nil && (rows<=len(aux.owners) || resize(&aux.owners,rows)==nil)
}

owner_set :: #force_inline proc(t:^Table($T),e:Entity,id:u16) -> bool {
    target:=raw(t)
    i:=entity_index(e)
    if e==NONE {return false}
    if id==0 {
        held:=owner_at(target,i)
        if held.id==0 || held.generation!=entity_generation(e) {return true}
    } else if !owners_reserve(target,i+1) {return false}
    owner_set_reserved(target,i,id==0?Row_Owner{}:Row_Owner{entity_generation(e),id})
    return true
}

@(private)
owner_set_reserved :: #force_inline proc(t:^Raw_Table,index:int,held:Row_Owner) {
    t.aux.owners[index]=held
    t.version=version_top(t)+1
}

raw_locks :: #force_inline proc "contextless" (t:^Raw_Table) -> []Lock {
    return t.lock_plan==nil?nil:t.lock_plan^
}

raw_locks_reserve :: proc(t:^Raw_Table,rows:int) -> bool {
    for lock in raw_locks(t) {
        if !owners_reserve(lock_table(t,lock),rows) {return false}
    }
    return true
}

@(private)
aux_ownership_equal :: proc "contextless" (a,b:^Raw_Table) -> bool {
    x,y:=a.aux,b.aux
    if x==nil {return y==nil || len(y.turns)==0 && len(y.owners)==0}
    if y==nil {return len(x.turns)==0 && len(x.owners)==0}
    return slice.equal(x.turns[:],y.turns[:]) && slice.equal(x.owners[:],y.owners[:])
}

@(private)
aux_copy :: proc(dst,src:^Raw_Table) -> bool {
    from:=src.aux
    off,turns,owners:=0,0,0
    if from!=nil {off,turns,owners=len(from.off),len(from.turns),len(from.owners)}
    to:=dst.aux
    if to!=nil && cap(to.off)>0 {off=src.values.len}
    if off+turns+owners>0 {
        to=aux_make(dst)
        if to==nil || reserve(&to.off,off)!=nil || reserve(&to.turns,turns)!=nil ||
           reserve(&to.owners,owners)!=nil {return false}
    }
    if to==nil {return true}
    if resize(&to.off,off)!=nil || resize(&to.turns,turns)!=nil ||
       resize(&to.owners,owners)!=nil {return false}
    if from!=nil && len(from.off)>0 {copy(to.off[:],from.off[:])} else {mem.zero_slice(to.off[:])}
    if from!=nil {
        copy(to.turns[:],from.turns[:])
        copy(to.owners[:],from.owners[:])
    }
    return true
}

table_aux_bytes :: proc "contextless" (t:^Raw_Table) -> int {
    aux:=t.aux
    if aux==nil {return 0}
    return size_of(Table_Aux)+cap(aux.off)*size_of(bool)+cap(aux.turns)*size_of(u64)+
        cap(aux.owners)*size_of(Row_Owner)
}
