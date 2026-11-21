package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:cook/textures"
import "mirai:editor/api"
import "mirai:project"
import "mirai:rhi/shared_device"
import "mirai:std/base"
import "mirai:store"

// Importing a source from outside the project ingests it where it is and
// pins its package: the project lists its texture from the store and copies
// nothing. Moving its root changes where the package is listed, and deleting
// it unpins the package and leaves the store and the source as they were.
@(test)
a_source_from_outside_is_pinned_listed_moved_and_unpinned_without_copies :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t)
    if device==nil {return}
    l:=new(Library_Test,context.temp_allocator)
    top:=base.test_folder(t,"editor-library")
    if top=="" || !library_test_open(t,l,"editor-library-game",fmt.tprintf("%s/store",top)) {return}
    defer library_test_close(l)
    if !testing.expect_value(t,textures.gpu_context_init(&l.s.import_gpu,device,""),
        textures.Error.None) {return}
    s:=&l.s
    r:=&l.assets.registry
    source:=library_test_source(t,top)
    before,_:=os.read_entire_file(source,context.temp_allocator)

    if !testing.expect(t,import_file(s,source,"props"),string(s.importer.message[:s.importer.message_length])) || !library_test_end(t,l) {return}
    pins:=library_test_pins(l.root)
    if !testing.expect_value(t,len(pins),1) {return}
    testing.expect_value(t,pins[0].folder,"props")
    file,found:=asset.registry_find_path(r,"props/sign.png.tex")
    if !found {file,found=asset.registry_find_path(r,"props/sign.tex")}
    if !testing.expectf(t,found && file.listed,"the texture is listed from the package: %v",r.listed) {return}
    id:=file.id
    object,built:=asset.registry_listed_object(r,file.path)
    testing.expect(t,built && store.chunk_has(&s.store,object),"the texture is an object of the store")
    testing.expectf(t,len(library_test_files(project.path(l.root,"assets",allocator=context.temp_allocator)))==0,"nothing is copied into the assets")
    after,_:=os.read_entire_file(source,context.temp_allocator)
    testing.expect(t,string(before)==string(after),"the source is as it was")

    // Its root moves where the package is listed, keeping its name.
    _,message:=asset_move(s,id,"props","other")
    testing.expect(t,strings.has_prefix(message,"name:"),message)
    path:string
    path,message=asset_move(s,id,"textures","")
    testing.expectf(t,message=="" && strings.has_prefix(path,"textures/"),"%s %s",path,message)
    testing.expect_value(t,library_test_pins(l.root)[0].folder,"textures")
    moved,_:=asset.registry_find(r,id)
    testing.expect(t,moved!=nil && moved.path==path)

    // Deleting it unpins the package: the store and the source stay.
    gone,refused:=asset_delete(s,id)
    testing.expectf(t,refused=="" && len(gone)==1 && gone[0]==path,"%v %s",gone,refused)
    testing.expect_value(t,len(library_test_pins(l.root)),0)
    _,listed:=asset.registry_find(r,id)
    testing.expect(t,!listed,"what it listed left the project")
    testing.expect(t,store.chunk_has(&s.store,object),"the object stays in the store")
    testing.expect(t,os.is_file(source),"the source outside the project stays")
}

// A package of the library added to a second project lists the blobs the
// first one does; packages.list and packages.add say for each hostile
// argument what failed and how to fix it.
@(test)
a_package_of_the_library_goes_to_a_second_project_with_the_same_blobs :: proc(t:^testing.T) {
    device:=shared_device.take_or_skip(t)
    if device==nil {return}
    top:=base.test_folder(t,"editor-library-add")
    if top=="" {return}
    kept:=fmt.tprintf("%s/store",top)
    first:=new(Library_Test,context.temp_allocator)
    if !library_test_open(t,first,"editor-library-first",kept) {return}
    defer library_test_close(first)
    if !testing.expect_value(t,textures.gpu_context_init(&first.s.import_gpu,device,""),
        textures.Error.None) {return}
    source:=library_test_source(t,top)
    if !testing.expect(t,import_file(&first.s,source,"")) || !library_test_end(t,first) {return}
    pin:=library_test_pins(first.root)[0]
    file:^asset.Registry_File
    for &f in first.assets.registry.files {
        if f.listed {file=&f}
    }
    if !testing.expect(t,file!=nil) {return}
    blob:=strings.clone(asset.registry_file_path(&first.assets.registry,file.path,context.temp_allocator),context.temp_allocator)

    second:=new(Library_Test,context.temp_allocator)
    if !library_test_open(t,second,"editor-library-second",kept) {return}
    defer library_test_close(second)
    s:=&second.s
    call :: proc(s:^Session,run:proc(s:^Session,call:^api.Call),params:^$P,$R:typeid) -> api.Call {
        method:=api.Method{params_id=P,result_id=R}
        call:=api.Call{method=&method,params=params,result=new(R,context.temp_allocator),allocator=context.temp_allocator}
        run(s,&call)
        call.method,call.params=nil,nil
        return call
    }
    listing:Api_Packages_List_Params
    listed:=call(s,api_packages_list,&listing,Api_Packages_List_Result)
    result:=(^Api_Packages_List_Result)(listed.result)
    if !testing.expectf(t,!listed.failed && result!=nil && len(result.packages)==1,"%s",listed.error.message) {return}
    p:=result.packages[0]
    testing.expect(t,p.id==pin.id && !p.pinned && len(p.assets)==1 && p.assets[0].built && p.assets[0].bytes>0 && p.assets[0].kind=="texture")

    Hostile :: struct {name:string,assets:[]string,folder,says:string}
    buffer:[base.ASSET_ID_TEXT]u8
    named:=strings.clone(base.asset_id_format(pin.id,buffer[:]),context.temp_allocator)
    hostile:=[?]Hostile{
        {"",nil,"","packages.list"},
        {"nothing such",nil,"","packages.list"},
        {named,{"zz"},"","packages.list"},
        {named,{"0123456789abcdef0123456789abcdef"},"","packages.list"},
        {named,nil,"../out","folder:"},
        {named,nil,".editor/x","folder:"},
    }
    for h in hostile {
        params:=Api_Packages_Add_Params{name=h.name,assets=h.assets,folder=h.folder}
        answer:=call(s,api_packages_add,&params,Import_Status_Result)
        testing.expectf(t,answer.failed && answer.error.code==api.INVALID_PARAMS && strings.contains(answer.error.message,h.says),"%v: %s",h,answer.error.message)
        testing.expect(t,s.importer.running==nil,"nothing starts")
    }
    params:=Api_Packages_Add_Params{name=named,folder="shared"}
    added:=call(s,api_packages_add,&params,Import_Status_Result)
    if !testing.expectf(t,!added.failed,"%s",added.error.message) || !library_test_end(t,second) {return}
    pins:=library_test_pins(second.root)
    testing.expect(t,len(pins)==1 && pins[0].id==pin.id && pins[0].folder=="shared")
    there,found:=asset.registry_find(&second.assets.registry,file.id)
    testing.expect(t,found && strings.has_prefix(there.path,"shared/") && asset.registry_file_path(&second.assets.registry,there.path,context.temp_allocator)==blob,"the same blob")

    // Without a store nothing lists or imports, and each says how to give one.
    store.close(&s.store)
    without:=call(s,api_packages_list,&listing,Api_Packages_List_Result)
    testing.expect(t,without.failed && strings.contains(without.error.message,"--store"),without.error.message)
    testing.expect(t,!import_file(s,source,""))
    testing.expect(t,strings.contains(string(s.importer.message[:s.importer.message_length]),"--store"))
    opened,_:=store.open(kept)
    s.store=opened
    testing.expect(t,!import_file(s,fmt.tprintf("%s/none.png",top),""))
    testing.expect(t,strings.contains(string(s.importer.message[:s.importer.message_length]),"does not exist"))
}
