package terrain

import "core:math"
import "core:math/rand"
import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"

@(test)
lod_levels_double_with_distance_and_hold_near_their_boundaries :: proc(t:^testing.T) {
    testing.expect_value(t,lod_level(10,16,5,0),u8(0))
    testing.expect_value(t,lod_level(20,16,5,0),u8(1))
    testing.expect_value(t,lod_level(40,16,5,0),u8(2))
    testing.expect_value(t,lod_level(1e6,16,3,0),u8(3))
    testing.expect_value(t,lod_level(16.5,16,5,0),u8(0))
    testing.expect_value(t,lod_level(15.5,16,5,1),u8(1))
    testing.expect_value(t,lod_level(13,16,5,1),u8(0))
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{70,1,70},1,64))
    testing.expect_value(t,chunk_lod_max(&source,{0,0,0}),u8(5))
    testing.expect_value(t,chunk_lod_max(&source,{1,0,0}),u8(1))
    volume:Source;defer source_destroy(&volume)
    testing.expect(t,source_make(&volume,.Volume,{9,9,9},1,8))
    testing.expect_value(t,chunk_lod_max(&volume,{0,0,0}),u8(0)) // a Volume has no levels of its own
}

@(private)
lod_seam_source :: proc(t:^testing.T,s:^Source) {
    testing.expect(t,source_make(s,.Heightfield,{69,1,69},0.5,16))
    for z in 0..<69 {for x in 0..<69 {source_set(s,{x,0,z},math.sin(f32(x)*0.37)*2+math.cos(f32(z)*0.23)*3+f32((x*7+z*13)%5)*0.1)}}
}

@(test)
chunks_of_mixed_levels_join_without_cracks_or_overlaps :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    lod_seam_source(t,&s)
    counts:=chunk_counts(&s)
    levels:=make([]u8,counts.x*counts.z);defer delete(levels)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    all:geom.Mesh_Buffer;geom.mesh_buffer_init(&all);defer geom.mesh_buffer_destroy(&all)
    welded:geom.Mesh_Buffer;geom.mesh_buffer_init(&welded);defer geom.mesh_buffer_destroy(&welded)
    random:=rand.create(7)
    for round in 0..<6 {
        for &level,i in levels {level=u8(rand.int_max(int(chunk_lod_max(&s,chunk_coord(&s,i)))+1,rand.default_random_generator(&random)))}
        if round==0 {for &level in levels {level=0}}
        geom.mesh_buffer_clear(&all)
        for i in 0..<len(levels) {
            coord:=chunk_coord(&s,i)
            lod:=chunk_lod_sides(&s,levels,coord)
            testing.expect(t,chunk_build(&s,coord,&mesh,true,lod))
            chunk_in_terrain(&mesh)
            low,high,_:=chunk_region(&s,coord)
            testing.expect_value(t,len(mesh.heights),(high.x-low.x+1)*(high.z-low.z+1))
            if lod.level>0 {testing.expect(t,len(mesh.geometry.positions)<len(mesh.heights))}
            offset:=u32(len(all.positions))
            append(&all.positions,..mesh.geometry.positions[:])
            for index in mesh.geometry.indices {append(&all.indices,index+offset)}
        }
        area:=f32(0)
        for at:=0;at<len(all.indices);at+=3 {
            a,b,c:=all.positions[all.indices[at]],all.positions[all.indices[at+1]],all.positions[all.indices[at+2]]
            up:=(b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z)
            testing.expect(t,up>0,"every triangle faces up")
            area+=up*0.5
        }
        testing.expect(t,abs(area-34*34)<1e-2,"the triangles cover the terrain once")
        geom.mesh_weld(geom.mesh_buffer_view(&all),0,&welded)
        edges:=make(map[[2]u32]int);defer delete(edges)
        for at:=0;at<len(welded.indices);at+=3 {
            for corner in 0..<3 {
                a,b:=welded.indices[at+corner],welded.indices[at+(corner+1)%3]
                edges[{min(a,b),max(a,b)}]+=1
            }
        }
        border:=f32(17)
        for edge,uses in edges {
            if uses==2 {continue}
            testing.expect_value(t,uses,1)
            a,b:=welded.positions[edge[0]],welded.positions[edge[1]]
            outer:=(abs(a.x)==border && abs(b.x)==border && a.x==b.x) || (abs(a.z)==border && abs(b.z)==border && a.z==b.z)
            testing.expectf(t,outer,"round %d: an open edge %v-%v inside the terrain",round,a,b)
        }
    }
}

// With Terrain_Settings.lod_distance, the distance makes a chunk coarser
// only as far as its error lets it be, and two chunks that touch are one
// level apart at most.
@(test)
far_chunks_show_coarser_levels_while_colliders_keep_every_sample :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    source:Source;defer source_destroy(&source)
    testing.expect(t,source_make(&source,.Heightfield,{129,1,129},1,16))
    // A bump of one sample, far from the view: no coarse level shows it, and the view would see it.
    testing.expect(t,source_set(&source,{121,0,121},3))
    source.revision=1
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    id:=base.Asset_Id{77,78}
    testing.expect_value(t,source_save(&source,fmt.tprintf("%s/source.terrain",root),id,&types),asset.Error.None)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=256}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    owner:=core.create(&w.entities)
    core.add(&w.transforms,owner,core.TRANSFORM_IDENTITY)
    core.add(&w.terrains,owner,Terrain{source=id,solid=true})
    core.test_world_settle(&w.w)
    view:=core.VIEW_DEFAULT
    view.position={-60,5,-60}
    settings:=Terrain_Settings{lod_distance=16}
    for _ in 0..<3 {terrain_test_update(&w,&resident,&app,view=view,settings=settings)}
    chunks:=resident.sources[0].chunks
    testing.expect_value(t,chunks[0].built.lod.level,u8(0))
    s:=&w.data.entries[0].source
    far,flat:=chunk_index(s,{7,0,7}),chunk_index(s,{7,0,0})
    // The level its error allows there: one, whose vertices are about the spacing the view sees.
    testing.expectf(t,chunks[far].built.lod.level<=1,"the chunk of the bump is at level %d",chunks[far].built.lod.level)
    testing.expect(t,chunks[flat].built.lod.level>=2)
    testing.expect_value(t,chunks[flat].built.lod.sides[0],min(chunks[flat].built.lod.level,chunks[flat-1].built.lod.level))
    apart :: proc(t:^testing.T,s:^Source,chunks:[]Resident_Chunk) {
        for i in 0..<64 {
            coord:=chunk_coord(s,i)
            for dz in i32(-1)..=1 {for dx in i32(-1)..=1 {
                j:=chunk_index(s,coord+{dx,0,dz})
                if j<0 {continue}
                a,b:=int(chunks[i].built.lod.level),int(chunks[j].built.lod.level)
                testing.expectf(t,abs(a-b)<=1,"chunks %v and %v touch at levels %d and %d",coord,chunk_coord(s,j),a,b)
            }}
        }
    }
    apart(t,s,chunks[:64])
    hit,ok:=phys.raycast({&w.state},{57,20,57},{0,-1,0})
    testing.expect(t,ok && abs(hit.point.y-3)<1e-4,"the collider keeps the sample")
    built:=resident.stats.built
    view.position={-59.9,5,-60}
    terrain_test_update(&w,&resident,&app,view=view,settings=settings)
    testing.expect_value(t,resident.stats.built,built)
    // The view crosses the terrain: the chunks near it become fine, the far ones coarse.
    view.position={60,5,60}
    terrain_test_update(&w,&resident,&app,view=view,settings=settings)
    testing.expect_value(t,chunks[far].built.lod.level,u8(0))
    testing.expect(t,chunks[0].built.lod.level>=2)
    apart(t,s,chunks[:64])
    testing.expect(t,resident.stats.built>built && resident.stats.built<built+64)
    hit,ok=phys.raycast({&w.state},{57,20,57},{0,-1,0})
    testing.expect(t,ok && abs(hit.point.y-3)<1e-4)
    // Colliders only near the view.
    settings.collision_distance=20
    terrain_test_update(&w,&resident,&app,view=view,settings=settings)
    testing.expect(t,chunks[far].built.collision && !chunks[0].built.collision)
    with_collider:=0
    for row in 0..<core.count(&w.chunks) {if core.has(core.read(&w.colliders),w.chunks.entities[row]) {with_collider+=1}}
    testing.expect(t,with_collider>0 && with_collider<64)
    _,ok=phys.raycast({&w.state},{-57,20,-57},{0,-1,0})
    testing.expect(t,!ok)
    testing.expect_value(t,w.problems.count,0)
}
