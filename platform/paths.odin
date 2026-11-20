package platform

import "core:os"

// Folder of the running executable: where what ships next to it is found.
path_executable_folder :: proc(allocator:=context.allocator) -> (path:string,ok:bool) {
    directory,error:=os.get_executable_directory(allocator)
    return directory,error==nil
}
// Folder of the system for files that need not outlive the process.
path_temporary_folder :: proc(allocator:=context.allocator) -> (path:string,ok:bool) {
    directory,error:=os.temp_directory(allocator)
    return directory,error==nil
}
