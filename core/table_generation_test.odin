package core

import "core:testing"

@(test)
table_replacement_by_a_new_generation_keeps_one_row_per_index_in_every_pending_order :: proc(t:^testing.T) {
    for order in 0..<4 {
        es:Entities;entities_init(&es);defer entities_destroy(&es)
        table:Table(i32);table_init(&table,"generation");defer table_destroy(&table)
        owner:Table(u16);table_init(&owner,"owner");defer table_destroy(&owner)
        locks:=[1]Lock{{offset=lock_offset(&table,&owner),id=1}}
        table.locks=locks[:]
        old,neighbor:=create(&es),create(&es)
        add(&table,old,11);add(&table,neighbor,22);table_settle(&table,&es)
        seen_version,seen_layout:=version(&table),layout(&table)
        // Undo can restore an entity pool before replacing its component rows.
        es.generation[entity_index(old)]+=1
        replacement:=entity_make(entity_index(old),es.generation[entity_index(old)])
        switch order {
        case 0: add(&table,replacement,33);remove(&table,old)
        case 1: remove(&table,old);add(&table,replacement,33)
        case 2: add(&table,replacement,33)
        case 3: add(&table,replacement,33);append(&es.doomed,old)
        }
        testing.expect(t,table_settle(&table,&es))
        testing.expect_value(t,count(&table),2)
        testing.expect(t,!has(&table,old) && has(&table,replacement) && has(&table,neighbor))
        testing.expect_value(t,table.entities[row_of(&table,replacement)],replacement)
        testing.expect_value(t,table.entities[row_of(&table,neighbor)],neighbor)
        testing.expect_value(t,table.values[row_of(&table,replacement)],i32(33))
        testing.expect_value(t,table.values[row_of(&table,neighbor)],i32(22))
        testing.expect(t,version(&table)>seen_version && layout(&table)>seen_layout)
        testing.expect_value(t,stamp(&table,row_of(&table,replacement)),version(&table))
        testing.expect_value(t,owner.owners[entity_index(replacement)],Row_Owner{entity_generation(replacement),1})
        for e,row in table.entities {
            testing.expect_value(t,row_of(&table,e),row)
            for other in table.entities[row+1:] {testing.expect(t,entity_index(e)!=entity_index(other))}
        }
    }
}

@(test)
locks_allow_a_new_generation_to_change_owner_before_the_old_owner_is_removed :: proc(t:^testing.T) {
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    target:Table(u8);table_init(&target,"target");defer table_destroy(&target)
    a,b:Table(i32);table_init(&a,"old writer");table_init(&b,"new writer")
    defer table_destroy(&a);defer table_destroy(&b)
    names:=[3]string{"","old writer","new writer"}
    locks_a:=[1]Lock{{offset=lock_offset(&a,&target),id=1,names=names[:],target="target"}}
    locks_b:=[1]Lock{{offset=lock_offset(&b,&target),id=2,names=names[:],target="target"}}
    a.locks,b.locks=locks_a[:],locks_b[:]
    old:=create(&es)
    add(&a,old,11);table_settle(&a,&es)
    es.generation[entity_index(old)]+=1
    replacement:=entity_make(entity_index(old),es.generation[entity_index(old)])
    add(&b,replacement,22);remove(&a,old)
    testing.expect(t,table_settle(&b,&es))
    testing.expect(t,table_settle(&a,&es))
    testing.expect_value(t,count(&a),0)
    testing.expect_value(t,count(&b),1)
    testing.expect_value(t,target.owners[entity_index(replacement)],Row_Owner{entity_generation(replacement),2})
}

@(test)
copied_and_published_locks_keep_their_generation_and_old_releases_cannot_clear_the_new_owner :: proc(t:^testing.T) {
    source,candidate:Table(i32)
    table_init(&source,"source");table_init(&candidate,"candidate")
    defer table_destroy(&source);defer table_destroy(&candidate)
    es:Entities;entities_init(&es);defer entities_destroy(&es)
    old:=create(&es)
    replacement:=entity_make(entity_index(old),entity_generation(old)+1)
    resize(&source.owners,entity_index(old)+1)
    source.owners[entity_index(old)]={entity_generation(old),1}
    source_lock:=[1]Lock{{offset=0,id=1}}
    candidate_lock:=[1]Lock{{offset=0,id=1}}
    source.locks,candidate.locks=source_lock[:],candidate_lock[:]
    testing.expect(t,table_copy(&candidate,&source))
    testing.expect_value(t,owner(&candidate,old),u16(1))
    testing.expect_value(t,owner(&candidate,replacement),u16(0))
    testing.expect(t,locks_claim(raw(&candidate),replacement,"candidate"))
    locks_release(raw(&candidate),old)
    testing.expect_value(t,owner(&candidate,replacement),u16(1))
    testing.expect_value(t,owner(&candidate,old),u16(0))
    seen:=version(&source)
    table_swap(&source,&candidate)
    testing.expect(t,lock_owners(raw(&source),source.locks[0])==&source.owners && lock_owners(raw(&candidate),candidate.locks[0])==&candidate.owners)
    testing.expect_value(t,owner(&source,replacement),u16(1))
    testing.expect_value(t,owner(&candidate,old),u16(1))
    testing.expect(t,version(&source)>seen)
    locks_release(raw(&source),old)
    testing.expect_value(t,owner(&source,replacement),u16(1))
    locks_release(raw(&source),replacement)
    testing.expect_value(t,owner(&source,replacement),u16(0))
}
