package core

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"

// The rows of one component: values, entities, stamps and off are parallel
// and dense. The rows below on are on; the others keep their values but are
// off, turned off by themselves (disable) or with their entity (Disabled).
// count, get, has, row_of and writable see the rows on; the raw_* procedures
// of reflection see every row. Adds, removes and turns wait in pending until
// the function that made them ends (world_settle), so no loop over a table
// and no pointer into it is broken inside a function.
//
// Reading stamps nothing: get, at, has and row_of only look. Every write
// raises version, and the row written takes it as its stamp: a row asked for
// to write (edit, edit_at, free, writable, touch), given another value (set),
// replaced by an add or turned on. A reader that keeps what it saw finds what
// changed since with changes: the rows stamped above the version it saw,
// which each_changed goes through, and in gone the entities whose row stopped
// being on or went while off; one that only makes again what it derives asks
// touched. layout grows whenever the rows are others. Both only grow, also in
// a table copied over. The stamp of a write is even and that of an add odd: a
// row is added, new to its writer, until it is written (added).
//
// A single table (@(component,single)) keeps on one row: of the rows that
// were turned on and whose entity is on, the one turned on last. Turning one
// on (enable) turns off the one that was on, which waits behind it; turning
// that one off, or its entity, or taking it away, turns on again the one
// turned on before. A row added while another is on comes off and waits for
// no turn, and one turned off (disable) waits no more: only enable turns them
// on. What a section, a prefab or a joined World brings comes off whatever is
// on (world_union, and the scene library for what it instantiates).
Table :: struct($T:typeid) {
    values:[dynamic]T,
    entities:[dynamic]Entity,
    stamps:[dynamic]u64,      // by row: the version of its last write
    page_stamps:[dynamic]u64, // by page of STAMP_PAGE rows: no stamp of its rows is above it
    off:[dynamic]bool,        // by row: turned off by itself, whatever its entity
    turns:[dynamic]u64,       // single tables, by row: how late it was turned on, the latest on; 0: it does not wait to be on
    rows:[dynamic][]i32,      // by entity index, in pages: row+1, 0 without one
    pending:[dynamic]Pending,
    added:[dynamic]T,         // values of the pending adds
    gone:Log(Entity),         // the entities whose row stopped being on; its room is made when the first one goes
    version:u64,
    layout:u64,               // grows when rows are added, removed, turned on or off, or replaced whole
    on:int,                   // the rows below it are on
    base:bool,                // identity, transform or hierarchy: on while its entity is disabled
    single:bool,              // @(component,single): at most one row on, by turns
    owners:[dynamic]Row_Owner, // shared tables: by index, the generation and lock that own the row
    locks:[]Lock,             // rows of other tables a row on of this one owns
    name:string,
    waits:Waits,
}

// Where a table of a World says that it has adds, removes or turns pending,
// for the settle of the World to come only to the tables that do: its place
// in the pending of the Entities offset bytes away from it, in the same
// World (by distance, as a lock: a World is copied in blocks). Zero in a
// table by itself and in a World made by hand, whose settle looks at every
// table.
Waits :: struct {
    offset:int,
    index:int,
}

// Makes a table of a World say what it has pending in es.pending[index]:
// entities_tables gave it room.
table_follow :: proc "contextless" (t:^Table($T),es:^Entities,index:int) {raw_follow(raw(t),es,index)}

raw_follow :: proc "contextless" (t:^Raw_Table,es:^Entities,index:int) {
    t.waits={int(uintptr(es))-int(uintptr(t)),index}
}

// Every change that waits for the settle goes through here.
@(private)
pending_push :: #force_inline proc(t:^Raw_Table,p:Pending) {
    append(&t.pending,p)
    table_waits(t)
}

@(private)
table_waits :: #force_inline proc "contextless" (t:^Raw_Table,waits:=true) {
    if t.waits.offset!=0 {(cast(^Entities)rawptr(uintptr(int(uintptr(t))+t.waits.offset))).pending[t.waits.index]=waits}
}

// The rows by entity index of a table come in pages of ROWS_PAGE indices,
// made when an entity of theirs first gets a row and kept from then on: a
// table holds them for the entities it had rows of, not for every entity of
// its World. An empty page: no entity of it has had a row. Pages are slices
// so that a table copies, compares and frees as any value does (value_copy).
ROWS_PAGE_BITS :: 12
ROWS_PAGE :: 1<<ROWS_PAGE_BITS

// row+1 of the entity of an index; 0 without one.
@(private)
rows_at :: #force_inline proc "contextless" (t:^Raw_Table,i:int) -> i32 {
    p:=i>>ROWS_PAGE_BITS
    if p>=len(t.rows) {return 0}
    page:=raw_data(t.rows[p])
    return page==nil?0:page[i&(ROWS_PAGE-1)]
}

// The page of the index is there: rows_room made it.
@(private)
rows_set :: #force_inline proc "contextless" (t:^Raw_Table,i:int,row:i32) {
    raw_data(t.rows[i>>ROWS_PAGE_BITS])[i&(ROWS_PAGE-1)]=row
}

// Room for the row of the entity of an index, in a World of capacity
// entities. False without memory.
@(private)
rows_room :: proc(t:^Raw_Table,i,capacity:int) -> bool {
    p:=i>>ROWS_PAGE_BITS
    if p>=len(t.rows) && resize(&t.rows,max(p+1,(capacity+ROWS_PAGE-1)>>ROWS_PAGE_BITS))!=nil {return false}
    if len(t.rows[p])>0 {return true}
    page,error:=make([]i32,ROWS_PAGE,t.rows.allocator)
    if error!=nil {return false}
    t.rows[p]=page
    return true
}

@(private)
rows_has_room :: #force_inline proc "contextless" (t:^Raw_Table,i:int) -> bool {
    p:=i>>ROWS_PAGE_BITS
    return p<len(t.rows) && len(t.rows[p])>0
}

// No entity has a row; the pages stay.
@(private)
rows_zero :: proc "contextless" (t:^Raw_Table) {
    for page in t.rows {mem.zero_slice(page)}
}

// Makes the rows by entity of dst those of src, in the pages dst has and
// those it lacks. False without memory.
@(private)
rows_copy :: proc(dst,src:^Raw_Table) -> bool {
    if dst.rows.allocator.procedure==nil {dst.rows.allocator=context.allocator}
    if len(dst.rows)<len(src.rows) && resize(&dst.rows,len(src.rows))!=nil {return false}
    for &page,p in dst.rows {
        from:[]i32
        if p<len(src.rows) {from=src.rows[p]}
        if len(from)==0 {
            mem.zero_slice(page)
            continue
        }
        if len(page)==0 {
            made,error:=make([]i32,ROWS_PAGE,dst.rows.allocator)
            if error!=nil {return false}
            page=made
        }
        copy(page,from)
    }
    return true
}

// The entity indices the rows of a table reach: every entity that has had a
// row in it has an index below.
raw_indices :: #force_inline proc "contextless" (t:^Raw_Table) -> int {return len(t.rows)<<ROWS_PAGE_BITS}

STAMP_PAGE_BITS :: 8
STAMP_PAGE :: 1<<STAMP_PAGE_BITS

@(private)
stamp_pages :: #force_inline proc "contextless" (rows:int) -> int {return (rows+STAMP_PAGE-1)>>STAMP_PAGE_BITS}

// The stamp of a row written now: no stamp of the table is above it.
@(private)
stamp_set :: #force_inline proc "contextless" (t:^Raw_Table,row:int,stamp:u64) {
    t.stamps[row]=stamp
    page:=&t.page_stamps[row>>STAMP_PAGE_BITS]
    page^=max(page^,stamp)
}

// The stamp of a row turned: above next, and added if the row was.
@(private)
stamp_turn :: #force_inline proc "contextless" (t:^Raw_Table,row:int,next:u64) {stamp_set(t,row,next+(t.stamps[row]&1))}

// The stamp of a write: even, and above every other of the table.
@(private)
version_write :: #force_inline proc "contextless" (t:^Raw_Table) -> u64 {
    t.version=(t.version+2)&~u64(1)
    return t.version
}

// The stamp of a row that came after every other, in room reserved for it.
@(private)
stamp_push :: #force_inline proc(t:^Raw_Table,stamp:u64) {
    append(&t.stamps,stamp)
    pages:=cast(^runtime.Raw_Dynamic_Array)&t.page_stamps
    pages.len=stamp_pages(len(t.stamps))
    t.page_stamps[pages.len-1]=stamp
}

// A row took the stamp of another: its page is not below it.
@(private)
stamp_moved :: #force_inline proc "contextless" (t:^Raw_Table,row:int) {
    page:=&t.page_stamps[row>>STAMP_PAGE_BITS]
    page^=max(page^,t.stamps[row])
}

Pending :: struct {
    entity:Entity,
    value:i32, // index in added, or PENDING_REMOVE, PENDING_OFF, PENDING_ON
}

PENDING_REMOVE :: -1
PENDING_OFF :: -2
PENDING_ON :: -3

// The entities gone keeps at least, from the first one that goes: past its
// room it drops its older half, and a reader that had not seen those reads
// the table whole. The room is made when the first entity goes and grows
// with the rows from then on (raw_reserve): what goes between two reads, the
// rows held and those that come, fits in the half that stays, however many a
// load brings.
GONE_CAPACITY :: 256

Row_Owner :: struct {generation:u32,id:u16}

// A row of this table owns the row of the same entity in another table.
Lock :: struct {
    offset:int, // from the table that holds it to the one whose rows it takes, in their World: lock_owners
    id:u16,
    names:[]string, // by lock id: the component that holds it
    target:string,
}

// Read-only access to a table: what a function that only reads receives.
Read :: struct($T:typeid) {table:^Table(T)}

// An empty table: it asks its allocator for nothing until it has rows.
table_init :: proc(t:^Table($T),name:string,allocator:=context.allocator) {raw_init(raw(t),name,allocator)}

raw_init :: proc(t:^Raw_Table,name:string,allocator:=context.allocator) {
    t.values={allocator=allocator}
    t.entities=make([dynamic]Entity,allocator)
    t.stamps=make([dynamic]u64,allocator)
    t.page_stamps=make([dynamic]u64,allocator)
    t.off=make([dynamic]bool,allocator)
    t.turns=make([dynamic]u64,allocator)
    t.rows=make([dynamic][]i32,allocator)
    t.pending=make([dynamic]Pending,allocator)
    t.added={allocator=allocator}
    t.gone.items=make([dynamic]Entity,allocator)
    t.owners=make([dynamic]Row_Owner,allocator)
    t.name=name
}

table_destroy :: proc(t:^Table($T)) {raw_destroy(raw(t),size_of(T))}

// size: of a value of the table.
raw_destroy :: proc(t:^Raw_Table,size:int) {
    for values in ([2]runtime.Raw_Dynamic_Array{t.values,t.added}) {
        if values.data!=nil {_=mem.free_with_size(values.data,values.cap*size,values.allocator)}
    }
    for page in t.rows {delete(page,t.rows.allocator)}
    delete(t.entities);delete(t.stamps);delete(t.page_stamps);delete(t.off);delete(t.turns);delete(t.rows)
    delete(t.pending);delete(t.gone.items);delete(t.owners)
    t^={}
}

read :: #force_inline proc "contextless" (t:^Table($T)) -> Read(T) {return {t}}

// The row of an entity whose component is on, -1 without one. Looking is not writing.
table_row :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> int {
    i:=entity_index(e)
    p:=i>>ROWS_PAGE_BITS
    if p>=len(t.rows) {return -1}
    page:=raw_data(t.rows[p])
    if page==nil {return -1}
    row:=int(page[i&(ROWS_PAGE-1)])-1
    if row<0 || row>=t.on || t.entities[row]!=e {return -1}
    return row
}
read_row :: #force_inline proc "contextless" (r:Read($T),e:Entity) -> int {return table_row(r.table,e)}
row_of :: proc{table_row,read_row}

// The value of the component of an entity; false without one on. Looking is
// not writing: whoever writes asks for the row with edit, or gives it with set.
table_get :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> (value:T,ok:bool) {
    if row:=table_row(t,e);row>=0 {return t.values[row],true}
    return
}
read_get :: #force_inline proc "contextless" (r:Read($T),e:Entity) -> (value:T,ok:bool) {return table_get(r.table,e)}
get :: proc{table_get,read_get}

// The row of an entity to write: it takes a stamp, and its readers process
// it. nil without one on.
edit :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> ^T {
    row:=table_row(t,e)
    return row<0?nil:edit_at(t,row)
}

// The row at an index, to write.
edit_at :: #force_inline proc "contextless" (t:^Table($T),row:int) -> ^T {
    t.version=(t.version+2)&~u64(1)
    t.stamps[row]=t.version
    t.page_stamps[row>>STAMP_PAGE_BITS]=t.version
    return &t.values[row]
}

// Gives the component of an entity a value. The row is written, and stamped,
// only when its bytes differ: true then. False without a row on.
set :: #force_inline proc "contextless" (t:^Table($T),e:Entity,value:T) -> (written:bool) {
    row:=table_row(t,e)
    return row>=0 && set_at(t,row,value)
}

// As set, for the row at an index.
set_at :: proc "contextless" (t:^Table($T),row:int,value:T) -> (written:bool) {
    value:=value
    if mem.compare_ptrs(&t.values[row],&value,size_of(T))==0 {return false}
    edit_at(t,row)^=value
    return true
}

table_has :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> bool {return table_row(t,e)>=0}
read_has :: #force_inline proc "contextless" (r:Read($T),e:Entity) -> bool {return table_row(r.table,e)>=0}
has :: proc{table_has,read_has}

// The row of an entity to write when no other component owns it: what a
// writer of a shared table that is not the owner uses.
free :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> ^T {
    i:=entity_index(e)
    if i<len(t.owners) && t.owners[i].generation==entity_generation(e) && t.owners[i].id!=0 {return nil}
    return edit(t,e)
}

// Every row on, to write.
writable :: proc "contextless" (t:^Table($T)) -> []T {
    version_write(raw(t))
    for &s in t.stamps[:t.on] {s=t.version}
    for &s in t.page_stamps[:stamp_pages(t.on)] {s=t.version}
    return t.values[:t.on]
}

// The lock that owns the row of an entity: 0 when it is free.
owner :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> u16 {
    i:=entity_index(e)
    return i<len(t.owners) && t.owners[i].generation==entity_generation(e)?t.owners[i].id:0
}

// The rows on: 0..<count are those a function goes through.
table_count :: #force_inline proc "contextless" (t:^Table($T)) -> int {return t.on}
read_count :: #force_inline proc "contextless" (r:Read($T)) -> int {return r.table.on}
count :: proc{table_count,read_count}

// The value of the row at an index.
table_at :: #force_inline proc "contextless" (t:^Table($T),row:int) -> T {return t.values[row]}
read_at :: #force_inline proc "contextless" (r:Read($T),row:int) -> T {return r.table.values[row]}
at :: proc{table_at,read_at}

table_entity_at :: #force_inline proc "contextless" (t:^Table($T),row:int) -> Entity {return t.entities[row]}
read_entity_at :: #force_inline proc "contextless" (r:Read($T),row:int) -> Entity {return r.table.entities[row]}
entity_at :: proc{table_entity_at,read_entity_at}

// The entity of the first row on; false without rows.
table_first :: #force_inline proc "contextless" (t:^Table($T)) -> (Entity,bool) {
    return t.on>0?t.entities[0]:NONE,t.on>0
}
read_first :: #force_inline proc "contextless" (r:Read($T)) -> (Entity,bool) {return table_first(r.table)}
first :: proc{table_first,read_first}

// The entity of the only row on; false without rows or with several.
table_sole :: #force_inline proc "contextless" (t:^Table($T)) -> (Entity,bool) {
    return t.on==1?t.entities[0]:NONE,t.on==1
}
read_sole :: #force_inline proc "contextless" (r:Read($T)) -> (Entity,bool) {return table_sole(r.table)}
sole :: proc{table_sole,read_sole}

table_stamp :: #force_inline proc "contextless" (t:^Table($T),row:int) -> u64 {return t.stamps[row]}
read_stamp :: #force_inline proc "contextless" (r:Read($T),row:int) -> u64 {return r.table.stamps[row]}
stamp :: proc{table_stamp,read_stamp}

table_version :: #force_inline proc "contextless" (t:^Table($T)) -> u64 {return t.version}
read_version :: #force_inline proc "contextless" (r:Read($T)) -> u64 {return r.table.version}
version :: proc{table_version,read_version}

read_layout :: #force_inline proc "contextless" (r:Read($T)) -> u64 {return r.table.layout}
table_layout :: #force_inline proc "contextless" (t:^Table($T)) -> u64 {return t.layout}
layout :: proc{table_layout,read_layout}

// Gives the entity the component, or replaces its value, at the end of the
// function. A component that was off stays off.
add :: proc(t:^Table($T),e:Entity,value:T) {
    append(&t.added,value)
    pending_push(raw(t),Pending{e,i32(len(t.added)-1)})
}

// Takes the component from the entity at the end of the function.
remove :: proc(t:^Table($T),e:Entity) {
    pending_push(raw(t),Pending{e,PENDING_REMOVE})
}

// Gives an entity a row at once, on and after every other, in a table its
// owner fills alone, outside a World: it waits for no settle and takes no
// lock, and every row of the table is on. A row the entity had stays, and
// the entity names the new one. False without memory, with the table as it
// was.
table_append :: proc(t:^Table($T),e:Entity,value:T) -> bool {
    count:=len(t.values)
    if reserve(&t.values,count+1)!=nil || reserve(&t.entities,count+1)!=nil || reserve(&t.stamps,count+1)!=nil || reserve(&t.page_stamps,stamp_pages(count+1))!=nil || reserve(&t.off,count+1)!=nil || !rows_room(raw(t),entity_index(e),0) {return false}
    t.version=(t.version+1)|1
    append(&t.values,value);append(&t.entities,e);append(&t.off,false)
    stamp_push(raw(t),t.version)
    rows_set(raw(t),entity_index(e),i32(count+1))
    t.on=count+1
    t.layout+=1
    return true
}

// The value the last add of this function waits to give an entity, to write
// before the end of the function: what a function reads of what it is making.
// nil without one, or when a remove follows it. Valid until the next add to
// the table.
table_added :: proc "contextless" (t:^Table($T),e:Entity) -> ^T {return cast(^T)raw_added(raw(t),type_info_of(T),e)}

// Whether the row at an index is new to its writer: it has its value from an
// add and was not written since, but by its author outside the loops (the
// editor, which Play copies: raw_author). What the writer of a table asks before it
// asks for the row (edit, edit_at, set, writable), to set up in its first
// tick what the row starts with, in place of a field that says it did. It is
// of the row: a World copied, or rolled back, keeps it.
table_added_row :: #force_inline proc "contextless" (t:^Table($T),row:int) -> bool {return t.stamps[row]&1==1}
read_added_row :: #force_inline proc "contextless" (r:Read($T),row:int) -> bool {return r.table.stamps[row]&1==1}
added :: proc{table_added,table_added_row,read_added_row}

// The value the entity will have at the end of the function, to write: the
// one an add waits to give it, or else its row on. nil without either.
staged :: proc "contextless" (t:^Table($T),e:Entity) -> ^T {
    if value:=table_added(t,e);value!=nil {return value}
    return edit(t,e)
}

// Whether the entity will have the component on at the end of the function,
// counting what this table waits for: what has answers after the settle. Of a
// single table it says whether the row of the entity is turned on; which row
// stays on is decided as the table settles.
staged_has :: proc "contextless" (t:^Table($T),e:Entity) -> bool {
    row:=raw_row(raw(t),e)
    present,off:=row>=0,row>=0 && t.off[row]
    off_with_entity:=present && row>=t.on && !off
    for p in t.pending {
        if p.entity!=e {continue}
        switch p.value {
        case PENDING_REMOVE: present,off=false,false
        case PENDING_OFF:    off=present
        case PENDING_ON:     off=false
        case:                present=true
        }
    }
    return present && !off && !off_with_entity
}

// Turns the component of an entity off at the end of the function: its row
// keeps its value, and no function sees it until enable. The base of an
// entity does not turn off: Disabled turns the whole entity off.
disable :: proc(t:^Table($T),e:Entity) {raw_disable(raw(t),e)}

// Turns the component of an entity on at the end of the function; while its
// entity is disabled it stays off with it. In a single table it is the one on
// from then, and the one that was on waits behind it.
enable :: proc(t:^Table($T),e:Entity) {raw_enable(raw(t),e)}

// Turns the component of an entity on or off at the end of the function.
set_on :: proc(t:^Table($T),e:Entity,on:bool) {
    if on {enable(t,e)} else {disable(t,e)}
}

// What a reader saw of a table, for changes.
Seen :: struct {
    version:u64,
    gone:u64, // the entities gone it read
}

// What changed in a table since a reader looked. The rows stamped above
// since were written, added or turned on, or, off with their entity, turned
// off or on by themselves; gone are the entities whose row
// stopped being on (removed, destroyed or turned off) or went while it was
// off, and one of them may be on again, among the rows stamped. all: the
// reader had not seen the rows there are, and goes through every one.
Changes :: struct {
    since:u64,
    gone:[]Entity,
    all:bool,
    written:bool, // rows were written, added or turned since, or all: each_changed has rows to give
    row,rows:int, // each_changed: the row it looks at next, of those it goes through
}

// What changed since seen, which it moves to now. gone is valid until the
// table settles again. off: each_changed also goes through the rows off, for
// code that walks every row by reflection.
raw_changes :: proc "contextless" (t:^Raw_Table,seen:^Seen,off:=false) -> (c:Changes) {
    c.since=seen.version
    gone,whole:=log_since(t.gone,&seen.gone)
    // Versions only grow: one seen above this one is of other rows.
    c.all=whole || seen.version>t.version
    if !c.all {c.gone=gone}
    c.written=c.all || t.version!=seen.version
    if c.written {c.rows=off?len(t.stamps):t.on}
    seen.version=t.version
    return
}
table_changes :: #force_inline proc "contextless" (t:^Table($T),seen:^Seen) -> Changes {return raw_changes(raw(t),seen)}
read_changes :: #force_inline proc "contextless" (r:Read($T),seen:^Seen) -> Changes {return raw_changes(raw(r.table),seen)}
changes :: proc{table_changes,read_changes}

// The rows among the changes, one at a time and in order, for a `for`: every
// row with all, and otherwise those stamped since, skipping whole the pages
// written before.
raw_each_changed :: #force_inline proc "contextless" (t:^Raw_Table,c:^Changes) -> (row:int,ok:bool) {
    row=c.row
    rows:=min(c.rows,len(t.stamps))
    if c.all {
        if row>=rows {return}
        c.row=row+1
        return row,true
    }
    stamps,pages,since:=raw_data(t.stamps),raw_data(t.page_stamps),c.since
    // A page is asked for where a walk enters it: every row below rows has its page.
    #no_bounds_check for row<rows {
        if row&(STAMP_PAGE-1)==0 && pages[row>>STAMP_PAGE_BITS]<=since {
            row+=STAMP_PAGE
            continue
        }
        if stamps[row]>since {
            c.row=row+1
            return row,true
        }
        row+=1
    }
    c.row=rows
    return 0,false
}
table_each_changed :: #force_inline proc "contextless" (t:^Table($T),c:^Changes) -> (row:int,ok:bool) {return raw_each_changed(raw(t),c)}
read_each_changed :: #force_inline proc "contextless" (r:Read($T),c:^Changes) -> (row:int,ok:bool) {return raw_each_changed(raw(r.table),c)}
each_changed :: proc{table_each_changed,read_each_changed}

// Whether one row on is among the changes: what a reader that walks another
// table asks of the row of its entity in this one.
table_changed :: #force_inline proc "contextless" (t:^Table($T),c:Changes,row:int) -> bool {return c.all || t.stamps[row]>c.since}
read_changed :: #force_inline proc "contextless" (r:Read($T),c:Changes,row:int) -> bool {return c.all || r.table.stamps[row]>c.since}
changed :: proc{table_changed,read_changed}

// The entities whose component of a, and of b and c, is on, with the value of
// each, for a `for` over the rows of a, the first table, in order: the one
// with the fewest rows goes first. row is the row of a the loop is at, which
// a writer of a asks for with edit_at:
//     j:=core.join(vels,masses,worlds)
//     for e,v,m,w in core.each_joined(&j) {core.edit_at(vels,j.row).y-=m.g*dt}
Join2 :: struct($A,$B:typeid) {a:^Table(A),b:^Table(B),row:int}
Join3 :: struct($A,$B,$C:typeid) {a:^Table(A),b:^Table(B),c:^Table(C),row:int}

join_tt :: proc "contextless" (a:^Table($A),b:^Table($B)) -> Join2(A,B) {return {a,b,-1}}
join_tr :: proc "contextless" (a:^Table($A),b:Read($B)) -> Join2(A,B) {return {a,b.table,-1}}
join_rt :: proc "contextless" (a:Read($A),b:^Table($B)) -> Join2(A,B) {return {a.table,b,-1}}
join_rr :: proc "contextless" (a:Read($A),b:Read($B)) -> Join2(A,B) {return {a.table,b.table,-1}}
join_ttt :: proc "contextless" (a:^Table($A),b:^Table($B),c:^Table($C)) -> Join3(A,B,C) {return {a,b,c,-1}}
join_ttr :: proc "contextless" (a:^Table($A),b:^Table($B),c:Read($C)) -> Join3(A,B,C) {return {a,b,c.table,-1}}
join_trt :: proc "contextless" (a:^Table($A),b:Read($B),c:^Table($C)) -> Join3(A,B,C) {return {a,b.table,c,-1}}
join_trr :: proc "contextless" (a:^Table($A),b:Read($B),c:Read($C)) -> Join3(A,B,C) {return {a,b.table,c.table,-1}}
join_rtt :: proc "contextless" (a:Read($A),b:^Table($B),c:^Table($C)) -> Join3(A,B,C) {return {a.table,b,c,-1}}
join_rtr :: proc "contextless" (a:Read($A),b:^Table($B),c:Read($C)) -> Join3(A,B,C) {return {a.table,b,c.table,-1}}
join_rrt :: proc "contextless" (a:Read($A),b:Read($B),c:^Table($C)) -> Join3(A,B,C) {return {a.table,b.table,c,-1}}
join_rrr :: proc "contextless" (a:Read($A),b:Read($B),c:Read($C)) -> Join3(A,B,C) {return {a.table,b.table,c.table,-1}}
join :: proc{join_tt,join_tr,join_rt,join_rr,join_ttt,join_ttr,join_trt,join_trr,join_rtt,join_rtr,join_rrt,join_rrr}

joined2 :: proc "contextless" (j:^Join2($A,$B)) -> (e:Entity,a:A,b:B,ok:bool) {
    for j.row+=1;j.row<j.a.on;j.row+=1 {
        e=j.a.entities[j.row]
        if rb:=table_row(j.b,e);rb>=0 {return e,j.a.values[j.row],j.b.values[rb],true}
    }
    return
}
joined3 :: proc "contextless" (j:^Join3($A,$B,$C)) -> (e:Entity,a:A,b:B,c:C,ok:bool) {
    for j.row+=1;j.row<j.a.on;j.row+=1 {
        e=j.a.entities[j.row]
        rb:=table_row(j.b,e)
        if rb<0 {continue}
        if rc:=table_row(j.c,e);rc>=0 {return e,j.a.values[j.row],j.b.values[rb],j.c.values[rc],true}
    }
    return
}
each_joined :: proc{joined2,joined3}

// Whether anything changed in a table since seen, which it moves to now:
// what a reader asks that makes again whole what it derives from the table.
// A table the World does not have (nil) never changes.
raw_touched :: proc "contextless" (t:^Raw_Table,seen:^Seen) -> bool {
    if t==nil {return false}
    now:=Seen{t.version,log_end(t.gone)}
    if seen^==now {return false}
    seen^=now
    return true
}
table_touched :: #force_inline proc "contextless" (t:^Table($T),seen:^Seen) -> bool {return raw_touched(raw(t),seen)}
read_touched :: #force_inline proc "contextless" (r:Read($T),seen:^Seen) -> bool {return raw_touched(raw(r.table),seen)}
// A storage of a World is its one row, and this the stamp of that row: it
// grows when a function receives the storage to write, when code outside the
// loops asks for it (world_storage) and when the World is copied over, swapped
// or cleared. What a function receives to read a storage S by change, beside
// S or core.Ref(S).
Stamp :: struct($S:typeid) {version:^u64}

// Whether a storage was handed out to write since seen, which it moves to now.
// A Stamp of no World says it always was.
stamp_touched :: proc "contextless" (s:Stamp($S),seen:^Seen) -> bool {
    if s.version==nil {return true}
    if seen.version==s.version^ {return false}
    seen.version=s.version^
    return true
}
touched :: proc{table_touched,read_touched,stamp_touched}

// The rows a reader saw in a table, for reshaped.
Shape :: distinct u64

// Whether the rows of a table are others since a reader looked, which it
// moves to now, whatever was written in them: what orders or indexes the
// rows of a table written every tick asks.
raw_reshaped :: proc "contextless" (t:^Raw_Table,shape:^Shape) -> bool {
    if t==nil {return false}
    if shape^==Shape(t.layout) {return false}
    shape^=Shape(t.layout)
    return true
}
table_reshaped :: #force_inline proc "contextless" (t:^Table($T),shape:^Shape) -> bool {return raw_reshaped(raw(t),shape)}
read_reshaped :: #force_inline proc "contextless" (r:Read($T),shape:^Shape) -> bool {return raw_reshaped(raw(r.table),shape)}
reshaped :: proc{table_reshaped,read_reshaped}

table_clear :: proc(t:^Table($T)) {raw_clear(raw(t))}

raw_clear :: proc(t:^Raw_Table) {
    for e in t.entities[:t.on] {locks_release(t,e)}
    t.values.len,t.added.len=0,0
    clear(&t.entities);clear(&t.stamps);clear(&t.page_stamps);clear(&t.off);clear(&t.turns);clear(&t.pending)
    log_reset(&t.gone)
    rows_zero(t)
    t.on=0
    t.version+=1
    t.layout+=1
}

// Applies the pending adds, removes and turns in the order they were made,
// drops the rows of the entities destroyed and moves those of the entities
// whose Disabled changed (Entities.turned). True when the rows changed.
// Without memory for the adds none is applied: they wait for the next settle.
// Settling the Id table brings the index of the entities by Id with it.
table_settle :: proc(t:^Table($T),es:^Entities) -> bool {
    changed:=raw_settle(raw(t),size_of(T),align_of(T),es)
    when T==Id {ids_follow(es,read(t))}
    return changed
}

raw_settle :: proc(t:^Raw_Table,size,align:int,es:^Entities) -> bool {
    turned:=t.base?0:len(es.turned)
    if len(t.pending)==0 && len(es.doomed)==0 && turned==0 {return false}
    // Adds take next+1, and turns next or, of a row added, next+1.
    next:=(t.version+2)&~u64(1)
    written,changed:=false,false
    if table_settle_reserve(t,size,align,es) {
        changed,written=table_pending_apply(t,size,es,next)
    }
    for e in es.doomed {
        if raw_row(t,e)>=0 {changed=raw_drop_index(t,size,entity_index(e)) || changed}
    }
    for e in es.turned[:turned] {
        if row:=raw_row(t,e);row>=0 {
            moved,on:=table_place(t,size,row,es,next)
            changed||=moved
            written||=on
        }
    }
    if t.single && changed {changed=single_keep(t,size,es,next) || changed}
    if changed || written {t.version=next+1}
    if changed {t.layout+=1}
    return changed
}

// Of the rows of a single table that wait to be on and whose entity is on,
// leaves on the one turned on last; the others that were on wait, off by
// themselves with their values.
@(private)
single_keep :: proc(t:^Raw_Table,size:int,es:^Entities,next:u64) -> bool {
    keep:=NONE
    best:=u64(0)
    for turn,row in t.turns {
        if turn<=best || entity_off(es,t.entities[row]) {continue}
        best,keep=turn,t.entities[row]
    }
    changed:=false
    for row:=0;row<t.on; {
        if t.entities[row]!=keep {
            t.off[row]=true
            if moved,_:=table_place(t,size,row,es,next);moved {
                changed=true
                continue
            }
        }
        row+=1
    }
    if row:=raw_row(t,keep);row>=t.on {
        t.off[row]=false
        moved,_:=table_place(t,size,row,es,next)
        changed||=moved
    }
    return changed
}

// The turn a row of a single table takes when it is turned on: after every
// other one that waits to be on, row aside (-1: none).
@(private)
single_turn :: proc "contextless" (t:^Raw_Table,row:=-1) -> u64 {
    last:=u64(0)
    for turn,at in t.turns {
        if at!=row {last=max(last,turn)}
    }
    return last+1
}

// Room for every pending add, in the rows and in the owners its locks take.
@(private)
table_settle_reserve :: proc(t:^Raw_Table,size,align:int,es:^Entities) -> bool {
    adds,high:=0,-1
    for p in t.pending {
        if p.value<0 {continue}
        adds+=1
        high=max(high,entity_index(p.entity))
    }
    if adds==0 {return true}
    if !raw_reserve(t,size,align,t.values.len+adds,high) {return false}
    capacity:=entities_capacity(es)
    for p in t.pending {
        if p.value>=0 && !rows_room(t,entity_index(p.entity),capacity) {return false}
    }
    return true
}

// Room for rows rows, and in the owners its locks take for an entity of
// index high among them: with rows_room for each entity, what a settle needs
// to apply its adds without allocating. False without memory, with the rows
// as they were.
@(private)
raw_reserve :: proc(t:^Raw_Table,size,align,rows,high:int) -> bool {
    if !raw_rows_reserve(t,size,align,rows) {return false}
    if cap(t.gone.items)>0 && cap(t.gone.items)<2*rows && reserve(&t.gone.items,max(2*rows,2*cap(t.gone.items)))!=nil {return false}
    for lock in t.locks {
        if owners:=lock_owners(t,lock);high>=len(owners) && resize(owners,high+1)!=nil {return false}
    }
    return true
}

@(private)
table_pending_apply :: proc(t:^Raw_Table,size:int,es:^Entities,next:u64) -> (changed,written:bool) {
    for p in t.pending {
        switch p.value {
        case PENDING_REMOVE:
            if raw_row(t,p.entity)>=0 {changed=raw_drop_index(t,size,entity_index(p.entity)) || changed}
        case PENDING_OFF,PENDING_ON:
            row:=raw_row(t,p.entity)
            if row<0 {continue}
            was:=t.off[row]
            t.off[row]=p.value==PENDING_OFF
            if t.single {
                // Turned on, it goes after every other; turned off, it waits no more.
                turn:=u64(0)
                if p.value==PENDING_ON {turn=single_turn(t,row);if t.turns[row]>=turn {turn=t.turns[row]}}
                if turn!=t.turns[row] {
                    t.turns[row]=turn
                    stamp_turn(t,row,next)
                    written=true
                }
            }
            moved,on:=table_place(t,size,row,es,next)
            // Off with its entity, the row stays where it was: the stamp
            // tells the readers of every row that its own off changed.
            if !moved && t.off[row]!=was {
                stamp_turn(t,row,next)
                on=true
            }
            changed||=moved
            written||=on
        case:
            if !alive(es,p.entity) {continue}
            value:=rawptr(uintptr(t.added.data)+uintptr(int(p.value)*size))
            if row:=raw_row(t,p.entity);row>=0 {
                if size>0 {mem.copy(raw_at(t,size,row),value,size)}
                stamp_set(t,row,next+1)
                written=true
                continue
            }
            i:=entity_index(p.entity)
            if rows_at(t,i)!=0 {changed=raw_drop_index(t,size,i) || changed}
            // In a single table, one that comes while another is on comes off, and waits for no turn.
            waits:=t.single && t.on>0
            on:=!waits && (t.base || !entity_off(es,p.entity))
            if on && !locks_claim(t,p.entity,t.name) {continue}
            if t.single {append(&t.turns,waits?0:single_turn(t))}
            row:=t.values.len
            t.values.len+=1
            if size>0 {mem.copy(raw_at(t,size,row),value,size)}
            append(&t.entities,p.entity)
            stamp_push(t,next+1)
            append(&t.off,waits)
            rows_set(t,i,i32(row+1))
            if on {
                table_swap_rows(t,size,row,t.on)
                t.on+=1
            }
            changed=true
        }
    }
    clear(&t.pending)
    t.added.len=0
    return
}

// Puts a row among those on when neither it nor its entity is off, and among
// the others otherwise. moved: it crossed; on: it turned on, stamped as
// written. A row on owns what its locks take: one that cannot take it stays
// off by itself.
@(private)
table_place :: proc(t:^Raw_Table,size,row:int,es:^Entities,next:u64) -> (moved,on:bool) {
    e:=t.entities[row]
    want:=!t.off[row] && (t.base || !entity_off(es,e))
    if want==(row<t.on) {return}
    if want {
        if !locks_claim(t,e,t.name) {
            t.off[row]=true
            return
        }
        stamp_turn(t,row,next)
        table_swap_rows(t,size,row,t.on)
        t.on+=1
        return true,true
    }
    locks_release(t,e)
    gone_push(t,e)
    table_swap_rows(t,size,row,t.on-1)
    t.on-=1
    return true,false
}

@(private)
raw_drop_index :: proc(t:^Raw_Table,size,i:int) -> bool {
    row:=int(rows_at(t,i))-1
    if row<0 {return false}
    gone_push(t,t.entities[row])
    if row<t.on {
        locks_release(t,t.entities[row])
        t.on-=1
        if row!=t.on {table_move_row(t,size,t.on,row)}
        row=t.on
    }
    last:=t.values.len-1
    if row!=last {table_move_row(t,size,last,row)}
    t.values.len-=1
    pop(&t.entities)
    pop(&t.stamps)
    (cast(^runtime.Raw_Dynamic_Array)&t.page_stamps).len=stamp_pages(len(t.stamps))
    pop(&t.off)
    if t.single {pop(&t.turns)}
    rows_set(t,i,0)
    return true
}

@(private)
raw_at :: #force_inline proc "contextless" (t:^Raw_Table,size,row:int) -> rawptr {
    return rawptr(uintptr(t.values.data)+uintptr(row*size))
}

// Puts the row from in to, whose row is lost.
@(private)
table_move_row :: proc "contextless" (t:^Raw_Table,size,from,to:int) {
    if size>0 {mem.copy(raw_at(t,size,to),raw_at(t,size,from),size)}
    t.entities[to]=t.entities[from]
    t.stamps[to]=t.stamps[from]
    stamp_moved(t,to)
    t.off[to]=t.off[from]
    if t.single {t.turns[to]=t.turns[from]}
    rows_set(t,entity_index(t.entities[to]),i32(to+1))
}

@(private)
table_swap_rows :: proc "contextless" (t:^Raw_Table,size,a,b:int) {
    if a==b {return}
    if size>0 {slice.ptr_swap_non_overlapping(raw_at(t,size,a),raw_at(t,size,b),size)}
    t.entities[a],t.entities[b]=t.entities[b],t.entities[a]
    t.stamps[a],t.stamps[b]=t.stamps[b],t.stamps[a]
    stamp_moved(t,a);stamp_moved(t,b)
    t.off[a],t.off[b]=t.off[b],t.off[a]
    if t.single {t.turns[a],t.turns[b]=t.turns[b],t.turns[a]}
    rows_set(t,entity_index(t.entities[a]),i32(a+1))
    rows_set(t,entity_index(t.entities[b]),i32(b+1))
}

// Notes that the row of an entity stopped being on. The room is made with
// the first one, and from then on it never allocates: full, it drops its
// older half; without room every reader reads the table whole.
@(private)
gone_push :: proc(t:^Raw_Table,e:Entity) {
    if cap(t.gone.items)==0 && reserve(&t.gone.items,max(GONE_CAPACITY,2*cap(t.entities)))!=nil {
        log_reset(&t.gone)
        return
    }
    log_push(&t.gone,e,cap(t.gone.items))
}

table_copy :: proc(dst,src:^Table($T)) -> bool {return raw_copy(raw(dst),raw(src),type_info_of(T),false)}

// info: of a value of the table. flat: a value is known to hold nothing
// behind a pointer (Table_Info.flat); false asks its type.
raw_copy :: proc(dst,src:^Raw_Table,info:^runtime.Type_Info,flat:bool) -> bool {
    if dst==src {return true}
    dst.on=0
    values:=flat?array_copy_flat(&dst.values,&src.values,info.size,info.align):array_copy(&dst.values,&src.values,info)
    // The rows by entity go before the entities: a copy that fails half way
    // leaves the entities of src over no other rows than theirs.
    if !values ||
       !rows_copy(dst,src) ||
       !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.entities,cast(^runtime.Raw_Dynamic_Array)&src.entities,size_of(Entity),align_of(Entity)) ||
       !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.stamps,cast(^runtime.Raw_Dynamic_Array)&src.stamps,size_of(u64),align_of(u64)) ||
       !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.page_stamps,cast(^runtime.Raw_Dynamic_Array)&src.page_stamps,size_of(u64),align_of(u64)) ||
       !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.off,cast(^runtime.Raw_Dynamic_Array)&src.off,size_of(bool),align_of(bool)) ||
       !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.turns,cast(^runtime.Raw_Dynamic_Array)&src.turns,size_of(u64),align_of(u64)) ||
       !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.owners,cast(^runtime.Raw_Dynamic_Array)&src.owners,size_of(Row_Owner),align_of(Row_Owner)) {return false}
    clear(&dst.pending)
    dst.added.len=0
    log_reset(&dst.gone,log_end(src.gone))
    dst.on=src.on
    dst.version=max(dst.version,src.version)+1
    dst.layout=max(dst.layout,src.layout)+1
    return true
}

// What a table of a World was when another World was last made a copy of
// it: its version and its layout. valid is false until the first copy, and
// after a copy that failed.
Copy_Mark :: struct {
    version,layout:u64,
    valid:bool,
}

// Makes dst a copy of src copying only what differs, for a dst kept as a copy
// of src or of a World made from src, whose rows carry the stamps of the
// writes that made them: a World into which a World of another origin was
// copied is copied whole first. Nothing when src did not change since the
// copy mark says; the rows stamped since, skipping whole the pages written
// before, when src kept its rows since; the rows whose stamps differ when
// both have the same rows; all of it otherwise. To the readers of dst it is
// a copy like table_copy.
table_copy_changed :: proc(dst,src:^Table($T),mark:^Copy_Mark) -> bool {
    return raw_copy_changed(raw(dst),raw(src),type_info_of(T),false,mark)
}

// info and flat: as raw_copy takes them.
raw_copy_changed :: proc(dst,src:^Raw_Table,info:^runtime.Type_Info,flat:bool,mark:^Copy_Mark) -> bool {
    if dst==src {return true}
    if mark.valid && mark.version==src.version && mark.layout==src.layout {return true}
    since:=rows_since(src,dst,mark^)
    mark.valid=false
    if since<0 {
        if !raw_copy(dst,src,info,flat) {return false}
        mark^={src.version,src.layout,true}
        return true
    }
    size,asked:=info.size,flat
    flat:=flat
    for row:=0;row<len(src.stamps); {
        if row&(STAMP_PAGE-1)==0 && src.page_stamps[row>>STAMP_PAGE_BITS]<=u64(since) {
            row+=STAMP_PAGE
            continue
        }
        if stamp:=src.stamps[row];stamp>u64(since) && dst.stamps[row]!=stamp {
            if !asked {flat,asked=value_flat(info),true}
            if flat {mem.copy_non_overlapping(raw_at(dst,size,row),raw_at(src,size,row),size)} else if !value_copy(raw_at(dst,size,row),raw_at(src,size,row),info) {return false}
            dst.stamps[row]=stamp
        }
        row+=1
    }
    // The same rows take the same pages; a row skipped may keep a stamp of its own.
    for &page,p in dst.page_stamps {page=max(page,src.page_stamps[p])}
    // The rows by entity follow from the entities, which are the same.
    if !slice.equal(dst.turns[:],src.turns[:]) && !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.turns,cast(^runtime.Raw_Dynamic_Array)&src.turns,size_of(u64),align_of(u64)) {return false}
    if !slice.equal(dst.owners[:],src.owners[:]) && !array_copy_flat(cast(^runtime.Raw_Dynamic_Array)&dst.owners,cast(^runtime.Raw_Dynamic_Array)&src.owners,size_of(Row_Owner),align_of(Row_Owner)) {return false}
    clear(&dst.pending)
    dst.added.len=0
    log_reset(&dst.gone,log_end(src.gone))
    dst.version=max(dst.version,src.version)+1
    dst.layout=max(dst.layout,src.layout)+1
    mark^={src.version,src.layout,true}
    return true
}

// Of a table and b, a copy of it when mark was taken of a, whether they hold
// the same rows, and from which stamp on those of a may differ from those of
// b: the version of the mark when a kept its rows since (the rows stamped up
// to it are as the copy took them), 0 when the rows only came out the same,
// -1 when they are others.
@(private)
rows_since :: proc "contextless" (a,b:^Raw_Table,mark:Copy_Mark) -> i64 {
    if a.on!=b.on || len(a.stamps)!=len(b.stamps) {return -1}
    if mark.valid && mark.layout==a.layout {return i64(mark.version)}
    return slice.equal(a.entities[:],b.entities[:]) && slice.equal(a.off[:],b.off[:])?0:-1
}

// Whether raw_restore can bring back src into dst, a src that
// world_copy_changed keeps as a copy of dst with mark: both still hold the
// same rows, on and off, with the same turns and owners. The stamp from
// which it looks, as rows_since gives it, or -1.
@(private)
restore_since :: proc "contextless" (dst,src:^Raw_Table,mark:Copy_Mark) -> i64 {
    since:=rows_since(dst,src,mark)
    return since>=0 && slice.equal(dst.turns[:],src.turns[:]) && slice.equal(dst.owners[:],src.owners[:])?since:-1
}

// Makes the rows of dst those of src in place, for a restore_since that is
// not -1 and values that hold nothing behind a pointer. Each row whose value
// or whose being added differs takes a stamp above every other, with the
// parity of its stamp in src, so a reader sees exactly the rows that went
// back, and none goes to gone; what waits for the settle is dropped. It
// allocates nothing.
@(private)
raw_restore :: proc "contextless" (dst,src:^Raw_Table,size:int,since:i64) {
    next:=(dst.version+2)&~u64(1)
    written:=false
    for row:=0;row<len(dst.stamps); {
        if row&(STAMP_PAGE-1)==0 && dst.page_stamps[row>>STAMP_PAGE_BITS]<=u64(since) {
            row+=STAMP_PAGE
            continue
        }
        stamp,from:=dst.stamps[row],src.stamps[row]
        if stamp>u64(since) && stamp!=from && ((stamp~from)&1==1 || mem.compare_ptrs(raw_at(dst,size,row),raw_at(src,size,row),size)!=0) {
            if size>0 {mem.copy_non_overlapping(raw_at(dst,size,row),raw_at(src,size,row),size)}
            stamp_set(dst,row,next+(from&1))
            written=true
        }
        row+=1
    }
    if written {dst.version=next+1}
    clear(&dst.pending)
    dst.added.len=0
    table_waits(dst,false)
}

table_swap :: proc(a,b:^Table($T)) {raw_swap(raw(a),raw(b))}

raw_swap :: proc(a,b:^Raw_Table) {
    if a==b {return}
    version:=max(a.version,b.version)+1
    layout:=max(a.layout,b.layout)+1
    gone:=max(log_end(a.gone),log_end(b.gone))
    a.values,b.values=b.values,a.values
    a.entities,b.entities=b.entities,a.entities
    a.stamps,b.stamps=b.stamps,a.stamps
    a.page_stamps,b.page_stamps=b.page_stamps,a.page_stamps
    a.off,b.off=b.off,a.off
    a.turns,b.turns=b.turns,a.turns
    a.rows,b.rows=b.rows,a.rows
    a.owners,b.owners=b.owners,a.owners
    a.pending,b.pending=b.pending,a.pending
    a.added,b.added=b.added,a.added
    a.on,b.on=b.on,a.on
    table_waits(a,len(a.pending)>0)
    table_waits(b,len(b.pending)>0)
    log_reset(&a.gone,gone);log_reset(&b.gone,gone)
    a.version,b.version=version,version
    a.layout,b.layout=layout,layout
}

@(private)
locks_claim :: proc(t:^Raw_Table,e:Entity,name:string) -> bool {
    i:=entity_index(e)
    generation:=entity_generation(e)
    for lock in t.locks {
        owners:=lock_owners(t,lock)
        if i<len(owners) && owners[i].generation==generation && owners[i].id!=0 && owners[i].id!=lock.id {
            holder:=int(owners[i].id)<len(lock.names)?lock.names[owners[i].id]:"another component"
            fail("%s cannot take the %s of entity %v: %s owns it",name,lock.target,e,holder)
            return false
        }
    }
    for lock in t.locks {
        owners:=lock_owners(t,lock)
        if i>=len(owners) && resize(owners,i+1)!=nil {return false}
    }
    for lock in t.locks {
        lock_owners(t,lock)[i]={generation,lock.id}
        lock_table(t,lock).version+=1
    }
    return true
}

@(private)
locks_release :: proc(t:^Raw_Table,e:Entity) {
    i:=entity_index(e)
    for lock in t.locks {
        owners:=lock_owners(t,lock)
        if i<len(owners) && owners[i].generation==entity_generation(e) && owners[i].id==lock.id {
            owners[i]={}
            lock_table(t,lock).version+=1
        }
    }
}

// The table whose rows a lock of a table takes: the one offset bytes away
// from it, in the same World. Who owns its rows is part of what it holds:
// its version moves when an owner does, so a copy of what changed takes it.
lock_table :: #force_inline proc "contextless" (t:^Raw_Table,lock:Lock) -> ^Raw_Table {
    return cast(^Raw_Table)rawptr(uintptr(int(uintptr(t))+lock.offset))
}

lock_owners :: #force_inline proc "contextless" (t:^Raw_Table,lock:Lock) -> ^[dynamic]Row_Owner {
    return &lock_table(t,lock).owners
}

// The offset of a lock of holder over the rows of target, two tables of one World.
lock_offset :: #force_inline proc "contextless" (holder,target:rawptr) -> int {
    return int(uintptr(target))-int(uintptr(holder))
}

// The same table without its type, for code that walks every table by
// reflection: the editor, scenes, saves and the network. Its layout is that
// of every Table(T).
Raw_Table :: struct {
    values:runtime.Raw_Dynamic_Array,
    entities:[dynamic]Entity,
    stamps:[dynamic]u64,
    page_stamps:[dynamic]u64,
    off:[dynamic]bool,
    turns:[dynamic]u64,
    rows:[dynamic][]i32,
    pending:[dynamic]Pending,
    added:runtime.Raw_Dynamic_Array,
    gone:Log(Entity),
    version:u64,
    layout:u64,
    on:int,
    base:bool,
    single:bool,
    owners:[dynamic]Row_Owner,
    locks:[]Lock,
    name:string,
    waits:Waits,
}
#assert(size_of(Raw_Table)==size_of(Table(u8)))
#assert(offset_of(Raw_Table,stamps)==offset_of(Table(u8),stamps))
#assert(offset_of(Raw_Table,page_stamps)==offset_of(Table(u8),page_stamps))
#assert(offset_of(Raw_Table,turns)==offset_of(Table(u8),turns))
#assert(offset_of(Raw_Table,gone)==offset_of(Table(u8),gone))
#assert(offset_of(Raw_Table,on)==offset_of(Table(u8),on))
#assert(offset_of(Raw_Table,name)==offset_of(Table(u8),name))
#assert(offset_of(Raw_Table,waits)==offset_of(Table(u8),waits))

raw :: #force_inline proc "contextless" (t:^Table($T)) -> ^Raw_Table {return cast(^Raw_Table)t}

// The row of an entity, on or off; -1 without one.
raw_row :: proc "contextless" (t:^Raw_Table,e:Entity) -> int {
    row:=int(rows_at(t,entity_index(e)))-1
    if row<0 || t.entities[row]!=e {return -1}
    return row
}

// The row of an entity to write, on or off: it takes a stamp. nil without one.
raw_edit :: proc "contextless" (t:^Raw_Table,type:^runtime.Type_Info,e:Entity) -> rawptr {
    row:=raw_row(t,e)
    if row<0 {return nil}
    stamp_set(t,row,version_write(t))
    return raw_value(t,type,row)
}

// The row of an entity to write as its author, outside the loops (the
// editor, an undo): it takes a stamp and stays added, since the library that
// writes the table has not seen it yet. nil without one.
raw_author :: proc "contextless" (t:^Raw_Table,type:^runtime.Type_Info,e:Entity) -> rawptr {
    row:=raw_row(t,e)
    if row<0 {return nil}
    t.version=version_write(t)+(t.stamps[row]&1)
    stamp_set(t,row,t.version)
    return raw_value(t,type,row)
}

// The row of an entity to read, on or off; nil without one.
raw_find :: proc "contextless" (t:^Raw_Table,type:^runtime.Type_Info,e:Entity) -> rawptr {
    row:=raw_row(t,e)
    return row<0?nil:raw_value(t,type,row)
}

// A component without fields has no bytes: its rows point at the table, so
// a row found is never nil.
raw_value :: proc "contextless" (t:^Raw_Table,type:^runtime.Type_Info,row:int) -> rawptr {
    if type.size==0 {return t}
    return rawptr(uintptr(t.values.data)+uintptr(row)*uintptr(type.size))
}

// Says that the row of an entity was written in place, through a pointer
// raw_find gave: a widget bound to its fields.
raw_touch :: proc "contextless" (t:^Raw_Table,e:Entity) {
    if row:=raw_row(t,e);row>=0 {stamp_set(t,row,version_write(t))}
}

// Whether the component of an entity is on, and whether it was turned off by
// itself (off alone, it is off with its entity).
raw_state :: proc "contextless" (t:^Raw_Table,e:Entity) -> (on,turned_off,found:bool) {
    row:=raw_row(t,e)
    if row<0 {return}
    return row<t.on,t.off[row],true
}

// As add, with the value at a pointer; nil: the component zeroed.
raw_add :: proc(t:^Raw_Table,info:^runtime.Type_Info,e:Entity,value:rawptr) {
    switch {
    case info.size==0: t.added.len+=1 // as append does for an empty type: there is no memory to copy into
    case value==nil:   runtime.__dynamic_array_append_nothing(&t.added,info.size,info.align)
    case:              runtime.__dynamic_array_append(&t.added,info.size,info.align,value,1)
    }
    pending_push(t,Pending{e,i32(t.added.len-1)})
}

raw_remove :: proc(t:^Raw_Table,e:Entity) {pending_push(t,Pending{e,PENDING_REMOVE})}

// The value the last add of the function waits to give an entity; nil without
// one, or when a remove follows it. Valid until the next add to the table.
raw_added :: proc "contextless" (t:^Raw_Table,type:^runtime.Type_Info,e:Entity) -> rawptr {
    #reverse for p in t.pending {
        if p.entity!=e || p.value==PENDING_OFF || p.value==PENDING_ON {continue}
        if p.value==PENDING_REMOVE {return nil}
        return type.size==0?rawptr(t):rawptr(uintptr(t.added.data)+uintptr(int(p.value)*type.size))
    }
    return nil
}

// The value an entity will have at the end of the function, to write: the one
// an add waits to give it, or else its row, on or off. nil without either.
raw_staged :: proc "contextless" (t:^Raw_Table,type:^runtime.Type_Info,e:Entity) -> rawptr {
    if value:=raw_added(t,type,e);value!=nil {return value}
    return raw_edit(t,type,e)
}

raw_disable :: proc(t:^Raw_Table,e:Entity) {
    if t.base {
        fail("%s is the base of every entity and does not turn off: give the entity core.Disabled to turn it off",t.name)
        return
    }
    pending_push(t,Pending{e,PENDING_OFF})
}

raw_enable :: proc(t:^Raw_Table,e:Entity) {
    if !t.base {pending_push(t,Pending{e,PENDING_ON})}
}

// Takes the row of an entity at once, between functions: what an undo puts
// back. The adds, removes and turns pending still settle as usual.
raw_drop :: proc(t:^Raw_Table,info:^runtime.Type_Info,e:Entity) -> bool {
    if t==nil || info==nil || e==NONE || t.values.len!=len(t.entities) || len(t.stamps)!=len(t.entities) || len(t.page_stamps)!=stamp_pages(len(t.stamps)) || len(t.off)!=len(t.entities) {return false}
    if raw_row(t,e)<0 || !raw_drop_index(t,info.size,entity_index(e)) {return false}
    t.version+=1
    t.layout+=1
    return true
}

// Gives an entity its row at once, between functions, turned off by itself
// or not: what an undo or a cancel puts back where raw_drop took it. The rows
// must have room for it, as a settle reserves for its adds; false without
// it, for an entity not alive, or for one that has a row. A row of another
// generation of its index goes first. The value is written whole. In a
// single table a row put on is turned on last.
raw_put :: proc(t:^Raw_Table,info:^runtime.Type_Info,es:^Entities,e:Entity,value:rawptr,off:bool) -> bool {
    if t==nil || info==nil || !alive(es,e) || raw_row(t,e)>=0 {return false}
    i,size:=entity_index(e),info.size
    if t.values.len>=t.values.cap || len(t.entities)>=cap(t.entities) || len(t.stamps)>=cap(t.stamps) || stamp_pages(len(t.stamps)+1)>cap(t.page_stamps) || len(t.off)>=cap(t.off) || !rows_has_room(t,i) {return false}
    if t.single && len(t.turns)>=cap(t.turns) {return false}
    for lock in t.locks {if owners:=lock_owners(t,lock);i>=max(len(owners),cap(owners)) {return false}}
    if rows_at(t,i)!=0 {raw_drop_index(t,size,i)}
    version_write(t)
    if t.single {append(&t.turns,off?0:single_turn(t))}
    row:=t.values.len
    t.values.len+=1
    if size>0 {mem.copy(raw_at(t,size,row),value,size)}
    append(&t.entities,e);stamp_push(t,t.version);append(&t.off,off && !t.base)
    rows_set(t,i,i32(row+1))
    if !t.off[row] && (t.base || !entity_off(es,e)) {
        if locks_claim(t,e,t.name) {
            table_swap_rows(t,size,row,t.on)
            t.on+=1
        } else {t.off[row]=true}
    }
    if t.single && t.on>1 {single_keep(t,size,es,t.version)}
    t.layout+=1
    return true
}

// Room for rows rows, on or off, with what goes by row: what a settle
// reserves for its adds, and code that puts rows at once (raw_put) before
// it. size and align: of a value of the table. False without memory, with
// the rows as they were.
raw_rows_reserve :: proc(t:^Raw_Table,size,align,rows:int) -> bool {
    if !runtime.__dynamic_array_reserve(&t.values,size,align,rows) || reserve(&t.entities,rows)!=nil || reserve(&t.stamps,rows)!=nil || reserve(&t.page_stamps,stamp_pages(rows))!=nil || reserve(&t.off,rows)!=nil {return false}
    return !t.single || reserve(&t.turns,rows)==nil
}

// Room for the row of any entity of an index below limit, and to note the
// entities that go: what code that puts rows back and takes them at once
// (raw_put, raw_drop) reserves first, with the room of its rows, to ask for
// no memory later. False without memory.
raw_room :: proc(t:^Raw_Table,limit:int) -> bool {
    for i:=0;i<limit;i+=ROWS_PAGE {
        if !rows_room(t,i,limit) {return false}
    }
    return cap(t.gone.items)>0 || reserve(&t.gone.items,max(GONE_CAPACITY,2*cap(t.entities)))==nil
}

// Every row, on or off.
raw_count :: #force_inline proc "contextless" (t:^Raw_Table) -> int {return t.values.len}

// -define:MIRAI_CHECK_WRITES=true makes the loops check, after every
// function, that it asked for every row it wrote of the tables it receives
// to write: a write that readers of the stamps would miss. It copies those
// tables around each function.
CHECK_WRITES :: #config(MIRAI_CHECK_WRITES,false)

Write_Check :: struct {
    table:^Raw_Table,
    size:int,
    version,layout:u64,
    values:[]u8,
}

write_check_begin :: proc(t:^Raw_Table,size:int) -> Write_Check {
    values,error:=make([]u8,t.values.len*size)
    if error!=nil {return {table=t}} // without a size write_check_end skips it
    c:=Write_Check{t,size,t.version,t.layout,values}
    if len(c.values)>0 {mem.copy(raw_data(c.values),t.values.data,len(c.values))}
    return c
}

write_check_end :: proc(checks:[]Write_Check,function:string) {
    for c in checks {
        defer delete(c.values)
        t:=c.table
        if c.size==0 || t.layout!=c.layout || t.values.len*c.size!=len(c.values) {continue}
        for row in 0..<t.values.len {
            if t.stamps[row]>c.version {continue}
            at:=row*c.size
            if mem.compare_ptrs(rawptr(uintptr(t.values.data)+uintptr(at)),&c.values[at],c.size)!=0 {
                fail("%s wrote the %s of entity %v without asking for its row (edit, edit_at, set, free, writable or touch)",function,t.name,t.entities[row])
                break
            }
        }
    }
}

// A rule of the engine was broken: logged with what to do about it, and in a
// test build the program stops there.
fail :: proc(format:string,args:..any,loc:=#caller_location) {
    message:=fmt.tprintf(format,..args)
    log.error(message,location=loc)
    when ODIN_TEST {panic(message,loc)}
}
