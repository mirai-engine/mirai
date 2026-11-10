package terrain

import "core:fmt"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"
import "mirai:std/geom"

TERRAIN_BENCH :: #config(TERRAIN_BENCH,false)

// The cost of building a chunk at each level: median of the runs, after one
// that warms the buffers, with the triangles it draws and those it collides
// with. Optional: -define:TERRAIN_BENCH=true, one thread and nothing else on
// the CPU.
@(test)
bench_terrain_levels :: proc(t:^testing.T) {
    when !TERRAIN_BENCH {return} else {
        RUNS :: 9
        mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
        report :: proc(t:^testing.T,name:string,s:^Source,coord:[3]i32,mesh:^Chunk_Mesh,levels:[]u8) {
            for level in 0..=chunk_lod_max(s,coord) {
                for &l in levels {l=level}
                lod:=chunk_lod_sides(s,levels,coord)
                for collision in ([2]bool{false,true}) {
                    times:[RUNS]f64
                    testing.expect(t,chunk_build(s,coord,mesh,collision,lod))
                    for &value in times {
                        start:=time.tick_now()
                        chunk_build(s,coord,mesh,collision,lod)
                        value=time.duration_milliseconds(time.tick_since(start))
                    }
                    slice.sort(times[:])
                    collides:=len(mesh.collision.indices)>0?len(mesh.collision.indices)/3:len(mesh.geometry.indices)/3
                    fmt.printfln("BENCH | %s | %d | %s | %.3f ms | %d | %d |",name,level,collision?"yes":"no",times[RUNS/2],len(mesh.geometry.indices)/3,collision?collides:0)
                }
            }
        }
        height :: proc(x,z:int) -> f32 {return math.sin(f32(x)*0.11)*6+math.cos(f32(z)*0.07)*9+f32((x*7+z*13)%11)*0.08}
        {
            s:Source;defer source_destroy(&s)
            testing.expect(t,source_make(&s,.Heightfield,{257,1,257},1,64))
            for z in 0..<257 {for x in 0..<257 {source_set(&s,{x,0,z},height(x,z))}}
            levels:=make([]u8,16,context.temp_allocator)
            report(t,"Heightfield 64×64 cells",&s,{1,0,1},&mesh,levels)
        }
        for chunk in ([2]int{16,32}) {
            s:Source;defer source_destroy(&s)
            lod_volume_source(t,&s,65,chunk)
            counts:=chunk_counts(&s)
            levels:=make([]u8,counts.x*counts.y*counts.z,context.temp_allocator)
            // A chunk the surface crosses, off its middle.
            coord:=[3]i32{0,i32(counts.y/2),i32(counts.z/2)}
            report(t,fmt.tprintf("Volume %d³ cells",chunk),&s,coord,&mesh,levels)
        }
    }
}
