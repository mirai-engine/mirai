package core

import "base:runtime"
import "core:mem"

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
    rows:[dynamic]i32, // directory length, directory (page offset + 1), then packed pages
}

@(private="file")
entity_rows_slot :: #force_inline proc "contextless" (rows:[]i32,index:int) -> int {
    page:=index>>ROWS_PAGE_BITS
    if len(rows)==0 || page>=int(rows[0]) || rows[1+page]==0 {return -1}
    return int(rows[0])+int(rows[1+page])+(index&(ROWS_PAGE-1))
}

@(private="file")
entity_rows_count :: #force_inline proc "contextless" (rows:[]i32) -> int {
    return len(rows)==0?0:int(rows[0])
}

@(private="file")
entity_rows_reserve :: proc(rows:^[dynamic]i32,pages,missing:int) -> bool {
    before:=entity_rows_count(rows[:])
    directory:=pages<=before?before:max(pages,2*before)
    values:=max(len(rows)-before-1,0)
    if missing>(int(max(i32))-directory-values-1)/ROWS_PAGE {return false}
    needed:=1+directory+values+missing*ROWS_PAGE
    if needed>cap(rows) && reserve(rows,max(needed,2*cap(rows)))!=nil {return false}
    if directory!=before {
        (cast(^runtime.Raw_Dynamic_Array)rows).len=1+directory+values
        copy(rows[directory+1:],rows[before+1:][:values])
        mem.zero_slice(rows[before+1:directory+1])
        rows[0]=i32(directory)
    }
    return true
}

@(private="file")
entity_rows_add :: proc(rows:^[dynamic]i32,page:int) -> bool {
    if rows[page+1]!=0 {return true}
    start:=len(rows)
    if resize(rows,start+ROWS_PAGE)!=nil {return false}
    rows[1+page]=i32(start-int(rows[0]))
    return true
}

// Where the value of an entity is in values; -1 without one.
entity_map_index :: #force_inline proc "contextless" (m:^Entity_Map($T),e:Entity) -> int {
    slot:=entity_rows_slot(m.rows[:],entity_index(e))
    at:=slot<0?-1:int(m.rows[slot])-1
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
    slot:=entity_rows_slot(m.rows[:],entity_index(e))
    return slot<0 || m.rows[slot]==0?NONE:m.entities[m.rows[slot]-1]
}

// Gives an entity a value, or replaces the one it has or the one of another
// generation of its index, and says where it is. A new one goes last. False
// without memory or for NONE: the map stays as it was.
entity_map_put :: proc(m:^Entity_Map($T),e:Entity,value:T) -> (^T,bool) {
    if e==NONE {return nil,false}
    i:=entity_index(e)
    slot:=entity_rows_slot(m.rows[:],i)
    if slot>=0 && m.rows[slot]!=0 {
        at:=int(m.rows[slot])-1
        m.values[at]=value
        m.entities[at]=e
        return &m.values[at],true
    }
    if !entity_map_reserve(m,len(m.values)+1) {return nil,false}
    if slot<0 {
        page:=i>>ROWS_PAGE_BITS
        if !entity_rows_reserve(&m.rows,page+1,1) || !entity_rows_add(&m.rows,page) {
            return nil,false
        }
        slot=entity_rows_slot(m.rows[:],i)
    }
    // Reserved: neither asks for memory.
    if _,err:=append(&m.values,value);err!=nil {return nil,false}
    if _,err:=append(&m.entities,e);err!=nil {pop(&m.values);return nil,false}
    m.rows[slot]=i32(len(m.values))
    return &m.values[len(m.values)-1],true
}

// Room for count values and for the entities of index below indices: putting
// them neither allocates nor moves the values. False without memory.
entity_map_reserve :: proc(m:^Entity_Map($T),count:int,indices:=0) -> bool {
    if count>cap(m.values) || count>cap(m.entities) {
        capacity:=max(count,2*cap(m.values))
        if reserve(&m.values,capacity)!=nil || reserve(&m.entities,capacity)!=nil {return false}
    }
    if indices<=0 {return true}
    pages:=((indices-1)>>ROWS_PAGE_BITS)+1
    directory:=entity_rows_count(m.rows[:])
    missing:=pages-min(pages,directory)
    for at in 1..=min(pages,directory) {missing+=int(m.rows[at]==0)}
    if missing==0 {return true}
    if !entity_rows_reserve(&m.rows,pages,missing) {return false}
    for page in 0..<pages {
        if !entity_rows_add(&m.rows,page) {return false}
    }
    return true
}

// Makes dst hold what src holds, for plain values: a copy of their bytes,
// which allocates only when dst lacks the room. False without memory.
entity_map_copy :: proc(dst,src:^Entity_Map($T)) -> bool {
    if dst==src {return true}
    if !entity_map_reserve(dst,len(src.values)) || reserve(&dst.rows,len(src.rows))!=nil {
        return false
    }
    (cast(^runtime.Raw_Dynamic_Array)&dst.values).len=len(src.values)
    (cast(^runtime.Raw_Dynamic_Array)&dst.entities).len=len(src.entities)
    (cast(^runtime.Raw_Dynamic_Array)&dst.rows).len=len(src.rows)
    copy(dst.values[:],src.values[:])
    copy(dst.entities[:],src.entities[:])
    copy(dst.rows[:],src.rows[:])
    return true
}

// Takes out the value at an index of values: the last one takes its place.
entity_map_remove_at :: proc(m:^Entity_Map($T),at:int) {
    m.rows[entity_rows_slot(m.rows[:],entity_index(m.entities[at]))]=0
    last:=len(m.values)-1
    if at!=last {
        // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
        m.values[at]=m.values[last]
        m.entities[at]=m.entities[last]
        m.rows[entity_rows_slot(m.rows[:],entity_index(m.entities[at]))]=i32(at+1)
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
entity_map_left :: proc(m:^Entity_Map($T),table:^Table($C,$A),c:Changes,at:^int,left:^T) -> (e:Entity,ok:bool) {
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
entity_map_prune :: proc(m:^Entity_Map($T),table:^Table($C,$A),c:Changes) -> (count:int) {
    at:=0
    for _ in entity_map_left(m,table,c,&at,nil) {count+=1}
    return
}

// No value; the memory stays for the next ones. What the values hold is the caller's.
entity_map_clear :: proc(m:^Entity_Map($T)) {
    for e in m.entities {m.rows[entity_rows_slot(m.rows[:],entity_index(e))]=0}
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
