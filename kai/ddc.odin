package kai

import "core:slice"
import "mirai:store"

// Signed derived data (DDC): what a writer of an org built, under
// kai-ddc-<org hex>/<key hex>, as a set of records. A record names its
// output by output_root, a DDC_Output object that lists every object the
// output consists of, the one the key's cache ref names first: Kai moves,
// mirrors and serves a result whole without reading what it is. Two records
// of one key with different outputs are both kept: the build is not
// deterministic.

DDC_PREFIX :: "kai-ddc-"
DDC_RECORDS_MAX :: 64
DDC_OUTPUT_MAX :: 1<<16 // objects one output lists


DDC_Record_Head :: struct #packed {
    magic:u32,
    org:Org_Id,
    key:store.Hash,         // what the build was asked: its inputs and recipe
    output_root:store.Hash, // the DDC_Output of what it produced
    producer:Key,
    time:i64,
} // + Signature

DDC_Record :: struct {
    using head:DDC_Record_Head,
    signature:Signature,
}

DDC_Set_Head :: struct #packed {
    magic:u32,
    count:u16,
} // + count × (u16 length, record), sorted by output_root, one per output_root

DDC_Output_Head :: struct #packed {
    magic:u32,
    reserved:u16,
    count:u32,
} // + [count]store.Hash: the result, then the others sorted, each once

ddc_namespace :: proc(org:Org_Id,buffer:^[len(DDC_PREFIX)+32]u8) -> string {
    copy(buffer[:],DDC_PREFIX)
    o:=org
    hex_text(o[:],buffer[len(DDC_PREFIX):])
    return string(buffer[:])
}

ddc_record_encode :: proc(d:^DDC_Record,identity:^Identity,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if identity.key!=d.producer || d.org=={} || d.key=={} || d.output_root=={} {return nil,.Invalid_Argument}
    head:=d.head
    head.magic=KAI_MAGIC
    w:=writer_make(allocator)
    write_value(&w,head)
    if w.failed {return nil,.Out_Of_Memory}
    d.signature=sign(identity,w.data[:])
    write_bytes(&w,d.signature[:])
    if w.failed {return nil,.Out_Of_Memory}
    return w.data[:],.None
}

ddc_record_decode :: proc(bytes:[]u8) -> (d:DDC_Record,error:Error) {
    r:=Reader{data=bytes}
    d.head=read_value(&r,DDC_Record_Head)
    if r.short || d.magic!=KAI_MAGIC || d.org=={} || d.key=={} || d.output_root=={} {return {},.Corrupt}
    d.signature=read_value(&r,Signature)
    if r.short || r.at!=len(bytes) {return {},.Corrupt}
    return d,.None
}

// Whether producer may publish derived data for the org: a writer of it.
ddc_producer_allowed :: proc(org:^Org,producer:Key) -> bool {
    role,ok:=org_role(org,producer)
    return ok && role>=.Writer
}

// The records of the set at address, each one's bytes.
@(private)
ddc_set_read :: proc(s:^store.Store,address:store.Hash,out:^[dynamic][]u8) -> Error {
    bytes:=object_get(s,address,.DDC_Set,context.temp_allocator) or_return
    r:=Reader{data=bytes}
    head:=read_value(&r,DDC_Set_Head)
    if r.short || head.magic!=KAI_MAGIC || head.count==0 || head.count>DDC_RECORDS_MAX {return .Corrupt}
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
ddc_set_write :: proc(s:^store.Store,org:Org_Id,key:store.Hash,records:[][]u8) -> (address:store.Hash,error:Error) {
    w:=writer_make(context.temp_allocator)
    write_value(&w,DDC_Set_Head{magic=KAI_MAGIC,count=u16(len(records))})
    for r in records {
        write_value(&w,u16(len(r)))
        write_bytes(&w,r)
    }
    if w.failed {return {},.Out_Of_Memory}
    address=object_put(s,.DDC_Set,w.data[:]) or_return
    ns:[len(DDC_PREFIX)+32]u8
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
ddc_publish :: proc(s:^store.Store,org:Org_Id,identity:^Identity,key:store.Hash,objects:[]store.Hash,time:i64) -> (nondeterministic:bool,error:Error) {
    output_root:=ddc_output_put(s,objects) or_return
    d:=DDC_Record{head={org=org,key=key,output_root=output_root,producer=identity.key,time=time}}
    record:=ddc_record_encode(&d,identity,context.temp_allocator) or_return
    set:=make([dynamic][]u8,context.temp_allocator)
    ns:[len(DDC_PREFIX)+32]u8
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
ddc_accept :: proc(s:^store.Store,org:^Org,key:store.Hash,address:store.Hash) -> (changed,nondeterministic:bool,error:Error) {
    incoming:=make([dynamic][]u8,context.temp_allocator)
    ddc_set_read(s,address,&incoming) or_return
    set:=make([dynamic][]u8,context.temp_allocator)
    ns:[len(DDC_PREFIX)+32]u8
    name:[64]u8
    namespace:=ddc_namespace(org.id,&ns)
    if held,e:=store.ref_get(s,namespace,store.hex(key,&name));e==.None {
        ddc_set_read(s,held,&set) or_return
    } else if e!=.Missing {
        return false,false,store_error(e)
    }
    for record in incoming {
        d,e:=ddc_record_decode(record)
        if e!=.None || d.org!=org.id || d.key!=key || !signed_valid(record,d.producer) || !ddc_producer_allowed(org,d.producer) {continue}
        added:=ddc_set_add(&set,record) or_return
        changed|=added
    }
    if changed {ddc_set_write(s,org.id,key,set[:]) or_return}
    return changed,len(set)>1,.None
}

// The records of key, sorted by output: more than one is nondeterminism.
ddc_lookup :: proc(s:^store.Store,org:Org_Id,key:store.Hash,out:^[dynamic]DDC_Record) -> Error {
    clear(out)
    ns:[len(DDC_PREFIX)+32]u8
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
    write_value(&w,DDC_Output_Head{magic=KAI_MAGIC})
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
    if r.short || head.magic!=KAI_MAGIC || head.reserved!=0 || head.count==0 || head.count>DDC_OUTPUT_MAX {return nil,.Corrupt}
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
    scratch:=scratch_make()
    if !object_whole(s,output_root,scratch) {
        append(lacking,output_root)
        return nil,.None
    }
    objects=ddc_output_get(s,output_root,context.temp_allocator) or_return
    for o in objects {
        if !object_whole(s,o,scratch) {append(lacking,o)}
    }
    return objects,.None
}

// Whether bytes end in a signature by key of what comes before it.
@(private)
signed_valid :: proc(bytes:[]u8,key:Key) -> bool {
    if len(bytes)<size_of(Signature) {return false}
    signature:Signature
    copy(signature[:],bytes[len(bytes)-size_of(Signature):])
    return signature_valid(key,bytes[:len(bytes)-size_of(Signature)],signature)
}
