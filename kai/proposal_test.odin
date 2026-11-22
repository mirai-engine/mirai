package kai

import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:store"

@(private="file")
Text_File :: struct {path,text:string}

@(private="file")
review_store :: proc(t:^testing.T,name:string) -> (s:store.Store,ok:bool) {
    folder:=base.test_folder(t,name)
    if folder=="" {return}
    e:store.Error
    s,e=store.open(strings.concatenate({folder,"/store"},context.temp_allocator))
    return s,testing.expect_value(t,e,store.Error.None)
}

// A committed revision of change id over parent with files, sorted by path.
@(private="file")
revision_of :: proc(t:^testing.T,s:^store.Store,author:^Identity,id:Change_Id,parent:Revision,files:[]Text_File,loc:=#caller_location) -> Revision {
    list:=make([dynamic]File,context.temp_allocator)
    for f in files {
        address,e:=store.put(s,transmute([]u8)f.text)
        testing.expect_value(t,e,store.Error.None,loc=loc)
        append(&list,File{path=f.path,kind=.File,address=address,size=u64(len(f.text))})
    }
    root,te:=tree_build(s,list[:])
    testing.expect_value(t,te,Error.None,loc=loc)
    return revision_with(t,s,author,id,parent,root,loc)
}

@(private="file")
revision_with :: proc(t:^testing.T,s:^store.Store,author:^Identity,id:Change_Id,parent:Revision,root:store.Hash,loc:=#caller_location) -> Revision {
    parents:=[]Revision{parent}
    c:=Change{id=id,tree=root,author=author.key,created=1,written=2,parents=parent=={}?nil:parents,description="work"}
    revision,ce:=change_put(s,&c,author)
    testing.expect_value(t,ce,Error.None,loc=loc)
    testing.expect_value(t,store.commit(s),store.Error.None,loc=loc)
    return revision
}

// The fold of the proposal l, settled.
@(private="file")
review_fold :: proc(t:^testing.T,s:^store.Store,f:^Proposal_Fold,l:^Log,org:^Org_Fold,loc:=#caller_location) {
    proposal_fold_destroy(f)
    testing.expect_value(t,proposal_fold(f,l,org),Error.None,loc=loc)
    if s!=nil {testing.expect_value(t,proposal_settle(s,f),Error.None,loc=loc)}
}

@(private="file")
org_refold :: proc(t:^testing.T,o:^Test_Org) {
    org_fold_destroy(&o.fold)
    test_users_destroy(o.folds[:])
    test_users_fold(t,{&o.alice,&o.bob,&o.carol},o.folds[:],o.users[:])
    testing.expect_value(t,org_fold(&o.fold,&o.org,o.users[:]),Error.None)
}

@(private="file")
expect_ok :: proc(t:^testing.T,_:store.Hash,e:Error,loc:=#caller_location) {
    testing.expect_value(t,e,Error.None,loc=loc)
}

// A scene driver that names an entity by a line "entity <key>": the anchor
// holds while the entity does.
@(private="file")
scene_anchor :: proc(data:rawptr,from,to:[]u8,anchor:^Anchor) -> bool {
    (^int)(data)^+=1
    if anchor.kind!=.Structural {return true}
    needle:=fmt.tprintf("entity %d\n",anchor.key)
    return strings.contains(string(from),needle) && strings.contains(string(to),needle)
}

@(private="file")
place_of :: proc(places:[]Comment_Place,l:^Log,address:store.Hash) -> Comment_Place {
    k:=log_find(l,address)
    for p in places {
        if int(p.entry)==k {return p}
    }
    return {entry=max(u32),outdated=true}
}

// Comments follow their change across rewrites: lines move by the line diff
// and go outdated when deleted, structural anchors go through the driver, and
// an approval carries over a rebase that changes no edit, never a rewrite.
@(test)
proposal_comments_reanchor_across_rewrites :: proc(t:^testing.T) {
    s,ok:=review_store(t,"kai-proposal-reanchor");if !ok {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    alice,bob,carol:=&o.alice.devices[0],&o.bob.devices[0],&o.carol.devices[0]

    A0,SCENE0::"one\ntwo\nthree\nfour\n","entity 7\nentity 42\n"
    base:=revision_of(t,&s,bob,random_id(Change_Id),{},{{"a.txt",A0},{"world.scene",SCENE0}})
    x:=random_id(Change_Id)
    r1:=revision_of(t,&s,bob,x,base,{{"a.txt","one\ntwo\nthree\nfour\nfive\n"},{"world.scene","entity 7\nentity 42\nentity 9\n"}})

    l:Log
    log_init(&l);defer log_destroy(&l)
    expect_ok(t,proposal_open(&l,o.project.id,"main","Five","adds five",bob,20))
    expect_ok(t,proposal_revise(&l,{{x,r1}},bob,21))
    shifted,e1:=proposal_comment(&l,{kind=.Lines,line=3,lines=1},"a.txt",x,{},"why three?",carol,22)
    gone,e2:=proposal_comment(&l,{kind=.Lines,line=2,lines=1},"a.txt",x,shifted,"two goes",carol,22)
    on_42,e3:=proposal_comment(&l,{kind=.Structural,key=42,field=1},"world.scene",x,{},"the door",carol,22)
    on_7,e4:=proposal_comment(&l,{kind=.Structural,key=7,field=1},"world.scene",x,{},"the lamp",carol,22)
    whole,e5:=proposal_comment(&l,{kind=.File},"a.txt",x,{},"the file",carol,22)
    general,e6:=proposal_comment(&l,{kind=.File},"",{},{},"looks good",carol,22)
    testing.expect(t,e1==.None && e2==.None && e3==.None && e4==.None && e5==.None && e6==.None)
    expect_ok(t,proposal_verdict(&l,.Approve,r1,alice,23))

    f:Proposal_Fold
    defer proposal_fold_destroy(&f)
    review_fold(t,&s,&f,&l,&o.fold)
    testing.expect_value(t,f.approvals,1)
    testing.expect_value(t,f.comments,6)

    // A rewrite: two lines before, "two" deleted, entity 7 removed.
    A2,SCENE2::"zero\nhalf\none\nthree\nfour\nfive\n","entity 42\nentity 9\n"
    r2:=revision_of(t,&s,bob,x,base,{{"a.txt",A2},{"world.scene",SCENE2}})
    expect_ok(t,proposal_revise(&l,{{x,r2}},bob,30))
    review_fold(t,&s,&f,&l,&o.fold)
    testing.expect_value(t,f.revision,r2)
    testing.expect_value(t,f.approvals,0)

    calls:=0
    drivers:=[]Driver{{id=7,version=1,data=&calls,anchor=scene_anchor}}
    places:=make([dynamic]Comment_Place,context.temp_allocator)
    testing.expect_value(t,proposal_reanchor(&s,&f,drivers,&places),Error.None)
    testing.expect_value(t,len(places),6)
    p:=place_of(places[:],&l,shifted)
    testing.expect(t,!p.outdated && p.anchor.line==4 && p.path=="a.txt","a line moves with the lines inserted before it")
    testing.expect(t,place_of(places[:],&l,gone).outdated,"a deleted line is outdated")
    testing.expect(t,!place_of(places[:],&l,on_42).outdated,"an entity kept keeps its anchor")
    testing.expect(t,place_of(places[:],&l,on_7).outdated,"a removed entity is outdated")
    testing.expect(t,!place_of(places[:],&l,whole).outdated,"a file anchor stays while the file does")
    p=place_of(places[:],&l,general)
    testing.expect(t,!p.outdated && p.change=={},"a comment on the proposal hangs on no change")
    testing.expect_value(t,calls,2)

    // Approved again, then rebased onto a base that adds an unrelated file:
    // the edits are the same, so the approval carries over.
    expect_ok(t,proposal_verdict(&l,.Approve,r2,alice,31))
    base2:=revision_of(t,&s,bob,random_id(Change_Id),base,{{"a.txt",A0},{"b.txt","bee\n"},{"world.scene",SCENE0}})
    r3:=revision_of(t,&s,bob,x,base2,{{"a.txt",A2},{"b.txt","bee\n"},{"world.scene",SCENE2}})
    expect_ok(t,proposal_revise(&l,{{x,r3}},bob,40))
    review_fold(t,nil,&f,&l,&o.fold)
    testing.expect_value(t,f.approvals,0)
    testing.expect_value(t,proposal_settle(&s,&f),Error.None)
    testing.expect_value(t,f.approvals,1)
    testing.expect_value(t,proposal_reanchor(&s,&f,drivers,&places),Error.None)
    testing.expect_value(t,place_of(places[:],&l,shifted).anchor.line,4)

    // The same edit on another file breaks the carry-over.
    r4:=revision_of(t,&s,bob,x,base2,{{"a.txt",A2},{"b.txt","bees\n"},{"world.scene",SCENE2}})
    expect_ok(t,proposal_revise(&l,{{x,r4}},bob,50))
    review_fold(t,&s,&f,&l,&o.fold)
    testing.expect_value(t,f.approvals,0)

    // Hostile arguments are refused before anything is signed.
    y:=random_id(Change_Id)
    _,e:=proposal_revise_body({})
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_revise_body({{x,r1},{x,r2}})
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_revise_body({{y,{}}})
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_comment_body({kind=.Lines},"a.txt",x,{},"")
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_comment_body({kind=.File},"../a.txt",x,{},"")
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_comment_body({kind=Anchor_Kind(9)},"a.txt",x,{},"")
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_verdict_body(.Approve,{})
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_check_body(r1,"",.Passed,{})
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_open_body(o.project.id,"","t","")
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=proposal_open(&l,o.project.id,"main","again","",bob,60)
    testing.expect_value(t,e,Error.Invalid_Argument)
}

// Landing asks for zero conflicts, the approvals and the passing checks of
// the target's policy on the final revision, checks by a signer with the
// Check right, and every entry signed; then the move it writes holds for
// every peer that folds the project.
@(test)
landing_enforces_policy_and_zero_conflicts :: proc(t:^testing.T) {
    s,ok:=review_store(t,"kai-proposal-land");if !ok {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    alice,bob,carol:=&o.alice.devices[0],&o.bob.devices[0],&o.carol.devices[0]
    expect_ok(t,log_append(&o.org,.Policy_Set,body_make(Policy_Set_Body{project=o.project.id,approvals=1,checks=1},strings_tail("main","ci")),alice,14))
    org_refold(t,&o)

    base:=revision_of(t,&s,bob,random_id(Change_Id),{},{{"a.txt","one\n"}})
    ours:=revision_of(t,&s,bob,random_id(Change_Id),base,{{"a.txt","two\n"}})
    theirs:=revision_of(t,&s,bob,random_id(Change_Id),base,{{"a.txt","three\n"}})
    tree:=proc(s:^store.Store,r:Revision) -> store.Hash {
        c,_:=change_get(s,r,context.temp_allocator)
        return c.tree
    }
    m:=Merger{s=&s}
    conflicted,me:=tree_merge3(&m,tree(&s,base),tree(&s,ours),tree(&s,theirs))
    testing.expect_value(t,me,Error.None)
    x:=random_id(Change_Id)
    rc:=revision_with(t,&s,bob,x,base,conflicted)
    r1:=revision_of(t,&s,bob,x,base,{{"a.txt","two\n"}})

    l:Log
    log_init(&l);defer log_destroy(&l)
    f:Proposal_Fold
    defer proposal_fold_destroy(&f)
    can_land :: proc(t:^testing.T,s:^store.Store,f:^Proposal_Fold,l:^Log,o:^Test_Org) -> Land_Refusal {
        review_fold(t,s,f,l,&o.fold)
        refusal,e:=proposal_can_land(s,f)
        testing.expect_value(t,e,Error.None)
        return refusal
    }
    expect_ok(t,proposal_open(&l,o.project.id,"main","Two","",bob,20))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Unrevised)
    expect_ok(t,proposal_revise(&l,{{x,rc}},bob,21))
    expect_ok(t,proposal_verdict(&l,.Approve,rc,alice,22))
    expect_ok(t,proposal_check(&l,rc,"ci",.Passed,{0=1},bob,22))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Conflicts)

    expect_ok(t,proposal_revise(&l,{{x,r1}},bob,30))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Approvals)
    expect_ok(t,proposal_verdict(&l,.Approve,r1,alice,31))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Checks)
    expect_ok(t,proposal_check(&l,r1,"ci",.Passed,{0=2},carol,32))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Checks)
    expect_ok(t,proposal_check(&l,r1,"ci",.Failed,{0=3},bob,33))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Checks)
    expect_ok(t,proposal_check(&l,r1,"ci",.Passed,{0=4},bob,34))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.None)

    // A copy of the log with a forged entry does not land.
    {
        forged_log:Log
        log_init(&forged_log,l.id);defer log_destroy(&forged_log)
        for item in l.items {log_add(&forged_log,item.bytes,false)}
        d:=Draft{type=.Proposal_Verdict,log_id=l.id,parents=test_heads(&l),time=35,body=body_make(Proposal_Verdict_Body{verdict=.Approve,revision=r1})}
        forged,_,_:=entry_sign(&d,carol,context.temp_allocator)
        forged[len(forged)-1]~=1
        _,e:=log_add(&forged_log,forged,false)
        testing.expect_value(t,e,Error.None)
        g:Proposal_Fold
        defer proposal_fold_destroy(&g)
        testing.expect_value(t,can_land(t,&s,&g,&forged_log,&o),Land_Refusal.Unverified)
    }

    project:Project_Fold
    testing.expect_value(t,project_fold(&project,&o.project,&o.fold),Error.None)
    move,refusal,le:=proposal_land(&s,&f,&project,bob,40)
    project_fold_destroy(&project)
    testing.expect(t,le==.None && refusal==.None,"the proposal lands")
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Not_Open)
    testing.expect_value(t,f.status,Proposal_Status.Landed)

    // Every peer folds the move as valid, and a move around the policy as not.
    proposals:=[]^Proposal_Fold{&f}
    expect_ok(t,log_append(&o.project,.Bookmark_Move,body_make(Bookmark_Move_Body{to=rc,from=1},slice.to_bytes([]Revision{r1}),transmute([]u8)string("main")),alice,41))
    testing.expect_value(t,project_fold(&project,&o.project,&o.fold,proposals),Error.None)
    defer project_fold_destroy(&project)
    targets:=make([dynamic]Revision,context.temp_allocator)
    project_bookmark(&project,"main",&targets)
    testing.expect(t,len(targets)==1 && targets[0]==r1,"main is at the landed revision")
    testing.expect(t,project.valid[log_find(&o.project,move)],"the landing move holds")
}

// A passkey of the test browser.
@(private="file")
Passkey :: struct {
    alg:Cose_Alg,
    ed:ed25519.Private_Key,
    ec:ecdsa.Private_Key,
}

@(private="file")
passkey_make :: proc(alg:Cose_Alg) -> (p:Passkey) {
    p.alg=alg
    switch alg {
    case .EdDSA:
        seed:[32]u8
        _=rand.read(seed[:])
        _=ed25519.private_key_set_bytes(&p.ed,seed[:])
    case .ES256: _=ecdsa.private_key_generate(&p.ec,.SECP256R1)
    }
    return
}

// The COSE key of p, as a browser's attestation carries it.
@(private="file")
passkey_cose :: proc(p:^Passkey) -> []u8 {
    out:=make([dynamic]u8,context.temp_allocator)
    switch p.alg {
    case .EdDSA:
        public:[32]u8
        ed25519.private_key_public_bytes(&p.ed,public[:])
        append(&out,0xa4,0x01,0x01,0x03,0x27,0x20,0x06,0x21,0x58,0x20)
        append(&out,..public[:])
    case .ES256:
        public:[65]u8
        ecdsa.private_key_public_bytes(&p.ec,public[:])
        append(&out,0xa5,0x01,0x02,0x03,0x26,0x20,0x01,0x21,0x58,0x20)
        append(&out,..public[1:33])
        append(&out,0x22,0x58,0x20)
        append(&out,..public[33:])
    }
    return out[:]
}

// What a browser on origin gives for challenge, its authenticator holding
// the passkey for rp_id.
@(private="file")
passkey_assert :: proc(p:^Passkey,rp_id,origin:string,challenge:[]u8,flags:u8=0x05,kind:="webauthn.get") -> Web_Assertion {
    encoded,_:=base64.encode(challenge,base64.ENC_URL_TABLE,context.temp_allocator,{.No_Padding})
    client:=fmt.tprintf(`{{"type":"%s","challenge":"%s","origin":"%s","crossOrigin":false}}`,kind,encoded,origin)
    data:=make([]u8,37,context.temp_allocator)
    hash.hash_string_to_buffer(.SHA256,rp_id,data[:32])
    data[32]=flags
    data[36]=1
    message:=make([]u8,37+32,context.temp_allocator)
    copy(message,data)
    hash.hash_string_to_buffer(.SHA256,client,message[37:])
    signature:[]u8
    switch p.alg {
    case .EdDSA:
        signature=make([]u8,64,context.temp_allocator)
        ed25519.sign(&p.ed,message,signature)
    case .ES256: signature,_=ecdsa.sign_asn1(&p.ec,.SHA256,message,context.temp_allocator)
    }
    return {data,transmute([]u8)client,signature}
}

// A login and a browser-signed verdict verify on any peer, offline, for an
// Ed25519 and a P-256 passkey; a wrong challenge, origin, relying party,
// presence or signature is refused, as are hostile keys and entries.
@(test)
webauthn_login_and_signed_verdict_verify_offline :: proc(t:^testing.T) {
    RP :: "kai.example"
    ORIGIN :: "https://kai.example"
    for alg in Cose_Alg {
        p:=passkey_make(alg)
        cose:=passkey_cose(&p)
        key,parsed:=cose_key_parse(cose)
        testing.expectf(t,parsed && key.alg==alg,"%v: the COSE key reads",alg)

        challenge:[32]u8
        _=rand.read(challenge[:])
        other:=challenge
        other[0]~=1
        Case :: struct {name:string,a:Web_Assertion,failure:Webauthn_Failure}
        good:=passkey_assert(&p,RP,ORIGIN,challenge[:])
        tampered:=passkey_assert(&p,RP,ORIGIN,challenge[:])
        tampered.signature=slice.clone(tampered.signature,context.temp_allocator)
        tampered.signature[len(tampered.signature)-1]~=1
        short:=good
        short.authenticator_data=good.authenticator_data[:36]
        cases:=[]Case{
            {"login",good,.None},
            {"another challenge",passkey_assert(&p,RP,ORIGIN,other[:]),.Challenge},
            {"another origin",passkey_assert(&p,RP,"https://evil.example",challenge[:]),.Origin},
            {"plain http",passkey_assert(&p,RP,"http://kai.example",challenge[:]),.Origin},
            {"another relying party",passkey_assert(&p,"evil.example",ORIGIN,challenge[:]),.Rp_Id},
            {"no user present",passkey_assert(&p,RP,ORIGIN,challenge[:],0x04),.Presence},
            {"a registration",passkey_assert(&p,RP,ORIGIN,challenge[:],kind="webauthn.create"),.Type},
            {"a tampered signature",tampered,.Signature},
            {"short authenticator data",short,.Malformed},
            {"client data not JSON",{good.authenticator_data,transmute([]u8)string("{\"type\":"),good.signature},.Malformed},
        }
        for &c in cases {
            testing.expectf(t,webauthn_verify(&key,RP,challenge[:],&c.a)==c.failure,"%v %s: %v",alg,c.name,c.failure)
        }
        q:=passkey_make(alg)
        other_key,_:=cose_key_parse(passkey_cose(&q))
        testing.expect_value(t,webauthn_verify(&other_key,RP,challenge[:],&good),Webauthn_Failure.Signature)
    }

    // Hostile COSE keys: random bytes, every truncation, a wrong algorithm.
    p:=passkey_make(.ES256)
    cose:=passkey_cose(&p)
    for n in 0..<len(cose) {
        _,parsed:=cose_key_parse(cose[:n])
        testing.expectf(t,!parsed,"a COSE key cut at %d is refused",n)
    }
    wrong:=slice.clone(cose,context.temp_allocator)
    wrong[4]=0x27
    _,parsed:=cose_key_parse(wrong)
    testing.expect(t,!parsed,"EC2 with EdDSA's algorithm is refused")
    noise:[96]u8
    for _ in 0..<256 {
        _=rand.read(noise[:])
        cose_key_parse(noise[:rand.int_max(len(noise))])
    }

    // A verdict signed in the browser verifies on a peer with the logs alone.
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    alice_genesis:=o.alice.log.id
    passkey:=passkey_make(.ES256)
    passkey_key:=passkey_cose(&passkey)
    body,be:=web_key_add_body({1,2,3},passkey_key,RP)
    testing.expect_value(t,be,Error.None)
    ctx,ce:=log_append(&o.alice.log,.Web_Key_Add,body,&o.alice.devices[0],5)
    testing.expect_value(t,ce,Error.None)
    _,be=web_key_add_body({1},wrong,RP)
    testing.expect_value(t,be,Error.Invalid_Argument)
    org_refold(t,&o)

    bob:=&o.bob.devices[0]
    revision:=Revision{0=9}
    l:Log
    log_init(&l);defer log_destroy(&l)
    expect_ok(t,proposal_open(&l,o.project.id,"main","Web","",bob,20))
    expect_ok(t,proposal_revise(&l,{{random_id(Change_Id),revision}},bob,21))

    web_key:=web_key_id(passkey_key,RP)
    browser_sign :: proc(t:^testing.T,l:^Log,p:^Passkey,cose:[]u8,web_key:Key,type:Entry_Type,body:[]u8,author_ctx:store.Hash,time:i64) -> []u8 {
        d:=Draft{type=type,log_id=l.id,parents=test_heads(l),author_ctx=author_ctx,time=time,body=body}
        unsigned,challenge,e:=entry_webauthn_begin(&d,web_key,context.temp_allocator)
        testing.expect_value(t,e,Error.None)
        a:=passkey_assert(p,RP,ORIGIN,challenge[:])
        bytes,_,fe:=entry_webauthn_finish(unsigned,cose,RP,&a,context.temp_allocator)
        testing.expect_value(t,fe,Error.None)
        return bytes
    }
    verdict_body,_:=proposal_verdict_body(.Approve,revision)
    verdict:=browser_sign(t,&l,&passkey,passkey_key,web_key,.Proposal_Verdict,verdict_body,ctx,30)
    comment_body,_:=proposal_comment_body({kind=.File},"",{},{},"before the key")
    early:=browser_sign(t,&l,&passkey,passkey_key,web_key,.Proposal_Comment,comment_body,alice_genesis,30)
    stranger:=passkey_make(.EdDSA)
    stranger_key:=passkey_cose(&stranger)
    unknown:=browser_sign(t,&l,&stranger,stranger_key,web_key_id(stranger_key,RP),.Proposal_Comment,comment_body,ctx,30)

    {
        d:=Draft{type=.Proposal_Verdict,log_id=l.id,parents=test_heads(&l),author_ctx=ctx,time=31,body=verdict_body}
        unsigned,_,_:=entry_webauthn_begin(&d,web_key,context.temp_allocator)
        replayed:=passkey_assert(&passkey,RP,ORIGIN,{1,2,3})
        _,_,e:=entry_webauthn_finish(unsigned,passkey_key,RP,&replayed,context.temp_allocator)
        testing.expect_value(t,e,Error.Unauthorized)
        _,_,e=entry_webauthn_finish(unsigned,stranger_key,RP,&replayed,context.temp_allocator)
        testing.expect_value(t,e,Error.Unauthorized)
    }

    peer:Log
    log_init(&peer,l.id);defer log_destroy(&peer)
    for item in l.items {
        _,e:=log_add(&peer,item.bytes,true)
        testing.expect_value(t,e,Error.None)
    }
    for bytes in ([][]u8{verdict,early,unknown}) {
        _,e:=log_add(&peer,bytes,true)
        testing.expect_value(t,e,Error.None)
    }
    for k in 0..<len(verdict) {
        forged:=slice.clone(verdict,context.temp_allocator)
        forged[k]~=0x10
        added,e:=log_add(&peer,forged,true)
        testing.expectf(t,!added && e!=.None,"a verdict with byte %d changed is refused",k)
    }
    f:Proposal_Fold
    defer proposal_fold_destroy(&f)
    testing.expect_value(t,proposal_fold(&f,&peer,&o.fold),Error.None)
    testing.expect_value(t,f.approvals,1)
    testing.expect(t,f.valid[log_find(&peer,store.address_of_bytes(verdict))],"the browser's verdict is alice's")
    testing.expect(t,!f.valid[log_find(&peer,store.address_of_bytes(early))],"an author_ctx before the key was added does not count")
    testing.expect(t,!f.valid[log_find(&peer,store.address_of_bytes(unknown))],"a passkey no user added does not count")

    // Revoked with no horizon in the proposal's log, the passkey's verdict stops counting.
    expect_ok(t,log_append(&o.alice.log,.Device_Revoke,revoke_body(web_key,{}),&o.alice.recovery,40))
    org_refold(t,&o)
    proposal_fold_destroy(&f)
    testing.expect_value(t,proposal_fold(&f,&peer,&o.fold),Error.None)
    testing.expect_value(t,f.approvals,0)
}
