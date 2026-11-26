package kai

import "core:slice"
import "core:unicode/utf8"
import "mirai:store"

// An org: who reads and writes its repositories, as one signed record its
// admins version. Each version names the one before (prev) and is signed by
// an admin of that one, or by one of its writers when it changes only the
// repositories; the first is signed by an admin it lists itself. A peer moves
// its ref to a record only once every version back to one it held, or to the
// first, holds: a forged or stale record never stands. Two admins that sign the
// same version apart are settled alike everywhere: the higher version wins,
// then the lower address. A member is a device key with a role and the names
// of its person and its machine; the devices of one person share its name.
//
// A repository's shared bookmarks are a Repo_Refs record any writer signs
// with the next seq; a peer takes a record only when its signer writes the
// org now and its seq is newer than the one held (then the lower address).

ORG_NAMESPACE :: "kai-org"    // name: an org's hex; names its newest record
REPO_PREFIX :: "kai-repo-"    // + an org's hex; name: a repository's hex; names its Repo_Refs
NAME_MAX :: 64                // bytes of the name of an org, a repository, a person or a device
MEMBERS_MAX :: 4096
ORG_REPOS_MAX :: 4096
REPO_BOOKMARKS_MAX :: 1024

Org_Id :: distinct [16]u8

// Reader reads every repository of the org; Node reads them too and keeps the
// derived data its writers publish (an always-on server); Writer publishes
// bookmarks, derived data and repositories; Admin also changes the members.
Role :: enum u8 {Reader,Node,Writer,Admin}

Member :: struct {
    key:Key,
    role:Role,
    name:string,   // of the person
    device:string, // of the machine
}

Org_Repo :: struct {
    id:Repo_Id,
    public:bool, // its shared bookmarks show on a server's web view to anyone
    name:string,
}

Org :: struct {
    id:Org_Id,
    version:u64,     // 1 for the first record, one more each time
    prev:store.Hash, // the record before; zero for the first
    signer:Key,
    time:i64,        // ns
    name:string,
    members:[]Member,  // sorted by key, each once
    repos:[]Org_Repo,  // sorted by id, each once
    signature:Signature,
}

@(private)
Org_Head :: struct #packed {
    magic:u32,
    version:u64,
    id:Org_Id,
    prev:store.Hash,
    signer:Key,
    time:i64,
    members:u16,
    repos:u16,
} // + name, members × (Key, Role, name, device), repos × (Repo_Id, public u8, name), Signature; names are a length byte and their bytes

name_valid :: proc(name:string) -> bool {
    return len(name)>0 && len(name)<=NAME_MAX && utf8.valid_string(name)
}

// The signed bytes of o, whose signature it sets.
org_encode :: proc(o:^Org,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(o.members)>MEMBERS_MAX || len(o.repos)>ORG_REPOS_MAX {return nil,.Too_Large}
    if identity.key!=o.signer || o.version==0 || !name_valid(o.name) {return nil,.Invalid_Argument}
    for m,i in o.members {
        if !name_valid(m.name) || !name_valid(m.device) || m.role>max(Role) {return nil,.Invalid_Argument}
        if i>0 && !key_less(o.members[i-1].key,m.key) {return nil,.Invalid_Argument}
    }
    for r,i in o.repos {
        if !name_valid(r.name) || r.id=={} {return nil,.Invalid_Argument}
        if i>0 && !repo_less(o.repos[i-1].id,r.id) {return nil,.Invalid_Argument}
    }
    w:=writer_make(allocator)
    write_value(&w,Org_Head{magic=KAI_MAGIC,version=o.version,id=o.id,prev=o.prev,signer=o.signer,time=o.time,members=u16(len(o.members)),repos=u16(len(o.repos))})
    write_name(&w,o.name)
    for m in o.members {
        write_value(&w,m.key)
        write_value(&w,m.role)
        write_name(&w,m.name)
        write_name(&w,m.device)
    }
    for r in o.repos {
        write_value(&w,r.id)
        write_value(&w,u8(r.public))
        write_name(&w,r.name)
    }
    if w.failed {return nil,.Out_Of_Memory}
    o.signature=sign(identity,w.data[:])
    write_bytes(&w,o.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The record of bytes, checked for its form and its signature (not for its
// signer's right: org_signs); its names point into bytes.
org_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (o:Org,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,Org_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version==0 || head.members>MEMBERS_MAX || head.repos>ORG_REPOS_MAX {return {},.Corrupt}
    if (head.version==1)!=(head.prev=={}) {return {},.Corrupt}
    o.id,o.version,o.prev,o.signer,o.time=head.id,head.version,head.prev,head.signer,head.time
    o.name=tail_string(&r)
    members,me:=make([]Member,head.members,allocator)
    repos,re:=make([]Org_Repo,head.repos,allocator)
    if me!=nil || re!=nil {
        delete(members,allocator)
        delete(repos,allocator)
        return {},.Out_Of_Memory
    }
    o.members,o.repos=members,repos
    ok:=name_valid(o.name)
    for &m,i in o.members {
        m.key=read_value(&r,Key)
        m.role=read_value(&r,Role)
        m.name=tail_string(&r)
        m.device=tail_string(&r)
        ok&&=m.role<=max(Role) && name_valid(m.name) && name_valid(m.device) && (i==0 || key_less(o.members[i-1].key,m.key))
    }
    for &x,i in o.repos {
        x.id=read_value(&r,Repo_Id)
        public:=read_value(&r,u8)
        x.public=public==1
        x.name=tail_string(&r)
        ok&&=public<=1 && x.id!={} && name_valid(x.name) && (i==0 || repo_less(o.repos[i-1].id,x.id))
    }
    o.signature=read_value(&r,Signature)
    if !ok || r.short || r.at!=len(bytes) || !signature_valid(o.signer,bytes[:len(bytes)-size_of(Signature)],o.signature) {
        org_destroy(&o,allocator)
        return {},.Corrupt
    }
    return o,.None
}

org_destroy :: proc(o:^Org,allocator:=context.allocator) {
    delete(o.members,allocator)
    delete(o.repos,allocator)
    o^={}
}

// The org record at address, its names in the store's bytes of allocator.
org_get :: proc(s:^store.Store,address:store.Hash,allocator:=context.allocator) -> (o:Org,error:Error) {
    bytes:=object_get(s,address,.Org,allocator) or_return
    o,error=org_decode(bytes,allocator)
    if error!=.None {delete(bytes,allocator)}
    return
}

// The member of o whose key is key, -1 when none.
org_member :: proc(o:^Org,key:Key) -> int {
    for m,i in o.members {
        if m.key==key {return i}
    }
    return -1
}

// The role of key in o; ok false when it is no member.
org_role :: proc(o:^Org,key:Key) -> (role:Role,ok:bool) {
    i:=org_member(o,key)
    if i<0 {return}
    return o.members[i].role,true
}

org_repo :: proc(o:^Org,id:Repo_Id) -> int {
    for r,i in o.repos {
        if r.id==id {return i}
    }
    return -1
}

// Whether next follows held: the next version of the same org, signed by an
// admin of held, or by a writer of held when only the repositories changed.
// A first record (held nil) is signed by an admin it lists.
org_signs :: proc(held,next:^Org) -> bool {
    if held==nil {
        role,ok:=org_role(next,next.signer)
        return next.version==1 && next.prev=={} && ok && role==.Admin
    }
    if next.id!=held.id || next.version!=held.version+1 {return false}
    role,ok:=org_role(held,next.signer)
    if !ok || role<.Writer {return false}
    if role==.Admin {return true}
    if len(next.members)!=len(held.members) {return false}
    for m,i in next.members {
        h:=held.members[i]
        if m.key!=h.key || m.role!=h.role || m.name!=h.name || m.device!=h.device {return false}
    }
    return true
}

org_ref_name :: proc(id:Org_Id,buffer:^[32]u8) -> string {
    v:=id
    return hex_text(v[:],buffer[:])
}

// The newest record held of org and its address; Missing when none.
org_head :: proc(s:^store.Store,id:Org_Id,allocator:=context.allocator) -> (o:Org,address:store.Hash,error:Error) {
    name:[32]u8
    a,e:=store.ref_get(s,ORG_NAMESPACE,org_ref_name(id,&name))
    if e!=.None {return {},{},store_error(e)}
    o,error=org_get(s,a,allocator)
    return o,a,error
}

// The ids of the orgs s holds, sorted.
org_ids :: proc(s:^store.Store,allocator:=context.allocator) -> (ids:[]Org_Id,error:Error) {
    refs,e:=store.ref_list(s,ORG_NAMESPACE,context.temp_allocator)
    if e!=.None && e!=.Missing {return nil,store_error(e)}
    out,me:=make([dynamic]Org_Id,0,len(refs),allocator)
    if me!=nil {return nil,.Out_Of_Memory}
    for ref in refs {
        id:Org_Id
        if hex_parse(ref.name,id[:]) {append(&out,id)}
    }
    slice.sort_by(out[:],proc(a,b:Org_Id) -> bool {return org_less(a,b)})
    return out[:],.None
}

// Signs o as the next version of the record held (its first when o.version
// is 1), puts it and moves the org's ref to it.
org_write :: proc(s:^store.Store,o:^Org,identity:^Identity,time:i64) -> (address:store.Hash,error:Error) {
    o.signer,o.time=identity.key,time
    slice.sort_by(o.members,proc(a,b:Member) -> bool {return key_less(a.key,b.key)})
    slice.sort_by(o.repos,proc(a,b:Org_Repo) -> bool {return repo_less(a.id,b.id)})
    bytes:=org_encode(o,identity,context.temp_allocator) or_return
    next:=org_decode(bytes,context.temp_allocator) or_return
    held,held_address,he:=org_head(s,o.id,context.temp_allocator)
    switch {
    case he==.Missing:
        if !org_signs(nil,&next) {return {},.Unauthorized}
    case he!=.None: return {},he
    case:
        if o.prev!=held_address || !org_signs(&held,&next) {return {},.Unauthorized}
    }
    address=object_put(s,.Org,bytes) or_return
    name:[32]u8
    if e:=store.ref_set(s,ORG_NAMESPACE,org_ref_name(o.id,&name),address);e!=.None {return {},store_error(e)}
    return address,.None
}

// Takes the record a peer named at address, already in the store with the
// versions before it back to one held: every one of them must follow the one
// before, and the newest must win over the head held. Missing, with the
// address to fetch in need, while a version on the way is not in the store.
// changed is false when the head held stays.
org_accept :: proc(s:^store.Store,id:Org_Id,address:store.Hash) -> (changed:bool,need:store.Hash,error:Error) {
    held,held_address,he:=org_head(s,id,context.temp_allocator)
    if he!=.None && he!=.Missing {return false,{},he}
    if he==.None && address==held_address {return false,{},.None}
    // The versions held, back to the first.
    ours:=make(map[store.Hash]u64,context.temp_allocator)
    for x:=held_address;he==.None && x!={}; {
        o,e:=org_get(s,x,context.temp_allocator)
        if e!=.None {break}
        ours[x]=o.version
        x=o.prev
    }
    chain:=make([dynamic]Org,context.temp_allocator)
    base:Maybe(Org)
    a:=address
    for {
        if _,known:=ours[a];known {
            o,_:=org_get(s,a,context.temp_allocator)
            base=o
            break
        }
        if !object_present(s,a) {return false,a,.Missing}
        o:=org_get(s,a,context.temp_allocator) or_return
        if o.id!=id || len(chain)>=ORG_CHAIN_MAX {return false,{},.Corrupt}
        append(&chain,o)
        if o.prev=={} {break}
        a=o.prev
    }
    if len(chain)==0 {return false,{},.None}
    last:=base
    for k:=len(chain)-1;k>=0;k-=1 {
        next:=&chain[k]
        b,has:=&last.?
        if !org_signs(has?b:nil,next) {return false,{},.Unauthorized}
        last=next^
    }
    newest:=chain[0]
    if he==.None && (newest.version<held.version || newest.version==held.version && !hash_less(address,held_address)) {return false,{},.None}
    name:[32]u8
    if e:=store.ref_set(s,ORG_NAMESPACE,org_ref_name(id,&name),address);e!=.None {return false,{},store_error(e)}
    return true,{},.None
}

ORG_CHAIN_MAX :: 1<<16 // versions a peer's record may lie past the one held

// --- Shared bookmarks ---

Bookmark_Ref :: struct {name:string,target:Revision}

Repo_Refs :: struct {
    org:Org_Id,
    repo:Repo_Id,
    seq:u64,           // higher in each record of the repository
    prev:store.Hash,   // the record before, zero for the first
    signer:Key,
    time:i64,          // ns
    bookmarks:[]Bookmark_Ref, // sorted by name
    signature:Signature,
}

@(private)
Repo_Refs_Head :: struct #packed {
    magic:u32,
    count:u16,
    org:Org_Id,
    repo:Repo_Id,
    seq:u64,
    prev:store.Hash,
    signer:Key,
    time:i64,
} // + count × (Revision, name), Signature

repo_refs_encode :: proc(r:^Repo_Refs,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(r.bookmarks)>REPO_BOOKMARKS_MAX {return nil,.Too_Large}
    if identity.key!=r.signer || r.org=={} || r.repo=={} || r.seq==0 {return nil,.Invalid_Argument}
    for b,i in r.bookmarks {
        if !bookmark_name_valid(b.name) || b.target=={} || (i>0 && r.bookmarks[i-1].name>=b.name) {return nil,.Invalid_Argument}
    }
    w:=writer_make(allocator)
    write_value(&w,Repo_Refs_Head{magic=KAI_MAGIC,count=u16(len(r.bookmarks)),org=r.org,repo=r.repo,seq=r.seq,prev=r.prev,signer=r.signer,time=r.time})
    for b in r.bookmarks {
        write_value(&w,b.target)
        write_name(&w,b.name)
    }
    if w.failed {return nil,.Out_Of_Memory}
    r.signature=sign(identity,w.data[:])
    write_bytes(&w,r.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The record of bytes, checked for its form and signature; its names point
// into bytes.
repo_refs_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (r:Repo_Refs,error:Error) {
    reader:=Reader{data=bytes}
    head:=read_value(&reader,Repo_Refs_Head)
    if reader.short || head.magic!=KAI_MAGIC || head.count>REPO_BOOKMARKS_MAX || head.org=={} || head.repo=={} || head.seq==0 {return {},.Corrupt}
    r.org,r.repo,r.seq,r.prev,r.signer,r.time=head.org,head.repo,head.seq,head.prev,head.signer,head.time
    bookmarks,e:=make([]Bookmark_Ref,head.count,allocator)
    if e!=nil {return {},.Out_Of_Memory}
    r.bookmarks=bookmarks
    ok:=true
    for &b,i in r.bookmarks {
        b.target=read_value(&reader,Revision)
        b.name=tail_string(&reader)
        ok&&=b.target!={} && bookmark_name_valid(b.name) && (i==0 || r.bookmarks[i-1].name<b.name)
    }
    r.signature=read_value(&reader,Signature)
    if !ok || reader.short || reader.at!=len(bytes) || !signature_valid(r.signer,bytes[:len(bytes)-size_of(Signature)],r.signature) {
        delete(bookmarks,allocator)
        return {},.Corrupt
    }
    return r,.None
}

repo_refs_get :: proc(s:^store.Store,address:store.Hash,allocator:=context.allocator) -> (r:Repo_Refs,error:Error) {
    bytes:=object_get(s,address,.Repo_Refs,allocator) or_return
    r,error=repo_refs_decode(bytes,allocator)
    if error!=.None {delete(bytes,allocator)}
    return
}

repo_namespace :: proc(org:Org_Id,buffer:^[len(REPO_PREFIX)+32]u8) -> string {
    copy(buffer[:],REPO_PREFIX)
    o:=org
    hex_text(o[:],buffer[len(REPO_PREFIX):])
    return string(buffer[:])
}

repo_ref_name :: proc(repo:Repo_Id,buffer:^[32]u8) -> string {
    r:=repo
    return hex_text(r[:],buffer[:])
}

// The shared bookmarks held of a repository and their address; Missing when none.
repo_refs_head :: proc(s:^store.Store,org:Org_Id,repo:Repo_Id,allocator:=context.allocator) -> (r:Repo_Refs,address:store.Hash,error:Error) {
    ns:[len(REPO_PREFIX)+32]u8
    name:[32]u8
    a,e:=store.ref_get(s,repo_namespace(org,&ns),repo_ref_name(repo,&name))
    if e!=.None {return {},{},store_error(e)}
    r,error=repo_refs_get(s,a,allocator)
    return r,a,error
}

// Signs the shared bookmarks of a repository of org as the next record after
// the one held, which a writer of the org publishes.
repo_refs_publish :: proc(s:^store.Store,org:^Org,repo:Repo_Id,identity:^Identity,bookmarks:[]Bookmark_Ref,time:i64) -> (address:store.Hash,error:Error) {
    if role,ok:=org_role(org,identity.key);!ok || role<.Writer {return {},.Unauthorized}
    if org_repo(org,repo)<0 {return {},.Missing}
    r:=Repo_Refs{org=org.id,repo=repo,seq=1,signer=identity.key,time=time}
    if old,old_address,e:=repo_refs_head(s,org.id,repo,context.temp_allocator);e==.None {
        r.seq,r.prev=old.seq+1,old_address
    } else if e!=.Missing {
        return {},e
    }
    sorted,clone_error:=slice.clone(bookmarks,context.temp_allocator)
    if clone_error!=nil {return {},.Out_Of_Memory}
    slice.sort_by(sorted,proc(a,b:Bookmark_Ref) -> bool {return a.name<b.name})
    r.bookmarks=sorted
    bytes:=repo_refs_encode(&r,identity,context.temp_allocator) or_return
    address=object_put(s,.Repo_Refs,bytes) or_return
    ns:[len(REPO_PREFIX)+32]u8
    name:[32]u8
    if e:=store.ref_set(s,repo_namespace(org.id,&ns),repo_ref_name(repo,&name),address);e!=.None {return {},store_error(e)}
    return address,.None
}

// Takes the record a peer named at address, already in the store: signed by
// a writer of org now, of a repository of org, and newer than the one held.
repo_refs_accept :: proc(s:^store.Store,org:^Org,address:store.Hash) -> (changed:bool,error:Error) {
    r:=repo_refs_get(s,address,context.temp_allocator) or_return
    if r.org!=org.id || org_repo(org,r.repo)<0 {return false,.Invalid_Argument}
    if role,ok:=org_role(org,r.signer);!ok || role<.Writer {return false,.Unauthorized}
    ns:[len(REPO_PREFIX)+32]u8
    name:[32]u8
    namespace:=repo_namespace(org.id,&ns)
    if held,held_address,e:=repo_refs_head(s,org.id,r.repo,context.temp_allocator);e==.None {
        if held_address==address || r.seq<held.seq || r.seq==held.seq && !hash_less(address,held_address) {return false,.None}
    } else if e!=.Missing {
        return false,e
    }
    if e:=store.ref_set(s,namespace,repo_ref_name(r.repo,&name),address);e!=.None {return false,store_error(e)}
    return true,.None
}

@(private)
write_name :: proc(w:^Writer,name:string) {
    write_value(w,u8(min(len(name),255)))
    write_string(w,name[:min(len(name),255)])
}

@(private)
key_less :: proc "contextless" (a,b:Key) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}

@(private)
repo_less :: proc "contextless" (a,b:Repo_Id) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}

@(private)
org_less :: proc "contextless" (a,b:Org_Id) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}
