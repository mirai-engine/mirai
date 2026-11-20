package project

import "core:os"
import "core:path/filepath"
import "core:strings"
import "mirai:std/base"

// The organization under which projects keep what they keep for their user.
USER_ORGANIZATION :: "Mirai"
// In the user folder of a project: the GPU pipelines its runs compiled, read back by the next.
PIPELINES_FILE :: "pipelines.bin"
PIPELINES_PATH_ENV :: "MIRAI_PIPELINES_PATH"

// Folder for what an application keeps for its user (settings, saves,
// caches), made when missing: <user data>/<organization>/<application>.
// organization may be empty.
user_data_folder :: proc(organization,application:string,allocator:=context.allocator) -> (path:string,ok:bool) {
    if application=="" {return "",false}
    data,error:=os.user_data_dir(context.temp_allocator)
    if error!=nil {return "",false}
    parts:=[]string{data,organization,application} if organization!="" else []string{data,application}
    joined,join_error:=filepath.join(parts,allocator)
    if join_error!=nil {return "",false}
    if os.make_directory_all(joined)!=nil && !os.is_dir(joined) {
        delete(joined,allocator)
        return "",false
    }
    return joined,true
}

// What the project at root keeps for its user, the saves and the compiled GPU
// pipelines: <user data>/Mirai/<name of the project, or of its folder>, made
// when missing. "" without a project or a folder of user data.
user_folder :: proc(root:string,allocator:=context.allocator) -> string {
    if root=="" {return ""}
    name:=filepath.base(root)
    if manifest,error:=manifest_read(path(root,PROJECT_FILE,allocator=context.temp_allocator));error.code==.None {
        if declared:=base.text_get(manifest.name[:]);declared!="" {name=strings.clone(declared,context.temp_allocator)}
    }
    folder,_:=user_data_folder(USER_ORGANIZATION,name,allocator)
    return folder
}
