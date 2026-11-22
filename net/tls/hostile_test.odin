package tls

import "core:crypto/x509"
import "core:math/rand"
import "core:testing"
import "core:time"

// Feeds input until all of it is taken or the connection fails; the error and whether the
// connection queued an alert for its peer.
@(private="file")
feed :: proc(c:^Conn,input:[]u8) -> (err:Error,alerted:bool) {
    at:=0
    for at<len(input) {
        taken,e:=receive(c,input[at:])
        at+=taken
        if e!=nil {return e,len(pending(c))>0}
        if taken==0 {break}
    }
    return nil,false
}

@(private="file")
expect_failure :: proc(t:^testing.T,name:string,c:^Conn,input:[]u8,want:Error,loc:=#caller_location) {
    err,alerted:=feed(c,input)
    testing.expectf(t,err==want,"%s: %v, want %v",name,err,want,loc=loc)
    testing.expectf(t,c.state==.Failed && alerted,"%s: no alert",name,loc=loc)
}

// A plaintext record of content around bytes.
@(private="file")
record_of :: proc(content:Content,bytes:[]u8,allocator:=context.temp_allocator) -> []u8 {
    r:=make([]u8,HEADER_BYTES+len(bytes),allocator)
    r[0],r[1],r[2],r[3],r[4]=u8(content),3,3,u8(len(bytes)>>8),u8(len(bytes))
    copy(r[HEADER_BYTES:],bytes)
    return r
}

// The first record of what c has to send, and its handshake message.
@(private="file")
first_record :: proc(c:^Conn) -> (record,message:[]u8) {
    out:=pending(c)
    n:=HEADER_BYTES+(int(out[3])<<8|int(out[4]))
    return out[:n],out[HEADER_BYTES:n]
}

// A handshake message cut to its first n bytes of body, with its length fields saying so.
@(private="file")
truncated :: proc(message:[]u8,n:int) -> []u8 {
    m:=make([]u8,4+n,context.temp_allocator)
    copy(m,message[:4+n])
    m[1],m[2],m[3]=u8(n>>16),u8(n>>8),u8(n)
    return record_of(.Handshake,m)
}

@(test)
tls13_refuses_hostile_and_downgraded_input :: proc(t:^testing.T) {
    p:Test_Pki
    if !test_pki(t,&p) {return}
    defer test_pki_destroy(&p)
    server_config:=Config{credentials=p.credentials[1:],alpn={"http/1.1"}}
    client_config:=Config{host="a.test",roots=p.roots[:]}

    // Random bytes: an error, or a record still waiting for its bytes.
    for i in 0..<200 {
        input:=make([]u8,(1 if i%3==0 else 6)+rand.int_max(3000),context.temp_allocator)
        for &b in input {b=u8(rand.uint32())}
        if i%3==1 {input[0],input[1],input[2]=22,3,1}
        if i%3==2 {input[0],input[1],input[2],input[3],input[4]=22,3,1,0,u8(len(input)-5) if len(input)<260 else 255}
        for role in Role {
            c,_:=create(server_config if role==.Server else client_config,role)
            err,_:=feed(c,input)
            waiting:=c.input_len>0 && c.state<.Connected || c.handshake_len>0
            testing.expectf(t,err!=nil || waiting,"random input %d to the %v neither fails nor waits",i,role)
            destroy(c)
        }
    }

    hello_client,_:=create(client_config,.Client)
    defer destroy(hello_client)
    _,hello:=first_record(hello_client)

    // The ClientHello cut at every offset.
    for n in 0..<len(hello)-4 {
        server,_:=create(server_config,.Server)
        err,_:=feed(server,truncated(hello,n))
        testing.expectf(t,err!=nil,"a ClientHello cut at %d is taken",n)
        destroy(server)
    }

    // A ServerHello cut at every offset.
    {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        _,_=feed(server,pending(client))
        _,server_hello:=first_record(server)
        for n in 0..<len(server_hello)-4 {
            c,_:=create(client_config,.Client)
            err,_:=feed(c,truncated(server_hello,n))
            testing.expectf(t,err!=nil,"a ServerHello cut at %d is taken",n)
            destroy(c)
        }
    }

    {
        server,_:=create(server_config,.Server)
        defer destroy(server)
        big:=[]u8{22,3,3,0x40,0x01}
        expect_failure(t,"a plaintext record over 2^14",server,big,.Record_Overflow)
    }
    {
        server,_:=create(server_config,.Server)
        defer destroy(server)
        expect_failure(t,"a handshake message over the limit",server,record_of(.Handshake,{1,0x7f,0xff,0xff,3,3}),.Illegal_Parameter)
    }
    {
        server,_:=create(server_config,.Server)
        defer destroy(server)
        m:=make([]u8,len(hello),context.temp_allocator)
        copy(m,hello)
        m[4+2+32]=33 // the session id is longer than its 32 bytes
        expect_failure(t,"a wrong vector length",server,record_of(.Handshake,m),.Decode)
    }
    {
        // TLS 1.2: no supported_versions. The alert is protocol_version, in the clear.
        tls12:=[]u8{1,0,0,51, 3,3, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
            0, 0,2,0xc0,0x2f, 1,0, 0,8, 0,10,0,4,0,2,0,23}
        server,_:=create(server_config,.Server)
        defer destroy(server)
        expect_failure(t,"a TLS 1.2 ClientHello",server,record_of(.Handshake,tls12),.Protocol_Version)
        testing.expect(t,string(pending(server))=="\x15\x03\x03\x00\x02\x02\x46","not a protocol_version alert")
    }
    {
        server,_:=create(server_config,.Server)
        defer destroy(server)
        expect_failure(t,"Finished before ClientHello",server,record_of(.Handshake,{20,0,0,4,1,2,3,4}),.Unexpected_Message)
    }
    {
        server,_:=create(server_config,.Server)
        defer destroy(server)
        expect_failure(t,"application data before the handshake",server,record_of(.Application_Data,{1,2,3}),.Unexpected_Message)
    }
    {
        server,_:=create(server_config,.Server)
        defer destroy(server)
        expect_failure(t,"ChangeCipherSpec before ClientHello",server,record_of(.Change_Cipher_Spec,{1}),.Unexpected_Message)
    }
    for sentinel in ([2]bool{true,false}) {
        // A server that answers TLS 1.2: with the downgrade sentinel an attack, without it
        // a version this client does not speak.
        sh:=[]u8{2,0,0,38, 3,3, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
            0, 0xc0,0x2f, 0}
        if sentinel {copy(sh[6+24:],"DOWNGRD\x01")}
        client,_:=create(client_config,.Client)
        defer destroy(client)
        expect_failure(t,"a TLS 1.2 ServerHello",client,record_of(.Handshake,sh),.Illegal_Parameter if sentinel else .Protocol_Version)
    }

    // A Finished that does not match, at each end.
    for role in Role {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        _,_=feed(server,pending(client))
        sent(client,len(pending(client)))
        if role==.Client {
            record,_:=first_record(server)
            _,_=feed(client,record)
            sent(server,len(record))
            client.read.secret[0]~=1
            expect_failure(t,"a bad server Finished",client,pending(server),.Decrypt_Error)
        } else {
            server.read.secret[0]~=1
            _,_=feed(client,pending(server))
            sent(server,len(pending(server)))
            expect_failure(t,"a bad client Finished",server,pending(client),.Decrypt_Error)
        }
    }

    // Chains the client refuses.
    stranger:Test_Identity
    if !test_identity(t,&stranger,{"a.test"}) {return}
    defer test_identity_destroy(&stranger)
    expired:Test_Identity
    if !test_identity(t,&expired,{"a.test"},&p.ca,not_after=time.time_add(time.now(),-time.Minute)) {return}
    defer test_identity_destroy(&expired)
    forged_der:=make([]u8,len(p.a.der),context.temp_allocator)
    copy(forged_der,p.a.der)
    forged_der[len(forged_der)-3]~=0x55
    forged,ferr:=credential_init({forged_der},&p.a.key)
    testing.expect_value(t,ferr,Error.None)
    defer credential_destroy(&forged)
    Refusal :: struct {name,host:string,credential:Credential,roots:[]^x509.Certificate,want:Error}
    refusals:=[]Refusal{
        {"an unknown authority","a.test",p.a.credential,{&stranger.certificate},.Unknown_CA},
        {"an expired leaf","a.test",expired.credential,p.roots[:],.Certificate_Expired},
        {"a forged signature","a.test",forged,p.roots[:],.Unknown_CA},
        {"a wrong host name","c.test",p.a.credential,p.roots[:],.Bad_Certificate},
    }
    for r in refusals {
        client,_:=create({host=r.host,roots=r.roots},.Client)
        defer destroy(client)
        credentials:=[]Credential{r.credential}
        server,_:=create({credentials=credentials},.Server)
        defer destroy(server)
        _,_=feed(server,pending(client))
        expect_failure(t,r.name,client,pending(server),r.want)
    }

    // After the handshake: a replayed record, a protected ChangeCipherSpec, a bad KeyUpdate.
    for i in 0..<3 {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        if !testing.expect_value(t,pump(client,server),Error.None) {continue}
        switch i {
        case 0:
            _,_=write(client,{'x'})
            record:=make([]u8,len(pending(client)),context.temp_allocator)
            copy(record,pending(client))
            err,_:=feed(server,record)
            testing.expect_value(t,err,Error.None)
            buffer:[4]u8
            _,_=read(server,buffer[:])
            expect_failure(t,"a replayed record",server,record,.Bad_Record_Mac)
        case 1:
            _=record_seal(client,.Change_Cipher_Spec,{1})
            expect_failure(t,"a protected ChangeCipherSpec",server,pending(client),.Unexpected_Message)
        case 2:
            _=record_seal(client,.Handshake,{24,0,0,1,2})
            expect_failure(t,"a KeyUpdate of 2",server,pending(client),.Illegal_Parameter)
        }
    }

    // Records without application data, in a row, end the connection: KeyUpdates that ask for
    // an answer, empty records and user_canceled alerts.
    for kind in 0..<3 {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        if !testing.expect_value(t,pump(client,server),Error.None) {continue}
        err:Error
        for _ in 0..<IDLE_RECORDS_MAX*4 {
            switch kind {
            case 0: _=key_update(client,true)
            case 1: _=record_seal(client,.Application_Data,{})
            case 2: _=record_seal(client,.Alert,{1,u8(Alert.User_Canceled)})
            }
            if err=pump(client,server);err!=nil {break}
        }
        testing.expectf(t,err==.Unexpected_Message && server.state==.Failed,"idle records of kind %d: %v",kind,err)
    }
    // Data between them keeps the connection.
    {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        if testing.expect_value(t,pump(client,server),Error.None) {
            buffer:[4]u8
            for _ in 0..<IDLE_RECORDS_MAX*4 {
                _=record_seal(client,.Application_Data,{})
                _,_=write(client,{'x'})
                if !testing.expect_value(t,pump(client,server),Error.None) {break}
                _,_=read(server,buffer[:])
            }
        }
    }
    // ChangeCipherSpec once, after the ClientHello.
    {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        err,_:=feed(server,pending(client))
        testing.expect_value(t,err,Error.None)
        err,_=feed(server,record_of(.Change_Cipher_Spec,{1}))
        testing.expect_value(t,err,Error.None)
        expect_failure(t,"a second ChangeCipherSpec",server,record_of(.Change_Cipher_Spec,{1}),.Unexpected_Message)
    }
    // A key used for as many records as its AEAD may protect is used for no more.
    {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        if testing.expect_value(t,pump(client,server),Error.None) {
            client.write.seq=1<<24+1<<23
            server.read.seq=client.write.seq
            client.suite=.CHACHA20_POLY1305_SHA256 // its limit lets the client seal
            _=record_seal(client,.Application_Data,{'x'})
            client.suite=server.suite
            expect_failure(t,"a record past the key's limit",server,pending(client),.Unexpected_Message)
        }
    }

    // Extensions a server sends unasked, or in a message that may not carry them.
    {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        server,_:=create(server_config,.Server)
        defer destroy(server)
        _,_=feed(server,pending(client))
        _,server_hello:=first_record(server)
        Extra :: struct {name:string,message:Message,extension:[]u8,want:Error}
        extras:=[]Extra{
            {"renegotiation_info in ServerHello",.Server_Hello,{0xff,0x01,0,1,0},.Unsupported_Extension},
            {"server_name in ServerHello",.Server_Hello,{0,0,0,0},.Illegal_Parameter},
            {"ALPN in EncryptedExtensions, not offered",.Encrypted_Extensions,{0,16,0,5,0,3,2,'h','2'},.Unsupported_Extension},
            {"key_share in EncryptedExtensions",.Encrypted_Extensions,{0,51,0,0},.Illegal_Parameter},
        }
        for x in extras {
            c,_:=create(client_config,.Client)
            defer destroy(c)
            m:=make([dynamic]u8,context.temp_allocator)
            if x.message==.Server_Hello {
                append(&m,..server_hello)
                c.group=server.group
                // The extensions' length is the two bytes before the end of the fixed fields.
                at:=4+2+32+1+int(server_hello[4+2+32])+2+1
                n:=int(m[at])<<8|int(m[at+1])+len(x.extension)
                m[at],m[at+1]=u8(n>>8),u8(n)
                append(&m,..x.extension)
            } else {
                c.state=.Wait_Encrypted_Extensions
                append(&m,u8(Message.Encrypted_Extensions),0,0,0,0,0)
                append(&m,..x.extension)
                m[5]=u8(len(x.extension))
            }
            size:=len(m)-4
            m[1],m[2],m[3]=u8(size>>16),u8(size>>8),u8(size)
            err:=client_message(c,m[:])
            testing.expectf(t,err==x.want,"%s: %v, want %v",x.name,err,x.want)
        }
    }

    // A credential without its key is never presented.
    {
        client,_:=create(client_config,.Client)
        defer destroy(client)
        empty:=[]Credential{{}}
        server,_:=create({credentials=empty},.Server)
        defer destroy(server)
        expect_failure(t,"a credential without a key",server,pending(client),.Unrecognized_Name)
    }

    // A fatal alert from the peer ends the connection without an answer.
    {
        server,_:=create(server_config,.Server)
        defer destroy(server)
        err,alerted:=feed(server,record_of(.Alert,{2,40}))
        testing.expect(t,err==.Alert_Received && server.alert==.Handshake_Failure && !alerted,"a received alert")
    }
}
