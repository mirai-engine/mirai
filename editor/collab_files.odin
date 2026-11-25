package editor

import "core:strings"
import "mirai:asset"
import "mirai:cook/share"
import "mirai:editor/history"
import "mirai:exchange"
import vcs "mirai:kai"
import "mirai:std/serial"
import "mirai:store"

// The asset files edited in a session travel with it: a material an agent
// changed, a texture painted, a file undone. Each end puts what changed of its
// own in its store and sends its address; the others fetch its chunks over
// the exchange of the session, only those their stores lack, and then put it
// in the memory of their registries: the host passes it on once it has it,
// and writes it; a guest holds it while it is in. Whoever joins gets the
// files the host holds in memory after the scene. A file of any size travels.

// A file another end changed whose chunks are being fetched.
@(private)
Collab_Fetch :: struct {
    path:string,         // in the registry
    address:store.Hash,
    origin:int,          // who changed it
    message:[]u8,        // the File message, which the host passes on once it has the file
}

// A file of the assets changed here: it goes to the others with the next update.
@(private)
collab_file_changed :: proc(s:^Session,relative:string) {
    st:=collab_state(s)
    if st==nil || st.applying_file || st.phase!=.Joined || relative=="" || relative[0]=='.' {return}
    for known in st.files_out {if known==relative {return}}
    append(&st.files_out,strings.clone(relative))
}

// What a file holds now, for the others, as a File message: who sent it, its
// path, whether it is there, and the address and size of its bytes, put in
// the store and served by the node. Not ok when it cannot be read or put.
@(private)
collab_file_payload :: proc(s:^Session,st:^Collab_State,relative:string) -> (payload:[]u8,ok:bool) {
    r:=files_registry(s)
    if r==nil || s.store.root=="" {return}
    // In the heap: a file of any size, which the memory of a frame need not hold.
    data,present,read:=history.file_contents(r,asset.registry_file_path(r,relative,context.temp_allocator))
    defer delete(data)
    if !read {return}
    address:store.Hash
    if present {
        e:store.Error
        if address,e=store.put(&s.store,data);e!=.None || store.commit(&s.store)!=.None {return}
        if st.node!=nil {share.node_serve(st.node,address)}
    }
    w:serial.Writer
    collab_begin(&w,.File,len(relative)+64)
    serial.write_scalar(&w,st.self)
    serial.write_string(&w,relative)
    serial.write_scalar(&w,u8(present))
    serial.write_bytes(&w,address[:])
    serial.write_scalar(&w,u64(len(data)))
    return serial.writer_bytes(&w),true
}

@(private)
collab_files_send :: proc(s:^Session,st:^Collab_State) {
    for relative in st.files_out {
        if payload,ok:=collab_file_payload(s,st,relative);ok {
            if st.role==.Guest {
                collab_queue(&st.peers[0],payload)
            } else {
                for &peer,i in st.peers {
                    if i!=0 && peer.used && peer.joined {collab_queue(&peer,payload)}
                }
            }
        }
        delete(relative)
    }
    clear(&st.files_out)
}

// The files a guest that joins needs besides the scene: those the host holds
// in memory, which its folder has not.
@(private)
collab_files_join :: proc(s:^Session,st:^Collab_State,peer:^Collab_Peer) {
    r:=files_registry(s)
    if r==nil {return}
    for &held in r.memory {
        if len(held.path)==0 || held.path[0]=='.' || asset.registry_outside(held.path) {continue}
        if payload,ok:=collab_file_payload(s,st,held.path);ok {collab_queue(peer,payload)}
    }
}

// A file from another end: removed at once, else fetched by its address and
// then the whole one changes here as there.
@(private)
collab_file_receive :: proc(s:^Session,st:^Collab_State,from:int,message:[]u8,r:^serial.Reader) {
    origin:=int(serial.read_u8(r))
    relative:=serial.read_string(r)
    present:=serial.read_u8(r)!=0
    address:store.Hash
    copy(address[:],serial.read_bytes(r,len(address)))
    size:=serial.read_u64(r)
    if r.failed || origin>=COLLAB_PEERS || origin==int(st.self) || relative=="" || relative[0]=='.' || asset.registry_outside(relative) || strings.contains(relative,"..") {return}
    if st.role==.Host && origin!=from {return}
    if present && (address=={} || size>u64(max(int)/2)) {return}
    // A newer version of the file replaces one still being fetched.
    for k:=0;k<len(st.fetches); {
        f:=&st.fetches[k]
        if f.path!=relative {k+=1;continue}
        collab_fetch_free(st,f)
        ordered_remove(&st.fetches,k)
    }
    if !present || s.store.root=="" || asset.object_whole(&s.store,address) {
        collab_file_apply(s,st,from,origin,relative,present,address,message)
        return
    }
    if st.node==nil || exchange.want(&st.node.x,address)!=.None {return}
    append(&st.fetches,Collab_Fetch{path=strings.clone(relative),address=address,origin=origin,message=st.role==.Host?slice_clone(message):nil})
}

@(private)
slice_clone :: proc(bytes:[]u8) -> []u8 {
    out:=make([]u8,len(bytes))
    copy(out,bytes)
    return out
}

@(private)
collab_fetch_free :: proc(st:^Collab_State,f:^Collab_Fetch) {
    if st.node!=nil {exchange.forget(&st.node.x,f.address)}
    delete(f.path)
    delete(f.message)
}

// The files whose chunks arrived are applied; one that no peer has any more is told.
@(private)
collab_files_poll :: proc(s:^Session,st:^Collab_State) {
    if st.node==nil {return}
    for k:=0;k<len(st.fetches); {
        f:=&st.fetches[k]
        p,known:=exchange.progress(&st.node.x,f.address)
        waiting:=known && (p.state==.Asking || p.state==.Missing && f.origin<COLLAB_PEERS && st.peers[f.origin].used)
        if waiting {k+=1;continue}
        if known && p.state==.Complete {
            collab_file_apply(s,st,-1,f.origin,f.path,true,f.address,f.message)
        } else {
            notify(s,strings.concatenate({f.path," did not arrive from the session: the editor that changed it left"},context.temp_allocator))
        }
        collab_fetch_free(st,f)
        ordered_remove(&st.fetches,k)
    }
}

// Puts the file in the registry as the other end has it; the host writes it,
// records who changed it and passes it on.
@(private)
collab_file_apply :: proc(s:^Session,st:^Collab_State,from,origin:int,relative:string,present:bool,address:store.Hash,message:[]u8) {
    data:[]u8
    defer delete(data)
    if present {
        e:vcs.Error
        if data,e=vcs.file_bytes(&s.store,address);e!=.None {return}
    }
    if registry:=files_registry(s);registry!=nil {
        st.applying_file=true
        file_set(s,asset.registry_file_path(registry,relative,context.temp_allocator),data,!present)
        st.applying_file=false
    }
    if st.role!=.Host {return}
    if present && st.node!=nil {share.node_serve(st.node,address)}
    if origin>0 && origin<COLLAB_PEERS {kai_coauthor(s,st.peers[origin].key)}
    for &peer,i in st.peers {
        if i!=0 && i!=origin && i!=from && peer.used && peer.joined {collab_queue(&peer,message)}
    }
}
