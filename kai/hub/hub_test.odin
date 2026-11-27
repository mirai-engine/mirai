package hub

import "core:crypto"
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

// A change of files; size, when not negative, is what every entry says it holds.
@(private="file")
change_of :: proc(t:^testing.T,s:^store.Store,identity:^kai.Identity,files:[][2]string,size:=-1) -> kai.Revision {
    list:=make([dynamic]kai.File,context.temp_allocator)
    for f in files {
        address,_:=store.put(s,transmute([]u8)f[1])
        append(&list,kai.File{path=f[0],kind=.File,address=address,size=u64(size>=0?size:len(f[1]))})
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
    why,ok:=hub_start(&h,{root=strings.concatenate({folder,"/server"},context.temp_allocator),host="127.0.0.1",port=0,http="127.0.0.1:0",name="cloud"})
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
    // The head's bound holds its blank line: the largest head and body fit
    // HEAD_MAX+BODY_MAX, the connection's input.
    start:=fmt.tprintf("POST /login HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\nX: ",BODY_MAX)
    pad:=HEAD_MAX-len(start)-4
    largest:=strings.concatenate({start,strings.repeat("p",pad,context.temp_allocator),"\r\n\r\n",strings.repeat("b",BODY_MAX,context.temp_allocator)},context.temp_allocator)
    testing.expect_value(t,len(largest),HEAD_MAX+BODY_MAX)
    testing.expect_value(t,request_parse(transmute([]u8)largest).status,200)
    longer:=strings.concatenate({start,strings.repeat("p",pad+1,context.temp_allocator),"\r\n\r\n"},context.temp_allocator)
    testing.expect_value(t,request_parse(transmute([]u8)longer).status,431)
    testing.expect_value(t,form_value(transmute([]u8)string("a=1&name=b%2Fc+d"),"name"),"b/c d")
    testing.expect_value(t,form_value(transmute([]u8)string("name=%zz"),"name"),"")
    testing.expect(t,!account_name_valid("Ben") && !account_name_valid("") && account_name_valid("ben.k-1"),"account names are lowercase")
}

// A web view without its agent or listener: the server's store and team, and
// the stores of its orgs under folder when tenants.
@(private="file")
bench_open :: proc(t:^testing.T,h:^Hub,folder:string,tenants:bool) -> bool {
    h^={allocator=context.allocator}
    h.sessions=make(map[[32]u8]Session)
    e:store.Error
    h.s,e=store.open(strings.concatenate({folder,"/server"},context.temp_allocator))
    if !testing.expect_value(t,e,store.Error.None) {return false}
    if !testing.expect_value(t,kai.team_open(&h.team,&h.s),kai.Error.None) {return false}
    if tenants {
        if !testing.expect_value(t,kai.tenants_init(&h.tenants,folder),kai.Error.None) {return false}
        h.team.tenants=&h.tenants
    }
    return testing.expect_value(t,kai.team_profile_set(&h.team,"ana","cloud"),kai.Error.None)
}

// What the web view answers to one request.
@(private="file")
ask :: proc(h:^Hub,text:string) -> Out {
    p:=request_parse(transmute([]u8)text)
    out:=Out{body=make([dynamic]u8,context.temp_allocator),headers=make([dynamic]u8,context.temp_allocator)}
    if p.status!=200 {
        out.status=p.status
        return out
    }
    page(h,&p.request,&out)
    if out.status==0 {out.status=200}
    return out
}

// A link names a file percent-encoded and opens it; an escape that is
// malformed or names a '/' or a NUL opens nothing. A file shows by its
// object's size, not the size its tree entry claims. A browser's POST from
// another site is refused before it signs in or out.
@(test)
the_web_view_opens_what_its_links_name_and_refuses_cross_site_posts :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hub-pages")
    if folder=="" {return}
    h:Hub
    defer hub_free(&h)
    if !bench_open(t,&h,folder,false) {return}
    org,oe:=kai.team_org_create(&h.team,"studio")
    if !testing.expect_value(t,oe,kai.Error.None) {return}
    repo:=kai.random_id(kai.Repo_Id)
    kai.team_repo_set(&h.team,org,{id=repo,name="lighthouse",public=true})
    big:=strings.repeat("x",FILE_SHOWN_MAX+1,context.temp_allocator)
    revision:=change_of(t,&h.s,&h.team.identity,{{"a b/\u00e9.txt","spaced and accented\n"},{"big.txt",big}},size=1)
    testing.expect_value(t,kai.team_publish(&h.team,org,repo,{{"main",revision}}),kai.Error.None)
    files:=fmt.tprintf("/%s/%s/t/%s",id_text(org),id_text(repo),id_text(revision))
    Case :: struct {request:string,status:int,shows,hides:string}
    get:=proc(path:string,extra:="") -> string {return fmt.tprintf("GET %s HTTP/1.1\r\nHost: kai\r\n%s\r\n",path,extra)}
    post:=proc(path,extra:string) -> string {
        body:="name=ben&password=wrong+horse"
        return fmt.tprintf("POST %s HTTP/1.1\r\nHost: kai\r\n%sContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n%s",path,extra,len(body),body)
    }
    cases:=[]Case{
        {get(fmt.tprintf("%s/a%%20b/%%C3%%A9.txt",files)),200,"spaced and accented",""},
        {get(fmt.tprintf("%s/a%%20b",files)),200,"a%20b/%C3%A9.txt",""},
        {get(fmt.tprintf("%s/a%%2Fb",files)),404,"",""},
        {get(fmt.tprintf("%s/a%%00",files)),404,"",""},
        {get(fmt.tprintf("%s/a%%2",files)),404,"",""},
        {get(fmt.tprintf("%s/a%%zzb",files)),404,"",""},
        {get(fmt.tprintf("%s/big.txt",files)),200,"too large","xxxxxxxx"},
        {post("/login","Origin: https://evil.example\r\n"),403,"",""},
        {post("/login","Origin: null\r\n"),403,"",""},
        {post("/login","Sec-Fetch-Site: cross-site\r\n"),403,"",""},
        {post("/logout","Sec-Fetch-Site: same-site\r\n"),403,"",""},
        {post("/login","Origin: http://kai\r\nSec-Fetch-Site: same-origin\r\n"),401,"",""},
        {post("/login","Origin: https://kai.example\r\nX-Forwarded-Host: kai.example\r\n"),401,"",""},
        {post("/login",""),401,"",""},
    }
    for c in cases {
        out:=ask(&h,c.request)
        text:=string(out.body[:])
        testing.expectf(t,out.status==c.status,"%q: %d, not %d",c.request,out.status,c.status)
        if c.shows!="" {testing.expectf(t,strings.contains(text,c.shows),"%q shows %q",c.request,c.shows)}
        if c.hides!="" {testing.expectf(t,!strings.contains(text,c.hides),"%q hides %q",c.request,c.hides)}
    }
}

// Setting a password ends the device's sessions; a sign-in while as many
// passwords derive as the server allows is told to come back; the sessions
// held stay at SESSIONS_MAX.
@(test)
web_accounts_bound_what_a_crowd_of_sign_ins_takes :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hub-accounts")
    if folder=="" {return}
    h:Hub
    defer hub_free(&h)
    if !bench_open(t,&h,folder,false) {return}
    key:=h.team.identity.key
    if !testing.expect(t,account_set(&h,key,"ben","correct horse"),"a member sets its sign-in") {return}
    token,result:=session_open(&h,"ben","correct horse")
    if !testing.expect_value(t,result,Sign_In.Signed) {return}
    hex:[64]u8
    cookie:=fmt.tprintf("GET / HTTP/1.1\r\nHost: kai\r\nCookie: kai=%s\r\n\r\n",hex_text(token[:],hex[:]))
    p:=request_parse(transmute([]u8)cookie)
    _,_,signed:=session_of(&h,&p.request)
    testing.expect(t,signed,"the session signs in")

    h.derivations=DERIVATIONS_MAX
    body:="name=ben&password=correct+horse"
    out:=ask(&h,fmt.tprintf("POST /login HTTP/1.1\r\nHost: kai\r\nContent-Length: %d\r\n\r\n%s",len(body),body))
    testing.expect_value(t,out.status,503)
    testing.expect(t,strings.contains(string(out.headers[:]),"Retry-After: "),"a busy sign-in says when to come back")
    testing.expect(t,!account_set(&h,key,"ben","another horse"),"a password does not derive while the server is busy")
    h.derivations=0

    testing.expect(t,account_set(&h,key,"ben","another horse"),"the member changes its password")
    _,_,signed=session_of(&h,&p.request)
    testing.expect(t,!signed,"a password changed ends the device's sessions")

    now:=time.now()._nsec
    for k in 0..<SESSIONS_MAX {
        filler:[32]u8
        filler[0],filler[1],filler[31]=u8(k),u8(k>>8),0xff
        h.sessions[filler]=Session{key=key,expires=now+i64(k+1)*i64(time.Second)}
    }
    _,result=session_open(&h,"ben","another horse")
    testing.expect_value(t,result,Sign_In.Signed)
    testing.expect_value(t,len(h.sessions),SESSIONS_MAX)
    oldest:[32]u8
    oldest[31]=0xff
    _,kept:=h.sessions[oldest]
    testing.expect(t,!kept,"the oldest session ends first")
}

// An org id a stranger names on a server of several orgs makes no folder and
// opens no store.
@(test)
an_unknown_org_makes_nothing_on_a_server :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hub-tenants")
    if folder=="" {return}
    h:Hub
    defer hub_free(&h)
    if !bench_open(t,&h,folder,true) {return}
    for _ in 0..<3 {
        org:=kai.random_id(kai.Org_Id)
        out:=ask(&h,fmt.tprintf("GET /%s HTTP/1.1\r\nHost: kai\r\n\r\n",id_text(org)))
        testing.expect_value(t,out.status,404)
        out=ask(&h,fmt.tprintf("GET /%s/%s HTTP/1.1\r\nHost: kai\r\n\r\n",id_text(org),id_text(kai.random_id(kai.Repo_Id))))
        testing.expect_value(t,out.status,404)
        testing.expect(t,!os.exists(fmt.tprintf("%s/orgs/%s",folder,id_text(org))),"no folder for an org id a request names")
    }
    testing.expect_value(t,ask(&h,"GET / HTTP/1.1\r\nHost: kai\r\n\r\n").status,200)
    testing.expect_value(t,len(h.tenants.stores),0)
}

// A client that expects 100 Continue gets it before it sends its body, and a
// client idle between requests does not hold the server's stop.
@(test)
the_web_view_answers_100_continue_and_stops_with_idle_clients :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hub-live")
    if folder=="" {return}
    h:Hub
    why,ok:=hub_start(&h,{root=strings.concatenate({folder,"/server"},context.temp_allocator),port=-1,http="127.0.0.1:0",name="cloud"})
    if !testing.expectf(t,ok,"the server starts: %s",why) {return}
    stopped:=false
    defer if !stopped {hub_stop(&h)}

    socket,e:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,h.port)
    if !testing.expect(t,e==nil,"a client connects") {return}
    defer net.close(socket)
    net.set_option(socket,.Receive_Timeout,5*time.Second)
    body:="name=ben&password=wrong+horse"
    head:=fmt.tprintf("POST /login HTTP/1.1\r\nHost: kai\r\nExpect: 100-continue\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n",len(body))
    net.send_tcp(socket,transmute([]u8)head)
    buffer:[4096]u8
    n,re:=net.recv_tcp(socket,buffer[:])
    testing.expect(t,re==nil && strings.has_prefix(string(buffer[:max(n,0)]),"HTTP/1.1 100 Continue\r\n\r\n"),"the server asks for the body")
    net.send_tcp(socket,transmute([]u8)body)
    reply:=make([dynamic]u8,context.temp_allocator)
    for !strings.contains(string(reply[:]),"Unauthorized") {
        n,re=net.recv_tcp(socket,buffer[:])
        if re!=nil || n<=0 {break}
        append(&reply,..buffer[:n])
    }
    testing.expect(t,strings.contains(string(reply[:]),"HTTP/1.1 401"),"the body is answered")

    idle,de:=net.dial_tcp_from_address_and_port(net.IP4_Loopback,h.port)
    if !testing.expect(t,de==nil,"a second client connects") {return}
    defer net.close(idle)
    net.set_option(idle,.Receive_Timeout,5*time.Second)
    net.send_tcp(idle,transmute([]u8)string("GET /healthz HTTP/1.1\r\nHost: kai\r\n\r\n"))
    n,re=net.recv_tcp(idle,buffer[:])
    testing.expect(t,re==nil && strings.contains(string(buffer[:max(n,0)]),"ok"),"the idle client was served once")
    started:=time.tick_now()
    hub_stop(&h)
    stopped=true
    took:=time.tick_since(started)
    testing.expectf(t,took<time.Second,"the server stops in %v with clients idle",took)
}

// An admin registers an org on a server with zero manual --join, publishes a
// repo, creates an offline 1-use invite and stops completely. A writer joins
// through the server while the admin is off, pulls the repo whole, and sees
// the org on the web view. When the admin restarts later, it recognizes the
// writer and promotes the verified admission into the signed org record.
// Self-registration stops at --max-orgs.
@(test)
a_server_registers_an_org_and_admits_offline_invites :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hub-offline-invite")
    if folder=="" {return}
    mac,pc:Machine
    if !machine_open(t,&mac,folder,"ana") || !machine_open(t,&pc,folder,"ben") {return}
    defer machine_close(&mac)
    defer machine_close(&pc)

    h:Hub
    why,ok:=hub_start(&h,{root=strings.concatenate({folder,"/server"},context.temp_allocator),host="127.0.0.1",port=0,http="127.0.0.1:0",name="cloud",max_orgs=2})
    if !testing.expectf(t,ok,"the server starts: %s",why) {return}
    defer hub_stop(&h)
    server_addr:=fmt.tprintf("127.0.0.1:%d",kai.agent_port(&h.agent))

    if !testing.expect_value(t,kai.agent_start(&mac.agent,&mac.team,{port=0,host="127.0.0.1"}),kai.Error.None) {return}
    mac.running=true
    if !testing.expect_value(t,kai.agent_start(&pc.agent,&pc.team,{port=-1}),kai.Error.None) {return}
    pc.running=true

    org,oe:=kai.team_org_create(&mac.team,"studio")
    if !testing.expect_value(t,oe,kai.Error.None) {return}
    if !testing.expectf(t,kai.agent_server_attach(&mac.agent,org,server_addr)==.None,"admin attaches server: %s",mac.agent.team.why) {return}
    testing.expect(t,os.is_dir(fmt.tprintf("%s/server/orgs/%s",folder,id_text(org))),"server created org tenant store")
    srv_key,srv_addr,has_srv:=kai.team_org_server(&mac.team,org)
    testing.expect(t,has_srv && srv_key==h.team.identity.key && srv_addr==server_addr,"org lists server as Node")

    repo:=kai.random_id(kai.Repo_Id)
    kai.team_repo_set(&mac.team,org,{id=repo,name="game"})
    rev:=change_of(t,&mac.s,&mac.team.identity,{{"hello.txt","offline invite works\n"}})
    kai.team_publish(&mac.team,org,repo,{{"main",rev}})
    kai.agent_changed(&mac.agent)

    Held :: struct {h:^Hub,s:^store.Store,org:kai.Org_Id,rev:kai.Revision,key:kai.Key}
    held:=Held{h=&h,org=org,rev=rev}
    if !testing.expect(t,until(20,&held,proc(data:rawptr) -> bool {
        x:=(^Held)(data)
        s,e:=kai.team_store(&x.h.team,x.org)
        if e!=.None {return false}
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        kai.closure_walk(s,{x.rev},nil,&missing)
        return len(missing)==0 && kai.object_kind(s,x.rev)==.Change
    }),"server synced the repo before admin goes offline") {return}

    mac_addr:=fmt.tprintf("127.0.0.1:%d",kai.agent_port(&mac.agent))
    invite,via_server,ie:=kai.agent_invite(&mac.agent,org,.Writer,"",{mac_addr},context.temp_allocator)
    if !testing.expectf(t,ie==.None && via_server,"offline server invite created: %v %v %s",ie,via_server,mac.agent.team.why) {return}

    // Stop Admin completely: Writer joins and pulls while Admin is OFF.
    kai.agent_stop(&mac.agent)
    mac.running=false

    joined,je:=kai.agent_join(&pc.agent,invite)
    if !testing.expectf(t,je==.None && joined==org,"writer joins via server while admin is off: %v %s",je,pc.agent.team.why) {return}
    kai.team_link(&pc.team,{local=kai.random_id(kai.Repo_Id),org=org,repo=repo})
    kai.agent_changed(&pc.agent)
    pc_held:=Held{s=&pc.s,org=org,rev=rev}
    if !testing.expect(t,until(20,&pc_held,proc(data:rawptr) -> bool {
        x:=(^Held)(data)
        missing:=make([dynamic]store.Hash,context.temp_allocator)
        kai.closure_walk(x.s,{x.rev},nil,&missing)
        return len(missing)==0 && kai.object_kind(x.s,x.rev)==.Change
    }),"writer pulls the repo whole from server while admin is off") {return}

    // Web view recognizes the offline-admitted member too.
    testing.expect(t,account_set(&h,pc.team.identity.key,"ben","correct horse"),"offline-admitted member sets web sign-in")
    status,head,_:=http(h.port,"POST","/login","name=ben&password=correct+horse")
    cookie:=cookie_of(head)
    testing.expect(t,status==303 && cookie!="","offline-admitted member signs into web view")
    page_status,_,text:=http(h.port,"GET",fmt.tprintf("/%s",id_text(org)),cookie=cookie)
    testing.expect(t,page_status==200 && strings.contains(text,"Members") && strings.contains(text,"game"),"web view lists org members and private repo")

    // Admin restarts later: recognizes Writer and merges admission into signed Org record.
    if !testing.expect_value(t,kai.agent_start(&mac.agent,&mac.team,{port=0,host="127.0.0.1"}),kai.Error.None) {return}
    mac.running=true
    merged:=Held{s=&mac.s,org=org,key=pc.team.identity.key}
    testing.expect(t,until(20,&merged,proc(data:rawptr) -> bool {
        x:=(^Held)(data)
        raw,_,e:=kai.org_head(x.s,x.org,context.temp_allocator)
        if e!=.None {return false}
        role,ok:=kai.org_role(&raw,x.key)
        return ok && role==.Writer
    }),"admin restarts, recognizes writer and promotes admission into signed org record")

    // Self-registration respects --max-orgs (2).
    org2,_:=kai.team_org_create(&mac.team,"second")
    testing.expectf(t,kai.agent_server_attach(&mac.agent,org2,server_addr)==.None,"second org attaches within max_orgs: %s",mac.agent.team.why)
    org3,_:=kai.team_org_create(&mac.team,"third")
    testing.expect(t,kai.agent_server_attach(&mac.agent,org3,server_addr)!=.None,"third org refused past max_orgs")
    testing.expect(t,!os.exists(fmt.tprintf("%s/server/orgs/%s",folder,id_text(org3))),"refused org creates no tenant folder")
}

// Replayed 1-use invites, revoked grants, and forged or stale admissions
// (including a server attempting to sign a grant itself) are all refused.
@(test)
forged_replayed_or_revoked_offline_admissions_are_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"kai-hub-forged-admit")
    if folder=="" {return}
    mac,pc1,pc2:Machine
    if !machine_open(t,&mac,folder,"ana") || !machine_open(t,&pc1,folder,"ben") || !machine_open(t,&pc2,folder,"cal") {return}
    defer machine_close(&mac)
    defer machine_close(&pc1)
    defer machine_close(&pc2)

    h:Hub
    why,ok:=hub_start(&h,{root=strings.concatenate({folder,"/server"},context.temp_allocator),host="127.0.0.1",port=0,http="127.0.0.1:0",name="cloud",max_orgs=4})
    if !testing.expectf(t,ok,"the server starts: %s",why) {return}
    defer hub_stop(&h)
    server_addr:=fmt.tprintf("127.0.0.1:%d",kai.agent_port(&h.agent))

    if !testing.expect_value(t,kai.agent_start(&mac.agent,&mac.team,{port=0,host="127.0.0.1"}),kai.Error.None) {return}
    mac.running=true
    if !testing.expect_value(t,kai.agent_start(&pc1.agent,&pc1.team,{port=-1}),kai.Error.None) {return}
    pc1.running=true
    if !testing.expect_value(t,kai.agent_start(&pc2.agent,&pc2.team,{port=-1}),kai.Error.None) {return}
    pc2.running=true

    org,_:=kai.team_org_create(&mac.team,"studio")
    if !testing.expect_value(t,kai.agent_server_attach(&mac.agent,org,server_addr),kai.Error.None) {return}
    mac_addr:=fmt.tprintf("127.0.0.1:%d",kai.agent_port(&mac.agent))
    inv1,via1,e1:=kai.agent_invite(&mac.agent,org,.Writer,"",{mac_addr},context.temp_allocator)
    inv2,via2,e2:=kai.agent_invite(&mac.agent,org,.Writer,"",{mac_addr},context.temp_allocator)
    if !testing.expect(t,e1==.None && via1 && e2==.None && via2,"both offline invites created") {return}

    // First invite succeeds once; replay by a second device is refused.
    if _,je:=kai.agent_join(&pc1.agent,inv1);!testing.expect_value(t,je,kai.Error.None) {return}
    _,replay_err:=kai.agent_join(&pc2.agent,inv1)
    testing.expect_value(t,replay_err,kai.Error.Expired)

    // Revoking invites bumps revoke_epoch and drops inv2 on the server.
    _,rev_err:=kai.agent_invites_revoke(&mac.agent,org)
    testing.expect_value(t,rev_err,kai.Error.None)
    _,revoked_err:=kai.agent_join(&pc2.agent,inv2)
    testing.expect_value(t,revoked_err,kai.Error.Expired)

    // Direct cryptographic verification: a server, writer, stranger, tampered
    // signature, wrong secret, stale epoch, or duplicate claim cannot forge membership.
    writer:=kai.identity_make()
    stranger:=kai.identity_make()
    stranger2:=kai.identity_make()
    testing.expect_value(t,kai.team_member_set(&mac.team,org,{key=writer.key,role=.Writer,name="W",device="pc"}),kai.Error.None)
    org_rec,_,oe:=kai.org_head(&mac.s,org,context.temp_allocator)
    if !testing.expect(t,oe==.None && org_rec.revoke_epoch>=1,"org record has bumped revoke_epoch") {return}

    make_pair :: proc(t:^testing.T,org:kai.Org_Id,epoch:u64,signer,claimer:^kai.Identity,secret:[32]u8) -> (gb,cb:[]u8) {
        g:=kai.Invite_Grant{org=org,secret_hash=kai.secret_digest(secret),role=.Writer,revoke_epoch=epoch,expires=time.now()._nsec+i64(time.Hour),signer=signer.key}
        ge,ce:kai.Error
        gb,ge=kai.invite_grant_encode(&g,signer,context.temp_allocator)
        testing.expect_value(t,ge,kai.Error.None)
        c:=kai.Invite_Claim{org=org,secret=secret,key=claimer.key,name="Bob",device="box"}
        cb,ce=kai.invite_claim_encode(&c,claimer,context.temp_allocator)
        testing.expect_value(t,ce,kai.Error.None)
        return
    }

    secret,wrong_secret:[32]u8
    crypto.rand_bytes(secret[:])
    crypto.rand_bytes(wrong_secret[:])
    gb,cb:=make_pair(t,org,org_rec.revoke_epoch,&mac.team.identity,&stranger,secret)

    // Tampered grant or claim signature, or mismatched secret.
    bad_g:=slice.clone(gb,context.temp_allocator);bad_g[len(bad_g)-1]~=1
    _,eg:=kai.admission_encode(bad_g,cb,context.temp_allocator)
    testing.expect_value(t,eg,kai.Error.Corrupt)
    bad_c:=slice.clone(cb,context.temp_allocator);bad_c[len(bad_c)-1]~=1
    _,ec:=kai.admission_encode(gb,bad_c,context.temp_allocator)
    testing.expect_value(t,ec,kai.Error.Corrupt)
    _,wrong_cb:=make_pair(t,org,org_rec.revoke_epoch,&mac.team.identity,&stranger,wrong_secret)
    _,es:=kai.admission_encode(gb,wrong_cb,context.temp_allocator)
    testing.expect_value(t,es,kai.Error.Unauthorized)

    // Server (.Node), Writer, or stranger cannot forge an admin Invite_Grant.
    for forger in ([]^kai.Identity{&h.team.identity,&writer,&stranger}) {
        fg,fc:=make_pair(t,org,org_rec.revoke_epoch,forger,&stranger2,secret)
        ad_b,ae:=kai.admission_encode(fg,fc,context.temp_allocator)
        if testing.expect_value(t,ae,kai.Error.None) {
            addr,pe:=kai.object_put(&mac.s,.Admission,ad_b)
            testing.expect_value(t,pe,kai.Error.None)
            _,ace:=kai.admission_accept(&mac.s,&org_rec,addr)
            testing.expect_value(t,ace,kai.Error.Unauthorized)
        }
    }

    // Grant from a revoked epoch is refused.
    stale_g,stale_c:=make_pair(t,org,org_rec.revoke_epoch-1,&mac.team.identity,&stranger,secret)
    stale_b,_:=kai.admission_encode(stale_g,stale_c,context.temp_allocator)
    stale_addr,_:=kai.object_put(&mac.s,.Admission,stale_b)
    _,stale_err:=kai.admission_accept(&mac.s,&org_rec,stale_addr)
    testing.expect_value(t,stale_err,kai.Error.Unauthorized)

    // Valid admission accepted once; a second claim reusing the same 1-use grant is refused.
    ok_b,ok_ae:=kai.admission_encode(gb,cb,context.temp_allocator)
    testing.expect_value(t,ok_ae,kai.Error.None)
    ok_addr,_:=kai.object_put(&mac.s,.Admission,ok_b)
    changed,ace:=kai.admission_accept(&mac.s,&org_rec,ok_addr)
    testing.expect(t,ace==.None && changed,"valid admission accepted")
    _,dup_cb:=make_pair(t,org,org_rec.revoke_epoch,&mac.team.identity,&stranger2,secret)
    dup_b,_:=kai.admission_encode(gb,dup_cb,context.temp_allocator)
    dup_addr,_:=kai.object_put(&mac.s,.Admission,dup_b)
    _,dup_err:=kai.admission_accept(&mac.s,&org_rec,dup_addr)
    testing.expect_value(t,dup_err,kai.Error.Unauthorized)
}
