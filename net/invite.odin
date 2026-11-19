package mirai_net

import "core:crypto"
import "core:crypto/x25519"
import "core:mem"
import cnet "core:net"
import "core:strings"

// Invitation codes. What a host gives others so they join it without seeing
// an address: where it is, as ICE gathers a host and a reflexive candidate
// (its IPv4 address on its network and the one its router mapped, each with
// its port), the key s its connections are made against and the secret that
// lets in (secure.odin). A code is the version of its layout, the two
// addresses, s (255 bits: the top bit of an X25519 key is never set), the
// secret and a CRC-15 of all of that, 435 bits in 87 characters of Crockford
// base32 by groups of four. Reading accepts lowercase, the letters O, I and L
// for the digits they look like, and spaces or dashes anywhere; a character
// that changed, or two neighbors that swapped, make it no code.
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
    Character, // one no code has
    Old,       // the length of a code of an earlier Mirai, without the key
    Length,
    Check,     // a character changed or two neighbors swapped
    Version,   // the layout of another Mirai
    Invalid,   // no address, a zero secret or a key that leaves nothing secret
}

INVITE_TEXT_BYTES :: INVITE_CHARACTERS+(INVITE_CHARACTERS-1)/INVITE_GROUP // of a code as invite_encode writes it

@(private) INVITE_ALPHABET :: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
@(private) INVITE_VERSION :: 1
@(private) INVITE_VERSION_BITS :: 5
@(private) INVITE_DATA_BITS :: INVITE_VERSION_BITS+2*48+255+64
@(private) INVITE_CHECK_BITS :: 15
@(private) INVITE_CHARACTERS :: (INVITE_DATA_BITS+INVITE_CHECK_BITS)/5
@(private) INVITE_OLD_CHARACTERS :: 35
@(private) INVITE_GROUP :: 4
#assert((INVITE_DATA_BITS+INVITE_CHECK_BITS)%5==0 && INVITE_CHARACTERS==87)

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
    key:=invitation.key.public
    if invitation.key.secret==0 || invitation.lan.kind==.None && invitation.public.kind==.None || key[31]&0x80!=0 || !key_usable(&key) {return ""}
    bits:[(INVITE_DATA_BITS+INVITE_CHECK_BITS+7)/8]u8
    at:=0
    invite_put(bits[:],&at,INVITE_VERSION,INVITE_VERSION_BITS)
    for address in ([2]Address{invitation.lan,invitation.public}) {
        address:=address
        #partial switch address.kind {
        case .None:
        case .IP4: if address.port==0 {return ""}
        case: return ""
        }
        for b in address.ip[:4] {invite_put(bits[:],&at,u64(b),8)}
        invite_put(bits[:],&at,u64(address.port),16)
    }
    for b in key[:31] {invite_put(bits[:],&at,u64(b),8)}
    invite_put(bits[:],&at,u64(key[31]),7)
    invite_put(bits[:],&at,invitation.key.secret,64)
    invite_put(bits[:],&at,u64(invite_check(bits[:],INVITE_DATA_BITS)),INVITE_CHECK_BITS)
    alphabet:=INVITE_ALPHABET
    b:=strings.builder_make(0,INVITE_CHARACTERS+INVITE_CHARACTERS/INVITE_GROUP,allocator)
    at=0
    for i in 0..<INVITE_CHARACTERS {
        if i>0 && i%INVITE_GROUP==0 {strings.write_byte(&b,'-')}
        strings.write_byte(&b,alphabet[invite_get(bits[:],&at,5)])
    }
    return strings.to_string(b)
}

// The invitation of a code, or why it is not one.
invite_decode :: proc(text:string) -> (invitation:Invitation,error:Invite_Error) {
    bits:[(INVITE_DATA_BITS+INVITE_CHECK_BITS+7)/8]u8
    characters,at:=0,0
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
        if value<0 {return {},.Character}
        if characters<INVITE_CHARACTERS {invite_put(bits[:],&at,u64(value),5)}
        characters+=1
    }
    switch {
    case characters==INVITE_OLD_CHARACTERS: return {},.Old
    case characters!=INVITE_CHARACTERS:     return {},.Length
    }
    at=INVITE_DATA_BITS
    if invite_get(bits[:],&at,INVITE_CHECK_BITS)!=u64(invite_check(bits[:],INVITE_DATA_BITS)) {return {},.Check}
    at=0
    if invite_get(bits[:],&at,INVITE_VERSION_BITS)!=INVITE_VERSION {return {},.Version}
    for address in ([2]^Address{&invitation.lan,&invitation.public}) {
        ip:[4]u8
        for &b in ip {b=u8(invite_get(bits[:],&at,8))}
        port:=u16(invite_get(bits[:],&at,16))
        if port!=0 {address^=address_ip4(ip[0],ip[1],ip[2],ip[3],int(port))}
    }
    key:=&invitation.key
    for &b in key.public[:31] {b=u8(invite_get(bits[:],&at,8))}
    key.public[31]=u8(invite_get(bits[:],&at,7))
    key.secret=invite_get(bits[:],&at,64)
    if key.secret==0 || invitation.lan.kind==.None && invitation.public.kind==.None || !key_usable(&key.public) {return {},.Invalid}
    return invitation,.None
}

// What to tell whoever typed a text that is not an invitation code.
invite_error_text :: proc(error:Invite_Error) -> string {
    switch error {
    case .None:      return ""
    case .Character: return "it has a character no invitation has: an invitation is letters and digits by groups of four"
    case .Old:       return "it is an invitation of an earlier Mirai: ask the host for a new one, of 87 characters"
    case .Length:    return "an invitation has 87 characters by groups of four: copy the whole code again"
    case .Check:     return "a character is wrong or two are swapped: copy the code again"
    case .Version:   return "it is an invitation of another version of Mirai: both ends need the same one"
    case .Invalid:   return "it is not an invitation a host makes"
    }
    return ""
}

@(private)
invite_put :: proc "contextless" (bits:[]u8,at:^int,value:u64,count:int) {
    for k in 0..<count {
        if value>>uint(count-1-k)&1!=0 {bits[(at^+k)/8]|=1<<(7-uint((at^+k)%8))}
    }
    at^+=count
}
@(private)
invite_get :: proc "contextless" (bits:[]u8,at:^int,count:int) -> (value:u64) {
    for k in 0..<count {value=value<<1|u64(bits[(at^+k)/8]>>(7-uint((at^+k)%8))&1)}
    at^+=count
    return
}

// CRC-15 of CAN (x^15+x^14+x^10+x^8+x^7+x^4+x^3+1) of the first count bits:
// it finds every burst of up to 15 bits, so any one character changed and
// any two neighbors swapped.
@(private)
invite_check :: proc "contextless" (bits:[]u8,count:int) -> u16 {
    crc:u16
    for i in 0..<count {
        top:=(crc>>14~u16(bits[i/8]>>(7-uint(i%8))))&1
        crc=crc<<1&0x7fff
        if top!=0 {crc~=0x4599}
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
