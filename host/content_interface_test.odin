package host

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import "mirai:ui"

@(private="file") CFF_OTF :: #load("../assets/fixtures/cff.otf")

@(private="file")
Interface_Fixture :: struct {
    root:string,
    assets:Assets,
    app:App,
}

@(private="file")
FONT_ID :: base.Asset_Id{0xf0,1}
@(private="file")
TEXTS_ID :: base.Asset_Id{0x57,1}
@(private="file")
PROMPTS_ID :: base.Asset_Id{0x9a,1}
@(private="file")
UI_ID :: base.Asset_Id{0x41,1}

// A folder with a .font, a .strings, a .prompts and a .ui whose text takes
// the font, and an application that reads it without a renderer.
@(private="file")
interface_fixture :: proc(t:^testing.T,f:^Interface_Fixture,name:string) -> bool {
    f.root=base.test_folder(t,name)
    if f.root=="" {return false}
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    testing.expect_value(t,asset.font_save(fmt.tprintf("%s/face.font",f.root),&types,{id=FONT_ID,file=CFF_OTF}),asset.Error.None) or_return

    languages:=[2]asset.String_Language{}
    asset.text_set(languages[0].code[:],"es");asset.text_set(languages[1].code[:],"en")
    keys:=[2]asset.String_Key{}
    asset.text_set(keys[0].name[:],"menu.play");asset.text_set(keys[1].name[:],"menu.quit")
    entries:=[3]asset.String_Entry{{0,0,0,5},{0,1,5,4},{1,0,9,5}}
    testing.expect_value(t,asset.strings_save(fmt.tprintf("%s/menu.strings",f.root),&types,{id=TEXTS_ID,languages=languages[:],keys=keys[:],entries=entries[:],text=transmute([]u8)string("JugarPlaySalir")}),asset.Error.None) or_return

    images:=[2]asset.Prompt_Image{
        {family=u8(ui.Prompt_Family.Xbox),input=u8(ui.Prompt_Input.South),texture={0x7e,1},uv={0.25,0,0.25,0.5},aspect=1},
        {family=u8(ui.Prompt_Family.Keyboard),input=u8(ui.Prompt_Input.Key),texture={0x7e,1},uv={0,0.5,0.5,0.25},aspect=2},
    }
    asset.text_set(images[1].key[:],"Space")
    testing.expect_value(t,asset.prompts_save(fmt.tprintf("%s/pad.prompts",f.root),&types,{id=PROMPTS_ID,images=images[:]}),asset.Error.None) or_return

    nodes:=[2]ui.Tree_Node{{kind=.Box,parent=-1},{kind=.Text,parent=0,style=1}}
    text:=transmute([]u8)string("Жα")
    nodes[1].text={0,u32(len(text))}
    styles:=[2]ui.Node_Style{{},{text={font=ui.FONT_TREE,size=20}}}
    fonts:=[1]ui.Tree_Font{{font=FONT_ID}}
    doc:asset.Document
    testing.expect_value(t,ui_tree_document(&doc,&types,UI_ID,{nodes=nodes[:],styles=styles[:],fonts=fonts[:],text=text}),asset.Error.None) or_return
    error:=asset.document_save(&doc,fmt.tprintf("%s/menu.ui",f.root))
    asset.document_destroy(&doc)
    testing.expect_value(t,error,asset.Error.None) or_return

    testing.expect(t,assets_init(&f.assets,{root=f.root,capacity=8})) or_return
    assets_scan(&f.assets)
    f.app=App{assets=&f.assets,allocator=context.allocator}
    return true
}

@(private="file")
interface_fixture_destroy :: proc(f:^Interface_Fixture) {
    ui.font_destroy(&f.app.ui_font)
    app_content_destroy(&f.app)
    assets_destroy(&f.assets)
}

@(test)
fonts_of_interfaces_join_the_font_of_the_application_between_frames :: proc(t:^testing.T) {
    f:Interface_Fixture
    if !interface_fixture(t,&f,"fonts") {return}
    defer interface_fixture_destroy(&f)
    app:=&f.app
    // Without a renderer the application has no font: the face is given and waits.
    face,ok:=content_font(app,FONT_ID)
    testing.expect(t,ok && face==CONTENT_UI_FONTS)
    again,_:=content_font(app,FONT_ID)
    testing.expect_value(t,again,face)
    app_ui_fonts_apply(app)
    testing.expect(t,!app.ui_font.ready)
    _,missing:=content_font(app,{0xdead,1})
    testing.expect(t,!missing,"An id without a file is no font")

    testing.expect(t,ui.font_init(&app.ui_font,nil,nil,1,app.allocator,on_demand=true))
    content:=content_ui(app,UI_ID)
    if !testing.expect(t,content!=nil,"An interface loads with the fonts it names") {return}
    testing.expect_value(t,content.tree.styles[1].text.font,face)
    testing.expect_value(t,app.ui_font.font_count,int(CONTENT_UI_FONTS))
    app_ui_fonts_apply(app)
    testing.expect_value(t,app.ui_font.font_count,int(face)+1)
    zhe:=ui.font_index(&app.ui_font,int(face),'Ж')
    testing.expect(t,app.ui_font.metrics[face].available[zhe],"The font of the .font is the face")
    testing.expect(t,abs(ui.text_width(&app.ui_font,"Ж",10,int(face))-8)<1e-4)

    // Collected or not, the font stays: the font of the application reads it.
    testing.expect_value(t,content_collect(app),1)
    testing.expect(t,app.content.fonts[0].id==FONT_ID && app.content.fonts[0].data!=nil)

    // Its file changes: the next frame gives the font its new bytes.
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    path:=fmt.tprintf("%s/face.font",f.root)
    testing.expect_value(t,asset.font_save(path,&types,{id=FONT_ID,file=ui.FONT_INTER}),asset.Error.None)
    testing.expect(t,assets_refresh(&f.assets,{"face.font"}))
    testing.expect_value(t,content_refresh(app),1)
    testing.expect(t,!app.ui_font.metrics[face].available[int('B')])
    app_ui_fonts_apply(app)
    testing.expect(t,app.ui_font.metrics[face].available[int('B')] && app.ui_font.font_count==int(face)+1,"The font is replaced where it is")
    face2,_:=content_font(app,FONT_ID)
    testing.expect_value(t,face2,face)
}

@(test)
texts_are_found_by_language_and_key_without_allocating :: proc(t:^testing.T) {
    f:Interface_Fixture
    if !interface_fixture(t,&f,"texts") {return}
    defer interface_fixture_destroy(&f)
    s:=content_strings(&f.app,TEXTS_ID)
    if !testing.expect(t,s!=nil) {return}
    testing.expect(t,content_strings(&f.app,FONT_ID)==nil,"A font is no table of texts")
    testing.expect(t,assets_scan(f.app.assets) && content_strings(&f.app,"menu.strings")==s,"by its path, the same texts")
    testing.expect(t,content_strings(&f.app,"missing.strings")==nil)
    es,en,play,quit:=base.name_hash("es"),base.name_hash("en"),base.name_hash("menu.play"),base.name_hash("menu.quit")
    text,found:=strings_text(s,es,play)
    testing.expect(t,found && text=="Jugar")
    text,found=strings_text(s,en,play)
    testing.expect(t,found && text=="Play")
    text,found=strings_text(s,es,quit)
    testing.expect(t,found && text=="Salir")
    _,found=strings_text(s,en,quit)
    testing.expect(t,!found,"A language without the text of a key")
    _,found=strings_text(s,base.name_hash("fr"),play)
    testing.expect(t,!found)
    _,found=strings_text(nil,es,play)
    testing.expect(t,!found)
}

@(test)
prompts_of_a_pack_are_found_by_family_input_and_key :: proc(t:^testing.T) {
    f:Interface_Fixture
    if !interface_fixture(t,&f,"prompts") {return}
    defer interface_fixture_destroy(&f)
    p:=content_prompts(&f.app,PROMPTS_ID)
    if !testing.expect(t,p!=nil) {return}
    south,found:=prompts_find(p,&f.assets,.Xbox,.South,"")
    testing.expect(t,found && south.quad.kind==.Image && south.quad.uv==ui.Rect{0.25,0,0.25,0.5} && south.aspect==1 && south.family==.Xbox)
    _,found=prompts_find(p,&f.assets,.PlayStation,.South,"")
    testing.expect(t,!found,"Another family has its own images")
    space:ui.Prompt
    space,found=prompts_find(p,&f.assets,.Xbox,.Key,"Space")
    testing.expect(t,found && space.family==.Keyboard && space.aspect==2 && space.text=="Space","Keys are of the keyboard whatever the family")
    _,found=prompts_find(p,&f.assets,.Keyboard,.Key,"Enter")
    testing.expect(t,!found)
}
