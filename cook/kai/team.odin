package kai_assets

import "core:crypto"
import "core:os"
import "core:strings"
import "mirai:store"
import vcs "mirai:kai"

// What a team does with a project of an org, for the operations that need
// its workspace: joining the org, linking a second workspace, the private
// paths its snapshots route, the shared bookmarks and the devices' ones, and
// the names they are called by. What needs no workspace is in kai (machine_*
// and team.odin there); each operation tells the machine's runner through
// Machine.changed, and m.why says what failed and how to fix it.

// Routes the private paths of the workspace's snapshots by the scopes and
// keyrings its org has in the store now, when its repository is a project of
// an org; call it again after they change.
project_route :: proc(p:^Project) -> vcs.Error {
    route_drop(p)
    w:=&p.workspace
    project,org,ok:=vcs.store_project_of(w.repo.s,w.repo.id)
    if !ok {return .None}
    allocator:=w.allocator
    if e:=vcs.org_state_load(w.repo.s,org,&p.org,allocator);e!=.None {
        vcs.org_state_destroy(&p.org)
        return e
    }
    p.routed=true
    p.keyrings=make([dynamic]^vcs.Keyring_Fold,allocator)
    p.public_allow=make([dynamic]string,allocator)
    vcs.machine_keyrings(w.repo.s,&p.org,&p.keyrings,allocator) or_return
    device:=vcs.machine_device_of(w.repo.s) or_return
    for x in p.org.fold.publics {
        if x.project==project && x.fingerprint=={} {
            if _,e:=append(&p.public_allow,x.path);e!=nil {return .Out_Of_Memory}
        }
    }
    p.routing={org=&p.org.fold,project=project,keyrings=p.keyrings[:],device=device,public_allow=p.public_allow[:]}
    w.options.overlay=&p.routing
    return .None
}

@(private)
route_drop :: proc(p:^Project) {
    if !p.routed {return}
    p.workspace.options.overlay=nil
    for k in p.keyrings {
        l:=k.log
        vcs.keyring_fold_destroy(k)
        if l!=nil {
            vcs.log_destroy(l)
            free(l,p.workspace.allocator)
        }
        free(k,p.workspace.allocator)
    }
    delete(p.keyrings)
    delete(p.public_allow)
    vcs.org_state_destroy(&p.org)
    crypto.zero_explicit(&p.routing,size_of(p.routing))
    p.routing,p.routed={},false
}

// The project and org the workspace's repository is.
project_of :: proc(p:^Project,m:^vcs.Machine) -> (project,org:vcs.Log_Id,error:vcs.Error) {
    ok:bool
    if project,org,ok=vcs.machine_project_of(m,p.workspace.repo.id);!ok {
        m.why="this workspace is no project of an org: mirai kai org add makes it one, or mirai kai init <project> in a new folder links one"
        return {},{},.Missing
    }
    return
}

// Makes the workspace's repository a project of org, public or the org's
// alone, named as its folder; its bookmarks reach the org's peers.
project_join :: proc(p:^Project,m:^vcs.Machine,org:vcs.Log_Id,public:bool) -> (project:vcs.Log_Id,error:vcs.Error) {
    title:=strings.trim_right(p.workspace.root,"/\\")
    if cut:=strings.last_index_any(title,"/\\");cut>=0 {title=title[cut+1:]}
    project=vcs.machine_project_add(m,org,p.workspace.repo.id,title,public) or_return
    bookmarks_publish(p,m) or_return
    if e:=project_route(p);e!=.None {
        m.why="the org's scopes do not read: fetch the org's logs again"
        return project,e
    }
    return project,.None
}

// Makes the workspace's repository the project of an org another machine
// added, so this workspace works on it.
project_link :: proc(p:^Project,m:^vcs.Machine,project:vcs.Log_Id) -> vcs.Error {
    vcs.machine_project_link(m,p.workspace.repo.id,project) or_return
    if e:=project_route(p);e!=.None {
        m.why="the org's scopes do not read: fetch the org's logs again"
        return e
    }
    return .None
}

// Keeps path public though the deny set holds it, or, with line from 1,
// waives the leak the publish scanner found on that line of the file in the
// working copy.
public_add :: proc(p:^Project,m:^vcs.Machine,path:string,line:int) -> vcs.Error {
    project,org:=project_of(p,m) or_return
    if line<=0 {
        vcs.machine_public_add(m,org,project,path) or_return
        return project_route(p)
    }
    bytes,e:=os.read_entire_file(strings.concatenate({p.workspace.root,"/",path},context.temp_allocator),context.temp_allocator)
    if e!=nil {
        m.why="the file does not read in the working copy: give its path from the project's folder"
        return .Io
    }
    lines:=strings.split(string(bytes),"\n",context.temp_allocator)
    if line>len(lines) {
        m.why="the file has fewer lines"
        return .Invalid_Argument
    }
    vcs.machine_public_add(m,org,project,path,lines[line-1]) or_return
    return project_route(p)
}

// A bookmark of the project's log, shared by the org, or one a device
// published.
Shared_Bookmark :: struct {
    name:string,     // as it is called: main, or <handle>/<device>:<bookmark> for a device's
    bookmark:string,
    target:vcs.Revision,
    device:vcs.Key,  // zero for a bookmark of the project's log
    here:bool,       // its change is in the store
}

// The bookmarks of the project's log, then every device's, in allocator.
bookmarks_shared :: proc(p:^Project,m:^vcs.Machine,out:^[dynamic]Shared_Bookmark,allocator:=context.temp_allocator) -> vcs.Error {
    project,_:=project_of(p,m) or_return
    ps:vcs.Project_State
    if e:=vcs.project_state_load(&m.store,project,&ps,context.temp_allocator);e!=.None {
        m.why="this store lacks the logs of the project or its org: let the agent fetch them"
        return e
    }
    here :: proc(s:^store.Store,r:vcs.Revision) -> bool {
        _,e:=vcs.change_get(s,r,context.temp_allocator)
        return e==.None
    }
    for b in ps.fold.bookmarks {
        name:=strings.clone(b.name,allocator)
        if _,e:=append(out,Shared_Bookmark{name=name,bookmark=name,target=b.target,here=here(&m.store,b.target)});e!=nil {return .Out_Of_Memory}
    }
    ns:[len(vcs.REFS_PREFIX)+64]u8
    refs,_:=store.ref_list(&m.store,vcs.refs_namespace(project,&ns),context.temp_allocator)
    for r in refs {
        bytes,ge:=vcs.object_get(&m.store,r.hash,.Device_Refs,context.temp_allocator)
        if ge!=.None {continue}
        d,de:=vcs.device_refs_decode(bytes,context.temp_allocator)
        if de!=.None {continue}
        display:=vcs.device_display(&ps.org,d.device)
        for b in d.refs {
            shown:=strings.concatenate({display,":",b.name},allocator)
            bookmark:=strings.clone(b.name,allocator)
            if _,a:=append(out,Shared_Bookmark{name=shown,bookmark=bookmark,target=b.target,device=d.device,here=here(&m.store,b.target)});a!=nil {return .Out_Of_Memory}
        }
    }
    return .None
}

// The change text names as revision_find does, or else a bookmark of the
// project's log, or a device's as <handle>/<device>:<bookmark>, whose change
// must be in the store.
revision_resolve :: proc(p:^Project,m:^vcs.Machine,text:string) -> (revision:vcs.Revision,error:vcs.Error) {
    if r,e:=revision_find(&p.workspace,text);e==.None {return r,.None}
    list:=make([dynamic]Shared_Bookmark,context.temp_allocator)
    if bookmarks_shared(p,m,&list)!=.None {
        m.why="it names no single visible change: @, @-, a bookmark or a prefix of a change id as mirai kai log shows it"
        return {},.Invalid_Argument
    }
    found:=0
    for b in list {
        if b.name!=text {continue}
        if !b.here {
            m.why="that bookmark's change is not in this store yet: let the agent fetch it"
            return {},.Missing
        }
        revision=b.target
        found+=1
    }
    switch found {
    case 1: return revision,.None
    case 0: m.why="it names no single change: @, @-, a bookmark, <handle>/<device>:<bookmark> as mirai kai bookmarks shows it, or a prefix of a change id"
    case: m.why="that shared bookmark diverged: move it to one change with mirai kai bookmarks move"
    }
    return {},.Invalid_Argument
}
