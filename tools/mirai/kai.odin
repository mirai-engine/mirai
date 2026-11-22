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

KAI_USAGE :: "kai init|status|snapshot|log [-n N]|diff [change]|undo|conflicts|bookmarks [project] | kai new [change...] [-m text] | kai describe [change] -m text | kai restore <change> | kai bookmarks set <name> <change> | kai bookmarks delete <name> [--project P] [--store S] | kai identity [--name N] | kai agent [--stay] [--port N] | kai org new <name> [--project P] | kai pair offer device|member|node [--org ID] [--role R] [--modes relay,seed,ddc] | kai pair join <ticket> [--name N] | kai pair approve [--code dddd-dddd] [--deny] | kai peers [--store S]"

// mirai kai: the version control of a project with no editor, through
// cook/kai as the editor does. A change is named by @ (the working copy), @-
// (its parent), a bookmark or a prefix of its id.
cmd_kai :: proc(_:string,args:[]string) -> int {
    if len(args)==0 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
    verb:=args[0]
    store_root,rest,store_ok:=store_take(args[1:])
    if !store_ok {fmt.eprintln("mirai kai: --store needs the folder of a store");return 2}
    switch verb {
    case "identity","agent","org","pair","peers": return kai_mesh(verb,store_root,rest)
    }
    folder,message,limit:=".","",20
    positionals:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(rest);i+=1 {
        if value,matched,ok:=option_value(rest,&i,"--project");matched {
            if !ok || value=="" {fmt.eprintln("mirai kai: --project needs a folder");return 2}
            folder=value
        } else if value,matched,ok=option_value(rest,&i,"-m");matched {
            if !ok {fmt.eprintln("mirai kai: -m needs a text");return 2}
            message=value
        } else if value,matched,ok=option_value(rest,&i,"-n");matched {
            n,parsed:=strconv.parse_int(value)
            if !ok || !parsed || n<=0 {fmt.eprintln("mirai kai: -n needs a count");return 2}
            limit=n
        } else if !positional(rest[i]) {
            return argument_unknown("kai",rest[i])
        } else {
            append(&positionals,rest[i])
        }
    }
    root:=project.path_absolute(folder,context.temp_allocator)
    if !project_folder(root) {fmt.eprintfln("mirai kai: %s has no %s: give the folder of a project with --project",root,project.PROJECT_FILE);return 2}
    if store_root=="" {store_root=store.default_root(context.temp_allocator)}
    s,store_error:=store.open(store_root)
    if store_error!=.None {fmt.eprintfln("mirai kai: the store at %s does not open (%v): give another with --store",store_root,store_error);return 1}
    defer store.close(&s)
    p:=new(ka.Project,context.temp_allocator)
    if verb=="init" {
        if len(positionals)>0 {return argument_unknown("kai init",positionals[0])}
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
    find :: proc(w:^vcs.Workspace,verb,text:string) -> (revision:vcs.Revision,ok:bool) {
        e:vcs.Error
        if revision,e=ka.revision_find(w,text);e!=.None {
            fmt.eprintfln("mirai kai %s: %q names no single visible change: @, @-, a bookmark or a prefix of a change id as mirai kai log shows it",verb,text)
            return
        }
        return revision,true
    }
    switch verb {
    case "status":
        if len(positionals)>0 {return argument_unknown("kai status",positionals[0])}
        st,e:=vcs.workspace_status(w,context.temp_allocator)
        if e!=.None {return kai_failed(verb,e)}
        c:=working_change(p)
        fmt.printfln("Working copy %s %s",ka.change_text(c.id),description_line(c.description))
        for d in st.changes {fmt.printfln("  %s %s",diff_mark(d),d.path)}
        if len(st.changes)==0 {fmt.println("  no changes")}
        if st.conflicts>0 {fmt.printfln("%d files in conflict: mirai kai conflicts lists them",st.conflicts)}
    case "snapshot":
        if len(positionals)>0 {return argument_unknown("kai snapshot",positionals[0])}
        report,e:=vcs.workspace_snapshot(w)
        if e!=.None {return kai_failed(verb,e)}
        fmt.printfln("%d files, %d read again.",report.files,report.hashed)
        if !kai_publish(p,store_root) {return 1}
    case "new":
        parents:=make([dynamic]vcs.Revision,context.temp_allocator)
        for text in positionals {
            r,ok:=find(w,verb,text)
            if !ok {return 1}
            append(&parents,r)
        }
        revision,e:=ka.new_change(w,parents[:],message,nil)
        if e!=.None {return kai_failed(verb,e)}
        c,_:=vcs.change_get(w.repo.s,revision,context.temp_allocator)
        fmt.printfln("Working copy %s, a new change.",ka.change_text(c.id))
    case "describe":
        if len(positionals)>1 {return argument_unknown("kai describe",positionals[1])}
        if message=="" {fmt.eprintln("mirai kai describe: -m gives the description");return 2}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(w,verb,positionals[0]);!ok {return 1}
        }
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        if _,e:=vcs.change_describe(&w.repo,target,message);e!=.None {return kai_failed(verb,e)}
    case "log":
        if len(positionals)>0 {return argument_unknown("kai log",positionals[0])}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        rows:=make([dynamic]ka.Log_Row,context.temp_allocator)
        if e:=ka.log(w,limit,&rows);e!=.None {return kai_failed(verb,e)}
        for row in rows {
            marks:=row.working ? "@" : "o"
            y,mo,d:=time.date(time.unix(0,row.change.written))
            h,mi,_:=time.clock(time.unix(0,row.change.written))
            fmt.printf("%s %s %04d-%02d-%02d %02d:%02d",marks,ka.change_text(row.change.id),y,int(mo),d,h,mi)
            for b in row.bookmarks {fmt.printf(" [%s]",b)}
            if row.conflicts>0 {fmt.printf(" (%d in conflict)",row.conflicts)}
            if len(row.change.coauthors)>0 {fmt.printf(" +%d authors",len(row.change.coauthors))}
            if len(row.change.turns)>0 {fmt.printf(" +%d agent turns",len(row.change.turns))}
            fmt.printfln(" %s",description_line(row.change.description))
        }
    case "diff":
        if len(positionals)>1 {return argument_unknown("kai diff",positionals[1])}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(w,verb,positionals[0]);!ok {return 1}
        }
        diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
        if e:=ka.diff(w,target,&diffs);e!=.None {return kai_failed(verb,e)}
        for d in diffs {fmt.printfln("%s %s",diff_mark(d),d.path)}
    case "undo":
        if len(positionals)>0 {return argument_unknown("kai undo",positionals[0])}
        undone,e:=ka.undo(w,nil)
        if e!=.None {return kai_failed(verb,e)}
        fmt.printfln("Undid: %s.",undone.description)
    case "restore":
        if len(positionals)!=1 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
        from,ok:=find(w,verb,positionals[0])
        if !ok {return 1}
        if e:=ka.restore(w,from,nil);e!=.None {return kai_failed(verb,e)}
    case "conflicts":
        if len(positionals)>0 {return argument_unknown("kai conflicts",positionals[0])}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_failed(verb,e)}
        for m in w.state.conflicts {fmt.println(m.path)}
        if len(w.state.conflicts)==0 {fmt.println("no conflicts")}
    case "bookmarks":
        switch {
        case len(positionals)==0:
            for &b in w.repo.view.bookmarks {
                if value,resolved:=vcs.terms_resolved(&b.terms);resolved {
                    c,_:=vcs.change_get(w.repo.s,value,context.temp_allocator)
                    fmt.printfln("%s %s",b.name,ka.change_text(c.id))
                } else {
                    fmt.printfln("%s (in conflict: %d sides)",b.name,len(b.terms.adds))
                }
            }
        case positionals[0]=="set" && len(positionals)==3:
            target,ok:=find(w,verb,positionals[2])
            if !ok {return 1}
            if e:=vcs.bookmark_set(&w.repo,positionals[1],target);e!=.None {return kai_failed(verb,e)}
            if !kai_publish(p,store_root) {return 1}
        case positionals[0]=="delete" && len(positionals)==2:
            if e:=vcs.bookmark_set(&w.repo,positionals[1],{});e!=.None {return kai_failed(verb,e)}
            if !kai_publish(p,store_root) {return 1}
        case:
            fmt.eprintfln("Usage: mirai %s",KAI_USAGE)
            return 2
        }
    case:
        fmt.eprintfln("Usage: mirai %s",KAI_USAGE)
        return 2
    }
    return 0
}

@(private="file")
kai_failed :: proc(verb:string,e:vcs.Error) -> int {
    fmt.eprintfln("mirai kai %s: %s",verb,vcs.error_text(e))
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

// A added, D removed, M changed, C in conflict.
@(private="file")
diff_mark :: proc(d:vcs.Diff) -> string {
    switch {
    case d.after.kind==.Conflict: return "C"
    case d.before.address=={}: return "A"
    case d.after.address=={}: return "D"
    }
    return "M"
}

// The machine of the store, with the running agent told of what it writes.
@(private="file")
Kai_Machine :: struct {
    machine:vcs.Machine,
    control:vcs.Control,
    agent:bool, // an agent runs for the store
}

@(private="file")
kai_machine_open :: proc(k:^Kai_Machine,store_root:string) -> bool {
    if e:=vcs.machine_open(&k.machine,store_root);e!=.None {
        fmt.eprintfln("mirai kai: %s",k.machine.why)
        return false
    }
    if vcs.control_open(&k.control,k.machine.store.root)==.None {
        k.agent=true
        k.machine.changed=vcs.control_machine_changed(&k.control)
    }
    return true
}

@(private="file")
kai_machine_close :: proc(k:^Kai_Machine) {
    if k.agent {vcs.control_close(&k.control)}
    vcs.machine_close(&k.machine)
}

// Publishes a workspace's bookmarks when its repository is a project of an org.
@(private="file")
kai_publish :: proc(p:^ka.Project,store_root:string) -> bool {
    k:Kai_Machine
    if !kai_machine_open(&k,store_root) {return false}
    defer kai_machine_close(&k)
    if e:=ka.bookmarks_publish(p,&k.machine);e!=.None {
        fmt.eprintfln("mirai kai: %s",k.machine.why)
        return false
    }
    return true
}

@(private="file")
short :: proc(bytes:[]u8) -> string {return ka.hex(bytes[:min(len(bytes),6)])}

// The org an option names by a prefix of its id, or the machine's only org.
@(private="file")
kai_org :: proc(m:^vcs.Machine,text:string) -> (org:vcs.Log_Id,ok:bool) {
    found:=0
    for id in m.orgs {
        x:=id
        if text=="" || strings.has_prefix(ka.hex(x[:]),strings.to_lower(text,context.temp_allocator)) {
            org=id
            found+=1
        }
    }
    if found==1 {return org,true}
    if found==0 {
        fmt.eprintln("mirai kai: this machine serves no such org: mirai kai org new makes one, or pair as a member")
    } else {
        fmt.eprintln("mirai kai: this machine serves several orgs: --org gives a prefix of the id of one")
    }
    return
}

// mirai kai identity, agent, org, pair and peers: the machine's identity and
// its mesh, through the kai package as the editor does.
@(private="file")
kai_mesh :: proc(verb,store_root:string,args:[]string) -> int {
    name,port,org_text,role_text,modes_text,code,folder:="","","","writer","","",""
    stay,deny:=false,false
    positionals:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(args);i+=1 {
        matched,ok:bool
        value:string
        if value,matched,ok=option_value(args,&i,"--name");matched {name=value
        } else if value,matched,ok=option_value(args,&i,"--port");matched {port=value
        } else if value,matched,ok=option_value(args,&i,"--org");matched {org_text=value
        } else if value,matched,ok=option_value(args,&i,"--role");matched {role_text=value
        } else if value,matched,ok=option_value(args,&i,"--modes");matched {modes_text=value
        } else if value,matched,ok=option_value(args,&i,"--code");matched {code=value
        } else if value,matched,ok=option_value(args,&i,"--project");matched {folder=value
        } else if args[i]=="--stay" {stay,ok,matched=true,true,true
        } else if args[i]=="--deny" {deny,ok,matched=true,true,true
        } else if positional(args[i]) {
            append(&positionals,args[i])
            continue
        } else {
            return argument_unknown(strings.concatenate({"kai ",verb},context.temp_allocator),args[i])
        }
        if !ok || value=="" && !stay && !deny {fmt.eprintfln("mirai kai %s: %s needs a value",verb,args[i]);return 2}
    }
    k:Kai_Machine
    if !kai_machine_open(&k,store_root) {return 1}
    defer kai_machine_close(&k)
    m:=&k.machine
    switch verb {
    case "identity":
        if len(positionals)>0 {return argument_unknown("kai identity",positionals[0])}
        if m.user=={} {
            if name=="" {name=os.get_env("USER",context.temp_allocator)}
            if name=="" {name="user"}
            buffer:[vcs.RECOVERY_TEXT]u8
            recovery,e:=vcs.machine_user_create(m,name,&buffer)
            if e!=.None {fmt.eprintfln("mirai kai identity: %s",m.why);return 1}
            user:=m.user
            fmt.printfln("User %s (%s) made on this device.",short(user[:]),name)
            fmt.printfln("Recovery key, shown once: write it down and keep it offline.\n  %s",recovery)
            crypto_zero(&buffer)
        } else {
            user:=m.user
            fmt.printfln("User %s",short(user[:]))
        }
        key,dh:=m.identity.key,m.dh.public
        fmt.printfln("Device key %s, X25519 %s",short(key[:]),short(dh[:]))
        for id in m.orgs {
            x:=id
            fmt.printfln("Org %s",short(x[:]))
        }
    case "org":
        if len(positionals)!=2 || positionals[0]!="new" {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
        org,e:=vcs.machine_org_create(m,positionals[1])
        if e!=.None {fmt.eprintfln("mirai kai org: %s",m.why);return 1}
        fmt.printfln("Org %s (%s) made; this device's user owns it.",short(org[:]),positionals[1])
        if folder!="" {
            root:=project.path_absolute(folder,context.temp_allocator)
            p:=new(ka.Project,context.temp_allocator)
            if e=ka.project_open(p,root,&m.store);e!=.None {
                fmt.eprintfln("mirai kai org: %s is no Kai workspace (%s): mirai kai init makes it one",root,vcs.error_text(e))
                return 1
            }
            defer ka.project_close(p)
            title:=strings.trim_right(root,"/\\")
            if cut:=strings.last_index_any(title,"/\\");cut>=0 {title=title[cut+1:]}
            project_id,pe:=vcs.machine_project_add(m,org,p.workspace.repo.id,title,false)
            if pe!=.None {fmt.eprintfln("mirai kai org: %s",m.why);return 1}
            if ka.bookmarks_publish(p,m)!=.None {fmt.eprintfln("mirai kai org: %s",m.why);return 1}
            fmt.printfln("Project %s (%s) is the org's; its bookmarks reach the org's peers.",short(project_id[:]),title)
        }
    case "agent":
        if len(positionals)>0 {return argument_unknown("kai agent",positionals[0])}
        if k.agent {fmt.eprintln("mirai kai agent: an agent runs for this store already");return 1}
        number:=0
        if port!="" {
            n,parsed:=strconv.parse_int(port)
            if !parsed || n<0 || n>65535 {fmt.eprintln("mirai kai agent: --port needs a port");return 2}
            number=n
        }
        r:=new(vcs.Runner)
        print :: proc(_:rawptr,text:string) {fmt.printfln("%s",text)}
        e:=vcs.runner_start(r,{machine=m,port=number,beacon=true,portmap=true,control=true,event={procedure=print}})
        if e!=.None {fmt.eprintfln("mirai kai agent: %s",m.why);return 1}
        defer vcs.runner_stop(r)
        user:=m.user
        fmt.printfln("Kai agent of user %s on UDP port %d, serving %d orgs%s.",short(user[:]),vcs.runner_port(r),len(m.orgs),stay?"":"; it exits when idle")
        stop:=false
        vcs.runner_run(r,&stop,!stay)
    case "pair":
        if !k.agent {fmt.eprintln("mirai kai pair: no Kai agent runs for this store: mirai kai agent starts one");return 1}
        if len(positionals)==0 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
        c:=&k.control
        switch positionals[0] {
        case "offer":
            if len(positionals)!=2 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
            mode:vcs.Pair_Mode
            switch positionals[1] {
            case "device": mode=.Device
            case "member": mode=.Member
            case "node": mode=.Node
            case: fmt.eprintln("mirai kai pair offer: device, member or node");return 2
            }
            org:vcs.Log_Id
            if mode!=.Device {
                ok:bool
                if org,ok=kai_org(m,org_text);!ok {return 1}
            }
            role:vcs.Role
            switch role_text {
            case "reader": role=.Reader
            case "writer": role=.Writer
            case "admin": role=.Admin
            case: fmt.eprintln("mirai kai pair offer: --role is reader, writer or admin");return 2
            }
            modes:vcs.Node_Modes
            for part in strings.split(modes_text,",",context.temp_allocator) {
                switch part {
                case "": 
                case "relay": modes+={.Relay}
                case "seed": modes+={.Seed}
                case "ddc": modes+={.DDC}
                case: fmt.eprintln("mirai kai pair offer: --modes takes relay, seed and ddc");return 2
                }
            }
            if mode==.Node && modes=={} {modes={.Relay,.Seed}}
            buffer:[vcs.TICKET_TEXT]u8
            ticket,e:=vcs.control_pair_offer(c,mode,org,role,modes,&buffer)
            if e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
            fmt.printfln("Ticket, valid ten minutes: on the other machine run\n  mirai kai pair join %s",ticket)
            fmt.println("then mirai kai pair approve here, comparing the codes both show.")
        case "join":
            if len(positionals)!=2 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
            if name=="" {name=os.get_env("USER",context.temp_allocator)}
            if name=="" {name="device"}
            if e:=vcs.control_pair_join(c,positionals[1],name);e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
            shown:=false
            for {
                progress,e:=vcs.control_pair_progress(c)
                if e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
                if progress.code!="" && !shown {
                    fmt.printfln("Code %s: approve on the other machine if it shows the same.",progress.code)
                    shown=true
                }
                #partial switch progress.phase {
                case .Approved: fmt.println("Paired: the agent syncs with the other machine now.");return 0
                case .Denied,.Failed: fmt.eprintfln("mirai kai pair: %s",progress.why);return 1
                }
                free_all(context.temp_allocator)
                time.sleep(200*time.Millisecond)
            }
        case "approve":
            if len(positionals)!=1 {fmt.eprintfln("Usage: mirai %s",KAI_USAGE);return 2}
            request,ok,e:=vcs.control_pair_request(c)
            if e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
            if !ok {fmt.eprintln("mirai kai pair: no pairing request waits: the other machine runs mirai kai pair join with the ticket first");return 1}
            fmt.printfln("%v %q asks to pair, code %s.",request.mode,request.name,request.code)
            approve:=!deny
            if !deny && code=="" {
                fmt.print("Does the other machine show the same code? yes/no: ")
                reader:bufio.Reader
                bufio.reader_init(&reader,os.to_stream(os.stdin),allocator=context.temp_allocator)
                line,_:=bufio.reader_read_string(&reader,'\n',context.temp_allocator)
                answer:=strings.to_lower(strings.trim_space(line),context.temp_allocator)
                approve=answer=="yes" || answer=="y"
            }
            if e=vcs.control_pair_answer(c,approve,code);e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
            fmt.println(approve?"Approved.":"Denied.")
        case:
            fmt.eprintfln("Usage: mirai %s",KAI_USAGE)
            return 2
        }
    case "peers":
        if len(positionals)>0 {return argument_unknown("kai peers",positionals[0])}
        if !k.agent {fmt.eprintln("mirai kai peers: no Kai agent runs for this store: mirai kai agent starts one");return 1}
        list:=make([dynamic]vcs.Runner_Peer_Info,context.temp_allocator)
        if e:=vcs.control_peers(&k.control,&list);e!=.None {fmt.eprintfln("mirai kai peers: %s",k.control.why);return 1}
        for p in list {
            org,dh:=p.org,p.dh
            fmt.printfln("org %s peer %s %v%s by %s",short(org[:]),short(dh[:]),p.class,p.node?" node":"",vcs.rung_text(p.rung))
        }
        if len(list)==0 {fmt.println("no peers connected")}
    }
    return 0
}

@(private="file")
crypto_zero :: proc(buffer:^[vcs.RECOVERY_TEXT]u8) {
    for &b in buffer {b=0}
}
