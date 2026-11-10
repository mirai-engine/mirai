package animation_editor

import "core:testing"
import "core:strings"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:editor/history"
import "mirai:project"
import mm "mirai:std/math"
import "mirai:std/serial"
import anim "plugins:animation/runtime"

@(private="file")
Sequence_Test_World :: struct {
    using world:core.Test_World,
    ids:core.Table(core.Id),
    parents:core.Table(core.Parent),
    transforms:core.Table(core.Transform),
    sequences:core.Table(anim.Keyframe_Path),
}

@(test)
sequence_capture_converts_parent_space_and_is_one_undoable_api_transaction :: proc(t:^testing.T) {
    w:Sequence_Test_World
    if !core.test_world_init(t,&w,anim.test_types) {return}
    defer core.test_world_destroy(&w)
    root,owner,source:=core.create(&w.entities),core.create(&w.entities),core.create(&w.entities)
    core.add(&w.ids,root,{1});core.add(&w.ids,owner,{2});core.add(&w.ids,source,{3})
    pose:=core.TRANSFORM_IDENTITY;pose.position.x=10;core.add(&w.transforms,root,pose)
    pose.position.x=2;core.add(&w.transforms,owner,pose)
    pose.position.x=16;core.add(&w.transforms,source,pose)
    core.add(&w.parents,owner,{entity=root});core.add(&w.sequences,owner,anim.keyframe_path_default())
    core.test_world_settle(&w)
    world:=core.test_world_ref(&w)
    selection:history.Selection;defer delete(selection.entities)
    edits:history.Edits;defer history.edits_free(&edits)
    viewport:editor.Viewport;gui:editor.Editor_Ui
    session:=editor.Session{edit_world=&w,info=core.test_world_info(&w),selection=&selection,edits=&edits,viewport=&viewport,gui=&gui}
    history.edits_reset(&edits,world)
    params:=Sequence_Capture_Params{frame=1};copy(params.entity[:],"0000000000000002");copy(params.source[:],"0000000000000003")
    captured_result:Sequence_Edit_Result
    method:=api.Method{params_id=Sequence_Capture_Params,result_id=Sequence_Edit_Result}
    call:=api.Call{method=&method,params=&params,result=&captured_result,allocator=context.temp_allocator}
    sequence_capture(&session,&call)
    testing.expect(t,!call.failed && w.sequences.values[0].frames[1].pose.position.x==6)
    testing.expect(t,edits.cursor==1 && w.transforms.values[1].position.x==2)
    testing.expect(t,history.undo(&edits,world,&selection))
    testing.expect(t,w.sequences.values[0].frames[1].pose==mm.TRANSFORM_IDENTITY)
    testing.expect(t,history.redo(&edits,world,&selection))
    testing.expect(t,w.sequences.values[0].frames[1].pose.position.x==6)
    core.get(&w.sequences,owner).relative=true
    history.edits_commit(&edits,world,&selection)
    previous:=w.sequences.values[0]
    sequence_capture(&session,&call)
    testing.expect(t,call.failed && w.sequences.values[0]==previous)
    copy(params.reference[:],"0000000000000001");call.failed=false
    sequence_capture(&session,&call)
    testing.expect(t,!call.failed && w.sequences.values[0].frames[1].pose.position.x==6)
    preview_params:=Sequence_Preview_Params{time=0.5};copy(preview_params.entity[:],"0000000000000002")
    result:Sequence_Preview_Result
    method.params_id=Sequence_Preview_Params;method.result_id=Sequence_Preview_Result
    call.params,call.result=&preview_params,&result
    version:=w.sequences.version
    sequence_preview(&session,&call)
    testing.expect(t,!call.failed && result.pose.position.x==5 && w.sequences.version==version)
    server:api.Server;testing.expect_value(t,api.server_init(&server,{max_connections=1,max_methods=2}),api.Init_Error.None);defer api.server_destroy(&server)
    writer:serial.Writer;serial.writer_init(&writer,4096);defer serial.writer_destroy(&writer)
    defaults:=sequence_set_defaults()
    testing.expect_value(t,api.method_register(&server,{name="set",params=Sequence_Set_Params,params_info=type_info_of(Sequence_Set_Params),result=Sequence_Edit_Result,result_info=type_info_of(Sequence_Edit_Result),defaults=&defaults,user=&session,handler=proc(call:^api.Call) {sequence_set((^editor.Session)(call.user),call)}}),api.Register_Error.None)
    method_set:=api.method_find(&server,"set");error,_:=api.method_execute(&server,method_set,`{"entity":"0000000000000002","value":{"frames":[{}, {"duration":2}]}}`,&writer)
    testing.expect(t,error.code==0 && w.sequences.values[0].count==2 && w.sequences.values[0].frames[0].pose==mm.TRANSFORM_IDENTITY && w.sequences.values[0].frames[1].duration==2,error.message)
    testing.expect(t,strings.contains(string(serial.writer_bytes(&writer)),`"queued": false`))
    before:=w.sequences.values[0];cursor:=edits.cursor;serial.writer_reset(&writer)
    error,_=api.method_execute(&server,method_set,`{"entity":"0000000000000002","value":{"frames":[]}}`,&writer)
    testing.expect(t,error.code==api.INVALID_PARAMS && strings.contains(error.data,`"path":"value.frames"`) && w.sequences.values[0]==before && edits.cursor==cursor)
}

// What git and the tools know of the kinds of the plugin without loading it.
@(test)
the_manifest_declares_the_asset_kinds_the_plugin_registers :: proc(t:^testing.T) {
    m,error:=project.plugin_read(#directory+"../plugin.mirai")
    testing.expect_value(t,error.code,project.Error_Code.None)
    testing.expect_value(t,editor.asset_kinds_differ(ANIMATION_KINDS_DEFAULT.provider,&m),"")
}
