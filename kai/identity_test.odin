package kai

import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"

// A user of the tests: a recovery key, devices with their X25519 keys, and
// the User_Log.
@(private)
Test_User :: struct {
    recovery:Identity,
    devices:[4]Identity,
    dhs:[4]net.Dh_Key,
    count:int,
    log:Log,
}

@(private)
test_user :: proc(t:^testing.T,u:^Test_User,name:string,loc:=#caller_location) {
    u^={recovery=identity_make()}
    log_init(&u.log,{},context.allocator)
    u.devices[0]=identity_make()
    u.dhs[0],_=net.dh_key()
    u.count=1
    body:=body_make(User_Genesis_Body{recovery=u.recovery.key,device=u.devices[0].key,dh=Dh_Key(u.dhs[0].public),proof=device_proof(&u.devices[0],transmute([32]u8)u.recovery.key)},transmute([]u8)name)
    _,e:=log_append(&u.log,.User_Genesis,body,&u.recovery,1)
    testing.expect_value(t,e,Error.None,loc=loc)
}

// Adds a device, linked by the first.
@(private)
test_device :: proc(t:^testing.T,u:^Test_User,loc:=#caller_location) -> int {
    k:=u.count
    u.devices[k]=identity_make()
    u.dhs[k],_=net.dh_key()
    u.count+=1
    body:=body_make(Device_Add_Body{device=u.devices[k].key,dh=Dh_Key(u.dhs[k].public),proof=device_proof(&u.devices[k],transmute([32]u8)u.log.id)},transmute([]u8)string("laptop"))
    _,e:=log_append(&u.log,.Device_Add,body,&u.devices[0],2)
    testing.expect_value(t,e,Error.None,loc=loc)
    return k
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

// A device revoked with a horizon at the org's head H keeps what it signed
// before H; whatever it signs after the revocation counts nowhere, though it
// names old parents and an old time: in the org's log (outside H), in its own
// User_Log (outside the revocation's causal past), and after H.
@(test)
revocation_horizon_rejects_backdated_entries :: proc(t:^testing.T) {
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
    horizon:=slice.clone(test_heads(&org),context.temp_allocator)
    user_before_revoke:=slice.clone(test_heads(&alice.log),context.temp_allocator)

    _,e=log_append(&alice.log,.Device_Revoke,revoke_body(alice.devices[stolen].key,{{log_id=org.id,heads=horizon}}),&alice.devices[0],30)
    testing.expect_value(t,e,Error.None)

    // The thief backdates: an old parent and an old time, in the org's log and in alice's.
    backdated:=test_entry(t,&org,.Member_Add,body_make(Member_Body{user=carol.log.id,role=.Admin}),&alice.devices[stolen],{genesis},15)
    after:=test_entry(t,&org,.Project_Add,body_make(Project_Add_Body{project=store.Hash{0=1},public=true}),&alice.devices[stolen],horizon,40)
    rogue:=identity_make()
    rogue_dh,_:=net.dh_key()
    rogue_add:=test_entry(t,&alice.log,.Device_Add,body_make(Device_Add_Body{device=rogue.key,dh=Dh_Key(rogue_dh.public),proof=device_proof(&rogue,transmute([32]u8)alice.log.id)},transmute([]u8)string("rogue")),&alice.devices[stolen],user_before_revoke,25)

    folds:[3]User_Fold
    users:[3]^User_Fold
    test_users_fold(t,{&alice,&bob,&carol},folds[:],users[:])
    defer test_users_destroy(folds[:])
    a:=users[0]
    testing.expect(t,user_device_index(a,rogue.key)<0,"a device the revoked one added after the revocation is no device")
    testing.expect(t,!a.valid[log_find(&alice.log,rogue_add)])
    testing.expect(t,!user_device_active(a,alice.devices[stolen].key) && user_device_active(a,alice.devices[0].key))

    f:Org_Fold
    testing.expect_value(t,org_fold(&f,&org,users[:]),Error.None)
    defer org_fold_destroy(&f)
    testing.expect(t,f.valid[log_find(&org,horizon[0])],"what the device signed inside its horizon stays")
    testing.expect(t,!f.valid[log_find(&org,backdated)],"a backdated entry is outside the horizon")
    testing.expect(t,!f.valid[log_find(&org,after)])
    testing.expect_value(t,org_role(&f,bob.log.id),Role.Writer)
    testing.expect_value(t,org_role(&f,carol.log.id),Role.None)
    testing.expect_value(t,len(f.projects),0)

    // A revocation that names no horizon for the org leaves none of the device's entries there.
    alice2:Test_User
    test_user(t,&alice2,"alice2");defer log_destroy(&alice2.log)
    second:=test_device(t,&alice2)
    org2:Log
    test_org(t,&org2,&alice2);defer log_destroy(&org2)
    log_append(&org2,.Member_Add,body_make(Member_Body{user=bob.log.id,role=.Reader}),&alice2.devices[second],20)
    log_append(&alice2.log,.Device_Revoke,revoke_body(alice2.devices[second].key,{}),&alice2.recovery,30)
    folds2:[2]User_Fold
    users2:[2]^User_Fold
    test_users_fold(t,{&alice2,&bob},folds2[:],users2[:])
    defer test_users_destroy(folds2[:])
    f2:Org_Fold
    testing.expect_value(t,org_fold(&f2,&org2,users2[:]),Error.None)
    defer org_fold_destroy(&f2)
    testing.expect_value(t,org_role(&f2,bob.log.id),Role.None)
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

// Pairing a second device and a member makes the entries that link them.
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
    {
        i,r:Pair
        pair_init(&i,true,laptop_dh,ticket,Dh_Key(alice.dhs[0].public))
        pair_init(&r,false,alice.dhs[0],ticket)
        r_info:=pair_info_encode({mode=.Device,log_id=alice.log.id,device=alice.devices[0].key},"phone",&info[0])
        // I learns the user log from R's info, and proves its key over it.
        i_info:=pair_info_encode({mode=.Device,device=laptop.key,proof=device_proof(&laptop,transmute([32]u8)alice.log.id)},"laptop",&info[1])
        run(t,&i,&r,r_info,i_info,&buffer)
        _,e:=pair_approve_device(&r,&alice.log,&alice.devices[0],5)
        testing.expect_value(t,e,Error.None)
        f:User_Fold
        testing.expect_value(t,user_fold(&f,&alice.log),Error.None)
        testing.expect(t,user_device_active(&f,laptop.key) && user_dh_active(&f,Dh_Key(laptop_dh.public)))
        user_fold_destroy(&f)
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
    _,e:=log_append(&o.project,.Project_Genesis,body_make(Project_Genesis_Body{org=o.org.id,public=b8(public)},transmute([]u8)string("game")),&o.alice.devices[0],10)
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
    changed,flagged,ae2:=ddc_accept(&a,&o.fold,key,copied,nil,1)
    testing.expect(t,ae2==.None && changed && !flagged)

    // A reader's record is skipped; alice's other output is kept beside bob's.
    ddc_publish(&b,o.org.id,&o.carol.devices[0],key,{y},nil,2)
    set,_=store.ref_get(&b,ddc_namespace(o.org.id,&ns),store.hex(key,&name))
    copied=test_copy(t,&b,&a,set,.DDC_Set)
    changed,flagged,_=ddc_accept(&a,&o.fold,key,copied,nil,2)
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
    good:=DDC_Output_Head{magic=KAI_MAGIC,version=DDC_VERSION,count=3}
    cases:=[]Case{
        {head=good,listed={z,x,y}},
        {head={magic=KAI_MAGIC,version=DDC_VERSION,count=0}},
        {head={magic=KAI_MAGIC,version=DDC_VERSION,count=DDC_OUTPUT_MAX+1},listed={z,x,y}},
        {head=good,listed={z,x}},
        {head=good,listed={z,x,y,y}},
        {head=good,listed={z,y,x}},
        {head=good,listed={z,x,x}},
        {head=good,listed={z,x,z}},
        {head=good,listed={z,{},y}},
        {head={magic=KAI_MAGIC,version=DDC_VERSION-1,count=3},listed={z,x,y}},
        {head={magic=KAI_MAGIC,version=DDC_VERSION,reserved=1,count=3},listed={z,x,y}},
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
