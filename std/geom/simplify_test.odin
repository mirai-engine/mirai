package geom

import "core:testing"

// A primitive welded by position: a closed surface with one vertex per point.
@(private) welded :: proc(out:^Mesh_Buffer,build:proc(out:^Mesh_Buffer)) {
    raw:Mesh_Buffer
    mesh_buffer_init(&raw)
    defer mesh_buffer_destroy(&raw)
    build(&raw)
    mesh_weld({positions=raw.positions[:],indices=raw.indices[:]},0,out)
}

// Simplifies into a slice of the temporary allocator.
@(private="file")
simplified :: proc(indices:[]u32,positions:[]Vec3,target_triangles:int,target_error:f32,options:Simplify_Options={},attributes:[]f32=nil,weights:[]f32=nil,vertex_lock:[]Simplify_Vertex=nil) -> (out:[]u32,error:f32,failed:Simplify_Error) {
    destination:=make([]u32,len(indices),context.temp_allocator)
    result:Simplify_Result
    result,failed=simplify(destination,indices,positions,target_triangles*3,target_error,options,attributes,weights,vertex_lock)
    return destination[:result.index_count],result.result_error,failed
}

@(private="file")
references :: proc(indices:[]u32,v:u32) -> bool {
    for index in indices {if index==v {return true}}
    return false
}

@(test)
simplify_empties_a_flat_sheet_and_keeps_its_outline :: proc(t:^testing.T) {
    sheet:Mesh_Buffer
    mesh_buffer_init(&sheet)
    defer mesh_buffer_destroy(&sheet)
    plane_build(&sheet,{4,2},16,8)
    testing.expect_value(t,len(sheet.indices)/3,256)
    // Within an error far below a cell, which nothing flat costs: the inside goes and the outline stays.
    out,error,failed:=simplified(sheet.indices[:],sheet.positions[:],0,1e-3,{.Error_Absolute})
    testing.expect_value(t,failed,Simplify_Error.None)
    testing.expectf(t,len(out)/3>=2 && len(out)/3<=8,"%d triangles are left of a flat sheet",len(out)/3)
    testing.expect(t,error<=1e-3)
    testing.expect(t,abs(mesh_area(sheet.positions[:],out)-8)<1e-5,"the sheet covers what it covered")
    lo,hi:=Vec3{max(f32),max(f32),max(f32)},Vec3{-max(f32),-max(f32),-max(f32)}
    for index in out {
        p:=sheet.positions[index]
        lo,hi={min(lo.x,p.x),min(lo.y,p.y),min(lo.z,p.z)},{max(hi.x,p.x),max(hi.y,p.y),max(hi.z,p.z)}
    }
    source_lo,source_hi:=mesh_bounds(sheet.positions[:])
    testing.expect(t,lo==source_lo && hi==source_hi)
    // The relative error is a share of the extent of the sheet, 4.
    relative,relative_error,_:=simplified(sheet.indices[:],sheet.positions[:],0,1e-3/4)
    testing.expect(t,len(relative)==len(out) && relative_error<=1e-3/4)
    testing.expect_value(t,simplify_scale(sheet.positions[:]),4)
}

@(test)
simplify_keeps_a_closed_surface_closed_and_close_to_its_shape :: proc(t:^testing.T) {
    ball:Mesh_Buffer
    mesh_buffer_init(&ball)
    defer mesh_buffer_destroy(&ball)
    welded(&ball,proc(out:^Mesh_Buffer) {icosphere_build(out,1,3)})
    positions:=ball.positions[:]
    testing.expect_value(t,len(ball.indices)/3,1280)
    volume:=mesh_volume(positions,ball.indices[:])
    worst:=f32(0)
    for target in ([]int{640,200,40}) {
        out,error,failed:=simplified(ball.indices[:],positions,target,max(f32))
        testing.expect_value(t,failed,Simplify_Error.None)
        testing.expectf(t,len(out)/3<=target && len(out)/3>=target*9/10,"%d triangles for a target of %d",len(out)/3,target)
        testing.expect(t,mesh_is_closed(positions,out),"the surface is still a closed two-manifold")
        kept:=mesh_volume(positions,out)
        // No vertex moves, so the surface only loses what its flatter faces cut off.
        testing.expectf(t,kept<=volume && kept>volume*(target>=200?0.9:0.5),"%d triangles hold %v of %v",target,kept,volume)
        testing.expect(t,error>worst,"fewer triangles cost more")
        worst=error
    }
    // The error asked for bounds how far the surface moves: nothing collapses under the first cost.
    still,_,_:=simplified(ball.indices[:],positions,0,1e-4,{.Error_Absolute})
    testing.expect_value(t,len(still)/3,1280)
    some,some_error,_:=simplified(ball.indices[:],positions,0,0.05,{.Error_Absolute})
    testing.expect(t,len(some)/3<1280 && len(some)/3>40 && some_error<=0.05,"a small error allows some collapses")
    testing.expect(t,mesh_is_closed(positions,some))
}

@(test)
simplify_reduces_a_tessellated_box_to_its_faces_without_moving_them :: proc(t:^testing.T) {
    // A box of 6 x 6 x 6 cells: flat faces, straight edges, eight corners.
    N :: 6
    grid:Mesh_Buffer
    mesh_buffer_init(&grid)
    defer mesh_buffer_destroy(&grid)
    index:=make(map[[3]int]u32,context.temp_allocator)
    vertex :: proc(grid:^Mesh_Buffer,index:^map[[3]int]u32,p:[3]int) -> u32 {
        if found,ok:=index[p];ok {return found}
        index[p]=u32(len(grid.positions))
        append(&grid.positions,Vec3{f32(p.x),f32(p.y),f32(p.z)}/N)
        return index[p]
    }
    for axis in 0..<3 {
        u,v:=(axis+1)%3,(axis+2)%3
        for side in 0..<2 {
            for i in 0..<N {
                for j in 0..<N {
                    corner:[4][3]int
                    for k in 0..<4 {
                        corner[k][axis]=side*N
                        corner[k][u]=i+(k==1||k==2?1:0)
                        corner[k][v]=j+(k>=2?1:0)
                    }
                    a,b,c,d:=vertex(&grid,&index,corner[0]),vertex(&grid,&index,corner[1]),vertex(&grid,&index,corner[2]),vertex(&grid,&index,corner[3])
                    if side==1 {append(&grid.indices,a,b,c,a,c,d)} else {append(&grid.indices,a,c,b,a,d,c)}
                }
            }
        }
    }
    positions:=grid.positions[:]
    testing.expect(t,mesh_is_closed(positions,grid.indices[:]))
    out,error,_:=simplified(grid.indices[:],positions,0,1e-3,{.Error_Absolute})
    testing.expectf(t,len(out)/3<=16 && len(out)/3>=12,"%d of %d triangles are left",len(out)/3,len(grid.indices)/3)
    testing.expect(t,error<=1e-3)
    testing.expect(t,mesh_is_closed(positions,out))
    testing.expect(t,abs(mesh_volume(positions,out)-1)<1e-5,"no collapse moved a face")
}

// A bumpy height grid of n by n cells, one unit each; the vertices with
// column below split take a copy of their own on the seam at column split,
// with another uv, for the triangles left of it (split 0: no seam).
@(private="file") bumpy_grid :: proc(out:^Mesh_Buffer,n,split:int) {
    height :: proc(x,z:int) -> f32 {return f32((x*7+z*13)%5)*0.05+f32((x*x+z)%3)*0.04+f32(x)*0.1}
    for z in 0..=n {for x in 0..=n {
        append(&out.positions,Vec3{f32(x),height(x,z),f32(z)})
        append(&out.uvs,Vec2{f32(x),f32(z)}/f32(n))
    }}
    copies:=make([]u32,n+1,context.temp_allocator)
    if split>0 {for z in 0..=n {
        copies[z]=u32(len(out.positions))
        append(&out.positions,out.positions[split+(n+1)*z])
        append(&out.uvs,Vec2{-1,f32(z)/f32(n)})
    }}
    for z in 0..<n {for x in 0..<n {
        v :: proc(x,z,n,split:int,copies:[]u32,left:bool) -> u32 {
            if split>0 && left && x==split {return copies[z]}
            return u32(x+(n+1)*z)
        }
        left:=x<split
        a,b,c,d:=v(x,z,n,split,copies,left),v(x+1,z,n,split,copies,left),v(x,z+1,n,split,copies,left),v(x+1,z+1,n,split,copies,left)
        append(&out.indices,a,c,b,b,c,d)
    }}
}

// Whether a triangle has corners on both sides of x.
@(private="file") triangles_span :: proc(positions:[]Vec3,indices:[]u32,x:int) -> bool {
    for j:=0;j<len(indices);j+=3 {
        below,above:=false,false
        for index in indices[j:j+3] {
            p:=positions[index].x
            below||=p<f32(x)
            above||=p>f32(x)
        }
        if below && above {return true}
    }
    return false
}

// The edges of a mesh by position used other than twice, outside the square of n cells.
@(private="file") inner_open_edges :: proc(positions:[]Vec3,indices:[]u32,n:int) -> (open:int) {
    weld:=make([]u32,len(positions),context.temp_allocator)
    positions_weld(positions,0,weld)
    uses:=make(map[[2]u32]int,context.temp_allocator)
    for t:=0;t<len(indices);t+=3 {for k in 0..<3 {
        a,b:=weld[indices[t+k]],weld[indices[t+(k+1)%3]]
        uses[{min(a,b),max(a,b)}]+=1
    }}
    side :: proc(p:Vec3,n:int) -> bool {return p.x==0 || p.z==0 || p.x==f32(n) || p.z==f32(n)}
    for edge,count in uses {
        if count==2 {continue}
        a,b:=positions[edge[0]],positions[edge[1]]
        if count==1 && side(a,n) && side(b,n) && (a.x==b.x || a.z==b.z) {continue}
        open+=1
    }
    return
}

@(test)
simplify_keeps_the_outline_of_a_seam_of_uvs :: proc(t:^testing.T) {
    N :: 24
    grid:Mesh_Buffer;mesh_buffer_init(&grid);defer mesh_buffer_destroy(&grid)
    bumpy_grid(&grid,N,N/2)
    positions:=grid.positions[:]
    seam_first:=u32((N+1)*(N+1))
    attributes:=make([]f32,len(grid.uvs)*2,context.temp_allocator)
    for uv,v in grid.uvs {attributes[v*2],attributes[v*2+1]=uv.x,uv.y}
    weights:=[]f32{1,1}
    target:=len(grid.indices)/3/6
    // Permissive moves the vertices of the seam along it, each with the wedges of its side.
    for options in ([]Simplify_Options{{},{.Permissive}}) {
        out,_,failed:=simplified(grid.indices[:],positions,target,max(f32),options,attributes,weights)
        testing.expect_value(t,failed,Simplify_Error.None)
        testing.expect(t,len(out)/3<=target)
        // The copies on the seam belong to the left triangles, the vertices at the seam column to the right ones.
        for j:=0;j<len(out);j+=3 {
            left:=positions[out[j]].x+positions[out[j+1]].x+positions[out[j+2]].x<3*N/2
            for index in out[j:j+3] {
                on_left:=index>=seam_first || positions[index].x<N/2
                on_right:=index<seam_first && positions[index].x>=N/2
                testing.expectf(t,left?on_left:on_right,"%v: a corner of a %s triangle takes a vertex of the other side",options,left?"left":"right")
            }
        }
        testing.expect_value(t,inner_open_edges(positions,out,N),0)
        testing.expectf(t,!triangles_span(positions,out,N/2),"%v: a triangle crosses the seam of uvs",options)
    }
}

@(test)
simplify_stops_at_places_of_many_wedges_that_permissive_moves_unless_protected :: proc(t:^testing.T) {
    // A flat grid whose cells have vertices of their own, with a uv each: every inner place has four wedges.
    N :: 16
    positions:=make([dynamic]Vec3,context.temp_allocator)
    attributes:=make([dynamic]f32,context.temp_allocator)
    indices:=make([dynamic]u32,context.temp_allocator)
    for z in 0..<N {for x in 0..<N {
        first:=u32(len(positions))
        for corner in ([4][2]int{{0,0},{1,0},{0,1},{1,1}}) {
            append(&positions,Vec3{f32(x+corner.x),0,f32(z+corner.y)})
            append(&attributes,f32(x*N+z),f32(corner.x))
        }
        append(&indices,first,first+2,first+1,first+1,first+2,first+3)
    }}
    weights:=[]f32{0.01,0.01}
    target:=len(indices)/3/8
    stuck,_,_:=simplified(indices[:],positions[:],target,max(f32),{},attributes[:],weights)
    testing.expectf(t,len(stuck)/3>len(indices)/3/2,"seams that meet stop the regular simplifier: %d of %d",len(stuck)/3,len(indices)/3)
    crossed,_,_:=simplified(indices[:],positions[:],target,max(f32),{.Permissive},attributes[:],weights)
    testing.expectf(t,len(crossed)/3<=target,"Permissive reaches the target: %d for %d",len(crossed)/3,target)
    testing.expect(t,abs(mesh_area(positions[:],crossed)-N*N)<1e-3,"and still covers the grid")
    protect:=make([]Simplify_Vertex,len(positions),context.temp_allocator)
    for &p in protect {p={.Protect}}
    protected,_,_:=simplified(indices[:],positions[:],target,max(f32),{.Permissive},attributes[:],weights,protect)
    testing.expect_value(t,len(protected),len(stuck))
}

@(test)
simplify_with_a_locked_border_keeps_the_edges_parts_share_at_any_level :: proc(t:^testing.T) {
    N :: 32
    parts:[2]Mesh_Buffer
    for &part in parts {mesh_buffer_init(&part)}
    defer for &part in parts {mesh_buffer_destroy(&part)}
    whole:Mesh_Buffer;mesh_buffer_init(&whole);defer mesh_buffer_destroy(&whole)
    bumpy_grid(&whole,N,0)
    // Two parts by the triangles of each half, each with its own vertices.
    for t:=0;t<len(whole.indices);t+=3 {
        center:=(whole.positions[whole.indices[t]]+whole.positions[whole.indices[t+1]]+whole.positions[whole.indices[t+2]])/3
        part:=&parts[center.x<N/2 ? 0 : 1]
        for k in 0..<3 {
            append(&part.indices,u32(len(part.positions)))
            append(&part.positions,whole.positions[whole.indices[t+k]])
        }
    }
    welded_parts:[2]Mesh_Buffer
    for &part in welded_parts {mesh_buffer_init(&part)}
    defer for &part in welded_parts {mesh_buffer_destroy(&part)}
    for &part,which in parts {mesh_weld(mesh_buffer_view(&part),0,&welded_parts[which])}
    for shares in ([?][2]int{{1,1},{8,2},{2,64},{64,64}}) {
        all:Mesh_Buffer;mesh_buffer_init(&all,context.temp_allocator)
        for which in 0..<2 {
            source:=&welded_parts[which]
            out,_,failed:=simplified(source.indices[:],source.positions[:],len(source.indices)/3/shares[which],max(f32),{.Lock_Border})
            testing.expect_value(t,failed,Simplify_Error.None)
            if shares[which]>2 {testing.expectf(t,len(out)/3<len(source.indices)/3/2,"a part with a locked border still simplifies: %d",len(out)/3)}
            // Every vertex of the border of the part is still used.
            border,kept:=0,0
            for p,v in source.positions {
                if p.x!=0 && p.z!=0 && p.z!=N && p.x!=N && p.x!=N/2 {continue}
                border+=1
                if references(out,u32(v)) {kept+=1}
            }
            testing.expect_value(t,kept,border)
            first:=u32(len(all.positions))
            append(&all.positions,..source.positions[:])
            for index in out {append(&all.indices,index+first)}
        }
        testing.expectf(t,inner_open_edges(all.positions[:],all.indices[:],N)==0,"parts simplified to 1/%v open an edge between them",shares)
    }
}

@(test)
simplify_keeps_locked_vertices_and_prunes_small_pieces :: proc(t:^testing.T) {
    ball:Mesh_Buffer
    mesh_buffer_init(&ball)
    defer mesh_buffer_destroy(&ball)
    welded(&ball,proc(out:^Mesh_Buffer) {icosphere_build(out,1,3)})
    lock:=make([]Simplify_Vertex,len(ball.positions),context.temp_allocator)
    for v in 0..<len(lock) {if v%7==0 {lock[v]={.Lock}}}
    out,_,_:=simplified(ball.indices[:],ball.positions[:],40,max(f32),{},nil,nil,lock)
    for v in 0..<len(lock) {
        if v%7==0 && !references(out,u32(v)) {testing.expectf(t,false,"locked vertex %d went away",v);break}
    }
    // A small ball beside a large one: Prune takes it away whole.
    pair:Mesh_Buffer
    mesh_buffer_init(&pair,context.temp_allocator)
    append(&pair.positions,..ball.positions[:])
    append(&pair.indices,..ball.indices[:])
    first:=u32(len(pair.positions))
    for p in ball.positions {append(&pair.positions,p*0.01+Vec3{3,0,0})}
    for index in ball.indices {append(&pair.indices,index+first)}
    target:=len(ball.indices)/3/4
    pruned,_,_:=simplified(pair.indices[:],pair.positions[:],target,max(f32),{.Prune})
    small:=0
    for index in pruned {if index>=first {small+=1}}
    testing.expect_value(t,small,0)
    testing.expect(t,len(pruned)/3<=target && len(pruned)/3>target/2)
    kept,_,_:=simplified(pair.indices[:],pair.positions[:],target,max(f32))
    small=0
    for index in kept {if index>=first {small+=1}}
    testing.expect(t,small>0,"without Prune each piece keeps its own triangles")
}

@(test)
simplify_of_a_sparse_part_is_that_of_the_part_alone :: proc(t:^testing.T) {
    torus:Mesh_Buffer
    mesh_buffer_init(&torus)
    defer mesh_buffer_destroy(&torus)
    welded(&torus,proc(out:^Mesh_Buffer) {torus_build(out,1,0.35,48,24)})
    // The triangles of one side of the torus, and that part with its own vertices in the order of first use.
    part:=make([dynamic]u32,context.temp_allocator)
    for j:=0;j<len(torus.indices);j+=3 {
        if torus.positions[torus.indices[j]].x>0.2 {append(&part,..torus.indices[j:j+3])}
    }
    alone:=make([dynamic]Vec3,context.temp_allocator)
    local:=make([dynamic]u32,context.temp_allocator)
    number:=make(map[u32]u32,context.temp_allocator)
    order:=make([dynamic]u32,context.temp_allocator)
    for index in part {
        at,found:=number[index]
        if !found {
            at=u32(len(alone))
            number[index]=at
            append(&alone,torus.positions[index])
            append(&order,index)
        }
        append(&local,at)
    }
    target:=len(part)/3/4
    sparse,sparse_error,_:=simplified(part[:],torus.positions[:],target,max(f32),{.Sparse,.Error_Absolute,.Lock_Border})
    dense,dense_error,_:=simplified(local[:],alone[:],target,max(f32),{.Error_Absolute,.Lock_Border})
    testing.expect(t,len(sparse)==len(dense) && sparse_error==dense_error)
    for index,at in dense {
        if order[index]!=sparse[at] {testing.expect(t,false,"the sparse result names other vertices");break}
    }
}

@(test)
simplify_refuses_broken_input_and_survives_degenerate_input :: proc(t:^testing.T) {
    out,_,failed:=simplified(nil,nil,4,0)
    testing.expect(t,failed==.None && len(out)==0)
    points:=[]Vec3{{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0.5,0.5,1}}
    destination:[16]u32
    _,failed=simplify(destination[:],{0,1,9},points,0,0)
    testing.expect_value(t,failed,Simplify_Error.Invalid_Mesh)
    _,failed=simplify(destination[:],{0,1},points,0,0)
    testing.expect_value(t,failed,Simplify_Error.Invalid_Mesh)
    _,failed=simplify(destination[:],{0,1,2},points,-3,0)
    testing.expect_value(t,failed,Simplify_Error.Invalid_Mesh)
    nan:=f32(0h7fc00000)
    _,failed=simplify(destination[:],{0,1,2},points,0,nan)
    testing.expect_value(t,failed,Simplify_Error.Invalid_Mesh)
    _,failed=simplify(destination[:2],{0,1,2},points,0,0)
    testing.expect_value(t,failed,Simplify_Error.Invalid_Mesh)
    _,failed=simplify(destination[:],{0,1,2},points,0,0,vertex_lock=make([]Simplify_Vertex,2,context.temp_allocator))
    testing.expect_value(t,failed,Simplify_Error.Invalid_Mesh)
    broken:=[]Vec3{{0,0,0},{1,0,0},{nan,0,0}}
    _,failed=simplify(destination[:],{0,1,2},broken,0,0)
    testing.expect_value(t,failed,Simplify_Error.Invalid_Mesh)
    _,failed=simplify(destination[:],{0,1,2},points,0,0,{},make([]f32,4,context.temp_allocator),[]f32{1})
    testing.expect_value(t,failed,Simplify_Error.Invalid_Attributes)
    _,failed=simplify(destination[:],{0,1,2},points,0,0,{},make([]f32,5,context.temp_allocator),[]f32{-1})
    testing.expect_value(t,failed,Simplify_Error.Invalid_Attributes)
    _,failed=simplify(destination[:],{0,1,2},points,0,0,{},make([]f32,5*33,context.temp_allocator),make([]f32,33,context.temp_allocator))
    testing.expect_value(t,failed,Simplify_Error.Invalid_Attributes)
    values:=[]f32{0,0,nan,0,0}
    _,failed=simplify(destination[:],{0,1,2},points,0,0,{},values,[]f32{1})
    testing.expect_value(t,failed,Simplify_Error.Invalid_Attributes)

    // Repeated corners, three triangles on one edge and every point in one place give valid indices.
    for indices in ([][]u32{{0,0,1,2,2,2,0,1,2},{0,1,2,1,0,3,0,1,4},{0,1,2,0,2,3,0,3,1,1,3,2}}) {
        result,_,shape_failed:=simplified(indices,points,0,max(f32),{.Permissive,.Prune})
        testing.expect(t,shape_failed==.None && len(result)%3==0)
        for index in result {testing.expect(t,int(index)<len(points))}
    }
    same:=[]Vec3{{1,1,1},{1,1,1},{1,1,1},{1,1,1}}
    for options in ([]Simplify_Options{{},{.Error_Absolute},{.Sparse,.Prune}}) {
        result,error,same_failed:=simplified({0,1,2,0,2,3,0,3,1,1,3,2},same,0,1,options)
        testing.expect(t,same_failed==.None && len(result)%3==0 && error==0)
    }
}

@(test)
simplify_is_deterministic_and_works_in_place :: proc(t:^testing.T) {
    torus:Mesh_Buffer
    mesh_buffer_init(&torus)
    defer mesh_buffer_destroy(&torus)
    welded(&torus,proc(out:^Mesh_Buffer) {torus_build(out,1,0.35,24,12)})
    first,first_error,_:=simplified(torus.indices[:],torus.positions[:],150,max(f32))
    second,second_error,_:=simplified(torus.indices[:],torus.positions[:],150,max(f32))
    in_place:=make([]u32,len(torus.indices),context.temp_allocator)
    copy(in_place,torus.indices[:])
    in_place_result,_:=simplify(in_place,in_place,torus.positions[:],150*3,max(f32))
    count,in_place_error:=in_place_result.index_count,in_place_result.result_error
    testing.expect(t,first_error==second_error && first_error==in_place_error && len(first)/3<=150)
    testing.expect(t,bytes_equal(first,second) && bytes_equal(first,in_place[:count]))
    testing.expect(t,mesh_is_closed(torus.positions[:],first),"a torus keeps its hole and stays closed")
}
