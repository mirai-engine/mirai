package importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import cimage "mirai:cook/image"
import "mirai:std/base"
import "mirai:std/serial"

@(private="file") CFF_OTF :: #load("../../assets/fixtures/cff.otf")
@(private="file") INTER :: #load("../../assets/fonts/Inter-Regular.ttf")

@(test)
fonts_import_as_the_file_they_are_and_collections_are_refused :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"fonts")
    if folder=="" {return}
    for file in ([2]string{"face.otf","inter.ttf"}) {
        source:=fmt.tprintf("%s/%s",folder,file)
        _=os.write_entire_file(source,CFF_OTF if file=="face.otf" else INTER)
        report,error:=import_font(source,folder)
        if !testing.expectf(t,error.code==.None,"%s imports: %s",file,error.message) {continue}
        defer report_destroy(&report)
        testing.expect(t,len(report.assets)==1 && report.assets[0].kind==asset.KIND_FONT && strings.has_suffix(report.assets[0].path,".font"))
        types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,report.assets[0].path),asset.Error.None) {continue}
        defer asset.asset_close(&a)
        view,view_error:=asset.font_view(&a,&types)
        testing.expect_value(t,view_error,asset.Error.None)
        testing.expect(t,view.info.outlines==(.CFF if file=="face.otf" else .TrueType) && len(view.file)==len(CFF_OTF if file=="face.otf" else INTER))
        // Again: the same asset, with the same id.
        again,again_error:=import_font(source,folder)
        testing.expect(t,again_error.code==.None && len(again.assets)==1 && again.assets[0].id==report.assets[0].id && again.assets[0].path==report.assets[0].path)
        report_destroy(&again)
    }
    collection:=fmt.tprintf("%s/family.ttc",folder)
    _=os.write_entire_file(collection,transmute([]u8)string("ttcf\x00\x02\x00\x00\x00\x00\x00\x02............"))
    _,error:=import_font(collection,folder)
    testing.expect(t,error.code==.Unsupported && strings.contains(error.message,"collection") && strings.contains(error.message,"fonttools ttLib -y 0"),error.message)
    broken:=fmt.tprintf("%s/broken.otf",folder)
    _=os.write_entire_file(broken,transmute([]u8)string("OTTO\x00\x09\x00\x80\x00\x03\x00\x10 not tables at all"))
    _,error=import_font(broken,folder)
    testing.expect(t,error.code==.Malformed,error.message)
    testing.expect(t,!os.exists(fmt.tprintf("%s/broken.font",folder)),"A refused font writes nothing")
}

@(test)
csv_fields_follow_rfc_4180 :: proc(t:^testing.T) {
    text:="\xef\xbb\xbfkey,es,en\r\n" +
        "a,\"uno, dos\",\"say \"\"hi\"\"\"\r\n" +
        "\n" +
        "b,\"dos\nlineas\",\r\n" +
        "c,,three"
    records,lines,message:=csv_records(text,context.temp_allocator)
    testing.expect_value(t,message,"")
    if !testing.expect_value(t,len(records),4) {return}
    testing.expect(t,records[0][0]=="key" && records[0][2]=="en","A byte order mark is not part of the first field")
    testing.expect(t,records[1][1]=="uno, dos" && records[1][2]=="say \"hi\"","Quotes hold commas and doubled quotes")
    testing.expect(t,records[2][1]=="dos\nlineas" && records[2][2]=="","Quotes hold line breaks; an empty last field is a field")
    testing.expect(t,len(records[3])==3 && records[3][1]=="" && records[3][2]=="three","The last record needs no line break")
    testing.expect(t,lines[1]==2 && lines[2]==4 && lines[3]==6,"Each record knows its line, past empty lines and breaks in quotes")
    _,_,unclosed:=csv_records("key,es\na,\"open",context.temp_allocator)
    testing.expect(t,strings.contains(unclosed,"line 2") && strings.contains(unclosed,"not closed"),unclosed)
    _,_,stray:=csv_records("key,es\na,b\"c",context.temp_allocator)
    testing.expect(t,strings.contains(stray,"line 2") && strings.contains(stray,"in quotes"),stray)
    _,_,after:=csv_records("key,es\na,\"b\"c",context.temp_allocator)
    testing.expect(t,strings.contains(after,"after its closing quote"),after)
}

@(test)
strings_table_reads_a_csv_by_key_and_language :: proc(t:^testing.T) {
    long:=strings.repeat("ñandú ",40,context.temp_allocator)
    table,message:=strings_table(fmt.tprintf("key,es,en,pt-BR\nmenu.play,Jugar,Play,Jogar\nmenu.quit,Salir,Quit,\nstory,\"%s\",Long,\"Ελληνικά, Русский\"\n",long),context.temp_allocator)
    if !testing.expectf(t,message=="","%s",message) {return}
    testing.expect(t,len(table.languages)==3 && len(table.keys)==3 && len(table.entries)==8,"An empty cell is no text")
    text :: proc(table:Strings_Table,key,language:string) -> string {
        for entry in table.entries {
            if serial.text_field(table.keys[entry.key].name[:])==key && serial.text_field(table.languages[entry.language].code[:])==language {return string(table.text[entry.offset:][:entry.length])}
        }
        return "<none>"
    }
    testing.expect_value(t,text(table,"menu.play","pt-BR"),"Jogar")
    testing.expect_value(t,text(table,"menu.quit","pt-BR"),"<none>")
    testing.expect_value(t,text(table,"story","es"),long)
    testing.expect_value(t,text(table,"story","pt-BR"),"Ελληνικά, Русский")

    Case :: struct {csv,says:string}
    for c in ([]Case{
        {"name,es\na,b\n","first row"},
        {"key,es,es\na,b,c\n","two columns"},
        {"key,es\na,b\na,c\n","also on line 2"},
        {"key,es\na,b,c\n","3 cells"},
        {"key,e s\na,b\n","language"},
        {"key,es\n,b\n","no key"},
        {"key,es\na,\xff\n","UTF-8"},
    }) {
        _,refused:=strings_table(c.csv,context.temp_allocator)
        testing.expectf(t,strings.contains(refused,c.says),"%q: %s",c.csv,refused)
    }
}

@(test)
prompt_images_pack_into_power_of_two_atlases :: proc(t:^testing.T) {
    PAD :: PROMPTS_PADDING
    check :: proc(t:^testing.T,sizes:[][2]int,places:[]Prompts_Place,pages:[][2]int) {
        for page in pages {
            testing.expect(t,page.x&(page.x-1)==0 && page.y&(page.y-1)==0 && page.x<=PROMPTS_ATLAS_MAX && page.y<=PROMPTS_ATLAS_MAX,"A page is a power of two on each side")
        }
        for a,i in places {
            page:=pages[a.page]
            testing.expect(t,a.x>=0 && a.y>=0 && a.x+sizes[i].x+2*PAD<=page.x && a.y+sizes[i].y+2*PAD<=page.y)
            for b,j in places[:i] {
                apart:=a.page!=b.page || a.x+sizes[i].x+2*PAD<=b.x || b.x+sizes[j].x+2*PAD<=a.x || a.y+sizes[i].y+2*PAD<=b.y || b.y+sizes[j].y+2*PAD<=a.y
                testing.expectf(t,apart,"Images %d and %d do not overlap with their padding",i,j)
            }
        }
    }
    // Four that fill a page exactly.
    square:=[4][2]int{{60,60},{60,60},{60,60},{60,60}}
    places,pages,ok:=prompts_pack(square[:],context.temp_allocator)
    testing.expectf(t,ok && len(pages)==1 && pages[0].x*pages[0].y==128*128,"%v",pages)
    check(t,square[:],places,pages)
    // A page of half the area and a small one take fewer texels than a whole one.
    sizes:=make([][2]int,121,context.temp_allocator)
    for &size in sizes {size={128,128}}
    places,pages,ok=prompts_pack(sizes,context.temp_allocator)
    if testing.expect(t,ok) {
        testing.expectf(t,len(pages)==2 && pages[0]==[2]int{2048,1024} && pages[1]==[2]int{1024,512},"%v",pages)
        check(t,sizes,places,pages)
    }
    mixed:=make([][2]int,40,context.temp_allocator)
    for &size,i in mixed {size={64+(i%3)*32,32+(i%2)*32}}
    places,pages,ok=prompts_pack(mixed,context.temp_allocator)
    if testing.expect(t,ok) {check(t,mixed,places,pages)}
    // More than a page holds takes another.
    large:=make([][2]int,5,context.temp_allocator)
    for &size in large {size={1500,1500}}
    _,many,fits:=prompts_pack(large,context.temp_allocator)
    testing.expect(t,fits && len(many)==5)
    _,_,too_large:=prompts_pack({{PROMPTS_ATLAS_MAX,8}},context.temp_allocator)
    testing.expect(t,!too_large)
}

@(test)
prompts_import_packs_the_images_of_a_manifest :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"prompts")
    if folder=="" {return}
    os.make_directory_all(fmt.tprintf("%s/images",folder))
    paint :: proc(path:string,width,height:int,color:[4]u8) {
        color:=color
        pixels:=make([]u8,width*height*4,context.temp_allocator)
        for i in 0..<width*height {copy(pixels[i*4:][:4],color[:])}
        cimage.image_write(path,{pixels=pixels,width=width,height=height})
    }
    paint(fmt.tprintf("%s/images/a.png",folder),32,32,{0,200,0,255})
    paint(fmt.tprintf("%s/images/space.png",folder),64,32,{255,255,255,128})
    manifest:=fmt.tprintf("%s/pad.prompts.json",folder)
    _=os.write_entire_file(manifest,transmute([]u8)string(`{"entries": [
        {"family": "Xbox", "input": "South", "image": "images/a.png"},
        {"family": "PlayStation", "input": "South", "image": "images/a.png"},
        {"family": "Keyboard", "input": "Key", "key": "Space", "image": "images/space.png"}
    ]}`))
    out:=fmt.tprintf("%s/out",folder)
    report,error:=import_prompts(manifest,out)
    if !testing.expectf(t,error.code==.None,"%s",error.message) {return}
    defer report_destroy(&report)
    if !testing.expect_value(t,len(report.assets),2) {return}
    atlas,pack:=report.assets[0],report.assets[1]
    testing.expect(t,atlas.kind==asset.KIND_TEXTURE && pack.kind==asset.KIND_PROMPTS && strings.has_suffix(pack.path,"/pad.prompts") && strings.has_suffix(atlas.path,"/pad_atlas.tex"))
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    a,b:asset.Asset
    if !testing.expect_value(t,asset.asset_load(&a,pack.path),asset.Error.None) {return}
    defer asset.asset_close(&a)
    view,view_error:=asset.prompts_view(&a,&types)
    if !testing.expect_value(t,view_error,asset.Error.None) {return}
    testing.expect(t,len(view.images)==3 && view.images[0].texture==atlas.id && view.images[0].uv==view.images[1].uv,"One image shown by two entries is packed once")
    space:=view.images[2]
    testing.expect(t,serial.text_field(space.key[:])=="Space" && space.aspect==2 && space.family==0 && space.input==asset.PROMPT_INPUT_KEY)
    if !testing.expect_value(t,asset.asset_load(&b,atlas.path),asset.Error.None) {return}
    defer asset.asset_close(&b)
    texture,texture_error:=asset.texture_view(&b,&types)
    if !testing.expect_value(t,texture_error,asset.Error.None) {return}
    width,height:=int(texture.info.width),int(texture.info.height)
    testing.expect(t,texture.info.format==.RGBA8 && .Srgb in texture.info.flags && b.blob.header.owner==pack.id,"The atlas is sRGB, plain RGBA8 and a part of the pack")
    texel :: proc(texels:[]u8,width,x,y:int) -> [4]u8 {at:=(y*width+x)*4;return {texels[at],texels[at+1],texels[at+2],texels[at+3]}}
    level:=texture.texels[texture.mips[0].offset:][:width*height*4]
    x,y:=int(space.uv.x*f32(width)),int(space.uv.y*f32(height))
    testing.expect_value(t,texel(level,width,x,y),[4]u8{255,255,255,128})
    testing.expect_value(t,texel(level,width,x-PROMPTS_PADDING,y-PROMPTS_PADDING),[4]u8{255,255,255,128}) // the padding repeats the edge, alpha straight
    // Again: the same files and ids.
    again,again_error:=import_prompts(manifest,out)
    testing.expect(t,again_error.code==.None && len(again.assets)==2 && again.assets[0].id==atlas.id && again.assets[1].id==pack.id && again.assets[0].kept)
    report_destroy(&again)

    Case :: struct {json,says:string}
    for c in ([]Case{
        {`{"entries": [{"family": "Xbx", "input": "South", "image": "images/a.png"}]}`,"Keyboard, Xbox, PlayStation, Nintendo"},
        {`{"entries": [{"family": "Xbox", "input": "Jump", "image": "images/a.png"}]}`,"the input \"Jump\""},
        {`{"entries": [{"family": "Keyboard", "input": "Key", "key": "Enterr", "image": "images/a.png"}]}`,"\"Enterr\""},
        {`{"entries": [{"family": "Xbox", "input": "Mouse_Left", "image": "images/a.png"}]}`,"family Keyboard"},
        {`{"entries": [{"family": "Xbox", "input": "South", "image": "images/a.png"},{"family": "Xbox", "input": "South", "image": "images/a.png"}]}`,"has an image already"},
        {`{"entries": [{"family": "Xbox", "input": "South", "image": "images/missing.png"}]}`,"missing.png"},
        {`{"images": []}`,"\"entries\""},
    }) {
        bad:=fmt.tprintf("%s/bad.prompts.json",folder)
        _=os.write_entire_file(bad,transmute([]u8)c.json)
        _,refused:=import_prompts(bad,out)
        testing.expectf(t,refused.code!=.None && strings.contains(refused.message,c.says),"%s: %s",c.json,refused.message)
    }
}
