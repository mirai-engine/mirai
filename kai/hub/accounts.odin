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
// first; setting it again from that device changes the password and ends the
// device's sessions. A session is a random token in a cookie, kept in memory:
// a restart signs everyone out. At most DERIVATIONS_MAX passwords derive at
// once, so a crowd of sign-ins does not take the server's memory.

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
// member of an org of this server; false when the name is another device's or
// the server is deriving as many passwords as it may. The device's sessions end.
account_set :: proc(data:rawptr,key:kai.Key,name,password:string) -> bool {
    h:=(^Hub)(data)
    if !account_name_valid(name) || len(password)<PASSWORD_MIN || len(password)>PASSWORD_MAX {return false}
    sync.mutex_lock(&h.lock)
    held,found:=account_get(h,name)
    sync.mutex_unlock(&h.lock)
    if found && held.key!=key {return false}
    a:Account
    copy(a.magic[:],ACCOUNT_MAGIC)
    crypto.rand_bytes(a.salt[:])
    a.key=key
    if derived,_:=derive(h,password,a.salt[:],a.hash[:]);!derived {return false}
    sync.mutex_lock(&h.lock)
    defer sync.mutex_unlock(&h.lock)
    // Another device may have taken the name while this one derived.
    if held,found=account_get(h,name);found && held.key!=key {return false}
    bytes:=transmute([size_of(Account)]u8)a
    address,e:=store.put(&h.s,bytes[:])
    if e!=.None || store.ref_set(&h.s,ACCOUNT_NAMESPACE,name,address)!=.None || store.commit(&h.s)!=.None {return false}
    for t,session in h.sessions {
        if session.key==key {delete_key(&h.sessions,t)}
    }
    return true
}

// Argon2id of password into hash; busy when DERIVATIONS_MAX already run.
@(private)
derive :: proc(h:^Hub,password:string,salt,hash:[]u8) -> (ok,busy:bool) {
    sync.mutex_lock(&h.lock)
    busy=h.derivations>=DERIVATIONS_MAX
    if !busy {h.derivations+=1}
    sync.mutex_unlock(&h.lock)
    if busy {return}
    parameters:=ARGON2ID
    ok=argon2id.derive(&parameters,transmute([]u8)password,salt,hash)==nil
    sync.mutex_lock(&h.lock)
    h.derivations-=1
    sync.mutex_unlock(&h.lock)
    return
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

Sign_In :: enum u8 {
    Refused, // no such name, or another password
    Signed,
    Busy,    // DERIVATIONS_MAX passwords derive already: try again in a moment
}

// Signs name in: a new session's token when the password holds. Past
// SESSIONS_MAX sessions the oldest ends.
session_open :: proc(h:^Hub,name,password:string) -> (token:[32]u8,result:Sign_In) {
    if !account_name_valid(name) || len(password)>PASSWORD_MAX {return}
    sync.mutex_lock(&h.lock)
    a,found:=account_get(h,name)
    sync.mutex_unlock(&h.lock)
    if !found {
        // As slow as a wrong password, so a name does not tell whether it is taken.
        a.salt={}
    }
    hash:[HASH_BYTES]u8
    derived,busy:=derive(h,password,a.salt[:],hash[:])
    if busy {return {},.Busy}
    if !derived || !found || crypto.compare_constant_time(hash[:],a.hash[:])!=1 {return}
    crypto.rand_bytes(token[:])
    session:=Session{key=a.key,expires=time.now()._nsec+i64(SESSION_HOURS)*i64(time.Hour)}
    session.name_len=copy(session.name[:],name)
    sync.mutex_lock(&h.lock)
    defer sync.mutex_unlock(&h.lock)
    now:=time.now()._nsec
    for t,s in h.sessions {
        if s.expires<now {delete_key(&h.sessions,t)}
    }
    if len(h.sessions)>=SESSIONS_MAX {
        oldest:[32]u8
        expires:=max(i64)
        for t,s in h.sessions {
            if s.expires<expires {oldest,expires=t,s.expires}
        }
        delete_key(&h.sessions,oldest)
    }
    if _,e:=map_insert(&h.sessions,token,session);e!=nil {return {},.Refused}
    return token,.Signed
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
