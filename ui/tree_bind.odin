package ui

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"
import mm "mirai:std/math"

// How the nodes of a tree read the data of the game. A binding is a path: it
// names a source first (a component of the entity the tree is built for, or
// a storage), dots go into the structs it holds, a number after an array is
// its element ("Hotbar.slots.2.count"), and past a field of type Entity the
// next name is a component of that entity
// ("Player_Stats.target.Nameplate_Data.health"). Inside a List the paths of
// the node it holds start at its element: a field of it, or for an array of
// entities a component of the element. A List that names a component alone
// takes a row of its table per element. A text with paths in braces is a
// template: "HP {health:0}/{most}", whose names are fields of the node with
// the paths they show. After the colon, a format: digits are decimals, %
// shows a fraction as a percent (with its digits after it), mm:ss and
// hh:mm:ss show seconds as a clock and + shows the sign. A pattern such as
// #,##0.00 groups thousands and writes the point as the language does, a bool
// shows "Yes|No", an enum maps its names ("Sword=Espada|Bow=Arco") and a
// number takes the text of its plural category in the language
// ("one=# coin|other=# coins", # is the number). {{ and }} are braces.
//
// The instance resolves the paths once into a plan: the regions of the game
// it reads (a source, a component reached through an entity, the elements of
// an array) and of each the ranges of bytes the tree reads. Its copy holds
// only those ranges, packed; tree_values_refresh compares them with the game
// and copies those that differ, so a field nothing shows costs nothing, and
// keeps which of them changed until the tree is built: only the texts that
// read those are formatted again.

Binding :: enum u8 {Text,Value,Visible,Selected,Disabled,Items,Image,Tint,Variant}

// A name kept in the strings of a tree.
Name_Ref :: struct {offset,length:u32}
// A name in braces of the text of a node (name_hash) and the path it shows, in strings.
Node_Field_Ref :: struct {name:u64,path:Name_Ref}
Node_Field_Desc :: struct {name,path:string}

TREE_PATH_CAPACITY :: 128 // bytes of a path a node binds, with its terminator

// What the bindings of a tree read of the game, as its host gives it.
Bind_Host :: struct {
    user:rawptr,
    schema:^serial.Schema,
    // The type of the source whose name has this name_hash, and whether it is a storage.
    source:proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool),
    // The bytes of a source of an entity (a storage takes none) and their
    // stamp, which moves when they change; 0: they are compared. nil: the
    // entity does not have it.
    fetch:proc(user:rawptr,name:u64,entity:base.Entity) -> (data:rawptr,stamp:u64),
    // The rows of the table of the component whose name has this name_hash,
    // one after the other: the bytes of the first, how many there are, how
    // far apart they start, and a stamp that moves when any of them changes
    // or rows come and go (0: they are compared). nil data: no rows.
    rows:proc(user:rawptr,name:u64) -> (data:rawptr,count,stride:int,stamp:u64),
    // Whether a control bound to a field of this storage writes it itself:
    // its Changed event then says what it wrote instead of asking the game.
    // nil: none does.
    commits:proc(user:rawptr,name:u64) -> bool,
}

@(private)
Region_Kind :: enum u8 {Source,Hop,Array,Rows}

// A part of the game the copy of an instance reads.
@(private)
Bind_Region :: struct {
    kind:Region_Kind,
    frame:i32,         // the Array in whose element it is packed; -1: the copy itself
    parent:i32,        // Hop: the region whose bytes hold its entity; Array: whose bytes hold the array (a Rows: the table)
    name:u64,          // Source, Hop, Rows: name_hash of the source or the component
    type:serial.Type_Index, // Source, Hop, Rows: of its bytes; Array: of its elements
    storage:bool,      // Source
    src:u32,           // Hop: where its entity is in the bytes of parent; Array: where the array is
    entity:u32,        // Hop: where its entity is packed, in its frame
    count,stride:u32,  // Array: its elements, and their size in the game; Rows: the rows the table has now and how far apart
    dst:u32,           // where it is packed, in its frame
    size:u32,          // packed: of one element for an Array
    first,ranges:u32,  // in Tree_Instance.ranges
    stamp:u64,         // of the bytes copied last, outside arrays
    last:base.Entity,  // Hop outside arrays: the entity they came from
    unchanged:bool,    // outside arrays: its stamp did not move in the last refresh, so its bytes were not looked at
    pure:bool,         // Array: no entity is reached inside it, so it changes only with the bytes of its parent
}
// Bytes of a region the tree reads: where they are in the game and in the copy.
@(private)
Bind_Range :: struct {region:i32,src,dst,size:u32}

// Where the paths of a node start.
@(private)
Bind_Scope :: struct {
    kind:enum u8 {Sources,Struct,Entity},
    region:i32,  // Struct: whose bytes hold the struct; Entity: whose bytes hold the entity
    offset:u32,  // in them
    type:serial.Type_Index, // Struct
}

// What failed when an instance did not take its tree: the node and what of it.
Bind_Failure :: struct {
    node:int,          // -1: none
    binding:Binding,
    template:bool,     // its text names in braces what failed
    capacity:bool,     // the lists of the tree need more than TREE_SLOTS slots, or memory ran out
}

@(private)
Bound :: struct {
    offset,size:u32, // in the frame of the node, once the plan is made; till then, in the bytes of region
    region:i32,
    kind:serial.Type_Kind,
    text:bool,    // an array of bytes holding NUL-terminated text
    bound:bool,
    count:u32,    // of an array: a color has 4
    elem:serial.Type_Kind,
    stride:u32,   // of an array of options: the size of each
    // Of an enum, or of the enums of an array of options, shown by name: found
    // again each time, because the schema moves its choices as it grows.
    choices_of:^serial.Schema,
    choices_type:serial.Type_Index,
}

@(private)
bound_choices :: proc(b:Bound) -> []serial.Choice {
    return serial.schema_choices(b.choices_of,b.choices_type) if b.choices_of!=nil else nil
}
@(private)
Node_Bound :: struct {text,value,visible,selected,disabled,image,tint,variant:Bound,options:Bound}
// The array a List builds its node for.
@(private)
Node_Items :: struct {
    offset,stride:u32, // packed, in the frame of the List
    count:u32,  // elements of the array, the most rows of a table; of a List that binds none, its count
    region:i32,
    bound:bool,
    rows:bool,  // of a table: as many elements as the table has rows now, up to count
}

@(private)
Format :: enum u8 {Default,Decimals,Percent,Clock,Clock_Hours,Pattern,Choice,Plural}
@(private)
Template_Part :: struct {
    literal:string, // shown as it is; empty for a field
    bound:Bound,
    format:Format,
    decimals:u8,    // Decimals, Percent; Pattern: the most it shows
    sign:bool,
    places:[2]u8,   // Pattern: the least digits before the point and after it
    grouped:bool,   // Pattern: thousands are grouped
    percent:bool,   // Pattern: a fraction shown as a percent
    spec:string,    // Choice and Plural: the texts it chooses from
}
// The parts of the text of a node, in parts of its instance.
@(private)
Template :: struct {first,count:u32,template:bool}

TREE_TEXT_KEPT :: 256 // bytes of the text a node formats that its instance keeps while values do not change

@(private)
Kept_Text :: struct {offset:u32,length:u16,valid:bool}

// The path a node binds, as the tree keeps it.
tree_binding :: proc "contextless" (tree:^Widget_Tree,node:^Node,binding:Binding) -> string {
    ref:=node.binds[binding]
    return string(tree.strings[ref.offset:][:ref.length])
}

// ---------------------------------------------------------------- the plan

// The frame whose copy holds the bytes of a region: the element of an
// Array, for what an Array holds; its frame otherwise.
@(private)
region_home :: proc(instance:^Tree_Instance,region:i32) -> i32 {
    if region<0 {return -1}
    r:=&instance.regions[region]
    return region if r.kind==.Array else r.frame
}

// The region with these keys, made the first time. -1: there is no host to
// make it with.
@(private)
bind_region :: proc(instance:^Tree_Instance,region:Bind_Region) -> i32 {
    for &r,i in instance.regions {
        if r.kind==region.kind && r.frame==region.frame && r.parent==region.parent && r.name==region.name && r.src==region.src {return i32(i)}
    }
    if instance.host==nil {return -1}
    append(&instance.regions,region)
    return i32(len(instance.regions)-1)
}

// The tree reads size bytes at src of region: the plan copies them.
@(private)
bind_want :: proc(instance:^Tree_Instance,region:i32,src,size:u32) -> bool {
    if instance.host==nil {
        // Without a host the plan is made: only what it holds is found.
        _,found:=bind_offset(instance,region,src,size)
        return found
    }
    append(&instance.ranges,Bind_Range{region=region,src=src,size=size})
    return true
}

// Where the bytes at src of region are in the copy of its frame.
@(private)
bind_offset :: proc(instance:^Tree_Instance,region:i32,src,size:u32) -> (offset:u32,found:bool) {
    r:=&instance.regions[region]
    origin:=u32(0) if r.kind==.Array else r.dst
    for range in instance.ranges[r.first:][:r.ranges] {
        if src>=range.src && src+size<=range.src+range.size {return origin+range.dst+(src-range.src),true}
    }
    return
}

// The field a path names from scope: its region, where it is in the bytes
// of the region, and its type. Without a host only the regions the plan
// holds are found.
@(private)
bind_resolve :: proc(instance:^Tree_Instance,scope:Bind_Scope,path:string) -> (region:i32,offset:u32,type:serial.Type_Index,ok:bool) {
    schema:=instance.schema
    if schema==nil || path=="" {return}
    host:=instance.host
    s:=scope
    rest:=path
    for rest!="" {
        name:=rest
        if dot:=strings.index_byte(rest,'.');dot>=0 {name,rest=rest[:dot],rest[dot+1:]} else {rest=""}
        if name=="" {return}
        hash:=base.name_hash(name)
        switch s.kind {
        case .Sources,.Entity:
            source:=Bind_Region{kind=.Source,frame=-1,parent=-1,name=hash}
            if s.kind==.Entity {
                bind_want(instance,s.region,s.offset,size_of(base.Entity)) or_return
                source={kind=.Hop,frame=region_home(instance,s.region),parent=s.region,name=hash,src=s.offset}
            }
            if host!=nil {
                t,storage,found:=host.source(host.user,hash)
                if !found || storage && s.kind==.Entity {return}
                source.type,source.storage=t,storage
            }
            at:=bind_region(instance,source)
            if at<0 {return}
            s={kind=.Struct,region=at,offset=0,type=instance.regions[at].type}
        case .Struct:
            field:=serial.schema_field(schema,s.type,hash)
            if field==nil {return}
            type:=field.type
            t:=serial.schema_type(schema,type)
            s.offset+=field.offset
            // A number after an array names its element: "build.2.key".
            for t!=nil && t.kind==.Array && rest!="" {
                segment,after:=rest,""
                if dot:=strings.index_byte(rest,'.');dot>=0 {segment,after=rest[:dot],rest[dot+1:]}
                element,parsed:=strconv.parse_uint(segment,10)
                if !parsed {break}
                e:=serial.schema_type(schema,t.elem)
                if e==nil || element>=uint(t.count) {return}
                s.offset+=u32(element)*e.size
                type,t,rest=t.elem,e,after
            }
            if rest=="" {return s.region,s.offset,type,true}
            #partial switch t.kind {
            case .Struct: s.type=type
            case .Entity: s.kind=.Entity
            case:         return
            }
        }
    }
    // A path that stops at a source or a component names all of it.
    if s.kind==.Struct {return s.region,s.offset,s.type,true}
    return
}

// A field a node shows or reads. want: what it must hold; Option, what a
// Selector or a Dropdown binds: a number, or an enum or text its options name.
@(private)
Bound_Want :: enum u8 {Shown,Number,Option,Asset,Color,Name,Entity,Data}
@(private)
tree_bind_field :: proc(instance:^Tree_Instance,scope:Bind_Scope,path:string,want:Bound_Want) -> (bound:Bound,ok:bool) {
    if path=="" {return {},true}
    schema:=instance.schema
    region,offset,field_type:=bind_resolve(instance,scope,path) or_return
    t:=serial.schema_type(schema,field_type)
    bound={offset=offset,size=t.size,region=region,kind=t.kind,bound=true}
    // What a Draw hands its procedure: the bytes of the field, whatever it holds.
    if want==.Data {
        if t.size==0 {return {},false}
        bind_want(instance,region,offset,t.size) or_return
        return bound,true
    }
    #partial switch t.kind {
    case .Bool,.Int,.Uint,.Float,.Enum:
        if t.kind==.Float && t.size!=4 && t.size!=8 {return {},false}
        if want==.Asset || want==.Color || want==.Entity {return {},false}
        if t.kind==.Enum && want!=.Number {bound.choices_of,bound.choices_type=schema,field_type}
        if want==.Name && t.kind!=.Enum {return {},false}
    case .Array:
        elem:=serial.schema_type(schema,t.elem)
        bound.count,bound.elem=t.count,elem.kind
        switch {
        case elem.kind==.Uint && elem.size==1 && (want==.Shown || want==.Name || want==.Option):
            bound.text=true
        case want==.Color && (t.count==3 || t.count==4) && (elem.kind==.Float && elem.size==4 || elem.kind==.Uint && elem.size==1):
        case:
            return {},false
        }
    case .Asset:
        if want!=.Asset {return {},false}
    case .Entity:
        if want!=.Entity {return {},false}
    case:
        return {},false
    }
    bind_want(instance,region,offset,t.size) or_return
    return bound,true
}

// Writes value into the bytes of the text field b, without what it held.
@(private)
bound_write_text :: proc(values:rawptr,b:Bound,value:string) {
    if values==nil || !b.bound || !b.text {return}
    bytes:=mem.byte_slice(rawptr(uintptr(values)+uintptr(b.offset)),int(b.size))
    mem.zero_slice(bytes)
    copy(bytes[:len(bytes)-1],value)
}

// The number an option named value writes into the field b: of an enum, the
// value of the member named so when it has one; else value read as a number.
@(private)
bound_option_number :: proc(b:Bound,value:string) -> f64 {
    for choice in bound_choices(b) {
        if choice.name==value {return f64(choice.value)}
    }
    number,_:=strconv.parse_f64(value)
    return number
}

// The position in options, "Label=Value|...", of the one whose value the field holds; -1: none.
@(private)
tree_option_chosen :: proc(values:rawptr,b:Bound,options:string) -> int {
    rest:=options
    for i:=0;;i+=1 {
        bar:=strings.index_byte(rest,'|')
        entry:=rest if bar<0 else rest[:bar]
        if equal:=strings.index_byte(entry,'=');equal>=0 {
            value:=strings.trim_space(entry[equal+1:])
            matches:=bound_bytes(values,b)==value if b.text else f32(bound_number(values,b))==f32(bound_option_number(b,value))
            if matches {return i}
        }
        if bar<0 {return -1}
        rest=rest[bar+1:]
    }
}

// Writes what a Changed event of a control asks for into the game, for a node
// bound to a field of a storage the host writes this way (Bind_Host.commits).
// False: the event is for the game to answer.
tree_commit_event :: proc(instance:^Tree_Instance,event:Tree_Event,host:^Bind_Host) -> bool {
    if host==nil || host.commits==nil || event.kind!=.Changed || event.node<0 || int(event.node)>=len(instance.bounds) {return false}
    bound:=instance.bounds[event.node].value
    if !bound.bound || bound.region<0 {return false}
    r:=instance.regions[bound.region]
    if r.kind!=.Source || !r.storage || !host.commits(host.user,r.name) {return false}
    data,_:=host.fetch(host.user,r.name,0)
    if data==nil {return false}
    for range in instance.ranges[r.first:][:r.ranges] {
        at:=r.dst+range.dst
        if bound.offset<at || bound.offset+bound.size>at+range.size {continue}
        in_game:=bound
        in_game.offset=range.src+bound.offset-at
        if bound.text {
            text:=event.text
            bound_write_text(data,in_game,base.text_get(text[:]))
        } else {
            bound_write(data,in_game,event.value)
        }
        return true
    }
    return false
}

// The array a Selector or a Dropdown takes its options from: of texts, or
// of enums shown by the names of their values.
@(private)
tree_bind_options :: proc(instance:^Tree_Instance,scope:Bind_Scope,path:string) -> (bound:Bound,ok:bool) {
    if path=="" {return {},true}
    schema:=instance.schema
    region,offset,field_type:=bind_resolve(instance,scope,path) or_return
    t:=serial.schema_type(schema,field_type)
    if t.kind!=.Array {return}
    e:=serial.schema_type(schema,t.elem)
    if e==nil || e.size==0 {return}
    bound={offset=offset,size=t.size,region=region,kind=.Array,bound=true,count=t.count,elem=e.kind,stride=e.size}
    #partial switch e.kind {
    case .Array:
        letter:=serial.schema_type(schema,e.elem)
        if letter==nil || letter.kind!=.Uint || letter.size!=1 {return {},false}
        bound.text=true
    case .Enum:
        if e.size!=1 && e.size!=2 && e.size!=4 && e.size!=8 {return {},false}
        bound.choices_of,bound.choices_type=schema,t.elem
    case:
        return {},false
    }
    bind_want(instance,region,offset,t.size) or_return
    return bound,true
}

// The array a List names, and where the paths of the node it holds start:
// its element, a struct or an entity. A component named alone, outside
// lists, is its table: up to rows elements, one per row, each that struct.
@(private)
tree_bind_items :: proc(instance:^Tree_Instance,scope:Bind_Scope,path:string,rows:u32) -> (items:Node_Items,element:Bind_Scope,ok:bool) {
    schema:=instance.schema
    if scope.kind==.Sources && schema!=nil && strings.index_byte(path,'.')<0 {
        named:=base.name_hash(path)
        table:=Bind_Region{kind=.Rows,frame=-1,parent=-1,name=named}
        found:=true
        if host:=instance.host;host!=nil {
            t,storage,known:=host.source(host.user,named)
            found=known && !storage && host.rows!=nil
            table.type=t
        }
        if at:=bind_region(instance,table) if found else -1;at>=0 {
            type:=instance.regions[at].type
            e:=serial.schema_type(schema,type)
            if e==nil || e.size==0 || e.kind!=.Struct {return}
            array:=bind_region(instance,{kind=.Array,frame=-1,parent=at,type=type,count=rows,stride=e.size})
            if array<0 {return}
            return {count=rows,region=array,bound=true,rows=true},{kind=.Struct,region=array,type=type},true
        }
    }
    region,offset,field_type:=bind_resolve(instance,scope,path) or_return
    t:=serial.schema_type(schema,field_type)
    if t.kind!=.Array {return}
    e:=serial.schema_type(schema,t.elem)
    if e==nil || e.size==0 || e.kind!=.Struct && e.kind!=.Entity {return}
    array:=bind_region(instance,{kind=.Array,frame=region_home(instance,region),parent=region,type=t.elem,src=offset,count=t.count,stride=e.size})
    if array<0 {return}
    if e.kind==.Struct {
        element={kind=.Struct,region=array,offset=0,type=t.elem}
    } else {
        element={kind=.Entity,region=array,offset=0}
        bind_want(instance,array,0,size_of(base.Entity)) or_return
    }
    return {count=t.count,region=array,bound=true},element,true
}

// Packs the ranges the tree reads, by region, and places the regions in
// the frames of the copy; every bound then reads its offset in its frame.
// A range keeps the alignment it has in the game.
@(private)
bind_plan :: proc(instance:^Tree_Instance) -> bool {
    wanted:=instance.ranges[:]
    slice.sort_by(wanted,proc(a,b:Bind_Range) -> bool {return a.region<b.region || a.region==b.region && a.src<b.src})
    merged:=0
    for range in wanted {
        if merged>0 {
            last:=&wanted[merged-1]
            if last.region==range.region && range.src<=last.src+last.size {
                last.size=max(last.size,range.src+range.size-last.src)
                continue
            }
        }
        wanted[merged]=range
        merged+=1
    }
    base.truncate(&instance.ranges,merged)
    // An array that reaches entities changes with them, whatever its parent does.
    for &r in instance.regions {r.pure=r.kind==.Array}
    for r in instance.regions {
        if r.kind!=.Hop {continue}
        for frame:=r.frame;frame>=0;frame=instance.regions[frame].frame {instance.regions[frame].pure=false}
    }
    for &r in instance.regions {r.first,r.ranges=0,0}
    for range,i in instance.ranges {
        r:=&instance.regions[range.region]
        if r.ranges==0 {r.first=u32(i)}
        r.ranges+=1
    }
    // Ranges of a region from at, keeping the alignment they have in the game.
    place :: proc(instance:^Tree_Instance,region:i32,at:u32) -> u32 {
        at:=at
        r:=&instance.regions[region]
        origin:=u32(0) if r.kind==.Array else r.dst
        for &range in instance.ranges[r.first:][:r.ranges] {
            at+=(range.src-at)&7
            range.dst=at-origin
            at+=range.size
        }
        return at
    }
    pack :: proc(instance:^Tree_Instance,frame:i32) -> (size:u32,ok:bool) {
        at:=u32(0)
        if frame>=0 {at=place(instance,frame,0)}
        for i in 0..<len(instance.regions) {
            r:=&instance.regions[i]
            if r.frame!=frame || r.kind==.Array && i32(i)==frame {continue}
            at+=(8-at&7)&7
            r.dst=at
            if r.kind==.Array {
                element:=pack(instance,i32(i)) or_return
                element=(element+7)&~u32(7)
                r=&instance.regions[i]
                r.size=element
                total:=u64(element)*u64(r.count)
                if u64(at)+total>u64(max(u32)) {return}
                at+=u32(total)
            } else {
                at=place(instance,i32(i),at)
                r=&instance.regions[i]
                r.size=at-r.dst
            }
        }
        return at,true
    }
    size:=pack(instance,-1) or_return
    for &r in instance.regions {
        if r.kind==.Hop {r.entity,_=bind_offset(instance,r.parent,r.src,size_of(base.Entity))}
    }
    // Every bound reads from the copy of its frame.
    rebase :: proc(instance:^Tree_Instance,b:^Bound) {
        if b.bound {b.offset,_=bind_offset(instance,b.region,b.offset,b.size)}
    }
    for &node in instance.bounds {
        rebase(instance,&node.text);rebase(instance,&node.value);rebase(instance,&node.visible);rebase(instance,&node.selected)
        rebase(instance,&node.disabled);rebase(instance,&node.image);rebase(instance,&node.tint);rebase(instance,&node.variant);rebase(instance,&node.options)
    }
    for &part in instance.parts {rebase(instance,&part.bound)}
    for &items in instance.items {
        if !items.bound {continue}
        r:=&instance.regions[items.region]
        items.offset,items.stride=r.dst,r.size
    }
    e:[3]runtime.Allocator_Error
    instance.values,e[0]=make([]u8,size,instance.allocator)
    instance.sources,e[1]=make([]rawptr,len(instance.regions),instance.allocator)
    instance.dirty,e[2]=make([]bool,len(instance.ranges),instance.allocator)
    return e=={}
}

// Whether a range a bound reads changed since the tree was built last.
@(private)
bound_dirty :: proc(instance:^Tree_Instance,b:Bound) -> bool {
    if !b.bound || b.region<0 || int(b.region)>=len(instance.regions) {return false}
    r:=&instance.regions[b.region]
    origin:=u32(0) if r.kind==.Array else r.dst
    for range,i in instance.ranges[r.first:][:r.ranges] {
        at:=origin+range.dst
        if b.offset<at+range.size && b.offset+b.size>at && instance.dirty[int(r.first)+i] {return true}
    }
    return false
}

// Every range of a region changed, and those of the regions packed in its elements.
@(private)
region_dirty :: proc(instance:^Tree_Instance,region:i32) {
    r:=&instance.regions[region]
    for i in r.first..<r.first+r.ranges {instance.dirty[i]=true}
    instance.dirty_any=true
    if r.kind!=.Array {return}
    for inner,i in instance.regions {
        if inner.frame==region && i32(i)!=region {region_dirty(instance,i32(i))}
    }
}

// Brings the copy of the instance up to date with the game: of each region,
// the ranges the tree reads are compared and copied where they differ, and
// the ranges that changed are kept for the next build. A source, a table or
// an entity reached outside arrays whose stamp did not move is not looked at,
// nor the arrays in it that reach no entity, unless all is. root: the entity
// whose components the paths name first. changed: a byte of the copy
// changed; missing: the name_hash of a source the paths name that root does
// not have, 0 when it has them all.
tree_values_refresh :: proc(instance:^Tree_Instance,host:^Bind_Host,root:base.Entity,all:=false) -> (changed:bool,missing:u64) {
    if len(instance.regions)==0 || host==nil || host.fetch==nil {return}
    values_copy(instance,host,-1,raw_data(instance.values),nil,root,all,instance.sources,&changed,&missing)
    return
}

@(private)
values_copy :: proc(instance:^Tree_Instance,host:^Bind_Host,frame:i32,dst:[^]u8,element:rawptr,root:base.Entity,all:bool,sources:[]rawptr,changed:^bool,missing:^u64) {
    if frame>=0 {
        sources[frame]=element
        ranges_copy(instance,frame,dst,element,changed)
    }
    for i in 0..<len(instance.regions) {
        r:=&instance.regions[i]
        if r.frame!=frame || r.kind==.Array && i32(i)==frame {continue}
        r.unchanged=false
        switch r.kind {
        case .Source,.Hop:
            entity:=root
            if r.kind==.Hop {entity=(cast(^base.Entity)&dst[r.entity])^}
            data:rawptr
            stamp:u64
            if r.kind==.Source || entity!=0 {data,stamp=host.fetch(host.user,r.name,entity)}
            sources[i]=data
            if data==nil {
                if r.kind==.Source && missing^==0 {missing^=r.name}
                if values_zero(dst[r.dst:][:r.size],changed) {region_dirty(instance,i32(i))}
                r.stamp,r.last=0,0
                continue
            }
            // Outside arrays a stamp that did not move says the bytes did not.
            if frame<0 && !all && stamp!=0 && stamp==r.stamp && entity==r.last {r.unchanged=true;continue}
            if frame<0 {r.stamp,r.last=stamp,entity}
            ranges_copy(instance,i32(i),dst[r.dst:],data,changed)
        case .Rows:
            data:rawptr
            count,stride:int
            stamp:u64
            if host.rows!=nil {data,count,stride,stamp=host.rows(host.user,r.name)}
            if data==nil {count=0}
            sources[i]=data
            rows:=u32(clamp(count,0,int(max(u32))))
            r.unchanged=!all && stamp!=0 && stamp==r.stamp && rows==r.count && u32(stride)==r.stride
            r.stamp,r.count,r.stride=stamp,rows,u32(max(stride,0))
        case .Array:
            parent:=sources[r.parent]
            from:=&instance.regions[r.parent]
            if r.pure && from.unchanged {continue}
            live,stride:=r.count,r.stride
            if from.kind==.Rows {live,stride=min(from.count,r.count),from.stride}
            for k in 0..<r.count {
                at:=dst[r.dst+k*r.size:]
                if parent==nil || k>=live {
                    if values_zero(at[:r.size],changed) {region_dirty(instance,i32(i))}
                    continue
                }
                values_copy(instance,host,i32(i),at,rawptr(uintptr(parent)+uintptr(r.src)+uintptr(k*stride)),root,all,sources,changed,missing)
            }
        }
    }
}

@(private)
ranges_copy :: proc(instance:^Tree_Instance,region:i32,dst:[^]u8,src:rawptr,changed:^bool) {
    r:=&instance.regions[region]
    for range,i in instance.ranges[r.first:][:r.ranges] {
        from:=rawptr(uintptr(src)+uintptr(range.src))
        to:=rawptr(&dst[range.dst])
        if mem.compare_ptrs(to,from,int(range.size))!=0 {
            mem.copy(to,from,int(range.size))
            changed^=true
            instance.dirty[int(r.first)+i]=true
            instance.dirty_any=true
        }
    }
}

// True when bytes held something, now zero.
@(private)
values_zero :: proc(bytes:[]u8,changed:^bool) -> bool {
    for b in bytes {if b!=0 {mem.zero_slice(bytes);changed^=true;return true}}
    return false
}

// Reads a template into parts. Not a template (nothing in braces): false.
// A path the game does not have: ok false.
@(private)
tree_template_parse :: proc(parts:^[dynamic]Template_Part,text:string,instance:^Tree_Instance,scope:Bind_Scope,tree:^Widget_Tree,node:^Node) -> (template,ok:bool) {
    if strings.index_byte(text,'{')<0 && strings.index_byte(text,'}')<0 {return false,true}
    literal_start:=0
    i:=0
    flush :: proc(parts:^[dynamic]Template_Part,text:string) {
        if text!="" {append(parts,Template_Part{literal=text})}
    }
    for i<len(text) {
        c:=text[i]
        if (c=='{' || c=='}') && i+1<len(text) && text[i+1]==c {
            flush(parts,text[literal_start:i+1])
            i+=2
            literal_start=i
            continue
        }
        if c!='{' {i+=1;continue}
        close:=strings.index_byte(text[i:],'}')
        if close<0 {return true,false}
        flush(parts,text[literal_start:i])
        inside:=text[i+1:i+close]
        name,spec:=inside,""
        if colon:=strings.index_byte(inside,':');colon>=0 {name,spec=inside[:colon],inside[colon+1:]}
        // A name of the text: the path of the field of the node it names.
        path:=""
        named:=base.name_hash(strings.trim_space(name))
        for f in node.fields {
            if f.name==named && named!=0 {path=string(tree.strings[f.path.offset:][:f.path.length]);break}
        }
        if path=="" {return true,false}
        part:Template_Part
        part.bound=tree_bind_field(instance,scope,path,.Shown) or_return
        if !part.bound.bound {return true,false}
        // Read after the plan is made, its offset is already in the frame.
        if instance.host==nil {part.bound.offset,_=bind_offset(instance,part.bound.region,part.bound.offset,part.bound.size)}
        if strings.has_prefix(spec,"+") {part.sign=true;spec=spec[1:]}
        kind:=part.bound.kind
        number:=kind==.Int || kind==.Uint || kind==.Float
        switch {
        case spec=="":
        case kind==.Bool && strings.index_byte(spec,'|')>=0:
            part.format,part.spec=.Choice,spec
        case kind==.Enum && strings.index_byte(spec,'=')>=0:
            part.format,part.spec=.Choice,spec
            if !format_names_valid(spec,bound_choices(part.bound)) {return true,false}
        case number && strings.index_byte(spec,'=')>=0:
            part.format,part.spec=.Plural,spec
            if !format_names_valid(spec,nil) {return true,false}
        case number_pattern(&part,spec):
        case spec=="mm:ss":    part.format=.Clock
        case spec=="hh:mm:ss": part.format=.Clock_Hours
        case strings.has_prefix(spec,"%"):
            part.format=.Percent
            if len(spec)>1 {
                digits,digits_ok:=strconv.parse_int(spec[1:])
                if !digits_ok || digits<0 || digits>9 {return true,false}
                part.decimals=u8(digits)
            }
        case:
            digits,digits_ok:=strconv.parse_int(spec)
            if !digits_ok || digits<0 || digits>9 {return true,false}
            part.format,part.decimals=.Decimals,u8(digits)
        }
        append(parts,part)
        i+=close+1
        literal_start=i
    }
    flush(parts,text[literal_start:])
    return true,true
}

@(private)
bound_number :: proc(values:rawptr,b:Bound) -> f64 {
    p:=rawptr(uintptr(values)+uintptr(b.offset))
    #partial switch b.kind {
    case .Bool:return 1 if (cast(^u8)p)^!=0 else 0
    case .Float:return f64((cast(^f32)p)^) if b.size==4 else (cast(^f64)p)^
    case .Int,.Enum:
        switch b.size {
        case 1:return f64((cast(^i8)p)^)
        case 2:return f64((cast(^i16)p)^)
        case 4:return f64((cast(^i32)p)^)
        case 8:return f64((cast(^i64)p)^)
        }
    case .Uint:
        switch b.size {
        case 1:return f64((cast(^u8)p)^)
        case 2:return f64((cast(^u16)p)^)
        case 4:return f64((cast(^u32)p)^)
        case 8:return f64((cast(^u64)p)^)
        }
    }
    return 0
}

// Writes a number into the field b, as its type holds it.
@(private)
bound_write :: proc(values:rawptr,b:Bound,value:f64) {
    if values==nil || !b.bound {return}
    p:=rawptr(uintptr(values)+uintptr(b.offset))
    #partial switch b.kind {
    case .Bool:(cast(^bool)p)^=value!=0
    case .Float:if b.size==4 {(cast(^f32)p)^=f32(value)} else {(cast(^f64)p)^=value}
    case .Int,.Enum:
        v:=i64(math.round(value))
        switch b.size {
        case 1:(cast(^i8)p)^=i8(v)
        case 2:(cast(^i16)p)^=i16(v)
        case 4:(cast(^i32)p)^=i32(v)
        case 8:(cast(^i64)p)^=v
        }
    case .Uint:
        v:=u64(max(math.round(value),0))
        switch b.size {
        case 1:(cast(^u8)p)^=u8(v)
        case 2:(cast(^u16)p)^=u16(v)
        case 4:(cast(^u32)p)^=u32(v)
        case 8:(cast(^u64)p)^=v
        }
    }
}

@(private)
bound_bytes :: proc(values:rawptr,b:Bound) -> string {
    bytes:=mem.byte_slice(rawptr(uintptr(values)+uintptr(b.offset)),int(b.size))
    length:=0
    for length<len(bytes) && bytes[length]!=0 {length+=1}
    return string(bytes[:length])
}

// The name of the value of an enum; empty for one without a name.
@(private)
bound_choice :: proc(values:rawptr,b:Bound) -> string {
    value:=i64(bound_number(values,b))
    for choice in bound_choices(b) {if choice.value==value {return choice.name}}
    return ""
}

@(private)
bound_text :: proc(ctx:^Context,values:rawptr,b:Bound) -> string {
    if b.text {return bound_bytes(values,b)}
    if b.kind==.Bool {return "On" if bound_number(values,b)!=0 else "Off"}
    if b.kind==.Enum {if name:=bound_choice(values,b);name!="" {return name}}
    return number_text(ctx,bound_number(values,b),2 if b.kind==.Float else 0)
}

// A part of a template, written into buffer in a language (name_hash of its code).
@(private)
template_part_write :: proc(buffer:^strings.Builder,values:rawptr,part:^Template_Part,language:u64) {
    if part.literal!="" {strings.write_string(buffer,part.literal);return}
    b:=part.bound
    switch part.format {
    case .Choice:
        if b.kind==.Enum {
            strings.write_string(buffer,option_shown(part.spec,bound_choice(values,b)))
            return
        }
        bar:=strings.index_byte(part.spec,'|')
        if bound_number(values,b)!=0 {strings.write_string(buffer,part.spec[:bar])} else {strings.write_string(buffer,part.spec[bar+1:])}
        return
    case .Plural:
        value:=bound_number(values,b)
        locale:=number_locale(language)
        text:=format_plural(part.spec,plural_of(locale,value))
        for c in transmute([]u8)text {
            if c=='#' {number_write(buffer,value,1,0,2 if b.kind==.Float else 0,true,locale)} else {strings.write_byte(buffer,c)}
        }
        return
    case .Pattern:
        value:=bound_number(values,b)
        if part.sign && value>=0 {strings.write_byte(buffer,'+')}
        number_write(buffer,value*100 if part.percent else value,int(part.places[0]),int(part.places[1]),int(part.decimals),part.grouped,number_locale(language))
        if part.percent {strings.write_byte(buffer,'%')}
        return
    case .Default,.Decimals,.Percent,.Clock,.Clock_Hours:
    }
    if b.text || b.kind==.Bool || b.kind==.Enum && len(bound_choices(b))>0 && part.format==.Default {
        text:string
        switch {
        case b.text:        text=bound_bytes(values,b)
        case b.kind==.Bool: text="On" if bound_number(values,b)!=0 else "Off"
        case:               text=bound_choice(values,b)
        }
        strings.write_string(buffer,text)
        return
    }
    value:=bound_number(values,b)
    if part.sign && value>=0 {strings.write_byte(buffer,'+')}
    digits:[64]u8
    switch part.format {
    case .Default:
        strings.write_string(buffer,number_format(digits[:],value,2 if b.kind==.Float else 0))
    case .Decimals:
        strings.write_string(buffer,strconv.write_float(digits[:],value,'f',int(part.decimals),64)[1 if value>=0 else 0:])
    case .Percent:
        strings.write_string(buffer,strconv.write_float(digits[:],value*100,'f',int(part.decimals),64)[1 if value>=0 else 0:])
        strings.write_byte(buffer,'%')
    case .Pattern,.Choice,.Plural:
    case .Clock,.Clock_Hours:
        if value<0 {strings.write_byte(buffer,'-')}
        seconds:=int(math.floor(abs(value)))
        two :: proc(buffer:^strings.Builder,n:int) {
            strings.write_byte(buffer,u8('0'+n/10%10));strings.write_byte(buffer,u8('0'+n%10))
        }
        if part.format==.Clock_Hours {
            two(buffer,seconds/3600)
            strings.write_byte(buffer,':')
            two(buffer,seconds/60%60)
        } else {
            minutes:=seconds/60
            if minutes>=100 {strings.write_int(buffer,minutes)} else {two(buffer,minutes)}
        }
        strings.write_byte(buffer,':')
        two(buffer,seconds%60)
    }
}

// A template with the values of now, in the text of the frame.
@(private)
template_text :: proc(ctx:^Context,values:rawptr,parts:[]Template_Part) -> string {
    buffer:=text_reserve(ctx,TREE_TEXT_KEPT*4)
    if buffer==nil {return ""}
    b:=strings.builder_from_bytes(buffer)
    for &part in parts {template_part_write(&b,values,&part,ctx.game.language)}
    return text_commit(ctx,strings.to_string(b))
}

// A color field as a display color: floats are linear.
@(private)
bound_color :: proc(values:rawptr,b:Bound) -> Color {
    p:=uintptr(values)+uintptr(b.offset)
    color:=Color{0,0,0,255}
    for i in 0..<min(int(b.count),4) {
        if b.elem==.Float {
            v:=(cast(^f32)rawptr(p+uintptr(i*4)))^
            if i<3 {v=mm.linear_to_srgb(clamp(v,0,1))}
            color[i]=u8(clamp(v,0,1)*255+0.5)
        } else {color[i]=(cast(^u8)rawptr(p+uintptr(i)))^}
    }
    return color
}

@(private)
bound_asset :: proc(values:rawptr,b:Bound) -> base.Asset_Id {
    return (cast(^base.Asset_Id)rawptr(uintptr(values)+uintptr(b.offset)))^
}
@(private)
bound_entity :: proc(values:rawptr,b:Bound) -> base.Entity {
    return (cast(^base.Entity)rawptr(uintptr(values)+uintptr(b.offset)))^
}

// The name of the variant a binding chooses: a text, or the name of an enum value.
@(private)
bound_variant :: proc(values:rawptr,b:Bound) -> u64 {
    return style_variant(bound_name(values,b))
}

// A text, or the name of an enum value.
@(private)
bound_name :: proc(values:rawptr,b:Bound) -> string {
    return bound_bytes(values,b) if b.text else bound_choice(values,b)
}

// ---------------------------------------------------------------- formats of a language

// How a language writes numbers and chooses its plurals, by its code (that of
// a translation, as engine/gui names the languages of a game). A language
// without a row writes as the first one. Groups of French and Russian take a
// no-break space, which the font has, in place of their narrow one.
@(private)
Number_Locale :: struct {
    code:string,
    group,point:string,
    least_group:u8, // digits a number has before it is grouped, past the first group (CLDR minimumGroupingDigits)
    plural:Plural_Rule,
    millions:bool,  // a whole number of millions is many
}
@(private)
Plural_Rule :: enum u8 {
    One,         // one: 1, whole
    Zero_Or_One, // one: up to 1
    Slavic,      // one: 1, 21; few: 2 to 4, 22; many: 0, 5 to 20; other: fractions
}
@(private)
NUMBER_LOCALES :: [?]Number_Locale{
    {"en",",",".",1,.One,false},
    {"ru","\u00a0",",",1,.Slavic,false},
    {"es",".",",",2,.One,true},
    {"es-419",",",".",1,.One,true},
    {"de",".",",",1,.One,false},
    {"fr","\u00a0",",",1,.Zero_Or_One,true},
    {"pt-BR",".",",",1,.Zero_Or_One,true},
    {"it",".",",",1,.One,true},
}
@(private)
number_locale :: proc(language:u64) -> Number_Locale {
    locales:=NUMBER_LOCALES
    for locale in locales {if base.name_hash(locale.code)==language {return locale}}
    return locales[0]
}

// The categories of plurals (CLDR).
@(private)
Plural :: enum u8 {Zero,One,Two,Few,Many,Other}
@(private)
PLURAL_NAMES :: [Plural]string{.Zero="zero",.One="one",.Two="two",.Few="few",.Many="many",.Other="other"}

@(private)
plural_of :: proc(locale:Number_Locale,value:f64) -> Plural {
    n:=abs(value)
    i:=math.floor(n)
    whole:=n==i
    switch locale.plural {
    case .One:if whole && i==1 {return .One}
    case .Zero_Or_One:if i<=1 {return .One}
    case .Slavic:
        if !whole {return .Other}
        k:=u64(i)
        if k%10==1 && k%100!=11 {return .One}
        if k%10>=2 && k%10<=4 && (k%100<12 || k%100>14) {return .Few}
        return .Many
    }
    if locale.millions && whole && i!=0 && math.mod(i,1e6)==0 {return .Many}
    return .Other
}

// The text a plural format gives a category: its own, or that of other, or
// the first one.
@(private)
format_plural :: proc(spec:string,category:Plural) -> string {
    names:=PLURAL_NAMES
    found,other,first:string
    rest:=spec
    for index:=0;rest!="";index+=1 {
        bar:=strings.index_byte(rest,'|')
        entry:=rest if bar<0 else rest[:bar]
        if equal:=strings.index_byte(entry,'=');equal>=0 {
            name,text:=entry[:equal],entry[equal+1:]
            if index==0 {first=text}
            if name==names[category] {found=text}
            if name=="other" {other=text}
        }
        if bar<0 {break}
        rest=rest[bar+1:]
    }
    return found if found!="" else other if other!="" else first
}

// Whether every "name=" of a format names a value of the enum, or with no
// choices a category of plurals.
@(private)
format_names_valid :: proc(spec:string,choices:[]serial.Choice) -> bool {
    names:=PLURAL_NAMES
    rest:=spec
    for rest!="" {
        bar:=strings.index_byte(rest,'|')
        entry:=rest if bar<0 else rest[:bar]
        equal:=strings.index_byte(entry,'=')
        if equal<0 {return false}
        name:=entry[:equal]
        known:=false
        if choices!=nil {
            for choice in choices {if choice.name==name {known=true;break}}
        } else {
            for plural in names {if plural==name {known=true;break}}
        }
        if !known {return false}
        if bar<0 {break}
        rest=rest[bar+1:]
    }
    return true
}

// Reads a pattern of number such as #,##0.00 or 0.0%: zeros are digits
// always shown, # digits shown when they are not zero, a comma before the
// point groups thousands. False when spec is not one.
@(private)
number_pattern :: proc(part:^Template_Part,spec:string) -> bool {
    body:=spec
    percent:=strings.has_suffix(body,"%")
    if percent {body=body[:len(body)-1]}
    if body=="" || strings.index_any(body,"#,.")<0 {return false}
    point:=strings.index_byte(body,'.')
    whole,fraction:=body,""
    if point>=0 {whole,fraction=body[:point],body[point+1:]}
    least_whole:=0
    for c in transmute([]u8)whole {
        switch c {
        case '0':least_whole+=1
        case '#',',':
        case:return false
        }
    }
    least,most:=0,0
    for c in transmute([]u8)fraction {
        switch c {
        case '0':
            if most>least {return false}
            least+=1;most+=1
        case '#':most+=1
        case:return false
        }
    }
    if most>9 || least_whole>32 {return false}
    part.format,part.percent,part.grouped=.Pattern,percent,strings.index_byte(whole,',')>=0
    part.places,part.decimals={u8(least_whole),u8(least)},u8(most)
    return true
}

// A number as a language writes it: at least digits before the point, from
// least to most digits after it, and its thousands grouped.
@(private)
number_write :: proc(buffer:^strings.Builder,value:f64,digits,least,most:int,grouped:bool,locale:Number_Locale) {
    if math.is_nan(value) || math.is_inf(value) {
        scratch:[8]u8
        strings.write_string(buffer,number_format(scratch[:],value))
        return
    }
    scratch:[96]u8
    text:=strconv.write_float(scratch[:],abs(value),'f',clamp(most,0,9),64)
    if len(text)>0 && text[0]=='+' {text=text[1:]}
    whole,fraction:=text,""
    if point:=strings.index_byte(text,'.');point>=0 {whole,fraction=text[:point],text[point+1:]}
    for len(fraction)>least && fraction[len(fraction)-1]=='0' {fraction=fraction[:len(fraction)-1]}
    if value<0 && strings.trim_left(whole,"0")!="" || value<0 && strings.trim_right(fraction,"0")!="" {strings.write_byte(buffer,'-')}
    if whole=="0" && digits==0 {whole=""}
    count:=max(len(whole),digits)
    group:=grouped && count>=3+int(max(locale.least_group,1))
    for i in 0..<count {
        if group && i>0 && (count-i)%3==0 {strings.write_string(buffer,locale.group)}
        pad:=count-len(whole)
        strings.write_byte(buffer,'0' if i<pad else whole[i-pad])
    }
    if fraction!="" {
        strings.write_string(buffer,locale.point)
        strings.write_string(buffer,fraction)
    }
}
