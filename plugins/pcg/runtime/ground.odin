package pcg

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// The ground the points of each Pcg_Graph stand on, in the frame of its
// cells: a tile of heights over each cell it wants (Pcg_Ground_Owner.cells),
// with the weights of the layers of the ground there, read from
// core.Ground_Queries without any physics (ground_read.odin), and where an
// excluding Pcg_Zone keeps points out of it. Each tile it changes raises its
// revision, and the generator builds again the cells whose tile changed.
// Every tile is on the fine grid of its owner near the sources; far from them
// a tile keeps only the samples around the points that may show there
// (sparse), which stand and pass their rules as on a whole tile. A cell
// waiting for its first read has a coarse tile, SAMPLES_MIN a side, until it
// is read. Without a ground in the world the plane y = 0 of the frame is the
// ground. It is the one ground cache of the procedural libraries: foliage
// reads it too.
@(storage)
Pcg_Ground :: struct {
    owners:[dynamic]Pcg_Ground_Owner,
    data:[2]u64,       // Pcg_Data: entries made and loads
    seen:[3]core.Seen, // the tables of Pcg_Graph, World_Transform and Volume
    streamed:u64,      // the revision of the streaming sources
    queue:[dynamic]Pcg_Ground_Task, // tiles to read, the next one last (queue_order)
    unordered:bool,                 // some were asked since the queue was ordered
    spent:int,                      // samples read in the frame so far (GROUND_SAMPLES)
    zones:[dynamic]Zone_Seen,       // where the excluding zones were when the tiles under them were last asked for
    zone_seen:[3]core.Seen,         // the tables of Pcg_Zone, Volume and Spline
}
Pcg_Ground_Owner :: struct {
    entity:core.Entity,
    cell_size:f32,               // m across its cells
    samples:u32,                 // per side of a whole tile; a cell is samples-1 steps across
    revision:u32,                // raised with the revision of any of its tiles
    layers:[dynamic]Ground_Layers, // what the weights of its samples are of, at most GROUND_LAYERS_MAX
    tiles:[dynamic]Pcg_Ground_Tile, // in the order of their coordinates, z then x
    pools:[dynamic]Ground_Pool,  // the samples of its tiles, a pool for each count of them
    sparse:[dynamic]Sparse_Tile, // the samples of its sparse tiles, one each
    cells:[dynamic]Ground_Want,  // the cells it wants a tile of, in their order: those the generator places in
    cells_revision:u32,          // raised when they change
    frame:mm.Transform,          // of its cells when they were last asked for
    epoch:u64,                   // and of its entry of Pcg_Data
    loads:u32,
    domain:u64,                  // the hash of where its Volume was
}
// A cell an owner wants, and how near the sources came to it, in reaches of its source.
Ground_Want :: struct {
    coord:[2]i32,
    near:f32,
}
Pcg_Ground_Tile :: struct {
    coord:[2]i32,
    revision:u32,
    pool,block:u32, // where its samples are: a block of a pool, or with SPARSE_POOL the sparse tile of that index
}
SPARSE_POOL :: max(u32)
// Some samples of the fine grid of the owner over a tile: those keys names
// (x first, in order), with their heights and weights, and where points are
// kept out of it.
Sparse_Tile :: struct {
    coord:[2]i32,
    keys:[dynamic]u16,
    heights:[dynamic]f32,
    weights:[dynamic]Layer_Weights,
    kept:[KEPT_WORDS]u64,
}
// The samples of the tiles of an owner with the same count per side, a block
// for each: a tile that takes another count leaves its block to the last.
Ground_Pool :: struct {
    samples:u32,
    heights:[dynamic]f32,           // samples*samples of each block, x first; NaN where there is no ground
    weights:[dynamic]Layer_Weights, // of each height
    kept:[dynamic]u64,              // KEPT_WORDS of each block (Pcg_Ground_Cell.kept)
    coords:[dynamic][2]i32,         // the tile of each block
}

// The materials of the four weights of a ground (core.Ground_Hit.layers).
Ground_Layers :: [4]base.Asset_Id
GROUND_LAYERS_MAX :: 256 // Ground_Layers of an owner, which a sample names by a byte

// The weights of the layers of the ground at a sample, adding up to 255, and
// which of the Ground_Layers of its owner they are of: all 0 where it has no
// layers or there is no ground.
Layer_Weights :: struct {
    weights:[4]u8,
    layers:u8,
}

// Of each Ground_Layers of an owner, the bits of the weights whose material a rule names.
Layer_Mask :: [GROUND_LAYERS_MAX]u8

KEPT_SIDE :: 64 // squares per side of a cell where points are kept out or not, as its centre is
KEPT_WORDS :: KEPT_SIDE*KEPT_SIDE/64
NO_GROUND :: f32(0h7fc00000)

// The ground under a cell, in the frame of its owner: heights on a grid of
// samples by samples points over the cell, x first, NaN where there is none,
// and the weights of the layers of the ground at each; where excluding zones
// keep points out (KEPT_SIDE squares per side, a bit each). absent: none is
// known (not read yet, or no ground there), and nothing stands there. With
// keys it holds only the samples keys names (in order), and where one of the
// four around a point is not held the point has no ground.
Pcg_Ground_Cell :: struct {
    cell_size:f32,
    samples:int,
    heights:[]f32,
    weights:[]Layer_Weights,
    layers:[]Ground_Layers,
    kept:[]u64,
    keys:[]u16,
    absent:bool,
}

// The cells whose ground someone needs fine before it shows points there:
// the editor asks for those under its brush. pcg_ground takes them.
@(storage,queue)
Pcg_Ground_Requests :: struct {cells:core.Queue(Ground_Request)}
Ground_Request :: struct {entity:core.Entity,coord:[2]i32}

ground_request :: proc(requests:^Pcg_Ground_Requests,entity:core.Entity,coord:[2]i32) {
    for held in requests.cells.items {if held.entity==entity && held.coord==coord {return}}
    core.offer(&requests.cells,Ground_Request{entity,coord})
}

// Bytes the ground cache holds for an owner, by the room of its lists: what a
// copy of the world (Play, a rollback) copies of it.
ground_owner_bytes :: proc "contextless" (owner:^Pcg_Ground_Owner) -> (bytes:int) {
    room :: #force_inline proc "contextless" (list:[dynamic]$T) -> int {return cap(list)*size_of(T)}
    bytes=size_of(Pcg_Ground_Owner)+room(owner.layers)+room(owner.tiles)+room(owner.pools)+room(owner.sparse)+room(owner.cells)
    for &pool in owner.pools {bytes+=room(pool.heights)+room(pool.weights)+room(pool.kept)+room(pool.coords)}
    for &tile in owner.sparse {bytes+=room(tile.keys)+room(tile.heights)+room(tile.weights)}
    return
}

// Bytes the whole ground cache holds, owners and queues.
ground_bytes :: proc "contextless" (g:^Pcg_Ground) -> (bytes:int) {
    if g==nil {return}
    bytes=size_of(Pcg_Ground)+(cap(g.owners)-len(g.owners))*size_of(Pcg_Ground_Owner)+cap(g.queue)*size_of(Pcg_Ground_Task)+cap(g.zones)*size_of(Zone_Seen)
    for &owner in g.owners {bytes+=ground_owner_bytes(&owner)}
    return
}

ground_owner :: proc "contextless" (g:^Pcg_Ground,entity:core.Entity) -> ^Pcg_Ground_Owner {
    if g==nil {return nil}
    for &owner in g.owners {if owner.entity==entity {return &owner}}
    return nil
}

// The tile of a cell; -1 when the owner has none.
ground_tile_find :: proc "contextless" (owner:^Pcg_Ground_Owner,coord:[2]i32) -> int {
    at:=coord_lower(owner.tiles[:],coord)
    return at<len(owner.tiles) && owner.tiles[at].coord==coord?at:-1
}

// Whether the owner wants a tile of a cell, and how near the sources are to it.
ground_wants :: proc "contextless" (owner:^Pcg_Ground_Owner,coord:[2]i32) -> (near:f32,wanted:bool) {
    at:=coord_lower(owner.cells[:],coord)
    if at<len(owner.cells) && owner.cells[at].coord==coord {return owner.cells[at].near,true}
    return
}

// The ground of a cell as the generator reads it: absent when no tile is
// known; revision, that of its tile.
ground_cell :: proc "contextless" (owner:^Pcg_Ground_Owner,coord:[2]i32) -> (ground:Pcg_Ground_Cell,revision:u32) {
    if owner==nil {return {absent=true},0}
    at:=ground_tile_find(owner,coord)
    if at<0 {return {absent=true},0}
    tile:=owner.tiles[at]
    if tile.pool==SPARSE_POOL {
        sparse:=&owner.sparse[tile.block]
        if owner.samples<2 {return {absent=true},0}
        return Pcg_Ground_Cell{cell_size=owner.cell_size,samples=int(owner.samples),heights=sparse.heights[:],weights=sparse.weights[:],layers=owner.layers[:],kept=sparse.kept[:],keys=sparse.keys[:]},tile.revision
    }
    pool:=&owner.pools[tile.pool]
    n:=int(pool.samples)
    if n<2 {return {absent=true},0}
    first:=int(tile.block)*n*n
    return Pcg_Ground_Cell{cell_size=owner.cell_size,samples=n,heights=pool.heights[first:][:n*n],weights=pool.weights[first:][:n*n],layers=owner.layers[:],kept=pool.kept[int(tile.block)*KEPT_WORDS:][:KEPT_WORDS]},tile.revision
}

// The samples per side of the grid of the tile of a cell; 0 without one.
ground_tile_samples :: proc "contextless" (owner:^Pcg_Ground_Owner,coord:[2]i32) -> u32 {
    if owner==nil {return 0}
    at:=ground_tile_find(owner,coord)
    if at<0 {return 0}
    return owner.tiles[at].pool==SPARSE_POOL?owner.samples:owner.pools[owner.tiles[at].pool].samples
}

// Whether the tile of a cell keeps only some of its samples.
ground_tile_sparse :: proc "contextless" (owner:^Pcg_Ground_Owner,coord:[2]i32) -> bool {
    if owner==nil {return false}
    at:=ground_tile_find(owner,coord)
    return at>=0 && owner.tiles[at].pool==SPARSE_POOL
}

// The four samples of a grid of samples a side around x and z from the
// corner of its cell, x first, and how far the point is between them; past
// the border, as at the nearest point of it.
ground_around :: proc "contextless" (cell_size:f32,samples:int,x,z:f32) -> (corners:[4]int,fu,fv:f32) {
    step:=cell_size/f32(samples-1)
    u,v:=clamp(x/step,0,f32(samples-1)),clamp(z/step,0,f32(samples-1))
    if u!=u {u=0}
    if v!=v {v=0}
    c,r:=min(int(u),samples-2),min(int(v),samples-2)
    return {r*samples+c,r*samples+c+1,(r+1)*samples+c,(r+1)*samples+c+1},u-f32(c),v-f32(r)
}

// Where the ground keeps the four samples around x and z; false when it does not keep one.
@(private)
ground_held :: proc "contextless" (g:Pcg_Ground_Cell,x,z:f32) -> (at:[4]int,fu,fv:f32,ok:bool) {
    at,fu,fv=ground_around(g.cell_size,g.samples,x,z)
    if len(g.keys)==0 {return at,fu,fv,len(g.heights)>=g.samples*g.samples}
    for &k in at {
        low,high:=0,len(g.keys)
        for low<high {mid:=(low+high)/2;if int(g.keys[mid])<k {low=mid+1} else {high=mid}}
        if low==len(g.keys) || int(g.keys[low])!=k || low>=len(g.heights) {return}
        k=low
    }
    return at,fu,fv,true
}

// The height and normal of the ground at x and z from the corner of its
// cell, between the four samples around it; false where one has no ground.
ground_at :: proc "contextless" (g:Pcg_Ground_Cell,x,z:f32) -> (height:f32,normal:[3]f32,ok:bool) {
    if g.samples<2 || g.absent {return}
    step:=g.cell_size/f32(g.samples-1)
    at,fu,fv,held:=ground_held(g,x,z)
    if !held {return}
    a,b,d,e:=g.heights[at[0]],g.heights[at[1]],g.heights[at[2]],g.heights[at[3]]
    if a-a!=0 || b-b!=0 || d-d!=0 || e-e!=0 {return}
    height=a+(b-a)*fu+(d-a)*fv+(a-b-d+e)*fu*fv
    dx:=((b-a)+(a-b-d+e)*fv)/step
    dz:=((d-a)+(a-b-d+e)*fu)/step
    normal=linalg.normalize([3]f32{-dx,1,-dz})
    return height,normal,true
}

// Of each Ground_Layers of an owner, the bits of the weights of the materials a rule names.
layer_mask :: proc "contextless" (r:Pcg_Ground_Rule,layers:[]Ground_Layers) -> (mask:Layer_Mask) {
    for set,k in layers[:min(len(layers),GROUND_LAYERS_MAX)] {
        for material,i in set {
            if material=={} {continue}
            for named in r.layers {if named==material {mask[k]|=1<<u8(i)}}
        }
    }
    return
}

// The weight of the layers of a mask at x and z from the corner of its cell,
// from 0 to 1, between the four samples around it; false where they are not
// known or one has no layers.
ground_layer_weight :: proc "contextless" (g:Pcg_Ground_Cell,mask:^Layer_Mask,x,z:f32) -> (weight:f32,ok:bool) {
    if g.samples<2 || len(g.weights)<(len(g.keys)>0?len(g.keys):g.samples*g.samples) {return}
    at,fu,fv,held:=ground_held(g,x,z)
    if !held {return}
    corners:=[4]Layer_Weights{g.weights[at[0]],g.weights[at[1]],g.weights[at[2]],g.weights[at[3]]}
    share:=[4]f32{(1-fu)*(1-fv),fu*(1-fv),(1-fu)*fv,fu*fv}
    for corner,k in corners {
        w:=corner.weights
        if int(w[0])+int(w[1])+int(w[2])+int(w[3])==0 {return}
        bits:=mask[corner.layers]
        named:=0
        for i in 0..<4 {if bits&(1<<u8(i))!=0 {named+=int(w[i])}}
        weight+=share[k]*f32(named)/255
    }
    return weight,true
}

// Whether points are kept out at x and z from the corner of its cell; past
// its border, as the nearest square inside it is.
ground_kept_out :: proc "contextless" (g:Pcg_Ground_Cell,x,z:f32) -> bool {
    if len(g.kept)<KEPT_WORDS || !(g.cell_size>0) {return false}
    step:=g.cell_size/KEPT_SIDE
    u,v:=x/step,z/step
    if u!=u {u=0}
    if v!=v {v=0}
    k:=int(clamp(v,0,KEPT_SIDE-1))*KEPT_SIDE+int(clamp(u,0,KEPT_SIDE-1))
    return g.kept[k>>6]>>(uint(k)&63)&1!=0
}

// The cell a point of the frame is in, and where it is from its corner.
cell_of :: proc "contextless" (cell_size:f32,position:[2]f32) -> (coord:[2]i32,local:[2]f32) {
    for axis in 0..<2 {
        v:=position[axis]/cell_size
        if !(abs(v)<f32(COORD_MAX+1)) {continue}
        c:=i32(math.floor(v))
        local[axis]=position[axis]-f32(c)*cell_size
        // What rounds to the far side belongs to the cell after.
        if local[axis]>=cell_size {c+=1;local[axis]-=cell_size}
        if local[axis]<0 {local[axis]=0}
        coord[axis]=c
    }
    return
}

cell_corner :: proc "contextless" (cell_size:f32,coord:[2]i32) -> [3]f32 {return {f32(coord.x)*cell_size,0,f32(coord.y)*cell_size}}

// The index of a Ground_Layers in those of an owner, added when it is not
// there; false when the owner has GROUND_LAYERS_MAX or no memory for more.
@(private)
ground_layers_index :: proc(owner:^Pcg_Ground_Owner,layers:Ground_Layers) -> (index:u8,ok:bool) {
    for held,i in owner.layers {if held==layers {return u8(i),true}}
    if len(owner.layers)>=GROUND_LAYERS_MAX {return}
    if _,error:=append(&owner.layers,layers);error!=nil {return}
    return u8(len(owner.layers)-1),true
}

// The whole tile of a cell to write, made when it is not there or has
// another count of samples (its heights NaN, its weights 0). The writer
// raises its revision and the owner's.
@(private)
ground_tile :: proc(owner:^Pcg_Ground_Owner,coord:[2]i32,samples:u32) -> (heights:[]f32,weights:[]Layer_Weights,kept:[]u64,tile:^Pcg_Ground_Tile) {
    at:=coord_lower(owner.tiles[:],coord)
    found:=at<len(owner.tiles) && owner.tiles[at].coord==coord
    sparse:=found && owner.tiles[at].pool==SPARSE_POOL
    n:=samples
    if n<2 {return}
    if !found || sparse || owner.pools[owner.tiles[at].pool].samples!=n {
        p:=-1
        for pool,i in owner.pools {if pool.samples==n {p=i;break}}
        if p<0 {
            if _,error:=append(&owner.pools,Ground_Pool{samples=n});error!=nil {return}
            p=len(owner.pools)-1
        }
        block,made:=pool_block_add(&owner.pools[p],coord)
        if !made {return}
        if found {
            tile_samples_free(owner,owner.tiles[at])
            owner.tiles[at].pool,owner.tiles[at].block=u32(p),block
        } else if _,error:=inject_at(&owner.tiles,at,Pcg_Ground_Tile{coord=coord,pool=u32(p),block=block});error!=nil {
            pool_block_free(owner,u32(p),block)
            return
        }
    }
    tile=&owner.tiles[at]
    pool:=&owner.pools[tile.pool]
    side:=int(n)*int(n)
    first:=int(tile.block)*side
    return pool.heights[first:][:side],pool.weights[first:][:side],pool.kept[int(tile.block)*KEPT_WORDS:][:KEPT_WORDS],tile
}

// Writes the sparse tile of a cell with the samples keys names: false when
// it held them already, or memory ran out and it keeps what it had. It raises
// the revision of the tile and the owner's.
@(private)
ground_sparse_write :: proc(owner:^Pcg_Ground_Owner,coord:[2]i32,keys:[]u16,heights:[]f32,weights:[]Layer_Weights,kept:[]u64) -> bool {
    at:=coord_lower(owner.tiles[:],coord)
    found:=at<len(owner.tiles) && owner.tiles[at].coord==coord
    if found && owner.tiles[at].pool==SPARSE_POOL {
        held:=&owner.sparse[owner.tiles[at].block]
        if slice.equal(held.keys[:],keys) && same_heights(held.heights[:],heights) && slice.equal(held.weights[:],weights) && slice.equal(held.kept[:],kept) {return false}
        if resize(&held.keys,len(keys))!=nil || resize(&held.heights,len(keys))!=nil || resize(&held.weights,len(keys))!=nil {return false}
        copy(held.keys[:],keys);copy(held.heights[:],heights);copy(held.weights[:],weights);copy(held.kept[:],kept)
    } else {
        made:=Sparse_Tile{coord=coord}
        e0,e1,e2,e3:runtime.Allocator_Error
        made.keys,e0=make([dynamic]u16,len(keys))
        made.heights,e1=make([dynamic]f32,len(keys))
        made.weights,e2=make([dynamic]Layer_Weights,len(keys))
        if e0==nil && e1==nil && e2==nil {_,e3=append(&owner.sparse,made)}
        if e0!=nil || e1!=nil || e2!=nil || e3!=nil {
            delete(made.keys);delete(made.heights);delete(made.weights)
            return false
        }
        copy(made.keys[:],keys);copy(made.heights[:],heights);copy(made.weights[:],weights)
        block:=u32(len(owner.sparse)-1)
        copy(owner.sparse[block].kept[:],kept)
        if found {
            tile_samples_free(owner,owner.tiles[at])
            owner.tiles[at].pool,owner.tiles[at].block=SPARSE_POOL,block
        } else if _,error:=inject_at(&owner.tiles,at,Pcg_Ground_Tile{coord=coord,pool=SPARSE_POOL,block=block});error!=nil {
            sparse_free(owner,block)
            return false
        }
    }
    owner.revision+=1
    owner.tiles[at].revision=owner.revision
    return true
}

@(private)
tile_samples_free :: proc(owner:^Pcg_Ground_Owner,tile:Pcg_Ground_Tile) {
    if tile.pool==SPARSE_POOL {sparse_free(owner,tile.block)} else {pool_block_free(owner,tile.pool,tile.block)}
}

// Lets go of a sparse tile: the last takes its place.
@(private)
sparse_free :: proc(owner:^Pcg_Ground_Owner,block:u32) {
    gone:=&owner.sparse[block]
    delete(gone.keys);delete(gone.heights);delete(gone.weights)
    last:=len(owner.sparse)-1
    if int(block)!=last {
        owner.sparse[block]=owner.sparse[last]
        if at:=ground_tile_find(owner,owner.sparse[block].coord);at>=0 {owner.tiles[at].block=block}
    }
    pop(&owner.sparse)
}

// A block at the end of a pool for the tile of coord, without ground.
@(private)
pool_block_add :: proc(pool:^Ground_Pool,coord:[2]i32) -> (block:u32,ok:bool) {
    side:=int(pool.samples)*int(pool.samples)
    first:=len(pool.heights)
    // They grow by doubling: tile after tile does not copy them all each time.
    if first+side>cap(pool.heights) && reserve(&pool.heights,max(first+side,2*cap(pool.heights)))!=nil {return}
    if first+side>cap(pool.weights) && reserve(&pool.weights,max(first+side,2*cap(pool.weights)))!=nil {return}
    words:=len(pool.kept)
    if words+KEPT_WORDS>cap(pool.kept) && reserve(&pool.kept,max(words+KEPT_WORDS,2*cap(pool.kept)))!=nil {return}
    if resize(&pool.heights,first+side)!=nil {return}
    if resize(&pool.weights,first+side)!=nil {base.truncate(&pool.heights,first);return}
    if resize(&pool.kept,words+KEPT_WORDS)!=nil {base.truncate(&pool.heights,first);base.truncate(&pool.weights,first);return}
    if _,error:=append(&pool.coords,coord);error!=nil {base.truncate(&pool.heights,first);base.truncate(&pool.weights,first);base.truncate(&pool.kept,words);return}
    for &h in pool.heights[first:] {h=NO_GROUND}
    for &w in pool.weights[first:] {w={}}
    for &w in pool.kept[words:] {w=0}
    return u32(len(pool.coords)-1),true
}

// Lets go of a block of a pool: the last block takes its place.
@(private)
pool_block_free :: proc(owner:^Pcg_Ground_Owner,p,block:u32) {
    pool:=&owner.pools[p]
    side:=int(pool.samples)*int(pool.samples)
    last:=len(pool.coords)-1
    if int(block)!=last {
        copy(pool.heights[int(block)*side:][:side],pool.heights[last*side:][:side])
        copy(pool.weights[int(block)*side:][:side],pool.weights[last*side:][:side])
        copy(pool.kept[int(block)*KEPT_WORDS:][:KEPT_WORDS],pool.kept[last*KEPT_WORDS:][:KEPT_WORDS])
        moved:=pool.coords[last]
        pool.coords[block]=moved
        if at:=ground_tile_find(owner,moved);at>=0 {owner.tiles[at].block=block}
    }
    base.truncate(&pool.heights,last*side)
    base.truncate(&pool.weights,last*side)
    base.truncate(&pool.kept,last*KEPT_WORDS)
    base.truncate(&pool.coords,last)
}

ground_owner_destroy :: proc(owner:^Pcg_Ground_Owner) {
    for &pool in owner.pools {delete(pool.heights);delete(pool.weights);delete(pool.kept);delete(pool.coords)}
    for &sparse in owner.sparse {delete(sparse.keys);delete(sparse.heights);delete(sparse.weights)}
    delete(owner.pools);delete(owner.tiles);delete(owner.sparse);delete(owner.layers);delete(owner.cells)
    owner^={}
}

// Takes the tile of index at away: its cell has no ground known again.
@(private)
ground_tile_remove :: proc(owner:^Pcg_Ground_Owner,at:int) {
    tile:=owner.tiles[at]
    ordered_remove(&owner.tiles,at)
    tile_samples_free(owner,tile)
    owner.revision+=1
}

// Forgets every tile of an owner, whose tiles take samples from here on.
@(private)
ground_owner_reset :: proc(owner:^Pcg_Ground_Owner,samples:u32,cell_size:f32) {
    if len(owner.tiles)>0 {owner.revision+=1}
    clear(&owner.tiles)
    for &pool in owner.pools {clear(&pool.heights);clear(&pool.weights);clear(&pool.kept);clear(&pool.coords)}
    for &sparse in owner.sparse {delete(sparse.keys);delete(sparse.heights);delete(sparse.weights)}
    clear(&owner.sparse)
    clear(&owner.layers)
    owner.samples,owner.cell_size=samples,cell_size
}

pcg_ground_destroy :: proc(g:^Pcg_Ground) {
    for &owner in g.owners {ground_owner_destroy(&owner)}
    delete(g.owners);delete(g.queue);delete(g.zones)
    g^={}
}

@(private)
same_heights :: proc "contextless" (a,b:[]f32) -> bool {
    if len(a)!=len(b) {return false}
    for value,i in a {
        other:=b[i]
        if value!=other && !(value-value!=0 && other-other!=0) {return false}
    }
    return true
}
