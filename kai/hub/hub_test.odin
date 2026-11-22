package hub

import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:slice"
import "core:strings"
import "core:testing"
import "mirai:kai"
import mnet "mirai:net"
import "mirai:store"

// Hostile requests are refused, each ending its connection, and the server
// goes on: malformed and smuggling-shaped heads, random bytes, every cut of a
// valid request, oversized heads and bodies, a sender too slow for the
// deadlines and more connections from one address than it takes.
@(test)
hub_http_refuses_hostile_requests :: proc(t:^testing.T) {
    Case :: struct {name,raw:string,status:int}
    long_target:=strings.repeat("a",TARGET_MAX,context.temp_allocator)
    many:=strings.builder_make(context.temp_allocator)
    for i in 0..<HEADERS_MAX+1 {fmt.sbprintf(&many,"X-%d: 1\r\n",i)}
    cases:=[]Case{
        {"a valid GET","GET /api HTTP/1.1\r\nHost: a\r\n\r\n",200},
        {"a valid POST","POST /api/session HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\n{}",200},
        {"Content-Length and Transfer-Encoding","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",501},
        {"a chunked body","POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",501},
        {"two lengths that agree","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",400},
        {"a signed length","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +1\r\n\r\nx",400},
        {"a length with a space inside","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1 1\r\n\r\nx",400},
        {"a folded header","GET / HTTP/1.1\r\nHost: a\r\nX: 1\r\n 2\r\n\r\n",400},
        {"a bare line feed","GET / HTTP/1.1\nHost: a\r\n\r\n",400},
        {"a bare carriage return","GET / HTTP/1.1\r\nHost: a\rX: 1\r\n\r\n",400},
        {"a NUL in a value","GET / HTTP/1.1\r\nHost: a\x00b\r\n\r\n",400},
        {"a space before the colon","GET / HTTP/1.1\r\nHost : a\r\n\r\n",400},
        {"no Host","GET / HTTP/1.1\r\n\r\n",400},
        {"two Hosts","GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",400},
        {"an absolute target","GET http://a/ HTTP/1.1\r\nHost: a\r\n\r\n",400},
        {"a target with a fragment","GET /a#b HTTP/1.1\r\nHost: a\r\n\r\n",400},
        {"a target too long",fmt.tprintf("GET /%s HTTP/1.1\r\nHost: a\r\n\r\n",long_target),414},
        {"two spaces","GET  / HTTP/1.1\r\nHost: a\r\n\r\n",400},
        {"an unknown method","DELETE / HTTP/1.1\r\nHost: a\r\n\r\n",501},
        {"a method that is no token","G(T / HTTP/1.1\r\nHost: a\r\n\r\n",400},
        {"HTTP/2","GET / HTTP/2.0\r\nHost: a\r\n\r\n",505},
        {"no version","GET /\r\nHost: a\r\n\r\n",400},
        {"a GET with a body","GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\n\r\nx",400},
        {"a POST without a length","POST / HTTP/1.1\r\nHost: a\r\n\r\n",411},
        {"a body past BODY_MAX",fmt.tprintf("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\n\r\n",BODY_MAX+1),413},
        {"a length past i32","POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 99999999999\r\n\r\n",400},
        {"an unknown expectation","POST / HTTP/1.1\r\nHost: a\r\nExpect: 200-ok\r\nContent-Length: 1\r\n\r\nx",417},
        {"too many headers",fmt.tprintf("GET / HTTP/1.1\r\nHost: a\r\n%s\r\n",strings.to_string(many)),431},
        {"a head past HEAD_MAX",fmt.tprintf("GET / HTTP/1.1\r\nHost: a\r\nX: %s",strings.repeat("b",HEAD_MAX,context.temp_allocator)),431},
    }
    for c in cases {
        p:=request_parse(transmute([]u8)c.raw)
        testing.expectf(t,p.status==c.status,"%s: %d, not %d",c.name,p.status,c.status)
    }

    // Every cut of a valid request waits for more; random bytes and byte flips never pass as something else.
    valid:="POST /api/session HTTP/1.1\r\nHost: kai.test\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"a\":\"bcd\"}"
    for n in 0..<len(valid) {
        p:=request_parse(transmute([]u8)valid[:n])
        testing.expectf(t,p.status==0 || p.status==400,"a cut at %d is not taken: %d",n,p.status)
    }
    noise:[700]u8
    for _ in 0..<3000 {
        n:=rand.int_max(len(noise))
        _=rand.read(noise[:n])
        p:=request_parse(noise[:n])
        testing.expect(t,p.status!=200 || p.request.size<=n)
        flipped:=transmute([]u8)strings.clone(valid,context.temp_allocator)
        flipped[rand.int_max(len(flipped))]=u8(rand.int_max(256))
        q:=request_parse(flipped)
        testing.expect(t,q.status!=200 || (q.request.size<=len(flipped) && len(q.request.body)<=BODY_MAX))
        free_all(context.temp_allocator)
    }

    // Over sockets, on loopback.
    f:=new(Fixture)
    defer free(f)
    defer fixture_close(f)
    if !fixture_open(t,f,"kai-hub-http") {return}
    h:=&f.hub
    open :: proc(t:^testing.T,f:^Fixture) -> (s:net.TCP_Socket,ok:bool) {
        socket,e:=net.dial_tcp(net.Endpoint{net.IP4_Loopback,f.hub.http_port})
        if !testing.expect(t,e==nil,"a connection opens") {return}
        net.set_blocking(socket,false)
        return socket,true
    }
    // What the socket gets within some steps of the hub, and whether the hub closed it.
    read :: proc(f:^Fixture,s:net.TCP_Socket,want:string="",steps:=400) -> (data:string,closed:bool) {
        got:=make([dynamic]u8,context.temp_allocator)
        buffer:[4096]u8
        for _ in 0..<steps {
            hub_step(&f.hub)
            n,e:=net.recv_tcp(s,buffer[:])
            if e==nil && n==0 {return string(got[:]),true}
            if e!=nil && e!=.Would_Block {return string(got[:]),true}
            append(&got,..buffer[:n])
            if want!="" && strings.count(string(got[:]),want)>=1 && strings.has_suffix(string(got[:]),"}") {return string(got[:]),false}
        }
        return string(got[:]),false
    }

    // Two requests in one write are answered in order on the same connection.
    if s,ok:=open(t,f);ok {
        net.send_tcp(s,transmute([]u8)string("GET /api/node HTTP/1.1\r\nHost: a\r\n\r\nGET /api/projects HTTP/1.1\r\nHost: a\r\n\r\n"))
        data,closed:=read(f,s,"\"projects\"")
        testing.expectf(t,!closed && strings.count(data,"HTTP/1.1 200 OK")==2 && strings.index(data,"\"device\"")<strings.index(data,"\"projects\""),"pipelined: %s",data)
        net.close(s)
    }
    // Garbage, an oversized head and an oversized body each get their refusal and the connection ends.
    for raw in ([?]string{
        "\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03garbage\r\n\r\n",
        fmt.tprintf("GET / HTTP/1.1\r\nX: %s",strings.repeat("c",HEAD_MAX+16,context.temp_allocator)),
        fmt.tprintf("POST /api/session HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\n\r\n",BODY_MAX*4),
    }) {
        s,ok:=open(t,f)
        if !ok {continue}
        net.send_tcp(s,transmute([]u8)raw)
        data,closed:=read(f,s)
        testing.expectf(t,closed && strings.has_prefix(data,"HTTP/1.1 4"),"refused and closed: %q",data[:min(len(data),40)])
        net.close(s)
    }
    // A head that does not end within HEAD_SECONDS loses its connection.
    if s,ok:=open(t,f);ok {
        net.send_tcp(s,transmute([]u8)string("GET /api/node HTTP/1.1\r\nHo"))
        _,closed:=read(f,s,steps=20)
        testing.expect(t,!closed,"a slow head waits within the deadline")
        f.now+=HEAD_SECONDS+1
        _,closed=read(f,s)
        testing.expect(t,closed,"past the deadline the connection ends")
        net.close(s)
    }
    // An idle keep-alive connection ends after IDLE_SECONDS.
    if s,ok:=open(t,f);ok {
        net.send_tcp(s,transmute([]u8)string("GET /api/node HTTP/1.1\r\nHost: a\r\n\r\n"))
        read(f,s,"\"device\"")
        f.now+=IDLE_SECONDS+1
        _,closed:=read(f,s)
        testing.expect(t,closed,"an idle connection ends")
        net.close(s)
    }
    // More connections from one address than it takes: the rest are closed at once.
    sockets:[CONNECTIONS_PER_ADDRESS+4]net.TCP_Socket
    opened:=0
    for &s in sockets {
        ok:bool
        if s,ok=open(t,f);ok {opened+=1}
    }
    for _ in 0..<50 {hub_step(&f.hub)}
    held:=0
    for c in h.conns {
        if c!=nil {held+=1}
    }
    testing.expectf(t,held<=CONNECTIONS_PER_ADDRESS,"%d connections held from one address",held)
    closed_count:=0
    for s in sockets[:opened] {
        if _,closed:=read(f,s,steps=5);closed {closed_count+=1}
    }
    testing.expectf(t,closed_count>=opened-CONNECTIONS_PER_ADDRESS,"%d of the extra connections closed",closed_count)
    for s in sockets[:opened] {net.close(s)}
    for _ in 0..<50 {hub_step(&f.hub)}
    // Through all of it the server goes on.
    if s,ok:=open(t,f);ok {
        net.send_tcp(s,transmute([]u8)string("GET /api/node HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"))
        data,_:=read(f,s,"\"device\"")
        testing.expectf(t,strings.has_prefix(data,"HTTP/1.1 200 OK") && strings.contains(data,"X-Content-Type-Options: nosniff") && strings.contains(data,"Content-Security-Policy: default-src 'self'"),"served with its security headers: %s",data[:min(len(data),80)])
        net.close(s)
    }
    testing.expect(t,h.stats.refused>0)
}

// Every public route answers an anonymous client for the public project and
// none answers anything of the private one, of a scoped path or of an
// overlay; member routes need a session. A browser's new user registers its
// passkey, signs in, and posts a verdict that a second machine's fold takes;
// a forged or replayed assertion is refused. A device approves a login and a
// second passkey for a browser without one.
@(test)
hub_serves_public_and_member_views :: proc(t:^testing.T) {
    f:=new(Fixture)
    defer free(f)
    defer fixture_close(f)
    if !fixture_open(t,f,"kai-hub-views") {return}
    P,Q:=hex(f.public[:]),hex(f.private[:])
    r1,r3:=hex(f.r1[:]),hex(f.r3[:])
    change:=hex(f.change[:])

    expect_clean :: proc(t:^testing.T,a:Answer,P,Q:string,loc:=#caller_location) {
        for leak in ([?]string{PRIVATE_MARKER,SCOPED_MARKER,Q,"secrets/","kai-ovl"}) {
            testing.expectf(t,!strings.contains(a.body,leak),"no %q in %s",leak,a.body[:min(len(a.body),120)],loc=loc)
        }
    }
    // Public, anonymous: every GET route with the public project.
    Visit :: struct {path:string,status:int,has:string}
    public_visits:=[]Visit{
        {"/api",200,"\"routes\""},
        {"/api/node",200,"\"seed\""},
        {"/api/projects",200,P},
        {fmt.tprintf("/api/projects/%s",P),200,"Welcome to the site"},
        {fmt.tprintf("/api/projects/%s/tree",P),200,"\"src\""},
        {fmt.tprintf("/api/projects/%s/tree?path=src&rev=main",P),200,"a.txt"},
        {fmt.tprintf("/api/projects/%s/file?path=src/a.txt",P),200,"one\ntwo\nthree\n"},
        {fmt.tprintf("/api/projects/%s/file?path=bin.dat&rev=%s",P,r1),200,"binary"},
        {fmt.tprintf("/api/projects/%s/changes?rev=main&limit=1",P),200,"\"more\":true"},
        {fmt.tprintf("/api/projects/%s/changes/%s",P,r3),200,"docs/b.md"},
        {fmt.tprintf("/api/projects/%s/diff?from=%s&to=%s&path=src/a.txt",P,r1,r3),200,"\"op\":\"add\""},
        {fmt.tprintf("/api/projects/%s/diff?from=%s&to=%s&path=bin.dat",P,r1,r3),200,"\"binary\":true"},
        {fmt.tprintf("/api/projects/%s/evolution/%s",P,change),200,"\"interdiffs\""},
        {"/api/entries",200,"\"author_ctx\""},
        {fmt.tprintf("/api/projects/%s/tree?path=secrets",P),404,""},
        {fmt.tprintf("/api/projects/%s/file?path=secrets/key.txt",P),404,""},
        {fmt.tprintf("/api/projects/%s/diff?from=%s&to=%s&path=secrets/key.txt",P,r1,r3),404,""},
        {fmt.tprintf("/api/projects/%s/changes/%s",P,hex(f.rq[:])),404,""},
    }
    for v in public_visits {
        a:=call(f,"GET",v.path)
        testing.expectf(t,a.status==v.status && strings.contains(a.body,v.has),"GET %s: %d %s",v.path,a.status,a.body[:min(len(a.body),160)])
        expect_clean(t,a,P,Q)
    }
    // The frontend: every file with its type and nothing that would replace the policy every
    // answer carries, nothing the policy blocks (inline script or style, eval, modules from
    // elsewhere), and the page for a path of its router.
    testing.expect(t,strings.contains(SECURITY_HEADERS,"script-src 'self'; style-src 'self'"),"the policy allows this origin's scripts and styles alone")
    web:=#load_directory("web")
    names:=make([dynamic]string,context.temp_allocator)
    for w in web {append(&names,w.name)}
    testing.expect(t,slice.contains(names[:],"index.html") && slice.contains(names[:],"app.js") && slice.contains(names[:],"vue.js"),"the frontend is embedded")
    TYPES :: [?][2]string{{".html","text/html; charset=utf-8"},{".js","text/javascript; charset=utf-8"},{".css","text/css; charset=utf-8"}}
    for w in web {
        a:=call(f,"GET",fmt.tprintf("/%s",w.name))
        want:=""
        for x in TYPES {
            if strings.has_suffix(w.name,x[0]) {want=x[1]}
        }
        testing.expectf(t,a.status==200 && a.content_type==want && a.body==string(w.data) && a.headers=="","%s is served as %q: %d %q",w.name,want,a.status,a.content_type)
        text:=string(w.data)
        for banned in ([?]string{"eval(","new Function","<style",`style="`,"javascript:","document.write"}) {
            testing.expectf(t,!strings.contains(text,banned),"%s holds no %q",w.name,banned)
        }
        if strings.has_suffix(w.name,".html") {
            rest:=text
            for at:=strings.index(rest,"<script");at>=0;at=strings.index(rest,"<script") {
                tag:=rest[at:]
                tag=tag[:strings.index_byte(tag,'>')+1]
                testing.expectf(t,strings.contains(tag,`src="/`) && strings.contains(tag,`type="module"`),"a script of %s is a module of this origin: %s",w.name,tag)
                rest=rest[at+len(tag):]
            }
        }
        if strings.has_suffix(w.name,".js") {
            rest:=text
            for at:=strings.index(rest," from '");at>=0;at=strings.index(rest," from '") {
                rest=rest[at+len(" from '"):]
                specifier:=rest[:strings.index_byte(rest,'\'')]
                testing.expectf(t,strings.has_prefix(specifier,"./") && slice.contains(names[:],specifier[2:]),"%s imports %q, a file beside it",w.name,specifier)
            }
        }
        if strings.has_suffix(w.name,".css") {
            testing.expectf(t,!strings.contains(text,"url(") && !strings.contains(text,"@import"),"%s loads nothing",w.name)
        }
    }
    for path in ([?]string{"/",fmt.tprintf("/p/%s/tree",P),fmt.tprintf("/proposal/%s",hex(f.proposal[:]))}) {
        a:=call(f,"GET",path)
        testing.expectf(t,a.status==200 && strings.has_prefix(a.content_type,"text/html") && strings.contains(a.body,`src="/app.js"`),"GET %s answers the page: %d",path,a.status)
    }
    testing.expect(t,call(f,"GET","/missing.js").status==404,"a file that is not there is no page")

    file:=call(f,"GET",fmt.tprintf("/api/projects/%s/file?path=bin.dat",P))
    testing.expect(t,strings.contains(file.headers,"sandbox") && strings.contains(file.headers,"attachment"),"a binary file is an attachment, sandboxed")
    // The private project and member routes answer an anonymous client nothing.
    private_visits:=[]string{
        fmt.tprintf("/api/projects/%s",Q),fmt.tprintf("/api/projects/%s/tree",Q),fmt.tprintf("/api/projects/%s/file?path=secret.txt",Q),
        fmt.tprintf("/api/projects/%s/changes",Q),fmt.tprintf("/api/projects/%s/changes/%s",Q,hex(f.rq[:])),
    }
    for path in private_visits {
        a:=call(f,"GET",path)
        testing.expectf(t,a.status==404,"GET %s: %d",path,a.status)
        expect_clean(t,a,P,Q)
    }
    member_visits:=[]string{
        fmt.tprintf("/api/projects/%s/stacks",P),fmt.tprintf("/api/projects/%s/proposals",P),fmt.tprintf("/api/proposals/%s",hex(f.proposal[:])),
        fmt.tprintf("/api/orgs/%s/members",hex(f.org[:])),fmt.tprintf("/api/orgs/%s/ddc",hex(f.org[:])),"/api/node/stats","/api/session",
    }
    for path in member_visits {
        a:=call(f,"GET",path)
        testing.expectf(t,a.status==401,"GET %s without a session: %d",path,a.status)
    }
    Evolution :: struct {revisions:[]struct {revision:string},interdiffs:[]struct {files:[]struct {path:string}}}
    ev:Evolution
    if json_read(t,call(f,"GET",fmt.tprintf("/api/projects/%s/evolution/%s",P,change)),&ev) {
        testing.expect(t,len(ev.revisions)==2 && ev.revisions[0].revision==hex(f.r2[:]) && ev.revisions[1].revision==r3,"the change's two revisions, oldest first")
        testing.expect(t,len(ev.interdiffs)==1 && len(ev.interdiffs[0].files)==2,"the interdiff names a.txt and b.md")
    }

    // A browser makes a new user with its passkey: recovery and device keys of its own.
    bob_key:=passkey_make()
    recovery,device:=kai.identity_make(),kai.identity_make()
    dh,_:=mnet.dh_key()
    genesis_body:=kai.body_make(kai.User_Genesis_Body{recovery=recovery.key,device=device.key,dh=kai.Dh_Key(dh.public),proof=kai.device_proof(&device,transmute([32]u8)recovery.key)},transmute([]u8)string("bob"))
    gd:=kai.Draft{type=.User_Genesis,time=100,body=genesis_body}
    genesis,bob,_:=kai.entry_sign(&gd,&recovery,context.temp_allocator)
    wk,_:=kai.web_key_add_body(bob_key.credential[:],passkey_cose(&bob_key),RP)
    wd:=kai.Draft{type=.Web_Key_Add,log_id=bob,parents={bob},time=101,body=wk}
    add,_,_:=kai.entry_sign(&wd,&recovery,context.temp_allocator)
    wrong_rp,_:=kai.web_key_add_body(bob_key.credential[:],passkey_cose(&bob_key),"evil.test")
    wd.body=wrong_rp
    evil,_,_:=kai.entry_sign(&wd,&recovery,context.temp_allocator)
    a:=call(f,"POST","/api/users",fmt.tprintf(`{{"entries":["%s","%s"]}}`,b64(genesis),b64(evil)))
    testing.expectf(t,a.status==400,"a passkey of another site is refused: %d",a.status)
    stranger:=kai.identity_make()
    wd.body=wk
    unsigned,_,_:=kai.entry_sign(&wd,&stranger,context.temp_allocator)
    a=call(f,"POST","/api/users",fmt.tprintf(`{{"entries":["%s","%s"]}}`,b64(genesis),b64(unsigned)))
    testing.expectf(t,a.status==400,"a Web_Key_Add another key signed is refused: %d",a.status)
    a=call(f,"POST","/api/users",fmt.tprintf(`{{"entries":["%s","%s"]}}`,b64(genesis),b64(add)))
    testing.expectf(t,a.status==201 && strings.contains(a.body,hex(bob[:])),"the new user is kept: %d %s",a.status,a.body)
    testing.expect_value(t,kai.machine_member_add(&f.alice,f.org,bob,.Writer),kai.Error.None)

    // It signs in; a challenge counts once, and a forged assertion is refused.
    cookie:=sign_in(t,f,&bob_key)
    Challenge_Answer :: struct {challenge:string}
    ch:Challenge_Answer
    json_read(t,call(f,"POST","/api/session/challenge"),&ch)
    assertion:=passkey_assert(&bob_key,unb64(ch.challenge))
    a=call(f,"POST","/api/session",fmt.tprintf(`{{"challenge":"%s","assertion":%s}}`,ch.challenge,passkey_forge(assertion)))
    testing.expectf(t,a.status==401 && a.cookie=="","a forged assertion is refused: %d",a.status)
    json_read(t,call(f,"POST","/api/session/challenge"),&ch)
    assertion=passkey_assert(&bob_key,unb64(ch.challenge))
    a=call(f,"POST","/api/session",fmt.tprintf(`{{"challenge":"%s","assertion":%s}}`,ch.challenge,assertion))
    testing.expect(t,a.status==200,"a fresh challenge signs in")
    a=call(f,"POST","/api/session",fmt.tprintf(`{{"challenge":"%s","assertion":%s}}`,ch.challenge,assertion))
    testing.expectf(t,a.status==401,"a replayed login is refused: %d",a.status)
    other:=passkey_make()
    json_read(t,call(f,"POST","/api/session/challenge"),&ch)
    a=call(f,"POST","/api/session",fmt.tprintf(`{{"challenge":"%s","assertion":%s}}`,ch.challenge,passkey_assert(&other,unb64(ch.challenge))))
    testing.expect(t,a.status==401,"a passkey no user has is refused")

    // The session reads the member views and the private project.
    for path in member_visits {
        b:=call(f,"GET",path,cookie=cookie)
        testing.expectf(t,b.status==200,"GET %s as a member: %d %s",path,b.status,b.body[:min(len(b.body),160)])
    }
    for path in private_visits {
        b:=call(f,"GET",path,cookie=cookie)
        testing.expectf(t,b.status==200,"GET %s as a member: %d",path,b.status)
    }
    testing.expect(t,strings.contains(call(f,"GET","/api/projects",cookie=cookie).body,Q),"a member lists the private project")
    stacks:=call(f,"GET",fmt.tprintf("/api/projects/%s/stacks",P),cookie=cookie)
    testing.expectf(t,strings.contains(stacks.body,"alice/") && strings.contains(stacks.body,":main"),"stacks are <handle>/<device>:<bookmark>: %s",stacks.body)
    proposal:=call(f,"GET",fmt.tprintf("/api/proposals/%s",hex(f.proposal[:])),cookie=cookie)
    testing.expectf(t,strings.contains(proposal.body,change) && strings.contains(proposal.body,"\"blocked\"") && strings.contains(proposal.body,`"opener_name":"alice"`),"the proposal's stack and opener: %s",proposal.body)

    // A verdict: the server drafts the bytes, the browser signs their BLAKE3.
    Draft_Answer :: struct {unsigned:string,author_ctx:string}
    d:Draft_Answer
    draft_body:=fmt.tprintf(`{{"type":"proposal_verdict","log":"%s","verdict":"approve","revision":"%s"}}`,hex(f.proposal[:]),r3)
    testing.expect(t,strings.contains(call(f,"POST","/api/drafts",draft_body).body,"sign in"),"a draft needs a session")
    if !json_read(t,call(f,"POST","/api/drafts",draft_body,cookie),&d) {return}
    testing.expect(t,!strings.contains(call(f,"POST","/api/drafts",draft_body,cookie).body,"challenge"),"a draft gives no challenge")
    bytes:=unb64(d.unsigned)
    challenge:=store.address_of_bytes(bytes)
    signed:=passkey_assert(&bob_key,challenge[:])
    a=call(f,"POST","/api/entries",fmt.tprintf(`{{"unsigned":"%s","assertion":%s}}`,d.unsigned,passkey_forge(signed)),cookie)
    testing.expectf(t,a.status==401,"a forged write is refused: %d %s",a.status,a.body)
    tampered:=slice.clone(bytes,context.temp_allocator)
    tampered[len(tampered)-1]~=1
    a=call(f,"POST","/api/entries",fmt.tprintf(`{{"unsigned":"%s","assertion":%s}}`,b64(tampered),signed),cookie)
    testing.expectf(t,a.status==400 || a.status==401,"bytes changed after signing are refused: %d",a.status)
    a=call(f,"POST","/api/entries",fmt.tprintf(`{{"unsigned":"%s","assertion":%s}}`,d.unsigned,signed),cookie)
    testing.expectf(t,a.status==201,"the verdict is kept: %d %s",a.status,a.body)
    Kept :: struct {address:string}
    kept:Kept
    json_read(t,a,&kept)
    a=call(f,"POST","/api/entries",fmt.tprintf(`{{"unsigned":"%s","assertion":%s}}`,d.unsigned,signed),cookie)
    testing.expectf(t,a.status==409,"a replayed write is refused: %d",a.status)

    // A second machine folds it with the logs alone, every signature checked.
    {
        s,from:=&f.peer.store,&f.alice.store
        Copy :: struct {id:kai.Log_Id,kind:kai.Log_Kind}
        logs:=[?]Copy{{f.alice.user,.User},{bob,.User},{f.org,.Org},{f.proposal,.Proposal}}
        opened:[4]kai.Log
        for c,i in logs {
            l:kai.Log
            kai.log_init(&l,c.id,context.temp_allocator)
            testing.expect_value(t,kai.log_open(from,&l,c.id,c.kind),kai.Error.None)
            kai.log_save(s,&l)
            kai.log_init(&opened[i],c.id,context.temp_allocator)
            testing.expect_value(t,kai.log_open(s,&opened[i],c.id,c.kind),kai.Error.None)
            for &item in opened[i].items {testing.expect(t,kai.entry_verify(item.bytes,&item.entry),"every entry verifies offline")}
        }
        ua,ub:kai.User_Fold
        testing.expect_value(t,kai.user_fold(&ua,&opened[0],context.temp_allocator),kai.Error.None)
        testing.expect_value(t,kai.user_fold(&ub,&opened[1],context.temp_allocator),kai.Error.None)
        users:=[]^kai.User_Fold{&ua,&ub}
        of:kai.Org_Fold
        testing.expect_value(t,kai.org_fold(&of,&opened[2],users,context.temp_allocator),kai.Error.None)
        pf:kai.Proposal_Fold
        testing.expect_value(t,kai.proposal_fold(&pf,&opened[3],&of,context.temp_allocator),kai.Error.None)
        address,_:=hash_parse(kept.address)
        at:=kai.log_find(&opened[3],address)
        testing.expect(t,at>=0 && pf.valid[at],"the peer's fold takes the browser's verdict")
        found:=false
        for v in pf.verdicts {found||=v.user==bob && v.verdict==.Approve && v.revision==f.r3}
        testing.expect(t,found,"the verdict is bob's approval of the stack's head")
    }

    // A browser without a passkey: alice's second device approves its login.
    Approval_Answer :: struct {id,secret,link,command:string}
    ap:Approval_Answer
    if json_read(t,call(f,"POST","/api/approvals",`{"kind":"login"}`),&ap) {
        testing.expect(t,strings.has_prefix(ap.link,"kai://approve?") && strings.has_prefix(ap.command,"mirai kai web approve "),"a link and the command that opens it")
        origin,id,ok:=link_parse(ap.link)
        testing.expect(t,ok && origin==f.hub.origin && id==ap.id,"the link names this hub and the approval")
        ask:Approval_Ask
        json_read(t,call(f,"GET",fmt.tprintf("/api/approvals/%s",id)),&ask)
        state:=call(f,"POST",fmt.tprintf("/api/approvals/%s/state",id),fmt.tprintf(`{{"secret":"%s"}}`,ap.secret))
        testing.expect(t,strings.contains(state.body,"waiting") && state.cookie=="","it waits")
        body,_,why:=approve_answer(&f.second,&ask,origin)
        testing.expectf(t,why=="",why)
        stranger_body,_,_:=approve_answer(&f.peer,&ask,origin)
        if stranger_body!=nil {
            b:=call(f,"POST",fmt.tprintf("/api/approvals/%s",id),string(stranger_body))
            testing.expect(t,b.status==403,"a device of no user is refused")
        }
        _,_,why=approve_answer(&f.second,&ask,"https://evil.test")
        testing.expect(t,why!="","an answer for another origin is not signed")
        b:=call(f,"POST",fmt.tprintf("/api/approvals/%s",id),string(body))
        testing.expectf(t,b.status==200,"the device's answer is taken: %d %s",b.status,b.body)
        state=call(f,"POST",fmt.tprintf("/api/approvals/%s/state",id),`{"secret":"AAAA"}`)
        testing.expect(t,state.status==403 && state.cookie=="","another secret gets nothing")
        state=call(f,"POST",fmt.tprintf("/api/approvals/%s/state",id),fmt.tprintf(`{{"secret":"%s"}}`,ap.secret))
        testing.expect(t,state.cookie!="","the browser's session")
        who:=call(f,"GET","/api/session",cookie=state.cookie)
        testing.expect(t,strings.contains(who.body,hex(f.alice.user[:])) && strings.contains(who.body,"\"passkey\":null"),"it is alice's, without a passkey")
        again:=call(f,"POST",fmt.tprintf("/api/approvals/%s/state",id),fmt.tprintf(`{{"secret":"%s"}}`,ap.secret))
        testing.expect(t,again.cookie=="","a login is given once")

        // A write of that session: the device signs it, and its agent may bring the entry to
        // the node before its answer does.
        write:Approval_Answer
        asked:=fmt.tprintf(`{{"kind":"entry","draft":{{"type":"proposal_comment","log":"%s","text":"From a device"}}}}`,hex(f.proposal[:]))
        if json_read(t,call(f,"POST","/api/approvals",asked,state.cookie),&write) {
            write_ask:Approval_Ask
            json_read(t,call(f,"GET",fmt.tprintf("/api/approvals/%s",write.id)),&write_ask)
            signed,_,write_why:=approve_answer(&f.second,&write_ask,f.hub.origin)
            testing.expectf(t,write_why=="",write_why)
            synced:kai.Log
            kai.log_init(&synced,f.proposal,context.temp_allocator)
            testing.expect_value(t,kai.log_open(&f.second.store,&synced,f.proposal,.Proposal),kai.Error.None)
            kai.log_save(&f.alice.store,&synced)
            testing.expect_value(t,store.commit(&f.alice.store),store.Error.None)
            answer:=call(f,"POST",fmt.tprintf("/api/approvals/%s",write.id),string(signed))
            testing.expectf(t,answer.status==200,"an entry the node holds already is approved: %d %s",answer.status,answer.body)
            polled:=call(f,"POST",fmt.tprintf("/api/approvals/%s/state",write.id),fmt.tprintf(`{{"secret":"%s"}}`,write.secret))
            testing.expectf(t,strings.contains(polled.body,`"approved"`) && strings.contains(polled.body,`"address"`),"the browser learns where it is kept: %s",polled.body)
        }
    }
    // And a passkey alice's browser made, which the device adds to her user.
    alice_key:=passkey_make()
    ap={}
    f.now+=LIMITS_CREATE_REFILL // the users made above spent this address's creations
    link:=call(f,"POST","/api/passkeys/link",fmt.tprintf(`{{"user":"%s","credential":"%s","cose":"%s"}}`,hex(f.alice.user[:]),b64(alice_key.credential[:]),b64(passkey_cose(&alice_key))))
    testing.expectf(t,link.status==201,"a passkey link waits for a device: %d %s",link.status,link.body)
    if json_read(t,link,&ap) {
        ask:Approval_Ask
        json_read(t,call(f,"GET",fmt.tprintf("/api/approvals/%s",ap.id)),&ask)
        body,_,why:=approve_answer(&f.second,&ask,f.hub.origin)
        testing.expectf(t,why=="",why)
        b:=call(f,"POST",fmt.tprintf("/api/approvals/%s",ap.id),string(body))
        testing.expectf(t,b.status==200,"the Web_Key_Add is kept: %d %s",b.status,b.body)
        who:=call(f,"GET","/api/session",cookie=sign_in(t,f,&alice_key))
        web_key:=kai.web_key_id(passkey_cose(&alice_key),RP)
        testing.expect(t,strings.contains(who.body,hex(f.alice.user[:])) && strings.contains(who.body,fmt.tprintf("\"passkey\":\"%s\"",hex(web_key[:]))),"the new passkey signs alice in, as the author its entries name")
    }
}

LIMITS_CREATE_REFILL :: 700.0

// GET /api lists every route the table dispatches, with its params, and each
// path the table names reaches its route.
@(test)
hub_api_describes_every_route :: proc(t:^testing.T) {
    f:=new(Fixture)
    defer free(f)
    defer fixture_close(f)
    if !fixture_open(t,f,"kai-hub-describe") {return}
    Described :: struct {
        routes:[]struct {method,path,access,summary,result:string,params:[]struct {name:string,in_:string `json:"in"`,type,text:string}},
        notes:[]string,
    }
    d:Described
    if !json_read(t,call(f,"GET","/api"),&d) {return}
    routes:=ROUTES
    testing.expect_value(t,len(d.routes),len(routes))
    methods:=METHOD_TEXT
    for &r,i in routes {
        if i>=len(d.routes) {break}
        x:=d.routes[i]
        testing.expectf(t,x.method==methods[r.method] && x.path==r.path && x.summary!="" && x.result!="","%s %s is described",methods[r.method],r.path)
        testing.expectf(t,len(x.params)==len(r.params),"%s lists its %d params",r.path,len(r.params))
        names:=0
        for segment in strings.split(r.path,"/",context.temp_allocator) {
            if !strings.has_prefix(segment,"{") {continue}
            names+=1
            found:=false
            for p in x.params {found||=p.in_=="path" && segment==fmt.tprintf("{{%s}}",p.name)}
            testing.expectf(t,found,"%s describes its path param %s: %v",r.path,segment,x.params)
        }
        // The path reaches this route, not the fallback.
        concrete,_:=strings.replace_all(r.path,"{","",context.temp_allocator)
        concrete,_=strings.replace_all(concrete,"}","",context.temp_allocator)
        a:=call(f,methods[r.method],concrete,r.method==.POST?"{}":"")
        testing.expectf(t,!strings.contains(a.body,"no such route"),"%s %s is dispatched: %s",methods[r.method],r.path,a.body)
        _=names
    }
    testing.expect(t,len(d.notes)>0)
    testing.expect(t,strings.contains(call(f,"POST","/api/node").body,"another method"),"a known path with another method says so")
    testing.expect(t,call(f,"GET","/api/nothing").status==404)
}
