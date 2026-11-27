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
    return project_link(p,t,org,repo)
}

// Writes the files of the repository's default bookmark in the workspace, as
// a new working change on it; a workspace that has the project's files
// already keeps them. Missing, with t.why, while nobody published a bookmark
// or its objects are not all here yet. bookmark: the one written, in the temp
// allocator.
clone_checkout :: proc(p:^Project,t:^vcs.Team) -> (bookmark:string,error:vcs.Error) {
    if os.is_file(project.path(p.workspace.root,project.PROJECT_FILE,allocator=context.temp_allocator)) {return "",.None}
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
    return b.name,.None
}

// Publishes the working copy to the repository's shared bookmark name for
// the whole org: the working change closes first when it changed a file or
// has a description (closing describes it), and the bookmark moves to what it
// closed, or to the working copy's parent when there was nothing to close.
// A change with a file in conflict is refused.
publish :: proc(p:^Project,t:^vcs.Team,name:string,closing:string,changed:^[dynamic]string) -> (revision:vcs.Revision,error:vcs.Error) {
    project_of(p,t) or_return
    if !vcs.bookmark_name_valid(name) {
        t.why=fmt.tprintf("%q is no bookmark name: letters, digits, - _ . and / of at most %d bytes",name,vcs.BOOKMARK_NAME_MAX)
        return {},.Invalid_Argument
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
            return {},.Invalid_Argument
        }
        revision=c.parents[0]
    }
    // The org's machines take what main names as it is: a conflict in it is resolved first.
    if published,e:=vcs.change_get(w.repo.s,revision,context.temp_allocator);e==.None {
        if totals,te:=vcs.tree_totals(w.repo.s,published.tree);te==.None && totals.conflicts>0 {
            t.why=fmt.tprintf("%d files of the change are in conflict: resolve them in the Kai tab, then publish",totals.conflicts)
            return {},.Invalid_Argument
        }
    }
    bookmark_move(p,t,name,revision) or_return
    return revision,.None
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
    name,device,role:string,
    you:bool,
}

Repo_View :: struct {
    id:vcs.Repo_Id,
    name:string,
    public:bool,
    main:string,    // the change id main names, "" while its change is not here
    published:bool, // someone published main
    here:bool,      // every object main reaches is here
    linked:bool,    // a workspace of this machine is one of it
    bytes:i64,      // total file bytes of main's tree when its root folder meta is here
    has_size:bool,
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
        x.key,x.role,x.you=m.key,role_text(m.role),m.key==t.identity.key
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
                x.published=true
                c,ce:=vcs.change_get(s,b.target,context.temp_allocator)
                if ce==.None {
                    x.main=change_text(c.id,allocator)
                    if totals,te:=vcs.tree_totals(s,c.tree);te==.None {
                        x.bytes,x.has_size=i64(totals.size),true
                    }
                }
                missing:=make([dynamic]store.Hash,context.temp_allocator)
                vcs.closure_walk(s,{b.target},nil,&missing)
                x.here=ce==.None && len(missing)==0
            }
        }
        for l in links {x.linked||=l.org==id && l.repo==r.id}
    }
    return .None
}

// What a project list row shows of a local Kai workspace's org link and
// publish state, read without taking the workspace lock or hashing files.
Project_Sync_State :: struct {
    kai:string,
    linked:bool,
    needs_publish:bool,
    can_publish:bool,
    bytes:i64,
    has_size:bool,
}

project_sync_state :: proc(s:^store.Store,t:^vcs.Team,root:string,allocator:=context.temp_allocator) -> (state:Project_Sync_State) {
    if s==nil || s.root=="" {return}
    repo,working,change_id,bookmark,ok:=vcs.workspace_working_info(s,root)
    if !ok {return}
    state.kai=bookmark!=""?strings.clone(bookmark,allocator):change_text(change_id,allocator)
    c,ce:=vcs.change_get(s,working,context.temp_allocator)
    if ce==.None {
        if totals,te:=vcs.tree_totals(s,c.tree);te==.None {
            state.bytes,state.has_size=i64(totals.size),true
        }
    }
    if t==nil {return}
    l,linked:=vcs.team_link_of(t,repo)
    if !linked {return}
    state.linked=true
    if o,_,oe:=vcs.team_org(t,l.org);oe==.None {
        if role,member:=vcs.org_role(&o,t.identity.key);member && role>=.Writer {state.can_publish=true}
    }
    if ce!=.None {return}
    main_target:vcs.Revision
    has_main:=false
    if org_s,se:=vcs.team_store(t,l.org);se==.None {
        if refs,_,re:=vcs.repo_refs_head(org_s,l.org,l.repo,context.temp_allocator);re==.None {
            for b in refs.bookmarks {
                if b.name==BOOKMARK_DEFAULT {
                    main_target,has_main=b.target,true
                    break
                }
            }
        }
    }
    if c.description!="" || len(c.parents)!=1 || !has_main || c.parents[0]!=main_target {
        state.needs_publish=true
        return
    }
    if parent,pe:=vcs.change_get(s,c.parents[0],context.temp_allocator);pe==.None && c.tree!=parent.tree {
        state.needs_publish=true
    }
    return
}

// Opens the workspace at root, snapshots and publishes to main, then closes it:
// used from the Launcher so a project can be published without opening the 3D editor.
project_publish_folder :: proc(s:^store.Store,t:^vcs.Team,root:string,types:^asset.Types=nil,allocator:=context.temp_allocator) -> (change:string,error:vcs.Error) {
    p:=new(Project,context.temp_allocator)
    if p==nil {return "",.Out_Of_Memory}
    if e:=project_open(p,root,s,types);e!=.None {
        if e==.Locked {t.why="another editor holds this project: publish from that editor"}
        return "",e
    }
    defer project_close(p)
    revision:=publish(p,t,BOOKMARK_DEFAULT,"",nil) or_return
    c:=vcs.change_get(s,revision,context.temp_allocator) or_return
    return change_text(c.id,allocator),.None
}

@(private)
clone :: proc(text:string,allocator:runtime.Allocator) -> (string,vcs.Error) {
    made,e:=strings.clone(text,allocator)
    if e!=nil {return "",.Out_Of_Memory}
    return made,.None
}
