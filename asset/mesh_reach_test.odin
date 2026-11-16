package asset

import "core:math"
import "core:math/linalg"
import "core:testing"

// A grid of quads moved and scaled to span scale on each side of center, with
// its uvs moved by uv_offset.
@(private="file")
reach_grid :: proc(scale:f32,center:[3]f32,uv_offset:[2]f32) -> (vertices:[]Vertex,indices:[]u32) {
    vertices,indices=test_grid(640,context.temp_allocator)
    for &v in vertices {
        v.position=center+(v.position-{32,0,5})*(scale/32)
        v.position.y=v.position.x*0.25
        v.uv+=uv_offset
    }
    return
}

@(private="file")
reach_close :: proc(t:^testing.T,g:Mesh_Geometry,vertices:[]Vertex,indices:[]u32,loc:=#caller_location) {
    // Every vertex of level 0 decodes within a step of one of the source.
    for c in g.clusters[:g.levels[0].cluster_count] {
        for local in 0..<cluster_vertex_count(c) {
            v:=cluster_vertex(g,c,local)
            testing.expect(t,finite(v.position.x,v.position.y,v.position.z),loc=loc)
            best,uv_best:=f32(max(f32)),f32(max(f32))
            for s in vertices {
                d:=linalg.abs(v.position-s.position)
                best=min(best,max(d.x,d.y,d.z))
                e:=linalg.abs(v.uv-s.uv)
                uv_best=min(uv_best,max(e.x,e.y))
            }
            testing.expectf(t,best<=g.position_step,"vertex %v is %v from the source, step %v",v.position,best,g.position_step,loc=loc)
            testing.expectf(t,uv_best<=g.uv_step,"uv %v is %v from the source, step %v",v.uv,uv_best,g.uv_step,loc=loc)
        }
    }
}

@(test)
mesh_build_encodes_any_finite_extent :: proc(t:^testing.T) {
    Case :: struct {scale:f32,center:[3]f32,uv:[2]f32}
    cases:=[]Case{
        {1,{0,0,0},{0,0}},
        {2e5,{0,0,0},{0,0}},             // a sky sphere of hundreds of kilometers
        {0.01,{3e6,-2e6,1e6},{0,0}},     // small and far from its origin
        {3e38,{0,0,0},{0,0}},            // the widest a f32 holds
        {1e37,{0,0,0},{0,0}},
        {1e30,{0,0,0},{0,0}},
        {1e20,{0,0,0},{0,0}},
        {1e15,{0,0,0},{0,0}},
        {1e10,{0,0,0},{0,0}},
        {1,{0,0,0},{1e7,-3e7}},          // uvs far from 0
        {1,{0,0,0},{3e38,-3e38}},
    }
    for c in cases {
        vertices,indices:=reach_grid(c.scale,c.center,c.uv)
        g,dag:Mesh_Geometry
        testing.expectf(t,mesh_build({vertices=vertices},indices,nil,&g,context.temp_allocator),"%v",c)
        if len(g.clusters)>0 {reach_close(t,g,vertices,indices)}
        testing.expectf(t,mesh_build_dag({vertices=vertices},indices,&dag,context.temp_allocator),"dag %v",c)
        if len(dag.clusters)>0 {reach_close(t,dag,vertices,indices)}
        free_all(context.temp_allocator)
    }
}

@(test)
mesh_build_refuses_what_is_not_a_number :: proc(t:^testing.T) {
    nan:=math.nan_f32()
    for field in 0..<4 {
        vertices,indices:=reach_grid(1,{},{})
        switch field {
        case 0: vertices[7].position.y=nan
        case 1: vertices[7].uv.x=nan
        case 2: vertices[7].uv1.y=math.inf_f32(1)
        case 3: vertices[7].position.z=math.inf_f32(-1)
        }
        g:Mesh_Geometry
        testing.expect(t,!mesh_build({vertices=vertices,flags={.Has_Uv1}},indices,nil,&g,context.temp_allocator))
        testing.expect(t,!mesh_build_dag({vertices=vertices,flags={.Has_Uv1}},indices,&g,context.temp_allocator))
        free_all(context.temp_allocator)
    }
}
