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
import kai_assets "mirai:cook/kai"
import "mirai:cook/textures"
import "mirai:exchange"
import vcs "mirai:kai"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"
import wire "mirai:net"

// A join: the snapshot a host offers, its files written into a folder, and
// the packages of the project refreshed with the peers as the source of the
// library. The tree is fetched a depth at a time, with the base put in the
// store first, so only the folders that changed are asked. The files that
// must be written are fetched small first, many at once, the project's
// manifest and start scene before the rest; each is written chunk by chunk
// into a temporary file and renamed into place as it completes. The store
// keeps what arrived, so a join stopped and run again fetches only the rest,
// and a file changed here before is put in the store first, so the chunks
// its old version shares with the new are not asked.
//
// A folder joined before keeps the snapshot it last took
// (<folder>/.mirai/share/snapshot), the base of three ways: a file the host
// changed or removed is replaced or removed when the joiner left it as it
// was; a file both changed is merged by the drivers of Kai (an asset row by
// row and field by field, text by lines) when they resolve it, and otherwise
// kept and reported, never overwritten, also when the joiner changes it while
// the join runs. A file that cannot be
// written or removed is reported with why and how to fix it, the rest is
// done, and the folder keeps as its base the last entry of each such file, so
// running the join again completes it.

Join_Desc :: struct {
    node:^Node,
    offer:string,      // the name of the host's offer under NAMESPACE
    own_offer:string,  // the name this node offers it under to others; "": none
    folder:string,     // where the project goes; "": a new folder by its name under parent
    parent:string,     // "": the current folder
    library:sources.Library, // asked once the files are written, for the importers of the folder's plugins (editor.import_library_built)
    worker:jobs.Worker_Ref,
    gpu:^textures.Gpu_Context,
    output:io.Writer,  // progress and what was kept; nil: nowhere
    pace:f64,          // seconds between two progress lines, default 1
    connect_seconds:f64, // waiting for the host, default 15
    progress:^Join_Progress, // what it is doing, for whoever shows it; nil: none
    require_live:bool, // the editor joins a live session
}

Join_Phase :: enum u8 {Connecting,Snapshot,Files,Packages,Done}

// What a join is doing while it runs. files and bytes: those it fetches;
// rate: chunk bytes received per second lately; left: seconds the files
// still need at that rate, <0 when unknown; kept: files left as the joiner
// changed them so far.
Join_State :: struct {
    phase:Join_Phase,
    files,files_done:int,
    bytes,bytes_done:i64,
    received:u64,
    rate,left:f64,
    kept:int,
}

// The state of a join, written by its thread and read by any other.
Join_Progress :: struct {
    lock:sync.Mutex,
    state:Join_State,
}

join_progress_read :: proc(p:^Join_Progress) -> Join_State {
    sync.mutex_guard(&p.lock)
    return p.state
}

@(private)
progress_set :: proc(d:^Join_Desc,state:Join_State) {
    if d.progress==nil {return}
    sync.mutex_guard(&d.progress.lock)
    d.progress.state=state
}

@(private)
progress_phase :: proc(d:^Join_Desc,phase:Join_Phase,report:^Join_Report=nil) {
    if d.progress==nil {return}
    sync.mutex_guard(&d.progress.lock)
    d.progress.state.phase=phase
    d.progress.state.left=-1
    if report!=nil {d.progress.state.kept=len(report.kept)}
}

Join_Report :: struct {
    folder:string,
    files:int,      // of the snapshot
    written:int,    // files written now
    removed:int,    // files the host removed, removed here
    merged:int,     // files both changed, merged and written
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
    drivers:[]vcs.Driver,       // what merges a file both changed
}

// An entry of the snapshot to write, with the file as the plan found it here:
// absent, or with the address base. done: written, or left on purpose.
// refused: its path passes through a link here, and it is not written.
// merge: both changed it since origin, the entry of the last snapshot.
@(private)
Write :: struct {at:int,present:bool,base:store.Hash,done:bool,refused:bool,merge:bool,origin:store.Hash}

// An entry of the last snapshot the host removed and the joiner did not change.
@(private)
Remove :: struct {at:int,done:bool,refused:bool}

@(private) MISSING_SECONDS :: 10.0 // an object no connected peer has for this long fails the join
@(private) STALL_SECONDS :: 20.0   // without a byte received or an object complete, what is wanted fails
@(private) WINDOW :: 256           // files wanted at once

join :: proc(d:Join_Desc,allocator:=context.allocator) -> (report:Join_Report,error:string) {
    n:=d.node
    d:=d
    if d.pace<=0 {d.pace=1}
    if d.connect_seconds<=0 {d.connect_seconds=15}
    report.kept=make([dynamic]string,allocator)
    report.failed=make([dynamic]string,allocator)
    progress_phase(&d,.Connecting)
    defer progress_phase(&d,.Done,&report)
    if error=join_connect(&d,allocator);error!="" {return}
    progress_phase(&d,.Snapshot)

    // The root first: it names the project, whose folder keeps the base.
    say(&d,"asking for the snapshot")
    address:store.Hash
    name:string
    if address,name,error=join_offer(&d,allocator);error!="" {return}
    folder:=d.folder
    if folder=="" {folder=project.path(d.parent==""?".":d.parent,name,allocator=context.temp_allocator)}
    folder=project.path_absolute(folder,allocator)
    report.folder=folder
    if os.exists(folder) && !os.is_dir(folder) {
        error=fmt.aprintf("%s is a file: give the join a folder",folder,allocator=allocator)
        return
    }
    // Its state and temporary files are not written through a link either.
    names:=project.FOLDER_NAMES
    for part in ([2]string{"tmp",SHARE_FOLDER}) {
        if link:=link_on(folder,fmt.tprintf("%s/%s",names[.Generated],part));link!="" {
            error=fmt.aprintf("%s is a link, and a join never writes through a link inside its folder: replace it with a folder of its own and run the join again",link,allocator=allocator)
            return
        }
    }
    node_serve(n,address)
    if d.own_offer!="" {
        if put_error:=offer_set(n.s,folder,d.own_offer,address,name);put_error!=.None {
            return report,fmt.aprintf("the project offer could not be kept in the store (%v)",put_error,allocator=allocator)
        }
    }
    // What a join stopped in the middle of a write left.
    temp_folder:=project.path(project.folder_path(folder,.Generated,context.temp_allocator),"tmp",allocator=context.temp_allocator)
    if left,list_error:=os.read_all_directory_by_path(temp_folder,context.temp_allocator);list_error==nil {
        for info in left {
            if strings.has_prefix(info.name,"share-") {os.remove(info.fullpath)}
        }
    }

    // The base as a tree in the store, so what the host did not change since is
    // not asked; then the snapshot, a depth of folders at a time.
    index:=index_load(folder,context.temp_allocator)
    last:Snapshot
    if previous,read_error:=os.read_entire_file(share_path(folder,"snapshot",context.temp_allocator),context.temp_allocator);read_error==nil {
        last,_=snapshot_decode(previous,context.temp_allocator)
    }
    // A base whose files are out of order or fold to one is no base.
    if _,base_error:=snapshot_put(n.s,&last);base_error!=.None {last={}}
    fetching:=Tree_Fetching{d=&d,allocator=allocator}
    folders:=make([dynamic]store.Hash,context.temp_allocator)
    snap,tree_error:=snapshot_read(n.s,address,name,{procedure=join_tree_fetch,data=&fetching},&folders,allocator)
    if tree_error==.Missing && fetching.error!="" {
        error=fetching.error
        return
    }
    if tree_error!=.None {
        error=refused(tree_error,allocator)
        return
    }
    report.files=len(snap.entries)
    node_serve(n,..folders[:])
    plan:=join_plan(&snap,&last,&index,folder,&report,allocator)
    types:asset.Types
    asset.types_init(&types)
    defer asset.types_destroy(&types)
    asset_driver:=kai_assets.Asset_Driver{types=&types}
    drivers:=[1]vcs.Driver{kai_assets.driver(&asset_driver)}
    plan.drivers=drivers[:]
    if error=join_room(&d,&snap,&plan,folder,allocator);error!="" {return}

    // The files, smallest first, then what the host removed.
    error=join_files(&d,&snap,&plan,&index,folder,&report,allocator)
    if error=="" {join_remove(&last,&plan,&index,folder,&report)}
    base_save(folder,&snap,&last,&plan)
    index_save(folder,&index)
    if error!="" {return}

    // The packages, their builds from the peers, once every file is here: a
    // source some of whose files did not arrive would import other assets.
    if len(report.failed)>0 {
        say(&d,"the packages are refreshed once every file is written")
        return
    }
    if os.exists(project.path(folder,asset.PACKAGES_FILE,allocator=context.temp_allocator)) {
        say(&d,"refreshing the packages of the project")
        progress_phase(&d,.Packages,&report)
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

// The snapshot, the project's name and the kind of offer, asked of the host's
// authenticated connection.
@(private)
join_offer :: proc(d:^Join_Desc,allocator:runtime.Allocator) -> (address:store.Hash,name:string,error:string) {
    n:=d.node
    host,connection,connected:=node_host_peer(n)
    if !connected {return {},"",refusal(.Timeout,allocator)}
    q,ask_error:=exchange.ref_ask(&n.x,NAMESPACE,d.offer,host,connection)
    if ask_error!=.None {return {},"",fmt.aprintf("the snapshot could not be asked for (%v)",ask_error,allocator=allocator)}
    defer exchange.query_end(&n.x,q)
    for {
        result,ok:=exchange.query_result(&n.x,q)
        if !ok {return {},"",strings.clone("the question for the snapshot was lost",allocator)}
        switch result.state {
        case .Found:
            roots:=[1]store.Hash{result.address}
            if error=join_fetch(d,roots[:],"the project offer",allocator,OFFER_BYTES_MAX);error!="" {return}
            kind:Offer_Kind
            read_error:store.Error
            address,kind,name,read_error=offer_read(n.s,result.address,allocator)
            if read_error!=.None {
                return {},"",fmt.aprintf("the project offer is invalid (%v): the host runs another version of Mirai, or is not honest",read_error,allocator=allocator)
            }
            if d.require_live && kind!=.Live {
                return {},"",strings.clone("this invitation shares files. Use mirai join.",allocator)
            }
            return
        case .Not_Found: return {},"",strings.clone("the host offers no project under this invitation, or did not answer: its share ended and another runs; ask for its new invitation",allocator)
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

// Why a snapshot the host sent is refused.
@(private)
refused :: proc(error:vcs.Error,allocator:runtime.Allocator) -> string {
    return fmt.aprintf("the host sent a snapshot this engine refuses (%v): it was not written; the host runs another version of Mirai, or is not honest",error,allocator=allocator)
}

@(private)
Tree_Fetching :: struct {d:^Join_Desc,error:string,allocator:runtime.Allocator}

@(private)
join_tree_fetch :: proc(data:rawptr,addresses:[]store.Hash) -> bool {
    f:=(^Tree_Fetching)(data)
    f.error=join_fetch(f.d,addresses,"the snapshot",f.allocator)
    return f.error==""
}

// Fetches the folders of a snapshot at addresses from the peers, WINDOW at a
// time; one whose object is larger than a folder's is refused.
@(private)
join_fetch :: proc(d:^Join_Desc,addresses:[]store.Hash,what:string,allocator:runtime.Allocator,limit:=i64(vcs.FOLDER_BYTES_MAX)) -> string {
    n:=d.node
    Active :: struct {address:store.Hash,missing:f64}
    active:=make([dynamic]Active,context.temp_allocator)
    defer for a in active {exchange.forget(&n.x,a.address)}
    // Identical folders share an address. The exchange keeps one want per address.
    seen:=make(map[store.Hash]bool,len(addresses),context.temp_allocator)
    defer delete(seen)
    next,complete:=0,0
    stall:Stall
    for next<len(addresses) || len(active)>0 {
        for len(active)<WINDOW && next<len(addresses) {
            address:=addresses[next]
            if address not_in seen {
                if exchange.want(&n.x,address,1<<20)!=.None {break}
                seen[address]=true
                append(&active,Active{address,-1})
            }
            next+=1
        }
        for k:=0;k<len(active); {
            a:=&active[k]
            p,_:=exchange.progress(&n.x,a.address)
            if p.total>limit {
                return fmt.aprintf("the host sent %s of %d bytes, more than the %d this engine takes",what,p.total,limit,allocator=allocator)
            }
            #partial switch p.state {
            case .Complete:
                exchange.forget(&n.x,a.address)
                unordered_remove(&active,k)
                complete+=1
                continue
            case .Failed:
                return fmt.aprintf("%s could not be kept in the store at %s (%v, %v): free space there",what,n.s.root,p.error,p.store_error,allocator=allocator)
            }
            if join_missing(d,p.state,&a.missing) {return fmt.aprintf("no connected peer has %s: the host changed it while this join ran; run the join again",what,allocator=allocator)}
            k+=1
        }
        if len(active)==0 && next==len(addresses) {break}
        if stalled(d,&stall,complete) {return fmt.aprintf("no connected peer sent any of %s for %.0f s: the host withholds it, or stopped; run the join again",what,STALL_SECONDS,allocator=allocator)}
        if error:=join_alive(d,allocator);error!="" {return error}
    }
    return ""
}

// Whether the join made no progress for STALL_SECONDS: no chunk byte received
// from any peer and no object complete, whatever the peers do or withhold.
@(private)
Stall :: struct {at:f64,received:u64,complete:int}

@(private)
stalled :: proc(d:^Join_Desc,s:^Stall,complete:int) -> bool {
    now:=node_now(d.node)
    received:=node_totals(d.node).received
    if s.at==0 || received!=s.received || complete!=s.complete {
        s^={at=now,received=received,complete=complete}
        return false
    }
    return now-s.at>=STALL_SECONDS
}

// Whether an object stayed missing at every connected peer for MISSING_SECONDS.
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
        if link_refused(report,folder,e.path) {
            append(&plan.write,Write{at=at,refused=true})
            continue
        }
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
        case based:
            append(&plan.write,Write{at=at,present=true,base=here,merge=true,origin=base.address})
        case:
            kept(report,"%s: you changed it and the host has another one; yours is kept",e.path)
        }
    }
    for &e,at in last.entries {
        if _,still:=snapshot_find(snap,e.path);still {continue}
        // Renamed by the host changing only its case: on this system it is the same file.
        if plan.folds && strings.to_lower(e.path,context.temp_allocator) in plan.snap_folded {continue}
        if link_refused(report,folder,e.path) {
            append(&plan.remove,Remove{at=at,refused=true})
            continue
        }
        here,_,present:=index_address(index,e.path,project.path(folder,e.path,allocator=context.temp_allocator))
        switch {
        case !present:
        case here==e.address: append(&plan.remove,Remove{at=at})
        case: kept(report,"%s: the host removed it and you changed it; yours is kept",e.path)
        }
    }
    return
}

// The first part of relative under folder that is a link (a symbolic link, or
// a junction on Windows), as a path; "" when none. The folder itself may be
// one: it is the place the joiner named.
@(private)
link_on :: proc(folder,relative:string) -> string {
    for at in 1..=len(relative) {
        if at<len(relative) && relative[at]!='/' {continue}
        path:=project.path(folder,relative[:at],allocator=context.temp_allocator)
        info,error:=os.lstat(path,context.temp_allocator)
        // What does not exist holds nothing below it.
        if error!=nil {return ""}
        if info.type==.Symlink {return path}
    }
    return ""
}

// Whether the path of an entry passes through a link inside folder, which a
// join never follows: reported with how to fix it.
@(private)
link_refused :: proc(report:^Join_Report,folder,relative:string) -> bool {
    link:=link_on(folder,relative)
    if link=="" {return false}
    failed(report,"%s: %s is a link, and a join never writes or removes through a link inside its folder: replace it with a folder or file of its own and run the join again",relative,link)
    return true
}

// The entry of path in the last snapshot, under any case where the system folds it.
@(private)
base_find :: proc(plan:^Plan,last:^Snapshot,path:string) -> (^vcs.File,bool) {
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
        if len(old)!=len(e.path) || link_on(folder,old)!="" {continue}
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
    // The root read once: each file then asks only what this value knows.
    store.chunk_has(s,{})
    for w in plan.write {
        if w.refused {continue}
        e:=&snap.entries[w.at]
        write+=i64(e.size)
        if e.address in seen || store.chunk_here(s,e.address) {continue}
        seen[e.address]=true
        fetch+=i64(e.size)
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

// Fetches the objects of the files to write, WINDOW at once: the project's
// manifest and its start scene first, then the others smallest first; each
// file is written as its object completes. A file whose object does not come
// is reported and the others go on; the error is what stops the whole join.
@(private)
join_files :: proc(d:^Join_Desc,snap:^Snapshot,plan:^Plan,index:^Index,folder:string,report:^Join_Report,allocator:runtime.Allocator) -> string {
    n:=d.node
    s:=n.s
    // The writes of each address, and the addresses to fetch in order.
    paths:=make(map[store.Hash][dynamic]int,context.temp_allocator)
    order:=make([dynamic]int,context.temp_allocator)
    total:i64
    for w,k in plan.write {
        if w.refused {continue}
        e:=&snap.entries[w.at]
        if e.size==0 {
            one:=[1]int{k}
            join_write(d,snap,plan,one[:],index,folder,report)
            continue
        }
        list,known:=&paths[e.address]
        if !known {
            paths[e.address]=make([dynamic]int,context.temp_allocator)
            list=&paths[e.address]
            append(&order,k)
            if !store.chunk_here(s,e.address) {total+=i64(e.size)}
        }
        append(list,k)
    }
    if len(order)==0 {return ""}
    scene:=join_scene(d,snap,index,folder)
    Sized :: struct {first:bool,size:i64,k:int}
    sized:=make([]Sized,len(order),context.temp_allocator)
    for k,at in order {
        e:=&snap.entries[plan.write[k].at]
        sized[at]={e.path==project.PROJECT_FILE || e.path==scene,i64(e.size),k}
    }
    slice.sort_by(sized,proc(a,b:Sized) -> bool {
        if a.first!=b.first {return a.first}
        return a.size<b.size || a.size==b.size && a.k<b.k
    })
    for one,at in sized {order[at]=one.k}
    say(d,"fetching %d files, %s",len(order),bytes_text(total))
    progress_set(d,{phase=.Files,files=len(order),bytes=total,left=-1,kept=len(report.kept)})
    Active :: struct {k:int,missing:f64}
    active:=make([dynamic]Active,context.temp_allocator)
    // What arrived, which the lease of the node holds from the end on.
    complete:=make([dynamic]store.Hash,context.temp_allocator)
    defer node_serve(n,..complete[:])
    next,complete_count:=0,0
    stall:Stall
    done:i64
    started:=node_now(n)
    totals:=node_totals(n)
    received_at,printed:=totals.received,started
    rate:f64
    for next<len(order) || len(active)>0 {
        for len(active)<WINDOW && next<len(order) {
            e:=&snap.entries[plan.write[order[next]].at]
            join_reuse(d,snap,plan,paths[e.address][:],folder)
            // Earlier first: the priority falls with the place in the order.
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
                join_write(d,snap,plan,list,index,folder,report)
                append(&complete,e.address)
                complete_count+=1
                report.fetched+=i64(e.size)
                done+=i64(e.size)
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
            say(d,"%d of %d files, %s of %s, %s/s, %s left",next-len(active),len(order),bytes_text(done+here),bytes_text(total),bytes_text(i64(rate)),eta<0?"time":seconds_text(max(eta,0)))
        }
        if d.progress!=nil {
            left:=total-done-here
            progress_set(d,{phase=.Files,files=len(order),files_done=complete_count,bytes=total,bytes_done=done+here,received=node_totals(n).received,rate=rate,left=rate>0?f64(left)/rate:-1,kept=len(report.kept)})
        }
        if len(active)==0 && next==len(order) {break}
        // Nothing arrives: what is wanted fails by path, and the files after it are asked.
        if stalled(d,&stall,complete_count) {
            for a in active {
                e:=&snap.entries[plan.write[a.k].at]
                for w in paths[e.address] {failed(report,"%s: no connected peer sent any of it for %.0f s: the host withholds it, or stopped; run the join again",snap.entries[plan.write[w].at].path,STALL_SECONDS)}
                exchange.forget(&n.x,e.address)
            }
            clear(&active)
            stall={}
            continue
        }
        if error:=join_alive(d,allocator);error!="" {return error}
    }
    elapsed:=node_now(n)-started
    say(d,"fetched %d files, %s in %s (%s/s)",len(order),bytes_text(total),seconds_text(elapsed),bytes_text(i64(f64(total)/max(elapsed,1e-3))))
    return ""
}

// The path of the scene the project's manifest starts with, "" when it names
// none: read from the folder when the file there is the host's, otherwise
// fetched first.
@(private)
join_scene :: proc(d:^Join_Desc,snap:^Snapshot,index:^Index,folder:string) -> string {
    e,found:=snapshot_find(snap,project.PROJECT_FILE)
    if !found || e.size>1<<20 {return ""}
    path:=project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS): each manifest is read where it is declared.
    if here,_,present:=index_address(index,project.PROJECT_FILE,path);present && here==e.address {
        m,read_error:=project.manifest_read(path)
        if read_error.code!=.None {return ""}
        return start_scene(&m)
    }
    roots:=[1]store.Hash{e.address}
    if join_fetch(d,roots[:],project.PROJECT_FILE,context.temp_allocator)!="" {return ""}
    o,open_error:=store.object_open(d.node.s,e.address)
    if open_error!=.None {return ""}
    defer store.object_close(&o)
    text:=make([]u8,int(store.object_size(&o)),context.temp_allocator)
    if store.object_read(&o,0,text)!=.None {return ""}
    m,parse_error:=project.manifest_parse(string(text))
    if parse_error.code!=.None {return ""}
    return start_scene(&m)
}

// The path of the start scene of a manifest, in the temp allocator; "": none.
@(private)
start_scene :: proc(m:^project.Manifest) -> string {
    scene:=base.text_get(m.start_scene[:])
    if scene=="" {return ""}
    return fmt.tprintf("assets/%s",scene)
}

// Puts in the store the file the joiner has of the writes of list where the
// store lacks the base it was planned at, cut as the host's is: the chunks its
// old version shares with the new are then not asked.
@(private)
join_reuse :: proc(d:^Join_Desc,snap:^Snapshot,plan:^Plan,list:[]int,folder:string) {
    s:=d.node.s
    for k in list {
        w:=&plan.write[k]
        if !w.present || store.chunk_here(s,w.base) {continue}
        file_put_object(s,project.path(folder,snap.entries[w.at].path,allocator=context.temp_allocator))
        store.commit(s)
        return
    }
}

// Writes the planned writes list of a complete object into the folder, each
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
        if w.refused {continue}
        e:=&snap.entries[w.at]
        target:=project.path(folder,e.path,allocator=context.temp_allocator)
        if link_refused(report,folder,e.path) {continue}
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
        temp:=fmt.tprintf("%s/share-%d-%d",temp_folder,os.get_pid(),w.at)
        mode:=os.Permissions_Default_File
        if e.kind==.Executable {mode+=os.Permissions_Execute_All}
        #partial switch saved,store_error,os_error:=object_save(s,e.address,i64(e.size),temp);saved {
        case .None:
        case .Size:
            os.remove(temp)
            failed(report,"%s: the snapshot says %d bytes and its object has others: the host is not honest; it was not written",e.path,e.size)
            continue
        case .Store:
            os.remove(temp)
            failed(report,"%s: its object does not read from the store at %s (%v): run the join again",e.path,s.root,store_error)
            continue
        case:
            os.remove(temp)
            failed(report,"%s could not be written (%v): free space on its disk, or give this user access to %s, and run the join again",target,os_error,temp_folder)
            continue
        }
        if w.merge && !join_merge(plan,s,e,w,target,temp) {
            os.remove(temp)
            kept(report,"%s: you changed it and the host has another one, and they do not merge; yours is kept",e.path)
            w.done=true
            continue
        }
        os.change_mode(temp,mode)
        if h:=d.node.hooks;h!=nil && h.saved!=nil {h.saved(h.data,e.path)}
        // The copy of a large file takes time: an edit made meanwhile is kept too.
        if again,_,still:=index_address(index,e.path,target);still!=present || still && again!=here {
            os.remove(temp)
            if !still || again!=e.address {kept(report,"%s: you changed it while the join ran; yours is kept",e.path)}
            w.done=true
            continue
        }
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
        // A link made inside the folder while the file was written is not followed either.
        if link_refused(report,folder,e.path) {
            os.remove(temp)
            continue
        }
        if rename_error:=os.rename(temp,target);rename_error!=nil {
            os.remove(temp)
            failed(report,"%s could not be replaced (%v): close what holds it, or give this user access, and run the join again",target,rename_error)
            continue
        }
        if w.merge {
            // Its address is the merge's, read the next time.
            delete_key(index,e.path)
            report.merged+=1
        } else if info,stat_error:=os.stat(target,context.temp_allocator);stat_error==nil {
            index_learn(index,e.path,info,e.address)
        }
        report.written+=1
        w.done=true
    }
}

// Merges into temp, which holds the host's file, the joiner's at target and
// their base, the entry of the last snapshot: false when the base is gone
// from the store, a side does not read or the drivers do not resolve it.
@(private)
join_merge :: proc(plan:^Plan,s:^store.Store,e:^vcs.File,w:^Write,target,temp:string) -> bool {
    if e.size>vcs.DRIVER_BYTES_MAX {return false}
    origin,origin_error:=vcs.file_bytes(s,w.origin,context.temp_allocator)
    if origin_error!=.None {return false}
    ours,ours_error:=os.read_entire_file(target,context.temp_allocator)
    if ours_error!=nil || len(ours)>vcs.DRIVER_BYTES_MAX {return false}
    theirs,theirs_error:=os.read_entire_file(temp,context.temp_allocator)
    if theirs_error!=nil {return false}
    input:=vcs.Driver_Input{path=e.path,base=origin,ours=ours,theirs=theirs,has_base=true,terms={w.origin,w.base,e.address}}
    out:=make([dynamic]u8,context.temp_allocator)
    if result,_:=vcs.drivers_merge(plan.drivers,&input,&out);result!=.Resolved {return false}
    return os.write_entire_file(temp,out[:])==nil
}

@(private)
Save_Error :: enum u8 {None,Size,Store,Write}

// Writes the object at address, of size bytes, into a new file at path chunk
// by chunk at the offset of each, walking its tree one node per level: what
// it holds does not grow with the file. Size: the object holds other bytes.
@(private)
object_save :: proc(s:^store.Store,address:store.Hash,size:i64,path:string) -> (error:Save_Error,store_error:store.Error,os_error:os.Error) {
    if size==0 {
        if os_error=os.write_entire_file(path,nil);os_error!=nil {return .Write,.None,os_error}
        return
    }
    o,open_error:=store.object_open(s,address)
    if open_error!=.None {return .Store,open_error,nil}
    defer store.object_close(&o)
    if store.object_size(&o)!=u64(size) {return .Size,.None,nil}
    file,create_error:=os.open(path,{.Write,.Create,.Trunc},os.Permissions_Default_File)
    if create_error!=nil {return .Write,.None,create_error}
    defer os.close(file)
    if os_error=os.truncate(file,size);os_error!=nil {return .Write,.None,os_error}
    Frame :: struct {node:store.Node_View,next:int}
    stack:[store.NODE_LEVEL_MAX+1]Frame
    buffers:[store.NODE_LEVEL_MAX+1][]u8
    defer for b in buffers {delete(b,context.temp_allocator)}
    chunk,_:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    defer delete(chunk,context.temp_allocator)
    stack[0]={node=o.root}
    depth:=1
    at:i64
    for depth>0 {
        top:=&stack[depth-1]
        if top.next==len(top.node.entries) {
            depth-=1
            continue
        }
        e:=top.node.entries[top.next]
        top.next+=1
        level:=top.node.level
        if level==0 {
            bytes,read_error:=store.chunk_read(s,e.address,chunk)
            if read_error!=.None {return .Store,read_error,nil}
            if u64(len(bytes))!=e.size {return .Store,.Corrupt,nil}
            for written:=0;written<len(bytes); {
                n,write_error:=os.write_at(file,bytes[written:],at+i64(written))
                if write_error!=nil {return .Write,.None,write_error}
                written+=n
            }
            at+=i64(len(bytes))
            continue
        }
        if buffers[level-1]==nil {buffers[level-1],_=make([]u8,store.CHUNK_MAX,context.temp_allocator)}
        bytes,read_error:=store.chunk_read(s,e.address,buffers[level-1])
        if read_error!=.None {return .Store,read_error,nil}
        child,parse_error:=store.node_parse(bytes)
        if parse_error!=.None || child.level!=level-1 || child.total!=e.size || len(child.groups)>0 || len(child.meta)>0 {return .Store,.Corrupt,nil}
        stack[depth]={node=child}
        depth+=1
    }
    if at!=size {return .Size,.None,nil}
    return
}

// Removes what the host removed, unless the joiner changed it since the plan
// or it cannot be removed, which is reported with how to fix it.
@(private)
join_remove :: proc(last:^Snapshot,plan:^Plan,index:^Index,folder:string,report:^Join_Report) {
    for &r in plan.remove {
        if r.refused {continue}
        e:=&last.entries[r.at]
        target:=project.path(folder,e.path,allocator=context.temp_allocator)
        if link_refused(report,folder,e.path) {continue}
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
    entries:=make([dynamic]vcs.File,0,len(snap.entries)+len(plan.remove),context.temp_allocator)
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
    slice.sort_by(entries[:],proc(a,b:vcs.File) -> bool {return a.path<b.path})
    if bytes:=snapshot_encode({name=snap.name,entries=entries[:]},context.temp_allocator);bytes!=nil {
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
// of its own, while this one says how far it is: as an editor refreshes them,
// a Final or a Fast build taken from the store and then from the peers, and a
// source imported only when none gives one, in the quality an editor imports.
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
    work.options={store=n.s,source=node_source(n),fast_textures=true,root=folder,plugins=d.library,worker=d.worker,gpu=d.gpu,progress=d.output}
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
        rate:=f64(t.received-last)/(now-printed)
        if t.received!=last {say(d,"builds: %s received, %s/s",bytes_text(i64(t.received-from)),bytes_text(i64(rate)))}
        last,printed=t.received,now
        if d.progress!=nil {
            sync.mutex_guard(&d.progress.lock)
            d.progress.state.received,d.progress.state.rate=t.received-from,rate
        }
    }
    thread.join(t)
    thread.destroy(t)
    return work.report
}

Offer_Kind :: enum u8 {Project,Live}

// An offer is one object: {version: u8, kind: u8, root: [32]u8, name_len: u8,
// name}, the root of the snapshot's tree and the name of its project.
@(private) OFFER_VERSION :: 3
@(private) OFFER_BYTES_MAX :: 2+32+1+NAME_MAX

@(private)
offer_read :: proc(s:^store.Store,object:store.Hash,allocator:=context.allocator) -> (address:store.Hash,kind:Offer_Kind,name:string,error:store.Error) {
    o:=store.object_open(s,object) or_return
    defer store.object_close(&o)
    size:=int(min(store.object_size(&o),OFFER_BYTES_MAX+1))
    if size<2+32+1 || size>OFFER_BYTES_MAX {return {},{},"",.Corrupt}
    bytes:[OFFER_BYTES_MAX]u8
    store.object_read(&o,0,bytes[:size]) or_return
    copy(address[:],bytes[2:])
    name=string(bytes[2+32+1:size])
    if bytes[0]!=OFFER_VERSION || bytes[1]>u8(Offer_Kind.Live) || address=={} || int(bytes[2+32])!=len(name) || !name_valid(name) {return {},{},"",.Corrupt}
    return address,Offer_Kind(bytes[1]),strings.clone(name,allocator),.None
}

// The offer of this kind of the snapshot at address of the project named
// project replaces the previous one of the folder.
offer_set :: proc(s:^store.Store,folder,name:string,address:store.Hash,project_name:string,kind:=Offer_Kind.Project) -> store.Error {
    if !name_valid(project_name) {return .Invalid_Argument}
    address:=address
    bytes:[OFFER_BYTES_MAX]u8
    bytes[0],bytes[1]=OFFER_VERSION,u8(kind)
    copy(bytes[2:],address[:])
    bytes[2+32]=u8(len(project_name))
    size:=2+32+1+copy(bytes[2+32+1:],project_name)
    object:=store.put(s,bytes[:size]) or_return
    store.ref_set(s,NAMESPACE,name,object) or_return
    file:=share_path(folder,"live-offer" if kind==.Live else "offer",context.temp_allocator)
    if previous,error:=os.read_entire_file(file,context.temp_allocator);error==nil && string(previous)!=name && store.name_valid(string(previous)) {
        store.ref_remove(s,NAMESPACE,string(previous))
    }
    file_save(file,transmute([]u8)name)
    return .None
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
