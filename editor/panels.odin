package editor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:editor/history"
import "mirai:project"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"
import "mirai:editor/api"

// Panels of the project: interfaces an agent of the AI chat makes on request,
// each a file of panels/ in the project. Buttons set fields of components of
// the scene and of settings, each to a value, on one entity, on the first that
// has the component or on every entity whose fields match; rows show fields
// with the controls of Details, on one entity or on all a where matches; a
// folded Attributes section shows what the buttons change; Restore puts back
// what the panel changed as it was before. A change of the scene is a step of
// the history, one of a setting as the settings dialog makes it. The Tools
// menu shows one panel at a time in place of Details, as the tool of a plugin;
// Escape or another selection closes it, and its header deletes it.

PANEL_EXTENSION :: ".mirai"
PANEL_CAPACITY :: 32
PANEL_ROWS :: 32
PANEL_BUTTONS :: 12
PANEL_SETS :: 12   // of a button
PANEL_ID_BYTES :: 48
PANEL_TITLE_BYTES :: 48
PANEL_NAME_BYTES :: 64
PANEL_FIELD_BYTES :: 96
PANEL_MATCH_BYTES :: 128
PANEL_VALUE_BYTES :: 160

@(private) PANELS_SCOPE :: ui.Id(0x70616e6c)

Panel_Row_Kind :: enum u8 {Heading,Component,Setting}

// A field of a component or a setting, and whose.
Panel_Target :: struct {
    kind:Panel_Row_Kind,
    target:[PANEL_NAME_BYTES]u8,  // the component or the setting
    field:[PANEL_FIELD_BYTES]u8,  // a field of it, a nested one by its path with dots
    entity:base.Entity_Id,        // a component: whose; 0: the first entity that has it, or those match names
    match:[PANEL_MATCH_BYTES]u8,  // a component: JSON of the fields an entity must have, by path; {} every entity with it; empty: one entity
}

Panel_Row :: struct {
    using place:Panel_Target,
    label:[PANEL_TITLE_BYTES]u8,  // a Heading: its text; otherwise the label of the field, or empty for its name
}

// A field a button sets, and the JSON of its value.
Panel_Set :: struct {
    using place:Panel_Target,
    value:[PANEL_VALUE_BYTES]u8,
}

Panel_Button :: struct {
    name:[PANEL_TITLE_BYTES]u8,
    sets:[PANEL_SETS]Panel_Set,
    set_count:int,
}

Project_Panel :: struct {
    id:[PANEL_ID_BYTES]u8,        // the name of its file, without the extension
    title:[PANEL_TITLE_BYTES]u8,
    buttons:[PANEL_BUTTONS]Panel_Button,
    button_count:int,
    rows:[PANEL_ROWS]Panel_Row,
    row_count:int,
    open:bool,
    attributes:bool,              // the Attributes section is unfolded
    scroll:[2]f32,
}

@(storage,free="panels_free")
Project_Panels :: struct {
    list:[dynamic]Project_Panel, // by id
    root:u64,                    // the hash of the project folder they were read from, plus one
    kept:[dynamic]Panel_Kept,    // what the panels changed was, until Restore, in the order they changed it
    kept_bytes:[dynamic]u8,
    selection:core.Entity,       // selected when the open panel was shown: another selection closes it
}

// A field a panel changed, and what it was: of a component of an entity, or
// of a setting (table nil).
Panel_Kept :: struct {
    panel:u64, // the hash of its id
    table:^core.Table_Info,
    entity:core.Entity,
    storage:int,
    offset,size:int,
    at:int,    // in kept_bytes
}

panels_free :: proc(panels:^Project_Panels) {
    delete(panels.list)
    delete(panels.kept)
    delete(panels.kept_bytes)
    panels^={}
}

@(private)
panel_folder :: proc(s:^Session) -> string {return project.folder_path(s.project_root,.Panels,context.temp_allocator)}

@(private)
panel_file :: proc(s:^Session,id:string) -> string {
    return project.path(panel_folder(s),fmt.tprintf("%s%s",id,PANEL_EXTENSION),allocator=context.temp_allocator)
}

@(private)
panel_find :: proc(panels:^Project_Panels,id:string) -> int {
    for &p,i in panels.list {
        if base.text_get(p.id[:])==id {return i}
    }
    return -1
}

// Reads the panels of the project folder once per folder: a file that does
// not read is left out and said in the console.
@(private)
panels_sync :: proc(s:^Session,panels:^Project_Panels) {
    root:=base.name_hash(s.project_root)+1
    if panels.root==root {return}
    panels.root=root
    clear(&panels.list)
    clear(&panels.kept)
    clear(&panels.kept_bytes)
    if s.project_root=="" {return}
    entries,error:=os.read_all_directory_by_path(panel_folder(s),context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if entry.type!=.Regular || !strings.has_suffix(entry.name,PANEL_EXTENSION) {continue}
        id:=strings.trim_suffix(entry.name,PANEL_EXTENSION)
        if message:=panel_id_check(id);message!="" {
            log.warnf("%s: %s",entry.fullpath,message)
            continue
        }
        if len(panels.list)>=PANEL_CAPACITY {
            log.warnf("%s: a project holds %d panels",entry.fullpath,PANEL_CAPACITY)
            continue
        }
        text,read_error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if read_error!=nil {
            log.warnf("%s: it cannot be read",entry.fullpath)
            continue
        }
        p:Project_Panel
        if message:=panel_read(string(text),&p);message!="" {
            log.warnf("%s: %s",entry.fullpath,message)
            continue
        }
        base.text_set(p.id[:],id)
        panel_insert(panels,p)
    }
}

// Keeps the list in the order of the ids.
@(private)
panel_insert :: proc(panels:^Project_Panels,p:Project_Panel) -> int {
    p:=p
    at:=len(panels.list)
    for &other,i in panels.list {
        if strings.compare(base.text_get(p.id[:]),base.text_get(other.id[:]))<0 {at=i;break}
    }
    inject_at(&panels.list,at,p)
    return at
}

// An id is what names its file: lower case letters, digits, - and _.
@(private)
panel_id_check :: proc(id:string) -> string {
    if id=="" {return "the id is empty"}
    if len(id)>=PANEL_ID_BYTES {return fmt.tprintf("the id %q is longer than %d bytes",id,PANEL_ID_BYTES-1)}
    for c in transmute([]u8)id {
        switch c {
        case 'a'..='z','0'..='9','-','_':
        case: return fmt.tprintf("the id %q has %q: an id has lower case letters, digits, - and _",id,rune(c))
        }
    }
    return ""
}

// The id a title gives: its letters and digits in lower case, the rest as -.
@(private)
panel_id_of :: proc(title:string) -> string {
    out:=make([dynamic]u8,0,len(title),context.temp_allocator)
    for c in transmute([]u8)title {
        switch c {
        case 'a'..='z','0'..='9': append(&out,c)
        case 'A'..='Z':           append(&out,c-'A'+'a')
        case:                     if len(out)>0 && out[len(out)-1]!='-' {append(&out,'-')}
        }
        if len(out)>=PANEL_ID_BYTES-1 {break}
    }
    id:=strings.trim(string(out[:]),"-")
    return id!=""?id:"panel"
}

// ---------------------------------------------------------------- the file

// A panel as panels/<id>.mirai keeps it and panel.save takes it; its id is
// the name of its file.
Panel_File :: struct {
    title:[PANEL_TITLE_BYTES]u8 `mirai:"text"`,
    buttons:[]Panel_File_Button `mirai:"optional,label=Each a variant that sets fields of components or settings to values when pressed, on one entity or on every entity a where matches; those of the scene as one undo step"`,
    rows:[]Panel_File_Row `mirai:"optional,label=Headings, and fields the user tunes with the controls of Details: of one entity, of every entity a where matches, or of a setting"`,
}
Panel_File_Button :: struct {
    name:[PANEL_TITLE_BYTES]u8 `mirai:"text,label=Unique in the panel; what panel.apply takes as button"`,
    sets:[]Panel_File_Set `mirai:"label=The fields it sets: a component with entity, where or neither (the first entity that has it), or a setting"`,
}
Panel_File_Set :: struct {
    component:[PANEL_NAME_BYTES]u8 `mirai:"text,optional"`,
    setting:[PANEL_NAME_BYTES]u8 `mirai:"text,optional,label=A section of the settings"`,
    field:[PANEL_FIELD_BYTES]u8 `mirai:"text,label=A field of it, a nested one by its path with dots"`,
    entity:base.Entity_Id `mirai:"optional"`,
    match:serial.Json `mirai:"optional,name=where,label=The fields an entity must have; {} is every entity with the component"`,
    value:serial.Json `mirai:"label=The JSON the field takes"`,
}
Panel_File_Row :: struct {
    heading:[PANEL_TITLE_BYTES]u8 `mirai:"text,optional"`,
    component:[PANEL_NAME_BYTES]u8 `mirai:"text,optional"`,
    setting:[PANEL_NAME_BYTES]u8 `mirai:"text,optional"`,
    field:[PANEL_FIELD_BYTES]u8 `mirai:"text,optional"`,
    entity:base.Entity_Id `mirai:"optional"`,
    match:serial.Json `mirai:"optional,name=where"`,
    label:[PANEL_TITLE_BYTES]u8 `mirai:"text,optional,label=Of the field; its name when left out"`,
}

// Reads a panel from the text of its file; what is wrong with it, or "".
@(private)
panel_read :: proc(text:string,p:^Project_Panel) -> string {
    file:Panel_File
    if problem:=serial.text_decode(text,&file,context.temp_allocator);problem!="" {return problem}
    return panel_from_file(&file,p)
}

// A panel from its file. It checks the shape, not the names of components and
// fields: panel_check does.
@(private)
panel_from_file :: proc(file:^Panel_File,p:^Project_Panel) -> string {
    p^={title=file.title}
    if base.text_get(p.title[:])=="" {return "title is missing"}
    if len(file.buttons)==0 && len(file.rows)==0 {return "a panel has buttons, rows or both"}
    if len(file.buttons)>PANEL_BUTTONS {return fmt.tprintf("a panel has up to %d buttons",PANEL_BUTTONS)}
    if len(file.rows)>PANEL_ROWS {return fmt.tprintf("a panel has up to %d rows",PANEL_ROWS)}
    for &b,i in file.buttons {
        at:=fmt.tprintf("buttons[%d]",i)
        name:=base.text_get(b.name[:])
        if name=="" {return fmt.tprintf("%s: name is missing",at)}
        if len(b.sets)==0 {return fmt.tprintf("%s: sets is empty: a button sets at least one field",at)}
        if len(b.sets)>PANEL_SETS {return fmt.tprintf("%s: a button sets up to %d fields",at,PANEL_SETS)}
        for &other in p.buttons[:i] {
            if base.text_get(other.name[:])==name {return fmt.tprintf("%s: %q is the name of another button",at,name)}
        }
        button:=&p.buttons[i]
        button.name,button.set_count=b.name,len(b.sets)
        for &set,k in b.sets {
            set_at:=fmt.tprintf("%s.sets[%d]",at,k)
            if problem:=panel_target_of(&button.sets[k].place,false,"",base.text_get(set.component[:]),base.text_get(set.setting[:]),set.field,set.entity,string(set.match));problem!="" {return fmt.tprintf("%s: %s",set_at,problem)}
            value:=strings.trim_space(string(set.value))
            if value=="" {return fmt.tprintf("%s: value is missing: the JSON the field takes",set_at)}
            if len(value)>=PANEL_VALUE_BYTES {return fmt.tprintf("%s: value is longer than %d bytes of JSON",set_at,PANEL_VALUE_BYTES-1)}
            base.text_set(button.sets[k].value[:],value)
        }
    }
    p.button_count=len(file.buttons)
    for &r,i in file.rows {
        row:=&p.rows[i]
        heading:=base.text_get(r.heading[:])
        if heading!="" && r.label[0]!=0 {return fmt.tprintf("rows[%d]: a heading has only its text",i)}
        row.label=r.heading if heading!="" else r.label
        if problem:=panel_target_of(&row.place,true,heading,base.text_get(r.component[:]),base.text_get(r.setting[:]),r.field,r.entity,string(r.match));problem!="" {return fmt.tprintf("rows[%d]: %s",i,problem)}
    }
    p.row_count=len(file.rows)
    return ""
}

// The target of a row or of a set; what is wrong, or "".
@(private)
panel_target_of :: proc(t:^Panel_Target,row:bool,heading,component,setting:string,field:[PANEL_FIELD_BYTES]u8,entity:base.Entity_Id,match:string) -> string {
    match:=strings.trim_space(match)
    if match=="null" {match=""}
    t.field,t.entity=field,entity
    kinds:=int(heading!="")+int(component!="")+int(setting!="")
    if kinds!=1 {return row?"a row has one of heading, component or setting":"a set has one of component or setting"}
    if match!="" && !strings.has_prefix(match,"{") {return `where is an object of the fields an entity must have: {"<field>": <value>}`}
    if len(match)>=PANEL_MATCH_BYTES {return fmt.tprintf("where is longer than %d bytes of JSON",PANEL_MATCH_BYTES-1)}
    base.text_set(t.match[:],match)
    switch {
    case heading!="":
        t.kind=.Heading
        if field[0]!=0 || entity!=0 || match!="" {return "a heading has only its text"}
        return ""
    case component!="": t.kind=.Component;base.text_set(t.target[:],component)
    case:               t.kind=.Setting;base.text_set(t.target[:],setting)
    }
    what:=t.kind==.Component?"component":"setting"
    if field[0]==0 {return fmt.tprintf("field is missing: the field of the %s",what)}
    if t.kind==.Setting && (entity!=0 || match!="") {return "a setting is of the project, not of entities"}
    if entity!=0 && match!="" {return "entity and where name different entities: give one of them"}
    return ""
}

// The file of a panel, in temporary memory.
@(private)
panel_file_of :: proc(p:^Project_Panel,allocator:=context.temp_allocator) -> (file:Panel_File) {
    target :: proc(t:^Panel_Target,component,setting:^[PANEL_NAME_BYTES]u8) {
        if t.kind==.Component {component^=t.target} else {setting^=t.target}
    }
    file.title=p.title
    file.buttons=make([]Panel_File_Button,p.button_count,allocator)
    for &b,i in p.buttons[:p.button_count] {
        file.buttons[i]={name=b.name,sets=make([]Panel_File_Set,b.set_count,allocator)}
        for &set,k in b.sets[:b.set_count] {
            shown:=&file.buttons[i].sets[k]
            target(&set.place,&shown.component,&shown.setting)
            shown.field,shown.entity=set.field,set.entity
            shown.match=serial.Json(strings.clone(base.text_get(set.match[:]),allocator))
            shown.value=serial.Json(strings.clone(base.text_get(set.value[:]),allocator))
        }
    }
    file.rows=make([]Panel_File_Row,p.row_count,allocator)
    for &row,i in p.rows[:p.row_count] {
        shown:=&file.rows[i]
        if row.kind==.Heading {
            shown.heading=row.label
            continue
        }
        target(&row.place,&shown.component,&shown.setting)
        shown.field,shown.entity,shown.label=row.field,row.entity,row.label
        shown.match=serial.Json(strings.clone(base.text_get(row.match[:]),allocator))
    }
    return
}

// ---------------------------------------------------------------- fields and entities

// The field of a target in the value of its component or setting.
@(private)
Panel_Field :: struct {
    info:^runtime.Type_Info,
    tag:reflect.Struct_Tag,
    name:string,
    offset:uintptr,
}

// A field by its path of names joined by dots, through nested structs and
// the fields they take with using; problem says why there is none.
@(private)
panel_field_find :: proc(info:^runtime.Type_Info,owner,path:string) -> (field:Panel_Field,problem:string) {
    find :: proc(info:^runtime.Type_Info,name:string) -> (field:Panel_Field,found:bool) {
        v,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
        if !is_struct {return}
        for i in 0..<int(v.field_count) {
            if v.usings[i] {
                if inner,ok:=find(v.types[i],name);ok {
                    inner.offset+=v.offsets[i]
                    return inner,true
                }
                continue
            }
            if v.names[i]==name {return {v.types[i],reflect.Struct_Tag(v.tags[i]),v.names[i],v.offsets[i]},true}
        }
        return
    }
    names :: proc(info:^runtime.Type_Info,out:^strings.Builder) {
        v,_:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
        for i in 0..<int(v.field_count) {
            tag:=reflect.Struct_Tag(v.tags[i])
            tagged:=field_tagged(v.tags[i])
            if .Hidden in tagged.flags {continue}
            if .Transient in tagged.flags {continue}
            if v.usings[i] {names(v.types[i],out);continue}
            if strings.builder_len(out^)>0 {strings.write_string(out,", ")}
            strings.write_string(out,v.names[i])
        }
    }
    current:=info
    shown:=owner
    rest:=path
    offset:uintptr
    for {
        name:=rest
        dot:=strings.index_byte(rest,'.')
        if dot>=0 {name,rest=rest[:dot],rest[dot+1:]} else {rest=""}
        if _,is_struct:=runtime.type_info_base(current).variant.(runtime.Type_Info_Struct);!is_struct {
            return {},fmt.tprintf("%s has no fields: it is a value",shown)
        }
        found,ok:=find(current,name)
        tagged:=field_tagged(string(found.tag))
        hidden:=.Hidden in tagged.flags
        transient:=.Transient in tagged.flags
        if !ok || hidden || transient {
            b:=strings.builder_make(context.temp_allocator)
            names(current,&b)
            return {},fmt.tprintf("%s has no field %q; its fields are %s",shown,name,strings.to_string(b))
        }
        offset+=found.offset
        if rest=="" {
            found.offset=offset
            return found,""
        }
        current=found.info
        shown=fmt.tprintf("%s.%s",shown,name)
    }
}

@(private)
panel_component :: proc(s:^Session,t:^Panel_Target) -> (table:^core.Table_Info,problem:string) {
    name:=base.text_get(t.target[:])
    table=component_table(s,name)
    if table==nil || table.place!=.World || !inspector_listed(s,table) {return nil,fmt.tprintf("%s is not a component of this project; component.list lists the components",name)}
    return table,""
}

@(private)
panel_setting :: proc(s:^Session,t:^Panel_Target) -> (storage:int,problem:string) {
    name:=base.text_get(t.target[:])
    for &info,i in s.info.storages {
        if info.setting!=.None && info.name==name {return i,""}
    }
    return -1,fmt.tprintf("%s is not a setting of this project; settings.get lists them",name)
}

// The JSON of a value at a path of fields, as an object that names only it.
@(private)
panel_value_nest :: proc(path,value:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    depth:=0
    rest:=path
    for name in strings.split_iterator(&rest,".") {
        w:serial.Writer
        serial.writer_init(&w,len(name)+2,context.temp_allocator)
        serial.text_write_string(&w,name)
        strings.write_byte(&b,'{')
        strings.write_string(&b,string(serial.writer_bytes(&w)))
        strings.write_byte(&b,':')
        depth+=1
    }
    strings.write_string(&b,value)
    for _ in 0..<depth {strings.write_byte(&b,'}')}
    return strings.to_string(b)
}

// The value of a component (table not nil) or a setting with the JSON of one
// field read over current, or over the default without it: what scene.set and
// settings.set accept for that field.
@(private)
panel_value_read :: proc(w:core.World_Ref,table:^core.Table_Info,info:^runtime.Type_Info,current:rawptr,path,value,what:string) -> (bytes:[]u8,problem:string) {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,added:=serial.schema_add_type_info(&schema,info)
    if !added {return nil,fmt.tprintf("%s cannot be read from JSON",what)}
    r:serial.Text_Reader
    serial.text_reader_init(&r,panel_value_nest(path,value),context.temp_allocator)
    bytes=make([]u8,max(info.size,1),context.temp_allocator)[:info.size]
    if table!=nil {
        if message,ok:=component_value_read(w,table,current,&schema,type,&r,bytes,what,context.temp_allocator);!ok {return nil,message}
        return bytes,""
    }
    if current!=nil {copy(bytes,([^]u8)(current)[:info.size])}
    if !serial.text_read(&r,&schema,type,bytes) {
        code,_:=reflect.enum_name_from_value(r.error.code)
        words,_:=strings.replace_all(strings.to_lower(code,context.temp_allocator),"_"," ",context.temp_allocator)
        return nil,fmt.tprintf("%s: %s",what,words)
    }
    if message,valid:=api.value_check(&schema,type,bytes,what,context.temp_allocator);!valid {return nil,message}
    return bytes,""
}

// Whether an entity has the fields a where names; with no entity it only
// checks them. Each value is read over the value of the entity, so it compares
// as the field holds it.
@(private)
panel_match :: proc(w:core.World_Ref,table:^core.Table_Info,current:rawptr,match:string) -> (matched:bool,problem:string) {
    r:serial.Text_Reader
    serial.text_reader_init(&r,match,context.temp_allocator)
    if !serial.text_accept(&r,'{') {return false,"where must be an object"}
    matched=true
    if serial.text_accept(&r,'}') {return}
    for {
        key,named:=serial.text_string(&r)
        if !named || !serial.text_expect(&r,':') {return false,"where is malformed"}
        path:=strings.clone(key,context.temp_allocator)
        serial.text_space(&r)
        start:=r.offset
        if !serial.text_skip(&r) {return false,"where is malformed"}
        field,missing:=panel_field_find(table.info,table.name,path)
        if missing!="" {return false,fmt.tprintf("where: %s",missing)}
        bytes,message:=panel_value_read(w,table,table.info,current,path,r.text[start:r.offset],fmt.tprintf("where.%s",path))
        if message!="" {return false,message}
        if current!=nil && string(([^]u8)(current)[field.offset:][:field.info.size])!=string(bytes[field.offset:][:field.info.size]) {matched=false}
        if serial.text_accept(&r,',') {continue}
        if !serial.text_expect(&r,'}') {return false,"where is malformed"}
        return
    }
}

// The entities a target of a component names: its entity, every one its
// where matches, or the first that has the component.
@(private)
panel_entities :: proc(s:^Session,w:core.World_Ref,table:^core.Table_Info,t:^Panel_Target) -> (entities:[dynamic]core.Entity,problem:string) {
    entities=make([dynamic]core.Entity,context.temp_allocator)
    raw:=core.world_table_at(w,table)
    name:=base.text_get(t.target[:])
    if t.entity!=0 {
        e:=api_entity(w,t.entity)
        if e==core.NONE {return entities,fmt.tprintf("%016x is not an entity of the scene",u64(t.entity))}
        if core.raw_find(raw,table.info,e)==nil {return entities,fmt.tprintf("%s has no %s",entity_name(w,e),name)}
        append(&entities,e)
        return
    }
    match:=base.text_get(t.match[:])
    for e in raw.entities {
        if !entity_alive(w,e) {continue}
        if match=="" {
            append(&entities,e)
            return
        }
        matched,message:=panel_match(w,table,core.raw_find(raw,table.info,e),match)
        if message!="" {return entities,message}
        if matched {append(&entities,e)}
    }
    return
}

// What a row shows this frame, ready for field_row, or why it shows nothing:
// the value of the first of its entities, written to all of them.
@(private)
panel_inspect :: proc(s:^Session,w:core.World_Ref,t:^Panel_Target,defaults:[]u8) -> (c:Inspect,field:Panel_Field,problem:string) {
    target:=base.text_get(t.target[:])
    path:=base.text_get(t.field[:])
    switch t.kind {
    case .Heading:
    case .Component:
        table:^core.Table_Info
        table,problem=panel_component(s,t)
        if problem!="" {return}
        field,problem=panel_field_find(table.info,target,path)
        if problem!="" {return}
        entities,missing:=panel_entities(s,w,table,t)
        if missing!="" {return {},{},missing}
        if len(entities)==0 {return {},{},fmt.tprintf("No entity has %s",target)}
        raw:=core.world_table_at(w,table)
        at:=0
        for &other,i in w.info.tables {if &other==table {at=i;break}}
        c={s=s,w=w,t=table,index=at,table=raw,entities=entities[:],name=table.name,type=table.type,value=cast([^]u8)core.raw_find(raw,table.info,entities[0]),size=table.info.size}
    case .Setting:
        storage:int
        storage,problem=panel_setting(s,t)
        if problem!="" {return}
        info:=&s.info.storages[storage]
        field,problem=panel_field_find(info.info,target,path)
        if problem!="" {return}
        c={s=s,w=w,index=SETTING_INDEX+storage,storage=storage+1,name=info.name,type=info.type,value=cast([^]u8)setting_data(s,storage),size=info.info.size}
        if engine:=setting_engine_value(s,info.name);s.settings_layer==.Project && engine!=nil {
            c.defaults=cast([^]u8)engine
        } else if info.info.size<=len(defaults) {
            if info.for_device!=nil && s.app!=nil && s.app.device!=nil {info.for_device(&defaults[0],rhi.device_info(s.app.device))} else if info.default!=nil {info.default(&defaults[0])}
            c.defaults=raw_data(defaults)
        }
    }
    return
}

@(private)
panel_label :: proc(label:string,field:Panel_Field) -> string {
    if label!="" {return label}
    if custom:=field_tagged(string(field.tag)).label;custom!="" {return custom}
    return readable(field.name)
}

// ---------------------------------------------------------------- buttons

// A field set to a value: where it goes and its bytes.
@(private)
Panel_Write :: struct {
    table:^core.Table_Info, // nil: a setting
    entity:core.Entity,
    storage:int,
    offset:int,
    bytes:[]u8,
}

// What a button writes, read before anything is written.
@(private)
panel_writes :: proc(s:^Session,w:core.World_Ref,b:^Panel_Button) -> (writes:[dynamic]Panel_Write,problem:string) {
    writes=make([dynamic]Panel_Write,context.temp_allocator)
    for &set,i in b.sets[:b.set_count] {
        at:=fmt.tprintf("sets[%d]",i)
        target:=base.text_get(set.target[:])
        path:=base.text_get(set.field[:])
        value:=base.text_get(set.value[:])
        what:=fmt.tprintf("%s.%s",target,path)
        switch set.kind {
        case .Heading:
        case .Component:
            table,missing:=panel_component(s,&set.place)
            if missing!="" {return writes,fmt.tprintf("%s: %s",at,missing)}
            field,no_field:=panel_field_find(table.info,target,path)
            if no_field!="" {return writes,fmt.tprintf("%s: %s",at,no_field)}
            entities,unknown:=panel_entities(s,w,table,&set.place)
            if unknown!="" {return writes,fmt.tprintf("%s: %s",at,unknown)}
            raw:=core.world_table_at(w,table)
            for e in entities {
                bytes,message:=panel_value_read(w,table,table.info,core.raw_find(raw,table.info,e),path,value,what)
                if message!="" {return writes,fmt.tprintf("%s: %s",at,message)}
                append(&writes,Panel_Write{table=table,entity=e,offset=int(field.offset),bytes=bytes[field.offset:][:field.info.size]})
            }
        case .Setting:
            storage,missing:=panel_setting(s,&set.place)
            if missing!="" {return writes,fmt.tprintf("%s: %s",at,missing)}
            info:=&s.info.storages[storage]
            field,no_field:=panel_field_find(info.info,target,path)
            if no_field!="" {return writes,fmt.tprintf("%s: %s",at,no_field)}
            bytes,message:=panel_value_read(w,nil,info.info,setting_data(s,storage),path,value,what)
            if message!="" {return writes,fmt.tprintf("%s: %s",at,message)}
            append(&writes,Panel_Write{storage=storage,offset=int(field.offset),bytes=bytes[field.offset:][:field.info.size]})
        }
    }
    return
}

// Presses a button: every value is read before any is written, so one that
// fails changes nothing. The fields of the scene are one step of the history;
// those of settings change as in the settings dialog. changed counts the
// entities and settings it wrote.
@(private)
panel_press :: proc(s:^Session,p:^Project_Panel,button:int) -> (changed:int,problem:string) {
    if button<0 || button>=p.button_count {return 0,"no such button"}
    b:=&p.buttons[button]
    w:=edited_world(s)
    writes,message:=panel_writes(s,w,b)
    if message!="" {return 0,message}
    if s.panels!=nil {
        for &write in writes {
            if write.table==nil {
                panel_keep(s.panels,p,nil,core.NONE,write.storage,write.offset,len(write.bytes),setting_data(s,write.storage))
            } else {
                panel_keep(s.panels,p,write.table,write.entity,0,write.offset,len(write.bytes),core.raw_find(core.world_table_at(w,write.table),write.table.info,write.entity))
            }
        }
    }
    opened,ready:=false,true
    one:[1]core.Entity
    for &write in writes {
        if write.table==nil {continue}
        if !opened && !s.edits.open {opened,ready=edit_open(s,fmt.tprintf("%s: %s",base.text_get(p.title[:]),base.text_get(b.name[:])))}
        if !ready {return 0,history.edits_error_text(s.edits.error)}
        one[0]=write.entity
        field_write(s,write.table,one[:],write.offset,write.bytes)
    }
    edit_close(s,opened)
    for &write in writes {
        if write.table==nil {setting_write(s,write.storage,write.offset,write.bytes)}
    }
    return len(writes),""
}

// Keeps what a field was before a panel first changes it; a part of a field
// already kept is not kept again.
@(private)
panel_keep :: proc(panels:^Project_Panels,p:^Project_Panel,table:^core.Table_Info,entity:core.Entity,storage,offset,size:int,value:rawptr) {
    if value==nil || size<=0 {return}
    key:=base.name_hash(base.text_get(p.id[:]))
    for k in panels.kept {
        if k.panel==key && k.table==table && k.entity==entity && k.storage==storage && offset>=k.offset && offset+size<=k.offset+k.size {return}
    }
    append(&panels.kept,Panel_Kept{panel=key,table=table,entity=entity,storage=storage,offset=offset,size=size,at=len(panels.kept_bytes)})
    append(&panels.kept_bytes,..([^]u8)(value)[offset:][:size])
}

// Keeps what a row of a panel is about to write over.
@(private)
panel_keep_row :: proc(c:^Inspect,offset,size:int) {
    panels:=c.s.panels
    if panels==nil {return}
    if c.storage>0 {
        panel_keep(panels,c.panel,nil,core.NONE,c.storage-1,offset,size,setting_data(c.s,c.storage-1))
        return
    }
    for e in c.entities {panel_keep(panels,c.panel,c.t,e,0,offset,size,core.raw_find(c.table,c.t.info,e))}
}

@(private)
panel_kept_count :: proc(panels:^Project_Panels,p:^Project_Panel) -> (count:int) {
    key:=base.name_hash(base.text_get(p.id[:]))
    for k in panels.kept {if k.panel==key {count+=1}}
    return
}

@(private)
panel_forget :: proc(panels:^Project_Panels,key:u64) {
    old:=make([]u8,len(panels.kept_bytes),context.temp_allocator)
    copy(old,panels.kept_bytes[:])
    clear(&panels.kept_bytes)
    kept:=0
    for k in panels.kept {
        if k.panel==key {continue}
        k:=k
        append(&panels.kept_bytes,..old[k.at:][:k.size])
        k.at=len(panels.kept_bytes)-k.size
        panels.kept[kept]=k
        kept+=1
    }
    resize(&panels.kept,kept)
}

// Puts back what a panel changed, as it was before the panel first changed
// it: the fields of the scene as one step of the history, of entities that
// still have them, and the settings as the settings dialog. restored counts
// the fields.
@(private)
panel_restore :: proc(s:^Session,p:^Project_Panel) -> (restored:int,problem:string) {
    panels:=s.panels
    if panels==nil {return}
    key:=base.name_hash(base.text_get(p.id[:]))
    w:=edited_world(s)
    opened,ready:=false,true
    one:[1]core.Entity
    #reverse for k in panels.kept {
        if k.panel!=key {continue}
        bytes:=panels.kept_bytes[k.at:][:k.size]
        if k.table==nil {
            setting_write(s,k.storage,k.offset,bytes)
            restored+=1
            continue
        }
        if (!entity_alive(w,k.entity) || core.raw_find(core.world_table_at(w,k.table),k.table.info,k.entity)==nil) {continue}
        if !opened && !s.edits.open {opened,ready=edit_open(s,fmt.tprintf("%s: Restore",base.text_get(p.title[:])))}
        if !ready {return 0,history.edits_error_text(s.edits.error)}
        one[0]=k.entity
        field_write(s,k.table,one[:],k.offset,bytes)
        restored+=1
    }
    edit_close(s,opened)
    panel_forget(panels,key)
    return
}

// Whether the rows and buttons of a panel name what this project has, before
// it is saved: components and settings with those fields, the entities, the
// fields a where names and every value. A component no entity has yet, or a
// where no entity matches yet, waits for one.
@(private)
panel_check :: proc(s:^Session,p:^Project_Panel) -> string {
    w:=edited_world(s)
    defaults:=make([]u8,INSPECTOR_COMPONENT_BYTES,context.temp_allocator)
    for &row,i in p.rows[:p.row_count] {
        if row.kind==.Heading {continue}
        if row.kind==.Component {
            table,missing:=panel_component(s,&row.place)
            if missing!="" {return fmt.tprintf("rows[%d]: %s",i,missing)}
            if _,problem:=panel_field_find(table.info,table.name,base.text_get(row.field[:]));problem!="" {return fmt.tprintf("rows[%d]: %s",i,problem)}
        }
        if _,_,problem:=panel_inspect(s,w,&row.place,defaults);problem!="" && !strings.has_prefix(problem,"No entity has") {
            return fmt.tprintf("rows[%d]: %s",i,problem)
        }
    }
    for &b,i in p.buttons[:p.button_count] {
        for &set,j in b.sets[:b.set_count] {
            at:=fmt.tprintf("buttons[%d].sets[%d]",i,j)
            target:=base.text_get(set.target[:])
            path:=base.text_get(set.field[:])
            what:=fmt.tprintf("%s.%s",target,path)
            if set.kind==.Setting {
                storage,missing:=panel_setting(s,&set.place)
                if missing!="" {return fmt.tprintf("%s: %s",at,missing)}
                info:=&s.info.storages[storage]
                if _,problem:=panel_field_find(info.info,target,path);problem!="" {return fmt.tprintf("%s: %s",at,problem)}
                if _,problem:=panel_value_read(w,nil,info.info,setting_data(s,storage),path,base.text_get(set.value[:]),what);problem!="" {return fmt.tprintf("%s.value: %s",at,problem)}
                continue
            }
            table,missing:=panel_component(s,&set.place)
            if missing!="" {return fmt.tprintf("%s: %s",at,missing)}
            if _,problem:=panel_field_find(table.info,target,path);problem!="" {return fmt.tprintf("%s: %s",at,problem)}
            if _,problem:=panel_value_read(w,table,table.info,nil,path,base.text_get(set.value[:]),what);problem!="" {return fmt.tprintf("%s.value: %s",at,problem)}
            if match:=base.text_get(set.match[:]);match!="" {
                if _,problem:=panel_match(w,table,nil,match);problem!="" {return fmt.tprintf("%s.%s",at,problem)}
            }
            if set.entity!=0 {
                if _,problem:=panel_entities(s,w,table,&set.place);problem!="" {return fmt.tprintf("%s: %s",at,problem)}
            }
        }
    }
    return panel_variants_check(p)
}

// Buttons are variants pressed in any order, so each one that sets fields of
// a target sets all the fields that the others set there; otherwise a field
// one of them set (an intensity of 0) stays after another is pressed.
@(private)
panel_variants_check :: proc(p:^Project_Panel) -> string {
    same_place :: proc(a,b:^Panel_Target) -> bool {
        return a.kind==b.kind && a.entity==b.entity && base.text_get(a.target[:])==base.text_get(b.target[:]) && base.text_get(a.match[:])==base.text_get(b.match[:])
    }
    for &b,i in p.buttons[:p.button_count] {
        for &other,j in p.buttons[:p.button_count] {
            if i==j {continue}
            for &want in other.sets[:other.set_count] {
                touches,sets:=false,false
                for &set in b.sets[:b.set_count] {
                    if !same_place(&set.place,&want.place) {continue}
                    touches=true
                    if base.text_get(set.field[:])==base.text_get(want.field[:]) {sets=true;break}
                }
                if touches && !sets {
                    return fmt.tprintf("buttons[%d] (%s) sets %s but not its %s, which buttons[%d] (%s) sets: buttons are variants pressed in any order, so give it the value of %s it should have",i,base.text_get(b.name[:]),base.text_get(want.target[:]),base.text_get(want.field[:]),j,base.text_get(other.name[:]),base.text_get(want.field[:]))
                }
            }
        }
    }
    return ""
}

// Writes a panel to its file and puts it in the list, in place of the one
// with its id.
@(private)
panel_store :: proc(s:^Session,panels:^Project_Panels,p:Project_Panel) -> (at:int,problem:string) {
    p:=p
    id:=base.text_get(p.id[:])
    text,encoded:=serial.text_encode(panel_file_of(&p),.Pretty,context.temp_allocator,sparse=true)
    if !encoded {return -1,"the panel does not fit in memory"}
    _=os.make_directory_all(panel_folder(s))
    if serial.file_write_atomic(panel_file(s,id),text)!=.None {return -1,fmt.tprintf("%s cannot be written",panel_file(s,id))}
    if existing:=panel_find(panels,id);existing>=0 {
        p.scroll,p.attributes=panels.list[existing].scroll,panels.list[existing].attributes
        panels.list[existing]=p
        return existing,""
    }
    return panel_insert(panels,p),""
}

@(private)
panel_delete :: proc(s:^Session,panels:^Project_Panels,at:int) -> bool {
    id:=base.text_get(panels.list[at].id[:])
    path:=panel_file(s,id)
    if os.exists(path) && os.remove(path)!=nil {return false}
    panel_forget(panels,base.name_hash(id))
    ordered_remove(&panels.list,at)
    return true
}

// ---------------------------------------------------------------- the panels

@(step="ui",after="editor_panels")
panels_build :: proc(s:^Session,g:^Editor_Ui,panels:^Project_Panels) {
    if !g.begun || playing(s) {return}
    panels_sync(s,panels)
    if panel_shown(panels)!=nil && history.selection_active(s.selection)!=panels.selection {panel_show(s,panels,-1,false)}
    if s.viewport.pick.active || scene_covered(s) {return}
    removed:=-1
    for &p,i in panels.list {
        if p.open && panel_build(s,&p) {removed=i}
    }
    if removed>=0 {
        title:=strings.clone(base.text_get(panels.list[removed].title[:]),context.temp_allocator)
        if panel_delete(s,panels,removed) {notify(s,fmt.tprintf("Deleted %s",title))} else {notify(s,fmt.tprintf("%s cannot be deleted",title))}
    }
}

// An open panel; true when its delete button was clicked.
@(private)
panel_build :: proc(s:^Session,p:^Project_Panel) -> (deleted:bool) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    id:=ui.id_derive(ctx,PANELS_SCOPE,base.text_get(p.id[:]))
    float:=tool_panel(g,id)
    width:=float.width.value-float.padding[0]-float.padding[2]
    height:=ctx.size.y-float.offset.y-th.margin-float.padding[1]-float.padding[3]
    if ui.panel(ctx,id,float) {
        ui.id_push(ctx,id)
        defer ui.id_pop(ctx)
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(24),align_y=.Center,gap=2}) {
            ui.label(ctx,base.text_get(p.title[:]),th.font,th.text,width-24,font=ui.FONT_SEMIBOLD)
            ui.spacer(ctx)
            deleted=ui.button(ctx,ui.id(ctx,"delete"),{icon=ui.icon_user(u8(User_Icon.Trash)),icon_color=th.text_muted,style=.Ghost,width=22,height=22,icon_size=12}).clicked
        }
        for first:=0;first<p.button_count;first+=2 {
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,gap=6}) {
                for button in first..<min(first+2,p.button_count) {
                    name:=base.text_get(p.buttons[button].name[:])
                    if ui.button(ctx,ui.id(ctx,"button",button+1),{label=name,style=.Field,width=-1,center=true}).clicked {
                        changed,problem:=panel_press(s,p,button)
                        if problem!="" {notify(s,problem)} else if changed==0 {notify(s,fmt.tprintf("%s: no entity matches",name))}
                    }
                }
            }
        }
        if ui.button(ctx,ui.id(ctx,"restore"),{label="Restore",icon=.Revert,style=.Ghost,width=-1,center=true,disabled=panel_kept_count(s.panels,p)==0}).clicked {
            if _,problem:=panel_restore(s,p);problem!="" {notify(s,problem)}
        }
        w:=edited_world(s)
        if p.row_count>0 || p.button_count>0 {
            if ui.scroll_area(ctx,ui.id(ctx,"rows"),&p.scroll,{width=ui.GROW,height=ui.FIT,max_height=max(height-24-(th.row+6)*f32((p.button_count+1)/2+1)-12,80),direction=.Column,gap=3}) {
                for &row,i in p.rows[:p.row_count] {
                    ui.id_push(ctx,ui.id(ctx,"row",i+1))
                    defer ui.id_pop(ctx)
                    if row.kind==.Heading {
                        ui.section(ctx,base.text_get(row.label[:]))
                        continue
                    }
                    panel_target_row(s,w,p,&row.place,base.text_get(row.label[:]),width)
                }
                if p.button_count>0 {panel_attributes(s,w,p,width)}
            }
        }
    }
    return
}

// The row of a field of its entities or a setting, or why there is none; its
// label says when the entities differ.
@(private)
panel_target_row :: proc(s:^Session,w:core.World_Ref,p:^Project_Panel,t:^Panel_Target,label:string,width:f32) {
    defaults:[INSPECTOR_COMPONENT_BYTES]u8
    c,field,problem:=panel_inspect(s,w,t,defaults[:])
    if problem!="" {
        readonly_row(s.gui.ctx,label!=""?label:readable(base.text_get(t.field[:])),problem)
        return
    }
    c.width=width
    c.panel=p
    c.held=base.hash_combine(base.name_hash(base.text_get(p.id[:])),u64(uintptr(t)-uintptr(p)))|1
    held_take(&c)
    shown:=panel_label(label,field)
    for e in c.entities[min(1,len(c.entities)):] {
        other:=([^]u8)(core.raw_find(c.table,c.t.info,e))
        if string(other[field.offset:][:field.info.size])!=string(c.value[field.offset:][:field.info.size]) {
            shown=fmt.tprintf("%s (mixed)",shown)
            break
        }
    }
    field_row(&c,field.info,field.tag,field.name,shown,field.offset,0)
}

// Folded at first: the fields the buttons set, each once, as rows; one a
// where names says how many entities match now.
@(private)
panel_attributes :: proc(s:^Session,w:core.World_Ref,p:^Project_Panel,width:f32) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    if !ui.collapsible(ctx,ui.id(ctx,"attributes"),"Attributes",&p.attributes).open {return}
    shown:=make([dynamic]^Panel_Target,context.temp_allocator)
    for &b in p.buttons[:p.button_count] {
        next: for &set in b.sets[:b.set_count] {
            for other in shown {
                if other.kind==set.kind && other.entity==set.entity && base.text_compare(other.target[:],set.target[:])==0 && base.text_compare(other.field[:],set.field[:])==0 && base.text_compare(other.match[:],set.match[:])==0 {continue next}
            }
            append(&shown,&set.place)
        }
    }
    for t,i in shown {
        ui.id_push(ctx,ui.id(ctx,"attribute",i+1))
        defer ui.id_pop(ctx)
        target:=base.text_get(t.target[:])
        match:=base.text_get(t.match[:])
        caption:=target
        if match!="" {caption=fmt.tprintf("%s where %s",target,strings.trim_space(strings.trim(match,"{} ")))}
        if match=="{}" {caption=fmt.tprintf("%s, every entity",target)}
        if match!="" {
            if table,missing:=panel_component(s,t);missing=="" {
                if entities,problem:=panel_entities(s,w,table,t);problem=="" {caption=fmt.tprintf(len(entities)==1?"%s, %d entity":"%s, %d entities",caption,len(entities))}
            }
        }
        ui.label(ctx,caption,th.font_small,th.text_faint,width)
        panel_target_row(s,w,p,t,"",width)
    }
}

// Shows a panel in place of Details, alone: the other panels and the tool of
// a plugin close. It stays until another entity is selected, Escape or
// another panel or tool. at -1 or on false closes the one shown.
panel_show :: proc(s:^Session,panels:^Project_Panels,at:int,on:bool) {
    if panels==nil {return}
    for &p,i in panels.list {p.open=on && i==at}
    if !on || at<0 {return}
    if s.viewport.plugin_tool!=0 {tool_leave(s)}
    panels.selection=history.selection_active(s.selection)
}

panel_shown :: proc(panels:^Project_Panels) -> ^Project_Panel {
    if panels==nil {return nil}
    for &p in panels.list {if p.open {return &p}}
    return nil
}
