package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import input "mirai:engine/input"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The values with names of the types @(names) (core/names.odin) are declared
// in code. The editor declares a new one, or renames one the project
// declared, by writing that code: a new one goes to the file NAMES_FILE of
// the game, a rename puts @(name="...") on the constant and keeps its
// identifier. Saved data keeps the numbers of constants, so nothing saved
// changes; the names are seen once the game is built again, which both start.
// An input action is a member of an enum @(actions), named by its identifier,
// and saved data keeps its name. The code renames it, with the types in view
// (the rename of an editor of code, or an agent), and once that code is built
// a rename follows it: input.mirai of the project and the documents that keep
// it take the new name. A new one is written by hand, with its default.

NAMES_FILE :: "names.odin"
NAME_CAPACITY :: 32

Names_Error :: enum u8 {None,Not_A_Type,Invalid_Name,Taken,Full,Unknown,Not_Of_Project,No_Game,Write_Failed,Source_Changed,Action_In_Code,Action_Not_Declared,Action_Still_Declared}

names_error_text :: proc(e:Names_Error,type,name:string) -> string {
    switch e {
    case .None:
    case .Not_A_Type:     return fmt.tprintf("%q is not a type @(names); names.list lists them",type)
    case .Invalid_Name:   return fmt.tprintf("%q is not a name: use letters, digits and _ or spaces, starting with a letter, up to %d characters",name,NAME_CAPACITY)
    case .Taken:          return fmt.tprintf("%s already has a value named %q",type,name)
    case .Full:           return fmt.tprintf("%s has no free value left for %q: remove one it no longer uses",type,name)
    case .Unknown:        return fmt.tprintf("%s has no value named %q; names.list lists them",type,name)
    case .Not_Of_Project: return fmt.tprintf("%q of %s is declared by the engine or a plugin: rename only the values the project declares",name,type)
    case .No_Game:        return "the project has no game folder to declare the name in"
    case .Write_Failed:   return "the code of the name could not be written"
    case .Source_Changed: return "the line that declares the name changed since the last build: build, then rename it again"
    case .Action_In_Code: return fmt.tprintf("an input action is a member of the enum @(actions) of the game: add %s to it, with its default in the field [Action]input.Action_Default of its storage",action_member(name))
    case .Action_Not_Declared: return fmt.tprintf("the code built does not declare the action %q: rename the member of the enum @(actions) to %s in code (the rename of your editor of code renames its uses), build, and rename again to follow it",name,action_member(name))
    case .Action_Still_Declared: return "the code built still declares the old name of the action: rename the member in code and build first; this rename follows it in input.mirai and the documents"
    }
    return ""
}

// What data calls a name a person typed: in lower case, with _ for spaces.
name_normal :: proc(text:string,allocator:=context.temp_allocator) -> (name:string,ok:bool) {
    text:=strings.trim_space(text)
    if text=="" || len(text)>NAME_CAPACITY {return}
    b:=strings.builder_make(allocator)
    for c,i in transmute([]u8)text {
        switch c {
        case 'a'..='z','0'..='9','_': strings.write_byte(&b,c)
        case 'A'..='Z':               strings.write_byte(&b,c+32)
        case ' ','-':                 strings.write_byte(&b,'_')
        case: return
        }
        if i==0 && !(c>='a' && c<='z' || c>='A' && c<='Z') {return}
    }
    return strings.to_string(b),true
}

@(private)
named_type_by_name :: proc(info:^core.World_Info,name:string) -> ^core.Named_Type_Info {
    if info==nil {return nil}
    for &entry in info.named_types {
        if entry.name==name {return &entry}
    }
    return nil
}

// Declares a new value of a type @(names) in the game: the first free one
// after the highest it has, leaving out the last value of the type, which may
// be a sentinel with a name (the custom collision profile). The game is built
// again.
names_create :: proc(s:^Session,info:^core.World_Info,type:typeid,text:string) -> (value:i64,error:Names_Error) {
    t:=core.named_type_of(info,type)
    if t==nil {return 0,.Not_A_Type}
    name,valid:=name_normal(text)
    if !valid {return 0,.Invalid_Name}
    values:=core.names_of(info,type)
    for entry in values {
        if entry.name==name {return 0,.Taken}
    }
    if type==input.Action {return 0,.Action_In_Code}
    value=names_free(values,t.limit)
    if value>=t.limit {return 0,.Full}
    if !s.has_project {return 0,.No_Game}
    folder:=project.folder_path(s.project_root,.Game,context.temp_allocator)
    if !os.is_dir(folder) {return 0,.No_Game}
    file:=project.path(folder,NAMES_FILE,allocator=context.temp_allocator)
    source:string
    if bytes,read_error:=os.read_entire_file(file,context.temp_allocator);read_error==nil {source=string(bytes)}
    else {source=fmt.tprintf("package %s\n\n// Names the editor declared.\n",game_package_name(folder))}
    qualifier:=""
    if !strings.has_prefix(t.path,"project:game") {
        alias:=t.path[max(strings.last_index_any(t.path,"/:"),-1)+1:]
        qualifier=fmt.tprintf("%s.",alias)
        line:=fmt.tprintf("import %s \"%s\"\n",alias,t.path)
        if !strings.contains(source,line) {
            at:=strings.index_byte(source,'\n')+1
            source=strings.concatenate({source[:at],"\n",line,source[at:]},context.temp_allocator)
        }
    }
    ident:=strings.to_upper(fmt.tprintf("%s%s",t.prefix,name),context.temp_allocator)
    if !strings.has_suffix(source,"\n") {source=strings.concatenate({source,"\n"},context.temp_allocator)}
    source=fmt.tprintf("%s%s :: %s%s(%d)\n",source,ident,qualifier,t.name,value)
    if serial.file_write_atomic(file,transmute([]u8)source)!=.None {return 0,.Write_Failed}
    build_start(s)
    return value,.None
}

// The first value no constant has after the highest below limit-1; limit when none is left.
@(private)
names_free :: proc(values:[]core.Name_Info,limit:i64) -> (value:i64) {
    for entry in values {
        if entry.value<limit-1 {value=max(value,entry.value+1)}
    }
    for taken:=true;taken && value<limit; {
        taken=false
        for entry in values {taken ||= entry.value==value}
        if taken {value+=1}
    }
    return
}

// The identifier of the member of an enum @(actions) an action name is: "layer_back" is Layer_Back.
action_member :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for c,i in transmute([]u8)name {
        strings.write_byte(&b,(i==0 || name[i-1]=='_') && c>='a' && c<='z'?c-32:c)
    }
    return strings.to_string(b)
}

// Renames a value of a type @(names) the project declared, with @(name="...")
// on its constant, and the game is built again; an input action renamed in
// code is followed (action_follow).
names_rename :: proc(s:^Session,info:^core.World_Info,type:typeid,old,text:string) -> Names_Error {
    if core.named_type_of(info,type)==nil {return .Not_A_Type}
    name,valid:=name_normal(text)
    if !valid {return .Invalid_Name}
    if type==input.Action {
        from,named:=name_normal(old)
        if !named {return .Invalid_Name}
        return action_follow(s,info,from,name)
    }
    found:^core.Name_Info
    for &entry in core.names_of(info,type) {
        if entry.name==name && entry.name!=old {return .Taken}
        if entry.name==old {found=&entry}
    }
    if found==nil {return .Unknown}
    if !found.project || !s.has_project {return .Not_Of_Project}
    file:=project.path(s.project_root,found.file,allocator=context.temp_allocator)
    bytes,read_error:=os.read_entire_file(file,context.temp_allocator)
    if read_error!=nil {return .Write_Failed}
    lines:=strings.split(string(bytes),"\n",context.temp_allocator)
    if found.line<1 || found.line>len(lines) {return .Write_Failed}
    line:=lines[found.line-1]
    // The line is the one of the last build: the file may have changed since.
    declared:=strings.contains(line,fmt.tprintf("@(name=%q)",old)) if found.named else !strings.contains(line,"@(name=") && strings.contains(line,core.named_type_of(info,type).name)
    if !declared {return .Source_Changed}
    attribute:=fmt.tprintf("@(name=%q)",name)
    if at:=strings.index(line,"@(name=");at>=0 {
        end:=strings.index_byte(line[at:],')')
        if end<0 {return .Write_Failed}
        line=strings.concatenate({line[:at],attribute,line[at+end+1:]},context.temp_allocator)
    } else {
        indent:=len(line)-len(strings.trim_left_space(line))
        line=strings.concatenate({line[:indent],attribute," ",line[indent:]},context.temp_allocator)
    }
    lines[found.line-1]=line
    if serial.file_write_atomic(file,transmute([]u8)strings.join(lines,"\n",context.temp_allocator))!=.None {return .Write_Failed}
    build_start(s)
    return .None
}

// An input action renamed in code (its member in the enum @(actions), with
// the rename of an editor of code or by an agent): the input.mirai of the
// project and its documents take the new name. The code built and loaded has
// to declare it already, and no longer the old one.
@(private)
action_follow :: proc(s:^Session,info:^core.World_Info,old,name:string) -> Names_Error {
    if _,declared:=core.name_value(info,input.Action,name);!declared {return .Action_Not_Declared}
    if _,still:=core.name_value(info,input.Action,old);still {return .Action_Still_Declared}
    if s.has_project {
        bindings:=project.path(s.project_root,project.INPUT_FILE,allocator=context.temp_allocator)
        if text,read_error:=os.read_entire_file(bindings,context.temp_allocator);read_error==nil {
            if renamed:=input_file_rename(string(text),old,name);renamed!="" {
                if serial.file_write_atomic(bindings,transmute([]u8)renamed)!=.None {return .Write_Failed}
                input_maps_rebuild(s)
            }
        }
    }
    action_documents_rename(s,old,name)
    return .None
}

// The documents of the project that keep the action old take the name: the
// values stay and read by it. Each one changes as an edit, unsaved; those of
// plugins and the engine stay.
@(private)
action_documents_rename :: proc(s:^Session,old,name:string) {
    r:=files_registry(s)
    if r==nil {return}
    // Gathered first: a write tells the assets, which may look at the files again.
    paths:=make([dynamic]string,context.temp_allocator)
    for file in r.files {
        if file.id=={} || content_mounted(r,file.path) {continue}
        path:=asset.registry_file_path(r,file.path,context.temp_allocator)
        if _,held:=asset.registry_memory_find(r,file.path);!held {
            // The schema is at the front of the file: most name no action.
            front:asset.Asset
            if asset.asset_load_front(&front,path,context.temp_allocator)!=.None {continue}
            named:=serial.schema_choice_rename(&front.schema,old,name)>0
            asset.asset_close(&front)
            if !named {continue}
        }
        append(&paths,path)
    }
    for path in paths {
        data,present,readable:=file_contents(r,path,context.temp_allocator)
        if !present || !readable {continue}
        doc:asset.Document
        if asset.document_read(&doc,data,context.temp_allocator)!=.None {continue}
        if asset.document_choice_rename(&doc,old,name)>0 {
            if bytes,error:=asset.document_bytes(&doc,context.temp_allocator);error==.None {_=file_write(s,path,bytes,"Rename action")}
        }
        asset.document_destroy(&doc)
    }
}

// The text of input.mirai with the action old named name; "" when it does not name old.
input_file_rename :: proc(text,old,name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    quoted:=fmt.tprintf("%q",old)
    rest,changed:=text,false
    for {
        at:=strings.index(rest,`"name"`)
        if at<0 {break}
        after:=at+len(`"name"`)
        value:=len(rest)-len(strings.trim_left_space(rest[after:]))
        if value<len(rest) && rest[value]==':' {
            value=len(rest)-len(strings.trim_left_space(rest[value+1:]))
            if strings.has_prefix(rest[value:],quoted) {
                fmt.sbprintf(&b,"%s%q",rest[:value],name)
                rest,changed=rest[value+len(quoted):],true
                continue
            }
        }
        strings.write_string(&b,rest[:after])
        rest=rest[after:]
    }
    if !changed {return ""}
    strings.write_string(&b,rest)
    return strings.to_string(b)
}

// The package the files of the game folder declare; "game" without one.
@(private)
game_package_name :: proc(folder:string) -> string {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return "game"}
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    for entry in entries {
        if !strings.has_suffix(entry.name,".odin") {continue}
        bytes,read_error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if read_error!=nil {continue}
        for line in strings.split_lines(string(bytes),context.temp_allocator) {
            if strings.has_prefix(line,"package ") {return strings.trim_space(line[len("package "):])}
        }
    }
    return "game"
}

Api_Names_Params :: struct {
    type:[64]u8 `mirai:"text,optional,label=One of the types; empty: every type"`,
}

// Written by hand: a field of Odin cannot be named package.
@(private)
Api_Names_Result :: struct {types:[1]Api_Names_Type `mirai:"list"`}
Api_Names_Type :: struct {
    type:[128]u8 `mirai:"text"`,
    path:[API_PATH_BYTES]u8 `mirai:"text,key=package,label=The import path of the package that declares it"`,
    names:[1]Api_Names_Value `mirai:"list,label=The values the code declares"`,
}
Api_Names_Value :: struct {
    name:[128]u8 `mirai:"text,label=What a field of the type takes in scene.set and gives back"`,
    value:i64,
    project:bool `mirai:"label=Whether the project declares it: names.rename renames only those"`,
}

Api_Name_Create_Params :: struct {
    type:[64]u8 `mirai:"text"`,
    name:[64]u8 `mirai:"text,label=Letters and digits and _ or spaces; starting with a letter"`,
}
Api_Name_Create_Result :: struct {value:i64,building:bool}

Api_Name_Rename_Params :: struct {
    type:[64]u8 `mirai:"text"`,
    name:[64]u8 `mirai:"text"`,
    to:[64]u8 `mirai:"text,label=Letters and digits and _ or spaces; starting with a letter"`,
}
Api_Name_Rename_Result :: struct {building:bool}

@(private)
api_names_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="names.list",summary="The types @(names) of the project (locomotion modes, input actions, collision categories...) with the named values the code declares for each.",params=Api_Names_Params,result=Api_Names_Result,writes_result=true,flags={.Read_Only},run=api_names_list})
    api_register(s,st,{name="names.create",summary="Declares a new value of a type @(names) in game/names.odin, the first free one after its highest, and starts the build of the game; an input action is declared in code, as a member of the enum @(actions) of the game.",params=Api_Name_Create_Params,result=Api_Name_Create_Result,run=api_name_create})
    api_register(s,st,{name="names.rename",summary="Renames a value of a type @(names) that the project declared, with @(name) on its constant, and starts the build of the game; saved data keeps its number. An input action is renamed in code first (its member of the enum @(actions)); once built, this follows it: input.mirai of the project and the documents that keep it take the new name, as edits, unsaved.",params=Api_Name_Rename_Params,result=Api_Name_Rename_Result,run=api_name_rename})
}

@(private)
api_names_list :: proc(s:^Session,call:^api.Call) {
    info:=shown_world(s).info
    wanted:=base.text_get(api.call_params(call,Api_Names_Params).type[:])
    if wanted!="" && named_type_by_name(info,wanted)==nil {
        api.call_failf(call,api.INVALID_PARAMS,"%s",names_error_text(.Not_A_Type,wanted,""))
        return
    }
    out:=call.out
    serial.text_write_raw(out,`{"types":[`)
    first:=true
    if info!=nil {
        for t in info.named_types {
            if wanted!="" && t.name!=wanted {continue}
            if !first {serial.write_u8(out,',')};first=false
            serial.write_u8(out,'{');api.write_text(out,"type",t.name,true);api.write_text(out,"package",t.path)
            api.write_key(out,"names");serial.write_u8(out,'[')
            for entry,i in core.names_of(info,t.type) {
                if i>0 {serial.write_u8(out,',')}
                serial.write_u8(out,'{');api.write_text(out,"name",entry.name,true)
                api.write_key(out,"value");serial.text_write_int(out,entry.value)
                api.write_bool(out,"project",entry.project)
                serial.write_u8(out,'}')
            }
            serial.text_write_raw(out,"]}")
        }
    }
    serial.text_write_raw(out,"]}")
}

@(private)
api_name_create :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Name_Create_Params)
    type,name:=base.text_get(params.type[:]),base.text_get(params.name[:])
    info:=shown_world(s).info
    t:=named_type_by_name(info,type)
    if t==nil {
        api.call_failf(call,api.INVALID_PARAMS,"%s",names_error_text(.Not_A_Type,type,name))
        return
    }
    value,error:=names_create(s,info,t.type,name)
    if error!=.None {
        api.call_failf(call,api.INVALID_PARAMS,"%s",names_error_text(error,type,name))
        return
    }
    result:=api.call_result(call,Api_Name_Create_Result)
    result.value,result.building=value,s.build.phase==.Running
}

@(private)
api_name_rename :: proc(s:^Session,call:^api.Call) {
    params:=api.call_params(call,Api_Name_Rename_Params)
    type,name,to:=base.text_get(params.type[:]),base.text_get(params.name[:]),base.text_get(params.to[:])
    info:=shown_world(s).info
    t:=named_type_by_name(info,type)
    if t==nil {
        api.call_failf(call,api.INVALID_PARAMS,"%s",names_error_text(.Not_A_Type,type,name))
        return
    }
    if error:=names_rename(s,info,t.type,name,to);error!=.None {
        api.call_failf(call,api.INVALID_PARAMS,"%s",names_error_text(error,type,error==.Invalid_Name || error==.Taken || error==.Action_Not_Declared?to:name))
        return
    }
    api.call_result(call,Api_Name_Rename_Result).building=s.build.phase==.Running
}
