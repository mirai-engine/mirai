package hub

import "core:crypto"
import "core:crypto/ecdsa"
import "core:crypto/x509"
import "core:encoding/endian"
import "core:encoding/pem"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:net/tls"
import "mirai:std/base"
import "mirai:std/subprocess"

// The headless node builds as a static linux_arm64 executable, and where a
// linux/arm64 runtime is at hand (this machine, or docker) it serves a
// node's store over HTTPS with a certificate of a local authority: a public
// view to anyone, a member view to a session a device of the member approved.
// Without a runtime the build is checked and the run is reported skipped.
@(test)
headless_arm64_server_builds_and_serves_public_and_member_views :: proc(t:^testing.T) {
    root,_:=filepath.clean(strings.concatenate({#directory,"/../.."},context.temp_allocator),context.temp_allocator)
    program:=strings.concatenate({root,"/bin/mirai.exe"},context.temp_allocator) when ODIN_OS==.Windows else strings.concatenate({root,"/mirai"},context.temp_allocator)
    state,out,errs,e:=subprocess.exec({working_dir=root,command={program,"build","kai","--target","linux_arm64"}},context.temp_allocator)
    if e==nil && state.exit_code!=0 && strings.contains(string(errs),"ld.lld is not in PATH") {
        log.warnf("SKIPPED linux_arm64 headless build: ld.lld is not in PATH")
        return
    }
    if !testing.expectf(t,e==nil && state.exit_code==0,"mirai build kai --target linux_arm64: %v %s%s",e,out,errs) {return}
    executable:=strings.concatenate({root,"/bin/mirai-kai-linux-arm64"},context.temp_allocator)
    elf,re:=os.read_entire_file(executable,context.temp_allocator)
    if !testing.expect(t,re==nil && len(elf)>64,"the executable is there") {return}
    testing.expect(t,string(elf[:4])=="\x7fELF" && elf[4]==2 && elf[18]==0xb7,"an ELF64 for aarch64")
    phoff,_:=endian.get_u64(elf[32:],.Little)
    phsize,_:=endian.get_u16(elf[54:],.Little)
    phnum,_:=endian.get_u16(elf[56:],.Little)
    interpreter:=false
    for i in 0..<int(phnum) {
        at:=int(phoff)+i*int(phsize)
        if at+4>len(elf) {break}
        kind,_:=endian.get_u32(elf[at:],.Little)
        interpreter||=kind==3 // PT_INTERP: a dynamic loader
    }
    testing.expect(t,!interpreter,"static: no dynamic loader")

    native:=ODIN_OS==.Linux && ODIN_ARCH==.arm64
    if !native {
        state,out,_,e=subprocess.exec({command={"docker","info","--format","{{.Architecture}}"}},context.temp_allocator)
        arch:=strings.trim_space(string(out))
        if e!=nil || state.exit_code!=0 || (arch!="aarch64" && arch!="arm64") {
            log.warnf("SKIPPED the run of %s: no linux/arm64 runtime here (docker: %s); the build was checked",executable,e!=nil?"absent":arch==""?"not running":arch)
            return
        }
    }

    // A store under the checkout, which docker's VM shares.
    folder:=fmt.tprintf("%s/bin/tests/kai-headless-%x",root,u64(time.now()._nsec))
    if !testing.expect(t,base.make_directory_all(folder)==nil) {return}
    // The container's mount may let go of the folder a moment after it stops.
    defer for _ in 0..<25 {
        if base.remove_all(folder)==nil && !os.exists(folder) {break}
        time.sleep(200*time.Millisecond)
    }
    f:=new(Fixture)
    defer free(f)
    defer fixture_close(f)
    if !fixture_store(t,f,folder) {return}
    ca_key,leaf_key:ecdsa.Private_Key
    if !testing.expect(t,ecdsa.private_key_generate(&ca_key,.SECP256R1) && ecdsa.private_key_generate(&leaf_key,.SECP256R1)) {return}
    defer ecdsa.private_key_clear(&ca_key)
    defer ecdsa.private_key_clear(&leaf_key)
    now:=time.now()
    ca_public,leaf_public:[65]u8
    ecdsa.private_key_public_bytes(&ca_key,ca_public[:])
    ecdsa.private_key_public_bytes(&leaf_key,leaf_public[:])
    ca_der,ce:=tls.certificate_make({names={"Kai Test Authority"},public_key=ca_public[:],not_before=time.time_add(now,-time.Hour),not_after=time.time_add(now,24*time.Hour),issuer=&ca_key,authority=true},context.temp_allocator)
    leaf_der,le:=tls.certificate_make({names={RP},public_key=leaf_public[:],not_before=time.time_add(now,-time.Hour),not_after=time.time_add(now,90*24*time.Hour),issuer=&ca_key,issuer_name="Kai Test Authority"},context.temp_allocator)
    if !testing.expect(t,ce==nil && le==nil,"the test authority issues the node's certificate") {return}
    scalar:[32]u8
    ecdsa.private_key_bytes(&leaf_key,scalar[:])
    chain,_:=pem.encode("CERTIFICATE",leaf_der,false,context.temp_allocator)
    os.make_directory(strings.concatenate({f.alice.store.root,"/",WEB_FOLDER},context.temp_allocator))
    testing.expect(t,secret_write(strings.concatenate({f.alice.store.root,"/",WEB_KEY_FILE},context.temp_allocator),scalar[:]))
    testing.expect(t,secret_write(strings.concatenate({f.alice.store.root,"/",WEB_CHAIN_FILE},context.temp_allocator),chain))
    crypto.zero_explicit(&scalar,32)
    ca,pe:=x509.parse(ca_der,context.temp_allocator)
    if !testing.expect(t,pe==.None) {return}
    roots:=[]^x509.Certificate{&ca}

    PORT :: 8443
    origin:=fmt.tprintf("https://%s:%d",RP,PORT)
    serve:=[]string{"serve","--mode","seed","--store","","--port","47914","--domain",RP,"--https",fmt.tprintf("%d",PORT)}
    dial_port:=PORT
    name:=fmt.tprintf("kai-headless-%x",u32(time.now()._nsec))
    node:subprocess.Process
    if native {
        serve[4]=f.alice.store.root
        command:=make([dynamic]string,context.temp_allocator)
        append(&command,executable)
        append(&command,..serve)
        p,se:=subprocess.start({command=command[:],stdout=os.stdout,stderr=os.stderr})
        if !testing.expect(t,se==nil,"the node starts") {return}
        node=p
    } else {
        image:=fmt.tprintf("%s/image",folder)
        base.make_directory_all(image)
        if !testing.expect(t,os.write_entire_file(fmt.tprintf("%s/Dockerfile",image),transmute([]u8)string("FROM scratch\nCMD [\"/b/mirai-kai-linux-arm64\"]\n"))==nil) {return}
        state,_,errs,e=subprocess.exec({command={"docker","build","-q","-t","mirai-kai-scratch",image}},context.temp_allocator)
        if !testing.expectf(t,e==nil && state.exit_code==0,"an empty image builds: %s",errs) {return}
        serve[4]="/s/alice"
        command:=make([dynamic]string,context.temp_allocator)
        append(&command,"docker","run","-d","--rm","--name",name,"--platform","linux/arm64","-p",fmt.tprintf("127.0.0.1::%d",PORT),
            "-v",fmt.tprintf("%s/bin:/b:ro",root),"-v",fmt.tprintf("%s:/s",folder),"mirai-kai-scratch","/b/mirai-kai-linux-arm64")
        append(&command,..serve)
        state,_,errs,e=subprocess.exec({command=command[:]},context.temp_allocator)
        if !testing.expectf(t,e==nil && state.exit_code==0,"the container runs: %s",errs) {return}
        state,out,_,_=subprocess.exec({command={"docker","port",name,fmt.tprintf("%d/tcp",PORT)}},context.temp_allocator)
        mapped:=strings.trim_space(string(out))
        if line:=strings.index_byte(mapped,'\n');line>=0 {mapped=mapped[:line]}
        n,ok:=parse_count(mapped[strings.last_index_byte(mapped,':')+1:])
        if !testing.expectf(t,ok,"the container's port: %s",mapped) {return}
        dial_port=n
    }
    defer {
        if native {
            subprocess.release(&node)
        } else {
            _,logs,logs_err,_:=subprocess.exec({command={"docker","logs",name}},context.temp_allocator)
            log.infof("the node's output:\n%s%s",logs,logs_err)
            subprocess.exec({command={"docker","stop","-t","2",name}},context.temp_allocator)
        }
    }
    get :: proc(origin,path:string,roots:[]^x509.Certificate,port:int,cookie:="",method:="GET",body:="") -> (r:tls.Response,why:string) {
        return client_call(origin,method,path,transmute([]u8)body,roots,cookie,"127.0.0.1",port)
    }
    answered:=false
    for _ in 0..<150 {
        if r,why:=get(origin,"/api/node",roots,dial_port);why=="" && r.status==200 {
            answered=true
            break
        }
        time.sleep(200*time.Millisecond)
        free_all(context.temp_allocator)
    }
    if !testing.expect(t,answered,"the node answers over HTTPS with the authority's certificate") {return}
    P,Q:=hex(f.public[:]),hex(f.private[:])
    r,why:=get(origin,fmt.tprintf("/api/projects/%s",P),roots,dial_port)
    testing.expectf(t,why=="" && r.status==200 && strings.contains(string(r.body),"Welcome to the site"),"the public view: %d %s %s",r.status,why,string(r.body))
    testing.expect(t,strings.contains(r.headers,"Strict-Transport-Security"),"HTTPS answers carry HSTS")
    r,_=get(origin,fmt.tprintf("/api/projects/%s",Q),roots,dial_port)
    testing.expect(t,r.status==404,"the private project is not shown to anyone")

    // A member's session: alice's device approves the login.
    r,why=get(origin,"/api/approvals",roots,dial_port,method="POST",body=`{"kind":"login"}`)
    Approval_Answer :: struct {id,secret:string}
    ap:Approval_Answer
    if !json_read(t,{status=r.status,body=string(r.body)},&ap) {return}
    r,_=get(origin,fmt.tprintf("/api/approvals/%s",ap.id),roots,dial_port)
    ask:Approval_Ask
    if !json_read(t,{status=r.status,body=string(r.body)},&ask) {return}
    body,_,fail_why:=approve_answer(&f.alice,&ask,origin)
    if !testing.expectf(t,fail_why=="","%s: %v %s",fail_why,ask,origin) {return}
    r,_=get(origin,fmt.tprintf("/api/approvals/%s",ap.id),roots,dial_port,method="POST",body=string(body))
    testing.expectf(t,r.status==200,"the device's approval: %d %s",r.status,string(r.body))
    r,_=get(origin,fmt.tprintf("/api/approvals/%s/state",ap.id),roots,dial_port,method="POST",body=fmt.tprintf(`{{"secret":"%s"}}`,ap.secret))
    cookie:=""
    if at:=strings.index(r.headers,COOKIE+"=");at>=0 {
        rest:=r.headers[at:]
        cookie=rest[:strings.index_byte(rest,';')]
    }
    if !testing.expect(t,cookie!="","the browser's session") {return}
    r,_=get(origin,fmt.tprintf("/api/projects/%s",Q),roots,dial_port,cookie)
    testing.expectf(t,r.status==200 && strings.contains(string(r.body),"vault"),"the member view of the private project: %d %s",r.status,string(r.body))
    r,_=get(origin,fmt.tprintf("/api/proposals/%s",hex(f.proposal[:])),roots,dial_port,cookie)
    testing.expectf(t,r.status==200 && strings.contains(string(r.body),"Rewrite a"),"the member view of a proposal: %d",r.status)
}
