package kai

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "mirai:std/base"
import "mirai:store"

@(private="file")
Machine :: struct {
    s:store.Store,
    team:Team,
    agent:Agent,
    running:bool,
}

@(private="file")
machine_open :: proc(t:^testing.T,m:^Machine,folder,name:string) -> bool {
    e:store.Error
    m.s,e=store.open(strings.concatenate({folder,"/",name},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return false}
    if !testing.expect_value(t,team_open(&m.team,&m.s),Error.None) {return false}
    return testing.expect_value(t,team_profile_set(&m.team,name,strings.concatenate({name,"-laptop"},context.temp_allocator)),Error.None)
}

@(private="file")
machine_start :: proc(t:^testing.T,m:^Machine,port:int,node:=false) -> bool {
    m.running=testing.expect_value(t,agent_start(&m.agent,&m.team,{port=port,host="127.0.0.1",node=node}),Error.None)
    return m.running
}

@(private="file")
machine_close :: proc(m:^Machine) {
    if m.running {agent_stop(&m.agent)}
    team_close(&m.team)
    store.close(&m.s)
}

// Waits up to seconds for done.
@(private="file")
until :: proc(seconds:f64,data:rawptr,done:proc(data:rawptr) -> bool) -> bool {
    started:=time.tick_now()
    for time.duration_seconds(time.tick_since(started))<seconds {
        if done(data) {return true}
        time.sleep(5*time.Millisecond)
    }
    return done(data)
}

// A change of files (path, text) in s, signed by identity.
@(private="file")
change_of :: proc(t:^testing.T,s:^store.Store,identity:^Identity,files:[][2]string) -> Revision {
    list:=make([dynamic]File,context.temp_allocator)
    for f in files {
        address,e:=store.put(s,transmute([]u8)f[1])
        testing.expect_value(t,e,store.Error.None)
        append(&list,File{path=f[0],kind=.File,address=address,size=u64(len(f[1]))})
    }
    slice.sort_by(list[:],proc(a,b:File) -> bool {return a.path<b.path})
    tree,te:=tree_build(s,list[:])
    testing.expect_value(t,te,Error.None)
    c:=Change{id=random_id(Change_Id),tree=tree,author=identity.key,created=1,written=1,description="work"}
    revision,ce:=change_put(s,&c,identity)
    testing.expect_value(t,ce,Error.None)
    testing.expect_value(t,store.commit(s),store.Error.None)
    return revision
}

// The handshake proves each end's device key over the transcript both see,
// with X25519 and ML-KEM-768 both in its keys: a byte changed in any message,
// a responder that is not the key expected, or a man in the middle that runs
// a handshake with each end, ends it; an invite's proof holds only under its
// secret. Sealed frames open only in order and only unchanged.
@(test)
noise_pq_handshake_proves_both_keys_and_refuses_tampering :: proc(t:^testing.T) {
    alice,bob,mallory:=identity_make(),identity_make(),identity_make()
    secret:[32]u8
    crypto.rand_bytes(secret[:])
    Case :: struct {name:string,message:int,at:int,expect:Key,ok:bool}
    cases:=[]Case{
        {"clean",0,0,{},true},
        {"the responder expected",0,0,bob.key,true},
        {"another responder expected",0,0,mallory.key,false},
        {"message 1, its X25519 key",1,3,{},false},
        {"message 1, its ML-KEM key",1,40,{},false},
        {"message 2, its X25519 key",2,5,{},false},
        {"message 2, its sealed ML-KEM ciphertext",2,100,{},false},
        {"message 2, the responder's proof",2,NOISE_MSG2-30,{},false},
        {"message 3, the initiator's proof",3,10,{},false},
    }
    for c in cases {
        i,r:Handshake
        handshake_init(&i,true,alice)
        handshake_init(&r,false,bob)
        i.secret=secret
        m1:[NOISE_MSG1]u8
        m2:[NOISE_MSG2]u8
        m3:[NOISE_MSG3]u8
        ok:=handshake_write_1(&i,m1[:])
        if c.message==1 {m1[c.at]~=1}
        ok&&=handshake_read_1(&r,m1[:],m2[:])
        if c.message==2 {m2[c.at]~=1}
        ok&&=handshake_read_2(&i,m2[:],m3[:],c.expect)
        if c.message==3 {m3[c.at]~=1}
        ok&&=handshake_read_3(&r,m3[:])
        testing.expectf(t,ok==c.ok,"%s: the handshake %v",c.name,ok?"held":"failed")
        if ok && c.ok {
            testing.expect(t,i.peer==bob.key && r.peer==alice.key,"each end knows the other's key")
            testing.expect(t,handshake_invited(r.proof,r.proved,secret),"the invite's proof holds under its secret")
            other:=secret
            other[0]~=1
            testing.expect(t,!handshake_invited(r.proof,r.proved,other),"and under no other")
            is,ir:=handshake_split(&i)
            rs,rr:=handshake_split(&r)
            plain:=[]u8{1,2,3,4,5}
            sealed:[5+NOISE_TAG]u8
            opened:[5]u8
            cipher_seal(&is,plain,sealed[:])
            testing.expect(t,cipher_open(&rr,sealed[:],opened[:]) && slice.equal(opened[:],plain),"a frame opens on the other end")
            cipher_seal(&rs,plain,sealed[:])
            sealed[2]~=1
            testing.expect(t,!cipher_open(&ir,sealed[:],opened[:]),"a changed frame does not open")
            cipher_seal(&is,plain,sealed[:])
            cipher_seal(&is,plain,sealed[:])
            testing.expect(t,!cipher_open(&rr,sealed[:],opened[:]),"a frame out of order does not open")
        }
        handshake_destroy(&i)
        handshake_destroy(&r)
    }
    // Mallory runs a handshake with each end and relays their messages.
    i,ma,mb,r:Handshake
    handshake_init(&i,true,alice)
    handshake_init(&ma,false,mallory)
    handshake_init(&mb,true,mallory)
    handshake_init(&r,false,bob)
    m1,n1:[NOISE_MSG1]u8
    m2,n2:[NOISE_MSG2]u8
    m3,n3:[NOISE_MSG3]u8
    handshake_write_1(&i,m1[:])
    handshake_read_1(&ma,m1[:],m2[:])
    handshake_write_1(&mb,n1[:])
    handshake_read_1(&r,n1[:],n2[:])
    // Mallory cannot make bob's proof over alice's transcript: alice sees mallory's key, or bob's forged.
    testing.expect(t,!handshake_read_2(&i,m2[:],m3[:],bob.key),"a man in the middle does not pass for the expected key")
    copy(m2[len(m2)-size_of(Key)-size_of(Signature)-NOISE_TAG:],n2[len(n2)-size_of(Key)-size_of(Signature)-NOISE_TAG:])
    testing.expect(t,!handshake_read_2(&i,m2[:],m3[:],{}),"the other end's proof does not open on this transcript")
    _=n3
    for h in ([]^Handshake{&i,&ma,&mb,&r}) {handshake_destroy(h)}
}

// An org's record holds only when signed by who may: the first by an admin it
// lists, then an admin of the version before for any change, a writer only
// when the members stay; a reader, a stranger or a changed byte is refused.
// Two admins that sign the same version apart are settled alike by every
// peer, and a version older than the one held is not taken.
@(test)
org_records_hold_only_when_signed_by_who_may :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-org-records")
    if folder=="" {return}
    s,e:=store.open(strings.concatenate({folder,"/store"},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return}
    defer store.close(&s)
    peer,pe:=store.open(strings.concatenate({folder,"/peer"},context.temp_allocator))
    if !testing.expect_value(t,pe,store.Error.None) {return}
    defer store.close(&peer)
    ana,ben,cal,eve,stranger:=identity_make(),identity_make(),identity_make(),identity_make(),identity_make()
    members:=[]Member{{ana.key,.Admin,"Ana","Mac",""},{ben.key,.Admin,"Ben","PC",""},{cal.key,.Writer,"Cal","PC",""},{eve.key,.Reader,"Eve","Mac",""}}
    slice.sort_by(members,proc(a,b:Member) -> bool {return key_less(a.key,b.key)})
    o:=Org{id=random_id(Org_Id),version=1,name="studio",members=members}
    first,we:=org_write(&s,&o,&ana,1)
    testing.expect_value(t,we,Error.None)
    expect_refused(t,object_get(&s,first,.Org,context.temp_allocator) or_else nil,proc(b:[]u8) -> Error {_,e:=org_decode(b,context.temp_allocator);return e},"an org record")
    held,_,_:=org_head(&s,o.id,context.temp_allocator)
    Case :: struct {name:string,by:^Identity,members:[]Member,repos:[]Org_Repo,ok:bool}
    repos:=[]Org_Repo{{id={0=1},name="game"}}
    fewer:=slice.clone(members[:3],context.temp_allocator)
    cases:=[]Case{
        {"a writer adds a repository",&cal,members,repos,true},
        {"a writer removes a member",&cal,fewer,repos,false},
        {"a reader adds a repository",&eve,members,repos,false},
        {"a stranger adds a repository",&stranger,members,repos,false},
        {"an admin removes a member",&ben,fewer,repos,true},
    }
    // A writer adds repositories and changes nothing held: not the org's name, nor a repository's name or visibility.
    with_repo:=held
    with_repo.repos=repos
    flipped:=[]Org_Repo{{id={0=1},name="game",public=true}}
    renamed_repo:=[]Org_Repo{{id={0=1},name="other"}}
    two_repos:=[]Org_Repo{{id={0=1},name="game"},{id={0=2},name="tools"}}
    Writer_Case :: struct {name:string,org_name:string,repos:[]Org_Repo,ok:bool}
    writer_cases:=[]Writer_Case{
        {"a writer adds a second repository","studio",two_repos,true},
        {"a writer renames the org","renamed",repos,false},
        {"a writer makes a repository public","studio",flipped,false},
        {"a writer renames a repository","studio",renamed_repo,false},
        {"a writer removes a repository","studio",nil,false},
    }
    for c in writer_cases {
        next:=with_repo
        next.version,next.prev,next.signer,next.name,next.repos=with_repo.version+1,first,cal.key,c.org_name,c.repos
        bytes,ee:=org_encode(&next,&cal,context.temp_allocator)
        testing.expect_value(t,ee,Error.None)
        decoded,_:=org_decode(bytes,context.temp_allocator)
        testing.expectf(t,org_signs(&with_repo,&decoded)==c.ok,"%s: %v",c.name,!c.ok)
    }
    for c in cases {
        next:=held
        next.version,next.prev,next.signer,next.members,next.repos=held.version+1,first,c.by.key,c.members,c.repos
        bytes,ee:=org_encode(&next,c.by,context.temp_allocator)
        testing.expect_value(t,ee,Error.None)
        decoded,de:=org_decode(bytes,context.temp_allocator)
        testing.expect_value(t,de,Error.None)
        testing.expectf(t,org_signs(&held,&decoded)==c.ok,"%s: %v",c.name,!c.ok)
    }
    // Two admins sign version 2 apart; each peer takes the one of the lower address.
    v2a:=held
    v2a.version,v2a.prev,v2a.repos=2,first,repos
    a2,ae:=org_write(&s,&v2a,&ana,2)
    testing.expect_value(t,ae,Error.None)
    v2b:=held
    v2b.version,v2b.prev,v2b.name=2,first,"studio b"
    b_bytes:=org_encode_signed(t,&v2b,&ben)
    b2,_:=object_put(&s,.Org,b_bytes)
    changed,_,ce:=org_accept(&s,o.id,b2)
    testing.expect_value(t,ce,Error.None)
    _,head,_:=org_head(&s,o.id,context.temp_allocator)
    lower:=hash_less(b2,a2)?b2:a2
    testing.expect(t,head==lower && changed==(lower==b2),"of two versions 2 the lower address holds")
    // A peer that holds nothing takes the chain from the first record, and the same head.
    for x in ([]store.Hash{first,a2,b2}) {copy_object(t,&s,&peer,x)}
    _,need,me:=org_accept(&peer,o.id,a2)
    testing.expect(t,me==.None && need=={},"a peer walks back to the first record")
    org_accept(&peer,o.id,b2)
    _,peer_head,_:=org_head(&peer,o.id,context.temp_allocator)
    testing.expect(t,peer_head==lower,"every peer settles alike")
    // An older version is not taken, and a chain with a version that does not hold is refused.
    taken,_,_:=org_accept(&s,o.id,first)
    testing.expect(t,!taken,"a stale record is not taken")
    forged:=v2a
    forged.version,forged.prev,forged.signer=3,lower,eve.key
    forged_bytes:=org_encode_signed(t,&forged,&eve)
    forged_address,_:=object_put(&s,.Org,forged_bytes)
    _,_,fe:=org_accept(&s,o.id,forged_address)
    testing.expect_value(t,fe,Error.Unauthorized)
    _,missing_need,mne:=org_accept(&peer,o.id,forged_address)
    testing.expect(t,mne==.Missing && missing_need==forged_address,"a version not here is asked for")
    // Another first record under the same id, signed by a stranger and versions ahead, is refused.
    hijack:=Org{id=o.id,version=1,name="mine",members={{stranger.key,.Admin,"Mallory","box",""}}}
    hijack_bytes:=org_encode_signed(t,&hijack,&stranger)
    hijack_first,_:=object_put(&s,.Org,hijack_bytes)
    hijack_next:=hijack
    for v in 2..=9 {
        hijack_next.version,hijack_next.prev=u64(v),hijack_first
        b:=org_encode_signed(t,&hijack_next,&stranger)
        hijack_first,_=object_put(&s,.Org,b)
    }
    _,_,he2:=org_accept(&s,o.id,hijack_first)
    testing.expect_value(t,he2,Error.Unauthorized)
    _,still,_:=org_head(&s,o.id,context.temp_allocator)
    testing.expect(t,still==lower,"the head held stays")
    // An admin removed in a version cannot branch from before it and win by versions.
    _,removed_head,_:=org_head(&s,o.id,context.temp_allocator)
    current,_:=org_get(&s,removed_head,context.temp_allocator)
    without_ben:=current
    kept:=make([dynamic]Member,context.temp_allocator)
    for m in current.members {if m.key!=ben.key {append(&kept,m)}}
    without_ben.version,without_ben.prev,without_ben.members=current.version+1,removed_head,kept[:]
    removal,re2:=org_write(&s,&without_ben,&ana,10)
    testing.expect_value(t,re2,Error.None)
    fork:=current
    fork_prev:=removed_head
    for k in 0..<3 {
        fork.version,fork.prev,fork.name=current.version+1+u64(k),fork_prev,"ben's"
        b:=org_encode_signed(t,&fork,&ben)
        fork_prev,_=object_put(&s,.Org,b)
    }
    _,_,fe2:=org_accept(&s,o.id,fork_prev)
    testing.expect_value(t,fe2,Error.Unauthorized)
    _,after_fork,_:=org_head(&s,o.id,context.temp_allocator)
    testing.expect(t,after_fork==removal,"the removal holds against a longer branch of the removed admin")

    // Shared bookmarks: a writer's next seq is taken, a reader's or an older one is not.
    _,head_now,_:=org_head(&s,o.id,context.temp_allocator)
    now,_:=org_get(&s,head_now,context.temp_allocator)
    if org_repo(&now,{0=1})<0 {
        next:=now
        next.version,next.prev,next.repos=now.version+1,head_now,repos
        org_write(&s,&next,&ana,4)
        now=next
    }
    one,re:=repo_refs_publish(&s,&now,{0=1},&cal,{{"main",{0=9}}},5)
    testing.expect_value(t,re,Error.None)
    _,re=repo_refs_publish(&s,&now,{0=1},&eve,{{"main",{0=8}}},6)
    testing.expect_value(t,re,Error.Unauthorized)
    two,_:=repo_refs_publish(&s,&now,{0=1},&ana,{{"main",{0=7}}},7)
    old_taken,_:=repo_refs_accept(&s,&now,one)
    testing.expect(t,!old_taken,"an older record of the bookmarks is not taken")
    refs,refs_address,_:=repo_refs_head(&s,now.id,{0=1},context.temp_allocator)
    testing.expect(t,refs_address==two && refs.bookmarks[0].target==Revision{0=7},"the newest record holds")
    rb,_:=object_get(&s,two,.Repo_Refs,context.temp_allocator)
    expect_refused(t,rb,proc(b:[]u8) -> Error {_,e:=repo_refs_decode(b,context.temp_allocator);return e},"shared bookmarks")
}

@(private="file")
org_encode_signed :: proc(t:^testing.T,o:^Org,by:^Identity) -> []u8 {
    o.signer=by.key
    bytes,e:=org_encode(o,by,context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    return bytes
}

@(private="file")
copy_object :: proc(t:^testing.T,from,into:^store.Store,address:store.Hash) {
    o,e:=store.object_open(from,address)
    if !testing.expect_value(t,e,store.Error.None) {return}
    defer store.object_close(&o)
    bytes:=make([]u8,int(store.object_size(&o)),context.temp_allocator)
    store.object_read(&o,0,bytes)
    p,_:=store.put_begin(into)
    store.put_write(&p,bytes)
    store.put_finish(&p,store.object_meta(&o))
    store.commit(into)
}

// A closure is whole only when every chunk of every object is here: a file
// whose root arrived and part of whose chunks did not is missing, so a pull
// cut midway never reads as complete.
@(test)
a_closure_is_whole_only_when_every_chunk_is_here :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-closure-whole")
    if folder=="" {return}
    a,e:=store.open(strings.concatenate({folder,"/a"},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return}
    defer store.close(&a)
    b,be:=store.open(strings.concatenate({folder,"/b"},context.temp_allocator))
    if !testing.expect_value(t,be,store.Error.None) {return}
    defer store.close(&b)
    big:=make([]u8,4*store.CHUNK_MAX,context.temp_allocator)
    for &x in big {x=u8(rand.uint32())}
    identity:=identity_make()
    revision:=change_of(t,&a,&identity,{{"big.bin",string(big)},{"small.txt","hello"}})
    // Every chunk a holds, and which of them are leaves of big.bin.
    chunks:=make([dynamic]store.Hash,context.temp_allocator)
    present,missing:=make([dynamic]store.Hash,context.temp_allocator),make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(&a,{revision},&present,&missing)
    testing.expect(t,len(missing)==0 && len(present)>=4,"a holds its own closure whole")
    buffer:=scratch_make()
    leaves:=0
    for o in present {
        stack:=make([dynamic]store.Hash,context.temp_allocator)
        append(&stack,o)
        for len(stack)>0 {
            x:=pop(&stack)
            append(&chunks,x)
            bytes,_:=store.chunk_read(&a,x,buffer)
            n,ne:=store.node_parse(bytes)
            if ne!=.None {continue}
            for entry in n.entries {
                if n.level>0 {append(&stack,entry.address)} else {
                    append(&chunks,entry.address)
                    if entry.size>1000 {leaves+=1}
                }
            }
        }
    }
    testing.expect(t,leaves>=2,"big.bin is several chunks")
    // b takes every chunk but one leaf of big.bin.
    skipped:=false
    for x in chunks {
        bytes,_:=store.chunk_read(&a,x,buffer)
        if !skipped && len(bytes)>1000 {
            if _,ne:=store.node_parse(bytes);ne!=.None {
                skipped=true
                continue
            }
        }
        store.chunk_put(&b,x,bytes)
    }
    store.commit(&b)
    clear(&present)
    clear(&missing)
    closure_walk(&b,{revision},&present,&missing)
    testing.expect(t,len(missing)==1,"the file with a chunk short is missing, though its root is here")
    for x in chunks {
        bytes,_:=store.chunk_read(&a,x,buffer)
        store.chunk_put(&b,x,bytes)
    }
    store.commit(&b)
    clear(&missing)
    closure_walk(&b,{revision},nil,&missing)
    testing.expect(t,len(missing)==0,"whole once every chunk came")
}

// Two machines pair by a one-time invite over TCP and sync a repository: the
// invited one is a member with the invite's role, pulls the shared bookmarks
// and every object they reach, and a second use of the invite and a device of
// no org get nothing.
@(test)
two_machines_pair_by_invite_and_sync_over_tcp :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-pair-sync")
    if folder=="" {return}
    mac,pc,stranger:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&pc,folder,"Ben") || !machine_open(t,&stranger,folder,"Eve") {return}
    defer machine_close(&mac)
    defer machine_close(&pc)
    defer machine_close(&stranger)
    org,oe:=team_org_create(&mac.team,"studio")
    testing.expect_value(t,oe,Error.None)
    repo:=random_id(Repo_Id)
    testing.expect_value(t,team_repo_set(&mac.team,org,{id=repo,name="game"}),Error.None)
    files:=make([dynamic][2]string,context.temp_allocator)
    for k in 0..<40 {append(&files,[2]string{fmt.tprintf("assets/file%02d.txt",k),strings.repeat(fmt.tprintf("line %d\n",k),2000+k,context.temp_allocator)})}
    revision:=change_of(t,&mac.s,&mac.team.identity,files[:])
    testing.expect_value(t,team_publish(&mac.team,org,repo,{{"main",revision}}),Error.None)
    if !machine_start(t,&mac,0) || !machine_start(t,&pc,-1) || !machine_start(t,&stranger,-1) {return}
    address:=fmt.tprintf("127.0.0.1:%d",agent_port(&mac.agent))
    text,ie:=team_invite(&mac.team,org,.Writer,"",{address},context.temp_allocator)
    if !testing.expect_value(t,ie,Error.None) {return}
    joined,je:=agent_join(&pc.agent,text)
    if !testing.expectf(t,je==.None && joined==org,"the invite joins: %v %s",je,pc.agent.team.why) {return}
    o,_,_:=team_org(&pc.team,org)
    role,member:=org_role(&o,pc.team.identity.key)
    testing.expect(t,member && role==.Writer && o.members[org_member(&o,pc.team.identity.key)].name=="Ben","the joined device is a writer under its own name")
    // A link makes the repository one this machine keeps: its objects come whole.
    testing.expect_value(t,team_link(&pc.team,{local=random_id(Repo_Id),org=org,repo=repo}),Error.None)
    agent_changed(&pc.agent)
    Wait :: struct {s:^store.Store,revision:Revision}
    w:=Wait{&pc.s,revision}
    whole:=until(20,&w,proc(data:rawptr) -> bool {
        w:=(^Wait)(data)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        if !object_present(w.s,w.revision) {return false}
        closure_walk(w.s,{w.revision},nil,&missing)
        return len(missing)==0
    })
    testing.expect(t,whole,"the pulled repository is whole")
    refs,_,re:=repo_refs_head(&pc.s,org,repo,context.temp_allocator)
    testing.expect(t,re==.None && len(refs.bookmarks)==1 && refs.bookmarks[0].target==revision,"the shared bookmarks came")
    pulls:=make([dynamic]Pull,context.temp_allocator)
    agent_pulls(&pc.agent,&pulls)
    testing.expect(t,len(pulls)==1 && pulls[0].whole && pulls[0].chunks>0 && pulls[0].bytes>0,"the pull says how far it is")
    // The invite is used: a second device gets nothing with it.
    _,se:=agent_join(&stranger.agent,text)
    testing.expect(t,se==.Expired || se==.Unreachable || se==.Unauthorized,"a used invite admits nobody")
    _,_,sh:=team_org(&stranger.team,org)
    testing.expect_value(t,sh,Error.Missing)
}

// The throughput of a pull over loopback: KAI_BENCH_MB megabytes (16 unless
// set) of incompressible bytes in 1000 files, pulled by a second machine.
// Prints the seconds and MB/s.
@(test)
a_pull_over_loopback_runs_at_tcp_speed :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-bench")
    if folder=="" {return}
    megabytes:=16
    if text,ok:=os.lookup_env("KAI_BENCH_MB",context.temp_allocator);ok {megabytes,_=strconv.parse_int(text)}
    a,b:Machine
    if !machine_open(t,&a,folder,"Ana") || !machine_open(t,&b,folder,"Ben") {return}
    defer machine_close(&a)
    defer machine_close(&b)
    org,_:=team_org_create(&a.team,"studio")
    repo:=random_id(Repo_Id)
    team_repo_set(&a.team,org,{id=repo,name="game"})
    total:=megabytes<<20
    files:=make([dynamic][2]string,context.temp_allocator)
    for k in 0..<1000 {
        size:=total/1000
        bytes:=make([]u8,size)
        for &x in bytes {x=u8(rand.uint32())}
        append(&files,[2]string{fmt.tprintf("data/%04d.bin",k),string(bytes)})
    }
    revision:=change_of(t,&a.s,&a.team.identity,files[:])
    for f in files {delete(f[1])}
    team_publish(&a.team,org,repo,{{"main",revision}})
    if !machine_start(t,&a,0) || !machine_start(t,&b,-1) {return}
    text,_:=team_invite(&a.team,org,.Reader,"",{fmt.tprintf("127.0.0.1:%d",agent_port(&a.agent))},context.temp_allocator)
    if _,je:=agent_join(&b.agent,text);!testing.expect_value(t,je,Error.None) {return}
    started:=time.tick_now()
    team_link(&b.team,{local=random_id(Repo_Id),org=org,repo=repo})
    agent_changed(&b.agent)
    whole:=until(600,&b.agent,proc(data:rawptr) -> bool {
        pulls:=make([dynamic]Pull,context.temp_allocator)
        agent_pulls((^Agent)(data),&pulls)
        return len(pulls)==1 && pulls[0].whole
    })
    seconds:=time.duration_seconds(time.tick_since(started))
    testing.expect(t,whole,"the pull ends whole")
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(&b.s,{revision},nil,&missing)
    testing.expect(t,len(missing)==0,"every object is here")
    fmt.printfln("a_pull_over_loopback_runs_at_tcp_speed: %d MB in 1000 files in %.3f s, %.1f MB/s",megabytes,seconds,f64(megabytes)/seconds)
}

// A server whose record of the org is a version behind (a machine joined
// while it was off and the admin is off now) takes the newer record from the
// machine that dials it, and then serves it: the newcomer pulls the
// repository from the server alone.
@(test)
a_server_a_version_behind_learns_the_newcomer_from_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-behind")
    if folder=="" {return}
    mac,server,laptop:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&server,folder,"cloud") || !machine_open(t,&laptop,folder,"Cal") {return}
    defer machine_close(&mac)
    defer machine_close(&server)
    defer machine_close(&laptop)
    org,_:=vcs_org(t,&mac)
    repo:=random_id(Repo_Id)
    team_repo_set(&mac.team,org,{id=repo,name="game"})
    revision:=change_of(t,&mac.s,&mac.team.identity,{{"a.txt","the first version\n"}})
    team_publish(&mac.team,org,repo,{{"main",revision}})
    if !machine_start(t,&mac,0) || !machine_start(t,&server,0,node=true) || !machine_start(t,&laptop,-1) {return}
    mac_address:=fmt.tprintf("127.0.0.1:%d",agent_port(&mac.agent))
    node,_:=team_invite(&mac.team,org,.Node,"",{mac_address},context.temp_allocator)
    if _,e:=agent_join(&server.agent,node);!testing.expect_value(t,e,Error.None) {return}
    Whole :: struct {s:^store.Store,revision:Revision}
    w:=Whole{&server.s,revision}
    whole :: proc(data:rawptr) -> bool {
        w:=(^Whole)(data)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        if !object_present(w.s,w.revision) {return false}
        closure_walk(w.s,{w.revision},nil,&missing)
        return len(missing)==0
    }
    if !testing.expect(t,until(20,&w,whole),"the server keeps the repository") {return}
    // The server goes off; the laptop joins through the mac, which then goes off too.
    server_port:=agent_port(&server.agent)
    agent_stop(&server.agent)
    server.running=false
    invite,_:=team_invite(&mac.team,org,.Writer,"",{mac_address},context.temp_allocator)
    if _,e:=agent_join(&laptop.agent,invite);!testing.expect_value(t,e,Error.None) {return}
    agent_stop(&mac.agent)
    mac.running=false
    held,_,_:=team_org(&server.team,org)
    testing.expect(t,org_member(&held,laptop.team.identity.key)<0,"the server does not know the laptop yet")
    if !testing.expect_value(t,agent_start(&server.agent,&server.team,{port=server_port,host="127.0.0.1",node=true}),Error.None) {return}
    server.running=true
    team_link(&laptop.team,{local=random_id(Repo_Id),org=org,repo=repo})
    agent_changed(&laptop.agent)
    at:=Whole{&laptop.s,revision}
    testing.expect(t,until(30,&at,whole),"the laptop pulls from the server alone")
}

@(private="file")
vcs_org :: proc(t:^testing.T,m:^Machine) -> (Org_Id,Error) {
    id,e:=team_org_create(&m.team,"studio")
    testing.expect_value(t,e,Error.None)
    return id,e
}

// A web sign-in goes to the org's server alone: a member's machine at the
// address given proves another key, so the password never reaches it.
@(test)
a_web_sign_in_reaches_only_the_orgs_server :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-web-login")
    if folder=="" {return}
    mac,server,writer:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&server,folder,"cloud") || !machine_open(t,&writer,folder,"Eve") {return}
    defer machine_close(&mac)
    defer machine_close(&server)
    defer machine_close(&writer)
    org,_:=vcs_org(t,&mac)
    Heard :: struct {passwords:int}
    heard:Heard
    listen :: proc(data:rawptr,key:Key,name,password:string) -> bool {
        (^Heard)(data).passwords+=1
        return true
    }
    if !machine_start(t,&mac,0) {return}
    server.running=testing.expect_value(t,agent_start(&server.agent,&server.team,{port=0,host="127.0.0.1",node=true,public="127.0.0.1:1",web_login=listen,web_data=&heard}),Error.None)
    writer.running=testing.expect_value(t,agent_start(&writer.agent,&writer.team,{port=0,host="127.0.0.1",web_login=listen,web_data=&heard}),Error.None)
    if !server.running || !writer.running {return}
    mac_address:=fmt.tprintf("127.0.0.1:%d",agent_port(&mac.agent))
    node,_:=team_invite(&mac.team,org,.Node,"",{mac_address},context.temp_allocator)
    if _,e:=agent_join(&server.agent,node);!testing.expect_value(t,e,Error.None) {return}
    invite,_:=team_invite(&mac.team,org,.Writer,"",{mac_address},context.temp_allocator)
    if _,e:=agent_join(&writer.agent,invite);!testing.expect_value(t,e,Error.None) {return}
    writer_address:=fmt.tprintf("127.0.0.1:%d",agent_port(&writer.agent))
    e:=agent_web_login(&mac.agent,writer_address,"ana","a long password")
    testing.expect_value(t,e,Error.Unauthorized)
    testing.expect_value(t,heard.passwords,0)
    server_address:=fmt.tprintf("127.0.0.1:%d",agent_port(&server.agent))
    testing.expect_value(t,agent_web_login(&mac.agent,server_address,"ana","a long password"),Error.None)
    testing.expect_value(t,heard.passwords,1)
}

// A handshake that fails leaves the accepted socket open and its caller's:
// it is closed once, by whoever accepted it.
@(test)
a_failed_handshake_leaves_the_accepted_socket_to_its_caller :: proc(t:^testing.T) {
    listener,le:=net.listen_tcp({net.IP4_Loopback,0})
    if !testing.expect(t,le==nil,"listens") {return}
    defer net.close(listener)
    bound,_:=net.bound_endpoint(listener)
    client,ce:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,bound.port)
    if !testing.expect(t,ce==nil,"dials") {return}
    defer net.close(client)
    socket,remote,ae:=net.accept_tcp(listener)
    if !testing.expect(t,ae==nil,"accepts") {return}
    garbage:[NOISE_MSG1]u8
    net.send_tcp(client,garbage[:])
    net.shutdown(client,.Send)
    c,e:=conn_accept(socket,remote,identity_make())
    testing.expect(t,c==nil && e==.Unauthorized,"the handshake fails")
    testing.expect(t,net.set_option(socket,.TCP_Nodelay,true)==nil,"the socket is still open")
    net.close(socket)
}

// An agent that stops while a dial to an address that never answers runs
// returns at once, and that dial ends before it does.
@(test)
an_agent_stops_while_a_dial_hangs :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-stop-dial")
    if folder=="" {return}
    m:Machine
    if !machine_open(t,&m,folder,"Ana") {return}
    defer machine_close(&m)
    // A documentation address (TEST-NET-1): nothing answers it.
    m.running=testing.expect_value(t,agent_start(&m.agent,&m.team,{port=-1,peers={"192.0.2.1:7350"}}),Error.None)
    if !m.running {return}
    Dialing :: struct {a:^Agent}
    d:=Dialing{&m.agent}
    testing.expect(t,until(5,&d,proc(data:rawptr) -> bool {
        a:=(^Dialing)(data).a
        sync.mutex_lock(&a.lock)
        defer sync.mutex_unlock(&a.lock)
        return a.dials>0
    }),"the dial runs")
    started:=time.tick_now()
    agent_stop(&m.agent)
    m.running=false
    testing.expectf(t,time.tick_since(started)<time.Second,"the agent stops in %v",time.tick_since(started))
    testing.expect_value(t,m.agent.dials,0)
}

// A peer that asks and never reads is cut off once what it asked passes
// REQUESTS_BYTES_MAX, instead of growing what the agent holds for it.
@(test)
a_peer_that_asks_and_never_reads_is_cut_off :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-requests")
    if folder=="" {return}
    mac,pc:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&pc,folder,"Ben") {return}
    defer machine_close(&mac)
    defer machine_close(&pc)
    org,_:=vcs_org(t,&mac)
    if !machine_start(t,&mac,0) || !machine_start(t,&pc,-1) {return}
    address:=fmt.tprintf("127.0.0.1:%d",agent_port(&mac.agent))
    invite,_:=team_invite(&mac.team,org,.Reader,"",{address},context.temp_allocator)
    if _,e:=agent_join(&pc.agent,invite);!testing.expect_value(t,e,Error.None) {return}
    c,e:=conn_dial(address,pc.team.identity,mac.team.identity.key)
    if !testing.expect_value(t,e,Error.None) {return}
    defer conn_free(c)
    head:=transmute([2]u8)u16le(WANT_MAX)
    wants:=make([]store.Hash,WANT_MAX,context.temp_allocator)
    for &w in wants {crypto.rand_bytes(w[:])}
    o:=org
    sent:=0
    for sent<400 && conn_send(c,.Want,o[:],head[:],slice.to_bytes(wants)) {sent+=1}
    // What it was sent, then the end: never an answer to each want.
    buffer:=make([]u8,FRAME_MAX+NOISE_TAG,context.temp_allocator)
    net.set_option(c.socket,.Receive_Timeout,10*time.Second)
    lacks:=0
    for {
        kind,_,ok:=conn_receive(c,buffer)
        if !ok {break}
        if kind==.Lack {lacks+=1}
    }
    testing.expectf(t,lacks<sent,"the agent cut the connection: %d wants, %d answered",sent,lacks)
}

// What a joining machine names itself is checked before the invite is spent:
// a Join without a device name leaves the invite for a good one.
@(test)
a_bad_join_does_not_spend_the_invite :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-bad-join")
    if folder=="" {return}
    mac,pc:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&pc,folder,"Ben") {return}
    defer machine_close(&mac)
    defer machine_close(&pc)
    org,_:=vcs_org(t,&mac)
    if !machine_start(t,&mac,0) || !machine_start(t,&pc,-1) {return}
    address:=fmt.tprintf("127.0.0.1:%d",agent_port(&mac.agent))
    invite,_:=team_invite(&mac.team,org,.Writer,"",{address},context.temp_allocator)
    token,_:=invite_parse(invite,context.temp_allocator)
    c,e:=conn_dial(address,pc.team.identity,token.key,token.secret)
    if !testing.expect_value(t,e,Error.None) {return}
    body:=make([dynamic]u8,context.temp_allocator)
    append(&body,..o_bytes(&org))
    write_text(&body,"Ben")
    write_text(&body,"")
    write_text(&body,"")
    conn_send(c,.Join,body[:])
    buffer:=make([]u8,FRAME_MAX+NOISE_TAG,context.temp_allocator)
    net.set_option(c.socket,.Receive_Timeout,5*time.Second)
    for {
        kind,_,ok:=conn_receive(c,buffer)
        if !ok || kind==.Bye || kind==.Welcome {
            testing.expect(t,kind!=.Welcome,"a nameless device is not welcomed")
            break
        }
    }
    conn_free(c)
    joined,je:=agent_join(&pc.agent,invite)
    testing.expectf(t,je==.None && joined==org,"the invite still joins: %v %s",je,pc.agent.team.why)
}

@(private="file")
o_bytes :: proc(org:^Org_Id) -> []u8 {return org[:]}

// What a machine takes from a peer is committed, and derived data is taken
// only whole: a set whose output is not all there sets no ref on a server,
// one whose output came does, and both those refs and the shared bookmarks a
// member that keeps nothing whole takes read from another handle of its store
// at once.
@(test)
what_a_server_takes_is_whole_and_committed :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-ddc-whole")
    if folder=="" {return}
    mac,server,pc:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&server,folder,"cloud") || !machine_open(t,&pc,folder,"Ben") {return}
    defer machine_close(&mac)
    defer machine_close(&server)
    defer machine_close(&pc)
    org,_:=vcs_org(t,&mac)
    if !machine_start(t,&mac,0) || !machine_start(t,&server,-1,node=true) || !machine_start(t,&pc,-1) {return}
    address:=fmt.tprintf("127.0.0.1:%d",agent_port(&mac.agent))
    node,_:=team_invite(&mac.team,org,.Node,"",{address},context.temp_allocator)
    if _,e:=agent_join(&server.agent,node);!testing.expect_value(t,e,Error.None) {return}
    reader,_:=team_invite(&mac.team,org,.Reader,"",{address},context.temp_allocator)
    if _,e:=agent_join(&pc.agent,reader);!testing.expect_value(t,e,Error.None) {return}
    // A set whose output names an object the mac does not have, and one whole.
    lacking,whole:store.Hash
    crypto.rand_bytes(lacking[:])
    crypto.rand_bytes(whole[:])
    missing:store.Hash
    crypto.rand_bytes(missing[:])
    present,_:=store.put(&mac.s,transmute([]u8)string("a derived result"))
    _,de:=ddc_publish(&mac.s,org,&mac.team.identity,lacking,{missing},1)
    testing.expect_value(t,de,Error.None)
    _,we:=ddc_publish(&mac.s,org,&mac.team.identity,whole,{present},1)
    testing.expect_value(t,we,Error.None)
    store.commit(&mac.s)
    // A repository the server is told of and does not keep whole.
    repo:=random_id(Repo_Id)
    team_repo_set(&mac.team,org,{id=repo,name="game"})
    revision:=change_of(t,&mac.s,&mac.team.identity,{{"a.txt","one\n"}})
    team_publish(&mac.team,org,repo,{{"main",revision}})
    agent_changed(&mac.agent)
    Taken :: struct {s:^store.Store,org:Org_Id,key:store.Hash}
    w:=Taken{&server.s,org,whole}
    if !testing.expect(t,until(20,&w,proc(data:rawptr) -> bool {
        w:=(^Taken)(data)
        records:=make([dynamic]DDC_Record,context.temp_allocator)
        return ddc_lookup(w.s,w.org,w.key,&records)==.None
    }),"the whole set is taken") {return}
    records:=make([dynamic]DDC_Record,context.temp_allocator)
    testing.expect_value(t,ddc_lookup(&server.s,org,lacking,&records),Error.Missing)
    other,oe:=store.open(server.s.root)
    if !testing.expect_value(t,oe,store.Error.None) {return}
    defer store.close(&other)
    testing.expect_value(t,ddc_lookup(&other,org,whole,&records),Error.None)
    pc_other,pe:=store.open(pc.s.root)
    if !testing.expect_value(t,pe,store.Error.None) {return}
    defer store.close(&pc_other)
    Refs :: struct {s:^store.Store,org:Org_Id,repo:Repo_Id}
    r:=Refs{&pc_other,org,repo}
    testing.expect(t,until(20,&r,proc(data:rawptr) -> bool {
        r:=(^Refs)(data)
        _,_,e:=repo_refs_head(r.s,r.org,r.repo,context.temp_allocator)
        return e==.None
    }),"the shared bookmarks read from another handle")
}

// Two processes that make a machine's key at once end with the same one.
@(test)
a_machine_key_made_twice_at_once_is_one :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-secret-race")
    if folder=="" {return}
    for round in 0..<20 {
        Maker :: struct {s:store.Store,key:Key,e:Error}
        makers:[4]Maker
        root:=fmt.tprintf("%s/round%d",folder,round)
        for &m in makers {
            e:store.Error
            m.s,e=store.open(root)
            if !testing.expect_value(t,e,store.Error.None) {return}
        }
        threads:[4]^thread.Thread
        for &m,k in makers {
            // Each thread its own temp allocator, as each process has.
            c:=runtime.default_context()
            c.allocator=context.allocator
            threads[k]=thread.create_and_start_with_poly_data(&m,proc(m:^Maker) {
                defer thread_end()
                identity,e:=machine_identity(&m.s)
                m.key,m.e=identity.key,e
            },c)
        }
        for th in threads {
            thread.join(th)
            thread.destroy(th)
        }
        for &m in makers {
            testing.expect_value(t,m.e,Error.None)
            testing.expect(t,m.key==makers[0].key,"every maker has the same key")
            store.close(&m.s)
        }
    }
}

// A repository's name is a folder's on every system.
@(test)
repository_names_are_folder_names_everywhere :: proc(t:^testing.T) {
    Case :: struct {name:string,valid:bool}
    cases:=[]Case{
        {"game",true},{"My Game 2",true},{"juego-ñ",true},{"v1.2",true},
        {"",false},{".",false},{"..",false},{"a/b",false},{"a\\b",false},{"../up",false},
        {"c:",false},{"a*",false},{"a?",false},{"a|b",false},{"a<b",false},{"a\"b",false},
        {"end.",false},{"end ",false},{"CON",false},{"nul",false},{"com1",false},{"LPT9.txt",false},
        {"aux .x",false},{"COM",true},{"console",true},
        {"tab\there",false},{"nul\x00byte",false},{"del\x7f",false},
    }
    for c in cases {testing.expectf(t,repo_name_valid(c.name)==c.valid,"%q: valid %v",c.name,c.valid)}
    testing.expect(t,!name_valid("bell\x07"),"a member's name has no control character")
}

// An admin revokes the open invites of an org: one that leaked admits nobody,
// and those of another org stay.
@(test)
revoked_invites_admit_nobody :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-revoke")
    if folder=="" {return}
    mac,pc:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&pc,folder,"Ben") {return}
    defer machine_close(&mac)
    defer machine_close(&pc)
    org,_:=vcs_org(t,&mac)
    other,_:=team_org_create(&mac.team,"other")
    if !machine_start(t,&mac,0) || !machine_start(t,&pc,-1) {return}
    address:=fmt.tprintf("127.0.0.1:%d",agent_port(&mac.agent))
    leaked,_:=team_invite(&mac.team,org,.Writer,"",{address},context.temp_allocator)
    team_invite(&mac.team,org,.Reader,"",{address},context.temp_allocator)
    kept,_:=team_invite(&mac.team,other,.Writer,"",{address},context.temp_allocator)
    cleared,e:=team_invites_clear(&mac.team,org)
    testing.expect(t,e==.None && cleared==2,"both invites of the org are revoked")
    _,je:=agent_join(&pc.agent,leaked)
    testing.expect_value(t,je,Error.Expired)
    joined,ke:=agent_join(&pc.agent,kept)
    testing.expectf(t,ke==.None && joined==other,"the other org's invite still joins: %v %s",ke,pc.agent.team.why)
}

// A router on loopback that grants PCP 0.3 s after the first request: the
// agent says it is connecting, an invite's wait takes the router's address
// once it answers, and the views hear that it moved.
@(test)
an_agent_reaches_online_when_the_router_maps_its_port :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-reach")
    if folder=="" {return}
    Router :: struct {socket:net.UDP_Socket,stop:bool}
    r:=new(Router);defer free(r)
    socket,se:=net.make_bound_udp_socket(net.IP4_Loopback,0)
    if !testing.expect(t,se==nil) {return}
    r.socket=socket
    defer net.close(socket)
    net.set_option(socket,.Receive_Timeout,10*time.Millisecond)
    bound,_:=net.bound_endpoint(socket)
    router:=thread.create_and_start_with_poly_data(r,proc(r:^Router) {
        packet:[1200]u8
        first:time.Tick
        for !sync.atomic_load(&r.stop) {
            size,from,e:=net.recv_udp(r.socket,packet[:])
            if e!=nil || size!=60 || packet[0]!=2 || packet[1]!=1 || packet[4]|packet[5]|packet[6]|packet[7]==0 {continue}
            if first=={} {first=time.tick_now()}
            if time.tick_since(first)<300*time.Millisecond {continue}
            packet[1]=0x81
            packet[4],packet[5],packet[6],packet[7]=0,0,0x0e,0x10
            packet[42],packet[43]=0x43,0xe6
            for &b in packet[44:60] {b=0}
            packet[54],packet[55]=255,255
            packet[56],packet[57],packet[58],packet[59]=8,8,8,8
            net.send_udp(r.socket,packet[:60],from)
        }
    })
    defer {sync.atomic_store(&r.stop,true);thread.join(router);thread.destroy(router)}
    m:Machine
    if !machine_open(t,&m,folder,"Ana") {return}
    defer machine_close(&m)
    gateway:=fmt.tprintf("127.0.0.1:%d",bound.port)
    m.running=testing.expect_value(t,agent_start(&m.agent,&m.team,{port=0,host="127.0.0.1",portmap=true,gateway=gateway}),Error.None)
    if !m.running {return}
    reach,_:=agent_reach(&m.agent,context.temp_allocator)
    testing.expect_value(t,reach,Reach.Connecting)
    generation:=agent_generation(&m.agent)
    started:=time.tick_now()
    testing.expect_value(t,agent_reach_wait(&m.agent,1500*time.Millisecond),Reach.Online)
    testing.expectf(t,time.tick_since(started)<1500*time.Millisecond,"the wait ends when the router answers: %v",time.tick_since(started))
    at:string
    reach,at=agent_reach(&m.agent,context.temp_allocator)
    testing.expect(t,reach==.Online && at=="8.8.8.8:17382",at)
    addresses:=agent_addresses(&m.agent,context.temp_allocator)
    testing.expect(t,len(addresses)>=2 && addresses[0]=="8.8.8.8:17382","an invite carries the router's address first")
    Moved :: struct {a:^Agent,from:u64}
    moved:=Moved{&m.agent,generation}
    testing.expect(t,until(3,&moved,proc(data:rawptr) -> bool {
        x:=(^Moved)(data)
        return agent_generation(x.a)!=x.from
    }),"the views hear that the router mapped the port")
    // A router address that is no host:port is refused.
    bad:=Agent_Options{port=0,host="127.0.0.1",portmap=true,gateway="no router"}
    other:Agent
    testing.expect_value(t,agent_start(&other,&m.team,bad),Error.Invalid_Argument)
}

// A peer joined over TCP with no beacons remembers the inviter's dialed
// address, and the inviter remembers a listening joiner's address: when the
// inviter restarts on the same port and publishes a new change, the joiner
// reconnects automatically and pulls it whole.
@(test)
a_joined_peer_reconnects_after_the_inviter_restarts :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-reconnect")
    if folder=="" {return}
    mac,pc,box:Machine
    if !machine_open(t,&mac,folder,"Ana") || !machine_open(t,&pc,folder,"Ben") || !machine_open(t,&box,folder,"Cal") {return}
    defer machine_close(&mac)
    defer machine_close(&pc)
    defer machine_close(&box)
    org,_:=vcs_org(t,&mac)
    if !machine_start(t,&mac,0) || !machine_start(t,&pc,-1) || !machine_start(t,&box,0) {return}
    mac_port:=agent_port(&mac.agent)
    mac_addr:=fmt.tprintf("127.0.0.1:%d",mac_port)
    box_addr:=fmt.tprintf("127.0.0.1:%d",agent_port(&box.agent))

    inv_pc,_:=team_invite(&mac.team,org,.Writer,"",{mac_addr},context.temp_allocator)
    if _,je:=agent_join(&pc.agent,inv_pc);!testing.expectf(t,je==.None,"pc joins: %v %s",je,pc.agent.team.why) {return}
    testing.expect(t,slice.contains(team_peer_addresses(&pc.team,mac.team.identity.key),mac_addr),"joiner saves the inviter's dialed address")

    inv_box,_:=team_invite(&mac.team,org,.Writer,"",{mac_addr},context.temp_allocator)
    if _,je:=agent_join(&box.agent,inv_box);!testing.expectf(t,je==.None,"box joins: %v %s",je,box.agent.team.why) {return}
    testing.expect(t,slice.contains(team_peer_addresses(&mac.team,box.team.identity.key),box_addr),"inviter saves a listening joiner's address")
    agent_stop(&box.agent)
    box.running=false

    repo:=random_id(Repo_Id)
    team_repo_set(&mac.team,org,{id=repo,name="game"})
    v1:=change_of(t,&mac.s,&mac.team.identity,{{"a.txt","v1\n"}})
    team_publish(&mac.team,org,repo,{{"main",v1}})
    agent_changed(&mac.agent)
    team_link(&pc.team,{local=random_id(Repo_Id),org=org,repo=repo})
    agent_changed(&pc.agent)

    State :: struct {s:^store.Store,a:^Agent,rev:Revision}
    st:=State{&pc.s,&pc.agent,v1}
    if !testing.expect(t,until(15,&st,proc(data:rawptr) -> bool {
        x:=(^State)(data)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        closure_walk(x.s,{x.rev},nil,&missing)
        return len(missing)==0 && object_kind(x.s,x.rev)==.Change
    }),"pc pulls v1 before restart") {return}

    // Inviter stops completely; wait until pc drops the connection.
    agent_stop(&mac.agent)
    mac.running=false
    if !testing.expect(t,until(5,&st,proc(data:rawptr) -> bool {
        x:=(^State)(data)
        peers:=make([dynamic]Peer_Info,context.temp_allocator)
        agent_peers(x.a,&peers,context.temp_allocator)
        return len(peers)==0
    }),"pc notices the inviter stopped") {return}

    // Inviter restarts on the same port and publishes v2; pc reconnects on its own.
    if !machine_start(t,&mac,mac_port) {return}
    v2:=change_of(t,&mac.s,&mac.team.identity,{{"a.txt","v2 after restart\n"}})
    team_publish(&mac.team,org,repo,{{"main",v2}})
    agent_changed(&mac.agent)
    st.rev=v2
    testing.expect(t,until(25,&st,proc(data:rawptr) -> bool {
        x:=(^State)(data)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        closure_walk(x.s,{x.rev},nil,&missing)
        return len(missing)==0 && object_kind(x.s,x.rev)==.Change
    }),"pc reconnects after inviter restart and pulls v2 whole")
}

// Offline invite records (Invite_Grant, Invite_Claim, Admission) refuse
// hostile bytes, and org_signs enforces monotonic revoke_epoch for admins and
// immutable revoke_epoch for writers.
@(test)
offline_invite_records_enforce_signatures_and_revoke_epoch :: proc(t:^testing.T) {
    ana,cal,ben:=identity_make(),identity_make(),identity_make()
    members:=[]Member{{ana.key,.Admin,"Ana","Mac",""},{cal.key,.Writer,"Cal","PC",""}}
    slice.sort_by(members,proc(a,b:Member) -> bool {return key_less(a.key,b.key)})
    org:=random_id(Org_Id)
    base_org:=Org{id=org,version=1,revoke_epoch=2,name="studio",members=members}
    base_bytes:=org_encode_signed(t,&base_org,&ana)
    base_rec,_:=org_decode(base_bytes,context.temp_allocator)
    dummy_prev:=store.address_of_bytes(base_bytes)

    Epoch_Case :: struct {name:string,by:^Identity,epoch:u64,ok:bool}
    for c in ([]Epoch_Case{
        {"admin keeps revoke_epoch",&ana,2,true},
        {"admin bumps revoke_epoch",&ana,3,true},
        {"admin lowers revoke_epoch",&ana,1,false},
        {"writer keeps revoke_epoch",&cal,2,true},
        {"writer bumps revoke_epoch",&cal,3,false},
    }) {
        next:=base_rec
        next.version,next.prev,next.revoke_epoch=2,dummy_prev,c.epoch
        b:=org_encode_signed(t,&next,c.by)
        dec,de:=org_decode(b,context.temp_allocator)
        testing.expect_value(t,de,Error.None)
        testing.expectf(t,org_signs(&base_rec,&dec)==c.ok,"%s: expected %v",c.name,c.ok)
    }

    secret:[32]u8
    crypto.rand_bytes(secret[:])
    grant:=Invite_Grant{org=org,secret_hash=secret_digest(secret),role=.Writer,revoke_epoch=2,expires=time.now()._nsec+i64(time.Hour),signer=ana.key,name="Ben"}
    gb,ge:=invite_grant_encode(&grant,&ana,context.temp_allocator)
    testing.expect_value(t,ge,Error.None)
    claim:=Invite_Claim{org=org,secret=secret,key=ben.key,name="Ben",device="laptop"}
    cb,ce:=invite_claim_encode(&claim,&ben,context.temp_allocator)
    testing.expect_value(t,ce,Error.None)
    ab,ae:=admission_encode(gb,cb,context.temp_allocator)
    testing.expect_value(t,ae,Error.None)

    expect_refused(t,gb,proc(b:[]u8) -> Error {_,e:=invite_grant_decode(b);return e},"invite grant")
    expect_refused(t,cb,proc(b:[]u8) -> Error {_,e:=invite_claim_decode(b);return e},"invite claim")
    expect_refused(t,ab,proc(b:[]u8) -> Error {_,e:=admission_decode(b);return e},"offline admission")
}
