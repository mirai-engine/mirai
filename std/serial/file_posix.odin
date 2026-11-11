#+build !windows
package serial

import "core:os"

@(private)
Read_File :: ^os.File

@(private)
file_open_read :: proc(path:string) -> (Read_File,File_Error) {
    file,error:=os.open(path)
    if error==nil {return file,.None}
    if general,is_general:=error.(os.General_Error);is_general && general==.Not_Exist {return nil,.Not_Found}
    return nil,.Open
}

@(private)
file_close :: proc(file:Read_File) {os.close(file)}

@(private)
file_size :: proc(file:Read_File) -> (i64,bool) {
    size,error:=os.file_size(file)
    return size,error==nil
}

@(private)
file_read_at :: proc(file:Read_File,offset:i64,out:[]u8) -> bool {
    for total:=0;total<len(out); {
        count,error:=os.read_at(file,out[total:],offset+i64(total))
        if error!=nil || count<=0 {return false}
        total+=count
    }
    return true
}

@(private)
file_replace :: proc(from,to:string) -> bool {return os.rename(from,to)==nil}
