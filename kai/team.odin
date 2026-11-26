package kai

import "base:runtime"
import "core:crypto"
import "core:crypto/hash"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "mirai:store"

// The Kai state of one machine, in its store: the device's Ed25519 seed in an
// owner-only file at the root of the store, made the first time it opens, and
// under MACHINE_NAMESPACE refs (never served to peers) its profile (the
// person's and the machine's names), the org repository each local repository
// is a workspace of and the addresses each peer was last reached at. The orgs
// are their signed records (org.odin); the open invites are INVITE_NAMESPACE
// refs. The CLI, the editor and a server open a machine the same way; each
// procedure that fails says in t.why what failed and how to fix it.

IDENTITY_FILE :: "kai-identity" // the seed of this device's signing key
MACHINE_NAMESPACE :: "kai-machine"
INVITE_NAMESPACE :: "kai-invite"
PROFILE_NAME :: "profile"
LINK_PREFIX :: "repo-" // + a local repository's hex: names the org (16 bytes) and repository (16 bytes) it is a workspace of
PEER_PREFIX :: "peer-" // + a device key's hex, its first 16 bytes: a Note of the addresses it was reached at
INVITE_HOURS :: 72
NOTE_TEXTS_MAX :: 16
ADDRESS_MAX :: 255

Team :: struct {
    store:^store.Store, // the process's
    tenants:^Tenants,   // a server's: each org in a store of its own; nil keeps every org in store
    identity:Identity,
    name:string,        // of the person, "" until set
    device:string,      // of this machine
    why:string,         // what the last failure was and how to fix it, in the temp allocator
    allocator:runtime.Allocator,
}

// The stores of the orgs a server keeps, one folder each under
// <root>/orgs/<org hex>, so no org reads another's objects, refs or quota.
// Opened on first use and kept until tenants_close; safe from any thread.
Tenants :: struct {
    root:string,
    lock:sync.Mutex,
    stores:map[Org_Id]^store.Store,
    allocator:runtime.Allocator,
}

tenants_init :: proc(tn:^Tenants,root:string,allocator:=context.allocator) -> Error {
    tn^={stores=make(map[Org_Id]^store.Store,allocator),allocator=allocator}
    e:runtime.Allocator_Error
    if tn.root,e=strings.clone(root,allocator);e!=nil {return .Out_Of_Memory}
    return .None
}

tenants_destroy :: proc(tn:^Tenants) {
    for _,s in tn.stores {
        store.close(s)
        free(s,tn.allocator)
    }
    delete(tn.stores)
    delete(tn.root,tn.allocator)
    tn^={}
}

// The store that holds org: the machine's, or the org's own on a server.
// On a server, an org it keeps no folder of is Missing unless create, which
// only making or joining an org passes: an id a stranger names never makes a
// folder, a store or an open file.
team_store :: proc(t:^Team,org:Org_Id,create:=false) -> (s:^store.Store,error:Error) {
    tn:=t.tenants
    if tn==nil {return t.store,.None}
    sync.mutex_lock(&tn.lock)
    defer sync.mutex_unlock(&tn.lock)
    if held,ok:=tn.stores[org];ok {return held,.None}
    name:[32]u8
    root:=strings.concatenate({tn.root,"/orgs/",org_ref_name(org,&name)},context.temp_allocator)
    if !create && !os.exists(strings.concatenate({root,"/LAYOUT"},context.temp_allocator)) {return nil,.Missing}
    made,me:=new(store.Store,tn.allocator)
    if me!=nil {return nil,.Out_Of_Memory}
    opened,e:=store.open(root,tn.allocator)
    if e!=.None {
        free(made,tn.allocator)
        return nil,store_error(e)
    }
    made^=opened
    tn.stores[org]=made
    return made,.None
}

// The orgs this machine holds a record of, sorted, in the temp allocator.
team_org_ids :: proc(t:^Team) -> []Org_Id {
    if t.tenants==nil {
        ids,_:=org_ids(t.store,context.temp_allocator)
        return ids
    }
    out:=make([dynamic]Org_Id,context.temp_allocator)
    entries,e:=os.read_all_directory_by_path(strings.concatenate({t.tenants.root,"/orgs"},context.temp_allocator),context.temp_allocator)
    if e!=nil {return nil}
    for entry in entries {
        id:Org_Id
        if !hex_parse(entry.name,id[:]) {continue}
        s,se:=team_store(t,id)
        if se!=.None {continue}
        if _,_,he:=org_head(s,id,context.temp_allocator);he==.None {append(&out,id)}
    }
    return out[:]
}

// A repository of an org a local repository is a workspace of.
Link :: struct {local:Repo_Id,org:Org_Id,repo:Repo_Id}

// Opens the Kai state of the machine whose store is s, making its key the
// first time.
team_open :: proc(t:^Team,s:^store.Store,allocator:=context.allocator) -> Error {
    t^={store=s,allocator=allocator}
    identity,e:=machine_identity(s)
    if e!=.None {return team_fail(t,e,"the device key at the root of the store does not read: give this user access to the store's folder")}
    t.identity=identity
    texts:=make([dynamic]string,context.temp_allocator)
    if note_get(s,PROFILE_NAME,&texts)==.None && len(texts)==2 {return team_names(t,texts[0],texts[1])}
    return .None
}

@(private)
team_names :: proc(t:^Team,name,device:string) -> Error {
    n,ne:=strings.clone(name,t.allocator)
    d,de:=strings.clone(device,t.allocator)
    if ne!=nil || de!=nil {
        delete(n,t.allocator)
        delete(d,t.allocator)
        return .Out_Of_Memory
    }
    delete(t.name,t.allocator)
    delete(t.device,t.allocator)
    t.name,t.device=n,d
    return .None
}

team_close :: proc(t:^Team) {
    delete(t.name,t.allocator)
    delete(t.device,t.allocator)
    crypto.zero_explicit(&t.identity,size_of(Identity))
    t^={}
}

@(private)
team_fail :: proc(t:^Team,e:Error,why:string) -> Error {
    t.why=why
    return e
}

// Names the person and this machine, which every org it joins or makes lists.
team_profile_set :: proc(t:^Team,name,device:string) -> Error {
    if !name_valid(name) || !name_valid(device) {return team_fail(t,.Invalid_Argument,"a name has 1 to 64 bytes of UTF-8: type your name and this machine's")}
    note_set(t.store,PROFILE_NAME,{name,device}) or_return
    return team_names(t,name,device)
}

// Makes an org with this machine its first admin.
team_org_create :: proc(t:^Team,name:string) -> (id:Org_Id,error:Error) {
    if t.name=="" {return {},team_fail(t,.Invalid_Argument,"name yourself and this machine first (Team, or mirai kai profile)")}
    if !name_valid(name) {return {},team_fail(t,.Invalid_Argument,"an org's name has 1 to 64 bytes of UTF-8")}
    members:=[1]Member{{key=t.identity.key,role=.Admin,name=t.name,device=t.device}}
    o:=Org{id=random_id(Org_Id),version=1,name=name,members=members[:]}
    s,se:=team_store(t,o.id,create=true)
    if se!=.None {return {},team_fail(t,se,"the org's store does not open: give this user access to the server's folder")}
    if _,e:=org_write(s,&o,&t.identity,time.now()._nsec);e!=.None {return {},team_fail(t,e,"the store refused the org's record: give this user access to the store")}
    return o.id,store_error(store.commit(s))
}

// The newest record of org this machine holds, in the temp allocator.
team_org :: proc(t:^Team,id:Org_Id) -> (o:Org,address:store.Hash,error:Error) {
    s:=team_store(t,id) or_return
    o,address,error=org_head(s,id,context.temp_allocator)
    if error!=.None {t.why="this machine is no member of that org: join it with an invite from one of its admins"}
    return
}

// Writes the next version of org after edit changed a copy of the newest.
@(private)
team_org_edit :: proc(t:^Team,id:Org_Id,data:rawptr,edit:proc(t:^Team,members:^[dynamic]Member,repos:^[dynamic]Org_Repo,data:rawptr) -> Error) -> Error {
    held,address:=team_org(t,id) or_return
    members:=make([dynamic]Member,context.temp_allocator)
    repos:=make([dynamic]Org_Repo,context.temp_allocator)
    append(&members,..held.members)
    append(&repos,..held.repos)
    edit(t,&members,&repos,data) or_return
    next:=held
    next.version,next.prev,next.members,next.repos=held.version+1,address,members[:],repos[:]
    s:=team_store(t,id) or_return
    if _,e:=org_write(s,&next,&t.identity,time.now()._nsec);e!=.None {
        if e==.Unauthorized {return team_fail(t,e,"only an admin of the org changes its members, and a writer its repositories: ask an admin")}
        return team_fail(t,e,"the store refused the org's record: give this user access to the store")
    }
    return store_error(store.commit(s))
}

// Adds a member, or changes its role and names.
team_member_set :: proc(t:^Team,org:Org_Id,member:Member) -> Error {
    if !name_valid(member.name) || !name_valid(member.device) || member.key=={} {return team_fail(t,.Invalid_Argument,"a member needs its key and names of 1 to 64 bytes")}
    m:=member
    return team_org_edit(t,org,&m,proc(t:^Team,members:^[dynamic]Member,repos:^[dynamic]Org_Repo,data:rawptr) -> Error {
        m:=(^Member)(data)^
        for &x in members {
            if x.key==m.key {
                x=m
                return .None
            }
        }
        if len(members)>=MEMBERS_MAX {return team_fail(t,.Too_Large,"the org has as many members as it may")}
        append(members,m)
        return .None
    })
}

// Removes a member's device; the org keeps at least one admin.
team_member_remove :: proc(t:^Team,org:Org_Id,key:Key) -> Error {
    k:=key
    return team_org_edit(t,org,&k,proc(t:^Team,members:^[dynamic]Member,repos:^[dynamic]Org_Repo,data:rawptr) -> Error {
        k:=(^Key)(data)^
        admins:=0
        found:=-1
        for m,i in members {
            if m.role==.Admin {admins+=1}
            if m.key==k {found=i}
        }
        if found<0 {return team_fail(t,.Missing,"that device is no member of the org")}
        if members[found].role==.Admin && admins==1 {return team_fail(t,.Invalid_Argument,"the org's last admin stays: make another member admin first")}
        ordered_remove(members,found)
        return .None
    })
}

// Adds a repository to org, or renames it and sets whether it is public.
team_repo_set :: proc(t:^Team,org:Org_Id,repo:Org_Repo) -> Error {
    if !name_valid(repo.name) || repo.id=={} {return team_fail(t,.Invalid_Argument,"a repository needs a name of 1 to 64 bytes")}
    r:=repo
    return team_org_edit(t,org,&r,proc(t:^Team,members:^[dynamic]Member,repos:^[dynamic]Org_Repo,data:rawptr) -> Error {
        r:=(^Org_Repo)(data)^
        for &x in repos {
            if x.id==r.id {
                x=r
                return .None
            }
        }
        if len(repos)>=ORG_REPOS_MAX {return team_fail(t,.Too_Large,"the org has as many repositories as it may")}
        append(repos,r)
        return .None
    })
}

// Publishes the shared bookmarks of a repository of org.
team_publish :: proc(t:^Team,org:Org_Id,repo:Repo_Id,bookmarks:[]Bookmark_Ref) -> Error {
    o,_:=team_org(t,org) or_return
    s:=team_store(t,org) or_return
    if _,e:=repo_refs_publish(s,&o,repo,&t.identity,bookmarks,time.now()._nsec);e!=.None {
        if e==.Unauthorized {return team_fail(t,e,"only a writer of the org publishes: ask an admin for the role")}
        if e==.Missing {return team_fail(t,e,"the repository is not in the org: publish it from its project first")}
        return team_fail(t,e,"the store refused the bookmarks: give this user access to the store")
    }
    return store_error(store.commit(s))
}

// Makes the local repository a workspace of a repository of org.
team_link :: proc(t:^Team,l:Link) -> Error {
    name:[len(LINK_PREFIX)+32]u8
    value:store.Hash
    org,repo:=l.org,l.repo
    copy(value[:16],org[:])
    copy(value[16:],repo[:])
    if e:=store.ref_set(t.store,MACHINE_NAMESPACE,link_name(l.local,&name),value);e!=.None {return team_fail(t,store_error(e),"the store refused the link: give this user access to the store")}
    return store_error(store.commit(t.store))
}

// The repository of an org the local repository is a workspace of.
team_link_of :: proc(t:^Team,local:Repo_Id) -> (l:Link,ok:bool) {
    name:[len(LINK_PREFIX)+32]u8
    value,e:=store.ref_get(t.store,MACHINE_NAMESPACE,link_name(local,&name))
    if e!=.None {return}
    l.local=local
    copy(l.org[:],value[:16])
    copy(l.repo[:],value[16:])
    return l,true
}

// Every link of this machine, in the temp allocator.
team_links :: proc(t:^Team) -> []Link {
    out:=make([dynamic]Link,context.temp_allocator)
    refs,_:=store.ref_list(t.store,MACHINE_NAMESPACE,context.temp_allocator)
    for ref in refs {
        if !strings.has_prefix(ref.name,LINK_PREFIX) {continue}
        l:Link
        if !hex_parse(ref.name[len(LINK_PREFIX):],l.local[:]) {continue}
        value:=ref.hash
        copy(l.org[:],value[:16])
        copy(l.repo[:],value[16:])
        append(&out,l)
    }
    return out[:]
}

@(private)
link_name :: proc(local:Repo_Id,buffer:^[len(LINK_PREFIX)+32]u8) -> string {
    copy(buffer[:],LINK_PREFIX)
    r:=local
    hex_text(r[:],buffer[len(LINK_PREFIX):])
    return string(buffer[:])
}

// --- Peers ---

// Keeps where a peer was reached, newest first.
team_peer_seen :: proc(t:^Team,key:Key,address:string) -> Error {
    if address=="" || len(address)>ADDRESS_MAX {return .Invalid_Argument}
    name:[len(PEER_PREFIX)+32]u8
    texts:=make([dynamic]string,context.temp_allocator)
    note_get(t.store,peer_name(key,&name),&texts)
    if len(texts)>0 && texts[0]==address {return .None}
    for k:=0;k<len(texts);k+=1 {
        if texts[k]==address {
            ordered_remove(&texts,k)
            break
        }
    }
    inject_at(&texts,0,address)
    return note_set(t.store,peer_name(key,&name),texts[:min(len(texts),NOTE_TEXTS_MAX)])
}

// The addresses a peer was reached at, newest first, in the temp allocator.
team_peer_addresses :: proc(t:^Team,key:Key) -> []string {
    name:[len(PEER_PREFIX)+32]u8
    texts:=make([dynamic]string,context.temp_allocator)
    note_get(t.store,peer_name(key,&name),&texts)
    return texts[:]
}

@(private)
peer_name :: proc(key:Key,buffer:^[len(PEER_PREFIX)+32]u8) -> string {
    copy(buffer[:],PEER_PREFIX)
    k:=key
    hex_text(k[:16],buffer[len(PEER_PREFIX):])
    return string(buffer[:])
}

// --- Invites ---

// What an admin hands another machine to join its org: where to reach the
// admin's machine, its device key and a one-time secret. Text of base32.
Invite_Token :: struct {
    org:Org_Id,
    key:Key,          // the inviting device
    secret:[32]u8,
    addresses:[]string, // host:port, the first one tried first
}

INVITE_TEXT_PREFIX :: "kai2"

// What the inviting machine keeps of an open invite.
@(private)
Invite_Head :: struct #packed {
    magic:u32,
    org:Org_Id,
    secret:[32]u8,
    role:Role,
    reserved:[7]u8,
    expires:i64, // ns
} // + name: the person the joining device belongs to, "" for one of its own

// Opens an invite to org for a device with role: of the person name, or of
// whoever joins when name is "". addresses are where this machine listens.
team_invite :: proc(t:^Team,org:Org_Id,role:Role,name:string,addresses:[]string,allocator:=context.allocator) -> (text:string,error:Error) {
    o,_:=team_org(t,org) or_return
    if r,ok:=org_role(&o,t.identity.key);!ok || r!=.Admin {return "",team_fail(t,.Unauthorized,"only an admin of the org invites: ask one")}
    if name!="" && !name_valid(name) {return "",team_fail(t,.Invalid_Argument,"a name has 1 to 64 bytes of UTF-8")}
    if len(addresses)==0 {return "",team_fail(t,.Invalid_Argument,"the invite needs an address this machine listens at: start its Kai agent (the editor, or mirai kai agent)")}
    head:=Invite_Head{magic=KAI_MAGIC,org=org,role=role,expires=time.now()._nsec+i64(INVITE_HOURS)*i64(time.Hour)}
    crypto.rand_bytes(head.secret[:])
    defer crypto.zero_explicit(&head.secret,32)
    w:=writer_make(context.temp_allocator)
    write_value(&w,head)
    write_name(&w,name)
    if w.failed {return "",.Out_Of_Memory}
    address,pe:=object_put(t.store,.Invite,w.data[:])
    if pe!=.None {return "",team_fail(t,pe,"the store refused the invite: give this user access to the store")}
    ref:[64]u8
    if e:=store.ref_set(t.store,INVITE_NAMESPACE,invite_name(head.secret,&ref),address);e!=.None {return "",store_error(e)}
    store.commit(t.store)
    token:=Invite_Token{org=org,key=t.identity.key,secret=head.secret,addresses=addresses}
    return invite_text(&token,allocator)
}

// The open invite of org whose secret the initiator of hs proved, which it
// removes: one invite, one device. Expired invites are removed on the way.
team_invite_take :: proc(t:^Team,org:Org_Id,hs:^Handshake) -> (role:Role,name:string,error:Error) {
    refs,e:=store.ref_list(t.store,INVITE_NAMESPACE,context.temp_allocator)
    if e!=.None {return {},"",.Expired}
    now:=time.now()._nsec
    for ref in refs {
        bytes,ge:=object_get(t.store,ref.hash,.Invite,context.temp_allocator)
        if ge!=.None {continue}
        r:=Reader{data=bytes}
        head:=read_value(&r,Invite_Head)
        n:=tail_string(&r)
        if r.short || head.magic!=KAI_MAGIC {continue}
        if head.expires<now {
            store.ref_remove(t.store,INVITE_NAMESPACE,ref.name)
            continue
        }
        if head.org!=org || !handshake_invited(hs,head.secret) {continue}
        store.ref_remove(t.store,INVITE_NAMESPACE,ref.name)
        store.commit(t.store)
        return head.role,strings.clone(n,context.temp_allocator),.None
    }
    store.commit(t.store)
    return {},"",.Expired
}

@(private)
invite_name :: proc(secret:[32]u8,buffer:^[64]u8) -> string {
    digest:[32]u8
    s:=secret
    hash.hash_bytes_to_buffer(.SHA256,s[:],digest[:])
    return hex_text(digest[:16],buffer[:])
}

invite_text :: proc(token:^Invite_Token,allocator:=context.allocator) -> (text:string,error:Error) {
    w:=writer_make(context.temp_allocator)
    write_value(&w,token.org)
    write_value(&w,token.key)
    write_value(&w,token.secret)
    write_value(&w,u8(len(token.addresses)))
    for a in token.addresses {
        if len(a)==0 || len(a)>ADDRESS_MAX {return "",.Invalid_Argument}
        write_name(&w,a)
    }
    if w.failed {return "",.Out_Of_Memory}
    made,ce:=strings.concatenate({INVITE_TEXT_PREFIX,base32_encode(w.data[:])},allocator)
    if ce!=nil {return "",.Out_Of_Memory}
    return made,.None
}

// The token of text; its addresses in allocator.
invite_parse :: proc(text:string,allocator:=context.allocator) -> (token:Invite_Token,error:Error) {
    trimmed:=strings.trim_space(text)
    if !strings.has_prefix(trimmed,INVITE_TEXT_PREFIX) {return {},.Corrupt}
    bytes,ok:=base32_decode(trimmed[len(INVITE_TEXT_PREFIX):])
    if !ok {return {},.Corrupt}
    r:=Reader{data=bytes}
    token.org=read_value(&r,Org_Id)
    token.key=read_value(&r,Key)
    token.secret=read_value(&r,[32]u8)
    count:=int(read_value(&r,u8))
    if r.short || count==0 || count>NOTE_TEXTS_MAX {return {},.Corrupt}
    addresses,me:=make([]string,count,allocator)
    if me!=nil {return {},.Out_Of_Memory}
    for &a in addresses {
        a=tail_string(&r)
        if a=="" {r.short=true}
    }
    if r.short || r.at!=len(bytes) {
        delete(addresses,allocator)
        return {},.Corrupt
    }
    for &a,k in addresses {
        ce:runtime.Allocator_Error
        if a,ce=strings.clone(a,allocator);ce!=nil {
            for x in addresses[:k] {delete(x,allocator)}
            delete(addresses,allocator)
            return {},.Out_Of_Memory
        }
    }
    token.addresses=addresses
    return token,.None
}

// --- Notes ---

// A few short texts this machine keeps for itself under a MACHINE_NAMESPACE
// ref: its profile, a peer's addresses.
@(private)
note_set :: proc(s:^store.Store,name:string,texts:[]string) -> Error {
    if len(texts)>NOTE_TEXTS_MAX {return .Too_Large}
    w:=writer_make(context.temp_allocator)
    write_value(&w,u8(len(texts)))
    for x in texts {
        if len(x)>255 {return .Invalid_Argument}
        write_name(&w,x)
    }
    if w.failed {return .Out_Of_Memory}
    address:=object_put(s,.Note,w.data[:]) or_return
    if e:=store.ref_set(s,MACHINE_NAMESPACE,name,address);e!=.None {return store_error(e)}
    return store_error(store.commit(s))
}

@(private)
note_get :: proc(s:^store.Store,name:string,out:^[dynamic]string) -> Error {
    address,e:=store.ref_get(s,MACHINE_NAMESPACE,name)
    if e!=.None {return store_error(e)}
    bytes:=object_get(s,address,.Note,context.temp_allocator) or_return
    r:=Reader{data=bytes}
    count:=int(read_value(&r,u8))
    for _ in 0..<min(count,NOTE_TEXTS_MAX) {append(out,tail_string(&r))}
    if r.short {
        clear(out)
        return .Corrupt
    }
    return .None
}

// --- The device key ---

// The identity of this machine: the seed kept in the root of the store, made
// the first time.
machine_identity :: proc(s:^store.Store) -> (identity:Identity,error:Error) {
    seed:[32]u8
    defer crypto.zero_explicit(&seed,32)
    machine_secret(s,IDENTITY_FILE,seed[:]) or_return
    identity.seed=seed
    if !identity_derive(&identity) {return {},.Corrupt}
    return identity,.None
}

// The secret bytes of the file name at the root of the store, as many as out
// holds, random and owner-only the first time: only a file that is not there
// is made, never one that does not read now (no right, no handle left).
@(private)
machine_secret :: proc(s:^store.Store,name:string,out:[]u8) -> Error {
    file:=strings.concatenate({s.root,"/",name},context.temp_allocator)
    bytes,read_error:=os.read_entire_file(file,context.temp_allocator)
    if read_error==nil {
        defer crypto.zero_explicit(raw_data(bytes),len(bytes))
        if len(bytes)!=len(out) {return .Corrupt}
        copy(out,bytes)
        return .None
    }
    if general,is_general:=read_error.(os.General_Error);!is_general || general!=.Not_Exist {return .Io}
    crypto.rand_bytes(out)
    temp:=strings.concatenate({file,".tmp"},context.temp_allocator)
    if os.write_entire_file(temp,out,{.Read_User,.Write_User})!=nil {return .Io}
    if os.rename(temp,file)!=nil {
        os.remove(temp)
        return .Io
    }
    // Two processes made one each at once: the one that won the rename counts.
    won,won_error:=os.read_entire_file(file,context.temp_allocator)
    if won_error!=nil || len(won)!=len(out) {return .Io}
    copy(out,won)
    crypto.zero_explicit(raw_data(won),len(won))
    return .None
}

// --- base32, lowercase, no padding ---

@(private="file")
BASE32 :: [32]u8{'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z','2','3','4','5','6','7'}

@(private)
base32_encode :: proc(data:[]u8) -> string {
    table:=BASE32
    out:=make([dynamic]u8,0,(len(data)*8+4)/5,context.temp_allocator)
    bits,value:=uint(0),u32(0)
    for b in data {
        value=value<<8|u32(b)
        bits+=8
        for bits>=5 {
            bits-=5
            append(&out,table[(value>>bits)&31])
        }
    }
    if bits>0 {append(&out,table[(value<<(5-bits))&31])}
    return string(out[:])
}

@(private)
base32_decode :: proc(text:string) -> (data:[]u8,ok:bool) {
    out:=make([dynamic]u8,0,len(text)*5/8,context.temp_allocator)
    bits,value:=uint(0),u32(0)
    for c in transmute([]u8)text {
        x:=c|0x20 if c>='A' && c<='Z' else c
        d:=x>='a' && x<='z'?int(x-'a'):x>='2' && x<='7'?int(x-'2')+26:-1
        if d<0 {return nil,false}
        value=value<<5|u32(d)
        bits+=5
        if bits>=8 {
            bits-=8
            append(&out,u8(value>>bits))
        }
    }
    return out[:],true
}

