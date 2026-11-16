package importer

import "core:mem"
import "core:slice"
import "mirai:std/base"
import "mirai:std/jobs"

// The zones of a profiled import, added up: what mirai import --profile
// prints and asset.import_status gives.

// Zones each thread of a profiled import keeps; past them the oldest are
// lost, and profile_totals counts them.
PROFILE_ZONES :: 1<<16

// The zones of one name under one parent, in preorder: the zones of a
// parent follow it, one deeper, heaviest first.
Zone_Total :: struct {
    name:string,
    depth:int,
    seconds:f64, // summed over the threads
    owner:f64,   // of seconds, those on the thread that imports (jobs.OWNER), which add up to its wall time
    count:int,
}

// Records the zones of the import options describes into profile, a ring
// for each worker of its job system (one without it), from now on. false
// when there is no memory for it.
profile_begin :: proc(profile:^base.Profile,options:^Import_Options,allocator:=context.allocator) -> bool {
    threads:=1 if options.worker.system==nil else jobs.worker_count(options.worker.system)
    if !base.profile_init(profile,{threads=threads,zones_per_thread=PROFILE_ZONES,allocator=allocator}) {return false}
    options.worker.profile=profile
    return true
}

// The zones of profile by name and by the zone that held each on its
// thread, and how many zones the rings lost. Read it while no thread
// records.
profile_totals :: proc(profile:^base.Profile,allocator:=context.allocator) -> (totals:[]Zone_Total,lost:u64) {
    Key :: struct {parent:int,name:string}
    Row :: struct {using total:Zone_Total,parent:int}
    rows:=make([dynamic]Row,context.temp_allocator)
    by_key:=make(map[Key]int,context.temp_allocator)
    zones:=make([]base.Profile_Zone,PROFILE_ZONES,context.temp_allocator)
    for thread in 0..<len(profile.threads) {
        lost+=base.profile_lost(profile,thread)
        read:=zones[:base.profile_read(profile,thread,zones)]
        // A zone ends before the one that holds it: from the newest back, the
        // holder of a zone is the last seen one level up.
        held:=make([dynamic]int,context.temp_allocator)
        #reverse for zone in read {
            depth:=int(zone.depth)
            parent:=-1
            if depth>0 && depth-1<len(held) {parent=held[depth-1]}
            key:=Key{parent,zone.name}
            at,seen:=by_key[key]
            if !seen {
                at=len(rows)
                append(&rows,Row{total={name=zone.name,depth=parent<0?0:rows[parent].depth+1},parent=parent})
                by_key[key]=at
            }
            seconds:=f64(zone.duration)/1e9
            rows[at].seconds+=seconds
            if thread==jobs.OWNER {rows[at].owner+=seconds}
            rows[at].count+=1
            resize(&held,depth+1)
            held[depth]=at
        }
    }
    order:=make([dynamic]int,0,len(rows),context.temp_allocator)
    children:=make([dynamic]int,context.temp_allocator)
    emit :: proc(rows:[]Row,order,children:^[dynamic]int,parent:int) {
        first:=len(children)
        for r,i in rows {if r.parent==parent {append(children,i)}}
        mine:=children[first:]
        context.user_ptr=raw_data(rows)
        slice.sort_by(mine,proc(a,b:int) -> bool {
            rows:=([^]Row)(context.user_ptr)
            return rows[a].seconds>rows[b].seconds
        })
        count:=len(mine)
        for k in 0..<count {
            i:=children[first+k]
            append(order,i)
            emit(rows,order,children,i)
        }
    }
    emit(rows[:],&order,&children,-1)
    error:mem.Allocator_Error
    totals,error=make([]Zone_Total,len(order),allocator)
    if error!=nil {return nil,lost}
    for i,at in order {totals[at]=rows[i].total}
    return
}

// The wall time of the thread that imports that no zone of it covers, out of
// seconds: what the zones leave unaccounted.
profile_unzoned :: proc(totals:[]Zone_Total,seconds:f64) -> f64 {
    zoned:=0.0
    for t in totals {if t.depth==0 {zoned+=t.owner}}
    return seconds-zoned
}
