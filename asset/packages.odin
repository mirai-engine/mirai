package asset

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

// The records of the imports kept in the machine store, as text:
//
// - Package: what one ingest of a source made, an object of the store pinned
//   by the BLAKE3 of its text, which the ref REF_MANIFESTS/<that hash> names.
//   Its id, where the source was, what the source and its settings are
//   (identity) and each asset with its id. Nothing in it depends on the
//   version of the engine. The import that ingests the source writes it and
//   names it with the ref REF_PACKAGES/<id>.
// - Build: the object of each asset of one build of a package. The import that
//   builds it writes it, names it with REF_IMPORTS/<import_key> (Final) or
//   REF_IMPORTS_FAST/<import_key>, and the refresh of a project names the one
//   it chose with REF_BUILDS/<build_select>, which a program that has no
//   importer finds.
// - Packages: the list of a project (PACKAGES_FILE, beside its manifest),
//   versioned: the packages it uses by the hash of their manifest, the folder
//   of its assets each is listed in, the assets it uses and what its file of
//   each document held when an import or a refresh last wrote it. Beside it, in
//   PACKAGE_FILES, the text of each manifest it pins (package_file), so the
//   root carries what its pins name: a store without a manifest takes it from
//   there. The library of cook/import/sources writes both.
//
// What a parse gives lives in its allocator, an arena: nothing frees it piece
// by piece. A text that is not a record of its version is an error, never a
// default.

PACKAGES_FILE :: "packages.mirai"
PACKAGE_FILES :: "packages" // the folder of a root, beside PACKAGES_FILE, with <package id>.mirai of each manifest it pins
PACKAGES_VERSION :: 2
PACKAGE_MANIFEST_VERSION :: 1
BUILD_MANIFEST_VERSION :: 4
RECORD_BYTES :: 16<<20 // the most a record takes as text: a larger one is refused unread

// Namespaces of the refs of the records.
REF_PACKAGES :: "packages"         // <package id>: its manifest, on a machine that ingested it
REF_MANIFESTS :: "manifests"       // <BLAKE3 of the text of a manifest>: its object, what a pin names
REF_IMPORTS :: "imports"           // <import_key>: a build with Final textures, which peers share
REF_IMPORTS_FAST :: "imports-fast" // <import_key>: a build with Fast textures, which peers share and a cook never takes
REF_BUILDS :: "builds"             // <build_select>: the build the refresh of this machine chose

REF_CACHE_PREFIX :: "cache-"       // and the name of a folder of cook/cache: <key>-<version>
REF_ORIGINS :: "origins"           // <origin_name>: the manifest of the package its source was ingested as on this machine
REF_SOURCES :: "sources"           // <origin_name>: what the files of that source were when last read, never shared
IMPORT_KEY_VERSIONS :: 32          // the most versions an import key combines

// Where the source of a package was when it was ingested: a hint to ingest it
// again, not part of what it is.
Package_Origin :: struct {
    path:string,     // relative to the root whose assets hold it, alike in every copy of it; else absolute
    folder:bool,     // the source is a folder (an Unreal package), not a file
    importer:string, // the format or the importer of a plugin that reads it
}

Package_Asset :: struct {
    kind:Fourcc,
    name:string, // in the source: the mesh, the material, the image
    index:int,   // among those of its kind in the source
    id:base.Asset_Id,
    part:bool,   // a part of the root of the package, decided when it was first ingested
    owner:base.Asset_Id,
    dependencies:[dynamic]base.Asset_Id,
}

Package :: struct {
    id:base.Asset_Id,
    name:string,
    origin:Package_Origin,
    identity:store.Hash,      // of the bytes of the source and its inputs, its settings and the code of the plugin that reads it
    settings:string,          // the text of the settings object; "" without one
    inputs:[dynamic]string,   // the files the import read besides the source, from its folder
    assets:[dynamic]Package_Asset,
}

Build_Output :: struct {
    id:base.Asset_Id,
    kind:Fourcc,
    kind_version:u16,
    object:store.Hash,    // of the asset (object_put)
    thumbnail:store.Hash, // an object of its bytes; zero: none
}

Build :: struct {
    package_id:base.Asset_Id,
    key:store.Hash,  // import_key of what built it
    final:bool,      // its textures are Final, else Fast
    outputs:[dynamic]Build_Output,
}

Project_Package :: struct {
    id:base.Asset_Id,
    manifest:store.Hash,
    folder:string,                 // of the assets of the project, where its assets are listed; "": the top
    assets:[dynamic]base.Asset_Id, // those the project uses, with what they depend on; none: all
    written:[dynamic]Package_Written,
}

// A document of a package whose file in the project the import or the
// refresh writes over: the content_hash of the header of that file as it last
// wrote it, so a file that holds anything else was changed since. A document
// followed field by field (a material) has none: what a person changed in it
// stays.
Package_Written :: struct {
    id:base.Asset_Id,
    hash:u64,
}

Packages :: struct {
    packages:[dynamic]Project_Package,
}

// What a program reads, as one value: the identity of a package and the
// versions of what imports it and writes its assets. Any machine that has the
// manifest computes it, without the source. ok is false with more than
// IMPORT_KEY_VERSIONS versions.
import_key :: proc(identity:store.Hash,versions:[]u64) -> (key:store.Hash,ok:bool) {
    TAG :: "mirai import key"
    if len(versions)>IMPORT_KEY_VERSIONS {return}
    bytes:[len(TAG)+1+size_of(store.Hash)+8*IMPORT_KEY_VERSIONS]u8
    n:=copy(bytes[:],TAG)
    bytes[n]=u8(len(versions))
    n+=1
    identity:=identity
    n+=copy(bytes[n:],identity[:])
    for version in versions {n+=word_put(bytes[n:],version,8)}
    return store.address_of_bytes(bytes[:n]),true
}

// The name of the build of the manifest with hash manifest that a program
// reads: the version of each kind of the cache its assets are of, as this
// program reads it. The refresh of a project names its choice so; a program
// without importers finds it by the same name.
build_select :: proc(manifest:store.Hash,p:^Package) -> store.Hash {
    TAG :: "mirai build select"
    bytes:[len(TAG)+size_of(store.Hash)+6*len(KINDS)]u8
    n:=copy(bytes[:],TAG)
    manifest:=manifest
    n+=copy(bytes[n:],manifest[:])
    for info in KINDS {
        if !import_cached(info.kind) {continue}
        for &a in p.assets {
            if a.kind!=info.kind {continue}
            n+=word_put(bytes[n:],u64(info.kind),4)
            n+=word_put(bytes[n:],u64(info.version),2)
            break
        }
    }
    return store.address_of_bytes(bytes[:n])
}

// The namespace of the refs of a folder of cook/cache, in buffer; "" for a
// name that does not fit.
cache_namespace :: proc(name:string,buffer:^[store.NAME_MAX]u8) -> string {
    if len(REF_CACHE_PREFIX)+len(name)>store.NAME_MAX {return ""}
    n:=copy(buffer[:],REF_CACHE_PREFIX)
    n+=copy(buffer[n:],name)
    return string(buffer[:n])
}

// The name of the refs REF_ORIGINS and REF_SOURCES of the source at origin
// (an absolute path with forward slashes), in buffer.
origin_name :: proc(origin:string,buffer:^[64]u8) -> string {
    return store.hex(store.address_of_bytes(transmute([]u8)origin),buffer)
}

@(private="file")
word_put :: proc(out:[]u8,value:u64,size:int) -> int {
    for i in 0..<size {out[i]=u8(value>>uint(8*i))}
    return size
}

// The text of a manifest; .Invalid for one that would not read back as it is.
package_text :: proc(p:^Package,allocator:=context.allocator) -> (text:string,error:Error) {
    if !package_valid(p) {return "",.Invalid}
    w:serial.Writer
    serial.writer_init(&w,1024,allocator)
    serial.text_write_raw(&w,"{\n  \"version\": ")
    serial.text_write_int(&w,PACKAGE_MANIFEST_VERSION)
    serial.text_write_raw(&w,",\n  \"id\": ")
    id_write(&w,p.id)
    serial.text_write_raw(&w,",\n  \"name\": ")
    serial.text_write_string(&w,p.name)
    serial.text_write_raw(&w,",\n  \"origin\": {\"path\": ")
    serial.text_write_string(&w,p.origin.path)
    serial.text_write_raw(&w,p.origin.folder?", \"folder\": true, \"importer\": ":", \"folder\": false, \"importer\": ")
    serial.text_write_string(&w,p.origin.importer)
    serial.text_write_raw(&w,"},\n  \"identity\": ")
    hash_write(&w,p.identity)
    if p.settings!="" {
        serial.text_write_raw(&w,",\n  \"settings\": ")
        serial.text_write_raw(&w,p.settings)
    }
    serial.text_write_raw(&w,",\n  \"inputs\": [")
    for input,at in p.inputs {
        if at>0 {serial.text_write_raw(&w,", ")}
        serial.text_write_string(&w,input)
    }
    serial.text_write_raw(&w,"],\n  \"assets\": [")
    for &a,at in p.assets {
        serial.text_write_raw(&w,at>0?",\n    {\"kind\": ":"\n    {\"kind\": ")
        kind_write(&w,a.kind)
        serial.text_write_raw(&w,", \"name\": ")
        serial.text_write_string(&w,a.name)
        serial.text_write_raw(&w,", \"index\": ")
        serial.text_write_int(&w,i64(a.index))
        serial.text_write_raw(&w,", \"id\": ")
        id_write(&w,a.id)
        if a.part {serial.text_write_raw(&w,", \"part\": true")}
        if a.owner!={} {
            serial.text_write_raw(&w,", \"owner\": ")
            id_write(&w,a.owner)
        }
        if len(a.dependencies)>0 {
            serial.text_write_raw(&w,", \"dependencies\": [")
            for d,i in a.dependencies {
                if i>0 {serial.text_write_raw(&w,", ")}
                id_write(&w,d)
            }
            serial.text_write_raw(&w,"]")
        }
        serial.text_write_raw(&w,"}")
    }
    serial.text_write_raw(&w,len(p.assets)>0?"\n  ]\n}\n":"]\n}\n")
    return writer_text(&w)
}

package_parse :: proc(text:string,allocator:=context.allocator) -> (p:Package,error:Error) {
    if len(text)>RECORD_BYTES {return {},.Too_Large}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    p.inputs=make([dynamic]string,allocator)
    p.assets=make([dynamic]Package_Asset,allocator)
    Field :: enum {Version,Id,Name,Origin,Identity,Settings,Inputs,Assets}
    seen:bit_set[Field]
    version:u64
    expect(&r,'{') or_return
    for first:=true;!serial.text_accept(&r,'}');first=false {
        if !first {expect(&r,',') or_return}
        name:=key(&r) or_return
        field:Field
        switch name {
        case "version": field=.Version
        case "id": field=.Id
        case "name": field=.Name
        case "origin": field=.Origin
        case "identity": field=.Identity
        case "settings": field=.Settings
        case "inputs": field=.Inputs
        case "assets": field=.Assets
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Version: version=count_read(&r,max(u64)) or_return
        case .Id: p.id=id_read(&r) or_return
        case .Name: p.name=string_read(&r,allocator) or_return
        case .Origin: p.origin=origin_read(&r,allocator) or_return
        case .Identity: p.identity=hash_read(&r) or_return
        case .Settings:
            serial.text_space(&r)
            start:=r.offset
            if serial.text_peek(&r)!='{' || !serial.text_skip(&r) {return {},.Corrupt}
            p.settings=clone(text[start:r.offset],allocator) or_return
        case .Inputs:
            expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {expect(&r,',') or_return}
                input:=string_read(&r,allocator) or_return
                if _,no_room:=append(&p.inputs,input);no_room!=nil {return {},.Out_Of_Memory}
            }
        case .Assets:
            expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {expect(&r,',') or_return}
                a:=asset_read(&r,allocator) or_return
                if _,no_room:=append(&p.assets,a);no_room!=nil {return {},.Out_Of_Memory}
            }
        }
    }
    if !serial.text_end(&r) {return {},.Corrupt}
    if version!=PACKAGE_MANIFEST_VERSION {return {},.Version}
    if seen!={.Version,.Id,.Name,.Origin,.Identity,.Inputs,.Assets} && seen!={.Version,.Id,.Name,.Origin,.Identity,.Settings,.Inputs,.Assets} {return {},.Corrupt}
    if !package_valid(&p) {return {},.Corrupt}
    return p,.None
}

// The text of a build manifest; .Invalid for one that would not read back as it is.
build_text :: proc(b:^Build,allocator:=context.allocator) -> (text:string,error:Error) {
    if !build_valid(b) {return "",.Invalid}
    w:serial.Writer
    serial.writer_init(&w,512,allocator)
    serial.text_write_raw(&w,"{\n  \"version\": ")
    serial.text_write_int(&w,BUILD_MANIFEST_VERSION)
    serial.text_write_raw(&w,",\n  \"package\": ")
    id_write(&w,b.package_id)
    serial.text_write_raw(&w,",\n  \"key\": ")
    hash_write(&w,b.key)
    serial.text_write_raw(&w,b.final?",\n  \"final\": true":",\n  \"final\": false")
    serial.text_write_raw(&w,",\n  \"outputs\": [")
    for o,at in b.outputs {
        serial.text_write_raw(&w,at>0?",\n    {\"id\": ":"\n    {\"id\": ")
        id_write(&w,o.id)
        serial.text_write_raw(&w,", \"kind\": ")
        kind_write(&w,o.kind)
        serial.text_write_raw(&w,", \"kind_version\": ")
        serial.text_write_int(&w,i64(o.kind_version))
        serial.text_write_raw(&w,", \"object\": ")
        hash_write(&w,o.object)
        if o.thumbnail!={} {
            serial.text_write_raw(&w,", \"thumbnail\": ")
            hash_write(&w,o.thumbnail)
        }
        serial.text_write_raw(&w,"}")
    }
    serial.text_write_raw(&w,len(b.outputs)>0?"\n  ]\n}\n":"]\n}\n")
    return writer_text(&w)
}

build_parse :: proc(text:string,allocator:=context.allocator) -> (b:Build,error:Error) {
    if len(text)>RECORD_BYTES {return {},.Too_Large}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    b.outputs=make([dynamic]Build_Output,allocator)
    Field :: enum {Version,Package,Key,Final,Outputs}
    seen:bit_set[Field]
    version:u64
    expect(&r,'{') or_return
    for first:=true;!serial.text_accept(&r,'}');first=false {
        if !first {expect(&r,',') or_return}
        name:=key(&r) or_return
        field:Field
        switch name {
        case "version": field=.Version
        case "package": field=.Package
        case "key": field=.Key
        case "final": field=.Final
        case "outputs": field=.Outputs
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Version: version=count_read(&r,max(u64)) or_return
        case .Package: b.package_id=id_read(&r) or_return
        case .Key: b.key=hash_read(&r) or_return
        case .Final: b.final=bool_read(&r) or_return
        case .Outputs:
            expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {expect(&r,',') or_return}
                o:=output_read(&r) or_return
                if _,no_room:=append(&b.outputs,o);no_room!=nil {return {},.Out_Of_Memory}
            }
        }
    }
    if !serial.text_end(&r) {return {},.Corrupt}
    if version!=BUILD_MANIFEST_VERSION {return {},.Version}
    if seen!={.Version,.Package,.Key,.Final,.Outputs} {return {},.Corrupt}
    if !build_valid(&b) {return {},.Corrupt}
    return b,.None
}

// The text of the list of a project; .Invalid for one that would not read back as it is.
packages_text :: proc(list:^Packages,allocator:=context.allocator) -> (text:string,error:Error) {
    if !packages_valid(list) {return "",.Invalid}
    w:serial.Writer
    serial.writer_init(&w,256,allocator)
    serial.text_write_raw(&w,"{\n  \"version\": ")
    serial.text_write_int(&w,PACKAGES_VERSION)
    serial.text_write_raw(&w,",\n  \"packages\": [")
    for &entry,at in list.packages {
        serial.text_write_raw(&w,at>0?",\n    {\"id\": ":"\n    {\"id\": ")
        id_write(&w,entry.id)
        serial.text_write_raw(&w,", \"manifest\": ")
        hash_write(&w,entry.manifest)
        serial.text_write_raw(&w,", \"folder\": ")
        serial.text_write_string(&w,entry.folder)
        serial.text_write_raw(&w,", \"assets\": [")
        for id,i in entry.assets {
            if i>0 {serial.text_write_raw(&w,", ")}
            id_write(&w,id)
        }
        serial.text_write_raw(&w,"], \"written\": [")
        for written,i in entry.written {
            serial.text_write_raw(&w,i>0?", {\"id\": ":"{\"id\": ")
            id_write(&w,written.id)
            serial.text_write_raw(&w,", \"hash\": \"")
            serial.text_write_hex(&w,written.hash,16,false)
            serial.text_write_raw(&w,"\"}")
        }
        serial.text_write_raw(&w,"]}")
    }
    serial.text_write_raw(&w,len(list.packages)>0?"\n  ]\n}\n":"]\n}\n")
    return writer_text(&w)
}

packages_parse :: proc(text:string,allocator:=context.allocator) -> (list:Packages,error:Error) {
    if len(text)>RECORD_BYTES {return {},.Too_Large}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    list.packages=make([dynamic]Project_Package,allocator)
    Field :: enum {Version,Packages}
    seen:bit_set[Field]
    version:u64
    expect(&r,'{') or_return
    for first:=true;!serial.text_accept(&r,'}');first=false {
        if !first {expect(&r,',') or_return}
        name:=key(&r) or_return
        field:Field
        switch name {
        case "version": field=.Version
        case "packages": field=.Packages
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Version: version=count_read(&r,max(u64)) or_return
        case .Packages:
            expect(&r,'[') or_return
            for begun:=false;!serial.text_accept(&r,']');begun=true {
                if begun {expect(&r,',') or_return}
                entry:=entry_read(&r,allocator) or_return
                if _,no_room:=append(&list.packages,entry);no_room!=nil {return {},.Out_Of_Memory}
            }
        }
    }
    if !serial.text_end(&r) {return {},.Corrupt}
    if version!=PACKAGES_VERSION {return {},.Version}
    if seen!={.Version,.Packages} || !packages_valid(&list) {return {},.Corrupt}
    return list,.None
}

// The list of the project at root, in allocator. found is false, with an
// empty list, when the project has none.
packages_load :: proc(root:string,allocator:=context.allocator) -> (list:Packages,found:bool,error:Error) {
    path:=fmt.tprintf("%s/%s",root,PACKAGES_FILE)
    data,read_error:=serial.file_read(path,context.temp_allocator,limit=RECORD_BYTES)
    if read_error==.Not_Found {
        list.packages=make([dynamic]Project_Package,allocator)
        return list,false,.None
    }
    if read_error!=.None {return {},false,file_error(read_error)}
    list,error=packages_parse(string(data),allocator)
    return list,error==.None,error
}

// Writes the list of the project at root, unless its file already says the same.
packages_save :: proc(root:string,list:^Packages) -> Error {
    text:=packages_text(list,context.temp_allocator) or_return
    path:=fmt.tprintf("%s/%s",root,PACKAGES_FILE)
    _,write_error:=serial.file_write_changed(path,transmute([]u8)text)
    return file_error(write_error)
}

// The file of root that holds the text of the manifest of the package id it
// pins, in the temp allocator.
package_file :: proc(root:string,id:base.Asset_Id) -> string {
    buffer:[base.ASSET_ID_TEXT]u8
    return fmt.tprintf("%s/%s/%s.mirai",root,PACKAGE_FILES,base.asset_id_format(id,buffer[:]))
}

// Writes the manifest the store keeps under entry.manifest to the file of
// root for its package, unless the file already holds it. .Corrupt when that
// object is not a manifest of the package entry names.
package_file_save :: proc(s:^store.Store,root:string,entry:^Project_Package) -> Error {
    text:=manifest_get(s,entry.manifest) or_return
    p:=package_parse(text,context.temp_allocator) or_return
    if p.id!=entry.id {return .Corrupt}
    path:=package_file(root,entry.id)
    if folder:=fmt.tprintf("%s/%s",root,PACKAGE_FILES);!os.is_dir(folder) && os.make_directory_all(folder)!=nil {return .IO}
    _,write_error:=serial.file_write_changed(path,transmute([]u8)text)
    return file_error(write_error)
}

// Removes the file of root for the package id; .None also when it has none.
package_file_remove :: proc(root:string,id:base.Asset_Id) -> Error {
    path:=package_file(root,id)
    if !os.exists(path) {return .None}
    return .None if os.remove(path)==nil else .IO
}

// The manifest a root pins with entry: the one the store keeps, else the file
// of root for it (package_file), which then goes into the store. A file that
// is there must hold the bytes of the address entry pins: .Hash when it does
// not, also when the store has the manifest. .Not_Found when neither has it.
// root "": the store alone. In allocator, an arena.
package_load :: proc(s:^store.Store,root:string,entry:^Project_Package,allocator:=context.allocator) -> (p:Package,error:Error) {
    file:[]u8
    kept:=false
    if root!="" {
        read_error:serial.File_Error
        file,read_error=serial.file_read(package_file(root,entry.id),context.temp_allocator,limit=RECORD_BYTES)
        #partial switch read_error {
        case .None:
            if store.address_of_bytes(file)!=entry.manifest {return {},.Hash}
            kept=true
        case .Not_Found:
        case: return {},file_error(read_error)
        }
    }
    p,error=package_get(s,entry.manifest,allocator)
    if error==.Not_Found && kept {
        p,error=package_parse(string(file),allocator)
        if error!=.None {return {},error}
        manifest_put(s,file) or_return
    }
    if error==.None && p.id!=entry.id {return {},.Corrupt}
    return
}

// Keeps a manifest in the store: hash, what pins it, is the BLAKE3 of its text.
package_put :: proc(s:^store.Store,p:^Package) -> (hash:store.Hash,error:Error) {
    text:=package_text(p,context.temp_allocator) or_return
    return manifest_put(s,transmute([]u8)text)
}

// The manifest the store keeps under the hash of its text, in allocator. .Not_Found without it.
package_get :: proc(s:^store.Store,hash:store.Hash,allocator:=context.allocator) -> (p:Package,error:Error) {
    text:=manifest_get(s,hash) or_return
    return package_parse(text,allocator)
}

// Keeps the text of a manifest as an object named by the ref REF_MANIFESTS/<its BLAKE3>, committed.
@(private="file")
manifest_put :: proc(s:^store.Store,text:[]u8) -> (hash:store.Hash,error:Error) {
    hash=store.address_of_bytes(text)
    object:=record_put(s,text) or_return
    digits:[64]u8
    return hash,store_error(store.ref_set(s,REF_MANIFESTS,store.hex(hash,&digits),object))
}

// The text of the manifest pinned by hash, only when it still hashes to it, in the temp allocator.
@(private="file")
manifest_get :: proc(s:^store.Store,hash:store.Hash) -> (text:string,error:Error) {
    digits:[64]u8
    object,ref_error:=store.ref_get(s,REF_MANIFESTS,store.hex(hash,&digits))
    if ref_error!=.None {return "",store_error(ref_error)}
    text=record_get(s,object) or_return
    if store.address_of_bytes(transmute([]u8)text)!=hash {return "",.Hash}
    return text,.None
}

// Keeps a build in the store: the address of its object, which refs name.
build_put :: proc(s:^store.Store,b:^Build) -> (object:store.Hash,error:Error) {
    text:=build_text(b,context.temp_allocator) or_return
    return record_put(s,transmute([]u8)text)
}

build_get :: proc(s:^store.Store,object:store.Hash,allocator:=context.allocator) -> (b:Build,error:Error) {
    text:=record_get(s,object) or_return
    return build_parse(text,allocator)
}

// Puts the text of a record as an object, without committing: the ref that names it commits it.
record_put :: proc(s:^store.Store,text:[]u8) -> (object:store.Hash,error:Error) {
    if len(text)>RECORD_BYTES {return {},.Too_Large}
    put_error:store.Error
    object,put_error=store.put(s,text)
    return object,store_error(put_error)
}

Listed_State :: enum u8 {
    Built,
    Not_Built, // no build this program reads: a machine with the source, or a peer that built it, gives it
}

// An asset of the cache a project lists from its packages.
Package_Listed :: struct {
    path:string,   // in the registry: <folder>/<name><extension>, as listed_path makes it
    object:store.Hash, // the object of the store that holds it; zero when not built
    id:base.Asset_Id,
    kind:Fourcc,
    package_id:base.Asset_Id,
    state:Listed_State,
    header:Header, // of the object when built: zero when it does not read
    dependencies:[]base.Asset_Id, // what its header and directory name, when built
}

Package_Problem_Code :: enum u8 {
    Manifest_Missing,    // neither the store nor the root has the manifest the project names
    Manifest_Unreadable, // the one there is not a manifest of this version, or of another package
    Manifest_Mismatch,   // the file of the root for it (package_file) is not the manifest it pins
    Build_Unreadable,    // the build its ref names is missing or does not read: its assets are not built
    Asset_Unknown,       // the project uses an asset its manifest does not have
}

Package_Problem :: struct {
    package_id:base.Asset_Id,
    asset:base.Asset_Id, // Asset_Unknown: the one the project names
    code:Package_Problem_Code,
}

Packages_Resolved :: struct {
    listed:[dynamic]Package_Listed,
    problems:[dynamic]Package_Problem,
    packages:[dynamic]Resolved_Package, // each one whose manifest read, in the order of the list
}

// A package a root uses, by what its manifest says of it.
Resolved_Package :: struct {
    id:base.Asset_Id,
    name:string,
    origin:Package_Origin,
    inputs:[]string, // the files the import read besides the source, from its folder
}

// What a project lists from the packages it uses: each asset of the cache it
// uses, with what they depend on, at its path, and the object of the build
// REF_BUILDS names for its manifest, or Not_Built. Documents are files of the
// project and are not listed. The manifests come from the store or from the
// files of root (package_load; "": the store alone). A manifest or a build
// that is not there or does not read is a problem of the result, never an
// error; nothing is removed, built or fetched. Two packages that list one path take the name of
// their package after it, "<name> (<package>)". In allocator, an arena; error
// only when memory runs out.
packages_resolve :: proc(s:^store.Store,root:string,list:^Packages,allocator:=context.allocator) -> (resolved:Packages_Resolved,error:Error) {
    resolved.listed=make([dynamic]Package_Listed,allocator)
    resolved.problems=make([dynamic]Package_Problem,allocator)
    resolved.packages=make([dynamic]Resolved_Package,allocator)
    names:=make([dynamic]string,context.temp_allocator)
    for &entry in list.packages {
        p,manifest_error:=package_load(s,root,&entry,context.temp_allocator)
        #partial switch manifest_error {
        case .None:
        case .Out_Of_Memory: return {},.Out_Of_Memory
        case .Not_Found: problem_add(&resolved,{entry.id,{},.Manifest_Missing}) or_return
        case .Hash: problem_add(&resolved,{entry.id,{},.Manifest_Mismatch}) or_return
        case: problem_add(&resolved,{entry.id,{},.Manifest_Unreadable}) or_return
        }
        if manifest_error!=.None {continue}
        named:=Resolved_Package{id=p.id,origin={folder=p.origin.folder}}
        named.name=clone(p.name,allocator) or_return
        named.origin.path=clone(p.origin.path,allocator) or_return
        named.origin.importer=clone(p.origin.importer,allocator) or_return
        inputs,no_inputs:=make([]string,len(p.inputs),allocator)
        if no_inputs!=nil {return {},.Out_Of_Memory}
        for input,at in p.inputs {inputs[at]=clone(input,allocator) or_return}
        named.inputs=inputs
        if _,no_room:=append(&resolved.packages,named);no_room!=nil {return {},.Out_Of_Memory}
        used,no_used:=make([]bool,len(p.assets),context.temp_allocator)
        by_id:=make(map[base.Asset_Id]int,context.temp_allocator)
        if no_used!=nil || reserve(&by_id,len(p.assets))!=nil {return {},.Out_Of_Memory}
        for &a,at in p.assets {by_id[a.id]=at}
        if len(entry.assets)==0 {
            for &u in used {u=true}
        } else {
            pending:=make([dynamic]int,context.temp_allocator)
            for id in entry.assets {
                at,known:=by_id[id]
                if !known {
                    problem_add(&resolved,{entry.id,id,.Asset_Unknown}) or_return
                    continue
                }
                if _,no_room:=append(&pending,at);no_room!=nil {return {},.Out_Of_Memory}
            }
            for len(pending)>0 {
                at:=pop(&pending)
                if used[at] {continue}
                used[at]=true
                for d in p.assets[at].dependencies {
                    if next,known:=by_id[d];known && !used[next] {
                        if _,no_room:=append(&pending,next);no_room!=nil {return {},.Out_Of_Memory}
                    }
                }
            }
        }
        outputs:=make(map[base.Asset_Id]Build_Output,context.temp_allocator)
        digits:[64]u8
        built,ref_error:=store.ref_get(s,REF_BUILDS,store.hex(build_select(entry.manifest,&p),&digits))
        switch ref_error {
        case .None:
            b,build_error:=build_get(s,built,context.temp_allocator)
            if build_error==.Out_Of_Memory {return {},.Out_Of_Memory}
            if build_error==.None && b.package_id!=p.id {build_error=.Corrupt}
            if build_error!=.None {
                problem_add(&resolved,{entry.id,{},.Build_Unreadable}) or_return
                break
            }
            if reserve(&outputs,len(b.outputs))!=nil {return {},.Out_Of_Memory}
            for o in b.outputs {outputs[o.id]=o}
        case .Missing:
        case .Out_Of_Memory: return {},.Out_Of_Memory
        case .Corrupt,.Invalid_Argument,.Io,.No_Space,.Unsupported_Layout:
            problem_add(&resolved,{entry.id,{},.Build_Unreadable}) or_return
        }
        folder:=entry.folder!=""?fmt.tprintf("%s/",entry.folder):""
        for &a,at in p.assets {
            info,known:=kind_info(a.kind)
            if !used[at] || !known || !import_cached(a.kind) {continue}
            repeated:=false
            for &other in p.assets {repeated||=other.kind==a.kind && other.name==a.name && other.index<a.index}
            listed:=Package_Listed{id=a.id,kind=a.kind,package_id=p.id,state=.Not_Built}
            listed.path=clone(listed_path(folder,a.name,a.index,repeated,info.extension),allocator) or_return
            if o,found:=outputs[a.id];found && o.kind==a.kind && o.kind_version==info.version {
                dependencies:=make([dynamic]base.Asset_Id,allocator)
                header,header_error:=object_header(s,o.object,&dependencies)
                #partial switch header_error {
                case .Out_Of_Memory: return {},.Out_Of_Memory
                case .Not_Here:
                case .None: listed.object,listed.state,listed.header,listed.dependencies=o.object,.Built,header,dependencies[:]
                // An object that does not read is listed for the registry to tell it is broken.
                case: listed.object,listed.state=o.object,.Built
                }
            }
            if _,no_room:=append(&resolved.listed,listed);no_room!=nil {return {},.Out_Of_Memory}
            if _,no_room:=append(&names,p.name);no_room!=nil {return {},.Out_Of_Memory}
        }
    }
    claims:=make(map[string]int,context.temp_allocator)
    if reserve(&claims,len(resolved.listed))!=nil {return {},.Out_Of_Memory}
    for &l in resolved.listed {claims[l.path]+=1}
    for &l,at in resolved.listed {
        if claims[l.path]<2 {continue}
        dot:=strings.last_index_byte(l.path,'.')
        l.path=clone(fmt.tprintf("%s (%s)%s",l.path[:dot],safe_name(names[at]),l.path[dot:]),allocator) or_return
    }
    return resolved,.None
}

// Where the registry lists an output of the cache: <folder><name><extension>
// with the name as safe_path gives it, and " (<index>)" before the extension
// when an output of its kind and name has a lower index (repeated). folder:
// "" or ending with '/'. In the temp allocator.
@(private)
listed_path :: proc(folder,name:string,index:int,repeated:bool,extension:string) -> string {
    if repeated {return fmt.tprintf("%s%s (%d)%s",folder,safe_path(name),index,extension)}
    return fmt.tprintf("%s%s%s",folder,safe_path(name),extension)
}

// A folder under another one: relative, with forward slashes, never out of it.
@(private)
folder_valid :: proc(folder:string) -> bool {
    if folder=="" {return true}
    if folder[0]=='/' || strings.contains_any(folder,"\\:") {return false}
    rest:=folder
    for part in strings.split_iterator(&rest,"/") {
        if part=="" || part=="." || part==".." {return false}
    }
    return true
}

@(private="file")
package_valid :: proc(p:^Package) -> bool {
    if p.id=={} || p.settings!="" && !object_valid(p.settings) {return false}
    for &a,at in p.assets {
        if a.id=={} || a.id==p.id || !kind_valid(a.kind) || a.index<0 || a.index>int(max(i32)) || a.part && !import_cached(a.kind) {return false}
        for &other in p.assets[:at] {
            if other.id==a.id || other.kind==a.kind && other.index==a.index && other.name==a.name {return false}
        }
        for d in a.dependencies {
            if d=={} {return false}
        }
    }
    return true
}

@(private="file")
build_valid :: proc(b:^Build) -> bool {
    if b.package_id=={} {return false}
    for o,at in b.outputs {
        if o.id=={} || !kind_valid(o.kind) {return false}
        for other in b.outputs[:at] {
            if other.id==o.id {return false}
        }
    }
    return true
}

@(private="file")
packages_valid :: proc(list:^Packages) -> bool {
    for &entry,at in list.packages {
        if entry.id=={} || !folder_valid(entry.folder) {return false}
        for &other in list.packages[:at] {
            if other.id==entry.id {return false}
        }
        for id,i in entry.assets {
            if id=={} {return false}
            for other in entry.assets[:i] {
                if other==id {return false}
            }
        }
        for written,i in entry.written {
            if written.id=={} || written.hash==0 {return false}
            for other in entry.written[:i] {
                if other.id==written.id {return false}
            }
        }
    }
    return true
}

// Four bytes a person can read, not all spaces: what the text of a kind keeps.
@(private="file")
kind_valid :: proc(kind:Fourcc) -> bool {
    if kind==fourcc("    ") {return false}
    for i in 0..<4 {
        c:=u8(u32(kind)>>uint(8*i))
        if c<0x20 || c>0x7e {return false}
    }
    return true
}

// One JSON object and nothing after it.
@(private="file")
object_valid :: proc(text:string) -> bool {
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    return serial.text_peek(&r)=='{' && serial.text_skip(&r) && serial.text_end(&r)
}

@(private="file")
writer_text :: proc(w:^serial.Writer) -> (text:string,error:Error) {
    if w.overflow>0 {
        serial.writer_destroy(w)
        return "",.Out_Of_Memory
    }
    return string(serial.writer_take(w)),.None
}

@(private="file")
id_write :: proc(w:^serial.Writer,id:base.Asset_Id) {
    serial.text_write_raw(w,"\"")
    serial.text_write_asset_id(w,id)
    serial.text_write_raw(w,"\"")
}

@(private="file")
hash_write :: proc(w:^serial.Writer,hash:store.Hash) {
    digits:[64]u8
    serial.text_write_raw(w,"\"")
    serial.text_write_raw(w,store.hex(hash,&digits))
    serial.text_write_raw(w,"\"")
}

@(private="file")
kind_write :: proc(w:^serial.Writer,kind:Fourcc) {
    buffer:[4]u8
    serial.text_write_string(w,strings.trim_right(fourcc_text(kind,&buffer)," "))
}

@(private="file")
expect :: proc(r:^serial.Text_Reader,c:u8) -> Error {
    return .None if serial.text_expect(r,c) else .Corrupt
}

// The name of a field and its colon: a view valid until the next string.
@(private="file")
key :: proc(r:^serial.Text_Reader) -> (name:string,error:Error) {
    text,ok:=serial.text_string(r)
    if !ok || !serial.text_expect(r,':') {return "",.Corrupt}
    return text,.None
}

@(private="file")
clone :: proc(text:string,allocator:runtime.Allocator) -> (cloned:string,error:Error) {
    if text=="" {return "",.None}
    copied,no_room:=strings.clone(text,allocator)
    if no_room!=nil {return "",.Out_Of_Memory}
    return copied,.None
}

@(private="file")
string_read :: proc(r:^serial.Text_Reader,allocator:runtime.Allocator) -> (text:string,error:Error) {
    value,ok:=serial.text_string(r)
    if !ok {return "",.Corrupt}
    return clone(value,allocator)
}

@(private="file")
count_read :: proc(r:^serial.Text_Reader,most:u64) -> (value:u64,error:Error) {
    negative,magnitude,ok:=serial.text_integer(r)
    if !ok || negative || magnitude>most {return 0,.Corrupt}
    return magnitude,.None
}

@(private="file")
bool_read :: proc(r:^serial.Text_Reader) -> (value:bool,error:Error) {
    if serial.text_keyword(r,"true") {return true,.None}
    if serial.text_keyword(r,"false") {return false,.None}
    return false,.Corrupt
}

@(private="file")
id_read :: proc(r:^serial.Text_Reader) -> (id:base.Asset_Id,error:Error) {
    text,ok:=serial.text_string(r)
    if !ok {return {},.Corrupt}
    parsed,valid:=base.asset_id_parse(text)
    if !valid {return {},.Corrupt}
    return parsed,.None
}

@(private="file")
hash_read :: proc(r:^serial.Text_Reader) -> (hash:store.Hash,error:Error) {
    text,ok:=serial.text_string(r)
    if !ok {return {},.Corrupt}
    parsed,valid:=store.parse_hex(text)
    if !valid {return {},.Corrupt}
    return parsed,.None
}

@(private="file")
kind_read :: proc(r:^serial.Text_Reader) -> (kind:Fourcc,error:Error) {
    text,ok:=serial.text_string(r)
    if !ok || len(text)==0 || len(text)>4 {return 0,.Corrupt}
    kind=fourcc(text)
    if !kind_valid(kind) {return 0,.Corrupt}
    return kind,.None
}

@(private="file")
ids_read :: proc(r:^serial.Text_Reader,ids:^[dynamic]base.Asset_Id) -> Error {
    expect(r,'[') or_return
    for begun:=false;!serial.text_accept(r,']');begun=true {
        if begun {expect(r,',') or_return}
        id:=id_read(r) or_return
        if _,no_room:=append(ids,id);no_room!=nil {return .Out_Of_Memory}
    }
    return .None
}

@(private="file")
origin_read :: proc(r:^serial.Text_Reader,allocator:runtime.Allocator) -> (origin:Package_Origin,error:Error) {
    Field :: enum {Path,Folder,Importer}
    seen:bit_set[Field]
    expect(r,'{') or_return
    for first:=true;!serial.text_accept(r,'}');first=false {
        if !first {expect(r,',') or_return}
        name:=key(r) or_return
        field:Field
        switch name {
        case "path": field=.Path
        case "folder": field=.Folder
        case "importer": field=.Importer
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Path: origin.path=string_read(r,allocator) or_return
        case .Folder: origin.folder=bool_read(r) or_return
        case .Importer: origin.importer=string_read(r,allocator) or_return
        }
    }
    if seen!={.Path,.Folder,.Importer} {return {},.Corrupt}
    return origin,.None
}

@(private="file")
asset_read :: proc(r:^serial.Text_Reader,allocator:runtime.Allocator) -> (a:Package_Asset,error:Error) {
    Field :: enum {Kind,Name,Index,Id,Part,Owner,Dependencies}
    seen:bit_set[Field]
    a.dependencies=make([dynamic]base.Asset_Id,allocator)
    expect(r,'{') or_return
    for first:=true;!serial.text_accept(r,'}');first=false {
        if !first {expect(r,',') or_return}
        name:=key(r) or_return
        field:Field
        switch name {
        case "kind": field=.Kind
        case "name": field=.Name
        case "index": field=.Index
        case "id": field=.Id
        case "part": field=.Part
        case "owner": field=.Owner
        case "dependencies": field=.Dependencies
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Kind: a.kind=kind_read(r) or_return
        case .Name: a.name=string_read(r,allocator) or_return
        case .Index: a.index=int(count_read(r,u64(max(i32))) or_return)
        case .Id: a.id=id_read(r) or_return
        case .Part: a.part=bool_read(r) or_return
        case .Owner:
            a.owner=id_read(r) or_return
            if a.owner=={} {return {},.Corrupt}
        case .Dependencies:
            ids_read(r,&a.dependencies) or_return
            if len(a.dependencies)==0 {return {},.Corrupt}
        }
    }
    if seen&{.Kind,.Name,.Index,.Id}!={.Kind,.Name,.Index,.Id} || .Part in seen && !a.part {return {},.Corrupt}
    return a,.None
}

@(private="file")
output_read :: proc(r:^serial.Text_Reader) -> (o:Build_Output,error:Error) {
    Field :: enum {Id,Kind,Kind_Version,Object,Thumbnail}
    seen:bit_set[Field]
    expect(r,'{') or_return
    for first:=true;!serial.text_accept(r,'}');first=false {
        if !first {expect(r,',') or_return}
        name:=key(r) or_return
        field:Field
        switch name {
        case "id": field=.Id
        case "kind": field=.Kind
        case "kind_version": field=.Kind_Version
        case "object": field=.Object
        case "thumbnail": field=.Thumbnail
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Id: o.id=id_read(r) or_return
        case .Kind: o.kind=kind_read(r) or_return
        case .Kind_Version: o.kind_version=u16(count_read(r,u64(max(u16))) or_return)
        case .Object: o.object=hash_read(r) or_return
        case .Thumbnail:
            o.thumbnail=hash_read(r) or_return
            if o.thumbnail=={} {return {},.Corrupt}
        }
    }
    if seen&{.Id,.Kind,.Kind_Version,.Object}!={.Id,.Kind,.Kind_Version,.Object} {return {},.Corrupt}
    return o,.None
}

@(private="file")
entry_read :: proc(r:^serial.Text_Reader,allocator:runtime.Allocator) -> (entry:Project_Package,error:Error) {
    Field :: enum {Id,Manifest,Folder,Assets,Written}
    seen:bit_set[Field]
    entry.assets=make([dynamic]base.Asset_Id,allocator)
    entry.written=make([dynamic]Package_Written,allocator)
    expect(r,'{') or_return
    for first:=true;!serial.text_accept(r,'}');first=false {
        if !first {expect(r,',') or_return}
        name:=key(r) or_return
        field:Field
        switch name {
        case "id": field=.Id
        case "manifest": field=.Manifest
        case "folder": field=.Folder
        case "assets": field=.Assets
        case "written": field=.Written
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Id: entry.id=id_read(r) or_return
        case .Manifest: entry.manifest=hash_read(r) or_return
        case .Folder: entry.folder=string_read(r,allocator) or_return
        case .Assets: ids_read(r,&entry.assets) or_return
        case .Written:
            expect(r,'[') or_return
            for begun:=false;!serial.text_accept(r,']');begun=true {
                if begun {expect(r,',') or_return}
                written:=written_read(r) or_return
                if _,no_room:=append(&entry.written,written);no_room!=nil {return {},.Out_Of_Memory}
            }
        }
    }
    if seen!={.Id,.Manifest,.Folder,.Assets,.Written} {return {},.Corrupt}
    return entry,.None
}

@(private="file")
written_read :: proc(r:^serial.Text_Reader) -> (written:Package_Written,error:Error) {
    Field :: enum {Id,Hash}
    seen:bit_set[Field]
    expect(r,'{') or_return
    for first:=true;!serial.text_accept(r,'}');first=false {
        if !first {expect(r,',') or_return}
        name:=key(r) or_return
        field:Field
        switch name {
        case "id": field=.Id
        case "hash": field=.Hash
        case: return {},.Corrupt
        }
        if field in seen {return {},.Corrupt}
        seen+={field}
        switch field {
        case .Id: written.id=id_read(r) or_return
        case .Hash:
            digits,ok:=serial.text_string(r)
            if !ok || len(digits)!=16 {return {},.Corrupt}
            parsed,parsed_ok:=base.hex_parse_u64(digits)
            if !parsed_ok {return {},.Corrupt}
            written.hash=parsed
        }
    }
    if seen!={.Id,.Hash} {return {},.Corrupt}
    return written,.None
}

// The text of the record the store keeps as the object at address, in the temp allocator.
record_get :: proc(s:^store.Store,address:store.Hash) -> (text:string,error:Error) {
    o,open_error:=store.object_open(s,address)
    if open_error!=.None {return "",store_error(open_error)}
    defer store.object_close(&o)
    size:=store.object_size(&o)
    if size>RECORD_BYTES {return "",.Too_Large}
    bytes,no_room:=make([]u8,int(size),context.temp_allocator)
    if no_room!=nil {return "",.Out_Of_Memory}
    if read_error:=store.object_read(&o,0,bytes);read_error!=.None {return "",store_error(read_error)}
    return string(bytes),.None
}

@(private="file")
file_error :: proc(error:serial.File_Error) -> Error {
    switch error {
    case .None: return .None
    case .Too_Large: return .Too_Large
    case .Out_Of_Memory: return .Out_Of_Memory
    case .Not_Found: return .Not_Found
    case .Open,.Read,.Write,.Rename,.Invalid_Alignment: return .IO
    }
    return .IO
}

@(private)
store_error :: proc(error:store.Error) -> Error {
    switch error {
    case .None: return .None
    case .Missing: return .Not_Found
    case .Corrupt,.Unsupported_Layout: return .Corrupt
    case .Invalid_Argument: return .Invalid
    case .Out_Of_Memory: return .Out_Of_Memory
    case .Io,.No_Space: return .IO
    }
    return .IO
}

@(private="file")
problem_add :: proc(resolved:^Packages_Resolved,problem:Package_Problem) -> Error {
    if _,no_room:=append(&resolved.problems,problem);no_room!=nil {return .Out_Of_Memory}
    return .None
}

// Whether what an import builds of a kind is of the cache: nothing edits it
// after the import, so its build gives it back whole.
import_cached :: proc "contextless" (kind:Fourcc) -> bool {
    return kind==KIND_MESH || kind==KIND_TEXTURE || kind==KIND_SOUND || kind==KIND_FONT
}

// A name a file can have: what no file system takes becomes _, and the
// spaces and dots of its ends go. "unnamed" when nothing is left. In the
// temp allocator.
safe_name :: proc(name:string) -> string {
    cleaned:=name_clean(name)
    return cleaned if cleaned!="" else "unnamed"
}

// Where under the folder of an import the output named name goes: each part
// between '/' as safe_name makes it, without the parts that are empty, "."
// or "..". "unnamed" when no part is left. In the temp allocator.
safe_path :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    rest:=name
    for part in strings.split_iterator(&rest,"/") {
        cleaned:=name_clean(part)
        if cleaned=="" {continue}
        if strings.builder_len(b)>0 {strings.write_byte(&b,'/')}
        strings.write_string(&b,cleaned)
    }
    return strings.to_string(b) if strings.builder_len(b)>0 else "unnamed"
}

@(private="file")
name_clean :: proc(name:string) -> string {
    b:=strings.builder_make(context.temp_allocator)
    for r in name {
        switch {
        case r<32 || r==127,r=='<',r=='>',r==':',r=='"',r=='/',r=='\\',r=='|',r=='?',r=='*',r=='#':
            strings.write_byte(&b,'_')
        case:
            strings.write_rune(&b,r)
        }
    }
    return strings.trim(strings.to_string(b)," .")
}
