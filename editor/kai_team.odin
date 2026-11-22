package editor

import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "mirai:cook/cache"
import ka "mirai:cook/kai"
import vcs "mirai:kai"
import net "mirai:net"
import "mirai:platform"
import "mirai:std/blake3"
import "mirai:store"

// The team of the project from the editor: the machine of its store (its
// user, its orgs and their logs) and the machine's runner, which the editor
// owns while it is open. The runner runs in a thread of the editor; when a
// `mirai kai agent` or another editor runs it for the store, the editor
// reaches that one instead. Either way the editor talks to it through its
// control channel (kai/control.odin), and what the editor's machine writes
// tells it. The runner starts once the machine has a user or an org, or when
// a pairing starts. What the tab shows of the team is read again into an
// arena when the machine's refs, the logs or the peers change, which a poll
// looks at every KAI_TEAM_POLL seconds; a frame that changes nothing reads
// nothing. A change of the org's scopes or keyrings routes the workspace's
// snapshots again (ka.project_route).

KAI_TEAM_POLL :: 0.5   // seconds between looks at the runner, the pairing and the logs
KAI_RUNNER_WAIT :: 5.0 // seconds an operation waits for the runner the editor starts
KAI_TEXT :: 256        // bytes of a text the editor keeps of the runner

Kai_Runner_State :: enum u8 {Starting,Running,Elsewhere,Failed}

// The runner of the machine in a thread of the editor.
Kai_Runner :: struct {
    thread:^thread.Thread,
    root:string,   // of the store, in the heap
    loopback:bool, // on 127.0.0.1 alone, without beacons or a mapping of the router: tests
    stop:bool,
    state:Kai_Runner_State,
    why:[KAI_TEXT]u8, // Failed: what failed and how to fix it
    why_length:int,
}

// What the Kai tab shows: the working copy and the log, the proposals of the
// project, or the team.
Kai_Tab :: enum u8 {Changes,Proposals,Team}

// A dialog of the tab: the recovery key shown once, rotating it, or a pairing
// request to answer.
Kai_Dialog :: enum u8 {None,Recovery,Rotate,Pair}

Kai_Peer :: struct {
    who:string,  // <handle>/<device>, or a node
    org:string,
    rung:string, // how it is reached
}

// What the team views show, in the team's arena.
Kai_Team_View :: struct {
    identity:ka.Identity_View,
    orgs:[]ka.Org_View,
    org:int,            // of orgs, the one the project is of; -1 when it is no project of an org
    project:vcs.Log_Id, // of the org
    patterns:[]string,  // of each scope of orgs[org], apart by spaces
    peers:[]Kai_Peer,
    shared:[]ka.Shared_Bookmark,
    proposals:[]ka.Proposal_Row,
    proposal:ka.Proposal_View, // the one open in the Proposals view
    changes:[][]Kai_File,      // what each change of its stack did
    shown:bool,                // proposal read
}

// The pairing request the dialog asks about.
Kai_Pair_Request :: struct {
    mode:vcs.Pair_Mode,
    who:[2*vcs.NAME_MAX+1]u8,
    who_length:int,
    code:[vcs.PAIR_CODE_TEXT]u8,
}

// The texts the team views type.
Kai_Fields :: struct {
    name:[vcs.NAME_MAX]u8,
    name_length:int,
    org:[vcs.NAME_MAX]u8,
    org_length:int,
    ticket:[vcs.TICKET_TEXT]u8, // to join with
    ticket_length:int,
    recovery:[vcs.RECOVERY_TEXT+8]u8,
    recovery_length:int,
    bookmark:[64]u8,
    bookmark_length:int,
    approvals:[4]u8,
    approvals_length:int,
    checks:[128]u8,
    checks_length:int,
    patterns:[256]u8,
    patterns_length:int,
    target:[64]u8,
    target_length:int,
    title:[128]u8,
    title_length:int,
    comment:[1024]u8,
    comment_length:int,
    lines:[16]u8,
    lines_length:int,
    check:[32]u8,
    check_length:int,
    command:[256]u8,
    command_length:int,
    file:int,       // the file of the open proposal's stack a comment hangs on: its index over every change, -1 the proposal
    entity:bool,    // the comment hangs on the entity selected in the scene
    history:bool,   // a new scope keeps earlier epochs readable
    readers:vcs.Role,
}

Kai_Team :: struct {
    machine:vcs.Machine,
    opened:bool,
    control:vcs.Control,
    connected:bool,
    runner:^Kai_Runner,  // this editor's; nil when another process runs it or none runs
    polled:f64,
    signature:store.Hash, // of the machine's refs and logs when the view was read
    peers:[vcs.RUNNER_PEERS]vcs.Runner_Peer_Info,
    peer_count:int,
    published:store.Hash, // of the bookmarks published last
    arena:vmem.Arena,
    view:Kai_Team_View,
    tab:Kai_Tab,
    dialog:Kai_Dialog,
    dialog_scroll:f32,
    proposal:vcs.Log_Id, // open in the Proposals view
    request:Kai_Pair_Request,
    asked:bool,          // a pairing request waits for an answer
    joining:bool,        // this machine joins a pairing: progress says how it goes
    progress:vcs.Pair_Phase,
    progress_code:[vcs.PAIR_CODE_TEXT]u8,
    progress_why:[KAI_TEXT]u8,
    progress_why_length:int,
    ticket:[vcs.TICKET_TEXT]u8, // offered last
    ticket_length:int,
    recovery:[vcs.RECOVERY_TEXT]u8, // shown once, then zeroed
    recovery_length:int,
    refusal:ka.Refusal,  // of the last snapshot or publish; its strings in the heap
    fields:Kai_Fields,
    scroll:[2]f32,
}

// The team, opened with the workspace: the machine of the store, and its
// runner when the machine has a user or an org.
kai_team_open :: proc(s:^Session) {
    st:=s.kai.state
    t:=&st.team
    if t.opened || s.store.root=="" {return}
    if vcs.machine_open(&t.machine,s.store.root)!=.None {
        notify(s,fmt.tprintf("Kai: %s",t.machine.why))
        return
    }
    t.opened=true
    t.fields.readers=.Writer
    t.fields.file=-1
    if t.machine.user!={} || len(t.machine.orgs)>0 {kai_team_connect(s,false)}
    kai_team_read(s)
}

kai_team_close :: proc(s:^Session) {
    t:=&s.kai.state.team
    if t.connected {vcs.control_close(&t.control)}
    kai_runner_end(t)
    if t.opened {vcs.machine_close(&t.machine)}
    vmem.arena_destroy(&t.arena)
    kai_refusal_set(t,{})
    for &b in t.recovery {b=0}
    t^={}
}

// Reaches the runner of the store: the one another process runs, or one this
// editor starts. wait: until it answers, KAI_RUNNER_WAIT seconds at most. ""
// or why it does not.
kai_team_connect :: proc(s:^Session,wait:bool) -> string {
    t:=&s.kai.state.team
    if !t.opened {return "The machine of the store is not open"}
    if t.connected {return ""}
    if t.runner==nil {
        if vcs.control_open(&t.control,t.machine.store.root)==.None {
            kai_team_connected(s)
            return ""
        }
        kai_runner_start(s)
    }
    started:=time.tick_now()
    for {
        r:=t.runner
        if r==nil {return "The Kai runner did not start"}
        switch sync.atomic_load(&r.state) {
        case .Starting:
        case .Running,.Elsewhere:
            if vcs.control_open(&t.control,t.machine.store.root)==.None {
                kai_team_connected(s)
                return ""
            }
            if sync.atomic_load(&r.state)==.Elsewhere && !wait {return t.control.why}
        case .Failed:
            why:=strings.clone(string(r.why[:r.why_length]),context.temp_allocator)
            kai_runner_end(t)
            return fmt.tprintf("The Kai runner does not start: %s",why)
        }
        if !wait || time.duration_seconds(time.tick_since(started))>KAI_RUNNER_WAIT {return "The Kai runner is starting: try again in a moment"}
        time.sleep(10*time.Millisecond)
    }
}

@(private)
kai_team_connected :: proc(s:^Session) {
    t:=&s.kai.state.team
    t.connected=true
    t.machine.changed=vcs.control_machine_changed(&t.control)
    // What the machine wrote before the runner answered: it reads the machine again.
    vcs.control_changed(&t.control,vcs.MACHINE_NAMESPACE,vcs.MACHINE_USER)
    if r:=t.runner;r!=nil && sync.atomic_load(&r.state)==.Elsewhere {kai_runner_end(t)}
    t.signature={}
}

@(private)
kai_runner_start :: proc(s:^Session) {
    t:=&s.kai.state.team
    r:=new(Kai_Runner)
    r.root=strings.clone(t.machine.store.root)
    r.loopback=s.kai.mesh_loopback
    r.thread=thread.create_and_start_with_poly_data(r,kai_runner_run)
    if r.thread==nil {
        delete(r.root)
        free(r)
        return
    }
    t.runner=r
}

// A runner that stopped: its thread joined and freed.
@(private)
kai_runner_end :: proc(t:^Kai_Team) {
    r:=t.runner
    if r==nil {return}
    sync.atomic_store(&r.stop,true)
    thread.join(r.thread)
    thread.destroy(r.thread)
    delete(r.root)
    free(r)
    t.runner=nil
}

// The thread of the runner: its own machine of the store, the runner on it
// until the editor stops it. Elsewhere when another runs for the store.
@(private)
kai_runner_run :: proc(r:^Kai_Runner) {
    defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
    fail :: proc(r:^Kai_Runner,state:Kai_Runner_State,why:string) {
        r.why_length=copy(r.why[:],why)
        sync.atomic_store(&r.state,state)
    }
    m:=new(vcs.Machine)
    defer free(m)
    if vcs.machine_open(m,r.root)!=.None {
        fail(r,.Failed,m.why)
        return
    }
    defer vcs.machine_close(m)
    runner:=new(vcs.Runner)
    defer free(runner)
    desc:=vcs.Runner_Desc{machine=m,beacon=!r.loopback,portmap=!r.loopback,control=true}
    if r.loopback {desc.bind=net.address_loopback(0)}
    if e:=vcs.runner_start(runner,desc);e!=.None {
        fail(r,e==.Locked?.Elsewhere:.Failed,m.why)
        return
    }
    defer vcs.runner_stop(runner)
    addresses:[1]net.Address
    if r.loopback {
        addresses[0]=net.address_loopback(vcs.runner_port(runner))
        runner.desc.addresses=addresses[:]
    }
    sync.atomic_store(&r.state,.Running)
    for !sync.atomic_load(&r.stop) {
        vcs.runner_update(runner,0.02)
        free_all(context.temp_allocator)
    }
}

// Who runs the machine's runner, as the Team view heads with it.
kai_runner_text :: proc(t:^Kai_Team) -> string {
    switch {
    case !t.opened: return "No machine"
    case t.connected && t.runner!=nil: return "This editor runs the mesh"
    case t.connected: return "Another process runs the mesh"
    case t.runner!=nil && sync.atomic_load(&t.runner.state)==.Starting: return "The mesh is starting"
    }
    return "The mesh is off"
}

// Between frames, every KAI_TEAM_POLL seconds: the runner that started, the
// pairing request that came, how a pairing this machine joins goes, the
// peers, and what changed in the machine's refs and logs.
kai_team_poll :: proc(s:^Session) {
    st:=s.kai.state
    t:=&st.team
    if !t.opened {return}
    now:=platform.clock_seconds()
    if now-t.polled<KAI_TEAM_POLL {return}
    t.polled=now
    changed:=false
    if !t.connected && (t.machine.user!={} || len(t.machine.orgs)>0 || t.runner!=nil) {
        changed=kai_team_connect(s,false)=="" || changed
    }
    if t.connected {
        if request,ok,e:=vcs.control_pair_request(&t.control);e==.None {
            kai_pair_asked(s,request,ok)
        } else {
            kai_team_lost(s)
            return
        }
        if t.joining {
            if progress,e:=vcs.control_pair_progress(&t.control);e==.None {
                if progress.phase!=t.progress || string(t.progress_code[:])!=progress.code {changed=true}
                t.progress=progress.phase
                copy(t.progress_code[:],progress.code)
                t.progress_why_length=copy(t.progress_why[:],progress.why)
                if progress.phase==.Approved || progress.phase==.Denied || progress.phase==.Failed {t.joining=false}
            }
        }
        list:=make([dynamic]vcs.Runner_Peer_Info,context.temp_allocator)
        if vcs.control_peers(&t.control,&list)==.None {
            count:=min(len(list),len(t.peers))
            if count!=t.peer_count {changed=true}
            for p,i in list[:count] {
                if t.peers[i]!=p {changed=true}
                t.peers[i]=p
            }
            t.peer_count=count
        }
    }
    vcs.machine_reload(&t.machine)
    signature:=kai_team_signature(s)
    if signature!=t.signature {
        t.signature=signature
        if ka.project_route(&st.project)!=.None {notify(s,"Kai: the org's scopes do not read: let the agent fetch the org's logs")}
        changed=true
        kai_team_read(s)
        kai_read(s)
    } else if changed {
        kai_team_read(s)
    }
}

// The pairing request that waits, or none: the dialog asks about it while
// no other dialog is up.
kai_pair_asked :: proc(s:^Session,request:vcs.Pair_Request,waiting:bool) {
    t:=&s.kai.state.team
    if waiting && !t.asked {
        t.request={mode=request.mode}
        who:=vcs.pair_request_who(&t.machine,request)
        t.request.who_length=copy(t.request.who[:],who)
        copy(t.request.code[:],request.code)
        t.asked=true
    }
    if waiting && t.dialog==.None {kai_dialog_open(s,.Pair)}
    if !waiting && t.asked {
        t.asked=false
        if t.dialog==.Pair {kai_dialog_close(s)}
    }
}

// The runner stopped answering: the next poll reaches it again.
@(private)
kai_team_lost :: proc(s:^Session) {
    t:=&s.kai.state.team
    vcs.control_close(&t.control)
    t.connected=false
    t.machine.changed={}
    if t.runner!=nil && sync.atomic_load(&t.runner.state)!=.Starting && sync.atomic_load(&t.runner.state)!=.Running {kai_runner_end(t)}
    kai_team_read(s)
}

// What the machine's refs and logs are now: the user, the orgs, every log and
// the devices' refs of the project. Each ref adds in on its own, in whatever
// order the store lists them.
@(private)
kai_team_signature :: proc(s:^Session) -> (signature:store.Hash) {
    t:=&s.kai.state.team
    m:=&t.machine
    namespaces:[4]string={vcs.MACHINE_NAMESPACE,vcs.USER_NAMESPACE,vcs.LOG_NAMESPACE,""}
    buffer:[len(vcs.REFS_PREFIX)+64]u8
    if project,_,linked:=vcs.machine_project_of(m,s.kai.state.project.workspace.repo.id);linked {namespaces[3]=vcs.refs_namespace(project,&buffer)}
    for namespace in namespaces {
        if namespace=="" {continue}
        refs,e:=store.ref_list(&m.store,namespace,context.temp_allocator)
        if e!=.None {continue}
        for r in refs {
            h:blake3.Hasher
            blake3.init(&h)
            blake3.update(&h,transmute([]u8)namespace)
            blake3.update(&h,transmute([]u8)r.name)
            hash:=r.hash
            blake3.update(&h,hash[:])
            one:=blake3.final(&h)
            for &b,k in signature {b~=one[k]}
        }
    }
    signature[0]~=u8(len(m.orgs))
    return
}

// What the team views show, read again into the arena.
kai_team_read :: proc(s:^Session) {
    st:=s.kai.state
    t:=&st.team
    vmem.arena_destroy(&t.arena)
    t.view={org=-1}
    if !t.opened || vmem.arena_init_growing(&t.arena)!=nil {return}
    a:=vmem.arena_allocator(&t.arena)
    v:=&t.view
    m:=&t.machine
    ka.identity_view(m,&v.identity,a)
    orgs:=make([]ka.Org_View,len(m.orgs),a)
    for id,i in m.orgs {
        if ka.org_view(m,id,&orgs[i],a)!=.None {orgs[i]={id=id}}
    }
    v.orgs=orgs
    peers:=make([]Kai_Peer,t.peer_count,a)
    for p,i in t.peers[:t.peer_count] {
        name:=""
        for o in orgs {if o.id==p.org {name=o.name}}
        peers[i]={who=ka.peer_who(m,p.org,p.dh,a),org=name,rung=vcs.rung_text(p.rung)}
    }
    v.peers=peers
    project,org,e:=ka.project_of(&st.project,m)
    if e!=.None {return}
    v.project=project
    for o,i in orgs {if o.id==org {v.org=i}}
    if v.org>=0 {
        scopes:=orgs[v.org].scopes
        v.patterns=make([]string,len(scopes),a)
        for sc,i in scopes {v.patterns[i]=strings.join(sc.patterns," ",a)}
    }
    shared:=make([dynamic]ka.Shared_Bookmark,a)
    ka.bookmarks_shared(&st.project,m,&shared,a)
    v.shared=shared[:]
    rows:=make([dynamic]ka.Proposal_Row,a)
    ka.proposal_list(&st.project,m,&rows,a)
    v.proposals=rows[:]
    if t.proposal=={} {return}
    if ka.proposal_view(&st.project,m,t.proposal,&v.proposal,a)!=.None {return}
    v.shown=true
    v.changes=make([][]Kai_File,len(v.proposal.stack),a)
    for item,i in v.proposal.stack {
        diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
        if ka.diff(&st.project.workspace,item.revision,&diffs,a)!=.None {continue}
        files:=make([]Kai_File,len(diffs),a)
        for d,k in diffs {files[k]={d.path,kai_mark(d),true}}
        v.changes[i]=files
    }
}

// A added, D removed, M changed, C in conflict.
kai_mark :: proc(d:vcs.Diff) -> u8 {
    switch {
    case d.after.kind==.Conflict: return 'C'
    case d.before.address=={}: return 'A'
    case d.after.address=={}: return 'D'
    }
    return 'M'
}

// The machine to act on, or why there is none.
kai_team_machine :: proc(s:^Session) -> (m:^vcs.Machine,message:string) {
    if s.kai==nil || s.kai.state==nil {return nil,kai_missing(s)}
    t:=&s.kai.state.team
    if !t.opened {return nil,"The machine of the store is not open: start the editor with a store"}
    return &t.machine,""
}

// After a write of the machine: the view and the routing follow at once.
kai_team_wrote :: proc(s:^Session) {
    st:=s.kai.state
    t:=&st.team
    vcs.machine_reload(&t.machine)
    if t.machine.user!={} || len(t.machine.orgs)>0 {kai_team_connect(s,false)}
    t.signature=kai_team_signature(s)
    ka.project_route(&st.project)
    kai_team_read(s)
    kai_read(s)
}

// Publishes the workspace's bookmarks as this device's refs of the project,
// when it is a project of an org and they changed since the last time. A
// publish the scanner refuses is the tab's refusal.
kai_publish :: proc(s:^Session) {
    st:=s.kai.state
    t:=&st.team
    if !t.opened {return}
    if _,_,linked:=vcs.machine_project_of(&t.machine,st.project.workspace.repo.id);!linked {return}
    h:blake3.Hasher
    blake3.init(&h)
    for &b in st.project.workspace.repo.view.bookmarks {
        blake3.update(&h,transmute([]u8)b.name)
        if target,resolved:=vcs.terms_resolved(&b.terms);resolved {blake3.update(&h,target[:])}
    }
    sum:=store.Hash(blake3.final(&h))
    if sum==t.published {return}
    if ka.bookmarks_publish(&st.project,&t.machine)!=.None {
        if refusal:=ka.publish_refusal(&t.machine);refusal.path!="" {kai_refusal_set(t,refusal)} else {notify(s,fmt.tprintf("Kai: %s",t.machine.why))}
        return
    }
    t.published=sum
}

// Keeps what refused a snapshot or a publish, its strings in the heap.
kai_refusal_set :: proc(t:^Kai_Team,refusal:ka.Refusal) {
    delete(t.refusal.text)
    delete(t.refusal.path)
    t.refusal=refusal
    t.refusal.text=refusal.text!=""?strings.clone(refusal.text):""
    t.refusal.path=refusal.path!=""?strings.clone(refusal.path):""
}

// The org the project's cook shares derived data with, while the mesh runs;
// zero otherwise.
kai_mesh_org :: proc(s:^Session) -> vcs.Log_Id {
    if s.kai==nil || s.kai.state==nil {return {}}
    t:=&s.kai.state.team
    if !t.opened || !t.connected {return {}}
    _,org,linked:=vcs.machine_project_of(&t.machine,s.kai.state.project.workspace.repo.id)
    if !linked {return {}}
    return org
}

// What an import shares through the mesh, in its own thread: a machine of the
// store and the cache of the org's project.
Kai_Mesh_Import :: struct {
    machine:vcs.Machine,
    cache:ka.Mesh_Cache,
    open,shared:bool,
}

// The source of a cook in the thread of an import: what peers built, asked on
// a miss; what it builds is published. false while no runner runs.
kai_mesh_import_open :: proc(k:^Kai_Mesh_Import,root:string,org:vcs.Log_Id) -> (source:cache.Source,ok:bool) {
    if org=={} || vcs.machine_open(&k.machine,root)!=.None {return}
    k.open=true
    if ka.mesh_cache_open(&k.cache,&k.machine,org)!=.None {return}
    k.shared=true
    return ka.mesh_source(&k.cache),true
}

kai_mesh_import_close :: proc(k:^Kai_Mesh_Import) {
    if k.shared {ka.mesh_cache_close(&k.cache)}
    if k.open {vcs.machine_close(&k.machine)}
    k^={}
}

// Shows the dialog of the tab.
kai_dialog_open :: proc(s:^Session,dialog:Kai_Dialog) {
    t:=&s.kai.state.team
    t.dialog,t.dialog_scroll=dialog,0
    if s.gui!=nil {s.gui.modal=.Kai}
}

// Closes it; the recovery key it showed is gone.
kai_dialog_close :: proc(s:^Session) {
    if s.kai!=nil && s.kai.state!=nil {
        t:=&s.kai.state.team
        for &b in t.recovery {b=0}
        t.recovery_length=0
        for &b in t.fields.recovery {b=0}
        t.fields.recovery_length=0
        t.dialog=.None
    }
    if s.gui!=nil && s.gui.modal==.Kai {s.gui.modal=.None}
}
