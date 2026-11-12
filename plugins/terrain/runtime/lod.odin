package terrain

import "core:math"

// Levels of detail of the pieces of a Heightfield: level k shows every
// 2^k-th sample. Each side of a piece (a chunk, or a node of the quadtree) is
// built at the level of its border (Border_Levels), the finer of the two
// chunks it joins, so every piece that shares it builds the same vertices
// along it and no crack opens between them; a strip of triangles joins that
// side to the inner grid of the piece. A Volume has none: its nodes show in
// the levels of their clusters.
LOD_LEVELS_MAX :: 7
// A chunk changes level only once its distance passes the boundary by this factor.
LOD_HYSTERESIS :: f32(1.1)
// Without Terrain_Settings.lod_distance, level 0 reaches this many chunk widths.
LOD_CHUNKS :: 4

// The level of a Heightfield chunk, of its sides (-X,+X,-Z,+Z) and of its
// corners (-X-Z, +X-Z, -X+Z, +X+Z), the points of the chunk grid where they
// meet. Of a node of the quadtree, the level of its inner grid and the finest
// of each side.
Chunk_Lod :: struct {level:u8,sides:[4]u8,corners:[4]u8}

// The coarsest level of a chunk: that which still leaves a sample inside it
// along each axis.
chunk_lod_max :: proc "contextless" (s:^Source,coord:[3]i32) -> u8 {
    level:=0
    low,high,valid:=chunk_region(s,coord)
    if !valid {return 0}
    // A Volume has no levels of its own: its nodes show what is far.
    if s.kind==.Volume {return 0}
    size:=min(high.x-low.x,high.z-low.z)
    for level<LOD_LEVELS_MAX && 2<<uint(level+1)<=size {level+=1}
    return u8(level)
}

// The level for a distance: 0 below base, one more each time it doubles.
// The current level stays while the distance is within LOD_HYSTERESIS of it.
lod_level :: proc "contextless" (distance,base:f32,maximum,current:u8) -> u8 {
    at :: proc "contextless" (distance,base:f32) -> int {
        if !(distance>=base) {return 0}
        return int(math.log2(distance/base))+1
    }
    near,far:=at(distance/LOD_HYSTERESIS,base),at(distance*LOD_HYSTERESIS,base)
    level:=int(current)
    if level<near || level>far {level=at(distance,base)}
    return u8(clamp(level,0,int(maximum)))
}

// The sides and corners of a Heightfield chunk take the finer level of the
// chunks that share them; levels holds the level of every chunk of the
// source. A Volume chunk has none.
chunk_lod_sides :: proc "contextless" (s:^Source,levels:[]u8,coord:[3]i32) -> (lod:Chunk_Lod) {
    if s.kind!=.Heightfield {return}
    n:=chunk_counts(s)
    b:=Border_Levels{counts={n.x,n.z},levels=levels}
    return chunk_lod_border(&b,levels[chunk_index(s,coord)],{int(coord.x),int(coord.z)})
}

// The Chunk_Lod of the Heightfield chunk at coord of the chunk grid, at its
// level, with its border.
chunk_lod_border :: proc "contextless" (b:^Border_Levels,level:u8,coord:[2]int) -> (lod:Chunk_Lod) {
    lod.level=level
    lod.sides={border_vertical(b,coord.x,coord.y),border_vertical(b,coord.x+1,coord.y),border_horizontal(b,coord.y,coord.x),border_horizontal(b,coord.y+1,coord.x)}
    lod.corners={border_corner(b,coord.x,coord.y),border_corner(b,coord.x+1,coord.y),border_corner(b,coord.x,coord.y+1),border_corner(b,coord.x+1,coord.y+1)}
    return
}

// What builds a piece of a Heightfield: its region of samples, inclusive;
// the level of its inner grid and whether that comes from the coarse grid (a
// node); its border; whether it has holes; and the samples between the
// texels of its maps (a node, 2^depth).
// A displaced chunk splits each cell in 2^detail per side, on the triangles of
// its collider: its positions count those steps, its sides keep the levels of
// their border but those that join another displaced chunk (fine), built at
// the steps of the detail they share.
@(private)
Piece :: struct {
    low,high:[2]int,
    level:u8,
    coarse:bool,
    border:^Piece_Border,
    holes:bool,
    cuts:[]Join_Cut, // cells a joined Volume takes, holes too
    detail:u8,
    fine:[4]u8,
    spacing:int,
}

// The lines of a level across size cells: every step, and the last one.
@(private)
lod_lines :: proc(size,step:int,out:^[dynamic]int) {
    clear(out)
    for at:=0;at<size;at+=step {append(out,at)}
    append(out,size)
}

// The positions along a side of size cells, cut by the chunk grid every
// cells into segments, each at its level; a step of a level spans 2^detail
// positions, and a fine side takes the positions of its own detail.
@(private)
piece_side_lines :: proc(size,cells:int,levels:[]u8,out:^[dynamic]int,detail:u8=0,fine:u8=0) {
    clear(out)
    for start,k:=0,0;start<size;start,k=start+cells,k+1 {
        end:=min(start+cells,size)
        step:=fine>0?1<<uint(detail-min(fine,detail)):1<<uint(levels[min(k,len(levels)-1)]+detail)
        for at:=start;at<end;at+=step {append(out,at)}
    }
    append(out,size)
}

// The index of the vertex of a piece at p, relative to its lowest sample;
// made the first time with the normal over the step of what it belongs to:
// its inner grid, the segment of its side it is on, or the point of the
// chunk grid, which every piece that shares them builds alike.
@(private)
piece_vertex :: proc(s:^Source,mesh:^Chunk_Mesh,p:Piece,lines:^Piece_Lines,at:[2]int) -> (index:u32,ok:bool) {
    width,depth:=(p.high.x-p.low.x)<<p.detail,(p.high.y-p.low.y)<<p.detail
    cells:=int(s.chunk_cells)<<p.detail
    slot:=-1
    level:=lines.level
    coarse:=p.coarse
    side:=-1
    along:=0
    switch {
    case at.x==0:     side,along=0,at.y
    case at.x==width: side,along=1,at.y
    case at.y==0:     side,along=2,at.x
    case at.y==depth: side,along=3,at.x
    }
    if side>=0 {
        size:=side<2?depth:width
        slot=lines.interior+(side==1?depth+1:0)+(side==2?2*(depth+1):0)+(side==3?2*(depth+1)+width+1:0)+along
        if along%cells==0 || along==size {
            list:=p.border.corners[side][:]
            level=list[along==size?len(list)-1:min(along/cells,len(list)-1)]
        } else {
            list:=p.border.sides[side][:]
            level=list[min(along/cells,len(list)-1)]
        }
        coarse=level>=COARSE_LEVEL
    } else {
        i,j:=lines.column[at.x],lines.row[at.y]
        slot=int(i)+len(lines.xs)*int(j)
    }
    if mesh.remap[slot]>=0 {return u32(mesh.remap[slot]),true}
    split:=(1<<p.detail)-1
    x,z:=p.low.x+at.x>>p.detail,p.low.y+at.y>>p.detail
    step:=1<<uint(level)
    position,normal:[3]f32
    switch {
    case at.x&split!=0 || at.y&split!=0: position,normal=detail_vertex(s,{x,z},{at.x&split,at.y&split},p.detail)
    case coarse:                         position,normal=coarse_vertex(s,x,z,step)
    case:                                position,normal=heightfield_vertex(s,x,z,step)
    }
    // Where it is over the maps of the piece, in texels.
    uv:=[2]f32{f32(at.x),f32(at.y)}/f32(max(p.spacing,1)<<p.detail)
    m:=&mesh.geometry
    index=u32(len(m.positions))
    if append(&m.positions,position)!=1 || append(&m.normals,normal)!=1 || append(&m.uvs,uv)!=1 || append(&mesh.uv1s,[2]f32{})!=1 {return}
    mesh.remap[slot]=i32(index)
    return index,true
}

// The lines of the inner grid of a piece and where a position falls among them.
@(private)
Piece_Lines :: struct {
    level:u8,
    xs,zs:[dynamic]int,
    column,row:[dynamic]i32, // by position along X and Z: its line of the inner grid
    interior:int,            // vertices of the inner grid, before those of the sides
}

// A triangle of three points of the piece, facing up; one over holes alone is
// left out (piece_triangle_holes).
@(private)
piece_triangle :: proc(s:^Source,mesh:^Chunk_Mesh,p:Piece,lines:^Piece_Lines,a,b,c:[2]int) -> bool {
    b,c:=b,c
    if (b.y-a.y)*(c.x-a.x)-(b.x-a.x)*(c.y-a.y)<0 {b,c=c,b}
    if p.holes {
        // The cells of samples under it.
        x0,z0:=min(a.x,b.x,c.x)>>p.detail,min(a.y,b.y,c.y)>>p.detail
        x1,z1:=max((max(a.x,b.x,c.x)-1)>>p.detail,x0),max((max(a.y,b.y,c.y)-1)>>p.detail,z0)
        if piece_triangle_holes(s,p,mesh,{p.low.x+x0,p.low.y+z0},{p.low.x+x1+1,p.low.y+z1+1}) {return true}
    }
    ia:=piece_vertex(s,mesh,p,lines,a) or_return
    ib:=piece_vertex(s,mesh,p,lines,b) or_return
    ic:=piece_vertex(s,mesh,p,lines,c) or_return
    return append(&mesh.geometry.indices,ia,ib,ic)==3
}

// Triangles between two lines along axis, each with one edge on one of them.
@(private)
piece_zip :: proc(s:^Source,mesh:^Chunk_Mesh,p:Piece,lines:^Piece_Lines,outer,inner:[][2]int,axis:int) -> bool {
    o,i:=0,0
    for o<len(outer)-1 || i<len(inner)-1 {
        if o<len(outer)-1 && (i==len(inner)-1 || outer[o+1][axis]<=inner[i+1][axis]) {
            piece_triangle(s,mesh,p,lines,outer[o],outer[o+1],inner[i]) or_return
            o+=1
        } else {
            piece_triangle(s,mesh,p,lines,outer[o],inner[i+1],inner[i]) or_return
            i+=1
        }
    }
    return true
}

// The visible mesh of a piece of a Heightfield: its inner grid at its level
// (finer where the piece is too narrow for it), its sides at the levels of
// their segments and a strip that joins each side to the inner grid. A piece
// one cell across joins its two long sides.
@(private)
piece_build :: proc(s:^Source,p:Piece,mesh:^Chunk_Mesh) -> bool {
    width,depth:=(p.high.x-p.low.x)<<p.detail,(p.high.y-p.low.y)<<p.detail
    if width<1 || depth<1 {return false}
    mesh.grid=true
    if !surface_maps_build(s,p.low,p.high,max(p.spacing,1),p.coarse,p.cuts,&mesh.maps) {return false}
    cells:=int(s.chunk_cells)<<p.detail
    lines:=&mesh.lines
    lines.level=p.level
    narrow:=min(width,depth)
    for lines.level>0 && 2<<uint(lines.level)>narrow {lines.level-=1}
    step:=1<<uint(lines.level)
    lod_lines(width,step,&lines.xs);lod_lines(depth,step,&lines.zs)
    nx,nz:=len(lines.xs),len(lines.zs)
    if resize(&lines.column,width+1)!=nil || resize(&lines.row,depth+1)!=nil {return false}
    for x,i in lines.xs {lines.column[x]=i32(i)}
    for z,j in lines.zs {lines.row[z]=i32(j)}
    lines.interior=nx*nz
    if resize(&mesh.remap,lines.interior+2*(depth+1)+2*(width+1))!=nil {return false}
    for &at in mesh.remap {at=-1}
    side:=&mesh.side
    inner:=&mesh.inner
    if narrow==1 {
        // Too narrow for an inner line: the two long sides join each other.
        long:=width==1?0:2
        size:=long==0?depth:width
        other:=&mesh.other
        piece_side_lines(size,cells,p.border.sides[long][:],&mesh.positions_a,p.detail,p.fine[long])
        piece_side_lines(size,cells,p.border.sides[long+1][:],&mesh.positions_b,p.detail,p.fine[long+1])
        clear(side);clear(other)
        for at in mesh.positions_a {append(side,long==0?[2]int{0,at}:[2]int{at,0})}
        for at in mesh.positions_b {append(other,long==0?[2]int{width,at}:[2]int{at,depth})}
        return piece_zip(s,mesh,p,lines,side[:],other[:],long==0?1:0)
    }
    for j in 1..<nz-2 {for i in 1..<nx-2 {
        a,b,c,d:=[2]int{lines.xs[i],lines.zs[j]},[2]int{lines.xs[i],lines.zs[j+1]},[2]int{lines.xs[i+1],lines.zs[j]},[2]int{lines.xs[i+1],lines.zs[j+1]}
        piece_triangle(s,mesh,p,lines,a,b,c) or_return
        piece_triangle(s,mesh,p,lines,c,b,d) or_return
    }}
    for which in 0..<4 {
        along:=which<2?depth:width
        piece_side_lines(along,cells,p.border.sides[which][:],&mesh.positions_a,p.detail,p.fine[which])
        clear(side);clear(inner)
        switch which {
        case 0,1:
            x:=which==0?0:width
            inner_x:=which==0?lines.xs[1]:lines.xs[nx-2]
            for at in mesh.positions_a {append(side,[2]int{x,at})}
            for j in 1..=nz-2 {append(inner,[2]int{inner_x,lines.zs[j]})}
        case 2,3:
            z:=which==2?0:depth
            inner_z:=which==2?lines.zs[1]:lines.zs[nz-2]
            for at in mesh.positions_a {append(side,[2]int{at,z})}
            for i in 1..=nx-2 {append(inner,[2]int{lines.xs[i],inner_z})}
        }
        piece_zip(s,mesh,p,lines,side[:],inner[:],which<2?1:0) or_return
    }
    return true
}
