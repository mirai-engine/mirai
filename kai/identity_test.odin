package kai

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import net "mirai:net"
import "mirai:std/base"
import "mirai:std/blake3"
import "mirai:store"

// A user of the tests: a recovery key, devices with their X25519 keys, and
// the User_Log.
@(private)
Test_User :: struct {
    recovery:Identity,
    devices:[4]Identity,
    dhs:[4]net.Dh_Key,
    kems:[4][KEM_SEED]u8,
    count:int,
    log:Log,
}

@(private)
test_user :: proc(t:^testing.T,u:^Test_User,name:string,loc:=#caller_location) {
    u^={recovery=identity_make()}
    log_init(&u.log,{},context.allocator)
    u.devices[0]=identity_make()
    u.dhs[0],_=net.dh_key()
    u.kems[0]=random_id([KEM_SEED]u8)
    u.count=1
    kem,_:=kem_public(&u.kems[0])
    body:=body_make(User_Genesis_Body{recovery=u.recovery.key,device=u.devices[0].key,dh=Dh_Key(u.dhs[0].public),kem=kem,proof=device_proof(&u.devices[0],transmute([32]u8)u.recovery.key,Dh_Key(u.dhs[0].public),blake3.hash(kem[:]))},transmute([]u8)name)
    _,e:=log_append(&u.log,.User_Genesis,body,&u.recovery,1)
    testing.expect_value(t,e,Error.None,loc=loc)
}

// Adds a device, linked by the first.
@(private)
test_device :: proc(t:^testing.T,u:^Test_User,loc:=#caller_location) -> int {
    k:=u.count
    u.devices[k]=identity_make()
    u.dhs[k],_=net.dh_key()
    u.kems[k]=random_id([KEM_SEED]u8)
    u.count+=1
    body:=test_device_body(&u.devices[k],Dh_Key(u.dhs[k].public),&u.kems[k],u.log.id,"laptop")
    _,e:=log_append(&u.log,.Device_Add,body,&u.devices[0],2)
    testing.expect_value(t,e,Error.None,loc=loc)
    return k
}

// The body of the Device_Add of a device with these keys, joining the user log.
@(private)
test_device_body :: proc(device:^Identity,dh:Dh_Key,seed:^[KEM_SEED]u8,joins:Log_Id,name:string) -> []u8 {
    kem,_:=kem_public(seed)
    return body_make(Device_Add_Body{device=device.key,dh=dh,kem=kem,proof=device_proof(device,transmute([32]u8)joins,dh,blake3.hash(kem[:]))},transmute([]u8)name)
}

// An entry with the parents given, added to l: its address.
@(private)
test_entry :: proc(t:^testing.T,l:^Log,type:Entry_Type,body:[]u8,identity:^Identity,parents:[]store.Hash,time:i64,loc:=#caller_location) -> store.Hash {
    d:=Draft{type=type,log_id=l.id,parents=parents,time=time,body=body}
    bytes,address,e:=entry_sign(&d,identity,context.temp_allocator)
    testing.expect_value(t,e,Error.None,loc=loc)
    _,add:=log_add(l,bytes,true)
    testing.expect_value(t,add,Error.None,loc=loc)
    return address
}

@(private)
test_heads :: proc(l:^Log) -> []store.Hash {
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    log_heads(l,&heads)
    return heads[:]
}

@(private)
test_org :: proc(t:^testing.T,org:^Log,owner:^Test_User,loc:=#caller_location) {
    log_init(org,{},context.allocator)
    _,e:=log_append(org,.Org_Genesis,body_make(Org_Genesis_Body{owner=owner.log.id},transmute([]u8)string("studio")),&owner.devices[0],10)
    testing.expect_value(t,e,Error.None,loc=loc)
}

@(private)
test_users_fold :: proc(t:^testing.T,users:[]^Test_User,folds:[]User_Fold,out:[]^User_Fold) {
    for u,i in users {
        testing.expect_value(t,user_fold(&folds[i],&u.log),Error.None)
        out[i]=&folds[i]
    }
}

@(private)
test_users_destroy :: proc(folds:[]User_Fold) {
    for &f in folds {user_fold_destroy(&f)}
}

// A device revoked from a machine that holds none of the org's logs: its
// User_Log names no org, project or proposal. Until a witness of the
// revocation reaches a log, what the device signed there stands; once one
// does, what it signed before the witness stands and whatever it signs
// after, with old parents and an old time, counts nowhere: in the org's log,
// in a project's, and in its own User_Log after the revocation.
@(test)
revocation_witness_rejects_backdated_entries :: proc(t:^testing.T) {
    alice,bob,carol:Test_User
    test_user(t,&alice,"alice");defer log_destroy(&alice.log)
    test_user(t,&bob,"bob");defer log_destroy(&bob.log)
    test_user(t,&carol,"carol");defer log_destroy(&carol.log)
    stolen:=test_device(t,&alice)
    org:Log
    test_org(t,&org,&alice);defer log_destroy(&org)
    genesis:=org.items[0].address
    _,e:=log_append(&org,.Member_Add,body_make(Member_Body{user=bob.log.id,role=.Writer}),&alice.devices[stolen],20)
    testing.expect_value(t,e,Error.None)
    before:=test_heads(&org)[0]
    project:Log
    log_init(&project);defer log_destroy(&project)
    _,e=log_append(&project,.Project_Genesis,body_make(Project_Genesis_Body{org=org.id,public=true},transmute([]u8)string("game")),&alice.devices[0],21,{},before)
    testing.expect_value(t,e,Error.None)
    log_append(&org,.Project_Add,body_make(Project_Add_Body{project=project.id,public=true}),&alice.devices[0],22)
    ctx:=test_heads(&org)[0]
    move:=test_move(t,&project,"main",{0=1},&alice.devices[stolen],ctx,23)
    user_before_revoke:=slice.clone(test_heads(&alice.log),context.temp_allocator)

    // A fresh machine of alice's revokes the stolen device: the user log names nothing of the org.
    revoke,re:=log_append(&alice.log,.Device_Revoke,revoke_body(alice.devices[stolen].key),&alice.recovery,30)
    testing.expect_value(t,re,Error.None)
    for &item in alice.log.items {
        testing.expect(t,!strings.contains(string(item.bytes),string(org.id[:])) && !strings.contains(string(item.bytes),string(project.id[:])),"a user's log names no org or project")
    }

    // Not witnessed yet: the backdated entry stands, as the revocation has not reached the org's log.
    early:=test_entry(t,&org,.Member_Add,body_make(Member_Body{user=carol.log.id,role=.Reader}),&alice.devices[stolen],{genesis},15)
    folds:[3]User_Fold
    users:[3]^User_Fold
    test_users_fold(t,{&alice,&bob,&carol},folds[:],users[:])
    f:Org_Fold
    testing.expect_value(t,org_fold(&f,&org,users[:]),Error.None)
    testing.expect(t,f.valid[log_find(&org,early)],"a revocation no witness carried here leaves the log as it was")
    org_fold_destroy(&f)
    test_users_destroy(folds[:])
    // Back to before it, as a member first saw it: the witnesses come in each log.
    wipe:Log
    log_init(&wipe,org.id);defer log_destroy(&wipe)
    for &item in org.items {
        if item.address!=early {log_add(&wipe,item.bytes,false)}
    }
    log_destroy(&org)
    org=wipe
    wipe={}
    witness:=test_witness(t,&org,alice.log.id,revoke,&alice.devices[0],{},40)
    test_witness(t,&project,alice.log.id,revoke,&alice.devices[0],test_heads(&org)[0],41)

    // The thief backdates: old parents and an old time, in the org's log, the project's and alice's.
    backdated:=test_entry(t,&org,.Member_Add,body_make(Member_Body{user=carol.log.id,role=.Admin}),&alice.devices[stolen],{genesis},15)
    after:=test_entry(t,&org,.Project_Add,body_make(Project_Add_Body{project=store.Hash{0=1},public=true}),&alice.devices[stolen],{witness},45)
    late_move:=test_move(t,&project,"main",{0=2},&alice.devices[stolen],ctx,24,{move})
    rogue:=identity_make()
    rogue_dh,_:=net.dh_key()
    rogue_seed:=random_id([KEM_SEED]u8)
    rogue_add:=test_entry(t,&alice.log,.Device_Add,test_device_body(&rogue,Dh_Key(rogue_dh.public),&rogue_seed,alice.log.id,"rogue"),&alice.devices[stolen],user_before_revoke,25)

    test_users_fold(t,{&alice,&bob,&carol},folds[:],users[:])
    defer test_users_destroy(folds[:])
    a:=users[0]
    testing.expect(t,user_device_index(a,rogue.key)<0,"a device the revoked one added after the revocation is no device")
    testing.expect(t,!a.valid[log_find(&alice.log,rogue_add)])
    testing.expect(t,!user_device_active(a,alice.devices[stolen].key) && user_device_active(a,alice.devices[0].key))

    testing.expect_value(t,org_fold(&f,&org,users[:]),Error.None)
    defer org_fold_destroy(&f)
    testing.expect(t,f.valid[log_find(&org,before)],"what the device signed before the witness stands")
    testing.expect(t,f.valid[log_find(&org,witness)])
    testing.expect(t,!f.valid[log_find(&org,backdated)],"a backdated entry is outside the witness's past")
    testing.expect(t,!f.valid[log_find(&org,after)])
    testing.expect_value(t,org_role(&f,bob.log.id),Role.Writer)
    testing.expect_value(t,org_role(&f,carol.log.id),Role.None)
    testing.expect_value(t,len(f.projects),1)
    p:Project_Fold
    testing.expect_value(t,project_fold(&p,&project,&f),Error.None)
    defer project_fold_destroy(&p)
    testing.expect(t,p.valid[log_find(&project,move)] && !p.valid[log_find(&project,late_move)],"in the project's log too")
}

// A move of bookmark of l to the revision to, signed by identity under the
// org's entry ctx, from the targets from, on parents (the heads when nil).
@(private)
test_move :: proc(t:^testing.T,l:^Log,bookmark:string,to:Revision,identity:^Identity,ctx:store.Hash,time:i64,parents:[]store.Hash=nil,from:[]Revision={},loc:=#caller_location) -> store.Hash {
    address,e:=log_append(l,.Bookmark_Move,move_body(bookmark,from,to),identity,time,{},ctx,parents)
    testing.expect_value(t,e,Error.None,loc=loc)
    return address
}

// A Witness in l of the removal at removal of the log of id, by identity,
// on the heads of l.
@(private)
test_witness :: proc(t:^testing.T,l:^Log,log:Log_Id,removal:store.Hash,identity:^Identity,ctx:store.Hash,time:i64,loc:=#caller_location) -> store.Hash {
    address,e:=log_append(l,.Witness,witness_body(log,removal),identity,time,{},ctx)
    testing.expect_value(t,e,Error.None,loc=loc)
    return address
}

// Two admins removing each other at once are both removed; what a removed
// admin wrote concurrently with its removal is void, as is a write about a
// member concurrent with its removal; the owner is removed by nothing but its
// own Owner_Transfer. Every order of arrival folds to the same state.
@(test)
concurrent_admin_removals_fold_deterministically :: proc(t:^testing.T) {
    alice,bob,carol,dave:Test_User
    test_user(t,&alice,"alice");defer log_destroy(&alice.log)
    test_user(t,&bob,"bob");defer log_destroy(&bob.log)
    test_user(t,&carol,"carol");defer log_destroy(&carol.log)
    test_user(t,&dave,"dave");defer log_destroy(&dave.log)
    org:Log
    test_org(t,&org,&alice);defer log_destroy(&org)
    log_append(&org,.Member_Add,body_make(Member_Body{user=bob.log.id,role=.Admin}),&alice.devices[0],11)
    log_append(&org,.Member_Add,body_make(Member_Body{user=carol.log.id,role=.Admin}),&alice.devices[0],12)
    log_append(&org,.Member_Add,body_make(Member_Body{user=dave.log.id,role=.Writer}),&alice.devices[0],13)
    h:=slice.clone(test_heads(&org),context.temp_allocator)
    test_entry(t,&org,.Member_Remove,body_make(Subject_Body{subject=carol.log.id}),&bob.devices[0],h,20)
    test_entry(t,&org,.Member_Remove,body_make(Subject_Body{subject=bob.log.id}),&carol.devices[0],h,20)
    promote:=test_entry(t,&org,.Role_Set,body_make(Member_Body{user=dave.log.id,role=.Admin}),&carol.devices[0],h,21)
    demote:=test_entry(t,&org,.Role_Set,body_make(Member_Body{user=bob.log.id,role=.Reader}),&alice.devices[0],h,22)
    owner:=test_entry(t,&org,.Member_Remove,body_make(Subject_Body{subject=alice.log.id}),&bob.devices[0],h,23)

    folds:[4]User_Fold
    users:[4]^User_Fold
    test_users_fold(t,{&alice,&bob,&carol,&dave},folds[:],users[:])
    defer test_users_destroy(folds[:])
    f:Org_Fold
    testing.expect_value(t,org_fold(&f,&org,users[:]),Error.None)
    defer org_fold_destroy(&f)
    testing.expect_value(t,org_role(&f,alice.log.id),Role.Owner)
    testing.expect_value(t,org_role(&f,bob.log.id),Role.None)
    testing.expect_value(t,org_role(&f,carol.log.id),Role.None)
    testing.expect_value(t,org_role(&f,dave.log.id),Role.Writer)
    testing.expect(t,!f.valid[log_find(&org,promote)] && !f.valid[log_find(&org,demote)] && !f.valid[log_find(&org,owner)])

    // The same entries in other orders of arrival fold the same.
    bytes:=make([][]u8,len(org.items),context.temp_allocator)
    for item,i in org.items {bytes[i]=item.bytes}
    for seed in 1..=6 {
        r:=rand.create(u64(seed))
        shuffled:=slice.clone(bytes,context.temp_allocator)
        rand.shuffle(shuffled,rand.default_random_generator(&r))
        other:Log
        log_init(&other,org.id)
        for b in shuffled {
            _,e:=log_add(&other,b,true)
            testing.expect_value(t,e,Error.None)
        }
        g:Org_Fold
        testing.expect_value(t,org_fold(&g,&other,users[:]),Error.None)
        testing.expect(t,slice.equal(g.members[:],f.members[:]))
        for item,i in org.items {testing.expect_value(t,g.valid[log_find(&other,item.address)],f.valid[i])}
        org_fold_destroy(&g)
        log_destroy(&other)
    }

    // Only the owner's transfer moves the owner.
    log_append(&org,.Owner_Transfer,body_make(Subject_Body{subject=dave.log.id}),&alice.devices[0],30)
    g:Org_Fold
    testing.expect_value(t,org_fold(&g,&org,users[:]),Error.None)
    defer org_fold_destroy(&g)
    testing.expect(t,org_role(&g,dave.log.id)==.Owner && org_role(&g,alice.log.id)==.Admin && g.owner==dave.log.id)
}

// Entries and logs from hostile bytes are refused, never crash; a signature
// that does not hold refuses the entry from a peer.
@(test)
hostile_log_entries_are_refused :: proc(t:^testing.T) {
    alice:Test_User
    test_user(t,&alice,"alice");defer log_destroy(&alice.log)
    test_device(t,&alice)
    good:=alice.log.items[0].bytes
    h:=base.Hostile{state=11}
    for _ in 0..<2000 {
        size:=int(base.hostile_next(&h)%u64(len(good)+16))
        bytes:=make([]u8,size,context.temp_allocator)
        for &b in bytes {b=u8(base.hostile_next(&h))}
        if size>=size_of(Entry_Head) && base.hostile_next(&h)%2==0 {
            copy(bytes,good[:min(size,len(good))])
            bytes[base.hostile_next(&h)%u64(size)]~=u8(1+base.hostile_next(&h)%255)
        }
        _,_=entry_decode(bytes)
        l:Log
        log_init(&l,alice.log.id)
        _,_=log_add(&l,bytes,true)
        log_index(&l)
        log_destroy(&l)
    }
    for k in 0..<len(good) {
        bytes:=slice.clone(good,context.temp_allocator)
        bytes[k]~=0x40
        l:Log
        log_init(&l)
        _,e:=log_add(&l,bytes,true)
        testing.expect(t,e!=.None,"a flipped byte is refused")
        log_destroy(&l)
    }
    // A device's ML-KEM key that is no encapsulation key (a coefficient not
    // reduced) is refused, well signed or not: in a genesis and in a Device_Add.
    for k in 0..<2 {
        bytes:=slice.clone(alice.log.items[k].bytes,context.temp_allocator)
        e,_:=entry_decode(bytes)
        at:=len(bytes)-size_of(Signature)-len(e.body)+int(e.type==.User_Genesis?offset_of(User_Genesis_Body,kem):offset_of(Device_Add_Body,kem))
        for c in 0..<3 {
            hostile:=slice.clone(bytes,context.temp_allocator)
            switch c {
            case 0: hostile[at],hostile[at+1]=0x01,0x0d // the first coefficient is q
            case 1: for &b in hostile[at:][:KEM_PUBLIC-32] {b=0xff}
            case 2: hostile[at+KEM_PUBLIC-33]=0xff // the last coefficient's high bits
            }
            signer:=e.type==.User_Genesis?&alice.recovery:&alice.devices[0]
            signature:=sign(signer,hostile[:len(hostile)-size_of(Signature)])
            copy(hostile[len(hostile)-size_of(Signature):],signature[:])
            _,de:=entry_decode(hostile)
            testing.expectf(t,de==.Corrupt,"a hostile ML-KEM key %d in %v is read",c,e.type)
            l:Log
            log_init(&l,k==0?{}:alice.log.id)
            if k==1 {log_add(&l,alice.log.items[0].bytes,true)}
            _,ae:=log_add(&l,hostile,true)
            testing.expect(t,ae!=.None,"a log does not take it")
            log_destroy(&l)
        }
    }
    // An entry of another log is refused.
    other:Test_User
    test_user(t,&other,"other");defer log_destroy(&other.log)
    test_device(t,&other)
    _,e:=log_add(&alice.log,other.log.items[1].bytes,true)
    testing.expect(t,e!=.None)
}

// The pairing code is fixed by values each side committed to before it saw
// the other's nonce. A middle that completes both handshakes gets different
// codes on the two screens, and anything it changes after the fact (another
// static key or nonce, ground to make the codes meet) breaks the commitment
// before the responder shows a code. Labels and infos never enter the code.
@(test)
pairing_rejects_mitm_label_grinding :: proc(t:^testing.T) {
    seed_of :: proc(n:u8) -> (seed:[64]u8) {
        for &b,i in seed {b=u8(i)*7+n*31+1}
        return
    }
    key_of :: proc(n:u8) -> net.Dh_Key {
        private:net.Key
        for &b,i in private {b=u8(i)*13+n*17+5}
        return net.dh_key_from(&private)
    }
    ticket:=[16]u8{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16}
    s_i,s_r,s_m:=key_of(1),key_of(2),key_of(3)
    buffer:[4][2048]u8

    // Honest: both ends show the same code and learn each other's keys.
    {
        i,r:Pair
        si,sr:=seed_of(1),seed_of(2)
        pair_init(&i,true,s_i,ticket,Dh_Key(s_r.public),&si)
        pair_init(&r,false,s_r,ticket,{},&sr)
        p1,e1:=pair_write_p1(&i,buffer[0][:])
        testing.expect_value(t,e1,Pair_Error.None)
        testing.expect_value(t,pair_read_p1(&r,p1),Pair_Error.None)
        p2,e2:=pair_write_p2(&r,transmute([]u8)string("responder"),buffer[1][:])
        testing.expect_value(t,e2,Pair_Error.None)
        testing.expect_value(t,pair_read_p2(&i,p2),Pair_Error.None)
        p3,e3:=pair_write_p3(&i,transmute([]u8)string("initiator"),buffer[2][:])
        testing.expect_value(t,e3,Pair_Error.None)
        testing.expect_value(t,pair_read_p3(&r,p3),Pair_Error.None)
        testing.expect(t,len(pair_code(&i))==PAIR_CODE_TEXT && pair_code(&i)==pair_code(&r))
        testing.expect(t,pair_remote(&i)==Dh_Key(s_r.public) && pair_remote(&r)==Dh_Key(s_i.public))
        testing.expect(t,string(pair_info(&r))=="initiator" && string(pair_info(&i))=="responder")
        p4,e4:=pair_write_p4(&r,.Approved,transmute([]u8)string("entries"),buffer[3][:])
        testing.expect_value(t,e4,Pair_Error.None)
        status,payload,e5:=pair_read_p4(&i,p4)
        testing.expect(t,e5==.None && status==.Approved && string(payload)=="entries")
        _,_,e6:=pair_read_p4(&i,p4)
        testing.expect(t,e6!=.None,"a P4 replayed is refused")
    }

    // A middle M with a ticket that does not name R's key is refused by I at P2.
    {
        i,m:Pair
        si,sm:=seed_of(1),seed_of(3)
        pair_init(&i,true,s_i,ticket,Dh_Key(s_r.public),&si)
        pair_init(&m,false,s_m,ticket,{},&sm)
        p1,_:=pair_write_p1(&i,buffer[0][:])
        pair_read_p1(&m,p1)
        p2,_:=pair_write_p2(&m,nil,buffer[1][:])
        testing.expect_value(t,pair_read_p2(&i,p2),Pair_Error.Ticket)
    }

    // A ticket read by M (no key check at I): M runs both handshakes, R side
    // first so it knows R's code, then tries 4096 values on I's side. Its
    // choice is fixed before I reveals its nonce, so it cannot steer I's code.
    {
        m_r,r:Pair
        smr,sr:=seed_of(4),seed_of(2)
        pair_init(&m_r,true,s_m,ticket,{},&smr)
        pair_init(&r,false,s_r,ticket,{},&sr)
        p1,_:=pair_write_p1(&m_r,buffer[0][:])
        pair_read_p1(&r,p1)
        p2,_:=pair_write_p2(&r,nil,buffer[1][:])
        pair_read_p2(&m_r,p2)
        committed_nonce:=m_r.nonce
        // Grinding after the commitment: every other nonce, or key, is refused, and R shows no code.
        for n in 0..<64 {
            ground:=m_r
            ground.nonce[0]~=u8(n+1)
            if n%2==1 {ground.s=key_of(u8(40+n))}
            tried:=r
            p3,_:=pair_write_p3(&ground,transmute([]u8)string("label"),buffer[2][:])
            testing.expect_value(t,pair_read_p3(&tried,p3),Pair_Error.Commitment)
            testing.expect_value(t,pair_code(&tried),"")
        }
        testing.expect(t,m_r.nonce==committed_nonce)
        // Changing only the label (the info) keeps the code: it is not an input.
        codes:[2]string
        for label,k in ([2]string{"label one","another label that is longer"}) {
            honest,tried:=m_r,r
            p3,_:=pair_write_p3(&honest,transmute([]u8)label,buffer[2][:])
            testing.expect_value(t,pair_read_p3(&tried,p3),Pair_Error.None)
            codes[k]=strings.clone(pair_code(&tried),context.temp_allocator)
            testing.expect_value(t,codes[k],pair_code(&honest))
        }
        testing.expect_value(t,codes[0],codes[1])
        code_r:=codes[0]

        // I's side: M answers I's commitment with each candidate; none can
        // be chosen to match, since I's nonce is revealed after.
        matched:=0
        for n in 0..<4096 {
            i,m_i:Pair
            si:=seed_of(1)
            sm:=seed_of(5)
            sm[40]=u8(n)
            sm[41]=u8(n>>8)
            pair_init(&i,true,s_i,ticket,{},&si)
            pair_init(&m_i,false,s_m,ticket,{},&sm)
            q1,_:=pair_write_p1(&i,buffer[0][:])
            pair_read_p1(&m_i,q1)
            q2,_:=pair_write_p2(&m_i,nil,buffer[1][:])
            pair_read_p2(&i,q2)
            q3,_:=pair_write_p3(&i,nil,buffer[2][:])
            testing.expect_value(t,pair_read_p3(&m_i,q3),Pair_Error.None)
            if pair_code(&i)==code_r {matched+=1}
        }
        testing.expect_value(t,matched,0)
    }

    // Hostile messages: wrong ticket, short, out of order, random.
    {
        r:Pair
        sr:=seed_of(2)
        pair_init(&r,false,s_r,ticket,{},&sr)
        h:=base.Hostile{state=3}
        for _ in 0..<500 {
            size:=int(base.hostile_next(&h)%700)
            bytes:=buffer[0][:size]
            for &b in bytes {b=u8(base.hostile_next(&h))}
            if size>0 {bytes[0]=u8(1+base.hostile_next(&h)%4)}
            tried:=r
            _=pair_read_p1(&tried,bytes)
            _=pair_read_p3(&tried,bytes)
            initiator:Pair
            si:=seed_of(1)
            pair_init(&initiator,true,s_i,ticket,{},&si)
            _=pair_read_p2(&initiator,bytes)
            _,_,_=pair_read_p4(&initiator,bytes)
        }
        other:=ticket
        other[0]=99
        i:Pair
        si:=seed_of(1)
        pair_init(&i,true,s_i,other,{},&si)
        p1,_:=pair_write_p1(&i,buffer[0][:])
        testing.expect_value(t,pair_read_p1(&r,p1),Pair_Error.Ticket)
        testing.expect_value(t,pair_read_p3(&r,p1),Pair_Error.Corrupt)
    }
}

// A ticket survives its text form; a changed character is caught.
@(test)
pair_tickets_and_gate :: proc(t:^testing.T) {
    key:=net.Key{}
    for &b,i in key {b=u8(i)}
    ticket:=Ticket{id={9,8,7,6,5,4,3,2,1,0,1,2,3,4,5,6},responder=Dh_Key(key),mode=.Member,expires=123456789}
    buffer:[TICKET_TEXT]u8
    text:=ticket_encode(ticket,&buffer)
    back,ok:=ticket_decode(text)
    testing.expect(t,ok && back==ticket)
    for k in 0..<len(text) {
        bytes:=transmute([]u8)strings.clone(text,context.temp_allocator)
        bytes[k]=bytes[k]=='A'?'B':'A'
        _,changed:=ticket_decode(string(bytes))
        testing.expect(t,!changed,"a changed character fails the checksum")
    }
    _,short:=ticket_decode(text[:len(text)-1])
    testing.expect(t,!short)

    g:Pair_Gate
    testing.expect_value(t,pair_gate_open(&g,ticket.id,0),Pair_Error.None)
    testing.expect_value(t,pair_gate_open(&g,ticket.id,1),Pair_Error.Busy)
    testing.expect_value(t,pair_gate_open(&g,ticket.id,PAIR_TIMEOUT),Pair_Error.None)
    testing.expect_value(t,g.denials,1)
    now:=PAIR_TIMEOUT
    for _ in 0..<PAIR_DENIALS-1 {
        pair_gate_close(&g,false,now)
        now+=1
        pair_gate_open(&g,ticket.id,now)
    }
    testing.expect(t,!g.active || g.paused_until>now)
    pair_gate_close(&g,false,now)
    testing.expect_value(t,pair_gate_open(&g,ticket.id,now+1),Pair_Error.Paused)
    testing.expect_value(t,pair_gate_open(&g,ticket.id,now+PAIR_PAUSE+1),Pair_Error.None)
    pair_gate_close(&g,true,now+PAIR_PAUSE+2)
    testing.expect_value(t,g.denials,0)
}

// Pairing a second device and a member makes the entries that link them. A
// device's ML-KEM key comes in K frames after P3 and lands in its Device_Add;
// a frame changed on the way does not open, a key other than the one P3
// named is refused, and a middle that names its own key in P3 runs two
// sessions whose codes differ, and cannot sign the device's proof over it.
@(test)
pairing_links_a_device_and_adds_a_member :: proc(t:^testing.T) {
    alice,bob:Test_User
    test_user(t,&alice,"alice");defer log_destroy(&alice.log)
    test_user(t,&bob,"bob");defer log_destroy(&bob.log)
    org:Log
    test_org(t,&org,&alice);defer log_destroy(&org)
    laptop:=identity_make()
    laptop_dh,_:=net.dh_key()
    ticket:=[16]u8{0=7}
    buffer:[3][2048]u8
    info:[2][PAIR_INFO_MAX]u8
    run :: proc(t:^testing.T,i,r:^Pair,r_info,i_info:[]u8,buffer:^[3][2048]u8) {
        p1,_:=pair_write_p1(i,buffer[0][:])
        pair_read_p1(r,p1)
        p2,_:=pair_write_p2(r,r_info,buffer[1][:])
        testing.expect_value(t,pair_read_p2(i,p2),Pair_Error.None)
        p3,_:=pair_write_p3(i,i_info,buffer[2][:])
        testing.expect_value(t,pair_read_p3(r,p3),Pair_Error.None)
    }
    laptop_seed:=random_id([KEM_SEED]u8)
    laptop_kem,_:=kem_public(&laptop_seed)
    laptop_hash:=blake3.hash(laptop_kem[:])
    keys:[PAIR_KEM_PARTS][PAIR_K_SIZE]u8
    {
        i,r:Pair
        pair_init(&i,true,laptop_dh,ticket,Dh_Key(alice.dhs[0].public))
        pair_init(&r,false,alice.dhs[0],ticket)
        r_info:=pair_info_encode({mode=.Device,log_id=alice.log.id,device=alice.devices[0].key},"phone",&info[0])
        // I learns the user log from R's info, and proves its keys over it.
        i_info:=pair_info_encode({mode=.Device,device=laptop.key,kem=laptop_hash,proof=device_proof(&laptop,transmute([32]u8)alice.log.id,Dh_Key(laptop_dh.public),laptop_hash)},"laptop",&info[1])
        run(t,&i,&r,r_info,i_info,&buffer)
        _,e:=pair_approve_device(&r,&alice.log,&alice.devices[0],5)
        testing.expect_value(t,e,Error.Invalid_Argument)
        for k in 0..<PAIR_KEM_PARTS {
            frame,fe:=pair_write_key(&i,&laptop_kem,k,keys[k][:])
            testing.expect(t,fe==.None && len(frame)==PAIR_K_SIZE && PAIR_K_SIZE+1<=FRAME_MAX)
        }
        tampered:=keys[0]
        tampered[PAIR_HEAD+9]~=1
        complete,ke:=pair_read_key(&r,tampered[:],laptop_hash)
        testing.expect(t,!complete && ke==.Corrupt,"a K frame changed on the way does not open")
        for k in 0..<PAIR_KEM_PARTS {
            complete,ke=pair_read_key(&r,keys[k][:],laptop_hash)
            testing.expect_value(t,ke,Pair_Error.None)
        }
        testing.expect(t,complete,"the key is whole once every part came")
        _,e=pair_approve_device(&r,&alice.log,&alice.devices[0],5)
        testing.expect_value(t,e,Error.None)
        f:User_Fold
        testing.expect_value(t,user_fold(&f,&alice.log),Error.None)
        testing.expect(t,user_device_active(&f,laptop.key) && user_dh_active(&f,Dh_Key(laptop_dh.public)))
        k:=user_device_index(&f,laptop.key)
        testing.expect(t,k>=0 && bytes_equal(user_device_kem(&f,f.devices[k]),laptop_kem[:]),"the device's ML-KEM key is in its Device_Add")
        user_fold_destroy(&f)
    }
    // A middle M sits between the laptop and R, with a ticket read on the way.
    {
        m_seed:=random_id([KEM_SEED]u8)
        m_kem,_:=kem_public(&m_seed)
        m_dh,_:=net.dh_key()
        lm,ml,mr,rm:Pair
        pair_init(&lm,true,laptop_dh,ticket)
        pair_init(&ml,false,m_dh,ticket)
        pair_init(&mr,true,m_dh,ticket,Dh_Key(alice.dhs[0].public))
        pair_init(&rm,false,alice.dhs[0],ticket)
        r_info:=pair_info_encode({mode=.Device,log_id=alice.log.id,device=alice.devices[0].key},"phone",&info[0])
        laptop_info:=pair_info_encode({mode=.Device,device=laptop.key,kem=laptop_hash,proof=device_proof(&laptop,transmute([32]u8)alice.log.id,Dh_Key(laptop_dh.public),laptop_hash)},"laptop",&info[1])
        run(t,&lm,&ml,r_info,laptop_info,&buffer)
        // M relays the laptop's info to R and sends its own key: refused.
        run(t,&mr,&rm,r_info,pair_info(&ml),&buffer)
        for k in 0..<PAIR_KEM_PARTS {pair_write_key(&mr,&m_kem,k,keys[k][:])}
        ke:Pair_Error
        for k in 0..<PAIR_KEM_PARTS {_,ke=pair_read_key(&rm,keys[k][:],laptop_hash)}
        testing.expect_value(t,ke,Pair_Error.Key)
        _,e:=pair_approve_device(&rm,&alice.log,&alice.devices[0],6)
        testing.expect_value(t,e,Error.Invalid_Argument)
        // Naming its own key, its two sessions show two codes for the people to compare.
        testing.expect(t,pair_code(&lm)!=pair_code(&rm),"the laptop and R show different codes with a middle between them")
    }
    {
        i,r:Pair
        pair_init(&i,true,bob.dhs[0],ticket,Dh_Key(alice.dhs[0].public))
        pair_init(&r,false,alice.dhs[0],ticket)
        r_info:=pair_info_encode({mode=.Member,log_id=org.id,device=alice.devices[0].key},"studio",&info[0])
        i_info:=pair_info_encode({mode=.Member,log_id=bob.log.id,device=bob.devices[0].key},"bob",&info[1])
        run(t,&i,&r,r_info,i_info,&buffer)
        _,e:=pair_approve_member(&r,&org,&alice.devices[0],.Writer,6)
        testing.expect_value(t,e,Error.None)
        folds:[2]User_Fold
        users:[2]^User_Fold
        test_users_fold(t,{&alice,&bob},folds[:],users[:])
        defer test_users_destroy(folds[:])
        f:Org_Fold
        testing.expect_value(t,org_fold(&f,&org,users[:]),Error.None)
        defer org_fold_destroy(&f)
        testing.expect_value(t,org_role(&f,bob.log.id),Role.Writer)
    }
}

// A grant holds only from an admin, within the admin's rights, for at most
// 30 days, and until revoked.
@(test)
grants_verify_against_the_org :: proc(t:^testing.T) {
    alice,bob:Test_User
    test_user(t,&alice,"alice");defer log_destroy(&alice.log)
    test_user(t,&bob,"bob");defer log_destroy(&bob.log)
    org:Log
    test_org(t,&org,&alice);defer log_destroy(&org)
    log_append(&org,.Member_Add,body_make(Member_Body{user=bob.log.id,role=.Writer}),&alice.devices[0],11)
    head:=test_heads(&org)[0]
    folds:[2]User_Fold
    users:[2]^User_Fold
    test_users_fold(t,{&alice,&bob},folds[:],users[:])
    defer test_users_destroy(folds[:])
    DAY :: i64(24*3600)*1_000_000_000
    make_grant :: proc(t:^testing.T,org:^Log,head:store.Hash,issuer:^Identity,rights:Rights,days:i64) -> []u8 {
        g:=Grant{head={org=org.id,org_head=head,issuer=issuer.key,rights=rights,not_before=0,not_after=days*DAY}}
        bytes,e:=grant_encode(&g,issuer,context.temp_allocator)
        testing.expect_value(t,e,Error.None)
        return bytes
    }
    f:Org_Fold
    testing.expect_value(t,org_fold(&f,&org,users[:]),Error.None)
    good:=make_grant(t,&org,head,&alice.devices[0],{.Read,.DDC},30)
    _,e:=grant_verify(&f,good,DAY)
    testing.expect_value(t,e,Error.None)
    _,e=grant_verify(&f,make_grant(t,&org,head,&alice.devices[0],{.Read},31),DAY)
    testing.expect_value(t,e,Error.Unauthorized)
    _,e=grant_verify(&f,make_grant(t,&org,head,&bob.devices[0],{.Read},1),DAY/2)
    testing.expect_value(t,e,Error.Unauthorized)
    _,e=grant_verify(&f,good,31*DAY)
    testing.expect_value(t,e,Error.Expired)
    org_fold_destroy(&f)
    log_append(&org,.Grant_Revoke,body_make(Subject_Body{subject=store.address_of_bytes(good)}),&alice.devices[0],12)
    testing.expect_value(t,org_fold(&f,&org,users[:]),Error.None)
    defer org_fold_destroy(&f)
    _,e=grant_verify(&f,good,DAY)
    testing.expect_value(t,e,Error.Unauthorized)
}

// What the org's tests need in a store: alice the owner, bob a writer, carol
// a reader, and a project.
@(private)
Test_Org :: struct {
    alice,bob,carol:Test_User,
    org,project:Log,
    folds:[3]User_Fold,
    users:[3]^User_Fold,
    fold:Org_Fold,
}

@(private)
test_org_make :: proc(t:^testing.T,o:^Test_Org,public:=true) {
    test_user(t,&o.alice,"alice")
    test_user(t,&o.bob,"bob")
    test_user(t,&o.carol,"carol")
    test_org(t,&o.org,&o.alice)
    log_init(&o.project)
    _,e:=log_append(&o.project,.Project_Genesis,body_make(Project_Genesis_Body{org=o.org.id,public=b8(public)},transmute([]u8)string("game")),&o.alice.devices[0],10,{},o.org.items[0].address)
    testing.expect_value(t,e,Error.None)
    log_append(&o.org,.Project_Add,body_make(Project_Add_Body{project=o.project.id,public=b8(public)}),&o.alice.devices[0],11)
    log_append(&o.org,.Member_Add,body_make(Member_Body{user=o.bob.log.id,role=.Writer}),&o.alice.devices[0],12)
    log_append(&o.org,.Member_Add,body_make(Member_Body{user=o.carol.log.id,role=.Reader}),&o.alice.devices[0],13)
    test_users_fold(t,{&o.alice,&o.bob,&o.carol},o.folds[:],o.users[:])
    testing.expect_value(t,org_fold(&o.fold,&o.org,o.users[:]),Error.None)
}

@(private)
test_org_destroy :: proc(o:^Test_Org) {
    org_fold_destroy(&o.fold)
    test_users_destroy(o.folds[:])
    log_destroy(&o.org)
    log_destroy(&o.project)
    log_destroy(&o.alice.log)
    log_destroy(&o.bob.log)
    log_destroy(&o.carol.log)
}

// A change of one file, committed: its revision.
@(private)
test_change :: proc(t:^testing.T,s:^store.Store,author:^Identity,text:string) -> Revision {
    address,e:=store.put(s,transmute([]u8)text)
    testing.expect_value(t,e,store.Error.None)
    root,te:=tree_build(s,{{path="readme.txt",kind=.File,address=address,size=u64(len(text))}})
    testing.expect_value(t,te,Error.None)
    c:=Change{id=random_id(Change_Id),tree=root,author=author.key,created=1,written=1,description=text}
    revision,ce:=change_put(s,&c,author)
    testing.expect_value(t,ce,Error.None)
    testing.expect_value(t,store.commit(s),store.Error.None)
    return revision
}

// Links repo to project in s, as making a workspace of the project does: what
// its operations keep is the project's org's on this machine (provenance.odin).
test_link :: proc(t:^testing.T,s:^store.Store,repo:Repo_Id,project:Log_Id,loc:=#caller_location) {
    testing.expect_value(t,store.ref_set(s,MACHINE_NAMESPACE,machine_repo_name(repo),project),store.Error.None,loc=loc)
    testing.expect_value(t,store.commit(s),store.Error.None,loc=loc)
}

// Writes revisions as a workspace of project in s does: a repository linked
// to the project whose bookmarks name them.
test_written :: proc(t:^testing.T,s:^store.Store,project:Log_Id,revisions:..Revision,loc:=#caller_location) {
    r:Repo
    testing.expect_value(t,repo_create(&r,s,identity_make(),random_id(Workspace_Id)),Error.None,loc=loc)
    defer repo_close(&r)
    for revision,i in revisions {
        name:=fmt.tprintf("written-%d",i)
        testing.expect_value(t,bookmark_set(&r,name,revision),Error.None,loc=loc)
    }
    test_link(t,s,r.id,project,loc)
}

// Copies the object at address from one store to another, as a fetch does.
@(private)
test_copy :: proc(t:^testing.T,from,to:^store.Store,address:store.Hash,kind:Object_Kind) -> store.Hash {
    bytes,e:=object_get(from,address,kind,context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    copied,pe:=object_put(to,kind,bytes)
    testing.expect_value(t,pe,Error.None)
    testing.expect_value(t,store.commit(to),store.Error.None)
    return copied
}

// A peer takes a device's newer refs only: an older seq, a forged signature,
// a device without write, or another device's name is refused, and the ref
// stays at the newest.
@(test)
device_refs_reject_rollback :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-refs-rollback")
    if folder=="" {return}
    a,ae:=store.open(strings.concatenate({folder,"/a"},context.temp_allocator))
    b,be:=store.open(strings.concatenate({folder,"/b"},context.temp_allocator))
    if !testing.expect(t,ae==.None && be==.None) {return}
    defer store.close(&a)
    defer store.close(&b)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    bob:=&o.bob.devices[0]
    first,e1:=device_refs_publish(&b,o.project.id,bob,{{"main",test_change(t,&b,bob,"one")}},1)
    second,e2:=device_refs_publish(&b,o.project.id,bob,{{"main",test_change(t,&b,bob,"two")},{"dev",test_change(t,&b,bob,"three")}},2)
    testing.expect(t,e1==.None && e2==.None)
    held,_,he:=device_refs_get(&b,o.project.id,bob.key,context.temp_allocator)
    testing.expect(t,he==.None && held.seq==2 && len(held.refs)==2)

    name:[32]u8
    bob_name:=refs_name(bob.key,&name)
    copied_first:=test_copy(t,&b,&a,first,.Device_Refs)
    copied_second:=test_copy(t,&b,&a,second,.Device_Refs)
    changed,e:=device_refs_accept(&a,&o.fold,o.project.id,bob_name,copied_second,0)
    testing.expect(t,e==.None && changed)
    changed,e=device_refs_accept(&a,&o.fold,o.project.id,bob_name,copied_first,0)
    testing.expect_value(t,e,Error.Rollback)
    changed,e=device_refs_accept(&a,&o.fold,o.project.id,bob_name,copied_second,0)
    testing.expect(t,e==.None && !changed)
    now,_,ne:=device_refs_get(&a,o.project.id,bob.key,context.temp_allocator)
    testing.expect(t,ne==.None && now.seq==2)

    // A forged record: bob's bytes with seq raised, the signature left.
    bytes,_:=object_get(&b,second,.Device_Refs,context.temp_allocator)
    forged:=slice.clone(bytes,context.temp_allocator)
    (^Device_Refs_Head)(raw_data(forged)).seq=9
    forged_address,_:=object_put(&a,.Device_Refs,forged)
    store.commit(&a)
    _,e=device_refs_accept(&a,&o.fold,o.project.id,bob_name,forged_address,0)
    testing.expect_value(t,e,Error.Unauthorized)

    // A reader cannot write refs; a record under another device's name is refused.
    carol:=&o.carol.devices[0]
    carol_refs,_:=device_refs_publish(&b,o.project.id,carol,{{"main",test_change(t,&b,carol,"carol")}},3)
    carol_copy:=test_copy(t,&b,&a,carol_refs,.Device_Refs)
    carol_name:[32]u8
    _,e=device_refs_accept(&a,&o.fold,o.project.id,refs_name(carol.key,&carol_name),carol_copy,0)
    testing.expect_value(t,e,Error.Unauthorized)
    _,e=device_refs_accept(&a,&o.fold,o.project.id,bob_name,carol_copy,0)
    testing.expect_value(t,e,Error.Invalid_Argument)
    now,_,_=device_refs_get(&a,o.project.id,bob.key,context.temp_allocator)
    testing.expect_value(t,now.seq,u64(2))
}

// Derived data is taken from writers and ddc producers; two outputs for one
// key are both kept and flagged. An output lists its result first and every
// other object once, sorted; hostile lists are refused.
@(test)
ddc_records_keep_differing_outputs :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-ddc")
    if folder=="" {return}
    a,ae:=store.open(strings.concatenate({folder,"/a"},context.temp_allocator))
    b,be:=store.open(strings.concatenate({folder,"/b"},context.temp_allocator))
    if !testing.expect(t,ae==.None && be==.None) {return}
    defer store.close(&a)
    defer store.close(&b)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    key:=store.address_of_bytes(transmute([]u8)string("shader key"))
    x,y:=store.Hash{0=1},store.Hash{0=2}
    nondeterministic,e:=ddc_publish(&b,o.org.id,&o.bob.devices[0],key,{x},nil,1)
    testing.expect(t,e==.None && !nondeterministic)
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    set,_:=store.ref_get(&b,ddc_namespace(o.org.id,&ns),store.hex(key,&name))
    copied:=test_copy(t,&b,&a,set,.DDC_Set)
    changed,flagged,ae2:=ddc_accept(&a,&o.fold,key,copied,1)
    testing.expect(t,ae2==.None && changed && !flagged)

    // A reader's record is skipped; alice's other output is kept beside bob's.
    ddc_publish(&b,o.org.id,&o.carol.devices[0],key,{y},nil,2)
    set,_=store.ref_get(&b,ddc_namespace(o.org.id,&ns),store.hex(key,&name))
    copied=test_copy(t,&b,&a,set,.DDC_Set)
    changed,flagged,_=ddc_accept(&a,&o.fold,key,copied,2)
    testing.expect(t,!changed && !flagged)
    flagged,_=ddc_publish(&a,o.org.id,&o.alice.devices[0],key,{y,x},nil,3)
    testing.expect(t,flagged,"two outputs of one key are nondeterminism")
    records:=make([dynamic]DDC_Record,context.temp_allocator)
    testing.expect_value(t,ddc_lookup(&a,o.org.id,key,&records),Error.None)
    xr,_:=ddc_output_put(&a,{x})
    yr,_:=ddc_output_put(&a,{y,x})
    roots:=[2]store.Hash{records[0].output_root,records[1].output_root}
    testing.expect(t,len(records)==2 && slice.contains(roots[:],xr) && slice.contains(roots[:],yr) && hash_less(roots[0],roots[1]))

    z:=store.Hash{0=3}
    listed,le:=ddc_output_put(&a,{z,y,x,y,z,x})
    objects,ge:=ddc_output_get(&a,listed,context.temp_allocator)
    testing.expect(t,le==.None && ge==.None && len(objects)==3 && objects[0]==z && objects[1]==x && objects[2]==y,"the result first, then the others sorted, each once")
    _,e=ddc_output_put(&a,{})
    testing.expect_value(t,e,Error.Invalid_Argument)
    _,e=ddc_output_put(&a,{x,{}})
    testing.expect_value(t,e,Error.Invalid_Argument)
    many:=make([]store.Hash,DDC_OUTPUT_MAX+1,context.temp_allocator)
    for &m,i in many {m=store.Hash{0=1,1=u8(i),2=u8(i>>8),3=u8(i>>16)}}
    _,e=ddc_output_put(&a,many)
    testing.expect_value(t,e,Error.Too_Large)
    Case :: struct {head:DDC_Output_Head,listed:[]store.Hash,cut:int}
    good:=DDC_Output_Head{magic=KAI_MAGIC,count=3}
    cases:=[]Case{
        {head=good,listed={z,x,y}},
        {head={magic=KAI_MAGIC,count=0}},
        {head={magic=KAI_MAGIC,count=DDC_OUTPUT_MAX+1},listed={z,x,y}},
        {head=good,listed={z,x}},
        {head=good,listed={z,x,y,y}},
        {head=good,listed={z,y,x}},
        {head=good,listed={z,x,x}},
        {head=good,listed={z,x,z}},
        {head=good,listed={z,{},y}},
        {head={magic=KAI_MAGIC,reserved=1,count=3},listed={z,x,y}},
        {head=good,listed={z,x,y},cut=1},
    }
    for c,i in cases {
        w:=writer_make(context.temp_allocator)
        write_value(&w,c.head)
        for l in c.listed {write_value(&w,l)}
        _,de:=ddc_output_decode(w.data[:len(w.data)-c.cut],context.temp_allocator)
        testing.expectf(t,(de==.None)==(i==0),"case %d decodes %v",i,de)
    }
}

// The beacon of a device reads as that device only with the org's secret,
// in its bucket or one next to it; to anyone else, tags of one device in two
// buckets, or of two orgs, share nothing.
@(test)
lan_beacon_tags_are_unlinkable :: proc(t:^testing.T) {
    secret,other:[32]u8
    for &b,i in secret {b=u8(i)}
    for &b,i in other {b=u8(i)+100}
    devices:=[3]Dh_Key{{0=1},{0=2},{0=3}}
    now:=i64(1_800_000_000)
    beacon:=beacon_make(&secret,devices[1],4242,now)
    device,port,found:=beacon_read(&secret,devices[:],beacon[:],now)
    testing.expect(t,found && device==1 && port==4242)
    _,_,found=beacon_read(&secret,devices[:],beacon[:],now+BEACON_BUCKET_SECONDS)
    testing.expect(t,found,"a clock one bucket ahead still reads it")
    _,_,found=beacon_read(&secret,devices[:],beacon[:],now+3*BEACON_BUCKET_SECONDS)
    testing.expect(t,!found)
    _,_,found=beacon_read(&other,devices[:],beacon[:],now)
    testing.expect(t,!found,"another org's secret reads nothing")
    _,_,found=beacon_read(&secret,devices[2:],beacon[:],now)
    testing.expect(t,!found)

    later:=beacon_make(&secret,devices[1],4242,now+BEACON_BUCKET_SECONDS)
    elsewhere:=beacon_make(&other,devices[1],4242,now)
    b0,b1,b2:=(^Beacon)(&beacon[0]),(^Beacon)(&later[0]),(^Beacon)(&elsewhere[0])
    shared :: proc(a,b:[BEACON_TAG]u8) -> int {
        n:=0
        for x,i in a {
            if x==b[i] {n+=1}
        }
        return n
    }
    testing.expect(t,shared(b0.org_tag,b1.org_tag)<4 && shared(b0.dev_tag,b1.dev_tag)<4,"a new bucket is a new tag")
    testing.expect(t,shared(b0.org_tag,b2.org_tag)<4 && shared(b0.dev_tag,b2.dev_tag)<4)
    same_bucket:=beacon_make(&secret,devices[2],4242,now)
    testing.expect(t,(^Beacon)(&same_bucket[0]).org_tag==b0.org_tag && (^Beacon)(&same_bucket[0]).dev_tag!=b0.dev_tag)
}

// The beacons' secret changes whenever someone leaves who could read them: a
// member removed, a device of a member revoked, a node removed.
@(test)
the_discovery_secret_rotates_when_a_member_device_or_node_goes :: proc(t:^testing.T) {
    o:Test_Org
    test_org_make(t,&o)
    defer test_org_destroy(&o)
    laptop:=test_device(t,&o.bob)
    node:=identity_make()
    node_dh,_:=net.dh_key()
    _,e:=log_append(&o.org,.Node_Add,body_make(Node_Add_Body{node=node.key,dh=Dh_Key(node_dh.public),modes={.Seed}}),&o.alice.devices[0],20)
    testing.expect_value(t,e,Error.None)
    refold :: proc(t:^testing.T,o:^Test_Org) -> [32]u8 {
        org_fold_destroy(&o.fold)
        test_users_destroy(o.folds[:])
        test_users_fold(t,{&o.alice,&o.bob,&o.carol},o.folds[:],o.users[:])
        testing.expect_value(t,org_fold(&o.fold,&o.org,o.users[:]),Error.None)
        return org_discovery(&o.fold)
    }
    before:=refold(t,&o)
    Case :: struct {name:string,log:^Log,type:Entry_Type,body:[]u8,author:^Identity}
    cases:=[]Case{
        {"a device of a member revoked",&o.bob.log,.Device_Revoke,revoke_body(o.bob.devices[laptop].key),&o.bob.devices[0]},
        {"a node removed",&o.org,.Node_Remove,body_make(Node_Remove_Body{node=node.key}),&o.alice.devices[0]},
        {"a member removed",&o.org,.Member_Remove,body_make(Subject_Body{subject=o.carol.log.id}),&o.alice.devices[0]},
    }
    for c,i in cases {
        _,e=log_append(c.log,c.type,c.body,c.author,i64(30+i))
        testing.expect_value(t,e,Error.None)
        after:=refold(t,&o)
        testing.expectf(t,after!=before,"%s rotates the secret",c.name)
        before=after
    }
}

// The relay tells cone NATs to punch, the lower key first, and relays the
// rest; it forwards a sealed datagram unchanged between admitted devices,
// within each sender's byte quota, which refills with time.
@(test)
relay_quota_and_forwarding :: proc(t:^testing.T) {
    r:Relay
    relay_init(&r,1000,1500)
    defer relay_destroy(&r)
    a,b,c:=Dh_Key{0=1},Dh_Key{0=2},Dh_Key{0=3}
    testing.expect(t,relay_admit(&r,a,0)==.None && relay_admit(&r,b,0)==.None && relay_admit(&r,c,0)==.None)
    cone:=net.address_ip4(203,0,113,5,40000)
    relay_observe(&r,b,0,cone)
    relay_observe(&r,b,1,cone)
    relay_observe(&r,a,0,net.address_ip4(198,51,100,7,50000))
    relay_observe(&r,a,1,net.address_ip4(198,51,100,7,50000))
    relay_observe(&r,c,0,net.address_ip4(192,0,2,9,1000))
    relay_observe(&r,c,1,net.address_ip4(192,0,2,9,1001))
    testing.expect(t,relay_nat(&r,a)==.Cone && relay_nat(&r,c)==.Symmetric && relay_nat(&r,Dh_Key{0=9})==.Unknown)
    plan,ok:=relay_rendezvous(&r,b,a,1)
    testing.expect(t,ok && !plan.relay && plan.initiator==a && plan.responder==b && plan.initiator_target==cone && plan.at>1)
    plan,ok=relay_rendezvous(&r,a,c,1)
    testing.expect(t,ok && plan.relay,"a symmetric NAT is relayed, not punched")

    datagram:[1000]u8
    for &x,i in datagram {x=u8(i*7)}
    envelope:[RELAY_ENVELOPE+1000]u8
    wrapped:=relay_wrap(b,datagram[:],envelope[:])
    to,out,forwarded:=relay_forward(&r,a,wrapped,0)
    testing.expect(t,forwarded && to==b && slice.equal(out,datagram[:]))
    _,_,forwarded=relay_forward(&r,a,wrapped,0)
    testing.expect(t,!forwarded,"past the quota")
    _,_,forwarded=relay_forward(&r,c,wrapped,0)
    testing.expect(t,forwarded,"each sender has its own quota")
    _,_,forwarded=relay_forward(&r,a,wrapped,0.6)
    testing.expect(t,forwarded,"the quota refills")
    _,_,forwarded=relay_forward(&r,Dh_Key{0=9},wrapped,1)
    testing.expect(t,!forwarded,"a device not admitted sends nothing")
    stranger:=relay_wrap(Dh_Key{0=9},datagram[:],envelope[:])
    _,_,forwarded=relay_forward(&r,b,stranger,5)
    testing.expect(t,!forwarded)
    relay_remove(&r,b)
    wrapped=relay_wrap(b,datagram[:],envelope[:])
    _,_,forwarded=relay_forward(&r,a,wrapped,10)
    testing.expect(t,!forwarded,"a removed device is not reached")
    h:=base.Hostile{state=5}
    for _ in 0..<200 {
        size:=int(base.hostile_next(&h)%len(envelope))
        for &x in envelope[:size] {x=u8(base.hostile_next(&h))}
        relay_forward(&r,a,envelope[:size],20)
    }
}

// A project's log of 100,000 moves folds in one walk and appends in place:
// its time is printed, not held to a budget, and the append after it writes
// one leaf of the pages, the branches above it and the index.
@(test)
a_log_of_100000_entries_folds_and_appends_in_bounds :: proc(t:^testing.T) {
    N :: 100_000
    folder:=base.test_folder(t,"kai-log-scale")
    if folder=="" {return}
    s,se:=store.open(strings.concatenate({folder,"/store"},context.temp_allocator))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    ctx:=test_heads(&o.org)[0]
    // Signatures are not what the fold reads: the entries carry zero ones, as a local read takes them.
    started:=time.tick_now()
    parent:=o.project.items[0].address
    zero_signature:Signature
    from:Revision
    for i in 0..<N {
        to:Revision
        to[0],to[1],to[2],to[3]=u8(i),u8(i>>8),u8(i>>16),1
        d:=Draft{type=.Bookmark_Move,log_id=o.project.id,parents={parent},org_ctx=ctx,time=i64(100+i),body=move_body("main",i==0?{}:{from},to)}
        from=to
        w,e:=entry_unsigned(&d,o.bob.devices[0].key,.Ed25519,context.temp_allocator)
        if !testing.expect_value(t,e,Error.None) {return}
        write_bytes(&w,zero_signature[:])
        _,ae:=log_add(&o.project,w.data[:],false)
        if !testing.expect_value(t,ae,Error.None) {return}
        parent=store.address_of_bytes(w.data[:])
        free_all(context.temp_allocator)
    }
    built:=time.tick_since(started)
    started=time.tick_now()
    f:Project_Fold
    testing.expect_value(t,project_fold(&f,&o.project,&o.fold),Error.None)
    folded:=time.tick_since(started)
    defer project_fold_destroy(&f)
    valid:=0
    for v in f.valid {valid+=int(v)}
    testing.expect_value(t,valid,N+1)
    testing.expect_value(t,len(f.bookmarks),1)
    started=time.tick_now()
    _,e:=log_save(&s,&o.project)
    testing.expect_value(t,e,Error.None)
    saved,whole:=time.tick_since(started),o.project.written
    test_move(t,&o.project,"main",{0=0xff},&o.bob.devices[0],ctx,200_000,nil,{from})
    _,e=log_save(&s,&o.project)
    testing.expect_value(t,e,Error.None)
    fmt.printfln("kai: a project's log of %d entries: built in %v, folded in %v, saved whole in %v (%d bytes); one append then writes %d bytes",N,built,folded,saved,whole,o.project.written)
    testing.expect(t,o.project.written<(LOG_PAGE_ENTRIES+2)*1024,"an append writes one leaf, its branches and the index")
}
