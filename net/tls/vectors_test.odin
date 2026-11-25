package tls

import "core:crypto/ecdh"
import "core:crypto/hash"
import "core:crypto/x509"
import "core:encoding/hex"
import "core:testing"

// The simple 1-RTT handshake of RFC 8448, 3: its key schedule from the two key shares and the
// transcript, and every record it protects, against the trace.
@(test)
tls13_known_answer_vectors :: proc(t:^testing.T) {
    anchor:x509.Certificate
    c,err:=create({host="server",roots={&anchor},suites={.AES_128_GCM_SHA256},groups={.X25519}},.Client)
    if !testing.expect_value(t,err,Error.None) {return}
    defer destroy(c)
    // The trace's own ClientHello replaces the one create wrote.
    c.output_len=0
    hash.init(&c.transcript[0],.SHA256)
    hash.init(&c.transcript[1],.SHA384)
    expect_record(t,c,.Handshake,RFC8448_CLIENT_HELLO,RFC8448_CLIENT_HELLO_RECORD)
    c.suite,c.digest=.AES_128_GCM_SHA256,.SHA256
    private:=bytes_of(RFC8448_CLIENT_PRIVATE)
    defer delete(private)
    testing.expect(t,ecdh.private_key_set_bytes(&c.key_share,.X25519,private))
    transcript_add(c,bytes_of(RFC8448_CLIENT_HELLO,context.temp_allocator))
    transcript_add(c,bytes_of(RFC8448_SERVER_HELLO,context.temp_allocator))

    shared_buffer:[HASH_MAX]u8
    shared,kerr:=key_exchange(c,bytes_of(RFC8448_SERVER_PUBLIC,context.temp_allocator),&shared_buffer)
    testing.expect_value(t,kerr,Error.None)
    expect_bytes(t,"shared secret",shared,RFC8448_SHARED)
    schedule_handshake(c,shared)
    expect_bytes(t,"handshake secret",c.handshake_secret[:32],RFC8448_HANDSHAKE_SECRET)
    expect_bytes(t,"client handshake traffic",c.client_traffic[:32],RFC8448_CLIENT_HANDSHAKE_TRAFFIC)
    expect_bytes(t,"server handshake traffic",c.server_traffic[:32],RFC8448_SERVER_HANDSHAKE_TRAFFIC)
    expect_bytes(t,"master secret",c.master_secret[:32],RFC8448_MASTER_SECRET)
    direction_set(&c.read,c.suite,c.server_traffic[:])
    direction_set(&c.write,c.suite,c.client_traffic[:])
    expect_bytes(t,"server handshake iv",c.read.iv[:],RFC8448_SERVER_HANDSHAKE_IV)

    expect_open(t,&c.read,RFC8448_SERVER_FLIGHT_RECORD,RFC8448_SERVER_FLIGHT,.Handshake)
    transcript_add(c,bytes_of(RFC8448_SERVER_FLIGHT,context.temp_allocator))
    schedule_application(c)
    expect_bytes(t,"client application traffic",c.client_traffic[:32],RFC8448_CLIENT_APPLICATION_TRAFFIC)
    expect_bytes(t,"server application traffic",c.server_traffic[:32],RFC8448_SERVER_APPLICATION_TRAFFIC)

    th,verify:[HASH_MAX]u8
    finished_compute(c.digest,c.write.secret[:],transcript_hash(c,&th),verify[:])
    expect_bytes(t,"client finished",verify[:32],RFC8448_CLIENT_FINISHED[8:])
    expect_record(t,c,.Handshake,RFC8448_CLIENT_FINISHED,RFC8448_CLIENT_FINISHED_RECORD)

    direction_set(&c.read,c.suite,c.server_traffic[:])
    direction_set(&c.write,c.suite,c.client_traffic[:])
    expect_bytes(t,"server application iv",c.read.iv[:],RFC8448_SERVER_APPLICATION_IV)
    expect_bytes(t,"client application iv",c.write.iv[:],RFC8448_CLIENT_APPLICATION_IV)
    expect_open(t,&c.read,RFC8448_TICKET_RECORD,RFC8448_TICKET,.Handshake)
    expect_record(t,c,.Application_Data,RFC8448_CLIENT_DATA,RFC8448_CLIENT_DATA_RECORD)
    expect_open(t,&c.read,RFC8448_SERVER_DATA_RECORD,RFC8448_SERVER_DATA,.Application_Data)
    expect_record(t,c,.Alert,RFC8448_CLIENT_ALERT,RFC8448_CLIENT_ALERT_RECORD)
}

@(private="file")
bytes_of :: proc(text:string,allocator:=context.allocator) -> []u8 {
    b,_:=hex.decode(transmute([]u8)text,allocator)
    return b
}

@(private="file")
expect_bytes :: proc(t:^testing.T,what:string,got:[]u8,want:string,loc:=#caller_location) {
    w:=bytes_of(want,context.temp_allocator)
    testing.expectf(t,string(got)==string(w),"%s: got %x, want %s",what,got,want,loc=loc)
}

// The record this end seals for payload.
@(private="file")
expect_record :: proc(t:^testing.T,c:^Conn,content:Content,payload,want:string,loc:=#caller_location) {
    c.output_len=0
    testing.expect_value(t,record_seal(c,content,bytes_of(payload,context.temp_allocator)),Error.None,loc=loc)
    expect_bytes(t,"record",pending(c),want,loc)
}

// A record of the peer opens to payload and its content type.
@(private="file")
expect_open :: proc(t:^testing.T,d:^Direction,record,payload:string,content:Content,loc:=#caller_location) {
    r:=bytes_of(record,context.temp_allocator)
    inner,ok:=record_open(d,r[:HEADER_BYTES],r[HEADER_BYTES:])
    if !testing.expect(t,ok && len(inner)>0,"the record does not open",loc=loc) {return}
    expect_bytes(t,"plaintext",inner[:len(inner)-1],payload,loc)
    testing.expect_value(t,Content(inner[len(inner)-1]),content,loc=loc)
}

@(private="file") RFC8448_CLIENT_PRIVATE ::
    "49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005"
@(private="file") RFC8448_CLIENT_HELLO ::
    "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113"+
    "031302010000910000000b0009000006736572766572ff01000100000a00140012001d001700180019010001"+
    "0101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae"+
    "4d5413691e529aaf2c002b0003020304000d0020001e04030503060302030804080508060401050106010201"+
    "0402050206020202002d00020101001c00024001"
@(private="file") RFC8448_CLIENT_HELLO_RECORD ::
    "16030100c4010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece700"+
    "0006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d00170018"+
    "00190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c0"+
    "6e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e0403050306030203080408050806040105"+
    "01060102010402050206020202002d00020101001c00024001"
@(private="file") RFC8448_SERVER_PUBLIC ::
    "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f"
@(private="file") RFC8448_SHARED ::
    "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d"
@(private="file") RFC8448_HANDSHAKE_SECRET ::
    "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac"
@(private="file") RFC8448_CLIENT_HANDSHAKE_TRAFFIC ::
    "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21"
@(private="file") RFC8448_SERVER_HANDSHAKE_TRAFFIC ::
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38"
@(private="file") RFC8448_MASTER_SECRET ::
    "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919"
@(private="file") RFC8448_SERVER_HELLO ::
    "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e"+
    "00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b0002"+
    "0304"
@(private="file") RFC8448_SERVER_HANDSHAKE_IV ::
    "5d313eb2671276ee13000b30"
@(private="file") RFC8448_SERVER_FLIGHT ::
    "080000240022000a00140012001d00170018001901000101010201030104001c00024001000000000b0001b9"+
    "000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a"+
    "06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e"+
    "310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4"+
    "bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace"+
    "6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda4308467480"+
    "30530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001"+
    "a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b050003"+
    "81810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172"+
    "f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3e"+
    "b7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de100"+
    "000f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc"+
    "90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411"+
    "ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53df"+
    "acd42f74f3140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718"
@(private="file") RFC8448_SERVER_FLIGHT_RECORD ::
    "17030302a2d1ff334a56f5bff6594a07cc87b580233f500f45e489e7f33af35edf7869fcf40aa40aa2b8ea73"+
    "f848a7ca07612ef9f945cb960b4068905123ea78b111b429ba9191cd05d2a389280f526134aadc7fc78c4b72"+
    "9df828b5ecf7b13bd9aefb0e57f271585b8ea9bb355c7c79020716cfb9b1183ef3ab20e37d57a6b9d7477609"+
    "aee6e122a4cf51427325250c7d0e509289444c9b3a648f1d71035d2ed65b0e3cdd0cbae8bf2d0b227812cbb3"+
    "60987255cc744110c453baa4fcd610928d809810e4b7ed1a8fd991f06aa6248204797e36a6a73b70a2559c09"+
    "ead686945ba246ab66e5edd8044b4c6de3fcf2a89441ac66272fd8fb330ef8190579b3684596c960bd596eea"+
    "520a56a8d650f563aad27409960dca63d3e688611ea5e22f4415cf9538d51a200c27034272968a264ed6540c"+
    "84838d89f72c24461aad6d26f59ecaba9acbbb317b66d902f4f292a36ac1b639c637ce343117b65962224531"+
    "7b49eeda0c6258f100d7d961ffb138647e92ea330faeea6dfa31c7a84dc3bd7e1b7a6c7178af36879018e3f2"+
    "52107f243d243dc7339d5684c8b0378bf30244da8c87c843f5e56eb4c5e8280a2b48052cf93b16499a66db7c"+
    "ca71e4599426f7d461e66f99882bd89fc50800becca62d6c74116dbd2972fda1fa80f85df881edbe5a376689"+
    "36b335583b599186dc5c6918a396fa48a181d6b6fa4f9d62d513afbb992f2b992f67f8afe67f76913fa388cb"+
    "5630c8ca01e0c65d11c66a1e2ac4c85977b7c7a6999bbf10dc35ae69f5515614636c0b9b68c19ed2e31c0b3b"+
    "66763038ebba42f3b38edc0399f3a9f23faa63978c317fc9fa66a73f60f0504de93b5b845e275592c12335ee"+
    "340bbc4fddd502784016e4b3be7ef04dda49f4b440a30cb5d2af939828fd4ae3794e44f94df5a631ede42c17"+
    "19bfdabf0253fe5175be898e750edc53370d2b"
@(private="file") RFC8448_CLIENT_APPLICATION_TRAFFIC ::
    "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5"
@(private="file") RFC8448_SERVER_APPLICATION_TRAFFIC ::
    "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643"
@(private="file") RFC8448_SERVER_APPLICATION_IV ::
    "cf782b88dd83549aadf1e984"
@(private="file") RFC8448_CLIENT_FINISHED ::
    "14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61"
@(private="file") RFC8448_CLIENT_FINISHED_RECORD ::
    "170303003575ec4dc238cce60b298044a71e219c56cc77b0517fe9b93c7a4bfc44d87f38f80338ac98fc46de"+
    "b384bd1caeacab6867d726c40546"
@(private="file") RFC8448_CLIENT_APPLICATION_IV ::
    "5b78923dee08579033e523d9"
@(private="file") RFC8448_TICKET ::
    "040000c90000001efad6aac502000000b22c035d829359ee5ff7af4ec900000000262a6494dc486d2c8a34cb"+
    "33fa90bf1b0070ad3c498883c9367c09a2be785abc55cd226097a3a982117283f82a03a143efd3ff5dd36d64"+
    "e861be7fd61d2827db279cce145077d454a3664d4e6da4d29ee03725a6a4dafcd0fc67d2aea70529513e3da2"+
    "677fa5906c5b3f7d8f92f228bda40dda721470f9fbf297b5aea617646fac5c03272e970727c621a79141ef5f"+
    "7de6505e5bfbc388e93343694093934ae4d3570008002a000400000400"
@(private="file") RFC8448_TICKET_RECORD ::
    "17030300de3a6b8f90414a97d6959c3487680de5134a2b240e6cffac116e95d41d6af8f6b580dcf3d11d63c7"+
    "58db289a015940252f55713e061dc13e078891a38efbcf5753ad8ef170ad3c7353d16d9da773b9ca7f2b9fa1"+
    "b6c0d4a3d03f75e09c30ba1e62972ac46f75f7b981be63439b2999ce13064615139891d5e4c5b406f16e3fc1"+
    "81a77ca475840025db2f0a77f81b5ab05b94c01346755f69232c86519d86cbeeac87aac347d143f9605d64f6"+
    "50db4d023e70e952ca49fe5137121c74bc2697687e248746d6df353005f3bce18696129c8153556b3b6c6779"+
    "b37bf15985684f"
@(private="file") RFC8448_CLIENT_DATA ::
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b"+
    "2c2d2e2f3031"
@(private="file") RFC8448_CLIENT_DATA_RECORD ::
    "1703030043a23f7054b62c94d0affafe8228ba55cbefacea42f914aa66bcab3f2b9819a8a5b46b395bd54a9a"+
    "20441e2b62974e1f5a6292a2977014bd1e3deae63aeebb21694915e4"
@(private="file") RFC8448_SERVER_DATA ::
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b"+
    "2c2d2e2f3031"
@(private="file") RFC8448_SERVER_DATA_RECORD ::
    "17030300432e937e11ef4ac740e538ad36005fc4a46932fc3225d05f82aa1b36e30efaf97d90e6dffc602dcb"+
    "501a59a8fcc49c4bf2e5f0a21c0047c2abf332540dd032e167c2955d"
@(private="file") RFC8448_CLIENT_ALERT ::
    "0100"
@(private="file") RFC8448_CLIENT_ALERT_RECORD ::
    "1703030013c9872760655666b74d7ff1153efd6db6d0b0e3"
