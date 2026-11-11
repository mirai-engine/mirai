package core

import "base:runtime"
import "core:mem"
import "core:slice"
import "mirai:std/serial"

// Moves what the generated structs of one World_Info hold into those of
// another, as a new library of the same project lays them out: the editor
// takes a component, a storage or a plugin that changed without starting
// again. A table or a storage that keeps its name, its place and the hash of
// the layout of its type moves whole; one whose type changed is converted by
// the names of its fields (serial.Migration); a new one starts as the new
// library makes it, and one that is gone is freed with the old library.
//
// A place migrates into a struct the new library initialized (fresh): what
// moves is swapped into it, so the old struct keeps what the new library made
// in its place and the old library's destroy frees both what went and those
// leftovers. The caller then puts fresh where the old struct was.
//
// When the new library gives an input action another number, a value that
// holds actions converts, so each keeps its action by name.

Migration_Kind :: enum u8 {
    New,     // the old library has none: as the new one starts it
    Move,    // the same layout: its bytes
    Convert, // another layout: by the names of the fields; what cannot be converted starts at its default
}

World_Migration :: struct {
    from,to:^World_Info,
    places:bit_set[Place],         // whose layout differs
    tables:[]Migration_Kind,       // by table of to
    table_sources:[]int,           // by table of to: its table in from, or -1
    table_map:[]int,               // by table of from: its table in to, or -1
    storages:[]Migration_Kind,     // by storage of to
    storage_sources:[]int,
    from_schema,to_schema:serial.Schema, // of the storages converted
    from_names,to_names:[]serial.Choice, // the names of the @(names) types, which the schemas point into
    allocator:runtime.Allocator,
}

// What moving the structs of from into those of to does with each table and
// storage. False without memory.
world_migration_make :: proc(m:^World_Migration,from,to:^World_Info,allocator:=context.allocator) -> bool {
    m^={from=from,to=to,allocator=allocator}
    for place in Place {
        if place_layout_hash(from,place)!=place_layout_hash(to,place) {m.places+={place}}
    }
    serial.schema_init(&m.from_schema,allocator)
    serial.schema_init(&m.to_schema,allocator)
    ok:bool
    if m.from_names,ok=schema_named(&m.from_schema,from,allocator);!ok {return false}
    if m.to_names,ok=schema_named(&m.to_schema,to,allocator);!ok {return false}
    error:runtime.Allocator_Error
    if m.tables,error=make([]Migration_Kind,len(to.tables),allocator);error!=nil {return false}
    if m.table_sources,error=make([]int,len(to.tables),allocator);error!=nil {return false}
    if m.table_map,error=make([]int,len(from.tables),allocator);error!=nil {return false}
    if m.storages,error=make([]Migration_Kind,len(to.storages),allocator);error!=nil {return false}
    if m.storage_sources,error=make([]int,len(to.storages),allocator);error!=nil {return false}
    for &source in m.table_map {source=-1}
    renumbered:=names_renumbered(from,to)
    for &t,i in to.tables {
        m.table_sources[i]=-1
        for &old,j in from.tables {
            if old.name!=t.name || old.place!=t.place {continue}
            m.table_sources[i]=j
            m.table_map[j]=i
            m.tables[i]=layout_kept(m,old.info,t.info,renumbered)?.Move:.Convert
            if m.tables[i]==.Convert {m.places+={t.place}}
            break
        }
    }
    for &s,i in to.storages {
        m.storage_sources[i]=-1
        for &old,j in from.storages {
            if old.name!=s.name || old.place!=s.place || old.by_world!=s.by_world {continue}
            m.storage_sources[i]=j
            m.storages[i]=layout_kept(m,old.info,s.info,renumbered && !s.by_world)?.Move:.Convert
            if m.storages[i]==.Convert {m.places+={s.place}}
            break
        }
    }
    return true
}

// Whether a name of a type @(names,actions) of from has another number in to.
@(private="file")
names_renumbered :: proc(from,to:^World_Info) -> bool {
    for t in from.named_types {
        if !t.actions {continue}
        same:^Named_Type_Info
        for &other in to.named_types {
            if other.name==t.name && other.path==t.path {same=&other;break}
        }
        if same==nil {continue}
        for entry in names_of(from,t.type) {
            if value,found:=name_value(to,same.type,entry.name);found && value!=entry.value {return true}
        }
    }
    return false
}

// Whether values laid out by from stay as they are in to: the same layout
// and, with renumbered actions, no action inside.
@(private="file")
layout_kept :: proc(m:^World_Migration,from,to:^runtime.Type_Info,renumbered:bool) -> bool {
    if type_layout_hash(from)!=type_layout_hash(to) {return false}
    if !renumbered || !value_flat(from) || !value_flat(to) {return true}
    src,src_ok:=serial.schema_add_type_info(&m.from_schema,from)
    dst,dst_ok:=serial.schema_add_type_info(&m.to_schema,to)
    return !src_ok || !dst_ok || serial.schema_layout_hash(&m.from_schema,src)==serial.schema_layout_hash(&m.to_schema,dst)
}

world_migration_destroy :: proc(m:^World_Migration) {
    context.allocator=m.allocator
    delete(m.tables);delete(m.table_sources);delete(m.table_map);delete(m.storages);delete(m.storage_sources)
    delete(m.from_schema.named);delete(m.to_schema.named)
    delete(m.from_names);delete(m.to_names)
    serial.schema_destroy(&m.from_schema)
    serial.schema_destroy(&m.to_schema)
    m^={}
}

// Whether every table keeps its index: what holds tables by index (undo,
// reviews, readers of changes) holds the same ones.
world_migration_keeps_indices :: proc(m:^World_Migration) -> bool {
    for to,from in m.table_map {if to!=from {return false}}
    return len(m.from.tables)==len(m.to.tables)
}

// Moves the place of data, laid out by m.from, into fresh, initialized by
// m.to. data is left for world_destroy by m.from. Run after world_settle: no
// add waits. allocator is that of the World.
place_migrate :: proc(m:^World_Migration,place:Place,data,fresh:rawptr,allocator:runtime.Allocator) {
    context.allocator=allocator
    if place==.World {
        from,to:=cast(^Entities)(uintptr(data)+m.from.entities),cast(^Entities)(uintptr(fresh)+m.to.entities)
        slice.ptr_swap_non_overlapping(from,to,size_of(Entities))
        // What says which tables wait is by table of each World_Info: it stays with its World.
        from.pending,to.pending=to.pending,from.pending
    }
    locks_from,locks_to:=lock_names(m.from,place,data),lock_names(m.to,place,fresh)
    for &t,i in m.to.tables {
        if t.place!=place || m.tables[i]==.New {continue}
        old:=&m.from.tables[m.table_sources[i]]
        src,dst:=cast(^Raw_Table)(uintptr(data)+old.offset),cast(^Raw_Table)(uintptr(fresh)+t.offset)
        table_take(dst,src)
        for &owner in dst.owners {owner.id=lock_id_map(locks_from,locks_to,owner.id)}
        if m.tables[i]==.Convert {table_convert(m,old,&t,dst,src)}
    }
    for &s,i in m.to.storages {
        if s.place!=place || m.storages[i]==.New {continue}
        old:=&m.from.storages[m.storage_sources[i]]
        src,dst:=rawptr(uintptr(data)+old.offset),rawptr(uintptr(fresh)+s.offset)
        if s.by_world {
            // The value of each World goes with the map; one of another layout starts again.
            if m.storages[i]==.Move {slice.ptr_swap_non_overlapping(dst,src,size_of(Raw_By_World))}
            continue
        }
        if m.storages[i]==.Move {
            slice.ptr_swap_non_overlapping(dst,src,s.info.size)
            continue
        }
        storage_convert(m,old,&s,src,dst)
    }
}

// The by_world storages of to that m does not move: what attach gives a World for them.
by_world_new :: proc(m:^World_Migration,shared:rawptr,id:World_Id,allocator:runtime.Allocator) -> bool {
    if id.generation==0 {return true}
    for &s,i in m.to.storages {
        if !s.by_world || m.storages[i]==.Move {continue}
        b:=cast(^Raw_By_World)(uintptr(shared)+s.offset)
        if b.allocator.procedure==nil {b.allocator=allocator}
        if int(id.index)>=b.entries.len {
            entries:=transmute(^[dynamic]Raw_By_World_Entry)&b.entries
            entries.allocator=b.allocator
            if resize(entries,int(id.index)+1)!=nil {return false}
        }
        entry:=&(cast([^]Raw_By_World_Entry)b.entries.data)[id.index]
        if entry.value==nil {
            made,error:=mem.alloc(max(s.info.size,1),max(s.info.align,1),b.allocator)
            if error!=nil {return false}
            entry.value=made
        }
        // As attach gives it: a zero value.
        mem.zero(entry.value,s.info.size)
        entry.world=id
    }
    return true
}

@(private="file")
Raw_By_World :: struct {
    entries:runtime.Raw_Dynamic_Array,
    allocator:runtime.Allocator,
}

@(private="file")
Raw_By_World_Entry :: struct {
    world:World_Id,
    value:rawptr,
}

#assert(size_of(Raw_By_World)==size_of(By_World(u8)))
#assert(size_of(Raw_By_World_Entry)==size_of(By_World_Entry(u8)))

// The rows of src go to dst; dst keeps what makes it a table of its library
// (its name, its locks, whether it is base or single, where it says that it waits) and src takes the
// empty rows dst had.
@(private="file")
table_take :: proc(dst,src:^Raw_Table) {
    name,locks,is_base,single,waits:=dst.name,dst.locks,dst.base,dst.single,dst.waits
    old_name,old_locks,old_base,old_single,old_waits:=src.name,src.locks,src.base,src.single,src.waits
    // Through memory: a multiple assignment of values over 64 bytes (odin-lang/Odin#7937, ODIN_WORKAROUNDS).
    slice.ptr_swap_non_overlapping(dst,src,size_of(Raw_Table))
    dst.name,dst.locks,dst.base,dst.single,dst.waits=name,locks,is_base,single,waits
    src.name,src.locks,src.base,src.single,src.waits=old_name,old_locks,old_base,old_single,old_waits
    table_waits(dst,len(dst.pending)>0)
    table_waits(src,len(src.pending)>0)
}

// The values of the rows dst took, converted to its type. Those of another
// shape, and every one of a type that is not plain data, start at the default.
@(private="file")
table_convert :: proc(m:^World_Migration,from,to:^Table_Info,t,old_table:^Raw_Table) {
    // What waits to be added is of the old type: none does after a settle.
    t.added,old_table.added=old_table.added,t.added
    count:=t.values.len
    old:=t.values
    size,align:=to.info.size,to.info.align
    values:runtime.Raw_Dynamic_Array
    values.allocator=old.allocator
    if count>0 {
        if data,error:=mem.alloc(size*count,max(align,1),old.allocator);error==nil {values.data,values.len,values.cap=data,count,count}
    }
    if values.data!=nil {values_convert(m,from.info,to.info,to.default,(cast([^]u8)values.data)[:size*count],(cast([^]u8)old.data)[:from.info.size*count],count)}
    if values.data==nil && count>0 {
        // The rows cannot stay without values: they go, as with a table that is gone.
        clear(&t.entities);clear(&t.stamps);clear(&t.page_stamps);clear(&t.off);clear(&t.turns);clear(&t.owners)
        rows_zero(t)
        t.on=0
        t.version+=1
        t.layout+=1
    }
    // The old values go to the struct the old library destroys.
    t.values,old_table.values=values,old
}

// Values of the table index of m.to from count values of its table in
// m.from: what the history and the reviews hold of rows. nil without memory.
table_values_convert :: proc(m:^World_Migration,index:int,src:[]u8,count:int,allocator:=context.allocator) -> []u8 {
    to:=&m.to.tables[index]
    from:=&m.from.tables[m.table_sources[index]]
    out,error:=make([]u8,to.info.size*count,allocator)
    if error!=nil {return nil}
    if count>0 && len(src)>=from.info.size*count {values_convert(m,from.info,to.info,to.default,out,src,count)}
    return out
}

// Converts count values by the names of their fields; every value of a type
// that is not plain data, and every field that cannot convert, takes the default.
@(private="file")
values_convert :: proc(m:^World_Migration,from,to:^runtime.Type_Info,default_proc:proc(dst:rawptr),dst,src:[]u8,count:int) {
    size:=to.size
    default:=make([]u8,size,context.temp_allocator)
    if default_proc!=nil && size>0 {default_proc(raw_data(default))}
    converted:=false
    if value_flat(from) && value_flat(to) {
        src_type,src_ok:=serial.schema_add_type_info(&m.from_schema,from)
        dst_type,dst_ok:=serial.schema_add_type_info(&m.to_schema,to)
        if src_ok && dst_ok {
            migration:serial.Migration
            if serial.migration_init(&migration,&m.from_schema,src_type,&m.to_schema,dst_type,context.temp_allocator)==.None {
                serial.migration_apply(&migration,dst,src,count,default)
                converted=true
            }
            serial.migration_destroy(&migration)
        }
    }
    if !converted {
        for i in 0..<count {mem.copy(raw_data(dst[i*size:]),raw_data(default),size)}
    }
}

// A storage of another layout, by the names of its fields when both types
// are plain data; otherwise it keeps what the new library starts it with.
@(private="file")
storage_convert :: proc(m:^World_Migration,from,to:^Storage_Info,src,dst:rawptr) {
    if !value_flat(from.info) || !value_flat(to.info) {return}
    src_type,src_ok:=serial.schema_add_type_info(&m.from_schema,from.info)
    dst_type,dst_ok:=serial.schema_add_type_info(&m.to_schema,to.info)
    if !src_ok || !dst_ok {return}
    migration:serial.Migration
    defer serial.migration_destroy(&migration)
    if serial.migration_init(&migration,&m.from_schema,src_type,&m.to_schema,dst_type,context.temp_allocator)!=.None {return}
    default:=make([]u8,to.info.size,context.temp_allocator)
    mem.copy(raw_data(default),dst,to.info.size)
    serial.migration_apply(&migration,(cast([^]u8)dst)[:to.info.size],(cast([^]u8)src)[:from.info.size],1,default)
}

// The names of the locks of a place, by id: the components that hold them.
// Every table with locks names them all.
@(private="file")
lock_names :: proc(info:^World_Info,place:Place,data:rawptr) -> []string {
    for &t in info.tables {
        if t.place!=place {continue}
        if table:=cast(^Raw_Table)(uintptr(data)+t.offset);len(table.locks)>0 {return table.locks[0].names}
    }
    return nil
}

@(private="file")
lock_id_map :: proc(from,to:[]string,id:u16) -> u16 {
    if from==nil || to==nil || int(id)>=len(from) {return id}
    for name,i in to {if name==from[id] {return u16(i)}}
    return 0
}
