package importer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

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
    given:bool,       // an output this import gave before (Writer.given), written then
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
    w.keep=context.temp_allocator
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
    w.stored=found
    if !found {w.sidecar.folder=folder}
    w.folder=filepath.dir(path) if w.sidecar.folder=="" else fmt.tprintf("%s/%s",filepath.dir(path),w.sidecar.folder)
    w.taken=make([]bool,len(w.sidecar.outputs),context.temp_allocator)
    w.outputs=make([dynamic]Output,context.temp_allocator)
    w.paths=make([dynamic]string,context.temp_allocator)
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
        w.key=import_key(w.path,{settings=w.report.settings,inputs=w.inputs},w.version,w.options.importer_code,w.options.fast_textures)
    }
    return asset.imported_file(w.imported,id,w.key,extension,context.temp_allocator)
}

// Notes a file the import reads besides its source, as the sidecar lists it.
// False for a new one once the key of the import is fixed: the files of the
// cache are named without it.
@(private)
writer_input :: proc(w:^Writer,file:string) -> bool {
    relative,error:=filepath.rel(filepath.dir(path_key(w.path)),path_key(file),context.temp_allocator)
    if error!=.None {return true}
    slashed,_:=strings.replace_all(relative,"\\","/",context.temp_allocator)
    if slice.contains(w.inputs[:],slashed) {return true}
    if w.key!=0 {return false}
    append(&w.inputs,strings.clone(slashed,w.keep))
    return true
}

// Gives each part its asset and its file: the output of the sidecar of its
// kind and name (the one of its index first), or of its kind for the only one
// of its kind, else a new id. What the import gives is listed in w.outputs, the sidecar it
// writes when it ends. A part of the kind and name of one of the first
// w.given outputs, or of the kind, name and index of a later one, is that one
// (given): an output is listed once however many times it is asked for.
@(private)
parts_plan :: proc(w:^Writer,parts:[]Part) {
    each: for &p in parts {
        if !p.only {
            for output,at in w.outputs {
                if output.kind!=p.kind || output.name!=p.name || at>=w.given && output.index!=p.index {continue}
                p.id,p.output,p.path,p.given=output.id,at,w.paths[at],true
                continue each
            }
        }
        entry:=-1
        for output,at in w.sidecar.outputs {
            if w.taken[at] || output.kind!=p.kind || !p.only && output.name!=p.name {continue}
            entry=at
            if p.only || output.index==p.index {break}
        }
        p.id=writer_id(w)
        written:u64
        if entry>=0 {
            w.taken[entry]=true
            p.id,written=w.sidecar.outputs[entry].id,w.sidecar.outputs[entry].written
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
                p.path=fresh_path(w,fmt.tprintf("%s%s",asset.safe_path(p.name),p.extension))
            }
            // What is written of a document the import keeps goes nowhere.
            if kept,keeping:=w.keeping[p.id];keeping {p.path=kept}
        }
        if folder:=filepath.dir(p.path);!os.is_dir(folder) {_=os.make_directory_all(folder)}
        p.output=len(w.outputs)
        append(&w.outputs,Output{kind=p.kind,name=strings.clone(p.name,w.keep),index=p.index,id=p.id,written=written})
        append(&w.paths,strings.clone(p.path,w.keep))
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
        if asset.import_cached(p.kind) && !p.given {w.outputs[p.output].part=p.owner!={}}
    }
}

// The documents among outputs that an import writes over and that changed
// since it last wrote them: the file of each in registry (the assets of their
// root) holds other content than the sidecar records (Output.written). A
// change of owner alone (asset.detach) is no change. Their ids, in allocator.
outputs_changed :: proc(outputs:[]Output,registry:^asset.Registry,allocator:=context.allocator) -> []base.Asset_Id {
    changed:=make([dynamic]base.Asset_Id,allocator)
    for output in outputs {
        if output.written==0 || asset.import_cached(output.kind) {continue}
        if file,found:=asset.registry_find(registry,output.id);found && file.kind==output.kind && file.imported==0 && file.content_hash!=output.written {append(&changed,output.id)}
    }
    return changed[:]
}

// Applies Import_Options.changed to the documents of the import that changed
// since it last wrote them: Refuse fails naming them, Keep sends what would be
// written of each to a file of the imported folder that goes when the import
// ends, and warns of it.
@(private)
writer_changed :: proc(w:^Writer) -> bool {
    if w.options.changed==.Discard {return true}
    changed:=outputs_changed(w.sidecar.outputs[:],w.registry,context.temp_allocator)
    if len(changed)==0 {return true}
    names:=project.FOLDER_NAMES
    paths:=make([]string,len(changed),context.temp_allocator)
    for id,at in changed {
        file,_:=asset.registry_find(w.registry,id)
        paths[at]=fmt.tprintf("%s/%s",names[.Assets],file.path)
    }
    switch w.options.changed {
    case .Refuse:
        one:=len(changed)==1
        return writer_fail(w,.Changed,"%s changed since %s was last imported, and importing it again writes over %s: import with discard_changes to write over %s, or leave it as it is to keep %s",
            strings.join(paths,", ",context.temp_allocator),w.source,one?"it":"them",one?"that change":"those changes",one?"it":"them")
    case .Keep:
        w.keeping=make(map[base.Asset_Id]string,context.temp_allocator)
        buffer:[base.ASSET_ID_TEXT]u8
        for id,at in changed {
            file,_:=asset.registry_find(w.registry,id)
            info,_:=asset.kind_info(file.kind)
            w.keeping[id]=fmt.tprintf("%s/%s.kept%s",w.imported,base.asset_id_format(id,buffer[:]),info.extension)
            writer_warn(w,"%s changed since its import last wrote it and was left as it is: import %s with discard_changes to write over it",paths[at],w.source)
        }
    case .Discard:
    }
    return true
}

// What the file of a document holds: the content_hash of its header; 0 when
// it is not an asset.
@(private)
written_hash :: proc(file:string) -> u64 {
    head:[asset.HEADER_SIZE]u8
    bytes,_,read_error:=serial.file_read_head(file,head[:])
    if read_error!=.None {return 0}
    header,header_error:=asset.header_read(bytes)
    return header.content_hash if header_error==.None else 0
}

// Records in the sidecar of the source at source what the document id its
// import wrote at file holds (Output.written): for one written once the import
// ended, the prefab of a model.
output_recorded :: proc(source:string,id:base.Asset_Id,file:string) -> bool {
    sidecar,found,error:=sidecar_load(source,context.temp_allocator)
    if !found || error.code!=.None {return false}
    for &output in sidecar.outputs {
        if output.id!=id {continue}
        output.written=written_hash(file)
        return sidecar_save(source,sidecar)
    }
    return false
}

// Ends the outputs of an import that wrote its assets: what its sidecar
// listed and the source no longer gives leaves it (a document stays, a plain
// asset from then on), the files of the imported folder its outputs had under
// another key go, and the sidecar is written with the settings the source was
// imported with. An import of documents alone leaves its stamp (STAMP_EXTENSION).
@(private)
writer_finish :: proc(w:^Writer) -> bool {
    current:=make(map[base.Asset_Id]string,context.temp_allocator)
    for output in w.outputs {
        info,known:=asset.kind_info(output.kind)
        if known && asset.import_cached(output.kind) {current[output.id]=filepath.base(imported_file(w,output.id,info.extension))}
    }
    stamp:=""
    if len(current)==0 && len(w.outputs)>0 {
        stamp=imported_file(w,w.outputs[0].id,STAMP_EXTENSION)
        current[w.outputs[0].id]=filepath.base(stamp)
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
    for _,kept in w.keeping {os.remove(kept)}
    slice.sort(w.inputs[:])
    if !sidecar_save(w.path,{settings=w.report.settings,folder=w.sidecar.folder,inputs=w.inputs,outputs=w.outputs}) {
        return writer_fail(w,.Write,"%s%s, which keeps the ids of the import, could not be written",w.path,SIDECAR_EXTENSION)
    }
    w.report.saved=strings.concatenate({w.path,SIDECAR_EXTENSION},w.allocator)
    // Without it the next sync imports the source again: nothing is lost.
    if stamp!="" {
        _=os.make_directory_all(w.imported)
        _=os.write_entire_file(stamp,nil)
    }
    return true
}

// The first of file (a path under the folder of the import) there, then file
// with " (2)" and on before its extension, that no part of this write took
// and no file has.
@(private)
fresh_path :: proc(w:^Writer,file:string) -> string {
    slash:=strings.last_index_byte(file,'/')
    under,last:=file[:slash+1],file[slash+1:]
    stem,extension:=filepath.stem(last),filepath.ext(last)
    for at:=1;;at+=1 {
        name:=fmt.tprintf("%s%s%s",under,stem,extension) if at==1 else fmt.tprintf("%s%s (%d)%s",under,stem,at,extension)
        key:=strings.to_lower(name,context.temp_allocator)
        joined,_:=filepath.join({w.folder,name},context.temp_allocator)
        candidate,_:=strings.replace_all(joined,"\\","/",context.temp_allocator)
        if w.names[key] || os.exists(candidate) {continue}
        w.names[strings.clone(key,w.keep)]=true
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
