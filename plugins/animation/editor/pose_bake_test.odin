package animation_editor

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Pose_Bake_Test_World :: struct {
    entities:core.Entities,
    ids:core.Table(core.Id),transforms:core.Table(core.Transform),parents:core.Table(core.Parent),worlds:core.Table(core.World_Transform),
    names:core.Table(core.Name),targets:core.Table(anim.Animation_Target),animations:core.Table(anim.Animation),modifiers:core.Table(anim.Pose_Modifiers),
    meshes:core.Table(erender.Mesh_Renderer),morph_weights:core.Table(anim.Morph_Weights),sources:core.Table(anim.Pose_Source),
    attachments:core.Table(anim.Bone_Attachment),
    playback:anim.Playback,requests:anim.Animation_Requests,events:anim.Animation_Events,constraints:anim.Animation_Constraints,
    modifier_runtime:anim.Modifier_Runtime,modifier_requests:anim.Modifier_Requests,grounding:anim.Grounding_Runtime,morphs:anim.Morph_Playback,
    actions:anim.Action_Runtime,action_requests:anim.Action_Requests,motion_requests:anim.Motion_Requests,
    hierarchy:core.Hierarchy,propagation:core.Propagation,jumps:core.Jumps,
    progress:core.Table(anim.Animation_Progress),time:core.Time,frame:core.Frame_Time,problems:core.Problems,
}
Pose_Bake_Test_Shared :: struct {skeletons:anim.Skeleton_Assets,poses:anim.Pose_Assets,blends:anim.Blend_Assets,graphs:anim.Graph_Assets,sources:anim.Source_Assets,skin:anim.Skin_Runtime,actions:anim.Actions_Assets}
Pose_Bake_Test :: struct {authoring:Authoring_Test,world:Pose_Bake_Test_World,shared:Pose_Bake_Test_Shared,info:core.World_Info,rig:core.Entity}
@(private)
Pose_Bake_Failing_Copy :: struct {owner:runtime.Allocator,attempts,fail_at:int}
@(private)
pose_bake_failing_copy_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]u8,runtime.Allocator_Error) {
    state:=(^Pose_Bake_Failing_Copy)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {state.attempts+=1;if state.attempts==state.fail_at {return nil,.Out_Of_Memory}}
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(private)
pose_bake_test_settle :: proc(data,shared,editor:rawptr) {
    world:=(^Pose_Bake_Test_World)(data)
    core.table_settle(&world.ids,&world.entities);core.table_settle(&world.transforms,&world.entities);core.table_settle(&world.parents,&world.entities);core.table_settle(&world.worlds,&world.entities)
    core.hierarchy_settle(&world.hierarchy,core.read(&world.parents),&world.entities)
    core.table_settle(&world.names,&world.entities);core.table_settle(&world.targets,&world.entities);core.table_settle(&world.animations,&world.entities);core.table_settle(&world.modifiers,&world.entities)
    core.table_settle(&world.meshes,&world.entities);core.table_settle(&world.morph_weights,&world.entities);core.table_settle(&world.sources,&world.entities)
    core.table_settle(&world.attachments,&world.entities);core.table_settle(&world.progress,&world.entities)
}

// The functions animation_evaluate runs, bound as a generated world binds them.
@(private)
pose_bake_test_sample :: proc(data,shared,editor,app_data:rawptr,worker:int) {
    w,s:=(^Pose_Bake_Test_World)(data),(^Pose_Bake_Test_Shared)(shared)
    anim.animation_sample(core.read(&w.animations),&w.progress,core.read(&w.modifiers),core.read(&w.attachments),&w.transforms,core.read(&w.parents),core.ref(&w.hierarchy),core.read(&w.names),core.read(&w.targets),core.read(&w.meshes),core.read(&w.sources),&w.requests,&w.events,&w.modifier_requests,&w.modifier_runtime,&w.playback,&s.poses,&s.skeletons,(^host.App)(app_data),w.time,w.frame,&w.problems,&s.blends,&s.graphs,&w.actions,&w.action_requests,&s.actions,nil,&w.motion_requests,nil,&s.sources,{},core.CLOCK_DEFAULT)
    pose_bake_test_settle(data,shared,editor)
}
@(private)
pose_bake_test_advance :: proc(data,shared,editor,app_data:rawptr,worker:int) {
    w,s:=(^Pose_Bake_Test_World)(data),(^Pose_Bake_Test_Shared)(shared)
    anim.animation_advance(core.read(&w.modifiers),&w.transforms,core.read(&w.parents),core.read(&w.worlds),&w.modifier_requests,&w.modifier_runtime,&w.playback,&w.constraints,&w.grounding,{},{},w.time,&w.requests,core.ref(&s.skeletons),&w.problems,nil,nil,{},{},core.CLOCK_DEFAULT)
    pose_bake_test_settle(data,shared,editor)
}
@(private)
pose_bake_test_morph :: proc(data,shared,editor,app_data:rawptr,worker:int) {
    w,s:=(^Pose_Bake_Test_World)(data),(^Pose_Bake_Test_Shared)(shared)
    anim.animation_morph(core.read(&w.meshes),core.read(&w.morph_weights),core.read(&w.animations),core.read(&w.targets),core.read(&w.sources),core.read(&w.parents),core.ref(&w.playback),core.ref(&w.modifier_runtime),&s.skin,&w.morphs,nil,(^host.App)(app_data),w.time,&w.problems)
}
@(private)
pose_bake_test_propagate :: proc(data,shared,editor,app_data:rawptr,worker:int) {
    w:=(^Pose_Bake_Test_World)(data)
    core.transforms_propagate(core.read(&w.transforms),core.ref(&w.hierarchy),&w.worlds,&w.propagation,&w.jumps,w.frame)
    pose_bake_test_settle(data,shared,editor)
}

@(private)
pose_bake_test_world_free :: proc(data:rawptr) {
    world:=(^Pose_Bake_Test_World)(data)
    anim.playback_free(&world.playback);anim.constraints_free(&world.constraints);anim.modifier_runtime_free(&world.modifier_runtime);anim.grounding_free(&world.grounding);anim.morph_playback_free(&world.morphs);anim.actions_runtime_free(&world.actions)
    core.value_free(world,type_info_of(Pose_Bake_Test_World))
}

@(private)
pose_bake_test_init :: proc(f:^Pose_Bake_Test,t:^testing.T,name:string) -> bool {
    if !authoring_test_init(&f.authoring,t,name) {return false}
    core.entities_init(&f.world.entities)
    tables:=make([]core.Table_Info,13,context.temp_allocator)
    tables[12]={type=anim.Animation_Progress,info=type_info_of(anim.Animation_Progress),offset=offset_of(Pose_Bake_Test_World,progress)}
    tables[0]={type=core.Id,info=type_info_of(core.Id),offset=offset_of(Pose_Bake_Test_World,ids)}
    tables[1]={type=core.Transform,info=type_info_of(core.Transform),offset=offset_of(Pose_Bake_Test_World,transforms)}
    tables[2]={type=core.Parent,info=type_info_of(core.Parent),offset=offset_of(Pose_Bake_Test_World,parents)}
    tables[3]={type=core.World_Transform,info=type_info_of(core.World_Transform),offset=offset_of(Pose_Bake_Test_World,worlds)}
    tables[4]={type=core.Name,info=type_info_of(core.Name),offset=offset_of(Pose_Bake_Test_World,names)}
    tables[5]={type=anim.Animation_Target,info=type_info_of(anim.Animation_Target),offset=offset_of(Pose_Bake_Test_World,targets)}
    tables[6]={type=anim.Animation,info=type_info_of(anim.Animation),offset=offset_of(Pose_Bake_Test_World,animations)}
    tables[7]={type=anim.Pose_Modifiers,info=type_info_of(anim.Pose_Modifiers),offset=offset_of(Pose_Bake_Test_World,modifiers)}
    tables[8]={type=erender.Mesh_Renderer,info=type_info_of(erender.Mesh_Renderer),offset=offset_of(Pose_Bake_Test_World,meshes)}
    tables[9]={type=anim.Morph_Weights,info=type_info_of(anim.Morph_Weights),offset=offset_of(Pose_Bake_Test_World,morph_weights)}
    tables[10]={type=anim.Pose_Source,info=type_info_of(anim.Pose_Source),offset=offset_of(Pose_Bake_Test_World,sources)}
    tables[11]={type=anim.Bone_Attachment,info=type_info_of(anim.Bone_Attachment),offset=offset_of(Pose_Bake_Test_World,attachments)}
    storages:=make([]core.Storage_Info,24,context.temp_allocator)
    storages[23]={type=core.Problems,info=type_info_of(core.Problems),offset=offset_of(Pose_Bake_Test_World,problems)}
    storages[21]={type=core.Frame_Time,info=type_info_of(core.Frame_Time),offset=offset_of(Pose_Bake_Test_World,frame)}
    storages[20]={type=core.Time,info=type_info_of(core.Time),offset=offset_of(Pose_Bake_Test_World,time)}
    storages[0]={type=anim.Playback,info=type_info_of(anim.Playback),offset=offset_of(Pose_Bake_Test_World,playback)}
    storages[1]={type=anim.Animation_Requests,info=type_info_of(anim.Animation_Requests),offset=offset_of(Pose_Bake_Test_World,requests)}
    storages[2]={type=anim.Animation_Events,info=type_info_of(anim.Animation_Events),offset=offset_of(Pose_Bake_Test_World,events)}
    storages[3]={type=anim.Animation_Constraints,info=type_info_of(anim.Animation_Constraints),offset=offset_of(Pose_Bake_Test_World,constraints)}
    storages[4]={type=anim.Modifier_Runtime,info=type_info_of(anim.Modifier_Runtime),offset=offset_of(Pose_Bake_Test_World,modifier_runtime)}
    storages[5]={type=anim.Modifier_Requests,info=type_info_of(anim.Modifier_Requests),offset=offset_of(Pose_Bake_Test_World,modifier_requests)}
    storages[6]={type=anim.Grounding_Runtime,info=type_info_of(anim.Grounding_Runtime),offset=offset_of(Pose_Bake_Test_World,grounding)}
    storages[7]={type=anim.Morph_Playback,info=type_info_of(anim.Morph_Playback),offset=offset_of(Pose_Bake_Test_World,morphs)}
    storages[8]={type=core.Hierarchy,info=type_info_of(core.Hierarchy),offset=offset_of(Pose_Bake_Test_World,hierarchy)}
    storages[9]={type=core.Jumps,info=type_info_of(core.Jumps),offset=offset_of(Pose_Bake_Test_World,jumps)}
    storages[10]={type=anim.Skeleton_Assets,info=type_info_of(anim.Skeleton_Assets),offset=offset_of(Pose_Bake_Test_Shared,skeletons),place=.Shared}
    storages[11]={type=anim.Pose_Assets,info=type_info_of(anim.Pose_Assets),offset=offset_of(Pose_Bake_Test_Shared,poses),place=.Shared}
    storages[12]={type=anim.Blend_Assets,info=type_info_of(anim.Blend_Assets),offset=offset_of(Pose_Bake_Test_Shared,blends),place=.Shared}
    storages[13]={type=anim.Graph_Assets,info=type_info_of(anim.Graph_Assets),offset=offset_of(Pose_Bake_Test_Shared,graphs),place=.Shared}
    storages[14]={type=anim.Source_Assets,info=type_info_of(anim.Source_Assets),offset=offset_of(Pose_Bake_Test_Shared,sources),place=.Shared}
    storages[15]={type=anim.Skin_Runtime,info=type_info_of(anim.Skin_Runtime),offset=offset_of(Pose_Bake_Test_Shared,skin),place=.Shared}
    storages[16]={type=anim.Action_Runtime,info=type_info_of(anim.Action_Runtime),offset=offset_of(Pose_Bake_Test_World,actions)}
    storages[17]={type=anim.Action_Requests,info=type_info_of(anim.Action_Requests),offset=offset_of(Pose_Bake_Test_World,action_requests)}
    storages[18]={type=anim.Actions_Assets,info=type_info_of(anim.Actions_Assets),offset=offset_of(Pose_Bake_Test_Shared,actions),place=.Shared}
    storages[19]={type=anim.Motion_Requests,info=type_info_of(anim.Motion_Requests),offset=offset_of(Pose_Bake_Test_World,motion_requests)}
    storages[22]={type=core.Propagation,info=type_info_of(core.Propagation),offset=offset_of(Pose_Bake_Test_World,propagation)}
    steps:=make([]core.Step_Info,4,context.temp_allocator)
    steps[0]={name="animation_sample",library="anim",call=pose_bake_test_sample}
    steps[1]={name="animation_advance",library="anim",call=pose_bake_test_advance}
    steps[2]={name="animation_morph",library="anim",call=pose_bake_test_morph}
    steps[3]={name="transforms_propagate",library="core",call=pose_bake_test_propagate}
    order:=make([]i32,4,context.temp_allocator)
    for &index,i in order {index=i32(i)}
    f.info={tables=tables,storages=storages,steps=steps,settle=pose_bake_test_settle}
    f.info.order[.Editor][.Fixed]=order
    f.info.sizes[.World],f.info.aligns[.World]=size_of(Pose_Bake_Test_World),align_of(Pose_Bake_Test_World)
    f.info.init[.World]=proc(data:rawptr,allocator:runtime.Allocator) -> bool {world:=(^Pose_Bake_Test_World)(data);world^={};core.entities_init(&world.entities,allocator);return len(world.entities.generation)>0}
    f.info.destroy[.World]=pose_bake_test_world_free
    f.info.copy=proc(dst,src:rawptr) -> bool {return core.value_copy(dst,src,type_info_of(Pose_Bake_Test_World))}
    f.authoring.app.info,f.authoring.app.shared=&f.info,&f.shared
    f.authoring.session.info,f.authoring.session.edit_world=&f.info,&f.world
    f.rig=core.create(&f.world.entities);core.add(&f.world.ids,f.rig,{value=17});core.add(&f.world.transforms,f.rig,core.from_math(mm.TRANSFORM_IDENTITY))
    parent:=f.rig
    for i in 1..=4 {
        entity:=core.create(&f.world.entities);name:=fmt.tprintf("joint%d",i)
        target:anim.Animation_Target;base.text_set(target.path[:],name);core.add(&f.world.targets,entity,target)
        transform:=mm.TRANSFORM_IDENTITY;if i>1 {transform.position.y=.5}
        core.add(&f.world.transforms,entity,core.from_math(transform));core.add(&f.world.parents,entity,{entity=parent});parent=entity
    }
    pose_bake_test_settle(&f.world,nil,nil)
    authoring_test_register(&f.authoring,t,"bake",Pose_Bake_Params,authoring_pose_bake,pose_bake_defaults())
    return true
}

@(private)
pose_bake_test_destroy :: proc(f:^Pose_Bake_Test) {
    pose_bake_test_world_free(&f.world)
    anim.skeleton_assets_free(&f.shared.skeletons);anim.pose_assets_free(&f.shared.poses);anim.blend_assets_free(&f.shared.blends);anim.graph_assets_free(&f.shared.graphs);anim.source_assets_free(&f.shared.sources);anim.skin_runtime_free(&f.shared.skin);anim.actions_assets_free(&f.shared.actions)
    delete(f.authoring.app.worlds)
    authoring_test_destroy(&f.authoring)
}

@(test)
pose_bake_uses_preview_actions_and_keeps_marker_crossings_across_discontinuous_sections :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"pose-bake-actions") {return};defer pose_bake_test_destroy(f)
    a:=&f.authoring;source_id,action_id:=base.Asset_Id{504,1},base.Asset_Id{504,2}
    root:asset.Animation_Root;base.text_set(root.bone[:],"joint1");root.translation=true
    clips:=[2]asset.Animation_Clip_Desc{{name="Idle"},{name="Reach",root=root,tracks={{target="joint1",property=.Position,keys={{time=0},{time=2,value={2,0,0,0}}}}},markers={{time=.1,name="start"},{time=1.1,name="end"}}}}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",a.root),&a.assets.types,{id=source_id,clips=clips[:]}),asset.Error.None)
    definition:=anim.ACTION_DEFINITION_DEFAULT;base.text_set(definition.name[:],"reach");base.text_set(definition.clip[:],"Reach");definition.fade_in,definition.fade_out=0,0;definition.root_motion=.In_Place
    sections:=[2]anim.Action_Section{{start=0,end=.25,next=1},{start=1,end=1.5,next=-1}};base.text_set(sections[0].name[:],"prepare");base.text_set(sections[1].name[:],"contact")
    testing.expect_value(t,anim.action_profile_save(fmt.tprintf("%s/reach.action",a.root),&a.assets.types,action_id,{info={animation=source_id},actions={definition},sections=sections[:]}),asset.Error.None);testing.expect(t,host.assets_scan(&a.assets))
    description:=anim.ANIMATION_DEFAULT;description.asset,description.actions=source_id,action_id;description.loop=false;base.text_set(description.clip[:],"Idle");core.add(&f.world.animations,f.rig,description);pose_bake_test_settle(&f.world,nil,nil)
    result:=authoring_test_execute(a,"bake",`{"id":"11","path":"action.anim","clip":"Final","start":0,"end":0.4,"rate":2.5,"actions":[{"kind":"Fire","name":"reach","tick":0}]}`);if !testing.expect(t,result.code==0,result.message) {return}
    file:asset.Asset;testing.expect_value(t,authoring_test_load(a,"action.anim",&file),asset.Error.None);defer asset.asset_close(&file)
    view,error:=asset.animation_view(&file,&a.assets.types);if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect(t,len(view.markers)==2 && abs(view.markers[0].time-.1)<1e-5 && abs(view.markers[1].time-.35)<1e-5 && view.clips[0].root.translation)
    for &track in view.tracks {if base.text_get(track.target[:])=="joint1" && track.property==.Position {testing.expect_value(t,track.key_count,2);testing.expect(t,abs(view.keys[track.first_key+1].value.x-.4)<1e-5)}}
    testing.expect(t,len(f.world.actions.states)==0 && len(f.world.action_requests.queue.items)==0)
}

@(test)
pose_bake_samples_final_constraints_curves_markers_blended_root_and_exact_partial_endpoint_in_an_isolated_world :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"pose-bake-final") {return};defer pose_bake_test_destroy(f)
    a:=&f.authoring;source_id,pose_id,other_id:=base.Asset_Id{501,1},base.Asset_Id{501,2},base.Asset_Id{501,3}
    root:asset.Animation_Root;base.text_set(root.bone[:],"joint1");root.translation,root.rotation=true,true
    clips:=make([]asset.Animation_Clip_Desc,2,context.temp_allocator)
    for &clip,i in clips {
        angle:=f32(.8) if i==0 else 1.2;rotation:=mm.quat_axis_angle({0,1,0},angle)
        clip={name="walk" if i==0 else "run",root=root,tracks={
            {target="joint1",property=.Position,keys={{time=0,value={}},{time=1,value={2 if i==0 else 4,0,0,0}}}},
            {target="joint1",property=.Rotation,keys={{time=0,value={0,0,0,1}},{time=1,value=lib.quat_vec4(rotation)}}},
            {target="pulse",property=.Float,keys={{time=0,value={}},{time=1,value={1 if i==0 else 2,0,0,0}}}},
            {target="direction",property=.Vector,keys={{time=0,value={1,2,3,4}},{time=1,value={2,3,4,5}}}},
        },markers={{time=.1,name="history"},{time=.35,name="step" if i==0 else "stride"}}}
        path:="source.anim" if i==0 else "other.anim";id:=source_id if i==0 else other_id
        testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/%s",a.root,path),&a.assets.types,{id=id,clips=clips[i:i+1]}),asset.Error.None)
    }
    ik:=anim.IK_CONSTRAINT_DEFAULT;ik.root,ik.joint,ik.end=anim.bone_ref("joint2"),anim.bone_ref("joint3"),anim.bone_ref("joint4")
    corrective:=anim.POSE_CORRECTIVE_DEFAULT;base.text_set(corrective.name[:],"root-offset");corrective.driver,corrective.bone=anim.bone_ref("joint1"),anim.bone_ref("joint1");base.text_set(corrective.curve[:],"bulge");corrective.sample_count=1;corrective.samples[0]=anim.POSE_CORRECTIVE_SAMPLE_DEFAULT;corrective.samples[0].delta.position={.1,0,0};corrective.samples[0].curve_value=.7
    testing.expect_value(t,anim.pose_profile_save(fmt.tprintf("%s/constraints.pose",a.root),&a.assets.types,pose_id,{ik={ik},correctives={corrective}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&a.assets))
    authoring_test_register(a,t,"graph",Graph_Write_Params,program_graph_set,program_graph_defaults())
    result:=authoring_test_execute(a,"graph",fmt.tprintf(`{{"path":"blend.agraph","animation":"%s","output":"mix","nodes":[{{"name":"walk","kind":"Clip","clip":"walk"}},{{"name":"run","kind":"Clip","clip":"run","animation":"%s"}},{{"name":"mix","kind":"Blend","left":"walk","right":"run","weight":0.5}}]}}`,authoring_test_id_text(source_id),authoring_test_id_text(other_id)))
    if !testing.expect(t,result.code==0,result.message) {return}
    animation:=anim.ANIMATION_DEFAULT;animation.asset=authoring_test_id(a,"blend.agraph");animation.root_motion=.In_Place;core.add(&f.world.animations,f.rig,animation);core.add(&f.world.modifiers,f.rig,{profile=pose_id,weight=1,enabled=true});pose_bake_test_settle(&f.world,nil,nil)
    before:=f.world.transforms.values[1]
    result=authoring_test_execute(a,"bake",`{"id":"11","path":"final.anim","clip":"Baked","start":0.2,"end":0.57,"rate":10,"goals":[{"kind":"IK","name":"joint4","target":{"position":[1,1,0]}}]}`)
    if !testing.expect(t,result.code==0,result.message) {return}
    testing.expect(t,f.world.transforms.values[1]==before && len(f.world.playback.states)==0 && len(f.world.modifier_requests.queue.items)==0)
    file:asset.Asset;testing.expect_value(t,authoring_test_load(a,"final.anim",&file),asset.Error.None);defer asset.asset_close(&file)
    output,error:=asset.animation_view(&file,&a.assets.types);if !testing.expect_value(t,error,asset.Error.None) {return}
    testing.expect(t,len(output.clips)==1 && output.clips[0].root==root && len(file.dependencies)==0)
    testing.expect(t,len(output.markers)==2)
    for &marker in output.markers {testing.expect(t,abs(marker.time-.15)<1e-5 && base.text_get(marker.name[:])!="history")}
    saw_unkeyed_bone,saw_pulse,saw_vector,saw_corrective:bool
    for &track in output.tracks {
        keys:=output.keys[track.first_key:][:track.key_count];testing.expect(t,len(keys)==5 && keys[0].time==0 && abs(keys[4].time-.37)<1e-6)
        name:=base.text_get(track.target[:])
        if name=="joint2" && track.property==.Rotation {saw_unkeyed_bone=mm.quat_angle(lib.vec4_quat(keys[4].value),mm.QUAT_IDENTITY)>.1}
        if name=="pulse" {saw_pulse=abs(keys[4].value.x-.855)<1e-4}
        if name=="direction" {saw_vector=keys[4].value.w>4.5}
        if name=="bulge" {saw_corrective=abs(keys[4].value.x-.7)<1e-5}
        if name=="joint1" && track.property==.Position {testing.expect(t,keys[0].value.x>.69 && keys[4].value.x>1.79)}
    }
    testing.expect(t,saw_unkeyed_bone && saw_pulse && saw_vector && saw_corrective)
    library:lib.Library;desc:=asset.animation_library_desc(output);testing.expect(t,lib.library_init(&library,desc));defer lib.library_destroy(&library);testing.expect(t,asset.animation_clips_add(output,&library,.Once)>0)
    actor,wanted:=mm.TRANSFORM_IDENTITY,mm.TRANSFORM_IDENTITY;previous:f32
    for frame in 1..=4 {
        time:=min(f32(frame)/10,f32(.37));dt:=time-previous
        moved,turned:=lib.clip_root_motion(&library,lib.Clip(1),base.name_hash("joint1"),previous,time)
        correction:=mm.quat_rotate(mm.quat_axis_angle({0,1,0},time+.2),{.1,0,0})-mm.quat_rotate(mm.quat_axis_angle({0,1,0},previous+.2),{.1,0,0})
        expected:=mm.Vec3{dt*3,0,0}+correction
        testing.expect(t,linalg.length(moved-expected)<1e-4 && mm.quat_angle(turned,mm.quat_axis_angle({0,1,0},dt))<.001)
        actor.position+=mm.quat_rotate(actor.rotation,moved);actor.rotation*=turned
        wanted.position+=mm.quat_rotate(wanted.rotation,expected);wanted.rotation*=mm.quat_axis_angle({0,1,0},dt)
        previous=time
    }
    testing.expect(t,linalg.length(actor.position-wanted.position)<1e-4 && mm.quat_angle(actor.rotation,wanted.rotation)<.001)
    result=authoring_test_execute(a,"bake",`{"id":"11","path":"in-place.anim","clip":"Still","start":0.2,"end":0.57,"rate":10,"root_motion":"In_Place","goals":[{"kind":"IK","name":"joint4","target":{"position":[1,1,0]}}]}`)
    if !testing.expect(t,result.code==0,result.message) {return}
    in_place:asset.Asset;testing.expect_value(t,authoring_test_load(a,"in-place.anim",&in_place),asset.Error.None);defer asset.asset_close(&in_place)
    still,loaded:=asset.animation_view(&in_place,&a.assets.types);testing.expect_value(t,loaded,asset.Error.None);testing.expect(t,!still.clips[0].root.translation && !still.clips[0].root.rotation)
    for &track in still.tracks {if base.text_get(track.target[:])!="joint1" {continue};for key in still.keys[track.first_key:][:track.key_count] {
        if track.property==.Position {testing.expect(t,abs(key.value.x-.1)<1e-5 && abs(key.value.z)<1e-5)}
        if track.property==.Rotation {testing.expect(t,mm.quat_angle(lib.vec4_quat(key.value),mm.QUAT_IDENTITY)<.001)}
    }}
}

@(test)
pose_bake_preserves_other_clips_and_undoes_without_publishing_on_failure :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"pose-bake-publication") {return};defer pose_bake_test_destroy(f)
    a:=&f.authoring;source_id:=base.Asset_Id{502,1}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/source.anim",a.root),&a.assets.types,{id=source_id,clips={{name="Still"}}}),asset.Error.None);testing.expect(t,host.assets_scan(&a.assets))
    animation:=anim.ANIMATION_DEFAULT;animation.asset=source_id;core.add(&f.world.animations,f.rig,animation);pose_bake_test_settle(&f.world,nil,nil)
    result:=authoring_test_execute(a,"bake",`{"id":"11","path":"final.anim","clip":"Still","start":0,"end":0.1,"rate":10}`);if !testing.expect(t,result.code==0,result.message) {return}
    output_id:=authoring_test_id(a,"final.anim");revision:=authoring_test_revision(a,"final.anim")
    result=authoring_test_execute(a,"bake",`{"id":"11","path":"final.anim","clip":"Other","start":0,"end":0.1,"rate":10}`);if !testing.expect(t,result.code==0,result.message) {return}
    file:asset.Asset;testing.expect_value(t,authoring_test_load(a,"final.anim",&file),asset.Error.None)
    view,error:=asset.animation_view(&file,&a.assets.types);testing.expect(t,error==.None && len(view.clips)==2 && len(view.tracks)==30);asset.asset_close(&file)
    failure:=Pose_Bake_Failing_Copy{owner=a.app.allocator,fail_at=3};saved:=a.app.allocator;a.app.allocator={pose_bake_failing_copy_allocator,&failure}
    result=authoring_test_execute(a,"bake",`{"id":"11","path":"oom.anim","clip":"Still","start":0,"end":0.1,"rate":10}`)
    a.app.allocator=saved;testing.expect(t,result.code!=0 && failure.attempts==3 && strings.contains(result.message,"copied") && !authoring_test_exists(a,"oom.anim"))
    testing.expect_value(t,authoring_test_execute(a,"bake",`{"id":"11","path":"bad.anim","clip":"Still","start":0.2,"end":0.1}`).code,api.INVALID_PARAMS)
    testing.expect(t,!authoring_test_exists(a,"bad.anim"))
}

@(test)
pose_bake_creates_editable_tracks_from_an_unanimated_skeleton_and_exports_final_morph_defaults_and_overrides :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"pose-bake-zero") {return};defer pose_bake_test_destroy(f)
    a:=&f.authoring;skeleton_id,mesh_id,profile_id:=base.Asset_Id{503,1},base.Asset_Id{503,2},base.Asset_Id{503,3}
    bones:[3]asset.Skeleton_Bone
    for &bone,i in bones {bone={parent=i32(i)-1,rotation=1,scale={1,1,1}};if i>0 {bone.translation.y=1};name:=fmt.tprintf("joint%d",i+1);base.text_set(bone.name[:],name);base.text_set(bone.path[:],name);bone.target=base.name_hash(name)}
    testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/rig.skeleton",a.root),&a.assets.types,{id=skeleton_id,bones=bones[:]}),asset.Error.None)
    vertices:=[3]asset.Vertex{{position={0,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}};skin:[3]asset.Skin_Vertex;for &vertex in skin {vertex.weights[0]=255}
    target:=asset.Morph_Target{weight=.2,count=1};base.text_set(target.name[:],"Smile")
    testing.expect_value(t,source_mesh_save(fmt.tprintf("%s/rig.mesh",a.root),&a.assets.types,{id=mesh_id,skeleton=skeleton_id,joints={{node=0,inverse_bind=1}}},{vertices=vertices[:],skin=skin[:],morphs={target},morph_deltas={{vertex=0,position={.1,0,0}}}},{0,1,2}),asset.Error.None)
    follow:=anim.FOLLOW_CONSTRAINT_DEFAULT;follow.bone=anim.bone_ref("joint2");follow.target=anim.spatial_point({.3,1,0});base.text_set(follow.name[:],"hand")
    corrective:=anim.POSE_CORRECTIVE_DEFAULT;corrective.driver=anim.bone_ref("joint1");corrective.apply_pose=false;corrective.sample_count=1;corrective.samples[0]=anim.POSE_CORRECTIVE_SAMPLE_DEFAULT;corrective.samples[0].curve_value=.3;base.text_set(corrective.curve[:],"Smile");base.text_set(corrective.name[:],"face")
    testing.expect_value(t,anim.pose_profile_save(fmt.tprintf("%s/procedural.pose",a.root),&a.assets.types,profile_id,{follow={follow},correctives={corrective}}),asset.Error.None);testing.expect(t,host.assets_scan(&a.assets))
    core.add(&f.world.meshes,f.rig,{mesh=mesh_id});core.add(&f.world.modifiers,f.rig,{profile=profile_id,weight=1,enabled=true});pose_bake_test_settle(&f.world,nil,nil)
    testing.expect(t,core.count(&f.world.animations)==0 && core.count(&f.world.sources)==0 && len(f.world.playback.states)==0)
    expected:=[4]f32{.2,.7,.8,.6};paths:=[4]string{"zero.anim","default.anim","override.anim","additive.anim"}
    modes:=[4]anim.Morph_Weight_Mode{.Default,.Default,.Override,.Additive};values:=[4]f32{0,.4,.8,.1}
    for pass in 0..<4 {
        if pass>0 {weights:=anim.Morph_Weights{source=f.rig};anim.morph_weight_set(&weights,"Smile",values[pass],modes[pass]);core.add(&f.world.morph_weights,f.rig,weights);pose_bake_test_settle(&f.world,nil,nil)}
        path:=paths[pass]
        result:=authoring_test_execute(a,"bake",fmt.tprintf(`{{"id":"11","path":"%s","clip":"Pose","start":0,"end":0.1,"rate":10}}`,path));if !testing.expect(t,result.code==0,result.message) {return}
        file:asset.Asset;testing.expect_value(t,authoring_test_load(a,path,&file),asset.Error.None)
        view,error:=asset.animation_view(&file,&a.assets.types);if !testing.expect_value(t,error,asset.Error.None) {asset.asset_close(&file);return}
        saw_rest,saw_follow,saw_morph:bool
        for &track in view.tracks {
            key:=view.keys[track.first_key];name:=base.text_get(track.target[:])
            if name=="joint3" && track.property==.Position {saw_rest=key.value.y==1}
            if name=="joint2" && track.property==.Position {saw_follow=abs(key.value.x-.3)<1e-5}
            if name=="/@morph/Smile" {saw_morph=abs(key.value.x-expected[pass])<1e-5}
        }
        testing.expect(t,saw_rest && saw_follow && saw_morph && len(file.dependencies)==0);asset.asset_close(&file)
    }
    testing.expect(t,core.count(&f.world.animations)==0 && len(f.world.playback.states)==0)
}
