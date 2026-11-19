package store

import "base:intrinsics"
import "core:log"
import "core:mem"
import "core:testing"
import "mirai:std/base"

// Byte offset of a seeded stream, computed at any offset so a long stream is
// generated where it is read, never held.
@(private="file")
random_fill :: proc "contextless" (seed,offset:u64,buffer:[]u8) {
    at:=offset
    i:=0
    for i<len(buffer) {
        if at&7==0 && len(buffer)-i>=8 {
            words:=(len(buffer)-i)/8
            #no_bounds_check for k in 0..<words {
                word:=base.hash_u64(seed~((at>>3)+u64(k))*0x9e3779b97f4a7c15)
                intrinsics.unaligned_store((^u64)(&buffer[i+8*k]),word)
            }
            i+=8*words
            at+=8*u64(words)
            continue
        }
        word:=base.hash_u64(seed~(at>>3)*0x9e3779b97f4a7c15)
        shift:=at&7
        for shift<8 && i<len(buffer) {
            buffer[i]=u8(word>>(8*shift))
            shift+=1
            at+=1
            i+=1
        }
    }
}

// Text-like records: words of a small vocabulary and numbers, line by line.
@(private="file")
structured_bytes :: proc(size:int,seed:u64) -> []u8 {
    words:=[?]string{"mesh","texture","level","stream","entity","cell","alpha","beta","light","shadow","=",",","0","1"}
    data:=make([]u8,size,context.temp_allocator)
    h:=base.Hostile{state=seed}
    at:=0
    for at<size {
        r:=base.hostile_next(&h)
        piece:string
        number:[8]u8
        if r%5==0 {
            for &d,i in number {d='0'+u8((r>>(4*uint(i)))%10)}
            piece=string(number[:])
        } else {
            piece=words[r%len(words)]
        }
        at+=copy(data[at:],piece)
        if at<size {data[at]=r%11==0?'\n':' ';at+=1}
    }
    return data
}

@(private="file")
whole_cuts :: proc(data:[]u8) -> [dynamic]int {
    cuts:=make([dynamic]int,context.temp_allocator)
    rest:=data
    for len(rest)>0 {
        n:=chunk_cut(rest)
        append(&cuts,n)
        rest=rest[n:]
    }
    return cuts
}

@(test)
chunks_are_the_same_streamed_in_any_split_and_whole :: proc(t:^testing.T) {
    random:=make([]u8,3<<20+77,context.temp_allocator)
    random_fill(7,0,random)
    zeros:=make([]u8,CHUNK_MAX*2+5,context.temp_allocator)
    cases:=[?]struct{name:string,data:[]u8,most:int}{
        {"empty",nil,1},
        {"one byte",random[:1],1},
        {"at the minimum",random[:CHUNK_MIN],CHUNK_MIN},
        {"one below the maximum",random[:CHUNK_MAX-1],4096},
        {"one above the maximum",random[:CHUNK_MAX+1],4096},
        {"random",random,3*CHUNK_MAX},
        {"random, a byte at a time",random[:CHUNK_MAX*3+1],1},
        {"structured",structured_bytes(2<<20,3),3*CHUNK_MAX},
        {"zeros",zeros,CHUNK_MAX+3},
    }
    c:Chunker
    if !testing.expect_value(t,chunker_init(&c),Error.None) {return}
    defer chunker_destroy(&c)
    h:=base.Hostile{state=11}
    for k in cases {
        want:=whole_cuts(k.data)
        for split in 0..<4 {
            chunker_reset(&c)
            got:=make([dynamic]int,context.temp_allocator)
            rest:=k.data
            for {
                n:=split==0?len(rest):min(len(rest),1+base.hostile_int(&h,k.most))
                if n>0 {
                    testing.expect_value(t,chunker_feed(&c,rest[:n]),Error.None)
                    rest=rest[n:]
                }
                if len(rest)==0 {chunker_end(&c)}
                for chunk in chunker_next(&c) {append(&got,len(chunk))}
                if len(rest)==0 {break}
            }
            testing.expectf(t,len(got)==len(want),"%s, split %d: %d chunks, whole %d",k.name,split,len(got),len(want))
            for i in 0..<min(len(got),len(want)) {
                if got[i]!=want[i] {testing.expectf(t,false,"%s, split %d: chunk %d is %d, whole %d",k.name,split,i,got[i],want[i]);break}
            }
        }
    }
}

@(test)
chunk_sizes_stay_within_bounds_and_average_near_the_target :: proc(t:^testing.T) {
    random:=make([]u8,64<<20,context.temp_allocator)
    random_fill(5,0,random)
    cases:=[?]struct{name:string,data:[]u8}{{"random",random},{"structured",structured_bytes(64<<20,9)}}
    for k in cases {
        cuts:=whole_cuts(k.data)
        for n,i in cuts {
            if i<len(cuts)-1 && (n<CHUNK_MIN || n>CHUNK_MAX) {testing.expectf(t,false,"%s: chunk %d of %d bytes",k.name,i,n);break}
        }
        mean:=f64(len(k.data))/f64(len(cuts))
        log.infof("%s: %d chunks, mean %.0f bytes",k.name,len(cuts),mean)
        testing.expectf(t,mean>=0.9*CHUNK_AVG && mean<=1.5*CHUNK_AVG,"%s: mean %.0f bytes",k.name,mean)
    }
}

@(private="file")
Collect :: struct {
    seen:map[Hash]Chunk_Kind,
    nodes:map[Hash][]u8,  // the bytes of each node, kept when keep is set
    levels:map[Hash]int,
    keep:bool,
    data_chunks:int,
}

@(private="file")
collect_sink :: proc(c:^Collect) -> Sink {
    return {data=c,procedure=proc(data:rawptr,kind:Chunk_Kind,address:Hash,bytes:[]u8) -> Error {
        c:=(^Collect)(data)
        c.seen[address]=kind
        if kind==.Data {
            c.data_chunks+=1
            return .None
        }
        c.levels[address]=int(bytes[5])
        if c.keep && address not_in c.nodes {
            copy_of:=make([]u8,len(bytes),context.temp_allocator)
            copy(copy_of,bytes)
            c.nodes[address]=copy_of
        }
        return .None
    }}
}

@(private="file")
collect_source :: proc(c:^Collect) -> Node_Source {
    return {data=c,procedure=proc(data:rawptr,address:Hash) -> ([]u8,Error) {
        bytes,ok:=(^Collect)(data).nodes[address]
        return bytes,ok?.None:.Missing
    }}
}

@(private="file")
Edit :: enum {None,Insert,Delete,Change}

// The seeded stream of size bytes with one edit at offset at, through an
// Object_Writer a block at a time.
@(private="file")
write_edited :: proc(w:^Object_Writer,seed:u64,size:u64,edit:Edit,at:u64,buffer:[]u8) -> (root:Hash,total:u64,error:Error) {
    length:=size
    switch edit {
    case .Insert: length+=1
    case .Delete: length-=1
    case .None,.Change:
    }
    for p:=u64(0);p<length; {
        block:=buffer[:min(u64(len(buffer)),length-p)]
        end:=p+u64(len(block))
        switch {
        case edit==.Insert && at>=p && at<end:
            random_fill(seed,p,block[:at-p])
            block[at-p]=0xa5
            random_fill(seed,at,block[at-p+1:])
        case edit==.Insert && at<p: random_fill(seed,p-1,block)
        case edit==.Delete && at<end:
            if at>=p {
                random_fill(seed,p,block[:at-p])
                random_fill(seed,at+1,block[at-p:])
            } else {
                random_fill(seed,p+1,block)
            }
        case:
            random_fill(seed,p,block)
            if edit==.Change && at>=p && at<end {block[at-p]~=0xff}
        }
        object_write(w,block) or_return
        p=end
    }
    return object_finish(w)
}

@(test)
an_edit_changes_two_data_chunks_and_one_node_per_level :: proc(t:^testing.T) {
    SIZE :: 200_000_000
    buffer:=make([]u8,1<<20,context.temp_allocator)
    base_collect:=Collect{seen=make(map[Hash]Chunk_Kind,context.temp_allocator),levels=make(map[Hash]int,context.temp_allocator)}
    w:Object_Writer
    if !testing.expect_value(t,object_writer_init(&w,collect_sink(&base_collect)),Error.None) {return}
    defer object_writer_destroy(&w)
    base_root,base_total,error:=write_edited(&w,21,SIZE,.None,0,buffer)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,base_total,u64(SIZE))
    base_depth:=base_collect.levels[base_root]
    cases:=[?]struct{edit:Edit,at:u64}{{.Insert,SIZE/2+12345},{.Delete,SIZE/3},{.Change,SIZE-1000},{.Insert,0},{.Change,77_777_777}}
    for k in cases {
        edited:=Collect{seen=make(map[Hash]Chunk_Kind,context.temp_allocator),levels=make(map[Hash]int,context.temp_allocator)}
        w.tree.sink=collect_sink(&edited)
        root,_,e:=write_edited(&w,21,SIZE,k.edit,k.at,buffer)
        testing.expect_value(t,e,Error.None)
        data_changed:=0
        nodes_changed:[NODE_LEVEL_MAX+1]int
        for address,kind in edited.seen {
            if address in base_collect.seen {continue}
            if kind==.Data {data_changed+=1} else {nodes_changed[edited.levels[address]]+=1}
        }
        depth:=edited.levels[root]
        log.infof("%v at %d: %d of %d data chunks and nodes per level %v differ; root level %d",k.edit,k.at,data_changed,edited.data_chunks,nodes_changed[:depth+1],depth)
        testing.expectf(t,depth==base_depth && depth>=1,"%v: root level %d, before %d",k.edit,depth,base_depth)
        testing.expectf(t,data_changed>=1 && data_changed<=2,"%v: %d data chunks differ",k.edit,data_changed)
        for n,level in nodes_changed[:depth+1] {
            testing.expectf(t,n==1,"%v: %d nodes of level %d differ",k.edit,n,level)
        }
    }
}

@(test)
a_long_stream_is_built_within_bounded_memory :: proc(t:^testing.T) {
    SIZE :: u64(10_000_000_000)
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    allocator:=mem.tracking_allocator(&track)
    Count :: struct {data,nodes:int}
    count:Count
    sink:=Sink{data=&count,procedure=proc(data:rawptr,kind:Chunk_Kind,address:Hash,bytes:[]u8) -> Error {
        c:=(^Count)(data)
        if kind==.Data {c.data+=1} else {c.nodes+=1}
        return .None
    }}
    buffer,_:=make([]u8,4<<20,allocator)
    defer delete(buffer,allocator)
    w:Object_Writer
    if !testing.expect_value(t,object_writer_init(&w,sink,allocator),Error.None) {return}
    defer object_writer_destroy(&w)
    for p:=u64(0);p<SIZE; {
        block:=buffer[:min(u64(len(buffer)),SIZE-p)]
        random_fill(33,p,block)
        if !testing.expect_value(t,object_write(&w,block),Error.None) {return}
        p+=u64(len(block))
    }
    _,total,error:=object_finish(&w)
    testing.expect_value(t,error,Error.None)
    testing.expect_value(t,total,SIZE)
    log.infof("10 GB: %d data chunks, %d nodes, peak %d bytes allocated",count.data,count.nodes,track.peak_memory_allocated)
    testing.expectf(t,track.peak_memory_allocated<=64<<20,"peak %d bytes",track.peak_memory_allocated)
}

@(test)
native_cuts_merge_and_split :: proc(t:^testing.T) {
    M :: CHUNK_MAX
    cases:=[?]struct{size:int,cuts:[]int,want:[]int}{
        {0,nil,nil},
        {10,nil,{10}},
        {M,{100,200},{M}},
        {M+1,{100},{M+1-(M+1-100),M+1-100}},
        {3*M+5,nil,{M,M,M,5}},
        {M/2*3,{M/2,M},{M,M/2}},
        {2*M,{10,10+M+7},{10,M,7+(2*M-10-M-7)}},
        {M+10,{5,M+5},{5,M,5}},
        {4*M,{M,2*M,3*M},{M,M,M,M}},
        {M/4*5,{M/4,M/2,M/4*3,M},{M,M/4}},
    }
    data:=make([]u8,4*M,context.temp_allocator)
    for k,i in cases {
        n,error:=native_cuts(data[:k.size],k.cuts)
        if !testing.expect_value(t,error,Error.None) {continue}
        got:=make([dynamic]int,context.temp_allocator)
        at:=0
        for chunk in native_next(&n) {
            testing.expectf(t,raw_data(chunk)==raw_data(data[at:]),"case %d: chunks follow each other",i)
            at+=len(chunk)
            append(&got,len(chunk))
        }
        testing.expectf(t,at==k.size && len(got)==len(k.want),"case %d: %v, want %v",i,got[:],k.want)
        for g,j in got {
            if j<len(k.want) && g!=k.want[j] {testing.expectf(t,false,"case %d: %v, want %v",i,got[:],k.want);break}
        }
    }
    bad:=[?][]int{{0},{10},{11},{5,5},{6,5},{-1}}
    for cuts in bad {
        _,error:=native_cuts(data[:10],cuts)
        testing.expectf(t,error==.Invalid_Argument,"cuts %v: %v",cuts,error)
    }
}

@(private="file")
test_entries :: proc(count:int,level:int,seed:u64) -> []Entry {
    entries:=make([]Entry,count,context.temp_allocator)
    h:=base.Hostile{state=seed}
    for &e in entries {
        for &b in e.address {b=u8(base.hostile_next(&h))}
        e.size=level==0?u64(1+base.hostile_int(&h,CHUNK_MAX)):base.hostile_next(&h)>>20
    }
    return entries
}

// Fills the offset of each group of a node of level 0 from its entries.
@(private="file")
group_offsets :: proc(entries:[]Entry,groups:[]Group) -> []Group {
    for &g in groups {
        g.offset=0
        for e in entries[:g.first] {g.offset+=e.size}
    }
    return groups
}

@(test)
nodes_round_trip :: proc(t:^testing.T) {
    meta:=[?]u8{1,2,3,4,5}
    two:=test_entries(300,0,3)
    high:=test_entries(17,3,4)
    high_total:u64
    for e in high {high_total+=e.size}
    cases:=[?]struct{level:int,entries:[]Entry,groups:[]Group,meta:[]u8}{
        {0,nil,{{first=0,count=0}},nil},
        {0,test_entries(1,0,1),{{first=0,count=1}},nil},
        {0,test_entries(NODE_ENTRIES_MAX,0,2),nil,nil},
        {0,two,group_offsets(two,{{tag=7,index=1,first=0,count=100,align=4},{tag=7,index=2,first=100,count=0},{tag=7,index=3,first=100,count=200}}),meta[:]},
        {3,high,{{first=0,count=2_000_000_000},{first=2_000_000_000,count=2_000_000_000,offset=high_total/2}},meta[:]},
    }
    buffer:=make([]u8,CHUNK_MAX,context.temp_allocator)
    for k,i in cases {
        bytes,error:=node_encode(buffer,k.level,k.entries,k.groups,k.meta)
        if !testing.expectf(t,error==.None,"case %d: %v",i,error) {continue}
        n,parse_error:=node_parse(bytes)
        if !testing.expectf(t,parse_error==.None,"case %d: %v",i,parse_error) {continue}
        total:u64
        for e in k.entries {total+=e.size}
        testing.expectf(t,n.level==k.level && n.total==total && len(n.entries)==len(k.entries) && len(n.groups)==len(k.groups) && string(n.meta)==string(k.meta),"case %d: head",i)
        for e,j in n.entries {
            if e!=k.entries[j] {testing.expectf(t,false,"case %d: entry %d",i,j);break}
        }
        for g,j in n.groups {testing.expectf(t,g==k.groups[j],"case %d: group %d",i,j)}
    }
    too_many:=test_entries(NODE_ENTRIES_MAX,0,5)
    _,error:=node_encode(buffer,0,too_many,{{count=u32(NODE_ENTRIES_MAX)}},nil)
    testing.expect_value(t,error,Error.Invalid_Argument)
}

@(test)
hostile_nodes_return_errors :: proc(t:^testing.T) {
    buffer:=make([]u8,CHUNK_MAX,context.temp_allocator)
    nine:=test_entries(9,0,8)
    valid,valid_error:=node_encode(buffer,0,nine,group_offsets(nine,{{first=0,count=4},{first=4,count=5}}),{9,9})
    testing.expect_value(t,valid_error,Error.None)
    high_buffer:=make([]u8,CHUNK_MAX,context.temp_allocator)
    high:=test_entries(3,1,12)
    for &e in high {e.size=100*CHUNK_MAX}
    high_valid,high_error:=node_encode(high_buffer,1,high,{{first=0,count=200},{first=200,count=250,offset=100*CHUNK_MAX}})
    testing.expect_value(t,high_error,Error.None)
    h:=base.Hostile{state=77}
    random:=make([]u8,CHUNK_MAX+8,context.temp_allocator)
    for _ in 0..<2000 {
        bytes:=random[:base.hostile_int(&h,len(random))]
        for &b in bytes {b=u8(base.hostile_next(&h))}
        if len(bytes)>=8 && base.hostile_int(&h,2)==0 {
            (^Node)(raw_data(bytes)).magic=NODE_MAGIC
            bytes[4]=NODE_VERSION
        }
        _,error:=node_parse(bytes)
        testing.expectf(t,error==.Corrupt,"random %d bytes: %v",len(bytes),error)
    }
    for n in 0..<len(valid) {
        _,error:=node_parse(valid[:n])
        testing.expectf(t,error==.Corrupt,"truncated at %d: %v",n,error)
    }
    mutated:=make([]u8,len(valid)+40,context.temp_allocator)
    entry_size :: proc(bytes:[]u8,i:int) -> ^u64 {return (^u64)(raw_data(bytes[size_of(Node)+i*size_of(Entry)+32:]))}
    group :: proc(bytes:[]u8,i:int) -> ^Group {return (^Group)(raw_data(bytes[size_of(Node)+9*size_of(Entry)+i*size_of(Group):]))}
    cases:=[?]struct{name:string,change:proc(bytes:[]u8)}{
        {"a count one above",proc(b:[]u8) {(^Node)(raw_data(b)).count+=1}},
        {"a count one below",proc(b:[]u8) {(^Node)(raw_data(b)).count-=1}},
        {"a count beyond the maximum",proc(b:[]u8) {(^Node)(raw_data(b)).count=max(u32)}},
        {"more groups",proc(b:[]u8) {(^Node)(raw_data(b)).groups+=1}},
        {"more meta",proc(b:[]u8) {(^Node)(raw_data(b)).meta=max(u16)}},
        {"a level beyond the bound",proc(b:[]u8) {(^Node)(raw_data(b)).level=NODE_LEVEL_MAX+1}},
        {"a reserved byte",proc(b:[]u8) {(^Node)(raw_data(b)).reserved=1}},
        {"another version",proc(b:[]u8) {(^Node)(raw_data(b)).version=NODE_VERSION+1}},
        {"entries that sum to another total",proc(b:[]u8) {(^Node)(raw_data(b)).total+=1}},
        {"a leaf above the chunk maximum",proc(b:[]u8) {entry_size(b,0)^=CHUNK_MAX+1}},
        {"an empty leaf",proc(b:[]u8) {entry_size(b,3)^=0}},
        {"sizes that overflow",proc(b:[]u8) {
            (^Node)(raw_data(b)).level=1
            entry_size(b,0)^=max(u64)
            entry_size(b,1)^=2
        }},
        {"overlapping groups",proc(b:[]u8) {group(b,1).first=3}},
        {"a gap between groups",proc(b:[]u8) {group(b,1).first=5;group(b,1).count=4}},
        {"leaves after the last group",proc(b:[]u8) {group(b,1).count=4}},
        {"a group offset one above",proc(b:[]u8) {group(b,1).offset+=1}},
        {"a group offset one below",proc(b:[]u8) {group(b,1).offset-=1}},
        {"a first group past byte 0",proc(b:[]u8) {group(b,0).offset=1}},
        {"a group beyond the leaves",proc(b:[]u8) {group(b,1).count=6}},
        {"a group past u32",proc(b:[]u8) {
            group(b,1).first=max(u32)
            group(b,1).count=1
        }},
        {"a group reserved byte",proc(b:[]u8) {group(b,0).reserved[1]=1}},
    }
    for k in cases {
        copy(mutated,valid)
        bytes:=mutated[:len(valid)]
        k.change(bytes)
        _,error:=node_parse(bytes)
        testing.expectf(t,error==.Corrupt,"%s: %v",k.name,error)
    }
    _,error:=node_parse(valid)
    testing.expect_value(t,error,Error.None)
    high_group :: proc(bytes:[]u8,i:int) -> ^Group {return (^Group)(raw_data(bytes[size_of(Node)+3*size_of(Entry)+i*size_of(Group):]))}
    high_cases:=[?]struct{name:string,change:proc(bytes:[]u8)}{
        {"a group with fewer bytes than leaves",proc(b:[]u8) {high_group(b,1).offset=199}},
        {"a group with more bytes than its leaves hold",proc(b:[]u8) {high_group(b,1).offset=200*CHUNK_MAX+1}},
        {"a group offset beyond the total",proc(b:[]u8) {high_group(b,1).offset=300*CHUNK_MAX+1}},
        {"a last group with more bytes than its leaves hold",proc(b:[]u8) {high_group(b,1).count=1}},
        {"offsets that go back",proc(b:[]u8) {high_group(b,1).offset=0;high_group(b,1).first=200}},
    }
    high_mutated:=make([]u8,len(high_valid),context.temp_allocator)
    for k in high_cases {
        copy(high_mutated,high_valid)
        k.change(high_mutated)
        _,high_parse:=node_parse(high_mutated)
        testing.expectf(t,high_parse==.Corrupt,"%s: %v",k.name,high_parse)
    }

    // A tree whose child is not one level below, or whose child holds other
    // bytes than its entry says, fails to resolve.
    nodes:=Collect{nodes=make(map[Hash][]u8,context.temp_allocator),levels=make(map[Hash]int,context.temp_allocator),seen=make(map[Hash]Chunk_Kind,context.temp_allocator)}
    leaf:=make([]u8,CHUNK_MAX,context.temp_allocator)
    leaf_bytes,_:=node_encode(leaf,0,test_entries(3,0,9))
    leaf_view,_:=node_parse(leaf_bytes)
    leaf_address:=address_of_bytes(leaf_bytes)
    nodes.nodes[leaf_address]=leaf_bytes
    trees:=[?]struct{name:string,level:int,size:u64}{
        {"a skipped level",2,leaf_view.total},
        {"another size",1,leaf_view.total+1},
    }
    for k in trees {
        parent:=make([]u8,CHUNK_MAX,context.temp_allocator)
        bytes,encode_error:=node_encode(parent,k.level,{{address=leaf_address,size=k.size}},{{first=0,count=3}})
        testing.expect_value(t,encode_error,Error.None)
        address:=address_of_bytes(bytes)
        nodes.nodes[address]=bytes
        _,locate_error:=tree_locate(collect_source(&nodes),address,0)
        testing.expectf(t,locate_error==.Corrupt,"%s: locate %v",k.name,locate_error)
        _,group_error:=group_locate(collect_source(&nodes),address,0,0)
        testing.expectf(t,group_error==.Corrupt,"%s: group %v",k.name,group_error)
    }
    self:=make([]u8,CHUNK_MAX,context.temp_allocator)
    unknown:Hash
    unknown[0]=1
    self_bytes,_:=node_encode(self,1,{{address=unknown,size=10}})
    nodes.nodes[unknown]=self_bytes
    _,locate_error:=tree_locate(collect_source(&nodes),unknown,3)
    testing.expect_value(t,locate_error,Error.Corrupt)

    // Memory that runs out.
    failing:=mem.Allocator{procedure=proc(data:rawptr,mode:mem.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,mem.Allocator_Error) {
        #partial switch mode {
        case .Free,.Free_All: return nil,.None
        }
        return nil,.Out_Of_Memory
    }}
    c:Chunker
    testing.expect_value(t,chunker_init(&c,failing),Error.Out_Of_Memory)
    tree:Tree
    tree_init(&tree,collect_sink(&nodes),failing)
    testing.expect_value(t,tree_group(&tree,0,0),Error.Out_Of_Memory)
    tree_init(&tree,collect_sink(&nodes),failing)
    testing.expect_value(t,tree_put_chunk(&tree,leaf[:10]),Error.Out_Of_Memory)
    _,_,finish_error:=tree_finish(&tree)
    testing.expect_value(t,finish_error,Error.Out_Of_Memory)
    tree_destroy(&tree)
}

@(test)
groups_resolve_at_every_boundary :: proc(t:^testing.T) {
    // low_every: every how many leaves an address ends a node, -1 never;
    // group_every: every how many leaves a group starts, 0 at random. The last
    // case leaves no room for its groups beside a top node of 6000 entries.
    cases:=[?]struct{leaves,low_every,group_every,min_level:int}{
        {50,0,0,0},
        {5000,64,0,1},
        {400_000,64,0,2},
        {6000,-1,3,1},
    }
    for k in cases {
        nodes:=Collect{nodes=make(map[Hash][]u8,context.temp_allocator),levels=make(map[Hash]int,context.temp_allocator),seen=make(map[Hash]Chunk_Kind,context.temp_allocator),keep=true}
        tree:Tree
        tree_init(&tree,collect_sink(&nodes))
        defer tree_destroy(&tree)
        h:=base.Hostile{state=u64(k.leaves)}
        sizes:=make([]u64,k.leaves,context.temp_allocator)
        addresses:=make([]Hash,k.leaves,context.temp_allocator)
        group_first:=make([dynamic]int,context.temp_allocator)
        for i in 0..<k.leaves {
            starts_group:=k.group_every>0?i%k.group_every==0:base.hostile_int(&h,k.leaves/7+1)==0
            if i==0 || starts_group {
                testing.expect_value(t,tree_group(&tree,7,u32(len(group_first)),2),Error.None)
                append(&group_first,i)
                if len(group_first)==3 {
                    testing.expect_value(t,tree_group(&tree,7,u32(len(group_first)),2),Error.None)
                    append(&group_first,i)
                }
            }
            for &b in addresses[i] {b=u8(base.hostile_next(&h))}
            if k.low_every>0 {
                low:=i%k.low_every==k.low_every-1
                addresses[i][3]=low?0:max(addresses[i][3],1)
            } else if k.low_every<0 {
                addresses[i][3]=max(addresses[i][3],1)
            }
            sizes[i]=u64(1+base.hostile_int(&h,CHUNK_MAX))
            if base.hostile_int(&h,9)==0 {sizes[i]=CHUNK_MAX}
            testing.expect_value(t,tree_put_leaf(&tree,addresses[i],sizes[i]),Error.None)
        }
        root,total,error:=tree_finish(&tree)
        if !testing.expect_value(t,error,Error.None) {continue}
        level:=nodes.levels[root]
        testing.expectf(t,level>=k.min_level,"%d leaves: root level %d",k.leaves,level)
        starts:=make([]u64,k.leaves+1,context.temp_allocator)
        for s,i in sizes {starts[i+1]=starts[i]+s}
        testing.expect_value(t,total,starts[k.leaves])
        root_view,_:=node_parse(nodes.nodes[root])
        testing.expectf(t,len(root_view.groups)==len(group_first),"%d leaves: %d groups",k.leaves,len(root_view.groups))
        for g,i in root_view.groups[:min(len(root_view.groups),len(group_first))] {
            testing.expectf(t,int(g.first)==group_first[i] && g.offset==starts[group_first[i]],"%d leaves: group %d at leaf %d byte %d",k.leaves,i,g.first,g.offset)
        }
        source:=collect_source(&nodes)
        for i in 0..<k.leaves {
            for offset in ([2]u64{starts[i],starts[i+1]-1}) {
                leaf,e:=tree_locate(source,root,offset)
                if !testing.expectf(t,e==.None && leaf.address==addresses[i] && leaf.offset==starts[i] && leaf.size==sizes[i],"%d leaves: byte %d of leaf %d: %v",k.leaves,offset,i,e) {return}
            }
        }
        _,beyond:=tree_locate(source,root,total)
        testing.expect_value(t,beyond,Error.Invalid_Argument)
        for first,g in group_first {
            end:=g+1<len(group_first)?group_first[g+1]:k.leaves
            size:=starts[end]-starts[first]
            check:=make([dynamic]int,context.temp_allocator)
            for i in first..<end {
                if i<first+3 || i>=end-3 || k.leaves<=5000 {append(&check,i)}
            }
            for i in check {
                for offset in ([2]u64{starts[i]-starts[first],starts[i+1]-1-starts[first]}) {
                    leaf,e:=group_locate(source,root,g,offset)
                    if !testing.expectf(t,e==.None && leaf.address==addresses[i] && leaf.offset==starts[i],"%d leaves: group %d byte %d: %v",k.leaves,g,offset,e) {return}
                }
            }
            _,past:=group_locate(source,root,g,size)
            testing.expectf(t,past==.Invalid_Argument,"%d leaves: group %d past its end: %v",k.leaves,g,past)
        }
        _,unknown:=group_locate(source,root,len(group_first),0)
        testing.expect_value(t,unknown,Error.Invalid_Argument)
    }
}
