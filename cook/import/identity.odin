package importer

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"

// Which asset each part of a source is (its sidecar says: sidecar.odin) and
// where its file is: one of the cache at the path the sidecar lists, in the
// imported folder; a document where the file with its id is now, under the
// folder searched (the assets of options.root, else options.root, else the
// folder written to), found by reading the front of every asset there. Of
// files with one id, the one a copy was made of is the asset.

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
    root:bool,        // the root of the import: the one of its kind, whatever its name
    entry:int,        // the output of the sidecar it is; -1 for a new one
    earlier:int,      // the file with its id, which it writes again; -1 without one
    shared:int,       // what another import wrote with the same content, which the part names instead of writing: its file; SHARED_AWAY for one that is not there now; NOT_SHARED for none
    output:int,       // what the sidecar the import writes lists for it (Writer.outputs)
    decided:bool,     // whether it is a part of the root was decided by an import before: part says it
    part:bool,
    id:base.Asset_Id,
    owner:base.Asset_Id,
    path:string,
}

@(private) NOT_SHARED :: -1
// The asset the sidecar says another import writes has no file now: that
// import did not run yet on this checkout, and the part names it all the same.
@(private) SHARED_AWAY :: -2

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
        if at,seen:=w.by_id[e.id];seen {
            if asset.file_newer(w.earlier[at].key,key) {w.earlier[at]=e}
            continue
        }
        w.by_id[e.id]=len(w.earlier)
        append(&w.earlier,e)
    }
}

// Reads the sidecar of the source at path, which says which asset each thing
// of the source is, and decides where what the import builds goes: the cache
// kinds to the imported folder of the root when the source is in the source
// folder of the root, everything else to the folder.
@(private)
writer_source :: proc(w:^Writer,path:string) -> bool {
    w.source,w.path=source_path(w.options,path),path
    w.inputs.allocator,w.held.allocator=context.temp_allocator,context.temp_allocator
    w.sidecar_file=sidecar_path(path,w.options.root,w.folder,context.temp_allocator)
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    sidecar,_,error:=sidecar_load(w.sidecar_file,context.temp_allocator)
    if error.code!=.None {return writer_fail(w,error.code,"%s",error.message)}
    w.sidecar=sidecar
    w.taken=make([]bool,len(w.sidecar.outputs),context.temp_allocator)
    w.outputs=make([dynamic]Output,context.temp_allocator)
    names:=project.FOLDER_NAMES
    w.cached=w.options.root!="" && !w.options.documents && strings.has_prefix(w.source,names[.Source]) && strings.has_prefix(w.source[len(names[.Source]):],"/")
    if w.cached {w.imported=project.imported_path(w.options.root,context.temp_allocator)}
    // A texture is built Fast only where sync builds it Final later: in the cache.
    if !w.cached {w.options.fast_textures=false}
    return true
}

// The file of an output of the cache: in the imported folder, by its id and
// the key of what the import builds from (import_key). The file the id had
// under another key takes that name first: the import keeps it or writes over
// it, as it would the one of a document.
@(private)
imported_file :: proc(w:^Writer,id:base.Asset_Id,extension:string) -> string {
    if w.key==0 {
        slice.sort(w.inputs[:])
        w.key=import_key(w.path,{settings=w.report.settings,inputs=w.inputs},w.version,w.options.fast_textures)
        entries,_:=os.read_all_directory_by_path(w.imported,context.temp_allocator)
        for entry in entries {
            if held,_,named:=asset.imported_name(entry.name);named {w.held[held]=entry.name}
        }
    }
    path:=asset.imported_file(w.imported,id,w.key,extension,context.temp_allocator)
    if name,held:=w.held[id];held && !os.exists(path) {_=os.rename(fmt.tprintf("%s/%s",w.imported,name),path)}
    return path
}

// Notes a file the import reads besides its source, as the sidecar lists it.
@(private)
writer_input :: proc(w:^Writer,file:string) {
    relative,error:=filepath.rel(filepath.dir(path_key(w.path)),path_key(file),context.temp_allocator)
    if error!=.None {return}
    slashed,_:=strings.replace_all(relative,"\\","/",context.temp_allocator)
    if !slice.contains(w.inputs[:],slashed) {append(&w.inputs,slashed)}
}

// The output of the sidecar a part is: of its kind and, unless it is the root
// of the import, of its name (the one of its index first), then of its index,
// for a part renamed in the source. -1 for a part the sidecar does not list.
@(private="file")
output_find :: proc(w:^Writer,p:^Part,by_index:bool) -> int {
    best,score:=-1,-1
    for &output,at in w.sidecar.outputs {
        if w.taken[at] || output.kind!=p.kind {continue}
        if p.root {return at}
        if by_index {
            if output.index==p.index {return at}
            continue
        }
        if output.name!=p.name {continue}
        if rank:=output.index==p.index?1:0;rank>score {best,score=at,rank}
    }
    return best
}

// Gives each part its asset and its file. A part the sidecar of the source
// lists is that asset: one of the cache in the imported folder, a
// document where the file with its id is now, and one another import writes
// (shared) only named, whether or not that import ran yet: the order sources
// are imported in changes nothing. A part it does not list is new: a texture names one of
// the project with the bytes of its image and its settings, when there is one
// (the content is not written twice); any other gets a random id and a file
// of its own. What the import gives is listed in w.outputs, the sidecar it
// writes when it ends.
@(private)
parts_plan :: proc(w:^Writer,parts:[]Part) {
    defaults:=make([]string,len(parts),context.temp_allocator)
    seen:=make(map[string]bool,context.temp_allocator)
    for &p,i in parts {
        p.entry,p.earlier,p.shared=-1,-1,NOT_SHARED
        defaults[i]=default_file(&seen,p.name,p.extension)
    }
    for by_index in ([2]bool{false,true}) {
        for &p in parts {
            if p.entry>=0 {continue}
            if at:=output_find(w,&p,by_index);at>=0 {p.entry=at;w.taken[at]=true}
        }
    }
    for &p in parts {
        if p.entry<0 {continue}
        output:=&w.sidecar.outputs[p.entry]
        p.id=output.id
        at,found:=w.by_id[output.id]
        if found && w.earlier[at].kind!=p.kind {found=false}
        if output.shared {
            p.shared=found?at:SHARED_AWAY
            continue
        }
        if found {p.earlier=at;w.earlier[at].taken=true}
    }
    for &p in parts {
        if p.entry>=0 || p.root || p.kind!=asset.KIND_TEXTURE {continue}
        for &e,at in w.earlier {
            if e.taken || e.kind!=asset.KIND_TEXTURE || !e.imported || e.info.source_size!=p.size || e.info.source_hash!=p.hash {continue}
            if e.info.settings_hash!=p.settings && (p.fast==0 || e.info.settings_hash!=p.fast) {continue}
            p.shared,p.id=at,e.id
            break
        }
    }
    for &p,i in parts {
        p.output=len(w.outputs)
        if p.shared!=NOT_SHARED {
            append(&w.outputs,Output{kind=p.kind,name=p.name,index=p.index,id=p.id,shared=true})
            continue
        }
        if p.entry<0 {p.id=writer_id(w)}
        cached:=w.cached && kind_cached(p.kind)
        switch {
        case cached:
            p.decided=p.entry>=0
            p.part=p.decided && w.sidecar.outputs[p.entry].part
            p.path=imported_file(w,p.id,p.extension)
        case p.earlier>=0:
            p.path=w.earlier[p.earlier].path
            p.decided,p.part=true,w.earlier[p.earlier].owner!={}
        case:
            p.path=fresh_path(w,defaults[i])
        }
        if folder:=filepath.dir(p.path);!os.is_dir(folder) {_=os.make_directory_all(folder)}
        append(&w.outputs,Output{kind=p.kind,name=p.name,index=p.index,id=p.id,part=p.part && cached})
    }
}

// The id and the file of the root of an import: the output of kind its
// sidecar lists, else a new one named name.
@(private)
root_take :: proc(w:^Writer,kind:asset.Fourcc,name,extension:string) -> (id:base.Asset_Id,path:string) {
    parts:=[1]Part{{kind=kind,name=name,extension=extension,root=true}}
    parts_plan(w,parts[:])
    return parts[0].id,parts[0].path
}

// Records which parts of the cache name the root of the import as their
// owner, once that is decided: what the sidecar keeps for the next import.
@(private)
parts_record :: proc(w:^Writer,parts:[]Part) {
    for &p in parts {
        if p.shared==NOT_SHARED && w.cached && kind_cached(p.kind) {w.outputs[p.output].part=p.owner!={}}
    }
}

// Ends the outputs of an import that wrote its assets: what its sidecar
// listed and the source no longer gives leaves it, with its file when it is of
// the cache (a document stays, a plain asset from then on), and the sidecar is
// written with the settings the source was imported with.
@(private)
writer_finish :: proc(w:^Writer) -> bool {
    for output,at in w.sidecar.outputs {
        if w.taken[at] || output.shared {continue}
        if name,held:=w.held[output.id];w.cached && held && kind_cached(output.kind) {
            os.remove(fmt.tprintf("%s/%s",w.imported,name))
            writer_warn(w,"%s %s is no longer in the source: its asset is gone, and what named it names nothing",kind_name(output.kind),output.name)
        } else if found,located:=w.by_id[output.id];located {
            writer_warn(w,"%s is no longer in the source: it was left as it is",w.earlier[found].path)
        }
    }
    slice.sort(w.inputs[:])
    if !sidecar_save(w.sidecar_file,{settings=w.report.settings,documents=!w.cached,inputs=w.inputs,outputs=w.outputs}) {
        return writer_fail(w,.Write,"%s, which keeps the ids of the import, could not be written",w.sidecar_file)
    }
    w.report.saved=strings.clone(w.sidecar_file,w.allocator)
    return true
}

// Takes a part of the cache another import wrote out of the root of that
// import, in its sidecar: what the next import of its source reads.
@(private)
sidecar_unpart :: proc(w:^Writer,e:^Earlier) -> bool {
    if !e.imported {return true}
    named:=base.text_get(e.info.source[:])
    source:=named
    if !filepath.is_abs(named) && w.options.root!="" {source,_=filepath.join({w.options.root,named},context.temp_allocator)}
    // Without a root every output is a document, whose file says whether it is a part.
    if w.options.root=="" {return true}
    file:=sidecar_path(source,w.options.root,allocator=context.temp_allocator)
    sidecar,found,error:=sidecar_load(file,context.temp_allocator)
    if error.code!=.None || !found {return error.code==.None}
    for &output in sidecar.outputs {
        if output.id==e.id && output.part {
            output.part=false
            return sidecar_save(file,sidecar)
        }
    }
    return true
}

// <name><extension> with a name a file can have, " (2)" and on when an
// earlier part of the same write took it: the file a part gets when the
// sidecar gives it none.
@(private)
default_file :: proc(seen:^map[string]bool,name,extension:string) -> string {
    base_name:=safe_name(name)
    for at:=1;;at+=1 {
        file:=fmt.tprintf("%s%s",base_name,extension) if at==1 else fmt.tprintf("%s (%d)%s",base_name,at,extension)
        key:=strings.to_lower(file,context.temp_allocator)
        if seen[key] {continue}
        seen[key]=true
        return file
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

// The first of file in the folder, then file with " (2)" and on before its
// extension, that no part of this write took and no file has.
@(private)
fresh_path :: proc(w:^Writer,file:string) -> string {
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

@(private)
kind_name :: proc(kind:asset.Fourcc) -> string {
    // The scene an import writes has one root: the prefab of its model.
    if kind==asset.KIND_SCENE {return "prefab"}
    if info,found:=asset.kind_info(kind);found {return info.name}
    return "asset"
}
