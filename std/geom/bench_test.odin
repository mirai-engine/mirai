package geom

import "core:fmt"
import "core:testing"
import "core:time"
import "mirai:std/base"

// Benchmarks run with: mirai test std/geom bench --release -define:GEOM_BENCH=true
GEOM_BENCH :: #config(GEOM_BENCH,false)

@(test)
bench_isosurface :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        values:=make([]f32,33*33*33);defer delete(values)
        grid:=iso_sphere(values,33)
        out:Mesh_Buffer;mesh_buffer_init(&out);defer mesh_buffer_destroy(&out)
        isosurface(grid,{},{32,32,32},&out)
        runs:=30
        start:=time.tick_now()
        for _ in 0..<runs {isosurface(grid,{},{32,32,32},&out)}
        bench_report("isosurface 33^3 sphere, reused output",runs,time.tick_since(start),fmt.tprintf("%d triangles",len(out.indices)/3))
    }
}

@(private) bench_report :: proc(name:string,runs:int,total:time.Duration,detail:string="") {
    fmt.printfln("BENCH %-44s %.3f ms  %s",name,time.duration_milliseconds(total)/f64(runs),detail)
}

@(test)
bench_hull :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        points:=make([]Vec3,10000)
        defer delete(points)
        for kind in ([?]Cloud{.Ball,.Box,.Sphere_Surface}) {
            rng:=base.rng_make(42)
            cloud_fill(points,kind,&rng)
            for limit in ([?]int{0,64}) {
                if kind!=.Sphere_Surface && limit!=0 {continue}
                runs:=20
                vertices,faces:=0,0
                start:=time.tick_now()
                for _ in 0..<runs {
                    hull,_:=hull_build(points,{max_vertices=limit})
                    vertices,faces=len(hull.vertices),len(hull.faces)
                    hull_destroy(&hull)
                }
                bench_report(fmt.tprintf("hull 10000 points %v max %d",kind,limit),runs,time.tick_since(start),fmt.tprintf("%d vertices, %d faces",vertices,faces))
            }
        }
    }
}

// Sphere of exactly 10,000 triangles with normals and texture coordinates.
@(private) bench_sphere :: proc(b:^Mesh_Buffer) {
    sphere_build(b,1,100,51)
    assert(len(b.indices)==30000)
}

@(test)
bench_slice :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        r:Slice_Rig
        slice_rig_init(&r)
        defer slice_rig_destroy(&r)
        bench_sphere(&r.mesh)
        mesh:=mesh_buffer_view(&r.mesh)
        planes:=[?]Plane{{{0,1,0},0.1},{{1,2,3},0.3},{{1,0,0},0.95}}
        for plane in planes {
            runs:=200
            result:Slice_Result
            mesh_slice(&r.slicer,mesh,plane,&r.front,&r.back)
            start:=time.tick_now()
            for _ in 0..<runs {result,_=mesh_slice(&r.slicer,mesh,plane,&r.front,&r.back)}
            bench_report(fmt.tprintf("slice 10000 triangles, plane %v",plane),runs,time.tick_since(start),
                fmt.tprintf("%d + %d triangles, %d cap triangles",result.front.triangles,result.back.triangles,result.front.cap_triangles))
        }
    }
}

@(test)
bench_fracture :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        f:Fracture
        fracture_init(&f)
        defer fracture_destroy(&f)
        b:Mesh_Buffer
        mesh_buffer_init(&b)
        defer mesh_buffer_destroy(&b)
        bench_sphere(&b)
        mesh:=mesh_buffer_view(&b)
        lo,hi:=mesh_bounds(mesh.positions)
        sites:[128]Vec3
        for count in ([?]int{32,128}) {
            for pattern in Site_Pattern {
                sites_generate(sites[:count],{pattern=pattern,seed=1,lo=lo,hi=hi,center={0,1,0},radius=1})
                runs:=5
                mesh_fracture(&f,mesh,sites[:count])
                start:=time.tick_now()
                for _ in 0..<runs {mesh_fracture(&f,mesh,sites[:count])}
                bench_report(fmt.tprintf("fracture 10000 triangles, %d sites %v",count,pattern),runs,time.tick_since(start),
                    fmt.tprintf("%d pieces, %d triangles, %d connections",len(f.pieces),len(f.mesh.indices)/3,len(f.connections)))
            }
        }
    }
}

@(test)
bench_simplify :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        ball:Mesh_Buffer
        mesh_buffer_init(&ball)
        defer mesh_buffer_destroy(&ball)
        welded(&ball,proc(out:^Mesh_Buffer) {icosphere_build(out,1,5)})
        destination:=make([]u32,len(ball.indices))
        defer delete(destination)
        for share in ([?]int{2,10,100}) {
            target:=len(ball.indices)/3/share
            runs:=5
            result:Simplify_Result
            start:=time.tick_now()
            for _ in 0..<runs {result,_=simplify(destination,ball.indices[:],ball.positions[:],target*3,max(f32))}
            bench_report(fmt.tprintf("simplify %d triangles to 1/%d",len(ball.indices)/3,share),runs,time.tick_since(start),fmt.tprintf("%d triangles, error %.4f",result.index_count/3,result.result_error))
        }
    }
}

@(test)
bench_decompose :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        ring:Mesh_Buffer
        mesh_buffer_init(&ring)
        defer mesh_buffer_destroy(&ring)
        welded(&ring,proc(out:^Mesh_Buffer) {torus_build(out,1,0.3,64,32)})
        source:=mesh_buffer_view(&ring)
        volume:=mesh_volume(source.positions,source.indices)
        for hulls in ([?]int{1,8,16}) {
            runs:=3
            count:=0
            held:f32
            start:=time.tick_now()
            for _ in 0..<runs {
                d,_:=mesh_decompose(source,{max_hulls=hulls})
                count,held=len(d.hulls),d.volume
                decomposition_destroy(&d)
            }
            bench_report(fmt.tprintf("decompose torus of %d triangles, max %d hulls",mesh_triangle_count(source),hulls),runs,time.tick_since(start),fmt.tprintf("%d hulls, volume %.3f for a mesh of %.3f",count,held,volume))
        }
    }
}

@(test)
bench_tangents :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        b:Mesh_Buffer
        mesh_buffer_init(&b)
        defer mesh_buffer_destroy(&b)
        bench_sphere(&b)
        mesh:=mesh_buffer_view(&b)
        corners:=make([]Vec4,len(mesh.indices))
        defer delete(corners)
        runs:=20
        _=corner_tangents(mesh.positions,mesh.normals,mesh.uvs,mesh.indices,corners)
        start:=time.tick_now()
        for _ in 0..<runs {
            _=corner_tangents(mesh.positions,mesh.normals,mesh.uvs,mesh.indices,corners)
        }
        bench_report("tangents 10000 triangles",runs,time.tick_since(start),fmt.tprintf("%d corners",len(corners)))
    }
}

@(test)
bench_polygon_convex_partition :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        points:[100]Vec2
        for &p,i in points[:96] {
            s,c:=turn_sincos(f64(i)/96)
            radius:f64=2 if i%2==0 else 1.6
            p={f32(radius*c),f32(radius*s)}
        }
        copy(points[96:],[]Vec2{{-0.5,-0.5},{-0.5,0.5},{0.5,0.5},{0.5,-0.5}})
        indices,sizes:[dynamic]u32
        defer {delete(indices);delete(sizes)}
        runs:=2000
        count:=0
        start:=time.tick_now()
        for _ in 0..<runs {
            clear(&indices);clear(&sizes)
            count=polygon_convex_partition(points[:],{96,4},&indices,&sizes)
        }
        bench_report("convex partition of 100 points with a hole",runs,time.tick_since(start),fmt.tprintf("%d pieces",count))    }
}
