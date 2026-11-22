package kai

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "mirai:store"

// A view: what a repository shows after an operation. Its heads are the
// visible changes no other visible change descends from, sorted; each
// workspace has its working-copy change; a bookmark names a change, or the
// terms of a conflict when two operations moved it apart.

View_Workspace :: struct {
    id:Workspace_Id,
    revision:Revision,
}

Bookmark :: struct {
    name:string,
    terms:Terms(Revision), // one add when it is not conflicted
}

View :: struct {
    heads:[dynamic]Revision,
    workspaces:[dynamic]View_Workspace,
    bookmarks:[dynamic]Bookmark,
}

View_Head :: struct #packed {
    magic:u32,
    version:u16,
    reserved:u16,
    heads:u32,
    workspaces:u32,
    bookmarks:u32,
    terms:u32,
    pool:u32,
} // + [heads]Revision, [workspaces]View_Workspace, [bookmarks]Bookmark_Record, [terms]Revision, pool

Bookmark_Record :: struct #packed {
    name_at:u32,
    name_len:u16,
    sides:u8,
    reserved:u8,
}

view_init :: proc(v:^View,allocator:=context.allocator) {
    v.heads=make([dynamic]Revision,allocator)
    v.workspaces=make([dynamic]View_Workspace,allocator)
    v.bookmarks=make([dynamic]Bookmark,allocator)
}

view_destroy :: proc(v:^View) {
    for &b in v.bookmarks {
        delete(b.name,v.bookmarks.allocator)
        terms_destroy(&b.terms)
    }
    delete(v.heads)
    delete(v.workspaces)
    delete(v.bookmarks)
    v^={}
}

view_clone :: proc(from:^View,allocator:=context.allocator) -> (v:View,error:Error) {
    view_init(&v,allocator)
    defer if error!=.None {view_destroy(&v)}
    if _,e:=append(&v.heads,..from.heads[:]);e!=nil {return v,.Out_Of_Memory}
    if _,e:=append(&v.workspaces,..from.workspaces[:]);e!=nil {return v,.Out_Of_Memory}
    for b in from.bookmarks {
        bookmark_add(&v,b.name,b.terms.adds[:],b.terms.removes[:]) or_return
    }
    return v,.None
}

@(private)
bookmark_add :: proc(v:^View,name:string,adds,removes:[]Revision) -> Error {
    allocator:=v.bookmarks.allocator
    b:Bookmark
    e:runtime.Allocator_Error
    if b.name,e=strings.clone(name,allocator);e!=nil {return .Out_Of_Memory}
    b.terms=terms_make(Revision,allocator)
    _,e1:=append(&b.terms.adds,..adds)
    _,e2:=append(&b.terms.removes,..removes)
    _,e3:=append(&v.bookmarks,b)
    if e1!=nil || e2!=nil || e3!=nil {
        delete(b.name,allocator)
        terms_destroy(&b.terms)
        return .Out_Of_Memory
    }
    return .None
}

// The bookmark of name, or nil.
view_bookmark :: proc(v:^View,name:string) -> ^Bookmark {
    for &b in v.bookmarks {if b.name==name {return &b}}
    return nil
}

// The working-copy change of a workspace, zero when the view has none.
view_workspace :: proc(v:^View,id:Workspace_Id) -> Revision {
    for w in v.workspaces {if w.id==id {return w.revision}}
    return {}
}

@(private)
view_sort :: proc(v:^View) {
    slice.sort_by(v.heads[:],hash_less)
    slice.sort_by(v.workspaces[:],proc(a,b:View_Workspace) -> bool {return id_less(a.id,b.id)})
    slice.sort_by(v.bookmarks[:],proc(a,b:Bookmark) -> bool {return a.name<b.name})
}

view_encode :: proc(v:^View,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    view_sort(v)
    if len(v.heads)>HEADS_MAX || len(v.workspaces)>WORKSPACES_MAX || len(v.bookmarks)>BOOKMARKS_MAX {return nil,.Too_Large}
    terms,pool:=0,0
    for b in v.bookmarks {
        if len(b.terms.adds)==0 || len(b.terms.adds)>CONFLICT_SIDES_MAX || len(b.terms.removes)!=len(b.terms.adds)-1 {return nil,.Invalid_Argument}
        terms+=2*len(b.terms.adds)-1
        pool+=len(b.name)
    }
    w:=writer_make(allocator)
    write_value(&w,View_Head{magic=KAI_MAGIC,version=VERSION,heads=u32(len(v.heads)),workspaces=u32(len(v.workspaces)),
        bookmarks=u32(len(v.bookmarks)),terms=u32(terms),pool=u32(pool)})
    for h in v.heads {write_value(&w,h)}
    for ws in v.workspaces {write_value(&w,ws)}
    at:=0
    for b in v.bookmarks {
        write_value(&w,Bookmark_Record{name_at=u32(at),name_len=u16(len(b.name)),sides=u8(len(b.terms.adds))})
        at+=len(b.name)
    }
    for b in v.bookmarks {
        for a,i in b.terms.adds {
            write_value(&w,a)
            if i<len(b.terms.removes) {write_value(&w,b.terms.removes[i])}
        }
    }
    for b in v.bookmarks {write_string(&w,b.name)}
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The view of bytes into v (initialized), checked: sorted unique heads,
// workspaces and names, simplified bookmark terms.
view_decode :: proc(bytes:[]u8,v:^View) -> Error {
    r:=Reader{data=bytes}
    head:=read_value(&r,View_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSION || head.reserved!=0 {return .Corrupt}
    if head.heads>HEADS_MAX || head.workspaces>WORKSPACES_MAX || head.bookmarks>BOOKMARKS_MAX || head.terms>BOOKMARKS_MAX*CONFLICT_TERMS_MAX {return .Corrupt}
    size:=u64(size_of(View_Head))+u64(head.heads)*size_of(Revision)+u64(head.workspaces)*size_of(View_Workspace)+
        u64(head.bookmarks)*size_of(Bookmark_Record)+u64(head.terms)*size_of(Revision)+u64(head.pool)
    if size!=u64(len(bytes)) {return .Corrupt}
    for k in 0..<int(head.heads) {
        h:=read_value(&r,Revision)
        if h=={} || (k>0 && !hash_less(v.heads[k-1],h)) {return .Corrupt}
        if _,e:=append(&v.heads,h);e!=nil {return .Out_Of_Memory}
    }
    for k in 0..<int(head.workspaces) {
        ws:=read_value(&r,View_Workspace)
        if ws.revision=={} || (k>0 && !id_less(v.workspaces[k-1].id,ws.id)) {return .Corrupt}
        if _,e:=append(&v.workspaces,ws);e!=nil {return .Out_Of_Memory}
    }
    records:=read_bytes(&r,int(head.bookmarks)*size_of(Bookmark_Record))
    terms_at:=r.at
    pool:=bytes[len(bytes)-int(head.pool):]
    used:=0
    previous:string
    t:=terms_make(Revision,context.temp_allocator)
    for k in 0..<int(head.bookmarks) {
        rec:=(^Bookmark_Record)(&records[k*size_of(Bookmark_Record)])^
        if rec.reserved!=0 || rec.sides==0 || rec.sides>CONFLICT_SIDES_MAX {return .Corrupt}
        if u64(rec.name_at)+u64(rec.name_len)>u64(len(pool)) {return .Corrupt}
        name:=string(pool[rec.name_at:][:rec.name_len])
        if !bookmark_name_valid(name) || (k>0 && name<=previous) {return .Corrupt}
        previous=name
        count:=2*int(rec.sides)-1
        used+=count
        if used>int(head.terms) {return .Corrupt}
        clear(&t.adds)
        clear(&t.removes)
        for i in 0..<count {
            term:=(^Revision)(&bytes[terms_at+(used-count+i)*size_of(Revision)])^
            if _,e:=append(i%2==0?&t.adds:&t.removes,term);e!=nil {return .Out_Of_Memory}
        }
        if rec.sides==1 {
            if t.adds[0]=={} {return .Corrupt}
        } else {
            before:=len(t.adds)
            terms_simplify(&t)
            if len(t.adds)!=before {return .Corrupt}
            if _,resolved:=terms_resolved(&t);resolved {return .Corrupt}
        }
        bookmark_add(v,name,t.adds[:],t.removes[:]) or_return
    }
    if used!=int(head.terms) {return .Corrupt}
    return .None
}

// A bookmark name: UTF-8 without control characters or spaces, 1 to
// BOOKMARK_NAME_MAX bytes.
bookmark_name_valid :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>BOOKMARK_NAME_MAX || !utf8.valid_string(name) {return false}
    for c in transmute([]u8)name {
        if c<=0x20 || c==0x7f {return false}
    }
    return true
}

view_put :: proc(s:^store.Store,v:^View) -> (address:store.Hash,error:Error) {
    bytes:=view_encode(v,context.temp_allocator) or_return
    return object_put(s,.View,bytes)
}

view_get :: proc(s:^store.Store,address:store.Hash,v:^View) -> Error {
    bytes:=object_get(s,address,.View,context.temp_allocator) or_return
    return view_decode(bytes,v)
}

// What ours and theirs did to base, both kept: a head, a workspace or a
// bookmark one side left as base had it takes the other's. A workspace both
// moved apart keeps ours; a bookmark both moved apart becomes a conflict of
// its terms.
view_merge :: proc(base,ours,theirs:^View,out:^View) -> Error {
    clear(&out.heads)
    clear(&out.workspaces)
    for &b in out.bookmarks {
        delete(b.name,out.bookmarks.allocator)
        terms_destroy(&b.terms)
    }
    clear(&out.bookmarks)
    {
        all:=make([dynamic]Revision,context.temp_allocator)
        if _,e:=append(&all,..base.heads[:]);e!=nil {return .Out_Of_Memory}
        if _,e:=append(&all,..ours.heads[:]);e!=nil {return .Out_Of_Memory}
        if _,e:=append(&all,..theirs.heads[:]);e!=nil {return .Out_Of_Memory}
        slice.sort_by(all[:],hash_less)
        for h,k in all {
            if k>0 && all[k-1]==h {continue}
            b,o,t:=contains(base.heads[:],h),contains(ours.heads[:],h),contains(theirs.heads[:],h)
            if merge3_value(b,o,t) {
                if _,e:=append(&out.heads,h);e!=nil {return .Out_Of_Memory}
            }
        }
    }
    {
        ids:=make([dynamic]Workspace_Id,context.temp_allocator)
        for list in ([3][]View_Workspace{base.workspaces[:],ours.workspaces[:],theirs.workspaces[:]}) {
            for ws in list {
                if !slice.contains(ids[:],ws.id) {
                    if _,e:=append(&ids,ws.id);e!=nil {return .Out_Of_Memory}
                }
            }
        }
        for id in ids {
            value:=merge3_value(view_workspace(base,id),view_workspace(ours,id),view_workspace(theirs,id))
            if value=={} {continue}
            if _,e:=append(&out.workspaces,View_Workspace{id,value});e!=nil {return .Out_Of_Memory}
        }
    }
    names:=make([dynamic]string,context.temp_allocator)
    for list in ([3][]Bookmark{base.bookmarks[:],ours.bookmarks[:],theirs.bookmarks[:]}) {
        for b in list {
            if !slice.contains(names[:],b.name) {
                if _,e:=append(&names,b.name);e!=nil {return .Out_Of_Memory}
            }
        }
    }
    t:=terms_make(Revision,context.temp_allocator)
    for name in names {
        clear(&t.adds)
        clear(&t.removes)
        absent:=[1]Revision{}
        b,o,th:=view_bookmark(base,name),view_bookmark(ours,name),view_bookmark(theirs,name)
        o_adds,o_removes:=o!=nil ? o.terms.adds[:] : absent[:],o!=nil ? o.terms.removes[:] : nil
        b_adds,b_removes:=b!=nil ? b.terms.adds[:] : absent[:],b!=nil ? b.terms.removes[:] : nil
        t_adds,t_removes:=th!=nil ? th.terms.adds[:] : absent[:],th!=nil ? th.terms.removes[:] : nil
        // ours + theirs - base
        _,e1:=append(&t.adds,..o_adds)
        _,e2:=append(&t.adds,..b_removes)
        _,e3:=append(&t.adds,..t_adds)
        _,e4:=append(&t.removes,..o_removes)
        _,e5:=append(&t.removes,..b_adds)
        _,e6:=append(&t.removes,..t_removes)
        if e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil || e6!=nil {return .Out_Of_Memory}
        terms_simplify(&t)
        if value,resolved:=terms_resolved(&t);resolved {
            if value=={} {continue}
            single:=[1]Revision{value}
            bookmark_add(out,name,single[:],nil) or_return
            continue
        }
        if len(t.adds)>CONFLICT_SIDES_MAX {return .Too_Large}
        bookmark_add(out,name,t.adds[:],t.removes[:]) or_return
    }
    view_sort(out)
    return .None
}

@(private)
merge3_value :: proc "contextless" (base,ours,theirs:$T) -> T {
    return ours==base ? theirs : ours
}

@(private)
contains :: proc "contextless" (list:[]Revision,value:Revision) -> bool {
    for h in list {if h==value {return true}}
    return false
}
