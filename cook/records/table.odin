package records

import "core:fmt"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// A whole table as mirai records and a content tool write it: rows by name,
// in order, each with the values of its fields as JSON.

// Gives e these rows and no others, in their order: each starts at the
// defaults of the columns and takes its values (values_put, as records.set);
// a row keeps the id it had by its name and a new one takes the id its name
// makes (id_of_name), the same on every run. c: what the values are read
// against (context_make of e). message says which row is refused, and why;
// e is then left with the rows it had.
rows_replace :: proc(e:^Edit,c:^Context,names,values:[]string) -> (message:string) {
    size:=row_size(e)
    old_ids:=slice.clone(e.ids[:],context.temp_allocator)
    old_names:=slice.clone(e.names[:],context.temp_allocator)
    old_values:=slice.clone(e.values,context.temp_allocator)
    made:=make([]u8,len(names)*size,context.temp_allocator)
    ids:=make([]u64,len(names),context.temp_allocator)
    for name,i in names {
        if !asset.records_name_valid(name) || len(name)>=asset.RECORDS_NAME {return fmt.tprintf("%q is not a name of a row: a word of ASCII letters, digits and _, shorter than %d bytes",name,asset.RECORDS_NAME)}
        for other in names[:i] {
            if other==name {return fmt.tprintf("two rows are named %s: give one another name",name)}
        }
        for &n,at in old_names {
            if serial.text_field(n[:])==name {ids[i]=old_ids[at]}
        }
    }
    for name,i in names {
        if ids[i]==0 {ids[i]=id_of_name(name,ids)}
        row:=made[i*size:][:size]
        copy(row,e.defaults)
        if message=values_put(c,row,values[i]);message!="" {return fmt.tprintf("row %s: %s",name,message)}
    }
    clear(&e.ids);clear(&e.names)
    e.values=e.values[:0]
    for name,i in names {
        if !row_put(e,ids[i],name,made[i*size:][:size]) {
            clear(&e.ids);clear(&e.names)
            append(&e.ids,..old_ids)
            append(&e.names,..old_names)
            e.values=e.values[:len(old_values)]
            copy(e.values,old_values)
            return "out of memory"
        }
    }
    return ""
}

// A new table at file (path under the assets) that holds rows of a type
// another table declares, with no rows. message: why not.
rows_of_make :: proc(registry:^asset.Registry,types:^asset.Types,info:^core.World_Info,type:string,id:base.Asset_Id,file,path:string,e:^Edit,allocator:=context.allocator) -> (message:string) {
    declaring,_:=declaring_find(registry,types,type)
    if declaring=={} {return fmt.tprintf("no .records declares %s: mirai records create makes one, records.types lists those there are",type)}
    if message=load(registry,types,info,declaring,e,allocator);message!="" {return}
    delete(e.file,e.allocator);delete(e.folder,e.allocator)
    e.id,e.declaring=id,declaring
    e.file=fmt.aprintf("%s",file,allocator=e.allocator)
    e.folder=fmt.aprintf("%s",folder_of(path),allocator=e.allocator)
    e.info.declares=false
    e.info.description={}
    clear(&e.ids);clear(&e.names)
    e.values=e.values[:0]
    return ""
}
