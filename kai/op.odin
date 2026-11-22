package kai

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "mirai:store"

// The operation log: every change to what a repository shows is an operation
// that points to its parent operations, the view after it and the changes it
// rewrote. One operation is one batch of the store, made visible by one
// commit. Each workspace writes only its own ref (ws-<id hex>) to its newest
// operation in the namespace kai-local-<repo hex>, which no peer is served;
// operations two workspaces wrote apart are merged by the next one that reads
// both. Undo is an operation too: the view it writes takes back what the
// undone one did and keeps what came after it, so an undo can be undone.

Op_Kind :: enum u8 {Snapshot,New,Describe,Rewrite,Merge,Abandon,Restore,Bookmark,Workspace,Import,Undo,Proposal}

Op_Head :: struct #packed {
    magic:u32,
    version:u16,
    kind:Op_Kind,
    parents:u8,
    view:store.Hash,
    undone:store.Hash,  // Undo: the operation it takes back
    workspace:Workspace_Id,
    time:i64,           // ns
    rewrites:u32,
    description:u32,
} // + [parents]store.Hash, [rewrites]Rewrite, description

// A change one operation replaced by another revision, or abandoned (to zero).
Rewrite :: struct #packed {
    from,to:Revision,
}

Operation :: struct {
    kind:Op_Kind,
    parents:[]store.Hash,
    view:store.Hash,
    undone:store.Hash,
    workspace:Workspace_Id,
    time:i64,
    rewrites:[]Rewrite,
    description:string,
}

op_encode :: proc(op:^Operation,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(op.parents)>OP_PARENTS_MAX || len(op.rewrites)>REWRITES_MAX || len(op.description)>DESCRIPTION_MAX {return nil,.Too_Large}
    if op.view=={} || (op.undone!={})!=(op.kind==.Undo) || !utf8.valid_string(op.description) {return nil,.Invalid_Argument}
    w:=writer_make(allocator)
    write_value(&w,Op_Head{magic=KAI_MAGIC,version=VERSION,kind=op.kind,parents=u8(len(op.parents)),view=op.view,undone=op.undone,
        workspace=op.workspace,time=op.time,rewrites=u32(len(op.rewrites)),description=u32(len(op.description))})
    for p in op.parents {write_value(&w,p)}
    for rw in op.rewrites {write_value(&w,rw)}
    write_string(&w,op.description)
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The operation of bytes, checked; its slices point into bytes but parents
// and rewrites, which are in allocator.
op_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (op:Operation,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,Op_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSION || head.kind>max(Op_Kind) {return {},.Corrupt}
    if head.view=={} || (head.undone!={})!=(head.kind==.Undo) || head.rewrites>REWRITES_MAX || head.description>DESCRIPTION_MAX {return {},.Corrupt}
    size:=u64(size_of(Op_Head))+u64(head.parents)*size_of(store.Hash)+u64(head.rewrites)*size_of(Rewrite)+u64(head.description)
    if size!=u64(len(bytes)) {return {},.Corrupt}
    op={kind=head.kind,view=head.view,undone=head.undone,workspace=head.workspace,time=head.time}
    e:runtime.Allocator_Error
    if op.parents,e=make([]store.Hash,head.parents,allocator);e!=nil {return {},.Out_Of_Memory}
    if op.rewrites,e=make([]Rewrite,head.rewrites,allocator);e!=nil {
        delete(op.parents,allocator)
        return {},.Out_Of_Memory
    }
    defer if error!=.None {
        delete(op.parents,allocator)
        delete(op.rewrites,allocator)
    }
    for &p,i in op.parents {
        p=read_value(&r,store.Hash)
        if p=={} || slice.contains(op.parents[:i],p) {return op,.Corrupt}
    }
    for &rw in op.rewrites {
        rw=read_value(&r,Rewrite)
        if rw.from=={} || rw.from==rw.to {return op,.Corrupt}
    }
    op.description=string(read_bytes(&r,int(head.description)))
    if r.short || !utf8.valid_string(op.description) {return op,.Corrupt}
    return op,.None
}

op_get :: proc(s:^store.Store,address:store.Hash,allocator:=context.allocator) -> (op:Operation,error:Error) {
    bytes:=object_get(s,address,.Operation,allocator) or_return
    return op_decode(bytes,allocator)
}

// A repository as one workspace sees it: the operation it stands on and its
// view, and the graph of what that view shows.
Repo :: struct {
    s:^store.Store,
    id:Repo_Id,
    workspace:Workspace_Id, // whose ref this value writes
    identity:Identity,
    merger:Merger,
    op:store.Hash,
    view_address:store.Hash,
    view:View,
    graph:Graph_Index,
    known:[dynamic]store.Hash, // operations other refs named that op descends from
    allocator:runtime.Allocator,
    namespace_bytes:[64]u8,
    namespace:string,
    ref_bytes:[64]u8,
    ref:string,
}

@(private)
repo_names :: proc(r:^Repo) {
    prefix:="kai-local-"
    copy(r.namespace_bytes[:],prefix)
    id:=r.id
    r.namespace=string(r.namespace_bytes[:len(prefix)+len(hex_text(id[:],r.namespace_bytes[len(prefix):]))])
    copy(r.ref_bytes[:],"ws-")
    ws:=r.workspace
    r.ref=string(r.ref_bytes[:3+len(hex_text(ws[:],r.ref_bytes[3:]))])
}

@(private)
repo_init :: proc(r:^Repo,s:^store.Store,id:Repo_Id,workspace:Workspace_Id,identity:Identity,drivers:[]Driver,allocator:runtime.Allocator) {
    r^={s=s,id=id,workspace=workspace,identity=identity,merger={s=s,drivers=drivers},allocator=allocator}
    view_init(&r.view,allocator)
    graph_init(&r.graph,allocator)
    r.known=make([dynamic]store.Hash,allocator)
    repo_names(r)
}

// A new repository in s with one workspace whose change is empty.
repo_create :: proc(r:^Repo,s:^store.Store,identity:Identity,workspace:Workspace_Id,drivers:[]Driver={},allocator:=context.allocator) -> (error:Error) {
    repo_init(r,s,random_id(Repo_Id),workspace,identity,drivers,allocator)
    defer if error!=.None {repo_close(r)}
    tx:=tx_begin(r) or_return
    empty:=tree_empty(s) or_return
    first:=change_create(&tx,nil,empty,"") or_return
    if _,e:=append(&tx.view.heads,first);e!=nil {return .Out_Of_Memory}
    if _,e:=append(&tx.view.workspaces,View_Workspace{workspace,first});e!=nil {return .Out_Of_Memory}
    return tx_commit(&tx,.Workspace,"create the repository",genesis=true)
}

// Opens the repository id as workspace sees it, merging the operations other
// workspaces wrote apart.
repo_open :: proc(r:^Repo,s:^store.Store,id:Repo_Id,workspace:Workspace_Id,identity:Identity,drivers:[]Driver={},allocator:=context.allocator) -> (error:Error) {
    repo_init(r,s,id,workspace,identity,drivers,allocator)
    defer if error!=.None {repo_close(r)}
    return repo_refresh(r)
}

repo_close :: proc(r:^Repo) {
    view_destroy(&r.view)
    graph_destroy(&r.graph)
    delete(r.known)
    r^={}
}

// The working-copy change of this value's workspace.
repo_working :: proc(r:^Repo) -> Revision {return view_workspace(&r.view,r.workspace)}

// Moves to the newest operations of every workspace: one, or the merge of
// those written apart, which this value writes.
repo_refresh :: proc(r:^Repo) -> Error {
    refs,e:=store.ref_list(r.s,r.namespace,context.temp_allocator)
    if e!=.None {return store_error(e)}
    candidates:=make([dynamic]store.Hash,context.temp_allocator)
    for ref in refs {
        if len(ref.name)<3 || ref.name[:3]!="ws-" {continue}
        if ref.hash==r.op || slice.contains(r.known[:],ref.hash) || slice.contains(candidates[:],ref.hash) {continue}
        if _,f:=append(&candidates,ref.hash);f!=nil {return .Out_Of_Memory}
    }
    if r.op!={} {
        if _,f:=append(&candidates,r.op);f!=nil {return .Out_Of_Memory}
    }
    if len(candidates)==0 {return .Missing}
    heads:=op_heads(r.s,candidates[:]) or_return
    for c in candidates {
        if !slice.contains(heads[:],c) && c!=r.op {
            if _,f:=append(&r.known,c);f!=nil {return .Out_Of_Memory}
        }
    }
    if len(heads)==1 {
        if heads[0]==r.op {return .None}
        return repo_load(r,heads[0])
    }
    slice.sort_by(heads[:],hash_less)
    return op_heads_merge(r,heads[:])
}

// The operations among candidates no other one descends from.
@(private)
op_heads :: proc(s:^store.Store,candidates:[]store.Hash) -> (heads:[dynamic]store.Hash,error:Error) {
    heads=make([dynamic]store.Hash,context.temp_allocator)
    for c in candidates {
        below:=false
        for other in candidates {
            if other==c {continue}
            if op_descends(s,other,c) or_return {below=true;break}
        }
        if !below {
            if _,e:=append(&heads,c);e!=nil {return heads,.Out_Of_Memory}
        }
    }
    return heads,.None
}

// Whether op a descends from op b.
@(private)
op_descends :: proc(s:^store.Store,a,b:store.Hash) -> (descends:bool,error:Error) {
    seen:=make(map[store.Hash]struct{},context.temp_allocator)
    stack:=make([dynamic]store.Hash,context.temp_allocator)
    if _,e:=append(&stack,a);e!=nil {return false,.Out_Of_Memory}
    for len(stack)>0 {
        n:=pop(&stack)
        op:=op_get(s,n,context.temp_allocator) or_return
        for p in op.parents {
            if p==b {return true,.None}
            if p in seen {continue}
            seen[p]={}
            if _,e:=append(&stack,p);e!=nil {return false,.Out_Of_Memory}
        }
    }
    return false,.None
}

// The ancestors of op, itself included.
@(private)
op_ancestors :: proc(s:^store.Store,op:store.Hash,out:^map[store.Hash]struct{}) -> Error {
    stack:=make([dynamic]store.Hash,context.temp_allocator)
    if _,e:=append(&stack,op);e!=nil {return .Out_Of_Memory}
    out[op]={}
    for len(stack)>0 {
        n:=pop(&stack)
        o:=op_get(s,n,context.temp_allocator) or_return
        for p in o.parents {
            if p in out {continue}
            out[p]={}
            if _,e:=append(&stack,p);e!=nil {return .Out_Of_Memory}
        }
    }
    return .None
}

// The newest operation that both a and every operation in set descend from,
// walking a's ancestors breadth first.
@(private)
op_base :: proc(s:^store.Store,set:^map[store.Hash]struct{},a:store.Hash) -> (base:store.Hash,error:Error) {
    queue:=make([dynamic]store.Hash,context.temp_allocator)
    seen:=make(map[store.Hash]struct{},context.temp_allocator)
    if _,e:=append(&queue,a);e!=nil {return {},.Out_Of_Memory}
    for at:=0;at<len(queue);at+=1 {
        n:=queue[at]
        if n in set {return n,.None}
        o:=op_get(s,n,context.temp_allocator) or_return
        for p in o.parents {
            if p in seen {continue}
            seen[p]={}
            if _,e:=append(&queue,p);e!=nil {return {},.Out_Of_Memory}
        }
    }
    return {},.Missing
}

// Writes the merge of operations written apart: each view merged into the
// first against their common operation.
@(private)
op_heads_merge :: proc(r:^Repo,heads:[]store.Hash) -> Error {
    first:=op_get(r.s,heads[0],context.temp_allocator) or_return
    merged:View
    view_init(&merged,context.temp_allocator)
    view_get(r.s,first.view,&merged) or_return
    ancestors:=make(map[store.Hash]struct{},context.temp_allocator)
    op_ancestors(r.s,heads[0],&ancestors) or_return
    for h in heads[1:] {
        base_op:=op_base(r.s,&ancestors,h) or_return
        b:=op_get(r.s,base_op,context.temp_allocator) or_return
        o:=op_get(r.s,h,context.temp_allocator) or_return
        base,theirs,out:View
        view_init(&base,context.temp_allocator)
        view_init(&theirs,context.temp_allocator)
        view_init(&out,context.temp_allocator)
        view_get(r.s,b.view,&base) or_return
        view_get(r.s,o.view,&theirs) or_return
        view_merge(&base,&merged,&theirs,&out) or_return
        merged=out
        op_ancestors(r.s,h,&ancestors) or_return
    }
    tx:=Tx{r=r,view=merged}
    tx.rewrites=make([dynamic]Rewrite,context.temp_allocator)
    tx.mapping=make(map[Revision][]Revision,context.temp_allocator)
    return tx_commit(&tx,.Merge,"merge operations written apart",parents=heads)
}

// Stands r on op.
@(private)
repo_load :: proc(r:^Repo,op:store.Hash) -> Error {
    o:=op_get(r.s,op,context.temp_allocator) or_return
    v:View
    view_init(&v,r.allocator)
    if e:=view_get(r.s,o.view,&v);e!=.None {
        view_destroy(&v)
        return e
    }
    view_destroy(&r.view)
    r.view=v
    r.op,r.view_address=op,o.view
    return graph_extend(&r.graph,r.s,r.view.heads[:])
}

// A transaction: the view one operation writes, in the temporary allocator,
// and what it rewrote.
Tx :: struct {
    r:^Repo,
    view:View,
    rewrites:[dynamic]Rewrite,
    mapping:map[Revision][]Revision, // what a rewritten or abandoned change's children move onto
}

tx_begin :: proc(r:^Repo) -> (tx:Tx,error:Error) {
    tx.r=r
    tx.view=view_clone(&r.view,context.temp_allocator) or_return
    tx.rewrites=make([dynamic]Rewrite,context.temp_allocator)
    tx.mapping=make(map[Revision][]Revision,context.temp_allocator)
    return tx,.None
}

// Writes the view and the operation and points this workspace's ref at it:
// one commit of the store.
tx_commit :: proc(tx:^Tx,kind:Op_Kind,description:string,undone:=store.Hash{},parents:[]store.Hash=nil,genesis:=false) -> Error {
    r:=tx.r
    tx_rebase_descendants(tx) or_return
    heads_enforce(tx) or_return
    view_address:=view_put(r.s,&tx.view) or_return
    own:=[1]store.Hash{r.op}
    op:=Operation{kind=kind,view=view_address,undone=undone,workspace=r.workspace,time=time.now()._nsec,rewrites=tx.rewrites[:],description=description}
    op.parents=parents!=nil ? parents : genesis ? nil : own[:]
    bytes:=op_encode(&op,context.temp_allocator) or_return
    address:=object_put(r.s,.Operation,bytes) or_return
    if e:=store.ref_set(r.s,r.namespace,r.ref,address);e!=.None {return store_error(e)}
    v:=view_clone(&tx.view,r.allocator) or_return
    view_destroy(&r.view)
    r.view=v
    r.op,r.view_address=address,view_address
    return graph_extend(&r.graph,r.s,r.view.heads[:])
}

// A new change in the transaction: its revision.
change_create :: proc(tx:^Tx,parents:[]Revision,tree:store.Hash,description:string,id:=Change_Id{},created:=i64(0)) -> (revision:Revision,error:Error) {
    now:=time.now()._nsec
    c:=Change{id=id,tree=tree,author=tx.r.identity.key,created=created,written=now,parents=parents,description=description}
    if c.id==({}) {c.id=random_id(Change_Id)}
    if c.created==0 {c.created=now}
    return change_put(tx.r.s,&c,&tx.r.identity)
}

// Makes identity the author of c, which another key may have signed: that
// one stays among its coauthors, in the temp allocator.
change_sign_as :: proc(c:^Change,identity:^Identity) -> Error {
    if c.author==identity.key {return .None}
    if !slice.contains(c.coauthors,c.author) && len(c.coauthors)<COAUTHORS_MAX {
        coauthors,e:=make([]Key,len(c.coauthors)+1,context.temp_allocator)
        if e!=nil {return .Out_Of_Memory}
        copy(coauthors,c.coauthors)
        coauthors[len(c.coauthors)]=c.author
        c.coauthors=coauthors
    }
    c.author=identity.key
    return .None
}

// The tree of parents merged: one parent's tree, or the merge of all of them
// against their merge bases.
parents_tree :: proc(r:^Repo,parents:[]Revision) -> (tree:store.Hash,error:Error) {
    if len(parents)==0 {return tree_empty(r.s)}
    graph_extend(&r.graph,r.s,parents) or_return
    tree=r.graph.trees[r.graph.lookup[parents[0]]]
    bases:=make([dynamic]Revision,context.temp_allocator)
    for p,k in parents[1:] {
        graph_merge_bases(&r.graph,parents[k],p,&bases) or_return
        base:store.Hash
        if len(bases)>0 {base=r.graph.trees[r.graph.lookup[bases[0]]]}
        tree=tree_merge3(&r.merger,base,tree,r.graph.trees[r.graph.lookup[p]]) or_return
    }
    return
}

// Replaces from by to everywhere the view names it, and records it.
tx_rewrite :: proc(tx:^Tx,from,to:Revision) -> Error {
    if _,e:=append(&tx.rewrites,Rewrite{from,to});e!=nil {return .Out_Of_Memory}
    for &h in tx.view.heads {if h==from {h=to}}
    for &w in tx.view.workspaces {if w.revision==from {w.revision=to}}
    for &b in tx.view.bookmarks {
        for &a in b.terms.adds {if a==from {a=to}}
        for &x in b.terms.removes {if x==from {x=to}}
    }
    moved,e:=make([]Revision,1,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    moved[0]=to
    tx.mapping[from]=moved
    return .None
}

// Rewrites every visible change that descends from a rewritten one onto
// what it was rewritten to, in topological order, its tree rebased.
@(private)
tx_rebase_descendants :: proc(tx:^Tx) -> Error {
    if len(tx.mapping)==0 {return .None}
    r:=tx.r
    g:=&r.graph
    // What the view showed before the transaction.
    graph_extend(g,r.s,r.view.heads[:]) or_return
    visible:=make([]bool,len(g.revisions),context.temp_allocator)
    stack:=make([dynamic]u32,context.temp_allocator)
    for h in r.view.heads {
        index,found:=g.lookup[h]
        if !found {continue}
        visible[index]=true
        if _,e:=append(&stack,index);e!=nil {return .Out_Of_Memory}
    }
    for len(stack)>0 {
        n:=pop(&stack)
        for p in graph_parents(g,n) {
            if visible[p] {continue}
            visible[p]=true
            if _,e:=append(&stack,p);e!=nil {return .Out_Of_Memory}
        }
    }
    count:=len(visible)
    for index in 0..<count {
        if !visible[index] {continue}
        revision:=g.revisions[index]
        if revision in tx.mapping {continue}
        old_parents:=make([dynamic]Revision,context.temp_allocator)
        new_parents:=make([dynamic]Revision,context.temp_allocator)
        moved:=false
        for p in graph_parents(g,u32(index)) {
            pr:=g.revisions[p]
            if _,e:=append(&old_parents,pr);e!=nil {return .Out_Of_Memory}
            if to,found:=tx.mapping[pr];found {
                moved=true
                for t in to {
                    if t!={} && !slice.contains(new_parents[:],t) {
                        if _,e:=append(&new_parents,t);e!=nil {return .Out_Of_Memory}
                    }
                }
                continue
            }
            if !slice.contains(new_parents[:],pr) {
                if _,e:=append(&new_parents,pr);e!=nil {return .Out_Of_Memory}
            }
        }
        if !moved {continue}
        c:=change_get(r.s,revision,context.temp_allocator) or_return
        from_tree:=parents_tree(r,old_parents[:]) or_return
        onto_tree:=parents_tree(r,new_parents[:]) or_return
        tree:=tree_rebase(&r.merger,c.tree,from_tree,onto_tree) or_return
        c.parents=new_parents[:]
        c.tree=tree
        c.written=time.now()._nsec
        change_sign_as(&c,&r.identity) or_return
        rewritten:=change_put(r.s,&c,&r.identity) or_return
        graph_extend(g,r.s,{rewritten}) or_return
        tx_rewrite(tx,revision,rewritten) or_return
    }
    return .None
}

// Keeps as heads only the visible changes no other head descends from.
@(private)
heads_enforce :: proc(tx:^Tx) -> Error {
    g:=&tx.r.graph
    graph_extend(g,tx.r.s,tx.view.heads[:]) or_return
    for w in tx.view.workspaces {
        if !slice.contains(tx.view.heads[:],w.revision) {
            graph_extend(g,tx.r.s,{w.revision}) or_return
            if _,e:=append(&tx.view.heads,w.revision);e!=nil {return .Out_Of_Memory}
        }
    }
    slice.sort_by(tx.view.heads[:],hash_less)
    kept:=make([dynamic]Revision,context.temp_allocator)
    for h,k in tx.view.heads {
        if h=={} || (k>0 && tx.view.heads[k-1]==h) {continue}
        below:=false
        for other in tx.view.heads {
            if other!=h && other!={} && graph_is_ancestor(g,h,other) {below=true;break}
        }
        if !below {
            if _,e:=append(&kept,h);e!=nil {return .Out_Of_Memory}
        }
    }
    clear(&tx.view.heads)
    if _,e:=append(&tx.view.heads,..kept[:]);e!=nil {return .Out_Of_Memory}
    return .None
}

// A new empty change on parents, made this workspace's working copy.
change_new :: proc(r:^Repo,parents:[]Revision,description:="") -> (revision:Revision,error:Error) {
    if len(parents)==0 || len(parents)>PARENTS_MAX {return {},.Invalid_Argument}
    tx:=tx_begin(r) or_return
    tree:=parents_tree(r,parents) or_return
    revision=change_create(&tx,parents,tree,description) or_return
    workspace_point(&tx,r.workspace,revision) or_return
    if _,e:=append(&tx.view.heads,revision);e!=nil {return {},.Out_Of_Memory}
    tx_commit(&tx,.New,"new change") or_return
    return
}

@(private)
workspace_point :: proc(tx:^Tx,id:Workspace_Id,revision:Revision) -> Error {
    for &w in tx.view.workspaces {
        if w.id==id {
            w.revision=revision
            return .None
        }
    }
    if _,e:=append(&tx.view.workspaces,View_Workspace{id,revision});e!=nil {return .Out_Of_Memory}
    return .None
}

// Rewrites revision with another description or tree (zero keeps it): the
// new revision. Its descendants move onto it.
@(private)
change_rewrite :: proc(tx:^Tx,revision:Revision,description:Maybe(string),tree:store.Hash) -> (rewritten:Revision,error:Error) {
    c:=change_get(tx.r.s,revision,context.temp_allocator) or_return
    if d,given:=description.?;given {c.description=d}
    if tree!={} {c.tree=tree}
    c.written=time.now()._nsec
    change_sign_as(&c,&tx.r.identity) or_return
    rewritten=change_put(tx.r.s,&c,&tx.r.identity) or_return
    tx_rewrite(tx,revision,rewritten) or_return
    return
}

change_describe :: proc(r:^Repo,revision:Revision,description:string) -> (rewritten:Revision,error:Error) {
    tx:=tx_begin(r) or_return
    rewritten=change_rewrite(&tx,revision,description,{}) or_return
    tx_commit(&tx,.Describe,"describe change") or_return
    return
}

// Gives revision the tree of another change.
change_restore :: proc(r:^Repo,revision:Revision,from:Revision) -> (rewritten:Revision,error:Error) {
    source:=change_get(r.s,from,context.temp_allocator) or_return
    tx:=tx_begin(r) or_return
    rewritten=change_rewrite(&tx,revision,nil,source.tree) or_return
    tx_commit(&tx,.Restore,"restore change") or_return
    return
}

// Splits revision in two by paths, each a file it added, changed or removed,
// or a folder whose files under it go too. The first keeps its id, created
// time, parents and description (description, when given, replaces it) and
// takes from it only the picked files over its parents' tree; the second, a
// new change on the first with no description, keeps its whole tree, and what
// pointed at revision (children, heads, bookmarks, workspaces) moves onto it.
// Both keep its coauthors and turns, with its author among the coauthors when
// another key signs them. A working copy split this way keeps its files.
// overlay: the private overlays move with what they were written for (the
// first takes its parents', since no private path is picked). An
// Invalid_Argument says why in refused, in the temp allocator.
change_split :: proc(r:^Repo,revision:Revision,paths:[]string,description:Maybe(string)=nil,overlay:^Overlay_Routing=nil,refused:^string=nil) -> (first,second:Revision,error:Error) {
    refuse :: proc(refused:^string,parts:..string) -> Error {
        if refused!=nil {refused^=strings.concatenate(parts,context.temp_allocator)}
        return .Invalid_Argument
    }
    if len(paths)==0 {return {},{},refuse(refused,"no path picked: name the files or folders the first change takes")}
    for p in paths {
        if !path_valid(p) {return {},{},refuse(refused,p,": not a path of the project: relative, with forward slashes, no empty, . or .. part")}
    }
    c:=change_get(r.s,revision,context.temp_allocator) or_return
    base:=parents_tree(r,c.parents) or_return
    diffs:=make([dynamic]Diff,context.temp_allocator)
    tree_diff(r.s,base,c.tree,&diffs,context.temp_allocator) or_return
    picked:=make([]bool,len(diffs),context.temp_allocator)
    for p in paths {
        hit:=false
        for d,k in diffs {
            if d.path==p || (len(d.path)>len(p) && d.path[len(p)]=='/' && strings.has_prefix(d.path,p)) {picked[k],hit=true,true}
        }
        if !hit {return {},{},refuse(refused,p,": the change did not add, change or remove it: pick what its diff lists")}
    }
    if !slice.contains(picked,false) {return {},{},refuse(refused,"every file the change touched is picked: start a new change with new instead")}

    files:=make([dynamic]File,context.temp_allocator)
    tree_files(r.s,base,&files,context.temp_allocator) or_return
    slice.sort_by(files[:],proc(a,b:File) -> bool {return a.path<b.path})
    for d,k in diffs {
        if !picked[k] {continue}
        at,found:=slice.binary_search_by(files[:],d.path,proc(f:File,path:string) -> slice.Ordering {return slice.cmp(f.path,path)})
        switch {
        case d.after.address=={}: if found {ordered_remove(&files,at)}
        case found: files[at]={path=d.path,kind=d.after.kind,address=d.after.address,size=d.after.size}
        case:
            if _,e:=inject_at(&files,at,File{path=d.path,kind=d.after.kind,address=d.after.address,size=d.after.size});e!=nil {return {},{},.Out_Of_Memory}
        }
    }
    if a,b,clash:=names_clash(files[:]);clash {
        return {},{},refuse(refused,a," and ",b,": the first change would hold a file and a folder of one name, or two names that differ only in case: pick both or neither")
    }
    tree:=tree_build(r.s,files[:]) or_return

    now:=time.now()._nsec
    tx:=tx_begin(r) or_return
    head:=c
    change_sign_as(&head,&r.identity) or_return
    head.tree,head.written=tree,now
    if d,given:=description.?;given {head.description=d}
    first=change_put(r.s,&head,&r.identity) or_return
    parents:=[1]Revision{first}
    rest:=Change{id=random_id(Change_Id),tree=c.tree,author=r.identity.key,created=now,written=now,parents=parents[:],coauthors=head.coauthors,turns=c.turns}
    second=change_put(r.s,&rest,&r.identity) or_return
    if _,e:=append(&tx.rewrites,Rewrite{revision,first});e!=nil {return {},{},.Out_Of_Memory}
    tx_rewrite(&tx,revision,second) or_return
    tx_commit(&tx,.Rewrite,"split change") or_return
    if overlay==nil || overlay.org==nil {return}
    for sc in overlay.org.scopes {
        if sc.project!=overlay.project {continue}
        for p in c.parents {
            if _,_,e:=overlay_record_get(r.s,overlay.project,sc.scope,p,context.temp_allocator);e==.Missing {continue}
            overlay_rebase(r.s,&overlay.device.identity,overlay.project,sc.scope,p,first,now) or_return
            break
        }
        for rw in tx.rewrites {
            if rw.to==first || rw.to=={} {continue}
            if _,_,e:=overlay_record_get(r.s,overlay.project,sc.scope,rw.from,context.temp_allocator);e==.Missing {continue}
            overlay_rebase(r.s,&overlay.device.identity,overlay.project,sc.scope,rw.from,rw.to,now) or_return
        }
    }
    return
}

// Two paths of files, sorted, that no tree holds together: a file and a
// folder of one name, or names that differ only in case.
@(private)
names_clash :: proc(files:[]File) -> (a,b:string,clash:bool) {
    held:=make(map[string]string,context.temp_allocator)    // a file's path folded: its path
    folders:=make(map[string]string,context.temp_allocator) // a folder's path folded: its path
    for f in files {
        lower:=strings.to_lower(f.path,context.temp_allocator)
        if other,found:=held[lower];found {return other,f.path,true}
        if other,found:=folders[lower];found {return other,f.path,true}
        for i in 0..<len(lower) {
            if lower[i]!='/' {continue}
            if other,found:=held[lower[:i]];found {return other,f.path,true}
            if other,found:=folders[lower[:i]];found {
                if other!=f.path[:i] {return other,f.path,true}
                continue
            }
            folders[lower[:i]]=f.path[:i]
        }
        held[lower]=f.path
    }
    return
}

// Records tree as this workspace's working copy: what a snapshot writes.
// The same revision when the tree did not change.
change_snapshot :: proc(r:^Repo,tree:store.Hash) -> (revision:Revision,error:Error) {
    working:=repo_working(r)
    if working=={} {return {},.Stale}
    c:=change_get(r.s,working,context.temp_allocator) or_return
    if c.tree==tree {return working,.None}
    tx:=tx_begin(r) or_return
    revision=change_rewrite(&tx,working,nil,tree) or_return
    tx_commit(&tx,.Snapshot,"snapshot working copy") or_return
    return
}

// Moves revision onto other parents.
change_rebase :: proc(r:^Repo,revision:Revision,onto:[]Revision) -> (rewritten:Revision,error:Error) {
    if len(onto)==0 || len(onto)>PARENTS_MAX {return {},.Invalid_Argument}
    c:=change_get(r.s,revision,context.temp_allocator) or_return
    from_tree:=parents_tree(r,c.parents) or_return
    onto_tree:=parents_tree(r,onto) or_return
    tree:=tree_rebase(&r.merger,c.tree,from_tree,onto_tree) or_return
    tx:=tx_begin(r) or_return
    c.parents=onto
    c.tree=tree
    c.written=time.now()._nsec
    change_sign_as(&c,&r.identity) or_return
    rewritten=change_put(r.s,&c,&r.identity) or_return
    tx_rewrite(&tx,revision,rewritten) or_return
    if _,e:=append(&tx.view.heads,rewritten);e!=nil {return {},.Out_Of_Memory}
    tx_commit(&tx,.Rewrite,"rebase change") or_return
    return
}

// Abandons revision: its children move onto its parents, a bookmark on it
// moves to its first parent, and a workspace on it gets a new empty change on
// its parents.
change_abandon :: proc(r:^Repo,revision:Revision) -> Error {
    c:=change_get(r.s,revision,context.temp_allocator) or_return
    tx:=tx_begin(r) or_return
    if _,e:=append(&tx.rewrites,Rewrite{revision,{}});e!=nil {return .Out_Of_Memory}
    parents,e:=slice.clone(c.parents,context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    tx.mapping[revision]=parents
    for &h,k in tx.view.heads {
        if h!=revision {continue}
        ordered_remove(&tx.view.heads,k)
        break
    }
    for p in c.parents {
        if _,f:=append(&tx.view.heads,p);f!=nil {return .Out_Of_Memory}
    }
    for &b in tx.view.bookmarks {
        parent:=len(c.parents)>0 ? c.parents[0] : Revision{}
        for &a in b.terms.adds {if a==revision {a=parent}}
        for &x in b.terms.removes {if x==revision {x=parent}}
        terms_simplify(&b.terms)
    }
    bookmarks_prune(&tx.view)
    for &w in tx.view.workspaces {
        if w.revision!=revision {continue}
        tree:=parents_tree(r,c.parents) or_return
        w.revision=change_create(&tx,c.parents,tree,"") or_return
    }
    return tx_commit(&tx,.Abandon,"abandon change")
}

// Drops bookmarks that came down to nothing.
@(private)
bookmarks_prune :: proc(v:^View) {
    for k:=0;k<len(v.bookmarks); {
        b:=&v.bookmarks[k]
        if value,resolved:=terms_resolved(&b.terms);resolved && value=={} {
            delete(b.name,v.bookmarks.allocator)
            terms_destroy(&b.terms)
            ordered_remove(&v.bookmarks,k)
            continue
        }
        if value,resolved:=terms_resolved(&b.terms);resolved && len(b.terms.adds)>1 {
            clear(&b.terms.adds)
            clear(&b.terms.removes)
            append(&b.terms.adds,value)
        }
        k+=1
    }
}

// Points the bookmark name at revision; zero removes it.
bookmark_set :: proc(r:^Repo,name:string,revision:Revision) -> Error {
    if !bookmark_name_valid(name) {return .Invalid_Argument}
    tx:=tx_begin(r) or_return
    b:=view_bookmark(&tx.view,name)
    switch {
    case b==nil && revision=={}: return .None
    case b==nil:
        single:=[1]Revision{revision}
        bookmark_add(&tx.view,name,single[:],nil) or_return
    case revision=={}:
        for &x,k in tx.view.bookmarks {
            if x.name!=name {continue}
            terms_destroy(&x.terms)
            ordered_remove(&tx.view.bookmarks,k)
            break
        }
    case:
        clear(&b.terms.adds)
        clear(&b.terms.removes)
        if _,e:=append(&b.terms.adds,revision);e!=nil {return .Out_Of_Memory}
    }
    return tx_commit(&tx,.Bookmark,"set bookmark")
}

// Adds a workspace whose working copy is a new empty change on parent.
workspace_add_to_view :: proc(r:^Repo,id:Workspace_Id,parent:Revision) -> (revision:Revision,error:Error) {
    if view_workspace(&r.view,id)!={} {return {},.Invalid_Argument}
    tx:=tx_begin(r) or_return
    parents:=[1]Revision{parent}
    tree:=parents_tree(r,parents[:]) or_return
    revision=change_create(&tx,parents[:],tree,"") or_return
    workspace_point(&tx,id,revision) or_return
    tx_commit(&tx,.Workspace,"add workspace") or_return
    return
}

// Takes back what op did, keeping what came after it: the view of the
// undone operation's parent merged with the current one against op's.
op_undo :: proc(r:^Repo,op:store.Hash) -> Error {
    undone:=op_get(r.s,op,context.temp_allocator) or_return
    if len(undone.parents)==0 {return .Invalid_Argument}
    parent:=op_get(r.s,undone.parents[0],context.temp_allocator) or_return
    base,theirs:View
    view_init(&base,context.temp_allocator)
    view_init(&theirs,context.temp_allocator)
    view_get(r.s,undone.view,&base) or_return
    view_get(r.s,parent.view,&theirs) or_return
    tx:=tx_begin(r) or_return
    ours:=view_clone(&r.view,context.temp_allocator) or_return
    view_merge(&base,&ours,&theirs,&tx.view) or_return
    return tx_commit(&tx,.Undo,"undo operation",undone=op)
}
