package kai

import "core:slice"
import "core:strings"
import "core:time"
import "mirai:store"

// What a ddc node keeps of derived data: every key of an org's DDC namespace
// with every object its outputs list here, dropped least recently used first
// once their bytes pass the node's quota; a key a lookup through this node
// still fetches, whose objects the node is fetching, or whose objects a peer
// asked this node for within DDC_SECONDS (its fetch from here, as long as a
// lookup lasts), is not dropped. A key is used when its newest record
// arrives, when a lookup through this node asks for it and when a peer asks
// this node for its objects. The store's own sweep reclaims what was dropped
// (store_prune with reclaim), so the quota holds on disk once it returns; the
// node names as live besides what its agents fetch and hold back.

DDC_SWEEP_SECONDS :: 60.0 // between two looks at the quota

DDC_USES_MAX :: 1<<14 // keys a ddc node remembers when they were used; past it the oldest is forgotten

@(private)
DDC_Use :: struct {org:Log_Id,key:store.Hash,at:i64} // ns

DDC_Stats :: struct {
    keys:int,             // with a record here
    records:int,
    whole:int,            // keys whose output is all here
    missing:int,          // keys whose output is not
    nondeterministic:int, // keys with more than one output
    lookups_found:int,    // lookups through this node that found an output
    lookups_missing:int,
    bytes:i64,            // of the outputs here
}

// The derived data of an org as the node's store holds it.
runner_ddc_stats :: proc(r:^Runner,org:Log_Id) -> (stats:DDC_Stats) {
    s:=&r.machine.store
    ns:[len(DDC_PREFIX)+64]u8
    refs,e:=store.ref_list(s,ddc_namespace(org,&ns),context.temp_allocator)
    if e!=.None {return}
    records:=make([dynamic][]u8,context.temp_allocator)
    for ref in refs {
        clear(&records)
        if ddc_set_read(s,ref.hash,&records)!=.None {continue}
        stats.keys+=1
        stats.records+=len(records)
        whole:=false
        outputs:=0
        for bytes in records {
            d,de:=ddc_record_decode(bytes)
            if de!=.None {continue}
            outputs+=1
            if size,here:=ddc_output_bytes(s,d.output_root);here {
                whole=true
                stats.bytes+=size
            }
        }
        if whole {stats.whole+=1} else {stats.missing+=1}
        if outputs>1 {stats.nondeterministic+=1}
    }
    stats.lookups_found,stats.lookups_missing=r.ddc_found,r.ddc_missing
    return
}

// The bytes of every object of the output at output_root, when all are whole here.
@(private)
ddc_output_bytes :: proc(s:^store.Store,output_root:store.Hash) -> (bytes:i64,whole:bool) {
    lacking:=make([dynamic]store.Hash,context.temp_allocator)
    objects,e:=ddc_output_lacking(s,output_root,&lacking)
    if e!=.None || len(lacking)>0 {return}
    bytes=object_bytes(s,output_root)
    for o in objects {bytes+=object_bytes(s,o)}
    return bytes,true
}

@(private)
object_bytes :: proc(s:^store.Store,address:store.Hash) -> i64 {
    o,e:=store.object_open(s,address)
    if e!=.None {return 0}
    defer store.object_close(&o)
    return i64(store.object_size(&o))
}

// Marks key of org used now.
@(private)
runner_ddc_touch :: proc(r:^Runner,org:Log_Id,key:store.Hash) {
    now:=time.now()._nsec
    oldest:=-1
    for &u,k in r.ddc_use {
        if u.org==org && u.key==key {
            u.at=now
            return
        }
        if oldest<0 || u.at<r.ddc_use[oldest].at {oldest=k}
    }
    if len(r.ddc_use)<DDC_USES_MAX {
        append(&r.ddc_use,DDC_Use{org,key,now})
    } else {
        r.ddc_use[oldest]=DDC_Use{org,key,now}
    }
}

// Drops the least recently used keys of every org until the outputs fit the
// quota, then has the store's sweep reclaim what no ref holds any more.
@(private)
runner_ddc_quota :: proc(r:^Runner) {
    if r.desc.ddc_quota<=0 || .DDC not_in r.desc.modes || r.now-r.ddc_swept<DDC_SWEEP_SECONDS && r.ddc_swept>0 {return}
    r.ddc_swept=r.now
    s:=&r.machine.store
    Held :: struct {org:Log_Id,key:store.Hash,used:i64,bytes:i64,busy:bool}
    held:=make([dynamic]Held,context.temp_allocator)
    total:i64
    records:=make([dynamic][]u8,context.temp_allocator)
    fetching:=make(map[store.Hash]bool,context.temp_allocator)
    asked:=make(map[store.Hash]i64,context.temp_allocator)
    now:=time.now()._nsec
    for o in r.orgs {
        for f in o.agent.fetches {fetching[f.address]=true}
        for x in o.agent.asked {
            if x.at>0 && x.at>asked[x.address] {asked[x.address]=x.at}
        }
    }
    // Whether a peer asked for the object at address lately: it is fetching it.
    asked_lately :: proc(item:^Held,asked:map[store.Hash]i64,address:store.Hash,now:i64) {
        at,known:=asked[address]
        if !known {return}
        item.used=max(item.used,at)
        item.busy||=f64(now-at)<DDC_SECONDS*1e9
    }
    for o in r.orgs {
        ns:[len(DDC_PREFIX)+64]u8
        refs,e:=store.ref_list(s,ddc_namespace(o.id,&ns),context.temp_allocator)
        if e!=.None {continue}
        for ref in refs {
            key,ok:=store.parse_hex(ref.name)
            if !ok {continue}
            clear(&records)
            if ddc_set_read(s,ref.hash,&records)!=.None {continue}
            item:=Held{org=o.id,key=key}
            for l in r.ddc {item.busy||=l.org==o.id && l.key==key}
            for bytes in records {
                d,de:=ddc_record_decode(bytes)
                if de!=.None {continue}
                item.used=max(item.used,d.time)
                if size,whole:=ddc_output_bytes(s,d.output_root);whole {item.bytes+=size}
                item.busy||=fetching[d.output_root]
                asked_lately(&item,asked,d.output_root,now)
                objects,_:=ddc_output_get(s,d.output_root,context.temp_allocator)
                for x in objects {
                    item.busy||=fetching[x]
                    asked_lately(&item,asked,x,now)
                }
            }
            for u in r.ddc_use {
                if u.org==o.id && u.key==key {item.used=max(item.used,u.at)}
            }
            total+=item.bytes
            append(&held,item)
        }
    }
    if total<=r.desc.ddc_quota {return}
    slice.sort_by(held[:],proc(a,b:Held) -> bool {return a.used<b.used})
    dropped:=0
    for item in held {
        if total<=r.desc.ddc_quota {break}
        if item.busy {continue}
        ns:[len(DDC_PREFIX)+64]u8
        name:[64]u8
        if store.ref_remove(s,ddc_namespace(item.org,&ns),store.hex(item.key,&name))!=.None {continue}
        total-=item.bytes
        dropped+=1
        for k:=0;k<len(r.ddc_use);k+=1 {
            if r.ddc_use[k].org==item.org && r.ddc_use[k].key==item.key {
                unordered_remove(&r.ddc_use,k)
                break
            }
        }
    }
    if dropped==0 {return}
    live:=make([dynamic]store.Hash,context.temp_allocator)
    for l in r.ddc {
        if l.output!={} {append(&live,l.output)}
    }
    for o in r.orgs {
        for f in o.agent.fetches {append(&live,f.address)}
        for f in o.agent.deferred {append(&live,f.address)}
    }
    e:=store_prune(s,time.now()._nsec)
    if e==.None {e=store_live(s,&live)}
    result:store.Sweep_Result
    if e==.None {
        se:store.Error
        result,se=store.sweep(s,live[:],reclaim=true)
        e=store_error(se)
    }
    if e!=.None {
        runner_event(r,"the store sweep after dropping %d derived data keys failed: %s",dropped,error_text(e))
        return
    }
    runner_event(r,"dropped %d least recently used derived data keys over the quota; the sweep freed %d bytes",dropped,result.bytes)
}

// Writes a prune (repo_prune) at now (ns) into the operation log of every
// repository of s, and lets go the overlay records of revisions nothing kept
// reaches any more and older than the prune keeps operations (overlay_prune):
// a sweep that names what store_live names then reclaims what only the
// operations past the retention reached, their private files with it.
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
    if ce:=store.commit(s);ce!=.None {return store_error(ce)}
    overlay_prune(s,now) or_return
    return store_error(store.commit(s))
}

// Removes the ref of each overlay record whose revision nothing kept reaches
// (store_reach) and that was written before now less OP_RETENTION: a record
// of a revision still to come stays while operations of its age would.
@(private)
overlay_prune :: proc(s:^store.Store,now:i64) -> Error {
    kept:=make([dynamic]store.Hash,context.temp_allocator)
    store_reach(s,&kept,false) or_return
    reached:=make(map[store.Hash]struct{},context.temp_allocator)
    for address in kept {reached[address]={}}
    namespaces,e:=store.ref_namespaces(s,context.temp_allocator)
    if e!=.None {return store_error(e)}
    for namespace in namespaces {
        if !strings.has_prefix(namespace,OVERLAY_PREFIX) {continue}
        refs,le:=store.ref_list(s,namespace,context.temp_allocator)
        if le!=.None {continue}
        for ref in refs {
            if commit,ok:=store.parse_hex(ref.name);ok && commit in reached {continue}
            bytes,ge:=overlay_get(s,ref.hash,.Overlay_Record,OVERLAY_RECORD_MAX,context.temp_allocator)
            if ge==.None {
                if record,de:=overlay_record_decode(bytes);de==.None && record.time>=now-OP_RETENTION {continue}
            }
            if re:=store.ref_remove(s,namespace,ref.name);re!=.None && re!=.Missing {return store_error(re)}
        }
    }
    return .None
}

// What a sweep of s keeps that no ref names directly, since the sweep follows
// refs and the chunks of objects, not the links inside Kai records: the
// operations each repository's log reaches (op_retained) and their views, and
// everything the refs of every other namespace reach (reach.odin): each log's
// pages and what its entries name, the closures of the changes they, the
// views and the devices' refs name, the sealed tree and files of the overlay
// record each ref names (not the records before it, which nothing reads), and
// every object of the outputs of the derived data kept.
store_live :: proc(s:^store.Store,live:^[dynamic]store.Hash) -> Error {
    return store_reach(s,live,true)
}

// What store_live keeps, to live; with overlays, what the overlays' refs
// reach too.
@(private)
store_reach :: proc(s:^store.Store,live:^[dynamic]store.Hash,overlays:bool) -> Error {
    namespaces,e:=store.ref_namespaces(s,context.temp_allocator)
    if e!=.None {return store_error(e)}
    roots:=make([dynamic]Walk_Item,context.temp_allocator)
    for namespace in namespaces {
        if !overlays && strings.has_prefix(namespace,OVERLAY_PREFIX) {continue}
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
            for h in v.heads {append(&roots,Walk_Item{h,.Change,false})}
            for x in v.workspaces {append(&roots,Walk_Item{x.revision,.Change,false})}
            for b in v.bookmarks {
                for r in b.terms.adds {append(&roots,Walk_Item{r,.Change,false})}
                for r in b.terms.removes {append(&roots,Walk_Item{r,.Change,false})}
            }
        }
    }
    w:=walk_make(s)
    w.entries=true
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    walk_all(&w,roots[:],live,&missing)
    return .None
}
