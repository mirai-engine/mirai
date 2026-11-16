package editor

import "core:testing"

@(test)
the_icon_of_the_window_is_the_mark_on_a_dark_tile :: proc(t:^testing.T) {
    pixels:=mark_icon_pixels(context.temp_allocator)
    testing.expect_value(t,len(pixels),MARK_ICON_SIZE*MARK_ICON_SIZE*4)
    at :: proc(pixels:[]u8,p:[2]f32) -> [4]u8 {
        unit:=f32(MARK_ICON_SIZE)/16*MARK_ICON_SCALE
        q:=f32(MARK_ICON_SIZE)*0.5+p*unit
        i:=(int(q.y)*MARK_ICON_SIZE+int(q.x))*4
        return {pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]}
    }
    corner:=f32(MARK_ICON_SIZE)*0.5/(f32(MARK_ICON_SIZE)/16*MARK_ICON_SCALE)
    testing.expect_value(t,at(pixels,{-corner,-corner})[3],u8(0))
    testing.expect_value(t,at(pixels,{corner-0.01,corner-0.01})[3],u8(0))
    testing.expect_value(t,at(pixels,{0,-7.5}),[4]u8{MARK_TILE[0],MARK_TILE[1],MARK_TILE[2],255})
    testing.expect_value(t,at(pixels,{0,0}),[4]u8{MARK_STAR[0],MARK_STAR[1],MARK_STAR[2],255})
    testing.expect_value(t,at(pixels,{0,4.6}),[4]u8{MARK_STAR[0],MARK_STAR[1],MARK_STAR[2],255})
    testing.expect_value(t,at(pixels,{-5.5,-2.5}),[4]u8{MARK_ARM[0],MARK_ARM[1],MARK_ARM[2],255})
    testing.expect_value(t,at(pixels,{5,3.5}),[4]u8{MARK_ARM[0],MARK_ARM[1],MARK_ARM[2],255})
}
