package author

import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The commands mirai ui and mirai scene, which the author program of the
// engine runs: a project reads, checks and writes the documents of its
// interfaces, scenes and prefabs with no editor.
//
//   read <asset> [--out <file>]   the document of the asset, as ui.inspect or
//                                 scene.inspect with root give it
//   read --sources                the document of every asset of the project,
//                                 each to its file under source/
//   write <asset> <document>      makes the asset say what the file declares,
//                                 as ui.write does; an asset that does not
//                                 exist yet is made
//   write <file|folder>...        the same for each document under source/:
//                                 source/<path>.ui.json is assets/<path>.ui,
//                                 and so for .scene.json and .prefab.json
//   check [<asset>...]            what the assets, all without one, would fail
//                                 with in the game
//
// The types of the game, which the paths an interface binds and the
// components of a scene are read against, are those of the library of the
// editor of the project as it was built last, which also has the cards its
// plugins add to the presets. Without it only an interface is read: nothing
// is written or checked that the game could not be asked about, and the
// command says what builds the library.
// Results go to output and failures to errors as "mirai ui write: <asset>:
// <reason>". Exit codes: 0 done, 1 failed, 2 misuse.

COMMAND_USAGE :: `Usage: mirai ui|scene read <asset> [--out <file>] | read --sources
       mirai ui|scene write <asset> <document file> | write <file or folder under source/>...
       mirai ui|scene check [<asset>...]`

// The folder of a project its documents are kept in as text.
SOURCE_FOLDER :: "source"

// What a command reads and writes: the interfaces, or the scenes and prefabs.
Document_Kind :: enum u8 {Ui,Scene}

// The extensions of the assets of each kind.
KIND_EXTENSIONS :: [Document_Kind][2]string{.Ui={".ui",""},.Scene={".scene",".prefab"}}

@(private="file")
kind_extensions :: proc(kind:Document_Kind) -> []string {
    extensions:=KIND_EXTENSIONS
    list:=make([dynamic]string,context.temp_allocator)
    for extension in extensions[kind] {
        if extension!="" {append(&list,extension)}
    }
    return list[:]
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
    untyped:string,        // why it has none, with what gives them
    plugins:Plugin_Recipes, // the cards of its plugins, when whoever runs the command reads them
    scratch:Scratch_World,  // where a recipe is run; made the first time
}

// What builds the library the types of a game come from.
BUILD_FIX :: "mirai build editor <project> --dev builds it"


// Opens the project at root with the assets of its plugins. library false
// leaves the types of its game out. problem: why it does not open.
project_open :: proc(p:^Project,root,engine:string,library:=true,recipes:Plugin_Recipes_Proc=nil) -> (problem:string) {
    opened,error:=project.open(root,engine,context.temp_allocator)
    if error.code!=.None {return project.error_text(root,error,context.temp_allocator)}
    p.root=strings.clone(opened.root)
    p.name=strings.clone(base.text_get(opened.manifest.name[:]))
    p.assets_root=project.folder_path(p.root,.Assets)
    asset.registry_init(&p.registry,p.assets_root)
    for mount in host.project_asset_mounts(&opened,context.temp_allocator) {asset.registry_mount(&p.registry,mount.folder,mount.prefix)}
    asset.types_init(&p.types)
    p.assets={&p.registry,&p.types}
    if os.is_dir(p.assets_root) && asset.registry_scan(&p.registry)!=.None {return fmt.tprintf("the assets of %s could not be read",p.assets_root)}
    if library {project_library_open(p)}
    if p.info!=nil && recipes!=nil {p.plugins=recipes(p.info,context.allocator)}
    return ""
}

project_close :: proc(p:^Project) {
    scratch_world_free(&p.scratch)
    if p.library.handle!=nil {host.project_library_unload(&p.library)}
    asset.registry_destroy(&p.registry)
    asset.types_destroy(&p.types)
    delete(p.root)
    delete(p.name)
    delete(p.assets_root)
    p^={}
}

// The types of the game of the project: those of the library of its editor,
// which its plugins give their cards in.
@(private="file")
project_library_open :: proc(p:^Project) {
    path:=project.project_library(p.root,"editor",context.temp_allocator)
    if !os.is_file(path) {
        p.untyped="the project has no built library, where the types of its game are: "+BUILD_FIX
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

// The asset a document kept under source/ is: source/<path>.ui.json is
// <path>.ui of the assets. ok false for a file elsewhere or of another name.
source_asset :: proc(p:^Project,file:string,kind:Document_Kind) -> (path:string,ok:bool) {
    absolute:=project.path_absolute(file,context.temp_allocator)
    folder:=strings.concatenate({project.path(p.root,SOURCE_FOLDER,allocator=context.temp_allocator),"/"},context.temp_allocator)
    if len(absolute)<=len(folder) || !strings.equal_fold(absolute[:len(folder)],folder) || !strings.has_suffix(absolute,".json") {return}
    path=absolute[len(folder):len(absolute)-len(".json")]
    for extension in kind_extensions(kind) {
        if strings.has_suffix(path,extension) {return path,true}
    }
    return "",false
}

// The file under source/ the document of an asset is kept in.
source_file :: proc(p:^Project,path:string) -> string {
    return project.path(p.root,SOURCE_FOLDER,strings.concatenate({path,".json"},context.temp_allocator),allocator=context.temp_allocator)
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
    document_write(out,&p.types,&r,-1,libs[:],p.assets)
    return ""
}

// What a write did.
Written :: struct {
    path:string, // of the asset, in the temporary allocator
    fresh:bool,  // the file did not exist
    same:bool,   // the file already said it: nothing was written
    changed:bool, // a scene: something of an entity it kept is another
    followed:int, // an interface: the files that use it as a widget and were written to follow its parameters
    made,removed:int,
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
    reading:=Reading{allocator=context.temp_allocator,raw=text,assets=registry_assets(&p.registry)}
    args:=Tree_Args{reading=&reading,types=&p.types,registry=&p.registry,assets=p.assets,info=p.info,asset=id}
    applied:bool
    if written.made,written.removed,applied=document_apply(&args,&r,-1,text);!applied {return {},reading.problem}
    params:=widget_params(p.assets,id)
    bytes,imports,loads:=document_bytes(&args,id,&r)
    if !loads {return {},reading.problem}
    written.path,written.fresh=path,fresh
    file:=project.path(p.assets_root,path,allocator=context.temp_allocator) if fresh else asset.registry_file_path(&p.registry,path,context.temp_allocator)
    if problem=file_put(p,file,path,bytes,&written);problem!="" {return}
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

// Checks the .ui of the project, or those of ids, against the types of the
// game: what does not load, the names that resolve to nothing and the paths
// they bind that it lacks.
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

// recipes reads the cards of the plugins of the library of the project
// (editor.plugin_recipes, in the program of the engine); without it a
// document names the presets alone.
command :: proc(args:[]string,output,errors:io.Writer,recipes:Plugin_Recipes_Proc=nil) -> int {
    root,engine:string
    rest:=make([dynamic]string,context.temp_allocator)
    for at:=0;at<len(args);at+=1 {
        switch args[at] {
        case "--project","--engine":
            if at+1>=len(args) {fmt.wprintln(errors,COMMAND_USAGE);return 2}
            if args[at]=="--project" {root=args[at+1]} else {engine=args[at+1]}
            at+=1
        case: append(&rest,args[at])
        }
    }
    if len(rest)<2 || rest[0]!="ui" && rest[0]!="scene" {fmt.wprintln(errors,COMMAND_USAGE);return 2}
    kind:=Document_Kind.Ui if rest[0]=="ui" else Document_Kind.Scene
    verb:=rest[1]
    if verb!="read" && verb!="write" && verb!="check" {
        fmt.wprintfln(errors,"mirai %s: there is no '%s'; it has read, write and check\n%s",rest[0],verb,COMMAND_USAGE)
        return 2
    }
    if root=="" {root="."}
    p:Project
    reads:=kind==.Ui && verb=="read"
    if problem:=project_open(&p,root,engine,!reads,recipes);problem!="" {
        fmt.wprintfln(errors,"mirai %s %s: %s",rest[0],verb,problem)
        return 1
    }
    defer project_close(&p)
    return project_run(&p,kind,verb,rest[2:],output,errors)
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
    sources:=false
    for at:=0;at<len(args);at+=1 {
        switch {
        case args[at]=="--sources": sources=true
        case args[at]=="--out":
            if at+1>=len(args) {fmt.wprintln(run.errors,COMMAND_USAGE);return 2}
            out=args[at+1]
            at+=1
        case named=="" && !strings.has_prefix(args[at],"-"): named=args[at]
        case:
            fmt.wprintln(run.errors,COMMAND_USAGE)
            return 2
        }
    }
    if sources==(named!="") || sources && out!="" {fmt.wprintln(run.errors,COMMAND_USAGE);return 2}
    if !sources {
        text,problem:=document_text(run,named)
        if problem!="" {run_fail(run,named,problem);return 1}
        if out=="" {
            fmt.wprintln(run.output,text)
            return 0
        }
        if !text_put(out,text) {run_fail(run,named,fmt.tprintf("%s could not be written",out));return 1}
        fmt.wprintfln(run.output,"%s: read to %s",named,out)
        return 0
    }
    // Every asset of the project itself: those of its plugins are theirs.
    count:=0
    for &file in run.p.registry.files {
        if file.state!=.Asset || !asset.registry_listed(&file) || !path_of_kind(file.path,run.kind) || path_mounted(&run.p.registry,file.path) {continue}
        path:=strings.clone(file.path,context.temp_allocator)
        text,problem:=document_text(run,path)
        if problem!="" {run_fail(run,path,problem);continue}
        to:=source_file(run.p,path)
        if !text_put(to,text) {run_fail(run,path,fmt.tprintf("%s could not be written",to));continue}
        fmt.wprintfln(run.output,"%s: read to %s",path,to)
        count+=1
    }
    if count==0 && !run.failed {fmt.wprintfln(run.output,"the project has no %s",strings.join(kind_extensions(run.kind)," or ",context.temp_allocator))}
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
    for extension in kind_extensions(kind) {
        if strings.has_suffix(path,extension) {return true}
    }
    return false
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

// A document to write and the asset it is.
@(private="file")
Target :: struct {asset,file:string}

// The documents under a folder, each with its asset.
@(private="file")
targets_under :: proc(run:^Run,folder:string,targets:^[dynamic]Target) {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    for entry in entries {
        full,_:=strings.replace_all(entry.fullpath,"\\","/",context.temp_allocator)
        if entry.type==.Directory {targets_under(run,full,targets);continue}
        if path,ok:=source_asset(run.p,full,run.kind);ok {append(targets,Target{path,full})}
    }
}

@(private="file")
command_write :: proc(run:^Run,args:[]string) -> int {
    targets:=make([dynamic]Target,context.temp_allocator)
    if len(args)==0 {fmt.wprintln(run.errors,COMMAND_USAGE);return 2}
    // An asset and its document: the first is no document nor a folder of them.
    if len(args)==2 && !strings.has_suffix(args[0],".json") && !os.is_dir(args[0]) && os.is_file(args[1]) {
        append(&targets,Target{args[0],args[1]})
    } else {
        for arg in args {
            switch {
            case os.is_dir(arg):
                before:=len(targets)
                targets_under(run,arg,&targets)
                if len(targets)==before {
                    run_fail(run,arg,fmt.tprintf("the folder has no document of this kind under %s/ of the project: %s/<path>%s.json is the asset <path>%s",SOURCE_FOLDER,SOURCE_FOLDER,kind_extensions(run.kind)[0],kind_extensions(run.kind)[0]))
                }
            case os.is_file(arg):
                path,ok:=source_asset(run.p,arg,run.kind)
                if !ok {
                    run_fail(run,arg,fmt.tprintf("the file does not say which asset it is: %s/<path>%s.json of the project is the asset <path>%s; for a file elsewhere name the asset first, mirai %s write <asset> <file>",SOURCE_FOLDER,kind_extensions(run.kind)[0],kind_extensions(run.kind)[0],kind_name(run.kind)))
                    continue
                }
                append(&targets,Target{path,arg})
            case:
                run_fail(run,arg,"there is no such file or folder")
            }
        }
    }
    if run.failed {return 1}
    // A document may use a file another one of the same run makes: what
    // fails is tried again while a round writes something.
    pending:=targets[:]
    problems:=make([]string,len(targets),context.temp_allocator)
    for len(pending)>0 {
        left:=make([dynamic]Target,context.temp_allocator)
        for target in pending {
            text,error:=os.read_entire_file(target.file,context.temp_allocator)
            if error!=nil {
                problems[len(left)]=fmt.tprintf("%s could not be read",target.file)
                append(&left,target)
                continue
            }
            written:Written
            problem:string
            switch run.kind {
            case .Ui:    written,problem=ui_write(run.p,target.asset,string(text))
            case .Scene: written,problem=scene_write(run.p,target.asset,string(text))
            }
            if problem!="" {
                problems[len(left)]=problem
                append(&left,target)
                continue
            }
            state:="unchanged" if written.same else "made" if written.fresh else "written"
            fmt.wprintf(run.output,"%s: %s, %d made and %d removed",written.path,state,written.made,written.removed)
            if written.followed>0 {fmt.wprintf(run.output,"; %d files that use it follow its parameters",written.followed)}
            fmt.wprintln(run.output)
        }
        if len(left)==len(pending) {
            for target,i in left {run_fail(run,target.asset,problems[i])}
            return 1
        }
        pending=left[:]
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
            id,unknown:=asset.registry_resolve(&run.p.registry,asset_path(arg),".ui")
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

// Checks the scenes and prefabs args name, all without one: each reads as its
// document and that document writes it back. How many do not.
@(private="file")
scene_check :: proc(run:^Run,args:[]string) -> (count:int) {
    paths:=make([dynamic]string,context.temp_allocator)
    for arg in args {append(&paths,asset_path(arg))}
    if len(args)==0 {
        for &file in run.p.registry.files {
            if file.state==.Asset && asset.registry_listed(&file) && path_of_kind(file.path,.Scene) && !path_mounted(&run.p.registry,file.path) {append(&paths,strings.clone(file.path,context.temp_allocator))}
        }
    }
    for path in paths {
        if problem:=scene_verify(run.p,path);problem!="" {
            fmt.wprintfln(run.output,"%s: %s",path,problem)
            count+=1
        }
    }
    return
}
