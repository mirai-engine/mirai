package editor

import "core:mem"
import "core:os"
import "core:slice"
import "mirai:core"
import "mirai:host"
import wire "mirai:net"
import "mirai:std/base"
import "mirai:std/serial"

// What the session carries of the games of the host, besides the scene.
//
// Watching. A guest that watches the Play of the host receives its World as
// the edits of the document travel: rows of the components a scene saves,
// those core.changes says were written, added, turned or gone since the last
// send. Here rows are keyed by the Entity of the World of the host, not by
// Id, so what the game creates without an Id travels too; Entity fields go as
// they are and the guest maps them to entities of its own. A guest that
// starts watching receives every row, and later only what changed, with the
// view the host sees; when a table holds rows the last send did not see, all
// of them start again. The guest draws that World without running its game:
// it is not a run of its own.
//
// Network games. When the host starts a game on the network, it sends a mark
// in the ordered stream of edits. A guest that processes it and has nothing of
// its own unconfirmed has, at that moment, the scene the server of the host
// runs, and copies it; a guest that cannot, or that entered after the mark,
// asks the host for the copy when it joins the game.

COLLAB_WATCH_INTERVAL :: 1.0/20
COLLAB_WATCH_BACKLOG :: 64 // reliable messages a watcher may have waiting before the Play waits for it

@(private)
Collab_Watch :: struct {
    // The host: the run that was sent, what was sent of each table, and when.
    run:core.World_Id,
    seen:[]Collab_Watch_Seen,
    at:f64,
    view:[11]f32, // the last view sent; its last value only says that one was
    // A guest: the World built from what arrives, and its entity for each one of the host.
    asked:bool,
    world:rawptr,
    entities:map[base.Entity_Id]core.Entity,
    rows:map[base.Entity_Id]int,
}

// What the watchers were sent of a table of the run.
@(private)
Collab_Watch_Seen :: struct {seen:core.Seen,layout:u64,off:int} // off: rows that were not on

// ---------------------------------------------------------------- shared parts

// The operations as messages of a kind, each within the size of a message:
// the kind, the author, the count and the operations.
@(private)
collab_ops_pack :: proc(ops:^Collab_Ops,kind:Collab_Message,author:u8) -> [][]u8 {
    messages:=make([dynamic][]u8,context.temp_allocator)
    if ops.count==0 {return messages[:]}
    all:=make([dynamic]u8,context.temp_allocator)
    append(&all,..serial.writer_bytes(&ops.head))
    append(&all,..serial.writer_bytes(&ops.body))
    append(&all,..serial.writer_bytes(&ops.tail))
    at:=0
    for at<len(all) {
        m:serial.Writer
        collab_begin(&m,kind,COLLAB_MESSAGE)
        serial.write_scalar(&m,author)
        count_at:=m.count
        serial.write_scalar(&m,u16(0))
        count:=0
        for at<len(all) {
            size:=int(intrinsic_u16(all[at+17:]))
            length:=19+size
            if count>0 && m.count+length>COLLAB_MESSAGE {break}
            serial.write_bytes(&m,all[at:][:length])
            at+=length
            count+=1
        }
        patched:=u16(count)
        serial.writer_patch(&m,count_at,mem.ptr_to_bytes(&patched))
        append(&messages,serial.writer_bytes(&m))
    }
    return messages[:]
}

// Bytes too long for one message, in chunks of a kind: the tag, the total,
// the offset and the chunk.
@(private)
collab_chunks_queue :: proc(peer:^Collab_Peer,kind:Collab_Message,data:[]u8,tag:u32=0) {
    offset:=0
    for {
        size:=min(COLLAB_CHUNK,len(data)-offset)
        m:serial.Writer
        collab_begin(&m,kind,size+16)
        serial.write_scalar(&m,tag)
        serial.write_scalar(&m,u32(len(data)))
        serial.write_scalar(&m,u32(offset))
        serial.write_bytes(&m,data[offset:][:size])
        collab_queue(peer,serial.writer_bytes(&m))
        offset+=size
        if offset>=len(data) {break}
    }
}

// Adds a chunk to what is being assembled; true when the last one arrived.
@(private)
collab_chunk_take :: proc(r:^serial.Reader,into:^[dynamic]u8,total:^int) -> (tag:u32,complete:bool) {
    tag=serial.read_u32(r)
    whole:=int(serial.read_u32(r))
    offset:=int(serial.read_u32(r))
    chunk:=serial.read_bytes(r,serial.reader_remaining(r))
    if r.failed || whole<=0 || whole>1<<30 {return}
    if offset==0 {
        clear(into)
        total^=whole
    }
    if offset!=len(into) || whole!=total^ {return}
    append(into,..chunk)
    if len(into)<total^ {return}
    total^=0
    return tag,true
}

// The name an editor of the session gave.
collab_peer_name :: proc(s:^Session,id:int) -> string {
    st:=collab_state(s)
    if st==nil || id<0 || id>=COLLAB_PEERS {return ""}
    peer:=&st.peers[id]
    return string(peer.name[:peer.name_length])
}

@(private)
collab_host_seen :: proc(st:^Collab_State) -> bool {
    if st==nil || st.role!=.Guest || st.phase!=.Joined {return false}
    host:=&st.peers[0]
    return host.used && host.has_pose && wire.host_time(&st.host)-host.seen<=COLLAB_PRESENCE_SEEN
}

// A guest: whether it is in a session, and whether it hears the host now.
collab_host_heard :: proc(s:^Session) -> (joined,heard:bool) {
    st:=collab_state(s)
    return st!=nil && st.role==.Guest && st.phase==.Joined,collab_host_seen(st)
}

// A guest sees the host inside a Play or a Simulate of its own.
collab_host_playing :: proc(s:^Session) -> bool {
    st:=collab_state(s)
    return collab_host_seen(st) && st.peers[0].playing
}

// What this editor tells its guests of the game of a plugin it serves (Play_Provider.offer); 0: none.
@(private)
collab_offer :: proc(s:^Session,out:[]u8) -> int {
    p:=providers(s)
    if !p.plays || p.play.offer==nil {return 0}
    return clamp(p.play.offer(s,out),0,len(out))
}

// A guest: the offer of the game the host serves, and the address of the
// session as this guest reaches the host. The offer is a copy.
collab_host_offer :: proc(s:^Session) -> (offer:[]u8,target:wire.Address,ok:bool) {
    st:=collab_state(s)
    if !collab_host_seen(st) || !st.peers[0].serving {return}
    host:=&st.peers[0]
    offer=make([]u8,host.offer_size,context.temp_allocator)
    copy(offer,host.offer[:host.offer_size])
    return offer,st.target,true
}

// An address of this machine or of its network: loopback, private, link-local.
collab_address_local :: proc "contextless" (a:wire.Address) -> bool {
    ip:=a.ip
    #partial switch a.kind {
    case .IP4: return ip[0]==127 || ip[0]==10 || ip[0]==172 && ip[1]&0xf0==16 || ip[0]==192 && ip[1]==168 || ip[0]==169 && ip[1]==254
    case .IP6:
        loopback:=ip[15]==1
        for b in ip[:15] {loopback&&=b==0}
        return loopback || ip[0]&0xfe==0xfc || ip[0]==0xfe && ip[1]&0xc0==0x80
    }
    return false
}

// ---------------------------------------------------------------- watching: the host

// Sends the Play of the host to the guests that watch it: everything to the
// ones that start, what changed to the others, and the view.
@(private)
collab_watch_send :: proc(s:^Session,st:^Collab_State,now:f64) {
    if st.role!=.Host {return}
    wt:=&st.watch
    r:=run_find(s,0)
    run:=r!=nil?host.app_world_id(s.app,r.world):core.World_Id{}
    watchers,fresh:=0,0
    for &peer,i in st.peers {
        if i==0 || !peer.used || !peer.watching {continue}
        watchers+=1
        if peer.watch_fresh {fresh+=1}
    }
    if run!=wt.run {
        // The Play ended, or another began: those who watched start again.
        if wt.run!={} {
            end:=[1]u8{u8(Collab_Message.Watch_End)}
            for &peer,i in st.peers {
                if i==0 || !peer.used || !peer.watching {continue}
                if !peer.watch_fresh {collab_queue(&peer,end[:])}
                peer.watch_fresh=true
            }
            fresh=watchers
        }
        for &seen in wt.seen {seen={}}
        wt.run=run
        wt.view={}
    }
    if run=={} || watchers==0 {return}
    if fresh==0 {
        if now-wt.at<COLLAB_WATCH_INTERVAL {return}
        for &peer,i in st.peers {
            if i!=0 && peer.used && peer.watching && len(peer.out)-peer.head>COLLAB_WATCH_BACKLOG {return}
        }
    }
    wt.at=now
    w:=core.world_ref(r.world,s.info)
    core.world_settle(w)
    ops:Collab_Ops
    collab_ops_begin(&ops)
    if !collab_watch_diff(st,w,wt.seen,&ops) {
        for &peer,i in st.peers {
            if i!=0 && peer.used && peer.watching {peer.watch_fresh=true}
        }
        fresh=watchers
    }
    changed:=collab_ops_pack(&ops,.Watch_Rows,0)
    view,moved:=collab_watch_view(w,&wt.view)
    for &peer,i in st.peers {
        if i==0 || !peer.used || !peer.watching || peer.watch_fresh {continue}
        for message in changed {collab_queue(&peer,message)}
        if moved {collab_queue(&peer,view)}
    }
    if fresh==0 {return}
    // Those who start get every row.
    all:Collab_Ops
    collab_ops_begin(&all)
    collab_watch_all(st,w,&all)
    rows:=collab_ops_pack(&all,.Watch_Rows,0)
    begin:=[1]u8{u8(Collab_Message.Watch_Begin)}
    whole,_:=collab_watch_view(w,nil)
    for &peer,i in st.peers {
        if i==0 || !peer.used || !peer.watching || !peer.watch_fresh {continue}
        peer.watch_fresh=false
        collab_queue(&peer,begin[:])
        for message in rows {collab_queue(&peer,message)}
        collab_queue(&peer,whole)
    }
}

// What changed in the run since the last send, keyed by entity: the rows
// written, added or turned on, with their off state when rows moved and some
// were or are off; a row that went, or turned off. False when a table holds
// rows the last send did not see: those watching start again.
@(private)
collab_watch_diff :: proc(st:^Collab_State,w:core.World_Ref,seen:[]Collab_Watch_Seen,ops:^Collab_Ops) -> (complete:bool) {
    complete=true
    for &info,i in w.info.tables {
        t:=&st.tables[i]
        if !t.used {continue}
        table:=core.world_table_at(w,&info)
        sent:=&seen[i]
        c:=core.raw_changes(table,&sent.seen)
        off:=core.raw_count(table)-table.on
        turned:=sent.layout!=table.layout && (sent.off>0 || off>0)
        sent.layout,sent.off=table.layout,off
        if c.all {complete=false}
        if !complete {continue}
        for e,k in c.gone {
            if slice.contains(c.gone[:k],e) {continue}
            key:=base.Entity_Id(u64(e))
            row:=core.raw_row(table,e)
            if row<0 {
                collab_op_write(ops,&ops.body,.Remove,t.hash,key,nil)
            } else if table.stamps[row]<=c.since {
                turn:=[1]u8{u8(table.off[row])}
                collab_op_write(ops,&ops.body,.Turn,t.hash,key,turn[:])
            }
        }
        if table.version<=c.since {continue}
        current:=make([]u8,max(t.size,1),context.temp_allocator)
        for row in 0..<core.raw_count(table) {
            if table.stamps[row]<=c.since {continue}
            key:=base.Entity_Id(u64(table.entities[row]))
            collab_normalize(w,t,core.raw_value(table,info.info,row),current,true)
            collab_op_write(ops,&ops.body,.Set,t.hash,key,current[:t.size])
            if turned {
                turn:=[1]u8{u8(table.off[row])}
                collab_op_write(ops,&ops.body,.Turn,t.hash,key,turn[:])
            }
        }
    }
    return
}

// Every row of the run, keyed by entity, and those turned off by themselves.
@(private)
collab_watch_all :: proc(st:^Collab_State,w:core.World_Ref,ops:^Collab_Ops) {
    for &info,i in w.info.tables {
        t:=&st.tables[i]
        if !t.used {continue}
        table:=core.world_table_at(w,&info)
        current:=make([]u8,max(t.size,1),context.temp_allocator)
        for row in 0..<core.raw_count(table) {
            key:=base.Entity_Id(u64(table.entities[row]))
            collab_normalize(w,t,core.raw_value(table,info.info,row),current,true)
            collab_op_write(ops,&ops.body,.Set,t.hash,key,current[:t.size])
            if table.off[row] {
                turn:=[1]u8{1}
                collab_op_write(ops,&ops.body,.Turn,t.hash,key,turn[:])
            }
        }
    }
}

// The view of the World as a message; moved is false when it equals last.
@(private)
collab_watch_view :: proc(w:core.World_Ref,last:^[11]f32) -> (message:[]u8,moved:bool) {
    view:=core.world_storage_of(w,core.View)
    if view==nil {return}
    rotation:=transmute([4]f32)view.rotation
    values:=[11]f32{view.position.x,view.position.y,view.position.z,rotation.x,rotation.y,rotation.z,rotation.w,view.fov,view.near,view.far,1}
    if last!=nil {
        if last^==values {return}
        last^=values
    }
    m:serial.Writer
    collab_begin(&m,.Watch_View,64)
    for value in values[:10] {serial.write_scalar(&m,value)}
    return serial.writer_bytes(&m),true
}

// ---------------------------------------------------------------- watching: a guest

// The World of the Play of the host as it arrived; nil before it does.
collab_watch_world :: proc(s:^Session) -> rawptr {
    st:=collab_state(s)
    if st==nil || st.role!=.Guest {return nil}
    return st.watch.world
}

// Asks the host to send its Play, or to stop. False when there is no host to ask.
collab_watch_request :: proc(s:^Session,on:bool) -> bool {
    st:=collab_state(s)
    if st==nil || st.role!=.Guest {return false}
    if !on {collab_watch_drop(s,st)}
    if st.phase!=.Joined {return false}
    st.watch.asked=on
    message:=[2]u8{u8(Collab_Message.Watch),u8(on)}
    collab_queue(&st.peers[0],message[:])
    return true
}

@(private)
collab_watch_drop :: proc(s:^Session,st:^Collab_State) {
    wt:=&st.watch
    wt.asked=false
    if wt.world!=nil {
        host.app_world_free(s.app,wt.world)
        wt.world=nil
    }
    clear(&wt.entities)
    clear(&wt.rows)
}

// A new World for the Play: the old one, if any, goes.
@(private)
collab_watch_begin :: proc(s:^Session,st:^Collab_State) {
    if !st.watch.asked {return}
    if st.watch.world!=nil {host.app_world_free(s.app,st.watch.world)}
    clear(&st.watch.entities)
    clear(&st.watch.rows)
    st.watch.world=host.app_world_create(s.app)
    if s.mode==.Watch && s.watch.host {
        selection_clear(s.selection)
        s.view_cut=true
    }
}

// The entity of this World for one of the host; created the first time.
@(private)
collab_watch_entity :: proc(wt:^Collab_Watch,es:^core.Entities,key:base.Entity_Id) -> core.Entity {
    if key==0 {return core.NONE}
    if e,found:=wt.entities[key];found {return e}
    e:=core.create(es)
    wt.entities[key]=e
    return e
}

// Applies rows of the Play of the host. An entity that loses its last row goes.
@(private)
collab_watch_apply :: proc(s:^Session,st:^Collab_State,data:[]u8) {
    wt:=&st.watch
    if wt.world==nil {return}
    r:=serial.reader_init(data)
    serial.read_u8(&r)
    serial.read_u8(&r)
    count:=int(serial.read_u16(&r))
    w:=core.world_ref(wt.world,s.info)
    es:=core.world_entities(w)
    for _ in 0..<count {
        kind:=Collab_Op(serial.read_u8(&r))
        hash:=serial.read_u64(&r)
        key:=base.Entity_Id(serial.read_u64(&r))
        size:=int(serial.read_u16(&r))
        bytes:=serial.read_bytes(&r,size)
        if r.failed {break}
        i,known:=st.by_hash[hash]
        if !known || key==0 {continue}
        info:=&s.info.tables[i]
        t:=&st.tables[i]
        table:=core.world_table_at(w,info)
        switch kind {
        case .Set:
            if size!=t.size {continue}
            e:=collab_watch_entity(wt,es,key)
            value:=make([]u8,max(size,1),context.temp_allocator)
            if size>0 {copy(value,bytes)}
            for offset in t.entities {
                field:=cast(^u64)&value[offset]
                field^=u64(collab_watch_entity(wt,es,base.Entity_Id(field^)))
            }
            if current:=core.raw_find(table,info.info,e);current!=nil {
                for range in t.transient {
                    if range[1]>0 {mem.copy(&value[range[0]],rawptr(uintptr(current)+uintptr(range[0])),range[1])}
                }
            } else {
                wt.rows[key]+=1
            }
            core.raw_add(table,info.info,e,raw_data(value))
        case .Remove:
            e,found:=wt.entities[key]
            if !found || core.raw_find(table,info.info,e)==nil {continue}
            core.raw_remove(table,e)
            wt.rows[key]-=1
            if wt.rows[key]<=0 {
                core.destroy(es,e)
                delete_key(&wt.entities,key)
                delete_key(&wt.rows,key)
            }
        case .Turn:
            e,found:=wt.entities[key]
            if !found || size!=1 {continue}
            if bytes[0]!=0 {core.raw_disable(table,e)} else {core.raw_enable(table,e)}
        case .Fields:
        }
    }
    core.world_settle(w)
}

@(private)
collab_watch_view_apply :: proc(s:^Session,st:^Collab_State,data:[]u8) {
    if st.watch.world==nil {return}
    r:=serial.reader_init(data)
    serial.read_u8(&r)
    values:[10]f32
    for &value in values {value=serial.read_f32(&r)}
    if r.failed {return}
    view:=core.world_storage_of(core.world_ref(st.watch.world,s.info),core.View)
    if view==nil {return}
    view.position={values[0],values[1],values[2]}
    view.rotation=transmute(quaternion128)[4]f32{values[3],values[4],values[5],values[6]}
    view.fov,view.near,view.far=values[7],values[8],values[9]
    view.camera=core.NONE
}

// ---------------------------------------------------------------- games of plugins

// The host started the game of a plugin on the scene as it is: what it edited
// travels first, then the mark, so a guest that processes the mark has that scene.
collab_play_mark :: proc(s:^Session,game:u32) {
    st:=collab_state(s)
    if st==nil || st.role!=.Host || st.phase!=.Joined {return}
    collab_edits_send(s,st)
    w:serial.Writer
    collab_begin(&w,.Play_Mark,8)
    serial.write_scalar(&w,game)
    collab_broadcast(st,serial.writer_bytes(&w))
}

// A guest at the mark: its document is the scene of the server of the host
// when nothing of its own is waiting to be confirmed.
@(private)
collab_play_copy :: proc(s:^Session,st:^Collab_State,game:u32) {
    st.play_serial,st.play_copied=game,false
    if st.phase!=.Joined || collab_snapshot_loading(st) || st.sent_edits!=st.echoed_edits || s.edits.open || s.edits.preview || s.edits.commit {return}
    if collab_unsent(s,st) {return}
    st.play_copied=document_write(s,play_copy_file(s,PLAY_HOST_SCENE),false)==.None
}

// The copy of the scene of a game of the host: true when it is in its file;
// otherwise it is asked for, and Play_Provider.scene_arrived says when it is.
collab_play_scene :: proc(s:^Session,game:u32) -> bool {
    st:=collab_state(s)
    if st==nil || st.role!=.Guest || st.phase!=.Joined {return false}
    if st.play_serial==game && st.play_copied {return true}
    w:serial.Writer
    collab_begin(&w,.Play_Scene_Request,8)
    serial.write_scalar(&w,game)
    collab_queue(&st.peers[0],serial.writer_bytes(&w))
    return false
}

// The host sends the file its server runs, when the game is still that one.
@(private)
collab_play_scene_send :: proc(s:^Session,st:^Collab_State,peer:^Collab_Peer,game:u32) {
    p:=providers(s)
    if !p.plays || p.play.game==nil || game==0 || p.play.game(s)!=game {return}
    data,error:=os.read_entire_file(play_copy_file(s,PLAY_SCENE),context.temp_allocator)
    if error!=nil {return}
    collab_chunks_queue(peer,.Play_Scene,data,game)
}

@(private)
collab_play_scene_take :: proc(s:^Session,st:^Collab_State,r:^serial.Reader) {
    game,complete:=collab_chunk_take(r,&st.play_bytes,&st.play_total)
    if !complete {return}
    defer clear(&st.play_bytes)
    file:=play_copy_file(s,PLAY_HOST_SCENE)
    if os.write_entire_file(file,st.play_bytes[:])!=nil {return}
    st.play_serial,st.play_copied=game,true
    if p:=providers(s);p.plays && p.play.scene_arrived!=nil {p.play.scene_arrived(s,game)}
}
