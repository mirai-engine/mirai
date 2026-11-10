package shapes

import "base:runtime"
import "core:testing"
import "mirai:std/geom"

// An allocator that serves `remaining` requests of its owner and refuses the rest.
@(private="file")
Memory_Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
memory_limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Memory_Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// What collides of a static shape, from its mesh, with the memory ending at
// each request in turn: it is refused, and with memory enough it is made
// whole. A quad and a strip of two quads.
@(test)
static_collision_without_memory_is_refused :: proc(t:^testing.T) {
    owner:=context.allocator
    limit:=Memory_Limit{owner=owner}
    Case :: struct {positions:[]geom.Vec3,indices:[]u32}
    cases:=[]Case{
        {{{0,0,0},{1,0,0},{1,1,0},{0,1,0}},{0,1,2,0,2,3}},
        {{{0,0,0},{1,0,0},{1,1,0},{0,1,0},{2,0,0},{2,1,0}},{0,1,2,0,2,3,1,4,5,1,5,2}},
    }
    for c,at in cases {
        g:Shape_Geometry
        geom.mesh_buffer_init(&g.mesh)
        append(&g.mesh.positions,..c.positions)
        append(&g.mesh.indices,..c.indices)
        made,refused:=false,false
        for served in 0..<16 {
            geom.mesh_buffer_clear(&g.collision)
            limit.remaining=served
            context.allocator={memory_limit_proc,&limit}
            made=static_collision(&g)
            context.allocator=owner
            limit.remaining=max(int)
            if made {break}
            refused=true
        }
        testing.expectf(t,made && refused,"case %d: refused without memory, and made with it",at)
        testing.expectf(t,len(g.collision.indices)==len(c.indices) && len(g.disabled_edges)==len(c.indices)/3,"case %d: %d indices and %d triangles with edges",at,len(g.collision.indices),len(g.disabled_edges))
        shape_geometry_destroy(&g)
    }
}

// A stroke swept to its next point with the memory ending at each request in
// turn: a point that finds none leaves the area as it was, and with memory
// enough the brush is swept to it.
@(test)
a_stroke_without_memory_keeps_its_area :: proc(t:^testing.T) {
    limit:=Memory_Limit{owner=context.allocator,remaining=max(int)}
    limited:=runtime.Allocator{memory_limit_proc,&limit}
    square:=[]geom.Vec2{{-0.5,-0.5},{0.5,-0.5},{0.5,0.5},{-0.5,0.5}}
    swept,refused:=false,false
    for served:=0;!swept && served<256;served+=1 {
        st:Shape_Stroke
        if !testing.expect_value(t,shape_stroke_begin(&st,square,0.05,limited),Shape_Error.None) || !testing.expect(t,shape_stroke_to(&st,{0,0})) {return}
        limit.remaining=served
        swept=shape_stroke_to(&st,{3,1})
        limit.remaining=max(int)
        points,loops:=shape_stroke_area(&st)
        if swept {
            testing.expectf(t,len(loops)==1 && len(points)>len(square),"swept to %d points in %d loops",len(points),len(loops))
        } else {
            refused=true
            testing.expectf(t,len(loops)==1 && len(points)==len(square),"with %d requests served: the area that was refused has %d points in %d loops",served,len(points),len(loops))
        }
        shape_stroke_destroy(&st)
    }
    testing.expect(t,swept && refused,"refused without memory, and swept with it")
}
