package kai

import "core:slice"
import "core:strings"
import "mirai:store"

// What a server keeps of derived data: every key its writers publish, until
// the bytes of their outputs pass its quota; then the oldest records go first
// (ddc_quota) and the store's sweep reclaims their objects.

// Drops the derived data of org whose records are oldest until the outputs
// left take at most quota bytes; dropped: the keys removed.
ddc_quota :: proc(s:^store.Store,org:Org_Id,quota:i64) -> (dropped:int,error:Error) {
    ns:[len(DDC_PREFIX)+32]u8
    namespace:=ddc_namespace(org,&ns)
    refs,e:=store.ref_list(s,namespace,context.temp_allocator)
    if e!=.None {return 0,e==.Missing?.None:store_error(e)}
    Held :: struct {name:string,time:i64,bytes:i64}
    held:=make([dynamic]Held,context.temp_allocator)
    total:i64
    records:=make([dynamic][]u8,context.temp_allocator)
    for ref in refs {
        clear(&records)
        if ddc_set_read(s,ref.hash,&records)!=.None {continue}
        item:=Held{name=ref.name}
        for bytes in records {
            d,de:=ddc_record_decode(bytes)
            if de!=.None {continue}
            item.time=max(item.time,d.time)
            item.bytes+=ddc_output_bytes(s,d.output_root)
        }
        total+=item.bytes
        append(&held,item)
    }
    if total<=quota {return 0,.None}
    slice.sort_by(held[:],proc(a,b:Held) -> bool {return a.time<b.time})
    for item in held {
        if total<=quota {break}
        if store.ref_remove(s,namespace,item.name)!=.None {continue}
        total-=item.bytes
        dropped+=1
    }
    return dropped,store_error(store.commit(s))
}

// The bytes of the objects of the output at output_root that are here.
@(private)
ddc_output_bytes :: proc(s:^store.Store,output_root:store.Hash) -> (bytes:i64) {
    bytes=object_bytes(s,output_root)
    objects,_:=ddc_output_get(s,output_root,context.temp_allocator)
    for o in objects {bytes+=object_bytes(s,o)}
    return
}

@(private)
object_bytes :: proc(s:^store.Store,address:store.Hash) -> i64 {
    o,e:=store.object_open(s,address)
    if e!=.None {return 0}
    defer store.object_close(&o)
    return i64(store.object_size(&o))
}

// Writes a prune (repo_prune) at now (ns) into the operation log of every
// repository of s: a sweep that names what store_live names then reclaims
// what only the operations past the retention reached.
store_prune :: proc(s:^store.Store,now:i64) -> Error {
    namespaces,e:=store.ref_namespaces(s,context.temp_allocator)
    if e!=.None {return store_error(e)}
    for namespace in namespaces {
        if !strings.has_prefix(namespace,LOCAL_PREFIX) || len(namespace)!=len(LOCAL_PREFIX)+2*size_of(Repo_Id) {continue}
        id:Repo_Id
        if !hex_parse(namespace[len(LOCAL_PREFIX):],id[:]) {continue}
        r:Repo
        if oe:=repo_open(&r,s,id,{},{},allocator=context.temp_allocator);oe!=.None {
            if oe==.Missing {continue}
            return oe
        }
        pe:=repo_prune(&r,now)
        repo_close(&r)
        if pe!=.None {return pe}
    }
    return store_error(store.commit(s))
}

// What a sweep of s keeps that no ref names directly, since the sweep follows
// refs and the chunks of objects, not the links inside Kai records: the
// operations each repository's log reaches (op_retained) and their views, and
// everything the refs of every other namespace reach (reach.odin): the
// versions of each org, the closures of the changes the views and the shared
// bookmarks name, and every object of the outputs of the derived data kept.
store_live :: proc(s:^store.Store,live:^[dynamic]store.Hash) -> Error {
    namespaces,e:=store.ref_namespaces(s,context.temp_allocator)
    if e!=.None {return store_error(e)}
    roots:=make([dynamic]Walk_Item,context.temp_allocator)
    for namespace in namespaces {
        refs,le:=store.ref_list(s,namespace,context.temp_allocator)
        if le!=.None {continue}
        if !strings.has_prefix(namespace,LOCAL_PREFIX) || len(namespace)!=len(LOCAL_PREFIX)+2*size_of(Repo_Id) {
            for ref in refs {append(&roots,ref_item(s,ref.hash))}
            continue
        }
        heads:=make([dynamic]store.Hash,context.temp_allocator)
        for ref in refs {
            if strings.has_prefix(ref.name,"ws-") {append(&heads,ref.hash)}
        }
        ops:=make([dynamic]store.Hash,context.temp_allocator)
        op_retained(s,heads[:],&ops) or_return
        for address in ops {
            append(live,address)
            o:=op_get_kept(s,address) or_continue
            append(live,o.view)
            v:View
            view_init(&v,context.temp_allocator)
            if view_get(s,o.view,&v)!=.None {continue}
            for h in v.heads {append(&roots,Walk_Item{h,.Change})}
            for x in v.workspaces {append(&roots,Walk_Item{x.revision,.Change})}
            for b in v.bookmarks {
                for r in b.terms.adds {append(&roots,Walk_Item{r,.Change})}
                for r in b.terms.removes {append(&roots,Walk_Item{r,.Change})}
            }
        }
    }
    w:=walk_make(s,false)
    present:=make([dynamic]Walk_Item,context.temp_allocator)
    missing:=make([dynamic]Walk_Item,context.temp_allocator)
    walk_all(&w,roots[:],&present,&missing)
    for x in present {append(live,x.address)}
    return .None
}
