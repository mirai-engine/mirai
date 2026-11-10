package editor

import "core:os"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:editor/api"
import "mirai:engine/gui"
import "mirai:std/serial"

// The texts of the project in the session: its .strings as author.Texts
// reads them, unsaved changes included, and the texts.* methods, which do in
// the open editor what mirai texts does on the files. A change is a step of
// history of each .strings it touches, which waits for Save.

// The texts of the project and the codes of the languages of the game, the
// one its texts are written in first.
texts_open :: proc(s:^Session) -> (texts:author.Texts,languages:[]string) {
    settings:=gui.UI_SETTINGS_DEFAULT
    if value:=cast(^gui.UI_Settings)setting_value(s,gui.UI_Settings);value!=nil {settings=value^}
    languages=author.texts_languages(settings)
    return author.texts_read(author.assets_of(s.app.assets),languages[0]),languages
}

// Writes the .strings the changes of texts touched; problem: why it could not.
texts_write :: proc(s:^Session,texts:^author.Texts,label:string) -> (problem:string) {
    a:=s.app.assets
    written:[]author.Texts_Written
    if written,problem=author.texts_written(texts,&a.types,asset_id_new(s));problem!="" {return}
    for file in written {
        if !file_write(s,asset.registry_file_path(&a.registry,file.path,context.temp_allocator),file.bytes,label) {return "a .strings could not be written"}
    }
    return ""
}

Texts_Set_Params :: struct {
    key:[64]u8 `mirai:"text,label=The key of the text; one no .strings has is added to texts.strings"`,
    language:[16]u8 `mirai:"text,label=Its code: en; es; pt-BR. texts.list gives those of the game"`,
    text:[4096]u8 `mirai:"text,label=UTF-8: what the key says in that language; empty takes it away"`,
}
Texts_File_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=A CSV with the column key and one per language by its code, as texts.export writes it and mirai import reads it; an import changes nothing where a cell is empty"`,
}
Texts_List :: struct {
    languages:[1][16]u8 `mirai:"list,text,label=The codes of the languages of the game (Project Settings > UI), the one its texts are written in first"`,
    texts:[1]Texts_Entry `mirai:"list"`,
}
Texts_Entry :: struct {
    key:[64]u8 `mirai:"text"`,
    file:[API_PATH_BYTES]u8 `mirai:"text,label=The .strings it is in"`,
    texts:u8 `mirai:"any,label=What it says by language code; a language it says nothing in is left out and shows the first"`,
}
Texts_Missing :: struct {
    missing:[1][512]u8 `mirai:"list,text,label=Each says what lacks a text and how to write it: who shows a key no .strings has (its .ui and node; its .records; row and field); a key without a text in a language of the game; a key two files have"`,
}
Texts_Count :: struct {
    texts:int `mirai:"label=The texts written or set"`,
}

@(private)
texts_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="texts.list",summary="Every text a player reads, by key: what each key of the .strings of the project says in each language. A node of a .ui, a core.Text of a row and the code show a text by its key.",result=Texts_List,writes_result=true,flags={.Read_Only},run=api_texts_list})
    api_register(s,st,{name="texts.set",summary="Makes a key say a text in a language: adds a text, or translates one. One step of history; its .strings waits for Save.",params=Texts_Set_Params,result=Texts_Count,run=api_texts_set})
    api_register(s,st,{name="texts.missing",summary="What the texts lack: who shows a key no .strings has, and the keys that say nothing in a language of the game.",result=Texts_Missing,writes_result=true,flags={.Read_Only},run=api_texts_missing})
    api_register(s,st,{name="texts.export",summary="Writes every text of the project to a CSV for translators.",params=Texts_File_Params,result=Texts_Count,flags={.Read_Only},run=api_texts_export})
    api_register(s,st,{name="texts.import",summary="Makes the keys of a CSV say its texts, as texts.export writes it. One step of history per .strings, which waits for Save.",params=Texts_File_Params,result=Texts_Count,run=api_texts_import})
}

@(private="file")
api_texts_list :: proc(s:^Session,call:^api.Call) {
    texts,languages:=texts_open(s)
    out:=call.out
    serial.text_write_raw(out,`{"languages":[`)
    for code,i in languages {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,code)
    }
    serial.text_write_raw(out,`],"texts":[`)
    for &row,i in texts.rows {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"key",row.key,true)
        api.write_text(out,"file",texts.files[row.file].path)
        api.write_key(out,"texts");serial.write_u8(out,'{')
        first:=true
        for cell,language in row.cells {
            if cell=="" {continue}
            api.write_text(out,texts.languages[language],cell,first)
            first=false
        }
        serial.text_write_raw(out,"}}")
    }
    serial.text_write_raw(out,"]}")
}

// Writes the texts a call changed and answers how many; fails the call with a problem.
@(private="file")
api_texts_done :: proc(s:^Session,call:^api.Call,texts:^author.Texts,count:int,problem,label:string) {
    problem:=problem
    if problem=="" {problem=texts_write(s,texts,label)}
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    api.call_result(call,Texts_Count).texts=count
}

@(private="file")
api_texts_set :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Texts_Set_Params)
    texts,_:=texts_open(s)
    api_texts_done(s,call,&texts,1,author.texts_set(&texts,serial.text_field(p.key[:]),serial.text_field(p.language[:]),serial.text_field(p.text[:])),"Text")
}

@(private="file")
api_texts_missing :: proc(s:^Session,call:^api.Call) {
    texts,languages:=texts_open(s)
    out:=call.out
    serial.text_write_raw(out,`{"missing":[`)
    for line,i in author.texts_missing(&texts,author.texts_uses(author.assets_of(s.app.assets)),languages) {
        if i>0 {serial.write_u8(out,',')}
        serial.text_write_string(out,line)
    }
    serial.text_write_raw(out,"]}")
}

@(private="file")
api_texts_export :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Texts_File_Params)
    path:=serial.text_field(p.path[:])
    texts,_:=texts_open(s)
    if path=="" || serial.file_write_atomic(path,transmute([]u8)author.texts_csv(&texts))!=.None {api.call_failf(call,api.INVALID_PARAMS,"path is the CSV to write, and '%s' could not be written",path);return}
    api.call_result(call,Texts_Count).texts=len(texts.rows)
}

@(private="file")
api_texts_import :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Texts_File_Params)
    path:=serial.text_field(p.path[:])
    bytes,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {api.call_failf(call,api.INVALID_PARAMS,"path is the CSV to read, and '%s' could not be read",path);return}
    texts,_:=texts_open(s)
    set,problem:=author.texts_csv_take(&texts,string(bytes))
    api_texts_done(s,call,&texts,set,problem,"Import texts")
}
