package kai

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "mirai:store"

// A tree: the files of a change as folders of the store. A file is an object
// of its bytes, cut on content, so a changed file shares the chunks the change
// did not touch. A folder is an object whose bytes list its entries sorted by
// name: {kind, name_len: u8, name, address, size: u64, files: u32, conflicts:
// u32}; its meta carries the totals under it, so whether a tree has conflicts
// is one read of its root's meta. A conflict entry names a Conflict object.
// Two trees that differ in one file share every folder off its path, and the
// same files give the same tree.

Entry_Kind :: enum u8 {File,Executable,Folder,Conflict}

Tree_Entry :: struct {
    name:string,
    kind:Entry_Kind,
    address:store.Hash,
    size:u64,       // a file's bytes; the bytes of the files under a folder; 0 for a conflict
    files:u32,      // 1 for a file or a conflict
    conflicts:u32,  // 1 for a conflict
}

// What a folder holds under it, in the meta of its object.
Totals :: struct #packed {
    files:u32,
    conflicts:u32,
    size:u64,
}

// A file of a tree by its path, as a flat list holds it.
File :: struct {
    path:string,
    kind:Entry_Kind, // File, Executable or Conflict
    address:store.Hash,
    size:u64,
}

@(private) ENTRY_FIXED :: 1+1+32+8+4+4

// The address of the object of no bytes: an empty file's.
empty_address :: proc "contextless" () -> store.Hash {
    groups:=[1]store.Group{{}}
    buffer:[size_of(store.Node)+size_of(store.Group)]u8
    bytes,_:=store.node_encode(buffer[:],0,nil,groups[:])
    return store.address_of_bytes(bytes)
}

folder_encode :: proc(entries:[]Tree_Entry,allocator:=context.allocator) -> (bytes:[]u8,totals:Totals,error:Error) {
    if len(entries)>FOLDER_ENTRIES_MAX {return nil,{},.Too_Large}
    size:=0
    for e in entries {size+=ENTRY_FIXED+len(e.name)}
    data,made:=make([dynamic]u8,0,size,allocator)
    if made!=nil {return nil,{},.Out_Of_Memory}
    w:=Writer{data=data}
    for e in entries {
        if len(e.name)==0 || len(e.name)>NAME_BYTES_MAX {return nil,{},.Invalid_Argument}
        write_value(&w,u8(e.kind))
        write_value(&w,u8(len(e.name)))
        write_string(&w,e.name)
        address:=e.address
        write_bytes(&w,address[:])
        write_value(&w,e.size)
        write_value(&w,e.files)
        write_value(&w,e.conflicts)
        totals.files+=e.files
        totals.conflicts+=e.conflicts
        totals.size+=e.size
    }
    if w.failed {return nil,{},.Out_Of_Memory}
    return w.data[:],totals,.None
}

// The entries of the bytes of a folder, whose totals must be totals. Names
// point into bytes. Every kind, name, order, size and count is checked.
folder_decode :: proc(bytes:[]u8,totals:Totals,out:^[dynamic]Tree_Entry) -> Error {
    clear(out)
    if totals.files>FILES_MAX || totals.conflicts>totals.files {return .Corrupt}
    r:=Reader{data=bytes}
    sum:Totals
    empty:=empty_address()
    previous:string
    for r.at<len(r.data) {
        e:Tree_Entry
        kind:=read_value(&r,u8)
        name_len:=int(read_value(&r,u8))
        e.name=string(read_bytes(&r,name_len))
        copy(e.address[:],read_bytes(&r,32))
        e.size=read_value(&r,u64)
        e.files=read_value(&r,u32)
        e.conflicts=read_value(&r,u32)
        if r.short || kind>u8(max(Entry_Kind)) {return .Corrupt}
        e.kind=Entry_Kind(kind)
        if len(out)>=FOLDER_ENTRIES_MAX {return .Corrupt}
        if !part_valid(e.name) || (len(out)>0 && e.name<=previous) {return .Corrupt}
        previous=e.name
        switch e.kind {
        case .File,.Executable:
            if e.files!=1 || e.conflicts!=0 || (e.size==0 && e.address!=empty) {return .Corrupt}
        case .Conflict:
            if e.files!=1 || e.conflicts!=1 || e.size!=0 || e.address=={} {return .Corrupt}
        case .Folder:
            if e.files==0 || e.conflicts>e.files || e.address=={} {return .Corrupt}
        }
        if u64(sum.files)+u64(e.files)>u64(totals.files) || u64(sum.conflicts)+u64(e.conflicts)>u64(totals.conflicts) || e.size>totals.size-sum.size {return .Corrupt}
        sum.files+=e.files
        sum.conflicts+=e.conflicts
        sum.size+=e.size
        if _,f:=append(out,e);f!=nil {return .Out_Of_Memory}
    }
    if sum!=totals {return .Corrupt}
    if _,_,clash:=names_fold_clash(out[:]) or_return;clash {return .Corrupt}
    return .None
}

// Two names of entries, sorted by name and unique, that differ only in case: a volume that
// ignores case takes them for one. Names with no capital and no byte past ASCII fold to
// themselves, so those are compared as they are sorted, without a copy.
@(private)
names_fold_clash :: proc(entries:[]Tree_Entry) -> (a,b:string,clash:bool,error:Error) {
    plain:=true
    scan: for e in entries {
        for c in transmute([]u8)e.name {
            if c>='A' && c<='Z' || c>=0x80 {
                plain=false
                break scan
            }
        }
    }
    if plain {return}
    names,made:=make([]string,len(entries),context.temp_allocator)
    if made!=nil {return "","",false,.Out_Of_Memory}
    for e,k in entries {names[k]=e.name}
    slice.sort_by(names,proc(x,y:string) -> bool {return fold_compare(x,y)<0})
    for k in 1..<len(names) {
        if fold_compare(names[k-1],names[k])==0 {return names[k-1],names[k],true,.None}
    }
    return
}

// The order of x and y with every rune lowered, as strings.to_lower would make them.
@(private)
fold_compare :: proc(x,y:string) -> int {
    i,j:=0,0
    for i<len(x) && j<len(y) {
        a,b:=rune(x[i]),rune(y[j])
        wa,wb:=1,1
        if a>=0x80 {a,wa=utf8.decode_rune_in_string(x[i:])}
        if b>=0x80 {b,wb=utf8.decode_rune_in_string(y[j:])}
        a,b=unicode.to_lower(a),unicode.to_lower(b)
        if a!=b {return a<b?-1:1}
        i+=wa
        j+=wb
    }
    return int(i<len(x))-int(j<len(y))
}

// Puts a folder of entries sorted by name: its entry, without a name.
folder_put :: proc(s:^store.Store,entries:[]Tree_Entry) -> (folder:Tree_Entry,error:Error) {
    bytes,totals:=folder_encode(entries,context.temp_allocator) or_return
    folder.kind=.Folder
    folder.files,folder.conflicts,folder.size=totals.files,totals.conflicts,totals.size
    folder.address=object_put(s,.Folder,bytes,mem.ptr_to_bytes(&totals)) or_return
    return
}

// The entries of the folder at address into out, names in allocator; when
// expected is given, the totals its parent declares.
folder_get :: proc(s:^store.Store,address:store.Hash,out:^[dynamic]Tree_Entry,expected:^Totals=nil,allocator:=context.allocator) -> (totals:Totals,error:Error) {
    bytes:=object_get(s,address,.Folder,allocator,mem.ptr_to_bytes(&totals)) or_return
    if expected!=nil && expected^!=totals {return {},.Corrupt}
    folder_decode(bytes,totals,out) or_return
    return
}

// The totals of the tree at root, from its meta alone: root.conflicts==0 says
// it has no conflict.
tree_totals :: proc(s:^store.Store,root:store.Hash) -> (totals:Totals,error:Error) {
    o,open:=store.object_open(s,root)
    if open!=.None {return {},store_error(open)}
    defer store.object_close(&o)
    meta:=store.object_meta(&o)
    meta_check(meta,.Folder,size_of(Totals)) or_return
    mem.copy_non_overlapping(&totals,&meta[size_of(Meta)],size_of(Totals))
    return
}

// The tree with no files.
tree_empty :: proc(s:^store.Store) -> (root:store.Hash,error:Error) {
    f:=folder_put(s,nil) or_return
    return f.address,.None
}

// Puts the folders of files, sorted by path, their objects being in the store
// already: the address of the root. Two paths no tree holds together (a file
// and a folder of one name, or names that differ only in case) are
// Invalid_Argument, with them in clash, in the temp allocator, when given.
tree_build :: proc(s:^store.Store,files:[]File,clash:^[2]string=nil) -> (root:store.Hash,error:Error) {
    if len(files)>FILES_MAX {return {},.Too_Large}
    for f,k in files {
        if !path_valid(f.path) || f.kind==.Folder {return {},.Invalid_Argument}
        if k>0 && files[k-1].path>=f.path {return {},.Invalid_Argument}
    }
    folder:=build_folder(s,files,0,0,clash) or_return
    return folder.address,.None
}

@(private)
build_folder :: proc(s:^store.Store,files:[]File,prefix,depth:int,clash:^[2]string) -> (folder:Tree_Entry,error:Error) {
    if depth>DEPTH_MAX {return {},.Too_Large}
    items:=make([dynamic]Tree_Entry,context.temp_allocator)
    for i:=0;i<len(files); {
        f:=&files[i]
        rest:=f.path[prefix:]
        slash:=strings.index_byte(rest,'/')
        if slash<0 {
            e:=Tree_Entry{name=rest,kind=f.kind,address=f.address,size=f.size,files=1}
            if f.kind==.Conflict {e.conflicts,e.size=1,0}
            append(&items,e)
            i+=1
            continue
        }
        under:=f.path[:prefix+slash+1]
        j:=i+1
        for j<len(files) && strings.has_prefix(files[j].path,under) {j+=1}
        child:=build_folder(s,files[i:j],prefix+slash+1,depth+1,clash) or_return
        child.name=rest[:slash]
        append(&items,child)
        i=j
    }
    slice.sort_by(items[:],proc(a,b:Tree_Entry) -> bool {return a.name<b.name})
    a,b:string
    same,one_name:=false,false
    for k in 1..<len(items) {
        if items[k-1].name==items[k].name {a,b,same,one_name=items[k].name,items[k].name,true,true}
    }
    if !same {a,b,same=names_fold_clash(items[:]) or_return}
    if !same {return folder_put(s,items[:])}
    if clash!=nil {
        under:=files[0].path[:prefix]
        clash^={strings.concatenate({under,a},context.temp_allocator),strings.concatenate({under,b},context.temp_allocator)}
        // A file and a folder of one name: the folder by a file under it.
        for f in files {
            if one_name && strings.has_prefix(f.path,clash[1]) && len(f.path)>len(clash[1]) && f.path[len(clash[1])]=='/' {
                clash[1]=f.path
                break
            }
        }
    }
    return {},.Invalid_Argument
}

// Appends the files of the tree at root to out, sorted by path, paths in
// allocator. Every folder is checked against what its parent declares.
tree_files :: proc(s:^store.Store,root:store.Hash,out:^[dynamic]File,allocator:=context.allocator) -> Error {
    return files_walk(s,root,nil,"",0,out,allocator)
}

@(private)
files_walk :: proc(s:^store.Store,address:store.Hash,expected:^Totals,prefix:string,depth:int,out:^[dynamic]File,allocator:runtime.Allocator) -> Error {
    if depth>DEPTH_MAX {return .Corrupt}
    entries:=make([dynamic]Tree_Entry,context.temp_allocator)
    folder_get(s,address,&entries,expected,context.temp_allocator) or_return
    for e in entries {
        path:=path_join(prefix,e.name,allocator) or_return
        if len(path)>PATH_MAX {return .Corrupt}
        if e.kind==.Folder {
            t:=Totals{e.files,e.conflicts,e.size}
            files_walk(s,e.address,&t,path,depth+1,out,allocator) or_return
            continue
        }
        if len(out)>=FILES_MAX {return .Corrupt}
        append(out,File{path=path,kind=e.kind,address=e.address,size=e.size})
    }
    return .None
}

// One path that differs between two trees: a file present on neither side
// has kind and address zero.
Diff :: struct {
    path:string,
    before,after:File, // path unset; present when address is not zero
}

// The files that differ from tree a to tree b, sorted by path, in allocator.
// Folders of equal address are not read. With missing, a folder the store
// lacks is appended to it and what lies under it is left out of out.
tree_diff :: proc(s:^store.Store,a,b:store.Hash,out:^[dynamic]Diff,allocator:=context.allocator,missing:^[dynamic]store.Hash=nil) -> Error {
    if a==b {return .None}
    return diff_folders(s,a,b,"",0,out,allocator,missing)
}

@(private)
diff_folders :: proc(s:^store.Store,a,b:store.Hash,prefix:string,depth:int,out:^[dynamic]Diff,allocator:runtime.Allocator,missing:^[dynamic]store.Hash) -> Error {
    if depth>DEPTH_MAX {return .Corrupt}
    left:=make([dynamic]Tree_Entry,context.temp_allocator)
    right:=make([dynamic]Tree_Entry,context.temp_allocator)
    lacking:=false
    for side in ([2]struct{address:store.Hash,entries:^[dynamic]Tree_Entry}{{a,&left},{b,&right}}) {
        if side.address=={} {continue}
        _,e:=folder_get(s,side.address,side.entries,nil,context.temp_allocator)
        if e==.Missing && missing!=nil {
            append(missing,side.address)
            lacking=true
        } else if e!=.None {
            return e
        }
    }
    if lacking {return .None}
    i,j:=0,0
    for i<len(left) || j<len(right) {
        l,r:Tree_Entry
        switch {
        case j>=len(right) || (i<len(left) && left[i].name<right[j].name): l=left[i];i+=1
        case i>=len(left) || right[j].name<left[i].name: r=right[j];j+=1
        case: l,r=left[i],right[j];i+=1;j+=1
        }
        name:=l.address!={} ? l.name : r.name
        if l.address==r.address && l.kind==r.kind {continue}
        path:=path_join(prefix,name,allocator) or_return
        lf,rf:=l.kind==.Folder && l.address!={},r.kind==.Folder && r.address!={}
        // A file before the folder of its name: a checkout removes it first.
        if (l.address!={} && !lf) || (r.address!={} && !rf) {
            d:=Diff{path=path}
            if !lf && l.address!={} {d.before={kind=l.kind,address=l.address,size=l.size}}
            if !rf && r.address!={} {d.after={kind=r.kind,address=r.address,size=r.size}}
            append(out,d)
        }
        if lf || rf {
            diff_folders(s,lf?l.address:{},rf?r.address:{},path,depth+1,out,allocator,missing) or_return
        }
    }
    return .None
}

// Whether a path can be written under any folder of any system: relative,
// with forward slashes, no empty, . or .. part, no part a system reserves.
path_valid :: proc(path:string) -> bool {
    if path=="" || len(path)>PATH_MAX {return false}
    start:=0
    for i in 0..=len(path) {
        if i<len(path) && path[i]!='/' {continue}
        if !part_valid(path[start:i]) {return false}
        start=i+1
    }
    return true
}

part_valid :: proc(part:string) -> bool {
    if part=="" || part=="." || part==".." || len(part)>NAME_BYTES_MAX {return false}
    for c in transmute([]u8)part {
        switch c {
        case 0..<0x20,0x7f,'/','\\',':','*','?','"','<','>','|': return false
        }
    }
    last:=part[len(part)-1]
    if last=='.' || last==' ' {return false}
    // A device of Windows, also with an extension: CON, PRN, AUX, NUL, COM1-9, LPT1-9.
    stem:=part
    if dot:=strings.index_byte(part,'.');dot>=0 {stem=part[:dot]}
    stem=strings.trim_right(stem," ")
    upper:[4]u8
    if len(stem)==3 || len(stem)==4 {
        for c,i in transmute([]u8)stem {upper[i]=c>='a' && c<='z'?c-'a'+'A':c}
        word:=string(upper[:len(stem)])
        switch word[:3] {
        case "CON","PRN","AUX","NUL": if len(word)==3 {return false}
        case "COM","LPT": if len(word)==4 && word[3]>='1' && word[3]<='9' {return false}
        }
    }
    return true
}

@(private)
path_join :: proc(prefix,name:string,allocator:runtime.Allocator) -> (path:string,error:Error) {
    e:runtime.Allocator_Error
    if prefix=="" {
        path,e=strings.clone(name,allocator)
    } else {
        path,e=strings.concatenate({prefix,"/",name},allocator)
    }
    return path,e!=nil ? .Out_Of_Memory : .None
}
