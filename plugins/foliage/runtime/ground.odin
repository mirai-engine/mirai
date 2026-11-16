package foliage

import "base:runtime"
import "core:slice"
import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// The ground the instances of each Foliage stand on, in the space of its
// entity: a tile of heights over each cell, with the weights of the layers of
// the ground there, read from core.Ground_Queries (ground_read.odin), and
// where a Foliage_Keep_Out keeps foliage out of it (keep_out.odin). Each
// tile it changes raises its revision, and foliage builds again the cells
// whose tile changed. Every tile is on the fine grid of its owner; far from
// where it is seen a tile keeps only the samples around the instances that
// may show there (sparse), which stand and pass their rules as they do on a
// whole tile: where an instance is does not depend on how far it is seen
// from. A cell without a tile (not read yet, or no ground
// covers it) has no ground: its generated instances are not there. Without a
// ground in the world there are no owners, and the plane y = 0 of each entity
// is its ground.
@(storage)
Foliage_Ground :: struct {
    owners:[dynamic]Ground_Owner,
    foliage:[2]u64,    // Foliage_Data: entries made and loads
    seen:[2]core.Seen, // the tables of Foliage and World_Transform
    streamed:u64,      // the revision of the streaming sources
    queue:[dynamic]Ground_Task, // tiles to read, the next one last (queue_order)
    unordered:bool,             // some were asked since the queue was ordered
    keep_outs:[dynamic]Keep_Out_Seen, // where they were when the tiles under them were last asked for
    keep_seen:[4]core.Seen,           // the tables of Foliage_Keep_Out, Volume, Spline and Collider
}
Ground_Owner :: struct {
    entity:core.Entity,
    samples:u32,                // per side of a tile written without saying how many; a cell is samples-1 steps across
    revision:u32,               // raised with the revision of any of its tiles
    layers:[dynamic]Ground_Layers, // what the weights of its samples are of: those of each ground under it, at most LAYERS_MAX
    tiles:[dynamic]Ground_Tile, // in the order of their coordinates, z then x
    pools:[dynamic]Ground_Pool, // the samples of its tiles, a pool for each count of them
    sparse:[dynamic]Sparse_Tile, // the samples of its sparse tiles, one each
    transform:mm.Transform,     // of its entity when its tiles were last asked for
    epoch:u64,                  // and of its entry of Foliage_Data
    loads:u32,
}
Ground_Tile :: struct {
    coord:[2]i32,
    revision:u32,
    pool,block:u32, // where its samples are: a block of a pool, or with SPARSE_POOL the sparse tile of that index
}
SPARSE_POOL :: max(u32)
// Some samples of the fine grid of the owner over a tile: those keys names
// (x first, in order), with their heights and weights, and where foliage is
// kept out of it.
Sparse_Tile :: struct {
    coord:[2]i32,
    keys:[dynamic]u16,
    heights:[dynamic]f32,
    weights:[dynamic]Layer_Weights,
    kept:[KEEP_OUT_WORDS]u64, // Ground_Cell.kept
}
// The samples of the tiles of an owner with the same count per side, a block
// for each: a tile that takes another count leaves its block to the last.
Ground_Pool :: struct {
    samples:u32,             // per side
    heights:[dynamic]f32,    // samples*samples of each block, x first; NaN where there is no ground
    weights:[dynamic]Layer_Weights, // of each height
    kept:[dynamic]u64,       // KEEP_OUT_WORDS of each block (Ground_Cell.kept)
    coords:[dynamic][2]i32,  // the tile of each block
}

// The materials of the four weights of a ground (core.Ground_Hit.layers):
// the layers of a terrain, in its order; none for a weight it does not have.
Ground_Layers :: [4]base.Asset_Id
LAYERS_MAX :: 256 // Ground_Layers of an owner, which a sample names by a byte

// The weights of the layers of the ground at a sample, adding up to 255, and
// which of the Ground_Layers of its owner they are of: all 0 where it has no
// layers or there is no ground.
Layer_Weights :: struct {
    weights:[4]u8,
    layers:u8,
}

// Of each Ground_Layers of an owner, the bits of the weights whose material a rule names.
Layer_Mask :: [LAYERS_MAX]u8

layer_mask :: proc "contextless" (r:Foliage_Rule,layers:[]Ground_Layers) -> (mask:Layer_Mask) {
    for set,k in layers[:min(len(layers),LAYERS_MAX)] {
        for material,i in set {
            if material=={} {continue}
            for named in r.layers {if named==material {mask[k]|=1<<u8(i)}}
        }
    }
    return
}

// The index of a Ground_Layers in those of an owner, added when it is not
// there; false when the owner has LAYERS_MAX or no memory for more.
ground_layers_index :: proc(owner:^Ground_Owner,layers:Ground_Layers) -> (index:u8,ok:bool) {
    for held,i in owner.layers {if held==layers {return u8(i),true}}
    if len(owner.layers)>=LAYERS_MAX {return}
    if _,error:=append(&owner.layers,layers);error!=nil {return}
    return u8(len(owner.layers)-1),true
}

// The cells whose ground someone needs before it shows instances there: the
// editor asks for those under its brush, so that what it paints knows the
// ground. foliage_ground takes them.
@(storage,queue)
Foliage_Ground_Requests :: struct {cells:core.Queue(Ground_Request)}
Ground_Request :: struct {entity:core.Entity,coord:[2]i32}

ground_request :: proc(requests:^Foliage_Ground_Requests,entity:core.Entity,coord:[2]i32) {
    for held in requests.cells.items {if held.entity==entity && held.coord==coord {return}}
    core.offer(&requests.cells,Ground_Request{entity,coord})
}

ground_owner :: proc "contextless" (g:^Foliage_Ground,entity:core.Entity) -> ^Ground_Owner {
    if g==nil {return nil}
    for &owner in g.owners {if owner.entity==entity {return &owner}}
    return nil
}

// The first tile at or after a cell, in their order.
@(private)
ground_tile_lower :: proc "contextless" (owner:^Ground_Owner,coord:[2]i32) -> int {
    low,high:=0,len(owner.tiles)
    for low<high {
        mid:=(low+high)/2
        if coord_before(owner.tiles[mid].coord,coord) {low=mid+1} else {high=mid}
    }
    return low
}

// The tile of a cell; -1 when the owner has none.
ground_tile_find :: proc "contextless" (owner:^Ground_Owner,coord:[2]i32) -> int {
    at:=ground_tile_lower(owner,coord)
    return at<len(owner.tiles) && owner.tiles[at].coord==coord?at:-1
}

// The ground of a cell as cell_expand reads it: absent when no tile is known
// under a Foliage with a ground; the plane without one (owner nil).
ground_cell :: proc "contextless" (owner:^Ground_Owner,coord:[2]i32) -> (ground:Ground_Cell,revision:u32) {
    if owner==nil {return}
    at:=ground_tile_find(owner,coord)
    if at<0 {return {absent=true},0}
    tile:=owner.tiles[at]
    if tile.pool==SPARSE_POOL {
        sparse:=&owner.sparse[tile.block]
        if owner.samples<2 {return}
        return Ground_Cell{samples=int(owner.samples),heights=sparse.heights[:],weights=sparse.weights[:],layers=owner.layers[:],kept=sparse.kept[:],keys=sparse.keys[:]},tile.revision
    }
    pool:=&owner.pools[tile.pool]
    n:=int(pool.samples)
    if n<2 {return}
    first:=int(tile.block)*n*n
    return Ground_Cell{samples=n,heights=pool.heights[first:][:n*n],weights=pool.weights[first:][:n*n],layers=owner.layers[:],kept=pool.kept[int(tile.block)*KEEP_OUT_WORDS:][:KEEP_OUT_WORDS]},tile.revision
}

// Where foliage is kept out of the tile of index at of an owner (Ground_Cell.kept).
ground_tile_kept :: proc "contextless" (owner:^Ground_Owner,at:int) -> []u64 {
    tile:=owner.tiles[at]
    if tile.pool==SPARSE_POOL {return owner.sparse[tile.block].kept[:]}
    return owner.pools[tile.pool].kept[int(tile.block)*KEEP_OUT_WORDS:][:KEEP_OUT_WORDS]
}

// The samples per side of the grid of the tile of a cell; 0 without one.
ground_tile_samples :: proc "contextless" (owner:^Ground_Owner,coord:[2]i32) -> u32 {
    if owner==nil {return 0}
    at:=ground_tile_find(owner,coord)
    if at<0 {return 0}
    return owner.tiles[at].pool==SPARSE_POOL?owner.samples:owner.pools[owner.tiles[at].pool].samples
}

// Whether the tile of a cell keeps only some of its samples.
ground_tile_sparse :: proc "contextless" (owner:^Ground_Owner,coord:[2]i32) -> bool {
    if owner==nil {return false}
    at:=ground_tile_find(owner,coord)
    return at>=0 && owner.tiles[at].pool==SPARSE_POOL
}

// The tile of a cell to write, made when it is not there or has another
// count of samples (its heights NaN, its weights 0), with samples per side
// (0: those it has, or the owner's). The writer raises its revision and the
// owner's after writing it.
ground_tile :: proc(owner:^Ground_Owner,coord:[2]i32,samples:u32=0) -> (heights:[]f32,weights:[]Layer_Weights,tile:^Ground_Tile) {
    at:=ground_tile_lower(owner,coord)
    found:=at<len(owner.tiles) && owner.tiles[at].coord==coord
    sparse:=found && owner.tiles[at].pool==SPARSE_POOL
    n:=samples
    if n==0 {n=found && !sparse?owner.pools[owner.tiles[at].pool].samples:owner.samples}
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
        } else if _,error:=inject_at(&owner.tiles,at,Ground_Tile{coord=coord,pool=u32(p),block=block});error!=nil {
            pool_block_free(owner,u32(p),block)
            return
        }
    }
    tile=&owner.tiles[at]
    pool:=&owner.pools[tile.pool]
    side:=int(n)*int(n)
    first:=int(tile.block)*side
    return pool.heights[first:][:side],pool.weights[first:][:side],tile
}

// Writes the sparse tile of a cell with the samples keys names (in order, of
// the grid of the owner): false when it held them already, or memory ran out
// and it keeps what it had. It raises the revision of the tile and the owner's.
ground_sparse_write :: proc(owner:^Ground_Owner,coord:[2]i32,keys:[]u16,heights:[]f32,weights:[]Layer_Weights,kept:[]u64) -> bool {
    at:=ground_tile_lower(owner,coord)
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
        copy(made.keys[:],keys);copy(made.heights[:],heights);copy(made.weights[:],weights);copy(made.kept[:],kept)
        block:=u32(len(owner.sparse)-1)
        if found {
            tile_samples_free(owner,owner.tiles[at])
            owner.tiles[at].pool,owner.tiles[at].block=SPARSE_POOL,u32(len(owner.sparse)-1)
        } else if _,error:=inject_at(&owner.tiles,at,Ground_Tile{coord=coord,pool=SPARSE_POOL,block=block});error!=nil {
            sparse_free(owner,block)
            return false
        }
    }
    owner.revision+=1
    owner.tiles[at].revision=owner.revision
    return true
}

// Lets go of where the samples of a tile are.
@(private)
tile_samples_free :: proc(owner:^Ground_Owner,tile:Ground_Tile) {
    if tile.pool==SPARSE_POOL {sparse_free(owner,tile.block)} else {pool_block_free(owner,tile.pool,tile.block)}
}

// Lets go of a sparse tile: the last takes its place.
@(private)
sparse_free :: proc(owner:^Ground_Owner,block:u32) {
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
    if words+KEEP_OUT_WORDS>cap(pool.kept) && reserve(&pool.kept,max(words+KEEP_OUT_WORDS,2*cap(pool.kept)))!=nil {return}
    if resize(&pool.heights,first+side)!=nil {return}
    if resize(&pool.weights,first+side)!=nil {base.truncate(&pool.heights,first);return}
    if resize(&pool.kept,words+KEEP_OUT_WORDS)!=nil {base.truncate(&pool.heights,first);base.truncate(&pool.weights,first);return}
    if _,error:=append(&pool.coords,coord);error!=nil {base.truncate(&pool.heights,first);base.truncate(&pool.weights,first);base.truncate(&pool.kept,words);return}
    for &h in pool.heights[first:] {h=NO_GROUND}
    for &w in pool.weights[first:] {w={}}
    for &w in pool.kept[words:] {w=0}
    return u32(len(pool.coords)-1),true
}

// Lets go of a block of a pool: the last block takes its place.
@(private)
pool_block_free :: proc(owner:^Ground_Owner,p,block:u32) {
    pool:=&owner.pools[p]
    side:=int(pool.samples)*int(pool.samples)
    last:=len(pool.coords)-1
    if int(block)!=last {
        copy(pool.heights[int(block)*side:][:side],pool.heights[last*side:][:side])
        copy(pool.weights[int(block)*side:][:side],pool.weights[last*side:][:side])
        copy(pool.kept[int(block)*KEEP_OUT_WORDS:][:KEEP_OUT_WORDS],pool.kept[last*KEEP_OUT_WORDS:][:KEEP_OUT_WORDS])
        moved:=pool.coords[last]
        pool.coords[block]=moved
        if at:=ground_tile_find(owner,moved);at>=0 {owner.tiles[at].block=block}
    }
    base.truncate(&pool.heights,last*side)
    base.truncate(&pool.weights,last*side)
    base.truncate(&pool.kept,last*KEEP_OUT_WORDS)
    base.truncate(&pool.coords,last)
}

NO_GROUND :: f32(0h7fc00000)

ground_owner_destroy :: proc(owner:^Ground_Owner) {
    for &pool in owner.pools {delete(pool.heights);delete(pool.weights);delete(pool.kept);delete(pool.coords)}
    for &sparse in owner.sparse {delete(sparse.keys);delete(sparse.heights);delete(sparse.weights)}
    delete(owner.pools);delete(owner.tiles);delete(owner.sparse);delete(owner.layers)
    owner^={}
}

// Takes the tile of index `at` away: its cell has no ground known again.
ground_tile_remove :: proc(owner:^Ground_Owner,at:int) {
    tile:=owner.tiles[at]
    ordered_remove(&owner.tiles,at)
    tile_samples_free(owner,tile)
    owner.revision+=1
}

// Forgets every tile of an owner, whose tiles take `samples` from here on.
ground_owner_reset :: proc(owner:^Ground_Owner,samples:u32) {
    if len(owner.tiles)>0 {owner.revision+=1}
    clear(&owner.tiles)
    for &pool in owner.pools {clear(&pool.heights);clear(&pool.weights);clear(&pool.kept);clear(&pool.coords)}
    for &sparse in owner.sparse {delete(sparse.keys);delete(sparse.heights);delete(sparse.weights)}
    clear(&owner.sparse)
    clear(&owner.layers)
    owner.samples=samples
}
