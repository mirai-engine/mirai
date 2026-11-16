package spatial

import "core:log"
import "core:testing"
import "core:time"

// mirai test std/spatial benchmark_grids_and_octree_with_ten_thousand_items --release -define:SPATIAL_BENCH=true -define:ODIN_TEST_THREADS=1
@(private="file") SPATIAL_BENCH :: #config(SPATIAL_BENCH,false)

@(test)
benchmark_grids_and_octree_with_ten_thousand_items :: proc(t:^testing.T) {
    when SPATIAL_BENCH {
        COUNT :: 10000
        ROUNDS :: 9
        // The level of the tree benchmark: 200 m wide and 20 m tall, bodies up to 2 m across.
        bounds:=Aabb{{-104,-4,-104},{104,24,104}}
        random:=random_make(1)
        boxes:=make([]Aabb,COUNT)
        moved:=make([]Aabb,COUNT)
        rays:=make([][2][3]f32,COUNT)
        items:=make([]i32,COUNT)
        defer {delete(boxes);delete(moved);delete(rays);delete(items)}
        for &box,i in boxes {
            center:=[3]f32{random_f32(&random,-100,100),random_f32(&random,0,20),random_f32(&random,-100,100)}
            half:=random_vector(&random,0.25,1)
            box={center-half,center+half}
            step:=random_vector(&random,-0.5,0.5)
            moved[i]={box.min+step,box.max+step}
        }
        for &ray in rays {
            ray={{random_f32(&random,-100,100),random_f32(&random,0,20),random_f32(&random,-100,100)},random_vector(&random,-60,60)}
        }
        Kind :: enum {Grid,Hash,Octree}
        names:=[Kind]string{.Grid="uniform grid, 4 m cells",.Hash="spatial hash, 4 m cells, 16384 lists",.Octree="octree, 8 levels, 8 per leaf"}
        for kind in Kind {
            g:Grid
            o:Octree
            switch kind {
            case .Grid: testing.expect(t,grid_init(&g,{cell_size=4,bounds=bounds,item_capacity=COUNT}))
            case .Hash: testing.expect(t,grid_init(&g,{cell_size=4,buckets=16384,item_capacity=COUNT}))
            case .Octree: testing.expect(t,octree_init(&o,{bounds=bounds,item_capacity=COUNT}))
            }
            defer {grid_destroy(&g);octree_destroy(&o)}
            best:[4]f64={1e30,1e30,1e30,1e30}
            found:[2]int
            for _ in 0..<ROUNDS {
                if kind==.Octree {octree_clear(&o)} else {grid_clear(&g)}
                start:=time.tick_now()
                if kind==.Octree {
                    for box,i in boxes {items[i],_=octree_insert(&o,box,u64(i))}
                } else {
                    for box,i in boxes {items[i],_=grid_insert(&g,box,u64(i))}
                }
                best[0]=min(best[0],f64(time.duration_nanoseconds(time.tick_since(start)))/COUNT)
                start=time.tick_now()
                if kind==.Octree {
                    for box,i in moved {octree_move(&o,items[i],box)}
                } else {
                    for box,i in moved {grid_move(&g,items[i],box)}
                }
                best[1]=min(best[1],f64(time.duration_nanoseconds(time.tick_since(start)))/COUNT)
                found={}
                start=time.tick_now()
                if kind==.Octree {
                    for box in boxes {
                        q:=octree_query(&o,box)
                        for _ in octree_query_next(&q) {found[0]+=1}
                    }
                } else {
                    for box in boxes {
                        q:=grid_query(&g,box)
                        for _ in grid_query_next(&q) {found[0]+=1}
                    }
                }
                best[2]=min(best[2],f64(time.duration_nanoseconds(time.tick_since(start)))/COUNT)
                start=time.tick_now()
                if kind==.Octree {
                    for ray in rays {
                        r:=octree_ray(&o,ray[0],ray[1],1)
                        for _ in octree_ray_next(&r) {found[1]+=1}
                    }
                } else {
                    for ray in rays {
                        r:=grid_ray(&g,ray[0],ray[1],1)
                        for _ in grid_ray_next(&r) {found[1]+=1}
                    }
                }
                best[3]=min(best[3],f64(time.duration_nanoseconds(time.tick_since(start)))/COUNT)
            }
            log.infof("%s: insert %.0f ns, move %.0f ns, query %.0f ns (%d overlaps), ray %.0f ns (%d hits)",names[kind],best[0],best[1],best[2],found[0],best[3],found[1])
        }
    }
}
