package kai

import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "mirai:store"

// Proposals: the review of a stack of changes before it moves a shared
// bookmark, written as entries of a Proposal_Log that every peer folds alike
// (log.odin) and checks against the org's policy itself. A proposal is opened
// on a target bookmark and revised to stacks of Change_Id -> Revision;
// comments name the change they were made on and follow it across rewrites;
// a verdict binds to a stack's head revision and carries over to a later one
// only when every change makes the same edits (an empty interdiff); a check
// binds to a revision and counts when its author holds the Check right, as a
// writer or under a grant; a land
// moves the bookmark in the Project_Log and names that move.

// --- Writing: the bodies, for a browser that signs them, and the entries ---

proposal_open_body :: proc(project:Log_Id,target,title,text:string) -> (body:[]u8,error:Error) {
    if project=={} || !bookmark_name_valid(target) || len(title)>int(max(u16)) || !utf8.valid_string(title) || !utf8.valid_string(text) {return nil,.Invalid_Argument}
    if size_of(Proposal_Open_Body)+len(target)+len(title)+len(text)>ENTRY_BODY_MAX {return nil,.Too_Large}
    body=body_make(Proposal_Open_Body{project=project,target=u8(len(target)),title=u16(len(title))},transmute([]u8)target,transmute([]u8)title,transmute([]u8)text)
    return body,body==nil?.Out_Of_Memory:.None
}

// A body of Revise: the stack bottom first, each change once.
proposal_revise_body :: proc(stack:[]Stack_Item) -> (body:[]u8,error:Error) {
    if len(stack)==0 || len(stack)>STACK_MAX {return nil,len(stack)==0?.Invalid_Argument:.Too_Large}
    for item,i in stack {
        if item.change=={} || item.revision=={} {return nil,.Invalid_Argument}
        for other in stack[:i] {
            if other.change==item.change {return nil,.Invalid_Argument}
        }
    }
    s:=stack
    body=body_make(Proposal_Revise_Body{count=u16(len(stack))},slice.to_bytes(s))
    return body,body==nil?.Out_Of_Memory:.None
}

// A body of Comment on path of change, or on the whole proposal when change is
// zero; reply_to is the comment it answers, or zero.
proposal_comment_body :: proc(anchor:Anchor,path:string,change:Change_Id,reply_to:store.Hash,text:string) -> (body:[]u8,error:Error) {
    if anchor.kind>max(Anchor_Kind) || !utf8.valid_string(text) {return nil,.Invalid_Argument}
    if (change!={} && !path_valid(path)) || (change=={} && path!="") {return nil,.Invalid_Argument}
    if anchor.kind==.Lines && (anchor.line==0 || anchor.lines==0) {return nil,.Invalid_Argument}
    if size_of(Proposal_Comment_Body)+len(path)+len(text)>ENTRY_BODY_MAX {return nil,.Too_Large}
    a:=Comment_Anchor{kind=anchor.kind,path=u16(len(path)),line=anchor.line,lines=anchor.lines,key=anchor.key,field=anchor.field,change=change}
    body=body_make(Proposal_Comment_Body{reply_to=reply_to,anchor=a},transmute([]u8)path,transmute([]u8)text)
    return body,body==nil?.Out_Of_Memory:.None
}

proposal_verdict_body :: proc(verdict:Verdict_Kind,revision:Revision) -> (body:[]u8,error:Error) {
    if verdict>max(Verdict_Kind) || revision=={} {return nil,.Invalid_Argument}
    body=body_make(Proposal_Verdict_Body{verdict=verdict,revision=revision})
    return body,body==nil?.Out_Of_Memory:.None
}

// A body of Check: what a runner named name found on revision, its log at
// log_root.
proposal_check_body :: proc(revision:Revision,name:string,state:Check_State,log_root:store.Hash) -> (body:[]u8,error:Error) {
    if revision=={} || !name_valid(name) || state>max(Check_State) {return nil,.Invalid_Argument}
    body=body_make(Proposal_Check_Body{revision=revision,state=state,log_root=log_root},transmute([]u8)name)
    return body,body==nil?.Out_Of_Memory:.None
}

// Opens a proposal in l, an empty log: the address of its genesis, the
// proposal's id.
proposal_open :: proc(l:^Log,project:Log_Id,target,title,text:string,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    if len(l.items)>0 {return {},.Invalid_Argument}
    body:=proposal_open_body(project,target,title,text) or_return
    return log_append(l,.Proposal_Open,body,identity,time,author_ctx,org_ctx)
}

proposal_revise :: proc(l:^Log,stack:[]Stack_Item,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    body:=proposal_revise_body(stack) or_return
    return log_append(l,.Proposal_Revise,body,identity,time,author_ctx,org_ctx)
}

proposal_comment :: proc(l:^Log,anchor:Anchor,path:string,change:Change_Id,reply_to:store.Hash,text:string,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    body:=proposal_comment_body(anchor,path,change,reply_to,text) or_return
    return log_append(l,.Proposal_Comment,body,identity,time,author_ctx,org_ctx)
}

proposal_verdict :: proc(l:^Log,verdict:Verdict_Kind,revision:Revision,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    body:=proposal_verdict_body(verdict,revision) or_return
    return log_append(l,.Proposal_Verdict,body,identity,time,author_ctx,org_ctx)
}

proposal_check :: proc(l:^Log,revision:Revision,name:string,state:Check_State,log_root:store.Hash,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    body:=proposal_check_body(revision,name,state,log_root) or_return
    return log_append(l,.Proposal_Check,body,identity,time,author_ctx,org_ctx)
}

proposal_close :: proc(l:^Log,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    return log_append(l,.Proposal_Close,nil,identity,time,author_ctx,org_ctx)
}

proposal_reopen :: proc(l:^Log,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    return log_append(l,.Proposal_Reopen,nil,identity,time,author_ctx,org_ctx)
}

// --- Reading ---

// A stack a valid Revise set: its entry and its items, into the log's bytes.
Proposal_Stack :: struct {
    entry:u32,
    items:[]Stack_Item,
}

// The stacks of the valid Revise entries of f, in the fold's order: the last
// is the current one.
proposal_stacks :: proc(f:^Proposal_Fold,out:^[dynamic]Proposal_Stack) -> Error {
    clear(out)
    for e in f.log.order {
        entry:=&f.log.items[e].entry
        if !f.valid[e] || entry.type!=.Proposal_Revise {continue}
        _,tail,_:=body_head(entry.body,Proposal_Revise_Body)
        if _,a:=append(out,Proposal_Stack{e,slice.reinterpret([]Stack_Item,tail)});a!=nil {return .Out_Of_Memory}
    }
    return .None
}

// The target bookmark of the proposal f folds.
proposal_target :: proc(f:^Proposal_Fold) -> string {
    k:=log_find(f.log,f.log.id)
    if k<0 {return ""}
    b,tail,_:=body_head(f.log.items[k].entry.body,Proposal_Open_Body)
    return string(tail[:b.target])
}

@(private)
stack_revision :: proc(items:[]Stack_Item,change:Change_Id) -> Revision {
    for item in items {
        if item.change==change {return item.revision}
    }
    return {}
}

// Settles f against the store: whether a change of the current stack has a
// conflict, and its approvals counted again with those of an earlier stack
// that carry over to the current one, every change of both making the same
// edits, as a rebase that touched none of their files. A peer settles its
// proposals before it folds the project, whose moves read both.
proposal_settle :: proc(s:^store.Store,f:^Proposal_Fold) -> Error {
    stacks:=make([dynamic]Proposal_Stack,context.temp_allocator)
    proposal_stacks(f,&stacks) or_return
    f.approvals,f.conflicted=0,false
    if len(stacks)==0 {return .None}
    current:=stacks[len(stacks)-1].items
    for item in current {
        c:=change_get(s,item.revision,context.temp_allocator) or_return
        totals:=tree_totals(s,c.tree) or_return
        if totals.conflicts>0 {f.conflicted=true}
    }
    for v in f.verdicts {
        if v.verdict!=.Approve {continue}
        if v.revision==f.revision {
            f.approvals+=1
            continue
        }
        #reverse for st in stacks {
            if st.items[len(st.items)-1].revision!=v.revision {continue}
            same:=stacks_same_edits(s,st.items,current) or_return
            if same {f.approvals+=1}
            break
        }
    }
    return .None
}

// Whether two stacks make the same edits: the same changes in the same order,
// each changing the same files from its first parent the same way.
stacks_same_edits :: proc(s:^store.Store,a,b:[]Stack_Item) -> (same:bool,error:Error) {
    if len(a)!=len(b) {return false,.None}
    edits_a:=make([dynamic]Diff,context.temp_allocator)
    edits_b:=make([dynamic]Diff,context.temp_allocator)
    for i in 0..<len(a) {
        if a[i].change!=b[i].change {return false,.None}
        if a[i].revision==b[i].revision {continue}
        change_edits(s,a[i].revision,&edits_a) or_return
        change_edits(s,b[i].revision,&edits_b) or_return
        if len(edits_a)!=len(edits_b) {return false,.None}
        for x,k in edits_a {
            y:=edits_b[k]
            if x.path!=y.path || x.before.kind!=y.before.kind || x.before.address!=y.before.address || x.after.kind!=y.after.kind || x.after.address!=y.after.address {return false,.None}
        }
    }
    return true,.None
}

// The files the change at revision changes from its first parent, or from no
// files when it has none.
@(private)
change_edits :: proc(s:^store.Store,revision:Revision,out:^[dynamic]Diff) -> Error {
    clear(out)
    c:=change_get(s,revision,context.temp_allocator) or_return
    base:store.Hash
    if len(c.parents)>0 {
        p:=change_get(s,c.parents[0],context.temp_allocator) or_return
        base=p.tree
    }
    return tree_diff(s,base,c.tree,out,context.temp_allocator)
}

// The entry of the file at path in the tree at root.
tree_file :: proc(s:^store.Store,root:store.Hash,path:string) -> (entry:Tree_Entry,found:bool,error:Error) {
    address,rest:=root,path
    entries:=make([dynamic]Tree_Entry,context.temp_allocator)
    for _ in 0..=DEPTH_MAX {
        clear(&entries)
        folder_get(s,address,&entries,nil,context.temp_allocator) or_return
        slash:=strings.index_byte(rest,'/')
        name:=slash<0?rest:rest[:slash]
        k,has:=slice.binary_search_by(entries[:],name,proc(e:Tree_Entry,name:string) -> slice.Ordering {
            return e.name<name?.Less:e.name>name?.Greater:.Equal
        })
        if !has {return {},false,.None}
        e:=entries[k]
        if slash<0 {return e,e.kind==.File || e.kind==.Executable,.None}
        if e.kind!=.Folder {return {},false,.None}
        address,rest=e.address,rest[slash+1:]
    }
    return {},false,.Corrupt
}

// A comment where it hangs on the current stack.
Comment_Place :: struct {
    entry:u32,        // the comment's item in the log
    change:Change_Id, // zero: on the whole proposal
    path:string,      // into the log's bytes
    anchor:Anchor,    // on the current revision of change
    outdated:bool,    // what it named is gone, or its change left the stack
}

// Places every valid comment of f on the current stack: a comment follows its
// change from the revision it was made on (that of the last stack in its causal
// past) to the current one; lines move by a line diff, a structural anchor
// by the first of drivers that knows the file, a file anchor stays while the
// file does.
proposal_reanchor :: proc(s:^store.Store,f:^Proposal_Fold,drivers:[]Driver,out:^[dynamic]Comment_Place) -> Error {
    clear(out)
    stacks:=make([dynamic]Proposal_Stack,context.temp_allocator)
    proposal_stacks(f,&stacks) or_return
    current:=len(stacks)>0?stacks[len(stacks)-1].items:nil
    for e in f.log.order {
        entry:=&f.log.items[e].entry
        if !f.valid[e] || entry.type!=.Proposal_Comment {continue}
        b,tail,_:=body_head(entry.body,Proposal_Comment_Body)
        a:=b.anchor
        place:=Comment_Place{entry=e,change=a.change,path=string(tail[:a.path]),anchor={kind=a.kind,line=a.line,lines=a.lines,key=a.key,field=a.field}}
        if a.change!={} {
            made:Revision
            #reverse for st in stacks {
                if log_before(f.log,int(st.entry),int(e)) {
                    made=stack_revision(st.items,a.change)
                    break
                }
            }
            now:=stack_revision(current,a.change)
            if made=={} || now=={} {
                place.outdated=true
            } else if made!=now {
                moved:=anchor_move(s,made,now,place.path,drivers,&place.anchor) or_return
                place.outdated=!moved
            }
        }
        if _,m:=append(out,place);m!=nil {return .Out_Of_Memory}
    }
    return .None
}

// Moves anchor on the file at path from the revision from to the revision to:
// false when what it named is gone.
@(private)
anchor_move :: proc(s:^store.Store,from,to:Revision,path:string,drivers:[]Driver,anchor:^Anchor) -> (moved:bool,error:Error) {
    a:=change_get(s,from,context.temp_allocator) or_return
    b:=change_get(s,to,context.temp_allocator) or_return
    before,in_before:=tree_file(s,a.tree,path) or_return
    after,in_after:=tree_file(s,b.tree,path) or_return
    if !in_after {return false,.None}
    if anchor.kind==.File || (in_before && before.address==after.address) {return true,.None}
    if !in_before {return false,.None}
    old:=file_bytes(s,before.address,context.temp_allocator) or_return
    new:=file_bytes(s,after.address,context.temp_allocator) or_return
    if anchor.kind==.Lines {return text_anchor(old,new,anchor),.None}
    return drivers_anchor(drivers,old,new,anchor),.None
}

// --- Landing ---

Land_Refusal :: enum u8 {None,Not_Open,Unrevised,Unverified,Conflicts,Approvals,Checks}

land_refusal_text :: proc(r:Land_Refusal) -> string {
    switch r {
    case .None: return "the proposal may land"
    case .Not_Open: return "the proposal is closed or landed: reopen it"
    case .Unrevised: return "the proposal has no stack: revise it with the changes to land"
    case .Unverified: return "an entry of the proposal is not signed by its author: fetch its log again from a peer"
    case .Conflicts: return "a change of the stack has conflicts: resolve them and revise the proposal"
    case .Approvals: return "the target's policy asks for more approvals of the final revision: ask reviewers to approve it"
    case .Checks: return "a check the target's policy requires has not passed on the final revision: run it again"
    }
    return ""
}

// Whether the proposal f folds, settled, meets the org's policy p: no
// conflict, its approvals, and every check p requires passed on the final
// revision.
proposal_policy :: proc(org:^Org_Fold,p:^Org_Policy,f:^Proposal_Fold) -> Land_Refusal {
    if f.conflicted {return .Conflicts}
    if f.approvals<p.approvals {return .Approvals}
    b,_,r,_:=policy_parts(org.log.items[p.entry].entry.body)
    tail_string(&r)
    for _ in 0..<b.checks {
        name:=tail_string(&r)
        passed:=false
        for c in f.checks {
            if c.name==name && c.state==.Passed {passed=true}
        }
        if !passed {return .Checks}
    }
    return .None
}

// Whether f may land on its target: open with a stack, every entry signed by
// its author, no change of the stack with a conflict, and the policy of the
// target met on the final revision. It settles f.
proposal_can_land :: proc(s:^store.Store,f:^Proposal_Fold) -> (refusal:Land_Refusal,error:Error) {
    if f.status!=.Open {return .Not_Open,.None}
    stacks:=make([dynamic]Proposal_Stack,context.temp_allocator)
    proposal_stacks(f,&stacks) or_return
    if len(stacks)==0 || f.revision=={} {return .Unrevised,.None}
    for &item in f.log.items {
        if !entry_verify(item.bytes,&item.entry) {return .Unverified,.None}
    }
    proposal_settle(s,f) or_return
    if f.conflicted {return .Conflicts,.None}
    target:=proposal_target(f)
    for &p in f.org.policies {
        if p.project==f.project && p.bookmark==target {return proposal_policy(f.org,&p,f),.None}
    }
    return .None,.None
}

// Lands f when proposal_can_land allows: a Bookmark_Move in the project's log
// from the target's targets to the final revision, naming the proposal and
// the heads of its log it was checked at, then the proposal's Land naming
// the move. The folds of both logs are then stale.
proposal_land :: proc(s:^store.Store,f:^Proposal_Fold,project:^Project_Fold,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{}) -> (move:store.Hash,refusal:Land_Refusal,error:Error) {
    if project.log.id!=f.project {return {},.None,.Invalid_Argument}
    refusal=proposal_can_land(s,f) or_return
    if refusal!=.None {return}
    target:=proposal_target(f)
    from:=make([dynamic]Revision,context.temp_allocator)
    project_bookmark(project,target,&from)
    if len(from)>CONFLICT_SIDES_MAX {return {},.None,.Too_Large}
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    log_heads(f.log,&heads) or_return
    if len(heads)>ENTRY_PARENTS_MAX {return {},.None,.Too_Large}
    body:=move_body(target,from[:],f.revision,f.log.id,heads[:])
    if body==nil {return {},.None,.Out_Of_Memory}
    move=log_append(project.log,.Bookmark_Move,body,identity,time,author_ctx,org_ctx) or_return
    _=log_append(f.log,.Proposal_Land,body_make(Proposal_Land_Body{revision=f.revision,bookmark_move=move}),identity,time,author_ctx,org_ctx) or_return
    return
}

// The proposal of each move of the project's log l that lands one, folded
// and settled as it was at the heads of its log the move names, appended to
// out: what project_fold checks those moves against. A move whose proposal's
// entries this store lacks gets none and does not hold until they come; one
// whose changes it lacks, the same. Each fold owns its log
// (project_snapshots_destroy).
project_snapshots :: proc(s:^store.Store,l:^Log,org:^Org_Fold,out:^[dynamic]^Proposal_Fold,allocator:=context.allocator) -> Error {
    for &item in l.items {
        if item.entry.type!=.Bookmark_Move {continue}
        b,heads,_,_:=move_parts(item.entry.body)
        if b.proposal=={} {continue}
        full:Log
        log_init(&full,b.proposal,context.temp_allocator)
        if log_open(s,&full,b.proposal,.Proposal)!=.None {continue}
        log_index(&full) or_return
        tips:=make([dynamic]int,context.temp_allocator)
        for h in heads {
            if k:=log_find(&full,h);k>=0 && full.complete[k] {append(&tips,k)}
        }
        if len(tips)!=len(heads) {continue}
        snapshot,se:=new(Log,allocator)
        if se!=nil {return .Out_Of_Memory}
        log_init(snapshot,b.proposal,allocator)
        for &x,i in full.items {
            within:=false
            for t in tips {within||=log_within(&full,i,t)}
            if within {log_add(snapshot,x.bytes,false) or_return}
        }
        pf,pe:=new(Proposal_Fold,allocator)
        if pe!=nil {
            log_destroy(snapshot)
            free(snapshot,allocator)
            return .Out_Of_Memory
        }
        if proposal_fold(pf,snapshot,org,allocator)!=.None || proposal_settle(s,pf)!=.None {
            proposal_fold_destroy(pf)
            free(pf,allocator)
            log_destroy(snapshot)
            free(snapshot,allocator)
            continue
        }
        pf.move=item.address
        if _,ae:=append(out,pf);ae!=nil {return .Out_Of_Memory}
    }
    return .None
}

project_snapshots_destroy :: proc(list:^[dynamic]^Proposal_Fold,allocator:=context.allocator) {
    for pf in list {
        l:=pf.log
        proposal_fold_destroy(pf)
        free(pf,allocator)
        log_destroy(l)
        free(l,allocator)
    }
    clear(list)
}
