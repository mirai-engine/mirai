package editor

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:project"
import "mirai:std/jobs"

@(test)
recovery_copy_is_written_by_a_job_and_read_back :: proc(t:^testing.T) {
    world:Prefab_Test_World
    prefab_test_init(&world,context.allocator)
    defer prefab_test_destroy(&world)
    tables:=[4]core.Table_Info{
        {name="Id",type=core.Id,info=type_info_of(core.Id),offset=offset_of(Prefab_Test_World,ids)},
        {name="Name",type=core.Name,info=type_info_of(core.Name),offset=offset_of(Prefab_Test_World,names)},
        {name="Transform",type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Prefab_Test_World,transforms)},
        {name="Parent",type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Prefab_Test_World,parents)},
    }
    storages:=[2]core.Storage_Info{{type=Prefabs,place=.Editor},{type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Prefab_Test_World,hierarchy)}}
    info:=core.World_Info{tables=tables[:],storages=storages[:],clear=prefab_test_clear,copy=prefab_test_copy,swap=prefab_test_swap,
        sizes={.World=size_of(Prefab_Test_World),.Shared=0,.Editor=0},aligns={.World=align_of(Prefab_Test_World),.Shared=1,.Editor=1},
        init={.World=prefab_test_init,.Shared=nil,.Editor=nil},destroy={.World=prefab_test_destroy,.Shared=nil,.Editor=nil}}
    root:=project.path_absolute(fmt.tprintf(".mirai/test-recovery-%d",os.get_pid()),context.temp_allocator)
    testing.expect(t,!os.exists(root))
    if os.exists(root) {return}
    os.make_directory_all(root)
    defer os.remove_all(root)
    assets:host.Assets
    asset.types_init(&assets.types)
    defer asset.types_destroy(&assets.types)
    asset.registry_init(&assets.registry,root)
    defer asset.registry_destroy(&assets.registry)
    app:=host.App{assets=&assets,info=&info,allocator=context.allocator}
    defer delete(app.worlds)
    // One thread besides the caller: the copy is written beside it.
    testing.expect(t,jobs.system_init(&app.jobs,{threads=1,allocator=context.allocator}))
    defer jobs.system_destroy(&app.jobs)
    selection:history.Selection
    edits:history.Edits
    document:Document
    prefabs:Prefabs
    s:=Session{info=&info,edit_world=&world,editor_world=&prefabs,assets_root=root,project_root=root,app=&app,selection=&selection,edits=&edits,document=&document}
    defer delete(selection.entities)
    defer history.edits_free(&edits)
    defer document_previous_free(&document)
    defer prefabs_free(&s)
    w:=edited_world(&s)
    entity_create(&s,{name="Kept",transform={position={2,0,0},rotation=1,scale={1,1,1}}})
    core.world_settle(w)
    history.edits_reset(&edits,w)

    testing.expect(t,document_recovery(&s))
    testing.expect(t,s.recovery.write.busy)
    testing.expect(t,recovery_wait(&s))
    testing.expect(t,!s.recovery.write.busy && s.recovery.owned)
    testing.expect_value(t,s.recovery.saved,history.edits_state(&edits))

    file:=recovery_file(&s,s.recovery.slot)
    copy:asset.Scene
    testing.expect_value(t,asset.scene_load(&copy,&assets.types,file),asset.Error.None)
    defer asset.scene_destroy(&copy)
    testing.expect(t,len(copy.index)==1 && asset.scene_entity(&copy,0).name=="Kept")
    _,has_info:=asset.document_table(&copy.doc,RECOVERY_TABLE)
    testing.expect(t,has_info)

    testing.expect(t,recovery_remove(&s))
    testing.expect(t,!os.exists(file))
}
