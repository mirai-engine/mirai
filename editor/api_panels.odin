package editor

import "core:fmt"
import "mirai:editor/api"
import "mirai:std/base"
import "core:strings"

// The panels of the project through the agent API: what an agent makes when
// the user asks for an interface of their own (panels.odin).

Api_Panel_Params :: struct {
    id:[PANEL_ID_BYTES]u8 `mirai:"text,label=The id of a panel as panel.list gives it"`,
}

Api_Panel_Apply_Params :: struct {
    id:[PANEL_ID_BYTES]u8 `mirai:"text,label=The id of a panel as panel.list gives it"`,
    button:[PANEL_TITLE_BYTES]u8 `mirai:"text,label=The name of one of its buttons"`,
}

Api_Panel :: struct {
    id:[PANEL_ID_BYTES]u8 `mirai:"text,label=What the other panel methods take"`,
    title:[PANEL_TITLE_BYTES]u8 `mirai:"text"`,
    open:bool `mirai:"label=Shown in the editor in place of Details"`,
    file:string `mirai:"label=panels/<id>.mirai of the project: where it is kept"`,
    panel:Panel_File `mirai:"label=As its file keeps it"`,
}
Api_Panel_List :: struct {panels:[]Api_Panel}
Api_Panel_Deleted :: struct {deleted:[PANEL_ID_BYTES]u8 `mirai:"text,label=The id of the panel"`}
Api_Panel_Applied :: struct {
    button:[PANEL_TITLE_BYTES]u8 `mirai:"text"`,
    changed:int `mirai:"label=Entities and settings it set"`,
    of:Api_Panel,
}
Api_Panel_Restored :: struct {
    restored:int `mirai:"label=Fields it put back"`,
    of:Api_Panel,
}

Api_Panel_Save_Params :: struct {
    id:[PANEL_ID_BYTES]u8 `mirai:"text,optional,label=The panel to replace; omitted: the id its title gives. Lower case letters, digits, - and _"`,
    open:bool `mirai:"optional,label=Show it in the editor"`,
    file:Panel_File `mirai:"inline"`,
}

@(private)
panels_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="panel.list",summary="The panels of the project: interfaces of the editor made for the user. The Tools menu of the toolbar shows one at a time in place of Details.",result=type_info_of(Api_Panel_List),flags={.Read_Only},run=api_panel_list})
    save:=Api_Panel_Save_Params{open=true}
    api_register(s,st,{name="panel.save",params=type_info_of(Api_Panel_Save_Params),defaults=&save,summary="Makes or replaces a panel of the project, the way to give the user an interface of their own (to try the environment, the post process or the lights). Checked against the project first.",result=type_info_of(Api_Panel),run=api_panel_save})
    api_register(s,st,{name="panel.open",summary="Shows a panel of the project in the editor.",params=type_info_of(Api_Panel_Params),result=type_info_of(Api_Panel),flags={.Idempotent},run=api_panel_open})
    api_register(s,st,{name="panel.close",summary="Hides a panel of the project; it stays in the Tools menu.",params=type_info_of(Api_Panel_Params),result=type_info_of(Api_Panel),flags={.Idempotent},run=api_panel_close})
    api_register(s,st,{name="panel.delete",summary="Deletes a panel of the project and its file.",params=type_info_of(Api_Panel_Params),result=type_info_of(Api_Panel_Deleted),flags={.Destructive},run=api_panel_delete})
    api_register(s,st,{name="panel.restore",summary="Puts back as they were what the buttons and rows of a panel changed since the editor opened or the last restore: the scene as one undo step, the settings as the settings dialog.",params=type_info_of(Api_Panel_Params),result=type_info_of(Api_Panel_Restored),run=api_panel_restore})
    api_register(s,st,{name="panel.apply",summary="Presses a button of a panel: what it sets in the scene as one undo step, the settings of the project as the settings dialog. Nothing changes when a value fails.",params=type_info_of(Api_Panel_Apply_Params),result=type_info_of(Api_Panel_Applied),run=api_panel_apply})
}

@(private)
api_panel_of :: proc(s:^Session,call:^api.Call,p:^Project_Panel) -> Api_Panel {
    return {p.id,p.title,p.open,strings.clone(panel_file(s,base.text_get(p.id[:])),call.allocator),panel_file_of(p,call.allocator)}
}

// The panel the params name, or a failure that lists those there are.
@(private)
api_panel_named :: proc(s:^Session,call:^api.Call,id:string) -> ^Project_Panel {
    panels_sync(s,s.panels)
    if at:=panel_find(s.panels,id);at>=0 {return &s.panels.list[at]}
    names:=make([dynamic]u8,context.temp_allocator)
    for &p,i in s.panels.list {
        if i>0 {append(&names,", ")}
        append(&names,base.text_get(p.id[:]))
    }
    if len(names)==0 {
        api.call_failf(call,api.INVALID_PARAMS,"%q is not a panel: the project has none; panel.save makes one",id)
    } else {
        api.call_failf(call,api.INVALID_PARAMS,"%q is not a panel; the panels are %s",id,string(names[:]))
    }
    return nil
}

@(private)
api_panel_list :: proc(s:^Session,call:^api.Call) {
    panels_sync(s,s.panels)
    panels:=make([]Api_Panel,len(s.panels.list),call.allocator)
    for &p,i in s.panels.list {panels[i]=api_panel_of(s,call,&p)}
    api.call_result(call,Api_Panel_List).panels=panels
}

@(private)
api_panel_save :: proc(s:^Session,call:^api.Call) {
    panels:=s.panels
    panels_sync(s,panels)
    if s.project_root=="" {
        api.call_fail(call,api.INVALID_PARAMS,"The editor has no project folder to keep panels in")
        return
    }
    params:=api.call_params(call,Api_Panel_Save_Params)
    p:Project_Panel
    if message:=panel_from_file(&params.file,&p);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    name:=base.text_get(params.id[:])
    if name=="" {name=panel_id_of(base.text_get(p.title[:]))}
    if message:=panel_id_check(name);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    if panel_find(panels,name)<0 && len(panels.list)>=PANEL_CAPACITY {
        api.call_failf(call,api.INVALID_PARAMS,"A project holds %d panels: replace one by its id or delete one with panel.delete",PANEL_CAPACITY)
        return
    }
    base.text_set(p.id[:],name)
    if message:=panel_check(s,&p);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    at,problem:=panel_store(s,panels,p)
    if problem!="" {
        api.call_fail(call,api.SERVER_ERROR,problem)
        return
    }
    if params.open {panel_show(s,panels,at,true)}
    api.call_result(call,Api_Panel)^=api_panel_of(s,call,&panels.list[at])
}

@(private)
api_panel_open :: proc(s:^Session,call:^api.Call) {
    p:=api_panel_named(s,call,base.text_get(api.call_params(call,Api_Panel_Params).id[:]))
    if p==nil {return}
    panel_show(s,s.panels,panel_find(s.panels,base.text_get(p.id[:])),true)
    api.call_result(call,Api_Panel)^=api_panel_of(s,call,p)
}

@(private)
api_panel_close :: proc(s:^Session,call:^api.Call) {
    p:=api_panel_named(s,call,base.text_get(api.call_params(call,Api_Panel_Params).id[:]))
    if p==nil {return}
    if p.open {panel_show(s,s.panels,-1,false)}
    api.call_result(call,Api_Panel)^=api_panel_of(s,call,p)
}

@(private)
api_panel_delete :: proc(s:^Session,call:^api.Call) {
    p:=api_panel_named(s,call,base.text_get(api.call_params(call,Api_Panel_Params).id[:]))
    if p==nil {return}
    id:=fmt.tprintf("%s",base.text_get(p.id[:]))
    if !panel_delete(s,s.panels,panel_find(s.panels,id)) {
        api.call_failf(call,api.SERVER_ERROR,"%s cannot be deleted",panel_file(s,id))
        return
    }
    base.text_set(api.call_result(call,Api_Panel_Deleted).deleted[:],id)
}

@(private)
api_panel_apply :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Panel_Apply_Params)
    p:=api_panel_named(s,call,base.text_get(params.id[:]))
    if p==nil {return}
    name:=base.text_get(params.button[:])
    button:=-1
    for &other,i in p.buttons[:p.button_count] {
        if base.text_get(other.name[:])==name {button=i;break}
    }
    if button<0 {
        names:=make([dynamic]u8,context.temp_allocator)
        for &other,i in p.buttons[:p.button_count] {
            if i>0 {append(&names,", ")}
            append(&names,base.text_get(other.name[:]))
        }
        api.call_failf(call,api.INVALID_PARAMS,"%q is not a button of %s; its buttons are %s",name,base.text_get(p.id[:]),len(names)>0?string(names[:]):"none")
        return
    }
    if !api_edit_begin(s,call,fmt.tprintf("%s: %s",base.text_get(p.title[:]),name)) {return}
    changed,problem:=panel_press(s,p,button)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem)}
    if !api_edit_end(s,call,problem=="") {return}
    settings_flush(s)
    api.call_result(call,Api_Panel_Applied)^={params.button,changed,api_panel_of(s,call,p)}
}

@(private)
api_panel_restore :: proc(s:^Session,call:^api.Call) {
    p:=api_panel_named(s,call,base.text_get(api.call_params(call,Api_Panel_Params).id[:]))
    if p==nil {return}
    if !api_edit_begin(s,call,fmt.tprintf("%s: Restore",base.text_get(p.title[:]))) {return}
    restored,problem:=panel_restore(s,p)
    if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem)}
    if !api_edit_end(s,call,problem=="") {return}
    settings_flush(s)
    api.call_result(call,Api_Panel_Restored)^={restored,api_panel_of(s,call,p)}
}
