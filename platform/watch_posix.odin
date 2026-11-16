#+build linux, darwin
#+private
package platform

import "core:sys/posix"

Dir_Iterator :: struct {dir:posix.DIR}

dir_open :: proc(it:^Dir_Iterator,path:string) -> bool {
    text:[WATCH_PATH_BYTES+1]u8
    if len(path)>WATCH_PATH_BYTES {return false}
    copy(text[:],path)
    it.dir=posix.opendir(cstring(raw_data(text[:])) if len(path)>0 else ".")
    return it.dir!=nil
}

// The name is written to name; an entry whose name does not fit is skipped.
dir_next :: proc(it:^Dir_Iterator,name:[]u8) -> (entry:Dir_Entry,ok:bool) {
    if it.dir==nil {return}
    for {
        d:=posix.readdir(it.dir)
        if d==nil {return}
        text:=string(cstring(raw_data(d.d_name[:])))
        if text=="." || text==".." || text=="" || len(text)>len(name) {continue}
        // Size and time are those of what a link points to, but a link to a
        // folder is not entered: it could lead back above itself.
        info:posix.stat_t
        if posix.fstatat(posix.dirfd(it.dir),cstring(raw_data(d.d_name[:])),&info,{})!=.OK {continue}
        directory:=posix.S_ISDIR(info.st_mode)
        if directory && d.d_type!=.DIR {
            if d.d_type!=.UNKNOWN {continue}
            link:posix.stat_t
            if posix.fstatat(posix.dirfd(it.dir),cstring(raw_data(d.d_name[:])),&link,{.SYMLINK_NOFOLLOW})!=.OK || !posix.S_ISDIR(link.st_mode) {continue}
        }
        entry.name=string(name[:copy(name,text)])
        entry.directory=directory
        entry.size=u64(info.st_size)
        entry.modified=i64(info.st_mtim.tv_sec)*1_000_000_000+i64(info.st_mtim.tv_nsec)
        return entry,true
    }
}

dir_close :: proc(it:^Dir_Iterator) {
    if it.dir!=nil {posix.closedir(it.dir);it.dir=nil}
}

// No system here tells about a whole folder with one handle: every pass walks.
Dir_Notify :: struct {}

dir_notify_open :: proc(n:^Dir_Notify,path:string,recursive:bool) -> bool {return false}
dir_notify_take :: proc(n:^Dir_Notify) -> (changed,alive:bool) {return true,false}
dir_notify_close :: proc(n:^Dir_Notify) {}
