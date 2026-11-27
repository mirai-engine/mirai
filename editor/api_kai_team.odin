package editor

import "core:fmt"
import "core:strings"
import ka "mirai:cook/kai"
import "mirai:editor/api"
import vcs "mirai:kai"

// The kai.* methods of the team: this machine's profile, its orgs, one-step
// invites, publishing the project to main, pulling an org's repository into a
// folder, the agent's peers and pulls, and a server's web sign-in, through
// the procedures of cook/kai and kai that `mirai kai` runs. Each one writes
// what it is asked and gives its result whole, as the Kai tab shows it; a
// failure says what failed and how to fix it.

Api_Kai_Profile_Params :: struct {
    name:string `mirai:"label=Your name, which every org you make or join shows"`,
    device:string `mirai:"label=This machine's name, as Mac or Studio PC"`,
}
Api_Kai_Member :: struct {
    key:string `mirai:"label=The first hex digits of its device key"`,
    name,device,role:string,
    you:bool `mirai:"label=This machine"`,
}
Api_Kai_Repository :: struct {
    id,name:string,
    public:bool,
    main:string `mirai:"label=The change main names; empty while nobody published it"`,
    bytes:i64 `mirai:"optional,label=Total file bytes of main's tree when known"`,
    here:bool `mirai:"label=Every object main reaches is in this store"`,
    linked:bool `mirai:"label=A workspace of this machine is one of it"`,
}
Api_Kai_Org :: struct {
    id,name,role:string,
    server:string `mirai:"optional,label=Attached central server host:port, empty when none"`,
    version:int,
    members:[]Api_Kai_Member,
    repositories:[]Api_Kai_Repository,
}
Api_Kai_Orgs :: struct {
    name:string `mirai:"label=Of this machine's person; empty until kai.profile"`,
    device:string,
    orgs:[]Api_Kai_Org,
}
Api_Kai_Org_Params :: struct {
    new:string `mirai:"optional,label=Makes an org of this name with this machine its admin"`,
    attach:string `mirai:"optional,label=Attaches an existing org (by name or id prefix) to a Kai server"`,
    server:string `mirai:"optional,label=With new or attach: host:port of the Kai server (defaults to MIRAI_KAI_SERVER / default server)"`,
    org:string `mirai:"optional,label=With member: the org, by its name or a prefix of its id"`,
    member:string `mirai:"optional,label=A member of org, by its device name or a prefix of its key"`,
    role:string `mirai:"optional,label=With member: reader, writer, admin or node"`,
    remove:bool `mirai:"optional,label=With member: removes it from the org"`,
}
Api_Kai_Invite_Params :: struct {
    org:string `mirai:"label=The org, by its name or a prefix of its id"`,
    role:string `mirai:"optional,label=reader, writer (the default), admin or node (a server)"`,
    mine:bool `mirai:"optional,label=For another machine of this person: it joins under this machine's name"`,
    at:string `mirai:"optional,label=host:port where the other machine reaches this one when it is on another network: what the router forwards; none: this machine's addresses on its LAN"`,
}
Api_Kai_Invite :: struct {
    invite:string `mirai:"label=What the other machine joins with, once, within 72 hours"`,
    addresses:[]string `mirai:"label=Where it reaches this machine"`,
}
Api_Kai_Join_Params :: struct {
    invite:string `mirai:"optional,label=Starts joining with it; none: says how the last join went"`,
}
Api_Kai_Joined :: struct {
    stage:string `mirai:"label=none, waiting (it reaches the inviting machine and waits for the org's record), done or failed"`,
    why:string,
    org:string,
    name:string,
}
Api_Kai_Publish_Params :: struct {
    description:string `mirai:"optional,label=Describes the working change it closes"`,
    bookmark:string `mirai:"optional,label=The shared bookmark it moves; none: main"`,
    org:string `mirai:"optional,label=When the project is in no org yet: the org it goes into in the same call"`,
    visibility:string `mirai:"optional,label=With org: public (shows to anyone on a server's web view) or org (the default)"`,
}
Api_Kai_Published :: struct {
    change:string,
    bookmark:string,
    secrets:[]string `mirai:"label=Files named like secrets that a public repository now shows: remove them and publish again"`,
}
Api_Kai_Clone_Params :: struct {
    org:string `mirai:"optional,label=The org, by its name or a prefix of its id"`,
    repository:string `mirai:"optional,label=A repository of org, by its name or a prefix of its id"`,
    folder:string `mirai:"optional,label=Where it goes: empty, not there yet, or a workspace a pull of it left; none: the projects screen's location"`,
    cancel:bool `mirai:"optional,label=Stops the pull that runs, or dismisses one that failed"`,
}
Api_Kai_Clone :: struct {
    stage:string `mirai:"label=none, waiting (the agent pulls it), done or failed"`,
    why:string,
    folder:string,
    chunks:int `mirai:"label=Chunks the agent took for it"`,
    bytes:i64,
}
Api_Kai_Peer :: struct {name,device,address:string}
Api_Kai_Pull :: struct {
    repository:string,
    chunks:int,
    left:int,
    bytes:i64,
    whole:bool,
}
Api_Kai_Peers :: struct {
    running:bool `mirai:"label=The agent of this machine runs in this editor"`,
    port:int,
    addresses:[]string `mirai:"label=Where this machine listens on its LAN"`,
    peers:[]Api_Kai_Peer,
    pulls:[]Api_Kai_Pull,
}
Api_Kai_Web_Login_Params :: struct {
    server:string `mirai:"optional,label=The host:port of the server's agent, as the org lists it; none: says how the last sign-in went"`,
    name:string `mirai:"optional,label=a-z, 0-9, . _ and -"`,
    password:string `mirai:"optional,label=8 to 256 bytes"`,
}
Api_Kai_Task :: struct {
    stage:string `mirai:"label=none, waiting, done or failed"`,
    why:string,
}

@(private)
kai_team_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="kai.profile",summary="Names the person of this machine and the machine, which every org it makes or joins shows.",params=type_info_of(Api_Kai_Profile_Params),result=type_info_of(Api_Kai_Orgs),run=api_kai_profile})
    api_register(s,st,{name="kai.org",summary="This machine's orgs with their members and repositories; makes one, sets a member's role or removes it first when asked.",params=type_info_of(Api_Kai_Org_Params),result=type_info_of(Api_Kai_Orgs),run=api_kai_org})
    api_register(s,st,{name="kai.invite",summary="A one-time invite to an org for another machine: its address, this device's key and a secret only it carries; the other machine joins with kai.join while this editor runs.",params=type_info_of(Api_Kai_Invite_Params),result=type_info_of(Api_Kai_Invite),run=api_kai_invite})
    api_register(s,st,{name="kai.join",summary="Joins the org of an invite on a thread of the agent: reaches the machine that made it, proves the invite and waits for the org's record that lists this machine; asked again with no invite, how it went.",params=type_info_of(Api_Kai_Join_Params),result=type_info_of(Api_Kai_Joined),run=api_kai_join})
    api_register(s,st,{name="kai.publish",summary="Publishes the working copy to main for the whole org: closes the working change when it changed a file, and moves main; a project in no org goes into one first, in the same call.",params=type_info_of(Api_Kai_Publish_Params),result=type_info_of(Api_Kai_Published),run=api_kai_publish})
    api_register(s,st,{name="kai.clone",summary="Pulls a repository of an org into a folder: it is a workspace at once, and its files are written once the agent has every object of main; asked again, how far it is.",params=type_info_of(Api_Kai_Clone_Params),result=type_info_of(Api_Kai_Clone),run=api_kai_clone})
    api_register(s,st,{name="kai.peers",summary="The agent of this machine: where it listens, the machines connected now and how far each repository's pull is.",result=type_info_of(Api_Kai_Peers),flags={.Read_Only},run=api_kai_peers})
    api_register(s,st,{name="kai.web_login",summary="Sets the name and password this machine signs in with on the web view of a Kai server of its org, on a thread of the agent, which proves the server's key first; asked again with no params, how it went.",params=type_info_of(Api_Kai_Web_Login_Params),result=type_info_of(Api_Kai_Task),run=api_kai_web_login})
}

@(private)
api_kai_team :: proc(s:^Session,call:^api.Call) -> ^vcs.Team {
    t,message:=kai_team_of(s)
    if t==nil {api.call_fail(call,api.SERVER_ERROR,message)}
    return t
}

// Fails the call with what the team says failed.
@(private)
api_kai_why :: proc(call:^api.Call,t:^vcs.Team,e:vcs.Error) {
    why:=t.why!=""?t.why:vcs.error_text(e)
    api.call_fail(call,e==.Invalid_Argument?api.INVALID_PARAMS:api.SERVER_ERROR,why)
}

// The org text names: its name, or a prefix of its id; the call fails otherwise.
@(private)
api_kai_org_find :: proc(s:^Session,call:^api.Call,t:^vcs.Team,text:string) -> (org:vcs.Org_Id,ok:bool) {
    found:=0
    for id in vcs.team_org_ids(t) {
        o,_,e:=vcs.team_org(t,id)
        if e!=.None {continue}
        if o.name==text || (len(text)>=4 && strings.has_prefix(org_hex(id),strings.to_lower(text,context.temp_allocator))) {
            org=id
            found+=1
        }
    }
    if found!=1 {
        api.call_failf(call,api.INVALID_PARAMS,"%q names %s org of this machine: kai.org lists them",text,found==0?"no":"more than one")
        return {},false
    }
    return org,true
}

@(private)
api_kai_orgs_fill :: proc(s:^Session,call:^api.Call,t:^vcs.Team) {
    r:=api.call_result(call,Api_Kai_Orgs)
    r.name=strings.clone(t.name,call.allocator)
    r.device=strings.clone(t.device,call.allocator)
    ids:=vcs.team_org_ids(t)
    orgs:=make([dynamic]Api_Kai_Org,0,len(ids),call.allocator)
    for id in ids {
        v:ka.Org_View
        if ka.org_view(t,id,&v,call.allocator)!=.None {continue}
        o:=Api_Kai_Org{id=strings.clone(org_hex(id),call.allocator),name=v.name,role=v.role,server=v.server,version=int(v.version)}
        o.members=make([]Api_Kai_Member,len(v.members),call.allocator)
        for m,i in v.members {
            key:=m.key
            o.members[i]={ka.hex(key[:4],call.allocator),m.name,m.device,m.role,m.you}
        }
        o.repositories=make([]Api_Kai_Repository,len(v.repos),call.allocator)
        for x,i in v.repos {
            id:=x.id
            o.repositories[i]={ka.hex(id[:],call.allocator),x.name,x.public,x.main,x.bytes,x.here,x.linked}
        }
        append(&orgs,o)
    }
    r.orgs=orgs[:]
}

@(private)
api_kai_profile :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Profile_Params)
    t:=api_kai_team(s,call)
    if t==nil {return}
    if e:=vcs.team_profile_set(t,strings.trim_space(p.name),strings.trim_space(p.device));e!=.None {
        api_kai_why(call,t,e)
        return
    }
    kai_team_wrote(s)
    api_kai_orgs_fill(s,call,t)
}

@(private)
api_kai_org :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Org_Params)
    t:=api_kai_team(s,call)
    if t==nil {return}
    switch {
    case p.new!="":
        if p.member!="" || p.attach!="" {
            api.call_fail(call,api.INVALID_PARAMS,"new, attach and member are given separately: give one per call")
            return
        }
        id,e:=vcs.team_org_create(t,strings.trim_space(p.new))
        if e!=.None {
            api_kai_why(call,t,e)
            return
        }
        kai_team_wrote(s)
        srv:=strings.trim_space(p.server)
        if srv=="" {srv=kai_default_server(s)}
        if srv!="" {kai_task_start(s,.Attach,srv,org=id,silent=true)}
    case p.attach!="":
        if p.member!="" {
            api.call_fail(call,api.INVALID_PARAMS,"attach and member are given together: give one per call")
            return
        }
        org,ok:=api_kai_org_find(s,call,t,p.attach)
        if !ok {return}
        srv:=strings.trim_space(p.server)
        if srv=="" {srv=kai_default_server(s)}
        if srv=="" {
            api.call_fail(call,api.INVALID_PARAMS,"no Kai server is configured: pass server host:port or set MIRAI_KAI_SERVER")
            return
        }
        if message:=kai_task_start(s,.Attach,srv,org=org,silent=false);message!="" {
            api.call_fail(call,api.SERVER_ERROR,message)
            return
        }
    case p.member!="":
        org,ok:=api_kai_org_find(s,call,t,p.org)
        if !ok {return}
        o,_,_:=vcs.team_org(t,org)
        found:=-1
        for m,i in o.members {
            key:=m.key
            if m.device==p.member || (len(p.member)>=4 && strings.has_prefix(ka.hex(key[:]),strings.to_lower(p.member,context.temp_allocator))) {
                if found>=0 {
                    api.call_failf(call,api.INVALID_PARAMS,"%q names several members: give more of a key",p.member)
                    return
                }
                found=i
            }
        }
        if found<0 {
            api.call_failf(call,api.INVALID_PARAMS,"%q names no member of the org: kai.org lists them",p.member)
            return
        }
        e:vcs.Error
        if p.remove {
            e=vcs.team_member_remove(t,org,o.members[found].key)
        } else {
            role,known:=ka.role_of(p.role)
            if !known {
                api.call_fail(call,api.INVALID_PARAMS,"role is reader, writer, admin or node")
                return
            }
            m:=o.members[found]
            m.role=role
            e=vcs.team_member_set(t,org,m)
        }
        if e!=.None {
            api_kai_why(call,t,e)
            return
        }
        kai_team_wrote(s)
    case p.remove || p.role!="" || p.org!="":
        api.call_fail(call,api.INVALID_PARAMS,"org, role and remove go with member")
        return
    }
    api_kai_orgs_fill(s,call,t)
}

@(private)
api_kai_invite :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Invite_Params)
    t:=api_kai_team(s,call)
    if t==nil {return}
    org,ok:=api_kai_org_find(s,call,t,p.org)
    if !ok {return}
    k:=s.kai.team
    asked:=k.invite_asked
    k.invite_asked=false
    role:=vcs.Role.Writer
    if p.role!="" {
        known:bool
        if role,known=ka.role_of(p.role);!known {
            api.call_fail(call,api.INVALID_PARAMS,"role is reader, writer, admin or node")
            return
        }
    }
    if message:=kai_agent_start(s);message!="" {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    addresses:=make([dynamic]string,call.allocator)
    at:=strings.trim_space(p.at)
    reach:vcs.Reach
    via_server:=false
    text:string
    e:vcs.Error
    if at!="" {
        append(&addresses,strings.clone(at,call.allocator))
        append(&addresses,..vcs.agent_addresses(&k.agent,call.allocator))
        text,e=vcs.team_invite(t,org,role,p.mine?t.name:"",addresses[:],call.allocator)
    } else {
        _,srv_addr,has_server:=vcs.team_org_server(t,org)
        if !has_server {
            // Asked as the agent starts, a direct invite waits for the router's address.
            reach=vcs.agent_reach_wait(&k.agent,KAI_REACH_WAIT)
        }
        append(&addresses,..vcs.agent_addresses(&k.agent,call.allocator))
        text,via_server,e=vcs.agent_invite(&k.agent,org,role,p.mine?t.name:"",addresses[:],call.allocator)
        if e!=.None && t.why=="" {t.why=k.agent.team.why}
        if via_server {
            clear(&addresses)
            append(&addresses,strings.clone(srv_addr,call.allocator))
        } else if has_server && e==.None {
            reach,_=vcs.agent_reach(&k.agent,context.temp_allocator)
        }
    }
    if e!=.None {
        api_kai_why(call,t,e)
        return
    }
    k.invite_length=copy(k.invite[:],text)
    k.invite_org,k.invite_local,k.invite_via_server,k.invite_copied=org,!via_server && at=="" && reach!=.Online,via_server,false
    k.invite_role,k.invite_mine=role,p.mine
    k.invite_seq+=1
    role_title:=role==.Admin?"Admin":role==.Reader?"Reader":"Writer"
    mine_note:=p.mine?" (your machine)":""
    #assert(vcs.INVITE_HOURS==72)
    tail:="valid 3 days — works even while Mirai is closed." if k.invite_via_server else ("local network only — add a public host:port above to invite over the internet." if k.invite_local else "valid 3 days while Mirai is open.")
    meta:=fmt.tprintf("%s invite%s · #%d · %s",role_title,mine_note,k.invite_seq,tail)
    k.invite_meta_length=copy(k.invite_meta[:],meta)
    if asked && kai_invite_copy(s) {notify(s,fmt.tprintf("%s invite%s copied to clipboard",role_title,mine_note))}
    r:=api.call_result(call,Api_Kai_Invite)
    r.invite,r.addresses=text,addresses[:]
}

@(private)
api_kai_join :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Join_Params)
    t:=api_kai_team(s,call)
    if t==nil {return}
    k:=s.kai.team
    if invite:=strings.trim_space(p.invite);invite!="" {
        if _,e:=vcs.invite_parse(invite,context.temp_allocator);e!=.None {
            api.call_fail(call,api.INVALID_PARAMS,"that is no Kai invite: copy all of it, it begins with kai2")
            return
        }
        if t.name=="" {
            api.call_fail(call,api.INVALID_PARAMS,"name yourself and this machine first: kai.profile")
            return
        }
        if message:=kai_task_start(s,.Join,invite);message!="" {
            api.call_fail(call,api.SERVER_ERROR,message)
            return
        }
    }
    x:=&k.tasks[.Join]
    r:=api.call_result(call,Api_Kai_Joined)
    r.stage,r.why=api_kai_task_state(x,call)
    if x.stage==.Done {
        o,_,_:=vcs.team_org(t,x.org)
        r.org=strings.clone(org_hex(x.org),call.allocator)
        r.name=strings.clone(o.name,call.allocator)
    }
}

// A task's stage and why, as its methods say them.
@(private)
api_kai_task_state :: proc(x:^Kai_Task,call:^api.Call) -> (stage,why:string) {
    STAGES :: [Kai_Clone_Stage]string{.None="none",.Waiting="waiting",.Done="done",.Failed="failed"}
    stages:=STAGES
    if x.stage==.Failed {why=strings.clone(string(x.why[:x.why_length]),call.allocator)}
    return stages[x.stage],why
}

@(private)
api_kai_publish :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Publish_Params)
    t:=api_kai_team(s,call)
    if t==nil {return}
    st:=s.kai.state
    if st==nil {
        api.call_fail(call,api.SERVER_ERROR,kai_missing(s))
        return
    }
    if p.visibility!="" && p.visibility!="public" && p.visibility!="org" {
        api.call_fail(call,api.INVALID_PARAMS,"visibility is public or org")
        return
    }
    _,linked:=vcs.team_link_of(t,st.project.workspace.repo.id)
    if !linked {
        if p.org=="" {
            api.call_fail(call,api.INVALID_PARAMS,"the project is in no org yet: give org, and visibility public or org")
            return
        }
    } else if p.org!="" || p.visibility!="" {
        api.call_fail(call,api.INVALID_PARAMS,"the project is in an org already: org and visibility go with its first publish")
        return
    }
    // Whatever may refuse goes before the org's record lists the repository.
    bookmark:=p.bookmark!=""?p.bookmark:ka.BOOKMARK_DEFAULT
    if !vcs.bookmark_name_valid(bookmark) {
        api.call_failf(call,api.INVALID_PARAMS,"%q is no bookmark name",bookmark)
        return
    }
    org:vcs.Org_Id
    if !linked {
        ok:bool
        if org,ok=api_kai_org_find(s,call,t,p.org);!ok {return}
        o,_,_:=vcs.team_org(t,org)
        if role,member:=vcs.org_role(&o,t.identity.key);!member || role<.Writer {
            api.call_fail(call,api.INVALID_PARAMS,"a reader of that org publishes nothing: an admin makes you a writer")
            return
        }
    }
    if _,message:=kai_prepare(s);message!="" {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    if !linked {
        if _,e:=ka.project_join(&st.project,t,org,p.visibility=="public");e!=.None {
            api_kai_why(call,t,e)
            return
        }
    }
    changed:=make([dynamic]string,context.temp_allocator)
    revision,e:=ka.publish(&st.project,t,bookmark,strings.trim_space(p.description),&changed)
    kai_wrote(s,changed[:])
    if e!=.None {
        kai_team_wrote(s)
        api_kai_why(call,t,e)
        return
    }
    // The description went into the change: the field is clear only now.
    st.description_length=0
    kai_team_wrote(s)
    r:=api.call_result(call,Api_Kai_Published)
    r.change=api_kai_text(&st.project.workspace,revision,call)
    r.bookmark=strings.clone(bookmark,call.allocator)
    l,_:=vcs.team_link_of(t,st.project.workspace.repo.id)
    warned:=false
    if o,_,oe:=vcs.team_org(t,l.org);oe==.None {
        if i:=vcs.org_repo(&o,l.repo);i>=0 && o.repos[i].public {
            secrets:=ka.secret_paths(&st.project,revision)
            r.secrets=make([]string,len(secrets),call.allocator)
            for x,k in secrets {r.secrets[k]=strings.clone(x,call.allocator)}
            if len(secrets)>0 {
                warned=true
                notify(s,strings.concatenate({"Kai: this public repository shows files named like secrets: ",strings.join(secrets,", ",context.temp_allocator)},context.temp_allocator))
            }
        }
    }
    if !warned {notify(s,fmt.tprintf("Published %s to %s",r.change[:min(len(r.change),8)],bookmark))}
}

@(private)
api_kai_clone :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Clone_Params)
    t:=api_kai_team(s,call)
    if t==nil {return}
    k:=s.kai.team
    if p.cancel {
        kai_clone_cancel(s)
    } else if p.org!="" || p.repository!="" {
        org,ok:=api_kai_org_find(s,call,t,p.org)
        if !ok {return}
        o,_,_:=vcs.team_org(t,org)
        repo:=-1
        for x,i in o.repos {
            id:=x.id
            if x.name==p.repository || (len(p.repository)>=4 && strings.has_prefix(ka.hex(id[:]),strings.to_lower(p.repository,context.temp_allocator))) {repo=i}
        }
        if repo<0 {
            api.call_failf(call,api.INVALID_PARAMS,"%q names no repository of %s: kai.org lists them",p.repository,o.name)
            return
        }
        folder:=p.folder!=""?p.folder:kai_clone_folder(s,org,o.repos[repo].id,o.repos[repo].name)
        if message:=kai_clone_start(s,org,o.repos[repo].id,o.repos[repo].name,folder);message!="" {
            api.call_fail(call,api.SERVER_ERROR,message)
            return
        }
    }
    r:=api.call_result(call,Api_Kai_Clone)
    c:=&k.clone
    STAGES :: [Kai_Clone_Stage]string{.None="none",.Waiting="waiting",.Done="done",.Failed="failed"}
    stages:=STAGES
    r.stage=stages[c.stage]
    r.why=strings.clone(string(c.why[:c.why_length]),call.allocator)
    r.folder=strings.clone(string(c.folder[:c.folder_length]),call.allocator)
    r.chunks,r.bytes=kai_clone_progress(k)
}

@(private)
api_kai_peers :: proc(s:^Session,call:^api.Call) {
    if api_kai_team(s,call)==nil {return}
    k:=s.kai.team
    kai_team_read(s)
    r:=api.call_result(call,Api_Kai_Peers)
    r.running=k.running
    if k.running {r.port=vcs.agent_port(&k.agent)}
    r.addresses=make([]string,len(k.view.addresses),call.allocator)
    for a,i in k.view.addresses {r.addresses[i]=strings.clone(a,call.allocator)}
    r.peers=make([]Api_Kai_Peer,len(k.view.peers),call.allocator)
    for x,i in k.view.peers {r.peers[i]={strings.clone(x.name,call.allocator),strings.clone(x.device,call.allocator),strings.clone(x.address,call.allocator)}}
    r.pulls=make([]Api_Kai_Pull,len(k.view.pulls),call.allocator)
    for x,i in k.view.pulls {
        name:=""
        for o in k.view.orgs {
            for repo in o.repos {if repo.id==x.repo {name=repo.name}}
        }
        r.pulls[i]={strings.clone(name,call.allocator),x.chunks,x.left,x.bytes,x.whole}
    }
}

@(private)
api_kai_web_login :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Kai_Web_Login_Params)
    if api_kai_team(s,call)==nil {return}
    if p.server!="" || p.name!="" || p.password!="" {
        server,name:=strings.trim_space(p.server),strings.trim_space(p.name)
        if server=="" || name=="" || len(p.password)<8 || len(p.password)>256 {
            api.call_fail(call,api.INVALID_PARAMS,"give server, name and a password of 8 to 256 bytes")
            return
        }
        if message:=kai_task_start(s,.Web_Login,server,name,p.password);message!="" {
            api.call_fail(call,api.SERVER_ERROR,message)
            return
        }
    }
    r:=api.call_result(call,Api_Kai_Task)
    r.stage,r.why=api_kai_task_state(&s.kai.team.tasks[.Web_Login],call)
}

// The names of the shared bookmarks that point at revision, apart by commas, in allocator.
kai_shared_names :: proc(s:^Session,revision:vcs.Revision,allocator:=context.temp_allocator) -> string {
    if s.kai==nil || s.kai.team==nil {return ""}
    names:=make([dynamic]string,context.temp_allocator)
    for b in s.kai.team.view.shared {
        if b.target==revision {append(&names,b.name)}
    }
    return strings.join(names[:],", ",allocator)
}

// What kai.bookmarks lists of the project: its shared bookmarks after the
// workspace's own.
@(private)
api_kai_shared :: proc(s:^Session,call:^api.Call,out:^[dynamic]Api_Kai_Bookmark) {
    w:=kai_workspace(s)
    if s.kai.team==nil {return}
    for b in s.kai.team.view.shared {
        x:=Api_Kai_Bookmark{name=strings.clone(b.name,call.allocator),shared=true,here=b.here}
        if b.here {x.change=api_kai_text(w,b.target,call)}
        append(out,x)
    }
}

// Moves a shared bookmark of the project for kai.bookmarks: false when the call failed.
@(private)
api_kai_bookmark_team :: proc(s:^Session,call:^api.Call,p:^Api_Kai_Bookmarks_Params) -> bool {
    if p.move=="" {return true}
    if !vcs.bookmark_name_valid(p.move) {
        api.call_failf(call,api.INVALID_PARAMS,"%q is no bookmark name: letters, digits, - _ . and / of at most %d bytes",p.move,vcs.BOOKMARK_NAME_MAX)
        return false
    }
    t:=api_kai_team(s,call)
    if t==nil {return false}
    w,message:=kai_prepare(s)
    if w==nil {
        api.call_fail(call,api.SERVER_ERROR,message)
        return false
    }
    revision,e:=ka.revision_resolve(&s.kai.state.project,t,p.change!=""?p.change:"@")
    if e!=.None {
        api.call_failf(call,api.INVALID_PARAMS,"%q names no single change: @, @-, a bookmark or a prefix of at least %d digits of a change id",p.change,ka.CHANGE_TEXT_MIN)
        return false
    }
    if e=ka.bookmark_move(&s.kai.state.project,t,p.move,revision);e!=.None {
        api_kai_why(call,t,e)
        return false
    }
    kai_team_wrote(s)
    return true
}
