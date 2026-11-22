package hub

import "core:time"
import "mirai:kai"
import "mirai:store"

// Writes: entries of the org and proposal logs. The server drafts the bytes
// of an entry (the log's heads, the author's context and the time) and keeps
// what the browser's passkey, or a device, signed over them, once the log's
// fold takes it as every peer's would. A draft carries no challenge: the
// browser computes the BLAKE3 of the bytes it checked and signs that.

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
    device:string, // device_add: the device's Ed25519 key, its X25519 key, its proof and name
    dh:string,
    proof:string,
    name:string,
}

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
WRITABLE :: bit_set[kai.Entry_Type]{.Proposal_Comment,.Proposal_Verdict,.Proposal_Close,.Proposal_Reopen,.Member_Add,.Member_Remove,.Role_Set,.Device_Add}

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
        fail(c,400,"type is one of proposal_comment, proposal_verdict, proposal_close, proposal_reopen, member_add, member_remove, role_set, device_add")
        return
    }
    log,lok:=hash_parse(b.log)
    if !lok {
        fail(c,400,"log is the id of the proposal or org the entry joins, 64 hex")
        return
    }
    d.log=log
    if d.type==.Device_Add && log!=c.session.user {
        fail(c,403,"a browser links devices to its own user alone")
        return
    }
    for o in runner_of(c.h).orgs {
        if session_role(c,o)==.None {continue}
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
        if !hex_parse(b.device,head.device[:]) || !hex_parse(b.dh,head.dh[:]) || !pok || len(proof)!=64 {
            fail(c,400,"device and dh are 64 hex, proof base64url of the device's signature: take them from the device's offer")
            return
        }
        copy(head.proof[:],proof)
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
    }
    if e!=.None || !kai.body_valid(d.type,d.body) {
        fail(c,400,"the fields do not make a valid body: GET /api/entries says what each holds")
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
    kai.log_heads(d.l,&heads)
    if len(heads)>kai.ENTRY_PARENTS_MAX {resize(&heads,kai.ENTRY_PARENTS_MAX)}
    org_ctx:store.Hash
    if kai.org_bound(d.l.kind) {org_ctx=kai.org_context(&d.org.agent.org,s.user)}
    draft:=kai.Draft{type=d.type,log_id=d.log,parents=heads[:],author_ctx=p.added,org_ctx=org_ctx,time=time.now()._nsec,body=d.body}
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
    json_member_hash(&j,"author_ctx",p.added)
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
    kept,status,why:=entry_keep(c,bytes,s.user)
    if status!=0 {
        fail(c,status,why)
        return
    }
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"address",kept)
    json_member_hash(&j,"log",entry.log_id)
    json_end_object(&j)
    json_response(c,&j,201)
    _=address
}

// Keeps a signed entry of user in its log when the log's fold takes it, and
// tells the peers: status 0, or the answer's status and why.
entry_keep :: proc(c:^Call,bytes:[]u8,user:kai.Log_Id) -> (address:store.Hash,status:int,why:string) {
    e,de:=kai.entry_decode(bytes)
    if de!=.None {return {},400,"the entry does not read"}
    kind,_:=kai.entry_log_kind(e.type)
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
    case .Project,.Keyring:
    }
    if !valid {return {},403,"the log does not take the entry: its author lacks the right, or its parents are not in the log yet"}
    if why=log_keep(c.h,&l);why!="" {return {},500,why}
    return address,0,""
}
