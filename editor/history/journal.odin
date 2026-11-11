package history

import "base:runtime"
import "core:mem"
import "core:slice"
import "mirai:core"
import "mirai:std/base"

// The journal of the edited World, in Edits: the image of what the World held
// when the journal last took it (the rows of the tables a scene saves and the
// entities), the steps of undo with what the rows they changed were, and,
// while collaboration reads it, the rows the image took
// since. Readers keep
// a cursor of their own: undo its place in the steps, the review of an agent
// the state of a step, collaboration its place in the changes.
// What changed since the image was taken comes from core.changes of each
// table, the rows stamped since and the entities whose row went, compared
// only with their rows in the image.
//
// With a table Id the image keeps the rows of the authors (the entities with
// an Id now or in the image): derived rows never enter a step.

// What a table held when the journal took it, by entity and in no order.
Journal_Table :: struct {
    values:[dynamic]u8,
    entities:[dynamic]core.Entity,
    off:[dynamic]bool, // by row: turned off by itself
    rows:[dynamic]i32, // by entity index: row+1
    seen:core.Seen,    // of the table, when it was taken
}

// The entities when the journal took them.
Journal_Entities :: struct {
    generation:[dynamic]u32,
    alive:[dynamic]bool, // by index: an entity of that generation lives
    count:int,
}

// A side of the entities of a step, by index: the generation (0: no entity
// ever had it there) and whether one lives.
Entity_Side :: struct {
    generation:[dynamic]u32,
    alive:[dynamic]bool,
}

// The entities born or gone in a step, by index, on its two sides: held is
// what the step left in the World where it is, the other what a swap puts back.
Entity_Changes :: struct {
    indices:[dynamic]u32,
    using other:Entity_Side,
    held:Entity_Side,
}

// A row the image took, as it was before: for the readers of the changes.
Journal_Change :: struct {
    entity:core.Entity,
    id:base.Entity_Id, // of the entity, also once it is gone
    table:i32,
    present,off:bool,
    valued:bool, // its bytes of before are in the values of the changes: taken while collaboration read
    value:u64,   // where, counted from the first value ever kept
}

// A row of a table whose saved bytes, off state or presence the World and the
// image disagree on; -1 where it has none.
Journal_Row :: struct {entity:core.Entity,image_row,row:int}

Journal_Diff :: struct {
    table:^core.Raw_Table,
    image:^Journal_Table,
    size:int,
    ranges:[][2]int,
    c:core.Changes,
    authors:History_Authors,
    only_authors:bool,
    phase,at:int,
}

@(private)
ENTITY_FREE :: u8(1)
ENTITY_TURNED :: u8(2)
@(private)
ENTITY_GOING :: u8(4)

journal_row :: proc "contextless" (image:^Journal_Table,e:core.Entity) -> int {
    i:=core.entity_index(e)
    if i>=len(image.rows) {return -1}
    row:=int(image.rows[i])-1
    return row>=0 && image.entities[row]==e?row:-1
}

journal_value :: proc "contextless" (image:^Journal_Table,size,row:int) -> rawptr {
    return rawptr(uintptr(raw_data(image.values))+uintptr(row*size))
}

@(private)
table_value :: proc "contextless" (t:^core.Raw_Table,size,row:int) -> rawptr {
    return rawptr(uintptr(t.values.data)+uintptr(row*size))
}

// Room in the image for rows rows and for the entities of index below
// indices. It grows by an eighth at least; false without memory.
@(private)
journal_room :: proc(image:^Journal_Table,rows,size,indices:int) -> bool {
    if rows>cap(image.entities) || rows>cap(image.off) || rows*size>cap(image.values) {
        n:=max(rows,cap(image.entities)+cap(image.entities)/8+8)
        if reserve(&image.values,n*size)!=nil || reserve(&image.entities,n)!=nil || reserve(&image.off,n)!=nil {return false}
    }
    if indices>cap(image.rows) && reserve(&image.rows,max(indices,cap(image.rows)+cap(image.rows)/8+8))!=nil {return false}
    return true
}

// The image takes a row: at row, or a new one for an entity it has none of.
@(private)
journal_put :: proc(image:^Journal_Table,e:core.Entity,row:int,value:rawptr,size:int,off:bool) -> bool {
    at:=row
    if at<0 {
        i:=core.entity_index(e)
        if i<len(image.rows) && image.rows[i]!=0 {journal_drop(image,int(image.rows[i])-1,size)}
        at=len(image.entities)
        if !journal_room(image,at+1,size,i+1) {return false}
        if i>=len(image.rows) {resize(&image.rows,i+1)}
        resize(&image.values,(at+1)*size)
        append(&image.entities,e)
        append(&image.off,off)
        image.rows[i]=i32(at+1)
    }
    if size>0 {mem.copy(journal_value(image,size,at),value,size)}
    image.off[at]=off
    return true
}

@(private)
journal_drop :: proc(image:^Journal_Table,row,size:int) {
    e:=image.entities[row]
    last:=len(image.entities)-1
    image.rows[core.entity_index(e)]=0
    if row!=last {
        moved:=image.entities[last]
        image.entities[row],image.off[row]=moved,image.off[last]
        if size>0 {mem.copy(journal_value(image,size,row),journal_value(image,size,last),size)}
        image.rows[core.entity_index(moved)]=i32(row+1)
    }
    pop(&image.entities)
    pop(&image.off)
    resize(&image.values,last*size)
}

journal_table_free :: proc(image:^Journal_Table) {
    delete(image.values);delete(image.entities);delete(image.off);delete(image.rows)
    image^={}
}

// The image of a table is what it holds now: every row, or with only_authors those of the authors.
@(private)
journal_table_take :: proc(image:^Journal_Table,t:^core.Raw_Table,size:int,authors:History_Authors,only_authors:bool) -> bool {
    n,kept:=len(t.entities),len(t.entities)
    if only_authors {
        kept=0
        for e in t.entities {if history_is_author(authors,e) {kept+=1}}
    }
    if cap(image.entities)>2*kept+64 {journal_table_free(image)}
    image.seen={}
    _=core.raw_changes(t,&image.seen)
    clear(&image.rows)
    indices:=0
    for e in t.entities {indices=max(indices,core.entity_index(e)+1)}
    if resize(&image.values,kept*size)!=nil || resize(&image.entities,kept)!=nil || resize(&image.off,kept)!=nil || resize(&image.rows,indices)!=nil {
        clear(&image.values);clear(&image.entities);clear(&image.off);clear(&image.rows)
        return false
    }
    if kept==n {
        if n*size>0 {mem.copy(raw_data(image.values),t.values.data,n*size)}
        copy(image.entities[:],t.entities[:])
        copy(image.off[:],t.off[:])
        for e,row in t.entities {image.rows[core.entity_index(e)]=i32(row+1)}
        return true
    }
    at:=0
    for e,row in t.entities {
        if !history_is_author(authors,e) {continue}
        if size>0 {mem.copy(journal_value(image,size,at),table_value(t,size,row),size)}
        image.entities[at],image.off[at]=e,t.off[row]
        image.rows[core.entity_index(e)]=i32(at+1)
        at+=1
    }
    return true
}

// Takes, in every table, the rows of the entities turned, up to index bound,
// that are not alive.
@(private)
turned_rows_drop :: proc(w:core.World_Ref,es:^core.Entities,marks:[]u8,bound:int) {
    for &t in w.info.tables {
        if t.place!=w.place {continue}
        table:=core.world_table_at(w,&t)
        // From the last: a row taken leaves in its place one already seen.
        for row:=len(table.entities)-1;row>=0;row-=1 {
            e:=table.entities[row]
            i:=core.entity_index(e)
            if i<bound && entity_turned(es,marks,i) && !core.alive(es,e) {core.raw_drop(table,t.info,e)}
        }
    }
}

// Whether a table changed since its image was taken.
journal_moved :: proc "contextless" (t:^core.Raw_Table,image:^Journal_Table) -> bool {
    return t.version!=image.seen.version || core.log_end(t.gone)!=image.seen.gone
}

journal_diff :: proc(t:^core.Raw_Table,image:^Journal_Table,size:int,ranges:[][2]int,authors:History_Authors,only_authors:bool) -> (d:Journal_Diff) {
    seen:=image.seen
    d={table=t,image=image,size=size,ranges=ranges,c=core.raw_changes(t,&seen),authors=authors,only_authors=only_authors}
    if d.c.all {d.phase,d.at=2,len(image.entities)}
    return
}

// Each entity of a diff once, however many times its row went: what a step
// records. The other diffs take a change that makes a later visit of the
// same entity equal, and do not allocate. False without memory for it.
journal_diff_once :: proc(d:^Journal_Diff) -> bool {
    if len(d.c.gone)<2 {return true}
    gone,error:=slice.clone(d.c.gone,context.temp_allocator)
    if error!=nil {return false}
    slice.sort(gone)
    d.c.gone=slice.unique(gone)
    return true
}

@(private)
journal_differ :: proc(d:^Journal_Diff,image_row,row:int) -> bool {
    if image_row<0 || row<0 {return image_row!=row}
    return d.image.off[image_row]!=d.table.off[row] || !saved_equal(table_value(d.table,d.size,row),journal_value(d.image,d.size,image_row),d.size,d.ranges)
}

// The next row the World and the image disagree on: of the entities whose
// row went or turned off, once each after journal_diff_once, and of the rows
// stamped since; of every row of both when the table holds rows the image did
// not see. Rows are visited from the last, so a row dropped meanwhile does not hide another.
journal_diff_next :: proc(d:^Journal_Diff) -> (r:Journal_Row,ok:bool) {
    t,image:=d.table,d.image
    for {
        switch d.phase {
        case 0:
            if d.at>=len(d.c.gone) {
                d.phase,d.at=1,len(t.entities)
                if t.version<=d.c.since {return}
                continue
            }
            e:=d.c.gone[d.at]
            d.at+=1
            if d.only_authors && !history_is_author(d.authors,e) {continue}
            row:=core.raw_row(t,e)
            if row>=0 && t.stamps[row]>d.c.since {continue}
            if image_row:=journal_row(image,e);journal_differ(d,image_row,row) {return {e,image_row,row},true}
        case 1:
            if d.at<=0 {return}
            d.at-=1
            row:=d.at
            if row>=len(t.entities) || t.stamps[row]<=d.c.since {continue}
            e:=t.entities[row]
            if d.only_authors && !history_is_author(d.authors,e) {continue}
            if image_row:=journal_row(image,e);journal_differ(d,image_row,row) {return {e,image_row,row},true}
        case 2:
            if d.at<=0 {d.phase,d.at=3,len(t.entities);continue}
            d.at-=1
            if d.at>=len(image.entities) {continue}
            e:=image.entities[d.at]
            if d.only_authors && !history_is_author(d.authors,e) {continue}
            if row:=core.raw_row(t,e);journal_differ(d,d.at,row) {return {e,d.at,row},true}
        case 3:
            if d.at<=0 {return}
            d.at-=1
            if d.at>=len(t.entities) {continue}
            e:=t.entities[d.at]
            if d.only_authors && !history_is_author(d.authors,e) {continue}
            if journal_row(image,e)<0 {return {e,-1,d.at},true}
        }
    }
}

// The index of the table Id in the world info; -1 without one.
journal_id_table :: proc(w:core.World_Ref) -> int {
    for t,i in w.info.tables {
        if t.place==w.place && t.type==core.Id {return i}
    }
    return -1
}

// The Id of an entity: in the World, or in the image once it is gone.
journal_id :: proc(edits:^Edits,w:core.World_Ref,id_table:int,e:core.Entity) -> base.Entity_Id {
    if id_table<0 {return 0}
    if t:=core.world_table_at(w,&w.info.tables[id_table]);core.raw_row(t,e)>=0 {return (^core.Id)(table_value(t,size_of(core.Id),core.raw_row(t,e))).value}
    if id_table<len(edits.image) {
        if row:=journal_row(&edits.image[id_table],e);row>=0 {return (^core.Id)(journal_value(&edits.image[id_table],size_of(core.Id),row)).value}
    }
    return 0
}

// The tables a scene saves in the order the image takes them: the table Id
// last, so the authors of the others are those the image had.
@(private)
journal_order :: proc(edits:^Edits,w:core.World_Ref,id_table,at:int) -> (index:int,ok:bool) {
    index=at==len(w.info.tables)?id_table:at
    ok=index>=0 && index<len(edits.saved) && edits.saved[index] && (index!=id_table || at==len(w.info.tables))
    return
}

// The transient ranges of every table a scene saves, kept for the diffs that may not allocate.
journal_ranges :: proc(edits:^Edits,w:core.World_Ref) -> bool {
    for ranges in edits.ranges[min(len(w.info.tables),len(edits.ranges)):] {delete(ranges.ranges)}
    if resize(&edits.ranges,len(w.info.tables))!=nil {return false}
    for &table,index in w.info.tables {
        cached:=&edits.ranges[index]
        if index>=len(edits.saved) || !edits.saved[index] || cached.info==table.info {continue}
        error:runtime.Allocator_Error
        ranges:=transient_ranges(w.info,table.info,context.allocator,&error)
        if error!=nil {delete(ranges);return false}
        delete(cached.ranges)
        cached.info,cached.ranges=table.info,ranges
    }
    return true
}

// The image takes the World: the rows the tables changed since it saw them,
// and the entities. While collaboration reads, what it took goes to the
// changes. It allocates only past the room journal_room and the reservations
// of a commit or an undo left.
@(private)
journal_sync :: proc(edits:^Edits,w:core.World_Ref) -> bool {
    authors,only_authors:=history_authors(edits,w)
    id:=journal_id_table(w)
    ok:=true
    for at in 0..=len(w.info.tables) {
        i,saved:=journal_order(edits,w,id,at)
        if !saved {continue}
        info:=&w.info.tables[i]
        table:=core.world_table_at(w,info)
        image:=&edits.image[i]
        if !journal_moved(table,image) {continue}
        size:=info.info.size
        d:=journal_diff(table,image,size,edits.ranges[i].ranges,authors,only_authors && i!=id)
        for r in journal_diff_next(&d) {
            if edits.reading {
                change:=Journal_Change{entity=r.entity,id=journal_id(edits,w,id,r.entity),table=i32(i),present=r.image_row>=0,off=r.image_row>=0 && image.off[r.image_row]}
                if edits.reading && change.present {
                    at:=edits.change_values_first+u64(len(edits.change_values))
                    if _,error:=append(&edits.change_values,..([^]u8)(journal_value(image,size,r.image_row))[:size]);error==nil {change.valued,change.value=true,at}
                }
                _,error:=append(&edits.changes,change)
                ok&&=error==nil
            }
            if r.row<0 {journal_drop(image,r.image_row,size)} else {ok&&=journal_put(image,r.entity,r.image_row,table_value(table,size,r.row),size,table.off[r.row])}
        }
        _=core.raw_changes(table,&image.seen)
    }
    return journal_entities_take(&edits.image_entities,core.world_entities(w)) && ok
}

// How many rows of a table the image would take now and how many of them it
// has none of: what journal_sync needs room for.
@(private)
journal_count :: proc(edits:^Edits,w:core.World_Ref,table:int,authors:History_Authors,only_authors:bool) -> (rows,adds:int) {
    info:=&w.info.tables[table]
    current:=core.world_table_at(w,info)
    image:=&edits.image[table]
    if !journal_moved(current,image) {return}
    d:=journal_diff(current,image,info.info.size,edits.ranges[table].ranges,authors,only_authors)
    for r in journal_diff_next(&d) {
        rows+=1
        if r.image_row<0 {adds+=1}
    }
    return
}

// The image takes the row of one entity, without a step nor a change: what
// collaboration received from the others.
journal_take :: proc(edits:^Edits,w:core.World_Ref,table:int,e:core.Entity) -> bool {
    if table<0 || table>=len(edits.image) || !edits.saved[table] {return true}
    info:=&w.info.tables[table]
    current:=core.world_table_at(w,info)
    image:=&edits.image[table]
    size:=info.info.size
    row,image_row:=core.raw_row(current,e),journal_row(image,e)
    if row<0 {
        if image_row>=0 {journal_drop(image,image_row,size)}
        return true
    }
    return journal_put(image,e,image_row,table_value(current,size,row),size,current.off[row])
}

// The image takes size bytes at offset of the row of e as the World has
// them, without a step nor a change: a field the engine wrote. Nothing when
// the image has no row of e, which is new to the next step whole.
journal_take_field :: proc(edits:^Edits,w:core.World_Ref,table:int,e:core.Entity,offset,size:int) {
    if table<0 || table>=len(edits.image) || !edits.saved[table] {return}
    info:=&w.info.tables[table]
    current:=core.world_table_at(w,info)
    image:=&edits.image[table]
    width:=info.info.size
    row,image_row:=core.raw_row(current,e),journal_row(image,e)
    if row<0 || image_row<0 || offset<0 || offset+size>width {return}
    mem.copy(rawptr(uintptr(journal_value(image,width,image_row))+uintptr(offset)),rawptr(uintptr(table_value(current,width,row))+uintptr(offset)),size)
}

// The image takes whether the row of e is turned off by itself, without a
// step nor a change. Nothing when the image has no row of e.
journal_take_off :: proc(edits:^Edits,w:core.World_Ref,table:int,e:core.Entity) {
    if table<0 || table>=len(edits.image) || !edits.saved[table] {return}
    current:=core.world_table_at(w,&w.info.tables[table])
    image:=&edits.image[table]
    row,image_row:=core.raw_row(current,e),journal_row(image,e)
    if row>=0 && image_row>=0 {image.off[image_row]=current.off[row]}
}

// The image of the index of an entity takes what the World has there.
journal_take_entity :: proc(edits:^Edits,w:core.World_Ref,e:core.Entity) -> bool {
    es:=core.world_entities(w)
    image:=&edits.image_entities
    i:=core.entity_index(e)
    if i<=0 || i>=len(es.generation) {return true}
    if i>=len(image.generation) && (resize(&image.generation,i+1)!=nil || resize(&image.alive,i+1)!=nil) {return false}
    alive:=core.alive(es,e)
    if alive!=image.alive[i] {image.count+=alive?1:-1}
    image.generation[i],image.alive[i]=es.generation[i],alive
    return true
}

@(private)
journal_entities_take :: proc(image:^Journal_Entities,es:^core.Entities) -> bool {
    n:=len(es.generation)
    if resize(&image.generation,n)!=nil || resize(&image.alive,n)!=nil {return false}
    copy(image.generation[:],es.generation[:])
    for &alive,i in image.alive {alive=i>0}
    for index in es.free {image.alive[index]=false}
    image.count=es.alive
    return true
}

@(private)
journal_entities_free :: proc(image:^Journal_Entities) {
    delete(image.generation);delete(image.alive)
    image^={}
}

// Whether the World has the entities of the image: with the same generations
// and as many alive, none was born, reborn or gone.
@(private)
journal_entities_same :: proc(image:^Journal_Entities,es:^core.Entities) -> bool {
    if len(image.generation)!=len(es.generation) || image.count!=es.alive {return false}
    return len(es.generation)==0 || mem.compare_ptrs(raw_data(image.generation),raw_data(es.generation),len(es.generation)*size_of(u32))==0
}

// The entities of the image that the World has otherwise: as the image has
// them on the other side, as the World has them held. marks: zero, as long as
// the generations.
@(private)
entity_changes_take :: proc(out:^Entity_Changes,image:^Journal_Entities,es:^core.Entities,marks:[]u8) -> bool {
    for index in es.free {marks[index]|=ENTITY_FREE}
    defer for index in es.free {marks[index]&~=ENTITY_FREE}
    for i in 1..<max(len(image.generation),len(es.generation)) {
        was,was_alive:=u32(0),false
        if i<len(image.generation) {was,was_alive=image.generation[i],image.alive[i]}
        now,alive:=u32(0),false
        if i<len(es.generation) {now,alive=es.generation[i],marks[i]&ENTITY_FREE==0}
        if was_alive==alive && (was==now || !alive && was==0) {continue}
        if _,error:=append(&out.indices,u32(i));error!=nil {return false}
        if _,error:=append(&out.generation,was);error!=nil {return false}
        if _,error:=append(&out.alive,was_alive);error!=nil {return false}
        if _,error:=append(&out.held.generation,now);error!=nil {return false}
        if _,error:=append(&out.held.alive,alive);error!=nil {return false}
    }
    return true
}

@(private)
entity_changes_free :: proc(changes:^Entity_Changes) {
    delete(changes.indices);delete(changes.generation);delete(changes.alive)
    delete(changes.held.generation);delete(changes.held.alive)
    changes^={}
}

// Gives an index of the World a generation and whether one lives there,
// and marks it turned. Generation 0 is one no handle had; an entity that goes
// takes another generation than the one it had. The free list must have room.
@(private)
entity_turn :: proc(es:^core.Entities,marks:[]u8,index:int,generation:u32,alive:bool) -> (was:u32,was_alive:bool) {
    was,was_alive=es.generation[index],marks[index]&ENTITY_FREE==0
    to:=generation
    if to==0 || was_alive && !alive && to==was {to=max(was+1,1)}
    es.generation[index]=to
    marks[index]|=ENTITY_TURNED
    if was_alive && !alive {
        append(&es.free,u32(index))
        marks[index]|=ENTITY_FREE
        es.alive-=1
    } else if !was_alive && alive {
        marks[index]&~=ENTITY_FREE
        es.alive+=1
    }
    return
}

// The free list keeps what is still free, in its order, and the marks of it go.
@(private)
entities_free_settle :: proc(es:^core.Entities,marks:[]u8) {
    n:=0
    for index in es.free {
        if marks[index]&ENTITY_FREE==0 {continue}
        marks[index]&~=ENTITY_FREE
        es.free[n]=index
        n+=1
    }
    resize(&es.free,n)
}

// Puts the other side of the entities of a step in the World: the step then
// holds what it put and keeps what the World had as the other side.
@(private)
entity_changes_swap :: proc(changes:^Entity_Changes,es:^core.Entities,marks:[]u8) {
    for index in es.free {marks[index]|=ENTITY_FREE}
    for i,k in changes.indices {
        if int(i)>=len(es.generation) {continue}
        changes.generation[k],changes.alive[k]=entity_turn(es,marks,int(i),changes.generation[k],changes.alive[k])
        changes.held.generation[k],changes.held.alive[k]=es.generation[i],marks[i]&ENTITY_FREE==0
    }
    entities_free_settle(es,marks)
}

// The World takes the entities of the image back. The indices born since
// go: the generations are as long as the image has them, and marks needs no
// more room than that.
@(private)
journal_entities_put :: proc(image:^Journal_Entities,es:^core.Entities,marks:[]u8) {
    n:=min(len(image.generation),len(es.generation))
    born,kept:=len(es.generation)-n,0
    for index in es.free {
        if int(index)>=n {born-=1;continue}
        marks[index]|=ENTITY_FREE
        es.free[kept]=index
        kept+=1
    }
    resize(&es.free,kept)
    resize(&es.generation,n)
    es.alive-=born
    for i in 1..<n {
        generation,alive:=image.generation[i],image.alive[i]
        now,now_alive:=es.generation[i],marks[i]&ENTITY_FREE==0
        if alive==now_alive && (generation==now || !alive && generation==0) {continue}
        entity_turn(es,marks,i,generation,alive)
    }
    entities_free_settle(es,marks)
}

// Whether an index was turned: marked, or past the generations, gone.
@(private)
entity_turned :: #force_inline proc "contextless" (es:^core.Entities,marks:[]u8,i:int) -> bool {
    return i>=len(es.generation) || i<len(marks) && marks[i]&ENTITY_TURNED!=0
}

// After entities were turned, up to index bound: the rows of the ones gone,
// in every table; a World_Transform without a Transform (of a turned entity,
// or of one whose Transform went since transforms); with a table Id, the
// entities turned alive without a row. Clears the marks.
world_turned_prune :: proc(w:core.World_Ref,marks:[]u8,bound:int,transforms:core.Seen) {
    core.world_settle(w)
    es:=core.world_entities(w)
    n:=min(len(marks),len(es.generation))
    turned_rows_drop(w,es,marks,bound)
    locals,poses:=core.world_table_of(w,core.Transform),core.world_table_of(w,core.World_Transform)
    if locals!=nil && poses!=nil {
        drop :: proc(locals:^core.Table(core.Transform),poses:^core.Table(core.World_Transform),e:core.Entity) {
            if core.raw_row(core.raw(poses),e)>=0 && core.raw_row(core.raw(locals),e)<0 {core.raw_drop(core.raw(poses),type_info_of(core.World_Transform),e)}
        }
        seen:=transforms
        c:=core.raw_changes(core.raw(locals),&seen)
        if c.all {
            for row:=len(poses.entities)-1;row>=0;row-=1 {drop(locals,poses,poses.entities[row])}
        } else {
            for e in c.gone {drop(locals,poses,e)}
            for i in 1..<n {if marks[i]&ENTITY_TURNED!=0 {drop(locals,poses,core.entity_make(i,es.generation[i]))}}
        }
    }
    core.world_settle(w)
    if core.world_table_of(w,core.Id)!=nil {
        for index in es.free {if int(index)<n {marks[index]|=ENTITY_FREE}}
        each: for i in 1..<n {
            if marks[i]&(ENTITY_TURNED|ENTITY_FREE)!=ENTITY_TURNED {continue}
            e:=core.entity_make(i,es.generation[i])
            for &t in w.info.tables {
                if t.place==w.place && core.raw_row(core.world_table_at(w,&t),e)>=0 {continue each}
            }
            core.destroy(es,e)
        }
        for index in es.free {if int(index)<n {marks[index]&~=ENTITY_FREE}}
    }
    for &mark in marks[:n] {mark&~=ENTITY_TURNED}
    core.world_settle(w)
}

// What the image took since collaboration looked at cursor, which then points
// past it; what it read goes (journal_read_done).
journal_read :: proc(edits:^Edits,cursor:^u64) -> []Journal_Change {
    end:=edits.changes_first+u64(len(edits.changes))
    from:=clamp(cursor^,edits.changes_first,end)
    cursor^=end
    return edits.changes[from-edits.changes_first:]
}

// What the row of a change held before the image took it; false when it was
// not kept. Valid until a reader is done or the image takes the World again.
journal_change_value :: proc(edits:^Edits,change:Journal_Change,size:int) -> (value:[]u8,kept:bool) {
    if !change.valued || change.value<edits.change_values_first {return}
    at:=int(change.value-edits.change_values_first)
    if at+size>len(edits.change_values) {return}
    return edits.change_values[at:][:size],true
}

journal_read_done :: proc(edits:^Edits,cursor:u64) {
    edits.read_done=cursor
    journal_trim(edits)
}

@(private)
journal_trim :: proc(edits:^Edits) {
    end:=edits.changes_first+u64(len(edits.changes))
    first:=end
    if edits.reading {first=min(first,edits.read_done)}
    read:=int(clamp(first,edits.changes_first,end)-edits.changes_first)
    remove_range(&edits.changes,0,read)
    edits.changes_first+=u64(read)
    kept:=edits.change_values_first+u64(len(edits.change_values))
    for change in edits.changes {
        if change.valued {kept=change.value;break}
    }
    remove_range(&edits.change_values,0,int(kept-edits.change_values_first))
    edits.change_values_first=kept
}

// Forgets the changes for every reader: the World they were of was replaced.
journal_changes_drop :: proc(edits:^Edits) {
    end:=edits.changes_first+u64(len(edits.changes))
    edits.read_done=end
    journal_trim(edits)
}

// Starts or stops reading the changes: a reader that starts sees from now on.
journal_reading :: proc(edits:^Edits,on:bool) -> (cursor:u64) {
    edits.reading=on
    end:=edits.changes_first+u64(len(edits.changes))
    journal_read_done(edits,end)
    if !on {shrink(&edits.change_values)}
    if !on {shrink(&edits.changes)}
    return end
}

// Whether the rows of the authors are as the journal has them.
journal_settled :: proc(edits:^Edits,w:core.World_Ref) -> bool {
    if w.data!=edits.world || !journal_ranges(edits,w) {return false}
    authors,only_authors:=history_authors(edits,w)
    id:=journal_id_table(w)
    for &info,i in w.info.tables {
        if i>=len(edits.saved) || !edits.saved[i] {continue}
        table:=core.world_table_at(w,&info)
        if !journal_moved(table,&edits.image[i]) {continue}
        d:=journal_diff(table,&edits.image[i],info.info.size,edits.ranges[i].ranges,authors,only_authors && i!=id)
        if _,differs:=journal_diff_next(&d);differs {return false}
    }
    return true
}
