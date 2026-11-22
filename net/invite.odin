package mirai_net

import "core:crypto"
import "core:crypto/x25519"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:hash"
import "core:mem"
import cnet "core:net"

// Invitation codes. What a host gives others so they join it without seeing
// an address: where it is, as ICE gathers a host and a reflexive candidate
// (its IPv4 address on its network and the one its router mapped, each with
// its port), the key s its connections are made against and the secret that
// lets in (secure.odin). Its unpadded Base64url record holds the version,
// both endpoints, the full public key and secret, and their CRC-16.
//
// Holding the code is what lets in: an Initiate opens only for the holder of
// s and only if its sender knew s and the secret, and nobody can try secrets
// against recorded traffic without s. Whoever learned s alone can only guess
// the 64 bits of the secret against the host, which drops wrong guesses at the
// rate of each address (secure.odin). Everything else stands at 128 bits:
// X25519, SHA-256, ChaCha20-Poly1305 and AEGIS-128L.

// The key of an invitation: s and the secret. It belongs to one share: the
// one who serves makes it (invite_key) when the share starts, keeps it in
// memory and gives it to its Host, and it ends with the share; it is never
// written down. A client holds what its code carries, without private.
Invite_Key :: struct {
    private:Key, // s: only the host that serves holds it
    public:Key,  // what the code carries
    secret:u64,  // never zero
}

Invitation :: struct {
    lan:Address,    // the host on its network; none when only the mapped one reaches it
    public:Address, // where its router mapped its port; none without a mapping
    key:Invite_Key, // without private
}

// Why a text is not an invitation code.
Invite_Error :: enum u8 {
    None,
    Character,
    Length,
    Check,
    Version,
    Invalid,
}

INVITE_TEXT_BYTES :: (INVITE_RECORD_BYTES*8+5)/6

@(private) INVITE_VERSION :: 2
@(private) INVITE_ENDPOINT_BYTES :: 6
@(private) INVITE_KEY_AT :: 1+2*INVITE_ENDPOINT_BYTES
@(private) INVITE_SECRET_AT :: INVITE_KEY_AT+KEY_BYTES
@(private) INVITE_CHECK_AT :: INVITE_SECRET_AT+8
@(private) INVITE_RECORD_BYTES :: INVITE_CHECK_AT+2

// A new key for a share. Not ok when the system gives no secure random bytes.
invite_key :: proc() -> (key:Invite_Key,ok:bool) {
    when !crypto.HAS_RAND_BYTES {return}
    private:Key
    defer crypto.zero_explicit(&private,KEY_BYTES)
    secret:u64
    crypto.rand_bytes(private[:])
    crypto.rand_bytes(mem.ptr_to_bytes(&secret))
    return invite_key_from(&private,secret),true
}

// The key of a share made from its private key and a secret; zero becomes one.
invite_key_from :: proc(private:^Key,secret:u64) -> (key:Invite_Key) {
    key.private=private^
    x25519.scalarmult_basepoint(key.public[:],key.private[:])
    key.secret=secret!=0?secret:1
    return
}

// The invitation of a host serving on port with key: its address on its
// network and, once the router mapped the port, the mapped one.
invite_make :: proc(key:Invite_Key,port:int,mapping:^Port_Mapping=nil) -> Invitation {
    invitation:=Invitation{lan=address_lan(port),key={public=key.public,secret=key.secret}}
    if mapping!=nil {
        if status:=mapping_poll(mapping);status.phase==.Mapped && status.external.kind==.IP4 && status.external!=invitation.lan {invitation.public=status.external}
    }
    return invitation
}

// The code of an invitation; empty when an address is neither none nor IPv4
// with a port, both are none, the secret is zero or the key leaves nothing secret.
invite_encode :: proc(invitation:Invitation,allocator:=context.allocator) -> string {
    if invitation.lan.kind==.None && invitation.public.kind==.None {return ""}
    record:[INVITE_RECORD_BYTES]u8
    record[0]=INVITE_VERSION
    for address,i in ([2]Address{invitation.lan,invitation.public}) {
        address:=address
        if address.kind==.None {continue}
        if address.kind!=.IP4 || address.port==0 {return ""}
        at:=1+i*INVITE_ENDPOINT_BYTES
        copy(record[at:at+4],address.ip[:4])
        endian.unchecked_put_u16be(record[at+4:at+6],address.port)
    }
    public:=invitation.key.public
    if invitation.key.secret==0 || public[KEY_BYTES-1]&0x80!=0 || !key_usable(&public) {return ""}
    copy(record[INVITE_KEY_AT:INVITE_SECRET_AT],public[:])
    endian.unchecked_put_u64be(record[INVITE_SECRET_AT:INVITE_CHECK_AT],invitation.key.secret)
    check:=hash.crc16_ccitt_0x1021(record[:INVITE_CHECK_AT])
    endian.unchecked_put_u16be(record[INVITE_CHECK_AT:],check)
    code,err:=base64.encode(record[:],base64.ENC_URL_TABLE,allocator,{.No_Padding})
    return err==nil?code:""
}

// The invitation of a code, or why it is not one.
invite_decode :: proc(text:string) -> (invitation:Invitation,error:Invite_Error) {
    if len(text)!=INVITE_TEXT_BYTES {return {},.Length}
    record:[INVITE_RECORD_BYTES]u8
    if _,err:=base64.decode_into_buf(record[:],text,base64.DEC_URL_TABLE,{.Strict,.No_Padding});err!=nil {
        return {},.Character
    }
    check:=hash.crc16_ccitt_0x1021(record[:INVITE_CHECK_AT])
    if endian.unchecked_get_u16be(record[INVITE_CHECK_AT:])!=check {return {},.Check}
    if record[0]!=INVITE_VERSION {return {},.Version}
    for address,i in ([2]^Address{&invitation.lan,&invitation.public}) {
        at:=1+i*INVITE_ENDPOINT_BYTES
        ip:=record[at:at+4]
        port:=endian.unchecked_get_u16be(record[at+4:at+6])
        if port==0 {
            if ip[0]|ip[1]|ip[2]|ip[3]!=0 {return {},.Invalid}
            continue
        }
        address^=address_ip4(ip[0],ip[1],ip[2],ip[3],int(port))
    }
    if invitation.lan.kind==.None && invitation.public.kind==.None {return {},.Invalid}
    key:=&invitation.key
    copy(key.public[:],record[INVITE_KEY_AT:INVITE_SECRET_AT])
    key.secret=endian.unchecked_get_u64be(record[INVITE_SECRET_AT:INVITE_CHECK_AT])
    if key.secret==0 || key.public[KEY_BYTES-1]&0x80!=0 || !key_usable(&key.public) {
        return {},.Invalid
    }
    return invitation,.None
}

// What to tell whoever typed a text that is not an invitation code.
invite_error_text :: proc(error:Invite_Error) -> string {
    switch error {
    case .None:      return ""
    case .Character: return "an invitation uses unpadded Base64url. Copy the code exactly"
    case .Length:    return "an invitation has 74 characters. Copy the whole code again"
    case .Check:     return "the invitation checksum failed. Copy the code again"
    case .Version:   return "the host and guest need the same version of Mirai"
    case .Invalid:   return "the invitation data is invalid. Ask the host for a new code"
    }
    return ""
}

// The IPv4 address of this machine on its network with a port: the one the
// system sends to the internet from, which a virtual adapter of a hypervisor,
// of WSL or of containers is not; without a route, of the first adapter that
// is up and has a gateway, else of the first that is up; never loopback nor
// link-local, unless there is nothing else.
address_lan :: proc(port:int) -> Address {
    if probe,error:=cnet.make_unbound_udp_socket(.IP4);error==nil {
        // Connecting a datagram socket sends nothing: it asks the routing table.
        connected:=socket_connect(cnet.Socket(probe),address_ip4(1,1,1,1,53))
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
