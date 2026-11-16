package platform

import "core:os"
import "core:path/filepath"

// Folder of the running executable: where what ships next to it is found.
path_executable_folder :: proc(allocator:=context.allocator) -> (path:string,ok:bool) {
    directory,error:=os.get_executable_directory(allocator)
    return directory,error==nil
}
// Folder for what the application keeps for its user (settings, saves,
// caches), created when missing: <user data>/<organization>/<application>.
// organization may be empty.
path_user_data_folder :: proc(organization,application:string,allocator:=context.allocator) -> (path:string,ok:bool) {
    if application=="" {return "",false}
    base,error:=os.user_data_dir(context.temp_allocator)
    if error!=nil {return "",false}
    parts:=[]string{base,organization,application} if organization!="" else []string{base,application}
    joined,join_error:=filepath.join(parts,allocator)
    if join_error!=nil {return "",false}
    if os.make_directory_all(joined)!=nil && !os.is_dir(joined) {
        delete(joined,allocator)
        return "",false
    }
    return joined,true
}
// Folder of the system for files that need not outlive the process.
path_temporary_folder :: proc(allocator:=context.allocator) -> (path:string,ok:bool) {
    directory,error:=os.temp_directory(allocator)
    return directory,error==nil
}
