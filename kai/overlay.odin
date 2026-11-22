package kai

import "base:runtime"
import "core:crypto"
import "core:crypto/aegis"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:math"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:std/base"
import "mirai:std/blake3"
import "mirai:std/compressor/data"
import "mirai:store"

// Encrypted overlays: the private files of a project. The Scope_Add patterns
// of the Org_Log route the matching paths of a snapshot into one overlay per
// scope and commit, sealed under the scope's newest epoch key: their plaintext
// never reaches the store and the public Change never names an overlay. The
// store holds, under the ref kai-ovl-<project hex>-<scope hex>/<commit hex>:
//
//   Overlay_Record  signed by a device of a writer: seq, prev, commit, scope,
//                   epoch, the sealed tree and the sorted file objects. Every
//                   address names ciphertext, so a seed mirrors all of it
//                   without any key.
//   sealed tree     nonce || AEGIS-256 under HKDF(K, "kai-1/tree") of the
//                   paths, file ids, sizes and file objects.
//   file object     one native group per sealed chunk: FastCDC under
//                   OVERLAY_CHUNK_MAX, MDC2, Padme, then AEGIS-256 under the
//                   file's key with a nonce keyed on the padded chunk, so an
//                   edit dedups within its file and epoch while nothing
//                   confirms a guessed plaintext.
//
// A scope's epoch key is wrapped in an Epoch_Add for every device that may
// read the scope; when the scope keeps history the new key wraps the previous
// one too. A write is refused while the newest epoch still wraps for a device
// that may no longer read the scope: any reader rotates first.
//
// The nonce of a chunk is BLAKE3 over k_nonce || q: std/blake3 has no keyed
// mode, and a fixed 32-byte key prefix makes the same PRF.

OVERLAY_PREFIX :: "kai-ovl-"
OVERLAY_MAGIC :: u32('K')|u32('O')<<8|u32('V')<<16|u32('1')<<24
OVERLAY_CHUNK_MAX :: store.CHUNK_MAX-(8<<10) // plaintext bytes of a chunk: sealed, it fits one store chunk
OVERLAY_FILES_MAX :: 1<<16
OVERLAY_FILE_CHUNKS_MAX :: 4096 // sealed chunks of a file, one group each in its object's root
OVERLAY_TREE_MAX :: 64<<20
OVERLAY_RECORD_MAX :: size_of(Overlay_Record_Head)+OVERLAY_FILES_MAX*size_of(store.Hash)+size_of(Signature)
OVERLAY_BLOB_MAX :: 256<<20
OVERLAY_TAG :: u32('K')|u32('O')<<8|u32('V')<<16|u32('C')<<24 // the native group of a sealed chunk
SCAN_LINE_MAX :: 4096 // bytes of a line the scanner reads; the rest of a longer line is skipped

LABEL_WRAP :: "kai-1/wrap"
LABEL_PREV :: "kai-1/prev"
LABEL_FILE :: "kai-1/file"
LABEL_CHUNK :: "kai-1/chunk"
LABEL_TREE :: "kai-1/tree"
LABEL_BLOB :: "kai-1/blob"
LABEL_LEAK :: "kai-1/leak"

// Paths refused at snapshot unless a scope or public_allow takes them.
DENY_PATTERNS :: [?]string{".env*","*.pem","*.key","id_*","*.p12"}

@(private) SEAL_HEAD :: 8 // u32 raw length, u32 MDC2 length
@(private) SEAL_NONCE :: aegis.IV_SIZE_256
@(private) SEAL_TAG :: aegis.TAG_SIZE_128
@(private) SEAL_Q_MAX :: (SEAL_HEAD+OVERLAY_CHUNK_MAX+1+4096+4095)&~4095 // Padme of the largest head and MDC2 bound

File_Id :: distinct [16]u8 // random for a new private file, kept across its edits and renames
Epoch_Key :: [32]u8

// A device as the overlays see it: what it signs with and its X25519 pair.
Overlay_Device :: struct {
    identity:Identity,
    dh:Dh_Key,
    dh_secret:[32]u8,
}

Overlay_Kind :: enum u8 {None,Record,Tree,File,Blob}

// What the root of every overlay object carries as meta.
Overlay_Meta :: struct #packed {
    magic:u32,
    kind:Overlay_Kind,
    reserved:u8,
    version:u16,
}

// --- Primitives ---

@(private)
aead_seal :: proc(key,iv,aad,plain,dst,tag:[]u8) {
    ctx:aegis.Context
    aegis.init(&ctx,key)
    defer aegis.reset(&ctx)
    aegis.seal(&ctx,dst,tag,iv,aad,plain)
}

@(private)
aead_open :: proc(key,iv,aad,cipher,tag,dst:[]u8) -> bool {
    ctx:aegis.Context
    aegis.init(&ctx,key)
    defer aegis.reset(&ctx)
    return aegis.open(&ctx,dst,iv,aad,cipher,tag)
}

// The smallest length at least length whose low bits Padme clears: at most
// about 12% more, and only O(log log) bits of the length remain.
padme :: proc "contextless" (length:int) -> int {
    if length<2 {return length}
    e:=bits.len_u64(u64(length))-1
    s:=bits.len_u64(u64(e))
    mask:=(1<<uint(e-s))-1
    return (length+mask)&~mask
}

@(private)
keyed_hash :: proc "contextless" (key:[]u8,parts:..[]u8) -> (out:[32]u8) {
    h:blake3.Hasher
    blake3.update(&h,key)
    for p in parts {blake3.update(&h,p)}
    return blake3.final(&h)
}

@(private)
put_u32 :: proc "contextless" (bytes:[]u8,value:u32) {
    v:=u32le(value)
    mem.copy_non_overlapping(raw_data(bytes),&v,4)
}

@(private)
get_u32 :: proc "contextless" (bytes:[]u8) -> u32 {
    v:u32le
    mem.copy_non_overlapping(&v,raw_data(bytes),4)
    return u32(v)
}

// The additional data of a wrapped key: org_id || scope_id || epoch || dh.
@(private)
wrap_aad :: proc(org:Log_Id,scope:Scope_Id,epoch:u32,dh:Dh_Key) -> (aad:[32+16+4+32]u8) {
    o,s,d:=org,scope,dh
    copy(aad[:],o[:])
    copy(aad[32:],s[:])
    put_u32(aad[48:],epoch)
    copy(aad[52:],d[:])
    return
}

// The key and nonce of a wrap: HKDF-SHA256("kai-1/wrap") over X25519(e, dh),
// salted with both public keys.
@(private)
wrap_keys :: proc(shared:[]u8,e_public:[]u8,dh:Dh_Key) -> (okm:[64]u8) {
    salt:[64]u8
    d:=dh
    copy(salt[:],e_public)
    copy(salt[32:],d[:])
    hkdf.extract_and_expand(.SHA256,salt[:],shared,transmute([]u8)string(LABEL_WRAP),okm[:])
    return
}

// key wrapped for the device dh: an ephemeral X25519 public key, the
// ciphertext and its tag.
envelope_wrap :: proc(org:Log_Id,scope:Scope_Id,epoch:u32,dh:Dh_Key,key:^Epoch_Key) -> (envelope:Envelope,ok:bool) {
    secret,public,shared:[32]u8
    defer crypto.zero_explicit(&secret,32)
    defer crypto.zero_explicit(&shared,32)
    crypto.rand_bytes(secret[:])
    x25519.scalarmult_basepoint(public[:],secret[:])
    point:=dh
    x25519.scalarmult(shared[:],secret[:],point[:])
    if crypto.is_zero_constant_time(shared[:])==1 {return}
    okm:=wrap_keys(shared[:],public[:],dh)
    defer crypto.zero_explicit(&okm,64)
    aad:=wrap_aad(org,scope,epoch,dh)
    envelope.dh=dh
    copy(envelope.wrapped[:32],public[:])
    aead_seal(okm[:32],okm[32:],aad[:],key[:],envelope.wrapped[32:64],envelope.wrapped[64:])
    return envelope,true
}

// The key an envelope wraps for device.
envelope_unwrap :: proc(org:Log_Id,scope:Scope_Id,epoch:u32,device:^Overlay_Device,envelope:Envelope) -> (key:Epoch_Key,ok:bool) {
    if envelope.dh!=device.dh {return}
    shared:[32]u8
    defer crypto.zero_explicit(&shared,32)
    e:=envelope
    x25519.scalarmult(shared[:],device.dh_secret[:],e.wrapped[:32])
    if crypto.is_zero_constant_time(shared[:])==1 {return}
    okm:=wrap_keys(shared[:],e.wrapped[:32],envelope.dh)
    defer crypto.zero_explicit(&okm,64)
    aad:=wrap_aad(org,scope,epoch,envelope.dh)
    if !aead_open(okm[:32],okm[32:],aad[:],e.wrapped[32:64],e.wrapped[64:],key[:]) {return {},false}
    return key,true
}

// The dh an epoch's envelope of the previous key carries: no device's key.
prev_marker :: proc(epoch:u32) -> Dh_Key {
    e:[4]u8
    put_u32(e[:],epoch)
    return Dh_Key(keyed_hash(transmute([]u8)string(LABEL_PREV),e[:]))
}

@(private)
prev_key :: proc(key:^Epoch_Key) -> (k:[32]u8) {
    hkdf.extract_and_expand(.SHA256,nil,key[:],transmute([]u8)string(LABEL_PREV),k[:])
    return
}

// The previous epoch's key wrapped under the key of epoch.
@(private)
prev_wrap :: proc(org:Log_Id,scope:Scope_Id,epoch:u32,key,previous:^Epoch_Key) -> (envelope:Envelope) {
    k:=prev_key(key)
    defer crypto.zero_explicit(&k,32)
    envelope.dh=prev_marker(epoch)
    crypto.rand_bytes(envelope.wrapped[:32])
    aad:=wrap_aad(org,scope,epoch,envelope.dh)
    aead_seal(k[:],envelope.wrapped[:32],aad[:],previous[:],envelope.wrapped[32:64],envelope.wrapped[64:])
    return
}

@(private)
prev_unwrap :: proc(org:Log_Id,scope:Scope_Id,epoch:u32,key:^Epoch_Key,envelope:Envelope) -> (previous:Epoch_Key,ok:bool) {
    k:=prev_key(key)
    defer crypto.zero_explicit(&k,32)
    e:=envelope
    aad:=wrap_aad(org,scope,epoch,envelope.dh)
    if !aead_open(k[:],e.wrapped[:32],aad[:],e.wrapped[32:64],e.wrapped[64:],previous[:]) {return {},false}
    return previous,true
}

// --- Keyring epochs ---

// The scope of the org a keyring keys.
keyring_scope :: proc(k:^Keyring_Fold) -> (scope:Org_Scope,ok:bool) {
    for s in k.org.scopes {
        if s.project==k.project && s.scope==k.scope {return s,true}
    }
    return
}

// Whether the device dh belongs to a member who may read scope.
@(private)
dh_reads :: proc(org:^Org_Fold,scope:Org_Scope,dh:Dh_Key) -> bool {
    for u in org.users {
        if user_dh_active(u,dh) && org_role(org,u.log.id)>=scope.readers {return true}
    }
    return false
}

// Whether device may read scope: an active device of a member whose role reaches its readers.
device_reads :: proc(org:^Org_Fold,scope:Org_Scope,device:^Overlay_Device) -> bool {
    _,role:=org_device_role(org,device.identity.key)
    return role>=scope.readers && dh_reads(org,scope,device.dh)
}

// The X25519 keys of every active device of the members who may read scope.
@(private)
scope_readers :: proc(org:^Org_Fold,scope:Org_Scope,out:^[dynamic]Dh_Key) -> Error {
    for m in org.members {
        if m.role<scope.readers {continue}
        for u in org.users {
            if u.log.id!=m.user {continue}
            for d in u.devices {
                if d.revoked || slice.contains(out[:],d.dh) {continue}
                if _,e:=append(out,d.dh);e!=nil {return .Out_Of_Memory}
            }
        }
    }
    return .None
}

// Whether a write must wait for a rotation: no epoch yet, or the newest one
// still wraps its key for a device that may no longer read the scope.
keyring_needs_rotation :: proc(k:^Keyring_Fold) -> bool {
    scope,ok:=keyring_scope(k)
    if !ok || k.epoch==0 {return true}
    marker:=prev_marker(k.epoch)
    for e in k.envelopes {
        if e.epoch==k.epoch && e.envelope.dh!=marker && !dh_reads(k.org,scope,e.envelope.dh) {return true}
    }
    return false
}

// The key of epoch as device holds it: its own envelope of that epoch, or of a
// later one and then the previous keys down to epoch.
keyring_epoch_key :: proc(k:^Keyring_Fold,device:^Overlay_Device,epoch:u32) -> (key:Epoch_Key,error:Error) {
    if epoch==0 || epoch>k.epoch {return {},.Invalid_Argument}
    org:=k.org.log.id
    at:=u32(0)
    for e:=epoch;e<=k.epoch;e+=1 {
        envelope,found:=keyring_envelope(k,e,device.dh)
        if !found {continue}
        ok:bool
        if key,ok=envelope_unwrap(org,k.scope,e,device,envelope);!ok {return {},.Corrupt}
        at=e
        break
    }
    if at==0 {return {},.Unauthorized}
    for e:=at;e>epoch;e-=1 {
        envelope,found:=keyring_envelope(k,e,prev_marker(e))
        if !found {
            crypto.zero_explicit(&key,size_of(key))
            return {},.Unauthorized
        }
        previous,ok:=prev_unwrap(org,k.scope,e,&key,envelope)
        crypto.zero_explicit(&key,size_of(key))
        if !ok {return {},.Corrupt}
        key=previous
    }
    return key,.None
}

@(private)
keyring_refold :: proc(k:^Keyring_Fold) -> Error {
    l,org,allocator:=k.log,k.org,k.envelopes.allocator
    keyring_fold_destroy(k)
    return keyring_fold(k,l,org,allocator)
}

// Starts the Keyring_Log of a scope at l, empty, with its first epoch: k is
// its fold. The caller saves the log.
keyring_create :: proc(k:^Keyring_Fold,l:^Log,org:^Org_Fold,project:Log_Id,scope:Scope_Id,device:^Overlay_Device,time:i64,allocator:=context.allocator) -> Error {
    user,_:=org_device_role(org,device.identity.key)
    _,e:=log_append(l,.Keyring_Genesis,body_make(Keyring_Genesis_Body{org=org.log.id,project=project,scope=scope}),&device.identity,time,{},org_context(org,user))
    if e!=.None {return e}
    keyring_fold(k,l,org,allocator) or_return
    if k.project!=project {return .Unauthorized}
    _,error:=rotate_scope_epoch(k,device,time)
    return error
}

// Adds the next epoch of the scope: a new random key wrapped for every device
// that may read it now, and the previous key under the new one when the scope
// keeps history. Any device that reads the scope may call it; the log's fold
// takes it from a writer. The caller saves the log.
rotate_scope_epoch :: proc(k:^Keyring_Fold,device:^Overlay_Device,time:i64) -> (epoch:u32,error:Error) {
    scope,ok:=keyring_scope(k)
    if !ok {return 0,.Invalid_Argument}
    if !device_reads(k.org,scope,device) {return 0,.Unauthorized}
    previous,key:Epoch_Key
    defer crypto.zero_explicit(&previous,size_of(previous))
    defer crypto.zero_explicit(&key,size_of(key))
    history:=scope.history && k.epoch>0
    if history {previous=keyring_epoch_key(k,device,k.epoch) or_return}
    crypto.rand_bytes(key[:])
    epoch=k.epoch+1
    readers:=make([dynamic]Dh_Key,context.temp_allocator)
    scope_readers(k.org,scope,&readers) or_return
    count:=len(readers)+(history?1:0)
    if count==0 {return 0,.Invalid_Argument}
    if count>ENVELOPES_MAX || size_of(Epoch_Add_Body)+count*size_of(Envelope)>ENTRY_BODY_MAX {return 0,.Too_Large}
    envelopes,made:=make([]Envelope,count,context.temp_allocator)
    if made!=nil {return 0,.Out_Of_Memory}
    org:=k.org.log.id
    for dh,i in readers {
        envelope,wrapped:=envelope_wrap(org,k.scope,epoch,dh,&key)
        if !wrapped {return 0,.Invalid_Argument}
        envelopes[i]=envelope
    }
    if history {envelopes[len(readers)]=prev_wrap(org,k.scope,epoch,&key,&previous)}
    body:=body_make(Epoch_Add_Body{epoch=epoch,envelopes=u16(count)},slice.to_bytes(envelopes))
    if body==nil {return 0,.Out_Of_Memory}
    user,_:=org_device_role(k.org,device.identity.key)
    log_append(k.log,.Epoch_Add,body,&device.identity,time,{},org_context(k.org,user)) or_return
    keyring_refold(k) or_return
    if k.epoch!=epoch {return 0,.Unauthorized}
    return epoch,.None
}

// --- Patterns ---

// Whether path matches a pattern of Scope_Add or of the deny set: `*` and `?`
// within one name, `**` across folders, `**/` zero or more folders. A pattern
// without '/' matches the last name of the path, one with '/' the whole path
// from the root; one ending in '/' everything under that folder.
glob_match :: proc(pattern,path:string) -> bool {
    p:=strings.trim_prefix(pattern,"/")
    if len(p)==0 || len(path)>PATH_MAX {return false}
    if strings.index_byte(pattern,'/')<0 {
        name:=path
        if k:=strings.last_index_byte(path,'/');k>=0 {name=path[k+1:]}
        return glob_full(p,name)
    }
    if strings.has_suffix(p,"/") {
        return strings.has_prefix(path,p) && len(path)>len(p)
    }
    return glob_full(p,path)
}

// Whether all of s matches all of p: a row per byte of p, over the bytes of s.
@(private)
glob_full :: proc(p,s:string) -> bool {
    n:=len(s)
    if n>PATH_MAX {return false}
    rows:[2][PATH_MAX+1]bool
    prev,next:=rows[0][:n+1],rows[1][:n+1]
    prev[0]=true
    for i:=0;i<len(p); {
        mem.zero_slice(next)
        c:=p[i]
        switch {
        case c=='*' && i+1<len(p) && p[i+1]=='*':
            i+=2
            folders:=i<len(p) && p[i]=='/'
            if folders {i+=1}
            seen:=false // a match ends at or before j-1
            for j in 0..=n {
                if folders {
                    next[j]=prev[j] || (j>0 && s[j-1]=='/' && seen)
                    seen|=prev[j]
                } else {
                    seen|=prev[j]
                    next[j]=seen
                }
            }
        case c=='*':
            i+=1
            for j in 0..=n {next[j]=prev[j] || (j>0 && next[j-1] && s[j-1]!='/')}
        case c=='?':
            i+=1
            for j in 0..<n {next[j+1]=prev[j] && s[j]!='/'}
        case:
            i+=1
            for j in 0..<n {next[j+1]=prev[j] && s[j]==c}
        }
        prev,next=next,prev
    }
    return prev[n]
}

// Whether the built-in deny set holds path.
overlay_denied :: proc(path:string) -> bool {
    patterns:=DENY_PATTERNS
    for p in patterns {
        if glob_match(p,path) {return true}
    }
    return false
}

// The scope of project path routes into: the first scope in Org_Log order with
// a pattern that matches it; ok false when none does.
scope_of :: proc(org:^Org_Fold,project:Log_Id,path:string) -> (scope:Org_Scope,ok:bool) {
    if org==nil {return}
    for s in org.scopes {
        if s.project!=project {continue}
        b,tail,_:=body_head(org.log.items[s.entry].entry.body,Scope_Add_Body)
        r:=Reader{data=tail}
        for _ in 0..<b.patterns {
            if glob_match(tail_string(&r),path) {return s,true}
        }
    }
    return
}

// --- Sealed chunks ---

File_Keys :: struct {enc,nonce:[32]u8}

// (k_enc, k_nonce) = HKDF-SHA256(K_epoch, "kai-1/file" || file_id).
file_keys :: proc(key:^Epoch_Key,file_id:File_Id) -> (k:File_Keys) {
    info:[len(LABEL_FILE)+16]u8
    id:=file_id
    copy(info[:],LABEL_FILE)
    copy(info[len(LABEL_FILE):],id[:])
    hkdf.extract_and_expand(.SHA256,nil,key[:],info[:],mem.ptr_to_bytes(&k))
    return
}

file_keys_clear :: proc(k:^File_Keys) {crypto.zero_explicit(k,size_of(File_Keys))}

// The additional data of a chunk: "kai-1/chunk" || scope_id || epoch || file_id.
chunk_aad :: proc(scope:Scope_Id,epoch:u32,file_id:File_Id) -> (aad:[len(LABEL_CHUNK)+16+4+16]u8) {
    s,f:=scope,file_id
    copy(aad[:],LABEL_CHUNK)
    copy(aad[len(LABEL_CHUNK):],s[:])
    put_u32(aad[len(LABEL_CHUNK)+16:],epoch)
    copy(aad[len(LABEL_CHUNK)+20:],f[:])
    return
}

// What sealing and opening keep: the MDC2 coder and the buffers of one chunk.
Sealer :: struct {
    encoder:data.Encoder,
    decoder:data.Decoder,
    q:[]u8,      // SEAL_Q_MAX: a padded chunk
    sealed:[]u8, // SEAL_NONCE+SEAL_Q_MAX+SEAL_TAG
    plain:[]u8,  // OVERLAY_CHUNK_MAX: an opened chunk
    allocator:runtime.Allocator,
}

sealer_init :: proc(z:^Sealer,allocator:=context.allocator) -> Error {
    z^={allocator=allocator}
    if data.encoder_init(&z.encoder,allocator)!=.None || data.decoder_init(&z.decoder,allocator)!=.None {
        sealer_destroy(z)
        return .Out_Of_Memory
    }
    e1,e2,e3:runtime.Allocator_Error
    z.q,e1=make([]u8,SEAL_Q_MAX,allocator)
    z.sealed,e2=make([]u8,SEAL_NONCE+SEAL_Q_MAX+SEAL_TAG,allocator)
    z.plain,e3=make([]u8,OVERLAY_CHUNK_MAX,allocator)
    if e1!=nil || e2!=nil || e3!=nil {
        sealer_destroy(z)
        return .Out_Of_Memory
    }
    return .None
}

sealer_destroy :: proc(z:^Sealer) {
    data.encoder_destroy(&z.encoder)
    data.decoder_destroy(&z.decoder)
    if z.q!=nil {crypto.zero_explicit(raw_data(z.q),len(z.q))}
    if z.plain!=nil {crypto.zero_explicit(raw_data(z.plain),len(z.plain))}
    delete(z.q,z.allocator)
    delete(z.sealed,z.allocator)
    delete(z.plain,z.allocator)
    z^={}
}

// Seals 1 to OVERLAY_CHUNK_MAX bytes: q = u32 length || u32 MDC2 length ||
// MDC2 || zeros to its Padme length, nonce = BLAKE3(k_nonce || q), and
// nonce || AEGIS-256(k_enc, nonce, q, aad) || tag, in the sealer's buffer.
seal_chunk :: proc(z:^Sealer,keys:^File_Keys,aad:[]u8,plain:[]u8) -> (sealed:[]u8,error:Error) {
    if len(plain)==0 || len(plain)>OVERLAY_CHUNK_MAX {return nil,.Invalid_Argument}
    bound:=data.bound(len(plain))
    packed,e:=data.encode(&z.encoder,.Fast,plain,z.q[SEAL_HEAD:][:bound])
    if e!=.None {return nil,e==.Out_Of_Memory?.Out_Of_Memory:.Invalid_Argument}
    length:=padme(SEAL_HEAD+packed)
    q:=z.q[:length]
    put_u32(q,u32(len(plain)))
    put_u32(q[4:],u32(packed))
    mem.zero_slice(q[SEAL_HEAD+packed:])
    nonce:=keyed_hash(keys.nonce[:],q)
    sealed=z.sealed[:SEAL_NONCE+length+SEAL_TAG]
    copy(sealed,nonce[:])
    aead_seal(keys.enc[:],nonce[:],aad,q,sealed[SEAL_NONCE:][:length],sealed[SEAL_NONCE+length:])
    return sealed,.None
}

// The bytes of a sealed chunk, in the sealer's buffer until the next call.
// Whatever does not open, or opens to a q no sealer writes, is Corrupt.
open_chunk :: proc(z:^Sealer,keys:^File_Keys,aad:[]u8,sealed:[]u8) -> (plain:[]u8,error:Error) {
    if len(sealed)<SEAL_NONCE+SEAL_HEAD+SEAL_TAG || len(sealed)>SEAL_NONCE+SEAL_Q_MAX+SEAL_TAG {return nil,.Corrupt}
    length:=len(sealed)-SEAL_NONCE-SEAL_TAG
    q:=z.q[:length]
    if !aead_open(keys.enc[:],sealed[:SEAL_NONCE],aad,sealed[SEAL_NONCE:][:length],sealed[SEAL_NONCE+length:],q) {return nil,.Corrupt}
    nonce:=keyed_hash(keys.nonce[:],q)
    if crypto.compare_constant_time(nonce[:],sealed[:SEAL_NONCE])!=1 {return nil,.Corrupt}
    raw,packed:=int(get_u32(q)),int(get_u32(q[4:]))
    if raw==0 || raw>OVERLAY_CHUNK_MAX || packed==0 || packed>length-SEAL_HEAD || padme(SEAL_HEAD+packed)!=length || !zero(q[SEAL_HEAD+packed:]) {return nil,.Corrupt}
    if data.decode(&z.decoder,data.MDC2,q[SEAL_HEAD:][:packed],z.plain[:raw])!=.None {return nil,.Corrupt}
    return z.plain[:raw],.None
}

// --- Overlay objects ---

@(private)
overlay_meta :: proc(kind:Overlay_Kind) -> [size_of(Overlay_Meta)]u8 {
    m:=Overlay_Meta{magic=OVERLAY_MAGIC,kind=kind,version=VERSION}
    return transmute([size_of(Overlay_Meta)]u8)m
}

@(private)
overlay_put :: proc(s:^store.Store,kind:Overlay_Kind,bytes:[]u8) -> (address:store.Hash,error:Error) {
    p,begin:=store.put_begin(s)
    if begin!=.None {return {},store_error(begin)}
    if e:=store.put_write(&p,bytes);e!=.None {
        store.put_abandon(&p)
        return {},store_error(e)
    }
    meta:=overlay_meta(kind)
    a,_,e:=store.put_finish(&p,meta[:])
    return a,store_error(e)
}

@(private)
overlay_kind_check :: proc(o:^store.Object,kind:Overlay_Kind) -> Error {
    meta:=store.object_meta(o)
    if len(meta)!=size_of(Overlay_Meta) {return .Corrupt}
    m:=(^Overlay_Meta)(raw_data(meta))^
    if m.magic!=OVERLAY_MAGIC || m.kind!=kind || m.reserved!=0 || m.version!=VERSION {return .Corrupt}
    return .None
}

@(private)
overlay_get :: proc(s:^store.Store,address:store.Hash,kind:Overlay_Kind,limit:int,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    o,open:=store.object_open(s,address)
    if open!=.None {return nil,store_error(open)}
    defer store.object_close(&o)
    overlay_kind_check(&o,kind) or_return
    size:=store.object_size(&o)
    if size>u64(limit) {return nil,.Too_Large}
    made,made_error:=make([]u8,int(size),allocator)
    if made_error!=nil {return nil,.Out_Of_Memory}
    if e:=store.object_read(&o,0,made);e!=.None {
        delete(made,allocator)
        return nil,store_error(e)
    }
    return made,.None
}

// Reads the file at path once and puts it sealed as an object of one native
// group per chunk; an empty file has no object. content is the BLAKE3 of the
// plaintext.
seal_file :: proc(z:^Sealer,s:^store.Store,path:string,scope:Scope_Id,epoch:u32,key:^Epoch_Key,file_id:File_Id) -> (object,content:store.Hash,size:u64,error:Error) {
    file,open_error:=os.open(path)
    if open_error!=nil {return {},{},0,.Io}
    defer os.close(file)
    buffer,made:=make([]u8,2*OVERLAY_CHUNK_MAX,context.temp_allocator)
    if made!=nil {return {},{},0,.Out_Of_Memory}
    defer crypto.zero_explicit(raw_data(buffer),len(buffer))
    keys:=file_keys(key,file_id)
    defer file_keys_clear(&keys)
    aad:=chunk_aad(scope,epoch,file_id)
    hasher:blake3.Hasher
    p,begin:=store.put_begin(s)
    if begin!=.None {return {},{},0,store_error(begin)}
    defer if error!=.None {store.put_abandon(&p)}
    have,groups:=0,0
    ended:=false
    for {
        for !ended && have<len(buffer) {
            n,read_error:=os.read(file,buffer[have:])
            if n>0 {
                blake3.update(&hasher,buffer[have:][:n])
                have+=n
                size+=u64(n)
            }
            if read_error==.EOF || (n==0 && read_error==nil) {
                ended=true
            } else if read_error!=nil {
                return {},{},0,.Io
            }
        }
        at:=0
        for have-at>0 && (ended || have-at>=OVERLAY_CHUNK_MAX) {
            window:=buffer[at:][:min(have-at,OVERLAY_CHUNK_MAX)]
            cut:=store.chunk_cut(window)
            if groups>=OVERLAY_FILE_CHUNKS_MAX {return {},{},0,.Too_Large}
            sealed:=seal_chunk(z,&keys,aad[:],window[:cut]) or_return
            if e:=store.put_native(&p,OVERLAY_TAG,u32(groups),0,sealed,nil);e!=.None {return {},{},0,store_error(e)}
            groups+=1
            at+=cut
        }
        copy(buffer,buffer[at:have])
        have-=at
        if ended && have==0 {break}
    }
    content=store.Hash(blake3.final(&hasher))
    if groups==0 {
        store.put_abandon(&p)
        return {},content,0,.None
    }
    meta:=overlay_meta(.File)
    a,_,e:=store.put_finish(&p,meta[:])
    if e!=.None {return {},{},0,store_error(e)}
    return a,content,size,.None
}

// The plaintext of the sealed file object of entry, in allocator. Whatever
// does not open, or opens to another size or content, is Corrupt.
open_file :: proc(z:^Sealer,s:^store.Store,scope:Scope_Id,epoch:u32,key:^Epoch_Key,entry:^Overlay_Entry,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if entry.size>u64(OVERLAY_FILE_CHUNKS_MAX)*OVERLAY_CHUNK_MAX {return nil,.Corrupt}
    out,made:=make([]u8,int(entry.size),allocator)
    if made!=nil {return nil,.Out_Of_Memory}
    defer if error!=.None {delete(out,allocator)}
    if entry.size==0 {
        if entry.object!={} {return nil,.Corrupt}
        return out,.None
    }
    o,open:=store.object_open(s,entry.object)
    if open!=.None {return nil,store_error(open)}
    defer store.object_close(&o)
    overlay_kind_check(&o,.File) or_return
    groups:=store.object_groups(&o)
    total:=store.object_size(&o)
    if len(groups)==0 || len(groups)>OVERLAY_FILE_CHUNKS_MAX {return nil,.Corrupt}
    keys:=file_keys(key,entry.file_id)
    defer file_keys_clear(&keys)
    aad:=chunk_aad(scope,epoch,entry.file_id)
    at:=0
    for g,i in groups {
        end:=i+1<len(groups)?groups[i+1].offset:total
        if g.tag!=OVERLAY_TAG || g.index!=u32(i) || end<g.offset || end-g.offset>u64(len(z.sealed)) {return nil,.Corrupt}
        sealed:=z.sealed[:end-g.offset]
        if e:=store.group_read(&o,i,0,sealed);e!=.None {return nil,store_error(e)}
        plain:=open_chunk(z,&keys,aad[:],sealed) or_return
        if len(plain)>len(out)-at {return nil,.Corrupt}
        at+=copy(out[at:],plain)
    }
    if at!=len(out) || store.Hash(blake3.hash(out))!=entry.content {return nil,.Corrupt}
    return out,.None
}

// --- Overlay tree ---

Overlay_Entry_Head :: struct #packed {
    file_id:File_Id,
    object:store.Hash,  // the sealed file object; zero for an empty file
    content:store.Hash, // BLAKE3 of the plaintext
    size:u64,
    mtime_ns:i64,       // as the device that sealed it found it
    executable:b8,
    reserved:u8,
    path_len:u16,
}

Overlay_Entry :: struct {
    using head:Overlay_Entry_Head,
    path:string,
}

Overlay_Tree_Head :: struct #packed {
    magic:u32,
    version:u16,
    reserved:u16,
    count:u32,
} // + [count]Overlay_Entry_Head sorted by path, then the paths

// The additional data of a tree: "kai-1/tree" || project || scope_id || epoch.
@(private)
tree_aad :: proc(project:Log_Id,scope:Scope_Id,epoch:u32) -> (aad:[len(LABEL_TREE)+32+16+4]u8) {
    p,s:=project,scope
    copy(aad[:],LABEL_TREE)
    copy(aad[len(LABEL_TREE):],p[:])
    copy(aad[len(LABEL_TREE)+32:],s[:])
    put_u32(aad[len(LABEL_TREE)+48:],epoch)
    return
}

@(private)
tree_key :: proc(key:^Epoch_Key) -> (k:[32]u8) {
    hkdf.extract_and_expand(.SHA256,nil,key[:],transmute([]u8)string(LABEL_TREE),k[:])
    return
}

// The entries sealed: a random nonce || AEGIS-256 || tag, in allocator.
tree_seal :: proc(entries:[]Overlay_Entry,project:Log_Id,scope:Scope_Id,epoch:u32,key:^Epoch_Key,allocator:=context.allocator) -> (sealed:[]u8,error:Error) {
    if len(entries)>OVERLAY_FILES_MAX {return nil,.Too_Large}
    w:=writer_make(context.temp_allocator)
    write_value(&w,Overlay_Tree_Head{magic=OVERLAY_MAGIC,version=VERSION,count=u32(len(entries))})
    for e in entries {
        head:=e.head
        head.reserved,head.path_len=0,u16(len(e.path))
        write_value(&w,head)
    }
    for e in entries {write_string(&w,e.path)}
    if w.failed {return nil,.Out_Of_Memory}
    defer crypto.zero_explicit(raw_data(w.data),len(w.data))
    if len(w.data)>OVERLAY_TREE_MAX-SEAL_NONCE-SEAL_TAG {return nil,.Too_Large}
    made,made_error:=make([]u8,SEAL_NONCE+len(w.data)+SEAL_TAG,allocator)
    if made_error!=nil {return nil,.Out_Of_Memory}
    crypto.rand_bytes(made[:SEAL_NONCE])
    k:=tree_key(key)
    defer crypto.zero_explicit(&k,32)
    aad:=tree_aad(project,scope,epoch)
    aead_seal(k[:],made[:SEAL_NONCE],aad[:],w.data[:],made[SEAL_NONCE:][:len(w.data)],made[SEAL_NONCE+len(w.data):])
    return made,.None
}

// The entries of a sealed tree, checked; their paths point into plain, of allocator.
tree_open :: proc(sealed:[]u8,project:Log_Id,scope:Scope_Id,epoch:u32,key:^Epoch_Key,out:^[dynamic]Overlay_Entry,allocator:=context.allocator) -> (plain:[]u8,error:Error) {
    clear(out)
    if len(sealed)<SEAL_NONCE+SEAL_TAG+size_of(Overlay_Tree_Head) || len(sealed)>OVERLAY_TREE_MAX {return nil,.Corrupt}
    length:=len(sealed)-SEAL_NONCE-SEAL_TAG
    made:runtime.Allocator_Error
    if plain,made=make([]u8,length,allocator);made!=nil {return nil,.Out_Of_Memory}
    k:=tree_key(key)
    defer crypto.zero_explicit(&k,32)
    aad:=tree_aad(project,scope,epoch)
    if !aead_open(k[:],sealed[:SEAL_NONCE],aad[:],sealed[SEAL_NONCE:][:length],sealed[SEAL_NONCE+length:],plain) {
        delete(plain,allocator)
        return nil,.Corrupt
    }
    if error=tree_decode(plain,out);error!=.None {
        crypto.zero_explicit(raw_data(plain),len(plain))
        delete(plain,allocator)
        clear(out)
        return nil,error
    }
    return plain,.None
}

@(private)
tree_decode :: proc(plain:[]u8,out:^[dynamic]Overlay_Entry) -> Error {
    r:=Reader{data=plain}
    head:=read_value(&r,Overlay_Tree_Head)
    if r.short || head.magic!=OVERLAY_MAGIC || head.version!=VERSION || head.reserved!=0 || head.count>OVERLAY_FILES_MAX {return .Corrupt}
    if !count_fits(&r,u64(head.count),size_of(Overlay_Entry_Head)) {return .Corrupt}
    heads:=read_bytes(&r,int(head.count)*size_of(Overlay_Entry_Head))
    for k in 0..<int(head.count) {
        e:Overlay_Entry
        mem.copy_non_overlapping(&e.head,raw_data(heads[k*size_of(Overlay_Entry_Head):]),size_of(Overlay_Entry_Head))
        e.path=string(read_bytes(&r,int(e.path_len)))
        if r.short || e.reserved!=0 || u8(e.executable)>1 || !path_valid(e.path) || (e.size==0)!=(e.object=={}) {return .Corrupt}
        if len(out)>0 && out[len(out)-1].path>=e.path {return .Corrupt}
        if _,f:=append(out,e);f!=nil {return .Out_Of_Memory}
    }
    if r.at!=len(plain) {return .Corrupt}
    return .None
}

// --- Overlay records ---

Overlay_Record_Head :: struct #packed {
    magic:u32,
    version:u16,
    reserved:u16,
    seq:u64,            // 1 for the first record of a chain, one more than prev's after
    prev:store.Hash,    // the record this one follows; zero for the first
    commit:Revision,    // the public change whose private files these are
    project:Log_Id,
    scope:Scope_Id,
    epoch:u32,
    files:u32,
    tree_root:store.Hash, // the sealed tree object
    author:Key,
    time:i64,           // ns
} // + [files]store.Hash ascending, Signature

Overlay_Record :: struct {
    using head:Overlay_Record_Head,
    objects:[]store.Hash, // the sealed file objects
    signature:Signature,
}

overlay_record_encode :: proc(r:^Overlay_Record,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(r.objects)>OVERLAY_FILES_MAX {return nil,.Too_Large}
    for o,i in r.objects {
        if o=={} || (i>0 && !hash_less(r.objects[i-1],o)) {return nil,.Invalid_Argument}
    }
    if r.seq==0 || (r.seq==1)!=(r.prev=={}) || r.commit=={} || r.tree_root=={} || r.epoch==0 || r.author!=identity.key {return nil,.Invalid_Argument}
    head:=r.head
    head.magic,head.version,head.reserved,head.files=OVERLAY_MAGIC,VERSION,0,u32(len(r.objects))
    w:=writer_make(allocator)
    write_value(&w,head)
    write_bytes(&w,slice.to_bytes(r.objects))
    if w.failed {return nil,.Out_Of_Memory}
    r.signature=sign(identity,w.data[:])
    write_bytes(&w,r.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The record of bytes, checked but not its signature; objects points into bytes.
overlay_record_decode :: proc(bytes:[]u8) -> (r:Overlay_Record,error:Error) {
    rd:=Reader{data=bytes}
    r.head=read_value(&rd,Overlay_Record_Head)
    if rd.short || r.magic!=OVERLAY_MAGIC || r.version!=VERSION || r.reserved!=0 || r.files>OVERLAY_FILES_MAX {return {},.Corrupt}
    if r.seq==0 || (r.seq==1)!=(r.prev=={}) || r.commit=={} || r.tree_root=={} || r.epoch==0 {return {},.Corrupt}
    if !count_fits(&rd,u64(r.files),size_of(store.Hash)) {return {},.Corrupt}
    r.objects=slice.reinterpret([]store.Hash,read_bytes(&rd,int(r.files)*size_of(store.Hash)))
    for o,i in r.objects {
        if o=={} || (i>0 && !hash_less(r.objects[i-1],o)) {return {},.Corrupt}
    }
    r.signature=read_value(&rd,Signature)
    if rd.short || rd.at!=len(bytes) {return {},.Corrupt}
    return r,.None
}

// The namespace of a scope's overlays: kai-ovl-<project hex>-<scope hex>.
overlay_namespace :: proc(project:Log_Id,scope:Scope_Id,buffer:^[len(OVERLAY_PREFIX)+64+1+32]u8) -> string {
    hex:[64]u8
    copy(buffer[:],OVERLAY_PREFIX)
    copy(buffer[len(OVERLAY_PREFIX):],store.hex(project,&hex))
    buffer[len(OVERLAY_PREFIX)+64]='-'
    s:=scope
    hex_text(s[:],buffer[len(OVERLAY_PREFIX)+65:])
    return string(buffer[:])
}

// The project and scope of an overlay namespace.
overlay_namespace_parse :: proc(namespace:string) -> (project:Log_Id,scope:Scope_Id,ok:bool) {
    if len(namespace)!=len(OVERLAY_PREFIX)+64+1+32 || !strings.has_prefix(namespace,OVERLAY_PREFIX) || namespace[len(OVERLAY_PREFIX)+64]!='-' {return}
    project,ok=store.parse_hex(namespace[len(OVERLAY_PREFIX):][:64])
    if !ok {return}
    text:=namespace[len(OVERLAY_PREFIX)+65:]
    for k in 0..<16 {
        high,high_ok:=hex_value(text[2*k])
        low,low_ok:=hex_value(text[2*k+1])
        if !high_ok || !low_ok {return {},{},false}
        scope[k]=high<<4|low
    }
    return project,scope,true
}

@(private)
hex_value :: proc "contextless" (c:u8) -> (u8,bool) {
    switch c {
    case '0'..='9': return c-'0',true
    case 'a'..='f': return c-'a'+10,true
    }
    return 0,false
}

// The record held for scope at commit, its address and its bytes in allocator; Missing when none.
overlay_record_get :: proc(s:^store.Store,project:Log_Id,scope:Scope_Id,commit:Revision,allocator:=context.allocator) -> (r:Overlay_Record,address:store.Hash,error:Error) {
    ns:[len(OVERLAY_PREFIX)+64+1+32]u8
    name:[64]u8
    a,e:=store.ref_get(s,overlay_namespace(project,scope,&ns),store.hex(commit,&name))
    if e!=.None {return {},{},store_error(e)}
    bytes:=overlay_get(s,a,.Record,OVERLAY_RECORD_MAX,allocator) or_return
    r=overlay_record_decode(bytes) or_return
    if r.project!=project || r.scope!=scope || r.commit!=commit {return {},{},.Corrupt}
    return r,a,.None
}

// Why the record of scope at commit does not read: None when it does, Missing
// when there is none.
overlay_record_error :: proc(s:^store.Store,project:Log_Id,scope:Scope_Id,commit:Revision) -> Error {
    _,_,e:=overlay_record_get(s,project,scope,commit,context.temp_allocator)
    return e
}

// Signs and stores the record of scope at commit and points its ref at it: it
// follows base, or the record the ref holds when that one is newer.
@(private)
overlay_record_write :: proc(s:^store.Store,identity:^Identity,r:^Overlay_Record,base:store.Hash,base_seq:u64) -> (address:store.Hash,error:Error) {
    r.prev,r.seq=base,base_seq+1
    if held,held_address,e:=overlay_record_get(s,r.project,r.scope,r.commit,context.temp_allocator);e==.None && held.seq>=base_seq {
        r.prev,r.seq=held_address,held.seq+1
    }
    r.author=identity.key
    bytes:=overlay_record_encode(r,identity,context.temp_allocator) or_return
    address=overlay_put(s,.Record,bytes) or_return
    ns:[len(OVERLAY_PREFIX)+64+1+32]u8
    name:[64]u8
    if e:=store.ref_set(s,overlay_namespace(r.project,r.scope,&ns),store.hex(r.commit,&name),address);e!=.None {return {},store_error(e)}
    return address,.None
}

// Takes the record a peer gave at address for the ref namespace/name: signed
// by a device of a writer, of a scope of the org, and newer than the one held.
// The record's objects point into the temp allocator.
overlay_accept :: proc(s:^store.Store,org:^Org_Fold,namespace,name:string,address:store.Hash) -> (r:Overlay_Record,changed:bool,error:Error) {
    project,scope,ok:=overlay_namespace_parse(namespace)
    if !ok {return {},false,.Invalid_Argument}
    commit,commit_ok:=store.parse_hex(name)
    if !commit_ok {return {},false,.Invalid_Argument}
    known:=false
    for sc in org.scopes {
        if sc.project==project && sc.scope==scope {known=true}
    }
    if !known {return {},false,.Unauthorized}
    bytes:=overlay_get(s,address,.Record,OVERLAY_RECORD_MAX,context.temp_allocator) or_return
    r=overlay_record_decode(bytes) or_return
    if r.project!=project || r.scope!=scope || r.commit!=commit {return {},false,.Corrupt}
    if !signed_valid(bytes,r.author) {return {},false,.Unauthorized}
    if _,role:=org_device_role(org,r.author);role<.Writer {return {},false,.Unauthorized}
    held_address,e:=store.ref_get(s,namespace,name)
    if e==.None {
        if held_address==address {return r,false,.None}
        // Two writers of one seq: the lower address wins, so every peer keeps the same.
        if held,_,held_error:=overlay_record_get(s,project,scope,commit,context.temp_allocator);held_error==.None && (held.seq>r.seq || (held.seq==r.seq && hash_less(held_address,address))) {return {},false,.Rollback}
    } else if e!=.Missing {
        return {},false,store_error(e)
    }
    if set:=store.ref_set(s,namespace,name,address);set!=.None {return {},false,store_error(set)}
    return r,true,.None
}

// Whether the log whose index is at address is the Keyring_Log id of a scope
// of org: its genesis, read alone and verified, says.
keyring_of_org :: proc(s:^store.Store,org:^Org_Fold,id:Log_Id,address:store.Hash) -> bool {
    bytes,found,_:=log_entry_get(s,address,id)
    if !found {return false}
    entry,de:=entry_decode(bytes)
    if de!=.None || entry.type!=.Keyring_Genesis || !entry_verify(bytes,&entry) {return false}
    b,_,_:=body_head(entry.body,Keyring_Genesis_Body)
    if b.org!=org.log.id {return false}
    for sc in org.scopes {
        if sc.project==b.project && sc.scope==b.scope {return true}
    }
    return false
}

// Carries the overlay of scope at from to the commit to: a new record of the
// same sealed tree and objects, signed again, without any key.
overlay_rebase :: proc(s:^store.Store,identity:^Identity,project:Log_Id,scope:Scope_Id,from,to:Revision,time:i64) -> (address:store.Hash,error:Error) {
    if from==to {return {},.Invalid_Argument}
    old,old_address:=overlay_record_get(s,project,scope,from,context.temp_allocator) or_return
    r:=old
    r.commit,r.time=to,time
    return overlay_record_write(s,identity,&r,old_address,old.seq)
}

// --- Reading an overlay ---

// One opened overlay: its record, key and entries.
Overlay :: struct {
    record:Overlay_Record, // its objects in the temp allocator
    address:store.Hash,
    key:Epoch_Key,
    entries:[dynamic]Overlay_Entry,
    tree:[]u8, // what the paths point into
    allocator:runtime.Allocator,
}

// Opens the overlay of the keyring's scope at commit with device's key.
overlay_open :: proc(o:^Overlay,s:^store.Store,k:^Keyring_Fold,device:^Overlay_Device,commit:Revision,allocator:=context.allocator) -> (error:Error) {
    o^={allocator=allocator}
    o.entries=make([dynamic]Overlay_Entry,allocator)
    defer if error!=.None {overlay_close(o)}
    // One store per value until odin-lang/Odin#7937.
    record,address:=overlay_record_get(s,k.project,k.scope,commit,context.temp_allocator) or_return
    o.record=record
    o.address=address
    o.key=keyring_epoch_key(k,device,o.record.epoch) or_return
    sealed:=overlay_get(s,o.record.tree_root,.Tree,OVERLAY_TREE_MAX,context.temp_allocator) or_return
    o.tree=tree_open(sealed,k.project,k.scope,o.record.epoch,&o.key,&o.entries,allocator) or_return
    // The record names exactly the tree's file objects.
    objects:=make([dynamic]store.Hash,context.temp_allocator)
    for e in o.entries {
        if e.object!={} && !slice.contains(objects[:],e.object) {append(&objects,e.object)}
    }
    slice.sort_by(objects[:],hash_less)
    if !slice.equal(objects[:],o.record.objects) {return .Corrupt}
    return .None
}

overlay_close :: proc(o:^Overlay) {
    crypto.zero_explicit(&o.key,size_of(o.key))
    if o.tree!=nil {crypto.zero_explicit(raw_data(o.tree),len(o.tree))}
    delete(o.tree,o.allocator)
    delete(o.entries)
    o^={}
}

// The plaintext of the overlay's file at path, in allocator.
overlay_file :: proc(o:^Overlay,s:^store.Store,path:string,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    for &e in o.entries {
        if e.path!=path {continue}
        z:Sealer
        sealer_init(&z,context.temp_allocator) or_return
        defer sealer_destroy(&z)
        return open_file(&z,s,o.record.scope,o.record.epoch,&o.key,&e,allocator)
    }
    return nil,.Missing
}

// --- Routing a snapshot ---

// What a snapshot routes by: the org's scopes of the project and the keyrings
// this end has of them. org nil routes nothing and only applies the deny set.
Overlay_Routing :: struct {
    org:^Org_Fold,
    project:Log_Id,
    keyrings:[]^Keyring_Fold,
    device:Overlay_Device,
    public_allow:[]string, // patterns kai public add marked: deny-set paths they match stay public
    refused:string,        // out: why the last snapshot was refused, in the temp allocator
    refusal:Overlay_Refusal, // out: what refused it, of refused_path
    refused_path:string,   // out: in the temp allocator
    refused_scope:Scope_Id, // out: of a scoped path
}

// What refused a snapshot.
Overlay_Refusal :: enum u8 {
    None,
    Denied,     // a path of the deny set no scope takes: an admin keeps it public, or a scope takes it
    No_Keyring, // its scope has no keyring here yet
    Rotate,     // its scope's newest key is still readable by a removed member or device: a reader rotates it
    Unreadable, // this device cannot read its scope
}

@(private)
Plan_Scope :: struct {
    scope:Org_Scope,
    keyring:^Keyring_Fold,
    key:Epoch_Key,
    base:store.Hash, // the record this snapshot follows
    base_seq:u64,
    base_epoch:u32,
    base_tree:store.Hash,
    base_commit:Revision,
    unchanged:bool, // the files are base's: its sealed tree stays
    previous:[dynamic]Overlay_Entry,
    files:[dynamic]Overlay_Entry,
    objects:[dynamic]store.Hash,
    tree:store.Hash,
    readable:bool, // this device holds the key: it seals; otherwise it carries base
}

// The private part of one snapshot, between overlay_route and overlay_publish.
Overlay_Plan :: struct {
    scopes:[dynamic]Plan_Scope,
}

@(private)
keyring_of :: proc(r:^Overlay_Routing,scope:Scope_Id) -> ^Keyring_Fold {
    for k in r.keyrings {
        if k.project==r.project && k.scope==scope {return k}
    }
    return nil
}

@(private)
public_allowed :: proc(r:^Overlay_Routing,path:string) -> bool {
    if r==nil {return false}
    for p in r.public_allow {
        if glob_match(p,path) {return true}
    }
    return false
}

@(private)
plan_find :: proc(plan:^Overlay_Plan,scope:Scope_Id) -> ^Plan_Scope {
    for &p in plan.scopes {
        if p.scope.scope==scope {return &p}
    }
    return nil
}

// Takes the private files out of found, in the temp allocator: each path a
// scope's pattern matches goes into that scope's part of plan, sealed; a path
// of the deny set no scope takes and public_allow does not mark refuses the
// snapshot, as does a scoped path whose keyring must rotate first or that this
// device cannot read, unless the device may no longer read its scope and the
// file is its last copy, unchanged. previous are the revisions whose overlays
// this snapshot follows, the first that has one; their private paths not in
// found are stated again, so a snapshot of the touched paths keeps them.
overlay_route :: proc(r:^Overlay_Routing,s:^store.Store,root:string,previous:[]Revision,found:^[dynamic]Found,plan:^Overlay_Plan) -> Error {
    plan.scopes=make([dynamic]Plan_Scope,context.temp_allocator)
    if r!=nil {r.refused,r.refusal,r.refused_path,r.refused_scope="",.None,"",{}}
    if r!=nil && r.org!=nil {
        for sc in r.org.scopes {
            if sc.project!=r.project {continue}
            p:=Plan_Scope{scope=sc,keyring=keyring_of(r,sc.scope)}
            p.previous=make([dynamic]Overlay_Entry,context.temp_allocator)
            p.files=make([dynamic]Overlay_Entry,context.temp_allocator)
            p.objects=make([dynamic]store.Hash,context.temp_allocator)
            for rev in previous {
                rec,address,e:=overlay_record_get(s,r.project,sc.scope,rev,context.temp_allocator)
                if e==.Missing {continue}
                if e!=.None {return e}
                p.base,p.base_seq,p.base_epoch,p.base_tree,p.base_commit=address,rec.seq,rec.epoch,rec.tree_root,rec.commit
                if p.keyring==nil {break}
                key,key_error:=keyring_epoch_key(p.keyring,&r.device,rec.epoch)
                if key_error!=.None {break}
                defer crypto.zero_explicit(&key,size_of(key))
                sealed:=overlay_get(s,rec.tree_root,.Tree,OVERLAY_TREE_MAX,context.temp_allocator) or_return
                tree_open(sealed,r.project,sc.scope,rec.epoch,&key,&p.previous,context.temp_allocator) or_return
                break
            }
            if p.keyring!=nil && p.keyring.epoch>0 && !keyring_needs_rotation(p.keyring) {
                if key,e:=keyring_epoch_key(p.keyring,&r.device,p.keyring.epoch);e==.None {
                    p.key,p.readable=key,true
                }
            }
            if _,e:=append(&plan.scopes,p);e!=nil {return .Out_Of_Memory}
            // A private path of the overlay followed that this scan did not list.
            for e in p.previous {
                _,listed:=slice.binary_search_by(found[:],e.path,proc(f:Found,path:string) -> slice.Ordering {return slice.cmp(f.path,path)})
                if listed {continue}
                info,stat_error:=os.lstat(workspace_join(root,e.path),context.temp_allocator)
                if stat_error!=nil || info.type!=.Regular {continue}
                if _,f:=append(found,found_of(e.path,info));f!=nil {return .Out_Of_Memory}
            }
            slice.sort_by(found[:],proc(a,b:Found) -> bool {return a.path<b.path})
        }
    }
    org:^Org_Fold
    project:Log_Id
    if r!=nil {org,project=r.org,r.project}
    kept:=0
    for f in found {
        sc,scoped:=scope_of(org,project,f.path)
        if !scoped {
            if overlay_denied(f.path) && !public_allowed(r,f.path) {
                if r!=nil {
                    r.refused=strings.concatenate({f.path,": a path of the deny set: scope it with mirai kai scope add, or an admin keeps it public with mirai kai public add ",f.path},context.temp_allocator)
                    r.refusal,r.refused_path=.Denied,strings.clone(f.path,context.temp_allocator)
                }
                return .Unauthorized
            }
            found[kept]=f
            kept+=1
            continue
        }
        p:=plan_find(plan,sc.scope)
        // A device that may no longer read the scope leaves its last copy
        // out: the record it follows is carried as it is.
        if !p.readable && p.keyring!=nil && !device_reads(r.org,sc,&r.device) {
            hash,_,he:=plain_hash(workspace_join(root,f.path))
            unchanged:=false
            for e in p.previous {unchanged||=he==.None && e.path==f.path && e.content==hash}
            if unchanged {continue}
        }
        refusal:=Overlay_Refusal.None
        switch {
        case p.keyring==nil || p.keyring.epoch==0: refusal=.No_Keyring
        case keyring_needs_rotation(p.keyring): refusal=.Rotate
        case !p.readable: refusal=.Unreadable
        }
        if refusal!=.None {r.refusal,r.refused_path,r.refused_scope=refusal,strings.clone(f.path,context.temp_allocator),sc.scope}
        switch refusal {
        case .None,.Denied:
        case .No_Keyring:
            r.refused=strings.concatenate({f.path,": its scope has no keyring here: let the agent fetch the org's logs"},context.temp_allocator)
            return .Unauthorized
        case .Rotate:
            id:=sc.scope
            buffer:[32]u8
            r.refused=strings.concatenate({f.path,": its scope's newest key is still readable by a removed member or device: a reader rotates it with mirai kai scope rotate ",hex_text(id[:4],buffer[:])},context.temp_allocator)
            return .Unauthorized
        case .Unreadable:
            r.refused=strings.concatenate({f.path,": this device cannot read its scope"},context.temp_allocator)
            return .Unauthorized
        }
        if len(p.files)>=OVERLAY_FILES_MAX {return .Too_Large}
        e:Overlay_Entry
        e.path,e.size,e.mtime_ns,e.executable=f.path,f.size,f.mtime_ns,b8(f.executable)
        if _,g:=append(&p.files,e);g!=nil {return .Out_Of_Memory}
    }
    base.truncate(found,kept)
    return overlay_seal(r,s,root,plan)
}

@(private)
workspace_join :: proc(root,relative:string) -> string {
    return strings.concatenate({root,"/",relative},context.temp_allocator)
}

// Seals the files of each readable scope of plan and their tree. A file that
// kept its path, size and settled time in an overlay of the same epoch keeps
// its object; any other keeps the file id of its path, or of a vanished path
// of the same content (a rename), or takes a new one.
@(private)
overlay_seal :: proc(r:^Overlay_Routing,s:^store.Store,root:string,plan:^Overlay_Plan) -> Error {
    z:Sealer
    sealer_init(&z,context.temp_allocator) or_return
    defer sealer_destroy(&z)
    now:=time.now()._nsec
    for &p in plan.scopes {
        if !p.readable {continue}
        epoch:=p.keyring.epoch
        taken:=make([]bool,len(p.previous),context.temp_allocator)
        kept:=make([]bool,len(p.files),context.temp_allocator)
        for &f,i in p.files {
            at,same:=slice.binary_search_by(p.previous[:],f.path,proc(e:Overlay_Entry,path:string) -> slice.Ordering {return slice.cmp(e.path,path)})
            if !same {continue}
            taken[at]=true
            old:=p.previous[at]
            f.file_id=old.file_id
            if p.base_epoch==epoch && old.size==f.size && old.mtime_ns==f.mtime_ns && now-f.mtime_ns>SETTLED_NANOSECONDS && (old.object=={} || object_present(s,old.object)) {
                executable:=f.executable
                f.head=old.head
                f.executable=executable
                kept[i]=true
            }
        }
        for &f,i in p.files {
            if kept[i] {continue}
            if f.file_id=={} {
                // A path new to the overlay takes the id of a vanished path of the same content.
                content,_,e:=plain_hash(workspace_join(root,f.path))
                if e!=.None {return e}
                for old,k in p.previous {
                    if !taken[k] && old.content==content {
                        f.file_id,taken[k]=old.file_id,true
                        break
                    }
                }
                if f.file_id=={} {f.file_id=random_id(File_Id)}
            }
            f.object,f.content,f.size=seal_file(&z,s,workspace_join(root,f.path),p.scope.scope,epoch,&p.key,f.file_id) or_return
        }
        for f in p.files {
            if f.object!={} && !slice.contains(p.objects[:],f.object) {append(&p.objects,f.object)}
        }
        slice.sort_by(p.objects[:],hash_less)
        p.unchanged=p.base!={} && p.base_epoch==epoch && len(p.files)==len(p.previous) && !slice.contains(kept,false)
        for f,i in p.files {
            if p.unchanged && f.executable!=p.previous[i].executable {p.unchanged=false}
        }
        if p.unchanged {
            p.tree=p.base_tree
            continue
        }
        sealed:=tree_seal(p.files[:],r.project,p.scope.scope,epoch,&p.key,context.temp_allocator) or_return
        p.tree=overlay_put(s,.Tree,sealed) or_return
    }
    return .None
}

// The BLAKE3 of the file at path.
@(private)
plain_hash :: proc(path:string) -> (hash:store.Hash,size:u64,error:Error) {
    file,open_error:=os.open(path)
    if open_error!=nil {return {},0,.Io}
    defer os.close(file)
    buffer,made:=make([]u8,READ_BYTES,context.temp_allocator)
    if made!=nil {return {},0,.Out_Of_Memory}
    defer crypto.zero_explicit(raw_data(buffer),len(buffer))
    h:blake3.Hasher
    for {
        n,read_error:=os.read(file,buffer)
        if n>0 {
            blake3.update(&h,buffer[:n])
            size+=u64(n)
        }
        if read_error==.EOF || (n==0 && read_error==nil) {break}
        if read_error!=nil {return {},0,.Io}
    }
    return store.Hash(blake3.final(&h)),size,.None
}

// Writes the records of plan for the public change commit: each readable
// scope's sealed tree, and for a scope this device cannot read, the overlay it
// followed, carried unchanged. A readable scope with no files and none before
// writes nothing.
overlay_publish :: proc(r:^Overlay_Routing,s:^store.Store,plan:^Overlay_Plan,commit:Revision) -> Error {
    if r==nil {return .None}
    t:=time.now()._nsec
    for &p in plan.scopes {
        if p.readable {
            if (len(p.files)==0 && p.base=={}) || (p.unchanged && p.base_commit==commit) {continue}
            rec:=Overlay_Record{head={commit=commit,project=r.project,scope=p.scope.scope,epoch=p.keyring.epoch,tree_root=p.tree,time=t},objects=p.objects[:]}
            overlay_record_write(s,&r.device.identity,&rec,p.base,p.base_seq) or_return
        } else if p.base!={} {
            base:=overlay_get(s,p.base,.Record,OVERLAY_RECORD_MAX,context.temp_allocator) or_return
            rec:=overlay_record_decode(base) or_return
            if rec.commit==commit {continue}
            rec.commit,rec.time=commit,t
            overlay_record_write(s,&r.device.identity,&rec,p.base,rec.seq) or_return
        }
    }
    return .None
}

// Clears the keys of plan.
overlay_plan_end :: proc(plan:^Overlay_Plan) {
    for &p in plan.scopes {crypto.zero_explicit(&p.key,size_of(p.key))}
}

// The revisions whose overlays a snapshot of r's working copy follows: the
// working revision, then its parents.
overlay_previous :: proc(r:^Repo) -> []Revision {
    previous:=make([dynamic]Revision,context.temp_allocator)
    working:=repo_working(r)
    if working=={} {return nil}
    append(&previous,working)
    if c,e:=change_get(r.s,working,context.temp_allocator);e==.None {append(&previous,..c.parents)}
    return previous[:]
}

// The private files a reader's working copy shows: after a move from the
// change before to the change after, the files each scope this device reads
// holds at after are written, and those it held at before and not at after
// are removed while they still hold what before had. A change holds the
// files of its own overlay or, before it has one, of its first parent's. A
// scope this device may no longer read takes its files away.
overlay_checkout :: proc(r:^Overlay_Routing,s:^store.Store,root:string,before,after:Revision) -> Error {
    if r==nil || r.org==nil {return .None}
    z:Sealer
    sealer_init(&z,context.temp_allocator) or_return
    defer sealer_destroy(&z)
    for sc in r.org.scopes {
        if sc.project!=r.project {continue}
        k:=keyring_of(r,sc.scope)
        if k==nil {continue}
        old:=make([dynamic]Overlay_Entry,context.temp_allocator)
        new:=make([dynamic]Overlay_Entry,context.temp_allocator)
        epoch:u32
        key:Epoch_Key
        defer crypto.zero_explicit(&key,size_of(key))
        // An epoch this device holds no key of is no file of its.
        if e:=overlay_entries_at(r,s,k,before,&old,nil,nil);e!=.None && e!=.Unauthorized {return e}
        if device_reads(r.org,sc,&r.device) {overlay_entries_at(r,s,k,after,&new,&epoch,&key) or_return}
        for &e in new {
            path:=workspace_join(root,e.path)
            if hash,_,he:=plain_hash(path);he==.None && hash==e.content {continue}
            bytes:=open_file(&z,s,sc.scope,epoch,&key,&e,context.temp_allocator) or_return
            defer crypto.zero_explicit(raw_data(bytes),len(bytes))
            if dir,_:=os.split_path(path);dir!="" {
                if os.make_directory_all(dir)!=nil && !os.is_dir(dir) {return .Io}
            }
            file_replace(path,bytes,bool(e.executable)) or_return
        }
        for e in old {
            kept:=false
            for n in new {kept||=n.path==e.path}
            if kept {continue}
            path:=workspace_join(root,e.path)
            if hash,_,he:=plain_hash(path);he==.None && hash==e.content {os.remove(path)}
        }
    }
    return .None
}

// The entries of the overlay of k's scope at revision, or at its first parent
// that has one, and the key of its epoch.
@(private)
overlay_entries_at :: proc(r:^Overlay_Routing,s:^store.Store,k:^Keyring_Fold,revision:Revision,out:^[dynamic]Overlay_Entry,epoch:^u32,key:^Epoch_Key) -> Error {
    if revision=={} {return .None}
    candidates:=make([dynamic]Revision,context.temp_allocator)
    append(&candidates,revision)
    if c,e:=change_get(s,revision,context.temp_allocator);e==.None {append(&candidates,..c.parents)}
    for rev in candidates {
        rec,_,e:=overlay_record_get(s,r.project,k.scope,rev,context.temp_allocator)
        if e==.Missing {continue}
        if e!=.None {return e}
        x:=keyring_epoch_key(k,&r.device,rec.epoch) or_return
        defer crypto.zero_explicit(&x,size_of(x))
        sealed:=overlay_get(s,rec.tree_root,.Tree,OVERLAY_TREE_MAX,context.temp_allocator) or_return
        tree_open(sealed,r.project,k.scope,rec.epoch,&x,out,context.temp_allocator) or_return
        if epoch!=nil {epoch^,key^=rec.epoch,x}
        return .None
    }
    return .None
}

// --- Derived data of private inputs ---

// The scopes of the project that inputs fall in, in Org_Log order: what an
// output built from them inherits.
overlay_taint :: proc(org:^Org_Fold,project:Log_Id,inputs:[]string,out:^[dynamic]Scope_Id) -> Error {
    clear(out)
    for path in inputs {
        sc,scoped:=scope_of(org,project,path)
        if !scoped || slice.contains(out[:],sc.scope) {continue}
        if len(out)>=TAINTED_MAX {return .Too_Large}
        if _,e:=append(out,sc.scope);e!=nil {return .Out_Of_Memory}
    }
    return .None
}

Blob_Head :: struct #packed {
    magic:u32,
    version:u16,
    scopes:u8,
    reserved:u8,
    project:Log_Id,
} // + scopes × (Scope_Id, u32 epoch), then nonce || AEGIS-256 || tag

@(private)
blob_key :: proc(keys:[]Epoch_Key,head:[]u8) -> (k:[32]u8) {
    ikm,made:=make([]u8,len(keys)*32,context.temp_allocator)
    if made!=nil {return}
    defer crypto.zero_explicit(raw_data(ikm),len(ikm))
    for &key,i in keys {copy(ikm[32*i:],key[:])}
    info:=strings.concatenate({LABEL_BLOB,string(head)},context.temp_allocator)
    hkdf.extract_and_expand(.SHA256,nil,ikm,transmute([]u8)info,k[:])
    return
}

// Seals an output built from inputs of scopes under the newest epoch of every
// one of them at once: only a device that reads them all opens it. Its
// address is what ddc_publish records, with scopes as its tainted scopes.
overlay_blob_seal :: proc(s:^store.Store,keyrings:[]^Keyring_Fold,device:^Overlay_Device,project:Log_Id,scopes:[]Scope_Id,bytes:[]u8) -> (address:store.Hash,error:Error) {
    if len(scopes)==0 || len(scopes)>TAINTED_MAX {return {},.Invalid_Argument}
    if len(bytes)>OVERLAY_BLOB_MAX {return {},.Too_Large}
    w:=writer_make(context.temp_allocator)
    write_value(&w,Blob_Head{magic=OVERLAY_MAGIC,version=VERSION,scopes=u8(len(scopes)),project=project})
    keys:=make([]Epoch_Key,len(scopes),context.temp_allocator)
    defer crypto.zero_explicit(raw_data(keys),len(keys)*size_of(Epoch_Key))
    for sc,i in scopes {
        k:^Keyring_Fold
        for kr in keyrings {
            if kr.project==project && kr.scope==sc {k=kr}
        }
        if k==nil || keyring_needs_rotation(k) {return {},.Unauthorized}
        keys[i]=keyring_epoch_key(k,device,k.epoch) or_return
        id:=sc
        write_bytes(&w,id[:])
        write_value(&w,u32le(k.epoch))
    }
    if w.failed {return {},.Out_Of_Memory}
    head:=len(w.data)
    if resize(&w.data,head+SEAL_NONCE+len(bytes)+SEAL_TAG)!=nil {return {},.Out_Of_Memory}
    crypto.rand_bytes(w.data[head:][:SEAL_NONCE])
    k:=blob_key(keys,w.data[:head])
    defer crypto.zero_explicit(&k,32)
    aead_seal(k[:],w.data[head:][:SEAL_NONCE],w.data[:head],bytes,w.data[head+SEAL_NONCE:][:len(bytes)],w.data[head+SEAL_NONCE+len(bytes):])
    return overlay_put(s,.Blob,w.data[:])
}

// The bytes of a sealed output, in allocator, and the scopes it is sealed under.
overlay_blob_open :: proc(s:^store.Store,keyrings:[]^Keyring_Fold,device:^Overlay_Device,address:store.Hash,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    sealed:=overlay_get(s,address,.Blob,OVERLAY_BLOB_MAX+(1<<16),context.temp_allocator) or_return
    r:=Reader{data=sealed}
    head:=read_value(&r,Blob_Head)
    if r.short || head.magic!=OVERLAY_MAGIC || head.version!=VERSION || head.reserved!=0 || head.scopes==0 || int(head.scopes)>TAINTED_MAX {return nil,.Corrupt}
    keys:=make([]Epoch_Key,int(head.scopes),context.temp_allocator)
    defer crypto.zero_explicit(raw_data(keys),len(keys)*size_of(Epoch_Key))
    for i in 0..<int(head.scopes) {
        sc:=read_value(&r,Scope_Id)
        epoch:=u32(read_value(&r,u32le))
        if r.short {return nil,.Corrupt}
        k:^Keyring_Fold
        for kr in keyrings {
            if kr.project==head.project && kr.scope==sc {k=kr}
        }
        if k==nil {return nil,.Unauthorized}
        keys[i]=keyring_epoch_key(k,device,epoch) or_return
    }
    at:=r.at
    if len(sealed)-at<SEAL_NONCE+SEAL_TAG {return nil,.Corrupt}
    length:=len(sealed)-at-SEAL_NONCE-SEAL_TAG
    out,made:=make([]u8,length,allocator)
    if made!=nil {return nil,.Out_Of_Memory}
    k:=blob_key(keys,sealed[:at])
    defer crypto.zero_explicit(&k,32)
    if !aead_open(k[:],sealed[at:][:SEAL_NONCE],sealed[:at],sealed[at+SEAL_NONCE:][:length],sealed[at+SEAL_NONCE+length:],out) {
        delete(out,allocator)
        return nil,.Corrupt
    }
    return out,.None
}

// --- Publish scanner ---

Leak_Kind :: enum u8 {Private_Key,Token,Assignment}

// A line a publish to public would leak: fingerprint names it without its
// secret, for a waiver.
Leak :: struct {
    path:string,
    line:int, // from 1
    kind:Leak_Kind,
    fingerprint:store.Hash,
}

// Prefixes of tokens issuers give, each followed by at least TOKEN_TAIL_MIN token characters.
@(private) TOKEN_PREFIXES :: [?]string{"ghp_","gho_","ghu_","ghs_","ghr_","github_pat_","glpat-","xoxb-","xoxp-","xoxa-","xapp-","sk_live_","rk_live_","sk-proj-","sk-ant-","AKIA","ASIA","AIza","npm_","pypi-","hf_","SG."}
@(private) TOKEN_TAIL_MIN :: 16
@(private) SECRET_WORDS :: [?]string{"KEY","SECRET","TOKEN","PASSWORD","PASSWD","PWD","CREDENTIAL","AUTH","PRIVATE"}
@(private) ASSIGNMENT_VALUE_MIN :: 16
@(private) ASSIGNMENT_BITS_MIN :: 3.5 // Shannon entropy per character of a value a scanner flags

@(private)
token_char :: proc "contextless" (c:u8) -> bool {
    return (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_' || c=='-' || c=='.' || c=='/' || c=='+' || c=='='
}

@(private)
entropy :: proc(text:string) -> f64 {
    counts:[256]int
    for i in 0..<len(text) {counts[text[i]]+=1}
    total:=f64(len(text))
    h:=0.0
    for c in counts {
        if c==0 {continue}
        p:=f64(c)/total
        h-=p*math.log2(p)
    }
    return h
}

// What one line leaks, if anything.
@(private)
line_leak :: proc(line:string) -> (kind:Leak_Kind,found:bool) {
    if strings.contains(line,"-----BEGIN ") && strings.contains(line,"PRIVATE KEY") {return .Private_Key,true}
    prefixes:=TOKEN_PREFIXES
    for p in prefixes {
        for at:=strings.index(line,p);at>=0; {
            before:=at==0 || !token_char(line[at-1])
            tail:=0
            for at+len(p)+tail<len(line) && token_char(line[at+len(p)+tail]) {tail+=1}
            if before && tail>=TOKEN_TAIL_MIN {return .Token,true}
            next:=strings.index(line[at+1:],p)
            at=next<0?-1:at+1+next
        }
    }
    // NAME=value or NAME: value, the name naming a secret and the value long and random.
    t:=strings.trim_space(line)
    t=strings.trim_prefix(t,"export ")
    eq:=strings.index_any(t,"=:")
    if eq<=0 {return}
    name:=strings.trim_space(t[:eq])
    for i in 0..<len(name) {
        c:=name[i]
        if !((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_' || c=='-' || c=='.') {return}
    }
    value:=strings.trim_space(t[eq+1:])
    value=strings.trim(value,"\"'`,;")
    if len(value)<ASSIGNMENT_VALUE_MIN || strings.index_any(value," \t")>=0 {return}
    upper:=strings.to_upper(name,context.temp_allocator)
    words:=SECRET_WORDS
    for w in words {
        if strings.contains(upper,w) && entropy(value)>=ASSIGNMENT_BITS_MIN {return .Assignment,true}
    }
    return
}

@(private)
leak_fingerprint :: proc(path:string,line:string) -> store.Hash {
    separator:=[1]u8{0}
    return store.Hash(keyed_hash(transmute([]u8)string(LABEL_LEAK),transmute([]u8)path,separator[:],transmute([]u8)line))
}

// The leaks a publish of tree to would add over tree from (zero: everything
// in to): each line of an added or changed text file that holds a private
// key, a token of a known issuer or a long random value assigned to a name
// of a secret, unless an admin waived its fingerprint for the project with a
// Public_Add of the org's log. A file with a NUL in its first block is binary
// and not read.
publish_scan :: proc(s:^store.Store,org:^Org_Fold,project:Log_Id,from,to:store.Hash,out:^[dynamic]Leak,allocator:=context.allocator) -> Error {
    clear(out)
    diffs:=make([dynamic]Diff,context.temp_allocator)
    tree_diff(s,from,to,&diffs,context.temp_allocator) or_return
    buffer,made:=make([]u8,READ_BYTES,context.temp_allocator)
    if made!=nil {return .Out_Of_Memory}
    line_buffer:=make([dynamic]u8,context.temp_allocator)
    for d in diffs {
        if d.after.address=={} || (d.after.kind!=.File && d.after.kind!=.Executable) {continue}
        o,open:=store.object_open(s,d.after.address)
        if open!=.None {return store_error(open)}
        defer store.object_close(&o)
        size:=store.object_size(&o)
        number:=1
        clear(&line_buffer)
        for at:=u64(0);at<size; {
            n:=int(min(u64(len(buffer)),size-at))
            if e:=store.object_read(&o,at,buffer[:n]);e!=.None {return store_error(e)}
            if at==0 && slice.contains(buffer[:min(n,8192)],0) {break}
            at+=u64(n)
            for c in buffer[:n] {
                if c!='\n' {
                    if len(line_buffer)<SCAN_LINE_MAX {append(&line_buffer,c)}
                    continue
                }
                scan_line(org,project,d.path,string(line_buffer[:]),number,out,allocator) or_return
                clear(&line_buffer)
                number+=1
            }
        }
        if len(line_buffer)>0 {scan_line(org,project,d.path,string(line_buffer[:]),number,out,allocator) or_return}
    }
    return .None
}

@(private)
scan_line :: proc(org:^Org_Fold,project:Log_Id,path,line:string,number:int,out:^[dynamic]Leak,allocator:runtime.Allocator) -> Error {
    kind,found:=line_leak(strings.trim_right(line,"\r"))
    if !found {return .None}
    fingerprint:=leak_fingerprint(path,line)
    if org!=nil {
        for p in org.publics {
            if p.project==project && p.fingerprint==fingerprint {return .None}
        }
    }
    p,e:=strings.clone(path,allocator)
    if e!=nil {return .Out_Of_Memory}
    if _,f:=append(out,Leak{path=p,line=number,kind=kind,fingerprint=fingerprint});f!=nil {return .Out_Of_Memory}
    return .None
}
