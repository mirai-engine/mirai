package editor

import "core:fmt"
import "core:strings"
import "mirai:asset"
import "mirai:editor/history"
import "mirai:std/base"
import "mirai:std/serial"

// The asset files edited in a session travel with it: a material an agent
// changed, a texture painted, a file undone. Each end sends what changed of
// its own, in memory and unsaved like the edit, and the others put it in the
// memory of their registries; the host passes it on. Whoever joins gets the
// unsaved files of the host after the scene. A file over COLLAB_FILE_BYTES
// stays where it was edited, and every end is told so: the session cannot
// make it the same for all, the repository of the project does.

COLLAB_FILE_BYTES :: 32<<20
COLLAB_UNSENT :: 8         // files that did not travel a session keeps to tell of: the last ones
COLLAB_UNSENT_PATH :: 192

// A file an editor of the session changed that did not travel.
@(private)
Collab_Unsent :: struct {
    path:[COLLAB_UNSENT_PATH]u8, // in the registry
    peer:u8,                     // who changed it
    bytes:u64,
}

// A file of the assets changed here: it goes to the others with the next update.
@(private)
collab_file_changed :: proc(s:^Session,relative:string) {
    st:=collab_state(s)
    if st==nil || st.applying_file || st.phase!=.Joined || relative=="" || relative[0]=='.' {return}
    for known in st.files_out {if known==relative {return}}
    append(&st.files_out,strings.clone(relative))
}

// What a file holds now, for the others: who sent it, its path, whether it is
// there and its bytes. Not ok with its size when it is too large to travel.
@(private)
collab_file_payload :: proc(s:^Session,st:^Collab_State,relative:string) -> (payload:[]u8,size:int,ok:bool) {
    r:=files_registry(s)
    if r==nil {return}
    data,present,read:=history.file_contents(r,asset.registry_file_path(r,relative,context.temp_allocator),context.temp_allocator)
    if !read {return}
    if len(data)>COLLAB_FILE_BYTES {return nil,len(data),false}
    w:serial.Writer
    serial.writer_init(&w,len(data)+len(relative)+16,context.temp_allocator)
    serial.write_scalar(&w,st.self)
    serial.write_string(&w,relative)
    serial.write_scalar(&w,u8(present))
    serial.write_bytes(&w,data)
    return serial.writer_bytes(&w),len(data),true
}

@(private)
collab_unsent_find :: proc(st:^Collab_State,relative:string) -> int {
    for &unsent,i in st.unsent[:st.unsent_count] {
        if base.text_get(unsent.path[:])==relative {return i}
    }
    return -1
}

// A file did not travel: the session keeps it to tell of, and this editor is
// told once, with what makes the file the same for all. False when it was known.
@(private)
collab_unsent_add :: proc(s:^Session,st:^Collab_State,relative:string,peer:int,bytes:int) -> bool {
    if at:=collab_unsent_find(st,relative);at>=0 {
        st.unsent[at].peer,st.unsent[at].bytes=u8(peer),u64(bytes)
        return false
    }
    if st.unsent_count==COLLAB_UNSENT {
        copy(st.unsent[:],st.unsent[1:])
        st.unsent_count-=1
    }
    unsent:=&st.unsent[st.unsent_count]
    unsent^={peer=u8(peer),bytes=u64(bytes)}
    base.text_set(unsent.path[:],relative)
    st.unsent_count+=1
    notify(s,collab_unsent_text(st,unsent))
    return true
}

// The file travelled after all, or went.
@(private)
collab_unsent_drop :: proc(st:^Collab_State,relative:string) {
    at:=collab_unsent_find(st,relative)
    if at<0 {return}
    copy(st.unsent[at:],st.unsent[at+1:st.unsent_count])
    st.unsent_count-=1
}

// What a file that did not travel is, and what to do about it.
@(private)
collab_unsent_text :: proc(st:^Collab_State,unsent:^Collab_Unsent) -> string {
    path:=base.text_get(unsent.path[:])
    if unsent.peer==st.self {return fmt.tprintf("%s is too large for the session: save it and share it through the repository of the project",path)}
    peer:=&st.peers[unsent.peer]
    name:=peer.name_length>0?string(peer.name[:peer.name_length]):"another editor"
    return fmt.tprintf("%s of %s is too large for the session: get it from the repository of the project once they share it",path,name)
}

// The files of the editors that left are nobody's to share any more.
@(private)
collab_unsent_prune :: proc(st:^Collab_State) {
    kept:=0
    for unsent in st.unsent[:st.unsent_count] {
        if !st.peers[unsent.peer].used {continue}
        st.unsent[kept]=unsent
        kept+=1
    }
    st.unsent_count=kept
}

// Tells the others, or one of them, of a file that did not travel.
@(private)
collab_unsent_tell :: proc(st:^Collab_State,unsent:^Collab_Unsent,to:^Collab_Peer=nil,except:int=-1) {
    w:serial.Writer
    collab_begin(&w,.File_Unsent,COLLAB_UNSENT_PATH+16)
    serial.write_scalar(&w,unsent.peer)
    serial.write_scalar(&w,unsent.bytes)
    serial.write_string(&w,base.text_get(unsent.path[:]))
    if to!=nil {collab_queue(to,serial.writer_bytes(&w))} else {collab_broadcast(st,serial.writer_bytes(&w),except)}
}

@(private)
collab_unsent_receive :: proc(s:^Session,st:^Collab_State,from:int,r:^serial.Reader) {
    origin:=int(serial.read_u8(r))
    bytes:=serial.read_u64(r)
    relative:=serial.read_string(r)
    if r.failed || origin>=COLLAB_PEERS || origin==int(st.self) || relative=="" || len(relative)>=COLLAB_UNSENT_PATH {return}
    if st.role==.Host && origin!=from {return}
    added:=collab_unsent_add(s,st,relative,origin,int(min(bytes,u64(max(int)))))
    if added && st.role==.Host {collab_unsent_tell(st,&st.unsent[st.unsent_count-1],except=from)}
}

@(private)
collab_files_send :: proc(s:^Session,st:^Collab_State) {
    for relative in st.files_out {
        payload,size,ok:=collab_file_payload(s,st,relative)
        switch {
        case ok:
            collab_unsent_drop(st,relative)
            if st.role==.Guest {
                collab_chunks_queue(&st.peers[0],.File,payload)
            } else {
                for &peer,i in st.peers {
                    if i!=0 && peer.used && peer.joined {collab_chunks_queue(&peer,.File,payload)}
                }
            }
        case size>COLLAB_FILE_BYTES:
            if collab_unsent_add(s,st,relative,int(st.self),size) {collab_unsent_tell(st,&st.unsent[st.unsent_count-1])}
        }
        delete(relative)
    }
    clear(&st.files_out)
}

// The files a guest that joins needs besides the scene: those the host
// changed and did not save, and word of those that do not travel.
@(private)
collab_files_join :: proc(s:^Session,st:^Collab_State,peer:^Collab_Peer) {
    r:=files_registry(s)
    if r==nil {return}
    for &held in r.memory {
        if asset.registry_outside(held.path) || len(held.path)==0 || held.path[0]=='.' {continue}
        payload,size,ok:=collab_file_payload(s,st,held.path)
        if ok {collab_chunks_queue(peer,.File,payload)} else if size>COLLAB_FILE_BYTES {collab_unsent_add(s,st,held.path,int(st.self),size)}
    }
    for &unsent in st.unsent[:st.unsent_count] {collab_unsent_tell(st,&unsent,peer)}
}

// A chunk of a file from another end; the whole one changes here as there.
@(private)
collab_file_receive :: proc(s:^Session,st:^Collab_State,from:int,r:^serial.Reader) {
    sender:=&st.peers[st.role==.Host?from:0]
    if _,complete:=collab_chunk_take(r,&sender.file_bytes,&sender.file_total);!complete {return}
    payload:=sender.file_bytes[:]
    in_:=serial.reader_init(payload)
    origin:=int(serial.read_u8(&in_))
    relative:=serial.read_string(&in_)
    present:=serial.read_u8(&in_)!=0
    data:=serial.read_bytes(&in_,serial.reader_remaining(&in_))
    if in_.failed || origin>=COLLAB_PEERS || origin==int(st.self) || relative=="" || relative[0]=='.' || asset.registry_outside(relative) || strings.contains(relative,"..") {return}
    if st.role==.Host && origin!=from {return}
    if registry:=files_registry(s);registry!=nil {
        st.applying_file=true
        file_set(s,asset.registry_file_path(registry,relative,context.temp_allocator),data,!present)
        st.applying_file=false
    }
    collab_unsent_drop(st,relative)
    if st.role==.Host {
        for &peer,i in st.peers {
            if i!=0 && i!=from && peer.used && peer.joined {collab_chunks_queue(&peer,.File,payload)}
        }
    }
}
