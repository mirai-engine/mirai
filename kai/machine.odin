package kai

import "base:runtime"
import "core:crypto"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import net "mirai:net"
import "mirai:std/blake3"
import "mirai:store"

// The Kai state of one machine, in its store: the device's Ed25519 seed and
// X25519 key in owner-only files at the root of the store, and under the
// MACHINE_NAMESPACE refs (never exposed to peers) the user the device belongs
// to, the orgs it serves and the projects its workspaces are. The logs
// themselves are the store's (kai-user, kai-log). Every operation that writes
// a log reads it from the store, appends, folds it again and saves it only
// when the new entry holds; m.why then says what failed and how to fix it.
// The CLI, the editor and a server open a machine the same way; changed
// tells whoever runs the mesh (runner_changed, or control_changed from
// another process) so a write reaches peers at once.

IDENTITY_FILE :: "kai-identity" // the seed of this device's signing key
DH_FILE :: "kai-dh"             // the private half of this device's X25519 key
MACHINE_NAMESPACE :: "kai-machine"
MACHINE_USER :: "user"
MACHINE_ORG_PREFIX :: "org-"
MACHINE_REPO_PREFIX :: "repo-"
MACHINE_ORGS_MAX :: 64
LABEL_RECOVERY :: "kai-1/recovery"
LABEL_DISCOVERY :: "kai-1/discovery"
RECOVERY_BYTES :: 32+3
RECOVERY_TEXT :: RECOVERY_BYTES*8/5+RECOVERY_BYTES*8/5/4-1 // 56 digits in groups of four

Machine :: struct {
    store:store.Store,
    identity:Identity,
    dh:net.Dh_Key,
    user:Log_Id,              // zero until a user is made or this device is linked
    orgs:[dynamic]Log_Id,     // the orgs it serves, as member or node
    changed:Machine_Changed,
    why:string,               // what the last failure was and how to fix it
    leak:Leak,                // what the publish scanner refused last, its path in the temp allocator
    allocator:runtime.Allocator,
}

// Told of every ref an operation wrote, so the mesh tells the peers.
Machine_Changed :: struct {
    data:rawptr,
    procedure:proc(data:rawptr,namespace,name:string),
}

// Opens the machine whose store is at root (store.default_root when empty),
// making its keys the first time.
machine_open :: proc(m:^Machine,root:string,allocator:=context.allocator) -> Error {
    m^={allocator=allocator}
    m.orgs=make([dynamic]Log_Id,allocator)
    folder:=root
    if folder=="" {folder=store.default_root(context.temp_allocator)}
    s,opened:=store.open(folder,allocator)
    if opened!=.None {
        delete(m.orgs)
        m.why="the store does not open: give the folder of a store this user may write"
        return store_error(opened)
    }
    m.store=s
    e:Error
    if m.identity,e=machine_identity(&m.store);e!=.None {
        machine_close(m)
        m.why="the identity seed of the store does not read: it is not 32 bytes, or this user may not write the store"
        return e
    }
    if m.dh,e=machine_dh(&m.store);e!=.None {
        machine_close(m)
        m.why="the X25519 key of the store does not read: it is not 32 bytes, or this user may not write the store"
        return e
    }
    machine_reload(m)
    return .None
}

machine_close :: proc(m:^Machine) {
    if m.store.state!=nil {store.close(&m.store)}
    delete(m.orgs)
    crypto.zero_explicit(&m.identity,size_of(Identity))
    crypto.zero_explicit(&m.dh,size_of(net.Dh_Key))
    m^={}
}

// Reads the user and the orgs again from the store: another process may have
// written them.
machine_reload :: proc(m:^Machine) {
    m.user={}
    if id,e:=store.ref_get(&m.store,MACHINE_NAMESPACE,MACHINE_USER);e==.None {m.user=id}
    clear(&m.orgs)
    refs,e:=store.ref_list(&m.store,MACHINE_NAMESPACE,context.temp_allocator)
    if e!=.None {return}
    for r in refs {
        if !strings.has_prefix(r.name,MACHINE_ORG_PREFIX) || len(m.orgs)>=MACHINE_ORGS_MAX {continue}
        append(&m.orgs,r.hash)
    }
}

// The identity of the device whose store is s: the seed kept in the root of
// the store, made the first time.
machine_identity :: proc(s:^store.Store) -> (identity:Identity,error:Error) {
    seed:[32]u8
    defer crypto.zero_explicit(&seed,32)
    machine_secret(s,IDENTITY_FILE,&seed) or_return
    identity.seed=seed
    if !identity_derive(&identity) {return {},.Corrupt}
    return identity,.None
}

@(private)
machine_dh :: proc(s:^store.Store) -> (key:net.Dh_Key,error:Error) {
    private:net.Key
    defer crypto.zero_explicit(&private,32)
    machine_secret(s,DH_FILE,&private) or_return
    return net.dh_key_from(&private),.None
}

// The 32 secret bytes of the file name at the root of the store, random and
// owner-only the first time.
@(private)
machine_secret :: proc(s:^store.Store,name:string,out:^[32]u8) -> Error {
    file:=strings.concatenate({s.root,"/",name},context.temp_allocator)
    if bytes,read_error:=os.read_entire_file(file,context.temp_allocator);read_error==nil {
        defer crypto.zero_explicit(raw_data(bytes),len(bytes))
        if len(bytes)!=32 {return .Corrupt}
        copy(out[:],bytes)
        return .None
    }
    crypto.rand_bytes(out[:])
    temp:=strings.concatenate({file,".tmp"},context.temp_allocator)
    if os.write_entire_file(temp,out[:],{.Read_User,.Write_User})!=nil {return .Io}
    if os.rename(temp,file)!=nil {
        os.remove(temp)
        return .Io
    }
    // Two processes made one each at once: the one that won the rename counts.
    bytes,read_error:=os.read_entire_file(file,context.temp_allocator)
    if read_error!=nil || len(bytes)!=32 {return .Io}
    copy(out[:],bytes)
    crypto.zero_explicit(raw_data(bytes),len(bytes))
    return .None
}

// What a device proves of itself to the logs and the overlays.
machine_overlay_device :: proc(m:^Machine) -> Overlay_Device {
    return {identity=m.identity,dh=Dh_Key(m.dh.public),dh_secret=transmute([32]u8)m.dh.private}
}

@(private)
machine_fail :: proc(m:^Machine,error:Error,why:string) -> Error {
    m.why=why
    return error
}

@(private)
machine_tell :: proc(m:^Machine,namespace,name:string) {
    if m.changed.procedure!=nil {m.changed.procedure(m.changed.data,namespace,name)}
}

@(private)
machine_now :: proc() -> i64 {return time.now()._nsec}

// The recovery key as it is printed once: Crockford Base32 of its seed and a
// checksum of three bytes, in groups of four digits.
@(private) CROCKFORD :: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

recovery_encode :: proc(seed:[32]u8,buffer:^[RECOVERY_TEXT]u8) -> string {
    bytes:[RECOVERY_BYTES]u8
    s:=seed
    copy(bytes[:],s[:])
    sum:=recovery_sum(seed)
    copy(bytes[32:],sum[:3])
    alphabet:=CROCKFORD
    n,digits,bits,acc:=0,0,uint(0),u32(0)
    for b in bytes {
        acc=acc<<8|u32(b)
        bits+=8
        for bits>=5 {
            bits-=5
            if digits>0 && digits%4==0 {
                buffer[n]='-'
                n+=1
            }
            buffer[n]=alphabet[(acc>>bits)&31]
            n+=1
            digits+=1
            acc&=(1<<bits)-1
        }
    }
    crypto.zero_explicit(&bytes,size_of(bytes))
    return string(buffer[:n])
}

// The seed of a recovery key as recovery_encode printed it; dashes, spaces and
// case do not matter, and I, L and O read as 1, 1 and 0.
recovery_decode :: proc(text:string) -> (seed:[32]u8,ok:bool) {
    bytes:[RECOVERY_BYTES]u8
    defer crypto.zero_explicit(&bytes,size_of(bytes))
    n,bits,acc:=0,uint(0),u32(0)
    for c in transmute([]u8)text {
        v:=-1
        switch c {
        case '-',' ': continue
        case '0','o','O': v=0
        case '1','i','I','l','L': v=1
        case:
            upper:=c>='a' && c<='z'?c-32:c
            v=strings.index_byte(CROCKFORD,upper)
        }
        if v<0 {return}
        acc=acc<<5|u32(v)
        bits+=5
        if bits>=8 {
            bits-=8
            if n>=RECOVERY_BYTES {return}
            bytes[n]=u8(acc>>bits)
            n+=1
            acc&=(1<<bits)-1
        }
    }
    if n!=RECOVERY_BYTES || acc!=0 {return}
    copy(seed[:],bytes[:32])
    sum:=recovery_sum(seed)
    if !bytes_equal(sum[:3],bytes[32:]) {return {},false}
    return seed,true
}

@(private)
recovery_sum :: proc(seed:[32]u8) -> [32]u8 {
    s:=seed
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,transmute([]u8)string(LABEL_RECOVERY))
    blake3.update(&h,s[:])
    return blake3.final(&h)
}

// Makes the user of this device: its User_Log, whose genesis the new recovery
// key signs and names this device device, or this machine's host name. The recovery key is in the text returned, once: print it and
// keep it offline; it is not stored.
machine_user_create :: proc(m:^Machine,name:string,buffer:^[RECOVERY_TEXT]u8,device:="") -> (recovery:string,error:Error) {
    if m.user!={} {return "",machine_fail(m,.Invalid_Argument,"this device belongs to a user already: one user per device")}
    if !name_valid(name) {return "",machine_fail(m,.Invalid_Argument,"a user's name is 1 to 64 bytes of text: give another")}
    head:=User_Genesis_Body{device=m.identity.key,dh=Dh_Key(m.dh.public)}
    if !name_valid(device_name_of(device,&head.device_name)) {return "",machine_fail(m,.Invalid_Argument,"a device's name is 1 to 64 bytes of text, as laptop: give another")}
    r:=identity_make()
    defer crypto.zero_explicit(&r,size_of(Identity))
    head.recovery,head.proof=r.key,device_proof(&m.identity,transmute([32]u8)r.key)
    l:Log
    log_init(&l,{},context.temp_allocator)
    body:=body_make(head,transmute([]u8)name)
    if _,e:=log_append(&l,.User_Genesis,body,&r,machine_now());e!=.None {return "",machine_fail(m,e,"the user's first entry does not sign")}
    machine_log_save(m,&l) or_return
    if e:=store.ref_set(&m.store,MACHINE_NAMESPACE,MACHINE_USER,l.id);e!=.None {return "",machine_fail(m,store_error(e),"the store refused the user's ref: give this user access to the store")}
    m.user=l.id
    return recovery_encode(r.seed,buffer),.None
}

// Records that this device belongs to the user of id: what a device pairing
// approved.
machine_user_set :: proc(m:^Machine,id:Log_Id) -> Error {
    if id=={} {return machine_fail(m,.Invalid_Argument,"no user log was given")}
    if m.user!={} && m.user!=id {return machine_fail(m,.Invalid_Argument,"this device belongs to another user already")}
    if e:=store.ref_set(&m.store,MACHINE_NAMESPACE,MACHINE_USER,id);e!=.None {return machine_fail(m,store_error(e),"the store refused the user's ref: give this user access to the store")}
    m.user=id
    return .None
}

// Records that this machine serves the org of id.
machine_org_join :: proc(m:^Machine,id:Log_Id) -> Error {
    if id=={} {return machine_fail(m,.Invalid_Argument,"no org was given")}
    if slice.contains(m.orgs[:],id) {return .None}
    if len(m.orgs)>=MACHINE_ORGS_MAX {return machine_fail(m,.Too_Large,"this machine serves as many orgs as it may: leave one first")}
    name:=machine_org_name(id)
    if e:=store.ref_set(&m.store,MACHINE_NAMESPACE,name,id);e!=.None {return machine_fail(m,store_error(e),"the store refused the org's ref: give this user access to the store")}
    append(&m.orgs,id)
    machine_tell(m,MACHINE_NAMESPACE,name)
    return .None
}

// Stops serving the org of id; its logs stay in the store.
machine_org_leave :: proc(m:^Machine,id:Log_Id) -> Error {
    k,found:=slice.linear_search(m.orgs[:],id)
    if !found {return .None}
    name:=machine_org_name(id)
    if e:=store.ref_remove(&m.store,MACHINE_NAMESPACE,name);e!=.None && e!=.Missing {return machine_fail(m,store_error(e),"the store refused to remove the org's ref")}
    ordered_remove(&m.orgs,k)
    machine_tell(m,MACHINE_NAMESPACE,name)
    return .None
}

@(private)
machine_org_name :: proc(id:Log_Id) -> string {
    buffer:=new([len(MACHINE_ORG_PREFIX)+64]u8,context.temp_allocator)
    copy(buffer[:],MACHINE_ORG_PREFIX)
    hex:[64]u8
    copy(buffer[len(MACHINE_ORG_PREFIX):],store.hex(id,&hex))
    return string(buffer[:])
}

@(private)
machine_log_save :: proc(m:^Machine,l:^Log) -> Error {
    if _,e:=log_save(&m.store,l);e!=.None {return machine_fail(m,e,"the store refused a log: give this user access to the store")}
    name:[64]u8
    machine_tell(m,log_namespace(l.kind),log_name(l.id,&name))
    return .None
}

// An org as this machine knows it: its log folded with every User_Log the
// store holds. Its strings and slices live in the allocator given.
Org_State :: struct {
    log:Log,
    user_logs:[dynamic]^Log,
    users:[dynamic]^User_Fold,
    fold:Org_Fold,
    folded:bool,
    allocator:runtime.Allocator,
}

org_state_load :: proc(s:^store.Store,id:Log_Id,o:^Org_State,allocator:=context.allocator) -> Error {
    o^={allocator=allocator}
    log_init(&o.log,id,allocator)
    o.user_logs=make([dynamic]^Log,allocator)
    o.users=make([dynamic]^User_Fold,allocator)
    log_open(s,&o.log,id,.Org) or_return
    if refs,e:=store.ref_list(s,USER_NAMESPACE,context.temp_allocator);e==.None {
        for r in refs {
            l,le:=new(Log,allocator)
            if le!=nil {return .Out_Of_Memory}
            log_init(l,{},allocator)
            if _,e:=append(&o.user_logs,l);e!=nil {
                free(l,allocator)
                return .Out_Of_Memory
            }
            if _,e:=log_load(s,l,r.hash,false);e!=.None || len(l.items)==0 {continue}
            f,fe:=new(User_Fold,allocator)
            if fe!=nil {return .Out_Of_Memory}
            if user_fold(f,l,allocator)!=.None {
                user_fold_destroy(f)
                free(f,allocator)
                continue
            }
            append(&o.users,f)
        }
    }
    return org_state_refold(o)
}

org_state_refold :: proc(o:^Org_State) -> Error {
    if o.folded {org_fold_destroy(&o.fold)}
    o.folded=false
    if e:=org_fold(&o.fold,&o.log,o.users[:],o.allocator);e!=.None {
        org_fold_destroy(&o.fold)
        return e
    }
    o.folded=true
    return .None
}

org_state_destroy :: proc(o:^Org_State) {
    if o.folded {org_fold_destroy(&o.fold)}
    for f in o.users {
        user_fold_destroy(f)
        free(f,o.allocator)
    }
    for l in o.user_logs {
        log_destroy(l)
        free(l,o.allocator)
    }
    delete(o.users)
    delete(o.user_logs)
    log_destroy(&o.log)
    o^={}
}

// The discovery secret D of an org: what its LAN beacons are keyed by. It
// hashes the org's genesis, which only members and nodes read, and every
// valid Member_Remove, so it changes when a member goes and the one removed
// cannot follow it.
org_discovery :: proc(f:^Org_Fold) -> (secret:[32]u8) {
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,transmute([]u8)string(LABEL_DISCOVERY))
    l:=f.log
    removes:=make([dynamic]store.Hash,context.temp_allocator)
    for item,i in l.items {
        if genesis(item.entry.type) {blake3.update(&h,item.bytes)}
        if item.entry.type==.Member_Remove && f.valid[i] {append(&removes,item.address)}
    }
    slice.sort_by(removes[:],hash_less)
    for &r in removes {blake3.update(&h,r[:])}
    return blake3.final(&h)
}

// The addresses a Node_Add of the org's log gives its node.
org_node_addresses :: proc(f:^Org_Fold,n:Org_Node,out:^[dynamic]net.Address) {
    if int(n.entry)>=len(f.log.items) {return}
    _,tail,ok:=body_head(f.log.items[n.entry].entry.body,Node_Add_Body)
    if !ok || len(tail)%size_of(Node_Address)!=0 {return}
    for a in slice.reinterpret([]Node_Address,tail) {
        if address,valid:=node_address_net(a);valid {append(out,address)}
    }
}

node_address_net :: proc "contextless" (a:Node_Address) -> (address:net.Address,ok:bool) {
    switch a.kind {
    case 1: return net.address_ip4(a.ip[0],a.ip[1],a.ip[2],a.ip[3],int(a.port)),true
    case 2: return {kind=.IP6,port=a.port,ip=a.ip},true
    }
    return {},false
}

node_address_of :: proc "contextless" (a:net.Address) -> (address:Node_Address,ok:bool) {
    #partial switch a.kind {
    case .IP4:
        address={kind=1,port=a.port}
        ip:=a.ip
        copy(address.ip[:4],ip[:4])
        return address,true
    case .IP6: return {kind=2,port=a.port,ip=a.ip},true
    }
    return {},false
}

// The role this device's user holds in the org, and the org's fold, for an
// operation that writes its log.
@(private)
machine_org_open :: proc(m:^Machine,id:Log_Id,o:^Org_State) -> Error {
    if e:=org_state_load(&m.store,id,o,context.temp_allocator);e!=.None {
        if e==.Missing {return machine_fail(m,e,"this store has no log of that org: pair with a member first, or let the agent fetch it")}
        return machine_fail(m,e,"the org's log does not fold: fetch it again from a member")
    }
    return .None
}

// Appends an entry this device signs to the org's log and saves it only when
// the fold takes it: an entry the fold refuses names what this device lacks.
machine_org_append :: proc(m:^Machine,org:Log_Id,type:Entry_Type,body:[]u8) -> (address:store.Hash,error:Error) {
    kind,_:=entry_log_kind(type)
    if kind!=.Org || genesis(type) {return {},machine_fail(m,.Invalid_Argument,"that is no entry of an org's log")}
    if !body_valid(type,body) {return {},machine_fail(m,.Invalid_Argument,"the entry's body is out of its bounds")}
    o:Org_State
    machine_org_open(m,org,&o) or_return
    defer org_state_destroy(&o)
    address,error=log_append(&o.log,type,body,&m.identity,machine_now(),machine_user_head(m))
    if error!=.None {return {},machine_fail(m,error,"the entry does not sign")}
    org_state_refold(&o)
    k:=log_find(&o.log,address)
    if k<0 || !o.folded || !o.fold.valid[k] {
        role:=m.user=={}?Role.None:org_role(&o.fold,m.user)
        if role==.None {return {},machine_fail(m,.Unauthorized,"this device's user is no member of the org: ask an admin to pair it as a member")}
        return {},machine_fail(m,.Unauthorized,"the org's rules refuse it to this device's user: an admin or the owner must do it, and its subject must be in the state it needs (a member to remove, a node not added yet)")
    }
    machine_log_save(m,&o.log) or_return
    return address,.None
}

@(private)
machine_user_head :: proc(m:^Machine) -> store.Hash {
    if m.user=={} {return {}}
    l:Log
    log_init(&l,m.user,context.temp_allocator)
    if log_open(&m.store,&l,m.user,.User)!=.None {return {}}
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if log_heads(&l,&heads)!=.None || len(heads)==0 {return {}}
    return heads[0]
}

// Makes an org this device's user owns: its log, and the machine serves it.
machine_org_create :: proc(m:^Machine,name:string) -> (org:Log_Id,error:Error) {
    if m.user=={} {return {},machine_fail(m,.Invalid_Argument,"this device has no user: mirai kai identity makes one")}
    if !name_valid(name) {return {},machine_fail(m,.Invalid_Argument,"an org's name is 1 to 64 bytes of text: give another")}
    l:Log
    log_init(&l,{},context.temp_allocator)
    if _,e:=log_append(&l,.Org_Genesis,body_make(Org_Genesis_Body{owner=m.user},transmute([]u8)name),&m.identity,machine_now(),machine_user_head(m));e!=.None {
        return {},machine_fail(m,e,"the org's first entry does not sign")
    }
    machine_log_save(m,&l) or_return
    machine_org_join(m,l.id) or_return
    return l.id,.None
}

// Makes a project of the org, of the repository of a workspace: its
// Project_Log and the Project_Add of the org; public projects are read by
// anyone who reaches a member.
machine_project_add :: proc(m:^Machine,org:Log_Id,repo:Repo_Id,name:string,public:bool) -> (project:Log_Id,error:Error) {
    if !name_valid(name) {return {},machine_fail(m,.Invalid_Argument,"a project's name is 1 to 64 bytes of text: give another")}
    if p,_,linked:=machine_project_of(m,repo);linked {return p,machine_fail(m,.Invalid_Argument,"this repository is a project of an org already")}
    l:Log
    log_init(&l,{},context.temp_allocator)
    if _,e:=log_append(&l,.Project_Genesis,body_make(Project_Genesis_Body{org=org,public=b8(public)},transmute([]u8)name),&m.identity,machine_now(),machine_user_head(m));e!=.None {
        return {},machine_fail(m,e,"the project's first entry does not sign")
    }
    machine_org_append(m,org,.Project_Add,body_make(Project_Add_Body{project=l.id,public=b8(public)})) or_return
    machine_log_save(m,&l) or_return
    if e:=store.ref_set(&m.store,MACHINE_NAMESPACE,machine_repo_name(repo),l.id);e!=.None {return {},machine_fail(m,store_error(e),"the store refused the project's ref")}
    return l.id,.None
}

@(private)
machine_repo_name :: proc(repo:Repo_Id) -> string {
    buffer:=new([len(MACHINE_REPO_PREFIX)+32]u8,context.temp_allocator)
    copy(buffer[:],MACHINE_REPO_PREFIX)
    r:=repo
    hex_text(r[:],buffer[len(MACHINE_REPO_PREFIX):])
    return string(buffer[:])
}

// The project and org the repository of a workspace is.
machine_project_of :: proc(m:^Machine,repo:Repo_Id) -> (project,org:Log_Id,ok:bool) {
    return store_project_of(&m.store,repo)
}

// The project and org the repository of a workspace is in the machine of store s.
store_project_of :: proc(s:^store.Store,repo:Repo_Id) -> (project,org:Log_Id,ok:bool) {
    id,e:=store.ref_get(s,MACHINE_NAMESPACE,machine_repo_name(repo))
    if e!=.None {return}
    l:Log
    log_init(&l,id,context.temp_allocator)
    if log_open(s,&l,id,.Project)!=.None || len(l.items)==0 {return}
    org,_=project_org(&l)
    return id,org,org!={}
}

machine_member_add :: proc(m:^Machine,org,user:Log_Id,role:Role) -> Error {
    if !role_valid(role) {return machine_fail(m,.Invalid_Argument,"a member's role is reader, writer or admin")}
    _,e:=machine_org_append(m,org,.Member_Add,body_make(Member_Body{user=user,role=role}))
    return e
}

machine_member_remove :: proc(m:^Machine,org,user:Log_Id) -> Error {
    _,e:=machine_org_append(m,org,.Member_Remove,body_make(Subject_Body{subject=user}))
    return e
}

machine_role_set :: proc(m:^Machine,org,user:Log_Id,role:Role) -> Error {
    if !role_valid(role) {return machine_fail(m,.Invalid_Argument,"a member's role is reader, writer or admin")}
    _,e:=machine_org_append(m,org,.Role_Set,body_make(Member_Body{user=user,role=role}))
    return e
}

machine_owner_transfer :: proc(m:^Machine,org,user:Log_Id) -> Error {
    _,e:=machine_org_append(m,org,.Owner_Transfer,body_make(Subject_Body{subject=user}))
    return e
}

machine_node_add :: proc(m:^Machine,org:Log_Id,node:Key,dh:Dh_Key,modes:Node_Modes,addresses:[]net.Address) -> Error {
    list:=make([dynamic]Node_Address,context.temp_allocator)
    for a in addresses {
        if n,ok:=node_address_of(a);ok && len(list)<NODE_ADDRESSES_MAX {append(&list,n)}
    }
    if len(list)==0 {return machine_fail(m,.Invalid_Argument,"a node needs an IPv4 or IPv6 address members reach it at")}
    body:=body_make(Node_Add_Body{node=node,dh=dh,modes=modes,addresses=u8(len(list))},slice.to_bytes(list[:]))
    _,e:=machine_org_append(m,org,.Node_Add,body)
    return e
}

machine_node_remove :: proc(m:^Machine,org:Log_Id,node:Key) -> Error {
    _,e:=machine_org_append(m,org,.Node_Remove,body_make(Node_Remove_Body{node=node}))
    return e
}

machine_policy_set :: proc(m:^Machine,org,project:Log_Id,bookmark:string,approvals:int,checks:[]string) -> Error {
    if approvals<0 || approvals>255 || len(checks)>CHECKS_MAX {return machine_fail(m,.Invalid_Argument,"a policy asks 0 to 255 approvals and at most 32 checks")}
    if !bookmark_name_valid(bookmark) || len(bookmark)>255 {return machine_fail(m,.Invalid_Argument,"a bookmark's name is 1 to 255 bytes of text without spaces")}
    texts:=make([dynamic]string,context.temp_allocator)
    append(&texts,bookmark)
    append(&texts,..checks)
    // The moves the project's log holds now keep the rules they were made under.
    l:Log
    log_init(&l,project,context.temp_allocator)
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if log_open(&m.store,&l,project,.Project)==.None {log_heads(&l,&heads)}
    if len(heads)>ENTRY_PARENTS_MAX {resize(&heads,ENTRY_PARENTS_MAX)}
    body:=body_make(Policy_Set_Body{project=project,approvals=u8(approvals),checks=u8(len(checks)),heads=u8(len(heads))},slice.to_bytes(heads[:]),strings_tail(..texts[:]))
    _,e:=machine_org_append(m,org,.Policy_Set,body)
    return e
}

// Records a scope of private paths of a project, and makes its keyring with
// the first epoch key wrapped for every device that may read it.
machine_scope_add :: proc(m:^Machine,org,project:Log_Id,patterns:[]string,readers:Role,history:bool) -> (scope:Scope_Id,error:Error) {
    if len(patterns)==0 || len(patterns)>PATTERNS_MAX {return {},machine_fail(m,.Invalid_Argument,"a scope has 1 to 64 patterns")}
    if !role_valid(readers) && readers!=.Owner {return {},machine_fail(m,.Invalid_Argument,"a scope's readers are a role: reader, writer, admin or owner")}
    scope=random_id(Scope_Id)
    tail:=make([dynamic]u8,context.temp_allocator)
    for p in patterns {
        if len(p)==0 || len(p)>255 {return {},machine_fail(m,.Invalid_Argument,"a pattern is 1 to 255 bytes")}
        append(&tail,u8(len(p)))
        append(&tail,..transmute([]u8)p)
    }
    body:=body_make(Scope_Add_Body{project=project,scope=scope,readers=readers,history=b8(history),patterns=u8(len(patterns))},tail[:])
    machine_org_append(m,org,.Scope_Add,body) or_return
    o:Org_State
    machine_org_open(m,org,&o) or_return
    defer org_state_destroy(&o)
    l:Log
    log_init(&l,{},context.temp_allocator)
    k:Keyring_Fold
    device:=machine_overlay_device(m)
    defer crypto.zero_explicit(&device,size_of(device))
    if e:=keyring_create(&k,&l,&o.fold,project,scope,&device,machine_now(),context.temp_allocator);e!=.None {
        return scope,machine_fail(m,e,"the scope's keyring does not start: a writer of the project makes it")
    }
    machine_log_save(m,&l) or_return
    return scope,.None
}

machine_scope_remove :: proc(m:^Machine,org,project:Log_Id,scope:Scope_Id) -> Error {
    _,e:=machine_org_append(m,org,.Scope_Remove,body_make(Scope_Remove_Body{project=project,scope=scope}))
    return e
}

// The keyrings of the org's scopes this store holds, folded against o.
machine_keyrings :: proc(s:^store.Store,o:^Org_State,out:^[dynamic]^Keyring_Fold,allocator:=context.allocator) -> Error {
    refs,e:=store.ref_list(s,LOG_NAMESPACE,context.temp_allocator)
    if e!=.None {return store_error(e)}
    for r in refs {
        id,ok:=store.parse_hex(r.name)
        if !ok || !keyring_of_org(s,&o.fold,id,r.hash) {continue}
        l,le:=new(Log,allocator)
        if le!=nil {return .Out_Of_Memory}
        log_init(l,id,allocator)
        if _,load:=log_load(s,l,r.hash,false);load!=.None {continue}
        k,ke:=new(Keyring_Fold,allocator)
        if ke!=nil {return .Out_Of_Memory}
        if keyring_fold(k,l,&o.fold,allocator)!=.None {continue}
        append(out,k)
    }
    return .None
}

// Signs a grant of rights to the holder of subject_dh and records it in the
// org's log; the grant's bytes are what the holder presents.
machine_grant :: proc(m:^Machine,org:Log_Id,subject_dh:Dh_Key,subject_key:Key,rights:Rights,project:Log_Id,path:string,days:int,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if days<1 || days>30 {return nil,machine_fail(m,.Invalid_Argument,"a grant lasts 1 to 30 days")}
    if len(path)>GRANT_PATH_MAX {return nil,machine_fail(m,.Invalid_Argument,"a grant's path scope is at most 1024 bytes")}
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    l:Log
    log_init(&l,org,context.temp_allocator)
    if e:=log_open(&m.store,&l,org,.Org);e!=.None {return nil,machine_fail(m,e,"this store has no log of that org")}
    log_heads(&l,&heads)
    if len(heads)==0 {return nil,machine_fail(m,.Corrupt,"the org's log has no head")}
    now:=machine_now()
    g:=Grant{head={magic=KAI_MAGIC,version=VERSION,rights=rights,org=org,org_head=heads[0],issuer=m.identity.key,subject_dh=subject_dh,subject_key=subject_key,project=project,not_before=now,not_after=now+i64(days)*24*3600*1_000_000_000,path_len=u16(len(path))},path=path}
    bytes=grant_encode(&g,&m.identity,allocator) or_return
    if _,e:=machine_org_append(m,org,.Grant,bytes);e!=.None {
        delete(bytes,allocator)
        return nil,e
    }
    return bytes,.None
}

machine_grant_revoke :: proc(m:^Machine,org:Log_Id,grant:[]u8) -> Error {
    _,e:=machine_org_append(m,org,.Grant_Revoke,body_make(Subject_Body{subject=store.address_of_bytes(grant)}))
    return e
}

// Publishes this device's bookmarks of a project, signed, and tells the mesh.
// In a public project the publish scanner checks what each bookmark adds.
machine_publish_refs :: proc(m:^Machine,project:Log_Id,refs:[]Bookmark_Ref) -> Error {
    l:Log
    log_init(&l,project,context.temp_allocator)
    if log_open(&m.store,&l,project,.Project)==.None {
        if org,public:=project_org(&l);public {
            o:Org_State
            if e:=machine_org_open(m,org,&o);e!=.None {return e}
            held,_,_:=device_refs_get(&m.store,project,m.identity.key,context.temp_allocator)
            for r in refs {
                before:Revision
                for h in held.refs {
                    if h.name==r.name {before=h.target}
                }
                if before==r.target {continue}
                machine_publish_check(m,&o.fold,project,true,before,r.target) or_return
            }
        }
    }
    if _,e:=device_refs_publish(&m.store,project,&m.identity,refs,machine_now());e!=.None {
        return machine_fail(m,e,"the bookmarks do not publish: names are [a-z0-9._-] and a store this user may write")
    }
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    machine_tell(m,refs_namespace(project,&ns),refs_name(m.identity.key,&name))
    return .None
}

// Publishes what this device built for key, signed, and tells the mesh.
machine_publish_ddc :: proc(m:^Machine,org:Log_Id,key,output:store.Hash,tainted:[]Scope_Id) -> (nondeterministic:bool,error:Error) {
    nondeterministic,error=ddc_publish(&m.store,org,&m.identity,key,output,tainted,machine_now())
    if error!=.None {return false,machine_fail(m,error,"the derived data does not publish to the store")}
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    machine_tell(m,ddc_namespace(org,&ns),store.hex(key,&name))
    return
}

// The name a device is made with, in buffer: given, or else this machine's
// host name up to its first dot, of letters, digits, - and _ alone and
// NAME_MAX bytes at most ("device" when the system gives none).
device_name_of :: proc(given:string,buffer:^[NAME_MAX]u8) -> string {
    buffer^={}
    if given!="" {
        if len(given)>NAME_MAX {return given}
        return string(buffer[:copy(buffer[:],given)])
    }
    host:[256]u8
    n:=0
    for c in transmute([]u8)host_name(host[:]) {
        if c=='.' || n==NAME_MAX {break}
        if (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='-' || c=='_' {
            buffer[n]=c
            n+=1
        }
    }
    if n==0 {n=copy(buffer[:],"device")}
    return string(buffer[:n])
}
