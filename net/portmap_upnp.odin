package mirai_net

import "core:fmt"
import cnet "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

@(private)
Portmap_UPnP :: struct {
    endpoint:Address,
    path:[512]u8,
    path_len:int,
    service:[96]u8,
    service_len:int,
    description:[32]u8,
    description_len:int,
    owned:bool,
}

@(private)
portmap_header :: proc(headers,name:string) -> string {
    remaining:=headers
    for line in strings.split_lines_iterator(&remaining) {
        colon:=strings.index(line,":")
        if colon>0 && strings.equal_fold(strings.trim_space(line[:colon]),name) {return strings.trim_space(line[colon+1:])}
    }
    return ""
}

@(private)
portmap_url :: proc(text:string,gateway:Address) -> (endpoint:Address,path:string,ok:bool) {
    if !strings.has_prefix(text,"http://") || len(text)>512 {return}
    rest:=text[7:];slash:=strings.index(rest,"/")
    authority:=rest
    path="/"
    if slash>=0 {authority=rest[:slash];path=rest[slash:]}
    if len(authority)==0 || len(authority)>64 || strings.contains_any(authority,"@[]\\?#\r\n\t ") || strings.contains_any(path,"\r\n\t <>\"#") {return}
    bytes:[80]u8
    address:=authority
    if !strings.contains(authority,":") {address=fmt.bprintf(bytes[:],"%s:80",authority)}
    endpoint,ok=address_parse(address)
    ok=ok && endpoint.kind==.IP4 && endpoint.ip==gateway.ip && endpoint.port!=0
    return
}

@(private)
portmap_xml :: proc(xml,name:string) -> (value,rest:string,ok:bool) {
    offset:=0
    for offset<len(xml) {
        relative:=strings.index(xml[offset:],"<")
        if relative<0 {return}
        begin:=offset+relative;end:=strings.index(xml[begin:],">")
        if end<0 {return}
        end+=begin
        tag:=xml[begin+1:end]
        space:=strings.index_any(tag," \t\r\n")
        if space>=0 {tag=tag[:space]}
        local:=tag;colon:=strings.last_index(tag,":")
        if colon>=0 {local=tag[colon+1:]}
        offset=end+1
        if local!=name || strings.has_prefix(tag,"/") || strings.has_prefix(tag,"!") || strings.has_suffix(tag,"/") {continue}
        if len(tag)>100 {return}
        close_bytes:[128]u8
        closing:=fmt.bprintf(close_bytes[:],"</%s>",tag)
        finish:=strings.index(xml[offset:],closing)
        if finish<0 {return}
        finish+=offset
        return strings.trim_space(xml[offset:finish]),xml[finish+len(closing):],true
    }
    return
}

@(private)
portmap_http_body :: proc(bytes:[]u8) -> (body:[]u8,status:int,complete,valid:bool) {
    text:=string(bytes)
    header_end:=strings.index(text,"\r\n\r\n")
    if header_end<0 {return nil,0,false,len(bytes)<8192}
    if header_end>8192 {return}
    first:=strings.index(text,"\r\n")
    if first<12 || !(strings.has_prefix(text,"HTTP/1.1 ") || strings.has_prefix(text,"HTTP/1.0 ")) {return}
    code,ok:=strconv.parse_int(text[9:12],10)
    if !ok || code<100 || code>599 {return}
    status=int(code)
    headers:=text[first+2:header_end]
    begin:=header_end+4
    transfer:=portmap_header(headers,"Transfer-Encoding")
    content_length:=portmap_header(headers,"Content-Length")
    if transfer!="" {
        if !strings.equal_fold(transfer,"chunked") || content_length!="" {return}
        cursor,output:=begin,begin
        for cursor<len(bytes) {
            line:=strings.index(string(bytes[cursor:]),"\r\n")
            if line<0 {return nil,status,false,true}
            chunk_text:=string(bytes[cursor:cursor+line]);extension:=strings.index(chunk_text,";")
            if extension>=0 {chunk_text=chunk_text[:extension]}
            chunk_size,parsed:=strconv.parse_uint(chunk_text,16)
            if !parsed || len(chunk_text)>8 || chunk_size>65536 {return}
            cursor+=line+2
            if chunk_size==0 {
                if cursor+2>len(bytes) {return nil,status,false,true}
                if bytes[cursor]!=13 || bytes[cursor+1]!=10 {return}
                return bytes[begin:output],status,true,true
            }
            if int(chunk_size)>len(bytes)-cursor-2 {return nil,status,false,true}
            finish:=cursor+int(chunk_size)
            if bytes[finish]!=13 || bytes[finish+1]!=10 {return}
            // Dechunk only when the complete message is present; the caller still appends on a partial response.
            output+=int(chunk_size)
            cursor=finish+2
        }
        return nil,status,false,true
    }
    if content_length=="" {return bytes[begin:],status,false,true}
    size,parsed:=strconv.parse_uint(content_length,10)
    if !parsed || size>65536 || size>uint(max(int)-begin) {return}
    if int(size)>len(bytes)-begin {return nil,status,false,true}
    return bytes[begin:begin+int(size)],status,true,true
}

@(private)
portmap_dechunk :: proc(bytes:[]u8) -> []u8 {
    header_end:=strings.index(string(bytes),"\r\n\r\n")
    begin:=header_end+4
    transfer:=portmap_header(string(bytes[:header_end]),"Transfer-Encoding")
    if !strings.equal_fold(transfer,"chunked") {return bytes}
    cursor,output:=begin,begin
    for cursor<len(bytes) {
        line:=strings.index(string(bytes[cursor:]),"\r\n")
        chunk_text:=string(bytes[cursor:cursor+line]);extension:=strings.index(chunk_text,";")
        if extension>=0 {chunk_text=chunk_text[:extension]}
        size,_:=strconv.parse_uint(chunk_text,16);cursor+=line+2
        if size==0 {return bytes[:output]}
        copy(bytes[output:],bytes[cursor:cursor+int(size)])
        output+=int(size);cursor+=int(size)+2
    }
    return bytes[:output]
}

@(private)
portmap_http :: proc(m:^Port_Mapping,endpoint:Address,request:[]u8,buffer:[]u8,releasing:=false) -> (body:[]u8,status:int,ok:bool) {
    any,error:=cnet.create_socket(.IP4,.TCP)
    if error!=nil {return}
    socket:=any.(cnet.TCP_Socket)
    defer cnet.close(socket)
    if cnet.set_blocking(socket,false)!=nil || !portmap_socket_connect(cnet.Socket(socket),endpoint) {return}
    start:=time.tick_now()
    deadline:=releasing?0.5:2.0
    sent,received:=0,0
    connected:=false
    for portmap_seconds(start)<deadline && (releasing || !portmap_stopped(m)) {
        if !connected {
            ready,valid:=portmap_socket_connected(cnet.Socket(socket))
            if ready && !valid {return}
            if !ready {portmap_pause();continue}
            connected=true
        }
        if sent<len(request) {
            size,send_error:=cnet.send_tcp(socket,request[sent:])
            if send_error!=nil && send_error!=.Would_Block {return}
            sent+=size
        } else {
            if received==len(buffer) {return}
            size,recv_error:=cnet.recv_tcp(socket,buffer[received:])
            if recv_error!=nil && recv_error!=.Would_Block {return}
            received+=size
            response:=buffer[:received]
            candidate,code,complete,valid:=portmap_http_body(response)
            if !valid {return}
            if complete {
                header_end:=strings.index(string(response),"\r\n\r\n")
                if strings.equal_fold(portmap_header(string(response[:header_end]),"Transfer-Encoding"),"chunked") {
                    response=portmap_dechunk(response);candidate=response[header_end+4:]
                }
                return candidate,code,true
            }
            if recv_error==nil && size==0 {
                if candidate==nil {return}
                return candidate,code,true
            }
        }
        portmap_pause()
    }
    return
}

@(private)
portmap_upnp_soap :: proc(m:^Port_Mapping,upnp:^Portmap_UPnP,action,args:string,buffer:[]u8,releasing:=false) -> (body:string,status:int,ok:bool) {
    service:=string(upnp.service[:upnp.service_len])
    path:=string(upnp.path[:upnp.path_len])
    envelope_bytes:[8192]u8
    envelope:=fmt.bprintf(envelope_bytes[:],"<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:%s xmlns:u=\"%s\">%s</u:%s></s:Body></s:Envelope>",action,service,args,action)
    request_bytes:[12288]u8
    ip:=upnp.endpoint.ip
    request:=fmt.bprintf(request_bytes[:],"POST %s HTTP/1.1\r\nHost: %d.%d.%d.%d:%d\r\nContent-Type: text/xml; charset=\"utf-8\"\r\nSOAPAction: \"%s#%s\"\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",path,ip[0],ip[1],ip[2],ip[3],upnp.endpoint.port,service,action,len(envelope),envelope)
    response,code,valid:=portmap_http(m,upnp.endpoint,transmute([]u8)request,buffer,releasing)
    return string(response),code,valid
}

@(private)
portmap_upnp_descriptor :: proc(description,url:string,gateway:Address) -> (upnp:Portmap_UPnP,ok:bool) {
    _,_,valid:=portmap_url(url,gateway)
    if !valid {return}
    base:=url
    if value,_,found:=portmap_xml(description,"URLBase");found && value!="" {base=value}
    rest:=description
    for _ in 0..<64 {
        service,next,found:=portmap_xml(rest,"service")
        if !found {return}
        rest=next
        kind,_,has_kind:=portmap_xml(service,"serviceType")
        control,_,has_control:=portmap_xml(service,"controlURL")
        if !has_kind || !has_control || len(control)>500 {continue}
        if kind!="urn:schemas-upnp-org:service:WANIPConnection:1" && kind!="urn:schemas-upnp-org:service:WANIPConnection:2" && kind!="urn:schemas-upnp-org:service:WANPPPConnection:1" {continue}
        endpoint,path,control_ok:=portmap_url(control,gateway)
        joined_bytes:[512]u8
        if !control_ok && !strings.contains(control,":") && !strings.contains_any(control,"&<>\r\n\\\"#") {
            base_endpoint,base_path,base_ok:=portmap_url(base,gateway)
            if !base_ok {continue}
            joined:=control
            if !strings.has_prefix(control,"/") {
                directory:=strings.last_index(base_path,"/")
                if directory+1+len(control)>=len(joined_bytes) {continue}
                joined=fmt.bprintf(joined_bytes[:],"%s%s",base_path[:directory+1],control)
            }
            endpoint,path,control_ok=base_endpoint,joined,true
        }
        if !control_ok || len(path)==0 || len(path)>=len(upnp.path) || len(kind)>=len(upnp.service) {continue}
        upnp.endpoint=endpoint
        upnp.path_len=copy(upnp.path[:],transmute([]u8)path)
        upnp.service_len=copy(upnp.service[:],transmute([]u8)kind)
        return upnp,true
    }
    return
}

@(private)
portmap_upnp_acquire :: proc(m:^Port_Mapping,u:^Udp,gateway,local:Address,lease:^Portmap_Lease) -> bool {
    discover:="M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
    multicast:=address_ip4(239,255,255,250,1900)
    if gateway.ip[0]!=127 {udp_send(u,multicast,transmute([]u8)discover)}
    router:=gateway;router.port=m.discovery_port
    udp_send(u,router,transmute([]u8)discover)
    start:=time.tick_now()
    packet:[1200]u8
    response:[65536]u8
    for portmap_seconds(start)<2.0 && !portmap_stopped(m) {
        size,from,received:=udp_receive(u,packet[:])
        if !received {portmap_pause();continue}
        if from.kind!=.IP4 || from.ip!=gateway.ip {continue}
        location:=portmap_header(string(packet[:size]),"Location")
        endpoint,path,url_ok:=portmap_url(location,gateway)
        if !url_ok {continue}
        request_bytes:[1024]u8;ip:=endpoint.ip
        request:=fmt.bprintf(request_bytes[:],"GET %s HTTP/1.1\r\nHost: %d.%d.%d.%d:%d\r\nConnection: close\r\n\r\n",path,ip[0],ip[1],ip[2],ip[3],endpoint.port)
        description,status,http_ok:=portmap_http(m,endpoint,transmute([]u8)request,response[:])
        if !http_ok || status!=200 {continue}
        upnp,descriptor_ok:=portmap_upnp_descriptor(string(description),location,gateway)
        if !descriptor_ok {continue}
        copy(upnp.description[:],"Mirai-")
        hex:="0123456789abcdef"
        for b,i in lease.nonce {upnp.description[6+i*2]=hex[b>>4];upnp.description[7+i*2]=hex[b&15]}
        upnp.description_len=30
        lease.upnp=upnp
        lease.external.port=m.port
        for attempt in 0..<3 {
            if attempt>0 {lease.external.port=u16(49152+int(portmap_get16(lease.nonce[attempt*2:attempt*2+2]))%16384)}
            args_bytes:[256]u8
            args:=fmt.bprintf(args_bytes[:],"<NewRemoteHost></NewRemoteHost><NewExternalPort>%d</NewExternalPort><NewProtocol>UDP</NewProtocol>",lease.external.port)
            body,code,queried:=portmap_upnp_soap(m,&lease.upnp,"GetSpecificPortMappingEntry",args,response[:])
            if !queried {break}
            if code==200 {continue}
            fault,_,found:=portmap_xml(body,"errorCode")
            if !found || fault!="714" {break}
            if portmap_upnp_add(m,local,lease,3600) {return true}
        }
    }
    return false
}

@(private)
portmap_upnp_add :: proc(m:^Port_Mapping,local:Address,lease:^Portmap_Lease,seconds:u32) -> bool {
    bytes:[1024]u8;ip:=local.ip
    args:=fmt.bprintf(bytes[:],"<NewRemoteHost></NewRemoteHost><NewExternalPort>%d</NewExternalPort><NewProtocol>UDP</NewProtocol><NewInternalPort>%d</NewInternalPort><NewInternalClient>%d.%d.%d.%d</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>%s</NewPortMappingDescription><NewLeaseDuration>%d</NewLeaseDuration>",lease.external.port,m.port,ip[0],ip[1],ip[2],ip[3],string(lease.upnp.description[:lease.upnp.description_len]),seconds)
    response:[65536]u8
    lease.upnp.owned=true
    body,status,ok:=portmap_upnp_soap(m,&lease.upnp,"AddPortMapping",args,response[:])
    if !ok {portmap_upnp_release(m,local,lease);return false}
    if status!=200 {
        fault,_,found:=portmap_xml(body,"errorCode")
        if seconds!=0 && found && fault=="725" {return portmap_upnp_add(m,local,lease,0)}
        lease.upnp.owned=false
        return false
    }
    lease.upnp.owned=true;lease.seconds=seconds
    body,status,ok=portmap_upnp_soap(m,&lease.upnp,"GetExternalIPAddress","",response[:])
    if ok && status==200 {
        ip_text,_,found:=portmap_xml(body,"NewExternalIPAddress")
        address_bytes:[80]u8
        if found {
            address_text:=fmt.bprintf(address_bytes[:],"%s:%d",ip_text,lease.external.port)
            if address,parsed:=address_parse(address_text);parsed && address.kind==.IP4 {lease.external=address;return true}
        }
    }
    portmap_upnp_release(m,local,lease)
    return false
}

@(private)
portmap_upnp_owns :: proc(m:^Port_Mapping,local:Address,lease:^Portmap_Lease,releasing:=false) -> bool {
    bytes:[256]u8
    args:=fmt.bprintf(bytes[:],"<NewRemoteHost></NewRemoteHost><NewExternalPort>%d</NewExternalPort><NewProtocol>UDP</NewProtocol>",lease.external.port)
    response:[65536]u8
    body,status,ok:=portmap_upnp_soap(m,&lease.upnp,"GetSpecificPortMappingEntry",args,response[:],releasing)
    if !ok || status!=200 {return false}
    client,_,has_client:=portmap_xml(body,"NewInternalClient")
    port,_,has_port:=portmap_xml(body,"NewInternalPort")
    description,_,has_description:=portmap_xml(body,"NewPortMappingDescription")
    ip_bytes:[32]u8
    ip:=local.ip
    expected:=fmt.bprintf(ip_bytes[:],"%d.%d.%d.%d",ip[0],ip[1],ip[2],ip[3])
    numeric,parsed:=strconv.parse_uint(port,10)
    return has_client && client==expected && has_port && parsed && numeric==uint(m.port) && has_description && description==string(lease.upnp.description[:lease.upnp.description_len])
}

@(private)
portmap_upnp_renew :: proc(m:^Port_Mapping,local:Address,lease:^Portmap_Lease) -> bool {
    if !portmap_upnp_owns(m,local,lease) {return false}
    return portmap_upnp_add(m,local,lease,lease.seconds)
}

@(private)
portmap_upnp_release :: proc(m:^Port_Mapping,local:Address,lease:^Portmap_Lease) {
    if !lease.upnp.owned || !portmap_upnp_owns(m,local,lease,true) {return}
    bytes:[256]u8
    args:=fmt.bprintf(bytes[:],"<NewRemoteHost></NewRemoteHost><NewExternalPort>%d</NewExternalPort><NewProtocol>UDP</NewProtocol>",lease.external.port)
    response:[65536]u8
    portmap_upnp_soap(m,&lease.upnp,"DeletePortMapping",args,response[:],true)
    lease.upnp.owned=false
}
