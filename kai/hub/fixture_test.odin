package hub

import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:kai"
import mnet "mirai:net"
import "mirai:std/base"
import "mirai:store"

// A node with an org of a public and a private project, and the browsers,
// machines and passkeys that talk to it.

RP :: "kai.test"
ORIGIN :: "https://kai.test"
PRIVATE_MARKER :: "PRIVATE-MARKER-7f3a"
SCOPED_MARKER :: "SCOPED-MARKER-91c2"
WIP_MARKER :: "WIP-MARKER-5d0e"

Fixture :: struct {
    folder:string,
    alice:kai.Machine,   // the org's owner; the node the hub runs on
    second:kai.Machine,  // a second device of alice, which approves
    peer:kai.Machine,    // a machine that folds what the hub kept
    open:[3]bool,
    runner:kai.Runner,
    running:bool,
    hub:Hub,
    serving:bool,
    now:f64,
    org,public,private:kai.Log_Id,
    r1,r2,r3,rq:kai.Revision,  // r2 and r3 are two revisions of change
    rw:kai.Revision,           // work in progress over r3 that only a device ref names
    change:kai.Change_Id,
    proposal:kai.Log_Id,
}

@(private="file")
Text :: struct {path,text:string}

@(private="file")
revision_make :: proc(t:^testing.T,m:^kai.Machine,id:kai.Change_Id,parent:kai.Revision,files:[]Text,written:i64,description:string) -> kai.Revision {
    s:=&m.store
    sorted:=slice.clone(files,context.temp_allocator)
    slice.sort_by(sorted,proc(a,b:Text) -> bool {return a.path<b.path})
    list:=make([dynamic]kai.File,context.temp_allocator)
    for f in sorted {
        address,e:=store.put(s,transmute([]u8)f.text)
        testing.expect_value(t,e,store.Error.None)
        append(&list,kai.File{path=f.path,kind=.File,address=address,size=u64(len(f.text))})
    }
    root,te:=kai.tree_build(s,list[:])
    testing.expect_value(t,te,kai.Error.None)
    parents:=[]kai.Revision{parent}
    c:=kai.Change{id=id,tree=root,author=m.identity.key,created=1,written=written,parents=parent=={}?nil:parents,description=description}
    revision,ce:=kai.change_put(s,&c,&m.identity)
    testing.expect_value(t,ce,kai.Error.None)
    testing.expect_value(t,store.commit(s),store.Error.None)
    return revision
}

@(private="file")
log_copy :: proc(t:^testing.T,from,to:^store.Store,id:kai.Log_Id,kind:kai.Log_Kind) {
    l:kai.Log
    kai.log_init(&l,id,context.temp_allocator)
    testing.expect_value(t,kai.log_open(from,&l,id,kind),kai.Error.None)
    _,e:=kai.log_save(to,&l)
    testing.expect_value(t,e,kai.Error.None)
    testing.expect_value(t,store.commit(to),store.Error.None)
}

user_head :: proc(m:^kai.Machine) -> store.Hash {
    l:kai.Log
    kai.log_init(&l,m.user,context.temp_allocator)
    kai.log_open(&m.store,&l,m.user,.User)
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    kai.log_heads(&l,&heads)
    return len(heads)>0?heads[0]:{}
}

// The store of a node: alice's org with its projects, a scope, a proposal
// revised twice and a second device of alice's.
fixture_store :: proc(t:^testing.T,f:^Fixture,folder:string) -> bool {
    f.folder=folder
    for name,k in ([3]string{"alice","second","peer"}) {
        m:=k==0?&f.alice:k==1?&f.second:&f.peer
        if !testing.expect_value(t,kai.machine_open(m,fmt.tprintf("%s/%s",folder,name)),kai.Error.None) {return false}
        f.open[k]=true
    }
    a:=&f.alice
    buffer:[kai.RECOVERY_TEXT]u8
    _,ue:=kai.machine_user_create(a,"alice",&buffer)
    testing.expect_value(t,ue,kai.Error.None)
    e:kai.Error
    f.org,e=kai.machine_org_create(a,"studio")
    testing.expect_value(t,e,kai.Error.None)
    f.public,e=kai.machine_project_add(a,f.org,kai.random_id(kai.Repo_Id),"site",true)
    testing.expect_value(t,e,kai.Error.None)
    f.private,e=kai.machine_project_add(a,f.org,kai.random_id(kai.Repo_Id),"vault",false)
    testing.expect_value(t,e,kai.Error.None)
    _,e=kai.machine_scope_add(a,f.org,f.public,{"secrets/**"},.Writer,false)
    testing.expect_value(t,e,kai.Error.None)

    // A public tree that holds a scoped path, as if a snapshot had let it
    // through: the hub must still leave it out.
    f.r1=revision_make(t,a,kai.random_id(kai.Change_Id),{},{
        {"README.md","# Site\nWelcome to the site.\n"},
        {"bin.dat","\x00\x01\x02\x00binary"},
        {"secrets/key.txt",SCOPED_MARKER},
        {"src/a.txt","one\ntwo\n"},
    },10,"First files")
    f.change=kai.random_id(kai.Change_Id)
    f.r2=revision_make(t,a,f.change,f.r1,{
        {"README.md","# Site\nWelcome to the site.\n"},{"bin.dat","\x00\x01\x02\x00binary"},{"secrets/key.txt",SCOPED_MARKER},
        {"src/a.txt","one\nTWO\nthree\n"},
    },20,"Change a")
    f.r3=revision_make(t,a,f.change,f.r1,{
        {"README.md","# Site\nWelcome to the site.\n"},{"bin.dat","\x00\x01\x02\x00binary"},{"secrets/key.txt",SCOPED_MARKER},
        {"docs/b.md","notes\n"},{"src/a.txt","one\ntwo\nthree\n"},
    },30,"Change a, rewritten")
    f.rq=revision_make(t,a,kai.random_id(kai.Change_Id),{},{{"secret.txt",PRIVATE_MARKER}},40,"Vault")
    f.rw=revision_make(t,a,kai.random_id(kai.Change_Id),f.r3,{{"README.md","# Site\nWelcome to the site.\n"},{"wip.txt",WIP_MARKER}},45,"Half done")
    testing.expect_value(t,kai.machine_bookmark_move(a,f.public,"main",f.r3),kai.Error.None)
    testing.expect_value(t,kai.machine_publish_refs(a,f.public,{{"main",f.r3},{"wip",f.rw}}),kai.Error.None)
    testing.expect_value(t,kai.machine_publish_refs(a,f.private,{{"main",f.rq}}),kai.Error.None)

    ctx:=user_head(a)
    oc:store.Hash
    {
        o:kai.Org_State
        testing.expect_value(t,kai.org_state_load(&a.store,f.org,&o,context.temp_allocator),kai.Error.None)
        oc=kai.org_context(&o.fold,a.user)
        kai.org_state_destroy(&o)
    }
    l:kai.Log
    kai.log_init(&l,{},context.temp_allocator)
    _,e=kai.proposal_open(&l,f.public,"main","Rewrite a","Two takes of a.",&a.identity,50,ctx,oc)
    testing.expect_value(t,e,kai.Error.None)
    _,e=kai.proposal_revise(&l,{{f.change,f.r2}},&a.identity,51,ctx,oc)
    testing.expect_value(t,e,kai.Error.None)
    _,e=kai.proposal_revise(&l,{{f.change,f.r3}},&a.identity,52,ctx,oc)
    testing.expect_value(t,e,kai.Error.None)
    _,e=kai.log_save(&a.store,&l)
    testing.expect_value(t,e,kai.Error.None)
    f.proposal=l.id

    // alice's second device, which approves for browsers without a passkey.
    s:=&f.second
    u:kai.Log
    kai.log_init(&u,a.user,context.temp_allocator)
    testing.expect_value(t,kai.log_open(&a.store,&u,a.user,.User),kai.Error.None)
    body:=kai.body_make(kai.Device_Add_Body{device=s.identity.key,dh=kai.Dh_Key(s.dh.public),proof=kai.device_proof(&s.identity,transmute([32]u8)a.user)},transmute([]u8)string("laptop"))
    _,e=kai.log_append(&u,.Device_Add,body,&a.identity,60)
    testing.expect_value(t,e,kai.Error.None)
    _,e=kai.log_save(&a.store,&u)
    testing.expect_value(t,e,kai.Error.None)
    testing.expect_value(t,store.commit(&a.store),store.Error.None)
    Copy :: struct {id:kai.Log_Id,kind:kai.Log_Kind}
    for c in ([?]Copy{{a.user,.User},{f.org,.Org},{f.proposal,.Proposal}}) {log_copy(t,&a.store,&s.store,c.id,c.kind)}
    testing.expect_value(t,kai.machine_user_set(s,a.user),kai.Error.None)
    testing.expect_value(t,kai.machine_org_join(s,f.org),kai.Error.None)
    return true
}

fixture_clock :: proc(data:rawptr) -> f64 {return (^f64)(data)^}

// The store, a runner of alice's on loopback and a hub on loopback HTTP.
fixture_open :: proc(t:^testing.T,f:^Fixture,name:string) -> bool {
    folder:=base.test_folder(t,name)
    if folder=="" || !fixture_store(t,f,folder) {return false}
    e:=kai.runner_start(&f.runner,{machine=&f.alice,bind=mnet.address_loopback(0),modes={.Relay,.Seed},observe_port=0,beacon_port=-1,host_seed=7})
    if !testing.expect_value(t,e,kai.Error.None) {return false}
    f.running=true
    f.now=1
    why:=hub_start(&f.hub,{runner=&f.runner,rp_id=RP,http_port=-1,clock={&f.now,fixture_clock}})
    if !testing.expectf(t,why=="","the hub starts: %s",why) {return false}
    f.serving=true
    return true
}

fixture_close :: proc(f:^Fixture) {
    if f.serving {hub_stop(&f.hub)}
    if f.running {kai.runner_stop(&f.runner)}
    if f.open[0] {kai.machine_close(&f.alice)}
    if f.open[1] {kai.machine_close(&f.second)}
    if f.open[2] {kai.machine_close(&f.peer)}
}

Answer :: struct {status:int,body:string,content_type:string,headers:string,cookie:string}

// One request as a browser sends it, answered by the hub's routes; from
// address when one is given.
call :: proc(f:^Fixture,method,path:string,body:="",cookie:="",address:=[16]u8{}) -> Answer {
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%s %s HTTP/1.1\r\nHost: %s\r\n",method,path,RP)
    if cookie!="" {fmt.sbprintf(&b,"Cookie: %s\r\n",cookie)}
    if method=="POST" {fmt.sbprintf(&b,"Content-Type: application/json\r\nContent-Length: %d\r\n",len(body))}
    fmt.sbprintf(&b,"\r\n%s",body)
    p:=request_parse(b.buf[:])
    if p.status!=200 {return {status=p.status}}
    f.hub.now=f.now
    conn:^Conn
    if address!={} {
        conn=new(Conn,context.temp_allocator)
        conn.address=address
    }
    r:=dispatch(&f.hub,conn,&p.request)
    a:=Answer{status=r.status,body=string(r.body),content_type=r.content_type,headers=r.headers}
    if at:=strings.index(r.headers,COOKIE+"=");at>=0 {
        rest:=r.headers[at:]
        a.cookie=rest[:strings.index_byte(rest,';')]
    }
    return a
}

hex :: proc(bytes:[]u8) -> string {
    j:=json_make()
    json_hex(&j,bytes)
    text:=json_text(&j)
    return text[1:len(text)-1]
}

b64 :: proc(bytes:[]u8) -> string {
    text,_:=base64.encode(bytes,base64.ENC_URL_TABLE,context.temp_allocator,{.No_Padding})
    return text
}

unb64 :: proc(text:string) -> []u8 {
    bytes,_:=base64_parse(text,1<<20)
    return bytes
}

json_read :: proc(t:^testing.T,a:Answer,out:^$T,loc:=#caller_location) -> bool {
    e:=json.unmarshal(transmute([]u8)a.body,out,.JSON,context.temp_allocator)
    return testing.expectf(t,e==nil,"the answer reads as JSON: %v %s",e,a.body,loc=loc)
}

// A passkey of the test browser: P-256, as most authenticators make.
Test_Passkey :: struct {
    key:ecdsa.Private_Key,
    credential:[16]u8,
}

passkey_make :: proc() -> (p:Test_Passkey) {
    _=ecdsa.private_key_generate(&p.key,.SECP256R1)
    p.credential=transmute([16]u8)kai.random_id(kai.Change_Id)
    return
}

passkey_cose :: proc(p:^Test_Passkey) -> []u8 {
    out:=make([dynamic]u8,context.temp_allocator)
    public:[65]u8
    ecdsa.private_key_public_bytes(&p.key,public[:])
    append(&out,0xa5,0x01,0x02,0x03,0x26,0x20,0x01,0x21,0x58,0x20)
    append(&out,..public[1:33])
    append(&out,0x22,0x58,0x20)
    append(&out,..public[33:])
    return out[:]
}

// The JSON of an assertion of challenge, as a browser on origin gives it.
passkey_assert :: proc(p:^Test_Passkey,challenge:[]u8,origin:=ORIGIN,rp:=RP) -> string {
    client:=fmt.tprintf(`{{"type":"webauthn.get","challenge":"%s","origin":"%s","crossOrigin":false}}`,b64(challenge),origin)
    data:=make([]u8,37,context.temp_allocator)
    hash.hash_string_to_buffer(.SHA256,rp,data[:32])
    data[32]=0x05
    data[36]=1
    message:=make([]u8,37+32,context.temp_allocator)
    copy(message,data)
    hash.hash_string_to_buffer(.SHA256,client,message[37:])
    signature,_:=ecdsa.sign_asn1(&p.key,.SHA256,message,context.temp_allocator)
    return fmt.tprintf(`{{"credential":"%s","authenticator_data":"%s","client_data_json":"%s","signature":"%s"}}`,b64(p.credential[:]),b64(data),b64(transmute([]u8)client),b64(signature))
}

// The same assertion with its signature's last byte changed: in the bytes,
// since a base64 character can differ only in bits the decoding drops.
passkey_forge :: proc(assertion:string) -> string {
    at:=strings.index(assertion,`"signature":"`)+len(`"signature":"`)
    end:=strings.index_byte(assertion[at:],'"')+at
    signature:=slice.clone(unb64(assertion[at:end]),context.temp_allocator)
    signature[len(signature)-1]~=1
    return strings.concatenate({assertion[:at],b64(signature),assertion[end:]},context.temp_allocator)
}

// Signs in with p: the session's cookie, or "".
sign_in :: proc(t:^testing.T,f:^Fixture,p:^Test_Passkey,loc:=#caller_location) -> string {
    a:=call(f,"POST","/api/session/challenge")
    Challenge_Answer :: struct {challenge:string}
    ch:Challenge_Answer
    if !json_read(t,a,&ch,loc) {return ""}
    answer:=call(f,"POST","/api/session",fmt.tprintf(`{{"challenge":"%s","assertion":%s}}`,ch.challenge,passkey_assert(p,unb64(ch.challenge))))
    testing.expectf(t,answer.status==200 && answer.cookie!="","the passkey signs in: %d %s",answer.status,answer.body,loc=loc)
    return answer.cookie
}
