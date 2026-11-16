package paint

import "core:math/rand"
import "core:testing"
import "mirai:asset"
import "mirai:std/serial"

// A .paint gives back what it was written with; no colors, or colors without
// a position each, are not written, and random bytes are refused when read.
@(test)
colors_come_back_and_hostile_files_are_refused :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    colors:=[]u32{0xff0000ff,0xff00ff00,0xffff0000}
    positions:=[][3]f32{{0,0,0},{1,0,0},{0,1,0}}
    doc:asset.Document
    testing.expect_value(t,paint_document(&doc,&types,{1,2},{}),asset.Error.Invalid)
    testing.expect_value(t,paint_document(&doc,&types,{1,2},{positions=positions[:2],colors=colors}),asset.Error.Invalid)
    if !testing.expect_value(t,paint_document(&doc,&types,{1,2},{info={mesh=9},positions=positions,colors=colors}),asset.Error.None) {return}
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None)
    asset.document_destroy(&doc)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None) {return}
    read,error:=paint_view(&file,&types)
    testing.expect(t,error==.None && read.mesh==9 && len(read.colors)==len(colors) && read.colors[2]==colors[2] && read.positions[2]==positions[2])
    asset.asset_close(&file)
    noise:[256]u8
    for &b in noise {b=u8(rand.uint32())}
    if asset.asset_open(&file,noise[:])==.None {
        _,refused:=paint_view(&file,&types)
        testing.expect(t,refused!=.None,"random bytes are no colors")
        asset.asset_close(&file)
    }
}
