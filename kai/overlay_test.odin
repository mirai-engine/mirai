package kai

import "core:bytes"
import "core:crypto/mlkem"
import "core:fmt"
import "core:math/rand"
import "core:mem"
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
SECRET :: "kai-secret-7Qx2Vb9LmZ4pR8sT1wYc6NdF3hJ0aE5u"

@(private)
device_of :: proc(u:^Test_User,k:int) -> Overlay_Device {
    return {identity=u.devices[k],dh=Dh_Key(u.dhs[k].public),dh_secret=u.dhs[k].private,kem_seed=u.kems[k]}
}

@(private)
scope_add :: proc(t:^testing.T,o:^Test_Org,scope:Scope_Id,readers:Role,history:bool,time:i64,patterns:..string) {
    body:=body_make(Scope_Add_Body{project=o.project.id,scope=scope,readers=readers,history=b8(history),patterns=u8(len(patterns))},strings_tail(..patterns))
    _,e:=log_append(&o.org,.Scope_Add,body,&o.alice.devices[0],time)
    testing.expect_value(t,e,Error.None)
}

// Folds the users and the org again after their logs changed.
@(private)
refold :: proc(t:^testing.T,o:^Test_Org,keyrings:..^Keyring_Fold) {
    org_fold_destroy(&o.fold)
    test_users_destroy(o.folds[:])
    test_users_fold(t,{&o.alice,&o.bob,&o.carol},o.folds[:],o.users[:])
    testing.expect_value(t,org_fold(&o.fold,&o.org,o.users[:]),Error.None)
    for k in keyrings {testing.expect_value(t,keyring_refold(k),Error.None)}
}

@(private="file")
put_file :: proc(t:^testing.T,root,path:string,content:[]u8,loc:=#caller_location) {
    full:=strings.concatenate({root,"/",path},context.temp_allocator)
    if dir,_:=os.split_path(full);dir!="" {os.make_directory_all(dir)}
    testing.expect(t,os.write_entire_file(full,content)==nil,loc=loc)
    old:=time.time_add(time.now(),-time.Hour)
    testing.expect(t,os.change_times(full,old,old)==nil,loc=loc)
}

@(private="file")
folder :: proc(base_folder,name:string) -> string {
    path:=strings.concatenate({base_folder,"/",name},context.temp_allocator)
    os.make_directory_all(path)
    return path
}

// Whether any file under folder holds needle.
@(private="file")
bytes_under :: proc(folder:string,needle:[]u8) -> bool {
    listed,e:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if e!=nil {return false}
    for info in listed {
        #partial switch info.type {
        case .Directory:
            if bytes_under(info.fullpath,needle) {return true}
        case .Regular:
            content,_:=os.read_entire_file(info.fullpath,context.temp_allocator)
            if bytes.contains(content,needle) {return true}
        }
    }
    return false
}

@(private="file")
random_bytes :: proc(n:int) -> []u8 {
    b:=make([]u8,n,context.temp_allocator)
    for &c in b {c=u8(rand.uint32())}
    return b
}

@(private)
open_files :: proc(t:^testing.T,s:^store.Store,k:^Keyring_Fold,device:^Overlay_Device,commit:Revision) -> (files:map[string]string,error:Error) {
    o:Overlay
    if error=overlay_open(&o,s,k,device,commit,context.temp_allocator);error!=.None {return}
    defer overlay_close(&o)
    files=make(map[string]string,context.temp_allocator)
    for e in o.entries {
        content,fe:=overlay_file(&o,s,e.path,context.temp_allocator)
        testing.expect_value(t,fe,Error.None)
        files[strings.clone(e.path,context.temp_allocator)]=string(content)
    }
    return
}

// A workspace whose org routes `.env` and `secrets/**` into a scope: the
// public tree, the store's packs and the stat index hold none of the private
// bytes or paths, while every reader opens them back from the overlay. A
// second snapshot keeps each file's id across an edit and a rename, keeps the
// sealed object of an unchanged file, and chains its record to the first.
@(test)
scoped_plaintext_never_enters_public_store :: proc(t:^testing.T) {
    folder_root:=base.test_folder(t,"kai-overlay-scoped")
    if folder_root=="" {return}
    s,se:=store.open(folder(folder_root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    scope:=random_id(Scope_Id)
    scope_add(t,&o,scope,.Reader,true,20,".env","secrets/**")
    refold(t,&o)
    alice,bob,carol:=device_of(&o.alice,0),device_of(&o.bob,0),device_of(&o.carol,0)
    kl:Log
    log_init(&kl);defer log_destroy(&kl)
    kf:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&s,o.project.id,scope,&alice,21),Error.None)
    defer keyring_fold_destroy(&kf)
    testing.expect_value(t,kf.epoch,u32(1))

    root:=folder(folder_root,"ws")
    big:=random_bytes(3*OVERLAY_CHUNK_MAX/2)
    put_file(t,root,"readme.txt",transmute([]u8)string("public"))
    put_file(t,root,".env",transmute([]u8)string("TOKEN="+SECRET+"\n"))
    put_file(t,root,"config/.env",transmute([]u8)string(SECRET+"-2"))
    put_file(t,root,"secrets/db/password.txt",transmute([]u8)string(SECRET+"-3"))
    put_file(t,root,"secrets/big.bin",big)
    put_file(t,root,"secrets/empty",nil)
    keyrings:=[]^Keyring_Fold{&kf}
    routing:=Overlay_Routing{org=&o.fold,project=o.project.id,keyrings=keyrings,device=alice}
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&s,o.alice.devices[0],overlay=&routing),Error.None) {return}
    defer workspace_close(&w)
    first:=repo_working(&w.repo)

    files:=make([dynamic]File,context.temp_allocator)
    c,_:=change_get(&s,first,context.temp_allocator)
    testing.expect_value(t,tree_files(&s,c.tree,&files,context.temp_allocator),Error.None)
    testing.expect(t,len(files)==1 && files[0].path=="readme.txt","the public tree holds only the public file")
    for row in w.index.rows {testing.expect_value(t,stat_path(&w.index,row),"readme.txt")}
    testing.expect(t,!bytes_under(folder(folder_root,"store"),transmute([]u8)string(SECRET)),"no pack holds a private byte")
    testing.expect(t,!bytes_under(folder(folder_root,"store"),big[1000:1064]))
    testing.expect(t,!store.chunk_has(&s,store.address_of_bytes(transmute([]u8)string(SECRET+"-2"))))
    testing.expect(t,!bytes_under(folder(folder_root,"store"),transmute([]u8)string("password.txt")),"nor a private path")

    // The public closure never reaches the overlay.
    record,record_address,re:=overlay_record_get(&s,o.project.id,scope,first,context.temp_allocator)
    testing.expect_value(t,re,Error.None)
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(&s,{first},&present,&missing)
    chunks:=make([dynamic]store.Hash,context.temp_allocator)
    for p in present {object_chunks(&s,p,&chunks)}
    private:=make([dynamic]store.Hash,context.temp_allocator)
    object_chunks(&s,record_address,&private)
    object_chunks(&s,record.tree_root,&private)
    for a in record.objects {object_chunks(&s,a,&private)}
    for a in private {testing.expect(t,!slice.contains(chunks[:],a),"a public chunk is an overlay's")}

    for device in ([]^Overlay_Device{&alice,&bob,&carol}) {
        opened,oe:=open_files(t,&s,&kf,device,first)
        testing.expect_value(t,oe,Error.None)
        testing.expect_value(t,len(opened),5)
        testing.expect_value(t,opened[".env"],"TOKEN="+SECRET+"\n")
        testing.expect_value(t,opened["config/.env"],SECRET+"-2")
        testing.expect(t,opened["secrets/big.bin"]==string(big) && opened["secrets/empty"]=="")
    }

    // An edit, a rename and an unchanged file: ids and the untouched object stay.
    before:Overlay
    testing.expect_value(t,overlay_open(&before,&s,&kf,&alice,first,context.temp_allocator),Error.None)
    defer overlay_close(&before)
    put_file(t,root,".env",transmute([]u8)string("TOKEN=rotated\n"))
    testing.expect(t,os.rename(strings.concatenate({root,"/secrets/db/password.txt"},context.temp_allocator),strings.concatenate({root,"/secrets/pw.txt"},context.temp_allocator))==nil)
    _,e:=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    second:=repo_working(&w.repo)
    after:Overlay
    testing.expect_value(t,overlay_open(&after,&s,&kf,&alice,second,context.temp_allocator),Error.None)
    defer overlay_close(&after)
    id_of :: proc(o:^Overlay,path:string) -> (entry:Overlay_Entry) {
        for e in o.entries {
            if e.path==path {return e}
        }
        return
    }
    testing.expect(t,id_of(&before,".env").file_id==id_of(&after,".env").file_id,"an edit keeps the file id")
    testing.expect(t,id_of(&before,".env").object!=id_of(&after,".env").object)
    testing.expect(t,id_of(&before,"secrets/db/password.txt").file_id==id_of(&after,"secrets/pw.txt").file_id,"a rename keeps it")
    testing.expect(t,id_of(&after,"secrets/db/password.txt").path=="")
    testing.expect(t,id_of(&before,"secrets/big.bin").object==id_of(&after,"secrets/big.bin").object,"an unchanged file keeps its object")
    testing.expect_value(t,after.record.seq,before.record.seq+1)
    testing.expect(t,after.record.prev==before.address)
    content,_:=overlay_file(&after,&s,".env",context.temp_allocator)
    testing.expect_value(t,string(content),"TOKEN=rotated\n")

    // Nothing changed once the files settle: the record stays.
    for path in ([]string{".env","secrets/pw.txt"}) {
        old:=time.time_add(time.now(),-time.Hour)
        os.change_times(strings.concatenate({root,"/",path},context.temp_allocator),old,old)
    }
    _,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    _,settled,_:=overlay_record_get(&s,o.project.id,scope,second,context.temp_allocator)
    _,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    _,again,_:=overlay_record_get(&s,o.project.id,scope,repo_working(&w.repo),context.temp_allocator)
    testing.expect(t,settled==again,"an unchanged overlay writes no record")
}

// Carol reads the scope at epoch 1, then is removed: no overlay is written
// until a reader rotates, and the new epoch wraps nothing for her. The scope
// keeps history, so a device added later opens epoch 1 through the chain of
// previous keys; a revoked device forces another rotation. A scope without
// history wraps no previous key.
@(test)
removed_member_cannot_decrypt_post_rotation_epoch :: proc(t:^testing.T) {
    folder_root:=base.test_folder(t,"kai-overlay-rotation")
    if folder_root=="" {return}
    s,se:=store.open(folder(folder_root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    scope,flat:=random_id(Scope_Id),random_id(Scope_Id)
    scope_add(t,&o,scope,.Reader,true,20,"secrets/**")
    scope_add(t,&o,flat,.Reader,false,21,"flat/**")
    refold(t,&o)
    alice,bob,carol:=device_of(&o.alice,0),device_of(&o.bob,0),device_of(&o.carol,0)
    kl,fl:Log
    log_init(&kl);defer log_destroy(&kl)
    log_init(&fl);defer log_destroy(&fl)
    kf,ff:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&s,o.project.id,scope,&alice,22),Error.None)
    defer keyring_fold_destroy(&kf)
    testing.expect_value(t,keyring_create(&ff,&fl,&o.fold,&s,o.project.id,flat,&alice,22),Error.None)
    defer keyring_fold_destroy(&ff)
    k1,e:=keyring_epoch_key(&kf,&carol,1)
    testing.expect_value(t,e,Error.None)

    root:=folder(folder_root,"ws")
    put_file(t,root,"readme.txt",transmute([]u8)string("public"))
    put_file(t,root,"secrets/a.txt",transmute([]u8)string(SECRET))
    routing:=Overlay_Routing{org=&o.fold,project=o.project.id,keyrings={&kf,&ff},device=alice}
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&s,o.alice.devices[0],overlay=&routing),Error.None) {return}
    defer workspace_close(&w)

    _,e=log_append(&o.org,.Member_Remove,body_make(Subject_Body{subject=o.carol.log.id}),&o.alice.devices[0],30)
    testing.expect_value(t,e,Error.None)
    refold(t,&o,&kf,&ff)
    testing.expect(t,keyring_needs_rotation(&kf))
    put_file(t,root,"secrets/a.txt",transmute([]u8)string(SECRET+" after removal"))
    _,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.Unauthorized)
    testing.expect(t,strings.contains(routing.refused,"rotate"),routing.refused)
    _,e=rotate_scope_epoch(&kf,&carol,31)
    testing.expect_value(t,e,Error.Unauthorized)

    epoch,re:=rotate_scope_epoch(&kf,&bob,32)
    testing.expect_value(t,re,Error.None)
    testing.expect_value(t,epoch,u32(2))
    testing.expect(t,!keyring_needs_rotation(&kf))
    _,e=keyring_epoch_key(&kf,&carol,2)
    testing.expect_value(t,e,Error.Unauthorized)
    found:=keyring_wraps(&kf,2,carol.dh)
    testing.expect(t,!found,"the new epoch wraps nothing for a removed member")
    _,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    revision:=repo_working(&w.repo)
    _,e=open_files(t,&s,&kf,&carol,revision)
    testing.expect_value(t,e,Error.Unauthorized)
    opened,oe:=open_files(t,&s,&kf,&bob,revision)
    testing.expect_value(t,oe,Error.None)
    testing.expect_value(t,opened["secrets/a.txt"],SECRET+" after removal")

    // A device bob adds later reads epoch 1 through the previous keys.
    second:=test_device(t,&o.bob)
    refold(t,&o,&kf,&ff)
    late:=device_of(&o.bob,second)
    _,e=keyring_epoch_key(&kf,&late,1)
    testing.expect_value(t,e,Error.Unauthorized)
    _,e=rotate_scope_epoch(&kf,&alice,40)
    testing.expect_value(t,e,Error.None)
    k1_late,le:=keyring_epoch_key(&kf,&late,1)
    testing.expect_value(t,le,Error.None)
    testing.expect(t,k1_late==k1,"history chains back to epoch 1")
    _,e=rotate_scope_epoch(&ff,&alice,41)
    testing.expect_value(t,e,Error.None)
    flat_epoch,_:=keyring_epoch(&ff,2)
    has_prev:=bool(flat_epoch.history)
    testing.expect(t,!has_prev,"a scope without history wraps no previous key")
    _,e=keyring_epoch_key(&ff,&late,1)
    testing.expect_value(t,e,Error.Unauthorized)

    // Revoking the late device needs a rotation too, and the next epoch shuts it out.
    _,e=log_append(&o.bob.log,.Device_Revoke,revoke_body(late.identity.key),&o.bob.devices[0],50)
    testing.expect_value(t,e,Error.None)
    refold(t,&o,&kf,&ff)
    testing.expect(t,keyring_needs_rotation(&kf))
    _,e=rotate_scope_epoch(&kf,&alice,51)
    testing.expect_value(t,e,Error.None)
    _,e=keyring_epoch_key(&kf,&late,kf.epoch)
    testing.expect_value(t,e,Error.Unauthorized)
}

// Removing the writer who started a scope's keyring and signed its first
// epoch keeps both: every reader left opens the old epoch and the one rotated
// after, since the writer's entries are judged as of when they were signed.
@(test)
removing_a_keyring_signer_keeps_its_epochs :: proc(t:^testing.T) {
    folder_root:=base.test_folder(t,"kai-overlay-signer")
    if folder_root=="" {return}
    s,se:=store.open(folder(folder_root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    scope:=random_id(Scope_Id)
    scope_add(t,&o,scope,.Reader,true,20,"secrets/**")
    refold(t,&o)
    alice,bob,carol:=device_of(&o.alice,0),device_of(&o.bob,0),device_of(&o.carol,0)
    kl:Log
    log_init(&kl);defer log_destroy(&kl)
    kf:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&s,o.project.id,scope,&bob,22),Error.None)
    defer keyring_fold_destroy(&kf)
    k1,e:=keyring_epoch_key(&kf,&carol,1)
    testing.expect_value(t,e,Error.None)

    removal,re:=log_append(&o.org,.Member_Remove,body_make(Subject_Body{subject=o.bob.log.id}),&o.alice.devices[0],30)
    testing.expect_value(t,re,Error.None)
    refold(t,&o,&kf)
    _,e=log_append(&kl,.Witness,witness_body(o.org.id,removal),&o.alice.devices[0],31,{},test_heads(&o.org)[0])
    testing.expect_value(t,e,Error.None)
    testing.expect_value(t,keyring_refold(&kf),Error.None)
    testing.expect(t,kf.valid[0] && kf.epoch==1,"the removed writer's genesis and epoch stand")
    testing.expect(t,keyring_needs_rotation(&kf))
    epoch,ee:=rotate_scope_epoch(&kf,&alice,32)
    testing.expect_value(t,ee,Error.None)
    testing.expect_value(t,epoch,u32(2))
    for reader in ([]^Overlay_Device{&alice,&carol}) {
        old,oe:=keyring_epoch_key(&kf,reader,1)
        _,ne:=keyring_epoch_key(&kf,reader,2)
        testing.expect(t,oe==.None && ne==.None && old==k1,"a reader left opens the old epoch and the new")
    }
    _,e=keyring_epoch_key(&kf,&bob,2)
    testing.expect_value(t,e,Error.Unauthorized)
}

// A reader's new device, a member let read the scope by a role it now has and
// a member added with such a role get the newest key from a reader that holds
// it, one Envelope_Add each, with no rotation; a member who does not read the
// scope gets none. An envelope added by a non-reader, for a key no user's log
// holds, for a member who does not read, or to an epoch that is not there is
// refused, and a revoked device's added envelope still asks for a rotation.
@(test)
envelope_adds_give_the_newest_key_to_readers_alone :: proc(t:^testing.T) {
    folder_root:=base.test_folder(t,"kai-overlay-envelope-add")
    if folder_root=="" {return}
    s,se:=store.open(folder(folder_root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    dave:Test_User
    test_user(t,&dave,"dave");defer log_destroy(&dave.log)
    folds:[4]User_Fold
    users:[4]^User_Fold
    fold:Org_Fold
    defer {org_fold_destroy(&fold);test_users_destroy(folds[:])}
    four :: proc(t:^testing.T,o:^Test_Org,dave:^Test_User,folds:[]User_Fold,users:[]^User_Fold,fold:^Org_Fold,k:^Keyring_Fold=nil) {
        org_fold_destroy(fold)
        test_users_destroy(folds)
        test_users_fold(t,{&o.alice,&o.bob,&o.carol,dave},folds,users)
        testing.expect_value(t,org_fold(fold,&o.org,users),Error.None)
        if k!=nil {testing.expect_value(t,keyring_refold(k),Error.None)}
    }
    scope:=random_id(Scope_Id)
    scope_add(t,&o,scope,.Writer,true,20,"secrets/**")
    four(t,&o,&dave,folds[:],users[:],&fold)
    alice,bob,carol:=device_of(&o.alice,0),device_of(&o.bob,0),device_of(&o.carol,0)
    kl:Log
    log_init(&kl);defer log_destroy(&kl)
    kf:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&fold,&s,o.project.id,scope,&alice,22),Error.None)
    defer keyring_fold_destroy(&kf)
    k1,_:=keyring_epoch_key(&kf,&alice,1)

    // Bob links a device: alice wraps the key for it alone, and nothing rotates.
    second:=test_device(t,&o.bob)
    four(t,&o,&dave,folds[:],users[:],&fold,&kf)
    phone:=device_of(&o.bob,second)
    _,e:=keyring_epoch_key(&kf,&phone,1)
    testing.expect_value(t,e,Error.Unauthorized)
    added,ae:=keyring_share(&kf,&alice,30)
    testing.expect(t,ae==.None && added==1,"one envelope, for the new device")
    key,ke:=keyring_epoch_key(&kf,&phone,1)
    testing.expect(t,ke==.None && key==k1,"the new device reads the scope at once")
    testing.expect(t,kf.epoch==1 && !keyring_needs_rotation(&kf),"no rotation")
    testing.expect(t,!keyring_wraps(&kf,1,carol.dh),"a member who does not read the scope gets no envelope")
    added,_=keyring_share(&kf,&phone,31)
    testing.expect_value(t,added,0)

    // Hostile adds: each is refused by the fold.
    garbage:=random_id(Epoch_Key)
    carol_kem,_:=kem_public(&carol.kem_seed)
    stranger_dh,_:=net.dh_key()
    stranger_seed:=random_id([KEM_SEED]u8)
    stranger_kem,_:=kem_public(&stranger_seed)
    Hostile :: struct {author:^Identity,user:Log_Id,epoch:u32,dh:Dh_Key,kem:[]u8,why:string}
    for h in ([]Hostile{
        {&o.carol.devices[0],o.carol.log.id,1,carol.dh,carol_kem[:],"by a member who does not read the scope"},
        {&o.alice.devices[0],o.alice.log.id,1,Dh_Key(stranger_dh.public),stranger_kem[:],"for a key no user's log holds"},
        {&o.alice.devices[0],o.alice.log.id,1,carol.dh,carol_kem[:],"for a member who does not read the scope"},
        {&o.alice.devices[0],o.alice.log.id,5,carol.dh,carol_kem[:],"to an epoch that is not there"},
    }) {
        envelope,_:=envelope_wrap(o.org.id,scope,h.epoch,h.dh,h.kem,&garbage)
        address,he:=log_append(&kl,.Envelope_Add,body_make(Envelope_Add_Body{epoch=h.epoch,envelope=envelope}),h.author,32,{},org_context(&fold,h.user))
        testing.expect_value(t,he,Error.None)
        testing.expect_value(t,keyring_refold(&kf),Error.None)
        at:=log_find(&kl,address)
        testing.expectf(t,at>=0 && !kf.valid[at],"an envelope add %s is refused",h.why)
    }
    testing.expect(t,!keyring_wraps(&kf,1,carol.dh) && !keyring_needs_rotation(&kf))

    // Carol's role now reaches the scope's readers, and dave joins as a writer: a reader's agent wraps for both.
    _,e=log_append(&o.org,.Role_Set,body_make(Member_Body{user=o.carol.log.id,role=.Writer}),&o.alice.devices[0],40)
    testing.expect_value(t,e,Error.None)
    _,e=log_append(&o.org,.Member_Add,body_make(Member_Body{user=dave.log.id,role=.Writer}),&o.alice.devices[0],41)
    testing.expect_value(t,e,Error.None)
    four(t,&o,&dave,folds[:],users[:],&fold,&kf)
    added,ae=keyring_share(&kf,&phone,42)
    testing.expect(t,ae==.None && added==2,"one envelope each for carol and dave")
    david:=device_of(&dave,0)
    for reader in ([]^Overlay_Device{&carol,&david}) {
        key,ke=keyring_epoch_key(&kf,reader,1)
        testing.expect(t,ke==.None && key==k1,"a member let read the scope reads it")
    }
    testing.expect(t,kf.epoch==1 && !keyring_needs_rotation(&kf))

    // A revoked device's added envelope asks for a rotation, which shuts it out.
    _,e=log_append(&o.bob.log,.Device_Revoke,revoke_body(phone.identity.key),&o.bob.devices[0],50)
    testing.expect_value(t,e,Error.None)
    four(t,&o,&dave,folds[:],users[:],&fold,&kf)
    testing.expect(t,keyring_needs_rotation(&kf),"a revoked device's envelope asks for a rotation")
    _,e=rotate_scope_epoch(&kf,&bob,51)
    testing.expect_value(t,e,Error.None)
    _,e=keyring_epoch_key(&kf,&phone,2)
    testing.expect_value(t,e,Error.Unauthorized)
}

// Leaks are stopped twice: a path of the deny set that no scope takes is
// refused at snapshot unless public_allow marks it, and a publish to public
// reports each line holding a private key, a token or a random secret
// assigned to a secret's name, with its path and line, unless an admin's
// Public_Add waives it.
@(test)
deny_set_and_publish_scanner_block_leaks :: proc(t:^testing.T) {
    folder_root:=base.test_folder(t,"kai-overlay-leaks")
    if folder_root=="" {return}
    s,se:=store.open(folder(folder_root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    root:=folder(folder_root,"ws")
    put_file(t,root,"readme.txt",transmute([]u8)string("public"))
    routing:=Overlay_Routing{public_allow={".env.example"}}
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&s,o.alice.devices[0],overlay=&routing),Error.None) {return}
    defer workspace_close(&w)
    for path in ([]string{".env",".env.local","deploy/server.pem","tls/site.key","home/id_rsa","certs/store.p12"}) {
        put_file(t,root,path,transmute([]u8)string("x"))
        _,e:=workspace_snapshot(&w)
        testing.expectf(t,e==.Unauthorized && strings.has_prefix(routing.refused,path),"%s: %v %s",path,e,routing.refused)
        os.remove(strings.concatenate({root,"/",path},context.temp_allocator))
    }
    put_file(t,root,".env.example",transmute([]u8)string("TOKEN=\n"))
    _,e:=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)

    put_file(t,root,"deploy/key.txt",transmute([]u8)string("# deploy\n\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n"))
    put_file(t,root,"ci.yml",transmute([]u8)string("steps:\n  token: ghp_8fK2mZq9Lx4Rt7Vn1Ys3Wb6Hd0Jc5Ae2Pg\n"))
    put_file(t,root,"app.cfg",transmute([]u8)string("API_KEY=Zq8Lr3Xv9Tm2Wb7Ns4Kp1Hy6Gd5Fc0Je\r\nname=game\n"))
    put_file(t,root,"notes.txt",transmute([]u8)string("PASSWORD=changeme\nversion: 1.2.3\nsee sk_live_ for the format\n"))
    binary:=make([]u8,64,context.temp_allocator)
    copy(binary[8:],"-----BEGIN RSA PRIVATE KEY-----")
    put_file(t,root,"logo.bin",binary)
    _,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    c,_:=change_get(&s,repo_working(&w.repo),context.temp_allocator)
    leaks:=make([dynamic]Leak,context.temp_allocator)
    testing.expect_value(t,publish_scan(&s,&o.fold,o.project.id,{},c.tree,&leaks,context.temp_allocator),Error.None)
    Expected :: struct {path:string,line:int,kind:Leak_Kind}
    expected:=[]Expected{{"app.cfg",1,.Assignment},{"ci.yml",2,.Token},{"deploy/key.txt",3,.Private_Key}}
    if testing.expectf(t,len(leaks)==len(expected),"%v",leaks) {
        for x,i in expected {
            testing.expectf(t,leaks[i].path==x.path && leaks[i].line==x.line && leaks[i].kind==x.kind,"%v",leaks[i])
        }
    }

    // Alice is the owner: her Public_Add waives its leak. Carol only reads:
    // the fold does not take hers.
    Waive :: struct {by:^Test_User,leak:Leak}
    for x,k in ([]Waive{{&o.alice,leaks[0]},{&o.carol,leaks[1]}}) {
        body:=body_make(Public_Add_Body{project=o.project.id,fingerprint=x.leak.fingerprint},transmute([]u8)x.leak.path)
        _,e=log_append(&o.org,.Public_Add,body,&x.by.devices[0],time.now()._nsec+i64(k))
        testing.expect_value(t,e,Error.None)
    }
    refold(t,&o)
    testing.expect_value(t,publish_scan(&s,&o.fold,o.project.id,{},c.tree,&leaks,context.temp_allocator),Error.None)
    testing.expect(t,len(leaks)==2 && leaks[0].path=="ci.yml" && leaks[1].path=="deploy/key.txt")
    testing.expect_value(t,publish_scan(&s,&o.fold,o.project.id,c.tree,c.tree,&leaks,context.temp_allocator),Error.None)
    testing.expect_value(t,len(leaks),0)
}

// Padme, MDC2 and AEGIS-256 round trips: every chunk size seals under
// store.CHUNK_MAX and opens to its bytes, sealing is deterministic within one
// file and differs across files, and whatever was changed, cut, extended,
// sealed under other keys or data, padded otherwise or made up is Corrupt.
// Records and trees refuse hostile bytes the same way.
@(test)
overlay_chunks_roundtrip_and_refuse_hostile_ciphertext :: proc(t:^testing.T) {
    for length in 0..<70000 {
        p:=padme(length)
        testing.expect(t,p>=length && padme(p)==p && (p-length)*100<=12*max(length,1),"padme")
        if t.error_count>0 {return}
    }
    z:Sealer
    testing.expect_value(t,sealer_init(&z),Error.None)
    defer sealer_destroy(&z)
    key:Epoch_Key
    copy(key[:],random_bytes(32))
    id:=random_id(File_Id)
    keys,other:=file_keys(&key,id),file_keys(&key,random_id(File_Id))
    scope:=random_id(Scope_Id)
    aad:=chunk_aad(scope,3,id)
    zeros:=make([]u8,OVERLAY_CHUNK_MAX,context.temp_allocator)
    for plain in ([][]u8{{7},transmute([]u8)string("hello"),random_bytes(1000),random_bytes(store.CHUNK_MIN),random_bytes(OVERLAY_CHUNK_MAX),zeros}) {
        sealed,e:=seal_chunk(&z,&keys,aad[:],plain)
        testing.expect_value(t,e,Error.None)
        testing.expect(t,len(sealed)<=store.CHUNK_MAX)
        sealed=slice.clone(sealed,context.temp_allocator)
        again,_:=seal_chunk(&z,&keys,aad[:],plain)
        testing.expect(t,slice.equal(sealed,again),"one file seals one chunk alike")
        elsewhere,_:=seal_chunk(&z,&other,aad[:],plain)
        testing.expect(t,!slice.equal(sealed[:SEAL_NONCE],elsewhere[:SEAL_NONCE]),"another file seals it otherwise")
        opened,oe:=open_chunk(&z,&keys,aad[:],sealed)
        testing.expect(t,oe==.None && slice.equal(opened,plain))
        _,oe=open_chunk(&z,&other,aad[:],sealed)
        testing.expect_value(t,oe,Error.Corrupt)
        wrong:=chunk_aad(scope,4,id)
        _,oe=open_chunk(&z,&keys,wrong[:],sealed)
        testing.expect_value(t,oe,Error.Corrupt)
        for at in ([]int{0,SEAL_NONCE,SEAL_NONCE+3,len(sealed)/2,len(sealed)-1}) {
            sealed[at]~=0x40
            _,oe=open_chunk(&z,&keys,aad[:],sealed)
            testing.expect_value(t,oe,Error.Corrupt)
            sealed[at]~=0x40
        }
        _,oe=open_chunk(&z,&keys,aad[:],sealed[:len(sealed)-1])
        testing.expect_value(t,oe,Error.Corrupt)
    }
    zeros_sealed,_:=seal_chunk(&z,&keys,aad[:],zeros)
    testing.expect(t,len(zeros_sealed)<OVERLAY_CHUNK_MAX/16,"MDC2 runs before the cipher")

    // A q only a forger writes: right nonce and tag, but a pad that is not zero.
    q:=make([]u8,64,context.temp_allocator)
    put_u32(q,5)
    put_u32(q[4:],6)
    packed,_:=data_encode_for_test(transmute([]u8)string("hello"))
    copy(q[SEAL_HEAD:],packed)
    q[63]=1
    forged:=make([]u8,SEAL_NONCE+len(q)+SEAL_TAG,context.temp_allocator)
    nonce:=keyed_hash(keys.nonce[:],q)
    copy(forged,nonce[:])
    aead_seal(keys.enc[:],nonce[:],aad[:],q,forged[SEAL_NONCE:][:len(q)],forged[SEAL_NONCE+len(q):])
    _,fe:=open_chunk(&z,&keys,aad[:],forged)
    testing.expect_value(t,fe,Error.Corrupt)

    for _ in 0..<300 {
        junk:=random_bytes(int(rand.uint32()%2048))
        _,je:=open_chunk(&z,&keys,aad[:],junk)
        testing.expect_value(t,je,Error.Corrupt)
        _,re:=overlay_record_decode(junk)
        testing.expect_value(t,re,Error.Corrupt)
        entries:=make([dynamic]Overlay_Entry,context.temp_allocator)
        _,te:=tree_open(junk,{},scope,1,&key,&entries,context.temp_allocator)
        testing.expect_value(t,te,Error.Corrupt)
        testing.expect_value(t,tree_decode(junk,&entries),Error.Corrupt)
    }

    // A record checks itself, and its signature is its author's.
    identity:=identity_make()
    r:=Overlay_Record{head={seq=1,commit={0=1},project={0=2},scope=scope,epoch=1,tree_root={0=3}},objects={{0=4},{0=5}}}
    r.author=identity.key
    encoded,ee:=overlay_record_encode(&r,&identity,context.temp_allocator)
    testing.expect_value(t,ee,Error.None)
    decoded,de:=overlay_record_decode(encoded)
    testing.expect(t,de==.None && signed_valid(encoded,identity.key) && len(decoded.objects)==2)
    for cut in ([]int{1,size_of(Signature),size_of(Signature)+1}) {
        _,de=overlay_record_decode(encoded[:len(encoded)-cut])
        testing.expect_value(t,de,Error.Corrupt)
    }
    encoded[40]~=1
    testing.expect(t,!signed_valid(encoded,identity.key))

    Case :: struct {pattern,path:string,match:bool}
    cases:=[]Case{
        {".env","config/.env",true},{".env","config/.env.local",false},{".env*","a/.env.local",true},
        {"secrets/**","secrets/a/b.txt",true},{"secrets/**","other/secrets/a",false},{"secrets/","secrets/x",true},
        {"**/*.pem","a/b/c.pem",true},{"**/*.pem","c.pem",true},{"assets/*/raw.bin","assets/x/raw.bin",true},
        {"assets/*/raw.bin","assets/x/y/raw.bin",false},{"id_?sa","keys/id_rsa",true},{"/build/*.log","build/a.log",true},
    }
    for c in cases {testing.expectf(t,glob_match(c.pattern,c.path)==c.match,"%s %s",c.pattern,c.path)}
}

@(private="file")
data_encode_for_test :: proc(plain:[]u8) -> (packed:[]u8,ok:bool) {
    z:Sealer
    if sealer_init(&z,context.temp_allocator)!=.None {return}
    defer sealer_destroy(&z)
    key:Epoch_Key
    keys:=file_keys(&key,{})
    aad:=chunk_aad({},1,{})
    sealed,e:=seal_chunk(&z,&keys,aad[:],plain)
    if e!=.None {return}
    opened_q:=make([]u8,len(sealed)-SEAL_NONCE-SEAL_TAG,context.temp_allocator)
    if !aead_open(keys.enc[:],sealed[:SEAL_NONCE],aad[:],sealed[SEAL_NONCE:][:len(opened_q)],sealed[SEAL_NONCE+len(opened_q):],opened_q) {return}
    n:=int(get_u32(opened_q[4:]))
    return slice.clone(opened_q[SEAL_HEAD:][:n],context.temp_allocator),true
}

// Moving an overlay to another commit signs a new record of the same sealed
// tree and objects, without any key; outputs built from private inputs
// inherit their scopes and open only for a device that reads all of them.
@(test)
overlay_rebase_keeps_ciphertext_and_ddc_outputs_inherit_scopes :: proc(t:^testing.T) {
    folder_root:=base.test_folder(t,"kai-overlay-rebase")
    if folder_root=="" {return}
    s,se:=store.open(folder(folder_root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    scope,other:=random_id(Scope_Id),random_id(Scope_Id)
    scope_add(t,&o,scope,.Reader,true,20,"secrets/**")
    scope_add(t,&o,other,.Writer,true,21,"licensed/**")
    refold(t,&o)
    alice,carol:=device_of(&o.alice,0),device_of(&o.carol,0)
    kl,ol:Log
    log_init(&kl);defer log_destroy(&kl)
    log_init(&ol);defer log_destroy(&ol)
    kf,of:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&s,o.project.id,scope,&alice,22),Error.None)
    defer keyring_fold_destroy(&kf)
    testing.expect_value(t,keyring_create(&of,&ol,&o.fold,&s,o.project.id,other,&alice,22),Error.None)
    defer keyring_fold_destroy(&of)
    root:=folder(folder_root,"ws")
    put_file(t,root,"readme.txt",transmute([]u8)string("public"))
    put_file(t,root,"secrets/a.txt",transmute([]u8)string(SECRET))
    routing:=Overlay_Routing{org=&o.fold,project=o.project.id,keyrings={&kf,&of},device=alice}
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&s,o.alice.devices[0],overlay=&routing),Error.None) {return}
    defer workspace_close(&w)
    from:=repo_working(&w.repo)
    to:=test_change(t,&s,&o.bob.devices[0],"rebased")
    old,old_address,e:=overlay_record_get(&s,o.project.id,scope,from,context.temp_allocator)
    testing.expect_value(t,e,Error.None)

    // Bob writes but holds no key in this test: a rebase needs none.
    address,re:=overlay_rebase(&s,&o.bob.devices[0],o.project.id,scope,from,to,5)
    testing.expect_value(t,re,Error.None)
    moved,moved_address,me:=overlay_record_get(&s,o.project.id,scope,to,context.temp_allocator)
    testing.expect_value(t,me,Error.None)
    testing.expect(t,moved_address==address && moved.tree_root==old.tree_root && slice.equal(moved.objects,old.objects))
    testing.expect(t,moved.prev==old_address && moved.seq==old.seq+1 && moved.author==o.bob.devices[0].key)
    opened,oe:=open_files(t,&s,&kf,&carol,to)
    testing.expect(t,oe==.None && opened["secrets/a.txt"]==SECRET)

    // A peer takes a newer record and refuses an older one.
    ns:[len(OVERLAY_PREFIX)+64+1+32]u8
    name:[64]u8
    namespace,commit_name:=overlay_namespace(o.project.id,scope,&ns),store.hex(to,&name)
    _,changed,ae:=overlay_accept(&s,&o.fold,namespace,commit_name,address)
    testing.expect(t,ae==.None && !changed)
    from_name:[64]u8
    _,_,ae=overlay_accept(&s,&o.fold,namespace,store.hex(from,&from_name),old_address)
    testing.expect_value(t,ae,Error.None)
    newer,_:=overlay_rebase(&s,&o.alice.devices[0],o.project.id,scope,from,to,6)
    _,_,ae=overlay_accept(&s,&o.fold,namespace,commit_name,address)
    testing.expect_value(t,ae,Error.Rollback)
    _,_,ae=overlay_accept(&s,&o.fold,namespace,commit_name,newer)
    testing.expect_value(t,ae,Error.None)

    tainted:=make([dynamic]Scope_Id,context.temp_allocator)
    testing.expect_value(t,overlay_taint(&o.fold,o.project.id,{"src/main.odin","secrets/a.txt","licensed/x.bin","secrets/b.txt"},&tainted),Error.None)
    testing.expect(t,len(tainted)==2 && tainted[0]==scope && tainted[1]==other)
    keyrings:=[]^Keyring_Fold{&kf,&of}
    // An output is sealed and opened a chunk at a time: the memory either takes is the same for
    // an output of one chunk as for one of many, and what it opens is what was written.
    Sealed :: struct {address:store.Hash,peak:i64,opened:bool}
    seal_and_open :: proc(t:^testing.T,s:^store.Store,keyrings:[]^Keyring_Fold,device:^Overlay_Device,project:Log_Id,scopes:[]Scope_Id,size:int) -> (out:Sealed) {
        track:mem.Tracking_Allocator
        mem.tracking_allocator_init(&track,context.allocator)
        defer mem.tracking_allocator_destroy(&track)
        b:Blob_Sealer
        if !testing.expect_value(t,overlay_blob_begin(&b,s,keyrings,device,project,scopes,mem.tracking_allocator(&track)),Error.None) {return}
        piece:[4096]u8
        overlay_blob_write(&b,transmute([]u8)string("cooked "+SECRET))
        for at:=len("cooked "+SECRET);at<size;at+=len(piece) {
            for &c,k in piece {c=u8(at+k)}
            overlay_blob_write(&b,piece[:min(len(piece),size-at)])
        }
        e:Error
        out.address,e=overlay_blob_finish(&b)
        if !testing.expect_value(t,e,Error.None) {return}
        r:Blob_Reader
        if !testing.expect_value(t,overlay_blob_open(&r,s,keyrings,device,out.address,mem.tracking_allocator(&track)),Error.None) {return}
        defer overlay_blob_close(&r)
        at:=0
        out.opened=true
        cooked:=string("cooked "+SECRET)
        for {
            plain,ne:=overlay_blob_next(&r)
            if ne!=.None || len(plain)==0 {
                out.opened&&=ne==.None
                break
            }
            for c,k in plain {
                want:=u8(at+k)
                if at+k<len(cooked) {want=cooked[at+k]}
                out.opened&&=c==want
            }
            at+=len(plain)
        }
        out.opened&&=at==size
        out.peak=track.peak_memory_allocated
        return
    }
    small:=seal_and_open(t,&s,keyrings,&alice,o.project.id,tainted[:],len("cooked "+SECRET))
    large:=seal_and_open(t,&s,keyrings,&alice,o.project.id,tainted[:],5*OVERLAY_CHUNK_MAX+123)
    testing.expect(t,small.opened && large.opened,"a sealed output opens as it was written")
    testing.expectf(t,large.peak==small.peak,"sealing and opening take %d bytes for one chunk and %d for many",small.peak,large.peak)
    r:Blob_Reader
    testing.expect_value(t,overlay_blob_open(&r,&s,keyrings,&carol,small.address),Error.Unauthorized)
    testing.expect(t,!bytes_under(folder(folder_root,"store"),transmute([]u8)string(SECRET)))
}

// Agents of one simulated network, as in mesh_test.odin.
@(private="file") MESH_CLIENTS :: 2
@(private="file") MESH_STEP :: 0.001

@(private="file")
Mesh :: struct {
    sim:net.Sim_Network,
    now:f64,
    folder:string,
    stores:[3]store.Store,
    open:[3]bool,
    agents:[3]Agent,
    running:[3]bool,
}

@(private="file")
mesh_init :: proc(t:^testing.T,m:^Mesh,name:string) -> bool {
    m.folder=base.test_folder(t,name)
    if m.folder=="" {return false}
    net.sim_network_init(&m.sim,{seed=13,endpoints=3*(1+MESH_CLIENTS),packets=1<<16})
    for k in 0..<3 {
        e:store.Error
        m.stores[k],e=store.open(fmt.tprintf("%s/node-%d",m.folder,k))
        if !testing.expect_value(t,e,store.Error.None) {return false}
        m.open[k]=true
    }
    return true
}

@(private="file")
mesh_destroy :: proc(m:^Mesh) {
    for k in 0..<3 {
        if m.running[k] {agent_close(&m.agents[k])}
        if m.open[k] {store.close(&m.stores[k])}
    }
    net.sim_network_destroy(&m.sim)
}

@(private="file")
mesh_endpoint :: proc "contextless" (k:int) -> int {return k*(1+MESH_CLIENTS)}

@(private="file")
mesh_start :: proc(t:^testing.T,m:^Mesh,k:int,identity:Identity,dh:net.Dh_Key,user,org:Log_Id,seed:=false) -> bool {
    clients:[MESH_CLIENTS]net.Transport
    for c in 0..<MESH_CLIENTS {clients[c]=net.sim_endpoint_transport(&m.sim,mesh_endpoint(k)+1+c)}
    e:=agent_init(&m.agents[k],{
        store=&m.stores[k],identity=identity,dh=dh,user=user,org=org,seed=seed,host_seed=u64(200+k*10),
        server=net.sim_endpoint_transport(&m.sim,mesh_endpoint(k)),
    },clients[:])
    m.running[k]=e==.None
    return testing.expect_value(t,e,Error.None)
}

@(private="file")
mesh_until :: proc(m:^Mesh,seconds:f64,data:rawptr,done:proc(m:^Mesh,data:rawptr) -> bool) -> bool {
    end:=m.now+seconds
    for m.now<end {
        m.now+=MESH_STEP
        net.sim_network_advance(&m.sim,m.now)
        for k in 0..<3 {
            if m.running[k] {agent_update(&m.agents[k],m.now)}
        }
        if done(m,data) {return true}
    }
    return false
}

// Whether the store holds every chunk of the object at address.
@(private="file")
object_whole :: proc(s:^store.Store,address:store.Hash) -> bool {
    if !object_present(s,address) {return false}
    chunks:=make([dynamic]store.Hash,context.temp_allocator)
    object_chunks(s,address,&chunks)
    for c in chunks {
        if !store.chunk_has(s,c) {return false}
    }
    return len(chunks)>1
}

@(private="file")
Seed_Goal :: struct {
    namespace:string,
    name:string,
    record:store.Hash,
    record_value:Overlay_Record,
    keyring:Log_Id,
}

// Alice snapshots a scoped file and publishes the change to a public
// project. A seed of the org mirrors the overlay's record, tree, file objects
// and keyring with no key of the scope: it cannot open them, though a reader
// opens them from its store. An anonymous peer reads the public change but
// gets no overlay ref, no keyring and no overlay chunk.
@(test)
public_peer_sees_zero_overlay_metadata_or_chunks :: proc(t:^testing.T) {
    m:=new(Mesh)
    defer free(m)
    if !mesh_init(t,m,"kai-overlay-mesh") {return}
    defer mesh_destroy(m)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    seed_identity:=identity_make()
    seed_dh,_:=net.dh_key()
    log_append(&o.org,.Node_Add,body_make(Node_Add_Body{node=seed_identity.key,dh=Dh_Key(seed_dh.public),modes={.Seed}}),&o.alice.devices[0],19)
    scope:=random_id(Scope_Id)
    scope_add(t,&o,scope,.Reader,true,20,"secrets/**")
    refold(t,&o)
    alice:=device_of(&o.alice,0)
    kl:Log
    log_init(&kl);defer log_destroy(&kl)
    kf:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&m.stores[0],o.project.id,scope,&alice,21),Error.None)
    defer keyring_fold_destroy(&kf)
    for l in ([]^Log{&o.alice.log,&o.bob.log,&o.carol.log,&o.org,&o.project,&kl}) {
        _,e:=log_save(&m.stores[0],l)
        testing.expect_value(t,e,Error.None)
    }
    root:=folder(m.folder,"ws")
    put_file(t,root,"readme.txt",transmute([]u8)string("public"))
    put_file(t,root,"secrets/token.txt",transmute([]u8)string(SECRET))
    put_file(t,root,"secrets/big.bin",random_bytes(OVERLAY_CHUNK_MAX+100))
    routing:=Overlay_Routing{org=&o.fold,project=o.project.id,keyrings={&kf},device=alice}
    w:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&m.stores[0],o.alice.devices[0],overlay=&routing),Error.None) {return}
    defer workspace_close(&w)
    revision:=repo_working(&w.repo)
    test_link(t,&m.stores[0],w.repo.id,o.project.id)
    record,record_address,re:=overlay_record_get(&m.stores[0],o.project.id,scope,revision,context.temp_allocator)
    if !testing.expect_value(t,re,Error.None) {return}

    if !mesh_start(t,m,0,o.alice.devices[0],o.alice.dhs[0],o.alice.log.id,o.org.id) {return}
    if !mesh_start(t,m,1,seed_identity,seed_dh,{},o.org.id,seed=true) {return}
    stranger:=identity_make()
    stranger_dh,_:=net.dh_key()
    if !mesh_start(t,m,2,stranger,stranger_dh,{},o.org.id) {return}
    a,sd,c:=&m.agents[0],&m.agents[1],&m.agents[2]
    _,pe:=agent_publish_refs(a,o.project.id,{{"main",revision}},1)
    testing.expect_value(t,pe,Error.None)
    _,pe=agent_append(a,o.project.id,.Bookmark_Move,body_make(Bookmark_Move_Body{to=revision},transmute([]u8)string("main")),2)
    testing.expect_value(t,pe,Error.None)
    testing.expect_value(t,agent_connect(sd,Dh_Key(o.alice.dhs[0].public),false,net.address_memory(mesh_endpoint(0))),Error.None)
    testing.expect_value(t,agent_connect(c,Dh_Key(o.alice.dhs[0].public),true,net.address_memory(mesh_endpoint(0))),Error.None)

    ns:[len(OVERLAY_PREFIX)+64+1+32]u8
    name:[64]u8
    g:=Seed_Goal{namespace=overlay_namespace(o.project.id,scope,&ns),name=store.hex(revision,&name),record=record_address,record_value=record,keyring=kl.id}
    mirrored :: proc(m:^Mesh,data:rawptr) -> bool {
        g:=(^Seed_Goal)(data)
        s:=&m.stores[1]
        held,e:=store.ref_get(s,g.namespace,g.name)
        if e!=.None || held!=g.record || !object_whole(s,g.record_value.tree_root) {return false}
        for o in g.record_value.objects {
            if !object_whole(s,o) {return false}
        }
        log_buffer:[64]u8
        _,le:=store.ref_get(s,LOG_NAMESPACE,log_name(g.keyring,&log_buffer))
        n,_:=agent_peers(&m.agents[2])
        return le==.None && n==1
    }
    if !testing.expectf(t,mesh_until(m,10,&g,mirrored),"not mirrored: alice %v, seed %v",a.stats,sd.stats) {return}
    testing.expect_value(t,a.stats.refused+sd.stats.refused,0)

    // The seed holds the ciphertext and the keyring, and no key.
    seed_device:=Overlay_Device{identity=seed_identity,dh=Dh_Key(seed_dh.public),dh_secret=seed_dh.private}
    sl:Log
    log_init(&sl);defer log_destroy(&sl)
    testing.expect_value(t,log_open(&m.stores[1],&sl,kl.id,.Keyring),Error.None)
    skf:Keyring_Fold
    testing.expect_value(t,keyring_fold(&skf,&sl,&sd.org,&m.stores[1]),Error.None)
    defer keyring_fold_destroy(&skf)
    testing.expect_value(t,skf.epoch,u32(1))
    _,ke:=keyring_epoch_key(&skf,&seed_device,1)
    testing.expect_value(t,ke,Error.Unauthorized)
    _,se:=open_files(t,&m.stores[1],&skf,&seed_device,revision)
    testing.expect_value(t,se,Error.Unauthorized)
    testing.expect(t,!bytes_under(fmt.tprintf("%s/node-1",m.folder),transmute([]u8)string(SECRET)))
    opened,oe:=open_files(t,&m.stores[1],&skf,&alice,revision)
    testing.expect(t,oe==.None && opened["secrets/token.txt"]==SECRET,"a reader opens what the seed mirrored")

    // The anonymous peer: no overlay ref, no keyring, no overlay chunk.
    peer:^Agent_Peer
    for &p in c.peers {
        if p.used {peer=&p}
    }
    log_buffer:[64]u8
    q1,_:=exchange.ref_ask(&c.x,g.namespace,g.name,peer.host,peer.connection)
    q2,_:=exchange.ref_ask(&c.x,LOG_NAMESPACE,log_name(kl.id,&log_buffer),peer.host,peer.connection)
    Answers :: struct {x:^exchange.Exchange,q:[2]exchange.Query,r:[2]exchange.Query_Result}
    answers:=Answers{x=&c.x,q={q1,q2}}
    answered :: proc(m:^Mesh,data:rawptr) -> bool {
        w:=(^Answers)(data)
        for k in 0..<2 {w.r[k],_=exchange.query_result(w.x,w.q[k])}
        return w.r[0].state!=.Waiting && w.r[1].state!=.Waiting
    }
    testing.expect(t,mesh_until(m,5,&answers,answered))
    testing.expect_value(t,answers.r[0].state,exchange.Query_State.Not_Found)
    testing.expect_value(t,answers.r[1].state,exchange.Query_State.Not_Found)
    for q in answers.q {exchange.query_end(&c.x,q)}
    wanted:=make([dynamic]store.Hash,context.temp_allocator)
    append(&wanted,revision,record_address,record.tree_root)
    append(&wanted,..record.objects)
    for a in wanted {testing.expect_value(t,exchange.want(&c.x,a),exchange.Error.None)}
    settled :: proc(m:^Mesh,data:rawptr) -> bool {
        wanted:=(^[dynamic]store.Hash)(data)
        x:=&m.agents[2].x
        for a,i in wanted {
            p,_:=exchange.progress(x,a)
            if p.state!=(i==0?exchange.State.Complete:exchange.State.Missing) {return false}
        }
        return true
    }
    testing.expect(t,mesh_until(m,5,&wanted,settled),"the public change arrives, no overlay object does")
    for a in wanted[1:] {testing.expect(t,!object_present(&m.stores[2],a))}
    namespaces,_:=store.ref_namespaces(&m.stores[2],context.temp_allocator)
    for n in namespaces {testing.expectf(t,!strings.has_prefix(n,OVERLAY_PREFIX),"the anonymous peer holds %s",n)}
    testing.expect(t,!bytes_under(fmt.tprintf("%s/node-2",m.folder),transmute([]u8)string(SECRET)))
}

// An epoch's key is wrapped for each device under X25519 and ML-KEM-768 at
// once: a device that holds only one of its two secrets opens nothing, and a
// changed KEM ciphertext, share, or any input of the salt (the device's keys)
// is refused. The envelopes of an epoch are an object of the store the entry
// names, so an epoch for 200 devices is written and each of them reads it.
@(test)
an_epoch_key_opens_only_with_both_device_secrets :: proc(t:^testing.T) {
    folder_root:=base.test_folder(t,"kai-overlay-hybrid")
    if folder_root=="" {return}
    s,se:=store.open(folder(folder_root,"store"))
    if !testing.expect_value(t,se,store.Error.None) {return}
    defer store.close(&s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    scope:=random_id(Scope_Id)
    scope_add(t,&o,scope,.Reader,true,20,"secrets/**")
    refold(t,&o)
    alice,bob:=device_of(&o.alice,0),device_of(&o.bob,0)
    org,epoch:=o.org.id,u32(7)
    key:=random_id(Epoch_Key)
    bob_kem,_:=kem_public(&bob.kem_seed)
    envelope,wrapped:=envelope_wrap(org,scope,epoch,bob.dh,bob_kem[:],&key)
    testing.expect(t,wrapped)
    opened,ok:=envelope_unwrap(org,scope,epoch,&bob,envelope)
    testing.expect(t,ok && opened==key,"the device opens its envelope")

    // One secret of two opens nothing.
    x_only,kem_only:=bob,bob
    x_only.kem_seed=alice.kem_seed
    kem_only.dh_secret=alice.dh_secret
    for d in ([]^Overlay_Device{&x_only,&kem_only}) {
        _,ok=envelope_unwrap(org,scope,epoch,d,envelope)
        testing.expect(t,!ok,"a device with one of its two secrets opens nothing")
    }
    // A changed ciphertext, share, sealed key or tag, or another salt input, is refused.
    for k in 0..<4 {
        e:=envelope
        switch k {
        case 0: e.kem[100]~=1
        case 1: e.share[3]~=1
        case 2: e.sealed[0]~=1
        case 3: e.tag[15]~=1
        }
        _,ok=envelope_unwrap(org,scope,epoch,&bob,e)
        testing.expectf(t,!ok,"a changed part %d is refused",k)
    }
    dk:mlkem.Decapsulation_Key
    testing.expect(t,mlkem.decapsulation_key_set_bytes(&dk,KEM,bob.kem_seed[:]))
    alice_kem,_:=kem_public(&alice.kem_seed)
    e:=envelope
    _,ok=envelope_open(org,scope,epoch,&e,&bob.dh_secret,&dk,alice_kem[:])
    testing.expect(t,!ok,"the salt binds the device's ML-KEM key")
    _,ok=envelope_open(org,scope,epoch,&e,&bob.dh_secret,&dk,bob_kem[:])
    testing.expect(t,ok)
    for c in 0..<3 {
        _,ok=envelope_unwrap(c==0?Log_Id{0=1}:org,c==1?Scope_Id{0=1}:scope,c==2?epoch+1:epoch,&bob,envelope)
        testing.expect(t,!ok,"the org, the scope and the epoch are bound")
    }
    mlkem.decapsulation_key_clear(&dk)
    small:=[32]u8{0=1}
    _,wrapped=envelope_wrap(org,scope,epoch,Dh_Key(small),bob_kem[:],&key)
    testing.expect(t,!wrapped,"a point of small order leaves nothing secret and is refused")

    // 200 devices of bob's read the scope: one epoch, one object of envelopes.
    devices:=make([]Overlay_Device,199,context.temp_allocator)
    for &d,k in devices {
        d.identity=identity_make()
        dh,_:=net.dh_key()
        d.dh,d.dh_secret=Dh_Key(dh.public),dh.private
        d.kem_seed=random_id([KEM_SEED]u8)
        _,ae:=log_append(&o.bob.log,.Device_Add,test_device_body(&d.identity,d.dh,&d.kem_seed,o.bob.log.id,fmt.tprintf("d%d",k)),&o.bob.devices[0],30)
        testing.expect_value(t,ae,Error.None)
    }
    refold(t,&o)
    kl:Log
    log_init(&kl);defer log_destroy(&kl)
    kf:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&s,o.project.id,scope,&alice,31),Error.None)
    defer keyring_fold_destroy(&kf)
    body,_:=keyring_epoch(&kf,1)
    testing.expect_value(t,int(body.devices),200+2) // bob's 200, alice's and carol's
    for &d in devices {
        _,ke:=keyring_epoch_key(&kf,&d,1)
        testing.expect_value(t,ke,Error.None)
    }
    // A store without the object reads nothing of the epoch yet.
    other,oe:=store.open(folder(folder_root,"other"))
    if !testing.expect_value(t,oe,store.Error.None) {return}
    defer store.close(&other)
    kf.store=&other
    _,ke:=keyring_epoch_key(&kf,&devices[0],1)
    testing.expect_value(t,ke,Error.Missing)
    kf.store=&s

    // What the hybrid costs: a device's entry, an envelope, an epoch of 10 devices.
    sizes:[2]int
    for &item in o.bob.log.items {
        if item.entry.type==.Device_Add {sizes[0]=len(item.bytes)}
    }
    for &item in kl.items {
        if item.entry.type==.Epoch_Add {sizes[1]=len(item.bytes)}
    }
    fmt.printfln("kai: a Device_Add with its ML-KEM-768 key is %d bytes; an envelope %d; an epoch of 10 devices %d bytes of entry and %d of envelopes",sizes[0],size_of(Envelope),sizes[1],10*size_of(Envelope))
}
