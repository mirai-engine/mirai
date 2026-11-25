package kai

import "base:runtime"
import "core:slice"
import "core:unicode/utf8"
import "mirai:store"

// --- The fold ---

// The fold of one log, whichever its kind: every kind is walked by fold_run,
// which asks each kind's procedures through a switch.
@(private)
Fold :: union {^User_Fold,^Org_Fold,^Project_Fold,^Proposal_Fold,^Keyring_Fold}

// The entries a fold walked about each subject, newest first: the state of a
// subject in the causal past of an entry is replayed from them.
@(private)
Subject_Lists :: struct {
    last:map[store.Hash]u32, // the newest entry about a subject, +1
    prev:[]u32,              // of each entry, the one walked before it about the same subject, +1
}

@(private)
subjects_make :: proc(s:^Subject_Lists,n:int,allocator:runtime.Allocator) -> Error {
    s.last=make(map[store.Hash]u32,allocator)
    prev,e:=make([]u32,n,allocator)
    if e!=nil {return .Out_Of_Memory}
    s.prev=prev
    return .None
}

@(private)
subjects_destroy :: proc(s:^Subject_Lists,allocator:runtime.Allocator) {
    delete(s.last)
    delete(s.prev,allocator)
    s^={}
}

@(private)
subjects_add :: proc(s:^Subject_Lists,subject:store.Hash,e:int) -> Error {
    s.prev[e]=s.last[subject]
    if _,me:=map_insert(&s.last,subject,u32(e+1));me!=nil {return .Out_Of_Memory}
    return .None
}

// The newest entry about subject, then each before it: -1 at the end.
@(private)
subjects_first :: #force_inline proc(s:^Subject_Lists,subject:store.Hash) -> int {return int(s.last[subject])-1}

@(private)
subjects_next :: #force_inline proc(s:^Subject_Lists,e:int) -> int {return int(s.prev[e])-1}

// Drops what entries of rank from and later recorded.
@(private)
subjects_drop :: proc(s:^Subject_Lists,l:^Log,from:int) {
    for _,&last in s.last {
        for last!=0 && int(l.rank[last-1])>=from {last=s.prev[last-1]}
    }
}

@(private)
list_drop :: proc(list:^[dynamic]u32,l:^Log,from:int) {
    for len(list)>0 && int(l.rank[list[len(list)-1]])>=from {pop(list)}
}

// The validity of every entry of l, as all peers find it, and then the state
// of the valid entries applied in order. One walk of the topological order
// decides each entry against the state of its causal past, which each kind
// replays from the entries walked about the subjects it reads, and against the
// valid removals walked before it that it is concurrent with. A removal that
// voids an entry walked before it walks again from that entry: near-linear
// when removals do not race the writes they void, O(n·v) for v such voids.
//
// A log with Witness entries is walked twice: the first walk, which holds
// every entry against every removal of another log, decides which witnesses
// are valid; the second judges all entries against them.
@(private)
fold_run :: proc(l:^Log,fold:Fold,valid:[]bool) -> Error {
    log_index(l) or_return
    fold_begin(fold) or_return
    clear(&l.witness_last)
    if resize(&l.witness_prev,len(l.items))!=nil {return .Out_Of_Memory}
    witnessed:=false
    for &item in l.items {witnessed||=item.entry.type==.Witness}
    if witnessed {
        l.witnessing=true
        e:=fold_walk(l,fold,valid)
        l.witnessing=false
        e or_return
    }
    fold_walk(l,fold,valid) or_return
    fold_apply(fold)
    return .None
}

@(private)
fold_walk :: proc(l:^Log,fold:Fold,valid:[]bool) -> Error {
    voided,e:=make([]bool,len(l.items),context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    from:=0
    for {
        fold_drop(fold,from)
        if l.witnessing {
            for _,&last in l.witness_last {
                for last!=0 && int(l.rank[last-1])>=from {last=l.witness_prev[last-1]}
            }
        }
        again:=-1
        for k in from..<len(l.order) {
            i:=int(l.order[k])
            valid[i]=!voided[i] && l.complete[i] && fold_authorized(fold,i)
            if !valid[i] {continue}
            fold_record(fold,i) or_return
            if l.witnessing && l.items[i].entry.type==.Witness {
                b,_,_:=body_head(l.items[i].entry.body,Witness_Body)
                l.witness_prev[i]=l.witness_last[b.removal]
                if _,me:=map_insert(&l.witness_last,b.removal,u32(i+1));me!=nil {return .Out_Of_Memory}
            }
            if at:=fold_voids(fold,i,valid,voided);at>=0 && (again<0 || at<again) {again=at}
        }
        if again<0 {break}
        from=again
    }
    return .None
}

@(private)
fold_begin :: proc(fold:Fold) -> Error {
    switch f in fold {
    case ^User_Fold:
        subjects_make(&f.keys,len(f.log.items),f.allocator) or_return
        subjects_make(&f.authors,len(f.log.items),f.allocator) or_return
        f.recoveries=make([dynamic]u32,f.allocator)
    case ^Org_Fold:
        subjects_make(&f.about,len(f.log.items),f.allocator) or_return
        subjects_make(&f.authored,len(f.log.items),f.allocator) or_return
        f.transfers=make([dynamic]u32,f.allocator)
        authors,e:=make([]u32,len(f.log.items),f.allocator)
        if e!=nil {return .Out_Of_Memory}
        f.authors=authors
    case ^Project_Fold:
    case ^Proposal_Fold:
        f.statuses=make([dynamic]u32,f.allocator)
        f.revises=make([dynamic]u32,f.allocator)
        if k:=log_find(f.log,f.log.id);k>=0 {
            b,_,_:=body_head(f.log.items[k].entry.body,Proposal_Open_Body)
            f.project=b.project
        }
    case ^Keyring_Fold:
        f.epochs=make([dynamic]u32,f.allocator)
        subjects_make(&f.added,len(f.log.items),f.allocator) or_return
        if k:=log_find(f.log,f.log.id);k>=0 {
            b,_,_:=body_head(f.log.items[k].entry.body,Keyring_Genesis_Body)
            f.project,f.scope=b.project,b.scope
        }
    }
    return .None
}

@(private)
fold_drop :: proc(fold:Fold,from:int) {
    switch f in fold {
    case ^User_Fold:
        subjects_drop(&f.keys,f.log,from)
        subjects_drop(&f.authors,f.log,from)
        list_drop(&f.recoveries,f.log,from)
    case ^Org_Fold:
        subjects_drop(&f.about,f.log,from)
        subjects_drop(&f.authored,f.log,from)
        list_drop(&f.transfers,f.log,from)
    case ^Project_Fold:
    case ^Proposal_Fold:
        list_drop(&f.statuses,f.log,from)
        list_drop(&f.revises,f.log,from)
    case ^Keyring_Fold:
        list_drop(&f.epochs,f.log,from)
        subjects_drop(&f.added,f.log,from)
    }
}

@(private)
fold_authorized :: proc(fold:Fold,e:int) -> bool {
    switch f in fold {
    case ^User_Fold: return user_authorized(f,e)
    case ^Org_Fold: return org_authorized(f,e)
    case ^Project_Fold: return project_authorized(f,e)
    case ^Proposal_Fold: return proposal_authorized(f,e)
    case ^Keyring_Fold: return keyring_authorized(f,e)
    }
    return false
}

// Records the valid entry e under the subjects it is about.
@(private)
fold_record :: proc(fold:Fold,e:int) -> Error {
    switch f in fold {
    case ^User_Fold:
        entry:=&f.log.items[e].entry
        if key,has:=user_subject(entry);has {subjects_add(&f.keys,store.Hash(key),e) or_return}
        subjects_add(&f.authors,store.Hash(entry.author),e) or_return
        if entry.type==.User_Genesis || entry.type==.Passkey_Genesis || entry.type==.Recovery_Rotate {
            if _,ae:=append(&f.recoveries,u32(e));ae!=nil {return .Out_Of_Memory}
        }
    case ^Org_Fold:
        entry:=&f.log.items[e].entry
        subject,has:=org_subject(f,e)
        if entry.type==.Org_Genesis {
            b,_,_:=body_head(entry.body,Org_Genesis_Body)
            subject,has=b.owner,true
        }
        if has {subjects_add(&f.about,subject,e) or_return}
        if f.authors[e]!=0 {subjects_add(&f.authored,f.users[f.authors[e]-1].log.id,e) or_return}
        if entry.type==.Owner_Transfer {
            if _,ae:=append(&f.transfers,u32(e));ae!=nil {return .Out_Of_Memory}
        }
    case ^Project_Fold:
    case ^Proposal_Fold:
        #partial switch f.log.items[e].entry.type {
        case .Proposal_Open,.Proposal_Close,.Proposal_Reopen,.Proposal_Land:
            if _,ae:=append(&f.statuses,u32(e));ae!=nil {return .Out_Of_Memory}
        case .Proposal_Revise:
            if _,ae:=append(&f.revises,u32(e));ae!=nil {return .Out_Of_Memory}
        }
    case ^Keyring_Fold:
        entry:=&f.log.items[e].entry
        #partial switch entry.type {
        case .Epoch_Add:
            if _,ae:=append(&f.epochs,u32(e));ae!=nil {return .Out_Of_Memory}
        case .Envelope_Add:
            b,_,_:=body_head(entry.body,Envelope_Add_Body)
            subjects_add(&f.added,envelope_subject(b.epoch,b.envelope.dh),e) or_return
        }
    }
    return .None
}

// Voids the valid entries walked before the valid removal r that it wins
// over: the lowest rank among them, -1 when none.
@(private)
fold_voids :: proc(fold:Fold,r:int,valid,voided:[]bool) -> int {
    again:=-1
    void :: proc(l:^Log,x:int,valid,voided:[]bool,again:^int) {
        voided[x],valid[x]=true,false
        if again^<0 || int(l.rank[x])<again^ {again^=int(l.rank[x])}
    }
    switch f in fold {
    case ^User_Fold:
        entry:=&f.log.items[r].entry
        #partial switch entry.type {
        case .Device_Revoke:
            b,_,_:=body_head(entry.body,Device_Revoke_Body)
            for x:=subjects_first(&f.authors,store.Hash(b.device));x>=0;x=subjects_next(&f.authors,x) {
                if x==r || !valid[x] || f.log.items[x].entry.type==.Device_Revoke || log_before(f.log,x,r) {continue}
                void(f.log,x,valid,voided,&again)
            }
        case .Recovery_Rotate:
            // A rotated recovery key signs nothing beside its rotation: what
            // it signs on parents that skip it, a stolen key's work, is void.
            old:=user_recovery_before(f,r)
            if old=={} {break}
            for x:=subjects_first(&f.authors,store.Hash(old));x>=0;x=subjects_next(&f.authors,x) {
                if x==r || !valid[x] || f.log.items[x].entry.type==.Recovery_Rotate || !log_concurrent(f.log,r,x) {continue}
                void(f.log,x,valid,voided,&again)
            }
        }
    case ^Org_Fold:
        if !org_removal(f.log.items[r].entry.type) {break}
        subject,_:=org_subject(f,r)
        for x:=subjects_first(&f.about,subject);x>=0;x=subjects_next(&f.about,x) {
            if valid[x] && !org_removal(f.log.items[x].entry.type) && log_concurrent(f.log,r,x) {void(f.log,x,valid,voided,&again)}
        }
        if f.log.items[r].entry.type!=.Member_Remove {break}
        for x:=subjects_first(&f.authored,subject);x>=0;x=subjects_next(&f.authored,x) {
            if valid[x] && !org_removal(f.log.items[x].entry.type) && log_concurrent(f.log,r,x) {void(f.log,x,valid,voided,&again)}
        }
    case ^Project_Fold,^Proposal_Fold,^Keyring_Fold:
    }
    return again
}

@(private)
fold_apply :: proc(fold:Fold) {
    switch f in fold {
    case ^User_Fold: user_apply(f)
    case ^Org_Fold: org_apply(f)
    case ^Project_Fold: project_apply(f)
    case ^Proposal_Fold: proposal_apply(f)
    case ^Keyring_Fold: keyring_apply(f)
    }
}

// A body of Device_Revoke of a device or web key of the user.
revoke_body :: proc(device:Key) -> []u8 {return body_make(Device_Revoke_Body{device=device})}

// --- Witnesses ---

// The removal a witness names, valid: the Device_Revoke of a user's log, or
// the Member_Remove, Role_Set or Grant_Revoke of the org's.
@(private)
witness_removal :: proc(org:^Org_Fold,users:[]^User_Fold,b:Witness_Body) -> (entry:^Entry,ok:bool) {
    if org!=nil && b.log==org.log.id {
        k:=log_find(org.log,b.removal)
        if k<0 || !org.valid[k] {return}
        #partial switch org.log.items[k].entry.type {
        case .Member_Remove,.Role_Set,.Grant_Revoke: return &org.log.items[k].entry,true
        }
        return
    }
    for u in users {
        if u.log.id!=b.log {continue}
        k:=log_find(u.log,b.removal)
        if k<0 || !u.valid[k] || u.log.items[k].entry.type!=.Device_Revoke {return}
        return &u.log.items[k].entry,true
    }
    return
}

// Whether the removal r affects entry e of l: e is by the device or web key
// it revokes, by the user it removes or lowers, or under the grant it revokes.
@(private)
witness_affects :: proc(org:^Org_Fold,users:[]^User_Fold,r:^Entry,l:^Log,e:int) -> bool {
    author:=l.items[e].entry.author
    #partial switch r.type {
    case .Device_Revoke:
        b,_,_:=body_head(r.body,Device_Revoke_Body)
        return b.device==author
    case .Member_Remove:
        b,_,_:=body_head(r.body,Subject_Body)
        u:=author_user(users,l,e)
        return u!=nil && u.log.id==b.subject
    case .Role_Set:
        b,_,_:=body_head(r.body,Member_Body)
        u:=author_user(users,l,e)
        return u!=nil && u.log.id==b.user
    case .Grant_Revoke:
        b,_,_:=body_head(r.body,Subject_Body)
        for &g in org.granted {
            if g.address==b.subject {return g.grant.subject_key==author}
        }
    }
    return false
}

// Whether the Witness e of l may stand: it names a valid removal its author is
// not affected by, and no valid witness of that removal is in its causal past
// (its author saw the removal there first). Who holds the right to write it
// is the log's rule.
@(private)
witness_valid :: proc(org:^Org_Fold,users:[]^User_Fold,l:^Log,e:int) -> bool {
    b,_,_:=body_head(l.items[e].entry.body,Witness_Body)
    r,ok:=witness_removal(org,users,b)
    if !ok || witness_affects(org,users,r,l,e) {return false}
    for w:=log_witness_first(l,b.removal);w>=0;w=log_witness_next(l,w) {
        if log_before(l,w,e) {return false}
    }
    return true
}

// The heads of l an entry that witnesses a removal names: all of them, as the
// writer knows them when it first sees the removal.
witness_body :: proc(log:Log_Id,removal:store.Hash) -> []u8 {return body_make(Witness_Body{log=log,removal=removal})}

// A removal a log may need a witness of: where it is, and the keys it affects.
Witness_Due :: struct {log:Log_Id,removal:store.Hash,keys:[]Key}

// The removals of the org's members, devices and grants that l, the Org_Log
// or a Project, open Proposal or Keyring log of the org, has no witness of,
// appended to out: what a device that holds a right in l writes, its parents
// those of witness_parents. One is due where a key it affects signed, and,
// whether or not one did, where the key held a right when the removal came
// and the log already was (log_born_before): so a removed key has no log to
// sign first in. A log born after a removal needs none, since every entry of
// it is judged with the removal, and a settled proposal none (it counts for
// nothing until a reopen, after which the agents that load it witness what
// it lacks). A Witness entry already there that names the removal, by a key
// it does not affect, counts, valid or not, so nothing is written twice.
witnesses_due :: proc(org:^Org_Fold,l:^Log,out:^[dynamic]Witness_Due) -> Error {
    authors:=make(map[Key]bool,context.temp_allocator)
    named:=make(map[store.Hash]bool,context.temp_allocator)
    for &item in l.items {
        authors[item.entry.author]=true
        if item.entry.type==.Witness {
            b,_,_:=body_head(item.entry.body,Witness_Body)
            named[b.removal]=true
        }
    }
    due :: proc(authors:^map[Key]bool,named:^map[store.Hash]bool,log:Log_Id,removal:store.Hash,keys:[]Key,eager:bool,out:^[dynamic]Witness_Due) -> Error {
        if removal in named || len(keys)==0 {return .None}
        signed:=eager
        for k in keys {signed||=k in authors}
        if !signed {return .None}
        own,e:=slice.clone(keys,context.temp_allocator)
        if e!=nil {return .Out_Of_Memory}
        if _,ae:=append(out,Witness_Due{log,removal,own});ae!=nil {return .Out_Of_Memory}
        return .None
    }
    born:=-1
    if l!=org.log {
        if born=log_born_at(org,l);born<0 {return .None}
    }
    for u in org.users {
        if u.log==l {continue}
        held:=log_right(l.kind,org_role(org,u.log.id))
        for d in u.devices {
            if !d.revoked {continue}
            removal:=u.log.items[d.revoke].address
            due(&authors,&named,u.log.id,removal,{d.key},held && (born<0 || !revocation_before(org,removal,born)),out) or_return
        }
        for w in u.web_keys {
            if !w.revoked {continue}
            removal:=u.log.items[w.revoke].address
            due(&authors,&named,u.log.id,removal,{w.key},held && (born<0 || !revocation_before(org,removal,born)),out) or_return
        }
    }
    if l==org.log {return .None}
    project:=l.id
    if l.kind==.Proposal {
        if g:=log_find(l,l.id);g>=0 {
            b,_,_:=body_head(l.items[g].entry.body,Proposal_Open_Body)
            project=b.project
        }
    }
    for i in org.log.order {
        r:=int(i)
        // An entry appended to the org's log since its fold (a witness just written) is no removal it knows.
        if r>=len(org.valid) || !org.valid[r] {continue}
        entry:=&org.log.items[r].entry
        keys:=make([dynamic]Key,context.temp_allocator)
        eager:=!log_within(org.log,r,born)
        #partial switch entry.type {
        case .Member_Remove,.Role_Set:
            user:=entry.type==.Member_Remove?(^Subject_Body)(raw_data(entry.body)).subject:(^Member_Body)(raw_data(entry.body)).user
            before:=org_role_replay(org,user,r,false)
            after:=Role.None
            if entry.type==.Role_Set {
                b,_,_:=body_head(entry.body,Member_Body)
                if before<=b.role {continue}
                after=b.role
            }
            eager&&=log_right(l.kind,before) && !log_right(l.kind,after)
            if u:=org_user(org,user);u!=nil {
                for d in u.devices {append(&keys,d.key)}
                for w in u.web_keys {append(&keys,w.key)}
            }
            for &g in org.granted {
                if g.issuer==user && g.grant.subject_key!={} {append(&keys,g.grant.subject_key)}
            }
        case .Grant_Revoke:
            b,_,_:=body_head(entry.body,Subject_Body)
            granted:=false
            for &g in org.granted {
                if g.address!=b.subject || g.grant.subject_key=={} {continue}
                append(&keys,g.grant.subject_key)
                granted||=.Check in g.grant.rights && (g.grant.project=={} || g.grant.project==project)
            }
            // A holder signs only checks, in the proposals of its project.
            eager&&=l.kind==.Proposal && granted
        case: continue
        }
        due(&authors,&named,org.log.id,org.log.items[r].address,keys[:],eager,out) or_return
    }
    return .None
}

// Whether a role holds a right in a log of kind: a writer's in a project's
// and a keyring's, any member's in the org's and a proposal's.
@(private)
log_right :: proc "contextless" (kind:Log_Kind,role:Role) -> bool {
    #partial switch kind {
    case .Project,.Keyring: return role>=.Writer
    }
    return role>=.Reader
}

// The org's entry the genesis of l, a Project, Proposal or Keyring log, was
// signed under; -1 when it names none valid here.
log_born_at :: proc(org:^Org_Fold,l:^Log) -> int {
    g:=log_find(l,l.id)
    if g<0 {return -1}
    return org_context_of(org,l,g)
}

// Whether the org's log at its entry born holds a valid witness of the
// revocation at removal, of a user's log: a log born there came after it.
@(private)
revocation_before :: proc(org:^Org_Fold,removal:store.Hash,born:int) -> bool {
    for w:=log_witness_first(org.log,removal);w>=0;w=log_witness_next(org.log,w) {
        if log_within(org.log,w,born) {return true}
    }
    return false
}

// Whether the key that signed entry e of l, a Project, Proposal or Keyring
// log, was revoked before l was born: its revocation is witnessed in the
// org's log in the causal past of the org entry l's genesis was signed under,
// so no entry of l is its, witnessed in l or not.
@(private)
revoked_before_log :: proc(org:^Org_Fold,u:^User_Fold,l:^Log,e:int) -> bool {
    born:=log_born_at(org,l)
    if born<0 {return false}
    author:=l.items[e].entry.author
    for d in u.devices {
        if d.key==author && d.revoked {return revocation_before(org,u.log.items[d.revoke].address,born)}
    }
    for w in u.web_keys {
        if w.key==author && w.revoked {return revocation_before(org,u.log.items[w.revoke].address,born)}
    }
    return false
}

// The parents of a witness a device writes when it finds a removal reached l:
// the heads of what keys did not sign, so an entry of theirs counts only when
// another key built on it before; at most ENTRY_PARENTS_MAX, by address.
witness_parents :: proc(l:^Log,keys:[]Key,out:^[dynamic]store.Hash) -> Error {
    log_index(l) or_return
    clear(out)
    covered,e:=make([]bool,len(l.items),context.temp_allocator)
    if e!=nil {return .Out_Of_Memory}
    for &item,i in l.items {
        if slice.contains(keys,item.entry.author) {continue}
        for p in log_parents(l,i) {covered[p]=true}
    }
    for &item,i in l.items {
        if covered[i] || !l.complete[i] || slice.contains(keys,item.entry.author) {continue}
        if _,ae:=append(out,item.address);ae!=nil {return .Out_Of_Memory}
    }
    slice.sort_by(out[:],hash_less)
    if len(out)>ENTRY_PARENTS_MAX && resize(out,ENTRY_PARENTS_MAX)!=nil {return .Out_Of_Memory}
    return .None
}

// --- User_Log ---

Device :: struct {
    key:Key,
    dh:Dh_Key,
    added:u32,   // its Device_Add or genesis
    revoked:bool,
    revoke:u32,  // its Device_Revoke
}

// A passkey of the user, by its web key id.
User_Web_Key :: struct {
    key:Key,
    added:u32,  // its Web_Key_Add or Passkey_Genesis
    revoked:bool,
    revoke:u32, // its Device_Revoke
}

User_Fold :: struct {
    log:^Log,
    valid:[]bool,
    recovery:Key, // zero for a user born of a passkey until a device sets one
    recovery_dh:Dh_Key, // the X25519 key of the recovery key, which epochs are wrapped for
    recovery_at:u32,    // the entry that set the recovery key: its ML-KEM key is there
    devices:[dynamic]Device,
    web_keys:[dynamic]User_Web_Key,
    keys:Subject_Lists,     // the walk: valid entries about each device or web key
    authors:Subject_Lists,  // valid entries by each key
    recoveries:[dynamic]u32, // the genesis and the valid rotations
    allocator:runtime.Allocator,
}

user_fold :: proc(f:^User_Fold,l:^Log,allocator:=context.allocator) -> Error {
    f^={log=l,allocator=allocator}
    f.devices=make([dynamic]Device,allocator)
    f.web_keys=make([dynamic]User_Web_Key,allocator)
    if l.kind!=.User || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,f,f.valid)
}

user_fold_destroy :: proc(f:^User_Fold) {
    delete(f.devices)
    delete(f.web_keys)
    delete(f.recoveries)
    subjects_destroy(&f.keys,f.allocator)
    subjects_destroy(&f.authors,f.allocator)
    delete(f.valid,f.allocator)
    f^={}
}

// The device or web key a user's entry is about.
@(private)
user_subject :: proc(entry:^Entry) -> (key:Key,has:bool) {
    #partial switch entry.type {
    case .User_Genesis:
        b,_,_:=body_head(entry.body,User_Genesis_Body)
        return b.device,true
    case .Passkey_Genesis,.Web_Key_Add: return web_key_of(entry.body)
    case .Device_Add:
        b,_,_:=body_head(entry.body,Device_Add_Body)
        return b.device,true
    case .Device_Revoke:
        b,_,_:=body_head(entry.body,Device_Revoke_Body)
        return b.device,true
    }
    return {},false
}

// What key was in the causal past of e: known when added, active when not
// revoked, web when a passkey.
@(private)
user_key_before :: proc(f:^User_Fold,key:Key,e:int) -> (known,active,web:bool) {
    revoked:=false
    for x:=subjects_first(&f.keys,store.Hash(key));x>=0;x=subjects_next(&f.keys,x) {
        if !log_before(f.log,x,e) {continue}
        #partial switch f.log.items[x].entry.type {
        case .Device_Revoke: revoked=true
        case .Passkey_Genesis,.Web_Key_Add: known,web=true,true
        case: known=true
        }
    }
    return known,known && !revoked,web
}

// The recovery key in the causal past of e: zero when it has none.
@(private)
user_recovery_before :: proc(f:^User_Fold,e:int) -> Key {
    #reverse for x in f.recoveries {
        if !log_before(f.log,int(x),e) {continue}
        entry:=&f.log.items[x].entry
        #partial switch entry.type {
        case .User_Genesis:
            b,_,_:=body_head(entry.body,User_Genesis_Body)
            return b.recovery
        case .Recovery_Rotate:
            b,_,_:=body_head(entry.body,Recovery_Rotate_Body)
            return b.recovery
        }
        return {}
    }
    return {}
}

// The rules of a User_Log. The recovery key or an active device adds and
// revokes devices and passkeys; the recovery key rotates itself. A user born
// of a passkey has neither until its passkey links a device, which may then
// set the first recovery key; while it has none, its passkeys link devices
// and passkeys, and nothing else of the user's log.
@(private)
user_authorized :: proc(f:^User_Fold,e:int) -> bool {
    entry:=&f.log.items[e].entry
    switch entry.type {
    case .User_Genesis:
        b,_,_:=body_head(entry.body,User_Genesis_Body)
        return entry.sig_kind==.Ed25519 && entry.author==b.recovery && device_proof_valid(b.device,transmute([32]u8)b.recovery,b.dh,b.kem[:],b.proof)
    case .Passkey_Genesis:
        key,ok:=web_key_of(entry.body)
        return entry.sig_kind==.WebAuthn && ok && entry.author==key
    case .Device_Add,.Device_Revoke,.Recovery_Rotate,.Web_Key_Add:
    case .None,.Org_Genesis,.Member_Add,.Member_Remove,.Role_Set,.Owner_Transfer,.Project_Add,.Scope_Add,.Scope_Remove,.Policy_Set,.Grant,.Grant_Revoke,.Node_Add,.Node_Remove,
         .Project_Genesis,.Bookmark_Move,.Proposal_Open,.Proposal_Revise,.Proposal_Comment,.Proposal_Verdict,.Proposal_Check,.Proposal_Land,.Proposal_Close,.Proposal_Reopen,
         .Keyring_Genesis,.Epoch_Add,.Envelope_Add,.Public_Add,.Witness:
        return false
    }
    // A revoked key's entries outside its revocation's causal past count nowhere in the user's log.
    for x:=subjects_first(&f.keys,store.Hash(entry.author));x>=0;x=subjects_next(&f.keys,x) {
        if f.log.items[x].entry.type==.Device_Revoke && !log_before(f.log,e,x) {return false}
    }
    recovery:=user_recovery_before(f,e)
    _,active,web:=user_key_before(f,entry.author,e)
    by_recovery:=entry.sig_kind==.Ed25519 && recovery!={} && entry.author==recovery
    by_device:=entry.sig_kind==.Ed25519 && active && !web
    by_passkey:=entry.sig_kind==.WebAuthn && active && web && recovery=={}
    // What a rotated key signs beside its rotation is void, whichever the walk meets first (fold_voids).
    if by_recovery && entry.type!=.Recovery_Rotate {
        for x in f.recoveries {
            if f.log.items[x].entry.type==.Recovery_Rotate && log_concurrent(f.log,int(x),e) && user_recovery_before(f,int(x))==entry.author {return false}
        }
    }
    #partial switch entry.type {
    case .Device_Add:
        b,_,_:=body_head(entry.body,Device_Add_Body)
        known,_,_:=user_key_before(f,b.device,e)
        return (by_recovery || by_device || by_passkey) && !known && device_proof_valid(b.device,transmute([32]u8)f.log.id,b.dh,b.kem[:],b.proof)
    case .Device_Revoke:
        b,_,_:=body_head(entry.body,Device_Revoke_Body)
        known,_,_:=user_key_before(f,b.device,e)
        return (by_recovery || by_device) && known
    case .Recovery_Rotate:
        b,_,_:=body_head(entry.body,Recovery_Rotate_Body)
        return (by_recovery || (recovery=={} && by_device)) && device_proof_valid(b.recovery,transmute([32]u8)f.log.id,b.dh,b.kem[:],b.proof)
    case .Web_Key_Add:
        key,ok:=web_key_of(entry.body)
        known,_,_:=user_key_before(f,key,e)
        return (by_recovery || by_device || by_passkey) && ok && !known
    }
    return false
}

@(private)
user_apply :: proc(f:^User_Fold) {
    for i in f.log.order {
        e:=int(i)
        if !f.valid[e] {continue}
        entry:=&f.log.items[e].entry
        #partial switch entry.type {
        case .User_Genesis:
            b,_,_:=body_head(entry.body,User_Genesis_Body)
            f.recovery,f.recovery_dh,f.recovery_at=b.recovery,b.recovery_dh,u32(e)
            append(&f.devices,Device{key=b.device,dh=b.dh,added=u32(e)})
        case .Passkey_Genesis:
            if key,ok:=web_key_of(entry.body);ok {append(&f.web_keys,User_Web_Key{key=key,added=u32(e)})}
        case .Device_Add:
            b,_,_:=body_head(entry.body,Device_Add_Body)
            if user_device_index(f,b.device)<0 {append(&f.devices,Device{key=b.device,dh=b.dh,added=u32(e)})}
        case .Device_Revoke:
            b,_,_:=body_head(entry.body,Device_Revoke_Body)
            for &d in f.devices {
                if d.key==b.device && !d.revoked {d.revoked,d.revoke=true,u32(e)}
            }
            for &w in f.web_keys {
                if w.key==b.device && !w.revoked {w.revoked,w.revoke=true,u32(e)}
            }
        case .Recovery_Rotate:
            b,_,_:=body_head(entry.body,Recovery_Rotate_Body)
            f.recovery,f.recovery_dh,f.recovery_at=b.recovery,b.dh,u32(e)
        case .Web_Key_Add:
            if key,ok:=web_key_of(entry.body);ok && user_web_key_index(f,key)<0 {append(&f.web_keys,User_Web_Key{key=key,added=u32(e)})}
        }
    }
}

// The ML-KEM encapsulation key of device d of the user, as the entry that
// added it holds it.
user_device_kem :: proc(f:^User_Fold,d:Device) -> []u8 {
    entry:=&f.log.items[d.added].entry
    #partial switch entry.type {
    case .User_Genesis: return entry.body[offset_of(User_Genesis_Body,kem):][:KEM_PUBLIC]
    case .Device_Add: return entry.body[offset_of(Device_Add_Body,kem):][:KEM_PUBLIC]
    }
    return nil
}

// The ML-KEM encapsulation key of the user's recovery key now; nil when it has none.
user_recovery_kem :: proc(f:^User_Fold) -> []u8 {
    if f.recovery=={} {return nil}
    entry:=&f.log.items[f.recovery_at].entry
    #partial switch entry.type {
    case .User_Genesis: return entry.body[offset_of(User_Genesis_Body,recovery_kem):][:KEM_PUBLIC]
    case .Recovery_Rotate: return entry.body[offset_of(Recovery_Rotate_Body,kem):][:KEM_PUBLIC]
    }
    return nil
}

// Where key is a device of the state, -1 when it is not one. A revoked
// device stays, so it cannot be added again.
user_device_index :: proc(f:^User_Fold,key:Key) -> int {
    for d,i in f.devices {
        if d.key==key {return i}
    }
    return -1
}

// Whether device of the user may have signed entry e of log l: it is one of
// the user's devices and, once revoked, e is in the causal past of the
// revocation in the user's log, or stands against it in l (log_witnessed).
user_device_allows :: proc(f:^User_Fold,device:Key,l:^Log,e:int) -> bool {
    k:=user_device_index(f,device)
    if k<0 {return false}
    d:=f.devices[k]
    return !d.revoked || user_revocation_holds(f,int(d.revoke),l,e)
}

@(private)
user_revocation_holds :: proc(f:^User_Fold,revoke:int,l:^Log,e:int) -> bool {
    if l==f.log {return log_before(l,e,revoke)}
    return log_witnessed(l,f.log.items[revoke].address,e)
}

// Where key is a web key of the state, -1 when it is not one.
user_web_key_index :: proc(f:^User_Fold,key:Key) -> int {
    for w,i in f.web_keys {
        if w.key==key {return i}
    }
    return -1
}

// Whether the passkey of web key id key may have signed entry e of l: the
// entry's author_ctx is a valid entry of the user's log whose causal past
// added the key, and, once revoked, e stands against its revocation.
user_web_key_allows :: proc(f:^User_Fold,key:Key,l:^Log,e:int) -> bool {
    k:=user_web_key_index(f,key)
    if k<0 {return false}
    w:=f.web_keys[k]
    at:=log_find(f.log,l.items[e].entry.author_ctx)
    if at<0 || !f.valid[at] || !log_within(f.log,int(w.added),at) {return false}
    return !w.revoked || user_revocation_holds(f,int(w.revoke),l,e)
}

// Whether entry e of l is the user's: by one of its devices, or by one of its
// passkeys for a WebAuthn entry.
user_signed :: proc(f:^User_Fold,l:^Log,e:int) -> bool {
    entry:=&l.items[e].entry
    if entry.sig_kind==.WebAuthn {return user_web_key_allows(f,entry.author,l,e)}
    return user_device_allows(f,entry.author,l,e)
}

// Whether device is a device of the user not revoked.
user_device_active :: proc(f:^User_Fold,device:Key) -> bool {
    k:=user_device_index(f,device)
    return k>=0 && !f.devices[k].revoked
}

// Whether the user has or had a device or a recovery key of X25519 key dh.
user_dh_known :: proc(f:^User_Fold,dh:Dh_Key) -> bool {
    for d in f.devices {
        if d.dh==dh {return true}
    }
    for x in f.recoveries {
        entry:=&f.log.items[x].entry
        #partial switch entry.type {
        case .User_Genesis: if (^User_Genesis_Body)(raw_data(entry.body)).recovery_dh==dh {return true}
        case .Recovery_Rotate: if (^Recovery_Rotate_Body)(raw_data(entry.body)).dh==dh {return true}
        }
    }
    return false
}

// The user whose active device has the X25519 key dh.
user_dh_active :: proc(f:^User_Fold,dh:Dh_Key) -> bool {
    for d in f.devices {
        if d.dh==dh && !d.revoked {return true}
    }
    return false
}

// Whether the user had a recovery key at ctx, an entry of its log: always for
// one born with it, and for one born of a passkey once a valid
// Recovery_Rotate is in ctx's causal past or is ctx.
user_recovered_at :: proc(f:^User_Fold,ctx:store.Hash) -> bool {
    g:=log_find(f.log,f.log.id)
    if g>=0 && f.log.items[g].entry.type==.User_Genesis {return true}
    at:=log_find(f.log,ctx)
    if at<0 || !f.valid[at] {return false}
    for x in f.recoveries {
        if f.log.items[x].entry.type==.Recovery_Rotate && log_within(f.log,int(x),at) {return true}
    }
    return false
}

// The entry of the user's log that an entry signed by a key the user added at
// added names as its author_ctx: a head whose causal past holds the add and,
// when the user has one, a recovery key; added itself when no head does.
user_context :: proc(f:^User_Fold,added:store.Hash) -> store.Hash {
    k:=log_find(f.log,added)
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if k<0 || log_heads(f.log,&heads)!=.None {return added}
    best:=added
    for h in heads {
        at:=log_find(f.log,h)
        if at<0 || !f.valid[at] || !log_within(f.log,k,at) {continue}
        if user_recovered_at(f,h) {return h}
        if best==added {best=h}
    }
    return best
}

// The role a user without a recovery key acts with: at most writer, so no
// one holds the org's administration on a passkey alone.
@(private)
role_recovered :: proc(role:Role,recovered:bool) -> Role {return recovered?role:min(role,Role.Writer)}

// --- Org_Log ---

Member :: struct {user:Log_Id,role:Role}
Org_Project :: struct {id:Log_Id,public:bool}
Org_Scope :: struct {project:Log_Id,scope:Scope_Id,readers:Role,history:bool,entry:u32}
Org_Policy :: struct {project:Log_Id,bookmark:string,approvals:int,entry:u32}
Org_Node :: struct {key:Key,dh:Dh_Key,modes:Node_Modes,entry:u32}
Org_Public :: struct {project:Log_Id,fingerprint:store.Hash,path:string} // path into the log's bytes
Org_Grant :: struct {entry:u32,address:store.Hash,issuer:Log_Id,grant:Grant} // a valid Grant, its issuer's user

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
    revoked:[dynamic]store.Hash, // grants revoked
    nodes:[dynamic]Org_Node,
    publics:[dynamic]Org_Public,
    granted:[dynamic]Org_Grant,
    about:Subject_Lists,     // valid entries about each subject (org_subject; a genesis is about its owner): what org_role_at replays
    authored:Subject_Lists,  // valid entries by each member
    transfers:[dynamic]u32,  // valid Owner_Transfers
    authors:[]u32,           // of each entry, its author among users, +1
    allocator:runtime.Allocator,
}

org_fold :: proc(f:^Org_Fold,l:^Log,users:[]^User_Fold,allocator:=context.allocator) -> Error {
    f^={log=l,users=users,allocator=allocator}
    f.members=make([dynamic]Member,allocator)
    f.removed=make([dynamic]Log_Id,allocator)
    f.projects=make([dynamic]Org_Project,allocator)
    f.scopes=make([dynamic]Org_Scope,allocator)
    f.policies=make([dynamic]Org_Policy,allocator)
    f.revoked=make([dynamic]store.Hash,allocator)
    f.nodes=make([dynamic]Org_Node,allocator)
    f.publics=make([dynamic]Org_Public,allocator)
    f.granted=make([dynamic]Org_Grant,allocator)
    if l.kind!=.Org || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,f,f.valid)
}

org_fold_destroy :: proc(f:^Org_Fold) {
    allocator:=f.allocator
    delete(f.members)
    delete(f.removed)
    delete(f.projects)
    delete(f.scopes)
    delete(f.policies)
    delete(f.revoked)
    delete(f.nodes)
    delete(f.publics)
    delete(f.granted)
    delete(f.transfers)
    subjects_destroy(&f.about,allocator)
    subjects_destroy(&f.authored,allocator)
    delete(f.authors,allocator)
    delete(f.valid,allocator)
    f^={}
}

// The fold of the user of id among those the org fold has; nil when none.
org_user :: proc(f:^Org_Fold,user:Log_Id) -> ^User_Fold {
    for u in f.users {
        if u.log.id==user {return u}
    }
    return nil
}

// The role of user in the state; None when not a member. A user without a
// recovery key acts as a writer at most.
org_role :: proc(f:^Org_Fold,user:Log_Id) -> Role {
    for m in f.members {
        if m.user!=user {continue}
        if u:=org_user(f,user);u!=nil {return role_recovered(m.role,u.recovery!={})}
        return m.role
    }
    return .None
}

// The user of the folds whose device or passkey may have signed entry e of l.
@(private)
author_user :: proc(users:[]^User_Fold,l:^Log,e:int) -> ^User_Fold {
    for u in users {
        if user_signed(u,l,e) {return u}
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
    case .Project_Add:
        b,_,_:=body_head(entry.body,Project_Add_Body)
        return b.project,true
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
org_removal :: proc "contextless" (t:Entry_Type) -> bool {
    #partial switch t {
    case .Member_Remove,.Scope_Remove,.Grant_Revoke,.Node_Remove: return true
    }
    return false
}

// The role of user replayed from the valid entries about it and the owner
// transfers in the causal past of e, and e itself when within.
@(private)
org_role_replay :: proc(f:^Org_Fold,user:Log_Id,e:int,within:bool) -> Role {
    seen :: #force_inline proc(f:^Org_Fold,x,e:int,within:bool) -> bool {return within?log_within(f.log,x,e):log_before(f.log,x,e)}
    entries:=make([dynamic]u32,context.temp_allocator)
    for x:=subjects_first(&f.about,user);x>=0;x=subjects_next(&f.about,x) {
        if seen(f,x,e,within) {append(&entries,u32(x))}
    }
    for x in f.transfers {
        if seen(f,int(x),e,within) && !slice.contains(entries[:],x) {append(&entries,x)}
    }
    // In the order of the walk: rank is a position, one per entry.
    ranked:=make([]u32,len(entries),context.temp_allocator)
    for x,k in entries {ranked[k]=f.log.rank[x]}
    slice.sort(ranked)
    role:=Role.None
    for r in ranked {
        x:=f.log.order[r]
        entry:=&f.log.items[x].entry
        #partial switch entry.type {
        case .Org_Genesis: role=.Owner
        case .Member_Add:
            b,_,_:=body_head(entry.body,Member_Body)
            if role==.None {role=b.role}
        case .Member_Remove: if role!=.Owner {role=.None}
        case .Role_Set:
            b,_,_:=body_head(entry.body,Member_Body)
            if role!=.None && role!=.Owner {role=b.role}
        case .Owner_Transfer:
            b,_,_:=body_head(entry.body,Subject_Body)
            if b.subject==user {
                if role!=.None {role=.Owner}
            } else if role==.Owner {
                role=.Admin
            }
        }
    }
    return role
}

// The role the author u of entry e of the org's log acts with there.
@(private)
org_role_author :: proc(f:^Org_Fold,u:^User_Fold,e:int) -> Role {
    return role_recovered(org_role_replay(f,u.log.id,e,false),user_recovered_at(u,f.log.items[e].entry.author_ctx))
}

// Whether a valid removal walked about subject is concurrent with e.
@(private)
org_removed_concurrently :: proc(f:^Org_Fold,subject:store.Hash,e:int) -> bool {
    for x:=subjects_first(&f.about,subject);x>=0;x=subjects_next(&f.about,x) {
        if org_removal(f.log.items[x].entry.type) && log_concurrent(f.log,x,e) {return true}
    }
    return false
}

// Whether subject was there in the causal past of e: its last Add, Remove
// or Grant_Revoke there says.
@(private)
org_present_before :: proc(f:^Org_Fold,subject:store.Hash,e:int) -> bool {
    last:=-1
    for x:=subjects_first(&f.about,subject);x>=0;x=subjects_next(&f.about,x) {
        if log_before(f.log,x,e) && (last<0 || f.log.rank[x]>f.log.rank[last]) {last=x}
    }
    if last<0 {return false}
    #partial switch f.log.items[last].entry.type {
    case .Scope_Remove,.Node_Remove,.Grant_Revoke: return false
    }
    return true
}

// The rules of an Org_Log, each in the state of the entry's causal past.
@(private)
org_authorized :: proc(f:^Org_Fold,e:int) -> bool {
    entry:=&f.log.items[e].entry
    u:=author_user(f.users,f.log,e)
    if u==nil {return false}
    for v,k in f.users {
        if v==u {f.authors[e]=u32(k+1)}
    }
    if entry.type==.Org_Genesis {
        b,_,_:=body_head(entry.body,Org_Genesis_Body)
        return u.log.id==b.owner && user_recovered_at(u,entry.author_ctx)
    }
    role:=org_role_author(f,u,e)
    if role==.None {return false}
    // A removal wins over what was written concurrently about its subject, and over what a removed member signed concurrently.
    if !org_removal(entry.type) {
        if s,has:=org_subject(f,e);has && org_removed_concurrently(f,s,e) {return false}
        if org_removed_concurrently(f,u.log.id,e) {return false}
    }
    #partial switch entry.type {
    case .Member_Add:
        b,_,_:=body_head(entry.body,Member_Body)
        return role>=.Admin && b.role<=role && org_role_replay(f,b.user,e,false)==.None
    case .Member_Remove:
        b,_,_:=body_head(entry.body,Subject_Body)
        target:=org_role_replay(f,b.subject,e,false)
        return target!=.None && target!=.Owner && (role>=.Admin || b.subject==u.log.id)
    case .Role_Set:
        b,_,_:=body_head(entry.body,Member_Body)
        target:=org_role_replay(f,b.user,e,false)
        return role>=.Admin && target!=.None && target!=.Owner && b.role<=role
    case .Owner_Transfer:
        b,_,_:=body_head(entry.body,Subject_Body)
        return role==.Owner && org_role_replay(f,b.subject,e,false)!=.None && b.subject!=u.log.id
    case .Project_Add:
        b,_,_:=body_head(entry.body,Project_Add_Body)
        return role>=.Admin && !org_present_before(f,b.project,e)
    case .Scope_Add:
        b,_,_:=body_head(entry.body,Scope_Add_Body)
        return role>=.Admin && org_present_before(f,b.project,e) && !org_present_before(f,scope_subject(b.project,b.scope),e)
    case .Scope_Remove:
        b,_,_:=body_head(entry.body,Scope_Remove_Body)
        return role>=.Admin && org_present_before(f,scope_subject(b.project,b.scope),e)
    case .Policy_Set:
        b,_,_:=body_head(entry.body,Policy_Set_Body)
        return role>=.Admin && org_present_before(f,b.project,e)
    case .Grant:
        g,_:=grant_decode(entry.body)
        return role>=.Admin && g.issuer==entry.author && g.org==f.log.id && signature_valid(g.issuer,entry.body[:len(entry.body)-size_of(Signature)],g.signature)
    case .Grant_Revoke: return role>=.Admin
    case .Node_Add:
        b,_,_:=body_head(entry.body,Node_Add_Body)
        return role>=.Admin && !org_present_before(f,store.Hash(b.node),e)
    case .Node_Remove:
        b,_,_:=body_head(entry.body,Node_Remove_Body)
        return role>=.Admin && org_present_before(f,store.Hash(b.node),e)
    case .Public_Add:
        b,_,_:=body_head(entry.body,Public_Add_Body)
        return role>=.Admin && org_present_before(f,b.project,e)
    case .Witness:
        // A member witnesses a device's revocation; what the org removes is in its own log already.
        b,_,_:=body_head(entry.body,Witness_Body)
        return b.log!=f.log.id && witness_valid(nil,f.users,f.log,e)
    }
    return false
}

@(private)
org_member_role :: proc(f:^Org_Fold,user:Log_Id) -> Role {
    for m in f.members {
        if m.user==user {return m.role}
    }
    return .None
}

@(private)
org_apply :: proc(f:^Org_Fold) {
    for i in f.log.order {
        e:=int(i)
        if !f.valid[e] {continue}
        entry:=&f.log.items[e].entry
        #partial switch entry.type {
        case .Org_Genesis:
            b,_,_:=body_head(entry.body,Org_Genesis_Body)
            f.owner=b.owner
            append(&f.members,Member{b.owner,.Owner})
        case .Member_Add:
            b,_,_:=body_head(entry.body,Member_Body)
            if org_member_role(f,b.user)==.None {append(&f.members,Member{b.user,b.role})}
        case .Member_Remove:
            b,_,_:=body_head(entry.body,Subject_Body)
            if !slice.contains(f.removed[:],b.subject) {append(&f.removed,b.subject)}
            for m,k in f.members {
                if m.user==b.subject && m.role!=.Owner {
                    ordered_remove(&f.members,k)
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
            if org_member_role(f,b.subject)==.None {break}
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
            for s,k in f.scopes {
                if s.project==b.project && s.scope==b.scope {
                    ordered_remove(&f.scopes,k)
                    break
                }
            }
        case .Policy_Set:
            b,_,r,_:=policy_parts(entry.body)
            bookmark:=tail_string(&r)
            for p,k in f.policies {
                if p.project==b.project && p.bookmark==bookmark {
                    ordered_remove(&f.policies,k)
                    break
                }
            }
            append(&f.policies,Org_Policy{b.project,bookmark,int(b.approvals),u32(e)})
        case .Grant:
            if g,ge:=grant_decode(entry.body);ge==.None && f.authors[e]!=0 {
                append(&f.granted,Org_Grant{u32(e),store.address_of_bytes(entry.body),f.users[f.authors[e]-1].log.id,g})
            }
        case .Grant_Revoke:
            b,_,_:=body_head(entry.body,Subject_Body)
            append(&f.revoked,b.subject)
        case .Node_Add:
            b,_,_:=body_head(entry.body,Node_Add_Body)
            if org_node(f,b.node)<0 {append(&f.nodes,Org_Node{b.node,b.dh,b.modes,u32(e)})}
        case .Node_Remove:
            b,_,_:=body_head(entry.body,Node_Remove_Body)
            if k:=org_node(f,b.node);k>=0 {ordered_remove(&f.nodes,k)}
        case .Public_Add:
            b,tail,_:=body_head(entry.body,Public_Add_Body)
            append(&f.publics,Org_Public{b.project,b.fingerprint,string(tail)})
        }
    }
}

// The role of user in the state of the org's entry head and its causal past.
org_role_at :: proc(f:^Org_Fold,user:Log_Id,head:int) -> Role {
    return org_role_replay(f,user,head,true)
}

// The role user held for entry e of l, a Project, Proposal or Keyring log,
// signed under the org's entry at: its role there, lowered by each valid
// Member_Remove or Role_Set of the user the causal past of at does not hold
// that e does not stand against in l (log_witnessed), or that the org entry
// l's genesis was signed under holds (l was born after it).
@(private)
org_role_signed_at :: proc(f:^Org_Fold,user:Log_Id,at:int,l:^Log,e:int) -> Role {
    role:=org_role_at(f,user,at)
    born:=log_born_at(f,l)
    for x:=subjects_first(&f.about,user);x>=0 && role!=.None;x=subjects_next(&f.about,x) {
        entry:=&f.log.items[x].entry
        if (entry.type!=.Member_Remove && entry.type!=.Role_Set) || log_within(f.log,x,at) {continue}
        if !(born>=0 && log_within(f.log,x,born)) && log_witnessed(l,f.log.items[x].address,e) {continue}
        if entry.type==.Member_Remove {
            role=.None
        } else {
            b,_,_:=body_head(entry.body,Member_Body)
            role=min(role,b.role)
        }
    }
    return role
}

// The org's entry that entry e of l names as its org_ctx, valid; -1 when it
// names none this end holds as valid.
org_context_of :: proc(f:^Org_Fold,l:^Log,e:int) -> int {
    x:=log_find(f.log,l.items[e].entry.org_ctx)
    if x<0 || !f.valid[x] {return -1}
    return x
}

// The role the author u of entry e of l, a Project, Proposal or Keyring log,
// held when it signed (org_role_signed_at at its org_ctx); None when its
// org_ctx is no valid entry of the org, or its key was revoked before l was
// born (revoked_before_log).
org_role_signed :: proc(f:^Org_Fold,u:^User_Fold,l:^Log,e:int) -> Role {
    at:=org_context_of(f,l,e)
    if at<0 || revoked_before_log(f,u,l,e) {return .None}
    return role_recovered(org_role_signed_at(f,u.log.id,at,l,e),user_recovered_at(u,l.items[e].entry.author_ctx))
}

// The org's entry a member signs a Project, Proposal or Keyring entry under:
// the head where its role is highest, the first by address on a tie.
org_context :: proc(f:^Org_Fold,user:Log_Id) -> store.Hash {
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if log_heads(f.log,&heads)!=.None || len(heads)==0 {return {}}
    best,role:=heads[0],Role.None
    for h,i in heads {
        k:=log_find(f.log,h)
        if r:=org_role_at(f,user,k);i==0 || r>role {best,role=h,r}
    }
    return best
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
    head.magic,head.version,head.reserved,head.reserved2,head.path_len=KAI_MAGIC,VERSIONS[.Grant],0,{},u16(len(g.path))
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
    if r.short || g.magic!=KAI_MAGIC || g.version!=VERSIONS[.Grant] || g.reserved!=0 || !zero(g.reserved2[:]) || g.path_len>GRANT_PATH_MAX {return {},.Corrupt}
    if transmute(u8)g.rights&~transmute(u8)RIGHTS_ALL!=0 || g.org=={} || g.org_head=={} || g.not_after<=g.not_before {return {},.Corrupt}
    g.path=string(read_bytes(&r,int(g.path_len)))
    g.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) || !utf8.valid_string(g.path) {return {},.Corrupt}
    return g,.None
}

// Checks the grant of bytes against the org now, for a connection or a
// record a peer offers: signed by its issuer, an admin at org_head and still
// one, its rights within the issuer's, at most 30 days long, now inside it,
// and not revoked.
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

// The grant the org's log carries under which key signs with right on
// project now; ok is false when none holds. The ddc right is over the org's
// derived data, whatever project the grant names.
org_grant_right :: proc(f:^Org_Fold,key:Key,right:Right,project:Log_Id,now:i64) -> (g:Grant,ok:bool) {
    if key=={} {return}
    for &x in f.granted {
        if x.grant.subject_key!=key {continue}
        held,e:=grant_verify(f,f.log.items[x.entry].entry.body,now)
        if e==.None && right in held.rights && (held.project=={} || held.project==project || right==.DDC) {return held,true}
    }
    return
}

// Whether entry e of l, a Project, Proposal or Keyring log, by key, held a
// grant of right on project when it was signed: the grant is in the causal
// past of the entry's org_ctx, so is its issuer as an admin there with the
// rights it gave; the entry's time, never before its causal past or its
// org_ctx's, is inside the grant; and no revocation of the grant, nor removal
// or lowering of its issuer, is in that past, in the past of the org entry
// l's genesis was signed under, or has reached l without e (log_witnessed).
org_grant_signed :: proc(f:^Org_Fold,key:Key,right:Right,project:Log_Id,l:^Log,e:int) -> bool {
    at:=org_context_of(f,l,e)
    if key=={} || at<0 {return false}
    born:=log_born_at(f,l)
    time:=max(l.time[e],f.log.time[at])
    grants: for &x in f.granted {
        g:=&x.grant
        if g.subject_key!=key || right not_in g.rights || (g.project!={} && g.project!=project) {continue}
        if !log_within(f.log,int(x.entry),at) || time<g.not_before || time>g.not_after || g.not_after-g.not_before>GRANT_NANOSECONDS_MAX {continue}
        for r:=subjects_first(&f.about,x.address);r>=0;r=subjects_next(&f.about,r) {
            if f.log.items[r].entry.type!=.Grant_Revoke {continue}
            if log_within(f.log,r,at) || (born>=0 && log_within(f.log,r,born)) || !log_witnessed(l,f.log.items[r].address,e) {continue grants}
        }
        issued:=org_role_signed_at(f,x.issuer,at,l,e)
        head:=log_find(f.log,g.org_head)
        if head<0 || issued<.Admin {continue}
        if then:=org_role_at(f,x.issuer,head);then<.Admin || g.rights&~role_rights(min(then,issued))!={} {continue}
        return true
    }
    return false
}

// Whether a grant's path scope covers path: an empty scope covers the whole
// project; otherwise the scope is a pattern as Scope_Add takes (glob_match).
grant_covers :: proc(scope,path:string) -> bool {return scope=="" || glob_match(scope,path)}

// --- Project_Log ---

Bookmark_Target :: struct {name:string,target:Revision}

Project_Fold :: struct {
    log:^Log,
    org:^Org_Fold,
    proposals:[]^Proposal_Fold, // the proposals moves land, each as it was at the heads its move names, by move (project_snapshots)
    valid:[]bool,
    org_id:Log_Id,
    public:bool,
    bookmarks:[dynamic]Bookmark_Target, // sorted by name then target: a name with several targets is diverged
    allocator:runtime.Allocator,
}

project_fold :: proc(f:^Project_Fold,l:^Log,org:^Org_Fold,proposals:[]^Proposal_Fold={},allocator:=context.allocator) -> Error {
    f^={log=l,org=org,proposals=proposals,allocator=allocator}
    f.bookmarks=make([dynamic]Bookmark_Target,allocator)
    if l.kind!=.Project || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,f,f.valid)
}

project_fold_destroy :: proc(f:^Project_Fold) {
    delete(f.bookmarks)
    delete(f.valid,f.allocator)
    f^={}
}

// The targets of bookmark: more than one when moves diverged.
project_bookmark :: proc(f:^Project_Fold,name:string,out:^[dynamic]Revision) {
    clear(out)
    for b in f.bookmarks {
        if b.name==name {append(out,b.target)}
    }
}

// The rules of a Project_Log: an admin starts it, a writer moves a shared
// bookmark, as each was when it signed; a move of a bookmark a policy guards
// names a proposal and the heads of its log, and that proposal as it was there
// meets the policy, unless the policy's heads hold the move. What becomes of
// the proposal later changes nothing of the move.
@(private)
project_authorized :: proc(f:^Project_Fold,e:int) -> bool {
    entry:=&f.log.items[e].entry
    u:=author_user(f.org.users,f.log,e)
    if u==nil {return false}
    role:=org_role_signed(f.org,u,f.log,e)
    if entry.type==.Project_Genesis {
        b,_,_:=body_head(entry.body,Project_Genesis_Body)
        return b.org==f.org.log.id && role>=.Admin
    }
    if entry.type==.Witness {return role>=.Writer && witness_valid(f.org,f.org.users,f.log,e)}
    if entry.type!=.Bookmark_Move || role<.Writer {return false}
    b,_,_,name:=move_parts(entry.body)
    pf:=move_proposal(f,e,b)
    if pf!=nil && pf.kept {return true}
    if pf!=nil && pf.conflicted {return false}
    for &p in f.org.policies {
        if p.project!=f.log.id || p.bookmark!=name {continue}
        pb,heads,_,_:=policy_parts(f.org.log.items[p.entry].entry.body)
        if pb.approvals==0 && pb.checks==0 {return true}
        // A move the policy's heads hold came before it.
        for h in heads {
            if k:=log_find(f.log,h);k>=0 && log_within(f.log,e,k) {return true}
        }
        return pf!=nil && proposal_policy(f.org,&p,pf)==.None
    }
    return true
}

@(private)
project_apply :: proc(f:^Project_Fold) {
    for i in f.log.order {
        e:=int(i)
        if !f.valid[e] {continue}
        entry:=&f.log.items[e].entry
        if entry.type==.Project_Genesis {
            b,_,_:=body_head(entry.body,Project_Genesis_Body)
            f.org_id,f.public=b.org,bool(b.public)
            continue
        }
        if entry.type!=.Bookmark_Move {continue}
        b,_,from,name:=move_parts(entry.body)
        for k:=len(f.bookmarks)-1;k>=0;k-=1 {
            if f.bookmarks[k].name==name && slice.contains(from,f.bookmarks[k].target) {ordered_remove(&f.bookmarks,k)}
        }
        have:=false
        for t in f.bookmarks {have||=t.name==name && t.target==b.to}
        if have {continue}
        // Kept sorted by name, then target: one insertion.
        at:=len(f.bookmarks)
        for t,k in f.bookmarks {
            if t.name>name || (t.name==name && hash_less(b.to,t.target)) {
                at=k
                break
            }
        }
        inject_at(&f.bookmarks,at,Bookmark_Target{name,b.to})
    }
}

// The proposal the move e lands, as it was at the heads the move names,
// folded and settled (project_snapshots): open, on this project, at the
// move's revision. nil when the move names none, or this end lacks those
// entries yet.
@(private)
move_proposal :: proc(f:^Project_Fold,e:int,b:Bookmark_Move_Body) -> ^Proposal_Fold {
    if b.proposal=={} {return nil}
    move:=f.log.items[e].address
    k,found:=slice.binary_search_by(f.proposals,move,proc(pf:^Proposal_Fold,move:store.Hash) -> slice.Ordering {
        if pf.move==move {return .Equal}
        return hash_less(pf.move,move)?.Less:.Greater
    })
    if !found {return nil}
    pf:=f.proposals[k]
    if pf.kept || (pf.log.id==b.proposal && pf.project==f.log.id && pf.status==.Open && pf.revision==b.to) {return pf}
    return nil
}

// --- Proposal_Log (its writing, re-anchoring and landing: proposal.odin) ---

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
    conflicted:bool,                     // a change of the stack has a conflict, as proposal_settle found
    checks:[dynamic]Proposal_Check,      // of revision, the last of each name
    comments:int,
    move:store.Hash,                     // the move this fold is the snapshot of, as project_snapshots made it
    kept:bool,                           // the move's verdict was kept (landings_read): no log was folded
    statuses:[dynamic]u32,               // the walk: valid Open, Close, Reopen and Land
    revises:[dynamic]u32,                // valid Revise
    allocator:runtime.Allocator,
}

proposal_fold :: proc(f:^Proposal_Fold,l:^Log,org:^Org_Fold,allocator:=context.allocator) -> Error {
    f^={log=l,org=org,allocator=allocator}
    f.verdicts=make([dynamic]Proposal_Approval,allocator)
    f.checks=make([dynamic]Proposal_Check,allocator)
    if l.kind!=.Proposal || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    fold_run(l,f,f.valid) or_return
    proposal_count(f)
    return .None
}

proposal_fold_destroy :: proc(f:^Proposal_Fold) {
    delete(f.verdicts)
    delete(f.checks)
    delete(f.statuses)
    delete(f.revises)
    delete(f.valid,f.allocator)
    f^={}
}

@(private)
proposal_count :: proc(f:^Proposal_Fold) {
    f.approvals=0
    for v in f.verdicts {
        if v.verdict==.Approve && v.revision==f.revision {f.approvals+=1}
    }
}

// The status of the proposal in the causal past of e.
@(private)
proposal_status_before :: proc(f:^Proposal_Fold,e:int) -> Proposal_Status {
    status:=Proposal_Status.Open
    for x in f.statuses {
        if !log_before(f.log,int(x),e) {continue}
        #partial switch f.log.items[x].entry.type {
        case .Proposal_Open,.Proposal_Reopen: status=.Open
        case .Proposal_Close: status=.Closed
        case .Proposal_Land: status=.Landed
        }
    }
    return status
}

// The head revision of the last Revise in the causal past of e, zero when none.
proposal_revision_before :: proc(f:^Proposal_Fold,e:int) -> Revision {
    #reverse for x in f.revises {
        if !log_before(f.log,int(x),e) {continue}
        b,tail,_:=body_head(f.log.items[x].entry.body,Proposal_Revise_Body)
        return slice.reinterpret([]Stack_Item,tail)[b.count-1].revision
    }
    return {}
}

// The rules of a Proposal_Log, each against the proposal in the entry's
// causal past and its author's role when it signed: a writer opens, the
// opener or a writer revises, any member comments, a writer gives a verdict
// and signs a check (or a key under a grant of the check right), the opener or
// an admin closes and reopens.
@(private)
proposal_authorized :: proc(f:^Proposal_Fold,e:int) -> bool {
    entry:=&f.log.items[e].entry
    u:=author_user(f.org.users,f.log,e)
    status:=proposal_status_before(f,e)
    if u==nil {
        // A runner outside the org checks under a grant of the Check right.
        return entry.type==.Proposal_Check && status==.Open && org_grant_signed(f.org,entry.author,.Check,f.project,f.log,e)
    }
    role:=org_role_signed(f.org,u,f.log,e)
    if role==.None {return false}
    if entry.type==.Proposal_Open {
        b,_,_:=body_head(entry.body,Proposal_Open_Body)
        f.opener=u.log.id
        return role>=.Writer && org_project_index(f.org,b.project)>=0
    }
    #partial switch entry.type {
    case .Witness: return witness_valid(f.org,f.org.users,f.log,e)
    case .Proposal_Revise: return status==.Open && (u.log.id==f.opener || role>=.Writer)
    case .Proposal_Comment: return true
    case .Proposal_Verdict,.Proposal_Check: return status==.Open && role>=.Writer
    case .Proposal_Land: return status==.Open && role>=.Writer && proposal_revision_before(f,e)!={}
    case .Proposal_Close: return status==.Open && (u.log.id==f.opener || role>=.Admin)
    case .Proposal_Reopen: return status==.Closed && (u.log.id==f.opener || role>=.Admin)
    }
    return false
}

// The state of the valid entries in order. A check counts for the revision of
// the last Revise in its causal past, and only when it names that revision.
@(private)
proposal_apply :: proc(f:^Proposal_Fold) {
    for i in f.log.order {
        e:=int(i)
        if !f.valid[e] {continue}
        entry:=&f.log.items[e].entry
        #partial switch entry.type {
        case .Proposal_Open: f.status=.Open
        case .Proposal_Revise:
            b,tail,_:=body_head(entry.body,Proposal_Revise_Body)
            f.revision=slice.reinterpret([]Stack_Item,tail)[b.count-1].revision
        case .Proposal_Comment: f.comments+=1
        case .Proposal_Verdict:
            u:=author_user(f.org.users,f.log,e)
            user:=u!=nil?u.log.id:{}
            b,_,_:=body_head(entry.body,Proposal_Verdict_Body)
            for v,k in f.verdicts {
                if v.user==user {
                    ordered_remove(&f.verdicts,k)
                    break
                }
            }
            append(&f.verdicts,Proposal_Approval{user,b.revision,b.verdict})
        case .Proposal_Land: f.status=.Landed
        case .Proposal_Close: f.status=.Closed
        case .Proposal_Reopen: f.status=.Open
        }
    }
    if f.revision=={} {return}
    checks: for i in f.log.order {
        e:=int(i)
        entry:=&f.log.items[e].entry
        if !f.valid[e] || entry.type!=.Proposal_Check {continue}
        b,tail,_:=body_head(entry.body,Proposal_Check_Body)
        if b.revision!=f.revision || proposal_revision_before(f,e)!=b.revision {continue}
        for &c in f.checks {
            if c.name==string(tail) {
                c.state=b.state
                continue checks
            }
        }
        append(&f.checks,Proposal_Check{string(tail),b.state})
    }
}

// --- Keyring_Log (the epochs of a scope's key; sealing: overlay.odin) ---

Keyring_Envelope :: struct {epoch:u32,envelope:Envelope}

Keyring_Fold :: struct {
    log:^Log,
    org:^Org_Fold,
    store:^store.Store, // where the envelopes of its epochs are
    valid:[]bool,
    project:Log_Id,
    scope:Scope_Id,
    epoch:u32, // the newest; 0 before the first
    envelopes:[dynamic]Keyring_Envelope, // those Envelope_Adds gave
    epochs:[dynamic]u32, // the walk: valid Epoch_Adds
    added:Subject_Lists, // valid Envelope_Adds by epoch and device
    allocator:runtime.Allocator,
}

keyring_fold :: proc(f:^Keyring_Fold,l:^Log,org:^Org_Fold,s:^store.Store,allocator:=context.allocator) -> Error {
    f^={log=l,org=org,store=s,allocator=allocator}
    f.envelopes=make([dynamic]Keyring_Envelope,allocator)
    if l.kind!=.Keyring || len(l.items)==0 {return .Invalid_Argument}
    valid,e:=make([]bool,len(l.items),allocator)
    if e!=nil {return .Out_Of_Memory}
    f.valid=valid
    return fold_run(l,f,f.valid)
}

keyring_fold_destroy :: proc(f:^Keyring_Fold) {
    delete(f.envelopes)
    delete(f.epochs)
    subjects_destroy(&f.added,f.allocator)
    delete(f.valid,f.allocator)
    f^={}
}

// The Epoch_Add of epoch that holds.
keyring_epoch :: proc(f:^Keyring_Fold,epoch:u32) -> (body:Epoch_Add_Body,ok:bool) {
    for x in f.epochs {
        if !f.valid[x] {continue}
        if b,_,_:=body_head(f.log.items[x].entry.body,Epoch_Add_Body);b.epoch==epoch {return b,true}
    }
    return
}

@(private)
envelope_subject :: proc(epoch:u32,dh:Dh_Key) -> store.Hash {
    bytes:[36]u8
    d:=dh
    copy(bytes[:32],d[:])
    put_u32(bytes[32:],epoch)
    return store.address_of_bytes(bytes[:])
}

// The rules of a Keyring_Log, against the epochs of the entry's causal past:
// a writer, as it was when it signed, starts it and one who also reads the
// scope adds the next epoch;
// concurrent epochs of one number: the first in order wins, the other is not
// authorized. A member who read the scope when it signed (a device that holds
// the key wraps it) adds an envelope to an epoch there for a device or a
// recovery key of a user who read the scope at the entry's org_ctx, unless an
// Envelope_Add gave that one before. Whether its target still reads is not
// asked here: an envelope of the newest epoch for one who no longer does is
// what keyring_needs_rotation finds.
@(private)
keyring_authorized :: proc(f:^Keyring_Fold,e:int) -> bool {
    entry:=&f.log.items[e].entry
    u:=author_user(f.org.users,f.log,e)
    if u==nil {return false}
    role:=org_role_signed(f.org,u,f.log,e)
    epoch:=u32(0)
    for x in f.epochs {
        if log_before(f.log,int(x),e) {
            b,_,_:=body_head(f.log.items[x].entry.body,Epoch_Add_Body)
            epoch=max(epoch,b.epoch)
        }
    }
    if entry.type==.Envelope_Add {
        b,_,_:=body_head(entry.body,Envelope_Add_Body)
        scope,ok:=keyring_scope(f)
        if !ok || role<max(scope.readers,Role.Reader) || b.epoch<1 || b.epoch>epoch || !envelope_target(f.org,scope,org_context_of(f.org,f.log,e),b.envelope.dh) {return false}
        for x:=subjects_first(&f.added,envelope_subject(b.epoch,b.envelope.dh));x>=0;x=subjects_next(&f.added,x) {
            if log_before(f.log,x,e) {return false}
        }
        return true
    }
    if role<.Writer {return false}
    #partial switch entry.type {
    case .Witness: return witness_valid(f.org,f.org.users,f.log,e)
    case .Keyring_Genesis:
        b,_,_:=body_head(entry.body,Keyring_Genesis_Body)
        return b.org==f.org.log.id && org_project_index(f.org,b.project)>=0
    case .Epoch_Add:
        b,_,_:=body_head(entry.body,Epoch_Add_Body)
        scope,ok:=keyring_scope(f)
        return ok && role>=scope.readers && b.epoch==epoch+1
    }
    return false
}

// Whether dh is the key of a device, revoked or not, or of a recovery key,
// rotated or not, of a user who read scope at the org's entry at: one an epoch may be wrapped
// for. It holds for good once it does.
@(private)
envelope_target :: proc(org:^Org_Fold,scope:Org_Scope,at:int,dh:Dh_Key) -> bool {
    if at<0 {return false}
    for u in org.users {
        if !user_dh_known(u,dh) {continue}
        return role_recovered(org_role_at(org,u.log.id,at),u.recovery!={})>=scope.readers
    }
    return false
}

@(private)
keyring_apply :: proc(f:^Keyring_Fold) {
    for i in f.log.order {
        e:=int(i)
        if !f.valid[e] {continue}
        entry:=&f.log.items[e].entry
        #partial switch entry.type {
        case .Keyring_Genesis:
            b,_,_:=body_head(entry.body,Keyring_Genesis_Body)
            f.project,f.scope=b.project,b.scope
        case .Epoch_Add:
            b,_,_:=body_head(entry.body,Epoch_Add_Body)
            f.epoch=max(f.epoch,b.epoch)
        case .Envelope_Add:
            b,_,_:=body_head(entry.body,Envelope_Add_Body)
            append(&f.envelopes,Keyring_Envelope{b.epoch,b.envelope})
        }
    }
}
