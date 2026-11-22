package kai

import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"
import "mirai:store"

@(private="file")
Fixture :: struct {
    folder:string,
    s:store.Store,
}

@(private="file")
fixture :: proc(t:^testing.T,name:string) -> (f:Fixture,ok:bool) {
    f.folder=base.test_folder(t,name)
    if f.folder=="" {return}
    e:store.Error
    f.s,e=store.open(strings.concatenate({f.folder,"/store"},context.temp_allocator))
    return f,testing.expect_value(t,e,store.Error.None)
}

@(private="file")
folder_of :: proc(f:^Fixture,name:string) -> string {
    path:=strings.concatenate({f.folder,"/",name},context.temp_allocator)
    os.make_directory_all(path)
    return path
}

// Writes text at root/path with its time age in the past, so it is settled.
@(private="file")
write :: proc(t:^testing.T,root,path,text:string,age:=time.Hour,loc:=#caller_location) {
    full:=strings.concatenate({root,"/",path},context.temp_allocator)
    if dir,_:=os.split_path(full);dir!="" {os.make_directory_all(dir)}
    testing.expect(t,os.write_entire_file(full,transmute([]u8)text)==nil,loc=loc)
    if age>0 {
        old:=time.time_add(time.now(),-age)
        testing.expect(t,os.change_times(full,old,old)==nil,loc=loc)
    }
}

@(private="file")
read :: proc(root,path:string) -> string {
    bytes,e:=os.read_entire_file(strings.concatenate({root,"/",path},context.temp_allocator),context.temp_allocator)
    if e!=nil {return "<missing>"}
    return string(bytes)
}

@(private="file")
tree_of :: proc(t:^testing.T,s:^store.Store,revision:Revision) -> store.Hash {
    c,e:=change_get(s,revision,context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    return c.tree
}

@(test)
a_snapshot_rehashes_only_changed_files :: proc(t:^testing.T) {
    f,ok:=fixture(t,"kai-snapshot");if !ok {return}
    defer store.close(&f.s)
    root:=folder_of(&f,"work")
    write(t,root,"a.txt","alpha")
    write(t,root,"b.txt","beta")
    write(t,root,"sub/c.txt","gamma")
    w:Workspace
    testing.expect_value(t,workspace_create(&w,root,&f.s,identity_make()),Error.None)
    defer workspace_close(&w)
    first:=repo_working(&w.repo)
    op:=w.repo.op

    report,e:=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    testing.expect_value(t,report.files,3)
    testing.expect_value(t,report.hashed,0)
    testing.expect(t,report.revision==first && w.repo.op==op,"an unchanged folder writes no operation")

    write(t,root,"b.txt","beta, longer now",30*time.Minute)
    report,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    testing.expect_value(t,report.hashed,1)
    testing.expect(t,report.revision!=first)

    // A file modified just now is racy: hashed again until it settles.
    write(t,root,"d.txt","fresh",0)
    report,_=workspace_snapshot(&w)
    testing.expect_value(t,report.hashed,1)
    settled:=report.revision
    report,_=workspace_snapshot(&w)
    testing.expect_value(t,report.hashed,1)
    testing.expect(t,report.revision==settled)
    write(t,root,"d.txt","fresh",time.Hour)
    report,_=workspace_snapshot(&w)
    testing.expect_value(t,report.hashed,1)

    // Touched paths alone are stated: a change nobody reported is not seen.
    write(t,root,"a.txt","alpha two",20*time.Minute)
    write(t,root,"sub/c.txt","gamma two",20*time.Minute)
    testing.expect_value(t,workspace_touched(&w,{"a.txt"}),Error.None)
    report,_=workspace_snapshot(&w)
    testing.expect_value(t,report.hashed,1)
    files:=make([dynamic]File,context.temp_allocator)
    testing.expect_value(t,tree_files(&f.s,tree_of(t,&f.s,report.revision),&files,context.temp_allocator),Error.None)
    for file in files {
        if file.path=="sub/c.txt" {
            bytes,_:=file_bytes(&f.s,file.address,context.temp_allocator)
            testing.expect_value(t,string(bytes),"gamma")
        }
    }
    report,_=workspace_snapshot(&w)
    testing.expect_value(t,report.hashed,1)
    testing.expect_value(t,report.files,4)
}

@(private="file")
expect_refused :: proc(t:^testing.T,bytes:[]u8,decode:proc(bytes:[]u8) -> Error,name:string,versioned:=true,loc:=#caller_location) {
    testing.expect_value(t,decode(bytes),Error.None,loc=loc)
    for n in 0..<len(bytes) {
        if decode(bytes[:n])!=.Corrupt {
            testing.expectf(t,false,"%s cut to %d bytes is not refused",name,n,loc=loc)
            return
        }
    }
    copy_bytes:=slice.clone(bytes,context.temp_allocator)
    // Any one byte changed: refused or read, never past the bytes.
    for k in 0..<len(copy_bytes) {
        before:=copy_bytes[k]
        for v in ([3]u8{0,0xff,before~0x5a}) {
            copy_bytes[k]=v
            _=decode(copy_bytes)
        }
        copy_bytes[k]=before
    }
    // Another version, a reserved byte or a count past the bytes.
    if versioned {
        version:=slice.clone(bytes,context.temp_allocator)
        version[4]+=1
        testing.expectf(t,decode(version)==.Corrupt,"%s of another version is read",name,loc=loc)
    }
    noise:=make([]u8,len(bytes)+64,context.temp_allocator)
    r:=rand.create(7)
    for _ in 0..<64 {
        for &b in noise {b=u8(rand.uint32(rand.default_random_generator(&r)))}
        testing.expectf(t,decode(noise)==.Corrupt,"%s of noise is read",name,loc=loc)
        copy(noise,bytes[:8])
        _=decode(noise)
    }
}

@(test)
hostile_kai_records_are_refused :: proc(t:^testing.T) {
    identity:=identity_make()
    parent:=Revision{0=1}
    other:=Revision{0=2}
    c:=Change{id={0=9},tree={0=3},author=identity.key,created=5,written=6,parents={parent,other},coauthors={Key{0=4}},turns={Turn_Ref{task=7}},description="fix the door"}
    change_bytes,e:=change_encode(&c,&identity,context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    testing.expect(t,change_verify(change_bytes),"a change verifies by its author")
    forged:=slice.clone(change_bytes,context.temp_allocator)
    forged[size_of(Change_Head)+3]~=1
    testing.expect(t,!change_verify(forged),"a changed parent breaks the signature")
    expect_refused(t,change_bytes,proc(b:[]u8) -> Error {_,e:=change_decode(b,context.temp_allocator);return e},"a change")

    adds:=[]Term{{address={0=1},size=1,kind=.File},{address={0=2},size=2,kind=.File}}
    removes:=[]Term{{address={0=3},size=3,kind=.File}}
    conflict_bytes,_:=conflict_encode(adds,removes,DRIVER_TEXT,context.temp_allocator)
    expect_refused(t,conflict_bytes,proc(b:[]u8) -> Error {
        terms:=terms_make(Term,context.temp_allocator)
        _,e:=conflict_decode(b,&terms)
        return e
    },"a conflict")
    unsimplified,_:=conflict_encode(adds,[]Term{adds[1]},0,context.temp_allocator)
    terms:=terms_make(Term,context.temp_allocator)
    _,e=conflict_decode(unsimplified,&terms)
    testing.expect_value(t,e,Error.Corrupt)
    _,e=conflict_encode(adds[:1],nil,0,context.temp_allocator)
    testing.expect_value(t,e,Error.Invalid_Argument)

    v:View
    view_init(&v,context.temp_allocator)
    append(&v.heads,parent,other)
    append(&v.workspaces,View_Workspace{{0=1},parent})
    bookmark_add(&v,"main",{parent},nil)
    bookmark_add(&v,"split",{parent,other},{Revision{0=5}})
    view_bytes,_:=view_encode(&v,context.temp_allocator)
    expect_refused(t,view_bytes,proc(b:[]u8) -> Error {
        v:View
        view_init(&v,context.temp_allocator)
        return view_decode(b,&v)
    },"a view")

    op:=Operation{kind=.Bookmark,parents={store.Hash{0=8}},view={0=9},workspace={0=1},time=10,rewrites={Rewrite{parent,other}},description="move main"}
    op_bytes,_:=op_encode(&op,context.temp_allocator)
    expect_refused(t,op_bytes,proc(b:[]u8) -> Error {_,e:=op_decode(b,context.temp_allocator);return e},"an operation")

    entries:=[]Tree_Entry{
        {name="a.txt",kind=.File,address={0=1},size=3,files=1},
        {name="b",kind=.Folder,address={0=2},size=10,files=4,conflicts=1},
        {name="c",kind=.Conflict,address={0=3},files=1,conflicts=1},
    }
    folder_bytes,totals,_:=folder_encode(entries,context.temp_allocator)
    @(static) folder_totals:Totals
    folder_totals=totals
    expect_refused(t,folder_bytes,proc(b:[]u8) -> Error {
        out:=make([dynamic]Tree_Entry,context.temp_allocator)
        return folder_decode(b,folder_totals,&out)
    },"a folder",versioned=false)
    out:=make([dynamic]Tree_Entry,context.temp_allocator)
    folded:=[]Tree_Entry{{name="A",kind=.File,address={0=1},size=1,files=1},{name="a",kind=.File,address={0=2},size=1,files=1}}
    folded_bytes,folded_totals,_:=folder_encode(folded,context.temp_allocator)
    testing.expect_value(t,folder_decode(folded_bytes,folded_totals,&out),Error.Corrupt)

    index:Stat_Index
    index.rows=make([dynamic]Stat_Row,context.temp_allocator)
    index.pool=make([dynamic]u8,context.temp_allocator)
    append(&index.pool,"a.txtb/c")
    append(&index.rows,Stat_Row{size=3,mtime_ns=1,inode=2,address={0=1},path_at=0,path_len=5},Stat_Row{size=4,address={0=2},path_at=5,path_len=3,flags=STAT_RACY})
    stat_bytes,_:=stat_encode(&index,context.temp_allocator)
    expect_refused(t,stat_bytes,proc(b:[]u8) -> Error {
        index:Stat_Index
        index.rows=make([dynamic]Stat_Row,context.temp_allocator)
        index.pool=make([dynamic]u8,context.temp_allocator)
        return stat_decode(b,&index)
    },"a stat index")

    st:=Workspace_State{repo={0=1},id={0=2},op={0=3},tree={0=4},conflicts=make([dynamic]Materialized,context.temp_allocator)}
    append(&st.conflicts,Materialized{path="x/y.txt",conflict={0=5},written={0=6}})
    state_bytes,_:=state_encode(&st,context.temp_allocator)
    expect_refused(t,state_bytes,proc(b:[]u8) -> Error {
        st:Workspace_State
        st.conflicts=make([dynamic]Materialized,context.temp_allocator)
        return state_decode(b,&st,context.temp_allocator)
    },"a workspace state")
}

@(test)
conflicts_simplify_and_resolve_by_edit :: proc(t:^testing.T) {
    a,b,c:=Revision{0=1},Revision{0=2},Revision{0=3}
    m:=terms_make(Revision,context.temp_allocator)
    append(&m.adds,a,b)
    append(&m.removes,b)
    terms_simplify(&m)
    value,resolved:=terms_resolved(&m)
    testing.expect(t,resolved && value==a,"a side equal to the base cancels")
    clear(&m.adds);clear(&m.removes)
    append(&m.adds,a,a)
    append(&m.removes,c)
    value,resolved=terms_resolved(&m)
    testing.expect(t,resolved && value==a,"both sides made the same change")
    clear(&m.adds);clear(&m.removes)
    append(&m.adds,a,b)
    append(&m.removes,c)
    terms_simplify(&m)
    _,resolved=terms_resolved(&m)
    testing.expect(t,!resolved)

    f,ok:=fixture(t,"kai-conflicts");if !ok {return}
    defer store.close(&f.s)
    root:=folder_of(&f,"work")
    write(t,root,"f.txt","1\n2\n3\n4\n5\n")
    write(t,root,"g.txt","a\nb\nc\nd\ne\n")
    w:Workspace
    testing.expect_value(t,workspace_create(&w,root,&f.s,identity_make()),Error.None)
    defer workspace_close(&w)
    base_change:=repo_working(&w.repo)

    left,e:=workspace_new(&w,{base_change},"left")
    testing.expect_value(t,e,Error.None)
    write(t,root,"f.txt","one\n2\n3\n4\n5\n",50*time.Minute)
    write(t,root,"g.txt","A\nb\nc\nd\ne\n",50*time.Minute)
    report,_:=workspace_snapshot(&w)
    left=report.revision
    right,_:=workspace_new(&w,{base_change},"right")
    testing.expect_value(t,read(root,"f.txt"),"1\n2\n3\n4\n5\n")
    write(t,root,"f.txt","uno\n2\n3\n4\n5\n",40*time.Minute)
    write(t,root,"g.txt","a\nb\nc\nd\nE\n",40*time.Minute)
    report,_=workspace_snapshot(&w)
    right=report.revision

    merged,_:=workspace_new(&w,{left,right},"merge")
    totals,_:=tree_totals(&f.s,tree_of(t,&f.s,merged))
    testing.expect_value(t,totals.conflicts,1)
    testing.expect_value(t,read(root,"g.txt"),"A\nb\nc\nd\nE\n")
    text:=read(root,"f.txt")
    testing.expect(t,strings.contains(text,"<<<<<<< ours\none\n") && strings.contains(text,"=======\nuno\n>>>>>>> theirs\n"),text)

    // Rebasing the conflict back onto one side composes its terms: they cancel.
    tree:=tree_of(t,&f.s,merged)
    rebased,re:=tree_rebase(&w.repo.merger,tree,tree_of(t,&f.s,right),tree_of(t,&f.s,left))
    testing.expect_value(t,re,Error.None)
    rebased_totals,_:=tree_totals(&f.s,rebased)
    testing.expect_value(t,rebased_totals.conflicts,0)
    testing.expect(t,rebased==tree_of(t,&f.s,left),"the conflict and the side it came from cancel into the other side")

    // A snapshot of the untouched markers keeps the conflict; an edit resolves it.
    status,se:=workspace_status(&w,context.temp_allocator)
    testing.expect_value(t,se,Error.None)
    testing.expect_value(t,status.conflicts,1)
    write(t,root,"f.txt","both\n2\n3\n4\n5\n",30*time.Minute)
    status,_=workspace_status(&w,context.temp_allocator)
    testing.expect_value(t,status.conflicts,0)
    testing.expect_value(t,len(w.state.conflicts),0)
    files:=make([dynamic]File,context.temp_allocator)
    tree_files(&f.s,tree_of(t,&f.s,status.revision),&files,context.temp_allocator)
    testing.expect_value(t,len(files),2)
    for file in files {testing.expect(t,file.kind==.File,file.path)}
}

@(test)
every_operation_undoes :: proc(t:^testing.T) {
    f,ok:=fixture(t,"kai-undo");if !ok {return}
    defer store.close(&f.s)
    r:Repo
    testing.expect_value(t,repo_create(&r,&f.s,identity_make(),random_id(Workspace_Id)),Error.None)
    defer repo_close(&r)
    first:=repo_working(&r)
    file,_:=store.put(&f.s,transmute([]u8)string("hello\n"))
    tree,_:=tree_build(&f.s,{File{path="hello.txt",kind=.File,address=file,size=6}})
    other:Revision

    Step :: enum {Snapshot,New,Describe,Restore,Bookmark,Rebase,Merge,Workspace,Abandon,Move_Bookmark}
    for step in Step {
        before:=r.view_address
        e:Error
        switch step {
        case .Snapshot: _,e=change_snapshot(&r,tree)
        case .New: other,e=change_new(&r,{repo_working(&r)},"second")
        case .Describe: _,e=change_describe(&r,repo_working(&r),"described")
        case .Restore:
            c,_:=change_get(&f.s,repo_working(&r),context.temp_allocator)
            _,e=change_restore(&r,repo_working(&r),c.parents[0])
        case .Bookmark: e=bookmark_set(&r,"main",repo_working(&r))
        case .Rebase:
            side,_:=change_new(&r,{r.view.heads[0]},"side")
            before=r.view_address
            other,e=change_rebase(&r,side,{first})
        case .Merge:
            x,_:=change_new(&r,{first},"x")
            before=r.view_address
            _,e=change_new(&r,{x,other},"merge")
        case .Workspace: _,e=workspace_add_to_view(&r,random_id(Workspace_Id),r.view.heads[0])
        case .Abandon: e=change_abandon(&r,repo_working(&r))
        case .Move_Bookmark: e=bookmark_set(&r,"main",other)
        }
        testing.expectf(t,e==.None,"%v: %v",step,e)
        after:=r.view_address
        testing.expectf(t,after!=before,"%v changes the view",step)
        testing.expectf(t,op_undo(&r,r.op)==.None,"%v undoes",step)
        testing.expectf(t,r.view_address==before,"undoing %v gives the view before it",step)
        testing.expectf(t,op_undo(&r,r.op)==.None,"the undo of %v undoes",step)
        testing.expectf(t,r.view_address==after,"undoing the undo of %v gives the view after it",step)
    }
}

@(test)
op_heads_of_two_workspaces_merge :: proc(t:^testing.T) {
    f,ok:=fixture(t,"kai-op-heads");if !ok {return}
    defer store.close(&f.s)
    root_a,root_b:=folder_of(&f,"a"),folder_of(&f,"b")
    write(t,root_a,"readme.txt","shared\n")
    a,b:Workspace
    testing.expect_value(t,workspace_create(&a,root_a,&f.s,identity_make()),Error.None)
    defer workspace_close(&a)
    testing.expect_value(t,workspace_add(&b,root_b,&a,identity_make()),Error.None)
    defer workspace_close(&b)
    testing.expect_value(t,read(root_b,"readme.txt"),"shared\n")
    testing.expect_value(t,repo_refresh(&a.repo),Error.None)
    testing.expect(t,a.repo.view_address==b.repo.view_address)

    // Each writes an operation without seeing the other's.
    testing.expect_value(t,bookmark_set(&a.repo,"from-a",repo_working(&a.repo)),Error.None)
    testing.expect_value(t,bookmark_set(&b.repo,"from-b",repo_working(&b.repo)),Error.None)
    refs,_:=store.ref_list(&f.s,a.repo.namespace,context.temp_allocator)
    ops:=0
    for ref in refs {if strings.has_prefix(ref.name,"ws-") {ops+=1}}
    testing.expect_value(t,ops,2)

    testing.expect_value(t,repo_refresh(&a.repo),Error.None)
    merged,_:=op_get(&f.s,a.repo.op,context.temp_allocator)
    testing.expect_value(t,merged.kind,Op_Kind.Merge)
    testing.expect_value(t,len(merged.parents),2)
    testing.expect(t,view_bookmark(&a.repo.view,"from-a")!=nil && view_bookmark(&a.repo.view,"from-b")!=nil,"the merged view keeps both")
    testing.expect_value(t,len(a.repo.view.workspaces),2)

    // The other workspace reads the merge as its newest operation.
    testing.expect_value(t,repo_refresh(&b.repo),Error.None)
    testing.expect(t,b.repo.op==a.repo.op && b.repo.view_address==a.repo.view_address)
}

@(test)
a_switch_cut_midway_recovers_on_status :: proc(t:^testing.T) {
    f,ok:=fixture(t,"kai-switch");if !ok {return}
    defer store.close(&f.s)
    root:=folder_of(&f,"work")
    write(t,root,"a.txt","a1")
    write(t,root,"b.txt","b1")
    write(t,root,"c/d.txt","d1")
    identity:=identity_make()
    w:Workspace
    testing.expect_value(t,workspace_create(&w,root,&f.s,identity),Error.None)
    one:=repo_working(&w.repo)
    two,_:=workspace_new(&w,{one})
    write(t,root,"a.txt","a2",50*time.Minute)
    write(t,root,"b.txt","b2",50*time.Minute)
    write(t,root,"c/d.txt","d2",50*time.Minute)
    write(t,root,"e.txt","e2",50*time.Minute)
    report,_:=workspace_snapshot(&w)
    two=report.revision

    w.cut_after=2
    testing.expect_value(t,workspace_switch(&w,one),Error.Io)
    workspace_close(&w)
    changed:=0
    for p in ([]string{"a.txt","b.txt","c/d.txt","e.txt"}) {
        if strings.has_suffix(read(root,p),"1") || read(root,p)=="<missing>" {changed+=1}
    }
    testing.expect_value(t,changed,2)

    testing.expect_value(t,workspace_open(&w,root,&f.s,identity),Error.None)
    defer workspace_close(&w)
    status,e:=workspace_status(&w,context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    testing.expect(t,status.recovered,"the cut switch is finished")
    testing.expect(t,status.revision==one,"the working copy is the change switched to")
    testing.expect_value(t,read(root,"a.txt"),"a1")
    testing.expect_value(t,read(root,"b.txt"),"b1")
    testing.expect_value(t,read(root,"c/d.txt"),"d1")
    testing.expect_value(t,read(root,"e.txt"),"<missing>")
    testing.expect(t,w.state.target=={},"no switch is left under way")
    _=two
}

@(test)
kai_imports_stay_engine_agnostic :: proc(t:^testing.T) {
    folder,_:=os.split_path(#file)
    listed,e:=os.read_all_directory_by_path(folder,context.temp_allocator)
    testing.expect(t,e==nil)
    allowed_exact:=[]string{"mirai:store","mirai:exchange","mirai:net"}
    sources:=0
    for info in listed {
        if !strings.has_suffix(info.name,".odin") {continue}
        sources+=1
        bytes,_:=os.read_entire_file(info.fullpath,context.temp_allocator)
        for line in strings.split_lines(string(bytes),context.temp_allocator) {
            trimmed:=strings.trim_space(line)
            if !strings.has_prefix(trimmed,"import ") {continue}
            quote:=strings.index_byte(trimmed,'"')
            end:=strings.last_index_byte(trimmed,'"')
            if quote<0 || end<=quote {continue}
            path:=trimmed[quote+1:end]
            ok:=strings.has_prefix(path,"base:") || strings.has_prefix(path,"core:") || strings.has_prefix(path,"mirai:std/") || slice.contains(allowed_exact,path)
            testing.expectf(t,ok,"%s imports %s: kai stays engine-agnostic",info.name,path)
        }
    }
    testing.expect(t,sources>5)
}
