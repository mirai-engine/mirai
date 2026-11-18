package editor

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "mirai:asset"
import img "mirai:cook/image"
import "mirai:cook/import/sources"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import "mirai:std/base"
import "mirai:store"

// asset.import takes by name what an image holds and where a model stands
// facing, and by its id the skeleton the clips of a model go on, and says
// what it takes when given another.
@(test)
asset_import_takes_the_settings_of_a_source_and_says_what_each_takes :: proc(t:^testing.T) {
    Setting :: enum {Image,Skeleton,Front}
    Case :: struct {setting:Setting,path,wrong,says,known:string}
    cases:=[?]Case{
        {.Image,"T_Katana_MR.png","metallic","data","Data"},
        {.Skeleton,"walk.glb","crusader","skeleton","0123456789abcdef0123456789abcdef"},
        {.Front,"walk.glb","up","negative_x","Negative_X"},
    }
    imports:Importer
    s:=Session{app=&host.App{},importer=&imports}
    run :: proc(s:^Session,c:Case,value:string) -> api.Call {
        params:Import_Params
        base.text_set(params.path[:],c.path)
        switch c.setting {
        case .Image:    base.text_set(params.image[:],value)
        case .Skeleton: base.text_set(params.skeleton[:],value)
        case .Front:    base.text_set(params.front[:],value)
        }
        method:=api.Method{params_id=Import_Params}
        call:=api.Call{method=&method,params=&params,allocator=context.temp_allocator}
        api_asset_import(s,&call)
        call.method,call.params=nil,nil
        return call
    }
    for c in cases {
        wrong:=run(&s,c,c.wrong)
        testing.expectf(t,wrong.failed && wrong.error.code==api.INVALID_PARAMS && strings.contains(wrong.error.message,c.says),"%v: %s",c.setting,wrong.error.message)
        // A value it knows passes on to the import, which here has no asset folder to write into.
        known:=run(&s,c,c.known)
        testing.expectf(t,known.failed && known.error.code==api.SERVER_ERROR && strings.contains(known.error.message,"asset folder"),"%v: %s",c.setting,known.error.message)
    }
}

@(test)
asset_import_reads_a_relative_source_from_the_project :: proc(t:^testing.T) {
    s:=Session{project_root="C:/game"}
    testing.expect_value(t,asset_import_source(&s,"assets/hero/walk.glb"),"C:/game/assets/hero/walk.glb")
    testing.expect_value(t,asset_import_source(&s,"C:/elsewhere/walk.glb"),"C:/elsewhere/walk.glb")
}

// A project of the editor over a store of its own, as a session has them.
@(private="file")
Library_Test :: struct {
    using files:Files_Test,
    assets:host.Assets,
    app:host.App,
    importer:Importer,
}

@(private="file")
library_test_open :: proc(t:^testing.T,l:^Library_Test,name,store_folder:string) -> bool {
    files_test_open(t,&l.files,name) or_return
    if !testing.expect(t,host.assets_init(&l.assets,{root=project.path(l.root,"assets",allocator=context.temp_allocator),capacity=16})) {return false}
    l.app=host.App{assets=&l.assets}
    l.s.app,l.s.importer=&l.app,&l.importer
    opened,error:=store.open(store_folder)
    l.s.store=opened
    return testing.expect_value(t,error,store.Error.None)
}

@(private="file")
library_test_close :: proc(l:^Library_Test) {
    import_end(&l.s)
    store.close(&l.s.store)
    host.assets_destroy(&l.assets)
    files_test_close(&l.files)
}

// Waits for the import that runs and takes what it wrote, as the frames do.
@(private="file")
library_test_end :: proc(t:^testing.T,l:^Library_Test,loc:=#caller_location) -> bool {
    job:=l.s.importer.running
    if !testing.expect(t,job!=nil,"an import runs",loc=loc) {return false}
    for !intrinsics.atomic_load(&job.done) {thread.yield()}
    import_poll(&l.s)
    status:=&l.s.importer.status
    return testing.expectf(t,status.ok,"%s",base.text_get(status.message[:]),loc=loc)
}

// The files under folder, by path.
@(private="file")
library_test_files :: proc(folder:string) -> []string {
    out:=make([dynamic]string,context.temp_allocator)
    todo:=make([dynamic]string,context.temp_allocator)
    append(&todo,folder)
    for next:=0;next<len(todo);next+=1 {
        entries,_:=os.read_all_directory_by_path(todo[next],context.temp_allocator)
        for entry in entries {
            path:=fmt.tprintf("%s/%s",todo[next],entry.name)
            if entry.type==.Directory {append(&todo,path)} else {append(&out,path)}
        }
    }
    return out[:]
}

@(private="file")
library_test_pins :: proc(root:string) -> []asset.Project_Package {
    list,_,_:=asset.packages_load(root,context.temp_allocator)
    return list.packages[:]
}

// A PNG outside the project, as a download is.
@(private="file")
library_test_source :: proc(t:^testing.T,folder:string) -> string {
    pixels:=make([]u8,8*8*4,context.temp_allocator)
    for &p,at in pixels {p=u8(at*7)}
    path:=fmt.tprintf("%s/downloads/sign.png",folder)
    os.make_directory_all(filepath.dir(path))
    testing.expect_value(t,img.image_write(path,{pixels=pixels,width=8,height=8}),img.Error.None)
    return path
}

// Importing a source from outside the project ingests it where it is and
// pins its package: the project lists its texture from the store and copies
// nothing. Moving its root changes where the package is listed, and deleting
// it unpins the package and leaves the store and the source as they were.
@(test)
a_source_from_outside_is_pinned_listed_moved_and_unpinned_without_copies :: proc(t:^testing.T) {
    l:=new(Library_Test,context.temp_allocator)
    top:=base.test_folder(t,"editor-library")
    if top=="" || !library_test_open(t,l,"editor-library-game",fmt.tprintf("%s/store",top)) {return}
    defer library_test_close(l)
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
    blob:=asset.registry_file_path(r,file.path,context.temp_allocator)
    testing.expectf(t,strings.has_prefix(blob,s.store.root),"%s is a blob of the store",blob)
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
    testing.expect(t,os.is_file(blob),"the blob stays in the store")
    testing.expect(t,os.is_file(source),"the source outside the project stays")
}

// A package of the library added to a second project lists the blobs the
// first one does; packages.list and packages.add say for each hostile
// argument what failed and how to fix it.
@(test)
a_package_of_the_library_goes_to_a_second_project_with_the_same_blobs :: proc(t:^testing.T) {
    top:=base.test_folder(t,"editor-library-add")
    if top=="" {return}
    kept:=fmt.tprintf("%s/store",top)
    first:=new(Library_Test,context.temp_allocator)
    if !library_test_open(t,first,"editor-library-first",kept) {return}
    defer library_test_close(first)
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
