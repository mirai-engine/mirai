package mirai_pcg

import "base:intrinsics"
import "mirai:std/base"
import mm "mirai:std/math"

// Deterministic sampling for procedural placement: the same points on every
// machine for a seed, from integer arithmetic and the streams of std/math. A
// layer is one kind of thing placed (a foliage type), scattered over the
// square cells of a grid. The index of a point does not depend on how many
// there are: a lower density takes the last ones away and keeps the others
// where they were.

// The second dimension of the Sobol sequence at index i, as a fraction of 2^32.
sobol_second :: proc "contextless" (i:u32) -> u32 {
    r,v,i:=u32(0),u32(1)<<31,i
    for i!=0 {
        if i&1!=0 {r~=v}
        i>>=1
        v~=v>>1
    }
    return r
}

// A nested uniform (Owen) scramble of a fraction of 2^32: each bit flips by a
// hash of the bits above it, so a set stratified in base 2 stays so.
owen_scramble :: proc "contextless" (x,seed:u32) -> u32 {
    v:=intrinsics.reverse_bits(x)+seed
    v~=v*0x6c50b47c
    v~=v*0xb82f1e52
    v~=v*0xc7afe638
    v~=v*0x8d22f6e6
    return intrinsics.reverse_bits(v)
}

// The key of the points of a layer in a cell for a seed: their count
// (scatter_count), their places (scatter_scramble) and the stream of each
// (point_stream) come from it.
scatter_key :: proc "contextless" (seed:u32,coord:[2]i32,layer:u32) -> u64 {
    return base.hash_u64(u64(seed)<<32 ~ u64(layer)) ~ base.hash_u64(u64(u32(coord.x)) | u64(u32(coord.y))<<32)
}

// How many points a cell of key gets for expected of them: the whole part,
// and one more with the chance of the rest (floor(expected) + (u < frac)), u
// the first value of the stream of key. None for NaN, zero or less; at most
// max(u32).
scatter_count :: proc "contextless" (key:u64,expected:f64) -> u32 {
    if !(expected>0) {return 0}
    if expected>=f64(max(u32)) {return max(u32)}
    counter:=mm.rng_make(key)
    count:=u32(expected)
    if f64(mm.random_f32(&counter))<expected-f64(count) {count+=1}
    return count
}

// The scramble of the places of the points of key, for scatter_point_unit.
scatter_scramble :: proc "contextless" (key:u64) -> u64 {return base.hash_u64(key)}

// The place of a point in [0,1)^2, x first: point of a (0,2) sequence of base
// 2 under the Owen scramble of its cell, in steps of 2^-24. However many
// points there are, the first ones cover the square as a jittered grid does,
// without the clumps and gaps of points at random.
scatter_point_unit :: proc "contextless" (scramble:u64,point:u32) -> [2]f32 {
    across:=owen_scramble(intrinsics.reverse_bits(point),u32(scramble))
    along:=owen_scramble(sobol_second(point),u32(scramble>>32))
    return [2]f32{f32(across>>8),f32(along>>8)}*(1.0/16777216.0)
}

// The stream of the values of a point of key (its turn, scale, chance).
point_stream :: proc "contextless" (key:u64,point:u32) -> mm.Rng {return mm.rng_make(key,u64(point)+1)}

// The id of a point within its cell: its layer in the high half and its
// index, which stay while the seed and the layer do.
stable_id :: proc "contextless" (layer_id:u32,point:u32) -> u64 {return u64(layer_id)<<32 | u64(point)}

// A point kept apart from others by its reach, from the corner of the middle
// cell of the 3 by 3 its points come from.
Spacing_Point :: struct {
    at:[2]f32,
    reach:f32,  // metres it keeps clear around it, with the reach of the other
    chance:f32, // 0 to 1: the value of its stream it is thinned by
    point:u32,  // its index among those of its layer in its cell
    cell:u8,    // of the 3 by 3, x first: SPACING_MIDDLE is the middle one
}
SPACING_MIDDLE :: 4

// Which of two points of a layer keeps its place when they are too near: the
// one of the lower index, or of the cell first in z and then x. Every cell
// that sees both decides the same.
spacing_before :: proc "contextless" (a,b:Spacing_Point) -> bool {return a.point<b.point || a.point==b.point && a.cell<b.cell}

// Buckets over the 3 by 3 cells around a middle one, at least as wide as the
// reaches of two points together: a point meets only those of the 9 buckets
// around its own. Its arrays take the allocator of spacing_grid_make, or the
// context's at the first reset of a zero one.
Spacing_Grid :: struct {
    heads:[dynamic]i32,
    next:[dynamic]i32, // of each point added, the one added before it to its bucket
    side:int,          // buckets per side
    size:f32,          // metres across a bucket
    cell:f32,          // metres across a cell
}
SPACING_GRID_SIDE_MAX :: 192

spacing_grid_make :: proc(allocator:=context.allocator) -> Spacing_Grid {
    return {heads=make([dynamic]i32,allocator),next=make([dynamic]i32,allocator)}
}

spacing_grid_destroy :: proc(g:^Spacing_Grid) {
    delete(g.heads);delete(g.next)
    g^={}
}

// Empties the grid for cells cell_size across and points whose reaches
// together come to at most reach. False for a cell size that is not finite
// and positive, or without memory; the grid then holds nothing.
spacing_grid_reset :: proc(g:^Spacing_Grid,cell_size,reach:f32) -> bool {
    clear(&g.next)
    g.side=0
    if !(cell_size>0) || cell_size>max(f32)/3 {return false}
    buckets:=3*cell_size/(reach>1e-3?reach:1e-3)
    side:=buckets>=SPACING_GRID_SIDE_MAX?SPACING_GRID_SIDE_MAX:max(int(buckets),1)
    if resize(&g.heads,side*side)!=nil {return false}
    for &h in g.heads {h=-1}
    g.side,g.size,g.cell=side,3*cell_size/f32(side),cell_size
    return true
}

@(private)
spacing_bucket :: proc "contextless" (g:^Spacing_Grid,at:[2]f32) -> [2]int {
    b:=(at+g.cell)/g.size
    clamped:[2]int
    for k in 0..<2 {
        v:=b[k]
        clamped[k]=v>=f32(g.side)?g.side-1:v>0?int(v):0
    }
    return clamped
}

// Adds the next point to the grid, the one of index len(g.next) in the
// points spacing_grid_blocks is given. False without memory or a reset.
spacing_grid_add :: proc(g:^Spacing_Grid,at:[2]f32) -> bool {
    if g.side<=0 || len(g.heads)<g.side*g.side {return false}
    b:=spacing_bucket(g,at)
    k:=b.y*g.side+b.x
    if _,error:=append(&g.next,g.heads[k]);error!=nil {return false}
    g.heads[k]=i32(len(g.next)-1)
    return true
}

// Which of the points a grid holds may keep a point away.
Spacing_Block :: enum u8 {
    Same_Cell,   // those of the cell of the point
    Other_Cells, // those of the other cells that keep their place before it (spacing_before)
    Any,
}

// Whether one of points, those the grid holds in the order they were added,
// is nearer to p than their two reaches. A point the grid holds past the end
// of points keeps nothing away.
spacing_grid_blocks :: proc "contextless" (g:^Spacing_Grid,points:[]Spacing_Point,p:Spacing_Point,by:Spacing_Block) -> bool {
    if g.side<=0 || len(g.heads)<g.side*g.side {return false}
    b:=spacing_bucket(g,p.at)
    for z in max(b.y-1,0)..=min(b.y+1,g.side-1) {
        for x in max(b.x-1,0)..=min(b.x+1,g.side-1) {
            for i:=g.heads[z*g.side+x];i>=0 && int(i)<len(g.next);i=g.next[i] {
                if int(i)>=len(points) {continue}
                q:=points[i]
                switch by {
                case .Same_Cell: if q.cell!=p.cell {continue}
                case .Other_Cells: if q.cell==p.cell || !spacing_before(q,p) {continue}
                case .Any:
                }
                d:=q.at-p.at
                r:=q.reach+p.reach
                if d.x*d.x+d.y*d.y<r*r {return true}
            }
        }
    }
    return false
}

// Layered dithering among layers of the same footprint: the layer a point of
// value u (0 to 1, of its stream) belongs to, which excludes the others
// without testing their points. Layer i owns its weight (0 to 1, a share of
// the points) of [0,1), after those before it; with weights over 1 in all,
// each owns its share of the total. False where u falls past them all, or is
// not in [0,1). A weight that is NaN or not positive owns nothing; a lower
// weight of one leaves those before it where they were.
dither_band_select :: proc "contextless" (u:f32,weights:[]f32) -> (layer:int,ok:bool) {
    if !(u>=0 && u<1) {return}
    total:=f32(0)
    for w in weights {total+=dither_weight(w)}
    at:=total>1?u*total:u
    low,last:=f32(0),-1
    for w,i in weights {
        share:=dither_weight(w)
        if share<=0 {continue}
        high:=low+share
        if at<high {return i,true}
        low,last=high,i
    }
    // u*total may round up to the total itself.
    if total>1 {return last,true}
    return
}

@(private)
dither_weight :: proc "contextless" (w:f32) -> f32 {return w>0?min(w,1):0}

// The chance a point stands with, its viability tapered at an edge: its
// viability (0 to 1) times a smoothstep of edge, its distance in metres
// inside the border of its region (signed, negative outside), over taper
// metres. With no taper, all of it inside the border and none outside. NaN
// gives none.
viability_taper :: proc "contextless" (viability,edge,taper:f32) -> f32 {
    v:=viability>0?min(viability,1):0
    if !(edge>0) {return 0}
    if !(taper>0) || edge>=taper {return v}
    x:=edge/taper
    return v*x*x*(3-2*x)
}

// The coverage at fraction f (0 to 1, x first) between the four corners of a
// square of coverage samples (x first, then z), each 0 to 1, bilinearly; a
// corner that is NaN covers nothing.
coverage_at :: proc "contextless" (corners:[4]f32,f:[2]f32) -> f32 {
    c:[4]f32
    for v,k in corners {c[k]=v>0?min(v,1):0}
    fu:=f.x>0?min(f.x,1):0
    fv:=f.y>0?min(f.y,1):0
    return (c[0]+(c[1]-c[0])*fu)*(1-fv)+(c[2]+(c[3]-c[2])*fu)*fv
}

// Coverage acceptance at an edge (bilinear coverage probability): a point of
// value u (0 to 1, of its stream) stands where it is under the coverage
// there, so the share that stands follows the coverage across the square.
coverage_accept :: proc "contextless" (corners:[4]f32,f:[2]f32,u:f32) -> bool {
    return u>=0 && u<coverage_at(corners,f)
}
