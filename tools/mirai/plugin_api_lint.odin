package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:project"

// What lies below the API of a plugin: its runtime and editor parts reach the
// renderer through engine/render and the editor, and only their tests import these.
PLUGIN_API_BELOW :: [?]string{"mirai:render","mirai:rhi"}

Plugin_Import :: struct {line:int,path:string}

// Whether mirai check runs the lint on folder: a package of the runtime or
// editor part of a plugin, of the engine or of a project.
plugin_api_lint_applies :: proc(folder:string) -> bool {
    parts:=project.PART_NAMES
    at:=strings.trim_right(project.path_absolute(folder,context.temp_allocator),"/")
    for {
        parent:=os.dir(at)
        if parent==at || parent=="" {return false}
        if os.is_file(project.path(parent,project.PLUGIN_FILE,allocator=context.temp_allocator)) {
            name:=at[strings.last_index_any(at,"/\\")+1:]
            return name==parts[.Runtime] || name==parts[.Editor]
        }
        at=parent
    }
}

// The imports of a source that reach below the API of a plugin.
plugin_api_lint_source :: proc(text:string,findings:^[dynamic]Plugin_Import) {
    rest:=text
    number:=0
    for line in strings.split_lines_iterator(&rest) {
        number+=1
        trimmed:=strings.trim_space(line)
        if !strings.has_prefix(trimmed,"import ") {continue}
        open:=strings.index_byte(trimmed,'"')
        if open<0 {continue}
        length:=strings.index_byte(trimmed[open+1:],'"')
        if length<0 {continue}
        imported:=trimmed[open+1:][:length]
        for below in PLUGIN_API_BELOW {
            if imported==below || strings.has_prefix(imported,below) && imported[len(below)]=='/' {append(findings,Plugin_Import{number,imported})}
        }
    }
}

// Prints those imports of the sources of a folder and of the packages under
// it, tests aside, with what to import instead. False when there is one.
plugin_api_lint_folder :: proc(folder:string) -> bool {
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    clean:=true
    for entry in entries {
        if entry.type==.Directory {
            if !plugin_api_lint_folder(entry.fullpath) {clean=false}
            continue
        }
        if entry.type!=.Regular || !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
        data,error:=os.read_entire_file(entry.fullpath,context.temp_allocator)
        if error!=nil {fmt.eprintfln("mirai check: could not read %s",entry.fullpath);clean=false;continue}
        findings:=make([dynamic]Plugin_Import,context.temp_allocator)
        plugin_api_lint_source(string(data),&findings)
        for f in findings {
            clean=false
            fmt.eprintfln("%s(%d:1) Error: a plugin imports %q only from its tests. Import \"mirai:engine/render\" instead, which offers what a plugin draws and reads through the renderer (stages and passes, programs, textures, debug lines); its editor part also has \"mirai:editor\" (gizmos, thumbnails) and \"mirai:engine/gui\" (images of the UI). What they lack is added to them, not reached around.",entry.fullpath,f.line,f.path)
        }
    }
    return clean
}

// The lint over the runtime and editor parts of the plugins a project brings.
plugin_api_lint_project :: proc(p:^project.Project) -> bool {
    parts:=project.PART_NAMES
    clean:=true
    for plugin in p.plugins {
        if plugin.origin!=.Project {continue}
        for part in ([2]project.Plugin_Part{.Runtime,.Editor}) {
            if part in plugin.manifest.parts && !plugin_api_lint_folder(project.path(plugin.folder,parts[part],allocator=context.temp_allocator)) {clean=false}
        }
    }
    return clean
}
