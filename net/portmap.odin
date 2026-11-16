package mirai_net

import "base:runtime"
import "core:crypto"
import cnet "core:net"
import "core:sync"
import "core:thread"
import "core:time"

Port_Mapping_Method :: enum u8 {None, Direct, PCP, NAT_PMP, UPnP}
Port_Mapping_Phase :: enum u8 {Pending, Mapped, Unavailable, Closed}
Port_Mapping_Status :: struct {
    phase:Port_Mapping_Phase,
    method:Port_Mapping_Method,
    external:Address,
    lease_seconds:u32,
}

Port_Mapping :: struct {
    worker:^thread.Thread,
    allocator:runtime.Allocator,
    lock:sync.Mutex,
    status:Port_Mapping_Status,
    stop:bool,
    port:u16,
    gateway:Address,
    discovery_port:u16,
}

// gateway is optional; a literal override also lets a local router fixture exercise the protocols.
mapping_start :: proc(m:^Port_Mapping,port:u16,allocator:=context.allocator,gateway:=Address{},discovery_port:u16=1900) -> bool {
    if m.worker!=nil || port==0 {return false}
    m^={allocator=allocator,port=port,gateway=gateway,discovery_port=discovery_port,status={phase=.Pending}}
    context.allocator=allocator
    m.worker=thread.create(proc(t:^thread.Thread) {portmap_worker((^Port_Mapping)(t.data))})
    if m.worker==nil {m.status.phase=.Unavailable;return false}
    m.worker.data=m
    thread.start(m.worker)
    return true
}

mapping_poll :: proc(m:^Port_Mapping) -> Port_Mapping_Status {
    sync.mutex_guard(&m.lock)
    return m.status
}

mapping_stop :: proc(m:^Port_Mapping) {sync.atomic_store_explicit(&m.stop,true,.Release)}

mapping_close :: proc(m:^Port_Mapping) {
    mapping_stop(m)
    if m.worker!=nil {
        thread.join(m.worker)
        context.allocator=m.allocator
        thread.destroy(m.worker)
    }
    m^={status={phase=.Closed}}
}

@(private)
Portmap_Lease :: struct {
    method:Port_Mapping_Method,
    external:Address,
    seconds:u32,
    nonce:[12]u8,
    upnp:Portmap_UPnP,
}

@(private)
portmap_stopped :: proc(m:^Port_Mapping) -> bool {return sync.atomic_load_explicit(&m.stop,.Acquire)}
@(private)
portmap_publish :: proc(m:^Port_Mapping,status:Port_Mapping_Status) {sync.mutex_guard(&m.lock);m.status=status}
@(private)
portmap_seconds :: proc(start:time.Tick) -> f64 {return time.duration_seconds(time.tick_since(start))}
@(private)
portmap_pause :: proc() {time.sleep(10*time.Millisecond)}

@(private)
portmap_worker :: proc(m:^Port_Mapping) {
    context.allocator=m.allocator
    gateway:=m.gateway
    if gateway.kind==.None {gateway=portmap_gateway()}
    if gateway.kind!=.IP4 {portmap_publish(m,{phase=.Unavailable});return}
    if gateway.port==0 {gateway.port=5351}
    probe,error:=cnet.make_unbound_udp_socket(.IP4)
    if error!=nil {portmap_publish(m,{phase=.Unavailable});return}
    if !portmap_socket_connect(cnet.Socket(probe),gateway) {cnet.close(probe);portmap_publish(m,{phase=.Unavailable});return}
    endpoint,ep_error:=cnet.bound_endpoint(probe)
    cnet.close(probe)
    local:=address_from_endpoint(endpoint)
    if ep_error!=nil || local.kind!=.IP4 {portmap_publish(m,{phase=.Unavailable});return}
    if portmap_public(local) {
        local.port=m.port
        portmap_publish(m,{phase=.Mapped,method=.Direct,external=local})
        return
    }
    local.port=0
    udp:Udp
    if !udp_open(&udp,local) {portmap_publish(m,{phase=.Unavailable});return}
    defer udp_close(&udp)
    lease:Portmap_Lease
    crypto.rand_bytes(lease.nonce[:])
    if !portmap_stopped(m) && portmap_pcp(m,&udp,gateway,local,&lease,3600) {lease.method=.PCP}
    if lease.method==.None && !portmap_stopped(m) && portmap_natpmp(m,&udp,gateway,&lease,3600) {lease.method=.NAT_PMP}
    if lease.method==.None && !portmap_stopped(m) && portmap_upnp_acquire(m,&udp,gateway,local,&lease) {lease.method=.UPnP}
    if lease.method==.None {
        portmap_publish(m,{phase=portmap_stopped(m)?.Closed:.Unavailable})
        return
    }
    if !portmap_public(lease.external) {
        portmap_release(m,&udp,gateway,local,&lease)
        portmap_publish(m,{phase=.Unavailable})
        return
    }
    portmap_publish(m,{phase=.Mapped,method=lease.method,external=lease.external,lease_seconds=lease.seconds})
    clock:=time.tick_now()
    expires:=f64(lease.seconds)
    renew:=expires/2
    if lease.seconds==0 {renew=1800;expires=1e30}
    for !portmap_stopped(m) {
        now:=portmap_seconds(clock)
        if now>=renew {
            ok:=false
            #partial switch lease.method {
            case .PCP: ok=portmap_pcp(m,&udp,gateway,local,&lease,3600)
            case .NAT_PMP: ok=portmap_natpmp(m,&udp,gateway,&lease,3600)
            case .UPnP: ok=portmap_upnp_renew(m,local,&lease)
            case: break
            }
            now=portmap_seconds(clock)
            if ok && !portmap_public(lease.external) {
                portmap_publish(m,{phase=.Unavailable})
                break
            } else if ok {
                expires=now+f64(lease.seconds)
                renew=now+f64(lease.seconds)/2
                if lease.seconds==0 {renew=now+1800;expires=1e30}
                portmap_publish(m,{phase=.Mapped,method=lease.method,external=lease.external,lease_seconds=lease.seconds})
            } else if now>=expires {
                portmap_publish(m,{phase=.Unavailable})
                break
            } else {renew=min(expires,now+min(30.0,max(0.1,(expires-now)/4)))}
        }
        time.sleep(50*time.Millisecond)
    }
    portmap_release(m,&udp,gateway,local,&lease)
    if portmap_stopped(m) {portmap_publish(m,{phase=.Closed})}
}

@(private)
portmap_release :: proc(m:^Port_Mapping,u:^Udp,gateway,local:Address,lease:^Portmap_Lease) {
    #partial switch lease.method {
    case .PCP:
        bytes:=portmap_pcp_request(local,m.port,lease.external,lease.nonce,0)
        for _ in 0..<3 {udp_send(u,gateway,bytes[:]);time.sleep(20*time.Millisecond)}
    case .NAT_PMP:
        bytes:=portmap_natpmp_request(m.port,lease.external.port,0)
        for _ in 0..<3 {udp_send(u,gateway,bytes[:]);time.sleep(20*time.Millisecond)}
    case .UPnP: portmap_upnp_release(m,local,lease)
    case: break
    }
}

@(private)
portmap_public :: proc(a:Address) -> bool {
    if a.port==0 && a.kind==.None {return false}
    if a.kind==.IP4 {
        ip:=a.ip
        return ip[0]!=0 && ip[0]!=10 && ip[0]!=127 && ip[0]<224 &&
            !(ip[0]==100 && ip[1]>=64 && ip[1]<=127) && !(ip[0]==169 && ip[1]==254) &&
            !(ip[0]==172 && ip[1]>=16 && ip[1]<=31) && !(ip[0]==192 && ip[1]==168) &&
            !(ip[0]==192 && ip[1]==0 && (ip[2]==0 || ip[2]==2)) &&
            !(ip[0]==198 && ((ip[1]==18 || ip[1]==19) || (ip[1]==51 && ip[2]==100))) &&
            !(ip[0]==203 && ip[1]==0 && ip[2]==113)
    }
    if a.kind==.IP6 {return a.ip[0]&0xe0==0x20}
    return false
}

@(private)
portmap_put16 :: proc(b:[]u8,v:u16) {b[0]=u8(v>>8);b[1]=u8(v)}
@(private)
portmap_put32 :: proc(b:[]u8,v:u32) {b[0]=u8(v>>24);b[1]=u8(v>>16);b[2]=u8(v>>8);b[3]=u8(v)}
@(private)
portmap_get16 :: proc(b:[]u8) -> u16 {return u16(b[0])<<8|u16(b[1])}
@(private)
portmap_get32 :: proc(b:[]u8) -> u32 {return u32(b[0])<<24|u32(b[1])<<16|u32(b[2])<<8|u32(b[3])}
@(private)
portmap_ip16 :: proc(a:Address) -> (bytes:[16]u8) {
    if a.kind==.IP4 {bytes[10]=255;bytes[11]=255;for i in 0..<4 {bytes[12+i]=a.ip[i]}} else if a.kind==.IP6 {bytes=a.ip}
    return
}

@(private)
portmap_pcp_request :: proc(local:Address,port:u16,external:Address,nonce:[12]u8,seconds:u32) -> (b:[60]u8) {
    b[0]=2;b[1]=1
    portmap_put32(b[4:8],seconds)
    ip:=portmap_ip16(local);copy(b[8:24],ip[:])
    for byte,i in nonce {b[24+i]=byte};b[36]=17
    portmap_put16(b[40:42],port);portmap_put16(b[42:44],external.port)
    suggested:=external
    if suggested.kind==.None {suggested.kind=local.kind}
    ip=portmap_ip16(suggested);copy(b[44:60],ip[:])
    return
}

@(private)
portmap_pcp_response :: proc(b:[]u8,port:u16,nonce:[12]u8) -> (external:Address,seconds:u32,ok:bool) {
    if len(b)<60 || len(b)%4!=0 || b[0]!=2 || b[1]!=0x81 || b[3]!=0 || b[36]!=17 || portmap_get16(b[40:42])!=port {return}
    for byte,i in nonce {if b[24+i]!=byte {return}}
    seconds=portmap_get32(b[4:8])
    if seconds==0 {return}
    ip:[16]u8;copy(ip[:],b[44:60])
    external=address_from_endpoint({address=transmute(cnet.IP6_Address)ip,port=int(portmap_get16(b[42:44]))})
    ok=external.port!=0
    return
}

@(private)
portmap_pcp :: proc(m:^Port_Mapping,u:^Udp,gateway,local:Address,lease:^Portmap_Lease,seconds:u32) -> bool {
    request:=portmap_pcp_request(local,m.port,lease.external,lease.nonce,seconds)
    granted:=false
    defer {
        if !granted && lease.method==.None {
            deletion:=portmap_pcp_request(local,m.port,lease.external,lease.nonce,0)
            udp_send(u,gateway,deletion[:])
        }
    }
    start:=time.tick_now();next:=0.0;interval:=0.25
    buffer:[1200]u8
    for portmap_seconds(start)<2.0 && !portmap_stopped(m) {
        now:=portmap_seconds(start)
        if now>=next {udp_send(u,gateway,request[:]);next=now+interval;interval*=2}
        for _ in 0..<16 {
            size,from,received:=udp_receive(u,buffer[:]);if !received {break}
            if from!=gateway {continue}
            ext,lifetime,valid:=portmap_pcp_response(buffer[:size],m.port,lease.nonce)
            if valid {granted=true;lease.external,lease.seconds=ext,lifetime;return true}
            if size>=24 && buffer[0]==2 && buffer[1]==0x81 && buffer[3]!=0 {return false}
            if size>=8 && buffer[0]==0 && buffer[1]==0x81 {return false}
        }
        portmap_pause()
    }
    return false
}

@(private)
portmap_natpmp_request :: proc(port,external:u16,seconds:u32) -> (b:[12]u8) {
    b[1]=1;portmap_put16(b[4:6],port);portmap_put16(b[6:8],external);portmap_put32(b[8:12],seconds)
    return
}
@(private)
portmap_natpmp_response :: proc(b:[]u8,port:u16) -> (external:u16,seconds:u32,ok:bool) {
    if len(b)!=16 || b[0]!=0 || b[1]!=129 || portmap_get16(b[2:4])!=0 || portmap_get16(b[8:10])!=port {return}
    external,seconds=portmap_get16(b[10:12]),portmap_get32(b[12:16])
    ok=external!=0 && seconds!=0
    return
}
@(private)
portmap_natpmp :: proc(m:^Port_Mapping,u:^Udp,gateway:Address,lease:^Portmap_Lease,seconds:u32) -> bool {
    request:=portmap_natpmp_request(m.port,lease.external.port==0?m.port:lease.external.port,seconds)
    granted:=false
    defer {
        if !granted && lease.method==.None {
            deletion:=portmap_natpmp_request(m.port,0,0)
            udp_send(u,gateway,deletion[:])
        }
    }
    external_request:[2]u8
    start:=time.tick_now();next:=0.0;interval:=0.25
    ip:Address;external:u16;lifetime:u32
    buffer:[1200]u8
    for portmap_seconds(start)<2.0 && !portmap_stopped(m) {
        now:=portmap_seconds(start)
        if now>=next {
            udp_send(u,gateway,external_request[:]);udp_send(u,gateway,request[:])
            next=now+interval;interval*=2
        }
        for _ in 0..<16 {
            size,from,received:=udp_receive(u,buffer[:]);if !received {break}
            if from!=gateway {continue}
            b:=buffer[:size]
            if len(b)==12 && b[0]==0 && b[1]==128 && portmap_get16(b[2:4])==0 {ip=address_ip4(b[8],b[9],b[10],b[11],0)}
            if ep,sec,ok:=portmap_natpmp_response(b,m.port);ok {external,lifetime=ep,sec}
            if len(b)>=4 && b[0]==0 && (b[1]==128 || b[1]==129) && portmap_get16(b[2:4])!=0 {return false}
            if ip.kind!=.None && external!=0 {granted=true;ip.port=external;lease.external,lease.seconds=ip,lifetime;return true}
        }
        portmap_pause()
    }
    return false
}
