package ui_inspector_editor

import "core:fmt"
import "core:strings"
import "mirai:cook/author"
import "mirai:editor"
import "mirai:engine/gui"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:editor/kit"
import "mirai:ui"

// The text of a node in the languages of the game. A localized node shows a
// key of the texts of the project (editor.texts_open): what the key says in
// each language is in its .strings, so the nodes, the rows of game data and
// the code that name one key show one text. The bubble of its Text row opens
// a window with the key and a row for each language its .strings name;
// texts.* does it for agents, and mirai texts takes them to a CSV and back.

// What the rows of the window edit, as the texts had it when it opened.
Texts_Edit :: struct {
    open:bool,
    node:int,     // the row they are of; -1: none
    change:u64,   // of the records they were read at
    revision:u64, // of the assets then: a .strings that changes is read again
    key:[ui.TREE_NAME_CAPACITY]u8,
    key_length:int,
    values:[TEXTS_LANGUAGES][TEXT_EDIT]u8, // by language of the game
    lengths:[TEXTS_LANGUAGES]int,
    code:[gui.LANGUAGE_CODE]u8, // of a language to add
    code_length:int,
}
TEXTS_LANGUAGES :: 16 // languages the window edits; the others are edited with texts.set

// The codes of the languages of the game, those its .strings name, the one
// its texts are written in first: read again when the assets change.
Texts_Languages :: struct {
    revision:u64, // of the assets they were read at
    codes:[TEXTS_LANGUAGES][gui.LANGUAGE_CODE]u8,
    count:int,
}
@(private)
texts_languages :: proc(s:^editor.Session,u:^Ui_Inspector) -> []string {
    l:=&u.languages
    if revision:=s.app.assets.registry.revision;l.revision!=revision || l.count==0 {
        texts:=editor.texts_open(s)
        l.revision,l.count=revision,min(len(texts.languages),TEXTS_LANGUAGES)
        for code,i in texts.languages[:l.count] {base.text_set(l.codes[i][:],code)}
    }
    out:=make([]string,l.count,context.temp_allocator)
    for &code,i in l.codes[:l.count] {out[i]=serial.text_field(code[:])}
    return out
}

// The text of a node in a language: what its key says there, or its own in
// the one texts are written in.
@(private)
node_text_in :: proc(s:^editor.Session,r:^author.Records,n:^ui.Tree_Node,language,source:string) -> string {
    if .Localized in n.flags {
        texts:=editor.texts_open(s)
        return author.texts_text(&texts,author.records_text(r,n.text),language)
    }
    return author.records_text(r,n.text) if language==source else ""
}

// Sets the text of a node in a language: of a localized one, what its key
// says there, for everything that shows the key, as a step of history of
// its .strings; of another, its own. Whether the records of the .ui changed.
@(private)
node_text_set :: proc(s:^editor.Session,r:^author.Records,n:^ui.Tree_Node,language,text:string) -> (records_changed:bool) {
    if .Localized not_in n.flags {
        author.records_text_set(r,&n.text,text)
        return true
    }
    texts:=editor.texts_open(s)
    problem:=author.texts_set(&texts,author.records_text(r,n.text),language,text)
    if problem=="" {problem=editor.texts_write(s,&texts,"Text")}
    if problem!="" {editor.notify(s,problem)}
    return false
}

// Makes a node localized, under the key its text makes (author.texts_key),
// or takes it back to a text of its own: what its key says.
@(private)
node_localize :: proc(s:^editor.Session,r:^author.Records,n:^ui.Tree_Node,source:string,localized:bool) {
    texts:=editor.texts_open(s)
    text:=author.records_text(r,n.text)
    if !localized {
        if said:=author.texts_text(&texts,text,source);said!="" {author.records_text_set(r,&n.text,said)}
        n.flags-={.Localized}
        return
    }
    key:=author.texts_key(&texts,text)
    n.flags+={.Localized}
    author.records_text_set(r,&n.text,key)
    if text!="" {node_text_set(s,r,n,source,text)}
}

// The bubble at the end of the row of the text of a node: filled when it is
// localized, empty when it is not, and off while a path of the game gives
// the text.
@(private)
texts_button :: proc(p:^Pane,n:^ui.Tree_Node,bound:bool) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    localized:=.Localized in n.flags && !bound
    tip:="Its text in each language of the game" if !bound else "A path of the game gives its text: it shows as the game has it"
    if ui.button(ctx,ui.id(ctx,"texts_open"),{icon=.Speech if localized else .Speech_Empty,icon_size=14,icon_color=ui.tone(ctx,"accent") if localized else ui.tone(ctx,"text_faint"),tip=tip,variant="ghost",width=ui.metric(ctx,"row"),height=ui.metric(ctx,"row"),disabled=bound,active=u.texts.open}).clicked {
        u.texts.open,u.texts.node=true,-1
    }
}

// The window of the texts of the node chosen, over the editor.
@(private)
texts_window :: proc(s:^editor.Session,u:^Ui_Inspector,n:^ui.Tree_Node) {
    ctx:=s.gui.ctx
    e:=&u.texts
    if !e.open {return}
    r:=&u.records
    languages:=texts_languages(s,u)
    source:=languages[0]
    // The window is of the node it opened for: choosing another closes it.
    if e.node>=0 && e.node!=u.selected {
        e.open=false
        return
    }
    // What the rows edit is read again when the records or the texts changed and no row is being typed in.
    revision:=s.app.assets.registry.revision
    if e.node!=u.selected || (e.change!=u.change || e.revision!=revision) && ctx.edit.id==0 {
        e.node,e.change,e.revision=u.selected,u.change,revision
        e.key_length=copy(e.key[:len(e.key)-1],author.records_text(r,n.text) if .Localized in n.flags else "")
        for language,i in languages {
            e.lengths[i]=copy(e.values[i][:len(e.values[i])-1],node_text_in(s,r,n,language,source))
        }
    }
    closed:=false
    if ui.modal(ctx,ui.id(ctx,"texts_window"),{width=460,close=&closed}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=6,align_y=.Center}) {
            ui.icon(ctx,.Speech,ui.tone(ctx,"text_muted"),15)
            ui.label(ctx,fmt.tprintf("Texts of %s",serial.text_field(n.name[:])),ui.metric(ctx,"font_heading"),ui.tone(ctx,"text"),0,font=ui.FONT_SEMIBOLD)
            if ui.button(ctx,ui.id(ctx,"texts_settings"),{icon=ui.icon_user(u8(editor.User_Icon.Gear)),icon_size=14,icon_color=ui.tone(ctx,"text_muted"),tip="The language its texts are written in, in Project Settings",variant="ghost",width=ui.metric(ctx,"row"),height=ui.metric(ctx,"row")}).clicked {
                e.open=false
                editor.settings_open(s,"UI_Settings")
            }
        }
        localized:=.Localized in n.flags
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
            kit.column_label(ctx,"Localized")
            if kit.toggle_switch(ctx,ui.id(ctx,"texts_localized"),&localized) {
                node_localize(s,r,n,source,localized)
                changed(u,"Localized")
            }
        }
        if localized {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
                kit.column_label(ctx,"Key")
                if ui.text_field(ctx,ui.id(ctx,"texts_key"),e.key[:len(e.key)-1],&e.key_length,{width=ui.GROW}).committed && e.key_length>0 {
                    author.records_text_set(r,&n.text,string(e.key[:e.key_length]))
                    changed(u,"Key")
                }
            }
        }
        for language,i in languages {
            if !localized && i>0 {break}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
                kit.column_label(ctx,language)
                buffer:=e.values[i][:]
                result:=ui.text_field(ctx,ui.id(ctx,"text",i+1),buffer[:len(buffer)-1],&e.lengths[i],{width=ui.GROW,placeholder="" if i==0 else string(e.values[0][:e.lengths[0]])})
                if result.committed && node_text_set(s,r,n,language,string(buffer[:e.lengths[i]])) {changed(u,"Text")}
            }
        }
        // Another language: the code of a .strings column, which its first text makes.
        if localized && len(languages)<TEXTS_LANGUAGES {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(ui.metric(ctx,"row")),gap=4,align_y=.Center}) {
                ui.text_field(ctx,ui.id(ctx,"texts_code"),e.code[:len(e.code)-1],&e.code_length,{width=ui.fixed(ui.metric(ctx,"label_width")),placeholder="pl"})
                buffer:=e.values[len(languages)][:]
                result:=ui.text_field(ctx,ui.id(ctx,"text",len(languages)+1),buffer[:len(buffer)-1],&e.lengths[len(languages)],{width=ui.GROW,placeholder="Its text in another language"})
                if result.committed && e.code_length>0 && node_text_set(s,r,n,string(e.code[:e.code_length]),string(buffer[:e.lengths[len(languages)]])) {changed(u,"Text")}
            }
        }
    }
    if closed {e.open=false}
}
