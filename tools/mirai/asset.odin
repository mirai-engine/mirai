package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import audio "mirai:audio"
import "mirai:cook/build"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:std/subprocess"

// mirai asset: reads and edits binary assets of any kind through the schema
// each file carries. Results go to stdout in forms meant to be parsed; what
// went wrong goes to stderr as "mirai asset <subcommand>: <file>: <reason>".
// Exit codes: 0 done, 1 failed or found differences or problems, 2 misuse.
//
// A scene and a .ui are documents a person or an agent writes as the text of
// mirai scene and mirai ui: dump prints that document, which the author
// program of the engine reads against the project the file is of, and verify
// adds what mirai scene check says of a scene. Neither is unpacked to tables.

Asset_Command :: struct {name,usage,summary:string,run:proc(root:string,args:[]string)->int}

ASSET_COMMANDS :: [?]Asset_Command{
    {"info","info <file>","Header, chunks and tables",asset_info},
    {"ls","ls <folder> [--cache <file>]","Assets of a folder: id, kind, bytes, dependencies and path",asset_ls},
    {"deps","deps <file> [--root <folder>] [--all|--users]","Dependencies of an asset, or the assets that depend on it",asset_deps},
    {"verify","verify <file>...","Checks the container, hash, tables and the rules of the kind; of a scene, what mirai scene check says",asset_verify},
    {"dump","dump <file> [--schema|--textconv]","The whole asset as JSON, a scene or a .ui as its document, or as the text git diffs",asset_dump},
    {"get","get <file> <path>","A table, a row or a value as JSON",asset_get},
    {"set","set <file> <path>=<value>...","Changes values and rewrites the file",asset_set},
    {"diff","diff <a> <b>","Differences by row key and field path",asset_diff},
    {"merge","merge <base> <ours> <theirs> [--out <file>]","Three-way merge by row and field; writes into <ours> as a git merge driver",asset_merge},
    {"unpack","unpack <file> <folder>","asset.json and one file per bulk column",asset_unpack},
    {"pack","pack <folder> <file>","The binary file of an unpack folder",asset_pack},
}

cmd_asset :: proc(root:string,args:[]string) -> int {
    if len(args)>0 {
        for command in ASSET_COMMANDS {
            if command.name==args[0] {return command.run(root,args[1:])}
        }
        fmt.eprintfln("mirai asset: unknown subcommand '%s'",args[0])
    }
    fmt.eprintln("Usage: mirai asset <subcommand> [arguments]")
    for command in ASSET_COMMANDS {fmt.eprintfln("  %-52s %s",command.usage,command.summary)}
    return 2
}

@(private="file")
misuse :: proc(command:string) -> int {
    for candidate in ASSET_COMMANDS {
        if candidate.name==command {fmt.eprintfln("Usage: mirai asset %s",candidate.usage)}
    }
    return 2
}

// argument_unknown with the usage of the subcommand.
@(private="file")
unknown :: proc(command,arg:string) -> int {
    argument_refuse(fmt.tprintf("asset %s",command),arg)
    return misuse(command)
}

@(private="file")
positionals :: proc(command:string,args:[]string) -> int {
    for arg in args {
        if !positional(arg) {return unknown(command,arg)}
    }
    return 0
}

@(private="file")
failed :: proc(command,file,reason:string,args:..any) -> int {
    fmt.eprintf("mirai asset %s: %s: ",command,file)
    fmt.eprintfln(reason,..args)
    return 1
}

@(private="file")
print :: proc(w:^serial.Writer) {
    bytes:=serial.writer_bytes(w)
    for len(bytes)>0 {
        count,error:=os.write(os.stdout,bytes)
        if error!=nil || count<=0 {break}
        bytes=bytes[count:]
    }
}

@(private="file")
error_text :: proc(error:asset.Error) -> string {
    switch error {
    case .None: return "no error"
    case .Truncated: return "the file is truncated"
    case .Not_An_Asset: return "not a Mirai asset"
    case .Version: return "a container or kind version this build does not read"
    case .Corrupt: return "the directory, a chunk or a table contradict each other"
    case .Hash: return "the content does not match its hash"
    case .Too_Large: return "needs more memory than the limit"
    case .Schema: return "the schema table is not valid"
    case .Out_Of_Memory: return "out of memory"
    case .Not_Found: return "does not exist"
    case .IO: return "could not be read or written"
    case .Invalid: return "contains something the format does not allow"
    }
    return "unknown error"
}

@(private="file")
locate_text :: proc(location:asset.Location,error:asset.Locate_Error) -> string {
    switch error {
    case .None: return ""
    case .Syntax: return "malformed path"
    case .Unknown_Table: return "no table has that name"
    case .Unknown_Column: return "the table has no such column"
    case .Missing_Row: return "the table has several rows: add [row] or [@key]"
    case .Row_Out_Of_Range: return "the table has no such row"
    case .Invalid_Key: return "that is not a key of the table"
    case .Unknown_Key: return "no row has that key"
    case .Value:
        switch location.value_error {
        case .None: return ""
        case .Syntax: return "malformed path"
        case .Unknown_Field: return "the type has no such field"
        case .Not_A_Struct: return "that has no fields"
        case .Not_An_Array: return "that is not an array"
        case .Out_Of_Range: return "index outside the array, or a number that does not fit the field"
        case .Not_A_Value: return "the path ends at a struct, an array or a row, not at a value"
        case .Wrong_Type: return "the value is not of the type of the field"
        case .Unknown_Member: return "the enum or bit set has no such member"
        case .Too_Long: return "the text does not fit the field"
        case .Not_A_Type: return "the type is not in the schema"
        }
    }
    return "invalid path"
}

@(private="file")
rule_text :: proc(rule:asset.Text_Rule) -> string {
    switch rule {
    case .None: return ""
    case .Not_An_Asset: return "\"mirai_asset\" is missing: this is not the text of an asset"
    case .Version: return "a text version this build does not read"
    case .Kind: return "\"kind\" is four characters, or a number"
    case .Id: return "\"id\" is 32 hexadecimal digits"
    case .Unknown_Flag: return "unknown flag"
    case .Number_Out_Of_Range: return "number out of range"
    case .Schema_First: return "\"schema\" goes before \"tables\", only once"
    case .Kind_First: return "in a type, \"kind\" goes before \"fields\", \"named\" and \"choices\", and \"named\" before \"by_name\""
    case .Unknown_Type_Kind: return "unknown type kind"
    case .Too_Many_Types: return "too many types"
    case .Schema_Invalid: return "the types of the schema contradict each other"
    case .Table_Name: return "table name missing, invalid or repeated"
    case .Columns_Order: return "in a table, \"name\" goes before \"columns\", only once"
    case .Data_Order: return "in a table, \"columns\" goes before \"data\", only once"
    case .Column: return "a column with an invalid name, type or alignment"
    case .Unknown_Compression: return "unknown compression"
    case .Unknown_Column: return "the table has no such column"
    case .Unknown_Ref: return "\"ref\" names a table that does not exist"
    case .Key: return "\"key\" is not a column of the table"
    case .Rows: return "\"rows\" does not match the rows of \"data\""
    case .Bulk_File: return "a bulk column needs its file, of rows*size bytes"
    case .Tables_Invalid: return "the tables contradict each other"
    case .Out_Of_Memory: return "out of memory"
    }
    return "invalid text"
}

@(private="file")
load :: proc(command,path:string,doc:^asset.Document) -> bool {
    if error:=asset.document_load(doc,path);error!=.None {
        failed(command,path,error_text(error))
        return false
    }
    return true
}

@(private="file")
write_id :: proc(w:^serial.Writer,id:base.Asset_Id) {serial.text_write_asset_id(w,id)}

@(private="file")
write_kind :: proc(w:^serial.Writer,kind:asset.Fourcc) {
    buffer:[4]u8
    serial.text_write_raw(w,asset.fourcc_text(kind,&buffer))
}

asset_info :: proc(_:string,args:[]string) -> int {
    if code:=positionals("info",args);code!=0 {return code}
    if len(args)!=1 {return misuse("info")}
    a:asset.Asset
    if error:=asset.asset_load(&a,args[0]);error!=.None {return failed("info",args[0],error_text(error))}
    defer asset.asset_close(&a)
    w:serial.Writer;serial.writer_init(&w)
    header:=a.blob.header
    serial.text_write_raw(&w,"kind: ");write_kind(&w,header.kind)
    if known,found:=asset.kind_info(header.kind);found {
        serial.text_write_raw(&w," (");serial.text_write_raw(&w,known.name);serial.text_write_raw(&w,")")
    }
    serial.text_write_raw(&w,"\nkind_version: ");serial.text_write_uint(&w,u64(header.kind_version))
    serial.text_write_raw(&w,"\nid: ");write_id(&w,header.id)
    if header.owner!={} {serial.text_write_raw(&w,"\nowner: ");write_id(&w,header.owner)}
    serial.text_write_raw(&w,"\nflags:")
    for flag in asset.Header_Flag {
        if flag in header.flags {serial.text_write_raw(&w,fmt.tprintf(" %v",flag))}
    }
    serial.text_write_raw(&w,fmt.tprintf("\nsize: %d\nalignment: %d\nhash: %016x %s\n",header.total_size,header.alignment,header.content_hash,asset.blob_verify_hash(&a.blob)?"ok":"MISMATCH"))
    serial.text_write_raw(&w,fmt.tprintf("dependencies: %d\n",len(a.dependencies)))
    for id in a.dependencies {serial.text_write_raw(&w,"  ");write_id(&w,id);serial.write_u8(&w,'\n')}
    serial.text_write_raw(&w,fmt.tprintf("chunks: %d\n",header.chunk_count))
    for at in 0..<int(header.chunk_count) {
        entry:=asset.blob_chunk(&a.blob,at)
        serial.text_write_raw(&w,"  ");write_kind(&w,entry.tag)
        serial.text_write_raw(&w,fmt.tprintf(" index %d offset %d stored %d size %d alignment %d %v\n",entry.index,entry.offset,entry.size,entry.uncompressed_size,1<<entry.alignment_log2,entry.compression))
    }
    serial.text_write_raw(&w,fmt.tprintf("tables: %d\n",len(a.tables)))
    for table in a.tables {
        serial.text_write_raw(&w,fmt.tprintf("  %s rows %d",table.name,table.rows))
        for flag in asset.Table_Flag {
            if flag in table.flags {serial.text_write_raw(&w,fmt.tprintf(" %v",flag))}
        }
        if table.key>=0 {serial.text_write_raw(&w,fmt.tprintf(" key %s",table.columns[table.key].name))}
        serial.write_u8(&w,'\n')
        for column in table.columns {
            type:=a.schema.types[column.type]
            serial.text_write_raw(&w,fmt.tprintf("    %s: %s %v, %d bytes",column.name==""?"(row)":column.name,type.name==""?"-":type.name,type.kind,column.size))
            if column.ref>=0 {serial.text_write_raw(&w,fmt.tprintf(", row of %s",a.tables[column.ref].name))}
            serial.write_u8(&w,'\n')
        }
    }
    print(&w)
    return 0
}

asset_ls :: proc(_:string,args:[]string) -> int {
    folder,cache:="",""
    for i:=0;i<len(args);i+=1 {
        switch {
        case args[i]=="--cache" && i+1<len(args): i+=1;cache=args[i]
        case !positional(args[i]): return unknown("ls",args[i])
        case folder=="": folder=args[i]
        case: return misuse("ls")
        }
    }
    if folder=="" {return misuse("ls")}
    r:asset.Registry
    asset.registry_init(&r,folder,cache,imported=imported_beside(folder))
    if error:=asset.registry_scan(&r);error!=.None {return failed("ls",folder,error_text(error))}
    w:serial.Writer;serial.writer_init(&w)
    problems:=0
    for &file in r.files {
        if file.state!=.Asset {continue}
        write_id(&w,file.id);serial.write_u8(&w,' ');write_kind(&w,file.kind)
        serial.text_write_raw(&w,fmt.tprintf(" %d %d %s\n",file.size,file.dependency_count,file.path))
    }
    for file in r.files {
        if file.state!=.Broken {continue}
        problems+=1
        serial.text_write_raw(&w,fmt.tprintf("! broken %s\n",file.path))
    }
    for duplicate in r.duplicates {
        problems+=1
        serial.text_write_raw(&w,"! duplicate ");write_id(&w,duplicate.id)
        serial.text_write_raw(&w,fmt.tprintf(" %s %s\n",r.files[duplicate.first].path,r.files[duplicate.second].path))
    }
    missing:[dynamic]asset.Registry_Missing
    asset.registry_missing(&r,&missing)
    for entry in missing {
        problems+=1
        serial.text_write_raw(&w,"! missing ");write_id(&w,entry.id)
        serial.text_write_raw(&w,fmt.tprintf(" %s\n",r.files[entry.file].path))
    }
    print(&w)
    return problems==0?0:1
}

asset_deps :: proc(_:string,args:[]string) -> int {
    file,folder:="",""
    all,users:=false,false
    for i:=0;i<len(args);i+=1 {
        switch {
        case args[i]=="--root" && i+1<len(args): i+=1;folder=args[i]
        case args[i]=="--all": all=true
        case args[i]=="--users": users=true
        case !positional(args[i]): return unknown("deps",args[i])
        case file=="": file=args[i]
        case: return misuse("deps")
        }
    }
    if file=="" || (all || users) && folder=="" || all && users {return misuse("deps")}
    a:asset.Asset
    if error:=asset.asset_load(&a,file);error!=.None {return failed("deps",file,error_text(error))}
    w:serial.Writer;serial.writer_init(&w)
    if folder=="" {
        for id in a.dependencies {write_id(&w,id);serial.write_u8(&w,'\n')}
        print(&w)
        return 0
    }
    r:asset.Registry
    asset.registry_init(&r,folder,imported=imported_beside(folder))
    if error:=asset.registry_scan(&r);error!=.None {return failed("deps",folder,error_text(error))}
    id:=a.blob.header.id
    missing:=0
    switch {
    case users:
        for at in asset.registry_dependents(&r,id) {write_id(&w,r.files[at].id);serial.text_write_raw(&w,fmt.tprintf(" %s\n",r.files[at].path))}
    case all:
        if _,known:=asset.registry_find(&r,id);!known {return failed("deps",file,"is not in %s",folder)}
        found:[dynamic]u32
        asset.registry_closure(&r,id,&found)
        for at in found {write_id(&w,r.files[at].id);serial.text_write_raw(&w,fmt.tprintf(" %s\n",r.files[at].path))}
    case:
        for dependency in a.dependencies {
            write_id(&w,dependency)
            if target,known:=asset.registry_find(&r,dependency);known {serial.text_write_raw(&w,fmt.tprintf(" %s\n",target.path))}
            else {missing+=1;serial.text_write_raw(&w," MISSING\n")}
        }
    }
    print(&w)
    return missing==0?0:1
}

// Everything that can be checked of a file without knowing who will use it,
// and the rules of its kind when it is one the engine defines.
@(private)
verify :: proc(path:string,types:^asset.Types) -> string {
    a:asset.Asset
    if error:=asset.asset_load(&a,path);error!=.None {return error_text(error)}
    defer asset.asset_close(&a)
    return verify_asset(&a,path,types)
}

// path: where the asset is, for what it says of a version this build does not read.
@(private="file")
verify_asset :: proc(a:^asset.Asset,path:string,types:^asset.Types) -> string {
    if !asset.blob_verify_hash(&a.blob) {return error_text(.Hash)}
    for &table in a.tables {
        for _,column in table.columns {
            if _,error:=asset.asset_column_data(a,&table,column);error!=.None {return fmt.tprintf("table %s: a chunk cannot be decompressed",table.name)}
        }
    }
    doc:asset.Document
    if error:=asset.document_from_asset(&doc,a);error!=.None {return error_text(error)}
    defer asset.document_destroy(&doc)
    if asset.document_check(&doc)!=.None {return "the tables contradict each other"}
    derived:[dynamic]base.Asset_Id
    defer delete(derived)
    if asset.document_dependencies(&doc,&derived)!=.None {return "a row has too many references"}
    same:=len(derived)==len(a.dependencies)
    for id,at in derived {same&&=at<len(a.dependencies) && a.dependencies[at]==id}
    if !same {return "the stored dependencies are not the ones its values name"}
    for table in doc.tables {
        for column in table.columns {
            if !schema_limits(&doc.schema,column.type) {continue}
            for row in 0..<table.rows {
                path:=fmt.tprintf("%s[%d]",table.name,row)
                if message,ok:=api.value_check(&doc.schema,column.type,column.data[row*column.size:][:column.size],path,context.temp_allocator);!ok {return fmt.tprintf("a value outside its schema: %s",message)}
            }
        }
    }
    // An asset this build does not read says how to make it again.
    if known,found:=asset.kind_info(a.blob.header.kind);found && known.version!=0 && a.blob.header.kind_version!=known.version {
        return asset.version_message(a,types,path,allocator=context.temp_allocator)
    }
    switch a.blob.header.kind {
    case asset.KIND_MESH:
        view,error:=asset.mesh_view(a,types)
        if error!=.None {return "mesh: counts or ranges outside their tables"}
        if !asset.mesh_check_indices(view) {return "mesh: an index, slot, weight or position out of range"}
    case asset.KIND_TEXTURE:
        if _,error:=asset.texture_view(a,types);error!=.None {return "texture: inconsistent size, format, layers or levels"}
    case asset.KIND_MATERIAL:
        if _,error:=asset.material_view(a,types);error!=.None {return "material: a value out of range or an invalid name"}
    case asset.KIND_SCENE:
        view,error:=asset.scene_view(a,types)
        if error!=.None {return "scene: a component table names rows that do not exist or are out of order"}
        if asset.scene_view_check(view)!=.None {return "scene: repeated ids, missing or cyclic parents, or prefab records without an entity"}
        roots:=0
        for parent in view.parents {roots+=int(parent==0)}
        if asset.asset_prefab(a) && roots!=1 {return fmt.tprintf("scene: a prefab with %d roots: put its entities under one in the editor, or make it a scene there",roots)}
    case asset.KIND_ANIMATION:
        if _,error:=asset.animation_view(a,types);error!=.None {return "animation: an invalid range, key or name"}
    case asset.KIND_SKELETON:
        if _,error:=asset.skeleton_view(a,types);error!=.None {return "skeleton: an invalid hierarchy, transform or bone reference"}
    case asset.KIND_SOUND:
        view,error:=asset.sound_view(a,types)
        if error!=.None {return "sound: inconsistent channels, sample rate, loop start, lossless data or file"}
        if view.info.encoding==.Lossless && view.info.sample_rate!=audio.MIXER_RATE {return fmt.tprintf("sound: coded at %d Hz, not the %d Hz the mixer plays: import its source again with mirai import",view.info.sample_rate,audio.MIXER_RATE)}
    case asset.KIND_UI:
        if !asset.ui_check(a,types) {return "interface: nodes out of preorder or without a box, or a style, image, animation, track or key that does not exist"}
    case asset.KIND_FONT:
        if _,error:=asset.font_view(a,types);error!=.None {return "font: the file is not a TrueType or OpenType font with the outlines it declares"}
    case asset.KIND_STRINGS:
        if _,error:=asset.strings_view(a,types);error!=.None {return "strings: an empty or repeated language or key, or an entry out of order, repeated, or outside the text or the UTF-8"}
    case asset.KIND_PROMPTS:
        if _,error:=asset.prompts_view(a,types);error!=.None {return "prompts: a family or an entry that does not exist, a key too many or too few, a part outside its texture, or a repeated entry"}
    case asset.KIND_RECORDS:
        if _,error:=asset.records_view(a,types);error!=.None {return "records: no type of rows, columns that are not valid (a name that is not a word or is there twice, options that do not fit its kind) or that a table of rows of another's type has, no defaults, a row with the id 0, a repeated id or name, or a name that is not a word"}
    }
    return ""
}

// Whether a value of the type can be outside its schema: integers alone, as
// the bytes of an image are, take any value.
@(private="file")
schema_limits :: proc(s:^serial.Schema,type:serial.Type_Index) -> bool {
    info:=serial.schema_type(s,type)
    #partial switch info.kind {
    case .Bool,.Int,.Uint,.Entity,.Entity_Id,.Asset: return false
    case .Array: return schema_limits(s,info.elem)
    }
    return true
}

// The scenes that pass are then checked by mirai scene check against the game
// of their project: whether their documents write them back, and the
// components they store otherwise than the game reads them.
asset_verify :: proc(root:string,args:[]string) -> int {
    if code:=positionals("verify",args);code!=0 {return code}
    if len(args)==0 {return misuse("verify")}
    types:asset.Types
    asset.types_init(&types)
    bad:=0
    scenes:=make([dynamic]string,context.temp_allocator)
    for path in args {
        if reason:=verify(path,&types);reason!="" {
            bad+=1
            fmt.printfln("FAIL %s: %s",path,reason)
        } else {
            fmt.printfln("ok %s",path)
            if strings.has_suffix(path,".scene") {append(&scenes,path)}
        }
    }
    if len(scenes)>0 {
        code,out,errors,problem:=author_files(root,"scene","check",scenes[:],true)
        if problem!="" {
            fmt.printfln("note: the components of the scenes were not checked against a game: %s",problem)
        } else {
            fmt.print(out)
            fmt.eprint(errors)
            if code!=0 {bad+=1}
        }
    }
    return bad==0?0:1
}

// The projects a file may be of, the likeliest first: the one it is in, the
// one the current folder is in and, when neither is, those of the folders
// under the current one (a checkout of the engine holds several).
@(private="file")
file_projects :: proc(file:string) -> []string {
    found:=make([dynamic]string,context.temp_allocator)
    add :: proc(found:^[dynamic]string,folder:string) {
        if folder!="" && !slice.contains(found[:],folder) {append(found,folder)}
    }
    add(&found,project_of(os.dir(project.path_absolute(file,context.temp_allocator))))
    here,_:=os.get_working_directory(context.temp_allocator)
    add(&found,project_of(here))
    if len(found)>0 {return found[:]}
    for pattern in ([]string{"*/"+project.PROJECT_FILE,"*/*/"+project.PROJECT_FILE}) {
        matches,_:=filepath.glob(join(here,pattern),context.temp_allocator)
        for match in matches {add(&found,project.path_absolute(os.dir(match),context.temp_allocator))}
    }
    return found[:]
}

// Runs the author program of the engine on files of a kind of document
// ("scene" or "ui") against the projects they may be of, and gives what it
// printed. Without build the engine is never built: git does not wait on a
// build to show a diff. problem: why the program did not run.
@(private="file")
author_files :: proc(root,kind,verb:string,files:[]string,build_engine:bool) -> (code:int,out,errors,problem:string) {
    projects:=file_projects(files[0])
    if len(projects)==0 {return 1,"","",fmt.tprintf("%s is in no project, and the current folder has none in it or above it: run it from the folder of the project",files[0])}
    mode:=build.engine_mode_resolve(root,.Dev)
    if build_engine && author_engine(root,"asset",mode)!=0 {return 1,"","","the engine did not build"}
    program:=build.engine_paths(root,mode,context.temp_allocator).author_program
    if !os.is_file(program) {return 1,"","",fmt.tprintf("the engine is not built, and its author program reads %s documents: mirai build engine builds it",kind)}
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,program)
    for folder in projects {append(&command,"--project",folder)}
    append(&command,"--engine",root,kind,verb)
    append(&command,..files)
    state,stdout,stderr,error:=subprocess.exec({command=command[:]},context.temp_allocator)
    if error!=nil {return 1,"","",fmt.tprintf("%s could not run",program)}
    return state.exit_code,string(stdout),string(stderr),""
}

// --textconv is what git diffs through diff.mirai.textconv: the text of
// Text_Options.diff, a scene and a .ui as their documents, and of a file this
// build does not read, one line that says why, so that a diff or a log that
// reaches one goes on.
asset_dump :: proc(root:string,args:[]string) -> int {
    file:=""
    options:asset.Text_Options
    for arg in args {
        switch {
        case arg=="--schema": options.schema=true
        case arg=="--textconv": options.diff=true
        case !positional(arg): return unknown("dump",arg)
        case file=="": file=arg
        case: return misuse("dump")
        }
    }
    if file=="" || options.schema && options.diff {return misuse("dump")}
    doc:asset.Document
    if options.diff {
        if error:=asset.document_load(&doc,file);error!=.None {
            fmt.printfln("mirai asset dump: %s",error_text(error))
            return 0
        }
    } else if !load("dump",file,&doc) {return 1}
    if kind,authored:=authored_kind(doc.kind);authored {
        if options.schema {return failed("dump",file,"a %s is dumped as its document, which has no schema: mirai asset info lists its tables",kind)}
        code,out,errors,problem:=author_files(root,kind,"read",{file},!options.diff)
        switch {
        case problem=="" && code==0:
            fmt.print(out)
            return 0
        case options.diff:
            line:=problem!=""?problem:strings.trim_space(errors)
            if cut:=strings.index_byte(line,'\n');cut>=0 {line=line[:cut]}
            fmt.printfln("mirai asset dump: %s",line)
            return 0
        case problem!="":
            return failed("dump",file,problem)
        }
        fmt.eprint(errors)
        return 1
    }
    w:serial.Writer;serial.writer_init(&w)
    if error:=asset.document_text_write(&doc,&w,options);error!=.None {return failed("dump",file,error_text(error))}
    print(&w)
    return 0
}

asset_get :: proc(_:string,args:[]string) -> int {
    if code:=positionals("get",args);code!=0 {return code}
    if len(args)!=2 {return misuse("get")}
    doc:asset.Document
    if !load("get",args[0],&doc) {return 1}
    location,error:=asset.document_locate(&doc,args[1])
    if error!=.None {return failed("get",args[0],"%s: %s (column %d)",args[1],locate_text(location,error),location.at+1)}
    w:serial.Writer;serial.writer_init(&w)
    switch {
    case location.row<0: asset.document_rows_write(&doc,&w,location.table,0)
    case location.column<0: asset.document_row_write(&doc,&w,location.table,location.row)
    case location.bit>=0: serial.text_write_raw(&w,location.bytes[location.bit>>3]&(1<<uint(location.bit&7))!=0?"true":"false")
    case: serial.text_write(&w,&doc.schema,location.type,location.bytes,.Pretty,0,location.is_text)
    }
    serial.write_u8(&w,'\n')
    print(&w)
    return 0
}

// A value typed in a shell: text, enum members and ids need no quotes.
@(private="file")
value_json :: proc(doc:^asset.Document,location:asset.Location,value:string) -> string {
    if len(value)>0 && (value[0]=='"' || value[0]=='[' || value[0]=='{') {return value}
    quote:=location.is_text
    #partial switch doc.schema.types[location.type].kind {
    case .Enum: quote=len(value)==0 || !(value[0]=='-' || value[0]>='0' && value[0]<='9')
    case .Asset: quote=true
    case .Entity,.Entity_Id: quote=strings.has_prefix(value,"0x") || strings.has_prefix(value,"0X")
    }
    if !quote {return value}
    w:serial.Writer;serial.writer_init(&w)
    serial.text_write_string(&w,value)
    return string(serial.writer_bytes(&w))
}

asset_set :: proc(_:string,args:[]string) -> int {
    if code:=positionals("set",args);code!=0 {return code}
    if len(args)<2 {return misuse("set")}
    doc:asset.Document
    if !load("set",args[0],&doc) {return 1}
    for assignment in args[1:] {
        equals:=strings.index_byte(assignment,'=')
        if equals<=0 {return failed("set",args[0],"%s: expected <path>=<value>",assignment)}
        path,value:=assignment[:equals],assignment[equals+1:]
        location,error:=asset.document_locate(&doc,path)
        if error!=.None {return failed("set",args[0],"%s: %s (column %d)",path,locate_text(location,error),location.at+1)}
        if location.row<0 || location.column<0 {return failed("set",args[0],"%s: the path names a table or a row; set changes values inside a column",path)}
        if location.bit>=0 {
            switch value {
            case "true": location.bytes[location.bit>>3]|=1<<uint(location.bit&7)
            case "false": location.bytes[location.bit>>3]&~=1<<uint(location.bit&7)
            case: return failed("set",args[0],"%s: expected true or false",path)
            }
            continue
        }
        text:=value_json(&doc,location,value)
        reader:serial.Text_Reader
        serial.text_reader_init(&reader,text)
        if serial.text_read(&reader,&doc.schema,location.type,location.bytes,location.is_text) {serial.text_end(&reader)}
        if reader.error.code!=.None {return failed("set",args[0],"%s: %s in '%s' (column %d)",path,serial.text_error_words(reader.error.code),text,reader.error.offset+1)}
    }
    if error:=asset.document_save(&doc,args[0]);error!=.None {return failed("set",args[0],error_text(error))}
    return 0
}

asset_diff :: proc(_:string,args:[]string) -> int {
    if code:=positionals("diff",args);code!=0 {return code}
    if len(args)!=2 {return misuse("diff")}
    a,b:asset.Document
    if !load("diff",args[0],&a) || !load("diff",args[1],&b) {return 2}
    w:serial.Writer;serial.writer_init(&w)
    count,error:=asset.document_diff(&a,&b,&w)
    if error!=.None {fmt.eprintfln("mirai asset diff: %v",error);return 2}
    print(&w)
    return count==0?0:1
}

// The merge driver of git (merge=mirai: "mirai asset merge %O %A %B"): the
// result goes into ours, and one line per conflict to stdout. An empty base is
// a file both sides added. Exit 1 with conflicts, whose values the merge left
// as ours had them; 2 when a file is not an asset or the result is not valid
// (as mirai asset verify says, when ours was), and then ours stays as it was.
asset_merge :: proc(_:string,args:[]string) -> int {
    files:=make([dynamic]string,context.temp_allocator)
    out:=""
    for i:=0;i<len(args);i+=1 {
        if args[i]=="--out" && i+1<len(args) {out=args[i+1];i+=1;continue}
        if !positional(args[i]) {return unknown("merge",args[i])}
        append(&files,args[i])
    }
    if len(files)!=3 {return misuse("merge")}
    if out=="" {out=files[1]}
    ours,origin,theirs:asset.Document
    if !load("merge",files[1],&ours) || !load("merge",files[2],&theirs) {return 2}
    base_doc:^asset.Document
    if info,error:=os.stat(files[0],context.temp_allocator);error==nil && info.size>0 {
        if !load("merge",files[0],&origin) {return 2}
        base_doc=&origin
    }
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    m:asset.Merge;defer asset.merge_destroy(&m)
    if error:=asset.scene_merge(&m,&types,&ours,base_doc,&theirs);error!=.None {failed("merge",files[1],error_text(error));return 2}
    data,error:=asset.document_bytes(&ours)
    if error!=.None {failed("merge",files[1],error_text(error));return 2}
    if ours.kind==asset.KIND_SCENE {
        check:asset.Scene
        if problem:=asset.scene_read(&check,&types,data);problem!=.None {failed("merge",files[1],"the result is not a valid scene: %s",error_text(problem));return 2}
        asset.scene_destroy(&check)
    }
    // Rows of a kind may name rows of another table by position, which a merge of rows does not
    // follow: a merge that breaks what ours kept is not written.
    if before:=verify(files[1],&types);before=="" {
        merged:asset.Asset
        if problem:=asset.asset_open(&merged,data);problem!=.None {failed("merge",files[1],"the result does not read: %s",error_text(problem));return 2}
        defer asset.asset_close(&merged)
        if reason:=verify_asset(&merged,out,&types);reason!="" {failed("merge",files[1],"the result is not valid: %s",reason);return 2}
    }
    if serial.file_write_atomic(out,data)!=.None {failed("merge",out,"could not be written");return 2}
    w:serial.Writer;serial.writer_init(&w)
    for conflict in m.conflicts {
        serial.text_write_raw(&w,"! ")
        switch conflict.kind {
        case .Value: serial.text_write_raw(&w,"value ")
        case .Removed: serial.text_write_raw(&w,conflict.ours?"removed-by-theirs ":"removed-by-ours ")
        case .Table: serial.text_write_raw(&w,"table ")
        }
        serial.text_write_raw(&w,conflict.path)
        serial.write_u8(&w,'\n')
    }
    print(&w)
    return len(m.conflicts)==0?0:1
}

// The kinds whose text is the document of mirai scene and mirai ui, by the
// name of that command.
@(private="file")
authored_kind :: proc(kind:asset.Fourcc) -> (name:string,authored:bool) {
    switch kind {
    case asset.KIND_SCENE: return "scene",true
    case asset.KIND_UI:    return "ui",true
    }
    return "",false
}

@(private="file")
authored_refusal :: proc(kind:string) -> string {
    return fmt.tprintf("a %s is not edited as tables: mirai %s read <asset> --out <file> gives its document, and mirai %s write <asset> <file> writes it back",kind,kind,kind)
}

MANIFEST :: "asset.json"

asset_unpack :: proc(_:string,args:[]string) -> int {
    if code:=positionals("unpack",args);code!=0 {return code}
    if len(args)!=2 {return misuse("unpack")}
    doc:asset.Document
    if !load("unpack",args[0],&doc) {return 1}
    if kind,authored:=authored_kind(doc.kind);authored {return failed("unpack",args[0],authored_refusal(kind))}
    if os.make_directory_all(args[1])!=nil && !os.is_dir(args[1]) {return failed("unpack",args[1],"the folder could not be created")}
    w:serial.Writer;serial.writer_init(&w)
    if error:=asset.document_text_write(&doc,&w,{schema=true,bulk=.Files});error!=.None {return failed("unpack",args[0],error_text(error))}
    if serial.file_write_atomic(join(args[1],MANIFEST),serial.writer_bytes(&w))!=.None {return failed("unpack",join(args[1],MANIFEST),"could not be written")}
    for table in doc.tables {
        if .Bulk not_in table.flags {continue}
        for column in table.columns {
            target:=join(args[1],asset.bulk_file_name(table.name,column.name))
            if serial.file_write_atomic(target,column.data)!=.None {return failed("unpack",target,"could not be written")}
        }
    }
    return 0
}

asset_pack :: proc(_:string,args:[]string) -> int {
    if code:=positionals("pack",args);code!=0 {return code}
    if len(args)!=2 {return misuse("pack")}
    manifest:=join(args[0],MANIFEST)
    text,read_error:=serial.file_read(manifest)
    if read_error!=.None {return failed("pack",manifest,read_error==.Not_Found?"does not exist":"could not be read")}
    folder:=args[0]
    loader:=asset.Bulk_Loader{proc(user:rawptr,name:string,allocator:mem.Allocator) -> ([]u8,bool) {
        // A name, never a path: a manifest reads nothing outside its folder.
        if name=="" || name[0]=='.' || strings.contains_any(name,"/\\:") {return nil,false}
        data,error:=serial.file_read(join((^string)(user)^,name),allocator)
        return data,error==.None
    },&folder}
    doc:asset.Document
    problem,ok:=asset.document_text_read(&doc,string(text),loader)
    if !ok {
        line,column:=serial.text_position(string(text),problem.offset)
        reason:=problem.code!=.None?serial.text_error_words(problem.code):rule_text(problem.rule)
        fmt.eprintfln("mirai asset pack: %s:%d:%d: %s",manifest,line,column,reason)
        return 1
    }
    if kind,authored:=authored_kind(doc.kind);authored {return failed("pack",manifest,authored_refusal(kind))}
    if error:=asset.document_save(&doc,args[1]);error!=.None {return failed("pack",args[1],error_text(error))}
    return 0
}

// The imported folder that goes with a folder of assets: that of the project
// or the plugin whose assets folder it is; "" for any other folder.
@(private="file")
imported_beside :: proc(folder:string) -> string {
    absolute:=project.path_absolute(folder,context.temp_allocator)
    names:=project.FOLDER_NAMES
    if os.base(absolute)!=names[.Assets] {return ""}
    return project.imported_path(os.dir(absolute),context.temp_allocator)
}
