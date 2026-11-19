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
// was; a file both changed is kept and reported, never overwritten.

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
    kept:[dynamic]string, // files left as they are, each with why
    fetched:i64,    // bytes of files received now
    packages:sources.Library_Report,
}

// What a file of the snapshot needs.
@(private)
Plan :: struct {
    write:[dynamic]int,       // entries of the snapshot to write
    remove:[dynamic]string,   // paths the host removed and the joiner did not change
}

@(private) MISSING_SECONDS :: 10.0 // a blob no connected peer has for this long fails the join
@(private) WINDOW :: 256           // files wanted at once

join :: proc(d:Join_Desc,allocator:=context.allocator) -> (report:Join_Report,error:string) {
    n:=d.node
    d:=d
    if d.pace<=0 {d.pace=1}
    if d.connect_seconds<=0 {d.connect_seconds=15}
    report.kept=make([dynamic]string,allocator)
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

    // The files, smallest first.
    if error=join_files(&d,&snap,&plan,&index,folder,&report,allocator);error!="" {
        index_save(folder,&index)
        return
    }
    for path in plan.remove {
        if os.remove(project.path(folder,path,allocator=context.temp_allocator))==nil {
            report.removed+=1
            delete_key(&index,path)
            folders_prune(folder,path)
        }
    }
    file_save(share_path(folder,"snapshot",context.temp_allocator),bytes)
    index_save(folder,&index)

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
            if error=join_missing(d,p.state,&missing,what,allocator);error!="" {return}
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

// A blob that stays missing at every connected peer for MISSING_SECONDS fails.
@(private)
join_missing :: proc(d:^Join_Desc,state:exchange.State,since:^f64,what:string,allocator:runtime.Allocator) -> string {
    if state!=.Missing {
        since^=-1
        return ""
    }
    now:=node_now(d.node)
    if since^<0 {since^=now}
    if now-since^<MISSING_SECONDS {return ""}
    return fmt.aprintf("no connected peer has %s: the host changed it while this join ran; run the join again",what,allocator=allocator)
}

// What the snapshot needs here, against the last one this folder took.
@(private)
join_plan :: proc(snap,last:^Snapshot,index:^Index,folder:string,report:^Join_Report,allocator:runtime.Allocator) -> (plan:Plan) {
    plan.write=make([dynamic]int,allocator)
    plan.remove=make([dynamic]string,allocator)
    for &e,at in snap.entries {
        here,_,present:=index_address(index,e.path,project.path(folder,e.path,allocator=context.temp_allocator))
        if present && here==e.address {continue}
        base,based:=snapshot_find(last,e.path)
        switch {
        case !present && !based:
            append(&plan.write,at)
        case !present:
            if base.address!=e.address {kept(report,"%s: you removed it and the host changed it; it stays removed",e.path)}
        case based && here==base.address:
            append(&plan.write,at)
        case based && base.address==e.address:
            // Only the joiner changed it: it is the joiner's.
        case:
            kept(report,"%s: you changed it and the host has another one; yours is kept",e.path)
        }
    }
    for &e in last.entries {
        if _,still:=snapshot_find(snap,e.path);still {continue}
        here,_,present:=index_address(index,e.path,project.path(folder,e.path,allocator=context.temp_allocator))
        switch {
        case !present:
        case here==e.address: append(&plan.remove,strings.clone(e.path,allocator))
        case: kept(report,"%s: the host removed it and you changed it; yours is kept",e.path)
        }
    }
    return
}

@(private)
kept :: proc(report:^Join_Report,format:string,args:..any) {
    append(&report.kept,fmt.aprintf(format,..args,allocator=report.kept.allocator))
}

// Whether the disks have room for what the plan fetches and writes.
@(private)
join_room :: proc(d:^Join_Desc,snap:^Snapshot,plan:^Plan,folder:string,allocator:runtime.Allocator) -> string {
    s:=d.node.s
    fetch,write:i64
    seen:=make(map[store.Hash]bool,context.temp_allocator)
    for at in plan.write {
        e:=&snap.entries[at]
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
// and writes each file as its blob completes.
@(private)
join_files :: proc(d:^Join_Desc,snap:^Snapshot,plan:^Plan,index:^Index,folder:string,report:^Join_Report,allocator:runtime.Allocator) -> string {
    n:=d.node
    s:=n.s
    // The paths of each address, and the addresses to fetch by size.
    paths:=make(map[store.Hash][dynamic]int,context.temp_allocator)
    order:=make([dynamic]int,context.temp_allocator)
    total:i64
    for at in plan.write {
        e:=&snap.entries[at]
        list,known:=&paths[e.address]
        if !known {
            paths[e.address]=make([dynamic]int,context.temp_allocator)
            list=&paths[e.address]
            if !store.has(s,e.address) {
                append(&order,at)
                total+=e.size
            }
        }
        append(list,at)
    }
    Sized :: struct {size:i64,at:int}
    sized:=make([]Sized,len(order),context.temp_allocator)
    for at,k in order {sized[k]={snap.entries[at].size,at}}
    slice.sort_by(sized,proc(a,b:Sized) -> bool {return a.size<b.size || a.size==b.size && a.at<b.at})
    for one,k in sized {order[k]=one.at}
    // What is here already is written first.
    for address,list in paths {
        if !store.has(s,address) {continue}
        if error:=join_write(d,snap,list[:],index,folder,report,allocator);error!="" {return error}
    }
    if len(order)==0 {return ""}
    say(d,"fetching %d files, %s",len(order),bytes_text(total))
    Active :: struct {at:int,missing:f64}
    active:=make([dynamic]Active,context.temp_allocator)
    next:=0
    done:i64
    started:=node_now(n)
    totals:=node_totals(n)
    received_at,printed:=totals.received,started
    rate:f64
    for next<len(order) || len(active)>0 {
        for len(active)<WINDOW && next<len(order) {
            e:=&snap.entries[order[next]]
            // Smaller first: the priority falls with the place in the order.
            if want_error:=exchange.want(&n.x,e.address,len(order)-next);want_error!=.None {break}
            append(&active,Active{order[next],-1})
            next+=1
        }
        here:i64
        for k:=0;k<len(active); {
            a:=&active[k]
            e:=&snap.entries[a.at]
            p,_:=exchange.progress(&n.x,e.address)
            #partial switch p.state {
            case .Complete:
                exchange.forget(&n.x,e.address)
                size,_:=store.blob_size(s,e.address)
                if size!=e.size {return fmt.aprintf("the snapshot says %s has %d bytes and its blob has %d: the host is not honest; nothing more was written",e.path,e.size,size,allocator=allocator)}
                if error:=join_write(d,snap,paths[e.address][:],index,folder,report,allocator);error!="" {return error}
                done+=e.size
                report.fetched+=e.size
                unordered_remove(&active,k)
                continue
            case .Failed:
                return fmt.aprintf("%s could not be kept in the store at %s (%v, %v): free space there",e.path,s.root,p.error,p.store_error,allocator=allocator)
            }
            if error:=join_missing(d,p.state,&a.missing,e.path,allocator);error!="" {return error}
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

// Writes each entry of a complete blob into the folder, whole through a rename.
@(private)
join_write :: proc(d:^Join_Desc,snap:^Snapshot,entries:[]int,index:^Index,folder:string,report:^Join_Report,allocator:runtime.Allocator) -> string {
    s:=d.node.s
    temp_folder:=project.path(project.folder_path(folder,.Generated,context.temp_allocator),"tmp",allocator=context.temp_allocator)
    if os.make_directory_all(temp_folder)!=nil && !os.is_dir(temp_folder) {return fmt.aprintf("%s could not be made: give this user access to %s",temp_folder,folder,allocator=allocator)}
    for at in entries {
        e:=&snap.entries[at]
        from,path_error:=store.blob_path(s,e.address,context.temp_allocator)
        if path_error!=.None {return fmt.aprintf("%s: its blob is not in the store at %s (%v)",e.path,s.root,path_error,allocator=allocator)}
        target:=project.path(folder,e.path,allocator=context.temp_allocator)
        temp:=fmt.tprintf("%s/share-%d-%d",temp_folder,os.get_pid(),at)
        mode:=os.Permissions_Default_File
        if e.executable {mode+=os.Permissions_Execute_All}
        if e.size==0 {
            if os.write_entire_file(temp,nil)!=nil {return fmt.aprintf("%s could not be written: free space on its disk, or give this user access",temp,allocator=allocator)}
        } else if copy_error:=os.copy_file(temp,from);copy_error!=nil {
            os.remove(temp)
            return fmt.aprintf("%s could not be written (%v): free space on its disk, or give this user access",target,copy_error,allocator=allocator)
        }
        os.change_mode(temp,mode)
        parent:=os.dir(target)
        if os.make_directory_all(parent)!=nil && !os.is_dir(parent) {
            os.remove(temp)
            return fmt.aprintf("%s could not be made: a file of yours has the name of a folder of the host's",parent,allocator=allocator)
        }
        if os.rename(temp,target)!=nil {
            os.remove(temp)
            return fmt.aprintf("%s could not be replaced: close what holds it, or give this user access",target,allocator=allocator)
        }
        if info,stat_error:=os.stat(target,context.temp_allocator);stat_error==nil {index_learn(index,e.path,info,e.address)}
        report.written+=1
    }
    return ""
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
