package editor

import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/history"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/jobs"

@(test)
recovery_copy_is_written_by_a_job_and_read_back :: proc(t:^testing.T) {
    info,described:=prefab_test_info(t)
    if !described {return}
    defer core.test_info_destroy(&info)
    world:Prefab_Test_World
    if !testing.expect(t,info.init[.World](&world,context.allocator)) {return}
    defer info.destroy[.World](&world)
    root:=base.test_folder(t,"recovery")
    if root=="" {return}
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
    editor:Prefab_Fixture_Editor
    s:=Session{info=&info,edit_world=&world,editor_world=&editor,assets_root=root,project_root=root,app=&app,selection=&selection,edits=&edits,document=&document}
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
