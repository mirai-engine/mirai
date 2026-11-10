package editor

import "core:crypto"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import scene "mirai:engine/scene"
import "mirai:host"
import wire "mirai:net"
import gpu "mirai:render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
import "mirai:ui"

// Collaboration: several editors share the scene of one of them. The host
// owns the file and orders the edits; a guest receives the whole scene when
// it enters and keeps its own copy in memory. What travels is what the
// journal of the document (journal.odin) says changed since the others were
// told, by component and entity, identified by Id: the fields of every row
// that changed (its Entity fields as Ids), the whole row when it is new to
// the others, whether it turned off or on, and the Ids of the rows that went.
// Whoever receives it writes those fields alone: two ends that change
// different fields of a row both keep theirs. A guest sends what it edited to
// the host, which applies it, and sends it to everybody, the sender included,
// so the ends converge to the order of the host, which decides a field two
// of them changed. Edits made by others do not enter the history of undo.
// Each end also sends its camera and selection at 12 Hz, which the others
// draw as avatars and outlines: selecting holds nothing.
//
// A guest joins with the code of the invitation of the host (net/invite.odin):
// its address on the router, or on its network, and the token of the session.

COLLAB_PORT :: 7950
COLLAB_VERSION :: 5 // of the messages: an editor of another one has another version of the project
COLLAB_PEERS :: 8 // the host and seven guests
COLLAB_NAME_BYTES :: 32
COLLAB_SELECTION :: 16
COLLAB_PRESENCE_INTERVAL :: 1.0/12
COLLAB_EDIT_INTERVAL :: 1.0/30
COLLAB_PRESENCE_SEEN :: 3.0 // seconds
COLLAB_CHUNK :: 8<<10
COLLAB_MESSAGE :: 10<<10
COLLAB_HELLO_TIMEOUT :: 10.0
COLLAB_WORKER_INTERVAL :: 2*time.Millisecond // between updates of the network half
COLLAB_PLAYING :: u8(1) // presence: inside a Play or a Simulate of its own
COLLAB_SERVING :: u8(2) // presence: serves the game of a plugin, whose offer follows
COLLAB_JOINED :: u8(4)  // presence: a guest that plays the game the host serves
COLLAB_OFFER_BYTES :: 32 // what the presence of the host carries of the game it serves (Play_Provider.offer)

Collab_Role :: enum u8 {None,Host,Guest}
Collab_Phase :: enum u8 {Idle,Connecting,Syncing,Joined,Ended}

Collab_Error :: enum u8 {
    None,
    Busy,        // a session is open
    Playing,
    Invite,      // not the code of an invitation
    Transport,   // the port could not be opened
    No_Assets,
    Dirty,       // the scene has unsaved changes
    No_Random,   // the system gives no secure random bytes, which the session is sealed with
}

collab_error_text :: proc(error:Collab_Error) -> string {
    switch error {
    case .None:      return ""
    case .Busy:      return "a session is open; leave it first"
    case .Playing:   return "a game is playing; stop it first"
    case .Invite:    return "not the code of an invitation: like K7Q2-9XMA-PL3F-0B2C"
    case .Transport: return "the port could not be opened"
    case .No_Assets: return "the project has no assets folder"
    case .Dirty:     return "the scene has unsaved changes; save it or discard them"
    case .No_Random: return "this system gives no secure random bytes to seal the session with"
    }
    return ""
}

@(private)
Collab_Message :: enum u8 {
    Hello=1,Welcome,Snapshot,Ready,Edit,Presence,Roster,Reject,
    Play_Mark,Play_Scene_Request,Play_Scene,           // the scene of a game of the host on the network (collab_play.odin)
    Agents,                                            // the agents of an editor (collab_agents.odin)
    Ping,                                              // a point of the scene an editor pinged (collab_ping.odin)
    File,                                              // an asset file an editor changed, in chunks (collab_files.odin)
    File_Unsent,                                       // an asset file an editor changed that is too large to travel
}

// Set: the whole row, for whoever has none. Fields: runs of bytes of a row,
// each its offset and its size as u16 and then its bytes. Turn: one byte, 1
// when the component is turned off by itself.
@(private)
Collab_Op :: enum u8 {Set=1,Remove,Turn,Fields}

@(private)
Collab_Peer :: struct {
    used,joined:bool,    // used: connected; joined: has the scene
    connection:wire.Connection,
    name:[COLLAB_NAME_BYTES]u8,
    name_length:int,
    client:u64,          // Collab.client of the editor
    orbit:Orbit,
    has_pose:bool,
    playing:bool,        // is inside a Play or a Simulate of their own
    serving:bool,        // serves the game of a plugin, as its offer says
    in_game:bool,        // plays the game the host serves
    offer:[COLLAB_OFFER_BYTES]u8,
    offer_size:int,
    seen:f64,
    selection:[COLLAB_SELECTION]base.Entity_Id,
    selection_count:int,
    agents:Collab_Agents,
    file_bytes:[dynamic]u8, // a file it sends, as it arrives
    file_total:int,
    out:[dynamic][]u8,   // reliable messages not sent yet
    head:int,
    connected_at:f64,
}

// What a component needs to travel: its size, the fields a scene saves of it, the transient bytes that stay local and its Entity fields.
@(private)
Collab_Table :: struct {
    used:bool,
    size:int,
    hash:u64,
    fields:[][2]int,
    transient:[][2]int,
    entities:[]uintptr,
}

// A row of the document, and what the others were told of it.
@(private)
Collab_Key :: struct {table:i32,entity:core.Entity}
@(private)
Collab_Told :: struct {
    id:base.Entity_Id,
    present,off:bool,
    value:int, // where its bytes as they were told are in told_values, when present
}
// A row by its Id. An entity made again under its Id (an operation of prefabs
// replaces the World) keeps it: the rows of its old handle do not remove it.
@(private)
Collab_Row :: struct {table:i32,id:base.Entity_Id}

@(private)
Collab_Ops :: struct {
    head,body,tail:serial.Writer, // sets of Ids first, then everything else, removals of Ids last
    count:int,
}

@(private)
Collab_State :: struct {
    role:Collab_Role,
    phase:Collab_Phase,
    reason:string,
    udp:wire.Udp,
    host:wire.Host,
    mapping:wire.Port_Mapping,
    mapping_on:bool,
    port:int,
    invite:u32,           // the token of the session
    target:wire.Address,  // a guest: the host
    self:u8,
    peers:[COLLAB_PEERS]Collab_Peer,
    layout:u32,
    tables:[]Collab_Table,
    cursor:u64,                         // in the changes of the journal of the document
    told:map[Collab_Key]Collab_Told,    // the rows of edits not in the journal yet, as the others were told them
    told_values:[dynamic]u8,
    crossed:map[Collab_Key]struct{},    // a guest: the rows other ends wrote while edits of its own were on their way to the host
    by_hash:map[u64]int,
    snapshot:[dynamic]u8, // a guest assembling the scene
    snapshot_total:int,
    epoch:u64,            // of the history of the document being shared
    presence_at,edit_at:f64,
    code:[48]u8,          // the host: its invitation, as others reach it
    code_length:int,
    sent_edits,received_edits,sent_ops,received_ops:u64,
    guest_name:[COLLAB_NAME_BYTES]u8,
    guest_name_length:int,
    echoed_edits:u64,     // a guest: its Edit messages the host sent back
    play_serial:u32,      // a guest: the last game of the host it saw the mark of
    play_copied:bool,     // and its copy of the scene of that game is written
    play_bytes:[dynamic]u8,
    play_total:int,
    figures:[COLLAB_PEERS]Presence, // of the others, by their place in peers
    agent_figures:[COLLAB_PEERS][COLLAB_AGENTS]Presence, // of their agents
    agents_key:u64,  // of the agents of this end as last sent
    agents_at:f64,
    files_out:[dynamic]string, // asset files changed here since the last update, by their paths in the registry
    applying_file:bool,        // a file of another end is being put: its change is not this end's
    unsent:[COLLAB_UNSENT]Collab_Unsent, // the files that did not travel; the first unsent_count
    unsent_count:int,
}

@(storage)
Collab :: struct {
    state:^Collab_State,
    // The fields of the Share popup.
    name:[COLLAB_NAME_BYTES]u8,
    name_length:int,
    join:[64]u8,
    join_length:int,
    joining:bool,
    error:Collab_Error,
    client:u64,   // who this editor is in every session: one that joins again takes its place back
    pings:[COLLAB_PEERS]Collab_Ping, // the last of each editor, by its place in the session; this one alone is 0
}

@(private)
collab_of :: proc(s:^Session) -> ^Collab {
    if s.editor_world==nil {return nil}
    return core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Collab)
}

// Who this editor is, the same in every session it shares or joins.
@(private)
collab_client :: proc(c:^Collab) -> u64 {
    when crypto.HAS_RAND_BYTES {
        for c.client==0 {crypto.rand_bytes(mem.ptr_to_bytes(&c.client))}
    }
    return c.client
}

@(private)
collab_state :: proc(s:^Session) -> ^Collab_State {
    c:=collab_of(s)
    return c==nil?nil:c.state
}

collab_active :: proc(s:^Session) -> bool {
    st:=collab_state(s)
    return st!=nil && st.role!=.None && st.phase!=.Ended
}

// This editor shares its scene: its Play serves the game for the guests.
collab_hosting :: proc(s:^Session) -> bool {
    st:=collab_state(s)
    return st!=nil && st.role==.Host && st.phase==.Joined
}

// A guest does not write the file of the scene: the host does.
collab_can_save :: proc(s:^Session) -> bool {
    st:=collab_state(s)
    return st==nil || st.role!=.Guest || st.phase==.Ended
}

// A guest cannot open another scene without leaving the session.
collab_can_open :: proc(s:^Session) -> bool {
    st:=collab_state(s)
    return st==nil || st.role!=.Guest || st.phase==.Ended
}

collab_summary :: proc(s:^Session) -> string {
    st:=collab_state(s)
    if st==nil || st.role==.None {return "none"}
    switch st.role {
    case .None: return "none"
    case .Host: return "host"
    case .Guest:
        switch st.phase {
        case .Idle:       return "guest"
        case .Connecting: return "guest connecting"
        case .Syncing:    return "guest syncing"
        case .Joined:     return "guest joined"
        case .Ended:      return "ended"
        }
    }
    return "none"
}

// ---------------------------------------------------------------- layout

@(private)
collab_layout_hash :: proc(info:^core.World_Info) -> u32 {
    hash:=base.hash_combine(0x6d63,COLLAB_VERSION)
    for t in info.tables {
        if t.place!=.World {continue}
        hash=base.hash_combine(hash,base.name_hash(t.name))
        hash=base.hash_combine(hash,u64(t.info.size))
    }
    return u32(hash)~u32(hash>>32)
}

@(private)
collab_tables_build :: proc(s:^Session,st:^Collab_State) {
    st.tables=make([]Collab_Table,len(s.info.tables))
    st.by_hash=make(map[u64]int)
    st.told=make(map[Collab_Key]Collab_Told)
    st.crossed=make(map[Collab_Key]struct{})
    for &t,i in s.info.tables {
        if t.place!=.World || i>=len(s.edits.saved) || !s.edits.saved[i] {continue}
        size:=t.info.size
        ranges:=history.transient_ranges(t.info,context.allocator)
        offsets:=entity_offsets(t.info,context.allocator)
        st.tables[i]={used=true,size=size,hash=base.name_hash(t.name),fields=history.saved_fields(t.info,context.allocator),transient=ranges,entities=offsets}
        st.by_hash[st.tables[i].hash]=i
    }
}

@(private)
collab_tables_free :: proc(st:^Collab_State) {
    for &t in st.tables {
        delete(t.fields);delete(t.transient);delete(t.entities)
    }
    delete(st.tables)
    delete(st.by_hash)
    delete(st.told)
    delete(st.told_values)
    delete(st.crossed)
    st.tables,st.by_hash,st.told,st.told_values,st.crossed=nil,nil,nil,nil,nil
}

// ---------------------------------------------------------------- start and end

@(private)
collab_name_set :: proc(c:^Collab,name:string) {
    text:=strings.trim_space(name)
    if text=="" {text="Editor"}
    c.name_length=copy(c.name[:COLLAB_NAME_BYTES-1],text)
}

@(private)
collab_start :: proc(s:^Session,role:Collab_Role,port:int,name:string,invite:u32,target:wire.Address={}) -> (st:^Collab_State,error:Collab_Error) {
    c:=collab_of(s)
    if c.state!=nil && c.state.role!=.None && c.state.phase!=.Ended {return nil,.Busy}
    if s.app.assets==nil {return nil,.No_Assets}
    if s.mode!=.Edit {return nil,.Playing}
    if c.state!=nil {collab_destroy(s)}
    collab_name_set(c,name)
    st=new(Collab_State)
    st.role=role
    st.layout=collab_layout_hash(s.info)
    channels:=[2]wire.Channel_Desc{
        {kind=.Reliable,max_message_bytes=COLLAB_MESSAGE,queue_bytes=256<<10},
        {kind=.Unreliable},
    }
    // A guest of an IPv4 host binds IPv4, which can also look for it by broadcast on its network.
    bind:=role==.Guest && target.kind==.IP4?wire.address_ip4(0,0,0,0,0):wire.address_any6(role==.Host?port:0)
    if !wire.udp_open(&st.udp,bind) {
        free(st)
        return nil,.Transport
    }
    desc:=wire.Host_Desc{
        mode=role==.Host?.Server:.Client,transport=wire.udp_transport(&st.udp),protocol_id=0x4d495241,version=st.layout,invite=invite,
        max_connections=COLLAB_PEERS-1,channels=channels[:],
    }
    // Its network half runs on a thread of its own: an editor busy for a while
    // (generating the world of a game) keeps answering, and the session lives.
    if wire.host_init(&st.host,desc)!=.None || !wire.worker_start(&st.host,COLLAB_WORKER_INTERVAL) {
        wire.host_destroy(&st.host)
        wire.udp_close(&st.udp)
        free(st)
        return nil,.Transport
    }
    collab_tables_build(s,st)
    st.epoch=s.edits.epoch
    st.port=int(st.udp.address.port)
    st.invite=invite
    c.state=st
    return st,.None
}

// Shares the scene: guests connect to this editor.
collab_host :: proc(s:^Session,port:int,name:string) -> Collab_Error {
    invite,made:=wire.invite_token()
    if !made {return .No_Random}
    st,error:=collab_start(s,.Host,port>0?port:COLLAB_PORT,name,invite)
    if error!=.None {return error}
    st.phase=.Joined
    st.self=0
    c:=collab_of(s)
    st.peers[0]={used=true,joined=true}
    st.peers[0].name_length=copy(st.peers[0].name[:],string(c.name[:c.name_length]))
    st.peers[0].orbit=s.viewport.orbit
    collab_journal_reset(s,st)
    st.mapping_on=wire.mapping_start(&st.mapping,u16(st.port))
    collab_codes_update(st)
    return .None
}

// Enters the session of another editor with the code of its invitation: the scene is replaced by the one of the host.
collab_join :: proc(s:^Session,code,name:string,discard:bool) -> Collab_Error {
    target,invite,valid:=wire.invite_decode(code)
    if !valid {return .Invite}
    if document_dirty(s) && !discard {return .Dirty}
    st,error:=collab_start(s,.Guest,0,name,invite,target)
    if error!=.None {return error}
    // Also on this machine and its network: the address of the code may be a router that does not loop back.
    if wire.host_connect(&st.host,target,nearby=true)!=.None {
        collab_destroy(s)
        return .Transport
    }
    st.phase=.Connecting
    st.self=0xff
    st.target=target
    st.peers[0].connected_at=wire.host_time(&st.host)
    return .None
}

// Ends the session; the scene stays as it is.
collab_leave :: proc(s:^Session) {
    st:=collab_state(s)
    if st==nil || st.role==.None {return}
    if st.phase!=.Ended {
        bye:=[1]u8{u8(Collab_Message.Reject)}
        if st.role==.Host {wire.message_send(&st.host,0,0,bye[:])}
        wire.host_disconnect(&st.host,0,.Closed)
        wire.host_poll(&st.host)
        // The worker sends them before the host goes.
        time.sleep(4*COLLAB_WORKER_INTERVAL)
    }
    collab_destroy(s)
}

@(private)
collab_destroy :: proc(s:^Session) {
    c:=collab_of(s)
    st:=c.state
    if st==nil {return}
    delete(st.play_bytes)
    if st.mapping_on {wire.mapping_close(&st.mapping)}
    wire.host_destroy(&st.host)
    wire.udp_close(&st.udp)
    for &peer in st.peers {
        for message in peer.out[peer.head:] {delete(message)}
        delete(peer.out)
        delete(peer.file_bytes)
    }
    for path in st.files_out {delete(path)}
    delete(st.files_out)
    delete(st.snapshot)
    collab_tables_free(st)
    history.journal_reading(s.edits,false)
    for &tab in s.documents {history.journal_reading(&tab.edits,false)}
    free(st)
    c.state=nil
}

@(private)
collab_end :: proc(st:^Collab_State,reason:string) {
    st.phase=.Ended
    st.reason=reason
}

// The close of the editor.
@(private)
collab_close :: proc(s:^Session) {
    collab_leave(s)
    collab_destroy(s)
}

// The code others join with, from anywhere: by the address the router mapped, or the one of the
// adapter. None until the router answered: the code is of the address it opens.
@(private)
collab_codes_update :: proc(st:^Collab_State) {
    if st.mapping_on && wire.mapping_poll(&st.mapping).phase==.Pending {return}
    code:=wire.invite_encode(wire.address_reachable(&st.mapping,st.mapping_on,st.port),st.invite,context.temp_allocator)
    if code!=string(st.code[:st.code_length]) {log.infof("invitation to the session: %s",code)}
    st.code_length=copy(st.code[:],code)
}

// ---------------------------------------------------------------- writing messages

@(private)
collab_begin :: proc(w:^serial.Writer,kind:Collab_Message,capacity:=256) {
    serial.writer_init(w,capacity,context.temp_allocator)
    serial.write_scalar(w,u8(kind))
}

// A reliable message for a peer, in order after the ones before it.
@(private)
collab_queue :: proc(peer:^Collab_Peer,bytes:[]u8) {
    copy_bytes,_:=make([]u8,len(bytes))
    copy(copy_bytes,bytes)
    append(&peer.out,copy_bytes)
}

@(private)
collab_flush :: proc(st:^Collab_State,peer:^Collab_Peer) {
    for peer.head<len(peer.out) {
        message:=peer.out[peer.head]
        if wire.message_send(&st.host,peer.connection,0,message)==.Full {break}
        delete(message)
        peer.head+=1
    }
    if peer.head>0 && peer.head==len(peer.out) {
        clear(&peer.out)
        peer.head=0
    }
}

// Sends to the host (a guest) or to every peer that has the scene or is getting it (the host).
@(private)
collab_broadcast :: proc(st:^Collab_State,bytes:[]u8,except:int=-1) {
    if st.role==.Guest {
        collab_queue(&st.peers[0],bytes)
        return
    }
    for &peer,i in st.peers {
        if i==0 || !peer.used || i==except {continue}
        collab_queue(&peer,bytes)
    }
}

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

// ---------------------------------------------------------------- the loop

// Called every frame between frames, after the editor: network, edits, presence.
@(private)
collab_update :: proc(s:^Session) {
    st:=collab_state(s)
    if st==nil || st.role==.None || st.phase==.Ended {return}
    now:=wire.host_time(&st.host)
    if st.role==.Host && st.mapping_on && int(now)%2==0 {collab_codes_update(st)}
    for command in wire.host_poll(&st.host) {
        collab_command(s,st,command,now)
        if st.phase==.Ended {return}
    }
    // The scene of the document was replaced: the host shares the new one.
    if st.epoch!=s.edits.epoch {
        st.epoch=s.edits.epoch
        if st.role==.Host {
            collab_journal_reset(s,st)
            for &peer,i in st.peers {
                if i!=0 && peer.used && peer.joined {collab_snapshot_send(s,st,&peer)}
            }
        } else if st.phase==.Joined && !collab_snapshot_loading(st) {
            collab_end(st,"the scene was replaced")
            return
        }
    }
    if st.phase==.Joined && now-st.edit_at>=COLLAB_EDIT_INTERVAL {
        st.edit_at=now
        collab_edits_send(s,st)
        collab_files_send(s,st)
    }
    if st.phase==.Joined && now-st.presence_at>=COLLAB_PRESENCE_INTERVAL {
        st.presence_at=now
        collab_presence_send(s,st)
        collab_agents_send(s,st,now)
    }
    if st.role==.Guest && st.phase==.Connecting && now-st.peers[0].connected_at>COLLAB_HELLO_TIMEOUT {
        collab_end(st,"the host did not answer")
        return
    }
    for &peer in st.peers {
        if peer.used && peer.connection!=0 || st.role==.Guest {collab_flush(st,&peer)}
    }
}

@(private)
collab_snapshot_loading :: proc(st:^Collab_State) -> bool {return st.snapshot_total>0}

@(private)
collab_command :: proc(s:^Session,st:^Collab_State,command:wire.Command,now:f64) {
    switch command.kind {
    case .Connected:
        if st.role==.Guest {
            st.phase=.Syncing
            st.peers[0].used=true
            st.peers[0].connection=command.connection
            c:=collab_of(s)
            w:serial.Writer
            collab_begin(&w,.Hello)
            serial.write_scalar(&w,st.layout)
            serial.write_string(&w,string(c.name[:c.name_length]))
            serial.write_scalar(&w,collab_client(c))
            collab_queue(&st.peers[0],serial.writer_bytes(&w))
        } else {
            slot:=-1
            for &peer,i in st.peers {
                if i>0 && !peer.used {slot=i;break}
            }
            if slot<0 {
                wire.host_disconnect(&st.host,command.connection,.Denied_Full)
                return
            }
            st.peers[slot]={used=true,connection=command.connection,connected_at=now}
        }
    case .Disconnected:
        if st.role==.Guest {
            reason:="the host left"
            #partial switch command.reason {
            case .Denied_Version: reason="the host has another version of the project"
            case .Denied_Full:    reason="the session is full"
            case .Timeout:        reason="the host stopped answering"
            case .Reliable_Overflow: reason="the connection could not keep up with what the session sends"
            case .Connect_Timeout: reason="the host did not answer: the invitation is not the one of the session, or the host is not reachable"
            }
            collab_end(st,reason)
            return
        }
        for &peer,i in st.peers {
            if i>0 && peer.used && peer.connection==command.connection {
                for message in peer.out[peer.head:] {delete(message)}
                delete(peer.out)
                delete(peer.file_bytes)
                peer={}
                collab_roster_send(st)
            }
        }
    case .Message:
        from:=-1
        if st.role==.Host {
            for &peer,i in st.peers {
                if i>0 && peer.used && peer.connection==command.connection {from=i;break}
            }
            if from<0 {return}
        }
        collab_receive(s,st,from,command.data,now)
    case .Object_Created,.Object_Updated,.Object_Destroyed,.Role_Changed,.Event,.Input,.Authority_Requested,.Authority_Changed:
    }
}

@(private)
collab_receive :: proc(s:^Session,st:^Collab_State,from:int,data:[]u8,now:f64) {
    if len(data)==0 {return}
    r:=serial.reader_init(data)
    kind:=Collab_Message(serial.read_u8(&r))
    switch kind {
    case .Hello:
        if st.role!=.Host || from<0 {return}
        layout:=serial.read_u32(&r)
        name:=serial.read_string(&r)
        client:=serial.read_u64(&r)
        if r.failed {return}
        if layout!=st.layout {
            wire.host_disconnect(&st.host,st.peers[from].connection,.Denied_Version)
            return
        }
        // An editor that joins again takes its place back, with its color:
        // the connection it left behind goes, and with it what it selected.
        from:=from
        for &other,i in st.peers {
            if i==0 || i==from || !other.used || other.client!=client || client==0 {continue}
            wire.host_disconnect(&st.host,other.connection,.Replaced)
            for message in other.out[other.head:] {delete(message)}
            delete(other.out)
            delete(other.file_bytes)
            other=st.peers[from]
            st.peers[from]={}
            from=i
            break
        }
        peer:=&st.peers[from]
        peer.client=client
        peer.name_length=copy(peer.name[:COLLAB_NAME_BYTES-1],name)
        w:serial.Writer
        collab_begin(&w,.Welcome)
        serial.write_scalar(&w,u8(from))
        collab_queue(peer,serial.writer_bytes(&w))
        collab_snapshot_send(s,st,peer)
        collab_files_join(s,st,peer)
    case .Welcome:
        if st.role!=.Guest {return}
        id:=serial.read_u8(&r)
        if !r.failed {st.self=id}
    case .Snapshot:
        if st.role!=.Guest {return}
        if _,complete:=collab_chunk_take(&r,&st.snapshot,&st.snapshot_total);complete {
            loaded:=collab_snapshot_load(s,st,st.snapshot[:])
            clear(&st.snapshot)
            if !loaded {
                collab_end(st,"the scene of the host could not be opened")
                return
            }
            st.phase=.Joined
            ready:=[1]u8{u8(Collab_Message.Ready)}
            collab_queue(&st.peers[0],ready[:])
        }
    case .Ready:
        if st.role!=.Host || from<0 {return}
        st.peers[from].joined=true
        collab_roster_send(st)
    case .Edit:
        if st.role==.Host && (from<0 || !st.peers[from].joined) {return}
        if st.role==.Guest && st.phase!=.Joined {return}
        own:=st.role==.Guest && len(data)>1 && data[1]==st.self
        if own {st.echoed_edits+=1}
        // What this end edited goes before what it applies, so the edits of the others are not taken for its own.
        collab_edits_send(s,st)
        collab_edit_apply(s,st,data,own)
        // The host sends what a guest edited to everybody, the sender included.
        if st.role==.Host {
            for &peer,i in st.peers {
                if i!=0 && peer.used {collab_queue(&peer,data)}
            }
        }
        st.received_edits+=1
    case .Presence:
        id:=int(serial.read_u8(&r))
        orbit:Orbit
        orbit.target.x=serial.read_f32(&r);orbit.target.y=serial.read_f32(&r);orbit.target.z=serial.read_f32(&r)
        orbit.yaw=serial.read_f32(&r);orbit.pitch=serial.read_f32(&r);orbit.distance=serial.read_f32(&r)
        count:=int(serial.read_u8(&r))
        if r.failed || id>=COLLAB_PEERS || id==int(st.self) || count>COLLAB_SELECTION {return}
        if st.role==.Host && id!=from {return}
        peer:=&st.peers[id]
        orbit_sanitize(&orbit)
        peer.orbit,peer.has_pose,peer.seen=orbit,true,now
        peer.selection_count=0
        for _ in 0..<count {
            value:=base.Entity_Id(serial.read_u64(&r))
            if r.failed {break}
            peer.selection[peer.selection_count]=value
            peer.selection_count+=1
        }
        state:=serial.read_u8(&r)
        peer.playing=!r.failed && state&COLLAB_PLAYING!=0
        peer.serving=!r.failed && state&COLLAB_SERVING!=0
        peer.in_game=!r.failed && state&COLLAB_JOINED!=0
        peer.offer_size=0
        if peer.serving {
            size:=int(serial.read_u8(&r))
            for i in 0..<min(size,COLLAB_OFFER_BYTES) {peer.offer[i]=serial.read_u8(&r)}
            peer.offer_size=min(size,COLLAB_OFFER_BYTES)
            peer.serving=!r.failed && size<=COLLAB_OFFER_BYTES
        }
        if st.role==.Host {
            for &other,i in st.peers {
                if i!=0 && i!=from && other.used && other.joined {wire.message_send(&st.host,other.connection,1,data)}
            }
        }
    case .Roster:
        if st.role!=.Guest {return}
        count:=int(serial.read_u8(&r))
        for i in 1..<COLLAB_PEERS {
            st.peers[i].used=false
            // Who is not on the list selects nothing any more.
            st.peers[i].has_pose,st.peers[i].selection_count,st.peers[i].agents.count=false,0,0
        }
        st.peers[0].used=true
        for _ in 0..<count {
            id:=int(serial.read_u8(&r))
            name:=serial.read_string(&r)
            if r.failed || id>=COLLAB_PEERS {break}
            peer:=&st.peers[id]
            peer.used,peer.joined=true,true
            peer.name_length=copy(peer.name[:COLLAB_NAME_BYTES-1],name)
        }
        collab_unsent_prune(st)
    case .Reject:
        if st.role==.Guest {collab_end(st,"the host ended the session");return}
        // A guest that leaves frees its place now, and what it selected with it.
        if from>0 && st.peers[from].used {
            peer:=&st.peers[from]
            wire.host_disconnect(&st.host,peer.connection,.Closed)
            for message in peer.out[peer.head:] {delete(message)}
            delete(peer.out)
            delete(peer.file_bytes)
            peer^={}
            collab_roster_send(st)
        }
    case .Play_Mark:
        if st.role!=.Guest {return}
        game:=serial.read_u32(&r)
        if !r.failed {collab_play_copy(s,st,game)}
    case .Play_Scene_Request:
        if st.role!=.Host || from<0 {return}
        game:=serial.read_u32(&r)
        if !r.failed {collab_play_scene_send(s,st,&st.peers[from],game)}
    case .Play_Scene:
        if st.role==.Guest {collab_play_scene_take(s,st,&r)}
    case .Agents:
        if st.phase==.Joined && (st.role==.Guest || from>=0 && st.peers[from].joined) {collab_agents_receive(st,from,data)}
    case .Ping:
        if st.phase==.Joined && (st.role==.Guest || from>=0 && st.peers[from].joined) {collab_ping_receive(s,st,from,data)}
    case .File:
        if st.phase==.Joined && (st.role==.Guest || from>=0 && st.peers[from].joined) {collab_file_receive(s,st,from,&r)}
    case .File_Unsent:
        if st.phase==.Joined && (st.role==.Guest || from>=0 && st.peers[from].joined) {collab_unsent_receive(s,st,from,&r)}
    }
}

@(private)
collab_roster_send :: proc(st:^Collab_State) {
    if st.role!=.Host {return}
    collab_unsent_prune(st)
    w:serial.Writer
    collab_begin(&w,.Roster)
    count:=0
    for &peer,i in st.peers {
        if peer.used && (i==0 || peer.joined) {count+=1}
    }
    serial.write_scalar(&w,u8(count))
    for &peer,i in st.peers {
        if !(peer.used && (i==0 || peer.joined)) {continue}
        serial.write_scalar(&w,u8(i))
        serial.write_string(&w,string(peer.name[:peer.name_length]))
    }
    for &peer,i in st.peers {
        if i!=0 && peer.used {collab_queue(&peer,serial.writer_bytes(&w))}
    }
}

// ---------------------------------------------------------------- the scene

@(private)
collab_snapshot_send :: proc(s:^Session,st:^Collab_State,peer:^Collab_Peer) {
    a:=s.app.assets
    w:=edited_world(s)
    core.world_settle(w)
    d:=s.document
    cap:asset.Scene
    if _,error:=scene.capture(w,&cap,&a.types,{previous=d.previous,id=d.id});error!=.None {return}
    defer asset.scene_destroy(&cap)
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    if asset.scene_write(&cap,&out)!=.None {return}
    collab_chunks_queue(peer,.Snapshot,serial.writer_bytes(&out))
}

// Replaces the World by the scene of the host, all of it or nothing.
@(private)
collab_snapshot_load :: proc(s:^Session,st:^Collab_State,data:[]u8) -> bool {
    a:=s.app.assets
    source:asset.Asset
    if asset.asset_open(&source,data)!=.None {return false}
    defer asset.asset_close(&source)
    view,view_error:=asset.scene_view(&source,&a.types)
    if view_error!=.None || asset.scene_view_check(view,context.temp_allocator)!=.None {return false}
    runs_stop(s)
    tools_release(s)
    if _,error:=scene.replace(edited_world(s),s.app,&source,&a.types);error!=.None {return false}
    records:=new(asset.Scene)
    own:=make([]u8,len(data))
    copy(own,data)
    defer delete(own)
    d:=s.document
    document_previous_free(d)
    if asset.scene_read(records,&a.types,own)==.None {d.previous=records} else {free(records)}
    d.id={}
    document_name(d,"","")
    document_opened(s)
    st.epoch=s.edits.epoch
    collab_journal_reset(s,st)
    return true
}

// ---------------------------------------------------------------- differences

@(private)
collab_ops_begin :: proc(ops:^Collab_Ops) {
    serial.writer_init(&ops.head,0,context.temp_allocator)
    serial.writer_init(&ops.body,0,context.temp_allocator)
    serial.writer_init(&ops.tail,0,context.temp_allocator)
    ops.count=0
}

@(private)
collab_op_write :: proc(ops:^Collab_Ops,into:^serial.Writer,kind:Collab_Op,hash:u64,id:base.Entity_Id,bytes:[]u8) {
    if ops==nil {return}
    serial.write_scalar(into,u8(kind))
    serial.write_scalar(into,hash)
    serial.write_scalar(into,u64(id))
    serial.write_scalar(into,u16(len(bytes)))
    serial.write_bytes(into,bytes)
    ops.count+=1
}

// The bytes of a row as they travel: transient bytes zero, Entity fields as Ids.
@(private)
collab_normalize :: proc(w:core.World_Ref,t:^Collab_Table,value:rawptr,out:[]u8) {
    if t.size>0 {mem.copy(raw_data(out),value,t.size)}
    for range in t.transient {
        if range[1]>0 {mem.zero(&out[range[0]],range[1])}
    }
    for offset in t.entities {
        field:=cast(^u64)&out[offset]
        field^=u64(api_entity_id(w,core.Entity(field^)))
    }
}

// The fields of a row that differ from what it was, as the runs of a Fields
// operation out of its bytes as they travel; fields that touch are one run.
@(private)
collab_fields_write :: proc(t:^Collab_Table,before:[]u8,value:rawptr,travels:[]u8,into:^serial.Writer) {
    start,end:=0,0
    for field in t.fields {
        if mem.compare_ptrs(&before[field[0]],rawptr(uintptr(value)+uintptr(field[0])),field[1])==0 {continue}
        if end>start && field[0]==end {
            end+=field[1]
            continue
        }
        collab_run_write(travels,start,end,into)
        start,end=field[0],field[0]+field[1]
    }
    collab_run_write(travels,start,end,into)
}

@(private)
collab_run_write :: proc(travels:[]u8,start,end:int,into:^serial.Writer) {
    if end<=start {return}
    serial.write_scalar(into,u16(start))
    serial.write_scalar(into,u16(end-start))
    serial.write_bytes(into,travels[start:end])
}

// The others have the World as it is: what changes from now on is what they are told.
@(private)
collab_journal_reset :: proc(s:^Session,st:^Collab_State) {
    st.cursor=history.journal_reading(s.edits,true)
    clear(&st.told)
    clear(&st.told_values)
    clear(&st.crossed)
}

// A row as the others have it: what they were told of it last.
@(private)
Collab_Before :: struct {
    id:base.Entity_Id,
    present,off:bool,
    value:[]u8, // its bytes then; nil when they were not kept
}

// What changed since the others were told, as messages for them: the rows
// the journal took since this end read it, the rows the World and the
// journal disagree on (edits not committed yet), and those the others were
// told of while they disagreed, each as it is now against what the others
// have of it: the journal kept what it held before it took it, and this end
// what it told of a row not committed yet. Of a row the others have, the
// fields that differ go; of one they do not, all of it. A row turns when its
// off state is not the one the others have.
@(private)
collab_edits_send :: proc(s:^Session,st:^Collab_State) {
    w:=edited_world(s)
    edits:=s.edits
    if w.data!=edits.world || core.world_table_of(w,core.Id)==nil {return}
    core.world_settle(w)
    if !history.journal_ranges(edits,w) {return}
    edits.reading=true
    keys:=make(map[Collab_Key]Collab_Before,context.temp_allocator)
    told:=slice.clone(st.told_values[:],context.temp_allocator)
    for key,was in st.told {
        before:=Collab_Before{id=was.id,present=was.present,off=was.off}
        if size:=st.tables[key.table].size;was.present && was.value+size<=len(told) {before.value=told[was.value:][:size]}
        keys[key]=before
    }
    for change in history.journal_read(edits,&st.cursor) {
        key:=Collab_Key{change.table,change.entity}
        if key in keys {continue}
        before:=Collab_Before{id=change.id,present=change.present,off=change.off}
        if value,kept:=history.journal_change_value(edits,change,st.tables[change.table].size);kept {before.value=value}
        keys[key]=before
    }
    clear(&st.told)
    clear(&st.told_values)
    authors,only_authors:=history.history_authors(edits,w)
    id_table:=history.journal_id_table(w)
    for &info,i in w.info.tables {
        if !st.tables[i].used || i>=len(edits.image) {continue}
        table:=core.world_table_at(w,&info)
        image:=&edits.image[i]
        if !history.journal_moved(table,image) {continue}
        size:=info.info.size
        d:=history.journal_diff(table,image,size,edits.ranges[i].ranges,authors,only_authors && i!=id_table)
        for r in history.journal_diff_next(&d) {
            key:=Collab_Key{i32(i),r.entity}
            if key not_in keys {
                before:=Collab_Before{id=history.journal_id(edits,w,id_table,r.entity),present=r.image_row>=0,off=r.image_row>=0 && image.off[r.image_row]}
                if before.present {before.value=([^]u8)(history.journal_value(image,size,r.image_row))[:size]}
                keys[key]=before
            }
            st.told[key]={}
        }
    }
    present:=make(map[Collab_Row]bool,len(keys),context.temp_allocator)
    for key,before in keys {
        id:=history.journal_id(edits,w,id_table,key.entity)
        if id==0 {id=before.id}
        if core.raw_row(core.world_table_at(w,&w.info.tables[key.table]),key.entity)>=0 {present[{key.table,id}]=true}
    }
    ops:Collab_Ops
    collab_ops_begin(&ops)
    for key,before in keys {
        info:=&w.info.tables[key.table]
        t:=&st.tables[key.table]
        table:=core.world_table_at(w,info)
        id:=history.journal_id(edits,w,id_table,key.entity)
        if id==0 {id=before.id}
        if id==0 {continue}
        is_ids:=info.type==core.Id
        row:=core.raw_row(table,key.entity)
        now:=Collab_Told{id=id,present=row>=0,off=row>=0 && table.off[row]}
        if row>=0 {
            value:=core.raw_value(table,info.info,row)
            current:=make([]u8,max(t.size,1),context.temp_allocator)
            collab_normalize(w,t,value,current)
            if is_ids || !before.present || len(before.value)!=t.size || t.size>int(max(u16)) {
                collab_op_write(&ops,is_ids?&ops.head:&ops.body,.Set,t.hash,id,current[:t.size])
            } else {
                runs:serial.Writer
                serial.writer_init(&runs,0,context.temp_allocator)
                collab_fields_write(t,before.value,value,current,&runs)
                if changed:=serial.writer_bytes(&runs);len(changed)>0 {collab_op_write(&ops,&ops.body,.Fields,t.hash,id,changed)}
            }
            if now.off!=(before.present && before.off) {
                turn:=[1]u8{u8(now.off)}
                collab_op_write(&ops,&ops.body,.Turn,t.hash,id,turn[:])
            }
            if key in st.told {
                now.value=len(st.told_values)
                append(&st.told_values,..([^]u8)(value)[:t.size])
            }
        } else if before.present && !present[{key.table,id}] {
            collab_op_write(&ops,is_ids?&ops.tail:&ops.body,.Remove,t.hash,id,nil)
        }
        if key in st.told {st.told[key]=now}
    }
    history.journal_read_done(edits,st.cursor)
    if ops.count==0 {return}
    if st.role==.Host {s.document.unsaved=true}
    for message in collab_ops_pack(&ops,.Edit,st.self) {
        collab_broadcast(st,message)
        st.sent_edits+=1
    }
    st.sent_ops+=u64(ops.count)
}

// Whether this end has edits the others were not told of.
@(private)
collab_unsent :: proc(s:^Session,st:^Collab_State) -> bool {
    edits:=s.edits
    w:=edited_world(s)
    return len(st.told)>0 || edits.changes_first+u64(len(edits.changes))!=st.cursor || !history.journal_settled(edits,w)
}

@(private)
intrinsic_u16 :: proc(bytes:[]u8) -> u16 {return u16(bytes[0])|u16(bytes[1])<<8}

// What an operation of another end wrote of a row: all of it, a run of its
// bytes, or whether it is turned off.
@(private)
Collab_Touch :: struct {
    table:int,
    entity:core.Entity,
    id:base.Entity_Id,
    kind:Collab_Op,
    offset,size:int, // Fields: the run
}

// Writes a run of bytes as they travel into a row: its Entity fields become
// the entities of this World and its transient bytes stay. False when the
// run is not of the row or cuts an Entity field.
@(private)
collab_run_put :: proc(es:^core.Entities,t:^Collab_Table,row:rawptr,offset:int,bytes:[]u8) -> bool {
    end:=offset+len(bytes)
    if end>t.size {return false}
    for at in t.entities {
        if int(at)<end && int(at)+size_of(core.Entity)>offset && (int(at)<offset || int(at)+size_of(core.Entity)>end) {return false}
    }
    value:=make([]u8,max(len(bytes),1),context.temp_allocator)
    copy(value,bytes)
    for at in t.entities {
        if int(at)<offset || int(at)>=end {continue}
        field:=cast(^u64)&value[int(at)-offset]
        field^=u64(core.entity_of(es,base.Entity_Id(field^)))
    }
    for range in t.transient {
        from,to:=max(range[0],offset),min(range[0]+range[1],end)
        if to>from {mem.copy(&value[from-offset],rawptr(uintptr(row)+uintptr(from)),to-from)}
    }
    if len(bytes)>0 {mem.copy(rawptr(uintptr(row)+uintptr(offset)),raw_data(value),len(bytes))}
    return true
}

// Whether this end has an edit of its own in a run of a row: its World and
// its journal disagree there.
@(private)
collab_run_edited :: proc(edits:^history.Edits,w:core.World_Ref,table:int,e:core.Entity,row:rawptr,offset,size,width:int) -> bool {
    if w.data!=edits.world || table>=len(edits.image) || offset+size>width {return false}
    image:=&edits.image[table]
    image_row:=history.journal_row(image,e)
    if image_row<0 {return true}
    return mem.compare_ptrs(rawptr(uintptr(row)+uintptr(offset)),rawptr(uintptr(history.journal_value(image,width,image_row))+uintptr(offset)),size)!=0
}

// Applies the operations of an Edit message to the World, without a step of
// undo: a Fields writes its runs and leaves the rest of the row as it is here.
// own: a message of this end, back from the host. This end has what it says
// or something newer, except in the rows another end wrote while it was on
// its way: there the host put it after theirs, so it is written again, but
// for the runs this end is editing now.
@(private)
collab_edit_apply :: proc(s:^Session,st:^Collab_State,data:[]u8,own:=false) {
    r:=serial.reader_init(data)
    serial.read_u8(&r)
    serial.read_u8(&r)
    count:=int(serial.read_u16(&r))
    w:=edited_world(s)
    es:=core.world_entities(w)
    touched:=make([dynamic]Collab_Touch,context.temp_allocator)
    // The sets of Id come first: the entities they make are found by Id once they settle.
    created:=false
    for _ in 0..<count {
        kind:=Collab_Op(serial.read_u8(&r))
        hash:=serial.read_u64(&r)
        id:=base.Entity_Id(serial.read_u64(&r))
        size:=int(serial.read_u16(&r))
        bytes:=serial.read_bytes(&r,size)
        if r.failed {break}
        i,known:=st.by_hash[hash]
        if !known || id==0 {continue}
        info:=&s.info.tables[i]
        t:=&st.tables[i]
        table:=core.world_table_at(w,info)
        if created && (kind!=.Set || info.type!=core.Id) {
            core.world_settle(w)
            created=false
        }
        e:=core.entity_of(es,id)
        if e!=core.NONE {
            key:=Collab_Key{i32(i),e}
            if own && key not_in st.crossed {continue}
            if !own && st.role==.Guest && st.sent_edits!=st.echoed_edits {st.crossed[key]={}}
        }
        switch kind {
        case .Set:
            if size!=t.size {continue}
            if info.type==core.Id {
                if e==core.NONE {
                    e=core.create(es)
                    created=true
                    core.raw_add(table,info.info,e,raw_data(bytes))
                    append(&touched,Collab_Touch{table=i,entity=e,id=id,kind=.Set})
                }
                continue
            }
            if e==core.NONE {continue}
            value:=make([]u8,max(size,1),context.temp_allocator)
            if current:=core.raw_find(table,info.info,e);current!=nil && size>0 {mem.copy(raw_data(value),current,size)}
            if !collab_run_put(es,t,raw_data(value),0,bytes) {continue}
            core.raw_add(table,info.info,e,raw_data(value))
            append(&touched,Collab_Touch{table=i,entity=e,id=id,kind=.Set})
        case .Fields:
            if e==core.NONE || info.type==core.Id {continue}
            row:=core.raw_staged(table,info.info,e)
            if row==nil {continue}
            runs:=serial.reader_init(bytes)
            for serial.reader_remaining(&runs)>0 {
                offset:=int(serial.read_u16(&runs))
                run:=serial.read_bytes(&runs,int(serial.read_u16(&runs)))
                if runs.failed {break}
                if own && collab_run_edited(s.edits,w,i,e,row,offset,len(run),t.size) {continue}
                if !collab_run_put(es,t,row,offset,run) {break}
                append(&touched,Collab_Touch{table=i,entity=e,id=id,kind=.Fields,offset=offset,size=len(run)})
            }
        case .Remove:
            if e==core.NONE {continue}
            if info.type==core.Id {
                core.destroy(es,e)
            } else {
                core.raw_remove(table,e)
            }
            append(&touched,Collab_Touch{table=i,entity=e,id=id,kind=.Remove})
        case .Turn:
            if e==core.NONE || size!=1 || info.type==core.Id {continue}
            if bytes[0]!=0 {core.raw_disable(table,e)} else {core.raw_enable(table,e)}
            append(&touched,Collab_Touch{table=i,entity=e,id=id,kind=.Turn})
        }
        st.received_ops+=1
    }
    core.world_settle(w)
    if st.sent_edits==st.echoed_edits {clear(&st.crossed)}
    // What was applied is what both ends agree on, and not an edit of this one:
    // the journal takes it without a step, and the others were told it. Of a
    // row this end is editing it takes those bytes alone: the rest is still
    // an edit of this end.
    edits:=s.edits
    if w.data==edits.world {
        id_table:=history.journal_id_table(w)
        for touch in touched {
            switch {
            case touch.table==id_table:
                for i in 0..<len(edits.image) {history.journal_take(edits,w,i,touch.entity)}
                history.journal_take_entity(edits,w,touch.entity)
            case touch.kind==.Fields: history.journal_take_field(edits,w,touch.table,touch.entity,touch.offset,touch.size)
            case touch.kind==.Turn:   history.journal_take_off(edits,w,touch.table,touch.entity)
            case:                     history.journal_take(edits,w,touch.table,touch.entity)
            }
            collab_told_take(st,w,touch)
        }
    }
    // What the others changed is no step of this history: the overrides derived before it are of before it.
    if s.editor_world!=nil && len(touched)>0 {prefabs_changed(s)}
    history.selection_prune(s.selection,w)
    if st.role==.Host {s.document.unsaved=true}
}

// What the others were told of a row this end is editing takes what another
// end wrote of it.
@(private)
collab_told_take :: proc(st:^Collab_State,w:core.World_Ref,touch:Collab_Touch) {
    key:=Collab_Key{i32(touch.table),touch.entity}
    told,telling:=&st.told[key]
    if !telling {return}
    info:=&w.info.tables[touch.table]
    table:=core.world_table_at(w,info)
    size:=info.info.size
    row:=core.raw_row(table,touch.entity)
    had:=told.present
    told.id,told.present,told.off=touch.id,row>=0,row>=0 && table.off[row]
    if row<0 {return}
    value:=([^]u8)(core.raw_value(table,info.info,row))
    switch {
    case !had:
        told.value=len(st.told_values)
        append(&st.told_values,..value[:size])
    case touch.kind==.Fields:
        copy(st.told_values[told.value+touch.offset:][:touch.size],value[touch.offset:][:touch.size])
    case touch.kind==.Set:
        copy(st.told_values[told.value:][:size],value[:size])
    case touch.kind==.Remove,touch.kind==.Turn:
    }
}

// ---------------------------------------------------------------- presence

@(private)
collab_presence_send :: proc(s:^Session,st:^Collab_State) {
    w:serial.Writer
    collab_begin(&w,.Presence,256)
    serial.write_scalar(&w,st.self)
    orbit:=s.viewport.orbit
    serial.write_scalar(&w,orbit.target.x);serial.write_scalar(&w,orbit.target.y);serial.write_scalar(&w,orbit.target.z)
    serial.write_scalar(&w,orbit.yaw);serial.write_scalar(&w,orbit.pitch);serial.write_scalar(&w,orbit.distance)
    world:=edited_world(s)
    ids:[COLLAB_SELECTION]base.Entity_Id
    count:=0
    for e in s.selection.entities {
        if count>=COLLAB_SELECTION || s.mode!=.Edit {break}
        if id:=api_entity_id(world,e);id!=0 {
            ids[count]=id
            count+=1
        }
    }
    serial.write_scalar(&w,u8(count))
    for id in ids[:count] {serial.write_scalar(&w,u64(id))}
    // Playing is part of the presence: a camera that stops moving because its
    // editor is inside a game does not look like one that was left alone. A
    // game a plugin serves says how guests join it.
    state:=u8(0)
    if run_find(s,0)!=nil {state|=COLLAB_PLAYING}
    offer:[COLLAB_OFFER_BYTES]u8
    offered:=collab_offer(s,offer[:])
    if offered>0 {state|=COLLAB_SERVING}
    if collab_in_game(s) {state|=COLLAB_JOINED}
    serial.write_scalar(&w,state)
    if offered>0 {
        serial.write_scalar(&w,u8(offered))
        for b in offer[:offered] {serial.write_scalar(&w,b)}
    }
    bytes:=serial.writer_bytes(&w)
    if st.role==.Guest {
        wire.message_send(&st.host,0,1,bytes)
        return
    }
    for &peer,i in st.peers {
        if i!=0 && peer.used && peer.joined {wire.message_send(&st.host,peer.connection,1,bytes)}
    }
}

collab_color :: proc "contextless" (id:int) -> ui.Color {return agent_color(id)}

// This guest plays the game the host serves, with a player of a plugin.
collab_in_game :: proc(s:^Session) -> bool {
    p:=providers(s)
    return p.plays && p.play.joined!=nil && p.play.joined(s)
}

// The others as the figure of the agents, its eyes where their camera is and
// turned to where it looks, under their initial and their name; what they
// select is outlined (collab_highlights). Whoever is playing has a ring under
// it and no selection.
collab_draw :: proc(s:^Session) {
    st:=collab_state(s)
    if st==nil || st.role==.None || st.phase!=.Joined || !presence_in_scene(s) {return}
    now:=wire.host_time(&st.host)
    lines:=&s.viewport.lines
    w:=edited_world(s)
    _,low,high,loaded:=presence_mesh(s.app.assets)
    presence_style(s)
    for &peer,i in st.peers {
        if i==int(st.self) || !peer.used || !peer.has_pose || now-peer.seen>COLLAB_PRESENCE_SEEN {continue}
        color:=collab_color(i)
        rgba:=[4]f32{f32(color[0])/255,f32(color[1])/255,f32(color[2])/255,1}
        eyes:=orbit_position(peer.orbit)
        forward,_,_:=orbit_basis(peer.orbit)
        yaw:=presence_yaw(forward)
        name:=string(peer.name[:peer.name_length])
        if loaded {
            if presence_prepare(s,&st.figures[i],eyes,yaw,color,agent_level(i),u64(COLLAB_PEERS+i)) {host.extras_instance_add(&s.app.extras,st.figures[i].instance)}
            if rect,shown:=presence_glyph_rect(s,presence_shown(&st.figures[i],eyes)+{0,high.y,0},s.viewport.view_projection);shown {
                presence_initial_draw(s,rect,name,color)
                presence_name_draw(s,rect,name,color)
            }
        }
        if (peer.playing || peer.in_game) && loaded {
            // In the game of the host the ring takes its color: where it plays.
            if peer.in_game {
                host:=collab_color(0)
                rgba.xyz={f32(host[0])/255,f32(host[1])/255,f32(host[2])/255}
            }
            rotation:=mm.quat_axis_angle({0,1,0},yaw)
            center:=eyes+mm.quat_rotate(rotation,[3]f32{(low.x+high.x)*0.5,low.y,(low.z+high.z)*0.5})
            gpu.debug_circle(lines,center,{0,1,0},max(high.x-low.x,high.z-low.z)*0.6,{rgba.x,rgba.y,rgba.z,0.65},32)
        }
    }
    collab_agents_draw(s,st,now)
    host.assets_commit(s.app.assets)
}


// Another editor that is in the session now and edits the document.
@(private)
collab_peer_live :: proc(st:^Collab_State,i:int,now:f64) -> bool {
    peer:=&st.peers[i]
    return i!=int(st.self) && peer.used && peer.has_pose && !peer.playing && now-peer.seen<=COLLAB_PRESENCE_SEEN
}

// The selections of the others, outlined in their colors: who works on what.
// It holds nothing: what another editor selected is edited like the rest.
@(private)
collab_highlights :: proc(s:^Session,w:core.World_Ref,levels:[]u8) {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined || w.data!=s.edit_world || s.mode!=.Edit {return}
    es:=core.world_entities(w)
    now:=wire.host_time(&st.host)
    for &peer,i in st.peers {
        if !collab_peer_live(st,i,now) {continue}
        for id in peer.selection[:peer.selection_count] {
            e:=api_entity(w,id)
            if e==core.NONE || !core.alive(es,e) {continue}
            // Their color shows over the selection of this end too: both work on it.
            if at:=core.entity_index(e);at<len(levels) && (levels[at]==0 || levels[at]==HIGHLIGHT_SELECTED || levels[at]==HIGHLIGHT_DESCENDANT) {levels[at]=agent_level(i)}
        }
    }
    collab_agents_highlights(s,st,w,levels,now)
}

// What the outlines of the others depend on: who is in and what they select.
@(private)
collab_highlights_key :: proc(s:^Session) -> u64 {
    st:=collab_state(s)
    if st==nil || st.phase!=.Joined {return 0}
    now:=wire.host_time(&st.host)
    key:=u64(1)
    for &peer,i in st.peers {
        if !collab_peer_live(st,i,now) {continue}
        key=base.hash_combine(key,u64(i+1))
        for id in peer.selection[:peer.selection_count] {key=base.hash_combine(key,u64(id))}
    }
    return base.hash_combine(key,collab_agents_key(s,st,now))
}
