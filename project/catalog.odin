package project

import "core:os"
import "core:slice"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// The catalog of plugins: a repository with a file for each plugin others
// made, CATALOG_PLUGINS/<name>.json, with the commit someone reviewed. A
// plugin is added to it with a pull request that touches only its own file,
// so two of them never conflict; cook/install keeps a checkout of it on the
// machine and installs the plugins it lists at that commit. Beside the file,
// <name>.png is the icon the editor shows the plugin with before it is
// installed.

CATALOG_URL :: "https://github.com/mirai-engine/mirai-plugins.git"
CATALOG_PLUGINS :: "plugins"
MAX_CATALOG :: 256

// What the file of a plugin says; its name is the name of the file.
Catalog_File :: struct {
    description:[256]u8 `mirai:"text"`,
    url:Url `mirai:"text"`,
    commit:Commit `mirai:"text"`, // the one reviewed: what an install from the catalog checks out
}

Catalog_Entry :: struct {
    name:Name,
    using file:Catalog_File,
}

Catalog :: struct {
    plugins:[MAX_CATALOG]Catalog_Entry, // sorted by name
}

// The file of the plugin name.
catalog_entry_parse :: proc(name,text:string,entry:^Catalog_Entry) -> Error {
    entry^={}
    if !name_valid(name) {return error_about(.Name_Invalid,name)}
    base.text_set(entry.name[:],name)
    if error:=value_parse(text,&entry.file,Catalog_File);error.code!=.None {
        base.text_set(error.subject[:],name)
        return error
    }
    if base.text_len(entry.url[:])==0 || !commit_valid(base.text_get(entry.commit[:])) {return error_about(.Source_Invalid,name)}
    return {}
}

catalog_icon :: proc(folder,name:string,allocator:=context.allocator) -> string {
    return path(folder,CATALOG_PLUGINS,strings.concatenate({name,".png"},context.temp_allocator),allocator=allocator)
}

catalog_entry_text :: proc(entry:^Catalog_Entry,allocator:=context.allocator) -> string {return value_text(&entry.file,Catalog_File,allocator)}

// Reads the catalog in the checkout folder: the .json files of its
// CATALOG_PLUGINS. Not_Found: there is no checkout; without the folder of
// the plugins there are none yet.
catalog_read :: proc(folder:string,c:^Catalog) -> Error {
    c^={}
    if !os.is_dir(folder) {return {code=.Not_Found}}
    plugins:=path(folder,CATALOG_PLUGINS,allocator=context.temp_allocator)
    if !os.is_dir(plugins) {return {}}
    entries,read_error:=os.read_all_directory_by_path(plugins,context.temp_allocator)
    if read_error!=nil {return {code=.Read_Failed}}
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    count:=0
    for entry in entries {
        if entry.type!=.Regular || !strings.has_suffix(entry.name,".json") {continue}
        name:=strings.trim_suffix(entry.name,".json")
        if count==MAX_CATALOG {return error_about(.Read_Failed,name)}
        data,file_error:=serial.file_read(path(plugins,entry.name,allocator=context.temp_allocator),context.temp_allocator)
        if file_error!=.None {return error_about(.Read_Failed,name)}
        if error:=catalog_entry_parse(name,string(data),&c.plugins[count]);error.code!=.None {return error}
        count+=1
    }
    return {}
}

catalog_count :: proc(c:^Catalog) -> int {
    for &entry,i in c.plugins {
        if base.text_len(entry.name[:])==0 {return i}
    }
    return len(c.plugins)
}

catalog_find :: proc(c:^Catalog,name:string) -> ^Catalog_Entry {
    for &entry in c.plugins[:catalog_count(c)] {
        if base.text_get(entry.name[:])==name {return &entry}
    }
    return nil
}
