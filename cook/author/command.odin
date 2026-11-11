package author

import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:engine/gui"
import escene "mirai:engine/scene"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The commands mirai ui, mirai scene and mirai texts, which the author
// program of the engine runs: a project reads, checks and writes the
// documents of its interfaces and scenes, and the texts of its .strings,
// with no editor.
//
//   read <asset> [--out <file>]   the document of the asset, as ui.inspect or
//                                 scene.inspect with root give it
//   write <asset> <document>      makes the asset say what the file of the
//                                 document declares, as ui.write and
//                                 scene.write do; an asset that does not
//                                 exist yet is made
//   check [<asset>...]            what the assets, all without one, would fail
//                                 with in the game
//   texts list                    every key and what it says in each language,
//                                 as the CSV translators take
//   texts set <key> <language> <text>   makes a key say a text in a language,
//                                 by its code; a key no .strings has is added
//   texts missing                 who shows a key no .strings has, and the
//                                 keys that say nothing in a language of the game
//   texts export <file.csv>       the CSV of list, to a file
//   texts import <file.csv>       makes the keys of a CSV say its texts
//
// The asset is the source: a document is read from it when it is wanted and
// kept nowhere.
//
// The types of the game, which the paths an interface binds and the
// components of a scene are read against, are those of the library of the
// editor of the project as it was built last. Without it only an interface is read: nothing
// is written or checked that the game could not be asked about, and the
// command says what builds the library.
//
// Results go to output and failures to errors as "mirai ui write: <asset>:
// <reason>". Exit codes: 0 done, 1 failed, 2 misuse.

// The asset may also be a file outside the assets of the project: that file
// read in place of the asset with its id (another version of it, as git
// gives one to diff), or as one more asset when the project has no asset with
// its id. Given several --project, the command runs on the first whose assets
// have the asset of the first file it names.

COMMAND_USAGE :: `Usage: mirai ui|scene read <asset> [--out <file>]
       mirai ui|scene write <asset> <document file>
       mirai ui|scene check [<asset>...]
       mirai texts list | missing | set <key> <language> <text> | export <file.csv> | import <file.csv>`

// What a command reads and writes: the interfaces, or the scenes.
Document_Kind :: enum u8 {Ui,Scene}

// The extension of the assets of each kind.
KIND_EXTENSIONS :: [Document_Kind]string{.Ui=".ui",.Scene=".scene"}

@(private="file")
kind_extension :: proc(kind:Document_Kind) -> string {
    extensions:=KIND_EXTENSIONS
    return extensions[kind]
}

@(private="file")
kind_name :: proc(kind:Document_Kind) -> string {return "ui" if kind==.Ui else "scene"}

// The project a command works on: its assets and, when it was built, the
// types of its game.
Project :: struct {
    root:string,
    name:string,
    assets_root:string,
    registry:asset.Registry,
    types:asset.Types,
    assets:Assets,
    library:host.Project_Library,
    info:^core.World_Info, // the types of the game as it was built last; nil: none
    source:string,         // the code of the language its texts are written in (UI_Settings.source)
    untyped:string,        // why it has none, with what gives them
    recipes:[]Recipe,       // of the engine and of its active plugins
    scratch:Scratch_World,  // where a recipe is run; made the first time
}

// What builds the library the types of a game come from.
BUILD_FIX :: "mirai build editor <project> builds it"


// Opens the project at root with the assets of its plugins. library false
// leaves the types of its game out. problem: why it does not open.
project_open :: proc(p:^Project,root,engine:string,library:=true) -> (problem:string) {
    opened,error:=project.open(root,engine,context.temp_allocator)
    if error.code!=.None {return project.error_text(root,error,context.temp_allocator)}
    p.root=strings.clone(opened.root)
    p.name=strings.clone(base.text_get(opened.manifest.name[:]))
    p.assets_root=project.folder_path(p.root,.Assets)
    asset.registry_init(&p.registry,p.assets_root,imported=project.imported_path(p.root,context.temp_allocator))
    for mount in host.project_asset_mounts(&opened,context.temp_allocator) {asset.registry_mount(&p.registry,mount.folder,mount.prefix,mount.imported)}
    asset.types_init(&p.types)
    p.assets={&p.registry,&p.types}
    if os.is_dir(p.assets_root) && asset.registry_scan(&p.registry)!=.None {return fmt.tprintf("the assets of %s could not be read",p.assets_root)}
    ui_settings:gui.UI_Settings
    project.settings_load({{name="UI_Settings",info=type_info_of(gui.UI_Settings),value=&ui_settings,default=proc(dst:rawptr) {(^gui.UI_Settings)(dst)^=gui.UI_SETTINGS_DEFAULT}}},p.root,engine,{.Project})
    p.source=strings.clone(base.text_get(ui_settings.source[:]))
    if library {project_library_open(p)}
    p.recipes=recipes_read(project.recipe_folders(&opened,context.temp_allocator))
    return ""
}

project_close :: proc(p:^Project) {
    scratch_world_free(&p.scratch)
    recipes_free(p.recipes)
    if p.library.handle!=nil {host.project_library_unload(&p.library)}
    asset.registry_destroy(&p.registry)
    asset.types_destroy(&p.types)
    delete(p.root)
    delete(p.name)
    delete(p.assets_root)
    delete(p.source)
    delete(p.untyped)
    p^={}
}

// The types of the game of the project: those of the library of its editor.
@(private="file")
project_library_open :: proc(p:^Project) {
    path:=project.project_library(p.root,"editor",context.temp_allocator)
    if !os.is_file(path) {
        p.untyped=strings.clone("the project has no built library, where the types of its game are: "+BUILD_FIX)
        return
    }
    library,error:=host.project_library_load(path,0)
    if error!=.None {
        p.untyped=fmt.aprintf("%s; %s again",host.library_error_text(error,path),BUILD_FIX)
        return
    }
    p.library=library
    p.info=&p.library.info
}

// The path of an asset as the registry names it, from how a person names it:
// under the folder of the assets, with forward slashes.
asset_path :: proc(path:string) -> string {
    forward,_:=strings.replace_all(path,"\\","/",context.temp_allocator)
    return strings.trim_prefix(strings.trim_prefix(forward,"./"),"assets/")
}

// ---------------------------------------------------------------- interfaces

// The document of the .ui a path or an id names, as ui.inspect gives it, on
// one line. problem: why there is none.
ui_read :: proc(p:^Project,named:string,out:^serial.Writer) -> (problem:string) {
    id,unknown:=asset.registry_resolve(&p.registry,asset_path(named),".ui")
    if unknown!="" {return fmt.tprintf("asset: %s",unknown)}
    r:Records
    if !records_read(p.assets,id,&r,context.temp_allocator) {
        return fmt.tprintf("asset %s is not a .ui that loads; pass the path of a .ui of the project or its id",named)
    }
    reading:=Reading{allocator=context.temp_allocator}
    args:=Tree_Args{reading=&reading,types=&p.types,registry=&p.registry,assets=p.assets,asset=id}
    libs:=doc_libs(&args,&r)
    texts:=texts_read(p.assets,p.source)
    document_write(out,&p.types,&r,-1,libs[:],p.assets,&texts)
    return ""
}

// What a write did.
Written :: struct {
    path:string, // of the asset, in the temporary allocator
    fresh:bool,  // the file did not exist
    same:bool,   // the file already said it: nothing was written
    changed:bool, // a scene: something of an entity it kept is another
    first:string, // a scene: the first thing that is, in the temporary allocator
    followed:int, // an interface: the files that use it as a widget and were written to follow its parameters
    made,removed:int,
    stored:[]escene.Stored, // a scene: the components of the game the file stored with another layout, now written with the game's
}

// Makes the .ui a path names say what a document declares, as ui.write does
// with save: a path that names nothing yet makes the file, whose id is the
// same for that path every time. A document ui.write refuses is refused, and
// the file stays as it was, and the files that use it as a widget follow
// where its parameters go now. Its paths are checked against p.info: the
// command refuses to write without it. problem: why.
ui_write :: proc(p:^Project,named,text:string) -> (written:Written,problem:string) {
    path:=asset_path(named)
    record,found:=asset.registry_find_path(&p.registry,path)
    fresh:=!found && strings.has_suffix(path,".ui") && !strings.contains_rune(path,':')
    r:Records
    id:base.Asset_Id
    if fresh {
        id=asset.content_id(p.name,"ui",path)
        if !records_load(&r,ui_empty_data(),context.temp_allocator) {return {},"the .ui could not be made: memory ran out"}
    } else {
        unknown:string
        if id,unknown=asset.registry_resolve(&p.registry,path,".ui");unknown!="" {return {},fmt.tprintf("asset: %s",unknown)}
        if !records_read(p.assets,id,&r,context.temp_allocator) {
            return {},fmt.tprintf("asset %s is not a .ui that loads; pass the path of a .ui of the project or its id",named)
        }
        record,_=asset.registry_find(&p.registry,id)
        path=strings.clone(record.path,context.temp_allocator)
    }
    texts:=texts_read(p.assets,p.source)
    params:=widget_params(p.assets,id)
    bytes:[]u8
    imports:[]ui.Tree_Data
    if bytes,imports,problem=ui_apply(p,id,&r,text,&texts,&written);problem!="" {return {},problem}
    written.path,written.fresh=path,fresh
    file:=project.path(p.assets_root,path,allocator=context.temp_allocator) if fresh else asset.registry_file_path(&p.registry,path,context.temp_allocator)
    if problem=file_put(p,file,path,bytes,&written);problem!="" {return}
    if problem=texts_put(p,&texts);problem!="" {return}
    // What the files that use this widget gave follows where its parameters go now.
    written.followed=widget_params_follow(p.assets,id,params_changes(params,data_params(records_data(&r),imports)),proc(user:rawptr,id:base.Asset_Id,records:^Records) -> bool {
        p:=(^Project)(user)
        record,found:=asset.registry_find(&p.registry,id)
        if !found {return false}
        path:=strings.clone(record.path,context.temp_allocator)
        bytes,_,_,loads:=records_bytes(p.assets,id,records)
        if !loads {return false}
        put:Written
        return file_put(p,asset.registry_file_path(&p.registry,path,context.temp_allocator),path,bytes,&put)==""
    },p)
    return
}

// The bytes of the .ui id once the document text declares it in r, with what
// its keys say set in texts. problem: why the document is refused.
@(private)
ui_apply :: proc(p:^Project,id:base.Asset_Id,r:^Records,text:string,texts:^Texts,written:^Written) -> (bytes:[]u8,imports:[]ui.Tree_Data,problem:string) {
    reading:=Reading{allocator=context.temp_allocator,raw=text,assets=registry_assets(&p.registry)}
    args:=Tree_Args{reading=&reading,types=&p.types,registry=&p.registry,assets=p.assets,info=p.info,asset=id,texts=texts}
    applied,loads:bool
    if written.made,written.removed,applied=document_apply(&args,r,-1,text);!applied {return nil,nil,reading.problem}
    if bytes,imports,loads=document_bytes(&args,id,r);!loads {return nil,nil,reading.problem}
    return
}

// Writes the file of an asset unless it already holds those bytes, and has
// the registry see it. problem: why it could not.
@(private)
file_put :: proc(p:^Project,file,path:string,bytes:[]u8,written:^Written) -> (problem:string) {
    if current,error:=os.read_entire_file(file,context.temp_allocator);error==nil && slice.equal(current,bytes) {
        written.same=true
        return ""
    }
    if slash:=strings.last_index_byte(file,'/');slash>0 {os.make_directory_all(file[:slash])}
    if serial.file_write_atomic(file,bytes)!=.None {return fmt.tprintf("%s could not be written. Nothing changed",file)}
    if asset.registry_refresh(&p.registry,{path})!=.None {return fmt.tprintf("%s was written and the assets could not be read again",file)}
    return ""
}

// Writes the .strings the changes of the texts touched. problem: why it could not.
@(private)
texts_put :: proc(p:^Project,t:^Texts) -> (problem:string) {
    written:[]Texts_Written
    if written,problem=texts_written(t,&p.types,asset.content_id(p.name,"strings",TEXTS_HOME));problem!="" {return}
    for file in written {
        put:Written
        if problem=file_put(p,asset.registry_file_path(&p.registry,file.path,context.temp_allocator),file.path,file.bytes,&put);problem!="" {return}
    }
    return ""
}

// mirai texts: the keys of the .strings of the project, read and written
// through texts.odin as the editor does it. Exit code 1 for missing when
// something is.
@(private="file")
texts_command :: proc(p:^Project,args:[]string,output,errors:io.Writer) -> int {
    t:=texts_read(p.assets,p.source)
    problem:=""
    switch {
    case len(args)==1 && args[0]=="list":
        fmt.wprint(output,texts_csv(&t))
    case len(args)==1 && args[0]=="missing":
        lines:=texts_missing(&t,texts_uses(p.assets))
        for line in lines {fmt.wprintln(output,line)}
        return 1 if len(lines)>0 else 0
    case len(args)==2 && args[0]=="export":
        if serial.file_write_atomic(args[1],transmute([]u8)texts_csv(&t))!=.None {problem=fmt.tprintf("%s could not be written",args[1])}
    case len(args)==4 && args[0]=="set":
        problem=texts_set(&t,args[1],args[2],args[3])
    case len(args)==2 && args[0]=="import":
        bytes,error:=os.read_entire_file(args[1],context.temp_allocator)
        if error!=nil {problem=fmt.tprintf("%s could not be read",args[1])} else {
            set:int
            if set,problem=texts_csv_take(&t,string(bytes));problem=="" {fmt.wprintfln(output,"%d texts",set)} else {problem=fmt.tprintf("%s: %s. Nothing changed",args[1],problem)}
        }
    case:
        fmt.wprintln(errors,COMMAND_USAGE)
        return 2
    }
    if problem=="" {problem=texts_put(p,&t)}
    if problem!="" {
        fmt.wprintfln(errors,"mirai texts %s: %s",args[0],problem)
        return 1
    }
    return 0
}

// Checks the .ui of the project, or those of ids, against the types of the
// game: what does not load, the names that resolve to nothing, the paths
// they bind that it lacks and the procedures their Draw nodes name.
ui_check :: proc(p:^Project,ids:[]base.Asset_Id,problems:^[dynamic]Bind_Problem) {
    types:Bind_Types
    defer bind_types_free(&types)
    if len(ids)==0 {
        bind_check_all(problems,&types,context.allocator,p.assets,p.info)
    } else {
        for id in ids {bind_check_file(problems,&types,context.allocator,p.assets,p.info,id)}
    }
}

// ---------------------------------------------------------------- the command

@(private="file")
Run :: struct {
    p:^Project,
    kind:Document_Kind,
    verb:string,
    output,errors:io.Writer,
    failed:bool,
}

@(private="file")
run_fail :: proc(run:^Run,what,why:string) {
    run.failed=true
    if what=="" {fmt.wprintfln(run.errors,"mirai %s %s: %s",kind_name(run.kind),run.verb,why)}
    else {fmt.wprintfln(run.errors,"mirai %s %s: %s: %s",kind_name(run.kind),run.verb,what,why)}
}

command :: proc(args:[]string,output,errors:io.Writer) -> int {
    engine:string
    roots:=make([dynamic]string,context.temp_allocator)
    rest:=make([dynamic]string,context.temp_allocator)
    for at:=0;at<len(args);at+=1 {
        switch args[at] {
        case "--project","--engine":
            if at+1>=len(args) {fmt.wprintln(errors,COMMAND_USAGE);return 2}
            if args[at]=="--project" {append(&roots,args[at+1])} else {engine=args[at+1]}
            at+=1
        case: append(&rest,args[at])
        }
    }
    if len(rest)<2 || rest[0]!="ui" && rest[0]!="scene" && rest[0]!="texts" {fmt.wprintln(errors,COMMAND_USAGE);return 2}
    kind:=Document_Kind.Ui if rest[0]=="ui" else Document_Kind.Scene
    verb:=rest[1]
    if rest[0]!="texts" && verb!="read" && verb!="write" && verb!="check" {
        fmt.wprintfln(errors,"mirai %s: there is no '%s'; it has read, write and check\n%s",rest[0],verb,COMMAND_USAGE)
        return 2
    }
    if len(roots)==0 {append(&roots,".")}
    root:=project_choose(roots[:],engine,rest[2] if len(rest)>2 else "")
    p:Project
    reads:=kind==.Ui && verb=="read" || rest[0]=="texts"
    if problem:=project_open(&p,root,engine,!reads);problem!="" {
        fmt.wprintfln(errors,"mirai %s %s: %s",rest[0],verb,problem)
        return 1
    }
    defer project_close(&p)
    if rest[0]=="texts" {return texts_command(&p,rest[1:],output,errors)}
    return project_run(&p,kind,verb,rest[2:],output,errors)
}

// Of several projects, the one whose assets have the asset of a file: the
// first when none has it, or named is no file.
@(private="file")
project_choose :: proc(roots:[]string,engine,named:string) -> string {
    if len(roots)==1 || !os.is_file(named) {return roots[0]}
    file:asset.Asset
    if asset.asset_load(&file,named,context.temp_allocator)!=.None {return roots[0]}
    id:=file.blob.header.id
    asset.asset_close(&file)
    for root in roots {
        p:Project
        problem:=project_open(&p,root,engine,false)
        _,has:=asset.registry_find(&p.registry,id)
        project_close(&p)
        if problem=="" && has {return root}
    }
    return roots[0]
}

// The path of the registry an asset named by a command has, the one resolver
// of read, write and check: a path of the registry, with or without assets/,
// an id or a name the registry resolves, or a file, there or not yet, under
// the assets of the project or of a plugin. An existing file outside them, or
// one the registry leaves out (a recipe), is read in memory; a write puts it
// back in that file. problem: why the name gives no asset of the kind.
@(private)
asset_named :: proc(p:^Project,named:string,kind:Document_Kind,writing:bool) -> (path,problem:string) {
    path=asset_path(named)
    if _,found:=asset.registry_find_path(&p.registry,path);found {return path,""}
    absolute,_:=strings.replace_all(project.path_absolute(named,context.temp_allocator),"\\","/",context.temp_allocator)
    if relative,under:=asset.registry_relative(&p.registry,absolute);under {
        // A file the registry leaves out, as those under .mirai, is read as one outside.
        if _,known:=asset.registry_find_path(&p.registry,relative);known || writing || !os.is_file(named) {return relative,""}
    }
    if !os.is_file(named) {return path,""}
    // A .ui is written by the id the project knows it by; a scene, as a recipe, also where it is.
    if writing && kind==.Ui {
        return "",fmt.tprintf("%s is outside the assets of the project; name the .ui by its path under assets/ (with or without assets/), by its id, or by its file under the assets folder of the project or of a plugin",named)
    }
    bytes,read:=os.read_entire_file(named,context.temp_allocator)

    if read!=nil {return "",fmt.tprintf("%s could not be read",named)}
    file:asset.Asset
    if asset.asset_take(&file,bytes,context.temp_allocator)!=.None {return "",fmt.tprintf("%s is not a Mirai asset",named)}
    id,file_kind:=file.blob.header.id,file.blob.header.kind
    asset.asset_close(&file)
    if file_kind!=(asset.KIND_UI if kind==.Ui else asset.KIND_SCENE) {return "",fmt.tprintf("%s is not a %s",named,kind_extension(kind))}
    // Written, by its file, which the registry saves to; read, in place of the asset with its id, or as one
    // more asset named by its id, which no file of the project is.
    buffer:[base.ASSET_ID_TEXT]u8
    path=strings.concatenate({base.asset_id_format(id,buffer[:]),kind_extension(kind)},context.temp_allocator)
    if record,known:=asset.registry_find(&p.registry,id);known {path=strings.clone(record.path,context.temp_allocator)}
    if writing {path=absolute}

    if asset.registry_memory_set(&p.registry,path,bytes)!=.None {return "",fmt.tprintf("%s could not be read: memory ran out",named)}
    return path,""
}

// Runs read, write or check on an open project. All but reading an interface
// need the types of its game: without them nothing is written or checked,
// and the failure says what builds them.
project_run :: proc(p:^Project,kind:Document_Kind,verb:string,args:[]string,output,errors:io.Writer) -> int {
    run:=Run{p=p,kind=kind,verb=verb,output=output,errors=errors}
    if !(kind==.Ui && verb=="read") && p.info==nil {
        what:="a scene is read and written against the components of the game, with the values they start with" if kind==.Scene else "the paths an interface binds are checked against the types of the game, and nothing checks them now"
        run_fail(&run,"",fmt.tprintf("%s; %s",what,p.untyped!=""?p.untyped:BUILD_FIX))
        return 1
    }
    code:=0
    switch verb {
    case "read":  code=command_read(&run,args)
    case "write": code=command_write(&run,args)
    case "check": code=command_check(&run,args)
    }
    if code==0 && run.failed {code=1}
    return code
}

// The document of an asset of the kind of the run, indented.
@(private="file")
document_text :: proc(run:^Run,named:string) -> (text:string,problem:string) {
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    switch run.kind {
    case .Ui:    problem=ui_read(run.p,named,&out)
    case .Scene: problem=scene_read(run.p,named,&out)
    }
    if problem!="" {return "",problem}
    return serial.json_pretty(string(serial.writer_bytes(&out)),context.temp_allocator),""
}

@(private="file")
command_read :: proc(run:^Run,args:[]string) -> int {
    named,out:string
    for at:=0;at<len(args);at+=1 {
        switch {
        case args[at]=="--out" && at+1<len(args):
            out=args[at+1]
            at+=1
        case named=="" && !strings.has_prefix(args[at],"-"): named=args[at]
        case:
            fmt.wprintln(run.errors,COMMAND_USAGE)
            return 2
        }
    }
    if named=="" {fmt.wprintln(run.errors,COMMAND_USAGE);return 2}
    path,taken:=asset_named(run.p,named,run.kind,false)
    if taken!="" {run_fail(run,named,taken);return 1}
    text,problem:=document_text(run,path)
    if problem!="" {run_fail(run,named,problem);return 1}
    if out=="" {
        fmt.wprintln(run.output,text)
        return 0
    }
    if !text_put(out,text) {run_fail(run,named,fmt.tprintf("%s could not be written",out));return 1}
    fmt.wprintfln(run.output,"%s: read to %s",named,out)
    return 0
}

@(private="file")
text_put :: proc(file,text:string) -> bool {
    forward,_:=strings.replace_all(file,"\\","/",context.temp_allocator)
    if slash:=strings.last_index_byte(forward,'/');slash>0 {os.make_directory_all(forward[:slash])}
    line:=strings.concatenate({text,"\n"},context.temp_allocator)
    return serial.file_write_atomic(forward,transmute([]u8)line)==.None
}

@(private="file")
path_of_kind :: proc(path:string,kind:Document_Kind) -> bool {
    return strings.has_suffix(path,kind_extension(kind))
}

// Whether a path of the registry is of a folder mounted beside the assets of
// the project: those of a plugin.
@(private="file")
path_mounted :: proc(r:^asset.Registry,path:string) -> bool {
    for mount in r.mounts {
        if len(path)>len(mount.prefix) && strings.has_prefix(path,mount.prefix) && path[len(mount.prefix)]=='/' {return true}
    }
    return false
}

@(private="file")
command_write :: proc(run:^Run,args:[]string) -> int {
    if len(args)!=2 {fmt.wprintln(run.errors,COMMAND_USAGE);return 2}
    text,error:=os.read_entire_file(args[1],context.temp_allocator)
    if error!=nil {run_fail(run,args[0],fmt.tprintf("%s could not be read",args[1]));return 1}
    path,problem:=asset_named(run.p,args[0],run.kind,true)
    if problem!="" {run_fail(run,args[0],problem);return 1}
    written:Written
    switch run.kind {
    case .Ui:    written,problem=ui_write(run.p,path,string(text))
    case .Scene: written,problem=scene_write(run.p,path,string(text))
    }
    if problem!="" {run_fail(run,args[0],problem);return 1}
    state:="unchanged" if written.same else "made" if written.fresh else "written"
    fmt.wprintf(run.output,"%s: %s, %d made and %d removed",written.path,state,written.made,written.removed)
    if written.followed>0 {fmt.wprintf(run.output,"; %d files that use it follow its parameters",written.followed)}
    fmt.wprintln(run.output)
    for entry in written.stored {
        text,_:=escene.stored_text(entry,written.path)
        fmt.wprintln(run.output,text)
    }
    return 0
}

@(private="file")
command_check :: proc(run:^Run,args:[]string) -> int {
    for arg in args {
        if strings.has_prefix(arg,"-") {fmt.wprintln(run.errors,COMMAND_USAGE);return 2}
    }
    count:=0
    switch run.kind {
    case .Ui:
        ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
        for arg in args {
            path,taken:=asset_named(run.p,arg,.Ui,false)
            if taken!="" {run_fail(run,arg,taken);continue}
            id,unknown:=asset.registry_resolve(&run.p.registry,asset_path(path),".ui")
            if unknown!="" {run_fail(run,arg,unknown);continue}
            append(&ids,id)
        }
        if run.failed {return 1}
        problems:=make([dynamic]Bind_Problem,context.temp_allocator)
        ui_check(run.p,ids[:],&problems)
        for &problem in problems {fmt.wprintln(run.output,bind_problem_text(run.p.assets,&problem))}
        count=len(problems)
    case .Scene:
        count=scene_check(run,args)
    }
    if count>0 {
        fmt.wprintfln(run.errors,"mirai %s check: %d problems",kind_name(run.kind),count)
        return 1
    }
    if !run.failed {fmt.wprintln(run.output,"no problems")}
    return 0
}

// Checks the scenes args name; without one, those of the project and the
// recipes of the engine and of its plugins: each reads as its document and
// that document writes it back, and what it stores otherwise than the game
// reads it is said, a problem when a save loses values or nothing reads them.
// Without names, a scene whose key did not move since the last check (in
// SCENE_KEYS_FILE) is not checked again: what that check said is said. How
// many problems.
@(private="file")
scene_check :: proc(run:^Run,args:[]string) -> (count:int) {
    // What is said of the scenes outlives the temporary memory the checks of the next ones use.
    arena:virtual.Arena
    if virtual.arena_init_growing(&arena)!=nil {run_fail(run,"","memory ran out");return}
    defer virtual.arena_destroy(&arena)
    kept:=virtual.arena_allocator(&arena)
    Named :: struct {path,shown,file:string} // file: a recipe, outside the assets
    scenes:=make([dynamic]Named,kept)
    for arg in args {
        path,taken:=asset_named(run.p,arg,.Scene,false)
        if taken!="" {run_fail(run,arg,taken);continue}
        path=strings.clone(asset_path(path),kept)
        append(&scenes,Named{path,path,""})
    }
    whole:=len(args)==0
    if whole {
        for &file in run.p.registry.files {
            if file.state==.Asset && asset.registry_listed(&file) && path_of_kind(file.path,.Scene) && !path_mounted(&run.p.registry,file.path) {
                path:=strings.clone(file.path,kept)
                append(&scenes,Named{path,path,""})
            }
        }
        for recipe in run.p.recipes {
            path,taken:=asset_named(run.p,recipe.path,.Scene,false)
            if taken!="" {run_fail(run,recipe.path,taken);continue}
            append(&scenes,Named{strings.clone(path,kept),strings.clone(recipe.path,kept),strings.clone(recipe.path,kept)})
        }
    }
    keys:=project.path(project.folder_path(run.p.root,.Generated,context.temp_allocator),"build",SCENE_KEYS_FILE,allocator=context.temp_allocator)
    types:=scene_types_key(run.p) if whole else 0
    previous:=scene_keys_read(keys,types,kept)
    checked:=make([dynamic]Scene_Checked,kept)
    closure:=make([dynamic]u32,context.temp_allocator)
    for scene in scenes {
        key:=scene_key(run.p,scene.path,scene.file,types,&closure)
        if old,kept:=previous[scene.shown];kept && old.key==key && types!=0 {
            fmt.wprint(run.output,old.text)
            append(&checked,old)
            count+=old.problems
            continue
        }
        said:=strings.builder_make(kept)
        problems:=0
        if problem:=scene_verify(run.p,scene.path);problem!="" {
            fmt.sbprintfln(&said,"%s: %s",scene.shown,problem)
            problems+=1
        }
        for entry in scene_stored(run.p,scene.path) {
            text,warning:=escene.stored_text(entry,scene.shown)
            fmt.sbprintln(&said,text)
            if warning {problems+=1}
        }
        fmt.wprint(run.output,strings.to_string(said))
        append(&checked,Scene_Checked{scene.shown,key,problems,strings.to_string(said)})
        count+=problems
    }
    if whole && types!=0 {scene_keys_write(keys,types,checked[:])}
    return
}

// Raise it when the check says something else of the same scenes and types: every key moves.
@(private="file")
SCENE_KEYS_VERSION :: 1
// In the build folder of the project: what the last check of all its scenes said of each.
SCENE_KEYS_FILE :: "scenes.keys"

@(private)
Scene_Checked :: struct {shown:string,key:u64,problems:int,text:string}

// What the check of a scene reads: the types of the game, the scene and the prefabs it places,
// by content.
@(private="file")
scene_key :: proc(p:^Project,path,file:string,types:u64,closure:^[dynamic]u32) -> u64 {
    if types==0 {return 0}
    if file!="" {
        bytes,error:=os.read_entire_file(file,context.temp_allocator)
        return base.hash_combine(types,base.hash64(bytes)) if error==nil else 0
    }
    found,listed:=asset.registry_find_path(&p.registry,path)
    if !listed {return 0}
    key:=base.hash_combine(types,found.content_hash)
    asset.registry_closure(&p.registry,found.id,closure)
    for needed in closure^ {key=base.hash_combine(key,p.registry.files[needed].content_hash)}
    return key
}

// The types of the game a scene is checked against; 0: unknown.
@(private)
scene_types_key :: proc(p:^Project) -> u64 {
    if p.info==nil || p.info.schema==nil {return 0}
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    serial.schema_write(&w,&p.info.schema.schema)
    key:=base.hash_combine(SCENE_KEYS_VERSION,base.hash64(serial.writer_bytes(&w)))
    for t in p.info.tables {key=base.hash_combine(base.hash_combine(key,base.name_hash(t.name)),base.name_hash(t.was))}
    return key|1
}

@(private)
scene_keys_read :: proc(file:string,types:u64,allocator:=context.allocator) -> map[string]Scene_Checked {
    previous:=make(map[string]Scene_Checked,allocator)
    data,error:=serial.file_read(file,allocator)
    if types==0 || error!=.None {return previous}
    r:=serial.reader_init(data)
    if serial.read_varint(&r)!=SCENE_KEYS_VERSION || serial.read_u64(&r)!=types {return previous}
    count:=serial.read_count(&r,11)
    for _ in 0..<count {
        entry:Scene_Checked
        entry.shown=serial.read_string(&r)
        entry.key=serial.read_u64(&r)
        entry.problems=int(serial.read_varint(&r))
        entry.text=serial.read_string(&r)
        if r.failed {break}
        previous[entry.shown]=entry
    }
    return previous
}

@(private)
scene_keys_write :: proc(file:string,types:u64,checked:[]Scene_Checked) {
    w:serial.Writer
    serial.writer_init(&w,allocator=context.temp_allocator)
    serial.write_varint(&w,SCENE_KEYS_VERSION)
    serial.write_u64(&w,types)
    serial.write_varint(&w,u64(len(checked)))
    for entry in checked {
        serial.write_string(&w,entry.shown)
        serial.write_u64(&w,entry.key)
        serial.write_varint(&w,u64(entry.problems))
        serial.write_string(&w,entry.text)
    }
    _=serial.file_write_atomic(file,serial.writer_bytes(&w))
}
