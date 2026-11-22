package editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import ka "mirai:cook/kai"
import "mirai:editor/api"
import vcs "mirai:kai"

// The kai.* methods of the team: the user of this device, the orgs, pairing
// another machine, the peers of the mesh, the proposals of the project and
// its private files, through the procedures of cook/kai and kai that `mirai
// kai` runs. Each one writes what it is asked and gives its result whole, as
// the Kai tab shows it; a failure says what failed and how to fix it.

Api_Kai_Device :: struct {
    name:string,
    key:string `mirai:"label=The first hex digits of its key"`,
    revoked:bool,
    this:bool `mirai:"label=This device"`,
}

Api_Kai_Identity_Params :: struct {
    name:string `mirai:"optional,label=Makes the user of this device with this handle, when it has none; its recovery key shows to the person in the editor's window, never in a result"`,
    device:string `mirai:"optional,label=With name: this device's name; none: the machine's host name"`,
    revoke:string `mirai:"optional,label=A device of the user to revoke, by its name or a prefix of its key"`,
    recovery:string `mirai:"optional,label=The recovery key the user has now, as it was shown: rotates it, and the new one shows to the person in the editor's window; with recover, the key that recovers"`,
    recover:string `mirai:"optional,label=With recovery: the id of a user whose devices were lost, recovered onto this device, which has none; its log must be here (a recovery pairing brings it), and its other devices are revoked"`,
    first_recovery:bool `mirai:"optional,label=Sets the first recovery key of a user born of a passkey; it shows to the person in the editor's window"`,
}
Api_Kai_Identity :: struct {
    user:string `mirai:"label=The id of the user; empty: this device has none yet"`,
    handle:string,
    device:string `mirai:"label=This device's name"`,
    subject:string `mirai:"label=What a grant is issued to: the device key and X25519 key"`,
    devices:[]Api_Kai_Device,
    orgs:[]string `mirai:"label=The orgs this machine serves"`,
}

Api_Kai_Org_Params :: struct {
    org:string `mirai:"optional,label=The org, by its name or a prefix of its id; none: the only one this machine serves"`,
    new:string `mirai:"optional,label=Makes an org of this name, which this device's user owns"`,
    add:string `mirai:"optional,label=public or org: puts the open project in the org, read by anyone or by the org alone"`,
    link:string `mirai:"optional,label=A project of the org, by its name or a prefix of its id: the open project's workspace works on it"`,
    member:string `mirai:"optional,label=A member, by its handle or a prefix of its id, given role"`,
    role:string `mirai:"optional,label=With member: reader, writer or admin"`,
    remove:string `mirai:"optional,label=A member to remove"`,
    transfer:string `mirai:"optional,label=A member to give the org to"`,
    leave:bool `mirai:"optional,label=This machine leaves the org and serves it no more"`,
}
Api_Kai_Member :: struct {
    handle:string `mirai:"label=Empty while its log is not here"`,
    user:string,
    role:string,
    devices:[]Api_Kai_Device,
}
Api_Kai_Policy :: struct {bookmark,text:string}
Api_Kai_Project :: struct {
    id:string,
    name:string,
    public:bool,
    open:bool `mirai:"label=The project open in the editor"`,
    policies:[]Api_Kai_Policy,
}
Api_Kai_Node :: struct {key,modes:string}
Api_Kai_Org :: struct {
    id:string,
    name:string,
    owner:string,
    role:string `mirai:"label=Of this device's user"`,
    members:[]Api_Kai_Member,
    nodes:[]Api_Kai_Node,
    projects:[]Api_Kai_Project,
}
Api_Kai_Orgs :: struct {orgs:[]Api_Kai_Org}

Api_Kai_Pair_Params :: struct {
    offer:string `mirai:"optional,label=member, device, node or recover: a ticket another machine joins with; recover lets a machine with no user reach the org to fetch the user it recovers"`,
    org:string `mirai:"optional,label=With offer member or node: the org; none: the only one"`,
    role:string `mirai:"optional,label=With offer member: reader, writer or admin; writer when none"`,
    modes:string `mirai:"optional,label=With offer node: relay, seed and ddc apart by commas; relay,seed when none"`,
    join:string `mirai:"optional,label=A ticket another machine offered"`,
    name:string `mirai:"optional,label=With join, on a device with no user: the name its user will know it by; none: the machine's host name"`,
    answer:string `mirai:"optional,label=approve or deny: the pairing request that waits"`,
    code:string `mirai:"optional,label=With approve: the code the other machine shows, dddd-dddd"`,
}
Api_Kai_Pair :: struct {
    ticket:string `mirai:"optional,label=The ticket offered now: valid ten minutes"`,
    asking:bool `mirai:"label=A pairing request waits for an answer here"`,
    mode:string `mirai:"optional,label=Of the request: member, device, node or recover"`,
    who:string `mirai:"optional,label=Of the request: <handle>/<device>"`,
    code:string `mirai:"optional,label=Of the request: compare it with the one the other machine shows"`,
    joining:string `mirai:"label=How the pairing this machine joins goes: none, asking, waiting, approved, denied or failed"`,
    joined_code:string `mirai:"optional,label=Of the pairing joined, once both ends have it"`,
    why:string `mirai:"optional,label=Of a pairing joined that failed"`,
}

Api_Kai_Peer :: struct {who,org,rung:string}
Api_Kai_Behind :: struct {org:string,behind,unfound:int}
Api_Kai_Peers :: struct {
    mesh:string `mirai:"label=Who runs the machine's mesh"`,
    peers:[]Api_Kai_Peer `mirai:"label=Connected now, and by which rung of the ladder"`,
    behind:[]Api_Kai_Behind `mirai:"label=Orgs whose logs peers named entries of that are not here yet (behind: writes wait until a peer gives them), or that never came (unfound: let go)"`,
}

Api_Kai_Proposals_Params :: struct {
    open:string `mirai:"optional,label=A shared bookmark of the project: opens a proposal to land on it"`,
    changes:[]string `mirai:"optional,label=With open: its stack, bottom first; none: the changes from the target to the working copy's parent"`,
    title:string `mirai:"optional,label=With open; none: the description of the working copy's parent"`,
    text:string `mirai:"optional,label=With open"`,
}
Api_Kai_Proposal_Row :: struct {
    id:string,
    title:string,
    target:string,
    opener:string,
    status:string,
    approvals:int,
    comments:int,
}
Api_Kai_Proposals :: struct {
    proposals:[]Api_Kai_Proposal_Row,
    opened:string `mirai:"optional,label=The id of the proposal opened"`,
}

Api_Kai_Proposal_Params :: struct {
    proposal:string `mirai:"label=A proposal by a prefix of its id, as kai.proposals lists it"`,
    comment:string `mirai:"optional,label=Comments with this text"`,
    file:string `mirai:"optional,label=A file of the stack, from the folder of the project: a comment hangs on it, or alone, detail says what its change did to it"`,
    change:string `mirai:"optional,label=With file: the change of the stack whose detail; none: the topmost that changed it"`,
    lines:string `mirai:"optional,label=With comment and file: lines of a text file, A-B from 1"`,
    entity:u64 `mirai:"optional,label=With comment and file: the id of an entity of the scene"`,
    reply:string `mirai:"optional,label=With comment: the comment it answers, by a prefix of its id"`,
    verdict:string `mirai:"optional,label=approve, changes or withdraw"`,
    revise:bool `mirai:"optional,label=Revises it to changes, or to those from its target to the working copy's parent"`,
    changes:[]string `mirai:"optional,label=With revise: the stack, bottom first"`,
    check:string `mirai:"optional,label=Runs a check of this name with command in the folder of the project, whose working copy must hold the proposal's final revision"`,
    command:[]string `mirai:"optional,label=With check: the program and its arguments"`,
    close:bool `mirai:"optional"`,
    reopen:bool `mirai:"optional"`,
    land:bool `mirai:"optional,label=Moves its target to its final revision for the whole org"`,
}
Api_Kai_Proposal_Change :: struct {
    change:string,
    description:string,
    files:[]Api_Kai_File,
}
Api_Kai_Comment :: struct {
    id:string `mirai:"label=What a reply names"`,
    reply_to:string `mirai:"optional"`,
    author:string `mirai:"label=<handle>/<device>"`,
    text:string,
    file:string `mirai:"optional,label=Empty: on the whole proposal"`,
    change:string `mirai:"optional,label=The change of the stack it hangs on"`,
    lines:string `mirai:"optional,label=A-B on that change's revision"`,
    entity:u64 `mirai:"optional"`,
    outdated:bool `mirai:"label=What it named is gone, or its change left the stack"`,
}
Api_Kai_Verdict :: struct {
    user:string,
    verdict:string,
    current:bool `mirai:"label=Given on the final revision"`,
}
Api_Kai_Check :: struct {name,state:string}
Api_Kai_Proposal :: struct {
    id:string,
    title:string,
    text:string,
    target:string,
    opener:string,
    status:string,
    approvals:int,
    stack:[]Api_Kai_Proposal_Change `mirai:"label=Bottom first, with what each change did to each file"`,
    comments:[]Api_Kai_Comment,
    verdicts:[]Api_Kai_Verdict,
    checks:[]Api_Kai_Check,
    blocking:string `mirai:"label=What keeps it from landing; empty: it may land"`,
    passed:bool `mirai:"optional,label=Of the check run now"`,
    detail:Api_Kai_Detail `mirai:"optional,label=Of file: what its change did to it"`,
}

Api_Kai_Scopes_Params :: struct {
    add:[]string `mirai:"optional,label=Patterns of private paths, as secrets/** or .env: a scope of them, sealed from the next snapshot on"`,
    readers:string `mirai:"optional,label=With add: reader, writer, admin or owner; writer when none"`,
    history:bool `mirai:"optional,label=With add: earlier epochs stay readable"`,
    remove:string `mirai:"optional,label=A scope by a prefix of its id"`,
    rotate:string `mirai:"optional,label=A scope by a prefix of its id: a new key wrapped for its readers now"`,
    public:string `mirai:"optional,label=path, or path:line of a leak the publish scanner found: an admin keeps it public"`,
}
Api_Kai_Scope :: struct {
    id:string,
    patterns:[]string,
    readers:string,
    history:bool,
}
Api_Kai_Scopes :: struct {
    scopes:[]Api_Kai_Scope,
    public:[]string `mirai:"label=Paths of the deny set kept public"`,
    refused:string `mirai:"optional,label=What refused the last snapshot or publish, and how to fix it"`,
    refused_path:string `mirai:"optional"`,
    refused_line:int `mirai:"optional,label=Of a leak the publish scanner found"`,
    action:string `mirai:"optional,label=What resolves it here: public (kai.scopes public) or rotate (kai.scopes rotate scope)"`,
    scope:string `mirai:"optional,label=Of a refusal that a rotation resolves"`,
}

@(private)
kai_team_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="kai.identity",summary="The user of this device and its devices; makes the user, revokes a device or rotates the recovery key first when asked.",params=type_info_of(Api_Kai_Identity_Params),result=type_info_of(Api_Kai_Identity),run=api_kai_identity})
    api_register(s,st,{name="kai.org",summary="The orgs this machine serves with their members, roles, devices, nodes and projects; makes one, puts the open project in one, sets a role, removes a member, gives the org away or leaves first when asked.",params=type_info_of(Api_Kai_Org_Params),result=type_info_of(Api_Kai_Orgs),run=api_kai_org})
    api_register(s,st,{name="kai.pair",summary="Pairing another machine as a member, a second device or a node: offers a ticket, joins with one, or answers the request that waits with the code both machines show.",params=type_info_of(Api_Kai_Pair_Params),result=type_info_of(Api_Kai_Pair),run=api_kai_pair})
    api_register(s,st,{name="kai.peers",summary="Who runs the machine's mesh, and the peers connected now with the rung each is reached by.",result=type_info_of(Api_Kai_Peers),flags={.Read_Only},run=api_kai_peers})
    api_register(s,st,{name="kai.proposals",summary="The proposals of the open project; opens one on a shared bookmark first when asked, by default with the changes from it to the working copy's parent.",params=type_info_of(Api_Kai_Proposals_Params),result=type_info_of(Api_Kai_Proposals),run=api_kai_proposals})
    api_register(s,st,{name="kai.proposal",summary="One proposal whole: its stack with what each change did, comments placed on the current stack, verdicts, checks and what keeps it from landing; comments, gives a verdict, revises, runs a check, closes, reopens or lands it first when asked.",params=type_info_of(Api_Kai_Proposal_Params),result=type_info_of(Api_Kai_Proposal),run=api_kai_proposal})
    api_register(s,st,{name="kai.scopes",summary="The private files of the open project: its scopes and the paths kept public, and what refused the last snapshot or publish; adds, removes or rotates a scope, or keeps a path public, first when asked.",params=type_info_of(Api_Kai_Scopes_Params),result=type_info_of(Api_Kai_Scopes),run=api_kai_scopes})
}

// The machine, or the call fails with why there is none.
@(private)
api_kai_machine :: proc(s:^Session,call:^api.Call) -> ^vcs.Machine {
    m,message:=kai_team_machine(s)
    if m==nil {api.call_fail(call,api.SERVER_ERROR,message)}
    return m
}

// Fails the call with what the machine says failed.
@(private)
api_kai_why :: proc(call:^api.Call,m:^vcs.Machine,e:vcs.Error) {
    why:=m.why!=""?m.why:vcs.error_text(e)
    api.call_fail(call,e==.Invalid_Argument?api.INVALID_PARAMS:api.SERVER_ERROR,why)
}

@(private)
api_kai_hex :: proc(bytes:[]u8,call:^api.Call) -> string {return ka.hex(bytes[:min(len(bytes),6)],call.allocator)}

// The one action of the params that are set, by name: "" for none, and the
// call failed when several are.
@(private)
api_kai_action :: proc(call:^api.Call,names:[]string,set:[]bool) -> (action:string,ok:bool) {
    for given,i in set {
        if !given {continue}
        if action!="" {
            api.call_failf(call,api.INVALID_PARAMS,"%s and %s are given together: give one of %s per call",action,names[i],strings.join(names,", ",context.temp_allocator))
            return
        }
        action=names[i]
    }
    return action,true
}

@(private)
api_kai_devices :: proc(devices:[]ka.Device_View,call:^api.Call) -> []Api_Kai_Device {
    out:=make([]Api_Kai_Device,len(devices),call.allocator)
    for d,i in devices {
        key:=d.key
        out[i]={strings.clone(d.name,call.allocator),api_kai_hex(key[:],call),d.revoked,d.this}
    }
    return out
}

@(private)
api_kai_identity :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Identity_Params)
    action,ok:=api_kai_action(call,{"name","revoke","recovery","recover","first_recovery"},{p.name!="",p.revoke!="",p.recovery!="" && p.recover=="",p.recover!="",p.first_recovery})
    if !ok {return}
    if action=="recover" && p.recovery=="" {
        api.call_fail(call,api.INVALID_PARAMS,"recover takes recovery: the user's recovery key, as it was shown")
        return
    }
    if p.device!="" && action!="name" {
        api.call_fail(call,api.INVALID_PARAMS,"device goes with name: it names this device when its user is made")
        return
    }
    // A recovery key is a secret for a person: it shows in the editor's window, never in a result.
    if (action=="name" || action=="recovery" || action=="first_recovery") && (s.headless || s.gui==nil) {
        api.call_fail(call,api.SERVER_ERROR,"a recovery key is shown to a person, and this editor has no window: make the user or rotate its key in an editor with a window, or with mirai kai identity in a terminal")
        return
    }
    m:=api_kai_machine(s,call)
    if m==nil {return}
    t:=&s.kai.state.team
    r:=api.call_result(call,Api_Kai_Identity)
    switch action {
    case "name":
        buffer:[vcs.RECOVERY_TEXT]u8
        defer for &b in buffer {b=0}
        recovery,e:=vcs.machine_user_create(m,p.name,&buffer,p.device)
        if e!=.None {api_kai_why(call,m,e);return}
        t.recovery_length=copy(t.recovery[:],recovery)
        kai_dialog_open(s,.Recovery)
        kai_team_wrote(s)
    case "revoke":
        device,e:=vcs.machine_device_find(m,p.revoke)
        if e==.None {e=vcs.machine_device_revoke(m,device)}
        if e!=.None {api_kai_why(call,m,e);return}
        kai_team_wrote(s)
    case "recovery":
        buffer:[vcs.RECOVERY_TEXT]u8
        defer for &b in buffer {b=0}
        recovery,e:=vcs.machine_recovery_rotate(m,strings.trim_space(p.recovery),&buffer)
        if e!=.None {api_kai_why(call,m,e);return}
        t.recovery_length=copy(t.recovery[:],recovery)
        kai_dialog_open(s,.Recovery)
    case "first_recovery":
        if vcs.machine_user_recovered(m) {
            api.call_fail(call,api.INVALID_PARAMS,"the user has a recovery key: rotate it with recovery, the key it has now")
            return
        }
        buffer:[vcs.RECOVERY_TEXT]u8
        defer for &b in buffer {b=0}
        recovery,e:=vcs.machine_recovery_rotate(m,"",&buffer)
        if e!=.None {api_kai_why(call,m,e);return}
        t.recovery_length=copy(t.recovery[:],recovery)
        kai_dialog_open(s,.Recovery)
        kai_team_wrote(s)
    case "recover":
        user,e:=vcs.machine_user_find(m,p.recover)
        if e==.None {e=vcs.machine_recover(m,user,p.recovery)}
        if e!=.None {api_kai_why(call,m,e);return}
        kai_team_wrote(s)
    }
    v:=&t.view.identity
    if m.user!={} {
        user:=m.user
        r.user=api_kai_hex(user[:],call)
    }
    r.handle=strings.clone(v.handle,call.allocator)
    r.device=strings.clone(v.device,call.allocator)
    r.subject=strings.clone(v.subject,call.allocator)
    r.devices=api_kai_devices(v.devices,call)
    r.orgs=make([]string,len(t.view.orgs),call.allocator)
    for o,i in t.view.orgs {r.orgs[i]=strings.clone(o.name,call.allocator)}
}

@(private)
api_kai_org :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Org_Params)
    action,ok:=api_kai_action(call,{"new","add","link","member","remove","transfer","leave"},{p.new!="",p.add!="",p.link!="",p.member!="",p.remove!="",p.transfer!="",p.leave})
    if !ok {return}
    switch {
    case action=="add" && p.add!="public" && p.add!="org":
        api.call_failf(call,api.INVALID_PARAMS,"add is public or org, not %q: public lets anyone read the project, org only its members",p.add)
        return
    case action=="member" && ka.role_of(p.role)==.None:
        api.call_failf(call,api.INVALID_PARAMS,"role is reader, writer or admin, not %q: give it with member",p.role)
        return
    case action!="member" && p.role!="":
        api.call_fail(call,api.INVALID_PARAMS,"role goes with member: name the member whose role it sets")
        return
    }
    m:=api_kai_machine(s,call)
    if m==nil {return}
    st:=s.kai.state
    e:vcs.Error
    switch action {
    case "new":
        org:vcs.Log_Id
        if org,e=vcs.machine_org_create(m,p.new);e!=.None {break}
    case "":
    case:
        org:vcs.Log_Id
        if org,e=vcs.machine_org_find(m,p.org);e!=.None {break}
        switch action {
        case "add": _,e=ka.project_join(&st.project,m,org,p.add=="public")
        case "link":
            project,porg:vcs.Log_Id
            if project,porg,e=vcs.machine_project_find(m,p.link);e!=.None {break}
            if porg!=org {
                m.why="that project is of another org: give that org with org"
                e=.Invalid_Argument
                break
            }
            e=ka.project_link(&st.project,m,project)
        case "leave": e=vcs.machine_leave(m,org)
        case "member","remove","transfer":
            text:=action=="member"?p.member:action=="remove"?p.remove:p.transfer
            user:vcs.Log_Id
            if user,e=vcs.machine_member(m,org,text);e!=.None {break}
            switch action {
            case "member": e=vcs.machine_role_set(m,org,user,ka.role_of(p.role))
            case "remove": e=vcs.machine_member_remove(m,org,user)
            case "transfer": e=vcs.machine_owner_transfer(m,org,user)
            }
        }
    }
    if e!=.None {api_kai_why(call,m,e);return}
    if action!="" {
        kai_team_wrote(s)
        kai_publish(s)
    }
    v:=&st.team.view
    r:=api.call_result(call,Api_Kai_Orgs)
    r.orgs=make([]Api_Kai_Org,len(v.orgs),call.allocator)
    for &o,i in v.orgs {
        x:=&r.orgs[i]
        id:=o.id
        x^={id=api_kai_hex(id[:],call),name=strings.clone(o.name,call.allocator),owner=strings.clone(o.owner,call.allocator),role=ka.role_text(o.role)}
        x.members=make([]Api_Kai_Member,len(o.members),call.allocator)
        for member,k in o.members {
            user:=member.user
            x.members[k]={handle=strings.clone(member.handle,call.allocator),user=api_kai_hex(user[:],call),role=ka.role_text(member.role),devices=api_kai_devices(member.devices,call)}
        }
        x.nodes=make([]Api_Kai_Node,len(o.nodes),call.allocator)
        for n,k in o.nodes {
            key:=n.key
            x.nodes[k]={api_kai_hex(key[:],call),ka.node_modes_text(n.modes,call.allocator)}
        }
        x.projects=make([]Api_Kai_Project,len(o.projects),call.allocator)
        for project,k in o.projects {
            pid:=project.id
            policies:=make([]Api_Kai_Policy,len(project.policies),call.allocator)
            for policy,j in project.policies {policies[j]={strings.clone(policy.bookmark,call.allocator),strings.clone(policy.text,call.allocator)}}
            x.projects[k]={id=api_kai_hex(pid[:],call),name=strings.clone(project.name,call.allocator),public=project.public,open=pid==v.project,policies=policies}
        }
    }
}

@(private)
api_kai_pair :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Pair_Params)
    action,ok:=api_kai_action(call,{"offer","join","answer"},{p.offer!="",p.join!="",p.answer!=""})
    if !ok {return}
    mode:vcs.Pair_Mode
    modes:vcs.Node_Modes
    role:=vcs.Role.Writer
    switch action {
    case "offer":
        switch p.offer {
        case "member": mode=.Member
        case "device": mode=.Device
        case "node": mode=.Node
        case "recover": mode=.Recover
        case:
            api.call_failf(call,api.INVALID_PARAMS,"offer is member, device, node or recover, not %q: member adds a user to the org, device links a second device of this user, node adds a relay or seed, recover lets a machine with no user fetch the user it recovers",p.offer)
            return
        }
        if p.role!="" {role=ka.role_of(p.role)}
        if role==.None {
            api.call_failf(call,api.INVALID_PARAMS,"role is reader, writer or admin, not %q",p.role)
            return
        }
        parsed:bool
        if modes,parsed=ka.node_modes_of(p.modes);!parsed {
            api.call_failf(call,api.INVALID_PARAMS,"modes takes relay, seed and ddc apart by commas, not %q",p.modes)
            return
        }
        if mode==.Node && modes=={} {modes={.Relay,.Seed}}
    case "join":
        if _,decoded:=vcs.ticket_decode(strings.trim_space(p.join));!decoded {
            api.call_fail(call,api.INVALID_PARAMS,"join: the ticket does not read: copy it again, whole, from the machine that offered it")
            return
        }
    case "answer":
        if p.answer!="approve" && p.answer!="deny" {
            api.call_failf(call,api.INVALID_PARAMS,"answer is approve or deny, not %q",p.answer)
            return
        }
        if p.answer=="approve" && len(p.code)!=vcs.PAIR_CODE_TEXT {
            api.call_fail(call,api.INVALID_PARAMS,"code: approving takes the code the other machine shows, as 1234-5678")
            return
        }
    }
    m:=api_kai_machine(s,call)
    if m==nil {return}
    t:=&s.kai.state.team
    if action!="" {
        if message:=kai_team_connect(s,true);message!="" {
            api.call_fail(call,api.SERVER_ERROR,message)
            return
        }
    }
    c:=&t.control
    r:=api.call_result(call,Api_Kai_Pair)
    switch action {
    case "offer":
        org:vcs.Log_Id
        if mode!=.Device {
            e:vcs.Error
            if org,e=vcs.machine_org_find(m,p.org);e!=.None {api_kai_why(call,m,e);return}
        }
        buffer:[vcs.TICKET_TEXT]u8
        ticket,e:=vcs.control_pair_offer(c,mode,org,role,modes,&buffer)
        if e!=.None {api.call_fail(call,e==.Invalid_Argument?api.INVALID_PARAMS:api.SERVER_ERROR,c.why);return}
        t.ticket_length=copy(t.ticket[:],ticket)
        r.ticket=strings.clone(ticket,call.allocator)
    case "join":
        name,ne:=vcs.machine_pair_name(m,p.name)
        if ne!=.None {api_kai_why(call,m,ne);return}
        if e:=vcs.control_pair_join(c,p.join,name);e!=.None {api.call_fail(call,e==.Invalid_Argument || e==.Expired || e==.Corrupt?api.INVALID_PARAMS:api.SERVER_ERROR,c.why);return}
        t.joining,t.progress,t.progress_code,t.progress_why_length=true,.Asking,{},0
    case "answer":
        if e:=vcs.control_pair_answer(c,p.answer=="approve",p.code);e!=.None {api.call_fail(call,api.SERVER_ERROR,c.why);return}
        t.asked=false
        if t.dialog==.Pair {kai_dialog_close(s)}
    }
    if t.connected {
        if request,asking,e:=vcs.control_pair_request(c);e==.None {
            kai_pair_asked(s,request,asking)
            if asking {
                modes:=[vcs.Pair_Mode]string{.Device="device",.Member="member",.Node="node",.Recover="recover"}
                r.asking,r.mode,r.code=true,modes[request.mode],strings.clone(request.code,call.allocator)
                r.who=vcs.pair_request_who(m,request,call.allocator)
            }
        }
        if t.joining || t.progress!=.None {
            if progress,e:=vcs.control_pair_progress(c);e==.None {
                t.progress=progress.phase
                copy(t.progress_code[:],progress.code)
                t.progress_why_length=copy(t.progress_why[:],progress.why)
                if progress.phase!=.Asking && progress.phase!=.Waiting {t.joining=false}
                if progress.phase==.Approved {kai_team_wrote(s)}
            }
        }
    }
    phases:=[vcs.Pair_Phase]string{.None="none",.Asking="asking",.Waiting="waiting",.Approved="approved",.Denied="denied",.Failed="failed"}
    r.joining=phases[t.progress]
    if t.progress_code[0]!=0 {r.joined_code=strings.clone(string(t.progress_code[:]),call.allocator)}
    r.why=strings.clone(string(t.progress_why[:t.progress_why_length]),call.allocator)
}

@(private)
api_kai_peers :: proc(s:^Session,call:^api.Call) {
    if api_kai_machine(s,call)==nil {return}
    t:=&s.kai.state.team
    r:=api.call_result(call,Api_Kai_Peers)
    r.mesh=kai_runner_text(t)
    r.peers=make([]Api_Kai_Peer,len(t.view.peers),call.allocator)
    for p,i in t.view.peers {r.peers[i]={strings.clone(p.who,call.allocator),strings.clone(p.org,call.allocator),strings.clone(p.rung,call.allocator)}}
    r.behind=make([]Api_Kai_Behind,len(t.view.behind),call.allocator)
    for b,i in t.view.behind {r.behind[i]={strings.clone(b.org,call.allocator),b.behind,b.unfound}}
}

// The workspace and the machine of a method of the project.
@(private)
api_kai_project :: proc(s:^Session,call:^api.Call) -> (p:^ka.Project,m:^vcs.Machine) {
    if api_kai_workspace(s,call)==nil {return}
    if m=api_kai_machine(s,call);m==nil {return}
    return &s.kai.state.project,m
}

// The change text names: what the workspace knows, or a shared bookmark.
@(private)
api_kai_revision :: proc(s:^Session,call:^api.Call,text:string) -> (revision:vcs.Revision,ok:bool) {
    w:=kai_workspace(s)
    if r,e:=ka.revision_find(w,text);e==.None {return r,true}
    if m,_:=kai_team_machine(s);m!=nil {
        if r,e:=ka.revision_resolve(&s.kai.state.project,m,text);e==.None {return r,true}
        api.call_failf(call,api.INVALID_PARAMS,"%q: %s",text,m.why)
        return
    }
    api.call_failf(call,api.INVALID_PARAMS,"%q names no single visible change: @, @-, a bookmark, <handle>/<device>:<bookmark> or a prefix of at least %d digits of a change kai.log lists",text,ka.CHANGE_TEXT_MIN)
    return
}

@(private)
api_kai_proposals :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Proposals_Params)
    if p.open=="" && (len(p.changes)>0 || p.title!="" || p.text!="") {
        api.call_fail(call,api.INVALID_PARAMS,"changes, title and text go with open: name the shared bookmark the proposal lands on")
        return
    }
    if p.open!="" && !vcs.bookmark_name_valid(p.open) {
        api.call_failf(call,api.INVALID_PARAMS,"open: %q is no bookmark name: letters, digits, - _ . and / of at most %d bytes",p.open,vcs.BOOKMARK_NAME_MAX)
        return
    }
    project,m:=api_kai_project(s,call)
    if project==nil {return}
    t:=&s.kai.state.team
    r:=api.call_result(call,Api_Kai_Proposals)
    if p.open!="" {
        if _,message:=kai_prepare(s);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
        stack:=make([dynamic]vcs.Revision,context.temp_allocator)
        for text in p.changes {
            revision,ok:=api_kai_revision(s,call,text)
            if !ok {return}
            append(&stack,revision)
        }
        title:=p.title
        if title=="" {title=ka.proposal_title(project)}
        if title=="" {title="(no description)"}
        id,e:=ka.proposal_open(project,m,p.open,title,p.text,stack[:])
        if e!=.None {api_kai_why(call,m,e);return}
        r.opened=api_kai_hex(id[:],call)
        kai_team_wrote(s)
    }
    v:=&t.view
    if v.org<0 {
        e:=vcs.Error.Missing
        if _,_,e=ka.project_of(project,m);e!=.None {api_kai_why(call,m,e);return}
    }
    r.proposals=make([]Api_Kai_Proposal_Row,len(v.proposals),call.allocator)
    for row,i in v.proposals {
        id:=row.id
        r.proposals[i]={id=api_kai_hex(id[:],call),title=strings.clone(row.title,call.allocator),target=strings.clone(row.target,call.allocator),opener=strings.clone(row.opener,call.allocator),status=kai_status_text(row.status),approvals=row.approvals,comments=row.comments}
    }
}

kai_status_text :: proc(status:vcs.Proposal_Status) -> string {
    texts:=[vcs.Proposal_Status]string{.Open="open",.Closed="closed",.Landed="landed"}
    return texts[status]
}

@(private)
api_kai_proposal :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Proposal_Params)
    if p.proposal=="" {
        api.call_fail(call,api.INVALID_PARAMS,"proposal: name one by a prefix of its id, as kai.proposals lists it")
        return
    }
    action,ok:=api_kai_action(call,{"comment","verdict","revise","check","close","reopen","land"},{p.comment!="",p.verdict!="",p.revise,p.check!="",p.close,p.reopen,p.land})
    if !ok {return}
    anchor:vcs.Anchor
    switch {
    case action!="comment" && action!="" && p.file!="":
        api.call_fail(call,api.INVALID_PARAMS,"file goes with comment, or alone for its detail")
        return
    case action!="comment" && (p.lines!="" || p.entity!=0 || p.reply!=""):
        api.call_fail(call,api.INVALID_PARAMS,"lines, entity and reply go with comment: give its text")
        return
    case p.change!="" && p.file=="":
        api.call_fail(call,api.INVALID_PARAMS,"change goes with file: name the file whose detail it gives")
        return
    case (p.lines!="" || p.entity!=0) && p.file=="":
        api.call_fail(call,api.INVALID_PARAMS,"lines and entity hang on a file: give it with file")
        return
    case p.lines!="" && p.entity!=0:
        api.call_fail(call,api.INVALID_PARAMS,"a comment hangs on lines or on an entity, not both")
        return
    case p.lines!="":
        parsed:bool
        if anchor,parsed=ka.lines_of(p.lines);!parsed {
            api.call_failf(call,api.INVALID_PARAMS,"lines is A-B from 1 with A no greater than B, as 3-7, not %q",p.lines)
            return
        }
    case p.entity!=0: anchor={kind=.Structural,key=p.entity}
    case p.file!="": anchor={kind=.File}
    }
    verdict:vcs.Verdict_Kind
    switch p.verdict {
    case "","approve": verdict=.Approve
    case "changes": verdict=.Changes
    case "withdraw": verdict=.Withdraw
    case:
        api.call_failf(call,api.INVALID_PARAMS,"verdict is approve, changes or withdraw, not %q",p.verdict)
        return
    }
    if action=="check" && len(p.command)==0 {
        api.call_fail(call,api.INVALID_PARAMS,"command: a check runs a program, as [\"mirai\",\"test\",\"kai\"]")
        return
    }
    if action!="check" && len(p.command)>0 {
        api.call_fail(call,api.INVALID_PARAMS,"command goes with check: give the check's name")
        return
    }
    if action!="revise" && len(p.changes)>0 {
        api.call_fail(call,api.INVALID_PARAMS,"changes go with revise")
        return
    }
    project,m:=api_kai_project(s,call)
    if project==nil {return}
    project_id,id,e:=ka.proposal_find(project,m,p.proposal)
    if e!=.None {api_kai_why(call,m,e);return}
    passed:bool
    switch action {
    case "comment": e=ka.proposal_comment(project,m,id,p.file,anchor,p.reply,p.comment)
    case "verdict": e=vcs.machine_proposal_verdict(m,project_id,id,verdict)
    case "revise":
        if _,message:=kai_prepare(s);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
        stack:=make([dynamic]vcs.Revision,context.temp_allocator)
        for text in p.changes {
            revision,found:=api_kai_revision(s,call,text)
            if !found {return}
            append(&stack,revision)
        }
        e=ka.proposal_revise(project,m,id,stack[:])
    case "check":
        if _,message:=kai_prepare(s);message!="" {api.call_fail(call,api.SERVER_ERROR,message);return}
        passed,_,e=ka.check_run(project,m,id,p.check,p.command)
    case "close","reopen": e=vcs.machine_proposal_close(m,project_id,id,action=="reopen")
    case "land": e=vcs.machine_proposal_land(m,project_id,id)
    }
    if e!=.None {api_kai_why(call,m,e);return}
    t:=&s.kai.state.team
    t.proposal=id
    if action!="" {kai_team_wrote(s)} else {kai_team_read(s)}
    v:=&t.view
    if !v.shown {
        api.call_fail(call,api.SERVER_ERROR,m.why!=""?m.why:"the proposal does not read: let the agent fetch its log")
        return
    }
    r:=api.call_result(call,Api_Kai_Proposal)
    api_kai_proposal_fill(r,v,call)
    r.passed=passed
    if p.file=="" || action!="" {return}
    revision:vcs.Revision
    if p.change!="" {
        found:bool
        if revision,found=api_kai_revision(s,call,p.change);!found {return}
    } else {
        // The topmost change of the stack that changed the file.
        #reverse for files,i in v.changes {
            for file in files {
                if file.path==p.file {revision=v.proposal.stack[i].revision}
            }
            if revision!={} {break}
        }
        if revision=={} {
            api.call_failf(call,api.INVALID_PARAMS,"file: no change of the stack changed %q: give a file stack lists",p.file)
            return
        }
    }
    if !api_kai_detail(s,call,revision,p.file,&r.detail) {return}
}

@(private)
api_kai_proposal_fill :: proc(r:^Api_Kai_Proposal,v:^Kai_Team_View,call:^api.Call) {
    a:=call.allocator
    x:=&v.proposal
    id:=x.id
    r^={id=api_kai_hex(id[:],call),title=strings.clone(x.title,a),text=strings.clone(x.text,a),target=strings.clone(x.target,a),opener=strings.clone(x.opener,a),status=kai_status_text(x.status),approvals=x.approvals,blocking=strings.clone(x.blocking,a)}
    r.stack=make([]Api_Kai_Proposal_Change,len(x.stack),a)
    for item,i in x.stack {
        files:=make([]Api_Kai_File,len(v.changes[i]),a)
        for f,k in v.changes[i] {
            mark:=[1]u8{f.mark}
            files[k]={strings.clone(f.path,a),strings.clone(string(mark[:]),a)}
        }
        r.stack[i]={ka.change_text(item.change,a),strings.clone(item.description,a),files}
    }
    r.comments=make([]Api_Kai_Comment,len(x.notes),a)
    for n,i in x.notes {
        address,reply:=n.address,n.reply_to
        c:=&r.comments[i]
        c^={id=api_kai_hex(address[:],call),author=strings.clone(n.author,a),text=strings.clone(n.text,a),file=strings.clone(n.path,a),outdated=n.outdated}
        if reply!={} {c.reply_to=api_kai_hex(reply[:],call)}
        if n.path!="" {c.change=ka.change_text(n.change,a)}
        #partial switch n.anchor.kind {
        case .Lines: c.lines=fmt.aprintf("%d-%d",n.anchor.line,n.anchor.line+n.anchor.lines-1,allocator=a)
        case .Structural: c.entity=n.anchor.key
        }
    }
    verdicts:=[vcs.Verdict_Kind]string{.Approve="approve",.Changes="changes",.Withdraw="withdraw"}
    r.verdicts=make([]Api_Kai_Verdict,len(x.verdicts),a)
    for verdict,i in x.verdicts {r.verdicts[i]={strings.clone(verdict.user,a),verdicts[verdict.verdict],verdict.current}}
    states:=[vcs.Check_State]string{.Pending="pending",.Passed="passed",.Failed="failed"}
    r.checks=make([]Api_Kai_Check,len(x.checks),a)
    for c,i in x.checks {r.checks[i]={strings.clone(c.name,a),states[c.state]}}
}

@(private)
api_kai_scopes :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Scopes_Params)
    action,ok:=api_kai_action(call,{"add","remove","rotate","public"},{len(p.add)>0,p.remove!="",p.rotate!="",p.public!=""})
    if !ok {return}
    readers:=vcs.Role.Writer
    switch {
    case action!="add" && (p.readers!="" || p.history):
        api.call_fail(call,api.INVALID_PARAMS,"readers and history go with add: give the patterns of the scope")
        return
    case p.readers=="owner": readers=.Owner
    case p.readers!="":
        if readers=ka.role_of(p.readers);readers==.None {
            api.call_failf(call,api.INVALID_PARAMS,"readers is reader, writer, admin or owner, not %q",p.readers)
            return
        }
    }
    for pattern in p.add {
        if pattern=="" || strings.has_prefix(pattern,"/") || strings.contains(pattern,"..") || strings.contains_any(pattern,"\\\x00") {
            api.call_failf(call,api.INVALID_PARAMS,"add: %q is no pattern of the project's paths: relative with forward slashes, as secrets/** or .env",pattern)
            return
        }
    }
    path,line:=p.public,0
    if cut:=strings.last_index_byte(path,':');action=="public" && cut>0 {
        n,parsed:=strconv.parse_int(path[cut+1:],10)
        if !parsed || n<1 {
            api.call_failf(call,api.INVALID_PARAMS,"public: %q is path or path:line with a line from 1",p.public)
            return
        }
        path,line=path[:cut],n
    }
    project,m:=api_kai_project(s,call)
    if project==nil {return}
    t:=&s.kai.state.team
    e:vcs.Error
    switch action {
    case "add": _,e=ka.scope_add(project,m,p.add,readers,p.history)
    case "remove","rotate":
        scope:vcs.Scope_Id
        if scope,e=ka.scope_find(project,m,action=="remove"?p.remove:p.rotate);e!=.None {break}
        if action=="remove" {e=ka.scope_remove(project,m,scope)} else {_,e=ka.scope_rotate(project,m,scope)}
    case "public": e=ka.public_add(project,m,path,line)
    }
    if e!=.None {api_kai_why(call,m,e);return}
    if action!="" {
        kai_refusal_set(t,{})
        kai_team_wrote(s)
        // What a scope or a public path changes is read again by a snapshot of every file.
        vcs.workspace_touched(&project.workspace,nil,false)
        kai_snapshot(s)
        kai_publish(s)
    }
    v:=&t.view
    if v.org<0 {
        e=.Missing
        if _,_,e=ka.project_of(project,m);e!=.None {api_kai_why(call,m,e);return}
    }
    r:=api.call_result(call,Api_Kai_Scopes)
    o:=&v.orgs[v.org]
    scopes:=make([dynamic]Api_Kai_Scope,call.allocator)
    for sc in o.scopes {
        if sc.project!=v.project {continue}
        patterns:=make([]string,len(sc.patterns),call.allocator)
        for x,k in sc.patterns {patterns[k]=strings.clone(x,call.allocator)}
        append(&scopes,Api_Kai_Scope{strings.clone(sc.id,call.allocator),patterns,ka.role_text(sc.readers),sc.history})
    }
    r.scopes=scopes[:]
    publics:=make([dynamic]string,call.allocator)
    for x in o.publics {
        if x.project==v.project {append(&publics,strings.clone(x.path,call.allocator))}
    }
    r.public=publics[:]
    refusal:=&t.refusal
    if refusal.text!="" {
        actions:=[ka.Refusal_Action]string{.None="",.Keep_Public="public",.Rotate="rotate"}
        r.refused,r.refused_path,r.refused_line,r.action=strings.clone(refusal.text,call.allocator),strings.clone(refusal.path,call.allocator),refusal.line,actions[refusal.action]
        if refusal.action==.Rotate {
            scope:=refusal.scope
            r.scope=ka.hex(scope[:4],call.allocator)
        }
    }
}

// The names of the shared bookmarks that point at revision: the project's and
// every device's, apart by commas, in allocator.
kai_shared_names :: proc(s:^Session,revision:vcs.Revision,allocator:=context.temp_allocator) -> string {
    if s.kai==nil || s.kai.state==nil {return ""}
    names:=make([dynamic]string,context.temp_allocator)
    for b in s.kai.state.team.view.shared {
        if b.target==revision {append(&names,b.name)}
    }
    return strings.join(names[:],", ",allocator)
}

// What kai.bookmarks lists of the project: its shared bookmarks and every
// device's, after the workspace's own.
@(private)
api_kai_shared :: proc(s:^Session,call:^api.Call,out:^[dynamic]Api_Kai_Bookmark) {
    w:=kai_workspace(s)
    for b in s.kai.state.team.view.shared {
        x:=Api_Kai_Bookmark{name=strings.clone(b.name,call.allocator),shared=b.device==({}),here=b.here}
        if b.here {x.change=api_kai_text(w,b.target,call)}
        if b.device!=({}) {
            cut:=strings.last_index_byte(b.name,':')
            if cut>0 {x.device=strings.clone(b.name[:cut],call.allocator)}
        }
        append(out,x)
    }
}

// Moves or guards a shared bookmark of the project for kai.bookmarks: false
// when the call failed.
@(private)
api_kai_bookmark_team :: proc(s:^Session,call:^api.Call,p:^Api_Kai_Bookmarks_Params) -> bool {
    if p.move=="" && p.policy=="" {return true}
    if p.move!="" && p.policy!="" {
        api.call_fail(call,api.INVALID_PARAMS,"move and policy are given together: give one per call")
        return false
    }
    name:=p.move!=""?p.move:p.policy
    if !vcs.bookmark_name_valid(name) {
        api.call_failf(call,api.INVALID_PARAMS,"%q is no bookmark name: letters, digits, - _ . and / of at most %d bytes",name,vcs.BOOKMARK_NAME_MAX)
        return false
    }
    if p.policy!="" && (p.approvals<0 || p.approvals>255) {
        api.call_fail(call,api.INVALID_PARAMS,"approvals is from 0 to 255: how many members approve before it lands")
        return false
    }
    for check in p.checks {
        if check=="" || len(check)>vcs.NAME_MAX {
            api.call_failf(call,api.INVALID_PARAMS,"checks: a check's name is 1 to %d bytes, as unit",vcs.NAME_MAX)
            return false
        }
    }
    project,m:=api_kai_project(s,call)
    if project==nil {return false}
    e:vcs.Error
    if p.move!="" {
        if _,message:=kai_prepare(s);message!="" {
            api.call_fail(call,api.SERVER_ERROR,message)
            return false
        }
        revision,ok:=api_kai_revision(s,call,p.change!=""?p.change:"@")
        if !ok {return false}
        m.leak={}
        if e=ka.bookmark_move(project,m,p.move,revision);e!=.None && m.leak.path!="" {kai_refusal_set(&s.kai.state.team,ka.publish_refusal(m))}
    } else {
        e=ka.policy_set(project,m,p.policy,p.approvals,p.checks)
    }
    if e!=.None {
        api_kai_why(call,m,e)
        return false
    }
    kai_team_wrote(s)
    return true
}
