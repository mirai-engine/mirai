package terrain

import "core:fmt"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

TERRAIN_BENCH :: #config(TERRAIN_BENCH,false)

// The cost of building a chunk of the most cells and its cluster levels, as
// a job builds a piece after an edit: median of the runs, after one that
// warms the buffers. Optional: -define:TERRAIN_BENCH=true, one thread and
// nothing else on the CPU.
@(test)
bench_terrain_levels :: proc(t:^testing.T) {
    when !TERRAIN_BENCH {return} else {
        RUNS :: 5
        N :: CHUNK_CELLS_MAX+1
        s:Source;defer source_destroy(&s)
        testing.expect(t,source_make(&s,.Heightfield,{N,1,N},0.5,CHUNK_CELLS_MAX))
        for z in 0..<N {for x in 0..<N {source_set(&s,{x,0,z},math.sin(f32(x)*0.11)*6+math.cos(f32(z)*0.07)*9+f32((x*7+z*13)%11)*0.08)}}
        mesh:Chunk_Mesh;chunk_mesh_init(&mesh);defer chunk_mesh_destroy(&mesh)
        for levels in ([2]bool{false,true}) {
            build,prepare:[RUNS+1]f64
            for &b,r in build {
                start:=time.tick_now()
                testing.expect(t,chunk_build(&s,{0,0,0},&mesh,true))
                b=time.duration_milliseconds(time.tick_since(start))
                start=time.tick_now()
                testing.expect(t,chunk_render_prepare(&mesh,{},levels))
                prepare[r]=time.duration_milliseconds(time.tick_since(start))
            }
            slice.sort(build[1:]);slice.sort(prepare[1:])
            fmt.printfln("BENCH | %d vertices | levels %v | build %.2f ms | prepare %.2f ms | %d levels |",len(mesh.geometry.positions),levels,build[1+RUNS/2],prepare[1+RUNS/2],len(mesh.render.geometry.levels))
        }
    }
}
