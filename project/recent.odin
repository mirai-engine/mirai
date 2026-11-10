package project

import "core:strings"
import "mirai:std/base"

// The projects an editor of this machine opened, for the launcher of the
// editor and for `mirai edit` without a project: RECENT_FILE in the
// machine_folder of the engine, never versioned, written like the settings.

RECENT_FILE :: "projects.mirai"
RECENT_CAPACITY :: 16
RECENT_PATH :: 512

Recent_Project :: struct {
    path:[RECENT_PATH]u8 `mirai:"text"`, // absolute, with forward slashes
    opened:i64,                          // nanoseconds since 1970 of the last time an editor opened it
}

Recent_Projects :: struct {
    open_last:bool, // mirai edit without a project opens the last one, not the launcher
    projects:[RECENT_CAPACITY]Recent_Project, // the last opened first; an empty path ends them
}

@(private="file")
recent_setting :: proc(recent:^Recent_Projects) -> [1]Setting {
    return {{name="Recent_Projects",info=type_info_of(Recent_Projects),value=recent}}
}

recent_file :: proc(engine_root:string,allocator:=context.allocator) -> string {
    folder:=machine_folder(engine_root,context.temp_allocator)
    if folder=="" {return ""}
    return path(folder,RECENT_FILE,allocator=allocator)
}

// What the file of the engine has; a missing file is an empty list.
recent_read :: proc(engine_root:string,recent:^Recent_Projects) -> Error {
    recent^={}
    file:=recent_file(engine_root,context.temp_allocator)
    if file=="" {return {}}
    settings:=recent_setting(recent)
    return settings_read(file,settings[:])
}

recent_write :: proc(engine_root:string,recent:^Recent_Projects) -> Error {
    file:=recent_file(engine_root,context.temp_allocator)
    if file=="" {return {code=.Write_Failed}}
    settings:=recent_setting(recent)
    below:=Recent_Projects{}
    under:=recent_setting(&below)
    return settings_write(file,settings[:],under[:])
}

recent_count :: proc(recent:^Recent_Projects) -> int {
    for &entry,i in recent.projects {
        if entry.path[0]==0 {return i}
    }
    return RECENT_CAPACITY
}

// Puts a project first, opened at now; the oldest leaves a full list.
recent_add :: proc(recent:^Recent_Projects,folder:string,now:i64) {
    absolute:=path_absolute(folder,context.temp_allocator)
    if absolute=="" || len(absolute)>=RECENT_PATH {return}
    count:=recent_count(recent)
    at:=count
    for &entry,i in recent.projects[:count] {
        if path_same(base.text_get(entry.path[:]),absolute) {at=i;break}
    }
    if at==count && count==RECENT_CAPACITY {at=count-1}
    copy(recent.projects[1:at+1],recent.projects[:at])
    recent.projects[0]={opened=now}
    base.text_set(recent.projects[0].path[:],absolute)
}

recent_remove :: proc(recent:^Recent_Projects,index:int) {
    count:=recent_count(recent)
    if index<0 || index>=count {return}
    copy(recent.projects[index:count-1],recent.projects[index+1:count])
    recent.projects[count-1]={}
}
