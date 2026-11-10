package project

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// The settings of a project: a section per setting, named by its type and
// written by its schema like the manifest. A setting is a storage of a
// library marked @(storage,setting): the engine, a plugin and the game each
// declare their own, and the editor shows them all.
//
// They come in layers. Under all of them are the values of the code; over
// those, the file of the engine on this machine (settings.mirai in
// machine_folder: the .mirai of its main checkout, which every worktree of it
// shares, never versioned), over it the file of the project, and on top, in
// a game that runs, the options the player chose (settings.mirai in the
// folder of the player: App.options). The files of the engine and of the
// player hold only the settings of the machine (@(storage,setting="machine")),
// the preferences of whoever uses the engine or plays there; the project may
// set any. Each file holds only the fields that differ from what the layers
// under it leave, so a change of the engine reaches every project that does
// not set that field. A shipped game has no engine: it carries both files
// merged (settings_merge).
//
// A section no setting of the layer names, of a plugin that is not active or
// of the project in the file of the engine, is kept as it is and not read; a
// field the type no longer has is left out.

SETTINGS_FILE :: "settings.mirai" // next to PROJECT_FILE, in the machine_folder of the engine and in the folder of the player

// The format of the files of the machine (Engine and Player layers), their
// first member: a file of another version is not read and the next save
// writes it anew. The file of a project has none: it is read by its fields.
SETTINGS_VERSION :: 3
@(private) SETTINGS_VERSION_KEY :: "version"

// Set in a process, the file of the machine is not read: what mirai render
// check measures does not depend on what was chosen on this computer.
SETTINGS_NO_MACHINE_ENV :: "MIRAI_NO_MACHINE_SETTINGS"

// The layers this process reads.
settings_layers_of_process :: proc() -> Settings_Layers {
    if value,found:=os.lookup_env(SETTINGS_NO_MACHINE_ENV,context.temp_allocator);found && value!="" && value!="0" {return {.Player,.Project}}
    return {.Player,.Project,.Engine}
}

// The files of the settings: SETTINGS_FROM_TOP gives their order.
Settings_Layer :: enum u8 {Project,Engine,Player}
Settings_Layers :: bit_set[Settings_Layer;u8]

SETTINGS_FROM_TOP :: [len(Settings_Layer)]Settings_Layer{.Player,.Project,.Engine}

Setting :: struct {
    name:string,
    info:^runtime.Type_Info,
    value:rawptr,
    default:proc(dst:rawptr), // writes the value of the code; nil: zero
    machine:bool,             // a preference of this machine: the file of the engine holds it
    base:rawptr,              // the value of the code on this machine, in place of default; nil: none
    named:map[typeid]serial.Named, // the names of the integers @(names) of the world, which the text uses; nil: numbers
}

// The settings the file of a layer holds: those of the machine for the
// engine and the player, every one for the project. They share their values.
settings_held :: proc(settings:[]Setting,layer:Settings_Layer,allocator:=context.temp_allocator) -> []Setting {
    if layer==.Project {return settings}
    held:=make([dynamic]Setting,allocator)
    for setting in settings {
        if setting.machine {append(&held,setting)}
    }
    return held[:]
}

// The file of a layer; "" when its root is not known. player is the folder
// of the options of the player.
settings_file :: proc(layer:Settings_Layer,root,engine_root:string,allocator:=context.allocator,player:="") -> string {
    switch layer {
    case .Project: if root!="" {return path(root,SETTINGS_FILE,allocator=allocator)}
    case .Engine:  if engine_root!="" {return path(machine_folder(engine_root,context.temp_allocator),SETTINGS_FILE,allocator=allocator)}
    case .Player:  if player!="" {return path(player,SETTINGS_FILE,allocator=allocator)}
    }
    return ""
}

// The layers under one: what its file is written against.
settings_under :: proc(layer:Settings_Layer) -> (under:Settings_Layers) {
    order:=SETTINGS_FROM_TOP
    below:=false
    for other in order {
        if below {under+={other}}
        below||=other==layer
    }
    return
}

// Reads the sections of text into the settings they name. A file may hold
// fields the settings no longer have, and they are left out; strict, for
// what a person or an agent writes now, makes them an error.
settings_parse :: proc(text:string,settings:[]Setting,strict:=false) -> Error {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    if !sections_read(&r,settings,nil,strict=strict) || !serial.text_end(&r) {
        line,column:=serial.text_position(text,r.error.offset)
        return {code=.Text,text=r.error.code,line=line,column=column,detail=serial.text_error_message(&r,allocator=context.temp_allocator)}
    }
    return {}
}

// The version a file of the machine says it is; 0 when it says none.
settings_version_of :: proc(text:string) -> u64 {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    if !serial.text_accept(&r,'{') {return 0}
    serial.text_space(&r)
    name,named:=serial.text_string(&r)
    if !named || name!=SETTINGS_VERSION_KEY || !serial.text_expect(&r,':') {return 0}
    serial.text_space(&r)
    negative,magnitude,ok:=serial.text_integer(&r)
    return !ok || negative?0:magnitude
}

// A missing file leaves the settings as they are, and so does a file of the
// machine of another version.
settings_read :: proc(path:string,settings:[]Setting,versioned:=false) -> Error {
    data,file_error:=serial.file_read(path,context.temp_allocator)
    if file_error!=.None {return {code=file_error==.Not_Found?.None:.Read_Failed}}
    if versioned && settings_version_of(string(data))!=SETTINGS_VERSION {return {}}
    return settings_parse(string(data),settings)
}

// Gives the settings the values of their code.
settings_default :: proc(settings:[]Setting) {
    for setting in settings {
        if setting.base!=nil {
            mem.copy(setting.value,setting.base,setting.info.size)
            continue
        }
        mem.zero(setting.value,setting.info.size)
        if setting.default!=nil {setting.default(setting.value)}
    }
}

// Gives the settings the values of the code and reads over them the files of
// the layers asked for, from the bottom, each into the settings it holds; the
// one of the player from its folder. On an error they keep what was read until
// it, and layer is the one whose file has it.
settings_load :: proc(settings:[]Setting,root,engine_root:string,layers:=Settings_Layers{.Player,.Project,.Engine},player:="") -> (error:Error,layer:Settings_Layer) {
    settings_default(settings)
    if len(settings)==0 {return}
    order:=SETTINGS_FROM_TOP
    #reverse for at in order {
        layer=at
        if layer not_in layers {continue}
        if file:=settings_file(layer,root,engine_root,context.temp_allocator,player);file!="" {
            if error=settings_read(file,settings_held(settings,layer),layer!=.Project);error.code!=.None {return}
        }
    }
    return {},.Project
}

// The sections of the file of the engine that name a setting of the project:
// that file holds only the settings of the machine, so they are not read. They
// belong in the file of the project.
settings_misplaced :: proc(settings:[]Setting,root,engine_root:string) -> []string {
    file:=settings_file(.Engine,root,engine_root,context.temp_allocator)
    if file=="" {return nil}
    data,file_error:=serial.file_read(file,context.temp_allocator)
    if file_error!=.None {return nil}
    kept:=make([dynamic]Kept_Section,context.temp_allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,string(data),context.temp_allocator)
    sections_read(&r,settings_held(settings,.Engine),&kept,false)
    serial.text_reader_destroy(&r)
    misplaced:=make([dynamic]string,context.temp_allocator)
    for section in kept {
        for setting in settings {
            if setting.name==section.name {append(&misplaced,strings.clone(section.name,context.temp_allocator));break}
        }
    }
    return misplaced[:]
}

// Copies of the settings: the list, their values and their bases in one
// block, which free(raw_data(list),allocator) releases. nil without memory
// for it.
settings_clone :: proc(settings:[]Setting,allocator:=context.allocator) -> []Setting {
    if len(settings)==0 {return nil}
    size,align:=len(settings)*size_of(Setting),align_of(Setting)
    for setting in settings {
        align=max(align,setting.info.align)
        copies:=setting.base!=nil?2:1
        for _ in 0..<copies {size=mem.align_forward_int(size,max(setting.info.align,1))+setting.info.size}
    }
    block,error:=mem.alloc_bytes(size,align,allocator)
    if error!=nil {return nil}
    list:=([^]Setting)(raw_data(block))[:len(settings)]
    at:=len(settings)*size_of(Setting)
    copy_at :: proc(block:[]u8,at:^int,src:rawptr,info:^runtime.Type_Info) -> rawptr {
        at^=mem.align_forward_int(at^,max(info.align,1))
        dst:=rawptr(uintptr(raw_data(block))+uintptr(at^))
        mem.copy(dst,src,info.size)
        at^+=info.size
        return dst
    }
    for setting,i in settings {
        list[i]=setting
        list[i].value=copy_at(block,&at,setting.value,setting.info)
        if setting.base!=nil {list[i].base=copy_at(block,&at,setting.base,setting.info)}
    }
    return list
}

// The text of the settings. With below, the same settings with the values of
// the layers under the file, each writes only the fields that differ from it,
// and none when nothing does; without it, every field.
settings_text :: proc(settings:[]Setting,below:[]Setting={},kept:[]Kept_Section={},allocator:=context.allocator,version:=0) -> string {
    w:serial.Writer
    serial.writer_init(&w,4096,allocator)
    serial.write_u8(&w,'{')
    count:=0
    if version>0 {
        serial.text_write_break(&w,1)
        serial.text_write_string(&w,SETTINGS_VERSION_KEY)
        serial.text_write_raw(&w,": ")
        serial.text_write_uint(&w,u64(version))
        count+=1
    }
    for setting,i in settings {
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        defer serial.schema_destroy(&schema)
        schema.named=setting.named
        type,_:=serial.schema_add_type_info(&schema,setting.info)
        value:=setting_image(&schema,type,setting.value)
        under:[]u8
        if len(below)>0 {
            under=setting_image(&schema,type,below[i].value)
            if mem.compare(value,under)==0 {continue}
        }
        serial.text_write_raw(&w,count>0?",":"")
        serial.text_write_break(&w,1)
        serial.text_write_string(&w,setting.name)
        serial.text_write_raw(&w,": ")
        struct_write(&w,&schema,type,value,1,under)
        count+=1
    }
    for section in kept {
        serial.text_write_raw(&w,count>0?",":"")
        serial.text_write_break(&w,1)
        serial.text_write_string(&w,section.name)
        serial.text_write_raw(&w,": ")
        serial.text_write_raw(&w,section.text)
        count+=1
    }
    serial.text_write_break(&w,0)
    serial.text_write_raw(&w,"}\n")
    return string(serial.writer_take(&w))
}

// Writes the settings over the file as settings_text does, keeping the
// sections of it that none of them names.
settings_write :: proc(path:string,settings,below:[]Setting,version:=0) -> Error {
    kept:=make([dynamic]Kept_Section,context.temp_allocator)
    if data,file_error:=serial.file_read(path,context.temp_allocator);file_error==.None {
        r:serial.Text_Reader
        serial.text_reader_init(&r,string(data),context.temp_allocator)
        sections_read(&r,settings,&kept,false)
        serial.text_reader_destroy(&r)
    }
    text:=settings_text(settings,below,kept[:],context.temp_allocator,version)
    if cut:=strings.last_index_byte(path,'/');cut>0 {_=os.make_directory_all(path[:cut])}
    return {code=serial.file_write_atomic(path,transmute([]u8)text)==.None?.None:.Write_Failed}
}

// Writes the settings the file of a layer holds as that file: the fields that
// differ from what the code and the files of the layers under it leave.
// failed is the layer whose file has the error, which may be one under it.
settings_save :: proc(settings:[]Setting,layer:Settings_Layer,root,engine_root:string,player:="") -> (error:Error,failed:Settings_Layer) {
    file:=settings_file(layer,root,engine_root,context.temp_allocator,player)
    if file=="" {return {code=.Write_Failed},layer}
    held:=settings_held(settings,layer)
    below:=settings_clone(held,context.temp_allocator)
    if len(below)!=len(held) {return {code=.Write_Failed},layer}
    if error,failed=settings_load(below,root,engine_root,settings_under(layer),player);error.code!=.None {return}
    return settings_write(file,held,below,layer==.Project?0:SETTINGS_VERSION),layer
}

// The files of the project and of the engine as one, for a game that ships
// without the engine: a field of the project replaces the same field of the
// engine, and an object merges field by field. Of the file of the engine only
// the sections machine names are taken: the settings of the machine. An empty
// object when there is no file. On an error, layer is the one whose file has
// it.
settings_merge :: proc(root,engine_root:string,machine:[]string,allocator:=context.allocator) -> (text:string,error:Error,layer:Settings_Layer) {
    merged:=Merge_Node{object=true,fields=make([dynamic]Merge_Node,context.temp_allocator)}
    order:=SETTINGS_FROM_TOP
    #reverse for at in order {
        layer=at
        file:=settings_file(layer,root,engine_root,context.temp_allocator)
        if file=="" {continue}
        data,file_error:=serial.file_read(file,context.temp_allocator)
        if file_error==.Not_Found {continue}
        if file_error!=.None {return "",{code=.Read_Failed},layer}
        if layer==.Engine && settings_version_of(string(data))!=SETTINGS_VERSION {continue}
        r:serial.Text_Reader
        serial.text_reader_init(&r,string(data),context.temp_allocator)
        if !merge_read(&r,&merged,0) || !serial.text_end(&r) {
            line,column:=serial.text_position(r.text,r.error.offset)
            return "",{code=.Text,text=r.error.code,line=line,column=column,detail=serial.text_error_message(&r,allocator=context.temp_allocator)},layer
        }
        if layer==.Engine {
            // The bottom layer: merged has its file alone.
            held:=0
            for field in merged.fields {
                for name in machine {
                    if name==field.name {merged.fields[held]=field;held+=1;break}
                }
            }
            base.truncate(&merged.fields,held)
        }
    }
    w:serial.Writer
    serial.writer_init(&w,4096,allocator)
    merge_write(&w,&merged,0)
    serial.write_u8(&w,'\n')
    return string(serial.writer_take(&w)),{},.Project
}

// A section of the file that no setting names, as its text.
Kept_Section :: struct {name,text:string}

// The sections of the file: into the settings they name when read is set, and
// those no setting names into kept. strict: a field a setting does not have
// is an error.
@(private)
sections_read :: proc(r:^serial.Text_Reader,settings:[]Setting,kept:^[dynamic]Kept_Section,read:=true,strict:=false) -> bool {
    if !serial.text_accept(r,'{') {return serial.text_fail(r,.Expected_Object)}
    if serial.text_accept(r,'}') {return true}
    for {
        serial.text_space(r)
        name:=serial.text_string(r) or_return
        name=strings.clone(name,context.temp_allocator)
        serial.text_expect(r,':') or_return
        serial.text_space(r)
        start:=r.offset
        found:=-1
        for setting,i in settings {
            if setting.name==name {found=i;break}
        }
        if found>=0 && read {
            s:=&settings[found]
            schema:serial.Schema
            serial.schema_init(&schema,context.temp_allocator)
            schema.named=s.named
            type,_:=serial.schema_add_type_info(&schema,s.info)
            ok:=struct_read(r,&schema,type,([^]u8)(s.value)[:s.info.size],!strict)
            serial.schema_destroy(&schema)
            if !ok {
                serial.text_error_within(r,name)
                return false
            }
        } else {
            serial.text_skip(r) or_return
            if found<0 && kept!=nil && name!=SETTINGS_VERSION_KEY {append(kept,Kept_Section{name,strings.clone(r.text[start:r.offset],context.temp_allocator)})}
        }
        if serial.text_accept(r,',') {continue}
        return serial.text_expect(r,'}')
    }
}

// The value as its schema saves it: padding and what follows the end of a
// text are zero, so equal values are equal bytes.
@(private="file")
setting_image :: proc(s:^serial.Schema,type:serial.Type_Index,value:rawptr) -> []u8 {
    layout:serial.Layout
    serial.layout_init(&layout,s,type,context.temp_allocator)
    defer serial.layout_destroy(&layout)
    image:=make([]u8,layout.size,context.temp_allocator)
    serial.value_write(&layout,image,value,1)
    return image
}

// A value of a settings file: the text of one that is not an object, or the
// fields of an object.
@(private="file")
Merge_Node :: struct {
    name:string,
    text:string,
    object:bool,
    fields:[dynamic]Merge_Node,
}

// Reads an object over the one in into: a field it has replaces the same one,
// and an object merges into an object.
@(private="file")
merge_read :: proc(r:^serial.Text_Reader,into:^Merge_Node,depth:int) -> bool {
    if depth>serial.TEXT_MAX_DEPTH {return serial.text_fail(r,.Too_Deep)}
    if !serial.text_accept(r,'{') {return serial.text_fail(r,.Expected_Object)}
    if serial.text_accept(r,'}') {return true}
    for {
        serial.text_space(r)
        name:=serial.text_string(r) or_return
        name=strings.clone(name,context.temp_allocator)
        serial.text_expect(r,':') or_return
        found:^Merge_Node
        for &field in into.fields {
            if field.name==name {found=&field;break}
        }
        if found==nil {
            append(&into.fields,Merge_Node{name=name})
            found=&into.fields[len(into.fields)-1]
        }
        if serial.text_peek(r)=='{' {
            if !found.object {found^={name=name,object=true,fields=make([dynamic]Merge_Node,context.temp_allocator)}}
            merge_read(r,found,depth+1) or_return
        } else {
            start:=r.offset
            serial.text_skip(r,depth+1) or_return
            found^={name=name,text=r.text[start:r.offset]}
        }
        if serial.text_accept(r,',') {continue}
        return serial.text_expect(r,'}')
    }
}

@(private="file")
merge_write :: proc(w:^serial.Writer,node:^Merge_Node,depth:int) {
    if !node.object {
        serial.text_write_raw(w,node.text)
        return
    }
    if len(node.fields)==0 {
        serial.text_write_raw(w,"{}")
        return
    }
    for &field,i in node.fields {
        serial.write_u8(w,i==0?'{':',')
        serial.text_write_break(w,depth+1)
        serial.text_write_string(w,field.name)
        serial.text_write_raw(w,": ")
        merge_write(w,&field,depth+1)
    }
    serial.text_write_break(w,depth)
    serial.write_u8(w,'}')
}
