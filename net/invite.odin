package mirai_net

import "core:crypto"
import cnet "core:net"
import "core:strings"

// Invitation codes. What a host gives others so they join it without seeing
// an address: its address, port and invitation token, and a check byte, in
// Crockford base32 by groups of four. An IPv4 host gives 16 characters
// (K7Q2-9XMA-PL3F-0B2C), an IPv6 one 36. Reading accepts lowercase, the
// letters O, I and L for the digits they look like, and spaces or dashes
// anywhere; a character that changed or went missing makes it no code.
//
// The token is Host_Desc.invite of the server and of whoever joins it: every
// key of the connection depends on it, so a client without the same one gets
// no answer at all, and nobody can try tokens from a host's answers.

INVITE_TOKEN_BITS :: 24
@(private) INVITE_ALPHABET :: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
@(private) INVITE_BYTES_4 :: 4+2+3+1
@(private) INVITE_BYTES_6 :: 16+2+3+1
@(private) INVITE_GROUP :: 4

// A new invitation token, never zero. Not ok when the system gives no secure random bytes.
invite_token :: proc() -> (token:u32,ok:bool) {
    when !crypto.HAS_RAND_BYTES {return}
    bytes:[4]u8
    crypto.rand_bytes(bytes[:])
    token=(u32(bytes[0])|u32(bytes[1])<<8|u32(bytes[2])<<16)&(1<<INVITE_TOKEN_BITS-1)
    return token!=0?token:1,true
}

// The code of an address and a token; empty for an address that is not IPv4 or IPv6, or a token that does not fit.
invite_encode :: proc(address:Address,token:u32,allocator:=context.allocator) -> string {
    address:=address
    if token==0 || token>=1<<INVITE_TOKEN_BITS || address.port==0 {return ""}
    bytes:[INVITE_BYTES_6]u8
    n:=0
    #partial switch address.kind {
    case .IP4: n=copy(bytes[:],address.ip[:4])
    case .IP6: n=copy(bytes[:],address.ip[:])
    case: return ""
    }
    bytes[n],bytes[n+1]=u8(address.port>>8),u8(address.port)
    bytes[n+2],bytes[n+3],bytes[n+4]=u8(token>>16),u8(token>>8),u8(token)
    n+=5
    bytes[n]=invite_check(bytes[:n])
    n+=1
    alphabet:=INVITE_ALPHABET
    characters:=(n*8+4)/5
    b:=strings.builder_make(0,characters+characters/INVITE_GROUP,allocator)
    for i in 0..<characters {
        if i>0 && i%INVITE_GROUP==0 {strings.write_byte(&b,'-')}
        value:=0
        for k in 0..<5 {
            bit:=i*5+k
            value<<=1
            if bit<n*8 {value|=int(bytes[bit/8]>>(7-uint(bit%8)))&1}
        }
        strings.write_byte(&b,alphabet[value])
    }
    return strings.to_string(b)
}

// The address and the token of a code; false when it is not one.
invite_decode :: proc(text:string) -> (address:Address,token:u32,ok:bool) {
    bytes:[INVITE_BYTES_6+1]u8
    bits:=0
    for c in transmute([]u8)text {
        value:=-1
        switch c {
        case '-',' ','\t': continue
        case '0','O','o': value=0
        case '1','I','i','L','l': value=1
        case '2'..='9': value=int(c-'0')
        case:
            upper:=c>='a' && c<='z'?c-'a'+'A':c
            value=strings.index_byte(INVITE_ALPHABET,upper)
        }
        if value<0 || bits+5>len(bytes)*8 {return}
        for k in 0..<5 {
            if value>>(4-uint(k))&1!=0 {bytes[(bits+k)/8]|=1<<(7-uint((bits+k)%8))}
        }
        bits+=5
    }
    n:=0
    switch bits/5 {
    case (INVITE_BYTES_4*8+4)/5: n=INVITE_BYTES_4
    case (INVITE_BYTES_6*8+4)/5: n=INVITE_BYTES_6
    case: return
    }
    // The bits past the last byte are zero in a code that was written as one.
    for bit in n*8..<bits {
        if bytes[bit/8]>>(7-uint(bit%8))&1!=0 {return}
    }
    if invite_check(bytes[:n-1])!=bytes[n-1] {return}
    ip:=n-6
    if ip==4 {address.kind=.IP4} else {address.kind=.IP6}
    copy(address.ip[:],bytes[:ip])
    address.port=u16(bytes[ip])<<8|u16(bytes[ip+1])
    token=u32(bytes[ip+2])<<16|u32(bytes[ip+3])<<8|u32(bytes[ip+4])
    if address.port==0 || token==0 {return {},0,false}
    return address,token,true
}

@(private)
invite_check :: proc "contextless" (bytes:[]u8) -> u8 {
    hash:=u32(2166136261)
    for b in bytes {hash=(hash~u32(b))*16777619}
    return u8(hash~hash>>8~hash>>16~hash>>24)
}

// The IPv4 address of this machine on its network with a port: the one the
// system sends to the internet from, which a virtual adapter of a hypervisor,
// of WSL or of containers is not; without a route, of the first adapter that
// is up and has a gateway, else of the first that is up; never loopback nor
// link-local, unless there is nothing else.
address_lan :: proc(port:int) -> Address {
    if probe,error:=cnet.make_unbound_udp_socket(.IP4);error==nil {
        // Connecting a datagram socket sends nothing: it asks the routing table.
        connected:=portmap_socket_connect(cnet.Socket(probe),address_ip4(1,1,1,1,53))
        endpoint,endpoint_error:=cnet.bound_endpoint(probe)
        cnet.close(probe)
        if local:=address_from_endpoint(endpoint);connected && endpoint_error==nil && local.kind==.IP4 && address_lan_usable(local.ip[:4]) {
            local.port=u16(port)
            return local
        }
    }
    interfaces,error:=cnet.enumerate_interfaces(context.temp_allocator)
    if error==nil {
        for gateway_needed in ([2]bool{true,false}) {
            for interface in interfaces {
                if cnet.Link_States.Up not_in interface.link.state {continue}
                if gateway_needed && !interface_has_gateway(interface) {continue}
                for lease in interface.unicast {
                    if ip,is_ip4:=lease.address.(cnet.IP4_Address);is_ip4 && address_lan_usable(ip[:]) {
                        return address_ip4(ip[0],ip[1],ip[2],ip[3],port)
                    }
                }
            }
        }
    }
    return address_ip4(127,0,0,1,port)
}

@(private)
address_lan_usable :: proc "contextless" (ip:[]u8) -> bool {
    return ip[0]!=0 && ip[0]!=127 && !(ip[0]==169 && ip[1]==254)
}

@(private)
interface_has_gateway :: proc(interface:cnet.Network_Interface) -> bool {
    for gateway in interface.gateways {
        if ip,is_ip4:=gateway.(cnet.IP4_Address);is_ip4 && ip!=(cnet.IP4_Address{}) {return true}
    }
    return false
}

// Where others reach a host whose port the router may have mapped: the
// mapped address when there is one, the one of its network otherwise.
address_reachable :: proc(mapping:^Port_Mapping,mapped:bool,port:int) -> Address {
    if mapped {
        if status:=mapping_poll(mapping);status.phase==.Mapped && status.external.kind==.IP4 {return status.external}
    }
    return address_lan(port)
}
