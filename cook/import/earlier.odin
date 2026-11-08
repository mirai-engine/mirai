package importer

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:std/base"

// What earlier imports wrote. The id in the header of an asset is its only
// identity and Import_Info the only record of where it came from: an import
// finds what an earlier import of its source wrote, wherever it was moved
// under the folder it searches (the assets folder of the project at
// options.root, else options.root, else the folder it writes to), and writes
// each part again to that file with that id (options.outside says what
// becomes of one outside the folder it writes to). A part that is new gets a random
// id and a file of its own. Of files with one id, the one a copy was made of
// is the asset (asset.file_newer).

@(private)
Earlier :: struct {
    path:string, // under the folder searched, as it was given
    key:string,  // the path made absolute: what files are compared by (path_key)
    id,owner:base.Asset_Id,
    kind:asset.Fourcc,
    version:u16, // of what its kind stores
    info:asset.Import_Info,
    dependencies:[]base.Asset_Id,
    imported:bool, // it has an Import_Info
    taken:bool,    // by the import being written
}

// What an import writes besides its root, before its file and id are known.
@(private)
Part :: struct {
    kind:asset.Fourcc,
    name:string,      // in the source: the mesh, the material, the image
    index:int,        // among those of its kind in the source
    extension:string,
    file:string,      // of a texture: the image file as imports name it, "" for one inside the source
    size,hash:u64,    // of a texture: of the bytes of its image
    settings:u64,     // of a texture: textures.settings_hash of how it is built
    fast:u64,         // of a texture built Fast, as the editor writes one until the cook encodes it again: its settings hash; 0 for an import that builds Final
    earlier:int,      // the output it writes again; -1 for a new one
    shared:int,       // what another import wrote with the same content, which the part names instead of writing; -1 for none
    id:base.Asset_Id,
    owner:base.Asset_Id,
    path:string,
}

// The fronts of the assets earlier scans read, by file (path_key): the
// writes of a level read the folder again for each package, and a file
// whose size and times are those it had is not read again. Made by
// earlier_cache_make, it serves one thread at a time.
Earlier_Cache :: struct {
    files:map[string]Earlier_Front,
    allocator:mem.Allocator,
}

@(private)
Earlier_Front :: struct {
    size,created,changed:i64,
    header:asset.Header,
    info:asset.Import_Info,
    imported:bool,
    error:asset.Error,
    dependencies:[]base.Asset_Id,
}

earlier_cache_make :: proc(allocator:=context.allocator) -> ^Earlier_Cache {
    cache:=new(Earlier_Cache,allocator)
    cache.files.allocator,cache.allocator=allocator,allocator
    return cache
}

earlier_cache_destroy :: proc(cache:^Earlier_Cache) {
    if cache==nil {return}
    allocator:=cache.allocator
    for key,front in cache.files {delete(key,allocator);delete(front.dependencies,allocator)}
    delete(cache.files)
    free(cache,allocator)
}

// The front of the asset of a file the walk found, from the cache when the
// file is as it was.
@(private="file")
earlier_peek :: proc(w:^Writer,info:Found_File,key:string) -> (front:Earlier_Front) {
    cache:=w.options.earlier_cache
    created,changed:=info.created,info.changed
    if cache!=nil {
        if kept,found:=cache.files[key];found && kept.size==info.size && kept.created==created && kept.changed==changed {return kept}
    }
    dependencies:=make([dynamic]base.Asset_Id,context.temp_allocator)
    front.size,front.created,front.changed=info.size,created,changed
    front.header,front.info,front.imported,front.error=asset.import_peek(info.path,&w.types,&dependencies)
    front.dependencies=dependencies[:]
    if cache==nil {return}
    stored:=front
    stored.dependencies=slice.clone(front.dependencies,cache.allocator)
    if old,found:=&cache.files[key];found {
        delete(old.dependencies,cache.allocator)
        old^=stored
    } else {
        cache.files[strings.clone(key,cache.allocator)]=stored
    }
    return
}

// A file under the folder searched, as listing its folder gives it. Times
// are nanoseconds since 1970.
@(private)
Found_File :: struct {
    path,name:string,
    size,created,changed:i64,
}

// Reads the front of every asset under folder but those under a folder whose
// name starts with a dot: header and Import_Info.
@(private)
earlier_scan :: proc(w:^Writer,folder:string) {
    absolute,error:=filepath.abs(folder,context.temp_allocator)
    if error!=nil || !os.is_dir(absolute) {return}
    prefix:=path_key(absolute)
    by_id:=make(map[base.Asset_Id]int,context.temp_allocator)
    for info in earlier_files(absolute) {
        if strings.has_suffix(info.name,".tmp") {continue}
        key:=path_key(info.path)
        front:=earlier_peek(w,info,key)
        if front.error!=.None {continue}
        header,import_data,imported,dependencies:=front.header,front.info,front.imported,front.dependencies
        path:=key
        if len(key)>len(prefix) && strings.equal_fold(key[:len(prefix)],prefix) {
            joined,_:=filepath.join({folder,key[len(prefix):]},context.temp_allocator)
            path,_=strings.replace_all(joined,"\\","/",context.temp_allocator)
        }
        e:=Earlier{path=path,key=key,id=header.id,owner=header.owner,kind=header.kind,version=header.kind_version,info=import_data,dependencies=dependencies,imported=imported}
        if at,seen:=by_id[e.id];seen {
            if asset.file_newer(w.earlier[at].key,key) {w.earlier[at]=e}
            continue
        }
        by_id[e.id]=len(w.earlier)
        append(&w.earlier,e)
    }
}

// The earlier import that this one updates, as an index of w.earlier, -1 for
// a new import:
//   - options.into, the root an earlier import wrote, which has to be of kind;
//   - else the root of kind that names this source, the one under the folder
//     written to first (a copy of an import, Earlier_Outside.Copy, is updated
//     by importing into its folder);
//   - else the one that names a source that is gone and had the same bytes
//     and extension: the source was moved or renamed (two such imports are a
//     warning and neither is taken: into chooses). A texture of a model names
//     the model as its source and the bytes of its image, so the extension
//     keeps an image imported on its own from taking it.
// A root is of its own: no owner.
@(private)
earlier_root :: proc(w:^Writer,kind:asset.Fourcc,source:string,size,hash:u64) -> (at:int,ok:bool) {
    if into:=w.options.into;into!={} {
        buffer:[base.ASSET_ID_TEXT]u8
        for &e,i in w.earlier {
            if e.id!=into {continue}
            if e.kind!=kind {return -1,writer_fail(w,.Not_Found,"%s (%s) is a %s: into names the %s of the import that %s updates",e.path,base.asset_id_format(into,buffer[:]),kind_name(e.kind),kind_name(kind),source)}
            if !e.imported {return -1,writer_fail(w,.Not_Found,"%s (%s) was not written by an import: into names the %s an earlier import wrote",e.path,base.asset_id_format(into,buffer[:]),kind_name(kind))}
            return i,true
        }
        return -1,writer_fail(w,.Not_Found,"no asset under %s has the id %s: into names the %s an earlier import wrote",w.search,base.asset_id_format(into,buffer[:]),kind_name(kind))
    }
    named:=-1
    for &e,i in w.earlier {
        if e.kind!=kind || !e.imported || e.owner!={} || !strings.equal_fold(base.text_get(e.info.source[:]),source) {continue}
        if named<0 {named=i}
        if earlier_inside(w,&e) {named=i;break}
    }
    if named>=0 {return named,earlier_writable(w,&w.earlier[named])}
    moved,copy:=-1,-1
    for &e,i in w.earlier {
        named:=base.text_get(e.info.source[:])
        if e.kind!=kind || !e.imported || e.owner!={} || e.info.source_size!=size || e.info.source_hash!=hash || !strings.equal_fold(filepath.ext(named),filepath.ext(source)) {continue}
        if source_exists(w,named) {
            copy=i
            continue
        }
        if moved>=0 {
            writer_warn(w,"%s and %s were imported from sources with the bytes of %s that are gone: neither is taken, into names the one to update",w.earlier[moved].path,e.path,source)
            return -1,true
        }
        moved=i
    }
    if moved<0 && copy>=0 {
        e:=&w.earlier[copy]
        writer_warn(w,"%s has the bytes of %s, which %s was imported from: this import writes its own outputs; import that source again, or pass into, to update those",source,base.text_get(e.info.source[:]),e.path)
    }
    if moved>=0 && !earlier_writable(w,&w.earlier[moved]) {return -1,false}
    return moved,true
}

// Whether the import may write an earlier output of its source again where
// it is: always, unless options.outside is Refuse and the file lies outside
// the folder the import writes to; then the import fails before writing
// anything, naming the file and the ways on. into names the import to update,
// wherever its root is.
@(private)
earlier_writable :: proc(w:^Writer,e:^Earlier) -> bool {
    if w.options.outside!=.Refuse || w.options.into!={} || earlier_inside(w,e) {return true}
    return writer_fail(w,.Outside,"%s was written by an earlier import of %s and lies outside %s: import with --in-place to write it again where it is, or with --copy for a separate import with new ids in %s",e.path,w.named if w.named!="" else base.text_get(e.info.source[:]),w.folder,w.folder)
}

// Whether an earlier output lies under the folder the import writes to.
@(private)
earlier_inside :: proc(w:^Writer,e:^Earlier) -> bool {
    folder:=strings.trim_right(path_key(w.folder),"/")
    return len(e.key)>len(folder) && e.key[len(folder)]=='/' && strings.equal_fold(e.key[:len(folder)],folder)
}

// Gives each part the output it writes again, then an id and a file. A part
// takes an output of its kind from the source the import named: first by
// name, preferring the same index, then by index, for a part renamed in the
// source. A texture the import does not have yet names one of the project
// with the bytes of its image and its settings, when there is one: the
// content is not written twice.
@(private)
parts_plan :: proc(w:^Writer,parts:[]Part) {
    defaults:=make([]string,len(parts),context.temp_allocator)
    seen:=make(map[string]bool,context.temp_allocator)
    for &p,i in parts {defaults[i]=default_path(w,&seen,p.name,p.extension)}
    // A part of another prefab that is there is of another import of the
    // source (a copy); one whose prefab is gone is this source's to take.
    from_source :: proc(w:^Writer,roots:map[base.Asset_Id]bool,e:^Earlier,p:^Part) -> bool {
        return !e.taken && e.imported && e.kind==p.kind && (w.owner=={} || e.owner=={} || e.owner==w.owner || !roots[e.owner]) && strings.equal_fold(base.text_get(e.info.source[:]),w.named)
    }
    roots:=earlier_roots(w)
    ours:=earlier_tree(w)
    for &p in parts {
        name:[64]u8
        asset.text_set(name[:],p.name)
        best,score:=-1,-1
        for &e,at in w.earlier {
            if !from_source(w,roots,&e,&p) || base.text_get(e.info.name[:])!=base.text_get(name[:]) {continue}
            // Of this import's prefab first, then the same index.
            rank:=(2 if ours[e.id] else 0)+(1 if int(e.info.index)==p.index else 0)
            if rank>score {best,score=at,rank}
        }
        if best>=0 {p.earlier=best;w.earlier[best].taken=true}
    }
    for &p in parts {
        if p.earlier>=0 {continue}
        best:=-1
        for &e,at in w.earlier {
            if !from_source(w,roots,&e,&p) || int(e.info.index)!=p.index {continue}
            if best<0 || ours[e.id] {best=at}
            if ours[e.id] {break}
        }
        if best>=0 {p.earlier=best;w.earlier[best].taken=true}
    }
    for &p in parts {
        if p.earlier>=0 || p.kind!=asset.KIND_TEXTURE {continue}
        for &e,at in w.earlier {
            if e.taken || e.kind!=asset.KIND_TEXTURE || !e.imported || e.info.source_size!=p.size || e.info.source_hash!=p.hash {continue}
            if e.info.settings_hash!=p.settings && (p.fast==0 || e.info.settings_hash!=p.fast) {continue}
            p.shared,p.id=at,e.id
            break
        }
    }
    for &p,i in parts {
        if p.shared>=0 {continue}
        if p.earlier>=0 {
            p.id,p.path=w.earlier[p.earlier].id,w.earlier[p.earlier].path
        } else {
            p.id,p.path=writer_id(w),fresh_path(w,defaults[i])
        }
    }
}

// The ids of the roots found: what an owner names when it is there.
@(private="file")
earlier_roots :: proc(w:^Writer) -> map[base.Asset_Id]bool {
    roots:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for &e in w.earlier {
        if e.owner=={} {roots[e.id]=true}
    }
    return roots
}

// The ids of what the prefab of the import (w.owner) holds: its parts and
// what it or they name, as far as names reach. Among outputs of one source
// written by two imports (a copy, Earlier_Outside.Copy), those of this
// import's prefab are the ones it writes again.
@(private="file")
earlier_tree :: proc(w:^Writer) -> map[base.Asset_Id]bool {
    ours:=make(map[base.Asset_Id]bool,context.temp_allocator)
    if w.owner=={} {return ours}
    ours[w.owner]=true
    for grew:=true;grew; {
        grew=false
        for &e in w.earlier {
            if !ours[e.id] && e.owner==w.owner {ours[e.id]=true;grew=true}
            if !ours[e.id] {continue}
            for id in e.dependencies {
                if !ours[id] {ours[id]=true;grew=true}
            }
        }
    }
    return ours
}

// Warns of the outputs of the source that no part took: they stay as they
// are. When another import of the source has a prefab too (a copy), only
// those this import's prefab held count.
@(private)
earlier_left :: proc(w:^Writer) {
    ours:=earlier_tree(w)
    roots:=earlier_roots(w)
    copied:=false // another prefab that is there holds parts of the source
    for &e in w.earlier {
        if e.owner!={} && e.owner!=w.owner && roots[e.owner] && e.imported && strings.equal_fold(base.text_get(e.info.source[:]),w.named) {copied=true}
    }
    for &e in w.earlier {
        if e.taken || !e.imported || e.owner!={} && e.owner!=w.owner || !strings.equal_fold(base.text_get(e.info.source[:]),w.named) {continue}
        if copied && w.owner!={} && !ours[e.id] {continue} // of the other import
        writer_warn(w,"%s is no longer in the source: it was left as it is",e.path)
    }
}

// <folder>/<name><extension> with a name a file can have, " (2)" and on when
// an earlier part of the same write took it: where a part is written when no
// file is there.
@(private)
default_path :: proc(w:^Writer,seen:^map[string]bool,name,extension:string) -> string {
    base_name:=safe_name(name)
    for at:=1;;at+=1 {
        file:=fmt.tprintf("%s%s",base_name,extension) if at==1 else fmt.tprintf("%s (%d)%s",base_name,at,extension)
        key:=strings.to_lower(file,context.temp_allocator)
        if seen[key] {continue}
        seen[key]=true
        return folder_path(w,file)
    }
}

// A file of the folder an import writes to, with forward slashes.
@(private)
folder_path :: proc(w:^Writer,file:string) -> string {
    path,_:=filepath.join({w.folder,file},context.temp_allocator)
    slashed,_:=strings.replace_all(path,"\\","/",context.temp_allocator)
    return slashed
}

// A name a file can have: what no file system takes becomes _.
safe_name :: proc(name:string) -> string {
    builder:strings.Builder
    strings.builder_init(&builder,context.temp_allocator)
    for r in name {
        switch {
        case r<32 || r==127,r=='<',r=='>',r==':',r=='"',r=='/',r=='\\',r=='|',r=='?',r=='*',r=='#':
            strings.write_byte(&builder,'_')
        case:
            strings.write_rune(&builder,r)
        }
    }
    cleaned:=strings.trim(strings.to_string(builder)," .")
    return cleaned if cleaned!="" else "unnamed"
}

// The first of path, a file of the folder, then path with " (2)" and on
// before its extension, that no part of this write took and no file has.
@(private)
fresh_path :: proc(w:^Writer,path:string) -> string {
    file:=filepath.base(path)
    stem,extension:=filepath.stem(file),filepath.ext(file)
    for at:=1;;at+=1 {
        name:=fmt.tprintf("%s%s",stem,extension) if at==1 else fmt.tprintf("%s (%d)%s",stem,at,extension)
        key:=strings.to_lower(name,context.temp_allocator)
        candidate:=folder_path(w,name)
        if w.names[key] || os.exists(candidate) {continue}
        w.names[key]=true
        return candidate
    }
}

@(private)
writer_id :: proc(w:^Writer) -> base.Asset_Id {return base.asset_id_random(&w.rng)}

// An absolute path with forward slashes: how files are compared.
@(private)
path_key :: proc(path:string) -> string {
    absolute,error:=filepath.abs(path,context.temp_allocator)
    if error!=nil {absolute=path}
    cleaned,_:=filepath.clean(absolute,context.temp_allocator)
    slashed,_:=strings.replace_all(cleaned,"\\","/",context.temp_allocator)
    return strings.clone(slashed,context.temp_allocator)
}

// Whether a source as imports name it is a file now.
@(private)
source_exists :: proc(w:^Writer,source:string) -> bool {
    if source=="" {return true}
    if filepath.is_abs(source) || w.options.root=="" {return os.exists(source)}
    joined,_:=filepath.join({w.options.root,source},context.temp_allocator)
    return os.exists(joined)
}

@(private)
kind_name :: proc(kind:asset.Fourcc) -> string {
    if info,found:=asset.kind_info(kind);found {return info.name}
    return "asset"
}
