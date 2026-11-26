package editor

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import "mirai:project"

// The team from the editor: the Kai state of the machine of its store (its
// profile and orgs) and the machine's agent, which runs in this process on
// the editor's own Store, so nothing reaches it over a socket. The team is
// the machine's, not the project's (Kai.team): a launcher with no project
// opens it too. The agent starts once the machine is in an org, or when it
// joins one. What the views show is read into an arena only when the agent
// says something moved (vcs.agent_generation) or this editor wrote: a frame
// that changes nothing reads nothing. A pull (kai.clone) makes the folder a
// workspace of an org's repository at once, and writes its files the first
// time the agent has every object of main, as the agent's own count of
// chunks and bytes says how far it is.

KAI_TEXT :: 256 // bytes of a text the editor keeps of the agent
KAI_READ_EVERY :: 250*time.Millisecond // between two reads of what the agent moved: a pull moves it at every batch

// What the Kai tab shows: the working copy and the log, or the team.
Kai_Tab :: enum u8 {Changes,Team}

// A repository of an org, as the Repositories of the launcher list it.
Kai_Repository :: struct {
    org:int,  // of view.orgs
    repo:int, // of its repos
}

// A row of the team views: a name and what follows it.
Kai_Line :: struct {name,rest:string}

// What a view shows of an org, its texts made when it is read.
Kai_Org_Lines :: struct {
    title:string, // the org's name, in capitals
    role:string,  // "You are admin."
    members:[]Kai_Line,
    repos:[]Kai_Line,
}

// What the team views show, in the team's arena.
Kai_Team_View :: struct {
    lines:[]Kai_Org_Lines, // of orgs
    listening:string,      // where this machine listens, said whole
    peer_lines:[]Kai_Line,
    publish:string,        // the Changes view's line over Publish to main
    orgs:[]ka.Org_View,
    org:int,            // of orgs, the one the open project is in; -1 when none
    link:vcs.Link,      // of the open project, when org>=0
    shared:[]ka.Shared_Bookmark,
    peers:[]vcs.Peer_Info,
    pulls:[]vcs.Pull,
    addresses:[]string, // where this machine listens on its LAN
    repositories:[]Kai_Repository,
}

// The texts the team views type.
Kai_Fields :: struct {
    name:[vcs.NAME_MAX]u8,
    name_length:int,
    device:[vcs.NAME_MAX]u8,
    device_length:int,
    org:[vcs.NAME_MAX]u8,
    org_length:int,
    invite:[1024]u8,    // to join with
    invite_length:int,
    at:[vcs.ADDRESS_MAX]u8, // host:port a machine outside the LAN reaches this one at
    at_length:int,
    server:[vcs.ADDRESS_MAX]u8, // a server's host:port, for the web sign-in
    server_length:int,
    login:[vcs.NAME_MAX]u8,
    login_length:int,
    password:[256]u8,
    password_length:int,
    bookmark:[64]u8,
    bookmark_length:int,
    role:vcs.Role,      // of the next invite
    mine:bool,          // the next invite is for a machine of this person
    public:bool,        // the first publish makes the repository public
}

Kai_Clone_Stage :: enum u8 {None,Waiting,Done,Failed}

// What the agent does on a thread of its own, so the frames go on: a join,
// which reaches another machine and waits for its record, or a web sign-in,
// which reaches a server. Its texts are copies, the password zeroed once it
// ends.
Kai_Task_Kind :: enum u8 {Join,Web_Login}

Kai_Task :: struct {
    kind:Kai_Task_Kind,
    stage:Kai_Clone_Stage,
    thread:^thread.Thread,
    ended:bool,                   // atomic: its thread returned; what follows it wrote before
    failed:bool,
    agent:^vcs.Agent,
    text:[1024]u8,                // the invite, or the server's host:port
    text_length:int,
    name:[vcs.NAME_MAX]u8,        // the web sign-in's
    name_length:int,
    password:[256]u8,
    password_length:int,
    org:vcs.Org_Id,               // the join's
    why:[KAI_TEXT]u8,
    why_length:int,
}

// A repository of an org coming into a folder of this machine.
Kai_Clone :: struct {
    stage:Kai_Clone_Stage,
    org:vcs.Org_Id,
    repo:vcs.Repo_Id,
    project:ka.Project,
    opened:bool,
    folder:[1024]u8,
    folder_length:int,
    name:[vcs.NAME_MAX]u8,
    name_length:int,
    why:[KAI_TEXT]u8,
    why_length:int,
}

Kai_Team :: struct {
    team:vcs.Team,
    opened:bool,
    agent:vcs.Agent,
    running:bool,
    why:[KAI_TEXT]u8, // why the agent does not run
    why_length:int,
    generation:u64,   // of the agent when the view was read
    read_at:time.Tick, // when it was
    arena:vmem.Arena,
    view:Kai_Team_View,
    invite:[1024]u8,  // offered last
    invite_length:int,
    fields:Kai_Fields,
    clone:Kai_Clone,
    tasks:[Kai_Task_Kind]Kai_Task,
    invite_org:vcs.Org_Id, // whose invite was offered last
    publish_org:int,       // of view.orgs, where a first publish goes
    scroll:[2]f32,
    width:f32,
}

// Opens the team of the editor's store, and starts its agent when the
// machine is in an org.
kai_team_open :: proc(s:^Session) {
    k:=s.kai
    if k==nil || k.team!=nil || s.store.root=="" {return}
    t,e:=new(Kai_Team)
    if e!=nil {return}
    k.team=t
    if vcs.team_open(&t.team,&s.store)!=.None {
        notify(s,fmt.tprintf("Kai: %s",t.team.why))
        return
    }
    t.opened=true
    t.fields.role=.Writer
    if t.team.name=="" {
        host:[128]u8
        name:=os.get_env(ODIN_OS==.Windows?"USERNAME":"USER",context.temp_allocator)
        t.fields.name_length=copy(t.fields.name[:],name)
        device:=vcs.host_name(host[:])
        if cut:=strings.index_byte(device,'.');cut>0 {device=device[:cut]}
        t.fields.device_length=copy(t.fields.device[:],device)
    }
    if len(vcs.team_org_ids(&t.team))>0 {kai_agent_start(s)}
    kai_team_read(s)
}

kai_team_close :: proc(s:^Session) {
    k:=s.kai
    if k==nil || k.team==nil {return}
    t:=k.team
    if t.clone.opened {ka.project_close(&t.clone.project)}
    // A task sees the agent stop: its dial is cancelled and its peer ends.
    if t.running {vcs.agent_stop(&t.agent)}
    for &x in t.tasks {kai_task_end(&x)}
    if t.opened {vcs.team_close(&t.team)}
    vmem.arena_destroy(&t.arena)
    free(t)
    k.team=nil
}

// Starts the machine's agent in this process, which asks the router to
// forward its port: "" or why it does not.
kai_agent_start :: proc(s:^Session) -> string {
    t:=s.kai.team
    if t==nil || !t.opened {return "The Kai state of the store is not open"}
    if t.running {return ""}
    options:=vcs.Agent_Options{port=0,beacon=true,portmap=true}
    if s.kai.mesh_loopback {options={port=0,host="127.0.0.1"}}
    if vcs.agent_start(&t.agent,&t.team,options,runtime.heap_allocator())!=.None {
        t.why_length=copy(t.why[:],t.team.why)
        log.warnf("the Kai agent does not start: %s",t.team.why)
        return fmt.tprintf("The Kai agent does not start: %s",t.team.why)
    }
    t.running,t.why_length=true,0
    return ""
}

// Between frames: what the agent changed is read again, at most every
// KAI_READ_EVERY, and a pull that waits writes its files once the agent says
// its repository came whole.
kai_team_poll :: proc(s:^Session) {
    if s.kai==nil {return}
    t:=s.kai.team
    if t==nil || !t.running {return}
    for &x in t.tasks {
        if x.stage!=.Waiting || !sync.atomic_load(&x.ended) {continue}
        kai_task_end(&x)
        x.stage=x.failed?.Failed:.Done
        why:=string(x.why[:x.why_length])
        switch x.kind {
        case .Join:
            if x.stage==.Done {
                t.fields.invite_length=0
                kai_team_wrote(s)
                o,_,_:=vcs.team_org(&t.team,x.org)
                notify(s,fmt.tprintf("Kai: this machine joined %s",o.name))
            } else {
                notify(s,fmt.tprintf("Kai: %s",why))
            }
        case .Web_Login: notify(s,x.stage==.Done?"Kai: the web sign-in is set":fmt.tprintf("Kai: %s",why))
        }
    }
    generation:=vcs.agent_generation(&t.agent)
    if generation==t.generation || t.read_at!={} && time.tick_since(t.read_at)<KAI_READ_EVERY {return}
    t.generation,t.read_at=generation,time.tick_now()
    kai_team_read(s)
    if c:=&t.clone;c.stage==.Waiting {
        for p in t.view.pulls {
            if p.org==c.org && p.repo==c.repo && p.whole {kai_clone_step(s)}
        }
    }
    kai_read(s)
}

// Starts a task of the agent: "" or why it does not.
kai_task_start :: proc(s:^Session,kind:Kai_Task_Kind,text:string,name:string="",password:string="") -> string {
    t:=s.kai.team
    x:=&t.tasks[kind]
    if x.stage==.Waiting {return kind==.Join?"A join runs: wait for it":"A web sign-in runs: wait for it"}
    if len(text)>len(x.text) || len(name)>len(x.name) || len(password)>len(x.password) {return "That is longer than Kai takes"}
    if message:=kai_agent_start(s);message!="" {return message}
    kai_task_end(x)
    x^={kind=kind,stage=.Waiting,agent=&t.agent}
    x.text_length=copy(x.text[:],text)
    x.name_length=copy(x.name[:],name)
    x.password_length=copy(x.password[:],password)
    c:=runtime.default_context()
    c.allocator,c.logger=runtime.heap_allocator(),context.logger
    x.thread=thread.create_and_start_with_poly_data(x,proc(x:^Kai_Task) {
        defer vcs.thread_end()
        e:vcs.Error
        switch x.kind {
        case .Join: x.org,e=vcs.agent_join(x.agent,string(x.text[:x.text_length]))
        case .Web_Login: e=vcs.agent_web_login(x.agent,string(x.text[:x.text_length]),string(x.name[:x.name_length]),string(x.password[:x.password_length]))
        }
        crypto.zero_explicit(&x.password,size_of(x.password))
        x.failed=e!=.None
        if e!=.None {x.why_length=copy(x.why[:],x.agent.team.why!=""?x.agent.team.why:vcs.error_text(e))}
        sync.atomic_store(&x.ended,true)
    },c)
    if x.thread==nil {
        crypto.zero_explicit(&x.password,size_of(x.password))
        x.stage=.Failed
        return "Kai could not start a thread"
    }
    return ""
}

// Waits for a task's thread, which the agent's stop or its own bounds end.
@(private)
kai_task_end :: proc(x:^Kai_Task) {
    if x.thread==nil {return}
    thread.join(x.thread)
    thread.destroy(x.thread)
    x.thread=nil
}

// After a write of the team: its peers hear it now and the views follow.
kai_team_wrote :: proc(s:^Session) {
    t:=s.kai.team
    if t==nil {return}
    if !t.running && len(vcs.team_org_ids(&t.team))>0 {kai_agent_start(s)}
    if t.running {vcs.agent_changed(&t.agent)}
    kai_team_read(s)
    kai_read(s)
}

// What the team views show, read again into the arena.
kai_team_read :: proc(s:^Session) {
    t:=s.kai.team
    if t==nil {return}
    vmem.arena_destroy(&t.arena)
    t.view={org=-1}
    if !t.opened || vmem.arena_init_growing(&t.arena)!=nil {return}
    a:=vmem.arena_allocator(&t.arena)
    v:=&t.view
    ids:=vcs.team_org_ids(&t.team)
    orgs:=make([dynamic]ka.Org_View,0,len(ids),a)
    repositories:=make([dynamic]Kai_Repository,a)
    for id in ids {
        o:ka.Org_View
        if ka.org_view(&t.team,id,&o,a)!=.None {continue}
        for _,r in o.repos {append(&repositories,Kai_Repository{len(orgs),r})}
        append(&orgs,o)
    }
    v.orgs,v.repositories=orgs[:],repositories[:]
    v.lines=make([]Kai_Org_Lines,len(orgs),a)
    for &o,i in orgs {
        x:=&v.lines[i]
        x.title=strings.to_upper(o.name,a)
        x.role=fmt.aprintf("You are %s.",o.role,allocator=a)
        x.members=make([]Kai_Line,len(o.members),a)
        for m,k in o.members {
            role:=m.role=="node"?"server":m.role
            x.members[k]={fmt.aprintf("%s (%s)",m.name,m.device,allocator=a),m.you?fmt.aprintf("%s, this machine",role,allocator=a):role}
        }
        x.repos=make([]Kai_Line,len(o.repos),a)
        for r,k in o.repos {
            state:="not published yet"
            if r.published {state=r.main!=""?fmt.aprintf("main %s%s",r.main,r.here?"":", on its way",allocator=a):"main published"}
            x.repos[k]={r.name,fmt.aprintf("%s, %s",r.public?"public":"org only",state,allocator=a)}
        }
    }
    if t.running {
        peers:=make([dynamic]vcs.Peer_Info,a)
        vcs.agent_peers(&t.agent,&peers,a)
        pulls:=make([dynamic]vcs.Pull,a)
        vcs.agent_pulls(&t.agent,&pulls)
        v.peers,v.pulls=peers[:],pulls[:]
        v.addresses=vcs.agent_addresses(&t.agent,a)
        v.peer_lines=make([]Kai_Line,len(peers),a)
        for p,k in peers {v.peer_lines[k]={fmt.aprintf("%s (%s)",p.device,p.name,allocator=a),fmt.aprintf("connected, %s",p.address,allocator=a)}}
        if len(v.addresses)>0 {v.listening=fmt.aprintf("Listening at %s. When the router opens its port (UPnP, NAT-PMP or PCP), the first is where machines on other networks reach it; otherwise they need a forwarded port or a Kai server.",strings.join(v.addresses,", ",context.temp_allocator),allocator=a)}
        events:=make([dynamic]string,context.temp_allocator)
        vcs.agent_events(&t.agent,&events,context.temp_allocator)
        for e in events {log.infof("kai: %s",e)}
    }
    if len(orgs)>0 {v.publish=fmt.aprintf("Publish this project to %s:",orgs[0].name,allocator=a)}
    st:=s.kai.state
    if st==nil {return}
    l,e:=ka.project_of(&st.project,&t.team)
    if e!=.None {return}
    v.link=l
    for o,i in orgs {
        if o.id!=l.org {continue}
        v.org=i
        for r in o.repos {
            if r.id==l.repo {v.publish=fmt.aprintf("%s in %s, %s",r.name,o.name,r.public?"public":"org only",allocator=a)}
        }
    }
    shared:=make([dynamic]ka.Shared_Bookmark,a)
    ka.bookmarks_shared(&st.project,&t.team,&shared,a)
    v.shared=shared[:]
}

// The team to act on, or why there is none; its why is cleared.
kai_team_of :: proc(s:^Session) -> (t:^vcs.Team,message:string) {
    if s.kai==nil {return nil,kai_missing(s)}
    kai_team_open(s)
    k:=s.kai.team
    if k==nil || !k.opened {return nil,"The Kai state of the store is not open: start the editor with a store this user may write"}
    k.team.why=""
    return &k.team,""
}

// --- Pulling a repository into a folder ---

// Pulls a repository of org into folder, which must be empty, not there yet,
// or a workspace a pull of it left. "" or why it does not start.
kai_clone_start :: proc(s:^Session,org:vcs.Org_Id,repo:vcs.Repo_Id,name,folder:string) -> string {
    t:=s.kai.team
    c:=&t.clone
    if c.stage==.Waiting {return fmt.tprintf("%s is being pulled: wait for it, or cancel it",string(c.name[:c.name_length]))}
    if folder=="" {return "Choose where the project goes"}
    kai_clone_cancel(s)
    if message:=kai_agent_start(s);message!="" {return message}
    c.org,c.repo=org,repo
    c.folder_length=copy(c.folder[:],folder)
    c.name_length=copy(c.name[:],name)
    if ka.project_clone(&c.project,&t.team,folder,&s.store,org,repo,kai_types(s))!=.None {
        c.stage=.Failed
        c.why_length=copy(c.why[:],t.team.why!=""?t.team.why:"the folder could not be made a workspace")
        return string(c.why[:c.why_length])
    }
    c.opened,c.stage=true,.Waiting
    log.infof("pulling %s into %s",name,folder)
    vcs.agent_changed(&t.agent)
    kai_clone_step(s)
    return ""
}

// Writes the files of the pull once they are all here.
@(private)
kai_clone_step :: proc(s:^Session) {
    t:=s.kai.team
    c:=&t.clone
    if c.stage!=.Waiting {return}
    _,e:=ka.clone_checkout(&c.project,&t.team)
    #partial switch e {
    case .None:
        c.stage=.Done
        ka.project_close(&c.project)
        c.opened=false
        folder:=string(c.folder[:c.folder_length])
        log.infof("pulled %s into %s",string(c.name[:c.name_length]),folder)
        if p:=s.projects;p!=nil && p.launcher {
            if message:=projects_open(s,folder);message!="" {notify(s,message)}
        } else {
            notify(s,fmt.tprintf("%s is in %s: open it from Projects",string(c.name[:c.name_length]),folder))
        }
    case .Missing:
        c.why_length=copy(c.why[:],t.team.why)
    case:
        c.stage=.Failed
        c.why_length=copy(c.why[:],t.team.why!=""?t.team.why:vcs.error_text(e))
    }
}

// Stops the pull: its folder stays a workspace a later pull goes on with.
kai_clone_cancel :: proc(s:^Session) {
    t:=s.kai.team
    if t==nil {return}
    c:=&t.clone
    if c.opened {ka.project_close(&c.project)}
    c^={}
}

// How far the pull is: chunks and bytes the agent took for its repository.
kai_clone_progress :: proc(t:^Kai_Team) -> (chunks:int,bytes:i64) {
    for p in t.view.pulls {
        if p.org==t.clone.org && p.repo==t.clone.repo {return p.chunks,p.bytes}
    }
    return
}

// The folder a repository is pulled into: one of the location named after it.
kai_clone_folder :: proc(s:^Session,name:string) -> string {
    p:=s.projects
    if p==nil {return ""}
    location:=strings.trim_space(string(p.location[:p.location_length]))
    if location=="" || !vcs.repo_name_valid(name) {return ""}
    return project.path(location,name,allocator=context.temp_allocator)
}
