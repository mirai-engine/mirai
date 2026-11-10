package mirai_math

@(require) import "core:log"
@(require) import "core:math/linalg"
@(require) import "core:testing"
@(require) import "core:time"

// Measurements of the hot paths: mirai test std/math --release -define:MIRAI_BENCH=true
BENCH :: #config(MIRAI_BENCH,false)

when BENCH {

BENCH_ROUNDS :: 5

// Runs the body several times and keeps the fastest: other processes can only make a round slower.
Bench :: struct {best:time.Duration,start:time.Tick,round:int}
bench_round :: proc(b:^Bench) -> bool {
    if b.round>0 {
        elapsed:=time.tick_since(b.start)
        if b.round==1 || elapsed<b.best {b.best=elapsed}
    }
    if b.round>=BENCH_ROUNDS {return false}
    b.round+=1
    b.start=time.tick_now()
    return true
}
bench_report :: proc(name:string,b:Bench,operations:int,sink:f32=0) {
    log.infof("%-46s %9.2f ns/op   (%d ops, check %v)",name,f64(time.duration_nanoseconds(b.best))/f64(operations),operations,sink)
}

@(test)
bench_transforms :: proc(t:^testing.T) {
    COUNT :: 100000
    rng:=rng_make(1)
    locals:=make([]Transform,COUNT);defer delete(locals)
    worlds:=make([]Transform,COUNT);defer delete(worlds)
    matrices:=make([]Mat4,COUNT);defer delete(matrices)
    for &local in locals {
        local={random_in_sphere(&rng)*10,random_quat(&rng),{random_range(&rng,0.5,2),random_range(&rng,0.5,2),random_range(&rng,0.5,2)}}
    }
    parent:=Transform{{1,2,3},random_quat(&rng),{2,0.5,1.5}}
    b:Bench
    for bench_round(&b) {
        #no_bounds_check for local,i in locals {worlds[i]=transform_compose(parent,local)}
    }
    bench_report("transform_compose",b,COUNT,worlds[COUNT/2].position.x)
    b={}
    for bench_round(&b) {
        #no_bounds_check for world,i in worlds {matrices[i]=transform_matrix(world)}
    }
    bench_report("transform_matrix",b,COUNT,matrices[COUNT/2][0,0])
    b={}
    for bench_round(&b) {
        #no_bounds_check for local,i in locals {matrices[i]=transform_matrix(transform_compose(parent,local))}
    }
    bench_report("compose + matrix (hierarchy flattening)",b,COUNT,matrices[COUNT/2][0,0])
    parent_matrix:=transform_matrix(parent)
    b={}
    for bench_round(&b) {
        #no_bounds_check for i in 0..<COUNT {matrices[i]=parent_matrix*matrices[i]}
    }
    bench_report("(Mat4 * Mat4, for comparison)",b,COUNT,matrices[COUNT/2][0,0])
    b={}
    for bench_round(&b) {
        #no_bounds_check for world,i in worlds {matrices[i],_=transform_inverse_matrix(world)}
    }
    bench_report("transform_inverse_matrix",b,COUNT,matrices[COUNT/2][0,0])
    b={}
    for bench_round(&b) {
        #no_bounds_check for i in 0..<COUNT {matrices[i]=linalg.inverse(matrices[i])}
    }
    bench_report("(linalg.inverse of a Mat4, for comparison)",b,COUNT,matrices[COUNT/2][0,0])
    sink:f32
    b={}
    for bench_round(&b) {
        #no_bounds_check for i in 0..<COUNT-1 {mixed:=transform_interpolate(worlds[i],worlds[i+1],0.3);sink+=mixed.position.x+mixed.rotation.w+mixed.scale.x}
    }
    bench_report("transform_interpolate (nlerp)",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for i in 0..<COUNT-1 {sink+=quat_slerp(worlds[i].rotation,worlds[i+1].rotation,0.3).w}
    }
    bench_report("quat_slerp",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for i in 0..<COUNT-1 {sink+=quat_nlerp(worlds[i].rotation,worlds[i+1].rotation,0.3).w}
    }
    bench_report("quat_nlerp",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for local in locals {sink+=quat_from_euler(local.position).w}
    }
    bench_report("quat_from_euler",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for world in worlds {sink+=quat_to_euler(world.rotation).y}
    }
    bench_report("quat_to_euler",b,COUNT,sink)
}

@(test)
bench_culling_and_queries :: proc(t:^testing.T) {
    COUNT :: 100000
    rng:=rng_make(2)
    boxes:=make([]Aabb,COUNT);defer delete(boxes)
    visible:=make([]u64,(COUNT+63)/64);defer delete(visible)
    for &box in boxes {
        center:=Vec3{random_range(&rng,-200,200),random_range(&rng,-50,50),random_range(&rng,-400,50)}
        box=aabb_from_center(center,{random_range(&rng,0.2,4),random_range(&rng,0.2,4),random_range(&rng,0.2,4)})
    }
    frustum:=frustum_from_matrix(perspective(1.2,16.0/9,0.1,300)*look_at({0,5,10},{0,0,-50},{0,1,0}))
    count:=0
    b:Bench
    for bench_round(&b) {count=frustum_cull_aabbs(frustum,boxes,visible)}
    bench_report("frustum_cull_aabbs (4 lanes), per box",b,COUNT,f32(count))
    b={}
    for bench_round(&b) {count=frustum_cull_aabbs_scalar(frustum,boxes,visible)}
    bench_report("the same, one plane at a time, per box",b,COUNT,f32(count))
    // The other extreme: a frustum that sees everything, where no box is rejected early.
    all:=frustum_from_matrix(orthographic(2000,2000,-1000,1000))
    b={}
    for bench_round(&b) {count=frustum_cull_aabbs(all,boxes,visible)}
    bench_report("frustum_cull_aabbs, all visible, per box",b,COUNT,f32(count))
    b={}
    for bench_round(&b) {count=frustum_cull_aabbs_scalar(all,boxes,visible)}
    bench_report("one plane at a time, all visible, per box",b,COUNT,f32(count))

    ray:=Ray{{0,5,10},linalg.normalize(Vec3{0.1,-0.05,-1})}
    inverse:=1/ray.direction
    sink:f32
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {
            if distance,hit:=ray_aabb_fast(ray.origin,inverse,box,1000);hit {sink+=distance}
        }
    }
    bench_report("ray_aabb_fast",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {
            if distance,_,hit:=ray_aabb(ray,box);hit {sink+=distance}
        }
    }
    bench_report("ray_aabb (with normal)",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {
            if distance,_,hit:=ray_sphere(ray,{box.min,3});hit {sink+=distance}
        }
    }
    bench_report("ray_sphere",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {
            if distance,_,hit:=ray_capsule(ray,{box.min,box.max,2});hit {sink+=distance}
        }
    }
    bench_report("ray_capsule",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {
            if distance,_,hit:=ray_triangle(ray,{box.min,box.max,box.min+{6,0,0}});hit {sink+=distance}
        }
    }
    bench_report("ray_triangle",b,COUNT,sink)
    obb:=Obb{{0,0,-50},quat_from_euler({0.3,0.7,0.2}),{30,10,20}}
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {
            if obb_overlaps(obb,{aabb_center(box),QUAT_IDENTITY,aabb_half(box)}) {sink+=1}
        }
    }
    bench_report("obb_overlaps",b,COUNT,sink)
    merged:=AABB_EMPTY
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {merged=aabb_merge(merged,box)}
    }
    bench_report("aabb_merge",b,COUNT,merged.max.x)
    area:f32
    b={}
    for bench_round(&b) {
        #no_bounds_check for i in 0..<COUNT-1 {area+=aabb_surface_area(aabb_merge(boxes[i],boxes[i+1]))}
    }
    bench_report("aabb_merge + aabb_surface_area (SAH cost)",b,COUNT,area)
    m:=transform_matrix({{1,2,3},quat_from_euler({0.3,0.7,0.2}),{1,2,1}})
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {sink+=aabb_transform(box,m).max.x}
    }
    bench_report("aabb_transform",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for box in boxes {sink+=closest_point_triangle({0,0,0},{box.min,box.max,box.min+{6,0,0}}).x}
    }
    bench_report("closest_point_triangle",b,COUNT,sink)
    b={}
    for bench_round(&b) {
        #no_bounds_check for i in 0..<COUNT-1 {
            p,_,_,_:=closest_segment_segment({boxes[i].min,boxes[i].max},{boxes[i+1].min,boxes[i+1].max})
            sink+=p.x
        }
    }
    bench_report("closest_segment_segment",b,COUNT,sink)
}

@(test)
bench_noise_and_random :: proc(t:^testing.T) {
    COUNT :: 200000
    rng:=rng_make(3)
    points:=make([]Vec3,COUNT);defer delete(points)
    for &point in points {point=random_in_sphere(&rng)*100}
    sink:f32
    b:Bench
    for bench_round(&b) {for p in points {sink+=noise_value3(p)}}
    bench_report("noise_value3",b,COUNT,sink)
    b={}
    for bench_round(&b) {for p in points {sink+=noise_perlin2(p.xy)}}
    bench_report("noise_perlin2",b,COUNT,sink)
    b={}
    for bench_round(&b) {for p in points {sink+=noise_perlin3(p)}}
    bench_report("noise_perlin3",b,COUNT,sink)
    b={}
    for bench_round(&b) {for p in points {sink+=noise_simplex2(p.xy)}}
    bench_report("noise_simplex2 (core OpenSimplex2)",b,COUNT,sink)
    b={}
    for bench_round(&b) {for p in points {sink+=noise_simplex3(p)}}
    bench_report("noise_simplex3 (core OpenSimplex2)",b,COUNT,sink)
    b={}
    for bench_round(&b) {for p in points {near,_:=noise_worley3(p);sink+=near}}
    bench_report("noise_worley3",b,COUNT,sink)
    b={}
    for bench_round(&b) {for p in points {sink+=noise_fbm3(p)}}
    bench_report("noise_fbm3, 5 octaves of Perlin",b,COUNT,sink)
    b={}
    for bench_round(&b) {for p in points {sink+=noise_curl3(p).x}}
    bench_report("noise_curl3",b,COUNT,sink)
    b={}
    for bench_round(&b) {for _ in 0..<COUNT {sink+=random_f32(&rng)}}
    bench_report("random_f32",b,COUNT,sink)
    b={}
    for bench_round(&b) {for _ in 0..<COUNT {sink+=f32(random_below(&rng,1000))}}
    bench_report("random_below",b,COUNT,sink)
    b={}
    for bench_round(&b) {for _ in 0..<COUNT {sink+=random_unit_vec3(&rng).x}}
    bench_report("random_unit_vec3",b,COUNT,sink)
    b={}
    for bench_round(&b) {for _ in 0..<COUNT {sink+=random_gaussian(&rng)}}
    bench_report("random_gaussian",b,COUNT,sink)
    b={}
    for bench_round(&b) {for _ in 0..<COUNT {sink+=random_in_cone(&rng,{0,1,0},0.5).x}}
    bench_report("random_in_cone",b,COUNT,sink)
}

@(test)
bench_packing_and_curves :: proc(t:^testing.T) {
    COUNT :: 200000
    rng:=rng_make(4)
    normals:=make([]Vec3,COUNT);defer delete(normals)
    rotations:=make([]Quat,COUNT);defer delete(rotations)
    for &normal in normals {normal=random_unit_vec3(&rng)}
    for &rotation in rotations {rotation=random_quat(&rng)}
    sink:f32
    packed:u32
    b:Bench
    for bench_round(&b) {for n in normals {packed~=normal_pack(n)}}
    bench_report("normal_pack",b,COUNT,f32(packed&0xff))
    b={}
    for bench_round(&b) {for _,i in normals {sink+=normal_unpack(u32(i)*2654435761).x}}
    bench_report("normal_unpack",b,COUNT,sink)
    wide:u64
    b={}
    for bench_round(&b) {for q in rotations {wide~=quat_pack(q)}}
    bench_report("quat_pack",b,COUNT,f32(wide&0xff))
    b={}
    for bench_round(&b) {for _,i in rotations {sink+=quat_unpack(u64(i)*2654435761&0xffffffff).w}}
    bench_report("quat_unpack",b,COUNT,sink)
    b={}
    for bench_round(&b) {for n in normals {sink+=linear_to_srgb(linalg.abs(n)).x}}
    bench_report("linear_to_srgb (rgb)",b,COUNT,sink)
    b={}
    for bench_round(&b) {for n in normals {sink+=linear_to_oklab(linalg.abs(n)).x}}
    bench_report("linear_to_oklab",b,COUNT,sink)
    b={}
    for bench_round(&b) {for n,i in normals {sink+=ease_apply(Ease(i%31),abs(n.x))}}
    bench_report("ease_apply, every curve in turn",b,COUNT,sink)
    b={}
    for bench_round(&b) {for i in 0..<COUNT-3 {sink+=catmull_rom(normals[i],normals[i+1],normals[i+2],normals[i+3],0.4).x}}
    bench_report("catmull_rom (Vec3)",b,COUNT,sink)
    value,velocity:=Vec3{},Vec3{}
    b={}
    for bench_round(&b) {for n in normals {value,velocity=spring_critical(value,velocity,n,8,1.0/60)}}
    bench_report("spring_critical (Vec3)",b,COUNT,value.x)
}

}
