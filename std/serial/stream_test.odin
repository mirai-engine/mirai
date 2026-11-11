package serial

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "mirai:std/base"

// xorshift64*: the same sequence on every run and platform.
@(private)
fuzz_next :: proc(state:^u64) -> u64 {
    state^~=state^>>12
    state^~=state^<<25
    state^~=state^>>27
    return state^*0x2545f4914f6cdd1d
}

@(private)
test_path :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    return fmt.tprintf("%s/mirai-serial-%d-%s",directory,os.get_pid(),name)
}

@(test)
writer_and_reader_round_trip_every_scalar :: proc(t:^testing.T) {
    w:Writer;writer_init(&w);defer writer_destroy(&w)
    write_u8(&w,0xab);write_u16(&w,0xbeef);write_u32(&w,0xdeadbeef);write_u64(&w,0x0123456789abcdef)
    write_i8(&w,-5);write_i16(&w,-1234);write_i32(&w,min(i32));write_i64(&w,min(i64))
    write_f32(&w,1.5);write_f64(&w,-2.25);write_bool(&w,true)
    write_string(&w,"mirai")
    write_align(&w,16)
    write_u8(&w,7)
    testing.expect_value(t,w.count%16,1)
    testing.expect_value(t,w.data[1],u8(0xef))
    testing.expect_value(t,w.data[2],u8(0xbe))

    r:=reader_init(writer_bytes(&w))
    testing.expect_value(t,read_u8(&r),u8(0xab))
    testing.expect_value(t,read_u16(&r),u16(0xbeef))
    testing.expect_value(t,read_u32(&r),u32(0xdeadbeef))
    testing.expect_value(t,read_u64(&r),u64(0x0123456789abcdef))
    testing.expect_value(t,read_i8(&r),i8(-5))
    testing.expect_value(t,read_i16(&r),i16(-1234))
    testing.expect_value(t,read_i32(&r),min(i32))
    testing.expect_value(t,read_i64(&r),min(i64))
    testing.expect_value(t,read_f32(&r),f32(1.5))
    testing.expect_value(t,read_f64(&r),f64(-2.25))
    testing.expect_value(t,read_bool(&r),true)
    testing.expect_value(t,read_string(&r),"mirai")
    read_align(&r,16)
    testing.expect_value(t,read_u8(&r),u8(7))
    testing.expect(t,!r.failed && reader_remaining(&r)==0)
}

@(test)
varints_round_trip_the_edges_of_every_length :: proc(t:^testing.T) {
    w:Writer;writer_init(&w);defer writer_destroy(&w)
    values:=[?]u64{0,1,127,128,16383,16384,1<<32-1,1<<32,1<<56-1,1<<56,1<<63-1,1<<63,max(u64)}
    signed:=[?]i64{0,-1,1,-64,63,-65,64,i64(min(i32)),i64(max(i32)),min(i64),max(i64)}
    for value in values {write_varint(&w,value)}
    for value in signed {write_svarint(&w,value)}
    r:=reader_init(writer_bytes(&w))
    for value in values {testing.expect_value(t,read_varint(&r),value)}
    for value in signed {testing.expect_value(t,read_svarint(&r),value)}
    testing.expect(t,!r.failed && reader_remaining(&r)==0)

    one:Writer;writer_init(&one);defer writer_destroy(&one)
    write_varint(&one,127);testing.expect_value(t,one.count,1)
    write_varint(&one,128);testing.expect_value(t,one.count,3)
    write_varint(&one,max(u64));testing.expect_value(t,one.count,13)
    write_svarint(&one,-1);testing.expect_value(t,one.count,14)
}

@(test)
reader_fails_once_and_stays_failed_past_the_end :: proc(t:^testing.T) {
    data:=[?]u8{1,2,3}
    r:=reader_init(data[:])
    testing.expect_value(t,read_u16(&r),u16(0x0201))
    testing.expect_value(t,read_u32(&r),u32(0))
    testing.expect(t,r.failed)
    testing.expect_value(t,read_u8(&r),u8(0))
    testing.expect(t,read_bytes(&r,1)==nil)
    testing.expect_value(t,reader_remaining(&r),0)

    negative:=reader_init(data[:])
    testing.expect(t,read_bytes(&negative,-1)==nil && negative.failed)
    seek:=reader_init(data[:])
    reader_seek(&seek,3);testing.expect(t,!seek.failed)
    reader_seek(&seek,4);testing.expect(t,seek.failed)
}

@(test)
reader_rejects_hostile_varints_counts_and_strings :: proc(t:^testing.T) {
    endless:=[?]u8{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x01}
    r:=reader_init(endless[:])
    testing.expect_value(t,read_varint(&r),u64(0))
    testing.expect(t,r.failed)

    overflow:=[?]u8{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x02}
    r=reader_init(overflow[:])
    read_varint(&r);testing.expect(t,r.failed)

    truncated:=[?]u8{0x80}
    r=reader_init(truncated[:])
    read_varint(&r);testing.expect(t,r.failed)

    // Says a million elements of 8 bytes follow, with 3 bytes of input.
    huge:=[?]u8{0xc0,0x84,0x3d,1,2,3}
    r=reader_init(huge[:])
    testing.expect_value(t,read_count(&r,8),0)
    testing.expect(t,r.failed)

    text:=[?]u8{5,'a','b'}
    r=reader_init(text[:])
    testing.expect_value(t,read_string(&r),"")
    testing.expect(t,r.failed)
}

@(test)
fixed_writer_counts_what_does_not_fit :: proc(t:^testing.T) {
    buffer:[6]u8
    w:Writer;writer_init_fixed(&w,buffer[:])
    write_u32(&w,1)
    write_u32(&w,2)
    write_u16(&w,0x0403)
    testing.expect_value(t,w.count,6)
    testing.expect_value(t,w.overflow,4)
    testing.expect_value(t,buffer[4],u8(3))
    writer_reset(&w)
    testing.expect_value(t,w.overflow,0)
    writer_destroy(&w)
}

@(test)
writer_patches_only_what_it_wrote :: proc(t:^testing.T) {
    w:Writer;writer_init(&w,4);defer writer_destroy(&w)
    write_u32(&w,0);write_u32(&w,9)
    size:=u32(w.count)
    testing.expect(t,writer_patch(&w,0,([^]u8)(&size)[:4]))
    testing.expect(t,!writer_patch(&w,6,([^]u8)(&size)[:4]))
    r:=reader_init(writer_bytes(&w))
    testing.expect_value(t,read_u32(&r),u32(8))
    taken:=writer_take(&w)
    testing.expect_value(t,len(taken),8)
    testing.expect_value(t,w.count,0)
    delete(taken)
}

@(test)
files_are_written_whole_and_read_back :: proc(t:^testing.T) {
    path:=test_path("atomic.bin")
    defer os.remove(path)
    first:=[?]u8{1,2,3,4,5,6,7,8,9,10}
    second:=[?]u8{42,43}
    testing.expect_value(t,file_write_atomic(path,first[:]),File_Error.None)
    testing.expect_value(t,file_write_atomic(path,second[:],sync=true),File_Error.None)
    data,error:=file_read(path)
    defer delete(data)
    testing.expect_value(t,error,File_Error.None)
    testing.expect_value(t,len(data),2)
    testing.expect_value(t,data[1],u8(43))
    testing.expect_value(t,uintptr(raw_data(data))%WRITER_ALIGNMENT,uintptr(0))
    testing.expect(t,!os.exists(fmt.tprintf("%s.%d.tmp",path,os.get_pid())))

    testing.expect_value(t,file_write_atomic(path,first[:]),File_Error.None)
    buffer:[4]u8
    head,size,head_error:=file_read_head(path,buffer[:])
    testing.expect_value(t,head_error,File_Error.None)
    testing.expect_value(t,size,i64(10))
    testing.expect_value(t,len(head),4)
    testing.expect_value(t,head[3],u8(4))
    testing.expect_value(t,file_read_range(path,7,buffer[:3]),File_Error.None)
    testing.expect_value(t,buffer[2],u8(10))
    testing.expect_value(t,file_read_range(path,8,buffer[:]),File_Error.Read)
}

@(test)
file_errors_name_what_failed :: proc(t:^testing.T) {
    missing:=test_path("missing.bin")
    data,error:=file_read(missing)
    testing.expect(t,data==nil)
    testing.expect_value(t,error,File_Error.Not_Found)
    buffer:[4]u8
    _,_,head_error:=file_read_head(missing,buffer[:])
    testing.expect_value(t,head_error,File_Error.Not_Found)
    testing.expect_value(t,file_write_atomic(test_path("no-such-folder/file.bin"),buffer[:]),File_Error.Open)

    path:=test_path("limit.bin")
    defer os.remove(path)
    testing.expect_value(t,file_write_atomic(path,buffer[:]),File_Error.None)
    _,limit_error:=file_read(path,limit=3)
    testing.expect_value(t,limit_error,File_Error.Too_Large)
    // A write that fails leaves the file as it was.
    staging:=fmt.tprintf("%s.%d.tmp",path,os.get_pid())
    testing.expect(t,os.make_directory(staging)==nil)
    defer os.remove(staging)
    other:=[?]u8{9,9,9,9,9}
    testing.expect_value(t,file_write_atomic(path,other[:]),File_Error.Open)
    kept,kept_error:=file_read(path)
    defer delete(kept)
    testing.expect(t,kept_error==.None && len(kept)==len(buffer) && kept[0]==buffer[0])
    empty:=test_path("empty.bin")
    defer os.remove(empty)
    testing.expect_value(t,file_write_atomic(empty,nil),File_Error.None)
    nothing,empty_error:=file_read(empty)
    testing.expect(t,nothing==nil && empty_error==.None)
}

// A staging file outlives a process that ended or was killed while it wrote:
// a later process removes it, and keeps the one of a process that runs.
@(test)
staging_files_of_ended_processes_are_removed :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"serial-staging")
    if folder=="" {return}
    path:=fmt.tprintf("%s/pipelines.bin",folder)
    data:=[?]u8{1,2,3}
    testing.expect_value(t,file_write_atomic(path,data[:]),File_Error.None)
    Case :: struct {name:string,old,kept:bool}
    cases:=[?]Case{
        {fmt.tprintf("pipelines.bin.%d.tmp",1<<30),false,false}, // no process has that pid
        {fmt.tprintf("pipelines.bin.%d.tmp",os.get_pid()),false,true}, // a process that runs may be writing it
        {fmt.tprintf("pipelines.bin.%d.tmp",os.get_ppid()),true,false}, // its pid was given to another process
        {"pipelines.bin.12ab.tmp",false,true},
        {"pipelines.bin.tmp",false,true},
        {"other.bin.1073741824.tmp",false,true},
    }
    for c in cases {
        staged:=fmt.tprintf("%s/%s",folder,c.name)
        testing.expect_value(t,os.write_entire_file(staged,data[:]),nil)
        if c.old {
            past:=time.time_add(time.now(),-2*STAGING_STALE)
            testing.expect_value(t,os.change_times(staged,past,past),nil)
        }
    }
    file_remove_stale(path)
    for c in cases {testing.expectf(t,os.exists(fmt.tprintf("%s/%s",folder,c.name))==c.kept,"%s kept: %v",c.name,c.kept)}
    testing.expect(t,os.exists(path))
}
