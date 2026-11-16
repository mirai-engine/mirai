package shaders

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Paths are absolute and written with '/' throughout the package, so names
// derived from them are the same on every platform.

@(private)
path_clean :: proc(path:string,allocator:=context.allocator) -> string {
    absolute,err:=os.get_absolute_path(path,context.temp_allocator)
    if err!=nil {absolute=path}
    cleaned,_:=os.clean_path(absolute,context.temp_allocator)
    result,_:=strings.replace_all(cleaned,"\\","/",allocator)
    if raw_data(result)==raw_data(cleaned) {result=strings.clone(cleaned,allocator)}
    return result
}

@(private)
path_join :: proc(parts:..string,allocator:=context.allocator) -> string {
    return strings.join(parts,"/",allocator)
}

@(private)
path_parent :: proc(path:string) -> string {
    index:=strings.last_index_byte(path,'/')
    return path[:index] if index>0 else path
}

@(private)
path_name :: proc(path:string) -> string {
    return path[strings.last_index_byte(path,'/')+1:]
}

// The part of path below base, or false when it is not inside it.
@(private)
path_relative :: proc(path,base:string) -> (relative:string,ok:bool) {
    if len(path)>len(base)+1 && strings.has_prefix(path,base) && path[len(base)]=='/' {return path[len(base)+1:],true}
    return "",false
}

@(private)
path_inside :: proc(path,base:string) -> bool {
    if path==base {return true}
    _,inside:=path_relative(path,base)
    return inside
}

// How target is reached from the directory `from`.
@(private)
path_from :: proc(target,from:string,allocator:=context.allocator) -> string {
    a:=strings.split(from,"/",context.temp_allocator)
    b:=strings.split(target,"/",context.temp_allocator)
    common:=0
    for common<len(a) && common<len(b) && a[common]==b[common] {common+=1}
    parts:=make([dynamic]string,context.temp_allocator)
    for _ in common..<len(a) {append(&parts,"..")}
    append(&parts,..b[common:])
    if len(parts)==0 {return strings.clone(".",allocator)}
    return strings.join(parts[:],"/",allocator)
}

// Component by component, as a list of folders sorts: "a/z" before "a.b/c".
@(private)
path_less :: proc(a,b:string) -> bool {
    x,y:=a,b
    for {
        i,j:=strings.index_byte(x,'/'),strings.index_byte(y,'/')
        head_x:=x[:i] if i>=0 else x
        head_y:=y[:j] if j>=0 else y
        if head_x!=head_y {return head_x<head_y}
        if i<0 || j<0 {return i<0 && j>=0}
        x,y=x[i+1:],y[j+1:]
    }
}

// A text source as the repository has it, whatever line endings the checkout uses.
@(private)
source_bytes :: proc(path:string,allocator:=context.allocator) -> (data:[]u8,ok:bool) {
    raw,err:=os.read_entire_file(path,allocator)
    if err!=nil {return nil,false}
    if strings.has_suffix(path,".slang-module") {return raw,true}
    return lf_bytes(raw),true
}

// Removes the carriage return of every CRLF, in place.
@(private)
lf_bytes :: proc(data:[]u8) -> []u8 {
    out:=0
    for i in 0..<len(data) {
        if data[i]=='\r' && i+1<len(data) && data[i+1]=='\n' {continue}
        data[out]=data[i]
        out+=1
    }
    return data[:out]
}

@(private)
write_file :: proc(path:string,data:[]u8) -> bool {
    return os.write_entire_file(path,data)==nil
}

// Writes next to the file and renames over it: a reader never sees half of it.
// The temporary file is of this process and thread: writers of the same file
// in other processes never share it.
@(private)
write_file_atomic :: proc(path:string,data:[]u8) -> bool {
    os.make_directory_all(path_parent(path))
    temporary:=fmt.tprintf("%s.%d-%d.tmp",path,os.get_pid(),os.get_current_thread_id())
    if os.write_entire_file(temporary,data)!=nil {return false}
    if os.rename(temporary,path)!=nil {os.remove(temporary);return false}
    return true
}

@(private)
Sha256 :: sha2.Context_256

@(private)
sha_begin :: proc(hash:^Sha256) {sha2.init_256(hash)}
@(private)
sha_bytes :: proc(hash:^Sha256,data:[]u8) {sha2.update(hash,data)}
@(private)
sha_text :: proc(hash:^Sha256,text:string) {sha2.update(hash,transmute([]u8)text)}
@(private)
sha_hex :: proc(hash:^Sha256,allocator:=context.allocator) -> string {
    digest:[32]u8
    sha2.final(hash,digest[:])
    return hex(digest[:],allocator)
}
@(private)
sha_of :: proc(data:[]u8,allocator:=context.allocator) -> string {
    hash:Sha256
    sha_begin(&hash)
    sha_bytes(&hash,data)
    return sha_hex(&hash,allocator)
}

@(private)
hex :: proc(bytes:[]u8,allocator:=context.allocator) -> string {
    DIGITS:="0123456789abcdef"
    out:=make([]u8,len(bytes)*2,allocator)
    for b,i in bytes {out[i*2],out[i*2+1]=DIGITS[b>>4],DIGITS[b&15]}
    return string(out)
}
