package hub

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:kai"
import "mirai:std/base"
import "mirai:store"

@(private="file")
Machine :: struct {
    s:store.Store,
    team:kai.Team,
    agent:kai.Agent,
    running:bool,
}

@(private="file")
machine_open :: proc(t:^testing.T,m:^Machine,folder,name:string) -> bool {
    e:store.Error
    m.s,e=store.open(strings.concatenate({folder,"/",name},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return false}
    if !testing.expect_value(t,kai.team_open(&m.team,&m.s),kai.Error.None) {return false}
    return testing.expect_value(t,kai.team_profile_set(&m.team,name,"laptop"),kai.Error.None)
}

@(private="file")
machine_close :: proc(m:^Machine) {
    if m.running {kai.agent_stop(&m.agent)}
    m.running=false
    kai.team_close(&m.team)
    store.close(&m.s)
}

@(private="file")
until :: proc(seconds:f64,data:rawptr,done:proc(data:rawptr) -> bool) -> bool {
    started:=time.tick_now()
    for time.duration_seconds(time.tick_since(started))<seconds {
        if done(data) {return true}
        time.sleep(10*time.Millisecond)
    }
    return done(data)
}

// One HTTP request to the web view; the status, the headers and the body.
@(private="file")
http :: proc(port:int,method,path:string,body:="",cookie:="") -> (status:int,head,text:string) {
    socket,e:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,port)
    if e!=nil {return}
    defer net.close(socket)
    request:=fmt.tprintf("%s %s HTTP/1.1\r\nHost: kai\r\nConnection: close\r\n%s%s\r\n%s",method,path,
        cookie!=""?fmt.tprintf("Cookie: %s\r\n",cookie):"",
        method=="POST"?fmt.tprintf("Content-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n",len(body)):"",body)
    net.send_tcp(socket,transmute([]u8)request)
    reply:=make([dynamic]u8,context.temp_allocator)
    buffer:[16<<10]u8
    for {
        n,re:=net.recv_tcp(socket,buffer[:])
        if re!=nil || n<=0 {break}
        append(&reply,..buffer[:n])
    }
    all:=string(reply[:])
    end:=strings.index(all,"\r\n\r\n")
    if end<0 || len(all)<12 {return}
    status=int(all[9]-'0')*100+int(all[10]-'0')*10+int(all[11]-'0')
    return status,all[:end],all[end+4:]
}

@(private="file")
cookie_of :: proc(head:string) -> string {
    at:=strings.index(head,"Set-Cookie: ")
    if at<0 {return ""}
    rest:=head[at+len("Set-Cookie: "):]
    return rest[:strings.index_byte(rest,';')]
}

@(private="file")
change_of :: proc(t:^testing.T,s:^store.Store,identity:^kai.Identity,files:[][2]string) -> kai.Revision {
    list:=make([dynamic]kai.File,context.temp_allocator)
    for f in files {
        address,_:=store.put(s,transmute([]u8)f[1])
        append(&list,kai.File{path=f[0],kind=.File,address=address,size=u64(len(f[1]))})
    }
    slice.sort_by(list[:],proc(a,b:kai.File) -> bool {return a.path<b.path})
    tree,_:=kai.tree_build(s,list[:])
    c:=kai.Change{id=kai.random_id(kai.Change_Id),tree=tree,author=identity.key,created=1,written=1,description="the lighthouse <b>keeper</b>"}
    revision,e:=kai.change_put(s,&c,identity)
    testing.expect_value(t,e,kai.Error.None)
    store.commit(s)
    return revision
}

// A server joined to an org keeps its repositories whole: a member pulls from
// it while the machine that published is off. Its web view shows a public
// repository to anyone and a private one only to a member signed in with the
// name and password it set from its device; the org's members show only to
// members; a change of another repository, a path outside the tree or a
// forged cookie get nothing; each org lives in a folder of its own.
@(test)
a_server_keeps_an_org_and_its_web_view_shows_what_each_one_may_see :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hub")
    if folder=="" {return}
    mac,pc:Machine
    if !machine_open(t,&mac,folder,"ana") || !machine_open(t,&pc,folder,"ben") {return}
    defer machine_close(&mac)
    defer machine_close(&pc)
    org,_:=kai.team_org_create(&mac.team,"studio")
    other,_:=kai.team_org_create(&mac.team,"secret studio")
    public,private:=kai.random_id(kai.Repo_Id),kai.random_id(kai.Repo_Id)
    kai.team_repo_set(&mac.team,org,{id=public,name="lighthouse",public=true})
    kai.team_repo_set(&mac.team,org,{id=private,name="vault"})
    files:=[][2]string{{"readme.txt","<script>alert(1)</script>\n"},{"assets/a.bin","\x00\x01\x02"}}
    revision:=change_of(t,&mac.s,&mac.team.identity,files)
    hidden:=change_of(t,&mac.s,&mac.team.identity,{{"plan.txt","the hidden plan\n"}})
    kai.team_publish(&mac.team,org,public,{{"main",revision}})
    kai.team_publish(&mac.team,org,private,{{"main",hidden}})
    if !testing.expect_value(t,kai.agent_start(&mac.agent,&mac.team,{port=0,host="127.0.0.1"}),kai.Error.None) {return}
    mac.running=true
    if !testing.expect_value(t,kai.agent_start(&pc.agent,&pc.team,{port=-1}),kai.Error.None) {return}
    pc.running=true
    mac_address:=fmt.tprintf("127.0.0.1:%d",kai.agent_port(&mac.agent))

    h:Hub
    why,ok:=hub_start(&h,{root=strings.concatenate({folder,"/server"},context.temp_allocator),port=0,http="127.0.0.1:0",name="cloud"})
    if !testing.expectf(t,ok,"the server starts: %s",why) {return}
    hub_stopped:=false
    defer if !hub_stopped {hub_stop(&h)}
    node_invite,_:=kai.team_invite(&mac.team,org,.Node,"",{mac_address},context.temp_allocator)
    if _,je:=kai.agent_join(&h.agent,node_invite);!testing.expectf(t,je==.None,"the server joins: %s",h.agent.team.why) {return}
    testing.expect(t,os.is_dir(fmt.tprintf("%s/server/orgs/%s",folder,id_text(org))),"the org has a folder of its own")
    testing.expect(t,!os.exists(fmt.tprintf("%s/server/orgs/%s",folder,id_text(other))),"an org it did not join has none")
    pc_invite,_:=kai.team_invite(&mac.team,org,.Writer,"",{mac_address},context.temp_allocator)
    if _,je:=kai.agent_join(&pc.agent,pc_invite);!testing.expect_value(t,je,kai.Error.None) {return}

    // The server holds every repository whole.
    Held :: struct {h:^Hub,org:kai.Org_Id,revisions:[2]kai.Revision}
    held:=Held{&h,org,{revision,hidden}}
    whole:=until(20,&held,proc(data:rawptr) -> bool {
        x:=(^Held)(data)
        s,_:=kai.team_store(&x.h.team,x.org)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        kai.closure_walk(s,x.revisions[:],nil,&missing)
        return len(missing)==0 && kai.object_kind(s,x.revisions[0])==.Change
    })
    if !testing.expect(t,whole,"the server keeps the org's repositories whole") {return}

    // The publisher goes off; the PC pulls from the server, whose address the org's record names.
    o,_,_:=kai.team_org(&pc.team,org)
    server_listed:=false
    for m in o.members {server_listed||=m.role==.Node}
    testing.expect(t,server_listed,"the org lists the server")
    kai.agent_stop(&mac.agent)
    mac.running=false
    _=kai.team_link(&pc.team,{local=kai.random_id(kai.Repo_Id),org=org,repo=public})
    kai.agent_changed(&pc.agent)
    pulled:=Held{nil,org,{revision,revision}}
    Pc :: struct {s:^store.Store,revision:kai.Revision}
    at_pc:=Pc{&pc.s,revision}
    came:=until(30,&at_pc,proc(data:rawptr) -> bool {
        x:=(^Pc)(data)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        kai.closure_walk(x.s,{x.revision},nil,&missing)
        return len(missing)==0 && kai.object_kind(x.s,x.revision)==.Change
    })
    _=pulled
    testing.expect(t,came,"the PC pulls the repository from the server while the publisher is off")

    // The web view.
    port:=h.port
    status,_,text:=http(port,"GET","/")
    testing.expect(t,status==200 && strings.contains(text,"lighthouse") && !strings.contains(text,"vault"),"the home page shows the public repository to anyone")
    status,_,_=http(port,"GET",fmt.tprintf("/%s/%s",id_text(org),id_text(private)))
    testing.expect_value(t,status,404)
    status,_,text=http(port,"GET",fmt.tprintf("/%s",id_text(org)))
    testing.expect(t,status==200 && !strings.contains(text,"Members"),"an anonymous visitor sees no members")
    base_path:=fmt.tprintf("/%s/%s",id_text(org),id_text(public))
    status,_,text=http(port,"GET",fmt.tprintf("%s/t/%s/readme.txt",base_path,id_text(revision)))
    testing.expect(t,status==200 && strings.contains(text,"&lt;script&gt;") && !strings.contains(text,"<script>"),"a file shows escaped")
    status,_,_=http(port,"GET",fmt.tprintf("%s/c/%s",base_path,id_text(hidden)))
    testing.expect_value(t,status,404)
    status,_,_=http(port,"GET",fmt.tprintf("%s/t/%s/../plan.txt",base_path,id_text(revision)))
    testing.expect_value(t,status,404)
    status,_,_=http(port,"GET","/",cookie="kai=0000000000000000000000000000000000000000000000000000000000000000")
    testing.expect_value(t,status,200)

    // Sign in as the PC, with the name it set from its device.
    testing.expect(t,account_set(&h,pc.team.identity.key,"ben","correct horse"),"a member sets its sign-in")
    testing.expect(t,!account_set(&h,mac.team.identity.key,"ben","another one"),"a name is its device's")
    status,_,_=http(port,"POST","/login","name=ben&password=wrong+horse")
    testing.expect_value(t,status,401)
    head:string
    status,head,_=http(port,"POST","/login","name=ben&password=correct+horse")
    cookie:=cookie_of(head)
    testing.expect(t,status==303 && strings.has_prefix(cookie,"kai=") && strings.contains(head,"HttpOnly"),"a right password gives a session cookie")
    status,_,text=http(port,"GET",fmt.tprintf("/%s",id_text(org)),cookie=cookie)
    testing.expect(t,status==200 && strings.contains(text,"Members") && strings.contains(text,"vault"),"a member sees the members and the private repository")
    status,_,text=http(port,"GET",fmt.tprintf("/%s/%s/t/%s/plan.txt",id_text(org),id_text(private),id_text(hidden)),cookie=cookie)
    testing.expect(t,status==200 && strings.contains(text,"the hidden plan"),"a member reads a private file")
    status,_,text=http(port,"GET",base_path,cookie=cookie)
    testing.expect(t,status==200 && strings.contains(text,"&lt;b&gt;keeper") && strings.contains(text,"ana (laptop)"),"the history names the author and escapes the description")
    status,_,_=http(port,"POST","/logout","",cookie=cookie)
    testing.expect_value(t,status,303)
    status,_,text=http(port,"GET",fmt.tprintf("/%s",id_text(org)),cookie=cookie)
    testing.expect(t,status==200 && !strings.contains(text,"Members"),"a closed session sees what anyone sees")
    hub_stop(&h)
    hub_stopped=true
}

// The parser refuses what two readers of one stream could read apart, and
// what is past its bounds.
@(test)
hub_http_refuses_hostile_requests :: proc(t:^testing.T) {
    Case :: struct {text:string,status:int}
    cases:=[]Case{
        {"GET / HTTP/1.1\r\nHost: a\r\n\r\n",200},
        {"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",400},
        {"GET / HTTP/1.1\r\n\r\n",400},
        {"POST /login HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n",501},
        {"POST /login HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",400},
        {"POST /login HTTP/1.1\r\nHost: a\r\nContent-Length: 999999\r\n\r\n",413},
        {"POST /login HTTP/1.1\r\nHost: a\r\n\r\n",411},
        {"GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n",400},
        {"GET / HTTP/1.1\nHost: a\n\n",400},
        {"GET /\x01 HTTP/1.1\r\nHost: a\r\n\r\n",400},
        {"BREW / HTTP/1.1\r\nHost: a\r\n\r\n",501},
        {"GET / HTTP/2.0\r\nHost: a\r\n\r\n",505},
        {"GET relative HTTP/1.1\r\nHost: a\r\n\r\n",400},
    }
    for c in cases {
        p:=request_parse(transmute([]u8)c.text)
        testing.expectf(t,p.status==c.status,"%q: %d, not %d",c.text,p.status,c.status)
    }
    testing.expect_value(t,form_value(transmute([]u8)string("a=1&name=b%2Fc+d"),"name"),"b/c d")
    testing.expect_value(t,form_value(transmute([]u8)string("name=%zz"),"name"),"")
    testing.expect(t,!account_name_valid("Ben") && !account_name_valid("") && account_name_valid("ben.k-1"),"account names are lowercase")
}
