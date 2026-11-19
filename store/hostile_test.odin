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

@(private="file")
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
    data:=test_bytes(3*PIECE_BYTES+9,5)
    hash:=test_address(data)
    pieces:=test_table(data)
    random:=make([]u8,PIECE_BYTES+3,context.temp_allocator)
    for _ in 0..<64 {
        size:=i64(base.hostile_int(&h,6*PIECE_BYTES))-PIECE_BYTES
        table:=make([]Hash,base.hostile_int(&h,8),context.temp_allocator)
        for &entry in table {
            for &b in entry {b=u8(base.hostile_next(&h))}
        }
        target:Hash
        for &b in target {b=u8(base.hostile_next(&h))}
        e:=receive_begin(&s,target,size,table)
        testing.expectf(t,e==.Corrupt || e==.Invalid_Argument,"a random table: %v",e)
    }
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),pieces),Error.None)
    for _ in 0..<64 {
        index:=base.hostile_int(&h,10)-3
        piece:=random[:base.hostile_int(&h,len(random))]
        for &b in piece {b=u8(base.hostile_next(&h))}
        e:=receive_piece(&s,hash,index,piece)
        testing.expectf(t,e==.Corrupt || e==.Invalid_Argument,"a random piece %d: %v",index,e)
    }
    unknown:Hash
    unknown[5]=9
    testing.expect_value(t,receive_piece(&s,unknown,0,data[:10]),Error.Missing)
    testing.expect_value(t,read(&s,unknown,0,random[:1]),Error.Missing)
    testing.expect_value(t,verify(&s,unknown),Error.Missing)
    _,size_error:=blob_size(&s,unknown)
    testing.expect_value(t,size_error,Error.Missing)
    testing.expect_value(t,read(&s,hash,-1,random[:1]),Error.Invalid_Argument)
    testing.expect_value(t,read(&s,hash,i64(len(data))+1,nil),Error.Invalid_Argument)
    testing.expect_value(t,read(&s,hash,max(i64),random[:1]),Error.Invalid_Argument)

    // A blob whose chunk is damaged on disk.
    stored,_:=put_bytes(&s,data[:PIECE_BYTES+5])
    testing.expect(t,test_damage(&s,data[:PIECE_BYTES+5],PIECE_BYTES+1),"the damage lands in a pack")
    testing.expect_value(t,verify(&s,stored),Error.Corrupt)
    testing.expect(t,!has(&s,stored),"a damaged blob goes")
    _,damaged_table_error:=blob_table(&s,stored,context.temp_allocator)
    testing.expect_value(t,damaged_table_error,Error.Missing)
    testing.expect(t,os.write_entire_file(path_in(folder,"tmp","partial",hex_of(hash),"table"),[]u8{1,2,3})==nil)
    testing.expect_value(t,receive_piece(&s,hash,0,test_piece(data,0)),Error.Corrupt)
    _,missing_error:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.Corrupt)
    testing.expect_value(t,read(&s,hash,0,random[:1]),Error.Corrupt)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),pieces),Error.None)
    _,missing_error=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.None)

    // A marked piece whose bytes on disk do not match its table entry.
    testing.expect_value(t,receive_piece(&s,hash,1,test_piece(data,1)),Error.None)
    partial_data:=path_in(folder,"tmp","partial",hex_of(hash),"data")
    on_disk,_:=os.read_entire_file(partial_data,context.temp_allocator)
    on_disk[PIECE_BYTES+7]~=1
    testing.expect(t,os.write_entire_file(partial_data,on_disk)==nil)
    testing.expect_value(t,read(&s,hash,PIECE_BYTES,random[:10]),Error.Not_Here_Yet)
    missing_list,_:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect(t,len(missing_list)==len(pieces) && missing_list[1]==1,"a piece that does not match is missing again")

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

    now:=time.now()
    unleased,_:=put_bytes(&s,data[:31],time.time_add(now,-2*GRACE))
    truncated:=path_in(folder,"leases","truncated")
    testing.expect_value(t,lease_write(&s,truncated,holder_self(),0,{unleased,hash},now),Error.None)
    valid,valid_error:=os.read_entire_file(truncated,context.temp_allocator)
    if !testing.expect(t,valid_error==nil && len(valid)>size_of(Hash)) {return}
    testing.expect(t,os.write_entire_file(truncated,valid[:len(valid)-size_of(Hash)])==nil)
    random_lease:=path_in(folder,"leases","random")
    testing.expect(t,os.write_entire_file(random_lease,test_bytes(len(valid),42))==nil)
    oversized:=path_in(folder,"leases","oversized")
    lease_bytes:=make([]u8,LEASE_HEADER+(LEASE_MAX_HASHES+1)*size_of(Hash),
        context.temp_allocator)
    copy(lease_bytes,valid)
    testing.expect(t,os.write_entire_file(oversized,lease_bytes)==nil)
    for file in ([3]string{truncated,random_lease,oversized}) {test_set_time(t,file,now)}
    _,hostile_sweep_error:=sweep(&s,nil,now)
    testing.expect_value(t,hostile_sweep_error,Error.None)
    testing.expect(t,!has(&s,unleased),"invalid leases do not keep addresses")

    // Memory that runs out.
    out:=s
    out.allocator=failing_allocator()
    _,table_error:=blob_table(&s,test_address(data[:PIECE_BYTES]),out.allocator)
    testing.expect_value(t,table_error,Error.Missing)
    good,_:=put_bytes(&s,data[:10])
    _,table_error=blob_table(&s,good,out.allocator)
    testing.expect_value(t,table_error,Error.Out_Of_Memory)
    _,missing_error=receive_missing(&s,hash,out.allocator)
    testing.expect_value(t,missing_error,Error.Out_Of_Memory)
    _,path_error:=blob_path(&s,good,out.allocator)
    testing.expect_value(t,path_error,Error.Out_Of_Memory)
    _,list_error:=ref_list(&s,"ns",out.allocator)
    testing.expect_value(t,list_error,Error.Out_Of_Memory)
    other,_:=put_bytes(&s,data[:20])
    testing.expect_value(t,receive_begin(&out,test_address(data[:PIECE_BYTES+1]),PIECE_BYTES+1,test_table(data[:PIECE_BYTES+1])),Error.None)
    testing.expect(t,has(&s,other))
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

@(private="file")
hex_of :: proc(hash:Hash) -> string {
    buffer:=new([64]u8,context.temp_allocator)
    return hex(hash,buffer)
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
    for e in entries {append(&packs,e.fullpath)}
    files.packs=packs[:]
    index,_:=os.read_all_directory_by_path(strings.concatenate({root,"/index"},context.temp_allocator),context.temp_allocator)
    for e in index {files.generation=e.fullpath}
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
    for folder in ([]string{"","/packs","/index","/leases","/retired","/tmp"}) {os.make_directory(strings.concatenate({to,folder},context.temp_allocator))}
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
