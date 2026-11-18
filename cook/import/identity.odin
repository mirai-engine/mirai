package importer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"

// Which asset each part of a source is and where it is written. The manifest
// of the package the source was ingested as (package_previous) says the
// asset: the one of its kind and name (of its kind for the root of the
// import), else a new one. Every part is written to a file of the scratch
// folder of the import and put in the store as a blob of its build; a
// document is also written, or followed, in the folder of the documents
// (Import_Options.documents): where the registry of the root has its id, else
// a new file there.

// What an import writes, before its file and id are known.
@(private)
Part :: struct {
    kind:asset.Fourcc,
    name:string,      // in the source: the mesh, the material, the image
    index:int,        // among those of its kind in the source
    extension:string,
    only:bool,        // the one of its kind, whatever its name, as the root (the clips of a model, named after it)
    output:int,       // what the manifest the import writes lists for it (Writer.outputs)
    given:bool,       // an output this import gave before (Writer.given), written then
    decided:bool,     // whether it is a part of the root was decided by an import before: part says it
    part:bool,
    id:base.Asset_Id,
    owner:base.Asset_Id,
    path:string,      // where it is written, in the scratch folder of the import
    target:string,    // of a document: its file in the folder of the documents; "": none
}

// Starts the import of the source at path: the manifest it was ingested as,
// the scratch folder its parts are written in and, with
// options.documents, the folder of the documents (folder under it: where
// those of a first import go, "" in it) and the assets of the root they are
// found among.
@(private)
writer_source :: proc(w:^Writer,path,folder:string) -> bool {
    w.path=path
    w.keep=context.temp_allocator
    w.origin=path_key(path)
    w.source=filepath.base(w.origin)
    w.inputs.allocator=context.temp_allocator
    w.outputs.allocator=context.temp_allocator
    w.targets.allocator=context.temp_allocator
    w.paths.allocator=context.temp_allocator
    w.blobs.allocator=context.temp_allocator
    w.fixed=false
    s:=w.options.store
    if s==nil {return writer_fail(w,.Write,"%s: an import puts what it builds in a store: give it one (Import_Options.store)",path)}
    previous,manifest,found,error:=package_previous(s,w.options.manifest,w.origin,context.temp_allocator)
    if error.code!=.None {return writer_fail(w,error.code,"%s",error.message)}
    w.previous,w.previous_manifest,w.stored=previous,manifest,found
    w.package_id=previous.id if found else writer_id(w)
    w.taken=make([]bool,len(previous.assets),context.temp_allocator)
    if documents:=w.options.documents;documents!="" {
        w.folder=documents if folder=="" else fmt.tprintf("%s/%s",documents,folder)
        w.registry=w.options.registry
        if w.registry==nil && w.options.root!="" {
            w.registry=new(asset.Registry,context.temp_allocator)
            asset.registry_init(w.registry,project.folder_path(w.options.root,.Assets,context.temp_allocator),"",context.temp_allocator)
            asset.registry_scan(w.registry)
        }
    }
    scratch,scratch_error:=os.make_directory_temp("","mirai-import-*",w.keep)
    if scratch_error!=nil {return writer_fail(w,.Write,"%s: the folder its parts are written in before the store takes them could not be made: %v",path,scratch_error)}
    w.scratch=scratch
    return true
}

// The file a part is written to before the store takes it.
@(private)
scratch_path :: proc(w:^Writer,id:base.Asset_Id,extension:string) -> string {
    text:[base.ASSET_ID_TEXT]u8
    return fmt.tprintf("%s/%s%s",w.scratch,base.asset_id_format(id,text[:]),extension)
}

// Notes a file the import reads besides its source, as the manifest lists it.
// False for a new one once what the import is made from is fixed
// (writer_identity).
@(private)
writer_input :: proc(w:^Writer,file:string) -> bool {
    relative,error:=filepath.rel(filepath.dir(w.origin),path_key(file),context.temp_allocator)
    if error!=.None {return true}
    slashed,_:=strings.replace_all(relative,"\\","/",context.temp_allocator)
    if slice.contains(w.inputs[:],slashed) {return true}
    if w.fixed {return false}
    append(&w.inputs,strings.clone(slashed,w.keep))
    return true
}

// Gives each part its asset and its files: the asset of the previous manifest
// of its kind and name (the one of its index first), or of its kind for the
// only one of its kind, else a new id. What the import gives is listed in
// w.outputs, the assets of the manifest it writes. A part of the kind and name
// of one of the first w.given outputs, or of the kind, name and index of a
// later one, is that one (given): an output is listed once however many times
// it is asked for. Planning a part of the cache fixes what the import is made
// from.
@(private)
parts_plan :: proc(w:^Writer,parts:[]Part) {
    each: for &p in parts {
        if !p.only {
            for output,at in w.outputs {
                if output.kind!=p.kind || output.name!=p.name || at>=w.given && output.index!=p.index {continue}
                p.id,p.output,p.path,p.target,p.given=output.id,at,w.paths[at],w.targets[at],true
                continue each
            }
        }
        entry:=-1
        for a,at in w.previous.assets {
            if w.taken[at] || a.kind!=p.kind || !p.only && a.name!=p.name {continue}
            entry=at
            if p.only || a.index==p.index {break}
        }
        p.id=writer_id(w)
        if entry>=0 {
            w.taken[entry]=true
            a:=w.previous.assets[entry]
            p.id,p.decided=a.id,true
            p.part=a.part if asset.import_cached(p.kind) else a.owner!={}
        }
        p.path=scratch_path(w,p.id,p.extension)
        p.target=""
        if asset.import_cached(p.kind) {
            writer_identity(w)
        } else if w.folder!="" {
            if w.registry!=nil {
                if file,found:=asset.registry_find(w.registry,p.id);found && file.kind==p.kind {p.target=asset.registry_file_path(w.registry,file.path,context.temp_allocator)}
            }
            if p.target=="" {p.target=fresh_path(w,fmt.tprintf("%s%s",asset.safe_path(p.name),p.extension))}
            if folder:=filepath.dir(p.target);!os.is_dir(folder) {_=os.make_directory_all(folder)}
        }
        p.output=len(w.outputs)
        append(&w.outputs,asset.Package_Asset{kind=p.kind,name=strings.clone(p.name,w.keep),index=p.index,id=p.id})
        append(&w.paths,strings.clone(p.path,w.keep))
        append(&w.targets,strings.clone(p.target,w.keep))
        append(&w.blobs,store.Hash{})
    }
}

// The id, the file and the output of the root of an import: the asset of
// kind the previous manifest lists, else a new one named name.
@(private)
root_take :: proc(w:^Writer,kind:asset.Fourcc,name,extension:string) -> (id:base.Asset_Id,path:string,output:int) {
    parts:=[1]Part{{kind=kind,name=name,extension=extension,only=true}}
    parts_plan(w,parts[:])
    return parts[0].id,parts[0].path,parts[0].output
}

// Takes the file of an output written at file as a blob of the build, with the
// owner and the dependencies its header gives, and its document written or
// followed at its target (document_follow). False, with the writer failed,
// when the store does not take it or the target cannot be written.
@(private)
writer_put :: proc(w:^Writer,output:int,file:string) -> bool {
    s:=w.options.store
    hash,error:=store.put_file(s,file)
    if error!=.None {return writer_fail(w,.Write,"%s could not be put in the store at %s: %v",file,s.root,error)}
    return writer_take(w,output,hash)
}

// Takes the blob hash as the output of the build, from the store: its owner and
// dependencies, and its document at its target.
@(private)
writer_take :: proc(w:^Writer,output:int,hash:store.Hash) -> bool {
    s:=w.options.store
    blob,path_error:=store.blob_path(s,hash,context.temp_allocator)
    if path_error!=.None {return writer_fail(w,.Write,"the store at %s does not have the blob it took: %v",s.root,path_error)}
    dependencies:=make([dynamic]base.Asset_Id,context.temp_allocator)
    header,_,_,peek_error:=asset.import_peek(blob,&w.types,&dependencies)
    if peek_error!=.None {return writer_fail(w,.Write,"%s, written for %s, does not read: %v",blob,w.outputs[output].name,peek_error)}
    o:=&w.outputs[output]
    w.blobs[output]=hash
    o.owner=header.owner
    o.part=asset.import_cached(o.kind) && header.owner!={}
    o.dependencies=make([dynamic]base.Asset_Id,w.keep)
    for d in dependencies {
        if d!={} && d!=o.id && !slice.contains(o.dependencies[:],d) {append(&o.dependencies,d)}
    }
    if target:=w.targets[output];target!="" {
        existed:=os.exists(target)
        warning,follow_error:=document_follow(&w.types,o.kind,blob,target,w.followed[:],w.registry,decided=w.report.settings.parts!=.Auto)
        if follow_error!=.None {return save_failed(w,follow_error,target)}
        if warning!="" {writer_warn(w,"%s",warning)}
        if !existed {append(&w.created,strings.clone(target,w.keep))}
    }
    if o.kind==asset.KIND_SKELETON {append(&w.followed,Followed_Skeleton{o.id,strings.clone(blob,w.keep)})}
    return true
}

// Ends the outputs of an import that wrote its assets: what the previous
// manifest listed and the source no longer gives leaves the package (a
// document stays, a plain asset from then on), and the manifest and the build
// are put in the store and named (writer_publish).
@(private)
writer_finish :: proc(w:^Writer,name,importer:string) -> bool {
    for a,at in w.previous.assets {
        if w.taken[at] {continue}
        if asset.import_cached(a.kind) {
            writer_warn(w,"%s %s is no longer in the source: its asset is gone, and what named it names nothing",kind_name(a.kind),a.name)
        } else if w.registry!=nil {
            if file,found:=asset.registry_find(w.registry,a.id);found {writer_warn(w,"%s is no longer in the source: it was left as it is",file.path)}
        }
    }
    return writer_publish(w,name,importer)
}

// Removes the documents the import created and the scratch folder; the blobs it
// put stay, named by nothing.
@(private)
writer_rollback :: proc(w:^Writer) {
    for path in w.created {os.remove(path)}
}

// Lets the writer go: its types and its scratch folder.
@(private)
writer_close :: proc(w:^Writer) {
    if w.scratch!="" {_=os.remove_all(w.scratch)}
    asset.types_destroy(&w.types)
}

// The first of file (a path under the folder of the documents) there, then
// file with " (2)" and on before its extension, that no part of this write
// took and no file has.
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

// An absolute path with forward slashes: how files are compared, and the
// origin of a package (asset.Package_Origin.path).
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
