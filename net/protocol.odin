package mirai_net

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// A protocol is what two ends must agree on to replicate: the fragments
// objects are made of, events and the input structure, each described from
// serial.Schema types. Both ends register the same ones in the same order and
// seal it; the hash of what they registered is what they compare when they
// connect.
//
// A fragment is a plain structure. Each replicated field of it becomes one or
// more leaves: a serializer chosen from the field's kind, flags, precision and
// bits. An object type is a list of fragments: the creation of an object
// carries its list, and each end composes the type of a list the first time
// it meets it (type_compose), from the leaves its fragments registered. The
// quantized state of an object is an array of 32-bit words, one or two per
// leaf, identical for every connection; what goes on the wire is written from
// those words. Fields and entries of struct arrays own change bits. Above 64,
// entries share bits within their fragment, never across different audiences.
//
// One half of a host composes types: on a server, the simulation half when it
// creates an object; on a client, the network half when it reads a creation.
// The other half reads a type only after the operation or the command that
// names it, so the types never move: the protocol makes room for
// TYPE_CAPACITY of them and their leaves when it is sealed.

Type_Id :: distinct u16
Fragment_Id :: distinct u16
Event_Id :: distinct u16
TYPE_NONE :: Type_Id(0xffff)
FRAGMENT_NONE :: Fragment_Id(0xffff)
EVENT_NONE :: Event_Id(0xffff)

MAX_FRAGMENTS :: 16 // of an object type
TYPE_CAPACITY :: 128
TYPE_LEAVES :: 1<<15 // of all the types composed after sealing
MAX_STATE_WORDS :: 1024
MAX_STATE_BYTES :: 880 // on the wire: a larger state goes in parts, each field of it within this
EVENT_MAX_BYTES :: 880

// A bit per fragment of an object type.
Fragment_Mask :: u16

// Which connections receive a fragment.
Fragment_Condition :: enum u8 {All,Owner,Not_Owner}
Fragment_Desc :: struct {schema:^serial.Schema,type:serial.Type_Index,condition:Fragment_Condition}

Event_Flag :: enum u8 {
    Reliable,
    From_Client, // clients may send it to the server
    Owner_Only,  // From_Client, and only about objects the sender owns
    Held,        // it reaches a held connection too (connection_hold); the rest does not
}
Event_Flags :: bit_set[Event_Flag;u8]

@(private)
Leaf_Kind :: enum u8 {
    Bool,
    Unsigned,   // low bits of an integer
    Signed,     // the same, sign extended when read
    Offset,     // integer with a range, sent as its distance to the minimum
    Float,      // raw IEEE bits
    Quantized,  // float as a signed count of steps, variable width
    Ranged,     // float with a range, as an unsigned count of steps from the minimum
    Enum,       // index of the value among the named values
    Bit_Set,
    Object,     // base.Entity sent as the network object the user id belongs to
    Quaternion, // smallest three
    Rotation,   // quaternion sent whole
    Text,
}
@(private)
Leaf :: struct {
    kind:Leaf_Kind,
    fragment:u8,
    bit:u8,      // of the change mask
    bits:u8,     // width when sent whole; Quaternion: per component; Text: of the length
    words:u16,   // in the quantized state
    word:u16,
    size:u16,    // bytes in the fragment
    unit:u16,    // the field of its fragment that owns its change bit
    source:u32,  // offset in the fragment
    choices:u32, // Enum: first value in Protocol.choices
    count:u32,   // Enum: values; Text: bytes
    low:f64,
    step:f64,
}
@(private)
Fragment_Info :: struct {size:u32,first_leaf,leaf_count:u32,condition:Fragment_Condition}

Object_Type :: struct {
    name:string,
    name_hash,hash:u64,
    key:u64,            // of its list of fragments
    kinds:[MAX_FRAGMENTS]Fragment_Id,
    fragments:[MAX_FRAGMENTS]Fragment_Info,
    fragment_count:int,
    first_leaf,leaf_count:int,
    leaves:[]Leaf,
    words:int,          // of quantized state
    bit_count:int,      // change bits in use
    index_bits:int,
    all,owner,others:u64, // change bits every connection, the owner and the rest receive
    bit_leaf,bit_leaves,bit_word,bit_words:[64]u16,
    fragment_bits:[MAX_FRAGMENTS]u64,
    reference_fragments:Fragment_Mask,
    max_bits:int,       // largest size on the wire
    bit_max_bits:[64]u32, // of the fields behind each change bit
    large:bool,         // max_bits exceeds MAX_STATE_BYTES: sent in parts of whole change bits
    owned:bool,         // its leaves are its own allocation: composed before sealing
}
@(private)
Event_Type :: struct {name_hash:u64,flags:Event_Flags,desc:Object_Type}

// A fragment as it was registered: its leaves, in Protocol.leaves, are those of
// the fragment alone, with words from its first and the field of each.
@(private)
Fragment_Record :: struct {
    hash:u64,
    first_leaf,leaf_count:int,
    units,words:int,
    size:u32,
    condition:Fragment_Condition,
}

Protocol :: struct {
    fragments:[dynamic]Fragment_Record,
    types:[]Object_Type, // TYPE_CAPACITY; type_count of them composed
    type_count:int,
    type_leaves:[]Leaf,  // of the types composed after sealing
    type_leaves_used:int,
    events:[dynamic]Event_Type,
    input:Object_Type,
    has_input:bool,
    leaves:[dynamic]Leaf,
    choices:[dynamic]i64,
    object_words:int,    // of the largest object its fragments make, at most MAX_STATE_WORDS
    smallest_words:int,  // of the smallest
    hash:u64,
    sealed:bool,
    allocator:runtime.Allocator,
}

// False without memory.
protocol_init :: proc(p:^Protocol,allocator:=context.allocator) -> bool {
    p^={allocator=allocator}
    error:runtime.Allocator_Error
    if p.types,error=make([]Object_Type,TYPE_CAPACITY,allocator);error!=nil {return false}
    p.fragments=make([dynamic]Fragment_Record,allocator)
    p.events=make([dynamic]Event_Type,allocator)
    p.leaves=make([dynamic]Leaf,allocator)
    p.choices=make([dynamic]i64,allocator)
    return true
}
protocol_destroy :: proc(p:^Protocol) {
    for &type in p.types[:p.type_count] {
        delete(type.name,p.allocator)
        if type.owned {delete(type.leaves,p.allocator)}
    }
    for event in p.events {delete(event.desc.name,p.allocator)}
    delete(p.input.name,p.allocator)
    delete(p.fragments);delete(p.types,p.allocator);delete(p.type_leaves,p.allocator)
    delete(p.events);delete(p.leaves);delete(p.choices)
    p^={}
}

// Registers a fragment objects can be made of. Fails when a field cannot be
// replicated, it replicates no field, its state exceeds MAX_STATE_WORDS or
// the largest encoding of the fields behind one change bit exceeds
// MAX_STATE_BYTES.
fragment_register :: proc(p:^Protocol,name:string,desc:Fragment_Desc) -> (Fragment_Id,bool) {
    if p.sealed || len(p.fragments)>=int(FRAGMENT_NONE) {return FRAGMENT_NONE,false}
    leaves,choices:=len(p.leaves),len(p.choices)
    alone,ok:=descriptor_build(p,name,{desc},MAX_STATE_BYTES,parts=true)
    if !ok {return FRAGMENT_NONE,false}
    delete(alone.name,p.allocator)
    record:=Fragment_Record{
        hash=alone.hash,first_leaf=alone.first_leaf,leaf_count=alone.leaf_count,
        units=fragment_units(desc),words=alone.words,size=alone.fragments[0].size,condition=desc.condition,
    }
    if _,error:=append(&p.fragments,record);error!=nil {
        base.truncate(&p.leaves,leaves);base.truncate(&p.choices,choices)
        return FRAGMENT_NONE,false
    }
    return Fragment_Id(len(p.fragments)-1),true
}

// Registers an object type of these fragments, before sealing: what
// type_compose gives the same list of fragments afterwards.
type_register :: proc(p:^Protocol,name:string,fragments:[]Fragment_Desc) -> (Type_Id,bool) {
    if p.sealed || len(fragments)==0 || len(fragments)>MAX_FRAGMENTS || p.type_count>=len(p.types) {return TYPE_NONE,false}
    kinds:[MAX_FRAGMENTS]Fragment_Id
    for fragment,i in fragments {
        registered:=false
        kinds[i],registered=fragment_register(p,name,fragment)
        if !registered {return TYPE_NONE,false}
    }
    leaves:=0
    for kind in kinds[:len(fragments)] {leaves+=p.fragments[kind].leaf_count}
    type:=&p.types[p.type_count]
    error:runtime.Allocator_Error
    if type.leaves,error=make([]Leaf,leaves,p.allocator);error!=nil {return TYPE_NONE,false}
    type.owned=true
    if !type_build(p,type,kinds[:len(fragments)]) {
        delete(type.leaves,p.allocator)
        type^={}
        return TYPE_NONE,false
    }
    type.name=strings.clone(name,p.allocator)
    type.name_hash=base.name_hash(name)
    p.type_count+=1
    return Type_Id(p.type_count-1),true
}

// The type of objects made of these fragments, in this order: the one
// composed before, or a new one. Fails before sealing, for a fragment the
// protocol does not have, a state that exceeds MAX_STATE_WORDS, or a protocol
// with TYPE_CAPACITY types or TYPE_LEAVES leaves composed.
type_compose :: proc(p:^Protocol,kinds:[]Fragment_Id) -> (Type_Id,bool) {
    if !p.sealed || len(kinds)==0 || len(kinds)>MAX_FRAGMENTS {return TYPE_NONE,false}
    key:=kinds_key(kinds)
    count:=intrinsics.atomic_load(&p.type_count)
    found: for &type,i in p.types[:count] {
        if type.key!=key || type.fragment_count!=len(kinds) {continue}
        for kind,k in kinds {if type.kinds[k]!=kind {continue found}}
        return Type_Id(i),true
    }
    if count>=len(p.types) {return TYPE_NONE,false}
    leaves:=0
    for kind in kinds {
        if int(kind)>=len(p.fragments) {return TYPE_NONE,false}
        leaves+=p.fragments[kind].leaf_count
    }
    if p.type_leaves_used+leaves>len(p.type_leaves) {return TYPE_NONE,false}
    type:=&p.types[count]
    type.leaves=p.type_leaves[p.type_leaves_used:][:leaves]
    if !type_build(p,type,kinds) {
        type^={}
        return TYPE_NONE,false
    }
    p.type_leaves_used+=leaves
    intrinsics.atomic_store(&p.type_count,count+1)
    return Type_Id(count),true
}

// How many types are composed: the ids below it are valid.
type_count :: #force_inline proc "contextless" (p:^Protocol) -> int {return intrinsics.atomic_load(&p.type_count)}

// The fragments of a type, in order.
type_kinds :: proc(p:^Protocol,type:Type_Id) -> []Fragment_Id {
    t:=&p.types[type]
    return t.kinds[:t.fragment_count]
}

// Registers an event: a structure sent to the replicas of an object, or to
// nobody in particular, once. The name identifies it in the protocol hash.
event_register :: proc(p:^Protocol,name:string,schema:^serial.Schema,type:serial.Type_Index,flags:Event_Flags={}) -> (Event_Id,bool) {
    if p.sealed || len(p.events)>=int(EVENT_NONE) {return EVENT_NONE,false}
    leaves,choices:=len(p.leaves),len(p.choices)
    desc,ok:=descriptor_build(p,name,{{schema=schema,type=type}},EVENT_MAX_BYTES)
    if !ok {return EVENT_NONE,false}
    if _,error:=append(&p.events,Event_Type{name_hash=desc.name_hash,flags=flags,desc=desc});error!=nil {
        delete(desc.name,p.allocator)
        base.truncate(&p.leaves,leaves);base.truncate(&p.choices,choices)
        return EVENT_NONE,false
    }
    return Event_Id(len(p.events)-1),true
}

// The structure a client sends every tick.
input_register :: proc(p:^Protocol,schema:^serial.Schema,type:serial.Type_Index) -> bool {
    if p.sealed || p.has_input {return false}
    desc,ok:=descriptor_build(p,"input",{{schema=schema,type=type}},INPUT_MAX_BYTES)
    if !ok {return false}
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    p.input=desc
    p.has_input=true
    return true
}

// Closes the protocol, makes room for the types to compose and returns the
// hash both ends compare when connecting: of its fragments, events and input.
// False without memory for that room: the protocol stays open.
protocol_seal :: proc(p:^Protocol) -> (hash:u64,ok:bool) {
    if p.sealed {return p.hash,true}
    hash=u64(len(p.fragments))<<32|u64(len(p.events))
    total,words,smallest:=0,0,MAX_STATE_WORDS
    for record in p.fragments {
        hash=base.hash_combine(hash,record.hash)
        total+=record.leaf_count
        words+=record.words
        smallest=min(smallest,record.words)
    }
    for &event in p.events {
        event.desc.leaves=p.leaves[event.desc.first_leaf:][:event.desc.leaf_count]
        hash=base.hash_combine(hash,base.hash_combine(event.desc.hash,u64(transmute(u8)event.flags)))
    }
    if p.has_input {
        p.input.leaves=p.leaves[p.input.first_leaf:][:p.input.leaf_count]
        hash=base.hash_combine(hash,p.input.hash)
    }
    error:runtime.Allocator_Error
    if p.type_leaves,error=make([]Leaf,min(total*TYPE_CAPACITY,TYPE_LEAVES),p.allocator);error!=nil {return 0,false}
    p.object_words=clamp(words,1,MAX_STATE_WORDS)
    p.smallest_words=max(smallest,1)
    p.hash,p.sealed=hash,true
    return hash,true
}

type_find :: proc(p:^Protocol,name:string) -> (Type_Id,bool) {
    hash:=base.name_hash(name)
    for type,i in p.types[:type_count(p)] {
        if type.name_hash==hash {return Type_Id(i),true}
    }
    return TYPE_NONE,false
}
// Change bits of the fields of one fragment of a type.
type_fragment_mask :: proc(p:^Protocol,type:Type_Id,fragment:int) -> u64 {
    return p.types[type].fragment_bits[fragment]
}

@(private)
kinds_key :: proc "contextless" (kinds:[]Fragment_Id) -> (key:u64) {
    key=u64(len(kinds))
    for kind in kinds {key=base.hash_combine(key,u64(kind)+1)}
    return
}

// The fields of a fragment that own change bits.
@(private)
fragment_units :: proc(desc:Fragment_Desc) -> int {
    root:=serial.schema_type(desc.schema,desc.type)
    if root.kind!=.Struct {return 1}
    units:=0
    for field in serial.schema_fields(desc.schema,desc.type) {
        if .Local not_in field.flags {units+=descriptor_units(desc.schema,field.type)}
    }
    return units
}

// Composes a type of registered fragments into type, whose leaves have room
// for theirs: the leaves of each fragment with its words and change bits in
// the type, as descriptor_build gives them.
@(private)
type_build :: proc(p:^Protocol,type:^Object_Type,kinds:[]Fragment_Id) -> bool {
    leaves:=type.leaves
    owned:=type.owned
    type^={leaves=leaves,owned=owned,key=kinds_key(kinds),fragment_count=len(kinds)}
    units:[MAX_FRAGMENTS]int
    fields:=0
    for kind,i in kinds {
        units[i]=p.fragments[kind].units
        fields+=units[i]
    }
    if fields==0 {return false}
    type.name_hash=type.key
    type.bit_count=min(fields,64)
    type.index_bits=serial.bit_count_for(u64(type.bit_count-1))
    words,bit_base,left,count:=0,0,fields,0
    for kind,index in kinds {
        record:=&p.fragments[kind]
        groups:=units[index]
        if fields>64 && groups>0 {
            reserve:=0
            for other in units[index+1:len(kinds)] {reserve+=int(other>0)}
            groups=min(groups,max(1,min(type.bit_count-bit_base-reserve,(type.bit_count-bit_base)*groups/left)))
        }
        info:=Fragment_Info{size=record.size,first_leaf=u32(count),condition=record.condition}
        for template in p.leaves[record.first_leaf:][:record.leaf_count] {
            leaf:=template
            leaf.fragment=u8(index)
            leaf.word=u16(words+int(template.word))
            leaf.bit=u8(bit_base+int(template.unit)*groups/units[index])
            leaves[count]=leaf
            count+=1
        }
        words+=record.words
        bit_base+=groups
        left-=units[index]
        info.leaf_count=u32(count)-info.first_leaf
        type.fragments[index]=info
        type.kinds[index]=kind
    }
    type.leaf_count=count
    type.words=words
    if words>MAX_STATE_WORDS {return false}
    return type_finish(p,type,leaves[:count],MAX_STATE_BYTES,parts=true)
}

@(private)
descriptor_build :: proc(p:^Protocol,name:string,fragments:[]Fragment_Desc,max_bytes:int,parts:=false) -> (type:Object_Type,ok:bool) {
    if len(fragments)==0 || len(fragments)>MAX_FRAGMENTS {return}
    first:=len(p.leaves)
    choices:=len(p.choices)
    defer if !ok {base.truncate(&p.leaves,first);base.truncate(&p.choices,choices)}
    fields:=0
    units:[MAX_FRAGMENTS]int
    for fragment,index in fragments {
        if fragment.schema==nil || int(fragment.type)>=len(fragment.schema.types) {return}
        root:=serial.schema_type(fragment.schema,fragment.type)
        if root.kind!=.Struct {units[index]=1;fields+=1;continue}
        for field in serial.schema_fields(fragment.schema,fragment.type) {
            if .Local not_in field.flags {units[index]+=descriptor_units(fragment.schema,field.type)}
        }
        fields+=units[index]
    }
    if fields==0 {return}
    type.name_hash=base.name_hash(name)
    type.fragment_count=len(fragments)
    type.first_leaf=first
    type.bit_count=min(fields,64)
    type.index_bits=serial.bit_count_for(u64(type.bit_count-1))
    words,bit_base,left:=0,0,fields
    for fragment,index in fragments {
        root:=serial.schema_type(fragment.schema,fragment.type)
        info:=Fragment_Info{size=root.size,first_leaf=u32(len(p.leaves)-first),condition=fragment.condition}
        groups:=units[index]
        if fields>64 && groups>0 {
            reserve:=0
            for count in units[index+1:len(fragments)] {reserve+=int(count>0)}
            groups=min(groups,max(1,min(type.bit_count-bit_base-reserve,(type.bit_count-bit_base)*groups/left)))
        }
        field:=0
        if root.kind!=.Struct {
            if !leaves_add(p,fragment.schema,fragment.type,nil,0,u8(bit_base),0,u8(index),&words) {return}
        } else {
            for &member in serial.schema_fields(fragment.schema,fragment.type) {
                if .Local in member.flags {continue}
                if !descriptor_member_add(p,fragment.schema,member.type,&member,member.offset,u8(index),bit_base,groups,units[index],&field,&words) {return}
            }
        }
        bit_base+=groups
        left-=units[index]
        info.leaf_count=u32(len(p.leaves)-first)-info.first_leaf
        type.fragments[index]=info
    }
    type.leaf_count=len(p.leaves)-first
    type.words=words
    if words>MAX_STATE_WORDS {return}
    type_finish(p,&type,p.leaves[first:],max_bytes,parts) or_return
    type.name=strings.clone(name,p.allocator)
    return type,true
}

// What a type derives from its leaves: the change bits of each fragment and
// audience, its hash and its largest encoding. False when one change bit
// encodes larger than max_bytes, or the whole state does and it cannot go in
// parts.
@(private)
type_finish :: proc(p:^Protocol,type:^Object_Type,leaves:[]Leaf,max_bytes:int,parts:bool) -> bool {
    if len(leaves)>int(max(u16)) {return false}
    type.hash=base.hash_combine(type.name_hash,u64(type.fragment_count)<<32|u64(type.leaf_count))
    type.max_bits=type.bit_count+8
    previous:=-1
    for leaf,i in leaves {
        bit:=int(leaf.bit)
        mask:=u64(1)<<uint(bit)
        if bit!=previous {
            type.bit_leaf[bit],type.bit_word[bit]=u16(i),leaf.word
            previous=bit
        }
        type.bit_leaves[bit]+=1
        type.bit_words[bit]+=leaf.words
        type.all|=mask
        type.fragment_bits[leaf.fragment]|=mask
        if leaf.kind==.Object {type.reference_fragments|=1<<leaf.fragment}
        switch type.fragments[leaf.fragment].condition {
        case .All:       type.owner|=mask;type.others|=mask
        case .Owner:     type.owner|=mask
        case .Not_Owner: type.others|=mask
        }
        type.max_bits+=leaf_max_bits(leaf)
        type.bit_max_bits[bit]+=u32(leaf_max_bits(leaf))+1
        hash:=u64(leaf.kind)|u64(leaf.bit)<<8|u64(leaf.bits)<<16|u64(leaf.words)<<24|u64(leaf.count)<<40
        type.hash=base.hash_combine(type.hash,hash)
        type.hash=base.hash_combine(type.hash,transmute(u64)leaf.low)
        type.hash=base.hash_combine(type.hash,transmute(u64)leaf.step)
        type.hash=base.hash_combine(type.hash,u64(leaf.fragment)|u64(type.fragments[leaf.fragment].condition)<<8)
        if leaf.kind==.Enum {
            for value in p.choices[leaf.choices:][:leaf.count] {type.hash=base.hash_combine(type.hash,u64(value))}
        }
    }
    type.large=type.max_bits>max_bytes*8
    if type.large && !parts {return false}
    for bits in type.bit_max_bits {
        if int(bits)+type.bit_count+8>max_bytes*8 {return false}
    }
    return true
}

@(private)
descriptor_units :: proc(s:^serial.Schema,index:serial.Type_Index) -> int {
    type:=serial.schema_type(s,index)
    if type.kind==.Array && serial.schema_type(s,type.elem).kind==.Struct {return int(type.count)}
    if type.kind==.Struct {
        count:=0
        split:=false
        for member in serial.schema_fields(s,index) {
            if .Local in member.flags {continue}
            units:=descriptor_units(s,member.type)
            count+=units
            split||=units!=1 || serial.schema_type(s,member.type).kind==.Array && serial.schema_type(s,serial.schema_type(s,member.type).elem).kind==.Struct
        }
        if split {return count}
    }
    return 1
}

@(private)
descriptor_member_add :: proc(p:^Protocol,s:^serial.Schema,index:serial.Type_Index,member:^serial.Field,offset:u32,fragment:u8,bit_base,groups,units:int,field,words:^int) -> bool {
    type:=serial.schema_type(s,index)
    if type.kind==.Struct && descriptor_units(s,index)!=1 {
        for &child in serial.schema_fields(s,index) {
            if .Local in child.flags {continue}
            if !descriptor_member_add(p,s,child.type,&child,offset+child.offset,fragment,bit_base,groups,units,field,words) {return false}
        }
        return true
    }
    if type.kind==.Array && serial.schema_type(s,type.elem).kind==.Struct {
        element:=serial.schema_type(s,type.elem)
        for i in 0..<type.count {
            bit,unit:=u8(bit_base+field^*groups/units),u16(field^)
            field^+=1
            if !leaves_add(p,s,type.elem,member,offset+i*element.size,bit,unit,fragment,words) {return false}
        }
        return true
    }
    bit,unit:=u8(bit_base+field^*groups/units),u16(field^)
    field^+=1
    return leaves_add(p,s,index,member,offset,bit,unit,fragment,words)
}

@(private)
leaf_max_bits :: proc(leaf:Leaf) -> int {
    #partial switch leaf.kind {
    case .Bool:       return 1
    case .Quantized:  return 34
    case .Quaternion: return 3+3*int(leaf.bits)
    case .Rotation:   return 129
    case .Text:       return 1+int(leaf.bits)+int(leaf.count)*8
    }
    return int(leaf.bits)+2
}

@(private)
leaves_add :: proc(p:^Protocol,s:^serial.Schema,index:serial.Type_Index,field:^serial.Field,offset:u32,bit:u8,unit:u16,fragment:u8,words:^int) -> bool {
    type:=serial.schema_type(s,index)^
    leaf:=Leaf{fragment=fragment,bit=bit,unit=unit,size=u16(type.size),source=offset,words=1}
    whole:=int(type.size)*8
    ranged:=field!=nil && field.has_min && field.has_max && field.max>field.min
    switch type.kind {
    case .Bool:
        leaf.kind,leaf.bits=.Bool,1
    case .Int,.Uint:
        if type.size>8 {return false}
        leaf.kind=type.kind==.Int?.Signed:.Unsigned
        leaf.bits=u8(whole)
        if field!=nil && field.bits>0 && int(field.bits)<whole {
            leaf.bits=field.bits
        } else if ranged {
            leaf.kind,leaf.low,leaf.count=.Offset,field.min,u32(type.kind==.Int)
            leaf.bits=u8(max(serial.bit_count_for(u64(i64(field.max)-i64(field.min))),1))
        }
    case .Float:
        leaf.kind,leaf.bits=.Float,u8(whole)
        if field!=nil && field.precision>0 {
            leaf.step=f64(field.precision)
            if ranged {
                leaf.kind,leaf.low=.Ranged,field.min
                steps:=math.ceil((field.max-field.min)/leaf.step)
                if steps>=f64(u64(1)<<32) {return false}
                leaf.bits=u8(max(serial.bit_count_for(u64(steps)),1))
            } else {
                leaf.kind,leaf.bits=.Quantized,32
            }
        }
    case .Enum:
        if type.size>8 || type.count==0 {return false}
        leaf.kind,leaf.choices,leaf.count=.Enum,u32(len(p.choices)),type.count
        leaf.bits=u8(max(serial.bit_count_for(u64(type.count-1)),1))
        for choice in serial.schema_choices(s,index) {
            if _,error:=append(&p.choices,choice.value);error!=nil {return false}
        }
    case .Bit_Set:
        if type.size>8 {return false}
        top:=i64(0)
        for choice in serial.schema_choices(s,index) {top=max(top,choice.value)}
        leaf.kind,leaf.bits=.Bit_Set,u8(clamp(type.count==0?whole:int(top)+1,1,whole))
    case .Entity:
        leaf.kind,leaf.bits=.Object,64
    case .Entity_Id:
        leaf.kind,leaf.bits=.Unsigned,64
    case .Asset:
        for half in 0..<u32(2) {
            part:=leaf
            part.kind,part.bits,part.words,part.size,part.source=.Unsigned,64,2,8,offset+half*8
            part.word=u16(words^)
            words^+=2
            if _,error:=append(&p.leaves,part);error!=nil {return false}
        }
        return true
    case .Struct:
        for &member in serial.schema_fields(s,index) {
            if .Local in member.flags {continue}
            if !leaves_add(p,s,member.type,&member,offset+member.offset,bit,unit,fragment,words) {return false}
        }
        return true
    case .Array:
        element:=serial.schema_type(s,type.elem)^
        if field!=nil && .Text in field.flags && element.kind==.Uint && element.size==1 {
            if type.count==0 || type.count>255 {return false}
            leaf.kind,leaf.count=.Text,type.count
            leaf.bits=u8(serial.bit_count_for(u64(type.count)))
            leaf.words=u16((type.count+3)/4)
        } else if field!=nil && .Rotation in field.flags && type.count==4 && element.kind==.Float && element.size==4 {
            leaf.kind,leaf.words,leaf.bits=.Rotation,4,32
            if field.bits>0 || field.precision>0 {
                bits:=field.bits>0?int(field.bits):serial.bit_count_for(u64(math.ceil(math.SQRT_TWO/f64(field.precision))))
                leaf.kind,leaf.words,leaf.bits=.Quaternion,2,u8(clamp(bits,2,serial.BIT_QUATERNION_MAX_BITS))
            }
        } else {
            for i in 0..<type.count {
                if !leaves_add(p,s,type.elem,field,offset+i*element.size,bit,unit,fragment,words) {return false}
            }
            return true
        }
    }
    if leaf.kind!=.Text && leaf.kind!=.Rotation && (leaf.bits>32 || leaf.kind==.Quaternion) {leaf.words=2}
    leaf.word=u16(words^)
    words^+=int(leaf.words)
    _,error:=append(&p.leaves,leaf)
    return error==nil
}

@(private)
source_load :: #force_inline proc "contextless" (source:rawptr,size:u16,signed:bool) -> u64 {
    switch size {
    case 1: return signed?u64(i64((^i8)(source)^)):u64((^u8)(source)^)
    case 2: return signed?u64(i64(intrinsics.unaligned_load((^i16)(source)))):u64(intrinsics.unaligned_load((^u16)(source)))
    case 4: return signed?u64(i64(intrinsics.unaligned_load((^i32)(source)))):u64(intrinsics.unaligned_load((^u32)(source)))
    }
    return intrinsics.unaligned_load((^u64)(source))
}
@(private)
source_store :: #force_inline proc "contextless" (target:rawptr,size:u16,value:u64) {
    switch size {
    case 1: (^u8)(target)^=u8(value)
    case 2: intrinsics.unaligned_store((^u16)(target),u16(value))
    case 4: intrinsics.unaligned_store((^u32)(target),u32(value))
    case:   intrinsics.unaligned_store((^u64)(target),value)
    }
}
@(private)
float_load :: #force_inline proc "contextless" (source:rawptr,size:u16) -> f64 {
    switch size {
    case 2: return f64(intrinsics.unaligned_load((^f16)(source)))
    case 4: return f64(intrinsics.unaligned_load((^f32)(source)))
    }
    return intrinsics.unaligned_load((^f64)(source))
}
@(private)
float_store :: #force_inline proc "contextless" (target:rawptr,size:u16,value:f64) {
    switch size {
    case 2: intrinsics.unaligned_store((^f16)(target),f16(value))
    case 4: intrinsics.unaligned_store((^f32)(target),f32(value))
    case:   intrinsics.unaligned_store((^f64)(target),value)
    }
}
@(private) low_mask :: #force_inline proc "contextless" (bits:u8) -> u64 {return bits>=64?max(u64):u64(1)<<bits-1}
@(private) word_load :: #force_inline proc "contextless" (words:[]u32,leaf:^Leaf) -> u64 {
    return leaf.words==2?u64(words[leaf.word])|u64(words[leaf.word+1])<<32:u64(words[leaf.word])
}
@(private) word_store :: #force_inline proc "contextless" (words:[]u32,leaf:^Leaf,value:u64) {
    words[leaf.word]=u32(value)
    if leaf.words==2 {words[leaf.word+1]=u32(value>>32)}
}

// Maps the ids of Entity fields: user id to network object when quantizing and back when reading.
@(private) Object_Map :: #type proc(h:^Host,value:u64) -> u64

// Fragment bytes to the words of its leaves.
@(private)
fragment_quantize :: proc(p:^Protocol,type:^Object_Type,fragment:int,source:rawptr,words:[]u32,h:^Host,to_object:Object_Map) {
    info:=type.fragments[fragment]
    for &leaf in type.leaves[info.first_leaf:][:info.leaf_count] {
        at:=rawptr(uintptr(source)+uintptr(leaf.source))
        value:u64
        switch leaf.kind {
        case .Bool:     value=u64((^u8)(at)^!=0)
        case .Unsigned: value=source_load(at,leaf.size,false)&low_mask(leaf.bits)
        case .Signed:   value=source_load(at,leaf.size,true)&low_mask(leaf.bits)
        case .Bit_Set:  value=source_load(at,leaf.size,false)&low_mask(leaf.bits)
        case .Offset:
            low:=i64(leaf.low)
            top:=i64(low_mask(leaf.bits))
            raw:=source_load(at,leaf.size,leaf.count!=0)
            value=u64(clamp(i64(raw)-low,0,top))
        case .Float:
            value=source_load(at,leaf.size,false)
        case .Quantized:
            steps:=float_load(at,leaf.size)/leaf.step
            if steps!=steps {steps=0}
            value=u64(u32(i32(clamp(math.round(steps),f64(min(i32)),f64(max(i32))))))
        case .Ranged:
            steps:=(float_load(at,leaf.size)-leaf.low)/leaf.step
            if steps!=steps {steps=0}
            value=u64(clamp(steps+0.5,0,f64(low_mask(leaf.bits))))
        case .Enum:
            raw:=i64(source_load(at,leaf.size,true))
            for choice,i in p.choices[leaf.choices:][:leaf.count] {
                if choice==raw || u64(choice)&low_mask(u8(leaf.size*8))==u64(raw)&low_mask(u8(leaf.size*8)) {value=u64(i);break}
            }
        case .Object:
            value=to_object==nil?0:to_object(h,intrinsics.unaligned_load((^u64)(at)))
        case .Quaternion:
            value=serial.quantize_quaternion(intrinsics.unaligned_load((^quaternion128)(at)),int(leaf.bits))
        case .Rotation:
            mem.copy(&words[leaf.word],at,16)
            continue
        case .Text:
            target:=([^]u8)(&words[leaf.word])
            mem.zero(target,int(leaf.words)*4)
            for i in 0..<int(leaf.count) {
                c:=([^]u8)(at)[i]
                if c==0 {break}
                target[i]=c
            }
            continue
        }
        word_store(words,&leaf,value)
    }
}

// Words back to fragment bytes, for the fields whose change bit is in mask.
// Fields that are not replicated keep what target had.
@(private)
fragment_dequantize :: proc(p:^Protocol,type:^Object_Type,fragment:int,words:[]u32,mask:u64,target:rawptr,h:^Host,to_user:Object_Map) {
    info:=type.fragments[fragment]
    for &leaf in type.leaves[info.first_leaf:][:info.leaf_count] {
        if mask&(1<<leaf.bit)==0 {continue}
        at:=rawptr(uintptr(target)+uintptr(leaf.source))
        value:=leaf.kind==.Text || leaf.kind==.Rotation?0:word_load(words,&leaf)
        switch leaf.kind {
        case .Bool:              (^u8)(at)^=u8(value&1)
        case .Unsigned,.Bit_Set: source_store(at,leaf.size,value&low_mask(leaf.bits))
        case .Signed:
            shift:=64-uint(leaf.bits)
            source_store(at,leaf.size,u64(i64(value<<shift)>>shift))
        case .Offset:    source_store(at,leaf.size,u64(i64(leaf.low)+i64(value&low_mask(leaf.bits))))
        case .Float:     source_store(at,leaf.size,value)
        case .Quantized: float_store(at,leaf.size,f64(i32(u32(value)))*leaf.step)
        case .Ranged:    float_store(at,leaf.size,leaf.low+f64(value&low_mask(leaf.bits))*leaf.step)
        case .Enum:      source_store(at,leaf.size,u64(p.choices[leaf.choices+u32(value<u64(leaf.count)?value:0)]))
        case .Object:    intrinsics.unaligned_store((^u64)(at),to_user==nil?0:to_user(h,value))
        case .Quaternion:intrinsics.unaligned_store((^quaternion128)(at),serial.dequantize_quaternion(value,int(leaf.bits)))
        case .Rotation:  mem.copy(at,&words[leaf.word],16)
        case .Text:
            mem.copy(at,&words[leaf.word],int(leaf.count))
            ([^]u8)(at)[leaf.count-1]=0
        }
    }
}

@(private) VAR_WHOLE :: [4]u8{6,12,20,32}
@(private) VAR_DELTA :: [4]u8{0,6,12,32}

@(private)
var_write :: #force_inline proc "contextless" (w:^serial.Bit_Writer,value:u32,widths:[4]u8) {
    for width,i in widths {
        if i==3 || u64(value)<u64(1)<<width {
            serial.bit_write(w,u64(i)|u64(value)<<2,2+int(width))
            return
        }
    }
}
@(private)
var_read :: #force_inline proc "contextless" (r:^serial.Bit_Reader,widths:[4]u8) -> u32 {
    return u32(serial.bit_read(r,int(widths[serial.bit_read(r,2)])))
}
@(private) zigzag32 :: #force_inline proc "contextless" (value:i32) -> u32 {return u32(value<<1)~u32(value>>31)}
@(private) unzigzag32 :: #force_inline proc "contextless" (value:u32) -> i32 {return i32(value>>1)~-i32(value&1)}

// Writes the leaves of the change bits in mask. With a base, each leaf is
// written as its difference to the same leaf of the base.
@(private)
state_write :: proc(w:^serial.Bit_Writer,type:^Object_Type,mask:u64,words:[]u32,base:[]u32) {
    rest:=mask&type.all
    for rest!=0 {
        bit:=intrinsics.count_trailing_zeros(rest)
        rest&=rest-1
        for &leaf in type.leaves[type.bit_leaf[bit]:][:type.bit_leaves[bit]] {
            if leaf.kind==.Text || leaf.kind==.Rotation {
                span:=words[leaf.word:][:leaf.words]
                if base!=nil {
                    same:=mem.compare_ptrs(&words[leaf.word],&base[leaf.word],int(leaf.words)*4)==0
                    serial.bit_write_bool(w,same)
                    if same {continue}
                }
                bytes:=mem.slice_data_cast([]u8,span)
                if leaf.kind==.Text {
                    length:=0
                    for length<int(leaf.count) && bytes[length]!=0 {length+=1}
                    serial.bit_write(w,u64(length),int(leaf.bits))
                    bytes=bytes[:length]
                }
                serial.bit_write_bytes(w,bytes)
                continue
            }
            value:=word_load(words,&leaf)
            width:=leaf.kind==.Quaternion?2+3*int(leaf.bits):int(leaf.bits)
            if base==nil {
                if leaf.kind==.Quantized {var_write(w,zigzag32(i32(u32(value))),VAR_WHOLE)} else {serial.bit_write(w,value,width)}
                continue
            }
            old:=word_load(base,&leaf)
            switch {
            case leaf.kind==.Quantized:
                var_write(w,zigzag32(i32(u32(value))-i32(u32(old))),VAR_DELTA)
            case width==1:
                serial.bit_write(w,value,1)
            case width<12 || leaf.kind==.Quaternion || leaf.kind==.Float:
                serial.bit_write_bool(w,value==old)
                if value!=old {serial.bit_write(w,value,width)}
            case:
                serial.bit_write_bool(w,value==old)
                if value==old {continue}
                small:=width/2
                difference:=serial.bit_zigzag(i64(value)-i64(old))
                fits:=difference<u64(1)<<uint(small)
                serial.bit_write_bool(w,fits)
                if fits {serial.bit_write(w,difference,small)} else {serial.bit_write(w,value,width)}
            }
        }
    }
}

// Reads what state_write wrote into words. base must be the state the sender used.
@(private)
state_read :: proc(r:^serial.Bit_Reader,type:^Object_Type,mask:u64,words:[]u32,base:[]u32) -> bool {
    rest:=mask&type.all
    for rest!=0 {
        bit:=intrinsics.count_trailing_zeros(rest)
        rest&=rest-1
        for &leaf in type.leaves[type.bit_leaf[bit]:][:type.bit_leaves[bit]] {
            if leaf.kind==.Text || leaf.kind==.Rotation {
                span:=words[leaf.word:][:leaf.words]
                if base!=nil && serial.bit_read_bool(r) {
                    copy(span,base[leaf.word:][:leaf.words])
                    continue
                }
                bytes:=mem.slice_data_cast([]u8,span)
                if leaf.kind==.Text {
                    length:=int(serial.bit_read(r,int(leaf.bits)))
                    if length>int(leaf.count) {return false}
                    mem.zero_slice(bytes)
                    bytes=bytes[:length]
                }
                if !serial.bit_read_bytes(r,bytes) {return false}
                continue
            }
            width:=leaf.kind==.Quaternion?2+3*int(leaf.bits):int(leaf.bits)
            value:u64
            if base==nil {
                value=leaf.kind==.Quantized?u64(u32(unzigzag32(var_read(r,VAR_WHOLE)))):serial.bit_read(r,width)
            } else {
                old:=word_load(base,&leaf)
                switch {
                case leaf.kind==.Quantized:
                    value=u64(u32(i32(u32(old))+unzigzag32(var_read(r,VAR_DELTA))))
                case width==1:
                    value=serial.bit_read(r,1)
                case width<12 || leaf.kind==.Quaternion || leaf.kind==.Float:
                    value=serial.bit_read_bool(r)?old:serial.bit_read(r,width)
                case:
                    if serial.bit_read_bool(r) {
                        value=old
                    } else if serial.bit_read_bool(r) {
                        value=u64(i64(old)+serial.bit_unzigzag(serial.bit_read(r,width/2)))&low_mask(u8(width))
                    } else {
                        value=serial.bit_read(r,width)
                    }
                }
            }
            word_store(words,&leaf,value)
        }
    }
    return !r.error
}

// Change bits, among those in bits, whose words differ between two states.
@(private)
state_diff :: proc(type:^Object_Type,a,b:[]u32,bits:u64) -> (mask:u64) {
    rest:=bits&type.all
    for rest!=0 {
        bit:=intrinsics.count_trailing_zeros(rest)
        rest&=rest-1
        first,count:=int(type.bit_word[bit]),int(type.bit_words[bit])
        if mem.compare_ptrs(&a[first],&b[first],count*4)!=0 {mask|=1<<bit}
    }
    return
}
@(private)
state_copy :: proc(type:^Object_Type,target,source:[]u32,mask:u64) {
    rest:=mask&type.all
    for rest!=0 {
        bit:=intrinsics.count_trailing_zeros(rest)
        rest&=rest-1
        first,count:=int(type.bit_word[bit]),int(type.bit_words[bit])
        copy(target[first:][:count],source[first:][:count])
    }
}
// Change bits whose words are not all zero: what a new replica does not already have.
@(private)
state_nonzero :: proc(type:^Object_Type,words:[]u32) -> (mask:u64) {
    for bit in 0..<uint(type.bit_count) {
        for word in words[type.bit_word[bit]:][:type.bit_words[bit]] {
            if word!=0 {mask|=1<<bit;break}
        }
    }
    return
}

// The change bits of `mask`, from the lowest, whose fields fit in `room` bits at their largest, with the mask.
@(private)
state_fit :: proc(type:^Object_Type,mask:u64,room:int) -> (fit:u64) {
    used:=type.bit_count+1
    for rest:=mask&type.all;rest!=0;rest&=rest-1 {
        bit:=intrinsics.count_trailing_zeros(rest)
        used+=int(type.bit_max_bits[bit])
        if used>room {break}
        fit|=u64(1)<<bit
    }
    return
}

@(private)
mask_write :: proc(w:^serial.Bit_Writer,type:^Object_Type,mask:u64) {
    if type.bit_count<=8 {serial.bit_write(w,mask,type.bit_count);return}
    count:=int(intrinsics.count_ones(mask))
    sparse:=count>=1 && count<=4 && 2+count*type.index_bits<type.bit_count
    serial.bit_write_bool(w,sparse)
    if !sparse {serial.bit_write(w,mask,type.bit_count);return}
    serial.bit_write(w,u64(count-1),2)
    for rest:=mask;rest!=0;rest&=rest-1 {serial.bit_write(w,u64(intrinsics.count_trailing_zeros(rest)),type.index_bits)}
}
@(private)
mask_read :: proc(r:^serial.Bit_Reader,type:^Object_Type) -> (mask:u64,ok:bool) {
    if type.bit_count<=8 || !serial.bit_read_bool(r) {
        mask=serial.bit_read(r,type.bit_count)
    } else {
        count:=int(serial.bit_read(r,2))+1
        for _ in 0..<count {mask|=1<<serial.bit_read(r,type.index_bits)}
    }
    return mask,!r.error && mask&~type.all==0
}

// Blends the replicated fields of two copies of a fragment: floats linearly,
// rotations along the shortest arc, everything else switching at the middle.
fragment_interpolate :: proc(p:^Protocol,type:Type_Id,fragment:int,a,b:rawptr,alpha:f32,out:rawptr) {
    t:=&p.types[type]
    info:=t.fragments[fragment]
    for &leaf in t.leaves[info.first_leaf:][:info.leaf_count] {
        offset:=uintptr(leaf.source)
        pa,pb,po:=rawptr(uintptr(a)+offset),rawptr(uintptr(b)+offset),rawptr(uintptr(out)+offset)
        #partial switch leaf.kind {
        case .Float,.Quantized,.Ranged:
            va,vb:=float_load(pa,leaf.size),float_load(pb,leaf.size)
            float_store(po,leaf.size,va+(vb-va)*f64(alpha))
        case .Quaternion,.Rotation:
            qa,qb:=intrinsics.unaligned_load((^[4]f32)(pa)),intrinsics.unaligned_load((^[4]f32)(pb))
            if qa[0]*qb[0]+qa[1]*qb[1]+qa[2]*qb[2]+qa[3]*qb[3]<0 {qb=-qb}
            q:=qa+(qb-qa)*alpha
            length:=math.sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3])
            if length>0 {q/=length} else {q=qa}
            intrinsics.unaligned_store((^[4]f32)(po),q)
        case:
            mem.copy(po,alpha<0.5?pa:pb,leaf.kind==.Text?int(leaf.count):int(leaf.size))
        }
    }
}
