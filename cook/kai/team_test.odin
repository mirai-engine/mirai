package kai_assets

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import net "mirai:net"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

// A machine of a team: its runner on its own thread over 127.0.0.1, as
// `mirai kai agent` runs it, and the machine the operations open on the same
// store, which tells the runner through its control as another process does.
@(private="file")
Team_Machine :: struct {
    runner_machine:vcs.Machine,
    runner:vcs.Runner,
    started:bool,
    stop:bool,
    worker:^thread.Thread,
    beacons:[1]net.Address,
    m:vcs.Machine,
    control:vcs.Control,
    connected:bool,
    folder:string,
}

@(private="file")
team_run :: proc(t:^thread.Thread) {
    x:=(^Team_Machine)(t.data)
    for !sync.atomic_load(&x.stop) {
        vcs.runner_update(&x.runner,0.01)
        free_all(context.temp_allocator)
    }
}

@(private="file")
team_open :: proc(t:^testing.T,x:^Team_Machine,folder:string,name:string) -> bool {
    x.folder=fmt.aprintf("%s/%s",folder,name)
    store_root:=fmt.tprintf("%s/store",x.folder)
    if !testing.expect_value(t,vcs.machine_open(&x.runner_machine,store_root),vcs.Error.None) {return false}
    return testing.expect_value(t,vcs.machine_open(&x.m,store_root),vcs.Error.None)
}

@(private="file")
team_user :: proc(t:^testing.T,x:^Team_Machine,name:string) {
    buffer:[vcs.RECOVERY_TEXT]u8
    _,e:=vcs.machine_user_create(&x.m,name,&buffer)
    testing.expect_value(t,e,vcs.Error.None)
    vcs.machine_reload(&x.runner_machine)
}

@(private="file")
team_start :: proc(t:^testing.T,x:^Team_Machine,beacon:bool) -> bool {
    vcs.machine_reload(&x.runner_machine)
    if !testing.expect_value(t,vcs.runner_start(&x.runner,{machine=&x.runner_machine,bind=net.address_loopback(0),beacon=beacon,beacon_port=-1,control=true}),vcs.Error.None) {return false}
    x.started=true
    if !testing.expect_value(t,vcs.control_open(&x.control,x.m.store.root),vcs.Error.None) {return false}
    x.connected=true
    x.m.changed=vcs.control_machine_changed(&x.control)
    return true
}

@(private="file")
team_go :: proc(x:^Team_Machine) {
    x.worker=thread.create(team_run)
    x.worker.data=x
    x.worker.init_context=context
    thread.start(x.worker)
}

@(private="file")
team_halt :: proc(x:^Team_Machine) {
    if x.worker!=nil {
        sync.atomic_store(&x.stop,true)
        thread.join(x.worker)
        thread.destroy(x.worker)
        x.worker=nil
    }
}

@(private="file")
team_close :: proc(x:^Team_Machine) {
    team_halt(x)
    if x.connected {vcs.control_close(&x.control)}
    if x.started {vcs.runner_stop(&x.runner)}
    vcs.machine_close(&x.m)
    vcs.machine_close(&x.runner_machine)
    delete(x.folder)
}

// Whether done holds within seconds, asked every few milliseconds.
@(private="file")
until :: proc(seconds:f64,data:rawptr,done:proc(data:rawptr) -> bool) -> bool {
    start:=time.tick_now()
    for time.duration_seconds(time.tick_since(start))<seconds {
        if done(data) {return true}
        time.sleep(20*time.Millisecond)
    }
    return done(data)
}

@(private="file")
write :: proc(t:^testing.T,root,path,text:string,loc:=#caller_location) {
    full:=strings.concatenate({root,"/",path},context.temp_allocator)
    if dir,_:=os.split_path(full);dir!="" {os.make_directory_all(dir)}
    testing.expect(t,os.write_entire_file(full,transmute([]u8)text)==nil,loc=loc)
    old:=time.time_add(time.now(),-time.Hour)
    os.change_times(full,old,old)
}

@(private="file")
read :: proc(root,path:string) -> (text:string,ok:bool) {
    bytes,e:=os.read_entire_file(strings.concatenate({root,"/",path},context.temp_allocator),context.temp_allocator)
    return string(bytes),e==nil
}

// Bob's store holds the org and alice's user as a pairing leaves them, and
// alice's holds bob's: he is a writer.
@(private="file")
team_pair :: proc(t:^testing.T,alice,bob:^Team_Machine,org:vcs.Log_Id) {
    copy_log :: proc(from,to:^store.Store,id:vcs.Log_Id,kind:vcs.Log_Kind) {
        l:vcs.Log
        vcs.log_init(&l,id,context.temp_allocator)
        vcs.log_open(from,&l,id,kind)
        vcs.log_save(to,&l)
    }
    copy_log(&bob.m.store,&alice.m.store,bob.m.user,.User)
    testing.expect_value(t,vcs.machine_member_add(&alice.m,org,bob.m.user,.Writer),vcs.Error.None)
    copy_log(&alice.m.store,&bob.m.store,org,.Org)
    copy_log(&alice.m.store,&bob.m.store,alice.m.user,.User)
    testing.expect_value(t,vcs.machine_org_join(&bob.m,org),vcs.Error.None)
}

// Whether the change at revision and everything it reaches are in the store.
@(private="file")
whole :: proc(s:^store.Store,revision:vcs.Revision) -> bool {
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    vcs.closure_walk(s,{revision},&present,&missing)
    return len(present)>0 && len(missing)==0
}

// The change a bookmark of the project's log names in the store of m, when
// it is whole there.
@(private="file")
shared_target :: proc(m:^vcs.Machine,project:vcs.Log_Id,name:string) -> vcs.Revision {
    ps:vcs.Project_State
    if vcs.project_state_load(&m.store,project,&ps,context.temp_allocator)!=.None {return {}}
    targets:=make([dynamic]vcs.Revision,context.temp_allocator)
    vcs.project_bookmark(&ps.fold,name,&targets)
    if len(targets)!=1 {return {}}
    if !whole(&m.store,targets[0]) {return {}}
    return targets[0]
}

// Alice, Bob and a CI machine outside the org run their agents over
// 127.0.0.1. Alice guards main with a policy; Bob starts on main, opens a
// proposal, and revises it after Alice's comment on a line, which follows the
// line; Alice approves; the CI machine, holding a grant of the check right,
// runs the check on its own working copy of the final revision; a direct
// move of main is refused with the policy, and Bob lands: main moves on
// every machine.
@(test)
a_team_reviews_and_lands_a_proposal_through_the_shared_operations :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-kai-team")
    if folder=="" {return}
    team:=new([3]Team_Machine)
    defer free(team)
    alice,bob,ci:=&team[0],&team[1],&team[2]
    names:=[]string{"alice","bob","ci"}
    for &x,k in team {
        if !team_open(t,&x,folder,names[k]) {return}
    }
    defer for &x in team {team_close(&x)}
    team_user(t,alice,"alice")
    team_user(t,bob,"bob")
    org,e:=vcs.machine_org_create(&alice.m,"studio")
    testing.expect_value(t,e,vcs.Error.None)
    team_pair(t,alice,bob,org)

    // Alice's project, with main on its first change, guarded.
    pa:=new(Project)
    defer free(pa)
    a_root:=fmt.tprintf("%s/ws",alice.folder)
    write(t,a_root,"readme.txt","a\nb\nc\n")
    if !testing.expect_value(t,project_create(pa,a_root,&alice.m.store),vcs.Error.None) {return}
    defer project_close(pa)
    project,je:=project_join(pa,&alice.m,org,false)
    testing.expect_value(t,je,vcs.Error.None)
    first,_:=revision_find(&pa.workspace,"@")
    _,e=new_change(&pa.workspace,nil,"",nil)
    testing.expect_value(t,e,vcs.Error.None)
    testing.expect_value(t,vcs.machine_bookmark_move(&alice.m,project,"main",first),vcs.Error.None)
    testing.expect_value(t,vcs.machine_policy_set(&alice.m,org,project,"main",1,{"unit"}),vcs.Error.None)

    for &x in team {
        if !team_start(t,&x,&x!=ci) {return}
    }
    alice.beacons[0]=net.address_loopback(vcs.runner_port(&bob.runner))
    bob.beacons[0]=net.address_loopback(vcs.runner_port(&alice.runner))
    alice.runner.desc.beacon_targets,bob.runner.desc.beacon_targets=alice.beacons[:],bob.beacons[:]
    for &x in team {team_go(&x)}

    // Bob's workspace works on the project from main, which the policy set
    // after it does not void.
    Goal :: struct {m:^vcs.Machine,project:vcs.Log_Id,revision:vcs.Revision,proposal:vcs.Log_Id}
    g:=Goal{m=&bob.m,project=project,revision=first}
    main_is :: proc(data:rawptr) -> bool {
        g:=(^Goal)(data)
        return shared_target(g.m,g.project,"main")==g.revision
    }
    if !testing.expect(t,until(10,&g,main_is),"main reaches bob") {return}
    pb:=new(Project)
    defer free(pb)
    b_root:=fmt.tprintf("%s/ws",bob.folder)
    if !testing.expect_value(t,project_create(pb,b_root,&bob.m.store),vcs.Error.None) {return}
    defer project_close(pb)
    testing.expect_value(t,project_link(pb,&bob.m,project),vcs.Error.None)
    on,re:=revision_resolve(pb,&bob.m,"main")
    testing.expect(t,re==.None && on==first,bob.m.why)
    _,e=new_change(&pb.workspace,{on},"bob's lines",nil)
    testing.expect_value(t,e,vcs.Error.None)
    text,_:=read(b_root,"readme.txt")
    testing.expect_value(t,text,"a\nb\nc\n")
    write(t,b_root,"readme.txt","a\nb\nc\nd\n")
    _,e=vcs.workspace_snapshot(&pb.workspace)
    testing.expect_value(t,e,vcs.Error.None)
    working:=vcs.repo_working(&pb.workspace.repo)
    id,oe:=proposal_open(pb,&bob.m,"main","more lines","",{working})
    if !testing.expectf(t,oe==.None,"bob opens: %s",bob.m.why) {return}

    // Alice comments on line 2 of Bob's revision.
    g.m,g.proposal,g.revision=&alice.m,id,working
    arrived :: proc(data:rawptr) -> bool {
        g:=(^Goal)(data)
        ps:vcs.Project_State
        if vcs.project_state_load(&g.m.store,g.project,&ps,context.temp_allocator)!=.None {return false}
        f:=vcs.project_state_proposal(&ps,g.proposal)
        return f!=nil && f.revision==g.revision && whole(&g.m.store,g.revision)
    }
    if !testing.expect(t,until(10,&g,arrived),"the proposal and its change reach alice") {return}
    testing.expect_value(t,proposal_comment(pa,&alice.m,id,"readme.txt",{kind=.Lines,line=2,lines=1},"","why b?"),vcs.Error.None)
    g.m=&bob.m
    commented :: proc(data:rawptr) -> bool {
        g:=(^Goal)(data)
        ps:vcs.Project_State
        if vcs.project_state_load(&g.m.store,g.project,&ps,context.temp_allocator)!=.None {return false}
        f:=vcs.project_state_proposal(&ps,g.proposal)
        return f!=nil && f.comments==1
    }
    if !testing.expect(t,until(10,&g,commented),"the comment reaches bob") {return}

    // Bob revises with a line above it: the comment follows its line.
    write(t,b_root,"readme.txt","z\na\nb\nc\nd\n")
    _,e=vcs.workspace_snapshot(&pb.workspace)
    final:=vcs.repo_working(&pb.workspace.repo)
    testing.expect_value(t,proposal_revise(pb,&bob.m,id,{final}),vcs.Error.None)
    g.m,g.revision=&alice.m,final
    if !testing.expect(t,until(10,&g,arrived),"the revision reaches alice") {return}
    v:Proposal_View
    testing.expect_value(t,proposal_view(pa,&alice.m,id,&v),vcs.Error.None)
    if testing.expect_value(t,len(v.notes),1) {
        n:=v.notes[0]
        testing.expectf(t,!n.outdated && n.anchor.line==3 && n.path=="readme.txt","the comment re-anchors: %v",n)
    }
    testing.expect_value(t,vcs.machine_proposal_verdict(&alice.m,project,id,.Approve),vcs.Error.None)

    // The CI machine holds a grant of the check right on the project: it
    // reaches alice, takes the proposal and checks a working copy of it.
    issued,ie:=vcs.machine_grant_issue(&alice.m,org,vcs.Dh_Key(ci.m.dh.public),ci.m.identity.key,{.Check,.Read},project,"",7,{net.address_loopback(vcs.runner_port(&alice.runner))},context.temp_allocator)
    if !testing.expectf(t,ie==.None,"alice issues: %s",alice.m.why) {return}
    _,le:=vcs.machine_grant_load(&ci.m,issued)
    if !testing.expectf(t,le==.None,"ci loads: %s",ci.m.why) {return}
    g.m=&ci.m
    if !testing.expect(t,until(15,&g,arrived),"the proposal and its change reach the grant holder") {return}
    pc:=new(Project)
    defer free(pc)
    if !testing.expect_value(t,project_create(pc,fmt.tprintf("%s/ws",ci.folder),&ci.m.store),vcs.Error.None) {return}
    defer project_close(pc)
    testing.expect_value(t,project_link(pc,&ci.m,project),vcs.Error.None)
    _,e=new_change(&pc.workspace,{final},"",nil)
    testing.expect_value(t,e,vcs.Error.None)
    when ODIN_OS==.Windows {command:=[]string{"cmd","/c","exit 0"}} else {command:=[]string{"true"}}
    passed,checked,ce:=check_run(pc,&ci.m,{},"unit",command)
    testing.expectf(t,ce==.None && passed && checked==id,"the holder checks: %v %s",ce,ci.m.why)

    // The policy is met on bob's machine; a move around it is refused.
    g.m=&bob.m
    may_land :: proc(data:rawptr) -> bool {
        g:=(^Goal)(data)
        ps:vcs.Project_State
        if vcs.project_state_load(&g.m.store,g.project,&ps,context.temp_allocator)!=.None {return false}
        f:=vcs.project_state_proposal(&ps,g.proposal)
        if f==nil {return false}
        refusal,e:=vcs.proposal_can_land(&g.m.store,f)
        return e==.None && refusal==.None
    }
    if !testing.expect(t,until(10,&g,may_land),"the approval and the check reach bob") {return}
    testing.expect_value(t,vcs.machine_bookmark_move(&bob.m,project,"main",final),vcs.Error.Unauthorized)
    testing.expectf(t,strings.contains(bob.m.why,"guarded by the org's policy, 1 approval and the check unit"),"the refusal names the policy: %s",bob.m.why)
    testing.expectf(t,vcs.machine_proposal_land(&bob.m,project,id)==.None,"bob lands: %s",bob.m.why)
    for x in ([]^Team_Machine{bob,alice,ci}) {
        g.m,g.revision=&x.m,final
        testing.expect(t,until(10,&g,main_is),"main moves on every machine")
    }
}

// Alice and Bob run their agents over 127.0.0.1 on a public project. Alice
// scopes secrets/ to the org's writers: her snapshot seals the file, Bob, a
// writer, finds it in his working copy, and nothing of it reaches the public
// closure an anonymous peer reads. Once Bob only reads the project, Alice's
// next write is refused until she rotates the scope's key, and the next
// version of the file does not reach Bob's working copy, nor opens for him.
// Removing the scope ends it.
@(test)
a_scope_keeps_private_files_from_non_readers_through_the_shared_operations :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"cook-kai-scope")
    if folder=="" {return}
    team:=new([2]Team_Machine)
    defer free(team)
    alice,bob:=&team[0],&team[1]
    names:=[]string{"alice","bob"}
    for &x,k in team {
        if !team_open(t,&x,folder,names[k]) {return}
    }
    defer for &x in team {team_close(&x)}
    team_user(t,alice,"alice")
    team_user(t,bob,"bob")
    org,_:=vcs.machine_org_create(&alice.m,"studio")
    team_pair(t,alice,bob,org)
    pa:=new(Project)
    defer free(pa)
    a_root:=fmt.tprintf("%s/ws",alice.folder)
    write(t,a_root,"readme.txt","public words\n")
    if !testing.expect_value(t,project_create(pa,a_root,&alice.m.store),vcs.Error.None) {return}
    defer project_close(pa)
    project,je:=project_join(pa,&alice.m,org,true)
    testing.expect_value(t,je,vcs.Error.None)
    _,se:=vcs.machine_scope_add(&alice.m,org,project,{"secrets/**"},.Writer,false)
    testing.expect_value(t,se,vcs.Error.None)
    testing.expect_value(t,project_route(pa),vcs.Error.None)
    write(t,a_root,"secrets/key.txt","first secret\n")
    public_scene:=#load("../../demo/assets/raft/Swimmer.scene")
    scoped_mesh:=#load("../../demo/assets/blockout/column.mesh")
    write(t,a_root,"assets/swimmer.scene",string(public_scene))
    write(t,a_root,"secrets/column.mesh",string(scoped_mesh))
    publish :: proc(t:^testing.T,p:^Project,m:^vcs.Machine) -> vcs.Revision {
        r,e:=new_change(&p.workspace,nil,"",nil)
        testing.expectf(t,e==.None,"%v %s",e,p.routing.refused)
        c,_:=vcs.change_get(&m.store,r,context.temp_allocator)
        parent:=c.parents[0]
        testing.expect_value(t,vcs.bookmark_set(&p.workspace.repo,"work",parent),vcs.Error.None)
        testing.expect_value(t,bookmarks_publish(p,m),vcs.Error.None)
        return parent
    }
    sealed:=publish(t,pa,&alice.m)
    c,_:=vcs.change_get(&alice.m.store,sealed,context.temp_allocator)
    _,in_public,_:=vcs.tree_file(&alice.m.store,c.tree,"secrets/key.txt")
    testing.expect(t,!in_public,"the private file is not in the public change")
    // The publish made the previews of the public scene it added, and none of the scoped mesh.
    {
        s:=&alice.m.store
        scene,in_tree,_:=vcs.tree_file(s,c.tree,"assets/swimmer.scene")
        testing.expect(t,in_tree,"the scene is in the public change")
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        record,state:=vcs.preview_get(s,org,.Summary,vcs.preview_key(.Summary,{},scene.address),&lacking,context.temp_allocator)
        facts:=make([dynamic]vcs.Preview_Fact,context.temp_allocator)
        kind,_:=vcs.preview_summary_decode(record,&facts)
        testing.expectf(t,state==.Found && kind=="prefab","the summary of the scene is published: %v %q",state,kind)
        _,state=vcs.preview_get(s,org,.Detail,vcs.preview_key(.Detail,{},scene.address),&lacking,context.temp_allocator)
        testing.expect_value(t,state,vcs.Preview_State.Found)
        mesh_address,_:=store.put(s,scoped_mesh)
        _,state=vcs.preview_get(s,org,.Summary,vcs.preview_key(.Summary,{},mesh_address),&lacking,context.temp_allocator)
        testing.expect_value(t,state,vcs.Preview_State.None)
        ns:[len(vcs.DDC_PREFIX)+64]u8
        keys,_:=store.ref_list(s,vcs.ddc_namespace(org,&ns),context.temp_allocator)
        testing.expectf(t,len(keys)==2,"the summary and the detail of the scene alone: %d keys",len(keys))
    }

    for &x in team {
        if !team_start(t,&x,true) {return}
    }
    alice.beacons[0]=net.address_loopback(vcs.runner_port(&bob.runner))
    bob.beacons[0]=net.address_loopback(vcs.runner_port(&alice.runner))
    alice.runner.desc.beacon_targets,bob.runner.desc.beacon_targets=alice.beacons[:],bob.beacons[:]
    for &x in team {team_go(&x)}

    // Bob, a writer, reads the scope: his working copy has the file.
    Goal :: struct {p:^Project,m:^vcs.Machine,text:string,want:vcs.Revision}
    pb:=new(Project)
    defer free(pb)
    b_root:=fmt.tprintf("%s/ws",bob.folder)
    if !testing.expect_value(t,project_create(pb,b_root,&bob.m.store),vcs.Error.None) {return}
    defer project_close(pb)
    g:=Goal{p=pb,m=&bob.m}
    found :: proc(data:rawptr) -> bool {
        g:=(^Goal)(data)
        r,e:=revision_resolve(g.p,g.m,g.text)
        if e!=.None || (g.want!={} && r!=g.want) || !whole(&g.m.store,r) {return false}
        project,_,_:=vcs.machine_project_of(g.m,g.p.workspace.repo.id)
        ps:vcs.Project_State
        if vcs.project_state_load(&g.m.store,project,&ps,context.temp_allocator)!=.None {return false}
        keyrings:=make([dynamic]^vcs.Keyring_Fold,context.temp_allocator)
        vcs.machine_keyrings(&g.m.store,&ps.org,&keyrings,context.temp_allocator)
        for k in keyrings {
            if r2,_,re:=vcs.overlay_record_get(&g.m.store,k.project,k.scope,r,context.temp_allocator);re==.None {
                for o in r2.objects {
                    if !vcs.object_whole(&g.m.store,o) {return false}
                }
                return vcs.object_whole(&g.m.store,r2.tree_root)
            }
        }
        return false
    }
    project_logged :: proc(data:rawptr) -> bool {
        x:=(^struct{m:^vcs.Machine,project:vcs.Log_Id})(data)
        l:vcs.Log
        vcs.log_init(&l,x.project,context.temp_allocator)
        return vcs.log_open(&x.m.store,&l,x.project,.Project)==.None
    }
    pl:=struct{m:^vcs.Machine,project:vcs.Log_Id}{&bob.m,project}
    if !testing.expect(t,until(10,&pl,project_logged),"the project's log reaches bob") {return}
    testing.expect_value(t,project_link(pb,&bob.m,project),vcs.Error.None)
    g.text=fmt.tprintf("%s:work",vcs.device_display(&pb.org,alice.m.identity.key))
    if !testing.expectf(t,until(10,&g,found),"alice's work and its overlay reach bob: %s",bob.m.why) {return}
    testing.expect_value(t,project_route(pb),vcs.Error.None)
    on,_:=revision_resolve(pb,&bob.m,g.text)
    testing.expect_value(t,on,sealed)
    _,e:=new_change(&pb.workspace,{on},"",nil)
    testing.expect_value(t,e,vcs.Error.None)
    secret,has:=read(b_root,"secrets/key.txt")
    testing.expect(t,has && secret=="first secret\n","a reader finds the private file in his working copy")
    public,_:=read(b_root,"readme.txt")
    testing.expect_value(t,public,"public words\n")
    // Restoring alice's change brings its private file back to a reader.
    testing.expect(t,os.remove(fmt.tprintf("%s/secrets/key.txt",b_root))==nil)
    testing.expect_value(t,restore(&pb.workspace,sealed,nil),vcs.Error.None)
    secret,has=read(b_root,"secrets/key.txt")
    testing.expect(t,has && secret=="first secret\n","a reader's restore writes the private file")

    // Bob now only reads the project: Alice's write waits for a rotation.
    testing.expect_value(t,vcs.machine_role_set(&alice.m,org,bob.m.user,.Reader),vcs.Error.None)
    testing.expect_value(t,project_route(pa),vcs.Error.None)
    write(t,a_root,"secrets/key.txt","second secret\n")
    _,e=vcs.workspace_snapshot(&pa.workspace)
    testing.expect_value(t,e,vcs.Error.Unauthorized)
    testing.expectf(t,strings.contains(pa.routing.refused,"mirai kai scope rotate"),"the refusal names the rotation: %s",pa.routing.refused)
    o:vcs.Org_State
    testing.expect_value(t,vcs.org_state_load(&alice.m.store,org,&o,context.temp_allocator),vcs.Error.None)
    epoch,ro:=vcs.machine_scope_rotate(&alice.m,org,project,o.fold.scopes[0].scope)
    testing.expectf(t,ro==.None && epoch==2,"alice rotates: %s",alice.m.why)
    testing.expect_value(t,project_route(pa),vcs.Error.None)
    resealed:=publish(t,pa,&alice.m)

    // The new version does not reach Bob, and his old copy goes.
    g.want=resealed
    if !testing.expect(t,until(10,&g,found),"alice's new work reaches bob") {return}
    testing.expect_value(t,project_route(pb),vcs.Error.None)
    on,_=revision_resolve(pb,&bob.m,g.text)
    testing.expect_value(t,on,resealed)
    _,e=new_change(&pb.workspace,{on},"",nil)
    testing.expect_value(t,e,vcs.Error.None)
    _,has=read(b_root,"secrets/key.txt")
    testing.expect(t,!has,"a non-reader's working copy loses the private file")
    testing.expect_value(t,restore(&pb.workspace,sealed,nil),vcs.Error.None)
    _,has=read(b_root,"secrets/key.txt")
    testing.expect(t,!has,"nor does a restore of a change he read before give it back")
    rings:=make([dynamic]^vcs.Keyring_Fold,context.temp_allocator)
    testing.expect_value(t,vcs.machine_keyrings(&bob.m.store,&pb.org,&rings,context.temp_allocator),vcs.Error.None)
    if testing.expect_value(t,len(rings),1) {
        device:=vcs.machine_overlay_device(&bob.m)
        _,ke:=vcs.keyring_epoch_key(rings[0],&device,rings[0].epoch)
        testing.expect(t,ke!=.None,"nor does the scope's epoch open for him")
    }

    // An anonymous peer reads what the shared bookmarks reach: none of the overlay's chunks are in it.
    testing.expectf(t,vcs.machine_bookmark_move(&alice.m,project,"main",resealed)==.None,"alice shares her work: %s",alice.m.why)
    team_halt(alice)
    a:=&alice.runner.orgs[0].agent
    rec,_,re:=vcs.overlay_record_get(&alice.m.store,project,o.fold.scopes[0].scope,resealed,context.temp_allocator)
    testing.expect_value(t,re,vcs.Error.None)
    chunks:=make([dynamic]store.Hash,context.temp_allocator)
    for x in rec.objects {vcs.object_chunks(&alice.m.store,x,&chunks)}
    vcs.object_chunks(&alice.m.store,rec.tree_root,&chunks)
    leaked:=0
    for x in chunks {
        if vcs.closure_has(a.closure.public[:],x) {leaked+=1}
    }
    testing.expect(t,len(chunks)>0 && len(a.closure.public)>0 && leaked==0,"no chunk of the overlay is public")

    // Removing the scope ends it.
    testing.expect_value(t,vcs.machine_scope_remove(&alice.m,org,project,o.fold.scopes[0].scope),vcs.Error.None)
    testing.expect_value(t,project_route(pa),vcs.Error.None)
    testing.expect_value(t,len(pa.org.fold.scopes),0)
}
