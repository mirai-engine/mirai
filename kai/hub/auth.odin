package hub

import "core:crypto"
import "core:crypto/ed25519"
import "core:strings"
import "mirai:kai"
import "mirai:store"

// Sessions and approvals. A session is a random token in an HttpOnly cookie
// that only this site gets; it reads, and a write still needs a signature of
// the user's own. A browser signs in with its passkey's assertion of a
// challenge of this server, used once; a browser without a passkey asks a
// device of the user to approve, by a link that `mirai kai web approve`
// opens: the device signs the login, a write, or the Web_Key_Add of a new
// passkey, and the browser that asked learns it by polling with a secret
// only it holds.

LABEL_WEB_LOGIN :: "kai-1/web-login"
USERS_MAX :: kai.AGENT_LOGS/2 // user logs a node keeps: past it, no browser makes another

Approval_Kind :: enum u8 {None,Login,Entry,Web_Key}
Approval_State :: enum u8 {Waiting,Approved,Denied,Expired}

Approval :: struct {
    used:bool,
    kind:Approval_Kind,
    state:Approval_State,
    id:[16]u8,
    secret:[32]u8,
    challenge:[32]u8,
    created:f64,
    user:kai.Log_Id,     // Entry and Web_Key: whose; Login: who approved
    device:kai.Key,      // the device that approved
    type:kai.Entry_Type, // Entry
    log:kai.Log_Id,
    body:[dynamic]u8,
    credential:[255]u8,  // Web_Key
    credential_len:int,
    cose:[kai.COSE_KEY_MAX]u8,
    cose_len:int,
    address:store.Hash,  // the entry kept
    taken:bool,          // Login: the session was given
    asker:[16]u8,        // the address of the browser that asked
    serial:u64,          // the order approvals were made in
}

approval_clear :: proc(a:^Approval) {
    delete(a.body)
    crypto.zero_explicit(a,size_of(Approval))
}

@(private)
APPROVAL_KIND_TEXT :: [Approval_Kind]string{.None="",.Login="login",.Entry="entry",.Web_Key="passkey"}
@(private)
APPROVAL_STATE_TEXT :: [Approval_State]string{.Waiting="waiting",.Approved="approved",.Denied="denied",.Expired="expired"}

// --- sessions ---

session_of :: proc(h:^Hub,r:^Request) -> ^Session {
    cookie,found:=request_header(r,"cookie")
    if !found {return nil}
    for part in strings.split_iterator(&cookie,";") {
        item:=strings.trim_space(part)
        if !strings.has_prefix(item,COOKIE+"=") {continue}
        token,ok:=base64_parse(item[len(COOKIE)+1:],32)
        if !ok || len(token)!=32 {return nil}
        for &s in h.sessions {
            if !s.used || crypto.compare_constant_time(s.token[:],token)!=1 {continue}
            if h.now-s.created>SESSION_SECONDS || h.now-s.seen>SESSION_IDLE_SECONDS || !session_holds(h,&s) {
                crypto.zero_explicit(&s,size_of(Session))
                return nil
            }
            s.seen=h.now
            return &s
        }
        return nil
    }
    return nil
}

// Whether what started a session still holds in the user's fold: its passkey,
// or the device that approved it, not revoked.
@(private)
session_holds :: proc(h:^Hub,s:^Session) -> bool {
    u:=user_fold_of(h,s.user)
    if u==nil {return false}
    if s.web_key=={} {return kai.user_device_active(u,s.device)}
    p,found:=passkey_of(h,u,s.credential[:s.credential_len])
    return found && p.key==s.web_key
}

// A new session for user, by its passkey or by the device that approved it;
// the oldest goes when all are taken.
session_new :: proc(h:^Hub,user:kai.Log_Id,web_key:kai.Key,credential:[]u8,device:kai.Key={}) -> (s:^Session,cookie:string) {
    slot:=0
    for x,i in h.sessions {
        if !x.used {
            slot=i
            break
        }
        if x.seen<h.sessions[slot].seen {slot=i}
    }
    s=&h.sessions[slot]
    s^={used=true,user=user,web_key=web_key,device=device,created=h.now,seen=h.now}
    s.credential_len=copy(s.credential[:],credential)
    crypto.rand_bytes(s.token[:])
    j:=json_make()
    json_base64(&j,s.token[:])
    token:=json_text(&j)
    cookie=strings.concatenate({"Set-Cookie: ",COOKIE,"=",token[1:len(token)-1],"; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=43200\r\n"},context.temp_allocator)
    return
}

@(private)
route_session :: proc(c:^Call) {
    s:=c.session
    roles:=ROLE_TEXT
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"user",s.user)
    name:=""
    for o in runner_of(c.h).orgs {
        for u in o.agent.user_list {
            if u.log.id==s.user {name=user_name(u)}
        }
    }
    json_member_string(&j,"name",name)
    json_key(&j,"passkey")
    if s.web_key=={} {json_null(&j)} else {
        key:=s.web_key
        json_hex(&j,key[:])
    }
    json_key(&j,"orgs")
    json_array(&j)
    for o in runner_of(c.h).orgs {
        role:=session_role(c,o)
        if role==.None {continue}
        json_object(&j)
        json_member_hash(&j,"org",o.id)
        json_member_string(&j,"name",org_name(o))
        json_member_string(&j,"role",roles[role])
        json_end_object(&j)
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
route_challenge :: proc(c:^Call) {
    h:=c.h
    slot:=0
    for x,i in h.challenges {
        if !x.used || x.expires<h.now {
            slot=i
            break
        }
        if x.expires<h.challenges[slot].expires {slot=i}
    }
    ch:=&h.challenges[slot]
    ch^={used=true,expires=h.now+CHALLENGE_SECONDS}
    crypto.rand_bytes(ch.value[:])
    j:=json_make()
    json_object(&j)
    json_key(&j,"challenge")
    json_base64(&j,ch.value[:])
    json_member_string(&j,"rp_id",h.desc.rp_id)
    json_member_int(&j,"timeout_ms",i64(CHALLENGE_SECONDS*1000))
    json_end_object(&j)
    json_response(c,&j)
}

// Takes a challenge this server gave and has not taken back: once.
@(private)
challenge_take :: proc(h:^Hub,value:[]u8) -> bool {
    if len(value)!=32 {return false}
    for &x in h.challenges {
        if !x.used || crypto.compare_constant_time(x.value[:],value)!=1 {continue}
        alive:=x.expires>=h.now
        x={}
        return alive
    }
    return false
}

Assertion_Body :: struct {
    credential,authenticator_data,client_data_json,signature:string,
}

@(private)
assertion_parse :: proc(c:^Call,b:Assertion_Body) -> (credential:[]u8,a:kai.Web_Assertion,ok:bool) {
    credential,ok=base64_parse(b.credential,255)
    data,ok1:=base64_parse(b.authenticator_data,kai.AUTHENTICATOR_DATA_MAX)
    client,ok2:=base64_parse(b.client_data_json,kai.CLIENT_DATA_MAX)
    signature,ok3:=base64_parse(b.signature,255)
    if !ok || !ok1 || !ok2 || !ok3 || len(credential)==0 {
        fail(c,400,"the assertion's fields are base64url of the browser's bytes: credential, authenticator_data, client_data_json, signature")
        return nil,{},false
    }
    return credential,{data,client,signature},true
}

// A passkey of this relying party some user's log added, by its credential id.
Passkey :: struct {
    user:^kai.User_Fold,
    key:kai.Key,
    cose:[]u8,
    added:store.Hash, // its Web_Key_Add
}

// The passkey of user u with that credential id, not revoked. A credential id
// is the browser's word only: another user may record the same one.
passkey_of :: proc(h:^Hub,u:^kai.User_Fold,credential:[]u8) -> (p:Passkey,found:bool) {
    for w in u.web_keys {
        if w.revoked {continue}
        item:=&u.log.items[w.added]
        head,tail,ok:=kai.body_head(item.entry.body,kai.Web_Key_Add_Body)
        if !ok || len(tail)!=int(head.credential)+int(head.cose)+int(head.rp) {continue}
        id:=tail[:head.credential]
        cose:=tail[head.credential:][:head.cose]
        rp:=string(tail[int(head.credential)+int(head.cose):])
        if rp!=h.desc.rp_id || string(id)!=string(credential) {continue}
        return {user=u,key=w.key,cose=cose,added=item.address},true
    }
    return
}

@(private)
route_sign_in :: proc(c:^Call) {
    Body :: struct {challenge:string,assertion:Assertion_Body}
    b:Body
    if !body_parse(c,&b) {return}
    challenge,cok:=base64_parse(b.challenge,32)
    credential,a,ok:=assertion_parse(c,b.assertion)
    if !ok {return}
    if !cok || !challenge_take(c.h,challenge) {
        fail(c,401,"the challenge is not one this server gave, it expired or it was used: ask for a new one")
        return
    }
    // Every user that records the credential id is tried: the one whose key signed is the one.
    p:Passkey
    failure:=kai.Webauthn_Failure.None
    found:=false
    users: for o in runner_of(c.h).orgs {
        for u in o.agent.user_list {
            candidate,has:=passkey_of(c.h,u,credential)
            if !has {continue}
            key,parsed:=kai.cose_key_parse(candidate.cose)
            if !parsed {continue}
            failure=kai.webauthn_verify(&key,c.h.desc.rp_id,challenge,&a,false)
            if failure==.None {
                p,found=candidate,true
                break users
            }
        }
    }
    if !found {
        fail(c,401,failure==.None?"no user of this node has that passkey: register it first":kai.webauthn_failure_text(failure))
        return
    }
    _,cookie:=session_new(c.h,p.user.log.id,p.key,credential)
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"user",p.user.log.id)
    json_member_string(&j,"name",user_name(p.user))
    json_end_object(&j)
    json_response(c,&j)
    c.response.headers=cookie
}

@(private)
route_sign_out :: proc(c:^Call) {
    if c.session!=nil {crypto.zero_explicit(c.session,size_of(Session))}
    j:=json_make()
    json_object(&j)
    json_end_object(&j)
    json_response(c,&j)
    c.response.headers=COOKIE+"=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0\r\n"
    c.response.headers=strings.concatenate({"Set-Cookie: ",c.response.headers},context.temp_allocator)
}

// --- a user whose first passkey is in the browser ---

@(private)
route_user_create :: proc(c:^Call) {
    Body :: struct {entries:[]string}
    b:Body
    if !body_parse(c,&b) {return}
    if len(b.entries)!=2 {
        fail(c,400,"entries are two: the User_Genesis, then the Web_Key_Add of the passkey")
        return
    }
    s:=store_of(c.h)
    if refs,e:=store.ref_list(s,kai.USER_NAMESPACE,context.temp_allocator);e!=.None || len(refs)>=USERS_MAX {
        fail(c,503,"this node keeps as many users as it may: an admin of its org removes some, or use another node")
        return
    }
    l:kai.Log
    kai.log_init(&l,{},context.temp_allocator)
    for text,i in b.entries {
        bytes,ok:=base64_parse(text,kai.ENTRY_BODY_MAX+4096)
        if !ok {
            fail(c,400,"each entry is base64url of its bytes")
            return
        }
        e,de:=kai.entry_decode(bytes)
        want:=i==0?kai.Entry_Type.User_Genesis:.Web_Key_Add
        if de!=.None || e.type!=want {
            fail(c,400,"the entries are the User_Genesis, then a Web_Key_Add: GET /api/entries lays them out")
            return
        }
        if added,ae:=kai.log_add(&l,bytes,true);!added || ae!=.None {
            fail(c,400,"an entry is not signed by its author or not of this log: sign the genesis and the Web_Key_Add with the new recovery key")
            return
        }
    }
    name:[64]u8
    if _,e:=store.ref_get(s,kai.USER_NAMESPACE,kai.log_name(l.id,&name));e==.None {
        fail(c,409,"this user exists on this node: a browser makes only new users; add a passkey to an existing one with POST /api/passkeys/link")
        return
    }
    f:kai.User_Fold
    if kai.user_fold(&f,&l,context.temp_allocator)!=.None || !f.valid[0] || !f.valid[1] || len(f.web_keys)!=1 {
        fail(c,400,"the new user's log does not hold: the genesis is signed by its recovery key with the device's proof, and the Web_Key_Add by the recovery key")
        return
    }
    for &item in l.items {
        if item.entry.type!=.Web_Key_Add {continue}
        head,tail,_:=kai.body_head(item.entry.body,kai.Web_Key_Add_Body)
        if len(tail)!=int(head.credential)+int(head.cose)+int(head.rp) || string(tail[int(head.credential)+int(head.cose):])!=c.h.desc.rp_id {
            fail(c,400,"the passkey is for another relying party: register it for this site's rp_id")
            return
        }
    }
    if why:=log_keep(c.h,&l);why!="" {
        fail(c,500,why)
        return
    }
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"user",l.id)
    json_end_object(&j)
    json_response(c,&j,201)
}

// Saves a log with the entries the store keeps of it already, so a log from a
// browser only adds to the stored one, and tells the peers of the runner.
@(private)
log_keep :: proc(h:^Hub,l:^kai.Log) -> string {
    s:=store_of(h)
    name:[64]u8
    if address,e:=store.ref_get(s,kai.log_namespace(l.kind),kai.log_name(l.id,&name));e==.None {
        if _,le:=kai.log_load(s,l,address,false);le!=.None {return "the store's copy of the log does not read: see the node's disk"}
    }
    if _,e:=kai.log_save(s,l);e!=.None {return "the store does not take the log: see the node's disk"}
    if store.commit(s)!=.None {return "the store does not commit: see the node's disk"}
    kai.runner_changed(runner_of(h),kai.log_namespace(l.kind),store.hex(l.id,&name))
    return ""
}

// --- approvals ---

// A new approval. One a browser asks without a session (a login, a passkey
// link) takes the place of the oldest of its address past
// APPROVALS_PER_ADDRESS, or of the oldest of all when the table is full.
@(private)
approval_new :: proc(c:^Call,kind:Approval_Kind) -> ^Approval {
    h:=c.h
    asker:[16]u8
    if c.conn!=nil {asker=c.conn.address}
    anonymous:=kind!=.Entry
    slot,mine,oldest,oldest_mine:=-1,0,-1,-1
    for &a,i in h.approvals {
        if a.used && h.now-a.created>APPROVAL_SECONDS {approval_clear(&a)}
        if !a.used {
            if slot<0 {slot=i}
            continue
        }
        if a.kind==.Entry {continue}
        if oldest<0 || a.serial<h.approvals[oldest].serial {oldest=i}
        if a.asker==asker {
            mine+=1
            if oldest_mine<0 || a.serial<h.approvals[oldest_mine].serial {oldest_mine=i}
        }
    }
    if anonymous && mine>=APPROVALS_PER_ADDRESS {slot=oldest_mine}
    if slot<0 && anonymous {slot=oldest}
    if slot<0 {
        fail(c,503,"too many approvals wait: try again in a few minutes")
        return nil
    }
    a:=&h.approvals[slot]
    if a.used {approval_clear(a)}
    h.approvals_made+=1
    a^={used=true,kind=kind,created=h.now,asker=asker,serial=h.approvals_made}
    crypto.rand_bytes(a.id[:])
    crypto.rand_bytes(a.secret[:])
    crypto.rand_bytes(a.challenge[:])
    a.body=make([dynamic]u8,h.allocator)
    return a
}

@(private)
approval_answer :: proc(c:^Call,a:^Approval) {
    link:=approval_link(c.h,a)
    j:=json_make()
    json_object(&j)
    json_member_hex(&j,"id",a.id[:])
    json_key(&j,"secret")
    json_base64(&j,a.secret[:])
    json_member_string(&j,"link",link)
    json_member_string(&j,"command",strings.concatenate({"mirai kai web approve '",link,"'"},context.temp_allocator))
    json_end_object(&j)
    json_response(c,&j,201)
}

approval_link :: proc(h:^Hub,a:^Approval) -> string {
    j:=json_make()
    json_hex(&j,a.id[:])
    id:=json_text(&j)
    return strings.concatenate({"kai://approve?origin=",percent_encode(h.origin),"&id=",id[1:len(id)-1]},context.temp_allocator)
}

HEX_UPPER :: [16]u8{'0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F'}

percent_encode :: proc(text:string) -> string {
    out:=make([dynamic]u8,0,len(text)*3,context.temp_allocator)
    for ch in transmute([]u8)text {
        switch ch {
        case 'a'..='z','A'..='Z','0'..='9','-','.','_','~': append(&out,ch)
        case:
            digits:=HEX_UPPER
            append(&out,'%',digits[ch>>4],digits[ch&15])
        }
    }
    return string(out[:])
}

@(private)
approval_find :: proc(c:^Call) -> ^Approval {
    id:[16]u8
    if !hex_parse(path_param(c,"id"),id[:]) {
        fail(c,400,"an approval is named by its id, 32 hex")
        return nil
    }
    for &a in c.h.approvals {
        if !a.used || a.id!=id {continue}
        if c.h.now-a.created>APPROVAL_SECONDS && a.state==.Waiting {a.state=.Expired}
        return &a
    }
    fail(c,404,"no such approval: it expired or was never made; ask again in the browser")
    return nil
}

@(private)
route_passkey_link :: proc(c:^Call) {
    Body :: struct {user,credential,cose:string}
    b:Body
    if !body_parse(c,&b) {return}
    user,uok:=hash_parse(b.user)
    credential,cok:=base64_parse(b.credential,255)
    cose,kok:=base64_parse(b.cose,kai.COSE_KEY_MAX)
    if !uok || !cok || !kok || len(credential)==0 {
        fail(c,400,"user is 64 hex; credential and cose are base64url of the new credential's id and COSE key")
        return
    }
    if _,parsed:=kai.cose_key_parse(cose);!parsed {
        fail(c,400,"the passkey is not an Ed25519 or P-256 COSE key: register a passkey of those")
        return
    }
    if user_fold_of(c.h,user)==nil {
        fail(c,404,"no such user on this node: its devices sync it here once its org lists the node")
        return
    }
    a:=approval_new(c,.Web_Key)
    if a==nil {return}
    a.user=user
    a.credential_len=copy(a.credential[:],credential)
    a.cose_len=copy(a.cose[:],cose)
    approval_answer(c,a)
}

user_fold_of :: proc(h:^Hub,user:kai.Log_Id) -> ^kai.User_Fold {
    for o in runner_of(h).orgs {
        for u in o.agent.user_list {
            if u.log.id==user {return u}
        }
    }
    return nil
}

@(private)
route_approval_new :: proc(c:^Call) {
    Body :: struct {kind:string,draft:Draft_Body}
    b:Body
    if !body_parse(c,&b) {return}
    switch b.kind {
    case "login":
        a:=approval_new(c,.Login)
        if a==nil {return}
        approval_answer(c,a)
    case "entry":
        if c.session==nil {
            fail(c,401,"a write's approval is asked from a session: sign in first")
            return
        }
        d,ok:=draft_build(c,&b.draft)
        if !ok {return}
        a:=approval_new(c,.Entry)
        if a==nil {return}
        a.user,a.type,a.log=c.session.user,d.type,d.log
        append(&a.body,..d.body)
        approval_answer(c,a)
    case:
        fail(c,400,"kind is login or entry")
    }
}

@(private)
route_approval_get :: proc(c:^Call) {
    a:=approval_find(c)
    if a==nil {return}
    kinds:=APPROVAL_KIND_TEXT
    states:=APPROVAL_STATE_TEXT
    j:=json_make()
    json_object(&j)
    json_member_string(&j,"kind",kinds[a.kind])
    json_member_string(&j,"state",states[a.state])
    json_member_string(&j,"rp_id",c.h.desc.rp_id)
    json_member_string(&j,"origin",c.h.origin)
    switch a.kind {
    case .None:
    case .Login:
        json_key(&j,"challenge")
        json_base64(&j,a.challenge[:])
    case .Entry:
        json_member_hash(&j,"user",a.user)
        types:=TYPE_TEXT
        json_member_string(&j,"type",types[a.type])
        json_member_hash(&j,"log",a.log)
        json_key(&j,"body")
        json_base64(&j,a.body[:])
    case .Web_Key:
        json_member_hash(&j,"user",a.user)
        json_key(&j,"credential")
        json_base64(&j,a.credential[:a.credential_len])
        json_key(&j,"cose")
        json_base64(&j,a.cose[:a.cose_len])
    }
    json_end_object(&j)
    json_response(c,&j)
}

// What a device signs to let a browser in: the label, the relying party and the challenge.
login_message :: proc(rp_id:string,challenge:[32]u8) -> []u8 {
    x:=challenge
    return transmute([]u8)strings.concatenate({LABEL_WEB_LOGIN,rp_id,string(x[:])},context.temp_allocator)
}

@(private)
route_approval_answer :: proc(c:^Call) {
    a:=approval_find(c)
    if a==nil {return}
    if a.state!=.Waiting {
        fail(c,409,"the approval is answered or expired already")
        return
    }
    Body :: struct {device,signature,entry:string}
    b:Body
    if !body_parse(c,&b) {return}
    switch a.kind {
    case .None:
    case .Login:
        device:kai.Key
        signature,sok:=base64_parse(b.signature,64)
        if !hex_parse(b.device,device[:]) || !sok || len(signature)!=64 {
            fail(c,400,"device is the device key (64 hex) and signature base64url of its Ed25519 signature")
            return
        }
        public:ed25519.Public_Key
        if !ed25519.public_key_set_bytes(&public,device[:]) || !ed25519.verify(&public,login_message(c.h.desc.rp_id,a.challenge),signature) {
            fail(c,401,"the signature is not the device's over this approval")
            return
        }
        user:^kai.User_Fold
        for o in runner_of(c.h).orgs {
            for u in o.agent.user_list {
                if kai.user_device_active(u,device) {user=u}
            }
        }
        if user==nil {
            fail(c,403,"the device is no active device of a user this node knows")
            return
        }
        a.user,a.device,a.state=user.log.id,device,.Approved
    case .Entry,.Web_Key:
        bytes,ok:=base64_parse(b.entry,kai.ENTRY_BODY_MAX+4096)
        if !ok {
            fail(c,400,"entry is base64url of the signed entry")
            return
        }
        e,de:=kai.entry_decode(bytes)
        if de!=.None || e.sig_kind!=.Ed25519 {
            fail(c,400,"the entry does not read, or it is not signed by a device")
            return
        }
        expected_type,expected_log,expected_body:=a.type,a.log,a.body[:]
        if a.kind==.Web_Key {
            body,be:=kai.web_key_add_body(a.credential[:a.credential_len],a.cose[:a.cose_len],c.h.desc.rp_id)
            if be!=.None {
                fail(c,400,"the passkey does not make a Web_Key_Add")
                return
            }
            expected_type,expected_log,expected_body=.Web_Key_Add,a.user,body
        }
        if e.type!=expected_type || e.log_id!=expected_log || string(e.body)!=string(expected_body) {
            fail(c,400,"the entry is not the one the approval asks for")
            return
        }
        u:=user_fold_of(c.h,a.user)
        if u==nil || !kai.user_device_active(u,e.author) {
            fail(c,403,"the entry is not signed by an active device of the user")
            return
        }
        // The device tells its peers of the entry as it signs it: the node may hold it already.
        address,status,why:=entry_keep(c,bytes,a.user)
        if status==409 {
            address=store.address_of_bytes(bytes)
        } else if status!=0 {
            fail(c,status,why)
            return
        }
        a.address,a.device,a.state=address,e.author,.Approved
    }
    states:=APPROVAL_STATE_TEXT
    j:=json_make()
    json_object(&j)
    json_member_string(&j,"state",states[a.state])
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
route_approval_state :: proc(c:^Call) {
    a:=approval_find(c)
    if a==nil {return}
    Body :: struct {secret:string}
    b:Body
    if !body_parse(c,&b) {return}
    secret,ok:=base64_parse(b.secret,32)
    if !ok || len(secret)!=32 || crypto.compare_constant_time(secret,a.secret[:])!=1 {
        fail(c,403,"the secret is not this approval's")
        return
    }
    states:=APPROVAL_STATE_TEXT
    j:=json_make()
    json_object(&j)
    json_member_string(&j,"state",states[a.state])
    if a.state==.Approved && a.address!={} {json_member_hash(&j,"address",a.address)}
    json_end_object(&j)
    json_response(c,&j)
    if a.kind==.Login && a.state==.Approved && !a.taken {
        a.taken=true
        _,cookie:=session_new(c.h,a.user,{},nil,a.device)
        c.response.headers=cookie
    }
}
