package ui_inspector_editor

import "core:fmt"
import "core:strings"
import "mirai:cook/author"
import "mirai:editor"
import "mirai:engine/gui"
import "mirai:std/serial"
import "mirai:ui"

// The text of a node in the languages of the game. A localized node shows a
// key of the texts of the project (editor.texts_open): what the key says in
// each language is in its .strings, so the nodes, the rows of game data and
// the code that name one key show one text. The bubble of its Text row opens
// a window with the key and a row for each language of UI_Settings.languages;
// texts.* does it for agents, and mirai texts takes them to a CSV and back.

// What the rows of the window edit, as the texts had it when it opened.
Texts_Edit :: struct {
    open:bool,
    node:int,     // the row they are of; -1: none
    change:u64,   // of the records they were read at
    revision:u64, // of the assets then: a .strings that changes is read again
    key:[ui.TREE_NAME_CAPACITY]u8,
    key_length:int,
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

// The text of a node in a language: what its key says there, or its own in
// the one texts are written in.
@(private)
node_text_in :: proc(s:^editor.Session,r:^author.Records,n:^ui.Tree_Node,language,source:gui.Language) -> string {
    codes:=gui.LANGUAGE_CODES
    if .Localized in n.flags {
        texts,_:=editor.texts_open(s)
        return author.texts_text(&texts,author.records_text(r,n.text),codes[language])
    }
    return author.records_text(r,n.text) if language==source else ""
}

// Sets the text of a node in a language: of a localized one, what its key
// says there, for everything that shows the key, as a step of history of
// its .strings; of another, its own. Whether the records of the .ui changed.
@(private)
node_text_set :: proc(s:^editor.Session,r:^author.Records,n:^ui.Tree_Node,language:gui.Language,text:string) -> (records_changed:bool) {
    if .Localized not_in n.flags {
        author.records_text_set(r,&n.text,text)
        return true
    }
    codes:=gui.LANGUAGE_CODES
    texts,_:=editor.texts_open(s)
    problem:=author.texts_set(&texts,author.records_text(r,n.text),codes[language],text)
    if problem=="" {problem=editor.texts_write(s,&texts,"Text")}
    if problem!="" {editor.notify(s,problem)}
    return false
}

// Makes a node localized, under the key its text makes (author.texts_key),
// or takes it back to a text of its own: what its key says.
@(private)
node_localize :: proc(s:^editor.Session,r:^author.Records,n:^ui.Tree_Node,source:gui.Language,localized:bool) {
    codes:=gui.LANGUAGE_CODES
    texts,_:=editor.texts_open(s)
    text:=author.records_text(r,n.text)
    if !localized {
        if said:=author.texts_text(&texts,text,codes[source]);said!="" {author.records_text_set(r,&n.text,said)}
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
    // What the rows edit is read again when the records or the texts changed and no row is being typed in.
    revision:=s.app.assets.registry.revision
    if e.node!=u.selected || (e.change!=u.change || e.revision!=revision) && ctx.edit.id==0 {
        e.node,e.change,e.revision=u.selected,u.change,revision
        e.key_length=copy(e.key[:len(e.key)-1],author.records_text(r,n.text) if .Localized in n.flags else "")
        for language in gui.Language {
            e.lengths[language]=copy(e.values[language][:len(e.values[language])-1],node_text_in(s,r,n,language,source))
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
                node_localize(s,r,n,source,localized)
                changed(u,"Localized")
            }
        }
        if localized {
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
                ui.column_label(ctx,"Key")
                if ui.text_field(ctx,ui.id(ctx,"texts_key"),e.key[:len(e.key)-1],&e.key_length,{width=ui.GROW}).committed && e.key_length>0 {
                    author.records_text_set(r,&n.text,string(e.key[:e.key_length]))
                    changed(u,"Key")
                }
            }
        }
        for language in gui.Language {
            if language not_in languages || !localized && language!=source {continue}
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center}) {
                ui.column_label(ctx,language_name(language))
                buffer:=e.values[language][:]
                result:=ui.text_field(ctx,ui.id(ctx,"text",int(language)+1),buffer[:len(buffer)-1],&e.lengths[language],{width=ui.GROW,placeholder="" if language==source else string(e.values[source][:e.lengths[source]])})
                if result.committed && node_text_set(s,r,n,language,string(buffer[:e.lengths[language]])) {changed(u,"Text")}
            }
        }
    }
    if closed {e.open=false}
}
