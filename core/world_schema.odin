package core

import "base:runtime"
import "core:slice"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// How the values of the components and of the scene settings of a world are
// saved and read: what scenes and saved games go through. The World_Info of a
// generated world holds one, made once by world_info_index.
World_Schema :: struct {
    schema:serial.Schema,
    choices:[]serial.Choice, // the names of the @(names) types, which schema.named points into
    tables:[]Value_Schema,   // by table of the World_Info
    storages:[]Value_Schema, // by storage: the persist ones; the others have TYPE_NONE
    records:[]Value_Schema,  // by record type of the World_Info
    table_hashes:[]Table_Hash, // sorted by hash: world_table_index_of_hash
    allocator:runtime.Allocator,
}

Table_Hash :: struct {
    hash:u64, // base.name_hash of the name of the table
    table:int,
}

Value_Schema :: struct {
    type:serial.Type_Index, // TYPE_NONE: not plain data
    hash:u64,               // of its layout: a value stored with another migrates by field names
    layout:serial.Layout,   // the bytes of a value that are saved: no transient field
    entities:[]u32,         // offsets of its Entity fields
}

// Completes the World_Info that the generated world returns: its tables and
// storages by type, and the schema of their values. A World_Info without
// them, made by hand, is searched through its lists and has no schema.
world_info_index :: proc(info:^World_Info,allocator:=context.allocator) {
    info.schema=world_schema_make(info,allocator)
    info.settles=settle_info(info)
    for &t in info.tables {t.flat=value_flat(t.info)}
    for &s in info.storages {s.flat=value_flat(s.info)}
    wanted:=0
    for s in info.storages {if !s.by_world {wanted+=1}}
    tables,tables_error:=make_map_cap(map[typeid]int,len(info.tables),allocator)
    storages,storages_error:=make_map_cap(map[typeid]int,wanted,allocator)
    if tables_error==nil && storages_error==nil {
        for t,i in info.tables {tables[t.type]=i}
        for s,i in info.storages {if !s.by_world {storages[s.type]=i}}
    }
    // Every type or none: a lookup that misses one would say the world lacks it.
    if tables_error!=nil || storages_error!=nil || len(tables)!=len(info.tables) || len(storages)!=wanted {
        delete(tables);delete(storages)
        return
    }
    info.tables_by_type,info.storages_by_type=tables,storages
}

// The schema of the tables and of the persist storages of a world; nil
// without memory.
world_schema_make :: proc(info:^World_Info,allocator:=context.allocator) -> ^World_Schema {
    ws,error:=new(World_Schema,allocator)
    if error!=nil {return nil}
    ws.allocator=allocator
    serial.schema_init(&ws.schema,allocator)
    if !world_schema_names(ws,info) {
        world_schema_destroy(ws)
        return nil
    }
    tables_error,storages_error,records_error,hashes_error:runtime.Allocator_Error
    ws.tables,tables_error=make([]Value_Schema,len(info.tables),allocator)
    ws.storages,storages_error=make([]Value_Schema,len(info.storages),allocator)
    ws.records,records_error=make([]Value_Schema,len(info.records),allocator)
    names:=len(info.tables)
    for t in info.tables {
        rest:=t.was
        for _ in strings.fields_iterator(&rest) {names+=1}
    }
    ws.table_hashes,hashes_error=make([]Table_Hash,names,allocator)
    if tables_error!=nil || storages_error!=nil || records_error!=nil || hashes_error!=nil {
        world_schema_destroy(ws)
        return nil
    }
    // A table is found by its name and by every name it had (@(component,was=)).
    names=len(info.tables)
    for t,i in info.tables {
        ws.table_hashes[i]={base.name_hash(t.name),i}
        rest:=t.was
        for name in strings.fields_iterator(&rest) {
            ws.table_hashes[names]={base.name_hash(name),i}
            names+=1
        }
    }
    slice.sort_by(ws.table_hashes,proc(a,b:Table_Hash) -> bool {return a.hash<b.hash || a.hash==b.hash && a.table<b.table})
    for t,i in info.tables {
        if !value_schema(ws,&ws.tables[i],t.info) {
            world_schema_destroy(ws)
            return nil
        }
        // Files written with the type carry the names it had, for a reader without this world.
        if type:=ws.tables[i].type;t.was!="" && type!=serial.TYPE_NONE {
            was,no_was:=strings.clone(t.was,ws.schema.allocator)
            if no_was!=nil {
                world_schema_destroy(ws)
                return nil
            }
            ws.schema.types[type].was=was
        }
    }
    for s,i in info.storages {
        ws.storages[i].type=serial.TYPE_NONE
        if s.persist && !value_schema(ws,&ws.storages[i],s.info) {
            world_schema_destroy(ws)
            return nil
        }
    }
    for r,i in info.records {
        if !value_schema(ws,&ws.records[i],r.info) {
            world_schema_destroy(ws)
            return nil
        }
    }
    return ws
}

// The schema of a world and the type in it of one of its values: of a table,
// a persist storage or a record, or of what they hold. ok is false for another.
world_value_type :: proc(info:^World_Info,type:typeid) -> (s:^serial.Schema,index:serial.Type_Index,ok:bool) {
    if info==nil || info.schema==nil {return}
    index,ok=info.schema.schema.lookup[type]
    return &info.schema.schema,index,ok
}

// The index in w.info.tables of the table of the place of w whose name has
// the hash a document names it by (base.name_hash).
world_table_index_of_hash :: proc(w:World_Ref,hash:u64) -> (int,bool) {
    if ws:=w.info.schema;ws!=nil {
        lo,hi:=0,len(ws.table_hashes)
        for lo<hi {
            mid:=(lo+hi)/2
            if ws.table_hashes[mid].hash<hash {lo=mid+1} else {hi=mid}
        }
        for at in lo..<len(ws.table_hashes) {
            entry:=ws.table_hashes[at]
            if entry.hash!=hash {break}
            if w.info.tables[entry.table].place==w.place {return entry.table,true}
        }
        return -1,false
    }
    for &t,at in w.info.tables {
        if t.place!=w.place {continue}
        if base.name_hash(t.name)==hash {return at,true}
        rest:=t.was
        for name in strings.fields_iterator(&rest) {
            if base.name_hash(name)==hash {return at,true}
        }
    }
    return -1,false
}

@(private="file")
world_schema_names :: proc(ws:^World_Schema,info:^World_Info) -> (ok:bool) {
    ws.choices,ok=schema_named(&ws.schema,info,ws.allocator)
    return
}

// Gives a schema the names of the types @(names) of a world and of the masks
// of their values, for it to read and write them by name before its types
// are added. choices holds them: whoever destroys the schema deletes it and
// the map named.
schema_named :: proc(s:^serial.Schema,info:^World_Info,allocator:=context.allocator) -> (choices:[]serial.Choice,ok:bool) {
    error:runtime.Allocator_Error
    choices,error=make([]serial.Choice,len(info.names),allocator)
    if error!=nil {return}
    s.named=make(map[typeid]serial.Named,allocator)
    for entry,i in info.names {choices[i]={entry.name,entry.value}}
    for i:=0;i<len(info.names); {
        type:=info.names[i].type
        end:=i
        for end<len(info.names) && info.names[end].type==type {end+=1}
        t:=named_type_of(info,type)
        s.named[type]={choices=choices[i:end],by_name=t!=nil && t.actions}
        i=end
    }
    for mask in info.name_bits {
        if values,found:=s.named[mask.of];found {s.named[mask.type]={choices=values.choices,bits=true,by_name=values.by_name}}
    }
    return choices,true
}

world_schema_destroy :: proc(ws:^World_Schema) {
    if ws==nil {return}
    allocator:=ws.allocator
    for &v in ws.tables {value_schema_destroy(&v,allocator)}
    for &v in ws.storages {value_schema_destroy(&v,allocator)}
    for &v in ws.records {value_schema_destroy(&v,allocator)}
    delete(ws.tables,allocator);delete(ws.storages,allocator);delete(ws.records,allocator)
    delete(ws.table_hashes,allocator)
    delete(ws.choices,allocator);delete(ws.schema.named)
    serial.schema_destroy(&ws.schema)
    _=runtime.mem_free(ws,allocator)
}

// False without memory; a type that is not plain data is TYPE_NONE.
@(private="file")
value_schema :: proc(ws:^World_Schema,v:^Value_Schema,info:^runtime.Type_Info) -> bool {
    v.type=serial.TYPE_NONE
    index,ok:=serial.schema_add_type_info(&ws.schema,info)
    if !ok {return true}
    v.type=index
    v.hash=serial.schema_layout_hash(&ws.schema,index)
    serial.layout_init(&v.layout,&ws.schema,index,ws.allocator)
    offsets:=make([dynamic]u32,ws.allocator)
    if !entity_offsets(&ws.schema,index,0,&offsets) {
        delete(offsets)
        return false
    }
    v.entities=offsets[:]
    return true
}

@(private="file")
value_schema_destroy :: proc(v:^Value_Schema,allocator:runtime.Allocator) {
    serial.layout_destroy(&v.layout)
    delete(v.entities,allocator)
}

@(private="file")
entity_offsets :: proc(s:^serial.Schema,index:serial.Type_Index,offset:u32,out:^[dynamic]u32) -> bool {
    type:=s.types[index]
    #partial switch type.kind {
    case .Entity:
        if _,error:=append(out,offset);error!=nil {return false}
    case .Array:
        stride:=s.types[type.elem].size
        for i in 0..<type.count {entity_offsets(s,type.elem,offset+i*stride,out) or_return}
    case .Struct:
        for field in s.fields[type.first:][:type.count] {entity_offsets(s,field.type,offset+field.offset,out) or_return}
    }
    return true
}
