package main

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:project"
import "mirai:store"

KAI_USAGE :: "kai init|status|snapshot|log [-n N]|diff [change]|undo|conflicts | kai prune | kai new [change...] [-m text] | kai describe [change] -m text | kai split [-r change] [-m text] <path...> | kai restore <change> | kai bookmarks [move <name> <change>] | kai publish [bookmark] [-m text] [--project P] [--store S]"
KAI_TEAM_USAGE :: "kai profile <name> <device> | kai org list | kai org new <name> | kai org show <org> | kai org add public|org [--org O] | kai org role <org> <member> reader|writer|admin|node | kai org remove <org> <member> | kai invite <org> [--role R] [--mine] [--at host:port] | kai invite <org> --revoke | kai join <invite> | kai pull <org> <repository> <folder> | kai agent [--port N] [--public host:port] | kai web-login <server host:port> <name> | kai serve [options] [--store S]"

// What the verbs of mirai kai take, besides --store and their positionals.
@(private="file")
Kai_Args :: struct {
    folder,message,change,port,org,role,at,public:string,
    limit:int,
    mine,revoke:bool,
    positionals:[dynamic]string,
}

// The options each verb takes.
@(private="file")
KAI_OPTIONS :: [?][2]string{
    {"init","--project"},{"status","--project"},{"snapshot","--project"},{"log","--project -n"},{"diff","--project"},
    {"undo","--project"},{"conflicts","--project"},{"new","--project -m"},{"describe","--project -m"},
    {"split","--project -r -m"},{"restore","--project"},{"bookmarks","--project"},{"publish","--project -m"},
    {"prune",""},{"profile",""},{"org","--project --org"},{"invite","--role --mine --at --revoke"},{"join",""},
    {"pull",""},{"agent","--port --public"},{"web-login",""},
}

@(private="file")
kai_args :: proc(verb:string,args:[]string,a:^Kai_Args) -> int {
    a^={folder=".",limit=20,role="writer"}
    a.positionals=make([dynamic]string,context.temp_allocator)
    allowed:=""
    known:=false
    for o in KAI_OPTIONS {
        if o[0]==verb {allowed,known=o[1],true}
    }
    command:=strings.concatenate({"kai ",verb},context.temp_allocator)
    if !known {
        fmt.eprintfln("Usage: mirai %s\n       mirai %s",KAI_USAGE,KAI_TEAM_USAGE)
        return 2
    }
    for i:=0;i<len(args);i+=1 {
        arg:=args[i]
        if positional(arg) {
            append(&a.positionals,arg)
            continue
        }
        name:=arg
        if cut:=strings.index_byte(arg,'=');cut>0 {name=arg[:cut]}
        takes:=false
        for word in strings.fields(allowed,context.temp_allocator) {takes||=word==name}
        if !takes {return argument_unknown(command,arg)}
        if name=="--mine" || name=="--revoke" {
            if name=="--mine" {a.mine=true} else {a.revoke=true}
            continue
        }
        value,_,ok:=option_value(args,&i,name)
        if !ok || value=="" {
            fmt.eprintfln("mirai %s: %s needs a value",command,name)
            return 2
        }
        switch name {
        case "--project": a.folder=value
        case "-m": a.message=value
        case "-r": a.change=value
        case "-n":
            parsed:bool
            if a.limit,parsed=strconv.parse_int(value);!parsed || a.limit<1 {
                fmt.eprintfln("mirai %s: -n takes a number from 1",command)
                return 2
            }
        case "--port": a.port=value
        case "--org": a.org=value
        case "--role": a.role=value
        case "--at": a.at=value
        case "--public": a.public=value
        }
    }
    return 0
}

// The counts of positionals each verb and sub-verb takes, checked before
// anything is opened: 2 and the usage when they do not fit.
@(private="file")
kai_refuse :: proc(verb:string,a:^Kai_Args) -> int {
    n:=len(a.positionals)
    sub:=n>0?a.positionals[0]:""
    fits:bool
    switch verb {
    case "status","snapshot","log","undo","conflicts","prune","agent": fits=n==0
    case "init","diff","describe","publish": fits=n<=1
    case "restore","join","invite": fits=n==1
    case "profile","web-login": fits=n==2
    case "pull": fits=n==3
    case "bookmarks": fits=n==0 || (sub=="move" && n==3)
    case "org":
        switch sub {
        case "list": fits=n==1
        case "new","show": fits=n==2
        case "add": fits=n==2 && (a.positionals[1]=="public" || a.positionals[1]=="org")
        case "remove": fits=n==3
        case "role":
            _,known:=ka.role_of(n==4?a.positionals[3]:"")
            fits=n==4 && known
        }
    case: fits=true
    }
    if verb=="invite" {
        _,known:=ka.role_of(a.role)
        fits&&=known
    }
    if !fits {
        fmt.eprintfln("Usage: mirai %s\n       mirai %s",KAI_USAGE,KAI_TEAM_USAGE)
        return 2
    }
    return 0
}

@(private="file")
kai_usage :: proc() -> int {
    command_usage("kai",os.stderr)
    return 2
}

// mirai kai: the version control of a project with no editor, through
// cook/kai as the editor does, and the orgs it shares it with. A change is
// named by @ (the working copy), @- (its parent), a bookmark, a shared
// bookmark or a prefix of its id.
cmd_kai :: proc(_:string,args:[]string) -> int {
    if len(args)==0 {return kai_usage()}
    verb:=args[0]
    store_root,rest,store_ok:=store_take(args[1:])
    if !store_ok {fmt.eprintln("mirai kai: --store needs the folder of a store");return 2}
    if verb=="serve" {return kai_node(store_root,rest)}
    a:Kai_Args
    if code:=kai_args(verb,rest,&a);code!=0 {return code}
    if code:=kai_refuse(verb,&a);code!=0 {return code}
    if store_root=="" {store_root=store.default_root(context.temp_allocator)}
    s,store_error:=store.open(store_root)
    if store_error!=.None {fmt.eprintfln("mirai kai: the store at %s does not open (%v): give another with --store",store_root,store_error);return 1}
    defer store.close(&s)
    t:vcs.Team
    if e:=vcs.team_open(&t,&s);e!=.None {return kai_why(verb,&t)}
    defer vcs.team_close(&t)
    switch verb {
    case "prune": return kai_prune(&s)
    case "profile","org","invite","join","pull","agent","web-login": return kai_team(verb,&t,&a)
    }
    root:=project.path_absolute(a.folder,context.temp_allocator)
    if !project_folder(root) && !ka.project_exists(root) {
        fmt.eprintfln("mirai kai: %s has no %s: give the folder of a project with --project",root,project.PROJECT_FILE)
        return 2
    }
    p:=new(ka.Project,context.temp_allocator)
    if verb=="init" {
        if ka.project_exists(root) {fmt.eprintfln("mirai kai init: %s is a workspace already",root);return 1}
        if e:=ka.project_create(p,root,&s);e!=.None {return kai_failed("init",e)}
        defer ka.project_close(p)
        fmt.printfln("%s is a Kai workspace: its files are change %s.",root,ka.change_text(working_change(p).id))
        return 0
    }
    if e:=ka.project_open(p,root,&s);e!=.None {
        if e==.Missing {fmt.eprintfln("mirai kai %s: %s is no Kai workspace: mirai kai init makes it one",verb,root);return 1}
        return kai_failed(verb,e)
    }
    defer ka.project_close(p)
    w:=&p.workspace
    find :: proc(p:^ka.Project,t:^vcs.Team,verb,text:string) -> (revision:vcs.Revision,ok:bool) {
        e:vcs.Error
        if revision,e=ka.revision_resolve(p,t,text);e!=.None {
            fmt.eprintfln("mirai kai %s: %q names no single change: @, @-, a bookmark or a prefix of at least %d digits of a change id",verb,text,ka.CHANGE_TEXT_MIN)
            return
        }
        return revision,true
    }
    positionals:=a.positionals[:]
    switch verb {
    case "status":
        st,e:=vcs.workspace_status(w,context.temp_allocator)
        if e!=.None {return kai_failed(verb,e)}
        c:=working_change(p)
        fmt.printfln("Working copy %s %s",ka.change_text(c.id),description_line(c.description))
        for d in st.changes {fmt.printfln("  %c %s",vcs.diff_mark(d),d.path)}
        if len(st.changes)==0 {fmt.println("  no changes")}
        if st.conflicts>0 {fmt.printfln("%d files in conflict: mirai kai conflicts lists them",st.conflicts)}
    case "snapshot":
        report,e:=ka.snapshot(w)
        if e!=.None {return kai_failed(verb,e)}
        fmt.printfln("%d files, %d read again.",report.files,report.hashed)
    case "new":
        parents:=make([dynamic]vcs.Revision,context.temp_allocator)
        for text in positionals {
            r,ok:=find(p,&t,verb,text)
            if !ok {return 1}
            append(&parents,r)
        }
        revision,e:=ka.new_change(w,parents[:],a.message,nil)
        if e!=.None {return kai_failed(verb,e)}
        c,_:=vcs.change_get(w.repo.s,revision,context.temp_allocator)
        fmt.printfln("Working copy %s, a new change.",ka.change_text(c.id))
    case "split":
        if len(positionals)==0 {fmt.eprintln("mirai kai split: name the files or folders the first change takes");return 2}
        return kai_split(w,a.change,a.message,positionals)
    case "describe":
        if a.message=="" {fmt.eprintln("mirai kai describe: -m gives the description");return 2}
        if _,e:=ka.snapshot(w);e!=.None {return kai_failed(verb,e)}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(p,&t,verb,positionals[0]);!ok {return 1}
        }
        if _,e:=vcs.change_describe(&w.repo,target,a.message);e!=.None {return kai_failed(verb,e)}
    case "log":
        if _,e:=ka.snapshot(w);e!=.None {return kai_failed(verb,e)}
        rows:=make([dynamic]ka.Log_Row,context.temp_allocator)
        if e:=ka.log(w,a.limit,&rows);e!=.None {return kai_failed(verb,e)}
        for row in rows {
            y,mo,d:=time.date(time.unix(0,row.change.written))
            h,mi,_:=time.clock(time.unix(0,row.change.written))
            fmt.printf("%s %s %04d-%02d-%02d %02d:%02d",row.working?"@":"o",ka.change_text(row.change.id),y,int(mo),d,h,mi)
            for b in row.bookmarks {fmt.printf(" [%s]",b)}
            if row.conflicts>0 {fmt.printf(" (%d in conflict)",row.conflicts)}
            if len(row.change.coauthors)>0 {fmt.printf(" +%d authors",len(row.change.coauthors))}
            fmt.printfln(" %s",description_line(row.change.description))
        }
    case "diff":
        if _,e:=ka.snapshot(w);e!=.None {return kai_failed(verb,e)}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(p,&t,verb,positionals[0]);!ok {return 1}
        }
        diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
        if e:=ka.diff(w,target,&diffs);e!=.None {return kai_failed(verb,e)}
        for d in diffs {fmt.printfln("%c %s",vcs.diff_mark(d),d.path)}
    case "undo":
        undone,e:=ka.undo(w,nil)
        if e!=.None {return kai_failed(verb,e)}
        fmt.printfln("Undid: %s.",undone.description)
    case "restore":
        from,ok:=find(p,&t,verb,positionals[0])
        if !ok {return 1}
        if e:=ka.restore(w,from,nil);e!=.None {return kai_failed(verb,e)}
    case "conflicts":
        if _,e:=ka.snapshot(w);e!=.None {return kai_failed(verb,e)}
        for m in w.state.conflicts {fmt.println(m.path)}
        if len(w.state.conflicts)==0 {fmt.println("no conflicts")}
    case "bookmarks":
        if len(positionals)==3 {
            target,ok:=find(p,&t,verb,positionals[2])
            if !ok {return 1}
            if ka.bookmark_move(p,&t,positionals[1],target)!=.None {return kai_why("bookmarks move",&t)}
            c,_:=vcs.change_get(w.repo.s,target,context.temp_allocator)
            fmt.printfln("%s moved to %s for the whole org.",positionals[1],ka.change_text(c.id))
            return 0
        }
        for &b in w.repo.view.bookmarks {
            if value,resolved:=vcs.terms_resolved(&b.terms);resolved {
                c,_:=vcs.change_get(w.repo.s,value,context.temp_allocator)
                fmt.printfln("%s %s",b.name,ka.change_text(c.id))
            } else {
                fmt.printfln("%s (in conflict: %d sides)",b.name,len(b.terms.adds))
            }
        }
        list:=make([dynamic]ka.Shared_Bookmark,context.temp_allocator)
        if ka.bookmarks_shared(p,&t,&list)!=.None {return 0}
        for b in list {
            id:="(not all here yet)"
            if c,e:=vcs.change_get(w.repo.s,b.target,context.temp_allocator);e==.None && b.here {id=ka.change_text(c.id)}
            fmt.printfln("%s %s (shared)",b.name,id)
        }
    case "publish":
        name:=len(positionals)==1?positionals[0]:ka.BOOKMARK_DEFAULT
        revision,e:=ka.publish(p,&t,name,a.message,nil)
        if e!=.None {return kai_why(verb,&t)}
        c,_:=vcs.change_get(w.repo.s,revision,context.temp_allocator)
        fmt.printfln("%s is %s for the whole org; a running agent (the editor, or mirai kai agent) sends it to the org's machines.",name,ka.change_text(c.id))
    }
    return 0
}

// mirai kai profile, org, invite, join, pull, agent and web-login: the orgs
// of this machine and its agent, through the kai package as the editor does.
@(private="file")
kai_team :: proc(verb:string,t:^vcs.Team,a:^Kai_Args) -> int {
    positionals:=a.positionals[:]
    switch verb {
    case "profile":
        if vcs.team_profile_set(t,positionals[0],positionals[1])!=.None {return kai_why(verb,t)}
        fmt.printfln("This machine is %s's %s.",positionals[0],positionals[1])
    case "org":
        return kai_org(t,a)
    case "invite":
        org,ok:=org_find(t,positionals[0])
        if !ok {return 1}
        if a.revoke {
            agent:vcs.Agent
            if vcs.agent_start(&agent,t,{port=-1})!=.None {return kai_why(verb,t)}
            defer vcs.agent_stop(&agent)
            cleared,e:=vcs.agent_invites_revoke(&agent,org)
            if e!=.None {return kai_why(verb,&agent.team)}
            fmt.printfln("%d open invites of the org admit nobody now",cleared)
            return 0
        }
        role,_:=ka.role_of(a.role)
        addresses:=make([dynamic]string,context.temp_allocator)
        if a.at!="" {
            append(&addresses,a.at)
        } else {
            agent:vcs.Agent
            if vcs.agent_start(&agent,t,{port=0})==.None {
                // The addresses the editor's or mirai kai agent's listener takes, on the usual port.
                for x in vcs.agent_addresses(&agent,context.temp_allocator) {
                    host,_,_:=strings.partition(x,":")
                    append(&addresses,fmt.tprintf("%s:%d",host,vcs.KAI_PORT))
                }
                vcs.agent_stop(&agent)
            }
        }
        name:=a.mine?t.name:""
        text:string
        via_server:=false
        e:vcs.Error
        if a.at=="" {
            agent:vcs.Agent
            if vcs.agent_start(&agent,t,{port=-1})==.None {
                defer vcs.agent_stop(&agent)
                text,via_server,e=vcs.agent_invite(&agent,org,role,name,addresses[:],context.temp_allocator)
                if e!=.None {return kai_why(verb,&agent.team)}
            } else {
                text,e=vcs.team_invite(t,org,role,name,addresses[:],context.temp_allocator)
                if e!=.None {return kai_why(verb,t)}
            }
        } else {
            text,e=vcs.team_invite(t,org,role,name,addresses[:],context.temp_allocator)
            if e!=.None {return kai_why(verb,t)}
        }
        fmt.println(text)
        if via_server {
            fmt.eprintfln("One device joins with it, within %d hours, through the org's server even while this machine is off.",vcs.INVITE_HOURS)
        } else {
            fmt.eprintfln("One device joins with it, within %d hours, while this machine's agent runs (the editor, or mirai kai agent), at %s. A machine outside this LAN needs a host:port the router forwards: --at.",vcs.INVITE_HOURS,strings.join(addresses[:],", ",context.temp_allocator))
        }
    case "join":
        agent:vcs.Agent
        if vcs.agent_start(&agent,t,{port=-1})!=.None {return kai_why(verb,t)}
        defer vcs.agent_stop(&agent)
        org,e:=vcs.agent_join(&agent,positionals[0])
        if e!=.None {
            fmt.eprintfln("mirai kai join: %s",agent.team.why)
            return 1
        }
        o,_,_:=vcs.team_org(t,org)
        fmt.printfln("This machine is in org %s: mirai kai pull takes a repository of it.",o.name)
    case "pull":
        return kai_pull(t,positionals[0],positionals[1],positionals[2])
    case "agent":
        port:=0
        if a.port!="" {port,_=strconv.parse_int(a.port)}
        agent:vcs.Agent
        if vcs.agent_start(&agent,t,{port=port,beacon=true,public=a.public,portmap=a.public==""})!=.None {return kai_why(verb,t)}
        defer vcs.agent_stop(&agent)
        fmt.printfln("Kai agent on TCP %d (%s); it runs until this process ends.",vcs.agent_port(&agent),strings.join(vcs.agent_addresses(&agent,context.temp_allocator),", ",context.temp_allocator))
        for {
            time.sleep(time.Second)
            free_all(context.temp_allocator)
            events:=make([dynamic]string,context.temp_allocator)
            vcs.agent_events(&agent,&events,context.temp_allocator)
            for e in events {fmt.println(e)}
        }
    case "web-login":
        password,found:=os.lookup_env("KAI_PASSWORD",context.temp_allocator)
        if !found {
            fmt.print("Password: ")
            r:bufio.Reader
            bufio.reader_init(&r,os.to_stream(os.stdin),allocator=context.temp_allocator)
            line,_:=bufio.reader_read_string(&r,'\n',context.temp_allocator)
            password=strings.trim_right(line,"\r\n")
        }
        agent:vcs.Agent
        if vcs.agent_start(&agent,t,{port=-1})!=.None {return kai_why(verb,t)}
        defer vcs.agent_stop(&agent)
        if vcs.agent_web_login(&agent,positionals[0],positionals[1],password)!=.None {
            fmt.eprintfln("mirai kai web-login: %s",agent.team.why)
            return 1
        }
        fmt.printfln("%s signs in on the server's web view, seeing what this machine's role in each org lets it see.",positionals[1])
    }
    return 0
}

@(private="file")
kai_org :: proc(t:^vcs.Team,a:^Kai_Args) -> int {
    positionals:=a.positionals[:]
    switch positionals[0] {
    case "list":
        for id in vcs.team_org_ids(t) {
            v:ka.Org_View
            if ka.org_view(t,id,&v)!=.None {continue}
            hex:[32]u8
            fmt.printfln("%s %s (%s, %d members, %d repositories)",vcs.org_ref_name(id,&hex)[:8],v.name,v.role,len(v.members),len(v.repos))
        }
    case "new":
        id,e:=vcs.team_org_create(t,positionals[1])
        if e!=.None {return kai_why("org new",t)}
        hex:[32]u8
        fmt.printfln("Org %s (%s): mirai kai org add public|org shares a project with it.",positionals[1],vcs.org_ref_name(id,&hex)[:8])
    case "show":
        id,ok:=org_find(t,positionals[1])
        if !ok {return 1}
        v:ka.Org_View
        if ka.org_view(t,id,&v)!=.None {return kai_why("org show",t)}
        fmt.printfln("%s, version %d; you are %s",v.name,v.version,v.role)
        for m in v.members {
            key:=m.key
            fmt.printfln("  %s %s (%s) %s%s",ka.hex(key[:4]),m.name,m.device,m.role,m.you?", this machine":"")
        }
        for r in v.repos {
            fmt.printfln("  repository %s%s, main %s%s",r.name,r.public?" (public)":"",r.main!=""?r.main:"not published",r.here?"":" (not all here)")
        }
    case "add":
        root:=project.path_absolute(a.folder,context.temp_allocator)
        p:=new(ka.Project,context.temp_allocator)
        if e:=ka.project_open(p,root,t.store);e!=.None {return kai_failed("org add",e)}
        defer ka.project_close(p)
        ids:=vcs.team_org_ids(t)
        org:vcs.Org_Id
        switch {
        case a.org!="":
            ok:bool
            if org,ok=org_find(t,a.org);!ok {return 1}
        case len(ids)==1: org=ids[0]
        case:
            fmt.eprintln("mirai kai org add: name the org with --org")
            return 2
        }
        public:=positionals[1]=="public"
        if _,e:=ka.project_join(p,t,org,public);e!=.None {return kai_why("org add",t)}
        fmt.printfln("%s is a repository of the org (%s); mirai kai publish moves main for it.",ka.project_title(root),public?"public":"org only")
    case "role","remove":
        id,ok:=org_find(t,positionals[1])
        if !ok {return 1}
        o,_,_:=vcs.team_org(t,id)
        found:=-1
        for m,i in o.members {
            key:=m.key
            if strings.has_prefix(ka.hex(key[:]),strings.to_lower(positionals[2],context.temp_allocator)) || m.device==positionals[2] {
                if found>=0 {
                    fmt.eprintfln("mirai kai org: %q names several members: give more of a key",positionals[2])
                    return 1
                }
                found=i
            }
        }
        if found<0 {
            fmt.eprintfln("mirai kai org: %q names no member: mirai kai org show lists them",positionals[2])
            return 1
        }
        e:vcs.Error
        if positionals[0]=="remove" {
            e=vcs.team_member_remove(t,id,o.members[found].key)
        } else {
            m:=o.members[found]
            m.role,_=ka.role_of(positionals[3])
            e=vcs.team_member_set(t,id,m)
        }
        if e!=.None {return kai_why("org",t)}
        fmt.println("Done: a running agent tells the org's machines.")
    }
    return 0
}

// Pulls a repository of an org into folder: the agent runs until main is here.
@(private="file")
kai_pull :: proc(t:^vcs.Team,org_text,repo_text,folder:string) -> int {
    org,ok:=org_find(t,org_text)
    if !ok {return 1}
    o,_,_:=vcs.team_org(t,org)
    repo:vcs.Repo_Id
    found:=false
    for r in o.repos {
        id:=r.id
        if r.name==repo_text || strings.has_prefix(ka.hex(id[:]),repo_text) {repo,found=r.id,true}
    }
    if !found {
        fmt.eprintfln("mirai kai pull: %q names no repository of %s: mirai kai org show lists them",repo_text,o.name)
        return 1
    }
    // The loop below frees the temp allocator: what it prints after is kept apart.
    name_buffer:[vcs.NAME_MAX]u8
    org_name:=string(name_buffer[:copy(name_buffer[:],o.name)])
    root:=project.path_absolute(folder,context.temp_allocator)
    root_buffer:[1024]u8
    root=string(root_buffer[:copy(root_buffer[:],root)])
    // On the heap: the loop below frees the temp allocator, and a workspace does not move.
    p,pe:=new(ka.Project)
    if pe!=nil {return kai_failed("pull",.Out_Of_Memory)}
    defer free(p)
    if ka.project_clone(p,t,root,t.store,org,repo)!=.None {return kai_why("pull",t)}
    defer ka.project_close(p)
    agent:vcs.Agent
    if vcs.agent_start(&agent,t,{port=-1})!=.None {return kai_why("pull",t)}
    defer vcs.agent_stop(&agent)
    started:=time.tick_now()
    for {
        bookmark,e:=ka.clone_checkout(p,t)
        if e==.None {
            fmt.printfln("\n%s holds %s of %s.",root,bookmark!=""?bookmark:"its files",org_name)
            return 0
        }
        if e!=.Missing || time.tick_since(started)>10*time.Minute {return kai_why("pull",t)}
        pulls:=make([dynamic]vcs.Pull,context.temp_allocator)
        vcs.agent_pulls(&agent,&pulls)
        for x in pulls {
            if x.repo==repo {fmt.printf("\r%d chunks, %.1f MB%s",x.chunks,f64(x.bytes)/f64(1<<20),x.whole?", writing the files...":"...")}
        }
        time.sleep(200*time.Millisecond)
        free_all(context.temp_allocator)
    }
}

// The org text names: a prefix of its id or its name.
@(private="file")
org_find :: proc(t:^vcs.Team,text:string) -> (org:vcs.Org_Id,ok:bool) {
    found:=0
    for id in vcs.team_org_ids(t) {
        hex:[32]u8
        o,_,e:=vcs.team_org(t,id)
        if e!=.None {continue}
        if o.name==text || strings.has_prefix(vcs.org_ref_name(id,&hex),strings.to_lower(text,context.temp_allocator)) {
            org=id
            found+=1
        }
    }
    if found!=1 {
        fmt.eprintfln("mirai kai: %q names %s org of this machine: mirai kai org list shows them",text,found==0?"no":"more than one")
        return {},false
    }
    return org,true
}

// Splits change (the working copy when empty) by paths: the first keeps them.
@(private="file")
kai_split :: proc(w:^vcs.Workspace,change,message:string,paths:[]string) -> int {
    description:Maybe(string)
    if message!="" {description=message}
    refused:string
    first,second,e:=ka.split(w,change!="" ? change : "@",paths,description,&refused)
    if e==.Invalid_Argument && refused!="" {fmt.eprintfln("mirai kai split: %s",refused);return 1}
    if e!=.None {return kai_failed("split",e)}
    a,_:=vcs.change_get(w.repo.s,first,context.temp_allocator)
    b,_:=vcs.change_get(w.repo.s,second,context.temp_allocator)
    fmt.printfln("%s %s keeps %d paths; %s holds the rest.",ka.change_text(a.id),description_line(a.description),len(paths),ka.change_text(b.id))
    return 0
}

// Prunes the operation log of every repository of the store and sweeps it.
@(private="file")
kai_prune :: proc(s:^store.Store) -> int {
    result,pe:=ka.prune(s,time.now()._nsec)
    if pe!=.None {return kai_failed("prune",pe)}
    if result.busy {
        fmt.println("Another process writes the store: the sweep runs again later.")
        return 0
    }
    fmt.printfln("Operations older than %d days pruned from every repository of %s; the sweep freed %d bytes. Undo does not go past this prune.",vcs.OP_RETENTION/i64(24*time.Hour),s.root,result.bytes)
    return 0
}

@(private="file")
kai_failed :: proc(verb:string,e:vcs.Error) -> int {
    fmt.eprintfln("mirai kai %s: %s",verb,vcs.error_text(e))
    return 1
}

@(private="file")
kai_why :: proc(verb:string,t:^vcs.Team) -> int {
    fmt.eprintfln("mirai kai %s: %s",verb,t.why!=""?t.why:"it failed")
    return 1
}

@(private="file")
project_folder :: proc(root:string) -> bool {
    return os.is_file(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
}

@(private="file")
working_change :: proc(p:^ka.Project) -> vcs.Change {
    c,_:=vcs.change_get(p.workspace.repo.s,vcs.repo_working(&p.workspace.repo),context.temp_allocator)
    return c
}

@(private="file")
description_line :: proc(text:string) -> string {
    if text=="" {return "(no description)"}
    line:=text
    if cut:=strings.index_byte(line,'\n');cut>=0 {line=line[:cut]}
    return line
}
