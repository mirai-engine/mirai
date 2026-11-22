package kai

import "base:runtime"
import "core:crypto/mlkem"
import "core:mem"
import "core:slice"
import "core:unicode/utf8"
import "mirai:std/blake3"
import "mirai:store"

// The signed logs of governance and review: User_Log, Org_Log, Project_Log,
// Proposal_Log and Keyring_Log share one entry format, one DAG and one fold.
// An entry names up to ENTRY_PARENTS_MAX parents by address (the BLAKE3 of its
// bytes); a log's id is the address of its genesis, the one entry without
// parents and with a zero log_id. Every peer folds the same entries to the same
// state: one walk of a topological order whose ties go by address. In a User
// or Org log an entry counts only if its author held the right in the state of
// its causal past there; a removal voids what its subject wrote concurrently,
// and the removal itself is never voided, so two admins removing each other
// remove both. An entry of a Project, Proposal or Keyring log names the entry
// of the org's log it was signed under (org_ctx), and its author's rights are
// those it held there. What removes or lowers a right in another log (a
// Device_Revoke in a User_Log; a Member_Remove, a lowering Role_Set or a
// Grant_Revoke in the Org_Log) reaches each log it concerns as a Witness entry
// of that log, written by a key that holds a right there when it first sees
// the removal: there, an entry by the key the removal affects holds only in
// the causal past of a valid witness of it; with no witness yet, the removal
// has not reached the log and its entries stand. So a removal stops what comes
// after it, backdated or not, and keeps what came before, with no clock and no
// server. An entry's time is never before its causal past (Log.time).
//
// A log is kept as its entries in pages of a trie by address, under an index
// object with its heads; the ref kai-log/<log id hex>, or kai-user/<log id
// hex> for a User_Log, names the index. Signatures are checked when entries
// come from a peer (log_merge), never on a local read.

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
    Public_Add,
    Passkey_Genesis,Witness,
}

Sig_Kind :: enum u8 {Ed25519,WebAuthn} // WebAuthn: the assertion of a browser's passkey (webauthn.odin)


Entry_Head :: struct #packed {
    magic:u32,
    version:u16,           // VERSIONS[.Log_Page]
    kind:Entry_Type,
    parents:u8,            // <= ENTRY_PARENTS_MAX; a genesis has none
    log_id:Log_Id,         // zero in a genesis
    author:Key,            // a device, the recovery key or a web key (web_key_id)
    author_ctx:store.Hash, // the head of the author's User_Log when it signed; a web key's entry counts only if its key was added in its causal past
    org_ctx:store.Hash,    // in a Project, Proposal or Keyring log, the entry of the org's log its author's rights are judged at; zero in a User or Org log
    time:i64,              // ns, as the signer's clock says
    body_len:u32,
    sig_kind:Sig_Kind,
    reserved:[3]u8,
} // + [parents]store.Hash sorted, body, then Signature or u16 length + WebAuthn assertion

ENTRY_PARENTS_MAX :: 8
ENTRY_BODY_MAX :: 64<<10
ASSERTION_MAX :: 2048
LOG_ENTRIES_MAX :: 1<<20 // entries of one log; far above what a team writes in years
LOG_BLOCK_MAX :: 1<<20   // bytes of a block of a log's entries: the first is small, each next one twice the last
NAME_MAX :: 64           // bytes of the name of a user, device, org or project
PATTERNS_MAX :: 64
CHECKS_MAX :: 32
NODE_ADDRESSES_MAX :: 8
ENVELOPES_MAX :: 1024   // devices an epoch's key is wrapped for
STACK_MAX :: 256
KEM :: mlkem.Parameters.ML_KEM_768
KEM_PUBLIC :: 1184      // a device's ML-KEM-768 encapsulation key
KEM_CIPHERTEXT :: 1088
KEM_SEED :: mlkem.DECAPSULATION_KEY_SEED_SIZE // (d, z): what a device keeps of its decapsulation key
LABEL_DEVICE :: "kai-1/device" // what a device signs, with the log it joins and its other keys, to prove it holds its key

Entry :: struct {
    type:Entry_Type,
    log_id:Log_Id,
    parents:[]store.Hash,
    author:Key,
    author_ctx:store.Hash,
    org_ctx:store.Hash,
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
User_Genesis_Body :: struct #packed {recovery:Key,device:Key,dh:Dh_Key,kem:[KEM_PUBLIC]u8,proof:Signature,device_name:[NAME_MAX]u8} // + name. proof: device_proof over the recovery key; device_name: the first device's, zero-padded
Passkey_Genesis_Body :: struct #packed {credential:u8,cose:u16,rp:u8}                  // + credential id, COSE key, relying party id, name; signed by that passkey
Device_Add_Body :: struct #packed {device:Key,dh:Dh_Key,kem:[KEM_PUBLIC]u8,proof:Signature} // + name. proof: device_proof over the log id
Device_Revoke_Body :: struct #packed {device:Key}                                      // a device or a web key
Recovery_Rotate_Body :: struct #packed {recovery:Key}
Web_Key_Add_Body :: struct #packed {credential:u8,cose:u16,rp:u8}                      // + credential id, COSE key, relying party id
Org_Genesis_Body :: struct #packed {owner:Log_Id}                                       // + name
Member_Body :: struct #packed {user:Log_Id,role:Role}                                   // Member_Add, Role_Set
Subject_Body :: struct #packed {subject:store.Hash}                                     // Member_Remove, Owner_Transfer (a user), Grant_Revoke (a grant)
Project_Add_Body :: struct #packed {project:Log_Id,public:b8}
Scope_Add_Body :: struct #packed {project:Log_Id,scope:Scope_Id,readers:Role,history:b8,patterns:u8} // + patterns × (u8 length, bytes)
Scope_Remove_Body :: struct #packed {project:Log_Id,scope:Scope_Id}
Policy_Set_Body :: struct #packed {project:Log_Id,approvals:u8,checks:u8,heads:u8}    // + [heads]store.Hash of the project's log, whose causal past keeps the rules before it; bookmark and checks, each u8 length and bytes
Node_Add_Body :: struct #packed {node:Key,dh:Dh_Key,modes:Node_Modes,addresses:u8}     // + [addresses]Node_Address
Node_Address :: struct #packed {kind:u8,port:u16,ip:[16]u8}                             // kind: 1 IPv4, 2 IPv6
Node_Remove_Body :: struct #packed {node:Key}
Project_Genesis_Body :: struct #packed {org:Log_Id,public:b8}                           // + name
Bookmark_Move_Body :: struct #packed {to:Revision,proposal:store.Hash,heads:u8,from:u8} // + [heads]store.Hash of the proposal's log it lands, [from]Revision, bookmark
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
Envelope :: struct #packed {dh:Dh_Key,share:[32]u8,kem:[KEM_CIPHERTEXT]u8,sealed:[32]u8,tag:[16]u8} // an epoch's key for the device dh: overlay.odin
Prev_Wrap :: struct #packed {nonce:[32]u8,sealed:[32]u8,tag:[16]u8}                      // the previous epoch's key under this one's
Epoch_Add_Body :: struct #packed {epoch:u32,devices:u16,history:b8,envelopes:store.Hash,previous:Prev_Wrap} // envelopes: an Envelopes object of [devices]Envelope sorted by dh; previous, when history
Envelope_Add_Body :: struct #packed {epoch:u32,envelope:Envelope}
// That a removal of the log named reached this log: the address of the
// Device_Revoke of a User_Log, or of the Member_Remove, Role_Set or
// Grant_Revoke of the Org_Log.
Witness_Body :: struct #packed {log:Log_Id,removal:store.Hash}
// A path of the project kept public though the deny set holds it, or, with a
// fingerprint, one leak the publish scanner found there waived.
Public_Add_Body :: struct #packed {project:Log_Id,fingerprint:store.Hash}                  // + path

entry_log_kind :: proc "contextless" (t:Entry_Type) -> (kind:Log_Kind,ok:bool) {
    switch t {
    case .None: return {},false
    case .User_Genesis,.Passkey_Genesis,.Device_Add,.Device_Revoke,.Recovery_Rotate,.Web_Key_Add: return .User,true
    case .Org_Genesis,.Member_Add,.Member_Remove,.Role_Set,.Owner_Transfer,.Project_Add,.Scope_Add,.Scope_Remove,.Policy_Set,.Grant,.Grant_Revoke,.Node_Add,.Node_Remove,.Public_Add: return .Org,true
    case .Project_Genesis,.Bookmark_Move: return .Project,true
    case .Proposal_Open,.Proposal_Revise,.Proposal_Comment,.Proposal_Verdict,.Proposal_Check,.Proposal_Land,.Proposal_Close,.Proposal_Reopen: return .Proposal,true
    case .Keyring_Genesis,.Epoch_Add,.Envelope_Add: return .Keyring,true
    case .Witness: return .Org,true // or a Project, Proposal or Keyring log: entry_fits
    }
    return {},false
}

// Whether an entry of type t belongs in a log of kind: a Witness in any but a
// User_Log, every other type in the one entry_log_kind says.
entry_fits :: proc "contextless" (t:Entry_Type,kind:Log_Kind) -> bool {
    if t==.Witness {return kind!=.User}
    k,ok:=entry_log_kind(t)
    return ok && k==kind
}

@(private)
genesis :: proc "contextless" (t:Entry_Type) -> bool {
    #partial switch t {
    case .User_Genesis,.Passkey_Genesis,.Org_Genesis,.Project_Genesis,.Proposal_Open,.Keyring_Genesis: return true
    }
    return false
}

// Whether entries of logs of kind name the org's entry they were signed under.
org_bound :: proc "contextless" (kind:Log_Kind) -> bool {return kind==.Project || kind==.Proposal || kind==.Keyring}

// What an entry says, before it is signed.
Draft :: struct {
    type:Entry_Type,
    log_id:Log_Id, // zero for a genesis
    parents:[]store.Hash,
    author_ctx:store.Hash,
    org_ctx:store.Hash, // in a Project, Proposal or Keyring log: an entry of the org's log (org_context)
    time:i64,
    body:[]u8,
}

// The bytes of d by author, what its signature covers.
@(private)
entry_unsigned :: proc(d:^Draft,author:Key,sig_kind:Sig_Kind,allocator:runtime.Allocator) -> (w:Writer,error:Error) {
    if len(d.parents)>ENTRY_PARENTS_MAX || len(d.body)>ENTRY_BODY_MAX {return {},.Too_Large}
    kind,known:=entry_log_kind(d.type)
    if !known || genesis(d.type)!=(len(d.parents)==0) || genesis(d.type)!=(d.log_id=={}) || (d.type!=.Witness && org_bound(kind)!=(d.org_ctx!={})) || !body_valid(d.type,d.body) {return {},.Invalid_Argument}
    parents,parents_error:=slice.clone(d.parents,context.temp_allocator)
    if parents_error!=nil {return {},.Out_Of_Memory}
    slice.sort_by(parents,hash_less)
    for p,i in parents {
        if p=={} || (i>0 && parents[i-1]==p) {return {},.Invalid_Argument}
    }
    w=writer_make(allocator)
    write_value(&w,Entry_Head{
        magic=KAI_MAGIC,version=VERSIONS[.Log_Page],kind=d.type,parents=u8(len(parents)),log_id=d.log_id,author=author,
        author_ctx=d.author_ctx,org_ctx=d.org_ctx,time=d.time,body_len=u32(len(d.body)),sig_kind=sig_kind,
    })
    for &p in parents {write_bytes(&w,p[:])}
    write_bytes(&w,d.body)
    if w.failed {
        delete(w.data)
        return {},.Out_Of_Memory
    }
    return w,.None
}

// The bytes of d signed by identity, and their address.
entry_sign :: proc(d:^Draft,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,address:store.Hash,error:Error) {
    w,unsigned:=entry_unsigned(d,identity.key,.Ed25519,allocator)
    if unsigned!=.None {return nil,{},unsigned}
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
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSIONS[.Log_Page] || !zero(head.reserved[:]) {return {},.Corrupt}
    kind,known:=entry_log_kind(head.kind)
    if !known || head.parents>ENTRY_PARENTS_MAX || head.body_len>ENTRY_BODY_MAX || head.sig_kind>max(Sig_Kind) {return {},.Corrupt}
    if genesis(head.kind)!=(head.parents==0) || genesis(head.kind)!=(head.log_id=={}) || (head.kind!=.Witness && org_bound(kind)!=(head.org_ctx!={})) {return {},.Corrupt}
    e.type,e.log_id,e.author,e.author_ctx,e.org_ctx,e.time,e.sig_kind=head.kind,head.log_id,head.author,head.author_ctx,head.org_ctx,head.time,head.sig_kind
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

// Whether the entry of bytes is signed by its author: by its Ed25519 key, or
// by the passkey its web key id names. Whose web key it is, the fold says.
entry_verify :: proc(bytes:[]u8,e:^Entry) -> bool {
    switch e.sig_kind {
    case .Ed25519: return signature_valid(e.author,bytes[:len(bytes)-size_of(Signature)],e.signature)
    case .WebAuthn: return entry_assertion_valid(bytes[:len(bytes)-size_of(u16)-len(e.assertion)],e)
    }
    return false
}

// The fixed part of a body and what follows it.
body_head :: proc "contextless" (body:[]u8,$T:typeid) -> (head:T,tail:[]u8,ok:bool) {
    if len(body)<size_of(T) {return}
    mem.copy_non_overlapping(&head,raw_data(body),size_of(T))
    return head,body[size_of(T):],true
}

// A Policy_Set's fixed part, the heads of the project's log it names, and a
// reader at its bookmark, which its checks follow.
policy_parts :: proc "contextless" (body:[]u8) -> (head:Policy_Set_Body,heads:[]store.Hash,r:Reader,ok:bool) {
    tail:[]u8
    head,tail,ok=body_head(body,Policy_Set_Body)
    if !ok || head.heads>ENTRY_PARENTS_MAX || len(tail)<int(head.heads)*size_of(store.Hash) {return {},nil,{},false}
    heads=slice.reinterpret([]store.Hash,tail[:int(head.heads)*size_of(store.Hash)])
    r=Reader{data=tail[len(heads)*size_of(store.Hash):]}
    return
}

// The next u8-length-prefixed string of a tail.
@(private)
tail_string :: proc "contextless" (r:^Reader) -> string {
    n:=read_value(r,u8)
    return string(read_bytes(r,int(n)))
}

// The name of device a user was made on, as its genesis gives it.
genesis_device_name :: proc(head:^User_Genesis_Body) -> string {
    n:=0
    for n<len(head.device_name) && head.device_name[n]!=0 {n+=1}
    return string(head.device_name[:n])
}

// The credential id, COSE key and relying party of a Web_Key_Add or a
// Passkey_Genesis, and what follows them: the name of a Passkey_Genesis.
passkey_parts :: proc(body:[]u8) -> (credential,cose:[]u8,rp_id:string,rest:[]u8,ok:bool) {
    head,tail,read:=body_head(body,Web_Key_Add_Body)
    size:=int(head.credential)+int(head.cose)+int(head.rp)
    if !read || head.credential==0 || head.cose==0 || head.rp==0 || len(tail)<size {return}
    credential=tail[:head.credential]
    cose=tail[head.credential:][:head.cose]
    rp_id=string(tail[int(head.credential)+int(head.cose):size])
    return credential,cose,rp_id,tail[size:],true
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
        head,tail,ok:=body_head(body,User_Genesis_Body)
        return ok && name_valid(string(tail)) && name_valid(genesis_device_name(&head),true) && kem_valid(head.kem[:])
    case .Passkey_Genesis:
        _,_,rp_id,name,ok:=passkey_parts(body)
        return ok && utf8.valid_string(rp_id) && name_valid(string(name))
    case .Device_Add:
        head,tail,ok:=body_head(body,Device_Add_Body)
        return ok && name_valid(string(tail)) && kem_valid(head.kem[:])
    case .Device_Revoke,.Recovery_Rotate,.Member_Remove,.Owner_Transfer,.Grant_Revoke,.Project_Add,.Scope_Remove,.Node_Remove,.Proposal_Verdict,.Proposal_Land,.Keyring_Genesis,.Envelope_Add,.Witness:
        size:=0
        #partial switch t {
        case .Device_Revoke: size=size_of(Device_Revoke_Body)
        case .Recovery_Rotate: size=size_of(Recovery_Rotate_Body)
        case .Member_Remove,.Owner_Transfer,.Grant_Revoke: size=size_of(Subject_Body)
        case .Witness: size=size_of(Witness_Body)
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
        _,_,_,rest,ok:=passkey_parts(body)
        return ok && len(rest)==0
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
        head,_,r,ok:=policy_parts(body)
        if !ok || head.checks>CHECKS_MAX {return false}
        if b:=tail_string(&r);len(b)==0 {return false}
        for _ in 0..<head.checks {
            if c:=tail_string(&r);len(c)==0 {return false}
        }
        return !r.short && r.at==len(r.data)
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
        pinned:=int(head.heads)*size_of(store.Hash)
        if !ok || head.to=={} || head.heads>ENTRY_PARENTS_MAX || (head.heads==0)!=(head.proposal=={}) || int(head.from)>CONFLICT_SIDES_MAX || len(tail)<=pinned+int(head.from)*size_of(Revision) {return false}
        name:=string(tail[pinned+int(head.from)*size_of(Revision):])
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
    case .Public_Add:
        _,tail,ok:=body_head(body,Public_Add_Body)
        return ok && path_valid(string(tail))
    case .Epoch_Add:
        head,tail,ok:=body_head(body,Epoch_Add_Body)
        return ok && len(tail)==0 && head.epoch>0 && head.devices>0 && head.devices<=ENVELOPES_MAX && head.envelopes!={} &&
            (head.history?head.epoch>1:head.previous==Prev_Wrap{})
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

// Whether kem is an ML-KEM-768 encapsulation key: its coefficients reduced.
kem_valid :: proc(kem:[]u8) -> bool {
    ek:mlkem.Encapsulation_Key
    defer mlkem.encapsulation_key_clear(&ek)
    return len(kem)==KEM_PUBLIC && mlkem.encapsulation_key_set_bytes(&ek,KEM,kem)
}

// What a device signs to prove it holds its key, for the log it joins (the
// recovery key of a genesis, the log id of a Device_Add), binding its X25519
// key and the BLAKE3 of its ML-KEM key to it: LABEL_DEVICE || joins || dh ||
// BLAKE3(kem). A pairing carries the hash before the key itself.
device_proof :: proc(device:^Identity,joins:[32]u8,dh:Dh_Key,kem_hash:[32]u8) -> Signature {
    message:=device_proof_message(joins,dh,kem_hash)
    return sign(device,message[:])
}

device_proof_valid :: proc(device:Key,joins:[32]u8,dh:Dh_Key,kem:[]u8,proof:Signature) -> bool {
    message:=device_proof_message(joins,dh,blake3.hash(kem))
    return signature_valid(device,message[:],proof)
}

@(private)
device_proof_message :: proc(joins:[32]u8,dh:Dh_Key,kem_hash:[32]u8) -> (message:[len(LABEL_DEVICE)+96]u8) {
    j,d,k:=joins,dh,kem_hash
    copy(message[:],LABEL_DEVICE)
    copy(message[len(LABEL_DEVICE):],j[:])
    copy(message[len(LABEL_DEVICE)+32:],d[:])
    copy(message[len(LABEL_DEVICE)+64:],k[:])
    return
}


// A move's parts: the heads of the proposal's log it lands, the targets it
// moves from, and the bookmark.
move_parts :: proc "contextless" (body:[]u8) -> (head:Bookmark_Move_Body,heads:[]store.Hash,from:[]Revision,name:string) {
    tail:[]u8
    head,tail,_=body_head(body,Bookmark_Move_Body)
    pinned:=int(head.heads)*size_of(store.Hash)
    heads=slice.reinterpret([]store.Hash,tail[:pinned])
    from=slice.reinterpret([]Revision,tail[pinned:][:int(head.from)*size_of(Revision)])
    name=string(tail[pinned+len(from)*size_of(Revision):])
    return
}

// A body of Bookmark_Move of bookmark from the targets from to to: by a
// landing, naming the proposal and the heads of its log it lands.
move_body :: proc(bookmark:string,from:[]Revision,to:Revision,proposal:store.Hash={},heads:[]store.Hash={}) -> []u8 {
    pinned,f:=heads,from
    return body_make(Bookmark_Move_Body{to=to,proposal=proposal,heads=u8(len(heads)),from=u8(len(from))},slice.to_bytes(pinned),slice.to_bytes(f),transmute([]u8)bookmark)
}

// One log's entries in memory, in the order they were added, their bytes in
// blocks that never move, with the DAG the index keeps and the pages of the
// trie the store keeps them in.
Log :: struct {
    id:Log_Id,
    kind:Log_Kind,
    known:bool,               // kind is the log's: from its entries or its index
    items:[dynamic]Log_Item,
    found:map[store.Hash]u32, // an item's index by its address
    blocks:[dynamic][]u8,
    block_used:int,           // bytes of the last block taken
    indexed:bool,
    order:[dynamic]u32,       // topological, ties by address
    rank:[dynamic]u32,        // the place of each item in order
    parent_first:[dynamic]u32,
    parent_list:[dynamic]u32,
    complete:[dynamic]bool,   // every ancestor is here
    time:[dynamic]i64,        // the latest time of the item and its causal past: an entry is never before what it builds on
    heads:[dynamic]u32,       // the complete items no complete item descends from, by address
    // Ancestry: the items are cut into chains, each a path of the DAG, and a
    // row gives, per chain, the last position of that chain in the causal
    // past of an item. An item that only extends its parent's chain shares
    // its parent's row; a merge or a fork makes one. So a linear log keeps one
    // row, and memory grows with merges times the log's width.
    chain:[dynamic]u32,
    pos:[dynamic]u32,         // from 1 in its chain
    row:[dynamic]u32,
    row_first:[dynamic]u32,
    rows:[dynamic]u32,
    chain_len:[dynamic]u32,
    pages:[dynamic]Log_Page,  // pages[0] is the root once there is an entry
    written:int,              // bytes the last log_save put
    // The valid Witness entries of the log, by the removal they name, as its
    // fold found them in a first walk; witnessing while that walk runs.
    witness_last:map[store.Hash]u32,
    witness_prev:[dynamic]u32,
    witnessing:bool,
    allocator:runtime.Allocator,
}

Log_Item :: struct {
    address:store.Hash,
    bytes:[]u8,  // in the log's blocks
    entry:Entry, // into bytes
}

// A page of the trie that keeps a log in the store. A page at depth d holds
// the entries whose addresses share its first d bytes: a leaf the entries
// themselves, a branch one page per next byte. A leaf of more than
// LOG_PAGE_ENTRIES entries is a branch, so the pages are a function of the
// set of entries alone: peers that hold the same entries make the same pages,
// and an append rewrites one leaf, the branches above it and the index.
Log_Page :: struct {
    address:store.Hash, // in the store, zero while dirty
    depth:u8,
    leaf:bool,
    count:u32,          // entries below
    items:[dynamic]u32, // a leaf's
    children:[]u32,     // a branch's 256 pages, +1
}

LOG_PAGE_ENTRIES :: 256

log_init :: proc(l:^Log,id:Log_Id={},allocator:=context.allocator) {
    l^={id=id,allocator=allocator}
    l.items=make([dynamic]Log_Item,allocator)
    l.found=make(map[store.Hash]u32,allocator)
    l.blocks=make([dynamic][]u8,allocator)
    l.order=make([dynamic]u32,allocator)
    l.rank=make([dynamic]u32,allocator)
    l.parent_first=make([dynamic]u32,allocator)
    l.parent_list=make([dynamic]u32,allocator)
    l.complete=make([dynamic]bool,allocator)
    l.time=make([dynamic]i64,allocator)
    l.heads=make([dynamic]u32,allocator)
    l.chain=make([dynamic]u32,allocator)
    l.pos=make([dynamic]u32,allocator)
    l.row=make([dynamic]u32,allocator)
    l.row_first=make([dynamic]u32,allocator)
    l.rows=make([dynamic]u32,allocator)
    l.chain_len=make([dynamic]u32,allocator)
    l.pages=make([dynamic]Log_Page,allocator)
    l.witness_last=make(map[store.Hash]u32,allocator)
    l.witness_prev=make([dynamic]u32,allocator)
}

log_destroy :: proc(l:^Log) {
    for b in l.blocks {delete(b,l.allocator)}
    for &p in l.pages {
        delete(p.items)
        delete(p.children,l.allocator)
    }
    delete(l.pages)
    delete(l.blocks)
    delete(l.items)
    delete(l.found)
    delete(l.order)
    delete(l.rank)
    delete(l.parent_first)
    delete(l.parent_list)
    delete(l.complete)
    delete(l.time)
    delete(l.heads)
    delete(l.chain)
    delete(l.pos)
    delete(l.row)
    delete(l.row_first)
    delete(l.rows)
    delete(l.chain_len)
    delete(l.witness_last)
    delete(l.witness_prev)
    l^={}
}

// The index of the entry at address, -1 when it is not here.
log_find :: proc(l:^Log,address:store.Hash) -> int {
    k,found:=l.found[address]
    return found?int(k):-1
}

// size bytes in the log's blocks, nil when memory ran out.
@(private)
log_bytes :: proc(l:^Log,size:int) -> []u8 {
    if len(l.blocks)==0 || l.block_used+size>len(l.blocks[len(l.blocks)-1]) {
        next:=len(l.blocks)==0?4096:min(2*len(l.blocks[len(l.blocks)-1]),LOG_BLOCK_MAX)
        block,e:=make([]u8,max(next,size),l.allocator)
        if e!=nil {return nil}
        if _,ae:=append(&l.blocks,block);ae!=nil {
            delete(block,l.allocator)
            return nil
        }
        l.block_used=0
    }
    out:=l.blocks[len(l.blocks)-1][l.block_used:][:size]
    l.block_used+=size
    return out
}

// Adds the entry of bytes, checking its signature when verify; added is false
// when it was here. An entry of another log is refused, and one past
// LOG_ENTRIES_MAX is Too_Large.
log_add :: proc(l:^Log,bytes:[]u8,verify:bool) -> (added:bool,error:Error) {
    e:=entry_decode(bytes) or_return
    address:=store.address_of_bytes(bytes)
    if genesis(e.type) {
        if l.id!={} && l.id!=address {return false,.Invalid_Argument}
    } else if l.id=={} || e.log_id!=l.id {
        return false,.Invalid_Argument
    }
    kind,_:=entry_log_kind(e.type)
    if e.type==.Witness {
        if !l.known || !entry_fits(e.type,l.kind) || org_bound(l.kind)!=(e.org_ctx!={}) {return false,.Invalid_Argument}
        kind=l.kind
    }
    if l.known && kind!=l.kind {return false,.Invalid_Argument}
    if address in l.found {return false,.None}
    if len(l.items)>=LOG_ENTRIES_MAX {return false,.Too_Large}
    if verify && !entry_verify(bytes,&e) {return false,.Unauthorized}
    own:=log_bytes(l,len(bytes))
    if own==nil {return false,.Out_Of_Memory}
    copy(own,bytes)
    e,_=entry_decode(own)
    if _,ae:=append(&l.items,Log_Item{address=address,bytes=own,entry=e});ae!=nil {return false,.Out_Of_Memory}
    i:=len(l.items)-1
    if _,me:=map_insert(&l.found,address,u32(i));me!=nil {
        pop(&l.items)
        return false,.Out_Of_Memory
    }
    if genesis(e.type) {l.id=address}
    l.kind,l.known=kind,true
    if page_insert(l,i)!=.None {
        delete_key(&l.found,address)
        pop(&l.items)
        return false,.Out_Of_Memory
    }
    log_extend(l,i)
    return true,.None
}

// Keeps the index of l when the new item i descends from every head, as an
// append does: it is then the last in any topological order. Anything else
// leaves the log to be indexed again.
@(private)
log_extend :: proc(l:^Log,i:int) {
    if !l.indexed {return}
    l.indexed=false
    entry:=&l.items[i].entry
    if len(l.items)!=len(l.order)+1 || len(entry.parents)==0 {return}
    parents:=make([dynamic]u32,0,len(entry.parents),context.temp_allocator)
    for p in entry.parents {
        k:=log_find(l,p)
        if k<0 {return}
        append(&parents,u32(k))
    }
    for h in l.heads {
        if !slice.contains(parents[:],h) {return}
    }
    grown:=0
    _,e1:=append(&l.parent_list,..parents[:])
    _,e2:=append(&l.parent_first,u32(len(l.parent_list)))
    if e1!=nil || e2!=nil {return}
    for x in ([?]^[dynamic]u32{&l.rank,&l.chain,&l.pos,&l.row}) {
        if _,e:=append(x,0);e==nil {grown+=1}
    }
    _,e3:=append(&l.complete,false)
    _,e4:=append(&l.time,0)
    if grown!=4 || e3!=nil || e4!=nil {return}
    clock:=make([dynamic]u32,context.temp_allocator)
    if log_place(l,i,false,&clock)!=.None {return}
    if l.complete[i] {
        clear(&l.heads)
        append(&l.heads,u32(i))
    }
    l.indexed=true
}

// Builds the parents, the topological order, the causal times, the heads
// and the ancestry of the log: O(n log n) for a log of n entries, and a row
// per merge or fork.
log_index :: proc(l:^Log) -> Error {
    if l.indexed {return .None}
    n:=len(l.items)
    if resize(&l.order,0)!=nil || resize(&l.rank,n)!=nil || resize(&l.parent_first,n+1)!=nil || resize(&l.complete,n)!=nil || resize(&l.time,n)!=nil {return .Out_Of_Memory}
    if resize(&l.chain,n)!=nil || resize(&l.pos,n)!=nil || resize(&l.row,n)!=nil || resize(&l.row_first,1)!=nil || resize(&l.rows,0)!=nil || resize(&l.chain_len,0)!=nil {return .Out_Of_Memory}
    l.row_first[0]=0
    clear(&l.parent_list)
    clear(&l.heads)
    if reserve(&l.parent_list,n)!=nil || reserve(&l.order,n)!=nil {return .Out_Of_Memory}
    missing,me:=make([]bool,n,context.temp_allocator)
    child_first,ce:=make([]u32,n+1,context.temp_allocator)
    if me!=nil || ce!=nil {return .Out_Of_Memory}
    for &item,i in l.items {
        l.parent_first[i]=u32(len(l.parent_list))
        for p in item.entry.parents {
            k:=log_find(l,p)
            if k<0 {
                missing[i]=true
                continue
            }
            if _,e:=append(&l.parent_list,u32(k));e!=nil {return .Out_Of_Memory}
            child_first[k+1]+=1
        }
    }
    l.parent_first[n]=u32(len(l.parent_list))
    for i in 0..<n {child_first[i+1]+=child_first[i]}
    child_list,le:=make([]u32,len(l.parent_list),context.temp_allocator)
    at,ae:=make([]u32,n,context.temp_allocator)
    waiting,we:=make([]u32,n,context.temp_allocator)
    if le!=nil || ae!=nil || we!=nil {return .Out_Of_Memory}
    for i in 0..<n {
        for p in log_parents(l,i) {
            child_list[child_first[p]+at[p]]=u32(i)
            at[p]+=1
            waiting[i]+=1
        }
    }
    // Kahn's walk taking the ready entry of the lowest address first, from a heap.
    heap:=make([dynamic]u32,0,n,context.temp_allocator)
    for i in 0..<n {
        if waiting[i]==0 {heap_push(&heap,l,u32(i))}
    }
    clock:=make([dynamic]u32,context.temp_allocator)
    for len(heap)>0 {
        i:=heap_pop(&heap,l)
        log_place(l,int(i),missing[i],&clock) or_return
        for c in child_list[child_first[i]:child_first[i+1]] {
            waiting[c]-=1
            if waiting[c]==0 {heap_push(&heap,l,c)}
        }
    }
    // What a cycle of hashes would leave: nothing a peer can make, refused all the same.
    if len(l.order)<n {
        placed,pe:=make([]bool,n,context.temp_allocator)
        if pe!=nil {return .Out_Of_Memory}
        for i in l.order {placed[i]=true}
        for i in 0..<n {
            if placed[i] {continue}
            l.rank[i]=u32(len(l.order))
            append(&l.order,u32(i))
            l.complete[i],l.time[i]=false,l.items[i].entry.time
            l.chain[i],l.pos[i],l.row[i]=u32(len(l.chain_len)),1,u32(len(l.row_first)-1)
            append(&l.chain_len,1)
            if _,e:=append(&l.row_first,u32(len(l.rows)));e!=nil {return .Out_Of_Memory}
        }
    }
    for i in 0..<n {
        if !l.complete[i] {continue}
        head:=true
        for c in child_list[child_first[i]:child_first[i+1]] {
            if l.complete[c] {
                head=false
                break
            }
        }
        if head {append(&l.heads,u32(i))}
    }
    context.user_ptr=l
    slice.sort_by(l.heads[:],proc(a,b:u32) -> bool {
        l:=(^Log)(context.user_ptr)
        return hash_less(l.items[a].address,l.items[b].address)
    })
    l.indexed=true
    return .None
}

// Places item i next in the order, with its completeness, causal time, chain
// and row.
@(private)
log_place :: proc(l:^Log,i:int,missing:bool,clock:^[dynamic]u32) -> Error {
    entry:=&l.items[i].entry
    parents:=log_parents(l,i)
    l.rank[i]=u32(len(l.order))
    if _,e:=append(&l.order,u32(i));e!=nil {return .Out_Of_Memory}
    complete:=!missing && (genesis(entry.type) || len(entry.parents)>0)
    time:=entry.time
    extend:=-1
    for p in parents {
        complete&=l.complete[p]
        time=max(time,l.time[p])
        if extend<0 && l.pos[p]==l.chain_len[l.chain[p]] {extend=int(p)}
    }
    l.complete[i],l.time[i]=complete,time
    if extend>=0 && len(parents)==1 {
        c:=l.chain[extend]
        l.chain_len[c]+=1
        l.chain[i],l.pos[i],l.row[i]=c,l.chain_len[c],l.row[extend]
        return .None
    }
    chains:=len(l.chain_len)
    if resize(clock,chains)!=nil {return .Out_Of_Memory}
    mem.zero_slice(clock[:])
    for p in parents {
        for c in 0..<chains {clock[c]=max(clock[c],log_reach(l,int(p),c))}
    }
    c:=-1
    if extend>=0 {
        c=int(l.chain[extend])
    } else {
        // A fork takes a chain whose last entry it descends from, else a new one.
        for k in 0..<chains {
            if l.chain_len[k]>0 && clock[k]==l.chain_len[k] {
                c=k
                break
            }
        }
    }
    if c<0 {
        c=chains
        if _,e:=append(&l.chain_len,0);e!=nil {return .Out_Of_Memory}
        if _,e:=append(clock,0);e!=nil {return .Out_Of_Memory}
    }
    l.chain_len[c]+=1
    clock[c]=l.chain_len[c]
    l.chain[i],l.pos[i],l.row[i]=u32(c),l.chain_len[c],u32(len(l.row_first)-1)
    if _,e:=append(&l.rows,..clock[:]);e!=nil {return .Out_Of_Memory}
    if _,e:=append(&l.row_first,u32(len(l.rows)));e!=nil {return .Out_Of_Memory}
    return .None
}

@(private)
heap_less :: #force_inline proc(l:^Log,a,b:u32) -> bool {return hash_less(l.items[a].address,l.items[b].address)}

@(private)
heap_push :: proc(heap:^[dynamic]u32,l:^Log,i:u32) {
    append(heap,i)
    k:=len(heap)-1
    for k>0 {
        up:=(k-1)/2
        if !heap_less(l,heap[k],heap[up]) {break}
        heap[k],heap[up]=heap[up],heap[k]
        k=up
    }
}

@(private)
heap_pop :: proc(heap:^[dynamic]u32,l:^Log) -> u32 {
    top:=heap[0]
    last:=pop(heap)
    if len(heap)==0 {return top}
    heap[0]=last
    k:=0
    for {
        a,b,least:=2*k+1,2*k+2,k
        if a<len(heap) && heap_less(l,heap[a],heap[least]) {least=a}
        if b<len(heap) && heap_less(l,heap[b],heap[least]) {least=b}
        if least==k {break}
        heap[k],heap[least]=heap[least],heap[k]
        k=least
    }
    return top
}

log_parents :: proc(l:^Log,i:int) -> []u32 {
    return l.parent_list[l.parent_first[i]:l.parent_first[i+1]]
}

// The last position of chain c in e and its causal past, 0 when none.
@(private)
log_reach :: #force_inline proc(l:^Log,e,c:int) -> u32 {
    if u32(c)==l.chain[e] {return l.pos[e]}
    first,last:=l.row_first[l.row[e]],l.row_first[l.row[e]+1]
    return first+u32(c)<last?l.rows[first+u32(c)]:0
}

// Whether a is a strict ancestor of e.
log_before :: #force_inline proc(l:^Log,a,e:int) -> bool {
    return a!=e && log_reach(l,e,int(l.chain[a]))>=l.pos[a]
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
    for h in l.heads {
        if _,e:=append(out,l.items[h].address);e!=nil {return .Out_Of_Memory}
    }
    return .None
}

// Appends an entry signed by identity to the log, its parents the heads, or
// parents when given: the entry's address. org_ctx is the org's entry it is
// signed under, for the entries of a Project, Proposal or Keyring log
// (org_context).
log_append :: proc(l:^Log,type:Entry_Type,body:[]u8,identity:^Identity,time:i64,author_ctx:=store.Hash{},org_ctx:=store.Hash{},parents:[]store.Hash=nil) -> (address:store.Hash,error:Error) {
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if parents!=nil {
        append(&heads,..parents)
    } else if !genesis(type) {
        log_heads(l,&heads) or_return
        if len(heads)==0 {return {},.Invalid_Argument}
        if len(heads)>ENTRY_PARENTS_MAX {resize(&heads,ENTRY_PARENTS_MAX)}
    }
    d:=Draft{type=type,log_id=genesis(type)?{}:l.id,parents=heads[:],author_ctx=author_ctx,org_ctx=org_ctx,time=time,body=body}
    bytes:[]u8
    bytes,address,error=entry_sign(&d,identity,context.temp_allocator)
    if error!=.None {return}
    _,error=log_add(l,bytes,false)
    return
}

// The valid witnesses of removal in l, then each before it: -1 at the end.
log_witness_first :: proc(l:^Log,removal:store.Hash) -> int {return int(l.witness_last[removal])-1}
log_witness_next :: proc(l:^Log,w:int) -> int {return int(l.witness_prev[w])-1}

// Whether entry e of l stands against the removal at address removal of
// another log: no valid witness of it is in l yet, or e is in the causal past
// of one.
log_witnessed :: proc(l:^Log,removal:store.Hash,e:int) -> bool {
    if l.witnessing {return true}
    w:=log_witness_first(l,removal)
    if w<0 {return true}
    for ;w>=0;w=log_witness_next(l,w) {
        if log_before(l,e,w) {return true}
    }
    return false
}

// --- Pages and the index in the store ---

LOG_NAMESPACE :: "kai-log"

// The object a log's ref names: its kind and id, how many entries it holds,
// its root page and its heads.
Log_Index_Head :: struct #packed {
    magic:u32,
    kind:Log_Kind,
    reserved:u8,
    count:u32,
    id:Log_Id,
    root:store.Hash,
    heads:u16,
    reserved2:[6]u8,
} // + [heads]store.Hash

Log_Page_Head :: struct #packed {
    magic:u32,
    depth:u8,    // the bytes of address every entry below shares with the page's path
    leaf:b8,
    count:u32,   // entries below
} // leaf: count × (u32 length, entry bytes) sorted by address; branch: [256]store.Hash, zero where none

LOG_HEADS_MAX :: 1<<12 // heads an index names; a log with more is folded from its pages alone

// The ref name of a log: the hex of its id.
log_name :: proc(id:Log_Id,buffer:^[64]u8) -> string {return store.hex(id,buffer)}

// Puts item i in the pages, from the root, which it makes for the first entry.
@(private)
page_insert :: proc(l:^Log,i:int) -> Error {
    if len(l.pages)==0 {
        if _,e:=append(&l.pages,Log_Page{leaf=true,items=make([dynamic]u32,l.allocator)});e!=nil {return .Out_Of_Memory}
    }
    return page_insert_at(l,0,i)
}

// Puts item i in the pages from page k down, splitting a leaf that grows past
// LOG_PAGE_ENTRIES.
@(private)
page_insert_at :: proc(l:^Log,k:int,i:int) -> Error {
    address:=l.items[i].address
    k:=k
    for {
        l.pages[k].address={}
        l.pages[k].count+=1
        if l.pages[k].leaf {
            if _,e:=append(&l.pages[k].items,u32(i));e!=nil {return .Out_Of_Memory}
            if len(l.pages[k].items)>LOG_PAGE_ENTRIES && l.pages[k].depth<31 {return page_split(l,k)}
            return .None
        }
        b:=address[l.pages[k].depth]
        if l.pages[k].children[b]==0 {
            child:=Log_Page{depth=l.pages[k].depth+1,leaf=true,items=make([dynamic]u32,l.allocator)}
            if _,e:=append(&l.pages,child);e!=nil {return .Out_Of_Memory}
            l.pages[k].children[b]=u32(len(l.pages))
        }
        k=int(l.pages[k].children[b])-1
    }
}

// Makes the leaf k a branch and puts its entries below it again.
@(private)
page_split :: proc(l:^Log,k:int) -> Error {
    children,e:=make([]u32,256,l.allocator)
    if e!=nil {return .Out_Of_Memory}
    items:=l.pages[k].items
    defer delete(items)
    l.pages[k].leaf,l.pages[k].items,l.pages[k].children,l.pages[k].count=false,{},children,0
    for i in items {page_insert_at(l,k,int(i)) or_return}
    return .None
}

// Puts the pages below k this store lacks, then k: its address. A page this
// store holds holds what is below it.
@(private)
page_save :: proc(s:^store.Store,l:^Log,k:int) -> (address:store.Hash,error:Error) {
    if l.pages[k].address!={} && store.chunk_has(s,l.pages[k].address) {return l.pages[k].address,.None}
    w:=writer_make(context.temp_allocator)
    p:=&l.pages[k]
    write_value(&w,Log_Page_Head{magic=KAI_MAGIC,depth=p.depth,leaf=b8(p.leaf),count=p.count})
    if p.leaf {
        context.user_ptr=l
        slice.sort_by(p.items[:],proc(a,b:u32) -> bool {
            l:=(^Log)(context.user_ptr)
            return hash_less(l.items[a].address,l.items[b].address)
        })
        for i in p.items {
            write_value(&w,u32(len(l.items[i].bytes)))
            write_bytes(&w,l.items[i].bytes)
        }
    } else {
        for c in 0..<256 {
            child:store.Hash
            if l.pages[k].children[c]!=0 {child=page_save(s,l,int(l.pages[k].children[c])-1) or_return}
            write_bytes(&w,child[:])
        }
    }
    if w.failed {return {},.Out_Of_Memory}
    address=object_put(s,.Log_Page,w.data[:]) or_return
    l.pages[k].address=address
    l.written+=len(w.data)
    return address,.None
}

// Puts what changed of the log since it was read or saved, its pages and its
// index, and points its ref at the index.
log_save :: proc(s:^store.Store,l:^Log) -> (address:store.Hash,error:Error) {
    return log_save_in(s,l,log_namespace(l.kind))
}

// log_save under namespace: a node keeps a user no org admitted yet apart.
log_save_in :: proc(s:^store.Store,l:^Log,namespace:string) -> (address:store.Hash,error:Error) {
    if l.id=={} || len(l.pages)==0 {return {},.Invalid_Argument}
    l.written=0
    root:=page_save(s,l,0) or_return
    log_index(l) or_return
    heads:=l.heads[:min(len(l.heads),LOG_HEADS_MAX)]
    w:=writer_make(context.temp_allocator)
    write_value(&w,Log_Index_Head{magic=KAI_MAGIC,kind=l.kind,count=u32(len(l.items)),id=l.id,root=root,heads=u16(len(heads))})
    for h in heads {write_bytes(&w,l.items[h].address[:])}
    if w.failed {return {},.Out_Of_Memory}
    address=object_put(s,.Log,w.data[:]) or_return
    l.written+=len(w.data)
    name:[64]u8
    if e:=store.ref_set(s,namespace,log_name(l.id,&name),address);e!=.None {return {},store_error(e)}
    return address,.None
}

// The index of a log at address, read.
log_index_read :: proc(s:^store.Store,address:store.Hash) -> (head:Log_Index_Head,heads:[]store.Hash,error:Error) {
    bytes:=object_get(s,address,.Log,context.temp_allocator) or_return
    r:=Reader{data=bytes}
    head=read_value(&r,Log_Index_Head)
    if r.short || head.magic!=KAI_MAGIC || head.reserved!=0 || !zero(head.reserved2[:]) || head.kind>max(Log_Kind) || head.count>LOG_ENTRIES_MAX || head.id=={} || head.root=={} {return {},nil,.Corrupt}
    heads=slice.reinterpret([]store.Hash,read_bytes(&r,int(head.heads)*size_of(store.Hash)))
    if r.short || r.at!=len(bytes) {return {},nil,.Corrupt}
    return head,heads,.None
}

// Adds to l the entries of the log whose index is at address, checking each
// signature when verify; changed when one was new. The pages l holds already
// are not read again. Pages the store lacks are appended to missing, when it
// is given, and the error is Missing: what was read is taken all the same.
log_load :: proc(s:^store.Store,l:^Log,address:store.Hash,verify:bool,missing:^[dynamic]store.Hash=nil) -> (changed:bool,error:Error) {
    head,_:=log_index_read(s,address) or_return
    if l.id!={} && l.id!=head.id {return false,.Invalid_Argument}
    if l.known && l.kind!=head.kind {return false,.Invalid_Argument}
    l.id,l.kind,l.known=head.id,head.kind,true
    if reserve(&l.items,int(head.count))!=nil || reserve(&l.found,int(head.count))!=nil {return false,.Out_Of_Memory}
    read:=make([dynamic]Page_Read,context.temp_allocator)
    lacking:=false
    page_load(s,l,head.root,0,{},verify,&changed,&read,&lacking,missing) or_return
    // The pages read stand for the pages l now holds where they cover the same entries.
    for x in read {
        if k:=page_at(l,x.path,x.depth);k>=0 && l.pages[k].count==x.count && bool(l.pages[k].leaf)==x.leaf {l.pages[k].address=x.address}
    }
    return changed,lacking?.Missing:.None
}

@(private)
Page_Read :: struct {address:store.Hash,path:store.Hash,depth:u8,leaf:bool,count:u32}

// The page of l at the depth bytes of path, -1 when there is none.
@(private)
page_at :: proc(l:^Log,path:store.Hash,depth:u8) -> int {
    if len(l.pages)==0 {return -1}
    k:=0
    for l.pages[k].depth<depth {
        if l.pages[k].leaf {return -1}
        c:=l.pages[k].children[path[l.pages[k].depth]]
        if c==0 {return -1}
        k=int(c)-1
    }
    return k
}

@(private)
page_load :: proc(s:^store.Store,l:^Log,address:store.Hash,depth:u8,path:store.Hash,verify:bool,changed:^bool,read:^[dynamic]Page_Read,lacking:^bool,missing:^[dynamic]store.Hash) -> Error {
    if k:=page_at(l,path,depth);k>=0 && l.pages[k].address==address {return .None}
    bytes,e:=object_get(s,address,.Log_Page,context.temp_allocator)
    if e==.Missing {
        lacking^=true
        if missing!=nil {append(missing,address)}
        return .None
    }
    if e!=.None {return e}
    r:=Reader{data=bytes}
    head:=read_value(&r,Log_Page_Head)
    if r.short || head.magic!=KAI_MAGIC || head.depth!=depth || head.depth>31 || head.count>LOG_ENTRIES_MAX {return .Corrupt}
    if _,ae:=append(read,Page_Read{address,path,depth,bool(head.leaf),head.count});ae!=nil {return .Out_Of_Memory}
    if head.leaf {
        if head.count>LOG_PAGE_ENTRIES {return .Corrupt}
        for _ in 0..<head.count {
            size:=read_value(&r,u32)
            entry:=read_bytes(&r,int(size))
            if r.short {return .Corrupt}
            at,want:=store.address_of_bytes(entry),path
            if string(at[:depth])!=string(want[:depth]) {return .Corrupt}
            added,add_error:=log_add(l,entry,verify)
            if add_error==.Corrupt || add_error==.Out_Of_Memory || add_error==.Too_Large {return add_error}
            changed^|=added
        }
    } else {
        children:=slice.reinterpret([]store.Hash,read_bytes(&r,256*size_of(store.Hash)))
        if r.short {return .Corrupt}
        for child,b in children {
            if child=={} {continue}
            next:=path
            next[depth]=u8(b)
            page_load(s,l,child,depth+1,next,verify,changed,read,lacking,missing) or_return
        }
    }
    if r.at!=len(bytes) {return .Corrupt}
    return .None
}

// The bytes of the entry at entry of the log whose index is at address,
// reading only the pages on its way: found is false when it has none.
log_entry_get :: proc(s:^store.Store,address,entry:store.Hash,allocator:=context.temp_allocator) -> (bytes:[]u8,found:bool,error:Error) {
    head,_:=log_index_read(s,address) or_return
    page:=head.root
    for depth in 0..<32 {
        data:=object_get(s,page,.Log_Page,context.temp_allocator) or_return
        r:=Reader{data=data}
        h:=read_value(&r,Log_Page_Head)
        if r.short || h.magic!=KAI_MAGIC || int(h.depth)!=depth {return nil,false,.Corrupt}
        if !h.leaf {
            children:=slice.reinterpret([]store.Hash,read_bytes(&r,256*size_of(store.Hash)))
            if r.short {return nil,false,.Corrupt}
            page=children[entry[depth]]
            if page=={} {return nil,false,.None}
            continue
        }
        for _ in 0..<h.count {
            size:=read_value(&r,u32)
            b:=read_bytes(&r,int(size))
            if r.short {return nil,false,.Corrupt}
            if store.address_of_bytes(b)==entry {
                out,me:=make([]u8,len(b),allocator)
                if me!=nil {return nil,false,.Out_Of_Memory}
                copy(out,b)
                return out,true,.None
            }
        }
        return nil,false,.None
    }
    return nil,false,.Corrupt
}

// The pages of the log whose index is at address that the store lacks,
// appended to out: what to fetch before the log reads whole.
log_pages_missing :: proc(s:^store.Store,address:store.Hash,out:^[dynamic]store.Hash) -> Error {
    head,_:=log_index_read(s,address) or_return
    return pages_missing(s,head.root,out,0)
}

@(private)
pages_missing :: proc(s:^store.Store,address:store.Hash,out:^[dynamic]store.Hash,depth:int) -> Error {
    if depth>31 {return .Corrupt}
    bytes,e:=object_get(s,address,.Log_Page,context.temp_allocator)
    if e==.Missing {
        if _,ae:=append(out,address);ae!=nil {return .Out_Of_Memory}
        return .None
    }
    if e!=.None {return e}
    r:=Reader{data=bytes}
    h:=read_value(&r,Log_Page_Head)
    if r.short || h.leaf {return .None}
    children:=slice.reinterpret([]store.Hash,read_bytes(&r,256*size_of(store.Hash)))
    if r.short {return .Corrupt}
    for c in children {
        if c!={} {pages_missing(s,c,out,depth+1) or_return}
    }
    return .None
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

// Merges the log a peer gave, its index at address, into l, verified, and
// saves l when it grew. A bad entry of the peer is skipped, the rest are
// taken. Missing, with the pages to fetch appended to missing, while some
// are not in the store yet.
log_merge :: proc(s:^store.Store,l:^Log,address:store.Hash,missing:^[dynamic]store.Hash=nil) -> (changed:bool,error:Error) {
    changed,error=log_load(s,l,address,true,missing)
    if changed {
        if _,save:=log_save(s,l);save!=.None {return changed,save}
    }
    return
}
