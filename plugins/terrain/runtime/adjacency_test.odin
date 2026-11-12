package terrain

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"

@(private="file")
slope_height :: proc(x,z:int) -> f32 {return 0.002*f32(x*x)+0.5*math.sin(f32(z)*0.2)}

// Two sources of one slope cut at a sample, the second's edge raised off it:
// a, samples x from 0 to 32, and b from 32 on.
@(private="file")
edge_sources :: proc(t:^testing.T,a,b:^Source,samples:=33,cells:=16) {
    testing.expect(t,source_make(a,.Heightfield,{samples,1,samples},1,cells))
    testing.expect(t,source_make(b,.Heightfield,{samples,1,samples},1,cells))
    for z in 0..<samples {for x in 0..<samples {
        testing.expect(t,source_set(a,{x,0,z},slope_height(x,z)))
        testing.expect(t,source_set(b,{x,0,z},slope_height(x+samples-1,z)+(x==0?0.3:0)))
    }}
}

// Across an edge two Heightfields share, a build reads the other: the
// samples of the edge are those of the one that owns it, the normals and the
// rules of the layers see across it, and the collider keeps no edge where the
// ground goes on flat.
@(test)
chunks_on_a_shared_edge_read_the_terrain_beside_them :: proc(t:^testing.T) {
    a,b:Source;defer source_destroy(&a);defer source_destroy(&b)
    edge_sources(t,&a,&b)
    n:=int(a.samples.x)-1
    into_a:=Chunk_Join{edges={1={s=&b,offset={n,0}}}}
    into_b:=Chunk_Join{edges={0={s=&a,offset={-n,0},owns=true}}}
    ma,mb:Chunk_Mesh
    chunk_mesh_init(&ma);defer chunk_mesh_destroy(&ma)
    chunk_mesh_init(&mb);defer chunk_mesh_destroy(&mb)
    testing.expect(t,chunk_build(&a,{1,0,0},&ma,true,{},into_a))
    testing.expect(t,chunk_build(&b,{0,0,0},&mb,true,{},into_b))
    // Vertices of the edge in the space of a.
    edge_a,edge_b:=0,0
    for p,i in ma.geometry.positions {
        at:=p+ma.origin
        if abs(at.x-source_origin(&a).x-f32(n))>1e-4 {continue}
        edge_a+=1
        for q,j in mb.geometry.positions {
            other:=q+mb.origin-source_origin(&b)+source_origin(&a)+{f32(n),0,0}
            if linalg.length(other.xz-at.xz)>1e-4 {continue}
            edge_b+=1
            testing.expectf(t,abs(other.y-at.y)<1e-5,"the edge stands where its owner has it: %v and %v",at.y,other.y)
            testing.expectf(t,linalg.length(ma.geometry.normals[i]-mb.geometry.normals[j])<1e-4,"one normal on the edge: %v and %v",ma.geometry.normals[i],mb.geometry.normals[j])
        }
    }
    testing.expect(t,edge_a==17 && edge_b==17)
    // The colliders take the same heights there, and the plane goes on across: no edge stays.
    for row in 0..<mb.rows {testing.expect(t,abs(mb.heights[row*mb.columns]-ma.heights[row*ma.columns+ma.columns-1])<1e-5)}
    rows:=ma.rows-1
    disabled:=0
    for i in 0..<rows {if ma.disabled_borders[rows+i]!=0 {disabled+=1}}
    testing.expect_value(t,disabled,rows)
    // The normal of the edge is that of the slope, not one of a side alone.
    testing.expect(t,ma.maps.normal[16]==normal_bytes(heightfield_normal(&a,n,0,1,&into_a.edges)))
    alone:=heightfield_normal(&a,n,8,1)
    across:=heightfield_normal(&a,n,8,1,&into_a.edges)
    testing.expect(t,abs(across.x+f32(0.128)/math.sqrt(f32(1+0.128*0.128)))<0.01 && linalg.length(alone-across)>1e-4)
}

@(private="file")
edge_world :: proc(t:^testing.T,w:^Terrain_Test_World,root:string,types:^asset.Types) -> (owners:[2]core.Entity) {
    a,b:Source;defer source_destroy(&a);defer source_destroy(&b)
    edge_sources(t,&a,&b,65,16)
    a.revision,b.revision=1,1
    ids:=[2]base.Asset_Id{{401,1},{401,2}}
    testing.expect_value(t,source_save(&a,fmt.tprintf("%s/a.terrain",root),ids[0],types),asset.Error.None)
    testing.expect_value(t,source_save(&b,fmt.tprintf("%s/b.terrain",root),ids[1],types),asset.Error.None)
    for id,k in ids {
        owners[k]=core.create(&w.entities)
        place:=core.TRANSFORM_IDENTITY
        place.position.x=f32(64*k)
        core.add(&w.transforms,owners[k],place)
        core.add(&w.worlds,owners[k],core.World_Transform{transform={position=place.position,rotation=place.rotation,scale=place.scale}})
        core.add(&w.terrains,owners[k],Terrain{source=id,solid=true})
    }
    test_world_settle(&w.w)
    return
}

// Two terrains placed edge to edge meet by themselves: each finds the other
// beside it, the levels of the border they share are one, the ground is
// continuous for bodies, and a brush over the edge writes both.
@(test)
heightfields_edge_to_edge_meet_and_a_brush_over_their_edge_writes_both :: proc(t:^testing.T) {
    root:=base.test_folder(t,"terrain")
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    w:Terrain_Test_World
    if !terrain_test_world_init(t,&w) {return}
    defer terrain_test_world_free(&w)
    owners:=edge_world(t,&w,root,&types)
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root=root,capacity=1024}));defer host.assets_destroy(&assets)
    app:=host.App{assets=&assets,allocator=context.allocator}
    resident:Terrain_Resident;defer terrain_resident_free(&resident)
    view:=core.VIEW_DEFAULT
    view.position={-40,30,0}
    view.size={1440,900}
    for _ in 0..<4 {terrain_test_update(&w,&resident,&app,view=view,settings={})}
    if !testing.expect_value(t,len(resident.owners),2) {return}
    oa,ob:=&resident.owners[0],&resident.owners[1]
    if oa.entity!=owners[0] {oa,ob=ob,oa}
    testing.expect(t,oa.sides[1].owner>=0 && ob.sides[0].owner>=0,"each finds the other beside it")
    testing.expect(t,!oa.sides[1].owns && ob.sides[0].owns,"the edge is of the terrain of the lower Id")
    // The segments of the shared line, from each side.
    sa,sb:=resident_source_find(&resident,oa.source,oa.entity),resident_source_find(&resident,ob.source,ob.entity)
    ba,bb:=resident_border(&resident,sa),resident_border(&resident,sb)
    for z in 0..<ba.counts.y {
        testing.expect_value(t,border_vertical(&bb,0,z),border_vertical(&ba,ba.counts.x,z))
        testing.expect_value(t,border_corner(&bb,0,z),border_corner(&ba,ba.counts.x,z))
    }
    // The ground is continuous over the edge: just past it, b stands where a does.
    for x in ([2]f32{31.99,32.01}) {
        hit,found:=phys.raycast({&w.state},{x,20,4},{0,-1,0})
        if testing.expectf(t,found,"no ground at x %v",x) {testing.expectf(t,abs(hit.point.y-slope_height(64,36))<0.05,"at x %v the ground is at %v",x,hit.point.y)}
    }
    // A brush over the edge raises both.
    ea,eb:=data_find(&w.data,oa.source),data_find(&w.data,ob.source)
    before_a,before_b:=grid_get(&ea.source.field,64,32),grid_get(&eb.source.field,0,32)
    dig(&w.terrain_requests,{kind=.Raise,center={32,0,0},radius=3,amount=1})
    terrain_test_update(&w,&resident,&app,view=view,settings={})
    ea,eb=data_find(&w.data,oa.source),data_find(&w.data,ob.source)
    testing.expect(t,grid_get(&ea.source.field,64,32)>before_a+0.5 && grid_get(&eb.source.field,0,32)>before_b+0.5)
    testing.expect_value(t,w.problems.count,0)
}
