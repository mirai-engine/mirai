package editor

import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:editor/api"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"

@(private="file") DISK_TEST_PREFAB :: base.Asset_Id{0x510ad101,0x1}

@(private="file")
disk_test_prefab :: proc(t:^testing.T,types:^asset.Types,path:string,names:..string) {
    sc:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&sc,types,asset.KIND_PREFAB,DISK_TEST_PREFAB),asset.Error.None) {return}
    defer asset.scene_destroy(&sc)
    for name,i in names {asset.scene_entity_add(&sc,base.Entity_Id(i+1),0,name)}
    sc.info.root=1
    testing.expect_value(t,asset.scene_save(&sc,path),asset.Error.None)
}

// What a tool writes to an asset is what a call finds, whether the editor
// draws frames by itself or not; unsaved changes stay.
@(test)
a_call_finds_what_changed_on_disk_and_unsaved_changes_stay :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) {return}
    defer platform.destroy(p)
    f:=new(Files_Test,context.temp_allocator)
    files_test_open(f,"mirai-assets-disk")
    defer files_test_close(f)
    assets:host.Assets
    root:=project.path(f.root,"assets",allocator=context.temp_allocator)
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,platform=p}
    f.s.app=&app
    host.app_assets_watch_reset(&app)
    defer {app.assets_watch={}}
    blade:=project.path(root,"blade.prefab",allocator=context.temp_allocator)
    disk_test_prefab(t,&assets.types,blade,"Blade")
    host.assets_scan(&assets)
    loaded:=host.assets_scene(&assets,DISK_TEST_PREFAB)
    if !testing.expect(t,loaded!=nil) {return}
    first:=loaded.blob.header.content_hash
    host.app_assets_watch_now(&app)

    disk_test_prefab(t,&assets.types,blade,"Blade","Hand_Attach")
    host.app_assets_watch_now(&app)
    now:=host.assets_scene(&assets,DISK_TEST_PREFAB)
    testing.expect(t,now!=nil && now.blob.header.content_hash!=first,"the editor holds what the file holds now")

    held,_:=os.read_entire_file(blade,context.temp_allocator)
    testing.expect_value(t,asset.registry_memory_set(&assets.registry,"blade.prefab",held),asset.Error.None)
    disk_test_prefab(t,&assets.types,blade,"Blade","Hand_Attach","Sheath")
    host.app_assets_watch_now(&app)
    if memory,found:=asset.registry_memory_find(&assets.registry,"blade.prefab");testing.expect(t,found) {
        testing.expect(t,slice.equal(memory.data,held),"the unsaved bytes stay")
    }
}

// Without names asset.save writes what the turn of the caller changed, and
// outside a turn everything unsaved.
@(test)
asset_save_without_names_writes_the_unsaved_assets_of_the_caller :: proc(t:^testing.T) {
    f:=new(Files_Test,context.temp_allocator)
    files_test_open(f,"mirai-assets-caller")
    defer files_test_close(f)
    assets:host.Assets
    root:=project.path(f.root,"assets",allocator=context.temp_allocator)
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets}
    f.s.app=&app
    s:=&f.s
    for name in ([]string{"mine.prefab","theirs.prefab"}) {
        testing.expect_value(t,asset.registry_memory_set(&assets.registry,name,transmute([]u8)string("x")),asset.Error.None)
    }
    m:=new(Ai,context.temp_allocator)
    s.ai=m
    m.task_count=1
    task:=&m.tasks[0]
    task.id=1
    base.text_set(task.name[:],"turn-1")
    defer delete(task.review.changed_files)
    append(&task.review.changed_files,project.path(root,"mine.prefab",allocator=context.temp_allocator))

    turn:=api.Call{raw="{}",client_tag="turn-1",allocator=context.temp_allocator}
    params:Api_Unsaved_Params
    paths,ok:=api_unsaved_paths(s,&turn,&params,of_caller=true)
    testing.expect(t,ok && len(paths)==1 && paths[0]=="mine.prefab")

    outside:=api.Call{raw="{}",allocator=context.temp_allocator}
    params={}
    paths,ok=api_unsaved_paths(s,&outside,&params,of_caller=true)
    testing.expect(t,ok && len(paths)==2)

    named:=api.Call{raw="{}",allocator=context.temp_allocator}
    params={}
    _,ok=api_unsaved_paths(s,&named,&params)
    testing.expect(t,!ok && named.failed,"asset.discard names what it takes back")
}
