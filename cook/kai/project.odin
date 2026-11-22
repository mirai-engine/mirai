package kai_assets

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:store"
import vcs "mirai:kai"

// A project under Kai: its workspace at the project's root over the store of
// the machine, signed by the identity of this machine, with the asset driver.
// When its repository is a project of an org, its snapshots route the private
// paths of the org's scopes into encrypted overlays (project_route). The
// editor and `mirai kai` go through these procedures alike.

CHANGE_TEXT :: 12               // hex digits a change id is shown with
CHANGE_TEXT_MIN :: 4            // the fewest digits a change is named by

// It must not move once opened: the workspace keeps its drivers, which point
// into it.
Project :: struct {
    types:asset.Types,
    driver:Asset_Driver,
    drivers:[1]vcs.Driver,
    workspace:vcs.Workspace,
    owns_types:bool,
    routing:vcs.Overlay_Routing, // what the workspace's snapshots route by, while routed
    org:vcs.Org_State,
    keyrings:[dynamic]^vcs.Keyring_Fold,
    public_allow:[dynamic]string,
    routed:bool,
}

// What a change in a log shows.
Log_Row :: struct {
    revision:vcs.Revision,
    change:vcs.Change,
    working:bool,     // this workspace's working copy
    conflicts:u32,    // files in conflict in its tree
    bookmarks:[]string,
}

// Whether root holds a workspace.
project_exists :: proc(root:string) -> bool {
    return os.exists(project.path(root,vcs.STATE_FOLDER+"/workspace",allocator=context.temp_allocator))
}

@(private)
project_prepare :: proc(p:^Project,types:^asset.Types) -> vcs.Workspace_Options {
    if types==nil {
        asset.types_init(&p.types)
        p.owns_types=true
        p.driver.types=&p.types
    } else {
        p.driver.types=types
    }
    p.drivers[0]=driver(&p.driver)
    return workspace_options(p.drivers[:])
}

// Makes the folder of a project a workspace of a new repository whose first
// change holds its files. types: the asset types documents merge with; nil:
// the engine's.
project_create :: proc(p:^Project,root:string,s:^store.Store,types:^asset.Types=nil,allocator:=context.allocator) -> vcs.Error {
    identity:=identity_load(s) or_return
    options:=project_prepare(p,types)
    if e:=vcs.workspace_create(&p.workspace,root,s,identity,options,allocator);e!=.None {
        project_close(p)
        return e
    }
    return .None
}

// Opens the workspace at the root of a project: Missing when there is none.
project_open :: proc(p:^Project,root:string,s:^store.Store,types:^asset.Types=nil,allocator:=context.allocator) -> vcs.Error {
    if !project_exists(root) {return .Missing}
    identity:=identity_load(s) or_return
    options:=project_prepare(p,types)
    if e:=vcs.workspace_open(&p.workspace,root,s,identity,options,allocator);e!=.None {
        project_close(p)
        return e
    }
    if e:=project_route(p);e!=.None {
        project_close(p)
        return e
    }
    return .None
}

project_close :: proc(p:^Project) {
    route_drop(p)
    if p.workspace.repo.s!=nil || p.workspace.root!="" {vcs.workspace_close(&p.workspace)}
    if p.owns_types {asset.types_destroy(&p.types)}
    p^={}
}

// Snapshots the working copy and records coauthors and agent turns in it:
// those it does not name yet join it, the author excepted.
snapshot_authored :: proc(w:^vcs.Workspace,coauthors:[]vcs.Key,turns:[]vcs.Turn_Ref) -> (report:vcs.Snapshot_Report,error:vcs.Error) {
    report=vcs.workspace_snapshot(w) or_return
    if len(coauthors)==0 && len(turns)==0 {return}
    r:=&w.repo
    c:=vcs.change_get(r.s,report.revision,context.temp_allocator) or_return
    keys:=make([dynamic]vcs.Key,context.temp_allocator)
    refs:=make([dynamic]vcs.Turn_Ref,context.temp_allocator)
    if _,e:=append(&keys,..c.coauthors);e!=nil {return report,.Out_Of_Memory}
    if _,e:=append(&refs,..c.turns);e!=nil {return report,.Out_Of_Memory}
    for k in coauthors {
        if k==r.identity.key || k==c.author || k==({}) || slice.contains(keys[:],k) || len(keys)==vcs.COAUTHORS_MAX {continue}
        if _,e:=append(&keys,k);e!=nil {return report,.Out_Of_Memory}
    }
    for t in turns {
        if t==({}) || slice.contains(refs[:],t) || len(refs)==vcs.TURNS_MAX {continue}
        if _,e:=append(&refs,t);e!=nil {return report,.Out_Of_Memory}
    }
    if len(keys)==len(c.coauthors) && len(refs)==len(c.turns) {return}
    tx:=vcs.tx_begin(r) or_return
    c.coauthors,c.turns=keys[:],refs[:]
    vcs.change_sign_as(&c,&r.identity) or_return
    rewritten:=vcs.change_put(r.s,&c,&r.identity) or_return
    vcs.tx_rewrite(&tx,report.revision,rewritten) or_return
    vcs.tx_commit(&tx,.Snapshot,"record authors") or_return
    report.revision=rewritten
    return
}

// What the project at root is on, as a list of projects shows it: the bookmark
// on its working change, else that change's id; "" when it is no workspace of
// a repository of s.
working_text :: proc(s:^store.Store,root:string,allocator:=context.temp_allocator) -> string {
    if s==nil || s.root=="" {return ""}
    change,bookmark,ok:=vcs.workspace_working_of(s,root)
    if !ok {return ""}
    if bookmark!="" {return strings.clone(bookmark,allocator)}
    return change_text(change,allocator)
}

// A change id as it is shown: its first CHANGE_TEXT hex digits.
change_text :: proc(id:vcs.Change_Id,allocator:=context.temp_allocator) -> string {
    id:=id
    return hex(id[:CHANGE_TEXT/2],allocator)
}

hex :: proc(bytes:[]u8,allocator:=context.temp_allocator) -> string {
    digits:="0123456789abcdef"
    out:=make([]u8,2*len(bytes),allocator)
    for b,k in bytes {
        out[2*k]=digits[b>>4]
        out[2*k+1]=digits[b&15]
    }
    return string(out)
}

// The visible changes, newest first (children before parents): at most limit,
// every one with limit<=0.
visible :: proc(w:^vcs.Workspace,limit:=0,allocator:=context.temp_allocator) -> (revisions:[dynamic]vcs.Revision,error:vcs.Error) {
    r:=&w.repo
    vcs.graph_extend(&r.graph,r.s,r.view.heads[:]) or_return
    seen:=make(map[u32]struct{},allocator=context.temp_allocator)
    stack:=make([dynamic]u32,context.temp_allocator)
    for h in r.view.heads {
        if index,found:=r.graph.lookup[h];found {append(&stack,index)}
    }
    for len(stack)>0 {
        index:=pop(&stack)
        if index in seen {continue}
        seen[index]={}
        for p in vcs.graph_parents(&r.graph,index) {append(&stack,p)}
    }
    order:=make([dynamic]u32,0,len(seen),context.temp_allocator)
    for index in seen {append(&order,index)}
    slice.sort_by(order[:],proc(a,b:u32) -> bool {return a>b})
    revisions=make([dynamic]vcs.Revision,allocator)
    for index in order {
        if limit>0 && len(revisions)==limit {break}
        if _,e:=append(&revisions,r.graph.revisions[index]);e!=nil {return revisions,.Out_Of_Memory}
    }
    return
}

// The change text names: @ the working copy, @- its first parent, a
// bookmark, or a prefix of at least CHANGE_TEXT_MIN hex digits of a change id
// or a revision among the visible changes. Invalid_Argument when it names
// none or several.
revision_find :: proc(w:^vcs.Workspace,text:string) -> (revision:vcs.Revision,error:vcs.Error) {
    r:=&w.repo
    working:=vcs.repo_working(r)
    switch text {
    case "@": return working,working=={} ? .Stale : .None
    case "@-":
        c:=vcs.change_get(r.s,working,context.temp_allocator) or_return
        if len(c.parents)==0 {return {},.Invalid_Argument}
        return c.parents[0],.None
    }
    if b:=vcs.view_bookmark(&r.view,text);b!=nil {
        if value,resolved:=vcs.terms_resolved(&b.terms);resolved {return value,.None}
        return {},.Invalid_Argument
    }
    lower:=strings.to_lower(text,context.temp_allocator)
    if len(lower)<CHANGE_TEXT_MIN {return {},.Invalid_Argument}
    list:=visible(w) or_return
    found:=0
    for v in list {
        index:=r.graph.lookup[v]
        id:=r.graph.change_id[index]
        address:=v
        if strings.has_prefix(hex(id[:]),lower) || strings.has_prefix(hex(address[:]),lower) {
            revision=v
            found+=1
        }
    }
    if found!=1 {return {},.Invalid_Argument}
    return revision,.None
}

// The visible changes, newest first, as a log shows them; their strings in allocator.
log :: proc(w:^vcs.Workspace,limit:int,out:^[dynamic]Log_Row,allocator:=context.temp_allocator) -> vcs.Error {
    r:=&w.repo
    list:=visible(w,limit) or_return
    working:=vcs.repo_working(r)
    for v in list {
        row:=Log_Row{revision=v,working=v==working}
        row.change=vcs.change_get(r.s,v,allocator) or_return
        totals:=vcs.tree_totals(r.s,row.change.tree) or_return
        row.conflicts=totals.conflicts
        names:=make([dynamic]string,allocator)
        for &b in r.view.bookmarks {
            if slice.contains(b.terms.adds[:],v) {append(&names,strings.clone(b.name,allocator))}
        }
        row.bookmarks=names[:]
        if _,e:=append(out,row);e!=nil {return .Out_Of_Memory}
    }
    return .None
}

// What a change did to the files of its parents.
diff :: proc(w:^vcs.Workspace,revision:vcs.Revision,out:^[dynamic]vcs.Diff,allocator:=context.temp_allocator) -> vcs.Error {
    r:=&w.repo
    c:=vcs.change_get(r.s,revision,context.temp_allocator) or_return
    before:=vcs.parents_tree(r,c.parents) or_return
    return vcs.tree_diff(r.s,before,c.tree,out,allocator)
}

// Undoes the newest operation of the repository after a snapshot, and writes
// the working copy as the view after it has it: what files that changed, in
// allocator. Undoing an undo is a redo.
undo :: proc(w:^vcs.Workspace,changed:^[dynamic]string,allocator:=context.temp_allocator) -> (undone:vcs.Operation,error:vcs.Error) {
    r:=&w.repo
    vcs.workspace_snapshot(w) or_return
    undone=vcs.op_get(r.s,r.op,allocator) or_return
    before,working:=w.state.tree,vcs.repo_working(r)
    vcs.op_undo(r,r.op) or_return
    vcs.workspace_update(w) or_return
    vcs.overlay_checkout(w.options.overlay,r.s,w.root,working,vcs.repo_working(r)) or_return
    return undone,files_changed(w,before,changed,allocator)
}

// Gives the working copy the files of another change and writes them, with
// the private files of that change this device reads: what public files
// changed.
restore :: proc(w:^vcs.Workspace,from:vcs.Revision,changed:^[dynamic]string,allocator:=context.temp_allocator) -> vcs.Error {
    r:=&w.repo
    vcs.workspace_snapshot(w) or_return
    before,working:=w.state.tree,vcs.repo_working(r)
    vcs.change_restore(r,working,from) or_return
    vcs.workspace_update(w) or_return
    vcs.overlay_checkout(w.options.overlay,r.s,w.root,working,from) or_return
    return files_changed(w,before,changed,allocator)
}

// A new change on parents (the working copy when none) as the working copy,
// written, with the private files this device reads: what public files that
// changed. With several parents their trees merge, and what does not merge is
// a conflict in its files.
new_change :: proc(w:^vcs.Workspace,parents:[]vcs.Revision,description:string,changed:^[dynamic]string,allocator:=context.temp_allocator) -> (revision:vcs.Revision,error:vcs.Error) {
    vcs.workspace_snapshot(w) or_return
    before:=w.state.tree
    on:=parents
    working:=[1]vcs.Revision{vcs.repo_working(&w.repo)}
    if len(on)==0 {on=working[:]}
    revision=vcs.workspace_new(w,on,description) or_return
    vcs.overlay_checkout(w.options.overlay,w.repo.s,w.root,working[0],revision) or_return
    return revision,files_changed(w,before,changed,allocator)
}

// Splits the change text names by paths after a snapshot, so they are checked
// against what the files hold now: the first keeps the change with the picked
// files, the second the rest; the working copy's files stay as they are. An
// Invalid_Argument says why in refused, in the temp allocator.
split :: proc(w:^vcs.Workspace,change:string,paths:[]string,description:Maybe(string),refused:^string) -> (first,second:vcs.Revision,error:vcs.Error) {
    vcs.workspace_snapshot(w) or_return
    revision,e:=revision_find(w,change)
    if e!=.None {
        refused^=fmt.tprintf("%q names no single visible change: @, @-, a bookmark or a prefix of at least %d digits of a change id",change,CHANGE_TEXT_MIN)
        return {},{},.Invalid_Argument
    }
    return vcs.change_split(&w.repo,revision,paths,description,w.options.overlay,refused)
}

@(private)
files_changed :: proc(w:^vcs.Workspace,before:store.Hash,changed:^[dynamic]string,allocator:runtime.Allocator) -> vcs.Error {
    if changed==nil {return .None}
    diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
    vcs.tree_diff(w.repo.s,before,w.state.tree,&diffs,allocator) or_return
    for d in diffs {
        if _,e:=append(changed,d.path);e!=nil {return .Out_Of_Memory}
    }
    return .None
}

// What the files of a conflict hold: the side of the working copy's first
// parent (ours), the one of the other parent (theirs) and their base, of a
// conflict of two sides; ok false for another one.
conflict_sides :: proc(w:^vcs.Workspace,path:string,allocator:=context.temp_allocator) -> (ours,origin,theirs:[]u8,has_base,ok:bool) {
    for m in w.state.conflicts {
        if m.path!=path {continue}
        t:=vcs.terms_make(vcs.Term,context.temp_allocator)
        if _,e:=vcs.conflict_get(w.repo.s,m.conflict,&t);e!=.None || len(t.adds)!=2 {return}
        read :: proc(s:^store.Store,term:vcs.Term,allocator:runtime.Allocator) -> (bytes:[]u8,ok:bool) {
            if term.address=={} || term.kind==.Folder {return nil,term.address=={}}
            b,e:=vcs.file_bytes(s,term.address,allocator)
            return b,e==.None
        }
        a,b,c:bool
        ours,a=read(w.repo.s,t.adds[0],allocator)
        theirs,b=read(w.repo.s,t.adds[1],allocator)
        origin,c=read(w.repo.s,t.removes[0],allocator)
        return ours,origin,theirs,t.removes[0].address!={},a && b && c
    }
    return
}
