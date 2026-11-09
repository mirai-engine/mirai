package editor

import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"

// The records of the prefab instances travel as the history of each end
// moves them across a version (Prefab_Version): what a step, its undo or its
// redo took out and put in, and the prefab files it wrote. They go after the
// rows of the same update, so the members are there when they arrive. The
// host applies what a guest sends and passes it to everybody, the sender
// included, as with the rows: every end follows the order of the host. What
// another editor changes of a member is observed at each end as an override.

// The history moved the records of the document across a version: forward,
// from before it to after it.
@(private)
collab_prefab_step :: proc(s:^Session,v:^Prefab_Version,forward:bool) {
    st:=collab_state(s)
    if st==nil || st.role==.None || st.phase!=.Joined || s.app.assets==nil {return}
    out,back:=&v.came,&v.gone
    if forward {out,back=&v.gone,&v.came}
    w:serial.Writer
    serial.writer_init(&w,256,context.temp_allocator)
    serial.write_scalar(&w,st.self)
    serial.write_scalar(&w,back.last_instance)
    collab_prefab_records_write(&w,out)
    collab_prefab_records_write(&w,back)
    registry:=&s.app.assets.registry
    count:=0
    for file in v.files {
        if _,inside:=asset.registry_relative(registry,file.path);inside {count+=1}
    }
    serial.write_scalar(&w,u16(count))
    for file in v.files {
        relative,inside:=asset.registry_relative(registry,file.path)
        if !inside {continue}
        wanted:=forward?file.after:file.before
        serial.write_string(&w,relative)
        serial.write_scalar(&w,u8(wanted!=nil))
        serial.write_scalar(&w,u32(len(wanted)))
        serial.write_bytes(&w,wanted)
    }
    append(&st.prefabs_out,slice.clone(serial.writer_bytes(&w)))
}

@(private)
collab_prefabs_send :: proc(s:^Session,st:^Collab_State) {
    for payload in st.prefabs_out {
        if st.role==.Guest {
            collab_chunks_queue(&st.peers[0],.Prefab,payload)
        } else {
            for &peer,i in st.peers {
                if i!=0 && peer.used {collab_chunks_queue(&peer,.Prefab,payload)}
            }
        }
        delete(payload)
    }
    clear(&st.prefabs_out)
}

// A chunk of what a step of another end changed of the records; the whole
// change moves the records here as there.
@(private)
collab_prefab_receive :: proc(s:^Session,st:^Collab_State,from:int,r:^serial.Reader) {
    sender:=&st.peers[st.role==.Host?from:0]
    if _,complete:=collab_chunk_take(r,&sender.prefab_bytes,&sender.prefab_total);!complete {return}
    payload:=sender.prefab_bytes[:]
    in_:=serial.reader_init(payload)
    origin:=int(serial.read_u8(&in_))
    v:Prefab_Version
    v.came.last_instance=serial.read_u32(&in_)
    collab_prefab_records_read(&in_,&v.gone)
    collab_prefab_records_read(&in_,&v.came)
    File :: struct {relative:string,present:bool,data:[]u8}
    files:=make([dynamic]File,context.temp_allocator)
    count:=int(serial.read_u16(&in_))
    for _ in 0..<count {
        relative:=serial.read_string(&in_)
        present:=serial.read_u8(&in_)!=0
        data:=serial.read_bytes(&in_,int(serial.read_u32(&in_)))
        if in_.failed {break}
        if relative=="" || relative[0]=='.' || asset.registry_outside(relative) || strings.contains(relative,"..") {continue}
        append(&files,File{relative,present,data})
    }
    if in_.failed || origin>=COLLAB_PEERS || st.role==.Host && origin!=from {return}
    a:=s.app.assets
    p:=prefabs_of(s)
    previous:=prefab_previous(s)
    if a==nil || p==nil || previous==nil {return}
    last:=previous.info.last_instance
    prefab_records_move(previous,&v,true)
    previous.info.last_instance=max(last,v.came.last_instance)
    // The files are as their author left them; the prefabs are read again
    // unless this end wrote them, which a file it sent back shows.
    reload:=make([dynamic]string,context.temp_allocator)
    for file in files {
        path:=asset.registry_file_path(&a.registry,file.relative,context.temp_allocator)
        current,read_error:=os.read_entire_file(path,context.temp_allocator)
        exists:=read_error==nil
        written:=false
        if file.present && (!exists || !slice.equal(current,file.data)) {
            if at:=strings.last_index_byte(path,'/');at>0 && !os.is_dir(path[:at]) {_=os.make_directory_all(path[:at])}
            written=serial.file_write_atomic(path,file.data)==.None
        } else if !file.present && exists {
            written=os.remove(path)==nil
        }
        if written || origin!=int(st.self) {append(&reload,path)}
    }
    prefab_files_reload(s,reload[:])
    for instance in v.came.instances {
        if instance.outer!=0 || prefab_base_find(p,instance.prefab)!=nil {continue}
        if loaded,ok:=prefab_scene_load(s,instance.prefab);ok {prefab_base_set(s,instance.prefab,loaded)}
    }
    p.observed=false
    if st.role==.Host {
        s.document.unsaved=true
        for &peer,i in st.peers {
            if i!=0 && peer.used {collab_chunks_queue(&peer,.Prefab,payload)}
        }
    }
}

@(private="file")
collab_prefab_records_write :: proc(w:^serial.Writer,records:^Prefab_Records) {
    serial.write_scalar(w,u32(len(records.instances)))
    for x in records.instances {
        serial.write_scalar(w,x.id)
        serial.write_scalar(w,x.prefab[0]);serial.write_scalar(w,x.prefab[1])
        serial.write_scalar(w,u64(x.root))
        serial.write_scalar(w,x.outer)
        serial.write_scalar(w,x.stamp)
    }
    serial.write_scalar(w,u32(len(records.members)))
    for x in records.members {
        serial.write_scalar(w,x.instance)
        serial.write_scalar(w,u64(x.source))
        serial.write_scalar(w,u64(x.entity))
    }
    serial.write_scalar(w,u32(len(records.overrides)))
    for x in records.overrides {
        path:=x.path
        serial.write_scalar(w,x.instance)
        serial.write_scalar(w,u64(x.entity))
        serial.write_scalar(w,x.component)
        serial.write_scalar(w,u8(x.kind))
        serial.write_bytes(w,path[:])
    }
}

// Into the temporary allocator.
@(private="file")
collab_prefab_records_read :: proc(r:^serial.Reader,records:^Prefab_Records) {
    count:=int(serial.read_u32(r))
    if count>serial.reader_remaining(r) {r.failed=true}
    if r.failed {return}
    records.instances=make([dynamic]asset.Instance,0,count,context.temp_allocator)
    for _ in 0..<count {
        x:asset.Instance
        x.id=serial.read_u32(r)
        x.prefab[0]=serial.read_u64(r)
        x.prefab[1]=serial.read_u64(r)
        x.root=base.Entity_Id(serial.read_u64(r))
        x.outer=serial.read_u32(r)
        x.stamp=serial.read_u64(r)
        append(&records.instances,x)
    }
    count=int(serial.read_u32(r))
    if count>serial.reader_remaining(r) {r.failed=true}
    if r.failed {return}
    records.members=make([dynamic]asset.Member,0,count,context.temp_allocator)
    for _ in 0..<count {
        x:asset.Member
        x.instance=serial.read_u32(r)
        x.source=base.Entity_Id(serial.read_u64(r))
        x.entity=base.Entity_Id(serial.read_u64(r))
        append(&records.members,x)
    }
    count=int(serial.read_u32(r))
    if count>serial.reader_remaining(r) {r.failed=true}
    if r.failed {return}
    records.overrides=make([dynamic]asset.Override,0,count,context.temp_allocator)
    for _ in 0..<count {
        x:asset.Override
        x.instance=serial.read_u32(r)
        x.entity=base.Entity_Id(serial.read_u64(r))
        x.component=serial.read_u64(r)
        kind:=serial.read_u8(r)
        copy(x.path[:],serial.read_bytes(r,len(x.path)))
        if r.failed || kind>u8(max(asset.Override_Kind)) {r.failed=true;return}
        x.kind=asset.Override_Kind(kind)
        append(&records.overrides,x)
    }
}
