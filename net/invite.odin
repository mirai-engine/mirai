package mirai_net

import "core:crypto"
import cnet "core:net"
import "core:strings"

// Invitation codes. What a host gives others so they join it without seeing
// an address: where it is, as ICE gathers a host and a reflexive candidate
// (its IPv4 address on its network and the one its router mapped, each with
// its port), its invitation token and a CRC-12 of all of that, 140 bits in 28
// characters of Crockford base32 by groups of four
// (R2M0-253B-DK5G-0W87-DDP5-XG9E-FB1A). Reading accepts lowercase, the
// letters O, I and L for the digits they look like, and spaces or dashes
// anywhere; a character that changed, or two neighbors that swapped, make it
// no code.
//
// The token is Host_Desc.invite of the server and of whoever joins it: every
// key of the connection depends on it, so a client without the same one gets
// no answer at all, and nobody can try tokens from a host's answers.

Invitation :: struct {
    lan:Address,    // the host on its network; none when only the mapped one reaches it
    public:Address, // where its router mapped its port; none without a mapping
    token:u32,      // Host_Desc.invite of the host, not zero
}

@(private) INVITE_ALPHABET :: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
@(private) INVITE_BYTES :: 16 // two addresses of 6 bytes and the token
@(private) INVITE_CHARACTERS :: (INVITE_BYTES*8+12)/5
@(private) INVITE_GROUP :: 4

// A new invitation token, never zero. Not ok when the system gives no secure random bytes.
invite_token :: proc() -> (token:u32,ok:bool) {
    when !crypto.HAS_RAND_BYTES {return}
    bytes:[4]u8
    crypto.rand_bytes(bytes[:])
    token=u32(bytes[0])|u32(bytes[1])<<8|u32(bytes[2])<<16|u32(bytes[3])<<24
    return token!=0?token:1,true
}

// The invitation of a host serving on port: its address on its network and,
// once the router mapped the port, the mapped one.
invite_make :: proc(token:u32,port:int,mapping:^Port_Mapping=nil) -> Invitation {
    invitation:=Invitation{lan=address_lan(port),token=token}
    if mapping!=nil {
        if status:=mapping_poll(mapping);status.phase==.Mapped && status.external.kind==.IP4 && status.external!=invitation.lan {invitation.public=status.external}
    }
    return invitation
}

// The code of an invitation; empty when an address is neither none nor IPv4 with a port, both are none, or the token is zero.
invite_encode :: proc(invitation:Invitation,allocator:=context.allocator) -> string {
    bytes:[INVITE_BYTES+2]u8
    for address,i in ([2]Address{invitation.lan,invitation.public}) {
        address:=address
        #partial switch address.kind {
        case .None: continue
        case .IP4: if address.port==0 {return ""}
        case: return ""
        }
        copy(bytes[i*6:],address.ip[:4])
        bytes[i*6+4],bytes[i*6+5]=u8(address.port>>8),u8(address.port)
    }
    if invitation.token==0 || invitation.lan.kind==.None && invitation.public.kind==.None {return ""}
    for k in 0..<4 {bytes[12+k]=u8(invitation.token>>(24-8*uint(k)))}
    check:=invite_check(bytes[:INVITE_BYTES])
    bytes[INVITE_BYTES],bytes[INVITE_BYTES+1]=u8(check>>4),u8(check<<4)
    alphabet:=INVITE_ALPHABET
    b:=strings.builder_make(0,INVITE_CHARACTERS+INVITE_CHARACTERS/INVITE_GROUP,allocator)
    for i in 0..<INVITE_CHARACTERS {
        if i>0 && i%INVITE_GROUP==0 {strings.write_byte(&b,'-')}
        value:=0
        for k in 0..<5 {
            bit:=i*5+k
            value=value<<1|int(bytes[bit/8]>>(7-uint(bit%8)))&1
        }
        strings.write_byte(&b,alphabet[value])
    }
    return strings.to_string(b)
}

// The invitation of a code; false when it is not one.
invite_decode :: proc(text:string) -> (invitation:Invitation,ok:bool) {
    bytes:[INVITE_BYTES+2]u8
    characters:=0
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
        if value<0 || characters==INVITE_CHARACTERS {return}
        for k in 0..<5 {
            bit:=characters*5+k
            if value>>(4-uint(k))&1!=0 {bytes[bit/8]|=1<<(7-uint(bit%8))}
        }
        characters+=1
    }
    if characters!=INVITE_CHARACTERS || invite_check(bytes[:INVITE_BYTES])!=u16(bytes[INVITE_BYTES])<<4|u16(bytes[INVITE_BYTES+1])>>4 {return}
    for address,i in ([2]^Address{&invitation.lan,&invitation.public}) {
        at:=bytes[i*6:]
        port:=u16(at[4])<<8|u16(at[5])
        if port==0 {continue}
        address^={kind=.IP4,port=port}
        copy(address.ip[:4],at[:4])
    }
    for k in 0..<4 {invitation.token=invitation.token<<8|u32(bytes[12+k])}
    if invitation.token==0 || invitation.lan.kind==.None && invitation.public.kind==.None {return {},false}
    return invitation,true
}

// CRC-12 (x^12+x^11+x^3+x^2+x+1): it finds every burst of up to 12 bits, so
// any one character changed and any two neighbors swapped.
@(private)
invite_check :: proc "contextless" (bytes:[]u8) -> u16 {
    crc:u16
    for b in bytes {
        for k in 0..<8 {
            top:=(crc>>11~u16(b>>(7-uint(k))))&1
            crc=crc<<1&0xfff
            if top!=0 {crc~=0x80f}
        }
    }
    return crc
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
