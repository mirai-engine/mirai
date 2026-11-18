package asset

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:std/base"
import "mirai:store"

@(private="file")
hash_of :: proc(text:string) -> store.Hash {return store.address_of_bytes(transmute([]u8)text)}

@(private="file")
ids :: proc(list:..base.Asset_Id) -> [dynamic]base.Asset_Id {
    out:=make([dynamic]base.Asset_Id,context.temp_allocator)
    append(&out,..list)
    return out
}

@(private="file")
sample_package :: proc() -> Package {
    p:=Package{id={1,1},name="crate \"kit\"/ü",origin={path="C:/Downloads/Kit\\crate.glb",importer="gltf"},identity=hash_of("crate"),settings=`{"lods": "None", "nested": {"a": [1, 2]}}`}
    p.inputs=make([dynamic]string,context.temp_allocator)
    append(&p.inputs,"crate.bin","textures/wood.png")
    p.assets=make([dynamic]Package_Asset,context.temp_allocator)
    append(&p.assets,
        Package_Asset{kind=KIND_SCENE,name="crate",id={2,2},dependencies=ids({3,3},{6,6})},
        Package_Asset{kind=KIND_MESH,name="body",id={3,3},part=true,owner={2,2},dependencies=ids({4,4})},
        Package_Asset{kind=KIND_MATERIAL,name="wood",id={4,4},dependencies=ids({5,5})},
        Package_Asset{kind=KIND_TEXTURE,name="wood",id={5,5}},
        Package_Asset{kind=KIND_MESH,name="body",index=1,id={6,6}},
        Package_Asset{kind=KIND_TEXTURE,name="spare",id={7,7}},
    )
    return p
}

@(private="file")
sample_build :: proc(p:^Package,blobs:[]store.Hash) -> Build {
    b:=Build{package_id=p.id,key=hash_of("key"),final=true,encoders=0x0123456789abcdef}
    b.outputs=make([dynamic]Build_Output,context.temp_allocator)
    for &a,at in p.assets {
        info,_:=kind_info(a.kind)
        append(&b.outputs,Build_Output{id=a.id,kind=a.kind,kind_version=info.version,blob=blobs[at%len(blobs)],thumbnail=at==0?hash_of("thumb"):{}})
    }
    return b
}

@(private="file")
sample_list :: proc() -> Packages {
    list:Packages
    list.packages=make([dynamic]Project_Package,context.temp_allocator)
    append(&list.packages,Project_Package{id={1,1},manifest=hash_of("m1"),folder="props/crate",assets=ids({3,3})},Project_Package{id={9,9},manifest=hash_of("m2"),assets=ids()})
    return list
}

// Each record reads back as it was written, field by field, and writes the
// same text again; a record that could not do so is refused when written.
@(test)
package_records_read_back_what_they_write :: proc(t:^testing.T) {
    p:=sample_package()
    text,error:=package_text(&p,context.temp_allocator)
    if !testing.expect_value(t,error,Error.None) {return}
    back,parse_error:=package_parse(text,context.temp_allocator)
    if !testing.expect_value(t,parse_error,Error.None) {return}
    testing.expect(t,back.id==p.id && back.name==p.name && back.origin==p.origin && back.identity==p.identity && back.settings==p.settings && len(back.inputs)==2 && back.inputs[1]==p.inputs[1] && len(back.assets)==len(p.assets),"the manifest reads back")
    for &a,at in back.assets {
        want:=p.assets[at]
        testing.expectf(t,a.kind==want.kind && a.name==want.name && a.index==want.index && a.id==want.id && a.part==want.part && a.owner==want.owner && len(a.dependencies)==len(want.dependencies),"asset %d reads back",at)
    }
    again,_:=package_text(&back,context.temp_allocator)
    testing.expect_value(t,again,text)

    b:=sample_build(&p,{hash_of("a"),hash_of("b")})
    build,build_error:=build_text(&b,context.temp_allocator)
    if !testing.expect_value(t,build_error,Error.None) {return}
    built,built_error:=build_parse(build,context.temp_allocator)
    if !testing.expect_value(t,built_error,Error.None) {return}
    testing.expect(t,built.package_id==b.package_id && built.key==b.key && built.final && built.encoders==b.encoders && len(built.outputs)==len(b.outputs),"the build reads back")
    for o,at in built.outputs {testing.expectf(t,o==b.outputs[at],"output %d reads back",at)}
    rebuilt,_:=build_text(&built,context.temp_allocator)
    testing.expect_value(t,rebuilt,build)

    list:=sample_list()
    listed,list_error:=packages_text(&list,context.temp_allocator)
    if !testing.expect_value(t,list_error,Error.None) {return}
    read,read_error:=packages_parse(listed,context.temp_allocator)
    if !testing.expect_value(t,read_error,Error.None) {return}
    testing.expect(t,len(read.packages)==2 && read.packages[0].id==list.packages[0].id && read.packages[0].manifest==list.packages[0].manifest && read.packages[0].folder=="props/crate" && len(read.packages[0].assets)==1 && len(read.packages[1].assets)==0,"the list reads back")

    // Through the store and the file of a project.
    folder:=base.test_folder(t,"packages-records");if folder=="" {return}
    s,open_error:=store.open(fmt.tprintf("%s/store",folder),context.temp_allocator)
    if !testing.expect_value(t,open_error,store.Error.None) {return}
    put,put_error:=package_put(&s,&p)
    testing.expect(t,put_error==.None && put==hash_of(text),"a manifest is the blob of its text")
    got,get_error:=package_get(&s,put,context.temp_allocator)
    testing.expect(t,get_error==.None && got.id==p.id,"and reads back from the store")
    _,missing:=package_get(&s,hash_of("nothing"),context.temp_allocator)
    testing.expect_value(t,missing,Error.Not_Found)
    empty,found,load_error:=packages_load(folder,context.temp_allocator)
    testing.expect(t,load_error==.None && !found && len(empty.packages)==0,"a project without a list uses no package")
    testing.expect_value(t,packages_save(folder,&list),Error.None)
    loaded,saved,_:=packages_load(folder,context.temp_allocator)
    testing.expect(t,saved && len(loaded.packages)==2,"the list of a project reads back from its file")

    // What would not read back is refused.
    bad:=p
    bad.settings=`{"open": `
    _,refused:=package_text(&bad,context.temp_allocator)
    testing.expect_value(t,refused,Error.Invalid)
    folded:=list
    folded.packages[0].folder="../outside"
    _,refused=packages_text(&folded,context.temp_allocator)
    testing.expect_value(t,refused,Error.Invalid)
}

// The listing of a project comes from its list, the manifests and the build
// each one's ref names, with the paths of the blobs. A package without a
// build is listed not built; a manifest the store lacks, a build that does not
// read or an asset the manifest lacks is a problem of the result; nothing is
// removed.
@(test)
packages_resolve_lists_the_blobs_of_what_a_project_uses :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"packages-resolve");if folder=="" {return}
    s,open_error:=store.open(fmt.tprintf("%s/store",folder),context.temp_allocator)
    if !testing.expect_value(t,open_error,store.Error.None) {return}
    mesh,_:=store.put_bytes(&s,transmute([]u8)string("mesh bytes"))
    texture,_:=store.put_bytes(&s,transmute([]u8)string("texture bytes"))
    p:=sample_package()
    manifest,_:=package_put(&s,&p)
    blobs:=[6]store.Hash{mesh,mesh,mesh,texture,mesh,texture}
    b:=sample_build(&p,blobs[:])
    // The second mesh is of a version this program does not read.
    b.outputs[4].kind_version+=1
    build,_:=build_put(&s,&b)
    digits:[64]u8
    testing.expect_value(t,store.ref_set(&s,REF_BUILDS,store.hex(build_select(manifest,&p),&digits),build),store.Error.None)

    other:=Package{id={20,20},name="rock",identity=hash_of("rock")}
    other.assets=make([dynamic]Package_Asset,context.temp_allocator)
    append(&other.assets,Package_Asset{kind=KIND_TEXTURE,name="wood",id={21,21}})
    unbuilt,_:=package_put(&s,&other)
    broken:=Package{id={30,30},name="broken",identity=hash_of("broken")}
    broken.assets=make([dynamic]Package_Asset,context.temp_allocator)
    append(&broken.assets,Package_Asset{kind=KIND_MESH,name="m",id={31,31}})
    broken_manifest,_:=package_put(&s,&broken)
    not_a_build,_:=store.put_bytes(&s,transmute([]u8)string("not a build"))
    testing.expect_value(t,store.ref_set(&s,REF_BUILDS,store.hex(build_select(broken_manifest,&broken),&digits),not_a_build),store.Error.None)

    list:Packages
    list.packages=make([dynamic]Project_Package,context.temp_allocator)
    append(&list.packages,
        Project_Package{id=p.id,manifest=manifest,folder="kit",assets=ids({2,2},{99,99})},
        Project_Package{id=other.id,manifest=unbuilt,folder="kit",assets=ids()},
        Project_Package{id={40,40},manifest=hash_of("absent")},
        Project_Package{id=broken.id,manifest=broken_manifest},
    )
    resolved,error:=packages_resolve(&s,"",&list,context.temp_allocator)
    if !testing.expect_value(t,error,Error.None) {return}
    mesh_path,_:=store.blob_path(&s,mesh,context.temp_allocator)
    texture_path,_:=store.blob_path(&s,texture,context.temp_allocator)
    Want :: struct {id:base.Asset_Id,path,file:string,state:Listed_State}
    wanted:=[]Want{
        {{3,3},"kit/body.mesh",mesh_path,.Built},
        {{5,5},"kit/wood (crate _kit__ü).tex",texture_path,.Built},
        {{6,6},"kit/body (1).mesh","",.Not_Built},
        {{21,21},"kit/wood (rock).tex","",.Not_Built},
        {{31,31},"m.mesh","",.Not_Built},
    }
    testing.expectf(t,len(resolved.listed)==len(wanted),"the cache assets used, with what they depend on: %v",resolved.listed)
    for w in wanted {
        found:=false
        for l in resolved.listed {
            if l.id!=w.id {continue}
            found=true
            testing.expectf(t,l.path==w.path && l.file==w.file && l.state==w.state,"%v is %s at %s (%v), not %s at %s (%v)",w.id,w.path,w.file,w.state,l.path,l.file,l.state)
        }
        testing.expectf(t,found,"%v is listed",w.id)
    }
    Problem :: struct {package_id,asset:base.Asset_Id,code:Package_Problem_Code}
    problems:=[]Problem{{p.id,{99,99},.Asset_Unknown},{{40,40},{},.Manifest_Missing},{broken.id,{},.Build_Unreadable}}
    testing.expectf(t,len(resolved.problems)==len(problems),"the problems: %v",resolved.problems)
    for want in problems {
        seen:=false
        for got in resolved.problems {seen||=got.package_id==want.package_id && got.asset==want.asset && got.code==want.code}
        testing.expectf(t,seen,"%v is reported",want)
    }
    for blob in ([]store.Hash{mesh,texture,manifest,build,unbuilt,not_a_build}) {testing.expect(t,store.has(&s,blob),"resolving removes no blob")}
    _,ref_error:=store.ref_get(&s,REF_BUILDS,store.hex(build_select(manifest,&p),&digits))
    testing.expect_value(t,ref_error,store.Error.None)

    // The name of a build changes with the versions of the kinds a program reads.
    _,ok:=import_key(p.identity,make([]u64,IMPORT_KEY_VERSIONS+1,context.temp_allocator))
    testing.expect(t,!ok,"an import key takes at most IMPORT_KEY_VERSIONS versions")
    first,_:=import_key(p.identity,{1,2})
    second,_:=import_key(p.identity,{1,3})
    testing.expect(t,first!=second && first!=build_select(manifest,&p),"keys of other versions differ")
    buffer:[store.NAME_MAX]u8
    testing.expect_value(t,cache_namespace("textures",&buffer),"cache-textures")
    testing.expect_value(t,cache_namespace(strings.repeat("x",store.NAME_MAX,context.temp_allocator),&buffer),"")
}

// text with the first of before replaced; "" when text does not have it.
@(private="file")
swap :: proc(text,before,after:string) -> string {
    at:=strings.index(text,before)
    if at<0 {return ""}
    return strings.concatenate({text[:at],after,text[at+len(before):]},context.temp_allocator)
}

@(private="file")
failing_allocator :: proc() -> runtime.Allocator {
    return {procedure=proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
        #partial switch mode {
        case .Free,.Free_All: return nil,.None
        }
        return nil,.Out_Of_Memory
    }}
}

// No text makes a parser of the records stop the program: random bytes,
// every cut of a valid text, oversized, deep or contradictory text, and
// memory that runs out give an error.
@(test)
package_records_refuse_hostile_text :: proc(t:^testing.T) {
    Parser :: enum {Package,Build,Packages}
    parse :: proc(parser:Parser,text:string,allocator:runtime.Allocator) -> Error {
        switch parser {
        case .Package: _,error:=package_parse(text,allocator);return error
        case .Build: _,error:=build_parse(text,allocator);return error
        case .Packages: _,error:=packages_parse(text,allocator);return error
        }
        return .None
    }
    p:=sample_package()
    b:=sample_build(&p,{hash_of("a")})
    list:=sample_list()
    valid:[Parser]string
    valid[.Package],_=package_text(&p,context.temp_allocator)
    valid[.Build],_=build_text(&b,context.temp_allocator)
    valid[.Packages],_=packages_text(&list,context.temp_allocator)
    id:=`"00000000000000010000000000000001"`
    Case :: struct {parser:Parser,text:string,want:Error}
    cases:=[]Case{
        {.Package,"",.Corrupt},
        {.Package,strings.repeat(" ",RECORD_BYTES+1,context.temp_allocator),.Too_Large},
        {.Package,strings.concatenate({`{"version": 1, "settings": `,strings.repeat("[",200,context.temp_allocator)},context.temp_allocator),.Corrupt},
        {.Package,swap(valid[.Package],`"version": 1`,`"version": 2`),.Version},
        {.Package,swap(valid[.Package],`"id": "00000000000000070000000000000007"`,`"id": "00000000000000050000000000000005"`),.Corrupt},
        {.Package,swap(valid[.Package],`"version": 1`,`"version": 1, "version": 1`),.Corrupt},
        {.Package,swap(valid[.Package],`"version": 1`,`"version": 1, "extra": 1`),.Corrupt},
        {.Package,swap(valid[.Package],`"kind": "TEX"`,`"kind": "TOOLONG"`),.Corrupt},
        {.Package,swap(valid[.Package],`"index": 1`,`"index": -1`),.Corrupt},
        {.Package,swap(valid[.Package],`"part": true`,`"part": true, "part": false`),.Corrupt},
        {.Build,swap(valid[.Build],`"kind_version": `,`"kind_version": 70000`),.Corrupt},
        {.Build,swap(valid[.Build],`"final": true`,`"final": 1`),.Corrupt},
        {.Build,swap(valid[.Build],`"package": `,`"package": "00000000000000000000000000000000", "x": `),.Corrupt},
        {.Build,`{"version": 1}`,.Corrupt},
        {.Packages,fmt.tprintf(`{{"version": 1, "packages": [{{"id": %s, "manifest": "nothex", "folder": "", "assets": []}}]}}`,id),.Corrupt},
        {.Packages,fmt.tprintf(`{{"version": 1, "packages": [{{"id": %s, "manifest": "%s", "folder": "a/../b", "assets": []}}]}}`,id,strings.repeat("0",64,context.temp_allocator)),.Corrupt},
        {.Packages,fmt.tprintf(`{{"version": 1, "packages": [{{"id": %s, "manifest": "%s", "folder": "", "assets": [%s, %s]}}]}}`,id,strings.repeat("0",64,context.temp_allocator),id,id),.Corrupt},
        {.Packages,`{"version": 1, "packages": []} {}`,.Corrupt},
        {.Packages,`{"version": 18446744073709551616, "packages": []}`,.Corrupt},
    }
    for c,at in cases {
        testing.expectf(t,at==0 || c.text!="","case %d changes a text it has",at)
        got:=parse(c.parser,c.text,context.temp_allocator)
        testing.expectf(t,got==c.want,"case %d (%v): %v, not %v",at,c.parser,got,c.want)
    }
    h:=base.Hostile{state=7}
    random:=make([]u8,4096,context.temp_allocator)
    for parser in Parser {
        text:=strings.trim_right(valid[parser],"\n")
        for cut in 0..<len(text) {
            got:=parse(parser,text[:cut],context.temp_allocator)
            testing.expectf(t,got!=.None,"%v cut at %d reads",parser,cut)
        }
        for _ in 0..<64 {
            bytes:=random[:base.hostile_int(&h,len(random))]
            for &c in bytes {c=u8(base.hostile_next(&h))}
            testing.expect(t,parse(parser,string(bytes),context.temp_allocator)!=.None,"random bytes do not read")
            // A valid text with one byte changed reads, or fails, without stopping.
            changed:=transmute([]u8)strings.clone(valid[parser],context.temp_allocator)
            changed[base.hostile_int(&h,len(changed))]=u8(base.hostile_next(&h))
            _=parse(parser,string(changed),context.temp_allocator)
        }
        testing.expect_value(t,parse(parser,valid[parser],failing_allocator()),Error.Out_Of_Memory)
    }
    _,refused:=package_text(&p,failing_allocator())
    testing.expect_value(t,refused,Error.Out_Of_Memory)
    folder:=base.test_folder(t,"packages-hostile");if folder=="" {return}
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",folder,PACKAGES_FILE),transmute([]u8)string("{\"version\""))==nil)
    _,found,load_error:=packages_load(folder,context.temp_allocator)
    testing.expect(t,!found && load_error==.Corrupt,"a damaged list is an error, never an empty one")
}

// A root carries the text of each manifest it pins: a store without one takes
// it from the root's file and lists its assets not built, and root_packages
// says so by package. A file that is not the manifest its pin names, or that
// does not read, is reported by package, never listed; with neither a file
// nor the manifest in the store, the package is missing.
@(test)
a_root_carries_the_manifests_it_pins :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"packages-files");if folder=="" {return}
    ingested,open_error:=store.open(fmt.tprintf("%s/ingested",folder),context.temp_allocator)
    if !testing.expect_value(t,open_error,store.Error.None) {return}
    fresh,fresh_error:=store.open(fmt.tprintf("%s/fresh",folder),context.temp_allocator)
    if !testing.expect_value(t,fresh_error,store.Error.None) {return}
    root:=fmt.tprintf("%s/game",folder)
    p:=sample_package()
    manifest,_:=package_put(&ingested,&p)
    list:Packages
    list.packages=make([dynamic]Project_Package,context.temp_allocator)
    append(&list.packages,Project_Package{id=p.id,manifest=manifest,folder="kit"})
    testing.expect_value(t,package_file_save(&ingested,root,&list.packages[0]),Error.None)
    testing.expect_value(t,packages_save(root,&list),Error.None)
    wrong:=Project_Package{id={8,8},manifest=manifest}
    testing.expect_value(t,package_file_save(&ingested,root,&wrong),Error.Corrupt)
    testing.expect(t,!os.exists(package_file(root,wrong.id)),"a manifest of another package is not written as this one's")

    resolved,error:=packages_resolve(&fresh,root,&list,context.temp_allocator)
    if !testing.expect_value(t,error,Error.None) {return}
    testing.expectf(t,len(resolved.problems)==0 && len(resolved.listed)==4,"%v %v",resolved.problems,resolved.listed)
    for l in resolved.listed {testing.expectf(t,l.state==.Not_Built,"%s is not built without a build",l.path)}
    testing.expect(t,store.has(&fresh,manifest),"the manifest of the root goes into the store, at the address it pins")
    lines,_:=root_packages(root,fresh.root,context.temp_allocator)
    testing.expectf(t,len(lines.listed)==4 && len(lines.problems)==1 && strings.contains(lines.problems[0],"crate"),"not built, said by package: %v",lines.problems)
    testing.expect_value(t,store.remove(&fresh,manifest),store.Error.None)

    file:=package_file(root,p.id)
    text,_:=package_text(&p,context.temp_allocator)
    hostile,_:=strings.replace(text,"crate","crane",1,context.temp_allocator)
    garbage:="{\"version\": 1, \"id\": 7}"
    Case :: struct {bytes:string,pin:store.Hash,want:Package_Problem_Code}
    cases:=[]Case{
        {hostile,manifest,.Manifest_Mismatch},
        {garbage,hash_of(garbage),.Manifest_Unreadable},
        {strings.repeat(" ",RECORD_BYTES+1,context.temp_allocator),manifest,.Manifest_Unreadable},
        {"",manifest,.Manifest_Missing},
    }
    for c,at in cases {
        if c.bytes=="" {os.remove(file)} else {testing.expect(t,os.write_entire_file(file,transmute([]u8)c.bytes)==nil)}
        list.packages[0].manifest=c.pin
        got,got_error:=packages_resolve(&fresh,root,&list,context.temp_allocator)
        if !testing.expect_value(t,got_error,Error.None) {continue}
        testing.expectf(t,len(got.listed)==0 && len(got.problems)==1 && got.problems[0].package_id==p.id && got.problems[0].code==c.want,"case %d: %v",at,got.problems)
        testing.expect_value(t,packages_save(root,&list),Error.None)
        said,_:=root_packages(root,fresh.root,context.temp_allocator)
        id:[base.ASSET_ID_TEXT]u8
        testing.expectf(t,len(said.problems)==1 && strings.contains(said.problems[0],base.asset_id_format(p.id,id[:])),"case %d is said by package: %v",at,said.problems)
    }
    testing.expect(t,!store.has(&fresh,manifest),"a file that is not its pin goes into no store")
    testing.expect_value(t,package_file_remove(root,p.id),Error.None)
    testing.expect_value(t,package_file_remove(root,p.id),Error.None)
}
