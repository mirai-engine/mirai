package build

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// A .records that declares its type is the one declaration of that record
// type: a build generates into the package its assets go with (game/ for the
// project, runtime/ for a plugin) the struct of its rows, its <NAME>_DEFAULT
// and the enums of its enum columns, in one file per package. The file is
// kept by git, so the package compiles and tests without a build, and a build
// writes it only when a table says something else. The generator reads the
// struct back as a record type by the attribute it writes on it.

RECORDS_FILE :: "records_gen.odin"

// Where the tables of a part of the project generate their types.
@(private="file")
Records_Owner :: struct {
    assets:string,  // the folder of its assets
    prefix:string,  // the path its assets have among those of the project: "" or plugins/<name>
    folder:string,  // of the package the types go into
    path:string,    // its import path
    plugin:int,     // -1: the project
}

@(private="file")
Records_Source :: struct {
    path:string, // among the assets
    owner:int,
    type:string,
    description:string,
    columns:[]asset.Records_Column,
    defaults:[]string, // the literal of the default of each column; "": zero
}

// Writes the records_gen.odin of each package whose assets declare record
// types, and takes it away from one whose assets declare none.
records_write :: proc(p:^project.Project) -> (errors:[]string) {
    files,found:=records_files(p,context.temp_allocator)
    if len(found)>0 {return found}
    out:=make([dynamic]string,context.temp_allocator)
    for file in files {
        if file[1]=="" {
            if os.exists(file[0]) && os.remove(file[0])!=nil {append(&out,fmt.tprintf("%s could not be removed",file[0]))}
            continue
        }
        if current,error:=os.read_entire_file(file[0],context.temp_allocator);error==nil && string(current)==file[1] {continue}
        if os.write_entire_file(file[0],file[1])!=nil {append(&out,fmt.tprintf("%s could not be written",file[0]))}
    }
    return out[:]
}

// The records_gen.odin of each package that has one or should, each with
// its text; an empty text: the package no longer has record types.
records_files :: proc(p:^project.Project,allocator:=context.allocator) -> (files:[][2]string,errors:[]string) {
    out:=make([dynamic][2]string,allocator)
    failed:=make([dynamic]string,allocator)
    owners:=records_owners(p)
    sources:=make([dynamic]Records_Source,context.temp_allocator)
    for owner,at in owners {records_sources_read(owner,at,&sources,&failed,allocator)}
    for &a,i in sources {
        for &b in sources[:i] {
            if a.type==b.type {append(&failed,fmt.aprintf("%s and %s both declare the record type %s: rename the type of one of them",b.path,a.path,a.type,allocator=allocator))}
        }
    }
    if len(failed)>0 {return nil,failed[:]}
    for owner,at in owners {
        file:=project.path(owner.folder,RECORDS_FILE,allocator=allocator)
        own:=make([dynamic]^Records_Source,context.temp_allocator)
        for &source in sources {
            if source.owner==at {append(&own,&source)}
        }
        if len(own)==0 {
            if os.exists(file) {append(&out,[2]string{file,""})}
            continue
        }
        name,has_package:=package_of(owner.folder)
        if !has_package {
            append(&failed,fmt.aprintf("%s declares the record type %s, and %s has no Odin package to generate it into: add a .odin file there",own[0].path,own[0].type,owner.folder,allocator=allocator))
            continue
        }
        text,problems:=records_text(p,owners,sources[:],at,own[:],name,allocator)
        if len(problems)>0 {
            append(&failed,..problems)
            continue
        }
        append(&out,[2]string{file,text})
    }
    return out[:],failed[:]
}

@(private="file")
records_owners :: proc(p:^project.Project) -> []Records_Owner {
    names:=project.FOLDER_NAMES
    parts:=project.PART_NAMES
    owners:=make([dynamic]Records_Owner,context.temp_allocator)
    append(&owners,Records_Owner{project.path(p.root,names[.Assets],allocator=context.temp_allocator),"",project.path(p.root,names[.Game],allocator=context.temp_allocator),fmt.tprintf("project:%s",names[.Game]),-1})
    for index in p.active {
        plugin:=&p.plugins[index]
        if .Assets not_in plugin.manifest.parts {continue}
        name:=base.text_get(plugin.manifest.name[:])
        append(&owners,Records_Owner{
            project.path(plugin.folder,parts[.Assets],allocator=context.temp_allocator),
            fmt.tprintf("%s/%s",names[.Plugins],name),
            project.path(plugin.folder,parts[.Runtime],allocator=context.temp_allocator),
            plugin_import(p.root,plugin,name,parts[.Runtime],context.temp_allocator),
            index,
        })
    }
    return owners[:]
}

// The tables of the assets of an owner that declare their type, by path.
@(private="file")
records_sources_read :: proc(owner:Records_Owner,at:int,sources:^[dynamic]Records_Source,errors:^[dynamic]string,allocator:=context.allocator) {
    paths:=make([dynamic]string,context.temp_allocator)
    walk :: proc(folder,relative:string,paths:^[dynamic]string) {
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {return}
        slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
        for entry in entries {
            if strings.has_prefix(entry.name,".") {continue}
            path:=relative=="" ? entry.name : fmt.tprintf("%s/%s",relative,entry.name)
            if entry.type==.Directory {
                walk(entry.fullpath,path,paths)
            } else if strings.has_suffix(entry.name,".records") {
                append(paths,path)
            }
        }
    }
    walk(owner.assets,"",&paths)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    for path in paths {
        shown:=owner.prefix=="" ? path : fmt.tprintf("%s/%s",owner.prefix,path)
        bytes,read:=os.read_entire_file(project.path(owner.assets,path,allocator=context.temp_allocator),context.temp_allocator)
        if read!=nil {
            append(errors,fmt.aprintf("%s could not be read",shown,allocator=allocator))
            continue
        }
        a:asset.Asset
        if asset.asset_open(&a,bytes,context.temp_allocator)!=.None {
            append(errors,fmt.aprintf("%s is not a .records the engine reads: mirai asset verify says why",shown,allocator=allocator))
            continue
        }
        defer asset.asset_close(&a)
        view,error:=asset.records_view(&a,&types)
        if error!=.None {
            append(errors,fmt.aprintf("%s is not a table of game data this engine reads (%v): mirai asset verify says why",shown,error,allocator=allocator))
            continue
        }
        if !view.info.declares {continue}
        source:=Records_Source{path=shown,owner=at,type=strings.clone(asset.records_type(view),context.temp_allocator),description=strings.clone(serial.text_field(view.info.description[:]),context.temp_allocator)}
        source.columns=slice.clone(view.columns,context.temp_allocator)
        source.defaults=make([]string,len(view.columns),context.temp_allocator)
        if data,found:=asset.asset_column_data(&a,view.defaults,0);found==.None {
            stored:=view.defaults.columns[0].type
            for &c,i in source.columns {
                field:=serial.schema_field(&a.schema,stored,base.name_hash(serial.text_field(c.name[:])))
                if field==nil || int(field.offset)+int(a.schema.types[field.type].size)>len(data) {continue}
                source.defaults[i]=value_literal(&a.schema,field.type,data[field.offset:][:a.schema.types[field.type].size])
            }
        }
        append(sources,source)
    }
}

// The text of the records_gen.odin of the owner at index.
@(private="file")
records_text :: proc(p:^project.Project,owners:[]Records_Owner,sources:[]Records_Source,at:int,own:[]^Records_Source,package_name:string,allocator:=context.allocator) -> (text:string,errors:[]string) {
    failed:=make([dynamic]string,allocator)
    owner:=owners[at]
    imports:=make(map[string]string,context.temp_allocator) // import path -> alias
    core_used,base_used:=false,false
    body:=strings.builder_make(context.temp_allocator)
    for source in own {
        for &c in source.columns {
            name:=serial.text_field(c.name[:])
            if c.kind!=.Enum {continue}
            values:=strings.fields(serial.text_field(c.values[:]),context.temp_allocator)
            fmt.sbprintf(&body,"\n%s :: enum u8 {{%s}}\n",serial.text_field(c.type[:]),strings.join(values,",",context.temp_allocator))
            _=name
        }
        fmt.sbprintf(&body,"\n@(record=%q",source.path)
        if source.description!="" {fmt.sbprintf(&body,",description=%q",records_line(source.description))}
        fmt.sbprintf(&body,")\n%s :: struct {{\n",source.type)
        defaults:=strings.builder_make(context.temp_allocator)
        for &c,i in source.columns {
            name:=serial.text_field(c.name[:])
            type:string
            switch c.kind {
            case .Int:    type="i32"
            case .Float:  type="f32"
            case .Bool:   type="bool"
            case .Enum,.Type: type=serial.text_field(c.type[:])
            case .Asset:  type="base.Asset_Id";base_used=true
            case .Text:   type="core.Text";core_used=true
            case .String: type=fmt.tprintf("[%d]u8",c.length)
            case .Record:
                core_used=true
                named:=serial.text_field(c.type[:])
                target:^Records_Source
                for &other in sources {
                    if other.type==named {target=&other;break}
                }
                if target==nil {
                    append(&failed,fmt.aprintf("%s: column %s names the record type %s, which no .records declares: name one of the record types there are, or make its table",source.path,name,named,allocator=allocator))
                    continue
                }
                if target.owner==at {
                    type=fmt.tprintf("core.Record(%s)",named)
                    break
                }
                to:=owners[target.owner]
                if owner.plugin>=0 && (to.plugin<0 || !project.plugin_reaches(p.plugins,owner.plugin,base.text_get(p.plugins[to.plugin].manifest.name[:]),false)) {
                    append(&failed,fmt.aprintf("%s: column %s names the record type %s of %s, which this plugin does not depend on: name a record type of the plugin or of a plugin in its dependencies",source.path,name,named,target.path,allocator=allocator))
                    continue
                }
                alias,known:=imports[to.path]
                if !known {
                    alias=fmt.tprintf("records_%d",len(imports))
                    imports[to.path]=alias
                }
                type=fmt.tprintf("core.Record(%s.%s)",alias,named)
            }
            if c.count>0 {type=fmt.tprintf("[%d]%s",c.count,type)}
            tags:=make([dynamic]string,context.temp_allocator)
            #partial switch c.kind {
            case .Int,.Float:
                if c.has_min {append(&tags,fmt.tprintf("min=%v",c.min))}
                if c.has_max {append(&tags,fmt.tprintf("max=%v",c.max))}
                if unit:=serial.text_field(c.unit[:]);unit!="" {append(&tags,fmt.tprintf("unit=%s",unit))}
            case .Asset:
                if kinds:=serial.text_field(c.asset_kind[:]);kinds!="" {append(&tags,fmt.tprintf("kind=%s",kinds))}
            case .String:
                append(&tags,"text")
            }
            if was:=serial.text_field(c.was[:]);was!="" {append(&tags,fmt.tprintf("was=%s",was))}
            fmt.sbprintf(&body,"    %s:%s",name,type)
            if len(tags)>0 {fmt.sbprintf(&body," `mirai:\"%s\"`",strings.join(tags[:],",",context.temp_allocator))}
            strings.write_byte(&body,',')
            if description:=serial.text_field(c.description[:]);description!="" {fmt.sbprintf(&body," // %s",records_line(description))}
            strings.write_byte(&body,'\n')
            if source.defaults[i]!="" {fmt.sbprintf(&defaults,"%s%s=%s",strings.builder_len(defaults)>0?",":"",name,source.defaults[i])}
        }
        strings.write_string(&body,"}\n")
        if strings.builder_len(defaults)>0 {
            buffer:[512]u8
            constant,_,_:=core.default_names(source.type,buffer[:])
            fmt.sbprintf(&body,"%s :: %s{{%s}}\n",constant,source.type,strings.to_string(defaults))
        }
    }
    if len(failed)>0 {return "",failed[:]}
    b:=strings.builder_make(allocator)
    fmt.sbprintf(&b,"package %s\n\n// Generated by mirai build from the .records of the assets that declare their type: edit those, not this.\n",package_name)
    lines:=make([dynamic]string,context.temp_allocator)
    if core_used {append(&lines,`import "mirai:core"`)}
    if base_used {append(&lines,`import "mirai:std/base"`)}
    for path,alias in imports {append(&lines,fmt.tprintf("import %s %q",alias,path))}
    slice.sort(lines[:])
    if len(lines)>0 {strings.write_byte(&b,'\n')}
    for line in lines {fmt.sbprintf(&b,"%s\n",line)}
    strings.write_string(&b,strings.to_string(body))
    return strings.to_string(b),nil
}

// A text on one line: what a comment or an attribute of the generated file holds.
@(private="file")
records_line :: proc(text:string) -> string {
    line,_:=strings.replace_all(strings.trim_space(text),"\n"," ",context.temp_allocator)
    line,_=strings.replace_all(line,"\r","",context.temp_allocator)
    return line
}

// The Odin literal of a value of a stored type; "" for a value of zeros.
@(private="file")
value_literal :: proc(s:^serial.Schema,type:serial.Type_Index,bytes:[]u8) -> string {
    if mem.check_zero(bytes) || !serial.type_valid(s,type) {return ""}
    t:=s.types[type]
    if t.named!=.None {return fmt.tprint(number_bytes(bytes,true))}
    #partial switch t.kind {
    case .Bool:
        return "true"
    case .Int:
        return fmt.tprint(number_bytes(bytes,true))
    case .Uint:
        return fmt.tprint(u64(number_bytes(bytes,false)))
    case .Float:
        if len(bytes)==4 {return fmt.tprint((^f32)(raw_data(bytes))^)}
        if len(bytes)==8 {return fmt.tprint((^f64)(raw_data(bytes))^)}
    case .Enum:
        value:=number_bytes(bytes,false)
        for choice in serial.schema_choices(s,type) {
            if choice.value==value {return fmt.tprintf(".%s",choice.name)}
        }
        return fmt.tprint(value)
    case .Bit_Set:
        members:=make([dynamic]string,context.temp_allocator)
        bits:=u64(number_bytes(bytes,false))
        for choice in serial.schema_choices(s,type) {
            if choice.value>=0 && choice.value<64 && bits&(1<<u64(choice.value))!=0 {append(&members,fmt.tprintf(".%s",choice.name))}
        }
        return fmt.tprintf("{{%s}}",strings.join(members[:],",",context.temp_allocator))
    case .Asset:
        id:base.Asset_Id
        mem.copy(&id,raw_data(bytes),size_of(id))
        return fmt.tprintf("{{%d,%d}}",id[0],id[1])
    case .Struct:
        parts:=make([dynamic]string,context.temp_allocator)
        for field in serial.schema_fields(s,type) {
            size:=int(s.types[field.type].size)
            if int(field.offset)+size>len(bytes) {continue}
            if part:=value_literal(s,field.type,bytes[field.offset:][:size]);part!="" {append(&parts,fmt.tprintf("%s=%s",field.name,part))}
        }
        return fmt.tprintf("{{%s}}",strings.join(parts[:],",",context.temp_allocator))
    case .Array:
        parts:=make([dynamic]string,context.temp_allocator)
        size:=int(s.types[t.elem].size)
        for i in 0..<int(t.count) {
            if (i+1)*size>len(bytes) {break}
            if part:=value_literal(s,t.elem,bytes[i*size:][:size]);part!="" {append(&parts,fmt.tprintf("%d=%s",i,part))}
        }
        return fmt.tprintf("{{%s}}",strings.join(parts[:],",",context.temp_allocator))
    }
    return ""
}

// An integer of 1, 2, 4 or 8 bytes, signed or not, as an i64.
@(private="file")
number_bytes :: proc(bytes:[]u8,signed:bool) -> i64 {
    switch len(bytes) {
    case 1: return signed ? i64((^i8)(raw_data(bytes))^) : i64(bytes[0])
    case 2: return signed ? i64((^i16)(raw_data(bytes))^) : i64((^u16)(raw_data(bytes))^)
    case 4: return signed ? i64((^i32)(raw_data(bytes))^) : i64((^u32)(raw_data(bytes))^)
    case 8: return (^i64)(raw_data(bytes))^
    }
    return 0
}
