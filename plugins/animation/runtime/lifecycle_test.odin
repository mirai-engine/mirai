package anim

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"

@(test)
bone_references_reject_overflow_embedded_zero_and_unterminated_storage_without_targeting_root :: proc(t:^testing.T) {
    state:Playing;defer playing_free(&state)
    append(&state.targets,u64(0));append(&state.targets,base.name_hash("foot"))
    full:[asset.NODE_PATH_CAPACITY]u8;for &byte in full {byte='a'}
    valid,ok:=bone_ref(string(full[:len(full)-1]))
    testing.expect(t,ok && base.text_get(valid.path[:])==string(full[:len(full)-1]))
    invalid,accepted:=bone_ref(string(full[:]))
    testing.expect(t,!accepted && bone_resolve(&state,invalid)==-1)
    invalid,accepted=bone_ref("foot\x00other")
    testing.expect(t,!accepted && bone_resolve(&state,invalid)==-1)
    invalid=Bone_Ref{path=full}
    testing.expect_value(t,bone_resolve(&state,invalid),-1)
    root,root_ok:=bone_ref("")
    testing.expect(t,root_ok && bone_resolve(&state,root)==0)
    testing.expect_value(t,bone_resolve(&state,bone_ref("foot")),1)
    requests:Animation_Requests;defer delete(requests.poses.items)
    animation_pose(&requests,core.entity_make(1,1),invalid,mm.TRANSFORM_IDENTITY)
    testing.expect_value(t,len(requests.poses.items),0)
    testing.expect_value(t,requests.poses.refused,1)
    library:lib.Library
    testing.expect_value(t,root_motion_sample(&library,{},Root_Motion{bone=invalid,translation=true},1),ROOT_DELTA_DEFAULT)
}

@(private="file")
Lifecycle_World :: struct {
    using world:core.Test_World,
    transforms:core.Table(core.Transform),
    modifiers:Modifier_Runtime,
}

@(test)
recreated_skeletons_get_distinct_bindings_and_replace_constraint_and_grounding_bone_indices :: proc(t:^testing.T) {
    w:Lifecycle_World
    if !core.test_world_init(t,&w,test_types) {return}
    defer core.test_world_destroy(&w)
    rig:=core.create(&w.entities)
    core.add(&w.transforms,rig,core.TRANSFORM_IDENTITY);core.test_world_settle(&w)
    playback:Playback;defer playback_free(&playback)
    bones:=[3]asset.Skeleton_Bone{
        {parent=-1,translation={0,1,0},rotation=1,scale={1,1,1}},
        {parent=0,translation={0,-0.5,0},rotation=1,scale={1,1,1}},
        {parent=1,translation={0,-0.5,0},rotation=1,scale={1,1,1}},
    }
    paths:=[3]string{"hip","hip/knee","hip/knee/foot"}
    names:=[3]string{"hip","knee","foot"}
    for &bone,i in bones {
        path,name:=paths[i],names[i]
        base.text_set(bone.path[:],path);base.text_set(bone.name[:],name);bone.target=base.name_hash(path)
    }
    definition:=Skeleton_Content{id={9,8},revision=1,bones=bones[:]}
    state:=state_get(&playback,rig)
    testing.expect(t,skeleton_bind(&playback,state,&definition,nil,&w.transforms))
    first:=state.bound
    config:=FOOT_GROUNDING_DEFAULT;config.count=1;config.adjust_body=false
    config.legs[0]=GROUNDED_LEG_DEFAULT;config.legs[0].hip=bone_ref("hip");config.legs[0].knee=bone_ref("knee");config.legs[0].foot=bone_ref("foot")
    grounding:Grounding_Runtime;defer grounding_free(&grounding)
    append(&grounding.records,Grounding_Record{});append(&grounding.hierarchies,Grounding_Hierarchy{})
    record:=&grounding.records[0]
    testing.expect(t,grounding_bind(&grounding,0,state,config,1,nil))
    testing.expect_value(t,record.bones[0],[3]int{1,2,3})
    leg:=IK_CONSTRAINT_DEFAULT;leg.root=bone_ref("hip");leg.joint=bone_ref("knee");leg.end=bone_ref("foot")
    core.add(&w.modifiers.ik,rig,leg);core.table_settle(&w.modifiers.ik,&w.entities)
    constraints:=Constraint_Rig{entity=rig};defer constraint_rig_free(&constraints)
    append(&constraints.rows[0],0)
    inputs:=Constraint_Inputs{ik=core.read(&w.modifiers.ik)}
    testing.expect(t,constraints_bind(state,inputs,&constraints))
    testing.expect_value(t,constraints.bones[0][0],[3]int{1,2,3})
    playing_free(state)
    state.entity=rig
    expanded:[4]asset.Skeleton_Bone
    expanded[0]={parent=-1,rotation=1,scale={1,1,1},target=base.name_hash("other")}
    base.text_set(expanded[0].path[:],"other");base.text_set(expanded[0].name[:],"other")
    copy(expanded[1:],bones[:]);expanded[2].parent=1;expanded[3].parent=2
    definition.bones=expanded[:]
    testing.expect(t,skeleton_bind(&playback,state,&definition,nil,&w.transforms))
    testing.expect(t,state.bound>first)
    testing.expect(t,grounding_bind(&grounding,0,state,config,1,nil))
    testing.expect_value(t,record.bones[0],[3]int{2,3,4})
    testing.expect(t,constraints_bind(state,inputs,&constraints))
    testing.expect_value(t,constraints.bones[0][0],[3]int{2,3,4})
    testing.expect_value(t,len(state.previous),len(state.local))
}

@(test)
skeleton_and_skin_content_retry_every_allocation_failure_without_publishing_partial_reload :: proc(t:^testing.T) {
    directory:=base.test_folder(t,"animation-content-retry")
    skeleton_path:=fmt.tprintf("%s/rig.skeleton",directory)
    mesh_path:=fmt.tprintf("%s/rig.mesh",directory)
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    bone:=asset.Skeleton_Bone{parent=-1,rotation=1,scale={1,1,1},target=base.name_hash("root")}
    base.text_set(bone.path[:],"root");base.text_set(bone.name[:],"root")
    skeleton_id,mesh_id:=base.Asset_Id{9,10},base.Asset_Id{11,12}
    if !testing.expect_value(t,asset.skeleton_save(skeleton_path,&types,{id=skeleton_id,bones={bone}}),asset.Error.None) {return}
    vertices:=[3]asset.Vertex{{position={0,0,0}},{position={1,0,0}},{position={0,1,0}}}
    influences:=[3]asset.Skin_Vertex{};for &influence in influences {influence.weights[0]=255}
    if !testing.expect_value(t,rig_mesh_save(mesh_path,&types,{id=mesh_id,skeleton=skeleton_id,joints={{node=0,inverse_bind=1}}},vertices[:],{0,1,2},influences[:]),asset.Error.None) {return}
    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root=directory})) {return}
    defer host.assets_destroy(&assets)
    failure:=Runtime_Allocation_Failure{owner=context.allocator,remaining=1000}
    saved_context:=context
    context.allocator={runtime_failure_allocator,&failure}
    defer context=saved_context
    app:=host.App{assets=&assets,allocator=context.allocator}
    skeleton_record,_:=asset.registry_find(&assets.registry,skeleton_id)
    mesh_record,_:=asset.registry_find(&assets.registry,mesh_id)
    skeleton_success,skin_success:=false,false
    for budget in 0..<512 {
        skeletons:Skeleton_Assets;skins:Skin_Runtime;skins.allocator=context.allocator
        failure.remaining=1000
        content:=skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)
        index:=skin_rig_load(&skins,app.assets,app.allocator,mesh_id,nil,core.NONE)
        if !testing.expect(t,content!=nil && index!=max(u32)) {skeleton_assets_free(&skeletons);skin_runtime_free(&skins);return}
        old_bones:=raw_data(content.bones);old_joints:=raw_data(skins.rigs[index].joints)
        old_skeleton_revision,old_skin_revision:=content.revision,skins.rigs[index].revision
        skeleton_record.time+=1;mesh_record.time+=1;assets.revision+=1
        failure.remaining=budget
        reloaded:=skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)
        if reloaded==nil {
            testing.expect_value(t,raw_data(skeletons.contents[0].bones),old_bones)
            testing.expect_value(t,skeletons.contents[0].revision,old_skeleton_revision)
        } else {skeleton_success=true}
        failure.remaining=budget
        new_index:=skin_rig_load(&skins,app.assets,app.allocator,mesh_id,nil,core.NONE)
        if new_index==max(u32) {
            testing.expect_value(t,raw_data(skins.rigs[index].joints),old_joints)
            testing.expect_value(t,skins.rigs[index].revision,old_skin_revision)
        } else {skin_success=true}
        failure.remaining=1000
        testing.expect(t,skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)!=nil)
        testing.expect_value(t,skin_rig_load(&skins,app.assets,app.allocator,mesh_id,nil,core.NONE),index)
        testing.expect_value(t,len(skeletons.contents),1);testing.expect_value(t,len(skins.rigs),1)
        skeleton_assets_free(&skeletons);skin_runtime_free(&skins)
        if skeleton_success && skin_success {break}
    }
    testing.expect(t,skeleton_success && skin_success)
    for budget in 0..<4 {
        skeletons:Skeleton_Assets;skins:Skin_Runtime;skins.allocator=context.allocator
        failure.remaining=budget
        skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)
        failure.remaining=budget
        skin_rig_load(&skins,app.assets,app.allocator,mesh_id,nil,core.NONE)
        failure.remaining=1000
        testing.expect(t,skeleton_content(&skeletons,app.assets,app.allocator,skeleton_id)!=nil)
        testing.expect_value(t,skin_rig_load(&skins,app.assets,app.allocator,mesh_id,nil,core.NONE),u32(0))
        testing.expect_value(t,len(skeletons.contents),1);testing.expect_value(t,len(skins.rigs),1)
        skeleton_assets_free(&skeletons);skin_runtime_free(&skins)
    }
}

