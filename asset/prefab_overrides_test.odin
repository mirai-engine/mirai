package asset

import "base:runtime"
import "core:testing"
import "mirai:std/base"

@(private="file") LAMP :: base.Asset_Id{0xa1,0xa2}

@(private="file")
lamp :: proc(prefab:^Scene,types:^Types,range:f32) {
    scene_init(prefab,types,KIND_PREFAB,LAMP)
    scene_entity_add(prefab,1,0,"Lamp")
    scene_entity_add(prefab,2,1,"Bulb")
    scene_entity_add(prefab,3,1,"Shade")
    prefab.info.root=1
    for id in ([]base.Entity_Id{1,2,3}) {
        value:=Test_Transform{position={0,f32(id),0},rotation=1,scale={1,1,1}}
        scene_set(prefab,id,"Transform",&value)
    }
    light:=Test_Light{{1,0,0},1,range}
    scene_set(prefab,2,"Light",&light)
    follow:=Test_Follow{target=base.Entity(1),anchor=2,offset={0,0,1}}
    scene_set(prefab,3,"Follow",&follow)
}

@(private="file")
member_of :: proc(scene:^Scene,root,source:base.Entity_Id) -> base.Entity_Id {
    members,_:=scene_instance_members(scene,root)
    for candidate in members {
        if candidate.source==source {return candidate.entity}
    }
    return 0
}

@(private="file")
derived :: proc(t:^testing.T,scene:^Scene,instance:base.Entity_Id,prefab:^Scene) -> []Override {
    out:=make([dynamic]Override,context.temp_allocator)
    testing.expect_value(t,scene_instance_overrides(&out,scene,instance,prefab),Error.None)
    return out[:]
}

@(test)
prefab_overrides_derive_from_the_members_survive_an_update_and_go_into_the_prefab :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    prefab:Scene;lamp(&prefab,&types,1);defer scene_destroy(&prefab)
    scene:Scene;scene_init(&scene,&types,KIND_SCENE,{0xb,0xb});defer scene_destroy(&scene)
    root,_:=scene_instantiate(&scene,&prefab,LAMP,0)
    instance:=root
    bulb,shade:=member_of(&scene,instance,2),member_of(&scene,instance,3)
    testing.expect_value(t,len(derived(t,&scene,instance,&prefab)),0)

    light,_:=scene_get(&scene,bulb,"Light",Test_Light)
    light.range=2
    scene_set(&scene,bulb,"Light",&light)
    scene_component_turn(&scene,bulb,base.name_hash("Light"),true)
    placed:=Test_Transform{position={5,5,5},rotation=1,scale={1,1,1}}
    scene_set(&scene,root,"Transform",&placed)
    scene_entity_rename(&scene,shade,"My shade")
    mesh:=Test_Mesh{{1,1},{2,2}}
    scene_set(&scene,shade,"Mesh",&mesh)
    follow_table,_:=scene_component(&scene,"Follow")
    scene_component_remove(&scene,follow_table,shade)
    sticker:=scene_new_id(&scene)
    scene_entity_add(&scene,sticker,bulb,"Sticker")
    aim:=Test_Follow{target=base.Entity(shade)}
    scene_set(&scene,sticker,"Follow",&aim)

    Expected :: struct {entity:base.Entity_Id,component:string,kind:Override_Kind,path:string}
    expected:=[]Expected{
        {bulb,"Light",.Field,"range"},
        {bulb,"Light",.Turned,""},
        {shade,"",.Field,"name"},
        {shade,"Mesh",.Added,""},
        {shade,"Follow",.Removed,""},
        {sticker,"",.Child,""},
    }
    found:=derived(t,&scene,instance,&prefab)
    testing.expect_value(t,len(found),len(expected))
    for e in expected {
        hash:=e.component==""?0:base.name_hash(e.component)
        seen:=false
        for &override in found {
            path:=override.path
            seen||=override.entity==e.entity && override.component==hash && override.kind==e.kind && base.text_get(path[:])==e.path
        }
        testing.expectf(t,seen,"%v %s %v %q is derived",e.entity,e.component,e.kind,e.path)
    }

    // What was derived is what an update keeps over the next prefab.
    clear(&scene.overrides)
    append(&scene.overrides,..found)
    next:Scene;lamp(&next,&types,3);defer scene_destroy(&next)
    scene_entity_rename(&next,3,"Shade v2")
    testing.expect_value(t,scene_instance_update(&scene,instance,&next),Error.None)
    light,_=scene_get(&scene,bulb,"Light",Test_Light)
    row,_:=scene_entity_find(&scene,shade)
    _,has_mesh:=scene_get(&scene,shade,"Mesh",Test_Mesh)
    _,has_follow:=scene_get(&scene,shade,"Follow",Test_Follow)
    _,has_sticker:=scene_entity_find(&scene,sticker)
    testing.expect(t,light.range==2 && scene_component_off(&scene,bulb,base.name_hash("Light")) && scene_entity(&scene,row).name=="My shade" && has_mesh && !has_follow && has_sticker)
    testing.expect_value(t,len(derived(t,&scene,instance,&next)),len(expected))

    // Applied, the prefab holds them and the instance nothing on its own.
    testing.expect_value(t,scene_overrides_apply(&scene,instance,derived(t,&scene,instance,&next),&next),Error.None)
    testing.expect_value(t,len(derived(t,&scene,instance,&next)),0)
    applied,_:=scene_get(&next,2,"Light",Test_Light)
    _,sticker_source,_:=scene_member(&scene,sticker)
    aimed,_:=scene_get(&next,sticker_source,"Follow",Test_Follow)
    testing.expect(t,applied.range==2 && scene_entity_count(&next)==4 && aimed.target==base.Entity(3))
}

@(private="file")
Failing :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
failing_allocator :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]u8,runtime.Allocator_Error) {
    state:=(^Failing)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if state.remaining==0 {return nil,.Out_Of_Memory}
        state.remaining-=1
    }
    return state.owner.procedure(state.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
prefab_value_applied_without_memory_leaves_the_prefab_and_can_be_tried_again :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    scene,prefab:Scene
    scene_init(&scene,&types,KIND_SCENE,{1,2});defer scene_destroy(&scene)
    scene_init(&prefab,&types,KIND_PREFAB,{3,4});defer scene_destroy(&prefab)
    scene_entity_add(&scene,1,0,"Source")
    scene_entity_add(&prefab,2,0,"Destination")
    before:=Test_Transform{{1,2,3},1,{1,1,1}}
    wanted:=Test_Transform{{9,8,7},1,{2,3,4}}
    scene_set(&prefab,2,"Transform",&before)
    scene_set(&scene,1,"Transform",&wanted)
    scene_table,_:=scene_component(&scene,"Transform")
    prefab_table,_:=scene_component(&prefab,"Transform")
    pair:=Override_Pair{scene_table=scene_table,prefab_table=prefab_table}
    inverse:=make(map[base.Entity_Id]base.Entity_Id,context.temp_allocator)
    for allowed in 0..<4 {
        failure:=Failing{owner=context.temp_allocator,remaining=allowed}
        error:Error
        {
            context.temp_allocator={failing_allocator,&failure}
            error=override_value_apply(&pair,&scene,&prefab,1,2,"",inverse)
        }
        testing.expect_value(t,error,Error.Out_Of_Memory)
        actual,_:=scene_get(&prefab,2,"Transform",Test_Transform)
        testing.expect_value(t,actual,before)
    }
    testing.expect_value(t,override_value_apply(&pair,&scene,&prefab,1,2,"",inverse),Error.None)
    actual,_:=scene_get(&prefab,2,"Transform",Test_Transform)
    testing.expect_value(t,actual,wanted)
}
