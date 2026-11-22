// Kai: the version control of Mirai, engine-agnostic. Every record is one
// object of the store with KAI_MAGIC, its kind and its version in the meta of
// its root, and in its bytes a #packed little-endian head, count-prefixed flat
// arrays and a trailing string pool. Stored records hold no pointers, reserved
// bytes are zero, and whatever a decode reads is checked: hostile bytes are
// Corrupt, another version is refused without migration.
package kai

import "base:runtime"
import "core:crypto"
import "core:crypto/ed25519"
import "core:mem"
import "mirai:store"

KAI_MAGIC :: u32('K')|u32('A')<<8|u32('I')<<16|u32('1')<<24
VERSION :: 1 // of every kind of record

Change_Id :: distinct [16]u8 // random at creation, kept across rewrites
Revision :: store.Hash        // the address of one Change object
Key :: distinct [32]u8        // Ed25519 public key
Dh_Key :: distinct [32]u8     // X25519 static public key
Signature :: distinct [64]u8
Repo_Id :: distinct [16]u8
Workspace_Id :: distinct [16]u8

// An agent's turn a change records: the agent's Identity object, the public
// review record of the turn and the task it served.
Turn_Ref :: struct #packed {
    agent:store.Hash,
    record:store.Hash,
    task:u64,
}

// Who signs: an Ed25519 public key and the seed of its private key.
Identity :: struct {
    key:Key,
    seed:[32]u8,
}

Object_Kind :: enum u8 {None,Folder,Conflict,Change,View,Operation,Stat_Index,Log,Device_Refs,DDC_Set,DDC_Output,Log_Page}

Error :: enum u8 {
    None,
    Corrupt,          // bytes that are not a valid record of this version
    Missing,          // an object or ref that is not in the store
    Too_Large,        // past one of the bounds below
    Invalid_Argument,
    Out_Of_Memory,
    Io,
    No_Space,
    Locked,           // another process holds the workspace
    Stale,            // the workspace's change is no longer in the view
    Unsupported,      // the system cannot do it here (a reflink across volumes)
    Unauthorized,     // a signature, or the right of its author, does not hold
    Rollback,         // a signed record not newer than the one held
    Expired,          // past the time a signed record allows
    Other_Store,      // the repository of a workspace is not in the store it is opened with
    Pruned,           // an operation behind a prune of the operation log, which undo does not cross
}

error_text :: proc(error:Error) -> string {
    switch error {
    case .None: return "no error"
    case .Corrupt: return "a Kai record does not read: fetch it again from a peer"
    case .Missing: return "an object of the repository is not in the store: fetch it from a peer"
    case .Too_Large: return "past a bound of Kai (files, folder entries, depth, path, parents, sides of a conflict or entries of a log): split it"
    case .Invalid_Argument: return "an argument out of its range"
    case .Out_Of_Memory: return "memory ran out"
    case .Io: return "the file system refused an operation: give this user access to the folder"
    case .No_Space: return "the volume is full: free space there"
    case .Locked: return "another process holds this workspace: close it first"
    case .Stale: return "the workspace's change is gone from the repository: switch to another change"
    case .Other_Store: return "the repository of this folder's workspace is not in this store: open it with the store it was made in, or delete its .mirai/kai folder to start a new history here"
    case .Unsupported: return "the file system cannot do it here"
    case .Unauthorized: return "a signature or the right of its author does not hold: fetch the logs of the org again, or ask an admin for the right"
    case .Rollback: return "a record older than the one held: a peer offered stale refs, fetch from another"
    case .Expired: return "the signed record is past its time: ask its issuer for a new one"
    case .Pruned: return "that operation is behind a prune of the operation log, which undo does not cross: restore an older change with mirai kai restore instead"
    }
    return ""
}

PARENTS_MAX :: 255
COAUTHORS_MAX :: 64
TURNS_MAX :: 64
CONFLICT_SIDES_MAX :: 16
CONFLICT_TERMS_MAX :: 2*CONFLICT_SIDES_MAX-1
DESCRIPTION_MAX :: 1<<20      // bytes of the description of a change or operation
FILES_MAX :: 1<<22            // files of a tree
FOLDER_ENTRIES_MAX :: 1<<16   // entries of one folder
DEPTH_MAX :: 64               // folders on the path of a file
PATH_MAX :: 1024              // bytes of a path
NAME_BYTES_MAX :: 255         // bytes of one name of a path
HEADS_MAX :: 1<<16
WORKSPACES_MAX :: 1024
BOOKMARKS_MAX :: 1<<16
BOOKMARK_NAME_MAX :: 255
REWRITES_MAX :: 1<<20
OP_PARENTS_MAX :: 255
RECORD_MAX :: 1<<30           // bytes of one record object

// What the root of every Kai object carries as meta, before what a kind adds.
Meta :: struct #packed {
    magic:u32,
    kind:Object_Kind,
    reserved:u8,
    version:u16,
}

// The Kai error of a store error.
store_error :: proc "contextless" (e:store.Error) -> Error {
    #partial switch e {
    case .None: return .None
    case .Missing: return .Missing
    case .Corrupt,.Unsupported_Layout: return .Corrupt
    case .Out_Of_Memory: return .Out_Of_Memory
    case .No_Space: return .No_Space
    case .Invalid_Argument: return .Invalid_Argument
    }
    return .Io
}

// Puts bytes as an object of kind, uncommitted: the commit of the operation
// that names it makes it durable.
object_put :: proc(s:^store.Store,kind:Object_Kind,bytes:[]u8,extra:[]u8={}) -> (address:store.Hash,error:Error) {
    if len(bytes)>RECORD_MAX {return {},.Too_Large}
    p,begin:=store.put_begin(s)
    if begin!=.None {return {},store_error(begin)}
    if e:=store.put_write(&p,bytes);e!=.None {
        store.put_abandon(&p)
        return {},store_error(e)
    }
    meta:[size_of(Meta)+64]u8
    if len(extra)>64 {
        store.put_abandon(&p)
        return {},.Invalid_Argument
    }
    head:=Meta{magic=KAI_MAGIC,kind=kind,version=VERSION}
    copy(meta[:],mem.ptr_to_bytes(&head))
    copy(meta[size_of(Meta):],extra)
    a,_,e:=store.put_finish(&p,meta[:size_of(Meta)+len(extra)])
    return a,store_error(e)
}

// The bytes of the object at address, which must be a record of kind; extra
// is what the meta carries after Meta, into extra_out.
object_get :: proc(s:^store.Store,address:store.Hash,kind:Object_Kind,allocator:=context.allocator,extra_out:[]u8=nil) -> (bytes:[]u8,error:Error) {
    o,open:=store.object_open(s,address)
    if open!=.None {return nil,store_error(open)}
    defer store.object_close(&o)
    meta:=store.object_meta(&o)
    meta_check(meta,kind,len(extra_out)) or_return
    copy(extra_out,meta[size_of(Meta):])
    size:=store.object_size(&o)
    if size>RECORD_MAX {return nil,.Too_Large}
    made,made_error:=make([]u8,int(size),allocator)
    if made_error!=nil {return nil,.Out_Of_Memory}
    if e:=store.object_read(&o,0,made);e!=.None {
        delete(made,allocator)
        return nil,store_error(e)
    }
    return made,.None
}

@(private)
meta_check :: proc "contextless" (meta:[]u8,kind:Object_Kind,extra:int) -> Error {
    if len(meta)!=size_of(Meta)+extra {return .Corrupt}
    head:=(^Meta)(raw_data(meta))^
    if head.magic!=KAI_MAGIC || head.kind!=kind || head.reserved!=0 || head.version!=VERSION {return .Corrupt}
    return .None
}

// Random bytes for ids.
random_id :: proc($T:typeid) -> (id:T) {
    crypto.rand_bytes(mem.ptr_to_bytes(&id))
    return
}

// A new signing identity.
identity_make :: proc() -> (identity:Identity) {
    crypto.rand_bytes(identity.seed[:])
    identity_derive(&identity)
    return
}

// Sets the key of identity from its seed.
identity_derive :: proc(identity:^Identity) -> bool {
    private:ed25519.Private_Key
    if !ed25519.private_key_set_bytes(&private,identity.seed[:]) {return false}
    defer ed25519.private_key_clear(&private)
    ed25519.private_key_public_bytes(&private,identity.key[:])
    return true
}

@(private)
sign :: proc(identity:^Identity,message:[]u8) -> (signature:Signature) {
    private:ed25519.Private_Key
    if !ed25519.private_key_set_bytes(&private,identity.seed[:]) {return}
    defer ed25519.private_key_clear(&private)
    ed25519.sign(&private,message,signature[:])
    return
}

@(private)
signature_valid :: proc(key:Key,message:[]u8,signature:Signature) -> bool {
    public:ed25519.Public_Key
    k,sig:=key,signature
    if !ed25519.public_key_set_bytes(&public,k[:]) {return false}
    return ed25519.verify(&public,message,sig[:])
}

// Writes records: appends to a buffer of the caller's allocator.
@(private)
Writer :: struct {
    data:[dynamic]u8,
    failed:bool,
}

@(private)
writer_make :: proc(allocator:runtime.Allocator) -> Writer {
    return {data=make([dynamic]u8,allocator)}
}

@(private)
write_bytes :: proc(w:^Writer,bytes:[]u8) {
    if w.failed {return}
    if _,e:=append(&w.data,..bytes);e!=nil {w.failed=true}
}

@(private)
write_value :: proc(w:^Writer,value:$T) {
    v:=value
    write_bytes(w,mem.ptr_to_bytes(&v))
}

@(private)
write_string :: proc(w:^Writer,text:string) {write_bytes(w,transmute([]u8)text)}

// Reads records: a read past the end marks the reader short and gives zeros.
@(private)
Reader :: struct {
    data:[]u8,
    at:int,
    short:bool,
}

@(private)
read_bytes :: proc "contextless" (r:^Reader,count:int) -> []u8 {
    if r.short || count<0 || count>len(r.data)-r.at {
        r.short=true
        return nil
    }
    bytes:=r.data[r.at:][:count]
    r.at+=count
    return bytes
}

@(private)
read_value :: proc "contextless" (r:^Reader,$T:typeid) -> (value:T) {
    bytes:=read_bytes(r,size_of(T))
    if bytes!=nil {mem.copy_non_overlapping(&value,raw_data(bytes),size_of(T))}
    return
}

// A count of items of size bytes each that the bytes left can hold.
@(private)
count_fits :: proc "contextless" (r:^Reader,count:u64,size:int) -> bool {
    return !r.short && count<=u64(len(r.data)-r.at)/u64(max(size,1))
}

@(private)
zero :: proc "contextless" (bytes:[]u8) -> bool {
    for b in bytes {if b!=0 {return false}}
    return true
}

@(private)
hash_less :: proc(a,b:store.Hash) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}

@(private)
hex_text :: proc(bytes:[]u8,buffer:[]u8) -> string {
    DIGITS:=[16]u8{'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'}
    n:=min(len(bytes),len(buffer)/2)
    for k in 0..<n {
        buffer[2*k]=DIGITS[bytes[k]>>4]
        buffer[2*k+1]=DIGITS[bytes[k]&15]
    }
    return string(buffer[:2*n])
}

// The bytes of hex text into out, which it must fill exactly.
@(private)
hex_parse :: proc(text:string,out:[]u8) -> bool {
    if len(text)!=2*len(out) {return false}
    for &b,k in out {
        high,high_ok:=hex_value(text[2*k])
        low,low_ok:=hex_value(text[2*k+1])
        if !high_ok || !low_ok {return false}
        b=high<<4|low
    }
    return true
}

@(private)
id_less :: proc "contextless" (a,b:Workspace_Id) -> bool {
    for k in 0..<len(a) {
        if a[k]!=b[k] {return a[k]<b[k]}
    }
    return false
}
