package build

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"

// The packages of a project as its libraries compile them: a copy of the Odin
// sources of its game, editor and plugins without their _test.odin files. The
// compiler reads every .odin of a folder, tests included; the stages of the
// engine and of the plugin libraries leave them out the same way, and only a
// test build reads the tests of a project (tests.odin). What the compiler says
// of the copy, and what it read of it, is said of the project.

// <project>/.mirai/build/stage, the collection project of its libraries.
project_stage :: proc(root:string,allocator:=context.allocator) -> string {
    return project.path(project.folder_path(root,.Generated,context.temp_allocator),"build","stage",allocator=allocator)
}

// Writes the stage of a project: what did not change keeps its date, and what
// the project no longer has leaves. False when a file could not be read or written.
@(private)
project_stage_write :: proc(root:string) -> bool {
    stage:=project_stage(root,context.temp_allocator)
    kept:=make(map[string]bool,context.temp_allocator)
    names:=project.FOLDER_NAMES
    for folder in ([3]project.Folder{.Game,.Editor,.Plugins}) {
        if !os.is_dir(project.path(root,names[folder],allocator=context.temp_allocator)) {continue}
        stage_copy(root,stage,names[folder],&kept) or_return
    }
    stage_prune(stage,"",kept)
    return true
}

@(private="file")
stage_copy :: proc(root,stage,relative:string,kept:^map[string]bool) -> bool {
    entries,error:=os.read_all_directory_by_path(project.path(root,relative,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        path:=fmt.tprintf("%s/%s",relative,entry.name)
        if entry.type==.Directory {
            if strings.has_prefix(entry.name,".") || entry.name=="testdata" {continue}
            stage_copy(root,stage,path,kept) or_return
            continue
        }
        if !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
        data,read_error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if read_error!=nil {return false}
        target:=project.path(stage,path,allocator=context.temp_allocator)
        folder:=target[:strings.last_index_byte(target,'/')]
        if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return false}
        if _,write_error:=write_changed(target,string(data));write_error!=nil {return false}
        kept[path]=true
    }
    return true
}

// Removes from the stage the sources the project no longer has.
@(private="file")
stage_prune :: proc(stage,relative:string,kept:map[string]bool) {
    entries,error:=os.read_all_directory_by_path(relative==""?stage:project.path(stage,relative,allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        path:=relative==""?entry.name:fmt.tprintf("%s/%s",relative,entry.name)
        if entry.type==.Directory {
            stage_prune(stage,path,kept)
        } else if path not_in kept {
            _=os.remove(entry.fullpath)
        }
    }
}

// The path of the project a path of its stage stands for; others as they are.
@(private)
stage_path_restore :: proc(root,path:string,allocator:runtime.Allocator) -> string {
    stage:=project_stage(root,context.temp_allocator)
    if len(path)<=len(stage) || path[len(stage)]!='/' || !project.path_same(path[:len(stage)],stage) {return path}
    return project.path(root,path[len(stage)+1:],allocator=allocator)
}

// Diagnostics of the stage point at the sources of the project.
@(private)
stage_paths_restore :: proc(root:string,diagnostics:[]Diagnostic,allocator:runtime.Allocator) {
    for &d in diagnostics {d.file=stage_path_restore(root,d.file,allocator)}
}

// Rewrites what the compiler exported that it read with the paths of the
// project in place of those of the stage, which hold the same text but the
// tests: a fingerprint of it reads the project, which a job may not have
// copied yet.
@(private)
stage_sources_restore :: proc(root,file:string) {
    Export :: struct {source_files,load_files:[]string}
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if error!=nil {return}
    export:Export
    if json.unmarshal(data,&export,allocator=context.temp_allocator)!=nil {return}
    for group in ([2][]string{export.source_files,export.load_files}) {
        for &path in group {path=stage_path_restore(root,path,context.temp_allocator)}
    }
    written,marshal_error:=json.marshal(export,allocator=context.temp_allocator)
    if marshal_error!=nil || os.write_entire_file(file,written)!=nil {_=os.remove(file)}
}
