package spatial

import "core:log"
import "core:slice"
import "core:testing"
import "core:time"

// Benchmarks: mirai test std/spatial <name> --release -define:SPATIAL_BENCH=true -define:ODIN_TEST_THREADS=1
@(private="file") SPATIAL_BENCH :: #config(SPATIAL_BENCH,false)

// Time per operation over many short batches. The machine is shared, so the fastest batch is the
// figure to compare and the median shows what the load of the moment adds.
@(private="file") Samples :: struct {values:[256]f64, count:int}
@(private="file") sample :: proc(s:^Samples, start:time.Tick, operations:int) {
    s.values[s.count]=f64(time.duration_nanoseconds(time.tick_since(start)))/f64(max(operations,1))
    s.count+=1
}
@(private="file") best :: proc(s:^Samples) -> f64 {return slice.min(s.values[:s.count])}
@(private="file") median :: proc(s:^Samples) -> f64 {
    slice.sort(s.values[:s.count])
    return s.values[s.count/2]
}

@(test)
benchmark_dynamic_tree_with_ten_thousand_proxies :: proc(t:^testing.T) {
    when SPATIAL_BENCH {
        COUNT :: 10000
        ROUNDS :: 100
        MOVED :: COUNT/10
        BATCH :: 500
        tree:Dynamic_Tree
        testing.expect(t,dynamic_tree_init(&tree,{proxy_capacity=COUNT,margin=0.1}))
        defer dynamic_tree_destroy(&tree)
        random:=random_make(1)
        // A level 200 m wide and 20 m tall, bodies up to 2 m across.
        tight:=make([]Aabb,COUNT)
        proxies:=make([]i32,COUNT)
        steps:=make([][3]f32,ROUNDS*MOVED)
        rays:=make([][2][3]f32,COUNT)
        defer {delete(tight);delete(proxies);delete(steps);delete(rays)}
        for &box in tight {
            center:=[3]f32{random_f32(&random,-100,100),random_f32(&random,0,20),random_f32(&random,-100,100)}
            half:=random_vector(&random,0.25,1)
            box={center-half,center+half}
        }
        for &step in steps {step=random_vector(&random,-0.5,0.5)}
        for &ray in rays {
            ray={{random_f32(&random,-100,100),random_f32(&random,0,20),random_f32(&random,-100,100)},random_vector(&random,-60,60)}
        }

        insert,query,move,update,ray,sweep:Samples
        for _ in 0..<12 {
            dynamic_tree_clear(&tree)
            start:=time.tick_now()
            for box,i in tight {proxies[i],_=dynamic_tree_insert(&tree,box,u64(i))}
            sample(&insert,start,COUNT)
        }
        height,ratio:=dynamic_tree_height(&tree),dynamic_tree_area_ratio(&tree)

        pairs:=0
        for pass in 0..<3 {
            for batch in 0..<COUNT/BATCH {
                start:=time.tick_now()
                for proxy in proxies[batch*BATCH:][:BATCH] {
                    q:=dynamic_tree_query(&tree,dynamic_tree_aabb(&tree,proxy))
                    for other in tree_query_next(&q) {
                        if other>proxy&&pass==0 {pairs+=1}
                    }
                }
                sample(&query,start,BATCH)
            }
        }

        // Each round a tenth of the bodies moves up to 0.5 m on each axis.
        for round in 0..<ROUNDS {
            start:=time.tick_now()
            for i in 0..<MOVED {
                slot:=(round*MOVED+i*7)%COUNT
                step:=steps[round*MOVED+i]
                tight[slot]={tight[slot].min+step,tight[slot].max+step}
                dynamic_tree_move(&tree,proxies[slot],tight[slot])
            }
            sample(&move,start,MOVED)
        }
        reinserted:=0
        for round in 0..<ROUNDS {
            start:=time.tick_now()
            for i in 0..<MOVED {
                slot:=(round*MOVED+i*7)%COUNT
                step:=steps[round*MOVED+i]
                tight[slot]={tight[slot].min-step,tight[slot].max-step}
                if dynamic_tree_update(&tree,proxies[slot],tight[slot],-step) {reinserted+=1}
            }
            sample(&update,start,MOVED)
        }

        touched:=0
        for pass in 0..<3 {
            for batch in 0..<COUNT/BATCH {
                start:=time.tick_now()
                for segment in rays[batch*BATCH:][:BATCH] {
                    r:=dynamic_tree_ray(&tree,segment[0],segment[1],1)
                    for _ in tree_ray_next(&r) {touched+=1}
                }
                sample(&ray,start,BATCH)
                start=time.tick_now()
                for segment,i in rays[batch*BATCH:][:BATCH] {
                    s:=dynamic_tree_sweep(&tree,tight[batch*BATCH+i],segment[1],1)
                    for _ in tree_sweep_next(&s) {touched+=1}
                }
                sample(&sweep,start,BATCH)
            }
        }

        testing.expect(t,dynamic_tree_validate(&tree))
        log.infof("dynamic tree, %d proxies, ns per operation as fastest batch (median batch)",COUNT)
        log.infof("  insert %.0f (%.0f): %.2f ms for all; height %d, area ratio %.1f",best(&insert),median(&insert),best(&insert)*COUNT/1e6,height,ratio)
        log.infof("  pair query %.0f (%.0f): %.2f ms for all, %d pairs",best(&query),median(&query),best(&query)*COUNT/1e6,pairs)
        log.infof("  move %.0f (%.0f): %.2f ms per round of %d",best(&move),median(&move),best(&move)*MOVED/1e6,MOVED)
        log.infof("  update with a 0.1 m margin %.0f (%.0f), %d of %d reinserted",best(&update),median(&update),reinserted,ROUNDS*MOVED)
        log.infof("  ray %.0f (%.0f), sweep %.0f (%.0f), up to 100 m long, %.1f leaves each",best(&ray),median(&ray),best(&sweep),median(&sweep),f64(touched)/(6*COUNT))
        log.infof("  after the moves: height %d, area ratio %.1f",dynamic_tree_height(&tree),dynamic_tree_area_ratio(&tree))
    }
}

// Distance along the ray to the triangle, as a fraction of the translation.
@(private="file") ray_triangle :: proc(origin,translation,a,b,c:[3]f32) -> (fraction:f32, hit:bool) {
    cross :: proc(u,v:[3]f32) -> [3]f32 {return {u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x}}
    dot :: proc(u,v:[3]f32) -> f32 {return u.x*v.x+u.y*v.y+u.z*v.z}
    e1,e2:=b-a,c-a
    p:=cross(translation,e2)
    det:=dot(e1,p)
    if abs(det)<1e-12 {return 0,false}
    s:=origin-a
    u:=dot(s,p)/det
    if u<0||u>1 {return 0,false}
    q:=cross(s,e1)
    v:=dot(translation,q)/det
    if v<0||u+v>1 {return 0,false}
    fraction=dot(e2,q)/det
    return fraction,fraction>=0
}

@(test)
benchmark_bvh_with_one_hundred_thousand_triangles :: proc(t:^testing.T) {
    when SPATIAL_BENCH {
        CELLS :: 224
        RAYS :: 100000
        BATCH :: 1000
        vertices,indices:=grid_mesh(CELLS,224,6)
        defer {delete(vertices);delete(indices)}
        defer free_all(context.temp_allocator)
        triangles:=len(indices)/3

        bvh:Bvh
        build,closest,every,query,sweep:Samples
        for _ in 0..<8 {
            bvh_destroy(&bvh)
            free_all(context.temp_allocator)
            start:=time.tick_now()
            testing.expect(t,bvh_build_triangles(&bvh,vertices,indices,{}))
            sample(&build,start,1)
        }
        defer bvh_destroy(&bvh)
        testing.expect(t,bvh_validate(&bvh))
        leaves,largest:=0,u32(0)
        for node in bvh.nodes {
            if node.count>0 {leaves+=1;largest=max(largest,node.count)}
        }

        random:=random_make(2)
        rays:=make([][2][3]f32,RAYS)
        boxes:=make([]Aabb,RAYS)
        defer {delete(rays);delete(boxes)}
        for &ray,i in rays {
            // From above the terrain towards a point below it, at any slope.
            origin:=[3]f32{random_f32(&random,0,224),random_f32(&random,10,40),random_f32(&random,0,224)}
            target:=[3]f32{random_f32(&random,0,224),-10,random_f32(&random,0,224)}
            ray={origin,target-origin}
            center:=[3]f32{random_f32(&random,0,224),random_f32(&random,-6,6),random_f32(&random,0,224)}
            boxes[i]={center-1,center+1}
        }

        hits,closest_leaves,tests,every_leaves,found,swept:=0,0,0,0,0,0
        for batch in 0..<RAYS/BATCH {
            start:=time.tick_now()
            for ray in rays[batch*BATCH:][:BATCH] {
                r:=bvh_ray(&bvh,ray[0],ray[1],1)
                nearest:=-1
                for primitives in bvh_ray_next(&r) {
                    closest_leaves+=1
                    for primitive in primitives {
                        tests+=1
                        a,b,c:=vertices[indices[3*primitive]],vertices[indices[3*primitive+1]],vertices[indices[3*primitive+2]]
                        if fraction,hit:=ray_triangle(ray[0],ray[1],a,b,c);hit&&fraction<=r.max_fraction {
                            r.max_fraction=fraction
                            nearest=int(primitive)
                        }
                    }
                }
                if nearest>=0 {hits+=1}
            }
            sample(&closest,start,BATCH)
            start=time.tick_now()
            for ray in rays[batch*BATCH:][:BATCH] {
                r:=bvh_ray(&bvh,ray[0],ray[1],1)
                for _ in bvh_ray_next(&r) {every_leaves+=1}
            }
            sample(&every,start,BATCH)
            start=time.tick_now()
            for box in boxes[batch*BATCH:][:BATCH] {
                q:=bvh_query(&bvh,box)
                for primitives in bvh_query_next(&q) {found+=len(primitives)}
            }
            sample(&query,start,BATCH)
            start=time.tick_now()
            for box,i in boxes[batch*BATCH:][:BATCH] {
                s:=bvh_sweep(&bvh,box,rays[batch*BATCH+i][1]*0.1,1)
                for primitives in bvh_sweep_next(&s) {swept+=len(primitives)}
            }
            sample(&sweep,start,BATCH)
        }
        log.infof("bvh, %d triangles, ns per operation as fastest batch (median batch)",triangles)
        log.infof("  build %.2f ms (%.2f ms): %.0f ns per triangle, %d nodes, %d leaves of %.2f triangles, at most %d",
            best(&build)/1e6,median(&build)/1e6,best(&build)/f64(triangles),len(bvh.nodes),leaves,f64(triangles)/f64(leaves),largest)
        log.infof("  closest hit %.0f (%.0f): %.2f M rays/s, %d of %d hit, %.1f leaves and %.1f triangle tests per ray",
            best(&closest),median(&closest),1e3/best(&closest),hits,RAYS,f64(closest_leaves)/RAYS,f64(tests)/RAYS)
        log.infof("  every leaf on the ray %.0f (%.0f), %.1f leaves per ray",best(&every),median(&every),f64(every_leaves)/RAYS)
        log.infof("  query of a 2 m box %.0f (%.0f), %.1f triangles each",best(&query),median(&query),f64(found)/RAYS)
        log.infof("  sweep of a 2 m box %.0f (%.0f), %.1f triangles each",best(&sweep),median(&sweep),f64(swept)/RAYS)
    }
}
