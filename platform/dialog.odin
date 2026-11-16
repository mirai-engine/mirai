package platform

import "base:runtime"
import "core:c"
import "core:sync"
import sdl "vendor:sdl3"

// Native dialogs for choosing a file or a folder. One at a time: dialog_show
// opens it, the answer arrives in a later frame through dialog_result.

Dialog_Kind :: enum u8 {Open_File,Save_File,Open_Folder}
// pattern: extensions separated by semicolons ("obj;gltf;glb"), or "*".
Dialog_Filter :: struct {name,pattern:string}
DIALOG_FILTER_CAPACITY :: 8
DIALOG_PATH_BYTES :: 4096
Dialog_Desc :: struct {
    kind:Dialog_Kind,
    tag:u32, // comes back in the result: what the application asked the dialog for
    filters:[]Dialog_Filter,
    location:string, // folder or file the dialog starts at
}
Dialog_State :: enum u8 {
    None,
    Accepted,
    Cancelled,
    Failed, // the system could not show the dialog, or the path does not fit in DIALOG_PATH_BYTES
}
Dialog_Result :: struct {state:Dialog_State,kind:Dialog_Kind,tag:u32,path:string}

// SDL may answer from another thread, and after the Platform is gone: the
// answer goes to a mailbox on the process heap that outlives both sides.
@(private)
Dialog_Mailbox :: struct {
    mutex:sync.Mutex,
    open,ready,failed,cancelled,abandoned:bool,
    kind:Dialog_Kind,
    tag:u32,
    path:[DIALOG_PATH_BYTES]u8,length:int,
    location:[DIALOG_PATH_BYTES]u8,
    filter_text:[1024]u8,
    filters:[DIALOG_FILTER_CAPACITY]sdl.DialogFileFilter,
}
@(private)
Dialog :: struct {
    box:^Dialog_Mailbox,
    result:Dialog_Result,
    path:[DIALOG_PATH_BYTES]u8,
}

// False while another dialog is open, or when the desc does not fit (more
// than DIALOG_FILTER_CAPACITY filters, text longer than the buffers).
// Headless there is no dialog to show: it stays open until dialog_answer.
dialog_show :: proc(p:^Platform,desc:Dialog_Desc) -> bool {
    if len(desc.filters)>DIALOG_FILTER_CAPACITY || len(desc.location)>=DIALOG_PATH_BYTES {return false}
    if p.dialog.box==nil {
        box,allocation_error:=new(Dialog_Mailbox,runtime.heap_allocator())
        if allocation_error!=nil {return false}
        p.dialog.box=box
    }
    box:=p.dialog.box
    sync.mutex_lock(&box.mutex)
    busy:=box.open
    if !busy {
        used:=0
        fits:=true
        for filter,i in desc.filters {
            if used+len(filter.name)+len(filter.pattern)+2>len(box.filter_text) {fits=false;break}
            box.filters[i].name=cstring(raw_data(box.filter_text[used:]))
            used+=copy(box.filter_text[used:],filter.name);box.filter_text[used]=0;used+=1
            box.filters[i].pattern=cstring(raw_data(box.filter_text[used:]))
            used+=copy(box.filter_text[used:],filter.pattern);box.filter_text[used]=0;used+=1
        }
        if !fits {sync.mutex_unlock(&box.mutex);return false}
        box.open=true;box.ready=false;box.failed=false;box.cancelled=false
        box.kind=desc.kind;box.tag=desc.tag
        n:=copy(box.location[:],desc.location);box.location[n]=0
    }
    sync.mutex_unlock(&box.mutex)
    if busy {return false}
    if p.headless {return true}
    location:cstring=nil
    if len(desc.location)>0 {location=cstring(raw_data(box.location[:]))}
    filters:=raw_data(box.filters[:]) if len(desc.filters)>0 else nil
    count:=c.int(len(desc.filters))
    switch desc.kind {
    case .Open_File:sdl.ShowOpenFileDialog(dialog_done,box,p.window.handle,filters,count,location,false)
    case .Save_File:sdl.ShowSaveFileDialog(dialog_done,box,p.window.handle,filters,count,location)
    case .Open_Folder:sdl.ShowOpenFolderDialog(dialog_done,box,p.window.handle,location,false)
    }
    return true
}
// A dialog is open, or its answer has not been collected by a frame yet.
dialog_pending :: proc(p:^Platform) -> bool {
    box:=p.dialog.box
    if box==nil {return false}
    sync.mutex_lock(&box.mutex);defer sync.mutex_unlock(&box.mutex)
    return box.open
}
// The answer that arrived with this frame; state is None in every other
// frame. The path is valid until the next frame begins.
dialog_result :: proc(p:^Platform) -> Dialog_Result {return p.dialog.result}

// Answers the dialog of a headless Platform as its user would: a path
// accepts, an empty path cancels, failed reports that it could not be shown.
// The answer follows the path of a native one. False when no dialog is open.
dialog_answer :: proc(p:^Platform,path:string,failed:=false) -> bool {
    if !p.headless || !dialog_pending(p) || len(path)>=DIALOG_PATH_BYTES {return false}
    text:[DIALOG_PATH_BYTES]u8
    copy(text[:],path)
    list:=[2]cstring{cstring(raw_data(text[:])) if len(path)>0 else nil,nil}
    dialog_done(p.dialog.box,raw_data(list[:]) if !failed else nil,0)
    return true
}

@(private)
dialog_done :: proc "c" (userdata:rawptr,filelist:[^]cstring,filter:c.int) {
    box:=cast(^Dialog_Mailbox)userdata
    sync.mutex_lock(&box.mutex)
    if box.abandoned {
        sync.mutex_unlock(&box.mutex)
        context=runtime.default_context()
        free(box,runtime.heap_allocator())
        return
    }
    box.length=0
    box.failed=filelist==nil
    box.cancelled=filelist!=nil && filelist[0]==nil
    if filelist!=nil && filelist[0]!=nil {
        path:=string(filelist[0])
        if len(path)<=len(box.path) {box.length=copy(box.path[:],path)} else {box.failed=true}
    }
    box.ready=true
    sync.mutex_unlock(&box.mutex)
}

// The callback may already have run inside the event pump, or be running on
// another thread: the mailbox is only read here, under its lock.
@(private)
dialog_collect :: proc(p:^Platform) {
    d:=&p.dialog
    d.result={}
    box:=d.box
    if box==nil {return}
    sync.mutex_lock(&box.mutex)
    if box.ready {
        d.result.kind=box.kind;d.result.tag=box.tag
        d.result.state=.Failed if box.failed else .Cancelled if box.cancelled else .Accepted
        n:=copy(d.path[:],box.path[:box.length])
        d.result.path=string(d.path[:n])
        box.ready=false;box.open=false
    }
    sync.mutex_unlock(&box.mutex)
}

// A dialog still open when the Platform is destroyed keeps its mailbox, and
// frees it when the user finally answers.
@(private)
dialog_abandon :: proc(p:^Platform) {
    box:=p.dialog.box
    if box==nil {return}
    p.dialog.box=nil
    sync.mutex_lock(&box.mutex)
    waiting:=box.open && !box.ready && !p.headless
    if waiting {box.abandoned=true}
    sync.mutex_unlock(&box.mutex)
    if !waiting {free(box,runtime.heap_allocator())}
}
