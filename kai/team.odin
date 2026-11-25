package kai

import "base:runtime"
import "core:crypto"
import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"
import net "mirai:net"
import "mirai:std/blake3"
import "mirai:store"

// What a team does through the logs of one machine: an org seen whole, a
// member who leaves, a device revoked, the recovery key rotated, grants
// carried to their holders, public paths, scopes rotated, shared bookmarks,
// proposals and the verification of a project. Each operation reads the logs
// from the store, appends one entry this device signs, keeps it only when the
// fold takes it and saves it, which tells the mesh (Machine.changed); m.why
// then says what failed and how to fix it. The CLI and the editor call these
// alike; what needs a workspace is in cook/kai.

MACHINE_GRANT_PREFIX :: "grant-" // + the hex of a grant's address: the grant text this machine holds
GRANT_TEXT_VERSION :: 2
@(private) GRANT_TEXT_HEAD :: 1+32
@(private) GRANT_BYTES_MAX :: size_of(Grant_Head)+GRANT_PATH_MAX+size_of(Signature)
@(private) GRANT_TEXT_BYTES_MAX :: GRANT_TEXT_HEAD+1+TICKET_ADDRESSES*CARRIED_ADDRESS+GRANT_BYTES_MAX+4
GRANT_TEXT_MAX :: (GRANT_TEXT_BYTES_MAX*4+2)/3 // the longest a grant's text is
@(private) LABEL_GRANT_TEXT :: "kai-1/grant-text"

// --- Names the logs give ---

// The name the genesis of a user's log gives the user.
user_name :: proc(f:^User_Fold) -> string {
    k:=log_find(f.log,f.log.id)
    if k<0 {return ""}
    entry:=&f.log.items[k].entry
    if entry.type==.Passkey_Genesis {
        _,_,_,name,_:=passkey_parts(entry.body)
        return string(name)
    }
    _,tail,_:=body_head(entry.body,User_Genesis_Body)
    return string(tail)
}

LABEL_DEVICE_LINK :: "kai-1/device-link"

// The eight digits a device being linked to a user and the browser that
// links it both show, from the device's key, for the person to compare.
device_link_code :: proc(device:Key,buffer:^[9]u8) -> string {
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,transmute([]u8)string(LABEL_DEVICE_LINK))
    d:=device
    blake3.update(&h,d[:])
    sum:=blake3.final(&h)
    n:=(u32(sum[0])|u32(sum[1])<<8|u32(sum[2])<<16|u32(sum[3])<<24)%100_000_000
    for k:=8;k>0;k-=1 {
        at:=k>4?k:k-1
        buffer[at]=u8('0'+n%10)
        n/=10
    }
    buffer[4]='-'
    return string(buffer[:])
}

// The name of device k of a user: what its Device_Add or the genesis calls
// it, or the first hex digits of its key when the genesis names none.
device_name :: proc(f:^User_Fold,k:int,allocator:=context.temp_allocator) -> string {
    d:=f.devices[k]
    entry:=&f.log.items[d.added].entry
    #partial switch entry.type {
    case .Device_Add:
        _,tail,_:=body_head(entry.body,Device_Add_Body)
        return string(tail)
    case .User_Genesis:
        head,_,_:=body_head(entry.body,User_Genesis_Body)
        if n:=len(genesis_device_name(&head));n>0 {
            at:=int(offset_of(User_Genesis_Body,device_name))
            return string(entry.body[at:at+n])
        }
    }
    key:=d.key
    buffer,e:=make([]u8,8,allocator)
    if e!=nil {return ""}
    return hex_text(key[:4],buffer)
}

// The name the genesis of an org's, a project's or a proposal's log gives it:
// a proposal's title.
log_title :: proc(l:^Log) -> string {
    k:=log_find(l,l.id)
    if k<0 {return ""}
    e:=&l.items[k].entry
    #partial switch e.type {
    case .Org_Genesis:
        _,tail,_:=body_head(e.body,Org_Genesis_Body)
        return string(tail)
    case .Project_Genesis:
        _,tail,_:=body_head(e.body,Project_Genesis_Body)
        return string(tail)
    case .Proposal_Open:
        b,tail,_:=body_head(e.body,Proposal_Open_Body)
        return string(tail[b.target:][:b.title])
    }
    return ""
}

// The text of a proposal, after its title.
proposal_text :: proc(l:^Log) -> string {
    k:=log_find(l,l.id)
    if k<0 || l.items[k].entry.type!=.Proposal_Open {return ""}
    b,tail,_:=body_head(l.items[k].entry.body,Proposal_Open_Body)
    return string(tail[int(b.target)+int(b.title):])
}

// The fold of the user of id among those of o; nil when this store has none.
org_state_user :: proc(o:^Org_State,user:Log_Id) -> ^User_Fold {
    for u in o.users {
        if u.log.id==user {return u}
    }
    return nil
}

// The user a device belongs to among those of o, and its index there.
org_state_device :: proc(o:^Org_State,device:Key) -> (user:^User_Fold,index:int) {
    for u in o.users {
        if k:=user_device_index(u,device);k>=0 {return u,k}
    }
    return nil,-1
}

// A device as <handle>/<device>: its user's name and its own.
device_display :: proc(o:^Org_State,device:Key,allocator:=context.temp_allocator) -> string {
    u,k:=org_state_device(o,device)
    d:=device
    buffer:[8]u8
    parts:=u==nil?[3]string{"?","/",hex_text(d[:4],buffer[:])}:[3]string{user_name(u),"/",device_name(u,k,allocator)}
    text,e:=strings.concatenate(parts[:],allocator)
    if e!=nil {return ""}
    return text
}

// The name a pairing this machine joins gives the other end: <handle>/<device>
// as its user's log names them, or, on a device with no user yet, device, the
// name the user's log will give it (this machine's host name when empty). NAME_MAX bytes at most, cut between
// characters.
machine_pair_name :: proc(m:^Machine,device:string,allocator:=context.temp_allocator) -> (name:string,error:Error) {
    if m.user=={} {
        buffer:[NAME_MAX]u8
        named:=device_name_of(device,&buffer)
        if !name_valid(named) {return "",machine_fail(m,.Invalid_Argument,"a device with no user joins with the name its user will know it by: 1 to 64 bytes of text, as laptop")}
        text,e:=strings.clone(named,allocator)
        if e!=nil {return "",machine_fail(m,.Out_Of_Memory,"no memory for the name")}
        return text,.None
    }
    l:Log
    f:User_Fold
    machine_user_open(m,&l,&f) or_return
    defer user_fold_destroy(&f)
    k:=user_device_index(&f,m.identity.key)
    if k<0 {return "",machine_fail(m,.Invalid_Argument,"this device is not in its user's log: pair it again")}
    text,e:=strings.concatenate({user_name(&f),"/",device_name(&f,k)},allocator)
    if e!=nil {return "",machine_fail(m,.Out_Of_Memory,"no memory for the name")}
    cut:=min(len(text),NAME_MAX)
    for cut>0 && cut<len(text) && text[cut]&0xC0==0x80 {cut-=1}
    return text[:cut],.None
}

// Who a pairing request comes from, as the person who answers it reads it:
// <handle>/<device>. A second device of this machine's user calls itself by
// its own name alone, which goes after the user's.
pair_request_who :: proc(m:^Machine,request:Pair_Request,allocator:=context.temp_allocator) -> string {
    parts:=[3]string{"","",request.name}
    l:Log
    f:User_Fold
    opened:=request.mode==.Device && m.user!={} && machine_user_open(m,&l,&f)==.None
    if opened {parts[0],parts[1]=user_name(&f),"/"}
    text,e:=strings.concatenate(parts[:],allocator)
    if opened {user_fold_destroy(&f)}
    if e!=nil {return ""}
    return text
}

// The member of the org text names: its user's name, or a prefix of the hex
// of its id.
machine_member :: proc(m:^Machine,org:Log_Id,text:string) -> (user:Log_Id,error:Error) {
    o:Org_State
    machine_org_open(m,org,&o) or_return
    defer org_state_destroy(&o)
    lower:=strings.to_lower(text,context.temp_allocator)
    found:=0
    for member in o.fold.members {
        id:=member.user
        hex:[64]u8
        match:=len(lower)>=4 && strings.has_prefix(store.hex(id,&hex),lower)
        if u:=org_state_user(&o,id);u!=nil && user_name(u)==text {match=true}
        if match {
            user=id
            found+=1
        }
    }
    if found==1 {return user,.None}
    if found==0 {return {},machine_fail(m,.Invalid_Argument,"no member of the org has that name or id: mirai kai org list names them")}
    return {},machine_fail(m,.Invalid_Argument,"several members have that name: give a prefix of the id mirai kai org list shows")
}

// The org text names among those this machine serves: its name or a prefix
// of the hex of its id; the only one when text is empty.
machine_org_find :: proc(m:^Machine,text:string) -> (org:Log_Id,error:Error) {
    lower:=strings.to_lower(text,context.temp_allocator)
    found:=0
    for id in m.orgs {
        hex:[64]u8
        match:=text=="" || strings.has_prefix(store.hex(id,&hex),lower)
        if !match {
            l:Log
            log_init(&l,id,context.temp_allocator)
            match=log_open(&m.store,&l,id,.Org)==.None && log_title(&l)==text
        }
        if match {
            org=id
            found+=1
        }
    }
    if found==1 {return org,.None}
    if found==0 {return {},machine_fail(m,.Invalid_Argument,"this machine serves no such org: mirai kai org new makes one, or pair as a member")}
    return {},machine_fail(m,.Invalid_Argument,"this machine serves several orgs: --org gives the name or a prefix of the id of one")
}

// The project of an org this machine serves that text names: its name or a
// prefix of the hex of its id.
machine_project_find :: proc(m:^Machine,text:string) -> (project,org:Log_Id,error:Error) {
    lower:=strings.to_lower(text,context.temp_allocator)
    found:=0
    for id in m.orgs {
        o:Org_State
        if org_state_load(&m.store,id,&o,context.temp_allocator)!=.None {continue}
        for p in o.fold.projects {
            pid:=p.id
            hex:[64]u8
            match:=len(lower)>=4 && strings.has_prefix(store.hex(pid,&hex),lower)
            if !match {
                l:Log
                log_init(&l,pid,context.temp_allocator)
                match=log_open(&m.store,&l,pid,.Project)==.None && log_title(&l)==text
            }
            if match {
                project,org=pid,id
                found+=1
            }
        }
    }
    if found==1 {return project,org,.None}
    if found==0 {return {},{},machine_fail(m,.Invalid_Argument,"no project of the orgs this machine serves has that name or id: mirai kai org list names them")}
    return {},{},machine_fail(m,.Invalid_Argument,"several projects have that name: give a prefix of the id mirai kai org list shows")
}

// --- Members and devices ---

// Leaves the org: this device's user is no member any more and the machine
// stops serving it. The owner gives the org to another member first.
machine_leave :: proc(m:^Machine,org:Log_Id) -> Error {
    o:Org_State
    machine_org_open(m,org,&o) or_return
    defer org_state_destroy(&o)
    role:=m.user=={}?Role.None:org_role(&o.fold,m.user)
    if role==.Owner {return machine_fail(m,.Unauthorized,"the owner does not leave its org: give it to a member first with mirai kai org transfer")}
    if role!=.None {machine_member_remove(m,org,m.user) or_return}
    return machine_org_leave(m,org)
}

@(private)
machine_user_open :: proc(m:^Machine,l:^Log,f:^User_Fold) -> Error {
    if m.user=={} {return machine_fail(m,.Invalid_Argument,"this device has no user: mirai kai identity makes one")}
    log_init(l,m.user,context.temp_allocator)
    if e:=log_open(&m.store,l,m.user,.User);e!=.None {return machine_fail(m,e,"this device's User_Log is not in its store: pair the device again")}
    if e:=user_fold(f,l,context.temp_allocator);e!=.None {return machine_fail(m,e,"this device's User_Log does not fold: fetch it again from another device of the user")}
    return .None
}

// The device of this machine's user that text names: its name or a prefix of
// the hex of its key.
machine_device_find :: proc(m:^Machine,text:string) -> (device:Key,error:Error) {
    l:Log
    f:User_Fold
    machine_user_open(m,&l,&f) or_return
    defer user_fold_destroy(&f)
    lower:=strings.to_lower(text,context.temp_allocator)
    found:=0
    for d,k in f.devices {
        key:=d.key
        buffer:[64]u8
        if device_name(&f,k)==text || (len(lower)>=4 && strings.has_prefix(hex_text(key[:],buffer[:]),lower)) {
            device=d.key
            found+=1
        }
    }
    if found==1 {return device,.None}
    if found==0 {return {},machine_fail(m,.Invalid_Argument,"the user has no device of that name or key: mirai kai org list names its devices")}
    return {},machine_fail(m,.Invalid_Argument,"several devices have that name: give a prefix of the key mirai kai org list shows")
}

// Revokes a device of this device's user: what it signs from now on counts
// nowhere, and what it signed stays, up to the heads every log of this store
// it signed in has now.
machine_device_revoke :: proc(m:^Machine,device:Key) -> Error {
    l:Log
    f:User_Fold
    machine_user_open(m,&l,&f) or_return
    defer user_fold_destroy(&f)
    k:=user_device_index(&f,device)
    if k<0 {return machine_fail(m,.Invalid_Argument,"the user has no such device: mirai kai org list names its devices")}
    if f.devices[k].revoked {return machine_fail(m,.Invalid_Argument,"that device is revoked already")}
    address,e:=log_append(&l,.Device_Revoke,revoke_body(device),&m.identity,machine_now())
    if e!=.None {return machine_fail(m,e,"the revocation does not sign")}
    user_fold_destroy(&f)
    user_fold(&f,&l,context.temp_allocator)
    if at:=log_find(&l,address);at<0 || !f.valid[at] {return machine_fail(m,.Unauthorized,"this device is revoked itself: a device of the user that is not, or the recovery key, revokes")}
    machine_log_save(m,&l) or_return
    for org in m.orgs {
        o:Org_State
        if org_state_load(&m.store,org,&o,context.temp_allocator)!=.None {continue}
        defer org_state_destroy(&o)
        machine_witness(m,&o,l.id,address) or_return
    }
    return .None
}

// Writes a Witness of the removal at removal, of the log removal_log, in each
// log of the org this store holds that witnesses_due says lacks one: the
// org's own for a device's revocation, and every project, open proposal and
// keyring where a key it affects signed or held a right. Its parents are the
// heads this device knows, so what the removed keys signed before stands
// there; a log where this device holds no right takes none of it, and is
// left to a device that does.
machine_witness :: proc(m:^Machine,o:^Org_State,removal_log:Log_Id,removal:store.Hash) -> Error {
    org:=o.log.id
    body:=witness_body(removal_log,removal)
    user,ctx:=machine_user_head(m),org_context(&o.fold,m.user)
    due:=make([dynamic]Witness_Due,context.temp_allocator)
    lacks :: proc(o:^Org_State,l:^Log,removal:store.Hash,due:^[dynamic]Witness_Due) -> bool {
        clear(due)
        if witnesses_due(&o.fold,l,due)!=.None {return false}
        for d in due {
            if d.removal==removal {return true}
        }
        return false
    }
    if removal_log!=org && lacks(o,&o.log,removal,&due) {
        if _,e:=log_append(&o.log,.Witness,body,&m.identity,machine_now(),user);e!=.None {return machine_fail(m,e,"the witness does not sign")}
        machine_log_save(m,&o.log) or_return
    }
    refs,e:=store.ref_list(&m.store,LOG_NAMESPACE,context.temp_allocator)
    if e!=.None {return .None}
    for r in refs {
        id,ok:=store.parse_hex(r.name)
        if !ok || id==org || !log_of_org(&m.store,&o.fold,id,r.hash) {continue}
        l:=new(Log,context.temp_allocator)
        log_init(l,id,context.temp_allocator)
        if _,le:=log_load(&m.store,l,r.hash,false);le!=.None {continue}
        if l.kind==.Proposal {
            f:Proposal_Fold
            if proposal_fold(&f,l,&o.fold,context.temp_allocator)!=.None || f.status!=.Open {continue}
        }
        if !lacks(o,l,removal,&due) {continue}
        if _,ae:=log_append(l,.Witness,body,&m.identity,machine_now(),user,ctx);ae!=.None {return machine_fail(m,ae,"the witness does not sign")}
        machine_log_save(m,l) or_return
    }
    return .None
}

// Whether the log whose index is at address is a Project, Proposal or
// Keyring log of the org: its genesis, read alone, says.
log_of_org :: proc(s:^store.Store,org:^Org_Fold,id:Log_Id,address:store.Hash) -> bool {
    head,_,e:=log_index_read(s,address)
    if e!=.None || head.id!=id {return false}
    #partial switch head.kind {
    case .Project: return org_project_index(org,id)>=0
    case .Proposal: return proposal_of_org(s,org,id,address)
    case .Keyring: return keyring_of_org(s,org,id,address)
    }
    return false
}

// Replaces the recovery key of this device's user: recovery is the one it
// has now, as it was printed; the new one is in the text returned, once. A
// user born of a passkey has none until a device of it sets the first:
// recovery is then empty and this device signs it.
machine_recovery_rotate :: proc(m:^Machine,recovery:string,buffer:^[RECOVERY_TEXT]u8) -> (text:string,error:Error) {
    l:Log
    f:User_Fold
    machine_user_open(m,&l,&f) or_return
    defer user_fold_destroy(&f)
    old:Identity
    defer crypto.zero_explicit(&old,size_of(old))
    signer:=&old
    if f.recovery=={} {
        if recovery!="" {return "",machine_fail(m,.Invalid_Argument,"the user has no recovery key yet: run it without one, and this device sets the first")}
        signer=&m.identity
    } else {
        seed,why:=recovery_decode(recovery)
        if why!="" {return "",machine_fail(m,.Invalid_Argument,why)}
        old.seed=seed
        crypto.zero_explicit(&seed,size_of(seed))
        identity_derive(&old)
        if f.recovery!=old.key {return "",machine_fail(m,.Unauthorized,"that is not the user's recovery key now: give the newest one printed")}
    }
    r:=identity_make()
    defer crypto.zero_explicit(&r,size_of(r))
    rd:=recovery_device(&r)
    defer crypto.zero_explicit(&rd,size_of(rd))
    kem,made:=kem_public(&rd.kem_seed)
    if !made {return "",machine_fail(m,.Invalid_Argument,"the new recovery key makes no ML-KEM key: rotate again")}
    body:=Recovery_Rotate_Body{recovery=r.key,dh=rd.dh,kem=kem,proof=device_proof(&r,transmute([32]u8)l.id,rd.dh,blake3.hash(kem[:]))}
    address,e:=log_append(&l,.Recovery_Rotate,body_make(body),signer,machine_now())
    if e!=.None {return "",machine_fail(m,e,"the rotation does not sign")}
    user_fold_destroy(&f)
    user_fold(&f,&l,context.temp_allocator)
    if k:=log_find(&l,address);k<0 || !f.valid[k] {return "",machine_fail(m,.Unauthorized,"this device may not set the user's recovery key: a device of the user that is not revoked sets the first one")}
    machine_log_save(m,&l) or_return
    return recovery_encode(r.seed,buffer),.None
}

// The user whose id text gives, whole or by its first hex digits (eight at
// least), among the users' logs the store holds; Missing while none matches.
machine_user_find :: proc(m:^Machine,text:string) -> (user:Log_Id,error:Error) {
    lower:=strings.to_lower(strings.trim_space(text),context.temp_allocator)
    if len(lower)<8 {return {},machine_fail(m,.Invalid_Argument,"a user's id is 64 hex digits, or its first eight at least")}
    refs,e:=store.ref_list(&m.store,USER_NAMESPACE,context.temp_allocator)
    if e!=.None && e!=.Missing {return {},machine_fail(m,store_error(e),"the store's users do not list")}
    found:=0
    for r in refs {
        if !strings.has_prefix(r.name,lower) {continue}
        id,ok:=store.parse_hex(r.name)
        if !ok {continue}
        user=id
        found+=1
    }
    if found==1 {return user,.None}
    if found>1 {return {},machine_fail(m,.Invalid_Argument,"several users' ids start so: give more of the id")}
    return {},machine_fail(m,.Missing,"no user of that id is in this store yet: join a recovery pairing a machine of one of the user's orgs offers (mirai kai pair offer recover --org <org>) and let the agent fetch it")
}

// What a recovery did to the private scopes its user reads.
Recover_Report :: struct {
    opened:int,  // scopes this device reads again through the recovery key's envelopes
    waiting:int, // orgs and scopes whose logs or envelopes are not in the store yet: recover again once the agent fetched them
    lost:[dynamic]Scope_Lost, // in the temp allocator
}

// A scope whose newest key no key left opened: its files up to epoch are out
// of anyone's reach, and the epoch after is wrapped for this device.
Scope_Lost :: struct {org,project:Log_Id,scope:Scope_Id,epoch:u32,text:string} // text: its patterns and project, in the temp allocator

// Recovers the user of id onto this device, which has none, after its devices
// were lost: recovery is the user's recovery key as it was printed, and the
// user's log must be in the store (a recovery pairing brings it: mirai kai
// pair offer recover on a machine of one of the user's orgs). The recovery
// key signs this device into the log and revokes every device still active;
// passkeys stay. The revocations are witnessed in the logs of the orgs this
// store holds, and the agents of the others witness them when they fold them.
// Then, in each org whose logs are here, the recovery key's envelopes give
// this device the keys of the scopes the user reads, and each starts a new
// epoch (keyring_recover). Run again on the device it recovered onto, with the
// same key, it does that last part alone, for what the agent fetched since;
// report says what it did.
machine_recover :: proc(m:^Machine,user:Log_Id,recovery:string,device:="",report:^Recover_Report=nil) -> Error {
    if m.user!={} && m.user!=user {return machine_fail(m,.Invalid_Argument,"this device belongs to another user already: a user is recovered onto a device that has none")}
    own:Recover_Report
    report:=report
    if report==nil {report=&own}
    report^={lost=make([dynamic]Scope_Lost,context.temp_allocator)}
    seed,why:=recovery_decode(strings.trim_space(recovery))
    defer crypto.zero_explicit(&seed,size_of(seed))
    if why!="" {return machine_fail(m,.Invalid_Argument,why)}
    r:=Identity{seed=seed}
    defer crypto.zero_explicit(&r,size_of(r))
    if !identity_derive(&r) {return machine_fail(m,.Invalid_Argument,"the recovery key does not make a signing key: type it again")}
    l:Log
    log_init(&l,user,context.temp_allocator)
    if e:=log_open(&m.store,&l,user,.User);e!=.None {
        return machine_fail(m,e,"the user's log is not in this store yet: on a machine of one of the user's orgs run mirai kai pair offer recover --org <org>, join it here and let the agent fetch it")
    }
    f:User_Fold
    if e:=user_fold(&f,&l,context.temp_allocator);e!=.None {return machine_fail(m,e,"the user's log does not fold: let the agent fetch it again")}
    defer user_fold_destroy(&f)
    if f.recovery=={} {return machine_fail(m,.Unauthorized,"the user has no recovery key: a user born of a passkey links a device from the browser instead")}
    if f.recovery!=r.key {return machine_fail(m,.Unauthorized,"that recovery key reads but is not this user's now: give the newest one printed for this user, and check the user's id")}
    written:=make([dynamic]store.Hash,context.temp_allocator)
    if m.user=={} {
        if user_device_index(&f,m.identity.key)>=0 {return machine_fail(m,.Invalid_Argument,"this device was a device of the user and is revoked: recover onto a new store")}
        name:[NAME_MAX]u8
        named:=device_name_of(device,&name)
        if !name_valid(named) {return machine_fail(m,.Invalid_Argument,"a device's name is 1 to 64 bytes of text, as laptop: give another")}
        body:=body_make(Device_Add_Body{device=m.identity.key,dh=Dh_Key(m.dh.public),kem=machine_kem_public(m),proof=device_proof(&m.identity,transmute([32]u8)user,Dh_Key(m.dh.public),machine_kem_hash(m))},transmute([]u8)named)
        add,e:=log_append(&l,.Device_Add,body,&r,machine_now())
        if e!=.None {return machine_fail(m,e,"the device's entry does not sign")}
        append(&written,add)
        for d in f.devices {
            if d.revoked {continue}
            address,re:=log_append(&l,.Device_Revoke,revoke_body(d.key),&r,machine_now())
            if re!=.None {return machine_fail(m,re,"a revocation does not sign")}
            append(&written,address)
        }
        user_fold_destroy(&f)
        user_fold(&f,&l,context.temp_allocator)
        for address in written {
            if k:=log_find(&l,address);k<0 || !f.valid[k] {return machine_fail(m,.Unauthorized,"the user's log refuses the recovery: let the agent fetch the user's log again, a newer recovery key may be in it")}
        }
        machine_log_save(m,&l) or_return
        machine_user_set(m,user) or_return
        machine_tell(m,MACHINE_NAMESPACE,MACHINE_USER)
    } else if !user_device_active(&f,m.identity.key) {
        return machine_fail(m,.Unauthorized,"this device is revoked: recover onto a new store")
    }
    rd:=recovery_device(&r)
    defer crypto.zero_explicit(&rd,size_of(rd))
    for org in m.orgs {
        o:Org_State
        if org_state_load(&m.store,org,&o,context.temp_allocator)!=.None {
            report.waiting+=1
            continue
        }
        defer org_state_destroy(&o)
        if len(written)>1 {
            for address in written[1:] {machine_witness(m,&o,l.id,address) or_return}
        }
        machine_recover_scopes(m,&o,&rd,report) or_return
    }
    return .None
}

// The scopes of the org o the user reads, after its devices were lost: what
// keyring_recover makes of each, with report counting them.
@(private)
machine_recover_scopes :: proc(m:^Machine,o:^Org_State,recovery:^Overlay_Device,report:^Recover_Report) -> Error {
    device:=machine_overlay_device(m)
    defer crypto.zero_explicit(&device,size_of(device))
    rings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
    machine_keyrings(&m.store,o,&rings,context.temp_allocator) or_return
    scopes: for sc in o.fold.scopes {
        if !device_reads(&o.fold,sc,&device) {continue}
        for k in rings {
            if k.project!=sc.project || k.scope!=sc.scope {continue}
            count,epoch:=len(k.log.items),k.epoch
            outcome,e:=keyring_recover(k,&device,recovery,machine_now())
            if e==.Missing {
                report.waiting+=1
                continue scopes
            }
            if e!=.None {return machine_fail(m,e,"a scope's keys do not wrap for this device: recover again once the agent fetched the org's logs")}
            if len(k.log.items)!=count {machine_log_save(m,k.log) or_return}
            switch outcome {
            case .Read:
            case .Opened: report.opened+=1
            case .Lost:
                patterns:=make([dynamic]string,context.temp_allocator)
                org_scope_patterns(&o.fold,sc,&patterns)
                project:="its project"
                p:Log
                log_init(&p,sc.project,context.temp_allocator)
                if log_open(&m.store,&p,sc.project,.Project)==.None {project=log_title(&p)}
                text:=fmt.tprintf("%s of %s",strings.join(patterns[:]," ",context.temp_allocator),project)
                append(&report.lost,Scope_Lost{o.log.id,sc.project,sc.scope,epoch,text})
            }
            continue scopes
        }
        report.waiting+=1
    }
    return .None
}

// The contexts this device signs an entry of l under: the head of its user's
// log, and for a Project, Proposal or Keyring log the org's entry its rights
// are judged at.
machine_entry_ctx :: proc(m:^Machine,l:^Log) -> (author_ctx,org_ctx:store.Hash) {
    author_ctx=machine_user_head(m)
    if !org_bound(l.kind) {return}
    org:Log_Id
    if g:=log_find(l,l.id);g>=0 {
        entry:=&l.items[g].entry
        #partial switch entry.type {
        case .Project_Genesis: org,_=project_org(l)
        case .Keyring_Genesis:
            b,_,_:=body_head(entry.body,Keyring_Genesis_Body)
            org=b.org
        case .Proposal_Open:
            b,_,_:=body_head(entry.body,Proposal_Open_Body)
            p:Log
            log_init(&p,b.project,context.temp_allocator)
            if log_open(&m.store,&p,b.project,.Project)==.None {
                org,_=project_org(&p)
            } else {
                // Without the project's log, the org that lists the project.
                for id in m.orgs {
                    o:Org_State
                    if org_state_load(&m.store,id,&o,context.temp_allocator)!=.None {continue}
                    if org_project_index(&o.fold,b.project)>=0 {org=id}
                    org_state_destroy(&o)
                }
            }
        }
    }
    if org=={} {return}
    o:Org_State
    if org_state_load(&m.store,org,&o,context.temp_allocator)!=.None {return}
    defer org_state_destroy(&o)
    org_ctx=org_context(&o.fold,m.user)
    return
}

// Whether this device's user has a recovery key: a user born of a passkey
// has none until a device sets one.
machine_user_recovered :: proc(m:^Machine) -> bool {
    l:Log
    f:User_Fold
    if machine_user_open(m,&l,&f)!=.None {return false}
    defer user_fold_destroy(&f)
    return f.recovery!={}
}

// Takes the User_Log a browser's passkey linked this device to, its entries
// verified: this device must be an active device of it. The machine then
// belongs to that user.
machine_user_linked :: proc(m:^Machine,user:Log_Id,entries:[][]u8) -> Error {
    if m.user!={} {return machine_fail(m,.Invalid_Argument,"this device belongs to a user already")}
    l:Log
    log_init(&l,user,context.temp_allocator)
    for bytes in entries {
        if _,e:=log_add(&l,bytes,true);e!=.None {return machine_fail(m,e,"an entry of the user's log does not hold: link the device again")}
    }
    f:User_Fold
    e:=user_fold(&f,&l,context.temp_allocator)
    defer user_fold_destroy(&f)
    if e!=.None || l.id!=user || !user_device_active(&f,m.identity.key) {return machine_fail(m,.Unauthorized,"the user's log does not name this device: link it again from the browser")}
    machine_log_save(m,&l) or_return
    return machine_user_set(m,user)
}

// Takes the log of an org this device's user is a member of, as the node it
// signed in to gave it, and serves the org: how a device linked from a
// browser comes to an org its user made on a node's web view afterwards. The
// org's Node_Add names where its node listens, which the agent reaches.
machine_org_take :: proc(m:^Machine,org:Log_Id,entries:[][]u8) -> Error {
    ul:Log
    uf:User_Fold
    machine_user_open(m,&ul,&uf) or_return
    defer user_fold_destroy(&uf)
    l:Log
    log_init(&l,{},context.temp_allocator)
    for bytes in entries {
        if _,e:=log_add(&l,bytes,true);e!=.None {return machine_fail(m,e,"an entry of the org's log does not hold: ask the node again")}
    }
    if l.id!=org || l.kind!=.Org {return machine_fail(m,.Invalid_Argument,"the node gave the log of another org than the one asked")}
    f:Org_Fold
    users:=[]^User_Fold{&uf}
    if e:=org_fold(&f,&l,users,context.temp_allocator);e!=.None {return machine_fail(m,e,"the org's log does not fold: ask the node again")}
    role:=org_role(&f,m.user)
    org_fold_destroy(&f)
    if role==.None {return machine_fail(m,.Unauthorized,"the org's log does not name this device's user as a member: an admin adds it first")}
    stored:Log
    log_init(&stored,org,context.temp_allocator)
    if log_open(&m.store,&stored,org,.Org)==.None {
        for item in l.items {
            if _,e:=log_add(&stored,item.bytes,false);e!=.None {return machine_fail(m,e,"the org's log in this store does not take the node's entries")}
        }
        machine_log_save(m,&stored) or_return
    } else {
        machine_log_save(m,&l) or_return
    }
    return machine_org_join(m,org)
}

// --- Grants ---

// The text a grant travels in to its holder: the grant, and the X25519 key
// and addresses of its issuer's agent, which the holder reaches first.
Grant_Text :: struct {
    grant:[]u8,
    issuer:Dh_Key,
    addresses:[TICKET_ADDRESSES]net.Address,
    address_count:int,
}

grant_text_encode :: proc(g:Grant_Text,allocator:=context.allocator) -> (text:string,error:Error) {
    if len(g.grant)>GRANT_BYTES_MAX {return "",.Too_Large}
    head:[GRANT_TEXT_HEAD]u8
    head[0]=GRANT_TEXT_VERSION
    issuer,addresses:=g.issuer,g.addresses
    copy(head[1:],issuer[:])
    scratch:[GRANT_TEXT_BYTES_MAX]u8
    out,e:=make([]u8,GRANT_TEXT_MAX,allocator)
    if e!=nil {return "",.Out_Of_Memory}
    return carried_encode(LABEL_GRANT_TEXT,head[:],addresses[:clamp(g.address_count,0,TICKET_ADDRESSES)],g.grant,scratch[:],out),.None
}

// The grant's text as grant_text_encode wrote it; its grant in allocator.
grant_text_decode :: proc(text:string,allocator:=context.allocator) -> (g:Grant_Text,ok:bool) {
    raw,e:=make([]u8,GRANT_TEXT_BYTES_MAX,allocator)
    if e!=nil {return}
    head,count,tail,read:=carried_decode(LABEL_GRANT_TEXT,text,GRANT_TEXT_HEAD,&g.addresses,raw)
    if !read || head[0]!=GRANT_TEXT_VERSION {return {},false}
    copy(g.issuer[:],head[1:])
    g.address_count,g.grant=count,tail
    return g,true
}

// Issues a grant of the org as machine_grant does and gives the text its
// holder loads: the grant with this machine's X25519 key and addresses, which
// its agent listens at.
machine_grant_issue :: proc(m:^Machine,org:Log_Id,subject_dh:Dh_Key,subject_key:Key,rights:Rights,project:Log_Id,path:string,days:int,addresses:[]net.Address,allocator:=context.allocator) -> (text:string,error:Error) {
    if rights=={} {return "",machine_fail(m,.Invalid_Argument,"a grant gives at least one right: read, write, ddc, check or relay")}
    if len(addresses)==0 {return "",machine_fail(m,.Invalid_Argument,"a grant's holder reaches this machine's agent first: mirai kai agent starts one")}
    bytes:=machine_grant(m,org,subject_dh,subject_key,rights,project,path,days,context.temp_allocator) or_return
    g:=Grant_Text{grant=bytes,issuer=Dh_Key(m.dh.public)}
    g.address_count=copy(g.addresses[:],addresses)
    return grant_text_encode(g,allocator)
}

// Takes a grant its issuer gave this machine: the store keeps its text, and
// the machine serves the grant's org, reaching first for the issuer.
machine_grant_load :: proc(m:^Machine,text:string) -> (grant:Grant,error:Error) {
    clean:=strings.trim_space(text)
    gt,ok:=grant_text_decode(clean,context.temp_allocator)
    if !ok {return {},machine_fail(m,.Corrupt,"the grant's text does not read: copy it again, whole")}
    g,e:=grant_decode(gt.grant)
    if e!=.None || !signature_valid(g.issuer,gt.grant[:len(gt.grant)-size_of(Signature)],g.signature) {return {},machine_fail(m,.Corrupt,"the grant does not read or is not signed by its issuer: ask for it again")}
    if g.subject_dh!=Dh_Key(m.dh.public) || (g.subject_key!={} && g.subject_key!=m.identity.key) {
        return {},machine_fail(m,.Unauthorized,"the grant is for another machine: give its issuer the subject mirai kai identity prints here")
    }
    if machine_now()>g.not_after {return {},machine_fail(m,.Expired,"the grant expired: ask its issuer for a new one")}
    object,pe:=store.put(&m.store,transmute([]u8)clean)
    if pe!=.None {return {},machine_fail(m,store_error(pe),"the store refused the grant: give this user access to the store")}
    name:=machine_grant_name(store.address_of_bytes(gt.grant))
    if se:=store.ref_set(&m.store,MACHINE_NAMESPACE,name,object);se!=.None {return {},machine_fail(m,store_error(se),"the store refused the grant's ref")}
    machine_tell(m,MACHINE_NAMESPACE,name)
    machine_org_join(m,g.org) or_return
    return g,.None
}

@(private)
machine_grant_name :: proc(address:store.Hash) -> string {
    buffer:=new([len(MACHINE_GRANT_PREFIX)+64]u8,context.temp_allocator)
    copy(buffer[:],MACHINE_GRANT_PREFIX)
    hex:[64]u8
    copy(buffer[len(MACHINE_GRANT_PREFIX):],store.hex(address,&hex))
    return string(buffer[:])
}

// A grant this machine holds, with what reaches its issuer.
Held_Grant :: struct {
    grant:Grant,
    address:store.Hash, // of the grant's bytes, as Grant_Revoke names it
    text:Grant_Text,
}

// The grants this machine holds, as machine_grant_load kept them; their bytes
// in allocator.
machine_grants_held :: proc(s:^store.Store,out:^[dynamic]Held_Grant,allocator:=context.temp_allocator) -> Error {
    refs,e:=store.ref_list(s,MACHINE_NAMESPACE,context.temp_allocator)
    if e!=.None {return store_error(e)}
    for r in refs {
        if !strings.has_prefix(r.name,MACHINE_GRANT_PREFIX) {continue}
        text,re:=file_bytes(s,r.hash,context.temp_allocator)
        if re!=.None {continue}
        gt,ok:=grant_text_decode(string(text),allocator)
        if !ok {continue}
        g,ge:=grant_decode(gt.grant)
        if ge!=.None {continue}
        if _,a:=append(out,Held_Grant{g,store.address_of_bytes(gt.grant),gt});a!=nil {return .Out_Of_Memory}
    }
    return .None
}

// The Grant entry of the org whose address text names by a prefix of its hex.
machine_grant_find :: proc(m:^Machine,org:Log_Id,text:string) -> (bytes:[]u8,error:Error) {
    o:Org_State
    machine_org_open(m,org,&o) or_return
    lower:=strings.to_lower(text,context.temp_allocator)
    found:=0
    for item,i in o.log.items {
        if item.entry.type!=.Grant || !o.fold.valid[i] {continue}
        hex:[64]u8
        if len(lower)>=4 && strings.has_prefix(store.hex(store.address_of_bytes(item.entry.body),&hex),lower) {
            bytes=item.entry.body
            found+=1
        }
    }
    if found==1 {return bytes,.None}
    return nil,machine_fail(m,.Invalid_Argument,found==0?"the org has no grant of that id: mirai kai grant list shows them":"several grants start so: give more of the id")
}

// --- Public paths and scopes ---

// Keeps path of the project public though the deny set holds it. With line,
// the text of a line of that file the publish scanner refused, it waives that
// one leak instead.
machine_public_add :: proc(m:^Machine,org,project:Log_Id,path:string,line:Maybe(string)=nil) -> Error {
    if !path_valid(path) {return machine_fail(m,.Invalid_Argument,"a path is relative to the project's folder, its names apart by /")}
    fingerprint:store.Hash
    if text,ok:=line.?;ok {fingerprint=leak_fingerprint(path,text)}
    _,e:=machine_org_append(m,org,.Public_Add,body_make(Public_Add_Body{project=project,fingerprint=fingerprint},transmute([]u8)path))
    return e
}

// Adds a new epoch to the key of a scope, wrapped for every device that may
// read it now: what a write refused after a reader was removed asks for.
machine_scope_rotate :: proc(m:^Machine,org,project:Log_Id,scope:Scope_Id) -> (epoch:u32,error:Error) {
    o:Org_State
    machine_org_open(m,org,&o) or_return
    defer org_state_destroy(&o)
    keyrings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
    if e:=machine_keyrings(&m.store,&o,&keyrings,context.temp_allocator);e!=.None {return 0,machine_fail(m,e,"the org's keyrings do not read")}
    for k in keyrings {
        if k.project!=project || k.scope!=scope {continue}
        device:=machine_overlay_device(m)
        defer crypto.zero_explicit(&device,size_of(device))
        e:Error
        if epoch,e=rotate_scope_epoch(k,&device,machine_now());e!=.None {return 0,machine_fail(m,e,"this device cannot rotate the scope: a writer who reads it rotates")}
        return epoch,machine_log_save(m,k.log)
    }
    return 0,machine_fail(m,.Missing,"this store has no keyring of that scope: let the agent fetch the org's logs")
}

// The scope of the project text names by a prefix of the hex of its id.
org_scope_find :: proc(f:^Org_Fold,project:Log_Id,text:string) -> (scope:Org_Scope,found:int) {
    lower:=strings.to_lower(text,context.temp_allocator)
    for sc in f.scopes {
        id:=sc.scope
        buffer:[32]u8
        if sc.project==project && len(lower)>=4 && strings.has_prefix(hex_text(id[:],buffer[:]),lower) {
            scope=sc
            found+=1
        }
    }
    return
}

// The patterns of a scope, from its Scope_Add.
org_scope_patterns :: proc(f:^Org_Fold,scope:Org_Scope,out:^[dynamic]string) {
    b,tail,_:=body_head(f.log.items[scope.entry].entry.body,Scope_Add_Body)
    r:=Reader{data=tail}
    for _ in 0..<b.patterns {append(out,tail_string(&r))}
}

// What the device of a store proves of itself to the overlays, from the keys
// at the root of the store.
machine_device_of :: proc(s:^store.Store) -> (device:Overlay_Device,error:Error) {
    identity:=machine_identity(s) or_return
    dh:=machine_dh(s) or_return
    defer crypto.zero_explicit(&dh,size_of(dh))
    device=Overlay_Device{identity=identity,dh=Dh_Key(dh.public),dh_secret=transmute([32]u8)dh.private}
    machine_secret(s,KEM_FILE,device.kem_seed[:]) or_return
    return device,.None
}

// --- Projects ---

// The org a project's log names and whether the project is public.
project_org :: proc(l:^Log) -> (org:Log_Id,public:bool) {
    k:=log_find(l,l.id)
    if k<0 || l.items[k].entry.type!=.Project_Genesis {return}
    b,_,_:=body_head(l.items[k].entry.body,Project_Genesis_Body)
    return b.org,bool(b.public)
}

// Makes the repository of a workspace a project of an org this machine
// serves, which another machine added: a second workspace of the project.
machine_project_link :: proc(m:^Machine,repo:Repo_Id,project:Log_Id) -> Error {
    if p,_,linked:=machine_project_of(m,repo);linked {
        if p==project {return .None}
        return machine_fail(m,.Invalid_Argument,"this workspace is another project of an org already")
    }
    l:Log
    log_init(&l,project,context.temp_allocator)
    if log_open(&m.store,&l,project,.Project)!=.None {return machine_fail(m,.Missing,"this store has no log of that project: let the agent fetch the org's logs")}
    org,_:=project_org(&l)
    if !slice.contains(m.orgs[:],org) {return machine_fail(m,.Unauthorized,"this machine does not serve the project's org: pair as a member first")}
    if e:=store.ref_set(&m.store,MACHINE_NAMESPACE,machine_repo_name(repo),project);e!=.None {return machine_fail(m,store_error(e),"the store refused the project's ref")}
    return .None
}

// A project as this machine knows it: its log folded against its org's, with
// every proposal of the project the store holds, folded and settled, so the
// moves a policy guards are checked as every peer checks them.
Project_State :: struct {
    id:Log_Id,
    org:Org_State,
    public:bool,
    log:Log,
    proposal_logs:[dynamic]^Log,
    proposals:[dynamic]^Proposal_Fold,
    snapshots:[dynamic]^Proposal_Fold, // the proposals the moves land, as they were (project_snapshots)
    store:^store.Store,
    fold:Project_Fold,
    folded:bool,
    allocator:runtime.Allocator,
}

project_state_load :: proc(s:^store.Store,project:Log_Id,ps:^Project_State,allocator:=context.allocator) -> Error {
    ps^={id=project,allocator=allocator,store=s}
    log_init(&ps.log,project,allocator)
    ps.proposal_logs=make([dynamic]^Log,allocator)
    ps.proposals=make([dynamic]^Proposal_Fold,allocator)
    ps.snapshots=make([dynamic]^Proposal_Fold,allocator)
    log_open(s,&ps.log,project,.Project) or_return
    org:Log_Id
    org,ps.public=project_org(&ps.log)
    if org=={} {return .Corrupt}
    org_state_load(s,org,&ps.org,allocator) or_return
    if refs,e:=store.ref_list(s,LOG_NAMESPACE,context.temp_allocator);e==.None {
        for r in refs {
            id,ok:=store.parse_hex(r.name)
            if !ok || id==project || id==org {continue}
            if head,_,he:=log_index_read(s,r.hash);he!=.None || head.kind!=.Proposal {continue}
            if genesis,found,_:=log_entry_get(s,r.hash,id);!found {
                continue
            } else if e,de:=entry_decode(genesis);de!=.None || e.type!=.Proposal_Open {
                continue
            } else if b,_,_:=body_head(e.body,Proposal_Open_Body);b.project!=project {
                continue
            }
            l,le:=new(Log,allocator)
            if le!=nil {return .Out_Of_Memory}
            log_init(l,id,allocator)
            if _,a:=append(&ps.proposal_logs,l);a!=nil {
                free(l,allocator)
                return .Out_Of_Memory
            }
            if _,load:=log_load(s,l,r.hash,false);load!=.None || l.kind!=.Proposal {continue}
            k:=log_find(l,id)
            if k<0 || l.items[k].entry.type!=.Proposal_Open {continue}
            if b,_,_:=body_head(l.items[k].entry.body,Proposal_Open_Body);b.project!=project {continue}
            f,fe:=new(Proposal_Fold,allocator)
            if fe!=nil {return .Out_Of_Memory}
            if proposal_fold(f,l,&ps.org.fold,allocator)!=.None {
                proposal_fold_destroy(f)
                free(f,allocator)
                continue
            }
            // A stack whose changes are not all here settles to no approvals.
            proposal_settle(s,f)
            append(&ps.proposals,f)
        }
    }
    return project_state_refold(ps)
}

project_state_refold :: proc(ps:^Project_State) -> Error {
    if ps.folded {project_fold_destroy(&ps.fold)}
    ps.folded=false
    project_snapshots_destroy(&ps.snapshots,ps.allocator)
    project_snapshots(ps.store,&ps.log,&ps.org.fold,&ps.snapshots,ps.allocator) or_return
    if e:=project_fold(&ps.fold,&ps.log,&ps.org.fold,ps.snapshots[:],ps.allocator);e!=.None {
        project_fold_destroy(&ps.fold)
        return e
    }
    ps.folded=true
    // A store another process holds open for writing keeps them the next time.
    _=landings_keep(ps.store,&ps.fold)
    return .None
}

project_state_destroy :: proc(ps:^Project_State) {
    if ps.folded {project_fold_destroy(&ps.fold)}
    project_snapshots_destroy(&ps.snapshots,ps.allocator)
    delete(ps.snapshots)
    for f in ps.proposals {
        proposal_fold_destroy(f)
        free(f,ps.allocator)
    }
    for l in ps.proposal_logs {
        log_destroy(l)
        free(l,ps.allocator)
    }
    delete(ps.proposals)
    delete(ps.proposal_logs)
    log_destroy(&ps.log)
    org_state_destroy(&ps.org)
    ps^={}
}

// The proposal of id among those the state folded; nil when it has none.
project_state_proposal :: proc(ps:^Project_State,id:Log_Id) -> ^Proposal_Fold {
    for f in ps.proposals {
        if f.log.id==id {return f}
    }
    return nil
}

// The proposal of the project text names by a prefix of the hex of its id.
project_state_proposal_find :: proc(ps:^Project_State,text:string) -> (f:^Proposal_Fold,found:int) {
    lower:=strings.to_lower(text,context.temp_allocator)
    for p in ps.proposals {
        hex:[64]u8
        if len(lower)>=4 && strings.has_prefix(store.hex(p.log.id,&hex),lower) {
            f=p
            found+=1
        }
    }
    return
}

// Whether the log whose index is at address is the Proposal_Log id of a
// project of org: its genesis, read alone and verified, says.
proposal_of_org :: proc(s:^store.Store,org:^Org_Fold,id:Log_Id,address:store.Hash) -> bool {
    bytes,found,_:=log_entry_get(s,address,id)
    if !found {return false}
    e,de:=entry_decode(bytes)
    if de!=.None || e.type!=.Proposal_Open || !entry_verify(bytes,&e) {return false}
    b,_,_:=body_head(e.body,Proposal_Open_Body)
    return org_project_index(org,b.project)>=0
}

@(private)
machine_project_open :: proc(m:^Machine,project:Log_Id,ps:^Project_State) -> Error {
    if e:=project_state_load(&m.store,project,ps,context.temp_allocator);e!=.None {
        if e==.Missing {return machine_fail(m,e,"this store lacks the logs of the project or its org: let the agent fetch them")}
        return machine_fail(m,e,"the project's logs do not fold: fetch them again from a member")
    }
    return .None
}

// The policy of the org on bookmark of the project; nil when it has none.
org_policy :: proc(f:^Org_Fold,project:Log_Id,bookmark:string) -> ^Org_Policy {
    for &p in f.policies {
        if p.project==project && p.bookmark==bookmark {return &p}
    }
    return nil
}

// The checks a policy requires, from its Policy_Set.
org_policy_checks :: proc(f:^Org_Fold,p:^Org_Policy,out:^[dynamic]string) {
    b,_,r,_:=policy_parts(f.log.items[p.entry].entry.body)
    tail_string(&r)
    for _ in 0..<b.checks {append(out,tail_string(&r))}
}

// A policy as a person reads it: its approvals and checks.
org_policy_text :: proc(f:^Org_Fold,p:^Org_Policy) -> string {
    checks:=make([dynamic]string,context.temp_allocator)
    org_policy_checks(f,p,&checks)
    text:=fmt.tprintf("%d approval%s",p.approvals,p.approvals==1?"":"s")
    if len(checks)>0 {text=fmt.tprintf("%s and the check%s %s",text,len(checks)==1?"":"s",strings.join(checks[:],", ",context.temp_allocator))}
    return text
}

@(private)
role_refusal :: proc(m:^Machine,org:^Org_Fold,need:Role,what:string) -> string {
    role:=m.user=={}?Role.None:org_role(org,m.user)
    if role==.None {return fmt.tprintf("this device's user is no member of the org, and %s is a %v's: ask an admin to pair it as a member",what,need)}
    return fmt.tprintf("this device's user is a %v of the org, and %s is a %v's: an admin sets the role with mirai kai org role",role,what,need)
}

// Moves a shared bookmark of the project to revision: a Bookmark_Move of the
// project's log from the targets it has. A bookmark a policy guards moves
// only by landing a proposal; m.why names the policy.
machine_bookmark_move :: proc(m:^Machine,project:Log_Id,name:string,to:Revision) -> Error {
    if !bookmark_name_valid(name) {return machine_fail(m,.Invalid_Argument,"a bookmark's name is 1 to 255 bytes of text without spaces")}
    if to=={} {return machine_fail(m,.Invalid_Argument,"a bookmark moves to a change")}
    ps:Project_State
    machine_project_open(m,project,&ps) or_return
    defer project_state_destroy(&ps)
    if p:=org_policy(&ps.org.fold,project,name);p!=nil {
        b,_,_:=body_head(ps.org.log.items[p.entry].entry.body,Policy_Set_Body)
        if b.approvals>0 || b.checks>0 {
            return machine_fail(m,.Unauthorized,fmt.tprintf("%s is guarded by the org's policy, %s: land the change through a proposal, mirai kai proposal open %s",name,org_policy_text(&ps.org.fold,p),name))
        }
    }
    from:=make([dynamic]Revision,context.temp_allocator)
    project_bookmark(&ps.fold,name,&from)
    if len(from)==1 && from[0]==to {return .None}
    if len(from)>CONFLICT_SIDES_MAX {return machine_fail(m,.Too_Large,"the bookmark diverged too far: move it from fewer targets")}
    old:Revision
    if len(from)>0 {old=from[0]}
    machine_publish_check(m,&ps.org.fold,project,ps.public,old,to) or_return
    address,e:=log_append(&ps.log,.Bookmark_Move,move_body(name,from[:],to),&m.identity,machine_now(),machine_user_head(m),org_context(&ps.org.fold,m.user))
    if e!=.None {return machine_fail(m,e,"the move does not sign")}
    project_state_refold(&ps)
    if k:=log_find(&ps.log,address);k<0 || !ps.folded || !ps.fold.valid[k] {return machine_fail(m,.Unauthorized,role_refusal(m,&ps.org.fold,.Writer,"moving a shared bookmark"))}
    return machine_log_save(m,&ps.log)
}

@(private)
leak_text :: proc(kind:Leak_Kind) -> string {
    switch kind {
    case .Private_Key: return "a private key"
    case .Token: return "a token"
    case .Assignment: return "a secret assigned to a name"
    }
    return ""
}

// Refuses publishing revision to over from in a public project when the
// publish scanner finds a leak: m.why names its file, line and waiver.
machine_publish_check :: proc(m:^Machine,org:^Org_Fold,project:Log_Id,public:bool,from,to:Revision) -> Error {
    m.leak={}
    if !public {return .None}
    trees:[2]store.Hash
    for r,k in ([2]Revision{from,to}) {
        if r=={} {continue}
        c,e:=change_get(&m.store,r,context.temp_allocator)
        if e!=.None {return machine_fail(m,e,"a change to publish is not in the store: let the agent fetch it")}
        trees[k]=c.tree
    }
    leaks:=make([dynamic]Leak,context.temp_allocator)
    if e:=publish_scan(&m.store,org,project,trees[0],trees[1],&leaks,context.temp_allocator);e!=.None {return machine_fail(m,e,"the publish scanner does not read the change's files: let the agent fetch them")}
    if len(leaks)==0 {return .None}
    l:=leaks[0]
    m.leak=l
    more:=len(leaks)>1?fmt.tprintf(" (and %d more)",len(leaks)-1):""
    return machine_fail(m,.Unauthorized,fmt.tprintf("%s:%d holds %s and the project is public%s: remove it, or an admin waives it with mirai kai public add %s:%d",l.path,l.line,leak_text(l.kind),more,l.path,l.line))
}

// --- Proposals ---

// Opens a proposal of the project on the target bookmark with its first
// stack, bottom first: its id.
machine_proposal_open :: proc(m:^Machine,project:Log_Id,target,title,text:string,stack:[]Stack_Item) -> (id:Log_Id,error:Error) {
    ps:Project_State
    machine_project_open(m,project,&ps) or_return
    defer project_state_destroy(&ps)
    l:Log
    log_init(&l,{},context.temp_allocator)
    now,ctx,org_ctx:=machine_now(),machine_user_head(m),org_context(&ps.org.fold,m.user)
    if _,e:=proposal_open(&l,project,target,title,text,&m.identity,now,ctx,org_ctx);e!=.None {
        return {},machine_fail(m,e,"a proposal has a target bookmark, a title of at most 65535 bytes and a text, all UTF-8")
    }
    if _,e:=proposal_revise(&l,stack,&m.identity,now+1,ctx,org_ctx);e!=.None {return {},machine_fail(m,e,"a stack holds 1 to 256 changes, each once")}
    f:Proposal_Fold
    e:=proposal_fold(&f,&l,&ps.org.fold,context.temp_allocator)
    defer proposal_fold_destroy(&f)
    if e!=.None {return {},machine_fail(m,e,"the proposal does not fold")}
    for v in f.valid {
        if !v {return {},machine_fail(m,.Unauthorized,role_refusal(m,&ps.org.fold,.Writer,"opening a proposal"))}
    }
    machine_log_save(m,&l) or_return
    return l.id,.None
}

// What keeps a proposal from landing, said whole: which approvals or checks
// of its target's policy are missing.
land_blocker :: proc(org:^Org_Fold,f:^Proposal_Fold,refusal:Land_Refusal) -> string {
    target:=proposal_target(f)
    hex:[64]u8
    id:=store.hex(f.log.id,&hex)[:8]
    #partial switch refusal {
    case .Approvals:
        if p:=org_policy(org,f.project,target);p!=nil {
            return fmt.tprintf("%s's policy asks %d approval%s of the final revision and it has %d: a reviewer runs mirai kai proposal approve %s",target,p.approvals,p.approvals==1?"":"s",f.approvals,id)
        }
    case .Checks:
        if p:=org_policy(org,f.project,target);p!=nil {
            checks:=make([dynamic]string,context.temp_allocator)
            org_policy_checks(org,p,&checks)
            for name in checks {
                state:="has not run"
                for c in f.checks {
                    if c.name!=name {continue}
                    state=c.state==.Passed?"":c.state==.Failed?"failed":"is pending"
                }
                if state=="" {continue}
                return fmt.tprintf("%s's policy requires the check %s, which %s on the final revision: run it there with mirai kai check %s -- <command>",target,name,state,name)
            }
        }
    }
    return land_refusal_text(refusal)
}

@(private)
proposal_refusal :: proc(m:^Machine,org:^Org_Fold,f:^Proposal_Fold,type:Entry_Type) -> string {
    if type==.Proposal_Reopen {
        if f.status!=.Closed {return "the proposal is not closed"}
        return "only who opened the proposal or an admin reopens it"
    }
    switch f.status {
    case .Open:
    case .Closed: if type!=.Proposal_Comment {return "the proposal is closed: mirai kai proposal reopen opens it again"}
    case .Landed: if type!=.Proposal_Comment {return "the proposal landed: open another one"}
    }
    role:=m.user=={}?Role.None:org_role(org,m.user)
    #partial switch type {
    case .Proposal_Check:
        if role==.None {return "this machine's user is no member of the org and it holds no grant of the check right on the project: an admin issues one with mirai kai grant issue"}
        return role_refusal(m,org,.Writer,"signing a check")
    case .Proposal_Verdict: return role_refusal(m,org,.Writer,"a verdict")
    case .Proposal_Revise: return role_refusal(m,org,.Writer,"revising another's proposal")
    case .Proposal_Land: return role_refusal(m,org,.Writer,"landing")
    case .Proposal_Close: return "only who opened the proposal or an admin closes it"
    case .Proposal_Comment: return role_refusal(m,org,.Reader,"a comment")
    }
    return "the proposal's rules refuse it"
}

// Appends an entry this device signs to the proposal f of the state, kept
// only when the proposal's fold takes it.
@(private)
proposal_write :: proc(m:^Machine,ps:^Project_State,f:^Proposal_Fold,type:Entry_Type,body:[]u8) -> (address:store.Hash,error:Error) {
    l:=f.log
    address,error=log_append(l,type,body,&m.identity,machine_now(),machine_user_head(m),org_context(&ps.org.fold,m.user))
    if error!=.None {return {},machine_fail(m,error,"the entry does not sign")}
    proposal_fold_destroy(f)
    proposal_fold(f,l,&ps.org.fold,ps.allocator)
    if k:=log_find(l,address);k<0 || !f.valid[k] {
        return {},machine_fail(m,.Unauthorized,proposal_refusal(m,&ps.org.fold,f,type))
    }
    proposal_settle(&m.store,f)
    machine_log_save(m,l) or_return
    return address,.None
}

@(private)
machine_proposal_load :: proc(m:^Machine,project,proposal:Log_Id,ps:^Project_State) -> (f:^Proposal_Fold,error:Error) {
    machine_project_open(m,project,ps) or_return
    f=project_state_proposal(ps,proposal)
    if f==nil {
        project_state_destroy(ps)
        return nil,machine_fail(m,.Missing,"this store has no such proposal of the project: mirai kai proposal list shows them")
    }
    return f,.None
}

// Revises the proposal to a new stack, bottom first.
machine_proposal_revise :: proc(m:^Machine,project,proposal:Log_Id,stack:[]Stack_Item) -> Error {
    ps:Project_State
    f:=machine_proposal_load(m,project,proposal,&ps) or_return
    defer project_state_destroy(&ps)
    body,e:=proposal_revise_body(stack)
    if e!=.None {return machine_fail(m,e,"a stack holds 1 to 256 changes, each once")}
    _,error:=proposal_write(m,&ps,f,.Proposal_Revise,body)
    return error
}

// Comments on the proposal: on the whole of it when change is zero, else on
// path of change at anchor; reply_to is the comment it answers, or zero.
machine_proposal_comment :: proc(m:^Machine,project,proposal:Log_Id,anchor:Anchor,path:string,change:Change_Id,reply_to:store.Hash,text:string) -> Error {
    ps:Project_State
    f:=machine_proposal_load(m,project,proposal,&ps) or_return
    defer project_state_destroy(&ps)
    body,e:=proposal_comment_body(anchor,path,change,reply_to,text)
    if e!=.None {return machine_fail(m,e,"a comment is UTF-8 text on a path of the project, with lines from 1")}
    _,error:=proposal_write(m,&ps,f,.Proposal_Comment,body)
    return error
}

// Approves, asks changes of or withdraws from the proposal's final revision.
machine_proposal_verdict :: proc(m:^Machine,project,proposal:Log_Id,verdict:Verdict_Kind) -> Error {
    ps:Project_State
    f:=machine_proposal_load(m,project,proposal,&ps) or_return
    defer project_state_destroy(&ps)
    if f.revision=={} {return machine_fail(m,.Invalid_Argument,land_refusal_text(.Unrevised))}
    body,_:=proposal_verdict_body(verdict,f.revision)
    _,error:=proposal_write(m,&ps,f,.Proposal_Verdict,body)
    return error
}

// Signs what the check name found on revision, its output at log_root: it
// counts while revision is the proposal's final one. A writer or a holder of
// a grant of the check right on the project signs it.
machine_proposal_check :: proc(m:^Machine,project,proposal:Log_Id,revision:Revision,name:string,passed:bool,log_root:store.Hash) -> Error {
    ps:Project_State
    f:=machine_proposal_load(m,project,proposal,&ps) or_return
    defer project_state_destroy(&ps)
    if f.revision!=revision {return machine_fail(m,.Invalid_Argument,"the proposal was revised while the check ran: run it again on its final revision")}
    body,e:=proposal_check_body(revision,name,passed?.Passed:.Failed,log_root)
    if e!=.None {return machine_fail(m,e,"a check's name is 1 to 64 bytes of text")}
    _,error:=proposal_write(m,&ps,f,.Proposal_Check,body)
    return error
}

// Closes the proposal, or reopens it.
machine_proposal_close :: proc(m:^Machine,project,proposal:Log_Id,reopen:bool) -> Error {
    ps:Project_State
    f:=machine_proposal_load(m,project,proposal,&ps) or_return
    defer project_state_destroy(&ps)
    _,error:=proposal_write(m,&ps,f,reopen?.Proposal_Reopen:.Proposal_Close,nil)
    return error
}

// Lands the proposal: its target moves to the final revision in the
// project's log, when no change of the stack has a conflict and the target's
// policy is met; m.why says what is missing otherwise.
machine_proposal_land :: proc(m:^Machine,project,proposal:Log_Id) -> Error {
    ps:Project_State
    f:=machine_proposal_load(m,project,proposal,&ps) or_return
    defer project_state_destroy(&ps)
    refusal,e:=proposal_can_land(&m.store,f)
    if e!=.None {return machine_fail(m,e,"a change of the stack is not in this store: let the agent fetch it")}
    if refusal!=.None {return machine_fail(m,.Unauthorized,land_blocker(&ps.org.fold,f,refusal))}
    from:=make([dynamic]Revision,context.temp_allocator)
    project_bookmark(&ps.fold,proposal_target(f),&from)
    old:Revision
    if len(from)>0 {old=from[0]}
    machine_publish_check(m,&ps.org.fold,project,ps.public,old,f.revision) or_return
    move,_,le:=proposal_land(&m.store,f,&ps.fold,&m.identity,machine_now(),machine_user_head(m),org_context(&ps.org.fold,m.user))
    if le!=.None {return machine_fail(m,le,"the landing does not sign")}
    land:=f.log
    proposal_fold_destroy(f)
    proposal_fold(f,land,&ps.org.fold,ps.allocator)
    proposal_settle(&m.store,f)
    project_state_refold(&ps)
    k:=log_find(&ps.log,move)
    if f.status!=.Landed || k<0 || !ps.folded || !ps.fold.valid[k] {return machine_fail(m,.Unauthorized,role_refusal(m,&ps.org.fold,.Writer,"landing"))}
    machine_log_save(m,land) or_return
    return machine_log_save(m,&ps.log)
}

// --- Verification ---

Verify_Report :: struct {
    logs,entries,refs,changes:int,
    failed:string, // the first that does not hold, in the temp allocator; empty when all do
}

// Checks the signatures and the structure of what the store holds of a
// project: the logs of its org, its users, its own, its proposals' and its
// scopes' keyrings, every device's refs of it, and every change the refs, the
// shared bookmarks and the stacks reach, with their trees.
machine_project_verify :: proc(m:^Machine,project:Log_Id,report:^Verify_Report) -> Error {
    report^={}
    s:=&m.store
    ps:Project_State
    if e:=project_state_load(s,project,&ps,context.temp_allocator);e!=.None {
        report.failed=fmt.tprintf("the logs of the project or its org do not read or fold (%s)",error_text(e))
        return .None
    }
    logs:=make([dynamic]^Log,context.temp_allocator)
    append(&logs,&ps.org.log,&ps.log)
    for l in ps.org.user_logs {append(&logs,l)}
    for f in ps.proposals {append(&logs,f.log)}
    keyrings:=make([dynamic]^Keyring_Fold,context.temp_allocator)
    machine_keyrings(s,&ps.org,&keyrings,context.temp_allocator)
    for k in keyrings {
        if k.project==project {append(&logs,k.log)}
    }
    for l in logs {
        report.logs+=1
        for &item in l.items {
            report.entries+=1
            if !entry_verify(item.bytes,&item.entry) {
                hex,entry:[64]u8
                report.failed=fmt.tprintf("the %v log %s: entry %s is not signed by its author",l.kind,store.hex(l.id,&hex)[:12],store.hex(item.address,&entry)[:12])
                return .None
            }
        }
    }
    targets:=make([dynamic]Revision,context.temp_allocator)
    for b in ps.fold.bookmarks {append(&targets,b.target)}
    for f in ps.proposals {
        stacks:=make([dynamic]Proposal_Stack,context.temp_allocator)
        proposal_stacks(f,&stacks)
        for st in stacks {
            for item in st.items {append(&targets,item.revision)}
        }
    }
    ns:[len(REFS_PREFIX)+64]u8
    if refs,e:=store.ref_list(s,refs_namespace(project,&ns),context.temp_allocator);e==.None {
        for r in refs {
            report.refs+=1
            bytes,ge:=object_get(s,r.hash,.Device_Refs,context.temp_allocator)
            d:Device_Refs
            de:=ge
            if ge==.None {d,de=device_refs_decode(bytes,context.temp_allocator)}
            name:[32]u8
            scope,writer:=device_may_write(&ps.org.fold,project,d.device,d.time)
            if de!=.None || !signed_valid(bytes,d.device) || refs_name(d.device,&name)!=r.name || !writer {
                report.failed=fmt.tprintf("the refs of device %s do not read, are not signed by it, or it may not write the project",r.name)
                return .None
            }
            from:=len(targets)
            for b in d.refs {append(&targets,b.target)}
            if scope=="" {continue}
            if we:=grant_writes_within(s,scope,d.device,targets[from:],nil,nil);we!=.None {
                report.failed=fmt.tprintf("the refs of device %s bring changes outside its grant's path %s (%s)",r.name,scope,error_text(we))
                return .None
            }
        }
    }
    seen:=make(map[Revision]struct{},context.temp_allocator)
    for len(targets)>0 {
        r:=pop(&targets)
        if r in seen {continue}
        seen[r]={}
        report.changes+=1
        hex:[64]u8
        bytes,ge:=object_get(s,r,.Change,context.temp_allocator)
        if ge!=.None {
            report.failed=fmt.tprintf("change %s is not in the store (%s): let the agent fetch it",store.hex(r,&hex)[:12],error_text(ge))
            return .None
        }
        c,ce:=change_decode(bytes,context.temp_allocator)
        if ce!=.None || !change_verify(bytes) {
            report.failed=fmt.tprintf("change %s does not read or is not signed by its author",store.hex(r,&hex)[:12])
            return .None
        }
        if _,te:=tree_totals(s,c.tree);te!=.None {
            report.failed=fmt.tprintf("the tree of change %s does not read whole (%s): let the agent fetch it",store.hex(r,&hex)[:12],error_text(te))
            return .None
        }
        append(&targets,..c.parents)
    }
    return .None
}
