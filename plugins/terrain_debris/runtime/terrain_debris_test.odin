package terrain_debris

import "core:testing"

@(test)
digs_give_a_piece_for_each_volume_taken_and_keep_what_falls_short_for_the_next :: proc(t:^testing.T) {
    owed:=f32(0)
    room:=u32(8)
    testing.expect_value(t,debris_count(&owed,0.3,0.5,&room),u32(0))
    testing.expect_value(t,debris_count(&owed,0.3,0.5,&room),u32(1))
    testing.expect(t,abs(owed-0.1)<1e-5,"what falls short of a piece waits for the next dig")
    // More than the tick has room for: what is left is owed up to one more.
    testing.expect_value(t,debris_count(&owed,100,0.5,&room),u32(7))
    testing.expect_value(t,room,u32(0))
    testing.expect(t,owed<=0.5)
    room=8
    testing.expect_value(t,debris_count(&owed,0,0.5,&room),u32(0))
    testing.expect_value(t,debris_count(&owed,0.01,0.5,&room),u32(1))
    testing.expect_value(t,debris_count(&owed,1,0,&room),u32(0))
}
