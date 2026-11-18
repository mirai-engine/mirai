package host

import "core:testing"

@(test)
views_split_the_surface_or_take_the_tiles_given :: proc(t:^testing.T) {
    app:App
    app.drawable={1280,720}
    testing.expect_value(t,app_player_rect(&app,0,1),[4]i32{0,0,1280,720})
    testing.expect_value(t,app_player_rect(&app,1,2),[4]i32{640,0,640,720})
    testing.expect_value(t,app_player_rect(&app,2,3),[4]i32{0,360,640,360})
    testing.expect_value(t,app_player_rect(&app,3,4),[4]i32{640,360,640,360})
    app.player_tiles[0],app.player_tiles[1]={0,0,640,360},{640,0,640,360}
    app.player_tile_count=2
    testing.expect_value(t,app_player_rect(&app,1,2),[4]i32{640,0,640,360})
}
