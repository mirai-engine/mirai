package kai

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "mirai:store"

// A change: one revision of a tree with its parents, who wrote it and why.
// Its Change_Id stays across rewrites and its address is its revision. The
// signature covers every byte before it; it is checked when a change comes
// from a peer (change_verify), never on a local read. Predecessors are not
// recorded here but in the operation that rewrote it.

Change_Head :: struct #packed {
    magic:u32,
    version:u16,
    reserved:u16,
    id:Change_Id,
    tree:store.Hash, // the root folder
    author:Key,      // the device or user that signs
    created:i64,     // ns, kept across rewrites
    written:i64,     // ns, this revision
    parents:u8,
    coauthors:u8,
    attachments:u8,
    reserved2:u8,
    description:u32, // UTF-8 bytes
} // + [parents]Revision, [coauthors]Key, [attachments]Attachment ascending, description, Signature

Change :: struct {
    id:Change_Id,
    tree:store.Hash,
    author:Key,
    created,written:i64,
    parents:[]Revision, // the first is the one a diff compares with
    coauthors:[]Key,
    attachments:[]Attachment, // ascending by type, then object
    description:string,
    signature:Signature,
}

// The bytes of c, signed by identity, which must be its author.
change_encode :: proc(c:^Change,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(c.parents)>PARENTS_MAX || len(c.coauthors)>COAUTHORS_MAX || len(c.attachments)>ATTACHMENTS_MAX || len(c.description)>DESCRIPTION_MAX {return nil,.Too_Large}
    if !utf8.valid_string(c.description) || identity.key!=c.author || c.tree=={} {return nil,.Invalid_Argument}
    for p,i in c.parents {
        if p=={} {return nil,.Invalid_Argument}
        for q in c.parents[:i] {if p==q {return nil,.Invalid_Argument}}
    }
    if !attachments_valid(c.attachments) {return nil,.Invalid_Argument}
    w:=writer_make(allocator)
    write_value(&w,Change_Head{
        magic=KAI_MAGIC,version=CHANGE_VERSION,id=c.id,tree=c.tree,author=c.author,created=c.created,written=c.written,
        parents=u8(len(c.parents)),coauthors=u8(len(c.coauthors)),attachments=u8(len(c.attachments)),description=u32(len(c.description)),
    })
    for p in c.parents {
        q:=p
        write_bytes(&w,q[:])
    }
    for k in c.coauthors {
        q:=k
        write_bytes(&w,q[:])
    }
    for a in c.attachments {write_value(&w,a)}
    write_string(&w,c.description)
    if w.failed {return nil,.Out_Of_Memory}
    c.signature=sign(identity,w.data[:])
    write_bytes(&w,c.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The change of bytes, checked; its slices point into bytes.
change_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (c:Change,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,Change_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=CHANGE_VERSION || head.reserved!=0 || head.reserved2!=0 {return {},.Corrupt}
    if head.tree=={} || head.coauthors>COAUTHORS_MAX || head.attachments>ATTACHMENTS_MAX || head.description>DESCRIPTION_MAX {return {},.Corrupt}
    size:=size_of(Change_Head)+int(head.parents)*size_of(Revision)+int(head.coauthors)*size_of(Key)+int(head.attachments)*size_of(Attachment)+int(head.description)+size_of(Signature)
    if len(bytes)!=size {return {},.Corrupt}
    c.id,c.tree,c.author,c.created,c.written=head.id,head.tree,head.author,head.created,head.written
    e1,e2,e3:runtime.Allocator_Error
    c.parents,e1=make([]Revision,head.parents,allocator)
    c.coauthors,e2=make([]Key,head.coauthors,allocator)
    c.attachments,e3=make([]Attachment,head.attachments,allocator)
    defer if error!=.None {
        delete(c.parents,allocator)
        delete(c.coauthors,allocator)
        delete(c.attachments,allocator)
    }
    if e1!=nil || e2!=nil || e3!=nil {return c,.Out_Of_Memory}
    for &p,i in c.parents {
        p=read_value(&r,Revision)
        if p=={} {return c,.Corrupt}
        for q in c.parents[:i] {if p==q {return c,.Corrupt}}
    }
    for &k in c.coauthors {k=read_value(&r,Key)}
    for &a in c.attachments {a=read_value(&r,Attachment)}
    if !attachments_valid(c.attachments) {return c,.Corrupt}
    c.description=string(read_bytes(&r,int(head.description)))
    c.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) || !utf8.valid_string(c.description) {return c,.Corrupt}
    return c,.None
}

// Whether a change's attachments are well formed: each of a type and an
// object, strictly ascending by type then object, so one list has one form.
attachments_valid :: proc(list:[]Attachment) -> bool {
    for a,i in list {
        if a.type==0 || a.object=={} {return false}
        if i>0 {
            b:=list[i-1]
            if b.type>a.type || (b.type==a.type && !hash_less(b.object,a.object)) {return false}
        }
    }
    return true
}

// An attachment's type as views show it, in the temp allocator: its four
// letters when they are printable ASCII (low byte first), else its hex.
attachment_type_text :: proc(type:u32) -> string {
    letters:=transmute([4]u8)type
    for c in letters {
        if c<0x21 || c>0x7e {return fmt.tprintf("%08x",type)}
    }
    return strings.clone(string(letters[:]),context.temp_allocator)
}

// Adds a to list, kept ascending: false when it is there already or list is full.
attachment_add :: proc(list:^[dynamic]Attachment,a:Attachment) -> (added:bool,error:Error) {
    if a.type==0 || a.object=={} {return false,.Invalid_Argument}
    at:=len(list)
    for b,i in list {
        if b==a {return false,.None}
        if b.type>a.type || (b.type==a.type && hash_less(a.object,b.object)) {
            at=i
            break
        }
    }
    if len(list)>=ATTACHMENTS_MAX {return false,.Too_Large}
    if _,e:=inject_at(list,at,a);e!=nil {return false,.Out_Of_Memory}
    return true,.None
}

// Whether the signature of the bytes of a change is its author's.
change_verify :: proc(bytes:[]u8) -> bool {
    if len(bytes)<size_of(Change_Head)+size_of(Signature) {return false}
    head:=(^Change_Head)(raw_data(bytes))^
    signature:Signature
    mem.copy_non_overlapping(&signature,&bytes[len(bytes)-size_of(Signature)],size_of(Signature))
    return signature_valid(head.author,bytes[:len(bytes)-size_of(Signature)],signature)
}

// Puts c signed by identity, uncommitted: its revision.
change_put :: proc(s:^store.Store,c:^Change,identity:^Identity) -> (revision:Revision,error:Error) {
    bytes:=change_encode(c,identity,context.temp_allocator) or_return
    return object_put(s,.Change,bytes)
}

// The change at revision, its slices in allocator.
change_get :: proc(s:^store.Store,revision:Revision,allocator:=context.allocator) -> (c:Change,error:Error) {
    bytes:=object_get(s,revision,.Change,allocator) or_return
    return change_decode(bytes,allocator)
}
