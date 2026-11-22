package tls

import "core:crypto/ecdh"
import "core:encoding/endian"

@(private) VERSION_TLS13 :: 0x0304
@(private) VERSION_TLS12 :: 0x0303

@(private)
Message :: enum u8 {
    Client_Hello = 1,
    Server_Hello = 2,
    New_Session_Ticket = 4,
    Encrypted_Extensions = 8,
    Certificate = 11,
    Certificate_Request = 13,
    Certificate_Verify = 15,
    Finished = 20,
    Key_Update = 24,
}

@(private) EXT_SERVER_NAME :: 0
@(private) EXT_SUPPORTED_GROUPS :: 10
@(private) EXT_SIGNATURE_ALGORITHMS :: 13
@(private) EXT_ALPN :: 16
@(private) EXT_PRE_SHARED_KEY :: 41
@(private) EXT_EARLY_DATA :: 42
@(private) EXT_SUPPORTED_VERSIONS :: 43
@(private) EXT_COOKIE :: 44
@(private) EXT_KEY_SHARE :: 51

@(private) GROUP_CODE :: [Group]u16{.X25519=0x001d,.P256=0x0017}
@(private) GROUP_CURVE :: [Group]ecdh.Curve{.X25519=.X25519,.P256=.SECP256R1}
@(private) group_code :: proc(g:Group) -> int {t:=GROUP_CODE;return int(t[g])}
@(private) group_curve :: proc(g:Group) -> ecdh.Curve {t:=GROUP_CURVE;return t[g]}

// Signature schemes (RFC 8446, 4.2.3).
@(private) ECDSA_P256_SHA256 :: 0x0403
@(private) ECDSA_P384_SHA384 :: 0x0503
@(private) RSA_PSS_RSAE_SHA256 :: 0x0804
@(private) RSA_PSS_RSAE_SHA384 :: 0x0805
@(private) RSA_PSS_RSAE_SHA512 :: 0x0806
@(private) ED25519 :: 0x0807
// What a client takes: the first six in CertificateVerify, all of them in the chain.
@(private) SIGNATURE_SCHEMES :: [?]u16{ECDSA_P256_SHA256,ECDSA_P384_SHA384,RSA_PSS_RSAE_SHA256,RSA_PSS_RSAE_SHA384,RSA_PSS_RSAE_SHA512,ED25519,0x0401,0x0501,0x0601}

// The random of a HelloRetryRequest: SHA-256 of "HelloRetryRequest" (RFC 8446, 4.1.3).
@(private) RETRY_RANDOM :: [32]u8{0xcf,0x21,0xad,0x74,0xe5,0x9a,0x61,0x11,0xbe,0x1d,0x8c,0x02,0x1e,0x65,0xb8,0x91,0xc2,0xa2,0x11,0x16,0x7a,0xbb,0x8c,0x5e,0x07,0x9e,0x09,0xe2,0xc8,0xa8,0x33,0x9c}

@(private) VERIFY_SERVER :: "TLS 1.3, server CertificateVerify"
@(private) VERIFY_CONTENT_MAX :: 64+len(VERIFY_SERVER)+1+HASH_MAX

// Reads the vectors of a message; a read past its end marks it bad and gives zeros.
@(private)
Reader :: struct {data:[]u8,at:int,bad:bool}

@(private)
read_bytes :: proc(r:^Reader,n:int) -> []u8 {
    if r.bad || n<0 || n>len(r.data)-r.at {
        r.bad=true
        return nil
    }
    r.at+=n
    return r.data[r.at-n:r.at]
}

@(private)
read_uint :: proc(r:^Reader,size:int) -> int {
    v:=0
    for b in read_bytes(r,size) {v=v<<8|int(b)}
    return v
}

@(private) read_u8 :: proc(r:^Reader) -> int {return read_uint(r,1)}
@(private) read_u16 :: proc(r:^Reader) -> int {return read_uint(r,2)}

// A vector with a length prefix of prefix bytes, of lo to hi bytes.
@(private)
read_vector :: proc(r:^Reader,prefix,lo,hi:int) -> []u8 {
    n:=read_uint(r,prefix)
    if n<lo || n>hi {r.bad=true}
    return read_bytes(r,n)
}

@(private)
read_done :: proc(r:^Reader) -> bool {return !r.bad && r.at==len(r.data)}

@(private)
Writer :: struct {data:[]u8,at:int,bad:bool}

@(private)
put_bytes :: proc(w:^Writer,bytes:[]u8) {
    if w.bad || len(bytes)>len(w.data)-w.at {
        w.bad=true
        return
    }
    copy(w.data[w.at:],bytes)
    w.at+=len(bytes)
}

@(private)
put_uint :: proc(w:^Writer,v:int,size:int) {
    b:[4]u8
    endian.unchecked_put_u32be(b[:],u32(v))
    put_bytes(w,b[4-size:])
}

@(private) put_u8 :: proc(w:^Writer,v:int) {put_uint(w,v,1)}
@(private) put_u16 :: proc(w:^Writer,v:int) {put_uint(w,v,2)}

// Opens a vector with a length prefix of prefix bytes; vector_close writes its length.
@(private)
vector_open :: proc(w:^Writer,prefix:int) -> int {
    put_uint(w,0,prefix)
    return w.at
}

@(private)
vector_close :: proc(w:^Writer,at,prefix:int) {
    if w.bad {return}
    n:=w.at-at
    if n>=1<<uint(8*prefix) {
        w.bad=true
        return
    }
    b:[4]u8
    endian.unchecked_put_u32be(b[:],u32(n))
    copy(w.data[at-prefix:],b[4-prefix:])
}

@(private)
put_vector :: proc(w:^Writer,prefix:int,bytes:[]u8) {
    at:=vector_open(w,prefix)
    put_bytes(w,bytes)
    vector_close(w,at,prefix)
}

@(private)
message_open :: proc(w:^Writer,kind:Message) -> int {
    put_u8(w,int(kind))
    return vector_open(w,3)
}

@(private) EXTENSIONS_MAX :: 64

@(private)
Extension :: struct {kind:int,data:[]u8}

// The extensions of a message: each type once (RFC 8446, 4.2).
@(private)
Extensions :: struct {list:[EXTENSIONS_MAX]Extension,count:int}

@(private)
extensions_parse :: proc(data:[]u8,out:^Extensions) -> Error {
    r:=Reader{data=data}
    for r.at<len(data) {
        if out.count==EXTENSIONS_MAX {return .Decode}
        kind:=read_u16(&r)
        body:=read_vector(&r,2,0,0xffff)
        if r.bad {return .Decode}
        for e in out.list[:out.count] {
            if e.kind==kind {return .Illegal_Parameter}
        }
        out.list[out.count]={kind,body}
        out.count+=1
    }
    return nil
}

@(private)
extension_find :: proc(e:^Extensions,kind:int) -> (data:[]u8,found:bool) {
    for x in e.list[:e.count] {
        if x.kind==kind {return x.data,true}
    }
    return nil,false
}

// What a CertificateVerify signs (RFC 8446, 4.4.3).
@(private)
verify_content :: proc(transcript:[]u8,dst:^[VERIFY_CONTENT_MAX]u8) -> []u8 {
    for i in 0..<64 {dst[i]=' '}
    copy(dst[64:],VERIFY_SERVER)
    dst[64+len(VERIFY_SERVER)]=0
    copy(dst[65+len(VERIFY_SERVER):],transcript)
    return dst[:65+len(VERIFY_SERVER)+len(transcript)]
}

@(private)
suite_of :: proc(code:int) -> (suite:Suite,ok:bool) {
    for s in Suite {
        if suite_code(s)==code {return s,true}
    }
    return {},false
}

@(private)
group_of :: proc(code:int) -> (group:Group,ok:bool) {
    for g in Group {
        if group_code(g)==code {return g,true}
    }
    return {},false
}

// The shared secret of this side's key share and the peer's public key.
@(private)
key_exchange :: proc(c:^Conn,peer:[]u8,dst:^[HASH_MAX]u8) -> (shared:[]u8,err:Error) {
    curve:=group_curve(c.group)
    public:ecdh.Public_Key
    if !ecdh.public_key_set_bytes(&public,curve,peer) {return nil,.Illegal_Parameter}
    defer ecdh.public_key_clear(&public)
    size:=ecdh.SHARED_SECRET_SIZES[curve]
    if !ecdh.ecdh(&c.key_share,&public,dst[:size]) {return nil,.Illegal_Parameter}
    return dst[:size],nil
}

// A new key share of this side for its group, and its public key.
@(private)
key_share_make :: proc(c:^Conn,dst:^[65]u8) -> (public:[]u8,err:Error) {
    curve:=group_curve(c.group)
    if !ecdh.private_key_generate(&c.key_share,curve) {return nil,.Internal}
    size:=ecdh.PUBLIC_KEY_SIZES[curve]
    ecdh.private_key_public_bytes(&c.key_share,dst[:size])
    return dst[:size],nil
}
