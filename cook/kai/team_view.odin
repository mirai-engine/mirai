package kai_assets

import "base:runtime"
import "core:strconv"
import "core:strings"
import vcs "mirai:kai"

// What the editor and `mirai kai` show of a machine's user and orgs, and the
// operations of a team on the workspace's project that both run: the texts
// a role, the modes of a node and a span of lines are given by, an org seen
// whole, the user of this device, who a peer is, what refused a snapshot or
// a publish and how to resolve it, shared bookmarks moved and guarded, and
// the scopes of the project. m.why says what failed and how to fix it.

// The role text names: reader, writer or admin; None for any other.
role_of :: proc(text:string) -> vcs.Role {
    switch text {
    case "reader": return .Reader
    case "writer": return .Writer
    case "admin": return .Admin
    }
    return .None
}

role_text :: proc(role:vcs.Role) -> string {
    switch role {
    case .None: return "none"
    case .Reader: return "reader"
    case .Writer: return "writer"
    case .Admin: return "admin"
    case .Owner: return "owner"
    }
    return ""
}

// The modes a node serves, named apart by commas: relay, seed and ddc.
node_modes_of :: proc(text:string) -> (modes:vcs.Node_Modes,ok:bool) {
    for part in strings.split(text,",",context.temp_allocator) {
        switch part {
        case "":
        case "relay": modes+={.Relay}
        case "seed": modes+={.Seed}
        case "ddc": modes+={.DDC}
        case: return {},false
        }
    }
    return modes,true
}

node_modes_text :: proc(modes:vcs.Node_Modes,allocator:=context.temp_allocator) -> string {
    names:=[vcs.Node_Mode]string{.Relay="relay",.Seed="seed",.DDC="ddc"}
    parts:=make([dynamic]string,context.temp_allocator)
    for mode in vcs.Node_Mode {
        if mode in modes {append(&parts,names[mode])}
    }
    return strings.join(parts[:],",",allocator)
}

// A span of lines of a text file, from 1: A-B, or A for one line.
lines_of :: proc(span:string) -> (anchor:vcs.Anchor,ok:bool) {
    first,last:=span,span
    if dash:=strings.index_byte(span,'-');dash>=0 {first,last=span[:dash],span[dash+1:]}
    x,ox:=strconv.parse_int(first)
    y,oy:=strconv.parse_int(last)
    if !ox || !oy || x<1 || y<x || y>int(max(u32)) {return}
    return {kind=.Lines,line=u32(x),lines=u32(y-x+1)},true
}

Device_View :: struct {
    key:vcs.Key,
    name:string,
    revoked:bool,
    this:bool, // this machine's device
}

Member_View :: struct {
    user:vcs.Log_Id,
    handle:string, // empty while its log is not here
    role:vcs.Role,
    devices:[]Device_View,
}

Policy_View :: struct {
    bookmark:string,
    text:string, // what a landing on it asks
}

Scope_View :: struct {
    scope:vcs.Scope_Id,
    project:vcs.Log_Id,
    id:string, // the hex it is named by
    patterns:[]string,
    readers:vcs.Role,
    history:bool,
}

Org_Project_View :: struct {
    id:vcs.Log_Id,
    name:string, // empty while its log is not here
    public:bool,
    policies:[]Policy_View,
}

Node_View :: struct {
    key:vcs.Key,
    modes:vcs.Node_Modes,
}

// An org as this machine knows it.
Org_View :: struct {
    id:vcs.Log_Id,
    name:string,
    owner:string,
    role:vcs.Role, // of this machine's user
    members:[]Member_View,
    nodes:[]Node_View,
    projects:[]Org_Project_View,
    scopes:[]Scope_View,
    publics:[]Public_View,
}

// A path of the deny set an admin keeps public in a project.
Public_View :: struct {
    project:vcs.Log_Id,
    path:string,
}

// The org of id whole, in allocator: Missing while its log is not here.
org_view :: proc(m:^vcs.Machine,id:vcs.Log_Id,v:^Org_View,allocator:=context.temp_allocator) -> vcs.Error {
    o:vcs.Org_State
    if e:=vcs.org_state_load(&m.store,id,&o,context.temp_allocator);e!=.None {
        m.why="the org's log is not in this store yet: let the agent fetch it"
        return e
    }
    clone :: proc(text:string,allocator:runtime.Allocator) -> string {
        out,_:=strings.clone(text,allocator)
        return out
    }
    v^={id=id,name=clone(vcs.log_title(&o.log),allocator)}
    if u:=vcs.org_state_user(&o,o.fold.owner);u!=nil {v.owner=clone(vcs.user_name(u),allocator)}
    if m.user!={} {v.role=vcs.org_role(&o.fold,m.user)}
    members:=make([]Member_View,len(o.fold.members),allocator)
    for member,i in o.fold.members {
        members[i]={user=member.user,role=member.role}
        u:=vcs.org_state_user(&o,member.user)
        if u==nil {continue}
        members[i].handle=clone(vcs.user_name(u),allocator)
        devices:=make([]Device_View,len(u.devices),allocator)
        for d,k in u.devices {
            devices[k]={key=d.key,name=clone(vcs.device_name(u,k),allocator),revoked=d.revoked,this=d.key==m.identity.key}
        }
        members[i].devices=devices
    }
    v.members=members
    nodes:=make([]Node_View,len(o.fold.nodes),allocator)
    for n,i in o.fold.nodes {nodes[i]={n.key,n.modes}}
    v.nodes=nodes
    projects:=make([]Org_Project_View,len(o.fold.projects),allocator)
    for p,i in o.fold.projects {
        pid:=p.id
        projects[i]={id=pid,public=p.public}
        l:vcs.Log
        vcs.log_init(&l,pid,context.temp_allocator)
        if vcs.log_open(&m.store,&l,pid,.Project)==.None {projects[i].name=clone(vcs.log_title(&l),allocator)}
        policies:=make([dynamic]Policy_View,allocator)
        for &policy in o.fold.policies {
            if policy.project==pid {append(&policies,Policy_View{clone(policy.bookmark,allocator),clone(vcs.org_policy_text(&o.fold,&policy),allocator)})}
        }
        projects[i].policies=policies[:]
    }
    v.projects=projects
    scopes:=make([]Scope_View,len(o.fold.scopes),allocator)
    for sc,i in o.fold.scopes {
        patterns:=make([dynamic]string,context.temp_allocator)
        vcs.org_scope_patterns(&o.fold,sc,&patterns)
        kept:=make([]string,len(patterns),allocator)
        for p,k in patterns {kept[k]=clone(p,allocator)}
        scope:=sc.scope
        scopes[i]={scope=sc.scope,project=sc.project,id=hex(scope[:4],allocator),patterns=kept,readers=sc.readers,history=sc.history}
    }
    v.scopes=scopes
    publics:=make([dynamic]Public_View,allocator)
    for x in o.fold.publics {
        if x.fingerprint=={} {append(&publics,Public_View{x.project,clone(x.path,allocator)})}
    }
    v.publics=publics[:]
    return .None
}

// The user of this device as its log has it.
Identity_View :: struct {
    user:vcs.Log_Id,     // zero: this device has no user
    handle:string,
    device:string,       // this device's name
    devices:[]Device_View,
    subject:string,      // what a grant is issued to: its device key and X25519 key in hex
    recovered:bool,      // the user has a recovery key; one born of a passkey has none until a device sets it
}

identity_view :: proc(m:^vcs.Machine,v:^Identity_View,allocator:=context.temp_allocator) -> vcs.Error {
    key,dh:=m.identity.key,m.dh.public
    v^={user=m.user,subject=strings.concatenate({hex(key[:],context.temp_allocator),hex(dh[:],context.temp_allocator)},allocator)}
    if m.user=={} {return .None}
    l:vcs.Log
    vcs.log_init(&l,m.user,context.temp_allocator)
    if e:=vcs.log_open(&m.store,&l,m.user,.User);e!=.None {
        m.why="this device's User_Log is not in its store: pair the device again"
        return e
    }
    f:vcs.User_Fold
    if e:=vcs.user_fold(&f,&l,context.temp_allocator);e!=.None {
        m.why="this device's User_Log does not fold: fetch it again from another device of the user"
        return e
    }
    defer vcs.user_fold_destroy(&f)
    v.handle=strings.clone(vcs.user_name(&f),allocator)
    v.recovered=f.recovery!={}
    devices:=make([]Device_View,len(f.devices),allocator)
    for d,k in f.devices {
        devices[k]={key=d.key,name=strings.clone(vcs.device_name(&f,k),allocator),revoked=d.revoked,this=d.key==m.identity.key}
        if devices[k].this {v.device=devices[k].name}
    }
    v.devices=devices
    return .None
}

// Who the peer of X25519 key dh is in an org: <handle>/<device> of a member's
// device, node and its key for a node, or its key.
peer_who :: proc(m:^vcs.Machine,org:vcs.Log_Id,dh:vcs.Dh_Key,allocator:=context.temp_allocator) -> string {
    key:=dh
    o:vcs.Org_State
    if vcs.org_state_load(&m.store,org,&o,context.temp_allocator)==.None {
        for u in o.users {
            for d in u.devices {
                if d.dh==dh {return vcs.device_display(&o,d.key,allocator)}
            }
        }
        for n in o.fold.nodes {
            if n.dh==dh {
                node:=n.key
                return strings.concatenate({"node ",hex(node[:4],context.temp_allocator)},allocator)
            }
        }
    }
    return hex(key[:4],allocator)
}

Refusal_Action :: enum u8 {
    None,
    Keep_Public, // an admin keeps the path, or the line of a leak, public: public_add
    Rotate,      // a reader rotates the scope's key: scope_rotate
}

// What refused a snapshot or a publish, and what resolves it.
Refusal :: struct {
    text:string,     // whole, with how to fix it
    path:string,
    line:int,        // of a leak the publish scanner found, from 1
    action:Refusal_Action,
    scope:vcs.Scope_Id,
}

// What refused the workspace's last snapshot, read from its routing: its
// strings stay in the temp allocator.
snapshot_refusal :: proc(p:^Project) -> Refusal {
    if unrouted(&p.workspace) {return {text=UNROUTED}}
    r:=&p.routing
    switch r.refusal {
    case .None: return {}
    case .Denied: return {text=r.refused,path=r.refused_path,action=.Keep_Public}
    case .Rotate: return {text=r.refused,path=r.refused_path,action=.Rotate,scope=r.refused_scope}
    case .No_Keyring,.Unreadable: return {text=r.refused,path=r.refused_path,scope=r.refused_scope}
    }
    return {}
}

// What refused the machine's last publish of bookmarks: the leak the publish
// scanner found, which an admin keeps public line by line.
publish_refusal :: proc(m:^vcs.Machine) -> Refusal {
    if m.leak.path=="" {return {}}
    return {text=m.why,path=m.leak.path,line=m.leak.line,action=.Keep_Public}
}

// Moves the project's shared bookmark name to revision for the whole org,
// refused with the policy's reason when one guards it.
bookmark_move :: proc(p:^Project,m:^vcs.Machine,name:string,to:vcs.Revision) -> vcs.Error {
    project,_:=project_of(p,m) or_return
    return vcs.machine_bookmark_move(m,project,name,to)
}

// Guards the project's bookmark name: it moves only by landing a proposal
// with approvals and the checks named passed.
policy_set :: proc(p:^Project,m:^vcs.Machine,name:string,approvals:int,checks:[]string) -> vcs.Error {
    project,org:=project_of(p,m) or_return
    return vcs.machine_policy_set(m,org,project,name,approvals,checks)
}

// Makes a scope of the project: what patterns match is sealed for readers
// from the next snapshot on; history keeps earlier epochs readable.
scope_add :: proc(p:^Project,m:^vcs.Machine,patterns:[]string,readers:vcs.Role,history:bool) -> (scope:vcs.Scope_Id,error:vcs.Error) {
    project,org:=project_of(p,m) or_return
    scope=vcs.machine_scope_add(m,org,project,patterns,readers,history) or_return
    return scope,project_route(p)
}

// The scope of the project text names by a prefix of its id.
scope_find :: proc(p:^Project,m:^vcs.Machine,text:string) -> (scope:vcs.Scope_Id,error:vcs.Error) {
    project,org:=project_of(p,m) or_return
    o:vcs.Org_State
    if e:=vcs.org_state_load(&m.store,org,&o,context.temp_allocator);e!=.None {
        m.why="the org's log is not in this store yet: let the agent fetch it"
        return {},e
    }
    sc,found:=vcs.org_scope_find(&o.fold,project,text)
    if found!=1 {
        m.why="no single scope of the project has that id: the list of scopes names them"
        return {},.Invalid_Argument
    }
    return sc.scope,.None
}

scope_remove :: proc(p:^Project,m:^vcs.Machine,scope:vcs.Scope_Id) -> vcs.Error {
    project,org:=project_of(p,m) or_return
    vcs.machine_scope_remove(m,org,project,scope) or_return
    return project_route(p)
}

// Wraps a new key of the scope for its readers now: what a write after a
// member or device left waits for.
scope_rotate :: proc(p:^Project,m:^vcs.Machine,scope:vcs.Scope_Id) -> (epoch:u32,error:vcs.Error) {
    project,org:=project_of(p,m) or_return
    epoch=vcs.machine_scope_rotate(m,org,project,scope) or_return
    return epoch,project_route(p)
}

// The title a proposal takes when none is given: the first line of the
// description of the working copy's parent.
proposal_title :: proc(p:^Project) -> string {
    r,e:=revision_find(&p.workspace,"@-")
    if e!=.None {return ""}
    c,_:=vcs.change_get(p.workspace.repo.s,r,context.temp_allocator)
    line:=c.description
    if cut:=strings.index_byte(line,'\n');cut>=0 {line=line[:cut]}
    return line
}
