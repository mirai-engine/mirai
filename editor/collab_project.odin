package editor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "mirai:cook/share"
import "mirai:platform"
import wire "mirai:net"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/jobs"
import "mirai:store"

// The project travels with the session, as mirai share and mirai join carry
// it (cook/share): the host's net host also carries the channels of the
// exchange, and a node of cook/share over it serves the snapshot of the
// project and the library of the store the editor started with. A guest,
// before it says Hello, brings a folder to that snapshot with the join of
// cook/share: its open project, by three ways, or a folder it names, which it
// opens once the join is done and joins the session again from there.

COLLAB_EXCHANGE_CHANNEL :: 2 // where the channels of the exchange start
COLLAB_LINES :: 8            // kept, failed and missing lines collab.status gives
COLLAB_LINE_BYTES :: 200
// What the host changes during the session reaches the guests: once its files
// are quiet for COLLAB_OFFER_QUIET it takes the snapshot again, at most once a
// COLLAB_OFFER_EVERY, and tells the guests in the session when it differs;
// a guest joins it again as soon as the update it runs ends.
COLLAB_OFFER_QUIET :: 0.5 // seconds
COLLAB_OFFER_EVERY :: 2.0 // seconds
@(private) COLLAB_WATCH_BUDGET :: 512

@(private)
collab_channels :: proc() -> (channels:[COLLAB_EXCHANGE_CHANNEL+2]wire.Channel_Desc) {
    channels[0]={kind=.Reliable,queue_bytes=256<<10}
    channels[1]={kind=.Unreliable}
    exchange_channels:=share.channels()
    channels[COLLAB_EXCHANGE_CHANNEL]=exchange_channels[0]
    channels[COLLAB_EXCHANGE_CHANNEL+1]=exchange_channels[1]
    return
}

// A guest's join: on a thread of its own, which waits for the steps of the node.
@(private)
Collab_Join :: struct {
    desc:share.Join_Desc,
    progress:share.Join_Progress,
    report:share.Join_Report,
    error:string,
    done:bool,
    thread:^thread.Thread,
    arena:mem.Dynamic_Arena,
    allocator:runtime.Allocator,
    digits:[64]u8,
    code:[64]u8,    // of the invitation, which the editor opened on folder joins with
    folder:string,  // where the join writes
    reopen:bool,    // folder is not the open project: it is opened once the join is done
    update:bool,    // of a guest in the session, after the host offered a new snapshot
    opening:bool,   // and its editor library is being built to open it
    finished:bool,  // the end of the join was taken on the editor's thread
}

// The node of a session over its host: what this editor serves and fetches.
@(private)
collab_node_start :: proc(s:^Session,st:^Collab_State) -> bool {
    // The exchange reads, hashes and stores on jobs of its own, which this thread owns as it
    // pumps; on the network of a test they run on the pump, as the tests of the exchange do.
    worker:=jobs.Worker_Ref{}
    if !st.virtual {st.node_jobs=new(jobs.Job_System)}
    if st.node_jobs!=nil && jobs.system_init(st.node_jobs,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()}) {
        worker={system=st.node_jobs,worker=jobs.OWNER}
    } else if st.node_jobs!=nil {
        free(st.node_jobs)
        st.node_jobs=nil
    }
    st.node=new(share.Node)
    if share.node_init(st.node,&s.store,runtime.heap_allocator(),worker,COLLAB_EXCHANGE_CHANNEL)!=.None {
        free(st.node)
        st.node=nil
        return false
    }
    return true
}

// The host offers its project under the token of the session: its snapshot,
// with what its packages need, held by the lease of the node.
@(private)
collab_project_offer :: proc(s:^Session,st:^Collab_State) -> (problem:string) {
    js:jobs.Job_System
    threaded:=jobs.system_init(&js,{threads=jobs.THREADS_AUTO,allocator=runtime.heap_allocator()})
    defer if threaded {jobs.system_destroy(&js)}
    worker:=jobs.Worker_Ref{}
    if threaded {worker={system=&js,worker=jobs.OWNER}}
    o,error:=share.offer(st.node,s.project_root,st.invite.secret,worker,context.temp_allocator)
    for line in o.taken.skipped {log.warnf("the session does not carry it: %s",line)}
    for line in o.problems {log.warnf("a guest will not get it: %s",line)}
    if error=="" {st.offered=o.address}
    return error
}

// The host watches the files of its project; without a platform (a test) it is told with collab_project_touched.
@(private)
collab_watch_start :: proc(s:^Session,st:^Collab_State) {
    if s.app.platform==nil {return}
    watch,error:=platform.watch_create(s.app.platform,{path=s.project_root,recursive=true,file_capacity=1<<16})
    if error!=.None {
        log.warnf("the files of %s are not watched (%v): what changes on this side reaches the guests when they join again",s.project_root,error)
        return
    }
    st.watch,st.watching=watch,true
}

// A file of the host's project changed: the next quiet moment offers the snapshot again.
collab_project_touched :: proc(s:^Session) {
    st:=collab_state(s)
    if st!=nil && st.role==.Host && st.phase==.Joined {st.changed_at=max(collab_now(st),1e-9)}
}

// The host: what changed in its folder, and a new snapshot offered to the guests when it differs.
@(private)
collab_host_changes :: proc(s:^Session,st:^Collab_State,now:f64) {
    if st.watching {
        events:[64]platform.Watch_Event
        count,_:=platform.watch_poll(s.app.platform,st.watch,COLLAB_WATCH_BUDGET,events[:])
        for e in events[:count] {
            if project.own_path(e.path) {st.changed_at=now;break}
        }
    }
    if st.changed_at==0 || now-st.changed_at<COLLAB_OFFER_QUIET || now-st.offered_at<COLLAB_OFFER_EVERY {return}
    st.changed_at,st.offered_at=0,now
    before:=st.offered
    if problem:=collab_project_offer(s,st);problem!="" {
        log.warnf("the project could not be offered again: %s",problem)
        return
    }
    if st.offered==before {return}
    st.offers+=1
    m:=[1]u8{u8(Collab_Message.Project)}
    for &peer,i in st.peers {
        if i!=0 && peer.used && peer.joined {collab_queue(&peer,m[:])}
    }
}

// A guest told of a new snapshot updates its open project to it, after the update it runs.
@(private)
collab_update_request :: proc(st:^Collab_State) {
    if st.role==.Guest && st.phase==.Joined {st.update_due=true}
}

// A guest's join of the snapshot the host offers under the token of its invitation, into folder.
@(private)
collab_join_start :: proc(s:^Session,st:^Collab_State,code,folder:string,reopen:bool,update:=false) -> bool {
    j:=new(Collab_Join)
    j.update=update
    base.text_set(j.code[:],code)
    mem.dynamic_arena_init(&j.arena,runtime.heap_allocator(),runtime.heap_allocator())
    j.allocator=base.dynamic_arena_allocator(&j.arena)
    j.folder=fmt.aprint(folder,allocator=j.allocator)
    j.reopen=reopen
    j.desc={node=st.node,offer=share.offer_name(st.invite.secret,&j.digits),folder=j.folder,progress=&j.progress,connect_seconds=COLLAB_HELLO_TIMEOUT}
    // The importers of the project's plugins, for a package no peer has a build of.
    if s.has_project {j.desc.library=import_library}
    st.join=j
    // With a context of its own: the temp allocator of the editor's is freed every frame.
    j.thread=thread.create_and_start_with_poly_data(j,proc(j:^Collab_Join) {
        defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
        js:jobs.Job_System
        // A core stays with the editor, which keeps drawing.
        threaded:=jobs.system_init(&js,{threads=max(os.get_processor_core_count()-2,0),allocator=runtime.heap_allocator()})
        if threaded {j.desc.worker={system=&js,worker=jobs.OWNER}}
        j.report,j.error=share.join(j.desc,j.allocator)
        j.desc.worker={}
        if threaded {jobs.system_destroy(&js)}
        sync.atomic_store(&j.done,true)
    })
    return j.thread!=nil
}

// The node stepped after the host was polled, and the end of a guest's join
// taken: the open project relisted and the Hello sent, or the folder opened.
@(private)
collab_project_update :: proc(s:^Session,st:^Collab_State,now:f64) {
    if st.node==nil {return}
    share.node_step(st.node,now)
    if st.role==.Host {
        collab_host_changes(s,st,now)
        return
    }
    j:=st.join
    if st.update_due && (j==nil || j.finished) {
        st.update_due=false
        code:=j!=nil?j.code:{}
        if j!=nil {collab_join_free(j)}
        st.join=nil
        if !collab_join_start(s,st,base.text_get(code[:]),s.project_root,false,update=true) {log.warn("the project of the host could not be updated: no thread to do it on")}
        return
    }
    if j==nil {return}
    if j.opening {
        p:=s.projects
        if !projects_opening(p) && !p.next {collab_end(st,fmt.tprintf("%s could not be opened: %s",j.folder,string(p.error[:p.error_length])))}
        return
    }
    if j.finished || !sync.atomic_load(&j.done) {return}
    j.finished=true
    thread.join(j.thread)
    thread.destroy(j.thread)
    j.thread=nil
    for line in j.report.kept {log.infof("kept: %s",line)}
    for line in j.report.failed {log.warnf("not written: %s",line)}
    for line in j.report.packages.missing {log.warnf("%s",line)}
    if j.update {
        // What changed on disk reloads as any file changed on disk does; the packages are listed again.
        if j.error!="" {log.warnf("the project of the host could not be updated: %s",j.error)}
        library_relist(s,{root=s.project_root})
        st.updates+=1
        return
    }
    if j.error!="" {
        collab_end(st,fmt.tprintf("the project of the host could not be brought here: %s",j.error))
        return
    }
    if j.reopen {
        if problem:=projects_open(s,j.folder);problem!="" {
            collab_end(st,fmt.tprintf("the project of the host is in %s, which could not be opened: %s",j.folder,problem))
            return
        }
        s.projects.join=j.code
        c:=collab_of(s)
        base.text_set(s.projects.join_name[:],string(c.name[:c.name_length]))
        j.opening=true
        return
    }
    library_relist(s,{root=s.project_root})
    collab_hello(s,st)
}

// Stops the join, which ends at its next wait, and frees the node.
@(private)
collab_project_destroy :: proc(s:^Session,st:^Collab_State) {
    if st.node!=nil {share.node_close(st.node)}
    if st.watching {platform.watch_destroy(s.app.platform,st.watch)}
    st.watching=false
    if j:=st.join;j!=nil {
        collab_join_free(j)
        st.join=nil
    }
    if st.node!=nil {
        if st.role==.Host && s.store.root!="" {
            digits:[64]u8
            store.ref_remove(&s.store,share.NAMESPACE,share.offer_name(st.invite.secret,&digits))
        }
        share.node_destroy(st.node)
        free(st.node)
        st.node=nil
    }
    if st.node_jobs!=nil {
        jobs.system_destroy(st.node_jobs)
        free(st.node_jobs)
        st.node_jobs=nil
    }
}

@(private)
collab_join_free :: proc(j:^Collab_Join) {
    if j.thread!=nil {
        thread.join(j.thread)
        thread.destroy(j.thread)
    }
    mem.dynamic_arena_destroy(&j.arena)
    free(j)
}

// What a phase of a join is doing, as Session says it.
@(private)
collab_join_text :: proc(j:^Collab_Join) -> string {
    state:=share.join_progress_read(&j.progress)
    if j.opening {return fmt.tprintf("Opening %s...",project_name_of(j.folder))}
    switch state.phase {
    case .Connecting: return "Connecting..."
    case .Snapshot:   return "Asking for the project..."
    case .Files:
        left:=state.left>=0?fmt.tprintf(", %s left",share.seconds_text(state.left)):""
        return fmt.tprintf("Files: %d of %d, %s of %s, %s/s%s",state.files_done,state.files,share.bytes_text(state.bytes_done),share.bytes_text(state.bytes),share.bytes_text(i64(state.rate)),left)
    case .Packages:   return fmt.tprintf("Builds: %s, %s/s",share.bytes_text(i64(state.received)),share.bytes_text(i64(state.rate)))
    case .Done:
    }
    return ""
}

@(private)
project_name_of :: proc(folder:string) -> string {
    name:=os.base(folder)
    return name!=""?name:folder
}

// The folder a guest joins into: its open project when folder is empty or
// names it; another folder is opened once the join is done.
@(private)
collab_join_folder :: proc(s:^Session,folder:string) -> (target:string,reopen:bool) {
    if folder=="" {return s.project_root,false}
    absolute:=project.path_absolute(folder,context.temp_allocator)
    if s.has_project && project.path_same(absolute,s.project_root) {return s.project_root,false}
    return absolute,true
}
