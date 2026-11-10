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
// Every write raises version, and the row written takes it as its stamp: a
// row asked for to write (get, at, free, writable, touch), replaced by an add
// or turned on. A reader that keeps what it saw finds what changed since with
// changes: the rows stamped above the version it saw, and in gone the
// entities whose row stopped being on or went while off. layout grows
// whenever the rows are others. Both only grow, also in a table copied over.
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
    off:[dynamic]bool,        // by row: turned off by itself, whatever its entity
    turns:[dynamic]u64,       // single tables, by row: how late it was turned on, the latest on; 0: it does not wait to be on
    rows:[dynamic]i32,        // by entity index: row+1, 0 without one
    pending:[dynamic]Pending,
    added:[dynamic]T,         // values of the pending adds
    gone:[dynamic]Entity,     // the entities whose row stopped being on, oldest first
    version:u64,
    layout:u64,               // grows when rows are added, removed, turned on or off, or replaced whole
    gone_first:u64,           // how many entities went before gone[0]
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

Pending :: struct {
    entity:Entity,
    value:i32, // index in added, or PENDING_REMOVE, PENDING_OFF, PENDING_ON
}

PENDING_REMOVE :: -1
PENDING_OFF :: -2
PENDING_ON :: -3

// The entities gone keeps at least: past its room it drops its older half,
// and a reader that had not seen those reads the table whole. The room grows
// with the rows (raw_reserve): what goes between two reads, the rows held and
// those that come, fits in the half that stays, however many a load brings.
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

// False without memory.
table_init :: proc(t:^Table($T),name:string,allocator:=context.allocator) -> bool {return raw_init(raw(t),name,allocator)}

raw_init :: proc(t:^Raw_Table,name:string,allocator:=context.allocator) -> bool {
    gone,error:=make([dynamic]Entity,0,GONE_CAPACITY,allocator) // settle never allocates for it: without it, readers read the table whole
    if error!=nil {return false}
    t.values={allocator=allocator}
    t.entities=make([dynamic]Entity,allocator)
    t.stamps=make([dynamic]u64,allocator)
    t.off=make([dynamic]bool,allocator)
    t.turns=make([dynamic]u64,allocator)
    t.rows=make([dynamic]i32,allocator)
    t.pending=make([dynamic]Pending,allocator)
    t.added={allocator=allocator}
    t.gone=gone
    t.owners=make([dynamic]Row_Owner,allocator)
    t.name=name
    return true
}

table_destroy :: proc(t:^Table($T)) {raw_destroy(raw(t),size_of(T))}

// size: of a value of the table.
raw_destroy :: proc(t:^Raw_Table,size:int) {
    for values in ([2]runtime.Raw_Dynamic_Array{t.values,t.added}) {
        if values.data!=nil {_=mem.free_with_size(values.data,values.cap*size,values.allocator)}
    }
    delete(t.entities);delete(t.stamps);delete(t.off);delete(t.turns);delete(t.rows)
    delete(t.pending);delete(t.gone);delete(t.owners)
    t^={}
}

read :: #force_inline proc "contextless" (t:^Table($T)) -> Read(T) {return {t}}

// The row of an entity whose component is on, -1 without one. Looking is not writing.
table_row :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> int {
    i:=entity_index(e)
    if i>=len(t.rows) {return -1}
    row:=int(t.rows[i])-1
    if row<0 || row>=t.on || t.entities[row]!=e {return -1}
    return row
}
read_row :: #force_inline proc "contextless" (r:Read($T),e:Entity) -> int {return table_row(r.table,e)}
row_of :: proc{table_row,read_row}

// The row of an entity to write; nil without one on.
table_get :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> ^T {
    row:=table_row(t,e)
    return row<0?nil:table_at(t,row)
}

read_get :: #force_inline proc "contextless" (r:Read($T),e:Entity) -> (value:T,ok:bool) {
    if row:=table_row(r.table,e);row>=0 {return r.table.values[row],true}
    return
}

get :: proc{table_get,read_get}

table_has :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> bool {return table_row(t,e)>=0}
read_has :: #force_inline proc "contextless" (r:Read($T),e:Entity) -> bool {return table_row(r.table,e)>=0}
has :: proc{table_has,read_has}

// The row of an entity to write when no other component owns it: what a
// writer of a shared table that is not the owner uses.
free :: #force_inline proc "contextless" (t:^Table($T),e:Entity) -> ^T {
    i:=entity_index(e)
    if i<len(t.owners) && t.owners[i].generation==entity_generation(e) && t.owners[i].id!=0 {return nil}
    return table_get(t,e)
}

// Every row on, to write.
writable :: proc "contextless" (t:^Table($T)) -> []T {
    t.version+=1
    for &s in t.stamps[:t.on] {s=t.version}
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

// The row at an index, to write.
table_at :: #force_inline proc "contextless" (t:^Table($T),row:int) -> ^T {
    t.version+=1
    t.stamps[row]=t.version
    return &t.values[row]
}
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

// The value the last add of this function waits to give an entity, to write
// before the end of the function: what a function reads of what it is making.
// nil without one, or when a remove follows it. Valid until the next add to
// the table.
added :: proc "contextless" (t:^Table($T),e:Entity) -> ^T {return cast(^T)raw_added(raw(t),type_info_of(T),e)}

// The value the entity will have at the end of the function, to write: the
// one an add waits to give it, or else its row on. nil without either.
staged :: proc "contextless" (t:^Table($T),e:Entity) -> ^T {
    if value:=added(t,e);value!=nil {return value}
    return table_get(t,e)
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
}

// What changed since seen, which it moves to now. gone is valid until the
// table settles again.
raw_changes :: proc "contextless" (t:^Raw_Table,seen:^Seen) -> (c:Changes) {
    end:=t.gone_first+u64(len(t.gone))
    c.since=seen.version
    if seen.gone<t.gone_first || seen.gone>end {
        c.all=true
    } else {
        c.gone=t.gone[seen.gone-t.gone_first:]
    }
    seen^={t.version,end}
    return
}
table_changes :: #force_inline proc "contextless" (t:^Table($T),seen:^Seen) -> Changes {return raw_changes(raw(t),seen)}
read_changes :: #force_inline proc "contextless" (r:Read($T),seen:^Seen) -> Changes {return raw_changes(raw(r.table),seen)}
changes :: proc{table_changes,read_changes}

// Whether a row on is among the changes.
table_changed :: #force_inline proc "contextless" (t:^Table($T),c:Changes,row:int) -> bool {return c.all || t.stamps[row]>c.since}
read_changed :: #force_inline proc "contextless" (r:Read($T),c:Changes,row:int) -> bool {return c.all || r.table.stamps[row]>c.since}
changed :: proc{table_changed,read_changed}

table_clear :: proc(t:^Table($T)) {raw_clear(raw(t))}

raw_clear :: proc(t:^Raw_Table) {
    for e in t.entities[:t.on] {locks_release(t,e)}
    t.values.len,t.added.len=0,0
    clear(&t.entities);clear(&t.stamps);clear(&t.off);clear(&t.turns);clear(&t.pending)
    gone_reset(t)
    for &row in t.rows {row=0}
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
    next:=t.version+1
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
    if changed || written {t.version=next}
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
    return adds==0 || raw_reserve(t,size,align,t.values.len+adds,high,entities_capacity(es))
}

// Room for rows rows, and for an entity of index high among them in a World
// of capacity entities: what a settle needs to apply its adds without
// allocating. False without memory, with the rows as they were.
@(private)
raw_reserve :: proc(t:^Raw_Table,size,align,rows,high,capacity:int) -> bool {
    if !runtime.__dynamic_array_reserve(&t.values,size,align,rows) || reserve(&t.entities,rows)!=nil || reserve(&t.stamps,rows)!=nil || reserve(&t.off,rows)!=nil {return false}
    if t.single && reserve(&t.turns,rows)!=nil {return false}
    if cap(t.gone)<2*rows && reserve(&t.gone,max(2*rows,2*cap(t.gone)))!=nil {return false}
    if high>=len(t.rows) && resize(&t.rows,max(high+1,capacity))!=nil {return false}
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
                    t.stamps[row]=next
                    written=true
                }
            }
            moved,on:=table_place(t,size,row,es,next)
            // Off with its entity, the row stays where it was: the stamp
            // tells the readers of every row that its own off changed.
            if !moved && t.off[row]!=was {
                t.stamps[row]=next
                on=true
            }
            changed||=moved
            written||=on
        case:
            if !alive(es,p.entity) {continue}
            value:=rawptr(uintptr(t.added.data)+uintptr(int(p.value)*size))
            if row:=raw_row(t,p.entity);row>=0 {
                if size>0 {mem.copy(raw_at(t,size,row),value,size)}
                t.stamps[row]=next
                written=true
                continue
            }
            i:=entity_index(p.entity)
            if i<len(t.rows) && t.rows[i]!=0 {changed=raw_drop_index(t,size,i) || changed}
            // In a single table, one that comes while another is on comes off, and waits for no turn.
            waits:=t.single && t.on>0
            on:=!waits && (t.base || !entity_off(es,p.entity))
            if on && !locks_claim(t,p.entity,t.name) {continue}
            if t.single {append(&t.turns,waits?0:single_turn(t))}
            row:=t.values.len
            t.values.len+=1
            if size>0 {mem.copy(raw_at(t,size,row),value,size)}
            append(&t.entities,p.entity)
            append(&t.stamps,next)
            append(&t.off,waits)
            t.rows[i]=i32(row+1)
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
        t.stamps[row]=next
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
    if i>=len(t.rows) || t.rows[i]==0 {return false}
    row:=int(t.rows[i]-1)
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
    pop(&t.off)
    if t.single {pop(&t.turns)}
    t.rows[i]=0
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
    t.off[to]=t.off[from]
    if t.single {t.turns[to]=t.turns[from]}
    t.rows[entity_index(t.entities[to])]=i32(to+1)
}

@(private)
table_swap_rows :: proc "contextless" (t:^Raw_Table,size,a,b:int) {
    if a==b {return}
    if size>0 {slice.ptr_swap_non_overlapping(raw_at(t,size,a),raw_at(t,size,b),size)}
    t.entities[a],t.entities[b]=t.entities[b],t.entities[a]
    t.stamps[a],t.stamps[b]=t.stamps[b],t.stamps[a]
    t.off[a],t.off[b]=t.off[b],t.off[a]
    if t.single {t.turns[a],t.turns[b]=t.turns[b],t.turns[a]}
    t.rows[entity_index(t.entities[a])]=i32(a+1)
    t.rows[entity_index(t.entities[b])]=i32(b+1)
}

// Notes that the row of an entity stopped being on, in the room table_init
// reserved: it never allocates. Full, it drops its older half; without room
// every reader reads the table whole.
@(private)
gone_push :: proc "contextless" (t:^Raw_Table,e:Entity) {
    gone:=cast(^runtime.Raw_Dynamic_Array)&t.gone
    if gone.len==gone.cap {
        if gone.len==0 {
            gone_reset(t)
            return
        }
        half:=(gone.len+1)/2
        copy(t.gone[:],t.gone[half:])
        gone.len-=half
        t.gone_first+=u64(half)
    }
    gone.len+=1
    t.gone[gone.len-1]=e
}

// No reader has seen what the table holds now.
@(private)
gone_reset :: proc "contextless" (t:^Raw_Table) {
    t.gone_first+=u64(len(t.gone))+1
    clear(&t.gone)
}

table_copy :: proc(dst,src:^Table($T)) -> bool {return raw_copy(raw(dst),raw(src),type_info_of([dynamic]T))}

// values: the type of the dynamic array of the values of the table.
raw_copy :: proc(dst,src:^Raw_Table,values:^runtime.Type_Info) -> bool {
    if dst==src {return true}
    dst.on=0
    if !value_copy(&dst.values,&src.values,values) ||
       !value_copy(&dst.entities,&src.entities,type_info_of([dynamic]Entity)) ||
       !value_copy(&dst.stamps,&src.stamps,type_info_of([dynamic]u64)) ||
       !value_copy(&dst.off,&src.off,type_info_of([dynamic]bool)) ||
       !value_copy(&dst.turns,&src.turns,type_info_of([dynamic]u64)) ||
       !value_copy(&dst.rows,&src.rows,type_info_of([dynamic]i32)) ||
       !value_copy(&dst.owners,&src.owners,type_info_of([dynamic]Row_Owner)) {return false}
    clear(&dst.pending)
    dst.added.len=0
    first:=max(dst.gone_first+u64(len(dst.gone)),src.gone_first+u64(len(src.gone)))+1
    clear(&dst.gone)
    dst.gone_first=first
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
// copy mark says; the rows whose stamps differ when both have the same rows;
// all of it otherwise. To the readers of dst it is a copy like table_copy.
table_copy_changed :: proc(dst,src:^Table($T),mark:^Copy_Mark) -> bool {
    return #force_inline raw_copy_changed(raw(dst),raw(src),type_info_of(T),type_info_of([dynamic]T),size_of(T),mark)
}

// info and size: of a value of the table; values: as raw_copy takes it.
raw_copy_changed :: proc(dst,src:^Raw_Table,info,values:^runtime.Type_Info,size:int,mark:^Copy_Mark) -> bool {
    if dst==src {return true}
    if mark.valid && mark.version==src.version && mark.layout==src.layout {return true}
    mark.valid=false
    same:=dst.on==src.on && len(dst.entities)==len(src.entities) && slice.equal(dst.entities[:],src.entities[:]) && slice.equal(dst.off[:],src.off[:])
    if !same {
        if !raw_copy(dst,src,values) {return false}
        mark^={src.version,src.layout,true}
        return true
    }
    flat:=-1
    for stamp,row in src.stamps {
        if dst.stamps[row]==stamp {continue}
        if flat<0 {flat=int(value_flat(info))}
        if flat==1 {mem.copy_non_overlapping(raw_at(dst,size,row),raw_at(src,size,row),size)} else if !value_copy(raw_at(dst,size,row),raw_at(src,size,row),info) {return false}
        dst.stamps[row]=stamp
    }
    if !slice.equal(dst.turns[:],src.turns[:]) && !value_copy(&dst.turns,&src.turns,type_info_of([dynamic]u64)) {return false}
    if !slice.equal(dst.rows[:],src.rows[:]) && !value_copy(&dst.rows,&src.rows,type_info_of([dynamic]i32)) {return false}
    if !slice.equal(dst.owners[:],src.owners[:]) && !value_copy(&dst.owners,&src.owners,type_info_of([dynamic]Row_Owner)) {return false}
    clear(&dst.pending)
    dst.added.len=0
    first:=max(dst.gone_first+u64(len(dst.gone)),src.gone_first+u64(len(src.gone)))+1
    clear(&dst.gone)
    dst.gone_first=first
    dst.version=max(dst.version,src.version)+1
    dst.layout=max(dst.layout,src.layout)+1
    mark^={src.version,src.layout,true}
    return true
}

table_swap :: proc(a,b:^Table($T)) {raw_swap(raw(a),raw(b))}

raw_swap :: proc(a,b:^Raw_Table) {
    if a==b {return}
    version:=max(a.version,b.version)+1
    layout:=max(a.layout,b.layout)+1
    first:=max(a.gone_first+u64(len(a.gone)),b.gone_first+u64(len(b.gone)))+1
    a.values,b.values=b.values,a.values
    a.entities,b.entities=b.entities,a.entities
    a.stamps,b.stamps=b.stamps,a.stamps
    a.off,b.off=b.off,a.off
    a.turns,b.turns=b.turns,a.turns
    a.rows,b.rows=b.rows,a.rows
    a.owners,b.owners=b.owners,a.owners
    a.pending,b.pending=b.pending,a.pending
    a.added,b.added=b.added,a.added
    a.on,b.on=b.on,a.on
    table_waits(a,len(a.pending)>0)
    table_waits(b,len(b.pending)>0)
    clear(&a.gone);clear(&b.gone)
    a.gone_first,b.gone_first=first,first
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
    for lock in t.locks {lock_owners(t,lock)[i]={generation,lock.id}}
    return true
}

@(private)
locks_release :: proc(t:^Raw_Table,e:Entity) {
    i:=entity_index(e)
    for lock in t.locks {
        owners:=lock_owners(t,lock)
        if i<len(owners) && owners[i].generation==entity_generation(e) && owners[i].id==lock.id {owners[i]={}}
    }
}

// The owners of the rows a lock of a table takes: those of the table offset
// bytes away from it, in the same World.
lock_owners :: #force_inline proc "contextless" (t:^Raw_Table,lock:Lock) -> ^[dynamic]Row_Owner {
    return &(cast(^Raw_Table)rawptr(uintptr(int(uintptr(t))+lock.offset))).owners
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
    off:[dynamic]bool,
    turns:[dynamic]u64,
    rows:[dynamic]i32,
    pending:[dynamic]Pending,
    added:runtime.Raw_Dynamic_Array,
    gone:[dynamic]Entity,
    version:u64,
    layout:u64,
    gone_first:u64,
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
#assert(offset_of(Raw_Table,turns)==offset_of(Table(u8),turns))
#assert(offset_of(Raw_Table,gone)==offset_of(Table(u8),gone))
#assert(offset_of(Raw_Table,on)==offset_of(Table(u8),on))
#assert(offset_of(Raw_Table,name)==offset_of(Table(u8),name))
#assert(offset_of(Raw_Table,waits)==offset_of(Table(u8),waits))

raw :: #force_inline proc "contextless" (t:^Table($T)) -> ^Raw_Table {return cast(^Raw_Table)t}

// The row of an entity, on or off; -1 without one.
raw_row :: proc "contextless" (t:^Raw_Table,e:Entity) -> int {
    i:=entity_index(e)
    if i>=len(t.rows) {return -1}
    row:=int(t.rows[i])-1
    if row<0 || t.entities[row]!=e {return -1}
    return row
}

// The row of an entity to write, on or off; nil without one.
raw_get :: proc "contextless" (t:^Raw_Table,type:^runtime.Type_Info,e:Entity) -> rawptr {
    row:=raw_row(t,e)
    if row<0 {return nil}
    t.version+=1
    t.stamps[row]=t.version
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
    if row:=raw_row(t,e);row>=0 {
        t.version+=1
        t.stamps[row]=t.version
    }
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
    return raw_get(t,type,e)
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
    if t==nil || info==nil || e==NONE || t.values.len!=len(t.entities) || len(t.stamps)!=len(t.entities) || len(t.off)!=len(t.entities) {return false}
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
    if t.values.len>=t.values.cap || len(t.entities)>=cap(t.entities) || len(t.stamps)>=cap(t.stamps) || len(t.off)>=cap(t.off) || i>=max(len(t.rows),cap(t.rows)) {return false}
    if t.single && len(t.turns)>=cap(t.turns) {return false}
    for lock in t.locks {if owners:=lock_owners(t,lock);i>=max(len(owners),cap(owners)) {return false}}
    if i<len(t.rows) && t.rows[i]!=0 {raw_drop_index(t,size,i)}
    if i>=len(t.rows) && resize(&t.rows,i+1)!=nil {return false}
    t.version+=1
    if t.single {append(&t.turns,off?0:single_turn(t))}
    row:=t.values.len
    t.values.len+=1
    if size>0 {mem.copy(raw_at(t,size,row),value,size)}
    append(&t.entities,e);append(&t.stamps,t.version);append(&t.off,off && !t.base)
    t.rows[i]=i32(row+1)
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
                fail("%s wrote the %s of entity %v without asking for its row (get, at, free, writable or touch)",function,t.name,t.entities[row])
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
