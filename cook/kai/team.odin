package kai_assets

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"
import vcs "mirai:kai"

// What a team does with a project of an org, for the operations that need
// its workspace: publishing it into an org, linking a workspace to an org's
// repository, pulling one into a new folder, the shared bookmarks and the
// views the editor and the CLI show. What needs no workspace is in kai
// (team.odin there); t.why says what failed and how to fix it.

// What a project publishes to and is pulled from by default.
BOOKMARK_DEFAULT :: "main"

// The org repository the workspace is.
project_of :: proc(p:^Project,t:^vcs.Team) -> (l:vcs.Link,error:vcs.Error) {
    ok:bool
    if l,ok=vcs.team_link_of(t,p.workspace.repo.id);!ok {
        t.why="this project is in no org yet: Publish to main shares it with one of your orgs"
        return {},.Missing
    }
    return l,.None
}

// The title a project's repository takes: its manifest's name, else its folder's.
project_title :: proc(root:string) -> string {
    m,e:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if name:=base.text_get(m.name[:]);e.code==.None && name!="" {return strings.clone(name[:min(len(name),vcs.NAME_MAX)],context.temp_allocator)}
    title:=strings.trim_right(root,"/\\")
    if cut:=strings.last_index_any(title,"/\\");cut>=0 {title=title[cut+1:]}
    return title[:min(len(title),vcs.NAME_MAX)]
}

// Makes the workspace's repository a repository of org, public or the org's
// alone, named as the project: one record of the org, so no reader sees a
// repository without its setting.
project_join :: proc(p:^Project,t:^vcs.Team,org:vcs.Org_Id,public:bool) -> (l:vcs.Link,error:vcs.Error) {
    if held,ok:=vcs.team_link_of(t,p.workspace.repo.id);ok {
        if held.org!=org {
            t.why="this project is already in another org"
            return held,.Invalid_Argument
        }
        o,_:=vcs.team_org(t,org) or_return
        i:=vcs.org_repo(&o,held.repo)
        if i>=0 && o.repos[i].public==public {return held,.None}
        x:=i>=0?o.repos[i]:vcs.Org_Repo{id=held.repo,name=project_title(p.workspace.root)}
        x.public=public
        vcs.team_repo_set(t,org,x) or_return
        return held,.None
    }
    l={local=p.workspace.repo.id,org=org,repo=p.workspace.repo.id}
    vcs.team_repo_set(t,org,{id=l.repo,name=project_title(p.workspace.root),public=public}) or_return
    vcs.team_link(t,l) or_return
    return l,.None
}

// Makes the workspace's repository the repository of an org another machine
// published, so this workspace works on it.
project_link :: proc(p:^Project,t:^vcs.Team,org:vcs.Org_Id,repo:vcs.Repo_Id) -> vcs.Error {
    return vcs.team_link(t,{local=p.workspace.repo.id,org=org,repo=repo})
}

// A shared bookmark of a repository: whether every object it reaches is here.
Shared_Bookmark :: struct {
    name:string,
    target:vcs.Revision,
    here:bool,
}

// The shared bookmarks of a repository of org, in allocator.
repo_bookmarks :: proc(t:^vcs.Team,org:vcs.Org_Id,repo:vcs.Repo_Id,out:^[dynamic]Shared_Bookmark,allocator:=context.temp_allocator) -> vcs.Error {
    s:=vcs.team_store(t,org) or_return
    refs,_,e:=vcs.repo_refs_head(s,org,repo,context.temp_allocator)
    if e==.Missing {return .None}
    if e!=.None {return e}
    for b in refs.bookmarks {
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        vcs.closure_walk(s,{b.target},nil,&missing)
        name,ce:=strings.clone(b.name,allocator)
        if ce!=nil {return .Out_Of_Memory}
        if _,ae:=append(out,Shared_Bookmark{name,b.target,len(missing)==0});ae!=nil {return .Out_Of_Memory}
    }
    return .None
}

// The shared bookmarks of the workspace's repository.
bookmarks_shared :: proc(p:^Project,t:^vcs.Team,out:^[dynamic]Shared_Bookmark,allocator:=context.temp_allocator) -> vcs.Error {
    l:=project_of(p,t) or_return
    return repo_bookmarks(t,l.org,l.repo,out,allocator)
}

// The bookmark a repository is pulled from: main, else the first; -1 when none.
bookmark_default :: proc(list:[]Shared_Bookmark) -> int {
    for b,i in list {
        if b.name==BOOKMARK_DEFAULT {return i}
    }
    return len(list)>0?0:-1
}

// Makes root a workspace of a repository of an org: a folder that is not
// there yet or is empty, or the workspace a pull of the same repository left
// there. The files come with clone_checkout once the agent pulled them.
project_clone :: proc(p:^Project,t:^vcs.Team,root:string,s:^store.Store,org:vcs.Org_Id,repo:vcs.Repo_Id,types:^asset.Types=nil,allocator:=context.allocator) -> vcs.Error {
    if project_exists(root) {
        project_open(p,root,s,types,allocator) or_return
        if l,ok:=vcs.team_link_of(t,p.workspace.repo.id);ok && (l.org!=org || l.repo!=repo) {
            project_close(p)
            t.why="that folder is a workspace of another repository: choose another location"
            return .Invalid_Argument
        }
    } else {
        if os.exists(root) {
            entries,error:=os.read_all_directory_by_path(root,context.temp_allocator)
            if !os.is_dir(root) || error!=nil || len(entries)>0 {
                t.why="that folder is not empty: choose another location, or an empty folder"
                return .Invalid_Argument
            }
        } else if os.make_directory_all(root)!=nil {
            t.why="that folder could not be made: choose a location this user may write"
            return .Io
        }
        project_create(p,root,s,types,allocator) or_return
    }
    // The workspace stays open, its lock this caller's, only when it holds.
    if e:=project_link(p,t,org,repo);e!=.None {
        project_close(p)
        return e
    }
    return .None
}

// Writes the files of the repository's default bookmark in the workspace, as
// a new working change on it; a workspace whose working copy has files
// already (a pull that wrote them, or the project it was made of) keeps them.
// Missing, with t.why, while nobody published a bookmark or its objects are
// not all here yet. bookmark: the one written, in the temp allocator.
clone_checkout :: proc(p:^Project,t:^vcs.Team) -> (bookmark:string,error:vcs.Error) {
    empty:=vcs.tree_empty(p.workspace.repo.s) or_return
    if p.workspace.state.tree!=empty {return "",.None}
    list:=make([dynamic]Shared_Bookmark,context.temp_allocator)
    bookmarks_shared(p,t,&list) or_return
    i:=bookmark_default(list[:])
    if i<0 {
        t.why="nobody published this repository yet: Publish to main from a machine that has it"
        return "",.Missing
    }
    b:=list[i]
    if !b.here {
        t.why=fmt.tprintf("%s is not all here yet: the agent pulls it from the org's machines",b.name)
        return b.name,.Missing
    }
    on:=[1]vcs.Revision{b.target}
    if _,e:=new_change(&p.workspace,on[:],"",nil);e!=.None {return b.name,e}
    // The manifest came with the files: what the workspace tracks follows it.
    tracked_read(&p.tracked,p.workspace.root)
    return b.name,.None
}

// Publishes the working copy to the repository's shared bookmark name for
// the whole org: the working change closes first when it changed a file or
// has a description (closing describes it), and the bookmark moves to what it
// closed, or to the working copy's parent when there was nothing to close.
// A change with a file in conflict is refused. ddc: what of the builds the
// project pins it shared in the org's derived data (project_ddc_publish).
publish :: proc(p:^Project,t:^vcs.Team,name:string,closing:string,changed:^[dynamic]string) -> (revision:vcs.Revision,ddc:Ddc_Published,error:vcs.Error) {
    project_of(p,t) or_return
    if !vcs.bookmark_name_valid(name) {
        t.why=fmt.tprintf("%q is no bookmark name: letters, digits, - _ . and / of at most %d bytes",name,vcs.BOOKMARK_NAME_MAX)
        return {},{},.Invalid_Argument
    }
    w:=&p.workspace
    snapshot(w) or_return
    working:=vcs.repo_working(&w.repo)
    c:=vcs.change_get(w.repo.s,working,context.temp_allocator) or_return
    diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
    diff(w,working,&diffs) or_return
    if len(diffs)>0 || c.description!="" || closing!="" || len(c.parents)>1 {
        text:Maybe(string)
        if closing!="" {text=closing}
        new_change(w,nil,"",changed,closing=text) or_return
        revision=revision_find(w,"@-") or_return
    } else {
        if len(c.parents)==0 {
            t.why="the project has no change to publish yet: change a file first"
            return {},{},.Invalid_Argument
        }
        revision=c.parents[0]
    }
    // The org's machines take what main names as it is: a conflict in it is resolved first.
    if published,e:=vcs.change_get(w.repo.s,revision,context.temp_allocator);e==.None {
        if totals,te:=vcs.tree_totals(w.repo.s,published.tree);te==.None && totals.conflicts>0 {
            t.why=fmt.tprintf("%d files of the change are in conflict: resolve them in the Kai tab, then publish",totals.conflicts)
            return {},{},.Invalid_Argument
        }
    }
    bookmark_move(p,t,name,revision) or_return
    ddc=project_ddc_publish(p,t)
    return revision,ddc,.None
}

// What a publish shared of the builds of the packages the project pins.
Ddc_Published :: struct {
    published:int, // keys whose records it added to the org's derived data
    missing:int,   // pinned packages with no whole build in this store: the machines that pull the project build them themselves
}

// What a publish says of the builds it could not share, in the temp
// allocator: "" when every pinned package had one.
ddc_missing_text :: proc(ddc:Ddc_Published) -> string {
    if ddc.missing==0 {return ""}
    return fmt.tprintf("%d pinned %s no whole build in this store to share in the org's derived data: the machines that pull the project build %s themselves. Refresh the project's packages here, then publish again.",ddc.missing,ddc.missing==1?"package has":"packages have",ddc.missing==1?"it":"them")
}

// Publishes in the org's derived data the builds of the packages the project
// pins that this store holds whole, as a refresh asks for them: by the
// manifest (asset.REF_BUILDS) and by import key (asset.REF_IMPORTS or
// asset.REF_IMPORTS_FAST), so a machine that pulls the project takes the
// exact builds it was published with. A key the org has a record of this
// output for is left as it is; the org's nodes hear of the rest from the
// agent. A pinned package whose build by manifest is not here whole is
// missing.
project_ddc_publish :: proc(p:^Project,t:^vcs.Team) -> (ddc:Ddc_Published) {
    l,e:=project_of(p,t)
    if e!=.None {return}
    s,se:=vcs.team_store(t,l.org)
    if se!=.None {return}
    root:=p.workspace.root
    list,_,le:=asset.packages_load(root,context.temp_allocator)
    if le!=.None {return}
    for &entry in list.packages {
        x,pe:=asset.package_load(s,root,&entry,context.temp_allocator)
        if pe!=.None {
            ddc.missing+=1
            continue
        }
        select_digits,key_digits:[64]u8
        select:=store.hex(asset.build_select(entry.manifest,&x),&select_digits)
        address,re:=store.ref_get(s,asset.REF_BUILDS,select)
        if re!=.None {
            ddc.missing+=1
            continue
        }
        b,be:=asset.build_get(s,address,context.temp_allocator)
        if be!=.None || b.package_id!=entry.id || !asset.build_whole(s,&b) {
            ddc.missing+=1
            continue
        }
        if _,_,ok:=ddc_share(t,l.org,s,asset.REF_BUILDS,select,address,true);ok {ddc.published+=1}
        if b.key=={} {continue}
        namespace:=b.final?asset.REF_IMPORTS:asset.REF_IMPORTS_FAST
        key:=store.hex(b.key,&key_digits)
        if held,he:=store.ref_get(s,namespace,key);he!=.None || held!=address {continue}
        if _,_,ok:=ddc_share(t,l.org,s,namespace,key,address,true);ok {ddc.published+=1}
    }
    return
}

// Moves the repository's shared bookmark name to revision for the whole org.
bookmark_move :: proc(p:^Project,t:^vcs.Team,name:string,to:vcs.Revision) -> vcs.Error {
    l:=project_of(p,t) or_return
    s:=vcs.team_store(t,l.org) or_return
    if s!=p.workspace.repo.s {
        t.why="this project's store is not the org's"
        return .Other_Store
    }
    list:=make([dynamic]vcs.Bookmark_Ref,context.temp_allocator)
    if refs,_,e:=vcs.repo_refs_head(s,l.org,l.repo,context.temp_allocator);e==.None {
        for b in refs.bookmarks {
            if b.name!=name {append(&list,b)}
        }
    }
    append(&list,vcs.Bookmark_Ref{name,to})
    return vcs.team_publish(t,l.org,l.repo,list[:])
}

// The change text names: a shared bookmark of the workspace's repository,
// else what revision_find names in the workspace.
revision_resolve :: proc(p:^Project,t:^vcs.Team,text:string) -> (revision:vcs.Revision,error:vcs.Error) {
    list:=make([dynamic]Shared_Bookmark,context.temp_allocator)
    if bookmarks_shared(p,t,&list)==.None {
        for b in list {
            if b.name==text {return b.target,.None}
        }
    }
    return revision_find(&p.workspace,text)
}

// The paths of a tree whose names look like secrets (keys, credentials,
// environment files): what a public publish warns of, in the temp allocator.
secret_paths :: proc(p:^Project,revision:vcs.Revision) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    c,e:=vcs.change_get(p.workspace.repo.s,revision,context.temp_allocator)
    if e!=.None {return nil}
    files:=make([dynamic]vcs.File,context.temp_allocator)
    if vcs.tree_files(p.workspace.repo.s,c.tree,&files,context.temp_allocator)!=.None {return nil}
    SECRET_NAMES :: [?]string{".env","id_rsa","id_ed25519","credentials.json",".npmrc",".netrc"}
    SECRET_EXTENSIONS :: [?]string{".pem",".key",".p12",".pfx",".keystore"}
    names:=SECRET_NAMES
    extensions:=SECRET_EXTENSIONS
    for f in files {
        name:=filepath.base(f.path)
        lower:=strings.to_lower(name,context.temp_allocator)
        secret:=strings.has_prefix(lower,".env.")
        for n in names {secret||=lower==n}
        for x in extensions {secret||=strings.has_suffix(lower,x)}
        if secret {append(&out,f.path)}
    }
    return out[:]
}

// --- Views ---

role_of :: proc(text:string) -> (role:vcs.Role,ok:bool) {
    switch text {
    case "reader": return .Reader,true
    case "node": return .Node,true
    case "writer": return .Writer,true
    case "admin": return .Admin,true
    }
    return
}

role_text :: proc(role:vcs.Role) -> string {
    switch role {
    case .Reader: return "reader"
    case .Node: return "node"
    case .Writer: return "writer"
    case .Admin: return "admin"
    }
    return ""
}

Member_View :: struct {
    key:vcs.Key,
    name,device:string,
    role:vcs.Role,
    you:bool,
}

// Where a repository's shared main is, as this machine holds it.
Repo_Main_State :: enum u8 {
    Unpublished, // nobody published main
    Coming,      // published: not every object it reaches is here yet
    Here,        // every object main reaches is here
}

Repo_View :: struct {
    id:vcs.Repo_Id,
    name:string,
    public:bool,
    main_state:Repo_Main_State,
    main:string,      // the change id main names, "" while its change is not here
    linked:bool,      // a workspace of this machine is one of it
    size:Maybe(i64),  // total file bytes of main's tree, once its root folder meta is here
}

Org_View :: struct {
    id:vcs.Org_Id,
    name:string,
    version:u64,
    role:string,   // this machine's
    server:string, // attached server host:port, "" when none
    members:[]Member_View,
    repos:[]Repo_View,
}

// What an org shows; its strings in allocator.
org_view :: proc(t:^vcs.Team,id:vcs.Org_Id,v:^Org_View,allocator:=context.temp_allocator) -> vcs.Error {
    o,_:=vcs.team_org(t,id) or_return
    s:=vcs.team_store(t,id) or_return
    v^={id=id,version=o.version}
    v.name=clone(o.name,allocator) or_return
    if role,ok:=vcs.org_role(&o,t.identity.key);ok {v.role=role_text(role)}
    if _,addr,has:=vcs.org_server(&o);has {v.server=clone(addr,allocator) or_return}
    members,me:=make([]Member_View,len(o.members),allocator)
    repos,re:=make([]Repo_View,len(o.repos),allocator)
    if me!=nil || re!=nil {return .Out_Of_Memory}
    v.members,v.repos=members,repos
    for m,i in o.members {
        x:=&v.members[i]
        x.key,x.role,x.you=m.key,m.role,m.key==t.identity.key
        x.name=clone(m.name,allocator) or_return
        x.device=clone(m.device,allocator) or_return
    }
    links:=vcs.team_links(t)
    for r,i in o.repos {
        x:=&v.repos[i]
        x.id,x.public=r.id,r.public
        x.name=clone(r.name,allocator) or_return
        if refs,_,e:=vcs.repo_refs_head(s,id,r.id,context.temp_allocator);e==.None {
            for b in refs.bookmarks {
                if b.name!=BOOKMARK_DEFAULT {continue}
                x.main_state=.Coming
                c,ce:=vcs.change_get(s,b.target,context.temp_allocator)
                if ce!=.None {continue}
                x.main=change_text(c.id,allocator)
                if totals,te:=vcs.tree_totals(s,c.tree);te==.None {x.size=i64(totals.size)}
                missing:=make([dynamic]store.Hash,context.temp_allocator)
                vcs.closure_walk(s,{b.target},nil,&missing)
                if len(missing)==0 {x.main_state=.Here}
            }
        }
        for l in links {x.linked||=l.org==id && l.repo==r.id}
    }
    return .None
}

// Where a workspace's working copy is against its repository's shared main.
Workspace_Sync :: enum u8 {
    Unlinked,    // in no org of this machine
    Unpublished, // nobody published main
    Synced,      // the working copy is main
    Ahead,       // it has what main lacks: a publish shares it
    Behind,      // main has what it lacks: update_from_main takes it
    Diverged,    // both: an update merges main, then a publish shares the rest
}

// Whether the working copy has what main lacks.
sync_ahead :: proc(sync:Workspace_Sync) -> bool {return sync==.Unpublished || sync==.Ahead || sync==.Diverged}

// Whether main has what the working copy lacks.
sync_behind :: proc(sync:Workspace_Sync) -> bool {return sync==.Behind || sync==.Diverged}

// What a project list row shows of a local Kai workspace's org link and
// publish state, read without taking the workspace lock or hashing files.
Project_Sync_State :: struct {
    kai:string,         // what the workspace is on: a bookmark or the working change
    sync:Workspace_Sync,
    can_publish:bool,   // this machine writes in the linked org
    main_here:bool,     // when behind: every object main reaches is here, so an update can start
    size:Maybe(i64),    // total file bytes of the working copy
    conflicts:u32,      // files in conflict in the working copy: a publish is refused until they are resolved
}

// Changes a list of projects walks from a working copy or main to tell which
// holds the other; past it a working copy counts as behind and unpublished,
// which an update or a publish then finds is not so.
SYNC_WALK_MAX :: 1024

project_sync_state :: proc(s:^store.Store,t:^vcs.Team,root:string,allocator:=context.temp_allocator) -> (state:Project_Sync_State) {
    if s==nil || s.root=="" {return}
    repo,working,change_id,bookmark,ok:=vcs.workspace_working_info(s,root)
    if !ok {return}
    state.kai=bookmark!=""?strings.clone(bookmark,allocator):change_text(change_id,allocator)
    c,ce:=vcs.change_get(s,working,context.temp_allocator)
    if ce==.None {
        if totals,te:=vcs.tree_totals(s,c.tree);te==.None {state.size,state.conflicts=i64(totals.size),totals.conflicts}
    }
    if t==nil {return}
    l,linked:=vcs.team_link_of(t,repo)
    if !linked {return}
    if o,_,oe:=vcs.team_org(t,l.org);oe==.None {
        if role,member:=vcs.org_role(&o,t.identity.key);member && role>=.Writer {state.can_publish=true}
    }
    // A working change that does not read is published by nobody this machine can tell.
    state.sync=.Unpublished
    if ce!=.None {return}
    main_target:vcs.Revision
    has_main:=false
    org_s,se:=vcs.team_store(t,l.org)
    if se==.None {
        if refs,_,re:=vcs.repo_refs_head(org_s,l.org,l.repo,context.temp_allocator);re==.None {
            for b in refs.bookmarks {
                if b.name==BOOKMARK_DEFAULT {
                    main_target,has_main=b.target,true
                    break
                }
            }
        }
    }
    if !has_main {return}
    ours:=working_ours(s,working,&c)
    ahead:=false
    if reaches(s,ours,main_target) {
        // What holds main and is not main is ahead of it, unless it holds
        // main's files alone and says nothing more: a publish shares nothing.
        for o in ours {ahead||=o!=main_target}
        if ahead && c.description=="" && state.conflicts==0 {
            if m,me:=vcs.change_get(s,main_target,context.temp_allocator);me==.None && m.tree==c.tree {ahead=false}
        }
        state.sync=ahead?.Ahead:.Synced
        return
    }
    for o in ours {ahead||=!reaches(s,{main_target},o)}
    state.sync=ahead?.Diverged:.Behind
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    vcs.closure_walk(org_s,{main_target},nil,&missing)
    state.main_here=len(missing)==0
    return
}

// What of a working copy is this machine's: the working change when it
// changed a file of its one parent, has a description or merges, else its
// parent. Read without a repository, so a merge counts as changed.
@(private)
working_ours :: proc(s:^store.Store,working:vcs.Revision,c:^vcs.Change) -> []vcs.Revision {
    if c.description=="" && len(c.parents)==1 {
        if parent,e:=vcs.change_get(s,c.parents[0],context.temp_allocator);e==.None && parent.tree==c.tree {return c.parents}
    }
    ours:=make([]vcs.Revision,1,context.temp_allocator)
    ours[0]=working
    return ours
}

// Whether target is one of from or their ancestors, within SYNC_WALK_MAX changes.
@(private)
reaches :: proc(s:^store.Store,from:[]vcs.Revision,target:vcs.Revision) -> bool {
    stack:=make([dynamic]vcs.Revision,context.temp_allocator)
    seen:=make(map[vcs.Revision]struct{},allocator=context.temp_allocator)
    append(&stack,..from)
    for len(stack)>0 && len(seen)<SYNC_WALK_MAX {
        r:=pop(&stack)
        if r==target {return true}
        if r in seen {continue}
        seen[r]={}
        c,e:=vcs.change_get(s,r,context.temp_allocator)
        if e!=.None {continue}
        append(&stack,..c.parents)
    }
    return false
}

// What an update of a working copy from main did.
Update_Result :: struct {
    revision:vcs.Revision, // the working change, made or kept
    conflicts:u32,         // files in conflict in its tree
    up_to_date:bool,       // main was in the working copy already: nothing changed
}

// Takes the repository's shared main into the working copy: a new working
// change on main and on what of the working copy main lacks (working_ours,
// with the merge of its parents' trees standing for one parent), whose trees
// merge. Every local change and edit stays: the edits of the working copy
// close as they are, and a file both sides changed apart is a conflict value.
// A merge whose tree is main's, of changes none of which is described, is on
// main alone: the working copy is then main, with nothing to publish.
// Missing, with t.why, while nobody published main or its objects are not all
// here yet.
update_from_main :: proc(p:^Project,t:^vcs.Team,changed:^[dynamic]string) -> (result:Update_Result,error:vcs.Error) {
    list:=make([dynamic]Shared_Bookmark,context.temp_allocator)
    bookmarks_shared(p,t,&list) or_return
    main:=-1
    for b,i in list {
        if b.name==BOOKMARK_DEFAULT {main=i}
    }
    if main<0 {
        t.why="nobody published main yet: Publish to main from a machine that has the project"
        return {},.Missing
    }
    target:=list[main].target
    if !list[main].here {
        t.why=fmt.tprintf("%s is not all here yet: the agent pulls it from the org's machines",BOOKMARK_DEFAULT)
        return {},.Missing
    }
    w:=&p.workspace
    r:=&w.repo
    snapshot(w) or_return
    working:=vcs.repo_working(r)
    c:=vcs.change_get(r.s,working,context.temp_allocator) or_return
    vcs.graph_extend(&r.graph,r.s,{working,target}) or_return
    if vcs.graph_is_ancestor(&r.graph,target,working) {return {revision=working,up_to_date=true},.None}
    ours:=[]vcs.Revision{working}
    if c.description=="" && len(c.parents)>0 {
        if tree,e:=vcs.parents_tree(r,c.parents);e==.None && tree==c.tree {ours=c.parents}
    }
    parents:=make([dynamic]vcs.Revision,context.temp_allocator)
    for o in ours {
        if vcs.graph_is_ancestor(&r.graph,o,target) {continue}
        if len(parents)==vcs.PARENTS_MAX-1 {
            t.why="the working copy merges as many changes as a change may: publish or describe it first"
            return {},.Too_Large
        }
        append(&parents,o)
    }
    append(&parents,target)
    if len(parents)>1 {
        main_change:=vcs.change_get(r.s,target,context.temp_allocator) or_return
        merged:=vcs.parents_tree(r,parents[:]) or_return
        described:=false
        for o in parents[:len(parents)-1] {
            x:=vcs.change_get(r.s,o,context.temp_allocator) or_return
            described||=x.description!=""
        }
        if merged==main_change.tree && !described {
            parents[0]=target
            resize(&parents,1)
        }
    }
    result.revision=new_change(w,parents[:],"",changed) or_return
    made:=vcs.change_get(r.s,result.revision,context.temp_allocator) or_return
    totals:=vcs.tree_totals(r.s,made.tree) or_return
    result.conflicts=totals.conflicts
    return
}

// Opens the workspace at root, takes main into it and closes it: an update
// from the Launcher, without opening the 3D editor.
project_update_folder :: proc(s:^store.Store,t:^vcs.Team,root:string,types:^asset.Types=nil) -> (result:Update_Result,error:vcs.Error) {
    p:=new(Project,context.temp_allocator)
    if p==nil {return {},.Out_Of_Memory}
    if e:=project_open(p,root,s,types);e!=.None {
        if e==.Locked {t.why="another editor holds this project: update it from that editor's Kai tab"}
        return {},e
    }
    defer project_close(p)
    if _,e:=project_of(p,t);e!=.None {return {},e}
    return update_from_main(p,t,nil)
}

// What a workspace leaving its folder keeps: its working copy snapshotted
// into the store, where its changes stay as a head of its repository.
Set_Aside :: struct {
    revision:vcs.Revision, // the working change, snapshotted
    repo:vcs.Repo_Id,
    linked:bool,           // it is a workspace of an org's repository
    unpublished:bool,      // no org has all it holds: linked with changes main lacks, or in no org
    alone:bool,            // no other workspace of its repository is in its view
}

// Snapshots the workspace at root and says what of it no org has, before its
// folder goes. Locked, with t.why, while an editor holds it.
project_set_aside :: proc(s:^store.Store,t:^vcs.Team,root:string,types:^asset.Types=nil) -> (aside:Set_Aside,error:vcs.Error) {
    p:=new(Project,context.temp_allocator)
    if p==nil {return {},.Out_Of_Memory}
    if e:=project_open(p,root,s,types);e!=.None {
        if e==.Locked && t!=nil {t.why="another editor holds this project: close it first"}
        return {},e
    }
    report,se:=snapshot(&p.workspace)
    aside.revision,aside.repo=report.revision,p.workspace.repo.id
    aside.alone=true
    for x in p.workspace.repo.view.workspaces {aside.alone&&=x.id==p.workspace.state.id}
    project_close(p)
    if se!=.None {return aside,se}
    state:=project_sync_state(s,t,root)
    aside.linked=state.sync!=.Unlinked
    aside.unpublished=state.sync==.Unlinked || sync_ahead(state.sync)
    return aside,.None
}

// Opens the workspace at root, snapshots and publishes to main, then closes it:
// used from the Launcher so a project can be published without opening the 3D
// editor. ddc: publish's.
project_publish_folder :: proc(s:^store.Store,t:^vcs.Team,root:string,types:^asset.Types=nil,allocator:=context.temp_allocator) -> (change:string,ddc:Ddc_Published,error:vcs.Error) {
    p:=new(Project,context.temp_allocator)
    if p==nil {return "",{},.Out_Of_Memory}
    if e:=project_open(p,root,s,types);e!=.None {
        if e==.Locked {t.why="another editor holds this project: publish from that editor"}
        return "",{},e
    }
    defer project_close(p)
    revision:vcs.Revision
    revision,ddc=publish(p,t,BOOKMARK_DEFAULT,"",nil) or_return
    c:=vcs.change_get(s,revision,context.temp_allocator) or_return
    return change_text(c.id,allocator),ddc,.None
}

@(private)
clone :: proc(text:string,allocator:runtime.Allocator) -> (string,vcs.Error) {
    made,e:=strings.clone(text,allocator)
    if e!=nil {return "",.Out_Of_Memory}
    return made,.None
}
