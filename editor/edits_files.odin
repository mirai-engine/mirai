package editor

import "core:os"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// Files of the project in the history. A file an edit writes or removes (a
// .mat, the .slang of a program, an animation asset) is part of the step of
// its gesture: what it held before the first write of the gesture and what
// the last one left. Undo and redo put one side back while the file still
// holds the other; a file that changed outside the editor since keeps what it
// has, and the swap counts it as kept. Assets and programs are loaded again
// after every change (files_settle). An editor that keeps the undo of a file
// itself (the revisions of a terrain) writes it outside the history with
// file_set; a step that holds such a file puts its side whatever it holds.
// With an asset document in front and no gesture of the scene open (the API,
// a tool), the step is one of the history of that document instead
// (asset_documents.odin).
//
// An asset file of the folder is not written: its content stays in the
// memory of the registry of the assets, unsaved, until it is saved
// (assets_unsaved.odin), and what it holds is what the registry holds. The
// Slang source of a program stays there too, by its absolute path, and the
// generation of the shaders reads it from there (programs_overlay). A content
// equal to the disk is no change. Other files are written at once.

EDITS_FILE_BYTES :: 64<<20 // a file larger than this is written without its history

// What a file was on the two sides of a step: held is what the step left in
// the file, other what a swap puts back. A side without the file is absent.
Edit_File :: struct {
    path:string, // absolute, with forward slashes
    held_present,other_present:bool,
    held,other:[]u8,
    revised:bool, // an editor also writes it outside the history (file_set): undo and redo put a side whatever it holds
}

@(private)
edit_file_free :: proc(file:^Edit_File) {
    delete(file.path);delete(file.held);delete(file.other)
    file^={}
}

@(private)
edit_file_bytes :: proc(file:^Edit_File) -> int {return len(file.path)+len(file.held)+len(file.other)}

// The registry whose memory keeps the asset files the edits of a session
// change; nil without assets, or with a folder that is a packed index.
@(private)
files_registry :: proc(s:^Session) -> ^asset.Registry {
    if s.app==nil || s.app.assets==nil || s.app.assets.indexed {return nil}
    return &s.app.assets.registry
}

// The registry looks again at files the editor wrote, by their absolute
// paths, instead of walking the folder. A file outside the assets is none of
// its business.
@(private)
assets_wrote :: proc(s:^Session,files:..string) {
    a:=s.app.assets
    if a==nil || a.indexed {return}
    paths:=make([dynamic]string,0,len(files),context.temp_allocator)
    for file in files {
        if path,inside:=asset.registry_relative(&a.registry,file);inside {append(&paths,path)}
    }
    if len(paths)>0 {host.assets_refresh(a,paths[:])}
}

// The path in the registry of a file whose changes stay in its memory: a file
// of the assets, or the source of a program by its absolute path.
@(private)
file_unsaved :: proc(r:^asset.Registry,path:string) -> (relative:string,ok:bool) {
    if r!=nil && strings.has_suffix(path,".slang") && asset.registry_outside(path) {return path,true}
    return asset.registry_relative(r,path)
}

// What a file holds now, or not present: what the registry keeps of it in
// memory, else the disk. ok false when it exists but cannot be read.
@(private)
file_contents :: proc(r:^asset.Registry,path:string,allocator:=context.allocator) -> (data:[]u8,present,ok:bool) {
    if relative,unsaved:=file_unsaved(r,path);unsaved {
        if held,found:=asset.registry_memory_find(r,relative);found {
            if held.removed {return nil,false,true}
            bytes,error:=make([]u8,len(held.data),allocator)
            if error!=nil {return nil,false,false}
            copy(bytes,held.data)
            return bytes,true,true
        }
    }
    return file_disk(path,allocator)
}

// What the disk holds of a file, or not present.
@(private)
file_disk :: proc(path:string,allocator:=context.allocator) -> (data:[]u8,present,ok:bool) {
    bytes,error:=serial.file_read(path,allocator,limit=EDITS_FILE_BYTES)
    #partial switch error {
    case .None:      return bytes,true,true
    case .Not_Found: return nil,false,true
    }
    return nil,false,false
}

@(private)
file_holds :: proc(r:^asset.Registry,path:string,present:bool,expected:[]u8) -> bool {
    current,exists,ok:=file_contents(r,path,context.temp_allocator)
    return ok && exists==present && (!present || string(current)==string(expected))
}

// Puts one side of a file: its bytes, or no file. One the registry keeps goes
// to its memory, which forgets it when it is what the disk holds.
@(private)
file_put :: proc(r:^asset.Registry,path:string,present:bool,bytes:[]u8) -> bool {
    if relative,unsaved:=file_unsaved(r,path);unsaved {
        if file_on_disk(path,present,bytes) {
            asset.registry_memory_drop(r,relative)
            return true
        }
        if !present {return asset.registry_memory_remove(r,relative)==.None}
        return asset.registry_memory_set(r,relative,bytes)==.None
    }
    if !present {return os.remove(path)==nil || !os.exists(path)}
    if os.make_directory_all(project_folder(path))!=nil && !os.is_dir(project_folder(path)) {return false}
    return serial.file_write_atomic(path,bytes)==.None
}

// The folder of a file; "." for one without.
@(private)
project_folder :: proc(file:string) -> string {
    cut:=strings.last_index_byte(file,'/')
    return cut>0?file[:cut]:"."
}

// Whether the disk holds one side of a file: its bytes, or no file. A file of
// another size is not read.
@(private)
file_on_disk :: proc(path:string,present:bool,bytes:[]u8) -> bool {
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil {return !present && !os.exists(path)}
    if !present || info.size!=i64(len(bytes)) {return false}
    disk,on_disk,read:=file_disk(path,context.temp_allocator)
    return read && on_disk && string(disk)==string(bytes)
}

// The gesture takes a file it changed: the first change keeps what was there
// before, the last what is there now. A file whose two sides end equal leaves
// the gesture.
@(private)
files_record :: proc(files:^[dynamic]Edit_File,path:string,before_present:bool,before:[]u8,after_present:bool,after:[]u8) -> bool {
    for &file,i in files {
        if file.path!=path {continue}
        delete(file.held)
        file.held_present,file.held=after_present,nil
        if after_present {file.held=make([]u8,len(after));copy(file.held,after)}
        if file.held_present==file.other_present && string(file.held)==string(file.other) {
            edit_file_free(&file)
            ordered_remove(files,i)
        }
        return true
    }
    if before_present==after_present && string(before)==string(after) {return true}
    file:=Edit_File{path=strings.clone(path),held_present=after_present,other_present=before_present}
    if after_present {file.held=make([]u8,len(after));copy(file.held,after)}
    if before_present {file.other=make([]u8,len(before));copy(file.other,before)}
    if len(file.path)!=len(path) || len(file.held)!=len(after) || len(file.other)!=len(before) {edit_file_free(&file);return false}
    if _,error:=append(files,file);error!=nil {edit_file_free(&file);return false}
    return true
}

// Puts back what the files of an open gesture held before it and forgets them.
@(private)
files_restore :: proc(r:^asset.Registry,files:^[dynamic]Edit_File,touched:^[dynamic]string,kept:^int) {
    #reverse for &file in files {
        if file.revised || file_holds(r,file.path,file.held_present,file.held) {
            if file_put(r,file.path,file.other_present,file.other) {file_touched(touched,file.path)}
        } else {
            kept^+=1
        }
        edit_file_free(&file)
    }
    clear(files)
}

// Undo and redo: each file of the step gets its other side while it holds
// the side the step left; one changed outside keeps what it has.
@(private)
files_swap :: proc(r:^asset.Registry,files:[]Edit_File,touched:^[dynamic]string,kept:^int) {
    #reverse for &file in files {
        if file.revised || file_holds(r,file.path,file.held_present,file.held) {
            if file_put(r,file.path,file.other_present,file.other) {file_touched(touched,file.path)} else {kept^+=1}
        } else {
            kept^+=1
        }
        file.held,file.other=file.other,file.held
        file.held_present,file.other_present=file.other_present,file.held_present
    }
}

@(private)
file_touched :: proc(touched:^[dynamic]string,path:string) {
    for known in touched {if known==path {return}}
    append(touched,strings.clone(path))
}

// What swaps and cancellations changed is taken again; files changed outside
// the editor that kept their content are told once.
@(private)
files_touched_settle :: proc(s:^Session,touched:^[dynamic]string,kept:^int) {
    if kept^>0 {
        notify(s,kept^==1?"A file changed outside the editor keeps its content":"Files changed outside the editor keep their content")
        kept^=0
    }
    for path in touched {
        file_changed(s,path)
        delete(path)
    }
    clear(touched)
}

@(private)
edits_files_cancel :: proc(edits:^Edits) {files_restore(edits.registry,&edits.files,&edits.touched,&edits.files_kept)}

@(private)
edits_files_swap :: proc(edits:^Edits,step:^Edit_Step) {files_swap(edits.registry,step.files[:],&edits.touched,&edits.files_kept)}

@(private)
files_free :: proc(files:^[dynamic]Edit_File,touched:^[dynamic]string) {
    for &file in files {edit_file_free(&file)}
    delete(files^)
    for path in touched {delete(path)}
    delete(touched^)
    files^,touched^=nil,nil
}

@(private)
edits_files_free :: proc(edits:^Edits) {files_free(&edits.files,&edits.touched)}

// Writes a file of the project as an edit, in the open gesture or in a step
// of its own named label; nil bytes with remove take it away. An asset file
// changes in memory, unsaved. Outside a transaction, a Play has no history:
// the file changes without a step.
file_write :: proc(s:^Session,path:string,bytes:[]u8,label:string,remove:=false) -> bool {
    r:=files_registry(s)
    if len(bytes)>EDITS_FILE_BYTES {return file_set(s,path,bytes,remove)}
    if h:=asset_history_front(s);h!=nil {return asset_history_write(s,h,path,bytes,label,remove)}
    history:=s.edits!=nil && (s.edits.open || shown_world(s).data==s.edits.world)
    opened,present:bool
    before:[]u8
    if history {
        ready,readable:bool
        if opened,ready=edit_open(s,label);!ready {return false}
        if before,present,readable=file_contents(r,path,context.temp_allocator);!readable {
            edit_close(s,opened)
            notify(s,"The file could not be read before changing it")
            return false
        }
        s.edits.registry=r
    }
    written:=file_put(r,path,!remove,bytes)
    if written {file_changed(s,path)}
    if history {
        if written && !files_record(&s.edits.files,path,present,before,!remove,remove?nil:bytes) {notify(s,"The file changed without a step of undo")}
        edit_close(s,opened)
    }
    return written
}

// Writes a file of the project outside the history, for an editor that keeps
// the undo of the file itself (the revisions of a terrain): an asset file
// changes in memory, unsaved, and is no change when it is what the disk holds.
//
// The steps that hold the file (the one that created it) put their side
// whatever it holds from then on: what that editor wrote is a revision of
// what they left.
file_set :: proc(s:^Session,path:string,bytes:[]u8,remove:=false) -> bool {
    written:=file_put(files_registry(s),path,!remove,bytes)
    if !written {return false}
    file_changed(s,path)
    if s.edits!=nil {
        for &file in s.edits.files {if file.path==path {file.revised=true}}
        for &step in s.edits.steps {for &file in step.files {if file.path==path {file.revised=true}}}
    }
    for &document in s.asset_documents {
        h:=&document.history
        for &file in h.files {if file.path==path {file.revised=true}}
        for &step in h.steps {for &file in step.files {if file.path==path {file.revised=true}}}
    }
    return true
}

// Whether a file of the project is there now: in the memory of the registry
// for one it keeps, else on disk.
file_exists :: proc(s:^Session,path:string) -> bool {
    _,present,_:=file_contents(files_registry(s),path,context.temp_allocator)
    return present
}

// What a file of the project holds now, as file_contents, in the temporary
// allocator: ok false when it is not there or cannot be read.
file_read :: proc(s:^Session,path:string) -> (data:[]u8,ok:bool) {
    present,read:bool
    data,present,read=file_contents(files_registry(s),path,context.temp_allocator)
    return data,present && read
}

// Changes when what file_read gives changes: the length and a hash of what
// memory holds, else the size and time of the file. ok false when it is not there.
file_stamp :: proc(s:^Session,path:string) -> (stamp:[2]i64,ok:bool) {
    if relative,unsaved:=file_unsaved(files_registry(s),path);unsaved {
        if held,found:=asset.registry_memory_find(files_registry(s),relative);found {
            if held.removed {return}
            return {i64(len(held.data)),i64(base.hash64(held.data,0))},true
        }
    }
    info,error:=os.stat(path,context.temp_allocator)
    if error!=nil {return}
    return {info.size,time.to_unix_nanoseconds(info.modification_time)},true
}

// What depends on a file of the project takes it again: an asset is read
// again where it is loaded, and the programs of the project are published
// when a source of theirs changed.
file_changed :: proc(s:^Session,path:string) {
    if strings.has_suffix(path,".slang") {
        if s.build!=nil {programs_publish_request(s)}
        return
    }
    r:=files_registry(s)
    relative,in_folder:=asset.registry_relative(r,path)
    if !in_folder {return}
    host.app_asset_changed(s.app,relative)
    collab_file_changed(s,relative)
}

// The files undo, redo and a cancelled gesture changed are taken again, those
// of the scene and those of the asset documents; those that changed outside
// the editor and kept their content are told once.
files_settle :: proc(s:^Session) {
    if s.edits!=nil {files_touched_settle(s,&s.edits.touched,&s.edits.files_kept)}
    for &document in s.asset_documents {files_touched_settle(s,&document.history.touched,&document.history.files_kept)}
}

// The project path of an absolute one, as the review and the API name files.
file_relative :: proc(s:^Session,path:string) -> string {
    if s.project_root!="" && strings.has_prefix(path,s.project_root) && len(path)>len(s.project_root) && path[len(s.project_root)]=='/' {return path[len(s.project_root)+1:]}
    return path
}
