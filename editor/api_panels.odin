package editor

import "core:fmt"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"

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
    file:[API_PATH_BYTES]u8 `mirai:"text,label=panels/<id>.mirai of the project: where it is kept"`,
    panel:Api_Panel_File `mirai:"label=As its file keeps it"`,
}
Api_Panel_File :: struct {
    title:[PANEL_TITLE_BYTES]u8 `mirai:"text"`,
    buttons:[]Api_Panel_Button `mirai:"optional"`,
    rows:[]Api_Panel_Row `mirai:"optional,label=Its headings and fields as panel.save takes them"`,
}
Api_Panel_Button :: struct {
    name:[PANEL_TITLE_BYTES]u8 `mirai:"text,label=What panel.apply takes as button"`,
    sets:[]Api_Panel_Set `mirai:"label=The fields it sets and their values as panel.save takes them"`,
}
Api_Panel_Set :: struct {
    component:[PANEL_NAME_BYTES]u8 `mirai:"text,optional"`,
    setting:[PANEL_NAME_BYTES]u8 `mirai:"text,optional,label=A section of the settings"`,
    field:[PANEL_FIELD_BYTES]u8 `mirai:"text"`,
    entity:base.Entity_Id `mirai:"optional"`,
    match:serial.Json `mirai:"optional,name=where,label=The fields an entity must have; {} is every entity with the component"`,
    value:serial.Json `mirai:"label=The JSON the field takes"`,
}
Api_Panel_Row :: struct {
    heading:[PANEL_TITLE_BYTES]u8 `mirai:"text,optional"`,
    component:[PANEL_NAME_BYTES]u8 `mirai:"text,optional"`,
    setting:[PANEL_NAME_BYTES]u8 `mirai:"text,optional"`,
    field:[PANEL_FIELD_BYTES]u8 `mirai:"text,optional"`,
    entity:base.Entity_Id `mirai:"optional"`,
    match:serial.Json `mirai:"optional,name=where"`,
    label:[PANEL_TITLE_BYTES]u8 `mirai:"text,optional"`,
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

@(private)
API_PANEL_TARGET :: `"component":{"type":"string"},"field":{"type":"string","description":"A field of the component; a nested one by its path with dots."},"entity":{"type":"string","description":"Whose component, by its id; with neither entity nor where: the first entity that has it."}`
@(private)
API_PANEL_SAVE_SCHEMA :: `{"type":"object","properties":{` +
    `"id":{"type":"string","description":"The panel to replace; omitted: the id its title gives. Lower case letters, digits, - and _. It is kept in panels/<id>.mirai of the project."},` +
    `"title":{"type":"string"},` +
    `"buttons":{"type":"array","maxItems":12,"description":"Each button is a variant that sets fields of components or settings to values when pressed (on one entity or on every entity a where matches; the fields left out of the rows), those of the scene as one undo step. A folded Attributes section of the panel lists what the buttons set. A panel has buttons, rows or both.","items":{"type":"object","properties":{"name":{"type":"string","description":"Unique in the panel."},"sets":{"type":"array","minItems":1,"maxItems":12,"items":{"oneOf":[` +
        `{"type":"object","properties":{` + API_PANEL_TARGET + `,"where":{"type":"object","description":"Every entity with the component whose fields equal these values, by path, found when the button is pressed; {}: every entity with it.","additionalProperties":{}},"value":{"description":"The JSON scene.set takes for that field."}},"required":["component","field","value"],"additionalProperties":false},` +
        `{"type":"object","properties":{"setting":{"type":"string","description":"A section of settings.get, as Graphics_Settings."},"field":{"type":"string"},"value":{"description":"The JSON settings.set takes for that field."}},"required":["setting","field","value"],"additionalProperties":false}]}}},"required":["name","sets"],"additionalProperties":false}},` +
    `"rows":{"type":"array","maxItems":32,"description":"Fields the user tunes with the controls of Details, as after pressing a button: of one entity, of every entity a where matches, or of a setting.","items":{"oneOf":[` +
        `{"type":"object","properties":{"heading":{"type":"string"}},"required":["heading"],"additionalProperties":false},` +
        `{"type":"object","properties":{` + API_PANEL_TARGET + `,"where":{"type":"object","description":"The row shows the first entity it matches and writes all of them; {}: every entity with the component.","additionalProperties":{}},"label":{"type":"string"}},"required":["component","field"],"additionalProperties":false},` +
        `{"type":"object","properties":{"setting":{"type":"string","description":"A section of settings.get, as Graphics_Settings."},"field":{"type":"string"},"label":{"type":"string"}},"required":["setting","field"],"additionalProperties":false}]}},` +
    `"open":{"type":"boolean","description":"Show it in the editor; true when omitted."}},"required":["title"],"additionalProperties":false}`

@(private)
panels_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="panel.list",summary="The panels of the project: interfaces of the editor made for the user. The Tools menu of the toolbar shows one at a time in place of Details.",result=Api_Panel_List,writes_result=true,flags={.Read_Only},run=api_panel_list})
    api_register(s,st,{name="panel.save",params_schema=API_PANEL_SAVE_SCHEMA,summary="Makes or replaces a panel of the project, the way to give the user an interface of their own (to try the environment, the post process or the lights). Checked against the project first.",result=Api_Panel,writes_result=true,run=api_panel_save})
    api_register(s,st,{name="panel.open",summary="Shows a panel of the project in the editor.",params=Api_Panel_Params,result=Api_Panel,writes_result=true,flags={.Idempotent},run=api_panel_open})
    api_register(s,st,{name="panel.close",summary="Hides a panel of the project; it stays in the Tools menu.",params=Api_Panel_Params,result=Api_Panel,writes_result=true,flags={.Idempotent},run=api_panel_close})
    api_register(s,st,{name="panel.delete",summary="Deletes a panel of the project and its file.",params=Api_Panel_Params,result=Api_Panel_Deleted,flags={.Destructive},run=api_panel_delete})
    api_register(s,st,{name="panel.restore",summary="Puts back as they were what the buttons and rows of a panel changed since the editor opened or the last restore: the scene as one undo step, the settings as the settings dialog.",params=Api_Panel_Params,result=Api_Panel_Restored,writes_result=true,run=api_panel_restore})
    api_register(s,st,{name="panel.apply",summary="Presses a button of a panel: what it sets in the scene as one undo step, the settings of the project as the settings dialog. Nothing changes when a value fails.",params=Api_Panel_Apply_Params,result=Api_Panel_Applied,writes_result=true,run=api_panel_apply})
}

@(private)
api_panel_write :: proc(s:^Session,out:^serial.Writer,p:^Project_Panel) {
    serial.write_u8(out,'{')
    api.write_text(out,"id",base.text_get(p.id[:]),true)
    api.write_text(out,"title",base.text_get(p.title[:]))
    api.write_bool(out,"open",p.open)
    api.write_text(out,"file",panel_file(s,base.text_get(p.id[:])))
    api.write_key(out,"panel")
    panel_write(out,p)
    serial.write_u8(out,'}')
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
    out:=call.out
    serial.text_write_raw(out,`{"panels": [`)
    for &p,i in s.panels.list {
        if i>0 {serial.write_u8(out,',')}
        api_panel_write(s,out,&p)
    }
    serial.text_write_raw(out,"]}")
}

@(private)
api_panel_save :: proc(s:^Session,call:^api.Call) {
    panels:=s.panels
    panels_sync(s,panels)
    if s.project_root=="" {
        api.call_fail(call,api.INVALID_PARAMS,"The editor has no project folder to keep panels in")
        return
    }
    p:Project_Panel
    id:[PANEL_ID_BYTES]u8
    open:=true
    if message,ok:=panel_parse(call.raw,&p,&id,&open);!ok {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    name:=base.text_get(id[:])
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
    if open {panel_show(s,panels,at,true)}
    api_panel_write(s,call.out,&panels.list[at])
}

@(private)
api_panel_open :: proc(s:^Session,call:^api.Call) {
    p:=api_panel_named(s,call,base.text_get(api.call_params(call,Api_Panel_Params).id[:]))
    if p==nil {return}
    panel_show(s,s.panels,panel_find(s.panels,base.text_get(p.id[:])),true)
    api_panel_write(s,call.out,p)
}

@(private)
api_panel_close :: proc(s:^Session,call:^api.Call) {
    p:=api_panel_named(s,call,base.text_get(api.call_params(call,Api_Panel_Params).id[:]))
    if p==nil {return}
    if p.open {panel_show(s,s.panels,-1,false)}
    api_panel_write(s,call.out,p)
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
    out:=call.out
    serial.write_u8(out,'{')
    api.write_text(out,"button",name,true)
    api.write_int(out,"changed",i64(changed))
    api.write_key(out,"of")
    api_panel_write(s,out,p)
    serial.write_u8(out,'}')
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
    out:=call.out
    serial.write_u8(out,'{')
    api.write_int(out,"restored",i64(restored),true)
    api.write_key(out,"of")
    api_panel_write(s,out,p)
    serial.write_u8(out,'}')
}
