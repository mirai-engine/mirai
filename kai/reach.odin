package kai

import "core:slice"
import "mirai:store"

// What a ref of a Kai namespace reaches, said once. The store's sweep follows
// refs and the chunks of objects, never an address a Kai record holds, so
// every link inside a record is named here, by the kind of object it names:
// the sweep keeps all of it (store_live) and a pull fetches what is missing of
// it (closure_walk). A new kind of object that names another object adds its
// case to walk_children, and nothing else.

// What an object of a walk is, and so what it names.
@(private)
Walk_Kind :: enum u8 {
    Change,Folder,Conflict,File, // a project's history: a file is bytes with no Kai kind
    Output,                      // a DDC_Output: the objects of one derived data result
    Org,Repo_Refs,DDC_Set,       // what the refs of an org, a repository and derived data name
}

@(private)
Walk_Item :: struct {address:store.Hash,kind:Walk_Kind}

@(private)
Walk :: struct {
    s:^store.Store,
    whole:bool,   // an object is here only when every chunk of it is, not its root alone
    scratch:[]u8, // of whole
    tree:[dynamic]Tree_Entry,
    terms:Terms(Term),
}

@(private)
walk_make :: proc(s:^store.Store,whole:bool) -> Walk {
    w:=Walk{s=s,whole=whole,tree=make([dynamic]Tree_Entry,context.temp_allocator),terms=terms_make(Term,context.temp_allocator)}
    if whole {w.scratch=scratch_make()}
    return w
}

// The item a ref names, by the kind of its object, for the sweep: whatever
// namespace holds it. An operation is not one: op_retained walks them.
@(private)
ref_item :: proc(s:^store.Store,address:store.Hash) -> Walk_Item {
    #partial switch object_kind(s,address) {
    case .Change: return {address,.Change}
    case .Org: return {address,.Org}
    case .Repo_Refs: return {address,.Repo_Refs}
    case .DDC_Set: return {address,.DDC_Set}
    }
    return {address,.File}
}

// Pushes the objects item names onto stack.
@(private)
walk_children :: proc(w:^Walk,item:Walk_Item,stack:^[dynamic]Walk_Item) {
    s:=w.s
    switch item.kind {
    case .Change:
        c,e:=change_get(s,item.address,context.temp_allocator)
        if e!=.None {return}
        for p in c.parents {append(stack,Walk_Item{p,.Change})}
        append(stack,Walk_Item{c.tree,.Folder})
        for a in c.attachments {append(stack,Walk_Item{a.object,.File})}
    case .Folder:
        clear(&w.tree)
        if _,e:=folder_get(s,item.address,&w.tree,nil,context.temp_allocator);e!=.None {return}
        for entry in w.tree {
            kind:Walk_Kind
            switch entry.kind {
            case .File,.Executable: kind=.File
            case .Folder: kind=.Folder
            case .Conflict: kind=.Conflict
            }
            append(stack,Walk_Item{entry.address,kind})
        }
    case .Conflict:
        clear(&w.terms.adds)
        clear(&w.terms.removes)
        if conflict_get(s,item.address,&w.terms)!=.None {return}
        for list in ([2][]Term{w.terms.adds[:],w.terms.removes[:]}) {
            for t in list {append(stack,Walk_Item{t.address,t.kind==.Folder?.Folder:.File})}
        }
    case .Output:
        objects,e:=ddc_output_get(s,item.address,context.temp_allocator)
        if e!=.None {return}
        for o in objects {append(stack,Walk_Item{o,.File})}
    case .Org:
        o,e:=org_get(s,item.address,context.temp_allocator)
        if e==.None && o.prev!={} {append(stack,Walk_Item{o.prev,.Org})}
    case .Repo_Refs:
        r,e:=repo_refs_get(s,item.address,context.temp_allocator)
        if e!=.None {return}
        for b in r.bookmarks {append(stack,Walk_Item{b.target,.Change})}
    case .DDC_Set:
        records:=make([dynamic][]u8,context.temp_allocator)
        if ddc_set_read(s,item.address,&records)!=.None {return}
        for bytes in records {
            if d,de:=ddc_record_decode(bytes);de==.None {append(stack,Walk_Item{d.output_root,.Output})}
        }
    case .File:
    }
}

// The objects roots reach: present gets those in the store (whole, when the
// walk asks it), missing those that are not (what lies under them is not
// walked).
@(private)
walk_all :: proc(w:^Walk,roots:[]Walk_Item,present,missing:^[dynamic]Walk_Item) {
    stack:=make([dynamic]Walk_Item,context.temp_allocator)
    seen:=make(map[store.Hash]bool,context.temp_allocator)
    append(&stack,..roots)
    empty:=empty_address()
    for len(stack)>0 {
        item:=pop(&stack)
        if item.address=={} || seen[item.address] {continue}
        seen[item.address]=true
        if !(w.whole?object_whole(w.s,item.address,w.scratch):object_present(w.s,item.address)) {
            if item.address!=empty {append(missing,item)}
            continue
        }
        append(present,item)
        walk_children(w,item,&stack)
    }
}

// The Kai objects reachable from revisions: changes, their parents, their
// trees, folders, conflicts and files, and the objects they attach. present
// gets those whole in the store, missing those that are not (what lies under
// them is not walked): an object whose root arrived and part of whose chunks
// are still coming is missing, so a pull cut midway never reads as complete.
closure_walk :: proc(s:^store.Store,revisions:[]Revision,present,missing:^[dynamic]store.Hash) {
    roots:=make([dynamic]Walk_Item,0,len(revisions),context.temp_allocator)
    for r in revisions {append(&roots,Walk_Item{r,.Change})}
    walk_missing(s,roots[:],present,missing)
}

// What closure_walk does from the objects an org's ref, a repository's refs or
// a derived data set names.
@(private)
walk_missing :: proc(s:^store.Store,roots:[]Walk_Item,present,missing:^[dynamic]store.Hash) {
    w:=walk_make(s,true)
    here:=make([dynamic]Walk_Item,context.temp_allocator)
    lacking:=make([dynamic]Walk_Item,context.temp_allocator)
    walk_all(&w,roots,&here,&lacking)
    if present!=nil {for x in here {append(present,x.address)}}
    for x in lacking {append(missing,x.address)}
}

// Whether the sorted closure holds address.
closure_has :: proc(sorted:[]store.Hash,address:store.Hash) -> bool {
    _,found:=slice.binary_search_by(sorted,address,proc(item:store.Hash,a:store.Hash) -> slice.Ordering {
        if item==a {return .Equal}
        return hash_less(item,a)?.Less:.Greater
    })
    return found
}

@(private)
object_present :: proc(s:^store.Store,address:store.Hash) -> bool {
    o,e:=store.object_open(s,address)
    if e!=.None {return false}
    store.object_close(&o)
    return true
}

// Whether every chunk of the object at address is in the store. Its nodes are
// read into scratch (store.CHUNK_MAX bytes, scratch_make), which a walk
// allocates once.
object_whole :: proc(s:^store.Store,address:store.Hash,scratch:[]u8) -> bool {
    return len(scratch)>=store.CHUNK_MAX && node_whole(s,address,scratch,0)
}

scratch_make :: proc() -> []u8 {
    buffer,_:=make([]u8,store.CHUNK_MAX,context.temp_allocator)
    return buffer
}

@(private)
node_whole :: proc(s:^store.Store,address:store.Hash,buffer:[]u8,depth:int) -> bool {
    if depth>store.NODE_LEVEL_MAX {return false}
    bytes,e:=store.chunk_read(s,address,buffer)
    if e!=.None {return false}
    n,parse_error:=store.node_parse(bytes)
    if parse_error!=.None {return false}
    entries,clone_error:=slice.clone(n.entries,context.temp_allocator)
    if clone_error!=nil {return false}
    level:=n.level
    for entry in entries {
        if level>0 {
            if !node_whole(s,entry.address,buffer,depth+1) {return false}
        } else if !store.chunk_here(s,entry.address) {
            return false
        }
    }
    return true
}
