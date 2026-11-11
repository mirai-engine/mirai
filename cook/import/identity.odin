package importer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"

// Which asset each part of a source is and where its file is. The sidecar of
// the source says the asset: the output of its kind and name (of its kind for
// the root of the import), else a new one. An asset of the cache is a file of
// the imported folder of the root named by its id and the key of what the
// import builds from; a document is where the registry of the root has its
// id, else a new file in the folder of the import.

// What an import writes, before its file and id are known.
@(private)
Part :: struct {
    kind:asset.Fourcc,
    name:string,      // in the source: the mesh, the material, the image
    index:int,        // among those of its kind in the source
    extension:string,
    only:bool,        // the one of its kind, whatever its name, as the root (the clips of a model, named after it)
    output:int,       // what the sidecar the import writes lists for it (Writer.outputs)
    decided:bool,     // whether it is a part of the root was decided by an import before: part says it
    part:bool,
    id:base.Asset_Id,
    owner:base.Asset_Id,
    path:string,
}

// Reads the sidecar of the source at path, which says which asset each thing
// of the source is, and the folder of the source new documents go to: the
// one its sidecar keeps, else folder. The source is in the assets of the
// project or the plugin at options.root.
@(private)
writer_source :: proc(w:^Writer,path,folder:string) -> bool {
    w.path=path
    w.source=source_path(w.options,path)
    w.inputs.allocator=context.temp_allocator
    names:=project.FOLDER_NAMES
    if w.options.root=="" {return writer_fail(w,.Not_Found,"%s: an import names the project or the plugin whose assets the source is in (root)",path)}
    if !strings.has_prefix(w.source,names[.Assets]) || !strings.has_prefix(w.source[len(names[.Assets]):],"/") {
        return writer_fail(w,.Not_Found,"%s is not in the %s folder of %s: move it there, with its %s when it has one, beside what it makes",path,names[.Assets],w.options.root,SIDECAR_EXTENSION)
    }
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    sidecar,found,error:=sidecar_load(path,context.temp_allocator)
    if error.code!=.None {return writer_fail(w,error.code,"%s",error.message)}
    w.sidecar=sidecar
    if !found {w.sidecar.folder=folder}
    w.folder=filepath.dir(path) if w.sidecar.folder=="" else fmt.tprintf("%s/%s",filepath.dir(path),w.sidecar.folder)
    w.taken=make([]bool,len(w.sidecar.outputs),context.temp_allocator)
    w.outputs=make([dynamic]Output,context.temp_allocator)
    w.imported=project.imported_path(w.options.root,context.temp_allocator)
    w.registry=w.options.registry
    if w.registry==nil {
        w.registry=new(asset.Registry,context.temp_allocator)
        asset.registry_init(w.registry,project.folder_path(w.options.root,.Assets,context.temp_allocator),"",context.temp_allocator,w.imported)
        asset.registry_scan(w.registry)
    }
    return true
}

// The file of an output of the cache: in the imported folder, by its id and
// the key of what the import builds from (import_key).
@(private)
imported_file :: proc(w:^Writer,id:base.Asset_Id,extension:string) -> string {
    if w.key==0 {
        slice.sort(w.inputs[:])
        w.key=import_key(w.path,{settings=w.report.settings,inputs=w.inputs},w.version,w.options.fast_textures)
    }
    return asset.imported_file(w.imported,id,w.key,extension,context.temp_allocator)
}

// Notes a file the import reads besides its source, as the sidecar lists it.
@(private)
writer_input :: proc(w:^Writer,file:string) {
    relative,error:=filepath.rel(filepath.dir(path_key(w.path)),path_key(file),context.temp_allocator)
    if error!=.None {return}
    slashed,_:=strings.replace_all(relative,"\\","/",context.temp_allocator)
    if !slice.contains(w.inputs[:],slashed) {append(&w.inputs,slashed)}
}

// Gives each part its asset and its file: the output of the sidecar of its
// kind and name (the one of its index first), or of its kind for the only one
// of its kind, else a new id. What the import gives is listed in w.outputs, the sidecar it
// writes when it ends.
@(private)
parts_plan :: proc(w:^Writer,parts:[]Part) {
    for &p in parts {
        entry:=-1
        for output,at in w.sidecar.outputs {
            if w.taken[at] || output.kind!=p.kind || !p.only && output.name!=p.name {continue}
            entry=at
            if p.only || output.index==p.index {break}
        }
        p.id=writer_id(w)
        if entry>=0 {
            w.taken[entry]=true
            p.id=w.sidecar.outputs[entry].id
        }
        switch {
        case asset.import_cached(p.kind):
            p.decided=entry>=0
            p.part=p.decided && w.sidecar.outputs[entry].part
            p.path=imported_file(w,p.id,p.extension)
        case:
            if file,found:=asset.registry_find(w.registry,p.id);found && file.kind==p.kind && file.imported==0 {
                p.path=asset.registry_file_path(w.registry,file.path,context.temp_allocator)
                p.decided,p.part=true,file.owner!={}
            } else {
                p.path=fresh_path(w,fmt.tprintf("%s%s",safe_name(p.name),p.extension))
            }
        }
        if folder:=filepath.dir(p.path);!os.is_dir(folder) {_=os.make_directory_all(folder)}
        p.output=len(w.outputs)
        append(&w.outputs,Output{kind=p.kind,name=p.name,index=p.index,id=p.id})
    }
}

// The id and the file of the root of an import: the output of kind its
// sidecar lists, else a new one named name.
@(private)
root_take :: proc(w:^Writer,kind:asset.Fourcc,name,extension:string) -> (id:base.Asset_Id,path:string) {
    parts:=[1]Part{{kind=kind,name=name,extension=extension,only=true}}
    parts_plan(w,parts[:])
    return parts[0].id,parts[0].path
}

// Records which parts of the cache name the root of the import as their
// owner, once that is decided: what the sidecar keeps for the next import.
@(private)
parts_record :: proc(w:^Writer,parts:[]Part) {
    for &p in parts {
        if asset.import_cached(p.kind) {w.outputs[p.output].part=p.owner!={}}
    }
}

// Ends the outputs of an import that wrote its assets: what its sidecar
// listed and the source no longer gives leaves it (a document stays, a plain
// asset from then on), the files of the imported folder its outputs had under
// another key go, and the sidecar is written with the settings the source was
// imported with.
@(private)
writer_finish :: proc(w:^Writer) -> bool {
    current:=make(map[base.Asset_Id]string,context.temp_allocator)
    for output in w.outputs {
        info,known:=asset.kind_info(output.kind)
        if known && asset.import_cached(output.kind) {current[output.id]=filepath.base(imported_file(w,output.id,info.extension))}
    }
    for output,at in w.sidecar.outputs {
        if w.taken[at] {continue}
        if asset.import_cached(output.kind) {
            current[output.id]=""
            writer_warn(w,"%s %s is no longer in the source: its asset is gone, and what named it names nothing",kind_name(output.kind),output.name)
        } else if file,found:=asset.registry_find(w.registry,output.id);found {
            writer_warn(w,"%s is no longer in the source: it was left as it is",file.path)
        }
    }
    entries,_:=os.read_all_directory_by_path(w.imported,context.temp_allocator)
    for entry in entries {
        id,_,named:=asset.imported_name(entry.name)
        if name,listed:=current[id];named && listed && name!=entry.name {os.remove(entry.fullpath)}
    }
    slice.sort(w.inputs[:])
    if !sidecar_save(w.path,{settings=w.report.settings,folder=w.sidecar.folder,inputs=w.inputs,outputs=w.outputs}) {
        return writer_fail(w,.Write,"%s%s, which keeps the ids of the import, could not be written",w.path,SIDECAR_EXTENSION)
    }
    w.report.saved=strings.concatenate({w.path,SIDECAR_EXTENSION},w.allocator)
    return true
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

// The first of file in the folder of the import, then file with " (2)" and
// on before its extension, that no part of this write took and no file has.
@(private)
fresh_path :: proc(w:^Writer,file:string) -> string {
    stem,extension:=filepath.stem(file),filepath.ext(file)
    for at:=1;;at+=1 {
        name:=fmt.tprintf("%s%s",stem,extension) if at==1 else fmt.tprintf("%s (%d)%s",stem,at,extension)
        key:=strings.to_lower(name,context.temp_allocator)
        joined,_:=filepath.join({w.folder,name},context.temp_allocator)
        candidate,_:=strings.replace_all(joined,"\\","/",context.temp_allocator)
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
