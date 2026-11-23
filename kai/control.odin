package kai

import "core:crypto"
import "core:encoding/endian"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import net "mirai:net"
import "mirai:store"

// How another process of this user reaches the runner of a store without
// opening its socket again. The runner holds AGENT_LOCK_FILE locked for as
// long as it runs (the system lets go when the process ends), so there is one
// runner per store; it writes AGENT_FILE, owner-only, with its port and a
// random token. A request is a datagram to 127.0.0.1 at that port:
//
//   L token id op body        A id error body   (error: an Error; body: why, when it is not None)
//
// Only the user who may read AGENT_FILE knows the token; the runner answers
// only from loopback. Each op is a runner_* procedure: the editor, which runs
// the runner itself, calls those directly.

AGENT_FILE :: "kai-agent"
AGENT_LOCK_FILE :: "kai-agent.lock"
CONTROL_TOKEN :: 32
CONTROL_TRIES :: 25        // of CONTROL_WAIT seconds each
CONTROL_WAIT :: 0.2
@(private) CONTROL_HEAD :: 1+CONTROL_TOKEN+4+1
@(private) ANSWER_HEAD :: 1+4+1
@(private) PEER_BYTES :: 32+32+3
@(private) ORG_INFO_BYTES :: 32+2+2+4

Control_Op :: enum u8 {None,Changed,Peers,Pair_Offer,Pair_Request,Pair_Answer,Pair_Join,Pair_Progress,DDC_Ask,Addresses,Object_Ask}

Control_Server :: struct {
    lock:Lock,
    locked:bool,
    token:[CONTROL_TOKEN]u8,
    file:[1024]u8,
    file_len:int,
}

@(private)
control_serve :: proc(c:^Control_Server,s:^store.Store) -> Error {
    c^={}
    lock:=strings.concatenate({s.root,"/",AGENT_LOCK_FILE},context.temp_allocator)
    c.lock=lock_take(lock) or_return
    c.locked=true
    crypto.rand_bytes(c.token[:])
    c.file_len=copy(c.file[:],strings.concatenate({s.root,"/",AGENT_FILE},context.temp_allocator))
    return .None
}

@(private)
control_publish :: proc(c:^Control_Server,port:u16) {
    if !c.locked {return}
    bytes:[2+CONTROL_TOKEN]u8
    endian.unchecked_put_u16le(bytes[:],port)
    copy(bytes[2:],c.token[:])
    file:=string(c.file[:c.file_len])
    temp:=strings.concatenate({file,".tmp"},context.temp_allocator)
    if os.write_entire_file(temp,bytes[:],{.Read_User,.Write_User})==nil {
        if os.rename(temp,file)!=nil {os.remove(temp)}
    }
    crypto.zero_explicit(&bytes,size_of(bytes))
}

@(private)
control_end :: proc(c:^Control_Server) {
    if !c.locked {return}
    os.remove(string(c.file[:c.file_len]))
    lock_release(&c.lock)
    crypto.zero_explicit(c,size_of(Control_Server))
}

@(private)
loopback :: proc "contextless" (a:net.Address) -> bool {
    if a.kind==.IP4 {return a.ip[0]==127}
    return a.kind==.IP6 && a.ip==[16]u8{15=1}
}

// A request of a local process: hostile bytes are dropped unanswered.
@(private)
control_read :: proc(r:^Runner,from:net.Address,bytes:[]u8) {
    c:=&r.control
    if !c.locked || !loopback(from) || len(bytes)<CONTROL_HEAD {return}
    if crypto.compare_constant_time(bytes[1:1+CONTROL_TOKEN],c.token[:])!=1 {return}
    id:=endian.unchecked_get_u32le(bytes[1+CONTROL_TOKEN:])
    op:=bytes[CONTROL_HEAD-1]
    body:=bytes[CONTROL_HEAD:]
    out:[FRAME_MAX]u8
    out[0]=FRAME_ANSWER
    endian.unchecked_put_u32le(out[1:],id)
    w:=Answer_Writer{data=out[ANSWER_HEAD:]}
    m:=r.machine
    m.why=""
    error:=control_do(r,op,body,&w)
    if w.failed && error==.None {error=.Too_Large}
    out[5]=u8(error)
    size:=ANSWER_HEAD+w.at
    if error!=.None {
        why:=m.why!=""?m.why:error_text(error)
        size=ANSWER_HEAD+copy(out[ANSWER_HEAD:],why)
    }
    r.active=r.now
    runner_send(r,from,out[:size])
}

@(private)
Answer_Writer :: struct {data:[]u8,at:int,failed:bool}

@(private)
answer_put :: proc(w:^Answer_Writer,bytes:[]u8) {
    if w.at+len(bytes)>len(w.data) {
        w.failed=true
        return
    }
    copy(w.data[w.at:],bytes)
    w.at+=len(bytes)
}

@(private)
answer_text :: proc(w:^Answer_Writer,text:string) {
    n:=min(len(text),255)
    answer_put(w,{u8(n)})
    answer_put(w,transmute([]u8)text[:n])
}

// The text of length byte n at the front of bytes, and what follows.
@(private)
take_text :: proc(bytes:[]u8) -> (text:string,rest:[]u8,ok:bool) {
    if len(bytes)<1 || len(bytes)<1+int(bytes[0]) {return}
    n:=int(bytes[0])
    return string(bytes[1:1+n]),bytes[1+n:],true
}

@(private)
control_do :: proc(r:^Runner,op:u8,body:[]u8,w:^Answer_Writer) -> Error {
    if op>u8(max(Control_Op)) {return .Invalid_Argument}
    switch Control_Op(op) {
    case .None: return .Invalid_Argument
    case .Changed:
        namespace,rest,ok:=take_text(body)
        name,tail,named:=take_text(rest)
        if !ok || !named || len(tail)!=0 || !store_name(namespace) || (name!="" && !store_name(name)) {return .Invalid_Argument}
        runner_changed(r,namespace,name)
    case .Peers:
        if len(body)!=0 {return .Invalid_Argument}
        list:=make([dynamic]Runner_Peer_Info,context.temp_allocator)
        runner_peers(r,&list)
        orgs:=make([dynamic]Runner_Org_Info,context.temp_allocator)
        runner_orgs_info(r,&orgs)
        o:=min(len(orgs),255)
        n:=min(len(list),255,(len(w.data)-w.at-2-o*ORG_INFO_BYTES)/PEER_BYTES)
        answer_put(w,{u8(n)})
        for &p in list[:n] {
            answer_put(w,p.org[:])
            answer_put(w,p.dh[:])
            answer_put(w,{u8(p.class),u8(p.rung),u8(p.node)})
        }
        answer_put(w,{u8(o)})
        for &x in orgs[:o] {
            behind,unfound:=u16(min(x.behind,0xffff)),u16(min(x.unfound,0xffff))
            answer_put(w,x.org[:])
            answer_put(w,{u8(behind),u8(behind>>8),u8(unfound),u8(unfound>>8),u8(x.changes),u8(x.changes>>8),u8(x.changes>>16),u8(x.changes>>24)})
        }
    case .Pair_Offer:
        if len(body)!=3+32+CARRIED_ADDRESS || body[0]>u8(max(Pair_Mode)) || body[1]>u8(max(Role)) || body[35]>u8(net.Address_Kind.IP6) {return .Invalid_Argument}
        org:Log_Id
        copy(org[:],body[3:35])
        at:=net.Address{kind=net.Address_Kind(body[35]),port=endian.unchecked_get_u16le(body[36:])}
        copy(at.ip[:],body[38:])
        buffer:[TICKET_TEXT]u8
        ticket:=runner_pair_offer(r,Pair_Mode(body[0]),org,Role(body[1]),transmute(Node_Modes)body[2],&buffer,at) or_return
        answer_put(w,transmute([]u8)ticket)
    case .Pair_Request:
        if len(body)!=0 {return .Invalid_Argument}
        request,ok:=runner_pair_request(r)
        answer_put(w,{u8(ok),u8(request.mode)})
        if ok {
            answer_text(w,request.code)
            answer_text(w,request.name)
            answer_put(w,request.user[:])
            answer_put(w,request.device[:])
        }
    case .Pair_Answer:
        if len(body)<1 {return .Invalid_Argument}
        code,rest,ok:=take_text(body[1:])
        if !ok || len(rest)!=0 || len(code)>PAIR_CODE_TEXT {return .Invalid_Argument}
        runner_pair_answer(r,body[0]!=0,code) or_return
    case .Pair_Join:
        ticket,rest,ok:=take_text(body)
        name,tail,named:=take_text(rest)
        if !ok || !named || len(tail)!=0 {return .Invalid_Argument}
        runner_pair_join(r,ticket,name) or_return
    case .Pair_Progress:
        if len(body)!=0 {return .Invalid_Argument}
        p:=runner_pair_progress(r)
        answer_put(w,{u8(p.phase)})
        answer_text(w,p.code)
        answer_text(w,p.why)
    case .DDC_Ask:
        if len(body)!=64 {return .Invalid_Argument}
        org,key:Log_Id
        copy(org[:],body[:32])
        copy(key[:],body[32:])
        state,output_root:=runner_ddc_ask(r,org,key)
        answer_put(w,{u8(state)})
        answer_put(w,output_root[:])
    case .Object_Ask:
        if len(body)!=64 {return .Invalid_Argument}
        org,address:Log_Id
        copy(org[:],body[:32])
        copy(address[:],body[32:])
        answer_put(w,{u8(runner_object_ask(r,org,address))})
    case .Addresses:
        if len(body)!=0 {return .Invalid_Argument}
        list:=make([dynamic]net.Address,context.temp_allocator)
        runner_addresses(r,&list)
        n:=min(len(list),TICKET_ADDRESSES)
        answer_put(w,{u8(n)})
        for a in list[:n] {
            x,_:=node_address_of(a)
            answer_put(w,mem.ptr_to_bytes(&x))
        }
    }
    return .None
}

@(private)
store_name :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>store.NAME_MAX {return false}
    for c in transmute([]u8)name {
        if !((c>='a' && c<='z') || (c>='0' && c<='9') || c=='.' || c=='_' || c=='-') {return false}
    }
    return true
}

// The client end: a process that reaches the runner of a store.
Control :: struct {
    udp:net.Udp,
    to:net.Address,
    token:[CONTROL_TOKEN]u8,
    next:u32,
    why:string, // the runner's text of the last failure, in the temp allocator
}

// Reaches the runner of the store at root: Missing when none runs.
control_open :: proc(c:^Control,root:string) -> Error {
    c^={}
    folder:=root
    if folder=="" {folder=store.default_root(context.temp_allocator)}
    lock,e:=lock_take(strings.concatenate({folder,"/",AGENT_LOCK_FILE},context.temp_allocator))
    if e==.None {
        lock_release(&lock)
        c.why="no Kai agent runs for this store: mirai kai agent starts one"
        return .Missing
    }
    if e!=.Locked {
        c.why="the agent's lock file does not open: give this user access to the store"
        return e
    }
    bytes,read_error:=os.read_entire_file(strings.concatenate({folder,"/",AGENT_FILE},context.temp_allocator),context.temp_allocator)
    if read_error!=nil || len(bytes)!=2+CONTROL_TOKEN {
        c.why="the agent is starting: try again in a moment"
        return .Missing
    }
    c.to=net.address_loopback(int(endian.unchecked_get_u16le(bytes)))
    copy(c.token[:],bytes[2:])
    crypto.zero_explicit(raw_data(bytes),len(bytes))
    if !net.udp_open(&c.udp,net.address_loopback(0)) {
        c.why="no UDP socket opens on 127.0.0.1"
        return .Io
    }
    return .None
}

control_close :: proc(c:^Control) {
    net.udp_close(&c.udp)
    crypto.zero_explicit(&c.token,CONTROL_TOKEN)
}

// One request and its answer, the answer's body in out.
control_call :: proc(c:^Control,op:Control_Op,body:[]u8,out:^[FRAME_MAX]u8) -> (answer:[]u8,error:Error) {
    request:[FRAME_MAX]u8
    if CONTROL_HEAD+len(body)>FRAME_MAX {return nil,.Too_Large}
    c.next+=1
    id:=c.next
    request[0]=FRAME_LOCAL
    copy(request[1:],c.token[:])
    endian.unchecked_put_u32le(request[1+CONTROL_TOKEN:],id)
    request[CONTROL_HEAD-1]=u8(op)
    copy(request[CONTROL_HEAD:],body)
    t:=net.udp_transport(&c.udp)
    for _ in 0..<CONTROL_TRIES {
        batch:=[1]net.Datagram{{c.to,request[:CONTROL_HEAD+len(body)]}}
        t.send(t.data,batch[:])
        deadline:=time.tick_now()
        for time.duration_seconds(time.tick_since(deadline))<CONTROL_WAIT {
            t.wait(t.data,CONTROL_WAIT)
            receive:=[1]net.Datagram{{bytes=out[:]}}
            if t.receive(t.data,receive[:])==0 {continue}
            got:=receive[0].bytes
            if !loopback(receive[0].address) || receive[0].address.port!=c.to.port || len(got)<ANSWER_HEAD || got[0]!=FRAME_ANSWER || endian.unchecked_get_u32le(got[1:])!=id {continue}
            if got[5]>u8(max(Error)) {return nil,.Corrupt}
            error=Error(got[5])
            if error!=.None {
                c.why=strings.clone(string(got[ANSWER_HEAD:]),context.temp_allocator)
                return nil,error
            }
            return got[ANSWER_HEAD:],.None
        }
    }
    c.why="the agent does not answer: it may have stopped"
    return nil,.Io
}

control_changed :: proc(c:^Control,namespace,name:string) -> Error {
    body:[2+2*store.NAME_MAX]u8
    if len(namespace)>255 || len(name)>255 {return .Invalid_Argument}
    body[0]=u8(len(namespace))
    copy(body[1:],namespace)
    body[1+len(namespace)]=u8(len(name))
    copy(body[2+len(namespace):],name)
    out:[FRAME_MAX]u8
    _,e:=control_call(c,.Changed,body[:2+len(namespace)+len(name)],&out)
    return e
}

// What Machine.changed calls in a process the runner is not in.
control_machine_changed :: proc(c:^Control) -> Machine_Changed {
    return {data=c,procedure=proc(data:rawptr,namespace,name:string) {control_changed((^Control)(data),namespace,name)}}
}

// The runner's peers, and of each org it serves how far behind it is.
control_peers :: proc(c:^Control,list:^[dynamic]Runner_Peer_Info,orgs:^[dynamic]Runner_Org_Info=nil) -> Error {
    out:[FRAME_MAX]u8
    answer:=control_call(c,.Peers,nil,&out) or_return
    return peers_parse(answer,list,orgs)
}

@(private)
peers_parse :: proc(answer:[]u8,list:^[dynamic]Runner_Peer_Info,orgs:^[dynamic]Runner_Org_Info) -> Error {
    if len(answer)<2 || len(answer)<2+int(answer[0])*PEER_BYTES {return .Corrupt}
    n:=int(answer[0])
    o:=int(answer[1+n*PEER_BYTES])
    if len(answer)!=2+n*PEER_BYTES+o*ORG_INFO_BYTES {return .Corrupt}
    for k in 0..<n {
        e:=answer[1+k*PEER_BYTES:][:PEER_BYTES]
        p:Runner_Peer_Info
        copy(p.org[:],e[:32])
        copy(p.dh[:],e[32:64])
        if e[64]>u8(max(Agent_Class)) || e[65]>u8(max(Rung)) {return .Corrupt}
        p.class,p.rung,p.node=Agent_Class(e[64]),Rung(e[65]),e[66]!=0
        append(list,p)
    }
    if orgs==nil {return .None}
    for k in 0..<o {
        e:=answer[2+n*PEER_BYTES+k*ORG_INFO_BYTES:][:ORG_INFO_BYTES]
        x:Runner_Org_Info
        copy(x.org[:],e[:32])
        x.behind,x.unfound=int(e[32])|int(e[33])<<8,int(e[34])|int(e[35])<<8
        x.changes=u32(e[36])|u32(e[37])<<8|u32(e[38])<<16|u32(e[39])<<24
        append(orgs,x)
    }
    return .None
}

// Asks the org's peers for the object at address, as the bytes of a file of a
// change still on its way: whole says it is in the runner's store now.
control_object_ask :: proc(c:^Control,org:Log_Id,address:store.Hash) -> (whole:bool,error:Error) {
    body:[64]u8
    o,a:=org,address
    copy(body[:],o[:])
    copy(body[32:],a[:])
    buffer:[FRAME_MAX]u8
    answer:=control_call(c,.Object_Ask,body[:],&buffer) or_return
    if len(answer)!=1 || answer[0]>1 {return false,.Corrupt}
    return answer[0]==1,.None
}

// The addresses the runner's socket is reached at, as a ticket gives them.
control_addresses :: proc(c:^Control,out:^[dynamic]net.Address) -> Error {
    buffer:[FRAME_MAX]u8
    answer:=control_call(c,.Addresses,nil,&buffer) or_return
    if len(answer)<1 || len(answer)!=1+int(answer[0])*size_of(Node_Address) {return .Corrupt}
    for a in slice.reinterpret([]Node_Address,answer[1:]) {
        if address,ok:=node_address_net(a);ok {append(out,address)}
    }
    return .None
}

control_pair_offer :: proc(c:^Control,mode:Pair_Mode,org:Log_Id,role:Role,modes:Node_Modes,buffer:^[TICKET_TEXT]u8,at:=net.Address{}) -> (ticket:string,error:Error) {
    body:[3+32+CARRIED_ADDRESS]u8
    body[0],body[1],body[2]=u8(mode),u8(role),transmute(u8)modes
    id:=org
    copy(body[3:],id[:])
    body[35]=u8(at.kind)
    endian.unchecked_put_u16le(body[36:],at.port)
    ip:=at.ip
    copy(body[38:],ip[:])
    out:[FRAME_MAX]u8
    answer:=control_call(c,.Pair_Offer,body[:],&out) or_return
    if len(answer)>TICKET_TEXT {return "",.Corrupt}
    return string(buffer[:copy(buffer[:],answer)]),.None
}

// The open pairing request of the runner; its strings in the temp allocator.
control_pair_request :: proc(c:^Control) -> (request:Pair_Request,ok:bool,error:Error) {
    out:[FRAME_MAX]u8
    answer:=control_call(c,.Pair_Request,nil,&out) or_return
    return pair_request_parse(answer)
}

@(private)
pair_request_parse :: proc(answer:[]u8) -> (request:Pair_Request,ok:bool,error:Error) {
    if len(answer)<2 || answer[1]>u8(max(Pair_Mode)) {return {},false,.Corrupt}
    if answer[0]==0 {return {},false,.None}
    request.mode=Pair_Mode(answer[1])
    code,rest,read:=take_text(answer[2:])
    name,tail,named:=take_text(rest)
    if !read || !named || len(tail)!=64 {return {},false,.Corrupt}
    request.code=strings.clone(code,context.temp_allocator)
    request.name=strings.clone(name,context.temp_allocator)
    copy(request.user[:],tail[:32])
    copy(request.device[:],tail[32:])
    return request,true,.None
}

control_pair_answer :: proc(c:^Control,approve:bool,code:string) -> Error {
    if len(code)>PAIR_CODE_TEXT {return .Invalid_Argument}
    body:[2+PAIR_CODE_TEXT]u8
    body[0],body[1]=u8(approve),u8(len(code))
    copy(body[2:],code)
    out:[FRAME_MAX]u8
    _,e:=control_call(c,.Pair_Answer,body[:2+len(code)],&out)
    return e
}

control_pair_join :: proc(c:^Control,ticket,name:string) -> Error {
    if len(ticket)>255 || len(name)>255 {return .Invalid_Argument}
    body:[2+255+255]u8
    body[0]=u8(len(ticket))
    copy(body[1:],ticket)
    body[1+len(ticket)]=u8(len(name))
    copy(body[2+len(ticket):],name)
    out:[FRAME_MAX]u8
    _,e:=control_call(c,.Pair_Join,body[:2+len(ticket)+len(name)],&out)
    return e
}

// How the pairing this machine joins goes; its strings in the temp allocator.
control_pair_progress :: proc(c:^Control) -> (progress:Pair_Progress,error:Error) {
    out:[FRAME_MAX]u8
    answer:=control_call(c,.Pair_Progress,nil,&out) or_return
    return pair_progress_parse(answer)
}

@(private)
pair_progress_parse :: proc(answer:[]u8) -> (progress:Pair_Progress,error:Error) {
    if len(answer)<1 || answer[0]>u8(max(Pair_Phase)) {return {},.Corrupt}
    code,rest,read:=take_text(answer[1:])
    why,tail,said:=take_text(rest)
    if !read || !said || len(tail)!=0 {return {},.Corrupt}
    return {phase=Pair_Phase(answer[0]),code=strings.clone(code,context.temp_allocator),why=strings.clone(why,context.temp_allocator)},.None
}

// What runner_ddc_ask answers: Found with the output_root of a record whose
// every object is whole in the runner's store.
control_ddc_ask :: proc(c:^Control,org:Log_Id,key:store.Hash) -> (state:DDC_State,output_root:store.Hash,error:Error) {
    body:[64]u8
    o,k:=org,key
    copy(body[:],o[:])
    copy(body[32:],k[:])
    out:[FRAME_MAX]u8
    answer:=control_call(c,.DDC_Ask,body[:],&out) or_return
    return ddc_answer_parse(answer)
}

@(private)
ddc_answer_parse :: proc(answer:[]u8) -> (state:DDC_State,output_root:store.Hash,error:Error) {
    if len(answer)!=33 || answer[0]>u8(max(DDC_State)) {return .Missing,{},.Corrupt}
    copy(output_root[:],answer[1:])
    return DDC_State(answer[0]),output_root,.None
}

