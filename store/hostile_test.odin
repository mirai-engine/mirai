package store

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:std/base"

@(private="file")
failing_allocator :: proc() -> runtime.Allocator {
    return {procedure=proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        #partial switch mode {
        case .Free,.Free_All: return nil,.None
        }
        return nil,.Out_Of_Memory
    }}
}

@(private)
path_in :: proc(folder:string,parts:..string) -> string {
    all:=make([dynamic]string,context.temp_allocator)
    append(&all,folder)
    append(&all,..parts)
    return strings.join(all[:],"/",context.temp_allocator)
}

@(test)
hostile_inputs_return_errors :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-hostile");if folder=="" {return}
    memory:base.Hostile_Memory
    allocator:=base.hostile_memory_begin(&memory)
    s,error:=open(folder,allocator)
    if !testing.expect_value(t,error,Error.None) {return}
    h:=base.Hostile{state=42}
    data:=test_bytes(3*CHUNK_MAX+9,5)
    hash,_:=test_put(&s,data)
    random:=make([]u8,CHUNK_MAX+3,context.temp_allocator)
    for _ in 0..<64 {
        target:Hash
        for &b in target {b=u8(base.hostile_next(&h))}
        chunk:=random[:base.hostile_int(&h,len(random))]
        e:=chunk_put(&s,target,chunk)
        testing.expectf(t,e==(.Invalid_Argument if len(chunk)==0 || len(chunk)>CHUNK_MAX else .None),"a chunk of %d bytes: %v",len(chunk),e)
        o,open_error:=object_open(&s,target)
        if open_error==.None {object_close(&o)}
        testing.expectf(t,open_error!=.None,"a random chunk is no object: %v",open_error)
    }
    unknown:Hash
    unknown[5]=9
    testing.expect_value(t,chunk_check(&s,unknown),Error.Missing)
    _,unknown_error:=object_open(&s,unknown)
    testing.expect_value(t,unknown_error,Error.Missing)
    if o,open_error:=object_open(&s,hash);testing.expect_value(t,open_error,Error.None) {
        testing.expect_value(t,object_read(&o,u64(len(data))+1,nil),Error.Invalid_Argument)
        testing.expect_value(t,object_read(&o,max(u64),random[:1]),Error.Invalid_Argument)
        testing.expect_value(t,object_read(&o,u64(len(data)),random[:1]),Error.Invalid_Argument)
        object_close(&o)
    }

    // Refs.
    for name in ([]string{"","."," ..","..","a/b","a\\b","A","con","com1.txt","x.","a b",strings.repeat("x",NAME_MAX+1,context.temp_allocator)}) {
        testing.expectf(t,ref_set(&s,"ns",name,hash)==.Invalid_Argument,"name %q",name)
        testing.expectf(t,ref_set(&s,name,"n",hash)==.Invalid_Argument,"namespace %q",name)
        _,get_error:=ref_get(&s,"ns",name)
        testing.expect_value(t,get_error,Error.Invalid_Argument)
        _,list_error:=ref_list(&s,name,context.temp_allocator)
        testing.expect_value(t,list_error,Error.Invalid_Argument)
    }
    testing.expect_value(t,ref_set(&s,"ns","n",hash),Error.None)

    // Leases of any content: one held that is not a lease keeps nothing, and
    // one whose holder ended goes.
    now:=time.now()
    unleased,_:=test_put(&s,data[:31],time.time_add(now,-2*GRACE))
    lease,lease_error:=lease_open(&s,{unleased,hash})
    if !testing.expect_value(t,lease_error,Error.None) {return}
    lease_buffer:[PATH_BYTES]u8
    lease_file,_:=lease_path(&lease,&lease_buffer)
    valid,valid_error:=os.read_entire_file(lease_file,context.temp_allocator)
    testing.expect_value(t,lease_release(&lease),Error.None)
    if !testing.expect(t,valid_error==nil && len(valid)>size_of(Hash)) {return}
    oversized:=make([]u8,len(LEASE_MAGIC)+(LEASE_MAX_HASHES+1)*size_of(Hash),context.temp_allocator)
    copy(oversized,valid)
    Hostile_Lease :: struct {name:string,bytes:[]u8}
    for c in ([]Hostile_Lease{{"truncated",valid[:len(valid)-1]},{"random",test_bytes(len(valid),42)},{"oversized",oversized},{"empty",nil}}) {
        path:=path_in(folder,"leases",c.name)
        testing.expect(t,os.write_entire_file(path,c.bytes)==nil)
        holder,open_error:=file_open(path,{.Read,.Write})
        if !testing.expect(t,open_error==nil) {continue}
        locked,_:=file_lock(holder,.Exclusive,false)
        testing.expect(t,locked)
        collected,make_error:=make(Live_Set,1,s.allocator)
        if !testing.expect(t,make_error==nil) {return}
        testing.expect_value(t,leases_collect(&s,&collected),Error.None)
        testing.expectf(t,!(unleased in collected) && !(hash in collected) && os.exists(path),"%s: a held file that is not a lease keeps nothing",c.name)
        os.close(holder)
        testing.expect_value(t,leases_collect(&s,&collected),Error.None)
        testing.expectf(t,!os.exists(path),"%s: it goes once its holder ends",c.name)
        delete(collected)
    }
    _,hostile_sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,hostile_sweep_error,Error.None)

    // Memory that runs out.
    out:=s
    out.allocator=failing_allocator()
    _,list_error:=ref_list(&s,"ns",out.allocator)
    testing.expect_value(t,list_error,Error.Out_Of_Memory)
    other,_:=test_put(&s,data[:20])
    testing.expect_value(t,chunk_put(&out,test_address(data[:CHUNK_MAX]),data[:CHUNK_MAX]),Error.None)
    testing.expect(t,chunk_has(&s,other))
    _,open_error:=open(path_in(folder,"other"),failing_allocator())
    testing.expect_value(t,open_error,Error.Out_Of_Memory)
    close(&s)
    leaked,bad_frees:=base.hostile_memory_end(&memory)
    testing.expect(t,leaked==0 && bad_frees==0,"the store keeps no memory past close")

    // Roots it refuses.
    testing.expect(t,os.write_entire_file(path_in(folder,"LAYOUT"),transmute([]u8)string("mirai store 1\n"))==nil)
    _,layout_error:=open(folder)
    testing.expect_value(t,layout_error,Error.Unsupported_Layout)
    _,long_error:=open(strings.repeat("x",ROOT_MAX+1,context.temp_allocator))
    testing.expect_value(t,long_error,Error.Invalid_Argument)
    _,empty_error:=open("")
    testing.expect_value(t,empty_error,Error.Invalid_Argument)
}

// Packs and index generations of any origin are refused without a crash:
// random bytes, wrong checks, counts and offsets that overflow.
@(test)
hostile_packs_and_generations_are_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-hostile-files");if folder=="" {return}
    good:=strings.concatenate({folder,"/good"},context.temp_allocator)
    data:=test_bytes(90000,7)
    address:Hash
    {
        s,ok:=test_store(t,good);if !ok {return}
        defer close(&s)
        address,_=put(&s,data)
        testing.expect_value(t,ref_set(&s,"keep","data",address),Error.None)
        _,error:=sweep(&s,nil)
        testing.expect_value(t,error,Error.None)
        // A second pack, sealed, outside the generation.
        put(&s,test_bytes(5000,8))
        testing.expect_value(t,commit(&s),Error.None)
    }
    files:=func_files(good)
    if !testing.expect(t,len(files.packs)>=2 && files.generation!="","the root has packs and a generation") {return}
    h:=base.Hostile{state=77}
    Damage :: enum {Random,Head_Only,Flip,Footer_Counts,Footer_Offsets,Truncated}
    // A damaged pack outside the generation is skipped: the rest reads.
    outside:=files.packs[0] if files.packs[0]!=files.indexed else files.packs[1]
    for damage in Damage {
        bytes,_:=os.read_entire_file(outside,context.temp_allocator)
        mutated:=hostile_mutate(bytes,damage,&h)
        root:=fmt.tprintf("%s/pack-%v",folder,damage)
        copy_root(good,root)
        testing.expect(t,os.write_entire_file(strings.concatenate({root,"/packs/",file_name(outside)},context.temp_allocator),mutated)==nil)
        s,ok:=test_store(t,root);if !ok {continue}
        got,error:=ref_get(&s,"keep","data")
        testing.expectf(t,error==.None && got==address,"%v: the generation still reads",damage)
        test_object_bytes(t,&s,address,data)
        again,put_error:=put(&s,test_bytes(5000,8))
        testing.expect(t,put_error==.None && commit(&s)==.None && chunk_has(&s,again),"and it takes writes")
        close(&s)
    }
    // A damaged generation refuses the root.
    for damage in Damage {
        bytes,_:=os.read_entire_file(files.generation,context.temp_allocator)
        mutated:=hostile_mutate(bytes,damage,&h)
        root:=fmt.tprintf("%s/index-%v",folder,damage)
        copy_root(good,root)
        testing.expect(t,os.write_entire_file(strings.concatenate({root,"/index/",file_name(files.generation)},context.temp_allocator),mutated)==nil)
        _,error:=open(root)
        testing.expectf(t,error==.Corrupt,"%v: %v",damage,error)
    }
    // A generation whose counts are each the largest.
    bytes,_:=os.read_entire_file(files.generation,context.temp_allocator)
    for field in 0..<4 {
        mutated:=make([]u8,len(bytes),context.temp_allocator)
        copy(mutated,bytes)
        head:=(^Idx_Head)(raw_data(mutated))
        switch field {
        case 0: head.packs=max(u32)
        case 1: head.refs=max(u32)
        case 2: head.chunks=max(u64)
        case 3: head.names=max(u32)
        }
        root:=fmt.tprintf("%s/count-%d",folder,field)
        copy_root(good,root)
        testing.expect(t,os.write_entire_file(strings.concatenate({root,"/index/",file_name(files.generation)},context.temp_allocator),mutated)==nil)
        _,error:=open(root)
        testing.expectf(t,error==.Corrupt,"count %d: %v",field,error)
    }
}

@(private="file")
Root_Files :: struct {packs:[]string,generation,indexed:string}

@(private="file")
func_files :: proc(root:string) -> (files:Root_Files) {
    packs:=make([dynamic]string,context.temp_allocator)
    entries,_:=os.read_all_directory_by_path(strings.concatenate({root,"/packs"},context.temp_allocator),context.temp_allocator)
    for e in entries {append(&packs,path_in(root,"packs",e.name))}
    files.packs=packs[:]
    index,_:=os.read_all_directory_by_path(strings.concatenate({root,"/index"},context.temp_allocator),context.temp_allocator)
    for e in index {files.generation=path_in(root,"index",e.name)}
    if files.generation!="" {
        bytes,_:=os.read_entire_file(files.generation,context.temp_allocator)
        g:=(^Idx_Head)(raw_data(bytes))
        if g.packs>0 {
            p:=(^Idx_Pack)(raw_data(bytes[size_of(Idx_Head):]))^
            name:[PACK_NAME]u8
            files.indexed=strings.concatenate({root,"/packs/",pack_name({p.writer,p.seq},&name)},context.temp_allocator)
        }
    }
    return
}

@(private="file")
file_name :: proc(path:string) -> string {
    return path[strings.last_index_byte(path,'/')+1:]
}

@(private="file")
copy_root :: proc(from,to:string) {
    for folder in ([]string{"","/packs","/index","/leases","/tmp"}) {os.make_directory(strings.concatenate({to,folder},context.temp_allocator))}
    for folder in ([]string{"/packs","/index"}) {
        entries,_:=os.read_all_directory_by_path(strings.concatenate({from,folder},context.temp_allocator),context.temp_allocator)
        for e in entries {
            bytes,_:=os.read_entire_file(e.fullpath,context.temp_allocator)
            _=os.write_entire_file(strings.concatenate({to,folder,"/",e.name},context.temp_allocator),bytes)
        }
    }
    _=os.write_entire_file(strings.concatenate({to,"/LAYOUT"},context.temp_allocator),transmute([]u8)string(LAYOUT))
}

@(private="file")
hostile_mutate :: proc(bytes:[]u8,damage:$D,h:^base.Hostile) -> []u8 {
    out:=make([]u8,len(bytes),context.temp_allocator)
    copy(out,bytes)
    footer_at:=len(out)-size_of(Footer)
    switch damage {
    case .Random: for &b in out {b=u8(base.hostile_next(h))}
    case .Head_Only: for &b in out[size_of(Pack_Head):] {b=u8(base.hostile_next(h))}
    case .Flip: out[len(out)/2]~=0x10
    case .Footer_Counts:
        if footer_at>0 {
            f:=(^Footer)(raw_data(out[footer_at:]))
            f.chunks,f.extras=max(u32),max(u32)
        }
    case .Footer_Offsets:
        if footer_at>0 {
            f:=(^Footer)(raw_data(out[footer_at:]))
            f.trailer,f.frames_end=max(u64)-7,max(u64)
        }
    case .Truncated: return out[:len(out)*2/3]
    }
    return out
}

// Memory that runs out while a newer generation is read keeps the one read
// before whole; the next read takes the newer one.
@(test)
a_refresh_out_of_memory_keeps_the_generation_before :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"store-refresh-oom");if folder=="" {return}
    now:=time.now()
    reader,ok:=test_store(t,folder);if !ok {return}
    defer close(&reader)
    before:=reader.state.generation.number
    writer,_:=test_store(t,folder)
    data:=test_bytes(400<<10,11)
    address,put_error:=put(&writer,data,now)
    testing.expect_value(t,put_error,Error.None)
    testing.expect_value(t,ref_set(&writer,"keep","object",address,now),Error.None)
    _,sweep_error:=sweep(&writer,nil,now)
    testing.expect_value(t,sweep_error,Error.None)
    close(&writer)

    state:=reader.state
    packs,index:=state.packs.allocator,state.pack_index.allocator
    shrink(&state.packs)
    state.packs.allocator,state.pack_index.allocator=failing_allocator(),failing_allocator()
    refreshed:=refresh_locked(&reader)
    state.packs.allocator,state.pack_index.allocator=packs,index
    testing.expect_value(t,refreshed,Error.Out_Of_Memory)
    testing.expect_value(t,state.generation.number,before)
    for pack,i in state.generation.map_pack {
        gp:=state.generation.packs[i]
        testing.expect(t,pack<len(state.packs) && state.packs[pack].id==Pack_Id{writer=gp.writer,seq=gp.seq})
    }
    testing.expect_value(t,refresh_locked(&reader),Error.None)
    testing.expect(t,state.generation.number>before,"the next read takes the newer generation")
    test_object_bytes(t,&reader,address,data)
}
