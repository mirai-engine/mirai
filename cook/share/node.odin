package share

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "mirai:asset"
import "mirai:cook/cache"
import "mirai:exchange"
import vcs "mirai:kai"
import "mirai:std/jobs"
import "mirai:store"
import wire "mirai:net"

// A peer of a shared project: a store, the exchange over the hosts of its
// owner (a server others join, the client of a join), the lease that keeps
// what it serves and fetches from a sweep, and what it saw of its peers.
// One thread calls node_pump once per step; a join runs on another thread
// and reads the clock and waits through the node. An owner whose hosts carry
// channels of its own too (an editor's session) inits the node with
// keep_others, takes those commands with node_take in the order they came,
// and holds hosts_lock around its own calls on the hosts while another
// thread pumps.

NAMESPACE :: "shares"      // <hash of the secret of an invitation>: the offer under it
PROTOCOL_ID :: 0x4d495348  // of the hosts of sharing: datagrams of any other application are ignored
VERSION :: 7               // the project offer, snapshot and exchange
PEERS :: 8                 // connections of a node at once
CONTROL_CHANNEL :: 0
PRESENCE_CHANNEL :: 1
EXCHANGE_CHANNEL :: 2
LEASE_SECONDS :: 60.0      // between two updates of the lease with what the exchange wants
@(private) WANTS :: 512
@(private) EVENTS :: 64

@(private) CHANNEL_DESCS :: []wire.Channel_Desc{
    {kind=.Reliable,queue_bytes=256<<10},
    {kind=.Unreliable},
    exchange.CONTROL_CHANNEL_DESC,
    exchange.DATA_CHANNEL_DESC,
}

// The same profile serves a project with or without a live editor.
host_init :: proc(h:^wire.Host,mode:wire.Mode,transport:wire.Transport,key:wire.Invite_Key,seed:=u64(0)) -> wire.Error {
    return wire.host_init(h,{
        mode=mode,transport=transport,invite=key,seed=seed,max_connections=PEERS-1,
        protocol_id=PROTOCOL_ID,version=VERSION,channels=CHANNEL_DESCS,
    })
}

Event_Kind :: enum u8 {Joined,Left}

Event :: struct {
    kind:Event_Kind,
    peer:int,                     // a number given in order of arrival
    reason:wire.Disconnect_Reason, // Left
    sent,received:u64,            // chunk bytes with that peer, Left
}

@(private)
Node_Peer :: struct {
    used:bool,
    host:^wire.Host,
    connection:wire.Connection,
    number:int,
}

Node :: struct {
    s:^store.Store,
    x:exchange.Exchange,
    hosts:[2]^wire.Host,
    host_count:int,
    allocator:runtime.Allocator,
    hosts_lock:sync.Mutex, // the simulation halves of hosts, which node_pump calls
    // The commands that are not the exchange's, kept for node_take when
    // keep_others: their data in bytes, at the offset of each in at.
    keep_others:bool,
    kept_lock:sync.Mutex,
    kept,taken:Kept,
    // Between the pump and the thread that joins.
    lock:sync.Mutex,
    tick:sync.Cond,
    now:f64,
    stepped:bool, // now is a time of the owner's clock: before the first step it is not
    waiting:int,  // threads in node_wait
    peers:[PEERS]Node_Peer,
    numbers:int,
    connected:int,
    client_reason:wire.Disconnect_Reason, // why the client host was refused or dropped
    client_joined:bool,
    events:[EVENTS]Event,
    event_head,event_count:int,
    sent_gone,received_gone:u64, // of peers that left
    served:[dynamic]store.Hash,  // what the lease holds besides the wants
    lease:store.Lease,
    leased:bool,
    lease_at:f64,
    lease_due:bool,
    stopped:bool,
    hooks:[vcs.TEST_ONLY]^Join_Hooks,
    offer_lease:store.Lease, // owned by the thread that offers the project
}

@(private)
Kept :: struct {
    commands:[dynamic]wire.Command,
    at:[dynamic]int,
    bytes:[dynamic]u8,
    lost:bool, // a command found no memory
}

@(private)
node_keep :: proc(k:^Kept,command:wire.Command) {
    count,size:=len(k.commands),len(k.bytes)
    _,a:=append(&k.commands,command)
    _,b:=append(&k.at,size)
    _,c:=append(&k.bytes,..command.data)
    if a==nil && b==nil && c==nil {return}
    resize(&k.commands,count)
    resize(&k.at,count)
    resize(&k.bytes,size)
    k.lost=true
}

// What a test does at the crash points of a join.
@(private)
Join_Hooks :: struct {
    saved:proc(data:rawptr,path:string), // a file's replacement is whole in its temporary file
    data:rawptr,
}

// worker: the job system and worker of the thread that pumps, which reads,
// hashes, stores and commits for the exchange; none: all of it runs on the
// pump. keep_others: the commands of the hosts that are not the exchange's
// wait for node_take.
node_init :: proc(n:^Node,s:^store.Store,allocator:=context.allocator,worker:=jobs.Worker_Ref{},keep_others:=false) -> exchange.Error {
    n^={s=s,allocator=allocator,keep_others=keep_others}
    n.served=make([dynamic]store.Hash,allocator)
    for k in ([2]^Kept{&n.kept,&n.taken}) {
        k^={commands=make([dynamic]wire.Command,allocator),at=make([dynamic]int,allocator),bytes=make([dynamic]u8,allocator)}
    }
    return exchange.init(&n.x,{
        store=s,channel=EXCHANGE_CHANNEL,peers=PEERS,wants=WANTS,
        expose=node_expose,user=n,allocator=allocator,worker=worker,
    })
}

node_destroy :: proc(n:^Node) {
    node_stop(n)
    exchange.destroy(&n.x)
    if n.leased {store.lease_release(&n.lease)}
    if n.offer_lease.store!=nil {store.lease_release(&n.offer_lease)}
    delete(n.served)
    for k in ([2]^Kept{&n.kept,&n.taken}) {
        delete(k.commands)
        delete(k.at)
        delete(k.bytes)
    }
}

// Wakes whoever waits on the node, which waits no more: a join running ends.
node_stop :: proc(n:^Node) {
    sync.mutex_guard(&n.lock)
    n.stopped=true
    sync.cond_broadcast(&n.tick)
}

// Stops the node and lets go of every peer, as if they all left: what a join
// waits for from them returns at once. For an owner that ends while a join runs.
node_close :: proc(n:^Node) {
    node_stop(n)
    sync.mutex_lock(&n.lock)
    peers:=n.peers
    sync.mutex_unlock(&n.lock)
    for p in peers {
        if p.used {node_left(n,p.host,p.connection,.Closed)}
    }
}

// Adds a host of the project profile for the node to poll.
node_host :: proc(n:^Node,h:^wire.Host) -> bool {
    if n.host_count==len(n.hosts) {return false}
    n.hosts[n.host_count]=h
    n.host_count+=1
    return true
}

// What peers may read: the snapshots offered, the manifests of packages, their
// builds, Final and Fast each under its own namespace, the build this machine
// chose for each manifest (for a peer without the importer that finds it by
// key), and the results of cook/cache. Never the origins or the sources of
// this machine.
@(private)
node_expose :: proc(user:rawptr,peer:exchange.Peer_Id,namespace:string) -> bool {
    switch namespace {
    case NAMESPACE,asset.REF_PACKAGES,asset.REF_MANIFESTS,asset.REF_IMPORTS,asset.REF_IMPORTS_FAST,asset.REF_BUILDS: return true
    }
    return strings.has_prefix(namespace,asset.REF_CACHE_PREFIX)
}

// One step: every host polled, the exchange updated at now (seconds, never
// back), the lease refreshed when due, and whoever waits on the node woken.
// With keep_others, the commands of the hosts that are not the exchange's
// (every connection that came or went, the messages of other channels) wait
// for node_take.
node_pump :: proc(n:^Node,now:f64) {
    sync.mutex_lock(&n.hosts_lock)
    for h in n.hosts[:n.host_count] {
        for command in wire.host_poll(h) {
            if node_command(n,h,command) || !n.keep_others {continue}
            sync.mutex_guard(&n.kept_lock)
            node_keep(&n.kept,command)
        }
    }
    exchange.update(&n.x,now)
    sync.mutex_unlock(&n.hosts_lock)
    sync.mutex_lock(&n.lock)
    n.now=now
    n.stepped=true
    due:=n.lease_due || now-n.lease_at>=LEASE_SECONDS
    sync.cond_broadcast(&n.tick)
    sync.mutex_unlock(&n.lock)
    if due {node_lease(n,now)}
}

// The commands node_pump kept since the last call, oldest first; valid until
// the next call. For one thread, the owner's. complete is false when one or
// more found no memory to wait in: the order of what follows is broken.
node_take :: proc(n:^Node) -> (commands:[]wire.Command,complete:bool) {
    clear(&n.taken.commands)
    clear(&n.taken.at)
    clear(&n.taken.bytes)
    n.taken.lost=false
    sync.mutex_lock(&n.kept_lock)
    kept:=n.kept
    n.kept=n.taken
    n.taken=kept
    sync.mutex_unlock(&n.kept_lock)
    for &command,i in n.taken.commands {
        size:=len(command.data)
        command.data=n.taken.bytes[n.taken.at[i]:][:size]
        command.words=nil
    }
    return n.taken.commands[:],!n.taken.lost
}

// A command of a polled host: a connection that came or went, or a message,
// which it says was the exchange's.
@(private)
node_command :: proc(n:^Node,h:^wire.Host,command:wire.Command) -> (own:bool) {
    #partial switch command.kind {
    case .Connected: node_joined(n,h,command.connection)
    case .Disconnected: node_left(n,h,command.connection,command.reason)
    case .Message: return exchange.receive(&n.x,h,command)
    }
    return false
}

@(private)
node_joined :: proc(n:^Node,h:^wire.Host,connection:wire.Connection) {
    if exchange.peer_add(&n.x,h,connection)!=.None {
        wire.host_disconnect(h,connection,.Capacity)
        return
    }
    sync.mutex_guard(&n.lock)
    for &p in n.peers {
        if p.used {continue}
        n.numbers+=1
        p={used=true,host=h,connection=connection,number=n.numbers}
        n.connected+=1
        if h.desc.mode==.Client {n.client_joined=true}
        node_event(n,{kind=.Joined,peer=p.number})
        return
    }
}

@(private)
node_left :: proc(n:^Node,h:^wire.Host,connection:wire.Connection,reason:wire.Disconnect_Reason) {
    progress,known:=exchange.peer_progress(&n.x,h,connection)
    exchange.peer_remove(&n.x,h,connection)
    sync.mutex_guard(&n.lock)
    if h.desc.mode==.Client {n.client_reason=reason}
    if !known {return}
    n.sent_gone+=progress.sent
    n.received_gone+=progress.received
    for &p in n.peers {
        if !p.used || p.host!=h || p.connection!=connection {continue}
        node_event(n,{kind=.Left,peer=p.number,reason=reason,sent=progress.sent,received=progress.received})
        p={}
        n.connected-=1
    }
}

@(private)
node_event :: proc(n:^Node,e:Event) {
    if n.event_count==EVENTS {
        n.event_head=(n.event_head+1)%EVENTS
        n.event_count-=1
    }
    n.events[(n.event_head+n.event_count)%EVENTS]=e
    n.event_count+=1
}

// The connection of the client host of the node: to the host its join connects to.
@(private)
node_host_peer :: proc(n:^Node) -> (h:^wire.Host,connection:wire.Connection,ok:bool) {
    sync.mutex_guard(&n.lock)
    for p in n.peers {
        if p.used && p.host.desc.mode==.Client {return p.host,p.connection,true}
    }
    return
}

// The events since the last call, oldest first, into buffer.
node_events :: proc(n:^Node,buffer:[]Event) -> []Event {
    sync.mutex_guard(&n.lock)
    count:=min(n.event_count,len(buffer))
    for k in 0..<count {buffer[k]=n.events[(n.event_head+k)%EVENTS]}
    n.event_head=(n.event_head+count)%EVENTS
    n.event_count-=count
    return buffer[:count]
}

// bad: peers that sent what no peer sends, neither asked nor served since;
// refused: their messages refused.
Node_Totals :: struct {connected:int,sent,received:u64,send_rate,receive_rate:f64,bad:int,refused:u64}

// Chunk bytes sent and received with every peer since the node began, and the rates now.
node_totals :: proc(n:^Node) -> (t:Node_Totals) {
    sync.mutex_guard(&n.lock)
    t.connected,t.sent,t.received=n.connected,n.sent_gone,n.received_gone
    for p in n.peers {
        if !p.used {continue}
        if progress,ok:=exchange.peer_progress(&n.x,p.host,p.connection);ok {
            t.sent+=progress.sent
            t.received+=progress.received
            t.send_rate+=progress.send_rate
            t.receive_rate+=progress.receive_rate
            t.refused+=progress.refused
            if progress.bad {t.bad+=1}
        }
    }
    return
}

// The clock of the node: that of its last step.
node_now :: proc(n:^Node) -> f64 {
    sync.mutex_guard(&n.lock)
    return n.now
}

// Waits until the node stepped to at least now+seconds, and at least once;
// false once it stopped.
node_wait :: proc(n:^Node,seconds:f64) -> bool {
    sync.mutex_guard(&n.lock)
    until:=n.now+seconds
    n.waiting+=1
    for (!n.stepped || n.now<until) && !n.stopped {sync.cond_wait(&n.tick,&n.lock)}
    n.waiting-=1
    return !n.stopped
}

// Whether a thread waits for the clock of the node: one that steps a clock of
// its own advances it only then, so the work between two waits takes none of it.
node_waiting :: proc(n:^Node) -> bool {
    sync.mutex_guard(&n.lock)
    return n.waiting>0
}

// Adds addresses to what the lease of the node holds.
node_serve :: proc(n:^Node,addresses:..store.Hash) {
    sync.mutex_guard(&n.lock)
    append(&n.served,..addresses)
    n.lease_due=true
}

@(private)
node_lease :: proc(n:^Node,now:f64) {
    wants:[WANTS]store.Hash
    wanted:=exchange.want_addresses(&n.x,wants[:])
    sync.mutex_lock(&n.lock)
    live:=make([]store.Hash,len(n.served)+len(wanted),context.temp_allocator)
    copy(live,n.served[:])
    copy(live[len(n.served):],wanted)
    n.lease_at,n.lease_due=now,false
    sync.mutex_unlock(&n.lock)
    if len(live)>store.LEASE_MAX_HASHES {live=live[:store.LEASE_MAX_HASHES]}
    if n.leased {
        store.lease_update(&n.lease,live)
        return
    }
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    if lease,error:=store.lease_open(n.s,live);error==.None {
        n.lease=lease
        n.leased=true
    }
}

// The source a refresh of the library asks: refs of the peers with their
// objects, and for a build every object it lists, made complete in the store
// before the ref is set there. The names of one call are asked together, and
// the objects of their builds fetched together. For a thread other than the pump's.
node_source :: proc(n:^Node) -> cache.Source {
    return {fetch=proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
        node_fetch((^Node)(user),nil,into,namespace,names,given)
    },user=n}
}

// node_source whose fetches give nothing once the flag cancel is set
// (exchange.fetch_cancel), the waits for the peers ending at once. Lives
// while it is asked.
Node_Fetching :: struct {node:^Node,cancel:^bool}

node_source_cancellable :: proc(f:^Node_Fetching) -> cache.Source {
    return {fetch=proc(user:rawptr,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
        f:=(^Node_Fetching)(user)
        node_fetch(f.node,f.cancel,into,namespace,names,given)
    },user=f}
}

@(private)
node_fetch :: proc(n:^Node,cancel:^bool,into:^store.Store,namespace:string,names:[]string,given:[]bool) {
    if into!=n.s || len(names)==0 {return}
    addresses:=make([]store.Hash,len(names),context.temp_allocator)
    refs_fetch(&n.x,namespace,names,addresses,cancel)
    if namespace==asset.REF_IMPORTS || namespace==asset.REF_IMPORTS_FAST || namespace==asset.REF_BUILDS {
        objects:=make([dynamic]store.Hash,context.temp_allocator)
        for &address in addresses {
            if address=={} || !asset.object_whole(into,address) {continue}
            b,build_error:=asset.build_get(into,address,context.temp_allocator)
            if build_error!=.None {
                address={}
                continue
            }
            roots:=asset.Build_Objects{build=&b,with_thumbnails=true}
            for root in asset.build_object_next(&roots) {append(&objects,root)}
        }
        objects_fetch(&n.x,objects[:],cancel)
        for &address in addresses {
            if address=={} {continue}
            b,build_error:=asset.build_get(into,address,context.temp_allocator)
            if build_error!=.None || !asset.build_whole(into,&b,true) {address={}}
        }
    }
    for address,k in addresses {
        given[k]=address!={} && asset.object_whole(into,address) && store.ref_set(into,namespace,names[k],address)==.None
    }
}

// The addresses peers name with namespace and names, each with its object
// complete, or {} for a name none names. A name or an object that none has makes
// the batch Missing, which says nothing of the others: the batch is asked
// again by halves, so m missing of n cost about m log n round trips, not n.
@(private)
refs_fetch :: proc(x:^exchange.Exchange,namespace:string,names:[]string,addresses:[]store.Hash,cancel:^bool=nil) {
    error:=exchange.fetch_refs(x,namespace,names,addresses,cancel=cancel)
    if error!=.Missing || len(names)==1 {return}
    half:=len(names)/2
    refs_fetch(x,namespace,names[:half],addresses[:half],cancel)
    refs_fetch(x,namespace,names[half:],addresses[half:],cancel)
}

// The objects of addresses fetched together, by halves when some peer lacks one.
@(private)
objects_fetch :: proc(x:^exchange.Exchange,addresses:[]store.Hash,cancel:^bool=nil) {
    if len(addresses)==0 {return}
    error:=exchange.fetch_all(x,addresses,cancel=cancel)
    if error!=.Missing || len(addresses)==1 {return}
    half:=len(addresses)/2
    objects_fetch(x,addresses[:half],cancel)
    objects_fetch(x,addresses[half:],cancel)
}

// The name of the snapshot a share offers under the secret of its invitation:
// a hash of the secret, so the names peers list reveal no secret.
offer_name :: proc(secret:u64,buffer:^[64]u8) -> string {
    bytes:[8]u8
    for k in 0..<8 {bytes[k]=u8(secret>>(8*uint(k)))}
    return store.hex(store.address_of_bytes(bytes[:]),buffer)
}
