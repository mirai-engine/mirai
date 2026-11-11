package anim

import "base:runtime"
import "core:testing"
import "mirai:core"
import "mirai:host"

@(private)
@(test_world)
Discovery_World :: struct {
    using world:Test_World,
    animations:core.Table(Animation),
    attachments:core.Table(Bone_Attachment),
}

@(test)
modifier_preparation_ignores_unrelated_writes_reloads_only_changed_definitions_and_preserves_headers_on_failure :: proc(t:^testing.T) {
    w:Discovery_World
    if !test_world_init(t,&w) {return}
    defer test_world_destroy(&w)
    looker,plain:=core.create(&w.entities),core.create(&w.entities)
    description:=ANIMATION_DEFAULT;description.asset={3,4}
    core.add(&w.animations,looker,description);core.add(&w.animations,plain,ANIMATION_DEFAULT);test_world_settle(&w)
    characters:Character_Assets;defer character_assets_free(&characters)
    look:=make([]Look_Constraint,1);defer delete(look);look[0]=LOOK_CONSTRAINT_DEFAULT;look[0].bone=bone_ref("head")
    test_character_seed(&characters,{3,4},{pose={look=look}})
    skeletons:Skeleton_Assets;defer skeleton_assets_free(&skeletons)
    host_assets:host.Assets;app:=host.App{assets=&host_assets,allocator=context.allocator}
    test_character_register(&host_assets,{3,4});defer test_registry_free(&host_assets)
    playback:Playback;defer playback_free(&playback)
    modifiers:Modifier_Runtime;defer modifier_runtime_free(&modifiers)
    prepare :: proc(modifiers:^Modifier_Runtime,w:^Discovery_World,characters:^Character_Assets,skeletons:^Skeleton_Assets,playback:^Playback,app:^host.App) -> bool {
        return modifier_prepare(modifiers,&w.animations,&w.attachments,characters,skeletons,playback,app.assets,app.allocator,nil)
    }
    if !testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)) {return}
    geometry:=modifiers.geometry;buffer:=raw_data(modifiers.look.values)
    testing.expect(t,len(modifiers.look.values)==1 && modifiers.look.values[0].rig==looker)
    // A write of another field of an Animation, or another revision of the assets, lays nothing out.
    core.edit(&w.animations,plain).weight=.4;core.edit(&w.animations,looker).speed=.7
    saved:=context;context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared:=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
    host_assets.revision+=1
    prepared &&=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
    context=saved;app.allocator=saved.allocator;characters.allocator=saved.allocator;skeletons.allocator=saved.allocator
    testing.expect(t,prepared && modifiers.geometry==geometry && raw_data(modifiers.look.values)==buffer && modifiers.inputs[5]==core.version(&w.animations) && modifiers.inputs[4]==host_assets.revision+1)
    look[0].weight=.3;characters.contents[0].revision+=1;host_assets.revision+=1
    if !testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)) {return}
    testing.expect(t,modifiers.geometry==geometry+1 && modifiers.look.values[0].weight==.3)
    copied:Modifier_Runtime;core.value_copy(&copied,&modifiers,type_info_of(Modifier_Runtime));defer modifier_runtime_free(&copied)
    copied.revisions[0]+=100;testing.expect(t,copied.revisions[0]!=modifiers.revisions[0])
    inputs:=modifiers.inputs;geometry=modifiers.geometry
    look[0].weight=.6;characters.contents[0].revision+=1;host_assets.revision+=1
    context.allocator=runtime.nil_allocator();context.temp_allocator=context.allocator;app.allocator=context.allocator
    prepared=prepare(&modifiers,&w,&characters,&skeletons,&playback,&app)
    context=saved;app.allocator=saved.allocator;characters.allocator=saved.allocator;skeletons.allocator=saved.allocator
    testing.expect(t,!prepared && modifiers.inputs==inputs && modifiers.geometry==geometry && modifiers.look.values[0].weight==.3)
    testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app) && modifiers.look.values[0].weight==.6 && modifiers.geometry==geometry+1)
    // The set is the asset of the Animation: another entity in the place of the first takes it over.
    old:=looker;index:=core.entity_index(looker)
    core.destroy(&w.entities,looker);test_world_settle(&w)
    looker=core.create(&w.entities);core.add(&w.animations,looker,description);test_world_settle(&w)
    testing.expect(t,prepare(&modifiers,&w,&characters,&skeletons,&playback,&app) && looker!=old && core.entity_index(looker)==index && modifiers.look.values[0].rig==looker)
}
