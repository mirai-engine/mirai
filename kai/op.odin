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
//
// A prune is an operation whose parents are the one it follows and every
// operation a workspace's ref named when it was written. The log keeps the
// operations the workspaces' refs name and, through parents, those not older
// than the newest prune's time less OP_RETENTION: what only the others reach
// is what the store's sweep reclaims (store_prune). Undo does not cross a
// prune.

Op_Kind :: enum u8 {Snapshot,New,Describe,Rewrite,Merge,Restore,Bookmark,Workspace,Undo,Prune}

OP_RETENTION :: i64(30*24*time.Hour) // ns of operations a prune keeps behind it
LOCAL_PREFIX :: "kai-local-" // + repository id: the refs of its workspaces, which no peer is served
OP_MERGES_PASSED :: 64 // merges of operation heads an undo in a workspace passes to find what it takes back

Op_Head :: struct #packed {
    magic:u32,
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
    write_value(&w,Op_Head{magic=KAI_MAGIC,kind=op.kind,parents=u8(len(op.parents)),view=op.view,undone=op.undone,
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
    if r.short || head.magic!=KAI_MAGIC || head.kind>max(Op_Kind) {return {},.Corrupt}
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
    known:map[store.Hash]struct{}, // what other workspaces' refs name now that op descends from
    allocator:runtime.Allocator,
    namespace_bytes:[64]u8,
    namespace:string,
    ref_bytes:[64]u8,
    ref:string,
    cut_commit:[TEST_ONLY]bool, // cuts the next commit after its objects, before its refs
    overlay:^Overlay_Routing, // routes a snapshot's private paths and carries the records of the overlays onto what an operation rewrites; nil: neither
}

@(private)
repo_names :: proc(r:^Repo) {
    prefix:=LOCAL_PREFIX
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
    r.known=make(map[store.Hash]struct{},allocator)
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
    known:=make([dynamic]store.Hash,context.temp_allocator)
    for ref in refs {
        if len(ref.name)<3 || ref.name[:3]!="ws-" || ref.hash==r.op || slice.contains(candidates[:],ref.hash) {continue}
        if _,f:=append(ref.hash in r.known ? &known : &candidates,ref.hash);f!=nil {return .Out_Of_Memory}
    }
    // Only what the refs name now stays known.
    clear(&r.known)
    for k in known {r.known[k]={}}
    if r.op!={} {
        if _,f:=append(&candidates,r.op);f!=nil {return .Out_Of_Memory}
    }
    if len(candidates)==0 {return .Missing}
    heads:=op_heads(r.s,candidates[:]) or_return
    for c in candidates {
        if !slice.contains(heads[:],c) && c!=r.op {r.known[c]={}}
    }
    if len(heads)==1 {
        if heads[0]==r.op {return .None}
        return repo_load(r,heads[0])
    }
    slice.sort_by(heads[:],hash_less)
    return op_heads_merge(r,heads[:])
}

// The operations among candidates no other one descends from: one walk
// down from all of them at once.
@(private)
op_heads :: proc(s:^store.Store,candidates:[]store.Hash) -> (heads:[dynamic]store.Hash,error:Error) {
    heads=make([dynamic]store.Hash,context.temp_allocator)
    below:=make(map[store.Hash]struct{},context.temp_allocator)
    stack:=make([dynamic]store.Hash,context.temp_allocator)
    if _,e:=append(&stack,..candidates);e!=nil {return heads,.Out_Of_Memory}
    for len(stack)>0 {
        op:=op_get_kept(s,pop(&stack)) or_continue
        for p in op.parents {
            if p in below {continue}
            below[p]={}
            if _,e:=append(&stack,p);e!=nil {return heads,.Out_Of_Memory}
        }
    }
    for c in candidates {
        if c in below {continue}
        if _,e:=append(&heads,c);e!=nil {return heads,.Out_Of_Memory}
    }
    return heads,.None
}

// The ancestors of op, itself included.
@(private)
op_ancestors :: proc(s:^store.Store,op:store.Hash,out:^map[store.Hash]struct{}) -> Error {
    stack:=make([dynamic]store.Hash,context.temp_allocator)
    if _,e:=append(&stack,op);e!=nil {return .Out_Of_Memory}
    out[op]={}
    for len(stack)>0 {
        n:=pop(&stack)
        o:=op_get_kept(s,n) or_continue
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
        o:=op_get_kept(s,n) or_continue
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
    tx.refs=make([dynamic]store.Ref_Set,context.temp_allocator)
    tx.carries=make([dynamic]Rewrite,context.temp_allocator)
    tx.mapping=make(map[Revision][]Revision,context.temp_allocator)
    return tx_commit(&tx,.Merge,"merge operations written apart",parents=heads)
}

// An operation, or none when a prune dropped it and the store reclaimed it:
// the history below a prune ends there.
@(private)
op_get_kept :: proc(s:^store.Store,address:store.Hash) -> (op:Operation,ok:bool) {
    o,e:=op_get(s,address,context.temp_allocator)
    return o,e==.None
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
// what it rewrote and the refs it moves besides its own (the records of
// private overlays that follow what it wrote).
Tx :: struct {
    r:^Repo,
    view:View,
    rewrites:[dynamic]Rewrite,
    mapping:map[Revision][]Revision, // what a rewritten or abandoned change's children move onto
    refs:[dynamic]store.Ref_Set,
    carries:[dynamic]Rewrite, // a revision written (to) and one whose overlay records it takes (from); the first that has one gives them
}

tx_begin :: proc(r:^Repo) -> (tx:Tx,error:Error) {
    tx.r=r
    tx.view=view_clone(&r.view,context.temp_allocator) or_return
    tx.rewrites=make([dynamic]Rewrite,context.temp_allocator)
    tx.mapping=make(map[Revision][]Revision,context.temp_allocator)
    tx.refs=make([dynamic]store.Ref_Set,context.temp_allocator)
    tx.carries=make([dynamic]Rewrite,context.temp_allocator)
    return tx,.None
}

// Writes the view and the operation and points this workspace's ref at it,
// with the transaction's other refs, the records of the overlays carried onto
// what it rewrote among them: one commit of the store.
tx_commit :: proc(tx:^Tx,kind:Op_Kind,description:string,undone:=store.Hash{},parents:[]store.Hash=nil,genesis:=false,at:=i64(0)) -> Error {
    r:=tx.r
    tx_rebase_descendants(tx) or_return
    heads_enforce(tx) or_return
    tx_carry(tx) or_return
    view_address:=view_put(r.s,&tx.view) or_return
    own:=[1]store.Hash{r.op}
    op:=Operation{kind=kind,view=view_address,undone=undone,workspace=r.workspace,time=at!=0?at:time.now()._nsec,rewrites=tx.rewrites[:],description=description}
    op.parents=parents!=nil ? parents : genesis ? nil : own[:]
    bytes:=op_encode(&op,context.temp_allocator) or_return
    address:=object_put(r.s,.Operation,bytes) or_return
    if _,e:=append(&tx.refs,store.Ref_Set{r.namespace,r.ref,address});e!=nil {return .Out_Of_Memory}
    when ODIN_TEST {
        if r.cut_commit[0] {
            r.cut_commit[0]=false
            return .Io
        }
    }
    if e:=store.refs_set(r.s,tx.refs[:]);e!=.None {return store_error(e)}
    v:=view_clone(&tx.view,r.allocator) or_return
    view_destroy(&r.view)
    r.view=v
    r.op,r.view_address=address,view_address
    return graph_extend(&r.graph,r.s,r.view.heads[:])
}

// A new change in the transaction: its revision. It takes the overlay
// records of its first parent that has one.
change_create :: proc(tx:^Tx,parents:[]Revision,tree:store.Hash,description:string,id:=Change_Id{},created:=i64(0)) -> (revision:Revision,error:Error) {
    now:=time.now()._nsec
    c:=Change{id=id,tree=tree,author=tx.r.identity.key,created=created,written=now,parents=parents,description=description}
    if c.id==({}) {c.id=random_id(Change_Id)}
    if c.created==0 {c.created=now}
    revision=change_put(tx.r.s,&c,&tx.r.identity) or_return
    for p in parents {
        if _,e:=append(&tx.carries,Rewrite{p,revision});e!=nil {return {},.Out_Of_Memory}
    }
    return
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

// Replaces from by to everywhere the view names it, and records it: to takes
// the records of from's overlays.
tx_rewrite :: proc(tx:^Tx,from,to:Revision) -> Error {
    if _,e:=append(&tx.rewrites,Rewrite{from,to});e!=nil {return .Out_Of_Memory}
    if _,e:=append(&tx.carries,Rewrite{from,to});e!=nil {return .Out_Of_Memory}
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

// Carries the records of the overlays onto the revisions the transaction
// wrote, in its commit: each takes those of the first revision it carries
// from that has one, unless the operation wrote its own (a snapshot's). A
// record carried is the same sealed tree and objects signed again by this
// device, which needs no key: a device that does not read a scope carries its
// records all the same.
@(private)
tx_carry :: proc(tx:^Tx) -> Error {
    o:=tx.r.overlay
    if o==nil || o.org==nil {return .None}
    now:=time.now()._nsec
    for c in tx.carries {
        for sc in o.org.scopes {
            if sc.project!=o.project || tx_sets_record(tx,o.project,sc.scope,c.to) {continue}
            if _,e:=overlay_rebase(tx.r.s,&o.device.identity,o.project,sc.scope,c.from,c.to,now,&tx.refs);e!=.None && e!=.Missing {return e}
        }
    }
    return .None
}

// Whether the transaction already sets the record of scope at commit.
@(private)
tx_sets_record :: proc(tx:^Tx,project:Log_Id,scope:Scope_Id,commit:Revision) -> bool {
    ns:[len(OVERLAY_PREFIX)+64+1+32]u8
    name:[64]u8
    namespace,text:=overlay_namespace(project,scope,&ns),store.hex(commit,&name)
    for ref in tx.refs {
        if ref.namespace==namespace && ref.name==text {return true}
    }
    return false
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

// A new empty change on parents, made this workspace's working copy. closing,
// when given, describes the working change it leaves, in the same operation:
// a parent that names that change is the change as described.
change_new :: proc(r:^Repo,parents:[]Revision,description:="",closing:Maybe(string)=nil) -> (revision:Revision,error:Error) {
    if len(parents)==0 || len(parents)>PARENTS_MAX {return {},.Invalid_Argument}
    tx:=tx_begin(r) or_return
    on:[PARENTS_MAX]Revision
    copy(on[:],parents)
    parents:=on[:len(parents)]
    if text,given:=closing.?;given {
        working:=repo_working(r)
        if working=={} {return {},.Stale}
        closed:=change_rewrite(&tx,working,text,{}) or_return
        for &p in parents {
            if p==working {p=closed}
        }
    }
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

// Gives revision the tree of another change, and its private files: those of
// from's overlays, or of its parents'.
change_restore :: proc(r:^Repo,revision:Revision,from:Revision) -> (rewritten:Revision,error:Error) {
    source:=change_get(r.s,from,context.temp_allocator) or_return
    tx:=tx_begin(r) or_return
    rewritten=change_rewrite(&tx,revision,nil,source.tree) or_return
    clear(&tx.carries)
    if _,e:=append(&tx.carries,Rewrite{from,rewritten});e!=nil {return {},.Out_Of_Memory}
    for p in source.parents {
        if _,e:=append(&tx.carries,Rewrite{p,rewritten});e!=nil {return {},.Out_Of_Memory}
    }
    tx_commit(&tx,.Restore,"restore change") or_return
    return
}

@(private)
split_refuse :: proc(refused:^string,parts:..string) -> Error {
    if refused!=nil {refused^=strings.concatenate(parts,context.temp_allocator)}
    return .Invalid_Argument
}

// The tree of the first half of a split of c: its parents' tree with what c
// did to the picked paths.
@(private)
split_tree :: proc(r:^Repo,c:^Change,paths:[]string,refused:^string) -> (tree:store.Hash,error:Error) {
    base:=parents_tree(r,c.parents) or_return
    diffs:=make([dynamic]Diff,context.temp_allocator)
    tree_diff(r.s,base,c.tree,&diffs,context.temp_allocator) or_return
    picked:=make([]bool,len(diffs),context.temp_allocator)
    for p in paths {
        hit:=false
        for d,k in diffs {
            if d.path==p || (len(d.path)>len(p) && d.path[len(p)]=='/' && strings.has_prefix(d.path,p)) {picked[k],hit=true,true}
        }
        if !hit {return {},split_refuse(refused,p,": the change did not add, change or remove it: pick what its diff lists")}
    }
    if !slice.contains(picked,false) {return {},split_refuse(refused,"every file the change touched is picked: start a new change with new instead")}

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
            if _,e:=inject_at(&files,at,File{path=d.path,kind=d.after.kind,address=d.after.address,size=d.after.size});e!=nil {return {},.Out_Of_Memory}
        }
    }
    clash:[2]string
    tree,error=tree_build(r.s,files[:],clash=&clash)
    if error==.Invalid_Argument && clash[0]!="" {
        return {},split_refuse(refused,clash[0]," and ",clash[1],": the first change would hold a file and a folder of one name, or two names that differ only in case: pick both or neither")
    }
    return
}

// Splits revision in two by paths, each a file it added, changed or removed,
// or a folder whose files under it go too. The first keeps its id, created
// time, parents and description (description, when given, replaces it) and
// takes from it only the picked files over its parents' tree; the second, a
// new change on the first with no description, keeps its whole tree, and what
// pointed at revision (children, heads, bookmarks, workspaces) moves onto it.
// Both keep its coauthors and attachments, with its author among the
// coauthors when another key signs them. A working copy split this way keeps its files.
// The second takes the change's private files and the first its parents',
// since no private path is picked. An Invalid_Argument says why in refused,
// in the temp allocator.
change_split :: proc(r:^Repo,revision:Revision,paths:[]string,description:Maybe(string)=nil,refused:^string=nil) -> (first,second:Revision,error:Error) {
    if len(paths)==0 {return {},{},split_refuse(refused,"no path picked: name the files or folders the first change takes")}
    for p in paths {
        if !path_valid(p) {return {},{},split_refuse(refused,p,": not a path of the project: relative, with forward slashes, no empty, . or .. part")}
    }
    c:=change_get(r.s,revision,context.temp_allocator) or_return
    tree:=split_tree(r,&c,paths,refused) or_return

    now:=time.now()._nsec
    tx:=tx_begin(r) or_return
    head:=c
    change_sign_as(&head,&r.identity) or_return
    head.tree,head.written=tree,now
    if d,given:=description.?;given {head.description=d}
    first=change_put(r.s,&head,&r.identity) or_return
    parents:=[1]Revision{first}
    rest:=Change{id=random_id(Change_Id),tree=c.tree,author=r.identity.key,created=now,written=now,parents=parents[:],coauthors=head.coauthors,attachments=c.attachments}
    second=change_put(r.s,&rest,&r.identity) or_return
    if _,e:=append(&tx.rewrites,Rewrite{revision,first});e!=nil {return {},{},.Out_Of_Memory}
    for p in c.parents {
        if _,e:=append(&tx.carries,Rewrite{p,first});e!=nil {return {},{},.Out_Of_Memory}
    }
    tx_rewrite(&tx,revision,second) or_return
    tx_commit(&tx,.Rewrite,"split change") or_return
    return
}

// Records tree as this workspace's working copy: what a snapshot writes, with
// the records of plan's private overlays in the same commit. The same
// revision when the tree did not change.
change_snapshot :: proc(r:^Repo,tree:store.Hash,plan:^Overlay_Plan=nil) -> (revision:Revision,error:Error) {
    working:=repo_working(r)
    if working=={} {return {},.Stale}
    c:=change_get(r.s,working,context.temp_allocator) or_return
    if c.tree==tree {
        refs:=make([dynamic]store.Ref_Set,context.temp_allocator)
        overlay_publish(r.overlay,r.s,plan,working,&refs) or_return
        if len(refs)>0 {store_error(store.refs_set(r.s,refs[:])) or_return}
        return working,.None
    }
    tx:=tx_begin(r) or_return
    revision=change_rewrite(&tx,working,nil,tree) or_return
    overlay_publish(r.overlay,r.s,plan,revision,&tx.refs) or_return
    tx_commit(&tx,.Snapshot,"snapshot working copy") or_return
    return
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
// Pruned when op is a prune or came before one the repository stands after;
// Merged when op only merged operations workspaces wrote apart: the engine
// made it and it holds no edit of its own, so what to take back is one of the
// operations under it (op_undo_target).
op_undo :: proc(r:^Repo,op:store.Hash) -> Error {
    undone:=op_get(r.s,op,context.temp_allocator) or_return
    if len(undone.parents)==0 {return .Invalid_Argument}
    if undone.kind==.Prune || (op_pruned(r.s,r.op,op) or_return) {return .Pruned}
    if undone.kind==.Merge {return .Merged}
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

// The operation an undo in r's workspace takes back: the newest one, or,
// past the merges of operation heads above it, the one under each merge that
// this workspace wrote, else the newest of its parents.
op_undo_target :: proc(r:^Repo) -> (op:store.Hash,error:Error) {
    op=r.op
    for _ in 0..<OP_MERGES_PASSED {
        o:=op_get(r.s,op,context.temp_allocator) or_return
        if o.kind!=.Merge || len(o.parents)==0 {return op,.None}
        newest:=i64(min(i64))
        for p in o.parents {
            parent:=op_get(r.s,p,context.temp_allocator) or_return
            if parent.workspace==r.workspace {
                op=p
                break
            }
            if parent.time>newest {op,newest=p,parent.time}
        }
    }
    return {},.Merged
}

// Writes a prune of the repository's operation log at now (ns), after the
// operations of every workspace: none when the newest operation is a prune.
repo_prune :: proc(r:^Repo,now:i64) -> Error {
    repo_refresh(r) or_return
    if newest,e:=op_get(r.s,r.op,context.temp_allocator);e==.None && newest.kind==.Prune {return .None}
    refs,e:=store.ref_list(r.s,r.namespace,context.temp_allocator)
    if e!=.None {return store_error(e)}
    parents:=make([dynamic]store.Hash,context.temp_allocator)
    append(&parents,r.op)
    for ref in refs {
        if len(ref.name)<3 || ref.name[:3]!="ws-" || slice.contains(parents[:],ref.hash) {continue}
        if len(parents)>=OP_PARENTS_MAX {return .Too_Large}
        append(&parents,ref.hash)
    }
    tx:=tx_begin(r) or_return
    return tx_commit(&tx,.Prune,"prune operations older than 30 days",parents=parents[:],at=now)
}

// The operations the log keeps from heads, the operations of the refs of its
// workspaces (see the head of this file).
op_retained :: proc(s:^store.Store,heads:[]store.Hash,out:^[dynamic]store.Hash) -> Error {
    ops:=make(map[store.Hash]Operation,context.temp_allocator)
    stack:=make([dynamic]store.Hash,context.temp_allocator)
    horizon:=min(i64)
    for pass in 0..<2 {
        if _,f:=append(&stack,..heads);f!=nil {return .Out_Of_Memory}
        kept:=make(map[store.Hash]struct{},context.temp_allocator)
        for len(stack)>0 {
            address:=pop(&stack)
            if address in kept {continue}
            o,read:=ops[address]
            if !read {
                e:Error
                if o,e=op_get(s,address,context.temp_allocator);e==.Missing && !slice.contains(heads,address) {continue}
                if e!=.None {return e}
                ops[address]=o
            }
            if pass==1 && o.time<horizon && !slice.contains(heads,address) {continue}
            kept[address]={}
            if o.kind==.Prune {horizon=max(horizon,o.time-OP_RETENTION)}
            if pass==1 {
                if _,f:=append(out,address);f!=nil {return .Out_Of_Memory}
            }
            if _,f:=append(&stack,..o.parents);f!=nil {return .Out_Of_Memory}
        }
    }
    return .None
}

// Whether op is behind a prune from: one from descends from that op descends from.
@(private)
op_pruned :: proc(s:^store.Store,from,op:store.Hash) -> (pruned:bool,error:Error) {
    Item :: struct {op:store.Hash,past:bool}
    stack:=make([dynamic]Item,context.temp_allocator)
    seen:=make(map[Item]struct{},context.temp_allocator)
    if _,f:=append(&stack,Item{from,false});f!=nil {return false,.Out_Of_Memory}
    for len(stack)>0 {
        it:=pop(&stack)
        if it in seen {continue}
        seen[it]={}
        if it.op==op && it.past {return true,.None}
        if it.op==op {continue}
        o:=op_get_kept(s,it.op) or_continue
        past:=it.past || o.kind==.Prune
        for p in o.parents {
            if _,f:=append(&stack,Item{p,past});f!=nil {return false,.Out_Of_Memory}
        }
    }
    return false,.None
}
