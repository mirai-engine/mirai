package kai

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:unicode/utf8"
import "mirai:store"

// The signed logs of governance and review: User_Log, Org_Log, Project_Log,
// Proposal_Log and Keyring_Log share one entry format, one DAG and one fold.
// An entry names up to ENTRY_PARENTS_MAX parents by address (the BLAKE3 of its
// bytes); a log's id is the address of its genesis, the one entry without
// parents and with a zero log_id. Every peer folds the same entries to the same
// state: a topological walk whose ties go by address, where an entry counts
// only if its author held the right in the state of its causal past. A removal
// voids what its subject wrote concurrently, and the removal itself is never
// voided, so two admins removing each other remove both. A device revocation
// names, per log, the heads whose causal past its device's entries must be in:
// whatever the device signs later, backdated or not, is outside it.
//
// The entries of one log are kept together as one Log object, sorted by
// address, under the ref kai-log/<log id hex>, or kai-user/<log id hex> for a
// User_Log. Signatures are checked when
// entries come from a peer (log_merge), never on a local read.

Log_Id :: store.Hash
Scope_Id :: distinct [16]u8

Log_Kind :: enum u8 {User,Org,Project,Proposal,Keyring}

Entry_Type :: enum u8 {
    None,
    User_Genesis,Device_Add,Device_Revoke,Recovery_Rotate,Web_Key_Add,
    Org_Genesis,Member_Add,Member_Remove,Role_Set,Owner_Transfer,Project_Add,Scope_Add,Scope_Remove,Policy_Set,Grant,Grant_Revoke,Node_Add,Node_Remove,
    Project_Genesis,Bookmark_Move,
    Proposal_Open,Proposal_Revise,Proposal_Comment,Proposal_Verdict,Proposal_Check,Proposal_Land,Proposal_Close,Proposal_Reopen,
    Keyring_Genesis,Epoch_Add,Envelope_Add,
}

Sig_Kind :: enum u8 {Ed25519,WebAuthn} // WebAuthn: the assertion of a browser review, verified from M5 on

Entry_Head :: struct #packed {
    magic:u32,
    version:u16,
    kind:Entry_Type,
    parents:u8,            // <= ENTRY_PARENTS_MAX; a genesis has none
    log_id:Log_Id,         // zero in a genesis
    author:Key,            // a device, the recovery key or a web key
    author_ctx:store.Hash, // the head of the author's User_Log when it signed
    time:i64,              // ns
    body_len:u32,
    sig_kind:Sig_Kind,
    reserved:[3]u8,
} // + [parents]store.Hash sorted, body, then Signature or u16 length + WebAuthn assertion

ENTRY_PARENTS_MAX :: 8
ENTRY_BODY_MAX :: 64<<10
ASSERTION_MAX :: 2048
LOG_ENTRIES_MAX :: 4096 // entries of one log: the fold is quadratic in them
NAME_MAX :: 64          // bytes of the name of a user, device, org or project
PATTERNS_MAX :: 64
CHECKS_MAX :: 32
HORIZONS_MAX :: 64
NODE_ADDRESSES_MAX :: 8
ENVELOPES_MAX :: 1024
STACK_MAX :: 256
WRAPPED_BYTES :: 80     // a scope key wrapped for one device: e, the key and its tag
LABEL_DEVICE :: "kai-1/device" // what a device signs, with the log it joins, to prove it holds its key

Entry :: struct {
    type:Entry_Type,
    log_id:Log_Id,
    parents:[]store.Hash,
    author:Key,
    author_ctx:store.Hash,
    time:i64,
    body:[]u8,
    sig_kind:Sig_Kind,
    signature:Signature,
    assertion:[]u8,
}

Role :: enum u8 {None,Reader,Writer,Admin,Owner}
Right :: enum u8 {Read,Write,DDC,Check,Relay}
Rights :: bit_set[Right;u8]
Node_Mode :: enum u8 {Relay,Seed,DDC}
Node_Modes :: bit_set[Node_Mode;u8]
Verdict_Kind :: enum u8 {Approve,Changes,Withdraw}
Check_State :: enum u8 {Pending,Passed,Failed}

// The fixed part of each body; what follows it is said beside it.
User_Genesis_Body :: struct #packed {recovery:Key,device:Key,dh:Dh_Key,proof:Signature} // + name. proof: the device signs LABEL_DEVICE || recovery
Device_Add_Body :: struct #packed {device:Key,dh:Dh_Key,proof:Signature}               // + name. proof: the device signs LABEL_DEVICE || log id
Device_Revoke_Body :: struct #packed {device:Key,horizons:u8}                          // + horizons × (Horizon, [heads]store.Hash)
Horizon :: struct #packed {log_id:Log_Id,heads:u8}
Recovery_Rotate_Body :: struct #packed {recovery:Key}
Web_Key_Add_Body :: struct #packed {credential:u8,cose:u16,rp:u8}                      // + credential id, COSE key, relying party id
Org_Genesis_Body :: struct #packed {owner:Log_Id}                                       // + name
Member_Body :: struct #packed {user:Log_Id,role:Role}                                   // Member_Add, Role_Set
Subject_Body :: struct #packed {subject:store.Hash}                                     // Member_Remove, Owner_Transfer (a user), Grant_Revoke (a grant)
Project_Add_Body :: struct #packed {project:Log_Id,public:b8}
Scope_Add_Body :: struct #packed {project:Log_Id,scope:Scope_Id,readers:Role,history:b8,patterns:u8} // + patterns × (u8 length, bytes)
Scope_Remove_Body :: struct #packed {project:Log_Id,scope:Scope_Id}
Policy_Set_Body :: struct #packed {project:Log_Id,approvals:u8,checks:u8}                // + bookmark and checks, each u8 length and bytes
Node_Add_Body :: struct #packed {node:Key,dh:Dh_Key,modes:Node_Modes,addresses:u8}     // + [addresses]Node_Address
Node_Address :: struct #packed {kind:u8,port:u16,ip:[16]u8}                             // kind: 1 IPv4, 2 IPv6
Node_Remove_Body :: struct #packed {node:Key}
Project_Genesis_Body :: struct #packed {org:Log_Id,public:b8}                           // + name
Bookmark_Move_Body :: struct #packed {to:Revision,proposal:store.Hash,from:u8}         // + [from]Revision, bookmark
Proposal_Open_Body :: struct #packed {project:Log_Id,target:u8,title:u16}              // + target bookmark, title, text
Proposal_Revise_Body :: struct #packed {count:u16}                                      // + [count]Stack_Item
Stack_Item :: struct #packed {change:Change_Id,revision:Revision}
// The Anchor of a comment as the log stores it, with its path's length and the change it was made on.
Comment_Anchor :: struct #packed {kind:Anchor_Kind,path:u16,line:u32,lines:u32,key:u64,field:u64,change:Change_Id}
Proposal_Comment_Body :: struct #packed {reply_to:store.Hash,anchor:Comment_Anchor}            // + path, text
Proposal_Verdict_Body :: struct #packed {verdict:Verdict_Kind,revision:Revision}
Proposal_Check_Body :: struct #packed {revision:Revision,state:Check_State,log_root:store.Hash} // + name
Proposal_Land_Body :: struct #packed {revision:Revision,bookmark_move:store.Hash}
Keyring_Genesis_Body :: struct #packed {org:Log_Id,project:Log_Id,scope:Scope_Id}
Envelope :: struct #packed {dh:Dh_Key,wrapped:[WRAPPED_BYTES]u8}
Epoch_Add_Body :: struct #packed {epoch:u32,envelopes:u16}                              // + [envelopes]Envelope
Envelope_Add_Body :: struct #packed {epoch:u32,envelope:Envelope}

entry_log_kind :: proc "contextless" (t:Entry_Type) -> (kind:Log_Kind,ok:bool) {
    switch t {
    case .None: return {},false
    case .User_Genesis,.Device_Add,.Device_Revoke,.Recovery_Rotate,.Web_Key_Add: return .User,true
    case .Org_Genesis,.Member_Add,.Member_Remove,.Role_Set,.Owner_Transfer,.Project_Add,.Scope_Add,.Scope_Remove,.Policy_Set,.Grant,.Grant_Revoke,.Node_Add,.Node_Remove: return .Org,true
    case .Project_Genesis,.Bookmark_Move: return .Project,true
    case .Proposal_Open,.Proposal_Revise,.Proposal_Comment,.Proposal_Verdict,.Proposal_Check,.Proposal_Land,.Proposal_Close,.Proposal_Reopen: return .Proposal,true
    case .Keyring_Genesis,.Epoch_Add,.Envelope_Add: return .Keyring,true
    }
    return {},false
}

@(private)
genesis :: proc "contextless" (t:Entry_Type) -> bool {
    #partial switch t {
    case .User_Genesis,.Org_Genesis,.Project_Genesis,.Proposal_Open,.Keyring_Genesis: return true
    }
    return false
}

// What an entry says, before it is signed.
Draft :: struct {
    type:Entry_Type,
    log_id:Log_Id, // zero for a genesis
    parents:[]store.Hash,
    author_ctx:store.Hash,
    time:i64,
    body:[]u8,
}

// The bytes of d signed by identity, and their address.
entry_sign :: proc(d:^Draft,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,address:store.Hash,error:Error) {
    if len(d.parents)>ENTRY_PARENTS_MAX || len(d.body)>ENTRY_BODY_MAX {return nil,{},.Too_Large}
    if genesis(d.type)!=(len(d.parents)==0) || genesis(d.type)!=(d.log_id=={}) || !body_valid(d.type,d.body) {return nil,{},.Invalid_Argument}
    parents,parents_error:=slice.clone(d.parents,context.temp_allocator)
    if parents_error!=nil {return nil,{},.Out_Of_Memory}
    slice.sort_by(parents,hash_less)
    for p,i in parents {
        if p=={} || (i>0 && parents[i-1]==p) {return nil,{},.Invalid_Argument}
    }
    w:=writer_make(allocator)
    write_value(&w,Entry_Head{
        magic=KAI_MAGIC,version=VERSION,kind=d.type,parents=u8(len(parents)),log_id=d.log_id,author=identity.key,
        author_ctx=d.author_ctx,time=d.time,body_len=u32(len(d.body)),sig_kind=.Ed25519,
    })
    for &p in parents {write_bytes(&w,p[:])}
    write_bytes(&w,d.body)
    if w.failed {
        delete(w.data)
        return nil,{},.Out_Of_Memory
    }
    signature:=sign(identity,w.data[:])
    write_bytes(&w,signature[:])
    if w.failed {
        delete(w.data)
        return nil,{},.Out_Of_Memory
    }
    return w.data[:],store.address_of_bytes(w.data[:]),.None
}

// The entry of bytes, checked; its slices point into bytes.
entry_decode :: proc(bytes:[]u8) -> (e:Entry,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,Entry_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSION || !zero(head.reserved[:]) {return {},.Corrupt}
    if _,known:=entry_log_kind(head.kind);!known || head.parents>ENTRY_PARENTS_MAX || head.body_len>ENTRY_BODY_MAX || head.sig_kind>max(Sig_Kind) {return {},.Corrupt}
    if genesis(head.kind)!=(head.parents==0) || genesis(head.kind)!=(head.log_id=={}) {return {},.Corrupt}
    e.type,e.log_id,e.author,e.author_ctx,e.time,e.sig_kind=head.kind,head.log_id,head.author,head.author_ctx,head.time,head.sig_kind
    e.parents=slice.reinterpret([]store.Hash,read_bytes(&r,int(head.parents)*size_of(store.Hash)))
    for p,i in e.parents {
        if p=={} || (i>0 && !hash_less(e.parents[i-1],p)) {return {},.Corrupt}
    }
    e.body=read_bytes(&r,int(head.body_len))
    switch head.sig_kind {
    case .Ed25519: e.signature=read_value(&r,Signature)
    case .WebAuthn:
        length:=read_value(&r,u16)
        if length==0 || length>ASSERTION_MAX {return {},.Corrupt}
        e.assertion=read_bytes(&r,int(length))
    }
    if r.short || r.at!=len(bytes) || !body_valid(e.type,e.body) {return {},.Corrupt}
    return e,.None
}

// Whether the entry of bytes is signed by its author. A WebAuthn assertion is
// not verified before M5, so it never counts.
entry_verify :: proc(bytes:[]u8,e:^Entry) -> bool {
    if e.sig_kind!=.Ed25519 {return false}
    return signature_valid(e.author,bytes[:len(bytes)-size_of(Signature)],e.signature)
}

// The fixed part of a body and what follows it.
body_head :: proc "contextless" (body:[]u8,$T:typeid) -> (head:T,tail:[]u8,ok:bool) {
    if len(body)<size_of(T) {return}
    mem.copy_non_overlapping(&head,raw_data(body),size_of(T))
    return head,body[size_of(T):],true
}

// The next u8-length-prefixed string of a tail.
@(private)
tail_string :: proc "contextless" (r:^Reader) -> string {
    n:=read_value(r,u8)
    return string(read_bytes(r,int(n)))
}

@(private)
name_valid :: proc(name:string,empty:=false) -> bool {
    return (empty || len(name)>0) && len(name)<=NAME_MAX && utf8.valid_string(name)
}

@(private)
role_valid :: proc "contextless" (role:Role) -> bool {return role>=.Reader && role<=.Admin}

// Whether body is a well-formed body of type t.
body_valid :: proc(t:Entry_Type,body:[]u8) -> bool {
    switch t {
    case .None: return false
    case .User_Genesis:
        _,tail,ok:=body_head(body,User_Genesis_Body)
        return ok && name_valid(string(tail))
    case .Device_Add:
        _,tail,ok:=body_head(body,Device_Add_Body)
        return ok && name_valid(string(tail))
    case .Device_Revoke:
        head,tail,ok:=body_head(body,Device_Revoke_Body)
        if !ok || head.horizons>HORIZONS_MAX {return false}
        r:=Reader{data=tail}
        for _ in 0..<head.horizons {
            h:=read_value(&r,Horizon)
            if h.heads==0 || h.heads>ENTRY_PARENTS_MAX || h.log_id=={} {return false}
            read_bytes(&r,int(h.heads)*size_of(store.Hash))
        }
        return !r.short && r.at==len(tail)
    case .Recovery_Rotate,.Member_Remove,.Owner_Transfer,.Grant_Revoke,.Project_Add,.Scope_Remove,.Node_Remove,.Proposal_Verdict,.Proposal_Land,.Keyring_Genesis,.Envelope_Add:
        size:=0
        #partial switch t {
        case .Recovery_Rotate: size=size_of(Recovery_Rotate_Body)
        case .Member_Remove,.Owner_Transfer,.Grant_Revoke: size=size_of(Subject_Body)
        case .Project_Add: size=size_of(Project_Add_Body)
        case .Scope_Remove: size=size_of(Scope_Remove_Body)
        case .Node_Remove: size=size_of(Node_Remove_Body)
        case .Proposal_Verdict:
            head,_,ok:=body_head(body,Proposal_Verdict_Body)
            if !ok || head.verdict>max(Verdict_Kind) {return false}
            size=size_of(Proposal_Verdict_Body)
        case .Proposal_Land: size=size_of(Proposal_Land_Body)
        case .Keyring_Genesis: size=size_of(Keyring_Genesis_Body)
        case .Envelope_Add: size=size_of(Envelope_Add_Body)
        }
        return len(body)==size
    case .Web_Key_Add:
        head,tail,ok:=body_head(body,Web_Key_Add_Body)
        return ok && head.credential>0 && head.cose>0 && head.rp>0 && len(tail)==int(head.credential)+int(head.cose)+int(head.rp)
    case .Org_Genesis:
        _,tail,ok:=body_head(body,Org_Genesis_Body)
        return ok && name_valid(string(tail))
    case .Member_Add,.Role_Set:
        head,tail,ok:=body_head(body,Member_Body)
        return ok && len(tail)==0 && role_valid(head.role)
    case .Scope_Add:
        head,tail,ok:=body_head(body,Scope_Add_Body)
        if !ok || head.patterns==0 || head.patterns>PATTERNS_MAX || !role_valid(head.readers) {return false}
        r:=Reader{data=tail}
        for _ in 0..<head.patterns {
            if p:=tail_string(&r);len(p)==0 || !utf8.valid_string(p) {return false}
        }
        return !r.short && r.at==len(tail)
    case .Policy_Set:
        head,tail,ok:=body_head(body,Policy_Set_Body)
        if !ok || head.checks>CHECKS_MAX {return false}
        r:=Reader{data=tail}
        if b:=tail_string(&r);len(b)==0 {return false}
        for _ in 0..<head.checks {
            if c:=tail_string(&r);len(c)==0 {return false}
        }
        return !r.short && r.at==len(tail)
    case .Grant:
        _,error:=grant_decode(body)
        return error==.None
    case .Node_Add:
        head,tail,ok:=body_head(body,Node_Add_Body)
        if !ok || head.addresses>NODE_ADDRESSES_MAX || len(tail)!=int(head.addresses)*size_of(Node_Address) {return false}
        for a in slice.reinterpret([]Node_Address,tail) {
            if a.kind<1 || a.kind>2 {return false}
        }
        return true
    case .Project_Genesis:
        _,tail,ok:=body_head(body,Project_Genesis_Body)
        return ok && name_valid(string(tail))
    case .Bookmark_Move:
        head,tail,ok:=body_head(body,Bookmark_Move_Body)
        if !ok || head.to=={} || int(head.from)>CONFLICT_SIDES_MAX || len(tail)<=int(head.from)*size_of(Revision) {return false}
        name:=string(tail[int(head.from)*size_of(Revision):])
        return len(name)<=BOOKMARK_NAME_MAX && utf8.valid_string(name)
    case .Proposal_Open:
        head,tail,ok:=body_head(body,Proposal_Open_Body)
        return ok && head.target>0 && len(tail)>=int(head.target)+int(head.title) && len(tail)<=int(head.target)+int(head.title)+DESCRIPTION_MAX && utf8.valid_string(string(tail))
    case .Proposal_Revise:
        head,tail,ok:=body_head(body,Proposal_Revise_Body)
        return ok && head.count>0 && head.count<=STACK_MAX && len(tail)==int(head.count)*size_of(Stack_Item)
    case .Proposal_Comment:
        head,tail,ok:=body_head(body,Proposal_Comment_Body)
        return ok && head.anchor.kind<=max(Anchor_Kind) && len(tail)>=int(head.anchor.path) && int(head.anchor.path)<=PATH_MAX && utf8.valid_string(string(tail))
    case .Proposal_Check:
        head,tail,ok:=body_head(body,Proposal_Check_Body)
        return ok && head.state<=max(Check_State) && name_valid(string(tail))
    case .Proposal_Close,.Proposal_Reopen:
        return len(body)==0
    case .Epoch_Add:
        head,tail,ok:=body_head(body,Epoch_Add_Body)
        return ok && head.envelopes>0 && head.envelopes<=ENVELOPES_MAX && len(tail)==int(head.envelopes)*size_of(Envelope)
    }
    return false
}

// A body: its fixed part, then tail.
body_make :: proc(head:$T,tail:..[]u8) -> []u8 {
    size:=size_of(T)
    for t in tail {size+=len(t)}
    bytes,error:=make([]u8,size,context.temp_allocator)
    if error!=nil {return nil}
    h:=head
    copy(bytes,mem.ptr_to_bytes(&h))
    at:=size_of(T)
    for t in tail {at+=copy(bytes[at:],t)}
    return bytes
}

// Strings each prefixed by their u8 length, for the tail of a body.
strings_tail :: proc(texts:..string) -> []u8 {
    size:=0
    for t in texts {size+=1+min(len(t),255)}
    bytes,error:=make([]u8,size,context.temp_allocator)
    if error!=nil {return nil}
    at:=0
    for t in texts {
        n:=min(len(t),255)
        bytes[at]=u8(n)
        copy(bytes[at+1:],t[:n])
        at+=1+n
    }
    return bytes
}

// What a device signs to prove it holds its key, for the log it joins: the
// recovery key of a genesis, the log id of a Device_Add.
device_proof :: proc(device:^Identity,joins:[32]u8) -> Signature {
    message:[len(LABEL_DEVICE)+32]u8
    copy(message[:],LABEL_DEVICE)
    j:=joins
    copy(message[len(LABEL_DEVICE):],j[:])
    return sign(device,message[:])
}

@(private)
device_proof_valid :: proc(device:Key,joins:[32]u8,proof:Signature) -> bool {
    message:[len(LABEL_DEVICE)+32]u8
    copy(message[:],LABEL_DEVICE)
    j:=joins
    copy(message[len(LABEL_DEVICE):],j[:])
    return signature_valid(device,message[:],proof)
}

// One log's entries in memory: sorted by address, with their DAG indexed by
// log_index.
Log :: struct {
    id:Log_Id,
    kind:Log_Kind,
    items:[dynamic]Log_Item,
    order:[dynamic]u32,  // topological, ties by address
    rank:[dynamic]u32,   // the place of each item in order
    parent_first:[dynamic]u32,
    parent_list:[dynamic]u32,
    complete:[dynamic]bool, // every ancestor is here
    past:[dynamic]u64,   // bit a of the words of e: a is a strict ancestor of e
    words:int,
    indexed:bool,
    allocator:runtime.Allocator,
}

Log_Item :: struct {
    address:store.Hash,
    bytes:[]u8, // the log's own copy
    entry:Entry, // into bytes
}

log_init :: proc(l:^Log,id:Log_Id={},allocator:=context.allocator) {
    l^={id=id,allocator=allocator}
    l.items=make([dynamic]Log_Item,allocator)
    l.order=make([dynamic]u32,allocator)
    l.rank=make([dynamic]u32,allocator)
    l.parent_first=make([dynamic]u32,allocator)
    l.parent_list=make([dynamic]u32,allocator)
    l.complete=make([dynamic]bool,allocator)
    l.past=make([dynamic]u64,allocator)
}

log_destroy :: proc(l:^Log) {
    for item in l.items {delete(item.bytes,l.allocator)}
    delete(l.items)
    delete(l.order)
    delete(l.rank)
    delete(l.parent_first)
    delete(l.parent_list)
    delete(l.complete)
    delete(l.past)
    l^={}
}

// The index of the entry at address, -1 when it is not here.
log_find :: proc(l:^Log,address:store.Hash) -> int {
    i,found:=slice.binary_search_by(l.items[:],address,proc(item:Log_Item,a:store.Hash) -> slice.Ordering {
        if item.address==a {return .Equal}
        return hash_less(item.address,a)?.Less:.Greater
    })
    return found?i:-1
}

// Adds the entry of bytes, checking its signature when verify; added is false
// when it was here. An entry of another log is refused.
log_add :: proc(l:^Log,bytes:[]u8,verify:bool) -> (added:bool,error:Error) {
    e:=entry_decode(bytes) or_return
    address:=store.address_of_bytes(bytes)
    kind,_:=entry_log_kind(e.type)
    if genesis(e.type) {
        if l.id!={} && l.id!=address {return false,.Invalid_Argument}
    } else if l.id=={} || e.log_id!=l.id {
        return false,.Invalid_Argument
    }
    if len(l.items)>0 && kind!=l.kind {return false,.Invalid_Argument}
    if log_find(l,address)>=0 {return false,.None}
    if len(l.items)>=LOG_ENTRIES_MAX {return false,.Too_Large}
    if verify && !entry_verify(bytes,&e) {return false,.Unauthorized}
    own,clone_error:=slice.clone(bytes,l.allocator)
    if clone_error!=nil {return false,.Out_Of_Memory}
    e,_=entry_decode(own)
    at,_:=slice.binary_search_by(l.items[:],address,proc(item:Log_Item,a:store.Hash) -> slice.Ordering {
        return hash_less(item.address,a)?.Less:.Greater
    })
    if _,insert_error:=inject_at(&l.items,at,Log_Item{address=address,bytes=own,entry=e});insert_error!=nil {
        delete(own,l.allocator)
        return false,.Out_Of_Memory
    }
    if genesis(e.type) {l.id=address}
    l.kind=kind
    l.indexed=false
    return true,.None
}

// Builds the parents, the topological order and the ancestry of the log.
log_index :: proc(l:^Log) -> Error {
    if l.indexed {return .None}
    n:=len(l.items)
    l.words=(n+63)/64
    if resize(&l.order,0)!=nil || resize(&l.rank,n)!=nil || resize(&l.parent_first,n+1)!=nil || resize(&l.complete,n)!=nil || resize(&l.past,n*l.words)!=nil {return .Out_Of_Memory}
    clear(&l.parent_list)
    if reserve(&l.parent_list,n*ENTRY_PARENTS_MAX)!=nil || reserve(&l.order,n)!=nil {return .Out_Of_Memory}
    mem.zero_slice(l.past[:])
    missing:=make([]bool,n,context.temp_allocator)
    for &item,i in l.items {
        l.parent_first[i]=u32(len(l.parent_list))
        for p in item.entry.parents {
            k:=log_find(l,p)
            if k<0 {
                missing[i]=true
                continue
            }
            append(&l.parent_list,u32(k))
        }
    }
    l.parent_first[n]=u32(len(l.parent_list))
    // Kahn's walk taking the ready entry of the lowest address first; an entry
    // with an absent ancestor is not complete and comes after.
    waiting:=make([]u32,n,context.temp_allocator)
    child_first:=make([]u32,n+1,context.temp_allocator)
    child_list:=make([]u32,len(l.parent_list),context.temp_allocator)
    for p in l.parent_list {child_first[p+1]+=1}
    for i in 0..<n {child_first[i+1]+=child_first[i]}
    child_at:=make([]u32,n,context.temp_allocator)
    for i in 0..<n {
        for p in log_parents(l,i) {
            waiting[i]+=1
            child_list[child_first[p]+child_at[p]]=u32(i)
            child_at[p]+=1
        }
    }
    ready:=make([dynamic]u32,context.temp_allocator)
    for i in 0..<n {
        if waiting[i]==0 {append(&ready,u32(i))}
    }
    placed:=make([]bool,n,context.temp_allocator)
    for len(ready)>0 {
        best:=0
        for k in 1..<len(ready) {
            if ready[k]<ready[best] {best=k}
        }
        i:=ready[best]
        unordered_remove(&ready,best)
        placed[i]=true
        l.rank[i]=u32(len(l.order))
        append(&l.order,i)
        complete:=!missing[i] && (genesis(l.items[i].entry.type) || len(l.items[i].entry.parents)>0)
        past:=l.past[int(i)*l.words:][:l.words]
        for p in log_parents(l,int(i)) {
            complete&=l.complete[p]
            past[p/64]|=1<<(p%64)
            for w,k in l.past[int(p)*l.words:][:l.words] {past[k]|=w}
        }
        l.complete[i]=complete
        for c in child_list[child_first[i]:child_first[i+1]] {
            waiting[c]-=1
            if waiting[c]==0 {append(&ready,c)}
        }
    }
    // What a cycle of hashes would leave: nothing a peer can make, refused all the same.
    for i in 0..<n {
        if !placed[i] {
            l.rank[i]=u32(len(l.order))
            append(&l.order,u32(i))
            l.complete[i]=false
        }
    }
    l.indexed=true
    return .None
}

log_parents :: proc(l:^Log,i:int) -> []u32 {
    return l.parent_list[l.parent_first[i]:l.parent_first[i+1]]
}

// Whether a is a strict ancestor of e.
log_before :: #force_inline proc(l:^Log,a,e:int) -> bool {
    return l.past[e*l.words+a/64]&(1<<uint(a%64))!=0
}

// Whether a is e or one of its ancestors.
log_within :: #force_inline proc(l:^Log,a,e:int) -> bool {return a==e || log_before(l,a,e)}

log_concurrent :: #force_inline proc(l:^Log,a,b:int) -> bool {
    return a!=b && !log_before(l,a,b) && !log_before(l,b,a)
}

// The complete entries no complete entry descends from, sorted by address.
log_heads :: proc(l:^Log,out:^[dynamic]store.Hash) -> Error {
    log_index(l) or_return
    clear(out)
    for i in 0..<len(l.items) {
        if !l.complete[i] {continue}
        head:=true
        for k in 0..<len(l.items) {
            if l.complete[k] && log_before(l,i,k) {
                head=false
                break
            }
        }
        if head {
            if _,e:=append(out,l.items[i].address);e!=nil {return .Out_Of_Memory}
        }
    }
    return .None
}

// Appends an entry signed by identity to the log, its parents the heads: the
// entry's address.
log_append :: proc(l:^Log,type:Entry_Type,body:[]u8,identity:^Identity,time:i64,author_ctx:=store.Hash{}) -> (address:store.Hash,error:Error) {
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if !genesis(type) {
        log_heads(l,&heads) or_return
        if len(heads)==0 {return {},.Invalid_Argument}
        if len(heads)>ENTRY_PARENTS_MAX {resize(&heads,ENTRY_PARENTS_MAX)}
    }
    d:=Draft{type=type,log_id=genesis(type)?{}:l.id,parents=heads[:],author_ctx=author_ctx,time=time,body=body}
    bytes:[]u8
    bytes,address,error=entry_sign(&d,identity,context.temp_allocator)
    if error!=.None {return}
    _,error=log_add(l,bytes,false)
    return
}

LOG_NAMESPACE :: "kai-log"

Log_Bundle_Head :: struct #packed {
    magic:u32,
    version:u16,
    kind:Log_Kind,
    reserved:u8,
    count:u32,
    id:Log_Id,
} // + count × (u32 length, entry bytes), sorted by address

// The ref name of a log: the hex of its id.
log_name :: proc(id:Log_Id,buffer:^[64]u8) -> string {return store.hex(id,buffer)}

// Puts the log's entries as one Log object and points its ref at it.
log_save :: proc(s:^store.Store,l:^Log) -> (address:store.Hash,error:Error) {
    if l.id=={} {return {},.Invalid_Argument}
    w:=writer_make(context.temp_allocator)
    write_value(&w,Log_Bundle_Head{magic=KAI_MAGIC,version=VERSION,kind=l.kind,count=u32(len(l.items)),id=l.id})
    for item in l.items {
        write_value(&w,u32(len(item.bytes)))
        write_bytes(&w,item.bytes)
    }
    if w.failed {return {},.Out_Of_Memory}
    address=object_put(s,.Log,w.data[:]) or_return
    name:[64]u8
    if e:=store.ref_set(s,log_namespace(l.kind),log_name(l.id,&name),address);e!=.None {return {},store_error(e)}
    return address,.None
}

// Adds to l the entries of the Log object at address, checking each signature
// when verify; changed when one was new.
log_load :: proc(s:^store.Store,l:^Log,address:store.Hash,verify:bool) -> (changed:bool,error:Error) {
    bytes:=object_get(s,address,.Log,context.temp_allocator) or_return
    r:=Reader{data=bytes}
    head:=read_value(&r,Log_Bundle_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSION || head.reserved!=0 || head.kind>max(Log_Kind) || head.count>LOG_ENTRIES_MAX || head.id=={} {return false,.Corrupt}
    if l.id!={} && l.id!=head.id {return false,.Invalid_Argument}
    l.id=head.id
    for _ in 0..<head.count {
        size:=read_value(&r,u32)
        entry:=read_bytes(&r,int(size))
        if r.short {return changed,.Corrupt}
        added,add_error:=log_add(l,entry,verify)
        if add_error==.Corrupt || add_error==.Out_Of_Memory || add_error==.Too_Large {return changed,add_error}
        changed|=added
    }
    if r.at!=len(bytes) {return changed,.Corrupt}
    return changed,.None
}

// The namespace of the refs of logs of kind: User_Logs apart, since peers
// not admitted yet read them to prove who they are.
log_namespace :: proc "contextless" (kind:Log_Kind) -> string {return kind==.User?USER_NAMESPACE:LOG_NAMESPACE}

// Opens the log of id from its ref: Missing when the store has none.
log_open :: proc(s:^store.Store,l:^Log,id:Log_Id,kind:Log_Kind) -> Error {
    name:[64]u8
    address,e:=store.ref_get(s,log_namespace(kind),log_name(id,&name))
    if e!=.None {return store_error(e)}
    _,error:=log_load(s,l,address,false)
    return error
}

// Merges the Log object a peer gave at address into l, verified, and saves l
// when it grew. A bad entry of the peer is skipped, the rest are taken.
log_merge :: proc(s:^store.Store,l:^Log,address:store.Hash) -> (changed:bool,error:Error) {
    changed,error=log_load(s,l,address,true)
    if changed {
        _,save:=log_save(s,l)
        if save!=.None {return changed,save}
    }
    return
}

// The rules of one kind of log for the fold: data is its fold.
@(private)
Rules :: struct {
    data:rawptr,
    reset:proc(data:rawptr),
    authorized:proc(data:rawptr,e:int) -> bool, // in the state of e's causal past
    apply:proc(data:rawptr,e:int),
    removal:proc(data:rawptr,r:int) -> bool,    // r is never voided
    voids:proc(data:rawptr,r,e:int) -> bool,    // valid removal r voids valid e
}

// The validity of every entry of l, as all peers find it, and then the state
// of the valid entries applied in order. Voiding entries can change who holds
// a right after them, so the walk runs again until nothing more is voided:
// the voided set only grows, so it ends.
@(private)
fold_run :: proc(l:^Log,rules:Rules,valid:[]bool) -> Error {
    log_index(l) or_return
    n:=len(l.items)
    forced:=make([]bool,n,context.temp_allocator)
    for {
        for e in l.order {
            valid[e]=false
            if forced[e] || !l.complete[e] {continue}
            rules.reset(rules.data)
            for a in l.order[:l.rank[e]] {
                if valid[a] && log_before(l,int(a),int(e)) {rules.apply(rules.data,int(a))}
            }
            valid[e]=rules.authorized(rules.data,int(e))
        }
        changed:=false
        for r in l.order {
            if !valid[r] || !rules.removal(rules.data,int(r)) {continue}
            for e in l.order {
                if valid[e] && !forced[e] && !rules.removal(rules.data,int(e)) && rules.voids(rules.data,int(r),int(e)) {
                    forced[e]=true
                    changed=true
                }
            }
        }
        if !changed {break}
    }
    rules.reset(rules.data)
    for e in l.order {
        if valid[e] {rules.apply(rules.data,int(e))}
    }
    return .None
}

// Applies the valid entries of the causal past of head, and head, alone.
@(private)
fold_at :: proc(l:^Log,rules:Rules,valid:[]bool,head:int) {
    rules.reset(rules.data)
    for e in l.order {
        if valid[e] && log_within(l,int(e),head) {rules.apply(rules.data,int(e))}
    }
}

@(private)
fold_all :: proc(l:^Log,rules:Rules,valid:[]bool) {
    rules.reset(rules.data)
    for e in l.order {
        if valid[e] {rules.apply(rules.data,int(e))}
    }
}

// --- User_Log ---

Device :: struct {
    key:Key,
    dh:Dh_Key,
    added:u32,   // its Device_Add or genesis
    revoked:bool,
    revoke:u32,  // its Device_Revoke
}

User_Fold :: struct {
    log:^Log,
    valid:[]bool,
    recovery:Key,
    devices:[dynamic]Device,
    web_keys:int,
}

user_fold :: proc(f:^User_Fold,l:^Log,allocator:=context.allocator) -> Error {
    f^={log=l}
    f.devices=make([dynamic]Device,allocator)
    if l.kind!=.User || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,user_rules(f),f.valid)
}

user_fold_destroy :: proc(f:^User_Fold) {
    delete(f.devices)
    delete(f.valid,f.devices.allocator)
    f^={}
}

@(private)
user_rules :: proc(f:^User_Fold) -> Rules {
    return {
        data=f,
        reset=proc(data:rawptr) {
            f:=(^User_Fold)(data)
            f.recovery={}
            clear(&f.devices)
            f.web_keys=0
        },
        authorized=proc(data:rawptr,e:int) -> bool {
            f:=(^User_Fold)(data)
            entry:=&f.log.items[e].entry
            if entry.type==.User_Genesis {
                b,_,_:=body_head(entry.body,User_Genesis_Body)
                return entry.author==b.recovery && device_proof_valid(b.device,transmute([32]u8)b.recovery,b.proof)
            }
            if f.recovery=={} {return false}
            by_recovery:=entry.author==f.recovery
            by_device:=user_device_active(f,entry.author)
            #partial switch entry.type {
            case .Device_Add:
                b,_,_:=body_head(entry.body,Device_Add_Body)
                return (by_recovery || by_device) && user_device_index(f,b.device)<0 && device_proof_valid(b.device,transmute([32]u8)f.log.id,b.proof)
            case .Device_Revoke:
                b,_,_:=body_head(entry.body,Device_Revoke_Body)
                return (by_recovery || by_device) && user_device_index(f,b.device)>=0
            case .Recovery_Rotate: return by_recovery
            case .Web_Key_Add: return by_recovery || by_device
            }
            return false
        },
        apply=proc(data:rawptr,e:int) {
            f:=(^User_Fold)(data)
            entry:=&f.log.items[e].entry
            #partial switch entry.type {
            case .User_Genesis:
                b,_,_:=body_head(entry.body,User_Genesis_Body)
                f.recovery=b.recovery
                append(&f.devices,Device{key=b.device,dh=b.dh,added=u32(e)})
            case .Device_Add:
                b,_,_:=body_head(entry.body,Device_Add_Body)
                if user_device_index(f,b.device)<0 {append(&f.devices,Device{key=b.device,dh=b.dh,added=u32(e)})}
            case .Device_Revoke:
                b,_,_:=body_head(entry.body,Device_Revoke_Body)
                for &d in f.devices {
                    if d.key==b.device && !d.revoked {d.revoked,d.revoke=true,u32(e)}
                }
            case .Recovery_Rotate:
                b,_,_:=body_head(entry.body,Recovery_Rotate_Body)
                f.recovery=b.recovery
            case .Web_Key_Add: f.web_keys+=1
            }
        },
        removal=proc(data:rawptr,r:int) -> bool {
            return (^User_Fold)(data).log.items[r].entry.type==.Device_Revoke
        },
        // A revoked device's entries in its own log count only inside the horizon the revocation names for it.
        voids=proc(data:rawptr,r,e:int) -> bool {
            f:=(^User_Fold)(data)
            b,_,_:=body_head(f.log.items[r].entry.body,Device_Revoke_Body)
            return f.log.items[e].entry.author==b.device && !horizon_holds(f.log,r,f.log,e)
        },
    }
}

// Where key is a device of the state, -1 when it is not one. A revoked
// device stays, so it cannot be added again.
@(private)
user_device_index :: proc(f:^User_Fold,key:Key) -> int {
    for d,i in f.devices {
        if d.key==key {return i}
    }
    return -1
}

// Whether entry e of log l lies inside the horizon the Device_Revoke r of
// user_log names for l: in the causal past of one of its heads for l, or, when
// it names none for l and l is user_log, in the causal past of r.
@(private)
horizon_holds :: proc(user_log:^Log,r:int,l:^Log,e:int) -> bool {
    b,tail,_:=body_head(user_log.items[r].entry.body,Device_Revoke_Body)
    reader:=Reader{data=tail}
    named:=false
    for _ in 0..<b.horizons {
        h:=read_value(&reader,Horizon)
        heads:=slice.reinterpret([]store.Hash,read_bytes(&reader,int(h.heads)*size_of(store.Hash)))
        if h.log_id!=l.id {continue}
        named=true
        for head in heads {
            if k:=log_find(l,head);k>=0 && log_within(l,e,k) {return true}
        }
    }
    if !named && user_log==l {return log_before(l,e,r)}
    return false
}

// Whether device of the user may have signed entry e of log l: it is one of
// the user's devices and, once revoked, e lies inside the horizon its
// revocation names for l. A revocation that names no horizon for l leaves
// none of the device's entries there.
user_device_allows :: proc(f:^User_Fold,device:Key,l:^Log,e:int) -> bool {
    k:=user_device_index(f,device)
    if k<0 {return false}
    d:=f.devices[k]
    return !d.revoked || horizon_holds(f.log,int(d.revoke),l,e)
}

// Whether device is a device of the user not revoked.
user_device_active :: proc(f:^User_Fold,device:Key) -> bool {
    k:=user_device_index(f,device)
    return k>=0 && !f.devices[k].revoked
}

// The user whose active device has the X25519 key dh.
user_dh_active :: proc(f:^User_Fold,dh:Dh_Key) -> bool {
    for d in f.devices {
        if d.dh==dh && !d.revoked {return true}
    }
    return false
}

// A body of Device_Revoke for device, with the heads of each log it leaves
// the device's entries in.
revoke_body :: proc(device:Key,horizons:[]Log_Horizon) -> []u8 {
    tail:=make([dynamic]u8,context.temp_allocator)
    for h in horizons {
        head:=Horizon{log_id=h.log_id,heads=u8(min(len(h.heads),ENTRY_PARENTS_MAX))}
        append(&tail,..mem.ptr_to_bytes(&head))
        for &x in h.heads[:head.heads] {append(&tail,..x[:])}
    }
    return body_make(Device_Revoke_Body{device=device,horizons=u8(len(horizons))},tail[:])
}

Log_Horizon :: struct {log_id:Log_Id,heads:[]store.Hash}

// --- Org_Log ---

Member :: struct {user:Log_Id,role:Role}
Org_Project :: struct {id:Log_Id,public:bool}
Org_Scope :: struct {project:Log_Id,scope:Scope_Id,readers:Role,history:bool,entry:u32}
Org_Policy :: struct {project:Log_Id,bookmark:string,approvals:int,entry:u32}
Org_Node :: struct {key:Key,dh:Dh_Key,modes:Node_Modes,entry:u32}

Org_Fold :: struct {
    log:^Log,
    users:[]^User_Fold, // the folds of the members' User_Logs this end has
    valid:[]bool,
    owner:Log_Id,
    members:[dynamic]Member,
    removed:[dynamic]Log_Id, // users a valid Member_Remove named
    projects:[dynamic]Org_Project,
    scopes:[dynamic]Org_Scope,
    policies:[dynamic]Org_Policy,
    grants:[dynamic]store.Hash,  // recorded in the log
    revoked:[dynamic]store.Hash, // grants revoked
    nodes:[dynamic]Org_Node,
}

org_fold :: proc(f:^Org_Fold,l:^Log,users:[]^User_Fold,allocator:=context.allocator) -> Error {
    f^={log=l,users=users}
    f.members=make([dynamic]Member,allocator)
    f.removed=make([dynamic]Log_Id,allocator)
    f.projects=make([dynamic]Org_Project,allocator)
    f.scopes=make([dynamic]Org_Scope,allocator)
    f.policies=make([dynamic]Org_Policy,allocator)
    f.grants=make([dynamic]store.Hash,allocator)
    f.revoked=make([dynamic]store.Hash,allocator)
    f.nodes=make([dynamic]Org_Node,allocator)
    if l.kind!=.Org || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,org_rules(f),f.valid)
}

org_fold_destroy :: proc(f:^Org_Fold) {
    allocator:=f.members.allocator
    delete(f.members)
    delete(f.removed)
    delete(f.projects)
    delete(f.scopes)
    delete(f.policies)
    delete(f.grants)
    delete(f.revoked)
    delete(f.nodes)
    delete(f.valid,allocator)
    f^={}
}

// The role of user in the state; None when not a member.
org_role :: proc(f:^Org_Fold,user:Log_Id) -> Role {
    for m in f.members {
        if m.user==user {return m.role}
    }
    return .None
}

// The user of the folds whose device may have signed entry e of l.
@(private)
author_user :: proc(users:[]^User_Fold,device:Key,l:^Log,e:int) -> ^User_Fold {
    for u in users {
        if user_device_allows(u,device,l,e) {return u}
    }
    return nil
}

// The member an active device belongs to, and its role.
org_device_role :: proc(f:^Org_Fold,device:Key) -> (user:Log_Id,role:Role) {
    for u in f.users {
        if user_device_active(u,device) {
            if r:=org_role(f,u.log.id);r!=.None {return u.log.id,r}
        }
    }
    return {},.None
}

// The node of the org with the Ed25519 key, -1 when there is none.
org_node :: proc(f:^Org_Fold,key:Key) -> int {
    for n,i in f.nodes {
        if n.key==key {return i}
    }
    return -1
}

@(private)
org_project_index :: proc(f:^Org_Fold,id:Log_Id) -> int {
    for p,i in f.projects {
        if p.id==id {return i}
    }
    return -1
}

@(private)
org_subject :: proc(f:^Org_Fold,e:int) -> (subject:store.Hash,has:bool) {
    entry:=&f.log.items[e].entry
    #partial switch entry.type {
    case .Member_Add,.Role_Set:
        b,_,_:=body_head(entry.body,Member_Body)
        return b.user,true
    case .Member_Remove,.Owner_Transfer,.Grant_Revoke:
        b,_,_:=body_head(entry.body,Subject_Body)
        return b.subject,true
    case .Scope_Add:
        b,_,_:=body_head(entry.body,Scope_Add_Body)
        return scope_subject(b.project,b.scope),true
    case .Scope_Remove:
        b,_,_:=body_head(entry.body,Scope_Remove_Body)
        return scope_subject(b.project,b.scope),true
    case .Node_Add:
        b,_,_:=body_head(entry.body,Node_Add_Body)
        return store.Hash(b.node),true
    case .Node_Remove:
        b,_,_:=body_head(entry.body,Node_Remove_Body)
        return store.Hash(b.node),true
    case .Grant:
        return store.address_of_bytes(entry.body),true
    }
    return {},false
}

@(private)
scope_subject :: proc(project:Log_Id,scope:Scope_Id) -> store.Hash {
    bytes:[48]u8
    p,s:=project,scope
    copy(bytes[:],p[:])
    copy(bytes[32:],s[:])
    return store.address_of_bytes(bytes[:])
}

@(private)
org_rules :: proc(f:^Org_Fold) -> Rules {
    return {
        data=f,
        reset=proc(data:rawptr) {
            f:=(^Org_Fold)(data)
            f.owner={}
            clear(&f.members)
            clear(&f.removed)
            clear(&f.projects)
            clear(&f.scopes)
            clear(&f.policies)
            clear(&f.grants)
            clear(&f.revoked)
            clear(&f.nodes)
        },
        authorized=proc(data:rawptr,e:int) -> bool {
            f:=(^Org_Fold)(data)
            entry:=&f.log.items[e].entry
            u:=author_user(f.users,entry.author,f.log,e)
            if u==nil {return false}
            if entry.type==.Org_Genesis {
                b,_,_:=body_head(entry.body,Org_Genesis_Body)
                return u.log.id==b.owner
            }
            role:=org_role(f,u.log.id)
            if role==.None {return false}
            #partial switch entry.type {
            case .Member_Add:
                b,_,_:=body_head(entry.body,Member_Body)
                return role>=.Admin && b.role<=role && org_role(f,b.user)==.None
            case .Member_Remove:
                b,_,_:=body_head(entry.body,Subject_Body)
                target:=org_role(f,b.subject)
                return target!=.None && target!=.Owner && (role>=.Admin || b.subject==u.log.id)
            case .Role_Set:
                b,_,_:=body_head(entry.body,Member_Body)
                target:=org_role(f,b.user)
                return role>=.Admin && target!=.None && target!=.Owner && b.role<=role
            case .Owner_Transfer:
                b,_,_:=body_head(entry.body,Subject_Body)
                return role==.Owner && org_role(f,b.subject)!=.None && b.subject!=u.log.id
            case .Project_Add:
                b,_,_:=body_head(entry.body,Project_Add_Body)
                return role>=.Admin && org_project_index(f,b.project)<0
            case .Scope_Add:
                b,_,_:=body_head(entry.body,Scope_Add_Body)
                if role<.Admin || org_project_index(f,b.project)<0 {return false}
                for s in f.scopes {
                    if s.project==b.project && s.scope==b.scope {return false}
                }
                return true
            case .Scope_Remove:
                b,_,_:=body_head(entry.body,Scope_Remove_Body)
                if role<.Admin {return false}
                for s in f.scopes {
                    if s.project==b.project && s.scope==b.scope {return true}
                }
                return false
            case .Policy_Set:
                b,_,_:=body_head(entry.body,Policy_Set_Body)
                return role>=.Admin && org_project_index(f,b.project)>=0
            case .Grant:
                g,_:=grant_decode(entry.body)
                return role>=.Admin && g.issuer==entry.author && g.org==f.log.id
            case .Grant_Revoke: return role>=.Admin
            case .Node_Add:
                b,_,_:=body_head(entry.body,Node_Add_Body)
                return role>=.Admin && org_node(f,b.node)<0
            case .Node_Remove:
                b,_,_:=body_head(entry.body,Node_Remove_Body)
                return role>=.Admin && org_node(f,b.node)>=0
            }
            return false
        },
        apply=proc(data:rawptr,e:int) {
            f:=(^Org_Fold)(data)
            entry:=&f.log.items[e].entry
            #partial switch entry.type {
            case .Org_Genesis:
                b,_,_:=body_head(entry.body,Org_Genesis_Body)
                f.owner=b.owner
                append(&f.members,Member{b.owner,.Owner})
            case .Member_Add:
                b,_,_:=body_head(entry.body,Member_Body)
                if org_role(f,b.user)==.None {append(&f.members,Member{b.user,b.role})}
            case .Member_Remove:
                b,_,_:=body_head(entry.body,Subject_Body)
                if !slice.contains(f.removed[:],b.subject) {append(&f.removed,b.subject)}
                for m,i in f.members {
                    if m.user==b.subject && m.role!=.Owner {
                        ordered_remove(&f.members,i)
                        break
                    }
                }
            case .Role_Set:
                b,_,_:=body_head(entry.body,Member_Body)
                for &m in f.members {
                    if m.user==b.user && m.role!=.Owner {m.role=b.role}
                }
            case .Owner_Transfer:
                b,_,_:=body_head(entry.body,Subject_Body)
                if org_role(f,b.subject)==.None {break}
                for &m in f.members {
                    if m.role==.Owner {m.role=.Admin}
                    if m.user==b.subject {m.role=.Owner}
                }
                f.owner=b.subject
            case .Project_Add:
                b,_,_:=body_head(entry.body,Project_Add_Body)
                if org_project_index(f,b.project)<0 {append(&f.projects,Org_Project{b.project,bool(b.public)})}
            case .Scope_Add:
                b,_,_:=body_head(entry.body,Scope_Add_Body)
                append(&f.scopes,Org_Scope{b.project,b.scope,b.readers,bool(b.history),u32(e)})
            case .Scope_Remove:
                b,_,_:=body_head(entry.body,Scope_Remove_Body)
                for s,i in f.scopes {
                    if s.project==b.project && s.scope==b.scope {
                        ordered_remove(&f.scopes,i)
                        break
                    }
                }
            case .Policy_Set:
                b,tail,_:=body_head(entry.body,Policy_Set_Body)
                r:=Reader{data=tail}
                bookmark:=tail_string(&r)
                for p,i in f.policies {
                    if p.project==b.project && p.bookmark==bookmark {
                        ordered_remove(&f.policies,i)
                        break
                    }
                }
                append(&f.policies,Org_Policy{b.project,bookmark,int(b.approvals),u32(e)})
            case .Grant: append(&f.grants,store.address_of_bytes(entry.body))
            case .Grant_Revoke:
                b,_,_:=body_head(entry.body,Subject_Body)
                append(&f.revoked,b.subject)
            case .Node_Add:
                b,_,_:=body_head(entry.body,Node_Add_Body)
                if org_node(f,b.node)<0 {append(&f.nodes,Org_Node{b.node,b.dh,b.modes,u32(e)})}
            case .Node_Remove:
                b,_,_:=body_head(entry.body,Node_Remove_Body)
                if k:=org_node(f,b.node);k>=0 {ordered_remove(&f.nodes,k)}
            }
        },
        removal=proc(data:rawptr,r:int) -> bool {
            #partial switch (^Org_Fold)(data).log.items[r].entry.type {
            case .Member_Remove,.Scope_Remove,.Grant_Revoke,.Node_Remove: return true
            }
            return false
        },
        // A removal wins over whatever was written concurrently about its
        // subject, and over what a removed member signed concurrently.
        voids=proc(data:rawptr,r,e:int) -> bool {
            f:=(^Org_Fold)(data)
            if !log_concurrent(f.log,r,e) {return false}
            subject,_:=org_subject(f,r)
            if s,has:=org_subject(f,e);has && s==subject {return true}
            if f.log.items[r].entry.type==.Member_Remove {
                for u in f.users {
                    if u.log.id==subject {return user_device_allows(u,f.log.items[e].entry.author,f.log,e)}
                }
            }
            return false
        },
    }
}

// The role of user in the state of the causal past of the org's entry head,
// and head itself; the fold is left as it was.
org_role_at :: proc(f:^Org_Fold,user:Log_Id,head:int) -> Role {
    rules:=org_rules(f)
    fold_at(f.log,rules,f.valid,head)
    role:=org_role(f,user)
    fold_all(f.log,rules,f.valid)
    return role
}

// The rights of a role.
role_rights :: proc "contextless" (role:Role) -> Rights {
    switch role {
    case .None: return {}
    case .Reader: return {.Read}
    case .Writer: return {.Read,.Write,.DDC,.Check}
    case .Admin,.Owner: return {.Read,.Write,.DDC,.Check,.Relay}
    }
    return {}
}

// --- Grants: rights an admin gives a key outside the org, for a while ---

RIGHTS_ALL :: Rights{.Read,.Write,.DDC,.Check,.Relay}
GRANT_NANOSECONDS_MAX :: i64(30*24*3600)*1_000_000_000
GRANT_PATH_MAX :: 1024

Grant_Head :: struct #packed {
    magic:u32,
    version:u16,
    rights:Rights,
    reserved:u8,
    org:Log_Id,
    org_head:store.Hash, // an entry of the org's log the issuer was an admin at
    issuer:Key,          // a device of an admin
    subject_dh:Dh_Key,   // what the holder connects with
    subject_key:Key,     // what the holder signs with: zero when it signs nothing
    project:Log_Id,
    not_before:i64,      // ns
    not_after:i64,       // ns, at most GRANT_NANOSECONDS_MAX after not_before
    path_len:u16,
    reserved2:[6]u8,
} // + path scope, Signature

Grant :: struct {
    using head:Grant_Head,
    path:string,
    signature:Signature,
}

grant_encode :: proc(g:^Grant,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(g.path)>GRANT_PATH_MAX {return nil,.Too_Large}
    if g.issuer!=identity.key || g.org=={} || g.org_head=={} || g.not_after<=g.not_before || !utf8.valid_string(g.path) {return nil,.Invalid_Argument}
    head:=g.head
    head.magic,head.version,head.reserved,head.reserved2,head.path_len=KAI_MAGIC,VERSION,0,{},u16(len(g.path))
    w:=writer_make(allocator)
    write_value(&w,head)
    write_string(&w,g.path)
    if w.failed {return nil,.Out_Of_Memory}
    g.signature=sign(identity,w.data[:])
    write_bytes(&w,g.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

grant_decode :: proc(bytes:[]u8) -> (g:Grant,error:Error) {
    r:=Reader{data=bytes}
    g.head=read_value(&r,Grant_Head)
    if r.short || g.magic!=KAI_MAGIC || g.version!=VERSION || g.reserved!=0 || !zero(g.reserved2[:]) || g.path_len>GRANT_PATH_MAX {return {},.Corrupt}
    if transmute(u8)g.rights&~transmute(u8)RIGHTS_ALL!=0 || g.org=={} || g.org_head=={} || g.not_after<=g.not_before {return {},.Corrupt}
    g.path=string(read_bytes(&r,int(g.path_len)))
    g.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) || !utf8.valid_string(g.path) {return {},.Corrupt}
    return g,.None
}

// Checks the grant of bytes against the org: signed by its issuer, an admin
// at org_head and still one, its rights within the issuer's, at most 30 days
// long, now inside it, and not revoked.
grant_verify :: proc(f:^Org_Fold,bytes:[]u8,now:i64) -> (g:Grant,error:Error) {
    g=grant_decode(bytes) or_return
    if !signature_valid(g.issuer,bytes[:len(bytes)-size_of(Signature)],g.signature) {return g,.Unauthorized}
    if g.org!=f.log.id {return g,.Unauthorized}
    if g.not_after-g.not_before>GRANT_NANOSECONDS_MAX {return g,.Unauthorized}
    if now<g.not_before || now>g.not_after {return g,.Expired}
    address:=store.address_of_bytes(bytes)
    for r in f.revoked {
        if r==address {return g,.Unauthorized}
    }
    head:=log_find(f.log,g.org_head)
    if head<0 || !f.valid[head] {return g,.Unauthorized}
    user,role:=org_device_role(f,g.issuer)
    if role<.Admin {return g,.Unauthorized}
    at:=org_role_at(f,user,head)
    if at<.Admin || g.rights&~role_rights(at<role?at:role)!={} {return g,.Unauthorized}
    return g,.None
}

// --- Project_Log ---

Bookmark_Target :: struct {name:string,target:Revision}

Project_Fold :: struct {
    log:^Log,
    org:^Org_Fold,
    proposals:[]^Proposal_Fold, // what a move a policy guards names
    valid:[]bool,
    org_id:Log_Id,
    public:bool,
    bookmarks:[dynamic]Bookmark_Target, // sorted by name then target: a name with several targets is diverged
}

project_fold :: proc(f:^Project_Fold,l:^Log,org:^Org_Fold,proposals:[]^Proposal_Fold={},allocator:=context.allocator) -> Error {
    f^={log=l,org=org,proposals=proposals}
    f.bookmarks=make([dynamic]Bookmark_Target,allocator)
    if l.kind!=.Project || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,project_rules(f),f.valid)
}

project_fold_destroy :: proc(f:^Project_Fold) {
    allocator:=f.bookmarks.allocator
    delete(f.bookmarks)
    delete(f.valid,allocator)
    f^={}
}

// The targets of bookmark: more than one when moves diverged.
project_bookmark :: proc(f:^Project_Fold,name:string,out:^[dynamic]Revision) {
    clear(out)
    for b in f.bookmarks {
        if b.name==name {append(out,b.target)}
    }
}

@(private)
project_rules :: proc(f:^Project_Fold) -> Rules {
    return {
        data=f,
        reset=proc(data:rawptr) {
            f:=(^Project_Fold)(data)
            clear(&f.bookmarks)
            f.org_id,f.public={},false
        },
        authorized=proc(data:rawptr,e:int) -> bool {
            f:=(^Project_Fold)(data)
            entry:=&f.log.items[e].entry
            u:=author_user(f.org.users,entry.author,f.log,e)
            if u==nil {return false}
            role:=org_role(f.org,u.log.id)
            if entry.type==.Project_Genesis {
                b,_,_:=body_head(entry.body,Project_Genesis_Body)
                return b.org==f.org.log.id && role>=.Admin
            }
            if entry.type!=.Bookmark_Move || f.org_id=={} || role<.Writer {return false}
            b,tail,_:=body_head(entry.body,Bookmark_Move_Body)
            name:=string(tail[int(b.from)*size_of(Revision):])
            for &p in f.org.policies {
                if p.project!=f.log.id || p.bookmark!=name || p.approvals==0 {continue}
                return policy_holds(f,&p,b.to,b.proposal)
            }
            return true
        },
        apply=proc(data:rawptr,e:int) {
            f:=(^Project_Fold)(data)
            entry:=&f.log.items[e].entry
            if entry.type==.Project_Genesis {
                b,_,_:=body_head(entry.body,Project_Genesis_Body)
                f.org_id,f.public=b.org,bool(b.public)
                return
            }
            b,tail,_:=body_head(entry.body,Bookmark_Move_Body)
            from:=slice.reinterpret([]Revision,tail[:int(b.from)*size_of(Revision)])
            name:=string(tail[len(from)*size_of(Revision):])
            for k:=len(f.bookmarks)-1;k>=0;k-=1 {
                if f.bookmarks[k].name==name && slice.contains(from,f.bookmarks[k].target) {ordered_remove(&f.bookmarks,k)}
            }
            for t in f.bookmarks {
                if t.name==name && t.target==b.to {return}
            }
            append(&f.bookmarks,Bookmark_Target{name,b.to})
            slice.sort_by(f.bookmarks[:],proc(a,b:Bookmark_Target) -> bool {
                if a.name!=b.name {return a.name<b.name}
                return hash_less(a.target,b.target)
            })
        },
        removal=proc(data:rawptr,r:int) -> bool {return false},
        voids=proc(data:rawptr,r,e:int) -> bool {return false},
    }
}

// Whether a move to revision under proposal meets the policy: the proposal is
// one this end folded, open on this project, at revision, with the approvals
// and passing checks the policy asks.
@(private)
policy_holds :: proc(f:^Project_Fold,p:^Org_Policy,revision:Revision,proposal:store.Hash) -> bool {
    if proposal=={} {return false}
    for pf in f.proposals {
        if pf.log.id!=proposal || pf.project!=f.log.id || pf.status!=.Open || pf.revision!=revision {continue}
        if pf.approvals<p.approvals {return false}
        _,tail,_:=body_head(f.org.log.items[p.entry].entry.body,Policy_Set_Body)
        r:=Reader{data=tail}
        tail_string(&r)
        b,_,_:=body_head(f.org.log.items[p.entry].entry.body,Policy_Set_Body)
        for _ in 0..<b.checks {
            name:=tail_string(&r)
            passed:=false
            for c in pf.checks {
                if c.name==name && c.state==.Passed {passed=true}
            }
            if !passed {return false}
        }
        return true
    }
    return false
}

// --- Proposal_Log (reviews; their web signatures and re-anchoring come in M5) ---

Proposal_Status :: enum u8 {Open,Closed,Landed}
Proposal_Check :: struct {name:string,state:Check_State}
Proposal_Approval :: struct {user:Log_Id,revision:Revision,verdict:Verdict_Kind}

Proposal_Fold :: struct {
    log:^Log,
    org:^Org_Fold,
    valid:[]bool,
    project:Log_Id,
    opener:Log_Id,
    status:Proposal_Status,
    revision:Revision, // the head of the stack last revised
    verdicts:[dynamic]Proposal_Approval, // the last of each user
    approvals:int,                       // of revision
    checks:[dynamic]Proposal_Check,      // of revision, the last of each name
    comments:int,
}

proposal_fold :: proc(f:^Proposal_Fold,l:^Log,org:^Org_Fold,allocator:=context.allocator) -> Error {
    f^={log=l,org=org}
    f.verdicts=make([dynamic]Proposal_Approval,allocator)
    f.checks=make([dynamic]Proposal_Check,allocator)
    if l.kind!=.Proposal || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    fold_run(l,proposal_rules(f),f.valid) or_return
    proposal_count(f)
    return .None
}

proposal_fold_destroy :: proc(f:^Proposal_Fold) {
    allocator:=f.verdicts.allocator
    delete(f.verdicts)
    delete(f.checks)
    delete(f.valid,allocator)
    f^={}
}

@(private)
proposal_count :: proc(f:^Proposal_Fold) {
    f.approvals=0
    for v in f.verdicts {
        if v.verdict==.Approve && v.revision==f.revision {f.approvals+=1}
    }
}

@(private)
proposal_rules :: proc(f:^Proposal_Fold) -> Rules {
    return {
        data=f,
        reset=proc(data:rawptr) {
            f:=(^Proposal_Fold)(data)
            f.project,f.opener,f.status,f.revision,f.approvals,f.comments={},{},.Open,{},0,0
            clear(&f.verdicts)
            clear(&f.checks)
        },
        authorized=proc(data:rawptr,e:int) -> bool {
            f:=(^Proposal_Fold)(data)
            entry:=&f.log.items[e].entry
            u:=author_user(f.org.users,entry.author,f.log,e)
            if u==nil {return false}
            role:=org_role(f.org,u.log.id)
            if role==.None {return false}
            #partial switch entry.type {
            case .Proposal_Open:
                b,_,_:=body_head(entry.body,Proposal_Open_Body)
                return role>=.Writer && org_project_index(f.org,b.project)>=0
            case .Proposal_Revise: return f.status==.Open && (u.log.id==f.opener || role>=.Writer)
            case .Proposal_Comment: return true
            case .Proposal_Verdict,.Proposal_Check: return f.status==.Open && role>=.Writer
            case .Proposal_Land: return f.status==.Open && role>=.Writer && f.revision!={}
            case .Proposal_Close: return f.status==.Open && (u.log.id==f.opener || role>=.Admin)
            case .Proposal_Reopen: return f.status==.Closed && (u.log.id==f.opener || role>=.Admin)
            }
            return false
        },
        apply=proc(data:rawptr,e:int) {
            f:=(^Proposal_Fold)(data)
            entry:=&f.log.items[e].entry
            u:=author_user(f.org.users,entry.author,f.log,e)
            user:=u!=nil?u.log.id:{}
            #partial switch entry.type {
            case .Proposal_Open:
                b,_,_:=body_head(entry.body,Proposal_Open_Body)
                f.project,f.opener,f.status=b.project,user,.Open
            case .Proposal_Revise:
                b,tail,_:=body_head(entry.body,Proposal_Revise_Body)
                stack:=slice.reinterpret([]Stack_Item,tail)
                f.revision=stack[b.count-1].revision
                clear(&f.checks)
            case .Proposal_Comment: f.comments+=1
            case .Proposal_Verdict:
                b,_,_:=body_head(entry.body,Proposal_Verdict_Body)
                for v,i in f.verdicts {
                    if v.user==user {
                        ordered_remove(&f.verdicts,i)
                        break
                    }
                }
                append(&f.verdicts,Proposal_Approval{user,b.revision,b.verdict})
            case .Proposal_Check:
                b,tail,_:=body_head(entry.body,Proposal_Check_Body)
                if b.revision!=f.revision {break}
                for &c in f.checks {
                    if c.name==string(tail) {
                        c.state=b.state
                        return
                    }
                }
                append(&f.checks,Proposal_Check{string(tail),b.state})
            case .Proposal_Land: f.status=.Landed
            case .Proposal_Close: f.status=.Closed
            case .Proposal_Reopen: f.status=.Open
            }
            proposal_count(f)
        },
        removal=proc(data:rawptr,r:int) -> bool {return false},
        voids=proc(data:rawptr,r,e:int) -> bool {return false},
    }
}

// --- Keyring_Log (the epochs of a scope's key; sealing comes in M4) ---

Keyring_Envelope :: struct {epoch:u32,envelope:Envelope}

Keyring_Fold :: struct {
    log:^Log,
    org:^Org_Fold,
    valid:[]bool,
    project:Log_Id,
    scope:Scope_Id,
    epoch:u32, // the newest; 0 before the first
    envelopes:[dynamic]Keyring_Envelope,
}

keyring_fold :: proc(f:^Keyring_Fold,l:^Log,org:^Org_Fold,allocator:=context.allocator) -> Error {
    f^={log=l,org=org}
    f.envelopes=make([dynamic]Keyring_Envelope,allocator)
    if l.kind!=.Keyring || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,keyring_rules(f),f.valid)
}

keyring_fold_destroy :: proc(f:^Keyring_Fold) {
    allocator:=f.envelopes.allocator
    delete(f.envelopes)
    delete(f.valid,allocator)
    f^={}
}

// The key of epoch wrapped for the device dh.
keyring_envelope :: proc(f:^Keyring_Fold,epoch:u32,dh:Dh_Key) -> (envelope:Envelope,found:bool) {
    for k in f.envelopes {
        if k.epoch==epoch && k.envelope.dh==dh {return k.envelope,true}
    }
    return
}

@(private)
keyring_rules :: proc(f:^Keyring_Fold) -> Rules {
    return {
        data=f,
        reset=proc(data:rawptr) {
            f:=(^Keyring_Fold)(data)
            f.project,f.scope,f.epoch={},{},0
            clear(&f.envelopes)
        },
        authorized=proc(data:rawptr,e:int) -> bool {
            f:=(^Keyring_Fold)(data)
            entry:=&f.log.items[e].entry
            u:=author_user(f.org.users,entry.author,f.log,e)
            if u==nil || org_role(f.org,u.log.id)<.Writer {return false}
            #partial switch entry.type {
            case .Keyring_Genesis:
                b,_,_:=body_head(entry.body,Keyring_Genesis_Body)
                return b.org==f.org.log.id && org_project_index(f.org,b.project)>=0
            case .Epoch_Add:
                b,_,_:=body_head(entry.body,Epoch_Add_Body)
                return b.epoch==f.epoch+1
            case .Envelope_Add:
                b,_,_:=body_head(entry.body,Envelope_Add_Body)
                _,found:=keyring_envelope(f,b.epoch,b.envelope.dh)
                return b.epoch>=1 && b.epoch<=f.epoch && !found
            }
            return false
        },
        apply=proc(data:rawptr,e:int) {
            f:=(^Keyring_Fold)(data)
            entry:=&f.log.items[e].entry
            #partial switch entry.type {
            case .Keyring_Genesis:
                b,_,_:=body_head(entry.body,Keyring_Genesis_Body)
                f.project,f.scope=b.project,b.scope
            case .Epoch_Add:
                b,tail,_:=body_head(entry.body,Epoch_Add_Body)
                f.epoch=max(f.epoch,b.epoch)
                for envelope in slice.reinterpret([]Envelope,tail) {append(&f.envelopes,Keyring_Envelope{b.epoch,envelope})}
            case .Envelope_Add:
                b,_,_:=body_head(entry.body,Envelope_Add_Body)
                append(&f.envelopes,Keyring_Envelope{b.epoch,b.envelope})
            }
        },
        // Concurrent epochs of the same number: the first in order wins, the other is not authorized.
        removal=proc(data:rawptr,r:int) -> bool {return false},
        voids=proc(data:rawptr,r,e:int) -> bool {return false},
    }
}
