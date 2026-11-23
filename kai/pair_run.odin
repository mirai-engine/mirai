package kai

import "core:slice"
import "core:strings"
import "core:time"
import net "mirai:net"

// The runner's part of pairing (pair.odin): the offer this machine makes and
// the pairing it joins, over the P frames of the runner's socket.

PAIR_RESEND :: 1.0             // seconds between repeats of a pairing message
PAIR_JOIN_SECONDS :: 30        // a joiner gives up on a responder that does not answer
PAIR_TICKET_SECONDS :: 10*60   // a ticket lasts

// What a request to pair this machine's user, org or node shows the person
// who answers it.
Pair_Request :: struct {
    mode:Pair_Mode,
    code:string,
    name:string,        // what the other end calls itself
    user:Log_Id,        // Member: the user that joins
    device:Key,
}

Pair_Phase :: enum u8 {None,Asking,Waiting,Approved,Denied,Failed}

// How a pairing this machine joins goes.
Pair_Progress :: struct {
    phase:Pair_Phase,
    code:string,        // once both ends have it
    why:string,         // Failed: what failed and how to fix it
}

@(private)
Pair_Offer :: struct {
    active:bool,
    ticket:Ticket,
    org:Log_Id,
    role:Role,
    modes:Node_Modes,
    gate:Pair_Gate,
    pair:Pair,
    from:net.Address,
    step:Pair_Message,   // what was read last
    shown:bool,          // the code waits for an answer
    last:[FRAME_MAX+PAIR_PAYLOAD_MAX]u8,
    last_len:int,
    name:[NAME_MAX]u8,
    name_len:int,
    info:Pair_Info,
    closes:f64,          // a finished pairing answers repeats until then
    at:net.Address,      // where the other machine listens, when this one cannot be reached: knocked until it asks
    knocked:f64,
}

@(private)
Pair_Join :: struct {
    active:bool,
    ticket:Ticket,
    pair:Pair,
    phase:Pair_Phase,
    to:net.Address,      // the responder, once it answered
    knock:net.Address,   // where a knock of this ticket came from: asked as the ticket's addresses are
    last:[FRAME_MAX]u8,
    last_len:int,
    keys:[PAIR_KEM_PARTS][1+PAIR_K_SIZE]u8, // a device's K frames, sent with each repeat of P3
    key_frames:int,
    sent:f64,
    started:f64,
    name:[NAME_MAX]u8,
    name_len:int,
    why:string,
    code:[PAIR_CODE_TEXT]u8,
}

// Offers a pairing: the ticket the other device takes, valid for
// PAIR_TICKET_SECONDS. Device links a second device of this machine's user;
// Member adds a user to org with role; Node adds a node with modes.
// With at, the address the other machine listens at, this end knocks there
// until the other asks: a machine behind a router that no ticket address
// reaches is asked through the way its own knocks opened.
runner_pair_offer :: proc(r:^Runner,mode:Pair_Mode,org:Log_Id,role:Role,modes:Node_Modes,buffer:^[TICKET_TEXT]u8,at:=net.Address{}) -> (ticket:string,error:Error) {
    m:=r.machine
    switch mode {
    case .Device:
        if m.user=={} {return "",machine_fail(m,.Invalid_Argument,"this device has no user to link another device to: mirai kai identity makes one")}
    case .Member:
        if !role_valid(role) {return "",machine_fail(m,.Invalid_Argument,"a member's role is reader, writer or admin")}
        if !slice.contains(m.orgs[:],org) {return "",machine_fail(m,.Invalid_Argument,"this machine does not serve that org")}
    case .Node:
        if modes=={} {return "",machine_fail(m,.Invalid_Argument,"a node serves relay, seed or ddc")}
        if !slice.contains(m.orgs[:],org) {return "",machine_fail(m,.Invalid_Argument,"this machine does not serve that org")}
    case .Recover:
        if !slice.contains(m.orgs[:],org) {return "",machine_fail(m,.Invalid_Argument,"this machine does not serve that org")}
    }
    if r.offer.active && r.offer.shown {return "",machine_fail(m,.Locked,"another pairing request waits for an answer: answer it first")}
    pair_end(&r.offer.pair)
    gate:=r.offer.gate
    r.offer={active=true,org=org,role=role,modes=modes,gate=gate,at=at,knocked=-PAIR_RESEND}
    t:=&r.offer.ticket
    t.id=random_id([16]u8)
    t.responder=Dh_Key(m.dh.public)
    t.mode=mode
    t.expires=time.now()._nsec+i64(PAIR_TICKET_SECONDS)*1_000_000_000
    list:=make([dynamic]net.Address,context.temp_allocator)
    runner_addresses(r,&list)
    // A node or a device on this same machine reaches it by loopback, which
    // a host firewall lets through where it drops the LAN address.
    if loopback:=net.address_ip4(127,0,0,1,int(r.port));!slice.contains(list[:],loopback) {
        inject_at(&list,min(len(list),TICKET_ADDRESSES-1),loopback)
    }
    t.address_count=copy(t.addresses[:],list[:])
    return ticket_encode(t^,buffer),.None
}

// The open request, once the other end revealed its keys and the code exists.
runner_pair_request :: proc(r:^Runner) -> (request:Pair_Request,ok:bool) {
    o:=&r.offer
    if !o.active || !o.shown {return}
    return {mode=o.ticket.mode,code=pair_code(&o.pair),name=string(o.name[:o.name_len]),user=o.info.log_id,device=o.info.device},true
}

// The person's answer to the open request; when code is given it must be the
// one shown, or the request is denied.
runner_pair_answer :: proc(r:^Runner,approve:bool,code:string="") -> Error {
    m:=r.machine
    o:=&r.offer
    if !o.active || !o.shown {return machine_fail(m,.Missing,"no pairing request waits for an answer")}
    now:=time.now()._nsec
    yes:=approve && (code=="" || code==pair_code(&o.pair))
    payload:=make([dynamic]u8,context.temp_allocator)
    if yes {
        switch o.ticket.mode {
        case .Device:
            l:Log
            log_init(&l,m.user,context.temp_allocator)
            if e:=log_open(&m.store,&l,m.user,.User);e!=.None {return machine_fail(m,e,"this device's User_Log is not in its store")}
            if _,e:=pair_approve_device(&o.pair,&l,&m.identity,now);e!=.None {return machine_fail(m,e,"the device's proof does not hold: pair again")}
            machine_log_save(m,&l) or_return
            id:=m.user
            append(&payload,..id[:])
            for org in m.orgs {
                g:=org
                append(&payload,..g[:])
            }
        case .Member:
            // One who is a member already keeps its role: the pairing only
            // brings its machine to this one again.
            member:=false
            {
                s:Org_State
                machine_org_open(m,o.org,&s) or_return
                member=org_role(&s.fold,o.info.log_id)!=.None
                org_state_destroy(&s)
            }
            if !member {machine_member_add(m,o.org,o.info.log_id,o.role) or_return}
            id:=o.org
            append(&payload,..id[:])
        case .Node:
            machine_node_add(m,o.org,o.info.device,pair_remote(&o.pair),o.modes,{o.from}) or_return
            id:=o.org
            append(&payload,..id[:])
        case .Recover:
            // Nothing is signed: the other machine reaches the org as a peer
            // not admitted, which reads the user logs alone, until its user
            // is recovered onto it.
            id:=o.org
            append(&payload,..id[:])
        }
    }
    runner_pair_finish(r,yes?.Approved:.Denied,payload[:])
    if approve && !yes {return machine_fail(m,.Unauthorized,"the code is not the one the other device shows: the request is denied, pair again")}
    return .None
}

@(private)
runner_pair_finish :: proc(r:^Runner,status:Pair_Status,payload:[]u8) {
    o:=&r.offer
    message,e:=pair_write_p4(&o.pair,status,payload,o.last[1:])
    if e==.None {
        o.last[0]=FRAME_PAIR
        o.last_len=1+len(message)
        runner_send(r,o.from,o.last[:o.last_len])
    }
    pair_gate_close(&o.gate,status==.Approved,time.now()._nsec)
    o.shown=false
    o.closes=r.now+PAIR_JOIN_SECONDS
    runner_event(r,"pairing %v",status)
}

// Joins a pairing with the ticket another machine offered; name is what this
// end calls itself. runner_pair_progress tells how it goes.
runner_pair_join :: proc(r:^Runner,text:string,name:string) -> Error {
    m:=r.machine
    t,ok:=ticket_decode(strings.trim_space(text))
    if !ok {return machine_fail(m,.Corrupt,"the ticket does not read: copy it again, whole")}
    if t.expires<time.now()._nsec {return machine_fail(m,.Expired,"the ticket expired: ask for a new one")}
    if t.address_count==0 {return machine_fail(m,.Invalid_Argument,"the ticket names no address to reach the other machine at")}
    if !name_valid(name) {return machine_fail(m,.Invalid_Argument,"a name is 1 to 64 bytes of text")}
    switch t.mode {
    case .Device: if m.user!={} {return machine_fail(m,.Invalid_Argument,"this device belongs to a user already: only a device without one is linked")}
    case .Member: if m.user=={} {return machine_fail(m,.Invalid_Argument,"this device has no user: mirai kai identity makes one first")}
    case .Recover: if m.user!={} {return machine_fail(m,.Invalid_Argument,"this device belongs to a user already: a user is recovered onto a device that has none")}
    case .Node:
    }
    if r.join.active {return machine_fail(m,.Locked,"this machine is joining another pairing: wait for it to end")}
    pair_end(&r.join.pair)
    r.join={active=true,ticket=t,phase=.Asking,started=r.now}
    r.join.name_len=copy(r.join.name[:],name)
    pair_init(&r.join.pair,true,m.dh,t.id,t.responder)
    message,e:=pair_write_p1(&r.join.pair,r.join.last[1:])
    if e!=.None {return machine_fail(m,.Invalid_Argument,pair_error_text(e))}
    r.join.last[0]=FRAME_PAIR
    r.join.last_len=1+len(message)
    runner_pair_resend(r)
    return .None
}

runner_pair_progress :: proc(r:^Runner) -> Pair_Progress {
    j:=&r.join
    p:=Pair_Progress{phase=j.phase,why=j.why}
    if j.code[0]!=0 {p.code=string(j.code[:])}
    return p
}

@(private)
runner_pair_resend :: proc(r:^Runner) {
    j:=&r.join
    j.sent=r.now
    if j.to.kind!=.None {
        runner_send(r,j.to,j.last[:j.last_len])
        for k in 0..<j.key_frames {runner_send(r,j.to,j.keys[k][:])}
        return
    }
    for a in j.ticket.addresses[:j.ticket.address_count] {runner_send(r,a,j.last[:j.last_len])}
    if j.knock.kind!=.None {runner_send(r,j.knock,j.last[:j.last_len])}
}

@(private)
runner_pair_fail :: proc(r:^Runner,why:string) {
    j:=&r.join
    j.phase,j.why,j.active=.Failed,why,false
    pair_end(&j.pair)
    runner_event(r,"pairing failed: %s",why)
}

@(private)
runner_pair_step :: proc(r:^Runner) {
    j:=&r.join
    if j.active {
        limit:=j.phase==.Waiting?f64(PAIR_TIMEOUT/1_000_000_000):PAIR_JOIN_SECONDS
        if r.now-j.started>limit {
            runner_pair_fail(r,"the other machine did not answer: check that its agent runs and the ticket's addresses reach it")
        } else if r.now-j.sent>PAIR_RESEND {
            runner_pair_resend(r)
        }
    }
    o:=&r.offer
    if o.active {
        now:=time.now()._nsec
        if o.shown && pair_gate_expire(&o.gate,now) {
            runner_pair_finish(r,.Denied,nil)
        }
        if !o.shown && o.closes>0 && r.now>o.closes {o.active=false}
        if now>o.ticket.expires && !o.shown {o.active=false}
        if o.active && o.at.kind!=.None && o.step==.None && r.now-o.knocked>=PAIR_RESEND {
            o.knocked=r.now
            frame:[1+PAIR_HEAD]u8
            frame[0],frame[1]=FRAME_PAIR,u8(Pair_Message.Knock)
            tag:=pair_knock_tag(o.ticket.id)
            copy(frame[2:],tag[:])
            runner_send(r,o.at,frame[:])
        }
    }
}

// A pairing message from from.
@(private)
runner_pair_read :: proc(r:^Runner,from:net.Address,message:[]u8) {
    if len(message)<PAIR_HEAD {return}
    switch Pair_Message(message[0]) {
    case .None:
    case .P1,.P3,.K: runner_pair_responder(r,from,message)
    case .P2,.P4: runner_pair_initiator(r,from,message)
    case .Knock:
        // Kept and asked with the next repeat: a knock is answered by nothing.
        j:=&r.join
        tag:=pair_knock_tag(j.ticket.id)
        if j.active && j.phase==.Asking && bytes_equal(message[1:PAIR_HEAD],tag[:]) {j.knock=from}
    }
}

@(private)
runner_pair_responder :: proc(r:^Runner,from:net.Address,message:[]u8) {
    m:=r.machine
    o:=&r.offer
    if !o.active || !bytes_equal(message[1:PAIR_HEAD],o.ticket.id[:]) {return}
    now:=time.now()._nsec
    // A repeat of what was answered gets the same answer.
    if o.step>=Pair_Message(message[0]) && from==o.from {
        if o.last_len>0 {runner_send(r,from,o.last[:o.last_len])}
        return
    }
    if o.closes>0 {return}
    switch Pair_Message(message[0]) {
    case .P1:
        if now>o.ticket.expires || o.step!=.None {return}
        if pair_gate_open(&o.gate,o.ticket.id,now)!=.None {return}
        pair_init(&o.pair,false,m.dh,o.ticket.id)
        if pair_read_p1(&o.pair,message)!=.None {
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            return
        }
        info:=Pair_Info{mode=o.ticket.mode,log_id=o.ticket.mode==.Device?m.user:o.org,device=m.identity.key}
        buffer:[PAIR_INFO_MAX]u8
        out,e:=pair_write_p2(&o.pair,pair_info_encode(info,"",&buffer),o.last[1:])
        if e!=.None {return}
        o.last[0]=FRAME_PAIR
        o.last_len=1+len(out)
        o.from,o.step=from,.P1
        runner_send(r,from,o.last[:o.last_len])
    case .P3:
        if o.step!=.P1 || from!=o.from {return}
        e:=pair_read_p3(&o.pair,message)
        if e!=.None {
            runner_event(r,"pairing refused: %s",pair_error_text(e))
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            o.step=.None
            return
        }
        info,name,ok:=pair_info_decode(pair_info(&o.pair))
        if !ok || info.mode!=o.ticket.mode || (info.mode==.Member && info.log_id=={}) {
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            o.step=.None
            return
        }
        o.info=info
        o.name_len=copy(o.name[:],name)
        o.step=.P3
        // A device shows once its ML-KEM key came whole in the K frames.
        if info.mode!=.Device {runner_pair_show(r)}
    case .K:
        if o.step!=.P3 || from!=o.from {return}
        if o.shown {
            runner_send(r,from,o.last[:o.last_len])
            return
        }
        complete,e:=pair_read_key(&o.pair,message,o.info.kem)
        if e==.Key {
            runner_event(r,"pairing refused: %s",pair_error_text(e))
            pair_gate_close(&o.gate,false,now)
            pair_end(&o.pair)
            o.step=.None
            return
        }
        if complete {runner_pair_show(r)}
    case .None,.P2,.P4,.Knock:
    }
}

// Shows the open request: its code waits for the person's answer.
@(private)
runner_pair_show :: proc(r:^Runner) {
    o:=&r.offer
    o.shown=true
    runner_event(r,"pairing request from %s: code %s",string(o.name[:o.name_len]),pair_code(&o.pair))
    out,_:=pair_write_p4(&o.pair,.Pending,nil,o.last[1:])
    o.last[0]=FRAME_PAIR
    o.last_len=1+len(out)
    runner_send(r,o.from,o.last[:o.last_len])
}

@(private)
runner_pair_initiator :: proc(r:^Runner,from:net.Address,message:[]u8) {
    m:=r.machine
    j:=&r.join
    if !j.active || !bytes_equal(message[1:PAIR_HEAD],j.ticket.id[:]) {return}
    switch Pair_Message(message[0]) {
    case .P2:
        if j.phase!=.Asking || j.pair.step!=.P1 {return}
        if e:=pair_read_p2(&j.pair,message);e!=.None {
            runner_pair_fail(r,pair_error_text(e))
            return
        }
        remote,_,ok:=pair_info_decode(pair_info(&j.pair))
        if !ok || remote.mode!=j.ticket.mode {
            runner_pair_fail(r,"the other machine answers another kind of pairing: ask for a new ticket")
            return
        }
        info:=Pair_Info{mode=j.ticket.mode,device=m.identity.key}
        switch j.ticket.mode {
        case .Device:
            info.kem=machine_kem_hash(m)
            info.proof=device_proof(&m.identity,transmute([32]u8)remote.log_id,Dh_Key(m.dh.public),info.kem)
        case .Member: info.log_id=m.user
        case .Node,.Recover:
        }
        buffer:[PAIR_INFO_MAX]u8
        out,e:=pair_write_p3(&j.pair,pair_info_encode(info,string(j.name[:j.name_len]),&buffer),j.last[1:])
        if e!=.None {
            runner_pair_fail(r,pair_error_text(e))
            return
        }
        j.last_len=1+len(out)
        if j.ticket.mode==.Device {
            kem:=machine_kem_public(m)
            for k in 0..<PAIR_KEM_PARTS {
                j.keys[k][0]=FRAME_PAIR
                pair_write_key(&j.pair,&kem,k,j.keys[k][1:])
            }
            j.key_frames=PAIR_KEM_PARTS
        }
        j.to,j.phase,j.code=from,.Waiting,j.pair.code
        runner_pair_resend(r)
        runner_event(r,"pairing code %s: check that the other machine shows the same",string(j.code[:]))
    case .P4:
        if j.phase!=.Waiting || from!=j.to {return}
        status,payload,e:=pair_read_p4(&j.pair,message)
        if e!=.None {return}
        switch status {
        case .Pending: j.started=r.now
        case .Denied:
            runner_pair_fail(r,"the other machine denied the pairing: compare the codes and pair again")
            j.phase=.Denied
        case .Approved:
            if runner_pair_take(r,payload) {
                j.phase,j.active=.Approved,false
                runner_event(r,"pairing approved")
            }
        }
    case .None,.P1,.P3,.K,.Knock:
    }
}

// What an approved pairing gave: the user this device joins and its orgs,
// or the org this member or node joins.
@(private)
runner_pair_take :: proc(r:^Runner,payload:[]u8) -> bool {
    m:=r.machine
    j:=&r.join
    if len(payload)<32 || len(payload)%32!=0 || len(payload)/32>MACHINE_ORGS_MAX+1 {
        runner_pair_fail(r,"the other machine's answer does not read: pair again")
        return false
    }
    ids:=slice.reinterpret([]Log_Id,payload)
    orgs:=ids
    if j.ticket.mode==.Device {
        if machine_user_set(m,ids[0])!=.None {
            runner_pair_fail(r,m.why)
            return false
        }
        orgs=ids[1:]
    }
    for id in orgs {
        if machine_org_join(m,id)!=.None {
            runner_pair_fail(r,m.why)
            return false
        }
    }
    runner_reload(r)
    // This end connects to the machine it paired with, whatever the keys say.
    for o in r.orgs {
        if !slice.contains(orgs,o.id) {continue}
        k:=runner_peer_index(o,j.ticket.responder)
        if k<0 && len(o.peers)<RUNNER_PEERS {
            append(&o.peers,Runner_Peer{dh=j.ticket.responder,attempt=-1})
            k=len(o.peers)-1
        }
        if k<0 {continue}
        p:=&o.peers[k]
        p.first,p.lan,p.lan_seen,p.stage,p.next_try=true,j.to,r.now,0,0
    }
    return true
}
