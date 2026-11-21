package editor

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "mirai:asset"
import img "mirai:cook/image"
import importer "mirai:cook/import"
import "mirai:cook/import/sources"
import "mirai:core"
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
    ROOT :: "C:/game" when ODIN_OS==.Windows else "/game"
    SOURCE :: "C:/elsewhere/walk.glb" when ODIN_OS==.Windows else "/elsewhere/walk.glb"
    s:=Session{project_root=ROOT}
    testing.expect_value(t,asset_import_source(&s,"assets/hero/walk.glb"),ROOT+"/assets/hero/walk.glb")
    testing.expect_value(t,asset_import_source(&s,SOURCE),SOURCE)
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

@(test)
asset_import_uses_the_whole_sources_documents_folder_and_reports_its_root_scene :: proc(t:^testing.T) {
    top:=base.test_folder(t,"editor-map")
    l:=new(Library_Test,context.temp_allocator)
    if top=="" || !library_test_open(t,l,"editor-map-game",fmt.tprintf("%s/store",top)) {return}
    defer library_test_close(l)
    Provider :: struct {provider:Import_Source_Provider}
    claims :: proc(path:string,head:[]u8) -> bool {return string(head)=="a cave map"}
    run :: proc(state:rawptr,source:string,options:importer.Import_Options,allocator:mem.Allocator) -> (
        report:importer.Import_Report,scene:string,error:importer.Error,
    ) {
        outputs:importer.Outputs
        bytes,_:=os.read_entire_file(source,context.temp_allocator)
        error=importer.outputs_begin(&outputs,source,"Cave",u64(len(bytes)),base.hash64(bytes),
            importer.import_version(1),options,"Test map",allocator)
        if error.code!=.None {return}
        cave,cave_path,_:=importer.output_root(&outputs,asset.KIND_SCENE,"Cave",".scene")
        lamp,lamp_path:=importer.output_part(&outputs,asset.KIND_SCENE,"Lamp",0,".scene")
        defer if error.code!=.None && outputs.source!="" {importer.outputs_end(&outputs,true)}
        types:asset.Types
        asset.types_init(&types,context.temp_allocator)
        for item in ([2]struct{id:base.Asset_Id,name,path:string}{
            {lamp,"Lamp",lamp_path},{cave,"Cave",cave_path},
        }) {
            doc:asset.Scene
            if asset.scene_init(&doc,&types,item.id,context.temp_allocator)!=.None ||
               asset.scene_save(&doc,item.path)!=.None {
                return {}, "", importer.error_make(.Write,"could not write %s",item.name)
            }
            if error=importer.output_written(&outputs,item.id,item.name);error.code!=.None {return}
        }
        report,error=importer.outputs_end(&outputs,false,allocator)
        return
    }
    storage:=core.Storage_Info{place=.Editor,info=type_info_of(Provider),default=proc(dst:rawptr) {
        (^Provider)(dst).provider={source={name="Test map",version=1,claims=claims,run=run}}
    }}
    info:=core.World_Info{storages={storage}}
    l.s.info=&info
    Case :: struct {source,folder,scene:string}
    for c in ([]Case{
        {"assets/maps/inside/Cave.map","","maps/inside/Cave/Cave.scene"},
        {"assets/maps/relative/Cave.map","maps/selected","maps/selected/Cave/Cave.scene"},
        {"assets/maps/root/Cave.map","/","Cave/Cave.scene"},
    }) {
        source:=project.path(l.root,c.source,allocator=context.temp_allocator)
        if !testing.expect_value(t,base.make_directory_all(filepath.dir(source)),nil) ||
           !testing.expect_value(t,os.write_entire_file(source,"a cave map"),nil) {return}
        params:Import_Params
        base.text_set(params.path[:],c.source)
        base.text_set(params.folder[:],c.folder)
        method:=api.Method{params_id=Import_Params,result_id=Import_Status_Result}
        result:Import_Status_Result
        call:=api.Call{method=&method,params=&params,result=&result,allocator=context.temp_allocator}
        api_asset_import(&l.s,&call)
        if !testing.expectf(t,!call.failed,"%s",call.error.message) || !library_test_end(t,l) {return}
        api_asset_import_status(&l.s,&call)
        testing.expect_value(t,result.scene,c.scene)
        testing.expect(t,os.is_file(project.path(l.root,"assets",c.scene,allocator=context.temp_allocator)))
    }
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

// A source whose import wrote a document of the project that changed since is
// not imported again without a word: asset.import fails naming it and how to
// go on, and the import of the content browser asks, with the documents that
// changed.
@(test)
importing_over_a_changed_document_asks_first :: proc(t:^testing.T) {
    root:=base.test_folder(t,"import-changed")
    if root=="" {return}
    folder:=fmt.tprintf("%s/assets",root)
    os.make_directory_all(folder)
    assets:host.Assets
    asset.types_init(&assets.types);defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,folder);defer asset.registry_destroy(&assets.registry)
    hall:=base.Asset_Id{7,9}
    scene:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&scene,&assets.types,hall,context.temp_allocator),asset.Error.None) {return}
    _,_=asset.scene_entity_add(&scene,asset.scene_new_id(&scene),{},"Added")
    testing.expect_value(t,asset.scene_save(&scene,fmt.tprintf("%s/hall.scene",folder)),asset.Error.None)
    asset.scene_destroy(&scene)
    source:=fmt.tprintf("%s/hall.gltf",folder)
    _=os.write_entire_file(source,"{}")
    testing.expect_value(t,asset.registry_scan(&assets.registry),asset.Error.None)
    // The package the source was ingested as, whose scene the pin says was written as something else.
    kept,opened:=store.open(fmt.tprintf("%s/store",root))
    if !testing.expect_value(t,opened,store.Error.None) {return}
    defer store.close(&kept)
    p:=asset.Package{id={5,5},name="hall",origin={path="assets/hall.gltf",importer="gltf"}}
    p.assets=make([dynamic]asset.Package_Asset,context.temp_allocator)
    append(&p.assets,asset.Package_Asset{kind=asset.KIND_SCENE,name="hall",id=hall})
    manifest,put_error:=asset.package_put(&kept,&p)
    if !testing.expect_value(t,put_error,asset.Error.None) {return}
    name:[64]u8
    testing.expect_value(t,store.ref_set(&kept,asset.REF_ORIGINS,asset.origin_name(importer.path_key(source),&name),manifest),store.Error.None)
    list:asset.Packages
    list.packages=make([dynamic]asset.Project_Package,context.temp_allocator)
    entry:=asset.Project_Package{id=p.id,manifest=manifest}
    entry.written=make([dynamic]asset.Package_Written,context.temp_allocator)
    append(&entry.written,asset.Package_Written{hall,1})
    append(&list.packages,entry)
    testing.expect_value(t,asset.packages_save(root,&list),asset.Error.None)

    imports:Importer
    gui:Editor_Ui
    defer delete(gui.import_changed)
    s:=Session{app=&host.App{assets=&assets},importer=&imports,gui=&gui,project_root=root,store=kept}
    params:Import_Params
    base.text_set(params.path[:],source)
    method:=api.Method{params_id=Import_Params}
    call:=api.Call{method=&method,params=&params,allocator=context.temp_allocator}
    api_asset_import(&s,&call)
    testing.expectf(t,call.failed && strings.contains(call.error.message,"hall.scene") && strings.contains(call.error.message,"discard_changes"),"%s",call.error.message)
    testing.expect(t,gui.modal==.None,"a call asks nobody")
    testing.expect(t,!import_file(&s,source,ask=true) && imports.running==nil,"nothing is imported")
    testing.expect(t,gui.modal==.Import_Changes && len(gui.import_changed)==1 && gui.import_changed[0]==hall && base.text_get(gui.import_source[:])==importer.path_key(source),"the user is asked, with what changed")
}
