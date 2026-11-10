package core

// A value for each of some entities: what a library keeps of the entities of
// a table, as a voice, a clock or what the renderer was told. The values are
// dense, with their entity at the same index of entities, and an entity finds
// its own in constant time. Removing one moves the last into its place.
// Growing checks memory, and putting, removing and pruning without new
// entities do not allocate. An index holds one generation: putting a newer
// one replaces the value of the older, so a mirror prunes first what holds
// something to release.
Entity_Map :: struct($T:typeid) {
    values:[dynamic]T,
    entities:[dynamic]Entity, // by value
    rows:[dynamic]i32,        // by entity index: value+1, 0 without one
}

// Where the value of an entity is in values; -1 without one.
entity_map_index :: #force_inline proc "contextless" (m:^Entity_Map($T),e:Entity) -> int {
    i:=entity_index(e)
    if i>=len(m.rows) {return -1}
    at:=int(m.rows[i])-1
    if at<0 || m.entities[at]!=e {return -1}
    return at
}

// The value of an entity; nil without one.
entity_map_get :: #force_inline proc "contextless" (m:^Entity_Map($T),e:Entity) -> ^T {
    at:=entity_map_index(m,e)
    return at<0?nil:&m.values[at]
}

// The entity whose value the index of e holds: e, another generation of its
// index, or NONE. Before putting e, a value that holds something to release
// looks here for the one it would replace.
entity_map_held :: #force_inline proc "contextless" (m:^Entity_Map($T),e:Entity) -> Entity {
    i:=entity_index(e)
    if i>=len(m.rows) || m.rows[i]==0 {return NONE}
    return m.entities[m.rows[i]-1]
}

// Gives an entity a value, or replaces the one it has or the one of another
// generation of its index, and says where it is. A new one goes last. False
// without memory or for NONE: the map stays as it was.
entity_map_put :: proc(m:^Entity_Map($T),e:Entity,value:T) -> (^T,bool) {
    if e==NONE {return nil,false}
    i:=entity_index(e)
    if i<len(m.rows) && m.rows[i]!=0 {
        at:=int(m.rows[i])-1
        m.values[at]=value
        m.entities[at]=e
        return &m.values[at],true
    }
    if !entity_map_reserve(m,len(m.values)+1,i+1) {return nil,false}
    append(&m.values,value)
    append(&m.entities,e)
    m.rows[i]=i32(len(m.values))
    return &m.values[len(m.values)-1],true
}

// Room for count values and for the entities of index below indices: putting
// them neither allocates nor moves the values. False without memory.
entity_map_reserve :: proc(m:^Entity_Map($T),count:int,indices:=0) -> bool {
    if count>cap(m.values) || count>cap(m.entities) {
        capacity:=max(count,2*cap(m.values))
        if reserve(&m.values,capacity)!=nil || reserve(&m.entities,capacity)!=nil {return false}
    }
    if indices>len(m.rows) {
        if indices>cap(m.rows) && reserve(&m.rows,max(indices,2*cap(m.rows)))!=nil {return false}
        if resize(&m.rows,indices)!=nil {return false}
    }
    return true
}

// Makes dst hold what src holds, for plain values: a copy of their bytes,
// which allocates only when dst lacks the room. False without memory.
entity_map_copy :: proc(dst,src:^Entity_Map($T)) -> bool {
    if dst==src {return true}
    if non_zero_resize(&dst.values,len(src.values))!=nil || non_zero_resize(&dst.entities,len(src.entities))!=nil || non_zero_resize(&dst.rows,len(src.rows))!=nil {return false}
    copy(dst.values[:],src.values[:])
    copy(dst.entities[:],src.entities[:])
    copy(dst.rows[:],src.rows[:])
    return true
}

// Takes out the value at an index of values: the last one takes its place.
entity_map_remove_at :: proc(m:^Entity_Map($T),at:int) {
    m.rows[entity_index(m.entities[at])]=0
    last:=len(m.values)-1
    if at!=last {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        m.values[at]=m.values[last]
        m.entities[at]=m.entities[last]
        m.rows[entity_index(m.entities[at])]=i32(at+1)
    }
    pop(&m.values)
    pop(&m.entities)
}

// Takes out the value of an entity; false without one.
entity_map_remove :: proc(m:^Entity_Map($T),e:Entity) -> bool {
    at:=entity_map_index(m,e)
    if at<0 {return false}
    entity_map_remove_at(m,at)
    return true
}

// Takes out, one at a time, the value of each entity that left a table since
// its reader looked (core.changes): those of c.gone without a row on there
// now and, with c.all, every one without a row on. The value goes to left
// (nil: nowhere), and what it holds is the caller's. at starts at 0, and the
// loop calls it with the same changes:
//
//   c,at,left:=core.changes(sources,&voices.seen),0,Voice_Entry{}
//   for e in core.entity_map_left(&voices.entries,sources,c,&at,&left) {...}
entity_map_left :: proc(m:^Entity_Map($T),table:Read($C),c:Changes,at:^int,left:^T) -> (e:Entity,ok:bool) {
    found:=-1
    if c.all {
        // at counts the values kept at the end; the one before them is next.
        for last:=len(m.values)-1-at^;last>=0 && found<0;last=len(m.values)-1-at^ {
            if has(table,m.entities[last]) {at^+=1} else {found=last}
        }
    } else {
        for at^<len(c.gone) && found<0 {
            at^+=1
            if !has(table,c.gone[at^-1]) {found=entity_map_index(m,c.gone[at^-1])}
        }
    }
    if found<0 {return}
    e,ok=m.entities[found],true
    if left!=nil {left^=m.values[found]}
    entity_map_remove_at(m,found)
    return
}

// Takes out the values of the entities that left a table, for values that
// hold nothing to release; how many went.
entity_map_prune :: proc(m:^Entity_Map($T),table:Read($C),c:Changes) -> (count:int) {
    at:=0
    for _ in entity_map_left(m,table,c,&at,nil) {count+=1}
    return
}

// No value; the memory stays for the next ones. What the values hold is the caller's.
entity_map_clear :: proc(m:^Entity_Map($T)) {
    for e in m.entities {m.rows[entity_index(e)]=0}
    clear(&m.values)
    clear(&m.entities)
}

// Frees the memory of the map; what the values hold is the caller's.
entity_map_destroy :: proc(m:^Entity_Map($T)) {
    delete(m.values)
    delete(m.entities)
    delete(m.rows)
    m^={}
}
