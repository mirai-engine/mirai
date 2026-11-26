package kai

import "mirai:store"

// A conflict is a value, never a state that blocks work: the terms of a merge
// that did not resolve, alternating side0, base0, side1, base1, ..., side_n,
// as Jujutsu keeps them. A base that equals a side cancels with it, so the
// stored terms are always simplified, and a conflict that comes down to one
// side is that side, never stored. A conflict inside the terms of a merge is
// flattened into them, so rebasing composes conflicts without losing one. An
// absent term (a file one side does not have) is all zero.

Term :: struct #packed {
    address:store.Hash,
    size:u64,
    kind:Entry_Kind, // File, Executable or Folder
    reserved:[7]u8,
}

Conflict_Head :: struct #packed {
    magic:u32,
    sides:u8,
    reserved:u8,
}

// A merge of values: adds are the sides, removes the bases between them;
// len(adds)==len(removes)+1.
Terms :: struct($T:typeid) {
    adds:[dynamic]T,
    removes:[dynamic]T,
}

terms_make :: proc($T:typeid,allocator:=context.allocator) -> Terms(T) {
    return {adds=make([dynamic]T,allocator),removes=make([dynamic]T,allocator)}
}

terms_destroy :: proc(t:^Terms($T)) {
    delete(t.adds)
    delete(t.removes)
}

// Cancels each base that equals a side.
terms_simplify :: proc(t:^Terms($T)) {
    for j:=0;j<len(t.removes); {
        found:=-1
        for a,i in t.adds {
            if a==t.removes[j] {found=i;break}
        }
        if found<0 {j+=1;continue}
        ordered_remove(&t.adds,found)
        ordered_remove(&t.removes,j)
    }
}

// The one value the terms come down to: one side, or sides that all made
// the same change.
terms_resolved :: proc(t:^Terms($T)) -> (value:T,resolved:bool) {
    if len(t.adds)==0 {return}
    for a in t.adds[1:] {
        if a!=t.adds[0] {return}
    }
    return t.adds[0],true
}

conflict_encode :: proc(adds,removes:[]Term,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(adds)<2 || len(adds)>CONFLICT_SIDES_MAX || len(removes)!=len(adds)-1 {return nil,.Invalid_Argument}
    w:=writer_make(allocator)
    write_value(&w,Conflict_Head{magic=KAI_MAGIC,sides=u8(len(adds))})
    for a,i in adds {
        write_value(&w,a)
        if i<len(removes) {write_value(&w,removes[i])}
    }
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The terms of the bytes of a conflict, checked: its sides, every term, and
// that it is simplified, so the same conflict always has one address.
conflict_decode :: proc(bytes:[]u8,t:^Terms(Term)) -> Error {
    clear(&t.adds)
    clear(&t.removes)
    r:=Reader{data=bytes}
    head:=read_value(&r,Conflict_Head)
    if r.short || head.magic!=KAI_MAGIC || head.reserved!=0 {return .Corrupt}
    if head.sides<2 || head.sides>CONFLICT_SIDES_MAX {return .Corrupt}
    count:=2*int(head.sides)-1
    if len(bytes)-r.at!=count*size_of(Term) {return .Corrupt}
    empty:=empty_address()
    for k in 0..<count {
        term:=read_value(&r,Term)
        if !term_valid(term,empty) {return .Corrupt}
        _,e:=append(k%2==0?&t.adds:&t.removes,term)
        if e!=nil {return .Out_Of_Memory}
    }
    before:=len(t.adds)
    terms_simplify(t)
    if len(t.adds)!=before {return .Corrupt}
    if _,resolved:=terms_resolved(t);resolved {return .Corrupt}
    return .None
}

@(private)
term_valid :: proc "contextless" (term:Term,empty:store.Hash) -> bool {
    if term.reserved!={} {return false}
    if term.address=={} {return term.size==0 && term.kind==.File}
    switch term.kind {
    case .File,.Executable: return term.size>0 || term.address==empty
    case .Folder: return true
    case .Conflict: return false
    }
    return false
}

conflict_put :: proc(s:^store.Store,t:^Terms(Term)) -> (entry:Tree_Entry,error:Error) {
    bytes:=conflict_encode(t.adds[:],t.removes[:],context.temp_allocator) or_return
    entry.kind,entry.files,entry.conflicts=.Conflict,1,1
    entry.address=object_put(s,.Conflict,bytes) or_return
    return
}

conflict_get :: proc(s:^store.Store,address:store.Hash,t:^Terms(Term)) -> Error {
    bytes:=object_get(s,address,.Conflict,context.temp_allocator) or_return
    return conflict_decode(bytes,t)
}

@(private)
term_of :: proc "contextless" (e:Tree_Entry) -> Term {
    return {address=e.address,size=e.kind==.Folder?0:e.size,kind=e.kind}
}

// What merges trees: the store, the drivers asked for files, in order before
// the built-in ones, and the bytes above which no driver reads a file.
Merger :: struct {
    s:^store.Store,
    drivers:[]Driver,
    bytes_max:int, // 0: DRIVER_BYTES_MAX
}

DRIVER_BYTES_MAX :: 64<<20

// Merges the trees adds and removes alternate: the root of the result, whose
// totals say how many conflicts it holds. A zero address is an empty tree.
tree_merge :: proc(m:^Merger,adds,removes:[]store.Hash) -> (root:store.Hash,error:Error) {
    if len(adds)!=len(removes)+1 || len(adds)>CONFLICT_SIDES_MAX {return {},.Invalid_Argument}
    t:=terms_make(Term,context.temp_allocator)
    for a in adds {append(&t.adds,Term{address=a,kind=a=={}?.File:.Folder})}
    for r in removes {append(&t.removes,Term{address=r,kind=r=={}?.File:.Folder})}
    entry,present:=merge_terms(m,&t,"",0) or_return
    if !present {return tree_empty(m.s)}
    if entry.kind!=.Folder {return {},.Corrupt}
    return entry.address,.None
}

// The tree of base, ours and theirs merged.
tree_merge3 :: proc(m:^Merger,base,ours,theirs:store.Hash) -> (root:store.Hash,error:Error) {
    return tree_merge(m,{ours,theirs},{base})
}

// The tree of a change rebased from its parent's tree onto another: onto
// plus what the change did to from.
tree_rebase :: proc(m:^Merger,tree,from,onto:store.Hash) -> (root:store.Hash,error:Error) {
    if from==onto {return tree,.None}
    return tree_merge(m,{onto,tree},{from})
}

// Merges the terms of one path: its entry, without a name, and whether there
// is one.
@(private)
merge_terms :: proc(m:^Merger,t:^Terms(Term),path:string,depth:int) -> (entry:Tree_Entry,present:bool,error:Error) {
    if depth>DEPTH_MAX {return {},false,.Too_Large}
    flatten(m.s,t) or_return
    terms_simplify(t)
    if value,resolved:=terms_resolved(t);resolved {return term_entry(m.s,value)}
    if len(t.adds)>CONFLICT_SIDES_MAX {return {},false,.Too_Large}
    folders,files:=0,0
    for list in ([2][]Term{t.adds[:],t.removes[:]}) {
        for term in list {
            if term.address=={} {continue}
            if term.kind==.Folder {folders+=1} else {files+=1}
        }
    }
    if folders>0 && files==0 {return merge_folders(m,t,path,depth)}
    if folders==0 && len(t.adds)==2 && t.adds[0].address!={} && t.adds[1].address!={} {
        // Two sides of a file, the base absent when both added it: a driver may merge them.
        merged:=make([dynamic]u8,context.temp_allocator)
        result,kind:=merge_file(m,t,path,&merged)
        if result==.Resolved {
            address,e:=store.put(m.s,merged[:])
            if e!=.None {return {},false,store_error(e)}
            return {kind=kind,address=address,size=u64(len(merged)),files=1},true,.None
        }
    }
    entry=conflict_put(m.s,t) or_return
    return entry,true,.None
}

// Replaces each term that is a conflict by its own terms, in place: a side's
// sides are sides, a base's sides are bases.
@(private)
flatten :: proc(s:^store.Store,t:^Terms(Term)) -> Error {
    has:=false
    for list in ([2][]Term{t.adds[:],t.removes[:]}) {
        for term in list {if term.kind==.Conflict {has=true}}
    }
    if !has {return .None}
    out:=terms_make(Term,context.temp_allocator)
    inner:=terms_make(Term,context.temp_allocator)
    for a,i in t.adds {
        if a.kind==.Conflict {
            conflict_get(s,a.address,&inner) or_return
            append(&out.adds,..inner.adds[:])
            append(&out.removes,..inner.removes[:])
        } else {
            append(&out.adds,a)
        }
        if i>=len(t.removes) {continue}
        r:=t.removes[i]
        if r.kind==.Conflict {
            conflict_get(s,r.address,&inner) or_return
            append(&out.removes,..inner.adds[:])
            append(&out.adds,..inner.removes[:])
        } else {
            append(&out.removes,r)
        }
    }
    if len(out.adds)!=len(out.removes)+1 || len(out.adds)>4*CONFLICT_SIDES_MAX {return .Too_Large}
    clear(&t.adds)
    clear(&t.removes)
    append(&t.adds,..out.adds[:])
    append(&t.removes,..out.removes[:])
    return .None
}

// The entry of one term: a folder's totals are read from its meta.
@(private)
term_entry :: proc(s:^store.Store,term:Term) -> (entry:Tree_Entry,present:bool,error:Error) {
    if term.address=={} {return {},false,.None}
    entry={kind=term.kind,address=term.address,size=term.size,files=1}
    if term.kind==.Folder {
        totals:=tree_totals(s,term.address) or_return
        if totals.files==0 {return {},false,.None}
        entry.files,entry.conflicts,entry.size=totals.files,totals.conflicts,totals.size
    }
    return entry,true,.None
}

// Merges folders name by name; an absent folder is an empty one, and a folder
// left empty is absent.
@(private)
merge_folders :: proc(m:^Merger,t:^Terms(Term),path:string,depth:int) -> (entry:Tree_Entry,present:bool,error:Error) {
    sides:=len(t.adds)+len(t.removes)
    lists:=make([][dynamic]Tree_Entry,sides,context.temp_allocator)
    for k in 0..<sides {
        term:=k%2==0 ? t.adds[k/2] : t.removes[k/2]
        lists[k]=make([dynamic]Tree_Entry,context.temp_allocator)
        if term.address!={} {folder_get(m.s,term.address,&lists[k],nil,context.temp_allocator) or_return}
    }
    at:=make([]int,sides,context.temp_allocator)
    items:=make([dynamic]Tree_Entry,context.temp_allocator)
    child:=terms_make(Term,context.temp_allocator)
    for {
        // The smallest name not yet merged.
        name:string
        found:=false
        for k in 0..<sides {
            if at[k]<len(lists[k]) && (!found || lists[k][at[k]].name<name) {name,found=lists[k][at[k]].name,true}
        }
        if !found {break}
        clear(&child.adds)
        clear(&child.removes)
        for k in 0..<sides {
            term:Term
            if at[k]<len(lists[k]) && lists[k][at[k]].name==name {
                term=term_of(lists[k][at[k]])
                at[k]+=1
            }
            append(k%2==0?&child.adds:&child.removes,term)
        }
        child_path:=path_join(path,name)
        e,here:=merge_terms(m,&child,child_path,depth+1) or_return
        if !here {continue}
        e.name=name
        append(&items,e)
    }
    if len(items)==0 {return {},false,.None}
    entry=folder_put(m.s,items[:]) or_return
    return entry,true,.None
}

// Asks the drivers to merge a file of two sides and one base: the result and
// its kind.
@(private)
merge_file :: proc(m:^Merger,t:^Terms(Term),path:string,out:^[dynamic]u8) -> (result:Driver_Result,kind:Entry_Kind) {
    base,ours,theirs:=t.removes[0],t.adds[0],t.adds[1]
    if ours.address=={} || theirs.address=={} {return .Unsupported,.File}
    // The executable bit merges as a value of its own.
    kind=ours.kind
    if ours.kind!=theirs.kind {
        if base.address!={} && base.kind==ours.kind {kind=theirs.kind} else if base.address=={} || base.kind!=theirs.kind {return .Conflicted,.File}
    }
    limit:=m.bytes_max>0 ? m.bytes_max : DRIVER_BYTES_MAX
    if ours.size>u64(limit) || theirs.size>u64(limit) || base.size>u64(limit) {return .Unsupported,kind}
    input:=Driver_Input{path=path,has_base=base.address!={}}
    e:Error
    if input.has_base {
        if input.base,e=file_bytes(m.s,base.address,context.temp_allocator);e!=.None {return .Error,kind}
    }
    if input.ours,e=file_bytes(m.s,ours.address,context.temp_allocator);e!=.None {return .Error,kind}
    if input.theirs,e=file_bytes(m.s,theirs.address,context.temp_allocator);e!=.None {return .Error,kind}
    result=drivers_merge(m.drivers,&input,out)
    return
}

// The bytes of the file object at address, whole; Too_Large past limit bytes, read from the
// object itself before anything is allocated.
file_bytes :: proc(s:^store.Store,address:store.Hash,allocator:=context.allocator,limit:=i64(max(int)/2)) -> (bytes:[]u8,error:Error) {
    o,open:=store.object_open(s,address)
    if open!=.None {return nil,store_error(open)}
    defer store.object_close(&o)
    size:=store.object_size(&o)
    if size>u64(limit) {return nil,.Too_Large}
    made,made_error:=make([]u8,int(size),allocator)
    if made_error!=nil {return nil,.Out_Of_Memory}
    if e:=store.object_read(&o,0,made);e!=.None {
        delete(made,allocator)
        return nil,store_error(e)
    }
    return made,.None
}

// What a checkout writes at the path of a conflict: the partial result of the
// driver that judged it for two sides of files (text with markers, a document
// with its conflicts as ours had them), else the first side present that is a
// file. Nothing when no side is a file.
conflict_materialize :: proc(m:^Merger,address:store.Hash,path:string,out:^[dynamic]u8) -> (kind:Entry_Kind,written:bool,error:Error) {
    t:=terms_make(Term,context.temp_allocator)
    conflict_get(m.s,address,&t) or_return
    clear(out)
    if len(t.adds)==2 {
        all_files:=true
        for list in ([2][]Term{t.adds[:],t.removes[:]}) {
            for term in list {if term.address!={} && term.kind==.Folder {all_files=false}}
        }
        if all_files && t.adds[0].address!={} && t.adds[1].address!={} {
            result,k:=merge_file(m,&t,path,out)
            if result==.Resolved || result==.Conflicted {return k,true,.None}
            clear(out)
        }
    }
    for a in t.adds {
        if a.address=={} || a.kind==.Folder {continue}
        bytes:=file_bytes(m.s,a.address,context.temp_allocator) or_return
        if _,e:=append(out,..bytes);e!=nil {return .File,false,.Out_Of_Memory}
        return a.kind,true,.None
    }
    return .File,false,.None
}
