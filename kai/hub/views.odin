package hub

import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "mirai:kai"
import "mirai:std/diff"
import "mirai:store"

// The read routes. A project is what an org the node serves lists; its
// revisions are those its bookmarks reach (the device refs of its members
// and the moves of its log), indexed in one graph per project, so a revision
// of another project is never answered through it. A path a scope of the org
// takes is left out of every listing, though public trees never hold one.

FILE_MAX :: 8<<20        // bytes of a file the file route answers
DIFF_FILE_MAX :: 1<<20   // bytes of each side a diff reads
DIFF_LINES_MAX :: 20000
CHANGES_PAGE_MAX :: 200
CHANGES_PAGE :: 50
README_MAX :: 256<<10
GRAPHS_MAX :: 16
EVOLUTION_MAX :: 64
STACK_CHANGES_MAX :: kai.STACK_MAX

Bookmark_View :: struct {
    name:string,
    revision:kai.Revision,
    landed:bool,      // a move of the project's log, not a device's ref
    device:kai.Key,
    time:i64,
}

// A project as one request sees it.
Project_View :: struct {
    org:^kai.Runner_Org,
    id:kai.Log_Id,
    public:bool,
    name:string,
    log:^kai.Log,
    bookmarks:[dynamic]Bookmark_View,
    main:int, // index of the main bookmark, -1 without bookmarks
    graph:^kai.Graph_Index,
}

Project_Graph :: struct {
    project:kai.Log_Id,
    sum:store.Hash, // of the targets it was extended with last
    graph:kai.Graph_Index,
    used:f64,
}

@(private)
runner_of :: proc(h:^Hub) -> ^kai.Runner {return h.desc.runner}

@(private)
store_of :: proc(h:^Hub) -> ^store.Store {return &h.desc.runner.machine.store}

// The role of the session's user in org; None without a session.
session_role :: proc(c:^Call,o:^kai.Runner_Org) -> kai.Role {
    if c.session==nil || !o.agent.folded {return .None}
    return kai.org_role(&o.agent.org,c.session.user)
}

org_find :: proc(h:^Hub,id:kai.Log_Id) -> ^kai.Runner_Org {
    for o in runner_of(h).orgs {
        if o.id==id && o.agent.folded {return o}
    }
    return nil
}

// The project of the path's {project}, if this caller may read it; else the
// answer is set: 404 alike for what does not exist and what is private.
project_open :: proc(c:^Call,id_text:string) -> (v:Project_View,ok:bool) {
    id,parsed:=hash_parse(id_text)
    if !parsed {
        fail(c,400,"a project is named by its id, 64 hex")
        return
    }
    for o in runner_of(c.h).orgs {
        if !o.agent.folded {continue}
        for p in o.agent.org.projects {
            if p.id!=id {continue}
            if !p.public && session_role(c,o)==.None {break}
            v={org=o,id=id,public=p.public,main=-1}
            v.log=kai.agent_log(&o.agent,id)
            v.name=project_name(v.log)
            v.bookmarks=make([dynamic]Bookmark_View,context.temp_allocator)
            project_bookmarks(c.h,&v)
            v.graph=project_graph(c.h,&v)
            return v,true
        }
    }
    fail(c,404,"no such project on this node, or it is private: sign in as a member of its org")
    return
}

@(private)
project_name :: proc(l:^kai.Log) -> string {
    if l==nil {return ""}
    for &item in l.items {
        if item.entry.type!=.Project_Genesis {continue}
        _,tail,ok:=kai.body_head(item.entry.body,kai.Project_Genesis_Body)
        if ok {return string(tail)}
    }
    return ""
}

// The bookmarks of a project: the moves its log keeps, then each name a
// device publishes that no move keeps, at its newest record.
@(private)
project_bookmarks :: proc(h:^Hub,v:^Project_View) {
    s:=store_of(h)
    if v.log!=nil && len(v.log.items)>0 {
        proposals:=make([dynamic]^kai.Proposal_Fold,context.temp_allocator)
        project_proposals(h,v.org,v.id,&proposals)
        f:kai.Project_Fold
        if kai.project_fold(&f,v.log,&v.org.agent.org,proposals[:],context.temp_allocator)==.None {
            for b in f.bookmarks {append(&v.bookmarks,Bookmark_View{name=b.name,revision=b.target,landed=true})}
        }
    }
    ns:[len(kai.REFS_PREFIX)+64]u8
    refs,e:=store.ref_list(s,kai.refs_namespace(v.id,&ns),context.temp_allocator)
    if e==.None {
        for ref in refs {
            bytes,ge:=kai.object_get(s,ref.hash,.Device_Refs,context.temp_allocator)
            if ge!=.None {continue}
            d,de:=kai.device_refs_decode(bytes,context.temp_allocator)
            if de!=.None || d.project!=v.id {continue}
            names: for b in d.refs {
                for &held in v.bookmarks {
                    if held.name!=b.name {continue}
                    if held.landed {continue names}
                    if held.time<d.time {held.revision,held.device,held.time=b.target,d.device,d.time}
                    continue names
                }
                append(&v.bookmarks,Bookmark_View{name=b.name,revision=b.target,device=d.device,time=d.time})
            }
        }
    }
    slice.sort_by(v.bookmarks[:],proc(a,b:Bookmark_View) -> bool {return a.name<b.name})
    for b,i in v.bookmarks {
        if b.name=="main" {v.main=i}
    }
    if v.main<0 && len(v.bookmarks)>0 {v.main=0}
}

// The proposal logs of a project the agent holds, folded and settled.
@(private)
project_proposals :: proc(h:^Hub,o:^kai.Runner_Org,project:kai.Log_Id,out:^[dynamic]^kai.Proposal_Fold) {
    for l in o.agent.logs {
        if l.kind!=.Proposal || len(l.items)==0 || proposal_project(l)!=project {continue}
        f:=new(kai.Proposal_Fold,context.temp_allocator)
        if kai.proposal_fold(f,l,&o.agent.org,context.temp_allocator)!=.None {continue}
        _=kai.proposal_settle(store_of(h),f)
        append(out,f)
    }
}

@(private)
proposal_project :: proc(l:^kai.Log) -> kai.Log_Id {
    k:=kai.log_find(l,l.id)
    if k<0 {return {}}
    b,_,ok:=kai.body_head(l.items[k].entry.body,kai.Proposal_Open_Body)
    return ok?b.project:{}
}

// The graph of the revisions a project's bookmarks and proposals reach,
// extended when they change. A revision whose objects are not here yet is
// left out until they are.
@(private)
project_graph :: proc(h:^Hub,v:^Project_View) -> ^kai.Graph_Index {
    targets:=make([dynamic]kai.Revision,context.temp_allocator)
    for b in v.bookmarks {append(&targets,b.revision)}
    for l in v.org.agent.logs {
        if l.kind!=.Proposal || proposal_project(l)!=v.id {continue}
        for &item in l.items {
            if item.entry.type!=.Proposal_Revise {continue}
            _,tail,ok:=kai.body_head(item.entry.body,kai.Proposal_Revise_Body)
            if !ok || len(tail)%size_of(kai.Stack_Item)!=0 {continue}
            for s in slice.reinterpret([]kai.Stack_Item,tail) {append(&targets,s.revision)}
        }
    }
    slice.sort_by(targets[:],hash_less)
    sum:=store.address_of_bytes(slice.to_bytes(targets[:]))
    g:^Project_Graph
    for &x in h.graphs {
        if x.project==v.id {g=&x}
    }
    if g==nil {
        if len(h.graphs)>=GRAPHS_MAX {
            oldest:=0
            for x,i in h.graphs {
                if x.used<h.graphs[oldest].used {oldest=i}
            }
            kai.graph_destroy(&h.graphs[oldest].graph)
            unordered_remove(&h.graphs,oldest)
        }
        append(&h.graphs,Project_Graph{project=v.id})
        g=&h.graphs[len(h.graphs)-1]
        kai.graph_init(&g.graph,h.allocator)
    }
    g.used=h.now
    if g.sum!=sum {
        g.sum=sum
        for t in targets {_=kai.graph_extend(&g.graph,store_of(h),{t})}
    }
    return &g.graph
}

// A revision the project's graph holds, from a revision's hex or a bookmark's
// name; the main bookmark when text is empty.
revision_resolve :: proc(c:^Call,v:^Project_View,text:string) -> (r:kai.Revision,ok:bool) {
    if text=="" {
        if v.main<0 {
            fail(c,404,"the project has no bookmark yet")
            return
        }
        r=v.bookmarks[v.main].revision
    } else if x,is_hex:=hash_parse(text);is_hex {
        r=x
    } else {
        found:=false
        for b in v.bookmarks {
            if b.name==text {r,found=b.revision,true}
        }
        if !found {
            fail(c,404,"no such bookmark or revision in this project")
            return
        }
    }
    if r not_in v.graph.lookup {
        fail(c,404,"that revision is not one of this project's, or its objects have not reached this node yet")
        return
    }
    return r,true
}

// Whether a path is one a scope of the project's org takes.
scoped :: proc(v:^Project_View,path:string) -> bool {
    _,taken:=kai.scope_of(&v.org.agent.org,v.id,path)
    return taken
}

// Whether a folder is one a scope takes whole, as secrets/** takes secrets.
scoped_folder :: proc(v:^Project_View,path:string) -> bool {
    return scoped(v,path) || scoped(v,strings.concatenate({path,"/_"},context.temp_allocator))
}

hash_less :: proc(a,b:store.Hash) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}

@(private)
user_name :: proc(u:^kai.User_Fold) -> string {
    for &item in u.log.items {
        if item.entry.type!=.User_Genesis {continue}
        _,tail,ok:=kai.body_head(item.entry.body,kai.User_Genesis_Body)
        if ok {return string(tail)}
    }
    return ""
}

// The user a device or passkey key belongs to in the org's agent, and its
// name and the device's.
key_owner :: proc(o:^kai.Runner_Org,key:kai.Key) -> (user:^kai.User_Fold,device_name:string) {
    for u in o.agent.user_list {
        for d in u.devices {
            if d.key!=key {continue}
            l:=u.log
            item:=&l.items[d.added]
            #partial switch item.entry.type {
            case .Device_Add:
                _,tail,_:=kai.body_head(item.entry.body,kai.Device_Add_Body)
                return u,string(tail)
            }
            k:=key
            return u,short_hex(k[:])
        }
        for w in u.web_keys {
            if w.key==key {return u,"passkey"}
        }
    }
    return nil,""
}

@(private)
short_hex :: proc(bytes:[]u8) -> string {
    j:=json_make()
    json_hex(&j,bytes[:min(len(bytes),6)])
    text:=json_text(&j)
    return text[1:len(text)-1]
}

@(private)
summary_line :: proc(text:string) -> string {
    line:=text
    if cut:=strings.index_byte(line,'\n');cut>=0 {line=line[:cut]}
    if len(line)>200 {
        cut:=200
        for cut>0 && !utf8.rune_start(line[cut]) {cut-=1}
        line=line[:cut]
    }
    return line
}

// --- /api/node and /api/projects ---

@(private)
route_node :: proc(c:^Call) {
    h:=c.h
    r:=runner_of(h)
    j:=json_make()
    json_object(&j)
    key:=r.machine.identity.key
    json_member_hex(&j,"device",key[:])
    json_key(&j,"modes")
    json_array(&j)
    modes:=MODE_TEXT
    for m in kai.Node_Mode {
        if m in r.desc.modes {json_string(&j,modes[m])}
    }
    json_end_array(&j)
    json_member_string(&j,"rp_id",h.desc.rp_id)
    json_member_string(&j,"origin",h.origin)
    json_member_int(&j,"orgs",i64(len(r.orgs)))
    json_member_bool(&j,"passkeys_work",strings.has_prefix(h.origin,"https://"))
    json_end_object(&j)
    json_response(c,&j)
}

MODE_TEXT :: [kai.Node_Mode]string{.Relay="relay",.Seed="seed",.DDC="ddc"}

@(private)
route_projects :: proc(c:^Call) {
    j:=json_make()
    json_object(&j)
    json_key(&j,"projects")
    json_array(&j)
    for o in runner_of(c.h).orgs {
        if !o.agent.folded {continue}
        member:=session_role(c,o)!=.None
        for p in o.agent.org.projects {
            if !p.public && !member {continue}
            json_object(&j)
            json_member_hash(&j,"id",p.id)
            json_member_hash(&j,"org",o.id)
            json_member_string(&j,"name",project_name(kai.agent_log(&o.agent,p.id)))
            json_member_bool(&j,"public",p.public)
            json_end_object(&j)
        }
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
route_project :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    s:=store_of(c.h)
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"id",v.id)
    json_member_hash(&j,"org",v.org.id)
    json_member_string(&j,"name",v.name)
    json_member_bool(&j,"public",v.public)
    json_key(&j,"main")
    if v.main>=0 {json_string(&j,v.bookmarks[v.main].name)} else {json_null(&j)}
    json_key(&j,"bookmarks")
    json_array(&j)
    for b in v.bookmarks {
        json_object(&j)
        json_member_string(&j,"name",b.name)
        json_member_hash(&j,"revision",b.revision)
        if ch,e:=kai.change_get(s,b.revision,context.temp_allocator);e==.None {
            id:=ch.id
            json_member_hex(&j,"change",id[:])
        } else {
            json_key(&j,"change")
            json_null(&j)
        }
        json_member_bool(&j,"landed",b.landed)
        if !b.landed {
            d:=b.device
            json_member_hex(&j,"device",d[:])
            json_member_int(&j,"time",b.time)
        }
        json_end_object(&j)
    }
    json_end_array(&j)
    json_key(&j,"readme")
    readme_write(&j,&v,s)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
readme_write :: proc(j:^Json,v:^Project_View,s:^store.Store) {
    if v.main<0 {
        json_null(j)
        return
    }
    ch,e:=kai.change_get(s,v.bookmarks[v.main].revision,context.temp_allocator)
    if e!=.None {
        json_null(j)
        return
    }
    for name in ([?]string{"README.md","README","readme.md","README.txt","Readme.md"}) {
        entry,found,_:=kai.tree_file(s,ch.tree,name)
        if !found {continue}
        o,oe:=store.object_open(s,entry.address)
        if oe!=.None {break}
        size:=min(store.object_size(&o),README_MAX)
        bytes:=make([]u8,int(size),context.temp_allocator)
        re:=store.object_read(&o,0,bytes)
        store.object_close(&o)
        if re!=.None {break}
        text:=string(bytes)
        for !utf8.valid_string(text) && len(text)>0 {text=text[:len(text)-1]}
        json_object(j)
        json_member_string(j,"path",name)
        json_member_string(j,"text",text)
        json_member_bool(j,"truncated",entry.size>README_MAX)
        json_end_object(j)
        return
    }
    json_null(j)
}

// --- tree and file ---

@(private)
ENTRY_KIND_TEXT :: [kai.Entry_Kind]string{.File="file",.Executable="executable",.Folder="folder",.Conflict="conflict"}

// The entries of the folder at path of the tree at root.
folder_at :: proc(s:^store.Store,root:store.Hash,path:string,out:^[dynamic]kai.Tree_Entry) -> (found:bool,error:kai.Error) {
    address,rest:=root,path
    for depth in 0..=kai.DEPTH_MAX {
        clear(out)
        kai.folder_get(s,address,out,nil,context.temp_allocator) or_return
        if rest=="" {return true,.None}
        if depth==kai.DEPTH_MAX {break}
        slash:=strings.index_byte(rest,'/')
        name:=slash<0?rest:rest[:slash]
        next:store.Hash
        has:=false
        for e in out {
            if e.name==name && e.kind==.Folder {next,has=e.address,true}
        }
        if !has {return false,.None}
        address,rest=next,slash<0?"":rest[slash+1:]
    }
    return false,.Corrupt
}

@(private)
route_tree :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    rev_text,_:=query_param(c,"rev")
    path,_:=query_param(c,"path")
    path=strings.trim(path,"/")
    if path!="" && (!kai.path_valid(path) || scoped_folder(&v,path)) {
        fail(c,404,"no such folder in this revision")
        return
    }
    r,rok:=revision_resolve(c,&v,rev_text)
    if !rok {return}
    s:=store_of(c.h)
    ch,e:=kai.change_get(s,r,context.temp_allocator)
    if e!=.None {
        fail(c,404,"the change is not on this node yet")
        return
    }
    entries:=make([dynamic]kai.Tree_Entry,context.temp_allocator)
    found,fe:=folder_at(s,ch.tree,path,&entries)
    if fe!=.None || !found {
        fail(c,404,"no such folder in this revision")
        return
    }
    kinds:=ENTRY_KIND_TEXT
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"revision",r)
    json_member_string(&j,"path",path)
    json_key(&j,"entries")
    json_array(&j)
    for entry in entries {
        full:=path==""?entry.name:strings.concatenate({path,"/",entry.name},context.temp_allocator)
        if scoped(&v,full) || (entry.kind==.Folder && scoped_folder(&v,full)) {continue}
        json_object(&j)
        json_member_string(&j,"name",entry.name)
        json_member_string(&j,"kind",kinds[entry.kind])
        json_member_int(&j,"size",i64(entry.size))
        json_member_int(&j,"files",i64(entry.files))
        json_member_int(&j,"conflicts",i64(entry.conflicts))
        json_end_object(&j)
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

// Whether bytes read as text: UTF-8 without NUL.
text_like :: proc(bytes:[]u8) -> bool {
    _,nul:=slice.linear_search(bytes,0)
    return !nul && utf8.valid_string(string(bytes))
}

@(private)
route_file :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    rev_text,_:=query_param(c,"rev")
    path,_:=query_param(c,"path")
    if !kai.path_valid(path) || scoped(&v,path) {
        fail(c,404,"no such file in this revision")
        return
    }
    r,rok:=revision_resolve(c,&v,rev_text)
    if !rok {return}
    s:=store_of(c.h)
    ch,e:=kai.change_get(s,r,context.temp_allocator)
    if e!=.None {
        fail(c,404,"the change is not on this node yet")
        return
    }
    entry,found,_:=kai.tree_file(s,ch.tree,path)
    if !found {
        fail(c,404,"no such file in this revision")
        return
    }
    if entry.size>FILE_MAX {
        fail(c,413,"the file is larger than FILE_MAX: fetch it with mirai kai from a member's machine")
        return
    }
    bytes,be:=kai.file_bytes(s,entry.address,context.temp_allocator)
    if be!=.None {
        fail(c,404,"the file's bytes are not on this node yet")
        return
    }
    c.response={status=200,body=bytes,cache="private, max-age=31536000, immutable"}
    name:=path
    if cut:=strings.last_index_byte(name,'/');cut>=0 {name=name[cut+1:]}
    disposition:=strings.concatenate({"Content-Disposition: attachment; filename=\"",safe_name(name),"\"\r\n"},context.temp_allocator)
    if text_like(bytes) {
        c.response.content_type="text/plain; charset=utf-8"
        c.response.headers=SANDBOX_HEADER
    } else {
        c.response.content_type="application/octet-stream"
        c.response.headers=strings.concatenate({SANDBOX_HEADER,disposition},context.temp_allocator)
    }
    if x,is_hex:=hash_parse(rev_text);!is_hex || x!=r {c.response.cache="no-store"}
}

// A file name a header can carry: printable ASCII without quotes or backslashes.
@(private)
safe_name :: proc(name:string) -> string {
    out:=make([dynamic]u8,0,len(name),context.temp_allocator)
    for c in transmute([]u8)name {
        append(&out,(c>=0x20 && c<0x7f && c!='"' && c!='\\')?c:'_')
    }
    return string(out[:])
}

// --- changes ---

@(private)
route_changes :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    rev_text,_:=query_param(c,"rev")
    page_text,_:=query_param(c,"page")
    limit_text,_:=query_param(c,"limit")
    page,limit:=0,CHANGES_PAGE
    if page_text!="" {
        n,parsed:=parse_count(page_text)
        if !parsed {fail(c,400,"page is a count from 0");return}
        page=n
    }
    if limit_text!="" {
        n,parsed:=parse_count(limit_text)
        if !parsed || n==0 || n>CHANGES_PAGE_MAX {fail(c,400,"limit is from 1 to CHANGES_PAGE_MAX");return}
        limit=n
    }
    r,rok:=revision_resolve(c,&v,rev_text)
    if !rok {return}
    g:=v.graph
    // The ancestors of r by the graph's order, which puts a change after its parents: newest first.
    start:=g.lookup[r]
    seen:=make([]bool,len(g.revisions),context.temp_allocator)
    stack:=make([dynamic]u32,context.temp_allocator)
    list:=make([dynamic]u32,context.temp_allocator)
    append(&stack,start)
    seen[start]=true
    for len(stack)>0 {
        n:=pop(&stack)
        append(&list,n)
        for p in kai.graph_parents(g,n) {
            if seen[p] {continue}
            seen[p]=true
            append(&stack,p)
        }
    }
    slice.sort_by(list[:],proc(a,b:u32) -> bool {return a>b})
    first:=min(page*limit,len(list))
    last:=min(first+limit,len(list))
    s:=store_of(c.h)
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"revision",r)
    json_member_int(&j,"page",i64(page))
    json_member_bool(&j,"more",last<len(list))
    json_key(&j,"changes")
    json_array(&j)
    for n in list[first:last] {
        revision:=g.revisions[n]
        ch,e:=kai.change_get(s,revision,context.temp_allocator)
        json_object(&j)
        json_member_hash(&j,"revision",revision)
        id:=g.change_id[n]
        json_member_hex(&j,"change",id[:])
        if e==.None {
            author:=ch.author
            json_member_hex(&j,"author",author[:])
            json_member_int(&j,"written",ch.written)
            json_member_string(&j,"summary",summary_line(ch.description))
        }
        json_key(&j,"parents")
        json_array(&j)
        for p in kai.graph_parents(g,n) {json_hash(&j,g.revisions[p])}
        json_end_array(&j)
        json_end_object(&j)
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
parse_count :: proc(text:string) -> (n:int,ok:bool) {
    if len(text)==0 || len(text)>9 {return}
    for ch in transmute([]u8)text {
        if ch<'0' || ch>'9' {return}
        n=n*10+int(ch-'0')
    }
    return n,true
}

@(private)
diff_status :: proc(d:kai.Diff) -> string {
    switch {
    case d.after.kind==.Conflict: return "conflict"
    case d.before.address=={}: return "added"
    case d.after.address=={}: return "removed"
    }
    return "modified"
}

// The files a change edits from its first parent, without scoped ones.
change_edits :: proc(s:^store.Store,v:^Project_View,ch:^kai.Change,out:^[dynamic]kai.Diff) -> kai.Error {
    base:store.Hash
    if len(ch.parents)>0 {
        p,e:=kai.change_get(s,ch.parents[0],context.temp_allocator)
        if e!=.None {return e}
        base=p.tree
    } else {
        empty,e:=kai.tree_empty(s)
        if e!=.None {return e}
        base=empty
    }
    all:=make([dynamic]kai.Diff,context.temp_allocator)
    kai.tree_diff(s,base,ch.tree,&all,context.temp_allocator) or_return
    for d in all {
        if !scoped(v,d.path) {append(out,d)}
    }
    return .None
}

@(private)
route_change :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    r,rok:=revision_resolve(c,&v,path_param(c,"revision"))
    if !rok {return}
    s:=store_of(c.h)
    ch,e:=kai.change_get(s,r,context.temp_allocator)
    if e!=.None {
        fail(c,404,"the change is not on this node yet")
        return
    }
    edits:=make([dynamic]kai.Diff,context.temp_allocator)
    ee:=change_edits(s,&v,&ch,&edits)
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"revision",r)
    id:=ch.id
    json_member_hex(&j,"change",id[:])
    author:=ch.author
    json_member_hex(&j,"author",author[:])
    if u,_:=key_owner(v.org,ch.author);u!=nil {json_member_string(&j,"author_name",user_name(u))}
    json_member_int(&j,"created",ch.created)
    json_member_int(&j,"written",ch.written)
    json_key(&j,"parents")
    json_array(&j)
    for p in ch.parents {json_hash(&j,p)}
    json_end_array(&j)
    json_member_string(&j,"description",ch.description)
    json_key(&j,"coauthors")
    json_array(&j)
    for k in ch.coauthors {
        json_object(&j)
        key:=k
        json_member_hex(&j,"key",key[:])
        if u,_:=key_owner(v.org,k);u!=nil {json_member_string(&j,"name",user_name(u))}
        json_end_object(&j)
    }
    json_end_array(&j)
    json_member_int(&j,"turns",i64(len(ch.turns)))
    json_key(&j,"files")
    json_array(&j)
    for d in edits {
        json_object(&j)
        json_member_string(&j,"path",d.path)
        json_member_string(&j,"status",diff_status(d))
        for side,k in ([2]kai.File{d.before,d.after}) {
            json_key(&j,k==0?"before":"after")
            if side.address=={} {
                json_null(&j)
                continue
            }
            json_object(&j)
            json_member_hash(&j,"address",side.address)
            json_member_int(&j,"size",i64(side.size))
            json_end_object(&j)
        }
        json_end_object(&j)
    }
    json_end_array(&j)
    json_member_bool(&j,"files_complete",ee==.None)
    json_end_object(&j)
    json_response(c,&j)
}

// --- diff ---

@(private)
DIFF_OP_TEXT :: [diff.Op]string{.Same="same",.Add="add",.Remove="remove"}

@(private)
route_diff :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    from_text,_:=query_param(c,"from")
    to_text,_:=query_param(c,"to")
    path,_:=query_param(c,"path")
    if !kai.path_valid(path) || scoped(&v,path) {
        fail(c,404,"no such file in these revisions")
        return
    }
    if from_text=="" || to_text=="" {
        fail(c,400,"from and to name the two revisions")
        return
    }
    from,fok:=revision_resolve(c,&v,from_text)
    if !fok {return}
    to,tok:=revision_resolve(c,&v,to_text)
    if !tok {return}
    s:=store_of(c.h)
    texts:[2]string
    sizes:[2]i64={-1,-1}
    binary,too_large:=false,false
    for revision,k in ([2]kai.Revision{from,to}) {
        ch,e:=kai.change_get(s,revision,context.temp_allocator)
        if e!=.None {
            fail(c,404,"a change is not on this node yet")
            return
        }
        entry,found,_:=kai.tree_file(s,ch.tree,path)
        if !found {continue}
        sizes[k]=i64(entry.size)
        if entry.size>DIFF_FILE_MAX {
            too_large=true
            continue
        }
        bytes,be:=kai.file_bytes(s,entry.address,context.temp_allocator)
        if be!=.None {
            fail(c,404,"the file's bytes are not on this node yet")
            return
        }
        if !text_like(bytes) {binary=true}
        texts[k]=string(bytes)
    }
    if sizes[0]<0 && sizes[1]<0 {
        fail(c,404,"no such file in these revisions")
        return
    }
    j:=json_make()
    json_object(&j)
    json_member_string(&j,"path",path)
    json_member_bool(&j,"binary",binary)
    json_member_bool(&j,"too_large",too_large)
    for size,k in sizes {
        json_key(&j,k==0?"before":"after")
        if size<0 {json_null(&j);continue}
        json_object(&j)
        json_member_int(&j,"size",size)
        json_end_object(&j)
    }
    lines:=make([dynamic]diff.Line,context.temp_allocator)
    stats:diff.Stats
    if !binary && !too_large {
        de:diff.Error
        stats,de=diff.lines(texts[0],texts[1],&lines,context.temp_allocator)
        if de!=.None {too_large=true}
    }
    json_member_int(&j,"added",i64(stats.added))
    json_member_int(&j,"removed",i64(stats.removed))
    json_member_bool(&j,"truncated",len(lines)>DIFF_LINES_MAX)
    json_key(&j,"lines")
    json_array(&j)
    ops:=DIFF_OP_TEXT
    for l in lines[:min(len(lines),DIFF_LINES_MAX)] {
        text:=l.op==.Remove?texts[0]:texts[1]
        json_object(&j)
        json_member_string(&j,"op",ops[l.op])
        json_member_int(&j,"old",i64(l.old))
        json_member_int(&j,"new",i64(l.new))
        json_member_string(&j,"text",text[l.start:l.end])
        json_end_object(&j)
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

// --- evolution ---

@(private)
route_evolution :: proc(c:^Call) {
    v,ok:=project_open(c,path_param(c,"project"))
    if !ok {return}
    id:kai.Change_Id
    if !hex_parse(path_param(c,"change"),id[:]) {
        fail(c,400,"a change is named by its id, 32 hex")
        return
    }
    s:=store_of(c.h)
    g:=v.graph
    Rev :: struct {revision:kai.Revision,written:i64,change:kai.Change}
    revs:=make([dynamic]Rev,context.temp_allocator)
    for cid,n in g.change_id {
        if cid!=id || len(revs)>=EVOLUTION_MAX {continue}
        ch,e:=kai.change_get(s,g.revisions[n],context.temp_allocator)
        if e!=.None {continue}
        append(&revs,Rev{g.revisions[n],ch.written,ch})
    }
    if len(revs)==0 {
        fail(c,404,"no revision of that change is in this project")
        return
    }
    slice.sort_by(revs[:],proc(a,b:Rev) -> bool {return a.written<b.written || a.written==b.written && hash_less(a.revision,b.revision)})
    edits:=make([][dynamic]kai.Diff,len(revs),context.temp_allocator)
    j:=json_make()
    json_object(&j)
    json_member_hex(&j,"change",id[:])
    json_key(&j,"revisions")
    json_array(&j)
    for &x,i in revs {
        edits[i]=make([dynamic]kai.Diff,context.temp_allocator)
        change_edits(s,&v,&x.change,&edits[i])
        json_object(&j)
        json_member_hash(&j,"revision",x.revision)
        json_member_int(&j,"written",x.written)
        author:=x.change.author
        json_member_hex(&j,"author",author[:])
        json_member_string(&j,"summary",summary_line(x.change.description))
        json_key(&j,"files")
        json_array(&j)
        for d in edits[i] {json_string(&j,d.path)}
        json_end_array(&j)
        json_end_object(&j)
    }
    json_end_array(&j)
    json_key(&j,"interdiffs")
    json_array(&j)
    for i in 1..<len(revs) {
        a,b:=&revs[i-1],&revs[i]
        paths:=make([dynamic]string,context.temp_allocator)
        for d in edits[i-1] {append(&paths,d.path)}
        for d in edits[i] {
            if !slice.contains(paths[:],d.path) {append(&paths,d.path)}
        }
        slice.sort(paths[:])
        json_object(&j)
        json_member_hash(&j,"from",a.revision)
        json_member_hash(&j,"to",b.revision)
        json_key(&j,"files")
        json_array(&j)
        for path in paths {
            before,in_before,_:=kai.tree_file(s,a.change.tree,path)
            after,in_after,_:=kai.tree_file(s,b.change.tree,path)
            if in_before==in_after && before.address==after.address {continue}
            json_object(&j)
            json_member_string(&j,"path",path)
            json_key(&j,"before")
            if in_before {json_hash(&j,before.address)} else {json_null(&j)}
            json_key(&j,"after")
            if in_after {json_hash(&j,after.address)} else {json_null(&j)}
            json_end_object(&j)
        }
        json_end_array(&j)
        json_end_object(&j)
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}
