package history

import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:std/serial"

// Files of the project in the history. A file an edit writes or removes (a
// .mat, the .slang of a program, an animation asset) is part of the step of
// its gesture: what it held before the first write of the gesture and what
// the last one left. Undo and redo put one side back while the file still
// holds the other; a file that changed outside the editor since keeps what it
// has, and the swap counts it as kept. A step that holds a file an editor
// also writes outside the history puts its side whatever it holds.
//
// An asset file of the folder is held by the registry of the assets until
// the editor writes it at the end of its step, and what it holds is what the
// registry holds. A content equal to the disk is no change. Other files (the
// Slang source of a program) are written at once.

EDITS_FILE_BYTES :: 64<<20 // a file larger than this is written without its history

// What a file was on the two sides of a step: held is what the step left in
// the file, other what a swap puts back. A side without the file is absent.
Edit_File :: struct {
    path:string, // absolute, with forward slashes
    held_present,other_present:bool,
    held,other:[]u8,
    revised:bool, // an editor also writes it outside the history (file_set): undo and redo put a side whatever it holds
}

edit_file_free :: proc(file:^Edit_File) {
    delete(file.path);delete(file.held);delete(file.other)
    file^={}
}

edit_file_bytes :: proc(file:^Edit_File) -> int {return len(file.path)+len(file.held)+len(file.other)}

// The path in the registry of a file it holds until its step ends: a file
// of the assets.
file_held :: proc(r:^asset.Registry,path:string) -> (relative:string,ok:bool) {
    return asset.registry_relative(r,path)
}

// What a file holds now, or not present: what the registry keeps of it in
// memory, else the disk. ok false when it exists but cannot be read.
file_contents :: proc(r:^asset.Registry,path:string,allocator:=context.allocator) -> (data:[]u8,present,ok:bool) {
    if relative,kept:=file_held(r,path);kept {
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

file_holds :: proc(r:^asset.Registry,path:string,present:bool,expected:[]u8) -> bool {
    current,exists,ok:=file_contents(r,path,context.temp_allocator)
    return ok && exists==present && (!present || string(current)==string(expected))
}

// Puts one side of a file: its bytes, or no file. One the registry holds goes
// to it, which forgets it when it is what the disk holds.
file_put :: proc(r:^asset.Registry,path:string,present:bool,bytes:[]u8) -> bool {
    if relative,kept:=file_held(r,path);kept {
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

@(private)
edits_files_cancel :: proc(edits:^Edits) {files_restore(edits.registry,&edits.files,&edits.touched,&edits.files_kept)}

@(private)
edits_files_swap :: proc(edits:^Edits,step:^Edit_Step) {files_swap(edits.registry,step.files[:],&edits.touched,&edits.files_kept)}

files_free :: proc(files:^[dynamic]Edit_File,touched:^[dynamic]string) {
    for &file in files {edit_file_free(&file)}
    delete(files^)
    for path in touched {delete(path)}
    delete(touched^)
    files^,touched^=nil,nil
}

@(private)
edits_files_free :: proc(edits:^Edits) {files_free(&edits.files,&edits.touched)}

// The path inside the project of an absolute one, as the review and the API name files.
file_relative :: proc(project_root,path:string) -> string {
    if project_root!="" && strings.has_prefix(path,project_root) && len(path)>len(project_root) && path[len(project_root)]=='/' {return path[len(project_root)+1:]}
    return path
}
