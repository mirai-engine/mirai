package mirai_pcg

import "base:runtime"
import "core:log"
import "core:math"
import "core:testing"
import "mirai:std/base"
import mm "mirai:std/math"

@(private="file") NAN :: f32(0h7fc00000)
@(private="file") INF :: f32(0h7f800000)

@(private="file")
fnv :: proc(h:^u64,v:u64) {h^=(h^~v)*0x100000001b3}

// The points a layer gets in a cell, as a caller scatters them.
@(private="file")
cell_points :: proc(seed:u32,coord:[2]i32,layer:u32,expected:f64,allocator:=context.allocator) -> [dynamic]Spacing_Point {
    key:=scatter_key(seed,coord,layer)
    scramble:=scatter_scramble(key)
    count:=scatter_count(key,expected)
    points:=make([dynamic]Spacing_Point,0,count,allocator)
    for point in 0..<count {
        r:=point_stream(key,point)
        append(&points,Spacing_Point{at=scatter_point_unit(scramble,point),chance=mm.random_f32(&r),point=point})
    }
    return points
}

// The sequence and its scramble give the same bits on every machine: the
// first direction numbers of the second Sobol dimension, the identity of a
// scramble by nothing in its lowest bit, and the hash of the counts and the
// places of many cells.
@(test)
sobol_owen_and_the_scatter_of_cells_keep_their_bits :: proc(t:^testing.T) {
    sobol:=[]struct{i,bits:u32}{{0,0},{1,0x80000000},{2,0xc0000000},{3,0x40000000},{4,0xa0000000},{8,0xf0000000},{16,0x88000000}}
    for c in sobol {testing.expectf(t,sobol_second(c.i)==c.bits,"sobol_second(%d) is %x, not %x",c.i,sobol_second(c.i),c.bits)}
    ids:=[]struct{layer,point:u32,id:u64}{{0,0,0},{1,0,1<<32},{7,9,7<<32|9},{max(u32),max(u32),max(u64)}}
    for c in ids {testing.expect_value(t,stable_id(c.layer,c.point),c.id)}
    h:=u64(0xcbf29ce484222325)
    for seed in u32(0)..<4 {
        for z in i32(-3)..=3 {
            for x in i32(-3)..=3 {
                for layer in u32(0)..<3 {
                    key:=scatter_key(seed,{x,z},layer)
                    fnv(&h,key)
                    count:=scatter_count(key,f64(layer)*37.3+0.5)
                    fnv(&h,u64(count))
                    scramble:=scatter_scramble(key)
                    for point in 0..<count {
                        at:=scatter_point_unit(scramble,point)
                        fnv(&h,u64(transmute(u32)at.x)|u64(transmute(u32)at.y)<<32)
                        r:=point_stream(key,point)
                        fnv(&h,u64(mm.rng_u32(&r)))
                    }
                }
            }
        }
    }
    GOLDEN :: u64(0xef27dff3e1247df8)
    if !testing.expectf(t,h==GOLDEN,"the scatter hashes to %x, not %x",h,GOLDEN) {log.infof("GOLDEN %x",h)}
}

// Any 2^8 first points of a cell, scrambled or not, put one in each of the
// 2^8 boxes of every shape 2^a by 2^(8-a): the (0,2) sequence stratifies, so
// a cell is covered evenly at every density.
@(test)
the_first_points_of_a_cell_fill_every_elementary_box_once :: proc(t:^testing.T) {
    K :: 8
    for scramble in ([]u64{0,0x9e3779b97f4a7c15,scatter_scramble(scatter_key(5,{-2,9},3))}) {
        for a in 0..=K {
            boxes:[1<<K]int
            for point in u32(0)..<1<<K {
                at:=scatter_point_unit(scramble,point)
                testing.expect(t,at.x>=0 && at.x<1 && at.y>=0 && at.y<1)
                bx,bz:=int(at.x*f32(int(1)<<uint(a))),int(at.y*f32(int(1)<<uint(K-a)))
                boxes[bz<<uint(a)|bx]+=1
            }
            for n,k in boxes {testing.expectf(t,n==1,"scramble %x: box %d of shape 2^%d holds %d points",scramble,k,a,n)}
        }
    }
}

// A lower density takes the last points away: the count never grows when the
// expected falls, the points that stay keep their place and stream, and over
// many cells the count averages what was expected (stochastic rounding).
@(test)
a_lower_density_drops_the_tail_and_keeps_the_rest :: proc(t:^testing.T) {
    expected:=[]f64{0,0.25,0.5,1,1.75,12.5,100.01,1000}
    for c in 0..<64 {
        key:=scatter_key(17,{i32(c),-i32(c)},2)
        last:=u32(0)
        for e in expected {
            n:=scatter_count(key,e)
            testing.expectf(t,n>=last && f64(n)>=math.floor(e) && f64(n)<=math.floor(e)+1,"count %d for %v after %d",n,e,last)
            last=n
        }
        dense:=cell_points(17,{i32(c),-i32(c)},2,300)
        sparse:=cell_points(17,{i32(c),-i32(c)},2,120)
        defer {delete(dense);delete(sparse)}
        testing.expect(t,len(sparse)<=len(dense))
        for p,i in sparse {testing.expect(t,p==dense[i],"a remaining point keeps its place and stream")}
    }
    for e in ([]f64{0.3,2.6,9.95}) {
        total:=f64(0)
        CELLS :: 20000
        for c in 0..<CELLS {total+=f64(scatter_count(scatter_key(3,{i32(c%141),i32(c/141)},1),e))}
        testing.expectf(t,abs(total/CELLS-e)<0.02,"mean count %v for %v",total/CELLS,e)
    }
    // Distinct for another cell, layer or seed when the other two stay. The
    // key is symmetric under swapping (seed, layer) with (z, x) of the cell,
    // so it is not distinct across all three at once.
    for seed in u32(0)..<3 {
        for layer in u32(0)..<3 {
            keys:=map[u64]bool{}
            defer delete(keys)
            for x in i32(-2)..=2 {for z in i32(-2)..=2 {keys[scatter_key(seed,{x,z},layer)]=true}}
            testing.expect_value(t,len(keys),25)
        }
    }
    for x in i32(-2)..=2 {
        layers,seeds:=map[u64]bool{},map[u64]bool{}
        defer {delete(layers);delete(seeds)}
        for k in u32(0)..<16 {
            layers[scatter_key(5,{x,-x},k)]=true
            seeds[scatter_key(k,{x,-x},5)]=true
        }
        testing.expect(t,len(layers)==16 && len(seeds)==16)
    }
}

// What scatter_count takes that is no count: none for NaN, zero, negative and
// negative infinity, the most for huge ones and infinity.
@(test)
scatter_count_refuses_what_is_no_count :: proc(t:^testing.T) {
    cases:=[]struct{e:f64,n:u32}{{f64(NAN),0},{0,0},{-1,0},{-1e300,0},{f64(-INF),0},{f64(INF),max(u32)},{1e300,max(u32)},{f64(max(u32)),max(u32)}}
    for c in cases {testing.expectf(t,scatter_count(7,c.e)==c.n,"scatter_count of %v is %d",c.e,scatter_count(7,c.e))}
}

// One layer stood in each cell of a 2 by 2 block, each from its own 3 by 3
// as a caller of the grid does: apart from its cell by index, then from the
// earlier ones across the border. No two points that stand are nearer than
// their reaches, within a cell or across a border, and every grid query is
// what testing every pair says.
@(test)
spacing_keeps_points_apart_across_the_borders_of_cells :: proc(t:^testing.T) {
    CELL :: f32(8)
    RADIUS :: f32(0.7)
    Stood :: struct {at:[2]f32,reach:f32,cell:[2]i32,point:u32}
    stood:[dynamic]Stood
    defer delete(stood)
    grid:=spacing_grid_make()
    defer spacing_grid_destroy(&grid)
    for middle in ([][2]i32{{0,0},{1,0},{0,1},{1,1}}) {
        spaced:[dynamic]Spacing_Point
        defer delete(spaced)
        testing.expect(t,spacing_grid_reset(&grid,CELL,4*RADIUS))
        for k in 0..<9 {
            d:=[2]i32{i32(k%3)-1,i32(k/3)-1}
            points:=cell_points(42,middle+d,1,60)
            defer delete(points)
            for g in points {
                p:=g
                p.at=g.at*CELL+[2]f32{f32(d.x),f32(d.y)}*CELL
                p.reach=RADIUS*(0.5+g.chance)
                p.cell=u8(k)
                blocked:=spacing_grid_blocks(&grid,spaced[:],p,.Same_Cell)
                testing.expect_value(t,blocked,blocks_by_pairs(spaced[:],p,.Same_Cell))
                if blocked {continue}
                append(&spaced,p)
                testing.expect(t,spacing_grid_add(&grid,p.at))
            }
        }
        for p in spaced {
            for by in Spacing_Block {testing.expect_value(t,spacing_grid_blocks(&grid,spaced[:],p,by),blocks_by_pairs(spaced[:],p,by))}
            if p.cell!=SPACING_MIDDLE || spacing_grid_blocks(&grid,spaced[:],p,.Other_Cells) {continue}
            append(&stood,Stood{p.at+[2]f32{f32(middle.x),f32(middle.y)}*CELL,p.reach,middle,p.point})
        }
    }
    across:=0
    for a,i in stood {
        for b in stood[i+1:] {
            d:=a.at-b.at
            r:=a.reach+b.reach
            if a.cell!=b.cell && d.x*d.x+d.y*d.y<4*r*r {across+=1}
            testing.expectf(t,d.x*d.x+d.y*d.y>=r*r,"points %d of %v and %d of %v stand %v apart, nearer than %v",a.point,a.cell,b.point,b.cell,math.sqrt(d.x*d.x+d.y*d.y),r)
        }
    }
    testing.expectf(t,len(stood)>40 && across>10,"%d points stand, %d pairs close across borders",len(stood),across)
}

@(private="file")
blocks_by_pairs :: proc(points:[]Spacing_Point,p:Spacing_Point,by:Spacing_Block) -> bool {
    for q in points {
        switch by {
        case .Same_Cell: if q.cell!=p.cell {continue}
        case .Other_Cells: if q.cell==p.cell || !spacing_before(q,p) {continue}
        case .Any:
        }
        d:=q.at-p.at
        r:=q.reach+p.reach
        if d.x*d.x+d.y*d.y<r*r {return true}
    }
    return false
}

// The tie between two points too near keeps the lower index, and between
// equal indices the cell first in z and then x; every view decides the same.
@(test)
spacing_breaks_ties_by_index_then_cell :: proc(t:^testing.T) {
    cases:=[]struct{a,b:Spacing_Point,before:bool}{
        {{point=1,cell=4},{point=2,cell=0},true},
        {{point=2,cell=0},{point=1,cell=4},false},
        {{point=3,cell=1},{point=3,cell=5},true},
        {{point=3,cell=5},{point=3,cell=1},false},
        {{point=3,cell=5},{point=3,cell=5},false},
    }
    for c in cases {testing.expect_value(t,spacing_before(c.a,c.b),c.before)}
}

// The buckets of a reset: as many as fit reaches of reach across 3 cells,
// one at least and SPACING_GRID_SIDE_MAX at most; a cell size that is not
// finite and positive refuses, and the grid then neither adds nor blocks.
@(test)
spacing_grid_reset_sizes_its_buckets_and_refuses_bad_cells :: proc(t:^testing.T) {
    grid:=spacing_grid_make()
    defer spacing_grid_destroy(&grid)
    cases:=[]struct{cell,reach:f32,ok:bool,side:int}{
        {32,3,true,32},{32,0,true,SPACING_GRID_SIDE_MAX},{32,NAN,true,SPACING_GRID_SIDE_MAX},{32,-5,true,SPACING_GRID_SIDE_MAX},
        {32,1000,true,1},{32,INF,true,1},{1,0.5,true,6},
        {0,1,false,0},{-1,1,false,0},{NAN,1,false,0},{INF,1,false,0},{max(f32),1,false,0},
    }
    for c in cases {
        ok:=spacing_grid_reset(&grid,c.cell,c.reach)
        testing.expectf(t,ok==c.ok && grid.side==c.side,"cell %v reach %v: %v with %d buckets a side",c.cell,c.reach,ok,grid.side)
        p:=Spacing_Point{reach=1}
        testing.expect_value(t,spacing_grid_add(&grid,{}),c.ok)
        testing.expect_value(t,spacing_grid_blocks(&grid,{p},p,.Any),c.ok)
    }
    zero:Spacing_Grid
    testing.expect(t,!spacing_grid_add(&zero,{}) && !spacing_grid_blocks(&zero,{},{},.Any),"a grid never reset holds nothing")
}

// Layered dithering partitions [0,1): every value belongs to one layer at
// most, each layer owns its weight of them (its share of the total past 1),
// the rest to none, and a lower weight of one layer leaves the values of the
// layers before it where they were.
@(test)
dithering_partitions_the_values_among_layers :: proc(t:^testing.T) {
    STEPS :: 10000
    cases:=[]struct{weights:[]f32,shares:[]f32}{
        {{0.5,0.25},{0.5,0.25}},
        {{0.2,0.3,0.4},{0.2,0.3,0.4}},
        {{1,1},{0.5,0.5}},
        {{2,0.5,0.5},{0.5,0.25,0.25}},
        {{0.3,NAN,-1,0.2,0},{0.3,0,0,0.2,0}},
        {{INF,0.5},{2.0/3.0,1.0/3.0}},
        {{},{}},
    }
    for c in cases {
        owned:[8]int
        for k in 0..<STEPS {
            u:=(f32(k)+0.5)/STEPS
            if layer,ok:=dither_band_select(u,c.weights);ok {owned[layer]+=1}
        }
        for share,i in c.shares {testing.expectf(t,abs(f32(owned[i])/STEPS-share)<=2.0/STEPS,"weights %v: layer %d owns %v, not %v",c.weights,i,f32(owned[i])/STEPS,share)}
    }
    full:=[]f32{0.3,0.4,0.2}
    less:=[]f32{0.3,0.4,0.05}
    for k in 0..<STEPS {
        u:=(f32(k)+0.5)/STEPS
        a,in_a:=dither_band_select(u,full)
        b,in_b:=dither_band_select(u,less)
        if in_a && a<2 {testing.expect(t,in_b && a==b,"a lower last weight keeps the layers before it")}
    }
    for u in ([]f32{NAN,-0.1,1,INF,-INF}) {_,ok:=dither_band_select(u,full);testing.expectf(t,!ok,"%v belongs to no layer",u)}
    for k in 0..<STEPS {
        u:=1-f32(k)*1e-7
        if u>=1 {continue}
        _,ok:=dither_band_select(u,[]f32{3,7})
        testing.expect(t,ok,"weights past 1 in all take every value")
    }
}

// The chance of a point is its viability inside the taper of an edge and a
// smoothstep of its distance there, none outside the border or for NaN.
@(test)
viability_tapers_at_the_edge :: proc(t:^testing.T) {
    cases:=[]struct{viability,edge,taper,chance:f32}{
        {1,5,2,1},{0.6,2,2,0.6},{1,1,2,0.5},{1,0.5,2,0.15625},{0.5,1,2,0.25},
        {1,0,2,0},{1,-3,2,0},{1,0.1,0,1},{1,-0.1,0,0},{1,1,-2,1},
        {2,5,1,1},{-1,5,1,0},{NAN,5,1,0},{1,NAN,1,0},{1,1,NAN,1},
        {1,INF,1,1},{1,-INF,1,0},{1,1,INF,0},{1,INF,INF,1},
    }
    for c in cases {
        v:=viability_taper(c.viability,c.edge,c.taper)
        testing.expectf(t,abs(v-c.chance)<1e-6,"viability %v edge %v taper %v: %v, not %v",c.viability,c.edge,c.taper,v,c.chance)
    }
    last:=f32(0)
    for k in 0..=100 {
        v:=viability_taper(0.8,f32(k)*0.03,2)
        testing.expect(t,v>=last && v<=0.8,"the taper rises to the viability")
        last=v
    }
}

// Coverage between four corners is bilinear, and the share of the points of
// a square that stand follows it; corners and fractions out of range are
// taken at the nearest end.
@(test)
coverage_accepts_points_by_its_bilinear_probability :: proc(t:^testing.T) {
    cases:=[]struct{corners:[4]f32,f:[2]f32,coverage:f32}{
        {{0,1,0,1},{0,0},0},{{0,1,0,1},{1,0},1},{{0,1,0,1},{0.25,0.7},0.25},
        {{1,1,0,0},{0.3,0.25},0.75},{{0.2,0.4,0.6,0.8},{0.5,0.5},0.5},
        {{NAN,1,-1,2},{1,1},1},{{NAN,1,-1,2},{0,0},0},{{1,1,1,1},{NAN,-INF},1},
        {{0,1,0,1},{INF,0},1},
    }
    for c in cases {
        v:=coverage_at(c.corners,c.f)
        testing.expectf(t,abs(v-c.coverage)<1e-6,"corners %v at %v: %v, not %v",c.corners,c.f,v,c.coverage)
    }
    r:=mm.rng_make(77)
    corners:=[4]f32{0,1,0.5,0.25}
    accepted,expected:=0,f64(0)
    N :: 40000
    for _ in 0..<N {
        f:=[2]f32{mm.random_f32(&r),mm.random_f32(&r)}
        expected+=f64(coverage_at(corners,f))
        if coverage_accept(corners,f,mm.random_f32(&r)) {accepted+=1}
    }
    testing.expectf(t,abs(f64(accepted)-expected)/N<0.01,"%d accepted where %v were expected",accepted,expected)
    for u in ([]f32{NAN,-0.5,1}) {testing.expect(t,!coverage_accept({1,1,1,1},{0.5,0.5},u))}
}

// Every procedure takes NaN, infinities and extremes without trapping, with
// its results in range; a grid takes any place, and points shorter than what
// it holds.
@(test)
hostile_inputs_stay_in_range :: proc(t:^testing.T) {
    h:=base.Hostile{state=0x5eed}
    grid:=spacing_grid_make()
    defer spacing_grid_destroy(&grid)
    points:[dynamic]Spacing_Point
    defer delete(points)
    for round in 0..<2000 {
        x:=base.hostile_f32(&h)
        _=scatter_count(base.hostile_next(&h),f64(x))
        at:=scatter_point_unit(base.hostile_next(&h),u32(base.hostile_next(&h)))
        testing.expect(t,at.x>=0 && at.x<1 && at.y>=0 && at.y<1)
        weights:=[3]f32{base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h)}
        if layer,ok:=dither_band_select(base.hostile_f32(&h),weights[:]);ok {testing.expect(t,layer>=0 && layer<3 && weights[layer]>0)}
        v:=viability_taper(base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h))
        testing.expect(t,v>=0 && v<=1)
        c:=coverage_at({base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h),base.hostile_f32(&h)},{base.hostile_f32(&h),base.hostile_f32(&h)})
        testing.expectf(t,c>=0 && c<=1+1e-6,"coverage %v",c)
        if round%100==0 {
            clear(&points)
            spacing_grid_reset(&grid,base.hostile_f32(&h),base.hostile_f32(&h))
        }
        p:=Spacing_Point{at={base.hostile_f32(&h),base.hostile_f32(&h)},reach=base.hostile_f32(&h),point=u32(base.hostile_int(&h,8)),cell=u8(base.hostile_int(&h,9))}
        _=spacing_grid_blocks(&grid,points[:base.hostile_int(&h,len(points)+1)],p,Spacing_Block(base.hostile_int(&h,3)))
        if spacing_grid_add(&grid,p.at) {append(&points,p)}
    }
}

@(private="file")
Limit :: struct {owner:runtime.Allocator,remaining:int}

@(private="file")
limit_proc :: proc(data:rawptr,mode:runtime.Allocator_Mode,size,alignment:int,old_memory:rawptr,old_size:int,loc:=#caller_location) -> ([]byte,runtime.Allocator_Error) {
    limit:=(^Limit)(data)
    if mode==.Alloc || mode==.Alloc_Non_Zeroed || mode==.Resize || mode==.Resize_Non_Zeroed {
        if limit.remaining<=0 {return nil,.Out_Of_Memory}
        limit.remaining-=1
    }
    return limit.owner.procedure(limit.owner.data,mode,size,alignment,old_memory,old_size,loc)
}

// A grid out of memory at each request in turn refuses the reset or the add
// that needed it, holds what it held before the add, and leaves nothing
// allocated once destroyed.
@(test)
spacing_grid_without_memory_refuses_and_leaks_nothing :: proc(t:^testing.T) {
    done:=false
    for served in 0..<64 {
        memory:base.Hostile_Memory
        limit:=Limit{base.hostile_memory_begin(&memory),served}
        grid:=spacing_grid_make(runtime.Allocator{limit_proc,&limit})
        added:=0
        whole:=spacing_grid_reset(&grid,16,1)
        if whole {
            for k in 0..<500 {
                if !spacing_grid_add(&grid,{f32(k%37),f32(k/37)}) {
                    whole=false
                    break
                }
                added+=1
            }
        }
        testing.expect_value(t,len(grid.next),added)
        spacing_grid_destroy(&grid)
        leaked,bad_frees:=base.hostile_memory_end(&memory)
        testing.expectf(t,leaked==0 && bad_frees==0,"served %d: %d allocations were left and %d frees were of nothing",served,leaked,bad_frees)
        if whole {
            done=true
            break
        }
    }
    testing.expect(t,done,"with memory enough the grid takes every point")
}
