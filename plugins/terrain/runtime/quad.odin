package terrain

import "mirai:std/base"

// The tree of the pieces of a source: its leaves are the chunks, in the
// order of chunk_index, and above them the nodes of each depth, in rows, up
// to its roots. A node covers the chunks of its children. A Heightfield has a
// quadtree over x and z, up to one root that covers every chunk; a node of
// it is of lower resolution. A Volume has an octree, as deep as a node of
// VOLUME_NODE_CELLS cells a side allows and of one depth at least, with many
// roots: a node of it is the
// surface of its chunks as one mesh, which the renderer draws at the detail
// the view asks for (the levels of its clusters). Every piece a terrain shows
// is a node of the tree: a chunk, or a node above.

QUAD_DEPTH_MAX :: 13
// The cells a side of the largest node of a Volume: what one build extracts and gives its levels.
VOLUME_NODE_CELLS :: 64

Quad :: struct {
    depth:int,                       // of the roots: 1 or more
    counts:[QUAD_DEPTH_MAX+1][2]int, // nodes along X and Z of each depth
    tall:[QUAD_DEPTH_MAX+1]int,      // and along Y: 1 for a Heightfield
    first:[QUAD_DEPTH_MAX+2]int,     // index of the first node of each depth; past the roots, the count of every node
}

quad_of :: proc "contextless" (s:^Source) -> (q:Quad) {
    n:=chunk_counts(s)
    q.counts[0]={n.x,n.z}
    q.tall[0]=n.y
    q.first[1]=n.x*n.y*n.z
    limit:=QUAD_DEPTH_MAX
    if s.kind==.Volume {
        limit=1
        for limit<QUAD_DEPTH_MAX && int(s.chunk_cells)<<uint(limit+1)<=VOLUME_NODE_CELLS {limit+=1}
    }
    // A terrain of one chunk has a root too: what stays when the chunk goes.
    for q.depth<limit && (q.depth==0 || q.counts[q.depth]!={1,1} || q.tall[q.depth]!=1) {
        c:=q.counts[q.depth]
        t:=q.tall[q.depth]
        q.depth+=1
        q.counts[q.depth]={(c.x+1)/2,(c.y+1)/2}
        q.tall[q.depth]=(t+1)/2
        q.first[q.depth+1]=q.first[q.depth]+q.counts[q.depth].x*q.counts[q.depth].y*q.tall[q.depth]
    }
    return
}

quad_total :: #force_inline proc "contextless" (q:^Quad) -> int {return q.first[q.depth+1]}

quad_depth :: proc "contextless" (q:^Quad,index:int) -> int {
    for d in 0..=q.depth {if index<q.first[d+1] {return d}}
    return -1
}

// The depth of a node and its place among those of its depth: x, y and z.
quad_coord3 :: proc "contextless" (q:^Quad,index:int) -> (depth:int,coord:[3]int) {
    depth=quad_depth(q,index)
    if depth<0 {return}
    local:=index-q.first[depth]
    n,t:=q.counts[depth],q.tall[depth]
    return depth,{local%n.x,local/n.x%t,local/(n.x*t)}
}

// The depth of a node and its place over x and z among those of its depth.
quad_coord :: proc "contextless" (q:^Quad,index:int) -> (depth:int,coord:[2]int) {
    c:[3]int
    depth,c=quad_coord3(q,index)
    return depth,c.xz
}

quad_index3 :: proc "contextless" (q:^Quad,depth:int,coord:[3]int) -> int {
    if depth<0 || depth>q.depth {return -1}
    n,t:=q.counts[depth],q.tall[depth]
    if coord.x<0 || coord.y<0 || coord.z<0 || coord.x>=n.x || coord.y>=t || coord.z>=n.y {return -1}
    return q.first[depth]+coord.x+n.x*(coord.y+t*coord.z)
}

// A node of the lowest layer by its place over x and z: any node of a Heightfield.
quad_index :: proc "contextless" (q:^Quad,depth:int,coord:[2]int) -> int {
    return quad_index3(q,depth,{coord.x,0,coord.y})
}

// -1 for a root.
quad_parent :: proc "contextless" (q:^Quad,index:int) -> int {
    depth,coord:=quad_coord3(q,index)
    if depth<0 || depth>=q.depth {return -1}
    return quad_index3(q,depth+1,coord/2)
}

// -1 where a child would be past the edge of the source, and for a chunk:
// the four of the lower layer first, which are all a Heightfield has.
quad_children :: proc "contextless" (q:^Quad,index:int) -> (children:[8]int) {
    children={-1,-1,-1,-1,-1,-1,-1,-1}
    depth,coord:=quad_coord3(q,index)
    if depth<=0 {return}
    for i in 0..<8 {children[i]=quad_index3(q,depth-1,coord*2+{i&1,(i>>2)&1,(i>>1)&1})}
    return
}

// The chunks a node covers, from low to before high, along x, y and z.
quad_chunks3 :: proc "contextless" (q:^Quad,index:int) -> (low,high:[3]int) {
    depth,coord:=quad_coord3(q,index)
    if depth<0 {return}
    span:=1<<uint(depth)
    low=coord*span
    high={min(low.x+span,q.counts[0].x),min(low.y+span,q.tall[0]),min(low.z+span,q.counts[0].y)}
    return
}

// The chunks a node covers over x and z, from low to before high.
quad_chunks :: proc "contextless" (q:^Quad,index:int) -> (low,high:[2]int) {
    a,b:=quad_chunks3(q,index)
    return a.xz,b.xz
}

// The samples of the X/Z grid a node covers, inclusive.
quad_region :: proc "contextless" (s:^Source,q:^Quad,index:int) -> (low,high:[2]int) {
    a,b:=quad_chunks(q,index)
    cells:=int(s.chunk_cells)
    return a*cells,{min(b.x*cells,int(s.samples.x)-1),min(b.y*cells,int(s.samples.z)-1)}
}

// The samples a node covers along x, y and z, inclusive.
quad_region3 :: proc "contextless" (s:^Source,q:^Quad,index:int) -> (low,high:[3]int) {
    a,b:=quad_chunks3(q,index)
    cells:=int(s.chunk_cells)
    low=a*cells
    for axis in 0..<3 {high[axis]=min(b[axis]*cells,int(s.samples[axis])-1)}
    return
}

// The coordinate of a chunk, or of the first chunk of a node: where its
// entity stands (chunk_origin).
quad_place :: proc "contextless" (s:^Source,q:^Quad,index:int) -> [3]i32 {
    if index<q.first[1] {return chunk_coord(s,index)}
    low,_:=quad_chunks3(q,index)
    return {i32(low.x),i32(low.y),i32(low.z)}
}

// The local box of node i: its region of the source, with the heights its
// samples reach (ranges) for a Heightfield.
node_box :: proc "contextless" (s:^Source,q:^Quad,ranges:[][2]f32,i:int) -> (low,high:[3]f32) {
    a,b:=quad_region3(s,q,i)
    low,high=source_box(s,a,b)
    if s.kind==.Heightfield && i<len(ranges) {low.y,high.y=ranges[i].x,ranges[i].y}
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
    // The Heightfields beside it (-X, +X, -Z, +Z, adjacency.odin): a chunk past a
    // side is one of theirs, so both build the border they share alike.
    sides:[4]Border_Side,
}
// The chunks of a Heightfield beside a side: chunk c past it is chunk c-shift
// of these, shift along the side and across it the width of this grid.
Border_Side :: struct {
    counts:[2]int,
    levels:[]u8, // nil: none
    deep:[]bool,
    shift:[2]int,
}

// The level of chunk x,z of the grid or of a terrain beside it, and whether it
// is deep; ok false for none.
@(private)
border_chunk :: proc "contextless" (b:^Border_Levels,x,z:int) -> (level:u8,deep,ok:bool) {
    if x>=0 && z>=0 && x<b.counts.x && z<b.counts.y {
        i:=x+b.counts.x*z
        return b.levels[i],b.deep==nil || b.deep[i],true
    }
    side:=-1
    switch {
    case x<0 && z>=0 && z<b.counts.y:          side=0
    case x>=b.counts.x && z>=0 && z<b.counts.y: side=1
    case z<0 && x>=0 && x<b.counts.x:          side=2
    case z>=b.counts.y && x>=0 && x<b.counts.x: side=3
    }
    if side<0 || b.sides[side].levels==nil {return}
    o:=&b.sides[side]
    p:=[2]int{x,z}-o.shift
    if p.x<0 || p.y<0 || p.x>=o.counts.x || p.y>=o.counts.y {return}
    i:=p.x+o.counts.x*p.y
    return o.levels[i],o.deep==nil || o.deep[i],true
}

// A segment between two chunks: the finer of them; 255 where neither is.
@(private)
border_segment :: proc "contextless" (b:^Border_Levels,a_x,a_z,c_x,c_z:int) -> u8 {
    level:=u8(255)
    deep:=true
    for p in ([2][2]int{{a_x,a_z},{c_x,c_z}}) {
        at,is_deep,ok:=border_chunk(b,p.x,p.y)
        if !ok {continue}
        level=min(level,at)
        if !is_deep {deep=false}
    }
    if level==255 {return 255}
    if !deep {level=max(level,COARSE_LEVEL)}
    return level
}

// The segment of the line of the chunk grid at x=gx, along row z.
border_vertical :: #force_inline proc "contextless" (b:^Border_Levels,gx,z:int) -> u8 {
    level:=border_segment(b,gx-1,z,gx,z)
    return level==255?0:level
}
// The segment of the line of the chunk grid at z=gz, along column x.
border_horizontal :: #force_inline proc "contextless" (b:^Border_Levels,gz,x:int) -> u8 {
    level:=border_segment(b,x,gz-1,x,gz)
    return level==255?0:level
}

// A point of the chunk grid: the finest of the segments that meet there, of
// this grid or of a terrain beside it.
border_corner :: proc "contextless" (b:^Border_Levels,gx,gz:int) -> u8 {
    level:=u8(255)
    level=min(level,border_segment(b,gx-1,gz-1,gx,gz-1))
    level=min(level,border_segment(b,gx-1,gz,gx,gz))
    level=min(level,border_segment(b,gx-1,gz-1,gx-1,gz))
    level=min(level,border_segment(b,gx,gz-1,gx,gz))
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
    for side,at in lod.sides {append(&border.sides[at],side)}
    append(&border.corners[0],lod.corners[0],lod.corners[2]);append(&border.corners[1],lod.corners[1],lod.corners[3])
    append(&border.corners[2],lod.corners[0],lod.corners[1]);append(&border.corners[3],lod.corners[2],lod.corners[3])
}

// The coarsest level of node i of a Heightfield: as chunk_lod_max, over its
// region.
node_lod_max :: proc "contextless" (s:^Source,q:^Quad,i:int) -> u8 {
    if s.kind==.Volume {return 0}
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
    if depth==0 || s.kind==.Volume {return 0}
    return min(u8(max(depth,COARSE_LEVEL)),node_lod_max(s,q,i))
}
