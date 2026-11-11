package editor

import "core:os"
import "core:slice"
import "core:testing"
import "mirai:asset"
import "mirai:host"
import "mirai:platform"
import "mirai:project"
import "mirai:std/base"

@(private="file") DISK_TEST_PREFAB :: base.Asset_Id{0x510ad101,0x1}

@(private="file")
disk_test_prefab :: proc(t:^testing.T,types:^asset.Types,path:string,names:..string) {
    sc:asset.Scene
    if !testing.expect_value(t,asset.scene_init(&sc,types,DISK_TEST_PREFAB),asset.Error.None) {return}
    defer asset.scene_destroy(&sc)
    for name,i in names {asset.scene_entity_add(&sc,base.Entity_Id(i+1),0,name)}
    testing.expect_value(t,asset.scene_save(&sc,path),asset.Error.None)
}

// What a tool writes to an asset is what a call finds, whether the editor
// draws frames by itself or not; what the registry holds for a step not yet
// ended stays.
@(test)
a_call_finds_what_changed_on_disk_and_what_a_step_holds_stays :: proc(t:^testing.T) {
    p,error:=platform.create({headless=true,fixed_dt=1.0/60,pacing=platform.Frame_Pacing{}})
    if !testing.expect_value(t,error,platform.Error.None) {return}
    defer platform.destroy(p)
    f:=new(Files_Test,context.temp_allocator)
    if !files_test_open(t,f,"assets-disk") {return}
    defer files_test_close(f)
    assets:host.Assets
    root:=project.path(f.root,"assets",allocator=context.temp_allocator)
    if !testing.expect(t,host.assets_init(&assets,{root=root,capacity=16})) {return}
    defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,platform=p}
    f.s.app=&app
    app.assets_watch.watch,_=platform.watch_create(p,{path=root,recursive=true})
    defer platform.watch_destroy(p,app.assets_watch.watch)
    blade:=project.path(root,"blade.scene",allocator=context.temp_allocator)
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
    testing.expect_value(t,asset.registry_memory_set(&assets.registry,"blade.scene",held),asset.Error.None)
    disk_test_prefab(t,&assets.types,blade,"Blade","Hand_Attach","Sheath")
    host.app_assets_watch_now(&app)
    if memory,found:=asset.registry_memory_find(&assets.registry,"blade.scene");testing.expect(t,found) {
        testing.expect(t,slice.equal(memory.data,held),"the bytes the step holds stay")
    }
}
