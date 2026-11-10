package editor

import "base:runtime"
import "core:mem"
import "core:strings"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The preferences of the editor: how its panels, its viewport, its lists and
// its Play were left, the same for every project and every checkout of the
// engine on this machine. They live in PREFERENCES_FILE in the folder of the
// engine on the machine (project.machine_folder), never versioned: a section
// per area, named by its type and written like the settings, with only the
// fields that differ from the code. Each area keeps its struct in its own
// storage; this file only reads and writes them, once the UI rests and
// they changed, and when the editor closes or restarts: never per frame. A
// --headless editor neither reads nor writes them, unless --preferences.
// What a user marks in the browser of a project (Content_Marks) and where
// they left it (Content_Navigation) are kept the same way, in MARKS_FILE in
// the .mirai folder of that project.

PREFERENCES_FILE :: "editor.mirai"
MARKS_FILE :: "content.mirai"
PREFERENCES_REST :: f32(0.5) // seconds without a gesture before a change is written

@(storage)
Preferences :: struct {
    file:string,  // "": this editor keeps none
    written:u64,  // what the file has, as preferences_hash
    marks_file:string,  // "": no project
    marks_written:u64,
    rest:f32,     // seconds the UI has rested
}

// The structs of the areas as the file names them, with their values of the code.
@(private)
preferences_list :: proc(s:^Session) -> []project.Setting {
    Area :: struct {name:string,info:^runtime.Type_Info,value:rawptr,default:proc(dst:rawptr)}
    // An editor without one of the storages (a session of a test) keeps no area of it.
    areas:=[?]Area{
        {"Layout",type_info_of(Layout),s.gui!=nil?&s.gui.layout:nil,proc(dst:rawptr) {(^Layout)(dst)^=LAYOUT_DEFAULT}},
        {"Content_View",type_info_of(Content_View),s.content!=nil?&s.content.view:nil,proc(dst:rawptr) {(^Content_View)(dst)^=CONTENT_VIEW_DEFAULT}},
        {"Viewport_Preferences",type_info_of(Viewport_Preferences),s.viewport!=nil?&s.viewport.preferences:nil,proc(dst:rawptr) {(^Viewport_Preferences)(dst)^=VIEWPORT_PREFERENCES_DEFAULT}},
        {"Console_Filter",type_info_of(Console_Filter),s.console!=nil?&s.console.filter:nil,proc(dst:rawptr) {(^Console_Filter)(dst)^=CONSOLE_DEFAULT.filter}},
        {"Play_Players",type_info_of(Play_Players),s.play_players,proc(dst:rawptr) {(^Play_Players)(dst)^=PLAY_PLAYERS_DEFAULT}},
        {"Play_History",type_info_of(Play_History),s.play_history,proc(dst:rawptr) {(^Play_History)(dst)^=PLAY_HISTORY_DEFAULT}},
        {"Ai_View",type_info_of(Ai_View),ai_view_preferences(s.ai),proc(dst:rawptr) {(^Ai_View)(dst)^=AI_VIEW_DEFAULT}},
    }
    // The areas the plugins keep.
    provided:[PROVIDER_CAPACITY]Preferences_Provider
    plugins:=provided[:provided_all(s,provided[:])]
    list:=make([dynamic]project.Setting,0,len(areas)+len(plugins),context.temp_allocator)
    for area in areas {
        if area.value!=nil {append(&list,project.Setting{name=area.name,info=area.info,value=area.value,default=area.default})}
    }
    for area in plugins {
        if value:=area.value!=nil?area.value(s):nil;value!=nil && area.info!=nil {append(&list,project.Setting{name=area.name,info=area.info,value=value,default=area.default})}
    }
    return list[:]
}

// The marks of the browser of the project and where it was left, as their
// file names them. navigation is read and written in place of Content.
@(private)
marks_list :: proc(s:^Session,navigation:^Content_Navigation) -> []project.Setting {
    list:=make([]project.Setting,2,context.temp_allocator)
    list[0]={name="Content_Marks",info=type_info_of(Content_Marks),value=&s.content.marks}
    list[1]={name="Content_Navigation",info=type_info_of(Content_Navigation),value=navigation}
    return list
}

@(private)
preferences_hash :: proc(list:[]project.Setting) -> (h:u64) {
    h=base.HASH_SEED
    for setting in list {h=base.hash64(([^]u8)(setting.value)[:setting.info.size],h)}
    return
}

// Where this editor keeps its preferences, and what the file has over the
// values of the code. A file that cannot be read is said and left as it is.
preferences_open :: proc(s:^Session,options:Options) {
    p:=s.preferences
    if options.headless && !options.preferences {return}
    folder:=project.machine_folder(s.engine_root,context.temp_allocator)
    if folder=="" {return}
    p.file=project.path(folder,PREFERENCES_FILE)
    list:=preferences_list(s)
    if error:=project.settings_read(p.file,list);error.code!=.None {notify(s,settings_file_error_text(p.file,error))}
    p.written=preferences_hash(list)
    if s.project_root!="" && s.content!=nil {
        p.marks_file=project.path(project.folder_path(s.project_root,.Generated,context.temp_allocator),MARKS_FILE)
        navigation:=content_navigation(s.content)
        marks:=marks_list(s,&navigation)
        if error:=project.settings_read(p.marks_file,marks);error.code!=.None {notify(s,settings_file_error_text(p.marks_file,error))}
        content_navigation_set(s.content,&navigation)
        p.marks_written=preferences_hash(marks)
    }
}

// Writes the preferences that changed since the file was written. While a
// Play runs the layout is that of the Play: the one of editing waits for Stop.
preferences_save :: proc(s:^Session) {
    p:=s.preferences
    if p==nil || s.mode!=.Edit {return}
    if p.marks_file!="" {
        navigation:=content_navigation(s.content)
        marks:=marks_list(s,&navigation)
        if h:=preferences_hash(marks);h!=p.marks_written {
            below:=project.settings_clone(marks,context.temp_allocator)
            project.settings_default(below)
            if error:=project.settings_write(p.marks_file,marks,below);error.code!=.None {notify(s,settings_file_error_text(p.marks_file,error))}
            p.marks_written=h
        }
    }
    if p.file=="" {return}
    list:=preferences_list(s)
    h:=preferences_hash(list)
    if h==p.written {return}
    below:=project.settings_clone(list,context.temp_allocator)
    if len(below)!=len(list) {return}
    project.settings_default(below)
    if error:=project.settings_write(p.file,list,below);error.code!=.None {notify(s,settings_file_error_text(p.file,error))}
    p.written=h
}

// Once a frame: a change is written when the UI has rested PREFERENCES_REST
// seconds since the last gesture, and checked again every as many seconds.
@(private)
preferences_update :: proc(s:^Session,ctx:^ui.Context,dt:f32) {
    p:=s.preferences
    if p==nil || p.file=="" && p.marks_file=="" {return}
    in_:=&ctx.input
    if ctx.active!=0 || ctx.edit.id!=0 || in_.down!={} || in_.pressed!={} || in_.wheel!={} || s.gui.splitter!=.None || s.inspector!=nil && s.inspector.gesture!=0 {
        p.rest=0
        return
    }
    p.rest+=dt
    if p.rest<PREFERENCES_REST {return}
    p.rest=0
    preferences_save(s)
}

@(private)
preferences_close :: proc(s:^Session) {
    p:=s.preferences
    if p==nil {return}
    preferences_save(s)
    delete(p.file)
    delete(p.marks_file)
    p^={}
}

// ---------------------------------------------------------------- API

Api_Preferences_Get_Params :: struct {
    sections:[API_SECTIONS][64]u8 `mirai:"text,optional,label=Only these areas, by the names preferences gives them; none: every area"`,
}

Api_Preferences :: struct {
    file:[512]u8 `mirai:"text,label=The file that keeps them; empty: this editor keeps none (--headless without --preferences) and a change lasts until it closes"`,
    preferences:u8 `mirai:"any,label=Every value in effect: a section per area of the editor with its fields"`,
    kept:u8 `mirai:"any,label=The sections and fields the file sets over the values of the code"`,
}

@(private)
API_PREFERENCES_SET_SCHEMA :: `{"type":"object","properties":{"preferences":{"type":"object","additionalProperties":{"type":"object"},"description":"{\"<Area>\": {\"<field>\": value}}: an object of areas as preferences.get names them, each with the fields to change"}},"required":["preferences"],"additionalProperties":false}`

@(private)
preferences_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="preferences.get",summary="The preferences of the editor on this machine, the same for every project: its panels, viewport, lists, console, Play and chats, and of the plugins.",params=Api_Preferences_Get_Params,result=Api_Preferences,writes_result=true,flags={.Read_Only},run=api_preferences_get})
    api_register(s,st,{name="preferences.set",params_schema=API_PREFERENCES_SET_SCHEMA,summary="Changes preferences of the editor; they take effect at once, the file keeps what differs from the values of the code and it answers with the areas changed.",result=Api_Preferences,writes_result=true,run=api_preferences_set})
}

@(private)
api_preferences_get :: proc(s:^Session,call:^api.Call) {
    keep,named:=api_sections_kept(call,api.call_params(call,Api_Preferences_Get_Params).sections[:],preferences_list(s),"preference area")
    if named {api_preferences_write(s,call,keep)}
}

// The answer of preferences.get for the areas of a mask (nil: all), and of
// preferences.set for those it changed.
@(private)
api_preferences_write :: proc(s:^Session,call:^api.Call,keep:[]bool) {
    list:=preferences_list(s)
    code:=project.settings_clone(list,context.temp_allocator)
    if len(code)!=len(list) {
        api.call_fail(call,api.SERVER_ERROR,"There is no memory to read the preferences")
        return
    }
    project.settings_default(code)
    out:=call.out
    serial.text_write_raw(out,`{"file": `)
    serial.text_write_string(out,s.preferences!=nil?s.preferences.file:"")
    serial.text_write_raw(out,`, "preferences": `)
    shown:=settings_kept(list,keep)
    serial.text_write_raw(out,strings.trim_space(project.settings_text(shown,{},{},context.temp_allocator)))
    serial.text_write_raw(out,`, "kept": `)
    serial.text_write_raw(out,strings.trim_space(project.settings_text(shown,settings_kept(code,keep),{},context.temp_allocator)))
    serial.write_u8(out,'}')
}

// Read into copies and checked against the fields of each area: a change that
// fails leaves every preference as it was.
@(private)
api_preferences_set :: proc(s:^Session,call:^api.Call) {
    USAGE :: `params are {"preferences": {"<Area>": {"<field>": value}}}`
    r:serial.Text_Reader
    serial.text_reader_init(&r,call.raw,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    sections:=""
    if serial.text_accept(&r,'{') && !serial.text_accept(&r,'}') {
        key,named:=serial.text_string(&r)
        if named && key=="preferences" && serial.text_expect(&r,':') && serial.text_peek(&r)=='{' {
            start:=r.offset
            if serial.text_skip(&r) {sections=r.text[start:r.offset]}
        }
        if !serial.text_expect(&r,'}') || !serial.text_end(&r) {sections=""}
    }
    if sections=="" {
        api.call_fail(call,api.INVALID_PARAMS,USAGE)
        return
    }
    list:=preferences_list(s)
    next:=project.settings_clone(list,context.temp_allocator)
    if len(next)!=len(list) {
        api.call_fail(call,api.SERVER_ERROR,"There is no memory to read the preferences")
        return
    }
    for name in settings_section_names(sections) {
        known:=false
        for area in list {known|=area.name==name}
        if known {continue}
        names:=make([dynamic]string,context.temp_allocator)
        for area in list {append(&names,area.name)}
        api.call_failf(call,api.INVALID_PARAMS,"%s is not an area of the preferences: they are %s",name,strings.join(names[:],", ",context.temp_allocator))
        return
    }
    if error:=project.settings_parse(sections,next,strict=true);error.code!=.None {
        api.call_failf(call,api.INVALID_PARAMS,"preferences: %s at line %d, column %d",error.detail,error.line,error.column)
        return
    }
    for area in next {
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        type,_:=serial.schema_add_type_info(&schema,area.info)
        check,valid:=api.value_check(&schema,type,([^]u8)(area.value)[:area.info.size],area.name,context.temp_allocator)
        serial.schema_destroy(&schema)
        if !valid {
            api.call_fail(call,api.INVALID_PARAMS,check)
            return
        }
    }
    for area,i in next {mem.copy(list[i].value,area.value,area.info.size)}
    preferences_save(s)
    api_preferences_write(s,call,settings_touched(list,sections))
}
