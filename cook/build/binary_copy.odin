package build

import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:os"
import "core:strings"

@(private)
BINARY_TEMP_PREFIX :: ".mirai-copy-"

@(private)
copy_binary :: proc(to,from:string) -> (ok:bool) {
    folder,name:=os.split_path(to)
    if name=="" || strings.contains(to,"\x00") || strings.contains(from,"\x00") {return false}
    source,open_error:=os.open(from)
    if open_error!=nil {return false}
    defer os.close(source)
    info,stat_error:=os.fstat(source,context.temp_allocator)
    if stat_error!=nil || info.type!=.Regular {return false}
    staged,path_ok:=binary_temp_path(folder)
    if !path_ok {return false}
    output,create_error:=os.open(staged,{.Write,.Create,.Excl},info.mode&os.Permissions_All)
    if create_error!=nil {return false}
    defer if !ok {_=os.remove(staged)}
    count,copy_error:=io.copy(os.to_writer(output),os.to_reader(source))
    close_error:=os.close(output)
    if copy_error!=nil || close_error!=nil || count!=info.size {return false}
    return publish(staged,to)
}

@(private)
binary_temp_path :: proc(folder:string) -> (string,bool) {
    digits:[16]u8
    suffix:=fmt.bprintf(digits[:],"%016x",rand.uint64())
    parent:=folder==""?".":folder
    path,error:=strings.concatenate({parent,"/",BINARY_TEMP_PREFIX,suffix},context.temp_allocator)
    return path,error==nil
}
