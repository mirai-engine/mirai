package terrain

import "mirai:std/base"

// The quadtree of a source whose chunks lie on one layer (a Heightfield):
// its leaves are the chunks, in the order of chunk_index, and above
// them the nodes of each depth, in rows, up to the root, which covers every
// chunk. A node covers the chunks of its children: four, or fewer at the far
// edges of the source. A Volume source has only its chunks. Every piece a
// terrain shows is a node of it: a chunk, or a node of lower resolution.

QUAD_DEPTH_MAX :: 13

Quad :: struct {
    depth:int,                       // of the root; 0 for a Volume, which has no nodes
    counts:[QUAD_DEPTH_MAX+1][2]int, // nodes along X and Z of each depth
    first:[QUAD_DEPTH_MAX+2]int,     // index of the first node of each depth; past the root, the count of every node
}

quad_of :: proc "contextless" (s:^Source) -> (q:Quad) {
    n:=chunk_counts(s)
    q.counts[0]={n.x,n.z}
    q.first[1]=n.x*n.y*n.z
    if s.kind==.Volume || n.y!=1 {return}
    // A source of one chunk has a root too: what stays when the chunk goes.
    for (q.depth==0 || q.counts[q.depth]!={1,1}) && q.depth<QUAD_DEPTH_MAX {
        c:=q.counts[q.depth]
        q.depth+=1
        q.counts[q.depth]={(c.x+1)/2,(c.y+1)/2}
        q.first[q.depth+1]=q.first[q.depth]+q.counts[q.depth].x*q.counts[q.depth].y
    }
    return
}

quad_total :: #force_inline proc "contextless" (q:^Quad) -> int {return q.first[q.depth+1]}

quad_depth :: proc "contextless" (q:^Quad,index:int) -> int {
    for d in 0..=q.depth {if index<q.first[d+1] {return d}}
    return -1
}

// The depth of a node and its place among those of its depth.
quad_coord :: proc "contextless" (q:^Quad,index:int) -> (depth:int,coord:[2]int) {
    depth=quad_depth(q,index)
    if depth<0 {return}
    local:=index-q.first[depth]
    return depth,{local%q.counts[depth].x,local/q.counts[depth].x}
}

quad_index :: proc "contextless" (q:^Quad,depth:int,coord:[2]int) -> int {
    if depth<0 || depth>q.depth {return -1}
    n:=q.counts[depth]
    if coord.x<0 || coord.y<0 || coord.x>=n.x || coord.y>=n.y {return -1}
    return q.first[depth]+coord.x+n.x*coord.y
}

// -1 for a root.
quad_parent :: proc "contextless" (q:^Quad,index:int) -> int {
    depth,coord:=quad_coord(q,index)
    if depth<0 || depth>=q.depth {return -1}
    return quad_index(q,depth+1,coord/2)
}

// -1 where a child would be past the edge of the source, and for a chunk.
quad_children :: proc "contextless" (q:^Quad,index:int) -> (children:[4]int) {
    children={-1,-1,-1,-1}
    depth,coord:=quad_coord(q,index)
    if depth<=0 {return}
    for i in 0..<4 {children[i]=quad_index(q,depth-1,coord*2+{i&1,i>>1})}
    return
}

// The chunks a node covers, from low to before high.
quad_chunks :: proc "contextless" (q:^Quad,index:int) -> (low,high:[2]int) {
    depth,coord:=quad_coord(q,index)
    if depth<0 {return}
    low={coord.x<<uint(depth),coord.y<<uint(depth)}
    high={min(low.x+1<<uint(depth),q.counts[0].x),min(low.y+1<<uint(depth),q.counts[0].y)}
    return
}

// The samples of the X/Z grid a node covers, inclusive.
quad_region :: proc "contextless" (s:^Source,q:^Quad,index:int) -> (low,high:[2]int) {
    a,b:=quad_chunks(q,index)
    cells:=int(s.chunk_cells)
    return a*cells,{min(b.x*cells,int(s.samples.x)-1),min(b.y*cells,int(s.samples.z)-1)}
}

// The coordinate of a chunk, or of the first chunk of a node: where its
// entity stands (chunk_origin).
quad_place :: proc "contextless" (s:^Source,q:^Quad,index:int) -> [3]i32 {
    if index<q.first[1] {return chunk_coord(s,index)}
    low,_:=quad_chunks(q,index)
    return {i32(low.x),0,i32(low.y)}
}

// The local box of node i: its region of the source, with the heights its
// samples reach (ranges); a Volume chunk spans its region.
node_box :: proc "contextless" (s:^Source,q:^Quad,ranges:[][2]f32,i:int) -> (low,high:[3]f32) {
    if s.kind==.Volume || q.depth==0 {
        heights:=i<len(ranges)?ranges[i]:{-HEIGHT_LIMIT,HEIGHT_LIMIT}
        return chunk_box(s,source_origin(s),i,heights)
    }
    a,b:=quad_region(s,q,i)
    origin:=source_origin(s)
    low=origin+[3]f32{f32(a.x),0,f32(a.y)}*s.cell
    high=origin+[3]f32{f32(b.x),0,f32(b.y)}*s.cell
    if i<len(ranges) {low.y,high.y=ranges[i].x,ranges[i].y} else {low.y,high.y=-HEIGHT_LIMIT,HEIGHT_LIMIT}
    return
}

// The levels of the borders between the pieces of a Heightfield, from the
// level each chunk would show (levels) and whether it lies well within the
// reach of a viewer (deep). The border of a chunk is cut in segments, a
// chunk wide, and points of the chunk grid. A segment takes the finer of the
// chunks on its sides; a point, the finest of the segments that meet there.
// Below COARSE_LEVEL a border reads the samples, and that only where both
// chunks are deep: their pages are in memory, so any piece that ends there,
// a chunk or a node, builds it alike. Every piece that shares a border builds
// it from these, whatever the pieces around show.
Border_Levels :: struct {
    counts:[2]int,
    levels:[]u8,
    deep:[]bool, // nil: every chunk deep
}

@(private)
border_segment :: proc "contextless" (b:^Border_Levels,a_x,a_z,c_x,c_z:int) -> u8 {
    level:=u8(255)
    deep:=true
    for p in ([2][2]int{{a_x,a_z},{c_x,c_z}}) {
        if p.x<0 || p.y<0 || p.x>=b.counts.x || p.y>=b.counts.y {continue}
        i:=p.x+b.counts.x*p.y
        level=min(level,b.levels[i])
        if b.deep!=nil && !b.deep[i] {deep=false}
    }
    if level==255 {return 0}
    if !deep {level=max(level,COARSE_LEVEL)}
    return level
}

// The segment of the line of the chunk grid at x=gx, along row z.
border_vertical :: #force_inline proc "contextless" (b:^Border_Levels,gx,z:int) -> u8 {return border_segment(b,gx-1,z,gx,z)}
// The segment of the line of the chunk grid at z=gz, along column x.
border_horizontal :: #force_inline proc "contextless" (b:^Border_Levels,gz,x:int) -> u8 {return border_segment(b,x,gz-1,x,gz)}

border_corner :: proc "contextless" (b:^Border_Levels,gx,gz:int) -> u8 {
    level:=u8(255)
    if gz>0 {level=min(level,border_vertical(b,gx,gz-1))}
    if gz<b.counts.y {level=min(level,border_vertical(b,gx,gz))}
    if gx>0 {level=min(level,border_horizontal(b,gz,gx-1))}
    if gx<b.counts.x {level=min(level,border_horizontal(b,gz,gx))}
    return level==255?0:level
}

// What a piece builds along its border: the level of each segment of its
// sides (-X, +X, -Z, +Z, along the side) and of each point of the chunk grid
// on them, one more than its segments.
Piece_Border :: struct {
    sides:[4][dynamic]u8,
    corners:[4][dynamic]u8,
}

piece_border_destroy :: proc(border:^Piece_Border) {
    for i in 0..<4 {delete(border.sides[i]);delete(border.corners[i])}
    border^={}
}

// The border of the chunks low to before high, written to border when it is
// given; returns a hash of it.
piece_border :: proc(b:^Border_Levels,low,high:[2]int,border:^Piece_Border=nil) -> (hash:u64) {
    hash=base.HASH_SEED
    put :: #force_inline proc(hash:^u64,list:^[dynamic]u8,value:u8) {
        hash^=base.hash_mix(hash^,u64(value))
        if list!=nil {append(list,value)}
    }
    if border!=nil {for i in 0..<4 {clear(&border.sides[i]);clear(&border.corners[i])}}
    list :: #force_inline proc "contextless" (border:^Piece_Border,corners:bool,side:int) -> ^[dynamic]u8 {
        if border==nil {return nil}
        return corners?&border.corners[side]:&border.sides[side]
    }
    for z in low.y..<high.y {put(&hash,list(border,false,0),border_vertical(b,low.x,z))}
    for z in low.y..<high.y {put(&hash,list(border,false,1),border_vertical(b,high.x,z))}
    for x in low.x..<high.x {put(&hash,list(border,false,2),border_horizontal(b,low.y,x))}
    for x in low.x..<high.x {put(&hash,list(border,false,3),border_horizontal(b,high.y,x))}
    for z in low.y..=high.y {put(&hash,list(border,true,0),border_corner(b,low.x,z))}
    for z in low.y..=high.y {put(&hash,list(border,true,1),border_corner(b,high.x,z))}
    for x in low.x..=high.x {put(&hash,list(border,true,2),border_corner(b,x,low.y))}
    for x in low.x..=high.x {put(&hash,list(border,true,3),border_corner(b,x,high.y))}
    return
}

// The border of a chunk as its Chunk_Lod tells it.
@(private)
piece_border_of_lod :: proc(lod:Chunk_Lod,border:^Piece_Border) {
    for i in 0..<4 {clear(&border.sides[i]);clear(&border.corners[i])}
    append(&border.sides[0],lod.faces[0]);append(&border.sides[1],lod.faces[1])
    append(&border.sides[2],lod.faces[4]);append(&border.sides[3],lod.faces[5])
    append(&border.corners[0],lod.corners[0],lod.corners[2]);append(&border.corners[1],lod.corners[1],lod.corners[3])
    append(&border.corners[2],lod.corners[0],lod.corners[1]);append(&border.corners[3],lod.corners[2],lod.corners[3])
}

// The coarsest level of node i of a Heightfield: as chunk_lod_max, over its
// region.
node_lod_max :: proc "contextless" (s:^Source,q:^Quad,i:int) -> u8 {
    depth,_:=quad_coord(q,i)
    if depth==0 {return chunk_lod_max(s,chunk_coord(s,i))}
    level:=0
    low,high:=quad_region(s,q,i)
    size:=min(high.x-low.x,high.y-low.y)
    for level<LOD_LEVELS_MAX+QUAD_DEPTH_MAX && 2<<uint(level+1)<=size {level+=1}
    return u8(level)
}

// The finest level node i of depth above 0 shows: a node of a Heightfield is
// built from the coarse grid, never finer than it.
node_lod_min :: proc "contextless" (s:^Source,q:^Quad,i:int) -> u8 {
    depth,_:=quad_coord(q,i)
    if depth==0 {return 0}
    level:=s.kind==.Heightfield?max(depth,COARSE_LEVEL):depth
    return min(u8(level),node_lod_max(s,q,i))
}
