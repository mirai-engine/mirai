package terrain

import "core:fmt"
import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"

@(private="file")
join_test_ground :: proc(s:^Source) -> bool {
    source_make(s,.Heightfield,{65,1,65},1,16) or_return
    for z in 0..<65 {for x in 0..<65 {source_set(s,{x,0,z},0.05*f32(x)+math.sin(f32(z)*0.4)) or_return}}
    return true
}

@(test)
a_joined_volume_meets_the_ground_on_the_sides_of_its_box_without_a_seam :: proc(t:^testing.T) {
    ground,volume:Source
    defer source_destroy(&ground);defer source_destroy(&volume)
    testing.expect(t,join_test_ground(&ground))
    testing.expect(t,source_make(&volume,.Volume,{17,17,17},1,8))
    join:=Chunk_Join{ground=&ground,offset={24,24},lift=-8}
    testing.expect(t,source_volume_ground(&volume,join))
    // A pit in its middle, away from the band.
    testing.expect(t,source_edit(&volume,{kind=.Carve,center={0,1,0},radius=3,amount=1}).changed)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    // Every sample of the Heightfield on the side x of the box is a vertex of the Volume there.
    found:[17]bool
    for cz in 0..<2 {for cy in 0..<2 {
        coord:=[3]i32{0,i32(cy),i32(cz)}
        testing.expect(t,chunk_build(&volume,coord,&mesh,true,{},join))
        origin:=chunk_origin(&volume,coord)
        for p in mesh.geometry.positions {
            at:=p+origin
            if abs(at.x+8)>1e-4 {continue}
            z:=at.z+8
            // Along the side the Volume runs on the edge of the ground between its samples.
            z0:=clamp(int(z),0,15)
            t0:=z-f32(z0)
            h:=grid_get(&ground.heights,24,24+z0)*(1-t0)+grid_get(&ground.heights,24,24+z0+1)*t0
            testing.expectf(t,abs(at.y-h)<1e-4,"a vertex on the side at z %v stands at %v, the ground at %v",z,at.y,h)
            if abs(z-math.round(z))<1e-5 {found[int(math.round(z))]=true}
        }
    }}
    for f,z in found {testing.expectf(t,f,"no vertex of the Volume on the sample %v of the side",z)}
    // The Heightfield leaves the cells of the box: a chunk over part of it.
    cuts:=[]Join_Cut{{{24,24},{40,40}}}
    testing.expect(t,chunk_build(&ground,{1,0,1},&mesh,true,{},{cuts=cuts}))
    testing.expect_value(t,len(mesh.geometry.indices),(256-64)*6)
    taken:=0
    for hole in mesh.holes {taken+=int(hole)}
    testing.expect_value(t,taken,64)
    testing.expect(t,join_cut_key(&ground,cuts,chunk_index(&ground,{1,0,1}))!=0)
    testing.expect_value(t,join_cut_key(&ground,cuts,chunk_index(&ground,{0,0,0})),u64(0))
    // Inside the band and past it the pit is the Volume's own.
    testing.expect(t,chunk_build(&volume,{1,1,1},&mesh,true,{},join))
    testing.expect(t,len(mesh.geometry.indices)>0)
}

@(test)
a_volume_that_joins_a_heightfield_takes_its_cells_and_digs_under_them :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    ground,volume:Source
    defer source_destroy(&ground);defer source_destroy(&volume)
    testing.expect(t,join_test_ground(&ground))
    testing.expect(t,source_make(&volume,.Volume,{17,17,17},1,8))
    testing.expect(t,source_volume_ground(&volume,{ground=&ground,offset={24,24},lift=-8}))
    testing.expect(t,source_edit(&volume,{kind=.Carve,center={0,1,0},radius=3,amount=1}).changed)
    ground.revision,volume.revision=1,1
    ground_id,volume_id:=base.Asset_Id{91,1},base.Asset_Id{91,2}
    testing.expect_value(t,source_save(&ground,fmt.tprintf("%s/ground.terrain",root),ground_id,&types),asset.Error.None)
    testing.expect_value(t,source_save(&volume,fmt.tprintf("%s/volume.terrain",root),volume_id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    field:=core.create(&w.entities)
    core.add(&w.transforms,field,core.TRANSFORM_IDENTITY)
    core.add(&w.ids,field,core.Id{value=7})
    core.add(&w.terrains,field,Terrain{source=ground_id,solid=true})
    dug:=core.create(&w.entities)
    core.add(&w.transforms,dug,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,dug,Terrain{source=volume_id,solid=true,ground=7})
    core.test_world_settle(&w.w)
    view:=core.VIEW_DEFAULT
    view.position={0,6,0}
    for _ in 0..<3 {terrain_test_update(&w,&resident,&app,view=view)}
    testing.expectf(t,w.problems.count==0,"%v",core.problems_list(&w.problems))
    cut:=resident_source_find(&resident,ground_id,field)
    testing.expect(t,cut!=nil && len(cut.join.cuts)==1 && cut.join.cuts[0]==Join_Cut{{24,24},{40,40}})
    // The ground inside the box is the Volume's: at its middle, the bottom of its pit.
    hit,found:=phys.raycast({&w.state},{0,10,0},{0,-1,0})
    surface:=grid_get(&ground.heights,32,32)
    testing.expectf(t,found && hit.point.y<surface-1.5,"the ray stops at %v, the ground at %v",hit.point,surface)
    // Within the band, the ground.
    hit,found=phys.raycast({&w.state},{-7.5,10,-2.5},{0,-1,0})
    testing.expect(t,found && abs(hit.point.y-source_height(&ground,-7.5,-2.5))<0.05)
    // A Volume moved off the samples of the ground joins nothing and says how far to move it.
    core.add(&w.transforms,dug,core.Transform{position={0.5,0,0},rotation=1,scale=1})
    core.test_world_settle(&w.w)
    for _ in 0..<2 {terrain_test_update(&w,&resident,&app,view=view)}
    testing.expect(t,core.problem_find(&w.problems,dug,"terrain.ground_misaligned")!=nil)
    cut=resident_source_find(&resident,ground_id,field)
    testing.expect(t,cut!=nil && len(cut.join.cuts)==0)
    hit,found=phys.raycast({&w.state},{0,10,0},{0,-1,0})
    testing.expect(t,found && abs(hit.point.y-surface)<0.05,"the Heightfield is whole again")
}
