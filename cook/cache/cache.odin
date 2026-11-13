package cache

import "core:fmt"
import "core:os"
import "core:time"
import "mirai:asset"
import "mirai:std/base"

// What an import or a cook built, kept by what it was made from in a folder
// of the caches of a project (project.cache_path), so that building it again
// reads it instead. A file of the cache is an asset whose id is its key and
// the version of what built it: a builder that gives other bytes misses every
// earlier file. A file that does not read back whole is a miss too. A read
// marks the file used, and a file no build used for UNUSED_AGE is removed:
// whatever its size, the cache keeps what the builds of the last weeks read,
// so a project larger than any fixed budget does not evict what its next
// build reads. Deleting the folder costs only the time of building again.

// A file of the cache no build used for this long is removed.
UNUSED_AGE :: 30*24*time.Hour
// A folder is looked over for unused files at most this often, after a
// write: one stat of its stamp otherwise.
TRIM_EVERY :: 24*time.Hour
// The file of a folder whose modification time is when it was last looked over.
TRIM_STAMP :: ".trimmed"

// The id of the file of key, built by version.
id :: proc "contextless" (key,version:u64) -> base.Asset_Id {return {key,version}}

// Where the file of key goes, in the temp allocator.
file_path :: proc(folder:string,key:u64,extension:string) -> string {
    return fmt.tprintf("%s/%016x%s",folder,key,extension)
}

// The file of key built by version, open in file for the caller to close and
// marked used. False without one, or with one that does not read back whole.
load :: proc(folder:string,key,version:u64,extension:string,file:^asset.Asset,allocator:=context.allocator) -> bool {
    if folder=="" {return false}
    path:=file_path(folder,key,extension)
    if asset.asset_load(file,path,allocator)!=.None {return false}
    if file.blob.header.id!=id(key,version) || !asset.blob_verify_hash(&file.blob) {
        asset.asset_close(file)
        return false
    }
    now:=time.now()
    _=os.change_times(path,now,now)
    return true
}

// Whether a file can be written into folder, which is made when missing.
ready :: proc(folder:string) -> bool {
    if folder=="" {return false}
    return os.is_dir(folder) || os.make_directory_all(folder)==nil
}

// Removes the files of folder no build used for UNUSED_AGE, and marks the
// folder looked over. How many went.
trim :: proc(folder:string) -> (removed:int) {
    now:=time.now()
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return}
    for entry in entries {
        if entry.type!=.Regular || entry.name==TRIM_STAMP || time.diff(entry.modification_time,now)<=UNUSED_AGE {continue}
        if os.remove(entry.fullpath)==nil {removed+=1}
    }
    stamp:=fmt.tprintf("%s/%s",folder,TRIM_STAMP)
    if !os.exists(stamp) {_=os.write_entire_file(stamp,nil)}
    _=os.change_times(stamp,now,now)
    return
}

// Called after a file was written into folder: trims it when it was not
// looked over for TRIM_EVERY.
written :: proc(folder:string) {
    stamp,error:=os.stat(fmt.tprintf("%s/%s",folder,TRIM_STAMP),context.temp_allocator)
    if error==nil && time.diff(stamp.modification_time,time.now())<TRIM_EVERY {return}
    trim(folder)
}
