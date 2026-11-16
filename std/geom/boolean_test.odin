package geom

import "base:runtime"
import "core:testing"
import "core:fmt"
import "core:math"
import "core:time"
import "mirai:std/base"
import mm "mirai:std/math"

@(private) Boolean_Rig :: struct {a,b,out,again:Mesh_Buffer}
@(private) boolean_rig_init :: proc(r:^Boolean_Rig) {for p in ([]^Mesh_Buffer{&r.a,&r.b,&r.out,&r.again}) {mesh_buffer_init(p)}}
@(private) boolean_rig_destroy :: proc(r:^Boolean_Rig) {for p in ([]^Mesh_Buffer{&r.a,&r.b,&r.out,&r.again}) {mesh_buffer_destroy(p)}}
@(private) boolean_box :: proc(out:^Mesh_Buffer,size,center:Vec3) {
    mesh_buffer_clear(out);cube_build(out,size)
    for &p in out.positions {p+=center}
}
@(private) boolean_expect :: proc(t:^testing.T,r:^Boolean_Rig,op:Boolean_Op,volume:f32,loc:=#caller_location) {
    e:=mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),op,&r.out)
    testing.expect_value(t,e,Boolean_Error.None,loc=loc)
    if e!=.None {return}
    if volume>0 {expect_closed(t,&r.out,"boolean",loc=loc)} else {testing.expect_value(t,len(r.out.indices),0,loc=loc)}
    actual:=buffer_volume(&r.out)
    testing.expectf(t,abs(actual-volume)<max(abs(volume)*1e-5,1e-5),"%v volume %g != %g",op,actual,volume,loc=loc)
}

@(test)
boolean_boxes_cover_overlap_containment_disjoint_equal_and_face_contact :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_box(&r.a,{2,2,2},{})
    boolean_box(&r.b,{2,2,2},{1,0,0})
    boolean_expect(t,&r,.Union,12);boolean_expect(t,&r,.Subtract,4);boolean_expect(t,&r,.Intersect,4)
    boolean_box(&r.b,{1,1,1},{})
    boolean_expect(t,&r,.Union,8);boolean_expect(t,&r,.Subtract,7);boolean_expect(t,&r,.Intersect,1)
    boolean_box(&r.b,{2,2,2},{3,0,0})
    boolean_expect(t,&r,.Union,16);boolean_expect(t,&r,.Subtract,8);boolean_expect(t,&r,.Intersect,0)
    boolean_box(&r.b,{2,2,2},{})
    boolean_expect(t,&r,.Union,8);boolean_expect(t,&r,.Subtract,0);boolean_expect(t,&r,.Intersect,8)
    boolean_box(&r.b,{2,2,2},{2,0,0})
    boolean_expect(t,&r,.Union,16);boolean_expect(t,&r,.Subtract,8);boolean_expect(t,&r,.Intersect,0)
}

@(test)
boolean_cave_keeps_its_roof_and_interpolates_attributes :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_box(&r.a,{8,6,8},{0,-3,0})
    boolean_box(&r.b,{2,2,6},{0,-3,3})
    for p in r.a.positions {append(&r.a.colors,Vec4{p.x,p.y,p.z,1})}
    for p in r.b.positions {append(&r.b.colors,Vec4{p.x,p.y,p.z,1})}
    for _ in 0..<len(r.a.indices)/3 {append(&r.a.materials,2)}
    for _ in 0..<len(r.b.indices)/3 {append(&r.b.materials,7)}
    boolean_expect(t,&r,.Subtract,368)
    found_roof,found_cap:=false,false
    for p,i in r.out.positions {
        if p.y==0 {found_roof=true}
        expected:=Vec4{p.x,p.y,p.z,1}
        for axis in 0..<4 {testing.expectf(t,abs(expected[axis]-r.out.colors[i][axis])<1e-5,"interpolated attribute changed")}
    }
    for m in r.out.materials {if m==7 {found_cap=true};testing.expect(t,m==2 || m==7)}
    testing.expect(t,found_roof && found_cap)
}

@(test)
boolean_curved_intersections_are_closed_repeatable_and_reusable :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_box(&r.a,{3,3,3},{})
    icosphere_build(&r.b,1.25,1)
    for &p in r.b.positions {p+=Vec3{0.75,0.2,0.35}}
    for op in Boolean_Op {
        e:=mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),op,&r.out)
        testing.expect_value(t,e,Boolean_Error.None)
        if e!=.None {continue}
        expect_closed(t,&r.out,"curved boolean")
        testing.expect_value(t,mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),op,&r.again),Boolean_Error.None)
        testing.expect_value(t,len(r.out.positions),len(r.again.positions))
        testing.expect_value(t,len(r.out.indices),len(r.again.indices))
        for p,i in r.out.positions {testing.expect_value(t,p,r.again.positions[i]);testing.expect_value(t,r.out.normals[i],r.again.normals[i]);testing.expect_value(t,r.out.uvs[i],r.again.uvs[i])}
        for index,i in r.out.indices {testing.expect_value(t,index,r.again.indices[i])}
        pointer:=raw_data(r.out.positions)
        testing.expect_value(t,mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),op,&r.out),Boolean_Error.None)
        testing.expect_value(t,raw_data(r.out.positions),pointer)
    }
}

@(test)
boolean_rejects_open_degenerate_invalid_inputs_and_capacity_without_partial_output :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_box(&r.a,{2,2,2},{})
    boolean_box(&r.b,{2,2,2},{1,0,0})
    a,b:=mesh_buffer_view(&r.a),mesh_buffer_view(&r.b)
    testing.expect_value(t,mesh_boolean(a,b,.Union,&r.out,{max_fragments=1}),Boolean_Error.Capacity)
    testing.expect_value(t,mesh_boolean(a,b,.Union,&r.out,{max_vertices=1}),Boolean_Error.Capacity)
    testing.expect_value(t,mesh_boolean(a,b,.Union,&r.out,{max_depth=1}),Boolean_Error.Capacity)
    testing.expect_value(t,mesh_boolean(a,b,.Union,&r.out,{tolerance=-1}),Boolean_Error.Invalid_Settings)
    testing.expect_value(t,mesh_boolean(a,b,Boolean_Op(99),&r.out),Boolean_Error.Invalid_Settings)
    testing.expect_value(t,mesh_boolean(a,b,.Union,nil),Boolean_Error.Invalid_Settings)
    open:=a;open.indices=open.indices[:len(open.indices)-3]
    testing.expect_value(t,mesh_boolean(open,b,.Union,&r.out),Boolean_Error.Not_Closed)
    indices:=[3]u32{0,0,0};invalid:=Mesh{positions=a.positions,indices=indices[:]}
    testing.expect_value(t,mesh_boolean(invalid,b,.Union,&r.out),Boolean_Error.Invalid_Mesh)
    indices[1]=max(u32)
    testing.expect_value(t,mesh_boolean(invalid,b,.Union,&r.out),Boolean_Error.Invalid_Mesh)
    r.a.positions[0].x=f32(0h7fc00000)
    testing.expect_value(t,mesh_boolean(a,b,.Union,&r.out),Boolean_Error.Invalid_Mesh)
    testing.expect_value(t,len(r.out.positions),0)
    boolean_box(&r.a,{2,2,2},{})
    empty:Mesh_Buffer;mesh_buffer_init(&empty,runtime.nil_allocator());defer mesh_buffer_destroy(&empty)
    testing.expect_value(t,mesh_boolean(mesh_buffer_view(&r.a),b,.Union,&empty),Boolean_Error.Out_Of_Memory)
    testing.expect_value(t,len(empty.indices),0)
    saved:=context.temp_allocator
    context.temp_allocator=runtime.nil_allocator()
    e:=mesh_boolean(mesh_buffer_view(&r.a),b,.Union,&r.out)
    context.temp_allocator=saved
    testing.expect_value(t,e,Boolean_Error.Out_Of_Memory)
    testing.expect_value(t,len(r.out.indices),0)
}

@(test)
boolean_empty_operands_and_small_large_coordinates_are_defined :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_box(&r.a,{2,2,2},{})
    boolean_expect(t,&r,.Union,8);boolean_expect(t,&r,.Subtract,8);boolean_expect(t,&r,.Intersect,0)
    for scale in ([5]f32{1e-30,1e-8,1,1e8,1e30}) {
        boolean_box(&r.a,Vec3{2,2,2}*scale,{})
        boolean_box(&r.b,Vec3{2,2,2}*scale,Vec3{1,0,0}*scale)
        for op in Boolean_Op {
            e:=mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),op,&r.out)
            testing.expect_value(t,e,Boolean_Error.None)
            if e==.None {expect_closed(t,&r.out,"scaled boolean")}
        }
    }
}

@(private) Boolean_Failing_Allocator :: struct {backing:runtime.Allocator,left:int}
@(private) boolean_failing_allocate :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    a:=cast(^Boolean_Failing_Allocator)data
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if a.left==0 {return nil,.Out_Of_Memory}
        a.left-=1
    }
    return a.backing.procedure(a.backing.data,mode,size,alignment,old_memory,old_size,loc)
}

@(test)
boolean_every_allocation_failure_clears_output_and_frees_custom_temporary_memory :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_box(&r.a,{2,2,2},{})
    boolean_box(&r.b,{2,2,2},{1,0.25,0.25})
    complete:=false
    for limit in 0..<1024 {
        fail:=Boolean_Failing_Allocator{context.allocator,limit}
        allocator:=runtime.Allocator{data=&fail,procedure=boolean_failing_allocate}
        output:Mesh_Buffer;mesh_buffer_init(&output,allocator)
        saved:=context.temp_allocator;context.temp_allocator=allocator
        e:=mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),.Subtract,&output)
        context.temp_allocator=saved
        if e==.None {complete=true;expect_closed(t,&output,"custom temporary allocator")} else {
            testing.expect_value(t,e,Boolean_Error.Out_Of_Memory)
            testing.expect_value(t,len(output.indices),0)
            testing.expect_value(t,len(output.positions),0)
        }
        mesh_buffer_destroy(&output)
        if complete {break}
    }
    testing.expect(t,complete)
}

@(test)
boolean_finite_extreme_attributes_do_not_overflow_interpolation :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_box(&r.a,{2,2,2},{})
    boolean_box(&r.b,{2,2,2},{1,0.25,0.25})
    for mesh in ([]^Mesh_Buffer{&r.a,&r.b}) {
        for p in mesh.positions {append(&mesh.colors,Vec4{3e38*(1 if p.x>0 else -1),3e38,0,1})}
        for &n in mesh.normals {n*=3e38}
    }
    testing.expect_value(t,mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),.Subtract,&r.out),Boolean_Error.None)
    for c in r.out.colors {for v in c {testing.expect(t,v-v==0)}}
    for n in r.out.normals {testing.expectf(t,ddot(dvec(n),dvec(n))>0.99,"normal overflowed")}
}

@(test)
boolean_rotated_solids_conserve_volume_and_repeated_cuts_remain_closed :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    rng:=base.rng_make(59137)
    for iteration in 0..<32 {
        boolean_box(&r.a,{3,2,4},{})
        boolean_box(&r.b,{2,3,2},mm.random_in_sphere(&rng)*1.5)
        s,c:=turn_sincos(f64(iteration)*0.037)
        for &p in r.b.positions {p={f32(f64(p.x)*c-f64(p.z)*s),p.y,f32(f64(p.x)*s+f64(p.z)*c)}}
        for &n in r.b.normals {n={f32(f64(n.x)*c-f64(n.z)*s),n.y,f32(f64(n.x)*s+f64(n.z)*c)}}
        volumes:[Boolean_Op]f32
        for op in Boolean_Op {
            e:=mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),op,&r.out)
            testing.expectf(t,e==.None,"rotation %d %v: %v",iteration,op,e)
            if e!=.None {continue}
            expect_closed(t,&r.out,"rotated boolean")
            volumes[op]=buffer_volume(&r.out)
        }
        testing.expectf(t,abs(volumes[.Union]+volumes[.Intersect]-36)<2e-4,"union/intersection lost volume")
        testing.expectf(t,abs(volumes[.Subtract]+volumes[.Intersect]-24)<2e-4,"subtraction lost volume")
    }
    boolean_box(&r.a,{8,6,8},{0,-3,0})
    for iteration in 0..<4 {
        mesh_buffer_clear(&r.b);icosphere_build(&r.b,1.25,1)
        for &p in r.b.positions {p+=Vec3{0,-3,4-f32(iteration)*1.2}}
        e:=mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),.Subtract,&r.out)
        testing.expectf(t,e==.None,"repeated cave cut %d: %v",iteration,e)
        if e!=.None {break}
        expect_closed(t,&r.out,"repeated cave cut")
        r.a,r.out=r.out,r.a
    }
}

@(test)
bench_boolean :: proc(t:^testing.T) {
    when !GEOM_BENCH {return} else {
        r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
        for n in ([6]Vec3{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) {
            u:=Vec3{n.y,n.z,n.x};v:=fvec(dcross(dvec(n),dvec(u)))
            for y in 0..<32 {for x in 0..<32 {
                a:=n*16+u*(f32(x)-16)+v*(f32(y)-16)
                test_quad(&r.a,a,a+u,a+u+v,a+v)
            }}
        }
        icosphere_build(&r.b,2,1)
        for &p in r.b.positions {p+=Vec3{0,16,0}}
        a,b:=mesh_buffer_view(&r.a),mesh_buffer_view(&r.b)
        testing.expect_value(t,mesh_boolean(a,b,.Subtract,&r.out),Boolean_Error.None)
        start:=time.tick_now()
        runs:=10
        for _ in 0..<runs {testing.expect_value(t,mesh_boolean(a,b,.Subtract,&r.out),Boolean_Error.None)}
        bench_report("boolean grid box 12288 triangles minus sphere 80",runs,time.tick_since(start),fmt.tprintf("%d output triangles",len(r.out.indices)/3))
    }
}

// A block of ground whose top rolls, like sculpted terrain: the planes of its
// tilted faces must not slice it far from the shape that cuts it.
@(private) boolean_ground :: proc(out:^Mesh_Buffer,cells:int,size,depth:f32) {
    mesh_buffer_clear(out)
    n:=cells+1
    at :: proc(x,z,n:int,size:f32) -> Vec3 {
        u,v:=(f32(x)/f32(n-1)-0.5)*size,(f32(z)/f32(n-1)-0.5)*size
        return {u,0.35*f32(math.sin(f64(u)*0.7))*f32(math.cos(f64(v)*0.45))+0.25*f32(math.sin(f64(u)*0.3+f64(v)*0.8)),v}
    }
    quad :: proc(out:^Mesh_Buffer,a,b,c,d:Vec3) {
        first:=u32(len(out.positions))
        append(&out.positions,a,b,c,d)
        append(&out.indices,first,first+1,first+2,first,first+2,first+3)
    }
    floor :: proc(p:Vec3,depth:f32) -> Vec3 {return {p.x,-depth,p.z}}
    for z in 0..<cells {for x in 0..<cells {
        a,b,c,d:=at(x,z,n,size),at(x,z+1,n,size),at(x+1,z+1,n,size),at(x+1,z,n,size)
        quad(out,a,b,c,d)
        quad(out,floor(a,depth),floor(d,depth),floor(c,depth),floor(b,depth))
    }}
    for i in 0..<cells {
        quad(out,at(i,0,n,size),at(i+1,0,n,size),floor(at(i+1,0,n,size),depth),floor(at(i,0,n,size),depth))
        quad(out,at(i+1,cells,n,size),at(i,cells,n,size),floor(at(i,cells,n,size),depth),floor(at(i+1,cells,n,size),depth))
        quad(out,at(0,i+1,n,size),at(0,i,n,size),floor(at(0,i,n,size),depth),floor(at(0,i+1,n,size),depth))
        quad(out,at(cells,i,n,size),at(cells,i+1,n,size),floor(at(cells,i+1,n,size),depth),floor(at(cells,i,n,size),depth))
    }
}

@(test)
boolean_shapes_cut_rolling_ground_without_slicing_it_elsewhere :: proc(t:^testing.T) {
    r:Boolean_Rig;boolean_rig_init(&r);defer boolean_rig_destroy(&r)
    boolean_ground(&r.a,64,64,8)
    expect_closed(t,&r.a,"ground")
    ground:=buffer_volume(&r.a)
    for center in ([4]Vec3{{3.55,0.2,7.74},{-11.3,0.1,-4.2},{20.7,-0.3,15.1},{0.4,0.25,-0.6}}) {
        mesh_buffer_clear(&r.b);sphere_build(&r.b,4.3,16,8)
        for &p in r.b.positions {p+=center}
        sphere:=buffer_volume(&r.b)
        for op in ([2]Boolean_Op{.Subtract,.Union}) {
            e:=mesh_boolean(mesh_buffer_view(&r.a),mesh_buffer_view(&r.b),op,&r.out)
            testing.expectf(t,e==.None,"%v at %v: %v",op,center,e)
            if e!=.None {continue}
            expect_closed(t,&r.out,"boolean")
            change:=buffer_volume(&r.out)-ground
            // About half the sphere lies under the ground at its center.
            testing.expectf(t,abs(abs(change)-sphere*0.5)<sphere*0.12,"%v at %v changes %g of a sphere of %g",op,center,change,sphere)
            testing.expect(t,len(r.out.indices)<len(r.a.indices)*3/2,"only the faces near the sphere are cut")
        }
    }
}
