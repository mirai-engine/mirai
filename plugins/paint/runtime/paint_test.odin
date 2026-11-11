package paint

import "core:math/rand"
import "core:testing"
import "mirai:asset"
import "mirai:std/serial"

// A .paint gives back the colors it was written with; no colors are not
// written, and random bytes are refused when read.
@(test)
colors_come_back_and_hostile_files_are_refused :: proc(t:^testing.T) {
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    colors:=[]u32{0xff0000ff,0xff00ff00,0xffff0000}
    doc:asset.Document
    testing.expect_value(t,colors_document(&doc,&types,{1,2},nil),asset.Error.Invalid)
    if !testing.expect_value(t,colors_document(&doc,&types,{1,2},colors),asset.Error.None) {return}
    writer:serial.Writer;serial.writer_init(&writer);defer serial.writer_destroy(&writer)
    testing.expect_value(t,asset.document_write(&doc,&writer),asset.Error.None)
    asset.document_destroy(&doc)
    file:asset.Asset
    if !testing.expect_value(t,asset.asset_open(&file,serial.writer_bytes(&writer)),asset.Error.None) {return}
    read,error:=colors_view(&file,&types)
    testing.expect(t,error==.None && len(read)==len(colors) && read[2]==colors[2])
    asset.asset_close(&file)
    noise:[256]u8
    for &b in noise {b=u8(rand.uint32())}
    if asset.asset_open(&file,noise[:])==.None {
        _,refused:=colors_view(&file,&types)
        testing.expect(t,refused!=.None,"random bytes are no colors")
        asset.asset_close(&file)
    }
}
