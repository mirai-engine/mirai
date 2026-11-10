package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"

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

// Writes a file of the project as an edit, in the open gesture or in a step
// of its own named label; nil bytes with remove take it away. An asset file
// changes in memory, unsaved. Outside a transaction, a Play has no history:
// the file changes without a step.
file_write :: proc(s:^Session,path:string,bytes:[]u8,label:string,remove:=false) -> bool {
    r:=files_registry(s)
    if len(bytes)>history.EDITS_FILE_BYTES {return file_set(s,path,bytes,remove)}
    if h:=asset_history_front(s);h!=nil {return asset_history_write(s,h,path,bytes,label,remove)}
    recorded:=s.edits!=nil && (s.edits.open || shown_world(s).data==s.edits.world)
    opened,present:bool
    before:[]u8
    if recorded {
        ready,readable:bool
        if opened,ready=edit_open(s,label);!ready {return false}
        if before,present,readable=history.file_contents(r,path,context.temp_allocator);!readable {
            edit_close(s,opened)
            notify(s,"The file could not be read before changing it")
            return false
        }
        s.edits.registry=r
    }
    written:=history.file_put(r,path,!remove,bytes)
    if written {file_changed(s,path)}
    if recorded {
        if written && !history.files_record(&s.edits.files,path,present,before,!remove,remove?nil:bytes) {notify(s,"The file changed without a step of undo")}
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
    written:=history.file_put(files_registry(s),path,!remove,bytes)
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
// The name and the file of a new asset of a tool, beside the scene (scene_folder,
// folder without one): prefix, with a number when a file has it. What a caller
// named keeps its name, and only its file takes the number.
asset_new_file :: proc(s:^Session,folder,prefix,extension:string,named:bool) -> (label,path:string) {
    folder:=scene_folder(s,folder)
    for number:=1;;number+=1 {
        stem:=number==1?prefix:fmt.tprintf("%s %d",prefix,number)
        path=fmt.tprintf("%s/%s%s",folder,stem,extension)
        if !file_exists(s,path) {return named?prefix:stem,path}
    }
}

// Whether a name can be the stem of a file on every system: what makes one of
// a tool (terrain.create, foliage.create) takes it as it is written.
asset_stem_valid :: proc(name:string) -> bool {
    return name!="" && len(name)<128 && name[0]!='.' && !strings.contains_any(name,"/\\:*?\"<>|")
}

file_exists :: proc(s:^Session,path:string) -> bool {
    _,present,_:=history.file_contents(files_registry(s),path,context.temp_allocator)
    return present
}

// What a file of the project holds now, as file_contents, in the temporary
// allocator: ok false when it is not there or cannot be read.
file_read :: proc(s:^Session,path:string) -> (data:[]u8,ok:bool) {
    present,read:bool
    data,present,read=history.file_contents(files_registry(s),path,context.temp_allocator)
    return data,present && read
}

// Changes when what file_read gives changes: the length and a hash of what
// memory holds, else the size and time of the file. ok false when it is not there.
file_stamp :: proc(s:^Session,path:string) -> (stamp:[2]i64,ok:bool) {
    if relative,unsaved:=history.file_unsaved(files_registry(s),path);unsaved {
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
