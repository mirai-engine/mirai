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
    save,load,write,read:Bench_Time,
    container,text:int,       // bytes
    bare:int,                 // of the text without its schema, which pack does not read
    bulk:int,                 // of the files next to the text
    packed:[Pack]int,         // of the text as one LZ stream of each level
}

// Seconds of the best round: on the clock, and of them those the thread had a processor.
@(private="file") Bench_Time :: struct {wall,cpu:f64}
@(private="file") Bench_Start :: struct {tick:time.Tick,thread,all:u64}

@(private="file")
bench_start :: proc() -> (s:Bench_Start) {
    s.thread,s.all=bench_thread_ran()
    s.tick=time.tick_now()
    return
}

@(private="file")
bench_stop :: proc(best:^Bench_Time,s:Bench_Start) {
    wall:=seconds(s.tick)
    thread,all:=bench_thread_ran()
    best.wall=min(best.wall,wall)
    best.cpu=min(best.cpu,wall*f64(thread-s.thread)/f64(max(all-s.all,1)))
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
    b.save,b.load,b.write,b.read={max(f64),max(f64)},{max(f64),max(f64)},{max(f64),max(f64)},{max(f64),max(f64)}
    for round in 0..<rounds {
        start:=bench_start()
        bytes,_:=document_bytes(doc)
        bench_stop(&b.save,start)
        mem.free_bytes(bytes,context.allocator)

        back:Document
        start=bench_start()
        error=document_read(&back,data)
        bench_stop(&b.load,start)
        testing.expect_value(t,error,Error.None) or_return
        document_destroy(&back)

        w:serial.Writer
        start=bench_start()
        serial.writer_init(&w)
        error=document_text_write(doc,&w,options)
        bench_stop(&b.write,start)
        serial.writer_destroy(&w)
        testing.expect_value(t,error,Error.None) or_return

        start=bench_start()
        problem,read:=document_text_read(&back,string(source),loader)
        bench_stop(&b.read,start)
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
    fmt.printfln("%s, container: save %.3f ms (cpu %.3f), load %.3f ms (cpu %.3f), %d bytes",name,b.save.wall*1000,b.save.cpu*1000,b.load.wall*1000,b.load.cpu*1000,b.container)
    fmt.printfln("%s, text: write %.3f ms (cpu %.3f), read %.3f ms (cpu %.3f), %d bytes (%d without the schema, %d of bulk files; as LZ %d Edit, %d Quick, %d Ship)",name,b.write.wall*1000,b.write.cpu*1000,b.read.wall*1000,b.read.cpu*1000,b.text,b.bare,b.bulk,b.packed[.Edit],b.packed[.Quick],b.packed[.Ship])
    fmt.printfln("%s, text / container: save %.1fx, load %.1fx, size %.1fx",name,b.write.wall/b.save.wall,b.read.wall/b.load.wall,f64(b.text)/f64(b.container))
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
            adopt:=Bench_Time{max(f64),max(f64)}
            for _ in 0..<rounds {
                doc:Document
                if !testing.expect_value(t,document_read(&doc,data),Error.None) {break}
                loaded:Scene
                start:=bench_start()
                error:=scene_from_document(&loaded,&types,&doc)
                bench_stop(&adopt,start)
                testing.expect_value(t,error,Error.None)
                scene_destroy(&loaded)
            }
            mem.free_bytes(data,context.allocator)
            fmt.printfln("%d entities, document to scene: %.3f ms (cpu %.3f)",count,adopt.wall*1000,adopt.cpu*1000)
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
