package mirai_net

import "base:intrinsics"
import "core:math"
import "core:mem"
import "mirai:std/base"
import "mirai:std/serial"

// Simulation half of replication: the table of objects the game registered
// (server) or was told about (client), and the calls that turn the game's
// structures into the quantized words a frame carries to the network half.
//
// A replicated object is an opaque user id, an object type of the protocol
// and one source pointer per fragment. Nothing here knows what the id means.

Object :: distinct base.Handle

// What a client is to a replica.
Role :: enum u8 {
    None,
    Shown,     // someone else's: shown as the server sends it
    Predicted, // owned by this client: it simulates it ahead, the server corrects
    Held,      // lent to this client: it simulates it and sends the state
}

// Who simulates an object.
Simulation :: enum u8 {
    Server, // the server; its owner predicts it
    Lent,   // the server, or the one client it lends it to at a time
    Each,   // every end its own copy: only the creation is replicated
}

Filter :: enum u8 {
    Always,  // every connection
    Owner,   // only the owning connection
    Spatial, // connections whose view reaches the object
    None,    // no connection
}

GROUPS_MAX :: 65535
OBJECT_GROUPS :: 4

// The groups of an object, from 1 to Replication_Desc.groups, in any order: a
// connection sees it while it has any of them. 0 is no group; with none, it is
// of no group.
Groups :: [OBJECT_GROUPS]u16

Replication_Desc :: struct {
    max_objects:int,       // default 1024. A client needs at least as many as its server
    state_words:int,       // quantized states, in 32-bit words and one more per object; default: max_objects of the largest object the fragments of the protocol make.
                           // object_create refuses with Full an object whose state does not fit
    baseline_words:int,    // baselines, likewise. A server shares each one among the connections that take it in the same state;
                           // default: eight per object (two per connection below four), and on a client two per replica
    records:int,           // per connection: objects and chunks in datagrams not yet acknowledged, default 4096
    budget_bytes:int,      // object data per connection and tick, default 4096
    max_updates:int,       // objects considered per connection and tick, default 256
    send_every:int,        // ticks between sends, default 1
    baseline_interval:int, // ticks before a connection takes a new baseline of an object, default 4; negative disables deltas
    filter_interval:int,   // ticks between evaluations of what a connection sees, default 2
    cell_size:f32,         // meters, default 32
    hysteresis:int,        // evaluations out of view before an object leaves a connection, default 8, at most 256
    leave_margin:f32,      // fraction of the reach of a view an object in it may go beyond before it counts as out, default 0.1; negative: none
    lease_ticks:int,       // ticks a delegated authority lasts without sending state, default 120
    input_redundancy:int,  // inputs repeated in every datagram, default 4, at most 8
    // seconds both ends can go back, as ticks of tick_rate (host_history): the client's history,
    // the input a server keeps ahead of its tick and its lag compensation. The server announces
    // its ticks in the handshake and a client takes them. Default 0.5, at most HISTORY_MAX_SECONDS
    history_seconds:f32,
    input_lead:f32,        // ticks of input the server should have in hand, default 2
    input_delay:f32,       // client: ticks ahead of its own that it submits its input for; its tick runs that many less ahead of the server
    interpolation_delay:f32, // ticks behind the server that remote objects are shown besides the jitter, default 2.5
    display_jump:f32,      // client: seconds the display of remote objects may fall behind where it should be before it jumps there; default 30 ticks
    display_dilation:f32,  // client: how much faster or slower than its ticks the display may run to catch up, default 0.1
    object_stats:bool,     // keep bits sent per object
    groups:int,            // server: groups an object can be of (object_set_groups), from 1; default 1024, at most 65535
}

Object_Desc :: struct {
    type:Type_Id,
    user:u64,                       // the game's id; Entity fields holding it travel as this object
    sources:[MAX_FRAGMENTS]rawptr,  // fragment structures; nil ones start zeroed and need object_write
    owner:Connection,
    filter:Filter,
    simulation:Simulation,
    priority:f32,                   // default 1
    position:[3]f32,
    radius:f32,                     // added to a view's radius, for large objects
    parent:Object,                  // created on a connection only after its parent, and never without it
    poll:bool,                      // compare the sources at every publish instead of waiting for object_mark_dirty
    poll_interval:int,              // ticks between turns, default 1: a polled object is read only on its turn, which object_poll_due tells
    auto_authority:bool,            // Lent: the first client to ask gets it without consulting the game
    groups:Groups,                  // a connection sees it only while it has one of them (connection_set_group); none: of no group
    visibility:u32,                 // a connection sees it only while it shares a bit with it (connection_set_visibility); 0: any
}

Input_Status :: enum u8 {
    None,     // nothing ever arrived from that connection: out is zeroed
    Fresh,    // the input of that tick
    Repeated, // that tick did not arrive in time: the latest one before it
}

Type_Stats :: struct {creates,updates,destroys,bits:u64}

@(private) INPUT_MAX_BYTES :: 96
@(private) INPUT_RING :: 16 // client: inputs kept until acknowledged, more than input_redundancy

HISTORY_SECONDS :: f32(0.5)
HISTORY_MAX_SECONDS :: f32(2)

// Ticks of history for seconds at a tick rate. A ring of them takes one slot more: the
// newest is the tick being written, and the whole depth lies behind it.
history_ticks :: proc(seconds:f32,tick_rate:int) -> int {
    return max(int(math.ceil(seconds*f32(tick_rate))),1)
}

// The ticks of history of the session: on a server its own, on a client the server's once
// connected (Command Connected), its own before.
host_history :: proc(h:^Host) -> int {
    return h.desc.mode==.Client && h.front.history>0?h.front.history:h.history
}

// Server: slots of the input ring of a connection; it takes input up to the history ahead of
// the tick it published last.
@(private)
input_depth :: #force_inline proc(h:^Host) -> int {return h.history+1}

@(private)
Front_Flag :: enum u8 {Alive,Poll,Dormant,Listed,Stale}
@(private)
Front_Object :: struct {
    generation:u32,
    type:Type_Id,
    flags:bit_set[Front_Flag;u8],
    dirty:Fragment_Mask, // fragments to quantize at the next publish
    role:Role,
    simulation:Simulation,
    poll_slot:u32,
    every,phase:u32, // its turns are the ticks whose remainder by every is phase
    user:u64,
    sources:[MAX_FRAGMENTS]rawptr,
}
@(private)
Front :: struct {
    objects:[]Front_Object,
    free:[]u32,
    free_head,free_count:int,
    dirty:[]u32,
    dirty_count:int,
    polled:[]u32,
    poll_count:int,
    turns:[64]u32, // objects scheduled by interval, so that the ones with the same interval take different phases
    user_keys:[]u64,
    user_values:[]u32,
    binding_revision,published_bindings:u64,
    words:[MAX_STATE_WORDS]u32,
    state_words:int, // server: words the states of the objects take in the network half, until it releases them
    type_stats:[]Type_Stats,
    object_bits:[]u64,
    clock:Clock,
    input_size:int,
    input_ticks:[]u32, // connections x input_depth: tick+1
    input_data:[]u8,
    input_last:[]u8,   // connections x input_size
    input_seen:[]bool,
    server_connection:Connection,
    history:int, // client: the ticks of history the server announced when it accepted
}

@(private)
repl_init :: proc(h:^Host) -> Error {
    d:=&h.desc.replication
    if d.max_objects<=0 {d.max_objects=1024}
    if d.max_objects>1<<20 {return refuse(h,"replication.max_objects","at most 1048576; 0 takes 1024")}
    if d.budget_bytes<=0 {d.budget_bytes=4096}
    if d.max_updates<=0 {d.max_updates=256}
    if d.send_every<=0 {d.send_every=1}
    if d.baseline_interval==0 {d.baseline_interval=4}
    if d.filter_interval<=0 {d.filter_interval=2}
    if d.cell_size<=0 {d.cell_size=32}
    if !(d.cell_size<=max(f32)) {return refuse(h,"replication.cell_size","finite meters; 0 or less takes 32")}
    if !(abs(d.leave_margin)<=max(f32)) {return refuse(h,"replication.leave_margin","a finite fraction; 0 takes 0.1, below 0 none")}
    if !(abs(d.interpolation_delay)<=max(f32)) {return refuse(h,"replication.interpolation_delay","finite ticks; 0 or less takes 2.5")}
    if d.hysteresis<=0 {d.hysteresis=8}
    if d.hysteresis>256 {return refuse(h,"replication.hysteresis","from 1 to 256 evaluations; 0 or less takes 8")}
    if d.leave_margin==0 {d.leave_margin=0.1}
    d.leave_margin=max(d.leave_margin,0)
    if d.lease_ticks<=0 {d.lease_ticks=120}
    d.input_redundancy=d.input_redundancy<=0?4:min(d.input_redundancy,8)
    if d.input_lead<=0 {d.input_lead=2}
    if d.interpolation_delay<=0 {d.interpolation_delay=2.5}
    if !(abs(d.display_jump)<=max(f32)) {return refuse(h,"replication.display_jump","finite seconds; 0 or less takes 30 ticks")}
    if !(abs(d.display_dilation)<=max(f32)) {return refuse(h,"replication.display_dilation","a finite fraction; 0 or less takes 0.1")}
    if d.display_jump<=0 {d.display_jump=f32(CLOCK_JUMP_TICKS)/f32(h.desc.tick_rate)}
    if d.display_dilation<=0 {d.display_dilation=CLOCK_MAX_DILATION}
    if d.groups<=0 {d.groups=1024}
    if d.groups>GROUPS_MAX {return refuse(h,"replication.groups","at most 65535; 0 takes 1024")}
    f:=&h.front
    protocol:=h.desc.protocol
    largest:=protocol.object_words
    if d.state_words<=0 {d.state_words=d.max_objects*(largest+1)}
    if d.baseline_words<=0 {
        d.baseline_words=d.max_objects*(largest+1)*(h.desc.mode==.Client?2:d.baseline_interval<0?0:min(2*h.desc.max_connections,8))
    }
    f.objects=host_make(h,Front_Object,d.max_objects)
    f.dirty=host_make(h,u32,d.max_objects)
    f.polled=host_make(h,u32,d.max_objects)
    capacity:=1
    for capacity<d.max_objects*2 {capacity<<=1}
    f.user_keys=host_make(h,u64,capacity)
    f.user_values=host_make(h,u32,capacity)
    f.type_stats=host_make(h,Type_Stats,TYPE_CAPACITY)
    h.shared_type_stats=host_make(h,Type_Stats,TYPE_CAPACITY)
    if d.object_stats {f.object_bits=host_make(h,u64,d.max_objects)}
    if h.desc.mode==.Server {
        f.free=host_make(h,u32,d.max_objects)
        for &slot,i in f.free {slot=u32(i)}
        f.free_count=d.max_objects
        if protocol.has_input {
            f.input_size=int(protocol.input.fragments[0].size)
            f.input_ticks=host_make(h,u32,h.desc.max_connections*input_depth(h))
            f.input_data=host_make(h,u8,h.desc.max_connections*input_depth(h)*f.input_size)
            f.input_last=host_make(h,u8,h.desc.max_connections*f.input_size)
            f.input_seen=host_make(h,bool,h.desc.max_connections)
        }
    }
    clock_init(&f.clock,h)
    return back_init(h)
}
@(private)
repl_destroy :: proc(h:^Host) {
    f:=&h.front
    delete(f.objects,h.allocator);delete(f.free,h.allocator);delete(f.dirty,h.allocator);delete(f.polled,h.allocator)
    delete(f.user_keys,h.allocator);delete(f.user_values,h.allocator);delete(f.type_stats,h.allocator)
    delete(f.object_bits,h.allocator);delete(h.shared_type_stats,h.allocator)
    delete(f.input_ticks,h.allocator);delete(f.input_data,h.allocator);delete(f.input_last,h.allocator);delete(f.input_seen,h.allocator)
    back_destroy(h)
}

@(private)
user_slot :: proc(f:^Front,user:u64) -> (slot:int,found:bool) {
    mask:=len(f.user_keys)-1
    slot=int((user*0x9e3779b97f4a7c15)>>32)&mask
    for f.user_keys[slot]!=0 {
        if f.user_keys[slot]==user {return slot,true}
        slot=(slot+1)&mask
    }
    return slot,false
}
@(private)
user_set :: proc(f:^Front,user:u64,index:u32) {
    if user==0 {return}
    slot,_:=user_slot(f,user)
    f.user_keys[slot],f.user_values[slot]=user,index
}
@(private)
user_remove :: proc(f:^Front,user:u64,index:u32) {
    if user==0 {return}
    slot,found:=user_slot(f,user)
    if !found || f.user_values[slot]!=index {return}
    mask:=len(f.user_keys)-1
    f.user_keys[slot]=0
    next:=(slot+1)&mask
    for f.user_keys[next]!=0 {
        key,value:=f.user_keys[next],f.user_values[next]
        f.user_keys[next]=0
        target,_:=user_slot(f,key)
        f.user_keys[target],f.user_values[target]=key,value
        next=(next+1)&mask
    }
}
// What an Entity field travels as when it names something this end does not
// replicate: the other end has no object for it, so the reference stays
// pending there (object_references_pending), instead of reading as none.
UNREPLICATED :: max(u64)

@(private)
front_to_reference :: proc(h:^Host,user:u64) -> u64 {
    if user==0 {return 0}
    object:=front_to_object(h,user)
    return object==0?UNREPLICATED:object
}

@(private)
front_to_object :: proc(h:^Host,user:u64) -> u64 {
    if user==0 {return 0}
    slot,found:=user_slot(&h.front,user)
    if !found {return 0}
    index:=h.front.user_values[slot]
    return u64(base.handle_make(index,h.front.objects[index].generation))
}
@(private)
front_to_user :: proc(h:^Host,object:u64) -> u64 {
    o:=front_object(h,Object(object))
    return o==nil?0:o.user
}
@(private)
front_object :: proc(h:^Host,object:Object) -> ^Front_Object {
    index:=int(base.handle_index(base.Handle(object)))
    if object==0 || index>=len(h.front.objects) {return nil}
    o:=&h.front.objects[index]
    return .Alive in o.flags && o.generation==base.handle_generation(base.Handle(object))?o:nil
}

@(private)
Create_Payload :: struct {
    owner:Connection,
    parent:Object,
    position:[3]f32,
    radius,priority:f32,
    type:Type_Id,
    filter:Filter,
    simulation:Simulation,
    auto:bool,
    groups:Groups,
    visibility:u32,
}

@(private)
Create_Buffer :: struct {payload:Create_Payload,words:[MAX_STATE_WORDS]u32}

// Server: what it lacks to create an object of a type now, the capacity that
// makes object_create refuse it with Full.
Room :: enum u8 {
    Fits,
    Objects,     // the objects of Replication_Desc.max_objects are in use
    State_Words, // their states fill Replication_Desc.state_words
    Frame,       // the operations staged since the last publish fill Host_Desc.frame_ops or frame_bytes: it fits after the next publish
}

object_room :: proc(h:^Host,type:Type_Id) -> Room {
    f:=&h.front
    protocol:=h.desc.protocol
    if protocol==nil || int(type)>=type_count(protocol) {return .Fits}
    size:=protocol.types[type].words
    if f.free_count==0 {return .Objects}
    if f.state_words+size+1>h.desc.replication.state_words {return .State_Words}
    if !op_fits(h,int(offset_of(Create_Buffer,words))+size*4) {return .Frame}
    return .Fits
}

// Server: registers an object. Its creation, with the state the sources hold
// now, reaches every connection that should see it.
object_create :: proc(h:^Host,desc:Object_Desc) -> (Object,Error) {
    f:=&h.front
    protocol:=h.desc.protocol
    if h.desc.mode!=.Server || protocol==nil || int(desc.type)>=type_count(protocol) {return 0,.Invalid}
    if !position_valid(desc.position) || !(desc.radius>=0 && desc.radius<=max(f32)) {return 0,.Invalid}
    if !(abs(desc.priority)<=max(f32)) || desc.poll_interval<0 || desc.poll_interval>int(max(u32)) {return 0,.Invalid}
    if desc.parent!=0 && front_object(h,desc.parent)==nil {return 0,.Invalid}
    if !groups_valid(h,desc.groups) {return 0,.Invalid}
    type:=&protocol.types[desc.type]
    if object_room(h,desc.type)!=.Fits {return 0,.Full}
    index:=f.free[f.free_head]
    o:=&f.objects[index]
    generation:=o.generation+1
    staged:Create_Buffer
    payload:=&staged.payload
    payload^={owner=desc.owner,parent=desc.parent,position=desc.position,radius=desc.radius,
        priority=desc.priority<=0?1:desc.priority,type=desc.type,filter=desc.filter,simulation=desc.simulation,auto=desc.auto_authority,groups=desc.groups,visibility=desc.visibility}
    words:=staged.words[:type.words]
    o^={generation=generation,type=desc.type,flags={.Alive},simulation=desc.simulation,user=desc.user,sources=desc.sources}
    user_set(f,desc.user,index)
    for fragment in 0..<type.fragment_count {
        if desc.sources[fragment]!=nil {fragment_quantize(protocol,type,fragment,desc.sources[fragment],words,h,front_to_reference)}
    }
    object:=Object(base.handle_make(index,generation))
    if !op_push(h,{kind=.Object_Create,handle=u64(object)},mem.ptr_to_bytes(&staged)[:int(offset_of(Create_Buffer,words))+type.words*4]) {
        user_remove(f,desc.user,index)
        o^={generation=generation-1}
        return 0,.Full
    }
    f.free_head=(f.free_head+1)%len(f.free)
    f.free_count-=1
    f.state_words+=type.words+1
    f.binding_revision+=1
    poll_schedule(f,o,desc.poll_interval)
    if desc.poll {
        o.flags+={.Poll}
        o.poll_slot=u32(f.poll_count)
        f.polled[f.poll_count]=index
        f.poll_count+=1
    }
    return object,.None
}

// Server: the object is of another type from now on, with the state its
// sources hold: every connection that has its replica takes both in its place,
// and the replica goes on. Full when the state does not fit state_words or the
// frame: try again after the next publish.
object_retype :: proc(h:^Host,object:Object,type:Type_Id,sources:[MAX_FRAGMENTS]rawptr) -> Error {
    f:=&h.front
    protocol:=h.desc.protocol
    o:=front_object(h,object)
    if o==nil || h.desc.mode!=.Server || protocol==nil || int(type)>=type_count(protocol) {return .Invalid}
    if o.type==type {return .None}
    sources:=sources
    before,after:=&protocol.types[o.type],&protocol.types[type]
    size:=int(offset_of(Create_Buffer,words))+after.words*4
    if f.state_words-before.words+after.words>h.desc.replication.state_words || !op_fits(h,size) {return .Full}
    staged:Create_Buffer
    staged.payload.type=type
    words:=staged.words[:after.words]
    for fragment in 0..<after.fragment_count {
        if sources[fragment]!=nil {fragment_quantize(protocol,after,fragment,sources[fragment],words,h,front_to_reference)}
    }
    if !op_push(h,{kind=.Object_Retype,handle=u64(object)},mem.ptr_to_bytes(&staged)[:size]) {return .Full}
    f.state_words+=after.words-before.words
    o.type,o.dirty,o.sources=type,0,sources
    f.binding_revision+=1
    return .None
}

@(private)
poll_schedule :: proc(f:^Front,o:^Front_Object,interval:int) {
    o.every,o.phase=u32(max(interval,1)),0
    if o.every==1 {return}
    turn:=&f.turns[o.every&63]
    o.phase=turn^%o.every
    turn^+=1
}
@(private)
poll_due :: #force_inline proc "contextless" (o:^Front_Object,tick:u32) -> bool {return o.every<=1 || tick%o.every==o.phase}

// Ticks between the turns of an object, 0 taking 1. Objects given the same
// interval take turns on different ticks, to spread the cost of reading them.
object_set_poll_interval :: proc(h:^Host,object:Object,interval:int) -> Error {
    o:=front_object(h,object)
    if o==nil || interval<0 || interval>int(max(u32)) {return .Invalid}
    if u32(max(interval,1))!=max(o.every,1) {poll_schedule(&h.front,o,interval)}
    return .None
}
object_poll_interval :: proc(h:^Host,object:Object) -> int {
    o:=front_object(h,object)
    return o==nil?0:int(max(o.every,1))
}
// Whether tick is a turn of the object: a polled one is read then, and a game
// that writes its state with object_write may follow the same turns.
object_poll_due :: proc(h:^Host,object:Object,tick:u32) -> bool {
    o:=front_object(h,object)
    return o!=nil && poll_due(o,tick)
}

// Server: removes the object from every connection. Its slot is reused once they all confirm.
object_destroy :: proc(h:^Host,object:Object) -> Error {
    f:=&h.front
    o:=front_object(h,object)
    if o==nil || h.desc.mode!=.Server {return .Invalid}
    if !op_push(h,{kind=.Object_Destroy,handle=u64(object)}) {return .Full}
    index:=base.handle_index(base.Handle(object))
    user_remove(f,o.user,index)
    if .Poll in o.flags {
        f.poll_count-=1
        moved:=f.polled[f.poll_count]
        f.polled[o.poll_slot]=moved
        f.objects[moved].poll_slot=o.poll_slot
    }
    o.flags={.Stale}
    f.binding_revision+=1
    return .None
}

object_valid :: proc(h:^Host,object:Object) -> bool {return front_object(h,object)!=nil}
object_user :: proc(h:^Host,object:Object) -> u64 {
    o:=front_object(h,object)
    return o==nil?0:o.user
}
// The object registered or bound with a user id, or zero.
object_of_user :: proc(h:^Host,user:u64) -> Object {return Object(front_to_object(h,user))}
object_type :: proc(h:^Host,object:Object) -> Type_Id {
    o:=front_object(h,object)
    return o==nil?TYPE_NONE:o.type
}
// Client: what this client is to the replica.
object_role :: proc(h:^Host,object:Object) -> Role {
    o:=front_object(h,object)
    return o==nil?.None:o.role
}

// Client: gives a replica the game's id, so Entity fields that refer to it resolve.
object_bind :: proc(h:^Host,object:Object,user:u64) -> Error {
    o:=front_object(h,object)
    if o==nil {return .Invalid}
    if o.user==user {return .None}
    index:=base.handle_index(base.Handle(object))
    user_remove(&h.front,o.user,index)
    o.user=user
    user_set(&h.front,user,index)
    h.front.binding_revision+=1
    return .None
}

object_binding_revision :: proc(h:^Host) -> u64 {return h.front.binding_revision}

// Quantizes into the complete object's word layout without publishing or retaining source.
object_pack :: proc(h:^Host,type:Type_Id,fragment:int,source:rawptr,words:[]u32) -> bool {
    protocol:=h.desc.protocol
    if protocol==nil || !protocol.sealed || int(type)>=type_count(protocol) || source==nil {return false}
    desc:=&protocol.types[type]
    if fragment<0 || fragment>=desc.fragment_count || len(words)<desc.words {return false}
    fragment_quantize(protocol,desc,fragment,source,words,h,front_to_reference)
    return true
}

// Change bits containing nonzero references whose object has not been bound yet.
object_references_pending :: proc(h:^Host,command:^Command,fragment:=-1) -> (mask:u64) {
    protocol:=h.desc.protocol
    if protocol==nil || command==nil || int(command.type)>=type_count(protocol) {return}
    type:=&protocol.types[command.type]
    if len(command.words)<type.words || fragment>=type.fragment_count {return}
    for &leaf in type.leaves {
        if leaf.kind!=.Object || fragment>=0 && int(leaf.fragment)!=fragment {continue}
        value:=word_load(command.words,&leaf)
        if value!=0 && front_to_user(h,value)==0 {mask|=u64(1)<<leaf.bit}
    }
    return
}

object_set_source :: proc(h:^Host,object:Object,fragment:int,source:rawptr) -> Error {
    o:=front_object(h,object)
    if o==nil || fragment<0 || fragment>=h.desc.protocol.types[o.type].fragment_count {return .Invalid}
    o.sources[fragment]=source
    return .None
}

// The fragment changed (all of them by default): it is read again at the next publish.
object_mark_dirty :: proc(h:^Host,object:Object,fragment:=-1) -> Error {
    f:=&h.front
    o:=front_object(h,object)
    if o==nil || fragment>=h.desc.protocol.types[o.type].fragment_count {return .Invalid}
    o.dirty|=fragment<0?max(Fragment_Mask):1<<uint(fragment)
    if .Listed not_in o.flags {
        o.flags+={.Listed}
        f.dirty[f.dirty_count]=base.handle_index(base.Handle(object))
        f.dirty_count+=1
    }
    return .None
}

// Reads a fragment from source now, without keeping the pointer.
object_write :: proc(h:^Host,object:Object,fragment:int,source:rawptr) -> Error {
    o:=front_object(h,object)
    protocol:=h.desc.protocol
    if o==nil || source==nil || fragment<0 || fragment>=protocol.types[o.type].fragment_count {return .Invalid}
    if h.desc.mode==.Client && o.role!=.Held {return .Invalid}
    return front_push_state(h,o,object,fragment,source)?.None:.Full
}

@(private)
front_push_state :: proc(h:^Host,o:^Front_Object,object:Object,fragment:int,source:rawptr) -> bool {
    protocol:=h.desc.protocol
    type:=&protocol.types[o.type]
    words:=h.front.words[:type.words]
    fragment_quantize(protocol,type,fragment,source,words,h,front_to_reference)
    info:=type.fragments[fragment]
    if info.leaf_count==0 {return true}
    first:=type.leaves[info.first_leaf]
    last:=type.leaves[info.first_leaf+info.leaf_count-1]
    span:=words[first.word:int(last.word)+int(last.words)]
    return op_push(h,{kind=.Object_State,a=u8(fragment),b=first.word,handle=u64(object)},mem.slice_data_cast([]u8,span))
}

// A dormant object is not polled and its dirty marks wait: waking it sends what changed meanwhile.
object_set_dormant :: proc(h:^Host,object:Object,dormant:bool) -> Error {
    o:=front_object(h,object)
    if o==nil {return .Invalid}
    if dormant {
        o.flags+={.Dormant}
    } else if .Dormant in o.flags {
        o.flags-={.Dormant}
        object_mark_dirty(h,object)
    }
    return .None
}

@(private)
object_op :: proc(h:^Host,object:Object,op:Op) -> Error {
    if front_object(h,object)==nil || h.desc.mode!=.Server {return .Invalid}
    op:=op
    op.handle=u64(object)
    return op_push(h,op)?.None:.Full
}
object_set_owner :: proc(h:^Host,object:Object,owner:Connection) -> Error {return object_op(h,object,{kind=.Object_Owner,value=u64(owner)})}
object_set_priority :: proc(h:^Host,object:Object,priority:f32) -> Error {
    if !(abs(priority)<=max(f32)) {return .Invalid}
    return object_op(h,object,{kind=.Object_Priority,v={0=priority}})
}
object_set_position :: proc(h:^Host,object:Object,position:[3]f32) -> Error {
    if !position_valid(position) {return .Invalid}
    return object_op(h,object,{kind=.Object_Position,v={position.x,position.y,position.z,0}})
}
object_set_radius :: proc(h:^Host,object:Object,radius:f32) -> Error {
    if !(radius>=0 && radius<=max(f32)) {return .Invalid}
    return object_op(h,object,{kind=.Object_Radius,v={0=radius}})
}
object_set_filter :: proc(h:^Host,object:Object,filter:Filter) -> Error {return object_op(h,object,{kind=.Object_Filter,a=u8(filter)})}
object_set_parent :: proc(h:^Host,object,parent:Object) -> Error {
    if parent==object || parent!=0 && front_object(h,parent)==nil {return .Invalid}
    return object_op(h,object,{kind=.Object_Parent,value=u64(parent)})
}
// Server: the visibility bits of an object, like collision layers: whatever
// its filter and its groups let, a connection sees it only while it shares a
// bit with it (connection_set_visibility), and so its children. 0: it asks for
// none. Teams, fog of war and what is private to some players are bits.
object_set_visibility :: proc(h:^Host,object:Object,mask:u32) -> Error {
    return object_op(h,object,{kind=.Object_Visibility,c=mask})
}

// Server: the visibility bits a connection has. One that arrives has none: it
// sees the objects that ask for none.
connection_set_visibility :: proc(h:^Host,connection:Connection,mask:u32) -> Error {
    if h.desc.mode!=.Server || connection==0 {return .Invalid}
    return op_push(h,{kind=.Connection_Visibility,handle=u64(connection),c=mask})?.None:.Full
}

// Server: the groups of an object: whatever its filter, a connection sees it
// only while it has one of them, and so its children; one link a connection
// however many of them it has. A part of the world that a connection may not
// have loaded (a section) is a group, and what is in several (sections that
// overlap) is of each. None: of no group.
object_set_groups :: proc(h:^Host,object:Object,groups:Groups) -> Error {
    if !groups_valid(h,groups) {return .Invalid}
    return object_op(h,object,{kind=.Object_Group,value=transmute(u64)groups})
}

@(private)
groups_valid :: proc(h:^Host,groups:Groups) -> bool {
    for group in groups {
        if int(group)>h.desc.replication.groups {return false}
    }
    return true
}

// Server: whether a connection has a group, which lets it see the objects of
// that group. A connection that arrives has none.
connection_set_group :: proc(h:^Host,connection:Connection,group:int,has:bool) -> Error {
    if h.desc.mode!=.Server || connection==0 || group<1 || group>h.desc.replication.groups {return .Invalid}
    return op_push(h,{kind=.Connection_Group,handle=u64(connection),c=u32(group),a=u8(has)})?.None:.Full
}

// Server: the connection has no group, as when it arrived.
connection_clear_groups :: proc(h:^Host,connection:Connection) -> Error {
    if h.desc.mode!=.Server || connection==0 {return .Invalid}
    return op_push(h,{kind=.Connection_Group,handle=u64(connection)})?.None:.Full
}

// Server: where a connection looks from. Spatial objects within radius are replicated to it; a negative radius
// is a view without an edge, which reaches every one of them.
connection_set_view :: proc(h:^Host,connection:Connection,position:[3]f32,radius:f32) -> Error {
    if h.desc.mode!=.Server {return .Invalid}
    if !position_valid(position) || !(abs(radius)<=max(f32)) {return .Invalid}
    return op_push(h,{kind=.View,handle=u64(connection),v={position.x,position.y,position.z,radius}})?.None:.Full
}

// Server: a held connection sees no object, as if every one were out of its
// view, and hears only the events registered Held, until it is let go: one
// that is still loading the world it will see. Host_Desc.hold holds every
// connection that arrives.
connection_hold :: proc(h:^Host,connection:Connection,held:bool) -> Error {
    if h.desc.mode!=.Server || connection==0 {return .Invalid}
    return op_push(h,{kind=.Hold,handle=u64(connection),a=u8(held)})?.None:.Full
}

// Server: whether its clock is paused and how fast its ticks run (scale, in
// (0, 64]), which every client hears with the tick at once.
clock_set :: proc(h:^Host,paused:bool,scale:f32) -> Error {
    if h.desc.mode!=.Server || !(scale>0 && scale<=CLOCK_SCALE_LIMIT) {return .Invalid}
    return op_push(h,{kind=.Clock,a=u8(paused),v={scale,0,0,0}})?.None:.Full
}

@(private)
position_valid :: #force_inline proc "contextless" (position:[3]f32) -> bool {
    return abs(position.x)<=max(f32) && abs(position.y)<=max(f32) && abs(position.z)<=max(f32)
}

// Server: lends the simulation of a Lent object to a connection for
// lease_ticks without news from it (0 takes the default); a zero connection
// takes it back. The previous holder is told, the new one gets the full state.
authority_grant :: proc(h:^Host,object:Object,connection:Connection,lease_ticks:=0) -> Error {
    o:=front_object(h,object)
    if o==nil || o.simulation!=.Lent {return .Invalid}
    return object_op(h,object,{kind=.Authority_Grant,value=u64(connection),c=u32(lease_ticks)})
}
// Client: asks the server for the simulation of a Lent replica.
authority_request :: proc(h:^Host,object:Object) -> Error {
    o:=front_object(h,object)
    if o==nil || h.desc.mode!=.Client || o.simulation!=.Lent {return .Invalid}
    return authority_push(h,.Authority_Request,object)
}
// Client: gives the authority back.
authority_release :: proc(h:^Host,object:Object) -> Error {
    o:=front_object(h,object)
    if o==nil || h.desc.mode!=.Client || o.role!=.Held {return .Invalid}
    return authority_push(h,.Authority_Release,object)
}

// A request goes on the reliable channel of the library: Full when it has no room.
@(private)
authority_push :: proc(h:^Host,kind:Op_Kind,object:Object) -> Error {
    if !queue_room(h,0,CHANNEL_SYSTEM,AUTHORITY_MESSAGE_BYTES) || !op_push(h,{kind=kind,handle=u64(object)}) {return .Full}
    queue_count(h,0,CHANNEL_SYSTEM,AUTHORITY_MESSAGE_BYTES)
    return .None
}

// Sends an event. On a server it goes to one connection, or to every one
// that has the object when connection is zero; on a client, to the server.
// An event about no object goes to every connection. A reliable one that does
// not fit in the queue of a connection it may go to returns Full and nothing
// is sent: the caller tries again after host_poll.
event_send :: proc(h:^Host,event:Event_Id,object:Object,payload:rawptr,connection:Connection=0) -> Error {
    protocol:=h.desc.protocol
    if protocol==nil || int(event)>=len(protocol.events) || payload==nil {return .Invalid}
    if object!=0 && front_object(h,object)==nil {return .Invalid}
    type:=&protocol.events[event]
    if h.desc.mode==.Client && .From_Client not_in type.flags {return .Invalid}
    words:=h.front.words[:type.desc.words]
    mem.zero_slice(words)
    fragment_quantize(protocol,&type.desc,0,payload,words,h,front_to_reference)
    buffer:[RELIABLE_EVENT_MAX_BYTES+16]u8
    w:serial.Bit_Writer
    serial.bit_writer_init(&w,buffer[:])
    serial.bit_write(&w,u64(System_Message.Event),3)
    serial.bit_write(&w,u64(event),16)
    serial.bit_write(&w,u64(object),64)
    state_write(&w,&type.desc,type.desc.all,words,nil)
    if w.overflow {return .Too_Large}
    data:=serial.bit_writer_flush(&w)
    reliable:=.Reliable in type.flags
    if reliable && !queue_room(h,connection,CHANNEL_SYSTEM,len(data)) {return .Full}
    if !op_push(h,{kind=.Event,a=u8(reliable)|u8(.Held in type.flags)<<1,handle=u64(connection),value=u64(object)},data) {return .Full}
    if reliable {queue_count(h,connection,CHANNEL_SYSTEM,len(data))}
    return .None
}
// Fills the event's structure from an Event command.
event_read :: proc(h:^Host,command:^Command,target:rawptr) -> bool {
    protocol:=h.desc.protocol
    if command.kind!=.Event || int(command.event)>=len(protocol.events) || target==nil {return false}
    type:=&protocol.events[command.event].desc
    if len(command.words)<type.words {return false}
    fragment_dequantize(protocol,type,0,command.words,type.all,target,h,front_to_user)
    return true
}

// Fills one fragment structure from an Object_Created or Object_Updated
// command. By default only the fields that changed are written; a mask
// chooses others, since the command carries the whole state of the object.
object_read :: proc(h:^Host,command:^Command,fragment:int,target:rawptr,mask:u64=0) -> bool {
    protocol:=h.desc.protocol
    if (command.kind!=.Object_Created && command.kind!=.Object_Updated) || int(command.type)>=type_count(protocol) || target==nil {return false}
    type:=&protocol.types[command.type]
    if fragment<0 || fragment>=type.fragment_count || len(command.words)<type.words {return false}
    fragment_dequantize(protocol,type,fragment,command.words,mask==0?command.mask:mask,target,h,front_to_user)
    return true
}

// Client: the input of a tick. It is sent with the following datagrams until the server has it.
input_submit :: proc(h:^Host,tick:u32,input:rawptr) -> Error {
    protocol:=h.desc.protocol
    if h.desc.mode!=.Client || protocol==nil || !protocol.has_input || input==nil {return .Invalid}
    words:=h.front.words[:protocol.input.words]
    fragment_quantize(protocol,&protocol.input,0,input,words,h,front_to_reference)
    return op_push(h,{kind=.Input,c=tick},mem.slice_data_cast([]u8,words))?.None:.Full
}

// Server: the input a connection sent for a tick, copied to out.
input_take :: proc(h:^Host,connection:Connection,tick:u32,out:rawptr) -> Input_Status {
    f:=&h.front
    index:=int(base.handle_index(base.Handle(connection)))
    if f.input_size==0 || out==nil || connection==0 || index>=len(f.input_seen) || h.connection_handles[index]!=connection {return .None}
    size,depth:=f.input_size,input_depth(h)
    last:=f.input_last[index*size:][:size]
    slot:=index*depth+int(tick)%depth
    if f.input_ticks[slot]==tick+1 {
        copy(last,f.input_data[slot*size:][:size])
        f.input_seen[index]=true
        mem.copy(out,raw_data(last),size)
        return .Fresh
    }
    mem.copy(out,raw_data(last),size)
    return f.input_seen[index]?.Repeated:.None
}

// Closes the tick: quantizes what was marked dirty or is polled, and queues
// the frame so the network half sends it. tick is the tick just simulated.
host_publish :: proc(h:^Host,tick:u32) {
    f:=&h.front
    protocol:=h.desc.protocol
    if protocol!=nil {
        if f.binding_revision!=f.published_bindings {
            for &o,index in f.objects {
                if .Alive not_in o.flags {continue}
                fragments:=protocol.types[o.type].reference_fragments
                if fragments==0 {continue}
                for fragment in 0..<protocol.types[o.type].fragment_count {
                    if fragments&(1<<uint(fragment))!=0 && o.sources[fragment]!=nil {
                        object_mark_dirty(h,Object(base.handle_make(u32(index),o.generation)),fragment)
                    }
                }
            }
            f.published_bindings=f.binding_revision
        }
        kept:=0
        for index in f.dirty[:f.dirty_count] {
            o:=&f.objects[index]
            if .Alive not_in o.flags {o.flags-={.Listed};continue}
            if .Dormant in o.flags || !front_publish(h,o,index,o.dirty) {
                f.dirty[kept]=index
                kept+=1
                continue
            }
            o.dirty=0
            o.flags-={.Listed}
        }
        f.dirty_count=kept
        for index in f.polled[:f.poll_count] {
            o:=&f.objects[index]
            if .Dormant not_in o.flags && .Listed not_in o.flags && poll_due(o,tick) {front_publish(h,o,index,max(Fragment_Mask))}
        }
    }
    op_push(h,{kind=.Tick,c=tick})
    frame_submit(h)
}
@(private)
front_publish :: proc(h:^Host,o:^Front_Object,index:u32,fragments:Fragment_Mask) -> bool {
    if h.desc.mode==.Client && o.role!=.Held {return true}
    type:=&h.desc.protocol.types[o.type]
    object:=Object(base.handle_make(index,o.generation))
    for fragment in 0..<type.fragment_count {
        if fragments&(1<<uint(fragment))==0 || o.sources[fragment]==nil {continue}
        if !front_push_state(h,o,object,fragment,o.sources[fragment]) {return false}
    }
    return true
}

type_stats :: proc(h:^Host,type:Type_Id) -> Type_Stats {
    return int(type)<len(h.front.type_stats)?h.front.type_stats[type]:{}
}
// Bits of state sent for an object to every connection; needs Replication_Desc.object_stats.
object_bits_sent :: proc(h:^Host,object:Object) -> u64 {
    index:=int(base.handle_index(base.Handle(object)))
    return front_object(h,object)!=nil && index<len(h.front.object_bits)?h.front.object_bits[index]:0
}

@(private)
front_copy_stats :: proc(h:^Host) {
    copy(h.front.type_stats,h.shared_type_stats)
    if len(h.front.object_bits)>0 {copy(h.front.object_bits,h.back.repl.shared_bits)}
}

// Brings the simulation half up to date with what the network half reports.
@(private)
front_absorb :: proc(h:^Host,buffer:^Command_Buffer) {
    f:=&h.front
    protocol:=h.desc.protocol
    if protocol==nil {return}
    for index in buffer.released[:buffer.released_count] {
        f.state_words-=protocol.types[f.objects[index].type].words+1
        f.objects[index].flags={}
        f.free[(f.free_head+f.free_count)%len(f.free)]=index
        f.free_count+=1
    }
    if buffer.sync.valid {clock_sync(&f.clock,buffer.sync)}
    server:=h.desc.mode==.Server
    for &command in buffer.commands[:buffer.count] {
        index:=int(base.handle_index(base.Handle(command.object)))
        #partial switch command.kind {
        case .Connected:
            if server {
                if f.input_size>0 {
                    connection:=int(base.handle_index(base.Handle(command.connection)))
                    depth:=input_depth(h)
                    mem.zero_slice(f.input_ticks[connection*depth:][:depth])
                    mem.zero_slice(f.input_last[connection*f.input_size:][:f.input_size])
                    f.input_seen[connection]=false
                }
            } else {
                f.server_connection=command.connection
                f.history=int(command.tick)
                clock_reset(&f.clock)
            }
        case .Disconnected:
            if !server {
                for &o in f.objects {o={}}
                mem.zero_slice(f.user_keys)
                f.dirty_count,f.poll_count,f.server_connection=0,0,0
                f.binding_revision+=1
            }
        case .Object_Created:
            if !server && command.retyped {
                // The replica goes on: what the game bound it to stays.
                o:=&f.objects[index]
                o.type,o.role,o.simulation,o.dirty=command.type,command.role,command.simulation,0
                f.binding_revision+=1
            } else if !server {
                f.objects[index]={generation=base.handle_generation(base.Handle(command.object)),type=command.type,flags={.Alive},role=command.role,simulation=command.simulation}
            }
        case .Object_Destroyed:
            if !server {
                o:=&f.objects[index]
                user_remove(f,o.user,u32(index))
                if .Poll in o.flags {
                    f.poll_count-=1
                    moved:=f.polled[f.poll_count]
                    f.polled[o.poll_slot]=moved
                    f.objects[moved].poll_slot=o.poll_slot
                }
                o^={}
                f.binding_revision+=1
            }
        case .Role_Changed:
            if o:=front_object(h,command.object);o!=nil && !server {o.role=command.role}
        case .Input:
            connection:=int(base.handle_index(base.Handle(command.connection)))
            depth:=input_depth(h)
            slot:=connection*depth+int(command.tick)%depth
            target:=f.input_data[slot*f.input_size:][:f.input_size]
            mem.zero_slice(target)
            fragment_dequantize(protocol,&protocol.input,0,command.words,protocol.input.all,raw_data(target),h,front_to_user)
            f.input_ticks[slot]=command.tick+1
            command.data=target
        }
    }
}

// Client: lets a replica it has authority over be read at every publish, like object_create's poll.
object_set_poll :: proc(h:^Host,object:Object,poll:bool) -> Error {
    f:=&h.front
    o:=front_object(h,object)
    if o==nil {return .Invalid}
    index:=base.handle_index(base.Handle(object))
    if poll && .Poll not_in o.flags {
        o.flags+={.Poll}
        o.poll_slot=u32(f.poll_count)
        f.polled[f.poll_count]=index
        f.poll_count+=1
    } else if !poll && .Poll in o.flags {
        o.flags-={.Poll}
        f.poll_count-=1
        moved:=f.polled[f.poll_count]
        f.polled[o.poll_slot]=moved
        f.objects[moved].poll_slot=o.poll_slot
    }
    return .None
}

@(private)
bitset_set :: #force_inline proc "contextless" (bits:[]u64,index:int) {bits[index>>6]|=1<<uint(index&63)}
@(private)
bitset_clear :: #force_inline proc "contextless" (bits:[]u64,index:int) {bits[index>>6]&~=1<<uint(index&63)}
@(private)
bitset_test :: #force_inline proc "contextless" (bits:[]u64,index:int) -> bool {return bits[index>>6]&(1<<uint(index&63))!=0}
@(private)
bitset_first :: #force_inline proc "contextless" (word:u64) -> int {return int(intrinsics.count_trailing_zeros(word))}
