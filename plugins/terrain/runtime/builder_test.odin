package terrain

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

@(test)
a_content_tool_writes_a_terrain_and_its_entity_in_one_pass :: proc(t:^testing.T) {
    folder,_:=os.temp_directory(context.temp_allocator)
    folder=fmt.tprintf("%s/mirai-terrain-builder-%d",folder,os.get_pid())
    defer os.remove_all(folder)
    c:asset.Content
    asset.content_init(&c,"builder_test")
    defer asset.content_destroy(&c)
    b:asset.Scene_Builder
    asset.builder_init(&b,&c,asset.KIND_SCENE,asset.content_id("builder_test","scene","island"))
    defer asset.builder_destroy(&b)
    file:=fmt.tprintf("%s/island/ground.terrain",folder)
    hill :: proc(x,z:f32) -> f32 {return x==0 && z==0?5:0}
    ground:=builder_terrain(&b,"Island",{file=file,samples=9,spacing=2,height=hill,layers={
        {material={7,7},tiling=3},
        {material={8,8},automatic=true,slope={30,90},softness={5,0}},
    }})
    testing.expect(t,ground!=0 && !b.failed && !c.failed)
    terrain_row,found:=asset.scene_get(&b.scene,ground,"Terrain",Terrain)
    testing.expect(t,found && terrain_row.solid && terrain_row.source!={} && terrain_row.revision==1)
    source:Source
    defer source_destroy(&source)
    id,read:=source_load(&source,file,&c.types)
    if !testing.expect(t,read) {return}
    testing.expect_value(t,id,terrain_row.source)
    testing.expect_value(t,source.layer_count,u32(2))
    testing.expect_value(t,source.layers[0].material,base.Asset_Id{7,7})
    testing.expect_value(t,source.layers[0].tiling,f32(3))
    testing.expect(t,source.layers[1].auto.enabled && source.layers[1].auto.slope.x>0.5)
    testing.expect_value(t,source.cell,f32(2))
    testing.expect_value(t,grid_get(&source.heights,4,4),f32(5))
    testing.expect_value(t,grid_get(&source.heights,0,0),f32(0))

    // The same code gives the same bytes; a bad desc says what is wrong and writes nothing.
    first,_:=os.read_entire_file(file,context.temp_allocator)
    again:asset.Scene_Builder
    asset.builder_init(&again,&c,asset.KIND_SCENE,asset.content_id("builder_test","scene","again"))
    defer asset.builder_destroy(&again)
    builder_terrain(&again,"Island",{file=file,samples=9,spacing=2,height=hill,layers={{material={7,7},tiling=3},{material={8,8},automatic=true,slope={30,90},softness={5,0}}}})
    second,_:=os.read_entire_file(file,context.temp_allocator)
    testing.expect(t,string(first)==string(second),"the same bytes on every run")

    bad:asset.Scene_Builder
    asset.builder_init(&bad,&c,asset.KIND_SCENE,asset.content_id("builder_test","scene","bad"))
    defer asset.builder_destroy(&bad)
    testing.expect_value(t,builder_terrain(&bad,"Bad",{file=file,samples=1}),base.Entity_Id(0))
    testing.expect(t,bad.failed && c.failed)
}
