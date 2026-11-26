package hub

import "core:crypto"
import "core:crypto/argon2id"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:kai"
import "mirai:store"

// The web accounts of a server: a name a member chose from its device, the
// Argon2id of its password and that device's key, under ACCOUNT_NAMESPACE
// refs of the server's own store. A name belongs to the device that set it
// first; setting it again from that device changes the password. A session is
// a random token in a cookie, kept in memory: a restart signs everyone out.

ACCOUNT_NAMESPACE :: "kai-web"
ACCOUNT_MAGIC :: "kai-web-1"
PASSWORD_MIN :: 8
PASSWORD_MAX :: 256
SALT_BYTES :: 16
HASH_BYTES :: 32
ARGON2ID :: argon2id.Parameters{memory_size=19*1024,passes=2,parallelism=1} // OWASP

Session :: struct {
    key:kai.Key,  // the device it signs in as
    name:[kai.NAME_MAX]u8,
    name_len:int,
    expires:i64,  // ns
}

@(private)
Account :: struct #packed {
    magic:[len(ACCOUNT_MAGIC)]u8,
    salt:[SALT_BYTES]u8,
    hash:[HASH_BYTES]u8,
    key:kai.Key,
}

// Whether name is an account name: 1 to 64 of a-z, 0-9, '.', '_' and '-'.
account_name_valid :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>kai.NAME_MAX {return false}
    for c in transmute([]u8)name {
        switch c {
        case 'a'..='z','0'..='9','.','_','-':
        case: return false
        }
    }
    return true
}

// Sets the web sign-in of the device key (kai.Agent_Options.web_login): a
// member of an org of this server; false when the name is another device's.
account_set :: proc(data:rawptr,key:kai.Key,name,password:string) -> bool {
    h:=(^Hub)(data)
    if !account_name_valid(name) || len(password)<PASSWORD_MIN || len(password)>PASSWORD_MAX {return false}
    sync.mutex_lock(&h.lock)
    defer sync.mutex_unlock(&h.lock)
    if held,ok:=account_get(h,name);ok && held.key!=key {return false}
    a:Account
    copy(a.magic[:],ACCOUNT_MAGIC)
    crypto.rand_bytes(a.salt[:])
    a.key=key
    parameters:=ARGON2ID
    if argon2id.derive(&parameters,transmute([]u8)password,a.salt[:],a.hash[:])!=nil {return false}
    bytes:=transmute([size_of(Account)]u8)a
    address,e:=store.put(&h.s,bytes[:])
    if e!=.None {return false}
    return store.ref_set(&h.s,ACCOUNT_NAMESPACE,name,address)==.None && store.commit(&h.s)==.None
}

@(private)
account_get :: proc(h:^Hub,name:string) -> (a:Account,ok:bool) {
    address,e:=store.ref_get(&h.s,ACCOUNT_NAMESPACE,name)
    if e!=.None {return}
    o,oe:=store.object_open(&h.s,address)
    if oe!=.None {return}
    defer store.object_close(&o)
    if store.object_size(&o)!=size_of(Account) {return}
    bytes:[size_of(Account)]u8
    if store.object_read(&o,0,bytes[:])!=.None {return}
    a=transmute(Account)bytes
    return a,string(a.magic[:])==ACCOUNT_MAGIC
}

// Signs name in: a new session's token when the password holds.
session_open :: proc(h:^Hub,name,password:string) -> (token:[32]u8,ok:bool) {
    if !account_name_valid(name) || len(password)>PASSWORD_MAX {return}
    sync.mutex_lock(&h.lock)
    a,found:=account_get(h,name)
    sync.mutex_unlock(&h.lock)
    if !found {
        // As slow as a wrong password, so a name does not tell whether it is taken.
        a.salt={}
    }
    hash:[HASH_BYTES]u8
    parameters:=ARGON2ID
    if argon2id.derive(&parameters,transmute([]u8)password,a.salt[:],hash[:])!=nil {return}
    if !found || crypto.compare_constant_time(hash[:],a.hash[:])!=1 {return}
    crypto.rand_bytes(token[:])
    session:=Session{key=a.key,expires=time.now()._nsec+i64(SESSION_HOURS)*i64(time.Hour)}
    session.name_len=copy(session.name[:],name)
    sync.mutex_lock(&h.lock)
    defer sync.mutex_unlock(&h.lock)
    now:=time.now()._nsec
    for t,s in h.sessions {
        if s.expires<now {delete_key(&h.sessions,t)}
    }
    h.sessions[token]=session
    return token,true
}

session_close :: proc(h:^Hub,token:[32]u8) {
    sync.mutex_lock(&h.lock)
    defer sync.mutex_unlock(&h.lock)
    delete_key(&h.sessions,token)
}

// The session of the request's cookie; ok false when it signed in as nobody.
session_of :: proc(h:^Hub,r:^Request) -> (s:Session,token:[32]u8,ok:bool) {
    cookies,found:=request_header(r,"cookie")
    if !found {return}
    for part in strings.split_iterator(&cookies,";") {
        c:=strings.trim_space(part)
        if !strings.has_prefix(c,"kai=") || len(c)!=4+64 {continue}
        if !hex_parse(c[4:],token[:]) {return}
        sync.mutex_lock(&h.lock)
        defer sync.mutex_unlock(&h.lock)
        held,known:=h.sessions[token]
        if !known || held.expires<time.now()._nsec {return}
        return held,token,true
    }
    return
}

@(private)
hex_parse :: proc(text:string,out:[]u8) -> bool {
    if len(text)!=2*len(out) {return false}
    for &b,k in out {
        hi,lo:=hex_digit(text[2*k]),hex_digit(text[2*k+1])
        if hi<0 || lo<0 {return false}
        b=u8(hi<<4|lo)
    }
    return true
}

@(private)
hex_digit :: proc(c:u8) -> int {
    switch c {
    case '0'..='9': return int(c-'0')
    case 'a'..='f': return int(c-'a'+10)
    }
    return -1
}
