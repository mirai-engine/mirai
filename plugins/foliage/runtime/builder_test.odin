package foliage

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

@(test)
a_content_tool_writes_a_foliage_and_its_entity_in_one_pass :: proc(t:^testing.T) {
    folder,_:=os.temp_directory(context.temp_allocator)
    folder=fmt.tprintf("%s/mirai-foliage-builder-%d",folder,os.get_pid())
    defer os.remove_all(folder)
    c:asset.Content
    asset.content_init(&c,"builder_test")
    defer asset.content_destroy(&c)
    b:asset.Scene_Builder
    asset.builder_init(&b,&c,asset.KIND_SCENE,asset.content_id("builder_test","scene","island"))
    defer asset.builder_destroy(&b)
    file:=fmt.tprintf("%s/island/plants.foliage",folder)
    desc:=Foliage_Desc{file=file,generate={{at={0,0,0},radius=40}},types={
        {name="palm",mesh={1,1},density=0.01,scale={0.8,1.2},yaw=120,tilt=5,align=0.15,rule=true,slope={0,28},ground_height={1,6},wind=0,casts_shadow=true},
        {mesh={2,2},layers={1}},
    }}
    plants:=builder_foliage(&b,"Plants",desc)
    testing.expect(t,plants!=0 && !b.failed && !c.failed)
    row,found:=asset.scene_get(&b.scene,plants,"Foliage",Foliage)
    testing.expect(t,found && row.source!={} && row.revision==1)

    source:Source
    defer source_destroy(&source)
    data,error:=os.read_entire_file(file,context.temp_allocator)
    if !testing.expect_value(t,error,nil) {return}
    opened:asset.Asset
    testing.expect_value(t,asset.asset_open(&opened,data),asset.Error.None)
    id,read:=source_read(&source,&opened,&c.types)
    asset.asset_close(&opened)
    if !testing.expect(t,read) {return}
    testing.expect_value(t,id,row.source)
    testing.expect_value(t,len(source.types),2)
    palm:=source.types[0]
    testing.expect(t,palm.mesh==base.Asset_Id{1,1} && palm.density==0.01 && palm.casts_shadow && palm.rule.enabled)
    testing.expect_value(t,palm.wind,f32(0))
    testing.expect_value(t,palm.align,f32(0.15))
    testing.expect(t,abs(palm.yaw-math.to_radians(f32(120)))<1e-4 && abs(palm.rule.slope.y-math.to_radians(f32(28)))<1e-4)
    other:=source.types[1]
    testing.expect_value(t,other.align,FOLIAGE_TYPE_DEFAULT.align)
    testing.expect_value(t,other.wind,FOLIAGE_TYPE_DEFAULT.wind)
    testing.expect_value(t,other.rule.layers,u32(2))
    testing.expect(t,len(source.cells)>=4,"the area turns on the generator of its cells")
    generated:=0
    for cell in source.cells {if cell.generate {generated+=1}}
    testing.expect_value(t,generated,len(source.cells))

    again:asset.Scene_Builder
    asset.builder_init(&again,&c,asset.KIND_SCENE,asset.content_id("builder_test","scene","again"))
    defer asset.builder_destroy(&again)
    builder_foliage(&again,"Plants",desc)
    second,_:=os.read_entire_file(file,context.temp_allocator)
    testing.expect(t,string(data)==string(second),"the same code gives the same bytes")

    bad:asset.Scene_Builder
    asset.builder_init(&bad,&c,asset.KIND_SCENE,asset.content_id("builder_test","scene","bad"))
    defer asset.builder_destroy(&bad)
    testing.expect_value(t,builder_foliage(&bad,"Bad",{file=file,types={{name="meshless"}}}),base.Entity_Id(0))
    testing.expect(t,bad.failed && c.failed)
}
