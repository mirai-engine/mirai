package editor

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// Copy and Paste of values, on the right click of the label of a field, the
// header of a component and Add component. The text is the JSON of the API:
// a component as an object under its name, as in `components`; the Transform
// as position, rotation_deg and scale; a field as its value; a reference to
// an entity as its id. Paste checks the whole text before it writes, and
// writes to every selected entity that has the component in one step; on Add
// component it adds or replaces the components the text names.

INSPECTOR_CLIPBOARD_BYTES :: 64*1024

Value_Menu_Kind :: enum u8 {None,Field,Component,Components,Transform,Transform_Field}

Value_Menu :: struct {
    kind:Value_Menu_Kind,
    table:int,               // of the world info: the component
    offset:int,              // of the field in it
    type:serial.Type_Index,  // of the field, in the schema of the world
    transform:Transform_Field,
    label:[48]u8,
}

@(private)
value_menu_popup :: proc(g:^Editor_Ui) -> ui.Id {return shell_id(g,"value_menu")}

@(private)
value_menu_open :: proc(s:^Session,menu:Value_Menu,label:string) {
    ctx:=s.gui.ctx
    s.inspector.menu=menu
    base.text_set(s.inspector.menu.label[:],label)
    ui.popup_open(ctx,value_menu_popup(s.gui),{ctx.pointer.x,ctx.pointer.y,1,1})
}

// The row of a field takes the right click that its controls leave: they
// are registered after it and win where they are.
@(private)
value_menu_row :: proc(s:^Session,id:ui.Id,menu:Value_Menu,label:string) {
    if ui.interact(s.gui.ctx,id).right {value_menu_open(s,menu,label)}
}

@(private)
value_menu_build :: proc(s:^Session,w:core.World_Ref) {
    ins:=s.inspector
    if ins.menu.kind==.None {return}
    ctx:=s.gui.ctx
    popup:=value_menu_popup(s.gui)
    if !ui.popup_is_open(ctx,popup) {
        ins.menu={}
        return
    }
    if ui.popup(ctx,popup,{min_width=ui.MENU_CHOICE_WIDTH}) {
        menu:=ins.menu
        if menu.kind!=.Components && ui.menu_item(ctx,ui.id_derive(ctx,popup,"copy"),"Copy") {
            if message:=value_copy(s,w,menu);message!="" {notify(s,message)}
        }
        if ui.menu_item(ctx,ui.id_derive(ctx,popup,"paste"),"Paste") {
            if message:=value_paste(s,w,menu);message!="" {notify(s,message)}
        }
        // The header of a component also gives it back its defaults or takes it from the selection.
        if menu.kind==.Component && menu.table>=0 && menu.table<len(w.info.tables) {
            t:=&w.info.tables[menu.table]
            entities:=make([dynamic]core.Entity,context.temp_allocator)
            for e in s.selection.entities {
                if entity_alive(w,e) && core.raw_find(core.world_table_at(w,t),t.info,e)!=nil {append(&entities,e)}
            }
            if ui.menu_item(ctx,ui.id_derive(ctx,popup,"reset"),"Reset",{disabled=len(entities)==0}) {
                c:=inspect_component(s,w,t.type,entities[:])
                inspect_reset(&c,0,c.size)
            }
            if ui.menu_item(ctx,ui.id_derive(ctx,popup,"remove"),"Remove",{disabled=len(entities)==0,danger=true}) {
                for e in entities {component_remove(s,e,t)}
            }
        }
    }
}

@(private)
value_menu_component :: proc(w:core.World_Ref,menu:Value_Menu,e:core.Entity) -> (t:^core.Table_Info,value:rawptr) {
    if menu.table<0 || menu.table>=len(w.info.tables) {return}
    t=&w.info.tables[menu.table]
    value=core.raw_find(core.world_table_at(w,t),t.info,e)
    return
}

// The angles the inspector shows for a rotation of an entity.
@(private)
inspector_angles :: proc(ins:^Inspector,e:core.Entity,rotation:mm.Quat) -> [3]f32 {
    if ins.euler_entity==e && ins.euler_rotation==rotation {return ins.euler*mm.DEG_PER_RAD}
    return mm.quat_to_euler(rotation)*mm.DEG_PER_RAD
}

// Writes the value the menu names, of the active entity, to the clipboard.
@(private)
value_copy :: proc(s:^Session,w:core.World_Ref,menu:Value_Menu) -> string {
    menu:=menu
    ctx:=s.gui.ctx
    if ctx.clipboard_set==nil {return "The clipboard is not available"}
    active:=history.selection_active(s.selection)
    if !entity_alive(w,active) {return ""}
    out:serial.Writer
    serial.writer_init(&out,1024,context.temp_allocator)
    switch menu.kind {
    case .None,.Components: return ""
    case .Transform,.Transform_Field:
        local:=entity_local(w,active)
        values:=[Transform_Field][3]f32{.Position=local.position,.Rotation=inspector_angles(s.inspector,active,local.rotation),.Scale=local.scale}
        if menu.kind==.Transform_Field {
            api.write_list(&out,values[menu.transform][:])
        } else {
            serial.text_write_raw(&out,`{"position":`);api.write_list(&out,values[.Position][:])
            serial.text_write_raw(&out,`,"rotation_deg":`);api.write_list(&out,values[.Rotation][:])
            serial.text_write_raw(&out,`,"scale":`);api.write_list(&out,values[.Scale][:])
            serial.write_u8(&out,'}')
        }
    case .Component,.Field:
        t,value:=value_menu_component(w,menu,active)
        if value==nil {return ""}
        bytes:=make([]u8,max(t.info.size,1),context.temp_allocator)
        api_value_out(w,t.info,value,bytes)
        schema,type,ok:=core.world_value_type(w.info,t.type)
        if !ok {return "This component has no JSON form"}
        if menu.kind==.Component {
            serial.write_u8(&out,'{');serial.text_write_string(&out,t.name);serial.write_u8(&out,':')
            serial.text_write(&out,schema,type,bytes[:t.info.size],.Line)
            serial.write_u8(&out,'}')
        } else {
            size:=int(schema.types[menu.type].size) if serial.type_valid(schema,menu.type) else 0
            if size==0 || menu.offset<0 || menu.offset+size>t.info.size {return ""}
            serial.text_write(&out,schema,menu.type,bytes[menu.offset:][:size],.Line)
        }
    }
    if out.overflow>0 {return "The value is too large to copy"}
    ctx.clipboard_set(ctx.clipboard_user,string(serial.writer_bytes(&out)))
    return fmt.tprintf("Copied %s",base.text_get(menu.label[:]))
}

@(private)
value_text_error :: proc(r:^serial.Text_Reader,path:string) -> string {
    if r.error.code==.None {return fmt.tprintf("%s: the clipboard holds more than its value",path)}
    line,column:=serial.text_position(r.text,r.error.offset)
    return fmt.tprintf("%s: the clipboard does not hold its value (line %d column %d)",path,line,column)
}

@(private)
value_read_vector :: proc(r:^serial.Text_Reader,schema:^serial.Schema) -> (value:[3]f32,ok:bool) {
    type:=serial.schema_add_type_info(schema,type_info_of([3]f32)) or_return
    ok=serial.text_read(r,schema,type,mem.ptr_to_bytes(&value))
    return
}

Value_Pending :: struct {
    e:core.Entity,
    t:^core.Table_Info,
    bytes:[]u8,
}

// Reads the clipboard into the value the menu names and writes it.
@(private)
value_paste :: proc(s:^Session,w:core.World_Ref,menu:Value_Menu) -> string {
    menu:=menu
    ctx:=s.gui.ctx
    if ctx.clipboard_get==nil {return "The clipboard is not available"}
    buffer:=make([]u8,INSPECTOR_CLIPBOARD_BYTES,context.temp_allocator)
    text:=string(buffer[:clamp(ctx.clipboard_get(ctx.clipboard_user,buffer),0,len(buffer))])
    if strings.trim_space(text)=="" {return "The clipboard is empty"}
    label:=base.text_get(menu.label[:])
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    active:=history.selection_active(s.selection)
    if !entity_alive(w,active) {return ""}
    switch menu.kind {
    case .None: return ""
    case .Transform,.Transform_Field:
        values:[Transform_Field][3]f32
        given:[Transform_Field]bool
        if menu.kind==.Transform_Field {
            value,ok:=value_read_vector(&r,&schema)
            if !ok || !serial.text_end(&r) {return value_text_error(&r,label)}
            values[menu.transform],given[menu.transform]=value,true
        } else {
            if !serial.text_expect(&r,'{') {return value_text_error(&r,label)}
            for !serial.text_accept(&r,'}') {
                if given!={} && !serial.text_expect(&r,',') {return value_text_error(&r,label)}
                key,ok:=serial.text_string(&r)
                if !ok || !serial.text_expect(&r,':') {return value_text_error(&r,label)}
                field:Transform_Field
                switch key {
                case "position": field=.Position
                case "rotation_deg": field=.Rotation
                case "scale": field=.Scale
                case: return fmt.tprintf("Transform has no field %q: position, rotation_deg and scale",key)
                }
                value,read:=value_read_vector(&r,&schema)
                if !read {return value_text_error(&r,label)}
                values[field],given[field]=value,true
            }
            if !serial.text_end(&r) {return value_text_error(&r,label)}
        }
        for value in values {if !finite3(value) {return fmt.tprintf("%s: the clipboard holds a number that is not finite",label)}}
        opened,edit_ready:=edit_open(s,fmt.tprintf("Paste %s",label))
        if !edit_ready {return history.edits_error_text(s.edits.error)}
        defer edit_close(s,opened)
        ins:=s.inspector
        for e in s.selection.entities {
            if !entity_alive(w,e) {continue}
            t:=entity_local(w,e)
            if given[.Position] {t.position=values[.Position]}
            if given[.Scale] {t.scale={scale_limit(values[.Scale].x),scale_limit(values[.Scale].y),scale_limit(values[.Scale].z)}}
            if given[.Rotation] {
                t.rotation=mm.quat_from_euler(values[.Rotation]*mm.RAD_PER_DEG)
                if e==active {ins.euler_entity,ins.euler_rotation,ins.euler=e,t.rotation,values[.Rotation]*mm.RAD_PER_DEG}
            }
            transform_set(s,e,t)
        }
    case .Field:
        t,value:=value_menu_component(w,menu,active)
        if value==nil {return ""}
        schema,type,ok:=core.world_value_type(w.info,t.type)
        if !ok || !serial.type_valid(schema,menu.type) {return fmt.tprintf("%s has no JSON form",label)}
        size:=int(schema.types[menu.type].size)
        if menu.offset<0 || menu.offset+size>t.info.size {return ""}
        bytes:=make([]u8,max(t.info.size,1),context.temp_allocator)
        api_value_out(w,t.info,value,bytes)
        field:=bytes[menu.offset:][:size]
        if !serial.text_read(&r,schema,menu.type,field) || !serial.text_end(&r) {return value_text_error(&r,label)}
        if message,valid:=api.value_check(schema,type,bytes[:t.info.size],readable(t.name),context.temp_allocator);!valid {return message}
        for at in w.info.schema.tables[menu.table].entities {
            if int(at)<menu.offset || int(at)>=menu.offset+size {continue}
            reference:=cast(^u64)&bytes[at]
            if reference^==0 {continue}
            target:=api_entity(w,base.Entity_Id(reference^))
            if target==core.NONE {return fmt.tprintf("%s names 0x%016x, which is not an entity of the scene",label,reference^)}
            reference^=u64(target)
        }
        table:=core.world_table_at(w,t)
        targets:=make([dynamic]core.Entity,context.temp_allocator)
        for e in s.selection.entities {
            if core.raw_find(table,t.info,e)!=nil {append(&targets,e)}
        }
        field_write(s,t,targets[:],menu.offset,field)
    case .Component:
        t,value:=value_menu_component(w,menu,active)
        if value==nil {return ""}
        schema,type,ok:=core.world_value_type(w.info,t.type)
        if !ok {return fmt.tprintf("%s has no JSON form",label)}
        // The object of the component, under its name or alone.
        wrapped:=false
        probe:=r
        if serial.text_accept(&probe,'{') {
            if key,named:=serial.text_string(&probe);named && key==t.name && serial.text_expect(&probe,':') {r.offset,wrapped=probe.offset,true}
        }
        start:=r.offset
        table:=core.world_table_at(w,t)
        pending:=make([dynamic]Value_Pending,context.temp_allocator)
        for e in s.selection.entities {
            current:=core.raw_find(table,t.info,e)
            if current==nil {continue}
            r.offset,r.error=start,{}
            bytes:=make([]u8,max(t.info.size,1),context.temp_allocator)
            if message,valid:=component_value_read(w,t,current,schema,type,&r,bytes[:t.info.size],readable(t.name),context.temp_allocator);!valid {return message}
            if wrapped && !serial.text_expect(&r,'}') || !serial.text_end(&r) {return value_text_error(&r,label)}
            append(&pending,Value_Pending{e,t,bytes})
        }
        value_pending_apply(s,pending[:],label)
    case .Components:
        pending:=make([dynamic]Value_Pending,context.temp_allocator)
        if !serial.text_expect(&r,'{') {return value_text_error(&r,"Components")}
        first:=true
        for !serial.text_accept(&r,'}') {
            if !first && !serial.text_expect(&r,',') {return value_text_error(&r,"Components")}
            first=false
            name,ok:=serial.text_string(&r)
            if !ok || !serial.text_expect(&r,':') {return value_text_error(&r,"Components")}
            t:=component_table(s,name)
            if t==nil || t.place!=.World || !inspector_listed(s,t) {return fmt.tprintf("%q is not a component that Paste adds",name)}
            schema,type,typed:=core.world_value_type(w.info,t.type)
            if !typed {return fmt.tprintf("%s has no JSON form",name)}
            table:=core.world_table_at(w,t)
            start:=r.offset
            for e in s.selection.entities {
                if !entity_alive(w,e) {continue}
                r.offset,r.error=start,{}
                bytes:=make([]u8,max(t.info.size,1),context.temp_allocator)
                if message,valid:=component_value_read(w,t,core.raw_find(table,t.info,e),schema,type,&r,bytes[:t.info.size],name,context.temp_allocator);!valid {return message}
                append(&pending,Value_Pending{e,t,bytes})
            }
        }
        if !serial.text_end(&r) {return value_text_error(&r,"Components")}
        value_pending_apply(s,pending[:],"components")
    }
    return ""
}

@(private)
value_pending_apply :: proc(s:^Session,pending:[]Value_Pending,label:string) {
    if len(pending)==0 {return}
    opened,edit_ready:=edit_open(s,fmt.tprintf("Paste %s",label))
    if !edit_ready {return}
    defer edit_close(s,opened)
    for p in pending {component_add(s,p.e,p.t,raw_data(p.bytes))}
    core.world_settle(editing_world(s))
}
