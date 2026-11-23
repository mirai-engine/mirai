package hub

import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:kai"
import "mirai:std/blake3"
import "mirai:std/subprocess"
import "mirai:store"

// The pure modules of the frontend (web/blake3.js and web/entry.js) run
// under the system's node against what this side makes: BLAKE3 across chunk
// and tree boundaries, devices' link codes, web key ids, the credential of an
// authenticator's data, a new user's Passkey_Genesis, the constants of an
// entry, and the server's draft of every write a browser makes,
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

    // A new user's genesis, as a browser builds it for its passkey to sign, and the link codes of devices.
    now:=time.now()._nsec
    body:=kai.body_make(kai.Passkey_Genesis_Body{credential=u8(len(p256.credential)),cose=u16(len(coses[0])),rp=u8(len(RP))},p256.credential[:],coses[0],transmute([]u8)string(RP),transmute([]u8)string("bob ü"))
    gd:=kai.Draft{type=.Passkey_Genesis,time=now,body=body}
    unsigned,challenge,_:=kai.entry_webauthn_begin(&gd,kai.web_key_id(coses[0],RP),context.temp_allocator)
    fmt.sbprintf(&b,`],"user":{{"name":"bob ü","time":"%d","unsigned":"%s","credential":"%s","cose":"%s","rp":"%s"}},"codes":[`,now,hex(unsigned),b64(p256.credential[:]),b64(coses[0]),RP)
    for k in 0..<4 {
        device:=kai.Key(kai.random_id(store.Hash))
        code:[9]u8
        fmt.sbprintf(&b,`%s{{"device":"%s","code":"%s"}}`,k>0?",":"",hex(device[:]),kai.device_link_code(device,&code))
    }
    fmt.sbprint(&b,`],`)
    a:=call(f,"POST","/api/users",fmt.tprintf(`{{"unsigned":"%s","assertion":%s}}`,b64(unsigned),passkey_assert(&p256,challenge[:])))
    if !testing.expectf(t,a.status==201,"the browser's user is kept: %d %s",a.status,a.body) {return}
    Made :: struct {user:string}
    made:Made
    json_read(t,a,&made)
    user,_:=hash_parse(made.user)
    testing.expect_value(t,kai.machine_member_add(&f.alice,f.org,user,.Writer),kai.Error.None)
    f.now+=2
    f.hub.now=f.now
    waiting_step(&f.hub)
    cookie:=sign_in(t,f,&p256)
    // A machine it links sets its recovery key, and an admin it is may write the org's entries.
    linked:kai.Machine
    if !testing.expect_value(t,kai.machine_open(&linked,fmt.tprintf("%s/linked",f.folder)),kai.Error.None) {return}
    defer kai.machine_close(&linked)
    if !device_link(t,f,cookie,&p256,user,&linked) {return}
    testing.expect_value(t,kai.machine_role_set(&f.alice,f.org,user,.Admin),kai.Error.None)
    constants:=json_make()
    json_object(&constants)
    json_member_int(&constants,"MAGIC",i64(kai.KAI_MAGIC))
    json_member_int(&constants,"VERSION",i64(kai.VERSIONS[.Log_Page]))
    json_member_int(&constants,"HEAD",size_of(kai.Entry_Head))
    json_member_int(&constants,"PARENTS_MAX",kai.ENTRY_PARENTS_MAX)
    json_member_int(&constants,"BODY_MAX",kai.ENTRY_BODY_MAX)
    json_member_int(&constants,"KEM_PUBLIC",kai.KEM_PUBLIC)
    json_member_int(&constants,"NAME_MAX",kai.NAME_MAX)
    names :: proc(j:^Json,key:string,text:[$E]string) {
        json_key(j,key)
        json_object(j)
        for name,value in text {
            if name!="" {json_member_int(j,name,i64(value))}
        }
        json_end_object(j)
    }
    names(&constants,"TYPES",TYPE_TEXT)
    names(&constants,"ROLES",ROLE_TEXT)
    names(&constants,"VERDICTS",VERDICT_TEXT)
    names(&constants,"ANCHORS",ANCHOR_TEXT)
    json_key(&constants,"MODES")
    json_object(&constants)
    modes:=MODE_TEXT
    for name,mode in modes {json_member_int(&constants,name,i64(transmute(u8)kai.Node_Modes{mode}))}
    json_end_object(&constants)
    json_end_object(&constants)
    fmt.sbprintf(&b,`"constants":%s,`,json_text(&constants))

    // The server's draft of every write a browser makes.
    device_identity:=kai.identity_make()
    device_key,device_dh:=device_identity.key,kai.Dh_Key(kai.random_id(store.Hash))
    device_seed:=kai.random_id([kai.KEM_SEED]u8)
    device_kem,_:=kai.kem_public(&device_seed)
    device_proof:=kai.device_proof(&device_identity,transmute([32]u8)user,device_dh,blake3.hash(device_kem[:]))
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
        fmt.tprintf(`{{"type":"device_add","log":"%s","device":"%s","dh":"%s","kem":"%s","proof":"%s","name":"laptop"}}`,me,hex(device_key[:]),hex(device_dh[:]),b64(device_kem[:]),b64(device_proof[:])),
        fmt.tprintf(`{{"type":"org_genesis","owner":"%s","name":"studio ü"}}`,me),
        node_action(f,O,`"relay","seed"`),
        fmt.tprintf(`{{"type":"project_genesis","org":"%s","name":"game","public":true}}`,O),
        fmt.tprintf(`{{"type":"project_add","log":"%s","project":"%s","public":false}}`,O,r1),
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
        {12,fmt.tprintf(`{{"type":"device_add","log":"%s","device":"%s","dh":"%s","kem":"%s","proof":"%s","name":"phone"}}`,me,hex(device_key[:]),hex(device_dh[:]),b64(device_kem[:]),b64(device_proof[:]))},
        {13,fmt.tprintf(`{{"type":"org_genesis","owner":"%s","name":"another"}}`,me)},
        {13,fmt.tprintf(`{{"type":"org_genesis","owner":"%s","name":"studio ü"}}`,O)},
        {14,node_action(f,O,`"relay"`)},
        {15,fmt.tprintf(`{{"type":"project_genesis","org":"%s","name":"game","public":false}}`,O)},
        {16,fmt.tprintf(`{{"type":"project_add","log":"%s","project":"%s","public":true}}`,O,r1)},
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
        for x in ([?]Tamper{{"the magic",0,'X'},{"the version",4,9},{"the type",6,int(kai.Entry_Type.Proposal_Land)},{"the log",8,-1},{"the author",40,-1},{"the author's context",72,0},{"the org's context",104,0},{"the signature kind",148,0},{"a reserved byte",150,1}}) {
            bad:=make([]u8,len(u),context.temp_allocator)
            copy(bad,u)
            if x.name=="the author's context" {
                for &c in bad[72:104] {c=0}
            } else if x.name=="the org's context" {
                // Zero where it must name an org entry, an entry where none belongs.
                zeroed:=true
                for c in bad[104:136] {zeroed&&=c==0}
                for &c,k in bad[104:136] {c=zeroed?u8(k+1):0}
            } else if x.value<0 {
                bad[x.at]~=1
            } else {
                bad[x.at]=u8(x.value)
            }
            refuse(&b,&first,fmt.tprintf("draft %d with %s changed",i,x.name),action,bad)
        }
        later:=make([]u8,len(u),context.temp_allocator)
        copy(later,u)
        stamp,_:=endian.get_i64(later[136:],.Little)
        endian.put_i64(later[136:],.Little,stamp+2*i64(time.Hour))
        refuse(&b,&first,fmt.tprintf("draft %d two hours late",i),action,later)
        orphan:=make([dynamic]u8,context.temp_allocator)
        append(&orphan,..u[:size_of(kai.Entry_Head)])
        orphan[7]=0
        append(&orphan,..u[size_of(kai.Entry_Head)+int(u[7])*size_of(store.Hash):])
        if u[7]>0 {refuse(&b,&first,fmt.tprintf("draft %d without parents",i),action,orphan[:])}
        longer:=make([dynamic]u8,context.temp_allocator)
        append(&longer,..u)
        append(&longer,0)
        refuse(&b,&first,fmt.tprintf("draft %d with a byte past its body",i),action,longer[:])
        length,_:=endian.get_u32(u[144:],.Little)
        endian.put_u32(longer[144:],.Little,length+1)
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
    fmt.sbprintf(&b,`],"author":"%s","now":"%d",`,hex(web_key[:]),time.now()._nsec)

    // The previews of assets as peers publish them, and records the node refuses.
    previews:=json_make()
    json_object(&previews)
    json_key(&previews,"summaries")
    json_array(&previews)
    Summary :: struct {kind:string,facts:[]kai.Preview_Fact}
    for x in ([?]Summary{
        {"scene",{{"Entities","2"},{"Top entities","Swimmer, Sun ü"}}},
        {"mesh",{{"Vertices","788"},{"Extent","0.986 × 1 × 0.986 m"},{"Cut","a\tb\nc"}}},
        {"records",{}},
    }) {
        record,_:=kai.preview_summary_encode(x.kind,x.facts,context.temp_allocator)
        facts:=make([dynamic]kai.Preview_Fact,context.temp_allocator)
        kind,_:=kai.preview_summary_decode(record,&facts)
        json_object(&previews)
        json_member_string(&previews,"text",string(record))
        json_member_string(&previews,"kind",kind)
        json_key(&previews,"facts")
        json_array(&previews)
        for f in facts {
            json_array(&previews)
            json_string(&previews,f.label)
            json_string(&previews,f.value)
            json_end_array(&previews)
        }
        json_end_array(&previews)
        json_end_object(&previews)
    }
    json_end_array(&previews)
    rows:=[]kai.Preview_Row{{'~',"Lamp","Transform[@0x20].value.position[0]: 0 -> 5"},{'+',"","Light"},{'-',"Sun ü",""}}
    detail,_:=kai.preview_detail_encode(&kai.Preview_Detail{added=1,removed=1,changed=1,cut=7,rows=rows},context.temp_allocator)
    json_member_string(&previews,"detail",string(detail))
    json_key(&previews,"refused")
    json_array(&previews)
    for text in ([?]string{
        "", "kai-summary 2\nmesh\n", "kai-summary 1\nmesh", "kai-summary 1\nmesh\nno tab\n", "kai-summary 1\nmesh\na\tb\tc\n",
        "kai-summary 1\nmesh\na\tb\x01\n", "kai-detail 1\n1\t2\t3\n", "kai-detail 1\n0\t0\t0\t0\n*\tname\ttext\n",
        strings.concatenate({"kai-summary 1\nmesh\n",strings.repeat("a\tb\n",kai.PREVIEW_FACTS_MAX+1,context.temp_allocator)},context.temp_allocator),
        strings.concatenate({"kai-summary 1\nmesh\na\t",strings.repeat("ü",kai.PREVIEW_VALUE_MAX/2+1,context.temp_allocator),"\n"},context.temp_allocator),
    }) {
        kind:=strings.has_prefix(text,"kai-detail")?kai.Preview_Kind.Detail:.Summary
        testing.expectf(t,kai.preview_check(kind,transmute([]u8)text)!=.None,"the node refuses %q",text)
        json_object(&previews)
        json_member_string(&previews,"kind",kind==.Detail?"detail":"summary")
        json_member_string(&previews,"text",text)
        json_end_object(&previews)
    }
    json_end_array(&previews)
    json_end_object(&previews)
    fmt.sbprintf(&b,`"previews":%s}}`,json_text(&previews))

    vectors:=fmt.tprintf("%s/vectors.json",f.folder)
    if !testing.expect(t,os.write_entire_file(vectors,transmute([]u8)strings.to_string(b))==nil) {return}
    script:=fmt.tprintf("%s/web_test.mjs",#directory)
    state2,out,errs,e:=subprocess.exec({command={"node",script,vectors}},context.temp_allocator)
    testing.expectf(t,e==nil && state2.exit_code==0,"the frontend's modules under node %s: %v\n%s%s",strings.trim_space(string(version)),e,out,errs)
}

// The node_add of this node to org, with modes, as the page builds it from GET /api/node.
@(private="file")
node_action :: proc(f:^Fixture,org,modes:string) -> string {
    r:=runner_of(&f.hub)
    key,dh:=r.machine.identity.key,r.machine.dh.public
    b:=strings.builder_make(context.temp_allocator)
    for a,i in node_addresses(&f.hub) {
        ip:=a.ip
        fmt.sbprintf(&b,`%s{{"kind":%d,"port":%d,"ip":"%s"}}`,i>0?",":"",a.kind,a.port,hex(ip[:]))
    }
    return fmt.tprintf(`{{"type":"node_add","log":"%s","node":"%s","dh":"%s","modes":[%s],"addresses":[%s]}}`,org,hex(key[:]),hex(dh[:]),modes,strings.to_string(b))
}

@(private="file")
hex_of :: proc(h:store.Hash) -> string {
    x:=h
    return hex(x[:])
}
