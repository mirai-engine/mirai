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
@(private)
Library_Test :: struct {
    using files:Files_Test,
    assets:host.Assets,
    app:host.App,
    importer:Importer,
}

@(private)
library_test_open :: proc(t:^testing.T,l:^Library_Test,name,store_folder:string) -> bool {
    files_test_open(t,&l.files,name) or_return
    if !testing.expect(t,host.assets_init(&l.assets,{root=project.path(l.root,"assets",allocator=context.temp_allocator),capacity=16})) {return false}
    l.app=host.App{assets=&l.assets}
    l.s.app,l.s.importer=&l.app,&l.importer
    opened,error:=store.open(store_folder)
    l.s.store=opened
    return testing.expect_value(t,error,store.Error.None)
}

@(private)
library_test_close :: proc(l:^Library_Test) {
    import_end(&l.s)
    store.close(&l.s.store)
    host.assets_destroy(&l.assets)
    files_test_close(&l.files)
}

// Waits for the import that runs and takes what it wrote, as the frames do.
@(private)
library_test_end :: proc(t:^testing.T,l:^Library_Test,loc:=#caller_location) -> bool {
    job:=l.s.importer.running
    if !testing.expect(t,job!=nil,"an import runs",loc=loc) {return false}
    for !intrinsics.atomic_load(&job.done) {thread.yield()}
    import_poll(&l.s)
    status:=&l.s.importer.status
    return testing.expectf(t,status.ok,"%s",base.text_get(status.message[:]),loc=loc)
}

// The files under folder, by path.
@(private)
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

@(private)
library_test_pins :: proc(root:string) -> []asset.Project_Package {
    list,_,_:=asset.packages_load(root,context.temp_allocator)
    return list.packages[:]
}

// A PNG outside the project, as a download is.
@(private)
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
