package geom

import "core:testing"
import "mirai:std/base"

// The nearest covered cell is at the distance a search of every cell of the
// tile finds, inside the tile, for sparse and dense grids and tiles that do
// not divide the grid.
@(test)
grid_nearest_is_the_nearest_covered_cell_of_its_tile :: proc(t:^testing.T) {
    Case :: struct {width,height,tile:int,one_in:int}
    cases:=[]Case{{1,1,0,1},{17,9,0,7},{16,16,4,5},{23,11,5,9},{40,3,0,40},{12,12,6,1000}}
    h:=base.Hostile{3}
    for c in cases {
        cells:=c.width*c.height
        covered:=make([]bool,cells,context.temp_allocator)
        for &cover in covered {cover=base.hostile_int(&h,c.one_in)==0}
        nearest:=make([]u32,cells,context.temp_allocator)
        distance2:=make([]u32,cells,context.temp_allocator)
        if !testing.expect(t,grid_nearest(covered,c.width,c.height,c.tile,nearest,distance2)) {continue}
        span_x:=c.tile if c.tile>0 else c.width
        span_y:=c.tile if c.tile>0 else c.height
        for cell in 0..<cells {
            x,y:=cell%c.width,cell/c.width
            best:=max(int)
            for other in 0..<cells {
                ox,oy:=other%c.width,other/c.width
                if !covered[other] || ox/span_x!=x/span_x || oy/span_y!=y/span_y {continue}
                best=min(best,(ox-x)*(ox-x)+(oy-y)*(oy-y))
            }
            if best==max(int) {
                testing.expectf(t,nearest[cell]==max(u32) && distance2[cell]==max(u32),"%v: cell %d of a tile that covers none",c,cell)
                continue
            }
            n:=int(nearest[cell])
            nx,ny:=n%c.width,n/c.width
            testing.expectf(t,covered[n] && nx/span_x==x/span_x && ny/span_y==y/span_y,"%v: cell %d takes %d, not covered in its tile",c,cell,n)
            testing.expectf(t,int(distance2[cell])==best && (nx-x)*(nx-x)+(ny-y)*(ny-y)==best,"%v: cell %d at %d, nearest at %d",c,cell,distance2[cell],best)
        }
    }
}
