package editor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "mirai:cook/share"
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
    o,error:=share.offer(st.node,s.project_root,st.invite,worker,context.temp_allocator)
    for line in o.taken.skipped {log.warnf("the session does not carry it: %s",line)}
    for line in o.problems {log.warnf("a guest will not get it: %s",line)}
    return error
}

// A guest's join of the snapshot the host offers under the token of its invitation, into folder.
@(private)
collab_join_start :: proc(s:^Session,st:^Collab_State,code,folder:string,reopen:bool) -> bool {
    j:=new(Collab_Join)
    base.text_set(j.code[:],code)
    mem.dynamic_arena_init(&j.arena,runtime.heap_allocator(),runtime.heap_allocator())
    j.allocator=base.dynamic_arena_allocator(&j.arena)
    j.folder=fmt.aprint(folder,allocator=j.allocator)
    j.reopen=reopen
    j.desc={node=st.node,offer=share.offer_name(st.invite,&j.digits),folder=j.folder,progress=&j.progress,connect_seconds=COLLAB_HELLO_TIMEOUT}
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
    j:=st.join
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
    if j:=st.join;j!=nil {
        if j.thread!=nil {
            thread.join(j.thread)
            thread.destroy(j.thread)
        }
        mem.dynamic_arena_destroy(&j.arena)
        free(j)
        st.join=nil
    }
    if st.node!=nil {
        if st.role==.Host && s.store.root!="" {
            digits:[64]u8
            store.ref_remove(&s.store,share.NAMESPACE,share.offer_name(st.invite,&digits))
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
