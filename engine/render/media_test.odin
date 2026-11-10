package render

import "core:testing"

// A view has a column every 8 pixels up to 160, as many rows as keep its
// cells square and 64 slices: the grid of a large view does not grow with it.
@(test)
media_grids_follow_the_proportion_of_the_view_up_to_their_size :: proc(t:^testing.T) {
    Case :: struct {width,height:u32,cells:[3]u32}
    for c in ([]Case{{1440,900,{160,100,64}},{3072,1728,{160,90,64}},{256,144,{32,18,64}},{4,4,{1,1,64}},{0,900,{}}}) {
        grid:=media_grid(c.width,c.height)
        testing.expectf(t,grid.cells.xyz==c.cells && grid.valid==0,"%dx%d: %v",c.width,c.height,grid)
    }
}
