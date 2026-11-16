package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:editor/history"
import "mirai:project"
import "mirai:std/base"

// The files of the project a turn changes with the tools of its agent rather
// than through the API: code, shaders, the manifest. What each one held when
// the turn started is kept, and when the turn ends the ones it changed join
// its review as one transaction, so they are reverted one by one
// (ai_review_file_revert) or with the turn. The assets folder belongs to the
// API, which records what it writes, and the dot folders are not the project's.

AI_CODE_FILE_BYTES :: 1<<20 // a larger file is followed by its size and time: a turn that changes it cannot be reverted

// A file as a turn found it: the key of its content in Ai.code, or none
// when it is larger than AI_CODE_FILE_BYTES.
Ai_Code_File :: struct {
    path:string, // relative to the project
    key:string,
    size:i64,
    modified:i64,
}

// What the files of the project held when the turn started.
ai_code_begin :: proc(s:^Session,m:^Ai,task:^Ai_Task) {
    ai_code_files_free(&task.code)
    // Not nil once taken, for a project without files too.
    reserve(&task.code,64)
    ai_code_walk(s,m,s.project_root,"",&task.code,0)
}

// The files the turn changed join its review, and another turn that changed
// one of them too is named in its transcript. True when all of them could.
ai_code_end :: proc(s:^Session,m:^Ai,task:^Ai_Task) -> (kept:bool) {
    kept=true
    if task.code==nil {return}
    now:=make([dynamic]Ai_Code_File,context.temp_allocator)
    ai_code_walk(s,m,s.project_root,"",&now,0)
    set:history.Change_Set
    before:=make(map[string]^Ai_Code_File,context.temp_allocator)
    for &file in task.code {before[file.path]=&file}
    after:=make(map[string]bool,context.temp_allocator)
    for &file in now {
        after[file.path]=true
        was:=before[file.path]
        if was!=nil && was.size==file.size && was.modified==file.modified {continue}
        if !ai_code_take(m,task,&set,was,&file) {kept=false}
    }
    for &file in task.code {
        if file.path in after {continue}
        if !ai_code_take(m,task,&set,&file,nil) {kept=false}
    }
    for &file in now {delete(file.path);delete(file.key)}
    ai_code_files_free(&task.code)
    ai_code_prune(m)
    if len(set.files)==0 {
        history.change_set_free(&set)
        return
    }
    set.state=task.state_after
    review:=&task.review
    append(&review.transactions,set)
    for &file in set.files {
        if !slice.contains(review.changed_files[:],file.path) {append(&review.changed_files,strings.clone(file.path))}
        if other:=ai_code_other(m,task,file.path);other!=nil {
            ai_task_note(s,task,"%s was also changed by \"%s\": revert the later change first",file.path,base.text_get(other.title[:]))
        }
    }
    review.pending=true
    return
}

// Another turn whose review holds path: reverting one of them puts back
// what the other found only while the file holds what that one left.
ai_code_other :: proc(m:^Ai,task:^Ai_Task,path:string) -> ^Ai_Task {
    for &other in m.tasks[:m.task_count] {
        if other.id!=task.id && !other.review_finished && slice.contains(other.review.changed_files[:],path) {return &other}
    }
    return nil
}

ai_code_files_free :: proc(files:^[dynamic]Ai_Code_File) {
    for &file in files {delete(file.path);delete(file.key)}
    delete(files^)
    files^=nil
}

// Every content kept, when the editor ends.
ai_code_free :: proc(m:^Ai) {
    for &task in m.tasks[:m.task_count] {ai_code_files_free(&task.code)}
    for key,content in m.code {delete(key);delete(content)}
    delete(m.code)
    m.code=nil
}

// A file the turn changed, created or removed, as a file of the change set:
// false when what it held or holds is not known (too large, unreadable) or
// does not fit the review.
@(private="file")
ai_code_take :: proc(m:^Ai,task:^Ai_Task,set:^history.Change_Set,was,is:^Ai_Code_File) -> bool {
    file:history.Change_File
    if was!=nil {
        content,known:=m.code[was.key]
        if was.key=="" || !known {return false}
        file.before_present,file.before=true,slice.clone(content)
    }
    if is!=nil {
        if is.key=="" {
            delete(file.before)
            return false
        }
        content,known:=m.code[is.key]
        if !known {
            delete(file.before)
            return false
        }
        file.after_present,file.after=true,slice.clone(content)
    }
    review:=&task.review
    if review.bytes+len(file.before)+len(file.after)>AI_REVIEW_BYTE_CAPACITY || review.rows+1>AI_REVIEW_ROW_CAPACITY {
        delete(file.before);delete(file.after)
        return false
    }
    review.bytes+=len(file.before)+len(file.after)
    review.rows+=1
    file.path=strings.clone(was!=nil?was.path:is.path)
    append(&set.files,file)
    return true
}

// The contents no turn that runs started with and that the files no longer hold go.
@(private="file")
ai_code_prune :: proc(m:^Ai) {
    held:=make(map[string]bool,context.temp_allocator)
    for &task in m.tasks[:m.task_count] {
        for file in task.code {if file.key!="" {held[file.key]=true}}
    }
    gone:=make([dynamic]string,context.temp_allocator)
    for key in m.code {if key not_in held {append(&gone,key)}}
    for key in gone {
        stored,content:=delete_key(&m.code,key)
        delete(stored);delete(content)
    }
}

// The files under folder (relative: under the project), with what each
// holds read into Ai.code when it is not there yet.
@(private="file")
ai_code_walk :: proc(s:^Session,m:^Ai,folder,relative:string,out:^[dynamic]Ai_Code_File,depth:int) {
    if depth>16 {return}
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    names:=project.FOLDER_NAMES
    for entry in entries {
        if entry.name=="" || entry.name[0]=='.' {continue}
        path:=relative==""?entry.name:fmt.tprintf("%s/%s",relative,entry.name)
        if entry.type==.Directory {
            if depth==0 && entry.name==names[.Assets] {continue}
            ai_code_walk(s,m,entry.fullpath,path,out,depth+1)
            continue
        }
        modified:=time.time_to_unix_nano(entry.modification_time)
        file:=Ai_Code_File{path=strings.clone(path),size=entry.size,modified=modified}
        if entry.size<=AI_CODE_FILE_BYTES {
            key:=fmt.tprintf("%s|%d|%d",path,entry.size,modified)
            if key not_in m.code {
                if content,read_error:=os.read_entire_file(entry.fullpath,context.allocator);read_error==nil {m.code[strings.clone(key)]=content}
            }
            if key in m.code {file.key=strings.clone(key)}
        }
        append(out,file)
    }
}
