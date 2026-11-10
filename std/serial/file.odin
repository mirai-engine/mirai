package serial

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:std/subprocess"

File_Error :: enum u8 {
    None,
    Not_Found,
    Open,
    Read,
    Write,
    Rename,
    Too_Large,
    Out_Of_Memory,
    Invalid_Alignment, // not a power of two
}

// The whole file, in memory of the allocator with the alignment asked for.
file_read :: proc(path:string,allocator:=context.allocator,alignment:=WRITER_ALIGNMENT,limit:=i64(max(int))) -> (data:[]u8,error:File_Error) {
    if alignment<=0 || alignment&(alignment-1)!=0 {return nil,.Invalid_Alignment}
    file,open_error:=os.open(path)
    if open_error!=nil {return nil,file_open_error(open_error)}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil {return nil,.Read}
    if size>limit {return nil,.Too_Large}
    if size==0 {return nil,.None}
    bytes,alloc_error:=mem.alloc_bytes_non_zeroed(int(size),alignment,allocator)
    if alloc_error!=nil {return nil,.Out_Of_Memory}
    if !file_read_exact(file,bytes) {
        mem.free_bytes(bytes,allocator)
        return nil,.Read
    }
    return bytes,.None
}

// The first bytes of a file, as many as fit the buffer, and its size.
file_read_head :: proc(path:string,buffer:[]u8) -> (head:[]u8,size:i64,error:File_Error) {
    file,open_error:=os.open(path)
    if open_error!=nil {return nil,0,file_open_error(open_error)}
    defer os.close(file)
    size_error:os.Error
    size,size_error=os.file_size(file)
    if size_error!=nil {return nil,0,.Read}
    head=buffer[:min(i64(len(buffer)),size)]
    if !file_read_exact(file,head) {return nil,size,.Read}
    return head,size,.None
}

// A range of a file. Fails when the file ends before it.
file_read_range :: proc(path:string,offset:i64,out:[]u8) -> File_Error {
    file,open_error:=os.open(path)
    if open_error!=nil {return file_open_error(open_error)}
    defer os.close(file)
    if _,seek_error:=os.seek(file,offset,.Start);seek_error!=nil {return .Read}
    return file_read_exact(file,out)?.None:.Read
}

// Writes a temporary file next to the destination and renames it over it: a
// reader sees the previous file or the new one, never a part of either. sync
// also waits for the device before the rename, which survives a power loss.
file_write_atomic :: proc(path:string,data:[]u8,sync:=false) -> File_Error {
    buffer:[1024]u8
    staging:=len(path)+32<=len(buffer)?fmt.bprintf(buffer[:],"%s.%d.tmp",path,os.get_pid()):fmt.tprintf("%s.%d.tmp",path,os.get_pid())
    file,open_error:=os.open(staging,{.Write,.Create,.Trunc},os.Permissions_Read_All+{.Write_User})
    if open_error!=nil {return .Open}
    written:=0
    for written<len(data) {
        count,write_error:=os.write(file,data[written:])
        if write_error!=nil || count<=0 {
            os.close(file)
            os.remove(staging)
            return .Write
        }
        written+=count
    }
    synced:=!sync || os.sync(file)==nil
    if os.close(file)!=nil || !synced {
        os.remove(staging)
        return .Write
    }
    if os.rename(staging,path)!=nil {
        os.remove(staging)
        return .Rename
    }
    return .None
}

// Past this age a staging file is left over even if its pid runs: the system
// gave the pid of the process that wrote it to another one.
STAGING_STALE :: time.Hour

// Removes the staging files of file_write_atomic for path that no process is
// writing: those of a process that ended, and those older than STAGING_STALE.
// The one of a process that runs, this one included, is kept.
file_remove_stale :: proc(path:string) {
    folder,name:=os.split_path(path)
    if name=="" {return}
    entries,error:=os.read_all_directory_by_path(folder if folder!="" else ".",context.temp_allocator)
    if error!=nil {return}
    now:=time.now()
    for entry in entries {
        pid,staging:=staging_pid(entry.name,name)
        if !staging || entry.type!=.Regular {continue}
        if time.diff(entry.modification_time,now)<STAGING_STALE && subprocess.process_alive(pid) {continue}
        _=os.remove(entry.fullpath)
    }
}

// The pid in the name of a staging file of file_write_atomic for a file named name.
@(private)
staging_pid :: proc(entry,name:string) -> (pid:int,staging:bool) {
    if len(entry)<len(name)+len(".0.tmp") || entry[:len(name)]!=name || entry[len(name)]!='.' || !strings.has_suffix(entry,".tmp") {return}
    digits:=entry[len(name)+1:len(entry)-len(".tmp")]
    if len(digits)>10 {return}
    for c in transmute([]u8)digits {
        if c<'0' || c>'9' {return}
        pid=pid*10+int(c-'0')
    }
    return pid,pid>0
}

@(private)
file_open_error :: proc(error:os.Error) -> File_Error {
    if general,is_general:=error.(os.General_Error);is_general && general==.Not_Exist {return .Not_Found}
    return .Open
}

@(private)
file_read_exact :: proc(file:^os.File,out:[]u8) -> bool {
    total:=0
    for total<len(out) {
        count,error:=os.read(file,out[total:])
        total+=count
        if error!=nil || count<=0 {break}
    }
    return total==len(out)
}
