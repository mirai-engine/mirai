package editor

import "mirai:core"
import "mirai:editor/history"
import "mirai:project"

// Puts the scene where change sets say: back to before them (forward false),
// newest first, or again to what they left (forward true), oldest first,
// inside the open gesture. label names the steps of the files it writes
// without one. How many fields, components, entities and files stayed as
// someone else left them.
@(private)
change_sets_apply :: proc(s:^Session,sets:[]history.Change_Set,forward:bool,label:string) -> (kept:int) {
    w:=edited_world(s)
    transforms:core.Seen
    if locals:=core.world_table_of(w,core.Transform);locals!=nil {_=core.changes(locals,&transforms)}
    count:=len(sets)
    for step in 0..<count {
        set:=&sets[forward?step:count-1-step]
        kept+=history.change_set_rows_apply(w,set,forward)
        for &file in set.files {
            if !change_file_put(s,&file,forward,label) {kept+=1}
        }
        core.world_settle(w)
    }
    history.world_turned_prune(w,nil,0,transforms)
    return
}

// Puts a file where one side left it while it holds the other. False when
// someone else changed it since: it keeps what it has.
@(private)
change_file_side :: proc(s:^Session,path:string,from_present:bool,from:[]u8,to_present:bool,to:[]u8,label:string) -> bool {
    full:=project.path(s.project_root,path,allocator=context.temp_allocator)
    r:=files_registry(s)
    if !history.file_holds(r,full,from_present,from) {return history.file_holds(r,full,to_present,to)}
    return file_write(s,full,to,label,remove=!to_present)
}

// Puts a file of a change set where it was before (forward false) or after it (forward true).
@(private)
change_file_put :: proc(s:^Session,file:^history.Change_File,forward:bool,label:string) -> bool {
    if forward {return change_file_side(s,file.path,file.before_present,file.before,file.after_present,file.after,label)}
    return change_file_side(s,file.path,file.after_present,file.after,file.before_present,file.before,label)
}
