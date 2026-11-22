package kai

import "core:slice"
import "core:unicode/utf8"
import "mirai:store"

// Signed device refs: each device writes only its own ref,
// kai-refs-<project hex>/<device hex, first 16 bytes>, naming a Device_Refs
// record it signed with a sequence number. A peer takes a newer record only
// when it is signed, its device may write the project, and its seq is higher
// than the one held: a peer or a seed cannot roll a device's bookmarks back.
// Display names come from the logs; store names stay in [a-z0-9._-].
//
// Signed derived data (DDC): what a writer or a holder of a ddc grant built,
// under kai-ddc-<org hex>/<key hex>, as a set of records. A record names its
// output by output_root, a DDC_Output object that lists every object the
// output consists of, the one the key's cache ref names first: Kai moves,
// mirrors and serves a result whole without reading what it is. Two records
// of one key with different outputs are both kept: the build is not
// deterministic.

REFS_PREFIX :: "kai-refs-"
DDC_PREFIX :: "kai-ddc-"
DEVICE_REFS_MAX :: 1024
DDC_RECORDS_MAX :: 64
DDC_OUTPUT_MAX :: 1<<16 // objects one output lists
DDC_VERSION :: 2        // of DDC records, sets and outputs
TAINTED_MAX :: 64

Device_Refs_Head :: struct #packed {
    magic:u32,
    version:u16,
    count:u16,
    project:Log_Id,
    device:Key,
    seq:u64,          // strictly higher in each record of the device
    prev:store.Hash,  // the record before, zero for the first
    time:i64,         // ns
} // + count × (Revision target, u8 length, bookmark), sorted by bookmark, then Signature

Bookmark_Ref :: struct {name:string,target:Revision}

Device_Refs :: struct {
    project:Log_Id,
    device:Key,
    seq:u64,
    prev:store.Hash,
    time:i64,
    refs:[]Bookmark_Ref,
    signature:Signature,
}

// The namespace of a project's device refs.
refs_namespace :: proc(project:Log_Id,buffer:^[len(REFS_PREFIX)+64]u8) -> string {
    copy(buffer[:],REFS_PREFIX)
    hex:[64]u8
    copy(buffer[len(REFS_PREFIX):],store.hex(project,&hex))
    return string(buffer[:])
}

// The name of a device's ref.
refs_name :: proc(device:Key,buffer:^[32]u8) -> string {
    d:=device
    return hex_text(d[:16],buffer[:])
}

device_refs_encode :: proc(r:^Device_Refs,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(r.refs)>DEVICE_REFS_MAX {return nil,.Too_Large}
    if identity.key!=r.device || r.project=={} || r.seq==0 {return nil,.Invalid_Argument}
    for ref,i in r.refs {
        if len(ref.name)==0 || len(ref.name)>BOOKMARK_NAME_MAX || !utf8.valid_string(ref.name) || ref.target=={} {return nil,.Invalid_Argument}
        if i>0 && r.refs[i-1].name>=ref.name {return nil,.Invalid_Argument}
    }
    w:=writer_make(allocator)
    write_value(&w,Device_Refs_Head{magic=KAI_MAGIC,version=VERSION,count=u16(len(r.refs)),project=r.project,device=r.device,seq=r.seq,prev=r.prev,time=r.time})
    for ref in r.refs {
        write_value(&w,ref.target)
        write_value(&w,u8(len(ref.name)))
        write_string(&w,ref.name)
    }
    if w.failed {return nil,.Out_Of_Memory}
    r.signature=sign(identity,w.data[:])
    write_bytes(&w,r.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

// The record of bytes, checked; its names point into bytes.
device_refs_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (r:Device_Refs,error:Error) {
    reader:=Reader{data=bytes}
    head:=read_value(&reader,Device_Refs_Head)
    if reader.short || head.magic!=KAI_MAGIC || head.version!=VERSION || head.count>DEVICE_REFS_MAX || head.project=={} || head.seq==0 {return {},.Corrupt}
    r.project,r.device,r.seq,r.prev,r.time=head.project,head.device,head.seq,head.prev,head.time
    refs,e:=make([]Bookmark_Ref,head.count,allocator)
    if e!=nil {return {},.Out_Of_Memory}
    r.refs=refs
    for &ref,i in r.refs {
        ref.target=read_value(&reader,Revision)
        ref.name=tail_string(&reader)
        if reader.short || ref.target=={} || len(ref.name)==0 || !utf8.valid_string(ref.name) || (i>0 && r.refs[i-1].name>=ref.name) {
            delete(refs,allocator)
            return {},.Corrupt
        }
    }
    r.signature=read_value(&reader,Signature)
    if reader.short || reader.at!=len(bytes) {
        delete(refs,allocator)
        return {},.Corrupt
    }
    return r,.None
}

@(private)
signed_valid :: proc(bytes:[]u8,key:Key) -> bool {
    if len(bytes)<size_of(Signature) {return false}
    signature:Signature
    copy(signature[:],bytes[len(bytes)-size_of(Signature):])
    return signature_valid(key,bytes[:len(bytes)-size_of(Signature)],signature)
}

// The record a device's ref names, and its address; Missing when it has none.
device_refs_get :: proc(s:^store.Store,project:Log_Id,device:Key,allocator:=context.allocator) -> (r:Device_Refs,address:store.Hash,error:Error) {
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    a,e:=store.ref_get(s,refs_namespace(project,&ns),refs_name(device,&name))
    if e!=.None {return {},{},store_error(e)}
    bytes:=object_get(s,a,.Device_Refs,allocator) or_return
    r,error=device_refs_decode(bytes,allocator)
    if error!=.None {delete(bytes,allocator)}
    return r,a,error
}

// Signs and writes this device's refs of the project: the next seq after the
// one it holds.
device_refs_publish :: proc(s:^store.Store,project:Log_Id,identity:^Identity,refs:[]Bookmark_Ref,time:i64) -> (address:store.Hash,error:Error) {
    r:=Device_Refs{project=project,device=identity.key,seq=1,time=time}
    if old,old_address,e:=device_refs_get(s,project,identity.key,context.temp_allocator);e==.None {
        r.seq,r.prev=old.seq+1,old_address
    } else if e!=.Missing {
        return {},e
    }
    sorted,clone_error:=slice.clone(refs,context.temp_allocator)
    if clone_error!=nil {return {},.Out_Of_Memory}
    slice.sort_by(sorted,proc(a,b:Bookmark_Ref) -> bool {return a.name<b.name})
    r.refs=sorted
    bytes:=device_refs_encode(&r,identity,context.temp_allocator) or_return
    address=object_put(s,.Device_Refs,bytes) or_return
    ns:[len(REFS_PREFIX)+64]u8
    name:[32]u8
    if e:=store.ref_set(s,refs_namespace(project,&ns),refs_name(identity.key,&name),address);e!=.None {return {},store_error(e)}
    return address,.None
}

// Whether device may write the project at time: a device of a writer of the
// org, or the signing key of a grant of the write right; scope is that
// grant's path scope, empty for a writer.
device_may_write :: proc(org:^Org_Fold,project:Log_Id,device:Key,time:i64) -> (scope:string,ok:bool) {
    if org_project_index(org,project)<0 {return}
    if _,role:=org_device_role(org,device);role>=.Writer {return "",true}
    g,granted:=org_grant_right(org,device,.Write,project,time)
    return g.path,granted
}

// Takes the Device_Refs record a peer gave at address, already in the store,
// for the ref name it came under: signed, by a device that may write the
// project now, under its own name, and newer than the one held. A grant
// holder's record is taken only when the changes it signed under the
// record's targets change only what its path scope covers; Missing, with what
// to fetch appended to missing, while they are not all in the store. The ref
// then names it; changed is false when it was the one held.
device_refs_accept :: proc(s:^store.Store,org:^Org_Fold,project:Log_Id,name:string,address:store.Hash,now:i64,missing:^[dynamic]store.Hash=nil) -> (changed:bool,error:Error) {
    bytes:=object_get(s,address,.Device_Refs,context.temp_allocator) or_return
    r:=device_refs_decode(bytes,context.temp_allocator) or_return
    own:[32]u8
    if r.project!=project || refs_name(r.device,&own)!=name {return false,.Invalid_Argument}
    scope,writer:=device_may_write(org,project,r.device,now)
    if !signed_valid(bytes,r.device) || !writer {return false,.Unauthorized}
    ns:[len(REFS_PREFIX)+64]u8
    namespace:=refs_namespace(project,&ns)
    known:[]Bookmark_Ref
    if held,e:=store.ref_get(s,namespace,name);e==.None {
        if held==address {return false,.None}
        old,_,old_error:=device_refs_get(s,project,r.device,context.temp_allocator)
        if old_error==.None && r.seq<=old.seq {return false,.Rollback}
        known=old.refs
    } else if e!=.Missing {
        return false,store_error(e)
    }
    if scope!="" {
        targets:=make([dynamic]Revision,context.temp_allocator)
        stops:=make([dynamic]Revision,context.temp_allocator)
        for b in r.refs {append(&targets,b.target)}
        for b in known {append(&stops,b.target)}
        grant_writes_within(s,scope,r.device,targets[:],stops[:],missing) or_return
    }
    if e:=store.ref_set(s,namespace,name,address);e!=.None {return false,store_error(e)}
    return true,.None
}

// Whether the changes author signed under targets, down to known ones,
// change only paths scope covers (grant_covers). A path counts as changed by
// a change when it differs from every parent, so a merge does not answer for
// what its parents brought. Unauthorized for one that changes another path;
// Missing, with the changes and folders to fetch appended to missing, while
// not all are in the store.
grant_writes_within :: proc(s:^store.Store,scope:string,author:Key,targets,known:[]Revision,missing:^[dynamic]store.Hash) -> Error {
    stack:=make([dynamic]Revision,context.temp_allocator)
    seen:=make(map[Revision]bool,context.temp_allocator)
    for k in known {seen[k]=true}
    append(&stack,..targets)
    lacking:=make([dynamic]store.Hash,context.temp_allocator)
    diffs:=make([dynamic]Diff,context.temp_allocator)
    outside:=make(map[string]int,context.temp_allocator)
    for len(stack)>0 {
        r:=pop(&stack)
        if r=={} || seen[r] {continue}
        seen[r]=true
        bytes,e:=object_get(s,r,.Change,context.temp_allocator)
        if e==.Missing {
            append(&lacking,r)
            continue
        }
        // Who signed it decides who answers for it: a forged author does not pass.
        if e!=.None || !change_verify(bytes) {return .Unauthorized}
        c,ce:=change_decode(bytes,context.temp_allocator)
        if ce!=.None {return .Unauthorized}
        if c.author!=author {continue}
        clear(&outside)
        parents:=len(c.parents)
        before:=len(lacking)
        for p in c.parents {
            append(&stack,p)
            pc,pe:=change_get(s,p,context.temp_allocator)
            if pe==.Missing {
                append(&lacking,p)
                continue
            }
            if pe!=.None {return .Unauthorized}
            clear(&diffs)
            tree_diff(s,pc.tree,c.tree,&diffs,context.temp_allocator,&lacking) or_return
            for d in diffs {
                if !grant_covers(scope,d.path) {outside[d.path]+=1}
            }
        }
        if parents==0 {
            parents=1
            clear(&diffs)
            tree_diff(s,{},c.tree,&diffs,context.temp_allocator,&lacking) or_return
            for d in diffs {
                if !grant_covers(scope,d.path) {outside[d.path]+=1}
            }
        }
        if len(lacking)>before {continue}
        for _,n in outside {
            if n==parents {return .Unauthorized}
        }
    }
    if len(lacking)>0 {
        if missing!=nil {append(missing,..lacking[:])}
        return .Missing
    }
    return .None
}

// --- DDC ---

DDC_Record_Head :: struct #packed {
    magic:u32,
    version:u16,
    tainted:u8,
    reserved:u8,
    org:Log_Id,
    key:store.Hash,         // what the build was asked: its inputs and recipe
    output_root:store.Hash, // the DDC_Output of what it produced
    producer:Key,
    time:i64,
} // + [tainted]Scope_Id (private scopes it read), Signature

DDC_Record :: struct {
    using head:DDC_Record_Head,
    tainted_scopes:[]Scope_Id,
    signature:Signature,
}

DDC_Set_Head :: struct #packed {
    magic:u32,
    version:u16,
    count:u16,
} // + count × (u16 length, record), sorted by output_root, one per output_root

DDC_Output_Head :: struct #packed {
    magic:u32,
    version:u16,
    reserved:u16,
    count:u32,
} // + [count]store.Hash: the result, then the others sorted, each once

ddc_namespace :: proc(org:Log_Id,buffer:^[len(DDC_PREFIX)+64]u8) -> string {
    copy(buffer[:],DDC_PREFIX)
    hex:[64]u8
    copy(buffer[len(DDC_PREFIX):],store.hex(org,&hex))
    return string(buffer[:])
}

ddc_record_encode :: proc(d:^DDC_Record,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if len(d.tainted_scopes)>TAINTED_MAX {return nil,.Too_Large}
    if identity.key!=d.producer || d.org=={} || d.key=={} || d.output_root=={} {return nil,.Invalid_Argument}
    head:=d.head
    head.magic,head.version,head.tainted,head.reserved=KAI_MAGIC,DDC_VERSION,u8(len(d.tainted_scopes)),0
    w:=writer_make(allocator)
    write_value(&w,head)
    for t in d.tainted_scopes {write_value(&w,t)}
    if w.failed {return nil,.Out_Of_Memory}
    d.signature=sign(identity,w.data[:])
    write_bytes(&w,d.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

ddc_record_decode :: proc(bytes:[]u8) -> (d:DDC_Record,error:Error) {
    r:=Reader{data=bytes}
    d.head=read_value(&r,DDC_Record_Head)
    if r.short || d.magic!=KAI_MAGIC || d.version!=DDC_VERSION || d.reserved!=0 || d.tainted>TAINTED_MAX || d.org=={} || d.key=={} || d.output_root=={} {return {},.Corrupt}
    d.tainted_scopes=slice.reinterpret([]Scope_Id,read_bytes(&r,int(d.tainted)*size_of(Scope_Id)))
    d.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) {return {},.Corrupt}
    return d,.None
}

// Whether producer may publish derived data for the org: a device of a
// writer, a node in DDC mode, or the signing key of a grant with the ddc
// right that holds now.
ddc_producer_allowed :: proc(org:^Org_Fold,producer:Key,grants:[][]u8,now:i64) -> bool {
    if _,role:=org_device_role(org,producer);role>=.Writer {return true}
    if k:=org_node(org,producer);k>=0 && .DDC in org.nodes[k].modes {return true}
    for bytes in grants {
        g,e:=grant_verify(org,bytes,now)
        if e==.None && .DDC in g.rights && g.subject_key==producer {return true}
    }
    return false
}

// The records of the set at address, each one's bytes.
@(private)
ddc_set_read :: proc(s:^store.Store,address:store.Hash,out:^[dynamic][]u8) -> Error {
    bytes:=object_get(s,address,.DDC_Set,context.temp_allocator) or_return
    r:=Reader{data=bytes}
    head:=read_value(&r,DDC_Set_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=DDC_VERSION || head.count==0 || head.count>DDC_RECORDS_MAX {return .Corrupt}
    for _ in 0..<head.count {
        size:=read_value(&r,u16)
        record:=read_bytes(&r,int(size))
        if r.short {return .Corrupt}
        if _,e:=append(out,record);e!=nil {return .Out_Of_Memory}
    }
    if r.at!=len(bytes) {return .Corrupt}
    return .None
}

@(private)
ddc_set_write :: proc(s:^store.Store,org:Log_Id,key:store.Hash,records:[][]u8) -> (address:store.Hash,error:Error) {
    w:=writer_make(context.temp_allocator)
    write_value(&w,DDC_Set_Head{magic=KAI_MAGIC,version=DDC_VERSION,count=u16(len(records))})
    for r in records {
        write_value(&w,u16(len(r)))
        write_bytes(&w,r)
    }
    if w.failed {return {},.Out_Of_Memory}
    address=object_put(s,.DDC_Set,w.data[:]) or_return
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    if e:=store.ref_set(s,ddc_namespace(org,&ns),store.hex(key,&name),address);e!=.None {return {},store_error(e)}
    return address,.None
}

// Adds a record to the set of its key, one per output, sorted: nondeterministic
// when the set then holds more than one output.
@(private)
ddc_set_add :: proc(set:^[dynamic][]u8,record:[]u8) -> (added:bool,error:Error) {
    d:=ddc_record_decode(record) or_return
    for r in set {
        other,_:=ddc_record_decode(r)
        if other.output_root==d.output_root {return false,.None}
    }
    if len(set)>=DDC_RECORDS_MAX {return false,.Too_Large}
    if _,e:=append(set,record);e!=nil {return false,.Out_Of_Memory}
    slice.sort_by(set[:],proc(a,b:[]u8) -> bool {
        x,_:=ddc_record_decode(a)
        y,_:=ddc_record_decode(b)
        return hash_less(x.output_root,y.output_root)
    })
    return true,.None
}

// Signs and adds this end's record of what key produced: objects, the one
// the key's cache ref names first, then every other one it consists of.
ddc_publish :: proc(s:^store.Store,org:Log_Id,identity:^Identity,key:store.Hash,objects:[]store.Hash,tainted:[]Scope_Id,time:i64) -> (nondeterministic:bool,error:Error) {
    output_root:=ddc_output_put(s,objects) or_return
    d:=DDC_Record{head={org=org,key=key,output_root=output_root,producer=identity.key,time=time},tainted_scopes=tainted}
    record:=ddc_record_encode(&d,identity,context.temp_allocator) or_return
    set:=make([dynamic][]u8,context.temp_allocator)
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    if held,e:=store.ref_get(s,ddc_namespace(org,&ns),store.hex(key,&name));e==.None {
        ddc_set_read(s,held,&set) or_return
    }
    added:=ddc_set_add(&set,record) or_return
    if added {ddc_set_write(s,org,key,set[:]) or_return}
    return len(set)>1,.None
}

// Merges the set a peer gave at address into the one held for key: each of
// its records signed by an allowed producer for this org and key. Records of
// a producer that is not allowed are skipped.
ddc_accept :: proc(s:^store.Store,org:^Org_Fold,key:store.Hash,address:store.Hash,grants:[][]u8,now:i64) -> (changed,nondeterministic:bool,error:Error) {
    incoming:=make([dynamic][]u8,context.temp_allocator)
    ddc_set_read(s,address,&incoming) or_return
    set:=make([dynamic][]u8,context.temp_allocator)
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    namespace:=ddc_namespace(org.log.id,&ns)
    if held,e:=store.ref_get(s,namespace,store.hex(key,&name));e==.None {
        ddc_set_read(s,held,&set) or_return
    } else if e!=.Missing {
        return false,false,store_error(e)
    }
    for record in incoming {
        d,e:=ddc_record_decode(record)
        if e!=.None || d.org!=org.log.id || d.key!=key || !signed_valid(record,d.producer) || !ddc_producer_allowed(org,d.producer,grants,now) {continue}
        added:=ddc_set_add(&set,record) or_return
        changed|=added
    }
    if changed {ddc_set_write(s,org.log.id,key,set[:]) or_return}
    return changed,len(set)>1,.None
}

// The records of key, sorted by output: more than one is nondeterminism. The
// records' tainted scopes live in the temp allocator.
ddc_lookup :: proc(s:^store.Store,org:Log_Id,key:store.Hash,out:^[dynamic]DDC_Record) -> Error {
    clear(out)
    ns:[len(DDC_PREFIX)+64]u8
    name:[64]u8
    held,e:=store.ref_get(s,ddc_namespace(org,&ns),store.hex(key,&name))
    if e!=.None {return store_error(e)}
    set:=make([dynamic][]u8,context.temp_allocator)
    ddc_set_read(s,held,&set) or_return
    for record in set {
        d:=ddc_record_decode(record) or_return
        if _,append_error:=append(out,d);append_error!=nil {return .Out_Of_Memory}
    }
    return .None
}

// Puts the DDC_Output of objects: the first as given, the others sorted, each
// once. Its address is a record's output_root.
ddc_output_put :: proc(s:^store.Store,objects:[]store.Hash) -> (address:store.Hash,error:Error) {
    if len(objects)==0 || objects[0]=={} {return {},.Invalid_Argument}
    if len(objects)>DDC_OUTPUT_MAX {return {},.Too_Large}
    rest:=make([dynamic]store.Hash,0,len(objects),context.temp_allocator)
    for o in objects[1:] {
        if o=={} {return {},.Invalid_Argument}
        if o!=objects[0] {append(&rest,o)}
    }
    slice.sort_by(rest[:],hash_less)
    w:=writer_make(context.temp_allocator)
    write_value(&w,DDC_Output_Head{magic=KAI_MAGIC,version=DDC_VERSION})
    write_value(&w,objects[0])
    count:=1
    for o,i in rest {
        if i>0 && rest[i-1]==o {continue}
        write_value(&w,o)
        count+=1
    }
    if w.failed {return {},.Out_Of_Memory}
    (^DDC_Output_Head)(raw_data(w.data))^.count=u32(count)
    return object_put(s,.DDC_Output,w.data[:])
}

// The objects of the DDC_Output at address, the result first, in allocator:
// Corrupt unless the others are sorted and each is there once.
ddc_output_get :: proc(s:^store.Store,address:store.Hash,allocator:=context.allocator) -> (objects:[]store.Hash,error:Error) {
    bytes:=object_get(s,address,.DDC_Output,context.temp_allocator) or_return
    return ddc_output_decode(bytes,allocator)
}

ddc_output_decode :: proc(bytes:[]u8,allocator:=context.allocator) -> (objects:[]store.Hash,error:Error) {
    r:=Reader{data=bytes}
    head:=read_value(&r,DDC_Output_Head)
    if r.short || head.magic!=KAI_MAGIC || head.version!=DDC_VERSION || head.reserved!=0 || head.count==0 || head.count>DDC_OUTPUT_MAX {return nil,.Corrupt}
    if len(bytes)-r.at!=int(head.count)*size_of(store.Hash) {return nil,.Corrupt}
    listed:=slice.reinterpret([]store.Hash,bytes[r.at:])
    for o,i in listed {
        if o=={} || (i>0 && o==listed[0]) || (i>1 && !hash_less(listed[i-1],o)) {return nil,.Corrupt}
    }
    made,e:=slice.clone(listed,allocator)
    if e!=nil {return nil,.Out_Of_Memory}
    return made,.None
}

// The objects of output_root that are not whole here, into lacking: the
// output itself while it is not here. Whole once lacking stays empty.
ddc_output_lacking :: proc(s:^store.Store,output_root:store.Hash,lacking:^[dynamic]store.Hash) -> (objects:[]store.Hash,error:Error) {
    if !object_whole(s,output_root) {
        append(lacking,output_root)
        return nil,.None
    }
    objects=ddc_output_get(s,output_root,context.temp_allocator) or_return
    for o in objects {
        if !object_whole(s,o) {append(lacking,o)}
    }
    return objects,.None
}
