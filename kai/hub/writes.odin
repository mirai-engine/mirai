package hub

import "core:slice"
import "core:time"
import "mirai:kai"
import mnet "mirai:net"
import "mirai:store"

// Writes: entries of the user, org, project and proposal logs. The server
// drafts the bytes of an entry (the log's heads, the author's context and
// the time) and keeps what the browser's passkey, or a device, signed over
// them, once the log's fold takes it as every peer's would. A draft carries
// no challenge: the browser computes the BLAKE3 of the bytes it checked and
// signs that.
//
// A user makes an org here once its user has a recovery key, which the
// first device it links sets: the passkey signs the org's genesis and the
// Node_Add of this node, which then hosts the org (kai/node.odin), at most
// hosted_orgs of them per user. A project is born empty, by its genesis and
// the org's Project_Add: its files come from a machine.
//
// Landing a proposal is two entries, as kai/proposal.odin's proposal_land
// signs them: the Bookmark_Move of the project's log from the target's
// targets to the stack's final revision, naming the proposal and the heads
// of its log, then the proposal's Land naming that move. The browser names
// every field of the move from what it read (GET /api/proposals and the
// project's bookmarks); the draft is refused when the node folds otherwise,
// or when the proposal may not land.

Draft_Body :: struct {
    type:string,
    log:string,
    verdict:string,
    revision:string,
    text:string,
    change:string,
    path:string,
    reply_to:string,
    anchor:struct {kind:string,line,lines:u32},
    user:string,
    role:string,
    device:string, // device_add: the device's Ed25519 key, its X25519 and ML-KEM keys, its proof and name
    dh:string,
    kem:string,
    proof:string,
    name:string,
    owner:string,    // org_genesis: the session's user, which owns the org
    org:string,      // project_genesis: the org the project is of
    project:string,  // project_add: the project's log id
    public:bool,     // project_genesis and project_add
    node:string,     // node_add: this node's key, dh, modes and addresses, as GET /api/node gives them
    modes:[]string,
    addresses:[]Address_Body,
    proposal:string,      // bookmark_move: the proposal it lands
    bookmark:string,      // bookmark_move: the proposal's target
    heads:[]string,       // bookmark_move: the heads of the proposal's log it was checked at
    from:[]string,        // bookmark_move: the targets the bookmark moves from
    bookmark_move:string, // proposal_land: the move's address
}

Address_Body :: struct {kind:u8,port:u16,ip:string} // a Node_Address: kind 1 IPv4 or 2 IPv6, ip 32 hex

TYPE_TEXT :: [kai.Entry_Type]string{
    .None="",
    .User_Genesis="user_genesis",.Device_Add="device_add",.Device_Revoke="device_revoke",.Recovery_Rotate="recovery_rotate",.Web_Key_Add="web_key_add",
    .Org_Genesis="org_genesis",.Member_Add="member_add",.Member_Remove="member_remove",.Role_Set="role_set",.Owner_Transfer="owner_transfer",
    .Project_Add="project_add",.Scope_Add="scope_add",.Scope_Remove="scope_remove",.Policy_Set="policy_set",.Grant="grant",.Grant_Revoke="grant_revoke",
    .Node_Add="node_add",.Node_Remove="node_remove",
    .Project_Genesis="project_genesis",.Bookmark_Move="bookmark_move",
    .Proposal_Open="proposal_open",.Proposal_Revise="proposal_revise",.Proposal_Comment="proposal_comment",.Proposal_Verdict="proposal_verdict",
    .Proposal_Check="proposal_check",.Proposal_Land="proposal_land",.Proposal_Close="proposal_close",.Proposal_Reopen="proposal_reopen",
    .Keyring_Genesis="keyring_genesis",.Epoch_Add="epoch_add",.Envelope_Add="envelope_add",.Public_Add="public_add",
    .Passkey_Genesis="passkey_genesis",.Witness="witness",
}

// The entries a browser writes through drafts.
WRITABLE :: bit_set[kai.Entry_Type]{.Proposal_Comment,.Proposal_Verdict,.Proposal_Close,.Proposal_Reopen,.Member_Add,.Member_Remove,.Role_Set,.Device_Add,.Org_Genesis,.Node_Add,.Project_Genesis,.Project_Add,.Bookmark_Move,.Proposal_Land}

// The node modes a hosted org's Node_Add names: never derived data.
HOSTED_MODES :: kai.Node_Modes{.Relay,.Seed}

NO_RECOVERY_TEXT :: "your user has no recovery key yet, and an org needs its owner to have one: link a machine (Link a machine on your account page) and run the command it shows there; the machine sets your recovery key and shows it once"

Draft :: struct {
    type:kai.Entry_Type,
    log:kai.Log_Id,
    body:[]u8,
    org:^kai.Runner_Org,
    l:^kai.Log,
}

// The type, log and body a draft asks for, checked against the session's
// org: the answer is set when it does not hold.
draft_build :: proc(c:^Call,b:^Draft_Body) -> (d:Draft,ok:bool) {
    types:=TYPE_TEXT
    for name,t in types {
        if name!="" && name==b.type && t in WRITABLE {d.type=t}
    }
    if d.type==.None {
        fail(c,400,"type is one of proposal_comment, proposal_verdict, proposal_close, proposal_reopen, bookmark_move, proposal_land, member_add, member_remove, role_set, device_add, org_genesis, node_add, project_genesis, project_add")
        return
    }
    if d.type==.Org_Genesis || d.type==.Project_Genesis {return genesis_draft(c,b,d)}
    log,lok:=hash_parse(b.log)
    if !lok {
        fail(c,400,"log is the id of the proposal, project, org or user the entry joins, 64 hex")
        return
    }
    d.log=log
    if d.type==.Device_Add {
        if log!=c.session.user {
            fail(c,403,"a browser links devices to its own user alone")
            return
        }
        if u:=user_fold_of(c.h,log);u!=nil {d.l=u.log}
    }
    for o in runner_of(c.h).orgs {
        if d.l!=nil || session_role(c,o)==.None {continue}
        if l:=kai.agent_log_open(&o.agent,log);l!=nil && len(l.items)>0 {d.org,d.l=o,l}
    }
    kind,_:=kai.entry_log_kind(d.type)
    if d.l==nil || d.l.kind!=kind {
        fail(c,404,"no such log of that kind in an org the session's user is a member of")
        return
    }
    e:kai.Error
    #partial switch d.type {
    case .Proposal_Comment:
        anchor:kai.Anchor
        switch b.anchor.kind {
        case "","file": anchor.kind=.File
        case "lines": anchor={kind=.Lines,line=b.anchor.line,lines=b.anchor.lines}
        case:
            fail(c,400,"a comment's anchor kind is file or lines")
            return
        }
        change:kai.Change_Id
        if b.change!="" && !hex_parse(b.change,change[:]) {
            fail(c,400,"change is a change id, 32 hex")
            return
        }
        reply:store.Hash
        if b.reply_to!="" {
            ok_reply:bool
            if reply,ok_reply=hash_parse(b.reply_to);!ok_reply {
                fail(c,400,"reply_to is the address of a comment, 64 hex")
                return
            }
        }
        d.body,e=kai.proposal_comment_body(anchor,b.path,change,reply,b.text)
    case .Proposal_Verdict:
        verdict:kai.Verdict_Kind
        switch b.verdict {
        case "approve": verdict=.Approve
        case "changes": verdict=.Changes
        case "withdraw": verdict=.Withdraw
        case:
            fail(c,400,"verdict is approve, changes or withdraw")
            return
        }
        revision,rok:=hash_parse(b.revision)
        if !rok {
            fail(c,400,"revision is the revision the verdict binds to, 64 hex")
            return
        }
        d.body,e=kai.proposal_verdict_body(verdict,revision)
    case .Proposal_Close,.Proposal_Reopen:
        d.body=nil
    case .Device_Add:
        head:kai.Device_Add_Body
        proof,pok:=base64_parse(b.proof,64)
        kem,kok:=base64_parse(b.kem,kai.KEM_PUBLIC)
        if !hex_parse(b.device,head.device[:]) || !hex_parse(b.dh,head.dh[:]) || !pok || len(proof)!=64 || !kok || len(kem)!=kai.KEM_PUBLIC {
            fail(c,400,"device and dh are 64 hex, kem base64url of the device's ML-KEM-768 key, proof base64url of the device's signature: take them from the device's offer")
            return
        }
        copy(head.proof[:],proof)
        copy(head.kem[:],kem)
        d.body=kai.body_make(head,transmute([]u8)b.name)
    case .Member_Add,.Role_Set,.Member_Remove:
        user,uok:=hash_parse(b.user)
        if !uok {
            fail(c,400,"user is the member's user id, 64 hex")
            return
        }
        if d.type==.Member_Remove {
            d.body=kai.body_make(kai.Subject_Body{subject=user})
        } else {
            role:kai.Role
            switch b.role {
            case "reader": role=.Reader
            case "writer": role=.Writer
            case "admin": role=.Admin
            case:
                fail(c,400,"role is reader, writer or admin")
                return
            }
            d.body=kai.body_make(kai.Member_Body{user=user,role=role})
        }
    case .Node_Add:
        body,why:=node_add_body(c,b)
        if why!="" {
            fail(c,400,why)
            return
        }
        d.body=body
    case .Project_Add:
        project,pok:=hash_parse(b.project)
        if !pok {
            fail(c,400,"project is the id of the project's log, 64 hex: its genesis's address")
            return
        }
        d.body=kai.body_make(kai.Project_Add_Body{project=project,public=b8(b.public)})
    case .Bookmark_Move:
        body,status,why:=landing_move_body(c,b,&d)
        if status!=0 {
            fail(c,status,why)
            return
        }
        d.body=body
    case .Proposal_Land:
        body,status,why:=landing_land_body(c,b,&d)
        if status!=0 {
            fail(c,status,why)
            return
        }
        d.body=body
    }
    if e!=.None || !kai.body_valid(d.type,d.body) {
        fail(c,400,"the fields do not make a valid body: the body of each type is in kai/log.odin")
        return
    }
    return d,true
}

@(private)
route_draft :: proc(c:^Call) {
    s:=c.session
    if s.web_key=={} {
        fail(c,403,"this session has no passkey: ask a device to sign the write (POST /api/approvals with kind entry)")
        return
    }
    b:Draft_Body
    if !body_parse(c,&b) {return}
    d,ok:=draft_build(c,&b)
    if !ok {return}
    u:=user_fold_of(c.h,s.user)
    if u==nil {
        fail(c,401,"the session's user is no longer on this node: sign in again")
        return
    }
    p,found:=passkey_of(c.h,u,s.credential[:s.credential_len])
    if !found || p.key!=s.web_key {
        fail(c,401,"the session's passkey is no longer its user's: sign in again")
        return
    }
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    if d.l!=nil {kai.log_heads(d.l,&heads)}
    if len(heads)>kai.ENTRY_PARENTS_MAX {resize(&heads,kai.ENTRY_PARENTS_MAX)}
    kind,_:=kai.entry_log_kind(d.type)
    org_ctx:store.Hash
    if kai.org_bound(kind) {org_ctx=kai.org_context(&d.org.agent.org,s.user)}
    author_ctx:=kai.user_context(u,p.added)
    if d.type==.Org_Genesis && !kai.user_recovered_at(u,author_ctx) {
        fail(c,403,NO_RECOVERY_TEXT)
        return
    }
    draft:=kai.Draft{type=d.type,log_id=d.log,parents=heads[:],author_ctx=author_ctx,org_ctx=org_ctx,time=time.now()._nsec,body=d.body}
    unsigned,_,e:=kai.entry_webauthn_begin(&draft,s.web_key,context.temp_allocator)
    if e!=.None {
        fail(c,400,"the entry does not make: its body or parents are out of bounds")
        return
    }
    types:=TYPE_TEXT
    j:=json_make()
    json_object(&j)
    json_key(&j,"unsigned")
    json_base64(&j,unsigned)
    json_member_string(&j,"type",types[d.type])
    json_member_hash(&j,"log",d.log)
    json_key(&j,"parents")
    json_array(&j)
    for h in heads {json_hash(&j,h)}
    json_end_array(&j)
    key:=s.web_key
    json_member_hex(&j,"author",key[:])
    json_member_hash(&j,"author_ctx",author_ctx)
    json_member_hash(&j,"org_ctx",org_ctx)
    json_member_int(&j,"time",draft.time)
    json_key(&j,"body")
    json_base64(&j,d.body)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
route_entry_append :: proc(c:^Call) {
    s:=c.session
    Body :: struct {unsigned:string,assertion:Assertion_Body}
    b:Body
    if !body_parse(c,&b) {return}
    unsigned,uok:=base64_parse(b.unsigned,kai.ENTRY_BODY_MAX+4096)
    credential,a,ok:=assertion_parse(c,b.assertion)
    if !ok {return}
    if !uok {
        fail(c,400,"unsigned is base64url of the draft's bytes")
        return
    }
    p:Passkey
    found:=false
    if u:=user_fold_of(c.h,s.user);u!=nil {p,found=passkey_of(c.h,u,credential)}
    if !found {
        fail(c,401,"the passkey is not one of the session's user")
        return
    }
    bytes,address,e:=kai.entry_webauthn_finish(unsigned,p.cose,c.h.desc.rp_id,&a,context.temp_allocator)
    if e!=.None {
        if e==.Unauthorized {
            key,_:=kai.cose_key_parse(p.cose)
            challenge:=store.address_of_bytes(unsigned)
            fail(c,401,kai.webauthn_failure_text(kai.webauthn_verify(&key,c.h.desc.rp_id,challenge[:],&a,true)))
        } else {
            fail(c,400,"the unsigned bytes are not an entry by this passkey: take them from a draft, unchanged")
        }
        return
    }
    entry,_:=kai.entry_decode(bytes)
    if entry.author!=p.key || entry.type not_in WRITABLE {
        fail(c,400,"the entry is not by this passkey, or not one a browser writes")
        return
    }
    kept,log,status,why:=address,entry.log_id,0,""
    if entry.type==.Org_Genesis || entry.type==.Project_Genesis {
        status,why=genesis_keep(c,bytes,&entry,s.user)
        log=address
    } else {
        kept,status,why=entry_keep(c,bytes,s.user)
    }
    if status!=0 {
        fail(c,status,why)
        return
    }
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"address",kept)
    json_member_hash(&j,"log",log)
    json_end_object(&j)
    json_response(c,&j,201)
}

// Keeps a signed entry of user in its log when the log's fold takes it, and
// tells the peers: status 0, or the answer's status and why.
entry_keep :: proc(c:^Call,bytes:[]u8,user:kai.Log_Id) -> (address:store.Hash,status:int,why:string) {
    e,de:=kai.entry_decode(bytes)
    if de!=.None {return {},400,"the entry does not read"}
    kind,_:=kai.entry_log_kind(e.type)
    if kind==.User && user_synced(c.h,e.log_id)==nil {return waiting_entry_keep(c.h,bytes,e.log_id)}
    var_org:^kai.Runner_Org
    for o in runner_of(c.h).orgs {
        if !o.agent.folded {continue}
        if kind==.User {
            if kai.agent_log(&o.agent,e.log_id)!=nil {var_org=o}
        } else if kai.agent_log_open(&o.agent,e.log_id)!=nil && kai.org_role(&o.agent.org,user)!=.None {
            var_org=o
        }
    }
    if var_org==nil {return {},404,"the entry's log is not one of an org this user is a member of"}
    o:=var_org
    l:kai.Log
    kai.log_init(&l,e.log_id,context.temp_allocator)
    if kai.log_open(store_of(c.h),&l,e.log_id,kind)!=.None {return {},404,"the entry's log is not in this node's store"}
    added,ae:=kai.log_add(&l,bytes,true)
    if ae!=.None {return {},400,"the entry does not hold: its signature or its log is wrong"}
    if !added {return {},409,"the entry is in the log already: a signed entry counts once"}
    address=store.address_of_bytes(bytes)
    at:=kai.log_find(&l,address)
    valid:=false
    switch kind {
    case .User:
        f:kai.User_Fold
        valid=kai.user_fold(&f,&l,context.temp_allocator)==.None && f.valid[at]
    case .Org:
        f:kai.Org_Fold
        valid=kai.org_fold(&f,&l,o.agent.user_list[:],context.temp_allocator)==.None && f.valid[at]
    case .Proposal:
        f:kai.Proposal_Fold
        valid=kai.proposal_fold(&f,&l,&o.agent.org,context.temp_allocator)==.None && f.valid[at]
    case .Project:
        f:kai.Project_Fold
        snapshots:[dynamic]^kai.Proposal_Fold
        valid=project_fold_of(c.h,o,&l,&f,&snapshots) && f.valid[at]
        project_fold_end(&snapshots)
    case .Keyring:
    }
    if !valid {
        if e.type==.Bookmark_Move {return {},403,"the project's log does not take the move: the target's policy is not met at the proposal's heads, or its author is no writer"}
        if e.type==.Node_Add || e.type==.Project_Add {return {},403,"the org's log does not take the entry: an admin or the owner adds a node or a project, with a recovery key; the node and the project must not be in the org yet"}
        return {},403,"the log does not take the entry: its author lacks the right, or its parents are not in the log yet"
    }
    if why=log_keep(c.h,&l);why!="" {return {},500,why}
    return address,0,""
}

// How many orgs each user may make here; none on a node with no seed.
hosting_max :: proc(h:^Hub) -> int {
    if .Seed not_in runner_of(h).desc.modes {return 0}
    return max(h.desc.hosted_orgs,0)
}

// Whether the org's log names this node: it serves the org to its members.
node_added :: proc(r:^kai.Runner,o:^kai.Runner_Org) -> bool {
    if !o.agent.folded {return false}
    for n in o.agent.org.nodes {
        if n.key==r.machine.identity.key {return true}
    }
    return false
}

// Where members reach this node: the hub's addresses, else the runner's own.
node_addresses :: proc(h:^Hub) -> []kai.Node_Address {
    list:=make([dynamic]mnet.Address,context.temp_allocator)
    if len(h.desc.addresses)>0 {
        append(&list,..h.desc.addresses)
    } else {
        kai.runner_addresses(runner_of(h),&list)
    }
    out:=make([dynamic]kai.Node_Address,context.temp_allocator)
    for a in list {
        if n,ok:=kai.node_address_of(a);ok && len(out)<kai.NODE_ADDRESSES_MAX {append(&out,n)}
    }
    return out[:]
}

// The body of the Node_Add of this node a hosted org names, from what the
// browser read of GET /api/node: why it is not this node's, or "".
@(private)
node_add_body :: proc(c:^Call,b:^Draft_Body) -> (body:[]u8,why:string) {
    r:=runner_of(c.h)
    key:kai.Key
    dh:kai.Dh_Key
    if !hex_parse(b.node,key[:]) || !hex_parse(b.dh,dh[:]) {return nil,"node and dh are this node's keys, 64 hex each: take them from GET /api/node"}
    if key!=r.machine.identity.key || dh!=kai.Dh_Key(r.machine.dh.public) {return nil,"a browser adds this node alone: take node and dh from GET /api/node"}
    modes:kai.Node_Modes
    texts:=MODE_TEXT
    for m in b.modes {
        found:=false
        for text,mode in texts {
            if text==m {
                modes+={mode}
                found=true
            }
        }
        if !found {return nil,"modes are relay and seed"}
    }
    if modes!=HOSTED_MODES {return nil,"a node hosts an org as relay and seed: it keeps no derived data of it"}
    own:=node_addresses(c.h)
    if len(b.addresses)!=len(own) {return nil,"addresses are where members reach this node, as GET /api/node gives them"}
    list:=make([dynamic]kai.Node_Address,context.temp_allocator)
    for a,i in b.addresses {
        n:=kai.Node_Address{kind=a.kind,port=a.port}
        if !hex_parse(a.ip,n.ip[:]) || n!=own[i] {return nil,"addresses are where members reach this node, as GET /api/node gives them"}
        append(&list,n)
    }
    return kai.body_make(kai.Node_Add_Body{node=key,dh=dh,modes=modes,addresses=u8(len(list))},slice.to_bytes(list[:])),""
}

// The draft of an org's genesis, which this node will host, or of a project's.
@(private)
genesis_draft :: proc(c:^Call,b:^Draft_Body,d:Draft) -> (out:Draft,ok:bool) {
    d:=d
    if len(b.name)==0 || len(b.name)>kai.NAME_MAX {
        fail(c,400,"a name is 1 to 64 bytes of text")
        return
    }
    if d.type==.Org_Genesis {
        owner,ook:=hash_parse(b.owner)
        if !ook || owner!=c.session.user {
            fail(c,400,"owner is your user id, 64 hex: an org is made by its owner")
            return
        }
        if why:=hosting_refused(c.h,c.session.user);why!="" {
            fail(c,403,why)
            return
        }
        d.body=kai.body_make(kai.Org_Genesis_Body{owner=c.session.user},transmute([]u8)b.name)
        return d,true
    }
    org,gok:=hash_parse(b.org)
    if !gok {
        fail(c,400,"org is the id of the org the project is of, 64 hex")
        return
    }
    o:=org_find(c.h,org)
    if o==nil || session_role(c,o)<.Admin {
        fail(c,403,"an admin or the owner of an org this node serves makes its projects, with a recovery key")
        return
    }
    d.org=o
    d.body=kai.body_make(kai.Project_Genesis_Body{org=org,public=b8(b.public)},transmute([]u8)b.name)
    return d,true
}

// Why this node makes no new org of user: hosting is closed, or the user
// made its bound already; "" when it does.
@(private)
hosting_refused :: proc(h:^Hub,user:kai.Log_Id) -> string {
    most:=hosting_max(h)
    if most==0 {return "this node makes no orgs on its web view: make the org on your machine (mirai kai org new) and pair a node of yours, or ask this node's operator"}
    if kai.store_hosted_count(store_of(h),user)>=most {return "you made as many orgs on this node as it hosts for one user: run a node of your own (mirai kai serve) for more"}
    if len(runner_of(h).orgs)>=kai.RUNNER_ORGS {return "this node serves as many orgs as it may: run a node of your own (mirai kai serve)"}
    return ""
}

// Keeps the genesis of an org this node then hosts, or of a project of an
// org it serves: status 0, or the answer's status and why.
@(private)
genesis_keep :: proc(c:^Call,bytes:[]u8,e:^kai.Entry,user:kai.Log_Id) -> (status:int,why:string) {
    h:=c.h
    l:kai.Log
    kai.log_init(&l,{},context.temp_allocator)
    if _,ae:=kai.log_add(&l,bytes,true);ae!=.None {return 400,"the genesis does not hold: its signature is wrong"}
    name:[64]u8
    if _,found:=store.ref_get(store_of(h),kai.LOG_NAMESPACE,kai.log_name(l.id,&name));found==.None {return 409,"the log exists already: a signed entry counts once"}
    if e.type==.Project_Genesis {
        b,_,_:=kai.body_head(e.body,kai.Project_Genesis_Body)
        o:=org_find(h,b.org)
        if o==nil || kai.org_role(&o.agent.org,user)==.None {return 404,"the project's org is not one this node serves with you as a member"}
        f:kai.Project_Fold
        if kai.project_fold(&f,&l,&o.agent.org,allocator=context.temp_allocator)!=.None || !f.valid[0] {return 403,"the project's genesis does not hold: an admin or the owner of the org makes its projects, with a recovery key"}
        if why=log_keep(h,&l);why!="" {return 500,why}
        return 0,""
    }
    if why=hosting_refused(h,user);why!="" {return 403,why}
    u:=user_fold_of(h,user)
    if u==nil {return 401,"the session's user is no longer on this node: sign in again"}
    if !kai.user_recovered_at(u,e.author_ctx) {return 403,NO_RECOVERY_TEXT}
    f:kai.Org_Fold
    users:=[]^kai.User_Fold{u}
    if kai.org_fold(&f,&l,users,context.temp_allocator)!=.None || !f.valid[0] || f.owner!=user {return 403,"the org's genesis does not hold: it names the session's user as its owner, signed by its passkey"}
    if !waiting_admit(h,user) {return 500,"the store does not take the user: see the node's disk"}
    if why=log_keep(h,&l);why!="" {return 500,why}
    m:=runner_of(h).machine
    if kai.machine_org_host(m,l.id,user)!=.None || store.commit(&m.store)!=.None {return 500,m.why!=""?m.why:"the store does not take the org: see the node's disk"}
    return 0,""
}

// The hashes of a list of 64 hex, in its order; false when one is not.
@(private)
hashes_parse :: proc(list:[]string) -> (out:[]store.Hash,ok:bool) {
    hashes:=make([]store.Hash,len(list),context.temp_allocator)
    for text,i in list {hashes[i]=hash_parse(text) or_return}
    return hashes,true
}

// Whether a and b hold the same hashes, each once.
@(private)
same_set :: proc(a,b:[]store.Hash) -> bool {
    if len(a)!=len(b) {return false}
    for x,i in a {
        if !slice.contains(b,x) || slice.contains(a[:i],x) {return false}
    }
    return true
}

// The proposal of id in org, folded and settled: nil when the org holds no such log.
@(private)
proposal_open_fold :: proc(c:^Call,o:^kai.Runner_Org,id:kai.Log_Id) -> ^kai.Proposal_Fold {
    l:=kai.agent_log_open(&o.agent,id)
    if l==nil || l.kind!=.Proposal || len(l.items)==0 {return nil}
    f:=new(kai.Proposal_Fold,context.temp_allocator)
    if kai.proposal_fold(f,l,&o.agent.org,context.temp_allocator)!=.None {return nil}
    return f
}

// The project's fold with the proposals its moves land, as every peer folds
// it; false when it does not fold. Free it with project_fold_end.
@(private)
project_fold_of :: proc(h:^Hub,o:^kai.Runner_Org,l:^kai.Log,f:^kai.Project_Fold,snapshots:^[dynamic]^kai.Proposal_Fold) -> bool {
    snapshots^=make([dynamic]^kai.Proposal_Fold,context.temp_allocator)
    if kai.project_snapshots(store_of(h),l,&o.agent.org,snapshots,context.temp_allocator)!=.None {return false}
    return kai.project_fold(f,l,&o.agent.org,snapshots[:],context.temp_allocator)==.None
}

@(private)
project_fold_end :: proc(snapshots:^[dynamic]^kai.Proposal_Fold) {
    kai.project_snapshots_destroy(snapshots,context.temp_allocator)
}

// The body of the move that lands a proposal on the project d.log, from the
// fields the browser read: status 0, or the answer's status and why.
@(private)
landing_move_body :: proc(c:^Call,b:^Draft_Body,d:^Draft) -> (body:[]u8,status:int,why:string) {
    o:=d.org
    if session_role(c,o)<.Writer {return nil,403,"landing a proposal is a writer's: an admin of the org gives you that role"}
    id,iok:=hash_parse(b.proposal)
    if !iok {return nil,400,"proposal is the id of the proposal's log, 64 hex"}
    pf:=proposal_open_fold(c,o,id)
    if pf==nil {return nil,404,"no such proposal in the project's org"}
    if pf.project!=d.log {return nil,400,"the proposal is of another project than the log the move joins"}
    s:=store_of(c.h)
    refusal,e:=kai.proposal_can_land(s,pf)
    if e!=.None {return nil,409,"a change of the stack is not on this node yet: wait for a peer to give it, then land"}
    if refusal!=.None {return nil,409,kai.land_blocker(&o.agent.org,pf,refusal)}
    target:=kai.proposal_target(pf)
    to,tok:=hash_parse(b.revision)
    if b.bookmark!=target || !tok || to!=pf.revision {return nil,409,"the proposal was revised or retargeted since this page read it: reload it and land again"}
    pfold:kai.Project_Fold
    snapshots:[dynamic]^kai.Proposal_Fold
    defer project_fold_end(&snapshots)
    if !project_fold_of(c.h,o,d.l,&pfold,&snapshots) {return nil,500,"the project's log does not fold on this node"}
    from:=make([dynamic]kai.Revision,context.temp_allocator)
    kai.project_bookmark(&pfold,target,&from)
    if len(from)>kai.CONFLICT_SIDES_MAX {return nil,409,"the target diverged too far: land it from a machine"}
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    kai.log_heads(pf.log,&heads)
    if len(heads)>kai.ENTRY_PARENTS_MAX {return nil,409,"the proposal's log has too many heads: comment on it once to join them, then land"}
    asked_from,fok:=hashes_parse(b.from)
    asked_heads,hok:=hashes_parse(b.heads)
    if !fok || !hok {return nil,400,"from and heads are lists of 64 hex"}
    if !same_set(asked_from,from[:]) || !same_set(asked_heads,heads[:]) {return nil,409,"the target or the proposal moved since this page read it: reload it and land again"}
    old:kai.Revision
    if len(from)>0 {old=from[0]}
    m:=runner_of(c.h).machine
    if kai.machine_publish_check(m,&o.agent.org,d.log,pfold.public,old,pf.revision)!=.None {return nil,409,m.why}
    return kai.move_body(target,asked_from,pf.revision,id,asked_heads),0,""
}

// The body of the Land of the proposal d.log, naming a move of its project
// that lands it at its final revision: status 0, or the answer's status and why.
@(private)
landing_land_body :: proc(c:^Call,b:^Draft_Body,d:^Draft) -> (body:[]u8,status:int,why:string) {
    o:=d.org
    pf:=proposal_open_fold(c,o,d.log)
    if pf==nil {return nil,404,"no such proposal in an org the session's user is a member of"}
    to,tok:=hash_parse(b.revision)
    move,mok:=hash_parse(b.bookmark_move)
    if !tok || !mok {return nil,400,"revision is the proposal's final revision and bookmark_move the address of the move that lands it, 64 hex each"}
    if pf.status!=.Open || to!=pf.revision {return nil,409,"the proposal is not open at that revision: reload it"}
    pl:=kai.agent_log_open(&o.agent,pf.project)
    k:=pl==nil?-1:kai.log_find(pl,move)
    if k<0 || pl.items[k].entry.type!=.Bookmark_Move {return nil,404,"bookmark_move is no move of the proposal's project on this node: land the move first"}
    head,_,_,_:=kai.move_parts(pl.items[k].entry.body)
    if head.proposal!=d.log || head.to!=pf.revision {return nil,400,"the move lands another proposal or revision"}
    return kai.body_make(kai.Proposal_Land_Body{revision=to,bookmark_move=move}),0,""
}

// The move of the project's log that lands f at its final revision, kept
// there and valid, that no Land of f names yet: what a browser whose second
// prompt was dismissed finishes with. Zero when there is none.
landing_pending :: proc(h:^Hub,o:^kai.Runner_Org,f:^kai.Proposal_Fold) -> store.Hash {
    if f.status!=.Open || f.revision=={} {return {}}
    pl:=kai.agent_log_open(&o.agent,f.project)
    if pl==nil || len(pl.items)==0 {return {}}
    found:store.Hash
    for &item in pl.items {
        if item.entry.type!=.Bookmark_Move {continue}
        head,_,_,_:=kai.move_parts(item.entry.body)
        if head.proposal==f.log.id && head.to==f.revision {found=item.address}
    }
    if found=={} {return {}}
    pfold:kai.Project_Fold
    snapshots:[dynamic]^kai.Proposal_Fold
    defer project_fold_end(&snapshots)
    if !project_fold_of(h,o,pl,&pfold,&snapshots) {return {}}
    if k:=kai.log_find(pl,found);k<0 || !pfold.valid[k] {return {}}
    return found
}
