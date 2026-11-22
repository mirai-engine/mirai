package tls

import "core:crypto/x509"
import "core:math/rand"
import "core:mem"
import "core:testing"

// A CA and the leaves it issues: a.test and b.test for any protocol, and a credential that
// answers acme-tls/1 for a.test.
Test_Pki :: struct {
    ca,a,b,challenge:Test_Identity,
    credentials:[3]Credential,
    roots:[1]^x509.Certificate,
}

test_pki :: proc(t:^testing.T,p:^Test_Pki) -> bool {
    if !test_identity(t,&p.ca,{"Test CA"},authority=true) {return false}
    if !test_identity(t,&p.a,{"a.test"},&p.ca) {return false}
    if !test_identity(t,&p.b,{"b.test","*.b.test"},&p.ca) {return false}
    if !test_identity(t,&p.challenge,{"a.test"},alpn="acme-tls/1") {return false}
    p.credentials={p.challenge.credential,p.a.credential,p.b.credential}
    p.roots={&p.ca.certificate}
    return true
}

test_pki_destroy :: proc(p:^Test_Pki) {
    test_identity_destroy(&p.challenge)
    test_identity_destroy(&p.b)
    test_identity_destroy(&p.a)
    test_identity_destroy(&p.ca)
}

// Moves what each end has to send to the other, at most chunk bytes per receive, until neither
// moves anything. The first error of either end, if any.
pump :: proc(client,server:^Conn,chunk:=max(int)) -> (err:Error) {
    for {
        moved:=false
        for pair in ([2][2]^Conn{{client,server},{server,client}}) {
            from,to:=pair[0],pair[1]
            out:=pending(from)
            if len(out)==0 {continue}
            taken,e:=receive(to,out[:min(len(out),chunk)])
            sent(from,taken)
            if taken>0 {moved=true}
            if e!=nil && err==nil {err=e}
        }
        if !moved {return}
    }
}

// Writes all of data from one end and reads it at the other.
transfer :: proc(t:^testing.T,from,to:^Conn,data:[]u8,chunk:int) -> bool {
    received:=make([]u8,len(data))
    defer delete(received)
    written,got:=0,0
    for steps:=0;got<len(data);steps+=1 {
        if steps>len(data)*4+1000 {return testing.expect(t,false,"the transfer stalls")}
        n,e:=write(from,data[written:])
        if !testing.expect_value(t,e,Error.None) {return false}
        written+=n
        out:=pending(from)
        taken,re:=receive(to,out[:min(len(out),chunk)])
        if !testing.expect_value(t,re,Error.None) {return false}
        sent(from,taken)
        m,_:=read(to,received[got:])
        got+=m
    }
    return testing.expect(t,string(received)==string(data),"the data arrives changed")
}

@(test)
tls13_handshake_and_records_round_trip_in_memory :: proc(t:^testing.T) {
    p:Test_Pki
    if !test_pki(t,&p) {return}
    defer test_pki_destroy(&p)
    Case :: struct {
        name:string,
        suite:Suite,
        client_groups,server_groups:Groups,
        client_alpn,server_alpn:[]string,
        host,alpn:string,
        retry:bool,
        size,chunk:int,
    }
    cases:=[]Case{
        {name="aes128 x25519",suite=.AES_128_GCM_SHA256,host="a.test",size=1000},
        {name="aes256 p256",suite=.AES_256_GCM_SHA384,client_groups={.P256},host="a.test",size=1000},
        {name="chacha20 x25519",suite=.CHACHA20_POLY1305_SHA256,host="a.test",size=1000},
        {name="retry to p256",suite=.AES_128_GCM_SHA256,server_groups={.P256},host="a.test",retry=true,size=1000},
        {name="retry with chacha20",suite=.CHACHA20_POLY1305_SHA256,server_groups={.P256},host="a.test",retry=true,size=100},
        {name="sni picks b",suite=.AES_256_GCM_SHA384,host="b.test",size=100},
        {name="sni wildcard",suite=.AES_128_GCM_SHA256,host="www.b.test",size=100},
        {name="alpn http/1.1",suite=.AES_128_GCM_SHA256,client_alpn={"h2","http/1.1"},server_alpn={"http/1.1","acme-tls/1"},host="b.test",alpn="http/1.1",size=100},
        {name="alpn acme-tls/1 takes the challenge",suite=.AES_128_GCM_SHA256,client_alpn={"acme-tls/1"},server_alpn={"http/1.1","acme-tls/1"},host="a.test",alpn="acme-tls/1",size=10},
        {name="large records",suite=.AES_256_GCM_SHA384,host="a.test",size=300_000},
        {name="fragmented by one byte",suite=.CHACHA20_POLY1305_SHA256,host="a.test",size=20_000,chunk=1},
        {name="fragmented by 7 bytes after a retry",suite=.AES_128_GCM_SHA256,server_groups={.P256},host="b.test",retry=true,size=40_000,chunk=7},
    }
    for c in cases {
        roots:=p.roots[:]
        if c.alpn=="acme-tls/1" {roots=[]^x509.Certificate{&p.challenge.certificate}}
        client_config:=Config{suites={c.suite},groups=c.client_groups,alpn=c.client_alpn,host=c.host,roots=roots}
        server_config:=Config{groups=c.server_groups,alpn=c.server_alpn,credentials=p.credentials[:]}
        if c.alpn!="acme-tls/1" {server_config.credentials=p.credentials[1:]}
        server,serr:=create(server_config,.Server)
        if !testing.expect_value(t,serr,Error.None) {return}
        defer destroy(server)
        client,cerr:=create(client_config,.Client)
        if !testing.expect_value(t,cerr,Error.None) {return}
        defer destroy(client)
        chunk:=c.chunk if c.chunk>0 else max(int)
        if !testing.expectf(t,pump(client,server,chunk)==nil,"%s: the handshake fails",c.name) {continue}
        testing.expectf(t,connected(client) && connected(server),"%s: not connected",c.name)
        testing.expectf(t,client.suite==c.suite && server.suite==c.suite,"%s: suite %v",c.name,server.suite)
        testing.expectf(t,client.retried==c.retry && server.retried==c.retry,"%s: retry %v",c.name,server.retried)
        testing.expectf(t,protocol(client)==c.alpn && protocol(server)==c.alpn,"%s: protocol %q",c.name,protocol(server))
        testing.expectf(t,server_name(server)==c.host,"%s: server name %q",c.name,server_name(server))
        testing.expectf(t,mem.check_zero(mem.ptr_to_bytes(&client.key_share)) && mem.check_zero(mem.ptr_to_bytes(&server.key_share)),"%s: a key share outlives the key exchange",c.name)
        data:=make([]u8,c.size)
        defer delete(data)
        for &b in data {b=u8(rand.uint32())}
        transfer(t,client,server,data,chunk)
        transfer(t,server,client,data,chunk)

        // KeyUpdate asked of the server: both directions change keys and data still flows.
        before_client,before_server:=client.write.epoch,server.write.epoch
        testing.expect_value(t,key_update(client,true),Error.None)
        testing.expect_value(t,pump(client,server,chunk),Error.None)
        testing.expectf(t,client.write.epoch==before_client+1 && server.write.epoch==before_server+1,"%s: keys not updated",c.name)
        transfer(t,client,server,data[:min(len(data),5000)],chunk)
        transfer(t,server,client,data[:min(len(data),5000)],chunk)

        close(client)
        testing.expect_value(t,pump(client,server,chunk),Error.None)
        buffer:[16]u8
        _,rerr:=read(server,buffer[:])
        testing.expectf(t,rerr==.Closed,"%s: close_notify gives %v",c.name,rerr)
        _,werr:=write(client,{1})
        testing.expect_value(t,werr,Error.Closed)
    }
}
