package anim

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:host"

@(test)
modifier_preparation_ignores_unrelated_writes_reloads_only_changed_definitions_and_preserves_headers_on_failure :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    source,target,plain:=core.create(&entities),core.create(&entities),core.create(&entities)
    animations:core.Table(Animation);defer core.table_destroy(&animations)
    configs:core.Table(Pose_Modifiers);defer core.table_destroy(&configs)
    attachments:core.Table(Bone_Attachment);defer core.table_destroy(&attachments)
    description:=ANIMATION_DEFAULT;description.source=source;description.retarget={3,5}
    core.add(&animations,target,description);core.add(&animations,plain,ANIMATION_DEFAULT);core.table_settle(&animations,&entities)
    core.add(&configs,source,Pose_Modifiers{profile={3,4},weight=1,enabled=true});core.table_settle(&configs,&entities)
    profiles:=Pose_Assets{allocator=context.allocator};defer pose_assets_free(&profiles)
    profile:=Pose_Profile{look=make([]Look_Constraint,1)};profile.look[0]=LOOK_CONSTRAINT_DEFAULT;profile.look[0].bone=bone_ref("head")
    retarget:=Pose_Profile{retarget=make([]Retarget_Mapping,1)};retarget.retarget[0]=RETARGET_MAPPING_DEFAULT;retarget.retarget[0].mode=.Paths
    append(&profiles.contents,Pose_Content{id={3,4},checked=1,revision=1,profile=profile,valid=true},Pose_Content{id={3,5},checked=1,revision=1,profile=retarget,valid=true})
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    playback:Playback;defer playback_free(&playback)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    if !testing.expect(t,modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,app.assets,app.allocator,nil)) {return}
    geometry:=modifiers.geometry;buffer:=raw_data(modifiers.look.values)
    core.get(&animations,plain).weight=.4;core.get(&animations,target).parameters[0]=.7
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,app.assets,app.allocator,nil)
    host_assets.revision+=1
    prepared &&=modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,app.assets,app.allocator,nil)
    context=saved;app.allocator=saved.allocator;profiles.allocator=saved.allocator;skeletons.allocator=saved.allocator
    testing.expect(t,prepared && modifiers.geometry==geometry && raw_data(modifiers.look.values)==buffer && modifiers.inputs[4]==core.version(&animations) && modifiers.inputs[7]==host_assets.revision+1)
    profiles.contents[0].profile.look[0].weight=.3;profiles.contents[0].revision+=1;host_assets.revision+=1
    if !testing.expect(t,modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,app.assets,app.allocator,nil)) {return}
    testing.expect(t,modifiers.geometry==geometry+1 && modifiers.look.values[0].weight==.3)
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied.revisions[0]+=100;testing.expect(t,copied.revisions[0]!=modifiers.revisions[0])
    inputs:=modifiers.inputs;geometry=modifiers.geometry
    profiles.contents[0].profile.look[0].weight=.6;profiles.contents[0].revision+=1;host_assets.revision+=1
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,app.assets,app.allocator,nil)
    context=saved;app.allocator=saved.allocator;profiles.allocator=saved.allocator;skeletons.allocator=saved.allocator
    testing.expect(t,!prepared && modifiers.inputs==inputs && modifiers.geometry==geometry && modifiers.look.values[0].weight==.3)
    testing.expect(t,modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,app.assets,app.allocator,nil) && modifiers.look.values[0].weight==.6 && modifiers.geometry==geometry+1)
    old:=target;index:=core.entity_index(target)
    core.destroy(&entities,target);core.table_settle(&animations,&entities);core.entities_settle(&entities)
    target=core.create(&entities);core.add(&animations,target,description);core.table_settle(&animations,&entities)
    testing.expect(t,modifier_prepare(&modifiers,core.read(&configs),core.read(&animations),core.read(&attachments),&profiles,&skeletons,&playback,app.assets,app.allocator,nil) && target!=old && core.entity_index(target)==index && modifiers.sources[0].entity==target)
}
