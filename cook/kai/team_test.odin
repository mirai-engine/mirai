package kai_assets

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

@(private="file")
Team_Machine :: struct {
    s:store.Store,
    team:vcs.Team,
    agent:vcs.Agent,
    running:bool,
    folder:string,
}

@(private="file")
team_open :: proc(t:^testing.T,x:^Team_Machine,folder,name:string) -> bool {
    x.folder=strings.concatenate({folder,"/",name},context.temp_allocator)
    e:store.Error
    x.s,e=store.open(strings.concatenate({x.folder,"/store"},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return false}
    if !testing.expect_value(t,vcs.team_open(&x.team,&x.s),vcs.Error.None) {return false}
    return testing.expect_value(t,vcs.team_profile_set(&x.team,name,"laptop"),vcs.Error.None)
}

@(private="file")
team_close :: proc(x:^Team_Machine) {
    if x.running {vcs.agent_stop(&x.agent)}
    vcs.team_close(&x.team)
    store.close(&x.s)
}

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

// What the editor and the launcher do with a team, without a terminal: a
// project is published to main in an org (one record names the repository
// and whether it is public), a second machine joins by an invite, pulls the
// repository into an empty folder and writes the files of main; then its
// edit published to main reaches the first, which writes it with a new change.
// A file named like a secret is what a public publish warns of.
@(test)
a_project_publishes_to_main_and_a_paired_machine_pulls_it :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-team-flow")
    if folder=="" {return}
    mac,pc:Team_Machine
    if !team_open(t,&mac,folder,"Ana") || !team_open(t,&pc,folder,"Ben") {return}
    defer team_close(&mac)
    defer team_close(&pc)
    root:=strings.concatenate({mac.folder,"/game"},context.temp_allocator)
    write(t,root,"project.mirai","{\"name\": \"Lighthouse\"}\n")
    write(t,root,"assets/readme.txt","the first version\n")
    write(t,root,".env","TOKEN=1\n")
    p:Project
    if !testing.expect_value(t,project_create(&p,root,&mac.s),vcs.Error.None) {return}
    defer project_close(&p)
    org,oe:=vcs.team_org_create(&mac.team,"studio")
    testing.expect_value(t,oe,vcs.Error.None)
    link,je:=project_join(&p,&mac.team,org,true)
    testing.expect_value(t,je,vcs.Error.None)
    published,_,pe:=publish(&p,&mac.team,BOOKMARK_DEFAULT,"first version",nil)
    if !testing.expectf(t,pe==.None,"publish: %v %s",pe,mac.team.why) {return}
    v:Org_View
    testing.expect_value(t,org_view(&mac.team,org,&v),vcs.Error.None)
    testing.expectf(t,len(v.repos)==1 && v.repos[0].name=="Lighthouse" && v.repos[0].public && v.repos[0].main!="" && v.repos[0].linked,"the repository is named as the project, public, on main: %v",v.repos)
    secrets:=secret_paths(&p,published)
    testing.expect(t,len(secrets)==1 && secrets[0]==".env","a file named like a secret is told before a public publish")

    testing.expect_value(t,vcs.agent_start(&mac.agent,&mac.team,{port=0,host="127.0.0.1"}),vcs.Error.None)
    mac.running=true
    testing.expect_value(t,vcs.agent_start(&pc.agent,&pc.team,{port=-1}),vcs.Error.None)
    pc.running=true
    text,ie:=vcs.team_invite(&mac.team,org,.Writer,"",{fmt.tprintf("127.0.0.1:%d",vcs.agent_port(&mac.agent))},context.temp_allocator)
    testing.expect_value(t,ie,vcs.Error.None)
    why:string
    if _,e:=vcs.agent_join(&pc.agent,text,&why);!testing.expectf(t,e==.None,"join: %v %s",e,why) {return}

    // Pull into an empty folder: the files come once the agent has every object of main.
    clone_root:=strings.concatenate({pc.folder,"/Lighthouse"},context.temp_allocator)
    q:Project
    if !testing.expectf(t,project_clone(&q,&pc.team,clone_root,&pc.s,org,link.repo)==.None,"clone: %s",pc.team.why) {return}
    defer project_close(&q)
    vcs.agent_changed(&pc.agent)
    Pulling :: struct {q:^Project,team:^vcs.Team}
    pulling:=Pulling{&q,&pc.team}
    checked:=until(20,&pulling,proc(data:rawptr) -> bool {
        x:=(^Pulling)(data)
        _,e:=clone_checkout(x.q,x.team)
        return e==.None
    })
    testing.expectf(t,checked,"the files of main are written: %s",pc.team.why)
    text_here,ok:=read(clone_root,"assets/readme.txt")
    testing.expect(t,ok && text_here=="the first version\n","the pulled project has main's files")

    // The second machine publishes an edit; the first takes it as a new change.
    write(t,clone_root,"assets/readme.txt","edited on the PC\n")
    second,_,se:=publish(&q,&pc.team,BOOKMARK_DEFAULT,"edit",nil)
    testing.expectf(t,se==.None,"the writer publishes: %s",pc.team.why)
    vcs.agent_changed(&pc.agent)
    Arrived :: struct {s:^store.Store,org:vcs.Org_Id,repo:vcs.Repo_Id,target:vcs.Revision}
    arrived:=Arrived{&mac.s,org,link.repo,second}
    came:=until(20,&arrived,proc(data:rawptr) -> bool {
        x:=(^Arrived)(data)
        refs,_,e:=vcs.repo_refs_head(x.s,x.org,x.repo,context.temp_allocator)
        if e!=.None || len(refs.bookmarks)==0 || refs.bookmarks[0].target!=x.target {return false}
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        vcs.closure_walk(x.s,{x.target},nil,&missing)
        return len(missing)==0
    })
    testing.expect(t,came,"the first machine has the edit")
    target,re:=revision_resolve(&p,&mac.team,BOOKMARK_DEFAULT)
    testing.expect(t,re==.None,"main resolves")
    _,ne:=new_change(&p.workspace,{target},"",nil)
    testing.expect_value(t,ne,vcs.Error.None)
    edited,_:=read(root,"assets/readme.txt")
    testing.expect_value(t,edited,"edited on the PC\n")
}

// Publishing a project shares the builds of the packages it pins as this machine has them:
// by manifest (asset.REF_BUILDS) and by import key (asset.REF_IMPORTS), each one record of the
// org's derived data, which the org's node then holds whole. Both agents count what moved, by
// peer and kind, and a second publish adds no record.
@(test)
a_publish_shares_the_builds_of_the_pinned_packages :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-team-ddc")
    if folder=="" {return}
    mac,server:Team_Machine
    if !team_open(t,&mac,folder,"Ana") || !team_open(t,&server,folder,"cloud") {return}
    defer team_close(&mac)
    defer team_close(&server)
    root:=strings.concatenate({mac.folder,"/game"},context.temp_allocator)
    write(t,root,"project.mirai","{\"name\": \"Dreamscape\"}\n")
    // A package the project pins, with its build: a texture.
    PACKAGE,TEXTURE :: base.Asset_Id{1,1},base.Asset_Id{1,2}
    blob,be:=store.put(&mac.s,make([]u8,200_000,context.temp_allocator))
    if !testing.expect_value(t,be,store.Error.None) {return}
    x:=asset.Package{id=PACKAGE,name="sign",origin={path="assets/sign.png",importer="image"},identity=store.address_of_bytes(transmute([]u8)string("sign"))}
    x.assets=make([dynamic]asset.Package_Asset,context.temp_allocator)
    append(&x.assets,asset.Package_Asset{kind=asset.KIND_TEXTURE,name="sign",id=TEXTURE})
    manifest,me:=asset.package_put(&mac.s,&x)
    if !testing.expect_value(t,me,asset.Error.None) {return}
    b:=asset.Build{package_id=PACKAGE,key=store.address_of_bytes(transmute([]u8)string("key")),final=true}
    b.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    append(&b.outputs,asset.Build_Output{id=TEXTURE,kind=asset.KIND_TEXTURE,object=blob})
    build,ue:=asset.build_put(&mac.s,&b)
    if !testing.expect_value(t,ue,asset.Error.None) {return}
    select_digits,key_digits:[64]u8
    select:=store.hex(asset.build_select(manifest,&x),&select_digits)
    key:=store.hex(b.key,&key_digits)
    testing.expect_value(t,store.ref_set(&mac.s,asset.REF_BUILDS,select,build),store.Error.None)
    testing.expect_value(t,store.ref_set(&mac.s,asset.REF_IMPORTS,key,build),store.Error.None)
    // And one it pins with no build in the store: nothing to share of it.
    BARE,BARE_TEXTURE :: base.Asset_Id{2,1},base.Asset_Id{2,2}
    y:=asset.Package{id=BARE,name="rock",origin={path="assets/rock.png",importer="image"},identity=store.address_of_bytes(transmute([]u8)string("rock"))}
    y.assets=make([dynamic]asset.Package_Asset,context.temp_allocator)
    append(&y.assets,asset.Package_Asset{kind=asset.KIND_TEXTURE,name="rock",id=BARE_TEXTURE})
    bare,ye:=asset.package_put(&mac.s,&y)
    if !testing.expect_value(t,ye,asset.Error.None) {return}
    list:asset.Packages
    list.packages=make([dynamic]asset.Project_Package,context.temp_allocator)
    entry:=asset.Project_Package{id=PACKAGE,manifest=manifest}
    bare_entry:=asset.Project_Package{id=BARE,manifest=bare}
    append(&list.packages,entry,bare_entry)
    testing.expect_value(t,asset.packages_save(root,&list),asset.Error.None)
    testing.expect_value(t,asset.package_file_save(&mac.s,root,&entry),asset.Error.None)
    testing.expect_value(t,asset.package_file_save(&mac.s,root,&bare_entry),asset.Error.None)

    p:Project
    if !testing.expect_value(t,project_create(&p,root,&mac.s),vcs.Error.None) {return}
    defer project_close(&p)
    org,_:=vcs.team_org_create(&mac.team,"studio")
    _,je:=project_join(&p,&mac.team,org,false)
    testing.expect_value(t,je,vcs.Error.None)
    testing.expect_value(t,vcs.agent_start(&mac.agent,&mac.team,{port=0,host="127.0.0.1"}),vcs.Error.None)
    mac.running=true
    testing.expect_value(t,vcs.agent_start(&server.agent,&server.team,{port=-1,node=true}),vcs.Error.None)
    server.running=true
    text,_:=vcs.team_invite(&mac.team,org,.Node,"",{fmt.tprintf("127.0.0.1:%d",vcs.agent_port(&mac.agent))},context.temp_allocator)
    why:string
    if _,e:=vcs.agent_join(&server.agent,text,&why);!testing.expectf(t,e==.None,"the node joins: %s",why) {return}

    _,ddc,pe:=publish(&p,&mac.team,BOOKMARK_DEFAULT,"first",nil)
    if !testing.expectf(t,pe==.None,"publish: %s",mac.team.why) {return}
    testing.expectf(t,ddc==Ddc_Published{published=2,missing=1},"both keys of the built package are shared and the bare one is missing: %v",ddc)
    testing.expect(t,strings.contains(ddc_missing_text(ddc),"1 pinned package has no whole build"),"the publish says what it could not share")
    testing.expect_value(t,ddc_missing_text({published=2}),"")
    keys:=[2]store.Hash{ddc_key(asset.REF_BUILDS,select),ddc_key(asset.REF_IMPORTS,key)}
    records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
    for k in keys {
        testing.expect_value(t,vcs.ddc_lookup(&mac.s,org,k,&records),vcs.Error.None)
        testing.expectf(t,len(records)==1,"one record of each key: %d",len(records))
    }
    testing.expect_value(t,project_ddc_publish(&p,&mac.team),Ddc_Published{missing=1})
    vcs.agent_changed(&mac.agent)
    Kept :: struct {s:^store.Store,org:vcs.Org_Id,keys:[2]store.Hash}
    kept:=Kept{&server.s,org,keys}
    whole:=until(20,&kept,proc(data:rawptr) -> bool {
        x:=(^Kept)(data)
        records:=make([dynamic]vcs.DDC_Record,context.temp_allocator)
        lacking:=make([dynamic]store.Hash,context.temp_allocator)
        for k in x.keys {
            if vcs.ddc_lookup(x.s,x.org,k,&records)!=.None || len(records)==0 {return false}
            if _,e:=vcs.ddc_output_lacking(x.s,records[0].output_root,&lacking);e!=.None || len(lacking)>0 {return false}
        }
        return true
    })
    if !testing.expect(t,whole,"the node holds both builds whole") {return}
    moved :: proc(a:^vcs.Agent,direction:vcs.Transfer_Direction,peer:string) -> (bytes:i64) {
        list:=make([dynamic]vcs.Transfer,context.temp_allocator)
        vcs.agent_transfers(a,&list,context.temp_allocator)
        for x in list {
            if x.direction==direction && x.kind==.Ddc && x.label=="DDC" && x.peer_name==peer {bytes+=x.bytes}
        }
        return
    }
    testing.expectf(t,moved(&mac.agent,.Upload,"cloud (laptop)")>=200_000,"the publisher counts what it sent the node")
    testing.expectf(t,moved(&server.agent,.Download,"Ana (laptop)")>=200_000,"the node counts what it took")
}

// A change with a file in conflict is not published: the org's machines take
// what main names as it is.
@(test)
a_change_in_conflict_is_not_published :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-team-conflict")
    if folder=="" {return}
    mac:Team_Machine
    if !team_open(t,&mac,folder,"Ana") {return}
    defer team_close(&mac)
    root:=strings.concatenate({mac.folder,"/game"},context.temp_allocator)
    write(t,root,"project.mirai","{\"name\": \"Lighthouse\"}\n")
    write(t,root,"a.txt","base\n")
    p:Project
    if !testing.expect_value(t,project_create(&p,root,&mac.s),vcs.Error.None) {return}
    defer project_close(&p)
    org,_:=vcs.team_org_create(&mac.team,"studio")
    project_join(&p,&mac.team,org,false)
    w:=&p.workspace
    base_change,_:=new_change(w,nil,"base",nil)
    sides:[2]vcs.Revision
    for text,k in ([2]string{"ours\n","theirs\n"}) {
        new_change(w,{base_change},"",nil)
        write(t,root,"a.txt",text)
        sides[k],_=new_change(w,nil,"",nil,closing=text)
        sides[k],_=revision_find(w,"@-")
    }
    _,me:=new_change(w,sides[:],"",nil)
    testing.expect_value(t,me,vcs.Error.None)
    _,_,pe:=publish(&p,&mac.team,BOOKMARK_DEFAULT,"merge",nil)
    testing.expectf(t,pe==.Invalid_Argument && strings.contains(mac.team.why,"conflict"),"refused: %v %s",pe,mac.team.why)
    _,_,re:=vcs.repo_refs_head(&mac.s,org,p.workspace.repo.id,context.temp_allocator)
    testing.expect_value(t,re,vcs.Error.Missing)
}

// The checkout of a plugin from git the manifest names is git's, as the
// project's .gitignore says: a workspace over the project tracks the
// project's own plugins and never that checkout, which each machine makes.
@(test)
a_workspace_leaves_out_the_checkouts_of_plugins_from_git :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-git-plugins")
    if folder=="" {return}
    mac:Team_Machine
    if !team_open(t,&mac,folder,"Ana") {return}
    defer team_close(&mac)
    root:=strings.concatenate({mac.folder,"/game"},context.temp_allocator)
    m:=project.manifest_default("Game")
    base.text_set(m.sources[0].name[:],"unreal")
    base.text_set(m.sources[0].url[:],"https://example.com/unreal.git")
    base.text_set(m.sources[0].commit[:],"e0509415e4a0e0509415e4a0e0509415e4a0e050")
    write(t,root,project.PROJECT_FILE,project.manifest_text(&m,context.temp_allocator))
    write(t,root,"assets/readme.txt","the game\n")
    write(t,root,"plugins/unreal/plugin.mirai","{\"name\": \"unreal\"}\n")
    write(t,root,"plugins/unreal/runtime/unreal.odin","package unreal\n")
    write(t,root,"plugins/unreal_tools/plugin.mirai","{\"name\": \"unreal_tools\"}\n")
    write(t,root,"plugins/mine/plugin.mirai","{\"name\": \"mine\"}\n")
    p:Project
    if !testing.expect_value(t,project_create(&p,root,&mac.s),vcs.Error.None) {return}
    defer project_close(&p)
    w:=&p.workspace
    c,ce:=vcs.change_get(w.repo.s,vcs.repo_working(&w.repo),context.temp_allocator)
    if !testing.expect_value(t,ce,vcs.Error.None) {return}
    files:=make([dynamic]vcs.File,context.temp_allocator)
    testing.expect_value(t,vcs.tree_files(w.repo.s,c.tree,&files,context.temp_allocator),vcs.Error.None)
    paths:=make([dynamic]string,context.temp_allocator)
    for f in files {append(&paths,f.path)}
    testing.expectf(t,slice.equal(paths[:],[]string{"assets/readme.txt","plugins/mine/plugin.mirai","plugins/unreal_tools/plugin.mirai","project.mirai"}),"the checkout of unreal is left out: %v",paths)
    testing.expect(t,!tracked_path(&p.tracked,"plugins/unreal") && !tracked_path(&p.tracked,"plugins/unreal/runtime/unreal.odin"))
    testing.expect(t,tracked_path(&p.tracked,"plugins") && tracked_path(&p.tracked,"plugins/mine/plugin.mirai"))
}

// A workspace the org's main moved past is told so without its lock, and an
// update takes main into it: its local change and its edit not committed stay,
// a file both sides changed apart becomes a conflict value, main's edits
// arrive, and a workspace with nothing of its own goes onto main as it is.
@(test)
a_workspace_behind_main_updates_and_keeps_its_work :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-team-update")
    if folder=="" {return}
    mac:Team_Machine
    if !team_open(t,&mac,folder,"Ana") {return}
    defer team_close(&mac)
    a_root:=strings.concatenate({mac.folder,"/a"},context.temp_allocator)
    write(t,a_root,"project.mirai","{\"name\": \"Lighthouse\"}\n")
    write(t,a_root,"assets/shared.txt","one\ntwo\nthree\n")
    write(t,a_root,"assets/clash.txt","base\n")
    a:Project
    if !testing.expect_value(t,project_create(&a,a_root,&mac.s),vcs.Error.None) {return}
    defer project_close(&a)
    org,_:=vcs.team_org_create(&mac.team,"studio")
    link,je:=project_join(&a,&mac.team,org,false)
    testing.expect_value(t,je,vcs.Error.None)
    _,_,pe:=publish(&a,&mac.team,BOOKMARK_DEFAULT,"first",nil)
    if !testing.expectf(t,pe==.None,"publish: %s",mac.team.why) {return}

    // Two more workspaces of the repository on main: b works on it, c does not.
    pulled :: proc(t:^testing.T,mac:^Team_Machine,root:string,org:vcs.Org_Id,repo:vcs.Repo_Id) -> bool {
        q:Project
        if !testing.expectf(t,project_clone(&q,&mac.team,root,&mac.s,org,repo)==.None,"clone: %s",mac.team.why) {return false}
        defer project_close(&q)
        _,e:=clone_checkout(&q,&mac.team)
        return testing.expectf(t,e==.None,"checkout: %s",mac.team.why)
    }
    b_root:=strings.concatenate({mac.folder,"/b"},context.temp_allocator)
    c_root:=strings.concatenate({mac.folder,"/c"},context.temp_allocator)
    if !pulled(t,&mac,b_root,org,link.repo) || !pulled(t,&mac,c_root,org,link.repo) {return}
    b:Project
    if !testing.expect_value(t,project_open(&b,b_root,&mac.s),vcs.Error.None) {return}
    write(t,b_root,"assets/local.txt","committed here\n")
    _,ne:=new_change(&b.workspace,nil,"",nil,closing="local commit")
    testing.expect_value(t,ne,vcs.Error.None)
    write(t,b_root,"assets/edit.txt","not committed\n")
    write(t,b_root,"assets/clash.txt","ours, on b\n")
    _,se:=snapshot(&b.workspace)
    testing.expect_value(t,se,vcs.Error.None)
    project_close(&b)

    state:=project_sync_state(&mac.s,&mac.team,b_root)
    testing.expectf(t,state.sync==.Ahead,"b is ahead of main and not behind it: %v",state)
    state=project_sync_state(&mac.s,&mac.team,c_root)
    testing.expectf(t,state.sync==.Synced,"c is on main: %v",state)

    write(t,a_root,"assets/shared.txt","one\ntwo\nthree\nfour\n")
    write(t,a_root,"assets/clash.txt","theirs, on a\n")
    _,_,pe=publish(&a,&mac.team,BOOKMARK_DEFAULT,"second",nil)
    if !testing.expectf(t,pe==.None,"publish: %s",mac.team.why) {return}

    state=project_sync_state(&mac.s,&mac.team,b_root)
    testing.expectf(t,state.sync==.Diverged && state.main_here,"b is behind main and still has its own: %v",state)
    state=project_sync_state(&mac.s,&mac.team,c_root)
    testing.expectf(t,state.sync==.Behind && state.main_here,"c is only behind main: %v",state)

    result,ue:=project_update_folder(&mac.s,&mac.team,b_root)
    if !testing.expectf(t,ue==.None,"update: %v %s",ue,mac.team.why) {return}
    testing.expectf(t,!result.up_to_date && result.conflicts==1,"the file both changed is the one conflict: %v",result)
    expect_text :: proc(t:^testing.T,root,path,want:string,loc:=#caller_location) {
        text,ok:=read(root,path)
        testing.expectf(t,ok && text==want,"%s holds %q, not %q",path,text,want,loc=loc)
    }
    expect_text(t,b_root,"assets/shared.txt","one\ntwo\nthree\nfour\n")
    expect_text(t,b_root,"assets/local.txt","committed here\n")
    expect_text(t,b_root,"assets/edit.txt","not committed\n")
    clash,_:=read(b_root,"assets/clash.txt")
    testing.expectf(t,strings.contains(clash,"ours, on b") && strings.contains(clash,"theirs, on a"),"the conflict keeps both sides: %q",clash)
    if testing.expect_value(t,project_open(&b,b_root,&mac.s),vcs.Error.None) {
        rows:=make([dynamic]Log_Row,context.temp_allocator)
        testing.expect_value(t,log(&b.workspace,0,&rows),vcs.Error.None)
        described:=make([dynamic]string,context.temp_allocator)
        for row in rows {append(&described,row.change.description)}
        testing.expectf(t,slice.contains(described[:],"local commit") && slice.contains(described[:],"second"),"the local commit and main are both in the history: %v",described)
        project_close(&b)
    }
    state=project_sync_state(&mac.s,&mac.team,b_root)
    testing.expectf(t,state.sync==.Ahead && state.conflicts==1,"b holds main now, has its own still and a conflict: %v",state)
    result,ue=project_update_folder(&mac.s,&mac.team,b_root)
    testing.expectf(t,ue==.None && result.up_to_date,"a second update has nothing to take: %v %v",ue,result)

    result,ue=project_update_folder(&mac.s,&mac.team,c_root)
    testing.expectf(t,ue==.None && !result.up_to_date && result.conflicts==0,"c updates cleanly: %v %v %s",ue,result,mac.team.why)
    expect_text(t,c_root,"assets/clash.txt","theirs, on a\n")
    state=project_sync_state(&mac.s,&mac.team,c_root)
    testing.expectf(t,state.sync==.Synced,"c is on main again, synced: %v",state)
}

// A working copy whose edits are what main took since is main once updated:
// the update is on main alone, not a merge, and nothing is left to publish.
// A merge of the working copy and main whose files are main's, with nothing
// described, is synced too.
@(test)
an_update_to_what_main_holds_is_main :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-team-update-same")
    if folder=="" {return}
    mac:Team_Machine
    if !team_open(t,&mac,folder,"Ana") {return}
    defer team_close(&mac)
    a_root:=strings.concatenate({mac.folder,"/a"},context.temp_allocator)
    write(t,a_root,"project.mirai","{\"name\": \"Lighthouse\"}\n")
    write(t,a_root,"assets/shared.txt","one\n")
    a:Project
    if !testing.expect_value(t,project_create(&a,a_root,&mac.s),vcs.Error.None) {return}
    defer project_close(&a)
    org,_:=vcs.team_org_create(&mac.team,"studio")
    link,_:=project_join(&a,&mac.team,org,false)
    _,_,pe:=publish(&a,&mac.team,BOOKMARK_DEFAULT,"first",nil)
    if !testing.expectf(t,pe==.None,"publish: %s",mac.team.why) {return}
    roots:[2]string
    for name,k in ([2]string{"b","c"}) {
        roots[k]=strings.concatenate({mac.folder,"/",name},context.temp_allocator)
        q:Project
        if !testing.expectf(t,project_clone(&q,&mac.team,roots[k],&mac.s,org,link.repo)==.None,"clone: %s",mac.team.why) {return}
        _,ce:=clone_checkout(&q,&mac.team)
        testing.expectf(t,ce==.None,"checkout: %s",mac.team.why)
        // The same edit main takes next, not committed.
        write(t,roots[k],"assets/shared.txt","one\ntwo\n")
        _,se:=snapshot(&q.workspace)
        testing.expect_value(t,se,vcs.Error.None)
        project_close(&q)
    }
    write(t,a_root,"assets/shared.txt","one\ntwo\n")
    second,_,se:=publish(&a,&mac.team,BOOKMARK_DEFAULT,"second",nil)
    if !testing.expectf(t,se==.None,"publish: %s",mac.team.why) {return}
    state:=project_sync_state(&mac.s,&mac.team,roots[0])
    testing.expectf(t,state.sync==.Diverged,"b has its edit and lacks main: %v",state)
    result,ue:=project_update_folder(&mac.s,&mac.team,roots[0])
    if !testing.expectf(t,ue==.None,"update: %v %s",ue,mac.team.why) {return}
    testing.expectf(t,!result.up_to_date && result.conflicts==0,"b updates cleanly: %v",result)
    c,_:=vcs.change_get(&mac.s,result.revision,context.temp_allocator)
    testing.expectf(t,len(c.parents)==1 && c.parents[0]==second,"the update is on main alone: %v",c.parents)
    state=project_sync_state(&mac.s,&mac.team,roots[0])
    testing.expectf(t,state.sync==.Synced && state.conflicts==0,"b is main, nothing to publish: %v",state)

    // A merge made before updates collapsed: its files are main's.
    q:Project
    if !testing.expect_value(t,project_open(&q,roots[1],&mac.s),vcs.Error.None) {return}
    working:=vcs.repo_working(&q.workspace.repo)
    _,me:=new_change(&q.workspace,{working,second},"",nil)
    testing.expect_value(t,me,vcs.Error.None)
    project_close(&q)
    state=project_sync_state(&mac.s,&mac.team,roots[1])
    testing.expectf(t,state.sync==.Synced,"a merge holding main's files alone is synced: %v",state)
}

// Restoring the pins of the packages takes back packages.mirai and the manifests of
// packages/ as the working copy's parent has them, removes one it added, and leaves
// every other edit of the working copy as it is.
@(test)
restoring_the_package_pins_leaves_every_other_edit :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-packages-restore")
    if folder=="" {return}
    mac:Team_Machine
    if !team_open(t,&mac,folder,"Ana") {return}
    defer team_close(&mac)
    root:=strings.concatenate({mac.folder,"/game"},context.temp_allocator)
    write(t,root,"project.mirai","{\"name\": \"Lighthouse\"}\n")
    write(t,root,"packages.mirai","pins one\n")
    write(t,root,"packages/aa.mirai","manifest one\n")
    write(t,root,"assets/a.txt","first\n")
    p:Project
    if !testing.expect_value(t,project_create(&p,root,&mac.s),vcs.Error.None) {return}
    _,ne:=new_change(&p.workspace,nil,"",nil,closing="first")
    testing.expect_value(t,ne,vcs.Error.None)
    project_close(&p)
    testing.expect(t,!project_packages_dirty(&mac.s,root),"nothing changed yet")

    write(t,root,"packages.mirai","pins two, longer\n")
    write(t,root,"packages/aa.mirai","manifest two, longer\n")
    write(t,root,"packages/bb.mirai","added\n")
    write(t,root,"packages/notes/cc.mirai","not a pin\n")
    write(t,root,"assets/a.txt","second, longer\n")
    write(t,root,"assets/b.txt","added\n")
    testing.expect(t,project_packages_dirty(&mac.s,root),"the pins changed")
    changed,re:=project_packages_restore(&mac.s,root)
    testing.expect_value(t,re,vcs.Error.None)
    slice.sort(changed)
    testing.expectf(t,slice.equal(changed,[]string{"packages.mirai","packages/aa.mirai","packages/bb.mirai"}),"only the pins are written: %v",changed)
    for x in ([][2]string{{"packages.mirai","pins one\n"},{"packages/aa.mirai","manifest one\n"},{"packages/notes/cc.mirai","not a pin\n"},{"assets/a.txt","second, longer\n"},{"assets/b.txt","added\n"}}) {
        text,ok:=read(root,x[0])
        testing.expectf(t,ok && text==x[1],"%s holds %q",x[0],text)
    }
    testing.expect(t,!os.exists(strings.concatenate({root,"/packages/bb.mirai"},context.temp_allocator)),"the pin added is removed")
    testing.expect(t,!project_packages_dirty(&mac.s,root),"the pins are as the parent has them")
    for x in ([]struct{path:string,pin:bool}{{"packages.mirai",true},{"packages/aa.mirai",true},{"packages/notes/cc.mirai",false},{"packages/.mirai",false},{"packages",false},{"assets/packages.mirai",false},{"packages.mirai.bak",false}}) {
        testing.expectf(t,packages_path(x.path)==x.pin,"%s is a pin: %v",x.path,x.pin)
    }
}
