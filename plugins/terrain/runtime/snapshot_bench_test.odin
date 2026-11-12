package terrain

import "core:fmt"
import "core:math"
import "core:mem"
import "core:testing"
import "core:time"

// What copying the terrain of a World costs with an extensive source held in
// memory: a Heightfield of 4097 samples a side with every page holding values
// and its coarse grid, and a Volume of 129³ as source_make leaves it. Play: the first copy into an
// empty World. Rollback: a ring of SNAPSHOT_RING copies, one a tick after a
// brush on the live World, for SNAPSHOT_TICKS ticks: the bytes the ring and
// the edits retain past the live source, and what a warm copy takes.
// Optional: -define:TERRAIN_BENCH=true.
@(private="file") SNAPSHOT_RING :: 8
@(private="file") SNAPSHOT_TICKS :: 64

@(test)
bench_terrain_snapshots :: proc(t:^testing.T) {
    when !TERRAIN_BENCH {return} else {
        Case :: struct {name:string,kind:Source_Kind,samples:[3]int,chunk_cells:int}
        cases:=[?]Case{{"Heightfield 4097x4097",.Heightfield,{4097,1,4097},128},{"Volume 129x129x129",.Volume,{129,129,129},16}}
        for c in cases {
            tracking:mem.Tracking_Allocator
            mem.tracking_allocator_init(&tracking,context.allocator)
            defer mem.tracking_allocator_destroy(&tracking)
            context.allocator=mem.tracking_allocator(&tracking)
            live:Terrain_Data
            live.settings=TERRAIN_SETTINGS_DEFAULT;live.ready=true
            resize(&live.entries,1)
            entry:=&live.entries[0]
            entry.id={9,9}
            s:=&entry.source
            if !testing.expect(t,source_make(s,c.kind,c.samples,1,c.chunk_cells)) {return}
            if c.kind==.Heightfield {
                last:=c.samples-1
                testing.expect(t,grid_prepare(&s.field,{},last,s.allocator))
                for z in 0..<c.samples.z {for x in 0..<c.samples.x {
                    grid_set(&s.field,x,z,math.sin(f32(x)*0.01)*20+math.cos(f32(z)*0.013)*15)
                }}
            }
            entry.change=1
            testing.expect(t,data_chunks_allocate(entry,context.allocator))
            live_bytes:=tracking.current_memory_allocated

            play:Terrain_Data
            start:=time.tick_now()
            testing.expect(t,terrain_data_copy(&play,&live))
            play_ms:=time.duration_milliseconds(time.tick_since(start))
            play_bytes:=tracking.current_memory_allocated-live_bytes
            terrain_data_free(&play)

            ring:[SNAPSHOT_RING]Terrain_Data
            before:=tracking.current_memory_allocated
            warm:f64
            for tick in 0..<SNAPSHOT_TICKS {
                at:=f32(tick)*3-90
                brush:=Brush{kind=.Raise,center={at,0,at*0.5},radius=4,amount=0.25,falloff=.Smooth,hardness=0.5}
                if c.kind==.Volume {brush=Brush{kind=.Carve,center={at*0.5,-20,0},radius=3,amount=1}}
                change:=source_edit(s,brush)
                testing.expect(t,change.changed)
                // As an edit of the World does: the coarse grid follows the samples.
                if c.kind==.Heightfield {source_coarse_update(s,change.low,change.high)}
                start=time.tick_now()
                testing.expect(t,terrain_data_copy(&ring[tick%SNAPSHOT_RING],&live))
                if tick>=SNAPSHOT_RING {warm+=time.duration_milliseconds(time.tick_since(start))}
            }
            ring_bytes:=tracking.current_memory_allocated-before
            fmt.printfln("BENCH | %s | values %d | live %d | play copy %d bytes %.2f ms | ring of %d after %d ticks %d bytes | warm copy %.3f ms |",c.name,source_cost(s)*4,live_bytes,play_bytes,play_ms,SNAPSHOT_RING,SNAPSHOT_TICKS,ring_bytes,warm/f64(SNAPSHOT_TICKS-SNAPSHOT_RING))
            for &snapshot in ring {terrain_data_free(&snapshot)}
            terrain_data_free(&live)
        }
    }
}
