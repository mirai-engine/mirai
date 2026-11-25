package tls

import "core:bytes"
import "core:fmt"
import "core:crypto/ecdsa"
import "core:crypto/x509"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/subprocess"

// A P-256 key and a certificate of it for names, issued by issuer or self-signed.
Test_Identity :: struct {
    key:ecdsa.Private_Key,
    der:[]u8,
    certificate:x509.Certificate,
    credential:Credential,
}

test_identity :: proc(t:^testing.T,id:^Test_Identity,names:[]string,issuer:^Test_Identity=nil,authority:=false,alpn:="",extensions:[][]u8={},not_after:=time.Time{}) -> bool {
    if !ecdsa.private_key_generate(&id.key,.SECP256R1) {return false}
    public:[65]u8
    ecdsa.private_key_public_bytes(&id.key,public[:])
    now:=time.now()
    err:Error
    id.der,err=certificate_make({
        names=names,
        public_key=public[:],
        not_before=time.time_add(now,-time.Hour),
        not_after=not_after if not_after!=({}) else time.time_add(now,90*24*time.Hour),
        issuer=&issuer.key if issuer!=nil else &id.key,
        issuer_name=issuer!=nil ? issuer.certificate.dns_names[0] : "",
        authority=authority,
        extensions=extensions,
    })
    if !testing.expect_value(t,err,Error.None) {return false}
    perr:x509.Error
    id.certificate,perr=x509.parse(id.der)
    if !testing.expect_value(t,perr,x509.Error.None) {return false}
    chain:=[][]u8{id.der}
    if issuer!=nil {chain=[][]u8{id.der,issuer.der}}
    owned,cerr:=make([][]u8,len(chain))
    if cerr!=nil {return false}
    copy(owned,chain)
    id.credential,err=credential_init(owned,&id.key,alpn)
    return testing.expect_value(t,err,Error.None)
}

test_identity_destroy :: proc(id:^Test_Identity) {
    delete(id.credential.chain)
    credential_destroy(&id.credential)
    x509.destroy(&id.certificate)
    delete(id.der)
    ecdsa.private_key_clear(&id.key)
}

@(test)
tls13_interoperates_with_system_tools :: proc(t:^testing.T) {
    id:Test_Identity
    if !test_identity(t,&id,{"localhost"}) {return}
    defer test_identity_destroy(&id)
    config:=Config{credentials={id.credential},alpn={"http/1.1"}}
    // Without curl the test is skipped, which is no pass.
    curl,found:=tool_path("curl")
    if !found {
        testing.expect(t,false,"skipped: curl is not installed")
        return
    }
    defer delete(curl)
    {
        served:=false
        // A curl with several TLS libraries (macOS) refuses --tlsv1.3 on its default one; its
        // OpenSSL-compatible one negotiates TLS 1.3, the only version this server speaks.
        flags:=[][]string{{"--tlsv1.3"},{"--tlsv1.2","--tls-max","1.3"}}
        for flag in flags {
            command:=make([dynamic]string,context.temp_allocator)
            append(&command,curl,"-sv","-k","--max-time","20")
            append(&command,..flag)
            port,listener,ok:=test_listen(t)
            if !ok {return}
            append(&command,strings.concatenate({"https://localhost:",port,"/"},context.temp_allocator))
            output,exit:=serve_tool(t,listener,command[:],config,nil)
            defer delete(output)
            if exit==4 {continue} // the option is not built in
            testing.expect_value(t,exit,0)
            tls13_ok:=bytes.contains(output,transmute([]u8)string("TLSv1.3")) || (ODIN_OS==.Windows && bytes.contains(output,transmute([]u8)string("schannel:")))
            testing.expectf(t,tls13_ok,"curl did not report TLS 1.3:\n%s",string(output))
            testing.expectf(t,bytes.contains(output,transmute([]u8)string("hello from mirai")),"curl did not receive the body:\n%s",string(output))
            log.infof("curl %v: %s",flag,tls_line(output))
            served=true
            break
        }
        testing.expect(t,served,"curl has no option that allows TLS 1.3")
    }
    if openssl,found:=tool_path("openssl");found {
        defer delete(openssl)
        port,listener,ok:=test_listen(t)
        if !ok {return}
        command:=[]string{openssl,"s_client","-tls1_3","-connect",strings.concatenate({"127.0.0.1:",port},context.temp_allocator),"-servername","localhost","-alpn","http/1.1","-ign_eof"}
        output,exit:=serve_tool(t,listener,command,config,transmute([]u8)string("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        defer delete(output)
        testing.expect_value(t,exit,0)
        testing.expectf(t,bytes.contains(output,transmute([]u8)string("TLSv1.3")),"openssl did not report TLS 1.3:\n%s",string(output))
        testing.expectf(t,bytes.contains(output,transmute([]u8)string("hello from mirai")),"openssl did not receive the body:\n%s",string(output))
        log.infof("openssl s_client: %s",tls_line(output))
    } else {
        log.info("openssl is not installed: only curl ran")
    }
}

// The line of a tool's output that names TLS 1.3.
@(private="file")
tls_line :: proc(output:[]u8) -> string {
    for line in strings.split_lines(string(output),context.temp_allocator) {
        if strings.contains(line,"TLSv1.3") {return line}
    }
    return ""
}

@(private="file")
tool_path :: proc(name:string) -> (path:string,found:bool) {
    search:=os.get_env("PATH",context.temp_allocator)
    sep:=";" when ODIN_OS==.Windows else ":"
    exe:=strings.concatenate({name,".exe"},context.temp_allocator) when ODIN_OS==.Windows else name
    for folder in strings.split(search,sep,context.temp_allocator) {
        if folder=="" {continue}
        candidate:=strings.concatenate({folder,"/",exe},context.temp_allocator)
        if os.is_file(candidate) {return strings.clone(candidate),true}
    }
    return "",false
}

@(private="file")
test_listen :: proc(t:^testing.T) -> (port:string,listener:net.TCP_Socket,ok:bool) {
    err:net.Network_Error
    listener,err=net.listen_tcp({address=net.IP4_Loopback,port=0})
    if !testing.expect_value(t,err,nil) {return}
    endpoint,eerr:=net.bound_endpoint(listener)
    if !testing.expect_value(t,eerr,nil) {return}
    if !testing.expect_value(t,net.set_blocking(listener,false),nil) {return}
    return fmt.tprintf("%d",endpoint.port),listener,true
}

// Runs command against one TLS connection served on listener, which answers a request with a
// short HTTP response and closes. Gives what the tool wrote and its exit code.
@(private="file")
serve_tool :: proc(t:^testing.T,listener:net.TCP_Socket,command:[]string,config:Config,stdin:[]u8) -> (output:[]u8,exit:int) {
    collected:[dynamic]u8
    defer net.close(listener)
    process,err:=subprocess.start({command=command},pipes=.Merged)
    if !testing.expect_value(t,err,nil) {return nil,-1}
    defer subprocess.release(&process)
    if stdin!=nil {
        _=subprocess.write(&process,stdin)
        subprocess.stdin_close(&process)
    }
    conn,cerr:=create(config,.Server)
    if !testing.expect_value(t,cerr,Error.None) {return nil,-1}
    defer destroy(conn)
    deadline:=time.time_add(time.now(),20*time.Second)
    socket:net.TCP_Socket
    accepted,answered,finished:=false,false,false
    request:[dynamic]u8
    defer delete(request)
    buffer:[4096]u8
    for time.diff(time.now(),deadline)>0 {
        idle:=true
        if count,_:=subprocess.read(&process,.Stdout,buffer[:]);count>0 {
            append(&collected,..buffer[:count])
            idle=false
        }
        if process.stdout==nil {break}
        if finished {
        } else if !accepted {
            s,_,aerr:=net.accept_tcp(listener)
            if aerr==nil {
                socket,accepted=s,true
                _=net.set_blocking(socket,false)
            }
        } else {
            n,rerr:=net.recv_tcp(socket,buffer[:])
            if rerr==nil && n>0 {
                idle=false
                for at:=0;at<n; {
                    taken,e:=receive(conn,buffer[at:n])
                    at+=taken
                    plain:[4096]u8
                    for {
                        m,_:=read(conn,plain[:])
                        if m==0 {break}
                        append(&request,..plain[:m])
                    }
                    if e!=nil {break}
                }
            }
            if !answered && bytes.contains(request[:],transmute([]u8)string("\r\n\r\n")) {
                _,_=write(conn,transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\nhello from mirai"))
                close(conn)
                answered=true
            }
            for out:=pending(conn);len(out)>0;out=pending(conn) {
                m,serr:=net.send_tcp(socket,out)
                if serr!=nil && serr!=.Would_Block {break}
                sent(conn,m)
                if m==0 {break}
            }
            if answered && len(pending(conn))==0 {
                net.close(socket)
                finished=true
            }
        }
        if idle {time.sleep(time.Millisecond)}
    }
    state,_:=subprocess.wait(&process,5*time.Second)
    if !state.exited {return collected[:],-1}
    return collected[:],state.exit_code
}
