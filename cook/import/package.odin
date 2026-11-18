package importer

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:store"

// An import ingests its source as a package of the store (asset/packages.odin).
// Its manifest says what the source is (identity, settings, inputs) and which
// asset each thing of the source is; nothing else decides an id, and importing
// the source again keeps them. Its build holds the blob of every output, the
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

// What the outputs of an import are made from, without any version of the
// engine (asset.Package.identity): the bytes of the source at path and of each
// input, named from the folder of the source, the text of its settings and the
// code of the plugin that imports it whole (Import_Options.importer_code). A
// file that cannot be read, such as a folder, counts as no bytes.
identity_of :: proc(path:string,inputs:[]string,settings:Import_Settings,code:u64) -> store.Hash {
    TAG :: "mirai import identity"
    bytes:=make([dynamic]u8,context.temp_allocator)
    append(&bytes,TAG)
    address :: proc(bytes:^[dynamic]u8,file:string) {
        hash:=store.address_of_bytes(nil)
        if !unsafe_path(file) {
            if read,_,error:=store.address_of_file(file);error==.None {hash=read}
        }
        append(bytes,..hash[:])
    }
    address(&bytes,path)
    folder:=path[:max(strings.last_index_byte(path,'/'),0)]
    for input in inputs {
        append(&bytes,input)
        append(&bytes,0)
        address(&bytes,fmt.tprintf("%s/%s",folder,input))
    }
    append(&bytes,settings_text(settings,context.temp_allocator))
    append(&bytes,0)
    code:=code
    append(&bytes,..([^]u8)(&code)[:size_of(code)])
    return store.address_of_bytes(bytes[:])
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
// ref REF_PACKAGES of this machine names whose origin is origin. found is
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
    refs,_:=store.ref_list(s,asset.REF_PACKAGES,context.temp_allocator)
    for ref in refs {
        candidate,read_error:=asset.package_get(s,ref.hash,context.temp_allocator)
        if read_error!=.None || candidate.origin.path!=origin {continue}
        p,read_error=asset.package_get(s,ref.hash,allocator)
        if read_error!=.None {continue}
        return p,ref.hash,true,{}
    }
    return
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
// them: the package with REF_PACKAGES, the build with REF_IMPORTS when its
// textures are Final, else REF_IMPORTS_FAST, and as the build this machine
// chose for the manifest (REF_BUILDS).
@(private)
writer_publish :: proc(w:^Writer,name,importer:string) -> bool {
    s:=w.options.store
    writer_identity(w)
    p:=asset.Package{id=w.package_id,name=name,identity=w.identity,inputs=w.inputs,assets=w.outputs}
    p.origin={path=w.origin,folder=os.is_dir(w.path),importer=importer}
    if settings:=settings_text(w.report.settings,context.temp_allocator);settings!="{}" {p.settings=settings}
    slice.sort(p.inputs[:])
    b:=asset.Build{package_id=w.package_id,key=w.key,final=!w.fast,encoders=textures.encoders_id()}
    b.outputs=make([dynamic]asset.Build_Output,context.temp_allocator)
    for output,at in w.outputs {
        if w.blobs[at]=={} {continue}
        info,_:=asset.kind_info(output.kind)
        append(&b.outputs,asset.Build_Output{id=output.id,kind=output.kind,kind_version=info.version,blob=w.blobs[at]})
    }
    manifest,manifest_error:=asset.package_put(s,&p)
    if manifest_error!=.None {return writer_fail(w,.Write,"the manifest of the package of %s could not be put in the store at %s: %v",w.path,s.root,manifest_error)}
    build,build_error:=asset.build_put(s,&b)
    if build_error!=.None {return writer_fail(w,.Write,"the build of the package of %s could not be put in the store at %s: %v",w.path,s.root,build_error)}
    id_text:[base.ASSET_ID_TEXT]u8
    key_text,select_text:[64]u8
    refs:=[3]struct{namespace,name:string}{
        {asset.REF_PACKAGES,base.asset_id_format(w.package_id,id_text[:])},
        {asset.REF_IMPORTS if b.final else asset.REF_IMPORTS_FAST,store.hex(w.key,&key_text)},
        {asset.REF_BUILDS,store.hex(asset.build_select(manifest,&p),&select_text)},
    }
    for ref,at in refs {
        if error:=store.ref_set(s,ref.namespace,ref.name,manifest if at==0 else build);error!=.None {
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
    w.identity=identity_of(w.origin,w.inputs[:],w.report.settings,w.options.importer_code)
    versions:=import_versions(w.version)
    w.key,_=asset.import_key(w.identity,versions[:])
}
