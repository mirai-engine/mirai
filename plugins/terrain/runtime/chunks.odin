package terrain

import "base:runtime"
import "core:math"
import "core:math/linalg"
import phys "plugins:physics/runtime"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"

Chunk_Mesh :: struct {
    geometry:geom.Mesh_Buffer,
    welded:geom.Mesh_Buffer,
    halo:geom.Mesh_Buffer,
    halo_edges:map[[2]geom.Vec3]geom.Vec3,
    disabled_edges:[dynamic]u8,
    disabled_borders:[dynamic]u8,
    uv1s:[dynamic][2]f32,
    heights:[dynamic]f32,
    columns,rows:int,
    origin:[3]f32, // the place of the chunk in its terrain, which its vertices and what collides are relative to (chunk_place)
    cell:[3]f32,
    remap:[dynamic]i32,
    holes:[dynamic]u8, // of the cells of a Heightfield collider
    samples:[dynamic]f32, // of a Volume: the window of samples a build reads
    collision:geom.Mesh_Buffer, // a Volume at a level above 0: what collides, level 0
    render:host.Mesh_Render_Geometry, // what the renderer takes of geometry, made by the job that built it
    render_ready:bool,                // render is that of geometry as it is
    // A piece of a Heightfield: the border of a chunk, and the lines it joins.
    border:Piece_Border,
    lines:Piece_Lines,
    side,inner,other:[dynamic][2]int,
    positions_a,positions_b:[dynamic]int,
}

chunk_mesh_init :: proc(mesh:^Chunk_Mesh,allocator:=context.allocator) {
    geom.mesh_buffer_init(&mesh.geometry,allocator)
    geom.mesh_buffer_init(&mesh.welded,allocator)
    geom.mesh_buffer_init(&mesh.halo,allocator)
    mesh.halo_edges=make(map[[2]geom.Vec3]geom.Vec3,allocator)
    mesh.disabled_edges=make([dynamic]u8,allocator)
    mesh.disabled_borders=make([dynamic]u8,allocator)
    mesh.uv1s=make([dynamic][2]f32,allocator)
    mesh.heights=make([dynamic]f32,allocator)
    mesh.remap=make([dynamic]i32,allocator)
    mesh.holes=make([dynamic]u8,allocator)
    mesh.samples=make([dynamic]f32,allocator)
    geom.mesh_buffer_init(&mesh.collision,allocator)
    host.assets_render_geometry_init(&mesh.render,allocator)
    for i in 0..<4 {mesh.border.sides[i]=make([dynamic]u8,allocator);mesh.border.corners[i]=make([dynamic]u8,allocator)}
    mesh.lines.xs,mesh.lines.zs=make([dynamic]int,allocator),make([dynamic]int,allocator)
    mesh.lines.column,mesh.lines.row=make([dynamic]i32,allocator),make([dynamic]i32,allocator)
    mesh.side,mesh.inner,mesh.other=make([dynamic][2]int,allocator),make([dynamic][2]int,allocator),make([dynamic][2]int,allocator)
    mesh.positions_a,mesh.positions_b=make([dynamic]int,allocator),make([dynamic]int,allocator)
}

chunk_mesh_destroy :: proc(mesh:^Chunk_Mesh) {
    geom.mesh_buffer_destroy(&mesh.geometry)
    geom.mesh_buffer_destroy(&mesh.welded)
    geom.mesh_buffer_destroy(&mesh.halo)
    delete(mesh.halo_edges);delete(mesh.disabled_edges);delete(mesh.disabled_borders)
    delete(mesh.uv1s);delete(mesh.heights)
    delete(mesh.remap)
    delete(mesh.holes);delete(mesh.samples)
    geom.mesh_buffer_destroy(&mesh.collision)
    host.assets_render_geometry_destroy(&mesh.render)
    piece_border_destroy(&mesh.border)
    delete(mesh.lines.xs);delete(mesh.lines.zs);delete(mesh.lines.column);delete(mesh.lines.row)
    delete(mesh.side);delete(mesh.inner);delete(mesh.other);delete(mesh.positions_a);delete(mesh.positions_b)
    mesh^={}
}

chunk_counts :: proc "contextless" (s:^Source) -> (counts:[3]int) {
    for axis in 0..<3 {counts[axis]=max((int(s.samples[axis])-2+int(s.chunk_cells))/int(s.chunk_cells),1)}
    return
}

chunk_coord :: proc "contextless" (s:^Source,index:int) -> [3]i32 {
    n:=chunk_counts(s)
    return {i32(index%n.x),i32(index/n.x%n.y),i32(index/(n.x*n.y))}
}

chunk_index :: proc "contextless" (s:^Source,coord:[3]i32) -> int {
    n:=chunk_counts(s)
    if coord.x<0 || coord.y<0 || coord.z<0 || int(coord.x)>=n.x || int(coord.y)>=n.y || int(coord.z)>=n.z {return -1}
    return int(coord.x)+n.x*(int(coord.y)+n.y*int(coord.z))
}

chunk_range :: proc "contextless" (s:^Source,change:Change) -> (low,high:[3]int) {
    if !change.changed {return {},{-1,-1,-1}}
    for axis in 0..<3 {
        maximum:=max(int(s.samples[axis])-2,0)
        low[axis]=clamp(change.low[axis]-2,0,maximum)/int(s.chunk_cells)
        high[axis]=clamp(change.high[axis]+1,0,maximum)/int(s.chunk_cells)
    }
    return
}

chunk_touched :: proc "contextless" (s:^Source,coord:[3]i32,change:Change) -> bool {
    low,high:=chunk_range(s,change)
    return change.changed && int(coord.x)>=low.x && int(coord.y)>=low.y && int(coord.z)>=low.z && int(coord.x)<=high.x && int(coord.y)<=high.y && int(coord.z)<=high.z
}

chunk_region :: proc "contextless" (s:^Source,coord:[3]i32) -> (low,high:[3]int,ok:bool) {
    if !source_valid(s.info) || chunk_index(s,coord)<0 {return}
    low={int(coord.x)*int(s.chunk_cells),int(coord.y)*int(s.chunk_cells),int(coord.z)*int(s.chunk_cells)}
    for axis in 0..<3 {high[axis]=min(low[axis]+int(s.chunk_cells),int(s.samples[axis])-1)}
    return low,high,true
}

// lod: the level of the chunk and of what it shares. The collider keeps
// level 0, whatever the level shown. The chunk is in its own space
// (chunk_place): its entity stands at mesh.origin of its terrain.
chunk_build :: proc(s:^Source,coord:[3]i32,mesh:^Chunk_Mesh,collision:=true,lod:=Chunk_Lod{},join:=Chunk_Join{}) -> bool {
    chunk_build_terrain(s,coord,mesh,collision,lod,join) or_return
    chunk_place(s,coord,mesh)
    return true
}

// The visible mesh of node index of the quadtree (above the chunks), in its
// own space, without collider. A Heightfield node shows its region at
// lod.level from the coarse grid, joined by its border.
node_build :: proc(s:^Source,q:^Quad,index:int,lod:Chunk_Lod,border:^Piece_Border,mesh:^Chunk_Mesh) -> bool {
    chunk_mesh_clear(mesh)
    if index<q.first[1] || index>=quad_total(q) {return false}
    m:=&mesh.geometry
    switch s.kind {
    case .Heightfield:
        low,high:=quad_region(s,q,index)
        if !piece_build(s,{low=low,high=high,level=lod.level,coarse=true,border=border},mesh) {return false}
    case .Volume:
        return false
    }
    chunk_place(s,quad_place(s,q,index),mesh)
    return true
}

// The place of a chunk in its terrain: the lowest corner of its cells.
chunk_origin :: proc "contextless" (s:^Source,coord:[3]i32) -> (origin:[3]f32) {
    start:=source_origin(s)
    for axis in 0..<3 {origin[axis]=f32(f64(start[axis])+f64(coord[axis])*f64(s.chunk_cells)*f64(s.cell))}
    return
}

// What a texture laid over the terrain, a turn every UV_METERS, has turned
// before a place of it, without the whole turns: the uvs of a chunk start
// there and stay small however far the terrain reaches.
chunk_turns :: proc "contextless" (place:[3]f32) -> [2]f32 {
    turns:[2]f32
    for axis,i in ([2]int{0,2}) {
        p:=f64(place[axis])/f64(UV_METERS)
        turns[i]=f32(p-math.floor(p))
    }
    return turns
}

// A chunk built in the space of its terrain into its own, from its place
// there (chunk_origin, mesh.origin): its vertices and what collides of it. A
// terrain of kilometres keeps them within a chunk, which f32 holds to the
// millimetre and less.
@(private)
chunk_place :: proc(s:^Source,coord:[3]i32,mesh:^Chunk_Mesh) {
    origin:=chunk_origin(s,coord)
    mesh.origin=origin
    for &p in mesh.geometry.positions {p-=origin}
    for &p in mesh.collision.positions {p-=origin}
}

@(private)
chunk_mesh_clear :: proc(mesh:^Chunk_Mesh) {
    mesh.render_ready=false
    geom.mesh_buffer_clear(&mesh.geometry)
    geom.mesh_buffer_clear(&mesh.collision)
    clear(&mesh.uv1s);clear(&mesh.heights);clear(&mesh.disabled_edges);clear(&mesh.disabled_borders);clear(&mesh.holes)
    mesh.columns,mesh.rows=0,0
    mesh.origin,mesh.cell={},{}
}

// A displaced chunk (displacement.odin), without collider: at level 0 with
// each cell split in 2^detail per side, its sides at the levels of lod but
// those that join another displaced chunk (fine), at its steps.
chunk_detail_build :: proc(s:^Source,coord:[3]i32,lod:Chunk_Lod,detail:u8,fine:[4]bool,mesh:^Chunk_Mesh) -> bool {
    chunk_mesh_clear(mesh)
    low,high,valid:=chunk_region(s,coord)
    if !valid || s.kind!=.Heightfield || lod.level!=0 {return false}
    piece_border_of_lod(lod,&mesh.border)
    piece_build(s,{low=low.xz,high=high.xz,border=&mesh.border,holes=len(s.holes.pages)>0,detail=detail,fine=fine},mesh) or_return
    chunk_place(s,coord,mesh)
    return true
}

@(private)
chunk_build_terrain :: proc(s:^Source,coord:[3]i32,mesh:^Chunk_Mesh,collision:=true,lod:=Chunk_Lod{},join:=Chunk_Join{}) -> bool {
    chunk_mesh_clear(mesh)
    low,high,valid:=chunk_region(s,coord)
    if !valid {return false}
    m:=&mesh.geometry
    if s.kind==.Volume {
        grid:geom.Scalar_Grid
        surface,ok:=chunk_volume_window(s,low,high,lod.level,&mesh.samples,&grid,join)
        if !ok {return false}
        if surface && collision {
            if geom.isosurface(grid,low,high,m)!=.None {return false}
            collides:=lod.level>0?&mesh.collision:&mesh.welded
            if !geom.mesh_weld(geom.mesh_buffer_view(m),0,collides) {return false}
            if lod.level==0 {
                mesh.geometry,mesh.welded=mesh.welded,mesh.geometry
                collides=m
            }
            if !chunk_volume_edges(s,grid,low,high,mesh,collides) {return false}
        }
        if surface && (lod.level>0 || !collision) {
            if geom.isosurface(grid,low,high,m,0,chunk_iso_lod(lod))!=.None {return false}
            if !geom.mesh_weld(geom.mesh_buffer_view(m),0,&mesh.welded) {return false}
            mesh.geometry,mesh.welded=mesh.welded,mesh.geometry
            // What a coarse level misses still shows while it collides.
            if len(m.indices)==0 && len(mesh.collision.indices)>0 {
                mesh.geometry,mesh.collision=mesh.collision,mesh.geometry
                geom.mesh_buffer_clear(&mesh.collision)
            }
        }
        if resize(&m.uvs,len(m.positions))!=nil || resize(&mesh.uv1s,len(m.positions))!=nil {return false}
        for position,i in m.positions {
            w:=layers_vertex(s,source_weights_at(s,position),i<len(m.normals)?m.normals[i]:{0,1,0},position.y)
            m.uvs[i],mesh.uv1s[i]={w[0],w[1]},{w[2],w[3]}
        }
        return true
    }
    columns,rows:=high.x-low.x+1,high.z-low.z+1
    if !chunk_lod_plain(lod) {
        piece_border_of_lod(lod,&mesh.border)
        if !piece_build(s,{low=low.xz,high=high.xz,level=lod.level,border=&mesh.border,holes=len(s.holes.pages)>0 || len(join.cuts)>0,cuts=join.cuts},mesh) {return false}
    } else {
        count:=columns*rows
        if resize(&m.positions,count)!=nil || resize(&m.normals,count)!=nil || resize(&m.uvs,count)!=nil || resize(&mesh.uv1s,count)!=nil || resize(&m.indices,(columns-1)*(rows-1)*6)!=nil {return false}
        for row in 0..<rows {for column in 0..<columns {
            at:=row*columns+column
            m.positions[at],m.normals[at],m.uvs[at],mesh.uv1s[at]=heightfield_vertex(s,low.x+column,low.z+row,1)
        }}
        next:=0
        for row in 0..<rows-1 {for column in 0..<columns-1 {
            if cell_hole(s,join.cuts,low.x+column,low.z+row) {continue}
            a:=u32(row*columns+column);b:=a+u32(columns)
            indices:=[6]u32{a,b,a+1,a+1,b,b+1}
            copy(m.indices[next:],indices[:]);next+=6
        }}
        base.truncate(&m.indices,next)
    }
    if !collision {return true}
    // The collider keeps every sample, whatever the level shown.
    if resize(&mesh.heights,columns*rows)!=nil {return false}
    for row in 0..<rows {for column in 0..<columns {mesh.heights[row*columns+column]=grid_get(&s.heights,low.x+column,low.z+row)}}
    if len(s.holes.pages)>0 || len(join.cuts)>0 {
        if resize(&mesh.holes,(columns-1)*(rows-1))!=nil {return false}
        for row in 0..<rows-1 {for column in 0..<columns-1 {mesh.holes[row*(columns-1)+column]=u8(cell_hole(s,join.cuts,low.x+column,low.z+row))}}
    }
    mesh.columns,mesh.rows=columns,rows
    mesh.cell={s.cell,1,s.cell}
    return chunk_heightfield_borders(s,low,high,mesh,join.cuts)
}

// The attributes of the vertex of a Heightfield sample, in the space of the
// terrain: its normal from the samples step away in the whole source, the
// slope the triangles of that step span, and the weights of its layers in the
// uvs.
@(private)
heightfield_vertex :: proc "contextless" (s:^Source,x,z,step:int) -> (position,normal:[3]f32,uv,uv1:[2]f32) {
    position=source_point(s,{x,0,z})
    normal=heightfield_normal(s,x,z,step)
    w:=layers_vertex(s,weights_float(grid_get(&s.weights,x,z)),heightfield_normal(s,x,z,LAYER_RULE_SAMPLES),position.y)
    return position,normal,{w[0],w[1]},{w[2],w[3]}
}

// A vertex inside the cell whose lowest sample is at, a step of 2^detail per
// sample in from it: on the triangle of the collider it falls in, with the
// attributes of its corners blended as its place is.
@(private)
detail_vertex :: proc "contextless" (s:^Source,at,step:[2]int,detail:u8) -> (position,normal:[3]f32,uv,uv1:[2]f32) {
    nx,nz:=int(s.samples.x),int(s.samples.z)
    f:=[2]f32{f32(step.x),f32(step.y)}/f32(int(1)<<detail)
    corners:=[4][2]int{at,{min(at.x+1,nx-1),at.y},{at.x,min(at.y+1,nz-1)},{min(at.x+1,nx-1),min(at.y+1,nz-1)}}
    // The diagonal of a cell runs from its +X corner to its +Z one.
    w:=f.x+f.y<=1?[4]f32{1-f.x-f.y,f.x,f.y,0}:[4]f32{0,1-f.y,1-f.x,f.x+f.y-1}
    for corner,i in corners {
        if w[i]==0 {continue}
        p,n,a,b:=heightfield_vertex(s,corner.x,corner.y,1)
        position+=p*w[i];normal+=n*w[i];uv+=a*w[i];uv1+=b*w[i]
    }
    normal=linalg.normalize0(normal)
    return
}

// Makes the geometry the renderer takes of a chunk built, where it was
// built: chunk_publish then only gives it the rows of its materials. Any thread.
chunk_render_prepare :: proc(kind:Source_Kind,mesh:^Chunk_Mesh,limits:host.Assets_Limits) -> bool {
    if len(mesh.geometry.indices)==0 {return false}
    tangents:[][4]f32
    if kind==.Heightfield {
        tangents=make([][4]f32,len(mesh.geometry.normals),context.temp_allocator)
        heightfield_tangents(mesh.geometry.normals[:],tangents)
    }
    mesh.render_ready=host.assets_render_geometry_make(geom.mesh_buffer_view(&mesh.geometry),mesh.uv1s[:],1,&mesh.render,limits,tangents)
    return mesh.render_ready
}

// The tangents of the vertices of a Heightfield chunk, whose uvs are their
// place over UV_METERS (or weights of layers, which shade triplanar): +x
// across the normal, and the bitangent up the image, towards -z, as Mirai's
// v grows with z. What MikkTSpace gives such a grid, without its cost.
heightfield_tangents :: proc "contextless" (normals:[][3]f32,out:[][4]f32) {
    for n,i in normals {
        t:=linalg.normalize0([3]f32{1,0,0}-n*n.x)
        out[i]={t.x,t.y,t.z,1}
    }
}

// The normal of a Heightfield at a sample, from the samples step away on each
// side (fewer at the borders of the source).
heightfield_normal :: proc "contextless" (s:^Source,x,z,step:int) -> [3]f32 {
    nx,nz:=int(s.samples.x),int(s.samples.z)
    x0,x1,z0,z1:=max(x-step,0),min(x+step,nx-1),max(z-step,0),min(z+step,nz-1)
    west,east:=grid_get(&s.heights,x0,z),grid_get(&s.heights,x1,z)
    north,south:=grid_get(&s.heights,x,z0),grid_get(&s.heights,x,z1)
    return linalg.normalize0([3]f32{(west-east)/(f32(x1-x0)*s.cell),1,(north-south)/(f32(z1-z0)*s.cell)})
}

// The samples a build of the Volume chunk low..high at level reads, from its
// blocks into samples: grid, the window of the field its surface and its
// collider are extracted from, at the places of the whole field. surface is
// false when every block there is all air or all solid alike: there is none
// to extract.
@(private)
chunk_volume_window :: proc(s:^Source,low,high:[3]int,level:u8,samples:^[dynamic]f32,grid:^geom.Scalar_Grid,join:=Chunk_Join{}) -> (surface,ok:bool) {
    g:=&s.distances
    halo:=max(1<<uint(level),2)
    last:[3]int
    grid^={samples={int(s.samples.x),int(s.samples.y),int(s.samples.z)},cell={s.cell,s.cell,s.cell},origin=source_origin(s)}
    for axis in 0..<3 {grid.first[axis],last[axis]=max(low[axis]-halo,0),min(high[axis]+halo,int(s.samples[axis])-1)}
    if !volume_held(s,grid.first,last) {return}
    from,to:=grid_pages(g,grid.first,last)
    sign:=0
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
        page:=&g.pages[px+g.counts.x*(py+g.counts.y*pz)]
        side:=page.fill<0?-1:1
        if page.values!=nil || sign!=0 && side!=sign {surface=true}
        sign=side
    }}}
    // The ground the band of a joined Volume reads may cross it anywhere.
    banded:=join.ground!=nil && (grid.first.x<JOIN_BAND || grid.first.z<JOIN_BAND || last.x>int(s.samples.x)-1-JOIN_BAND || last.z>int(s.samples.z)-1-JOIN_BAND)
    if !surface && !banded {return false,true}
    grid.extent=last-grid.first+1
    if resize(samples,grid.extent.x*grid.extent.y*grid.extent.z)!=nil {return}
    grid.values=samples[:]
    // Row by row, a run of each block at a time.
    at:=0
    for z in grid.first.z..=last.z {for y in grid.first.y..=last.y {
        for x:=grid.first.x;x<=last.x; {
            q:=[3]int{x,y,z}/BLOCK
            page:=&g.pages[q.x+g.counts.x*(q.y+g.counts.y*q.z)]
            run:=samples[at:][:min(q.x*BLOCK+BLOCK-1,last.x)-x+1]
            if page.values==nil {
                for &value in run {value=page.fill}
            } else {
                low:=q*BLOCK
                width,height:=min(BLOCK,g.size.x-low.x),min(BLOCK,g.size.y-low.y)
                copy(run,page.values[x-low.x+width*(y-low.y+height*(z-low.z)):])
            }
            at+=len(run)
            x+=len(run)
        }
    }}
    if banded {join_blend(s,join,grid.values,grid.first,grid.extent)}
    return true,true
}

@(private)
chunk_volume_edges :: proc(s:^Source,grid:geom.Scalar_Grid,low,high:[3]int,mesh:^Chunk_Mesh,m:^geom.Mesh_Buffer) -> bool {
    if resize(&mesh.disabled_edges,len(m.indices)/3)!=nil {return false}
    for &mask in mesh.disabled_edges {mask=0}
    for axis in 0..<3 {for side in 0..<2 {
        cut:=side==0?low[axis]:high[axis]
        if cut==0 || cut==int(s.samples[axis])-1 {continue}
        from,to:=low,high
        from[axis]=cut-(side==0?1:0);to[axis]=from[axis]+1
        if geom.isosurface(grid,from,to,&mesh.halo)!=.None {return false}
        clear(&mesh.halo_edges)
        if reserve(&mesh.halo_edges,len(mesh.halo.indices))!=nil {return false}
        face:=source_origin(s)[axis]+f32(cut)*s.cell
        for triangle:=0;triangle<len(mesh.halo.indices);triangle+=3 {
            p:=[3]geom.Vec3{mesh.halo.positions[mesh.halo.indices[triangle]],mesh.halo.positions[mesh.halo.indices[triangle+1]],mesh.halo.positions[mesh.halo.indices[triangle+2]]}
            for edge in 0..<3 {
                a,b:=p[edge],p[(edge+1)%3]
                if a[axis]==face && b[axis]==face {mesh.halo_edges[{a,b}]=p[(edge+2)%3]}
            }
        }
        for triangle:=0;triangle<len(m.indices);triangle+=3 {
            p:=[3]geom.Vec3{m.positions[m.indices[triangle]],m.positions[m.indices[triangle+1]],m.positions[m.indices[triangle+2]]}
            normal:=linalg.normalize0(linalg.cross(p[1]-p[0],p[2]-p[0]))
            for edge in 0..<3 {
                a,b:=p[edge],p[(edge+1)%3]
                if a[axis]!=face || b[axis]!=face {continue}
                opposite,found:=mesh.halo_edges[{b,a}]
                if found && !phys.collision_edge_active(normal,a,b,opposite) {mesh.disabled_edges[triangle/3]|=u8(1<<uint(edge))}
            }
        }
    }}
    return true
}

@(private)
chunk_heightfield_borders :: proc(s:^Source,low,high:[3]int,mesh:^Chunk_Mesh,cuts:[]Join_Cut=nil) -> bool {
    rows,columns:=mesh.rows-1,mesh.columns-1
    if resize(&mesh.disabled_borders,2*(rows+columns))!=nil {return false}
    for &mask in mesh.disabled_borders {mask=0}
    for side in 0..<4 {
        axis:=side<2?0:2
        maximum:=side&1!=0
        cut:=maximum?high[axis]:low[axis]
        if cut==0 || cut==int(s.samples[axis])-1 {continue}
        count:=axis==0?rows:columns
        offset:=side<2?side*rows:2*rows+(side-2)*columns
        for i in 0..<count {
            x,z:=low.x,low.z
            if axis==0 {x=cut-(maximum?1:0);z+=i} else {x+=i;z=cut-(maximum?1:0)}
            a,b,c,d:=source_point(s,{x,0,z}),source_point(s,{x+1,0,z}),source_point(s,{x,0,z+1}),source_point(s,{x+1,0,z+1})
            normal:=maximum?linalg.normalize0(linalg.cross(c-b,d-b)):linalg.normalize0(linalg.cross(c-a,b-a))
            p,q,opposite:geom.Vec3
            across:[2]int
            switch side {
            case 0: p,q,opposite,across=a,c,source_point(s,{x-1,0,z+1}),{x-1,z}
            case 1: p,q,opposite,across=d,b,source_point(s,{x+2,0,z}),{x+1,z}
            case 2: p,q,opposite,across=b,a,source_point(s,{x+1,0,z-1}),{x,z-1}
            case 3: p,q,opposite,across=c,d,source_point(s,{x,0,z+2}),{x,z+1}
            }
            // Next to a hole the edge is a border.
            if cell_hole(s,cuts,across.x,across.y) {continue}
            if !phys.collision_edge_active(normal,p,q,opposite) {mesh.disabled_borders[offset+i]=1}
        }
    }
    return true
}

// picking keeps the triangles on the CPU without a collider: the editor picks
// a chunk far from the view by them.
chunk_publish :: proc(a:^host.Assets,kind:Source_Kind,mesh:^Chunk_Mesh,collision:=true,picking:=false) -> (id:base.Asset_Id,ok:bool) {
    if len(mesh.geometry.indices)==0 {return {},true}
    options:=host.Mesh_Generate_Options{no_lods=true,collision=collision || picking,disabled_edges=mesh.disabled_edges[:]}
    if collision {options.collision_mesh=geom.mesh_buffer_view(&mesh.collision)}
    if mesh.render_ready {
        options.render_geometry=&mesh.render
    } else if kind==.Heightfield {
        tangents:=make([][4]f32,len(mesh.geometry.normals),context.temp_allocator)
        heightfield_tangents(mesh.geometry.normals[:],tangents)
        options.tangents=tangents
    }
    heightfield:host.Assets_Heightfield
    if kind==.Heightfield && collision {
        // In the space of the chunk, whose first sample is its origin.
        heightfield={heights=mesh.heights[:],columns=mesh.columns,rows=mesh.rows,cell=mesh.cell,disabled_borders=mesh.disabled_borders[:],holes=mesh.holes[:]}
        options.heightfield=&heightfield
    }
    slots:=[1]base.Asset_Id{}
    return host.assets_mesh_generate(a,geom.mesh_buffer_view(&mesh.geometry),slots[:],mesh.uv1s[:],options)
}

