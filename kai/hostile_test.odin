package kai

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:exchange"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"

@(private="file")
hostile_store :: proc(t:^testing.T,folder,name:string) -> (s:store.Store,ok:bool) {
    e:store.Error
    s,e=store.open(strings.concatenate({folder,"/",name},context.temp_allocator))
    return s,testing.expect_value(t,e,store.Error.None)
}

// An entry of a Member_Add by alice of a random user: any number of them,
// each with its own address.
@(private="file")
hostile_member :: proc(t:^testing.T,org:^Log,alice:^Test_User,time:i64) -> store.Hash {
    address,e:=log_append(org,.Member_Add,body_make(Member_Body{user=random_id(Log_Id),role=.Reader}),&alice.devices[0],time)
    testing.expect_value(t,e,Error.None)
    return address
}

// A peer's log whose page holds an entry with a bad signature where this
// end's holds one the peer withholds (a removal), as many entries each, next
// to a page with an entry that is new: the merge takes the new entry and
// saves, and the log opened again holds what this end verified, the withheld
// entry and not the forged one. A peer's page never stands for one of its own.
@(test)
a_forged_log_page_never_stands_for_a_verified_one :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-page")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    alice:Test_User
    test_user(t,&alice,"alice");defer log_destroy(&alice.log)
    org:Log
    test_org(t,&org,&alice);defer log_destroy(&org)
    // Past LOG_PAGE_ENTRIES the root is a branch: each first byte of an address has its leaf.
    for k in 0..<LOG_PAGE_ENTRIES+40 {hostile_member(t,&org,&alice,i64(100+k))}
    withheld:=hostile_member(t,&org,&alice,1000)
    _,se:=log_save(&s,&org)
    testing.expect_value(t,se,Error.None)

    // The forged entry: a well-formed one whose signature is broken, ground
    // until its address falls in the leaf of the withheld one.
    forged:[]u8
    good:=org.items[1].bytes
    grind: for at in len(good)-size_of(Signature)..<len(good) {
        for flip in 1..<256 {
            bytes:=slice.clone(good,context.temp_allocator)
            bytes[at]~=u8(flip)
            if store.address_of_bytes(bytes)[0]==withheld[0] {
                forged=bytes
                break grind
            }
        }
    }
    if !testing.expect(t,forged!=nil,"a forged entry lands in the withheld one's leaf") {return}
    fresh:store.Hash
    peer:Log
    log_init(&peer,org.id);defer log_destroy(&peer)
    for item in org.items {
        if item.address!=withheld {log_add(&peer,item.bytes,false)}
    }
    _,fe:=log_add(&peer,forged,false)
    testing.expect_value(t,fe,Error.None)
    for {
        fresh=hostile_member(t,&peer,&alice,2000+i64(len(peer.items)))
        if fresh[0]!=withheld[0] {break}
    }
    peer_address,pe:=log_save_in(&s,&peer,"test-peer")
    testing.expect_value(t,pe,Error.None)

    mine:Log
    log_init(&mine);defer log_destroy(&mine)
    testing.expect_value(t,log_open(&s,&mine,org.id,.Org),Error.None)
    changed,me:=log_merge(&s,&mine,peer_address)
    testing.expect(t,changed && me==.None,"the peer's new entry is taken")
    testing.expect_value(t,store.commit(&s),store.Error.None)
    opened:Log
    log_init(&opened);defer log_destroy(&opened)
    testing.expect_value(t,log_open(&s,&opened,org.id,.Org),Error.None)
    testing.expect(t,log_find(&opened,withheld)>=0,"the entry the peer withheld stays")
    testing.expect(t,log_find(&opened,store.address_of_bytes(forged))<0,"the forged entry never enters")
    testing.expect(t,log_find(&opened,fresh)>=0 && len(opened.items)==len(org.items)+1)
}

// A scope only admins read: a writer who does not read it adds no epoch to
// its keyring and no overlay record a peer takes, as it may for a scope
// writers read; and an epoch whose envelopes are not here asks for a rotation.
@(test)
scope_writes_need_the_role_that_reads_the_scope :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-scope")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    peer,peer_ok:=hostile_store(t,folder,"peer")
    if !peer_ok {return}
    defer store.close(&peer)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    admins,writers:=random_id(Scope_Id),random_id(Scope_Id)
    scope_add(t,&o,admins,.Admin,false,20,"secrets/**")
    scope_add(t,&o,writers,.Writer,false,21,"shared/**")
    refold(t,&o)
    alice:=device_of(&o.alice,0)
    kl:Log
    log_init(&kl);defer log_destroy(&kl)
    kf:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&s,o.project.id,admins,&alice,22),Error.None)
    defer keyring_fold_destroy(&kf)
    testing.expect_value(t,kf.epoch,u32(1))
    _,ae:=log_append(&kl,.Epoch_Add,body_make(Epoch_Add_Body{epoch=2,devices=1,envelopes=random_id(store.Hash)}),&o.bob.devices[0],23,{},org_context(&o.fold,o.bob.log.id))
    testing.expect_value(t,ae,Error.None)
    testing.expect_value(t,keyring_refold(&kf),Error.None)
    testing.expect(t,kf.epoch==1 && !kf.valid[len(kl.items)-1],"a writer who does not read the scope adds no epoch")

    for scope,k in ([2]Scope_Id{admins,writers}) {
        r:=Overlay_Record{project=o.project.id,scope=scope,commit=random_id(Revision),epoch=1,tree_root=random_id(store.Hash),time=24}
        address,we:=overlay_record_write(&s,&o.bob.devices[0],&r,{},0)
        testing.expect_value(t,we,Error.None)
        copied:=test_copy(t,&s,&peer,address,.Overlay_Record)
        ns:[len(OVERLAY_PREFIX)+64+1+32]u8
        name:[64]u8
        _,changed,e:=overlay_accept(&peer,&o.fold,overlay_namespace(o.project.id,scope,&ns),store.hex(r.commit,&name),copied)
        if k==0 {
            testing.expect_value(t,e,Error.Unauthorized)
        } else {
            testing.expect(t,e==.None && changed,"a writer writes a scope writers read")
        }
    }

    // The peer holds the keyring's log and not its envelopes: a write waits.
    pl:Log
    log_init(&pl);defer log_destroy(&pl)
    for item in kl.items[:1+1] {log_add(&pl,item.bytes,true)}
    pf:Keyring_Fold
    testing.expect_value(t,keyring_fold(&pf,&pl,&o.fold,&peer),Error.None)
    defer keyring_fold_destroy(&pf)
    testing.expect(t,pf.epoch==1 && keyring_needs_rotation(&pf),"envelopes that are not here do not pass for read")
}

// A checkout refuses to write under a folder that is a link, so nothing
// outside the root is written or removed; a link where a file goes is
// replaced, never followed; and a tree never writes what Kai keeps of the
// workspace, whatever the case of its names.
@(test)
a_checkout_writes_nothing_outside_its_root_or_into_kai :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-checkout")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    root:=strings.concatenate({folder,"/work"},context.temp_allocator)
    outside:=strings.concatenate({folder,"/outside"},context.temp_allocator)
    os.make_directory_all(root)
    os.make_directory_all(outside)
    keep:=strings.concatenate({outside,"/keep.txt"},context.temp_allocator)
    testing.expect(t,os.write_entire_file(keep,transmute([]u8)string("mine"))==nil)
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&s,identity_make()),Error.None) {return}
    defer workspace_close(&w)
    file :: proc(t:^testing.T,s:^store.Store,path,text:string) -> File {
        address,e:=store.put(s,transmute([]u8)text)
        testing.expect_value(t,e,store.Error.None)
        return {path=path,kind=.File,address=address,size=u64(len(text))}
    }
    tree :: proc(t:^testing.T,s:^store.Store,files:..File) -> store.Hash {
        root,e:=tree_build(s,files)
        testing.expect_value(t,e,Error.None)
        return root
    }
    kai_before:=make([dynamic][]u8,context.temp_allocator)
    for name in ([]string{"workspace","lock"}) {
        bytes,_:=os.read_entire_file(strings.concatenate({root,"/.mirai/kai/",name},context.temp_allocator),context.temp_allocator)
        append(&kai_before,bytes)
    }

    // What Kai keeps, by any case, is no file of the project.
    for prefix in ([]string{".mirai/kai/",".MIRAI/Kai/",".Mirai/KAI/"}) {
        target:=tree(t,&s,file(t,&s,strings.concatenate({prefix,"lock"},context.temp_allocator),"forged"),file(t,&s,strings.concatenate({prefix,"workspace"},context.temp_allocator),"forged"),file(t,&s,"a.txt","alpha"))
        testing.expect_value(t,checkout(&w,target),Error.None)
    }
    for name,k in ([]string{"workspace","lock"}) {
        bytes,_:=os.read_entire_file(strings.concatenate({root,"/.mirai/kai/",name},context.temp_allocator),context.temp_allocator)
        testing.expectf(t,name=="workspace" || slice.equal(bytes,kai_before[k]),"the tree writes no %s of Kai",name)
        testing.expect(t,!strings.contains(string(bytes),"forged"))
    }
    a,_:=os.read_entire_file(strings.concatenate({root,"/a.txt"},context.temp_allocator),context.temp_allocator)
    testing.expect_value(t,string(a),"alpha")

    linked:=strings.concatenate({root,"/linked"},context.temp_allocator)
    leaf:=strings.concatenate({root,"/leaf"},context.temp_allocator)
    if os.symlink(outside,linked)!=nil || os.symlink(outside,leaf)!=nil {
        fmt.println("a_checkout_writes_nothing_outside_its_root_or_into_kai: no symbolic links here, the link cases are skipped")
        return
    }
    under:=tree(t,&s,file(t,&s,"a.txt","alpha"),file(t,&s,"linked/evil.txt","escaped"),file(t,&s,"linked/keep.txt","replaced"))
    testing.expect_value(t,checkout(&w,under),Error.Unsupported)
    kept,_:=os.read_entire_file(keep,context.temp_allocator)
    testing.expect(t,string(kept)=="mine" && !os.exists(strings.concatenate({outside,"/evil.txt"},context.temp_allocator)),"nothing is written through a linked folder")
    // A file where the link was: the link goes, what it points at stays.
    over:=tree(t,&s,file(t,&s,"a.txt","alpha"),file(t,&s,"leaf","a file now"))
    testing.expect_value(t,checkout(&w,over),Error.None)
    info,le:=os.lstat(leaf,context.temp_allocator)
    testing.expect(t,le==nil && info.type==.Regular,"the link is replaced by the file")
    kept,_=os.read_entire_file(keep,context.temp_allocator)
    testing.expect_value(t,string(kept),"mine")
}

// A device secret that does not read now (its file is there and this user
// may not read it) is an error, never replaced by a new one.
@(test)
an_unreadable_device_secret_is_kept :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-secret")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    first,e:=machine_identity(&s)
    testing.expect_value(t,e,Error.None)
    path:=strings.concatenate({s.root,"/",IDENTITY_FILE},context.temp_allocator)
    before,_:=os.read_entire_file(path,context.temp_allocator)
    if os.change_mode(path,{})!=nil {return}
    defer os.change_mode(path,{.Read_User,.Write_User})
    if _,readable:=os.read_entire_file(path,context.temp_allocator);readable==nil {
        fmt.println("an_unreadable_device_secret_is_kept: this user reads a file of no rights, skipped")
        return
    }
    _,again:=machine_identity(&s)
    testing.expect_value(t,again,Error.Io)
    os.change_mode(path,{.Read_User,.Write_User})
    after,_:=os.read_entire_file(path,context.temp_allocator)
    testing.expect(t,slice.equal(before,after),"the secret is the one made first")
    second,se:=machine_identity(&s)
    testing.expect(t,se==.None && second.key==first.key)
}

// Strangers that connect anonymously, or with a key the logs do not place,
// take at most AGENT_UNPROVEN slots: a member still connects.
@(test)
strangers_leave_room_for_members :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-slots")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project}) {log_save(&s,l)}
    STRANGERS :: AGENT_PEERS
    sim:net.Sim_Network
    net.sim_network_init(&sim,{seed=5,endpoints=2+STRANGERS,packets=1<<16})
    defer net.sim_network_destroy(&sim)
    a:=new(Agent)
    defer free(a)
    if !testing.expect_value(t,agent_init(a,{store=&s,identity=o.alice.devices[0],dh=o.alice.dhs[0],user=o.alice.log.id,org=o.org.id,host_seed=7,server=net.sim_endpoint_transport(&sim,0)},nil),Error.None) {return}
    defer agent_close(a)
    channels:=exchange.CHANNEL_DESCS
    hosts:=new([STRANGERS+1]net.Host)
    defer free(hosts)
    org:=o.org.id
    for k in 0..=STRANGERS {
        dh,_:=net.dh_key()
        if k==STRANGERS {dh=o.bob.dhs[0]}
        testing.expect_value(t,net.host_init(&hosts[k],{mode=.Client,transport=net.sim_endpoint_transport(&sim,1+k),channels=channels[:],protocol_id=AGENT_PROTOCOL,seed=u64(50+k),identity=dh}),net.Error.None)
    }
    defer for &h in hosts {net.host_destroy(&h)}
    now:=0.0
    run :: proc(sim:^net.Sim_Network,a:^Agent,hosts:[]net.Host,now:^f64,seconds:f64) {
        for end:=now^+seconds;now^<end; {
            now^+=0.001
            net.sim_network_advance(sim,now^)
            agent_update(a,now^)
            for &h in hosts {
                net.host_update(&h,now^)
                for _ in net.host_poll(&h) {}
            }
        }
    }
    for k in 0..<STRANGERS {
        claim:=k%2==0?nil:org[:]
        net.host_connect_identity(&hosts[k],net.Key(o.alice.dhs[0].public),claim,net.address_memory(0))
    }
    run(&sim,a,hosts[:],&now,2)
    unproven,admitted:=0,0
    for p in a.peers {unproven+=int(agent_unproven(p))}
    testing.expectf(t,unproven>0 && unproven<=AGENT_UNPROVEN,"strangers hold %d slots",unproven)
    net.host_connect_identity(&hosts[STRANGERS],net.Key(o.alice.dhs[0].public),org[:],net.address_memory(0))
    run(&sim,a,hosts[:],&now,2)
    for p in a.peers {admitted+=int(p.used && p.dh==Dh_Key(o.bob.dhs[0].public) && p.class==.Member)}
    testing.expect_value(t,admitted,1)
}

// A rendezvous message is taken once: the same bytes again within the skew,
// or an older one, are not; and the cache of keys keeps the ones used last.
@(test)
rendezvous_messages_are_taken_once :: proc(t:^testing.T) {
    device,node:=new(Runner),new(Runner)
    defer free(device)
    defer free(node)
    dm,nm:Machine
    dm.dh,_=net.dh_key()
    nm.dh,_=net.dh_key()
    for x in ([2]^Runner{device,node}) {x.keys=make([dynamic]Shared_Key,0,RUNNER_KEYS)}
    defer delete(device.keys)
    defer delete(node.keys)
    device.machine,node.machine=&dm,&nm
    o:=new(Runner_Org)
    defer free(o)
    o.peers=make([dynamic]Runner_Peer)
    defer delete(o.peers)
    other:=Dh_Key{0=7}
    append(&o.peers,Runner_Peer{dh=Dh_Key(nm.dh.public),node=true,modes={.Relay},attempt=-1},Runner_Peer{dh=other,attempt=-1})
    append(&device.orgs,o)
    defer delete(device.orgs)
    plan :: proc(node:^Runner,device:Dh_Key,other:Dh_Key,time:i64) -> [size_of(Z_Head)+size_of(Z_Plan)+Z_MAC]u8 {
        out:[size_of(Z_Head)+size_of(Z_Plan)+Z_MAC]u8
        head:=Z_Head{frame=FRAME_RENDEZVOUS,type=.Plan,from=Dh_Key(node.machine.dh.public),time=time}
        z:=Z_Plan{peer=other}
        copy(out[:],(cast([^]u8)&head)[:size_of(Z_Head)])
        copy(out[size_of(Z_Head):],(cast([^]u8)&z)[:size_of(Z_Plan)])
        mac:=keyed_hash(runner_shared(node,device).key[:],out[:size_of(Z_Head)+size_of(Z_Plan)])
        copy(out[size_of(Z_Head)+size_of(Z_Plan):],mac[:Z_MAC])
        return out
    }
    from:=net.address_loopback(7)
    now:=time.now()._nsec
    first:=plan(node,Dh_Key(dm.dh.public),other,now)
    older:=plan(node,Dh_Key(dm.dh.public),other,now-1000)
    device.now=1
    runner_frame(device,from,first[:],0)
    testing.expect(t,o.peers[1].planned==1,"a plan is taken")
    for replay in ([][]u8{first[:],older[:]}) {
        o.peers[1].planned=0
        runner_frame(device,from,replay,0)
        testing.expect(t,o.peers[1].planned==0,"a replayed or older plan is not")
    }
    stranger:=plan(node,Dh_Key(dm.dh.public),other,now+1)
    stranger[2]~=1 // its sender is no node of the device's orgs: no X25519 is spent on it
    keys:=len(device.keys)
    runner_frame(device,from,stranger[:],0)
    testing.expect(t,len(device.keys)==keys,"a sender no org knows makes no key")

    // Past RUNNER_KEYS the least recently used key goes, not the whole cache.
    clear(&node.keys)
    for k in 0..<RUNNER_KEYS+1 {
        node.now=f64(k)
        dh,_:=net.dh_key()
        runner_shared(node,Dh_Key(dh.public))
        if k==RUNNER_KEYS-1 {
            node.now+=0.5
            runner_shared(node,node.keys[0].dh)
        }
    }
    kept:=false
    for x in node.keys {kept||=x.used==f64(RUNNER_KEYS-1)+0.5}
    testing.expect(t,len(node.keys)==RUNNER_KEYS && kept,"a key used last stays")
}

// Corrupt, truncated and random log indexes, pages and overlay records are
// refused or read as what they are, never trusted, under bounds checks.
@(test)
hostile_logs_and_overlay_records_are_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hostile-records")
    if folder=="" {return}
    s,ok:=hostile_store(t,folder,"store")
    if !ok {return}
    defer store.close(&s)
    alice:Test_User
    test_user(t,&alice,"alice");defer log_destroy(&alice.log)
    test_device(t,&alice)
    index,se:=log_save(&s,&alice.log)
    testing.expect_value(t,se,Error.None)
    head,_,he:=log_index_read(&s,index)
    testing.expect_value(t,he,Error.None)
    page,pe:=object_get(&s,head.root,.Log_Page,context.temp_allocator)
    testing.expect_value(t,pe,Error.None)
    index_bytes,ie:=object_get(&s,index,.Log,context.temp_allocator)
    testing.expect_value(t,ie,Error.None)
    r:=Overlay_Record{seq=1,project=random_id(Log_Id),scope=random_id(Scope_Id),commit=random_id(Revision),epoch=1,tree_root=random_id(store.Hash),author=alice.devices[0].key,objects={random_id(store.Hash)},time=1}
    record,re:=overlay_record_encode(&r,&alice.devices[0],context.temp_allocator)
    testing.expect_value(t,re,Error.None)
    h:=base.Hostile{state=17}
    for round in 0..<600 {
        for good,kind in ([3][]u8{page,index_bytes,record}) {
            size:=int(base.hostile_next(&h)%u64(len(good)+8))
            bytes:=make([]u8,size,context.temp_allocator)
            copy(bytes,good)
            switch round%3 {
            case 0: for &b in bytes {b=u8(base.hostile_next(&h))}
            case 1: if size>0 {bytes[base.hostile_next(&h)%u64(size)]~=u8(1+base.hostile_next(&h)%255)}
            }
            switch kind {
            case 0:
                address,e:=object_put(&s,.Log_Page,bytes)
                if e!=.None {continue}
                w:=writer_make(context.temp_allocator)
                forged:=head
                forged.root=address
                write_value(&w,forged)
                for x in alice.log.heads {write_bytes(&w,alice.log.items[x].address[:])}
                at,_:=object_put(&s,.Log,w.data[:])
                l:Log
                log_init(&l)
                _,_=log_load(&s,&l,at,true)
                log_destroy(&l)
            case 1:
                at,e:=object_put(&s,.Log,bytes)
                if e!=.None {continue}
                l:Log
                log_init(&l)
                _,_=log_load(&s,&l,at,true)
                _,_,_=log_entry_get(&s,at,alice.log.id)
                missing:=make([dynamic]store.Hash,context.temp_allocator)
                _=log_pages_missing(&s,at,&missing)
                log_destroy(&l)
            case 2:
                decoded,e:=overlay_record_decode(bytes)
                if e==.None && size!=len(record) {testing.expectf(t,false,"a record of %d bytes of %d reads",size,len(record))}
                _=decoded
            }
        }
    }
    // Every cut of a page or a record is refused.
    for n in 0..<len(record) {
        _,e:=overlay_record_decode(record[:n])
        testing.expectf(t,e!=.None,"a record cut at %d reads",n)
    }
    for n in 0..<len(page) {
        address,_:=object_put(&s,.Log_Page,page[:n])
        w:=writer_make(context.temp_allocator)
        forged:=head
        forged.root=address
        write_value(&w,forged)
        for x in alice.log.heads {write_bytes(&w,alice.log.items[x].address[:])}
        at,_:=object_put(&s,.Log,w.data[:])
        l:Log
        log_init(&l)
        _,e:=log_load(&s,&l,at,true)
        testing.expectf(t,e!=.None || len(l.items)<len(alice.log.items),"a page cut at %d reads whole",n)
        log_destroy(&l)
    }
}
