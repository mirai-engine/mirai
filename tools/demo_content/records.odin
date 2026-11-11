package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// Tables of game data (.records) of the demo: rows of a struct of
// demo/game with @(record), with the same ids every time, and the English
// of their texts with its Spanish translation.

Row_Out :: struct($T:typeid) {
    name:string,
    value:T,
}

// A text a row names: its English and, when there is one, its Spanish.
Text_Out :: struct {
    text:core.Text,
    en,es:string,
}

// What the ids of a table come from: its name, so they stay when its folder changes.
@(private)
records_name :: proc(file:string) -> string {return strings.trim_suffix(file[strings.last_index_byte(file,'/')+1:],".records")}

// The ids of rows and texts are below 2^53, as the editor makes them.
@(private)
record_id_of :: proc(file,name:string) -> u64 {return base.name_hash(fmt.tprintf("%s\x1frecords\x1f%s",records_name(file),name))&(1<<53-1)}

@(private)
records_table_of :: proc(file:string) -> base.Asset_Id {return asset.content_id(PROJECT,"records",records_name(file))}

// The row name of the table of file, as a field that names it.
record_ref :: proc($T:typeid,file,name:string) -> core.Record(T) {
    return {records_table_of(file),core.Record_Id(record_id_of(file,name))}
}

// A text of the table of file, by a name that is its own in that table.
record_text_of :: proc(file,name,en:string,es:="") -> Text_Out {
    return {core.Text{record_id_of(file,fmt.tprintf("text\x1f%s",name))},en,es}
}

// Writes demo/<file>.records: rows of type, which names the struct as
// "game.Name", with their texts.
write_records :: proc(o:^Out,file,type:string,$T:typeid,rows:[]Row_Out(T),texts:[]Text_Out) {
    index,ok:=asset.types_index(&o.content.types,T)
    if !ok {
        fmt.eprintfln("demo_content: %s: %v has no schema",file,typeid_of(T))
        o.content.failed=true
        return
    }
    ids:=make([]u64,len(rows),context.temp_allocator)
    names:=make([]asset.Records_Name,len(rows),context.temp_allocator)
    values:=make([]T,len(rows),context.temp_allocator)
    for row,i in rows {
        ids[i]=record_id_of(file,row.name)
        base.text_set(names[i][:],row.name)
        values[i]=row.value
    }
    entries:=make([dynamic]asset.Records_Text,context.temp_allocator)
    text:=strings.builder_make(context.temp_allocator)
    for t in texts {
        for language in ([2]string{"","es"}) {
            value:=t.en if language=="" else t.es
            if value=="" {continue}
            entry:=asset.Records_Text{text=t.text.id,offset=u32(strings.builder_len(text)),length=u32(len(value))}
            base.text_set(entry.language[:],language)
            strings.write_string(&text,value)
            append(&entries,entry)
        }
    }
    // A table keeps its texts ordered by id, then by language: "" before "es", as they were added.
    slice.stable_sort_by(entries[:],proc(a,b:asset.Records_Text) -> bool {return a.text<b.text})
    images:=make([]u8,len(rows)*size_of(T),context.temp_allocator)
    if layout:=asset.types_layout(&o.content.types,index);layout!=nil && len(rows)>0 {serial.value_write(layout,images,raw_data(values),len(rows))}
    desc:=asset.Records_Desc{
        id=records_table_of(file),type=type,ids=ids,names=names,
        schema=&o.content.types.schema,value_type=index,images=images,
        texts=entries[:],text=transmute([]u8)strings.to_string(text),
    }
    bytes,error:=asset.records_bytes(&o.content.types,desc,context.temp_allocator)
    if error==.None && os.write_entire_file(path(o,file),bytes)!=nil {error=.IO}
    asset.content_check(&o.content,file,error)
}
