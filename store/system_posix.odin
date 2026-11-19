#+build darwin, linux
package store

import "core:os"

@(private)
file_open :: proc(path:string,flags:=os.File_Flags{.Read}) -> (^os.File,os.Error) {
    return os.open(path,flags)
}

@(private)
file_remove :: proc(path:string) -> os.Error {
    return os.remove(path)
}

// Renames from to to, replacing to; a reader of the old to keeps it.
@(private)
rename_replace :: proc(from,to:string) -> os.Error {
    return os.rename(from,to)
}

// Renames the folder from to to, which must not hold anything.
@(private)
rename_folder :: proc(from,to:string) -> os.Error {
    return os.rename(from,to)
}
