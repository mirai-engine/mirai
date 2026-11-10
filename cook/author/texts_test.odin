package author

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

@(private="file")
Texts_Project :: struct {
    root:string,
    registry:asset.Registry,
    types:asset.Types,
}

@(private="file")
texts_project :: proc(t:^testing.T,p:^Texts_Project,name:string) -> bool {
    p.root=base.test_folder(t,name)
    if p.root=="" {return false}
    asset.registry_init(&p.registry,p.root)
    asset.types_init(&p.types)
    return true
}

@(private="file")
texts_project_destroy :: proc(p:^Texts_Project) {
    asset.registry_destroy(&p.registry)
    asset.types_destroy(&p.types)
}

// Writes the .strings the changes touched and reads the assets again.
@(private="file")
texts_project_put :: proc(t:^testing.T,p:^Texts_Project,texts:^Texts) -> bool {
    written,problem:=texts_written(texts,&p.types,{0x7e,7})
    testing.expect_value(t,problem,"") or_return
    for file in written {
        testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",p.root,file.path),file.bytes)==nil) or_return
    }
    return testing.expect_value(t,asset.registry_scan(&p.registry),asset.Error.None)
}

// The texts written, set by set, are the texts read: through the .strings
// and through the CSV translators take, which cook/import reads as any CSV
// of texts, no text is lost in a language. A key takes its text by language
// code; one of no language of a game, a key too long and a key of an
// imported file are refused with why.
@(test)
every_text_survives_its_strings_and_its_csv :: proc(t:^testing.T) {
    p:Texts_Project
    if !texts_project(t,&p,"author-texts") {return}
    defer texts_project_destroy(&p)
    a:=Assets{&p.registry,&p.types}
    said:=[]struct{key,code,text:string}{
        {"menu.start","en","Start"},{"menu.start","es","Empezar"},{"menu.start","pt-BR","Iniciar"},
        {"menu.quit","en","Quit, \"now\"\nor later"},{"menu.quit","es","Salir"},
        {"hud.score","en","Score: {coins}"},
    }
    texts:=texts_read(a,"en")
    for s in said {testing.expect_value(t,texts_set(&texts,s.key,s.code,s.text),"")}
    refused:=[]struct{key,code,text,why:string}{
        {"menu.start","spanish","Empezar","'spanish' is no language a game can be in; give its code: en,"},
        {"","en","Start","a key is a name shorter than 64 bytes"},
    }
    for c in refused {
        problem:=texts_set(&texts,c.key,c.code,c.text)
        testing.expectf(t,strings.has_prefix(problem,c.why),"%s",problem)
    }
    if !texts_project_put(t,&p,&texts) {return}
    testing.expect(t,os.is_file(fmt.tprintf("%s/%s",p.root,TEXTS_HOME)),"A key no .strings has goes to the one of the project")

    read:=texts_read(a,"en")
    testing.expect(t,len(read.problems)==0 && len(read.rows)==3 && read.languages[0]=="en")
    for s in said {testing.expect_value(t,texts_text(&read,s.key,s.code),s.text)}
    testing.expect_value(t,texts_text(&read,"hud.score","es"),"")

    // The CSV is the one cook/import reads, and gives every text back to texts that have none.
    csv:=texts_csv(&read)
    table,message:=importer.strings_table(csv,context.temp_allocator)
    testing.expect(t,message=="" && len(table.entries)==len(said) && serial.text_field(table.languages[0].code[:])=="en")
    empty:=texts_read({},"en")
    set,problem:=texts_csv_take(&empty,csv)
    testing.expect(t,problem=="" && set==len(said))
    for s in said {testing.expect_value(t,texts_text(&empty,s.key,s.code),s.text)}
    // A cell changes one text; an empty one changes nothing; a CSV that does not read says its line.
    set,problem=texts_csv_take(&read,"key,en,es\nmenu.quit,,Cerrar\nmenu.back,Back,\n")
    testing.expect(t,problem=="" && set==2)
    testing.expect(t,texts_text(&read,"menu.quit","es")=="Cerrar" && texts_text(&read,"menu.quit","en")==said[3].text && texts_text(&read,"menu.back","en")=="Back")
    _,problem=texts_csv_take(&read,"key,en\nmenu.back,\"Back\n")
    testing.expectf(t,strings.contains(problem,"line 2"),"%s",problem)

    // What an import made changes in its CSV.
    languages:=[1]asset.String_Language{}
    asset.text_set(languages[0].code[:],"en")
    keys:=[1]asset.String_Key{}
    asset.text_set(keys[0].name[:],"lines.greet")
    source:asset.Import_Info
    testing.expect_value(t,asset.strings_save(fmt.tprintf("%s/lines.strings",p.root),&p.types,{id={0x11,1},languages=languages[:],keys=keys[:],entries={{0,0,0,5}},text=transmute([]u8)string("Hello"),source=&source}),asset.Error.None)
    asset.registry_scan(&p.registry)
    read=texts_read(a,"en")
    testing.expect_value(t,texts_text(&read,"lines.greet","en"),"Hello")
    problem=texts_set(&read,"lines.greet","en","Hi")
    testing.expectf(t,strings.contains(problem,"lines.strings, which is imported"),"%s",problem)
}

@(private="file")
Texts_Item :: struct {damage:f32,title:core.Text,lines:[2]core.Text}

// What the texts lack is told with who asks for it: the document and the
// node of a .ui, the document, the row and the field of a .records; a key
// that says nothing in a language of the game; a key two files have.
@(test)
a_missing_text_names_the_document_and_who_shows_it :: proc(t:^testing.T) {
    p:Texts_Project
    if !texts_project(t,&p,"author-texts-missing") {return}
    defer texts_project_destroy(&p)
    a:=Assets{&p.registry,&p.types}

    text:=make([dynamic]u8,context.temp_allocator)
    nodes:=[]ui.Tree_Node{
        ui.tree_node_record(&text,-1,{kind=.Box,name="menu"}),
        ui.tree_node_record(&text,0,{kind=.Button,name="start",text="menu.start",flags={.Localized}}),
        ui.tree_node_record(&text,0,{kind=.Button,name="quit",text="menu.quit",flags={.Localized}}),
        ui.tree_node_record(&text,0,{kind=.Text,name="version",text="menu.start"}),
    }
    styles:=[1]ui.Node_Style{}
    testing.expect_value(t,host.ui_tree_save(fmt.tprintf("%s/menu.ui",p.root),&p.types,{0x21,1},{nodes=nodes,styles=styles[:],text=text[:]}),asset.Error.None)

    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    value_type,_:=serial.schema_add_type_info(&schema,type_info_of(Texts_Item))
    items:=[1]Texts_Item{}
    base.text_set(items[0].title.key[:],"item.sword")
    base.text_set(items[0].lines[1].key[:],"menu.start")
    names:=[1]asset.Records_Name{}
    base.text_set(names[0][:],"sword")
    bytes,error:=asset.records_bytes(&p.types,{id={0x22,1},type="game.Item",ids={7},names=names[:],schema=&schema,value_type=value_type,images=mem.slice_to_bytes(items[:])},context.temp_allocator)
    testing.expect(t,error==.None && os.write_entire_file(fmt.tprintf("%s/items.records",p.root),bytes)==nil)

    texts:=texts_read(a,"en")
    texts_set(&texts,"menu.start","en","Start")
    if !texts_project_put(t,&p,&texts) {return}
    // The same key in a second file.
    languages:=[1]asset.String_Language{}
    asset.text_set(languages[0].code[:],"en")
    keys:=[1]asset.String_Key{}
    asset.text_set(keys[0].name[:],"menu.start")
    testing.expect_value(t,asset.strings_save(fmt.tprintf("%s/z_more.strings",p.root),&p.types,{id={0x23,1},languages=languages[:],keys=keys[:],entries={{0,0,0,2}},text=transmute([]u8)string("Go")}),asset.Error.None)
    asset.registry_scan(&p.registry)

    texts=texts_read(a,"en")
    testing.expect_value(t,texts_text(&texts,"menu.start","en"),"Start")
    uses:=texts_uses(a)
    testing.expect_value(t,len(uses),4)
    lines:=strings.join(texts_missing(&texts,uses,{"en","es"}),"\n",context.temp_allocator)
    wanted:=[]string{
        "menu.ui: quit shows the key menu.quit, which no .strings has",
        "items.records: sword.title shows the key item.sword, which no .strings has",
        "the key menu.start of texts.strings says nothing in es",
        "the key menu.start is in texts.strings and in z_more.strings",
    }
    for want in wanted {testing.expectf(t,strings.contains(lines,want),"%q is not in:\n%s",want,lines)}
    testing.expectf(t,!strings.contains(lines,"start shows") && !strings.contains(lines,"lines[1]") && !strings.contains(lines,"version"),"A key with its text is not missing, and a node that is not localized shows no key:\n%s",lines)
}
