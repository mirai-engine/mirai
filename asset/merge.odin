package asset

import "base:runtime"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// A three-way merge: what ours and theirs did to the document they both come
// from, base, put together into ours. Rows are matched as document_diff
// matches them, by their key or by the key of the row they refer to, and
// values field by field: a value one side left as base had it takes the one
// of the other side. What both sides changed apart, a row one side removed
// and the other changed or hung rows under, and a table matched whole (Bulk,
// or without keys and both changed) are conflicts: the merge keeps ours there
// and lists them. Without base, every difference is a conflict.

Merge_Kind :: enum u8 {
    Value,   // both sides changed a value apart
    Removed, // one side removed a row the other changed or refers to
    Table,   // a table matched whole changed on both sides
}

Merge_Conflict :: struct {
    kind:Merge_Kind,
    path:string,  // document_locate path of the value, the row or the table
    table:string,
    key:u64,      // the key of the row, or of the row it refers to, when it fits in 8 bytes
    ours,theirs:bool, // whether each side has the row
}

Merge :: struct {
    conflicts:[dynamic]Merge_Conflict,
}

merge_destroy :: proc(m:^Merge) {
    for conflict in m.conflicts {
        delete(conflict.path,m.conflicts.allocator)
        delete(conflict.table,m.conflicts.allocator)
    }
    delete(m.conflicts)
    m^={}
}

@(private="file") OURS :: 0
@(private="file") BASE :: 1
@(private="file") THEIRS :: 2

@(private="file")
Side :: struct {
    doc:^Document,
    table:int,       // -1: this side has no such table
    rows:int,
    data:[][]u8,     // per column of ours, its rows in the layout of ours; nil: the side lacks the column
    keys:[]string,   // per row, what identifies it; "" for none
    refs:[][]string, // per column of ours that indexes a table, per row the key of the row it indexes
}

@(private="file")
Out_Row :: struct {
    side:int, // OURS or THEIRS
    row:int,
    theirs,base:int, // of a row of ours: the same row on the other sides, or -1
    keep:bool,
}

@(private="file")
Table_Merge :: struct {
    sides:[3]Side,
    keyed:bool,
    added:bool, // ours did not have it before the merge
    rows:[dynamic]Out_Row,
}

@(private="file")
Merger :: struct {
    m:^Merge,
    docs:[3]^Document,
    scratch:runtime.Allocator,
    tables:[]Table_Merge,
    path:[dynamic]u8, // the fields under the column of the value being merged
    text:serial.Writer,
    exhausted:bool, // scratch had no memory for a step: the merge ends with Out_Of_Memory
}

// The value of a column of one row that merge_value is working on.
@(private="file")
Spot :: struct {table,row:int,column:string}

document_merge :: proc(m:^Merge,ours,origin,theirs:^Document) -> Error {
    if m.conflicts.allocator.procedure==nil {m.conflicts=make([dynamic]Merge_Conflict,ours.allocator)}
    arena:vmem.Arena
    if vmem.arena_init_growing(&arena)!=nil {return .Out_Of_Memory}
    defer vmem.arena_destroy(&arena)
    g:=Merger{m=m,docs={ours,origin,theirs},scratch=vmem.arena_allocator(&arena)}
    g.path=make([dynamic]u8,allocator=g.scratch)
    serial.writer_init(&g.text,allocator=g.scratch)
    first_added:=len(ours.tables)
    columns_follow(&g) or_return
    tables_add(&g) or_return
    no_tables:runtime.Allocator_Error
    if g.tables,no_tables=make([]Table_Merge,len(ours.tables),g.scratch);no_tables!=nil {return .Out_Of_Memory}
    for &table,at in g.tables {
        table.added=at>=first_added
        sides_read(&g,at) or_return
    }
    for _,at in g.tables {
        if !g.exhausted {rows_decide(&g,at)}
    }
    if !g.exhausted {references_keep(&g)}
    if g.exhausted {return .Out_Of_Memory}
    for _,at in g.tables {table_build(&g,at) or_return}
    references_write(&g)
    if !g.exhausted {rows_sort(&g)}
    if g.exhausted {return .Out_Of_Memory}
    // What the merge added for nothing, and single rows no side kept.
    for at:=len(ours.tables)-1;at>=0;at-=1 {
        kept:=0
        for out in g.tables[at].rows {if out.keep {kept+=1}}
        if kept==0 && (g.tables[at].added || .Single in ours.tables[at].flags) {document_table_remove(ours,at)}
    }
    return .None
}

// Replaces the table name of dst with the one of src, with its rows: the
// side a conflict over a whole table takes.
document_table_take :: proc(dst,src:^Document,name:string) -> Error {
    from,found:=document_table(src,name)
    if !found {return .Not_Found}
    if at,has:=document_table(dst,name);has {document_table_remove(dst,at)}
    source:=&src.tables[from]
    table:=document_table_add(dst,name,source.flags) or_return
    link:serial.Schema_Import
    document_import_begin(dst,&link,&src.schema)
    defer serial.schema_import_destroy(&link)
    if .Single not_in source.flags {document_resize(dst,table,source.rows) or_return}
    for &column in source.columns {
        type:=document_import(dst,&link,column.type)
        if type==serial.TYPE_NONE {return .Out_Of_Memory}
        added:=document_column_add(dst,table,column.name,type,column.flags,column.compression,column.alignment) or_return
        copy(dst.tables[table].columns[added].data,column.data)
        if column.ref>=0 {dst.tables[table].columns[added].ref,_=document_table(dst,src.tables[column.ref].name)}
    }
    dst.tables[table].key=source.key
    return .None
}

// A column whose type only theirs changed (a field added or removed: its component grew) takes
// the type of theirs, ours' rows moving to it by field names, so what theirs added is kept; base's
// rows then migrate to it as theirs' do. Where ours changed the type too, ours' stays.
@(private="file")
columns_follow :: proc(g:^Merger) -> Error {
    ours,base,theirs:=g.docs[OURS],g.docs[BASE],g.docs[THEIRS]
    if theirs==nil || base==nil {return .None}
    for at in 0..<len(ours.tables) {
        name:=ours.tables[at].name
        their_table,in_theirs:=document_table(theirs,name)
        base_table,in_base:=document_table(base,name)
        if !in_theirs || !in_base {continue}
        for c in 0..<len(ours.tables[at].columns) {
            column:=ours.tables[at].columns[c]
            if column.ref>=0 {continue}
            their_column,has_theirs:=document_column(theirs,their_table,column.name)
            base_column,has_base:=document_column(base,base_table,column.name)
            if !has_theirs || !has_base {continue}
            their_type:=theirs.tables[their_table].columns[their_column].type
            base_type:=base.tables[base_table].columns[base_column].type
            if theirs.hashes[their_type]==ours.hashes[column.type] || base.hashes[base_type]!=ours.hashes[column.type] {continue}
            document_column_retype(ours,at,c,&theirs.schema,their_type) or_return
        }
    }
    return .None
}

// Tables only theirs has go into ours, empty, so every table merges alike.
@(private="file")
tables_add :: proc(g:^Merger) -> Error {
    ours,theirs:=g.docs[OURS],g.docs[THEIRS]
    if theirs==nil {return .None}
    link:serial.Schema_Import
    document_import_begin(ours,&link,&theirs.schema)
    defer serial.schema_import_destroy(&link)
    first:=len(ours.tables)
    for &source in theirs.tables {
        if _,found:=document_table(ours,source.name);found {continue}
        table:=document_table_add(ours,source.name,source.flags) or_return
        for &column in source.columns {
            type:=document_import(ours,&link,column.type)
            if type==serial.TYPE_NONE {return .Out_Of_Memory}
            document_column_add(ours,table,column.name,type,column.flags,column.compression,column.alignment) or_return
        }
        ours.tables[table].key=source.key
    }
    for at in first..<len(ours.tables) {
        source,_:=document_table(theirs,ours.tables[at].name)
        for &column,c in ours.tables[at].columns {
            ref:=theirs.tables[source].columns[c].ref
            if ref>=0 {column.ref,_=document_table(ours,theirs.tables[ref].name)}
        }
    }
    return .None
}

@(private="file")
sides_read :: proc(g:^Merger,at:int) -> Error {
    ours:=g.docs[OURS]
    merge:=&g.tables[at]
    target:=&ours.tables[at]
    key_column,_:=identity_column(ours,at)
    merge.keyed=key_column>=0 || .Single in target.flags
    for &side,s in merge.sides {
        side.doc,side.table=g.docs[s],-1
        if side.doc!=nil {
            if s==OURS {side.table=at} else {side.table,_=document_table(side.doc,target.name)}
        }
        if side.table>=0 && !(s==OURS && merge.added) {side.rows=side.doc.tables[side.table].rows}
        no_data,no_refs,no_keys:runtime.Allocator_Error
        side.data,no_data=make([][]u8,len(target.columns),g.scratch)
        side.refs,no_refs=make([][]string,len(target.columns),g.scratch)
        side.keys,no_keys=make([]string,side.rows,g.scratch)
        if no_data!=nil || no_refs!=nil || no_keys!=nil {return .Out_Of_Memory}
        if side.rows==0 {continue}
        from:=&side.doc.tables[side.table]
        for &wanted,c in target.columns {
            // A column of rows that a side does not have refers to none there.
            if wanted.ref>=0 {
                no_column:runtime.Allocator_Error
                if side.refs[c],no_column=make([]string,side.rows,g.scratch);no_column!=nil {return .Out_Of_Memory}
            }
            found:=c
            if s!=OURS {
                found=-1
                for candidate,i in from.columns {
                    if candidate.name==wanted.name {found=i;break}
                }
            }
            if found<0 {continue}
            have:=&from.columns[found]
            if wanted.ref>=0 {
                if have.ref<0 {continue}
                for row in 0..<side.rows {
                    index:=int(index_load(have.data,row,have.size))
                    if index<side.doc.tables[have.ref].rows {side.refs[c][row]=strings.clone(string(identity(side.doc,have.ref,index)),g.scratch)}
                }
                continue
            }
            if s==OURS || side.doc.hashes[have.type]==ours.hashes[wanted.type] {
                side.data[c]=have.data
                continue
            }
            migrated,no_migrated:=make([]u8,side.rows*wanted.size,g.scratch)
            if no_migrated!=nil {return .Out_Of_Memory}
            migration:serial.Migration
            if serial.migration_init(&migration,&side.doc.schema,have.type,&ours.schema,wanted.type,g.scratch)!=.None {return .Invalid}
            serial.migration_apply(&migration,migrated,have.data,side.rows)
            side.data[c]=migrated
        }
        if key_column<0 || .Single in target.flags {continue}
        for row in 0..<side.rows {side.keys[row]=strings.clone(string(identity(side.doc,side.table,row)),g.scratch)}
    }
    return .None
}

@(private="file")
side_cell :: proc(side:^Side,column,row,size:int) -> []u8 {
    if side.data[column]==nil {return nil}
    return side.data[column][row*size:][:size]
}

// Whether two rows hold the same values, the rows they refer to included.
@(private="file")
rows_equal :: proc(g:^Merger,merge:^Table_Merge,a:int,row_a:int,b:int,row_b:int) -> bool {
    for &column,c in g.docs[OURS].tables[merge_index(g,merge)].columns {
        if column.ref>=0 {
            if merge.sides[a].refs[c][row_a]!=merge.sides[b].refs[c][row_b] {return false}
            continue
        }
        left,right:=side_cell(&merge.sides[a],c,row_a,column.size),side_cell(&merge.sides[b],c,row_b,column.size)
        if left==nil || right==nil {
            if left!=nil || right!=nil {return false}
            continue
        }
        if mem.compare(left,right)!=0 {return false}
    }
    return true
}

@(private="file")
merge_index :: proc(g:^Merger,merge:^Table_Merge) -> int {
    return int((uintptr(merge)-uintptr(raw_data(g.tables)))/size_of(Table_Merge))
}

@(private="file")
sides_same :: proc(g:^Merger,merge:^Table_Merge,a,b:int) -> bool {
    if merge.sides[a].rows!=merge.sides[b].rows {return false}
    for row in 0..<merge.sides[a].rows {
        if !rows_equal(g,merge,a,row,b,row) {return false}
    }
    return true
}

// The values of a row and the keys of the rows it refers to, as one text.
@(private="file")
row_signature :: proc(g:^Merger,merge:^Table_Merge,s:int,row:int) -> string {
    text:=make([dynamic]u8,allocator=g.scratch)
    for &column,c in g.docs[OURS].tables[merge_index(g,merge)].columns {
        if column.ref>=0 {
            append(&text,..transmute([]u8)merge.sides[s].refs[c][row])
        } else if cell:=side_cell(&merge.sides[s],c,row,column.size);cell!=nil {
            append(&text,..cell)
        }
        append(&text,0xff)
    }
    return string(text[:])
}

@(private="file")
keys_complete :: proc(side:^Side) -> bool {
    for key in side.keys {
        if key=="" {return false}
    }
    return true
}

@(private="file")
rows_decide :: proc(g:^Merger,at:int) {
    merge:=&g.tables[at]
    target:=&g.docs[OURS].tables[at]
    o,b,t:=&merge.sides[OURS],&merge.sides[BASE],&merge.sides[THEIRS]
    no_rows:runtime.Allocator_Error
    if merge.rows,no_rows=make([dynamic]Out_Row,0,o.rows+t.rows,g.scratch);no_rows!=nil {g.exhausted=true;return}
    single:=.Single in target.flags
    if .Bulk in target.flags {
        from:=OURS
        if !sides_same(g,merge,OURS,THEIRS) && !sides_same(g,merge,THEIRS,BASE) {
            if b.table>=0 && sides_same(g,merge,OURS,BASE) {from=THEIRS} else {conflict(g,.Table,g.docs[OURS],at,-1,true,true)}
        }
        for row in 0..<merge.sides[from].rows {append(&merge.rows,Out_Row{side=from,row=row,theirs=-1,base=-1,keep=true})}
        return
    }
    if merge.keyed && (single || keys_complete(o) && keys_complete(b) && keys_complete(t)) {
        base_rows,no_base:=make(map[string]int,b.rows,g.scratch)
        theirs_rows,no_theirs:=make(map[string]int,t.rows,g.scratch)
        matched,no_matched:=make([]bool,t.rows,g.scratch)
        if no_base!=nil || no_theirs!=nil || no_matched!=nil {g.exhausted=true;return}
        for key,row in b.keys {if !(key in base_rows) {base_rows[key]=row}}
        for key,row in t.keys {if !(key in theirs_rows) {theirs_rows[key]=row}}
        for key,row in o.keys {
            base_row,in_base:=base_rows[key]
            if !in_base {base_row=-1}
            if theirs_row,in_theirs:=theirs_rows[key];in_theirs && !matched[theirs_row] {
                matched[theirs_row]=true
                append(&merge.rows,Out_Row{side=OURS,row=row,theirs=theirs_row,base=base_row,keep=true})
                continue
            }
            keep:=true
            if in_base {
                // Theirs removed it: it goes, unless ours changed it.
                keep=!rows_equal(g,merge,OURS,row,BASE,base_row)
                if keep {conflict(g,.Removed,g.docs[OURS],at,row,true,false)}
            }
            append(&merge.rows,Out_Row{side=OURS,row=row,theirs=-1,base=-1,keep=keep})
        }
        for key,row in t.keys {
            if matched[row] {continue}
            if base_row,in_base:=base_rows[key];in_base {
                // Ours removed it: it stays removed, but what theirs changed in it is a conflict.
                if !rows_equal(g,merge,THEIRS,row,BASE,base_row) {conflict(g,.Removed,g.docs[THEIRS],t.table,row,false,true)}
                continue
            }
            append(&merge.rows,Out_Row{side=THEIRS,row=row,theirs=-1,base=-1,keep=true})
        }
        return
    }
    // Without keys rows are a set: each side adds and removes rows.
    in_base,no_base:=make(map[string]int,b.rows,g.scratch)
    in_theirs,no_theirs:=make(map[string]int,t.rows,g.scratch)
    shared,no_shared:=make(map[string]int,o.rows,g.scratch) // rows of theirs that ours also kept
    if no_base!=nil || no_theirs!=nil || no_shared!=nil {g.exhausted=true;return}
    for row in 0..<b.rows {in_base[row_signature(g,merge,BASE,row)]+=1}
    for row in 0..<t.rows {in_theirs[row_signature(g,merge,THEIRS,row)]+=1}
    for row in 0..<o.rows {
        signature:=row_signature(g,merge,OURS,row)
        keep:=true
        if in_theirs[signature]>shared[signature] {
            shared[signature]+=1
            if in_base[signature]>0 {in_base[signature]-=1}
        } else if in_base[signature]>0 {
            in_base[signature]-=1
            keep=false
        }
        append(&merge.rows,Out_Row{side=OURS,row=row,theirs=-1,base=-1,keep=keep})
    }
    for row in 0..<t.rows {
        signature:=row_signature(g,merge,THEIRS,row)
        if shared[signature]>0 {shared[signature]-=1;continue}
        if in_base[signature]>0 {in_base[signature]-=1;continue}
        append(&merge.rows,Out_Row{side=THEIRS,row=row,theirs=-1,base=-1,keep=true})
    }
}

// A row kept that refers to a row the merge removed: when the row is ours,
// what it refers to stays; when it came from theirs, it goes with it.
@(private="file")
references_keep :: proc(g:^Merger) {
    ours:=g.docs[OURS]
    kept,no_kept:=make([]map[string]int,len(g.tables),g.scratch)
    if no_kept!=nil {g.exhausted=true;return}
    for changed:=true;changed; {
        changed=false
        for &set in kept {set=nil}
        for &merge,at in g.tables {
            for &column,c in ours.tables[at].columns {
                if column.ref<0 || !g.tables[column.ref].keyed {continue}
                referred:=&g.tables[column.ref]
                if kept[column.ref]==nil {
                    no_set:runtime.Allocator_Error
                    if kept[column.ref],no_set=make(map[string]int,len(referred.rows),g.scratch);no_set!=nil {g.exhausted=true;return}
                    for out,i in referred.rows {
                        if out.keep {kept[column.ref][referred.sides[out.side].keys[out.row]]=i}
                    }
                }
                for &out in merge.rows {
                    if !out.keep {continue}
                    key:=merge.sides[out.side].refs[c][out.row]
                    if key=="" || key in kept[column.ref] {continue}
                    changed=true
                    if out.side==OURS {
                        for &other in referred.rows {
                            if other.side==OURS && referred.sides[OURS].keys[other.row]==key {
                                other.keep=true
                                conflict(g,.Removed,ours,column.ref,other.row,true,false)
                                break
                            }
                        }
                        rows_restore(g,column.ref,key)
                    } else {
                        out.keep=false
                        theirs:=&referred.sides[THEIRS]
                        for candidate,row in theirs.keys {
                            if candidate==key {conflict(g,.Removed,theirs.doc,theirs.table,row,false,true);break}
                        }
                    }
                }
                if changed {break}
            }
            if changed {break}
        }
    }
}

// What ours had under a row that stays after all: the rows of other tables
// that refer to it come back with it, as the components of an entity theirs
// removed and ours kept.
@(private="file")
rows_restore :: proc(g:^Merger,referred:int,key:string) {
    ours:=g.docs[OURS]
    for &merge,at in g.tables {
        for &column,c in ours.tables[at].columns {
            if column.ref!=referred {continue}
            for &out in merge.rows {
                if !out.keep && out.side==OURS && merge.sides[OURS].refs[c][out.row]==key {out.keep=true}
            }
        }
    }
}

@(private="file")
table_build :: proc(g:^Merger,at:int) -> Error {
    ours:=g.docs[OURS]
    merge:=&g.tables[at]
    target:=&ours.tables[at]
    kept:=0
    for out in merge.rows {if out.keep {kept+=1}}
    if kept==0 && .Single in target.flags {return .None}
    fresh,no_fresh:=make([]Doc_Column,len(target.columns),g.scratch)
    if no_fresh!=nil {return .Out_Of_Memory}
    for &column,c in target.columns {
        fresh[c]=column
        fresh[c].data,fresh[c].capacity=nil,0
        if error:=column_size(ours,&fresh[c],kept*column.size);error!=.None {
            for &done in fresh[:c] {mem.free_bytes(raw_data(done.data)[:done.capacity],ours.allocator)}
            return error
        }
    }
    i:=0
    for out in merge.rows {
        if !out.keep {continue}
        side:=&merge.sides[out.side]
        for &column,c in target.columns {
            if column.size==0 {continue}
            cell:=fresh[c].data[i*column.size:][:column.size]
            if column.ref>=0 {
                // Ours keeps its index until references_write finds the row by its key.
                if out.side==OURS && !merge.added {copy(cell,column.data[out.row*column.size:][:column.size])}
                continue
            }
            source:=side_cell(side,c,out.row,column.size)
            if source!=nil {copy(cell,source)}
            if out.side!=OURS || out.theirs<0 || source==nil {continue}
            theirs:=side_cell(&merge.sides[THEIRS],c,out.theirs,column.size)
            if theirs==nil {continue}
            origin:[]u8
            if out.base>=0 {origin=side_cell(&merge.sides[BASE],c,out.base,column.size)}
            clear(&g.path)
            merge_value(g,Spot{at,out.row,column.name},column.type,origin,source,theirs,cell)
        }
        i+=1
    }
    for &column,c in target.columns {
        mem.free_bytes(raw_data(column.data)[:column.capacity],ours.allocator)
        column=fresh[c]
    }
    if .Single not_in target.flags {target.rows=kept}
    return .None
}

@(private="file")
merge_value :: proc(g:^Merger,spot:Spot,type:serial.Type_Index,origin,ours,theirs,out:[]u8) {
    if mem.compare(ours,theirs)==0 {return}
    if origin!=nil && mem.compare(origin,ours)==0 {copy(out,theirs);return}
    if origin!=nil && mem.compare(origin,theirs)==0 {return}
    schema:=&g.docs[OURS].schema
    kind:=schema.types[type]
    if kind.kind!=.Struct {
        conflict(g,.Value,g.docs[OURS],spot.table,spot.row,true,true,spot.column)
        return
    }
    part :: proc(bytes:[]u8,offset,size:int) -> []u8 {return bytes==nil?nil:bytes[offset:][:size]}
    length:=len(g.path)
    defer base.truncate(&g.path,length)
    for &field in schema.fields[kind.first:][:kind.count] {
        if .Transient in field.flags {continue}
        base.truncate(&g.path,length)
        append(&g.path,'.');append(&g.path,field.name)
        offset,size:=int(field.offset),int(schema.types[field.type].size)
        merge_value(g,spot,field.type,part(origin,offset,size),ours[offset:][:size],theirs[offset:][:size],out[offset:][:size])
    }
}

// Every column that indexes a table indexes the row of the merge with the key
// it named.
@(private="file")
references_write :: proc(g:^Merger) {
    ours:=g.docs[OURS]
    rows,no_rows:=make([]map[string]int,len(ours.tables),g.scratch)
    if no_rows!=nil {g.exhausted=true;return}
    for &merge,at in g.tables {
        target:=&ours.tables[at]
        for &column,c in target.columns {
            if column.ref<0 || column.size==0 {continue}
            referred:=column.ref
            if !g.tables[referred].keyed || .Single in ours.tables[referred].flags {continue}
            if rows[referred]==nil {
                no_set:runtime.Allocator_Error
                if rows[referred],no_set=make(map[string]int,ours.tables[referred].rows,g.scratch);no_set!=nil {g.exhausted=true;return}
                for row in 0..<ours.tables[referred].rows {rows[referred][string(identity(ours,referred,row))]=row}
            }
            i:=0
            for out in merge.rows {
                if !out.keep {continue}
                if row,found:=rows[referred][merge.sides[out.side].refs[c][out.row]];found {index_store(column.data,i,column.size,u64(row))}
                i+=1
            }
        }
    }
}

// Rows identified by the row they refer to go in the order of what they refer
// to, as the rows of the components of a scene follow its entities.
@(private="file")
rows_sort :: proc(g:^Merger) {
    ours:=g.docs[OURS]
    Order :: struct {index:u64,row:int}
    for at in 0..<len(ours.tables) {
        column,through:=identity_column(ours,at)
        target:=&ours.tables[at]
        if through<0 || target.rows<2 {continue}
        refs:=&target.columns[column]
        order,no_order:=make([]Order,target.rows,g.scratch)
        if no_order!=nil {g.exhausted=true;return}
        sorted:=true
        for &entry,row in order {
            entry={index_load(refs.data,row,refs.size),row}
            if row>0 && order[row-1].index>entry.index {sorted=false}
        }
        if sorted {continue}
        slice.stable_sort_by(order,proc(a,b:Order) -> bool {return a.index<b.index})
        for &each in target.columns {
            if each.size==0 {continue}
            copied,no_copied:=make([]u8,len(each.data),g.scratch)
            if no_copied!=nil {g.exhausted=true;return}
            copy(copied,each.data)
            for entry,row in order {copy(each.data[row*each.size:][:each.size],copied[entry.row*each.size:][:each.size])}
        }
    }
}

@(private="file")
conflict :: proc(g:^Merger,kind:Merge_Kind,doc:^Document,table,row:int,ours,theirs:bool,column:="") {
    serial.writer_reset(&g.text)
    if kind==.Value {
        if column!="" {serial.write_u8(&g.text,'.');serial.text_write_raw(&g.text,column)}
        serial.write_bytes(&g.text,g.path[:])
    }
    merge_conflict_add(g.m,kind,doc,table,row,ours,theirs,string(serial.writer_bytes(&g.text)))
}

// Lists a conflict once: the row of a table of doc, the table when row is
// -1, and field the column and fields under the row (".value.position").
@(private)
merge_conflict_add :: proc(m:^Merge,kind:Merge_Kind,doc:^Document,table,row:int,ours,theirs:bool,field:="") {
    text:serial.Writer
    serial.writer_init(&text,allocator=context.temp_allocator)
    target:=&doc.tables[table]
    serial.text_write_raw(&text,target.name)
    key:u64
    if row>=0 && .Single not_in target.flags {
        serial.write_u8(&text,'[')
        row_identity(doc,table,row,&text)
        serial.write_u8(&text,']')
        if bytes:=identity(doc,table,row);len(bytes)>0 && len(bytes)<=8 {mem.copy(&key,raw_data(bytes),len(bytes))}
    }
    serial.text_write_raw(&text,field)
    path:=string(serial.writer_bytes(&text))
    for known in m.conflicts {
        if known.kind==kind && known.path==path {return}
    }
    allocator:=m.conflicts.allocator
    append(&m.conflicts,Merge_Conflict{kind=kind,path=strings.clone(path,allocator),table=strings.clone(target.name,allocator),key=key,ours=ours,theirs=theirs})
}
