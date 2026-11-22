package kai

import "core:slice"
import "core:strings"
import "core:time"
import "mirai:store"

// What a ddc node keeps of derived data: every key of an org's DDC namespace
// with the outputs here, swept least recently used first once their bytes
// pass the node's quota. A key is used when its newest record arrives and
// when a lookup through this node asks for it. The store's sweep follows refs
// only, not the links inside Kai records, so the sweep names as live what a
// node serves besides: the closures of every project's bookmarks and
// proposals, every overlay record with its sealed tree and files, and the
// outputs of the keys it keeps. A store that holds a workspace is not swept.

DDC_SWEEP_SECONDS :: 60.0 // between two looks at the quota

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
            if object_whole(s,d.output) {
                whole=true
                stats.bytes+=object_bytes(s,d.output)
            }
        }
        if whole {stats.whole+=1} else {stats.missing+=1}
        if outputs>1 {stats.nondeterministic+=1}
    }
    stats.lookups_found,stats.lookups_missing=r.ddc_found,r.ddc_missing
    return
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
    for &u in r.ddc_use {
        if u.org==org && u.key==key {
            u.at=now
            return
        }
    }
    append(&r.ddc_use,DDC_Use{org,key,now})
}

// Drops the least recently used keys of every org until the outputs fit the
// quota, then sweeps the store of what no ref holds any more.
@(private)
runner_ddc_quota :: proc(r:^Runner) {
    if r.desc.ddc_quota<=0 || .DDC not_in r.desc.modes || r.now-r.ddc_swept<DDC_SWEEP_SECONDS && r.ddc_swept>0 {return}
    r.ddc_swept=r.now
    s:=&r.machine.store
    Held :: struct {org:Log_Id,key:store.Hash,used:i64,bytes:i64}
    held:=make([dynamic]Held,context.temp_allocator)
    total:i64
    records:=make([dynamic][]u8,context.temp_allocator)
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
            for bytes in records {
                d,de:=ddc_record_decode(bytes)
                if de!=.None {continue}
                item.used=max(item.used,d.time)
                if object_whole(s,d.output) {item.bytes+=object_bytes(s,d.output)}
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
    if refs,e:=store.ref_list(s,MACHINE_NAMESPACE,context.temp_allocator);e==.None {
        for ref in refs {
            if strings.has_prefix(ref.name,MACHINE_REPO_PREFIX) {
                runner_event(r,"dropped %d derived data keys over the quota; the store holds a workspace, so it is not swept",dropped)
                return
            }
        }
    }
    live:=make([dynamic]store.Hash,context.temp_allocator)
    runner_live(r,&live)
    result,e:=store.sweep(s,live[:])
    if e!=.None {
        runner_event(r,"the store sweep after dropping %d derived data keys failed: %s",dropped,store.error_text(e))
        return
    }
    runner_event(r,"dropped %d least recently used derived data keys over the quota; the sweep freed %d bytes",dropped,result.bytes)
}

// What the node serves that no ref names directly: the closures of the
// projects' bookmarks, landed moves and proposal stacks, the overlay records
// with their chains, sealed trees and files, and the outputs of the derived
// data it keeps.
@(private)
runner_live :: proc(r:^Runner,live:^[dynamic]store.Hash) {
    s:=&r.machine.store
    targets:=make([dynamic]Revision,context.temp_allocator)
    roots:=make([dynamic]store.Hash,context.temp_allocator)
    for o in r.orgs {
        agent_targets(&o.agent,{},false,&targets,&roots)
        for l in o.agent.logs {
            for &item in l.items {
                #partial switch item.entry.type {
                case .Bookmark_Move:
                    b,_,ok:=body_head(item.entry.body,Bookmark_Move_Body)
                    if ok {append(&targets,b.to)}
                case .Proposal_Revise:
                    _,tail,ok:=body_head(item.entry.body,Proposal_Revise_Body)
                    if !ok || len(tail)%size_of(Stack_Item)!=0 {continue}
                    for stack in slice.reinterpret([]Stack_Item,tail) {append(&targets,stack.revision)}
                }
            }
        }
    }
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    closure_walk(s,targets[:],live,&missing)
    namespaces,e:=store.ref_namespaces(s,context.temp_allocator)
    if e!=.None {return}
    records:=make([dynamic][]u8,context.temp_allocator)
    for namespace in namespaces {
        refs,le:=store.ref_list(s,namespace,context.temp_allocator)
        if le!=.None {continue}
        switch {
        case strings.has_prefix(namespace,OVERLAY_PREFIX):
            for ref in refs {
                address:=ref.hash
                for _ in 0..<OVERLAY_FILES_MAX {
                    if address=={} {break}
                    bytes,ge:=overlay_get(s,address,.Record,OVERLAY_RECORD_MAX,context.temp_allocator)
                    if ge!=.None {break}
                    record,de:=overlay_record_decode(bytes)
                    if de!=.None {break}
                    append(live,record.tree_root)
                    append(live,..record.objects)
                    address=record.prev
                    if address!={} {append(live,address)}
                }
            }
        case strings.has_prefix(namespace,DDC_PREFIX):
            for ref in refs {
                clear(&records)
                if ddc_set_read(s,ref.hash,&records)!=.None {continue}
                for bytes in records {
                    if d,de:=ddc_record_decode(bytes);de==.None {append(live,d.output)}
                }
            }
        }
    }
}
