package importer

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:std/blake3"
import "mirai:store"

// An import ingests its source as a package of the store (asset/packages.odin).
// Its manifest says what the source is (identity, settings, inputs) and which
// asset each thing of the source is; nothing else decides an id, and importing
// the source again keeps them. Its build holds the object of every output, the
// documents as the source gives them (their baseline) among them, under the
// key of its identity and the versions of what imports and writes it
// (import_key): what any machine with the manifest finds without the source.

// The settings as the text of their object: only where they differ from their
// defaults (the zero value), so a manifest shows what was chosen; reading
// fills the rest.
settings_text :: proc(settings:Import_Settings,allocator:=context.allocator) -> string {
    settings,defaults:=settings,Import_Settings{}
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,_:=serial.schema_add(&schema,Import_Settings)
    w:serial.Writer
    serial.writer_init(&w,512,allocator)
    serial.text_write_changed(&w,&schema,type,([^]u8)(&settings)[:size_of(Import_Settings)],([^]u8)(&defaults)[:size_of(Import_Settings)],.Pretty,depth=1)
    return string(serial.writer_take(&w))
}

// False for a text that is not settings this build reads: a field or a value
// it does not know, or one out of its range. "" is the defaults.
settings_parse :: proc(text:string) -> (settings:Import_Settings,ok:bool) {
    if text!="" {
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        defer serial.schema_destroy(&schema)
        type,_:=serial.schema_add(&schema,Import_Settings)
        r:serial.Text_Reader
        serial.text_reader_init(&r,text,context.temp_allocator)
        defer serial.text_reader_destroy(&r)
        serial.text_read(&r,&schema,type,([^]u8)(&settings)[:size_of(Import_Settings)]) or_return
    }
    return settings,settings_valid(settings)
}

@(private="file")
settings_valid :: proc(settings:Import_Settings) -> bool {
    return settings.textures<=max(textures.Encoding) && settings.rdo_lambda<=textures.RDO_LAMBDA_MAX &&
        settings.image<=max(Image_Use) && settings.alpha_coverage>=0 && settings.alpha_coverage<=1 && settings.lods<=max(Lods) && settings.parts<=max(Parts) && settings.front<=max(Front) && settings.rig<=max(Rig) &&
        settings.rig_crotch>=0 && settings.rig_neck>=0 && (settings.rig==.Humanoid || settings.rig_crotch==0 && settings.rig_neck==0)
}

// What the outputs of the package package_id are made from, without any
// version of the engine (asset.Package.identity): the package, whose ids its
// blobs hold, so two packages of the same bytes have builds of their own; the
// bytes of the source at path and of each input, named from the folder of the
// source; the text of its settings and the code of the plugin that imports it
// whole (Import_Options.importer_code). A file that cannot be read, such as a
// folder, counts as no bytes. With hashes, a file whose size and modification
// time it knows is not read.
identity_of :: proc(package_id:base.Asset_Id,path:string,inputs:[]string,settings:Import_Settings,code:u64,hashes:^Source_Hashes=nil) -> store.Hash {
    TAG :: "mirai import identity"
    bytes:=make([dynamic]u8,context.temp_allocator)
    append(&bytes,TAG)
    package_id:=package_id
    append(&bytes,..([^]u8)(&package_id)[:size_of(package_id)])
    address :: proc(bytes:^[dynamic]u8,file:string,hashes:^Source_Hashes) {
        hash:=store.address_of_bytes(nil)
        if !unsafe_path(file) {hash=file_address(hashes,file)}
        append(bytes,..hash[:])
    }
    address(&bytes,path,hashes)
    folder:=path[:max(strings.last_index_byte(path,'/'),0)]
    for input in inputs {
        append(&bytes,input)
        append(&bytes,0)
        address(&bytes,fmt.tprintf("%s/%s",folder,input),hashes)
    }
    append(&bytes,settings_text(settings,context.temp_allocator))
    append(&bytes,0)
    code:=code
    append(&bytes,..([^]u8)(&code)[:size_of(code)])
    return store.address_of_bytes(bytes[:])
}

// The addresses of the files the identity of one source read, by path, as
// they were when read: kept by the library of the machine per source
// (asset.REF_SOURCES), so finding whether a source changed reads only the
// files whose size or modification time changed. The bytes still decide: a
// file that changed is read again.
Source_Hashes :: struct {
    files:map[string]Source_Hash,
    changed:bool,
}
Source_Hash :: struct {size,modified:i64,hash:store.Hash}

// A file modified this close to when it was read may change again within the
// same modification time (2 s on FAT, a coarse network file system): what was
// learned of it is not kept, and it is read again the next time.
SETTLED_NANOSECONDS :: 2_000_000_000

// The hashes kept for the source at origin (path_key), in allocator; none
// when the store has none or they do not read.
source_hashes_load :: proc(s:^store.Store,origin:string,allocator:=context.allocator) -> (hashes:Source_Hashes) {
    hashes.files=make(map[string]Source_Hash,allocator=allocator)
    name:[64]u8
    hash,ref_error:=store.ref_get(s,asset.REF_SOURCES,asset.origin_name(origin,&name))
    if ref_error!=.None {return}
    text,read_error:=asset.record_get(s,hash)
    if read_error!=.None {return}
    for line in strings.split_lines_iterator(&text) {
        parts:=strings.split_n(line," ",4,context.temp_allocator)
        if len(parts)!=4 {continue}
        address,address_ok:=store.parse_hex(parts[0])
        file_size,size_ok:=strconv.parse_i64(parts[1])
        modified,modified_ok:=strconv.parse_i64(parts[2])
        if address_ok && size_ok && modified_ok {hashes.files[strings.clone(parts[3],allocator)]={file_size,modified,address}}
    }
    return
}

// Keeps the hashes of the source at origin when reading it changed them.
source_hashes_save :: proc(s:^store.Store,origin:string,hashes:^Source_Hashes) {
    if !hashes.changed {return}
    files:=make([dynamic]string,0,len(hashes.files),context.temp_allocator)
    for file in hashes.files {append(&files,file)}
    slice.sort(files[:])
    b:=strings.builder_make(context.temp_allocator)
    digits:[64]u8
    for file in files {
        known:=hashes.files[file]
        fmt.sbprintf(&b,"%s %d %d %s\n",store.hex(known.hash,&digits),known.size,known.modified,file)
    }
    hash,error:=asset.record_put(s,transmute([]u8)strings.to_string(b))
    if error!=.None {return}
    name:[64]u8
    _=store.ref_set(s,asset.REF_SOURCES,asset.origin_name(origin,&name),hash)
}

// The BLAKE3 of the bytes of the file at path, read once; false when it does not read.
@(private="file")
file_hash :: proc(path:string) -> (hash:store.Hash,read:bool) {
    file,open_error:=os.open(path)
    if open_error!=nil {return}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil {return}
    hasher:blake3.Hasher
    buffer:[64<<10]u8=---
    for at:=i64(0);at<size; {
        n,read_error:=os.read_at(file,buffer[:min(i64(len(buffer)),size-at)],at)
        if read_error!=nil || n<=0 {return}
        blake3.update(&hasher,buffer[:n])
        at+=i64(n)
    }
    return store.Hash(blake3.final(&hasher)),true
}

// The address of the bytes of a file, from hashes when its size and
// modification time are those it knows; that of no bytes for a file that
// cannot be read.
@(private="file")
file_address :: proc(hashes:^Source_Hashes,file:string) -> store.Hash {
    info,stat_error:=os.stat(file,context.temp_allocator)
    size,modified:=info.size,time.time_to_unix_nano(info.modification_time)
    if hashes!=nil && stat_error==nil {
        if known,found:=hashes.files[file];found && known.size==size && known.modified==modified {return known.hash}
    }
    hash,read:=file_hash(file)
    if !read {return store.address_of_bytes(nil)}
    if hashes!=nil && stat_error==nil && time.time_to_unix_nano(time.now())-modified>SETTLED_NANOSECONDS {
        if _,found:=hashes.files[file];!found {hashes.files[strings.clone(file,hashes.files.allocator)]={}}
        hashes.files[file]={size,modified,hash}
        hashes.changed=true
    }
    return hash
}

// The versions of what reads a source with a format of version
// (import_version) and writes its assets, as asset.import_key combines them:
// the writer and the format, every kind of asset and what builds textures.
import_versions :: proc(version:u32) -> [3]u64 {
    kinds:=make([dynamic]u64,0,len(asset.KINDS),context.temp_allocator)
    for info in asset.KINDS {append(&kinds,u64(info.kind)<<16|u64(info.version))}
    return {u64(version),base.hash64(slice.to_bytes(kinds[:])),u64(textures.BUILD_VERSION)}
}

// The manifest of the package the source at origin (an absolute path with
// forward slashes) was ingested as: the one manifest names, else the one the
// ref REF_ORIGINS of this machine names for origin. found is
// false without one. In allocator, an arena.
package_previous :: proc(s:^store.Store,manifest:store.Hash,origin:string,allocator:=context.allocator) -> (p:asset.Package,hash:store.Hash,found:bool,error:Error) {
    digits:[64]u8
    if manifest!={} {
        read_error:asset.Error
        p,read_error=asset.package_get(s,manifest,allocator)
        if read_error==.Not_Found {return {},{},false,error_make(.Not_Found,"the manifest %s of the package of %s is not in the store at %s: fetch it from a peer that has it, or import the source as a new package",store.hex(manifest,&digits),origin,s.root)}
        if read_error!=.None {return {},{},false,error_make(.Malformed,"the manifest %s of the package of %s does not read (%v): import the source as a new package",store.hex(manifest,&digits),origin,read_error)}
        return p,manifest,true,{}
    }
    name:[64]u8
    named,ref_error:=store.ref_get(s,asset.REF_ORIGINS,asset.origin_name(origin,&name))
    if ref_error!=.None {return}
    read_error:asset.Error
    if p,read_error=asset.package_get(s,named,allocator);read_error!=.None || p.origin.path!=origin_of(origin) {return {},{},false,{}}
    return p,named,true,{}
}

// The settings of the package the source at path was ingested as
// (package_previous with options.manifest), the defaults (found false) when it
// was not or without options.store.
settings_load :: proc(options:Import_Options,path:string) -> (settings:Import_Settings,found:bool,error:Error) {
    if options.store==nil {return}
    p:asset.Package
    p,_,found,error=package_previous(options.store,options.manifest,path_key(path),context.temp_allocator)
    if !found || error.code!=.None {return}
    valid:bool
    if settings,valid=settings_parse(p.settings);!valid {
        return {},false,error_make(.Malformed,"the settings the package of %s keeps (%s) are not those of this build: import it as a new package",path,p.settings)
    }
    return
}

// The asset the package the source at path was ingested as on this machine
// gave what the source names name, of kind; false when it gave none.
output_id :: proc(s:^store.Store,path:string,kind:asset.Fourcc,name:string) -> (id:base.Asset_Id,found:bool) {
    p,_,known,error:=package_previous(s,{},path_key(path),context.temp_allocator)
    if !known || error.code!=.None {return}
    for a in p.assets {
        if a.kind==kind && a.name==name {return a.id,true}
    }
    return
}

// Puts the manifest of the package and its build in the store and names
// them: the package with REF_PACKAGES and by its origin (REF_ORIGINS), the build with REF_IMPORTS when its
// textures are Final, else REF_IMPORTS_FAST, and as the build this machine
// chose for the manifest (REF_BUILDS).
@(private)
writer_publish :: proc(w:^Writer,name,importer:string) -> bool {
    s:=w.options.store
    writer_identity(w)
    p:=asset.Package{id=w.package_id,name=name,identity=w.identity,inputs=w.inputs,assets=w.outputs}
    p.origin={path=origin_of(w.origin),folder=os.is_dir(w.path),importer=importer}
    if settings:=settings_text(w.report.settings,context.temp_allocator);settings!="{}" {p.settings=settings}
    slice.sort(p.inputs[:])
    b:=asset.Build{package_id=w.package_id,key=w.key,final=!w.fast,encoders=textures.encoders_id()}
    b.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    for output,at in w.outputs {
        if w.objects[at]=={} {continue}
        info,_:=asset.kind_info(output.kind)
        append(&b.outputs,asset.Build_Output{id=output.id,kind=output.kind,kind_version=info.version,object=w.objects[at]})
    }
    manifest,manifest_error:=asset.package_put(s,&p)
    if manifest_error!=.None {return writer_fail(w,.Write,"the manifest of the package of %s could not be put in the store at %s: %v",w.path,s.root,manifest_error)}
    build,build_error:=asset.build_put(s,&b)
    if build_error!=.None {return writer_fail(w,.Write,"the build of the package of %s could not be put in the store at %s: %v",w.path,s.root,build_error)}
    id_text:[base.ASSET_ID_TEXT]u8
    key_text,select_text,origin_text:[64]u8
    refs:=[4]struct{namespace,name:string}{
        {asset.REF_PACKAGES,base.asset_id_format(w.package_id,id_text[:])},
        {asset.REF_ORIGINS,asset.origin_name(w.origin,&origin_text)},
        {asset.REF_IMPORTS if b.final else asset.REF_IMPORTS_FAST,store.hex(w.key,&key_text)},
        {asset.REF_BUILDS,store.hex(asset.build_select(manifest,&p),&select_text)},
    }
    for ref,at in refs {
        if error:=store.ref_set(s,ref.namespace,ref.name,manifest if at<2 else build);error!=.None {
            return writer_fail(w,.Write,"the ref %s/%s of the package of %s could not be set in the store at %s: %v",ref.namespace,ref.name,w.path,s.root,error)
        }
    }
    w.report.package_id,w.report.manifest,w.report.build,w.report.key,w.report.final=w.package_id,manifest,build,w.key,b.final
    return true
}

// Fixes what the import is made from once its inputs are whole: its identity
// and the key of its build (asset.import_key).
@(private)
writer_identity :: proc(w:^Writer) {
    if w.fixed {return}
    w.fixed=true
    slice.sort(w.inputs[:])
    w.identity=identity_of(w.package_id,w.origin,w.inputs[:],w.report.settings,w.options.importer_code,w.options.hashes)
    w.key=build_key(w.identity,w.version,w.options.importer_code)
}

// The key of the build of a package of identity (asset.import_key): the
// versions of what reads its source with a format of version (import_version)
// and, for a source a plugin imports whole, the identity of the code of that
// plugin (code; 0: none), so a changed importer builds again also where its
// source is not.
build_key :: proc(identity:store.Hash,version:u32,code:u64) -> store.Hash {
    versions:=import_versions(version)
    all:=[4]u64{versions[0],versions[1],versions[2],code}
    key,_:=asset.import_key(identity,all[:3 if code==0 else 4])
    return key
}
