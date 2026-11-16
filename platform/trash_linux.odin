#+build linux
package platform

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// Moves a file or folder to the trash of the user, as the freedesktop.org
// trash specification describes it: the file goes to Trash/files and a
// .trashinfo with its path and the time goes to Trash/info, which file
// managers read to bring it back. path is absolute. A file of another device
// than the home trash is not moved.
trash :: proc(path:string) -> bool {
    if path=="" {return false}
    data,error:=os.user_data_dir(context.temp_allocator)
    if error!=nil {return false}
    files:=strings.concatenate({data,"/Trash/files"},context.temp_allocator)
    info:=strings.concatenate({data,"/Trash/info"},context.temp_allocator)
    if os.make_directory_all(files)!=nil && !os.is_dir(files) {return false}
    if os.make_directory_all(info)!=nil && !os.is_dir(info) {return false}
    now:=posix.time(nil)
    local:posix.tm
    if posix.localtime_r(&now,&local)==nil {return false}
    record:=fmt.tprintf("[Trash Info]\nPath=%s\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n",trash_escape(path),
        local.tm_year+1900,local.tm_mon+1,local.tm_mday,local.tm_hour,local.tm_min,local.tm_sec)
    name:=filepath.base(path)
    for attempt in 1..=1000 {
        taken:=attempt==1?name:fmt.tprintf("%s.%d",name,attempt)
        // The info file is created first and alone: it is what reserves the name.
        info_path:=strings.concatenate({info,"/",taken,".trashinfo"},context.temp_allocator)
        handle:=posix.open(strings.clone_to_cstring(info_path,context.temp_allocator),{.WRONLY,.CREAT,.EXCL},{.IRUSR,.IWUSR})
        if handle<0 {
            if posix.errno()==.EEXIST {continue}
            return false
        }
        written:=posix.write(handle,raw_data(record),uint(len(record)))
        posix.close(handle)
        target:=strings.concatenate({files,"/",taken},context.temp_allocator)
        if written!=len(record) || os.exists(target) || posix.rename(strings.clone_to_cstring(path,context.temp_allocator),strings.clone_to_cstring(target,context.temp_allocator))!=0 {
            os.remove(info_path)
            if written==len(record) && os.exists(target) {continue}
            return false
        }
        return true
    }
    return false
}

// A path as the Path key of a .trashinfo has it: the bytes that are not
// letters, digits, the unreserved marks or separators as %XX.
@(private="file")
trash_escape :: proc(path:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for c in transmute([]u8)path {
        switch c {
        case 'a'..='z','A'..='Z','0'..='9','-','_','.','~','/':strings.write_byte(&b,c)
        case:fmt.sbprintf(&b,"%%%02X",c)
        }
    }
    return strings.to_string(b)
}
