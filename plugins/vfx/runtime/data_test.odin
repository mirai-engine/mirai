package vfx

import "core:testing"
import "mirai:core"
import gpu "mirai:render"
import "mirai:std/base"

// The words of an entry are those the renderer reads the catalog with.
#assert(DATA_WORDS==gpu.PROGRAM_DATA_WORDS)

@(test)
data_channels_follow_the_programs_that_read_them :: proc(t:^testing.T) {
    d:Data_Channels
    defer data_free(&d)
    problems:core.Problems
    sparks,smoke:=base.name_hash("sparks"),base.name_hash("smoke")
    // Two programs read sparks with different words, one reads smoke: sparks keeps the most.
    data_need(&d,sparks,4,&problems,core.NONE)
    data_need(&d,smoke,2,&problems,core.NONE)
    data_need(&d,sparks,7,&problems,core.NONE)
    data_place(&d)
    testing.expect_value(t,len(d.entries),2)
    testing.expect_value(t,d.entries[0].words,u32(7))
    testing.expect_value(t,d.entries[1].offset,data_bytes(7))
    testing.expect_value(t,d.bytes,data_bytes(7)+data_bytes(2))
    layout:=d.layout
    // A frame without the programs of smoke lets it go, and the channels are made again.
    d.made=true
    data_need(&d,sparks,7,&problems,core.NONE)
    data_place(&d)
    testing.expect_value(t,len(d.entries),1)
    testing.expect(t,d.layout!=layout && !d.made)
    testing.expect_value(t,data_find(&d,smoke),-1)
}

// A watched channel is read back from the copy the frame wrote, as many
// entries as its counter says; one nobody watches is not.
@(test)
data_channels_a_game_watches_come_back_from_the_copy_the_frame_wrote :: proc(t:^testing.T) {
    d:Data_Channels
    defer data_free(&d)
    problems:core.Problems
    sparks,smoke:=base.name_hash("sparks"),base.name_hash("smoke")
    data_need(&d,sparks,2,&problems,core.NONE)
    data_need(&d,smoke,2,&problems,core.NONE)
    data_need(&d,REPORTS_CHANNEL,REPORT_WORDS,&problems,core.NONE)
    data_place(&d)
    data_watched(&d,[]u64{sparks})
    testing.expect(t,d.entries[0].watched && !d.entries[1].watched && d.entries[2].watched, "the reports come back too")
    // The copy the frame wrote comes back alone: two entries, as its counter says.
    words:u32=2
    bytes:=make([]u8,data_copy_bytes(words))
    defer delete(bytes)
    ([^]u32)(raw_data(bytes))[0]=2
    copies:=([^]f32)(raw_data(bytes[16:]))
    for i in 0..<6 {copies[i]=f32(10+i)}
    channel:Data_Read
    defer delete(channel.entries)
    data_read_bytes(&channel,bytes,words)
    testing.expect(t,channel.fresh)
    testing.expect_value(t,len(channel.entries),4)
    testing.expect_value(t,channel.entries[3],f32(13))
    read:=Particle_Data_Read{}
    defer particle_data_read_free(&read)
    append(&read.channels,Data_Read{name=sparks,words=2,fresh=true})
    append(&read.channels[0].entries,1,2,3,4)
    entries,each:=data_entries(&read,"sparks")
    testing.expect_value(t,len(entries),4)
    testing.expect_value(t,each,2)
    entries,each=data_entries(&read,"smoke")
    testing.expect_value(t,len(entries),0)
}
