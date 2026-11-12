package foliage

import "mirai:core"
import "mirai:std/base"
import mm "mirai:std/math"

// The ground the instances of each Foliage stand on, in the space of its
// entity: a tile of heights over each cell, with the weights of the layers of
// the ground there, read from core.Ground_Queries (ground_read.odin). Each
// tile it changes raises its revision, and foliage builds again the cells
// whose tile changed. A tile may be coarser than the others (the ground far
// from where it is seen). A cell without a tile (not read yet, or no ground
// covers it) has no ground: its generated instances are not there. Without a
// ground in the world there are no owners, and the plane y = 0 of each entity
// is its ground.
@(storage)
Foliage_Ground :: struct {
    owners:[dynamic]Ground_Owner,
    foliage:[2]u64,    // Foliage_Data: entries made and loads
    seen:[2]core.Seen, // the tables of Foliage and World_Transform
    streamed:u64,      // the revision of the streaming sources
    queue:[dynamic]Ground_Task,  // tiles to read, in the order they were asked
    queued:[dynamic]Ground_Task, // the same, sorted
}
Ground_Owner :: struct {
    entity:core.Entity,
    samples:u32,                // per side of a tile written without saying how many; a cell is samples-1 steps across
    revision:u32,               // raised with the revision of any of its tiles
    layers:[RULE_LAYERS]base.Asset_Id, // what the weights of its tiles are of: the material of each layer of the ground under it
    layer_count:u32,
    tiles:[dynamic]Ground_Tile, // in the order of their coordinates, z then x
    pools:[dynamic]Ground_Pool, // the samples of its tiles, a pool for each count of them
    transform:mm.Transform,     // of its entity when its tiles were last asked for
    epoch:u64,                  // and of its entry of Foliage_Data
    loads:u32,
}
Ground_Tile :: struct {
    coord:[2]i32,
    revision:u32,
    pool,block:u32, // where its samples are
}
// The samples of the tiles of an owner with the same count per side, a block
// for each: a tile that takes another count leaves its block to the last.
Ground_Pool :: struct {
    samples:u32,             // per side
    heights:[dynamic]f32,    // samples*samples of each block, x first; NaN where there is no ground
    weights:[dynamic][4]u8,  // of each height: of the layers of the ground there, adding up to 255; 0 where it has none or there is no ground
    coords:[dynamic][2]i32,  // the tile of each block
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
    pool:=&owner.pools[tile.pool]
    n:=int(pool.samples)
    if n<2 {return}
    first:=int(tile.block)*n*n
    return Ground_Cell{samples=n,heights=pool.heights[first:][:n*n],weights=pool.weights[first:][:n*n]},tile.revision
}

// The samples per side of the tile of a cell; 0 without one.
ground_tile_samples :: proc "contextless" (owner:^Ground_Owner,coord:[2]i32) -> u32 {
    if owner==nil {return 0}
    at:=ground_tile_find(owner,coord)
    return at<0?0:owner.pools[owner.tiles[at].pool].samples
}

// The tile of a cell to write, made when it is not there or has another
// count of samples (its heights NaN, its weights 0), with samples per side
// (0: those it has, or the owner's). The writer raises its revision and the
// owner's after writing it.
ground_tile :: proc(owner:^Ground_Owner,coord:[2]i32,samples:u32=0) -> (heights:[]f32,weights:[][4]u8,tile:^Ground_Tile) {
    at:=ground_tile_lower(owner,coord)
    found:=at<len(owner.tiles) && owner.tiles[at].coord==coord
    n:=samples
    if n==0 {n=found?owner.pools[owner.tiles[at].pool].samples:owner.samples}
    if n<2 {return}
    if !found || owner.pools[owner.tiles[at].pool].samples!=n {
        p:=-1
        for pool,i in owner.pools {if pool.samples==n {p=i;break}}
        if p<0 {
            if _,error:=append(&owner.pools,Ground_Pool{samples=n});error!=nil {return}
            p=len(owner.pools)-1
        }
        block,made:=pool_block_add(&owner.pools[p],coord)
        if !made {return}
        if found {
            pool_block_free(owner,owner.tiles[at].pool,owner.tiles[at].block)
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

// A block at the end of a pool for the tile of coord, without ground.
@(private)
pool_block_add :: proc(pool:^Ground_Pool,coord:[2]i32) -> (block:u32,ok:bool) {
    side:=int(pool.samples)*int(pool.samples)
    first:=len(pool.heights)
    // They grow by doubling: tile after tile does not copy them all each time.
    if first+side>cap(pool.heights) && reserve(&pool.heights,max(first+side,2*cap(pool.heights)))!=nil {return}
    if first+side>cap(pool.weights) && reserve(&pool.weights,max(first+side,2*cap(pool.weights)))!=nil {return}
    if resize(&pool.heights,first+side)!=nil {return}
    if resize(&pool.weights,first+side)!=nil {base.truncate(&pool.heights,first);return}
    if _,error:=append(&pool.coords,coord);error!=nil {base.truncate(&pool.heights,first);base.truncate(&pool.weights,first);return}
    for &h in pool.heights[first:] {h=NO_GROUND}
    for &w in pool.weights[first:] {w={}}
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
        moved:=pool.coords[last]
        pool.coords[block]=moved
        if at:=ground_tile_find(owner,moved);at>=0 {owner.tiles[at].block=block}
    }
    base.truncate(&pool.heights,last*side)
    base.truncate(&pool.weights,last*side)
    base.truncate(&pool.coords,last)
}

NO_GROUND :: f32(0h7fc00000)

ground_owner_destroy :: proc(owner:^Ground_Owner) {
    for &pool in owner.pools {delete(pool.heights);delete(pool.weights);delete(pool.coords)}
    delete(owner.pools);delete(owner.tiles)
    owner^={}
}

// Takes the tile of index `at` away: its cell has no ground known again.
ground_tile_remove :: proc(owner:^Ground_Owner,at:int) {
    tile:=owner.tiles[at]
    ordered_remove(&owner.tiles,at)
    pool_block_free(owner,tile.pool,tile.block)
    owner.revision+=1
}

// Forgets every tile of an owner, whose tiles take `samples` from here on.
ground_owner_reset :: proc(owner:^Ground_Owner,samples:u32) {
    if len(owner.tiles)>0 {owner.revision+=1}
    clear(&owner.tiles)
    for &pool in owner.pools {clear(&pool.heights);clear(&pool.weights);clear(&pool.coords)}
    owner.samples=samples
}
