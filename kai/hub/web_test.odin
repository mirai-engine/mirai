package hub

import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:kai"
import "mirai:std/subprocess"
import "mirai:store"

// The pure modules of the frontend (web/blake3.js and web/entry.js) run
// under the system's node against what this side makes: BLAKE3 across chunk
// and tree boundaries, recovery texts, web key ids, the credential of an
// authenticator's data, a new user's first entries, the entry layout of
// GET /api/entries, and the server's draft of every write a browser makes,
// which the check takes, and tampered or mismatched drafts it refuses.
// Without node the run is reported skipped.
@(test)
hub_web_modules_agree_with_the_node :: proc(t:^testing.T) {
    state,version,_,ve:=subprocess.exec({command={"node","--version"}},context.temp_allocator)
    if ve!=nil || state.exit_code!=0 {
        log.warnf("SKIPPED: no node here to run the frontend's modules (%v)",ve)
        return
    }
    f:=new(Fixture)
    defer free(f)
    defer fixture_close(f)
    if !fixture_open(t,f,"kai-hub-web") {return}
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprint(&b,`{"blake3":[`)
    for n,i in ([?]int{0,1,63,64,65,1023,1024,1025,2048,2049,3072,3073,4096,4097,5120,5121,6144,6145,7168,7169,8192,8193,16384,31744,102400}) {
        input:=make([]u8,n,context.temp_allocator)
        for &x,k in input {x=u8(k%251)}
        fmt.sbprintf(&b,`%s{{"size":%d,"hash":"%s"}}`,i>0?",":"",n,hex_of(store.address_of_bytes(input)))
    }
    fmt.sbprint(&b,`],"recovery":[`)
    for k in 0..<4 {
        seed:[32]u8
        switch k {
        case 1: for &x in seed {x=255}
        case 2,3: seed=transmute([32]u8)kai.random_id(store.Hash)
        }
        buffer:[kai.RECOVERY_TEXT]u8
        fmt.sbprintf(&b,`%s{{"seed":"%s","text":"%s"}}`,k>0?",":"",hex(seed[:]),kai.recovery_encode(seed,&buffer))
    }

    // Passkeys of both kinds a node takes, and their authenticator data with and without extensions.
    p256:=passkey_make()
    ed:=make([dynamic]u8,context.temp_allocator)
    append(&ed,0xa4,0x01,0x01,0x03,0x27,0x20,0x06,0x21,0x58,0x20)
    for k in 0..<32 {append(&ed,u8(k*7+1))}
    coses:=[2][]u8{passkey_cose(&p256),ed[:]}
    fmt.sbprint(&b,`],"web_keys":[`)
    for cose,k in coses {
        id:=kai.web_key_id(cose,RP)
        fmt.sbprintf(&b,`%s{{"cose":"%s","rp":"%s","id":"%s"}}`,k>0?",":"",b64(cose),RP,hex(id[:]))
    }
    fmt.sbprint(&b,`],"attested":[`)
    for cose,k in coses {
        for extended in ([2]bool{false,true}) {
            data:=make([dynamic]u8,context.temp_allocator)
            for x in 0..<32 {append(&data,u8(x))}
            append(&data,extended?0xc5:0x45,0,0,0,7)
            for _ in 0..<16 {append(&data,0)}
            append(&data,0,u8(len(p256.credential)))
            append(&data,..p256.credential[:])
            append(&data,..cose)
            if extended {
                append(&data,0xa1,0x6b)
                append(&data,"credProtect")
                append(&data,0x02)
            }
            fmt.sbprintf(&b,`%s{{"name":"%d %v","data":"%s","credential":"%s","cose":"%s"}}`,k>0||extended?",":"",k,extended,b64(data[:]),b64(p256.credential[:]),b64(cose))
        }
    }

    // A new user's genesis and the Web_Key_Add of its passkey, as a browser signs them.
    recovery,device:kai.Identity
    recovery.seed=transmute([32]u8)kai.random_id(store.Hash)
    device.seed=transmute([32]u8)kai.random_id(store.Hash)
    kai.identity_derive(&recovery)
    kai.identity_derive(&device)
    dh:=kai.Dh_Key(kai.random_id(store.Hash))
    proof:=kai.device_proof(&device,transmute([32]u8)recovery.key)
    genesis_body:=kai.body_make(kai.User_Genesis_Body{recovery=recovery.key,device=device.key,dh=dh,proof=proof},transmute([]u8)string("bob ü"))
    now:=time.now()._nsec
    gd:=kai.Draft{type=.User_Genesis,time=now,body=genesis_body}
    genesis,user,_:=kai.entry_sign(&gd,&recovery,context.temp_allocator)
    wk,_:=kai.web_key_add_body(p256.credential[:],coses[0],RP)
    wd:=kai.Draft{type=.Web_Key_Add,log_id=user,parents={user},time=now+1,body=wk}
    add,_,_:=kai.entry_sign(&wd,&recovery,context.temp_allocator)
    fmt.sbprintf(&b,`],"user":{{"recovery_seed":"%s","device_seed":"%s","dh":"%s","proof":"%s","name":"bob ü","time":"%d",`,
        hex(recovery.seed[:]),hex(device.seed[:]),hex(dh[:]),hex(proof[:]),now)
    fmt.sbprintf(&b,`"genesis":"%s","log":"%s","web_key_add":"%s","credential":"%s","cose":"%s","rp":"%s"}},`,
        hex(genesis),hex_of(user),hex(add[:len(add)-size_of(kai.Signature)]),b64(p256.credential[:]),b64(coses[0]),RP)
    a:=call(f,"POST","/api/users",fmt.tprintf(`{{"entries":["%s","%s"]}}`,b64(genesis),b64(add)))
    if !testing.expectf(t,a.status==201,"the browser's user is kept: %d %s",a.status,a.body) {return}
    testing.expect_value(t,kai.machine_member_add(&f.alice,f.org,user,.Writer),kai.Error.None)
    cookie:=sign_in(t,f,&p256)
    entries:=call(f,"GET","/api/entries")
    fmt.sbprintf(&b,`"layout":%s,`,entries.body)

    // The server's draft of every write a browser makes.
    P,O:=hex_of(f.proposal),hex_of(f.org)
    change,r1,r3,me:=hex(f.change[:]),hex_of(f.r1),hex_of(f.r3),hex_of(user)
    actions:=[?]string{
        fmt.tprintf(`{{"type":"proposal_comment","log":"%s","text":"On the whole proposal"}}`,P),
        fmt.tprintf(`{{"type":"proposal_comment","log":"%s","text":"On a file","change":"%s","path":"src/a.txt","anchor":{{"kind":"file"}}}}`,P,change),
        fmt.tprintf(`{{"type":"proposal_comment","log":"%s","text":"On lines, ü","change":"%s","path":"src/a.txt","anchor":{{"kind":"lines","line":2,"lines":2}}}}`,P,change),
        fmt.tprintf(`{{"type":"proposal_comment","log":"%s","text":"A reply","reply_to":"%s"}}`,P,r1),
        fmt.tprintf(`{{"type":"proposal_verdict","log":"%s","verdict":"approve","revision":"%s"}}`,P,r3),
        fmt.tprintf(`{{"type":"proposal_verdict","log":"%s","verdict":"changes","revision":"%s"}}`,P,r3),
        fmt.tprintf(`{{"type":"proposal_verdict","log":"%s","verdict":"withdraw","revision":"%s"}}`,P,r3),
        fmt.tprintf(`{{"type":"proposal_close","log":"%s"}}`,P),
        fmt.tprintf(`{{"type":"proposal_reopen","log":"%s"}}`,P),
        fmt.tprintf(`{{"type":"member_add","log":"%s","user":"%s","role":"reader"}}`,O,me),
        fmt.tprintf(`{{"type":"role_set","log":"%s","user":"%s","role":"admin"}}`,O,me),
        fmt.tprintf(`{{"type":"member_remove","log":"%s","user":"%s"}}`,O,me),
    }
    // What the user asked otherwise than each draft says, by the draft it is checked against.
    Mismatch :: struct {draft:int,action:string}
    mismatches:=[?]Mismatch{
        {0,fmt.tprintf(`{{"type":"proposal_comment","log":"%s","text":"Other words"}}`,P)},
        {2,fmt.tprintf(`{{"type":"proposal_comment","log":"%s","text":"On lines, ü","change":"%s","path":"src/a.txt","anchor":{{"kind":"lines","line":3,"lines":2}}}}`,P,change)},
        {4,actions[5]},
        {4,fmt.tprintf(`{{"type":"proposal_verdict","log":"%s","verdict":"approve","revision":"%s"}}`,P,r1)},
        {7,actions[8]},
        {9,fmt.tprintf(`{{"type":"member_add","log":"%s","user":"%s","role":"writer"}}`,O,me)},
        {11,fmt.tprintf(`{{"type":"member_remove","log":"%s","user":"%s"}}`,O,P)},
        {1,fmt.tprintf(`{{"type":"proposal_comment","log":"%s","text":"On a file","change":"%s","path":"src/a.txt","anchor":{{"kind":"file"}}}}`,O,change)},
    }
    Draft_Answer :: struct {unsigned:string}
    drafts:[len(actions)][]u8
    fmt.sbprint(&b,`"drafts":[`)
    for action,i in actions {
        d:Draft_Answer
        if !json_read(t,call(f,"POST","/api/drafts",action,cookie),&d) {return}
        drafts[i]=unb64(d.unsigned)
        fmt.sbprintf(&b,`%s{{"action":%s,"unsigned":"%s"}}`,i>0?",":"",action,d.unsigned)
    }
    fmt.sbprint(&b,`],"refused":[`)
    first:=true
    refuse :: proc(b:^strings.Builder,first:^bool,name,action:string,bytes:[]u8) {
        fmt.sbprintf(b,`%s{{"name":"%s","action":%s,"unsigned":"%s"}}`,first^?"":",",name,action,b64(bytes))
        first^=false
    }
    for action,i in actions {
        u:=drafts[i]
        Tamper :: struct {name:string,at,value:int}
        for x in ([?]Tamper{{"the magic",0,'X'},{"the version",4,2},{"the type",6,int(kai.Entry_Type.Proposal_Land)},{"the log",8,-1},{"the author",40,-1},{"the author's context",72,0},{"the signature kind",116,0},{"a reserved byte",118,1}}) {
            bad:=make([]u8,len(u),context.temp_allocator)
            copy(bad,u)
            if x.name=="the author's context" {
                for &c in bad[72:104] {c=0}
            } else if x.value<0 {
                bad[x.at]~=1
            } else {
                bad[x.at]=u8(x.value)
            }
            refuse(&b,&first,fmt.tprintf("draft %d with %s changed",i,x.name),action,bad)
        }
        later:=make([]u8,len(u),context.temp_allocator)
        copy(later,u)
        stamp,_:=endian.get_i64(later[104:],.Little)
        endian.put_i64(later[104:],.Little,stamp+2*i64(time.Hour))
        refuse(&b,&first,fmt.tprintf("draft %d two hours late",i),action,later)
        orphan:=make([dynamic]u8,context.temp_allocator)
        append(&orphan,..u[:size_of(kai.Entry_Head)])
        orphan[7]=0
        append(&orphan,..u[size_of(kai.Entry_Head)+int(u[7])*size_of(store.Hash):])
        refuse(&b,&first,fmt.tprintf("draft %d without parents",i),action,orphan[:])
        longer:=make([dynamic]u8,context.temp_allocator)
        append(&longer,..u)
        append(&longer,0)
        refuse(&b,&first,fmt.tprintf("draft %d with a byte past its body",i),action,longer[:])
        length,_:=endian.get_u32(u[112:],.Little)
        endian.put_u32(longer[112:],.Little,length+1)
        refuse(&b,&first,fmt.tprintf("draft %d with a longer body",i),action,longer[:])
        if length>0 {
            flipped:=make([]u8,len(u),context.temp_allocator)
            copy(flipped,u)
            flipped[len(flipped)-1]~=1
            refuse(&b,&first,fmt.tprintf("draft %d with its body changed",i),action,flipped)
        }
    }
    for m,k in mismatches {refuse(&b,&first,fmt.tprintf("draft %d against mismatch %d",m.draft,k),m.action,drafts[m.draft])}
    web_key:=kai.web_key_id(coses[0],RP)
    fmt.sbprintf(&b,`],"author":"%s","now":"%d"}}`,hex(web_key[:]),time.now()._nsec)

    vectors:=fmt.tprintf("%s/vectors.json",f.folder)
    if !testing.expect(t,os.write_entire_file(vectors,transmute([]u8)strings.to_string(b))==nil) {return}
    script:=fmt.tprintf("%s/web_test.mjs",#directory)
    state2,out,errs,e:=subprocess.exec({command={"node",script,vectors}},context.temp_allocator)
    testing.expectf(t,e==nil && state2.exit_code==0,"the frontend's modules under node %s: %v\n%s%s",strings.trim_space(string(version)),e,out,errs)
}

@(private="file")
hex_of :: proc(h:store.Hash) -> string {
    x:=h
    return hex(x[:])
}
