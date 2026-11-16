package asset

import "core:testing"
import "mirai:std/base"
import "mirai:std/serial"

// .font, .strings and .prompts: what is written is read back, and what a
// reader refuses is refused when written.

@(private="file")
test_reopen :: proc(t:^testing.T,doc:^Document,a:^Asset) -> bool {
    w:serial.Writer;serial.writer_init(&w);defer serial.writer_destroy(&w)
    if !testing.expect_value(t,document_write(doc,&w),Error.None) {return false}
    data:=make([]u8,len(serial.writer_bytes(&w)))
    copy(data,serial.writer_bytes(&w))
    return testing.expect_value(t,asset_take(a,data),Error.None)
}

@(test)
font_keeps_the_bytes_of_one_font :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    file:=#load("../assets/fixtures/cff.otf")
    doc:Document
    if !testing.expect_value(t,font_document(&doc,&types,{id={0xf0,1},file=file,compression=.Stream}),Error.None) {return}
    a:Asset
    ok:=test_reopen(t,&doc,&a)
    document_destroy(&doc)
    if !ok {return}
    defer asset_close(&a)
    view,error:=font_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,view.info.outlines==.CFF && string(view.file)==string(file))
    testing.expect(t,len(a.dependencies)==0)
    // What is not one font is refused: a collection, a web font, a few bytes.
    for head in ([]string{"ttcf\x00\x01\x00\x00\x00\x00\x00\x02","wOF2\x00\x01\x00\x00\x00\x00\x00\x00","true"}) {
        refused:Document
        testing.expectf(t,font_document(&refused,&types,{id={0xf1,1},file=transmute([]u8)head})==.Invalid,"%q is refused",head)
    }
    outlines,found:=font_outlines(#load("../assets/fonts/Inter-Regular.ttf"))
    testing.expect(t,found && outlines==.TrueType)
}

@(test)
strings_keep_the_texts_of_each_language_by_key :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    languages:=[3]String_Language{}
    text_set(languages[0].code[:],"es");text_set(languages[1].code[:],"en");text_set(languages[2].code[:],"pt-BR")
    keys:=[2]String_Key{}
    text_set(keys[0].name[:],"menu.play");text_set(keys[1].name[:],"menu.quit")
    long:=make([]u8,300);defer delete(long)
    for &b,i in long {b='a'+u8(i%26)}
    text:=make([dynamic]u8);defer delete(text)
    append(&text,"Jugar");append(&text,"Play");append(&text,..long);append(&text,"Salir")
    entries:=[4]String_Entry{{0,0,0,5},{0,1,5,4},{0,2,9,300},{1,0,309,5}}
    doc:Document
    if !testing.expect_value(t,strings_document(&doc,&types,{id={0x57,1},languages=languages[:],keys=keys[:],entries=entries[:],text=text[:]}),Error.None) {return}
    a:Asset
    ok:=test_reopen(t,&doc,&a)
    document_destroy(&doc)
    if !ok {return}
    defer asset_close(&a)
    view,error:=strings_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(view.languages)==3 && len(view.keys)==2 && len(view.entries)==4)
    entry:=view.entries[2]
    testing.expect(t,serial.text_field(view.languages[entry.language].code[:])=="pt-BR" && string(view.text[entry.offset:][:entry.length])==string(long),"A text longer than a field is kept whole")
    // Out of order, repeated, out of the text or not UTF-8: refused.
    broken:=entries
    broken[1],broken[2]=broken[2],broken[1]
    refused:Document
    testing.expect_value(t,strings_document(&refused,&types,{id={0x58,1},languages=languages[:],keys=keys[:],entries=broken[:],text=text[:]}),Error.Invalid)
    broken=entries;broken[3].length=6
    testing.expect_value(t,strings_document(&refused,&types,{id={0x58,1},languages=languages[:],keys=keys[:],entries=broken[:],text=text[:]}),Error.Invalid)
    twice:=keys;twice[1]=twice[0]
    testing.expect_value(t,strings_document(&refused,&types,{id={0x58,1},languages=languages[:],keys=twice[:],entries=entries[:],text=text[:]}),Error.Invalid)
    invalid:=[2]u8{0xc3,0x28}
    testing.expect_value(t,strings_document(&refused,&types,{id={0x58,1},languages=languages[:],keys=keys[:],entries=entries[:1],text=invalid[:]}),Error.Invalid)
}

@(test)
prompts_name_the_part_of_a_texture_of_each_input :: proc(t:^testing.T) {
    types:Types;types_init(&types);defer types_destroy(&types)
    atlas:=base.Asset_Id{0xa7,1}
    images:=[3]Prompt_Image{
        {family=1,input=5,texture=atlas,uv={0,0,0.5,0.5},aspect=1},
        {family=0,input=PROMPT_INPUT_KEY,texture=atlas,uv={0.5,0,0.5,0.25},aspect=2},
        {family=2,input=5,texture=atlas,uv={0,0.5,0.5,0.5},aspect=1},
    }
    text_set(images[1].key[:],"Space")
    doc:Document
    if !testing.expect_value(t,prompts_document(&doc,&types,{id={0x9a,1},images=images[:]}),Error.None) {return}
    a:Asset
    ok:=test_reopen(t,&doc,&a)
    document_destroy(&doc)
    if !ok {return}
    defer asset_close(&a)
    view,error:=prompts_view(&a,&types)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,len(view.images)==3 && serial.text_field(view.images[1].key[:])=="Space" && view.images[1].uv==Prompt_Uv{0.5,0,0.5,0.25})
    testing.expect(t,len(a.dependencies)==1 && a.dependencies[0]==atlas,"A pack depends on its textures")
    refused:Document
    for change in 0..<6 {
        broken:=images
        switch change {
        case 0: broken[0].family=PROMPT_FAMILIES
        case 1: broken[0].input=PROMPT_INPUTS
        case 2: text_set(broken[0].key[:],"A")   // a key on an input that is not Key
        case 3: broken[1].key={}                 // Key without one
        case 4: broken[2].uv.x=0.75              // past the texture
        case 5: broken[2].family=1               // the same input twice
        }
        testing.expectf(t,prompts_document(&refused,&types,{id={0x9b,1},images=broken[:]})==.Invalid,"change %d is refused",change)
    }
}
