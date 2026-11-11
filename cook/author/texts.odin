package author

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The texts of a project as a tool edits them: every .strings of its assets
// as one table of keys, the rows of the CSV translators take. The game reads
// the same files the same way (host.app_texts): a key is in one file, and
// the first language of a file is the one its texts are written in, which a
// key shows in a language that lacks it. Everything lives in the temporary
// allocator: a command or a call reads them, changes them and writes the
// files that changed.
Texts :: struct {
    languages:[dynamic]string, // codes; the first: the one the texts are written in (UI_Settings.source)
    rows:[dynamic]Texts_Row,
    files:[dynamic]Texts_File,
    problems:[dynamic]string, // a .strings that does not load; a key two files have
}
Texts_Row :: struct {
    key:string,
    file:int,
    cells:[dynamic]string, // by languages; "": none
}
Texts_File :: struct {
    id:base.Asset_Id, // zero: not written yet
    path:string,      // as the registry names it
    imported:bool,    // made from a CSV: it changes there
    changed:bool,
}

// Where a key no .strings has goes.
TEXTS_HOME :: "texts.strings"
// How long the key made from a text gets before its number.
TEXTS_KEY_WORDS :: 40

@(private="file")
texts_language :: proc(t:^Texts,code:string) -> int {
    for known,i in t.languages {if known==code {return i}}
    append(&t.languages,strings.clone(code,context.temp_allocator))
    return len(t.languages)-1
}

@(private="file")
texts_cell :: proc(row:^Texts_Row,language:int) -> ^string {
    for len(row.cells)<=language {append(&row.cells,"")}
    return &row.cells[language]
}

texts_row :: proc(t:^Texts,key:string) -> ^Texts_Row {
    for &row in t.rows {if row.key==key {return &row}}
    return nil
}

// What a key says in a language; "" where it says nothing.
texts_text :: proc(t:^Texts,key,code:string) -> string {
    row:=texts_row(t,key)
    for known,i in t.languages {if row!=nil && known==code && i<len(row.cells) {return row.cells[i]}}
    return ""
}

// The texts of the assets, unsaved changes included. source: the code of the
// language they are written in.
texts_read :: proc(a:Assets,source:string) -> (t:Texts) {
    context.allocator=context.temp_allocator
    texts_language(&t,source)
    if a.registry==nil {return}
    for &record in a.registry.files {
        if record.kind!=asset.KIND_STRINGS || record.id=={} {continue}
        file:asset.Asset
        view:asset.Strings_View
        bytes,read:=asset.registry_read(a.registry,record.path)
        loaded:=read==.None && asset.asset_take(&file,bytes)==.None
        if loaded {
            error:asset.Error
            view,error=asset.strings_view(&file,a.types)
            loaded=error==.None
        }
        if !loaded {
            append(&t.problems,fmt.tprintf("%s does not load, so the game has none of its texts: mirai asset verify says why",record.path))
            continue
        }
        append(&t.files,Texts_File{id=record.id,path=record.path,imported=view.source!=nil})
        rows:=make([]int,len(view.keys))
        for &key,i in view.keys {
            name:=strings.clone(serial.text_field(key.name[:]))
            if earlier:=texts_row(&t,name);earlier!=nil {
                rows[i]=-1
                append(&t.problems,fmt.tprintf("the key %s is in %s and in %s, and the game reads the first: take it out of one",name,t.files[earlier.file].path,record.path))
                continue
            }
            rows[i]=len(t.rows)
            append(&t.rows,Texts_Row{key=name,file=len(t.files)-1})
        }
        for e in view.entries {
            if rows[e.key]<0 {continue}
            language:=texts_language(&t,serial.text_field(view.languages[e.language].code[:]))
            texts_cell(&t.rows[rows[e.key]],language)^=strings.clone(string(view.text[e.offset:][:e.length]))
        }
    }
    return
}

// Makes a key say a text in a language, by its code. A key no .strings has
// is added to TEXTS_HOME; an empty text takes away what it said, and a key
// that says nothing is not written. problem: what keeps it from it.
texts_set :: proc(t:^Texts,key,code,text:string) -> (problem:string) {
    context.allocator=context.temp_allocator
    if !texts_code(code) {return fmt.tprintf("'%s' is no code of a language: two or three lowercase letters, then a region or a script after '-' if any (pl, pt-BR, es-419), up to %d bytes",code,len(asset.String_Language{}.code)-1)}
    if key=="" || len(key)>=len(asset.String_Key{}.name) {return fmt.tprintf("a key is a name shorter than %d bytes, and '%s' is not",len(asset.String_Key{}.name),key)}
    row:=texts_row(t,key)
    if row==nil {
        home:=-1
        for &file,i in t.files {if file.path==TEXTS_HOME {home=i}}
        if home<0 {
            append(&t.files,Texts_File{path=TEXTS_HOME})
            home=len(t.files)-1
        }
        append(&t.rows,Texts_Row{key=strings.clone(key),file=home})
        row=&t.rows[len(t.rows)-1]
    }
    file:=&t.files[row.file]
    cell:=texts_cell(row,texts_language(t,code))
    if cell^==text {return ""}
    if file.imported {return fmt.tprintf("the key %s is in %s, which is imported: change its CSV and import it again",key,file.path)}
    cell^=strings.clone(text)
    file.changed=true
    return ""
}

// The key a text takes when whoever writes it gives none: its ASCII letters
// and digits in lowercase, each run of anything else a _, cut at the last
// word that ends within TEXTS_KEY_WORDS. The key of that name that already
// says this text in the language texts are written in is shared; one that
// says another leaves the name to the next number: start, start_2, start_3.
texts_key :: proc(t:^Texts,text:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    whole:=0 // the bytes of the words that ended
    for c in transmute([]u8)text {
        switch c {
        case 'a'..='z','0'..='9': strings.write_byte(&b,c)
        case 'A'..='Z':           strings.write_byte(&b,c+('a'-'A'))
        case:
            if n:=strings.builder_len(b);n>0 && b.buf[n-1]!='_' {
                whole=n
                strings.write_byte(&b,'_')
            }
        }
        if strings.builder_len(b)>TEXTS_KEY_WORDS {break}
    }
    name:=strings.trim_right(strings.to_string(b),"_")
    if len(name)>TEXTS_KEY_WORDS {name=name[:whole if whole>0 else TEXTS_KEY_WORDS]}
    if name=="" {name="text"}
    for n:=1;;n+=1 {
        key:=name if n==1 else fmt.tprintf("%s_%d",name,n)
        if row:=texts_row(t,key);row==nil || len(row.cells)>0 && row.cells[0]==text {return key}
    }
}

// A .strings a change touched, as the file it is now.
Texts_Written :: struct {
    path:string, // as the registry names it
    bytes:[]u8,
}

// The files the changes touched: their keys in order, the language texts
// are written in first. fresh: the id TEXTS_HOME takes when it is made now.
texts_written :: proc(t:^Texts,types:^asset.Types,fresh:base.Asset_Id) -> (written:[]Texts_Written,problem:string) {
    context.allocator=context.temp_allocator
    out:=make([dynamic]Texts_Written)
    for &file,at in t.files {
        if !file.changed {continue}
        rows:=make([dynamic]^Texts_Row)
        said:=make([]bool,len(t.languages)) // a key of the file says something in that language
        said[0]=true
        for &row in t.rows {
            any:=false
            for cell,language in row.cells {
                if row.file==at && cell!="" {said[language],any=true,true}
            }
            if any {append(&rows,&row)}
        }
        slice.sort_by(rows[:],proc(a,b:^Texts_Row) -> bool {return a.key<b.key})
        desc:=asset.Strings_Desc{id=file.id if file.id!={} else fresh}
        languages:=make([dynamic]asset.String_Language)
        columns:=make([]u32,len(t.languages)) // of each language: its row in the file
        for code,language in t.languages {
            if !said[language] {continue}
            columns[language]=u32(len(languages))
            append(&languages,asset.String_Language{})
            base.text_set(languages[columns[language]].code[:],code)
        }
        keys:=make([]asset.String_Key,len(rows))
        entries:=make([dynamic]asset.String_Entry)
        text:=make([dynamic]u8)
        for row,key in rows {
            base.text_set(keys[key].name[:],row.key)
            for cell,language in row.cells {
                if cell=="" {continue}
                append(&entries,asset.String_Entry{key=u32(key),language=columns[language],offset=u32(len(text)),length=u32(len(cell))})
                append(&text,cell)
            }
        }
        desc.languages,desc.keys,desc.entries,desc.text=languages[:],keys,entries[:],text[:]
        bytes,error:=asset.strings_bytes(types,desc)
        if error!=.None {return nil,fmt.tprintf("%s could not be written: %v",file.path,error)}
        append(&out,Texts_Written{file.path,bytes})
    }
    return out[:],""
}

// Every text as the CSV translators take and cook/import reads: key and a
// column for each language by its code, the one texts are written in first.
texts_csv :: proc(t:^Texts) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"key")
    for code in t.languages {strings.write_byte(&b,',');strings.write_string(&b,code)}
    strings.write_byte(&b,'\n')
    rows:=slice.clone(t.rows[:],context.temp_allocator)
    slice.sort_by(rows,proc(a,b:Texts_Row) -> bool {return a.key<b.key})
    for &row in rows {
        importer.csv_cell(&b,row.key)
        for _,language in t.languages {
            strings.write_byte(&b,',')
            importer.csv_cell(&b,row.cells[language] if language<len(row.cells) else "")
        }
        strings.write_byte(&b,'\n')
    }
    return strings.to_string(b)
}

// Makes the keys of a CSV, read as cook/import reads it, say its texts: an
// empty cell changes nothing. set: how many texts it gave. With a problem,
// which names the line, the texts are not to be written.
texts_csv_take :: proc(t:^Texts,csv:string) -> (set:int,problem:string) {
    table,message:=importer.strings_table(csv,context.temp_allocator)
    if message!="" {return 0,message}
    for e in table.entries {
        key:=serial.text_field(table.keys[e.key].name[:])
        problem=texts_set(t,key,serial.text_field(table.languages[e.language].code[:]),string(table.text[e.offset:][:e.length]))
        if problem!="" {return}
        set+=1
    }
    return
}

// Who shows a key: a node of a .ui, by its path in the tree, or a core.Text
// field of a row of a .records.
Texts_Use :: struct {document,asker,key:string}

// Every key the interfaces and the tables of game data of the assets show.
texts_uses :: proc(a:Assets) -> []Texts_Use {
    context.allocator=context.temp_allocator
    uses:=make([dynamic]Texts_Use)
    if a.registry==nil {return nil}
    for &record in a.registry.files {
        switch record.kind {
        case asset.KIND_UI:
            records:Records
            if !records_read(a,record.id,&records,context.temp_allocator) {continue}
            data:=records_data(&records)
            imports,imported:=host.ui_tree_imports_in(a.registry,a.types,data)
            linked,is_linked:=ui.tree_link(data,imports,context.temp_allocator)
            nodes,expanded:=ui.tree_expand(linked,context.temp_allocator)
            if !imported || !is_linked || !expanded {continue}
            for &n,row in nodes {
                if .Localized not_in n.flags || n.kind==.Component || n.text.length==0 {continue}
                name:=serial.text_field(n.name[:])
                append(&uses,Texts_Use{record.path,strings.clone(name) if name!="" else fmt.tprintf("#%d",row),strings.clone(ui.tree_string(linked.text,n.text))})
            }
        case asset.KIND_RECORDS:
            bytes,read:=asset.registry_read(a.registry,record.path)
            file:asset.Asset
            if read!=.None || asset.asset_take(&file,bytes)!=.None {continue}
            view,error:=asset.records_view(&file,a.types)
            if error!=.None {continue}
            values,_:=asset.asset_column_data(&file,view.rows,view.value)
            type:=view.rows.columns[view.value].type
            size:=int(file.schema.types[type].size)
            for row in 0..<len(view.ids) {
                if (row+1)*size>len(values) {break}
                texts_record_uses(&uses,&file.schema,type,values[row*size:][:size],record.path,strings.clone(serial.text_field(view.names[row][:])))
            }
        }
    }
    return uses[:]
}

// The core.Text fields of a value of a type of the schema of a file, each
// asked by the path of its field after the name of its row.
@(private="file")
texts_record_uses :: proc(uses:^[dynamic]Texts_Use,schema:^serial.Schema,type:serial.Type_Index,value:[]u8,document,asker:string) {
    t:=schema.types[type]
    #partial switch t.kind {
    case .Struct:
        fields:=schema.fields[t.first:][:t.count]
        if t.name=="Text" && len(fields)==1 && fields[0].name=="key" && .Text in fields[0].flags {
            if key:=serial.text_field(value);key!="" {append(uses,Texts_Use{document,asker,strings.clone(key)})}
            return
        }
        for field in fields {
            size:=int(schema.types[field.type].size)
            texts_record_uses(uses,schema,field.type,value[field.offset:][:size],document,fmt.tprintf("%s.%s",asker,field.name))
        }
    case .Array:
        size:=int(schema.types[t.elem].size)
        if schema.types[t.elem].kind!=.Struct && schema.types[t.elem].kind!=.Array {return}
        for i in 0..<int(t.count) {texts_record_uses(uses,schema,t.elem,value[i*size:][:size],document,fmt.tprintf("%s[%d]",asker,i))}
    }
}

// Whether code names a language as a .strings keeps it: a language of two or
// three lowercase letters, then parts of letters and digits after '-'.
texts_code :: proc(code:string) -> bool {
    if len(code)>=len(asset.String_Language{}.code) {return false}
    for part,i in strings.split(code,"-",context.temp_allocator) {
        if i==0 && (len(part)<2 || len(part)>3) || len(part)<2 || len(part)>8 {return false}
        for c in transmute([]u8)part {
            if i==0 && (c<'a' || c>'z') || !(c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9') {return false}
        }
    }
    return true
}

// What the texts lack, each a line that says how to fix it: what does not
// load and the keys two files have; who shows a key no .strings has, by its
// document and its node or its row and field; the keys that say nothing in
// a language of the game, nor in the language of its region; and the
// characters of a language the glyphs of the interfaces lack, which show
// as '?'.
texts_missing :: proc(t:^Texts,uses:[]Texts_Use) -> []string {
    context.allocator=context.temp_allocator
    out:=make([dynamic]string)
    append(&out,..t.problems[:])
    for use in uses {
        row:=texts_row(t,use.key)
        said:=false
        if row!=nil {for cell in row.cells {said||=cell!=""}}
        if !said {append(&out,fmt.tprintf("%s: %s shows the key %s, which no .strings has: mirai texts set %s %s \"<its text>\" writes it",use.document,use.asker,use.key,use.key,t.languages[0]))}
    }
    for &row in t.rows {
        for code in t.languages[1:] {
            if texts_text(t,row.key,code)!="" {continue}
            shown:=t.languages[0]
            for parent:=code;strings.last_index_byte(parent,'-')>0; {
                parent=parent[:strings.last_index_byte(parent,'-')]
                if texts_text(t,row.key,parent)!="" {shown="";break}
            }
            if shown!="" {append(&out,fmt.tprintf("the key %s of %s says nothing in %s, where it shows what it says in %s: mirai texts set %s %s \"<its text>\" writes it",row.key,t.files[row.file].path,code,shown,row.key,code))}
        }
    }
    for code,language in t.languages {
        lacked:=make([dynamic]string)
        seen:=make([dynamic]rune)
        for &row in t.rows {
            if language>=len(row.cells) {continue}
            for r in row.cells[language] {
                if texts_drawn(r) || slice.contains(seen[:],r) {continue}
                append(&seen,r)
                append(&lacked,fmt.tprintf("'%c' U+%04X (%s)",r,r,row.key))
            }
        }
        if len(lacked)>0 {append(&out,fmt.tprintf("the texts in %s have characters the glyphs of the interfaces lack, which show as '?': %s; write them with Latin, Greek or Cyrillic letters: mirai texts set <key> %s \"<its text>\"",code,strings.join(lacked[:],", "),code))}
    }
    return out[:]
}

// Whether the fonts of the interfaces draw a character: those of the glyphs
// of their atlas (ui.FONT_RANGES and ui.FONT_EXTRA).
@(private="file")
texts_drawn :: proc(r:rune) -> bool {
    for range in ui.FONT_RANGES {if r>=range.first && r<=range.last {return true}}
    extras:=ui.FONT_EXTRA
    return slice.contains(extras[:],r)
}
