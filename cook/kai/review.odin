package kai_assets

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:std/subprocess"
import "mirai:store"
import vcs "mirai:kai"

// The proposals of a project as its workspace sees them: the stack a
// proposal takes by default (the changes from its target to the working
// copy's parent), comments placed on the current stack by the asset driver,
// what keeps a proposal from landing, and checks run on a working copy of
// its final revision. The entries are written by kai's machine_proposal_*,
// which the CLI and the editor call directly for verdicts, closing and
// landing.

// The changes from through back to the change from (exclusive), along first
// parents, bottom first.
stack_between :: proc(p:^Project,from,through:vcs.Revision,out:^[dynamic]vcs.Stack_Item) -> vcs.Error {
    r:=&p.workspace.repo
    heads:=make([dynamic]vcs.Revision,context.temp_allocator)
    for h in ([2]vcs.Revision{from,through}) {
        if h!={} {append(&heads,h)}
    }
    vcs.graph_extend(&r.graph,r.s,heads[:]) or_return
    at:=through
    for at!={} && len(out)<vcs.STACK_MAX {
        if from!={} && vcs.graph_is_ancestor(&r.graph,at,from) {break}
        c:=vcs.change_get(r.s,at,context.temp_allocator) or_return
        if _,e:=append(out,vcs.Stack_Item{c.id,at});e!=nil {return .Out_Of_Memory}
        if len(c.parents)==0 {break}
        at=c.parents[0]
    }
    slice.reverse(out[:])
    return .None
}

// The change a bookmark of the project's log names, or else the workspace's
// own bookmark of that name; zero when neither has one.
target_revision :: proc(p:^Project,ps:^vcs.Project_State,target:string) -> vcs.Revision {
    targets:=make([dynamic]vcs.Revision,context.temp_allocator)
    vcs.project_bookmark(&ps.fold,target,&targets)
    if len(targets)==1 {return targets[0]}
    if b:=vcs.view_bookmark(&p.workspace.repo.view,target);b!=nil {
        if value,resolved:=vcs.terms_resolved(&b.terms);resolved {return value}
    }
    return {}
}

// The stack of revisions as a proposal names it, or by default the changes
// from target to the working copy's parent, after a snapshot.
@(private)
stack_make :: proc(p:^Project,m:^vcs.Machine,ps:^vcs.Project_State,target:string,revisions:[]vcs.Revision,out:^[dynamic]vcs.Stack_Item) -> vcs.Error {
    w:=&p.workspace
    vcs.workspace_snapshot(w) or_return
    for r in revisions {
        c,e:=vcs.change_get(w.repo.s,r,context.temp_allocator)
        if e!=.None {
            m.why="a change of the stack is not in the store"
            return e
        }
        append(out,vcs.Stack_Item{c.id,r})
    }
    if len(revisions)>0 {return .None}
    from:=target_revision(p,ps,target)
    if from=={} {
        m.why="the target names no bookmark of the project: mirai kai bookmarks move starts it, or name the stack's changes"
        return .Invalid_Argument
    }
    through,e:=revision_find(w,"@-")
    if e!=.None {
        m.why="the working copy has no parent to propose"
        return e
    }
    stack_between(p,from,through,out) or_return
    if len(out)==0 {
        m.why="no change lies between the target and the working copy's parent: mirai kai new records the working copy as one"
        return .Invalid_Argument
    }
    return .None
}

@(private)
project_state :: proc(m:^vcs.Machine,project:vcs.Log_Id,ps:^vcs.Project_State) -> vcs.Error {
    if e:=vcs.project_state_load(&m.store,project,ps,context.temp_allocator);e!=.None {
        m.why="this store lacks the logs of the project or its org: let the agent fetch them"
        return e
    }
    return .None
}

// Opens a proposal on target with the stack of revisions, bottom first, or
// by default the changes from target to the working copy's parent: its id.
proposal_open :: proc(p:^Project,m:^vcs.Machine,target,title,text:string,revisions:[]vcs.Revision) -> (id:vcs.Log_Id,error:vcs.Error) {
    project,_:=project_of(p,m) or_return
    ps:vcs.Project_State
    project_state(m,project,&ps) or_return
    stack:=make([dynamic]vcs.Stack_Item,context.temp_allocator)
    stack_make(p,m,&ps,target,revisions,&stack) or_return
    return vcs.machine_proposal_open(m,project,target,title,text,stack[:])
}

// Revises the proposal to the stack of revisions, or by default to the
// changes from its target to the working copy's parent.
proposal_revise :: proc(p:^Project,m:^vcs.Machine,id:vcs.Log_Id,revisions:[]vcs.Revision) -> vcs.Error {
    project,_:=project_of(p,m) or_return
    ps:vcs.Project_State
    project_state(m,project,&ps) or_return
    f:=vcs.project_state_proposal(&ps,id)
    if f==nil {
        m.why="this store has no such proposal of the project"
        return .Missing
    }
    stack:=make([dynamic]vcs.Stack_Item,context.temp_allocator)
    stack_make(p,m,&ps,vcs.proposal_target(f),revisions,&stack) or_return
    return vcs.machine_proposal_revise(m,project,id,stack[:])
}

// The proposal of the workspace's project text names by a prefix of its id.
proposal_find :: proc(p:^Project,m:^vcs.Machine,text:string) -> (project,id:vcs.Log_Id,error:vcs.Error) {
    project,_=project_of(p,m) or_return
    ps:vcs.Project_State
    project_state(m,project,&ps) or_return
    f,found:=vcs.project_state_proposal_find(&ps,text)
    if found!=1 {
        m.why=found==0?"the project has no proposal of that id: mirai kai proposal list shows them":"several proposals start so: give more of the id"
        return {},{},.Invalid_Argument
    }
    return project,f.log.id,.None
}

// A proposal as a list shows it.
Proposal_Row :: struct {
    id:vcs.Log_Id,
    title,target,opener:string,
    status:vcs.Proposal_Status,
    approvals,comments:int,
}

@(private)
proposal_row :: proc(ps:^vcs.Project_State,f:^vcs.Proposal_Fold,allocator:runtime.Allocator) -> Proposal_Row {
    opener:="?"
    if u:=vcs.org_state_user(&ps.org,f.opener);u!=nil {opener=vcs.user_name(u)}
    return {id=f.log.id,title=strings.clone(vcs.log_title(f.log),allocator),target=strings.clone(vcs.proposal_target(f),allocator),opener=strings.clone(opener,allocator),status=f.status,approvals=f.approvals,comments=f.comments}
}

// The proposals of the workspace's project, in allocator.
proposal_list :: proc(p:^Project,m:^vcs.Machine,out:^[dynamic]Proposal_Row,allocator:=context.temp_allocator) -> vcs.Error {
    project,_:=project_of(p,m) or_return
    ps:vcs.Project_State
    project_state(m,project,&ps) or_return
    for f in ps.proposals {
        if _,e:=append(out,proposal_row(&ps,f,allocator));e!=nil {return .Out_Of_Memory}
    }
    return .None
}

// A change of a proposal's current stack.
Proposal_Item :: struct {
    change:vcs.Change_Id,
    revision:vcs.Revision,
    description:string,
}

// A comment where it hangs on the current stack.
Proposal_Note :: struct {
    address:store.Hash,  // what a reply names
    reply_to:store.Hash,
    author:string,       // <handle>/<device>
    text:string,
    path:string,         // empty: on the whole proposal
    change:vcs.Change_Id,
    anchor:vcs.Anchor,   // on the current revision of change
    outdated:bool,       // what it named is gone, or its change left the stack
}

Proposal_Verdict :: struct {
    user:string,
    verdict:vcs.Verdict_Kind,
    current:bool, // given on the final revision
}

Proposal_View :: struct {
    using row:Proposal_Row,
    text:string,
    stack:[dynamic]Proposal_Item,
    notes:[dynamic]Proposal_Note,
    verdicts:[dynamic]Proposal_Verdict,
    checks:[dynamic]vcs.Proposal_Check,
    refusal:vcs.Land_Refusal,
    blocking:string, // what keeps it from landing, said whole
}

// The proposal of id whole: its stack, its comments placed on the current
// stack, its verdicts and checks, and what keeps it from landing; in
// allocator.
proposal_view :: proc(p:^Project,m:^vcs.Machine,id:vcs.Log_Id,v:^Proposal_View,allocator:=context.temp_allocator) -> vcs.Error {
    project,_:=project_of(p,m) or_return
    ps:vcs.Project_State
    project_state(m,project,&ps) or_return
    f:=vcs.project_state_proposal(&ps,id)
    if f==nil {
        m.why="this store has no such proposal of the project"
        return .Missing
    }
    s:=&m.store
    v^={row=proposal_row(&ps,f,allocator),text=strings.clone(vcs.proposal_text(f.log),allocator)}
    v.stack=make([dynamic]Proposal_Item,allocator)
    v.notes=make([dynamic]Proposal_Note,allocator)
    v.verdicts=make([dynamic]Proposal_Verdict,allocator)
    v.checks=make([dynamic]vcs.Proposal_Check,allocator)
    stacks:=make([dynamic]vcs.Proposal_Stack,context.temp_allocator)
    vcs.proposal_stacks(f,&stacks) or_return
    if len(stacks)>0 {
        for item in stacks[len(stacks)-1].items {
            description:=""
            if c,e:=vcs.change_get(s,item.revision,context.temp_allocator);e==.None {description=c.description}
            append(&v.stack,Proposal_Item{item.change,item.revision,strings.clone(description,allocator)})
        }
    }
    places:=make([dynamic]vcs.Comment_Place,context.temp_allocator)
    if e:=vcs.proposal_reanchor(s,f,p.drivers[:],&places);e!=.None {
        m.why="a change of the stack is not in this store: let the agent fetch it"
        return e
    }
    for place in places {
        item:=&f.log.items[place.entry]
        b,tail,_:=vcs.body_head(item.entry.body,vcs.Proposal_Comment_Body)
        author:="a grant holder"
        if u,_:=vcs.org_state_device(&ps.org,item.entry.author);u!=nil {author=vcs.device_display(&ps.org,item.entry.author)}
        append(&v.notes,Proposal_Note{
            address=item.address,reply_to=b.reply_to,author=strings.clone(author,allocator),text=strings.clone(string(tail[b.anchor.path:]),allocator),
            path=strings.clone(place.path,allocator),change=place.change,anchor=place.anchor,outdated=place.outdated,
        })
    }
    for x in f.verdicts {
        name:="?"
        if u:=vcs.org_state_user(&ps.org,x.user);u!=nil {name=vcs.user_name(u)}
        append(&v.verdicts,Proposal_Verdict{strings.clone(name,allocator),x.verdict,x.revision==f.revision})
    }
    for c in f.checks {append(&v.checks,vcs.Proposal_Check{strings.clone(c.name,allocator),c.state})}
    refusal,e:=vcs.proposal_can_land(s,f)
    if e!=.None {
        refusal=.Unverified
        v.blocking="a change of the stack is not in this store: let the agent fetch it"
    } else if refusal!=.None {
        v.blocking=strings.clone(vcs.land_blocker(&ps.org.fold,f,refusal),allocator)
    }
    v.refusal=refusal
    v.approvals=f.approvals
    return .None
}

// Comments on the proposal: on the whole of it when path is empty, else on
// path at anchor, in the topmost change of the current stack that changes the
// file, or else that has it. reply_to: the comment it answers, by a prefix of
// its address, or empty.
proposal_comment :: proc(p:^Project,m:^vcs.Machine,id:vcs.Log_Id,path:string,anchor:vcs.Anchor,reply_to:string,text:string) -> vcs.Error {
    project,_:=project_of(p,m) or_return
    ps:vcs.Project_State
    project_state(m,project,&ps) or_return
    f:=vcs.project_state_proposal(&ps,id)
    if f==nil {
        m.why="this store has no such proposal of the project"
        return .Missing
    }
    s:=&m.store
    change:vcs.Change_Id
    if path!="" {
        stacks:=make([dynamic]vcs.Proposal_Stack,context.temp_allocator)
        vcs.proposal_stacks(f,&stacks) or_return
        if len(stacks)==0 {
            m.why=vcs.land_refusal_text(.Unrevised)
            return .Invalid_Argument
        }
        items:=stacks[len(stacks)-1].items
        has:vcs.Change_Id
        #reverse for item in items {
            c,e:=vcs.change_get(s,item.revision,context.temp_allocator)
            if e!=.None {
                m.why="a change of the stack is not in this store: let the agent fetch it"
                return e
            }
            _,found,_:=vcs.tree_file(s,c.tree,path)
            if !found {continue}
            if has=={} {has=item.change}
            diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
            before:=vcs.parents_tree(&p.workspace.repo,c.parents) or_return
            vcs.tree_diff(s,before,c.tree,&diffs,context.temp_allocator) or_return
            for d in diffs {
                if d.path==path {change=item.change}
            }
            if change!={} {break}
        }
        if change=={} {change=has}
        if change=={} {
            m.why="no change of the stack has that file: give its path from the project's folder"
            return .Invalid_Argument
        }
    }
    reply:store.Hash
    if reply_to!="" {
        lower:=strings.to_lower(reply_to,context.temp_allocator)
        found:=0
        for &item,i in f.log.items {
            if item.entry.type!=.Proposal_Comment || !f.valid[i] {continue}
            if strings.has_prefix(hex(item.address[:]),lower) {
                reply=item.address
                found+=1
            }
        }
        if found!=1 {
            m.why="no single comment of the proposal has that id: mirai kai proposal show lists them"
            return .Invalid_Argument
        }
    }
    return vcs.machine_proposal_comment(m,project,id,anchor,path,change,reply,text)
}

// Where a check's output goes while it runs.
Check_Output :: struct {
    data:rawptr,
    procedure:proc(data:rawptr,bytes:[]u8),
}

// Runs command in the workspace's folder for the check name and signs what it
// found on the final revision of the proposal of id, whose files the working
// copy must hold: Passed when it exits with 0. Its output, kept as an object
// of the store, is the log the Check names. id zero takes the one open
// proposal whose final revision the working copy holds.
check_run :: proc(p:^Project,m:^vcs.Machine,id:vcs.Log_Id,name:string,command:[]string,output:Check_Output={}) -> (passed:bool,proposal:vcs.Log_Id,error:vcs.Error) {
    project,_:=project_of(p,m) or_return
    w:=&p.workspace
    vcs.workspace_snapshot(w) or_return
    ps:vcs.Project_State
    project_state(m,project,&ps) or_return
    tree:=w.state.tree
    target:^vcs.Proposal_Fold
    found:=0
    for f in ps.proposals {
        if f.status!=.Open || f.revision=={} || (id!={} && f.log.id!=id) {continue}
        c,e:=vcs.change_get(&m.store,f.revision,context.temp_allocator)
        if e!=.None || c.tree!=tree {continue}
        target=f
        found+=1
    }
    if found!=1 {
        switch {
        case id!={}: m.why="the working copy does not hold the proposal's final revision, or it is not open: mirai kai new <its revision> and run the check there"
        case found==0: m.why="no open proposal's final revision is what the working copy holds: mirai kai new <its revision> and run the check there"
        case: m.why="several open proposals hold these files: --proposal names one"
        }
        return false,{},.Invalid_Argument
    }
    process,start_error:=subprocess.start({working_dir=w.root,command=command},pipes=.Merged)
    if start_error!=nil {
        m.why="the command does not start: give a program and its arguments after --"
        return false,{},.Invalid_Argument
    }
    defer subprocess.release(&process)
    log:=make([dynamic]u8,context.temp_allocator)
    buffer:[4096]u8
    for {
        n,open:=subprocess.read(&process,.Stdout,buffer[:])
        if n>0 {
            append(&log,..buffer[:n])
            if output.procedure!=nil {output.procedure(output.data,buffer[:n])}
        }
        if !open {break}
        if n==0 {time.sleep(10*time.Millisecond)}
    }
    state,wait_error:=subprocess.wait(&process)
    passed=wait_error==nil && state.exited && state.exit_code==0
    root,put_error:=store.put(&m.store,log[:])
    if put_error!=.None {
        m.why="the store refused the check's output: give this user access to the store"
        return passed,{},.Io
    }
    proposal=target.log.id
    error=vcs.machine_proposal_check(m,project,proposal,target.revision,name,passed,root)
    return
}
