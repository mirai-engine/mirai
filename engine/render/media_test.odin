package render

import "core:testing"

// A view has a column every MEDIA_PIXELS pixels up to MEDIA_COLUMNS, as many
// rows as keep its cells square: the grid of a large view does not grow with
// it, and a view without pixels has none.
@(test)
media_grids_follow_the_proportion_of_the_view_up_to_their_size :: proc(t:^testing.T) {
    for size in ([][2]u32{{1440,900},{3072,1728},{256,144},{4,4},{900,1440}}) {
        grid:=media_grid(size.x,size.y)
        columns:=min((size.x+MEDIA_PIXELS-1)/MEDIA_PIXELS,MEDIA_COLUMNS)
        square:=abs(f32(grid.cells.y)/f32(grid.cells.x)-f32(size.y)/f32(size.x))<=1/f32(grid.cells.x)
        testing.expectf(t,grid.cells.x==columns && square && grid.cells.z==MEDIA_SLICES && grid.valid==0,"%v: %v",size,grid)
    }
    testing.expect_value(t,media_grid(0,900),Media_Grid{})
}
