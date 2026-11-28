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
import "mirai:std/base"

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
KAI_READ_EVERY :: 15*time.Second // between background re-reads when the agent moves; local writes and Refresh read immediately
KAI_REACH_WAIT :: 1500*time.Millisecond // an invite waits for the router this long while it has not answered

// What the Kai tab shows: the working copy and the log, or the team.
Kai_Tab :: enum u8 {Changes,Team}

// A repository of an org, as the Repositories of the launcher list it.
Kai_Repository :: struct {
    org:int,  // of view.orgs
    repo:int, // of its repos
}

// A row of the team views: a name and what follows it.
Kai_Line :: struct {name,rest:string}

// A member row of an org, preformatted in the team's arena.
Kai_Member_Line :: struct {
    name,rest,key_hex:string,
    role:vcs.Role,
    you:bool,
}

// What the launcher's Team view shows: the org cards, with the card of a new
// org or of a join open, or one org.
Kai_Team_Card :: enum u8 {None,New_Org,Join_Org}
Kai_Team_Cards :: struct {open:Kai_Team_Card}
Kai_Team_Org :: struct {
    org:vcs.Org_Id,
    web_login:bool, // its web view sign-in is unfolded
}
Kai_Team_Screen :: union #no_nil {Kai_Team_Cards,Kai_Team_Org}

// What a view shows of an org, its texts made when it is read.
Kai_Org_Lines :: struct {
    title:string,   // the org's name, in capitals
    role:string,    // "You are admin."
    summary:string, // "3 members · 1 repo"
    server:string,  // "Server synced · host:port" when attached, "" otherwise
    admins:int,
    members:[]Kai_Member_Line,
    repos:[]Kai_Line,
}

// What the team views show, in the team's arena.
Kai_Team_View :: struct {
    lines:[]Kai_Org_Lines, // of orgs
    machine:string,        // "name (device)" of this machine
    reach:string,          // how other networks reach this machine, in a few words
    online:bool,           // they reach it at the router's address
    default_server:string, // central server host:port available for 1-click attach, "" when disabled
    peer_lines:[]Kai_Line,
    publish:string,        // the Changes view's line over Publish to main
    orgs:[]ka.Org_View,
    org_names:[]string, // of orgs, for the publish organization dropdown
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

// What the agent does on a thread of its own, so the frames go on: a join,
// which reaches another machine and waits for its record, a web sign-in, or
// attaching an org to a central server. Its texts are copies, the password
// zeroed once it ends.
Kai_Task_Kind :: enum u8 {Join,Web_Login,Attach}

Kai_Task_State :: enum u8 {
    Idle,
    Running, // its thread runs
    Ended,   // its thread returned, setting it last (atomic): why holds its failure, empty when none
    Done,
    Failed,
}

Kai_Task :: struct {
    kind:Kai_Task_Kind,
    state:Kai_Task_State,         // atomic while its thread runs, which alone writes Ended
    thread:^thread.Thread,
    silent:bool,                  // auto-attach: do not toast if offline
    agent:^vcs.Agent,
    text:[1024]u8,                // the invite, or the server's host:port
    text_length:int,
    name:[vcs.NAME_MAX]u8,        // the web sign-in's
    name_length:int,
    password:[256]u8,
    password_length:int,
    org:vcs.Org_Id,               // the join's or attach's
    why:[KAI_TEXT]u8,             // its own failure, which its thread writes before Ended
    why_length:int,
}

// Whether a task's thread runs or ended unseen: another of its kind waits.
kai_task_busy :: proc(x:^Kai_Task) -> bool {
    state:=sync.atomic_load(&x.state)
    return state==.Running || state==.Ended
}

Kai_Clone_State :: enum u8 {
    Idle,
    Pulling, // its workspace is open, its lock this editor's, until the files are written
    Done,
    Failed,
}

// A repository of an org coming into a folder of this machine.
Kai_Clone :: struct {
    state:Kai_Clone_State, // kai_clone_end leaves Pulling
    org:vcs.Org_Id,
    repo:vcs.Repo_Id,
    project:ka.Project,    // open while Pulling
    folder:[1024]u8,
    folder_length:int,
    name:[vcs.NAME_MAX]u8,
    name_length:int,
    why:[KAI_TEXT]u8,
    why_length:int,
    why_copied:f64, // ui.Context.time its banner last copied why (error_banner)
}

// Whether the machine's Kai state opened and its agent runs.
Kai_Team_Status :: enum u8 {
    Closed,  // the Kai state of the store does not open (why): an action tries again
    Open,    // no agent runs: the machine is in no org yet, or it did not start (why)
    Running, // its agent runs in this process
}

Kai_Team :: struct {
    team:vcs.Team,
    status:Kai_Team_Status,
    agent:vcs.Agent,
    why:[KAI_TEXT]u8, // why the state does not open or the agent does not run
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
    invite_org:vcs.Org_Id,   // whose invite was offered last
    invite_copied:bool,      // the invite offered last was copied to the clipboard
    invite_copied_at:time.Tick, // when it was copied, to show the green check briefly
    invite_local:bool,       // it carries no address another network reaches
    invite_via_server:bool,  // it targets the org's central server (works while admin is off)
    invite_role:vcs.Role,    // role encoded into the invite offered last
    invite_mine:bool,        // whether the invite offered last is for another machine of this person
    invite_seq:int,          // incremented each time a new invite is made
    invite_meta:[160]u8,     // summary line shown under the invite field
    invite_meta_length:int,
    publish_org:int,         // of view.orgs, where a first publish goes
    screen:Kai_Team_Screen,  // of the launcher's Team view
    scroll:[2]f32,
    width:f32,
}

// Opens the team of the editor's store, and starts its agent when the
// machine is in an org. A team whose state did not open opens again only
// when retry: what an action of the person asks, never a frame.
kai_team_open :: proc(s:^Session,retry:=false) {
    k:=s.kai
    if k==nil || s.store.root=="" {return}
    t:=k.team
    if t!=nil && (t.status!=.Closed || !retry) {return}
    if t==nil {
        e:runtime.Allocator_Error
        if t,e=new(Kai_Team);e!=nil {return}
        k.team=t
    }
    t.team.why=""
    if vcs.team_open(&t.team,&s.store)!=.None {
        t.why_length=copy(t.why[:],t.team.why)
        notify(s,fmt.tprintf("Kai: %s",t.team.why))
        return
    }
    t.status,t.why_length=.Open,0
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
    kai_clone_end(&t.clone,.Idle)
    // A task sees the agent stop: its dial is cancelled and its peer ends.
    if t.status==.Running {vcs.agent_stop(&t.agent)}
    for &x in t.tasks {kai_task_end(&x)}
    if t.status!=.Closed {vcs.team_close(&t.team)}
    vmem.arena_destroy(&t.arena)
    free(t)
    k.team=nil
}

// Starts the machine's agent in this process, which asks the router to
// forward its port: "" or why it does not.
kai_agent_start :: proc(s:^Session) -> string {
    t:=s.kai.team
    if t==nil || t.status==.Closed {return "The Kai state of the store is not open"}
    if t.status==.Running {return ""}
    options:=vcs.Agent_Options{port=0,beacon=true,portmap=true}
    if s.kai.mesh_loopback {options={port=0,host="127.0.0.1"}}
    t.team.why=""
    if e:=vcs.agent_start(&t.agent,&t.team,options,runtime.heap_allocator());e!=.None {
        why:=t.team.why!=""?t.team.why:vcs.error_text(e)
        t.why_length=copy(t.why[:],why)
        log.warnf("the Kai agent does not start: %s",why)
        return fmt.tprintf("The Kai agent does not start: %s",why)
    }
    t.status,t.why_length=.Running,0
    return ""
}

// The central server host:port to attach new orgs to; "" when disabled.
kai_default_server :: proc(s:^Session,allocator:=context.temp_allocator) -> string {
    if s.kai!=nil {
        if s.kai.server!="" {
            copied,e:=strings.clone(s.kai.server,allocator)
            return e==nil?copied:""
        }
        if s.kai.mesh_loopback {return ""}
    }
    return vcs.default_server(allocator)
}

// Between frames: what the agent changed is read again at most every
// KAI_READ_EVERY (15 s). Active clones check whole directly without rebuilding
// the views until the pull completes.
kai_team_poll :: proc(s:^Session) {
    if s.kai==nil {return}
    t:=s.kai.team
    if t==nil {return}
    // A task is taken back once it ended, whether or not the agent still runs.
    for &x in t.tasks {
        if sync.atomic_load(&x.state)!=.Ended {continue}
        kai_task_end(&x)
        x.state=x.why_length>0?.Failed:.Done
        why:=string(x.why[:x.why_length])
        switch x.kind {
        case .Join:
            if x.state==.Done {
                t.fields.invite_length=0
                t.screen=Kai_Team_Org{org=x.org}
                kai_team_wrote(s)
                o,_,_:=vcs.team_org(&t.team,x.org)
                notify(s,fmt.tprintf("Kai: this machine joined %s",o.name))
            } else {
                notify(s,fmt.tprintf("Kai: %s",why))
            }
        case .Web_Login: notify(s,x.state==.Done?"Kai: the web sign-in is set":fmt.tprintf("Kai: %s",why))
        case .Attach:
            if x.state==.Done {
                kai_team_wrote(s)
                if !x.silent {notify(s,"Kai: org synced to server")}
            } else if !x.silent {
                notify(s,fmt.tprintf("Kai: %s",why))
            }
        }
    }
    if t.status!=.Running {return}
    if c:=&t.clone;c.state==.Pulling {
        if pull,ok:=vcs.agent_pull_of(&t.agent,c.org,c.repo);ok && pull.whole {
            kai_clone_step(s)
            t.generation,t.read_at=vcs.agent_generation(&t.agent),time.tick_now()
            kai_team_read(s)
            kai_read(s)
            if p:=s.projects;p!=nil && p.shown {projects_rows_read(s)}
            return
        }
    }
    generation:=vcs.agent_generation(&t.agent)
    if generation==t.generation || t.read_at!={} && time.tick_since(t.read_at)<KAI_READ_EVERY {return}
    t.generation,t.read_at=generation,time.tick_now()
    kai_team_read(s)
    if c:=&t.clone;c.state==.Pulling {
        for p in t.view.pulls {
            if p.org==c.org && p.repo==c.repo && p.whole {kai_clone_step(s)}
        }
    }
    kai_read(s)
}

// Starts a task of the agent: "" or why it does not.
kai_task_start :: proc(s:^Session,kind:Kai_Task_Kind,text:string,name:string="",password:string="",org:vcs.Org_Id={},silent:=false) -> string {
    t:=s.kai.team
    x:=&t.tasks[kind]
    if kai_task_busy(x) {
        switch kind {
        case .Join: return "A join runs: wait for it"
        case .Web_Login: return "A web sign-in runs: wait for it"
        case .Attach: return "Syncing an org to the server already: wait for it"
        }
    }
    if len(text)>len(x.text) || len(name)>len(x.name) || len(password)>len(x.password) {return "That is longer than Kai takes"}
    if message:=kai_agent_start(s);message!="" {return message}
    kai_task_end(x)
    x^={kind=kind,state=.Running,silent=silent,agent=&t.agent,org=org}
    x.text_length=copy(x.text[:],text)
    x.name_length=copy(x.name[:],name)
    x.password_length=copy(x.password[:],password)
    c:=runtime.default_context()
    c.allocator,c.logger=runtime.heap_allocator(),context.logger
    x.thread=thread.create_and_start_with_poly_data(x,proc(x:^Kai_Task) {
        defer vcs.thread_end()
        e:vcs.Error
        why:string // in this thread's temp allocator: copied before it ends
        switch x.kind {
        case .Join: x.org,e=vcs.agent_join(x.agent,string(x.text[:x.text_length]),&why)
        case .Web_Login: e=vcs.agent_web_login(x.agent,string(x.text[:x.text_length]),string(x.name[:x.name_length]),string(x.password[:x.password_length]),&why)
        case .Attach: e=vcs.agent_server_attach(x.agent,x.org,string(x.text[:x.text_length]),&why)
        }
        crypto.zero_explicit(&x.password,size_of(x.password))
        if e!=.None {x.why_length=copy(x.why[:],why!=""?why:vcs.error_text(e))}
        sync.atomic_store(&x.state,.Ended)
    },c)
    if x.thread==nil {
        crypto.zero_explicit(&x.password,size_of(x.password))
        x.why_length=copy(x.why[:],"Kai could not start a thread: memory ran out")
        x.state=.Failed
        return string(x.why[:x.why_length])
    }
    return ""
}

// Explicit Refresh: wakes the agent to sync and immediately re-reads the team,
// workspace, and project rows.
kai_team_refresh :: proc(s:^Session) {
    if s.kai!=nil {
        kai_team_open(s,retry=true)
        if t:=s.kai.team;t!=nil {
            if t.status==.Running {vcs.agent_sync_now(&t.agent)}
            t.generation=t.status==.Running?vcs.agent_generation(&t.agent):0
            t.read_at=time.tick_now()
            kai_team_read(s)
        }
        kai_read(s)
    }
    if p:=s.projects;p!=nil && p.shown {projects_rows_read(s)}
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
    if t==nil || t.status==.Closed {return}
    if t.status==.Open && len(vcs.team_org_ids(&t.team))>0 {kai_agent_start(s)}
    if t.status==.Running {vcs.agent_changed(&t.agent)}
    kai_team_read(s)
    kai_read(s)
}

// What the team views show, read again into the arena.
kai_team_read :: proc(s:^Session) {
    t:=s.kai.team
    if t==nil {return}
    vmem.arena_destroy(&t.arena)
    t.view={org=-1}
    if t.status==.Closed || vmem.arena_init_growing(&t.arena)!=nil {return}
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
    v.org_names=make([]string,len(orgs),a)
    for o,i in orgs {v.org_names[i]=o.name}
    v.machine=fmt.aprintf("%s (%s)",t.team.name,t.team.device,allocator=a)
    v.default_server=kai_default_server(s,a)
    v.lines=make([]Kai_Org_Lines,len(orgs),a)
    for &o,i in orgs {
        x:=&v.lines[i]
        x.title=strings.to_upper(o.name,a)
        x.role=fmt.aprintf("You are %s.",o.role,allocator=a)
        x.summary=fmt.aprintf("%d %s · %d %s",len(o.members),len(o.members)==1?"member":"members",len(o.repos),len(o.repos)==1?"repo":"repos",allocator=a)
        if o.server!="" {x.server=fmt.aprintf("Server synced · %s",o.server,allocator=a)}
        x.members=make([]Kai_Member_Line,len(o.members),a)
        for m,k in o.members {
            role:=m.role==.Node?"server":ka.role_text(m.role)
            if m.role==.Admin {x.admins+=1}
            key:=m.key
            x.members[k]={
                name=fmt.aprintf("%s (%s)",m.name,m.device,allocator=a),
                rest=m.you?fmt.aprintf("%s, this machine",role,allocator=a):role,
                key_hex=ka.hex(key[:8],a),
                role=m.role,
                you=m.you,
            }
        }
        x.repos=make([]Kai_Line,len(o.repos),a)
        for r,k in o.repos {
            state:="not published yet"
            switch r.main_state {
            case .Unpublished:
            case .Coming: state=r.main!=""?fmt.aprintf("main %s, on its way",r.main,allocator=a):"main published"
            case .Here: state=fmt.aprintf("main %s",r.main,allocator=a)
            }
            kind:=r.public?"public":"org only"
            if bytes,sized:=r.size.?;sized {
                x.repos[k]={r.name,fmt.aprintf("%s · %s · %s",kind,base.bytes_text(bytes),state,allocator=a)}
            } else {
                x.repos[k]={r.name,fmt.aprintf("%s, %s",kind,state,allocator=a)}
            }
        }
    }
    if t.status==.Running {
        peers:=make([dynamic]vcs.Peer_Info,a)
        vcs.agent_peers(&t.agent,&peers,a)
        pulls:=make([dynamic]vcs.Pull,a)
        vcs.agent_pulls(&t.agent,&pulls)
        v.peers,v.pulls=peers[:],pulls[:]
        v.addresses=vcs.agent_addresses(&t.agent,a)
        v.peer_lines=make([]Kai_Line,len(peers),a)
        for p,k in peers {v.peer_lines[k]={fmt.aprintf("%s (%s)",p.device,p.name,allocator=a),"connected"}}
        reach,at:=vcs.agent_reach(&t.agent,a)
        v.online=reach==.Online
        switch reach {
        case .Online: v.reach=fmt.aprintf("Online · %s",at,allocator=a)
        case .Connecting: v.reach="Connecting…"
        case .Local: v.reach="Local network only"
        }
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
    kai_team_open(s,retry=true)
    k:=s.kai.team
    if k==nil || k.status==.Closed {
        if k!=nil && k.why_length>0 {return nil,fmt.tprintf("The Kai state of the store is not open: %s",string(k.why[:k.why_length]))}
        return nil,"The Kai state of the store is not open: start the editor with a store this user may write"
    }
    k.team.why=""
    return &k.team,""
}

// --- Pulling a repository into a folder ---

// Pulls a repository of org into folder, which must be empty, not there yet,
// or a workspace a pull of it left. "" or why it does not start.
kai_clone_start :: proc(s:^Session,org:vcs.Org_Id,repo:vcs.Repo_Id,name,folder:string) -> string {
    t:=s.kai.team
    c:=&t.clone
    if c.state==.Pulling {return fmt.tprintf("%s is being pulled: wait for it, or cancel it",string(c.name[:c.name_length]))}
    if folder=="" {return "Choose where the project goes"}
    kai_clone_cancel(s)
    if message:=kai_agent_start(s);message!="" {return message}
    c.org,c.repo=org,repo
    c.folder_length=copy(c.folder[:],folder)
    c.name_length=copy(c.name[:],name)
    t.team.why=""
    if ka.project_clone(&c.project,&t.team,folder,&s.store,org,repo,kai_types(s))!=.None {
        // project_clone closed what it opened: no lock is held.
        c.state=.Failed
        c.why_length=copy(c.why[:],t.team.why!=""?t.team.why:"the folder could not be made a workspace")
        return string(c.why[:c.why_length])
    }
    c.state=.Pulling
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
    if c.state!=.Pulling {return}
    t.team.why=""
    _,e:=ka.clone_checkout(&c.project,&t.team)
    #partial switch e {
    case .None:
        kai_clone_end(c,.Done)
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
        kai_clone_end(c,.Failed)
        c.why_length=copy(c.why[:],t.team.why!=""?t.team.why:vcs.error_text(e))
    }
}

// Leaves Pulling for state: the workspace closes and its lock goes, whatever
// the pull came to.
kai_clone_end :: proc(c:^Kai_Clone,state:Kai_Clone_State) {
    if c.state==.Pulling {ka.project_close(&c.project)}
    c.state=state
}

// Stops the pull: its folder stays a workspace a later pull goes on with.
kai_clone_cancel :: proc(s:^Session) {
    t:=s.kai.team
    if t==nil {return}
    kai_clone_end(&t.clone,.Idle)
    t.clone={}
}

// How far the pull is: chunks and bytes the agent took for its repository,
// read directly from the agent without rebuilding the team view.
kai_clone_progress :: proc(t:^Kai_Team) -> (chunks:int,bytes:i64) {
    if t.status==.Running {
        if p,ok:=vcs.agent_pull_of(&t.agent,t.clone.org,t.clone.repo);ok {return p.chunks,p.bytes}
    }
    for p in t.view.pulls {
        if p.org==t.clone.org && p.repo==t.clone.repo {return p.chunks,p.bytes}
    }
    return
}

// What moves with the org's machines now or moved a few seconds ago, read
// from the agent at each call, its texts in allocator: what a pull, a
// publish or derived data sends or takes, by peer, with its speed. None, and
// nothing allocated, while no agent runs or nothing moves.
kai_transfers :: proc(s:^Session,allocator:=context.temp_allocator) -> []vcs.Transfer {
    if s.kai==nil || s.kai.team==nil || s.kai.team.status!=.Running {return nil}
    out:=make([dynamic]vcs.Transfer,allocator)
    vcs.agent_transfers(&s.kai.team.agent,&out,allocator)
    return out[:]
}

// How fast a repository comes now, from every peer it comes from: bytes a second.
kai_pull_speed :: proc(s:^Session,org:vcs.Org_Id,repo:vcs.Repo_Id) -> (bytes_per_second:f64) {
    for x in kai_transfers(s) {
        if x.direction==.Download && x.kind==.Project && x.org==org && x.repo==repo {bytes_per_second+=x.bytes_per_second}
    }
    return
}

// What a transfer moves and with whom ("Uploading Dreamscape to Frama (PC)"),
// and how far it is ("42.3 MB · 8.4 MB/s"), in the temp allocator.
kai_transfer_text :: proc(x:^vcs.Transfer) -> (what,rest:string) {
    label:=x.label
    if x.kind==.Sync {label=fmt.tprintf("the records of %s",x.label) if x.label!="" else "the org's records"}
    peer:=x.peer_name if x.peer_name!="" else "a peer"
    what=fmt.tprintf("%s %s %s %s",x.direction==.Upload?"Uploading":"Downloading",label,x.direction==.Upload?"to":"from",peer)
    speed:=x.active?fmt.tprintf("%s/s",base.bytes_text(i64(x.bytes_per_second))):"idle"
    rest=fmt.tprintf("%s · %s",base.bytes_text(x.bytes),speed)
    if x.direction==.Download && x.left>0 && x.active {rest=fmt.tprintf("%s · %d chunks left",rest,x.left)}
    return
}

// The folder a repository is pulled into: one of the location named after it.
// If an unrelated folder of that name already exists on disk (including
// case-insensitive matches on Windows/macOS), picks <name>-2, <name>-3, ...
kai_clone_folder :: proc(s:^Session,org:vcs.Org_Id,repo:vcs.Repo_Id,name:string) -> string {
    p:=s.projects
    if p==nil {return ""}
    location:=strings.trim_space(string(p.location[:p.location_length]))
    if location=="" || !vcs.repo_name_valid(name) {return ""}
    same_repo :: proc(s:^Session,folder:string,org:vcs.Org_Id,repo:vcs.Repo_Id) -> bool {
        if !ka.project_exists(folder) || s.kai==nil || s.kai.team==nil || s.kai.team.status==.Closed {return false}
        local,_,_,_,ok:=vcs.workspace_working_info(&s.store,folder)
        if !ok {return false}
        l,linked:=vcs.team_link_of(&s.kai.team.team,local)
        return linked && l.org==org && l.repo==repo
    }
    candidate:=project.path(location,name,allocator=context.temp_allocator)
    if !os.exists(candidate) || same_repo(s,candidate,org,repo) {return candidate}
    for n in 2..=64 {
        alt:=project.path(location,fmt.tprintf("%s-%d",name,n),allocator=context.temp_allocator)
        if !os.exists(alt) || same_repo(s,alt,org,repo) {return alt}
    }
    return candidate
}
