package ui

import "core:math"
import "core:testing"

@(private="file")
test_glyph_texel :: proc(font:^Font,glyph:Glyph,phase,column,row:int) -> u8 {
    x:=int(math.round(glyph.uv.x*f32(font.width)))+phase*int(glyph.bounds.w)+column
    y:=int(math.round(glyph.uv.y*f32(font.height)))+row
    return font.pixels[y*font.width+x]
}

@(test)
font_rasterizes_embedded_inter_into_a_bordered_atlas :: proc(t:^testing.T) {
    font:Font
    ready:=font_init(&font,nil,nil,1);defer font_destroy(&font)
    testing.expect(t,ready,"The embedded fonts always initialize")
    if !ready {return}
    testing.expect_value(t,font.font_count,FONT_DEFAULTS)
    testing.expect_value(t,len(font.faces),len(FONT_FACES_EDITOR))
    testing.expect(t,text_width(&font,"WWW",16)>text_width(&font,"iii",16)*2,"Proportional glyph advances")
    face:=font_face(&font,FONT_REGULAR,14)
    testing.expect_value(t,face.size,i32(14))
    testing.expect(t,face.glyphs[int('a')].bounds.h<face.glyphs[int('A')].bounds.h,"Lowercase keeps its x-height")
    testing.expect_value(t,text_width(&font,"iii\nWWW",16),text_width(&font,"WWW",16))
    for character in 32..<127 {testing.expectf(t,font.metrics[0].available[character],"Printable ASCII %q is in the atlas",rune(character))}
    testing.expect(t,font_index(&font,0,'\U0001f600')==font_index(&font,0,'?'),"Code points outside the atlas fall back to '?'")
    testing.expect(t,font_index(&font,0,'…')>=384,"The symbols of the UI have glyphs of their own")
    antialiased:=false;opaque:=false
    for coverage in font.pixels {if coverage>0 && coverage<255 {antialiased=true};if coverage==255 {opaque=true}}
    testing.expect(t,antialiased && opaque,"Atlas contains grayscale antialiasing and solid glyph interiors")
    for &f in font.faces {
        for glyph,index in f.glyphs {
            if !font.metrics[f.font].available[index] || glyph.bounds.w<=0 {continue}
            x:=int(math.round(glyph.uv.x*f32(font.width)));y:=int(math.round(glyph.uv.y*f32(font.height)))
            width:=int(glyph.bounds.w);height:=int(glyph.bounds.h)
            testing.expectf(t,x>=0 && y>=0 && x+width*int(glyph.phases)<=font.width && y+height<=font.height,"Glyph %d of size %d stays inside the atlas",index,f.size)
            covered:=0
            for phase in 0..<int(glyph.phases) {
                for row in 0..<height {for column in 0..<width {
                    coverage:=test_glyph_texel(&font,glyph,phase,column,row)
                    if row==0 || column==0 || row==height-1 || column==width-1 {
                        testing.expectf(t,coverage==0,"Glyph %d of size %d keeps an empty border at phase %d",index,f.size,phase)
                    } else if coverage>0 {covered+=1}
                }}
            }
            testing.expectf(t,covered>0,"The texture coordinates of glyph %d of size %d address its pixels",index,f.size)
        }
    }
}

@(test)
font_sizes_are_em_and_faces_have_the_exact_size_of_the_density :: proc(t:^testing.T) {
    for density in ([3]f32{1,1.75,2}) {
        font:Font
        testing.expect(t,font_init(&font,nil,nil,density))
        defer font_destroy(&font)
        for face in FONT_FACES_EDITOR {
            testing.expect_value(t,font_face(&font,int(face.font),f32(face.size)*density).pixel_size,f32(face.size)*density)
        }
        // CSS: Inter's line is its ascent of 1984 and descent of 494 units per 2048.
        testing.expect(t,abs(font.metrics[0].ascent-1984.0/2048)<1e-6)
        testing.expect_value(t,text_width(&font,"Directional light",11),text_width(&font,"Directional light",11))
    }
    normal,retina:Font
    defer {font_destroy(&normal);font_destroy(&retina)}
    testing.expect(t,font_init(&normal,nil,nil,1)&&font_init(&retina,nil,nil,2))
    // An em of 11 is 11 units: the cap height of Inter is 0.7275 em. Up to 14
    // pixels per em the hinter rounds the x-height up, and the caps grow with it.
    cap_height :: proc(font:^Font,size:f32) -> int {
        glyph:=font_face(font,0,size).glyphs[int('H')]
        rows:=0
        for row in 0..<int(glyph.bounds.h) {
            strongest:u8
            for column in 0..<int(glyph.bounds.w) {strongest=max(strongest,test_glyph_texel(font,glyph,0,column,row))}
            if strongest>=128 {rows+=1}
        }
        return rows
    }
    a1,a2:=cap_height(&normal,11),cap_height(&retina,22)
    testing.expectf(t,a1==int(math.round(f32(11*0.7275))) && abs(a2-a1*2)<=1,"Cap heights of %v and %v pixels",a1,a2)
    testing.expect_value(t,text_width(&retina,"Directional light",13),text_width(&normal,"Directional light",13))
}

@(test)
font_hints_heights_to_the_pixel_grid :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,nil,nil,1.75))
    defer font_destroy(&font)
    // The top and the bottom of H and of x are flat: the light hinter puts
    // them on pixel edges, so their first and last rows are nearly solid.
    for face in font.faces {
        for character in ([2]rune{'H','x'}) {
            glyph:=face.glyphs[int(character)]
            width,height:=int(glyph.bounds.w),int(glyph.bounds.h)
            for row in ([2]int{1,height-2}) {
                strongest:u8
                for column in 1..<width-1 {strongest=max(strongest,test_glyph_texel(&font,glyph,0,column,row))}
                testing.expectf(t,strongest>=200,"%q at %.2f pixels: row %d peaks at %d",character,face.pixel_size,row,strongest)
            }
        }
    }
}

@(test)
font_faces_keep_subpixel_phases_of_small_glyphs :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,nil,nil,1.75))
    defer font_destroy(&font)
    face:=font_face(&font,FONT_REGULAR,11*1.75)
    testing.expect_value(t,face.phases,u8(4))
    testing.expect_value(t,font_face(&font,FONT_REGULAR,15*1.75).phases,u8(2))
    testing.expect_value(t,font_face(&font,FONT_REGULAR,20*1.75).phases,u8(1))
    // The stem of l moves a quarter of a pixel at each phase.
    glyph:=face.glyphs[int('l')]
    centers:[4]f32
    for phase in 0..<4 {
        weight,sum:f32
        for row in 0..<int(glyph.bounds.h) {for column in 0..<int(glyph.bounds.w) {
            coverage:=f32(test_glyph_texel(&font,glyph,phase,column,row))
            weight+=coverage;sum+=coverage*f32(column)
        }}
        centers[phase]=sum/weight
    }
    for phase in 1..<4 {testing.expectf(t,abs(centers[phase]-centers[0]-f32(phase)*0.25)<0.06,"Phases move the stem by quarters: %v",centers)}
}

@(test)
font_kerning_comes_from_gpos :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,nil,nil,1))
    defer font_destroy(&font)
    // Inter Regular: the pairs of the class and of the glyph subtables of
    // its kern lookups, in units of 2048 per em.
    Pair :: struct {left,right:rune,units:f32}
    for pair in ([?]Pair{{'A','V',-140},{'T','o',-160},{'T','y',-128},{'L','T',-197},{'r','.',-128},{'7','.',-256},{'Y','o',-157},{'W','A',-116}}) {
        a,b:=font_index(&font,0,pair.left),font_index(&font,0,pair.right)
        kern:=font_kern(&font,0,a,b,2048)
        testing.expectf(t,kern==pair.units,"%c%c kerns %v units, not %v",pair.left,pair.right,kern,pair.units)
        separate:=text_width(&font,string([]u8{u8(pair.left)}),11)+text_width(&font,string([]u8{u8(pair.right)}),11)
        together:=text_width(&font,string([]u8{u8(pair.left),u8(pair.right)}),11)
        testing.expect(t,abs(together-separate-pair.units*11/2048)<1e-4,"Kerning moves the pen in measures")
    }
    testing.expect_value(t,font_kern(&font,0,font_index(&font,0,'o'),font_index(&font,0,'o'),11),f32(0))
    testing.expect_value(t,font_kern(&font,0,-1,font_index(&font,0,'V'),11),f32(0))
    testing.expect(t,len(font.metrics[FONT_SEMIBOLD].kerning.values)>0,"Each weight reads its own kerning")
}

@(test)
font_weights_are_faces_of_their_own :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,nil,nil,1))
    defer font_destroy(&font)
    ink :: proc(font:^Font,f:int,size:f32,character:rune) -> int {
        glyph:=font_face(font,f,size).glyphs[int(character)]
        total:=0
        for row in 0..<int(glyph.bounds.h) {for column in 0..<int(glyph.bounds.w) {total+=int(test_glyph_texel(font,glyph,0,column,row))}}
        return total
    }
    regular,medium,semibold:=ink(&font,FONT_REGULAR,11,'H'),ink(&font,FONT_MEDIUM,11,'H'),ink(&font,FONT_SEMIBOLD,11,'H')
    testing.expectf(t,regular<medium && medium<semibold,"Heavier weights cover more: %d, %d, %d",regular,medium,semibold)
    testing.expect(t,text_width(&font,"Transform",11,FONT_SEMIBOLD)>text_width(&font,"Transform",11,FONT_REGULAR),"SemiBold has its own advances")
}

@(test)
font_atlas_is_rebuilt_as_a_transaction_when_the_density_changes :: proc(t:^testing.T) {
    ctx:Context
    testing.expect(t,test_context_init(&ctx,TEST_FONT))
    defer context_destroy(&ctx)
    revision,height:=ctx.font.revision,ctx.font.height
    testing.expect(t,context_set_density(&ctx,1),"The same density changes nothing")
    testing.expect_value(t,ctx.font.revision,revision)
    testing.expect(t,context_set_density(&ctx,2))
    testing.expect_value(t,ctx.font.density,f32(2))
    testing.expect(t,ctx.font.revision!=revision && ctx.font.height>height,"A denser display gets a larger atlas to upload")
    testing.expect_value(t,font_face(&ctx.font,0,28).pixel_size,f32(28))
    // Without memory the previous atlas stays whole.
    pixels,revision2:=raw_data(ctx.font.pixels),ctx.font.revision
    backing:=ctx.font.allocator
    ctx.font.allocator=mem_nil_allocator()
    testing.expect(t,!font_rebuild(&ctx.font,3))
    ctx.font.allocator=backing
    testing.expect(t,raw_data(ctx.font.pixels)==pixels && ctx.font.revision==revision2 && ctx.font.density==2)
    testing.expect_value(t,font_face(&ctx.font,0,28).pixel_size,f32(28))
}

@(test)
font_takes_several_fonts_and_sizes :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,{FONT_INTER,FONT_INTER},{14,32},1))
    defer font_destroy(&font)
    testing.expect_value(t,len(font.faces),4)
    testing.expect_value(t,font_face(&font,1,30).size,i32(32))
    testing.expect_value(t,font_face(&font,1,30).font,u8(1))
    testing.expect_value(t,font_face(&font,0,15).size,i32(14))
    testing.expect_value(t,text_width(&font,"Play",32,1),text_width(&font,"Play",32,0))
    bad:Font
    testing.expect(t,!font_init(&bad,{{1,2,3,4}},nil,1),"A file that is not a font is refused")
    testing.expect_value(t,len(bad.faces),0)
}

@(test)
text_wraps_at_words_and_newlines :: proc(t:^testing.T) {
    // Without an atlas every character but the space is half a size wide, and a space a quarter.
    font:Font
    Case :: struct {text:string,width:f32,wrap:Text_Wrap,lines:[]string}
    cases:=[]Case{
        {"alpha beta gamma",60,.Words,{"alpha beta","gamma"}},
        {"alpha beta gamma",30,.Words,{"alpha","beta","gamma"}},
        {"alpha beta gamma",60,.None,{"alpha beta gamma"}},
        {"one\ntwo",1000,.Words,{"one","two"}},
        {"",100,.Words,{""}},
        // A word and the space after it fit, or the word starts the next line.
        {"alpha beta",49,.Words,{"alpha beta"}},
        {"alpha beta gamma",49,.Words,{"alpha","beta gamma"}},
        // A word wider than the line starts one and breaks after its last character that fits.
        {"unbreakable word",20,.Words,{"unbr","eaka","ble","word"}},
        {"a unbreakable b",20,.Words,{"a","unbr","eaka","ble","b"}},
        // A line ends before the spaces it breaks at; one that does not fit after a word starts the next line.
        {"aaaa  bbbb",25,.Words,{"aaaa","bbbb"}},
        {"aaaa  bbbb",24,.Words,{"aaaa"," bbbb"}},
        {"a  b",100,.Words,{"a  b"}},
        // The spaces before a newline stay in their line, and a newline that ends the text starts an empty line.
        {"ab  \ncd",100,.Words,{"ab  ","cd"}},
        {"a\n\nb",100,.None,{"a","","b"}},
        {"a\n",100,.Words,{"a",""}},
        {"\n",100,.Words,{"",""}},
    }
    for c in cases {
        it:=text_lines(&font,c.text,10,c.width,c.wrap)
        for {
            start,end,ok:=text_lines_next(&it)
            if !ok {break}
            testing.expectf(t,it.row<len(c.lines) && c.text[start:end]==c.lines[min(it.row,len(c.lines)-1)],"%q at %v: line %d is %q",c.text,c.width,it.row,c.text[start:end])
        }
        testing.expectf(t,it.row+1==len(c.lines),"%q at %v: %d lines",c.text,c.width,it.row+1)
    }
    _,_,width:=text_line(&font,"alpha beta gamma",10,60,.Words)
    testing.expect_value(t,width,f32(47.5))
}

@(test)
text_is_cut_for_an_ellipsis_and_indexed_by_position :: proc(t:^testing.T) {
    font:Font
    testing.expect_value(t,text_width(&font,"abcd",10),f32(20))
    testing.expect_value(t,text_cut(&font,"abcdefgh",10,25),"abcd")
    testing.expect_value(t,text_cut(&font,"abcdefgh",10,400),"abcdefgh")
    testing.expect_value(t,text_index_at(&font,"abcd",10,-5),0)
    testing.expect_value(t,text_index_at(&font,"abcd",10,2),0)
    testing.expect_value(t,text_index_at(&font,"abcd",10,3),1)
    testing.expect_value(t,text_index_at(&font,"abcd",10,3,true),0)
    testing.expect_value(t,text_index_at(&font,"abcd",10,11,true),2)
    testing.expect_value(t,text_index_at(&font,"abcd",10,500),4)
}

@(private="file")
test_glyph_vertices :: proc(frame:Frame) -> int {
    count:=0
    for v in frame.vertices {if quad_kind(v.quad)==.Glyph {count+=1}}
    return count
}
@(private="file")
test_rasterized :: proc(font:^Font) -> int {
    count:=0
    for &face in font.faces {for glyph in face.glyphs {if glyph.phases>0 {count+=1}}}
    return count
}

@(test)
a_font_on_demand_rasterizes_what_the_contexts_that_borrow_it_draw :: proc(t:^testing.T) {
    owner:Font
    testing.expect(t,font_init(&owner,nil,nil,1.75,on_demand=true))
    defer font_destroy(&owner)
    testing.expect_value(t,test_rasterized(&owner),0)
    testing.expect_value(t,owner.height,884) // FONT_ROWS_START by the square of the density
    a,b:Context
    desc:=TEST_FONT
    desc.font=&owner
    testing.expect(t,test_context_init(&a,desc) && test_context_init(&b,desc))
    draw :: proc(ctx:^Context,user:rawptr) {draw_text(ctx,"Transform",10,10,11,{255,255,255,255})}
    input:=test_input()
    // The first frame asks for the glyphs; the owner rasterizes them and the next one draws them.
    testing.expect_value(t,test_glyph_vertices(test_frame(&a,&input,draw)),0)
    revision:=owner.revision
    testing.expect(t,font_update(&owner),"The owner rasterizes what was asked for")
    testing.expect(t,owner.revision!=revision)
    testing.expect_value(t,test_rasterized(&owner),8) // T r a n s f o m
    testing.expect(t,!font_update(&owner),"Nothing is asked twice")
    testing.expect_value(t,test_glyph_vertices(test_frame(&a,&input,draw)),9*6)
    testing.expect_value(t,test_glyph_vertices(test_frame(&b,&input,draw)),9*6)
    testing.expect(t,!font_update(&owner),"A context that borrows the font draws what another one asked for")
    // The glyphs are those of a font rasterized whole.
    whole:Font
    testing.expect(t,font_init(&whole,nil,nil,1.75))
    defer font_destroy(&whole)
    for character in ([3]rune{'T','f','m'}) {
        x,y:=font_face(&owner,0,11*1.75).glyphs[int(character)],font_face(&whole,0,11*1.75).glyphs[int(character)]
        testing.expect(t,x.bounds==y.bounds && x.phases==y.phases)
        same:=true
        for phase in 0..<int(x.phases) {for row in 0..<int(x.bounds.h) {for column in 0..<int(x.bounds.w) {
            same&=test_glyph_texel(&owner,x,phase,column,row)==test_glyph_texel(&whole,y,phase,column,row)
        }}}
        testing.expectf(t,same,"%q has the coverage of the whole atlas",character)
    }
    // A context does not rebuild nor free what it borrows.
    testing.expect(t,context_set_density(&a,3) && owner.density==1.75)
    context_destroy(&a)
    testing.expect(t,owner.ready && test_rasterized(&owner)==8)
    // Another density empties the atlas and the glyphs are asked for again.
    testing.expect(t,font_set_density(&owner,2))
    testing.expect_value(t,test_rasterized(&owner),0)
    testing.expect_value(t,test_glyph_vertices(test_frame(&b,&input,draw)),0)
    testing.expect(t,font_update(&owner))
    testing.expect_value(t,test_glyph_vertices(test_frame(&b,&input,draw)),9*6)
    context_destroy(&b)
}

@(test)
a_font_on_demand_grows_and_keeps_the_glyphs_it_has :: proc(t:^testing.T) {
    owner:Font
    testing.expect(t,font_init(&owner,nil,nil,2,on_demand=true))
    defer font_destroy(&owner)
    font_want(&owner,0,int('H'))
    testing.expect(t,font_update(&owner))
    before:=owner.faces[0].glyphs[int('H')]
    rows:=make([]u8,int(before.bounds.w*before.bounds.h))
    defer delete(rows)
    for row in 0..<int(before.bounds.h) {for column in 0..<int(before.bounds.w) {rows[row*int(before.bounds.w)+column]=test_glyph_texel(&owner,before,0,column,row)}}
    // Every glyph of every face: the atlas has to grow many times.
    for face in 0..<len(owner.faces) {for index in 32..<FONT_GLYPHS {font_want(&owner,face,index)}}
    height:=owner.height
    testing.expect(t,font_update(&owner))
    testing.expect(t,owner.height>height,"The atlas grows by rows")
    after:=owner.faces[0].glyphs[int('H')]
    testing.expect(t,after.bounds==before.bounds && after.uv.h<before.uv.h,"Texture coordinates follow the new height")
    same:=true
    for row in 0..<int(after.bounds.h) {for column in 0..<int(after.bounds.w) {same&=rows[row*int(after.bounds.w)+column]==test_glyph_texel(&owner,after,0,column,row)}}
    testing.expect(t,same,"A glyph keeps its pixels when the atlas grows")
    for &face in owner.faces {for glyph,index in face.glyphs {if index>=32 {testing.expect(t,glyph.phases>0)}}}
}

@(test)
a_context_that_asks_its_owner_draws_new_glyphs_in_the_same_frame :: proc(t:^testing.T) {
    owner:Font
    testing.expect(t,font_init(&owner,nil,nil,1,on_demand=true))
    defer font_destroy(&owner)
    ctx:Context
    desc:=TEST_FONT
    desc.font=&owner
    desc.font_ask=proc(user:rawptr) {font_update((^Font)(user),grow=false)}
    desc.font_user=&owner
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    draw :: proc(ctx:^Context,user:rawptr) {draw_text(ctx,"Transform",10,10,11,{255,255,255,255},FONT_SEMIBOLD)}
    input:=test_input()
    testing.expect_value(t,test_glyph_vertices(test_frame(&ctx,&input,draw)),9*6)
    testing.expect(t,!font_update(&owner),"Nothing waits for the next frame")
    // A full atlas grows only between frames: the glyph that does not fit waits for it.
    owner.shelf={0,owner.height,0}
    many :: proc(ctx:^Context,user:rawptr) {draw_text(ctx,"Lights",10,10,15,{255,255,255,255},FONT_SEMIBOLD)}
    testing.expect_value(t,test_glyph_vertices(test_frame(&ctx,&input,many)),0)
    height:=owner.height
    testing.expect(t,font_update(&owner) && owner.height>height)
    testing.expect_value(t,test_glyph_vertices(test_frame(&ctx,&input,many)),6*6)
}

@(test)
a_font_on_demand_tells_its_owner_which_texels_changed :: proc(t:^testing.T) {
    owner:Font
    testing.expect(t,font_init(&owner,nil,nil,1,on_demand=true))
    defer font_destroy(&owner)
    testing.expect_value(t,owner.dirty,[4]int{0,0,owner.width,owner.height})
    owner.dirty={}
    font_want(&owner,0,int('W'))
    testing.expect(t,font_update(&owner))
    glyph:=owner.faces[0].glyphs[int('W')]
    x,y:=int(glyph.uv.x*f32(owner.width)),int(glyph.uv.y*f32(owner.height))
    testing.expect_value(t,owner.dirty,[4]int{x,y,x+int(glyph.bounds.w*glyph.phases),y+int(glyph.bounds.h)})
    owner.dirty={}
    testing.expect(t,font_set_density(&owner,2))
    testing.expect_value(t,owner.dirty,[4]int{0,0,owner.width,owner.height})
}

@(private="file")
TEST_CFF :: #load("../assets/fixtures/cff.otf")

@(test)
font_has_greek_and_cyrillic_glyphs_of_their_own :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,nil,{14},1))
    defer font_destroy(&font)
    question:=font_index(&font,0,'?')
    for character in "αβγΩώЖжЯёЄ" {
        index:=font_index(&font,0,character)
        testing.expectf(t,index!=question && index>=FONT_EXTRA_INDEX+len(FONT_EXTRA),"%q has a glyph of its own",character)
        testing.expectf(t,font.metrics[0].advances[index]>0,"%q advances",character)
        glyph:=font_face(&font,0,14).glyphs[index]
        testing.expectf(t,glyph.phases==1 && glyph.bounds.w>2,"%q is rasterized whole, on whole pixels",character)
    }
    testing.expect_value(t,font_index(&font,0,'͸'),question) // unassigned in Greek
    testing.expect_value(t,font_index(&font,0,'Ԁ'),question) // after Cyrillic
    testing.expect(t,text_width(&font,"Привет",14)>text_width(&font,"При",14),"Cyrillic is measured")
    testing.expect(t,font_index(&font,0,'é')==int('é') && font_index(&font,0,'ſ')==0x17f,"Latin glyphs are their code point")
}

@(test)
font_reads_cff_outlines_and_the_kerning_of_greek_and_cyrillic :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,{TEST_CFF},{20},1),"An OpenType font with CFF outlines loads")
    defer font_destroy(&font)
    m:=&font.metrics[0]
    for character in ([?]rune{'A','H','α','Ж'}) {
        index:=font_index(&font,0,character)
        testing.expectf(t,m.available[index],"%q is in the CFF font",character)
        glyph:=font_face(&font,0,20).glyphs[index]
        testing.expectf(t,glyph.bounds.w>2 && glyph.bounds.h>2,"%q is rasterized",character)
    }
    testing.expect(t,abs(m.advances[font_index(&font,0,'Ж')]-0.8)<1e-6)
    testing.expect_value(t,font_index(&font,0,'B'),font_index(&font,0,'?'))
    a,zhe,alpha:=font_index(&font,0,'A'),font_index(&font,0,'Ж'),font_index(&font,0,'α')
    testing.expect_value(t,metrics_kerning(m,a,a),f32(-50))
    testing.expect_value(t,metrics_kerning(m,zhe,alpha),f32(-120)) // a lookup of 'cyrl' alone
}

@(test)
a_glyph_a_font_lacks_is_drawn_from_inter :: proc(t:^testing.T) {
    ctx:Context
    desc:=TEST_FONT
    fonts:=[2][]byte{FONT_INTER,TEST_CFF}
    desc.fonts=fonts[:]
    testing.expect(t,test_context_init(&ctx,desc))
    defer context_destroy(&ctx)
    font:=&ctx.font
    question:=font_index(font,1,'?')
    // from: the font that draws it; -1: '?', which neither has.
    Case :: struct {character:string,from:int}
    for c in ([]Case{{"A",1},{"Ж",1},{"B",0},{"П",0},{"и",0},{"é",0},{"\U0001f600",-1}}) {
        pen:=text_pen(font,14,1)
        advance:f32
        for r in c.character {_,advance=text_pen_step(&pen,r)}
        if c.from<0 {
            testing.expectf(t,pen.previous==question && pen.from==1,"%q is '?'",c.character)
            continue
        }
        testing.expectf(t,pen.from==c.from && pen.previous!=question && font.metrics[c.from].available[pen.previous],"%q comes from font %v, not %v",c.character,c.from,pen.from)
        testing.expectf(t,advance==text_width(font,c.character,14,c.from),"%q advances as in the font that has it",c.character)
    }
    // Drawn with the glyph of Inter's face, whatever the font of the text.
    build :: proc(ctx:^Context,user:rawptr) {draw_text(ctx,"Привет",0,0,14,{255,255,255,255},1)}
    input:=test_input()
    frame:=test_frame(&ctx,&input,build)
    testing.expect_value(t,len(frame.vertices),6*6)
    pe:=font_face(font,0,14).glyphs[font_index(font,1,'П')].uv
    corner:=frame.vertices[0].uv
    for v in frame.vertices[:6] {corner={min(corner.x,v.uv.x),min(corner.y,v.uv.y)}}
    // At whichever phase the pen puts it.
    phase:=(corner.x-pe.x)/pe.w
    testing.expectf(t,abs(corner.y-pe.y)<1e-5 && abs(phase-math.round(phase))<1e-3 && phase>-0.001 && phase<4,"'П' is drawn from Inter: %v, %v",corner,pe)
}

@(test)
fonts_are_added_between_frames_keeping_what_was_rasterized :: proc(t:^testing.T) {
    owner:Font
    testing.expect(t,font_init(&owner,nil,nil,1,on_demand=true))
    defer font_destroy(&owner)
    font_want(&owner,0,int('H'))
    testing.expect(t,font_update(&owner))
    before:=owner.faces[0].glyphs[int('H')]
    font_want(&owner,1,int('W'))
    faces:=len(owner.faces)
    index,added:=font_add(&owner,TEST_CFF)
    testing.expect(t,added && index==FONT_DEFAULTS && owner.font_count==FONT_DEFAULTS+1)
    testing.expect_value(t,len(owner.faces),faces+10) // a face at each size of the editor
    testing.expect(t,owner.faces[0].glyphs[int('H')]==before,"What was rasterized stays")
    face:=font_face(&owner,FONT_DEFAULTS,20)
    testing.expect(t,face!=nil && face.font==FONT_DEFAULTS && face.size==20)
    testing.expect(t,font_update(&owner))
    testing.expect(t,owner.faces[1].glyphs[int('W')].phases>0,"What was asked for before is rasterized")
    face_index:=owner.metrics[FONT_DEFAULTS].faces[0]
    zhe:=font_index(&owner,FONT_DEFAULTS,'Ж')
    font_want(&owner,face_index,zhe)
    testing.expect(t,font_update(&owner))
    testing.expect(t,owner.faces[face_index].glyphs[zhe].bounds.w>2,"The added font rasterizes on demand")
    testing.expect(t,abs(text_width(&owner,"Ж",10,FONT_DEFAULTS)-8)<1e-4)
    _,refused:=font_add(&owner,{1,2,3,4})
    testing.expect(t,!refused && owner.font_count==FONT_DEFAULTS+1 && len(owner.faces)==faces+10,"Bytes that are not a font leave it as it was")
    for owner.font_count<FONT_CAPACITY {
        _,more:=font_add(&owner,FONT_INTER)
        if !testing.expect(t,more) {break}
    }
    _,full:=font_add(&owner,FONT_INTER)
    testing.expect(t,!full,"No more than FONT_CAPACITY fonts")
}

@(test)
a_whole_font_is_rasterized_again_when_a_font_is_added_or_replaced :: proc(t:^testing.T) {
    font:Font
    testing.expect(t,font_init(&font,{FONT_INTER},{12,24},1))
    defer font_destroy(&font)
    revision:=font.revision
    index,added:=font_add(&font,TEST_CFF)
    testing.expect(t,added && index==1 && len(font.faces)==4)
    testing.expect(t,font.revision!=revision)
    glyph:=font_face(&font,1,24).glyphs[font_index(&font,1,'H')]
    testing.expect(t,glyph.bounds.w>2 && test_glyph_texel(&font,glyph,0,int(glyph.bounds.w)/2,int(glyph.bounds.h)/2)==255,"The added font is in the atlas")
    testing.expect(t,font_replace(&font,1,FONT_INTER_SEMIBOLD))
    testing.expect(t,text_width(&font,"Transform",11,1)>text_width(&font,"Transform",11,0),"The font has the advances of its new file")
    testing.expect(t,font.metrics[1].available[int('B')],"The font has the glyphs of its new file")
    testing.expect(t,!font_replace(&font,1,{1,2,3}) && font.metrics[1].available[int('B')],"A failed replace keeps the font")
    testing.expect(t,!font_replace(&font,2,FONT_INTER))
}

@(test)
text_at_a_size_no_face_is_close_to_gets_a_face_of_its_own_between_frames :: proc(t:^testing.T) {
    owner:Font
    testing.expect(t,font_init(&owner,nil,nil,1,on_demand=true))
    defer font_destroy(&owner)
    // What the medium font asked for before keeps its glyph through the move.
    medium:=owner.metrics[FONT_MEDIUM].faces[0]
    font_want(&owner,medium,int('W'))
    faces:=len(owner.faces)
    font_face_ask(&owner,FONT_REGULAR,26)
    font_face_ask(&owner,FONT_REGULAR,26.2)
    font_face_ask(&owner,FONT_REGULAR,20) // the editor has it
    testing.expect(t,font_faces_add(&owner))
    testing.expect_value(t,len(owner.faces),faces+1)
    face:=font_face(&owner,FONT_REGULAR,26)
    testing.expect(t,face!=nil && face.size==26 && face.pixel_size==26,"the size asked for has its face")
    for ask in owner.asked {testing.expect_value(t,ask.size,i32(0))}
    moved:=owner.metrics[FONT_MEDIUM].faces[0]
    testing.expect_value(t,moved,medium+1)
    testing.expect(t,font_update(&owner))
    testing.expect(t,owner.faces[moved].glyphs[int('W')].phases>0,"what was wanted follows its face")
    // The faces of the regular font did not move: it is first.
    testing.expect_value(t,owner.metrics[FONT_REGULAR].faces[0],0)
}
