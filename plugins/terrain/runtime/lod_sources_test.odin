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

