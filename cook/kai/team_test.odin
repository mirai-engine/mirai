package kai_assets

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
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
    published,pe:=publish(&p,&mac.team,BOOKMARK_DEFAULT,"first version",nil)
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
    if _,e:=vcs.agent_join(&pc.agent,text);!testing.expectf(t,e==.None,"join: %v %s",e,pc.agent.team.why) {return}

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
    second,se:=publish(&q,&pc.team,BOOKMARK_DEFAULT,"edit",nil)
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
    _,pe:=publish(&p,&mac.team,BOOKMARK_DEFAULT,"merge",nil)
    testing.expectf(t,pe==.Invalid_Argument && strings.contains(mac.team.why,"conflict"),"refused: %v %s",pe,mac.team.why)
    _,_,re:=vcs.repo_refs_head(&mac.s,org,p.workspace.repo.id,context.temp_allocator)
    testing.expect_value(t,re,vcs.Error.Missing)
}
