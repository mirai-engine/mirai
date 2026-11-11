package terrain

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"

// An open bumpy surface of n by n cells of half a metre, with a seam of uvs
// and normals at column seam and a band of material 1, as a Mesh source.
@(private)
lod_mesh_source :: proc(t:^testing.T,s:^Source,n:int,cell:f32=0.5,chunk_cells:=16,seam:=20) {
    height :: proc(x,z:int) -> f32 {return math.sin(f32(x)*0.37)*1.5+math.cos(f32(z)*0.23)*2+f32((x*7+z*13)%5)*0.1}
    mesh:geom.Mesh_Buffer;geom.mesh_buffer_init(&mesh);defer geom.mesh_buffer_destroy(&mesh)
    for z in 0..=n {for x in 0..=n {
        append(&mesh.positions,[3]f32{f32(x)*cell,height(x,z),f32(z)*cell})
        append(&mesh.uvs,[2]f32{f32(x),f32(z)}/f32(n))
    }}
    copies:=make([]u32,n+1,context.temp_allocator)
    for z in 0..=n {
        copies[z]=u32(len(mesh.positions))
        append(&mesh.positions,mesh.positions[seam+(n+1)*z])
        append(&mesh.uvs,[2]f32{-1,f32(z)/f32(n)})
    }
    for z in 0..<n {for x in 0..<n {
        v :: proc(x,z,n,seam:int,copies:[]u32,left:bool) -> u32 {return left && x==seam?copies[z]:u32(x+(n+1)*z)}
        left:=x<seam
        a,b,c,d:=v(x,z,n,seam,copies,left),v(x+1,z,n,seam,copies,left),v(x,z+1,n,seam,copies,left),v(x+1,z+1,n,seam,copies,left)
        append(&mesh.indices,a,c,b,b,c,d)
        material:=u32(z>=10 && z<20 ? 1 : 0)
        append(&mesh.materials,material,material)
    }}
    resize(&mesh.normals,len(mesh.positions))
    geom.mesh_compute_normals(mesh.positions[:],mesh.indices[:],mesh.normals[:])
    slots:=[2]base.Asset_Id{{1,1},{2,2}}
    testing.expect(t,source_from_mesh(s,geom.mesh_buffer_view(&mesh),cell,chunk_cells,slots[:]))
}

// A closed blob with bumps a coarse level does not read, inside the air
// margin of a Volume source of n samples per axis.
@(private)
lod_volume_source :: proc(t:^testing.T,s:^Source,n:int,chunk_cells:=8) {
    testing.expect(t,source_make(s,.Volume,{n,n,n},1,chunk_cells))
    band:=s.cell*SDF_BAND_CELLS
    center:=f32(n-1)*0.5
    for z in 0..<n {for y in 0..<n {for x in 0..<n {
        value:=band
        if x>0 && y>0 && z>0 && x<n-1 && y<n-1 && z<n-1 {
            p:=[3]f32{f32(x),f32(y),f32(z)}-center
            value=clamp(linalg.length(p*[3]f32{1,1.4,1})-center*0.7+f32((x*7+y*3+z*13)%5)*0.15,-band,band)
        }
        testing.expect(t,source_set(s,{x,y,z},value))
    }}}
}

@(private="file")
lod_random_levels :: proc(s:^Source,levels:[]u8,random:^rand.Default_Random_State,round:int) {
    for &level,i in levels {
        maximum:=int(chunk_lod_max(s,chunk_coord(s,i)))
        switch round {
        case 0: level=0
        case 1: level=u8(maximum)
        case: level=u8(rand.int_max(maximum+1,rand.default_random_generator(random)))
        }
    }
}

@(private)
lod_append :: proc(all:^geom.Mesh_Buffer,m:^geom.Mesh_Buffer) {
    first:=u32(len(all.positions))
    append(&all.positions,..m.positions[:])
    append(&all.normals,..m.normals[:])
    for index in m.indices {append(&all.indices,index+first)}
    append(&all.materials,..m.materials[:])
}

@(test)
mesh_sections_of_mixed_levels_join_without_cracks_or_overlaps :: proc(t:^testing.T) {
    N :: 48
    s:Source;defer source_destroy(&s)
    lod_mesh_source(t,&s,N,0.5,24)
    counts:=chunk_counts(&s)
    testing.expect_value(t,counts,[3]int{2,1,2})
    levels:=make([]u8,counts.x*counts.z);defer delete(levels)
    for i in 0..<len(levels) {testing.expect(t,chunk_lod_max(&s,chunk_coord(&s,i))>=2)}
    // The triangles of the source of each material.
    material_area:[2]f32
    for &section in s.mesh_chunks {
        g:=&section.geometry
        for at:=0;at<len(g.indices);at+=3 {
            a,b,c:=g.positions[g.indices[at]],g.positions[g.indices[at+1]],g.positions[g.indices[at+2]]
            material_area[g.materials[at/3]]+=((b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z))*0.5
        }
    }
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    all,welded:geom.Mesh_Buffer
    geom.mesh_buffer_init(&all);geom.mesh_buffer_init(&welded)
    defer {geom.mesh_buffer_destroy(&all);geom.mesh_buffer_destroy(&welded)}
    random:=rand.create(11)
    extent:=f32(N)*0.5
    for round in 0..<6 {
        lod_random_levels(&s,levels,&random,round)
        geom.mesh_buffer_clear(&all)
        for i in 0..<len(levels) {
            coord:=chunk_coord(&s,i)
            lod:=chunk_lod_sides(&s,levels,coord)
            testing.expect_value(t,lod.faces,[6]u8{lod.level,lod.level,lod.level,lod.level,lod.level,lod.level})
            testing.expect(t,chunk_build(&s,coord,&mesh,round%2==1,lod))
            // Every vertex of a level is one of its section, in the space of the chunk.
            for p in mesh.geometry.positions {
                found:=false
                for q in s.mesh_chunks[i].geometry.positions {if q-mesh.origin==p {found=true;break}}
                testing.expect(t,found,"a vertex of a level is one of its section")
            }
            chunk_in_terrain(&mesh)
            section:=len(s.mesh_chunks[i].geometry.indices)/3
            if lod.level>0 {
                testing.expect(t,len(mesh.geometry.indices)/3<section)
                if round%2==1 {testing.expect_value(t,len(mesh.collision.indices)/3,section)}
            }
            testing.expect_value(t,len(mesh.uv1s),len(mesh.geometry.positions))
            lod_append(&all,&mesh.geometry)
        }
        // Signed over X/Z, with each edge used once each way: the surface is covered once.
        area:f32
        shown:[2]f32
        for at:=0;at<len(all.indices);at+=3 {
            a,b,c:=all.positions[all.indices[at]],all.positions[all.indices[at+1]],all.positions[all.indices[at+2]]
            up:=((b.z-a.z)*(c.x-a.x)-(b.x-a.x)*(c.z-a.z))*0.5
            area+=up
            shown[all.materials[at/3]]+=up
        }
        testing.expectf(t,abs(area-extent*extent)<1e-2,"round %d: the triangles cover %g, not the terrain once",round,area)
        for material in 0..<2 {testing.expectf(t,abs(shown[material]-material_area[material])<1e-2,"round %d: material %d covers %g of %g",round,material,shown[material],material_area[material])}
        geom.mesh_weld(geom.mesh_buffer_view(&all),0,&welded)
        edges:=make(map[[2]u32]int,context.temp_allocator)
        directed:=make(map[[2]u32]bool,context.temp_allocator)
        for at:=0;at<len(welded.indices);at+=3 {for corner in 0..<3 {
            a,b:=welded.indices[at+corner],welded.indices[at+(corner+1)%3]
            edges[{min(a,b),max(a,b)}]+=1
            testing.expectf(t,!({a,b} in directed),"round %d: an edge is used twice the same way",round)
            directed[{a,b}]=true
        }}
        for edge,uses in edges {
            if uses==2 {continue}
            testing.expect_value(t,uses,1)
            a,b:=welded.positions[edge[0]],welded.positions[edge[1]]
            outer:=(a.x==b.x && (a.x==0 || a.x==extent)) || (a.z==b.z && (a.z==0 || a.z==extent))
            testing.expectf(t,outer,"round %d: an open edge %v-%v inside the terrain",round,a,b)
        }
    }
}

@(test)
coarse_mesh_and_volume_levels_carry_the_weights_of_their_vertices :: proc(t:^testing.T) {
    for kind in ([2]Source_Kind{.Mesh,.Volume}) {
        s:Source;defer source_destroy(&s)
        if kind==.Mesh {lod_mesh_source(t,&s,48)} else {lod_volume_source(t,&s,33)}
        rock:=LAYER_DEFAULT
        rock.auto={enabled=true,slope={0.6,math.PI/2},height={-HEIGHT_LIMIT,HEIGHT_LIMIT},softness={0.2,1}}
        testing.expect(t,source_layer_set(&s,0,LAYER_DEFAULT) && source_layer_set(&s,1,rock) && source_layer_set(&s,2,LAYER_DEFAULT))
        origin:=source_origin(&s)
        brush:=Brush{kind=.Paint,center=origin+[3]f32{8,0,8},radius=6,amount=0.8,layer=2}
        testing.expect(t,source_paint(&s,brush).changed)
        mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
        coord:=[3]i32{1,kind==.Volume?1:0,1}
        level:=chunk_lod_max(&s,coord)
        testing.expect(t,level>0)
        levels:=make([]u8,len(s.mesh_changed)>0?len(s.mesh_changed):chunk_counts(&s).x*chunk_counts(&s).y*chunk_counts(&s).z,context.temp_allocator)
        for &l in levels {l=level}
        testing.expect(t,chunk_build(&s,coord,&mesh,true,chunk_lod_sides(&s,levels,coord)))
        chunk_in_terrain(&mesh)
        m:=&mesh.geometry
        testing.expect(t,len(m.indices)>0)
        // The vertices of slot 0, the surface of the terrain.
        surface:=make([]bool,len(m.positions),context.temp_allocator)
        for at in 0..<len(m.indices)/3 {if len(m.materials)==0 || m.materials[at]==0 {for k in 0..<3 {surface[m.indices[at*3+k]]=true}}}
        for v in 0..<len(m.positions) {
            if !surface[v] {continue}
            p:=m.positions[v]
            w:=layers_vertex(&s,source_weights_at(&s,p),m.normals[v],p.y)
            testing.expectf(t,m.uvs[v]==[2]f32{w[0],w[1]} && mesh.uv1s[v]==[2]f32{w[2],w[3]},"%v: a vertex at %v shows other weights",kind,p)
        }
    }
}

@(test)
volume_chunks_of_mixed_levels_join_closed_without_cracks :: proc(t:^testing.T) {
    s:Source;defer source_destroy(&s)
    lod_volume_source(t,&s,33)
    counts:=chunk_counts(&s)
    testing.expect_value(t,counts,[3]int{4,4,4})
    levels:=make([]u8,counts.x*counts.y*counts.z);defer delete(levels)
    mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
    all,welded:geom.Mesh_Buffer
    geom.mesh_buffer_init(&all);geom.mesh_buffer_init(&welded)
    defer {geom.mesh_buffer_destroy(&all);geom.mesh_buffer_destroy(&welded)}
    random:=rand.create(5)
    full:f32
    for round in 0..<8 {
        lod_random_levels(&s,levels,&random,round)
        geom.mesh_buffer_clear(&all)
        for i in 0..<len(levels) {
            coord:=chunk_coord(&s,i)
            lod:=chunk_lod_sides(&s,levels,coord)
            testing.expect(t,chunk_build(&s,coord,&mesh,round%2==1,lod))
            chunk_in_terrain(&mesh)
            if round%2==1 && lod.level>0 && len(mesh.collision.indices)>0 {testing.expect(t,len(mesh.geometry.indices)<len(mesh.collision.indices))}
            lod_append(&all,&mesh.geometry)
        }
        geom.mesh_weld(geom.mesh_buffer_view(&all),0,&welded)
        topology:=geom.mesh_topology(welded.positions[:],welded.indices[:],by_position=false)
        testing.expectf(t,geom.mesh_topology_is_closed(topology),"round %d: the chunks do not close: %v",round,topology)
        volume:=geom.mesh_volume(welded.positions[:],welded.indices[:])
        if round==0 {full=volume}
        testing.expectf(t,volume>0 && abs(volume-full)<0.1*full,"round %d: the chunks enclose %g of %g",round,volume,full)
        // A vertex two chunks share has one normal.
        normals:=make(map[[3]f32][3]f32,context.temp_allocator)
        for p,i in all.positions {
            if old,ok:=normals[p];ok {testing.expect_value(t,all.normals[i],old)} else {normals[p]=all.normals[i]}
        }
    }
}

@(test)
far_mesh_and_volume_chunks_show_coarser_levels_and_collide_at_level_0 :: proc(t:^testing.T) {
    for kind in ([2]Source_Kind{.Mesh,.Volume}) {
        root:=base.test_folder(t,"terrain")
        allocator:=Terrain_Test_Allocator{owner=context.allocator}
        temporary:=Terrain_Test_Allocator{owner=context.temp_allocator}
        context.allocator={terrain_test_allocator,&allocator}
        context.temp_allocator={terrain_test_allocator,&temporary}
        source:Source;defer source_destroy(&source)
        if kind==.Mesh {lod_mesh_source(t,&source,64,1,16,20)} else {lod_volume_source(t,&source,49,16)}
        source.revision=1
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        id:=base.Asset_Id{91,u64(kind)}
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
        s:=&source
        low,high:[3]f32
        if kind==.Mesh {low,high=geom.mesh_bounds(s.mesh_chunks[0].geometry.positions[:]);for &chunk in s.mesh_chunks {a,b:=geom.mesh_bounds(chunk.geometry.positions[:]);low,high=linalg.min(low,a),linalg.max(high,b)}} else {low=source_origin(s);high=-low}
        view:=core.VIEW_DEFAULT
        view.position={low.x-6,high.y+2,low.z-6}
        settings:=Terrain_Settings{lod_distance=6,samples=16*1024*1024}
        for _ in 0..<3 {terrain_test_update(&w,&resident,&app,view=view,settings=settings)}
        testing.expectf(t,w.problems.count==0,"%v: %v",kind,core.problems_list(&w.problems))
        if !testing.expect(t,len(resident.sources)==1) {continue}
        chunks:=resident.sources[0].chunks
        loaded:=&w.data.entries[0].source
        coarse:=0
        for chunk,i in chunks {
            if chunk.mesh=={} {continue}
            testing.expect(t,chunk.built.collision)
            ref:=assets.index[chunk.mesh]
            drawn:=int(assets.meshes[ref.index].index_count)/3
            buffer:geom.Mesh_Buffer;geom.mesh_buffer_init(&buffer,context.temp_allocator)
            _,collides:=host.assets_collision(&assets,chunk.mesh,.None,.Mesh,&buffer)
            testing.expect(t,collides)
            if chunk.built.lod.level==0 {testing.expect_value(t,len(buffer.indices)/3,drawn);continue}
            testing.expectf(t,drawn<=len(buffer.indices)/3,"%v chunk %d at level %d draws %d triangles and collides with %d",kind,i,chunk.built.lod.level,drawn,len(buffer.indices)/3)
            if drawn<len(buffer.indices)/3 {coarse+=1}
        }
        testing.expectf(t,coarse>0,"%v: no chunk is coarse",kind)
        // A ray far from the view meets the collider where the source is, not where a coarse level is.
        far:=[3]f32{high.x-3.3,high.y+5,high.z-4.7}
        if kind==.Volume {far={6.3,high.y+5,7.7}}
        expected,_,found:=source_ray(loaded,far,{0,-1,0})
        hit,ok:=phys.raycast({&w.state},far,{0,-1,0})
        testing.expectf(t,found && ok && abs(hit.point.y-expected.y)<1e-4,"%v: the collider is at %v, the source at %v",kind,hit.point,expected)
        // Near a boundary the levels hold, and a frame that changes nothing builds and allocates nothing.
        built:=resident.stats.built
        view.position+={0.1,0,0}
        terrain_test_update(&w,&resident,&app,view=view,settings=settings)
        testing.expect_value(t,resident.stats.built,built)
        calls,temps:=allocator.requests,temporary.requests
        for _ in 0..<10 {terrain_test_update(&w,&resident,&app,view=view,settings=settings)}
        testing.expect_value(t,allocator.requests,calls)
        testing.expect_value(t,temporary.requests,temps)
        testing.expect_value(t,resident.stats.built,built)
        // The view crosses the terrain: the far chunks become fine.
        view.position={high.x-2,high.y,high.z-2}
        terrain_test_update(&w,&resident,&app,view=view,settings=settings)
        last:=len(chunks)-1
        testing.expect_value(t,chunks[last].built.lod.level,u8(0))
        testing.expect(t,chunks[0].built.lod.level>0)
        hit,ok=phys.raycast({&w.state},far,{0,-1,0})
        testing.expect(t,ok && abs(hit.point.y-expected.y)<1e-4)
        testing.expect_value(t,w.problems.count,0)
    }
}
