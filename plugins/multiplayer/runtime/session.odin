package multiplayer

import "base:runtime"
import "core:crypto"
import "core:crypto/sha2"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "mirai:core"
import input "mirai:engine/input"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import wire "mirai:net"

// The network of a world: one wire.Host, the protocol of the replicated
// components and the messages the generator found, and what the server and the
// client keep besides the rest of the world. Each world has its own, so the
// runs of an editor serve or join games apart, each on its port. Copying a
// world leaves the session of the copy as it was: a correction restores the
// World and keeps the network that is talking, and a world made by copy
// opens its own.

Status :: enum u8 {Offline,Connecting,Connected,Disconnected}

Open_Error :: enum u8 {
    None,
    Transport_Failed, // the socket could not be opened, or the address is not one
    Protocol_Failed,  // a replicated component or a message does not fit the protocol
    Host_Failed,
    Out_Of_Memory,
}

Net_Stats :: struct {
    objects:int,              // server: entities replicated. Client: replicas with an entity
    predicted,interpolated:int,
    spawned,despawned:u64,    // client: entities made for a replica, or taken from the scene, and released
    events_received,events_sent:u64,
    events_dropped:u64,       // arrived while the game was paused and Net_Events held PAUSED_EVENTS
    confirmed,corrected,snapped:u64, // client: states of the server that matched the prediction, that were replayed, that were taken as they came
    resimulated:u64,          // client: ticks simulated again
    largest_resimulation:int,
    blended:u64,              // client: errors taken into the present without simulating again: closed over the ticks that follow
    placed:u64,               // client: of them, those that put the replica where the server had it at once: at rest, or too far to close
    fragments_published:u64,
    references_deferred,references_resolved:u64,
    deferred:u64,             // client: corrections that were closed over the next ticks because they were out of the history, of the frame or of the budget
    rewound:u64,              // client: times the world went back to a tick a library asked for (rewind)
    views_corrected:u64,      // server: views a client said it saw that Net_Settings.rewind_tolerance replaced
    unverified:u64,           // client: server states older than the history, which could not be compared
    overtaken:u64,            // client: of them, the newest of a replica in a frame, which put it where the server had it, carried to the present
    history_resets:u64,       // client: times the history was dropped: a jump of the clock
    sync_tested:u64,          // client: ticks run again by sync_test
    sync_skipped:u64,         // client: of them, those the network gave something else, which are not compared: a state of the server came after they ran
    snapshot_bytes:int,       // client: size of one world snapshot
    snapshot_seconds:f64,     // client: spent saving them, in total
    resimulate_seconds:f64,   // client: spent in corrections, in total
}

// The fragments of the protocol, before those of the replicated components.
@(private) FRAGMENT_POSE :: wire.Fragment_Id(0)
@(private) FRAGMENT_MOTION :: wire.Fragment_Id(1)
@(private) FRAGMENT_DRIVER :: wire.Fragment_Id(2)

// What a type of the protocol holds where: its fragments, as this end reads them.
@(private)
Net_Type :: struct {
    known:bool,
    fits:bool,  // its components fit tables: false only for a creation no end of this build makes
    type:wire.Type_Id,
    motion:int, // fragment of Motion_State; -1: no simulation moves it
    driver:int, // fragment of Driver_State; -1: it has no Move_Input
    first:int,  // fragment of the first component
    tables:[COMPONENTS]int, // by component: index in the tables of the world info
    count:int,
    references:wire.Fragment_Mask,
}

@(private)
Net_Event :: struct {type:typeid,size:int,reliable:bool}

// The messages of the session itself, by their place among the messages; the
// world follows the server's only when the protocol has them all (a world the
// generator made).
@(private)
Own_Events :: struct {
    world,ready,player,section,gone:int,
}

// What an end of a game asks to open: a server on a port, or a client of an
// invitation or an address, over a link that may be made worse.
Open_Request :: struct {
    server:bool,
    port:int,          // server: 0: Net_Settings.port
    invite:bool,       // server: it lets in only who brings its invitation
    invite_token:u32,  // of it; 0: one is made, the port is mapped on the router and the network says the code
    connect:[96]u8 `mirai:"text"`, // client: the code of an invitation, or an address
    latency,jitter:f64, // seconds a datagram is delayed each way, and how much that varies
    loss:f32,          // share of the datagrams lost each way
    timeout:f64,       // seconds of silence that end a connection or an attempt; 0: those of the settings. A world that advances only when asked waits longer
    new_player:bool,   // client: a player of this world alone, which the session makes and keeps while the world lives, instead of the one of the profile (Net_Identity): one of several clients of a machine
}

// What a World opens on the network before its first frame: whoever runs it
// asks (the editor part of this plugin, for each run of the editor);
// without asking, what the application was launched with (launch_read).
@(storage,keep)
Session_Request :: struct {
    open:Open_Request,
}

// The network of a World: each one serves, joins or opens nothing on its own.
// The application keeps one for each World (by_world), outside it: the
// sockets do not go with a copy of the World, and it closes when the World is freed.
@(storage,host,by_world,free="session_free")
Net_Session :: struct {
    problems:^core.Problems, // of the World while a step of the network runs, nil outside
    opened:bool,
    launched:bool,    // it opened what the player was launched with: it tells the player how it stands
    until_empty:bool, // launched: a server that ends when the last of the connections it had leaves
    status_path:string, // launched: a file it appends its state to
    wanted:Open_Request,
    mode:wire.Mode,
    allocator:runtime.Allocator,
    desc:Net_Settings,
    schema:serial.Schema,
    protocol:wire.Protocol,
    host:wire.Host,
    host_ready,built:bool,
    udp:wire.Udp,
    conditioner:wire.Conditioner, // between the socket and the host when the launch asks for a worse link
    types:[]Net_Type,           // by type of the protocol
    fragments:[]wire.Fragment_Id, // by table of the world info: the fragment of a replicated component
    events:[]Net_Event,
    own:Own_Events,
    follows:bool, // the protocol has the messages of the session: a client follows the scene of its server
    secret:[2]u64, // client: of the player it presents (Net_Player); kept while the World lives
    arrived:[dynamic]Connection_Event, // since the last tick began: Net_Connections of the next one
    scratch:[]u8, // one event or one component
    placed:u32,   // the places it asked of core.Pose_Target: each a new number
    taken:u32,    // client: the last place asked before a tick began, which its simulation took
    address:string,
    port:int,       // server: of the socket
    invite:u32,     // server: the token a client must bring, 0: anyone joins; client: the one it brings
    invite_code:string, // server: the code of the invitation, once the router answered
    mapping:wire.Port_Mapping, // server: of the port, when it made its own invitation
    mapping_on:bool,
    now:f64,
    status:Status,
    reason:Disconnect_Reason,
    reason_text:string,
    refusal:[256]u8, // why the libraries describe no protocol, for the session that did not open
    connections:int,
    joined,left,lost:u64,
    stats:Net_Stats,
    ended:bool,
    events_held:bool, // pump left in Net_Events what no frame read yet
    server:Server,
    client:Client,
    status_file:^os.File,
    status_tick:u64,
    status_ticks:u64, // ticks between two blocks of the status file: --status-ticks, 60 by default
    info:^core.World_Info,
    told:Told,
}

// What a launched session already printed.
@(private)
Told :: struct {
    joined,lost,served,invited:bool,
    seen,refused:u64,
}

// The UDP port of the game: Net_Settings.port, or DEFAULT_PORT for 0. valid
// is false for one that is not a UDP port.
settings_port :: proc(settings:Net_Settings) -> (port:int,valid:bool) {
    if settings.port<0 || settings.port>65535 {return DEFAULT_PORT,false}
    return settings.port>0?settings.port:DEFAULT_PORT,true
}

// The default of what Net_Settings leaves at zero.
@(private)
settings_resolve :: proc(settings:Net_Settings,tick_dt:f32) -> (d:Net_Settings) {
    d=settings
    if d.protocol_id==0 {d.protocol_id=NET_PROTOCOL_ID}
    if d.port<=0 {d.port=DEFAULT_PORT}
    if d.max_clients<=0 {d.max_clients=32}
    if d.max_objects<=0 {d.max_objects=1024}
    if d.predicted_capacity<=0 {d.predicted_capacity=256}
    if d.view_radius<=0 {d.view_radius=128}
    if d.position_tolerance<=0 {d.position_tolerance=0.05}
    if d.velocity_tolerance<=0 {d.velocity_tolerance=0.5}
    if d.rotation_tolerance<=0 {d.rotation_tolerance=0.07}
    if d.scale_tolerance<=0 {d.scale_tolerance=0.001}
    if d.resimulate_budget<=0 {d.resimulate_budget=int(1/tick_dt+0.5)}
    if d.critical_ticks<=0 {d.critical_ticks=int(0.5/tick_dt+0.5)}
    if d.max_resimulate<=0 {d.max_resimulate=int(0.3/tick_dt+0.5)}
    if d.correction_time<=0 {d.correction_time=0.1}
    if d.rewind_tolerance==0 {d.rewind_tolerance=0.2}
    d.sync_test=max(d.sync_test,0)
    return
}

// Opens a server or a client from what the World was asked to open
// (Session_Request), or else from what the player was launched with, the
// first time it runs.
@(private)
session_start :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,settings:^Net_Settings) {
    s.opened=true
    s.info=w.info
    s.allocator=app.allocator
    if request:=core.world_storage_of(w,Session_Request);request!=nil && (request.open.server || request.open.connect[0]!=0) {
        s.wanted=request.open
    } else {
        if !launch_read(s,app) {
            host.app_exit(app,host.PLAYER_USAGE)
            return
        }
        s.launched=true
    }
    wanted:=&s.wanted
    connect:=base.text_get(wanted.connect[:])
    if !wanted.server && connect=="" {return}
    if s.launched {
        // A session keeps the time of the clock, and a client holds the script of the player until it joins.
        host.app_real_time(app)
        if !wanted.server {app.script_hold=true}
    }
    s.mode=wanted.server?.Server:.Client
    s.desc=settings_resolve(settings^,app.tick_dt)
    port:=wanted.port>0?wanted.port:s.desc.port
    if _,valid:=settings_port(settings^);!valid {
        core.report(s.problems,core.NONE,"net.settings","the network did not open: Net_Settings.port %d is not a UDP port; give it one from 1 to 65535, or 0 for %d",settings.port,DEFAULT_PORT)
        session_fail(s,app.allocator,fmt.tprintf("the network did not open: Net_Settings.port %d is not a UDP port",settings.port))
        return
    }
    if wanted.timeout>0 {s.desc.timeout,s.desc.connect_timeout=wanted.timeout,wanted.timeout}
    if s.launched {s.told={}}
    error,refused:=session_open(s,w,app,port)
    switch error {
    case .None:
    case .Transport_Failed:
        if wanted.server {session_fail(s,app.allocator,fmt.tprintf("could not open the UDP port %d: is another server on it?",port))}
        else {session_fail(s,app.allocator,fmt.tprintf("\"%s\" is neither an invitation nor an address: give a code like K7Q2-9XMA-PL3F-0B2C, 1.2.3.4:27500 or [::1]:27500",connect))}
    case .Protocol_Failed:
        if refusal:=base.text_get(s.refusal[:]);refusal!="" {
            session_fail(s,app.allocator,fmt.tprintf("the libraries do not describe a network protocol: %s",refusal))
        } else {
            session_fail(s,app.allocator,"the libraries do not describe a network protocol: a replicated component or a message does not fit in a datagram")
        }
    case .Host_Failed,.Out_Of_Memory:
        if refused.field!="" {
            owner,field:=setting_of(refused.field)
            core.report(s.problems,core.NONE,"net.settings","the network did not open: %s%s is out of its range (%s); change it",owner,field,refused.range)
            session_fail(s,app.allocator,fmt.tprintf("the network did not open: %s%s is out of its range (%s)",owner,field,refused.range))
        } else {session_fail(s,app.allocator,fmt.tprintf("the network did not open: %v",error))}
    }
    if s.launched && s.status_path!="" && s.opened && s.status!=.Disconnected {
        file,open_error:=os.open(s.status_path,{.Write,.Create,.Append},os.Permissions_Default_File)
        if open_error==nil {s.status_file=file}
    }
}

// Keeps a copy of why the session ended, for a person; without memory for
// it, the problems say it.
@(private)
reason_keep :: proc(s:^Net_Session,allocator:runtime.Allocator,reason:string) {
    delete(s.reason_text,allocator)
    error:runtime.Allocator_Error
    if s.reason_text,error=strings.clone(reason,allocator);error!=nil {
        core.report(s.problems,core.NONE,"net.reason","the session ended and there is no memory to keep why: %s",reason)
    }
}

@(private)
session_fail :: proc(s:^Net_Session,allocator:runtime.Allocator,reason:string) {
    log.errorf("net: %s",reason)
    reason_keep(s,allocator,reason)
    s.status=.Disconnected
    s.ended=true
    session_destroy(s)
}

@(private)
session_open :: proc(s:^Net_Session,w:core.World_Ref,app:^host.App,port:int) -> (error:Open_Error,refused:wire.Refusal) {
    allocator:=app.allocator
    d:=&s.desc
    target:wire.Address
    if s.mode==.Server {
        if !wire.udp_open(&s.udp,wire.address_any6(port)) {return .Transport_Failed,{}}
        s.port=int(s.udp.address.port)
        if s.wanted.invite {
            s.invite=s.wanted.invite_token
            if s.invite==0 {
                s.invite=wire.invite_token()
                s.mapping_on=wire.mapping_start(&s.mapping,u16(s.port))
            }
        }
    } else {
        parsed:bool
        connect:=base.text_get(s.wanted.connect[:])
        if target,s.invite,parsed=wire.invite_decode(connect);!parsed {
            target,parsed=wire.address_parse(connect)
        }
        if !parsed {return .Transport_Failed,{}}
        if target.port==0 {target.port=u16(port)}
        bind:=target.kind==.IP6?wire.address_any6(0):wire.address_ip4(0,0,0,0,0)
        if !wire.udp_open(&s.udp,bind) {return .Transport_Failed,{}}
        no_address:runtime.Allocator_Error
        if s.address,no_address=strings.clone(connect,allocator);no_address!=nil {
            session_destroy(s)
            return .Out_Of_Memory,{}
        }
    }
    if !protocol_build(s,w) {
        session_destroy(s)
        return .Protocol_Failed,{}
    }
    transport:=wire.udp_transport(&s.udp)
    wanted:=&s.wanted
    if wanted.latency>0 || wanted.jitter>0 || wanted.loss>0 {
        conditions:=wire.Sim_Conditions{latency=wanted.latency,jitter=wanted.jitter,loss=wanted.loss}
        if !wire.conditioner_init(&s.conditioner,transport,conditions,{seed=d.seed,allocator=allocator}) {
            session_destroy(s)
            return .Out_Of_Memory,{}
        }
        transport=wire.conditioner_transport(&s.conditioner)
    }
    host_desc:=wire.Host_Desc{
        mode=s.mode,transport=transport,protocol=&s.protocol,protocol_id=d.protocol_id,version=d.version,
        seed=d.seed,invite=s.invite,max_connections=d.max_clients,tick_rate=int(1/app.tick_dt+0.5),replication=d.replication,allocator=allocator,
        timeout=d.timeout,connect_timeout=d.connect_timeout,hold=s.follows,
    }
    host_desc.replication.max_objects=d.max_objects
    host_desc.frame_ops=max(4096,d.max_objects*8)
    host_desc.frame_bytes=max(256<<10,d.max_objects*512)
    if wire.host_init(&s.host,host_desc)!=.None {
        refused=s.host.refused
        session_destroy(s)
        return .Host_Failed,refused
    }
    s.host_ready=true
    if s.arrived==nil {s.arrived=make([dynamic]Connection_Event,allocator)}
    ready:=s.mode==.Server?server_init(s,allocator):client_init(s,w,app.allocator)
    if !ready {
        session_destroy(s)
        return .Out_Of_Memory,{}
    }
    world_seen(s,w)
    if s.mode==.Client {
        if wire.host_connect(&s.host,target)!=.None {
            session_destroy(s)
            return .Host_Failed,{}
        }
        s.status=.Connecting
    } else {
        s.status=.Connected
    }
    return .None,{}
}

// Where a game changes a field of the Host_Desc the session gives its host;
// the rest the session sets itself.
@(private)
setting_of :: proc(field:string) -> (owner,name:string) {
    switch {
    case field=="max_connections":                return "Net_Settings.","max_clients"
    case field=="replication.max_objects":        return "Net_Settings.","max_objects"
    case strings.has_prefix(field,"replication."): return "Net_Settings.",field
    }
    return "Host_Desc.",field
}

// The libraries described no protocol: the problem says why and how to fix
// it, and the session that does not open gives the same reason. False.
@(private)
protocol_refuse :: proc(s:^Net_Session,format:string,args:..any) -> bool {
    text:=fmt.tprintf(format,..args)
    core.report(s.problems,core.NONE,"net.protocol","%s",text)
    base.text_set(s.refusal[:],text)
    return false
}

// The fragments of the protocol: the pose, the motion and the driver, then
// every replicated component and every message, in the order the generator
// gives them, which is the same on both ends of one build: the hash they
// compare says so.
@(private)
protocol_build :: proc(s:^Net_Session,w:core.World_Ref) -> bool {
    allocator:=s.allocator
    s.refusal={}
    s.built=true
    serial.schema_init(&s.schema,allocator)
    wire.protocol_init(&s.protocol,allocator) or_return
    pose:=serial.schema_add(&s.schema,Pose) or_return
    motion:=serial.schema_add(&s.schema,Motion_State) or_return
    driver:=serial.schema_add(&s.schema,Driver_State) or_return
    input:=serial.schema_add(&s.schema,Input_Packet) or_return
    _=wire.fragment_register(&s.protocol,"pose",{schema=&s.schema,type=pose}) or_return
    _=wire.fragment_register(&s.protocol,"motion",{schema=&s.schema,type=motion}) or_return
    _=wire.fragment_register(&s.protocol,"driver",{schema=&s.schema,type=driver}) or_return
    largest:=size_of(Received)
    fragments,fragments_error:=make([]wire.Fragment_Id,len(w.info.tables),allocator)
    if fragments_error!=nil {return false}
    s.fragments=fragments
    for &info,table in w.info.tables {
        s.fragments[table]=wire.FRAGMENT_NONE
        if info.replicated==.None || info.place!=.World {continue}
        type,ok:=serial.schema_add_type_info(&s.schema,info.info)
        if !ok {return protocol_refuse(s,"%s does not fit the protocol: %s",info.name,s.schema.error)}
        condition:=info.replicated==.Owner?wire.Fragment_Condition.Owner:info.replicated==.Others?.Not_Owner:.All
        registered:bool
        s.fragments[table],registered=wire.fragment_register(&s.protocol,info.name,{schema=&s.schema,type=type,condition=condition})
        if !registered {return protocol_refuse(s,"%s does not fit the protocol: it replicates no field, or its fields take more than a state carries; mark local what need not travel",info.name)}
        largest=max(largest,info.info.size)
    }
    events,events_error:=make([]Net_Event,len(w.info.messages),allocator)
    if events_error!=nil {return false}
    s.events=events
    s.own={-1,-1,-1,-1,-1}
    for message,index in w.info.messages {
        switch message.type {
        case Net_World:       s.own.world=index
        case Net_World_Ready: s.own.ready=index
        case Net_Player:      s.own.player=index
        case Net_Section:     s.own.section=index
        case Net_Gone:        s.own.gone=index
        }
        if message.info.size>EVENT_BYTES {return protocol_refuse(s,"message %s takes %d bytes, and a message %d; send less in it",message.name,message.info.size,EVENT_BYTES)}
        type,ok:=serial.schema_add_type_info(&s.schema,message.info)
        if !ok {return protocol_refuse(s,"message %s does not fit the protocol: %s",message.name,s.schema.error)}
        flags:wire.Event_Flags
        if message.reliable {flags+={.Reliable}}
        // A connection hears the world it is to load while it is held; nothing else of the game reaches it.
        if message.type==Net_World {flags+={.Held}}
        switch message.from {
        case .Server:
        case .Client: flags+={.From_Client}
        case .Owner:  flags+={.From_Client,.Owner_Only}
        }
        name:=fmt.tprintf("%s.%s",message.library,message.name)
        event,registered:=wire.event_register(&s.protocol,name,&s.schema,type,flags)
        if !registered || int(event)!=index {return protocol_refuse(s,"message %s does not fit a datagram; send less in it",message.name)}
        s.events[index]={type=message.type,size=message.info.size,reliable=message.reliable}
    }
    s.follows=s.own.world>=0 && s.own.ready>=0 && s.own.player>=0 && s.own.section>=0 && s.own.gone>=0
    wire.input_register(&s.protocol,&s.schema,input) or_return
    _=wire.protocol_seal(&s.protocol) or_return
    types,types_error:=make([]Net_Type,wire.TYPE_CAPACITY,allocator)
    if types_error!=nil {return false}
    s.types=types
    error:runtime.Allocator_Error
    s.scratch,error=make_aligned_bytes(largest,allocator)
    return error==nil
}

// What a type of the protocol holds where, the first time this end meets it.
@(private)
net_type :: proc(s:^Net_Session,type:wire.Type_Id) -> ^Net_Type {
    t:=&s.types[type]
    if t.known {return t}
    t^={known=true,fits=true,type=type,motion=-1,driver=-1,first=-1}
    for kind,fragment in wire.type_kinds(&s.protocol,type) {
        switch kind {
        case FRAGMENT_POSE:
        case FRAGMENT_MOTION: t.motion=fragment
        case FRAGMENT_DRIVER: t.driver=fragment
        case:
            if t.first<0 {t.first=fragment}
            if t.count==COMPONENTS {t.fits=false;continue}
            for owner,table in s.fragments {
                if owner!=kind {continue}
                t.tables[t.count]=table
                t.count+=1
                break
            }
        }
    }
    if t.first<0 {t.first=len(wire.type_kinds(&s.protocol,type))}
    t.references=s.protocol.types[type].reference_fragments
    return t
}

@(private)
make_aligned_bytes :: proc(size:int,allocator:runtime.Allocator) -> ([]u8,runtime.Allocator_Error) {
    return runtime.mem_alloc_bytes(max(size,16),16,allocator)
}

// Releases the host, the socket and everything the protocol needed.
@(private)
session_destroy :: proc(s:^Net_Session) {
    allocator:=s.allocator
    client_destroy(s)
    server_destroy(s)
    if s.host_ready {
        if s.status==.Connected || s.status==.Connecting {
            wire.host_disconnect(&s.host)
            wire.host_update(&s.host,s.now)
        }
        wire.host_destroy(&s.host)
        s.host_ready=false
    }
    if s.conditioner.allocator.procedure!=nil {wire.conditioner_destroy(&s.conditioner)}
    if s.udp.open {wire.udp_close(&s.udp)}
    if s.built {
        wire.protocol_destroy(&s.protocol)
        serial.schema_destroy(&s.schema)
        s.built=false
    }
    delete(s.types,allocator);s.types=nil
    delete(s.fragments,allocator);s.fragments=nil
    delete(s.events,allocator);s.events=nil
    delete(s.arrived);s.arrived=nil
    delete(s.scratch,allocator);s.scratch=nil
    delete(s.address,allocator);s.address=""
    delete(s.invite_code,allocator);s.invite_code=""
    if s.mapping_on {wire.mapping_close(&s.mapping)}
    s.mapping_on=false
    if s.status_file!=nil {
        os.close(s.status_file)
        s.status_file=nil
    }
}

// Leaves the network: the entities stay as they are.
close :: proc(s:^Net_Session) {
    if !s.opened || s.status==.Offline && !s.host_ready {return}
    session_destroy(s)
    s.status=.Offline
}

// Why a client is without its server, for a person, in the temporary allocator.
@(private)
reason_text :: proc(reason:Disconnect_Reason,address:string,protocol:u64) -> string {
    #partial switch reason {
    case .Connect_Timeout:   return fmt.tprintf("the server %s does not answer",address)
    case .Denied_Protocol:   return fmt.tprintf("the server %s refused the connection: its libraries do not produce the same network protocol as those of this project (here %016x); build both ends from the same sources",address,protocol)
    case .Denied_Version:    return fmt.tprintf("the server %s refused the connection: it is of another version",address)
    case .Denied_Full:       return fmt.tprintf("the server %s is full",address)
    case .Denied_Invite:     return fmt.tprintf("the server %s refused the connection: the invitation is not the one of its game",address)
    case .Denied_Security:   return fmt.tprintf("the server %s refused the connection: one end encrypts and the other does not",address)
    case .Closed:            return fmt.tprintf("the server %s closed the connection",address)
    case .Timeout:           return fmt.tprintf("the connection to the server %s was lost: it stopped answering",address)
    case .Kicked:            return fmt.tprintf("the server %s kicked this client",address)
    case .Replaced:          return fmt.tprintf("the server %s took another connection of the same player",address)
    case .Denied_Player:     return fmt.tprintf("the server %s refused the connection: this client presented no player, or two",address)
    case .Capacity:          return fmt.tprintf("the connection to the server %s ended: this client has no room for what the server has (more objects than Net_Settings.max_objects, or a history longer than %v s at its tick rate); raise them, or lower them on the server",address,wire.HISTORY_MAX_SECONDS)
    }
    return fmt.tprintf("the connection to the server %s was lost: %v",address,reason)
}

// Tells whoever launched the player how the network stands, and ends the
// player when the session cannot go on: a client that did not join, or lost
// its server with no window to show it; a server that could not open, or
// emptied with --until-empty. The scripted input of a client waits until it joins.
@(private)
report_update :: proc(s:^Net_Session,app:^host.App) {
    invited:=invite_update(s)
    if !s.launched {return}
    told:=&s.told
    // By the end of the session and not by the text of its reason, which may have found no memory.
    lost:=s.status==.Disconnected && s.ended
    if lost && !told.lost {
        told.lost=true
        if s.reason_text!="" {fmt.eprintfln("mirai: %s",s.reason_text)}
        else {fmt.eprintln("mirai: the session ended, and there was no memory to keep why")}
    }
    if s.mode==.Client {
        if s.status==.Connected && !told.joined {
            told.joined=true
            app.script_hold=false
            fmt.printfln("mirai: connected to %s",base.text_get(s.wanted.connect[:]))
        }
        if lost && (!told.joined || app.platform==nil || app.platform.headless) {host.app_exit(app,PLAYER_NET)}
        return
    }
    if lost {
        host.app_exit(app,PLAYER_NET)
        return
    }
    if !s.host_ready {return}
    if !told.served {
        told.served=true
        fmt.printfln("mirai: server on UDP port %d, protocol %016x",s.port,s.protocol.hash)
    }
    if invited {fmt.printfln("mirai: invitation %s",s.invite_code)}
    if s.joined+s.left!=told.seen {
        told.seen=s.joined+s.left
        fmt.printfln("mirai: %d connections (%d arrived, %d left, %d without notice)",s.connections,s.joined,s.left,s.lost)
    }
    if refused:=s.host.stats.handshakes_refused;refused!=told.refused {
        told.refused=refused
        fmt.printfln("mirai: %d connection attempts refused: another version, another protocol, without the invitation or a full server",refused)
    }
    if s.until_empty && s.joined>0 && s.connections==0 {host.app_exit(app,host.PLAYER_OK)}
}

// One block of the status file: the session, then every replicated entity
// by its object of the network, which is the same number on every end.
@(private)
status_write :: proc(s:^Net_Session,w:core.World_Ref,frame:u64,tick:u64,problems:int) {
    file:=s.status_file
    if file==nil {return}
    rtt:=0.0
    if s.mode==.Client && s.host_ready {rtt=wire.clock_state(&s.host).rtt*1000}
    // The UDP bytes of the whole host both ways: the bandwidth of a run.
    sent,received:u64
    if s.host_ready {
        totals:=wire.host_stats(&s.host)
        sent,received=totals.bytes_sent,totals.bytes_received
    }
    // Of the client, how far its tick runs ahead of the estimate of the
    // server's and why (bias, jitter), and the corrections it could not
    // replay (deferred) or not even compare (unverified).
    ahead,bias,jitter,margin,margin_low:f64
    if s.mode==.Client && s.host_ready {
        clock:=wire.clock_state(&s.host)
        ahead,bias,jitter=f64(tick)-clock.server,clock.bias,clock.jitter*1000
        margin,margin_low=wire.clock_margin_take(&s.host)
    }
    os.write_string(file,fmt.tprintf("status frame=%d tick=%d role=%v net=%v reason=%v connections=%d joined=%d left=%d lost=%d objects=%d problems=%d resimulations=%d blended=%d rtt_ms=%.0f sent=%d received=%d ahead=%.1f bias=%.1f jitter_ms=%.0f deferred=%d unverified=%d overtaken=%d history_resets=%d margin=%.0f margin_low=%.0f views_corrected=%d\n",
        frame,tick,s.mode,s.status,s.reason,s.connections,s.joined,s.left,s.lost,s.stats.objects,problems,s.stats.corrected,s.stats.blended,rtt,sent,received,ahead,bias,jitter,s.stats.deferred,s.stats.unverified,s.stats.overtaken,s.stats.history_resets,margin,margin_low,s.stats.views_corrected))
    transforms:=core.world_table_of(w,core.Transform)
    line :: proc(file:^os.File,transforms:^core.Table(core.Transform),object:Object,e:core.Entity,own:bool) {
        local,ok:=core.get(transforms,e)
        if !ok {return}
        os.write_string(file,fmt.tprintf("object %d %d %.3f %.3f %.3f\n",u64(object),int(own),local.position.x,local.position.y,local.position.z))
    }
    if s.mode==.Server {
        for &slot in s.server.objects {
            if slot.object!=0 {line(file,transforms,slot.object,slot.entity,slot.owner!=0)}
        }
    } else {
        for &r in s.client.replicas[:s.client.replica_high] {
            if r.object!=0 {line(file,transforms,r.object,r.entity,r.role==.Predicted)}
        }
    }
    os.write_string(file,"end\n")
    os.flush(file)
}

// Whether this application serves a session now.
is_server :: proc(s:core.Ref(Net_Session)) -> bool {return s.host_ready && s.mode==.Server}

// The code of the invitation of a server, once the router answered. True when it was made now.
@(private)
invite_update :: proc(s:^Net_Session) -> bool {
    if !s.host_ready || s.mode!=.Server || s.invite==0 || s.invite_code!="" {return false}
    if s.mapping_on && wire.mapping_poll(&s.mapping).phase==.Pending {return false}
    s.invite_code=wire.invite_encode(wire.address_reachable(&s.mapping,s.mapping_on,s.port),s.invite,s.allocator)
    return true
}

// The code of the invitation of this server, for the game to show: empty
// without one (--invite), and while the router is still being asked.
invite_code :: proc(s:core.Ref(Net_Session)) -> string {return s.invite_code}

// Whether this application is a client of a session now.
is_client :: proc(s:core.Ref(Net_Session)) -> bool {return s.host_ready && s.mode==.Client}

// The ticks the session can go back: how far a correction of the client and the lag
// compensation of the server reach (Net_Settings.replication.history_seconds, the server's on a
// client). 0 without a network.
session_history :: proc(s:core.Ref(Net_Session)) -> int {return s.ptr!=nil && s.host_ready?wire.host_history(&s.host):0}

// Client: its connection as the server names it, the peer of its seat
// (input.Seat.peer); 0 until the server said it.
own_connection :: proc(s:core.Ref(Net_Session)) -> Connection {return s.host_ready && s.mode==.Client?s.client.connection:0}

// Server: where a connection that owns no entity looks from. Entities of Near
// relevance within radius meters reach it; a negative radius reaches all of them,
// which is what a connection gets until it has a view. What a connection owns
// gives it its view and replaces this one.
view_set :: proc(s:^Net_Session,connection:Connection,position:[3]f32,radius:f32) -> bool {
    return s.host_ready && wire.connection_set_view(&s.host,connection,position,radius)==.None
}

// Server: whether a connection sees an entity of Custom relevance. An entity
// whose object the network makes at the end of this tick takes it then. A new
// object and a connection that arrives start with none. False on a client and
// when the requests waiting for their objects fill Net_Settings.max_objects.
relevance_set :: proc(s:^Net_Session,e:core.Entity,connection:Connection,relevant:bool) -> bool {
    if !s.host_ready || s.mode!=.Server || connection==0 {return false}
    return server_relevance(s,e,connection,relevant)
}

// Client: asks for the simulation of a Lent entity, or gives it back.
authority_request :: proc(s:^Net_Session,e:core.Entity) -> bool {
    return s.host_ready && wire.authority_request(&s.host,wire.object_of_user(&s.host,u64(e)))==.None
}
authority_release :: proc(s:^Net_Session,e:core.Entity) -> bool {
    return s.host_ready && wire.authority_release(&s.host,wire.object_of_user(&s.host,u64(e)))==.None
}

// Server: lends the simulation of a Lent entity to a connection; zero takes it back.
authority_grant :: proc(s:^Net_Session,e:core.Entity,connection:Connection) -> bool {
    return s.host_ready && wire.authority_grant(&s.host,wire.object_of_user(&s.host,u64(e)),connection)==.None
}

// The actions a connection sent for the tick being simulated.
remote_input :: proc(inputs:core.Ref(Remote_Inputs),connection:Connection) -> (actions:input.Remote_Actions,status:wire.Input_Status) {
    entry:=remote_entry(inputs.ptr,connection)
    if entry==nil {return}
    return entry.actions,entry.status
}

// The entry of a connection, by its index; nil without one.
@(private)
remote_entry :: proc "contextless" (inputs:^Remote_Inputs,connection:Connection) -> ^Remote_Input {
    index:=object_index(Object(connection))
    if inputs==nil || connection==0 || index>=len(inputs.entries) || inputs.entries[index].connection!=connection {return nil}
    return &inputs.entries[index]
}

@(private)
object_index :: #force_inline proc "contextless" (object:Object) -> int {return int(base.handle_index(base.Handle(object)))}

// The network of a world, when it ends.
session_free :: proc(s:^Net_Session) {
    if s.opened {session_destroy(s)}
}

#assert(crypto.HAS_RAND_BYTES)

// The secret of a new player: 128 random bits.
@(private)
secret_new :: proc() -> (secret:[2]u64) {
    for secret=={} {crypto.rand_bytes(mem.ptr_to_bytes(&secret))}
    return
}

// The id of the player of a secret: its hash, which tells nothing of the
// secret; never 0.
@(private)
player_id :: proc(secret:[2]u64) -> u64 {
    secret:=secret
    digest:[sha2.DIGEST_SIZE_256]u8
    hashing:sha2.Context_256
    sha2.init_256(&hashing)
    sha2.update(&hashing,mem.ptr_to_bytes(&secret))
    sha2.final(&hashing,digest[:])
    id:=(^u64)(&digest[0])^
    return id!=0?id:1
}

// The arguments of the player the network reads: --server [port], --dedicated
// (a server nobody plays on), --invite [token], --connect <invitation or
// address>, --new-player, --until-empty, --status <file> (every --status-ticks
// <n> ticks) and a link worse than the real one, --latency <ms>,
// --jitter <ms> and --loss <percent>. False, after saying why, when one has a
// value it does not take.
@(private)
launch_read :: proc(s:^Net_Session,app:^host.App) -> bool {
    launch:=&app.launch
    wanted:=&s.wanted
    fail :: proc(text:string) -> bool {
        fmt.eprintfln("mirai: %s",text)
        return false
    }
    if _,on:=host.launch_flag(launch,"--dedicated");on {wanted.server=true}
    if at,on:=host.launch_flag(launch,"--server");on {
        wanted.server=true
        if text,given:=host.launch_value(launch,at);given {
            port,numeric:=strconv.parse_int(text,10)
            if !numeric || port<=0 || port>65535 {return fail("--server takes a UDP port from 1 to 65535")}
            wanted.port=port
        }
    }
    if at,on:=host.launch_flag(launch,"--invite");on {
        wanted.invite=true
        if text,given:=host.launch_value(launch,at);given {
            token,parsed:=strconv.parse_u64(text,16)
            if !parsed || token==0 || token>=1<<24 {return fail("--invite takes a nonzero 24-bit hexadecimal token")}
            wanted.invite_token=u32(token)
        }
    }
    if at,on:=host.launch_flag(launch,"--connect");on {
        text,given:=host.launch_value(launch,at)
        if !given || len(text)>=len(wanted.connect) {return fail("--connect takes the code of an invitation (K7Q2-9XMA-PL3F-0B2C) or an address (1.2.3.4:27500)")}
        base.text_set(wanted.connect[:],text)
    }
    if wanted.server && wanted.connect[0]!=0 {return fail("--server or --dedicated and --connect do not go together: a player serves the game or joins one")}
    if _,on:=host.launch_flag(launch,"--new-player");on {
        if wanted.server {return fail("--new-player is of a client: a player of this run alone instead of the one of its profile, for several clients on one machine; it goes with --connect")}
        wanted.new_player=true
    }
    if _,on:=host.launch_flag(launch,"--until-empty");on {
        if !wanted.server {return fail("--until-empty is for a server: add --server")}
        s.until_empty=true
    }
    if at,on:=host.launch_flag(launch,"--status");on {
        text,given:=host.launch_value(launch,at)
        if !given {return fail("--status takes the file the network status is appended to")}
        no_path:runtime.Allocator_Error
        if s.status_path,no_path=strings.clone(text,app.allocator);no_path!=nil {return fail("there is no memory for the file of --status")}
    }
    if at,on:=host.launch_flag(launch,"--status-ticks");on {
        text,given:=host.launch_value(launch,at)
        every,numeric:=strconv.parse_int(text,10)
        if !given || !numeric || every<1 || every>100_000 {return fail("--status-ticks takes the ticks between two blocks of the status file, from 1")}
        s.status_ticks=u64(every)
    }
    for flag in ([3]string{"--latency","--jitter","--loss"}) {
        at,on:=host.launch_flag(launch,flag)
        if !on {continue}
        text,given:=host.launch_value(launch,at)
        amount,parsed:=strconv.parse_f64(text)
        if !given || !parsed || amount<0 || amount!=amount || flag=="--loss" && amount>100 || amount>10_000 {
            return fail(fmt.tprintf("%s takes %s",flag,flag=="--loss"?"a percentage from 0 to 100":"milliseconds from 0 to 10000"))
        }
        switch flag {
        case "--latency": wanted.latency=amount/1000
        case "--jitter":  wanted.jitter=amount/1000
        case "--loss":    wanted.loss=f32(amount/100)
        }
    }
    return true
}
