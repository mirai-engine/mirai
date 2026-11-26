package hub

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:kai"
import "mirai:store"

// KaiHub: what `mirai kai serve` runs. A Kai agent that is always on, a node
// of each org it joined (it keeps every repository whole and the derived data
// writers publish, so a machine pulls while the others are off), and a web
// view of those orgs over plain HTTP on 127.0.0.1, meant to sit behind a
// reverse proxy (Caddy, Cloudflare, nginx) that gives it TLS. Each org lives
// in a store of its own under <root>/orgs/<org hex> (kai.Tenants), so a
// server that keeps the orgs of several customers never mixes their objects.
// The server is trusted, as a Git host is: a web account is a name and a
// password a member set from its device (kai.agent_web_login), and sees what
// that device's role in each org lets it see; the pages are made on the
// server, with no script.

SERVE_USAGE :: "kai serve [--root <folder>] [--port N] [--http host:port] [--public host:port] [--join <invite>]... [--name <name>] [--ddc-quota <bytes>]"
HTTP_DEFAULT :: "127.0.0.1:7351"
CONNECTIONS_MAX :: 256
REQUEST_SECONDS :: 30  // to receive one request whole, the wait before it included
SEND_SECONDS :: 30     // of one send to a client
SESSION_HOURS :: 24*14
SESSIONS_MAX :: 4096
DERIVATIONS_MAX :: 4   // Argon2id derivations at once, each of ARGON2ID's memory
DDC_SWEEP_SECONDS :: 300

Hub :: struct {
    s:store.Store,     // <root>/server: the server's own state, its key and web accounts
    team:kai.Team,
    tenants:kai.Tenants,
    agent:kai.Agent,
    listener:net.TCP_Socket,
    address:net.IP4_Address, // the web view listens at
    port:int,          // of the web view
    lock:sync.Mutex,   // of what follows
    sessions:map[[32]u8]Session,
    clients:[CONNECTIONS_MAX]Client,
    derivations:int,   // Argon2id derivations running
    stopping:bool,
    accept:^thread.Thread,
    allocator:runtime.Allocator,
}

// A connection of the web view; its slot is free when !open.
@(private)
Client :: struct {
    socket:net.TCP_Socket,
    open:bool,
}

Hub_Options :: struct {
    root:string,
    port:int,       // the agent's TCP port; 0: kai.KAI_PORT
    http:string,    // host:port of the web view
    public:string,  // host:port where members reach the agent
    name:string,    // the server's device name
}

// Opens the server's stores and starts its agent and its web view.
hub_start :: proc(h:^Hub,options:Hub_Options,allocator:=context.allocator) -> (why:string,ok:bool) {
    h^={allocator=allocator}
    me:runtime.Allocator_Error
    if h.sessions,me=make(map[[32]u8]Session,SESSIONS_MAX,allocator);me!=nil {return "memory ran out",false}
    if os.make_directory_all(options.root)!=nil && !os.is_dir(options.root) {return fmt.tprintf("%s could not be made: choose a folder this user may write",options.root),false}
    e:store.Error
    if h.s,e=store.open(strings.concatenate({options.root,"/server"},context.temp_allocator),allocator);e!=.None {return fmt.tprintf("the server's store does not open: %s",store.error_text(e)),false}
    if kai.team_open(&h.team,&h.s,allocator)!=.None {
        store.close(&h.s)
        return h.team.why,false
    }
    if kai.tenants_init(&h.tenants,options.root,allocator)!=.None {
        hub_free(h)
        return "memory ran out",false
    }
    h.team.tenants=&h.tenants
    name:=options.name!=""?options.name:"server"
    if h.team.name!=name {kai.team_profile_set(&h.team,name,name)}
    agent_options:=kai.Agent_Options{port=options.port,node=true,public=options.public,web_login=account_set,web_data=h}
    if ae:=kai.agent_start(&h.agent,&h.team,agent_options,allocator);ae!=.None {
        hub_free(h)
        return h.team.why,false
    }
    host,port,split:=net.split_port(options.http!=""?options.http:HTTP_DEFAULT)
    address,parsed:=net.parse_ip4_address(host)
    if !split || !parsed {
        kai.agent_stop(&h.agent)
        hub_free(h)
        return "--http takes an IPv4 host:port, as 127.0.0.1:7351",false
    }
    listener,le:=net.listen_tcp({address,port})
    if le!=nil {
        kai.agent_stop(&h.agent)
        hub_free(h)
        return fmt.tprintf("%s is taken: choose another --http",options.http),false
    }
    h.listener,h.address,h.port=listener,address,port
    if bound,be:=net.bound_endpoint(listener);be==nil {h.port=bound.port}
    h.accept=thread.create_and_start_with_poly_data(h,hub_accept_run,hub_context(h))
    if h.accept==nil {
        net.close(listener)
        kai.agent_stop(&h.agent)
        hub_free(h)
        return "the web view's thread does not start: memory ran out",false
    }
    return "",true
}

// Stops the web view and the agent and closes the stores.
hub_stop :: proc(h:^Hub) {
    // A client between requests waits in a receive: shut its socket so it ends
    // now. Its thread frees the slot under the lock before it closes the
    // socket, so no socket number here is another's.
    sync.mutex_lock(&h.lock)
    h.stopping=true
    for c in h.clients {
        if c.open {net.shutdown(c.socket,.Both)}
    }
    sync.mutex_unlock(&h.lock)
    wake:=h.address==net.IP4_Any?net.IP4_Loopback:h.address
    if s,e:=net.dial_tcp_from_address_and_port(wake,h.port);e==nil {net.close(s)}
    thread.join(h.accept)
    thread.destroy(h.accept)
    for {
        sync.mutex_lock(&h.lock)
        open:=0
        for c in h.clients {
            if c.open {open+=1}
        }
        sync.mutex_unlock(&h.lock)
        if open==0 {break}
        time.sleep(10*time.Millisecond)
    }
    net.close(h.listener)
    kai.agent_stop(&h.agent)
    hub_free(h)
}

@(private)
hub_free :: proc(h:^Hub) {
    delete(h.sessions)
    kai.team_close(&h.team)
    kai.tenants_destroy(&h.tenants)
    store.close(&h.s)
}

// A thread of the web view: the hub's allocator and a temp allocator of its own.
@(private)
hub_context :: proc(h:^Hub) -> runtime.Context {
    c:=runtime.default_context()
    c.allocator=h.allocator
    c.logger=context.logger
    return c
}

@(private)
hub_accept_run :: proc(h:^Hub) {
    defer kai.thread_end()
    for {
        socket,_,e:=net.accept_tcp(h.listener)
        slot:=-1
        sync.mutex_lock(&h.lock)
        stopping:=h.stopping
        if !stopping && e==nil {
            for c,k in h.clients {
                if c.open {continue}
                h.clients[k]={socket,true}
                slot=k
                break
            }
        }
        sync.mutex_unlock(&h.lock)
        if stopping {
            if e==nil {net.close(socket)}
            return
        }
        if e!=nil {continue}
        if slot<0 {
            net.close(socket)
            continue
        }
        Job :: struct {h:^Hub,slot:int,socket:net.TCP_Socket}
        job,je:=new(Job)
        started:^thread.Thread
        if je==nil {
            job^={h,slot,socket}
            started=thread.create_and_start_with_poly_data(job,proc(job:^Job) {
                defer kai.thread_end()
                hub_connection(job.h,job.socket)
                hub_client_end(job.h,job.slot)
                free(job)
            },hub_context(h),self_cleanup=true)
        }
        if started==nil {
            hub_client_end(h,slot)
            free(job)
        }
    }
}

// Frees a client's slot and closes its socket, in that order (see hub_stop).
@(private)
hub_client_end :: proc(h:^Hub,slot:int) {
    sync.mutex_lock(&h.lock)
    socket:=h.clients[slot].socket
    h.clients[slot]={}
    sync.mutex_unlock(&h.lock)
    net.close(socket)
}

// Serves the requests of one connection until it closes or one is refused.
@(private)
hub_connection :: proc(h:^Hub,socket:net.TCP_Socket) {
    net.set_option(socket,.Send_Timeout,SEND_SECONDS*time.Second)
    when ODIN_OS==.Darwin {net.set_option(socket,.No_SIGPIPE_From_EPIPE,true)}
    // The head's bound holds its blank line, so a whole request fits.
    input:[HEAD_MAX+BODY_MAX]u8
    have:=0
    for served:=0;served<REQUESTS_PER_CONNECTION;served+=1 {
        free_all(context.temp_allocator)
        p:Parse
        started:=time.tick_now()
        continued:=false
        for {
            p=request_parse(input[:have])
            if p.status!=0 {break}
            if have==len(input) {
                p.status=431
                break
            }
            if p.head_done && p.request.expect_continue && !continued {
                continued=true
                if !send_all(socket,transmute([]u8)string("HTTP/1.1 100 Continue\r\n\r\n")) {return}
            }
            // One deadline for the whole request, not one per receive, so a
            // client sending a byte now and then does not hold the thread.
            left:=REQUEST_SECONDS*time.Second-time.tick_since(started)
            if left<time.Millisecond {return} // a zero timeout would wait forever
            net.set_option(socket,.Receive_Timeout,left)
            n,e:=net.recv_tcp(socket,input[have:])
            if e!=nil || n<=0 {return}
            have+=n
        }
        out:=Out{body=make([dynamic]u8,context.temp_allocator),headers=make([dynamic]u8,context.temp_allocator)}
        if p.status!=200 {
            out.status=p.status
            respond(socket,&out,false)
            return
        }
        r:=&p.request
        page(h,r,&out)
        keep:=r.keep_alive && out.status<400
        if !respond(socket,&out,keep,r.method==.HEAD) || !keep {return}
        copy(input[:],input[r.size:have])
        have-=r.size
    }
}

// What a page answers.
Out :: struct {
    status:int,
    type:string,          // Content-Type
    body:[dynamic]u8,     // in the temp allocator
    headers:[dynamic]u8,  // extra header lines, each ending in CRLF
}

@(private)
respond :: proc(socket:net.TCP_Socket,out:^Out,keep:bool,head_only:=false) -> bool {
    b:=strings.builder_make(context.temp_allocator)
    if out.status==0 {out.status=200}
    fmt.sbprintf(&b,"HTTP/1.1 %d %s\r\n",out.status,reason(out.status))
    strings.write_string(&b,SECURITY_HEADERS)
    if out.type=="" && len(out.body)==0 && out.status>=400 {
        out.type="text/plain; charset=utf-8"
        append(&out.body,..transmute([]u8)reason(out.status))
    }
    if out.type!="" {fmt.sbprintf(&b,"Content-Type: %s\r\n",out.type)}
    fmt.sbprintf(&b,"Content-Length: %d\r\nCache-Control: no-store\r\n",len(out.body))
    strings.write_string(&b,string(out.headers[:]))
    strings.write_string(&b,keep?"\r\n":"Connection: close\r\n\r\n")
    if !head_only {strings.write_bytes(&b,out.body[:])}
    return send_all(socket,b.buf[:])
}

@(private)
send_all :: proc(socket:net.TCP_Socket,bytes:[]u8) -> bool {
    for at:=0;at<len(bytes); {
        n,e:=net.send_tcp(socket,bytes[at:])
        if e!=nil || n<=0 {return false}
        at+=n
    }
    return true
}

// mirai kai serve: runs the server until the process ends.
serve_command :: proc(program:string,args:[]string,store_root:="") -> int {
    options:=Hub_Options{http=HTTP_DEFAULT}
    joins:=make([dynamic]string,context.temp_allocator)
    quota:i64
    for k:=0;k<len(args);k+=1 {
        value:=k+1<len(args)?args[k+1]:""
        switch args[k] {
        case "--root": options.root=value
        case "--port": options.port,_=strconv.parse_int(value)
        case "--http": options.http=value
        case "--public": options.public=value
        case "--join": append(&joins,value)
        case "--name": options.name=value
        case "--ddc-quota": quota,_=strconv.parse_i64(value)
        case:
            fmt.eprintfln("Usage: %s %s",program,SERVE_USAGE)
            return 2
        }
        k+=1
    }
    if options.root=="" {options.root=store_root!=""?store_root:"kai-server"}
    h:Hub
    why,ok:=hub_start(&h,options)
    if !ok {
        fmt.eprintfln("%s kai serve: %s",program,why)
        return 1
    }
    defer hub_stop(&h)
    for token in joins {
        org,e:=kai.agent_join(&h.agent,token)
        if e!=.None {
            fmt.eprintfln("%s kai serve: the invite does not join: %s",program,h.agent.team.why)
            return 1
        }
        hex:[32]u8
        fmt.printfln("joined org %s",kai.org_ref_name(org,&hex))
    }
    fmt.printfln("Kai server: agent on TCP %d, web view on http://%s (put a TLS reverse proxy before it), orgs under %s/orgs",kai.agent_port(&h.agent),options.http,options.root)
    swept:=time.tick_now()
    for {
        time.sleep(time.Second)
        free_all(context.temp_allocator)
        events:=make([dynamic]string,context.temp_allocator)
        kai.agent_events(&h.agent,&events,context.temp_allocator)
        for e in events {fmt.println(e)}
        if quota<=0 || time.tick_since(swept)<DDC_SWEEP_SECONDS*time.Second {continue}
        swept=time.tick_now()
        for id in kai.team_org_ids(&h.team) {
            s,se:=kai.team_store(&h.team,id)
            if se!=.None {continue}
            if dropped,_:=kai.ddc_quota(s,id,quota);dropped>0 {
                live:=make([dynamic]store.Hash,context.temp_allocator)
                if kai.store_live(s,&live)==.None {store.sweep(s,live[:])}
            }
        }
    }
}
