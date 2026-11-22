package kai

import "core:encoding/endian"
import "core:mem"
import "mirai:std/blake3"

// The LAN beacon: a datagram broadcast every BEACON_SECONDS that only members
// of an org can read. Its tags are keyed by the org's discovery secret D and
// change every BEACON_BUCKET_SECONDS, so to anyone without D the beacons of
// one device in two buckets, or of two orgs in one, are unrelated noise. A
// member matches the org tag, then which device by its dev tag. No mDNS.

BEACON_SECONDS :: 30
BEACON_BUCKET_SECONDS :: 600
BEACON_TAG :: 12
LABEL_BEACON_ORG :: "kai-1/beacon-org"
LABEL_BEACON_DEVICE :: "kai-1/beacon-dev"

Beacon :: struct #packed {
    org_tag:[BEACON_TAG]u8,
    dev_tag:[BEACON_TAG]u8,
    port:u16, // little-endian: where the device's agent listens
}

BEACON_BYTES :: size_of(Beacon)

// The bucket of a time in Unix seconds.
beacon_bucket :: proc "contextless" (unix:i64) -> u64 {return u64(max(unix,0))/BEACON_BUCKET_SECONDS}

@(private)
beacon_tag :: proc(secret:^[32]u8,label:string,bucket:u64,device:[]u8) -> (tag:[BEACON_TAG]u8) {
    // BLAKE3 has no length extension: the secret first, of a fixed length,
    // keys it.
    h:blake3.Hasher
    blake3.init(&h)
    blake3.update(&h,secret[:])
    blake3.update(&h,transmute([]u8)label)
    b:[8]u8
    endian.unchecked_put_u64le(b[:],bucket)
    blake3.update(&h,b[:])
    blake3.update(&h,device)
    sum:=blake3.final(&h)
    copy(tag[:],sum[:BEACON_TAG])
    return
}

beacon_org_tag :: proc(secret:^[32]u8,bucket:u64) -> [BEACON_TAG]u8 {
    return beacon_tag(secret,LABEL_BEACON_ORG,bucket,nil)
}

beacon_dev_tag :: proc(secret:^[32]u8,bucket:u64,device:Dh_Key) -> [BEACON_TAG]u8 {
    d:=device
    return beacon_tag(secret,LABEL_BEACON_DEVICE,bucket,d[:])
}

// The beacon of device for the org of secret at a time in Unix seconds.
beacon_make :: proc(secret:^[32]u8,device:Dh_Key,port:u16,unix:i64) -> (bytes:[BEACON_BYTES]u8) {
    bucket:=beacon_bucket(unix)
    b:=Beacon{org_tag=beacon_org_tag(secret,bucket),dev_tag=beacon_dev_tag(secret,bucket,device)}
    endian.unchecked_put_u16le(mem.ptr_to_bytes(&b.port),port)
    copy(bytes[:],mem.ptr_to_bytes(&b))
    return
}

// Which of devices sent the beacon, and its port: the bucket of now or one
// next to it, so clocks a few minutes apart still meet. found is false for a
// beacon of another org or of no device known.
beacon_read :: proc(secret:^[32]u8,devices:[]Dh_Key,bytes:[]u8,unix:i64) -> (device:int,port:u16,found:bool) {
    if len(bytes)!=BEACON_BYTES {return -1,0,false}
    b:=(^Beacon)(raw_data(bytes))^
    now:=beacon_bucket(unix)
    for bucket in ([3]u64{now,now-1,now+1}) {
        if beacon_org_tag(secret,bucket)!=b.org_tag {continue}
        for d,i in devices {
            if beacon_dev_tag(secret,bucket,d)==b.dev_tag {
                return i,endian.unchecked_get_u16le(mem.ptr_to_bytes(&b.port)),true
            }
        }
        return -1,0,false
    }
    return -1,0,false
}
