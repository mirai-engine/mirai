package importer

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

// Which asset each part of a source is and where it is written. The manifest
// of the package the source was ingested as (package_previous) says the
// asset: the one of its kind and name (of its kind for the root of the
// import), else a new one. Every part is written to a file of the scratch
// folder of the import and put in the store as an object of its build; a
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
    origin:string,    // the file it is made from apart from the source (an image file, path_key); "": the source
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
    w.documents=strings.clone(folder,w.keep)
    w.origin=path_key(path)
    w.source=filepath.base(w.origin)
    w.inputs.allocator=context.temp_allocator
    w.outputs.allocator=context.temp_allocator
    w.targets.allocator=context.temp_allocator
    w.paths.allocator=context.temp_allocator
    w.origins.allocator=context.temp_allocator
    w.objects.allocator=context.temp_allocator
    w.fixed=false
    s:=w.options.store
    if s==nil {return writer_fail(w,.Write,"%s: an import puts what it builds in a store: give it one (Import_Options.store)",path)}
    previous,manifest,found,error:=package_previous(s,w.options.manifest,w.origin,context.temp_allocator)
    if error.code!=.None {return writer_fail(w,error.code,"%s",error.message)}
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    w.previous=previous
    w.previous_manifest=manifest
    w.stored=found
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
// w.outputs, the assets of the manifest it writes. A part of the kind, name
// and origin of one of the first w.given outputs, or of the kind, name and
// index of a later one, is that one (given): an output is listed once however
// many times it is asked for. Planning a part of the cache fixes what the import is made
// from.
@(private)
parts_plan :: proc(w:^Writer,parts:[]Part) {
    each: for &p in parts {
        if !p.only {
            for output,at in w.outputs {
                if output.kind!=p.kind || output.name!=p.name || at<w.given && w.origins[at]!=p.origin || at>=w.given && output.index!=p.index {continue}
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
        written:u64
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
            if _,keeping:=w.keeping[p.id];keeping {
                // A document the import keeps as it is: its object alone is written.
                p.target=""
            } else {
                if p.target=="" {p.target=fresh_path(w,fmt.tprintf("%s%s",asset.safe_path(p.name),p.extension))}
                if folder:=filepath.dir(p.target);!os.is_dir(folder) {_=os.make_directory_all(folder)}
            }
        }
        p.output=len(w.outputs)
        append(&w.outputs,asset.Package_Asset{kind=p.kind,name=strings.clone(p.name,w.keep),index=p.index,id=p.id})
        append(&w.paths,strings.clone(p.path,w.keep))
        append(&w.targets,strings.clone(p.target,w.keep))
        append(&w.origins,strings.clone(p.origin,w.keep))
        append(&w.objects,store.Hash{})
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

// Takes the file of an output written at file as an object of the build, with the
// owner and the dependencies its header gives, and its document written or
// followed at its target (document_follow). False, with the writer failed,
// when the store does not take it or the target cannot be written.
@(private)
writer_put :: proc(w:^Writer,output:int,file:string) -> bool {
    s:=w.options.store
    object,error:=asset.object_put_file(s,file)
    if error!=.None {return writer_fail(w,.Write,"%s could not be put in the store at %s: %v",file,s.root,error)}
    return writer_take(w,output,object)
}

// What the project's pin records its file of the document id held when the
// import or the refresh last wrote it (asset.Package_Written); 0: nothing.
written_of :: proc(written:[]asset.Package_Written,id:base.Asset_Id) -> u64 {
    for entry in written {
        if entry.id==id {return entry.hash}
    }
    return 0
}

// The documents of the package p that the import or the refresh writes over
// and that changed since it last wrote them: the file of each in registry
// (the assets of the project) holds other content than written records. A
// change of owner alone (asset.detach) is no change. Their ids, in allocator.
documents_changed :: proc(p:^asset.Package,written:[]asset.Package_Written,registry:^asset.Registry,allocator:=context.allocator) -> []base.Asset_Id {
    changed:=make([dynamic]base.Asset_Id,allocator)
    if registry==nil {return changed[:]}
    for &a in p.assets {
        recorded:=written_of(written,a.id)
        if recorded==0 || asset.import_cached(a.kind) {continue}
        if file,found:=asset.registry_find(registry,a.id);found && file.kind==a.kind && written_hash(asset.registry_file_path(registry,file.path,context.temp_allocator))!=recorded {append(&changed,a.id)}
    }
    return changed[:]
}

// Applies Import_Options.changed to the documents of the import that changed
// since it last wrote them: Refuse fails naming them, Keep leaves each as it
// is (Writer.keeping), writing its object alone, and warns of it.
@(private)
writer_changed :: proc(w:^Writer) -> bool {
    if w.folder=="" || w.options.changed==.Discard {return true}
    changed:=documents_changed(&w.previous,w.options.written,w.registry,context.temp_allocator)
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
        w.keeping=make(map[base.Asset_Id]u64,context.temp_allocator)
        for id,at in changed {
            w.keeping[id]=written_of(w.options.written,id)
            writer_warn(w,"%s changed since its import last wrote it and was left as it is: import %s with discard_changes to write over it",paths[at],w.source)
        }
    case .Discard:
    }
    return true
}

// What the file of a document holds: the content_hash of its canonical form
// (asset.document_written_as with Codecs.None), so a file written again with
// other compression holds the same; 0 when it is not an asset.
written_hash :: proc(file:string) -> u64 {
    data,read_error:=serial.file_read(file,context.temp_allocator)
    if read_error!=.None {return 0}
    canonical,error:=asset.document_written_as(data,.None,context.temp_allocator)
    if error!=.None {return 0}
    header,header_error:=asset.header_read(canonical)
    return header.content_hash if header_error==.None else 0
}

// Records in the report what the project's file of the document id holds as
// the import leaves it (Import_Report.written): hash, else, for one it keeps
// as it is, what the pin recorded. A material records nothing: it is followed
// field by field.
@(private)
writer_written :: proc(w:^Writer,id:base.Asset_Id,kind:asset.Fourcc,hash:u64) {
    if kind==asset.KIND_MATERIAL || asset.import_cached(kind) {return}
    hash:=hash
    if recorded,keeping:=w.keeping[id];keeping {hash=recorded}
    if hash!=0 {append(&w.report.written,asset.Package_Written{id,hash})}
}

// Takes the object hash as the output of the build, from the store: its owner and
// dependencies, and its document at its target.
@(private)
writer_take :: proc(w:^Writer,output:int,hash:store.Hash) -> bool {
    s:=w.options.store
    dependencies:=make([dynamic]base.Asset_Id,context.temp_allocator)
    header,peek_error:=asset.object_header(s,hash,&dependencies)
    digits:[64]u8
    if peek_error!=.None {return writer_fail(w,.Write,"the object %s of the store at %s, taken for %s, does not read: %v",store.hex(hash,&digits),s.root,w.outputs[output].name,peek_error)}
    o:=&w.outputs[output]
    w.objects[output]=hash
    baseline:[]u8
    if w.targets[output]!="" || o.kind==asset.KIND_SKELETON {
        read_error:asset.Error
        baseline,read_error=asset.object_file(s,hash,w.keep)
        if read_error!=.None {return writer_fail(w,.Write,"the object %s of the store at %s, taken for %s, does not read: %v",store.hex(hash,&digits),s.root,o.name,read_error)}
    }
    o.owner=header.owner
    o.part=asset.import_cached(o.kind) && header.owner!={}
    o.dependencies=make([dynamic]base.Asset_Id,w.keep)
    for d in dependencies {
        if d!={} && d!=o.id && !slice.contains(o.dependencies[:],d) {append(&o.dependencies,d)}
    }
    if target:=w.targets[output];target!="" {
        existed:=os.exists(target)
        warning,follow_error:=document_follow(&w.types,o.kind,baseline,target,w.followed[:],w.registry,decided=w.report.settings.parts!=.Auto)
        if follow_error!=.None {return save_failed(w,follow_error,target)}
        if warning!="" {writer_warn(w,"%s",warning)}
        if !existed {append(&w.created,strings.clone(target,w.keep))}
        writer_written(w,o.id,o.kind,written_hash(target))
    } else if _,keeping:=w.keeping[o.id];keeping {
        writer_written(w,o.id,o.kind,0)
    }
    if o.kind==asset.KIND_SKELETON {append(&w.followed,Followed_Skeleton{o.id,baseline})}
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

// Removes the documents the import created and the scratch folder; the objects it
// put stay, named by nothing.
@(private)
writer_rollback :: proc(w:^Writer) {
    for path in w.created {os.remove(path)}
}

// Lets the writer go: its types and its scratch folder.
@(private)
writer_close :: proc(w:^Writer) {
    textures.gpu_context_destroy(&w.gpu)
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

// The project or the plugin whose assets folder has the file at path: the
// folder that holds the nearest assets folder above it. False for a file in
// no assets folder.
source_root :: proc(path:string,allocator:=context.allocator) -> (root:string,ok:bool) {
    names:=project.FOLDER_NAMES
    folder:=project.path_absolute(path,context.temp_allocator)
    for {
        parent:=filepath.dir(folder)
        if parent==folder {return}
        if filepath.base(parent)==names[.Assets] {return strings.clone(filepath.dir(parent),allocator),true}
        folder=parent
    }
}

// Where a manifest says its source is (asset.Package_Origin.path), for the
// source at origin (path_key): relative to the root whose assets hold it
// (source_root), so every copy of that root names it alike; else origin. In
// the temp allocator.
origin_of :: proc(origin:string) -> string {
    root,inside:=source_root(origin,context.temp_allocator)
    under:=fmt.tprintf("%s/",path_key(root))
    if !inside || !strings.has_prefix(origin,under) {return origin}
    return origin[len(under):]
}

// The source the origin of a manifest names, as path_key gives it: a relative
// one under root, the project or plugin that pins its package. "" for a
// relative one without a root. In the temp allocator.
origin_path :: proc(origin,root:string) -> string {
    if origin=="" || filepath.is_abs(origin) || strings.has_prefix(origin,"/") {return origin}
    if root=="" {return ""}
    return path_key(fmt.tprintf("%s/%s",root,origin))
}

@(private)
kind_name :: proc(kind:asset.Fourcc) -> string {
    // The scene an import writes has one root: the prefab of its model.
    if kind==asset.KIND_SCENE {return "prefab"}
    if info,found:=asset.kind_info(kind);found {return info.name}
    return "asset"
}
