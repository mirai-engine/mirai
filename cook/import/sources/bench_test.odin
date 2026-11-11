package sources

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/base"

BENCH :: #config(COOK_BENCH,false)
BENCH_ROUNDS :: 5

@(private="file")
best_of :: proc(body:proc(data:rawptr),data:rawptr) -> time.Duration {
    best:=time.Duration(max(i64))
    for _ in 0..<BENCH_ROUNDS {
        start:=time.tick_now()
        body(data)
        best=min(best,time.tick_since(start))
    }
    return best
}

@(private="file")
Large :: struct {path,out:string,model_bytes,asset_bytes:int,triangles,vertices:int}

@(test)
bench_import_and_write_of_a_large_obj :: proc(t:^testing.T) {
    if !BENCH {return}
    SIDE :: 400
    folder:=base.test_folder(t,"bench")
    if folder=="" {return}
    text:=strings.builder_make();defer strings.builder_destroy(&text)
    for y in 0..=SIDE {
        for x in 0..=SIDE {fmt.sbprintf(&text,"v %d %d %f\nvt %f %f\nvn 0 1 0\n",x,y,f32(x*y%7)*0.1,f32(x)/SIDE,f32(y)/SIDE)}
    }
    for y in 0..<SIDE {
        for x in 0..<SIDE {
            a:=y*(SIDE+1)+x+1
            b:=a+1;c:=a+SIDE+2;d:=a+SIDE+1
            fmt.sbprintf(&text,"f %d/%d/%d %d/%d/%d %d/%d/%d %d/%d/%d\n",a,a,a,b,b,b,c,c,c,d,d,d)
        }
    }
    large:=Large{path=write_text(folder,"grid.obj",string(text.buf[:])),out=fmt.tprintf("%s/out",folder),model_bytes=len(text.buf)}
    read:=best_of(proc(data:rawptr) {
        large:=(^Large)(data)
        model,error:=importer.import_model(large.path,FORMATS[:])
        assert(error.code==.None)
        large.triangles=len(model.meshes[0].indices)/3
        large.vertices=len(model.meshes[0].vertices)
        importer.model_destroy(&model)
    },&large)
    model,_:=importer.import_model(large.path,FORMATS[:])
    defer importer.model_destroy(&model)
    written:=best_of(proc(data:rawptr) {
        large:=(^Large)(data)
        model,_:=importer.import_model(large.path,FORMATS[:])
        defer importer.model_destroy(&model)
        // Every round builds the mesh: the one before left the same file.
        report,error:=importer.import_write(&model,large.out,{rebuild=true})
        assert(error.code==.None)
        large.asset_bytes=report.assets[0].bytes
        importer.report_destroy(&report)
    },&large)
    fmt.printfln("obj %d MB, %d triangles, %d vertices: import_model %v, import_model + import_write %v, mesh %d MB",large.model_bytes>>20,large.triangles,large.vertices,read,written,large.asset_bytes>>20)
}

@(test)
bench_import_of_a_skinned_glb :: proc(t:^testing.T) {
    if !BENCH {return}
    path:=DEMO+"models/skeletal-character/robot.glb"
    best:=best_of(proc(data:rawptr) {
        model,error:=importer.import_model((^string)(data)^,FORMATS[:])
        assert(error.code==.None)
        importer.model_destroy(&model)
    },&path)
    model,_:=importer.import_model(path,FORMATS[:])
    defer importer.model_destroy(&model)
    fmt.printfln("robot.glb: %d triangles, 13 joints: import_model %v",len(model.meshes[0].indices)/3,best)
}

