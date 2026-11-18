package store

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
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
    hash:=address_of_bytes(data)
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

    // Files of the root damaged on disk.
    stored,_:=put_bytes(&s,data[:PIECE_BYTES+5])
    path,_:=blob_path(&s,stored,context.temp_allocator)
    damaged:=make([]u8,PIECE_BYTES+5,context.temp_allocator)
    copy(damaged,data)
    damaged[PIECE_BYTES+1]~=1
    Damage :: struct {bytes:[]u8}
    for d in ([]Damage{{damaged},{damaged[:PIECE_BYTES]},{nil},{data[:PIECE_BYTES+6]}}) {
        testing.expect(t,os.write_entire_file(path,d.bytes)==nil)
        testing.expect_value(t,verify(&s,stored),Error.Corrupt)
        _,table_error:=blob_table(&s,stored,context.temp_allocator)
        testing.expect_value(t,table_error,Error.Corrupt)
    }
    testing.expect(t,os.write_entire_file(path_in(folder,"partial",hex_of(hash),"table"),[]u8{1,2,3})==nil)
    testing.expect_value(t,receive_piece(&s,hash,0,test_piece(data,0)),Error.Corrupt)
    _,missing_error:=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.Corrupt)
    testing.expect_value(t,read(&s,hash,0,random[:1]),Error.Corrupt)
    testing.expect_value(t,receive_begin(&s,hash,i64(len(data)),pieces),Error.None)
    _,missing_error=receive_missing(&s,hash,context.temp_allocator)
    testing.expect_value(t,missing_error,Error.None)

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
    testing.expect(t,os.write_entire_file(path_in(folder,"refs","ns","n"),transmute([]u8)string("not a hash"))==nil)
    _,get_error:=ref_get(&s,"ns","n")
    testing.expect_value(t,get_error,Error.Corrupt)

    // Memory that runs out.
    out:=s
    out.allocator=failing_allocator()
    _,table_error:=blob_table(&s,address_of_bytes(data[:PIECE_BYTES]),out.allocator)
    testing.expect_value(t,table_error,Error.Missing)
    good,_:=put_bytes(&s,data[:10])
    _,table_error=blob_table(&s,good,out.allocator)
    testing.expect_value(t,table_error,Error.Out_Of_Memory)
    _,missing_error=receive_missing(&s,hash,out.allocator)
    testing.expect_value(t,missing_error,Error.Out_Of_Memory)
    _,path_error:=blob_path(&s,good,out.allocator)
    testing.expect_value(t,path_error,Error.Out_Of_Memory)
    _,list_error:=ref_list(&out,"ns",context.temp_allocator)
    testing.expect_value(t,list_error,Error.Out_Of_Memory)
    _,sweep_error:=sweep(&out,{good})
    testing.expect_value(t,sweep_error,Error.Out_Of_Memory)
    other,_:=put_bytes(&s,data[:20])
    testing.expect_value(t,receive_begin(&out,address_of_bytes(data[:PIECE_BYTES+1]),PIECE_BYTES+1,test_table(data[:PIECE_BYTES+1])),Error.Out_Of_Memory)
    testing.expect(t,has(&s,other))
    _,open_error:=open(path_in(folder,"other"),failing_allocator())
    testing.expect_value(t,open_error,Error.Out_Of_Memory)
    close(&s)
    leaked,bad_frees:=base.hostile_memory_end(&memory)
    testing.expect(t,leaked==0 && bad_frees==0,"the store keeps no memory past close")

    // Roots it refuses.
    testing.expect(t,os.write_entire_file(path_in(folder,"layout"),transmute([]u8)string("mirai store 0\n"))==nil)
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
