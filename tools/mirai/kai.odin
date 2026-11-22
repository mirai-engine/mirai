package main

import "core:bufio"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import net "mirai:net"
import "mirai:project"
import "mirai:store"

KAI_USAGE :: "kai init [project]|status|snapshot|log [-n N]|diff [change]|undo|conflicts|verify | kai prune | kai new [change...] [-m text] | kai describe [change] -m text | kai split [-r change] [-m text] <path...> | kai restore <change> | kai bookmarks [set|move <name> <change> | delete <name> | policy <name> [--approvals N] [--checks a,b]] [--project P] [--store S]"
KAI_MESH_USAGE :: "kai identity [--name N] | kai identity revoke <device> | kai identity recovery | kai identity recover <user> [--name N] | kai agent [--stay] [--port N] | kai pair offer device|member|node|recover [--org O] [--role R] [--modes relay,seed,ddc] | kai pair join <ticket> [--name N] | kai pair approve [--code dddd-dddd] [--deny] | kai peers [--store S]"
KAI_TEAM_USAGE :: "kai org list|leave | kai org new <name> | kai org add public|org | kai org remove|transfer <member> | kai org role <member> reader|writer|admin | kai grant issue <subject> --rights read,write,ddc,check,relay [--days N] [--path P] | kai grant list|load <text>|revoke <grant> | kai scope add <pattern...> [--readers R] [--history] | kai scope list|remove|rotate <scope> | kai public add <path>[:line] [--org O] [--project P] [--store S]"
KAI_REVIEW_USAGE :: "kai proposal open <target> [change...] [-m title] [--text T] | kai proposal list|show|approve|changes|withdraw|close|reopen|land <proposal> | kai proposal revise <proposal> [change...] | kai proposal comment <proposal> -m text [--file P | --lines P:A-B | --entity P#id] [--reply C] | kai check <name> [--proposal P] -- <command...> [--project P] [--store S]"

// What the verbs of mirai kai take, besides --store and their positionals.
@(private="file")
Kai_Args :: struct {
    folder,message,change,name,port,org,role,modes,code:string,
    rights,path,readers,checks,text,file,lines,entity,reply,proposal:string,
    limit,days,approvals:int,
    folder_given,stay,deny,history:bool,
    positionals:[dynamic]string,
    command:[]string, // after --
}

// The options each verb takes.
@(private="file")
KAI_OPTIONS :: [?][2]string{
    {"init","--project"},{"status","--project"},{"snapshot","--project"},{"log","--project -n"},{"diff","--project"},
    {"undo","--project"},{"conflicts","--project"},{"verify","--project"},{"new","--project -m"},{"describe","--project -m"},
    {"split","--project -r -m"},{"restore","--project"},{"bookmarks","--project --approvals --checks"},
    {"prune",""},{"identity","--name"},{"agent","--port --stay"},{"pair","--org --role --modes --code --deny --name"},{"peers",""},
    {"org","--project --org"},{"grant","--project --org --rights --days --path"},{"scope","--project --readers --history"},
    {"public","--project"},{"proposal","--project -m --text --file --lines --entity --reply"},{"check","--project --proposal"},
}

@(private="file")
KAI_FLAGS :: [?]string{"--stay","--deny","--history"}

// Reads the options of verb: 2 and the refusal printed when one is unknown,
// lacks its value or holds no valid one.
@(private="file")
kai_args :: proc(verb:string,args:[]string,a:^Kai_Args) -> int {
    a^={folder=".",limit=20,days=7,approvals=-1,role="writer"}
    a.positionals=make([dynamic]string,context.temp_allocator)
    allowed:=""
    known:=false
    for o in KAI_OPTIONS {
        if o[0]==verb {allowed,known=o[1],true}
    }
    command:=strings.concatenate({"kai ",verb},context.temp_allocator)
    if !known {
        fmt.eprintfln("Usage: mirai %s",KAI_USAGE)
        return 2
    }
    for i:=0;i<len(args);i+=1 {
        arg:=args[i]
        if arg=="--" {
            if verb!="check" {return argument_unknown(command,arg)}
            a.command=args[i+1:]
            break
        }
        if positional(arg) {
            append(&a.positionals,arg)
            continue
        }
        name:=arg
        if cut:=strings.index_byte(arg,'=');cut>0 {name=arg[:cut]}
        takes:=false
        for word in strings.fields(allowed,context.temp_allocator) {takes||=word==name}
        if !takes {return argument_unknown(command,arg)}
        flag:=false
        for f in KAI_FLAGS {flag||=f==name}
        if flag {
            switch name {
            case "--stay": a.stay=true
            case "--deny": a.deny=true
            case "--history": a.history=true
            }
            continue
        }
        value,_,ok:=option_value(args,&i,name)
        if !ok || value=="" {
            fmt.eprintfln("mirai %s: %s needs a value",command,name)
            return 2
        }
        number :: proc(command,name,value:string,low,high:int) -> (n:int,ok:bool) {
            parsed:bool
            if n,parsed=strconv.parse_int(value);!parsed || n<low || n>high {
                fmt.eprintfln("mirai %s: %s takes a number from %d to %d",command,name,low,high)
                return 0,false
            }
            return n,true
        }
        switch name {
        case "--project": a.folder,a.folder_given=value,true
        case "-m": a.message=value
        case "-r": a.change=value
        case "-n": if a.limit,ok=number(command,name,value,1,max(int));!ok {return 2}
        case "--name": a.name=value
        case "--port": a.port=value
        case "--org": a.org=value
        case "--role": a.role=value
        case "--modes": a.modes=value
        case "--code": a.code=value
        case "--rights": a.rights=value
        case "--days": if a.days,ok=number(command,name,value,1,30);!ok {return 2}
        case "--path": a.path=value
        case "--readers": a.readers=value
        case "--approvals": if a.approvals,ok=number(command,name,value,0,255);!ok {return 2}
        case "--checks": a.checks=value
        case "--text": a.text=value
        case "--file": a.file=value
        case "--lines": a.lines=value
        case "--entity": a.entity=value
        case "--reply": a.reply=value
        case "--proposal": a.proposal=value
        }
    }
    return 0
}

@(private="file")
kai_usage :: proc() -> int {
    command_usage("kai",os.stderr)
    return 2
}

// mirai kai: the version control of a project with no editor, through
// cook/kai as the editor does, and the team it shares it with through the
// machine's mesh. A change is named by @ (the working copy), @- (its parent),
// a bookmark, a shared bookmark, <handle>/<device>:<bookmark> or a prefix of
// its id.
cmd_kai :: proc(_:string,args:[]string) -> int {
    if len(args)==0 {return kai_usage()}
    verb:=args[0]
    store_root,rest,store_ok:=store_take(args[1:])
    if !store_ok {fmt.eprintln("mirai kai: --store needs the folder of a store");return 2}
    if verb=="serve" || verb=="web" {return kai_node(verb,store_root,rest)}
    a:Kai_Args
    if code:=kai_args(verb,rest,&a);code!=0 {return code}
    if code:=kai_refuse(verb,&a);code!=0 {return code}
    switch verb {
    case "identity","agent","pair","peers": return kai_mesh(verb,store_root,&a)
    case "org","grant": return kai_team(verb,store_root,&a)
    case "prune": return kai_prune(store_root)
    }
    root:=project.path_absolute(a.folder,context.temp_allocator)
    if !project_folder(root) {fmt.eprintfln("mirai kai: %s has no %s: give the folder of a project with --project",root,project.PROJECT_FILE);return 2}
    if store_root=="" {store_root=store.default_root(context.temp_allocator)}
    s,store_error:=store.open(store_root)
    if store_error!=.None {fmt.eprintfln("mirai kai: the store at %s does not open (%v): give another with --store",store_root,store_error);return 1}
    defer store.close(&s)
    p:=new(ka.Project,context.temp_allocator)
    if verb=="init" {
        if ka.project_exists(root) {fmt.eprintfln("mirai kai init: %s is a workspace already",root);return 1}
        k:Kai_Machine
        project_id:vcs.Log_Id
        if len(a.positionals)==1 {
            if !kai_machine_open(&k,store_root) {return 1}
            e:vcs.Error
            if project_id,_,e=vcs.machine_project_find(&k.machine,a.positionals[0]);e!=.None {return kai_why("init",&k)}
        }
        defer if len(a.positionals)==1 {kai_machine_close(&k)}
        if e:=ka.project_create(p,root,&s);e!=.None {return kai_failed("init",e)}
        defer ka.project_close(p)
        fmt.printfln("%s is a Kai workspace: its files are change %s.",root,ka.change_text(working_change(p).id))
        if project_id!={} {
            if ka.project_link(p,&k.machine,project_id)!=.None {return kai_why("init",&k)}
            fmt.printfln("It works on project %s: mirai kai bookmarks shows where its changes are.",a.positionals[0])
        }
        return 0
    }
    if e:=ka.project_open(p,root,&s);e!=.None {
        if e==.Missing {fmt.eprintfln("mirai kai %s: %s is no Kai workspace: mirai kai init makes it one",verb,root);return 1}
        return kai_failed(verb,e)
    }
    defer ka.project_close(p)
    switch verb {
    case "scope","public","proposal","check","verify": return kai_review(verb,p,store_root,&a)
    }
    w:=&p.workspace
    k:Kai_Machine
    machined:=false
    defer if machined {kai_machine_close(&k)}
    // A change named by what the workspace knows, or by what the project's
    // logs and the devices' refs say.
    find :: proc(p:^ka.Project,k:^Kai_Machine,machined:^bool,store_root,verb,text:string) -> (revision:vcs.Revision,ok:bool) {
        e:vcs.Error
        if revision,e=ka.revision_find(&p.workspace,text);e==.None {return revision,true}
        if !machined^ {
            if !kai_machine_open(k,store_root) {return}
            machined^=true
        }
        if revision,e=ka.revision_resolve(p,&k.machine,text);e!=.None {
            fmt.eprintfln("mirai kai %s: %q: %s",verb,text,k.machine.why)
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
        for d in st.changes {fmt.printfln("  %s %s",diff_mark(d),d.path)}
        if len(st.changes)==0 {fmt.println("  no changes")}
        if st.conflicts>0 {fmt.printfln("%d files in conflict: mirai kai conflicts lists them",st.conflicts)}
    case "snapshot":
        report,e:=vcs.workspace_snapshot(w)
        if e!=.None {return kai_refused(verb,p,e)}
        fmt.printfln("%d files, %d read again.",report.files,report.hashed)
        if !kai_publish(p,store_root) {return 1}
    case "new":
        parents:=make([dynamic]vcs.Revision,context.temp_allocator)
        for text in positionals {
            r,ok:=find(p,&k,&machined,store_root,verb,text)
            if !ok {return 1}
            append(&parents,r)
        }
        revision,e:=ka.new_change(w,parents[:],a.message,nil)
        if e!=.None {return kai_refused(verb,p,e)}
        c,_:=vcs.change_get(w.repo.s,revision,context.temp_allocator)
        fmt.printfln("Working copy %s, a new change.",ka.change_text(c.id))
    case "split":
        if len(positionals)==0 {fmt.eprintln("mirai kai split: name the files or folders the first change takes");return 2}
        if code:=kai_split(w,a.change,a.message,positionals);code!=0 {return code}
    case "describe":
        if a.message=="" {fmt.eprintln("mirai kai describe: -m gives the description");return 2}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_refused(verb,p,e)}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(p,&k,&machined,store_root,verb,positionals[0]);!ok {return 1}
        }
        if _,e:=vcs.change_describe(&w.repo,target,a.message);e!=.None {return kai_failed(verb,e)}
    case "log":
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_refused(verb,p,e)}
        rows:=make([dynamic]ka.Log_Row,context.temp_allocator)
        if e:=ka.log(w,a.limit,&rows);e!=.None {return kai_failed(verb,e)}
        for row in rows {
            marks:=row.working ? "@" : "o"
            y,mo,d:=time.date(time.unix(0,row.change.written))
            h,mi,_:=time.clock(time.unix(0,row.change.written))
            fmt.printf("%s %s %04d-%02d-%02d %02d:%02d",marks,ka.change_text(row.change.id),y,int(mo),d,h,mi)
            for b in row.bookmarks {fmt.printf(" [%s]",b)}
            if row.conflicts>0 {fmt.printf(" (%d in conflict)",row.conflicts)}
            if len(row.change.coauthors)>0 {fmt.printf(" +%d authors",len(row.change.coauthors))}
            for a,k in row.change.attachments {
                if k>0 && row.change.attachments[k-1].type==a.type {continue}
                n:=0
                for b in row.change.attachments[k:] {n+=int(b.type==a.type)}
                fmt.printf(" +%d %s",n,vcs.attachment_type_text(a.type))
            }
            fmt.printfln(" %s",description_line(row.change.description))
        }
    case "diff":
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_refused(verb,p,e)}
        target:=vcs.repo_working(&w.repo)
        if len(positionals)==1 {
            ok:bool
            if target,ok=find(p,&k,&machined,store_root,verb,positionals[0]);!ok {return 1}
        }
        diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
        if e:=ka.diff(w,target,&diffs);e!=.None {return kai_failed(verb,e)}
        for d in diffs {fmt.printfln("%s %s",diff_mark(d),d.path)}
    case "undo":
        undone,e:=ka.undo(w,nil)
        if e!=.None {return kai_refused(verb,p,e)}
        fmt.printfln("Undid: %s.",undone.description)
    case "restore":
        from,ok:=find(p,&k,&machined,store_root,verb,positionals[0])
        if !ok {return 1}
        if e:=ka.restore(w,from,nil);e!=.None {return kai_refused(verb,p,e)}
    case "conflicts":
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_refused(verb,p,e)}
        for m in w.state.conflicts {fmt.println(m.path)}
        if len(w.state.conflicts)==0 {fmt.println("no conflicts")}
    case "bookmarks":
        return kai_bookmarks(p,&k,&machined,store_root,&a)
    }
    return 0
}

// The counts of positionals each verb and sub-verb takes, checked before
// anything is opened: 2 and the usage when they do not fit.
@(private="file")
kai_refuse :: proc(verb:string,a:^Kai_Args) -> int {
    n:=len(a.positionals)
    sub:=n>0?a.positionals[0]:""
    fits:=true
    switch verb {
    case "status","snapshot","log","undo","conflicts","verify","agent","peers","prune": fits=n==0
    case "init","diff","describe": fits=n<=1
    case "restore": fits=n==1
    case "identity": fits=n==0 || (sub=="revoke" && n==2) || (sub=="recovery" && n==1) || (sub=="recover" && n==2)
    case "bookmarks":
        switch sub {
        case "": fits=n==0
        case "set","move": fits=n==3
        case "delete": fits=n==2
        case "policy":
            fits=n==2
            if fits && a.approvals<0 && a.checks=="" {fmt.eprintln("mirai kai bookmarks policy: --approvals and --checks say what the policy asks");return 2}
        case: fits=false
        }
    case "pair":
        switch sub {
        case "offer","join": fits=n==2
        case "approve": fits=n==1
        case: fits=false
        }
    case "org":
        switch sub {
        case "list","leave": fits=n==1
        case "new","remove","transfer": fits=n==2
        case "add": fits=n==2 && (a.positionals[1]=="public" || a.positionals[1]=="org")
        case "role": fits=n==3 && ka.role_of(a.positionals[2])!=.None
        case: fits=false
        }
    case "grant":
        switch sub {
        case "list": fits=n==1
        case "load","revoke": fits=n==2
        case "issue":
            fits=n==2
            if fits && a.rights=="" {fmt.eprintln("mirai kai grant issue: --rights names what the grant gives: read, write, ddc, check or relay");return 2}
            if _,ok:=kai_rights(a.rights);fits && !ok {fmt.eprintln("mirai kai grant issue: --rights takes read, write, ddc, check and relay, apart by commas");return 2}
            if _,_,ok:=kai_subject(a.positionals[1]);fits && !ok {fmt.eprintln("mirai kai grant issue: the subject is the 128 hex digits mirai kai identity prints on the holder's machine");return 2}
        case: fits=false
        }
    case "scope":
        switch sub {
        case "list": fits=n==1
        case "remove","rotate": fits=n==2
        case "add":
            fits=n>=2
            if fits && a.readers!="" && ka.role_of(a.readers)==.None && a.readers!="owner" {fmt.eprintln("mirai kai scope add: --readers is reader, writer, admin or owner");return 2}
        case: fits=false
        }
    case "public": fits=n==2 && sub=="add"
    case "proposal":
        switch sub {
        case "list": fits=n==1
        case "open","revise": fits=n>=2
        case "show","approve","changes","withdraw","close","reopen","land": fits=n==2
        case "comment":
            fits=n==2
            anchors:=int(a.file!="")+int(a.lines!="")+int(a.entity!="")
            if fits && (a.message=="" || anchors>1) {fmt.eprintln("mirai kai proposal comment: -m gives the text, and at most one of --file, --lines and --entity where it hangs");return 2}
            if _,_,ok:=kai_anchor(a);fits && !ok {fmt.eprintln("mirai kai proposal comment: --lines is path:first-last and --entity is path#id");return 2}
        case: fits=false
        }
    case "check":
        fits=n==1
        if fits && len(a.command)==0 {fmt.eprintln("mirai kai check: the command to run goes after --, as mirai kai check unit -- mirai test kai");return 2}
    }
    if !fits {return kai_usage()}
    return 0
}

@(private="file")
rights_text :: proc(rights:vcs.Rights) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for r in vcs.Right {
        if r in rights {append(&names,strings.to_lower(fmt.tprint(r),context.temp_allocator))}
    }
    return strings.join(names[:],",",context.temp_allocator)
}

@(private="file")
day_text :: proc(ns:i64) -> string {
    y,mo,d:=time.date(time.unix(0,ns))
    return fmt.tprintf("%04d-%02d-%02d",y,int(mo),d)
}

@(private="file")
kai_rights :: proc(text:string) -> (rights:vcs.Rights,ok:bool) {
    for part in strings.split(text,",",context.temp_allocator) {
        switch part {
        case "read": rights+={.Read}
        case "write": rights+={.Write}
        case "ddc": rights+={.DDC}
        case "check": rights+={.Check}
        case "relay": rights+={.Relay}
        case: return {},false
        }
    }
    return rights,rights!={}
}

// The keys a grant's subject gives: its device key and its X25519 key, as
// mirai kai identity prints them.
@(private="file")
kai_subject :: proc(text:string) -> (key:vcs.Key,dh:vcs.Dh_Key,ok:bool) {
    if len(text)!=128 {return}
    for k in 0..<64 {
        v,parsed:=strconv.parse_u64_of_base(text[2*k:2*k+2],16)
        if !parsed {return {},{},false}
        if k<32 {key[k]=u8(v)} else {dh[k-32]=u8(v)}
    }
    return key,dh,true
}

// Where a comment hangs: --file P, --lines P:A-B and --entity P#id.
@(private="file")
kai_anchor :: proc(a:^Kai_Args) -> (path:string,anchor:vcs.Anchor,ok:bool) {
    switch {
    case a.file!="": return a.file,{kind=.File},true
    case a.lines!="":
        cut:=strings.last_index_byte(a.lines,':')
        if cut<=0 {return}
        lines,parsed:=ka.lines_of(a.lines[cut+1:])
        if !parsed {return}
        return a.lines[:cut],lines,true
    case a.entity!="":
        cut:=strings.last_index_byte(a.entity,'#')
        if cut<=0 {return}
        id,parsed:=strconv.parse_u64(a.entity[cut+1:])
        if !parsed {return}
        return a.entity[:cut],{kind=.Structural,key=id},true
    }
    return "",{},true
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
kai_prune :: proc(store_root:string) -> int {
    root:=store_root!="" ? store_root : store.default_root(context.temp_allocator)
    s,e:=store.open(root)
    if e!=.None {fmt.eprintfln("mirai kai prune: the store at %s does not open (%v): give another with --store",root,e);return 1}
    defer store.close(&s)
    result,pe:=ka.prune(&s,time.now()._nsec)
    if pe!=.None {return kai_failed("prune",pe)}
    fmt.printfln("Operations older than %d days pruned from every repository of %s; the sweep freed %d bytes. Undo does not go past this prune.",vcs.OP_RETENTION/i64(24*time.Hour),root,result.bytes)
    return 0
}

@(private="file")
kai_failed :: proc(verb:string,e:vcs.Error) -> int {
    fmt.eprintfln("mirai kai %s: %s",verb,vcs.error_text(e))
    return 1
}

// A snapshot refused for a private or denied path says which and how to fix it.
@(private="file")
kai_refused :: proc(verb:string,p:^ka.Project,e:vcs.Error) -> int {
    if e==.Unauthorized && p.routing.refused!="" {
        fmt.eprintfln("mirai kai %s: %s",verb,p.routing.refused)
        return 1
    }
    return kai_failed(verb,e)
}

@(private="file")
kai_why :: proc(verb:string,k:^Kai_Machine) -> int {
    fmt.eprintfln("mirai kai %s: %s",verb,k.machine.why)
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

// The bookmarks: the workspace's own, the project's shared ones and every
// device's; setting, moving and guarding them.
@(private="file")
kai_bookmarks :: proc(p:^ka.Project,k:^Kai_Machine,machined:^bool,store_root:string,a:^Kai_Args) -> int {
    w:=&p.workspace
    positionals:=a.positionals[:]
    machine :: proc(k:^Kai_Machine,machined:^bool,store_root:string) -> bool {
        if machined^ {return true}
        machined^=kai_machine_open(k,store_root)
        return machined^
    }
    resolve :: proc(p:^ka.Project,k:^Kai_Machine,text:string) -> (revision:vcs.Revision,ok:bool) {
        e:vcs.Error
        if revision,e=ka.revision_resolve(p,&k.machine,text);e!=.None {
            fmt.eprintfln("mirai kai bookmarks: %q: %s",text,k.machine.why)
            return
        }
        return revision,true
    }
    sub:=len(positionals)>0?positionals[0]:""
    switch sub {
    case "":
        for &b in w.repo.view.bookmarks {
            if value,resolved:=vcs.terms_resolved(&b.terms);resolved {
                c,_:=vcs.change_get(w.repo.s,value,context.temp_allocator)
                fmt.printfln("%s %s",b.name,ka.change_text(c.id))
            } else {
                fmt.printfln("%s (in conflict: %d sides)",b.name,len(b.terms.adds))
            }
        }
        if _,_,linked:=vcs.store_project_of(w.repo.s,w.repo.id);!linked {return 0}
        if !machine(k,machined,store_root) {return 1}
        list:=make([dynamic]ka.Shared_Bookmark,context.temp_allocator)
        if ka.bookmarks_shared(p,&k.machine,&list)!=.None {return kai_why("bookmarks",k)}
        for b in list {
            id:="(not here yet)"
            if c,e:=vcs.change_get(&k.machine.store,b.target,context.temp_allocator);e==.None {id=ka.change_text(c.id)}
            fmt.printfln("%s %s%s",b.name,id,b.device=={}?" (shared)":"")
        }
    case "set":
        if !machine(k,machined,store_root) {return 1}
        target,ok:=resolve(p,k,positionals[2])
        if !ok {return 1}
        if e:=vcs.bookmark_set(&w.repo,positionals[1],target);e!=.None {return kai_failed("bookmarks",e)}
        if ka.bookmarks_publish(p,&k.machine)!=.None {return kai_why("bookmarks",k)}
    case "delete":
        if e:=vcs.bookmark_set(&w.repo,positionals[1],{});e!=.None {return kai_failed("bookmarks",e)}
        if !machine(k,machined,store_root) {return 1}
        if ka.bookmarks_publish(p,&k.machine)!=.None {return kai_why("bookmarks",k)}
    case "move":
        if !machine(k,machined,store_root) {return 1}
        if _,e:=vcs.workspace_snapshot(w);e!=.None {return kai_refused("bookmarks",p,e)}
        target,ok:=resolve(p,k,positionals[2])
        if !ok {return 1}
        if ka.bookmark_move(p,&k.machine,positionals[1],target)!=.None {return kai_why("bookmarks move",k)}
        c,_:=vcs.change_get(w.repo.s,target,context.temp_allocator)
        fmt.printfln("%s moved to %s for the whole org.",positionals[1],ka.change_text(c.id))
    case "policy":
        if !machine(k,machined,store_root) {return 1}
        checks:=make([dynamic]string,context.temp_allocator)
        if a.checks!="" {
            for c in strings.split(a.checks,",",context.temp_allocator) {
                if c!="" {append(&checks,c)}
            }
        }
        if ka.policy_set(p,&k.machine,positionals[1],max(a.approvals,0),checks[:])!=.None {return kai_why("bookmarks policy",k)}
        fmt.printfln("%s now moves only by a proposal with %d approvals and the checks %v.",positionals[1],max(a.approvals,0),checks[:])
    }
    return 0
}

// mirai kai identity, agent, pair and peers: the machine's identity and its
// mesh, through the kai package as the editor does.
@(private="file")
kai_mesh :: proc(verb,store_root:string,a:^Kai_Args) -> int {
    k:Kai_Machine
    if !kai_machine_open(&k,store_root) {return 1}
    defer kai_machine_close(&k)
    m:=&k.machine
    positionals:=a.positionals[:]
    switch verb {
    case "identity":
        if len(positionals)>0 {return kai_identity_change(&k,positionals,a.name)}
        if m.user=={} {
            name:=a.name
            if name=="" {name=os.get_env("USER",context.temp_allocator)}
            if name=="" {name="user"}
            buffer:[vcs.RECOVERY_TEXT]u8
            recovery,e:=vcs.machine_user_create(m,name,&buffer)
            if e!=.None {return kai_why("identity",&k)}
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
        fmt.printfln("Subject for grants: %s%s",ka.hex(key[:]),ka.hex(dh[:]))
        for id in m.orgs {
            x:=id
            fmt.printfln("Org %s",short(x[:]))
        }
    case "agent":
        if k.agent {fmt.eprintln("mirai kai agent: an agent runs for this store already");return 1}
        number:=0
        if a.port!="" {
            n,parsed:=strconv.parse_int(a.port)
            if !parsed || n<0 || n>65535 {fmt.eprintln("mirai kai agent: --port needs a port");return 2}
            number=n
        }
        r:=new(vcs.Runner)
        print :: proc(_:rawptr,text:string) {fmt.printfln("%s",text)}
        e:=vcs.runner_start(r,{machine=m,port=number,beacon=true,portmap=true,control=true,event={procedure=print}})
        if e!=.None {return kai_why("agent",&k)}
        defer vcs.runner_stop(r)
        user:=m.user
        fmt.printfln("Kai agent of user %s on UDP port %d, serving %d orgs%s.",short(user[:]),vcs.runner_port(r),len(m.orgs),a.stay?"":"; it exits when idle")
        stop:=false
        vcs.runner_run(r,&stop,!a.stay)
    case "pair":
        if !k.agent {fmt.eprintln("mirai kai pair: no Kai agent runs for this store: mirai kai agent starts one");return 1}
        return kai_pair(&k,a)
    case "peers":
        if !k.agent {fmt.eprintln("mirai kai peers: no Kai agent runs for this store: mirai kai agent starts one");return 1}
        list:=make([dynamic]vcs.Runner_Peer_Info,context.temp_allocator)
        orgs:=make([dynamic]vcs.Runner_Org_Info,context.temp_allocator)
        if e:=vcs.control_peers(&k.control,&list,&orgs);e!=.None {fmt.eprintfln("mirai kai peers: %s",k.control.why);return 1}
        for p in list {
            org,dh:=p.org,p.dh
            fmt.printfln("org %s peer %s %v%s by %s",short(org[:]),short(dh[:]),p.class,p.node?" node":"",vcs.rung_text(p.rung))
        }
        if len(list)==0 {fmt.println("no peers connected")}
        for x in orgs {
            org:=x.org
            if x.behind>0 {fmt.printfln("org %s is behind: %d entries of its logs peers named are not here yet, and their writes wait; reach another member or node to get them",short(org[:]),x.behind)}
            if x.unfound>0 {fmt.printfln("org %s let go of %d entries peers named that never came",short(org[:]),x.unfound)}
        }
    }
    return 0
}

// mirai kai identity revoke and recovery.
@(private="file")
kai_identity_change :: proc(k:^Kai_Machine,positionals:[]string,name:string) -> int {
    m:=&k.machine
    switch positionals[0] {
    case "revoke":
        device,e:=vcs.machine_device_find(m,positionals[1])
        if e!=.None || vcs.machine_device_revoke(m,device)!=.None {return kai_why("identity revoke",k)}
        fmt.printfln("Device %s is revoked: what it signs from now on counts nowhere.",positionals[1])
    case "recovery":
        // A user born of a passkey has none yet: this device sets the first.
        line:string
        if vcs.machine_user_recovered(m) {
            fmt.print("The recovery key now, as it was printed: ")
            reader:bufio.Reader
            bufio.reader_init(&reader,os.to_stream(os.stdin),allocator=context.temp_allocator)
            line,_=bufio.reader_read_string(&reader,'\n',context.temp_allocator)
        }
        buffer:[vcs.RECOVERY_TEXT]u8
        defer crypto_zero(&buffer)
        recovery,e:=vcs.machine_recovery_rotate(m,strings.trim_space(line),&buffer)
        if e!=.None {return kai_why("identity recovery",k)}
        fmt.printfln("The old recovery key counts no more. The new one, shown once: write it down and keep it offline.\n  %s",recovery)
    case "recover":
        // The user's log comes from a peer of a recovery pairing: wait for it a while.
        user:vcs.Log_Id
        for tries:=0;;tries+=1 {
            e:vcs.Error
            if user,e=vcs.machine_user_find(m,positionals[1]);e==.None {break}
            if e!=.Missing || !k.agent || tries>=RECOVER_WAIT*5 {return kai_why("identity recover",k)}
            if tries==0 {fmt.println("Waiting for the agent to fetch the user's log...")}
            time.sleep(200*time.Millisecond)
        }
        if m.user!={} && m.user!=user {fmt.eprintln("mirai kai identity recover: this device belongs to another user already: recover onto a new store");return 1}
        again:=m.user==user
        fmt.print("The user's recovery key, as it was printed: ")
        reader:bufio.Reader
        bufio.reader_init(&reader,os.to_stream(os.stdin),allocator=context.temp_allocator)
        line,_:=bufio.reader_read_string(&reader,'\n',context.temp_allocator)
        defer crypto_zero_text(line)
        report:vcs.Recover_Report
        if vcs.machine_recover(m,user,line,name,&report)!=.None {return kai_why("identity recover",k)}
        id:=user
        if !again {fmt.printfln("User %s recovered onto this device: its other devices are revoked, its passkeys stay. Rotate the recovery key with mirai kai identity recovery if it may have been seen.",short(id[:]))}
        // The org's logs come once the peers admit this device: wait for them a while.
        for tries:=0;report.waiting>0 && k.agent && tries<RECOVER_WAIT*5;tries+=1 {
            if tries==0 {fmt.println("Waiting for the agent to fetch the orgs' logs and the scopes' keys...")}
            time.sleep(200*time.Millisecond)
            if vcs.machine_recover(m,user,line,name,&report)!=.None {return kai_why("identity recover",k)}
        }
        if report.opened>0 {fmt.printfln("Private scopes this device reads again through the recovery key: %d. Each starts a new epoch, since the lost devices hold the last key.",report.opened)}
        for x in report.lost {
            fmt.printfln("Scope %s: no key left opens its files up to epoch %d, which were wrapped only for keys that are lost; they stay unreadable. Epoch %d starts now for this device.",x.text,x.epoch,x.epoch+1)
        }
        if report.waiting>0 {fmt.printfln("%d of the user's orgs or scopes are not in this store yet: once mirai kai org list shows them, run mirai kai identity recover %s again.",report.waiting,positionals[1])}
    }
    return 0
}

RECOVER_WAIT :: 60 // seconds identity recover waits for the user's log to arrive

// mirai kai pair offer, join and approve.
@(private="file")
kai_pair :: proc(k:^Kai_Machine,a:^Kai_Args) -> int {
    m,c:=&k.machine,&k.control
    positionals:=a.positionals[:]
    switch positionals[0] {
    case "offer":
        mode:vcs.Pair_Mode
        switch positionals[1] {
        case "device": mode=.Device
        case "member": mode=.Member
        case "node": mode=.Node
        case "recover": mode=.Recover
        case: fmt.eprintln("mirai kai pair offer: device, member, node or recover");return 2
        }
        org:vcs.Log_Id
        if mode!=.Device {
            e:vcs.Error
            if org,e=vcs.machine_org_find(m,a.org);e!=.None {return kai_why("pair",k)}
        }
        role:=ka.role_of(a.role)
        if role==.None {fmt.eprintln("mirai kai pair offer: --role is reader, writer or admin");return 2}
        modes,modes_ok:=ka.node_modes_of(a.modes)
        if !modes_ok {fmt.eprintln("mirai kai pair offer: --modes takes relay, seed and ddc");return 2}
        if mode==.Node && modes=={} {modes={.Relay,.Seed}}
        buffer:[vcs.TICKET_TEXT]u8
        ticket,e:=vcs.control_pair_offer(c,mode,org,role,modes,&buffer)
        if e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
        fmt.printfln("Ticket, valid ten minutes: on the other machine run\n  mirai kai pair join %s",ticket)
        fmt.println("then mirai kai pair approve here, comparing the codes both show.")
    case "join":
        name,ne:=vcs.machine_pair_name(m,a.name)
        if ne!=.None {return kai_why("pair",k)}
        if e:=vcs.control_pair_join(c,positionals[1],name);e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
        ticket,_:=vcs.ticket_decode(strings.trim_space(positionals[1]))
        shown:=false
        for {
            progress,e:=vcs.control_pair_progress(c)
            if e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
            if progress.code!="" && !shown {
                fmt.printfln("Code %s: approve on the other machine if it shows the same.",progress.code)
                shown=true
            }
            #partial switch progress.phase {
            case .Approved:
                if ticket.mode==.Recover {
                    fmt.println("Paired: the agent fetches the org's user logs now; mirai kai identity recover <user> recovers yours.")
                } else {
                    fmt.println("Paired: the agent syncs with the other machine now.")
                }
                return 0
            case .Denied,.Failed: fmt.eprintfln("mirai kai pair: %s",progress.why);return 1
            }
            free_all(context.temp_allocator)
            time.sleep(200*time.Millisecond)
        }
    case "approve":
        request,ok,e:=vcs.control_pair_request(c)
        if e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
        if !ok {fmt.eprintln("mirai kai pair: no pairing request waits: the other machine runs mirai kai pair join with the ticket first");return 1}
        fmt.printfln("%v %s asks to pair, code %s.",request.mode,vcs.pair_request_who(m,request),request.code)
        approve:=!a.deny
        if !a.deny && a.code=="" {
            fmt.print("Does the other machine show the same code? yes/no: ")
            reader:bufio.Reader
            bufio.reader_init(&reader,os.to_stream(os.stdin),allocator=context.temp_allocator)
            line,_:=bufio.reader_read_string(&reader,'\n',context.temp_allocator)
            answer:=strings.to_lower(strings.trim_space(line),context.temp_allocator)
            approve=answer=="yes" || answer=="y"
        }
        if e=vcs.control_pair_answer(c,approve,a.code);e!=.None {fmt.eprintfln("mirai kai pair: %s",c.why);return 1}
        fmt.println(approve?"Approved.":"Denied.")
    }
    return 0
}

// The project of the folder an option gives, opened over the machine's store.
@(private="file")
kai_project :: proc(k:^Kai_Machine,folder,verb:string) -> (p:^ka.Project,ok:bool) {
    root:=project.path_absolute(folder,context.temp_allocator)
    p=new(ka.Project,context.temp_allocator)
    if e:=ka.project_open(p,root,&k.machine.store);e!=.None {
        fmt.eprintfln("mirai kai %s: %s is no Kai workspace (%s): mirai kai init makes it one",verb,root,vcs.error_text(e))
        return nil,false
    }
    return p,true
}

// mirai kai org and grant: the orgs this machine serves and the grants of
// their admins.
@(private="file")
kai_team :: proc(verb,store_root:string,a:^Kai_Args) -> int {
    k:Kai_Machine
    if !kai_machine_open(&k,store_root) {return 1}
    defer kai_machine_close(&k)
    m:=&k.machine
    positionals:=a.positionals[:]
    sub:=positionals[0]
    command:=strings.concatenate({verb," ",sub},context.temp_allocator)
    if verb=="org" && sub=="new" {
        org,e:=vcs.machine_org_create(m,positionals[1])
        if e!=.None {return kai_why(command,&k)}
        fmt.printfln("Org %s (%s) made; this device's user owns it.",short(org[:]),positionals[1])
        if !a.folder_given {return 0}
        p,ok:=kai_project(&k,a.folder,command)
        if !ok {return 1}
        defer ka.project_close(p)
        project_id,pe:=ka.project_join(p,m,org,false)
        if pe!=.None {return kai_why(command,&k)}
        fmt.printfln("Project %s is the org's; its bookmarks reach the org's peers.",short(project_id[:]))
        return 0
    }
    if verb=="grant" && sub=="load" {
        g,e:=vcs.machine_grant_load(m,positionals[1])
        if e!=.None {return kai_why(command,&k)}
        org:=g.org
        fmt.printfln("Grant of %s on org %s held until %s: the agent reaches its issuer now%s.",rights_text(g.rights),short(org[:]),day_text(g.not_after),k.agent?"":" (mirai kai agent starts one)")
        return 0
    }
    org,e:=vcs.machine_org_find(m,a.org)
    if e!=.None {return kai_why(command,&k)}
    switch sub {
    case "list":
        if verb=="grant" {return kai_grants(&k,org)}
        for id in m.orgs {
            if a.org=="" || id==org {kai_org_print(m,id)}
        }
    case "leave":
        if vcs.machine_leave(m,org)!=.None {return kai_why(command,&k)}
        fmt.println("This machine left the org and serves it no more.")
    case "remove","transfer","role":
        user,ue:=vcs.machine_member(m,org,positionals[1])
        if ue!=.None {return kai_why(command,&k)}
        switch sub {
        case "remove": e=vcs.machine_member_remove(m,org,user)
        case "transfer": e=vcs.machine_owner_transfer(m,org,user)
        case "role": e=vcs.machine_role_set(m,org,user,ka.role_of(positionals[2]))
        }
        if e!=.None {return kai_why(command,&k)}
        fmt.printfln("Done: the org's peers take it at once.")
    case "add":
        p,ok:=kai_project(&k,a.folder,command)
        if !ok {return 1}
        defer ka.project_close(p)
        project_id,pe:=ka.project_join(p,m,org,positionals[1]=="public")
        if pe!=.None {return kai_why(command,&k)}
        fmt.printfln("Project %s is the org's, %s; its bookmarks reach the org's peers.",short(project_id[:]),positionals[1]=="public"?"public":"read by the org alone")
    case "issue":
        key,dh,_:=kai_subject(positionals[1])
        rights,_:=kai_rights(a.rights)
        project_id:vcs.Log_Id
        if a.folder_given {
            p,ok:=kai_project(&k,a.folder,command)
            if !ok {return 1}
            defer ka.project_close(p)
            if project_id,_,e=ka.project_of(p,m);e!=.None {return kai_why(command,&k)}
        }
        addresses:=make([dynamic]net.Address,context.temp_allocator)
        if k.agent {vcs.control_addresses(&k.control,&addresses)}
        text,ie:=vcs.machine_grant_issue(m,org,dh,key,rights,project_id,a.path,a.days,addresses[:],context.temp_allocator)
        if ie!=.None {return kai_why(command,&k)}
        fmt.printfln("Grant of %s for %d days. On the holder's machine run\n  mirai kai grant load %s",rights_text(rights),a.days,text)
    case "revoke":
        bytes,fe:=vcs.machine_grant_find(m,org,positionals[1])
        if fe!=.None || vcs.machine_grant_revoke(m,org,bytes)!=.None {return kai_why(command,&k)}
        fmt.println("Revoked: the org's peers refuse its holder from now on.")
    }
    return 0
}

@(private="file")
kai_org_print :: proc(m:^vcs.Machine,id:vcs.Log_Id) {
    v:ka.Org_View
    x:=id
    if ka.org_view(m,id,&v)!=.None {
        fmt.printfln("Org %s: its log is not here yet",short(x[:]))
        return
    }
    fmt.printfln("Org %s %s, owner %s",short(x[:]),v.name,v.owner!=""?v.owner:"?")
    for member in v.members {
        user:=member.user
        if member.handle=="" {
            fmt.printfln("  member %s %s (its log is not here yet)",short(user[:]),ka.role_text(member.role))
            continue
        }
        devices:=make([dynamic]string,context.temp_allocator)
        for d in member.devices {
            key:=d.key
            mark:=d.revoked?" revoked":d.this?" (this device)":""
            append(&devices,fmt.tprintf("%s %s%s",d.name,short(key[:]),mark))
        }
        fmt.printfln("  member %s %s %s: %s",member.handle,short(user[:]),ka.role_text(member.role),strings.join(devices[:],", ",context.temp_allocator))
    }
    for p in v.projects {
        pid:=p.id
        fmt.printfln("  project %s %s (%s)",short(pid[:]),p.name!=""?p.name:"(its log is not here yet)",p.public?"public":"org")
        for policy in p.policies {fmt.printfln("    policy %s: %s",policy.bookmark,policy.text)}
        for sc in v.scopes {
            if sc.project==pid {kai_scope_print("    ",sc)}
        }
    }
    for n in v.nodes {
        key:=n.key
        fmt.printfln("  node %s %s",short(key[:]),ka.node_modes_text(n.modes))
    }
}

@(private="file")
kai_scope_print :: proc(indent:string,sc:ka.Scope_View) {
    fmt.printfln("%sscope %s %s, read by %s%s",indent,sc.id,strings.join(sc.patterns," ",context.temp_allocator),ka.role_text(sc.readers),sc.history?", keeps history":"")
}

@(private="file")
kai_grants :: proc(k:^Kai_Machine,org:vcs.Log_Id) -> int {
    m:=&k.machine
    o:vcs.Org_State
    if vcs.org_state_load(&m.store,org,&o,context.temp_allocator)!=.None {return kai_why("grant list",k)}
    now:=time.now()._nsec
    for item,i in o.log.items {
        if item.entry.type!=.Grant || !o.fold.valid[i] {continue}
        g,e:=vcs.grant_verify(&o.fold,item.entry.body,now)
        address:=store.address_of_bytes(item.entry.body)
        dh:=g.subject_dh
        state:=e==.None?"in force":e==.Expired?"expired":"revoked"
        scope:=g.path==""?"":fmt.tprintf(" under %s",g.path)
        fmt.printfln("grant %s %s to %s%s until %s: %s",short(address[:]),rights_text(g.rights),short(dh[:]),scope,day_text(g.not_after),state)
    }
    held:=make([dynamic]vcs.Held_Grant,context.temp_allocator)
    vcs.machine_grants_held(&m.store,&held)
    for h in held {
        address,g:=h.address,h.grant
        fmt.printfln("held grant %s %s until %s",short(address[:]),rights_text(g.rights),day_text(g.not_after))
    }
    return 0
}

// mirai kai scope, public, proposal, check and verify: what the team does
// with the workspace's project.
@(private="file")
kai_review :: proc(verb:string,p:^ka.Project,store_root:string,a:^Kai_Args) -> int {
    k:Kai_Machine
    if !kai_machine_open(&k,store_root) {return 1}
    defer kai_machine_close(&k)
    m:=&k.machine
    positionals:=a.positionals[:]
    sub:=len(positionals)>0?positionals[0]:""
    command:=strings.concatenate({verb," ",sub},context.temp_allocator)
    project_id,org,e:=ka.project_of(p,m)
    if e!=.None {return kai_why(command,&k)}
    proposal :: proc(p:^ka.Project,k:^Kai_Machine,text,command:string) -> (id:vcs.Log_Id,ok:bool) {
        _,found,e:=ka.proposal_find(p,&k.machine,text)
        if e!=.None {
            kai_why(command,k)
            return
        }
        return found,true
    }
    stack :: proc(p:^ka.Project,k:^Kai_Machine,texts:[]string,command:string) -> (revisions:[dynamic]vcs.Revision,ok:bool) {
        revisions=make([dynamic]vcs.Revision,context.temp_allocator)
        for text in texts {
            r,e:=ka.revision_resolve(p,&k.machine,text)
            if e!=.None {
                fmt.eprintfln("mirai kai %s: %q: %s",command,text,k.machine.why)
                return
            }
            append(&revisions,r)
        }
        return revisions,true
    }
    switch verb {
    case "verify":
        report:vcs.Verify_Report
        if e=vcs.machine_project_verify(m,project_id,&report);e!=.None {return kai_failed(verb,e)}
        if report.failed!="" {fmt.eprintfln("mirai kai verify: %s",report.failed);return 1}
        fmt.printfln("Verified %d logs (%d entries), %d device refs and %d changes with their trees.",report.logs,report.entries,report.refs,report.changes)
    case "public":
        path,line:=positionals[1],0
        if cut:=strings.last_index_byte(path,':');cut>0 {
            if n,parsed:=strconv.parse_int(path[cut+1:]);parsed && n>0 {path,line=path[:cut],n}
        }
        if ka.public_add(p,m,path,line)!=.None {return kai_why(command,&k)}
        fmt.println(line>0?"The leak on that line is waived for the project.":"The path stays public for the project.")
    case "scope":
        switch sub {
        case "list":
            v:ka.Org_View
            if ka.org_view(m,org,&v)!=.None {return kai_why(command,&k)}
            for sc in v.scopes {
                if sc.project==project_id {kai_scope_print("",sc)}
            }
            for x in v.publics {
                if x.project==project_id {fmt.printfln("public %s",x.path)}
            }
        case "add":
            readers:=vcs.Role.Writer
            if a.readers=="owner" {readers=.Owner} else if a.readers!="" {readers=ka.role_of(a.readers)}
            scope,se:=ka.scope_add(p,m,positionals[1:],readers,a.history)
            if se!=.None {return kai_why(command,&k)}
            fmt.printfln("Scope %s: what its patterns match is sealed for its readers from the next snapshot on.",ka.hex(scope[:4]))
        case "remove","rotate":
            scope,fe:=ka.scope_find(p,m,positionals[1])
            if fe!=.None {return kai_why(command,&k)}
            if sub=="remove" {
                if ka.scope_remove(p,m,scope)!=.None {return kai_why(command,&k)}
                fmt.println("Scope removed: its paths are no longer sealed in the next snapshots.")
            } else {
                epoch,re:=ka.scope_rotate(p,m,scope)
                if re!=.None {return kai_why(command,&k)}
                fmt.printfln("The scope's key is at epoch %d, wrapped for its readers now.",epoch)
            }
        }
    case "check":
        id:vcs.Log_Id
        if a.proposal!="" {
            ok:bool
            if id,ok=proposal(p,&k,a.proposal,command);!ok {return 1}
        }
        resolved,found:=script_command(a.command)
        if !found {return 127}
        echo :: proc(_:rawptr,bytes:[]u8) {os.write(os.stdout,bytes)}
        passed,target,ce:=ka.check_run(p,m,id,positionals[0],resolved,{procedure=echo})
        if ce!=.None {return kai_why("check",&k)}
        fmt.printfln("Check %s %s on proposal %s.",positionals[0],passed?"passed":"failed",short(target[:]))
        if !passed {return 1}
    case "proposal":
        return kai_proposal(p,&k,project_id,a,proposal,stack)
    }
    return 0
}

@(private="file")
kai_proposal :: proc(p:^ka.Project,k:^Kai_Machine,project_id:vcs.Log_Id,a:^Kai_Args,
    proposal:proc(p:^ka.Project,k:^Kai_Machine,text,command:string) -> (vcs.Log_Id,bool),
    stack:proc(p:^ka.Project,k:^Kai_Machine,texts:[]string,command:string) -> ([dynamic]vcs.Revision,bool)) -> int {
    m:=&k.machine
    positionals:=a.positionals[:]
    sub:=positionals[0]
    command:=strings.concatenate({"proposal ",sub},context.temp_allocator)
    switch sub {
    case "list":
        rows:=make([dynamic]ka.Proposal_Row,context.temp_allocator)
        if ka.proposal_list(p,m,&rows)!=.None {return kai_why(command,k)}
        for r in rows {
            id:=r.id
            fmt.printfln("%s %v %s %q by %s, %d approvals, %d comments",short(id[:]),r.status,r.target,r.title,r.opener,r.approvals,r.comments)
        }
        if len(rows)==0 {fmt.println("no proposals")}
        return 0
    case "open":
        revisions,ok:=stack(p,k,positionals[2:],command)
        if !ok {return 1}
        title:=a.message
        if title=="" {title=description_line(ka.proposal_title(p))}
        id,e:=ka.proposal_open(p,m,positionals[1],title,a.text,revisions[:])
        if e!=.None {return kai_why(command,k)}
        fmt.printfln("Proposal %s on %s opened: reviewers see it at once.",short(id[:]),positionals[1])
        return 0
    }
    id,ok:=proposal(p,k,positionals[1],command)
    if !ok {return 1}
    e:vcs.Error
    switch sub {
    case "show":
        v:ka.Proposal_View
        if ka.proposal_view(p,m,id,&v)!=.None {return kai_why(command,k)}
        fmt.printfln("Proposal %s %v on %s: %s, by %s",short(id[:]),v.status,v.target,v.title,v.opener)
        if v.text!="" {fmt.printfln("  %s",v.text)}
        for item in v.stack {
            fmt.printfln("  change %s %s",ka.change_text(item.change),description_line(item.description))
        }
        for n in v.notes {
            place:="on the proposal"
            switch {
            case n.path=="":
            case n.anchor.kind==.Lines: place=fmt.tprintf("on %s:%d-%d",n.path,n.anchor.line,n.anchor.line+n.anchor.lines-1)
            case n.anchor.kind==.Structural: place=fmt.tprintf("on %s#%d",n.path,n.anchor.key)
            case: place=fmt.tprintf("on %s",n.path)
            }
            address:=n.address
            fmt.printfln("  comment %s by %s %s%s: %s",short(address[:]),n.author,place,n.outdated?" (outdated)":"",n.text)
        }
        for x in v.verdicts {fmt.printfln("  %v by %s%s",x.verdict,x.user,x.current?"":" (on an earlier revision)")}
        for c in v.checks {fmt.printfln("  check %s %v",c.name,c.state)}
        switch {
        case v.status==.Landed: fmt.println("  It landed.")
        case v.status==.Closed: fmt.println("  It is closed: mirai kai proposal reopen opens it again.")
        case v.blocking=="": fmt.println("  It may land: mirai kai proposal land lands it.")
        case: fmt.printfln("  It may not land yet: %s",v.blocking)
        }
        return 0
    case "revise":
        revisions,stacked:=stack(p,k,positionals[2:],command)
        if !stacked {return 1}
        e=ka.proposal_revise(p,m,id,revisions[:])
    case "comment":
        path,anchor,_:=kai_anchor(a)
        e=ka.proposal_comment(p,m,id,path,anchor,a.reply,a.message)
    case "approve": e=vcs.machine_proposal_verdict(m,project_id,id,.Approve)
    case "changes": e=vcs.machine_proposal_verdict(m,project_id,id,.Changes)
    case "withdraw": e=vcs.machine_proposal_verdict(m,project_id,id,.Withdraw)
    case "close","reopen": e=vcs.machine_proposal_close(m,project_id,id,sub=="reopen")
    case "land": e=vcs.machine_proposal_land(m,project_id,id)
    }
    if e!=.None {return kai_why(command,k)}
    if sub=="land" {
        fmt.println("Landed: the target moved for the whole org.")
    } else {
        fmt.println("Done: the org's peers see it at once.")
    }
    return 0
}

@(private="file")
crypto_zero :: proc(buffer:^[vcs.RECOVERY_TEXT]u8) {
    crypto.zero_explicit(buffer,size_of(buffer^))
}

// Wipes a recovery key typed in, which lives in the temp allocator.
@(private="file")
crypto_zero_text :: proc(text:string) {
    crypto.zero_explicit(raw_data(text),len(text))
}
