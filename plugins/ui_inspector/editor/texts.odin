package ui_inspector_editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:engine/gui"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The texts of a node in the languages of the game. A localized node keeps
// its text, in the language the interfaces are written in
// (UI_Settings.source), and a translation for each other language of
// UI_Settings.languages in its own .ui, under an id of its own: a text is
// not shared between nodes; a widget that has it is. The bubble of its Text
// row opens a window with a row for each language. ui.texts and ui.text.set
// do it for agents, and ui.text.export and ui.text.import (mirai texts)
// take every text of the project to a CSV and back: its rows are found by
// the asset id of their .ui, and an empty cell changes nothing.

// What the rows of the window edit, as the records had it when it opened.
Texts_Edit :: struct {
    open:bool,
    node:int,     // the row they are of; -1: none
    change:u64,   // of the records they were read at
    values:[gui.Language][TEXT_EDIT]u8,
    lengths:[gui.Language]int,
}

// The languages of the game and the one its texts are written in.
@(private)
texts_languages :: proc(s:^editor.Session) -> (languages:gui.Languages,source:gui.Language) {
    languages,source={.English},.English
    if settings:=cast(^gui.UI_Settings)editor.setting_value(s,gui.UI_Settings);settings!=nil {
        languages,source=settings.languages,settings.source
    }
    languages+={source}
    return
}

// The name of a language as a person reads it.
language_name :: proc(language:gui.Language) -> string {
    name,_:=strings.replace_all(fmt.tprintf("%v",language),"_"," ",context.temp_allocator)
    return name
}

// The text of a node in a language: its own in the source, or its translation.
@(private)
node_text_in :: proc(r:^author.Records,n:^ui.Tree_Node,language,source:gui.Language) -> string {
    if language==source {return author.records_text(r,n.text)}
    codes:=gui.LANGUAGE_CODES
    if at:=author.records_translation(r,n.text_id,codes[language]);at>=0 {return author.records_text(r,r.translations[at].text)}
    return ""
}

// Sets the text of a node in a language; in another than the source it
// becomes localized. An empty translation goes.
@(private)
node_text_set :: proc(r:^author.Records,n:^ui.Tree_Node,row:int,language,source:gui.Language,text:string) {
    if language==source {
        author.records_text_set(r,&n.text,text)
        return
    }
    if n.text_id==0 {n.text_id=author.records_text_id(r,row)}
    n.flags+={.Localized}
    codes:=gui.LANGUAGE_CODES
    at:=author.records_translation(r,n.text_id,codes[language])
    if text=="" {
        if at>=0 {ordered_remove(&r.translations,at)}
        return
    }
    if at<0 {
        t:=ui.Tree_Translation{id=n.text_id}
        ui.tree_text_set(t.language[:],codes[language])
        append(&r.translations,t)
        at=len(r.translations)-1
    }
    author.records_text_set(r,&r.translations[at].text,text)
}

// The bubble at the end of the row of the text of a node: filled when it is
// localized, empty when it is not, and off while a path of the game gives
// the text.
@(private)
texts_button :: proc(p:^Pane,n:^ui.Tree_Node,bound:bool) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    localized:=.Localized in n.flags && !bound
    tip:="Its text in each language of the game" if !bound else "A path of the game gives its text: it shows as the game has it"
    if ui.button(ctx,ui.id(ctx,"texts_open"),{icon=.Speech if localized else .Speech_Empty,icon_size=14,icon_color=th.accent if localized else th.text_faint,tip=tip,style=.Ghost,width=th.row,height=th.row,disabled=bound,active=u.texts.open}).clicked {
        u.texts.open,u.texts.node=true,-1
    }
}

// The window of the texts of the node chosen, over the editor.
@(private)
texts_window :: proc(s:^editor.Session,u:^Ui_Inspector,n:^ui.Tree_Node) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    e:=&u.texts
    if !e.open {return}
    r:=&u.records
    languages,source:=texts_languages(s)
    // The window is of the node it opened for: choosing another closes it.
    if e.node>=0 && e.node!=u.selected {
        e.open=false
        return
    }
    // What the rows edit is read again when the records changed and no row is being typed in.
    if e.node!=u.selected || e.change!=u.change && ctx.edit.id==0 {
        e.node,e.change=u.selected,u.change
        for language in gui.Language {
            e.lengths[language]=copy(e.values[language][:len(e.values[language])-1],node_text_in(r,n,language,source))
        }
    }
    closed:=false
    if ui.modal(ctx,ui.id(ctx,"texts_window"),{width=460,close=&closed}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=6,align_y=.Center}) {
            ui.icon(ctx,.Speech,th.text_muted,15)
            ui.label(ctx,fmt.tprintf("Texts of %s",serial.text_field(n.name[:])),th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
            if ui.button(ctx,ui.id(ctx,"texts_settings"),{icon=ui.icon_user(u8(editor.User_Icon.Gear)),icon_size=14,icon_color=th.text_muted,tip="The languages of the game, in Project Settings",style=.Ghost,width=th.row,height=th.row}).clicked {
                e.open=false
                editor.settings_open(s,"UI_Settings")
            }
        }
        localized:=.Localized in n.flags
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
            ui.column_label(ctx,"Localized")
            if ui.toggle_switch(ctx,ui.id(ctx,"texts_localized"),&localized) {
                if localized {
                    n.flags+={.Localized}
                    if n.text_id==0 {n.text_id=author.records_text_id(r,u.selected)}
                } else {n.flags-={.Localized}}
                changed(u,"Localized")
            }
        }
        for language in gui.Language {
            if language not_in languages || !localized && language!=source {continue}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
                ui.column_label(ctx,language_name(language))
                buffer:=e.values[language][:]
                result:=ui.text_field(ctx,ui.id(ctx,"text",int(language)+1),buffer[:len(buffer)-1],&e.lengths[language],{width=ui.GROW,placeholder="" if language==source else author.records_text(r,n.text)})
                if result.committed {
                    node_text_set(r,n,u.selected,language,source,string(buffer[:e.lengths[language]]))
                    changed(u,"Text")
                }
            }
        }
    }
    if closed {e.open=false}
}

// ---------------------------------------------------------------- the API

Ui_Texts_Params :: struct {
    asset:base.Asset_Id,
    node:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=Its name"`,
}
Ui_Text_Set_Params :: struct {
    asset:base.Asset_Id,
    node:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=Its name"`,
    language:[32]u8 `mirai:"text,label=Its name (Spanish or Latam_Spanish) or its code (es or es-419)"`,
    text:[4096]u8 `mirai:"text,label=UTF-8. In the language interfaces are written in the text of the node; in another its translation; empty takes the translation away"`,
}
Ui_Texts_File_Params :: struct {
    path:[512]u8 `mirai:"text,label=A CSV with the columns file; asset (the id of the .ui); node; id; and one per language of the game by its code with the one texts are written in first. An import finds a row by asset and id: file is only to read and an empty cell changes nothing"`,
}

Ui_Texts_Result :: struct {
    localized:bool `mirai:"label=Whether it keeps a translation for each other language"`,
    source:gui.Language `mirai:"label=The language interfaces are written in"`,
    texts:[1]Ui_Text_Entry `mirai:"list,label=One for each language of the game (Project Settings > UI)"`,
}
Ui_Text_Entry :: struct {
    language:gui.Language,
    code:[8]u8 `mirai:"text"`,
    text:[RESULT_TEXT_BYTES]u8 `mirai:"text,label=In source the text of the node; in another its translation; empty where it has none"`,
}
Ui_Texts_Exported :: struct {
    path:[512]u8 `mirai:"text"`,
    texts:int `mirai:"label=The localized texts written"`,
}
Ui_Texts_Imported :: struct {
    files:[1][editor.API_PATH_BYTES]u8 `mirai:"list,text,label=The paths of the .ui it changed; each waits for Save"`,
    rejected:[1]Ui_Texts_Rejected `mirai:"list"`,
}
Ui_Texts_Rejected :: struct {
    row:int `mirai:"label=Of the CSV; the row of the columns is 1"`,
    reason:[RESULT_TEXT_BYTES]u8 `mirai:"text"`,
}

@(private)
texts_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="ui.texts",summary="The text of a node of a .ui in each language of the game: its own in the language interfaces are written in and its translation in each other.",params=Ui_Texts_Params,params_info=type_info_of(Ui_Texts_Params),result=Ui_Texts_Result,result_info=type_info_of(Ui_Texts_Result),writes_result=true,flags={.Read_Only},run=api_texts})
    editor.api_method_register(s,{name="ui.text.set",summary="Sets the text of a node of a .ui in a language of the game; a translation makes the node localized. One step of history; the file waits for Save.",params=Ui_Text_Set_Params,params_info=type_info_of(Ui_Text_Set_Params),result=Ui_Ok,result_info=type_info_of(Ui_Ok),run=api_text_set})
    editor.api_method_register(s,{name="ui.text.export",summary="Writes every localized text of the .ui of the project to a CSV for translators.",params=Ui_Texts_File_Params,params_info=type_info_of(Ui_Texts_File_Params),result=Ui_Texts_Exported,result_info=type_info_of(Ui_Texts_Exported),flags={.Read_Only},run=api_texts_export})
    editor.api_method_register(s,{name="ui.text.import",summary="Sets the texts of the .ui of the project from a CSV as ui.text.export writes it. One step of history per file; the files wait for Save.",params=Ui_Texts_File_Params,params_info=type_info_of(Ui_Texts_File_Params),result=Ui_Texts_Imported,result_info=type_info_of(Ui_Texts_Imported),writes_result=true,run=api_texts_import})
}

@(private)
api_language :: proc(call:^api.Call,named:string) -> (language:gui.Language,ok:bool) {
    codes:=gui.LANGUAGE_CODES
    for l in gui.Language {
        if strings.equal_fold(fmt.tprintf("%v",l),named) || strings.equal_fold(language_name(l),named) || codes[l]==named {return l,true}
    }
    api.call_fail(call,api.INVALID_PARAMS,"language is one of English, Russian, Spanish, Latam_Spanish, German, French, Portuguese or Italian, or its code")
    return
}

@(private)
api_texts :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Texts_Params)
    records:author.Records
    row,ok:=api_node(s,call,p.asset,serial.text_field(p.node[:]),&records)
    if !ok {return}
    n:=&records.nodes[row]
    languages,source:=texts_languages(s)
    codes:=gui.LANGUAGE_CODES
    out:=call.out
    serial.write_u8(out,'{')
    api.write_bool(out,"localized",.Localized in n.flags,true)
    api.write_text(out,"source",fmt.tprintf("%v",source))
    api.write_key(out,"texts");serial.write_u8(out,'[')
    first:=true
    for language in gui.Language {
        if language not_in languages {continue}
        if !first {serial.write_u8(out,',')};first=false
        serial.write_u8(out,'{')
        api.write_text(out,"language",fmt.tprintf("%v",language),true)
        api.write_text(out,"code",codes[language])
        api.write_text(out,"text",node_text_in(&records,n,language,source))
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}

@(private)
api_text_set :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Text_Set_Params)
    language,known:=api_language(call,serial.text_field(p.language[:]))
    if !known {return}
    languages,source:=texts_languages(s)
    if language not_in languages {api.call_failf(call,api.INVALID_PARAMS,"the game is not in %s: add it to the languages of Project Settings > UI first",language_name(language));return}
    text:=serial.text_field(p.text[:])
    records:author.Records
    row,ok:=api_node(s,call,p.asset,serial.text_field(p.node[:]),&records)
    if !ok {return}
    node_text_set(&records,&records.nodes[row],row,language,source,text)
    message,written:=records_write(s,p.asset,&records,"Text")
    if !written {api.call_fail(call,api.INVALID_PARAMS,message);return}
    api.call_result(call,Ui_Ok).ok=true
}

// A field of a CSV, quoted when it has a comma, a quote or a line.
@(private)
csv_field :: proc(b:^strings.Builder,text:string) {
    if !strings.contains_any(text,",\"\n\r") {strings.write_string(b,text);return}
    strings.write_byte(b,'"')
    for c in transmute([]u8)text {
        if c=='"' {strings.write_byte(b,'"')}
        strings.write_byte(b,c)
    }
    strings.write_byte(b,'"')
}

// The rows of a CSV, each its fields.
@(private)
csv_rows :: proc(text:string) -> [][]string {
    rows:=make([dynamic][]string,context.temp_allocator)
    fields:=make([dynamic]string,context.temp_allocator)
    b:=strings.builder_make(context.temp_allocator)
    quoted:=false
    end_field :: proc(fields:^[dynamic]string,b:^strings.Builder) {
        append(fields,strings.clone(strings.to_string(b^),context.temp_allocator))
        strings.builder_reset(b)
    }
    for i:=0;i<len(text);i+=1 {
        c:=text[i]
        switch {
        case quoted && c=='"' && i+1<len(text) && text[i+1]=='"': strings.write_byte(&b,'"');i+=1
        case c=='"':                quoted=!quoted
        case !quoted && c==',':     end_field(&fields,&b)
        case !quoted && c=='\r':
        case !quoted && c=='\n':
            end_field(&fields,&b)
            append(&rows,fields[:])
            fields=make([dynamic]string,context.temp_allocator)
        case:                       strings.write_byte(&b,c)
        }
    }
    if strings.builder_len(b)>0 || len(fields)>0 {
        end_field(&fields,&b)
        append(&rows,fields[:])
    }
    return rows[:]
}

// The order of the columns of the languages of a CSV: the source first.
@(private)
texts_csv_order :: proc(languages:gui.Languages,source:gui.Language) -> []gui.Language {
    order:=make([dynamic]gui.Language,context.temp_allocator)
    append(&order,source)
    for language in gui.Language {if language in languages && language!=source {append(&order,language)}}
    return order[:]
}

// The first row of the CSV ui.text.export writes.
@(private)
texts_csv_header :: proc(b:^strings.Builder,order:[]gui.Language) {
    codes:=gui.LANGUAGE_CODES
    strings.write_string(b,"file,asset,node,id")
    for language in order {strings.write_byte(b,',');strings.write_string(b,codes[language])}
    strings.write_byte(b,'\n')
}

// The rows of the localized texts of one .ui, in the columns of order; how many.
@(private)
texts_csv_file :: proc(b:^strings.Builder,path:string,id:base.Asset_Id,records:^author.Records,order:[]gui.Language,source:gui.Language) -> (count:int) {
    text:[32]u8
    for &n in records.nodes {
        if .Localized not_in n.flags || n.text_id==0 {continue}
        csv_field(b,path);strings.write_byte(b,',')
        strings.write_string(b,base.asset_id_format(id,text[:]));strings.write_byte(b,',')
        csv_field(b,serial.text_field(n.name[:]));strings.write_byte(b,',')
        strings.write_string(b,fmt.tprintf("%016x",n.text_id))
        for language in order {strings.write_byte(b,',');csv_field(b,node_text_in(records,&n,language,source))}
        strings.write_byte(b,'\n')
        count+=1
    }
    return
}

// The language of each column of the first row of a CSV, from the fifth;
// why, for a person, when it is not that of ui.text.export.
@(private)
texts_csv_columns :: proc(rows:[][]string,languages:gui.Languages) -> (columns:[]gui.Language,why:string) {
    if len(rows)<1 || len(rows[0])<5 || rows[0][0]!="file" || rows[0][1]!="asset" || rows[0][2]!="node" || rows[0][3]!="id" {return nil,"the CSV starts with file,asset,node,id and a column for each language by its code, as ui.text.export writes it"}
    codes:=gui.LANGUAGE_CODES
    columns=make([]gui.Language,len(rows[0]),context.temp_allocator)
    for header,i in rows[0][4:] {
        found:=false
        for language in gui.Language {if codes[language]==header && language in languages {columns[i+4],found=language,true}}
        if !found {return nil,fmt.tprintf("column %s is not the code of a language of the game; add it in Project Settings > UI or take the column out",header)}
    }
    return
}

// A row of a CSV of texts: the .ui it is of, the id of its text and its cell in each language.
@(private) Texts_Row :: struct {line:int,asset:base.Asset_Id,id:u64,cells:[]string}
@(private) Texts_Rejected :: struct {line:int,reason:string}

// A row after the first of a CSV, line of its file, against the .ui of the
// registry: why when it is not one of them. width: the columns of the first row.
@(private)
texts_csv_row :: proc(registry:^asset.Registry,row:[]string,line,width:int) -> (parsed:Texts_Row,why:string) {
    if len(row)<width {return {},"it has fewer columns than the first row"}
    id,ok:=base.asset_id_parse(row[1])
    if !ok {return {},fmt.tprintf("asset '%s' is not an asset id",row[1])}
    if file,found:=asset.registry_find(registry,id);!found || file.kind!=asset.KIND_UI {return {},fmt.tprintf("asset %s is not a .ui of the project",row[1])}
    text_id,hex:=u64(0),len(row[3])==16
    for c in transmute([]u8)row[3] {
        digit:=u64(c-'0') if c>='0' && c<='9' else u64(c-'a'+10) if c>='a' && c<='f' else 16
        hex&=digit<16
        text_id=text_id<<4|(digit&15)
    }
    if !hex || text_id==0 {return {},fmt.tprintf("id '%s' is not the id of a localized text: 16 hexadecimal digits",row[3])}
    return {line,id,text_id,row[4:width]},""
}

// Sets the texts the rows of the .ui id give in their columns (an empty cell
// changes nothing); a row without its localized node goes to rejected.
// Whether a cell set a text.
@(private)
texts_csv_apply :: proc(records:^author.Records,id:base.Asset_Id,rows:[]Texts_Row,columns:[]gui.Language,source:gui.Language,rejected:^[dynamic]Texts_Rejected) -> (touched:bool) {
    for row in rows {
        if row.asset!=id {continue}
        at:=-1
        for &n,i in records.nodes {if n.text_id==row.id && .Localized in n.flags {at=i;break}}
        if at<0 {append(rejected,Texts_Rejected{row.line,fmt.tprintf("its .ui has no localized node with id %016x",row.id)});continue}
        for text,i in row.cells {
            if text!="" {node_text_set(records,&records.nodes[at],at,columns[i+4],source,text);touched=true}
        }
    }
    return
}

@(private)
api_texts_export :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Texts_File_Params)
    path:=serial.text_field(p.path[:])
    a:=s.app.assets
    if a==nil || path=="" {api.call_fail(call,api.INVALID_PARAMS,"path is the CSV to write");return}
    languages,source:=texts_languages(s)
    order:=texts_csv_order(languages,source)
    b:=strings.builder_make(context.temp_allocator)
    texts_csv_header(&b,order)
    count:=0
    api_flush(s)
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        records:author.Records
        if !author.records_read(author.assets_of(a),file.id,&records,context.temp_allocator) {continue}
        count+=texts_csv_file(&b,file.path,file.id,&records,order,source)
    }
    if serial.file_write_atomic(path,transmute([]u8)strings.to_string(b))!=.None {api.call_failf(call,api.SERVER_ERROR,"%s could not be written",path);return}
    api.call_result(call,Ui_Texts_Exported)^={path=p.path,texts=count}
}

@(private)
api_texts_import :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Texts_File_Params)
    path:=serial.text_field(p.path[:])
    a:=s.app.assets
    if a==nil || path=="" {api.call_fail(call,api.INVALID_PARAMS,"path is the CSV to read");return}
    bytes,error:=os.read_entire_file(path,context.temp_allocator)
    if error!=nil {api.call_failf(call,api.INVALID_PARAMS,"%s could not be read",path);return}
    rows:=csv_rows(string(bytes))
    languages,source:=texts_languages(s)
    columns,why:=texts_csv_columns(rows,languages)
    if why!="" {api.call_fail(call,api.INVALID_PARAMS,why);return}
    api_flush(s)
    // Each row by the .ui it names; a row that names none is rejected with why.
    accepted:=make([dynamic]Texts_Row,context.temp_allocator)
    rejected:=make([dynamic]Texts_Rejected,context.temp_allocator)
    assets:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for row,i in rows[1:] {
        line:=i+2
        if len(row)==1 && row[0]=="" {continue}
        parsed,reason:=texts_csv_row(&a.registry,row,line,len(rows[0]))
        if reason!="" {append(&rejected,Texts_Rejected{line,reason});continue}
        append(&accepted,parsed)
        if !slice.contains(assets[:],parsed.asset) {append(&assets,parsed.asset)}
    }
    out:=call.out
    serial.text_write_raw(out,`{"files":[`)
    first:=true
    for id in assets {
        records:author.Records
        if !author.records_read(author.assets_of(a),id,&records,context.temp_allocator) {
            for row in accepted {if row.asset==id {append(&rejected,Texts_Rejected{row.line,"its .ui does not load"})}}
            continue
        }
        if !texts_csv_apply(&records,id,accepted[:],columns,source,&rejected) {continue}
        if message,written:=records_write(s,id,&records,"Import texts");!written {
            for row in accepted {if row.asset==id {append(&rejected,Texts_Rejected{row.line,message})}}
            continue
        }
        if !first {serial.write_u8(out,',')};first=false
        file,_:=asset.registry_find(&a.registry,id)
        serial.text_write_string(out,file.path)
    }
    serial.text_write_raw(out,`],"rejected":[`)
    for rejection,i in rejected {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_int(out,"row",i64(rejection.line),true)
        api.write_text(out,"reason",rejection.reason)
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}
