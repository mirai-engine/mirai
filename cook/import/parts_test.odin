package importer

import "core:testing"

// A large image whose seam steps by one level, where neighbors step by a
// quarter: sampled every few pixels, the interior would look as rough as the
// seam.
@(test)
a_large_image_whose_seam_steps_more_than_its_neighbors_does_not_tile :: proc(t:^testing.T) {
    SIZE :: 2048
    pixels:=make([]u8,SIZE*SIZE*4)
    defer delete(pixels)
    // Up to 255 at the middle and down to 1 at the last pixel.
    level :: proc(at:int) -> u8 {return u8(at<SIZE/2 ? at*255/(SIZE/2) : 1+(SIZE-1-at)*254/(SIZE/2-1))}
    for y in 0..<SIZE {
        for x in 0..<SIZE {
            at:=(y*SIZE+x)*4
            pixels[at],pixels[at+1],pixels[at+3]=level(x),level(y),255
        }
    }
    testing.expect(t,!image_tiles(pixels,SIZE,SIZE))
    // The same image made to meet itself at its edges tiles.
    for y in 0..<SIZE {
        pixels[(y*SIZE+SIZE-1)*4]=0
    }
    for x in 0..<SIZE {
        pixels[((SIZE-1)*SIZE+x)*4+1]=0
    }
    testing.expect(t,image_tiles(pixels,SIZE,SIZE))
}
