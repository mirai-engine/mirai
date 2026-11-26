package mirai_net

import cnet "core:net"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"

@(test)
port_mapping_pcp_and_natpmp_codecs_reject_mismatched_or_truncated_replies :: proc(t:^testing.T) {
    nonce:=[12]u8{0=1,11=255}
    local:=address_ip4(192,168,2,4,0)
    external:=address_ip4(8,8,8,8,17950)
    request:=portmap_pcp_request(local,7950,external,nonce,3600)
    testing.expect(t,request[0]==2 && request[1]==1 && request[18]==255 && request[19]==255)
    testing.expect(t,portmap_get16(request[40:42])==7950 && portmap_get16(request[42:44])==17950 && portmap_get32(request[4:8])==3600)
    request[1]=0x81
    parsed,seconds,ok:=portmap_pcp_response(request[:],7950,nonce)
    testing.expect(t,ok && parsed==external && seconds==3600)
    for size in 0..<60 {_,_,ok=portmap_pcp_response(request[:size],7950,nonce);testing.expect(t,!ok)}
    _,_,ok=portmap_pcp_response(request[:],7951,nonce);testing.expect(t,!ok)
    request[24]=request[24]~1
    _,_,ok=portmap_pcp_response(request[:],7950,nonce);testing.expect(t,!ok)
    request[24]=request[24]~1;request[3]=2
    _,_,ok=portmap_pcp_response(request[:],7950,nonce);testing.expect(t,!ok)
    nat_request:=portmap_natpmp_request(7950,17950,3600)
    testing.expect(t,nat_request[0]==0 && nat_request[1]==1 && portmap_get16(nat_request[4:6])==7950 && portmap_get16(nat_request[6:8])==17950)
    nat:[16]u8;nat[1]=129
    portmap_put16(nat[8:10],7950);portmap_put16(nat[10:12],17950);portmap_put32(nat[12:16],3600)
    port,life,valid:=portmap_natpmp_response(nat[:],7950)
    testing.expect(t,valid && port==17950 && life==3600)
    for size in 0..<16 {_,_,ok=portmap_natpmp_response(nat[:size],7950);testing.expect(t,!ok)}
    _,_,ok=portmap_natpmp_response(nat[:],7951);testing.expect(t,!ok)
    nat[3]=1;_,_,ok=portmap_natpmp_response(nat[:],7950);testing.expect(t,!ok)
    // A TCP port (Kai's): PCP names protocol 6, NAT-PMP takes opcode 2 and answers 130, and a
    // reply for the other protocol is not taken.
    tcp:=portmap_pcp_request(local,7350,external,nonce,3600,.TCP)
    testing.expect_value(t,tcp[36],u8(6))
    tcp[1]=0x81
    _,_,ok=portmap_pcp_response(tcp[:],7350,nonce,.TCP);testing.expect(t,ok)
    _,_,ok=portmap_pcp_response(tcp[:],7350,nonce,.UDP);testing.expect(t,!ok)
    nat_tcp:=portmap_natpmp_request(7350,7350,3600,.TCP)
    testing.expect_value(t,nat_tcp[1],u8(2))
    nat={};nat[1]=130
    portmap_put16(nat[8:10],7350);portmap_put16(nat[10:12],7350);portmap_put32(nat[12:16],3600)
    _,_,ok=portmap_natpmp_response(nat[:],7350,.TCP);testing.expect(t,ok)
    _,_,ok=portmap_natpmp_response(nat[:],7350,.UDP);testing.expect(t,!ok)
}

@(test)
port_mapping_upnp_parsers_bound_addresses_headers_and_xml :: proc(t:^testing.T) {
    gateway:=address_ip4(192,168,1,1,5351)
    endpoint,path,ok:=portmap_url("http://192.168.1.1:5000/root.xml",gateway)
    testing.expect(t,ok && endpoint.port==5000 && path=="/root.xml")
    for url in ([]string{"https://192.168.1.1/root.xml","http://8.8.8.8/root.xml","http://user@192.168.1.1/root.xml","http://192.168.1.1/evil\r\nHeader: yep","http://192.168.1.1:0/root.xml"}) {
        _,_,ok=portmap_url(url,gateway);testing.expect(t,!ok)
    }
    xml:="<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>control</controlURL></service></serviceList></device></root>"
    upnp:Portmap_UPnP
    upnp,ok=portmap_upnp_descriptor(xml,"http://192.168.1.1:5000/igd/root.xml",gateway)
    testing.expect(t,ok && upnp.endpoint.port==5000 && string(upnp.path[:upnp.path_len])=="/igd/control")
    xml="<root><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType><controlURL>http://8.8.8.8/attack</controlURL></service></root>"
    _,ok=portmap_upnp_descriptor(xml,"http://192.168.1.1/root.xml",gateway);testing.expect(t,!ok)
    value,_,found:=portmap_xml("<s:Envelope><s:Body><u:errorCode>725</u:errorCode></s:Body></s:Envelope>","errorCode")
    testing.expect(t,found && value=="725")
    _,_,found=portmap_xml("<serviceType>unterminated","serviceType");testing.expect(t,!found)
    testing.expect(t,portmap_header("HTTP/1.1 200 OK\r\nlOcAtIoN: http://192.168.1.1/root.xml\r\n\r\n","Location")=="http://192.168.1.1/root.xml")
    for a in ([]Address{address_ip4(10,0,0,1,7950),address_loopback(7950),address_ip4(100,64,0,1,7950),address_ip4(192,168,1,1,7950),address_ip4(224,0,0,1,7950)}) {testing.expect(t,!address_global(a))}
    random:[1024]u8;seed:=u64(5)
    for _ in 0..<1000 {
        for &byte in random {byte=u8(base.splitmix_next(&seed))}
        size:=int(base.splitmix_next(&seed)%u64(len(random)))
        portmap_xml(string(random[:size]),"service")
        portmap_http_body(random[:size])
    }
}

@(test)
port_mapping_http_handles_chunked_and_partial_data :: proc(t:^testing.T) {
    text:="HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nbody"
    body,status,complete,ok:=portmap_http_body(transmute([]u8)text)
    testing.expect(t,ok && complete && status==200 && string(body)=="body")
    for size in 0..<len(text) {_,_,complete,ok=portmap_http_body(transmute([]u8)text[:size]);testing.expect(t,ok && !complete)}
    chunked:="HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nbo\r\n2\r\ndy\r\n0\r\n\r\n"
    for size in 0..<len(chunked) {_,_,complete,ok=portmap_http_body(transmute([]u8)chunked[:size]);testing.expect(t,ok && !complete)}
    bytes:[256]u8;n:=copy(bytes[:],chunked)
    _,_,complete,ok=portmap_http_body(bytes[:n]);testing.expect(t,complete && ok)
    result:=portmap_dechunk(bytes[:n]);start:=strings.index(string(result),"\r\n\r\n")+4
    testing.expect(t,string(result[start:])=="body")
    for invalid in ([]string{"HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n","HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n","HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n","HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nx\r\n"}) {
        _,_,_,ok=portmap_http_body(transmute([]u8)invalid);testing.expect(t,!ok)
    }
}

@(test)
port_mapping_worker_maps_renews_and_releases_pcp :: proc(t:^testing.T) {
    router:Udp
    if !testing.expect(t,udp_open(&router,address_loopback(0))) {return}
    defer udp_close(&router)
    m:Port_Mapping
    if !testing.expect(t,mapping_start(&m,7950,context.allocator,router.address)) {return}
    defer mapping_close(&m)
    packet:[1200]u8
    maps,releases:=0,0
    start:=time.tick_now()
    for portmap_seconds(start)<3 {
        size,from,got:=udp_receive(&router,packet[:])
        if got && size==60 && packet[0]==2 && packet[1]==1 {
            life:=portmap_get32(packet[4:8])
            if life==0 {releases+=1} else {
                maps+=1;packet[1]=0x81
                portmap_put32(packet[4:8],1)
                portmap_put16(packet[42:44],17950)
                for &byte in packet[44:60] {byte=0}
                packet[54]=255;packet[55]=255
                packet[56],packet[57],packet[58],packet[59]=8,8,8,8
                udp_send(&router,from,packet[:size])
            }
        }
        status:=mapping_poll(&m)
        if maps>=2 && status.phase==.Mapped {
            testing.expect(t,status.method==.PCP && status.external==address_ip4(8,8,8,8,17950))
            mapping_stop(&m)
        }
        if releases>0 && mapping_poll(&m).phase==.Closed {break}
        time.sleep(time.Millisecond)
    }
    testing.expectf(t,maps>=2 && releases>0,"maps %d releases %d status %v",maps,releases,mapping_poll(&m))
}

@(test)
port_mapping_worker_falls_back_to_natpmp_and_cancels_pending_work :: proc(t:^testing.T) {
    router:Udp
    if !testing.expect(t,udp_open(&router,address_loopback(0))) {return}
    defer udp_close(&router)
    m:Port_Mapping
    if !testing.expect(t,mapping_start(&m,7950,context.allocator,router.address)) {return}
    defer mapping_close(&m)
    packet:[1200]u8
    pcp,maps,releases:=0,0,0
    start:=time.tick_now()
    for portmap_seconds(start)<3 {
        size,from,got:=udp_receive(&router,packet[:])
        if got {
            if size==60 && packet[0]==2 {
                pcp+=1
                failure:[24]u8;failure[0]=2;failure[1]=0x81;failure[3]=1
                udp_send(&router,from,failure[:])
            } else if size==2 && packet[0]==0 && packet[1]==0 {
                reply:[12]u8;reply[1]=128;reply[8],reply[9],reply[10],reply[11]=8,8,4,4
                udp_send(&router,from,reply[:])
            } else if size==12 && packet[0]==0 && packet[1]==1 {
                if portmap_get32(packet[8:12])==0 {releases+=1} else {
                    maps+=1
                    reply:[16]u8;reply[1]=129
                    copy(reply[8:10],packet[4:6]);portmap_put16(reply[10:12],27950);portmap_put32(reply[12:16],3600)
                    udp_send(&router,from,reply[:])
                }
            }
        }
        status:=mapping_poll(&m)
        if status.phase==.Mapped {
            testing.expect(t,status.method==.NAT_PMP && status.external==address_ip4(8,8,4,4,27950))
            mapping_stop(&m)
        }
        if releases>0 && mapping_poll(&m).phase==.Closed {break}
        time.sleep(time.Millisecond)
    }
    testing.expectf(t,pcp>0 && maps>0 && releases>0,"pcp %d maps %d releases %d",pcp,maps,releases)
    mapping_close(&m)
    if !testing.expect(t,mapping_start(&m,7950,context.allocator,router.address)) {return}
    start=time.tick_now();mapping_close(&m)
    testing.expect(t,portmap_seconds(start)<1 && mapping_poll(&m).phase==.Closed)
}

// A NAT-PMP error to the mapping request ends NAT-PMP at once for either
// protocol: the worker turns to UPnP without waiting out the NAT-PMP time.
@(test)
port_mapping_worker_leaves_natpmp_on_its_error_reply :: proc(t:^testing.T) {
    for protocol in Port_Protocol {
        router,discovery:Udp
        if !testing.expect(t,udp_open(&router,address_loopback(0))) {return}
        defer udp_close(&router)
        if !testing.expect(t,udp_open(&discovery,address_loopback(0))) {return}
        defer udp_close(&discovery)
        m:Port_Mapping
        if !testing.expect(t,mapping_start(&m,7950,context.allocator,router.address,discovery.address.port,protocol)) {return}
        defer mapping_close(&m)
        opcodes:=NATPMP_OPCODE
        packet:[1200]u8
        refused:=false
        refused_at:time.Tick
        discovered:=-1.0
        start:=time.tick_now()
        for portmap_seconds(start)<4 && discovered<0 {
            if size,from,got:=udp_receive(&router,packet[:]);got {
                if size==60 && packet[0]==2 {
                    failure:[24]u8;failure[0]=2;failure[1]=0x81;failure[3]=1
                    udp_send(&router,from,failure[:])
                } else if size==2 && packet[0]==0 && packet[1]==0 {
                    reply:[12]u8;reply[1]=128;reply[8],reply[9],reply[10],reply[11]=8,8,4,4
                    udp_send(&router,from,reply[:])
                } else if size==12 && packet[0]==0 && packet[1]==opcodes[protocol] && portmap_get32(packet[8:12])!=0 {
                    failure:[16]u8;failure[1]=128+opcodes[protocol];failure[3]=2
                    copy(failure[8:10],packet[4:6])
                    udp_send(&router,from,failure[:])
                    if !refused {refused,refused_at=true,time.tick_now()}
                }
            }
            if _,_,got:=udp_receive(&discovery,packet[:]);got && refused {
                discovered=time.duration_seconds(time.tick_since(refused_at))
            }
            time.sleep(time.Millisecond)
        }
        testing.expectf(t,refused && discovered>=0 && discovered<1,"%v: UPnP is asked %.2f s after the NAT-PMP error",protocol,discovered)
    }
}

@(test)
port_mapping_http_uses_a_bounded_nonblocking_local_socket :: proc(t:^testing.T) {
    listener,error:=cnet.listen_tcp({address=cnet.IP4_Loopback,port=0})
    if !testing.expect(t,error==nil) {return}
    defer cnet.close(listener)
    cnet.set_blocking(listener,false)
    endpoint,_:=cnet.bound_endpoint(listener)
    m:Port_Mapping
    bytes:[65536]u8
    // A peer that accepts no data cannot make HTTP or shutdown wait for the OS's TCP timeout.
    request:="GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
    start:=time.tick_now()
    _,_,ok:=portmap_http(&m,address_from_endpoint(endpoint),transmute([]u8)request,bytes[:],true)
    testing.expect(t,!ok && portmap_seconds(start)<1)
}

// A router on loopback that speaks UPnP alone: PCP and NAT-PMP get an error,
// or no answer when silent. existing: it already forwards the port to this
// machine under another owner's description, as a mapping the user made does.
@(private="file")
Upnp_Router :: struct {
    router,discovery:Udp,
    listener:cnet.TCP_Socket,
    endpoint:cnet.Endpoint,
    silent,existing:bool,
    client:cnet.TCP_Socket,
    have_client:bool,
    read_bytes,response_bytes:[8192]u8,
    xml_bytes:[4096]u8,
    description:[64]u8,
    description_len:int,
    input_size,output_size,sent:int,
    owned,added,deleted,unexpected:bool,
}

@(private="file")
upnp_router_open :: proc(r:^Upnp_Router) -> bool {
    if !udp_open(&r.router,address_loopback(0)) || !udp_open(&r.discovery,address_loopback(0)) {return false}
    listener,error:=cnet.listen_tcp({address=cnet.IP4_Loopback,port=0})
    if error!=nil {return false}
    r.listener=listener
    cnet.set_blocking(listener,false)
    r.endpoint,_=cnet.bound_endpoint(listener)
    return true
}

@(private="file")
upnp_router_close :: proc(r:^Upnp_Router) {
    if r.have_client {cnet.close(r.client)}
    if r.listener!=0 {cnet.close(r.listener)}
    udp_close(&r.router)
    udp_close(&r.discovery)
}

// Answers what came since the last step.
@(private="file")
upnp_router_step :: proc(r:^Upnp_Router) {
    packet:[1200]u8
    if size,from,got:=udp_receive(&r.router,packet[:]);got && !r.silent {
        if size==60 && packet[0]==2 {
            failure:[24]u8;failure[0]=2;failure[1]=0x81;failure[3]=1
            udp_send(&r.router,from,failure[:])
        } else if size>=2 && packet[0]==0 {
            failure:[8]u8;failure[1]=packet[1]|128;failure[3]=2
            udp_send(&r.router,from,failure[:])
        }
    }
    if _,from,got:=udp_receive(&r.discovery,packet[:]);got {
        location_bytes:[256]u8
        location:=fmt.bprintf(location_bytes[:],"HTTP/1.1 200 OK\r\nLocation: http://127.0.0.1:%d/root.xml\r\n\r\n",r.endpoint.port)
        udp_send(&r.discovery,from,transmute([]u8)location)
    }
    if !r.have_client {
        incoming,_,accept_error:=cnet.accept_tcp(r.listener)
        if accept_error==nil {r.client=incoming;r.have_client=true;r.input_size,r.output_size,r.sent=0,0,0;cnet.set_blocking(r.client,false)}
        return
    }
    if r.output_size>0 {
        size,send_error:=cnet.send_tcp(r.client,r.response_bytes[r.sent:r.output_size])
        r.sent+=size
        if (send_error!=nil && send_error!=.Would_Block) || r.sent==r.output_size {cnet.close(r.client);r.have_client=false}
        return
    }
    size,recv_error:=cnet.recv_tcp(r.client,r.read_bytes[r.input_size:])
    r.input_size+=size
    if recv_error!=nil && recv_error!=.Would_Block {cnet.close(r.client);r.have_client=false;return}
    text:=string(r.read_bytes[:r.input_size])
    header_end:=strings.index(text,"\r\n\r\n")
    complete:=false
    if header_end>=0 {
        length,length_ok:=strconv.parse_uint(portmap_header(text[:header_end],"Content-Length"),10)
        complete=length_ok && length<8192 && header_end+4+int(length)<=r.input_size
    }
    is_get:=strings.has_prefix(text,"GET ") && header_end>=0
    if !is_get && !complete {return}
    body:="";status:=200
    switch {
    case is_get:
        body="<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/control</controlURL></service></serviceList></device></root>"
    case strings.contains(text,"#GetSpecificPortMappingEntry"):
        switch {
        case r.existing:
            body="<s:Envelope><s:Body><NewInternalPort>7950</NewInternalPort><NewInternalClient>127.0.0.1</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>miniupnpd</NewPortMappingDescription><NewLeaseDuration>0</NewLeaseDuration></s:Body></s:Envelope>"
        case r.owned:
            body=fmt.bprintf(r.xml_bytes[:],"<s:Envelope><s:Body><NewInternalClient>127.0.0.1</NewInternalClient><NewInternalPort>7950</NewInternalPort><NewPortMappingDescription>%s</NewPortMappingDescription></s:Body></s:Envelope>",string(r.description[:r.description_len]))
        case: status=500;body="<s:Envelope><s:Body><errorCode>714</errorCode></s:Body></s:Envelope>"
        }
    case strings.contains(text,"#AddPortMapping"):
        value,_,found:=portmap_xml(text,"NewPortMappingDescription")
        if found {r.description_len=copy(r.description[:],value)}
        r.owned,r.added=true,true
        body="<s:Envelope><s:Body><AddPortMappingResponse/></s:Body></s:Envelope>"
    case strings.contains(text,"#GetExternalIPAddress"):
        body="<s:Envelope><s:Body><NewExternalIPAddress>8.8.8.8</NewExternalIPAddress></s:Body></s:Envelope>"
    case strings.contains(text,"#DeletePortMapping"):
        r.owned,r.deleted=false,true
        body="<s:Envelope><s:Body><DeletePortMappingResponse/></s:Body></s:Envelope>"
    case: r.unexpected=true
    }
    response:=fmt.bprintf(r.response_bytes[:],"HTTP/1.1 %d Reply\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",status,len(body),body)
    r.output_size=len(response)
}

@(test)
port_mapping_worker_falls_back_to_upnp_and_releases_only_its_mapping :: proc(t:^testing.T) {
    r:=new(Upnp_Router);defer free(r)
    defer upnp_router_close(r)
    if !testing.expect(t,upnp_router_open(r)) {return}
    m:Port_Mapping
    if !testing.expect(t,mapping_start(&m,7950,context.allocator,r.router.address,r.discovery.address.port)) {return}
    defer mapping_close(&m)
    shared:=false
    start:=time.tick_now()
    for portmap_seconds(start)<5 && !r.unexpected {
        upnp_router_step(r)
        status:=mapping_poll(&m)
        if status.phase==.Mapped {
            shared=true
            testing.expect(t,status.method==.UPnP && status.external==address_ip4(8,8,8,8,7950))
            mapping_stop(&m)
        }
        if r.deleted && mapping_poll(&m).phase==.Closed {break}
        time.sleep(time.Millisecond)
    }
    testing.expectf(t,r.added && r.deleted && shared && !r.owned && !r.unexpected,"added %v deleted %v shared %v status %v",r.added,r.deleted,shared,mapping_poll(&m))
}

// A router whose PCP and NAT-PMP are silent and that already forwards the
// port to this machine, under its own description: the mapping serves within
// a second, and closing leaves the router's mapping in place.
@(test)
port_mapping_upnp_takes_an_existing_mapping_to_this_machine_and_leaves_it :: proc(t:^testing.T) {
    r:=new(Upnp_Router);defer free(r)
    defer upnp_router_close(r)
    if !testing.expect(t,upnp_router_open(r)) {return}
    r.silent,r.existing=true,true
    m:Port_Mapping
    if !testing.expect(t,mapping_start(&m,7950,context.allocator,r.router.address,r.discovery.address.port)) {return}
    defer mapping_close(&m)
    mapped:=-1.0
    start:=time.tick_now()
    for portmap_seconds(start)<5 && !r.unexpected {
        upnp_router_step(r)
        status:=mapping_poll(&m)
        if mapped<0 && status.phase==.Mapped {
            mapped=portmap_seconds(start)
            testing.expect(t,status.method==.UPnP && status.external==address_ip4(8,8,8,8,7950) && status.lease_seconds==0)
            mapping_stop(&m)
        }
        if status.phase==.Closed || status.phase==.Unavailable {break}
        time.sleep(time.Millisecond)
    }
    // The release asks the router once more, which its steps answer.
    for _ in 0..<200 {upnp_router_step(r);time.sleep(time.Millisecond)}
    testing.expectf(t,mapped>=0 && mapped<1.5,"mapped after %.2f s: %v",mapped,mapping_poll(&m))
    testing.expectf(t,!r.added && !r.deleted && !r.unexpected,"added %v deleted %v",r.added,r.deleted)
}
