package hub

import "core:bufio"
import "core:crypto/ed25519"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:kai"
import "mirai:store"

// The commands of a node, which `mirai kai` and the headless mirai-kai
// executable run alike: serve, pair join for the node itself, and web approve
// for a member's device.

SERVE_USAGE :: "kai serve --mode relay|seed|seed+ddc --store <folder> [--port N] [--ddc-quota BYTES] [--domain NAME ...] [--https PORT] [--http PORT] [--no-sandbox]"
NODE_PORT :: 47914 // the UDP port of a node unless --port says otherwise

// The TCP ports a confined node may bind and connect to.
Sandbox_Ports :: struct {bind,connect:[]int}

// Runs the node until the process ends. program names the executable in
// what it prints.
serve_command :: proc(program:string,args:[]string,store_root:="") -> int {
    root,mode,port_text,quota_text,http_text,https_text:=store_root,"","","","",""
    domains:=make([dynamic]string,context.temp_allocator)
    no_sandbox:=false
    for i:=0;i<len(args);i+=1 {
        a:=args[i]
        if a=="--no-sandbox" {
            no_sandbox=true
            continue
        }
        value:string
        if i+1<len(args) {value=args[i+1]}
        switch a {
        case "--mode": mode=value
        case "--store": root=value
        case "--port": port_text=value
        case "--ddc-quota": quota_text=value
        case "--domain": append(&domains,strings.to_lower(value,context.temp_allocator))
        case "--http": http_text=value
        case "--https": https_text=value
        case:
            fmt.eprintfln("%s kai serve: %q is not an option of it.\nUsage: %s %s",program,a,program,SERVE_USAGE)
            return 2
        }
        if value=="" {
            fmt.eprintfln("%s kai serve: %s needs a value",program,a)
            return 2
        }
        i+=1
    }
    modes:kai.Node_Modes
    switch mode {
    case "relay": modes={.Relay}
    case "seed": modes={.Relay,.Seed}
    case "seed+ddc": modes={.Relay,.Seed,.DDC}
    case:
        fmt.eprintfln("%s kai serve: --mode is relay, seed or seed+ddc.\nUsage: %s %s",program,program,SERVE_USAGE)
        return 2
    }
    if root=="" {
        fmt.eprintfln("%s kai serve: --store names the folder of the node's store",program)
        return 2
    }
    port,http_port,https_port:=NODE_PORT,0,0
    ok:bool
    if port_text!="" {
        if port,ok=port_parse(port_text);!ok {fmt.eprintfln("%s kai serve: --port is a UDP port",program);return 2}
    }
    if http_text!="" {
        if http_port,ok=port_parse(http_text);!ok || http_port==0 {fmt.eprintfln("%s kai serve: --http is a TCP port on 127.0.0.1",program);return 2}
    }
    if https_text!="" {
        if https_port,ok=port_parse(https_text);!ok || https_port==0 {fmt.eprintfln("%s kai serve: --https is a TCP port",program);return 2}
        if len(domains)==0 {fmt.eprintfln("%s kai serve: --https needs --domain, the names of its certificate",program);return 2}
    }
    if len(domains)>0 && https_port==0 {https_port=443}
    for d in domains {
        if !domain_valid(d) {fmt.eprintfln("%s kai serve: %q is no DNS name: give the public name of this machine",program,d);return 2}
    }
    quota:i64
    if quota_text!="" {
        if .DDC not_in modes {fmt.eprintfln("%s kai serve: --ddc-quota is for --mode seed+ddc",program);return 2}
        if quota,ok=bytes_parse(quota_text);!ok || quota<=0 {fmt.eprintfln("%s kai serve: --ddc-quota is a size in bytes, with K, M, G or T after it if you like",program);return 2}
    }
    web:=http_port!=0 || https_port!=0
    if web && .Seed not_in modes {
        fmt.eprintfln("%s kai serve: a relay holds logs only; the web view needs --mode seed",program)
        return 2
    }

    m:=new(kai.Machine)
    if e:=kai.machine_open(m,root);e!=.None {
        fmt.eprintfln("%s kai serve: %s",program,m.why)
        return 1
    }
    defer {
        kai.machine_close(m)
        free(m)
    }
    print :: proc(_:rawptr,text:string) {
        t:=time.now()
        h,mi,s:=time.clock(t)
        fmt.printfln("%02d:%02d:%02d %s",h,mi,s,text)
    }
    r:=new(kai.Runner)
    defer free(r)
    // The hub's HTTPS listener on the relay's port hands the relay's connections over.
    tcp_port:=https_port==kai.RELAY_TCP_PORT?0:kai.RELAY_TCP_PORT
    if e:=kai.runner_start(r,{machine=m,port=port,modes=modes,control=true,ddc_quota=quota,tcp_port=tcp_port,event={procedure=print}});e!=.None {
        fmt.eprintfln("%s kai serve: %s",program,m.why)
        return 1
    }
    defer kai.runner_stop(r)
    key:=m.identity.key
    fmt.printfln("Kai node %s (%s) on UDP port %d, serving %d orgs.",short_hex(key[:]),mode,kai.runner_port(r),len(m.orgs))
    if tcp:=kai.runner_tcp_port(r);tcp!=0 {fmt.printfln("Relay over TCP on port %d for devices whose UDP is blocked.",tcp)}
    if len(m.orgs)==0 {
        fmt.printfln("It serves no org yet. To pair it, an admin of the org runs on their machine\n  mirai kai pair offer node --org <org> --modes %s\nthen here, while this runs:\n  %s kai pair join <ticket> --store %s\nand approves on their machine with mirai kai pair approve when both show the same code.",mode=="relay"?"relay":mode=="seed"?"relay,seed":"relay,seed,ddc",program,root)
    }
    h:=new(Hub)
    defer free(h)
    if web {
        rp:="localhost"
        if len(domains)>0 {rp=domains[0]}
        why:=hub_start(h,{runner=r,rp_id=rp,http_port=http_port,https_port=https_port,domains=domains[:],event={procedure=print}})
        if why!="" {
            fmt.eprintfln("%s kai serve: %s",program,why)
            return 1
        }
        if h.has_plain {fmt.printfln("Web view on http://127.0.0.1:%d (loopback only; passkeys need HTTPS).",h.http_port)}
        if h.has_secure {fmt.printfln("Web view on %s.",h.origin)}
    }
    defer if web {hub_stop(h)}
    // ACME's directory is reached on 443, and the resolver may ask over TCP.
    bind:=[2]int{h.http_port,h.https_port}
    connect:=[2]int{h.certs.acme?443:0,h.certs.acme?53:0}
    applied,why:=false,"--no-sandbox"
    if !no_sandbox {applied,why=sandbox_apply(root,{bind[:],connect[:]})}
    switch {
    case applied:
        fmt.println("Sandbox: the store's folder is all it may write; its TCP ports and system calls are the ones it uses.")
    case ODIN_OS==.Linux && !no_sandbox:
        fmt.eprintfln("%s kai serve: the sandbox does not apply (%s): run it on a kernel with Landlock and seccomp, or start it with --no-sandbox to serve unconfined",program,why)
        return 1
    case:
        fmt.printfln("Sandbox: none (%s).",why)
    }
    stop:=false
    if web {
        hub_run(h,&stop)
    } else {
        kai.runner_run(r,&stop,false)
    }
    return 0
}

@(private)
port_parse :: proc(text:string) -> (port:int,ok:bool) {
    n,parsed:=strconv.parse_int(text,10)
    if !parsed || n<0 || n>65535 {return}
    return n,true
}

// A size in bytes, with a binary unit after it if one likes: 512M, 20G.
bytes_parse :: proc(text:string) -> (n:i64,ok:bool) {
    if text=="" {return}
    digits,shift:=text,uint(0)
    switch text[len(text)-1] {
    case 'K','k': shift=10
    case 'M','m': shift=20
    case 'G','g': shift=30
    case 'T','t': shift=40
    }
    if shift>0 {digits=text[:len(text)-1]}
    value,parsed:=strconv.parse_i64(digits,10)
    if !parsed || value<0 || value>max(i64)>>shift {return}
    return value<<shift,true
}

@(private)
domain_valid :: proc(name:string) -> bool {
    if len(name)==0 || len(name)>kai.RP_ID_MAX || name[0]=='.' || name[len(name)-1]=='.' {return false}
    for c in transmute([]u8)name {
        switch c {
        case 'a'..='z','0'..='9','-','.':
        case: return false
        }
    }
    return strings.index(name,"..")<0
}

// The pairing of the node itself, through the runner of its store.
join_command :: proc(program:string,args:[]string,store_root:="") -> int {
    root,name,ticket:=store_root,"node",""
    for i:=0;i<len(args);i+=1 {
        switch {
        case args[i]=="--store" && i+1<len(args): root=args[i+1];i+=1
        case args[i]=="--name" && i+1<len(args): name=args[i+1];i+=1
        case ticket=="" && !strings.has_prefix(args[i],"--"): ticket=args[i]
        case:
            fmt.eprintfln("Usage: %s kai pair join <ticket> --store <folder> [--name N]",program)
            return 2
        }
    }
    if ticket=="" || root=="" {
        fmt.eprintfln("Usage: %s kai pair join <ticket> --store <folder> [--name N]",program)
        return 2
    }
    c:kai.Control
    if kai.control_open(&c,root)!=.None {
        fmt.eprintfln("%s kai pair join: no node runs for that store: start %s kai serve first",program,program)
        return 1
    }
    defer kai.control_close(&c)
    if kai.control_pair_join(&c,ticket,name)!=.None {
        fmt.eprintfln("%s kai pair join: %s",program,c.why)
        return 1
    }
    shown:=false
    for {
        progress,e:=kai.control_pair_progress(&c)
        if e!=.None {
            fmt.eprintfln("%s kai pair join: %s",program,c.why)
            return 1
        }
        if progress.code!="" && !shown {
            fmt.printfln("Code %s: the admin approves on their machine if it shows the same.",progress.code)
            shown=true
        }
        #partial switch progress.phase {
        case .Approved:
            fmt.println("Paired: the node serves the org now.")
            return 0
        case .Denied,.Failed:
            fmt.eprintfln("%s kai pair join: %s",program,progress.why)
            return 1
        }
        free_all(context.temp_allocator)
        time.sleep(200*time.Millisecond)
    }
}

// --- mirai kai web approve ---

WEB_USAGE :: "kai web approve <link> [--yes] [--store S]"

// What an approval asks, as GET /api/approvals/{id} answers it.
Approval_Ask :: struct {
    kind,state,rp_id,origin,challenge,user,type,log,body,credential,cose,linked:string,
    entries:[]string, // device: the user's log once it names this machine
}

// The link a browser shows: its hub's origin and the approval's id.
link_parse :: proc(link:string) -> (origin,id:string,ok:bool) {
    rest:=strings.trim_space(link)
    if !strings.has_prefix(rest,"kai://approve?") {return}
    rest=rest[len("kai://approve?"):]
    for part in strings.split_iterator(&rest,"&") {
        eq:=strings.index_byte(part,'=')
        if eq<0 {return}
        value,decoded:=percent_decode(part[eq+1:])
        if !decoded {return}
        switch part[:eq] {
        case "origin": origin=value
        case "id": id=value
        }
    }
    raw:[16]u8
    if !hex_parse(id,raw[:]) {return}
    if _,valid:=origin_parse(origin);!valid {return}
    return origin,id,true
}

// What a device answers to an approval: the JSON body of its POST, signed
// with the device's key; summary says what it signs, for the person to see.
// Without sign it only checks the approval and says what it would sign.
approve_answer :: proc(m:^kai.Machine,ask:^Approval_Ask,origin:string,sign:=true) -> (body:[]u8,summary,why:string) {
    o,_:=origin_parse(origin)
    if ask.origin!=origin || (o.secure && ask.rp_id!=o.host) {return nil,"","the hub answers for another origin than the link's: do not approve"}
    j:=json_make()
    json_object(&j)
    switch ask.kind {
    case "login":
        challenge,ok:=base64_parse(ask.challenge,32)
        if !ok || len(challenge)!=32 {return nil,"","the hub's challenge does not read"}
        summary=fmt.tprintf("let a browser on %s sign in as this device's user",origin)
        if !sign {return nil,summary,""}
        c:[32]u8
        copy(c[:],challenge)
        signature:=login_signature(&m.identity,ask.rp_id,c)
        key:=m.identity.key
        json_member_hex(&j,"device",key[:])
        json_key(&j,"signature")
        json_base64(&j,signature[:])
    case "device":
        user,uok:=hash_parse(ask.user)
        if !uok {return nil,"","the approval names no user"}
        if m.user!={} {return nil,"","this device belongs to a user already: a browser links only a device with none"}
        code:[9]u8
        summary=fmt.tprintf("link this device to the user %s on %s; the browser must show %s",ask.user[:12],origin,kai.device_link_code(m.identity.key,&code))
        if !sign {return nil,summary,""}
        proof:=kai.device_proof(&m.identity,transmute([32]u8)user)
        name_buffer:[kai.NAME_MAX]u8
        key,dh:=m.identity.key,m.dh.public
        json_member_hex(&j,"device",key[:])
        json_member_hex(&j,"dh",dh[:])
        json_key(&j,"proof")
        json_base64(&j,proof[:])
        json_member_string(&j,"name",kai.device_name_of("",&name_buffer))
    case "entry","passkey":
        user,uok:=hash_parse(ask.user)
        if !uok || user!=m.user {return nil,"","the approval is for another user than this device's"}
        type:kai.Entry_Type
        log:kai.Log_Id
        body_bytes:[]u8
        if ask.kind=="passkey" {
            credential,cok:=base64_parse(ask.credential,255)
            cose,kok:=base64_parse(ask.cose,kai.COSE_KEY_MAX)
            if !cok || !kok {return nil,"","the passkey's fields do not read"}
            made,e:=kai.web_key_add_body(credential,cose,ask.rp_id)
            if e!=.None {return nil,"","the passkey is not one Kai takes"}
            type,log,body_bytes=.Web_Key_Add,m.user,made
            summary=fmt.tprintf("add a passkey of %s to this device's user",ask.rp_id)
        } else {
            types:=TYPE_TEXT
            for name,t in types {
                if name==ask.type && t in WRITABLE {type=t}
            }
            lok:bool
            log,lok=hash_parse(ask.log)
            bok:bool
            body_bytes,bok=base64_parse(ask.body,kai.ENTRY_BODY_MAX)
            if type==.None || !lok || !bok || !kai.body_valid(type,body_bytes) {return nil,"","the write does not read as one a browser asks for"}
            summary=fmt.tprintf("sign %s in log %s from %s",ask.type,ask.log[:12],origin)
        }
        kind,_:=kai.entry_log_kind(type)
        l:kai.Log
        kai.log_init(&l,log,context.temp_allocator)
        if kai.log_open(&m.store,&l,log,kind)!=.None {return nil,"","this device's store does not hold that log: let its agent sync first"}
        if !sign {return nil,summary,""}
        ctx,org_ctx:=kai.machine_entry_ctx(m,&l)
        address,e:=kai.log_append(&l,type,body_bytes,&m.identity,time.now()._nsec,ctx,org_ctx)
        if e!=.None {return nil,"",kai.error_text(e)}
        if _,se:=kai.log_save(&m.store,&l);se!=.None || store.commit(&m.store)!=.None {return nil,"","this device's store does not take the entry"}
        name:[64]u8
        if m.changed.procedure!=nil {m.changed.procedure(m.changed.data,kai.log_namespace(kind),store.hex(log,&name))}
        k:=kai.log_find(&l,address)
        json_key(&j,"entry")
        json_base64(&j,l.items[k].bytes)
    case:
        return nil,"","the hub asks for an approval of a kind this tool does not know"
    }
    json_end_object(&j)
    return transmute([]u8)json_text(&j),summary,""
}

login_signature :: proc(identity:^kai.Identity,rp_id:string,challenge:[32]u8) -> (signature:[64]u8) {
    private:ed25519.Private_Key
    if !ed25519.private_key_set_bytes(&private,identity.seed[:]) {return}
    defer ed25519.private_key_clear(&private)
    ed25519.sign(&private,login_message(rp_id,challenge),signature[:])
    return
}

// mirai kai web approve: asks the hub what the link wants, shows it, and
// answers it signed by this device once the person says yes.
web_command :: proc(program:string,args:[]string,store_root:="") -> int {
    if len(args)<2 || args[0]!="approve" {
        fmt.eprintfln("Usage: %s %s",program,WEB_USAGE)
        return 2
    }
    link,yes:="",false
    for a in args[1:] {
        switch {
        case a=="--yes": yes=true
        case link=="": link=a
        case:
            fmt.eprintfln("Usage: %s %s",program,WEB_USAGE)
            return 2
        }
    }
    origin,id,ok:=link_parse(link)
    if !ok {
        fmt.eprintfln("%s kai web approve: the link does not read: copy it whole from the browser, as kai://approve?origin=...&id=...",program)
        return 2
    }
    path:=strings.concatenate({"/api/approvals/",id},context.temp_allocator)
    response,why:=client_call(origin,"GET",path,nil)
    if why!="" || response.status!=200 {
        if why=="" {why=fmt.tprintf("the hub answered %d: %s",response.status,string(response.body))}
        fmt.eprintfln("%s kai web approve: %s",program,why)
        return 1
    }
    ask:Approval_Ask
    if json.unmarshal(response.body,&ask,.JSON,context.temp_allocator)!=nil || ask.state!="waiting" {
        fmt.eprintfln("%s kai web approve: the approval is %s: ask again in the browser",program,ask.state==""?"unreadable":ask.state)
        return 1
    }
    m:=new(kai.Machine,context.temp_allocator)
    if kai.machine_open(m,store_root)!=.None {
        fmt.eprintfln("%s kai web approve: %s",program,m.why)
        return 1
    }
    defer kai.machine_close(m)
    c:kai.Control
    if kai.control_open(&c,m.store.root)==.None {
        m.changed=kai.control_machine_changed(&c)
    }
    defer if m.changed.procedure!=nil {kai.control_close(&c)}
    if m.user=={} && ask.kind!="device" {
        fmt.eprintfln("%s kai web approve: this device has no user: mirai kai identity makes one, or pair it",program)
        return 1
    }
    _,asked,ask_why:=approve_answer(m,&ask,origin,false)
    if ask_why!="" {
        fmt.eprintfln("%s kai web approve: %s",program,ask_why)
        return 1
    }
    if !yes {
        fmt.printf("%s asks this device to %s. Approve? yes/no: ",origin,asked)
        reader:bufio.Reader
        bufio.reader_init(&reader,os.to_stream(os.stdin),allocator=context.temp_allocator)
        line,_:=bufio.reader_read_string(&reader,'\n',context.temp_allocator)
        answer:=strings.to_lower(strings.trim_space(line),context.temp_allocator)
        if answer!="yes" && answer!="y" {
            fmt.println("Not approved.")
            return 1
        }
    }
    body,summary,fail_why:=approve_answer(m,&ask,origin)
    if fail_why!="" {
        fmt.eprintfln("%s kai web approve: %s",program,fail_why)
        return 1
    }
    response,why=client_call(origin,"POST",path,body)
    if why!="" || response.status!=200 {
        if why=="" {why=fmt.tprintf("the hub answered %d: %s",response.status,string(response.body))}
        fmt.eprintfln("%s kai web approve: %s",program,why)
        return 1
    }
    if ask.kind=="device" {
        if why=device_link_wait(m,origin,path,ask.user);why!="" {
            fmt.eprintfln("%s kai web approve: %s",program,why)
            return 1
        }
        fmt.println("Linked: this device is the user's now. It has no recovery key yet: mirai kai identity recovery sets the first.")
        return 0
    }
    fmt.printfln("Approved: %s.",summary)
    return 0
}

DEVICE_LINK_SECONDS :: 600

// Waits for the browser to sign this device's Device_Add, then takes the
// user's log it answers with: why it did not, or "".
device_link_wait :: proc(m:^kai.Machine,origin,path,user_text:string) -> string {
    user,_:=hash_parse(user_text)
    end:=time.tick_now()
    for time.duration_seconds(time.tick_since(end))<DEVICE_LINK_SECONDS {
        time.sleep(2*time.Second)
        response,why:=client_call(origin,"GET",path,nil)
        if why!="" {return why}
        ask:Approval_Ask
        if response.status!=200 || json.unmarshal(response.body,&ask,.JSON,context.temp_allocator)!=nil {return fmt.tprintf("the hub answered %d: %s",response.status,string(response.body))}
        if ask.state=="expired" || ask.state=="denied" {return fmt.tprintf("the link was %s: ask a new one in the browser",ask.state)}
        if ask.linked=="" {continue}
        return device_link_take(m,user,ask.entries)
    }
    return "the browser did not link the device in time: ask a new link"
}

// Takes the user's log the hub gave once it names this device.
device_link_take :: proc(m:^kai.Machine,user:kai.Log_Id,entries:[]string) -> string {
    list:=make([dynamic][]u8,context.temp_allocator)
    for text in entries {
        bytes,ok:=base64_parse(text,kai.ENTRY_BODY_MAX+4096)
        if !ok {return "an entry of the user's log does not read"}
        append(&list,bytes)
    }
    if kai.machine_user_linked(m,user,list[:])!=.None {return m.why}
    if store.commit(&m.store)!=.None {return "this device's store does not take the user's log"}
    return ""
}
