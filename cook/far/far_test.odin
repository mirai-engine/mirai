package far

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file") FAR_ROOT :: base.Asset_Id{0xfa,1}
@(private="file") FAR_INNER :: base.Asset_Id{0xfa,2}
@(private="file") FAR_SHEET :: base.Asset_Id{0xfa,3}
@(private="file") FAR_RED :: base.Asset_Id{0xfa,4}

@(private="file")
Far_Test_Body :: struct {kind:u8}
@(private="file")
Far_Test_Hidden :: struct {}

// A bumpy sheet of side cells as a static mesh whose slot comes red.
@(private="file")
far_test_sheet :: proc(t:^testing.T,types:^asset.Types,path:string,side:int) -> (triangles:u32) {
    vertices:=make([dynamic]asset.Vertex,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for z in 0..=side {
        for x in 0..=side {
            y:=0.3*math.sin(f32(x)*0.4)*math.cos(f32(z)*0.3)
            append(&vertices,asset.Vertex{position={f32(x),y,f32(z)},normal=mm.normal_pack({0,1,0}),color=0xffffffff,tangent=mm.tangent_pack({1,0,0},1)})
        }
    }
    row:=u32(side+1)
    for z in 0..<u32(side) {
        for x in 0..<u32(side) {
            a:=z*row+x
            append(&indices,a,a+row,a+1,a+1,a+row,a+row+1)
        }
    }
    g:asset.Mesh_Geometry
    testing.expect(t,asset.mesh_build_dag({vertices=vertices[:]},indices[:],&g,context.temp_allocator))
    slots:=[1]asset.Material_Slot{{id=1,material=FAR_RED}}
    testing.expect_value(t,asset.mesh_save(path,types,{id=FAR_SHEET,geometry=g,slots=slots[:]}),asset.Error.None)
    return g.levels[0].triangle_count
}

// A scene with two sheets, a third that moves and a fourth that is hidden
// under a group, and a reference to a scene with one more: the far mesh the
// cook makes of the first holds the three that stay, red.
@(test)
a_far_mesh_is_made_of_the_static_meshes_of_a_scene_and_of_the_scenes_it_references :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"far")
    if folder=="" {return}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    File :: struct {id:base.Asset_Id,kind:asset.Fourcc,path:string}
    files:=[4]File{
        {FAR_ROOT,asset.KIND_SCENE,fmt.tprintf("%s/root.scene",folder)},{FAR_INNER,asset.KIND_SCENE,fmt.tprintf("%s/inner.scene",folder)},
        {FAR_SHEET,asset.KIND_MESH,fmt.tprintf("%s/sheet.mesh",folder)},{FAR_RED,asset.KIND_MATERIAL,fmt.tprintf("%s/red.mat",folder)},
    }
    sheet:=far_test_sheet(t,&types,files[2].path,32)
    red:=asset.MATERIAL_DEFAULTS
    red.base_color={1,0,0}
    testing.expect_value(t,asset.material_save(files[3].path,&types,{id=FAR_RED,info=red}),asset.Error.None)
    at :: proc(x:f32) -> core.Transform {return {position={x,0,0},rotation=1,scale={1,1,1}}}
    root:asset.Scene;asset.scene_init(&root,&types,FAR_ROOT)
    for id in 1..=6 {asset.scene_entity_add(&root,base.Entity_Id(id),5 if id==6 else 0,fmt.tprintf("thing %d",id))}
    for id in 1..=6 {
        pose:=at(f32(id)*40)
        asset.scene_set(&root,base.Entity_Id(id),"Transform",&pose)
        if id!=5 {asset.scene_set(&root,base.Entity_Id(id),"Mesh_Renderer",&Far_Renderer{mesh=FAR_SHEET})}
    }
    asset.scene_set(&root,3,"Rigid_Body",&Far_Test_Body{1})
    asset.scene_set(&root,5,"Hidden",&Far_Test_Hidden{})
    asset.scene_entity_add(&root,7,0,"Inner")
    asset.scene_set(&root,7,"Scene_Reference",&Far_Reference{scene=FAR_INNER})
    testing.expect_value(t,asset.scene_save(&root,files[0].path),asset.Error.None)
    asset.scene_destroy(&root)
    inner:asset.Scene;asset.scene_init(&inner,&types,FAR_INNER)
    asset.scene_entity_add(&inner,1,0,"Sheet")
    asset.scene_set(&inner,1,"Mesh_Renderer",&Far_Renderer{mesh=FAR_SHEET})
    testing.expect_value(t,asset.scene_save(&inner,files[1].path),asset.Error.None)
    asset.scene_destroy(&inner)

    registry:asset.Registry
    asset.registry_init(&registry,folder)
    defer asset.registry_destroy(&registry)
    if !testing.expect_value(t,asset.registry_scan(&registry),asset.Error.None) {return}
    g:asset.Mesh_Geometry
    testing.expect(t,far_cook(&registry,FAR_ROOT,&g,context.temp_allocator),"it is made")
    testing.expect(t,g.levels[0].triangle_count>0 && g.levels[0].triangle_count<4*sheet,"four sheets, cut at its error")
    testing.expect(t,.Has_Surface in g.flags)
    // The inner sheet at 0 and those at 40, 80 and 160; not the one that moves
    // at 120, nor the hidden one at 200 and what hangs from it.
    low,high:=g.bounds_min,g.bounds_max
    testing.expectf(t,low.x>=-0.01 && low.x<0.01 && high.x>191.99 && high.x<192.01,"%v %v",low,high)
    for c in g.clusters {
        color:=mm.rgba8_unpack(g.colors[c.vertex_first])
        testing.expect(t,color.r==1 && color.g==0 && color.b==0,"its slot came red")
    }
    // A scene without static meshes has none.
    testing.expect(t,!far_cook(&registry,{0xfa,9},&g,context.temp_allocator),"a scene that is not there gives none")
}
