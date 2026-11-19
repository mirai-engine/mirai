package store

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

@(private)
rename_new :: proc(from,to:string) -> (exists:bool,error:Error) {
    a,b:[PATH_BYTES+1]u8
    if len(from)>=len(a) || len(to)>=len(b) {return false,.Invalid_Argument}
    copy(a[:],from)
    copy(b[:],to)
    result:=linux.renameat2(linux.AT_FDCWD,cstring(&a[0]),
        linux.AT_FDCWD,cstring(&b[0]),{.NOREPLACE})
    if result==.NONE {return false,.None}
    if result==.EEXIST {return true,.None}
    return false,os_error(os.Platform_Error(result))
}

@(private)
no_space :: proc(error:os.Error) -> bool {
    e,ok:=error.(os.Platform_Error)
    return ok && (e==.ENOSPC || e==.EDQUOT)
}

// When the process started, in ticks since boot plus the boot time in
// seconds scaled alike; alive is false for one that is not running.
@(private)
process_start :: proc(pid:u64) -> (start:u64,alive:bool) {
    if pid==0 || pid>u64(max(i32)) {return 0,false}
    path_buffer:[64]u8
    path:=strings.concatenate({"/proc/",strconv.write_uint(path_buffer[32:],pid,10),"/stat"},context.temp_allocator)
    bytes:[1024]u8
    stat:=file_text(path,bytes[:]) or_return
    close:=strings.last_index_byte(stat,')')
    if close<0 {return 0,false}
    fields:=stat[close+1:]
    // After the name: the state is field 3 and starttime field 22.
    for field_index:=3;;field_index+=1 {
        fields=strings.trim_left_space(fields)
        end:=strings.index_byte(fields,' ')
        if end<0 {end=len(fields)}
        field:=fields[:end]
        if field_index==3 && (field=="Z" || field=="X") {return 0,false}
        if field_index==22 {
            ticks,ok:=strconv.parse_u64(field)
            if !ok {return 0,false}
            boot_bytes,read_error:=os.read_entire_file_from_path("/proc/stat",context.temp_allocator)
            if read_error!=nil {return 0,false}
            boot_text:=string(boot_bytes)
            at:=strings.index(boot_text,"\nbtime ")
            if at<0 {return 0,false}
            boot_line:=boot_text[at+7:]
            if line_end:=strings.index_byte(boot_line,'\n');line_end>=0 {boot_line=boot_line[:line_end]}
            boot,boot_ok:=strconv.parse_u64(boot_line)
            if !boot_ok {return 0,false}
            return boot<<32+ticks,true
        }
        if end==len(fields) {return 0,false}
        fields=fields[end:]
    }
}

@(private="file")
file_text :: proc(path:string,buffer:[]u8) -> (string,bool) {
    file,error:=os.open(path)
    if error!=nil {return "",false}
    defer os.close(file)
    n,_:=os.read(file,buffer)
    return string(buffer[:max(n,0)]),n>0
}

@(private)
host_name :: proc(buffer:^[HOST_BYTES]u8) {
    uts:linux.UTS_Name
    if linux.uname(&uts)!=.NONE {return}
    name:=string(cstring(&uts.nodename[0]))
    copy(buffer[:HOST_BYTES-1],name)
}
