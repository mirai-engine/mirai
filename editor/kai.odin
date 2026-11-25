package editor

import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "mirai:asset"
import ka "mirai:cook/kai"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import vcs "mirai:kai"
import "mirai:platform"
import "mirai:project"
import "mirai:store"

// Kai from the editor: the project is a workspace of its own repository in the
// machine's store, opened when the editor starts on it; a project without one
// uses no version control until Enable Kai (kai_enable) makes it. What the
// editor writes and what the watch of the folder sees are pushed as touched
// paths (kai.workspace_touched), so a snapshot stats only those; the working
// copy snapshots once the files are quiet, with the authors of the steps since
// (Kai_Authorship). What the tab shows is read again after each operation into
// an arena, so a frame that changes nothing allocates nothing. A guest of a
// collaboration session keeps no workspace: its host records the changes.

KAI_QUIET :: 1.0          // seconds files are left alone before the working copy snapshots
KAI_WATCH_BUDGET :: 512   // of a frame's watch of the folder
KAI_LOG_ROWS :: 64        // changes the tab and kai.log show by default
KAI_DESCRIPTION_BYTES :: 1024

// Who changed the working copy since the last snapshot: the key of an editor
// of a session the host applied, or the task of an agent's turn.
Kai_Author :: struct {
    key:vcs.Key,
    task:u64,
}

// What a change attaches for an agent's turn: a Kai_Turn object. Kai carries
// it without reading it; what a turn is stays the editor's.
KAI_TURN :: u32('t')|u32('u')<<8|u32('r')<<16|u32('n')<<24
KAI_TURN_VERSION :: 1

Kai_Turn :: struct #packed {
    version:u32,
    reserved:u32,
    task:u64, // the task of the AI chat whose turn edited
}

// The task of the turn object at address; ok false when it is no turn.
kai_turn_read :: proc(s:^store.Store,address:store.Hash) -> (task:u64,ok:bool) {
    o,e:=store.object_open(s,address)
    if e!=.None {return}
    defer store.object_close(&o)
    turn:Kai_Turn
    if store.object_size(&o)!=size_of(Kai_Turn) || store.object_read(&o,0,([^]u8)(&turn)[:size_of(turn)])!=.None {return}
    if turn.version!=KAI_TURN_VERSION || turn.reserved!=0 || turn.task==0 {return}
    return turn.task,true
}

// How many agents' turns a change's attachments are.
kai_turns :: proc(attachments:[]vcs.Attachment) -> (n:int) {
    for a in attachments {
        if a.type==KAI_TURN {n+=1}
    }
    return
}

// Requests: the history and a host of a session push; kai_snapshot takes.
@(storage,queue)
Kai_Authorship :: struct {using queue:core.Queue(Kai_Author)}

Kai_File :: struct {
    path:string,
    mark:u8,      // A added, D removed, M changed, C in conflict
    changed:bool, // by the working change: a conflict of its parents is listed but not
}

Kai_Row :: struct {
    change:string,
    description:string,
    bookmarks:string,
    working:bool,
    conflicts:u32,
    authors,turns:int,
    revision:vcs.Revision,
}

// What the tab shows, in the arena.
Kai_View :: struct {
    change:string,        // of the working copy
    title:string,         // what the tab heads with: "@ " and the change
    description:string,
    files:[]Kai_File,     // what the working copy changed from its parents
    rows:[]Kai_Row,       // the log, newest first
    picked:[]Kai_File,    // what the change picked in the log did
    bookmarks:[]string,   // name and change, as the tab lists them
    operation:string,     // the newest operation: what Undo takes back
    redo:bool,            // the newest operation is an undo
    fields:[]ka.Field_Conflict, // of the conflict unfolded
    whole:bool,           // the conflict unfolded resolves whole: not an asset
}

Kai_State :: struct {
    project:ka.Project,
    watch:platform.Watch,
    watching:bool,
    touched:bool,          // files changed since the last snapshot
    touched_at:f64,
    seen_state,seen_epoch:u64, // of the history of the scene, whose steps after are authors
    arena:vmem.Arena,
    view:Kai_View,
    unfolded:string,       // the conflict whose fields show; in the heap
    picks:[dynamic]bool,   // by field of view.fields: theirs
    unchecked_all:bool,      // CHANGES: every file unchecked but the toggled ones; false: checked
    toggled:[dynamic]string, // paths whose check is the other one, in the heap
    description:[KAI_DESCRIPTION_BYTES]u8,
    description_length:int,
    scroll:[2]f32,
    width:f32,             // of the tab this frame: what its rows of buttons lay out in
    picked:vcs.Revision,   // the change of the log whose files show
    detail:Kai_Detail,     // a file of a change, open in the tab
    team:Kai_Team,
}

@(storage)
Kai :: struct {
    state:^Kai_State,
    tried:bool,       // opening was tried for this project
    error:vcs.Error,  // why it is not open
    key:vcs.Key,      // this editor's identity in every session and change
    mesh_loopback:bool, // the runner the editor starts listens on 127.0.0.1 alone: tests
}

// The workspace of the project; nil when it has none open.
kai_workspace :: proc(s:^Session) -> ^vcs.Workspace {
    if s.kai==nil || s.kai.state==nil {return nil}
    return &s.kai.state.project.workspace
}

@(private)
kai_types :: proc(s:^Session) -> ^asset.Types {
    if s.app==nil || s.app.assets==nil {return nil}
    return &s.app.assets.types
}

// Opens the workspace of the project: once per project, with the machine's
// store. A project without one keeps no history until kai_enable makes it
// (Missing). A guest of a session opens none, nor does a run that ends by
// itself after a count of frames (a check of a build, a capture): only an
// editor that someone drives records history.
kai_open :: proc(s:^Session) {
    k:=s.kai
    if k==nil || k.tried || k.state!=nil || !s.has_project || s.store.root=="" || s.frames>0 {return}
    if st:=collab_state(s);st!=nil && st.role==.Guest && st.phase!=.Ended {return}
    k.tried=true
    if identity,e:=ka.identity_load(&s.store);e==.None {k.key=identity.key}
    if !ka.project_exists(s.project_root) {
        k.error=.Missing
        return
    }
    if e:=kai_attach(s,false);e!=.None {
        log.warnf("the Kai workspace of %s does not open: %s",s.project_root,vcs.error_text(e))
    }
}

// Makes the project a Kai workspace whose first change holds its files, and
// opens it. "" or why it could not.
kai_enable :: proc(s:^Session) -> string {
    k:=s.kai
    if k==nil || !s.has_project {return "The editor has no project"}
    if k.state!=nil {return "The project already uses Kai"}
    if s.store.root=="" {return kai_missing(s)}
    if st:=collab_state(s);st!=nil && st.role==.Guest && st.phase!=.Ended {return kai_missing(s)}
    if ka.project_exists(s.project_root) {return "The project already has a Kai workspace: it opens with the project"}
    k.tried=true
    if identity,e:=ka.identity_load(&s.store);e==.None {k.key=identity.key}
    if e:=kai_attach(s,true);e!=.None {
        return fmt.tprintf("The Kai workspace of the project could not be made: %s",vcs.error_text(e))
    }
    log.infof("%s is a Kai workspace now: its files are its first change",s.project_root)
    return ""
}

// Opens the workspace at the project's root, or makes it first with create,
// and starts watching its files.
@(private)
kai_attach :: proc(s:^Session,create:bool) -> vcs.Error {
    k:=s.kai
    st:=new(Kai_State)
    if st==nil {
        k.error=.Out_Of_Memory
        return .Out_Of_Memory
    }
    e:vcs.Error
    if create {
        e=ka.project_create(&st.project,s.project_root,&s.store,kai_types(s))
    } else {
        e=ka.project_open(&st.project,s.project_root,&s.store,kai_types(s))
    }
    if e!=.None {
        free(st)
        k.error=e
        return e
    }
    k.error=.None
    k.state=st
    if s.edits!=nil {st.seen_state,st.seen_epoch=s.edits.serial,s.edits.epoch}
    if s.app!=nil && s.app.platform!=nil {
        if watch,error:=platform.watch_create(s.app.platform,{path=s.project_root,recursive=true,file_capacity=1<<16});error==.None {
            st.watch,st.watching=watch,true
        } else {
            log.warnf("the files of %s are not watched (%v): a snapshot reads the whole folder",s.project_root,error)
        }
    }
    kai_team_open(s)
    kai_read(s)
    return .None
}

kai_close :: proc(s:^Session) {
    k:=s.kai
    if k==nil || k.state==nil {return}
    st:=k.state
    if st.watching && s.app!=nil && s.app.platform!=nil {platform.watch_destroy(s.app.platform,st.watch)}
    kai_team_close(s)
    kai_detail_close(st)
    ka.project_close(&st.project)
    vmem.arena_destroy(&st.arena)
    delete(st.unfolded)
    delete(st.picks)
    kai_checks_reset(st,false)
    delete(st.toggled)
    free(st)
    k.state=nil
}

// A file of the project changed, by its absolute path: the next snapshot
// stats it. Outside the project, or not tracked, it is nothing to Kai.
kai_touched :: proc(s:^Session,file:string) {
    w:=kai_workspace(s)
    if w==nil || file=="" {return}
    relative:=history.file_relative(s.project_root,file)
    if relative==file || !project.own_path(relative) {return}
    kai_touched_relative(s,relative)
}

@(private)
kai_touched_relative :: proc(s:^Session,relative:string) {
    st:=s.kai.state
    paths:=[1]string{relative}
    complete:=st.watching && (!st.touched || st.project.workspace.touched_all)
    if vcs.workspace_touched(&st.project.workspace,paths[:],complete)!=.None {return}
    st.touched,st.touched_at=true,platform.clock_seconds()
}

// What runs between frames: the watch of the folder, the authors of the steps
// since, and a snapshot once the files are quiet.
kai_poll :: proc(s:^Session) {
    kai_open(s)
    w:=kai_workspace(s)
    if w==nil {return}
    st:=s.kai.state
    if st.watching {
        events:[64]platform.Watch_Event
        count,_:=platform.watch_poll(s.app.platform,st.watch,KAI_WATCH_BUDGET,events[:])
        for e in events[:count] {
            if project.own_path(e.path) {kai_touched_relative(s,e.path)}
        }
        if platform.watch_stats(s.app.platform,st.watch).untracked>0 {
            vcs.workspace_touched(w,nil,false)
            st.touched,st.touched_at=true,platform.clock_seconds()
        }
    }
    kai_authors_follow(s)
    kai_team_poll(s)
    if !st.touched || platform.clock_seconds()-st.touched_at<KAI_QUIET || !kai_files_settled(s) {return}
    kai_snapshot(s)
}

// Whether what the editor holds is on disk: no gesture open, no file held, no game playing.
@(private)
kai_files_settled :: proc(s:^Session) -> bool {
    if playing(s) {return false}
    if s.edits!=nil && (s.edits.open || s.edits.commit || s.edits.preview) {return false}
    if r:=files_registry(s);r!=nil && len(r.memory)>0 {return false}
    return true
}

// The steps recorded since it last looked, each its author: an agent's turn
// is recorded in the change; a step of the user or of the API is this editor's.
@(private)
kai_authors_follow :: proc(s:^Session) {
    st:=s.kai.state
    q:=s.kai_authorship
    if q==nil {return}
    if edits:=s.edits;edits!=nil {
        if edits.epoch!=st.seen_epoch {st.seen_epoch,st.seen_state=edits.epoch,0}
        if edits.serial!=st.seen_state {
            for &step in edits.steps[:edits.cursor] {
                if step.state>st.seen_state {kai_author_push(q,step.author)}
            }
            st.seen_state=edits.serial
        }
    }
}

@(private)
kai_author_push :: proc(q:^Kai_Authorship,author:history.Edit_Author) {
    if author==history.EDIT_AUTHOR_USER || author==history.EDIT_AUTHOR_API {return}
    core.push(&q.queue,Kai_Author{task=u64(author)})
}

// An editor of a session changed the project: the host records it as a coauthor.
kai_coauthor :: proc(s:^Session,key:vcs.Key) {
    if s.kai_authorship==nil || key==({}) || s.kai==nil || key==s.kai.key {return}
    core.push(&s.kai_authorship.queue,Kai_Author{key=key})
}

// Records the files as they are as the working copy, with the authors since
// the last time. "" or why it could not.
kai_snapshot :: proc(s:^Session) -> string {
    w:=kai_workspace(s)
    if w==nil {return kai_missing(s)}
    st:=s.kai.state
    st.touched=false
    kai_authors_follow(s)
    authors:=core.take(&s.kai_authorship.queue)
    keys:=make([dynamic]vcs.Key,0,len(authors),context.temp_allocator)
    turns:=make([dynamic]vcs.Attachment,0,len(authors),context.temp_allocator)
    for a in authors {
        if a.key!=({}) {append(&keys,a.key)}
        if a.task==0 {continue}
        turn:=Kai_Turn{version=KAI_TURN_VERSION,task=a.task}
        if address,pe:=store.put(w.repo.s,([^]u8)(&turn)[:size_of(turn)]);pe==.None {append(&turns,vcs.Attachment{KAI_TURN,address})}
    }
    _,e:=ka.snapshot_authored(w,keys[:],turns[:])
    // A refusal stays until a snapshot holds; one of a publish, until a publish does.
    t:=&st.team
    if refusal:=ka.snapshot_refusal(&st.project);e==.Unauthorized && refusal.text!="" {
        kai_refusal_set(t,refusal)
    } else if e==.None && t.refusal.text!="" && t.refusal.line==0 {
        kai_refusal_set(t,{})
    }
    kai_read(s)
    if e==.Unauthorized && t.refusal.text!="" {return t.refusal.text}
    if e!=.None {return vcs.error_text(e)}
    return ""
}

// Why there is no workspace to work with.
kai_missing :: proc(s:^Session) -> string {
    if !s.has_project {return "The editor has no project"}
    if s.store.root=="" {return "The editor has no store, where Kai keeps the changes: start it with --store <folder>"}
    if st:=collab_state(s);st!=nil && st.role==.Guest && st.phase!=.Ended {return "A guest of a session keeps no changes: its host records them"}
    if k:=s.kai;k!=nil && k.error==.Missing {return "The project does not use version control: kai.init, or Enable Kai in the Kai tab, makes it a Kai workspace"}
    if k:=s.kai;k!=nil && k.error!=.None {return fmt.tprintf("The Kai workspace of the project does not open: %s",vcs.error_text(k.error))}
    return "The Kai workspace of the project is not open"
}

// Files Kai wrote are read again where they are loaded; the document in
// front whose file went closes.
@(private)
kai_wrote :: proc(s:^Session,relative:[]string) {
    if len(relative)==0 || s.app==nil {return}
    files:=make([dynamic]string,0,len(relative),context.temp_allocator)
    for path in relative {append(&files,project.path(s.project_root,path,allocator=context.temp_allocator))}
    if s.app.assets!=nil {
        assets_wrote(s,..files[:])
        for file in files {
            if inside,found:=asset.registry_relative(&s.app.assets.registry,file);found {host.app_asset_changed(s.app,inside)}
        }
    }
    for file in files {
        if strings.has_suffix(file,".slang") && s.build!=nil {programs_publish_request(s)}
    }
    if s.document!=nil {
        if open:=document_file(s.document);open!="" && !os.exists(open) {
            for file in files {
                if project.path_same(file,open) {document_close_active(s);break}
            }
        }
    }
}

// Before an operation: what the editor holds is written and recorded.
@(private)
kai_prepare :: proc(s:^Session) -> (w:^vcs.Workspace,message:string) {
    w=kai_workspace(s)
    if w==nil {return nil,kai_missing(s)}
    if playing(s) {return nil,"Stop the game first"}
    files_flush(s,true)
    if !kai_files_settled(s) {return nil,"Finish the edit that is open first"}
    if message=kai_snapshot(s);message!="" {return nil,message}
    return w,""
}

@(private)
kai_finish :: proc(s:^Session,e:vcs.Error,changed:[]string) -> string {
    kai_wrote(s,changed)
    if e==.None {kai_publish(s)}
    kai_read(s)
    if e!=.None {return vcs.error_text(e)}
    return ""
}

// A new change on parents (the working copy when none) as the working copy.
kai_new :: proc(s:^Session,parents:[]vcs.Revision,description:string) -> string {
    w,message:=kai_prepare(s)
    if w==nil {return message}
    changed:=make([dynamic]string,context.temp_allocator)
    _,e:=ka.new_change(w,parents,description,&changed)
    return kai_finish(s,e,changed[:])
}

// Whether the file at path is checked in CHANGES: what New change closes.
kai_checked :: proc(st:^Kai_State,path:string) -> bool {
    toggled:=false
    for p in st.toggled {if p==path {toggled=true;break}}
    return st.unchecked_all==toggled
}

// Checks or unchecks the file at path.
kai_check :: proc(st:^Kai_State,path:string,checked:bool) {
    if kai_checked(st,path)==checked {return}
    for p,k in st.toggled {
        if p!=path {continue}
        delete(p)
        unordered_remove(&st.toggled,k)
        return
    }
    append(&st.toggled,strings.clone(path))
}

// Every file checked, or none.
kai_checks_reset :: proc(st:^Kai_State,unchecked:bool) {
    for p in st.toggled {delete(p)}
    clear(&st.toggled)
    st.unchecked_all=unchecked
}

// Closes the working change with the files checked in CHANGES, described with
// description when given, and leaves the others in a new working change; with
// every file checked, a new change as kai_new. The files are read again after
// the snapshot, so one that changed since the click goes by its own check.
kai_new_checked :: proc(s:^Session,description:string) -> string {
    w,message:=kai_prepare(s)
    if w==nil {return message}
    st:=s.kai.state
    diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
    if e:=ka.diff(w,vcs.repo_working(&w.repo),&diffs);e!=.None {return kai_finish(s,e,nil)}
    picked:=make([dynamic]string,0,len(diffs),context.temp_allocator)
    for d in diffs {
        if kai_checked(st,d.path) {append(&picked,d.path)}
    }
    if len(picked)==len(diffs) {
        changed:=make([dynamic]string,context.temp_allocator)
        _,e:=ka.new_change(w,nil,description,&changed)
        if e==.None {kai_checks_reset(st,false)}
        return kai_finish(s,e,changed[:])
    }
    if len(picked)==0 {return "No file is checked: check the files the change closes with"}
    _,_,text,_:=kai_split(s,"@",picked[:],description)
    if text=="" {kai_checks_reset(st,false)}
    return text
}

// Splits the change text names by paths: the first keeps the change with the
// picked files and description when given, the second the rest. invalid: the
// message says which argument was wrong.
kai_split :: proc(s:^Session,change:string,paths:[]string,description:string) -> (first,second:vcs.Revision,message:string,invalid:bool) {
    w:^vcs.Workspace
    if w,message=kai_prepare(s);w==nil {return}
    text:Maybe(string)
    if description!="" {text=description}
    refused:string
    e:vcs.Error
    first,second,e=ka.split(w,change,paths,text,&refused)
    message=kai_finish(s,e,nil)
    if e==.Invalid_Argument && refused!="" {message,invalid=refused,true}
    return
}

kai_describe :: proc(s:^Session,revision:vcs.Revision,description:string) -> string {
    w,message:=kai_prepare(s)
    if w==nil {return message}
    _,e:=vcs.change_describe(&w.repo,revision,description)
    return kai_finish(s,e,nil)
}

kai_undo :: proc(s:^Session) -> (undone:string,message:string) {
    w:^vcs.Workspace
    if w,message=kai_prepare(s);w==nil {return}
    changed:=make([dynamic]string,context.temp_allocator)
    op,e:=ka.undo(w,&changed)
    return op.description,kai_finish(s,e,changed[:])
}

kai_restore :: proc(s:^Session,from:vcs.Revision) -> string {
    w,message:=kai_prepare(s)
    if w==nil {return message}
    changed:=make([dynamic]string,context.temp_allocator)
    e:=ka.restore(w,from,&changed)
    return kai_finish(s,e,changed[:])
}

kai_bookmark :: proc(s:^Session,name:string,revision:vcs.Revision) -> string {
    w,message:=kai_prepare(s)
    if w==nil {return message}
    if !vcs.bookmark_name_valid(name) {return fmt.tprintf("%q is no bookmark name: letters, digits, - _ . and / of at most %d bytes",name,vcs.BOOKMARK_NAME_MAX)}
    return kai_finish(s,vcs.bookmark_set(&w.repo,name,revision),nil)
}

// Resolves the conflict at path: one side whole, or the merge with theirs for
// the conflicts whose paths are listed. The file is written and recorded.
kai_resolve :: proc(s:^Session,path:string,whole:ka.Resolve_Whole,theirs:[]string) -> string {
    w,message:=kai_prepare(s)
    if w==nil {return message}
    types:=kai_types(s)
    if types==nil {return "The editor has no assets"}
    e:=ka.conflict_resolve(w,types,path,whole,theirs)
    if e==.Io {return fmt.tprintf("%s could not be written or removed: give this user access to it",path)}
    if e==.Invalid_Argument {return fmt.tprintf("%s is not in conflict, or its sides do not read: kai.conflicts lists the files",path)}
    changed:=[1]string{path}
    if s.kai.state.unfolded==path {kai_unfold(s,"")}
    return kai_finish(s,e,changed[:])
}

// Shows the fields in conflict of a file; "" folds it.
kai_unfold :: proc(s:^Session,path:string) {
    st:=s.kai.state
    if st==nil {return}
    delete(st.unfolded)
    st.unfolded=strings.clone(path)
    clear(&st.picks)
    kai_read(s)
}

// What the tab shows, read again into the arena.
kai_read :: proc(s:^Session) {
    w:=kai_workspace(s)
    if w==nil {return}
    st:=s.kai.state
    vmem.arena_destroy(&st.arena)
    st.view={}
    if vmem.arena_init_growing(&st.arena)!=nil {return}
    a:=vmem.arena_allocator(&st.arena)
    v:=&st.view
    r:=&w.repo
    working:=vcs.repo_working(r)
    if c,e:=vcs.change_get(r.s,working,a);e==.None {
        v.change=ka.change_text(c.id,a)
        v.title=strings.concatenate({"@ ",v.change},a)
        v.description=c.description
    }
    diffs:=make([dynamic]vcs.Diff,context.temp_allocator)
    ka.diff(w,working,&diffs,a)
    // A conflict of a merge is in its parents' tree too: listed whether it changed or not.
    files:=make([dynamic]Kai_File,0,len(diffs)+len(w.state.conflicts),a)
    for m in w.state.conflicts {append(&files,Kai_File{strings.clone(m.path,a),'C',false})}
    for d in diffs {
        listed:=false
        for &f in files {
            if f.path==d.path {f.changed,listed=true,true;break}
        }
        if listed {continue}
        append(&files,Kai_File{d.path,vcs.diff_mark(d),true})
    }
    v.files=files[:]
    // A check of a file no longer listed goes.
    for k:=0;k<len(st.toggled); {
        listed:=false
        for f in v.files {if f.path==st.toggled[k] {listed=true;break}}
        if listed {k+=1;continue}
        delete(st.toggled[k])
        unordered_remove(&st.toggled,k)
    }
    rows:=make([dynamic]ka.Log_Row,context.temp_allocator)
    ka.log(w,KAI_LOG_ROWS,&rows,a)
    v.rows=make([]Kai_Row,len(rows),a)
    for row,i in rows {
        names:=make([dynamic]string,0,len(row.bookmarks)+1,context.temp_allocator)
        append(&names,..row.bookmarks)
        if shared:=kai_shared_names(s,row.revision);shared!="" {append(&names,shared)}
        v.rows[i]={
            change=ka.change_text(row.change.id,a),description=row.change.description,
            bookmarks=strings.join(names[:],", ",a),working=row.working,conflicts=row.conflicts,
            authors=len(row.change.coauthors),turns=kai_turns(row.change.attachments),revision=row.revision,
        }
    }
    if st.picked!={} {
        changed:=make([dynamic]vcs.Diff,context.temp_allocator)
        if ka.diff(w,st.picked,&changed,a)==.None {
            v.picked=make([]Kai_File,len(changed),a)
            for d,k in changed {v.picked[k]={d.path,vcs.diff_mark(d),true}}
        } else {
            st.picked={}
        }
    }
    marks:=make([dynamic]string,a)
    for &b in r.view.bookmarks {
        if value,resolved:=vcs.terms_resolved(&b.terms);resolved {
            text:="?"
            if c,e:=vcs.change_get(r.s,value,context.temp_allocator);e==.None {text=ka.change_text(c.id,a)}
            append(&marks,fmt.aprintf("%s %s",b.name,text,allocator=a))
        } else {
            append(&marks,fmt.aprintf("%s in conflict",b.name,allocator=a))
        }
    }
    v.bookmarks=marks[:]
    if op,e:=vcs.op_get(r.s,r.op,a);e==.None {
        v.operation,v.redo=op.description,op.kind==.Undo
    }
    if st.unfolded!="" {
        fields:=make([dynamic]ka.Field_Conflict,a)
        is_asset:=false
        if types:=kai_types(s);types!=nil {is_asset,_=ka.conflict_fields(w,types,st.unfolded,&fields,a)}
        v.fields,v.whole=fields[:],!is_asset
        resize(&st.picks,len(fields))
    }
}
