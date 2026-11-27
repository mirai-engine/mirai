package kai

import "core:crypto/hash"
import "core:slice"
import "core:strings"
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
GRANT_PREFIX :: "kai-grant-"  // + an org's hex; name: first 16 bytes of secret_hash hex
ADMIT_PREFIX :: "kai-admit-"  // + an org's hex; name: secret_hash hex
NAME_MAX :: 64                // bytes of the name of an org, a repository, a person or a device
MEMBERS_MAX :: 4096
ORG_REPOS_MAX :: 4096
REPO_BOOKMARKS_MAX :: 1024
GRANTS_MAX :: 256
ADMISSIONS_MAX :: 1024

Org_Id :: distinct [16]u8

// Reader reads every repository of the org; Node reads them too and keeps the
// derived data its writers publish (an always-on server); Writer publishes
// bookmarks, derived data and repositories; Admin also changes the members.
Role :: enum u8 {Reader,Node,Writer,Admin}

Member :: struct {
    key:Key,
    role:Role,
    name:string,    // of the person
    device:string,  // of the machine
    address:string, // host:port where every member reaches it, "" when none: a server's
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
} // + name, members × (Key, Role, name, device, address), repos × (Repo_Id, public u8, name), Signature; texts are a length byte and their bytes

// Whether name is a name of an org, member, device or repository: 1 to
// NAME_MAX bytes of UTF-8 without control characters.
name_valid :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>NAME_MAX || !utf8.valid_string(name) {return false}
    for c in name {
        if c<0x20 || c==0x7f || c>=0x80 && c<0xa0 {return false}
    }
    return true
}

// Whether name is a repository's: a name that is also a folder's on every
// system, where a pull puts it: no separator, colon or wildcard, not . or ..,
// no dot or space last and no name Windows keeps for a device.
repo_name_valid :: proc(name:string) -> bool {
    if !name_valid(name) || name=="." || name==".." {return false}
    for c in transmute([]u8)name {
        switch c {
        case '/','\\',':','*','?','"','<','>','|': return false
        }
    }
    last:=name[len(name)-1]
    if last=='.' || last==' ' {return false}
    stem:=name
    if dot:=strings.index_byte(stem,'.');dot>=0 {stem=stem[:dot]}
    stem=strings.trim_right_space(stem)
    upper:=strings.to_upper(stem,context.temp_allocator)
    switch upper {
    case "CON","PRN","AUX","NUL": return false
    }
    if len(upper)==4 && (strings.has_prefix(upper,"COM") || strings.has_prefix(upper,"LPT")) && upper[3]>='0' && upper[3]<='9' {return false}
    return true
}

// The signed bytes of o, whose signature it sets.
org_encode :: proc(o:^Org,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(o.members)>MEMBERS_MAX || len(o.repos)>ORG_REPOS_MAX {return nil,.Too_Large}
    if identity.key!=o.signer || o.version==0 || !name_valid(o.name) {return nil,.Invalid_Argument}
    for m,i in o.members {
        if !name_valid(m.name) || !name_valid(m.device) || m.role>max(Role) || len(m.address)>255 {return nil,.Invalid_Argument}
        if i>0 && !key_less(o.members[i-1].key,m.key) {return nil,.Invalid_Argument}
    }
    for r,i in o.repos {
        if !repo_name_valid(r.name) || r.id=={} {return nil,.Invalid_Argument}
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
        write_name(&w,m.address)
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
        m.address=tail_string(&r)
        ok&&=m.role<=max(Role) && name_valid(m.name) && name_valid(m.device) && (i==0 || key_less(o.members[i-1].key,m.key))
    }
    for &x,i in o.repos {
        x.id=read_value(&r,Repo_Id)
        public:=read_value(&r,u8)
        x.public=public==1
        x.name=tail_string(&r)
        ok&&=public<=1 && x.id!={} && repo_name_valid(x.name) && (i==0 || repo_less(o.repos[i-1].id,x.id))
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

// The org's attached server (.Node with an address), if any.
org_server :: proc(o:^Org) -> (key:Key,address:string,ok:bool) {
    for m in o.members {
        if m.role==.Node && m.address!="" {return m.key,m.address,true}
    }
    return {},"",false
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
    // A writer adds repositories, and changes nothing else: not the members,
    // not the org's name, not a repository held (its name, or whether it is public).
    if next.name!=held.name || len(next.members)!=len(held.members) {return false}
    for m,i in next.members {
        h:=held.members[i]
        if m.key!=h.key || m.role!=h.role || m.name!=h.name || m.device!=h.device || m.address!=h.address {return false}
    }
    for h in held.repos {
        i:=org_repo(next,h.id)
        if i<0 || next.repos[i].name!=h.name || next.repos[i].public!=h.public {return false}
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

// The newest record held of org with verified offline admissions merged into
// members; Missing when the org is not held.
org_effective_head :: proc(s:^store.Store,id:Org_Id,allocator:=context.allocator) -> (o:Org,address:store.Hash,error:Error) {
    o,address,error=org_head(s,id,allocator)
    if error!=.None {return}
    o,error=org_effective(s,&o,allocator)
    return
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
    admissions_prune(s,&next)
    return address,.None
}

// Takes the record a peer named at address, already in the store with the
// versions before it back to one held: every one of them must follow the one
// before, and the newest must win over the head held. Missing, with the
// address to fetch in need, while a version on the way is not whole in the
// store. changed is false when the head held stays. Once an org is held, a
// chain that reaches back to no version held (another first record under the
// same id) is refused, and so is a branch from an older version held whose
// signers the head held no longer lets sign: a member removed since cannot
// write the org again by branching from before its removal.
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
    base_address:store.Hash
    scratch:=scratch_make()
    a:=address
    for {
        if _,known:=ours[a];known {
            o,_:=org_get(s,a,context.temp_allocator)
            base,base_address=o,a
            break
        }
        if !object_whole(s,a,scratch) {return false,a,.Missing}
        o:=org_get(s,a,context.temp_allocator) or_return
        if o.id!=id || len(chain)>=ORG_CHAIN_MAX {return false,{},.Corrupt}
        append(&chain,o)
        if o.prev=={} {break}
        a=o.prev
    }
    if len(chain)==0 {return false,{},.None}
    if he==.None {
        if base==nil {return false,{},.Unauthorized}
        // A branch from an older version: each of its signers must sign still.
        if base_address!=held_address {
            for &x in chain {
                role,member:=org_role(&held,x.signer)
                if !member || role<.Writer || (role==.Writer && !org_signs_as_writer(&held,&x)) {return false,{},.Unauthorized}
            }
        }
    }
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
    admissions_prune(s,&newest)
    return true,{},.None
}

ORG_CHAIN_MAX :: 1<<16 // versions a peer's record may lie past the one held

// Whether a writer of held may have signed next as a version of it: the
// members and what held has of the org and its repositories stay.
@(private)
org_signs_as_writer :: proc(held,next:^Org) -> bool {
    h:=held^
    h.version=next.version-1
    return org_signs(&h,next)
}

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

// --- Offline 1-use invites and verified admissions ---

// An admin-signed 1-use voucher held by an org's server so a device can join
// while the admin is offline. The server sees only secret_hash until claimed.
Invite_Grant :: struct {
    org:Org_Id,
    secret_hash:[32]u8,
    role:Role,
    expires:i64, // ns
    signer:Key,
    name:string, // optional fixed person name ("For another machine of mine")
    signature:Signature,
}

@(private)
Invite_Grant_Head :: struct #packed {
    magic:u32,
    org:Org_Id,
    secret_hash:[32]u8,
    role:Role,
    reserved:[7]u8,
    expires:i64,
    signer:Key,
} // + name, Signature

// A joining device's self-signed claim proving knowledge of the 1-use secret
// and binding its device key, names and public address.
Invite_Claim :: struct {
    org:Org_Id,
    secret:[32]u8,
    key:Key,
    name:string,
    device:string,
    public:string,
    signature:Signature,
}

@(private)
Invite_Claim_Head :: struct #packed {
    magic:u32,
    org:Org_Id,
    secret:[32]u8,
    key:Key,
} // + name, device, public, Signature

// A verified offline admission: an admin's Invite_Grant paired with the
// invitee's Invite_Claim whose secret hashes to grant.secret_hash.
Admission :: struct {
    grant:Invite_Grant,
    claim:Invite_Claim,
}

@(private)
Admission_Head :: struct #packed {
    magic:u32,
    grant_len:u16,
    claim_len:u16,
} // + grant_bytes, claim_bytes

secret_digest :: proc(secret:[32]u8) -> (out:[32]u8) {
    s:=secret
    hash.hash_bytes_to_buffer(.SHA256,s[:],out[:])
    return
}

grant_namespace :: proc(org:Org_Id,buffer:^[len(GRANT_PREFIX)+32]u8) -> string {
    copy(buffer[:],GRANT_PREFIX)
    o:=org
    hex_text(o[:],buffer[len(GRANT_PREFIX):])
    return string(buffer[:])
}

admit_namespace :: proc(org:Org_Id,buffer:^[len(ADMIT_PREFIX)+32]u8) -> string {
    copy(buffer[:],ADMIT_PREFIX)
    o:=org
    hex_text(o[:],buffer[len(ADMIT_PREFIX):])
    return string(buffer[:])
}

@(private)
grant_ref_name :: proc(secret_hash:[32]u8,buffer:^[32]u8) -> string {
    sh:=secret_hash
    return hex_text(sh[:16],buffer[:])
}

@(private)
admit_ref_name :: proc(secret_hash:[32]u8,buffer:^[64]u8) -> string {
    sh:=secret_hash
    return hex_text(sh[:],buffer[:])
}

invite_grant_encode :: proc(g:^Invite_Grant,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if identity.key!=g.signer || g.org=={} || g.secret_hash=={} || g.role>max(Role) {return nil,.Invalid_Argument}
    if g.name!="" && !name_valid(g.name) {return nil,.Invalid_Argument}
    w:=writer_make(allocator)
    write_value(&w,Invite_Grant_Head{
        magic=KAI_MAGIC,org=g.org,secret_hash=g.secret_hash,role=g.role,
        expires=g.expires,signer=g.signer,
    })
    write_name(&w,g.name)
    if w.failed {return nil,.Out_Of_Memory}
    g.signature=sign(identity,w.data[:])
    write_bytes(&w,g.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

invite_grant_decode :: proc(bytes:[]u8) -> (g:Invite_Grant,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,Invite_Grant_Head)
    if r.short || head.magic!=KAI_MAGIC || head.org=={} || head.secret_hash=={} || head.role>max(Role) || !zero(head.reserved[:]) {return {},.Corrupt}
    g.org,g.secret_hash,g.role,g.expires,g.signer=head.org,head.secret_hash,head.role,head.expires,head.signer
    g.name=tail_string(&r)
    g.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) || (g.name!="" && !name_valid(g.name)) {return {},.Corrupt}
    if !signature_valid(g.signer,bytes[:len(bytes)-size_of(Signature)],g.signature) {return {},.Corrupt}
    return g,.None
}

invite_claim_encode :: proc(c:^Invite_Claim,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if identity.key!=c.key || c.org=={} || c.secret=={} || !name_valid(c.name) || !name_valid(c.device) || len(c.public)>ADDRESS_MAX {return nil,.Invalid_Argument}
    w:=writer_make(allocator)
    write_value(&w,Invite_Claim_Head{magic=KAI_MAGIC,org=c.org,secret=c.secret,key=c.key})
    write_name(&w,c.name)
    write_name(&w,c.device)
    write_name(&w,c.public)
    if w.failed {return nil,.Out_Of_Memory}
    c.signature=sign(identity,w.data[:])
    write_bytes(&w,c.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

invite_claim_decode :: proc(bytes:[]u8) -> (c:Invite_Claim,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,Invite_Claim_Head)
    if r.short || head.magic!=KAI_MAGIC || head.org=={} || head.secret=={} {return {},.Corrupt}
    c.org,c.secret,c.key=head.org,head.secret,head.key
    c.name=tail_string(&r)
    c.device=tail_string(&r)
    c.public=tail_string(&r)
    c.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) || !name_valid(c.name) || !name_valid(c.device) {return {},.Corrupt}
    if !signature_valid(c.key,bytes[:len(bytes)-size_of(Signature)],c.signature) {return {},.Corrupt}
    return c,.None
}

admission_encode :: proc(grant_bytes,claim_bytes:[]u8,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(grant_bytes)>int(max(u16)) || len(claim_bytes)>int(max(u16)) {return nil,.Too_Large}
    g:=invite_grant_decode(grant_bytes) or_return
    c:=invite_claim_decode(claim_bytes) or_return
    if g.org!=c.org || secret_digest(c.secret)!=g.secret_hash {return nil,.Unauthorized}
    w:=writer_make(allocator)
    write_value(&w,Admission_Head{magic=KAI_MAGIC,grant_len=u16(len(grant_bytes)),claim_len=u16(len(claim_bytes))})
    write_bytes(&w,grant_bytes)
    write_bytes(&w,claim_bytes)
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

admission_decode :: proc(bytes:[]u8) -> (ad:Admission,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,Admission_Head)
    if r.short || head.magic!=KAI_MAGIC {return {},.Corrupt}
    gb:=read_bytes(&r,int(head.grant_len))
    cb:=read_bytes(&r,int(head.claim_len))
    if r.short || r.at!=len(bytes) {return {},.Corrupt}
    ad.grant=invite_grant_decode(gb) or_return
    ad.claim=invite_claim_decode(cb) or_return
    if ad.grant.org!=ad.claim.org || secret_digest(ad.claim.secret)!=ad.grant.secret_hash {return {},.Corrupt}
    return ad,.None
}

admission_get :: proc(s:^store.Store,address:store.Hash,allocator:=context.allocator) -> (ad:Admission,error:Error) {
    bytes:=object_get(s,address,.Admission,allocator) or_return
    ad,error=admission_decode(bytes)
    if error!=.None {delete(bytes,allocator)}
    return
}

// Whether ad holds against org's signed record: matching org and secret hash,
// and signed by a current admin of org.
admission_valid :: proc(o:^Org,ad:^Admission) -> bool {
    if ad.grant.org!=o.id || ad.claim.org!=o.id {return false}
    if secret_digest(ad.claim.secret)!=ad.grant.secret_hash {return false}
    role,ok:=org_role(o,ad.grant.signer)
    return ok && role==.Admin
}

// Accepts a verified Admission object at address for org under ADMIT_PREFIX.
// Refuses a second distinct claim for an already-accepted 1-use grant.
admission_accept :: proc(s:^store.Store,o:^Org,address:store.Hash) -> (changed:bool,error:Error) {
    ad:=admission_get(s,address,context.temp_allocator) or_return
    if !admission_valid(o,&ad) {return false,.Unauthorized}
    if org_member(o,ad.claim.key)>=0 {return false,.None}
    ns:[len(ADMIT_PREFIX)+32]u8
    name:[64]u8
    namespace:=admit_namespace(o.id,&ns)
    ref_name:=admit_ref_name(ad.grant.secret_hash,&name)
    if held,he:=store.ref_get(s,namespace,ref_name);he==.None {
        if held==address {return false,.None}
        if prev,pe:=admission_get(s,held,context.temp_allocator);pe==.None && admission_valid(o,&prev) {return false,.Unauthorized}
    } else if he!=.Missing {
        return false,store_error(he)
    }
    refs,le:=store.ref_list(s,namespace,context.temp_allocator)
    if le==.None && len(refs)>=ADMISSIONS_MAX {return false,.Too_Large}
    if se:=store.ref_set(s,namespace,ref_name,address);se!=.None {return false,store_error(se)}
    return true,.None
}

// The org record with any verified offline admissions merged into members.
// Returns o^ untouched when there are no pending admissions.
org_effective :: proc(s:^store.Store,o:^Org,allocator:=context.allocator) -> (eff:Org,error:Error) {
    eff=o^
    ns:[len(ADMIT_PREFIX)+32]u8
    refs,re:=store.ref_list(s,admit_namespace(o.id,&ns),context.temp_allocator)
    if re!=.None || len(refs)==0 {return eff,.None}
    extra:=make([dynamic]Member,context.temp_allocator)
    for ref in refs {
        ad,ae:=admission_get(s,ref.hash,allocator)
        if ae!=.None || !admission_valid(o,&ad) {continue}
        if org_member(o,ad.claim.key)>=0 {continue}
        dup:=false
        for m in extra {if m.key==ad.claim.key {dup=true;break}}
        if dup {continue}
        append(&extra,Member{
            key=ad.claim.key,
            role=ad.grant.role,
            name=ad.grant.name!=""?ad.grant.name:ad.claim.name,
            device=ad.claim.device,
            address=ad.claim.public,
        })
    }
    if len(extra)==0 {return eff,.None}
    merged,me:=make([]Member,len(o.members)+len(extra),allocator)
    if me!=nil {return {},.Out_Of_Memory}
    copy(merged,o.members)
    copy(merged[len(o.members):],extra[:])
    slice.sort_by(merged,proc(a,b:Member) -> bool {return key_less(a.key,b.key)})
    eff.members=merged
    return eff,.None
}

// Stores a pending admin-signed 1-use grant on a server, bounded by GRANTS_MAX.
grant_put :: proc(s:^store.Store,o:^Org,grant_bytes:[]u8,now:i64) -> Error {
    g:=invite_grant_decode(grant_bytes) or_return
    if g.org!=o.id {return .Invalid_Argument}
    if role,ok:=org_role(o,g.signer);!ok || role!=.Admin {return .Unauthorized}
    if g.expires<=now {return .Expired}
    ns:[len(GRANT_PREFIX)+32]u8
    namespace:=grant_namespace(o.id,&ns)
    refs,le:=store.ref_list(s,namespace,context.temp_allocator)
    live:=0
    if le==.None {
        for ref in refs {
            b,ge:=object_get(s,ref.hash,.Invite_Grant,context.temp_allocator)
            if ge!=.None {
                store.ref_remove(s,namespace,ref.name)
                continue
            }
            old,de:=invite_grant_decode(b)
            if de!=.None || old.expires<=now {
                store.ref_remove(s,namespace,ref.name)
                continue
            }
            live+=1
        }
    }
    if live>=GRANTS_MAX {return .Too_Large}
    address:=object_put(s,.Invite_Grant,grant_bytes) or_return
    name:[32]u8
    if se:=store.ref_set(s,namespace,grant_ref_name(g.secret_hash,&name),address);se!=.None {return store_error(se)}
    return .None
}

// Consumes the pending 1-use grant matching secret: removes and commits its
// ref BEFORE returning its bytes so a grant never admits twice.
grant_take :: proc(s:^store.Store,o:^Org,secret:[32]u8,now:i64,allocator:=context.temp_allocator) -> (grant_bytes:[]u8,error:Error) {
    sh:=secret_digest(secret)
    ns:[len(GRANT_PREFIX)+32]u8
    name:[32]u8
    namespace:=grant_namespace(o.id,&ns)
    ref_name:=grant_ref_name(sh,&name)
    addr,ge:=store.ref_get(s,namespace,ref_name)
    if ge!=.None {return nil,.Expired}
    bytes,oe:=object_get(s,addr,.Invite_Grant,allocator)
    if oe!=.None {return nil,.Expired}
    g,de:=invite_grant_decode(bytes)
    valid:=de==.None && g.org==o.id && g.secret_hash==sh && g.expires>=now
    if valid {
        role,ok:=org_role(o,g.signer)
        valid=ok && role==.Admin
    }
    if re:=store.ref_remove(s,namespace,ref_name);re!=.None {return nil,store_error(re)}
    if ce:=store.commit(s);ce!=.None {return nil,store_error(ce)}
    if !valid {return nil,.Expired}
    return bytes,.None
}

@(private)
admissions_prune :: proc(s:^store.Store,o:^Org) {
    ns:[len(ADMIT_PREFIX)+32]u8
    namespace:=admit_namespace(o.id,&ns)
    refs,e:=store.ref_list(s,namespace,context.temp_allocator)
    if e!=.None {return}
    for ref in refs {
        ad,ae:=admission_get(s,ref.hash,context.temp_allocator)
        if ae!=.None || !admission_valid(o,&ad) || org_member(o,ad.claim.key)>=0 {
            store.ref_remove(s,namespace,ref.name)
        }
    }
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
