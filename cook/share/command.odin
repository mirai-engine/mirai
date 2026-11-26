package share

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/slashpath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:asset"
import "mirai:cook/import/sources"
import vcs "mirai:kai"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"
import wire "mirai:net"

// The commands mirai share and mirai join, which the import program of the
// engine runs. share takes a snapshot of a project, opens a host with its port
// mapped by the router, prints one invitation and serves until it is stopped:
// the snapshot, its files and the library of the machine store, to whoever
// holds the invitation. join connects with an invitation, writes the project
// into a folder and refreshes its packages from the peers; while it runs it
// serves what it has to others, with an invitation of its own. --address
// joins the host at that address, with the key of the invitation, in place
// of the addresses it carries (the same machine at 127.0.0.1, or an address
// known to reach it). The store is the machine's, or the one at --store.
// Exit codes: 0 done, 1 failed, 2 misuse, 3 incomplete (a join wrote all but
// the files it lists, and run again once they are fixed completes them).

SHARE_USAGE :: "Usage: mirai share [project] [--port N] [--store <folder>]"
JOIN_USAGE :: "Usage: mirai join <invitation> [folder] [--address <ip:port>] [--port N] [--store <folder>]"
PORT :: 7950 // a share's, unless --port; taken, the system gives another
@(private) STATUS_SECONDS :: 10.0
@(private) MAPPING_SECONDS :: 15.0 // the most an invitation waits for the router

// share or join, by the first argument. library reads the formats and the
// importers the plugins of the joined project add, building its editor first
// (editor.import_library_built in the import program).
command :: proc(args:[]string,output,errors:io.Writer,library:sources.Library=nil) -> int {
    if len(args)>0 && args[0]=="share" {return share_command(args[1:],output,errors)}
    if len(args)>0 && args[0]=="join" {return join_command(args[1:],output,errors,library)}
    fmt.wprintfln(errors,"%s\n%s",SHARE_USAGE,JOIN_USAGE)
    return 2
}

// A host on UDP with its port mapping.
@(private)
Udp_Host :: struct {
    udp:wire.Udp,
    host:wire.Host,
    mapping:wire.Port_Mapping,
    mapping_on,open:bool,
    key:wire.Invite_Key, // of the invitation: of this share for a server, what the code carries for a client
    port:int,
}

@(private)
host_open :: proc(h:^Udp_Host,mode:wire.Mode,port:int,key:wire.Invite_Key) -> bool {
    // The addresses of an invitation are IPv4.
    if mode==.Client {
        if !wire.udp_open(&h.udp,wire.address_ip4(0,0,0,0,0)) {return false}
    } else if !wire.udp_open(&h.udp,wire.address_any6(port)) && !wire.udp_open(&h.udp,wire.address_any6(0)) {
        return false
    }
    if host_init(&h.host,mode,wire.udp_transport(&h.udp),key)!=.None || !wire.worker_start(&h.host) {
        wire.host_destroy(&h.host)
        wire.udp_close(&h.udp)
        return false
    }
    h.key=key
    h.open,h.port=true,int(h.udp.address.port)
    if mode==.Server {h.mapping_on=wire.mapping_start(&h.mapping,u16(h.port))}
    return true
}

@(private)
host_close :: proc(h:^Udp_Host) {
    if !h.open {return}
    // The others hear the end instead of waiting for silence.
    wire.host_disconnect(&h.host,0,.Closed)
    wire.host_poll(&h.host)
    time.sleep(5*time.Millisecond)
    if h.mapping_on {wire.mapping_close(&h.mapping)}
    wire.host_destroy(&h.host)
    wire.udp_close(&h.udp)
    h.open=false
}

// The invitation of a server once its router answered, or MAPPING_SECONDS
// passed; mapped: whether it carries an address outside this network.
@(private)
invitation_of :: proc(h:^Udp_Host,wait:bool) -> (code:string,mapped:bool,ready:bool) {
    if h.mapping_on && wait {
        started:=time.tick_now()
        for wire.mapping_poll(&h.mapping).phase==.Pending && time.duration_seconds(time.tick_since(started))<MAPPING_SECONDS {time.sleep(20*time.Millisecond)}
    }
    if h.mapping_on && wire.mapping_poll(&h.mapping).phase==.Pending {return "",false,false}
    invitation:=wire.invite_make(h.key,h.port,h.mapping_on?&h.mapping:nil)
    return wire.invite_encode(invitation,context.allocator),invitation.public.kind!=.None,true
}

@(private)
store_open :: proc(root:string,errors:io.Writer,what:string) -> (s:store.Store,ok:bool) {
    folder:=root!=""?root:store.default_root(context.temp_allocator)
    if folder=="" {
        fmt.wprintfln(errors,"mirai %s: this machine has no folder of user data for its store: pass one with --store",what)
        return
    }
    error:store.Error
    s,error=store.open(folder)
    #partial switch error {
    case .None: return s,true
    case .Unsupported_Layout:
        fmt.wprintfln(errors,"mirai %s: the store at %s was written by another version of Mirai: remove that folder, whose content is fetched or built again, or pass another with --store",what,folder)
    case:
        fmt.wprintfln(errors,"mirai %s: the store at %s could not be opened (%v): pass another with --store",what,folder,error)
    }
    return
}

@(private)
options_parse :: proc(args:[]string,errors:io.Writer,usage,what:string,positional:^[dynamic]string,address:^wire.Address=nil) -> (port:int,store_root:string,ok:bool) {
    port=-1
    for at:=0;at<len(args);at+=1 {
        switch args[at] {
        case "--address":
            if address==nil || at+1>=len(args) {fmt.wprintln(errors,usage);return}
            at+=1
            parsed,valid:=wire.address_parse(args[at])
            if !valid || parsed.kind!=.IP4 || parsed.port==0 {fmt.wprintfln(errors,"mirai %s: --address needs an IPv4 address with its port, as 127.0.0.1:7950",what);return}
            address^=parsed
        case "--store":
            if at+1>=len(args) {fmt.wprintln(errors,usage);return}
            at+=1
            store_root=args[at]
        case "--port":
            if at+1>=len(args) {fmt.wprintln(errors,usage);return}
            at+=1
            value,parsed:=strconv.parse_int(args[at])
            if !parsed || value<0 || value>65535 {fmt.wprintfln(errors,"mirai %s: --port needs a UDP port from 0 (any) to 65535",what);return}
            port=value
        case:
            if strings.has_prefix(args[at],"-") {fmt.wprintfln(errors,"mirai %s: '%s' is not an option\n%s",what,args[at],usage);return}
            append(positional,args[at])
        }
    }
    return port,store_root,true
}

@(private)
share_command :: proc(args:[]string,output,errors:io.Writer) -> int {
    positional:=make([dynamic]string,context.temp_allocator)
    port,store_root,ok:=options_parse(args,errors,SHARE_USAGE,"share",&positional)
    if !ok || len(positional)>1 {
        if ok {fmt.wprintln(errors,SHARE_USAGE)}
        return 2
    }
    root:=project.path_absolute(len(positional)>0?positional[0]:".",context.temp_allocator)
    s,opened:=store_open(store_root,errors,"share")
    if !opened {return 1}
    defer store.close(&s)

    // The exchange's jobs, owned by this thread, which pumps.
    exchange_jobs:jobs.Job_System
    if !jobs.system_init(&exchange_jobs,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) {
        fmt.wprintln(errors,"mirai share: the threads of the exchange could not be started")
        return 1
    }
    defer jobs.system_destroy(&exchange_jobs)
    n:=new(Node,context.temp_allocator)
    if node_init(n,&s,runtime.heap_allocator(),{system=&exchange_jobs,worker=jobs.OWNER})!=.None {
        fmt.wprintln(errors,"mirai share: no memory for the exchange")
        return 1
    }
    defer node_destroy(n)
    key,made:=wire.invite_key()
    if !made {fmt.wprintln(errors,"mirai share: this system gives no secure random bytes to seal the connections with");return 1}

    js:jobs.Job_System
    if !jobs.system_init(&js,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) {
        fmt.wprintln(errors,"mirai share: the threads to read the files on could not be started")
        return 1
    }
    started:=time.tick_now()
    o,offer_error:=offer(n,&s,root,key.secret,{system=&js,worker=jobs.OWNER},context.temp_allocator)
    jobs.system_destroy(&js)
    for line in o.taken.skipped {fmt.wprintfln(errors,"left out: %s",line)}
    if offer_error!="" {
        fmt.wprintfln(errors,"mirai share: %s",offer_error)
        return 1
    }
    fmt.wprintfln(output,"snapshot of %s: %d files, %s (%d read into the store at %s, %s)",root,o.taken.files,base.bytes_text(o.taken.bytes),o.taken.put,s.root,seconds_text(time.duration_seconds(time.tick_since(started))))
    if o.taken.sources>0 {fmt.wprintfln(output,"%d sources of built packages left out: joiners take the builds",o.taken.sources)}
    for problem in o.problems {fmt.wprintfln(errors,"warning: a joiner will not get it: %s",problem)}
    h:=new(Udp_Host,context.temp_allocator)
    if !host_open(h,.Server,port>=0?port:PORT,key) {
        fmt.wprintfln(errors,"mirai share: no UDP port could be opened%s: give another with --port",port>0?fmt.tprintf(" at %d",port):"")
        return 1
    }
    defer host_close(h)
    node_host(n,&h.host)
    name:=o.name

    code,mapped,_:=invitation_of(h,true)
    fmt.wprintfln(output,"Sharing %s on UDP port %d. Invitation:\n\n    %s\n\nOn the other machine: mirai join %s [folder]",name,h.port,code,code)
    if !mapped {fmt.wprintfln(output,"The router mapped no port, so only machines on this network can join; from another network, the joiner's router must map one, or this one must allow UPnP, NAT-PMP or PCP.")}
    fmt.wprintln(output,"Stop with Ctrl+C.")
    events:[EVENTS]Event
    status_at:=0.0
    last:Node_Totals
    for {
        now:=wire.host_time(&h.host)
        node_pump(n,now)
        for e in node_events(n,events[:]) {event_print(output,e,node_totals(n).connected)}
        if now-status_at>=STATUS_SECONDS {
            status_at=now
            t:=node_totals(n)
            if t.sent!=last.sent || t.connected!=last.connected {
                fmt.wprintfln(output,"%d connected, %s sent, %s/s",t.connected,base.bytes_text(i64(t.sent)),base.bytes_text(i64(t.send_rate)))
            }
            last=t
        }
        time.sleep(time.Millisecond)
    }
}

// What a host offers: the snapshot of its project, its address and name,
// what taking it read, and the packages a joiner will not get, each why.
Offer :: struct {
    snapshot:Snapshot,
    address:store.Hash,
    name:string,
    taken:Take_Report,
    problems:[]string,
}

// Offers the project at root to whoever holds the invitation of secret: its
// snapshot put in s, at the same root as the node, under offer_name of the secret, with
// its folders, files and what the packages it pins need held by the lease of
// the node. Taking it again after a change offers the new snapshot, and a
// joined peer that joins again gets only what differs. Jobs of
// worker, when given, read the files. In allocator. No concurrent offer of n.
// Keep s open through node_destroy.
offer :: proc(
    n:^Node,s:^store.Store,root:string,secret:u64,worker:=jobs.Worker_Ref{},
    allocator:=context.allocator,kind:=Offer_Kind.Project,cancel:^bool=nil,
) -> (o:Offer,error:string) {
    if n==nil || n.s==nil || s==nil || s.root=="" || s.root!=n.s.root {
        return {},"the project offer must use the store the node serves"
    }
    if offer_cancelled(cancel) {return {},OFFER_CANCELLED}
    manifest,manifest_error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if manifest_error.code!=.None {
        return {},fmt.aprintf("%s is not a project (its %s does not read: %v): give the folder of one",root,project.PROJECT_FILE,manifest_error.code,allocator=allocator)
    }
    o.name=base.text_get(manifest.name[:])
    if !name_valid(o.name) {o.name=os.base(root)}
    if !name_valid(o.name) {o.name="project"}
    o.name=strings.clone(o.name,allocator)
    served:=make([dynamic]store.Hash,context.temp_allocator)
    built:=library_served(s,root,&served,cancel)
    if offer_cancelled(cancel) {return {},OFFER_CANCELLED}
    o.snapshot,o.address,o.taken,error=snapshot_take(s,root,o.name,&served,worker,allocator,cancel,&built)
    if error!="" {return}
    packages,_:=asset.root_packages_in(s,root,allocator)
    o.problems=packages.problems
    for e in o.snapshot.entries {append(&served,e.address)}
    lease,lease_error:=store.lease_open(s,served[:])
    if lease_error!=.None {
        return {},fmt.aprintf("the project lease could not be kept (%v)",
            lease_error,allocator=allocator)
    }
    defer if lease.store!=nil {store.lease_release(&lease)}
    if offer_cancelled(cancel) {return {},OFFER_CANCELLED}
    digits:[64]u8
    if put_error:=offer_set(s,root,offer_name(secret,&digits),o.address,o.name,kind);put_error!=.None {
        return {},fmt.aprintf("the project offer could not be kept in the store (%v)",put_error,allocator=allocator)
    }
    if n.offer_lease.store!=nil {store.lease_release(&n.offer_lease)}
    n.offer_lease=lease
    lease={}
    return
}

// What the packages the project at root pins need: their manifests and the
// builds this machine chose for them, with every blob they list. Gives the
// sources of those whose build is here whole, which a joiner does not need.
@(private)
library_served :: proc(s:^store.Store,root:string,served:^[dynamic]store.Hash,cancel:^bool) -> (built:Built_Sources) {
    built=make(Built_Sources,context.temp_allocator)
    list,_,error:=asset.packages_load(root,context.temp_allocator)
    if error!=.None {return}
    index:=store.read_index(s)
    digits:[64]u8
    for &entry in list.packages {
        if offer_cancelled(cancel) {return}
        append(served,entry.manifest)
        p,package_error:=asset.package_load(&index,root,&entry,context.temp_allocator)
        if package_error!=.None {continue}
        hash,ref_error:=store.ref_get(&index,asset.REF_BUILDS,
            store.hex(asset.build_select(entry.manifest,&p),&digits))
        if ref_error!=.None {continue}
        append(served,hash)
        b,build_error:=asset.build_get(&index,hash,context.temp_allocator)
        if build_error!=.None {continue}
        objects:=asset.Build_Objects{build=&b,with_thumbnails=true}
        for address in asset.build_object_next(&objects) {append(served,address)}
        if !asset.build_whole(&index,&b) {continue}
        origin:=source_relative(p.origin.path)
        if origin=="" {continue}
        built[origin]=true
        folder:=slashpath.dir(p.origin.path,context.temp_allocator)
        for input in p.inputs {
            if path:=source_relative(fmt.tprintf("%s/%s",folder,input));path!="" {built[path]=true}
        }
    }
    return
}

// The path of a source a manifest names, relative to the project, in lower
// case; "" for one outside the project.
@(private)
source_relative :: proc(path:string) -> string {
    if path=="" || strings.has_prefix(path,"/") || strings.index_byte(path,':')>=0 {return ""}
    cleaned:=slashpath.clean(path,context.temp_allocator)
    if cleaned=="." || cleaned==".." || strings.has_prefix(cleaned,"../") {return ""}
    return strings.to_lower(cleaned,context.temp_allocator)
}

@(private)
event_print :: proc(output:io.Writer,e:Event,connected:int) {
    switch e.kind {
    case .Joined: fmt.wprintfln(output,"peer %d joined (%d connected)",e.peer,connected)
    case .Left: fmt.wprintfln(output,"peer %d left (%v): %s sent to it, %s received (%d connected)",e.peer,e.reason,base.bytes_text(i64(e.sent)),base.bytes_text(i64(e.received)),connected)
    }
}

// The network of a join: its node pumped on a thread of its own until stopped.
@(private)
Pump :: struct {
    node:^Node,
    hosts:[2]^Udp_Host,
    output:io.Writer,
    stop:bool,
}

@(private)
join_command :: proc(args:[]string,output,errors:io.Writer,library:sources.Library) -> int {
    positional:=make([dynamic]string,context.temp_allocator)
    at:wire.Address
    port,store_root,ok:=options_parse(args,errors,JOIN_USAGE,"join",&positional,&at)
    if !ok || len(positional)<1 || len(positional)>2 {
        if ok {fmt.wprintln(errors,JOIN_USAGE)}
        return 2
    }
    invitation,refused:=wire.invite_decode(positional[0])
    if refused!=.None {
        fmt.wprintfln(errors,"mirai join: '%s' is not an invitation of this Mirai: %s",positional[0],wire.invite_error_text(refused))
        return 1
    }
    folder:=len(positional)>1?positional[1]:""
    s,opened:=store_open(store_root,errors,"join")
    if !opened {return 1}
    defer store.close(&s)
    js:jobs.Job_System
    if !jobs.system_init(&js,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) {
        fmt.wprintln(errors,"mirai join: the threads to import on could not be started")
        return 1
    }
    defer jobs.system_destroy(&js)

    // The exchange's jobs, owned by the thread that pumps; the join's own are for its imports.
    exchange_jobs:jobs.Job_System
    if !jobs.system_init(&exchange_jobs,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) {
        fmt.wprintln(errors,"mirai join: the threads of the exchange could not be started")
        return 1
    }
    defer jobs.system_destroy(&exchange_jobs)
    n:=new(Node,context.temp_allocator)
    if node_init(n,&s,runtime.heap_allocator(),{system=&exchange_jobs,worker=jobs.OWNER})!=.None {
        fmt.wprintln(errors,"mirai join: no memory for the exchange")
        return 1
    }
    client,server:=new(Udp_Host,context.temp_allocator),new(Udp_Host,context.temp_allocator)
    own,made:=wire.invite_key()
    if !made {fmt.wprintln(errors,"mirai join: this system gives no secure random bytes to seal the connections with");return 1}
    if !host_open(client,.Client,0,invitation.key) {
        fmt.wprintln(errors,"mirai join: no UDP port could be opened: close what holds them, or let this program use the network")
        node_destroy(n)
        return 1
    }
    node_host(n,&client.host)
    if host_open(server,.Server,port>=0?port:PORT,own) {node_host(n,&server.host)}
    if at.kind!=.None {
        wire.host_connect(&client.host,at)
    } else {
        wire.host_connect(&client.host,invitation.lan,invitation.public)
    }

    pump:=Pump{node=n,hosts={client,server},output=output}
    t:=thread.create_and_start_with_data(&pump,proc(data:rawptr) {
        p:=(^Pump)(data)
        code_said:=!p.hosts[1].open
        for !sync.atomic_load(&p.stop) {
            node_pump(p.node,wire.host_time(&p.hosts[0].host))
            if !code_said {
                if code,_,ready:=invitation_of(p.hosts[1],false);ready {
                    code_said=true
                    if code!="" {fmt.wprintfln(p.output,"while this runs, others can join from here too: mirai join %s",code)}
                }
            }
            time.sleep(time.Millisecond)
        }
    })
    if t==nil {fmt.wprintln(errors,"mirai join: no thread for the network");return 1}
    digits,own_digits:[64]u8
    desc:=Join_Desc{
        node=n,offer=offer_name(invitation.key.secret,&digits),own_offer=server.open?offer_name(own.secret,&own_digits):"",
        folder=folder,library=library,worker={system=&js,worker=jobs.OWNER},output=output,
    }
    report,error:=join(desc,context.temp_allocator)
    t_received:=node_totals(n).received
    sync.atomic_store(&pump.stop,true)
    thread.join(t)
    thread.destroy(t)
    host_close(client)
    host_close(server)
    node_destroy(n)
    if report.folder!="" && desc.own_offer!="" {store.ref_remove(&s,NAMESPACE,desc.own_offer)}

    for line in report.kept {fmt.wprintfln(output,"kept: %s",line)}
    for line in report.failed {fmt.wprintfln(errors,"not written: %s",line)}
    if error!="" {
        fmt.wprintfln(errors,"mirai join: %s",error)
        return 1
    }
    code:=0
    for warning in report.packages.warnings {fmt.wprintfln(output,"warning: %s",warning)}
    for failure in report.packages.failures {fmt.wprintfln(errors,"mirai join: %s",failure);code=1}
    for missing in report.packages.missing {fmt.wprintfln(errors,"mirai join: %s",missing);code=1}
    fmt.wprintfln(output,"Joined into %s: %d files, %d written, %d removed, %d kept as you left them; %d packages, %d builds fetched; %s received.",
        report.folder,report.files,report.written,report.removed,len(report.kept),report.packages.packages,report.packages.fetched,base.bytes_text(i64(t_received)))
    if len(report.failed)>0 {
        fmt.wprintfln(errors,"mirai join: incomplete, %d files were not written or removed; fix what each says and run the same join again, which does only those",len(report.failed))
        return 3
    }
    open:=fmt.tprintf("mirai edit %s",report.folder)
    if store_root!="" {open=fmt.tprintf("%s --store %s",open,store_root)}
    fmt.wprintfln(output,"Open it with: %s",open)
    return code
}
