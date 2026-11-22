package kai

import "core:slice"
import "mirai:store"

// What a ref of a Kai namespace reaches, said once. The store's sweep follows
// refs and the chunks of objects, never an address a Kai record holds, so
// every link inside a record is named here, by the kind of object it names:
// the sweep keeps all of it (store_live), and the members', public and grant
// sets serve what of it their peer may read, through the same gate
// (walk_admits). A new kind of object or entry that names another object
// adds its case to walk_children or entry_names, and nothing else.

// What an object of a walk is, and so what it names.
@(private)
Walk_Kind :: enum u8 {
    Change,Folder,Conflict,File, // a project's history: a file is bytes with no Kai kind
    Output,                      // a DDC_Output: the objects of one derived data result
    Log,Log_Page,                // a log's index and its pages, which hold the entries
    Refs,DDC_Set,Overlay,        // what the refs of a project, an org's derived data and a scope name
    Overlay_Tree,Overlay_File,Envelopes,
    Check,                       // what a check printed: bytes only its signer vouches for, never served
}

// The Kai kind of the object each walk kind names; None for plain bytes.
@(private)
WALK_OBJECTS :: [Walk_Kind]Object_Kind{
    .Change=.Change,.Folder=.Folder,.Conflict=.Conflict,.File=.None,.Output=.DDC_Output,.Log=.Log,
    .Log_Page=.Log_Page,.Refs=.Device_Refs,.DDC_Set=.DDC_Set,.Overlay=.Overlay_Record,
    .Overlay_Tree=.Overlay_Tree,.Overlay_File=.Overlay_File,.Envelopes=.Envelopes,.Check=.None,
}

// The kinds a served set reads only when the object is of the Kai kind the
// record that names it says: an address a peer's signed record holds may
// name any object of the store. The walk below a root that came from the org
// (a change, an output) is trusted, as its closure is the org's.
@(private)
WALK_TYPED :: bit_set[Walk_Kind]{.Log,.Log_Page,.Refs,.DDC_Set,.Overlay,.Overlay_Tree,.Overlay_File,.Envelopes}

// root: a change or output a signed record names, served only once it came
// from the org (provenance.odin).
@(private)
Walk_Item :: struct {address:store.Hash,kind:Walk_Kind,root:bool}

@(private)
Walk :: struct {
    s:^store.Store,
    own:Key,            // this machine's device: an output it published is the org's
    entries:bool,       // a leaf page gives what each of its entries names (the sweep); a served set takes the entries a fold holds instead
    untainted:bool,     // a DDC set gives only the outputs no scope taints
    proven:^Provenance, // the gate of a served set; nil walks everything (the sweep)
    tree:[dynamic]Tree_Entry,
    terms:Terms(Term),
}

@(private)
walk_make :: proc(s:^store.Store) -> Walk {
    return {s=s,tree=make([dynamic]Tree_Entry,context.temp_allocator),terms=terms_make(Term,context.temp_allocator)}
}

// Whether the walk of a served set takes item: Wait when it is not here or
// did not come from the org yet, No when it names an object of another kind
// than the record said or one never served.
@(private)
Admit :: enum u8 {Yes,Wait,No}

@(private)
walk_admits :: proc(w:^Walk,item:Walk_Item) -> Admit {
    if w.proven==nil {return .Yes}
    if item.kind==.Check {return .No}
    if item.root && !provenance_has(w.proven,item.address) {return .Wait}
    if item.kind in WALK_TYPED {
        if !object_present(w.s,item.address) {return .Wait}
        kinds:=WALK_OBJECTS
        if object_kind(w.s,item.address)!=kinds[item.kind] {return .No}
    }
    return .Yes
}

// The item a ref names, by the kind of its object, for the sweep: whatever
// namespace holds it. An operation is not one: op_retained walks them.
@(private)
ref_item :: proc(s:^store.Store,address:store.Hash) -> Walk_Item {
    #partial switch object_kind(s,address) {
    case .Change: return {address,.Change,false}
    case .Log: return {address,.Log,false}
    case .Device_Refs: return {address,.Refs,false}
    case .DDC_Set: return {address,.DDC_Set,false}
    case .Overlay_Record: return {address,.Overlay,false}
    }
    return {address,.File,false}
}

// What the entry names in the store, pushed onto out.
@(private)
entry_names :: proc(entry:^Entry,out:^[dynamic]Walk_Item) {
    #partial switch entry.type {
    case .Bookmark_Move:
        if b,_,ok:=body_head(entry.body,Bookmark_Move_Body);ok {append(out,Walk_Item{b.to,.Change,true})}
    case .Proposal_Revise:
        _,tail,ok:=body_head(entry.body,Proposal_Revise_Body)
        if !ok || len(tail)%size_of(Stack_Item)!=0 {return}
        for st in slice.reinterpret([]Stack_Item,tail) {append(out,Walk_Item{st.revision,.Change,true})}
    case .Proposal_Check:
        if b,_,ok:=body_head(entry.body,Proposal_Check_Body);ok {append(out,Walk_Item{b.log_root,.Check,false})}
    case .Epoch_Add:
        if b,_,ok:=body_head(entry.body,Epoch_Add_Body);ok {append(out,Walk_Item{b.envelopes,.Envelopes,false})}
    }
}

// Pushes the objects item names onto stack.
@(private)
walk_children :: proc(w:^Walk,item:Walk_Item,stack:^[dynamic]Walk_Item) {
    s:=w.s
    switch item.kind {
    case .Change:
        c,e:=change_get(s,item.address,context.temp_allocator)
        if e!=.None {return}
        for p in c.parents {append(stack,Walk_Item{p,.Change,false})}
        append(stack,Walk_Item{c.tree,.Folder,false})
        for a in c.attachments {append(stack,Walk_Item{a.object,.File,false})}
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
            append(stack,Walk_Item{entry.address,kind,false})
        }
    case .Conflict:
        clear(&w.terms.adds)
        clear(&w.terms.removes)
        if _,e:=conflict_get(s,item.address,&w.terms);e!=.None {return}
        for list in ([2][]Term{w.terms.adds[:],w.terms.removes[:]}) {
            for t in list {append(stack,Walk_Item{t.address,t.kind==.Folder?.Folder:.File,false})}
        }
    case .Output:
        objects,e:=ddc_output_get(s,item.address,context.temp_allocator)
        if e!=.None {return}
        for o in objects {append(stack,Walk_Item{o,.File,false})}
    case .Log:
        head,_,e:=log_index_read(s,item.address)
        if e!=.None {return}
        append(stack,Walk_Item{head.root,.Log_Page,false})
    case .Log_Page:
        bytes,e:=object_get(s,item.address,.Log_Page,context.temp_allocator)
        if e!=.None {return}
        r:=Reader{data=bytes}
        h:=read_value(&r,Log_Page_Head)
        if r.short || h.magic!=KAI_MAGIC || h.depth>31 {return}
        if !h.leaf {
            children:=slice.reinterpret([]store.Hash,read_bytes(&r,256*size_of(store.Hash)))
            if r.short {return}
            for c in children {
                if c!={} {append(stack,Walk_Item{c,.Log_Page,false})}
            }
            return
        }
        if !w.entries {return}
        for _ in 0..<min(h.count,LOG_PAGE_ENTRIES) {
            size:=read_value(&r,u32)
            entry_bytes:=read_bytes(&r,int(size))
            if r.short {return}
            entry,de:=entry_decode(entry_bytes)
            if de==.None {entry_names(&entry,stack)}
        }
    case .Refs:
        bytes,e:=object_get(s,item.address,.Device_Refs,context.temp_allocator)
        if e!=.None {return}
        d,de:=device_refs_decode(bytes,context.temp_allocator)
        if de!=.None {return}
        for b in d.refs {append(stack,Walk_Item{b.target,.Change,true})}
    case .DDC_Set:
        records:=make([dynamic][]u8,context.temp_allocator)
        if ddc_set_read(s,item.address,&records)!=.None {return}
        for bytes in records {
            d,de:=ddc_record_decode(bytes)
            if de!=.None || (w.untainted && d.tainted>0) {continue}
            append(stack,Walk_Item{d.output_root,.Output,d.producer!=w.own})
        }
    case .Overlay:
        bytes,e:=overlay_get(s,item.address,.Overlay_Record,OVERLAY_RECORD_MAX,context.temp_allocator)
        if e!=.None {return}
        r,re:=overlay_record_decode(bytes)
        if re!=.None {return}
        append(stack,Walk_Item{r.tree_root,.Overlay_Tree,false})
        for o in r.objects {append(stack,Walk_Item{o,.Overlay_File,false})}
    case .File,.Overlay_Tree,.Overlay_File,.Envelopes,.Check:
    }
}

// The objects roots reach as far as w admits them: present gets those in
// the store, missing those that are not or wait to come from the org (what
// lies under them is not walked).
@(private)
walk_all :: proc(w:^Walk,roots:[]Walk_Item,present,missing:^[dynamic]store.Hash) {
    stack:=make([dynamic]Walk_Item,context.temp_allocator)
    seen:=make(map[store.Hash]bool,context.temp_allocator)
    append(&stack,..roots)
    empty:=empty_address()
    for len(stack)>0 {
        item:=pop(&stack)
        if item.address=={} || seen[item.address] {continue}
        seen[item.address]=true
        admit:=walk_admits(w,item)
        if admit==.No {continue}
        if admit==.Wait || !object_present(w.s,item.address) {
            if item.address!=empty {append(missing,item.address)}
            continue
        }
        append(present,item.address)
        walk_children(w,item,&stack)
    }
}

// The Kai objects reachable from revisions: changes, their parents, their
// trees, folders, conflicts and files, and the objects they attach. present
// gets those in the store, missing those that are not (what lies under them
// is not walked).
closure_walk :: proc(s:^store.Store,revisions:[]Revision,present,missing:^[dynamic]store.Hash) {
    w:=walk_make(s)
    roots:=make([dynamic]Walk_Item,0,len(revisions),context.temp_allocator)
    for r in revisions {append(&roots,Walk_Item{r,.Change,false})}
    walk_all(&w,roots[:],present,missing)
}

// The chunks of the index at address and of every page below it, as far as
// the store holds them: what a peer reads of a log.
log_objects :: proc(s:^store.Store,address:store.Hash,out:^[dynamic]store.Hash) {
    w:=walk_make(s)
    present:=make([dynamic]store.Hash,context.temp_allocator)
    missing:=make([dynamic]store.Hash,context.temp_allocator)
    walk_all(&w,{{address,.Log,false}},&present,&missing)
    for o in present {object_chunks(s,o,out)}
}
