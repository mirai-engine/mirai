package kai

import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/rsa"
import "core:encoding/base64"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"
import net "mirai:net"
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

// The org's entry a member signs the project's and proposals' entries under now.
@(private="file")
at :: proc(o:^Test_Org) -> store.Hash {return test_heads(&o.org)[0]}

@(private="file")
proposal_check_body_of :: proc(revision:Revision,name:string,state:Check_State) -> []u8 {
    body,_:=proposal_check_body(revision,name,state,{0=7})
    return body
}

// Saves l to s, as a peer that holds it does.
@(private="file")
machine_log_put :: proc(s:^store.Store,l:^Log) -> (store.Hash,Error) {return log_save(s,l)}

@(private="file")
expect_ok :: proc(t:^testing.T,_:store.Hash,e:Error,loc:=#caller_location) {
    testing.expect_value(t,e,Error.None,loc=loc)
}

// A scene driver that names an entity by a line "entity <key>": the anchor
// holds while the entity does. A file with no such line is not its own.
@(private="file")
scene_anchor :: proc(data:rawptr,from,to:[]u8,anchor:^Anchor) -> (moved,known:bool) {
    (^int)(data)^+=1
    if !strings.contains(string(to),"entity ") {return false,false}
    if anchor.kind!=.Structural {return true,true}
    needle:=fmt.tprintf("entity %d\n",anchor.key)
    return strings.contains(string(from),needle) && strings.contains(string(to),needle),true
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
    expect_ok(t,proposal_open(&l,o.project.id,"main","Five","adds five",bob,20,{},at(&o)))
    expect_ok(t,proposal_revise(&l,{{x,r1}},bob,21,{},at(&o)))
    shifted,e1:=proposal_comment(&l,{kind=.Lines,line=3,lines=1},"a.txt",x,{},"why three?",carol,22,{},at(&o))
    gone,e2:=proposal_comment(&l,{kind=.Lines,line=2,lines=1},"a.txt",x,shifted,"two goes",carol,22,{},at(&o))
    on_42,e3:=proposal_comment(&l,{kind=.Structural,key=42,field=1},"world.scene",x,{},"the door",carol,22,{},at(&o))
    on_7,e4:=proposal_comment(&l,{kind=.Structural,key=7,field=1},"world.scene",x,{},"the lamp",carol,22,{},at(&o))
    whole,e5:=proposal_comment(&l,{kind=.File},"a.txt",x,{},"the file",carol,22,{},at(&o))
    general,e6:=proposal_comment(&l,{kind=.File},"",{},{},"looks good",carol,22,{},at(&o))
    on_text,e7:=proposal_comment(&l,{kind=.Structural,key=7,field=1},"a.txt",x,{},"not a scene",carol,22,{},at(&o))
    testing.expect(t,e1==.None && e2==.None && e3==.None && e4==.None && e5==.None && e6==.None && e7==.None)
    expect_ok(t,proposal_verdict(&l,.Approve,r1,alice,23,{},at(&o)))

    f:Proposal_Fold
    defer proposal_fold_destroy(&f)
    review_fold(t,&s,&f,&l,&o.fold)
    testing.expect_value(t,f.approvals,1)
    testing.expect_value(t,f.comments,7)

    // A rewrite: two lines before, "two" deleted, entity 7 removed.
    A2,SCENE2::"zero\nhalf\none\nthree\nfour\nfive\n","entity 42\nentity 9\n"
    r2:=revision_of(t,&s,bob,x,base,{{"a.txt",A2},{"world.scene",SCENE2}})
    expect_ok(t,proposal_revise(&l,{{x,r2}},bob,30,{},at(&o)))
    review_fold(t,&s,&f,&l,&o.fold)
    testing.expect_value(t,f.revision,r2)
    testing.expect_value(t,f.approvals,0)

    calls:=0
    drivers:=[]Driver{{data=&calls,anchor=scene_anchor}}
    places:=make([dynamic]Comment_Place,context.temp_allocator)
    testing.expect_value(t,proposal_reanchor(&s,&f,drivers,&places),Error.None)
    testing.expect_value(t,len(places),7)
    p:=place_of(places[:],&l,shifted)
    testing.expect(t,!p.outdated && p.anchor.line==4 && p.path=="a.txt","a line moves with the lines inserted before it")
    testing.expect(t,place_of(places[:],&l,gone).outdated,"a deleted line is outdated")
    testing.expect(t,!place_of(places[:],&l,on_42).outdated,"an entity kept keeps its anchor")
    testing.expect(t,place_of(places[:],&l,on_7).outdated,"a removed entity is outdated")
    testing.expect(t,!place_of(places[:],&l,whole).outdated,"a file anchor stays while the file does")
    p=place_of(places[:],&l,general)
    testing.expect(t,!p.outdated && p.change=={},"a comment on the proposal hangs on no change")
    testing.expect(t,!place_of(places[:],&l,on_text).outdated,"a file no driver knows keeps its anchor")
    testing.expect_value(t,calls,3)

    // Approved again, then rebased onto a base that adds an unrelated file:
    // the edits are the same, so the approval carries over.
    expect_ok(t,proposal_verdict(&l,.Approve,r2,alice,31,{},at(&o)))
    base2:=revision_of(t,&s,bob,random_id(Change_Id),base,{{"a.txt",A0},{"b.txt","bee\n"},{"world.scene",SCENE0}})
    r3:=revision_of(t,&s,bob,x,base2,{{"a.txt",A2},{"b.txt","bee\n"},{"world.scene",SCENE2}})
    expect_ok(t,proposal_revise(&l,{{x,r3}},bob,40,{},at(&o)))
    review_fold(t,nil,&f,&l,&o.fold)
    testing.expect_value(t,f.approvals,0)
    testing.expect_value(t,proposal_settle(&s,&f),Error.None)
    testing.expect_value(t,f.approvals,1)
    testing.expect_value(t,proposal_reanchor(&s,&f,drivers,&places),Error.None)
    testing.expect_value(t,place_of(places[:],&l,shifted).anchor.line,4)

    // The same edit on another file breaks the carry-over.
    r4:=revision_of(t,&s,bob,x,base2,{{"a.txt",A2},{"b.txt","bees\n"},{"world.scene",SCENE2}})
    expect_ok(t,proposal_revise(&l,{{x,r4}},bob,50,{},at(&o)))
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
    _,e=proposal_open(&l,o.project.id,"main","again","",bob,60,{},at(&o))
    testing.expect_value(t,e,Error.Invalid_Argument)
}

// Landing asks for zero conflicts, the approvals and the passing checks of
// the target's policy on the final revision, checks by a signer with the
// Check right (a writer, or a runner under a grant), and every entry signed;
// then the move it writes holds for every peer that folds the project, and
// one to a conflicted revision does not, whatever approved it.
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
    expect_ok(t,proposal_open(&l,o.project.id,"main","Two","",bob,20,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Unrevised)
    expect_ok(t,proposal_revise(&l,{{x,rc}},bob,21,{},at(&o)))
    expect_ok(t,proposal_verdict(&l,.Approve,rc,alice,22,{},at(&o)))
    expect_ok(t,proposal_check(&l,rc,"ci",.Passed,{0=1},bob,22,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Conflicts)

    expect_ok(t,proposal_revise(&l,{{x,r1}},bob,30,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Approvals)
    expect_ok(t,proposal_verdict(&l,.Approve,r1,alice,31,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Checks)
    expect_ok(t,proposal_check(&l,r1,"ci",.Passed,{0=2},carol,32,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Checks)
    runner:=identity_make()
    before_grant:=at(&o)
    grant:=Grant{head={org=o.org.id,org_head=test_heads(&o.org)[0],issuer=alice.key,subject_key=runner.key,rights={.Check},project=o.project.id,not_before=0,not_after=1000}}
    grant_bytes,ge:=grant_encode(&grant,alice,context.temp_allocator)
    testing.expect_value(t,ge,Error.None)
    expect_ok(t,log_append(&o.org,.Grant,grant_bytes,alice,15))
    org_refold(t,&o)
    // A check under the grant counts only when signed under an org entry that holds the grant.
    expect_ok(t,log_append(&l,.Proposal_Check,proposal_check_body_of(r1,"ci",.Passed),&runner,32,{},before_grant))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Checks)
    expect_ok(t,log_append(&l,.Proposal_Check,proposal_check_body_of(r1,"ci",.Passed),&runner,32,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.None)
    expect_ok(t,proposal_check(&l,r1,"ci",.Failed,{0=3},bob,33,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Checks)
    expect_ok(t,proposal_check(&l,r1,"ci",.Passed,{0=4},bob,34,{},at(&o)))
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.None)

    // A copy of the log with a forged entry does not land.
    {
        forged_log:Log
        log_init(&forged_log,l.id);defer log_destroy(&forged_log)
        for item in l.items {log_add(&forged_log,item.bytes,false)}
        d:=Draft{type=.Proposal_Verdict,log_id=l.id,parents=test_heads(&l),org_ctx=at(&o),time=35,body=body_make(Proposal_Verdict_Body{verdict=.Approve,revision=r1})}
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
    pre_land:=slice.clone(test_heads(&l),context.temp_allocator)
    move,refusal,le:=proposal_land(&s,&f,&project,bob,40,{},at(&o))
    project_fold_destroy(&project)
    testing.expect(t,le==.None && refusal==.None,"the proposal lands")
    testing.expect_value(t,can_land(t,&s,&f,&l,&o),Land_Refusal.Not_Open)
    testing.expect_value(t,f.status,Proposal_Status.Landed)

    // Every peer folds the move as valid, whatever becomes of the proposal
    // after: revised, approved otherwise, reopened; a move around the
    // policy, and one to a conflicted revision that a proposal approved, as not.
    {
        // Concurrent with the landing, so they count in the proposal's fold.
        revise_body,_:=proposal_revise_body({{x,rc}})
        verdict_body,_:=proposal_verdict_body(.Changes,r1)
        expect_ok(t,log_append(&l,.Proposal_Revise,revise_body,bob,42,{},at(&o),pre_land))
        expect_ok(t,log_append(&l,.Proposal_Verdict,verdict_body,alice,43,{},at(&o),pre_land))
        expect_ok(t,machine_log_put(&s,&l))
        snaps:=make([dynamic]^Proposal_Fold,context.temp_allocator)
        testing.expect_value(t,project_snapshots(&s,&o.project,&o.fold,&snaps),Error.None)
        defer project_snapshots_destroy(&snaps)
        later:Project_Fold
        testing.expect_value(t,project_fold(&later,&o.project,&o.fold,snaps[:]),Error.None)
        defer project_fold_destroy(&later)
        testing.expect(t,later.valid[log_find(&o.project,move)],"a landed move stays when its proposal changes after")
    }
    l2:Log
    log_init(&l2);defer log_destroy(&l2)
    expect_ok(t,proposal_open(&l2,o.project.id,"main","Conflicted","",bob,41,{},at(&o)))
    expect_ok(t,proposal_revise(&l2,{{x,rc}},bob,42,{},at(&o)))
    expect_ok(t,proposal_verdict(&l2,.Approve,rc,alice,43,{},at(&o)))
    expect_ok(t,proposal_check(&l2,rc,"ci",.Passed,{0=6},bob,43,{},at(&o)))
    f2:Proposal_Fold
    defer proposal_fold_destroy(&f2)
    review_fold(t,&s,&f2,&l2,&o.fold)
    testing.expect(t,f2.conflicted && f2.approvals==1 && len(f2.checks)==1,"the conflicted stack is approved and checked")
    expect_ok(t,machine_log_put(&s,&l2))
    expect_ok(t,log_append(&o.project,.Bookmark_Move,move_body("main",{r1},rc),alice,44,{},at(&o)))
    expect_ok(t,log_append(&o.project,.Bookmark_Move,move_body("main",{r1},rc,l2.id,test_heads(&l2)),bob,45,{},at(&o)))
    proposals:=make([dynamic]^Proposal_Fold,context.temp_allocator)
    testing.expect_value(t,project_snapshots(&s,&o.project,&o.fold,&proposals),Error.None)
    defer project_snapshots_destroy(&proposals)
    testing.expect_value(t,project_fold(&project,&o.project,&o.fold,proposals[:]),Error.None)
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
    rs:rsa.Private_Key,
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
    case .RS256: _=rsa.private_key_generate(&p.rs,2048)
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
    case .RS256:
        n_len:=rsa.private_key_size(&p.rs)
        n:=make([]u8,n_len,context.temp_allocator)
        _=rsa.private_key_n(&p.rs,n)
        e_val:=rsa.private_key_e(&p.rs)
        e_buf:[4]u8={u8(e_val>>24),u8(e_val>>16),u8(e_val>>8),u8(e_val)}
        e:=e_buf[:]
        for len(e)>1 && e[0]==0 {e=e[1:]}
        // {1: 3, 3: -257, -1: n, -2: e}
        append(&out,0xa4,0x01,0x03,0x03,0x39,0x01,0x00,0x20)
        if len(n)<256 {append(&out,0x58,u8(len(n)))} else {append(&out,0x59,u8(len(n)>>8),u8(len(n)))}
        append(&out,..n)
        append(&out,0x21,u8(0x40|len(e)))
        append(&out,..e)
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
    case .RS256:
        signature=make([]u8,rsa.private_key_size(&p.rs),context.temp_allocator)
        _=rsa.sign_pkcs1(&p.rs,.SHA256,message,signature)
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
        Case :: struct {name:string,a:Web_Assertion,failure:Webauthn_Failure,write:bool}
        good:=passkey_assert(&p,RP,ORIGIN,challenge[:])
        tampered:=passkey_assert(&p,RP,ORIGIN,challenge[:])
        tampered.signature=slice.clone(tampered.signature,context.temp_allocator)
        tampered.signature[len(tampered.signature)-1]~=1
        short:=good
        write:=good // as a write keeps it: with the low S
        if alg==.ES256 {_,write.signature,_=es256_low_s(good.signature,context.temp_allocator)}
        short.authenticator_data=good.authenticator_data[:36]
        cases:=[]Case{
            {"login",good,.None,false},
            {"a write",write,.None,true},
            {"an origin with a port",passkey_assert(&p,RP,ORIGIN+":8443",challenge[:]),.None,false},
            {"an origin with a port that is no number",passkey_assert(&p,RP,ORIGIN+":84x3",challenge[:]),.Origin,false},
            {"an origin of a longer name",passkey_assert(&p,RP,ORIGIN+".evil.example",challenge[:]),.Origin,false},
            {"a login with the user present, not verified",passkey_assert(&p,RP,ORIGIN,challenge[:],0x01),.None,false},
            {"a write with the user present, not verified",passkey_assert(&p,RP,ORIGIN,challenge[:],0x01),.Verification,true},
            {"another challenge",passkey_assert(&p,RP,ORIGIN,other[:]),.Challenge,false},
            {"another origin",passkey_assert(&p,RP,"https://evil.example",challenge[:]),.Origin,false},
            {"plain http",passkey_assert(&p,RP,"http://kai.example",challenge[:]),.Origin,false},
            {"another relying party",passkey_assert(&p,"evil.example",ORIGIN,challenge[:]),.Rp_Id,false},
            {"no user present",passkey_assert(&p,RP,ORIGIN,challenge[:],0x04),.Presence,false},
            {"a registration",passkey_assert(&p,RP,ORIGIN,challenge[:],kind="webauthn.create"),.Type,false},
            {"a tampered signature",tampered,.Signature,false},
            {"short authenticator data",short,.Malformed,false},
            {"client data not JSON",{good.authenticator_data,transmute([]u8)string("{\"type\":"),good.signature},.Malformed,false},
        }
        for &c in cases {
            testing.expectf(t,webauthn_verify(&key,RP,challenge[:],&c.a,c.write)==c.failure,"%v %s: %v",alg,c.name,c.failure)
        }
        q:=passkey_make(alg)
        other_key,_:=cose_key_parse(passkey_cose(&q))
        testing.expect_value(t,webauthn_verify(&other_key,RP,challenge[:],&good,false),Webauthn_Failure.Signature)
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
    oc:=at(&o)
    l:Log
    log_init(&l);defer log_destroy(&l)
    expect_ok(t,proposal_open(&l,o.project.id,"main","Web","",bob,20,{},at(&o)))
    expect_ok(t,proposal_revise(&l,{{random_id(Change_Id),revision}},bob,21,{},at(&o)))

    web_key:=web_key_id(passkey_key,RP)
    browser_sign :: proc(t:^testing.T,l:^Log,p:^Passkey,cose:[]u8,web_key:Key,type:Entry_Type,body:[]u8,author_ctx,org_ctx:store.Hash,time:i64) -> []u8 {
        d:=Draft{type=type,log_id=l.id,parents=test_heads(l),author_ctx=author_ctx,org_ctx=org_ctx,time=time,body=body}
        unsigned,challenge,e:=entry_webauthn_begin(&d,web_key,context.temp_allocator)
        testing.expect_value(t,e,Error.None)
        a:=passkey_assert(p,RP,ORIGIN,challenge[:])
        bytes,_,fe:=entry_webauthn_finish(unsigned,cose,RP,&a,context.temp_allocator)
        testing.expect_value(t,fe,Error.None)
        return bytes
    }
    verdict_body,_:=proposal_verdict_body(.Approve,revision)
    verdict:=browser_sign(t,&l,&passkey,passkey_key,web_key,.Proposal_Verdict,verdict_body,ctx,oc,30)
    comment_body,_:=proposal_comment_body({kind=.File},"",{},{},"before the key")
    early:=browser_sign(t,&l,&passkey,passkey_key,web_key,.Proposal_Comment,comment_body,alice_genesis,oc,30)
    stranger:=passkey_make(.EdDSA)
    stranger_key:=passkey_cose(&stranger)
    unknown:=browser_sign(t,&l,&stranger,stranger_key,web_key_id(stranger_key,RP),.Proposal_Comment,comment_body,ctx,oc,30)

    // An RS256 passkey (Windows Hello) signs a 256-byte signature and encodes cleanly;
    // a 1024-bit RSA key is refused.
    {
        rs:=passkey_make(.RS256)
        rs_key:=passkey_cose(&rs)
        rs_entry:=browser_sign(t,&l,&rs,rs_key,web_key_id(rs_key,RP),.Proposal_Comment,comment_body,ctx,oc,30)
        decoded,de:=entry_decode(rs_entry)
        testing.expect(t,de==.None && entry_verify(rs_entry,&decoded),"an RS256-signed entry decodes and verifies")
        small:Passkey={alg=.RS256}
        _=rsa.private_key_generate(&small.rs,1024)
        _,small_ok:=cose_key_parse(passkey_cose(&small))
        testing.expect(t,!small_ok,"a 1024-bit RSA COSE key is refused")
    }

    {
        d:=Draft{type=.Proposal_Verdict,log_id=l.id,parents=test_heads(&l),author_ctx=ctx,org_ctx=oc,time=31,body=verdict_body}
        unsigned,_,_:=entry_webauthn_begin(&d,web_key,context.temp_allocator)
        replayed:=passkey_assert(&passkey,RP,ORIGIN,{1,2,3})
        _,_,e:=entry_webauthn_finish(unsigned,passkey_key,RP,&replayed,context.temp_allocator)
        testing.expect_value(t,e,Error.Unauthorized)
        _,_,e=entry_webauthn_finish(unsigned,stranger_key,RP,&replayed,context.temp_allocator)
        testing.expect_value(t,e,Error.Unauthorized)
    }

    // An ES256 signature verifies with s and with n-s: a write keeps only the low one, so
    // the two give one entry and one address.
    {
        d:=Draft{type=.Proposal_Comment,log_id=l.id,parents=test_heads(&l),author_ctx=ctx,org_ctx=oc,time=32,body=comment_body}
        unsigned,challenge,_:=entry_webauthn_begin(&d,web_key,context.temp_allocator)
        high:Web_Assertion
        for _ in 0..<64 {
            a:=passkey_assert(&passkey,RP,ORIGIN,challenge[:])
            if is_high,_,_:=es256_low_s(a.signature,context.temp_allocator);is_high {
                high=a
                break
            }
        }
        if testing.expect(t,high.signature!=nil,"a high S in 64 signatures") {
            low:=high
            _,low.signature,_=es256_low_s(high.signature,context.temp_allocator)
            key,_:=cose_key_parse(passkey_key)
            testing.expect_value(t,webauthn_verify(&key,RP,challenge[:],&high,false),Webauthn_Failure.None)
            testing.expect_value(t,webauthn_verify(&key,RP,challenge[:],&high,true),Webauthn_Failure.Signature)
            testing.expect_value(t,webauthn_verify(&key,RP,challenge[:],&low,true),Webauthn_Failure.None)
            _,from_high,he:=entry_webauthn_finish(unsigned,passkey_key,RP,&high,context.temp_allocator)
            _,from_low,le:=entry_webauthn_finish(unsigned,passkey_key,RP,&low,context.temp_allocator)
            testing.expect(t,he==.None && le==.None && from_high==from_low,"the two encodings of a signature make two entries")
        }
        unverified:=passkey_assert(&passkey,RP,ORIGIN,challenge[:],0x01)
        _,_,ue:=entry_webauthn_finish(unsigned,passkey_key,RP,&unverified,context.temp_allocator)
        testing.expect_value(t,ue,Error.Unauthorized)
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

    // Revoked, the passkey's verdict stands until a witness reaches the
    // proposal's log, and then as what came before it; what it signs after
    // counts nowhere.
    revoke,_:=log_append(&o.alice.log,.Device_Revoke,revoke_body(web_key),&o.alice.recovery,40)
    org_refold(t,&o)
    proposal_fold_destroy(&f)
    testing.expect_value(t,proposal_fold(&f,&peer,&o.fold),Error.None)
    testing.expect_value(t,f.approvals,1)
    expect_ok(t,log_append(&peer,.Witness,witness_body(o.alice.log.id,revoke),bob,41,{},at(&o)))
    withdraw_body,_:=proposal_verdict_body(.Withdraw,revision)
    late:=browser_sign(t,&peer,&passkey,passkey_key,web_key,.Proposal_Verdict,withdraw_body,ctx,oc,42)
    _,e:=log_add(&peer,late,true)
    testing.expect_value(t,e,Error.None)
    proposal_fold_destroy(&f)
    testing.expect_value(t,proposal_fold(&f,&peer,&o.fold),Error.None)
    testing.expect_value(t,f.approvals,1)
    testing.expect(t,!f.valid[log_find(&peer,store.address_of_bytes(late))],"a revoked passkey's entry after the witness counts nowhere")
}

// A check under a grant is judged by the grant's validity at the check's
// time, which is never before its causal past: an expired grant cannot sign
// one that counts by claiming an old time, a check counts for the revision of
// the last Revise in its causal past, and a revocation keeps the checks made
// before it reached the proposal and voids the later ones.
@(test)
a_grant_signs_checks_only_while_it_holds :: proc(t:^testing.T) {
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    alice,bob:=&o.alice.devices[0],&o.bob.devices[0]
    runner:=identity_make()
    grant_of :: proc(t:^testing.T,o:^Test_Org,issuer:^Identity,runner:Key,not_after:i64) -> []u8 {
        g:=Grant{head={org=o.org.id,org_head=test_heads(&o.org)[0],issuer=issuer.key,subject_key=runner,rights={.Check},project=o.project.id,not_before=0,not_after=not_after}}
        bytes,e:=grant_encode(&g,issuer,context.temp_allocator)
        testing.expect_value(t,e,Error.None)
        return bytes
    }
    expect_ok(t,log_append(&o.org,.Grant,grant_of(t,&o,alice,runner.key,50),alice,15))
    org_refold(t,&o)
    r1,r2:=Revision{0=1},Revision{0=2}
    x:=random_id(Change_Id)
    l:Log
    log_init(&l);defer log_destroy(&l)
    expect_ok(t,proposal_open(&l,o.project.id,"main","Checks","",bob,20,{},at(&o)))
    before_revise:=slice.clone(test_heads(&l),context.temp_allocator)
    expect_ok(t,proposal_revise(&l,{{x,r1}},bob,100,{},at(&o)))
    f:Proposal_Fold
    defer proposal_fold_destroy(&f)
    // Claimed at 10, it builds on a Revise at 100: past the grant's end at 50.
    stale,_:=log_append(&l,.Proposal_Check,proposal_check_body_of(r1,"ci",.Passed),&runner,10,{},at(&o))
    review_fold(t,nil,&f,&l,&o.fold)
    testing.expect(t,!f.valid[log_find(&l,stale)] && len(f.checks)==0,"an expired grant signs no check that counts")

    expect_ok(t,log_append(&o.org,.Grant,grant_of(t,&o,alice,runner.key,1000),alice,16))
    org_refold(t,&o)
    held,_:=log_append(&l,.Proposal_Check,proposal_check_body_of(r1,"ci",.Passed),&runner,110,{},at(&o))
    blind,_:=log_append(&l,.Proposal_Check,proposal_check_body_of(r1,"lint",.Passed),&runner,111,{},at(&o),before_revise)
    review_fold(t,nil,&f,&l,&o.fold)
    testing.expect(t,f.valid[log_find(&l,held)] && len(f.checks)==1 && f.checks[0].name=="ci","a check under the grant in force counts")
    testing.expect(t,f.valid[log_find(&l,blind)],"a check that saw no Revise is signed under the grant")

    // Revoked: the check before the witness stands, the one after it does not.
    grant:=o.fold.granted[len(o.fold.granted)-1]
    revoke,_:=log_append(&o.org,.Grant_Revoke,body_make(Subject_Body{subject=grant.address}),alice,17)
    org_refold(t,&o)
    review_fold(t,nil,&f,&l,&o.fold)
    testing.expect(t,f.valid[log_find(&l,held)],"a revocation not witnessed here keeps the log as it was")
    expect_ok(t,log_append(&l,.Witness,witness_body(o.org.id,revoke),bob,120,{},at(&o)))
    after,_:=log_append(&l,.Proposal_Check,proposal_check_body_of(r1,"ci",.Failed),&runner,121,{},test_heads(&o.org)[0])
    review_fold(t,nil,&f,&l,&o.fold)
    testing.expect(t,f.valid[log_find(&l,held)] && !f.valid[log_find(&l,after)],"what came before the witness stands; what came after does not")
    testing.expect(t,len(f.checks)==1 && f.checks[0].state==.Passed)
    expect_ok(t,proposal_revise(&l,{{x,r2}},bob,130,{},at(&o)))
    review_fold(t,nil,&f,&l,&o.fold)
    testing.expect_value(t,len(f.checks),0)
}

// A writer removed from the org keeps what it did: its moves of a shared
// bookmark and its approvals stand and main does not move back, while what it
// signs after the removal reached those logs, under an old org entry, counts
// nowhere. A member's agent that starts after the removal serves what main
// names to its peers and to anonymous readers.
@(test)
a_removed_writer_keeps_its_past :: proc(t:^testing.T) {
    s,ok:=review_store(t,"kai-removed-writer");if !ok {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    alice,bob:=&o.alice.devices[0],&o.bob.devices[0]
    old:=at(&o)
    work:=test_change(t,&s,bob,"bob's work")
    m1:=test_move(t,&o.project,"main",work,bob,old,20)
    l:Log
    log_init(&l);defer log_destroy(&l)
    expect_ok(t,proposal_open(&l,o.project.id,"main","Bob's","",alice,21,{},old))
    expect_ok(t,proposal_revise(&l,{{random_id(Change_Id),{0=2}}},alice,22,{},old))
    approval,_:=proposal_verdict(&l,.Approve,{0=2},bob,23,{},old)
    // A proposal bob never signed in.
    untouched:Log
    log_init(&untouched);defer log_destroy(&untouched)
    expect_ok(t,proposal_open(&untouched,o.project.id,"main","Alice's","",alice,24,{},old))

    removal,e:=log_append(&o.org,.Member_Remove,body_make(Subject_Body{subject=o.bob.log.id}),alice,30)
    testing.expect_value(t,e,Error.None)
    org_refold(t,&o)
    // The removal is due in every log bob held a right in, signed there or not.
    due:=make([dynamic]Witness_Due,context.temp_allocator)
    for log in ([]^Log{&o.project,&l,&untouched}) {
        clear(&due)
        testing.expect_value(t,witnesses_due(&o.fold,log,&due),Error.None)
        testing.expectf(t,len(due)==1 && due[0].removal==removal,"%v: the removal is due",log.kind)
    }
    test_witness(t,&o.project,o.org.id,removal,alice,at(&o),31)
    test_witness(t,&l,o.org.id,removal,alice,at(&o),32)
    test_witness(t,&untouched,o.org.id,removal,alice,at(&o),32)
    // A proposal opened after the removal needs no witness: every entry of it is judged with it.
    born_after:Log
    log_init(&born_after);defer log_destroy(&born_after)
    expect_ok(t,proposal_open(&born_after,o.project.id,"main","Later","",alice,35,{},at(&o)))
    clear(&due)
    testing.expect_value(t,witnesses_due(&o.fold,&born_after,&due),Error.None)
    testing.expect_value(t,len(due),0)

    // After the witness, bob signs under the org's entry from before his removal.
    m2:=test_move(t,&o.project,"main",{0=3},bob,old,33,nil,{work})
    late,_:=proposal_verdict(&l,.Changes,{0=2},bob,34,{},old)
    first_late,_:=proposal_comment(&untouched,{},"",{},{},"late",bob,36,{},old)
    born_late,_:=proposal_comment(&born_after,{},"",{},{},"late",bob,36,{},old)
    for c in ([]struct{log:^Log,entry:store.Hash}{{&untouched,first_late},{&born_after,born_late}}) {
        g:Proposal_Fold
        testing.expect_value(t,proposal_fold(&g,c.log,&o.fold),Error.None)
        testing.expect(t,!g.valid[log_find(c.log,c.entry)],"a removed writer's first entry in a log it never signed in does not stand")
        proposal_fold_destroy(&g)
    }

    p:Project_Fold
    testing.expect_value(t,project_fold(&p,&o.project,&o.fold),Error.None)
    defer project_fold_destroy(&p)
    targets:=make([dynamic]Revision,context.temp_allocator)
    project_bookmark(&p,"main",&targets)
    testing.expect(t,p.valid[log_find(&o.project,m1)] && !p.valid[log_find(&o.project,m2)],"the move before stands, the backdated one does not")
    testing.expect(t,len(targets)==1 && targets[0]==work,"main stays where bob moved it")
    f:Proposal_Fold
    defer proposal_fold_destroy(&f)
    testing.expect_value(t,proposal_fold(&f,&l,&o.fold),Error.None)
    testing.expect(t,f.valid[log_find(&l,approval)] && !f.valid[log_find(&l,late)],"the approval stands, the later verdict does not")
    testing.expect_value(t,f.approvals,1)

    for log in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {
        _,se:=log_save(&s,log)
        testing.expect_value(t,se,Error.None)
    }
    test_written(t,&s,o.project.id,work)
    sim:net.Sim_Network
    net.sim_network_init(&sim,{seed=3,endpoints=2,packets=64})
    defer net.sim_network_destroy(&sim)
    a:=new(Agent)
    defer free(a)
    testing.expect_value(t,agent_init(a,{store=&s,identity=o.alice.devices[0],dh=o.alice.dhs[0],user=o.alice.log.id,org=o.org.id,host_seed=7,server=net.sim_endpoint_transport(&sim,0)},{net.sim_endpoint_transport(&sim,1)}),Error.None)
    defer agent_close(a)
    testing.expect(t,work in a.members.chunks,"a member is served what main names after its writer left")
    testing.expect(t,closure_has(a.closure.public[:],work),"so is an anonymous reader")
}

// A landed move's verdict against its proposal at the heads the move names
// is kept: the project folds again without reading any proposal, the same
// after a restart, and the verdicts are found again when the kept set is gone.
@(test)
a_project_of_10000_landed_moves_folds_without_reading_its_proposals :: proc(t:^testing.T) {
    N :: 10_000
    s,ok:=review_store(t,"kai-landings");if !ok {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    alice,bob:=&o.alice.devices[0],&o.bob.devices[0]
    expect_ok(t,log_append(&o.org,.Policy_Set,body_make(Policy_Set_Body{project=o.project.id,approvals=1},strings_tail("main")),alice,14))
    org_refold(t,&o)
    started:=time.tick_now()
    logs:=make([]store.Hash,N,context.temp_allocator)
    ids:=make([]Log_Id,N,context.temp_allocator)
    from:Revision
    for i in 0..<N {
        id:=random_id(Change_Id)
        text:=fmt.tprintf("version %d\n",i)
        r:=revision_of(t,&s,bob,id,from,{{"a.txt",text}})
        l:Log
        log_init(&l)
        expect_ok(t,proposal_open(&l,o.project.id,"main",fmt.tprintf("Version %d",i),"",bob,20,{},at(&o)))
        expect_ok(t,proposal_revise(&l,{{id,r}},bob,21,{},at(&o)))
        expect_ok(t,proposal_verdict(&l,.Approve,r,alice,22,{},at(&o)))
        address,e:=machine_log_put(&s,&l)
        testing.expect_value(t,e,Error.None)
        logs[i],ids[i]=address,l.id
        expect_ok(t,log_append(&o.project,.Bookmark_Move,move_body("main",i==0?{}:{from},r,l.id,test_heads(&l)),bob,30,{},at(&o)))
        log_destroy(&l)
        from=r
    }
    built:=time.tick_since(started)
    fold :: proc(t:^testing.T,s:^store.Store,o:^Test_Org,want:Revision) -> (took:time.Duration,kept:int) {
        started:=time.tick_now()
        snaps:=make([dynamic]^Proposal_Fold)
        defer {project_snapshots_destroy(&snaps);delete(snaps)}
        testing.expect_value(t,project_snapshots(s,&o.project,&o.fold,&snaps),Error.None)
        f:Project_Fold
        testing.expect_value(t,project_fold(&f,&o.project,&o.fold,snaps[:]),Error.None)
        defer project_fold_destroy(&f)
        took=time.tick_since(started)
        targets:=make([dynamic]Revision,context.temp_allocator)
        project_bookmark(&f,"main",&targets)
        if want=={} {
            testing.expect(t,len(targets)==0,"no move holds")
        } else {
            testing.expect(t,len(targets)==1 && targets[0]==want,"main is at the last landed revision")
        }
        for pf in snaps {kept+=int(pf.kept)}
        testing.expect_value(t,landings_keep(s,&f),Error.None)
        return
    }
    cold,kept:=fold(t,&s,&o,from)
    testing.expect_value(t,kept,0)
    // Without any proposal's log in the store, every move still holds by its kept verdict.
    name:[64]u8
    for id in ids {testing.expect_value(t,store.ref_remove(&s,LOG_NAMESPACE,log_name(id,&name)),store.Error.None)}
    warm,kept_warm:=fold(t,&s,&o,from)
    testing.expect_value(t,kept_warm,N)
    // A kept verdict is for the policy it was judged on: another policy reads the proposals again.
    for id,i in ids {testing.expect_value(t,store.ref_set(&s,LOG_NAMESPACE,log_name(id,&name),logs[i]),store.Error.None)}
    testing.expect_value(t,store.ref_remove(&s,LANDINGS_NAMESPACE,log_name(o.project.id,&name)),store.Error.None)
    rebuilt,kept_rebuilt:=fold(t,&s,&o,from)
    testing.expect_value(t,kept_rebuilt,0)
    expect_ok(t,log_append(&o.org,.Policy_Set,body_make(Policy_Set_Body{project=o.project.id,approvals=2},strings_tail("main")),alice,15))
    org_refold(t,&o)
    _,kept_other:=fold(t,&s,&o,{})
    testing.expect_value(t,kept_other,0)
    fmt.printfln("kai: a project of %d landed moves: built in %v, folded reading every proposal in %v, with the kept verdicts in %v, again from the proposals in %v",N,built,cold,warm,rebuilt)

    // A verdict kept while the org's log lacked a removal is judged again once it comes: the
    // removal is valid and voids nothing in the org, but the snapshot's witness of it now leaves
    // out the removed member's approval, so the move no longer holds.
    p:Test_Org
    test_org_make(t,&p);defer test_org_destroy(&p)
    carol:=&p.carol.devices[0]
    bob=&p.bob.devices[0]
    expect_ok(t,log_append(&p.org,.Policy_Set,body_make(Policy_Set_Body{project=p.project.id,approvals=1},strings_tail("main")),&p.alice.devices[0],14))
    expect_ok(t,log_append(&p.org,.Role_Set,body_make(Member_Body{user=p.carol.log.id,role=.Writer}),&p.alice.devices[0],15))
    before:=at(&p)
    removal,re:=log_append(&p.org,.Member_Remove,body_make(Subject_Body{subject=p.carol.log.id}),&p.alice.devices[0],16)
    testing.expect_value(t,re,Error.None)
    org_refold(t,&p)
    lacking:Log
    log_init(&lacking);defer log_destroy(&lacking)
    for &item in p.org.items {
        if item.address!=removal {_,_=log_add(&lacking,item.bytes,false)}
    }
    behind:Org_Fold
    testing.expect_value(t,org_fold(&behind,&lacking,p.users[:]),Error.None)
    defer org_fold_destroy(&behind)
    id:=random_id(Change_Id)
    r:=revision_of(t,&s,bob,id,{},{{"b.txt","landed\n"}})
    l:Log
    log_init(&l);defer log_destroy(&l)
    expect_ok(t,proposal_open(&l,p.project.id,"main","Late","",bob,20,{},before))
    revised,ve:=proposal_revise(&l,{{id,r}},bob,21,{},before)
    testing.expect_value(t,ve,Error.None)
    approve,_:=proposal_verdict_body(.Approve,r)
    expect_ok(t,log_append(&l,.Proposal_Verdict,approve,carol,22,{},before,{revised}))
    expect_ok(t,log_append(&l,.Witness,witness_body(p.org.id,removal),bob,23,{},removal,{revised}))
    _,le:=machine_log_put(&s,&l)
    testing.expect_value(t,le,Error.None)
    expect_ok(t,log_append(&p.project,.Bookmark_Move,move_body("main",{},r,l.id,test_heads(&l)),bob,30,{},before))
    landed :: proc(t:^testing.T,s:^store.Store,project:^Log,org:^Org_Fold) -> (holds:bool,kept:int) {
        snaps:=make([dynamic]^Proposal_Fold)
        defer {project_snapshots_destroy(&snaps);delete(snaps)}
        testing.expect_value(t,project_snapshots(s,project,org,&snaps),Error.None)
        f:Project_Fold
        testing.expect_value(t,project_fold(&f,project,org,snaps[:]),Error.None)
        defer project_fold_destroy(&f)
        targets:=make([dynamic]Revision,context.temp_allocator)
        project_bookmark(&f,"main",&targets)
        for pf in snaps {kept+=int(pf.kept)}
        testing.expect_value(t,landings_keep(s,&f),Error.None)
        return len(targets)==1,kept
    }
    holds,kept_behind:=landed(t,&s,&p.project,&behind)
    testing.expect(t,holds && kept_behind==0,"without the removal the approval counts and the move holds")
    holds,kept_behind=landed(t,&s,&p.project,&behind)
    testing.expect(t,holds && kept_behind==1,"its verdict is kept")
    holds,kept_behind=landed(t,&s,&p.project,&p.fold)
    testing.expect(t,!holds && kept_behind==0,"once the removal comes the kept verdict is not read and the move does not hold")
}
