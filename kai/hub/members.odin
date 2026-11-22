package hub

import "mirai:kai"
import "mirai:store"

// The routes for members: what a session of a member of the org reads.

// The project of the path for a member of its org: the answer is set when
// the session's user is not one.
member_project :: proc(c:^Call) -> (v:Project_View,ok:bool) {
    v,ok=project_open(c,path_param(c,"project"))
    if !ok {return}
    if session_role(c,v.org)==.None {
        fail(c,403,"this view is for members of the project's org")
        return {},false
    }
    return
}

member_org :: proc(c:^Call) -> (o:^kai.Runner_Org,ok:bool) {
    id,parsed:=hash_parse(path_param(c,"org"))
    if !parsed {
        fail(c,400,"an org is named by its id, 64 hex")
        return
    }
    o=org_find(c.h,id)
    if o==nil || session_role(c,o)==.None {
        fail(c,404,"no such org on this node, or the session's user is not a member of it")
        return nil,false
    }
    return o,true
}

// Whether revision is an ancestor of, or one of, a landed bookmark.
@(private)
landed :: proc(v:^Project_View,revision:kai.Revision) -> bool {
    for b in v.bookmarks {
        if b.landed && kai.graph_is_ancestor(v.graph,revision,b.revision) {return true}
    }
    return false
}

@(private)
route_stacks :: proc(c:^Call) {
    v,ok:=member_project(c)
    if !ok {return}
    s:=store_of(c.h)
    j:=json_make()
    json_object(&j)
    json_key(&j,"stacks")
    json_array(&j)
    ns:[len(kai.REFS_PREFIX)+64]u8
    refs,_:=store.ref_list(s,kai.refs_namespace(v.id,&ns),context.temp_allocator)
    for ref in refs {
        bytes,ge:=kai.object_get(s,ref.hash,.Device_Refs,context.temp_allocator)
        if ge!=.None {continue}
        d,de:=kai.device_refs_decode(bytes,context.temp_allocator)
        if de!=.None || d.project!=v.id {continue}
        u,device_name:=key_owner(v.org,d.device)
        handle:=u!=nil?user_name(u):"unknown"
        for b in d.refs {
            json_object(&j)
            json_member_string(&j,"label",concat(context.temp_allocator,handle,"/",device_name,":",b.name))
            if u!=nil {json_member_hash(&j,"user",u.log.id)}
            json_member_string(&j,"handle",handle)
            device:=d.device
            json_member_hex(&j,"device",device[:])
            json_member_string(&j,"device_name",device_name)
            json_member_string(&j,"bookmark",b.name)
            json_member_hash(&j,"revision",b.target)
            json_member_int(&j,"time",d.time)
            json_key(&j,"changes")
            json_array(&j)
            at:=b.target
            for _ in 0..<STACK_CHANGES_MAX {
                if at not_in v.graph.lookup || landed(&v,at) {break}
                ch,e:=kai.change_get(s,at,context.temp_allocator)
                if e!=.None {break}
                json_object(&j)
                json_member_hash(&j,"revision",at)
                id:=ch.id
                json_member_hex(&j,"change",id[:])
                json_member_string(&j,"summary",summary_line(ch.description))
                json_end_object(&j)
                if len(ch.parents)==0 {break}
                at=ch.parents[0]
            }
            json_end_array(&j)
            json_end_object(&j)
        }
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
STATUS_TEXT :: [kai.Proposal_Status]string{.Open="open",.Closed="closed",.Landed="landed"}

@(private)
proposal_texts :: proc(f:^kai.Proposal_Fold) -> (title,text:string) {
    k:=kai.log_find(f.log,f.log.id)
    if k<0 {return}
    b,tail,ok:=kai.body_head(f.log.items[k].entry.body,kai.Proposal_Open_Body)
    if !ok || len(tail)<int(b.target)+int(b.title) {return}
    return string(tail[b.target:][:b.title]),string(tail[int(b.target)+int(b.title):])
}

@(private)
route_proposals :: proc(c:^Call) {
    v,ok:=member_project(c)
    if !ok {return}
    folds:=make([dynamic]^kai.Proposal_Fold,context.temp_allocator)
    project_proposals(c.h,v.org,v.id,&folds)
    status:=STATUS_TEXT
    j:=json_make()
    json_object(&j)
    json_key(&j,"proposals")
    json_array(&j)
    for f in folds {
        title,_:=proposal_texts(f)
        json_object(&j)
        json_member_hash(&j,"id",f.log.id)
        json_member_string(&j,"title",title)
        json_member_string(&j,"target",kai.proposal_target(f))
        json_member_string(&j,"status",status[f.status])
        json_member_hash(&j,"opener",f.opener)
        for u in v.org.agent.user_list {
            if u.log.id==f.opener {json_member_string(&j,"opener_name",user_name(u))}
        }
        json_member_hash(&j,"revision",f.revision)
        json_member_int(&j,"approvals",i64(f.approvals))
        json_member_int(&j,"comments",i64(f.comments))
        json_end_object(&j)
    }
    json_end_array(&j)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
VERDICT_TEXT :: [kai.Verdict_Kind]string{.Approve="approve",.Changes="changes",.Withdraw="withdraw"}
@(private)
CHECK_TEXT :: [kai.Check_State]string{.Pending="pending",.Passed="passed",.Failed="failed"}
@(private)
ANCHOR_TEXT :: [kai.Anchor_Kind]string{.File="file",.Lines="lines",.Structural="structural"}

@(private)
route_proposal :: proc(c:^Call) {
    id,parsed:=hash_parse(path_param(c,"proposal"))
    if !parsed {
        fail(c,400,"a proposal is named by the id of its log, 64 hex")
        return
    }
    o:^kai.Runner_Org
    l:^kai.Log
    for x in runner_of(c.h).orgs {
        if !x.agent.folded || session_role(c,x)==.None {continue}
        if found:=kai.agent_log(&x.agent,id);found!=nil && found.kind==.Proposal && len(found.items)>0 {o,l=x,found}
    }
    if l==nil {
        fail(c,404,"no such proposal in an org the session's user is a member of")
        return
    }
    s:=store_of(c.h)
    f:kai.Proposal_Fold
    if kai.proposal_fold(&f,l,&o.agent.org,context.temp_allocator)!=.None {
        fail(c,404,"the proposal's log does not fold yet: its opening entry has not arrived")
        return
    }
    refusal,_:=kai.proposal_can_land(s,&f)
    title,text:=proposal_texts(&f)
    stacks:=make([dynamic]kai.Proposal_Stack,context.temp_allocator)
    kai.proposal_stacks(&f,&stacks)
    places:=make([dynamic]kai.Comment_Place,context.temp_allocator)
    kai.proposal_reanchor(s,&f,{},&places)
    status:=STATUS_TEXT
    verdicts:=VERDICT_TEXT
    checks:=CHECK_TEXT
    anchors:=ANCHOR_TEXT
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"id",id)
    json_member_hash(&j,"project",f.project)
    json_member_string(&j,"title",title)
    json_member_string(&j,"text",text)
    json_member_string(&j,"target",kai.proposal_target(&f))
    json_member_string(&j,"status",status[f.status])
    json_member_hash(&j,"opener",f.opener)
    for u in o.agent.user_list {
        if u.log.id==f.opener {json_member_string(&j,"opener_name",user_name(u))}
    }
    json_member_hash(&j,"revision",f.revision)
    json_key(&j,"stack")
    json_array(&j)
    if len(stacks)>0 {
        for item in stacks[len(stacks)-1].items {
            json_object(&j)
            change:=item.change
            json_member_hex(&j,"change",change[:])
            json_member_hash(&j,"revision",item.revision)
            if ch,e:=kai.change_get(s,item.revision,context.temp_allocator);e==.None {json_member_string(&j,"summary",summary_line(ch.description))}
            json_end_object(&j)
        }
    }
    json_end_array(&j)
    json_key(&j,"comments")
    json_array(&j)
    for p in places {
        item:=&l.items[p.entry]
        b,tail,ok:=kai.body_head(item.entry.body,kai.Proposal_Comment_Body)
        if !ok || len(tail)<int(b.anchor.path) {continue}
        json_object(&j)
        json_member_hash(&j,"id",item.address)
        author:=item.entry.author
        json_member_hex(&j,"author",author[:])
        if u,_:=key_owner(o,item.entry.author);u!=nil {json_member_string(&j,"author_name",user_name(u))}
        json_member_int(&j,"time",item.entry.time)
        json_member_string(&j,"text",string(tail[b.anchor.path:]))
        json_key(&j,"reply_to")
        if b.reply_to=={} {json_null(&j)} else {json_hash(&j,b.reply_to)}
        json_key(&j,"change")
        if p.change=={} {json_null(&j)} else {
            change:=p.change
            json_hex(&j,change[:])
        }
        json_member_string(&j,"path",p.path)
        json_key(&j,"anchor")
        json_object(&j)
        json_member_string(&j,"kind",anchors[p.anchor.kind])
        json_member_int(&j,"line",i64(p.anchor.line))
        json_member_int(&j,"lines",i64(p.anchor.lines))
        json_end_object(&j)
        json_member_bool(&j,"outdated",p.outdated)
        json_end_object(&j)
    }
    json_end_array(&j)
    json_key(&j,"verdicts")
    json_array(&j)
    for vd in f.verdicts {
        json_object(&j)
        json_member_hash(&j,"user",vd.user)
        for u in o.agent.user_list {
            if u.log.id==vd.user {json_member_string(&j,"name",user_name(u))}
        }
        json_member_string(&j,"verdict",verdicts[vd.verdict])
        json_member_hash(&j,"revision",vd.revision)
        json_member_bool(&j,"current",vd.revision==f.revision)
        json_end_object(&j)
    }
    json_end_array(&j)
    json_key(&j,"checks")
    json_array(&j)
    for ck in f.checks {
        json_object(&j)
        json_member_string(&j,"name",ck.name)
        json_member_string(&j,"state",checks[ck.state])
        json_end_object(&j)
    }
    json_end_array(&j)
    json_member_int(&j,"approvals",i64(f.approvals))
    json_key(&j,"blocked")
    if refusal==.None {json_null(&j)} else {
        json_object(&j)
        refusals:=REFUSAL_TEXT
        json_member_string(&j,"reason",refusals[refusal])
        json_member_string(&j,"text",kai.land_refusal_text(refusal))
        json_end_object(&j)
    }
    heads_write(&j,l)
    json_end_object(&j)
    json_response(c,&j)
}

REFUSAL_TEXT :: [kai.Land_Refusal]string{.None="none",.Not_Open="not_open",.Unrevised="unrevised",.Unverified="unverified",.Conflicts="conflicts",.Approvals="approvals",.Checks="checks"}

@(private)
heads_write :: proc(j:^Json,l:^kai.Log) {
    heads:=make([dynamic]store.Hash,context.temp_allocator)
    kai.log_heads(l,&heads)
    json_key(j,"heads")
    json_array(j)
    for h in heads {json_hash(j,h)}
    json_end_array(j)
}

@(private)
ROLE_TEXT :: [kai.Role]string{.None="none",.Reader="reader",.Writer="writer",.Admin="admin",.Owner="owner"}

@(private)
org_name :: proc(o:^kai.Runner_Org) -> string {
    l:=o.agent.org.log
    if l==nil {return ""}
    k:=kai.log_find(l,l.id)
    if k<0 {return ""}
    _,tail,ok:=kai.body_head(l.items[k].entry.body,kai.Org_Genesis_Body)
    return ok?string(tail):""
}

@(private)
route_members :: proc(c:^Call) {
    o,ok:=member_org(c)
    if !ok {return}
    roles:=ROLE_TEXT
    f:=&o.agent.org
    j:=json_make()
    json_object(&j)
    json_member_hash(&j,"org",o.id)
    json_member_string(&j,"name",org_name(o))
    json_member_hash(&j,"owner",f.owner)
    json_key(&j,"members")
    json_array(&j)
    for m in f.members {
        json_object(&j)
        json_member_hash(&j,"user",m.user)
        json_member_string(&j,"role",roles[m.role])
        for u in o.agent.user_list {
            if u.log.id!=m.user {continue}
            json_member_string(&j,"name",user_name(u))
            json_key(&j,"devices")
            json_array(&j)
            for d in u.devices {
                json_object(&j)
                key:=d.key
                json_member_hex(&j,"key",key[:])
                _,name:=key_owner(o,d.key)
                json_member_string(&j,"name",name)
                json_member_bool(&j,"revoked",d.revoked)
                json_end_object(&j)
            }
            json_end_array(&j)
            json_key(&j,"passkeys")
            json_array(&j)
            for w in u.web_keys {
                json_object(&j)
                key:=w.key
                json_member_hex(&j,"key",key[:])
                json_member_bool(&j,"revoked",w.revoked)
                json_end_object(&j)
            }
            json_end_array(&j)
        }
        json_end_object(&j)
    }
    json_end_array(&j)
    json_key(&j,"nodes")
    json_array(&j)
    for n in f.nodes {
        json_object(&j)
        key:=n.key
        json_member_hex(&j,"key",key[:])
        json_key(&j,"modes")
        json_array(&j)
        modes:=MODE_TEXT
        for m in kai.Node_Mode {
            if m in n.modes {json_string(&j,modes[m])}
        }
        json_end_array(&j)
        json_end_object(&j)
    }
    json_end_array(&j)
    heads_write(&j,f.log)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
route_ddc :: proc(c:^Call) {
    o,ok:=member_org(c)
    if !ok {return}
    r:=runner_of(c.h)
    st:=kai.runner_ddc_stats(r,o.id)
    j:=json_make()
    json_object(&j)
    json_member_int(&j,"keys",i64(st.keys))
    json_member_int(&j,"records",i64(st.records))
    json_member_int(&j,"whole",i64(st.whole))
    json_member_int(&j,"missing",i64(st.missing))
    json_member_int(&j,"nondeterministic",i64(st.nondeterministic))
    json_member_int(&j,"lookups_found",i64(st.lookups_found))
    json_member_int(&j,"lookups_missing",i64(st.lookups_missing))
    json_member_int(&j,"quota",r.desc.ddc_quota)
    json_member_int(&j,"bytes",st.bytes)
    json_end_object(&j)
    json_response(c,&j)
}

@(private)
CLASS_TEXT :: [kai.Agent_Class]string{.None="none",.Pending="pending",.Member="member",.Node="node",.Anonymous="anonymous",.Grant="grant"}

@(private)
route_stats :: proc(c:^Call) {
    h:=c.h
    r:=runner_of(h)
    member:=false
    for o in r.orgs {member||=session_role(c,o)!=.None}
    if !member {
        fail(c,403,"the node's stats are for members of an org it serves")
        return
    }
    classes:=CLASS_TEXT
    peers:=make([dynamic]kai.Runner_Peer_Info,context.temp_allocator)
    kai.runner_peers(r,&peers)
    j:=json_make()
    json_object(&j)
    json_key(&j,"peers")
    json_array(&j)
    for p in peers {
        o:=org_find(h,p.org)
        if o==nil || session_role(c,o)==.None {continue}
        json_object(&j)
        json_member_hash(&j,"org",p.org)
        dh:=p.dh
        json_member_hex(&j,"dh",dh[:])
        json_member_string(&j,"class",classes[p.class])
        json_member_string(&j,"rung",kai.rung_text(p.rung))
        json_member_bool(&j,"node",p.node)
        json_end_object(&j)
    }
    json_end_array(&j)
    json_key(&j,"relay")
    json_object(&j)
    forwarded,dropped:u64
    for d in r.relay.devices {
        forwarded+=d.forwarded
        dropped+=d.dropped
    }
    json_member_int(&j,"devices",i64(len(r.relay.devices)))
    json_member_int(&j,"forwarded",i64(forwarded))
    json_member_int(&j,"dropped",i64(dropped))
    json_end_object(&j)
    json_key(&j,"store")
    json_object(&j)
    if u,e:=store.usage(&r.machine.store);e==.None {
        json_member_int(&j,"bytes",u.bytes)
        json_member_int(&j,"packs",i64(u.packs))
    }
    json_end_object(&j)
    json_key(&j,"hub")
    json_object(&j)
    sessions:=0
    for x in h.sessions {
        if x.used {sessions+=1}
    }
    json_member_int(&j,"requests",i64(h.stats.requests))
    json_member_int(&j,"refused",i64(h.stats.refused))
    json_member_int(&j,"connections",i64(h.stats.connections))
    json_member_int(&j,"sessions",i64(sessions))
    json_end_object(&j)
    json_end_object(&j)
    json_response(c,&j)
}

