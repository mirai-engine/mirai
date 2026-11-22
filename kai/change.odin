package kai

import "base:runtime"
import "core:mem"
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
    turns:u8,
    reserved2:u8,
    description:u32, // UTF-8 bytes
} // + [parents]Revision, [coauthors]Key, [turns]Turn_Ref, description, Signature

Change :: struct {
    id:Change_Id,
    tree:store.Hash,
    author:Key,
    created,written:i64,
    parents:[]Revision, // the first is the one a diff compares with
    coauthors:[]Key,
    turns:[]Turn_Ref,
    description:string,
    signature:Signature,
}

// The bytes of c, signed by identity, which must be its author.
change_encode :: proc(c:^Change,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(c.parents)>PARENTS_MAX || len(c.coauthors)>COAUTHORS_MAX || len(c.turns)>TURNS_MAX || len(c.description)>DESCRIPTION_MAX {return nil,.Too_Large}
    if !utf8.valid_string(c.description) || identity.key!=c.author || c.tree=={} {return nil,.Invalid_Argument}
    for p,i in c.parents {
        if p=={} {return nil,.Invalid_Argument}
        for q in c.parents[:i] {if p==q {return nil,.Invalid_Argument}}
    }
    w:=writer_make(allocator)
    write_value(&w,Change_Head{
        magic=KAI_MAGIC,version=VERSION,id=c.id,tree=c.tree,author=c.author,created=c.created,written=c.written,
        parents=u8(len(c.parents)),coauthors=u8(len(c.coauthors)),turns=u8(len(c.turns)),description=u32(len(c.description)),
    })
    for p in c.parents {
        q:=p
        write_bytes(&w,q[:])
    }
    for k in c.coauthors {
        q:=k
        write_bytes(&w,q[:])
    }
    for turn in c.turns {write_value(&w,turn)}
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
    if r.short || head.magic!=KAI_MAGIC || head.version!=VERSION || head.reserved!=0 || head.reserved2!=0 {return {},.Corrupt}
    if head.tree=={} || head.coauthors>COAUTHORS_MAX || head.turns>TURNS_MAX || head.description>DESCRIPTION_MAX {return {},.Corrupt}
    size:=size_of(Change_Head)+int(head.parents)*size_of(Revision)+int(head.coauthors)*size_of(Key)+int(head.turns)*size_of(Turn_Ref)+int(head.description)+size_of(Signature)
    if len(bytes)!=size {return {},.Corrupt}
    c.id,c.tree,c.author,c.created,c.written=head.id,head.tree,head.author,head.created,head.written
    e1,e2,e3:runtime.Allocator_Error
    c.parents,e1=make([]Revision,head.parents,allocator)
    c.coauthors,e2=make([]Key,head.coauthors,allocator)
    c.turns,e3=make([]Turn_Ref,head.turns,allocator)
    defer if error!=.None {
        delete(c.parents,allocator)
        delete(c.coauthors,allocator)
        delete(c.turns,allocator)
    }
    if e1!=nil || e2!=nil || e3!=nil {return c,.Out_Of_Memory}
    for &p,i in c.parents {
        p=read_value(&r,Revision)
        if p=={} {return c,.Corrupt}
        for q in c.parents[:i] {if p==q {return c,.Corrupt}}
    }
    for &k in c.coauthors {k=read_value(&r,Key)}
    for &turn in c.turns {turn=read_value(&r,Turn_Ref)}
    c.description=string(read_bytes(&r,int(head.description)))
    c.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) || !utf8.valid_string(c.description) {return c,.Corrupt}
    return c,.None
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
