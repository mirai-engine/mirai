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
expect_refused :: proc(t:^testing.T,bytes:[]u8,decode:proc(bytes:[]u8) -> Error,name:string,versioned:=false,loc:=#caller_location) {
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
    // Another version (of what is no object: its version is in its bytes), a reserved byte or a count past the bytes.
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
    c:=Change{id={0=9},tree={0=3},author=identity.key,created=5,written=6,parents={parent,other},coauthors={Key{0=4}},attachments={{1,{0=7}},{1,{0=8}},{2,{0=1}}},description="fix the door"}
    change_bytes,e:=change_encode(&c,&identity,context.temp_allocator)
    testing.expect_value(t,e,Error.None)
    // An attachment list out of order, repeated, untyped, of no object or past its bound is refused.
    head_size:=size_of(Change_Head)+len(c.parents)*size_of(Revision)+len(c.coauthors)*size_of(Key)
    for bad in ([]Attachment{{1,{0=7}},{1,{0=6}},{0,{0=9}},{1,{}}}) {
        forged_list:=slice.clone(change_bytes,context.temp_allocator)
        (^Attachment)(&forged_list[head_size+size_of(Attachment)])^=bad
        _,de:=change_decode(forged_list,context.temp_allocator)
        testing.expectf(t,de==.Corrupt,"an attachment list with %v second is refused",bad)
    }
    listed:=make([]Attachment,ATTACHMENTS_MAX+1,context.temp_allocator)
    for &a,i in listed {a={1,{0=u8(i+1),1=u8(i>>8)+1}}}
    past:=c
    past.attachments=listed
    _,e=change_encode(&past,&identity,context.temp_allocator)
    testing.expect_value(t,e,Error.Too_Large)
    past_bytes:=slice.clone(change_bytes,context.temp_allocator)
    (^Change_Head)(raw_data(past_bytes)).attachments=ATTACHMENTS_MAX+1
    _,e=change_decode(past_bytes,context.temp_allocator)
    testing.expect_value(t,e,Error.Corrupt)
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
    // Names that differ only in case, side by side in byte order or apart ("Ab" < "B" < "aB").
    f,opened:=fixture(t,"kai-hostile-fold")
    if !opened {return}
    defer store.close(&f.s)
    // A kind's version is in the meta of its object's root, from VERSIONS: one of another is refused there.
    for kind in ([]Object_Kind{.Change,.Operation,.Log_Page,.Device_Refs,.Overlay_Record,.Envelopes}) {
        p,_:=store.put_begin(&f.s)
        store.put_write(&p,change_bytes)
        meta:=object_meta(kind)
        meta[offset_of(Meta,version)]+=1
        address,_,_:=store.put_finish(&p,meta[:])
        _,ge:=object_get(&f.s,address,kind,context.temp_allocator)
        testing.expectf(t,ge==.Corrupt,"an object of kind %v of another version is read",kind)
        meta[offset_of(Meta,version)]-=1
        p,_=store.put_begin(&f.s)
        store.put_write(&p,change_bytes)
        address,_,_=store.put_finish(&p,meta[:])
        _,ge=object_get(&f.s,address,kind,context.temp_allocator)
        testing.expectf(t,ge==.None,"an object of kind %v of its version is not read",kind)
    }
    for names in ([?][3]string{{"A","a","b"},{"Ab","B","aB"},{"\u00c9t\u00e9","b","\u00e9t\u00e9"}}) {
        folded:=[3]Tree_Entry{}
        for name,k in names {folded[k]={name=name,kind=.File,address={0=u8(k+1)},size=1,files=1}}
        folded_bytes,folded_totals,_:=folder_encode(folded[:],context.temp_allocator)
        testing.expectf(t,folder_decode(folded_bytes,folded_totals,&out)==.Corrupt,"%v decodes",names)
        files:=[3]File{}
        for name,k in names {files[k]={path=name,kind=.File,address=empty_address()}}
        slice.sort_by(files[:],proc(a,b:File) -> bool {return a.path<b.path})
        clash:[2]string
        _,e:=tree_build(&f.s,files[:],clash=&clash)
        testing.expectf(t,e==.Invalid_Argument && clash[0]!="" && strings.equal_fold(clash[0],clash[1]),"%v builds: %v %v",names,e,clash)
    }

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
    },"a workspace state",versioned=true)

    // Previews a peer publishes for the web view: what the encoders make is
    // taken, and texts past their bounds or with control bytes, another head,
    // a count that is no number and anything a PNG header does not say are not.
    summary,_:=preview_summary_encode("mesh",{{"Vertices","788"},{"Names","a\tb\nc"}},context.temp_allocator)
    testing.expect_value(t,preview_check(.Summary,summary),Error.None)
    rows:=[]Preview_Row{{'~',"Lamp","Transform.position: 0 -> 5"},{'+',"","Light"}}
    detail,_:=preview_detail_encode(&Preview_Detail{changed=1,added=1,rows=rows},context.temp_allocator)
    testing.expect_value(t,preview_check(.Detail,detail),Error.None)
    many:=make([]Preview_Fact,PREVIEW_FACTS_MAX+1,context.temp_allocator)
    for &f in many {f={"label","value"}}
    _,e=preview_summary_encode("mesh",many,context.temp_allocator)
    testing.expect_value(t,e,Error.Too_Large)
    long:=strings.repeat("x",PREVIEW_VALUE_MAX+1,context.temp_allocator)
    hostile:=[]struct {kind:Preview_Kind,text:string}{
        {.Summary,""},
        {.Summary,"kai-summary 2\nmesh\n"},
        {.Summary,"kai-summary 1\nmesh"},
        {.Summary,"kai-summary 1\n\n"},
        {.Summary,"kai-summary 1\nmesh\nno tab\n"},
        {.Summary,"kai-summary 1\nmesh\na\tb\tc\n"},
        {.Summary,"kai-summary 1\nmesh\n\tvalue\n"},
        {.Summary,"kai-summary 1\nmesh\na\tb\r\n"},
        {.Summary,"kai-summary 1\nmesh\na\t\xff\n"},
        {.Summary,strings.concatenate({"kai-summary 1\nmesh\na\t",long,"\n"},context.temp_allocator)},
        {.Summary,strings.concatenate({"kai-summary 1\nmesh\n",strings.repeat("a\tb\n",PREVIEW_FACTS_MAX+1,context.temp_allocator)},context.temp_allocator)},
        {.Detail,"kai-detail 1\n1\t2\t3\n"},
        {.Detail,"kai-detail 1\n1\t2\t3\t-4\n"},
        {.Detail,"kai-detail 1\n1\t2\t3\t4\t5\n"},
        {.Detail,"kai-detail 1\n0\t0\t0\t0\n*\tname\ttext\n"},
        {.Detail,"kai-detail 1\n0\t0\t0\t0\n+\tname\n"},
        {.Detail,"kai-detail 1\n0\t0\t0\t9999999999\n"},
        {.Thumbnail,"\x89PNG\r\n\x1a\nnot a png"},
        {.Thumbnail,"kai-summary 1\nmesh\n"},
    }
    for x in hostile {
        testing.expectf(t,preview_check(x.kind,transmute([]u8)x.text)!=.None,"a %v preview %q is refused",x.kind,x.text)
    }
    // A PNG of 2x2 pixels, and one whose header says more than PREVIEW_SIDE_MAX.
    png:=[]u8{0x89,'P','N','G','\r','\n',0x1a,'\n',0,0,0,13,'I','H','D','R',0,0,0,2,0,0,0,2,8,6,0,0,0,0,0,0,0, 0,0,0,0,'I','E','N','D',0xae,0x42,0x60,0x82}
    testing.expect_value(t,preview_check(.Thumbnail,png),Error.None)
    wide:=slice.clone(png,context.temp_allocator)
    wide[18]=0x10
    testing.expect_value(t,preview_check(.Thumbnail,wide),Error.Corrupt)
    testing.expect(t,preview_key(.Summary,{},{0=1})!=preview_key(.Thumbnail,{},{0=1}) && preview_key(.Detail,{0=1},{0=2})!=preview_key(.Detail,{0=2},{0=1}),"a key names the kind and the sides")
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
    tree,_:=tree_build(&f.s,{File{path="hello.txt",kind=.File,address=file,size=6},File{path="world.txt",kind=.File,address=file,size=6}})
    other:Revision

    Step :: enum {Snapshot,Split,New,Describe,Restore,Bookmark,Rebase,Merge,Workspace,Abandon,Move_Bookmark}
    for step in Step {
        before:=r.view_address
        e:Error
        switch step {
        case .Snapshot: _,e=change_snapshot(&r,tree)
        case .Split: _,_,e=change_split(&r,repo_working(&r),{"hello.txt"})
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

    // A merge of operations two workspaces wrote apart is the engine's: it is not undone, and an
    // undo in a workspace takes back its own operation under the merge, keeping the other's.
    second:Repo
    testing.expect_value(t,repo_open(&second,&f.s,r.id,random_id(Workspace_Id),identity_make()),Error.None)
    defer repo_close(&second)
    testing.expect_value(t,bookmark_set(&second,"theirs",first),Error.None)
    testing.expect_value(t,bookmark_set(&r,"ours",first),Error.None)
    own:=r.op
    testing.expect_value(t,repo_refresh(&r),Error.None)
    merge,_:=op_get(&f.s,r.op,context.temp_allocator)
    testing.expect_value(t,merge.kind,Op_Kind.Merge)
    merged:=r.view_address
    testing.expect_value(t,op_undo(&r,r.op),Error.Merged)
    testing.expect(t,r.view_address==merged,"a refused undo changes nothing")
    target,te:=op_undo_target(&r)
    testing.expect(t,te==.None && target==own,"the undo takes back this workspace's operation under the merge")
    testing.expect_value(t,op_undo(&r,target),Error.None)
    testing.expect(t,view_bookmark(&r.view,"ours")==nil && view_bookmark(&r.view,"theirs")!=nil,"what the other workspace did stays")
}

// A prune keeps what the workspaces' refs name and the operations of the
// last OP_RETENTION: the sweep after it reclaims the operations past it and
// the revisions only they reached, keeps what a view or a device's ref
// reaches, and undo works after the prune and refuses to cross it.
@(test)
a_prune_drops_old_operations_and_the_sweep_reclaims_what_only_they_reached :: proc(t:^testing.T) {
    f,ok:=fixture(t,"kai-prune");if !ok {return}
    defer store.close(&f.s)
    identity:=identity_make()
    r:Repo
    testing.expect_value(t,repo_create(&r,&f.s,identity,random_id(Workspace_Id)),Error.None)
    defer repo_close(&r)
    tree :: proc(s:^store.Store,text:string) -> store.Hash {
        file,_:=store.put(s,transmute([]u8)text)
        root,_:=tree_build(s,{File{path="a.txt",kind=.File,address=file,size=u64(len(text))}})
        return root
    }
    // The working copy written twice: old operations alone reach its first revision.
    first,_:=change_snapshot(&r,tree(&f.s,"first\n"))
    kept,_:=change_snapshot(&r,tree(&f.s,"kept\n"))
    testing.expect_value(t,bookmark_set(&r,"main",kept),Error.None)
    // What a change attaches is kept as its tree is, and so is what a kept view's change attaches.
    attached,ae:=store.put(&f.s,transmute([]u8)string("an agent's turn"))
    testing.expect_value(t,ae,store.Error.None)
    attached_kept,ake:=store.put(&f.s,transmute([]u8)string("a turn of the working copy"))
    testing.expect_value(t,ake,store.Error.None)
    working:=change_get(&f.s,repo_working(&r),context.temp_allocator) or_else Change{}
    working.attachments={{1,attached_kept}}
    rewrite_tx,_:=tx_begin(&r)
    testing.expect_value(t,change_sign_as(&working,&r.identity),Error.None)
    working_revision,we:=change_put(&f.s,&working,&r.identity)
    testing.expect_value(t,we,Error.None)
    testing.expect_value(t,tx_rewrite(&rewrite_tx,repo_working(&r),working_revision),Error.None)
    testing.expect_value(t,tx_commit(&rewrite_tx,.Snapshot,"attach"),Error.None)
    kept=working_revision
    published_change:=Change{id=random_id(Change_Id),tree=tree(&f.s,"published\n"),author=identity.key,created=1,written=1,attachments={{1,attached}},description="only a device names it"}
    published,_:=change_put(&f.s,&published_change,&identity)
    _,pe:=device_refs_publish(&f.s,{0=1},&identity,{{"work",published}},1)
    testing.expect_value(t,pe,Error.None)
    // Overlay records: one of a revision only old operations reach, and two of the kept working
    // copy, the second following the first.
    sealed :: proc(t:^testing.T,s:^store.Store,text:string) -> store.Hash {
        address,e:=store.put(s,transmute([]u8)text)
        testing.expect_value(t,e,store.Error.None)
        return address
    }
    seal :: proc(t:^testing.T,s:^store.Store,identity:^Identity,commit:Revision,tree:store.Hash) {
        r:=Overlay_Record{head={commit=commit,project={0=7},scope={0=7},epoch=1,tree_root=tree,time=time.now()._nsec}}
        _,e:=overlay_record_write(s,identity,&r,{},0)
        testing.expect_value(t,e,Error.None)
    }
    gone_tree,older_tree,newer_tree:=sealed(t,&f.s,"sealed tree of the first"),sealed(t,&f.s,"sealed tree, before"),sealed(t,&f.s,"sealed tree, after")
    seal(t,&f.s,&identity,first,gone_tree)
    seal(t,&f.s,&identity,kept,older_tree)
    seal(t,&f.s,&identity,kept,newer_tree)
    before:=r.op
    old:=make([dynamic]store.Hash,context.temp_allocator)
    testing.expect_value(t,op_retained(&f.s,{r.op},&old),Error.None)
    testing.expect_value(t,store.commit(&f.s),store.Error.None)

    // A day past the retention, every operation so far is old.
    later:=time.now()._nsec+OP_RETENTION+i64(24*time.Hour)
    prune :: proc(t:^testing.T,s:^store.Store,now:i64) {
        testing.expect_value(t,store_prune(s,now),Error.None)
        live:=make([dynamic]store.Hash,context.temp_allocator)
        testing.expect_value(t,store_live(s,&live),Error.None)
        _,e:=store.sweep(s,live[:],time.Time{_nsec=now},reclaim=true)
        testing.expect_value(t,e,store.Error.None)
    }
    prune(t,&f.s,later)
    testing.expect_value(t,repo_refresh(&r),Error.None)
    newest,_:=op_get(&f.s,r.op,context.temp_allocator)
    testing.expect_value(t,newest.kind,Op_Kind.Prune)
    for op in old {testing.expectf(t,object_present(&f.s,op)==(op==before),"%v: only the operation the workspace's ref names stays",op)}
    testing.expect(t,!object_present(&f.s,first),"a revision only old operations reached is reclaimed")
    testing.expect(t,object_present(&f.s,attached) && object_present(&f.s,attached_kept),"what a kept change attaches survives the sweep")
    testing.expect_value(t,overlay_record_error(&f.s,{0=7},{0=7},first),Error.Missing)
    testing.expect(t,!object_present(&f.s,gone_tree),"the overlay of a revision the prune let go goes with it")
    held,_,he:=overlay_record_get(&f.s,{0=7},{0=7},kept,context.temp_allocator)
    testing.expect(t,he==.None && held.tree_root==newer_tree && object_present(&f.s,newer_tree),"the record a kept revision's ref names stays whole")
    testing.expect(t,!object_present(&f.s,older_tree) && !object_present(&f.s,held.prev),"the records before it, which nothing reads, go")
    for revision in ([]Revision{kept,published,repo_working(&r)}) {
        files:=make([dynamic]File,context.temp_allocator)
        c,ce:=change_get(&f.s,revision,context.temp_allocator)
        testing.expect(t,ce==.None && tree_files(&f.s,c.tree,&files,context.temp_allocator)==.None,"what a view or a device's ref reaches stays whole")
    }

    // After the prune every operation undoes; the prune and what came before it do not.
    testing.expect_value(t,op_undo(&r,r.op),Error.Pruned)
    testing.expect_value(t,op_undo(&r,before),Error.Pruned)
    view:=r.view_address
    _,e:=change_describe(&r,repo_working(&r),"after the prune")
    testing.expect_value(t,e,Error.None)
    after:=r.view_address
    testing.expect_value(t,op_undo(&r,r.op),Error.None)
    testing.expect(t,r.view_address==view,"the operation after the prune undoes")
    testing.expect_value(t,op_undo(&r,r.op),Error.None)
    testing.expect(t,r.view_address==after,"and its undo too")
    // A second prune within the retention keeps what the first kept since.
    prune(t,&f.s,later+1)
    testing.expect_value(t,repo_refresh(&r),Error.None)
    testing.expect(t,object_present(&f.s,newest.view),"the operations of the last 30 days stay")
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

    // Undoing the merge itself would drop what one side did: it is refused. An undo in a
    // workspace takes back its own operation under it, and the view keeps the other's.
    testing.expect_value(t,op_undo(&b.repo,b.repo.op),Error.Merged)
    target,te:=op_undo_target(&b.repo)
    testing.expect_value(t,te,Error.None)
    undone,_:=op_get(&f.s,target,context.temp_allocator)
    testing.expect(t,undone.workspace==b.repo.workspace && undone.kind==.Bookmark,"b's own bookmark")
    testing.expect_value(t,op_undo(&b.repo,target),Error.None)
    testing.expect(t,view_bookmark(&b.repo.view,"from-b")==nil && view_bookmark(&b.repo.view,"from-a")!=nil,"only b's operation is taken back")
    testing.expect_value(t,len(b.repo.view.workspaces),2)
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

    // What a list of projects shows of the workspace, read without opening it: its working
    // change, and a bookmark on it once one points there.
    change,bookmark,on:=workspace_working_of(&f.s,root)
    one_change,_:=change_get(&f.s,one,context.temp_allocator)
    testing.expect(t,on && change==one_change.id && bookmark=="","the working change, read without opening the workspace")
    testing.expect_value(t,bookmark_set(&w.repo,"main",one),Error.None)
    _,bookmark,on=workspace_working_of(&f.s,root)
    testing.expect_value(t,bookmark,"main")
    _,_,on=workspace_working_of(&f.s,folder_of(&f,"none"))
    testing.expect(t,!on,"a folder that is no workspace shows nothing")

    // A snapshot that fails to save leaves the index in memory as it was.
    write(t,root,"a.txt","a1")
    write(t,root,"b.txt","b1")
    write(t,root,"c/d.txt","d1")
    _,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    rows:=slice.clone(w.index.rows[:],context.temp_allocator)
    write(t,root,"b.txt","b3",40*time.Minute)
    state_folder:=strings.concatenate({root,"/",STATE_FOLDER},context.temp_allocator)
    testing.expect(t,os.chmod(state_folder,{.Read_User,.Execute_User})==nil)
    _,e=workspace_snapshot(&w)
    os.chmod(state_folder,os.Permissions_Read_All+os.Permissions_Execute_All+{.Write_User})
    testing.expect(t,e!=.None,"the state does not save into a folder it may not write")
    testing.expect(t,slice.equal(rows,w.index.rows[:]),"the index is the one before the failed snapshot")
    write(t,root,"b.txt","b1")
    _,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)

    // A workspace whose sibling is this one clones a file the sibling's index row says it
    // holds without reading it (a.txt, rewritten in place with the row's size, time and
    // inode, comes as the sibling has it), and takes from the store one edited since (b.txt).
    row,_:=stat_find(&w.index,"a.txt")
    a_path:=strings.concatenate({root,"/a.txt"},context.temp_allocator)
    testing.expect(t,os.write_entire_file(a_path,transmute([]u8)string("A1"))==nil)
    settled:=time.unix(0,row.mtime_ns)
    testing.expect(t,os.change_times(a_path,settled,settled)==nil)
    write(t,root,"b.txt","bX",20*time.Minute)
    sibling_root:=folder_of(&f,"sibling")
    v:Workspace
    testing.expect_value(t,workspace_add(&v,sibling_root,&w,identity,{sibling=root}),Error.None)
    testing.expect_value(t,workspace_switch(&v,one),Error.None)
    testing.expect_value(t,read(sibling_root,"a.txt"),"A1")
    testing.expect_value(t,read(sibling_root,"b.txt"),"b1")
    testing.expect_value(t,read(sibling_root,"c/d.txt"),"d1")
    workspace_close(&v)

    // The folder opened with a store that never held its repository says so.
    workspace_close(&w)
    other,oe:=store.open(strings.concatenate({f.folder,"/other"},context.temp_allocator))
    testing.expect_value(t,oe,store.Error.None)
    defer store.close(&other)
    testing.expect_value(t,workspace_open(&w,root,&other,identity_make()),Error.Other_Store)
}

// A change splits by paths in one operation: the first half keeps its id,
// parents and description with the files picked over its parents, a conflict
// it inherits and its parents' private files; the second, on it, keeps the
// whole tree and its private files, and what pointed at the change follows it.
// What is not a file the change touched is refused with why. One undo gives the
// view before; an edit on disk after the last snapshot reaches the next one.
// Every other rewrite (describe, abandon of a parent, rebase) carries the
// change's private files onto what it writes in its one operation, those of
// a scope the device that rewrites does not read too; a restore gives it
// those of the change it restores from.
@(test)
a_change_splits_by_paths_and_undoes_in_one_operation :: proc(t:^testing.T) {
    f,ok:=fixture(t,"kai-split");if !ok {return}
    defer store.close(&f.s)
    o:Test_Org
    test_org_make(t,&o);defer test_org_destroy(&o)
    scope,vault:=random_id(Scope_Id),random_id(Scope_Id)
    scope_add(t,&o,scope,.Reader,true,20,"secrets/**")
    scope_add(t,&o,vault,.Admin,true,20,"vault/**")
    refold(t,&o)
    alice,bob:=device_of(&o.alice,0),device_of(&o.bob,0)
    kl,vl:Log
    log_init(&kl);defer log_destroy(&kl)
    log_init(&vl);defer log_destroy(&vl)
    kf,kv:Keyring_Fold
    testing.expect_value(t,keyring_create(&kf,&kl,&o.fold,&f.s,o.project.id,scope,&alice,21),Error.None)
    defer keyring_fold_destroy(&kf)
    testing.expect_value(t,keyring_create(&kv,&vl,&o.fold,&f.s,o.project.id,vault,&alice,21),Error.None)
    defer keyring_fold_destroy(&kv)
    routing:=Overlay_Routing{org=&o.fold,project=o.project.id,keyrings={&kf,&kv},device=alice}
    root,other:=folder_of(&f,"a"),folder_of(&f,"b")
    for file in ([][2]string{{"keep.txt","keep"},{"edit.txt","v1"},{"gone.txt","bye"},{"art/a.txt","a1"},{"art/b.txt","b1"},{"d","dee"},{"f.txt","1\n2\n3\n"},{"secrets/key.txt","old secret"},{"vault/plan.txt","admins only"}}) {
        write(t,root,file[0],file[1])
    }
    w,b:Workspace
    if !testing.expect_value(t,workspace_create(&w,root,&f.s,o.alice.devices[0],overlay=&routing),Error.None) {return}
    defer workspace_close(&w)
    origin:=repo_working(&w.repo)

    // A merge whose f.txt is in conflict, and on it the work to split.
    left,_:=workspace_new(&w,{origin})
    write(t,root,"f.txt","one\n2\n3\n",50*time.Minute)
    report,_:=workspace_snapshot(&w)
    left=report.revision
    _,_=workspace_new(&w,{origin})
    write(t,root,"f.txt","uno\n2\n3\n",50*time.Minute)
    report,_=workspace_snapshot(&w)
    right:=report.revision
    _,e:=workspace_new(&w,{left,right},"work")
    testing.expect_value(t,e,Error.None)
    write(t,root,"edit.txt","v2",40*time.Minute)
    write(t,root,"new.txt","new",40*time.Minute)
    write(t,root,"art/a.txt","a2",40*time.Minute)
    write(t,root,"art/c.txt","c2",40*time.Minute)
    write(t,root,"secrets/key.txt","new secret",40*time.Minute)
    os.remove(strings.concatenate({root,"/gone.txt"},context.temp_allocator))
    os.remove(strings.concatenate({root,"/d"},context.temp_allocator))
    write(t,root,"d/x.txt","x",40*time.Minute)
    report,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    split:=report.revision
    before_split,_:=change_get(&f.s,split,context.temp_allocator)
    totals,_:=tree_totals(&f.s,before_split.tree)
    testing.expect_value(t,totals.conflicts,1)

    // A bookmark and a child on it, and another workspace, of another key, on it too.
    testing.expect_value(t,bookmark_set(&w.repo,"wip",split),Error.None)
    child,_:=change_new(&w.repo,{split},"child")
    testing.expect_value(t,workspace_switch(&w,split),Error.None)
    testing.expect_value(t,workspace_add(&b,other,&w,o.bob.devices[0]),Error.None)
    defer workspace_close(&b)
    testing.expect_value(t,workspace_switch(&b,split),Error.None)

    routing_bob:=Overlay_Routing{org=&o.fold,project=o.project.id,keyrings={&kf,&kv},device=bob}
    b.repo.overlay=&routing_bob
    Refusal :: struct {paths:[]string,says:string}
    refusals:=[]Refusal{
        {nil,"no path picked"},
        {{"art/../x"},"not a path"},
        {{"missing.txt"},"did not add, change or remove"},
        {{"f.txt"},"did not add, change or remove"},          // a conflict it inherits
        {{"secrets/key.txt"},"did not add, change or remove"}, // private: never in the public tree
        {{"edit.txt","gone.txt","new.txt","art","d","d/x.txt"},"with new"},
        {{"d/x.txt"},"d and d/x.txt"},
    }
    for refusal in refusals {
        why:string
        _,_,re:=change_split(&b.repo,split,refusal.paths,nil,&why)
        testing.expectf(t,re==.Invalid_Argument && strings.contains(why,refusal.says),"%v: %v %q",refusal.paths,re,why)
    }

    // An edit on disk after the last snapshot.
    write(t,root,"edit.txt","v3, on disk",30*time.Minute)
    before:=b.repo.view_address
    why:string
    // A split cut after its objects and before its commit moved nothing: neither its operation
    // nor the records of its overlays.
    b.repo.cut_commit=true
    cut_first,cut_second,ce:=change_split(&b.repo,split,{"new.txt","gone.txt","art","d","d/x.txt"},nil,&why)
    testing.expect_value(t,ce,Error.Io)
    testing.expect(t,b.repo.view_address==before,"the view is the one before the cut split")
    testing.expect(t,cut_first!={} && overlay_record_error(&f.s,o.project.id,scope,cut_first)==.Missing && overlay_record_error(&f.s,o.project.id,scope,cut_second)==.Missing,"no overlay record of the cut split was set")
    first,second,se:=change_split(&b.repo,split,{"new.txt","gone.txt","art","d","d/x.txt"},nil,&why)
    if !testing.expectf(t,se==.None,"%v %s",se,why) {return}
    after:=b.repo.view_address
    op,_:=op_get(&f.s,b.repo.op,context.temp_allocator)
    testing.expect(t,op.kind==.Rewrite && len(op.parents)==1,"one operation")
    a,_:=change_get(&f.s,first,context.temp_allocator)
    z,_:=change_get(&f.s,second,context.temp_allocator)
    testing.expect(t,a.id==before_split.id && a.created==before_split.created && a.description=="work" && slice.equal(a.parents,before_split.parents),"the first keeps the change's id, parents and text")
    testing.expect(t,a.author==o.bob.devices[0].key && slice.contains(a.coauthors,o.alice.devices[0].key),"the author that did not sign is a coauthor")
    testing.expect(t,z.id!=a.id && z.description=="" && len(z.parents)==1 && z.parents[0]==first && z.tree==before_split.tree,"the second is the whole tree on the first")
    paths_of :: proc(s:^store.Store,from,to:store.Hash) -> string {
        diffs:=make([dynamic]Diff,context.temp_allocator)
        tree_diff(s,from,to,&diffs,context.temp_allocator)
        names:=make([dynamic]string,context.temp_allocator)
        for d in diffs {append(&names,d.path)}
        return strings.join(names[:]," ",context.temp_allocator)
    }
    base,_:=parents_tree(&b.repo,a.parents)
    testing.expect_value(t,paths_of(&f.s,base,a.tree),"art/a.txt art/c.txt d d/x.txt gone.txt new.txt")
    testing.expect_value(t,paths_of(&f.s,a.tree,z.tree),"edit.txt")
    totals,_=tree_totals(&f.s,a.tree)
    testing.expect_value(t,totals.conflicts,1)
    testing.expect(t,view_workspace(&b.repo.view,w.repo.workspace)==second && view_workspace(&b.repo.view,b.repo.workspace)==second,"both workspaces are on the second")
    mark:=view_bookmark(&b.repo.view,"wip")
    value,_:=terms_resolved(&mark.terms)
    testing.expect(t,value==second,"the bookmark follows the second")
    testing.expect(t,!slice.contains(b.repo.view.heads[:],split) && !slice.contains(b.repo.view.heads[:],first))
    moved:Revision
    for h in b.repo.view.heads {
        if c,_:=change_get(&f.s,h,context.temp_allocator);c.description=="child" {moved=h}
    }
    moved_change,_:=change_get(&f.s,moved,context.temp_allocator)
    testing.expect(t,moved!=child && len(moved_change.parents)==1 && moved_change.parents[0]==second && moved_change.tree==tree_of(t,&f.s,child),"the child moves onto the second as it was")
    opened,oe:=open_files(t,&f.s,&kf,&alice,first)
    testing.expect(t,oe==.None && opened["secrets/key.txt"]=="old secret","the first has its parents' private files")
    opened,oe=open_files(t,&f.s,&kf,&alice,second)
    testing.expect(t,oe==.None && opened["secrets/key.txt"]=="new secret","the second has the change's private files")

    testing.expect_value(t,op_undo(&b.repo,b.repo.op),Error.None)
    testing.expect(t,b.repo.view_address==before,"one undo gives the view before the split")
    // Records are kept by revision and an operation writes only those of revisions it made: the
    // view an undo gives back reads its private files as they were, and so does a redo.
    opened,oe=open_files(t,&f.s,&kf,&alice,split)
    testing.expect(t,oe==.None && opened["secrets/key.txt"]=="new secret","the change split and undone has its private files")
    testing.expect_value(t,op_undo(&b.repo,b.repo.op),Error.None)
    testing.expect(t,b.repo.view_address==after,"undoing the undo splits again")
    opened,oe=open_files(t,&f.s,&kf,&alice,second)
    testing.expect(t,oe==.None && opened["secrets/key.txt"]=="new secret","the split done again has the second's private files")

    // The working copy kept its files, and the edit on disk reaches the second.
    testing.expect_value(t,read(root,"edit.txt"),"v3, on disk")
    report,e=workspace_snapshot(&w)
    testing.expect_value(t,e,Error.None)
    now,_:=change_get(&f.s,report.revision,context.temp_allocator)
    testing.expect(t,now.id==z.id && now.parents[0]==first,"the working copy is the second")
    testing.expect_value(t,paths_of(&f.s,z.tree,now.tree),"edit.txt")
    opened,oe=open_files(t,&f.s,&kf,&alice,report.revision)
    testing.expect(t,oe==.None && opened["secrets/key.txt"]=="new secret","the next snapshot follows the second's private files")

    // Each rewrite by bob, who reads one scope and not the other, carries the change's records
    // in its operation: alice opens both scopes on what it wrote, bob only his, and one undo
    // gives the change back with its own.
    Private :: struct {secret,vault:string,bob:Error}
    private_at :: proc(t:^testing.T,s:^store.Store,kf,kv:^Keyring_Fold,alice,bob:^Overlay_Device,revision:Revision) -> (p:Private) {
        opened,_:=open_files(t,s,kf,alice,revision)
        p.secret=opened["secrets/key.txt"]
        opened,_=open_files(t,s,kv,alice,revision)
        p.vault=opened["vault/plan.txt"]
        _,p.bob=open_files(t,s,kv,bob,revision)
        if opened,_=open_files(t,s,kf,bob,revision);opened["secrets/key.txt"]!=p.secret {p.secret="bob reads another"}
        return
    }
    want:=Private{"new secret","admins only",.Unauthorized}
    testing.expect_value(t,repo_refresh(&b.repo),Error.None)
    held:=report.revision
    testing.expect_value(t,private_at(t,&f.s,&kf,&kv,&alice,&bob,held),want)
    Rewrite_Kind :: enum {Describe,Restore,Abandon_Parent,Rebase}
    for kind in Rewrite_Kind {
        before_view:=b.repo.view_address
        e:Error
        switch kind {
        case .Describe: _,e=change_describe(&b.repo,held,"described")
        case .Restore: _,e=change_restore(&b.repo,held,first)
        case .Abandon_Parent: e=change_abandon(&b.repo,first)
        case .Rebase: _,e=change_rebase(&b.repo,held,{origin})
        }
        if !testing.expectf(t,e==.None,"%v: %v",kind,e) {return}
        rewritten:Revision
        o,_:=op_get(&f.s,b.repo.op,context.temp_allocator)
        for rw in o.rewrites {
            if rw.from==held {rewritten=rw.to}
        }
        if !testing.expectf(t,rewritten!={},"%v rewrites the change",kind) {return}
        before_want:=want
        if kind==.Restore {want.secret="old secret"}
        testing.expectf(t,private_at(t,&f.s,&kf,&kv,&alice,&bob,rewritten)==want,"%v carries the private files: %v",kind,private_at(t,&f.s,&kf,&kv,&alice,&bob,rewritten))
        after_view:=b.repo.view_address
        testing.expect_value(t,op_undo(&b.repo,b.repo.op),Error.None)
        testing.expectf(t,b.repo.view_address==before_view && private_at(t,&f.s,&kf,&kv,&alice,&bob,held)==before_want,"undoing %v gives the change back with its private files",kind)
        testing.expect_value(t,op_undo(&b.repo,b.repo.op),Error.None)
        testing.expectf(t,b.repo.view_address==after_view && private_at(t,&f.s,&kf,&kv,&alice,&bob,rewritten)==want,"doing %v again keeps them",kind)
        held=rewritten
    }
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
