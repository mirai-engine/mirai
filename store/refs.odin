package store

import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// A ref names an address: a Ref frame in its writer's pack, committed after
// the chunks it reaches, so no reader sees a ref before what it names is
// durable. The newest frame of a name wins; a removed ref is a frame of a zero
// address. The store does not interpret refs. Namespaces and names are
// lowercase ASCII letters, digits, '.', '_' and '-', the same on every system.

Ref :: struct {
    name:string,
    hash:Hash,
}

ref_get :: proc(s:^Store,namespace,name:string) -> (hash:Hash,error:Error) {
    if s==nil || s.state==nil || !name_valid(namespace) || !name_valid(name) {return {},.Invalid_Argument}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    read_index_locked(s) or_return
    return ref_get_locked(s,namespace,name)
}

@(private)
ref_get_locked :: proc(s:^Store,namespace,name:string) -> (hash:Hash,error:Error) {
    if v,found:=ref_resolve_locked(s,namespace,name);found {return v.address,.None}
    return {},.Missing
}

// Points the ref at hash and commits.
ref_set :: proc(s:^Store,namespace,name:string,hash:Hash,now:Maybe(time.Time)=nil) -> Error {
    if hash=={} {return .Invalid_Argument}
    return ref_frames_commit(s,{{namespace,name,hash}},now)
}

// A ref and the address it is pointed at.
Ref_Set :: struct {
    namespace,name:string,
    hash:Hash,
}

// Points every ref of sets at its hash in one commit: a reader, and a crash at
// any point, sees all of them moved or none.
refs_set :: proc(s:^Store,sets:[]Ref_Set,now:Maybe(time.Time)=nil) -> Error {
    for x in sets {
        if x.hash=={} {return .Invalid_Argument}
    }
    return ref_frames_commit(s,sets,now)
}

// Removes the ref and commits; Missing when it was not set.
ref_remove :: proc(s:^Store,namespace,name:string,now:Maybe(time.Time)=nil) -> Error {
    if s==nil || s.state==nil || !name_valid(namespace) || !name_valid(name) {return .Invalid_Argument}
    sync.mutex_lock(&s.state.lock)
    error:=refresh_locked(s)
    if error==.None {_,error=ref_get_locked(s,namespace,name)}
    sync.mutex_unlock(&s.state.lock)
    if error!=.None {return error}
    return ref_frames_commit(s,{{namespace,name,{}}},now)
}

// The frames of sets, a zero hash removing its ref, written and committed at once.
@(private)
ref_frames_commit :: proc(s:^Store,sets:[]Ref_Set,now:Maybe(time.Time)) -> Error {
    if s==nil || s.state==nil {return .Invalid_Argument}
    for x in sets {
        if !name_valid(x.namespace) || !name_valid(x.name) {return .Invalid_Argument}
    }
    at:=(now.? or_else time.now())._nsec
    batch_enter(s) or_return
    defer batch_leave(s)
    st:=stage_take(s) or_return
    defer stage_give(s,st)
    for x in sets {ref_stage(st,x.namespace,x.name,x.hash,at) or_return}
    stage_write(s,st,at) or_return
    return commit(s,time.Time{_nsec=at})
}

@(private)
ref_stage :: proc(st:^Stage,namespace,name:string,hash:Hash,now:i64) -> Error {
    payload:[REF_FIXED+2*NAME_MAX]u8
    time_value:=now
    copy(payload[:],mem.ptr_to_bytes(&time_value))
    payload[8],payload[9]=u8(len(namespace)),u8(len(name))
    copy(payload[REF_FIXED:],namespace)
    copy(payload[REF_FIXED+len(namespace):],name)
    return stage_frame(st,.Ref,hash,payload[:REF_FIXED+len(namespace)+len(name)])
}

// The refs of a namespace; an unknown namespace has none. ref_list_delete frees them.
ref_list :: proc(s:^Store,namespace:string,allocator:=context.allocator) -> (refs:[]Ref,error:Error) {
    if s==nil || s.state==nil || !name_valid(namespace) {return nil,.Invalid_Argument}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    read_index_locked(s) or_return
    return ref_list_locked(s,namespace,allocator)
}

// The refs of a namespace as the state holds them; nothing reads the root,
// so names taken from the state stay valid.
@(private)
ref_list_locked :: proc(s:^Store,namespace:string,allocator:=context.allocator) -> (refs:[]Ref,error:Error) {
    state:=s.state
    names:=make([dynamic]string,0,0,context.temp_allocator)
    defer delete(names)
    g:=&state.generation
    for r in g.refs {
        ns,_:=generation_string(g,r.namespace)
        if ns!=namespace {continue}
        name,_:=generation_string(g,r.name)
        if _,e:=append(&names,name);e!=nil {return nil,.Out_Of_Memory}
    }
    for key in state.refs {
        if len(key)<=len(namespace) || key[:len(namespace)]!=namespace || key[len(namespace)]!='/' {continue}
        if _,e:=append(&names,key[len(namespace)+1:]);e!=nil {return nil,.Out_Of_Memory}
    }
    slice.sort(names[:])
    list,make_error:=make([]Ref,len(names),allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    n:=0
    for name,i in names {
        if i>0 && names[i-1]==name {continue}
        v,found:=ref_resolve_locked(s,namespace,name)
        if !found {continue}
        cloned,e:=strings.clone(name,allocator)
        if e!=nil {
            ref_list_delete(list[:n],allocator)
            return nil,.Out_Of_Memory
        }
        list[n]={name=cloned,hash=v.address}
        n+=1
    }
    return list[:n],.None
}

// The namespaces that hold refs; ref_namespaces_delete frees them.
ref_namespaces :: proc(s:^Store,allocator:=context.allocator) -> (namespaces:[]string,error:Error) {
    if s==nil || s.state==nil {return nil,.Invalid_Argument}
    sync.mutex_lock(&s.state.lock)
    defer sync.mutex_unlock(&s.state.lock)
    read_index_locked(s) or_return
    state:=s.state
    seen:=make([dynamic]string,0,0,context.temp_allocator)
    defer delete(seen)
    g:=&state.generation
    for r in g.refs {
        ns,_:=generation_string(g,r.namespace)
        if _,e:=append(&seen,ns);e!=nil {return nil,.Out_Of_Memory}
    }
    for key in state.refs {
        slash:=strings.index_byte(key,'/')
        if slash<0 {continue}
        if _,e:=append(&seen,key[:slash]);e!=nil {return nil,.Out_Of_Memory}
    }
    slice.sort(seen[:])
    list,make_error:=make([]string,len(seen),allocator)
    if make_error!=nil {return nil,.Out_Of_Memory}
    n:=0
    for ns,i in seen {
        if ns=="" || (i>0 && seen[i-1]==ns) {continue}
        held,list_error:=ref_list_locked(s,ns,context.temp_allocator)
        if list_error!=.None {
            ref_namespaces_delete(list[:n],allocator)
            return nil,list_error
        }
        count:=len(held)
        ref_list_delete(held,context.temp_allocator)
        if count==0 {continue}
        cloned,e:=strings.clone(ns,allocator)
        if e!=nil {
            ref_namespaces_delete(list[:n],allocator)
            return nil,.Out_Of_Memory
        }
        list[n]=cloned
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
