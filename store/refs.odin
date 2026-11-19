package store

import "core:os"

// A ref names an address: refs/<namespace>/<name>, holding its hex. The store
// does not interpret refs. Namespaces and names are lowercase ASCII letters,
// digits, '.', '_' and '-', so they are the same file on every system.

Ref :: struct {
    name:string,
    hash:Hash,
}

ref_get :: proc(s:^Store,namespace,name:string) -> (hash:Hash,error:Error) {
    buffer:[PATH_BYTES]u8
    path:=ref_file(s,namespace,name,&buffer) or_return
    file,open_error:=file_open(path)
    if open_error!=nil {return {},os_error(open_error)}
    defer os.close(file)
    return ref_parse(file)
}

// Points the ref at hash, replacing what it held at once.
ref_set :: proc(s:^Store,namespace,name:string,hash:Hash) -> Error {
    buffer,folder_buffer:[PATH_BYTES]u8
    path:=ref_file(s,namespace,name,&buffer) or_return
    folder_make(join(&folder_buffer,s.root,"refs",namespace) or_return) or_return
    text:[64]u8
    return file_write(s.root,path,{transmute([]u8)hex(hash,&text)})
}

ref_remove :: proc(s:^Store,namespace,name:string) -> Error {
    buffer:[PATH_BYTES]u8
    path:=ref_file(s,namespace,name,&buffer) or_return
    return os_error(file_remove(path))
}

// The refs of a namespace; an unknown namespace has none. ref_list_delete frees them.
ref_list :: proc(s:^Store,namespace:string,allocator:=context.allocator) -> (refs:[]Ref,error:Error) {
    if !name_valid(namespace) {return nil,.Invalid_Argument}
    buffer:[PATH_BYTES]u8
    folder:=join(&buffer,s.root,"refs",namespace) or_return
    entries,read_error:=os.read_all_directory_by_path(folder,s.allocator)
    if read_error==.Not_Exist {return nil,.None}
    if read_error!=nil {return nil,os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    list,make_error:=make([]Ref,len(entries),allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    n:=0
    for entry in entries {
        if entry.type!=.Regular || !name_valid(entry.name) {continue}
        file,open_error:=file_open(entry.fullpath)
        if open_error==.Not_Exist {continue}
        error=os_error(open_error)
        hash:Hash
        if error==.None {
            hash,error=ref_parse(file)
            os.close(file)
        }
        name,name_error:=make([]u8,len(entry.name),allocator)
        if error==.None && name_error!=nil {error=.Out_Of_Memory}
        if error!=.None {
            delete(name,allocator)
            ref_list_delete(list[:n],allocator)
            return nil,error
        }
        copy(name,entry.name)
        list[n]={name=string(name),hash=hash}
        n+=1
    }
    return list[:n],.None
}

// The namespaces that hold refs; ref_namespaces_delete frees them.
ref_namespaces :: proc(s:^Store,allocator:=context.allocator) -> (namespaces:[]string,error:Error) {
    buffer:[PATH_BYTES]u8
    folder:=join(&buffer,s.root,"refs") or_return
    entries,read_error:=os.read_all_directory_by_path(folder,s.allocator)
    if read_error==.Not_Exist {return nil,.None}
    if read_error!=nil {return nil,os_error(read_error)}
    defer os.file_info_slice_delete(entries,s.allocator)
    list,make_error:=make([]string,len(entries),allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    n:=0
    for entry in entries {
        if entry.type!=.Directory || !name_valid(entry.name) {continue}
        name,name_error:=make([]u8,len(entry.name),allocator)
        if name_error!=nil {
            ref_namespaces_delete(list[:n],allocator)
            return nil,.Out_Of_Memory
        }
        copy(name,entry.name)
        list[n]=string(name)
        n+=1
    }
    return list[:n],.None
}

ref_namespaces_delete :: proc(list:[]string,allocator:=context.allocator) {
    for name in list {delete(name,allocator)}
    delete(list,allocator)
}

ref_list_delete :: proc(list:[]Ref,allocator:=context.allocator) {
    for ref in list {delete(ref.name,allocator)}
    delete(list,allocator)
}

// 1 to NAME_MAX of lowercase letters, digits, '.', '_' and '-'; neither only
// dots, nor ending in a dot, nor a name Windows keeps for a device.
name_valid :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>NAME_MAX || name[len(name)-1]=='.' {return false}
    dots:=0
    stem:=len(name)
    for c,i in transmute([]u8)name {
        switch c {
        case 'a'..='z','0'..='9','_','-':
        case '.':
            dots+=1
            stem=min(stem,i)
        case:
            return false
        }
    }
    if dots==len(name) {return false}
    switch name[:stem] {
    case "con","prn","aux","nul": return false
    }
    if stem==4 && (name[:3]=="com" || name[:3]=="lpt") && name[3]>='0' && name[3]<='9' {return false}
    return true
}

@(private)
ref_file :: proc(s:^Store,namespace,name:string,buffer:^[PATH_BYTES]u8) -> (string,Error) {
    if !name_valid(namespace) || !name_valid(name) {return "",.Invalid_Argument}
    return join(buffer,s.root,"refs",namespace,name)
}

@(private)
ref_parse :: proc(file:^os.File) -> (Hash,Error) {
    text:[65]u8
    n,read_error:=os.read_at(file,text[:],0)
    if n<len(text) && read_error!=nil && read_error!=.EOF {return {},os_error(read_error)}
    if n==64 {
        if hash,ok:=parse_hex(string(text[:64]));ok {return hash,.None}
    }
    return {},.Corrupt
}
