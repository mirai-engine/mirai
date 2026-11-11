package mirai_net

import "base:runtime"
import "core:crypto"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:std/base"

// A host is one end of the network: a server that accepts connections or a
// client with one connection to a server. It has two halves that only meet
// through two flat queues, so the second can run on its own thread:
//
//   simulation half   what the game calls. Every call appends an operation
//                     to the frame being staged; host_publish closes the
//                     frame of a tick and queues it.
//   network half      host_update, or the worker thread. Applies the queued
//                     frames, reads and writes datagrams and appends what it
//                     received to a command buffer that host_poll hands back.
//
// The network half never reads memory of the simulation: a frame carries
// copies. A Host must stay where it was initialized.

Connection :: distinct base.Handle

Mode :: enum u8 {Server,Client}

Error :: enum u8 {
    None,
    Invalid,       // bad argument, stale handle or wrong mode
    Full,          // a preallocated capacity is exhausted
    Too_Large,
    Out_Of_Memory, // only from init procedures
}

// Why host_init refused a Host_Desc: the field, as its path in Host_Desc, and the values it takes.
Refusal :: struct {field,range:string}

@(private)
refuse :: proc(h:^Host,field,range:string) -> Error {
    h.refused={field,range}
    return .Invalid
}

Disconnect_Reason :: enum u8 {
    None,
    Closed,            // either side asked for it
    Timeout,
    Connect_Timeout,   // also what a wrong invitation ends in: it gets no answer
    Denied_Full,
    Denied_Version,
    Denied_Protocol,   // the two ends registered different object types, events or channels
    Protocol_Error,    // the other end sent something that cannot be parsed
    Reliable_Overflow, // a reliable channel had no room left for a message
    Capacity,          // this end ran out of room for what the other end sent
    Kicked,
    Denied_Security,      // the server answered with keys that leave nothing secret or that it could not have made
    Replaced,             // another connection of the same player took its place
    Scene_Missing,        // the client does not have the scene the server is in
    Denied_Player,        // the client presented no player, or a second one
}

Host_Desc :: struct {
    mode:Mode,
    transport:Transport,
    protocol:^Protocol,       // object types, events and input; nil for connections and channels alone
    protocol_id:u32,          // identity of the application: datagrams of any other are ignored
    version:u32,              // both ends must have the same
    seed:u64,                 // source of salts; 0 takes it from the system
    invite:u64,               // the invitation both ends must have; 0 at both: anyone who reaches the server joins. Every key of a connection depends on it (invite.odin)
    max_connections:int,      // server; default 32. A client has one
    channels:[]Channel_Desc,  // at most USER_CHANNELS
    tick_rate:int,            // Hz, default 60
    send_rate:int,            // bytes per second and connection at most, default 256 KiB
    min_send_rate:int,        // bytes per second below which congestion control does not go, default send_rate/16
    packets_per_update:int,   // datagrams per connection in one update, default 4
    timeout:f64,              // seconds of silence that close a connection, default 10
    connect_timeout:f64,      // default 5
    keepalive:f64,            // seconds, default 0.5
    frame_ops:int,            // operations of the simulation per frame, default 4096
    frame_bytes:int,          // their payload, default 256 KiB
    command_count:int,        // commands between two host_poll; by default 4096 or what the protocol needs
    command_bytes:int,        // their payload; by default 512 KiB or what the protocol needs
    handshakes_per_update:int, // server: key exchanges computed in one update, default 8
    replication:Replication_Desc,
    hold:bool,                // server: a connection that arrives is held (connection_hold) until it is let go
    allocator:runtime.Allocator,
}

Command_Kind :: enum u8 {
    Connected,          // tick: the ticks of history of the server (host_history)
    Disconnected,       // reason
    Message,            // channel, data
    Object_Created,     // object, type, role, simulation, tick, mask, words; retyped: of a replica this end has, which is of this type from now on
    Object_Updated,     // object, type, tick, mask, words; connection is the client that sent it, on a server
    Object_Destroyed,   // object
    Role_Changed,       // object, role
    Event,              // event, object, words; connection is the sender, on a server
    Input,              // tick, data: the input structure of a client, on a server
    Authority_Requested,// object, connection
    Authority_Changed,  // object, connection holding it now, zero when it went back to the server
}

// What the network half hands back. data and words point into the buffer of
// the poll that returned the command and die with the next host_poll.
Command :: struct {
    kind:Command_Kind,
    channel:u8,
    reason:Disconnect_Reason,
    role:Role,
    simulation:Simulation,
    type:Type_Id,
    event:Event_Id,
    tick:u32,
    connection:Connection,
    object:Object,
    ended:bool,   // Object_Destroyed: the object is gone on the server; false: it only left what this connection sees
    more:bool,    // Message: a piece of a reliable message whose next bytes come in the next Message of the channel
    retyped:bool, // Object_Created: the replica of this object goes on, with the type and the whole state of the command
    mask:u64,     // fields that changed, one bit each as numbered by the object type
    data:[]u8,
    words:[]u32,  // quantized state: object_read and event_read turn it into structures
}

Host_Stats :: struct {
    connections:int,
    packets_sent,packets_received:u64,
    bytes_sent,bytes_received:u64,
    packets_invalid:u64,     // wrong size, checksum or contents
    handshakes_refused:u64,  // answered with a denial, after the cookie and the proof of the client
    handshakes_dropped:u64,  // answered with nothing: a cookie that is not this host's or is old, or a proof that does not open
    handshakes_deferred:u64, // key exchanges put off: the update had computed its share, or the address presented wrong proofs too fast
    commands_dropped:u64,    // the command buffer was full
    receive_stalls:u64,      // updates that stopped reading because the command buffer had no reserve left
    operations_dropped:u64,  // the frame of the simulation was full
    publish_stalls:u64,      // frames that had to wait for the network half
    frames:u64,              // frames applied
    state_words_used:int,    // words in use of Replication_Desc.state_words and baseline_words, a word per block included
    baseline_words_used:int,
    state_failures:u64,      // objects left without a state for lack of state_words; object_create refuses them first on a server
    baseline_failures:u64,   // baselines not taken for lack of baseline_words: the update went against the one before, or whole
    update_seconds:f64,      // time of the last update of the network half, and of its parts:
    apply_seconds:f64,       // taking in the frames of the simulation
    receive_seconds:f64,     // reading datagrams
    scope_seconds:f64,       // deciding what each connection sees
    send_seconds:f64,        // choosing, packing and sending
}

@(private) FRAME_COUNT :: 4
@(private) USER_CHANNELS :: 6
@(private) MAX_CHANNELS :: 8

@(private)
Op_Kind :: enum u8 {
    Tick,Connect,Disconnect,Message,
    Object_Create,Object_Retype,Object_State,Object_Destroy,Object_Owner,Object_Priority,Object_Position,Object_Radius,Object_Filter,
    Object_Parent,Authority_Grant,Authority_Request,Authority_Release,View,Event,Input,Object_Visibility,Connection_Visibility,Hold,Clock,
    Object_Group,Connection_Group,
}
@(private)
Op :: struct {
    kind:Op_Kind,
    a:u8,
    b:u16,
    c,d:u32,
    handle:u64,
    value:u64,
    v:[4]f32,
    offset,size:u32,
}
@(private)
Connect_Request :: struct {candidates:[CANDIDATES]Address,count:int}
// Bytes of messages given to the game channels of one connection: 4 more than each one's data.
// streaming: bytes of the message message_send streams on each channel that it has not queued yet.
@(private)
Queued_Bytes :: struct {connection:Connection,bytes:[MAX_CHANNELS]u64,streaming:[MAX_CHANNELS]int}
@(private)
Frame :: struct {ops:[]Op,count:int,bytes:[]u8,used:int}
@(private)
Sync_Sample :: struct {valid:bool,server_tick:u32,margin:i32,has_margin:bool,rtt,jitter,time:f64,paused:bool,scale:f32}
@(private)
Command_Buffer :: struct {
    commands:[]Command,
    count:int,
    bytes:[]u8,
    used:int,
    released:[]u32, // object slots the server may hand out again
    released_count:int,
    sync:Sync_Sample,
}

Host :: struct {
    desc:Host_Desc,
    allocator:runtime.Allocator,
    channels:[MAX_CHANNELS]Channel_Desc,
    channel_count:int,
    start:time.Tick,
    failed:bool,
    refused:Refusal, // why host_init returned Invalid
    history:int,     // ticks of Replication_Desc.history_seconds at tick_rate

    // Simulation half.
    staging:^Frame,
    inbox:^Command_Buffer,
    front:Front,
    connection_stats:[]Connection_Stats,
    connection_handles:[]Connection,
    // What message_send and the reliable messages of the library queued for each connection and
    // for all of them, and how much of it the network half had applied at the last host_poll: the
    // rest is not yet in queue_free (system_free for the reliable channel of the library).
    sent:[]Queued_Bytes,
    sent_all:[MAX_CHANNELS]u64,
    applied:[][MAX_CHANNELS]u64,
    applied_all:[MAX_CHANNELS]u64,
    system_free:[]u32,
    stats:Host_Stats,
    operations_dropped,publish_stalls:u64,

    // Exchange, under lock.
    lock:sync.Mutex,
    queued:[FRAME_COUNT]^Frame,
    queued_count:int,
    spare:[FRAME_COUNT]^Frame,
    spare_count:int,
    ready:^Command_Buffer,
    ready_full:bool,
    shared_stats:Host_Stats,
    shared_connection_stats:[]Connection_Stats,
    shared_connection_handles:[]Connection,
    shared_applied:[][MAX_CHANNELS]u64,
    shared_applied_all:[MAX_CHANNELS]u64,
    shared_system_free:[]u32,
    shared_type_stats:[]Type_Stats,

    // Network half.
    back:Back,
    frames:[FRAME_COUNT]Frame,
    buffers:[3]Command_Buffer,
    worker:^thread.Thread,
    worker_stop:bool,
    worker_interval:time.Duration,
}

@(private)
Back :: struct {
    now:f64,
    outbox:^Command_Buffer,
    peers:[]Peer,
    by_address:base.Hash_Map(u32), // the slot of each peer that is not Free, by the address_key of its address
    key:u64,
    secret:[16]u8,
    secure:Host_Secure,
    attempt:Attempt, // client
    rng:u64,
    tick:u32,
    send_pending:bool,
    paused:bool,      // server: its clock, which goes with the tick to every client
    scale:f32,
    clock_due:bool,   // the clock changed: every connection hears it now
    applied_all:[MAX_CHANNELS]u64, // bytes of the messages for every connection taken from the frames
    reserve_bytes,reserve_count:int,
    incoming,outgoing,scratch:[PACKET_BYTES]u8,
    stats:Host_Stats,
    repl:Repl,
}

@(private)
host_make :: proc(h:^Host,$T:typeid,count:int) -> []T {
    result,error:=make([]T,count,h.allocator)
    if error!=nil {h.failed=true;return nil}
    return result
}

// Bytes that are also read as words.
@(private)
host_make_bytes :: proc(h:^Host,count:int) -> []u8 {
    result,error:=mem.make_aligned([]u8,count,16,h.allocator)
    if error!=nil {h.failed=true;return nil}
    return result
}

host_init :: proc(h:^Host,desc:Host_Desc) -> Error {
    h^={desc=desc}
    d:=&h.desc
    h.allocator=d.allocator.procedure==nil?context.allocator:d.allocator
    if d.transport.send==nil || d.transport.receive==nil {return refuse(h,"transport","a send and a receive procedure")}
    if len(d.channels)>USER_CHANNELS {return refuse(h,"channels","at most 6")}
    if d.mode==.Client {d.max_connections=1} else if d.max_connections<=0 {d.max_connections=32}
    if d.max_connections>MAX_CONNECTIONS {return refuse(h,"max_connections","at most 1024; 0 takes 32")}
    if d.tick_rate<=0 {d.tick_rate=60}
    if !(d.replication.history_seconds<=HISTORY_MAX_SECONDS) {return refuse(h,"replication.history_seconds","at most 2 seconds; 0 or less takes 0.5")}
    if d.replication.history_seconds<=0 {d.replication.history_seconds=HISTORY_SECONDS}
    h.history=history_ticks(d.replication.history_seconds,d.tick_rate)
    if d.send_rate<=0 {d.send_rate=256<<10}
    if d.min_send_rate<=0 {d.min_send_rate=max(d.send_rate/16,PACKET_BYTES*4)}
    if d.packets_per_update<=0 {d.packets_per_update=4}
    if d.timeout<=0 {d.timeout=10}
    if d.connect_timeout<=0 {d.connect_timeout=5}
    if d.keepalive<=0 {d.keepalive=0.5}
    if d.frame_ops<=0 {d.frame_ops=4096}
    if d.frame_bytes<=0 {d.frame_bytes=256<<10}
    for channel,i in d.channels {
        c:=channel
        if c.queue_bytes<=0 {c.queue_bytes=32<<10}
        if c.kind==.Reliable {
            c.max_message_bytes=max(int)
            if c.window<=0 {c.window=CHUNK_WINDOW}
            if c.window>MAX_WINDOW || c.window&(c.window-1)!=0 {return refuse(h,"channels.window","a power of two up to 4096; 0 takes 64")}
        } else {
            c.max_message_bytes=c.max_message_bytes<=0?MAX_UNRELIABLE_BYTES:min(c.max_message_bytes,MAX_UNRELIABLE_BYTES)
            c.window=0
        }
        h.channels[i]=c
    }
    h.channel_count=len(d.channels)
    d.channels=nil
    if d.protocol!=nil {
        if !d.protocol.sealed {return refuse(h,"protocol","sealed by protocol_seal")}
        h.channels[CHANNEL_SYSTEM]={kind=.Reliable,queue_bytes=64<<10,max_message_bytes=RELIABLE_EVENT_MAX_BYTES+16,window=CHUNK_WINDOW}
        h.channels[CHANNEL_EVENTS]={kind=.Unreliable,queue_bytes=16<<10,max_message_bytes=EVENT_MAX_BYTES+16}
    }
    h.start=time.tick_now()
    h.worker_interval=time.Millisecond

    when !crypto.HAS_RAND_BYTES {return refuse(h,"security","a system that gives secure random bytes: every connection is sealed")}
    b:=&h.back
    b.rng=d.seed
    b.scale=1
    if d.seed==0 {crypto.rand_bytes(mem.ptr_to_bytes(&b.rng))}
    crypto.rand_bytes(b.secret[:])
    secure_host_init(h)
    b.key=base.hash_combine(0x6d697261696e6574,u64(d.protocol_id))

    for &frame in h.frames {
        frame.ops=host_make(h,Op,d.frame_ops)
        frame.bytes=host_make_bytes(h,d.frame_bytes)
    }
    h.staging=&h.frames[0]
    for i in 1..<FRAME_COUNT {h.spare[h.spare_count]=&h.frames[i];h.spare_count+=1}
    h.connection_stats=host_make(h,Connection_Stats,d.max_connections)
    h.connection_handles=host_make(h,Connection,d.max_connections)
    h.shared_connection_stats=host_make(h,Connection_Stats,d.max_connections)
    h.shared_connection_handles=host_make(h,Connection,d.max_connections)
    h.sent=host_make(h,Queued_Bytes,d.max_connections)
    h.applied=host_make(h,[MAX_CHANNELS]u64,d.max_connections)
    h.shared_applied=host_make(h,[MAX_CHANNELS]u64,d.max_connections)
    h.system_free=host_make(h,u32,d.max_connections)
    h.shared_system_free=host_make(h,u32,d.max_connections)
    b.peers=host_make(h,Peer,d.max_connections)
    if !base.hash_map_init(&b.by_address,d.max_connections,h.allocator) {h.failed=true}
    // What one datagram can turn into, so a full command buffer stops the reading before it and not halfway.
    b.reserve_bytes=PACKET_BYTES*2
    b.reserve_count=PACKET_BYTES*8/15
    for i in 0..<MAX_CHANNELS {
        if h.channels[i].kind==.Reliable {b.reserve_bytes+=h.channels[i].window*CHUNK_BYTES+PIECE_BYTES}
    }
    if d.replication.records<=0 {d.replication.records=d.protocol!=nil?4096:1024}
    if d.protocol!=nil && !h.failed {
        if error:=repl_init(h);error!=.None {
            refused:=h.refused
            host_destroy(h)
            h.refused=refused
            return error
        }
    }
    if d.command_count<=0 {d.command_count=max(4096,b.reserve_count*4)}
    if d.command_bytes<=0 {d.command_bytes=max(512<<10,b.reserve_bytes*4)}
    if b.reserve_bytes>d.command_bytes/2 {host_destroy(h);return refuse(h,"command_bytes","at least twice what one datagram can turn into; 0 takes enough")}
    if b.reserve_count>d.command_count/2 {host_destroy(h);return refuse(h,"command_count","at least twice the commands one datagram can turn into; 0 takes enough")}
    released:=d.protocol!=nil && d.mode==.Server?d.replication.max_objects:0
    for &buffer in h.buffers {
        buffer.commands=host_make(h,Command,d.command_count)
        buffer.bytes=host_make_bytes(h,d.command_bytes)
        buffer.released=host_make(h,u32,released)
    }
    b.outbox,h.ready,h.inbox=&h.buffers[0],&h.buffers[1],&h.buffers[2]
    for &peer in b.peers {
        peer.generation=1
        if !h.failed {peer_allocate(h,&peer)}
    }
    if h.failed {host_destroy(h);return .Out_Of_Memory}
    return .None
}

host_destroy :: proc(h:^Host) {
    worker_stop(h)
    repl_destroy(h)
    for &peer in h.back.peers {peer_release(h,&peer)}
    delete(h.back.peers,h.allocator)
    delete(h.back.secure.failed,h.allocator)
    base.hash_map_destroy(&h.back.by_address)
    for frame in h.frames {delete(frame.ops,h.allocator);delete(frame.bytes,h.allocator)}
    for buffer in h.buffers {delete(buffer.commands,h.allocator);delete(buffer.bytes,h.allocator);delete(buffer.released,h.allocator)}
    delete(h.connection_stats,h.allocator);delete(h.connection_handles,h.allocator)
    delete(h.shared_connection_stats,h.allocator);delete(h.shared_connection_handles,h.allocator)
    delete(h.sent,h.allocator);delete(h.applied,h.allocator);delete(h.shared_applied,h.allocator)
    delete(h.system_free,h.allocator);delete(h.shared_system_free,h.allocator)
    h^={}
}

// Seconds since the host was initialized: the clock of the worker thread.
host_time :: proc(h:^Host) -> f64 {return time.duration_seconds(time.tick_since(h.start))}

@(private)
op_push :: proc(h:^Host,op:Op,data:[]u8=nil) -> bool {
    f:=h.staging
    size:=(len(data)+7)&~int(7)
    if !op_fits(h,len(data)) {h.operations_dropped+=1;return false}
    o:=&f.ops[f.count]
    f.count+=1
    o^=op
    o.offset,o.size=u32(f.used),u32(len(data))
    copy(f.bytes[f.used:],data)
    f.used+=size
    return true
}
// Whether the staged frame has room for one more operation with bytes of data.
@(private)
op_fits :: #force_inline proc "contextless" (h:^Host,bytes:int) -> bool {
    f:=h.staging
    return f.count<len(f.ops) && f.used+((bytes+7)&~int(7))<=len(f.bytes)
}
@(private)
op_data :: #force_inline proc(f:^Frame,op:^Op) -> []u8 {return f.bytes[op.offset:][:op.size]}

// Queues the staged frame for the network half. When that half is behind, the
// frame keeps filling and goes with the next call.
@(private)
frame_submit :: proc(h:^Host) {
    if h.staging.count==0 {return}
    sync.mutex_lock(&h.lock)
    if h.spare_count>0 && h.queued_count<FRAME_COUNT {
        h.queued[h.queued_count]=h.staging
        h.queued_count+=1
        h.spare_count-=1
        h.staging=h.spare[h.spare_count]
        h.staging.count,h.staging.used=0,0
    } else {
        h.publish_stalls+=1
    }
    sync.mutex_unlock(&h.lock)
}

// Client: starts connecting to a server at one of addresses: those of its
// invitation, its address on its network and the one its router mapped, are
// asked at once, and the first that accepts is the connection. The answer is
// a Connected or a Disconnected command.
host_connect :: proc(h:^Host,addresses:..Address) -> Error {
    if h.desc.mode!=.Client {return .Invalid}
    request:Connect_Request
    for address in addresses {
        if address.kind==.None || slice.contains(request.candidates[:request.count],address) {continue}
        if request.count==CANDIDATES {return .Invalid}
        request.candidates[request.count]=address
        request.count+=1
    }
    if request.count==0 {return .Invalid}
    return op_push(h,{kind=.Connect},mem.ptr_to_bytes(&request))?.None:.Full
}
// Closes a connection and tells the other end why. Zero closes every connection.
host_disconnect :: proc(h:^Host,connection:Connection=0,reason:=Disconnect_Reason.Closed) -> Error {
    return op_push(h,{kind=.Disconnect,a=u8(reason),handle=u64(connection)})?.None:.Full
}

// Queues a message on a channel of a connection. Zero sends it to every connection.
// A reliable message that does not fit in the queue of a connection returns
// Full and nothing is sent: the caller tries again after host_poll.
//
// With sent, a reliable message to one connection streams: sent bytes of it
// are queued, and each call queues what the queue and the frame have room for
// and adds it to sent, Full when it queued nothing; the message is sent when
// sent reaches its size. Until then the channel of the connection takes no
// other message.
message_send :: proc(h:^Host,connection:Connection,channel:int,data:[]u8,sent:^int=nil) -> Error {
    if channel<0 || channel>=h.channel_count {return .Invalid}
    reliable:=h.channels[channel].kind==.Reliable
    if sent!=nil {return message_stream(h,connection,channel,data,sent)}
    if reliable && len(data)+4>h.channels[channel].queue_bytes || len(data)>h.channels[channel].max_message_bytes {return .Too_Large}
    if reliable && (streaming(h,connection,channel) || !queue_room(h,connection,channel,len(data))) {return .Full}
    if !op_push(h,{kind=.Message,a=u8(channel),handle=u64(connection),c=max(u32)},data) {return .Full}
    queue_count(h,connection,channel,len(data))
    return .None
}

@(private)
message_stream :: proc(h:^Host,connection:Connection,channel:int,data:[]u8,sent:^int) -> Error {
    index:=int(base.handle_index(base.Handle(connection)))
    if h.channels[channel].kind!=.Reliable || connection==0 || index>=len(h.connection_handles) || h.connection_handles[index]!=connection || sent^<0 || sent^>len(data) || len(data)>=int(max(u32)) {return .Invalid}
    if len(data)==0 {return message_send(h,connection,channel,data)}
    q:=&h.sent[index]
    if q.connection!=connection {q^={connection=connection}}
    first:=sent^==0
    if first==(q.streaming[channel]!=0) || !first && q.streaming[channel]!=len(data)-sent^ {return .Full}
    header:=first?4:0
    free:=int(h.connection_stats[index].queue_free[channel])-int(queue_pending(h,index,channel))-header
    room:=len(h.staging.bytes)-h.staging.used
    size:=min(len(data)-sent^,free,room-room%8)
    if size<=0 {return .Full}
    if !op_push(h,{kind=.Message,a=u8(channel),handle=u64(connection),c=first?u32(len(data)):0},data[sent^:][:size]) {return .Full}
    q.bytes[channel]+=u64(header+size)
    sent^+=size
    q.streaming[channel]=len(data)-sent^
    return .None
}

// A message streams on the channel of the connection, or of any when it is zero.
@(private)
streaming :: proc(h:^Host,connection:Connection,channel:int) -> bool {
    for q,i in h.sent {
        if q.connection!=0 && q.connection==h.connection_handles[i] && (connection==0 || q.connection==connection) && q.streaming[channel]!=0 {return true}
    }
    return false
}

// A message of size bytes fits in the queue of the channel of the connection,
// or of every connection when it is zero, as of the last host_poll and what
// was queued since.
@(private)
queue_room :: proc(h:^Host,connection:Connection,channel,size:int) -> bool {
    for handle,i in h.connection_handles {
        if handle==0 || (connection!=0 && handle!=connection) {continue}
        free:=channel==CHANNEL_SYSTEM?h.system_free[i]:h.connection_stats[i].queue_free[channel]
        if queue_pending(h,i,channel)+u64(4+size)>u64(free) {return false}
    }
    return true
}

@(private)
queue_count :: proc(h:^Host,connection:Connection,channel,size:int) {
    if connection==0 {
        h.sent_all[channel]+=u64(4+size)
    } else if index:=int(base.handle_index(base.Handle(connection)));index<len(h.sent) {
        q:=&h.sent[index]
        if q.connection!=connection {q^={connection=connection}}
        q.bytes[channel]+=u64(4+size)
    }
}

// Bytes queued for a connection that its free room does not count yet.
@(private)
queue_pending :: proc(h:^Host,index,channel:int) -> u64 {
    q:=&h.sent[index]
    own:=u64(0)
    if q.connection==h.connection_handles[index] && q.bytes[channel]>h.applied[index][channel] {
        own=q.bytes[channel]-h.applied[index][channel]
    }
    return own+h.sent_all[channel]-h.applied_all[channel]
}

// Hands the staged operations to the network half and returns what it
// received since the last call. The slice is valid until the next call.
host_poll :: proc(h:^Host) -> []Command {
    frame_submit(h)
    sync.mutex_lock(&h.lock)
    if h.ready_full {
        h.inbox,h.ready=h.ready,h.inbox
        h.ready.count,h.ready.used,h.ready.released_count,h.ready.sync=0,0,0,{}
        h.ready_full=false
    } else {
        h.inbox.count,h.inbox.used,h.inbox.released_count,h.inbox.sync=0,0,0,{}
    }
    h.stats=h.shared_stats
    copy(h.connection_stats,h.shared_connection_stats)
    copy(h.connection_handles,h.shared_connection_handles)
    copy(h.applied,h.shared_applied)
    copy(h.system_free,h.shared_system_free)
    h.applied_all=h.shared_applied_all
    front_copy_stats(h)
    sync.mutex_unlock(&h.lock)
    h.stats.operations_dropped,h.stats.publish_stalls=h.operations_dropped,h.publish_stalls
    front_absorb(h,h.inbox)
    return h.inbox.commands[:h.inbox.count]
}

host_stats :: proc(h:^Host) -> Host_Stats {return h.stats}

// Statistics of a connection as of the last host_poll.
connection_stats :: proc(h:^Host,connection:Connection) -> (Connection_Stats,bool) {
    index:=int(base.handle_index(base.Handle(connection)))
    if index>=len(h.connection_handles) || connection==0 || h.connection_handles[index]!=connection {return {},false}
    return h.connection_stats[index],true
}

// Runs the network half on the calling thread: applies the frames queued by
// the simulation, receives, and sends what is due. now is in seconds and must
// not go back. False, doing nothing, while a worker runs: the half is its.
host_update :: proc(h:^Host,now:f64) -> bool {
    if h.worker!=nil {return false}
    frame_submit(h)
    back_update(h,now)
    return true
}

@(private)
back_update :: proc(h:^Host,now:f64) {
    b:=&h.back
    started:=time.tick_now()
    b.now=max(b.now,now)
    taken:[FRAME_COUNT]^Frame
    sync.mutex_lock(&h.lock)
    count:=h.queued_count
    copy(taken[:],h.queued[:count])
    h.queued_count=0
    sync.mutex_unlock(&h.lock)
    for frame in taken[:count] {
        for &op in frame.ops[:frame.count] {op_apply(h,frame,&op)}
        b.stats.frames+=1
    }
    if count>0 {
        sync.mutex_lock(&h.lock)
        for frame in taken[:count] {h.spare[h.spare_count]=frame;h.spare_count+=1}
        sync.mutex_unlock(&h.lock)
    }
    applied:=time.tick_now()

    b.secure.handshakes=h.desc.handshakes_per_update
    for {
        out:=b.outbox
        if len(out.bytes)-out.used<b.reserve_bytes || len(out.commands)-out.count<b.reserve_count {b.stats.receive_stalls+=1;break}
        size,from,ok:=h.desc.transport.receive(h.desc.transport.data,b.incoming[:])
        if !ok {break}
        b.stats.packets_received+=1
        b.stats.bytes_received+=u64(size)
        packet_receive(h,b.incoming[:size],from)
    }
    received:=time.tick_now()

    connections:=0
    for &peer in b.peers {
        if peer.state==.Free {continue}
        peer_service(h,&peer)
        if peer.state==.Connected {connections+=1}
    }
    if b.send_pending {repl_tick(h)}
    scoped:=time.tick_now()
    for &peer in b.peers {
        if peer.state==.Connected && peer_wants_send(h,&peer) {peer_send(h,&peer)}
    }
    b.send_pending,b.clock_due=false,false
    b.stats.connections=connections
    finished:=time.tick_now()
    b.stats.update_seconds=time.duration_seconds(time.tick_diff(started,finished))
    b.stats.apply_seconds=time.duration_seconds(time.tick_diff(started,applied))
    b.stats.receive_seconds=time.duration_seconds(time.tick_diff(applied,received))
    b.stats.scope_seconds=time.duration_seconds(time.tick_diff(received,scoped))
    b.stats.send_seconds=time.duration_seconds(time.tick_diff(scoped,finished))

    sync.mutex_lock(&h.lock)
    h.shared_stats=b.stats
    h.shared_applied_all=b.applied_all
    for &peer,i in b.peers {
        for &c,k in peer.channels {
            if k<USER_CHANNELS {peer.stats.queue_free[k]=u32(len(c.queue.data)-c.queue.used)}
            h.shared_applied[i][k]=c.applied
        }
        system:=&peer.channels[CHANNEL_SYSTEM]
        h.shared_system_free[i]=u32(len(system.queue.data)-system.queue.used)
        h.shared_connection_stats[i]=peer.stats
        h.shared_connection_handles[i]=peer.state==.Connected?peer_handle(h,&peer):0
    }
    repl_share_stats(h)
    out:=b.outbox
    if !h.ready_full && (out.count>0 || out.released_count>0 || out.sync.valid) {
        b.outbox,h.ready=h.ready,out
        h.ready_full=true
    }
    sync.mutex_unlock(&h.lock)
}

@(private)
op_apply :: proc(h:^Host,frame:^Frame,op:^Op) {
    b:=&h.back
    #partial switch op.kind {
    case .Tick:
        b.tick=op.c
        b.send_pending=true
    case .Clock:
        paused,scale:=op.a!=0,op.v[0]
        b.clock_due ||= paused!=b.paused || scale!=b.scale
        b.paused,b.scale=paused,scale
    case .Connect:
        request:Connect_Request
        mem.copy(&request,raw_data(op_data(frame,op)),size_of(Connect_Request))
        peer_connect(h,&request)
    case .Disconnect:
        for &peer in b.peers {
            if peer.state==.Free || (op.handle!=0 && u64(peer_handle(h,&peer))!=op.handle) {continue}
            peer_drop(h,&peer,Disconnect_Reason(op.a),true)
        }
    case .Message:
        // c: max for a whole message, else the size of a streamed one with its first bytes, 0 with the rest.
        data:=op_data(frame,op)
        total:=op.c==max(u32)?-1:int(op.c)
        size:=u64(total==0?len(data):4+len(data))
        if op.handle==0 {b.applied_all[op.a]+=size}
        for &peer in b.peers {
            if peer.state!=.Connected || (op.handle!=0 && u64(peer_handle(h,&peer))!=op.handle) {continue}
            if op.handle!=0 {peer.channels[op.a].applied+=size}
            channel_queue(h,&peer,int(op.a),data,total)
        }
    case:
        repl_op(h,frame,op)
    }
}

@(private)
command_push :: proc(h:^Host,command:Command,data:[]u8=nil,words:=0) -> ^Command {
    out:=h.back.outbox
    size:=(len(data)+7)&~int(7)+words*4
    size=(size+7)&~int(7)
    if out.count>=len(out.commands) || out.used+size>len(out.bytes) {h.back.stats.commands_dropped+=1;return nil}
    c:=&out.commands[out.count]
    out.count+=1
    c^=command
    if len(data)>0 {
        c.data=out.bytes[out.used:][:len(data)]
        copy(c.data,data)
    }
    if words>0 {
        c.words=mem.slice_data_cast([]u32,out.bytes[out.used+(len(data)+7)&~int(7):][:words*4])
    }
    out.used+=size
    return c
}

// Starts a thread that runs the network half about once per interval, so
// receiving, packing and sending never wait for the simulation nor hold it.
worker_start :: proc(h:^Host,interval:=time.Millisecond) -> bool {
    if h.worker!=nil {return false}
    h.worker_interval=interval
    sync.atomic_store(&h.worker_stop,false)
    h.worker=thread.create_and_start_with_data(h,proc(data:rawptr) {
        h:=(^Host)(data)
        for !sync.atomic_load(&h.worker_stop) {
            back_update(h,host_time(h))
            time.sleep(h.worker_interval)
        }
    })
    return h.worker!=nil
}
worker_stop :: proc(h:^Host) {
    if h.worker==nil {return}
    sync.atomic_store(&h.worker_stop,true)
    thread.join(h.worker)
    thread.destroy(h.worker)
    h.worker=nil
}
