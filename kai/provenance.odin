package kai

import "base:runtime"
import "core:slice"
import "core:strings"
import "mirai:store"

// Where what an org serves came from. A ref names any address it likes, and
// the store of a machine holds what every org it serves and every repository
// of it wrote, so an object enters an org's served sets (the members', the
// public and the grants' closures) only from a root that came from the org:
//
//   - a change or a derived data output the org's agent fetched from a peer
//     (received), kept as one sorted object per org under
//     PROVENANCE_NAMESPACE, which no peer is served;
//   - what the operations a repository linked to one of the org's projects
//     keeps reach (written by a workspace of it);
//   - an output this machine published as the org's derived data.
//
// Every change before such a root is the org's too, as its closure is: the
// walk from it is trusted. A root a ref names that is none of these is walked
// as one this machine lacks: it waits until it comes from the org's peers.

PROVENANCE_NAMESPACE :: "kai-local-provenance" // + /<org hex>
PROVENANCE_MAX :: 1<<21                        // roots an org keeps as received; past it a root waits as one not here

Provenance :: struct {
    received:map[store.Hash]struct{}, // changes and outputs the org's agent fetched
    proven:map[store.Hash]struct{},   // the changes and outputs that came from the org, and every change before them
    dirty:bool,                       // received holds roots not written yet
}

provenance_init :: proc(p:^Provenance,allocator:runtime.Allocator) {
    p^={received=make(map[store.Hash]struct{},allocator),proven=make(map[store.Hash]struct{},allocator)}
}

provenance_destroy :: proc(p:^Provenance) {
    delete(p.received)
    delete(p.proven)
    p^={}
}

// Whether the change or output at address came from the org.
provenance_has :: proc(p:^Provenance,address:store.Hash) -> bool {return address in p.proven}

// Reads the roots this store kept as received for org, without those it
// holds no more: what comes back after a sweep comes from wherever it came.
provenance_load :: proc(p:^Provenance,s:^store.Store,org:Log_Id) {
    name:[64]u8
    address,e:=store.ref_get(s,PROVENANCE_NAMESPACE,log_name(org,&name))
    if e!=.None {return}
    bytes,ge:=object_get(s,address,.Provenance,context.temp_allocator)
    if ge!=.None || len(bytes)%size_of(store.Hash)!=0 {return}
    for root in slice.reinterpret([]store.Hash,bytes) {
        if len(p.received)>=PROVENANCE_MAX {break}
        if object_present(s,root) {p.received[root]={}} else {p.dirty=true}
    }
}

// Writes the received roots of org when they changed.
provenance_save :: proc(p:^Provenance,s:^store.Store,org:Log_Id) -> Error {
    if !p.dirty {return .None}
    roots:=make([dynamic]store.Hash,0,len(p.received),context.temp_allocator)
    for root in p.received {append(&roots,root)}
    slice.sort_by(roots[:],hash_less)
    address:=object_put(s,.Provenance,slice.to_bytes(roots[:])) or_return
    name:[64]u8
    if e:=store.ref_set(s,PROVENANCE_NAMESPACE,log_name(org,&name),address);e!=.None {return store_error(e)}
    p.dirty=false
    return .None
}

// Takes address, an object the org's agent fetched from a peer: a change or
// an output is received, and proven with what it reaches.
provenance_received :: proc(p:^Provenance,s:^store.Store,address:store.Hash) {
    kind:=object_kind(s,address)
    if (kind!=.Change && kind!=.DDC_Output) || address in p.received || len(p.received)>=PROVENANCE_MAX {return}
    p.received[address]={}
    p.dirty=true
    provenance_prove(p,s,address,kind)
}

// Builds the proven set again: what the received roots and the operations the
// repositories of org's projects keep reach.
provenance_rebuild :: proc(p:^Provenance,s:^store.Store,org:^Org_Fold) {
    clear(&p.proven)
    for root in p.received {provenance_prove(p,s,root,object_kind(s,root))}
    provenance_local(p,s,org,true)
}

// Proves what the workspaces of repositories linked to org's projects name:
// the views of the operations their logs keep with retained, or of the
// newest operation of each workspace without.
provenance_local :: proc(p:^Provenance,s:^store.Store,org:^Org_Fold,retained:bool) {
    links,e:=store.ref_list(s,MACHINE_NAMESPACE,context.temp_allocator)
    if e!=.None {return}
    for link in links {
        if !strings.has_prefix(link.name,MACHINE_REPO_PREFIX) || org_project_index(org,link.hash)<0 {continue}
        namespace:=strings.concatenate({LOCAL_PREFIX,link.name[len(MACHINE_REPO_PREFIX):]},context.temp_allocator)
        refs,le:=store.ref_list(s,namespace,context.temp_allocator)
        if le!=.None {continue}
        ops:=make([dynamic]store.Hash,context.temp_allocator)
        for ref in refs {
            if strings.has_prefix(ref.name,"ws-") {append(&ops,ref.hash)}
        }
        if retained {
            heads:=slice.clone(ops[:],context.temp_allocator)
            clear(&ops)
            if op_retained(s,heads,&ops)!=.None {continue}
        }
        for address in ops {
            o:=op_get_kept(s,address) or_continue
            v:View
            view_init(&v,context.temp_allocator)
            if view_get(s,o.view,&v)!=.None {continue}
            for h in v.heads {provenance_prove(p,s,h,.Change)}
            for w in v.workspaces {provenance_prove(p,s,w.revision,.Change)}
            for b in v.bookmarks {
                for r in b.terms.adds {provenance_prove(p,s,r,.Change)}
                for r in b.terms.removes {provenance_prove(p,s,r,.Change)}
            }
        }
    }
}

// Proves the object at root of kind and, for a change, every change before
// it down to those already proven; what is not here is proven when it is.
provenance_prove :: proc(p:^Provenance,s:^store.Store,root:store.Hash,kind:Object_Kind) {
    if root=={} || root in p.proven {return}
    if kind==.DDC_Output {
        p.proven[root]={}
        return
    }
    if kind!=.Change {return}
    stack:=make([dynamic]store.Hash,context.temp_allocator)
    append(&stack,root)
    for len(stack)>0 {
        revision:=pop(&stack)
        if revision=={} || revision in p.proven {continue}
        c,e:=change_get(s,revision,context.temp_allocator)
        if e!=.None {continue}
        p.proven[revision]={}
        append(&stack,..c.parents)
    }
}

// The kind of the Kai record at address; None when it is none.
object_kind :: proc(s:^store.Store,address:store.Hash) -> Object_Kind {
    o,e:=store.object_open(s,address)
    if e!=.None {return .None}
    defer store.object_close(&o)
    meta:=store.object_meta(&o)
    if len(meta)<size_of(Meta) {return .None}
    head:=(^Meta)(raw_data(meta))^
    if head.magic!=KAI_MAGIC || head.version!=VERSION {return .None}
    return head.kind
}
