package render

import "core:math"

// The media of a view: a volume along its frustum that holds, in each cell,
// the light its media turn towards the eye from the eye to the far side of
// the cell (rgb) and the share of what is behind they let through (a). The
// plugin that has media (fog) leaves it in the Lit stage under MEDIA_TEXTURE;
// what is blended later (particles) binds it with pass_media and goes behind
// the same haze as the opaque scene. shaders/include/media_grid.slang reads
// it.
MEDIA_TEXTURE :: "view media"

MEDIA_COLUMNS :: 160 // across a view; its rows follow its proportion
MEDIA_PIXELS :: 8    // a narrower view has a column every this many pixels
MEDIA_SLICES :: 64   // along a view, thinner near the eye
MEDIA_DISTANCE :: f32(128) // metres along the view the slices reach
MEDIA_FAR_SLICES :: 32        // past them, each further than the one before by the same ratio; the last goes on without end
MEDIA_FAR_REACH :: f32(32768) // metres along the view where the last of them begins
MEDIA_SLICE_SCALE :: f32(2)   // metres: about where slices stop growing in step with the distance and start growing with it

// media_grid.slang Media_Grid: the cells of the media of a view.
Media_Grid :: struct {
    cells:[4]u32,  // columns, rows, slices to MEDIA_DISTANCE, slices past it
    distance:f32,
    scale:f32,
    reach:f32,
    valid:u32,     // 1: the view has media
}

// The grid of a view: a column every MEDIA_PIXELS pixels up to MEDIA_COLUMNS,
// and as many rows as keep its cells about square on the screen. Not valid:
// valid is for whoever finds the media.
media_grid :: proc "contextless" (width,height:u32) -> Media_Grid {
    if width==0 || height==0 {return {}}
    columns:=clamp((width+MEDIA_PIXELS-1)/MEDIA_PIXELS,1,MEDIA_COLUMNS)
    rows:=max(u32(math.round(f32(columns)*f32(height)/f32(width))),1)
    return {cells={columns,rows,MEDIA_SLICES,MEDIA_FAR_SLICES},distance=MEDIA_DISTANCE,scale=MEDIA_SLICE_SCALE,reach=MEDIA_FAR_REACH}
}

// Binds the media of the view of a pass at SLOT_PASS0 + slot, before a pass
// of the Blend stage begins, and gives its grid; in a view without media, an
// empty volume there and a grid that is not valid.
pass_media :: proc(pass:^Pass,slot:u32) -> Media_Grid {
    grid:=media_grid(pass.width,pass.height)
    if !pass_volume_sample(pass,slot,MEDIA_TEXTURE) || grid.cells.x==0 {return {}}
    grid.valid=1
    return grid
}
