package share

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "mirai:asset"
import "mirai:cook/import/sources"
import "mirai:exchange"
import "mirai:project"
import "mirai:std/jobs"
import "mirai:store"
import wire "mirai:net"

// A join: the snapshot a host offers, its files written into a folder, and
// the packages of the project refreshed with the peers as the source of the
// library. The files that must be written are fetched smallest first, many at
// once, and each is written whole through a rename as it completes; the store
// keeps what arrived, so a join stopped and run again fetches only the rest.
//
// A folder joined before keeps the snapshot it last took
// (<folder>/.mirai/share/snapshot), the base of three ways: a file the host
// changed or removed is replaced or removed when the joiner left it as it
// was; a file both changed is kept and reported, never overwritten, also
// when the joiner changes it while the join runs. A file that cannot be
// written or removed is reported with why and how to fix it, the rest is
// done, and the folder keeps as its base the last entry of each such file, so
// running the join again completes it.

Join_Desc :: struct {
    node:^Node,
    offer:string,      // the name of the snapshot under NAMESPACE the host offers (offer_name of its token)
    own_offer:string,  // the name this node offers it under to others; "": none
    folder:string,     // where the project goes; "": a new folder by its name under parent
    parent:string,     // "": the current folder
    library:sources.Library,
    worker:jobs.Worker_Ref,
    output:io.Writer,  // progress and what was kept; nil: nowhere
    pace:f64,          // seconds between two progress lines, default 1
    connect_seconds:f64, // waiting for the host, default 15
}

Join_Report :: struct {
    folder:string,
    files:int,      // of the snapshot
    written:int,    // files written now
    removed:int,    // files the host removed, removed here
    kept:[dynamic]string,   // files left as they are on purpose, each with why
    failed:[dynamic]string, // files not written or removed, each with why and how to fix it: the join is incomplete
    fetched:i64,    // bytes of files received now
    packages:sources.Library_Report,
}

// What the files of the snapshot need here.
@(private)
Plan :: struct {
    write:[dynamic]Write,
    remove:[dynamic]Remove,
    folds:bool,                 // the folder's file system folds case: paths compare in lower case
    last_folded:map[string]int, // with folds: the entries of the last snapshot by their path in lower case
    snap_folded:map[string]int, // with folds: those of the snapshot
}

// An entry of the snapshot to write, with the file as the plan found it here:
// absent, or with the address base. done: written, or left on purpose.
@(private)
Write :: struct {at:int,present:bool,base:store.Hash,done:bool}

// An entry of the last snapshot the host removed and the joiner did not change.
@(private)
Remove :: struct {at:int,done:bool}

@(private) MISSING_SECONDS :: 10.0 // a blob no connected peer has for this long fails the join
@(private) WINDOW :: 256           // files wanted at once

join :: proc(d:Join_Desc,allocator:=context.allocator) -> (report:Join_Report,error:string) {
    n:=d.node
    d:=d
    if d.pace<=0 {d.pace=1}
    if d.connect_seconds<=0 {d.connect_seconds=15}
    report.kept=make([dynamic]string,allocator)
    report.failed=make([dynamic]string,allocator)
    if error=join_connect(&d,allocator);error!="" {return}

    // The snapshot: its size is checked before it is taken whole.
    say(&d,"asking for the snapshot")
    address:store.Hash
    if address,error=join_offer(&d,allocator);error!="" {return}
    bytes:[]u8
    if bytes,error=join_blob(&d,address,SNAPSHOT_MAX_BYTES,"the snapshot",allocator);error!="" {return}
    snap,decode_error:=snapshot_decode(bytes,allocator)
    if decode_error!=.None {
        error=fmt.aprintf("the host sent a snapshot this engine refuses (%v): it was not written; the host runs another version of Mirai, or is not honest",decode_error,allocator=allocator)
        return
    }
    report.files=len(snap.entries)
    folder:=d.folder
    if folder=="" {folder=project.path(d.parent==""?".":d.parent,snap.name,allocator=context.temp_allocator)}
    folder=project.path_absolute(folder,allocator)
    report.folder=folder
    if os.exists(folder) && !os.is_dir(folder) {
        error=fmt.aprintf("%s is a file: give the join a folder",folder,allocator=allocator)
        return
    }
    node_serve(n,address)
    if d.own_offer!="" {offer_set(n.s,folder,d.own_offer,address)}
    // What a join stopped in the middle of a write left.
    temp_folder:=project.path(project.folder_path(folder,.Generated,context.temp_allocator),"tmp",allocator=context.temp_allocator)
    if left,list_error:=os.read_all_directory_by_path(temp_folder,context.temp_allocator);list_error==nil {
        for info in left {
            if strings.has_prefix(info.name,"share-") {os.remove(info.fullpath)}
        }
    }

    // What changes, from the last snapshot of this folder and its files as they are.
    index:=index_load(folder,context.temp_allocator)
    last:Snapshot
    if previous,read_error:=os.read_entire_file(share_path(folder,"snapshot",context.temp_allocator),context.temp_allocator);read_error==nil {
        last,_=snapshot_decode(previous,context.temp_allocator)
    }
    plan:=join_plan(&snap,&last,&index,folder,&report,allocator)
    if error=join_room(&d,&snap,&plan,folder,allocator);error!="" {return}

    // The files, smallest first, then what the host removed.
    error=join_files(&d,&snap,&plan,&index,folder,&report,allocator)
    if error=="" {join_remove(&last,&plan,&index,folder,&report)}
    base_save(folder,&snap,&last,&plan)
    index_save(folder,&index)
    if error!="" {return}

    // The packages, their builds from the peers.
    if os.exists(project.path(folder,asset.PACKAGES_FILE,allocator=context.temp_allocator)) {
        say(&d,"refreshing the packages of the project")
        report.packages=join_packages(&d,folder,allocator)
    }
    return
}

@(private)
say :: proc(d:^Join_Desc,format:string,args:..any) {
    if d.output.procedure!=nil {fmt.wprintfln(d.output,format,..args)}
}

// Waits for the connection to the host, or says why there is none.
@(private)
join_connect :: proc(d:^Join_Desc,allocator:runtime.Allocator) -> string {
    n:=d.node
    // The clock of the node is its owner's from its first step on.
    if !node_wait(n,0) {return strings.clone("the join was stopped",allocator)}
    started:=node_now(n)
    for {
        sync.mutex_lock(&n.lock)
        joined,reason:=n.client_joined,n.client_reason
        sync.mutex_unlock(&n.lock)
        if joined {return ""}
        if reason!=.None || node_now(n)-started>d.connect_seconds {return refusal(reason,allocator)}
        if !node_wait(n,0.05) {return strings.clone("the join was stopped",allocator)}
    }
}

// Why the connection to a host ended, and what to do.
refusal :: proc(reason:wire.Disconnect_Reason,allocator:=context.allocator) -> string {
    #partial switch reason {
    case .Denied_Version,.Denied_Protocol:
        return strings.clone("the host runs another version of Mirai: both sides need the same engine",allocator)
    case .Denied_Full:
        return strings.clone("the host has all the peers it takes: join again when one leaves, or join from another peer that has the project",allocator)
    case .Closed,.Kicked:
        return strings.clone("the host closed the connection: it stopped sharing; run the join again with a new invitation and it resumes",allocator)
    case .Timeout:
        return strings.clone("the host stopped answering: run the same join again when it shares, and it resumes where it was",allocator)
    }
    return strings.clone("the host did not answer. Either its share has ended (an invitation lasts while the share that printed it runs: ask for a new one), or it cannot be reached from here: on another network one side needs a router that maps a port (UPnP, NAT-PMP or PCP) and the host must give the code it prints once its router answered; a firewall must let UDP through",allocator)
}

// The address of the snapshot the host offers.
@(private)
join_offer :: proc(d:^Join_Desc,allocator:runtime.Allocator) -> (address:store.Hash,error:string) {
    n:=d.node
    q,ask_error:=exchange.ref_ask(&n.x,NAMESPACE,d.offer)
    if ask_error!=.None {return {},fmt.aprintf("the snapshot could not be asked for (%v)",ask_error,allocator=allocator)}
    defer exchange.query_end(&n.x,q)
    for {
        result,ok:=exchange.query_result(&n.x,q)
        if !ok {return {},strings.clone("the question for the snapshot was lost",allocator)}
        switch result.state {
        case .Found: return result.address,""
        case .Not_Found: return {},strings.clone("the host offers no project under this invitation: its share ended and another runs; ask for its new invitation",allocator)
        case .Waiting:
        }
        if error=join_alive(d,allocator);error!="" {return}
    }
}

// Fails once the host is gone; otherwise waits a step.
@(private)
join_alive :: proc(d:^Join_Desc,allocator:runtime.Allocator) -> string {
    n:=d.node
    sync.mutex_lock(&n.lock)
    connected,reason:=n.connected,n.client_reason
    sync.mutex_unlock(&n.lock)
    if connected==0 {return refusal(reason==.None?.Timeout:reason,allocator)}
    if !node_wait(n,0.02) {return strings.clone("the join was stopped",allocator)}
    return ""
}

// The bytes of a blob of at most limit bytes, fetched from the peers.
@(private)
join_blob :: proc(d:^Join_Desc,address:store.Hash,limit:i64,what:string,allocator:runtime.Allocator) -> (bytes:[]u8,error:string) {
    n:=d.node
    if !store.has(n.s,address) {
        exchange.want(&n.x,address,1<<20)
        defer exchange.forget(&n.x,address)
        missing:=-1.0
        for {
            p,_:=exchange.progress(&n.x,address)
            if p.total>limit {return nil,fmt.aprintf("the host sent %s of %d bytes, more than the %d this engine takes: it was refused",what,p.total,limit,allocator=allocator)}
            if p.state==.Complete {break}
            if p.state==.Failed {return nil,fmt.aprintf("%s could not be kept in the store at %s (%v, %v): free space there",what,n.s.root,p.error,p.store_error,allocator=allocator)}
            if join_missing(d,p.state,&missing) {return nil,fmt.aprintf("no connected peer has %s: the host changed it while this join ran; run the join again",what,allocator=allocator)}
            if error=join_alive(d,allocator);error!="" {return}
        }
    }
    size,size_error:=store.blob_size(n.s,address)
    if size_error!=.None {return nil,fmt.aprintf("%s does not read from the store at %s (%v)",what,n.s.root,size_error,allocator=allocator)}
    if size>limit {return nil,fmt.aprintf("the host sent %s of %d bytes, more than the %d this engine takes: it was refused",what,size,limit,allocator=allocator)}
    bytes=make([]u8,int(size),allocator)
    if read_error:=store.read(n.s,address,0,bytes);read_error!=.None {return nil,fmt.aprintf("%s does not read from the store at %s (%v)",what,n.s.root,read_error,allocator=allocator)}
    return bytes,""
}

// Whether a blob stayed missing at every connected peer for MISSING_SECONDS.
@(private)
join_missing :: proc(d:^Join_Desc,state:exchange.State,since:^f64) -> bool {
    if state!=.Missing {
        since^=-1
        return false
    }
    now:=node_now(d.node)
    if since^<0 {since^=now}
    return now-since^>=MISSING_SECONDS
}

// What the snapshot needs here, against the last one this folder took.
@(private)
join_plan :: proc(snap,last:^Snapshot,index:^Index,folder:string,report:^Join_Report,allocator:runtime.Allocator) -> (plan:Plan) {
    plan.write=make([dynamic]Write,allocator)
    plan.remove=make([dynamic]Remove,allocator)
    if plan.folds=folds_case(folder);plan.folds {
        plan.last_folded=make(map[string]int,len(last.entries),allocator)
        plan.snap_folded=make(map[string]int,len(snap.entries),allocator)
        for e,at in last.entries {plan.last_folded[strings.to_lower(e.path,allocator)]=at}
        for e,at in snap.entries {plan.snap_folded[strings.to_lower(e.path,allocator)]=at}
        case_follow(snap,last,&plan,index,folder)
    }
    for &e,at in snap.entries {
        here,_,present:=index_address(index,e.path,project.path(folder,e.path,allocator=context.temp_allocator))
        if present && here==e.address {continue}
        base,based:=base_find(&plan,last,e.path)
        switch {
        case !present && !based:
            append(&plan.write,Write{at=at})
        case !present:
            if base.address!=e.address {kept(report,"%s: you removed it and the host changed it; it stays removed",e.path)}
        case based && here==base.address:
            append(&plan.write,Write{at=at,present=true,base=here})
        case based && base.address==e.address:
            // Only the joiner changed it: it is the joiner's.
        case:
            kept(report,"%s: you changed it and the host has another one; yours is kept",e.path)
        }
    }
    for &e,at in last.entries {
        if _,still:=snapshot_find(snap,e.path);still {continue}
        // Renamed by the host changing only its case: on this system it is the same file.
        if plan.folds && strings.to_lower(e.path,context.temp_allocator) in plan.snap_folded {continue}
        here,_,present:=index_address(index,e.path,project.path(folder,e.path,allocator=context.temp_allocator))
        switch {
        case !present:
        case here==e.address: append(&plan.remove,Remove{at=at})
        case: kept(report,"%s: the host removed it and you changed it; yours is kept",e.path)
        }
    }
    return
}

// The entry of path in the last snapshot, under any case where the system folds it.
@(private)
base_find :: proc(plan:^Plan,last:^Snapshot,path:string) -> (^Entry,bool) {
    if e,found:=snapshot_find(last,path);found {return e,true}
    if !plan.folds {return nil,false}
    at,found:=plan.last_folded[strings.to_lower(path,context.temp_allocator)]
    if !found {return nil,false}
    return &last.entries[at],true
}

// Whether the file system of folder folds case, as APFS and NTFS do unless
// formatted otherwise: a file made with a name in lower case is found under it
// in upper case.
@(private)
folds_case :: proc(folder:string) -> bool {
    temp_folder:=project.path(project.folder_path(folder,.Generated,context.temp_allocator),"tmp",allocator=context.temp_allocator)
    if os.make_directory_all(temp_folder)!=nil && !os.is_dir(temp_folder) {return false}
    name:=fmt.tprintf("share-case-%d",os.get_pid())
    lower:=project.path(temp_folder,name,allocator=context.temp_allocator)
    if os.write_entire_file(lower,nil)!=nil {return false}
    defer os.remove(lower)
    return os.exists(project.path(temp_folder,strings.to_upper(name,context.temp_allocator),allocator=context.temp_allocator))
}

// Where the system folds case, a file the host renamed changing only the case
// of its path is renamed here too, folders first, where the joiner left the
// name of the last snapshot; a name the joiner changed stays. The index follows.
@(private)
case_follow :: proc(snap,last:^Snapshot,plan:^Plan,index:^Index,folder:string) {
    temp_folder:=project.path(project.folder_path(folder,.Generated,context.temp_allocator),"tmp",allocator=context.temp_allocator)
    for &e in snap.entries {
        if _,same:=snapshot_find(last,e.path);same {continue}
        at,renamed:=plan.last_folded[strings.to_lower(e.path,context.temp_allocator)]
        if !renamed {continue}
        old:=last.entries[at].path
        if len(old)!=len(e.path) {continue}
        start:=0
        for i in 0..=len(e.path) {
            if i<len(e.path) && e.path[i]!='/' {continue}
            if e.path[start:i]!=old[start:i] {
                parent:=start==0?folder:project.path(folder,e.path[:start-1],allocator=context.temp_allocator)
                part_rename(parent,old[start:i],e.path[start:i],temp_folder)
            }
            start=i+1
        }
        if k,known:=index[old];known {
            delete_key(index,old)
            index[strings.clone(e.path,index.allocator)]=k
        }
    }
}

// Renames the file or folder from to to in parent, which differ only in case,
// through a name of its own in temp_folder; nothing when parent holds neither name.
@(private)
part_rename :: proc(parent,from,to,temp_folder:string) {
    listed,error:=os.read_all_directory_by_path(parent,context.temp_allocator)
    if error!=nil {return}
    for info in listed {
        if info.name==to {return}
        if info.name!=from {continue}
        temp:=fmt.tprintf("%s/share-case-%d-rename",temp_folder,os.get_pid())
        source:=project.path(parent,from,allocator=context.temp_allocator)
        if os.rename(source,temp)!=nil {return}
        if os.rename(temp,project.path(parent,to,allocator=context.temp_allocator))!=nil {os.rename(temp,source)}
        return
    }
}

@(private)
kept :: proc(report:^Join_Report,format:string,args:..any) {
    append(&report.kept,fmt.aprintf(format,..args,allocator=report.kept.allocator))
}

@(private)
failed :: proc(report:^Join_Report,format:string,args:..any) {
    append(&report.failed,fmt.aprintf(format,..args,allocator=report.failed.allocator))
}

// Whether the disks have room for what the plan fetches and writes.
@(private)
join_room :: proc(d:^Join_Desc,snap:^Snapshot,plan:^Plan,folder:string,allocator:runtime.Allocator) -> string {
    s:=d.node.s
    fetch,write:i64
    seen:=make(map[store.Hash]bool,context.temp_allocator)
    for w in plan.write {
        e:=&snap.entries[w.at]
        write+=e.size
        if e.address in seen || store.has(s,e.address) {continue}
        seen[e.address]=true
        fetch+=e.size
    }
    existing:=folder
    for !os.exists(existing) {
        parent:=os.dir(existing)
        if parent==existing {break}
        existing=parent
    }
    store_free,store_known:=free_bytes(s.root)
    folder_free,folder_known:=free_bytes(existing)
    store_info,_:=os.stat(s.root,context.temp_allocator)
    folder_info,_:=os.stat(existing,context.temp_allocator)
    if store_known && folder_known && store_info.device==folder_info.device && store_info.device!=0 {
        if fetch+write>store_free {return fmt.aprintf("the disk of %s and %s has %s free and the join needs %s: free space, or give another folder or --store",s.root,folder,bytes_text(store_free),bytes_text(fetch+write),allocator=allocator)}
        return ""
    }
    if store_known && fetch>store_free {return fmt.aprintf("the disk of the store at %s has %s free and the join needs %s there: free space, or give another --store",s.root,bytes_text(store_free),bytes_text(fetch),allocator=allocator)}
    if folder_known && write>folder_free {return fmt.aprintf("the disk of %s has %s free and the join needs %s there: free space, or give another folder",folder,bytes_text(folder_free),bytes_text(write),allocator=allocator)}
    return ""
}

// Fetches the blobs of the files to write, smallest first and WINDOW at once,
// and writes each file as its blob completes. A file whose blob does not come
// is reported and the others go on; the error is what stops the whole join.
@(private)
join_files :: proc(d:^Join_Desc,snap:^Snapshot,plan:^Plan,index:^Index,folder:string,report:^Join_Report,allocator:runtime.Allocator) -> string {
    n:=d.node
    s:=n.s
    // The writes of each address, and the addresses to fetch by size.
    paths:=make(map[store.Hash][dynamic]int,context.temp_allocator)
    order:=make([dynamic]int,context.temp_allocator)
    total:i64
    for w,k in plan.write {
        e:=&snap.entries[w.at]
        list,known:=&paths[e.address]
        if !known {
            paths[e.address]=make([dynamic]int,context.temp_allocator)
            list=&paths[e.address]
            if !store.has(s,e.address) {
                append(&order,k)
                total+=e.size
            }
        }
        append(list,k)
    }
    Sized :: struct {size:i64,k:int}
    sized:=make([]Sized,len(order),context.temp_allocator)
    for k,at in order {sized[at]={snap.entries[plan.write[k].at].size,k}}
    slice.sort_by(sized,proc(a,b:Sized) -> bool {return a.size<b.size || a.size==b.size && a.k<b.k})
    for one,at in sized {order[at]=one.k}
    // What is here already is written first.
    for address,list in paths {
        if store.has(s,address) {join_write(d,snap,plan,list[:],index,folder,report)}
    }
    if len(order)==0 {return ""}
    say(d,"fetching %d files, %s",len(order),bytes_text(total))
    Active :: struct {k:int,missing:f64}
    active:=make([dynamic]Active,context.temp_allocator)
    next:=0
    done:i64
    started:=node_now(n)
    totals:=node_totals(n)
    received_at,printed:=totals.received,started
    rate:f64
    for next<len(order) || len(active)>0 {
        for len(active)<WINDOW && next<len(order) {
            e:=&snap.entries[plan.write[order[next]].at]
            // Smaller first: the priority falls with the place in the order.
            if want_error:=exchange.want(&n.x,e.address,len(order)-next);want_error!=.None {break}
            append(&active,Active{order[next],-1})
            next+=1
        }
        here:i64
        for k:=0;k<len(active); {
            a:=&active[k]
            e:=&snap.entries[plan.write[a.k].at]
            list:=paths[e.address][:]
            p,_:=exchange.progress(&n.x,e.address)
            ended:=true
            #partial switch p.state {
            case .Complete:
                size,_:=store.blob_size(s,e.address)
                if size!=e.size {
                    for w in list {failed(report,"%s: the snapshot says %d bytes and its blob has %d: the host is not honest; it was not written",snap.entries[plan.write[w].at].path,e.size,size)}
                } else {
                    join_write(d,snap,plan,list,index,folder,report)
                    report.fetched+=e.size
                }
                done+=e.size
            case .Failed:
                for w in list {failed(report,"%s could not be kept in the store at %s (%v, %v): free space there, and run the join again",snap.entries[plan.write[w].at].path,s.root,p.error,p.store_error)}
            case:
                if join_missing(d,p.state,&a.missing) {
                    for w in list {failed(report,"%s: no connected peer has it, the host changed it while this join ran: run the join again",snap.entries[plan.write[w].at].path)}
                } else {
                    ended=false
                }
            }
            if ended {
                exchange.forget(&n.x,e.address)
                unordered_remove(&active,k)
                continue
            }
            here+=max(p.here,0)
            k+=1
        }
        now:=node_now(n)
        if now-printed>=d.pace {
            t:=node_totals(n)
            dt:=now-printed
            rate=f64(t.received-received_at)/dt
            received_at,printed=t.received,now
            left:=total-done-here
            eta:=rate>0?f64(left)/rate:-1
            say(d,"%d of %d files, %s of %s, %s/s, %s left",next-len(active),len(order),bytes_text(done+here),bytes_text(total),bytes_text(i64(rate)),eta<0?"time":seconds_text(eta))
        }
        if error:=join_alive(d,allocator);error!="" {return error}
    }
    elapsed:=node_now(n)-started
    say(d,"fetched %d files, %s in %s (%s/s)",len(order),bytes_text(total),seconds_text(elapsed),bytes_text(i64(f64(total)/max(elapsed,1e-3))))
    return ""
}

// Writes the planned writes list of a complete blob into the folder, each
// whole through a rename, unless the joiner changed the file since the plan;
// what cannot be written is reported with how to fix it.
@(private)
join_write :: proc(d:^Join_Desc,snap:^Snapshot,plan:^Plan,list:[]int,index:^Index,folder:string,report:^Join_Report) {
    s:=d.node.s
    temp_folder:=project.path(project.folder_path(folder,.Generated,context.temp_allocator),"tmp",allocator=context.temp_allocator)
    if os.make_directory_all(temp_folder)!=nil && !os.is_dir(temp_folder) {
        for k in list {failed(report,"%s: %s could not be made: give this user access to %s, and run the join again",snap.entries[plan.write[k].at].path,temp_folder,folder)}
        return
    }
    for k in list {
        w:=&plan.write[k]
        e:=&snap.entries[w.at]
        target:=project.path(folder,e.path,allocator=context.temp_allocator)
        here,_,present:=index_address(index,e.path,target)
        if present!=w.present || present && here!=w.base {
            if !present || here!=e.address {kept(report,"%s: you changed it while the join ran; yours is kept",e.path)}
            w.done=true
            continue
        }
        if present && !writable(target) {
            failed(report,"%s is read-only: make it writable (chmod u+w on macOS and Linux, attrib -r on Windows) and run the join again",target)
            continue
        }
        from,path_error:=store.blob_path(s,e.address,context.temp_allocator)
        if path_error!=.None {
            failed(report,"%s: its blob is not in the store at %s (%v): run the join again",e.path,s.root,path_error)
            continue
        }
        temp:=fmt.tprintf("%s/share-%d-%d",temp_folder,os.get_pid(),w.at)
        mode:=os.Permissions_Default_File
        if e.executable {mode+=os.Permissions_Execute_All}
        if e.size==0 {
            if write_error:=os.write_entire_file(temp,nil);write_error!=nil {
                failed(report,"%s could not be written (%v): free space on its disk, or give this user access to %s, and run the join again",target,write_error,temp_folder)
                continue
            }
        } else if copy_error:=os.copy_file(temp,from);copy_error!=nil {
            os.remove(temp)
            failed(report,"%s could not be written (%v): free space on its disk, or give this user access to %s, and run the join again",target,copy_error,temp_folder)
            continue
        }
        os.change_mode(temp,mode)
        parent:=os.dir(target)
        if make_error:=os.make_directory_all(parent);make_error!=nil && !os.is_dir(parent) {
            os.remove(temp)
            failed(report,"%s could not be made (%v): a file of yours has the name of a folder of the host's, or this user cannot write there; move it or give access, and run the join again",parent,make_error)
            continue
        }
        if !writable(parent) {
            os.remove(temp)
            failed(report,"%s: its folder %s is read-only: give this user write access to it (chmod u+w on macOS and Linux) and run the join again",e.path,parent)
            continue
        }
        if rename_error:=os.rename(temp,target);rename_error!=nil {
            os.remove(temp)
            failed(report,"%s could not be replaced (%v): close what holds it, or give this user access, and run the join again",target,rename_error)
            continue
        }
        if info,stat_error:=os.stat(target,context.temp_allocator);stat_error==nil {index_learn(index,e.path,info,e.address)}
        report.written+=1
        w.done=true
    }
}

// Removes what the host removed, unless the joiner changed it since the plan
// or it cannot be removed, which is reported with how to fix it.
@(private)
join_remove :: proc(last:^Snapshot,plan:^Plan,index:^Index,folder:string,report:^Join_Report) {
    for &r in plan.remove {
        e:=&last.entries[r.at]
        target:=project.path(folder,e.path,allocator=context.temp_allocator)
        here,_,present:=index_address(index,e.path,target)
        switch {
        case !present:
            r.done=true
        case here!=e.address:
            kept(report,"%s: the host removed it and you changed it; yours is kept",e.path)
            r.done=true
        case !writable(target):
            failed(report,"%s is read-only and the host removed it: make it writable (chmod u+w on macOS and Linux, attrib -r on Windows) and run the join again",target)
        case:
            if remove_error:=os.remove(target);remove_error!=nil {
                failed(report,"%s could not be removed (%v): close what holds it, or give this user write access to its folder, and run the join again",target,remove_error)
                continue
            }
            report.removed+=1
            delete_key(index,e.path)
            folders_prune(folder,e.path)
            r.done=true
        }
    }
}

// Keeps as the base of the next join the host's snapshot, but for what this
// one did not do: a file not written keeps its entry of the last snapshot, and
// a file not removed its removed entry, so that the next join does them.
@(private)
base_save :: proc(folder:string,snap,last:^Snapshot,plan:^Plan) {
    undone:=make(map[int]bool,context.temp_allocator)
    for w in plan.write {
        if !w.done {undone[w.at]=true}
    }
    entries:=make([dynamic]Entry,0,len(snap.entries)+len(plan.remove),context.temp_allocator)
    for e,at in snap.entries {
        if at not_in undone {
            append(&entries,e)
        } else if base,based:=base_find(plan,last,e.path);based {
            append(&entries,base^)
        }
    }
    for r in plan.remove {
        if !r.done {append(&entries,last.entries[r.at])}
    }
    slice.sort_by(entries[:],proc(a,b:Entry) -> bool {return a.path<b.path})
    if bytes,error:=snapshot_encode({name=snap.name,entries=entries[:]},context.temp_allocator);error==.None {
        file_save(share_path(folder,"snapshot",context.temp_allocator),bytes)
    }
}

// Removes the folders of path under root that were left empty.
@(private)
folders_prune :: proc(root,path:string) {
    for at:=strings.last_index_byte(path,'/');at>0;at=strings.last_index_byte(path[:at],'/') {
        folder:=project.path(root,path[:at],allocator=context.temp_allocator)
        listed,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil || len(listed)>0 || os.remove(folder)!=nil {return}
    }
}

// The project's packages refreshed with the peers as the source, on a thread
// of its own, while this one says how far it is.
@(private)
join_packages :: proc(d:^Join_Desc,folder:string,allocator:runtime.Allocator) -> sources.Library_Report {
    n:=d.node
    Work :: struct {
        options:sources.Library_Options,
        folder:string,
        report:sources.Library_Report,
        allocator:runtime.Allocator,
        done:bool,
    }
    work:=Work{folder=folder,allocator=allocator}
    work.options={store=n.s,source=node_source(n),root=folder,plugins=d.library,worker=d.worker,progress=d.output}
    t:=thread.create_and_start_with_data(&work,proc(data:rawptr) {
        w:=(^Work)(data)
        w.report=sources.project_refresh(w.folder,w.options,w.allocator)
        free_all(context.temp_allocator)
        sync.atomic_store(&w.done,true)
    })
    if t==nil {
        work.report=sources.project_refresh(folder,work.options,allocator)
        return work.report
    }
    started:=node_now(n)
    from:=node_totals(n).received
    printed:=started
    last:=from
    for !sync.atomic_load(&work.done) {
        if !node_wait(n,0.05) {break}
        now:=node_now(n)
        if now-printed<d.pace {continue}
        t:=node_totals(n)
        if t.received!=last {say(d,"builds: %s received, %s/s",bytes_text(i64(t.received-from)),bytes_text(i64(f64(t.received-last)/(now-printed))))}
        last,printed=t.received,now
    }
    thread.join(t)
    thread.destroy(t)
    return work.report
}

// Sets the ref under which this node offers the snapshot at address, in place
// of the one it offered for folder before.
offer_set :: proc(s:^store.Store,folder,name:string,address:store.Hash) {
    file:=share_path(folder,"offer",context.temp_allocator)
    if previous,error:=os.read_entire_file(file,context.temp_allocator);error==nil && string(previous)!=name && store.name_valid(string(previous)) {
        store.ref_remove(s,NAMESPACE,string(previous))
    }
    store.ref_set(s,NAMESPACE,name,address)
    file_save(file,transmute([]u8)name)
}

bytes_text :: proc(bytes:i64) -> string {
    value:=f64(bytes)
    switch {
    case value>=1<<30: return fmt.tprintf("%.2f GiB",value/(1<<30))
    case value>=1<<20: return fmt.tprintf("%.1f MiB",value/(1<<20))
    case value>=1<<10: return fmt.tprintf("%.1f KiB",value/(1<<10))
    }
    return fmt.tprintf("%d bytes",bytes)
}

seconds_text :: proc(seconds:f64) -> string {
    whole:=int(seconds+0.5)
    if whole<60 {return fmt.tprintf("%d s",whole)}
    if whole<3600 {return fmt.tprintf("%d min %02d s",whole/60,whole%60)}
    return fmt.tprintf("%d h %02d min",whole/3600,whole/60%60)
}
