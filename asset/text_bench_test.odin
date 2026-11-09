package asset

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:testing"
import "core:time"
import "mirai:std/compressor/lz"
import "mirai:std/serial"

// A document in the container against the same document as the text `mirai asset unpack` writes
// and `pack` reads: scenes of three sizes and files of the template and the demo. Run with
//   mirai test asset text_source_against_the_container --release -define:ASSET_BENCH=true

@(private="file") ASSET_BENCH :: #config(ASSET_BENCH,false)
@(private="file") TEXT_BENCH_FILES :: [?]string{
    "templates/game/assets/hud/hud.ui","templates/game/assets/menu/shell.ui","demo/assets/ocean/Ocean.mat",
    "templates/game/assets/arena/main.scene","demo/assets/animation_gallery/animation.scene",
}

@(private="file")
Text_Bench :: struct {
    save,load,write,read:f64, // seconds, the best round
    container,text:int,       // bytes
    bare:int,                 // of the text without its schema, which pack does not read
    bulk:int,                 // of the files next to the text
    packed:[Pack]int,         // of the text as one LZ stream of each level
}

// Every round builds what a save or a load builds: nothing is reused between rounds.
@(private="file")
text_bench :: proc(t:^testing.T,doc:^Document,rounds:int) -> (b:Text_Bench,ok:bool) {
    options:=Text_Options{schema=true,bulk=.Files}
    data,error:=document_bytes(doc)
    testing.expect_value(t,error,Error.None) or_return
    defer mem.free_bytes(data,context.allocator)
    text:serial.Writer;serial.writer_init(&text);defer serial.writer_destroy(&text)
    testing.expect_value(t,document_text_write(doc,&text,options),Error.None) or_return
    source:=serial.writer_bytes(&text)
    loader:=test_bulk_loader(doc)
    b.save,b.load,b.write,b.read=max(f64),max(f64),max(f64),max(f64)
    for round in 0..<rounds {
        start:=time.tick_now()
        bytes,_:=document_bytes(doc)
        b.save=min(b.save,seconds(start))
        mem.free_bytes(bytes,context.allocator)

        back:Document
        start=time.tick_now()
        error=document_read(&back,data)
        b.load=min(b.load,seconds(start))
        testing.expect_value(t,error,Error.None) or_return
        document_destroy(&back)

        w:serial.Writer
        start=time.tick_now()
        serial.writer_init(&w)
        error=document_text_write(doc,&w,options)
        b.write=min(b.write,seconds(start))
        serial.writer_destroy(&w)
        testing.expect_value(t,error,Error.None) or_return

        start=time.tick_now()
        problem,read:=document_text_read(&back,string(source),loader)
        b.read=min(b.read,seconds(start))
        testing.expectf(t,read,"%v %v at %d",problem.code,problem.rule,problem.offset) or_return
        if round==0 {
            again,_:=document_bytes(&back)
            testing.expect(t,mem.compare(again,data)==0,"the text gives the same file back")
            mem.free_bytes(again,context.allocator)
        }
        document_destroy(&back)
        free_all(context.temp_allocator)
    }
    b.container,b.text=len(data),len(source)
    bare:serial.Writer;serial.writer_init(&bare);defer serial.writer_destroy(&bare)
    document_text_write(doc,&bare)
    b.bare=len(serial.writer_bytes(&bare))
    for table in doc.tables {
        if .Bulk not_in table.flags {continue}
        for column in table.columns {b.bulk+=len(column.data)}
    }
    encoder:lz.Encoder;defer lz.encoder_destroy(&encoder)
    packed:=make([]u8,pack_bound(len(source)));defer delete(packed)
    for p in Pack {b.packed[p],_=pack(&encoder,p,source,packed)}
    return b,true
}

@(private="file")
text_bench_print :: proc(name:string,b:Text_Bench) {
    fmt.printfln("%s, container: save %.3f ms, load %.3f ms, %d bytes",name,b.save*1000,b.load*1000,b.container)
    fmt.printfln("%s, text: write %.3f ms, read %.3f ms, %d bytes (%d without the schema, %d of bulk files; as LZ %d Edit, %d Quick, %d Ship)",name,b.write*1000,b.read*1000,b.text,b.bare,b.bulk,b.packed[.Edit],b.packed[.Quick],b.packed[.Ship])
    fmt.printfln("%s, text / container: save %.1fx, load %.1fx, size %.1fx",name,b.write/b.save,b.read/b.load,f64(b.text)/f64(b.container))
}

@(test)
text_source_against_the_container :: proc(t:^testing.T) {
    when !ASSET_BENCH {return}
    else {
        // The allocator of the test runner counts every allocation; the measurement uses the heap.
        context.allocator=runtime.heap_allocator()
        types:Types;types_init(&types);defer types_destroy(&types)
        for count in ([]int{100,10000,100000}) {
            rounds:=count>10000?5:count>100?20:200
            scene:Scene
            bench_scene(&scene,&types,count)
            defer scene_destroy(&scene)
            if !testing.expect_value(t,scene_records_put(&scene),Error.None) {continue}
            b,ok:=text_bench(t,&scene.doc,rounds)
            if !ok {continue}
            text_bench_print(fmt.tprintf("%d entities",count),b)

            // What either encoding pays after its document to have the scene an editor edits.
            data,_:=document_bytes(&scene.doc)
            adopt:=max(f64)
            for _ in 0..<rounds {
                doc:Document
                if !testing.expect_value(t,document_read(&doc,data),Error.None) {break}
                loaded:Scene
                start:=time.tick_now()
                error:=scene_from_document(&loaded,&types,&doc)
                adopt=min(adopt,seconds(start))
                testing.expect_value(t,error,Error.None)
                scene_destroy(&loaded)
            }
            mem.free_bytes(data,context.allocator)
            fmt.printfln("%d entities, document to scene: %.3f ms",count,adopt*1000)
            free_all(context.temp_allocator)
        }
        for name in TEXT_BENCH_FILES {
            defer free_all(context.temp_allocator)
            path:=fmt.tprintf("%s/../%s",#directory,name)
            doc:Document
            if !testing.expectf(t,document_load(&doc,path)==.None,"%s was not read",path) {continue}
            defer document_destroy(&doc)
            if b,ok:=text_bench(t,&doc,200);ok {text_bench_print(name,b)}
        }
    }
}
