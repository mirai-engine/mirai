package terrain

import "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:host"
import "mirai:std/geom"

@(private)
hill_height :: proc(s:^Source,x,z:int,height,width:f32) -> f32 {
    p:=source_point(s,{x,0,z})
    return height*math.exp(-(p.x*p.x+p.z*p.z)/(2*width*width))
}

@(test)
an_automatic_slope_rule_fades_over_several_samples :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{65,1,65},0.25,64))
    for z in 0..<65 {for x in 0..<65 {source_set(&s,{x,0,z},hill_height(&s,x,z,4,3))}}
    rock:=LAYER_DEFAULT
    rock.auto.enabled,rock.auto.slope=true,{math.PI/6,math.PI/2}
    testing.expect(t,source_layer_set(&s,0,LAYER_DEFAULT) && source_layer_set(&s,1,rock))
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&s,{0,0,0},&mesh,false))
    cover:=proc(m:^Chunk_Mesh,x,z:int) -> f32 {return m.geometry.uvs[z*65+x].y}
    steepest,between:=f32(0),0
    for z in 0..<65 {for x in 0..<64 {
        steepest=max(steepest,abs(cover(&mesh,x+1,z)-cover(&mesh,x,z)),abs(cover(&mesh,z,x+1)-cover(&mesh,z,x)))
        if c:=cover(&mesh,x,z);c>0.1 && c<0.9 {between+=1}
    }}
    testing.expectf(t,steepest<0.35,"the cover of the rule jumps by %v between neighbor samples",steepest)
    testing.expect(t,between>64,"the rule fades over a band of samples, not a line")
}

@(test)
coarse_levels_take_normals_over_their_own_step_and_neighbors_share_them :: proc(t:^testing.T) {
    smooth,rough:Source
    defer source_destroy(&smooth);defer source_destroy(&rough)
    testing.expect(t,source_make(&smooth,.Heightfield,{129,1,129},1,64))
    testing.expect(t,source_make(&rough,.Heightfield,{129,1,129},1,64))
    for z in 0..<129 {for x in 0..<129 {
        h:=hill_height(&smooth,x,z,30,25)
        source_set(&smooth,{x,0,z},h)
        // A ripple of four samples: no level coarser than 2 can show it.
        source_set(&rough,{x,0,z},h+0.6*math.sin(f32(x)*math.PI/2))
    }}
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    lod:=Chunk_Lod{level=3,sides={3,3,3,3}}
    testing.expect(t,chunk_build(&rough,{0,0,0},&mesh,false,lod))
    chunk_in_terrain(&mesh)
    worst:=f32(0)
    origin:=source_origin(&rough)
    for p,i in mesh.geometry.positions {
        x,z:=int(math.round(p.x-origin.x)),int(math.round(p.z-origin.z))
        if x==0 || z==0 || x==64 || z==64 {continue}
        worst=max(worst,math.acos(clamp(linalg.dot(mesh.geometry.normals[i],heightfield_normal(&smooth,x,z,8)),-1,1)))
    }
    testing.expectf(t,worst<0.02,"a coarse vertex shows the ripple: %v rad",worst)
    full:=heightfield_normal(&rough,30,30,1)
    testing.expect(t,math.acos(linalg.dot(full,heightfield_normal(&smooth,30,30,1)))>0.3,"level 0 keeps every sample")
    // Two chunks at different levels: the vertices they share have one normal.
    levels:=[4]u8{3,1,0,2}
    normals:=make(map[[2]f32][3]f32);defer delete(normals)
    shared:=0
    for i in 0..<4 {
        coord:=chunk_coord(&rough,i)
        testing.expect(t,chunk_build(&rough,coord,&mesh,false,chunk_lod_sides(&rough,levels[:],coord)))
        chunk_in_terrain(&mesh)
        for p,v in mesh.geometry.positions {
            key:=[2]f32{p.x,p.z}
            if known,found:=normals[key];found {testing.expect_value(t,known,mesh.geometry.normals[v]);shared+=1} else {normals[key]=mesh.geometry.normals[v]}
        }
    }
    testing.expect(t,shared>64)
}

@(test)
far_rays_find_a_large_paged_heightfield_and_chunks_keep_picking_triangles :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    testing.expect(t,source_make(&s,.Heightfield,{1025,1,1025},1,64))
    for z in 0..<1025 {for x in 0..<1025 {source_set(&s,{x,0,z},hill_height(&s,x,z,60,120))}}
    eye:=[3]f32{0,150,200}
    for target in ([4][3]f32{{0,0,0},{-150,0,-100},{200,0,-300},{-400,0,350}}) {
        point,_,ok:=source_ray(&s,eye,target-eye)
        testing.expectf(t,ok,"a ray from %v toward %v misses",eye,target)
        if ok {testing.expect(t,abs(point.y-source_height(&s,point.x,point.z))<1e-2)}
    }
    assets:host.Assets;testing.expect(t,host.assets_init(&assets,{root="assets",capacity=8}));defer host.assets_destroy(&assets)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    testing.expect(t,chunk_build(&s,{3,0,3},&mesh,false,{level=2,sides={2,2,2,2}}))
    id,made:=chunk_publish(&assets,&mesh,false,picking=true)
    testing.expect(t,made)
    buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer);defer geom.mesh_buffer_destroy(&buffer)
    testing.expect(t,host.assets_geometry(&assets,id,.None,&buffer) && len(buffer.indices)==len(mesh.geometry.indices),"a chunk without a collider keeps triangles to pick")
    _,heightfield:=host.assets_heightfield(&assets,id)
    testing.expect(t,!heightfield)
}
